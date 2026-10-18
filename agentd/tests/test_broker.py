import json
import os
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def home(tmp_path, monkeypatch):
    from ghost_agentd import config
    monkeypatch.setattr(config, "HOME", tmp_path)
    proj = tmp_path / "projects" / "fq"
    proj.mkdir(parents=True)
    (proj / "project.yaml").write_text(
        f"paths: ['{tmp_path}/code/fq']\ntelegram: {{token: '', chat_id: -100123}}\nresident: true\npolicy:\n  l1: ['walle 發 *-test']\n")
    (tmp_path / "code" / "fq" / "sub").mkdir(parents=True)
    return tmp_path


@pytest.fixture
def broker(home):
    from ghost_agentd.broker import Broker
    from ghost_agentd.config import Config, Projects
    cfg = Config(decision_timeout=5, digest_seconds=0, hold_every_conversation=True)
    b = Broker(cfg, Projects())
    b.tg_projects = {"fq", "_default"}
    b.events = []

    class Rec:
        def on_pending(self, p): b.events.append(("pending", p.id))
        def on_update(self, p): b.events.append(("update", p.id, p.state))
        def on_notice(self, project, text): b.events.append(("notice", project.name, text))

    b.listeners.append(Rec())
    return b


def ask(broker, cmd, cwd, out):
    payload = {"session_id": "s1", "cwd": cwd, "tool_name": "Bash",
               "tool_input": {"command": cmd}, "tab_title": "H5NewGPay2"}
    out.append(broker.request_permission(payload))


def wait_pending(broker, n=1):
    for _ in range(100):
        if len(broker.pending) >= n:
            return list(broker.pending.values())
        time.sleep(0.02)
    raise AssertionError("no pending request appeared")


def test_l0_allowed_without_card_and_digested(broker, home):
    out = []
    ask(broker, "git status", f"{home}/code/fq/sub", out)
    assert out[0]["behavior"] == "allow"
    assert not any(e[0] == "pending" for e in broker.events)
    broker.flush_digests(force=True)
    notice = [e for e in broker.events if e[0] == "notice"]
    assert notice and notice[0][1] == "fq" and "L0" in notice[0][2]


def test_project_l1_rule(broker, home):
    out = []
    ask(broker, "walle 發 bc-api-test", f"{home}/code/fq", out)
    assert out[0]["behavior"] == "allow"


def test_l2_allow_from_card(broker, home):
    out = []
    t = threading.Thread(target=ask, args=(broker, "git push origin feature/x", f"{home}/code/fq", out))
    t.start()
    p = wait_pending(broker)[0]
    assert p.project == "fq" and p.level == 2
    assert broker.sessions["s1"].status == "waiting"
    ok, _ = broker.decide(p.id, "allow", "tg")
    t.join(2)
    assert ok and out[0]["behavior"] == "allow"
    assert broker.sessions["s1"].status == "running"
    ok, why = broker.decide(p.id, "deny", "myghost")
    assert not ok  # second surface sees it's already handled
    log = [json.loads(l) for l in (home / "projects/fq/decisions.jsonl").read_text().splitlines()]
    assert log[-1]["state"] == "allowed" and log[-1]["by"] == "tg"


def test_deny_with_reason(broker, home):
    out = []
    t = threading.Thread(target=ask, args=(broker, "rm -rf build", f"{home}/code/fq", out))
    t.start()
    p = wait_pending(broker)[0]
    broker.decide(p.id, "deny", "tg", message="先別刪，build 裡有要留的檔")
    t.join(2)
    assert out[0]["behavior"] == "deny" and "要留的檔" in out[0]["message"]


def test_always_allow_persists(broker, home):
    out = []
    t = threading.Thread(target=ask, args=(broker, "git push origin feature/a", f"{home}/code/fq", out))
    t.start()
    p = wait_pending(broker)[0]
    broker.decide(p.id, "always", "tg")
    t.join(2)
    assert out[0]["behavior"] == "allow"
    assert json.loads((home / "projects/fq/always_allow.json").read_text()) == ["git push origin feature/*"]
    out2 = []
    ask(broker, "git push origin feature/b", f"{home}/code/fq", out2)
    assert out2[0]["behavior"] == "allow"


def test_l3_needs_confirm_and_cannot_always(broker, home):
    out = []
    t = threading.Thread(target=ask, args=(broker, "mysql -h prod-db -e 'UPDATE x'", f"{home}/code/fq", out))
    t.start()
    p = wait_pending(broker)[0]
    assert broker.decide(p.id, "always", "tg")[0] is False
    assert broker.decide(p.id, "allow", "tg") == (True, "L3：請再確認一次")
    assert p.state == "confirming" and not out
    broker.decide(p.id, "confirm", "tg")
    t.join(2)
    assert out[0]["behavior"] == "allow"


def test_timeout_denies(broker, home):
    broker.cfg.decision_timeout = 0.3
    out = []
    ask(broker, "rm x", f"{home}/code/fq", out)
    assert out[0]["behavior"] == "deny" and "逾時" in out[0]["message"]
    assert any(e == ("update", e[1], "expired") for e in broker.events if e[0] == "update")


