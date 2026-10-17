"""A newer card takes over older ones: they close, marked as handled by
the new card, so a late press can't make the assistant decide again."""

import json
import threading
import time

from ghost_agentd import tools
from test_assistant import manager, wait_for  # noqa: F401  (fixtures)
from test_broker import broker, home  # noqa: F401  (fixtures)
from test_dispatch import setup as dispatch_setup


def test_new_card_closes_the_ones_it_replaces(broker, manager, tmp_path, monkeypatch):
    p, root, d, tm = dispatch_setup(broker, manager, tmp_path, monkeypatch)
    t = tools.Tools(broker, manager, lambda name: None, dispatcher=d)
    old = broker.create_choice("fq", "用方案 A？", [{"label": "好"}, {"label": "不要"}])
    other = broker.create_choice("lts", "別的專案", [{"label": "好"}, {"label": "不要"}])
    d.propose(p, "做 A", "platform", "x", branch="feature/a")
    old_dispatch = next(x for x in broker.pending.values() if getattr(x, "dispatch", None))
    # A conversation's permission request is never the assistant's to close.
    perm = []
    threading.Thread(target=lambda: perm.append(broker.request_permission({
        "session_id": "s", "cwd": str(root / "platform"), "tool_name": "Bash",
        "tool_input": {"command": "rm -rf build"}})), daemon=True).start()
    wait_for(lambda: any(x.kind != "choice" for x in broker.pending.values()))
    perm_card = next(x for x in broker.pending.values() if x.kind != "choice")

    out = t.t_ask_decision(p, {"question": "改用方案 B？", "options": [{"label": "好"}, {"label": "不要"}],
                               "replaces": [old.id, old_dispatch.id, other.id, perm_card.id]})
    new_tag = out.split("（")[1].split("，")[0]  # "#2"
    assert f"已撤掉舊卡：{old.tag}、{old_dispatch.tag}" in out and "沒撤掉" in out
    assert not old.open and not old_dispatch.open and other.open and perm_card.open
    assert old.superseded_by == new_tag and new_tag.startswith("#") and old.decided_by == "superseded"
    assert next(iter(d.items.values())).state == "dropped"  # its proposal is off
    # A late press on the old card does nothing.
    assert broker.decide(old.id, "o0", "tg")[0] is False
    recs = [json.loads(l) for l in (p.dir / "decisions.jsonl").read_text().splitlines()]
    rec = next(r for r in recs if r["id"] == old.id)
    assert rec["superseded_by"] == new_tag and new_tag in rec["deny_message"] and rec["serial"]
    broker.decide(perm_card.id, "deny", "myghost")


def test_a_member_replaces_only_their_own(broker, manager):
    t = tools.Tools(broker, manager, lambda name: None)
    p = broker.projects.get("fq")
    elsa = {"id": 7, "name": "Elsa"}
    owners = broker.create_choice("fq", "負責人的", [{"label": "好"}, {"label": "不要"}])
    broker.requester_of = lambda name: elsa
    hers = broker.create_choice("fq", "她的", [{"label": "好"}, {"label": "不要"}])
    assert hers.requested_by == elsa
    out = t.t_ask_decision(p, {"question": "新的", "options": [{"label": "好"}, {"label": "不要"}],
                               "replaces": f"{hers.id}, {owners.id}"})
    assert not hers.open and owners.open and "不是這位成員交辦的卡" in out


def test_marked_in_the_assistants_chat(broker, manager):
    t = tools.Tools(broker, manager, lambda name: None)
    p = broker.projects.get("fq")
    a = manager.get("fq")
    old = broker.create_choice("fq", "舊題", [{"label": "好"}, {"label": "不要"}])
    a.add("choice", "舊題", choice_id=old.id)
    out = t.t_ask_decision(p, {"question": "新題", "options": [{"label": "好"}, {"label": "不要"}],
                               "replaces": [old.id]})
    new_tag = out.split("（")[1].split("，")[0]  # "#2"
    item = next(i for i in a.items if i.choice_id == old.id)
    assert item.chosen == f"已改由新決策卡 {new_tag} 處理"
    time.sleep(0.05)
