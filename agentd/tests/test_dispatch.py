"""Dispatch (P3): the assistant proposes, only 開工 starts anything, the work
gets its own worktree and branch, and runs with permission prompts on."""

import subprocess
import time

from ghost_agentd import dispatch
from test_assistant import manager, roles, wait_for  # noqa: F401  (fixtures)
from test_broker import broker, home  # noqa: F401  (fixtures)


def make_repo(path):
    path.mkdir(parents=True)
    run = lambda *a: subprocess.run(["git", "-C", str(path), *a], check=True, capture_output=True)
    run("init", "-q", "-b", "develop")
    run("config", "user.email", "t@t")
    run("config", "user.name", "t")
    (path / "a.txt").write_text("a")
    run("add", ".")
    run("commit", "-qm", "init")


class FakeTmux:
    def __init__(self):
        self.calls = []
        self.sessions = set()

    def __call__(self, *args):
        self.calls.append(args)
        out = ""
        if "new-session" in args:
            self.sessions.add(args[args.index("-s") + 1])
        if args and args[0] == "list-sessions":
            out = "\n".join(self.sessions)
        rc = 0 if args[0] != "has-session" or args[-1] in self.sessions else 1
        return subprocess.CompletedProcess(args, rc, out, "")


def setup(broker, manager, tmp_path, monkeypatch):
    p = broker.projects.get("fq")
    root = tmp_path / "code"
    make_repo(root / "platform")
    p.paths[:] = [str(root)]
    tm = FakeTmux()
    monkeypatch.setattr(dispatch, "_tmux", tm)
    monkeypatch.setattr(dispatch, "agent_view_for", lambda path: None)  # no agent view: tabs
    d = dispatch.Dispatcher(broker, manager)
    broker.listeners.append(d)
    return p, root, d, tm


def test_propose_validates_and_only_start_starts(broker, manager, tmp_path, monkeypatch):
    p, root, d, tm = setup(broker, manager, tmp_path, monkeypatch)
    assert "專案資料夾內" in d.propose(p, "x", "/etc", "do it")
    assert "不是 git repo" in d.propose(p, "x", str(root), "do it")
    assert "不合法" in d.propose(p, "x", "platform", "do it", branch="a..b")
    assert "找不到起點" in d.propose(p, "x", "platform", "do it", base="nope")
    assert "開工卡" in d.propose(p, "LSC #198 優惠設置", "platform", "把 A 改成 B，做完先別 push",
                                 branch="feature/lsc-198")
    card = next(x for x in broker.pending.values() if getattr(x, "dispatch", None))
    assert "把 A 改成 B" in card.summary and "feature/lsc-198" in card.summary
    assert not tm.calls  # proposing starts nothing

    broker.decide(card.id, "o0", "tg")  # 開工
    item = next(iter(d.items.values()))
    wait_for(lambda: item.state == "started")
    wt = root / ".worktrees" / "platform-lsc-198"
    assert wt.exists() and item.worktree == str(wt)
    branch = subprocess.run(["git", "-C", str(wt), "branch", "--show-current"], capture_output=True, text=True)
    assert branch.stdout.strip() == "feature/lsc-198"
    new = next(c for c in tm.calls if "new-session" in c)
    cmd = new[-1]
    assert "--permission-mode bypassPermissions" in cmd  # like his agent views
    assert new[new.index("-c") + 1] == str(wt)
    # Trusted first (claude refuses a folder never trusted), and told about production.
    import json
    trusted = json.loads(dispatch.CLAUDE_CONFIG.read_text())["projects"]
    assert trusted[str(wt.resolve())]["hasTrustDialogAccepted"] is True
    sent = (broker.projects.get("fq").dir / "dispatch" / f"{item.id}.md").read_text()
    assert sent.startswith("把 A 改成 B") and "ghost-ask" in sent and "正式環境" in sent
    assert item.tmux.startswith("myghost_")
    assert ("set-option", "-t", item.tmux, "@myghost_title", "LSC #198 優惠設置") in tm.calls
    assert [x["id"] for x in d.live()] == [item.id]


