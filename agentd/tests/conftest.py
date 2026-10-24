import os
import tempfile

import pytest

# Before ghost_agentd is imported: its HOME default must never be the real
# ~/.myghost. Fixtures monkeypatch HOME per test, but an assistant's reader
# thread can outlive its test and save after the patch is undone — that
# once wrote an empty pending.json over the live daemon's waiting cards,
# lost at its next restart.
os.environ["MYGHOST_HOME"] = tempfile.mkdtemp(prefix="myghost-test-home-")


@pytest.fixture(autouse=True)
def _own_claude_config(tmp_path, monkeypatch):
    """Dispatching marks worktrees trusted in Claude Code's config; never
    the real ~/.claude.json from a test."""
    from ghost_agentd import dispatch
    cfg = tmp_path / "claude.json"
    cfg.write_text('{"projects": {}}')
    monkeypatch.setattr(dispatch, "CLAUDE_CONFIG", cfg)
    return cfg
