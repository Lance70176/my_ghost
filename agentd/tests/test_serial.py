"""Every card gets the day's running number in its project (#1, #2…)."""

import time

from ghost_agentd import tools
from ghost_agentd.broker import Broker
from ghost_agentd.config import Config, Projects
from test_assistant import manager  # noqa: F401  (fixtures)
from test_broker import broker, home  # noqa: F401  (fixtures)


def choice(b, project="fq", q="要嗎？"):
    return b.create_choice(project, q, [{"label": "好"}, {"label": "不要"}])


def test_numbers_run_per_project_per_day(broker, home, monkeypatch):
    a, b = choice(broker), choice(broker)
    assert (a.serial, b.serial) == (1, 2) and a.tag == "#1" and a.serial_day == time.strftime("%m/%d")
    other = choice(broker, "_default")
    assert other.serial == 1  # each project counts its own
    # A restart goes on counting rather than starting again.
    again = Broker(Config(decision_timeout=5, digest_seconds=0, hold_every_conversation=True), Projects())
    assert choice(again).serial == 3
    # A new day starts from 1.
    real = time.strftime
    monkeypatch.setattr(time, "strftime", lambda fmt, *a: {"%Y-%m-%d": "2099-01-02", "%m/%d": "01/02"}.get(fmt) or real(fmt, *a))
    assert choice(broker).serial == 1


def test_cards_are_found_and_replaced_by_number(broker, manager):
    t = tools.Tools(broker, manager, lambda name: None)
    p = broker.projects.get("fq")
    old = choice(broker)
    assert broker.find("fq", "#1") is old and broker.find("fq", "1") is old and broker.find("fq", old.id) is old
    assert broker.find("_default", "#1") is None
    out = t.t_ask_decision(p, {"question": "新的", "options": [{"label": "好"}, {"label": "不要"}],
                               "replaces": ["#1"]})
    assert "#2" in out and "已撤掉舊卡：#1" in out and "改由 #2" in out
    assert not old.open and old.superseded_by == "#2"


def test_telegram_card_shows_its_number(broker):
    from ghost_agentd.telegram import framed
    p = choice(broker)
    assert f"<code>#1</code>（{p.serial_day}）" in framed(p, ["x"])
