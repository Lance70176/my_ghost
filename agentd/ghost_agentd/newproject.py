"""Adding a project assistant from MyGhost (the ✦ "new assistant" form).

    POST /api/projects/probe   {"token"} -> the bot, and the groups it was
                               added to lately (so the form can offer them)
    POST /api/projects         {"name", "path", "token", "chat_id"?,
                                "resident"?, "commanders"?} -> writes
                               projects/<name>/project.yaml and brings the
                               bot and the assistant up without a restart

Both are loopback only: a token is a secret, and a new project decides who
may command an assistant.
"""

from __future__ import annotations

import json
import os
import re
import urllib.error
import urllib.request

from . import config as cfgmod
from .broker import log

NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,39}$")
TOKEN = re.compile(r"^\d{5,}:[A-Za-z0-9_-]{30,}$")


def _tg(token: str, method: str, **params) -> dict:
    url = f"https://api.telegram.org/bot{token}/{method}"
    req = urllib.request.Request(url, data=json.dumps(params).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return json.loads(e.read() or b"{}")


def _quote(s: str) -> str:
    return json.dumps(s, ensure_ascii=False)


class ProjectSetup:
    def __init__(self, broker, on_added=None):
        self.broker = broker
        self.on_added = on_added  # (project name) -> None, set by main
        self.polled: set[str] = set()  # tokens a running bot already polls

    def _token_users(self, token: str) -> list[str]:
        return [p.name for p in self.broker.projects.all() if p.tg_token == token]

    def probe(self, body: dict) -> tuple[int, dict]:
        token = str(body.get("token") or "").strip()
        if not TOKEN.match(token):
            return 400, {"ok": False, "message": "Bot token 格式不對（應該像 123456:ABC…，向 @BotFather 拿）"}
        me = _tg(token, "getMe")
        if not me.get("ok"):
            return 400, {"ok": False, "message": f"Telegram 不認得這個 token：{me.get('description', '')}"}
        bot = me["result"]
        out = {"ok": True, "bot": "@" + bot.get("username", ""), "bot_name": bot.get("first_name", ""),
               "privacy": not bot.get("can_read_all_group_messages", False),
               "used_by": self._token_users(token), "groups": []}
        if token in self.polled:
            # getUpdates would fight the running bot (409); its groups are
            # the projects' own.
            out["message"] = "這個 bot 已經在服務其他專案，群組可在下面直接填，或之後在群組打 /chatid。"
            return 200, out
        ups = _tg(token, "getUpdates", allowed_updates=["message", "my_chat_member"])
        groups: dict[int, dict] = {}
        for u in ups.get("result") or []:
            m = u.get("message") or u.get("my_chat_member") or {}
            chat = m.get("chat") or {}
            moved = (u.get("message") or {}).get("migrate_to_chat_id")
            if moved:
                old = groups.pop(chat.get("id"), None)
                groups[moved] = {"id": moved, "title": (old or chat).get("title", ""), "member": True}
                continue
            if chat.get("type") not in ("group", "supergroup"):
                continue
            status = ((u.get("my_chat_member") or {}).get("new_chat_member") or {}).get("status")
            entry = groups.setdefault(chat["id"], {"id": chat["id"], "title": chat.get("title", ""), "member": True})
            entry["title"] = chat.get("title", entry["title"])
            if status in ("left", "kicked"):
                entry["member"] = False
            elif status:
                entry["member"] = True
        out["groups"] = [g for g in groups.values() if g["member"]]
        for g in out["groups"]:
            n = _tg(token, "getChatMemberCount", chat_id=g["id"])
            g["members"] = n.get("result")
        return 200, out

    def create(self, body: dict) -> tuple[int, dict]:
        name = str(body.get("name") or "").strip()
        path = os.path.expanduser(str(body.get("path") or "").strip())
        token = str(body.get("token") or "").strip()
        if not NAME.match(name) or name == cfgmod.DEFAULT_PROJECT:
            return 400, {"ok": False, "message": "專案名稱只能用英數字、底線、點、減號（最多 40 字）"}
        folder = cfgmod.HOME / "projects" / name
        if (folder / "project.yaml").exists():
            return 409, {"ok": False, "message": f"已經有「{name}」這個專案助手了"}
        if not path or not os.path.isabs(path) or not os.path.isdir(path):
            return 400, {"ok": False, "message": "專案資料夾不存在（要填完整路徑）"}
        real = os.path.realpath(path).rstrip("/")
        for p in self.broker.projects.all():
            if any(os.path.realpath(x).rstrip("/") == real for x in p.paths):
                return 409, {"ok": False, "message": f"這個資料夾已經屬於「{p.name}」助手"}
        chat_id = body.get("chat_id")
        try:
            chat_id = int(chat_id) if chat_id not in (None, "") else None
        except (TypeError, ValueError):
            return 400, {"ok": False, "message": "群組 chat_id 要是數字（例如 -5183162852）"}
        commanders = []
        for c in body.get("commanders") or []:
            try:
                commanders.append(int(c))
            except (TypeError, ValueError):
                return 400, {"ok": False, "message": f"指揮者 user_id 要是數字：{c}"}
        bot = ""
        if token:
            if not TOKEN.match(token):
                return 400, {"ok": False, "message": "Bot token 格式不對"}
            me = _tg(token, "getMe")
            if not me.get("ok"):
                return 400, {"ok": False, "message": f"Telegram 不認得這個 token：{me.get('description', '')}"}
            bot = "@" + me["result"].get("username", "")
        resident = bool(body.get("resident", True))

        lines = [
            f"name: {name}",
            "paths:",
            f"  - {_quote(path)}  # every repo below this folder belongs to {name}",
            f"resident: {'true' if resident else 'false'}"
            + ("            # assistant kept running, watching all the time" if resident
               else "           # wakes on events, sleeps after 30 idle minutes"),
            "telegram:",
        ]
        if token:
            lines += [f"  # {bot} — {name}'s own bot; nothing else may poll it.",
                      f"  token: {_quote(token)}",
                      f"  chat_id: {chat_id if chat_id is not None else 'null'}"
                      + ("    # set by sending /chatid in the group" if chat_id is None else "")]
        else:
            lines += ["  token: \"\"            # no bot: cards only in MyGhost",
                      "  chat_id: null"]
        if commanders:
            lines += ["  # Members besides the owner (config.yaml commanders); add more in the",
                      "  # group: reply to their message with /addmember",
                      f"  commander_user_ids: [{', '.join(map(str, commanders))}]"]
        else:
            lines += ["  # Members besides the owner (config.yaml commanders); add them in the",
                      "  # group: reply to their message with /addmember",
                      "  commander_user_ids: []"]
        lines += [
            "policy:",
            "  # Globs on the whole command. allow = L2 -> L1, deny = always ask,",
            "  # l0 / l1 = extra silent / notify-after rules, l3 = regex, double confirm.",
            "  allow: []", "  deny: []", "  l0: []", "  l1: []", "  l3: []", "",
        ]
        folder.mkdir(parents=True, exist_ok=True)
        f = folder / "project.yaml"
        tmp = f.with_suffix(".tmp")
        tmp.write_text("\n".join(lines), encoding="utf-8")
        os.chmod(tmp, 0o600)  # holds the bot token
        tmp.replace(f)
        log(f"project {name}: created from MyGhost ({path}, bot {bot or '-'}, chat {chat_id}, "
            f"{'resident' if resident else 'on events'})")
        self.broker.projects.reload()
        if self.on_added:
            try:
                self.on_added(name)
            except Exception as e:
                log(f"project {name}: bring-up failed {e!r}")
        self.broker.bump()
        msg = f"已建立「{name}」助手"
        if token and chat_id is None:
            msg += f"。把 {bot} 拉進專案群組後，在群組打 /chatid 就會自動綁定"
        return 200, {"ok": True, "message": msg, "project": name}
