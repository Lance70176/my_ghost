#!/bin/bash
# Install MyGhost.app into /Applications from a built DMG and relaunch it.
#
# Usage: install_local.sh [path/to/MyGhost.dmg]
#   (defaults to the MyGhost.dmg next to this script, i.e. build/MyGhost.dmg)
#
# Safe to run while MyGhost is open: the app is quit first, and because every
# tab runs inside a persistent tmux session, tabs reattach automatically on
# relaunch. Run build_dmg.sh first to produce the DMG.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DMG="${1:-$SCRIPT_DIR/MyGhost.dmg}"

if [ ! -f "$DMG" ]; then
    echo "error: DMG not found at $DMG (run build_dmg.sh first)" >&2
    exit 1
fi

echo "==> Mounting $DMG..."
MNT=$(hdiutil attach "$DMG" -nobrowse | grep /Volumes/ | awk -F'\t' '{print $NF}')
trap 'hdiutil detach "$MNT" >/dev/null 2>&1 || true' EXIT

if pgrep -x my_ghost >/dev/null 2>&1; then
    echo "==> Quitting running MyGhost (tmux sessions persist)..."
    osascript -e 'tell application "MyGhost" to quit' 2>/dev/null || pkill -x my_ghost || true
    for _ in $(seq 1 20); do
        pgrep -x my_ghost >/dev/null 2>&1 || break
        sleep 0.5
    done
    if pgrep -x my_ghost >/dev/null 2>&1; then
        echo "==> Still running, forcing..."
        pkill -9 -x my_ghost || true
        sleep 1
    fi
fi

echo "==> Installing to /Applications/MyGhost.app..."
ditto "$MNT/MyGhost.app" /Applications/MyGhost.app

echo "==> Relaunching..."
open /Applications/MyGhost.app

echo "Done. Installed $(stat -f '%Sm' /Applications/MyGhost.app/Contents/MacOS/my_ghost) build."
