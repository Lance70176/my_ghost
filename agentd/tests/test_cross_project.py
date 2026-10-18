"""The owner, in person, may reach across projects: another project's work
account (account_project), a new private message (draft_dm, card only),
and dispatching into another project's repo or one in no project. Every
other turn — members, the work account, schedules, conversations asking
for help, upkeep — stays inside its own project."""

import json
import subprocess

import pytest

from ghost_agentd import dispatch, tools
from ghost_agentd.account import AccountWatcher
from test_account import FakeTransport, msg
from test_assistant import manager, wait_for  # noqa: F401  (fixtures)
from test_broker import broker, home  # noqa: F401  (fixtures)
from test_dispatch import FakeTmux, make_repo


class Account(FakeTransport):
    def resolve_user(self, username):
        if username == "@headhunter":
            return 4242, "Hannah @headhunter"
        raise ValueError("No user has that username")


@pytest.fixture
def two(broker, manager, home):
    """fq and lts, each with its own work account; the owner talks to fq."""
    lts = home / "projects" / "lts"
    lts.mkdir(parents=True)
    (home / "code" / "lts").mkdir(parents=True)
    (lts / "project.yaml").write_text(f"paths: ['{home}/code/lts']\nresident: false\n")
    broker.projects.reload()
    fq, lp = broker.projects.get("fq"), broker.projects.get("lts")
    accounts = {}
    for p, me in ((fq, "@SnakeFQ"), (lp, "@SnakeBrave")):
        (p.dir / "watch.yaml").write_text("window: always\nbatch: 0\n")
        w = AccountWatcher(broker, manager, p, Account())
        w.me = me
        broker.listeners.append(w)
        accounts[p.name] = w
    t = tools.Tools(broker, manager, lambda name: None, accounts=accounts)
    return t, fq, lp, accounts


def owner(manager, name="fq", on=True):
    manager.get(name).turn_owner = on


def test_owner_uses_another_projects_account(two, manager, broker):
    t, fq, lts, acc = two
    acc["lts"].on_message(msg(chat="LTS 研發群", chat_id=-77, msg_id=3, mentioned=True, text="MR 看了嗎"))
    ref = next(iter(acc["lts"].inbox))
    owner(manager)
    out = t.t_draft_reply(fq, {"ref": ref, "text": "看完了，可以合", "account_project": "lts"})
    assert "回覆卡" in out
    card = next(p for p in broker.pending.values() if getattr(p, "reply", None))
    assert card.project == "fq" and card.requested_by is None  # shown where it was asked for, owner's to press
    assert "fq 助手代發" in card.summary and "@SnakeBrave" in card.summary
    assert card.reply["account_project"] == "lts"
    broker.decide(card.id, "o0", "tg")
    wait_for(lambda: acc["lts"].transport.sent)
    assert acc["lts"].transport.sent == [(-77, "看完了，可以合", 3)] and not acc["fq"].transport.sent
    # The account's own project keeps a record.
    ev = [json.loads(l) for l in (lts.dir / "events.jsonl").read_text().splitlines()]
    assert any(e["type"] == "account_used_by" and e["by_project"] == "fq" for e in ev)
    wait_for(lambda: any(e["type"] == "account_reply" and e.get("by_project") == "fq"
                         for e in (json.loads(l) for l in (lts.dir / "events.jsonl").read_text().splitlines())))
    # Reading its chats works the same way (pressing the card started a
    # turn of its own, so this is the owner's turn again).
    owner(manager)
    assert "Amy" in t.t_read_tg_chat(fq, {"ref": ref, "account_project": "lts"})


