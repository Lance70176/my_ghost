"""Waiting cards survive a daemon restart."""
import threading
import time

from test_broker import broker, home, wait_pending  # noqa: F401  (fixtures)


def restart(broker):
    from ghost_agentd.broker import Broker
    from ghost_agentd.config import Projects
    again = Broker(broker.cfg, Projects())
    again.tg_projects = set(broker.tg_projects)
    return again


def test_choice_card_survives_and_can_still_be_pressed(broker, home):
    p = broker.create_choice("fq", "影片要縮短嗎？", [{"label": "縮短"}, {"label": "維持"}])
    p.requested_by = {"id": 7, "name": "王爾莎"}
    p.tg_message_id = 4242
    broker.save_pending()
    again = restart(broker)
    q = again.pending[p.id]
    assert q.summary == "影片要縮短嗎？" and q.tag == p.tag and q.tg_message_id == 4242
    assert q.requested_by["name"] == "王爾莎" and q.event is not None
    ok, _ = again.decide(p.id, "o1", "tg", actor={"owner": False, "id": 7, "name": "王爾莎"})
    assert ok and q.chosen == 1 and p.id not in again.pending
    # Decided cards leave the file too.
    assert p.id not in restart(again).pending


def test_permission_card_rejoined_by_its_hook(broker, home):
    out = []
    payload = {"session_id": "s1", "cwd": f"{home}/code/fq", "tool_name": "Bash",
               "tool_input": {"command": "git push origin main"}, "request_key": "k-rejoin"}
    t = threading.Thread(target=lambda: out.append(broker.request_permission(payload)), daemon=True)
    t.start()
    p = wait_pending(broker)[0]
    again = restart(broker)  # the old daemon's hook connection is gone
    out2 = []
    t2 = threading.Thread(target=lambda: out2.append(again.request_permission(payload)))
    t2.start()
    time.sleep(0.1)
    assert list(again.pending) == [p.id]  # re-joined, no second card
    again.decide(p.id, "allow", "tg")
    t2.join(2)
    assert out2[0]["behavior"] == "allow"


def test_restored_permission_card_closed_when_no_hook_returns(broker, home, monkeypatch):
    from ghost_agentd import broker as bmod
    t = threading.Thread(target=lambda: broker.request_permission(
        {"session_id": "s1", "cwd": f"{home}/code/fq", "tool_name": "Bash",
         "tool_input": {"command": "git push origin main"}}), daemon=True)
    t.start()
    p = wait_pending(broker)[0]
    monkeypatch.setattr(bmod, "RESTORE_GRACE", 0.1)
    again = restart(broker)
    for _ in range(50):
        if p.id not in again.pending:
            break
        time.sleep(0.02)
    assert p.id not in again.pending


def test_decider_named_not_pronoun():
    """The assistant is told who decided by name, never just 他."""
    from types import SimpleNamespace
    from ghost_agentd.assistant import decider_label
    assert decider_label(SimpleNamespace(decided_actor=None), {"id": 7, "name": "王爾莎"}) == "王爾莎"
    assert decider_label(SimpleNamespace(decided_actor={"owner": True, "name": "Rex"}), None) == "負責人（Rex）"
    assert decider_label(SimpleNamespace(decided_actor={"owner": True}), None) == "負責人"


def test_decider_uses_owner_name_when_set(monkeypatch):
    from types import SimpleNamespace
    from ghost_agentd import config as cfgmod
    from ghost_agentd.assistant import decider_label
    monkeypatch.setattr(cfgmod, "OWNER", "Rex Lu")
    assert decider_label(SimpleNamespace(decided_actor={"owner": True, "name": "RexLu"}), None) == "Rex Lu"
    assert decider_label(SimpleNamespace(decided_actor=None), {"id": 7, "name": "王爾莎"}) == "王爾莎"
