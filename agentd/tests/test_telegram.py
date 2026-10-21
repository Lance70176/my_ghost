import threading
import time

import pytest

COMMANDER = 111


@pytest.fixture
def setup(tmp_path, monkeypatch):
    from ghost_agentd import config
    monkeypatch.setattr(config, "HOME", tmp_path)
    for name, token, chat in (("fq", "TOKEN_FQ", -1001), ("lts", "TOKEN_LTS", -1002), ("yc", "", None)):
        d = tmp_path / "projects" / name
        d.mkdir(parents=True)
        (tmp_path / "code" / name).mkdir(parents=True)
        tg = f"telegram: {{token: '{token}', chat_id: {chat}}}\n" if token else ""
        (d / "project.yaml").write_text(f"paths: ['{tmp_path}/code/{name}']\n{tg}")
    from ghost_agentd.broker import Broker
    from ghost_agentd.config import Config, Projects, TelegramConfig
    from ghost_agentd.telegram import build_bots
    cfg = Config(decision_timeout=5, hold_every_conversation=True,
                 telegram=TelegramConfig(token="TOKEN_FALLBACK", chat_id=COMMANDER,
                                         commander_user_ids=[COMMANDER]))
    broker = Broker(cfg, Projects())
    bots = {b.token: b for b in build_bots(cfg, broker)}
    sent = []
    for b in bots.values():
        b.call = lambda method, _b=b, **kw: sent.append((_b.token, method, kw)) or {"message_id": len(sent)}
        b.start()
        broker.listeners.append(b)
    return tmp_path, broker, bots, sent


def drain(bot):
    while not bot.jobs.empty():
        fn, args = bot.jobs.get()
        fn(*args)


def test_each_project_routes_to_its_own_bot_and_group(setup):
    home, broker, bots, sent = setup
    assert bots["TOKEN_FQ"].routes == {"fq": -1001}
    assert bots["TOKEN_LTS"].routes == {"lts": -1002}
    # yc has no bot of its own, so it and _default use the fallback bot.
    assert set(bots["TOKEN_FALLBACK"].routes) == {"yc", "_default"}
    assert broker.tg_projects == {"fq", "lts", "yc", "_default"}

    out = []
    t = threading.Thread(target=lambda: out.append(broker.request_permission({
        "session_id": "s", "cwd": f"{home}/code/lts", "tool_name": "Bash",
        "tool_input": {"command": "rm -rf build"}})))
    t.start()
    for _ in range(100):
        if broker.pending:
            break
        time.sleep(0.02)
    p = next(iter(broker.pending.values()))
    for b in bots.values():
        drain(b)
    cards = [s for s in sent if s[1] == "sendMessage"]
    assert [(c[0], c[2]["chat_id"]) for c in cards] == [("TOKEN_LTS", -1002)]

    lts = bots["TOKEN_LTS"]
    cb = lambda user, chat: {"callback_query": {"id": "q", "from": {"id": user},
                                                "message": {"chat": {"id": chat, "type": "supergroup"}},
                                                "data": f"g:{p.id}:allow"}}
    # A stranger in the right group can't decide.
    lts._handle(cb(999, -1002))
    assert p.open
    # The commander pressing in another project's group can't either.
    lts._handle(cb(COMMANDER, -1001))
    assert p.open
    lts._handle(cb(COMMANDER, -1002))
    t.join(2)
    assert out[0]["behavior"] == "allow"


def test_reply_to_card_denies_with_reason(setup):
    home, broker, bots, sent = setup
    out = []
    t = threading.Thread(target=lambda: out.append(broker.request_permission({
        "session_id": "s", "cwd": f"{home}/code/fq", "tool_name": "Bash",
        "tool_input": {"command": "git push origin feature/x"}})))
    t.start()
    for _ in range(100):
        if broker.pending:
            break
        time.sleep(0.02)
    fq = bots["TOKEN_FQ"]
    drain(fq)
    p = next(iter(broker.pending.values()))
    assert p.tg_message_id is not None
    fq._handle({"message": {"message_id": 99, "chat": {"id": -1001, "type": "supergroup"},
                            "from": {"id": COMMANDER}, "text": "先等 code review",
                            "reply_to_message": {"message_id": p.tg_message_id}}})
    t.join(2)
    assert out[0]["behavior"] == "deny" and "code review" in out[0]["message"]