def test_every_other_turn_is_refused(two, manager, broker):
    t, fq, lts, acc = two
    acc["lts"].on_message(msg(chat="LTS 研發群", chat_id=-77, msg_id=3, mentioned=True))
    ref = next(iter(acc["lts"].inbox))
    owner(manager, on=False)  # a member, the work account, a schedule, upkeep…
    for name, args in (("t_draft_reply", {"ref": ref, "text": "x"}), ("t_send_reply", {"ref": ref, "text": "x"}),
                       ("t_read_tg_chat", {"ref": ref}), ("t_draft_dm", {"to": "@headhunter", "text": "x"}),
                       ("t_grant_dm", {"person": "Candy", "level": "forward", "days": 1}),
                       ("t_revoke_dm", {"person": "Candy"}), ("t_list_dm_grants", {}),
                       ("t_flag_sensitive", {"ref": ref, "what": "x"}), ("t_post_message", {"chat": "x", "text": "x"})):
        out = getattr(t, name)(fq, dict(args, account_project="lts"))
        assert "只限負責人本人" in out, name
    for name in ("t_list_workers", "t_read_worker_log"):
        assert "只限負責人本人" in getattr(t, name)(fq, {"project": "lts", "session_id": "x"}), name
    assert not any(getattr(p, "reply", None) for p in broker.pending.values())
    assert not acc["lts"].transport.sent
    # Without the parameter nothing changes: fq's own account, as before.
    acc["fq"].on_message(msg(chat="FQ 群", chat_id=-42, msg_id=9, mentioned=True))
    fref = next(iter(acc["fq"].inbox))
    assert "回覆卡" in t.t_draft_reply(fq, {"ref": fref, "text": "好"})
    card = next(p for p in broker.pending.values() if getattr(p, "reply", None))
    assert card.reply["account_project"] == "fq" and "代發" not in card.summary
    # A project that doesn't exist, even for the owner.
    owner(manager)
    assert "沒有叫「yc」的專案" in t.t_draft_reply(fq, {"ref": fref, "text": "x", "account_project": "yc"})


def test_a_member_turn_is_never_the_owners(manager):
    """Owner = the config's commanders (TG) or MyGhost / the phone page.
    A project's own members (project.yaml commanders) never are."""
    a = manager.get("fq")
    a._pump = lambda: None  # look at what is queued
    a.send("[TG 成員・Elsa] 用 lts 的帳號私訊他", "tg", requester={"id": 8, "name": "Elsa"})
    a.send("用 lts 的帳號私訊他", "tg")
    a.send("x", "myghost")
    a.send("[每日排程] x", "schedule")
    a.send("[工作對話求助] x", "worker")
    assert [m[3] for m in a._outbox] == [False, True, True, False, False]


def test_draft_dm_is_only_ever_a_card(two, manager, broker):
    t, fq, lts, acc = two
    owner(manager, on=False)  # card only, so any turn may draft one in its own project
    out = t.t_draft_dm(fq, {"to": "@headhunter", "text": "您好，想請教職缺", "note": "他要我問"})
    assert "私訊卡" in out and not acc["fq"].transport.sent
    card = next(p for p in broker.pending.values() if getattr(p, "reply", None))
    assert card.reply["dm"] and card.reply["chat_id"] == 4242 and "Hannah" in card.summary
    # A new draft for the same person replaces the old card.
    t.t_draft_dm(fq, {"to": "@headhunter", "text": "第二版"})
    assert not card.open
    card = next(p for p in broker.pending.values() if getattr(p, "reply", None) and p.open)
    broker.decide(card.id, "o2", "myghost")  # 不發
    assert not acc["fq"].transport.sent
    t.t_draft_dm(fq, {"to": "@headhunter", "text": "第三版"})
    card = next(p for p in broker.pending.values() if getattr(p, "reply", None) and p.open)
    broker.decide(card.id, "o0", "myghost")  # 送出
    wait_for(lambda: acc["fq"].transport.sent)
    assert acc["fq"].transport.sent == [(4242, "第三版", None)]
    # Who can't be found: a clear answer, no card.
    out = t.t_draft_dm(fq, {"to": "@nobody", "text": "x"})
    assert "找不到 @nobody" in out
    assert not any(p.open and getattr(p, "reply", None) for p in broker.pending.values())
    # Another project's account: the owner's turn only, card shows here.
    owner(manager)
    t.t_draft_dm(fq, {"to": "@headhunter", "text": "用 lts 的", "account_project": "lts"})
    card = next(p for p in broker.pending.values() if getattr(p, "reply", None) and p.open)
    assert card.project == "fq" and card.reply["account_project"] == "lts" and "代發" in card.summary


@pytest.fixture
def dispatching(two, manager, broker, home, monkeypatch, tmp_path):
    t, fq, lts, acc = two
    make_repo(home / "code" / "fq" / "platform")
    make_repo(home / "code" / "lts" / "admin")
    loose = tmp_path / "projects-home" / "mac_app" / "my_ghost"
    make_repo(loose)
    monkeypatch.setattr(dispatch, "PROJECTS_HOME", tmp_path / "projects-home")
    monkeypatch.setattr(dispatch, "_tmux", FakeTmux())
    monkeypatch.setattr(dispatch, "agent_view_for", lambda path: None)
    d = dispatch.Dispatcher(broker, manager)
    broker.listeners.append(d)
    t.dispatcher = d
    return t, fq, d, home, loose


