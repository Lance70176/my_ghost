#!/bin/bash
# Start MyGhost Web. First run installs npm dependencies (node-pty compiles
# a small native module, so the Xcode command line tools must be present).
#
# Usage:
#   ./start.sh              # foreground
#   ./start.sh --daemon     # background (nohup), log to web.log
#   ./start.sh --stop       # stop a daemonized server
#   MYGHOST_WEB_PORT=9000 ./start.sh
set -e
cd "$(dirname "$0")"

PID_FILE=".web.pid"

if [ "$1" = "--stop" ]; then
    if [ -f "$PID_FILE" ] && kill "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "stopped $(cat "$PID_FILE")"
    else
        echo "not running"
    fi
    rm -f "$PID_FILE"
    exit 0
fi

if ! command -v node >/dev/null; then
    echo "error: node not found — install Node.js first (brew install node)" >&2
    exit 1
fi

if [ ! -d node_modules ]; then
    echo "==> Installing dependencies (first run)..."
    npm install --no-fund --no-audit
fi

# npm drops the exec bit on node-pty's prebuilt spawn-helper, which then
# fails with "posix_spawnp failed" on the first terminal attach.
chmod +x node_modules/node-pty/prebuilds/*/spawn-helper 2>/dev/null || true

if [ "$1" = "--daemon" ]; then
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "already running (pid $(cat "$PID_FILE"))"
        exit 0
    fi
    nohup node server.js > web.log 2>&1 &
    echo $! > "$PID_FILE"
    sleep 1
    tail -5 web.log
    echo "(daemonized, pid $(cat "$PID_FILE") — stop with ./start.sh --stop)"
else
    exec node server.js
fi
