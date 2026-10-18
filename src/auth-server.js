#!/usr/bin/env node
// auth-server.js — tiny status page for the Claude Code container.
//
//   Signed in      -> green "You're all set" banner
//   Not signed in  -> the Anthropic sign-in link scraped from the tmux pane,
//                     plus a box to paste the code back into Claude
//
// No dependencies (plain Node). Listens on AUTH_PAGE_PORT (default 8765).
// LAN use only: anyone who can reach this page while Claude is signed OUT
// can drive the login prompt. Once signed in, it only shows the banner.
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');

const PORT = parseInt(process.env.AUTH_PAGE_PORT || '8765', 10);
const SESSION = process.env.TMUX_SESSION || 'claude';
const HOME = process.env.HOME || '/workspace/.home';
const CRED_FILE = path.join(HOME, '.claude', '.credentials.json');
const CONTAINER = process.env.CONTAINER_NAME || 'claude-code';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const run = (cmd, args, timeout = 8000) =>
  new Promise((resolve) =>
    execFile(cmd, args, { timeout, maxBuffer: 1 << 20 }, (err, stdout) =>
      resolve({ ok: !err, stdout: String(stdout || '') })));

// ---------- auth detection ----------
// Cheapest signals first; `claude auth status` is the fallback (cached).
let authCache = { at: 0, value: { authed: false } };
async function checkAuth() {
  if (process.env.ANTHROPIC_API_KEY) return { authed: true, method: 'API key' };
  if (process.env.CLAUDE_CODE_OAUTH_TOKEN) return { authed: true, method: 'OAuth token' };
  try {
    const raw = fs.readFileSync(CRED_FILE, 'utf8');
    if (/"accessToken"\s*:\s*"[^"]+"/.test(raw)) return { authed: true, method: 'Claude account' };
  } catch (_) { /* no credentials file yet */ }
  if (Date.now() - authCache.at < 10000) return authCache.value;
  const r = await run('claude', ['auth', 'status'], 10000);
  let value = { authed: false };
  try {
    const j = JSON.parse(r.stdout);
    if (j && j.loggedIn) value = { authed: true, method: j.authMethod || 'signed in' };
  } catch (_) { /* not JSON / older CLI */ }
  authCache = { at: Date.now(), value };
  return value;
}

// ---------- tmux pane scraping ----------
async function readPane() {
  const [t, w] = await Promise.all([
    run('tmux', ['capture-pane', '-p', '-J', '-t', SESSION, '-S', '-300'], 4000),
    run('tmux', ['display-message', '-p', '-t', SESSION, '#{pane_width}'], 4000),
  ]);
  if (!t.ok) return null;
  return { text: t.stdout, width: parseInt(w.stdout, 10) || 0 };
}