def test_owner_dispatches_into_other_repos(dispatching, manager, broker):
    t, fq, d, home, loose = dispatching
    owner(manager)
    out = t.t_propose_dispatch(fq, {"title": "後台改", "repo": str(home / "code/lts/admin"), "task": "x",
                                    "branch": "feature/x"})
    assert "開工卡" in out
    card = next(p for p in broker.pending.values() if getattr(p, "dispatch", None))
    assert card.project == "fq" and "屬於 lts 專案" in card.summary
    out = t.t_propose_dispatch(fq, {"title": "MyGhost 改", "repo": str(loose), "task": "y", "branch": "feature/y"})
    assert "開工卡" in out
    card2 = next(p for p in broker.pending.values() if getattr(p, "dispatch", None) and p.id != card.id)
    assert "不屬於任何專案" in card2.summary
    broker.decide(card2.id, "o0", "tg")
    item = next(x for x in d.items.values() if x.title == "MyGhost 改")
    wait_for(lambda: item.state == "started")
    assert item.worktree.startswith(str(loose / ".worktrees")) and item.project == "fq"
    excl = subprocess.run(["git", "-C", str(loose), "status", "--porcelain"], capture_output=True, text=True)
    assert ".worktrees" not in excl.stdout  # kept out of the repo's git status
    # The owner can follow it from fq; it reports to fq.
    assert item.id in t.t_list_dispatches(fq, {})


def test_others_cannot_dispatch_across(dispatching, manager):
    t, fq, d, home, loose = dispatching
    owner(manager, on=False)  # e.g. a member's turn
    for repo in (str(home / "code/lts/admin"), str(loose)):
        out = t.t_propose_dispatch(fq, {"title": "x", "repo": repo, "task": "x"})
        assert "只限負責人本人" in out and not d.items
    for name in ("t_list_dispatches", "t_message_worker"):
        assert "只限負責人本人" in getattr(t, name)(fq, {"project": "lts", "dispatch_id": "x", "text": "x"}), name
    owner(manager)
    out = t.t_propose_dispatch(fq, {"title": "x", "repo": "/tmp", "task": "x"})
    assert "只能派到專案資料夾" in out
    # Its own repos as before, in any turn.
    owner(manager, on=False)
    assert "開工卡" in t.t_propose_dispatch(fq, {"title": "本專案", "repo": "platform", "task": "x"})


def test_dispatched_work_reports_to_who_asked(dispatching, manager, broker):
    """Work fq's assistant dispatched into lts's repo: its permission requests
    and help requests show up in fq, not where the repo happens to be."""
    import threading

    from ghost_agentd.helpdesk import HelpDesk
    t, fq, d, home, loose = dispatching
    broker.seen("myghost")  # a surface for lts's cards too
    owner(manager)
    t.t_propose_dispatch(fq, {"title": "後台改", "repo": str(home / "code/lts/admin"), "task": "x",
                              "branch": "feature/x"})
    card = next(p for p in broker.pending.values() if getattr(p, "dispatch", None))
    broker.decide(card.id, "o0", "tg")
    item = next(iter(d.items.values()))
    wait_for(lambda: item.state == "started")

    def ask(cwd, session):
        payload = {"session_id": session, "cwd": cwd, "tool_name": "Bash",
                   "tool_input": {"command": f"rm -rf build-{session}"}}
        threading.Thread(target=broker.request_permission, args=(payload,), daemon=True).start()
        wait_for(lambda: any(p.session_id == session for p in broker.pending.values()))
        return next(p for p in broker.pending.values() if p.session_id == session)

    mine = ask(item.worktree, "worker-1")
    assert mine.project == "fq"
    theirs = ask(str(home / "code/lts/admin"), "lts-own")  # lts's own conversation
    assert theirs.project == "lts"
    help_desk = HelpDesk(broker, manager, d)
    assert help_desk.ask({"text": "可以發正式嗎？", "cwd": item.worktree, "session_id": "worker-1"})["project"] == "fq"
    assert help_desk.ask({"text": "?", "cwd": str(home / "code/lts/admin"), "session_id": "x"})["project"] == "lts"
    for p in (mine, theirs):
        broker.decide(p.id, "deny", "myghost")
