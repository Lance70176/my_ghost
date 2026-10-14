#!/usr/bin/env python3
"""Claude Code hook for ghost-agentd. One script for every event; stdlib only.

PermissionRequest: forwards the request to the daemon and blocks until the
user decides on TG / MyGhost / the phone page, then prints the decision.
If the daemon isn't running, prints nothing so Claude Code shows its normal
prompt — installing the hook never makes a session worse off than without it.

Other events (Notification, Stop, UserPromptSubmit, SessionEnd) are posted
fire-and-forget so the daemon can track each session's status.

Set GHOST_AGENTD=off in a session's environment to bypass it.
"""

import json
import os
import secrets
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

URL = os.environ.get("GHOST_AGENTD_URL", "http://127.0.0.1:7788")
# Slightly under the hook timeout in settings.json (604800s = 7 days, so a
# request under discussion can wait that long) so we always get
# to print an answer before Claude Code kills us.
DEADLINE = float(os.environ.get("GHOST_HOOK_DEADLINE", "604780"))


def tmux_info():
    pane = os.environ.get("TMUX_PANE")
    tmux = shutil.which("tmux") or "/opt/homebrew/bin/tmux"
    if not pane or not os.environ.get("TMUX"):
        return "", ""
    try:
        out = subprocess.run(
            [tmux, "display-message", "-p", "-t", pane, "#{session_name}\t#{@myghost_title}"],
            capture_output=True, text=True, timeout=2,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return "", ""
    name, _, title = out.partition("\t")
    return name, title


def post(path, payload, timeout):
    req = urllib.request.Request(
        URL + path, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "X-Ghost": "1"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def permission(payload):
    payload["request_key"] = secrets.token_hex(8)
    start = time.time()
    first = True
    while True:
        left = DEADLINE - (time.time() - start)
        if left <= 5:
            return None
        try:
            return post("/hook/permission", payload, timeout=left)
        except urllib.error.HTTPError:
            return None
        except (urllib.error.URLError, ConnectionError, TimeoutError, OSError):
            # Not running at all: fall back to the normal prompt right away.
            if first:
                return None
            # Dropped mid-wait (daemon restarting): re-join the same card.
            time.sleep(2)
        first = False


def main():
    if os.environ.get("GHOST_AGENTD", "").lower() in ("off", "0", "false"):
        return
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return
    payload["tmux_session"], payload["tab_title"] = tmux_info()
    if os.environ.get("GHOST_ASSISTANT"):
        # The project assistant itself (run by ghost-agentd, not in a tab).
        payload["tab_title"] = os.environ["GHOST_ASSISTANT"] + " 助手"
    event = payload.get("hook_event_name", "")

    if event == "SessionStart":
        # Tell conversations in a project how to reach its assistant
        # (not the assistant itself).
        if os.environ.get("GHOST_ASSISTANT"):
            return
        try:
            ctx = post("/hook/context", {"cwd": payload.get("cwd", "")}, timeout=3).get("context")
        except Exception:
            return
        if ctx:
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": "SessionStart", "additionalContext": ctx}}, ensure_ascii=False))
        return

    if event == "PermissionRequest":
        # Don't forward the transcript path's contents, just the request.
        result = permission(payload)
        if not result or result.get("behavior") not in ("allow", "deny"):
            return
        decision = {"behavior": result["behavior"]}
        if result["behavior"] == "deny":
            decision["message"] = result.get("message") or "使用者拒絕了這個操作。"
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PermissionRequest", "decision": decision}}, ensure_ascii=False))
        return

    for k in ("transcript_path",):
        payload.pop(k, None)
    try:
        post("/hook/event", payload, timeout=2)
    except Exception:
        pass


if __name__ == "__main__":
    main()
