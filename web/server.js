// MyGhost Web — browser access to the tmux sessions behind MyGhost tabs.
//
// Runs on the Mac that owns the sessions (laptop or a remote host like a
// Mac mini) and serves a small single-page UI: sidebar tab list, xterm.js
// terminal attached over WebSocket, a file browser with upload/download,
// and the AI usage quota panel. Intended for personal use over a tailnet:
// plain HTTP guarded by a bearer token (the tailnet link itself is
// encrypted by Tailscale/WireGuard).

const http = require("http");
const https = require("https");
const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const { execFile } = require("child_process");
const { WebSocketServer } = require("ws");
const pty = require("node-pty");

const PORT = parseInt(process.env.MYGHOST_WEB_PORT || "8899", 10);
const HOST = process.env.MYGHOST_WEB_BIND || "0.0.0.0";

const APP_SUPPORT = path.join(os.homedir(), "Library/Application Support/MyGhost");
const STATE_FILE = path.join(APP_SUPPORT, "screen_sessions.json");
const WEB_TABS_FILE = path.join(APP_SUPPORT, "web_tabs.json");
const TOKEN_FILE = path.join(APP_SUPPORT, "web_token");

const TMUX = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
  .find((p) => fs.existsSync(p));
if (!TMUX) {
  console.error("tmux not found — install it with: brew install tmux");
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Auth token: generated once, shared by every client via URL ?token= which is
// then stored in a cookie so plain links keep working.

function loadToken() {
  try {
    const t = fs.readFileSync(TOKEN_FILE, "utf8").trim();
    if (t) return t;
  } catch {}
  const t = crypto.randomBytes(24).toString("hex");
  fs.mkdirSync(APP_SUPPORT, { recursive: true });
  fs.writeFileSync(TOKEN_FILE, t + "\n", { mode: 0o600 });
  return t;
}
const TOKEN = loadToken();

// MYGHOST_WEB_NO_AUTH=1 turns the token check off entirely — for networks
// where every device is trusted (a private tailnet / home LAN). Anyone who
// can reach the port then has a full shell as this user; leave auth on if
// guests ever join the network.
const NO_AUTH = process.env.MYGHOST_WEB_NO_AUTH === "1";

function requestToken(req) {
  const url = new URL(req.url, "http://x");
  if (url.searchParams.get("token")) return url.searchParams.get("token");
  const cookie = req.headers.cookie || "";
  const m = cookie.match(/(?:^|;\s*)myghost_token=([^;]+)/);
  if (m) return m[1];
  const auth = req.headers.authorization || "";
  if (auth.startsWith("Bearer ")) return auth.slice(7);
  return null;
}

function authed(req) {
  if (NO_AUTH) return true;
  const got = requestToken(req);
  if (!got || got.length !== TOKEN.length) return false;
  return crypto.timingSafeEqual(Buffer.from(got), Buffer.from(TOKEN));
}

// ---------------------------------------------------------------------------
// tmux helpers

function tmux(args) {
  return new Promise((resolve, reject) => {
    execFile(TMUX, args, { maxBuffer: 4 * 1024 * 1024 }, (err, stdout) => {
      if (err) reject(err);
      else resolve(stdout);
    });
  });
}

async function aliveSessions() {
  try {
    const out = await tmux(["list-sessions", "-F", "#{session_name}"]);
    return out.split("\n").map((s) => s.trim()).filter((s) => /^myghost/.test(s));
  } catch {
    return []; // no tmux server running
  }
}

function readJSON(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return fallback;
  }
}

// Session list = live tmux sessions, decorated with the titles/groups the
// MyGhost app saved in its state file (when this machine runs the app) and
// the titles of web-created tabs. Remote-tab entries in the state file point
// at *other* hosts and are skipped — each host serves its own sessions.
// Browser-side tab metadata: titles for web-created tabs, plus the ordering
// and grouping the browser applies on top of whatever the app saved. The
// browser can't drag-and-drop the way the app does, so order is explicit.
function readWebTabs() {
  const raw = readJSON(WEB_TABS_FILE, {});
  // Older files were a flat {session: title} map.
  if (raw && (raw.titles || raw.order || raw.groups)) {
    return {
      titles: raw.titles || {},
      order: raw.order || [],
      orderBase: raw.orderBase || [],
      groups: raw.groups || {},
    };
  }
  return { titles: raw || {}, order: [], orderBase: [], groups: {} };
}

