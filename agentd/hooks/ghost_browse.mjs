// ghost-browse: open a page in a real (windowed) Chrome and print its text.
// Headless Chrome and curl get stopped by Cloudflare's bot check; a normal
// Chrome window with its own profile passes it. We drive it over CDP, so no
// macOS Automation permission is needed.
//
// usage: ghost-browse <url> [--wait 40] [--shot out.png] [--js 'expr'] [--html]
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const PORT = Number(process.env.GHOST_BROWSE_PORT || 9334);
const PROFILE = process.env.GHOST_BROWSE_PROFILE || path.join(os.homedir(), '.myghost', 'browser-profile');
const CHROME = process.env.GHOST_BROWSE_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const BLOCKED = /just a moment|請稍候|checking your browser|verify you are human|驗證您是人類|attention required/i;

const argv = process.argv.slice(2);
const opt = { wait: 40, shot: '', js: '', html: false };
let url = '';
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--wait') opt.wait = Number(argv[++i]);
  else if (a === '--shot') opt.shot = argv[++i];
  else if (a === '--js') opt.js = argv[++i];
  else if (a === '--html') opt.html = true;
  else if (!url) url = a;
}
if (!/^https?:\/\//.test(url)) {
  console.error('usage: ghost-browse <http(s)-url> [--wait 秒] [--shot 圖檔.png] [--js 表達式] [--html]');
  process.exit(2);
}

const sleep = ms => new Promise(r => setTimeout(r, ms));
const api = async (p, method = 'GET') => (await fetch(`http://127.0.0.1:${PORT}${p}`, { method })).json();

async function ensureChrome() {
  try { await api('/json/version'); return; } catch {}
  fs.mkdirSync(PROFILE, { recursive: true });
  spawn(CHROME, [`--user-data-dir=${PROFILE}`, `--remote-debugging-port=${PORT}`,
    '--no-first-run', '--no-default-browser-check', '--window-size=1280,900', 'about:blank'],
    { detached: true, stdio: 'ignore' }).unref();
  for (let i = 0; i < 40; i++) {
    await sleep(250);
    try { await api('/json/version'); return; } catch {}
  }
  throw new Error('Chrome 沒有啟動（debug port ' + PORT + '）');
}

function connect(wsUrl) {
  const ws = new WebSocket(wsUrl);
  let id = 0; const pend = {};
  ws.onmessage = e => { const m = JSON.parse(e.data); if (pend[m.id]) { pend[m.id](m); delete pend[m.id]; } };
  const send = (method, params = {}) => new Promise((res, rej) => {
    pend[++id] = m => m.error ? rej(new Error(m.error.message)) : res(m.result);
    ws.send(JSON.stringify({ id, method, params }));
  });
  return new Promise(r => { ws.onopen = () => r({ ws, send }); });
}

await ensureChrome();
const tab = await api('/json/new?' + encodeURIComponent(url), 'PUT');
const { ws, send } = await connect(tab.webSocketDebuggerUrl);
const ev = async expr => (await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true })).result?.value;

// Wait for the bot check to clear and the text to stop growing.
let last = -1, stable = 0, state = {};
const deadline = Date.now() + opt.wait * 1000;
while (Date.now() < deadline) {
  await sleep(1000);
  try {
    state = await ev('({t: document.title, u: location.href, n: (document.body && document.body.innerText || "").length, r: document.readyState})') || {};
  } catch { continue; }
  if (BLOCKED.test(state.t || '') || state.r !== 'complete') { stable = 0; continue; }
  stable = state.n === last && state.n > 0 ? stable + 1 : 0;
  last = state.n;
  if (stable >= 2) break;
}

const blocked = BLOCKED.test(state.t || '');
console.log(`# ${state.t || ''}\n# ${state.u || url}${blocked ? '\n# ⚠️ 仍卡在驗證頁（可加大 --wait，或請負責人在 Mini 上的這個 Chrome 視窗手動過一次驗證）' : ''}\n`);
if (opt.shot) {
  const { data } = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
  fs.writeFileSync(opt.shot, Buffer.from(data, 'base64'));
  console.log(`# 截圖：${opt.shot}\n`);
}
const out = opt.js ? await ev(opt.js) : await ev(opt.html ? 'document.documentElement.outerHTML' : 'document.body.innerText');
console.log(typeof out === 'string' ? out : JSON.stringify(out, null, 1));
ws.close();
await api('/json/close/' + tab.id).catch(() => {});
process.exit(blocked ? 3 : 0);
