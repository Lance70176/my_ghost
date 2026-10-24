"""A process already stopped can still print its last result. That must not
start the assistant again (its /context follow-up used to), nor reach the
real ~/.myghost from a test."""

import os
from pathlib import Path

from ghost_agentd import config
from test_assistant import manager, wait_for  # noqa: F401  (fixtures)
from test_broker import broker, home  # noqa: F401  (fixtures)


def test_tests_never_use_the_real_home():
    real = Path.home() / ".myghost"
    assert Path(os.environ["MYGHOST_HOME"]) != real
    assert config.HOME != real


def test_a_stopped_process_result_starts_nothing(manager):
    a = manager.get("fq")
    a.start()
    wait_for(lambda: a.running)
    old = a.proc
    a.stop()
    assert not a.running
    a._event({"type": "result", "subtype": "success", "result": "late"}, old)
    assert a.proc is None and not a._outbox
