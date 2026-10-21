"""Telegram gateway: decision cards out, button presses in.

Each project has its own assistant bot and its own group (project.yaml
`telegram: {token, chat_id}`); one `Bot` runs per distinct token and serves
the projects configured with it. Requests outside every project use the
fallback bot in config.yaml. Only the commander accounts
(`telegram.commander_user_ids`) can press buttons or give commands.

Plain Bot API over urllib — no third-party client, so the daemon has a single
dependency (PyYAML). Outgoing calls run on a worker thread because the broker
emits while holding its lock; a slow or dead Telegram must never stall a hook.

Must use its own bot token: two processes long-polling one token make
Telegram answer 409 to both (ccgram already polls its own bot on this Mac).
"""

from __future__ import annotations

import html
import json
import queue
import re
import threading
import time
import urllib.error
import urllib.request

from pathlib import Path

from . import config as cfgmod
from . import uploads
from .broker import Broker, Pending, log
from .config import DEFAULT_PROJECT, Config, Project
from .policy import L3, LEVEL_NAMES

API = "https://api.telegram.org/bot{token}/{method}"
FILE_API = "https://api.telegram.org/file/bot{token}/{path}"
MAX_DOWNLOAD = 20 * 1024 * 1024  # the Bot API's own limit for getFile
LEVEL_ICON = {0: "⚪️", 1: "🟢", 2: "🟠", 3: "🔴"}
STATE_TEXT = {
    "allowed": ("✅", "已同意"),
    "denied": ("❌", "已拒絕"),
    "expired": ("⌛️", "逾時，已預設拒絕"),
}
SOURCE_TEXT = {"tg": "TG", "myghost": "MyGhost", "web": "手機網頁", "timeout": "逾時",
               "self_reply": "你已在 TG 自己回覆", "replaced": "已改稿", "superseded": "已改由新決策卡處理",
               "answered": "已依文字回覆結案", "terminal": "已在終端機處理"}


def esc(s: str) -> str:
    return html.escape(str(s), quote=False)


RULE = "━━━━━━━━━━━━━━"
CHUNK = 3900  # under Telegram's 4096-character message limit
FENCE = re.compile(r"^\s*```")
INLINE = re.compile(r"`([^`\n]+)`|\*\*(?=\S)(.+?)(?<=\S)\*\*|\[([^\]\n]+)\]\((https?://[^)\s]+)\)")
HEADING = re.compile(r"^#{1,6}\s+(.*)$")
BULLET = re.compile(r"^([ \t]*)[-*+][ \t]+(.*)$")


def md_chunks(text: str) -> list[str]:
    """The assistant's Markdown cut into message-sized pieces at line ends.
    A code block split across two pieces is closed and reopened, so each
    piece converts on its own."""
    out, cur, fence = [], "", None
    for line in text.split("\n"):
        while len(line) > CHUNK:
            line, rest = line[:CHUNK], line[CHUNK:]
            out.append(cur + line + ("\n```" if fence is not None else ""))
            cur, line = (fence + "\n" if fence is not None else ""), rest
        if cur and len(cur) + len(line) + 5 > CHUNK:
            out.append(cur.rstrip("\n") + ("\n```" if fence is not None else ""))
            cur = fence + "\n" if fence is not None else ""
        cur += line + "\n"
        if FENCE.match(line):
            fence = None if fence is not None else line.strip()
    if cur.strip():
        out.append(cur.rstrip("\n"))
    return out


def md_to_html(text: str) -> str:
    """Telegram HTML for the Markdown Claude writes: fenced and inline code,
    **bold**, headings, links and (nested) bullets. Anything else is escaped
    as it is — single * and _ are left alone, they show up in names and arithmetic."""
    out, code = [], None
    for line in text.split("\n"):
        if FENCE.match(line):
            if code is None:
                code = []
            else:
                out.append("<pre>" + esc("\n".join(code)) + "</pre>")
                code = None
            continue
        if code is not None:
            code.append(line)
            continue
        h = HEADING.match(line)
        li = BULLET.match(line)
        if h:
            out.append(f"<b>{_inline(h.group(1))}</b>")
        elif li:
            # Telegram has no lists: a bullet sign, and em spaces for the
            # nesting (plain leading spaces get eaten).
            depth = len(li.group(1).expandtabs(4)) // 2
            out.append(" " * depth + ("◦ " if depth else "• ") + _inline(li.group(2)))
        else:
            out.append(_inline(line))
    if code is not None:
        out.append("<pre>" + esc("\n".join(code)) + "</pre>")
    return "\n".join(out)


