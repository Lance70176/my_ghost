# ghost-agentd

The always-on service behind MyGhost's project assistants. It does three
things:

1. **Permission relay** — every Claude Code session on the Mac sends its
   permission prompts here; rules grade them L0–L3 and the ones that need a
   person become decision cards on Telegram, in MyGhost (bottom-right) and on
   the phone page. Answer on any one and the others mark the card handled.
2. **Project assistants** — one long-lived Claude per project that chats with
   you in its Telegram group and in MyGhost, keeps notes, and asks you in
   cards before anything is done: starting work, replying from a work account,
   querying a production database.
3. **Sources** — work Telegram accounts, ClickUp lists and schedules that wake
   the assistant with what changed.

Setting it up step by step: see the main [README](../README.md#ai-project-assistants--ai-專案助手).

MyGhost 專案助手背後的常駐服務，負責三件事：**權限中繼**（Claude Code 的授權請求依規則分 L0–L3，
需要人決定的變成決策卡，同時出現在 Telegram、MyGhost 右下角和手機網頁，任一邊按下其他地方同步）、
**專案助手**（每個專案一位常駐 Claude，在 TG 群組與 MyGhost 跟你對話，要動手前一律出卡問你），
以及**資料來源**（工作 TG 帳號、ClickUp、排程，有變動時叫醒助手）。
一步步的設定教學在主 [README](../README.md#ai-project-assistants--ai-專案助手)。

## Levels · 決策分級

| 等級 | 處理 | 例子 |
| --- | --- | --- |
| L0 | 直接放行，記錄並在摘要裡彙整 | 讀檔、`git status`、跑測試、改專案內的檔案 |
| L1 | 放行後通知 | `git commit`、專案設定的 `walle 發 *-test*`、按過「一律允許」的指令 |
| L2 | 發決策卡，等你按 | `git push`、`rm`、裝套件、連資料庫、未分類的指令 |
| L3 | 決策卡＋二次確認，不能設成一律允許 | 正式環境、`--force` push、`sudo`、`DROP TABLE` |

Compound commands take the highest grade of their parts. 「此專案一律允許」
only turns L2 into L1 and is stored in `projects/<name>/always_allow.json`.
Timeout (30 min by default) denies. Replying to a card on Telegram denies it
and passes your text to the conversation as the reason.

## Project assistants (P2) · 專案助手

Each project can have an Opus 5.5 assistant: one long-lived
`claude -p --input-format stream-json --output-format stream-json` per project,
run by the daemon with the project root as its cwd (`assistant.py`). Resident
projects (`resident: true`) start with the daemon; others start on the first
message and stop after 30 idle minutes. The conversation survives restarts
(`--session-id` / `--resume`), the daily 04:00 restart, and compaction: after
every turn the daemon reads `/context`, and at 80% it has the assistant write
its memory (`state.md`) and then sends `/compact`.

每個專案一個常駐的 Claude（stream-json 雙向串流）。對話存在
`projects/<name>/chat.jsonl`，助手的記憶在 `state.md`，報告在 `reports/`。

- **MyGhost**: the ✦ sidebar mode replaces the terminal area with the
  assistant — chat in the middle, pending decisions and history on the right.
  「💬 討論」 on any card switches there and hands the card to the assistant.
- **Telegram**: the commander's messages in a project group go to that
  project's assistant; its replies (and what you type in MyGhost) go back.
- **Tools** (`hooks/ghost_tools.py`, MCP over stdio): cards
  (`ask_decision`, `close_cards`; a new card can `replaces` older ones),
  memory (`read_state`, `update_state`), the project's conversations
  (`list_workers`, `read_worker_log`, `message_worker`, `reply_worker`),
  dispatch (`propose_dispatch`, `list_dispatches`, `close_worker` — the
  daily tidy-up deletes its own "XX AI - …" conversations quiet over 7 days
  once they are in its memory and not needed again), work accounts
  (`draft_reply`, `draft_dm`, `send_reply`, `read_tg_chat`, `grant_dm`…),
  `db_query` (read-only), ClickUp (`clickup_task`, `clickup_done`),
  `share_report`, `tg_send`. The assistant never edits code itself: work is
  proposed with `propose_dispatch` and starts as a new Claude Code
  conversation (in a git worktree) only when you press 開工.
- **It can't decide for you**: `ask_decision` options may carry an
  `allow`/`deny` action for the card under discussion; only your click applies
  it (L3 still needs the second confirmation). Cards are numbered per project
  and day (#1, #2…) and can be referred to by number.
- **Each assistant stays in its project**: a PreToolUse hook
  (`hooks/ghost_scope.py`) keeps file and shell access inside the project's
  folders, except in turns you started yourself (and the background work you
  started in them). Members added with `/addmember` may talk to it and press
  the cards from their own requests.

The assistant follows the host: MyGhost keeps one ghost-agentd client per
host tab. The local Mac's daemon is reached at `127.0.0.1:7788`; a remote
host's through an SSH forward (`ssh -N -L <port>:127.0.0.1:7788 <host>`, the
same ssh target and options the host tab uses), so every daemon stays
loopback-only. Switch the window to a host and ✦ shows that host's
assistants, cards and history; cards from all open hosts appear bottom-right,
labelled with their host.

助手跟著主機走：每個主機分頁各自透過 SSH 轉發連到那台的 ghost-agentd，服務
本身只綁 127.0.0.1。

(`remote.token` in `config.yaml` still makes the daemon listen beyond
loopback for clients that can't use SSH; MyGhost doesn't need it.)

## Telegram

- **Commander** — your personal TG account(s), `telegram.commander_user_ids`
  in `config.yaml`. No bot obeys anyone else.
- **Assistant** — each project has its own bot and its own group
  (`project.yaml` → `telegram.token` / `chat_id`). Don't reuse ccgram's bot:
  two processes polling one token both get 409.
- Send `/chatid` to a bot (in the group, or privately) to see the chat id and
  your user id. `/pending` re-sends open cards, `/status` lists conversations.

指揮者是你的個人 TG 帳號；每個專案的助手是一個獨立 bot，各自一個群組。

## Work accounts · 工作帳號

A work Telegram account (a real person's account the assistants watch and
answer from, after a press) is set up once in
`~/.myghost/accounts/<name>/account.yaml` and keeps one connection however
many assistants it serves. `routes` hand each message to exactly one
project, first match wins:

```yaml
routes:
  - folder: LTS          # a Telegram chat folder
    project: lts
    trigger: all
  - group: "FQ 研發群"    # a group, by title or chat id
    project: fq
  - all: true            # everything else
    project: fq
```

A chat routed in by folder or by name is assigned to that project: its
private messages reach the assistant without a grant, replies stay cards.
Whatever no route takes is only recorded (`unrouted.jsonl`: who and where).
Each project's `watch.yaml` still sets its window, auto-reply and post-to
lists; groups listed there (e.g. with `/watch`) claim their chats too.
Log in with `python -m ghost_agentd account-login <name>`.

工作帳號在 `~/.myghost/accounts/` 統一設定、只連一次線，用 `routes` 把每則訊息分給一個助手。

## Install · 安裝

```bash
agentd/install.sh             # daemon + hooks in ~/.claude/settings.json
agentd/install.sh --no-hooks  # daemon only
agentd/install.sh --uninstall
```

The daemon runs from `~/.myghost/agentd` under launchd (`com.myghost.agentd`,
log `~/.myghost/agentd.log`); restart after editing config with
`launchctl kickstart -k gui/$(id -u)/com.myghost.agentd`.

**Safe by default:** a request is held only while the project's bot or
MyGhost (polling) can show the card; otherwise the daemon declines and the
session asks in the terminal as usual. The phone page shows held cards but is
never on its own a reason to hold one, so a forgotten browser tab can't keep
prompts out of the terminal. If the daemon is down the hook
prints nothing, with the same result. Set `GHOST_AGENTD=off` in a session's
environment to bypass it entirely.

只有在專案的 bot 或 MyGhost 能顯示卡片時才攔下請求；否則服務直接退回，對話照常
在終端機詢問，不會卡住等 30 分鐘。手機網頁會顯示已攔下的卡，但不會單獨成為攔截的
理由。

## Files · 檔案

```
~/.myghost/
├─ config.yaml          # commander ids, fallback bot, port, timeouts
├─ sessions.json        # each conversation's last status (badges)
├─ agentd.log
└─ projects/<name>/
   ├─ project.yaml      # paths, resident, own bot + group, policy overrides
   ├─ always_allow.json # rules added from 「此專案一律允許」
   ├─ sources.yaml      # requirement sources (read from P3 on)
   ├─ events.jsonl      # hook events, append only
   └─ decisions.jsonl   # every decision: who, when, what (audit)
```

## API (127.0.0.1:7788)

| | |
| --- | --- |
| `POST /hook/permission` | hook payload → blocks → `{"behavior": "allow"/"deny"/"ask"}` |
| `POST /hook/event` | Notification / Stop / UserPromptSubmit / SessionEnd |
| `GET /api/state?since=N&wait=25&client=myghost` | pending cards + session status, long-polled |
| `POST /api/decisions/<id>` | `{"action": "allow"/"deny"/"always"/"confirm"/"cancel"/"discuss"/"o<N>", "message": "…"}` |
| `GET /api/assistants` | every assistant's status |
| `GET /api/assistants/<p>/chat?since=N&wait=25` | chat items, long-polled |
| `POST /api/assistants/<p>/messages` / `stop` / `start` | talk to / interrupt / wake an assistant |

POSTs need the `X-Ghost: 1` header so a web page can't approve through
localhost. The phone page reaches these through `web/server.js`
(`/api/agent/*`).

## Develop · 開發

```bash
cd agentd && uv sync && uv run pytest
```