def test_retry_rejoins_same_card(broker, home):
    out = []
    payload = {"session_id": "s1", "cwd": f"{home}/code/fq", "tool_name": "Bash",
               "tool_input": {"command": "rm x"}, "request_key": "k1"}
    t1 = threading.Thread(target=lambda: out.append(broker.request_permission(dict(payload))))
    t1.start()
    p = wait_pending(broker)[0]
    t2 = threading.Thread(target=lambda: out.append(broker.request_permission(dict(payload))))
    t2.start()
    time.sleep(0.1)
    assert len(broker.pending) == 1
    broker.decide(p.id, "allow", "web")
    t1.join(2), t2.join(2)
    assert [o["behavior"] for o in out] == ["allow", "allow"]


def test_unmatched_cwd_goes_to_default(broker, home):
    out = []
    t = threading.Thread(target=ask, args=(broker, "rm x", "/somewhere/else", out))
    t.start()
    p = wait_pending(broker)[0]
    assert p.project == "_default"
    broker.decide(p.id, "deny", "tg")
    t.join(2)


def test_session_status_from_events(broker, home):
    cwd = f"{home}/code/fq"
    broker.hook_event({"hook_event_name": "UserPromptSubmit", "session_id": "s9", "cwd": cwd})
    assert broker.sessions["s9"].status == "running"
    broker.hook_event({"hook_event_name": "Stop", "session_id": "s9", "cwd": cwd,
                       "last_assistant_message": "done"})
    assert broker.sessions["s9"].status == "done"
    broker.hook_event({"hook_event_name": "SessionEnd", "session_id": "s9", "cwd": cwd})
    assert all(s["session_id"] != "s9" for s in broker.list_sessions())


def test_http_and_hook_end_to_end(home, tmp_path):
    """Real daemon process + real hook script, decision made over the API."""
    port = 17788
    (home / "config.yaml").write_text(f"port: {port}\ndecision_timeout: 20\n")
    env = dict(os.environ, MYGHOST_HOME=str(home), PYTHONPATH=str(ROOT), GHOST_NO_ASSISTANTS="1")
    daemon = subprocess.Popen([sys.executable, "-m", "ghost_agentd"], env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        base = f"http://127.0.0.1:{port}"
        for _ in range(50):
            try:
                urllib.request.urlopen(base + "/api/health", timeout=1)
                break
            except OSError:
                time.sleep(0.1)
        # With no surface online the daemon declines and the hook stays silent.
        r = subprocess.run([sys.executable, str(ROOT / "hooks/ghost-hook.py")], text=True,
                           env=dict(env, GHOST_AGENTD_URL=base), capture_output=True, timeout=10,
                           input=json.dumps({"hook_event_name": "PermissionRequest", "cwd": "/x",
                                             "tool_name": "Bash", "tool_input": {"command": "rm y"}}))
        assert r.stdout == ""
        urllib.request.urlopen(base + "/api/state?client=myghost", timeout=2)
        # As an assistant's own conversation: only those (and dispatched work)
        # are held as cards now.
        hook_env = dict(env, GHOST_AGENTD_URL=base, GHOST_ASSISTANT="fq")
        hook_env.pop("TMUX", None)
        payload = {"hook_event_name": "PermissionRequest", "session_id": "e2e",
                   "cwd": f"{home}/code/fq", "tool_name": "Bash",
                   "tool_input": {"command": "git push origin feature/e2e"}}
        hook = subprocess.Popen([sys.executable, str(ROOT / "hooks/ghost-hook.py")], env=hook_env,
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        hook.stdin.write(json.dumps(payload))
        hook.stdin.close()
        state = None
        for _ in range(50):
            state = json.loads(urllib.request.urlopen(base + "/api/state", timeout=2).read())
            if state["pending"]:
                break
            time.sleep(0.1)
        pid = state["pending"][0]["id"]
        # A POST without the header is refused (CSRF guard).
        req = urllib.request.Request(f"{base}/api/decisions/{pid}", method="POST",
                                     data=b'{"action":"allow"}')
        with pytest.raises(urllib.error.HTTPError) as e:
            urllib.request.urlopen(req, timeout=2)
        assert e.value.code == 403
        req = urllib.request.Request(f"{base}/api/decisions/{pid}", method="POST",
                                     data=json.dumps({"action": "deny", "by": "myghost",
                                                      "message": "not now"}).encode(),
                                     headers={"X-Ghost": "1", "Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=2)
        out = json.loads(hook.stdout.read())
        hook.wait(5)
        d = out["hookSpecificOutput"]["decision"]
        assert out["hookSpecificOutput"]["hookEventName"] == "PermissionRequest"
        assert d["behavior"] == "deny" and "not now" in d["message"]
    finally:
        daemon.terminate()
        daemon.wait(5)
        print(daemon.stdout.read().decode())


def test_hook_silent_when_daemon_down(tmp_path):
    env = dict(os.environ, GHOST_AGENTD_URL="http://127.0.0.1:1")
    r = subprocess.run([sys.executable, str(ROOT / "hooks/ghost-hook.py")], env=env, text=True,
                       input=json.dumps({"hook_event_name": "PermissionRequest", "tool_name": "Bash",
                                         "tool_input": {"command": "rm x"}}),
                       capture_output=True, timeout=10)
    assert r.returncode == 0 and r.stdout == ""
