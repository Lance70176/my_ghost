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


class Tools:
    def __init__(self, broker, assistants, bots_for):
        self.broker = broker
        self.assistants = assistants
        self.bots_for = bots_for  # project name -> Bot or None

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
