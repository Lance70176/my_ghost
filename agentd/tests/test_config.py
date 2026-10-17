"""bind_chat_id (/chatid): fills in a project's group, however the empty
chat_id was written."""

import yaml

from ghost_agentd import config


def bound(tmp_path, monkeypatch, line):
    monkeypatch.setattr(config, "HOME", tmp_path)
    d = tmp_path / "projects" / "case"
    d.mkdir(parents=True, exist_ok=True)
    f = d / "project.yaml"
    f.write_text(f"name: case\ntelegram:\n  token: \"T\"\n{line}\nresident: false\n")
    p = config.Project("case", [])
    ok = config.bind_chat_id(p, -5348996874)
    return ok, yaml.safe_load(f.read_text())["telegram"].get("chat_id"), f.read_text()


def test_binds_every_way_of_writing_nothing(tmp_path, monkeypatch):
    for line in ("  chat_id: null", "  chat_id: ~  # none yet", "  chat_id:",
                 "  chat_id:                # TODO: send /chatid there"):
        ok, chat, text = bound(tmp_path, monkeypatch, line)
        assert ok and chat == -5348996874, (line, text)
    assert "# TODO" in text  # the comment stays a comment


def test_never_replaces_a_group_already_set(tmp_path, monkeypatch):
    ok, chat, _ = bound(tmp_path, monkeypatch, "  chat_id: -100123  # group")
    assert not ok and chat == -100123
