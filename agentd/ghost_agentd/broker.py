"""The decision broker: pending permission requests, session status, and the
append-only logs.

A hook thread calls `request_permission()` and blocks until someone decides
(TG, MyGhost, the phone page) or the timeout denies it. Deciding from any
surface resolves the one shared `Pending`, and every listener is told so the
other surfaces can mark their card handled.
"""

from __future__ import annotations

import json
import secrets
import threading
import time
from dataclasses import asdict, dataclass, field, fields
from typing import Protocol

from . import config as cfgmod
from .config import Config, Project, Projects
from .policy import L0, L1, L2, L3, LEVEL_NAMES, Grade, describe_request, grade


class Listener(Protocol):
    def on_pending(self, p: "Pending") -> None: ...
    def on_update(self, p: "Pending") -> None: ...
    def on_notice(self, project: Project, text: str) -> None: ...
    # Optional: a choice was answered / a card was taken into discussion.
    # def on_choice(self, p: "Pending", option: dict) -> None: ...
    # def on_discuss(self, p: "Pending") -> None: ...


@dataclass
class Pending:
    id: str
    key: str  # the hook's own request id; a retried hook re-joins its card
    project: str
    session_id: str
    tmux_session: str
    tab_title: str
    cwd: str
    tool_name: str
    tool_input: dict
    summary: str
    level: int
    reason: str
    always_pattern: str | None
    created: float
    deadline: float
    state: str = "pending"  # pending | confirming | allowed | denied | expired
    decided_by: str = ""
    deny_message: str = ""
    always_added: str | None = None
    tg_message_id: int | None = None
    resolved_at: float = 0.0
    # Taken into a discussion ("💬 討論"): never times out, still decidable.
    discussing: bool = False
    # "permission" (a hook is waiting) or "choice" (an assistant's question:
    # options to pick from, nothing blocked, never times out).
    kind: str = "permission"
    # choice: [{"label": str, "action": "allow"|"deny"|None}]
    options: list = field(default_factory=list)
    # choice about a permission card: picking an option with an action
    # applies it to that card — the assistant itself can't decide anything.
    card_id: str | None = None
    chosen: int | None = None
    # A reply card (P3): a choice whose first option sends `text` from the
    # project's work account to the chat a message came from —
    # {ref, chat_id, msg_id, chat, sender, text, account}.
    reply: dict | None = None
    # A dispatch card (P3): option 0 starts the proposed work — {id}.
    dispatch: dict | None = None
    event: threading.Event = field(default_factory=threading.Event, repr=False)

    @property
    def open(self) -> bool:
        return self.state in ("pending", "confirming")

    def public(self) -> dict:
        d = {f.name: getattr(self, f.name) for f in fields(self) if f.name != "event"}
        d["level_name"] = LEVEL_NAMES[self.level]
        d["can_always"] = self.level == L2 and bool(self.always_pattern)
        d["remaining"] = -1 if (self.discussing or self.kind == "choice") \
            else max(0, int(self.deadline - time.time()))
        if self.kind == "choice":
            d["level_name"] = "選擇"
            d["can_always"] = False
        return d


@dataclass
class Session:
    session_id: str
    project: str
    cwd: str
    tmux_session: str = ""
    tab_title: str = ""
    status: str = "running"  # running | waiting | done | ended
    updated: float = 0.0
    last_message: str = ""
    # The agent view (the screen listing background jobs): its status is
    # its jobs' status, not its own last event.
    agent_view: bool = False


