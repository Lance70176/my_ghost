"""TG commands that change what a project's work account watches (P3).

In the project's group (commander only):

    /watches              the rules in force
    /watch [name] [kw:a,b]
                          pick one of the account's groups (buttons), then
                          what wakes the assistant and for how long
    /unwatch              pick a rule to remove
    /pause [2h|30m|1d]    hold the account's messages (they wait), /resume

They edit projects/<name>/watch.yaml, which the watcher re-reads.
"""

from __future__ import annotations

import re
import secrets
import time
from datetime import datetime, timedelta

import yaml

from .account import DEFAULT_WATCH, AccountWatcher

OFFICE = "mon-fri 08:30-18:20"
HEADER = "".join(l + "\n" for l in DEFAULT_WATCH.splitlines() if l.startswith("#"))


def load_raw(w: AccountWatcher) -> dict:
    w.watch()  # writes the default file if there's none
    try:
        raw = yaml.safe_load((w.project.dir / "watch.yaml").read_text(encoding="utf-8")) or {}
    except yaml.YAMLError:
        raw = yaml.safe_load(DEFAULT_WATCH)
    raw.setdefault("groups", [])
    return raw


def save_raw(w: AccountWatcher, raw: dict) -> None:
    f = w.project.dir / "watch.yaml"
    tmp = f.with_suffix(".tmp")
    tmp.write_text(HEADER + yaml.safe_dump(raw, allow_unicode=True, sort_keys=False), encoding="utf-8")
    tmp.replace(f)
    w._watch = None  # re-read now


def describe_window(spec) -> str:
    spec = str(spec or "always")
    if spec == "always":
        return "一直"
    if spec == OFFICE:
        return "平日 08:30–18:20"
    m = re.search(r"until\s+(\d{4}-\d{2}-\d{2})", spec)
    return f"到 {m.group(1)}" if m else spec


def describe_trigger(t) -> str:
    if t == "all":
        return "全部訊息"
    if t == "mention":
        return "只有 @我／回覆我"
    if isinstance(t, dict) and t.get("keywords"):
        return "關鍵字：" + "、".join(map(str, t["keywords"]))
    if isinstance(t, dict) and t.get("from"):
        return "只看：" + "、".join(map(str, t["from"]))
    return str(t)


def parse_duration(text: str) -> int:
    m = re.match(r"^\s*(\d+)\s*(m|min|h|d)?\s*$", text or "")
    if not m:
        return 3600
    n, unit = int(m.group(1)), m.group(2) or "h"
    return n * {"m": 60, "min": 60, "h": 3600, "d": 86400}[unit]


