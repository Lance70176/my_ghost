"""Assistant manager against a fake `claude` (no tokens spent)."""

import json
import sys
import threading
import time
from pathlib import Path

import pytest

from test_broker import broker, home, wait_pending  # noqa: F401  (fixtures)

FAKE = Path(__file__).with_name("fake_claude.py")


@pytest.fixture
def manager(broker, home, monkeypatch, tmp_path):
    from ghost_agentd import assistant
    script = tmp_path / "claude"
    script.write_text(f"#!/bin/sh\nexec {sys.executable} {FAKE} \"$@\"\n")
    script.chmod(0o755)
    monkeypatch.setattr(assistant, "CLAUDE", str(script))
    monkeypatch.setenv("FAKE_ARGV_LOG", str(tmp_path / "argv.log"))
    m = assistant.AssistantManager(broker, 7788)
    broker.listeners.append(m)
    yield m
    for a in list(m.assistants.values()):
        a.stop()


def wait_for(cond, timeout=8):
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.05)
    raise AssertionError("condition not met")


def roles(a):
    return [(i.role, i.text) for i in a.items]


def test_conversation_and_context_probe(manager):
    a = manager.get("fq")
    a.send("你好", "myghost")
    wait_for(lambda: ("assistant", "回覆：你好") in roles(a))
    # The /context probe after the turn is invisible but sets the usage.
    wait_for(lambda: a.context_pct == 10 and a._inflight is None and not a._outbox)
    assert all("Context" not in t for _, t in roles(a))
    assert ("tool", "read_state") in roles(a)
    assert not a.busy
    chat = manager.chat("fq", 0, 0)
    assert [i["role"] for i in chat["items"]] == ["user", "tool", "assistant"]
    saved = (a.dir / "chat.jsonl").read_text().splitlines()
    assert len(saved) == 3


def test_compaction_when_context_is_high(manager, monkeypatch):
    monkeypatch.setenv("FAKE_CTX", "85")
    a = manager.get("fq")
    a.send("看一下", "myghost")
    wait_for(lambda: any(r == "notice" and "已壓縮" in t for r, t in roles(a)))
    assert any(r == "notice" and "85%" in t for r, t in roles(a))
    # The save-then-compact exchange stays out of the visible chat.
    assert not any("update_state" in t for _, t in roles(a) if _ in ("user", "assistant"))


def test_resume_after_restart(manager, tmp_path):
    a = manager.get("fq")
    a.start()
    sid = a.meta["session_id"]
    a.stop()
    a.start()
    log = tmp_path / "argv.log"
    wait_for(lambda: log.exists() and len(log.read_text().splitlines()) == 2)
    argv = [json.loads(l) for l in log.read_text().splitlines()]
    assert "--session-id" in argv[0] and sid in argv[0]
    assert "--resume" in argv[1] and sid in argv[1]
    assert "--model" in argv[1] and "claude-opus-5-5" in argv[1]


def test_choice_round_trip(manager, broker):
    a = manager.get("fq")
    a.start()
    c = broker.create_choice("fq", "要用哪個方案？", [{"label": "A"}, {"label": "B"}])
    assert any(i.role == "choice" and i.choice_id == c.id for i in a.items), (roles(a), c.id, [i.choice_id for i in a.items])
    ok, _ = broker.decide(c.id, "o1", "myghost")
    assert ok
    wait_for(lambda: any(r == "assistant" and "選了「B」" in t for r, t in roles(a)))
    assert next(i for i in a.items if i.role == "choice").chosen == "B"


def test_discuss_then_choice_decides_the_card(manager, broker, home):
    out = []
    payload = {"session_id": "w1", "cwd": f"{home}/code/fq", "tool_name": "Bash",
               "tool_input": {"command": "git push origin feature/x"}, "tab_title": "H5"}
    t = threading.Thread(target=lambda: out.append(broker.request_permission(payload)))
    t.start()
    card = wait_pending(broker)[0]
    broker.decide(card.id, "discuss", "myghost")
    a = manager.get("fq")
    wait_for(lambda: any(i.role == "discuss" and i.card_id == card.id for i in a.items))
    wait_for(lambda: any(r == "assistant" and "card_id=" + card.id in t for r, t in roles(a)))
    # The assistant asks; the commander picks the option tied to "allow".
    c = broker.create_choice("fq", "要推嗎？", [{"label": "同意", "action": "allow"},
                                                {"label": "拒絕", "action": "deny"}], card_id=card.id)
    ok, why = broker.decide(c.id, "o0", "myghost")
    assert ok and "已同意" in why
    t.join(2)
    assert out[0]["behavior"] == "allow"


def test_choice_without_card_cannot_decide_anything(manager, broker, home):
    out = []
    payload = {"session_id": "w2", "cwd": f"{home}/code/fq", "tool_name": "Bash",
               "tool_input": {"command": "rm -rf build"}}
    t = threading.Thread(target=lambda: out.append(broker.request_permission(payload)))
    t.start()
    card = wait_pending(broker)[0]
    c = broker.create_choice("fq", "?", [{"label": "同意", "action": "allow"}, {"label": "x"}])
    broker.decide(c.id, "o0", "myghost")
    assert card.open  # no card_id: the action is ignored
    broker.decide(card.id, "deny", "myghost")
    t.join(2)


def test_interrupt(manager):
    a = manager.get("fq")
    a.send("SLOW", "myghost")
    wait_for(lambda: a.busy)
    assert a.interrupt()
    wait_for(lambda: not a.busy)
    assert any(r == "notice" and "已停止" in t for r, t in roles(a))


def test_one_message_at_a_time(manager):
    """A message sent mid-turn waits for that turn to end, so every reply
    lands on its own message and the /context probe never shows."""
    a = manager.get("fq")
    a.send("SLOW", "myghost")
    wait_for(lambda: a._inflight is False)
    a.send("第二則", "myghost")
    assert a._outbox and a.busy  # held back, not written into the running turn
    wait_for(lambda: ("assistant", "回覆：第二則") in roles(a), timeout=12)
    wait_for(lambda: not a.busy and not a._outbox and a._inflight is None)
    assert all("Context" not in t for _, t in roles(a))