def test_group_upgraded_to_supergroup_is_followed(setup, monkeypatch):
    """Making a bot admin can turn a group into a supergroup with a new id;
    the bot follows it and writes the new id to project.yaml."""
    _, broker, _, _ = setup
    import io
    import json as _json
    import urllib.error
    from ghost_agentd import telegram as tg
    p = broker.projects.get("fq")
    f = p.dir / "project.yaml"
    f.write_text("name: fq\ntelegram:\n  token: \"t\"\n  chat_id: -111    # group\n")
    bot = tg.Bot(broker.cfg, broker, "t")
    bot.routes["fq"] = -111
    sent = []

    def fake_urlopen(req, timeout=0):
        body = _json.loads(req.data)
        sent.append(body["chat_id"])
        if body["chat_id"] == -111:
            raise urllib.error.HTTPError(req.full_url, 400, "", {}, io.BytesIO(_json.dumps({
                "ok": False, "description": "group chat was upgraded to a supergroup chat",
                "parameters": {"migrate_to_chat_id": -100222}}).encode()))
        return io.BytesIO(_json.dumps({"ok": True, "result": {"message_id": 1}}).encode())

    monkeypatch.setattr(tg.urllib.request, "urlopen", fake_urlopen)
    assert bot.call("sendMessage", chat_id=-111, text="hi") == {"message_id": 1}
    assert sent == [-111, -100222] and bot.chat_for("fq") == -100222
    assert "chat_id: -100222    # group" in f.read_text()


def test_photo_with_caption_reaches_the_assistant(setup, monkeypatch, tmp_path):
    """A photo carries its words as a caption: the assistant gets both."""
    home, broker, bots, sent = setup
    fq = bots["TOKEN_FQ"]
    got = []

    class FakeAssistant:
        uploads = tmp_path / "uploads"

        def send(self, text, source, **kw):
            got.append((text, source, kw.get("files") or []))

    fq.assistants = type("M", (), {"get": lambda self, name: FakeAssistant()})()
    fq.call = lambda method, **kw: {"file_path": "photos/file_7.jpg"} if method == "getFile" else {}

    class Resp:
        def __init__(self, data): self.data = data
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def read(self, n=-1): return self.data

    from ghost_agentd import telegram
    monkeypatch.setattr(telegram.urllib.request, "urlopen", lambda url, timeout=0: Resp(b"\xff\xd8jpeg"))
    msg = {"message_id": 5, "chat": {"id": -1001, "type": "supergroup"}, "from": {"id": COMMANDER},
           "caption": "幫我確認這個是不是真的",
           "photo": [{"file_id": "small", "file_size": 10}, {"file_id": "big", "file_size": 2000}]}
    fq._handle({"message": msg})
    text, source, files = got[-1]
    assert text == "幫我確認這個是不是真的" and source == "tg"
    assert len(files) == 1 and files[0].path.suffix == ".jpg" and files[0].path.read_bytes() == b"\xff\xd8jpeg"

    # Too big for the Bot API: still delivered, with a note instead of the file.
    big = dict(msg, caption="", photo=[{"file_id": "huge", "file_size": 30 * 1024 * 1024}])
    fq._handle({"message": big})
    text, _, files = got[-1]
    assert not files and "20MB" in text


def test_cards_stand_out_from_chat(broker):
    from ghost_agentd.telegram import RULE, Bot
    bot = Bot.__new__(Bot)
    p = broker.create_choice("fq", "要不要換影片？", [{"label": "換"}, {"label": "不換"}])
    text = bot.card_text(p)
    assert text.startswith(RULE) and text.endswith(RULE) and "待你決定" in text
    assert "<blockquote>要不要換影片？</blockquote>" in text
    broker.decide(p.id, "deny", "tg")
    assert "已處理" in bot.card_text(p) and "<b>負責人選了：</b><code>略過</code>（TG · " in bot.card_text(p)


