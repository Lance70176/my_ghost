"""A card the person already answered in words: the assistant repeats back
which card and what answer, and closes it only after they say OK."""

import json

from ghost_agentd import tools
from test_assistant import manager, wait_for  # noqa: F401  (fixtures)
from test_broker import broker, home  # noqa: F401  (fixtures)
from test_dispatch import setup as dispatch_setup


def person_turn(a, owner=True):
    """What _pump does when a person's message starts a turn."""
    a.turn_person, a.turn_owner = True, owner
    a.turn_seq += 1


def test_repeats_back_then_closes_on_ok(broker, manager, tmp_path, monkeypatch):
    p, root, d, tm = dispatch_setup(broker, manager, tmp_path, monkeypatch)
    t = tools.Tools(broker, manager, lambda name: None, dispatcher=d)
    a = manager.get("fq")
    q = broker.create_choice("fq", "整理一下：有 3 組 worktree 還在硬碟上，要刪掉嗎？\n細節…",
                             [{"label": "刪"}, {"label": "留著"}])
    a.add("choice", q.summary, choice_id=q.id)
    d.propose(p, "做 A", "platform", "x", branch="feature/a")
    work = next(x for x in broker.pending.values() if getattr(x, "dispatch", None))
    other = broker.create_choice("lts", "別的專案", [{"label": "好"}, {"label": "不要"}])

    person_turn(a)  # 「可以，全部刪掉」
    out = t.t_close_cards(p, {"cards": f"{q.tag}、{work.tag} {other.id}", "answer": "可以，全部刪掉"})
    assert "還沒關卡" in out and "請確認要結案" in out
    assert f"{q.tag}（{q.serial_day}）「整理一下：有 3 組 worktree 還在硬碟上，要刪掉嗎？」" in out
    assert "你的答案：可以，全部刪掉" in out and "回「OK」" in out and "不能關" in out
    assert q.open and work.open  # nothing closed yet
    # Not in the same turn: he hasn't seen the question.
    assert "還不能關" in t.t_close_cards(p, {"confirmed": True}) and q.open

    person_turn(a)  # 「OK」
    out = t.t_close_cards(p, {"confirmed": True})
    assert f"已關卡：{q.tag}、{work.tag}" in out
    assert not q.open and not work.open and other.open
    assert q.answered == "可以，全部刪掉" and q.decided_by == "answered" and q.chosen is None
    assert not tm.calls and next(iter(d.items.values())).state == "dropped"  # nothing started
    assert next(i for i in a.items if i.choice_id == q.id).chosen == "已依文字回覆結案：可以，全部刪掉"
    assert broker.decide(q.id, "o0", "tg")[0] is False  # a late press does nothing
    recs = [json.loads(line) for line in (p.dir / "decisions.jsonl").read_text().splitlines()]
    rec = next(r for r in recs if r["id"] == q.id)
    assert rec["answered"] == "可以，全部刪掉" and rec["by"] == "answered"
    # The confirmation is used up.
    assert "沒有等他確認" in t.t_close_cards(p, {"confirmed": True})


def test_only_a_persons_turn(broker, manager):
    t = tools.Tools(broker, manager, lambda name: None)
    p = broker.projects.get("fq")
    a = manager.get("fq")
    q = broker.create_choice("fq", "題目", [{"label": "好"}, {"label": "不要"}])
    person_turn(a)
    t.t_close_cards(p, {"cards": [q.id], "answer": "好"})
    a.turn_person = False  # a schedule, a help request, upkeep
    a.turn_seq += 1
    assert "只有負責人或成員" in t.t_close_cards(p, {"confirmed": True})
    assert q.open


def test_a_member_confirms_only_their_own(broker, manager):
    t = tools.Tools(broker, manager, lambda name: None)
    p = broker.projects.get("fq")
    a = manager.get("fq")
    owners = broker.create_choice("fq", "負責人的", [{"label": "好"}, {"label": "不要"}])
    elsa, other = {"id": 7, "name": "Elsa"}, {"id": 8, "name": "Bob"}
    broker.requester_of = lambda name: elsa
    hers = broker.create_choice("fq", "她的", [{"label": "好"}, {"label": "不要"}])
    person_turn(a, owner=False)
    out = t.t_close_cards(p, {"cards": [hers.id, owners.id], "answer": "好"})
    assert "不是這位成員交辦的卡" in out and "她的" in out
    broker.requester_of = lambda name: other  # someone else says OK
    person_turn(a, owner=False)
    assert "只有當初回答的人" in t.t_close_cards(p, {"confirmed": True}) and hers.open
    broker.requester_of = lambda name: elsa
    person_turn(a, owner=False)
    assert "已關卡" in t.t_close_cards(p, {"confirmed": True})
    assert not hers.open and owners.open


def test_a_stale_question_expires(broker, manager, monkeypatch):
    t = tools.Tools(broker, manager, lambda name: None)
    p = broker.projects.get("fq")
    a = manager.get("fq")
    q = broker.create_choice("fq", "題目", [{"label": "好"}, {"label": "不要"}])
    person_turn(a)
    t.t_close_cards(p, {"cards": [q.id], "answer": "好"})
    t.close_offers["fq"]["at"] -= t.CLOSE_OFFER_TTL + 1
    person_turn(a)
    assert "超過 2 小時" in t.t_close_cards(p, {"confirmed": True}) and q.open


def test_turn_person_follows_who_spoke(manager, monkeypatch):
    a = manager.get("fq")
    a._write = lambda obj: True
    monkeypatch.setattr(type(a), "running", property(lambda self: True))
    seq = a.turn_seq
    for internal, requester, owner, expect in [(False, None, True, True), (False, {"id": 7}, False, True),
                                               (False, None, False, False), (True, None, True, False)]:
        a._outbox.append(("hi", internal, requester, owner))
        a._inflight = None
        a._pump()
        assert a.turn_person is expect
    assert a.turn_seq == seq + 2  # only the two people's turns count
