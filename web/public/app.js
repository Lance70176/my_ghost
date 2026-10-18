/* MyGhost Web front-end: sidebar tabs + xterm.js terminal + project assistants. */
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
  // ghost-agentd: pending decisions and each Claude session's status, keyed
  // by the tmux session the conversation runs in.
  let agent = { pending: [], sessions: [] };
  let agentStatus = new Map();
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
    current = name;
    localStorage.setItem("myghost_last_session", name);
    $("term-empty").classList.add("hidden");
    $("term-title").textContent = sessionTitle(name);
    showScreen("term");
    term.clear();
    fit.fit();
    renderTabs();
    retryDelay = RETRY_MIN;
    connect();
    term.focus();
  }

  // Reconnection. A phone drops the socket whenever the screen locks or the
  // browser goes to the background, and coming back used to leave a dead
  // terminal until the tab was opened again. Now a closed socket retries on
  // its own, and returning to the page reattaches straight away. A socket
  // that slept for a while is replaced even if it still claims to be open:
  // iOS hands those back half-dead, never delivering another byte or close.
  const RETRY_MIN = 1000;
  const RETRY_MAX = 15000;
  const STALE_AFTER = 15000; // ms in the background before a socket is distrusted
  let retryDelay = RETRY_MIN;
  let retryTimer = null;
  let hiddenAt = 0;
  let reconnectNoted = false;

  function dropSocket() {
    clearTimeout(retryTimer);
    retryTimer = null;
    if (!ws) return;
    ws.onclose = ws.onmessage = ws.onopen = null;
    try { ws.close(); } catch {}
    ws = null;
  }

  function connect() {
    dropSocket();
    const name = current;
    if (!name) return;
    fit.fit();
    const proto = location.protocol === "https:" ? "wss" : "ws";
    const socket = new WebSocket(
      `${proto}://${location.host}/ws?session=${encodeURIComponent(name)}` +
        `&cols=${term.cols}&rows=${term.rows}`
    );
    socket.binaryType = "arraybuffer";
    socket.onopen = () => {
      retryDelay = RETRY_MIN;
      reconnectNoted = false;
    };
    socket.onmessage = (e) => {
      term.write(typeof e.data === "string" ? e.data : new Uint8Array(e.data));
    };
    socket.onclose = (e) => {
      if (ws !== socket) return;
      ws = null;
      if (current !== name) return;
      const gone =
        e.code === 4400 || e.code === 4401 ||
        (state.sessions.length && !state.sessions.some((s) => s.name === name));
      if (gone) {
        term.write("\r\n\x1b[90m[disconnected — click the tab to reattach]\x1b[0m\r\n");
        return;
      }
      if (!reconnectNoted) {
        reconnectNoted = true;
        term.write("\r\n\x1b[90m[connection lost — reconnecting…]\x1b[0m\r\n");
      }
      // In the background the retry waits for the page to come back (below);
      // timers barely run there anyway.
      if (!document.hidden) scheduleRetry();
    };
    ws = socket;
  }

  function scheduleRetry() {
    clearTimeout(retryTimer);
    retryTimer = setTimeout(connect, retryDelay);
    retryDelay = Math.min(retryDelay * 2, RETRY_MAX);
  }

  function resume() {
    if (!current || !term) return;
    const away = hiddenAt ? Date.now() - hiddenAt : 0;
    hiddenAt = 0;
    if (!ws || ws.readyState !== WebSocket.OPEN || away > STALE_AFTER) {
      retryDelay = RETRY_MIN;
      connect();
    }
  }

  document.addEventListener("visibilitychange", () => {
    if (document.hidden) hiddenAt = Date.now();
    else resume();
  });
  window.addEventListener("pageshow", (e) => { if (e.persisted) resume(); });
  window.addEventListener("online", resume);

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
    // This Mac's own tabs and the ones from elsewhere sit under their own
    // heading, even when only one kind is present, so it's always clear which
    // is which.
    let openSection = null;
    for (const s of state.sessions) {
      if (s.sectionKey !== openSection) {
        openSection = s.sectionKey;
        openGroup = null;
        const head = document.createElement("div");
        head.className = "section-label";
        head.textContent = s.section;
        list.appendChild(head);
      }
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
        const st = agentStatus.get(s.name);
        if (st) {
          const b = document.createElement("span");
          b.className = "status " + st;
          b.textContent = { waiting: "等你", running: "執行中", done: "✓" }[st] || "";
          el.appendChild(b);
        }
        if (s.name.startsWith("myghostr_")) {
          // Other Macs' tabs share one section, so each names the Mac it
          // came from.
          const b = document.createElement("span");
          b.className = "badge";
          b.textContent = s.device || "app·ssh";
          b.title = s.device ? `${s.device} 透過 ssh 開的分頁` : "另一台 Mac 透過 ssh 開的分頁";
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
    // Tabs move among their own app's tabs; a section is never crossed.
    const sameGroup = all.filter((x) =>
      (x.group || "") === (s.group || "") && x.sectionKey === s.sectionKey);
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
    dropSocket();
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

  // ------------------------------------------------------------------ decisions

  const LEVEL_CLASS = { L0: "l0", L1: "l1", L2: "l2", L3: "l3" };

  async function refreshAgent() {
    let data;
    try {
      data = await api("/api/agent/state");
    } catch {
      return;
    }
    agent = data;
    const next = new Map();
    // Oldest first, so a tab's freshest conversation decides its badge.
    for (const s of [...(data.sessions || [])].reverse())
      if (s.tmux_session && s.status !== "ended") next.set(s.tmux_session, s.status);
    const changed = JSON.stringify([...next]) !== JSON.stringify([...agentStatus]);
    agentStatus = next;
    if (changed) renderTabs();
    renderDecisions();
    agentChanged();
  }

  async function decide(p, action, message) {
    try {
      const r = await fetch("/api/agent/decisions/" + p.id, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action, message: message || "" }),
      });
      const j = await r.json();
      if (!r.ok && j.message) alert(j.message);
    } catch {}
    refreshAgent();
  }

  const leftText = (p) =>
    p.discussing ? "💬 討論中，不會逾時" : Math.ceil(p.remaining / 60) + " 分鐘後逾時並拒絕";

  // Cards folded away by tapping the heading, by id: folded while every
  // waiting card is one of them, so a new card opens the list again.
  let foldedCards = new Set();
  try {
    foldedCards = new Set(JSON.parse(localStorage.getItem("myghost_folded_decisions") || "[]"));
  } catch {}

  function foldDecisions(fold) {
    const ids = fold ? (agent.pending || []).map((p) => p.id) : [];
    foldedCards = new Set(ids);
    try {
      localStorage.setItem("myghost_folded_decisions", JSON.stringify(ids));
    } catch {}
    paintFold();
  }

  function paintFold() {
    const box = $("decisions");
    const pending = agent.pending || [];
    const folded = pending.length > 0 && pending.every((p) => foldedCards.has(p.id));
    box.classList.toggle("folded", folded);
    const head = box.querySelector(".dec-head");
    if (head) head.textContent = `${folded ? "▸" : "▾"} 🔐 待決策 ${pending.length}`;
  }

  function renderDecisions() {
    const box = $("decisions");
    const pending = agent.pending || [];
    box.classList.toggle("hidden", pending.length === 0);
    paintFold();
    // Don't rebuild under a finger: only re-render when the set changed.
    const sig = pending.map((p) => p.id + p.state + (p.discussing ? "d" : "")).join(",");
    if (box.dataset.sig === sig) {
      for (const p of pending) {
        const t = box.querySelector(`[data-left="${p.id}"]`);
        if (t) t.textContent = leftText(p);
      }
      return;
    }
    box.dataset.sig = sig;
    box.innerHTML = `<button class="dec-head" type="button" title="收合／展開"></button>`;
    box.querySelector(".dec-head").onclick = () => foldDecisions(!box.classList.contains("folded"));
    paintFold();
    for (const p of pending) box.appendChild(buildPendingCard(p));
  }

  /// A waiting decision with its buttons. `full` shows a long request whole
  /// instead of in a scrolling box — the decision's own page has the room.
  function buildPendingCard(p, full) {
    const card = document.createElement("div");
    card.className = "dec-card " + (LEVEL_CLASS[p.level_name] || "");
    const head = document.createElement("div");
    head.className = "dec-meta";
    head.innerHTML = `<span class="lv"></span> <span class="who"></span>`;
    head.querySelector(".lv").textContent = p.level_name;
    head.querySelector(".who").textContent =
      `${p.project} · ${p.tab_title || (p.session_id || "").slice(0, 8)}`;
    let cmd = document.createElement("pre");
    cmd.className = "dec-cmd";
    if (full) cmd.style.maxHeight = "none";
    cmd.textContent = p.summary;
    // A work-account reply reads as who wrote what and what would go back.
    if (p.reply) cmd = replyBlock(p.reply, `將以 ${p.reply.account} 送出`, false);
    const why = document.createElement("div");
    why.className = "dec-why";
    why.textContent = p.reason + (p.level_name === "L3" ? " · 需要二次確認" : "");
    const left = document.createElement("div");
    left.className = "dec-left";
    left.dataset.left = p.id;
    left.textContent = leftText(p);
    const btns = document.createElement("div");
    btns.className = "dec-btns";
    const b = (label, cls, fn) => {
      const el = document.createElement("button");
      el.className = cls;
      el.textContent = label;
      el.onclick = fn;
      btns.appendChild(el);
    };
    if (p.kind === "choice") {
      why.textContent = p.reply ? p.reason || "回覆外部訊息" : "助手的選擇題";
      left.textContent = "";
      (p.options || []).forEach((o, i) =>
        b(o.label, o.action === "deny" ? "no" : "ok", () => decide(p, "o" + i)));
      b("略過", "", () => decide(p, "deny"));
      card.append(head, cmd, why, btns);
      return card;
    }
    if (p.state === "confirming") {
      b("⚠️ 確定同意", "ok", () => decide(p, "confirm"));
      b("取消", "", () => decide(p, "cancel"));
    } else {
      b(p.level_name === "L3" ? "同意（需再確認）" : "同意", "ok", () => decide(p, "allow"));
    }
    b("拒絕", "no", () => decide(p, "deny"));
    b("附理由拒絕…", "no", () => {
      const why = prompt("拒絕理由（會轉給對話）");
      if (why !== null) decide(p, "deny", why);
    });
    if (!p.discussing) b("💬 討論（不逾時）", "", () => decide(p, "discuss"));
    if (p.can_always) b("此專案一律允許 " + p.always_pattern, "always", () => decide(p, "always"));
    card.append(head, cmd, why, left, btns);
    return card;
  }

  /// "X 說" with the original message, then the drafted reply under a line
  /// saying what became of it.
  function replyBlock(r, outcome, sent) {
    const wrap = document.createElement("div");
    const el = (cls, text) => {
      const d = document.createElement("div");
      d.className = cls;
      d.textContent = text;
      wrap.appendChild(d);
      return d;
    };
    el("d-label", r.private === false ? `${r.sender} 在 ${r.chat} 說` : `${r.sender} 說`);
    if (r.original) el("d-box", r.original);
    el("d-out" + (sent ? " sent" : ""), (sent ? "➤ " : "") + outcome);
    el("d-box" + (sent ? " sent" : ""), r.text || "");
    if (r.note) el("d-label", "💡 " + r.note);
    return wrap;
  }

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

  // ------------------------------------------------------------------ AI agent

  // The assistant whose conversation is open and how far it has been read.
  let chatProject = null;
  let chatSeq = 0;
  let chatTimer = null;
  let assistants = [];
  let assistantsOffline = false;
  // That assistant's decision history, and the agentd version it was read at.
  let history = [];
  let historyVersion = null;
  // The decision open on its own page: {id, pending}.
  let detail = null;

  const SOURCE = {
    tg: "TG", myghost: "MyGhost", web: "手機網頁", timeout: "逾時",
    superseded: "已改由新決策卡處理", answered: "用文字回答", self_reply: "你在 TG 自己回覆",
    account: "工作帳號", clickup: "ClickUp", worker: "派工對話", system: "系統",
  };

  const ago = (ts) => {
    if (!ts) return "";
    const s = Date.now() / 1000 - ts;
    if (s < 60) return "剛剛";
    if (s < 3600) return Math.floor(s / 60) + " 分鐘前";
    if (s < 86400) return Math.floor(s / 3600) + " 小時前";
    return Math.floor(s / 86400) + " 天前";
  };

  const stamp = (ts) => {
    if (!ts) return "";
    const d = new Date(ts * 1000);
    const two = (n) => String(n).padStart(2, "0");
    return `${two(d.getMonth() + 1)}/${two(d.getDate())} ${two(d.getHours())}:${two(d.getMinutes())}`;
  };

  // Only the cards an assistant raised in its own conversation belong on its
  // screens; a Claude Code tab's permission request is answered from the
  // sidebar's list of everything waiting.
  const isAssistantCard = (x) => x.kind === "choice";
  const pendingFor = (project) =>
    (agent.pending || []).filter((p) => p.project === project && isAssistantCard(p));
  const serialTag = (x) => (x.serial ? "#" + String(x.serial).replace(/^#/, "") : "");

  async function loadAssistants() {
    let data;
    try {
      data = await api("/api/agent/assistants");
    } catch {
      return;
    }
    assistants = data.assistants || [];
    assistantsOffline = !!data.offline;
    renderAssistants();
  }

  function renderAssistants() {
    const list = $("agent-list");
    list.innerHTML = "";
    if (!assistants.length) {
      const empty = document.createElement("div");
      empty.className = "agent-empty";
      empty.textContent = assistantsOffline ? "ghost-agentd 沒有在執行。" : "還沒有專案助手。";
      list.appendChild(empty);
      return;
    }
    for (const a of assistants) {
      const st = a.status;
      const row = document.createElement("div");
      row.className = "agent-row" + (a.name === chatProject ? " active" : "");
      const dot = st && st.busy ? "busy" : st && st.running ? "on" : "";
      const pend = pendingFor(a.name).length;
      row.innerHTML = `<span class="dot ${dot}"></span><span class="name"></span>` +
        (pend ? `<span class="pend">${pend} 待決策</span>` : "") + `<span class="when"></span>`;
      row.querySelector(".name").textContent = a.name + " 助手";
      row.querySelector(".when").textContent = ago((st && st.last_activity) || a.last_activity);
      row.onclick = () => openAssistant(a.name);
      list.appendChild(row);
    }
  }

  function openAssistant(name) {
    if (chatProject !== name) {
      chatProject = name;
      chatSeq = 0;
      history = [];
      historyVersion = null;
      $("agent-chat").innerHTML = "";
      $("agent-sub").textContent = "";
      $("agent-wrap").classList.remove("drawer-open");
      closeDetail();
    }
    $("agent-title").textContent = name + " 助手";
    showScreen("agent");
    renderAssistants();
    renderDrawer(true);
    pollChat(true);
  }

  async function pollChat(toEnd) {
    clearTimeout(chatTimer);
    const project = chatProject;
    if (!project) return;
    try {
      const data = await api(`/api/agent/assistants/${encodeURIComponent(project)}/chat?since=${chatSeq}`);
      if (project === chatProject) appendChat(data, toEnd);
    } catch {}
    // Only while the conversation is on screen.
    if (project === chatProject && $("app").classList.contains("nav-agent"))
      chatTimer = setTimeout(() => pollChat(false), 2500);
  }

  function appendChat(data, toEnd) {
    const box = $("agent-chat");
    const nearEnd = box.scrollHeight - box.scrollTop - box.clientHeight < 80;
    const partial = box.querySelector(".msg.partial");
    if (partial) partial.remove();
    if (!chatSeq && data.truncated) {
      const more = document.createElement("div");
      more.className = "chat-more";
      more.textContent = "較早的對話請到 App 查看";
      box.appendChild(more);
    }
    for (const it of data.items || []) {
      chatSeq = Math.max(chatSeq, it.seq);
      box.appendChild(chatItem(it));
    }
    if (data.partial) {
      const d = document.createElement("div");
      d.className = "msg assistant partial";
      d.textContent = data.partial + " …";
      box.appendChild(d);
    }
    const st = data.status;
    if (st) {
      $("agent-sub").textContent =
        st.compacting ? "整理記憶中…" : st.busy ? "處理中…" : st.running ? "待命中" : "未啟動";
    }
    if (toEnd || nearEnd) box.scrollTop = box.scrollHeight;
  }

  function chatItem(it) {
    const d = document.createElement("div");
    const role = ["user", "assistant", "tool", "choice"].includes(it.role) ? it.role : "notice";
    d.className = "msg " + role;
    if (role === "user") {
      if (it.source && it.source !== "myghost") {
        const src = document.createElement("span");
        src.className = "msg src";
        src.textContent = SOURCE[it.source] || it.source;
        d.appendChild(src);
      }
      d.appendChild(document.createTextNode(it.text || ""));
    } else if (role === "tool") {
      d.textContent = "🔧 " + (it.tool ? it.tool + "：" : "") + (it.text || "");
      d.onclick = () => d.classList.toggle("open");
    } else if (role === "choice") {
      const text = document.createElement("div");
      text.textContent = (serialTag(it) ? serialTag(it) + " " : "") + (it.text || "");
      d.appendChild(text);
      if ((it.options || []).length) {
        const opts = document.createElement("div");
        opts.className = "opts";
        for (const o of it.options) {
          const label = typeof o === "string" ? o : o.label;
          const chip = document.createElement("span");
          chip.className = "opt" + (it.chosen && it.chosen === label ? " picked" : "");
          chip.textContent = label;
          opts.appendChild(chip);
        }
        d.appendChild(opts);
      }
      // The question is a decision card: open it, waiting or already decided.
      if (it.choice_id) {
        d.classList.add("linked");
        d.onclick = () => openCard(it.choice_id);
      }
    } else {
      d.textContent = it.text || "";
    }
    return d;
  }

  async function sendToAssistant() {
    const input = $("agent-input");
    const text = input.value.trim();
    if (!text || !chatProject) return;
    const btn = $("agent-send");
    btn.disabled = true;
    try {
      await api(`/api/agent/assistants/${encodeURIComponent(chatProject)}/messages`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text }),
      });
      input.value = "";
      growInput();
    } catch {
      $("agent-sub").textContent = "送不出去，請再試一次";
    }
    btn.disabled = false;
    pollChat(true);
  }

  function growInput() {
    const input = $("agent-input");
    input.style.height = "auto";
    input.style.height = input.scrollHeight + "px";
  }

  $("agent-send").onclick = sendToAssistant;
  $("agent-input").oninput = growInput;
  // A desktop keyboard sends on Return; a phone's Return is a line break.
  $("agent-input").onkeydown = (e) => {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing && !PHONE.matches) {
      e.preventDefault();
      sendToAssistant();
    }
  };
  $("agent-back").onclick = () => showScreen("list");

  // ---------------------------------------------------- decisions drawer

  $("drawer-handle").onclick = () => {
    if ($("agent-wrap").classList.toggle("drawer-open")) loadHistory();
  };

  async function loadHistory() {
    const project = chatProject;
    if (!project) return;
    historyVersion = agent.version;
    try {
      const data = await api("/api/agent/decisions?project=" + encodeURIComponent(project));
      if (project === chatProject) history = data.decisions || [];
    } catch {}
    renderDrawer(true);
  }

  function outcomeOf(r) {
    if (r.reply) {
      const sent = r.outcome === "send";
      const text = {
        send: `已用 ${r.reply.account} 送出`,
        revise: "沒送出：要求修改",
        self_reply: "沒送出：你已在 TG 自己回覆",
        replaced: "沒送出：已有更新的草稿",
        superseded: "沒送出：已改由新決策卡處理",
        answered: "沒送出：已用文字回答",
      }[r.outcome] || "沒送出：不用回覆";
      return { cls: sent ? "ok" : "", sent, text };
    }
    if (r.by === "superseded") return { cls: "", text: "已改由新決策卡處理" };
    if (r.by === "answered") return { cls: "ok", sent: true, text: "已用文字回答" };
    if (r.state === "allowed") return { cls: "ok", sent: true, text: r.chosen ? "已選：" + r.chosen : "已同意" };
    if (r.state === "expired") return { cls: "", text: "逾時" };
    return { cls: "no", text: "已拒絕" };
  }

  const sourceOf = (r) => SOURCE[r.by] || r.by || "";

  function firstLine(s) {
    return String(s || "").split("\n").find((l) => l.trim()) || "";
  }

  function decisionRow(x, pending) {
    const o = pending
      ? { cls: "wait", text: x.kind === "choice" ? "等你選" : leftText(x) }
      : outcomeOf(x);
    const row = document.createElement("div");
    row.className = "dec-row " + o.cls;
    const meta = document.createElement("div");
    meta.className = "meta";
    const add = (cls, text) => {
      if (!text) return;
      const s = document.createElement("span");
      s.className = cls;
      s.textContent = text;
      meta.appendChild(s);
    };
    add("", pending ? "" : stamp(x.ts));
    add("tag", serialTag(x));
    add("lv", pending ? x.level_name : x.level);
    const line = document.createElement("div");
    line.className = "line";
    line.textContent = x.reply
      ? `${x.reply.sender}：${x.reply.original || x.reply.text}`
      : firstLine(x.summary);
    const out = document.createElement("div");
    out.className = "out" + (o.sent ? " sent" : "");
    out.textContent = o.text;
    row.append(meta, line, out);
    row.onclick = () => openDetail(x, pending);
    return row;
  }

  /// Rebuilds the drawer when what it lists changed — not on every poll, so a
  /// row isn't swapped out from under a finger. `force` redraws regardless.
  function renderDrawer(force) {
    const pend = chatProject ? pendingFor(chatProject) : [];
    $("drawer-count").textContent = pend.length ? String(pend.length) : "";
    const shown = history.filter(isAssistantCard);
    const drawer = $("agent-drawer");
    const sig = [chatProject, pend.map((p) => p.id + p.state).join(), shown.map((r) => r.id).join()].join("|");
    if (!force && drawer.dataset.sig === sig) return;
    drawer.dataset.sig = sig;

    const fill = (box, items, pending, emptyText) => {
      box.innerHTML = "";
      if (!items.length) {
        const empty = document.createElement("div");
        empty.className = "drawer-empty";
        empty.textContent = emptyText;
        box.appendChild(empty);
      }
      for (const x of items) box.appendChild(decisionRow(x, pending));
    };
    fill($("drawer-pending"), pend, true, "目前沒有等你決定的事。");
    fill($("drawer-history"), shown, false, "還沒有決策紀錄。");
  }

  // ---------------------------------------------------- decision page

  function openCard(id) {
    const p = (agent.pending || []).find((x) => x.id === id);
    if (p) return openDetail(p, true);
    const r = history.find((x) => x.id === id);
    if (r) return openDetail(r, false);
    // Decided before the history was loaded: fetch it, then look again.
    loadHistory().then(() => {
      const again = history.find((x) => x.id === id);
      if (again) openDetail(again, false);
    });
  }

  function openDetail(x, pending) {
    detail = { id: x.id, pending };
    $("detail-title").textContent = [serialTag(x), pending ? "待決策" : "決策紀錄"].filter(Boolean).join(" ");
    const body = $("detail-body");
    body.innerHTML = "";
    body.appendChild(pending ? buildPendingCard(x, true) : historyDetail(x));
    body.scrollTop = 0;
    $("agent-detail").classList.remove("hidden");
  }

  function closeDetail() {
    detail = null;
    $("agent-detail").classList.add("hidden");
  }
  $("detail-back").onclick = closeDetail;

  function historyDetail(r) {
    const wrap = document.createElement("div");
    const meta = document.createElement("div");
    meta.className = "d-meta";
    meta.textContent = [stamp(r.ts), r.level, r.tab || r.project].filter(Boolean).join(" · ");
    wrap.appendChild(meta);
    const o = outcomeOf(r);
    if (r.reply) {
      wrap.appendChild(replyBlock(r.reply, o.text, o.sent));
    } else {
      const box = document.createElement("div");
      box.className = "d-box mono";
      box.textContent = r.summary || "";
      const out = document.createElement("div");
      out.className = "d-out" + (o.sent ? " sent" : "");
      out.textContent = o.text;
      wrap.append(box, out);
    }
    const facts = [];
    if (r.reason) facts.push("原因：" + r.reason);
    facts.push("決定者：" + sourceOf(r));
    if (r.wait_seconds) facts.push(`等了 ${Math.round(r.wait_seconds)} 秒才決定`);
    if (r.deny_message) facts.push("拒絕理由：" + r.deny_message);
    if (r.always_added) facts.push("此專案一律允許：" + r.always_added);
    if (r.discussed) facts.push("決定前有討論過");
    const f = document.createElement("div");
    f.className = "d-facts";
    f.style.whiteSpace = "pre-wrap";
    f.textContent = facts.join("\n");
    wrap.appendChild(f);
    return wrap;
  }

  /// Keeps the AI Agent screens in step with each agentd poll.
  function agentChanged() {
    if ($("mode-agent").classList.contains("active")) renderAssistants();
    if (!chatProject) return;
    renderDrawer(false);
    if ($("agent-wrap").classList.contains("drawer-open") && agent.version !== historyVersion) loadHistory();
    // A waiting card answered elsewhere — TG, the app — leaves its page.
    if (detail && detail.pending && !(agent.pending || []).some((p) => p.id === detail.id)) {
      closeDetail();
      loadHistory();
    }
  }

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
    app.classList.toggle("nav-agent", which === "agent");
    app.classList.toggle("nav-list", which === "list");
    // The conversation polls only while it is the screen being looked at.
    if (which !== "agent") clearTimeout(chatTimer);
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
  $("mode-agent").onclick = () => setMode("agent");
  function setMode(m) {
    $("mode-term").classList.toggle("active", m === "term");
    $("mode-agent").classList.toggle("active", m === "agent");
    $("tab-pane").classList.toggle("hidden", m !== "term");
    $("agent-pane").classList.toggle("hidden", m !== "agent");
    if (m === "agent") loadAssistants();
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
  refreshAgent();
  setInterval(refreshAgent, 3000);
  setInterval(refreshState, 5000);
  setInterval(refreshAI, 60000);
  setInterval(() => {
    if ($("mode-agent").classList.contains("active")) loadAssistants();
  }, 15000);
})();
