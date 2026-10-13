"""Discussion (no timeout) and the decision history / project list APIs."""

import json
import threading
import time

from test_broker import ask, broker, home, wait_pending  # noqa: F401  (fixtures)


def test_discuss_never_times_out_and_stays_decidable(broker, home):
    broker.cfg.decision_timeout = 0.3
    out = []
    t = threading.Thread(target=ask, args=(broker, "rm -rf build", f"{home}/code/fq", out))
    t.start()
    p = wait_pending(broker)[0]
    assert broker.decide(p.id, "discuss", "myghost")[0]
    assert broker.decide(p.id, "discuss", "myghost")[0] is False
    time.sleep(0.8)  # well past the 0.3s timeout
    assert not out and p.open and p.public()["remaining"] == -1
    broker.decide(p.id, "allow", "tg")
    t.join(2)
    assert out[0]["behavior"] == "allow"
    rec = json.loads((home / "projects/fq/decisions.jsonl").read_text().splitlines()[-1])
    assert rec["discussed"] is True and rec["state"] == "allowed"


def test_decision_history_and_projects(broker, home):
    out = []
    payload = {"session_id": "s7", "cwd": f"{home}/code/fq", "tool_name": "Bash",
               "tool_input": {"command": "rm x"}, "tmux_session": "myghost_abc", "tab_title": "T"}
    t = threading.Thread(target=lambda: out.append(broker.request_permission(payload)))
    t.start()
    p = wait_pending(broker)[0]
    projects = {r["name"]: r for r in broker.list_projects()}
    assert projects["fq"]["pending"] == 1 and projects["fq"]["resident"] is True
    assert broker.list_projects()[0]["name"] == "fq"  # resident first
    broker.decide(p.id, "deny", "web", message="no")
    t.join(2)
    hist = broker.list_decisions()
    assert hist[0]["tmux_session"] == "myghost_abc" and hist[0]["state"] == "denied"
    assert broker.list_decisions("fq")[0]["id"] == p.id
    assert broker.list_decisions("_default") == []