def _append(path, record: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


class Broker:
    def __init__(self, cfg: Config, projects: Projects):
        self.cfg = cfg
        self.projects = projects
        self.lock = threading.RLock()
        self.pending: dict[str, Pending] = {}
        self.by_key: dict[str, Pending] = {}
        self.sessions: dict[str, Session] = {}
        self.listeners: list[Listener] = []
        self.paused_until = 0.0
        # Which surfaces can show a card right now: "tg" when configured, and
        # MyGhost / the phone page while they keep polling /api/state.
        self.client_seen: dict[str, float] = {}
        self.tg_projects: set[str] = set()  # projects whose bot has a group
        # project -> list of (level, summary, tab) waiting for the digest
        self._digest: dict[str, list[tuple[int, str, str]]] = {}
        self._digest_due: dict[str, float] = {}
        self.version = 0  # bumped on every change; clients long-poll on it
        self._changed = threading.Condition(self.lock)
        self._load_sessions()

    # ------------------------------------------------------------------ util

    def _bump(self) -> None:
        self.version += 1
        self._changed.notify_all()

    def wait_change(self, since: int, timeout: float) -> int:
        with self._changed:
            if self.version == since:
                self._changed.wait(timeout)
            return self.version

    def _emit(self, method: str, *args) -> None:
        for l in list(self.listeners):
            fn = getattr(l, method, None)
            if fn is None:
                continue
            try:
                fn(*args)
            except Exception as e:  # a broken TG must never block a decision
                log(f"listener {type(l).__name__}.{method} failed: {e!r}")

    def _session_file(self):
        return cfgmod.HOME / "sessions.json"

    def _load_sessions(self) -> None:
        try:
            raw = json.loads(self._session_file().read_text())
            for s in raw:
                self.sessions[s["session_id"]] = Session(**s)
        except (OSError, ValueError, TypeError):
            pass

    def _save_sessions(self) -> None:
        cutoff = time.time() - 3 * 86400
        live = [asdict(s) for s in self.sessions.values() if s.updated > cutoff]
        f = self._session_file()
        tmp = f.with_suffix(".tmp")
        tmp.write_text(json.dumps(live, ensure_ascii=False))
        tmp.replace(f)

    def _touch_session(self, payload: dict, project: Project, status: str | None = None,
                       message: str | None = None) -> Session:
        sid = payload.get("session_id") or "unknown"
        s = self.sessions.get(sid)
        if s is None:
            s = Session(session_id=sid, project=project.name, cwd=payload.get("cwd", ""))
            self.sessions[sid] = s
        s.project = project.name
        s.cwd = payload.get("cwd") or s.cwd
        s.tmux_session = payload.get("tmux_session") or s.tmux_session
        s.tab_title = payload.get("tab_title") or s.tab_title
        if status:
            s.status = status
        if message is not None:
            s.last_message = message[:300]
        s.updated = time.time()
        self._save_sessions()
        return s

    def seen(self, client: str) -> None:
        self.client_seen[client] = time.time()

    def surfaces(self, project: str | None = None) -> list[str]:
        now = time.time()
        live = [c for c, t in self.client_seen.items() if now - t < 90]
        tg = project in self.tg_projects if project else bool(self.tg_projects)
        return (["tg"] if tg else []) + sorted(live)

    # ------------------------------------------------------------ permission

    def request_permission(self, payload: dict) -> dict:
        """Called from the hook. Blocks until decided; returns
        {"behavior": "allow"} or {"behavior": "deny", "message": ...}."""
        self.projects.maybe_reload()
        project = self.projects.match(payload.get("cwd", ""))
        tool = payload.get("tool_name", "")
        tool_input = payload.get("tool_input") or {}
        key = str(payload.get("request_key") or secrets.token_hex(8))

        with self.lock:
            existing = self.by_key.get(key)
            # Hold only when TG or MyGhost can show the card. The phone page is
            # the fallback for a card already held, not a reason to hold one:
            # a browser tab left open would otherwise keep every prompt out of
            # the terminal.
            if existing is None and not {"tg", "myghost"} & set(self.surfaces(project.name)):
                # Nobody could see a card: let Claude Code ask in the terminal
                # rather than hang until the timeout.
                return {"behavior": "ask", "message": "no decision surface online"}
            if existing is None:
                g: Grade = grade(tool, tool_input, payload.get("cwd", ""), project.policy)
                summary = describe_request(tool, tool_input)
                now = time.time()
                p = Pending(
                    id=secrets.token_hex(4), key=key, project=project.name,
                    session_id=payload.get("session_id", ""),
                    tmux_session=payload.get("tmux_session", ""),
                    tab_title=payload.get("tab_title", ""),
                    cwd=payload.get("cwd", ""), tool_name=tool,
                    tool_input=tool_input, summary=summary, level=g.level,
                    reason=g.reason, always_pattern=g.always_pattern,
                    created=now, deadline=now + self.cfg.decision_timeout,
                )
                self.by_key[key] = p
                _append(project.dir / "events.jsonl", {
                    "ts": now, "type": "permission_request", "id": p.id,
                    "session_id": p.session_id, "tab": p.tab_title, "tool": tool,
                    "summary": summary, "level": LEVEL_NAMES[g.level], "reason": g.reason,
                })
                if g.level <= L1:
                    self._resolve(p, "allowed", f"rule:{LEVEL_NAMES[g.level]}")
                    self._queue_digest(project, g.level, p)
                else:
                    self.pending[p.id] = p
                    self._touch_session(payload, project, status="waiting",
                                        message=f"等待授權：{summary}")
                    self._bump()
                    self._emit("on_pending", p)
            else:
                p = existing
                self._touch_session(payload, project)

        while not p.event.is_set():
            # A request under discussion has no deadline; re-check hourly in
            # case the discussion flag is ever cleared.
            remaining = 3600.0 if p.discussing else p.deadline - time.time()
            if p.event.wait(timeout=max(0.0, remaining)):
                break
            with self.lock:
                if p.open and not p.discussing and time.time() >= p.deadline:
                    p.deny_message = "逾時沒有人回應，預設拒絕。"
                    self._resolve(p, "expired", "timeout")
        return self.result(p)

    @staticmethod
    def result(p: Pending) -> dict:
        if p.state == "allowed":
            return {"behavior": "allow", "id": p.id}
        msg = p.deny_message or "使用者拒絕了這個操作。"
        return {"behavior": "deny", "message": msg, "id": p.id}

    def create_choice(self, project: str, question: str, options: list, card_id: str | None = None,
                      session_id: str = "") -> Pending:
        """An assistant's multiple-choice question. Options with an action
        ("allow"/"deny") decide card_id when picked."""
        clean = []
        for o in options[:8]:
            o = o if isinstance(o, dict) else {"label": str(o)}
            act = o.get("action") if o.get("action") in ("allow", "deny") else None
            clean.append({"label": str(o.get("label", ""))[:80], "action": act if card_id else None})
        now = time.time()
        with self.lock:
            p = Pending(
                id=secrets.token_hex(4), key="choice-" + secrets.token_hex(6), project=project,
                session_id=session_id, tmux_session="", tab_title=f"{project} 助手", cwd="",
                tool_name="ask_decision", tool_input={}, summary=question[:900],
                level=L1, reason="助手的選擇題", always_pattern=None,
                created=now, deadline=now + 30 * 86400, kind="choice", options=clean, card_id=card_id,
            )
            self.pending[p.id] = p
            self.by_key[p.key] = p
            self._bump()
            self._emit("on_pending", p)
        return p

    def create_reply(self, project: str, summary: str, reply: dict, options: list[str]) -> Pending:
        """A drafted reply to a message the work account got. Sending it is
        the commander's pick of option 0; nothing sends it otherwise."""
        now = time.time()
        with self.lock:
            p = Pending(
                id=secrets.token_hex(4), key="reply-" + secrets.token_hex(6), project=project,
                session_id="", tmux_session="", tab_title=f"{project} 助手", cwd="",
                tool_name="draft_reply", tool_input={}, summary=summary[:3000],
                level=L2, reason="用工作帳號回覆外部訊息", always_pattern=None,
                created=now, deadline=now + 30 * 86400, kind="choice",
                options=[{"label": o, "action": None} for o in options], reply=reply,
            )
            self.pending[p.id] = p
            self.by_key[p.key] = p
            self._bump()
            self._emit("on_pending", p)
        return p

    def create_dispatch(self, project: str, summary: str, dispatch: dict, options: list[str]) -> Pending:
        """Proposed work: starting it is the commander's pick of option 0."""
        now = time.time()
        with self.lock:
            p = Pending(
                id=secrets.token_hex(4), key="dispatch-" + secrets.token_hex(6), project=project,
                session_id="", tmux_session="", tab_title=f"{project} 助手", cwd="",
                tool_name="propose_dispatch", tool_input={}, summary=summary[:4000],
                level=L2, reason="派工：開新的工作對話", always_pattern=None,
                created=now, deadline=now + 30 * 86400, kind="choice",
                options=[{"label": o, "action": None} for o in options], dispatch=dispatch,
            )
            self.pending[p.id] = p
            self.by_key[p.key] = p
            self._bump()
            self._emit("on_pending", p)
        return p

    def bump(self) -> None:
        with self.lock:
            self._bump()

    def dismiss(self, pid: str, by: str) -> bool:
        """Close a card nobody needs any more (answered elsewhere, replaced)
        without it counting as anyone's answer."""
        with self.lock:
            p = self.pending.get(pid)
            if p is None or not p.open:
                return False
            self._resolve(p, "denied", by)
        return True

    def decide(self, pid: str, action: str, by: str, message: str = "") -> tuple[bool, str]:
        """action: allow | deny | always | confirm | cancel | discuss, or for
        a choice o<N> (pick option N) / deny (dismiss). Returns (ok, why)."""
        card_followup = None
        with self.lock:
            p = self.pending.get(pid)
            if p is None or not p.open:
                return False, "這個請求已經處理過了"
            if p.kind == "choice":
                if action == "deny":
                    self._resolve(p, "denied", by)
                    self._emit("on_choice", p, None)
                    return True, "已略過這個問題"
                if not action.startswith("o") or not action[1:].isdigit() \
                        or int(action[1:]) >= len(p.options):
                    return False, "請選一個選項"
                p.chosen = int(action[1:])
                opt = p.options[p.chosen]
                p.deny_message = ""
                self._resolve(p, "allowed", by)
                self._emit("on_choice", p, opt)
                if not (opt.get("action") and p.card_id):
                    return True, f"已選擇：{opt['label']}"
                card_followup = (p.card_id, opt["action"])
        if card_followup:
            ok, why = self.decide(card_followup[0], card_followup[1], by)
            return True, f"已選擇；授權卡：{why}"
        with self.lock:
            p = self.pending.get(pid)
            if p is None or not p.open:
                return False, "這個請求已經處理過了"
            if action == "deny":
                p.deny_message = (f"使用者拒絕（{by}）：{message}" if message
                                  else f"使用者在 {by} 拒絕了這個操作。")
                self._resolve(p, "denied", by)
                return True, "已拒絕"
            if action == "always":
                if p.level != L2 or not p.always_pattern:
                    return False, "這個等級不能設成一律允許"
                cfgmod.add_always_allow(self.projects.get(p.project), p.always_pattern)
                p.always_added = p.always_pattern
                self._resolve(p, "allowed", by)
                return True, f"已同意，之後一律允許 {p.always_pattern}"
            if action == "allow" and p.level >= L3 and p.state == "pending":
                p.state = "confirming"
                self._bump()
                self._emit("on_update", p)
                return True, "L3：請再確認一次"
            if action in ("allow", "confirm"):
                if p.level >= L3 and p.state != "confirming" and action != "confirm":
                    return False, "L3 需要二次確認"
                self._resolve(p, "allowed", by)
                return True, "已同意"
            if action == "discuss":
                if p.discussing:
                    return False, "已經在討論中"
                p.discussing = True
                self._bump()
                self._emit("on_update", p)
                self._emit("on_discuss", p)
                return True, "已標成討論中，不會逾時；決定後再按同意或拒絕"
            if action == "cancel" and p.state == "confirming":
                p.state = "pending"
                self._bump()
                self._emit("on_update", p)
                return True, "已取消確認"
            return False, f"不認得的動作 {action}"

    def _resolve(self, p: Pending, state: str, by: str) -> None:
        p.state = state
        p.decided_by = by
        project = self.projects.get(p.project)
        _append(project.dir / "decisions.jsonl", {
            "ts": time.time(), "id": p.id, "project": p.project,
            "session_id": p.session_id, "tmux_session": p.tmux_session,
            "tab": p.tab_title, "tool": p.tool_name,
            "summary": p.summary, "level": LEVEL_NAMES[p.level], "reason": p.reason,
            "state": state, "by": by, "always_added": p.always_added,
            "discussed": p.discussing, "deny_message": p.deny_message if state != "allowed" else "",
            "kind": p.kind,
            "chosen": p.options[p.chosen]["label"] if p.kind == "choice" and p.chosen is not None else None,
            "reply": {k: p.reply.get(k) for k in ("chat", "sender", "text", "account", "private", "original", "note")}
            if p.reply else None,
            # send | revise | skip | self_reply | replaced
            "outcome": (by if by in ("self_reply", "replaced") else
                        {0: "send", 1: "revise"}.get(p.chosen, "skip")) if p.reply else None,
            "wait_seconds": round(time.time() - p.created, 1),
        })
        was_pending = self.pending.pop(p.id, None) is not None
        p.event.set()
        if was_pending:
            s = self.sessions.get(p.session_id)
            if s is not None and not any(o.session_id == s.session_id for o in self.pending.values()):
                s.status = "running"
                s.last_message = ("已同意：" if state == "allowed" else "已拒絕：") + p.summary[:200]
                s.updated = time.time()
                self._save_sessions()
            self._bump()
            self._emit("on_update", p)
        p.resolved_at = time.time()

    def list_pending(self) -> list[dict]:
        with self.lock:
            return [p.public() for p in sorted(self.pending.values(), key=lambda x: x.created)]

    def list_decisions(self, project: str | None = None, limit: int = 200) -> list[dict]:
        """Newest first, across one project or all of them."""
        names = [project] if project else [p.name for p in self.projects.all()]
        rows: list[dict] = []
        for name in names:
            f = self.projects.get(name).dir / "decisions.jsonl"
            if self.projects.get(name).name != name or not f.exists():
                continue
            with open(f, encoding="utf-8") as fh:
                lines = fh.readlines()[-limit:]
            for line in lines:
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    continue
        with self.lock:
            for r in rows:
                # Records written before tmux_session was logged: recover it
                # from the conversation's last known session.
                if not r.get("tmux_session"):
                    s = self.sessions.get(r.get("session_id", ""))
                    r["tmux_session"] = s.tmux_session if s else ""
        rows.sort(key=lambda r: -r.get("ts", 0))
        return rows[:limit]

    def list_projects(self) -> list[dict]:
        self.projects.maybe_reload()
        out = []
        with self.lock:
            for p in self.projects.all():
                sessions = [s for s in self.sessions.values() if s.project == p.name and s.status != "ended"]
                f = p.dir / "decisions.jsonl"
                from .tools import list_jobs
                jobs = list_jobs(p.paths) if p.paths else []
                out.append({
                    "name": p.name, "resident": p.resident, "paths": p.paths,
                    "jobs": len(jobs),
                    "jobs_working": sum(1 for j in jobs if j["state"] == "working"),
                    "jobs_waiting": sum(1 for j in jobs if j["state_label"] == "等你"),
                    "has_bot": bool(p.tg_token) or (p.name in self.tg_projects),
                    "tg_ready": p.name in self.tg_projects,
                    "pending": sum(1 for x in self.pending.values() if x.project == p.name),
                    "sessions": len(sessions),
                    "waiting": sum(1 for s in sessions if s.status == "waiting"),
                    "running": sum(1 for s in sessions if s.status == "running"),
                    "last_activity": max([s.updated for s in sessions] + [f.stat().st_mtime if f.exists() else 0]),
                })
        # Resident first, then the busiest.
        out.sort(key=lambda r: (not r["resident"], r["name"] == "_default", -r["pending"], -r["last_activity"]))
        return out

    def get(self, pid: str) -> Pending | None:
        with self.lock:
            return self.pending.get(pid)

    # ---------------------------------------------------------------- events

    def hook_event(self, payload: dict) -> None:
        """Notification / Stop / UserPromptSubmit / SessionEnd from the hook."""
        self.projects.maybe_reload()
        project = self.projects.match(payload.get("cwd", ""))
        ev = payload.get("hook_event_name", "")
        with self.lock:
            _append(project.dir / "events.jsonl", {
                "ts": time.time(), "type": ev, "session_id": payload.get("session_id"),
                "tab": payload.get("tab_title"),
                "notification_type": payload.get("notification_type"),
                "message": (payload.get("message") or payload.get("last_assistant_message") or "")[:500],
            })
            has_pending = any(p.session_id == payload.get("session_id") for p in self.pending.values())
            if ev == "UserPromptSubmit":
                self._touch_session(payload, project, "running", "")
            elif ev == "Stop":
                self._touch_session(payload, project, "waiting" if has_pending else "done",
                                    payload.get("last_assistant_message") or "")
                if payload.get("tmux_session"):
                    self._emit("on_stop", payload["tmux_session"], payload.get("last_assistant_message") or "")
            elif ev == "SessionEnd":
                self._touch_session(payload, project, "ended")
            elif ev == "Notification":
                nt = payload.get("notification_type", "")
                if nt.startswith("agent_"):  # about a background job: an agent view
                    self._touch_session(payload, project).agent_view = True
                if nt == "idle_prompt":
                    s = self._touch_session(payload, project, "waiting" if has_pending else "done")
                    if self.cfg.notify_idle:
                        self._emit("on_notice", project,
                                   f"💤 {s.tab_title or s.session_id[:8]} 在等你輸入")
                elif nt in ("permission_prompt", "elicitation_dialog", "agent_needs_input"):
                    # A prompt the hook didn't take (daemon was down, or a
                    # dialog type the hook can't answer): the user must act.
                    self._touch_session(payload, project, "waiting", payload.get("message", ""))
                else:
                    self._touch_session(payload, project)
            self._bump()

    # A "running" conversation whose transcript hasn't moved this long has
    # stopped (an interrupted turn sends no Stop).
    STALE_RUNNING = 15 * 60

    def _status(self, s: Session, jobs: dict[str, str]) -> str:
        """What the tab badge should say: waiting only when it really needs
        the user, running only while it's really working."""
        from .tools import jobs_status_under, transcript_age
        if any(p.session_id == s.session_id for p in self.pending.values()):
            return "waiting"
        if s.session_id in jobs:  # a background job: its own state is the truth
            return jobs[s.session_id]
        age = transcript_age(s.session_id)
        # An agent view keeps no transcript of its own.
        if s.agent_view or age is None:
            st = jobs_status_under(s.cwd)
            if st is not None:
                return st
        if s.status == "running" and age is not None and age > self.STALE_RUNNING:
            return "done"
        return s.status

    def list_sessions(self) -> list[dict]:
        from .tools import job_states
        jobs = job_states()
        with self.lock:
            out = []
            for s in sorted(self.sessions.values(), key=lambda s: -s.updated):
                if s.status == "ended":
                    continue
                d = asdict(s)
                d["status"] = self._status(s, jobs)
                out.append(d)
            return out

    # ---------------------------------------------------------------- digest

    def _queue_digest(self, project: Project, level: int, p: Pending) -> None:
        if level == L0 and not self.cfg.digest_l0:
            return
        self._digest.setdefault(project.name, []).append((level, p.summary, p.tab_title))
        self._digest_due.setdefault(project.name, time.time() + self.cfg.digest_seconds)

    def flush_digests(self, force: bool = False) -> None:
        with self.lock:
            now = time.time()
            # A resolved key stays ten minutes so a hook retrying after a lost
            # response gets the same answer instead of a fresh card.
            for k in [k for k, p in self.by_key.items() if p.resolved_at and now - p.resolved_at > 600]:
                del self.by_key[k]
            due = [n for n, t in self._digest_due.items() if force or t <= now]
            batches = {n: self._digest.pop(n, []) for n in due}
            for n in due:
                self._digest_due.pop(n, None)
        for name, items in batches.items():
            if not items:
                continue
            l1 = [i for i in items if i[0] == L1]
            l0 = [i for i in items if i[0] == L0]
            lines = []
            if l1:
                lines.append(f"L1 已放行 {len(l1)} 筆（做完通知）：")
                lines += [f"・{tab + '：' if tab else ''}{s[:120]}" for _, s, tab in l1[:10]]
            if l0:
                kinds = sorted({s.split('(')[0].split(' ')[0] for _, s, _ in l0})
                lines.append(f"L0 已自動放行 {len(l0)} 筆（{'、'.join(kinds[:6])}）")
            self._emit("on_notice", self.projects.get(name), "\n".join(lines))


_log_lock = threading.Lock()


def log(msg: str) -> None:
    line = time.strftime("%Y-%m-%d %H:%M:%S ") + msg
    with _log_lock:
        print(line, flush=True)
