"""Loading ~/.myghost/config.yaml and the per-project files.

    ~/.myghost/
    ├─ config.yaml                 # telegram token/chat, http port, timeouts
    ├─ agentd.log
    └─ projects/<name>/
       ├─ project.yaml             # paths, own TG bot + group, policy overrides
       ├─ always_allow.json        # rules added from "此專案一律允許"
       ├─ events.jsonl             # hook events, append only
       └─ decisions.jsonl          # every decision, append only (audit)

Requests whose cwd matches no project go to the built-in "_default" project.
"""

from __future__ import annotations

import json
import os
import threading
from dataclasses import dataclass, field
from pathlib import Path

import yaml

from .policy import ProjectPolicy

HOME = Path(os.environ.get("MYGHOST_HOME", Path.home() / ".myghost"))
DEFAULT_PROJECT = "_default"


@dataclass
class TelegramConfig:
    # Fallback bot for requests outside every project (optional).
    token: str = ""
    chat_id: int | None = None
    # The commander's personal TG accounts: the only ones whose button
    # presses and commands any bot obeys.
    commander_user_ids: list[int] = field(default_factory=list)


@dataclass
class Config:
    telegram: TelegramConfig = field(default_factory=TelegramConfig)
    host: str = "127.0.0.1"
    port: int = 7788
    decision_timeout: int = 1800  # seconds; then deny
    digest_seconds: int = 60  # batch L0/L1 notices this long
    digest_l0: bool = True  # include silent L0 allows in the digest
    notify_idle: bool = False  # TG message when a session goes idle
    mirror_to_myghost: bool = True
    # Other Macs' MyGhost (over Tailscale): bind beyond loopback and require
    # this token from non-loopback clients. Empty token = loopback only.
    remote_token: str = ""
    # Mirror MyGhost-side chat into the project's TG group.
    sync_chat_to_tg: bool = True


@dataclass
class Project:
    name: str
    paths: list[str]
    # The project's own assistant bot and group.
    tg_token: str = ""
    tg_chat_id: int | None = None
    # Resident assistant (kept running) vs woken on events (P2).
    resident: bool = False
    policy: ProjectPolicy = field(default_factory=ProjectPolicy)

    @property
    def dir(self) -> Path:
        return HOME / "projects" / self.name


def load_config() -> Config:
    path = HOME / "config.yaml"
    raw = yaml.safe_load(path.read_text()) if path.exists() else {}
    raw = raw or {}
    tg = raw.get("telegram") or {}
    token = os.environ.get("GHOST_TG_TOKEN") or tg.get("token") or ""
    chat = os.environ.get("GHOST_TG_CHAT") or tg.get("chat_id")
    return Config(
        telegram=TelegramConfig(
            token=str(token),
            chat_id=int(chat) if chat not in (None, "") else None,
            commander_user_ids=[int(u) for u in
                                (tg.get("commander_user_ids") or tg.get("allowed_user_ids") or [])],
        ),
        host=raw.get("host", "127.0.0.1"),
        port=int(raw.get("port", 7788)),
        decision_timeout=int(raw.get("decision_timeout", 1800)),
        digest_seconds=int(raw.get("digest_seconds", 60)),
        digest_l0=bool(raw.get("digest_l0", True)),
        notify_idle=bool(raw.get("notify_idle", False)),
        remote_token=str((raw.get("remote") or {}).get("token") or ""),
        sync_chat_to_tg=bool(raw.get("sync_chat_to_tg", True)),
    )


class Projects:
    """Project registry, re-read when a project.yaml changes on disk."""

    def __init__(self):
        self._lock = threading.Lock()
        self._projects: dict[str, Project] = {}
        self._mtimes: dict[str, float] = {}
        self.reload()

    def reload(self) -> None:
        root = HOME / "projects"
        root.mkdir(parents=True, exist_ok=True)
        found: dict[str, Project] = {}
        mtimes: dict[str, float] = {}
        for yml in sorted(root.glob("*/project.yaml")):
            name = yml.parent.name
            try:
                raw = yaml.safe_load(yml.read_text()) or {}
            except yaml.YAMLError:
                continue
            mtimes[str(yml)] = yml.stat().st_mtime
            pol = raw.get("policy") or {}
            tg = raw.get("telegram") or {}
            paths = [os.path.expanduser(p) for p in raw.get("paths") or []]
            found[name] = Project(
                name=raw.get("name", name),
                paths=paths,
                tg_token=str(tg.get("token") or ""),
                tg_chat_id=int(tg["chat_id"]) if tg.get("chat_id") not in (None, "") else None,
                resident=bool(raw.get("resident", False)),
                policy=ProjectPolicy(
                    root_paths=paths,
                    allow=list(pol.get("allow") or []),
                    deny=list(pol.get("deny") or []),
                    l0=list(pol.get("l0") or []),
                    l1=list(pol.get("l1") or []),
                    l3=list(pol.get("l3") or []),
                ),
            )
        default = found.get(DEFAULT_PROJECT) or Project(DEFAULT_PROJECT, [])
        found[DEFAULT_PROJECT] = default
        for p in found.values():
            p.dir.mkdir(parents=True, exist_ok=True)
            p.policy.allow = sorted(set(p.policy.allow) | set(load_always_allow(p)))
        with self._lock:
            self._projects = found
            self._mtimes = mtimes

    def maybe_reload(self) -> None:
        root = HOME / "projects"
        current = {str(y): y.stat().st_mtime for y in root.glob("*/project.yaml")}
        current.update({str(a): a.stat().st_mtime for a in root.glob("*/always_allow.json")})
        if current != getattr(self, "_seen", None):
            self._seen = current
            self.reload()

    def all(self) -> list[Project]:
        with self._lock:
            return list(self._projects.values())

    def get(self, name: str) -> Project:
        with self._lock:
            return self._projects.get(name) or self._projects[DEFAULT_PROJECT]

    def match(self, cwd: str) -> Project:
        """The project whose path is the longest prefix of cwd."""
        real = os.path.realpath(cwd or "")
        best, best_len = None, -1
        with self._lock:
            for p in self._projects.values():
                for path in p.paths:
                    root = os.path.realpath(path).rstrip("/")
                    if (real == root or real.startswith(root + "/")) and len(root) > best_len:
                        best, best_len = p, len(root)
            return best or self._projects[DEFAULT_PROJECT]


def load_always_allow(p: Project) -> list[str]:
    f = p.dir / "always_allow.json"
    try:
        return list(json.loads(f.read_text()))
    except (OSError, ValueError):
        return []


def add_always_allow(p: Project, pattern: str) -> None:
    rules = load_always_allow(p)
    if pattern not in rules:
        rules.append(pattern)
        f = p.dir / "always_allow.json"
        tmp = f.with_suffix(".tmp")
        tmp.write_text(json.dumps(rules, ensure_ascii=False, indent=2))
        tmp.replace(f)
    if pattern not in p.policy.allow:
        p.policy.allow.append(pattern)
