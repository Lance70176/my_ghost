#!/bin/bash
# Install MyGhost Web as a LaunchAgent so it starts at login and restarts if
# it dies. Runs in the user's GUI session — that's where the tmux server and
# keychain (for the AI usage panel) live.
#
# Usage:
#   ./install-launchd.sh              # token auth (default)
#   ./install-launchd.sh --no-auth    # no token — trusted networks only
#   ./install-launchd.sh --uninstall
set -e
cd "$(dirname "$0")"

LABEL=com.myghost.web
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM=$(id -u)

if [ "$1" = "--uninstall" ]; then
    launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "uninstalled $LABEL"
    exit 0
fi

NODE="$(command -v node || true)"
[ -z "$NODE" ] && for c in /opt/homebrew/bin/node /usr/local/bin/node; do
    [ -x "$c" ] && NODE="$c" && break
done
if [ -z "$NODE" ]; then
    echo "error: node not found — install Node.js first (brew install node)" >&2
    exit 1
fi

if [ ! -d node_modules ]; then
    echo "==> Installing dependencies..."
    npm install --no-fund --no-audit
fi
chmod +x node_modules/node-pty/prebuilds/*/spawn-helper 2>/dev/null || true

NO_AUTH=0
[ "$1" = "--no-auth" ] && NO_AUTH=1

WEB_DIR="$(pwd)"
PORT="${MYGHOST_WEB_PORT:-8899}"

# Record the location so the app's Web Access panel can find and control it.
SUPPORT="$HOME/Library/Application Support/MyGhost"
mkdir -p "$SUPPORT"
printf '%s\n' "$WEB_DIR" > "$SUPPORT/web_dir"

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$NODE</string>
        <string>$WEB_DIR/server.js</string>
    </array>
    <key>WorkingDirectory</key><string>$WEB_DIR</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <!-- launchd starts services with no locale, and tmux then replaces
             anything it can't confirm is printable ASCII with "_" — which
             mangles CJK tab names on the way out. -->
        <key>LANG</key><string>en_US.UTF-8</string>
        <key>LC_ALL</key><string>en_US.UTF-8</string>
        <key>MYGHOST_WEB_PORT</key><string>$PORT</string>
        <key>MYGHOST_WEB_NO_AUTH</key><string>$NO_AUTH</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$WEB_DIR/web.log</string>
    <key>StandardErrorPath</key><string>$WEB_DIR/web.log</string>
</dict>
</plist>
EOF

# Stop a ./start.sh --daemon instance so the port is free for the agent.
if [ -f .web.pid ] && kill "$(cat .web.pid)" 2>/dev/null; then
    echo "(stopped the old --daemon instance)"
fi
rm -f .web.pid

launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
# bootout is asynchronous: bootstrapping too soon fails, and with `set -e` the
# script would exit having left nothing loaded — the service silently gone.
for attempt in 1 2 3 4 5; do
    if launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>/dev/null; then
        break
    fi
    if [ "$attempt" = 5 ]; then
        echo "error: could not load $LABEL — run 'launchctl bootstrap gui/$UID_NUM $PLIST' to see why" >&2
        exit 1
    fi
    sleep 1
done

sleep 1
if ! launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
    echo "error: $LABEL did not stay loaded; see $WEB_DIR/web.log" >&2
    exit 1
fi
tail -5 web.log
echo "installed $LABEL (starts at login; uninstall with ./install-launchd.sh --uninstall)"
