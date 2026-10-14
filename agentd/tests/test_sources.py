"""ClickUp on a schedule: only changes wake the assistant, and the one thing
it may change is a tracked ticket's status (with a comment)."""

from datetime import datetime

from ghost_agentd import tools
from ghost_agentd.sources import ClickUpSource, Schedule
from test_assistant import manager, roles, wait_for  # noqa: F401  (fixtures)
from test_broker import broker, home  # noqa: F401  (fixtures)
from test_jobs import write_job


def at(s):
    return datetime.strptime(s, "%Y-%m-%d %H:%M").timestamp()


def test_schedule():
    s = Schedule.parse("weekday 09:00,14:00")
    thu_10 = at("2026-10-15 10:00")
    assert s.last_slot(thu_10) == at("2026-10-15 09:00")
    assert s.due(at("2026-10-15 08:00"), thu_10)
    assert not s.due(at("2026-10-15 09:05"), thu_10)
    assert s.last_slot(at("2026-10-17 12:00")) == at("2026-10-16 14:00")  # Saturday -> Fri 14:00
    assert Schedule.parse("every 30m").due(at("2026-10-15 09:00"), at("2026-10-15 09:31"))


class FakeClickUp:
    def __init__(self):
        self.tasks = {}
        self.calls = []

    def get(self, path, query=None):
        if path == "user":
            return {"user": {"id": 7}}
        if path == "team":
            return {"teams": [{"id": "900"}]}
        if path.startswith("team/"):
            return {"tasks": list(self.tasks.values()), "last_page": True}
        if path.endswith("/comment"):
            return {"comments": [{"date": "9999999999999", "user": {"username": "Lynn"},
                                  "comment_text": "STG 退回：金額不對"}]}
        if path.startswith("task/"):
            return {"name": "x", "status": {"status": "開發中"}, "url": "u", "text_content": "內容"}
        raise AssertionError(path)

    def call(self, method, path, body=None, query=None):
        self.calls.append((method, path, body))
        return {}


def task(tid, name, status, updated=1, lst="主看板"):
    return {"id": tid, "name": name, "status": {"status": status}, "list": {"name": lst},
            "url": f"https://app.clickup.com/t/{tid}", "date_updated": str(updated)}


def source(broker, manager, fake):
    p = broker.projects.get("fq")
    return ClickUpSource(p, {"name": "LTS 需求", "sites": ["LSA", "LSB", "LSC"],
                             "done_status": "待驗收", "schedule": "weekday 09:00,14:00"}, manager, fake)


def test_first_run_then_only_changes(broker, manager, tmp_path, monkeypatch):
    monkeypatch.setattr(tools, "JOBS", tmp_path / "jobs")
    monkeypatch.setattr(tools, "_job_cache", (0.0, []))
    p = broker.projects.get("fq")
    write_job(tmp_path / "jobs", "ab12cd34", name="【LSC】優惠設置 #198", state="working",
              cwd=p.paths[0] if p.paths else str(tmp_path))
    fake = FakeClickUp()
    fake.tasks = {"t1": task("t1", "【LSC】後台－優惠設置（#198）", "開發中"),
                  "t2": task("t2", "【LSA】後台－會員紀錄（#173）", "待驗收")}
    s = source(broker, manager, fake)
    a = manager.get("fq")
    assert "交給助手" in s.run()
    first = next(t for r, t in roles(a) if r == "user")
    assert "第一次盤點" in first and first.index("【LSA】") < first.index("【LSC】")  # grouped by site

    assert s.run().startswith("沒有變動")  # nothing changed: the assistant isn't woken
    assert sum(1 for r, _ in roles(a) if r == "user") == 1

    fake.tasks["t2"] = task("t2", "【LSA】後台－會員紀錄（#173）", "驗收未通過", updated=2)
    fake.tasks["t3"] = task("t3", "【LSB】新需求", "待領取")
    del fake.tasks["t1"]
    s.run()
    wait_for(lambda: sum(1 for r, _ in roles(a) if r == "user") == 2)
    msg = [t for r, t in roles(a) if r == "user"][-1]
    assert "待驗收 → 驗收未通過" in msg and "Lynn：STG 退回" in msg
    assert "離開清單" in msg and "新單" in msg
    if p.paths:
        assert "已有工作對話" in msg  # t1 matched the job by #198


def test_done_only_for_tracked_tickets(broker, manager):
    fake = FakeClickUp()
    fake.tasks = {"t1": task("t1", "【LSC】x", "開發中")}
    s = source(broker, manager, fake)
    s.run()
    assert "不在" in s.done("other", "留言")
    assert "留言" in s.done("t1", "  ")
    assert "待驗收" in s.done("t1", "改了 A；MR !12")
    assert ("PUT", "task/t1", {"status": "待驗收"}) in fake.calls
    assert any(c[0] == "POST" and c[1] == "task/t1/comment" for c in fake.calls)
    assert "不在" in s.task("other")