def test_drop_and_follow_ups(broker, manager, tmp_path, monkeypatch):
    p, root, d, tm = setup(broker, manager, tmp_path, monkeypatch)
    d.propose(p, "不做的", "platform", "x")
    card = next(x for x in broker.pending.values() if getattr(x, "dispatch", None))
    broker.decide(card.id, "o2", "myghost")
    time.sleep(0.2)
    assert next(iter(d.items.values())).state == "dropped" and not tm.calls

    d.propose(p, "做的", "platform", "y", branch="feature/y")
    card = next(x for x in broker.pending.values() if getattr(x, "dispatch", None))
    broker.decide(card.id, "o0", "myghost")
    item = next(x for x in d.items.values() if x.title == "做的")
    wait_for(lambda: item.state == "started")
    # Follow-ups only into its own dispatched conversations.
    assert "只能傳給你派出" in d.message(p, "nope", "hi")
    assert d.message(p, item.id, "用方案 B") == "已送出。"
    assert any(c[:2] == ("paste-buffer", "-p") and item.tmux in c for c in tm.calls)
    # Its stops are reported to the assistant.
    d.on_stop(item.tmux, "", "做完了，還沒 push")
    a = manager.get("fq")
    wait_for(lambda: any(r == "user" and "做完了，還沒 push" in t for r, t in roles(a)))


def test_into_an_open_agent_view_as_a_background_job(broker, manager, tmp_path, monkeypatch):
    """With `claude agents` open on the project, the work becomes a background
    job there, with the permission mode its jobs use."""
    p, root, d, tm = setup(broker, manager, tmp_path, monkeypatch)
    monkeypatch.setattr(dispatch, "agent_view_for", lambda path: str(root))
    jobs = tmp_path / "jobs"
    from ghost_agentd import tools
    monkeypatch.setattr(tools, "JOBS", jobs)
    ran = []

    def fake_run(cmd, **kw):
        if cmd[0] != dispatch.CLAUDE:
            return real_run(cmd, **kw)
        ran.append((cmd, kw["cwd"]))
        (jobs / "abcd1234").mkdir(parents=True)
        (jobs / "abcd1234" / "state.json").write_text('{"sessionId": "sess-1"}')
        return subprocess.CompletedProcess(cmd, 0, "backgrounded · abcd1234 · 背景示範\n", "")

    real_run = subprocess.run
    monkeypatch.setattr(dispatch.subprocess, "run", fake_run)
    d.propose(p, "背景示範", "platform", "做 X", branch="feature/bg")
    card = next(x for x in broker.pending.values() if getattr(x, "dispatch", None))
    assert "claude agents" in card.summary and "略過權限確認" in card.summary
    broker.decide(card.id, "o0", "tg")
    item = next(iter(d.items.values()))
    wait_for(lambda: item.state == "started")
    cmd, cwd = ran[0]
    assert cmd[1:5] == ["--bg", "-n", "背景示範", "--permission-mode"] and cmd[5] == "bypassPermissions"
    assert cwd == item.worktree and item.job_id == "abcd1234" and item.session_id == "sess-1"
    assert not any("new-session" in c for c in tm.calls) and d.live() == []  # no tab
    d.on_stop("", "sess-1", "做好了")
    wait_for(lambda: any(r == "user" and "做好了" in t for r, t in roles(manager.get("fq"))))


