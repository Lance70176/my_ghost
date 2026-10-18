"""Which conversations become cards, a dispatched conversation's questions,
and cards closed once their request is answered in the terminal."""
import json
import threading
import time

import pytest

from test_broker import home, wait_pending  # noqa: F401  (fixtures)


@pytest.fixture
def broker(home):
    """The default: only assistants and their dispatched work are held."""
    from ghost_agentd.broker import Broker
    from ghost_agentd.config import Config, Projects
    b = Broker(Config(decision_timeout=5, digest_seconds=0), Projects())
    b.tg_projects = {"fq", "_default"}
    return b


def bash(cwd, cmd, **extra):
    return {"session_id": "s1", "cwd": cwd, "tool_name": "Bash", "tool_input": {"command": cmd}, **extra}


def run(broker, payload, out, alive=None):
    t = threading.Thread(target=lambda: out.append(broker.request_permission(payload, alive=alive)))
    t.start()
    return t


def test_other_conversations_ask_in_their_own_terminal(broker, home):
    cwd = f"{home}/code/fq"
    r = broker.request_permission(bash(cwd, "git push origin main"))
    assert r["behavior"] == "ask" and not broker.pending
    # What the rules allow by themselves is still allowed silently.
    assert broker.request_permission(bash(cwd, "ls -la"))["behavior"] == "allow"
    # An assistant's own conversation is still held as a card.
    out = []
    t = run(broker, bash(cwd, "git push origin main", assistant="fq"), out)
    p = wait_pending(broker)[0]
    broker.decide(p.id, "allow", "tg")
    t.join(2)
    assert out[0]["behavior"] == "allow"


def test_card_closed_when_answered_in_the_terminal(broker, home, monkeypatch):
    from ghost_agentd import broker as bmod
    monkeypatch.setattr(bmod, "ALIVE_POLL", 0.05)
    monkeypatch.setattr(bmod, "ORPHAN_GRACE", 0.1)
    connected = {"yes": True}
    out = []
    t = run(broker, bash(f"{home}/code/fq", "git push origin main", assistant="fq"), out,
            alive=lambda: connected["yes"])
    p = wait_pending(broker)[0]
    connected["yes"] = False  # Claude Code ended the hook: answered elsewhere
    t.join(2)
    for _ in range(50):
        if not p.open:
            break
        time.sleep(0.02)
    assert not p.open and p.decided_by == "terminal" and p.id not in broker.pending


WORKER = {"id": "d1", "title": "後台文章：網址自動清理", "card": "c0ffee00",
          "requested_by": {"id": 7, "name": "王爾莎"}, "label": "FQ AI - 後台文章：網址自動清理"}


def ask_payload(home, questions):
    return {"session_id": "w1", "cwd": f"{home}/code/fq", "tool_name": "AskUserQuestion",
            "tool_input": {"questions": questions}}


def test_dispatched_question_becomes_a_card_and_answers_it(broker, home):
    proj = broker.projects.get("fq")
    proj.dir.mkdir(parents=True, exist_ok=True)
    (proj.dir / "decisions.jsonl").write_text(
        json.dumps({"id": "c0ffee00", "serial": 5, "serial_day": "10/17"}) + "\n")
    broker.dispatched_to = lambda payload: "fq" if payload.get("session_id") == "w1" else None
    broker.worker_of = lambda payload: WORKER if payload.get("session_id") == "w1" else None
    qs = [{"question": "可以合併並上線嗎？", "header": "上線",
           "options": [{"label": "同意合併並上線", "description": "ff-merge 後部署"},
                       {"label": "先不要上線", "description": "停在分支"}], "multiSelect": False}]
    out = []
    t = run(broker, ask_payload(home, qs), out)
    p = wait_pending(broker)[0]
    assert p.kind == "choice" and p.worker_ask["dispatch"] == "d1"
    assert p.summary.startswith("🔁 延伸自決策卡 #5（10/17）「🚀 開工：後台文章：網址自動清理」")
    assert "可以合併並上線嗎？" in p.summary and p.requested_by["name"] == "王爾莎"
    assert [o["label"] for o in p.options] == ["同意合併並上線", "先不要上線"]
    broker.decide(p.id, "o0", "tg")
    t.join(2)
    r = out[0]
    assert r["behavior"] == "allow"
    assert r["updatedInput"]["answers"] == {"可以合併並上線嗎？": "同意合併並上線"}
    assert r["updatedInput"]["questions"] == qs


def test_skipped_question_goes_back_to_the_terminal(broker, home):
    broker.dispatched_to = lambda payload: "fq"
    broker.worker_of = lambda payload: WORKER
    qs = [{"question": f"Q{i}", "options": [{"label": "A"}, {"label": "B"}]} for i in range(2)]
    out = []
    t = run(broker, ask_payload(home, qs), out)
    first, second = sorted(wait_pending(broker, 2), key=lambda c: c.key)
    assert "（第 1／2 題）" in first.summary
    broker.decide(first.id, "deny", "tg")
    t.join(2)
    assert out[0]["behavior"] == "ask"
    assert not second.open and second.decided_by == "terminal"


def test_not_dispatched_question_is_left_alone(broker, home):
    qs = [{"question": "Q", "options": [{"label": "A"}, {"label": "B"}]}]
    assert broker.request_permission(ask_payload(home, qs))["behavior"] == "ask"
    assert not broker.pending
