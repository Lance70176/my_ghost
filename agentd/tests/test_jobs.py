import json

from ghost_agentd import tools


def write_job(root, jid, **state):
    d = root / jid
    d.mkdir(parents=True)
    (d / "state.json").write_text(json.dumps(state))


def test_list_jobs_by_project(tmp_path, monkeypatch):
    jobs = tmp_path / "jobs"
    monkeypatch.setattr(tools, "JOBS", jobs)
    proj = tmp_path / "fq"
    (proj / "bc-api").mkdir(parents=True)
    write_job(jobs, "a1", name="日報", state="done", detail="完成了 token=abc123secret", cwd=str(proj),
              sessionId="s-a", updatedAt="2026-10-13T10:00:00Z")
    write_job(jobs, "b2", name="H5", state="working", cwd=str(proj / "bc-api"),
              sessionId="s-b", updatedAt="2026-10-14T01:00:00Z")
    write_job(jobs, "c3", name="其他專案", state="done", cwd=str(tmp_path / "lts"), sessionId="s-c")
    write_job(jobs, "d4", name="助手自己", state="working", cwd=str(proj), sessionId="own")
    out = tools.list_jobs([str(proj)], exclude_session="own")
    assert [j["name"] for j in out] == ["H5", "日報"]  # newest first, other project and self excluded
    assert out[0]["state_label"] == "執行中" and out[1]["state_label"] == "完成"
    assert "abc123secret" not in out[1]["detail"]


def test_tab_status_follows_jobs_and_activity(tmp_path, monkeypatch):
    """A background job's own state wins over an old hook event, and a
    'running' conversation whose transcript went quiet has stopped."""
    import os
    import time as _t
    from ghost_agentd.broker import Session
    jobs = tmp_path / "jobs"
    trans = tmp_path / "tr"
    monkeypatch.setattr(tools, "JOBS", jobs)
    monkeypatch.setattr(tools, "TRANSCRIPTS", trans)
    monkeypatch.setattr(tools, "_job_cache", (0.0, []))
    write_job(jobs, "j1", state="done", sessionId="job-done")
    write_job(jobs, "j2", state="working", sessionId="job-busy")
    (trans / "p").mkdir(parents=True)
    old = trans / "p" / "quiet.jsonl"
    old.write_text("{}")
    os.utime(old, (_t.time() - 3600, _t.time() - 3600))
    (trans / "p" / "busy.jsonl").write_text("{}")

    class B:  # just what _status needs
        pending = {}
        STALE_RUNNING = 900
    from ghost_agentd.broker import Broker
    st = lambda sid, status: Broker._status(B, Session(sid, "fq", "", status=status), tools.job_states())
    assert st("job-done", "waiting") == "done"     # it asked once, then finished
    assert st("job-busy", "waiting") == "running"
    assert st("quiet", "running") == "done"        # interrupted: no Stop came
    assert st("busy", "running") == "running"
    assert st("unknown", "waiting") == "waiting"


def test_agent_view_status_is_its_jobs(tmp_path, monkeypatch):
    from ghost_agentd.broker import Broker, Session
    jobs = tmp_path / "jobs"
    monkeypatch.setattr(tools, "JOBS", jobs)
    monkeypatch.setattr(tools, "TRANSCRIPTS", tmp_path / "none")
    monkeypatch.setattr(tools, "_job_cache", (0.0, []))
    view = str(tmp_path / "claude")
    write_job(jobs, "a", state="done", sessionId="s1", originCwd=view)
    write_job(jobs, "b", state="done", sessionId="s2", originCwd=view + "/sub")
    write_job(jobs, "c", state="needs_input", sessionId="s3", originCwd=str(tmp_path / "other"))

    class B:
        pending = {}
        STALE_RUNNING = 900
    v = Session("view", "x", view, status="waiting", agent_view=True)
    assert Broker._status(B, v, tools.job_states()) == "done"  # asked once; all finished now
    write_job(jobs, "d", state="working", sessionId="s4", originCwd=view)
    monkeypatch.setattr(tools, "_job_cache", (0.0, []))
    assert Broker._status(B, v, tools.job_states()) == "running"


def test_job_remove_runs_claude_rm(tmp_path, monkeypatch):
    """Deleting a conversation is `claude rm <id>`; its refusal (work not
    pushed) comes back for the commander to read."""
    calls = tmp_path / "calls"
    fake = tmp_path / "claude"
    fake.write_text(f'#!/bin/sh\necho "$@" >> {calls}\n'
                    'if [ "$2" = "keep" ]; then echo "worktree has unpushed commits" >&2; exit 1; fi\n')
    fake.chmod(0o755)
    monkeypatch.setattr(tools, "CLAUDE_BIN", str(fake))
    monkeypatch.setattr(tools, "_tmux", lambda *a, **k: None)
    assert tools.job_remove({"id": "a1b2c3d4", "cwd": str(tmp_path)}) == ""
    assert "unpushed" in tools.job_remove({"id": "keep", "cwd": str(tmp_path)})
    assert calls.read_text().split("\n")[:2] == ["rm a1b2c3d4", "rm keep"]
