"""A card the person already answered in words: the assistant closes it
with that answer, so it stops waiting for a press."""

import json

from ghost_agentd import tools
from test_assistant import manager, wait_for  # noqa: F401  (fixtures)
from test_broker import broker, home  # noqa: F401  (fixtures)
from test_dispatch import setup as dispatch_setup


def test_closes_with_the_answer(broker, manager, tmp_path, monkeypatch):
    p, root, d, tm = dispatch_setup(broker, manager, tmp_path, monkeypatch)
    t = tools.Tools(broker, manager, lambda name: None, dispatcher=d)
    a = manager.get("fq")
    a.turn_person = True
    q = broker.create_choice("fq", "要刪掉 3 個 worktree 嗎？", [{"label": "刪"}, {"label": "留著"}])
    a.add("choice", q.summary, choice_id=q.id)
    d.propose(p, "做 A", "platform", "x", branch="feature/a")
    work = next(x for x in broker.pending.values() if getattr(x, "dispatch", None))
    other = broker.create_choice("lts", "別的專案", [{"label": "好"}, {"label": "不要"}])

    out = t.t_close_cards(p, {"cards": f"{q.tag}、{work.tag} {other.id}", "answer": "可以，全部刪掉"})
    assert f"已關卡：{q.tag}、{work.tag}" in out and "沒關掉" in out
    assert not q.open and not work.open and other.open
    assert q.answered == "可以，全部刪掉" and q.decided_by == "answered" and q.chosen is None
    assert not tm.calls and next(iter(d.items.values())).state == "dropped"  # nothing started
    assert next(i for i in a.items if i.choice_id == q.id).chosen == "已依文字回覆結案：可以，全部刪掉"
    assert broker.decide(q.id, "o0", "tg")[0] is False  # a late press does nothing
    recs = [json.loads(line) for line in (p.dir / "decisions.jsonl").read_text().splitlines()]
    rec = next(r for r in recs if r["id"] == q.id)
    assert rec["answered"] == "可以，全部刪掉" and rec["by"] == "answered"


def test_only_a_persons_turn(broker, manager):
    t = tools.Tools(broker, manager, lambda name: None)
    p = broker.projects.get("fq")
    manager.get("fq").turn_person = False  # a schedule, a help request, upkeep
    q = broker.create_choice("fq", "題目", [{"label": "好"}, {"label": "不要"}])
    assert "只有負責人或成員" in t.t_close_cards(p, {"cards": [q.id], "answer": "好"})
    assert q.open


def test_a_member_closes_only_their_own(broker, manager):
    t = tools.Tools(broker, manager, lambda name: None)
    p = broker.projects.get("fq")
    manager.get("fq").turn_person = True
    owners = broker.create_choice("fq", "負責人的", [{"label": "好"}, {"label": "不要"}])
    elsa = {"id": 7, "name": "Elsa"}
    broker.requester_of = lambda name: elsa
    hers = broker.create_choice("fq", "她的", [{"label": "好"}, {"label": "不要"}])
    out = t.t_close_cards(p, {"cards": [hers.id, owners.id], "answer": "好"})
    assert not hers.open and owners.open and "不是這位成員交辦的卡" in out


def test_turn_person_follows_who_spoke(manager, monkeypatch):
    a = manager.get("fq")
    a._write = lambda obj: True
    monkeypatch.setattr(type(a), "running", property(lambda self: True))
    for internal, requester, owner, expect in [(False, None, True, True), (False, {"id": 7}, False, True),
                                               (False, None, False, False), (True, None, True, False)]:
        a._outbox.append(("hi", internal, requester, owner))
        a._inflight = None
        a._pump()
        assert a.turn_person is expect