FOLD_AT = 300  # characters after the opening paragraph that get folded away


def tg_html(text: str) -> str:
    """A reply as TG shows it: the opening paragraph (the conclusion) in
    full, a long rest folded into an expandable quote — a long scroll of
    replies otherwise blurs which is which. Code stays unfolded."""
    text = text.strip("\n")
    lead, sep, rest = text.partition("\n\n")
    if sep and HEADING.match(lead) and "\n" not in lead:  # a title alone: take its paragraph too
        more, sep, rest = rest.partition("\n\n")
        lead += "\n\n" + more
    rest = rest.strip("\n")
    if len(rest) < FOLD_AT or any(FENCE.match(l) for l in rest.split("\n")):
        return md_to_html(text)
    return md_to_html(lead) + "\n<blockquote expandable>" + md_to_html(rest) + "</blockquote>"


def _inline(line: str) -> str:
    parts, last = [], 0
    for m in INLINE.finditer(line):
        parts.append(esc(line[last:m.start()]))
        if m.group(1) is not None:
            parts.append(f"<code>{esc(m.group(1))}</code>")
        elif m.group(2) is not None:
            parts.append(f"<b>{_inline(m.group(2))}</b>")
        else:
            parts.append(f'<a href="{html.escape(m.group(4))}">{esc(m.group(3))}</a>')
        last = m.end()
    parts.append(esc(line[last:]))
    return "".join(parts)


def framed(p: Pending, lines: list[str]) -> str:
    """A card between two rules, so it stands out from the plain chat
    mirrored into the same group."""
    num = f" <code>{p.tag}</code>（{p.serial_day}）" if p.serial else ""
    tag = (f"📋 <b>待你決定</b>{num}" if p.open else f"📋 決策單・已處理{num}")
    if p.requested_by:  # a member's request: they (and the owner) may press it
        who = asked(p)
        tag += f"\n👤 {who} 交辦（{who}和{esc(cfgmod.owner())}都可以按）"
    return "\n".join([f"{RULE}\n{tag}", *lines, RULE])


def asked(p: Pending) -> str:
    """Who the card is for: the member whose request it came from, else the
    project's owner."""
    if p.requested_by:
        return esc(str(p.requested_by.get("name") or p.requested_by.get("id")))
    return esc(cfgmod.owner())


def decided_by_line(p: Pending, src: str, name: bool = True) -> str:
    """"（王爾莎 · TG · 01:20）": who pressed it, where, and when. `name`
    off where the line already says who."""
    parts = [esc(p.decider)] if name and p.decider else []
    return "（" + " · ".join(parts + [esc(src), time.strftime("%H:%M")]) + "）"


def build_bots(cfg: Config, broker: Broker) -> list["Bot"]:
    """One Bot per distinct token, routing each project to its own group."""
    bots: dict[str, Bot] = {}
    for p in broker.projects.all():
        token, chat = p.tg_token, p.tg_chat_id
        if p.name == DEFAULT_PROJECT or not token:
            token, chat = cfg.telegram.token, cfg.telegram.chat_id
        if not token:
            continue
        bot = bots.setdefault(token, Bot(cfg, broker, token))
        bot.routes[p.name] = chat
    return list(bots.values())