function writeWebTabs(data) {
  fs.mkdirSync(APP_SUPPORT, { recursive: true });
  fs.writeFileSync(WEB_TABS_FILE, JSON.stringify(data));
}

async function sessionList() {
  const alive = await aliveSessions();
  const state = readJSON(STATE_FILE, { sessions: [] });
  const web = readWebTabs();
  const webTabs = web.titles;

  const meta = new Map(); // name -> {title, group}; insertion order = app order
  const walk = (entries, group) => {
    for (const s of entries || []) {
      if (s.isGroup) walk(s.children, s.groupName || s.title || "Group");
      else if (s.screenSessionName && !s.remoteTarget) {
        meta.set(s.screenSessionName, {
          title: s.customTitle || s.title || null,
          group: group || null,
        });
      }
    }
  };
  walk(state.sessions, null);

  // The app's own tab order, which the sidebar should match by default.
  const appOrder = [...meta.keys()].filter((n) => alive.includes(n));

  const sessions = alive.map((name) => {
    const m = meta.get(name);
    const isWeb = name.startsWith("myghostweb_");
    let title = (m && m.title) || webTabs[name] || null;
    if (!title) {
      // myghostr_ sessions are tabs the app opened onto this host over ssh.
      if (name.startsWith("myghostr_")) title = "ssh " + name.slice(9, 17);
      else title = name.slice(-8);
    }
    // A group set in the browser wins over the app's, so grouping done here
    // sticks; "" means explicitly ungrouped.
    let group = (m && m.group) || (isWeb ? "Web" : null);
    if (Object.prototype.hasOwnProperty.call(web.groups, name)) {
      group = web.groups[name] || null;
    }
    return { name, title, group, web: isWeb };
  });

  // Order: follow the app's tab order, so both sidebars read the same. A
  // reorder done in the browser overrides it, but only until the app itself
  // reorders — the app is authoritative, and its order having changed since
  // the override was made retires the override.
  let order = appOrder;
  if (web.order.length) {
    const baseStillCurrent =
      web.orderBase.length === appOrder.length &&
      web.orderBase.every((n, i) => n === appOrder[i]);
    if (baseStillCurrent) {
      order = web.order;
    } else {
      web.order = [];
      web.orderBase = [];
      writeWebTabs(web);
    }
  }

  // Sessions the ordering doesn't mention (web tabs, ssh tabs owned by another
  // machine's app) keep their place at the end.
  const rank = new Map(order.map((n, i) => [n, i]));
  sessions.sort((a, b) => {
    const ra = rank.has(a.name) ? rank.get(a.name) : Number.MAX_SAFE_INTEGER;
    const rb = rank.has(b.name) ? rank.get(b.name) : Number.MAX_SAFE_INTEGER;
    return ra !== rb ? ra - rb : a.name.localeCompare(b.name);
  });
  return sessions;
}

/// The app's tab order for sessions that are currently alive.
function appTabOrder(alive) {
  const state = readJSON(STATE_FILE, { sessions: [] });
  const names = [];
  const walk = (entries) => {
    for (const s of entries || []) {
      if (s.isGroup) walk(s.children);
      else if (s.screenSessionName && !s.remoteTarget) names.push(s.screenSessionName);
    }
  };
  walk(state.sessions);
  return names.filter((n) => alive.includes(n));
}

// ---------------------------------------------------------------------------
// AI usage (same endpoints the app queries), cached briefly.

function getJSON(url, headers) {
  return new Promise((resolve, reject) => {
    const req = https.get(url, { headers, timeout: 15000 }, (res) => {
      let data = "";
      res.on("data", (c) => (data += c));
      res.on("end", () => {
        if (res.statusCode < 200 || res.statusCode >= 300)
          return reject(new Error("HTTP " + res.statusCode));
        try {
          resolve(JSON.parse(data));
        } catch (e) {
          reject(e);
        }
      });
    });
    req.on("error", reject);
    req.on("timeout", () => req.destroy(new Error("timeout")));
  });
}

function claudeToken() {
  return new Promise((resolve) => {
    execFile(
      "/usr/bin/security",
      ["find-generic-password", "-w", "-s", "Claude Code-credentials"],
      (err, stdout) => {
        if (err) return resolve(null);
        try {
          resolve(JSON.parse(stdout).claudeAiOauth.accessToken || null);
        } catch {
          resolve(null);
        }
      }
    );
  });
}