class WatchCommands:
    """Handles the commands and their buttons for every project with a work
    account. `send(chat_id, text, buttons)` posts a message."""

    def __init__(self, accounts: dict[str, AccountWatcher]):
        self.accounts = accounts
        self.picks: dict[str, dict] = {}  # token -> a /watch in progress

    def handles(self, text: str) -> bool:
        return bool(re.match(r"^/(watch|watches|unwatch|pause|resume)(@\w+)?\b", text or ""))

    # ------------------------------------------------------------ commands

    def command(self, project: str, text: str) -> tuple[str, list]:
        """(reply text, button rows) for a command typed in the project's chat."""
        w = self.accounts.get(project)
        if w is None:
            return f"{project} 沒有設定工作帳號，沒有東西可以監看。", []
        cmd, _, arg = text.partition(" ")
        cmd = cmd.split("@")[0]
        arg = arg.strip()
        if cmd == "/watches":
            return self.list_rules(w), []
        if cmd == "/pause":
            until = w.pause(parse_duration(arg))
            return (f"⏸ {w.me or '工作帳號'} 的訊息先不轉給助手，到 {time.strftime('%m/%d %H:%M', time.localtime(until))}；"
                    "期間的訊息會排隊，之後一起交給助手。提早恢復：/resume"), []
        if cmd == "/resume":
            w.pause(0)
            return "▶️ 恢復：排隊中的訊息會在一分鐘內交給助手。", []
        if cmd == "/unwatch":
            groups = load_raw(w)["groups"]
            if not groups:
                return "目前沒有指定監看的群組（只看私訊和 @我）。", []
            rows = [[{"text": f"✖️ {g.get('title') or g.get('group')}",
                      "callback_data": f"w:rm:{project}:{g.get('group')}"[:64]}] for g in groups]
            return "要停止監看哪一個？", rows
        # /watch [name] [kw:a,b]
        kw = []
        m = re.search(r"\bkw:(\S+)", arg)
        if m:
            kw = [k for k in re.split(r"[,，、]", m.group(1)) if k]
            arg = (arg[:m.start()] + arg[m.end():]).strip()
        transport = w.transport
        if transport is None or not hasattr(transport, "groups"):
            return "工作帳號目前沒有連線，等它連上再試。", []
        try:
            found = transport.groups(arg)
        except Exception as e:
            return f"讀不到工作帳號的群組：{e}", []
        if not found:
            return f"{w.me or '工作帳號'} 的群組裡找不到「{arg}」。", []
        token = secrets.token_hex(3)
        self.picks[token] = {"project": project, "kw": kw, "ts": time.time(), "groups": dict(found)}
        rows = [[{"text": title[:40], "callback_data": f"w:g:{token}:{gid}"}] for gid, title in found]
        return "要監看哪個群組？" + (f"（關鍵字：{'、'.join(kw)}）" if kw else ""), rows

    def list_rules(self, w: AccountWatcher) -> str:
        raw = load_raw(w)
        lines = [f"👀 {w.me or '工作帳號'} 的監看規則"]
        dms = raw.get("dms", True)
        grants = [g for g in w.grants.all() if g.until > time.time()]
        lines.append(f"• 私訊：只轉已授權的人（{describe_window(dms if isinstance(dms, str) else raw.get('window'))}），"
                     "其他只記錄" + ("" if grants else "；目前沒有人"))
        lines += [f"　– {g.describe()}" for g in grants]
        if raw.get("mentions", True):
            lines.append(f"• 任何群組 @我／回覆我：{describe_window(raw.get('window'))}")
        for g in raw["groups"]:
            lines.append(f"• {g.get('title') or g.get('group')}：{describe_trigger(g.get('trigger', 'all'))}，"
                         f"{describe_window(g.get('window', raw.get('window')))}")
        if raw.get("ignore"):
            lines.append("• 不看：" + "、".join(map(str, raw["ignore"])))
        if w.paused_until > time.time():
            lines.append(f"⏸ 暫停中，到 {time.strftime('%m/%d %H:%M', time.localtime(w.paused_until))}")
        lines.append("新增 /watch 群名（可加 kw:關鍵字1,關鍵字2）　移除 /unwatch　暫停 /pause 2h")
        return "\n".join(lines)

    # ------------------------------------------------------------- buttons

    def callback(self, data: str, projects: list[str]) -> tuple[str, list, str]:
        """(new message text, button rows, toast) for a w:… button."""
        parts = data.split(":")
        if parts[1] == "rm" and len(parts) >= 4:
            project, gid = parts[2], ":".join(parts[3:])
            w = self.accounts.get(project)
            if w is None or project not in projects:
                return "", [], "不屬於這個群組的專案"
            raw = load_raw(w)
            gone = [g for g in raw["groups"] if str(g.get("group")) == gid]
            raw["groups"] = [g for g in raw["groups"] if str(g.get("group")) != gid]
            save_raw(w, raw)
            name = gone[0].get("title") or gid if gone else gid
            return f"✅ 已停止監看「{name}」。", [], "已移除"
        pick = self.picks.get(parts[2]) if len(parts) >= 4 else None
        if pick is None or time.time() - pick["ts"] > 1800:
            return "這個選單過期了，請重新 /watch。", [], "已過期"
        if pick["project"] not in projects:
            return "", [], "不屬於這個群組的專案"
        token = parts[2]
        if parts[1] == "g":
            pick["gid"] = int(parts[3])
            title = pick["groups"].get(pick["gid"], parts[3])
            pick["title"] = title
            if pick["kw"]:
                pick["trigger"] = {"keywords": pick["kw"]}
                return self._ask_window(token, title)
            rows = [[{"text": "全部訊息", "callback_data": f"w:t:{token}:all"},
                     {"text": "只有 @我／回覆我", "callback_data": f"w:t:{token}:mention"}]]
            return f"「{title}」：什麼訊息要交給助手？", rows, ""
        if parts[1] == "t":
            pick["trigger"] = parts[3] if parts[3] in ("all", "mention") else "all"
            return self._ask_window(token, pick["title"])
        if parts[1] == "w":
            choice = parts[3]
            if choice == "office":
                window = OFFICE
            elif choice.isdigit():
                window = "until " + (datetime.now() + timedelta(days=int(choice))).strftime("%Y-%m-%d")
            else:
                window = "always"
            w = self.accounts[pick["project"]]
            raw = load_raw(w)
            raw["groups"] = [g for g in raw["groups"] if str(g.get("group")) != str(pick["gid"])]
            raw["groups"].append({"group": str(pick["gid"]), "title": pick["title"],
                                  "trigger": pick["trigger"], "window": window})
            save_raw(w, raw)
            self.picks.pop(token, None)
            return (f"✅ 開始監看「{pick['title']}」：{describe_trigger(pick['trigger'])}，{describe_window(window)}。"
                    "\n看全部規則：/watches", [], "已設定")
        return "", [], "看不懂這個按鈕"

    def _ask_window(self, token: str, title: str) -> tuple[str, list, str]:
        rows = [[{"text": "一直", "callback_data": f"w:w:{token}:always"},
                 {"text": "平日上班時間", "callback_data": f"w:w:{token}:office"}],
                [{"text": "7 天", "callback_data": f"w:w:{token}:7"},
                 {"text": "30 天", "callback_data": f"w:w:{token}:30"}]]
        return f"「{title}」要監看多久？", rows, ""