class Bot:
    def __init__(self, cfg: Config, broker: Broker, token: str):
        self.cfg = cfg
        self.broker = broker
        self.token = token
        # project name -> group chat id (None until set up with /chatid)
        self.routes: dict[str, int | None] = {}
        self.jobs: queue.Queue = queue.Queue()
        self.offset = 0
        self.me: dict = {}
        self.assistants = None  # AssistantManager, set by main
        self.watch_commands = None  # WatchCommands, set by main
        self._warned: set[tuple] = set()  # (chat, user) told about already

    def chat_for(self, project: str) -> int | None:
        return self.routes.get(project)

    @property
    def name(self) -> str:
        return "@" + self.me.get("username", "?")

    # --------------------------------------------------------------- plumbing

    def _download(self, m: dict, folder: Path) -> tuple[list, str]:
        """The message's photo / file saved into `folder`, and a note for
        the assistant when it couldn't be."""
        att = attachment(m)
        if att is None:
            return [], ""
        file_id, name, size = att
        if size and size > MAX_DOWNLOAD:
            return [], f"（附件「{name}」超過 20MB，Telegram bot 下載不了，請改傳較小的檔案。）"
        try:
            info = self.call("getFile", file_id=file_id)
            url = FILE_API.format(token=self.token, path=info["file_path"])
            with urllib.request.urlopen(url, timeout=60) as r:
                data = r.read(MAX_DOWNLOAD + 1)
            if len(data) > MAX_DOWNLOAD:
                raise RuntimeError("超過 20MB")
            if name == "photo.jpg" and "." in info["file_path"]:
                name = "photo" + Path(info["file_path"]).suffix
            return [uploads.Attached(uploads.save(folder, name, data))], ""
        except Exception as e:
            log(f"telegram: {self.name} attachment download failed: {e!r}")
            return [], f"（附件「{name}」下載失敗：{e}）"

    def call(self, method: str, timeout: float = 15, **params) -> dict:
        url = API.format(token=self.token, method=method)
        body = json.dumps({k: v for k, v in params.items() if v is not None}).encode()
        req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                data = json.loads(r.read())
        except urllib.error.HTTPError as e:
            data = json.loads(e.read() or b"{}")
        if not data.get("ok"):
            moved = (data.get("parameters") or {}).get("migrate_to_chat_id")
            if moved and params.get("chat_id") is not None and self._migrate(int(params["chat_id"]), int(moved)):
                params["chat_id"] = moved
                return self.call(method, timeout, **params)
            raise RuntimeError(f"{method}: {data.get('description', data)}")
        return data["result"]

    def _migrate(self, old: int, new: int) -> bool:
        """The group became a supergroup with a new id: follow it."""
        moved = False
        for project, chat in list(self.routes.items()):
            if chat == old:
                self.routes[project] = new
                cfgmod.set_chat_id(self.broker.projects.get(project), old, new)
                log(f"telegram: {project}'s group moved {old} -> {new} (supergroup); project.yaml updated")
                moved = True
        return moved

    def start(self) -> None:
        try:
            self.me = self.call("getMe")
        except Exception as e:
            log(f"telegram: getMe failed: {e!r}")
        for project, chat in self.routes.items():
            if chat is None:
                log(f"telegram: {self.name} has no chat_id for {project} — "
                    "add the bot to the project group and send /chatid there")
            else:
                self.broker.tg_projects.add(project)
        log(f"telegram: {self.name} serving {', '.join(self.routes)}")
        try:  # what Telegram suggests after "/"
            self.call("setMyCommands", commands=[
                {"command": "pending", "description": "待決策的卡片"},
                {"command": "status", "description": "工作對話狀態"},
                {"command": "watches", "description": "工作帳號的監看規則"},
                {"command": "watch", "description": "新增監看群組：/watch 群名 [kw:關鍵字]"},
                {"command": "unwatch", "description": "移除監看群組"},
                {"command": "pause", "description": "暫停轉訊息給助手：/pause 2h"},
                {"command": "resume", "description": "恢復轉訊息給助手"},
                {"command": "members", "description": "可以指揮助手的成員"},
                {"command": "addmember", "description": "回覆某人的訊息：加為成員"},
                {"command": "removemember", "description": "回覆某人的訊息或 /removemember id：移除成員"},
                {"command": "chatid", "description": "顯示 chat_id／user_id"}])
        except Exception as e:
            log(f"telegram: setMyCommands failed: {e!r}")
        threading.Thread(target=self._worker, name="tg-out", daemon=True).start()
        threading.Thread(target=self._poll, name="tg-in", daemon=True).start()

    def _worker(self) -> None:
        while True:
            fn, args = self.jobs.get()
            for attempt in range(3):
                try:
                    fn(*args)
                    break
                except Exception as e:
                    log(f"telegram: {fn.__name__} failed ({attempt + 1}/3): {e!r}")
                    time.sleep(2 * (attempt + 1))

    # ------------------------------------------------------ broker listener

    def on_pending(self, p: Pending) -> None:
        if self.chat_for(p.project) is not None:
            self.jobs.put((self._send_card, (p,)))

    def on_update(self, p: Pending) -> None:
        if self.chat_for(p.project) is not None:
            self.jobs.put((self._edit_card, (p,)))

    def on_notice(self, project: Project, text: str) -> None:
        if self.chat_for(project.name) is not None:
            self.jobs.put((self._send_notice, (project, text)))

    def on_chat(self, project: Project, item) -> None:
        """Mirror the assistant conversation into the project's group."""
        if self.chat_for(project.name) is None:
            return
        if item.role == "assistant" and item.text.strip():
            # Quote the TG message it answers, so a reply stays tied to its
            # question however much else was said in between.
            reply_to = getattr(item, "tg_reply_to", None)
            for i, chunk in enumerate(md_chunks(item.text)):
                self.jobs.put((self._send_markdown, (project, chunk, reply_to if i == 0 else None)))
            return
        if item.role == "user" and item.source in ("myghost", "web") and self.cfg.sync_chat_to_tg:
            text = f"🖥 你在 MyGhost：{item.text}"
            names = [f.get("name", "") for f in getattr(item, "files", None) or []]
            if names:
                text += "\n📎 " + "、".join(names)
        else:
            return
        for i in range(0, len(text), CHUNK):
            self.jobs.put((self._send_plain, (project, text[i:i + CHUNK])))

    def _send_plain(self, project: Project, text: str, reply_to: int | None = None) -> None:
        self.call("sendMessage", chat_id=self.chat_for(project.name), text=text,
                  disable_web_page_preview=True, reply_parameters=quoting(reply_to))

    def _send_markdown(self, project: Project, text: str, reply_to: int | None = None) -> None:
        try:
            self.call("sendMessage", chat_id=self.chat_for(project.name), text=tg_html(text),
                      parse_mode="HTML", disable_web_page_preview=True, reply_parameters=quoting(reply_to))
        except RuntimeError as e:
            # Markdown we didn't foresee must not cost the message itself.
            log(f"telegram: {project.name} formatted reply refused ({e}); sent as plain text")
            self._send_plain(project, text, reply_to)

    # ---------------------------------------------------------------- render

    def card_text(self, p: Pending) -> str:
        if p.kind == "choice":
            head = ("✉️ <b>{} 助手草擬了回覆，問{}</b>" if p.reply else
                    "🚀 <b>{} 助手提議開工，問{}</b>" if getattr(p, "dispatch", None) else
                    "🙋 <b>{} 助手派出的工作對話問{}</b>" if getattr(p, "worker_ask", None) else
                    "❓ <b>{} 助手問{}</b>")
            lines = [head.format(esc(p.project), asked(p)),
                     f"<blockquote>{esc(p.summary[:3000])}</blockquote>"]
            if not p.open:
                # The buttons go once it's decided, so the options they offered
                # are kept in the text, the picked one ticked.
                lines.append("<b>選項：</b>")
                lines += [f"{'✅' if i == p.chosen else '▫️'} {esc(o['label'])}" for i, o in enumerate(p.options)]
                # Bot messages can't set a text colour; inline code is the one
                # style every client draws in its own colour, so the answer
                # stands apart from the question quoted above it.
                src = SOURCE_TEXT.get(p.decided_by, p.decided_by)
                who = esc(p.decider or cfgmod.owner())
                if p.decided_by == "terminal":
                    lines.append("🖥 <b>已改在終端機回答</b>，這張不用再按")
                elif p.superseded_by:
                    lines.append(f"⏭️ <b>已改由新決策卡</b> <code>{esc(p.superseded_by)}</code> <b>處理</b>，這張不用再按")
                elif p.answered:
                    lines.append(f"💬 <b>已依文字回覆結案：</b><code>{esc(p.answered)}</code>，這張不用再按")
                elif p.chosen is not None:
                    lines.append(f"✅ <b>{who}選了：</b><code>{esc(p.options[p.chosen]['label'])}</code>"
                                 f"{decided_by_line(p, src, name=False)}")
                else:
                    lines.append(f"⏭️ <b>{who}選了：</b><code>略過</code>{decided_by_line(p, src, name=False)}")
            return framed(p, lines)
        who = esc(p.tab_title or p.session_id[:8] or "?")
        head = f"{LEVEL_ICON[p.level]} <b>{LEVEL_NAMES[p.level]}</b> · {esc(p.project)} · {who}"
        lines = [head, f"<pre>{esc(p.summary[:900])}</pre>", esc(p.reason)]
        if p.level >= L3:
            lines.append("⚠️ 高風險：需要二次確認，不能設成一律允許")
        if p.open and p.discussing:
            lines.append("💬 討論中（不會逾時）· 回覆這則訊息可附上拒絕理由")
        elif p.open:
            mins = max(0, int((p.deadline - time.time()) // 60))
            lines.append(f"⏳ {mins} 分鐘後逾時並拒絕 · 回覆這則訊息可附上拒絕理由")
        else:
            src = SOURCE_TEXT.get(p.decided_by, p.decided_by)
            icon, text = STATE_TEXT.get(p.state, ("", p.state))
            # A timeout has nobody to name; a press names who pressed it.
            if p.decided_by == "terminal":
                lines.append("🖥 <code>已在終端機處理</code>，這張不用再按")
            elif p.decided_by not in ("tg", "myghost", "web"):
                lines.append(f"{icon} <code>{esc(text)}</code>（{esc(src)} · {time.strftime('%H:%M')}）")
            else:
                lines.append(f"{icon} <code>{esc(text)}</code>{decided_by_line(p, src)}")
            if p.always_added:
                lines.append(f"♾ 之後此專案一律允許 <code>{esc(p.always_added)}</code>")
        return framed(p, lines)

    def keyboard(self, p: Pending) -> dict | None:
        if not p.open:
            return None
        b = lambda text, action: {"text": text, "callback_data": f"g:{p.id}:{action}"}
        if p.kind == "choice":
            rows = [[b(o["label"][:60], f"o{i}")] for i, o in enumerate(p.options)]
            rows.append([b("略過", "deny")])
            return {"inline_keyboard": rows}
        if p.state == "confirming":
            rows = [[b("⚠️ 確定同意", "confirm"), b("↩︎ 取消", "cancel")], [b("❌ 拒絕", "deny")]]
        elif p.level >= L3:
            rows = [[b("✅ 同意（需再確認）", "allow"), b("❌ 拒絕", "deny")]]
        else:
            rows = [[b("✅ 同意", "allow"), b("❌ 拒絕", "deny")]]
            if p.always_pattern:
                label = p.always_pattern if len(p.always_pattern) <= 40 else p.always_pattern[:39] + "…"
                rows.append([b(f"♾ 此專案一律允許 {label}", "always")])
        if not p.discussing:
            rows.append([b("💬 討論（不逾時）", "discuss")])
        return {"inline_keyboard": rows}

    # --------------------------------------------------------------- outgoing

    def _send_card(self, p: Pending) -> None:
        if not p.open:
            return
        msg = self.call("sendMessage", chat_id=self.chat_for(p.project), text=self.card_text(p),
                        parse_mode="HTML", reply_markup=self.keyboard(p))
        p.tg_message_id = msg["message_id"]
        # Kept with the card, so it can still be edited after a restart.
        self.broker.save_pending()
        if not p.open:  # decided elsewhere while we were sending
            self._edit_card(p)

    def _edit_card(self, p: Pending) -> None:
        if p.tg_message_id is None:
            return
        try:
            self.call("editMessageText", chat_id=self.chat_for(p.project),
                      message_id=p.tg_message_id, text=self.card_text(p), parse_mode="HTML",
                      reply_markup=self.keyboard(p) or {"inline_keyboard": []})
        except RuntimeError as e:
            if "not modified" not in str(e):
                raise

    def _send_notice(self, project: Project, text: str) -> None:
        self.call("sendMessage", chat_id=self.chat_for(project.name),
                  text=f"👻 {project.name}\n{text}", disable_notification=True)

    # --------------------------------------------------------------- incoming

    def _commanders(self, project: str) -> set[int]:
        p = self.broker.projects.get(project)
        return set(self.cfg.telegram.commander_user_ids) | set(p.commander_user_ids)

    def _is_commander(self, user_id) -> bool:
        """Commander of anything this bot serves (or of the whole daemon)."""
        return user_id in self.cfg.telegram.commander_user_ids or \
            any(user_id in self._commanders(n) for n in self.routes)

    def _is_owner(self, user_id) -> bool:
        """The owner (config.yaml commanders): the only ones who may press
        decision cards or change what the work account watches. Commanders
        a project adds on its own (members) may only talk to its assistant."""
        return user_id in self.cfg.telegram.commander_user_ids

    def _actor(self, user: dict) -> dict:
        """Who pressed a card, for the assistant's next turn (by user id,
        which Telegram vouches for — not the display name)."""
        name = " ".join(x for x in (user.get("first_name"), user.get("last_name")) if x)
        if self._is_owner(user.get("id")):
            # The name only labels the card; the owner's scope never depends on it.
            return {"owner": True, "name": name}
        return {"owner": False, "id": user.get("id"), "name": name or str(user.get("id"))}

    def _authorized(self, user: dict, chat: dict) -> bool:
        # Only a commander of the project the chat belongs to (its group, or
        # a private chat with them), nobody else — whatever they write.
        return bool(self._projects_in(chat, user))

    def _projects_in(self, chat: dict, user: dict | None = None) -> list[str]:
        if chat.get("type") == "private":
            names = list(self.routes)
        else:
            names = [n for n, c in self.routes.items() if c == chat.get("id")]
        if user is not None:
            names = [n for n in names if user.get("id") in self._commanders(n)]
        return names

    def _members_command(self, text: str, m: dict, chat: dict, mine: list[str], owner: bool) -> None:
        """/members, and (owner only) /addmember, /removemember: who besides
        the owner may talk to this group's assistant."""
        def say(t):
            self.call("sendMessage", chat_id=chat["id"], text=t)
        if chat.get("type") == "private" or len(mine) != 1:
            return say("請在專案的群組裡下這個指令。")
        p = self.broker.projects.get(mine[0])
        members = cfgmod.member_names(p)
        cmd = text.split(" ")[0].split("@")[0]
        if cmd == "/members":
            lines = [f"・{n or i}（{i}）" for i, n in members.items()] or [f"（沒有，只有{cfgmod.owner()}）"]
            return say(f"「{p.name}」助手的成員（可以跟助手對話、交辦工作，處理自己交辦的決策卡；"
                       f"{cfgmod.owner()}看得到也能處理全部）：\n" + "\n".join(lines))
        if not owner:
            return say("只有專案負責人可以加減成員。")
        target = (m.get("reply_to_message") or {}).get("from") or {}
        arg = text.split(" ", 1)[1].strip() if " " in text else ""
        if cmd == "/removemember" and not target and arg.isdigit():
            target = {"id": int(arg)}
        uid = target.get("id")
        if not uid:
            return say(f"請「回覆」那個人的一則訊息再打 {cmd}。")
        if target.get("is_bot"):
            return say("bot 不能當成員。")
        if self._is_owner(uid):
            return say("他是負責人，本來就能指揮助手。")
        who = " ".join(x for x in (target.get("first_name"), target.get("last_name")) if x) \
            or members.get(uid) or str(uid)
        if cmd == "/addmember":
            if uid in members:
                return say(f"{who} 已經是成員了。")
            members[uid] = who
        else:
            if uid not in members:
                return say(f"{who} 不是成員。")
            members.pop(uid)
        if not cfgmod.set_members(p, members):
            return say("寫入 project.yaml 失敗，請看 agentd.log。")
        added = cmd == "/addmember"
        log(f"telegram: {p.name} member {'added' if added else 'removed'}: {who} ({uid})")
        if self.assistants is not None:
            note = f"{cfgmod.owner()}{'新增' if added else '移除'}了 TG 成員 {who}（{uid}）。"
            a = self.assistants.get(p.name)
            a.add("notice", note, source="system")
            # The model must know too, or it keeps telling people the old list.
            a.send(note + "（已生效。只要記住，不用回覆。）", "system", show=False, internal=True)
        if added:
            return say(f"✅ 已把 {who} 加為「{p.name}」助手的成員：可以在這個群組跟助手對話、交辦工作，"
                       f"並處理自己交辦的決策卡；{cfgmod.owner()}看得到也能處理全部。監看規則與授權仍只有{cfgmod.owner()}能改。")
        return say(f"已移除 {who}，之後他的訊息不會交給助手。")

    def _outsiders(self, m: dict, chat: dict) -> None:
        """Someone who isn't a commander is in a project group: everything
        the assistant says there is readable by them. Say so, once each."""
        if chat.get("type") == "private":
            return
        projects = [n for n, c in self.routes.items() if c == chat.get("id")]
        if not projects:
            return
        allowed = set().union(*(self._commanders(n) for n in projects))
        people = [m.get("from") or {}] + list(m.get("new_chat_members") or [])
        for u in people:
            uid = u.get("id")
            if not uid or u.get("is_bot") or uid in allowed or (chat.get("id"), uid) in self._warned:
                continue
            self._warned.add((chat.get("id"), uid))
            who = " ".join(x for x in (u.get("first_name"), u.get("last_name")) if x) or str(uid)
            if u.get("username"):
                who += f" @{u['username']}"
            log(f"telegram: non-commander {who} ({uid}) in {projects}'s group {chat.get('id')}")
            self.call("sendMessage", chat_id=chat["id"],
                      text=f"⚠️ {who} 不是這個助手的指揮者，他的訊息不會交給助手；"
                           "但助手在這個群組說的內容他都看得到。不該在的話請把他移出群組。")
            for n in projects:
                if self.assistants is not None:
                    self.assistants.get(n).add(
                        "notice", f"⚠️ TG 群組裡有非指揮者 {who}（{uid}），助手在群組的發言他看得到。",
                        source="system")

    def _poll(self) -> None:
        while True:
            try:
                updates = self.call("getUpdates", timeout=60, offset=self.offset or None,
                                    allowed_updates=["message", "callback_query"])
                for u in updates:
                    self.offset = u["update_id"] + 1
                    try:
                        self._handle(u)
                    except Exception as e:
                        log(f"telegram: update failed: {e!r}")
            except Exception as e:
                log(f"telegram: poll error: {e!r}")
                time.sleep(5)

    def _handle(self, u: dict) -> None:
        if "callback_query" in u:
            cq = u["callback_query"]
            chat = (cq.get("message") or {}).get("chat") or {}
            if not self._authorized(cq.get("from") or {}, chat):
                self.call("answerCallbackQuery", callback_query_id=cq["id"], text="你沒有權限")
                return
            data = cq.get("data") or ""
            uid = (cq.get("from") or {}).get("id")
            if not self._is_owner(uid):
                card = self.broker.get(data.split(":")[1]) if data.startswith("g:") and data.count(":") == 2 else None
                if card is None or (card.requested_by or {}).get("id") != uid:
                    self.call("answerCallbackQuery", callback_query_id=cq["id"],
                              text="這張不是你交辦的，只有專案負責人可以按")
                    return
            if data.startswith("w:") and self.watch_commands is not None:
                text, rows, toast = self.watch_commands.callback(data, self._projects_in(chat, cq.get("from") or {}))
                self.call("answerCallbackQuery", callback_query_id=cq["id"], text=toast or None)
                if text:
                    self.call("editMessageText", chat_id=chat["id"], message_id=cq["message"]["message_id"],
                              text=text, reply_markup={"inline_keyboard": rows} if rows else None)
                return
            parts = data.split(":")
            if len(parts) != 3 or parts[0] != "g":
                return
            p = self.broker.get(parts[1])
            if p is not None and p.project not in self._projects_in(chat, cq.get("from") or {}):
                self.call("answerCallbackQuery", callback_query_id=cq["id"], text="不屬於這個群組的專案")
                return
            ok, why = self.broker.decide(parts[1], parts[2], "tg", actor=self._actor(cq.get("from") or {}))
            self.call("answerCallbackQuery", callback_query_id=cq["id"], text=why)
            return

        m = u.get("message") or {}
        chat, user = m.get("chat") or {}, m.get("from") or {}
        # A photo or file carries its words as a caption, not text.
        text = (m.get("text") or m.get("caption") or "").strip()
        self._outsiders(m, chat)
        if text.startswith("/chatid"):
            # Setup helper: works before chat_id is configured — but only
            # answers a commander, and binds this group to the bot's one
            # project that has none yet.
            if not self._is_commander(user.get("id")):
                return
            unbound = [n for n, c in self.routes.items() if c is None]
            note = ("（chat_id 填到 project.yaml 的 telegram.chat_id；"
                    "user_id 填到 config.yaml 的 commander_user_ids）")
            if chat.get("type") in ("group", "supergroup") and len(unbound) == 1 \
                    and user.get("id") in self._commanders(unbound[0]) \
                    and cfgmod.bind_chat_id(self.broker.projects.get(unbound[0]), int(chat["id"])):
                self.routes[unbound[0]] = int(chat["id"])
                self.broker.tg_projects.add(unbound[0])
                log(f"telegram: {self.name} bound {unbound[0]} to group {chat['id']}")
                note = f"✅ 已把這個群組設為「{unbound[0]}」助手的群組。"
            self.call("sendMessage", chat_id=chat["id"],
                      text=f"chat_id: {chat['id']}\nuser_id: {user.get('id')}\n{note}")
            return
        if not self._authorized(user, chat):
            return
        mine = self._projects_in(chat, user)
        reply = m.get("reply_to_message") or {}
        owner = self._is_owner(user.get("id"))
        if owner and reply.get("message_id") and text and not text.startswith("/"):
            for p in list(self.broker.pending.values()):
                if p.tg_message_id == reply["message_id"] and p.project in mine:
                    ok, why = self.broker.decide(p.id, "deny", "tg", message=text, actor=self._actor(user))
                    self.call("sendMessage", chat_id=chat["id"],
                              reply_to_message_id=m["message_id"],
                              text=("已拒絕，並把理由轉給對話" if ok else why))
                    return
        if text.split(" ")[0].split("@")[0] in ("/members", "/addmember", "/removemember"):
            self._members_command(text, m, chat, mine, owner)
            return
        if text.startswith("/pending"):
            pend = [p for p in self.broker.pending.values() if p.project in mine]
            if not pend:
                self.call("sendMessage", chat_id=chat["id"],
                          text="目前沒有待決策的請求 👍")
            for p in pend:  # re-send so buttons are at the bottom of the chat
                self.jobs.put((self._send_card, (p,)))
            return
        if self.watch_commands is not None and self.watch_commands.handles(text):
            if not owner:
                self.call("sendMessage", chat_id=chat["id"], text="監看規則只有專案負責人可以改。")
                return
            if len(mine) != 1:
                self.call("sendMessage", chat_id=chat["id"], text="請在專案的群組裡下這個指令。")
                return
            reply_text, rows = self.watch_commands.command(mine[0], text)
            self.call("sendMessage", chat_id=chat["id"], text=reply_text,
                      reply_markup={"inline_keyboard": rows} if rows else None)
            return
        if (text or attachment(m)) and not text.startswith("/") and self.assistants is not None \
                and len(mine) == 1 and chat.get("type") != "private":
            # A message from the commander in a project group: for its assistant.
            a = self.assistants.get(mine[0])
            files, note = self._download(m, a.uploads)
            text = "\n".join(x for x in (text, note) if x)
            if not owner:  # a member: the assistant must know who is talking
                who = " ".join(x for x in (user.get("first_name"), user.get("last_name")) if x) \
                    or str(user.get("id"))
                text = f"[TG 成員・{who}] {text}"
                a.send(text, "tg", files=files, requester={"id": user.get("id"), "name": who},
                       tg_message=m.get("message_id"))
                return
            a.send(text, "tg", files=files, tg_message=m.get("message_id"))
            return
        if text.startswith("/status"):
            rows = [s for s in self.broker.list_sessions() if s["project"] in mine][:20]
            icon = {"running": "⚙️", "waiting": "🙋", "done": "✅"}
            lines = [f"{icon.get(s['status'], '·')} {s['project']} · {s['tab_title'] or s['session_id'][:8]}"
                     for s in rows] or ["沒有進行中的對話"]
            self.call("sendMessage", chat_id=chat["id"],
                      text="\n".join(lines))


def quoting(message_id: int | None) -> dict | None:
    """reply_parameters for a reply to `message_id`; still sent if that
    message was deleted meanwhile."""
    if message_id is None:
        return None
    return {"message_id": message_id, "allow_sending_without_reply": True}


def attachment(m: dict) -> tuple[str, str, int] | None:
    """(file_id, file name, size) of a message's photo or file; stickers and
    the like are skipped."""
    if m.get("photo"):
        p = m["photo"][-1]  # the largest size
        return p["file_id"], "photo.jpg", int(p.get("file_size") or 0)
    for key, default in (("document", "file"), ("video", "video.mp4"), ("voice", "voice.ogg"),
                         ("audio", "audio.mp3"), ("video_note", "video_note.mp4")):
        d = m.get(key)
        if d and d.get("file_id"):
            return d["file_id"], d.get("file_name") or default, int(d.get("file_size") or 0)
    return None
