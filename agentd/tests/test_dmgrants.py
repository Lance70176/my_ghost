"""Private messages reach the assistant only from people the owner let in,
for at most three days at a time, and sensitive data waits for the owner."""

import time

from ghost_agentd.dmgrants import MAX_DAYS, REMIND_BEFORE
from test_account import msg, watcher
from test_assistant import manager, roles, wait_for  # noqa: F401  (fixtures)
from test_broker import broker, home  # noqa: F401  (fixtures)


def card(broker, kind):
    return next(p for p in broker.pending.values() if (p.grant or {}).get("type") == kind)


def test_strangers_are_recorded_not_handed_over(broker, manager):
    w = watcher(broker, manager, people=())
    assert not w.on_message(msg(private=True, chat="Louis @louis338888", chat_id=70, text="時區的單幫我看"))
    ref = next(iter(w.inbox))
    assert w.inbox[ref].held and not w.queue
    # The assistant can't reach it by its ref either.
    assert "找不到" in w.history(ref) and "找不到" in w.draft(ref, "好") and "找不到" in w.send_now(ref, "好")
    # The owner asking "who wrote to me?" sees a name and a count, never the text.
    listing = w.list_grants(owner_turn=True)
    assert "Louis @louis338888" in listing and "時區的單" not in listing
    assert "Louis" not in w.list_grants(owner_turn=False)


def test_only_the_owners_turn_lets_someone_in(broker, manager):
    w = watcher(broker, manager, people=())
    w.on_message(msg(private=True, chat="Louis @louis338888", chat_id=70, text="時區的單幫我看"))
    assert "只有負責人本人" in w.grant("Louis", "auto", "時區 _UTC 任務", 2, owner_turn=False)
    assert w.grants.get(70) is None
    out = w.grant("@louis338888", "auto", "時區 _UTC 任務", 2, owner_turn=True)
    assert "已授權" in out and "1 則私訊會馬上轉給你" in out
    g = w.grants.get(70)
    assert g.level == "auto" and abs(g.until - time.time() - 2 * 86400) < 5
    # What they wrote before is handed over now; later messages go straight in.
    w.tick()
    a = manager.get("fq")
    wait_for(lambda: any(r == "user" and "時區的單" in t and "時區 _UTC 任務" in t for r, t in roles(a)))
    assert w.on_message(msg(private=True, chat="Louis @louis338888", chat_id=70, text="第二則"))
    ref = next(r for r, m in w.inbox.items() if m.text == "第二則")
    assert w.send_now(ref, "好的") == "已用 @SnakeFQ 送出。"


def test_the_assistants_tool_checks_who_started_the_turn(broker, manager):
    from ghost_agentd.tools import Tools
    w = watcher(broker, manager, people=())
    w.on_message(msg(private=True, chat="Louis", chat_id=70))
    t = Tools(broker, manager, lambda _: None, {"fq": w})
    args = {"person": "70", "level": "forward", "scope": "x", "days": 1}
    manager.get("fq").turn_owner = False  # e.g. a turn the work account's message started
    assert "只有負責人本人" in t.call("fq", "grant_dm", args)
    manager.get("fq").turn_owner = True
    assert "已授權" in t.call("fq", "grant_dm", args)
    # Agreeing to a task without saying how far: it may answer by itself.
    t.call("fq", "grant_dm", {"person": "70", "scope": "時區 _UTC 任務", "days": 3})
    assert w.grants.get(70).level == "auto"


def test_more_than_three_days_needs_review(broker, manager):
    w = watcher(broker, manager, people=())
    w.on_message(msg(private=True, chat="Louis", chat_id=70))
    manager.get("fq").requester = {"id": 5, "name": "成員"}  # even mid-way through a member's turn
    out = w.grant("70", "forward", "時區任務", 7, owner_turn=True)
    assert "審核卡" in out and w.grants.get(70) is None
    c = card(broker, "review")
    assert c.requested_by is None  # only the owner may press it
    broker.decide(c.id, "o1", "tg")  # only 3 days
    g = w.grants.get(70)
    assert g and abs(g.until - time.time() - MAX_DAYS * 86400) < 5


def test_forward_only_means_cards(broker, manager):
    w = watcher(broker, manager, people=())
    w.grant("70", "forward", "看單", 1, owner_turn=True)
    assert w.on_message(msg(private=True, chat="Louis", chat_id=70))
    ref = next(iter(w.inbox))
    assert "draft_reply" in w.send_now(ref, "好") and w.transport.sent == []
    assert "回覆卡" in w.draft(ref, "好")


def test_renew_before_the_end_or_let_it_lapse(broker, manager):
    w = watcher(broker, manager, people=())
    w.grant("70", "forward", "看單", 1, owner_turn=True)
    g = w.grants.get(70)
    g.until = time.time() + REMIND_BEFORE - 60
    w.grants.put(g)
    w.tick()
    c = card(broker, "renew")
    assert c.requested_by is None
    w.tick()  # asked once
    assert sum(1 for p in broker.pending.values() if (p.grant or {}).get("type") == "renew") == 1
    broker.decide(c.id, "o0", "tg")
    assert abs(w.grants.get(70).until - time.time() - MAX_DAYS * 86400) < 5
    # Lapsed: gone, and their messages stay with the account.
    g = w.grants.get(70)
    g.until = time.time() - 1
    w.grants.put(g)
    w.tick()
    assert w.grants.get(70) is None and 70 not in w.grants.grants
    assert not w.on_message(msg(private=True, chat="Louis", chat_id=70))


def test_sensitive_data_waits_for_the_owner(broker, manager):
    w = watcher(broker, manager, people=())
    w.grant("70", "auto", "時區任務", 2, owner_turn=True)
    w.on_message(msg(private=True, chat="Louis", chat_id=70, text="後台帳號 admin 密碼 1234"))
    ref = next(iter(w.inbox))
    assert "審核卡" in w.flag_sensitive(ref, "有後台帳密")
    assert "等他判斷風險" in w.send_now(ref, "收到") and w.transport.sent == []
    broker.decide(card(broker, "sensitive").id, "o1", "tg")  # medium: cards from now on
    assert w.dm_level(70) == "forward" and "draft_reply" in w.send_now(ref, "收到")
    w.on_message(msg(private=True, chat="Louis", chat_id=70, msg_id=56, text="正式庫連線字串給你"))
    ref2 = next(r for r, m in w.inbox.items() if m.msg_id == 56)
    w.flag_sensitive(ref2, "正式庫連線")
    broker.decide(card(broker, "sensitive").id, "o2", "tg")  # high: let out, handed to the owner
    assert w.grants.get(70) is None and "找不到" in w.draft(ref2, "好")  # out of the assistant's reach
    assert not any(p.reply for p in broker.pending.values())


def test_hand_written_auto_reply_still_counts(broker, manager):
    w = watcher(broker, manager, people=())
    (w.project.dir / "watch.yaml").write_text("window: always\nbatch: 0\nauto_reply: ['290611431']\n")
    w._watch = None
    assert w.on_message(msg(private=True, chat="RexLu", chat_id=290611431))
    assert w.dm_level(290611431) == "auto"