const URL_START = /https:\/\/(?:[\w-]+\.)*(?:claude\.ai|claude\.com|anthropic\.com)\/\S*authorize\S*/;
const URL_CHARS = /^[A-Za-z0-9\-._~:/?#[\]@!$&'()*+,;=%]+$/;

// Returns the most recent sign-in URL on screen. Handles URLs the TUI has
// hard-wrapped across lines (tmux -J only joins soft wraps).
function findLoginUrl(pane) {
  if (!pane) return null;
  const lines = pane.text.split('\n').map((l) => l.replace(/\s+$/, ''));
  let url = null;
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(URL_START);
    if (!m) continue;
    let cand = m[0];
    let j = i;
    while (pane.width && lines[j].length >= pane.width - 3 &&
           j + 1 < lines.length && URL_CHARS.test(lines[j + 1].trim())) {
      j++;
      cand += lines[j].trim();
    }
    url = cand.replace(/[).,;'"]+$/, '');
    i = j;
  }
  return url;
}

function tail(text, n = 30) {
  return text.split('\n').map((l) => l.replace(/\s+$/, '')).filter(Boolean).slice(-n).join('\n');
}

async function getState() {
  const a = await checkAuth();
  if (a.authed) return { state: 'ready', method: a.method };
  const pane = await readPane();
  if (!pane) return { state: 'no-session' };
  const url = findLoginUrl(pane);
  return {
    state: url ? 'login' : 'waiting',
    url,
    awaitingCode: /paste\s+code/i.test(pane.text),
    snapshot: tail(pane.text),
  };
}

// ---------- actions (only while signed out) ----------
let lastAction = 0;
async function handleAction(body) {
  if ((await checkAuth()).authed) return [409, { error: 'Already signed in.' }];
  if (Date.now() - lastAction < 1500) return [429, { error: 'One moment, try again.' }];
  lastAction = Date.now();
  const keys = (...a) => run('tmux', ['send-keys', '-t', SESSION, ...a]);
  switch (body.action) {
    case 'login':
      await keys('-l', '--', '/login'); await sleep(400); await keys('Enter');
      return [200, { ok: true }];
    case 'enter':
      await keys('Enter');
      return [200, { ok: true }];
    case 'code': {
      const code = String(body.code || '').trim();
      if (!/^[A-Za-z0-9._~#:%-]{8,600}$/.test(code)) {
        return [400, { error: 'That doesn’t look like a sign-in code.' }];
      }
      if (!findLoginUrl(await readPane())) return [409, { error: 'No sign-in is waiting for a code.' }];
      await keys('-l', '--', code); await sleep(300); await keys('Enter');
      authCache.at = 0;
      return [200, { ok: true }];
    }
    default:
      return [400, { error: 'Unknown action.' }];
  }
}

// ---------- HTML ----------
const esc = (s) => String(s).replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const TICK = '<svg viewBox="0 0 24 24" width="28" height="28" aria-hidden="true"><circle cx="12" cy="12" r="11" fill="currentColor"/><path d="M7 12.5l3.2 3.2L17.5 8.5" fill="none" stroke="var(--on-ok)" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg>';
const ALERT = '<svg viewBox="0 0 24 24" width="28" height="28" aria-hidden="true"><circle cx="12" cy="12" r="11" fill="currentColor"/><path d="M12 6.5v7M12 17.2v.3" fill="none" stroke="var(--on-warn)" stroke-width="2.4" stroke-linecap="round"/></svg>';

function banner(kind, title, sub) {
  return `<div class="banner ${kind}" role="status">${kind === 'ok' ? TICK : ALERT}<div><strong>${title}</strong><span>${sub}</span></div></div>`;
}

const attach = `docker exec -it ${CONTAINER} tmux attach -t ${SESSION}`;

function body(st) {
  if (st.state === 'ready') {
    return banner('ok', 'You’re all set', `Claude Code is signed in (${esc(st.method)}) and running in tmux.`) +
      `<section class="card"><h2>Open the session</h2><p>From the host:</p><pre>${esc(attach)}</pre>
       <p class="muted">Detach with Ctrl-b then d. Claude keeps running in the background.</p></section>`;
  }
  if (st.state === 'no-session') {
    return banner('warn', 'Claude’s tmux session isn’t running', 'The page can’t see a login screen.') +
      `<section class="card"><p>Check the container logs, or restart the container:</p>
       <pre>docker logs ${esc(CONTAINER)}\ndocker restart ${esc(CONTAINER)}</pre></section>`;
  }
  const snap = `<details${st.state === 'waiting' ? ' open' : ''}><summary>What Claude is showing</summary><pre id="snap">${esc(st.snapshot || '')}</pre></details>`;
  if (st.state === 'login') {
    return banner('warn', 'Sign-in needed', 'Claude Code isn’t signed in yet.') +
      `<section class="card">
        <ol><li>Open the sign-in link and approve access.</li>
            <li>Copy the code Anthropic shows you.</li>
            <li>Paste it below and submit.</li></ol>
        <a class="btn primary" href="${esc(st.url)}" target="_blank" rel="noopener noreferrer">Sign in with Anthropic ↗</a>
        <form id="codeform" autocomplete="off">
          <input id="code" name="code" spellcheck="false" placeholder="Paste code here" aria-label="Sign-in code" required>
          <button class="btn" type="submit">Submit code</button>
        </form>
        <p id="msg" class="muted" aria-live="polite"></p>
        <details><summary>Show link</summary><code class="url">${esc(st.url)}</code></details>
        ${snap}
      </section>`;
  }
  return banner('warn', 'Waiting for a sign-in link', 'Claude isn’t signed in and no link is on screen yet.') +
    `<section class="card">
      <p>Start the sign-in flow. If a menu appears below, press Enter to pick the highlighted option
         (the default is your Claude account).</p>
      <div class="row">
        <button class="btn primary" data-action="login">Start sign-in</button>
        <button class="btn" data-action="enter">Press Enter</button>
      </div>
      <p id="msg" class="muted" aria-live="polite"></p>
      ${snap}
      <p class="muted">Or do it by hand: <code>${esc(attach)}</code></p>
    </section>`;
}

function page(st) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Claude Code Sign-in</title>
<style>
:root{--bg:#f6f6f4;--fg:#1d1d1b;--muted:#6b6b66;--card:#fff;--line:#e2e1dc;
 --ok:#1f8a4c;--ok-bg:#e8f5ec;--on-ok:#fff;--warn:#b26a00;--warn-bg:#fdf3e2;--on-warn:#fff;--accent:#c96442}
@media (prefers-color-scheme:dark){:root{--bg:#191917;--fg:#ecebe6;--muted:#a3a29c;--card:#22221f;--line:#34332f;
 --ok:#3fbf73;--ok-bg:#15301f;--on-ok:#0e1f14;--warn:#e8a33d;--warn-bg:#33270f;--on-warn:#2a1d05;--accent:#e07a56}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}
main{max-width:640px;margin:0 auto;padding:32px 16px}
h1{font-size:15px;font-weight:600;color:var(--muted);margin:0 0 16px;letter-spacing:.02em}
h2{font-size:17px;margin:0 0 8px}
.banner{display:flex;gap:14px;align-items:center;padding:16px 18px;border-radius:12px;border:1px solid}
.banner strong{display:block;font-size:19px}
.banner span{display:block;color:var(--fg);opacity:.85}
.banner.ok{background:var(--ok-bg);border-color:var(--ok);color:var(--ok)}
.banner.warn{background:var(--warn-bg);border-color:var(--warn);color:var(--warn)}
.banner svg{flex:none}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:18px;margin-top:16px}
ol{padding-left:20px;margin:0 0 16px}
pre,code{font:13px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
pre{background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:10px;overflow-x:auto;white-space:pre-wrap;overflow-wrap:anywhere;margin:8px 0}
.card>p:first-child{margin-top:0}
.url{display:block;word-break:break-all;margin-top:8px}
.muted{color:var(--muted);font-size:14px}
.row{display:flex;gap:10px;flex-wrap:wrap}
.btn{appearance:none;border:1px solid var(--line);background:var(--card);color:var(--fg);border-radius:8px;
 padding:10px 16px;font:inherit;font-weight:600;cursor:pointer;text-decoration:none;display:inline-block}
.btn.primary{background:var(--accent);border-color:var(--accent);color:#fff}
.btn:disabled{opacity:.6;cursor:wait}
form{display:flex;gap:10px;margin-top:16px;flex-wrap:wrap}
input{flex:1 1 220px;min-width:0;padding:10px 12px;border-radius:8px;border:1px solid var(--line);background:var(--bg);color:var(--fg);font:14px ui-monospace,Menlo,monospace}
details{margin-top:14px}summary{cursor:pointer;color:var(--muted);font-size:14px}
</style></head>
<body data-state="${esc(st.state)}" data-url="${esc(st.url || '')}">
<main><h1>Claude Code · ${esc(CONTAINER)}</h1>${body(st)}</main>
<script>
const b=document.body.dataset, msg=document.getElementById('msg');
async function act(action, extra){
  const r=await fetch('/api/action',{method:'POST',headers:{'Content-Type':'application/json','X-Requested-With':'claude-auth-page'},body:JSON.stringify(Object.assign({action},extra||{}))});
  const j=await r.json().catch(()=>({}));
  if(msg) msg.textContent = r.ok ? (action==='code'?'Code sent. Checking…':'Sent. Watching for the link…') : (j.error||'Something went wrong.');
}
document.querySelectorAll('[data-action]').forEach(el=>el.addEventListener('click',async()=>{el.disabled=true;await act(el.dataset.action);setTimeout(()=>el.disabled=false,1600)}));
const f=document.getElementById('codeform');
if(f) f.addEventListener('submit',async e=>{e.preventDefault();await act('code',{code:document.getElementById('code').value})});
async function poll(){try{
  const j=await (await fetch('/api/status',{cache:'no-store'})).json();
  if(j.state!==b.state||(j.url||'')!==b.url){location.reload();return}
  const s=document.getElementById('snap'); if(s&&typeof j.snapshot==='string') s.textContent=j.snapshot;
}catch(e){}}
setInterval(poll, b.state==='ready'?15000:3000);
</script></body></html>`;
}

// ---------- server ----------
function send(res, code, type, data) {
  res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store', 'X-Frame-Options': 'DENY' });
  res.end(data);
}

http.createServer(async (req, res) => {
  try {
    const url = req.url.split('?')[0];
    if (req.method === 'GET' && url === '/healthz') return send(res, 200, 'text/plain', 'ok');
    if (req.method === 'GET' && url === '/api/status') {
      return send(res, 200, 'application/json', JSON.stringify(await getState()));
    }
    if (req.method === 'GET' && url === '/') {
      return send(res, 200, 'text/html; charset=utf-8', page(await getState()));
    }
    if (req.method === 'POST' && url === '/api/action') {
      // Custom header forces a CORS preflight, so other websites can't post here.
      if (req.headers['x-requested-with'] !== 'claude-auth-page') {
        return send(res, 403, 'application/json', '{"error":"Forbidden"}');
      }
      let raw = '';
      for await (const chunk of req) {
        raw += chunk;
        if (raw.length > 4096) return send(res, 413, 'application/json', '{"error":"Too large"}');
      }
      let parsed = {};
      try { parsed = JSON.parse(raw || '{}'); } catch (_) { /* fall through */ }
      const [code, out] = await handleAction(parsed);
      return send(res, code, 'application/json', JSON.stringify(out));
    }
    send(res, 404, 'text/plain', 'Not found');
  } catch (err) {
    console.error(err);
    send(res, 500, 'text/plain', 'Internal error');
  }
}).listen(PORT, '0.0.0.0', () => console.log(`auth page listening on :${PORT}`));
