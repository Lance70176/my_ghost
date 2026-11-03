# Agent status for MyGhost tabs

Shows what Codex and agy are doing on their MyGhost tab — in the sidebar and
the pane title bar — the same way any program can report it with the Program
Status Protocol (OSC 7501).

| Agent | Working | Needs you | Done |
| --- | --- | --- | --- |
| Codex | prompt sent, tool use | `PermissionRequest` (shows the tool and command) | `Stop` |
| agy | prompt sent (`PreInvocation`), tool use | — agy has no hook for permission prompts | `Stop` |

The agents' hooks run `~/.myghost/bin/myghost-status`, which writes the OSC
7501 report to the agent's tmux pane (found through `$TMUX_PANE`). MyGhost's
relay on that pane turns it into the tab's status, for local tabs and remote
tabs alike. Outside tmux it does nothing.

## Install

On every machine where the agents run (this Mac, and hosts your remote tabs
connect to):

```sh
sh agent-status/install.sh
# a remote host:
scp -r agent-status host: && ssh host 'sh agent-status/install.sh'
```

**Codex only runs hooks you have trusted.** After installing, open `codex`,
run `/hooks` and trust the `myghost-status` entries. The hook commands never
change between installs, so this is needed once per machine.

Re-running the installer is safe: it replaces its own hooks and keeps the
rest of `~/.codex/hooks.json` (a copy is left in `hooks.json.bak-myghost`).
