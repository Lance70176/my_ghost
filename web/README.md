# MyGhost Web

Browser access to the tmux sessions behind MyGhost's tabs — use your terminal
workspace from **Windows, Linux, iPad, or any machine with a browser**. The
server runs on the Mac that owns the sessions; the browser gets the sidebar tab
list (same titles and groups as the app), an xterm.js terminal, a file browser
with upload/download, and the AI usage panel.

從瀏覽器操作 MyGhost 分頁背後的 tmux session——**Windows、Linux、iPad 或任何有
瀏覽器的裝置**都能使用。伺服器跑在持有 session 的那台 Mac 上；瀏覽器端有側欄分
頁清單（標題與分組跟 App 一致）、xterm.js 終端機、可上傳下載的檔案瀏覽器，以及
AI 額度面板。

## Start · 啟動

Run it from a copy **outside** the git checkout — `npm install`, logs and the
pid file would otherwise show up as changes and block `git pull`:

請從 git checkout **之外**的副本執行——否則 `npm install`、log 與 pid 檔會變成
未提交的變更，讓 `git pull` 被擋下：

```bash
rsync -a --exclude node_modules web/ ~/myghost-web/
cd ~/myghost-web && ./install-launchd.sh --no-auth
```

```bash
cd web                  # or ~/myghost-web
./start.sh              # foreground（第一次會自動 npm install）
./start.sh --daemon     # background，log 寫到 web.log
./start.sh --stop       # stop the daemon

# Start at login and keep alive (launchd) · 開機自動啟動
./install-launchd.sh              # with token auth
./install-launchd.sh --no-auth    # no token — trusted networks only
./install-launchd.sh --uninstall
```

`--no-auth` skips the token entirely; anyone who can reach the port gets a
shell as your user, so only use it on a fully trusted network (private
tailnet / home LAN with no guests).
`--no-auth` 會完全關閉 token 驗證；能連上這個 port 的人就等於拿到你的 shell，
請只在完全信任的網路（私人 tailnet／無訪客的家用網路）使用。

The server prints a tokened URL like
`http://<ip>:8899/?token=…` — open it from any browser. The token is stored in
`~/Library/Application Support/MyGhost/web_token` and set as a cookie on first
visit, so later visits to the plain URL keep working.

啟動後會印出帶 token 的網址（`http://<ip>:8899/?token=…`），用任何瀏覽器開啟即
可。token 存在 `~/Library/Application Support/MyGhost/web_token`，首次造訪後寫入
cookie，之後開純網址也能用。

## Notes · 注意事項

- Intended for use over **Tailscale / a private LAN**: the link layer provides
  the encryption; the server itself is plain HTTP guarded by the token.
  建議走 **Tailscale 或內網**使用：加密由網路層提供，伺服器本身是 HTTP＋token。
- Attaching a session from the browser resizes it for every attached client
  (plain tmux behavior) — the desktop app window shows the same size until it
  is resized again. 瀏覽器附掛 session 會改變該 session 的尺寸（tmux 的行為），
  桌面 App 那邊看到的尺寸會跟著變，重新調整視窗即可恢復。
- "＋" creates browser-owned tabs (`myghostweb_…`); only these can be closed
  from the browser. The app's own tabs must be closed in the app.
  「＋」建立的是瀏覽器自己的分頁（`myghostweb_…`），也只有這些能在瀏覽器關閉；
  App 的分頁請回到 App 關。
- The file browser is scoped to the home directory.
  檔案瀏覽器僅限家目錄範圍。
- Run the same server on each host you care about (e.g. laptop **and** the
  Mac mini) — each serves its own sessions.
  每台主機（例如筆電和 Mac mini）各跑一份伺服器，各自服務自己的 session。

Requirements · 需求：Node.js 18+、tmux、macOS（Xcode CLT for the native PTY
module）。Port 可用 `MYGHOST_WEB_PORT` 覆寫（預設 8899）。
