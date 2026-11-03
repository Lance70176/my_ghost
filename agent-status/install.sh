#!/bin/sh
# Install MyGhost's agent status hooks for Codex and agy on this machine.
#
#   sh agent-status/install.sh            # from a checkout
#   ssh host 'sh -s' < agent-status/install.sh   # not enough: needs the files
#   scp -r agent-status host: && ssh host 'sh agent-status/install.sh'
#
# - ~/.myghost/bin/myghost-status: writes OSC 7501 to the agent's tmux pane
# - Codex: adds hook groups to ~/.codex/hooks.json (keeps everything there)
# - agy:   installs the "myghost-status" plugin (PreInvocation/tool/Stop hooks)
#
# Safe to run again: existing myghost-status hooks are replaced, nothing else
# is touched. Needs perl (JSON::PP ships with it) for the Codex merge.
set -e
here=$(cd "$(dirname "$0")" && pwd)
bin="$HOME/.myghost/bin/myghost-status"

mkdir -p "$HOME/.myghost/bin"
cp "$here/myghost-status" "$bin"
chmod 755 "$bin"
echo "installed $bin"

# --- Codex -----------------------------------------------------------------
if [ -d "$HOME/.codex" ] || command -v codex >/dev/null 2>&1; then
  mkdir -p "$HOME/.codex"
  hooks="$HOME/.codex/hooks.json"
  [ -f "$hooks" ] && cp "$hooks" "$hooks.bak-myghost"
  perl "$here/merge-codex-hooks.pl" "$hooks" "$bin"
  echo "codex: hooks merged into $hooks"
  echo "codex: Codex skips new hooks until you trust them — open codex, run /hooks"
  echo "       and trust the myghost-status ones (once; reinstalling keeps them trusted)."
else
  echo "codex: not found, skipped"
fi

# --- agy ---------------------------------------------------------------------
agy_bin=
for c in agy "$HOME/.local/bin/agy"; do
  if command -v "$c" >/dev/null 2>&1; then agy_bin=$c; break; fi
done
if [ -n "$agy_bin" ]; then
  plug="$HOME/.myghost/agy-plugin/myghost-status"
  mkdir -p "$plug"
  cp "$here/agy-plugin/plugin.json" "$plug/plugin.json"
  sed "s#@BIN@#$bin#g" "$here/agy-plugin/hooks.json" > "$plug/hooks.json"
  "$agy_bin" plugin uninstall myghost-status >/dev/null 2>&1 || true
  "$agy_bin" plugin install "$plug"
  "$agy_bin" plugin enable myghost-status >/dev/null 2>&1 || true
  echo "agy: plugin myghost-status installed"
else
  echo "agy: not found, skipped"
fi
