#!/usr/bin/env python3
"""PreToolUse hook for a project assistant (ghost-agentd passes it with
--settings to the assistant only): keep it inside its own project.

Turns started by the owner's own words (ghost-agentd writes
GHOST_SCOPE_FILE) are not limited. Otherwise, files the assistant reads, searches or writes, and absolute / ~ / .. paths
in its shell commands, must be under GHOST_SCOPE_ROOTS (the project's
folders and its own ~/.myghost/projects/<name>), or under a few system
folders. Anything else — another project, ~/.myghost's other files,
~/.claude — is refused, so one project's assistant can't show another's
files to the people in its group.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import sys

HOME = os.path.expanduser("~")
SYSTEM = ("/usr", "/bin", "/sbin", "/opt/homebrew", "/dev/null", "/dev/stdin", "/dev/stdout",
          "/dev/stderr", "/dev/tty", "/tmp", "/private/tmp", "/var/folders", "/private/var/folders",
          "/System", "/Applications/Xcode.app", "/Library/Developer")
FILE_KEYS = ("file_path", "notebook_path", "path")


def roots() -> list[str]:
    return [os.path.realpath(r).rstrip("/") for r in os.environ.get("GHOST_SCOPE_ROOTS", "").split(os.pathsep) if r]


def inside(path: str, allowed: list[str]) -> bool:
    real = os.path.realpath(path)
    for r in allowed + [os.path.realpath(s) for s in SYSTEM]:
        if real == r or real.startswith(r.rstrip("/") + "/"):
            return True
    return False


def as_path(token: str, cwd: str) -> str | None:
    """The path a shell word names, if it plausibly names one."""
    t = token.strip("'\"")
    if "=" in t and not t.startswith(("/", "~", "$")):
        t = t.split("=", 1)[1]  # --file=/x, VAR=/x
    t = t.replace("${HOME}", HOME).replace("$HOME", HOME)
    if t.startswith("~"):
        t = os.path.expanduser(t)
    if t.startswith("/"):
        top = "/" + t.lstrip("/").split("/", 1)[0]
        # "/api/" in a grep pattern isn't a path: only real top-level folders.
        return t if os.path.exists(top) else None
    if ".." in t.split("/"):
        return os.path.join(cwd, t)
    return None


def owner_turn() -> bool:
    """The owner's own request: other projects are open to this turn."""
    f = os.environ.get("GHOST_SCOPE_FILE")
    if not f:
        return False
    try:
        with open(f, encoding="utf-8") as fh:
            return json.load(fh).get("mode") == "owner"
    except (OSError, ValueError):
        return False  # unknown: keep it inside


def outside(payload: dict) -> str | None:
    allowed = roots()
    if not allowed or owner_turn():
        return None
    tool = payload.get("tool_name", "")
    inp = payload.get("tool_input") or {}
    cwd = payload.get("cwd") or os.getcwd()
    if tool == "Bash":
        cmd = str(inp.get("command") or "")
        try:
            words = shlex.split(cmd, posix=True)
        except ValueError:
            words = cmd.split()
        for w in words:
            for part in re.split(r"[;|&<>()`]+|:(?=/)", w):
                p = as_path(part, cwd) if part else None
                if p and not inside(p, allowed):
                    return p
        if re.search(r"(^|[\s;|&])cd\s*($|[;|&])", cmd):  # bare cd: home
            return "cd 到家目錄"
        return None
    for k in FILE_KEYS:
        v = inp.get(k)
        if isinstance(v, str) and v:
            p = os.path.join(cwd, os.path.expanduser(v))
            if not inside(p, allowed):
                return p
    return None


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return
    try:
        bad = outside(payload)
    except Exception as e:  # fail closed: a broken check must not open everything
        bad = f"（檢查失敗：{e!r}）"
    if not bad:
        return
    where = "、".join(roots())
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse", "permissionDecision": "deny",
        "permissionDecisionReason": (
            f"專案權限分開：你只能存取自己專案的檔案（{where}），{bad} 不在範圍內。"
            "其他專案的資料不要查也不要提；需要就請負責人到那個專案的助手問。")}}, ensure_ascii=False))


if __name__ == "__main__":
    main()
