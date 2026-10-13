"""Telegram gateway: decision cards out, button presses in.

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
SOURCE_TEXT = {"tg": "TG", "myghost": "MyGhost", "web": "手機網頁", "timeout": "逾時"}


def esc(s: str) -> str:
    return html.escape(str(s), quote=False)


class Telegram:
    def __init__(self, cfg: Config, broker: Broker):
        self.cfg = cfg
        self.broker = broker
        self.jobs: queue.Queue = queue.Queue()
        self.offset = 0
        self.enabled = bool(cfg.telegram.token)
        self.me: dict = {}

    # --------------------------------------------------------------- plumbing

    def call(self, method: str, timeout: float = 15, **params) -> dict:
        url = API.format(token=self.cfg.telegram.token, method=method)
        body = json.dumps({k: v for k, v in params.items() if v is not None}).encode()
        req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                data = json.loads(r.read())
        except urllib.error.HTTPError as e:
            data = json.loads(e.read() or b"{}")
        if not data.get("ok"):
            raise RuntimeError(f"{method}: {data.get('description', data)}")
        return data["result"]

    def start(self) -> None:
        if not self.enabled:
            log("telegram: no token configured — TG disabled (cards only in MyGhost/web)")
            return
        try:
            self.me = self.call("getMe")
            log(f"telegram: logged in as @{self.me.get('username')}")
        except Exception as e:
            log(f"telegram: getMe failed: {e!r}")
        if self.cfg.telegram.chat_id is None:
            log("telegram: chat_id not set — send /chatid to the bot to find it")
        self.broker.tg_ready = self.cfg.telegram.chat_id is not None
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

    def _thread(self, project: Project) -> int | None:
        return project.topic_id if project.name != DEFAULT_PROJECT else None

    # ------------------------------------------------------ broker listener

    def on_pending(self, p: Pending) -> None:
        if self.enabled and self.cfg.telegram.chat_id is not None:
            self.jobs.put((self._send_card, (p,)))

    def on_update(self, p: Pending) -> None:
        if self.enabled and self.cfg.telegram.chat_id is not None:
            self.jobs.put((self._edit_card, (p,)))

    def on_notice(self, project: Project, text: str) -> None:
        if self.enabled and self.cfg.telegram.chat_id is not None:
            self.jobs.put((self._send_notice, (project, text)))

    # ---------------------------------------------------------------- render

    def card_text(self, p: Pending) -> str:
        who = esc(p.tab_title or p.session_id[:8] or "?")
        head = f"{LEVEL_ICON[p.level]} <b>{LEVEL_NAMES[p.level]}</b> · {esc(p.project)} · {who}"
        lines = [head, f"<pre>{esc(p.summary[:900])}</pre>", esc(p.reason)]
        if p.level >= L3:
            lines.append("⚠️ 高風險：需要二次確認，不能設成一律允許")
        if p.open:
            mins = max(0, int((p.deadline - time.time()) // 60))
            lines.append(f"⏳ {mins} 分鐘後逾時並拒絕 · 回覆這則訊息可附上拒絕理由")
        else:
            when = time.strftime("%H:%M")
            src = SOURCE_TEXT.get(p.decided_by, p.decided_by)
            lines.append(f"<b>{STATE_TEXT.get(p.state, p.state)}</b>（{esc(src)} · {when}）")
            if p.always_added:
                lines.append(f"♾ 之後此專案一律允許 <code>{esc(p.always_added)}</code>")
        return "\n".join(lines)

    def keyboard(self, p: Pending) -> dict | None:
        if not p.open:
            return None
        b = lambda text, action: {"text": text, "callback_data": f"g:{p.id}:{action}"}
        if p.state == "confirming":
            rows = [[b("⚠️ 確定同意", "confirm"), b("↩︎ 取消", "cancel")], [b("❌ 拒絕", "deny")]]
        elif p.level >= L3:
            rows = [[b("✅ 同意（需再確認）", "allow"), b("❌ 拒絕", "deny")]]
        else:
            rows = [[b("✅ 同意", "allow"), b("❌ 拒絕", "deny")]]
            if p.always_pattern:
                label = p.always_pattern if len(p.always_pattern) <= 40 else p.always_pattern[:39] + "…"
                rows.append([b(f"♾ 此專案一律允許 {label}", "always")])
        return {"inline_keyboard": rows}

    # --------------------------------------------------------------- outgoing

    def _send_card(self, p: Pending) -> None:
        if not p.open:
            return
        project = self.broker.projects.get(p.project)
        msg = self.call("sendMessage", chat_id=self.cfg.telegram.chat_id,
                        message_thread_id=self._thread(project), text=self.card_text(p),
                        parse_mode="HTML", reply_markup=self.keyboard(p))
        p.tg_message_id = msg["message_id"]
        if not p.open:  # decided elsewhere while we were sending
            self._edit_card(p)

    def _edit_card(self, p: Pending) -> None:
        if p.tg_message_id is None:
            return
        try:
            self.call("editMessageText", chat_id=self.cfg.telegram.chat_id,
                      message_id=p.tg_message_id, text=self.card_text(p), parse_mode="HTML",
                      reply_markup=self.keyboard(p) or {"inline_keyboard": []})
        except RuntimeError as e:
            if "not modified" not in str(e):
                raise

    def _send_notice(self, project: Project, text: str) -> None:
        self.call("sendMessage", chat_id=self.cfg.telegram.chat_id,
                  message_thread_id=self._thread(project),
                  text=f"👻 {project.name}\n{text}", disable_notification=True)

    # --------------------------------------------------------------- incoming

    def _authorized(self, user: dict, chat: dict) -> bool:
        allowed = self.cfg.telegram.allowed_user_ids
        if allowed:
            return user.get("id") in allowed
        # No allow-list: only a private chat with the configured chat id.
        return chat.get("type") == "private" and chat.get("id") == self.cfg.telegram.chat_id

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
            parts = (cq.get("data") or "").split(":")
            if len(parts) != 3 or parts[0] != "g":
                return
            ok, why = self.broker.decide(parts[1], parts[2], "tg")
            self.call("answerCallbackQuery", callback_query_id=cq["id"], text=why)
            return

        m = u.get("message") or {}
        chat, user, text = m.get("chat") or {}, m.get("from") or {}, (m.get("text") or "").strip()
        if text.startswith("/chatid"):
            # Setup helper: works before chat_id is configured.
            self.call("sendMessage", chat_id=chat["id"], message_thread_id=m.get("message_thread_id"),
                      text=f"chat_id: {chat['id']}\nthread_id: {m.get('message_thread_id')}\n"
                           f"user_id: {user.get('id')}")
            return
        if not self._authorized(user, chat):
            return
        reply = m.get("reply_to_message") or {}
        if reply.get("message_id") and text and not text.startswith("/"):
            for p in list(self.broker.pending.values()):
                if p.tg_message_id == reply["message_id"]:
                    ok, why = self.broker.decide(p.id, "deny", "tg", message=text)
                    self.call("sendMessage", chat_id=chat["id"],
                              message_thread_id=m.get("message_thread_id"),
                              reply_to_message_id=m["message_id"],
                              text=("已拒絕，並把理由轉給對話" if ok else why))
                    return
        if text.startswith("/pending"):
            pend = list(self.broker.pending.values())
            if not pend:
                self.call("sendMessage", chat_id=chat["id"],
                          message_thread_id=m.get("message_thread_id"), text="目前沒有待決策的請求 👍")
            for p in pend:  # re-send so buttons are at the bottom of the chat
                self.jobs.put((self._send_card, (p,)))
            return
        if text.startswith("/status"):
            rows = self.broker.list_sessions()[:20]
            icon = {"running": "⚙️", "waiting": "🙋", "done": "✅"}
            lines = [f"{icon.get(s['status'], '·')} {s['project']} · {s['tab_title'] or s['session_id'][:8]}"
                     for s in rows] or ["沒有進行中的對話"]
            self.call("sendMessage", chat_id=chat["id"], message_thread_id=m.get("message_thread_id"),
                      text="\n".join(lines))
