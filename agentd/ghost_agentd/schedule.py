"""Daily schedules: at a set time — or a random one within a window — the
daemon wakes a project's assistant with a standing prompt.

    ~/.myghost/projects/<name>/schedule.yaml

    - name: 工作日報
      when: "mon-fri 18:30-19:00"   # same syntax as watch.yaml windows
      random: true                  # a random minute in the window (else its start)
      prompt: 發今天的工作日報…

Kept by the daemon rather than the assistant's own cron, which a restart
loses. Today's chosen time and whether it fired are in schedule_state.json,
so a restart neither fires twice nor picks a new time; a run missed because
the daemon was down past the window's end is skipped, not done late.
"""

from __future__ import annotations

import json
import random
import time
from pathlib import Path

import yaml

from .account import Window
from .broker import log


def load(path: Path) -> list[dict]:
    if not path.exists():
        return []
    try:
        raw = yaml.safe_load(path.read_text(encoding="utf-8")) or []
    except yaml.YAMLError as e:
        log(f"schedule: {path} is not valid YAML ({e})")
        return []
    return [e for e in raw if isinstance(e, dict) and e.get("name") and e.get("prompt") and e.get("when")]


class Schedules:
    def __init__(self, projects, assistants):
        self.projects = projects
        self.assistants = assistants

    def tick(self, now: float | None = None) -> None:
        now = now or time.time()
        for p in self.projects.all():
            entries = load(p.dir / "schedule.yaml")
            if entries:
                self._project(p, entries, now)

    def _project(self, p, entries: list[dict], now: float) -> None:
        state_file = p.dir / "schedule_state.json"
        try:
            state = json.loads(state_file.read_text())
        except (OSError, ValueError):
            state = {}
        lt = time.localtime(now)
        today = time.strftime("%Y-%m-%d", lt)
        midnight = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1))
        changed = False
        for e in entries:
            name = str(e["name"])
            w = Window.parse(e["when"])
            if (w.days is not None and lt.tm_wday not in w.days) or w.expired(now):
                continue
            start, end = midnight + w.start * 60, midnight + w.end * 60
            s = state.get(name) or {}
            if s.get("date") != today:
                at = start + (random.uniform(0, max(end - start - 60, 0)) if e.get("random") else 0)
                s = state[name] = {"date": today, "at": at, "fired": False}
                changed = True
                log(f"schedule {p.name}: {name} today at {time.strftime('%H:%M', time.localtime(at))}")
            if s["fired"] or now < s["at"]:
                continue
            s["fired"] = True
            changed = True
            if now >= end:
                log(f"schedule {p.name}: {name} missed (daemon was down)")
                continue
            log(f"schedule {p.name}: {name}")
            self.assistants.get(p.name).send(
                f"「{name}」排定時間到了（{time.strftime('%H:%M', time.localtime(now))}）。{str(e['prompt']).strip()}",
                "schedule")
        if changed:
            tmp = state_file.with_suffix(".tmp")
            tmp.write_text(json.dumps(state, ensure_ascii=False))
            tmp.replace(state_file)
