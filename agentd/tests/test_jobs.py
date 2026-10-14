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
    monkeypatch.setattr(tools, "_job_cache", (0.0, {}))
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
