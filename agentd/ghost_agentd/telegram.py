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
import threading
import time
import urllib.error
import urllib.request

from . import config as cfgmod
from .broker import Broker, Pending, log
from .config import DEFAULT_PROJECT, Config, Project
from .policy import L3, LEVEL_NAMES

API = "https://api.telegram.org/bot{token}/{method}"
LEVEL_ICON = {0: "⚪️", 1: "🟢", 2: "🟠", 3: "🔴"}
STATE_TEXT = {
    "allowed": "✅ 已同意",
    "denied": "❌ 已拒絕",
    "expired": "⌛️ 逾時，已預設拒絕",
}
SOURCE_TEXT = {"tg": "TG", "myghost": "MyGhost", "web": "手機網頁", "timeout": "逾時",
               "self_reply": "你已在 TG 自己回覆", "replaced": "已改稿"}


def esc(s: str) -> str:
    return html.escape(str(s), quote=False)


RULE = "━━━━━━━━━━━━━━"


def framed(p: Pending, lines: list[str]) -> str:
    """A card between two rules, so it stands out from the plain chat
    mirrored into the same group."""
    tag = "📋 <b>待你決定</b>" if p.open else "📋 決策單・已處理"
    return "\n".join([f"{RULE}\n{tag}", *lines, RULE])


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
            text = item.text
        elif item.role == "user" and item.source in ("myghost", "web") and self.cfg.sync_chat_to_tg:
            text = f"🖥 你在 MyGhost：{item.text}"
            names = [f.get("name", "") for f in getattr(item, "files", None) or []]
            if names:
                text += "\n📎 " + "、".join(names)
        else:
            return
        for i in range(0, len(text), 3900):
            self.jobs.put((self._send_plain, (project, text[i:i + 3900])))

    def _send_plain(self, project: Project, text: str) -> None:
        self.call("sendMessage", chat_id=self.chat_for(project.name), text=text,
                  disable_web_page_preview=True)

    # ---------------------------------------------------------------- render

    def card_text(self, p: Pending) -> str:
        if p.kind == "choice":
            head = ("✉️ <b>{} 助手草擬了回覆</b>" if p.reply else
                    "🚀 <b>{} 助手提議開工</b>" if getattr(p, "dispatch", None) else "❓ <b>{} 助手問你</b>")
            lines = [head.format(esc(p.project)), f"<blockquote>{esc(p.summary[:3000])}</blockquote>"]
            if not p.open:
                pick = p.options[p.chosen]["label"] if p.chosen is not None else "（略過）"
                lines.append(f"<b>你選了：{esc(pick)}</b>（{esc(SOURCE_TEXT.get(p.decided_by, p.decided_by))}）")
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
            when = time.strftime("%H:%M")
            src = SOURCE_TEXT.get(p.decided_by, p.decided_by)
            lines.append(f"<b>{STATE_TEXT.get(p.state, p.state)}</b>（{esc(src)} · {when}）")
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
        return set(p.commander_user_ids or self.cfg.telegram.commander_user_ids)

    def _is_commander(self, user_id) -> bool:
        """Commander of anything this bot serves (or of the whole daemon)."""
        return user_id in self.cfg.telegram.commander_user_ids or \
            any(user_id in self._commanders(n) for n in self.routes)

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
            ok, why = self.broker.decide(parts[1], parts[2], "tg")
            self.call("answerCallbackQuery", callback_query_id=cq["id"], text=why)
            return

        m = u.get("message") or {}
        chat, user, text = m.get("chat") or {}, m.get("from") or {}, (m.get("text") or "").strip()
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
        if reply.get("message_id") and text and not text.startswith("/"):
            for p in list(self.broker.pending.values()):
                if p.tg_message_id == reply["message_id"] and p.project in mine:
                    ok, why = self.broker.decide(p.id, "deny", "tg", message=text)
                    self.call("sendMessage", chat_id=chat["id"],
                              reply_to_message_id=m["message_id"],
                              text=("已拒絕，並把理由轉給對話" if ok else why))
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
            if len(mine) != 1:
                self.call("sendMessage", chat_id=chat["id"], text="請在專案的群組裡下這個指令。")
                return
            reply_text, rows = self.watch_commands.command(mine[0], text)
            self.call("sendMessage", chat_id=chat["id"], text=reply_text,
                      reply_markup={"inline_keyboard": rows} if rows else None)
            return
        if text and not text.startswith("/") and self.assistants is not None and len(mine) == 1 \
                and chat.get("type") != "private":
            # A message from the commander in a project group: for its assistant.
            self.assistants.get(mine[0]).send(text, "tg")
            return
        if text.startswith("/status"):
            rows = [s for s in self.broker.list_sessions() if s["project"] in mine][:20]
            icon = {"running": "⚙️", "waiting": "🙋", "done": "✅"}
            lines = [f"{icon.get(s['status'], '·')} {s['project']} · {s['tab_title'] or s['session_id'][:8]}"
                     for s in rows] or ["沒有進行中的對話"]
            self.call("sendMessage", chat_id=chat["id"],
                      text="\n".join(lines))