def test_a_turn_ended_by_an_api_error_is_reported(broker, manager, tmp_path, monkeypatch):
    """No Stop comes when an API error ends the turn; StopFailure stands in."""
    p, root, d, tm = setup(broker, manager, tmp_path, monkeypatch)
    d.propose(p, "翻譯", "platform", "x", branch="feature/tr")
    card = next(x for x in broker.pending.values() if getattr(x, "dispatch", None))
    broker.decide(card.id, "o0", "tg")
    item = next(iter(d.items.values()))
    wait_for(lambda: item.state == "started")
    sent = []
    monkeypatch.setattr(manager.get("fq"), "send", lambda text, source, **kw: sent.append(text))
    broker.hook_event({"hook_event_name": "StopFailure", "session_id": "s-tr", "cwd": item.worktree,
                       "tmux_session": item.tmux, "error": "invalid_request",
                       "error_details": "safeguards flagged this session [cyber]",
                       "last_assistant_message": "測試站發佈成功，正在登入後台抽查"})
    wait_for(lambda: sent)
    assert "API 錯誤中斷" in sent[0] and "[cyber]" in sent[0] and "測試站發佈成功" in sent[0]
    assert "跳過被擋的那一步" in sent[0] and item.stops == 1
    s = broker.sessions["s-tr"]
    assert s.status == "waiting" and "API 錯誤" in s.last_message


def test_a_members_work_stays_theirs(broker, manager, tmp_path, monkeypatch):
    """Work a member asked for: the turns its conversation causes (stopping,
    asking for help) work for that member, so they may press those cards."""
    from ghost_agentd.helpdesk import HelpDesk
    p, root, d, tm = setup(broker, manager, tmp_path, monkeypatch)
    elsa = {"id": 8653633889, "name": "王 爾莎"}
    d.propose(p, "成員的", "platform", "x", branch="feature/m")
    card = next(x for x in broker.pending.values() if getattr(x, "dispatch", None))
    card.requested_by = elsa  # proposed while working for her
    broker.decide(card.id, "o0", "tg")
    item = next(iter(d.items.values()))
    wait_for(lambda: item.state == "started")
    assert item.requested_by == elsa

    sent = []
    a = manager.get("fq")
    monkeypatch.setattr(a, "send", lambda text, source, **kw: sent.append((source, kw.get("requester"), text)))
    d.on_stop(item.tmux, "", "做完了")
    wait_for(lambda: len(sent) == 1)
    assert sent[0][1] == elsa and "王 爾莎" in sent[0][2]

    import yaml
    f = p.dir / "project.yaml"
    conf = yaml.safe_load(f.read_text()) or {}
    conf["paths"] = [str(root)]  # ask() reloads the project from disk
    f.write_text(yaml.safe_dump(conf, allow_unicode=True))
    h = HelpDesk(broker, manager, d)
    assert h.ask({"text": "可以上正式嗎", "cwd": item.worktree + "/src", "session_id": "s9"})["ok"]
    wait_for(lambda: len(sent) == 2)
    assert sent[1][:2] == ("worker", elsa)
    # Any other conversation in the project is still the owner's.
    assert h.ask({"text": "別的", "cwd": str(root / "platform"), "session_id": "s10"})["ok"]
    wait_for(lambda: len(sent) == 3)
    assert sent[2][1] is None


def test_trust_keeps_the_rest_of_the_config(tmp_path):
    import json
    tmp_path = tmp_path / "home"
    tmp_path.mkdir()
    cfg = tmp_path / "c.json"
    cfg.write_text(json.dumps({"oauthAccount": {"x": 1}, "projects": {"/a": {"allowedTools": ["Bash"]}}}))
    cfg.chmod(0o600)
    dispatch.trust(tmp_path, cfg)
    dispatch.trust(tmp_path, cfg)  # twice is fine
    data = json.loads(cfg.read_text())
    assert data["oauthAccount"] == {"x": 1} and data["projects"]["/a"] == {"allowedTools": ["Bash"]}
    assert data["projects"][str(tmp_path.resolve())] == {"hasTrustDialogAccepted": True}
    assert cfg.stat().st_mode & 0o777 == 0o600
    assert [x.name for x in tmp_path.iterdir()] == ["c.json"]  # no temp file left
    dispatch.trust(tmp_path, tmp_path / "missing.json")  # no config: nothing happens
    assert not (tmp_path / "missing.json").exists()
