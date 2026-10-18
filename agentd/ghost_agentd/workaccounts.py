"""Work accounts, set up once and shared out: each Telegram login lives in
~/.myghost/accounts/<name>/ (account.yaml + account.session), keeps one
connection, and hands every message to exactly one project's assistant by
its routes. A project's own side — inbox, queue, grants, watch.yaml
(window, auto_reply, post_to…) — stays in the project's folder.

    # ~/.myghost/accounts/brave/account.yaml
    api_id: 123
    api_hash: abc
    phone: "+886…"
    routes:                      # first match wins; nothing matched: recorded only
      - folder: LTS              # a Telegram chat folder
        project: lts
        trigger: all             # as in watch.yaml groups
      - group: "FQ 研發群"        # a group, by title or chat id
        project: fq
      - chat: "290611431"        # one chat (private or group), by id or name
        project: fq
      - private: true            # every private chat
        project: fq
      - all: true                # everything else
        project: fq

A chat put in a folder / chat route (or a project's folders) is assigned:
its private messages reach the assistant without a grant, replies stay
cards. Groups a project lists in its watch.yaml claim their chats after the
explicit routes and before `all`, so /watch keeps working.

Projects whose project.yaml still has telegram.account and no account with
that phone get one made at start (named after the project, routing all of
the account's messages there), their session copied over.
"""

from __future__ import annotations

import json
import shutil
import time
from dataclasses import dataclass, field
from pathlib import Path

import yaml

from . import config as cfgmod
from .broker import log

KINDS = ("folder", "group", "chat", "private", "all")


def accounts_dir() -> Path:
    return cfgmod.HOME / "accounts"


@dataclass
class Route:
    kind: str  # folder | group | chat | private | all
    value: str  # the folder / group / chat ("" for private and all)
    project: str
    trigger: object = "all"
    window: object = None  # a watch.yaml window spec, or None

    def via(self) -> dict:
        return {"kind": self.kind, "value": self.value, "trigger": self.trigger, "window": self.window}

    def describe(self) -> str:
        return f"{self.kind}{' ' + self.value if self.value else ''} → {self.project}"


@dataclass
class AccountConfig:
    name: str
    dir: Path
    api_id: str
    api_hash: str
    phone: str
    routes: list[Route] = field(default_factory=list)

    @property
    def session_file(self) -> Path:
        return self.dir / "account.session"

    @property
    def projects(self) -> list[str]:
        return list(dict.fromkeys(r.project for r in self.routes))

    @classmethod
    def load(cls, d: Path) -> "AccountConfig | None":
        f = d / "account.yaml"
        try:
            raw = yaml.safe_load(f.read_text(encoding="utf-8")) or {}
        except (OSError, yaml.YAMLError) as e:
            log(f"accounts: {f} unreadable ({e})")
            return None
        routes = []
        for r in raw.get("routes") or []:
            if not isinstance(r, dict) or not r.get("project"):
                continue
            kind = next((k for k in KINDS if k in r), None)
            if kind is None:
                log(f"accounts: {d.name}: route without folder/group/chat/private/all: {r}")
                continue
            value = "" if kind in ("private", "all") else str(r[kind])
            routes.append(Route(kind, value, str(r["project"]), r.get("trigger", "all"), r.get("window")))
        return cls(d.name, d, str(raw.get("api_id") or ""), str(raw.get("api_hash") or ""),
                   str(raw.get("phone") or ""), routes)


def _migrate(projects) -> None:
    """Make an account for each project that still carries its own login."""
    base = accounts_dir()
    have = {a.phone for a in _scan()}
    for p in projects.all():
        acc = p.tg_account or {}
        phone = str(acc.get("phone") or "")
        if not phone or phone in have:
            continue
        d = base / p.name
        if d.exists():
            continue
        d.mkdir(parents=True)
        d.chmod(0o700)
        routes = []
        # Folders the project's watch.yaml named become routes of their own.
        try:
            watch = yaml.safe_load((p.dir / "watch.yaml").read_text(encoding="utf-8")) or {}
        except (OSError, yaml.YAMLError):
            watch = {}
        for f in watch.get("folders") or []:
            f = f if isinstance(f, dict) else {"folder": f}
            if f.get("folder"):
                routes.append({"folder": str(f["folder"]), "project": p.name,
                               **({"trigger": f["trigger"]} if "trigger" in f else {})})
        if not routes:
            routes.append({"all": True, "project": p.name})
        body = {"api_id": acc.get("api_id"), "api_hash": acc.get("api_hash"), "phone": phone, "routes": routes}
        f = d / "account.yaml"
        f.write_text("# A work Telegram account, shared out to project assistants by `routes`\n"
                     "# (first match wins). See ghost_agentd/workaccounts.py.\n"
                     + yaml.safe_dump(body, allow_unicode=True, sort_keys=False), encoding="utf-8")
        f.chmod(0o600)
        old = p.dir / "account.session"
        if old.exists():
            shutil.copy2(old, d / "account.session")
            (d / "account.session").chmod(0o600)
        have.add(phone)
        log(f"accounts: made {d.name} from project {p.name}'s telegram.account ({len(routes)} route(s))")