async function claudeUsage() {
  const token = await claudeToken();
  if (!token) return null;
  const dict = await getJSON("https://api.anthropic.com/api/oauth/usage", {
    Authorization: `Bearer ${token}`,
    "anthropic-beta": "oauth-2025-04-20",
    "Content-Type": "application/json",
  });
  const limits = Array.isArray(dict.limits) ? dict.limits : [];
  const limitReset = (kind) => {
    const l = limits.find((x) => x.kind === kind);
    return l && l.resets_at ? l.resets_at : null;
  };
  const windows = [];
  const top = [
    ["five_hour", "5h", "session"],
    ["seven_day", "Week", "weekly_all"],
  ];
  for (const [key, label, kind] of top) {
    const v = dict[key];
    if (!v || typeof v.utilization !== "number") continue;
    windows.push({
      label,
      percent: Math.min(Math.max(v.utilization, 0), 100),
      resetsAt: v.resets_at || limitReset(kind),
    });
  }
  for (const l of limits) {
    const name = l.scope && l.scope.model && l.scope.model.display_name;
    if (!name || typeof l.percent !== "number") continue;
    windows.push({
      label: name,
      percent: Math.min(Math.max(l.percent, 0), 100),
      resetsAt: l.resets_at || null,
    });
  }
  return windows.length ? windows : null;
}

async function chatgptUsage() {
  const auth = readJSON(path.join(os.homedir(), ".codex/auth.json"), null);
  const token = auth && auth.tokens && auth.tokens.access_token;
  if (!token) return null;
  const headers = {
    Authorization: `Bearer ${token}`,
    "Content-Type": "application/json",
    "User-Agent": "codex_cli_rs",
    originator: "codex_cli_rs",
  };
  if (auth.tokens.account_id) headers["chatgpt-account-id"] = auth.tokens.account_id;
  const dict = await getJSON("https://chatgpt.com/backend-api/codex/usage", headers);
  const windows = [];
  const collect = (w, fallbackLabel) => {
    if (!w || typeof w.used_percent !== "number") return;
    const minutes =
      w.window_minutes ||
      (w.limit_window_seconds ? Math.round(w.limit_window_seconds / 60) : null);
    let label = fallbackLabel;
    if (minutes) {
      if (minutes <= 360) label = "5h";
      else if (minutes >= 10000) label = "Week";
      else label = Math.round(minutes / 60) + "h";
    }
    let resetsAt = null;
    if (typeof w.reset_at === "number") resetsAt = new Date(w.reset_at * 1000).toISOString();
    else if (typeof w.resets_at === "number") resetsAt = new Date(w.resets_at * 1000).toISOString();
    else if (typeof (w.resets_in_seconds ?? w.reset_after_seconds) === "number")
      resetsAt = new Date(Date.now() + (w.resets_in_seconds ?? w.reset_after_seconds) * 1000).toISOString();
    windows.push({ label, percent: Math.min(Math.max(w.used_percent, 0), 100), resetsAt });
  };
  if (dict.rate_limit) {
    collect(dict.rate_limit.primary_window, "5h");
    collect(dict.rate_limit.secondary_window, "Week");
  }
  return windows.length ? windows : null;
}

let aiCache = { at: 0, data: null };
async function aiUsage() {
  if (Date.now() - aiCache.at < 120000 && aiCache.data) return aiCache.data;
  const [claude, chatgpt] = await Promise.all([
    claudeUsage().catch(() => null),
    chatgptUsage().catch(() => null),
  ]);
  aiCache = { at: Date.now(), data: { claude, chatgpt } };
  return aiCache.data;
}

// ---------------------------------------------------------------------------
// File browser helpers. Paths are restricted to the home directory: the web
// UI is for grabbing/dropping work files, not for exploring the whole disk.

function safePath(p) {
  const home = os.homedir();
  const resolved = path.resolve(p || home);
  if (resolved !== home && !resolved.startsWith(home + path.sep)) return null;
  return resolved;
}

function listDir(dir) {
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  return entries
    .filter((e) => !e.name.startsWith("."))
    .map((e) => {
      let size = 0;
      try {
        size = e.isFile() ? fs.statSync(path.join(dir, e.name)).size : 0;
      } catch {}
      return { name: e.name, dir: e.isDirectory(), size };
    })
    .sort((a, b) => (a.dir !== b.dir ? (a.dir ? -1 : 1) : a.name.localeCompare(b.name)));
}

// Pick a non-clashing "name" / "1-name" / "2-name" inside dir.
function collisionFree(dir, name) {
  let p = path.join(dir, name);
  let i = 1;
  while (fs.existsSync(p)) p = path.join(dir, `${i++}-${name}`);
  return p;
}

