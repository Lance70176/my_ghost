"""The tools a project assistant can call (served to it by hooks/ghost_tools.py,
an MCP stdio server that forwards each call here).

Read-only by design for phase 2: the only things a tool can change are the
assistant's own memory (state.md), its reports, a question put to the
commander, and a message to its own project's Telegram group.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import time
from pathlib import Path

from .policy import redact

TRANSCRIPTS = Path(os.path.expanduser("~/.claude/projects"))
JOBS = Path(os.path.expanduser("~/.claude/jobs"))
# Claude Code background job states, as the agent list shows them.
JOB_STATE = {"working": "執行中", "done": "完成", "idle": "完成", "blocked": "等你",
             "awaiting_input": "等你", "needs_input": "等你", "waiting": "等你", "failed": "失敗",
             "error": "失敗", "stopped": "已停止"}


# How a background job's own state reads as a tab status.
JOB_STATUS = {"working": "running", "blocked": "waiting", "awaiting_input": "waiting",
              "needs_input": "waiting", "waiting": "waiting"}
_job_cache: tuple[float, list] = (0.0, [])
_transcript_cache: dict[str, Path] = {}


def _jobs() -> list[tuple[str, str, str]]:
    """(session id, running | waiting | done, cwd) for every Claude Code
    background job, from its state.json (what the agent list shows).
    Cached 5 s."""
    global _job_cache
    now = time.time()
    if now - _job_cache[0] < 5:
        return _job_cache[1]
    out = []
    for f in JOBS.glob("*/state.json") if JOBS.exists() else []:
        try:
            d = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        out.append((str(d.get("sessionId") or ""), JOB_STATUS.get(str(d.get("state") or ""), "done"),
                    str(d.get("originCwd") or d.get("cwd") or "")))
    _job_cache = (now, out)
    return out


def job_states() -> dict[str, str]:
    """session id -> running | waiting | done, for background jobs."""
    return {sid: st for sid, st, _ in _jobs() if sid}


def jobs_status_under(cwd: str) -> str | None:
    """For an agent view (the screen listing background jobs): waiting if
    any job started under `cwd` needs you, running if any is working,
    done if they've all finished; None if there are none."""
    states = {st for _, st, c in _jobs() if cwd and _under(c, [cwd])}
    for st in ("waiting", "running", "done"):
        if st in states:
            return st
    return None


def transcript_age(session_id: str) -> float | None:
    """Seconds since the conversation's transcript was last written."""
    f = _transcript_cache.get(session_id)
    if f is None or not f.exists():
        hits = list(TRANSCRIPTS.glob(f"*/{session_id}.jsonl")) if session_id else []
        if not hits:
            return None
        f = _transcript_cache[session_id] = hits[0]
    try:
        return time.time() - f.stat().st_mtime
    except OSError:
        return None


def _under(path: str, roots: list[str]) -> bool:
    if not path:
        return False
    p = os.path.realpath(path)
    for r in roots:
        r = os.path.realpath(os.path.expanduser(r)).rstrip("/")
        if p == r or p.startswith(r + "/"):
            return True
    return False


def list_jobs(project_paths: list[str], exclude_session: str = "") -> list[dict]:
    """The project's Claude Code conversations as its agent list knows them
    (~/.claude/jobs/<id>/state.json): name, state, latest progress."""
    out = []
    if not JOBS.exists() or not project_paths:
        return out
    for f in JOBS.glob("*/state.json"):
        try:
            d = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        cwd = d.get("cwd") or d.get("originCwd") or ""
        if not (_under(cwd, project_paths) or _under(d.get("worktreePath") or "", project_paths)):
            continue
        if exclude_session and d.get("sessionId") == exclude_session:
            continue
        state = str(d.get("state") or "")
        intent = str(d.get("displayIntent") or d.get("intent") or "").strip().splitlines()
        out.append({
            "id": f.parent.name,
            "name": d.get("name") or (intent[0][:60] if intent else f.parent.name),
            "state": state,
            "state_label": JOB_STATE.get(state, state),
            "detail": redact(str(d.get("detail") or "")[:400]),
            "intent": redact(intent[0][:200]) if intent else "",
            "session_id": d.get("sessionId") or "",
            "cwd": cwd,
            "branch": d.get("worktreeBranch") or "",
            "created_at": d.get("createdAt") or "",
            "updated_at": d.get("updatedAt") or "",
        })
    out.sort(key=lambda j: j["updated_at"], reverse=True)
    return out