def test_answer_drawn_apart_from_question(broker):
    from ghost_agentd.telegram import Bot
    bot = Bot.__new__(Bot)
    p = broker.create_choice("fq", "上傳嗎？", [{"label": "OK <上傳>"}, {"label": "先不要"}])
    assert "❓ <b>fq 助手問負責人</b>" in bot.card_text(p)
    broker.decide(p.id, "o0", "myghost")
    assert "✅ <b>負責人選了：</b><code>OK &lt;上傳&gt;</code>（MyGhost · " in bot.card_text(p)


def test_decided_card_keeps_options_and_names_who(broker):
    """A member's card says who it asks; once pressed it still lists every
    option, ticks the picked one, and names who pressed it."""
    import json
    from ghost_agentd.telegram import Bot
    bot = Bot.__new__(Bot)
    p = broker.create_choice("fq", "影片放哪？", [{"label": "甲：上面"}, {"label": "乙：下面"}])
    p.requested_by = {"id": 7, "name": "王爾莎"}
    text = bot.card_text(p)
    assert "❓ <b>fq 助手問王爾莎</b>" in text and "👤 王爾莎 交辦（王爾莎和負責人都可以按）" in text
    broker.decide(p.id, "o1", "tg", actor={"owner": False, "id": 7, "name": "王爾莎"})
    text = bot.card_text(p)
    assert "<b>選項：</b>\n▫️ 甲：上面\n✅ 乙：下面" in text
    assert "✅ <b>王爾莎選了：</b><code>乙：下面</code>（TG · " in text
    rec = json.loads((broker.projects.get("fq").dir / "decisions.jsonl").read_text().splitlines()[-1])
    assert rec["decider"] == "王爾莎" and rec["chosen"] == "乙：下面"


def test_permission_card_names_who_decided(broker):
    from ghost_agentd.telegram import Bot
    bot = Bot.__new__(Bot)
    p = broker.create_choice("fq", "x", [{"label": "a"}])  # any card works for the name
    broker.decide(p.id, "o0", "tg", actor={"owner": True, "name": "Rex"})
    assert p.decider == "Rex"
    q = broker.create_choice("fq", "y", [{"label": "a"}])
    broker.decide(q.id, "o0", "web")
    assert q.decider == "負責人"


from test_broker import broker, home  # noqa: E402,F401  (fixtures)


def test_assistant_markdown_becomes_telegram_html():
    from ghost_agentd.telegram import md_to_html
    out = md_to_html("**真正要讓 PM 知道的**：a_b * 2 < 3\n"
                     "## 標題\n"
                     "看 `x<y` 和 [卡片](https://app.clickup.com/t/z8v0kmw7rx)\n"
                     "```\n【LSC】前/後台 **不轉** <b>\n```")
    assert out == ("<b>真正要讓 PM 知道的</b>：a_b * 2 &lt; 3\n"
                   "<b>標題</b>\n"
                   '看 <code>x&lt;y</code> 和 <a href="https://app.clickup.com/t/z8v0kmw7rx">卡片</a>\n'
                   "<pre>【LSC】前/後台 **不轉** &lt;b&gt;</pre>")
    # An unclosed fence still yields balanced tags.
    assert md_to_html("```\nhalf") == "<pre>half</pre>"


def test_bullets_and_sub_bullets_are_drawn():
    from ghost_agentd.telegram import md_to_html
    out = md_to_html("1. **香港角色**：沒改\n  - 原始 216 個\n    * 更深\n- 頂層 **粗**\n---\n**只是粗體**")
    assert out == ("1. <b>香港角色</b>：沒改\n"
                   "\u2003◦ 原始 216 個\n"
                   "\u2003\u2003◦ 更深\n"
                   "• 頂層 <b>粗</b>\n"
                   "---\n"
                   "<b>只是粗體</b>")