def _scan() -> list[AccountConfig]:
    base = accounts_dir()
    if not base.exists():
        return []
    out = []
    for d in sorted(base.iterdir()):
        if (d / "account.yaml").exists():
            a = AccountConfig.load(d)
            if a is not None:
                out.append(a)
    return out


def load_accounts(projects) -> list[AccountConfig]:
    _migrate(projects)
    return _scan()


def find(name: str, projects) -> AccountConfig | None:
    """An account by its name, or the one routing to a project of that name."""
    accounts = load_accounts(projects)
    return (next((a for a in accounts if a.name == name), None)
            or next((a for a in accounts if name in a.projects), None))


class WorkAccount:
    """One login, shared: picks the project lane (AccountWatcher) for each
    message. The Telegram side is `transport` (TelethonAccount)."""

    def __init__(self, cfg: AccountConfig):
        self.cfg = cfg
        self.name = cfg.name
        self.lanes: dict = {}  # project name -> AccountWatcher
        self.transport = None
        self._warned: set = set()

    # -------------------------------------------------------------- routing

    def route(self, m):
        """The lane a message goes to, setting m.via; None: no project's."""
        hits = [r for r in self.cfg.routes if r.kind not in ("all",) and r.project in self.lanes
                and self._matches(r, m)]
        if len(hits) > 1 and m.chat_id not in self._warned:
            self._warned.add(m.chat_id)
            log(f"account {self.name}: 「{m.chat}」 matches {len(hits)} routes "
                f"({'; '.join(r.describe() for r in hits)}); the first wins")
        if hits:
            r = hits[0]
            m.via = r.via() if r.kind in ("folder", "chat", "group") else {}
            return self.lanes[r.project]
        # Groups a project's watch.yaml lists (e.g. added with /watch).
        if not m.private:
            for name, lane in self.lanes.items():
                if lane.watch()._rule(m) is not None:
                    m.via = {}
                    return lane
        r = next((r for r in self.cfg.routes if r.kind == "all" and r.project in self.lanes), None)
        if r is not None:
            m.via = {}
            return self.lanes[r.project]
        return None

    @staticmethod
    def _matches(r: Route, m) -> bool:
        if r.kind == "folder":
            return r.value in (m.folders or [])
        if r.kind == "group":
            return not m.private and r.value in (m.chat, str(m.chat_id))
        if r.kind == "chat":
            return r.value in (m.chat, str(m.chat_id))
        if r.kind == "private":
            return bool(m.private)
        return True

    def needs_folders(self) -> bool:
        return any(r.kind == "folder" for r in self.cfg.routes) or \
            any(lane.watch().folders for lane in self.lanes.values())

    def folders_named(self) -> list[str]:
        names = [r.value for r in self.cfg.routes if r.kind == "folder"]
        for lane in self.lanes.values():
            names += [r.group for r in lane.watch().folders]
        return list(dict.fromkeys(names))

    def unrouted(self, m) -> None:
        """No project takes it: a line for the record, not the text."""
        try:
            with open(self.cfg.dir / "unrouted.jsonl", "a", encoding="utf-8") as fh:
                fh.write(json.dumps({"ts": m.ts, "chat_id": m.chat_id, "chat": m.chat, "private": m.private,
                                     "sender": m.sender, "folders": m.folders}, ensure_ascii=False) + "\n")
        except OSError:
            pass

    # ----------------------------------------------------- the account's own

    def set_me(self, me: str) -> None:
        for lane in self.lanes.values():
            lane.me = me

    def on_mine(self, chat_id: int, ts: float) -> None:
        """The account wrote in a chat: unless a lane just sent it, that's
        the owner answering by hand — every lane drops what it answered."""
        now = time.time()
        if any(now - lane.own_sends.get(chat_id, 0) < lane.OWN_SEND_GRACE for lane in self.lanes.values()):
            return
        for lane in self.lanes.values():
            lane.on_mine(chat_id, ts)


class LaneTransport:
    """What a project's lane sees of the shared connection: sending and
    looking people up go straight through; reading a chat downloads into the
    project's own uploads and reports back to it."""

    def __init__(self, shared, lane):
        self.shared = shared
        self.lane = lane

    def send(self, chat_id: int, text: str, reply_to: int | None) -> None:
        self.shared.send(chat_id, text, reply_to)

    def resolve_user(self, username: str):
        return self.shared.resolve_user(username)

    def groups(self, keyword: str = "", limit: int = 8):
        return self.shared.groups(keyword, limit)

    def history(self, chat_id: int, limit: int) -> list[dict]:
        return self.shared.history(chat_id, limit, self.lane)