// ---------------------------------------------------------------------------
// HTTP server

const PUBLIC = path.join(__dirname, "public");
const VENDOR = {
  "/vendor/xterm.js": "node_modules/@xterm/xterm/lib/xterm.js",
  "/vendor/xterm.css": "node_modules/@xterm/xterm/css/xterm.css",
  "/vendor/addon-fit.js": "node_modules/@xterm/addon-fit/lib/addon-fit.js",
};
const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".svg": "image/svg+xml",
};

function send(res, code, body, headers) {
  res.writeHead(code, Object.assign({ "Content-Type": "application/json" }, headers));
  res.end(typeof body === "string" ? body : JSON.stringify(body));
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  const p = url.pathname;

  // Static assets need no token; they contain nothing sensitive.
  if (p === "/" || p === "/index.html") {
    if (!authed(req)) {
      send(res, 401, "<h3>MyGhost Web</h3><p>Open the tokened URL printed by the server.</p>",
        { "Content-Type": "text/html; charset=utf-8" });
      return;
    }
    const headers = { "Content-Type": "text/html; charset=utf-8" };
    if (url.searchParams.get("token"))
      headers["Set-Cookie"] =
        `myghost_token=${url.searchParams.get("token")}; Path=/; Max-Age=31536000; SameSite=Strict`;
    send(res, 200, fs.readFileSync(path.join(PUBLIC, "index.html"), "utf8"), headers);
    return;
  }
  if (VENDOR[p]) {
    send(res, 200, fs.readFileSync(path.join(__dirname, VENDOR[p]), "utf8"),
      { "Content-Type": MIME[path.extname(p)] });
    return;
  }
  if (!p.startsWith("/api/") && fs.existsSync(path.join(PUBLIC, p.slice(1))) && !p.includes("..")) {
    send(res, 200, fs.readFileSync(path.join(PUBLIC, p.slice(1)), "utf8"),
      { "Content-Type": MIME[path.extname(p)] || "application/octet-stream" });
    return;
  }

  if (!p.startsWith("/api/")) return send(res, 404, { error: "not found" });
  if (!authed(req)) return send(res, 401, { error: "unauthorized" });

  try {
    if (p === "/api/state" && req.method === "GET") {
      return send(res, 200, {
        host: os.hostname().split(".")[0],
        home: os.homedir(),
        sessions: await sessionList(),
      });
    }

    if (p === "/api/tabs" && req.method === "POST") {
      const name = "myghostweb_" + crypto.randomBytes(4).toString("hex");
      await tmux(["new-session", "-d", "-s", name, "-c", os.homedir()]);
      const web = readWebTabs();
      web.titles[name] = "Web " + name.slice(-4);
      writeWebTabs(web);
      return send(res, 200, { name });
    }

    // Full ordering, sent by the browser after a move.
    if (p === "/api/order" && req.method === "PUT") {
      let body = "";
      for await (const c of req) body += c;
      const order = JSON.parse(body || "{}").order;
      if (!Array.isArray(order)) return send(res, 400, { error: "order must be an array" });
      const web = readWebTabs();
      web.order = order.filter((n) => typeof n === "string").slice(0, 500);
      // Remember the app order this override was made against, so a later
      // reorder in the app supersedes it instead of the two fighting.
      web.orderBase = appTabOrder(await aliveSessions());
      writeWebTabs(web);
      return send(res, 200, { ok: true });
    }

    // Group assignment: {group: "Web"} to join, {group: null} to leave.
    const groupMatch = p.match(/^\/api\/tabs\/(myghost[a-zA-Z0-9_-]+)\/group$/);
    if (groupMatch && req.method === "PUT") {
      let body = "";
      for await (const c of req) body += c;
      const raw = JSON.parse(body || "{}").group;
      const web = readWebTabs();
      web.groups[groupMatch[1]] = raw ? String(raw).slice(0, 40) : "";
      writeWebTabs(web);
      return send(res, 200, { ok: true });
    }

    const tabMatch = p.match(/^\/api\/tabs\/(myghostweb_[a-f0-9]+)$/);
    if (tabMatch && req.method === "DELETE") {
      // Only web-created tabs can be killed from the browser; the app's own
      // tabs must be closed in the app, which also updates its saved state.
      await tmux(["kill-session", "-t", tabMatch[1]]).catch(() => {});
      const web = readWebTabs();
      delete web.titles[tabMatch[1]];
      delete web.groups[tabMatch[1]];
      web.order = web.order.filter((n) => n !== tabMatch[1]);
      writeWebTabs(web);
      return send(res, 200, { ok: true });
    }
    if (tabMatch && req.method === "PATCH") {
      let body = "";
      for await (const c of req) body += c;
      const title = String(JSON.parse(body || "{}").title || "").slice(0, 60);
      if (title) {
        const web = readWebTabs();
        web.titles[tabMatch[1]] = title;
        writeWebTabs(web);
      }
      return send(res, 200, { ok: true });
    }

    if (p === "/api/files" && req.method === "GET") {
      const dir = safePath(url.searchParams.get("path"));
      if (!dir) return send(res, 400, { error: "path outside home" });
      return send(res, 200, { path: dir, entries: listDir(dir) });
    }

    if (p === "/api/download" && req.method === "GET") {
      const file = safePath(url.searchParams.get("path"));
      if (!file || !fs.existsSync(file) || fs.statSync(file).isDirectory())
        return send(res, 404, { error: "not found" });
      res.writeHead(200, {
        "Content-Type": "application/octet-stream",
        "Content-Disposition":
          `attachment; filename*=UTF-8''${encodeURIComponent(path.basename(file))}`,
        "Content-Length": fs.statSync(file).size,
      });
      fs.createReadStream(file).pipe(res);
      return;
    }

    if (p === "/api/upload" && req.method === "POST") {
      const dir = safePath(url.searchParams.get("dir"));
      const name = path.basename(url.searchParams.get("name") || "upload.bin");
      if (!dir) return send(res, 400, { error: "path outside home" });
      const dest = collisionFree(dir, name);
      const out = fs.createWriteStream(dest);
      req.pipe(out);
      await new Promise((ok, bad) => {
        out.on("finish", ok);
        out.on("error", bad);
        req.on("error", bad);
      });
      return send(res, 200, { path: dest });
    }

    if (p === "/api/ai-usage" && req.method === "GET") {
      return send(res, 200, await aiUsage());
    }

    send(res, 404, { error: "not found" });
  } catch (e) {
    send(res, 500, { error: String((e && e.message) || e) });
  }
});

