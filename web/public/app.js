/* MyGhost Web front-end: sidebar tabs + xterm.js terminal + file browser. */
(() => {
  const $ = (id) => document.getElementById(id);

  // Glyph for the "join to group" button: a framed plus, which reads as
  // "add into a container" next to the plain ▲▼ move controls.
  const JOIN_GLYPH = "&#8862;"; // ⊞
  const api = (p, opts) => fetch(p, opts).then((r) => {
    if (!r.ok) throw new Error("HTTP " + r.status);
    return r.json();
  });

  let state = { sessions: [], host: "", home: "" };
  let current = null; // attached session name
  let ws = null;
  let term = null;
  let fit = null;

  // ------------------------------------------------------------------ terminal

  function ensureTerm() {
    if (term) return;
    term = new Terminal({
      fontFamily: "SF Mono, Cascadia Mono, Consolas, Menlo, monospace",
      fontSize: 13,
      cursorBlink: true,
      allowProposedApi: true,
      scrollback: 5000,
      theme: {
        background: "#1d2029",
        foreground: "#d8dae2",
        cursor: "#d8dae2",
        selectionBackground: "#3a4f7d88",
      },
    });
    fit = new FitAddon.FitAddon();
    term.loadAddon(fit);
    term.open($("terminal"));
    term.onData((d) => {
      if (ws && ws.readyState === WebSocket.OPEN) ws.send(d);
    });
    new ResizeObserver(() => {
      if (!term) return;
      fit.fit();
      if (ws && ws.readyState === WebSocket.OPEN)
        ws.send(JSON.stringify({ type: "resize", cols: term.cols, rows: term.rows }));
    }).observe($("term-wrap"));
  }

  function attach(name) {
    ensureTerm();
    if (ws) {
      ws.onclose = null;
      ws.close();
      ws = null;
    }
    current = name;
    $("term-empty").classList.add("hidden");
    term.clear();
    fit.fit();
    renderTabs();

    const proto = location.protocol === "https:" ? "wss" : "ws";
    const socket = new WebSocket(
      `${proto}://${location.host}/ws?session=${encodeURIComponent(name)}` +
        `&cols=${term.cols}&rows=${term.rows}`
    );
    socket.binaryType = "arraybuffer";
    socket.onmessage = (e) => {
      term.write(typeof e.data === "string" ? e.data : new Uint8Array(e.data));
    };
    socket.onclose = () => {
      if (current === name) term.write("\r\n\x1b[90m[disconnected — click the tab to reattach]\x1b[0m\r\n");
    };
    ws = socket;
    term.focus();
  }

  // ------------------------------------------------------------------ sidebar

  async function refreshState() {
    try {
      state = await api("/api/state");
      $("host-name").textContent = state.host;
      renderTabs();
    } catch {}
  }

  function renderTabs() {
    const list = $("tab-list");
    list.innerHTML = "";
    const groups = new Map();
    for (const s of state.sessions) {
      const key = s.group || "";
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(s);
    }
    const ordered = [...groups.entries()].sort((a, b) => {
      if (a[0] === "") return -1;
      if (b[0] === "") return 1;
      return a[0].localeCompare(b[0]);
    });
    for (const [group, sessions] of ordered) {
      if (group) {
        const label = document.createElement("div");
        label.className = "group-label";
        label.textContent = group;
        list.appendChild(label);
      }
      for (const s of sessions) {
        const el = document.createElement("div");
        el.className = "tab" + (s.name === current ? " active" : "");
        const title = document.createElement("span");
        title.className = "title";
        title.textContent = s.title;
        el.appendChild(title);
        if (s.name.startsWith("myghostr_")) {
          const b = document.createElement("span");
          b.className = "badge";
          b.textContent = "app·ssh";
          el.appendChild(b);
        }

        // Reorder controls: the browser can't drag rows the way the app can,
        // so each row carries explicit move buttons. Moving swaps with the
        // neighbour in the same group, then the whole order is saved.
        const tools = document.createElement("span");
        tools.className = "tools";
        const mkBtn = (label, cls, help, fn) => {
          const b = document.createElement("button");
          b.className = cls;
          b.innerHTML = label;
          b.title = help;
          b.onclick = (ev) => { ev.stopPropagation(); fn(); };
          return b;
        };
        tools.appendChild(mkBtn("&#9650;", "move", "Move up", () => move(s, -1)));
        tools.appendChild(mkBtn("&#9660;", "move", "Move down", () => move(s, 1)));
        tools.appendChild(mkBtn(JOIN_GLYPH, "join", "Join to a group", () => joinTo(s)));
        el.appendChild(tools);
        if (s.web) {
          const close = document.createElement("button");
          close.className = "close";
          close.textContent = "✕";
          close.title = "Close this web tab (kills its shell)";
          close.onclick = async (ev) => {
            ev.stopPropagation();
            if (!confirm(`Close ${s.title}? Its shell will be killed.`)) return;
            await api("/api/tabs/" + s.name, { method: "DELETE" });
            if (current === s.name && ws) ws.close();
            refreshState();
          };
          el.appendChild(close);
          title.ondblclick = async () => {
            const t = prompt("Rename tab", s.title);
            if (!t) return;
            await api("/api/tabs/" + s.name, {
              method: "PATCH",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ title: t }),
            });
            refreshState();
          };
        }
        el.onclick = () => attach(s.name);
        list.appendChild(el);
      }
    }
  }

  // Move `s` one slot within its own group and persist the full order.
  async function move(s, delta) {
    const all = state.sessions;
    const sameGroup = all.filter((x) => (x.group || "") === (s.group || ""));
    const at = sameGroup.findIndex((x) => x.name === s.name);
    const swapWith = sameGroup[at + delta];
    if (!swapWith) return;
    const names = all.map((x) => x.name);
    const i = names.indexOf(s.name);
    const j = names.indexOf(swapWith.name);
    names[i] = swapWith.name;
    names[j] = s.name;
    // Reflect immediately, then save; the poll will confirm.
    const byName = new Map(all.map((x) => [x.name, x]));
    state.sessions = names.map((n) => byName.get(n));
    renderTabs();
    await fetch("/api/order", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ order: names }),
    });
  }

  // Put a tab into a group (or take it out). Groups are a browser-side label;
  // the app's own grouping is left untouched.
  async function joinTo(s) {
    const existing = [...new Set(state.sessions.map((x) => x.group).filter(Boolean))];
    const hint = existing.length
      ? `Existing groups: ${existing.join(", ")}`
      : "No groups yet — type a name to create one";
    const name = prompt(`Join "${s.title}" to which group?\n${hint}\n(leave empty to ungroup)`,
      s.group || "");
    if (name === null) return;
    await fetch(`/api/tabs/${s.name}/group`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ group: name.trim() }),
    });
    refreshState();
  }

  $("new-tab").onclick = async () => {
    const { name } = await api("/api/tabs", { method: "POST" });
    await refreshState();
    attach(name);
  };

  // ------------------------------------------------------------------ AI usage

  function barColor(p) {
    if (p < 50) return "#78c87c";
    if (p < 80) return "#e0c04e";
    if (p < 90) return "#e09a4e";
    return "#e06c75";
  }

  function fmtReset(iso) {
    if (!iso) return "";
    const d = new Date(iso);
    const now = new Date();
    const sec = Math.max(0, (d - now) / 1000);
    const days = Math.floor(sec / 86400);
    const hrs = Math.floor((sec % 86400) / 3600);
    const min = Math.floor((sec % 3600) / 60);
    const count = days > 0 ? `in ${days}d ${hrs}h` : hrs > 0 ? `in ${hrs}h ${String(min).padStart(2, "0")}m` : `in ${min}m`;
    const sameDay = d.toDateString() === now.toDateString();
    const time = sameDay
      ? d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
      : d.toLocaleString([], { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" });
    return `<span class="time">${time}</span> <span class="count">${count}</span>`;
  }

  async function refreshAI() {
    let data;
    try {
      data = await api("/api/ai-usage");
    } catch {
      return;
    }
    const body = $("ai-body");
    body.innerHTML = "";
    const accounts = [
      ["Claude Code", data.claude],
      ["ChatGPT", data.chatgpt],
    ];
    for (const [name, windows] of accounts) {
      if (!windows) continue;
      const acct = document.createElement("div");
      acct.className = "ai-account";
      acct.innerHTML = `<div class="ai-name">${name}</div>`;
      for (const w of windows) {
        const row = document.createElement("div");
        row.className = "ai-row";
        row.innerHTML =
          `<span class="ai-label">${w.label}</span>` +
          `<span class="ai-bar"><span class="ai-fill" style="width:${w.percent}%;background:${barColor(w.percent)}"></span></span>` +
          `<span class="ai-pct">${Math.round(w.percent)}%</span>`;
        const reset = document.createElement("div");
        reset.className = "ai-reset";
        reset.innerHTML = fmtReset(w.resetsAt);
        acct.appendChild(row);
        if (reset.innerHTML) acct.appendChild(reset);
      }
      body.appendChild(acct);
    }
  }

  // ------------------------------------------------------------------ files

  let cwd = null;

  async function loadDir(p) {
    const data = await api("/api/files?path=" + encodeURIComponent(p || ""));
    cwd = data.path;
    const crumbs = $("crumbs");
    crumbs.innerHTML = "";
    const home = state.home || "";
    const rel = cwd.startsWith(home) ? cwd.slice(home.length) : cwd;
    const parts = rel.split("/").filter(Boolean);
    const rootLink = document.createElement("a");
    rootLink.textContent = "~";
    rootLink.onclick = () => loadDir(home);
    crumbs.appendChild(rootLink);
    let acc = home;
    for (const part of parts) {
      acc += "/" + part;
      const sep = document.createElement("span");
      sep.className = "sep";
      sep.textContent = "/";
      crumbs.appendChild(sep);
      const a = document.createElement("a");
      a.textContent = part;
      const target = acc;
      a.onclick = () => loadDir(target);
      crumbs.appendChild(a);
    }

    const list = $("file-list");
    list.innerHTML = "";
    for (const e of data.entries) {
      const el = document.createElement("div");
      el.className = "file";
      const size = e.dir ? "" : e.size > 1048576
        ? (e.size / 1048576).toFixed(1) + " MB"
        : e.size > 1024 ? (e.size / 1024).toFixed(0) + " KB" : e.size + " B";
      el.innerHTML = `<span>${e.dir ? "📁" : "📄"}</span>` +
        `<span class="title">${e.name}</span><span class="size">${size}</span>`;
      el.onclick = () => {
        if (e.dir) loadDir(cwd + "/" + e.name);
        else window.open(`/api/download?path=${encodeURIComponent(cwd + "/" + e.name)}`, "_blank");
      };
      list.appendChild(el);
    }
  }

  $("upload-input").onchange = async (ev) => {
    for (const file of ev.target.files) {
      await fetch(
        `/api/upload?dir=${encodeURIComponent(cwd)}&name=${encodeURIComponent(file.name)}`,
        { method: "POST", body: file }
      );
    }
    ev.target.value = "";
    loadDir(cwd);
  };

  // ------------------------------------------------------------------ modes

  function setCollapsed(collapsed) {
    $("sidebar").classList.toggle("collapsed", collapsed);
    $("expand-sidebar").classList.toggle("hidden", !collapsed);
    localStorage.setItem("myghost_sidebar_collapsed", collapsed ? "1" : "0");
    if (term) setTimeout(() => {
      fit.fit();
      if (ws && ws.readyState === WebSocket.OPEN)
        ws.send(JSON.stringify({ type: "resize", cols: term.cols, rows: term.rows }));
    }, 60);
  }
  $("collapse-sidebar").onclick = () => setCollapsed(true);
  $("expand-sidebar").onclick = () => setCollapsed(false);
  if (localStorage.getItem("myghost_sidebar_collapsed") === "1") setCollapsed(true);

  $("mode-term").onclick = () => setMode("term");
  $("mode-files").onclick = () => setMode("files");
  function setMode(m) {
    $("mode-term").classList.toggle("active", m === "term");
    $("mode-files").classList.toggle("active", m === "files");
    $("tab-pane").classList.toggle("hidden", m !== "term");
    $("file-pane").classList.toggle("hidden", m !== "files");
    if (m === "files" && cwd === null) loadDir("");
  }

  // ------------------------------------------------------------------ boot

  // No auto-attach: attaching resizes the tmux window for every client, so
  // grabbing a session the desktop app is showing should be a deliberate act.
  refreshState();
  refreshAI();
  setInterval(refreshState, 5000);
  setInterval(refreshAI, 60000);
})();
