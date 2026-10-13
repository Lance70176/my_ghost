#!/bin/bash
# Install ghost-agentd for the current user:
#   - copies the daemon to ~/.myghost/agentd (outside the git checkout, like web/)
#   - creates its venv, a config template and the two resident projects (fq, lts)
#   - registers a launchd agent (com.myghost.agentd) that keeps it running
#   - adds the hooks to ~/.claude/settings.json (every Claude Code session)
#
#   ./install.sh               install / update
#   ./install.sh --no-hooks    install the daemon only
#   ./install.sh --uninstall   remove the launchd agent and the hooks
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="${MYGHOST_HOME:-$HOME/.myghost}"
DEST="$HOME_DIR/agentd"
LABEL=com.myghost.agentd
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SETTINGS="$HOME/.claude/settings.json"
HOOK="$DEST/hooks/ghost-hook.py"

edit_hooks() { # $1 = add | remove
  /usr/bin/python3 - "$1" "$SETTINGS" "$HOOK" <<'PY'
import json, os, sys
mode, path, hook = sys.argv[1:4]
s = json.load(open(path)) if os.path.exists(path) else {}
hooks = s.setdefault("hooks", {})
cmd = f"/usr/bin/python3 {hook}"
mine = lambda h: "ghost-hook.py" in h.get("command", "")
for ev in list(hooks):
    groups = []
    for g in hooks[ev]:
        g["hooks"] = [h for h in g.get("hooks", []) if not mine(h)]
        if g["hooks"]:
            groups.append(g)
    hooks[ev] = groups
if mode == "add":
    hooks.setdefault("PermissionRequest", []).append(
        {"hooks": [{"type": "command", "command": cmd, "timeout": 1860}]})
    for ev in ("Notification", "Stop", "UserPromptSubmit", "SessionEnd"):
        hooks.setdefault(ev, []).append(
            {"hooks": [{"type": "command", "command": cmd, "timeout": 5, "async": True}]})
for ev in [e for e, g in hooks.items() if not g]:
    del hooks[ev]
tmp = path + ".ghost.tmp"
with open(tmp, "w") as f:
    json.dump(s, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, path)
print(f"hooks {'added to' if mode == 'add' else 'removed from'} {path}")
PY
}

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  [[ -f "$SETTINGS" ]] && edit_hooks remove
  echo "uninstalled (config and logs kept in $HOME_DIR)"
  exit 0
fi

mkdir -p "$DEST" "$HOME_DIR/projects/fq" "$HOME_DIR/projects/lts" "$HOME/Library/LaunchAgents"
rsync -a --delete --exclude .venv --exclude __pycache__ --exclude .pytest_cache \
  --exclude tests --exclude uv.lock "$SRC/" "$DEST/"
(cd "$DEST" && uv sync -q --no-dev)
chmod +x "$HOOK"

if [[ ! -f "$HOME_DIR/config.yaml" ]]; then
  cat > "$HOME_DIR/config.yaml" <<'YAML'
# ghost-agentd settings. Restart after editing:
#   launchctl kickstart -k gui/$(id -u)/com.myghost.agentd
telegram:
  # Your personal TG account(s): the only ones any assistant bot obeys.
  # Send /chatid to a bot to see your user_id.
  commander_user_ids: []
  # Optional fallback bot for sessions outside every project (NOT ccgram's).
  token: ""
  chat_id:
port: 7788
decision_timeout: 1800 # seconds; then deny
digest_seconds: 60     # batch "L0/L1 allowed" notices this long
digest_l0: true
notify_idle: false
YAML
  chmod 600 "$HOME_DIR/config.yaml"
fi

for NAME in fq lts; do
  [[ -f "$HOME_DIR/projects/$NAME/project.yaml" ]] && continue
  cat > "$HOME_DIR/projects/$NAME/project.yaml" <<YAML
name: $NAME
paths:
  - $HOME/projects/$NAME  # every repo below this folder belongs to $NAME
resident: true            # assistant kept running (P2); others wake on events
telegram:
  token: ""               # this project's own assistant bot (@BotFather)
  chat_id:                # this project's group: add the bot, send /chatid
policy:
  # Globs on the whole command. allow = L2 -> L1, deny = always ask,
  # l0 / l1 = extra silent / notify-after rules, l3 = regex, double confirm.
  allow: []
  deny: []
  l0: []
  l1:
    - "walle 發 *-test*"
  l3:
    - 'bc-pay.*\b(INSERT|UPDATE|DELETE)\b'
YAML
  chmod 600 "$HOME_DIR/projects/$NAME/project.yaml"
done

# Requirement sources are read from P3 on; written now so the decisions made
# in the plan are on file.
if [[ ! -f "$HOME_DIR/projects/lts/sources.yaml" ]]; then
  cat > "$HOME_DIR/projects/lts/sources.yaml" <<'YAML'
- type: clickup
  name: "LTS 後台需求"
  list: ["LSC 後台", "LSA 後台"]
  filter: { status: ["待開發", "開發中", "待補資料"], assignee: me }
  schedule: "weekday 09:00,14:00"
  on_new: plan-then-ask        # new ticket: plan HTML first, you press 開工
  on_done: writeback           # the assistant updates the ticket itself (L1, tells you after)
  done_status: "已驗收"
  match_workers: "【LS[AC]】|#\\d+"
- type: gitlab
  name: "LTS MR"
  projects: [base, platform, scheduler, admin]
  watch: [mr_review_requested, pipeline_failed]
  schedule: every 30m
  on_new: notify
YAML
fi

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$DEST/.venv/bin/python</string>
    <string>-m</string>
    <string>ghost_agentd</string>
  </array>
  <key>WorkingDirectory</key><string>$DEST</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>MYGHOST_HOME</key><string>$HOME_DIR</string>
    <key>PYTHONUNBUFFERED</key><string>1</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME_DIR/agentd.log</string>
  <key>StandardErrorPath</key><string>$HOME_DIR/agentd.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "daemon: $LABEL started (log: $HOME_DIR/agentd.log)"

if [[ "${1:-}" != "--no-hooks" ]]; then
  edit_hooks add
fi

sleep 1
curl -s --max-time 2 http://127.0.0.1:7788/api/health && echo
(cd "$DEST" && MYGHOST_HOME="$HOME_DIR" .venv/bin/python -m ghost_agentd check)
