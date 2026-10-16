"""db_query: read-only queries the daemon runs for the assistant; databases
marked `confirm` (production) wait for the owner's card."""

import json
import socket
import stat

from ghost_agentd.dbquery import DBQuery, check_sql
from test_assistant import manager, wait_for  # noqa: F401  (fixtures)
from test_broker import broker, home  # noqa: F401  (fixtures)


def test_only_one_read_only_statement():
    for ok in ["SELECT * FROM member WHERE id = 5 LIMIT 1",
               "select `update`, `delete` from t;",  # quoted names are fine
               "SELECT REPLACE(name, 'a', 'b'), 'drop table x; --' FROM t",
               "SHOW TABLES", "DESCRIBE member", "EXPLAIN SELECT 1",
               "WITH x AS (SELECT 1) SELECT * FROM x", "-- note\nSELECT 1"]:
        assert check_sql(ok) is None, ok
    for bad in ["", "UPDATE member SET x = 1", "DELETE FROM t", "SELECT 1; DROP TABLE t",
                "SELECT * FROM t FOR UPDATE", "SELECT SLEEP(100)", "SELECT 1 INTO OUTFILE '/tmp/x'",
                "SELECT /*!50000 1 */", "SELECT 1 INTO @a", "ANALYZE SELECT 1",
                "WITH x AS (SELECT 1) DELETE FROM t", "SELECT 'unclosed"]:
        assert check_sql(bad), bad


def fake_db(tmp_path, project, confirm=False):
    """A client script that records what it ran and prints two rows."""
    srv = socket.socket()
    srv.bind(("127.0.0.1", 0))
    srv.listen()
    log = tmp_path / "ran.txt"
    client = tmp_path / "client.sh"
    client.write_text("#!/bin/bash\n"
                      f"printf '%s\\n' \"$@\" > {log}\n"
                      "printf 'id\\tname\\n1\\tAmy\\n2\\tBob\\n'\n")
    client.chmod(client.stat().st_mode | stat.S_IEXEC)
    project.databases = {"lsc-dev": {"client": str(client), "port": srv.getsockname()[1]},
                         "lsc-prod": {"client": str(client), "port": srv.getsockname()[1], "confirm": True}}
    return srv, log


def test_runs_read_only_and_logs(broker, manager, tmp_path):
    p = broker.projects.get("fq")
    srv, log = fake_db(tmp_path, p)
    q = DBQuery(broker, manager)
    assert "沒有叫" in q.query(p, "nope", "SELECT 1")
    assert "沒有執行" in q.query(p, "lsc-dev", "DELETE FROM t") and not log.exists()
    out = q.query(p, "lsc-dev", "SELECT id, name FROM member LIMIT 2")
    assert "2 列" in out and "Amy" in out
    ran = log.read_text()
    assert "--batch" in ran and "START TRANSACTION READ ONLY; SELECT id, name FROM member LIMIT 2; ROLLBACK;" in ran
    assert "SET SESSION TRANSACTION READ ONLY" in ran
    assert "max_execution_time = 60000" in ran  # the fake isn't MariaDB: MySQL's limit
    ev = [json.loads(l) for l in (p.dir / "events.jsonl").read_text().splitlines()]
    assert ev[-1]["type"] == "db_query" and ev[-1]["db"] == "lsc-dev" and ev[-1]["rows"] == 2
    srv.close()


def test_production_waits_for_the_owner(broker, manager, tmp_path, monkeypatch):
    p = broker.projects.get("fq")
    srv, log = fake_db(tmp_path, p)
    q = DBQuery(broker, manager)
    broker.listeners.append(q)
    broker.requester_of = lambda name: {"id": 7, "name": "Elsa"}  # a member's turn
    out = q.query(p, "lsc-prod", "SELECT COUNT(*) FROM member", "看會員數")
    assert "負責人同意" in out and not log.exists()
    card = next(x for x in broker.pending.values() if getattr(x, "db_query", None))
    assert card.requested_by is None  # only the owner may press it
    assert "成員 Elsa" in card.summary and "看會員數" in card.summary

    sent = []
    a = manager.get("fq")
    monkeypatch.setattr(a, "send", lambda text, source, *rest, **kw: sent.append(text))
    broker.decide(card.id, "o0", "myghost")
    wait_for(lambda: any("Amy" in t for t in sent))
    assert "START TRANSACTION READ ONLY; SELECT COUNT(*) FROM member" in log.read_text()

    log.unlink()
    q.query(p, "lsc-prod", "SELECT 1")
    card = next(x for x in broker.pending.values() if getattr(x, "db_query", None) and x.open)
    broker.decide(card.id, "o1", "myghost")  # 不查
    wait_for(lambda: any("不同意" in t for t in sent))
    assert not log.exists()
    srv.close()
