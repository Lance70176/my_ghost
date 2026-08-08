/* MyGhost Web front-end: sidebar tabs + xterm.js terminal + file browser. */
(() => {
  const $ = (id) => document.getElementById(id);

  // Glyph for the "join to group" button: a framed plus, which reads as
  // "add into a container" next to the plain ▲▼ move controls.
  const JOIN_GLYPH = "&#8862;"; // ⊞

  // Sidebar glyphs drawn to match the app's SF Symbols: chevron.down /
  // chevron.right on a group, rectangle.stack for the group itself, and
  // the terminal icon each group member carries.
  const svg = (body, size = 13) =>
    `<svg viewBox="0 0 16 16" width="${size}" height="${size}" fill="none" ` +
    `stroke="currentColor" stroke-width="1.5" stroke-linecap="round" ` +
    `stroke-linejoin="round">${body}</svg>`;
  const ICON = {
    chevronDown: svg('<path d="M4 6.5L8 10.5l4-4"/>', 11),
    chevronRight: svg('<path d="M6.5 4l4 4-4 4"/>', 11),
    stack: svg('<rect x="2.5" y="6" width="11" height="7.5" rx="1.8"/>' +
               '<path d="M4.8 3.5h6.4"/>', 12),
    terminal: svg('<rect x="1.8" y="3.5" width="12.4" height="9" rx="2"/>' +
                  '<path d="M4.6 6.6L6.6 8l-2 1.4M8.4 9.8h3"/>', 13),
  };

  const collapsedGroups = new Set(
    JSON.parse(localStorage.getItem("myghost_collapsed_groups") || "[]"));
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

    installTouchScroll();
    if (IS_TOUCH) {
      installComposeBar();
      installScrollPad();
    }
  }

  const IS_TOUCH = window.matchMedia("(pointer: coarse)").matches;

  /// Scroll back through the session, `lines` rows at a time.
  ///
  /// Nothing here can scroll it directly. A full-screen program (Claude Code,
  /// vim) draws on the alternate screen, where neither the browser terminal
  /// nor tmux keeps any scrollback — the history exists only inside that
  /// program, which redraws as it scrolls. Asking tmux to scroll therefore
  /// moved nothing at all.
  ///
  /// What does work is what a mouse does on the desktop: hand the terminal a
  /// wheel event and let it decide. With mouse reporting on it forwards the
  /// wheel to the program, which scrolls its own view; without it, the
  /// terminal scrolls its own buffer.
  function scrollSession(lines) {
    if (!term || !lines) return;
    const screen = term.element?.querySelector(".xterm-screen") || term.element;
    if (!screen) return;
    const rect = screen.getBoundingClientRect();
    const cell = Math.max(8, rect.height / (term.rows || 24));
    screen.dispatchEvent(new WheelEvent("wheel", {
      // Positive `lines` means back through history, which is a wheel-up.
      deltaY: -lines * cell,
      deltaMode: 0,
      bubbles: true,
      cancelable: true,
      clientX: rect.left + rect.width / 2,
      clientY: rect.top + rect.height / 2,
    }));
  }

  /// Drag to scroll.
  ///
  /// Full-screen programs turn on mouse reporting, so a touch drag would
  /// otherwise reach the program as a mouse drag and move nothing. Claim
  /// clearly vertical drags; horizontal ones still reach the program.
  function installTouchScroll() {
    // Listen on the wrapper, not the terminal element: xterm owns everything
    // inside it, and the wrapper is the outermost node the gesture crosses.
    const el = $("term-wrap");
    let lastY = null;
    let carry = 0;
    let claimed = false;

    const rowHeight = () => Math.max(12, el.clientHeight / (term.rows || 24));

    el.addEventListener("touchstart", (e) => {
      if (e.touches.length !== 1) return;
      lastY = e.touches[0].clientY;
      carry = 0;
      claimed = false;
    }, { capture: true, passive: true });

    el.addEventListener("touchmove", (e) => {
      if (lastY === null || e.touches.length !== 1) return;
      const y = e.touches[0].clientY;
      carry += lastY - y;
      lastY = y;
      if (!claimed) {
        if (Math.abs(carry) < 6) return;
        claimed = true;
      }
      // Dragging up (content moves up) reveals newer output, so a downward
      // drag goes back into history — the direction a scrollbar would imply.
      const lines = Math.trunc(carry / rowHeight());
      if (lines !== 0) {
        scrollSession(-lines);
        carry -= lines * rowHeight();
      }
      e.preventDefault();
      e.stopPropagation();
    }, { capture: true, passive: false });

    const end = () => { lastY = null; claimed = false; };
    el.addEventListener("touchend", end, { capture: true, passive: true });
    el.addEventListener("touchcancel", end, { capture: true, passive: true });
  }

  /// Half-page scroll buttons pinned to the right edge on touch devices.
  /// A swipe can be claimed by whatever is running full screen; a button
  /// can't, so this is the reliable way back through the history.
  function installScrollPad() {
    const pad = $("scroll-pad");
    pad.classList.remove("hidden");
    for (const button of pad.querySelectorAll("button[data-scroll]")) {
      const step = () => {
        const page = Math.max(3, Math.floor((term.rows || 24) / 2));
        scrollSession(Number(button.dataset.scroll) * page);
      };
      // Respond on touchstart so it feels immediate, and don't let the press
      // reach the terminal underneath.
      button.addEventListener("touchstart", (e) => {
        e.preventDefault();
        e.stopPropagation();
        step();
      }, { passive: false });
      button.onclick = (e) => { e.preventDefault(); };
    }
  }

  /// A compose box for touch devices.
  ///
  /// Dictation and IME keyboards edit text in place and re-emit what they have
  /// so far, which reaches a terminal as repeated, ever-growing input (the
  /// "在在手機版本在手機版本上…" effect). Composing in a normal text field and
  /// sending the finished line avoids that entirely.
  function installComposeBar() {
    const bar = $("compose");
    const input = $("compose-input");
    bar.classList.remove("hidden");
    $("term-wrap").classList.add("with-compose");
    // Tapping the terminal shouldn't raise the system keyboard: input goes
    // through the compose box, so the terminal's own field stays quiet.
    if (term.textarea) term.textarea.setAttribute("inputmode", "none");

    const grow = () => {
      input.style.height = "auto";
      input.style.height = Math.min(input.scrollHeight, 96) + "px";
    };

    const sendRaw = (data) => {
      if (ws && ws.readyState === WebSocket.OPEN) ws.send(data);
    };

    const submit = () => {
      const text = input.value;
      if (!text) { sendRaw("\r"); return; }
      sendRaw(text + "\r");
      input.value = "";
      grow();
    };

    input.addEventListener("input", grow);
    input.addEventListener("keydown", (e) => {
      // A hardware keyboard (iPad) should still feel normal: Enter sends,
      // Shift+Enter inserts a line break.
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        submit();
      }
    });
    // Sending shouldn't reopen the keyboard either: after a line goes out the
    // next thing wanted is usually the output, not another line.
    $("compose-send").addEventListener("mousedown", (e) => e.preventDefault());
    $("compose-send").onclick = (e) => {
      e.preventDefault();
      submit();
    };

    $("compose-newline").onclick = () => {
      const at = input.selectionStart ?? input.value.length;
      input.value = input.value.slice(0, at) + "\n" + input.value.slice(at);
      input.selectionStart = input.selectionEnd = at + 1;
      grow();
      input.focus();
    };

    const KEYS = {
      esc: "\x1b",
      tab: "\t",
      ctrlc: "\x03",
      up: "\x1b[A",
      down: "\x1b[B",
      left: "\x1b[D",
      right: "\x1b[C",
      // What a real Backspace sends: the default erase character, which is
      // what readline and full-screen programs alike expect.
      back: "\x7f",
    };
    const REPEAT_DELAY = 400;
    const REPEAT_RATE = 55;

    // A finger that slides off the button never delivers its own touchend, so
    // the release has to be caught globally or a held key would repeat for
    // ever. Only one key can be down at a time, so one slot is enough.
    let releaseHeldKey = null;
    const release = () => releaseHeldKey && releaseHeldKey();
    for (const ev of ["touchend", "touchcancel", "mouseup", "blur"])
      window.addEventListener(ev, release, { passive: true });

    for (const button of bar.querySelectorAll("#compose-keys button[data-key]")) {
      const repeats = button.hasAttribute("data-repeat");
      let delayTimer = null;
      let repeatTimer = null;

      const stop = () => {
        clearTimeout(delayTimer);
        clearInterval(repeatTimer);
        delayTimer = repeatTimer = null;
        if (releaseHeldKey === stop) releaseHeldKey = null;
      };
      const press = () => {
        release();
        sendRaw(KEYS[button.dataset.key] || "");
        if (!repeats) return;
        releaseHeldKey = stop;
        delayTimer = setTimeout(() => {
          repeatTimer = setInterval(() => sendRaw(KEYS[button.dataset.key] || ""), REPEAT_RATE);
        }, REPEAT_DELAY);
      };

      // These send straight to the terminal, so they must not pull focus into
      // the compose box — pressing esc or an arrow would otherwise throw the
      // keyboard up over the screen you were trying to look at.
      button.addEventListener("touchstart", (e) => {
        e.preventDefault();
        press();
      }, { passive: false });
      button.addEventListener("mousedown", (e) => {
        e.preventDefault();
        // Touch already fired; a trackpad or hardware keyboard lands here.
        if (!IS_TOUCH) press();
      });
      button.onclick = (e) => e.preventDefault();
    }
    // Half-page jumps, for when a drag is awkward (or lands on something the
    // program wants to handle itself).
    for (const button of bar.querySelectorAll("#compose-keys button[data-scroll]")) {
      button.onclick = () => {
        const page = Math.max(3, Math.floor((term.rows || 24) / 2));
        scrollSession(Number(button.dataset.scroll) * page);
      };
    }
  }

  function attach(name) {
    ensureTerm();
    if (ws) {
      ws.onclose = null;
      ws.close();
      ws = null;
    }
    current = name;
    localStorage.setItem("myghost_last_session", name);
    $("term-empty").classList.add("hidden");
    $("term-title").textContent = sessionTitle(name);
    showScreen("term");
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
    // Walk the list in order and start a group wherever the group changes, so
    // groups sit between the tabs around them exactly as they do in the app —
    // bucketing by group instead pushed every group to the bottom.
    let openGroup = null;
    for (const s of state.sessions) {
      const group = s.group || "";
      if (group !== openGroup) {
        openGroup = group;
        if (group) {
          const label = document.createElement("div");
          label.className = "group-label";
          const collapsed = collapsedGroups.has(group);
          label.innerHTML =
            `<span class="chev">${collapsed ? ICON.chevronRight : ICON.chevronDown}</span>` +
            `<span class="gicon">${ICON.stack}</span>` +
            `<span class="gname"></span>`;
          label.querySelector(".gname").textContent = group;
          label.onclick = () => {
            if (collapsedGroups.has(group)) collapsedGroups.delete(group);
            else collapsedGroups.add(group);
            localStorage.setItem(
              "myghost_collapsed_groups", JSON.stringify([...collapsedGroups]));
            renderTabs();
          };
          list.appendChild(label);
        }
      }
      if (group && collapsedGroups.has(group)) continue;
      {
        const el = document.createElement("div");
        el.className = "tab" + (s.name === current ? " active" : "") +
          (group ? " child" : "");
        // Group members carry the app's tree line and terminal glyph; a
        // top-level tab is plain text there, same as the app.
        if (group) {
          const icon = document.createElement("span");
          icon.className = "ticon";
          icon.innerHTML = ICON.terminal;
          el.appendChild(icon);
        }
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

  /// Close the attached tab, mirroring the app's "−". On touch there is no
  /// hover, so the per-row ✕ is unreachable and this is the only way.
  $("close-tab").onclick = async () => {
    if (!current) return;
    const tab = state.sessions.find((s) => s.name === current);
    const label = tab ? tab.title : "this tab";
    if (!confirm(`Close "${label}"? Its shell and everything running in it will stop.`)) {
      return;
    }
    await api("/api/tabs/" + current, { method: "DELETE" }).catch(() => {});
    if (ws) ws.close();
    current = null;
    localStorage.removeItem("myghost_last_session");
    $("term-empty").classList.remove("hidden");
    // Nothing is attached any more, so the terminal screen has nothing to show.
    showScreen("list");
    refreshState();
  };

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

  /// Phone navigation. The stylesheet only acts on these classes under the
  /// narrow layout, so both screens stay on a desktop and the class is simply
  /// inert there — no branch needed at the call sites.
  const PHONE = window.matchMedia("(max-width: 720px)");

  function sessionTitle(name) {
    const session = state.sessions.find((s) => s.name === name);
    return (session && session.title) || name;
  }

  function showScreen(which) {
    const app = $("app");
    app.classList.toggle("nav-term", which === "term");
    app.classList.toggle("nav-list", which !== "term");
    // The terminal changed width, so tmux needs the new size.
    if (term) setTimeout(() => {
      fit.fit();
      if (ws && ws.readyState === WebSocket.OPEN)
        ws.send(JSON.stringify({ type: "resize", cols: term.cols, rows: term.rows }));
    }, 60);
  }

  $("back-to-list").onclick = () => showScreen("list");

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
  // A collapse stored from a desktop visit would hide the phone's whole list
  // screen, leaving nothing to navigate from.
  if (!PHONE.matches && localStorage.getItem("myghost_sidebar_collapsed") === "1")
    setCollapsed(true);

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

  /// The session to open on load, if any.
  ///
  /// `?tab=` names one outright — hand a phone a Home Screen shortcut with it
  /// and the page lands straight in that conversation. Otherwise reopen
  /// whatever was last attached from this browser. There is no blind "first
  /// session" fallback: attaching resizes the tmux window for every client, so
  /// it should only happen where it was asked for.
  /// A session named outright by `?tab=`, if it resolves to one.
  function deepLinkedSession() {
    const want = new URL(location.href).searchParams.get("tab");
    if (!want) return null;
    const needle = want.toLowerCase();
    return (
      state.sessions.find((s) => s.name === want) ||
      state.sessions.find((s) => (s.title || "").toLowerCase() === needle) ||
      state.sessions.find((s) => (s.title || "").toLowerCase().includes(needle)) ||
      null
    );
  }

  function preferredSession() {
    const deep = deepLinkedSession();
    if (deep) return deep.name;
    const last = localStorage.getItem("myghost_last_session");
    return last && state.sessions.some((s) => s.name === last) ? last : null;
  }

  refreshState().then(() => {
    const target = preferredSession();
    // A phone opens on the list, the way the sessions screen does in the app.
    // `?tab=` still lands straight in its session, since that link is a Home
    // Screen shortcut for one conversation and asks for it by name — the
    // distinction matters because attaching resizes the tmux window for every
    // client, so it should only happen where it was actually asked for.
    if (target && (!PHONE.matches || deepLinkedSession())) attach(target);
    else showScreen("list");
  });
  refreshAI();
  setInterval(refreshState, 5000);
  setInterval(refreshAI, 60000);
})();
