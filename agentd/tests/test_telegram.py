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
    cfg = Config(decision_timeout=5,
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
