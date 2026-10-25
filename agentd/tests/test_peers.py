"""One assistant asks another (ask_assistant): only in the owner's own turn;
the other answers inside its own project, and what it says comes back."""

import pytest

from ghost_agentd import tools
from test_assistant import manager, roles, wait_for  # noqa: F401  (fixtures)
from test_broker import broker, home  # noqa: F401  (fixtures)


@pytest.fixture
def two(broker, manager, home):
    lts = home / "projects" / "lts"
    lts.mkdir(parents=True)
    (home / "code" / "lts").mkdir(parents=True)
    (lts / "project.yaml").write_text(f"paths: ['{home}/code/lts']\nresident: false\n")
    broker.projects.reload()
    t = tools.Tools(broker, manager, lambda name: None)
    return t, broker.projects.get("fq"), broker.projects.get("lts")


def sent(a):
    """What the assistant was handed, as its fake replies echo it."""
    return [t for r, t in roles(a) if r == "assistant"]


def test_owner_asks_another_assistant_and_gets_the_answer(two, manager):
    t, fq, lts = two
    manager.get("fq").turn_owner = True
    out = t.t_ask_assistant(fq, {"project": "lts", "question": "資料刪除頁要不要寫不會訓練 AI？"})
    assert "已把問題交給 lts 助手" in out
    ask_id = next(iter(manager.peers.items))
    b = manager.get("lts")
    # lts gets it as data, in a turn that is not the owner's
    wait_for(lambda: any("不會訓練 AI" in x and ask_id in x and x.startswith("回覆：[其他專案助手]")
                         for x in sent(b)))
    assert not b.turn_owner
    assert any(r == "notice" and "fq 助手替" in x for r, x in roles(b))
    # whatever lts said in that turn goes back to fq, as data, not as the owner
    a = manager.get("fq")
    wait_for(lambda: any(x.startswith("回覆：[其他專案助手]") and "lts」專案助手回覆了你的提問" in x
                         for x in sent(a)))
    wait_for(lambda: manager.peers.items[ask_id].answers)
    assert "不會訓練 AI" in manager.peers.items[ask_id].answers[0][1]
    wait_for(lambda: not a.busy)
    assert not a.turn_owner


def test_only_the_owners_turn_may_ask(two, manager):
    t, fq, lts = two
    manager.get("fq").turn_owner = False
    out = t.t_ask_assistant(fq, {"project": "lts", "question": "x"})
    assert "只限負責人本人" in out and not manager.peers.items


def test_bad_targets(two, manager):
    t, fq, lts = two
    manager.get("fq").turn_owner = True
    assert "沒有叫「nope」" in t.t_ask_assistant(fq, {"project": "nope", "question": "x"})
    assert "你自己的專案" in t.t_ask_assistant(fq, {"project": "fq", "question": "x"})
    assert "空的" in t.t_ask_assistant(fq, {"project": "lts", "question": " "})
    assert not manager.peers.items


def test_later_answer_only_from_the_asked_project(two, manager):
    t, fq, lts = two
    manager.get("fq").turn_owner = True
    t.t_ask_assistant(fq, {"project": "lts", "question": "要等王爾莎決定"})
    ask_id = next(iter(manager.peers.items))
    assert "沒有 id" in t.t_reply_assistant(fq, {"ask_id": ask_id, "text": "我自己答"})
    assert "沒有 id" in t.t_reply_assistant(lts, {"ask_id": "ffffff", "text": "x"})
    assert "已轉給 fq" in t.t_reply_assistant(lts, {"ask_id": ask_id, "text": "王爾莎選了拿掉"})
    a = manager.get("fq")
    wait_for(lambda: any("補充回覆" in x and "王爾莎選了拿掉" in x for x in sent(a)))
    # kept across a restart of the daemon
    from ghost_agentd.peers import PeerDesk
    assert ask_id in PeerDesk(manager).items


def test_work_done_tells_the_assistant_the_owner_registered(two, manager, broker):
    from ghost_agentd.dispatch import Dispatch, Dispatcher
    t, fq, lts = two
    t.dispatcher = Dispatcher(broker, manager)
    d = Dispatch(id="d1", project="fq", title="資料刪除頁", repo="/x/site", branch="b", base="main",
                 task="做頁面", state="started", session_id="s1")
    t.dispatcher.items[d.id] = d
    a = manager.get("fq")
    a.turn_owner = False
    assert "只限負責人本人" in t.t_notify_on_done(fq, {"dispatch_id": "d1", "project": "lts"})
    a.turn_owner = True
    assert "沒有叫「nope」" in t.t_notify_on_done(fq, {"dispatch_id": "d1", "project": "nope"})
    assert "沒有 id=zz" in t.t_notify_on_done(fq, {"dispatch_id": "zz", "project": "lts"})
    assert "已登記" in t.t_notify_on_done(fq, {"dispatch_id": "d1", "project": "lts"})
    assert d.notify == ["lts"] and "完成後通知 lts" in t.dispatcher.list_for(fq)
    # its stop reaches the assistant tied to the dispatch, saying whom to tell
    calls = []
    a.send = lambda text, source, **kw: calls.append((text, kw))
    t.dispatcher.on_stop("", "s1", "做好了，已上線")
    wait_for(lambda: calls)
    assert calls[0][1]["dispatch"] == "d1" and "通知 lts 助手" in calls[0][0]
    del a.send
    # in that turn only the registered project may be told; other turns can't
    a.turn_owner, a.turn_dispatch = False, "d1"
    assert "只限負責人本人" in t.t_ask_assistant(fq, {"project": "nope", "question": "x"})
    out = t.t_ask_assistant(fq, {"project": "lts", "question": "資料刪除頁上線了"})
    assert "已把問題交給 lts 助手" in out
    b = manager.get("lts")
    wait_for(lambda: any("來通知你" in x and "資料刪除頁" in x for x in sent(b)))
    a.turn_dispatch = None
    assert "只限負責人本人" in t.t_ask_assistant(fq, {"project": "lts", "question": "x"})


def test_both_groups_read_the_question_and_answer_in_full(two, manager):
    t, fq, lts = two
    notices = []
    manager.notify = lambda project, text: notices.append((project.name, text))
    manager.get("fq").turn_owner = True
    t.t_ask_assistant(fq, {"project": "lts", "question": "背景" * 400 + "結尾的問題"})
    ask_id = next(iter(manager.peers.items))
    assert any(p == "lts" and x.endswith("結尾的問題") for p, x in notices)
    assert any(r == "notice" and x.endswith("結尾的問題") for r, x in roles(manager.get("lts")))
    t.t_reply_assistant(lts, {"ask_id": ask_id, "text": "答覆" * 400 + "最後一句"})
    assert any(p == "fq" and x.endswith("最後一句") for p, x in notices)
