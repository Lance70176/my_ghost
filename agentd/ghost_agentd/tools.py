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

from . import config as cfgmod
from .config import DEFAULT_PROJECT
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


def job_remove(job: dict) -> str:
    """Delete a background conversation and its worktree, as `claude rm`
    does from `claude agents` (stopping it if it still runs). It refuses when
    the worktree has work that isn't pushed; that message comes back as is.
    "" when it's gone."""
    _tmux("kill-session", "-t", ATTACH_PREFIX + job["id"])  # our hidden attach, if any
    _attach_used.pop(ATTACH_PREFIX + job["id"], None)
    try:
        r = subprocess.run([CLAUDE_BIN, "rm", job["id"]], capture_output=True, text=True, timeout=90,
                           cwd=job.get("cwd") or os.path.expanduser("~"))
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"刪不掉：{e}"
    if r.returncode == 0:
        return ""
    return (r.stderr.strip() or r.stdout.strip() or f"claude rm 失敗（{r.returncode}）")[:800]


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
                 helpdesk=None, dbquery=None):
        self.broker = broker
        self.assistants = assistants
        self.bots_for = bots_for  # project name -> Bot or None
        self.accounts = accounts if accounts is not None else {}  # project name -> AccountWatcher
        self.sources = sources  # Sources (requirement sources), or None
        self.dispatcher = dispatcher  # Dispatcher, or None
        self.helpdesk = helpdesk  # HelpDesk, or None
        self.dbquery = dbquery  # DBQuery, or None
        # close_cards waiting for the person's OK, by project:
        # {ids, answer, who, seq, at}.
        self.close_offers: dict[str, dict] = {}

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
        if card:
            found = self.broker.find(p.name, card)  # an id, or today's "#3"
            card = found.id if found else None  # decided elsewhere: still ask, don't link
        member, ask_owner = self._card_member(p, args, card)
        a = self.assistants.get(p.name)
        c = self.broker.create_choice(p.name, question, options, card_id=card,
                                      session_id=a.meta.get("session_id", ""), member=member)
        out = (f"已把選擇題送給他（{c.tag}，id={c.id}），在 MyGhost 和 TG 都看得到。提到這張卡時用 {c.tag}。不要等待，先結束這一輪；"
               "他選好後你會收到一則新訊息告訴你選了什麼。" + self._replace(p, args, c.id))
        if member:
            out += f"\n這張卡交給 {member['name']}（負責人已授權對方決定「{self._kind(args)}」），對方和負責人都能按。"
        return out + ask_owner.replace("{tag}", c.tag)

    # ------------------------------------------------- member grants

    def _grants(self, p) -> list[dict]:
        """Kinds of card the owner let a member decide:
        [{id, name, kind, at}] in member_grants.json."""
        try:
            return json.loads((p.dir / "member_grants.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return []

    def _save_grants(self, p, grants: list[dict]) -> None:
        f = p.dir / "member_grants.json"
        tmp = f.with_suffix(".tmp")
        tmp.write_text(json.dumps(grants, ensure_ascii=False, indent=1), encoding="utf-8")
        tmp.replace(f)

    @staticmethod
    def _kind(args) -> str:
        return re.sub(r"\s+", " ", str(args.get("kind") or "")).strip()[:40]

    @staticmethod
    def _same_kind(a: str, b: str) -> bool:
        return re.sub(r"\s+", "", a).lower() == re.sub(r"\s+", "", b).lower()

    def _member(self, p, who: str) -> dict | None:
        """One of the project's members, by user id or name (spaces ignored)."""
        names = cfgmod.member_names(p)
        key = re.sub(r"\s+", "", who)
        for uid, name in names.items():
            if key == str(uid) or (name and key == re.sub(r"\s+", "", name)):
                return {"id": uid, "name": name or str(uid)}
        return None

    def _card_member(self, p, args, card) -> tuple[dict | None, str]:
        """Who a new question is for (args["for_member"]), and what to tell
        the assistant when that member can't press it yet: in a member's own
        turn the card is theirs anyway; otherwise only a kind the owner let
        them decide hands it over, and anything else is the owner's to OK."""
        want = str(args.get("for_member") or "").strip()
        if not want or card:
            return None, ""
        m = self._member(p, want)
        names = "、".join(n or str(i) for i, n in cfgmod.member_names(p).items()) or "（沒有成員）"
        if m is None:
            return None, f"\n找不到成員「{want}」，這張卡只有負責人能按。這個專案的成員：{names}。"
        req = self.broker.requester_of(p.name)
        if req:  # a member's turn: their cards are theirs already
            if req.get("id") != m["id"]:
                return None, f"\n成員那一輪開的卡只會是 {req.get('name')} 的，不能給 {m['name']}。"
            return None, ""
        kind = self._kind(args)
        if kind and any(g["id"] == m["id"] and self._same_kind(g["kind"], kind) for g in self._grants(p)):
            return m, ""
        have = [g["kind"] for g in self._grants(p) if g["id"] == m["id"]]
        return None, (
            f"\n⚠️ {m['name']} 按不到這張卡：負責人還沒授權 {m['name']} 決定「{kind or '（沒帶 kind）'}」這類卡"
            + (f"（目前授權的類型：{'、'.join(have)}；同一類就用一樣的 kind）" if have else "") + "。"
            f"現在就在群組跟 {cfgmod.owner()} 確認：要不要讓 {m['name']} 以後自己決定「{kind or '這類'}」的卡？"
            f"他本人說可以，就用 member_grant（action=add、member={m['name']}、kind、cards=[\"{{tag}}\"]）記下，"
            "這張卡會立刻交給對方，之後同類的卡帶一樣的 for_member＋kind 就直接給對方。他沒同意之前別跟對方說按得到。")

    def t_member_grant(self, p, args) -> str:
        """The owner lets a member decide one kind of card from now on (add),
        takes it back (remove), or asks what's granted (list)."""
        action = str(args.get("action") or "list")
        grants = self._grants(p)
        if action == "list":
            if not grants:
                return "沒有成員授權：成員只能按自己交辦的卡。"
            return "成員可以自己決定的卡：\n" + "\n".join(
                f"• {g['name']}：{g['kind']}（{time.strftime('%m/%d', time.localtime(g['at']))} 授權）" for g in grants)
        if not self._owner_turn(p):
            return "只有負責人本人親自說的那一輪可以改成員授權；成員、工作對話或排程要求的一律不做，先在群組問負責人。"
        m = self._member(p, str(args.get("member") or ""))
        if m is None:
            names = "、".join(n or str(i) for i, n in cfgmod.member_names(p).items()) or "（沒有成員）"
            return f"找不到這位成員。這個專案的成員：{names}（不是成員要先在群組用 /addmember 加入）。"
        kind = self._kind(args)
        if action == "remove":
            keep = [g for g in grants if not (g["id"] == m["id"] and (not kind or self._same_kind(g["kind"], kind)))]
            if len(keep) == len(grants):
                return f"{m['name']} 沒有「{kind}」的授權。" if kind else f"{m['name']} 沒有任何授權。"
            self._save_grants(p, keep)
            return f"已收回 {m['name']} 的授權：{kind or '全部類型'}。已經開出的卡不變。"
        if action != "add":
            return "action 要是 add、remove 或 list。"
        if not kind:
            return "需要 kind：這類卡的名稱（例如「發文文案修改」「排程核准」），之後開同類卡用一樣的 kind。"
        if not any(g["id"] == m["id"] and self._same_kind(g["kind"], kind) for g in grants):
            grants.append({"id": m["id"], "name": m["name"], "kind": kind, "at": time.time()})
            self._save_grants(p, grants)
        out = f"已記住：{m['name']} 以後可以自己決定「{kind}」這類卡。開這類卡時帶 for_member={m['name']}、kind={kind}。"
        cards = args.get("cards") or []
        if isinstance(cards, str):
            cards = [x for x in re.split(r"[,\s、]+", cards) if x]
        if cards:
            done, refused = self.broker.hand_over(p.name, list(cards), m)
            if done:
                out += f"\n已交給 {m['name']}：{'、'.join(done)}（對方現在按得到了，跟對方說一聲）。"
            if refused:
                out += "\n沒交出去：" + "；".join(refused)
        return out

    @staticmethod
    def _refused_note(refused: list[str]) -> str:
        """What the assistant must say when a card it meant to close stays."""
        if not any("不是這位成員交辦的卡" in r for r in refused):
            return ""
        return ("\n這些卡還開著（記在負責人名下，成員那一輪動不了）。在群組講清楚哪幾張還沒關，"
                "請負責人按掉或用文字回答；要讓成員以後自己決定同類卡，問負責人要不要用 member_grant 授權。")

    # How long a close_cards confirmation question stays answerable.
    CLOSE_OFFER_TTL = 2 * 3600

    def t_close_cards(self, p, args) -> str:
        """Two steps, so a misheard answer can't close a card: first it only
        repeats back which card and what answer, for the person to confirm;
        a later message of theirs saying OK lets confirmed=true close it."""
        a = self.assistants.get(p.name)
        if not getattr(a, "turn_person", False):
            return "只有負責人或成員親自傳來的那一輪可以依文字回答關卡；排程、求助或系統訊息的輪不行。"
        requester = self.broker.requester_of(p.name)
        who = "owner" if getattr(a, "turn_owner", False) else str((requester or {}).get("id", ""))
        if args.get("confirmed"):
            offer = self.close_offers.get(p.name)
            if not offer:
                return "沒有等他確認的關卡。先不帶 confirmed 呼叫一次，把確認訊息傳給他。"
            if time.time() - offer["at"] > self.CLOSE_OFFER_TTL:
                self.close_offers.pop(p.name, None)
                return "上次的確認已經超過 2 小時，重新登記一次並請他再確認。"
            if getattr(a, "turn_seq", 0) <= offer["seq"]:
                return "還不能關：要等他看過確認訊息、在下一則訊息回 OK 之後才可以。先結束這一輪。"
            if who != "owner" and who != offer["who"]:
                return "只有當初回答的人（或負責人）可以確認這次關卡。"
            self.close_offers.pop(p.name, None)
            answer = offer["answer"]
            done, refused = self.broker.close_answered(p.name, offer["ids"], answer, requester)
            for item in a.items:
                if item.role == "choice" and item.choice_id in done:
                    item.chosen = f"已依文字回覆結案：{answer}"
            if self.dispatcher is not None:
                self.dispatcher.drop_cards(done)
            out = (f"已關卡：{'、'.join(self.broker.closed_tags.get(i, i) for i in done)}（標為已依文字回覆結案）。"
                   "卡上的動作沒有執行，照他的答案自己往下做。") if done else "沒有關到任何卡。"
            if refused:
                out += "\n沒關掉：" + "；".join(refused)
            return out

        cards = args.get("cards") or []
        if isinstance(cards, str):
            cards = [x for x in re.split(r"[,\s、]+", cards) if x]
        answer = str(args.get("answer") or "").strip()[:300]
        if not cards or not answer:
            return "需要 cards（卡的編號）和 answer（他的回答原話）。"
        found, refused = self.broker.closable(p.name, list(cards), requester)
        if not found:
            return "沒有可以關的卡：" + "；".join(refused) + self._refused_note(refused)
        self.close_offers[p.name] = {"ids": [c.id for c in found], "answer": answer, "who": who,
                                     "seq": getattr(a, "turn_seq", 0), "at": time.time()}
        lines = []
        for c in found:
            first = next((ln.strip() for ln in c.summary.splitlines() if ln.strip()), "")
            title = first[:40] + ("…" if len(first) > 40 else "")
            lines.append(f"• {c.tag}（{c.serial_day}）「{title}」")
        msg = "請確認要結案：\n" + "\n".join(lines) + f"\n你的答案：{answer}\n沒問題請回「OK」，有誤直接告訴我。"
        out = ("還沒關卡。把下面這段原樣傳給他，等他下一則訊息回 OK，再用 close_cards 帶 confirmed=true 關卡"
               "（他更正的話就照更正重新登記）：\n\n" + msg)
        if refused:
            out += "\n\n（這些不能關，不用列在確認訊息裡：" + "；".join(refused) + "）" + self._refused_note(refused)
        return out

    def _replace(self, p, args, new_id: str) -> str:
        """Close the older cards the new one takes over (args["replaces"])."""
        old = args.get("replaces") or []
        if isinstance(old, str):
            old = [x for x in re.split(r"[,\s]+", old) if x]
        if not old:
            return ""
        done, refused = self.broker.supersede(p.name, list(old), new_id, self.broker.requester_of(p.name))
        a = self.assistants.get(p.name)
        new = self.broker.get(new_id)
        new_tag = new.tag if new else new_id
        for item in a.items:
            if item.role == "choice" and item.choice_id in done:
                item.chosen = f"已改由新決策卡 {new_tag} 處理"
        if self.dispatcher is not None:
            self.dispatcher.drop_cards(done)
        out = (f"\n已撤掉舊卡：{'、'.join(self.broker.closed_tags.get(i, i) for i in done)}"
               f"（標為已改由 {new_tag} 處理）。") if done else ""
        if refused:
            out += "\n沒撤掉：" + "；".join(refused) + self._refused_note(refused)
        return out

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
        p, err = self._project_arg(p, args, "project")
        if err:
            return err
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
        p, err = self._project_arg(p, args, "project")
        if err:
            return err
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
        # The same report keeps its link: sharing it again updates the file
        # behind the link it got the first time (until that one expires).
        links_file = reports / "shared_links.json"
        try:
            links = json.loads(links_file.read_text())
        except (OSError, ValueError):
            links = {}
        prev = "" if args.get("new_link") else str(links.get(local.name) or "")
        try:
            r = None
            if prev:
                r = subprocess.run([SHARE, "-u", prev, str(local)], capture_output=True, text=True, timeout=120)
            if r is None or r.returncode != 0:  # first time, or the old link expired
                prev = ""
                r = subprocess.run([SHARE, str(local)], capture_output=True, text=True, timeout=120)
        except (OSError, subprocess.SubprocessError) as e:
            return f"分享失敗：{e}；報告已存在 {local}"
        url = next((l.strip() for l in r.stdout.splitlines() if l.strip().startswith("http")), "")
        if not url:
            return f"分享失敗：{(r.stderr or r.stdout)[-300:]}；報告已存在 {local}"
        links[local.name] = url
        links_file.write_text(json.dumps(links, ensure_ascii=False, indent=1))
        note = "（沿用這份報告原本的連結，內容已更新）" if prev else ""
        return f"連結：{url}{note}\n本機存檔：{local}"

    def t_tg_send(self, p, args) -> str:
        text = str(args.get("text") or "").strip()
        if not text:
            return "text 是空的。"
        bot = self.bots_for(p.name)
        if bot is None:
            return "這個專案還沒設定 TG bot，訊息沒有送出。"
        bot.jobs.put((bot._send_notice, (p, redact(text))))
        return "已送到專案群組。"

    # ------------------------------------------- cross-project (owner only)

    CROSS_REFUSED = ("沒有執行：{key}={name} 是跨專案操作，只限負責人本人（主帳號在 TG、MyGhost 或手機網頁）"
                     "親自交辦的那一輪。這一輪是成員、工作帳號訊息、排程、工作對話求助或內部維護觸發的，"
                     "不能跨專案；請負責人本人來交辦。")

    def _project_arg(self, p, args, key: str):
        """(project, "") for args[key] — this project when it's missing — or
        (None, why not). Another project only in the owner's own turn."""
        name = str(args.get(key) or "").strip()
        if not name or name == p.name:
            return p, ""
        if not self._owner_turn(p):
            return None, self.CROSS_REFUSED.format(key=key, name=name)
        names = {x.name for x in self.broker.projects.all() if x.name != DEFAULT_PROJECT}
        if name not in names:
            return None, f"沒有叫「{name}」的專案。有的：{'、'.join(sorted(names))}。"
        return self.broker.projects.get(name), ""

    def _account(self, p, args):
        """(watcher, on_behalf, error): the work account to use — another
        project's with account_project, in the owner's own turn only."""
        target, err = self._project_arg(p, args, "account_project")
        if err:
            return None, "", err
        w = self.accounts.get(target.name)
        if w is None:
            return None, "", ("這個專案沒有設定工作帳號。" if target is p
                              else f"{target.name} 專案沒有設定工作帳號。")
        return w, ("" if target is p else p.name), ""

    def _used_by(self, w, on_behalf: str, what: str, detail: str = "") -> None:
        if on_behalf:
            w._event("account_used_by", by_project=on_behalf, what=what, detail=detail[:200])

    def t_draft_reply(self, p, args) -> str:
        w, behalf, err = self._account(p, args)
        if err:
            return err
        out = w.draft(str(args.get("ref") or ""), str(args.get("text") or ""), str(args.get("note") or ""),
                      on_behalf=behalf)
        return out + self._replace_drafts(p, args, out, r"回覆卡（id=([0-9a-f]+)")

    def t_draft_dm(self, p, args) -> str:
        w, behalf, err = self._account(p, args)
        if err:
            return err
        out = w.draft_dm(str(args.get("to") or ""), str(args.get("text") or ""), str(args.get("note") or ""),
                         on_behalf=behalf)
        return out + self._replace_drafts(p, args, out, r"私訊卡（id=([0-9a-f]+)")

    def _replace_drafts(self, p, args, out: str, pattern: str) -> str:
        """A new reply card takes over the ones in args["replaces"], and on its
        own over any open card with the same text to the same chat: re-hanging
        the same reply on another message left the old card pressable."""
        m = re.search(pattern, out)
        new = self.broker.get(m.group(1)) if m else None
        if new is None:
            return ""
        old = args.get("replaces") or []
        if isinstance(old, str):
            old = [x for x in re.split(r"[,\s]+", old) if x]
        r = new.reply or {}
        same = " ".join(str(r.get("text") or "").split())
        with self.broker.lock:
            dup = [x.id for x in self.broker.pending.values()
                   if x.id != new.id and x.open and x.project == new.project and x.reply
                   and x.reply.get("chat_id") == r.get("chat_id")
                   and " ".join(str(x.reply.get("text") or "").split()) == same]
        return self._replace(p, {"replaces": list(old) + dup}, new.id)

    def t_send_reply(self, p, args) -> str:
        w, behalf, err = self._account(p, args)
        if err:
            return err
        return w.send_now(str(args.get("ref") or ""), str(args.get("text") or ""), on_behalf=behalf)

    def _owner_turn(self, p) -> bool:
        return bool(getattr(self.assistants.get(p.name), "turn_owner", False))

    def t_grant_dm(self, p, args) -> str:
        w, behalf, err = self._account(p, args)
        if err:
            return err
        self._used_by(w, behalf, "grant_dm", str(args.get("person") or ""))
        # Agreeing to a task means it may be handled and answered by itself.
        return w.grant(str(args.get("person") or ""), str(args.get("level") or "auto"),
                       str(args.get("scope") or ""), args.get("days") or 0, self._owner_turn(p))

    def t_revoke_dm(self, p, args) -> str:
        w, behalf, err = self._account(p, args)
        if err:
            return err
        self._used_by(w, behalf, "revoke_dm", str(args.get("person") or ""))
        return w.revoke(str(args.get("person") or ""))

    def t_list_dm_grants(self, p, args) -> str:
        w, behalf, err = self._account(p, args)
        if err:
            return err
        self._used_by(w, behalf, "list_dm_grants")
        return w.list_grants(self._owner_turn(p))

    def t_watch_group(self, p, args) -> str:
        w, behalf, err = self._account(p, args)
        if err:
            return err
        if not self._owner_turn(p):
            return "監看規則只有負責人本人說話的那一輪能改（成員、工作帳號訊息、排程觸發的輪次不行）。"
        from .watchcmd import set_group
        self._used_by(w, behalf, "watch_group", str(args.get("chat") or ""))
        return set_group(w, str(args.get("chat") or ""), args.get("keywords") or args.get("trigger") or "all",
                         args.get("window") or "always", args.get("action") == "remove")

    def t_flag_sensitive(self, p, args) -> str:
        w, behalf, err = self._account(p, args)
        if err:
            return err
        self._used_by(w, behalf, "flag_sensitive", str(args.get("ref") or ""))
        return w.flag_sensitive(str(args.get("ref") or ""), str(args.get("what") or ""))

    def t_post_message(self, p, args) -> str:
        w, behalf, err = self._account(p, args)
        if err:
            return err
        return w.post(str(args.get("chat") or ""), str(args.get("text") or ""), on_behalf=behalf)

    def t_read_tg_chat(self, p, args) -> str:
        w, behalf, err = self._account(p, args)
        if err:
            return err
        limit = int(args.get("limit") or 20)
        self._used_by(w, behalf, "read_tg_chat", str(args.get("chat") or args.get("ref") or ""))
        if args.get("chat") and not args.get("ref"):
            return w.history_of(str(args["chat"]), limit)
        return w.history(str(args.get("ref") or ""), limit)

    def t_db_query(self, p, args) -> str:
        if self.dbquery is None:
            return "資料庫查詢沒有啟用。"
        return self.dbquery.query(p, str(args.get("database") or "").strip(), str(args.get("sql") or ""),
                                  str(args.get("why") or ""))

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
        out = self.dispatcher.propose(p, str(args.get("title") or ""), str(args.get("repo") or ""),
                                      str(args.get("task") or ""), str(args.get("branch") or ""),
                                      str(args.get("base") or ""), str(args.get("source") or ""),
                                      owner_turn=self._owner_turn(p))
        m = re.search(r"開工卡（id=([0-9a-f]+)", out)
        return out + (self._replace(p, args, m.group(1)) if m else "")

    def t_message_worker(self, p, args) -> str:
        if self.dispatcher is None:
            return "派工沒有啟用。"
        p, err = self._project_arg(p, args, "project")
        if err:
            return err
        return self.dispatcher.message(p, str(args.get("dispatch_id") or ""), str(args.get("text") or ""))

    def t_list_dispatches(self, p, args) -> str:
        if self.dispatcher is None:
            return "派工沒有啟用。"
        p, err = self._project_arg(p, args, "project")
        return err or self.dispatcher.list_for(p)

    def t_close_worker(self, p, args) -> str:
        if self.dispatcher is None:
            return "派工沒有啟用。"
        return self.dispatcher.close(p, str(args.get("dispatch_id") or ""), owner_turn=self._owner_turn(p))

    def t_reply_worker(self, p, args) -> str:
        if self.helpdesk is None:
            return "求助沒有啟用。"
        p, err = self._project_arg(p, args, "project")
        if err:
            return err
        return self.helpdesk.reply(p.name, str(args.get("help_id") or ""), str(args.get("text") or ""))