SHARE = shutil.which("share") or os.path.expanduser("~/.local/bin/share")


def _encode(path: str) -> str:
    """How Claude Code names a project's transcript folder."""
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def _text(content) -> str:
    if isinstance(content, str):
        return content
    out = []
    for b in content or []:
        if isinstance(b, dict) and b.get("type") == "text":
            out.append(b.get("text", ""))
    return "\n".join(out)


def _transcripts(project_paths: list[str], days: float) -> list[Path]:
    prefixes = [_encode(os.path.realpath(p)) for p in project_paths]
    cutoff = time.time() - days * 86400
    found = []
    if not TRANSCRIPTS.exists():
        return found
    for d in TRANSCRIPTS.iterdir():
        if d.is_dir() and any(d.name == p or d.name.startswith(p + "-") for p in prefixes):
            for f in d.glob("*.jsonl"):
                try:
                    if f.stat().st_mtime >= cutoff:
                        found.append(f)
                except OSError:
                    continue
    return sorted(found, key=lambda f: -f.stat().st_mtime)


def _summarize(f: Path) -> dict:
    title = ai_title = first_prompt = last_reply = cwd = branch = ""
    n_user = 0
    with open(f, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            t = d.get("type")
            if t == "custom-title":
                title = d.get("customTitle") or title
            elif t == "ai-title":
                ai_title = d.get("aiTitle") or ai_title
            elif t == "user" and not d.get("isSidechain"):
                txt = _text((d.get("message") or {}).get("content"))
                if txt and not txt.startswith("<") and "tool_result" not in str(d.get("message", ""))[:200]:
                    n_user += 1
                    first_prompt = first_prompt or txt
                cwd = d.get("cwd") or cwd
                branch = d.get("gitBranch") or branch
            elif t == "assistant" and not d.get("isSidechain"):
                txt = _text((d.get("message") or {}).get("content"))
                if txt.strip():
                    last_reply = txt
    return {
        "session_id": f.stem, "title": title or ai_title or first_prompt[:60],
        "cwd": cwd, "branch": branch, "updated": time.strftime("%m-%d %H:%M", time.localtime(f.stat().st_mtime)),
        "user_messages": n_user, "first_prompt": redact(first_prompt[:300]),
        "last_reply": redact(last_reply[-600:]),
    }


JOB_ID = re.compile(r"^[0-9a-f]{8}$")
TMUX = shutil.which("tmux") or "/opt/homebrew/bin/tmux"
CLAUDE_BIN = shutil.which("claude") or "/opt/homebrew/bin/claude"
ATTACH_PREFIX = "ghostattach_"
_attach_used: dict[str, float] = {}


def find_job(project_paths: list[str], job_id: str, exclude_session: str = "") -> dict | None:
    """A job of this project, or None — the only jobs MyGhost may read or type into."""
    if not JOB_ID.match(job_id or ""):
        return None
    return next((j for j in list_jobs(project_paths, exclude_session) if j["id"] == job_id), None)


def job_transcript(job: dict) -> Path | None:
    try:
        state = json.loads((JOBS / job["id"] / "state.json").read_text())
    except (OSError, ValueError):
        return None
    p = state.get("linkScanPath")
    if p and Path(p).exists():
        return Path(p)
    sid = job.get("session_id")
    hits = list(TRANSCRIPTS.glob(f"*/{sid}.jsonl")) if sid else []
    return hits[0] if hits else None


def job_messages(job: dict, limit: int = 200) -> list[dict]:
    """The conversation as you'd read it: your messages, its replies, and one
    line per tool it ran."""
    f = job_transcript(job)
    if f is None:
        return []
    out = []
    with open(f, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            t = d.get("type")
            if t not in ("user", "assistant") or d.get("isSidechain"):
                continue
            content = (d.get("message") or {}).get("content")
            ts = d.get("timestamp", "")
            if t == "user":
                txt = _text(content).strip()
                if txt and not txt.startswith("<"):
                    out.append({"role": "user", "text": redact(txt[:4000]), "ts": ts})
                continue
            for b in content or []:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "text" and b.get("text", "").strip():
                    out.append({"role": "assistant", "text": redact(b["text"][:6000]), "ts": ts})
                elif b.get("type") == "tool_use":
                    inp = b.get("input") or {}
                    arg = next((str(inp[k]) for k in ("command", "file_path", "pattern", "description", "url")
                                if inp.get(k)), "")
                    out.append({"role": "tool", "text": redact(f"{b.get('name', '')}: {arg[:160]}"), "ts": ts})
    # Number by position in the whole conversation, then keep the tail: an
    # id must keep meaning the same message as older ones drop off.
    for i, m in enumerate(out):
        m["i"] = i
    return out[-limit:]


def _tmux(*args: str, timeout: float = 5) -> subprocess.CompletedProcess:
    return subprocess.run([TMUX, *args], capture_output=True, text=True, timeout=timeout)


def job_send(job: dict, text: str) -> str:
    """Type a message into a background conversation, the way you would in
    `claude attach`: a hidden tmux window keeps it attached, the text goes in
    as a paste (so line breaks stay inside one message), then Return."""
    name = ATTACH_PREFIX + job["id"]
    if _tmux("has-session", "-t", name).returncode != 0:
        cwd = job.get("cwd") or os.path.expanduser("~")
        r = _tmux("new-session", "-d", "-s", name, "-x", "200", "-y", "50", "-c", cwd,
                  f"{CLAUDE_BIN} attach {job['id']}")
        if r.returncode != 0:
            return f"開不了這個對話：{r.stderr.strip()[:200]}"
        # Wait for the input prompt.
        for _ in range(60):
            time.sleep(0.25)
            screen = _tmux("capture-pane", "-p", "-t", name).stdout
            if "❯" in screen:
                break
        else:
            return "對話還沒準備好，請稍後再試一次。"
    buf = f"ghost_{job['id']}"
    r = _tmux("set-buffer", "-b", buf, "--", text)
    if r.returncode != 0:
        return f"送不出去：{r.stderr.strip()[:200]}"
    _tmux("paste-buffer", "-p", "-d", "-b", buf, "-t", name)
    time.sleep(0.3)
    _tmux("send-keys", "-t", name, "Enter")
    _attach_used[name] = time.time()
    return ""


def close_idle_attachments(max_idle: float = 1800) -> None:
    """Hidden `claude attach` windows unused for a while are closed (the
    conversation itself keeps running)."""
    out = _tmux("list-sessions", "-F", "#{session_name}").stdout.split()
    now = time.time()
    for name in out:
        if name.startswith(ATTACH_PREFIX):
            last = _attach_used.setdefault(name, now)
            if now - last > max_idle:
                _tmux("kill-session", "-t", name)
                _attach_used.pop(name, None)


class Tools:
    def __init__(self, broker, assistants, bots_for, accounts=None, sources=None, dispatcher=None,
                 helpdesk=None):
        self.broker = broker
        self.assistants = assistants
        self.bots_for = bots_for  # project name -> Bot or None
        self.accounts = accounts if accounts is not None else {}  # project name -> AccountWatcher
        self.sources = sources  # Sources (requirement sources), or None
        self.dispatcher = dispatcher  # Dispatcher, or None
        self.helpdesk = helpdesk  # HelpDesk, or None

    def call(self, project: str, name: str, args: dict) -> str:
        fn = getattr(self, "t_" + name, None)
        if fn is None:
            return f"沒有這個工具：{name}"
        return fn(self.broker.projects.get(project), args or {})

    # ------------------------------------------------------------------ tools

    def t_ask_decision(self, p, args) -> str:
        question = str(args.get("question") or "").strip()
        options = args.get("options") or []
        if not question or len(options) < 2:
            return "需要 question 和至少兩個 options。"
        card = args.get("card_id") or None
        if card and self.broker.get(card) is None:
            card = None  # already decided elsewhere; still ask, but don't link
        a = self.assistants.get(p.name)
        c = self.broker.create_choice(p.name, question, options, card_id=card,
                                      session_id=a.meta.get("session_id", ""))
        return (f"已把選擇題送給他（id={c.id}），在 MyGhost 和 TG 都看得到。不要等待，先結束這一輪；"
                "他選好後你會收到一則新訊息告訴你選了什麼。")

    def t_read_state(self, p, args) -> str:
        f = p.dir / "state.md"
        return f.read_text(encoding="utf-8") if f.exists() else "（記憶是空的：還沒寫過 state.md）"

    def t_update_state(self, p, args) -> str:
        content = str(args.get("content") or "")
        if not content.strip():
            return "content 是空的，沒有更新。"
        f = p.dir / "state.md"
        tmp = f.with_suffix(".tmp")
        tmp.write_text(redact(content), encoding="utf-8")
        tmp.replace(f)
        return f"已更新記憶（{len(content)} 字）。"

    def t_list_workers(self, p, args) -> str:
        days = float(args.get("days") or 2)
        own = self.assistants.get(p.name).meta.get("session_id")
        live = {s["session_id"]: s for s in self.broker.list_sessions()}
        # Claude Code's own agent list first: it has the names and states the
        # commander sees.
        jobs = list_jobs(p.paths, exclude_session=own)
        if jobs:
            for j in jobs:
                j["pending_decisions"] = sum(1 for x in self.broker.pending.values()
                                             if x.session_id == j["session_id"])
            return json.dumps(jobs, ensure_ascii=False, indent=1)
        rows = []
        for f in _transcripts(p.paths, days)[:40]:
            if f.stem == own:
                continue
            s = _summarize(f)
            st = live.get(s["session_id"])
            s["status"] = st["status"] if st else "unknown"
            s["tab"] = st["tab_title"] if st else ""
            s["pending_decisions"] = sum(1 for x in self.broker.pending.values() if x.session_id == s["session_id"])
            rows.append(s)
        if not rows:
            return f"最近 {days:g} 天沒有工作對話。"
        return json.dumps(rows, ensure_ascii=False, indent=1)

    def t_read_worker_log(self, p, args) -> str:
        sid = str(args.get("session_id") or "")
        limit = min(int(args.get("max_messages") or 30), 120)
        files = [f for f in _transcripts(p.paths, 60) if f.stem == sid]
        if not files:
            return f"找不到這個專案的工作對話 {sid}。"
        msgs = []
        with open(files[0], encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if d.get("type") not in ("user", "assistant") or d.get("isSidechain"):
                    continue
                txt = _text((d.get("message") or {}).get("content")).strip()
                if not txt or txt.startswith("<"):
                    continue
                who = "他" if d["type"] == "user" else "工作對話"
                msgs.append(f"[{who}] {txt[:1200]}")
        return redact("\n\n".join(msgs[-limit:]))

    def t_share_report(self, p, args) -> str:
        path = Path(os.path.expanduser(str(args.get("path") or "")))
        if not path.is_file() or path.suffix.lower() not in (".html", ".htm", ".pdf"):
            return "path 要指向一個存在的 .html 或 .pdf 檔。"
        reports = p.dir / "reports"
        reports.mkdir(exist_ok=True)
        local = path if path.parent == reports else reports / path.name
        if local != path:
            shutil.copy2(path, local)
        try:
            out = subprocess.run([SHARE, str(local)], capture_output=True, text=True, timeout=120).stdout
        except (OSError, subprocess.SubprocessError) as e:
            return f"分享失敗：{e}；報告已存在 {local}"
        url = next((l.strip() for l in out.splitlines() if l.strip().startswith("http")), "")
        return f"連結：{url}\n本機存檔：{local}" if url else f"分享失敗：{out[-300:]}；報告已存在 {local}"

    def t_tg_send(self, p, args) -> str:
        text = str(args.get("text") or "").strip()
        if not text:
            return "text 是空的。"
        bot = self.bots_for(p.name)
        if bot is None:
            return "這個專案還沒設定 TG bot，訊息沒有送出。"
        bot.jobs.put((bot._send_notice, (p, redact(text))))
        return "已送到專案群組。"

    def t_draft_reply(self, p, args) -> str:
        w = self.accounts.get(p.name)
        if w is None:
            return "這個專案沒有設定工作帳號。"
        return w.draft(str(args.get("ref") or ""), str(args.get("text") or ""), str(args.get("note") or ""))

    def t_read_tg_chat(self, p, args) -> str:
        w = self.accounts.get(p.name)
        if w is None:
            return "這個專案沒有設定工作帳號。"
        return w.history(str(args.get("ref") or ""), int(args.get("limit") or 20))

    def t_clickup_task(self, p, args) -> str:
        tid = str(args.get("task_id") or "").strip()
        src = self.sources.find(p.name, tid) if self.sources else None
        if src is None:
            return "這個專案沒有設定 ClickUp 來源，或這張單不在追蹤範圍內。"
        try:
            return src.task(tid)
        except Exception as e:
            return f"讀不到這張單：{e}"

    def t_clickup_done(self, p, args) -> str:
        tid = str(args.get("task_id") or "").strip()
        src = self.sources.find(p.name, tid) if self.sources else None
        if src is None:
            return "這個專案沒有設定 ClickUp 來源，或這張單不在追蹤範圍內。"
        try:
            return src.done(tid, str(args.get("comment") or ""))
        except Exception as e:
            return f"沒有改成功：{e}"

    def t_refresh_sources(self, p, args) -> str:
        srcs = (self.sources.by_project.get(p.name) if self.sources else None) or []
        if not srcs:
            return "這個專案沒有設定需求來源。"
        out = []
        for s in srcs:
            if not s.lock.acquire(blocking=False):
                out.append(f"{s.name}：正在整理中")
                continue
            try:
                out.append(f"{s.name}：{s.run()}")
            finally:
                s.lock.release()
        return "\n".join(out)

    def t_propose_dispatch(self, p, args) -> str:
        if self.dispatcher is None:
            return "派工沒有啟用。"
        return self.dispatcher.propose(p, str(args.get("title") or ""), str(args.get("repo") or ""),
                                       str(args.get("task") or ""), str(args.get("branch") or ""),
                                       str(args.get("base") or ""), str(args.get("source") or ""))

    def t_message_worker(self, p, args) -> str:
        if self.dispatcher is None:
            return "派工沒有啟用。"
        return self.dispatcher.message(p, str(args.get("dispatch_id") or ""), str(args.get("text") or ""))

    def t_list_dispatches(self, p, args) -> str:
        return self.dispatcher.list_for(p) if self.dispatcher else "派工沒有啟用。"

    def t_reply_worker(self, p, args) -> str:
        if self.helpdesk is None:
            return "求助沒有啟用。"
        return self.helpdesk.reply(p.name, str(args.get("help_id") or ""), str(args.get("text") or ""))
