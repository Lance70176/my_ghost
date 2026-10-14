"""A conversation asks its project assistant for help; the answer goes back
into that conversation — and only an answer to its own request."""

import os
import subprocess
import sys
import threading
from pathlib import Path

from ghost_agentd import dispatch, server, tools
from ghost_agentd.helpdesk import HelpDesk
from test_assistant import manager, roles, wait_for  # noqa: F401  (fixtures)
from test_broker import broker, home  # noqa: F401  (fixtures)

ASK = Path(__file__).resolve().parent.parent / "hooks" / "ghost-ask"


def desk(broker, manager, tmp_path):
    import yaml
    root = tmp_path / "code"
    (root / "repo").mkdir(parents=True)
    f = broker.projects.get("fq").dir / "project.yaml"
    conf = yaml.safe_load(f.read_text()) or {}
    conf["paths"] = [str(root)]
    f.write_text(yaml.safe_dump(conf, allow_unicode=True))
    broker.projects.reload()
    return broker.projects.get("fq"), root, HelpDesk(broker, manager)


def test_context_only_inside_a_project(broker, manager, tmp_path):
    p, root, h = desk(broker, manager, tmp_path)
    ctx = h.context_for(str(root / "repo"))
    assert "ghost-ask" in ctx and "fq" in ctx
    assert h.context_for("/tmp") == ""


def test_ask_and_reply_into_the_conversation(broker, manager, tmp_path, monkeypatch):
    p, root, h = desk(broker, manager, tmp_path)
    sent = []
    monkeypatch.setattr(tools, "job_send", lambda job, text: sent.append(("job", job["id"], text)) or "")
    monkeypatch.setattr(dispatch, "paste", lambda tmux, text: sent.append(("tmux", tmux, text)) or "")
    r = h.ask({"text": "要發 bc-api 到測試環境", "cwd": str(root / "repo"), "session_id": "s1", "job": "abcd1234"})
    assert r["ok"] and r["deliverable"]
    a = manager.get("fq")
    wait_for(lambda: any(r_ == "user" and "要發 bc-api 到測試環境" in t and r["id"] in t for r_, t in roles(a)))
    assert "已送進" in h.reply("fq", r["id"], "可以，用 walle 發 test")
    assert sent[-1][:2] == ("job", "abcd1234") and "回覆你的求助" in sent[-1][2]
    assert "沒有 id" in h.reply("lts", r["id"], "x")  # another project's assistant can't
    assert "沒有 id" in h.reply("fq", "ffffff", "x")
    t = h.ask({"text": "問題", "cwd": str(root), "tmux": "myghost_x"})
    h.reply("fq", t["id"], "答案")
    assert sent[-1][:2] == ("tmux", "myghost_x")
    assert not h.ask({"text": "x", "cwd": "/tmp"})["ok"]  # not in a project


def test_ghost_ask_waits_for_the_answer(broker, manager, tmp_path):
    p, root, h = desk(broker, manager, tmp_path)
    httpd = server.serve(broker, "127.0.0.1", 0, assistants=manager, helpdesk=h)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        env = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE", "TMUX"))}
        env["GHOST_AGENTD_URL"] = f"http://127.0.0.1:{httpd.server_address[1]}"
        proc = subprocess.Popen([sys.executable, str(ASK), "沒有分頁也沒有背景工作的對話"], cwd=str(root / "repo"),
                                env=env, stdout=subprocess.PIPE, text=True)
        wait_for(lambda: h.items)
        hid = next(iter(h.items))
        h.reply("fq", hid, "答案在這裡")
        out, _ = proc.communicate(timeout=20)
        assert "答案在這裡" in out
    finally:
        httpd.shutdown()
