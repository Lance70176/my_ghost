# ghost-agentd

The always-on, no-LLM service behind MyGhost's project assistants. Phase 1
(this directory today) is the **permission relay**: every Claude Code session
on the Mac sends its permission prompts here, the rules grade them L0–L3, and
the ones that need a person become decision cards on Telegram, in MyGhost
(bottom-right) and on the phone page — answer on any one and the others mark
the card handled.

MyGhost 專案助手背後的常駐服務（不呼叫 LLM）。目前完成的是 **P1 權限中繼**：
這台 Mac 上所有 Claude Code 對話的授權請求都送到這裡，先用規則分成 L0–L3，
需要人決定的就變成決策卡，同時出現在 Telegram、MyGhost 右下角和手機網頁；
任一邊按下後，其他地方的卡片會同步變成「已處理」。

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

## Telegram

- **Commander** — your personal TG account(s), `telegram.commander_user_ids`
  in `config.yaml`. No bot obeys anyone else.
- **Assistant** — each project has its own bot and its own group
  (`project.yaml` → `telegram.token` / `chat_id`). Don't reuse ccgram's bot:
  two processes polling one token both get 409.
- Send `/chatid` to a bot (in the group, or privately) to see the chat id and
  your user id. `/pending` re-sends open cards, `/status` lists conversations.

指揮者是你的個人 TG 帳號；每個專案的助手是一個獨立 bot，各自一個群組。

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
| `POST /api/decisions/<id>` | `{"action": "allow"/"deny"/"always"/"confirm"/"cancel", "message": "…"}` |

POSTs need the `X-Ghost: 1` header so a web page can't approve through
localhost. The phone page reaches these through `web/server.js`
(`/api/agent/*`).

## Develop · 開發

```bash
cd agentd && uv sync && uv run pytest
```
