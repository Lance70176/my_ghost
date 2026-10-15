"""Daily schedules: the daemon wakes the assistant once a day, at a random
time within the window, on the days set — and a restart changes nothing."""

import json
from datetime import datetime

from ghost_agentd.schedule import Schedules


def at(s: str) -> float:
    return datetime.strptime(s, "%Y-%m-%d %H:%M").timestamp()


class FakeAssistant:
    def __init__(self):
        self.got = []

    def send(self, text, source):
        self.got.append((text, source))


class FakeAssistants:
    def __init__(self, a):
        self.a = a

    def get(self, name):
        return self.a


class FakeProject:
    def __init__(self, d):
        self.name, self.dir = "fq", d


class FakeProjects:
    def __init__(self, p):
        self.p = p

    def all(self):
        return [self.p]


def schedules(tmp_path, a):
    (tmp_path / "schedule.yaml").write_text(
        '- name: 工作日報\n  when: "mon-fri 18:30-19:00"\n  random: true\n  prompt: 發日報\n')
    return Schedules(FakeProjects(FakeProject(tmp_path)), FakeAssistants(a))


def state(tmp_path):
    return json.loads((tmp_path / "schedule_state.json").read_text())["工作日報"]


def test_fires_once_at_a_random_time_in_the_window(tmp_path):
    a = FakeAssistant()
    schedules(tmp_path, a).tick(at("2026-10-15 12:00"))  # Thursday: picks today's time
    when = state(tmp_path)["at"]
    assert at("2026-10-15 18:30") <= when < at("2026-10-15 19:00")
    assert not a.got
    # A restart keeps the time, and it fires once.
    s = schedules(tmp_path, a)
    s.tick(when + 1)
    s.tick(when + 30)
    assert len(a.got) == 1 and a.got[0][1] == "schedule" and "發日報" in a.got[0][0]
    assert state(tmp_path)["at"] == when


def test_not_on_weekends_and_not_late(tmp_path):
    a = FakeAssistant()
    s = schedules(tmp_path, a)
    s.tick(at("2026-10-17 18:45"))  # Saturday
    assert not a.got
    s.tick(at("2026-10-16 20:00"))  # Friday, daemon down through the window
    assert not a.got and state(tmp_path)["fired"]