def test_owner_name_replaces_the_title(broker, monkeypatch):
    from ghost_agentd import config as cfgmod
    from ghost_agentd.telegram import asked, framed
    monkeypatch.setattr(cfgmod, "OWNER", "Rex Lu")
    p = broker.create_choice("fq", "要嗎", [{"label": "好"}, {"label": "不要"}])
    assert asked(p) == "Rex Lu"
    p.requested_by = {"id": 7, "name": "王爾莎"}
    assert "👤 王爾莎 交辦（王爾莎和Rex Lu都可以按）" in framed(p, [])


def test_code_block_split_across_messages_stays_a_block():
    from ghost_agentd.telegram import CHUNK, md_chunks, md_to_html
    text = "前言\n```\n" + "\n".join("x" * 80 for _ in range(100)) + "\n```\n結尾"
    chunks = md_chunks(text)
    assert len(chunks) == 3 and all(len(c) <= CHUNK + 4 for c in chunks)
    for c in chunks:
        h = md_to_html(c)
        assert h.count("<pre>") == h.count("</pre>")
    assert md_to_html(chunks[-1]).endswith("</pre>\n結尾")


def test_reply_falls_back_to_plain_when_telegram_refuses(setup):
    home, broker, bots, sent = setup
    bot = bots["TOKEN_FQ"]

    def call(method, **kw):
        if kw.get("parse_mode"):
            raise RuntimeError("sendMessage: Bad Request: can't parse entities")
        sent.append((bot.token, method, kw))
        return {"message_id": 1}
    bot.call = call
    item = type("Item", (), {"role": "assistant", "text": "**hi**", "source": ""})()
    bot.on_chat(broker.projects.get("fq"), item)
    drain(bot)
    assert sent[-1][2]["text"] == "**hi**" and "parse_mode" not in sent[-1][2]


def test_assistant_reply_quotes_the_tg_message(setup):
    """TG messages reach the assistant with their id, and the reply quotes
    it — only its first piece, when a long reply is split."""
    home, broker, bots, sent = setup
    fq = bots["TOKEN_FQ"]
    got = []

    class FakeAssistant:
        uploads = home / "uploads"

        def send(self, text, source, **kw):
            got.append(kw.get("tg_message"))

    fq.assistants = type("M", (), {"get": lambda self, name: FakeAssistant()})()
    fq._handle({"message": {"message_id": 77, "chat": {"id": -1001, "type": "supergroup"},
                            "from": {"id": COMMANDER}, "text": "#8 收了嗎"}})
    assert got == [77]

    from ghost_agentd.telegram import CHUNK
    item = type("Item", (), {"role": "assistant", "text": "結論\n\n" + "細節\n" * CHUNK, "source": "",
                             "tg_reply_to": 77})()
    fq.on_chat(broker.projects.get("fq"), item)
    drain(fq)
    replies = [kw.get("reply_parameters") for _, m, kw in sent if m == "sendMessage"]
    assert len(replies) >= 2
    assert replies[0] == {"message_id": 77, "allow_sending_without_reply": True}
    assert all(r is None for r in replies[1:])


def test_long_reply_folds_its_details():
    from ghost_agentd.telegram import tg_html
    assert "blockquote" not in tg_html("#8 已經收掉了。\n\n細節一句。")
    long = "**結論**：#8 已收掉。\n\n" + "\n".join(f"- 第 {i} 點細節說明比較長一點的內容" for i in range(20))
    h = tg_html(long)
    assert h.startswith("<b>結論</b>：#8 已收掉。\n<blockquote expandable>• 第 0 點")
    assert h.endswith("</blockquote>")
    # A heading alone keeps its paragraph out of the fold.
    h = tg_html("## 盤點\n\n兩件進行中。\n\n" + "x" * 400)
    assert h.startswith("<b>盤點</b>\n\n兩件進行中。\n<blockquote expandable>")
    # Code is never folded.
    assert "blockquote" not in tg_html("結論\n\n" + "x" * 400 + "\n```\ncode\n```")
