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
