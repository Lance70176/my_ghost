"""Who may reach the assistant by private message (2026-10-16).

Every private message to the work account is recorded, but only people the
owner has agreed to are handed to the assistant. The owner tells the
assistant in their own conversation ("let Louis's DMs in, only for the _UTC
task, two days"); the assistant records it with grant_dm, which the daemon
only accepts on a turn the owner started — a message from the person
themselves can't open the door.

- level "forward": the assistant sees their messages; replies are cards.
- level "auto": within `scope` it may also answer by itself (send_reply).
- At most MAX_DAYS per agreement; longer goes to a review card. Half a day
  before the end the owner gets a card to renew for another MAX_DAYS;
  unanswered, the grant simply ends.
- A message with sensitive data: the assistant asks the owner to judge the
  risk (flag_sensitive). Medium drops the grant to "forward", high ends it.

Stored in projects/<name>/dm_grants.json.
"""

from __future__ import annotations

import json
import os
import threading
import time
from dataclasses import asdict, dataclass, fields
from pathlib import Path

MAX_DAYS = 3
REMIND_BEFORE = 12 * 3600
FORWARD, AUTO = "forward", "auto"
LEVEL_TEXT = {FORWARD: "轉給助手（回覆出卡）", AUTO: "範圍內可自動回"}


@dataclass
class Grant:
    chat_id: int
    name: str
    level: str  # forward | auto
    scope: str  # the kind of task the owner agreed to
    until: float
    granted_at: float
    # Sensitive data judged medium: replies are cards from then on.
    risk: str = ""
    # The renew card: "" | "asked" (remind_card is open) | "declined"
    remind: str = ""
    remind_card: str = ""

    def describe(self) -> str:
        end = time.strftime("%m/%d %H:%M", time.localtime(self.until))
        return f"{self.name}｜{LEVEL_TEXT.get(self.level, self.level)}｜範圍：{self.scope}｜到 {end}"


class DmGrants:
    def __init__(self, path: Path):
        self.path = path
        self.lock = threading.RLock()
        self.grants: dict[int, Grant] = {}
        self._load()

    def _load(self) -> None:
        try:
            rows = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return
        names = {f.name for f in fields(Grant)}
        for r in rows if isinstance(rows, list) else []:
            try:
                g = Grant(**{k: v for k, v in r.items() if k in names})
                self.grants[int(g.chat_id)] = g
            except (TypeError, ValueError):
                continue

    def save(self) -> None:
        with self.lock:
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps([asdict(g) for g in self.grants.values()], ensure_ascii=False, indent=1),
                           encoding="utf-8")
            os.chmod(tmp, 0o600)
            tmp.replace(self.path)

    def get(self, chat_id: int, now: float | None = None) -> Grant | None:
        """The grant for this person, if it hasn't ended."""
        g = self.grants.get(int(chat_id))
        return g if g and g.until > (now or time.time()) else None

    def put(self, g: Grant) -> None:
        with self.lock:
            self.grants[int(g.chat_id)] = g
            self.save()

    def remove(self, chat_id: int) -> Grant | None:
        with self.lock:
            g = self.grants.pop(int(chat_id), None)
            if g:
                self.save()
            return g

    def all(self) -> list[Grant]:
        return sorted(self.grants.values(), key=lambda g: g.until)
