"""TG watch commands edit watch.yaml; /pause holds messages; attachments
are downloaded where the assistant can read them."""

import time

from ghost_agentd.account import AccountWatcher, Watch
from ghost_agentd.watchcmd import WatchCommands
from test_account import msg
from test_assistant import manager, roles, wait_for  # noqa: F401  (fixtures)
from test_broker import broker, home  # noqa: F401  (fixtures)


class FakeTransport:
    def __init__(self, uploads):
        self.uploads = uploads

    def groups(self, keyword="", limit=8):
        all_ = [(-1001, "大玩家技术群（新）"), (-1002, "FQ 研發群"), (-1003, "閒聊")]
        return [g for g in all_ if keyword.lower() in g[1].lower()][:limit]

    def send(self, *a):
        pass

    def history(self, chat_id, limit):
        f = self.uploads / "20261015-010101-abcd-shot.png"
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_bytes(b"png")
        return [{"ts": time.time(), "sender": "Amy", "text": "看這張", "media": "圖片", "file": str(f)},
                {"ts": time.time(), "sender": "Amy", "text": "", "media": "影片", "file": "", "skip": "超過 20 MB"}]


def setup(broker, manager):
    p = broker.projects.get("fq")
    (p.dir / "watch.yaml").write_text("window: always\nbatch: 0\n")
    w = AccountWatcher(broker, manager, p)
    w.transport = FakeTransport(w.uploads)
    w.me = "@SnakeFQ"
    return p, w, WatchCommands({"fq": w})


def test_watch_flow_writes_watch_yaml(broker, manager):
    p, w, c = setup(broker, manager)
    assert c.handles("/watch FQ") and c.handles("/watches") and not c.handles("/status")
    text, rows = c.command("fq", "/watch 研發")
    assert "哪個群組" in text and rows[0][0]["text"] == "FQ 研發群"
    text, rows, _ = c.callback(rows[0][0]["callback_data"], ["fq"])
    assert "什麼訊息" in text
    text, rows, _ = c.callback(rows[0][1]["callback_data"], ["fq"])  # only @me
    assert "多久" in text
    text, rows, _ = c.callback(rows[1][0]["callback_data"], ["fq"])  # 7 days
    assert "開始監看「FQ 研發群」" in text and "只有 @我" in text and "到 " in text
    rule = Watch.load(p.dir / "watch.yaml").groups[0]
    assert rule.group == "-1002" and rule.trigger == "mention" and rule.window.until
    assert "FQ 研發群：只有 @我" in c.command("fq", "/watches")[0]
    # Keywords skip the trigger step; a rule for the same group is replaced.
    text, rows = c.command("fq", "/watch 研發 kw:bug,壞了")
    text, rows, _ = c.callback(rows[0][0]["callback_data"], ["fq"])
    assert "多久" in text
    c.callback(rows[0][0]["callback_data"], ["fq"])
    groups = Watch.load(p.dir / "watch.yaml").groups
    assert len(groups) == 1 and groups[0].trigger == {"keywords": ["bug", "壞了"]}
    # Another project's group can't press these.
    text, rows = c.command("fq", "/watch 閒聊")
    assert c.callback(rows[0][0]["callback_data"], ["lts"])[2] == "不屬於這個群組的專案"
    # /unwatch
    text, rows = c.command("fq", "/unwatch")
    text, rows, _ = c.callback(rows[0][0]["callback_data"], ["fq"])
    assert "已停止監看「FQ 研發群」" in text and not Watch.load(p.dir / "watch.yaml").groups
    assert "找不到" in c.command("fq", "/watch 不存在的群")[0]
    assert "沒有設定工作帳號" in c.command("lts", "/watches")[0]


def test_pause_holds_messages(broker, manager):
    p, w, c = setup(broker, manager)
    assert "先不轉給助手" in c.command("fq", "/pause 2h")[0]
    w.on_message(msg(private=True, text="暫停中來的"))
    w.tick()
    assert w.queue and not any(r == "user" for r, _ in roles(manager.get("fq")))
    assert "暫停中" in c.command("fq", "/watches")[0]
    c.command("fq", "/resume")
    w.tick()
    wait_for(lambda: any(r == "user" and "暫停中來的" in t for r, t in roles(manager.get("fq"))))


def test_attachments_reach_the_assistant(broker, manager):
    p, w, c = setup(broker, manager)
    f = w.uploads / "20261015-020202-beef-error.png"
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_bytes(bytes.fromhex("89504e470d0a1a0a"))
    w.on_message(msg(private=True, text="報錯截圖", media="圖片", files=[str(f)]))
    w.tick()
    a = manager.get("fq")
    wait_for(lambda: any(i.role == "user" and i.files for i in a.items))
    item = next(i for i in a.items if i.role == "user")
    assert str(f) in item.text and item.files[0]["name"] == "error.png"
    ref = next(iter(w.inbox))
    out = w.history(ref)
    assert "圖片已存：" in out and "shot.png" in out and "超過 20 MB" in out