// ---------------------------------------------------------------------------
// WebSocket terminal: one PTY running `tmux attach` per connection. Browser
// sends binary keystrokes and JSON control messages ({type:"resize"}).

const wss = new WebSocketServer({ server, path: "/ws" });

wss.on("connection", (ws, req) => {
  if (!authed(req)) return ws.close(4401, "unauthorized");
  const url = new URL(req.url, "http://x");
  const session = url.searchParams.get("session") || "";
  if (!/^myghost[a-zA-Z0-9_-]*$/.test(session)) return ws.close(4400, "bad session");

  const term = pty.spawn(TMUX, ["attach-session", "-t", session], {
    name: "xterm-256color",
    cols: parseInt(url.searchParams.get("cols") || "120", 10),
    rows: parseInt(url.searchParams.get("rows") || "32", 10),
    cwd: os.homedir(),
    env: Object.assign({}, process.env, { TERM: "xterm-256color", LANG: "en_US.UTF-8" }),
  });

  term.onData((d) => {
    if (ws.readyState === ws.OPEN) ws.send(d);
  });
  term.onExit(() => ws.close(1000, "detached"));

  ws.on("message", (msg, isBinary) => {
    if (!isBinary) {
      try {
        const c = JSON.parse(msg.toString());
        if (c.type === "resize" && c.cols > 0 && c.rows > 0) {
          term.resize(Math.min(c.cols, 500), Math.min(c.rows, 200));
          return;
        }
      } catch {}
      term.write(msg.toString());
      return;
    }
    term.write(msg.toString("utf8"));
  });
  ws.on("close", () => {
    try {
      term.kill();
    } catch {}
  });
});

server.listen(PORT, HOST, () => {
  const ifaces = os.networkInterfaces();
  const addrs = [];
  for (const list of Object.values(ifaces))
    for (const i of list || [])
      if (i.family === "IPv4" && !i.internal) addrs.push(i.address);
  const suffix = NO_AUTH ? "" : `/?token=${TOKEN}`;
  console.log(`MyGhost Web listening on port ${PORT}${NO_AUTH ? " (no auth)" : ""}`);
  console.log(`  local:  http://127.0.0.1:${PORT}${suffix}`);
  for (const a of addrs) console.log(`  lan:    http://${a}:${PORT}${suffix}`);
  if (!NO_AUTH) console.log(`Token file: ${TOKEN_FILE}`);
});
