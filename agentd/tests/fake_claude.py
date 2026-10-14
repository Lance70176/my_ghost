#!/usr/bin/env python3
"""A stand-in for `claude -p` in bidirectional stream-json mode, for tests.

Replies "回覆：<text>" to every message (streamed as a text delta first),
answers /context with FAKE_CTX percent, /compact with a compact_boundary,
and "SLOW" waits until interrupted. Logs its argv to FAKE_ARGV_LOG.
"""

import json
import os
import select
import sys

if os.environ.get("FAKE_ARGV_LOG"):
    with open(os.environ["FAKE_ARGV_LOG"], "a") as f:
        f.write(json.dumps(sys.argv[1:]) + "\n")

sid = "fake"
for flag in ("--session-id", "--resume"):
    if flag in sys.argv:
        sid = sys.argv[sys.argv.index(flag) + 1]


def out(obj):
    obj.setdefault("session_id", sid)
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def result(text="", is_error=False):
    out({"type": "result", "subtype": "success", "is_error": is_error, "result": text, "num_turns": 1})


out({"type": "system", "subtype": "init", "model": "fake"})
for line in sys.stdin:
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    if msg.get("type") == "control_request":
        continue
    content = (msg.get("message") or {}).get("content", "")
    text = content if isinstance(content, str) else ""
    if text == "/context":
        pct = int(os.environ.get("FAKE_CTX", "10"))
        out({"type": "assistant", "message": {"content": [{"type": "text", "text": f"Context {pct}%"}]},
             "context_usage": {"percentage": pct}})
        result()
    elif text == "/compact":
        out({"type": "system", "subtype": "compact_boundary", "compact_metadata": {"trigger": "manual"}})
        result()
    elif text.endswith("SLOW"):
        # Wait for an interrupt (or give up after 5 s).
        r, _, _ = select.select([sys.stdin], [], [], 5)
        if r:
            sys.stdin.readline()
        result("interrupted", is_error=True)
    else:
        reply = "回覆：" + text
        out({"type": "stream_event", "event": {"delta": {"type": "text_delta", "text": reply[:3]}}})
        out({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "name": "mcp__ghost__read_state", "input": {}},
            {"type": "text", "text": reply}]}})
        result(reply)
