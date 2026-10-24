"""A card the assistant opens for a member outside that member's own turn
(the owner's turn, a work conversation's help request) is the owner's to
press — until the owner lets the member decide that kind of card."""

import pytest

from ghost_agentd import tools
from test_assistant import manager  # noqa: F401  (fixture)
from test_broker import broker, home  # noqa: F401  (fixtures)
from test_close_cards import person_turn

ELSA = {"id": 7, "name": "王 爾莎"}
OPTS = [{"label": "A"}, {"label": "B"}]


@pytest.fixture
def t(broker, manager, monkeypatch):
    monkeypatch.setattr(tools.cfgmod, "member_names", lambda p: {7: "王 爾莎"})
    return tools.Tools(broker, manager, lambda name: None)


def tag_of(out):
    return out.split("（", 1)[1].split("，", 1)[0]


def test_ungranted_card_stays_the_owners_and_says_ask(broker, manager, t):
    p = broker.projects.get("fq")
    out = t.t_ask_decision(p, {"question": "封面那行字？", "options": OPTS,
                               "for_member": "王爾莎", "kind": "發文文案修改"})
    c = broker.find("fq", tag_of(out))
    assert c.requested_by is None
    assert "按不到這張卡" in out and "member_grant" in out and f'cards=["{c.tag}"]' in out


def test_only_the_owners_turn_grants(broker, manager, t):
    p = broker.projects.get("fq")
    a = manager.get("fq")
    person_turn(a, owner=False)  # the member asks for it herself
    out = t.t_member_grant(p, {"action": "add", "member": "王 爾莎", "kind": "發文文案修改"})
    assert "只有負責人本人" in out
    assert "沒有成員授權" in t.t_member_grant(p, {"action": "list"})


def test_grant_hands_over_now_and_later(broker, manager, t):
    p = broker.projects.get("fq")
    a = manager.get("fq")
    first = broker.create_choice("fq", "封面那行字？", OPTS)
    linked = broker.create_choice("fq", "討論權限卡", [{"label": "同意", "action": "allow"}, {"label": "不"}],
                                  card_id=first.id)
    person_turn(a)  # the owner: 「可以，以後文案她決定」
    out = t.t_member_grant(p, {"action": "add", "member": "王爾莎", "kind": "發文文案修改",
                               "cards": [first.tag, linked.tag]})
    assert "已記住" in out and f"已交給 王 爾莎：{first.tag}" in out and "只有負責人能決定" in out
    assert first.requested_by == ELSA and linked.requested_by is None
    assert ("update", first.id, "pending") in broker.events  # the TG card is redrawn

    # A help request's turn (not the owner's words): same kind goes to her.
    a.turn_person = a.turn_owner = False
    out = t.t_ask_decision(p, {"question": "第二句？", "options": OPTS,
                               "for_member": "7", "kind": "發文 文案修改"})
    assert broker.find("fq", tag_of(out)).requested_by == ELSA and "交給 王 爾莎" in out
    # Another kind still needs the owner.
    out = t.t_ask_decision(p, {"question": "要不要花錢投廣告？", "options": OPTS,
                               "for_member": "王 爾莎", "kind": "廣告預算"})
    assert broker.find("fq", tag_of(out)).requested_by is None and "目前授權的類型：發文文案修改" in out

    # Her own turn can now close the card handed to her.
    broker.requester_of = lambda name: ELSA
    person_turn(a, owner=False)
    assert "還沒關卡" in t.t_close_cards(p, {"cards": [first.tag], "answer": "A"})

    person_turn(a)
    broker.requester_of = lambda name: None
    assert "已收回" in t.t_member_grant(p, {"action": "remove", "member": "王 爾莎"})
    assert "沒有成員授權" in t.t_member_grant(p, {"action": "list"})


def test_refused_close_tells_the_assistant_to_say_so(broker, manager, t):
    p = broker.projects.get("fq")
    a = manager.get("fq")
    owners = broker.create_choice("fq", "負責人的", OPTS)
    broker.requester_of = lambda name: ELSA
    person_turn(a, owner=False)
    out = t.t_close_cards(p, {"cards": [owners.tag], "answer": "A"})
    assert "不是這位成員交辦的卡" in out and "在群組講清楚" in out
    out = t.t_ask_decision(p, {"question": "新版", "options": OPTS, "replaces": [owners.tag]})
    assert "沒撤掉" in out and "在群組講清楚" in out and owners.open
