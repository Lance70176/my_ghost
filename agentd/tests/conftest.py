import pytest


@pytest.fixture(autouse=True)
def _own_claude_config(tmp_path, monkeypatch):
    """Dispatching marks worktrees trusted in Claude Code's config; never
    the real ~/.claude.json from a test."""
    from ghost_agentd import dispatch
    cfg = tmp_path / "claude.json"
    cfg.write_text('{"projects": {}}')
    monkeypatch.setattr(dispatch, "CLAUDE_CONFIG", cfg)
    return cfg
