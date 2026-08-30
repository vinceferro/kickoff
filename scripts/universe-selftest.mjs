#!/usr/bin/env node
// universe-selftest.mjs — THE runnable proof for the generic /universe deck (core-v0.4 S1+S2).
//
// Starts mission-control/server.py against a SUPPLIED mission-state.json (copied to a scratch
// path — the original is never served, locked, or chmod'd), loads /universe headless, and asserts
// the render reflects THAT state:
//   • core label == state.project (and the HUD title carries it)
//   • galaxy count == distinct done[].theme (→ owner → 'shipped' fallback — the engine's grouping)
//   • star count  == done.length
//   • ZERO console errors + ZERO console WARNS + ZERO page errors (incl. the software-GL bloom
//     noise — shader-noise; warns captured so a three.js warn-path regression is visible; the
//     browser's own GL-driver PERF chatter — a tight [.WebGL-…] signature — is filtered + counted)
//   • the served HTML carries ZERO operator-identity strings (denylist via UNIVERSE_IDENTITY_DENYLIST;
//     empty default → a green no-op for a generic adopter, still executed)
//   • auth: /universe + /config without a token → 401; / still serves + retired /3d → 404 (additive, nothing broken)
//   • [HUD-fit] at the 390px AND 320px (iPhone SE) viewports the HUD title clears the top-right controls
//   • [S3 opt-in] the main server runs KICKOFF_UNIVERSE=1 → /universe 200, /config {"universe":true}
//     (BOOLEANS only), dashboard shows the 🌌 link; a SECOND server on port+1 with the flag UNSET
//     (the shipped default) proves OFF → /universe 404, /config {"universe":false}, link hidden.
//   • [S4 theming] main server (no .kickoff ancestor → baked template default): /universe-theme is
//     token-gated + serves the default palette, and the deck's APPLIED engine values (CSS var, core
//     material, fog, bloom strength) == the shipped organic look. A THIRD server on port+2 runs the
//     REAL adopter wiring (KICKOFF_STATE under a scratch .kickoff/ + an override universe.theme.json
//     beside it — the derived path, no env override): the deck's applied values reflect the OVERRIDE
//     (retinted accent/fog/hues/strings), invalid colors fall back, out-of-bounds knobs CLAMP (the
//     organic guardrail), non-overridden keys keep defaults, and the data-driven counts are unchanged
//     (a theme retints — it never touches the state pipeline). Override screenshot → <outPng>-override.
//   • [S5 offline/vendored] the deck is CDN-free: the served HTML carries ZERO CDN/unpkg/three@
//     strings (the importmap is local /vendor/three/…); every browser context runs behind an
//     interceptor that ABORTS + records any non-127.0.0.1 request — the deck must render green
//     anyway, and the run asserts ZERO external requests were even attempted (the offline proof).
//     /vendor/ serves the pinned Three.js with the correct JS MIME, UNAUTHENTICATED by design
//     (module fetches precede the deck's token→cookie wiring — a gated /vendor would dead-deck
//     every first visit); traversal attempts (raw ../, %2e%2e, absolute joins — sent path-as-is
//     over a raw socket, fetch would pre-normalize them) all 404 and never leak the token; the
//     flag-OFF twin 404s /vendor too (no capability, no routes).
//
// SAFETY: binds fresh UNIQUE ports — <port>, <port>+1 AND <port>+2 — (fails fast if any is busy) and kills
// ONLY the exact child PIDs it spawned — NEVER pattern-kills server.py (that would take down the live board).
//
// Usage: NODE_PATH=<dir-with-playwright>/node_modules node scripts/universe-selftest.mjs \
//          <mission-state.json> [port=9461] [flagset=angle-egl|soft] [outPng]
//   angle-egl → the box GPU (real bloom); soft → default headless SwiftShader/SwANGLE
//   (proves the shader-noise suppression keeps the software-GL verify clean).
import { createRequire } from 'node:module';
import { readFileSync, writeFileSync, existsSync, readdirSync, mkdirSync, rmSync, mkdtempSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import net from 'node:net';
import os from 'node:os';
import http from 'node:http';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const MC = path.join(REPO, 'mission-control');
// The served /universe HTML must carry NO operator-identity strings. WHICH strings count as
// "identity" is operator-specific (an adopter's are their own — a maintainer's dev handle is
// meaningless to them), so the denylist is data, not a baked-in literal: pass it via
// UNIVERSE_IDENTITY_DENYLIST (comma-separated). Default empty → a generic adopter's run has
// nothing to deny and the assert is a green no-op that still executes; a maintainer scrubbing a
// release can export their own names (e.g. their handle) to actually enforce it. Terms are
// regex-escaped so a term containing regex metacharacters (a '.', '+', etc.) still matches literally.
const IDENTITY_DENY = (process.env.UNIVERSE_IDENTITY_DENYLIST || '')
  .split(',').map(s => s.trim()).filter(Boolean);
const identityHits = (s) => IDENTITY_DENY.length === 0 ? []
  : (s.match(new RegExp(IDENTITY_DENY.map(t => t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|'), 'gi')) || []);

const stateFile = process.argv[2] || path.join(MC, 'mission-state.sample.json');
const port = Number(process.argv[3] || 9461);
const portOff = port + 1;     // the flag-OFF twin server (S3 opt-in proof) — must also be free
const portTheme = port + 2;   // the THEME-OVERRIDE server (S4 proof) — must also be free
const flagsKey = process.argv[4] || 'angle-egl';
const outPng = process.argv[5] || `/tmp/universe-selftest-${port}.png`;
const outPngOverride = outPng.replace(/\.png$/i, '') + '-override.png';

const FLAGSETS = {
  'angle-egl': ['--use-gl=angle', '--use-angle=gl-egl', '--ignore-gpu-blocklist', '--enable-gpu-rasterization'],
  'soft': [],   // default headless GL → SwANGLE/SwiftShader (the software-GL path an adopter hit)
};

function findChrome() { // full chromium (not headless-shell) — required for the GPU flagset
  const base = path.join(os.homedir(), '.cache/ms-playwright');
  try {
    for (const d of readdirSync(base)) {
      if (d.startsWith('chromium-') && !d.includes('headless')) {
        const p = `${base}/${d}/chrome-linux64/chrome`;
        if (existsSync(p)) return p;
      }
    }
  } catch {}
  return undefined;
}

// expected values straight from the SUPPLIED state (the engine's own grouping rule):
// buildConstellations keeps done items with a text; themeKeyOf groups theme → owner → 'shipped'.
const state = JSON.parse(readFileSync(stateFile, 'utf-8'));
const doneItems = (state.done || []).filter(d => d && d.text);
const galaxyKeys = [...new Set(doneItems.map(d => d.theme || d.owner || 'shipped'))];
const expected = { project: state.project, galaxies: galaxyKeys.length, stars: doneItems.length };

// serve a scratch COPY — the supplied file is never locked/chmod'd/mtime-bumped by the server
const scratch = mkdtempSync(path.join(os.tmpdir(), 'universe-selftest-'));
const servedState = path.join(scratch, 'mission-state.json');
writeFileSync(servedState, JSON.stringify(state, null, 2));

const results = [];
const check = (name, ok, detail) => { results.push({ name, ok, detail }); console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  — ' + detail : ''}`); };

// the ports must be genuinely free — refuse to run into someone else's server
const assertPortFree = (p) => new Promise((res, rej) => {
  const s = net.createServer();
  s.once('error', e => rej(new Error(`port ${p} not free (${e.code}) — pick another; NOT killing anything`)));
  s.once('listening', () => s.close(res));
  s.listen(p, '127.0.0.1');
});
await assertPortFree(port);
await assertPortFree(portOff);
await assertPortFree(portTheme);

// ── [S4] the OVERRIDE theme + the REAL adopter wiring shape ──────────────────────────────
// A scratch .kickoff/ with the state nested at the instance.env path and an override
// universe.theme.json BESIDE it — server.py must find the theme by DERIVING the .kickoff
// ancestor from KICKOFF_STATE (no KICKOFF_UNIVERSE_THEME env), exactly like a real adopter.
// The override exercises every guardrail: a retint (accent/space/hues/strings), an INVALID
// color (strict parse → default), and two OUT-OF-BOUNDS knobs (clamped → the organic look
// can be retinted/rescaled but never broken).
const OVERRIDE_THEME = {
  palette: {
    accent: '#a78bfa',                                   // retint: soft violet (≠ default #5fa8b0)
    accentWarm: 'red; background:url(x)',                // INVALID → must fall back to #d99a5c
    space: '#140a20',                                    // deep violet night
    galaxyHues: ['#a78bfa', '#f0a0c0', '#7fd0c8'],       // 3 cycled hues (≠ the shipped six)
  },
  knobs: { bloomStrength: 1.25, particleDensity: 9.9, starSize: 0.1, galaxySize: 1.15, tunnelIntensity: 1.3 },
  //                       ok ↑        CLAMP → 2.0 ↑      CLAMP → 0.6 ↑
  strings: { tagline: 'the override cosmos', genesisLabel: 'Slack', signature: 'themed by the selftest' },
};
const kickoffDir = path.join(scratch, '.kickoff');
const nestedStateDir = path.join(kickoffDir, 'state', 'mission-control');
mkdirSync(nestedStateDir, { recursive: true });
const nestedState = path.join(nestedStateDir, 'mission-state.json');
writeFileSync(nestedState, JSON.stringify(state, null, 2));
writeFileSync(path.join(kickoffDir, 'universe.theme.json'), JSON.stringify(OVERRIDE_THEME, null, 2));

// ── spawn the REAL server.py on the unique ports (exact-PID lifecycle) ──
// main server: KICKOFF_UNIVERSE=1 (the deck under test is the OPT-IN route, S3);
// spawnServer also builds the flag-UNSET twin that proves the shipped default is OFF,
// and the S4 theme-override server (stateOverride → the .kickoff-nested copy).
const spawnServer = (p, universeOn, stateOverride) => {
  const env = { ...process.env, KICKOFF_STATE: stateOverride || servedState };
  delete env.KICKOFF_UNIVERSE;                 // never inherit the runner's shell value
  delete env.KICKOFF_UNIVERSE_THEME;           // theme resolution under test — never inherit either
  if (universeOn) env.KICKOFF_UNIVERSE = '1';
  const child = spawn('python3', [path.join(MC, 'server.py'), String(p)], { env, stdio: ['ignore', 'ignore', 'pipe'] });
  child.stderrText = '';
  child.stderr.on('data', d => { child.stderrText += d; });
  return child;
};
const killPid = async (pid) => {
  if (!pid) return;
  try { process.kill(pid, 'SIGTERM'); } catch {}
  await new Promise(r => setTimeout(r, 800));
  try { process.kill(pid, 0); process.kill(pid, 'SIGKILL'); } catch {} // still alive → hard kill (exact PID only)
};
const server = spawnServer(port, true);
const serverPid = server.pid;
let serverOffPid = null;     // spawned later, killed in finally (exact PID)
let serverThemePid = null;   // the S4 override server — spawned later, killed in finally (exact PID)

let browser = null;
let failed = false;
try {
  // wait for /healthz
  const waitUp = async (b, child, p) => {
    for (let i = 0; i < 50; i++) {
      try { const r = await fetch(`${b}/healthz`); if (r.ok) return; } catch {}
      await new Promise(r => setTimeout(r, 200));
    }
    throw new Error(`server.py never came up on :${p}\n${child.stderrText}`);
  };
  const base = `http://127.0.0.1:${port}`;
  await waitUp(base, server, port);
  const token = readFileSync(path.join(MC, '.mission-token'), 'utf-8').trim();

  // ── HTTP-level asserts ──
  const unauth = await fetch(`${base}/universe`);
  check('auth: /universe without token → 401', unauth.status === 401, `got ${unauth.status}`);
  const uni = await fetch(`${base}/universe?token=${encodeURIComponent(token)}`);
  check('GET /universe → 200 text/html', uni.status === 200 && (uni.headers.get('content-type') || '').includes('text/html'), `got ${uni.status}`);
  const html = await uni.text();
  const idHits = identityHits(html);
  check('served HTML: ZERO operator-identity strings (UNIVERSE_IDENTITY_DENYLIST)', idHits.length === 0,
    idHits.length ? `hits: ${[...new Set(idHits)].join(',')}` : (IDENTITY_DENY.length ? 'clean' : 'no denylist set — nothing to deny'));
  {
    const r = await fetch(`${base}/?token=${encodeURIComponent(token)}`);
    check('additive: GET / still 200', r.status === 200, `got ${r.status}`);
  }
  // /3d is RETIRED (v0.4): /universe replaces the old bespoke deck. The route is gone,
  // so GET /3d must fall through to a clean 404 — never 500 on the missing private deck.
  {
    const r = await fetch(`${base}/3d?token=${encodeURIComponent(token)}`);
    check('retired: GET /3d → 404 (route removed, /universe replaces it)', r.status === 404, `got ${r.status}`);
  }

  // ── [S5 vendored three] the deck is CDN-free + /vendor serves it, contained ──
  const cdnHits = html.match(/unpkg\.com|jsdelivr|cdnjs|https?:\/\/cdn\.|three@/gi) || [];
  check('served HTML: ZERO CDN/unpkg/three@ strings (importmap is local)', cdnHits.length === 0,
    cdnHits.length ? `hits: ${[...new Set(cdnHits)].join(',')}` : 'clean');
  check('served HTML: importmap points at /vendor/three/', html.includes('"three": "/vendor/three/build/three.module.js"'),
    'importmap rewrite present');
  // UNAUTHENTICATED by design: the browser fetches these modules BEFORE the deck's
  // token→cookie wiring runs — this assert pins the posture so a future re-gating
  // (which would dead-deck every first visit) fails loudly here.
  const vCore = await fetch(`${base}/vendor/three/build/three.module.js`);
  const vCoreBody = vCore.status === 200 ? await vCore.text() : '';
  check('vendor: three.module.js serves WITHOUT a token (first-load module fetch)',
    vCore.status === 200 && vCoreBody.length > 500000, `got ${vCore.status}, ${vCoreBody.length} bytes`);
  check('vendor: correct JS MIME (module scripts hard-fail otherwise)',
    (vCore.headers.get('content-type') || '').includes('text/javascript'), `got ${vCore.headers.get('content-type')}`);
  const vAddon = await fetch(`${base}/vendor/three/examples/jsm/postprocessing/UnrealBloomPass.js`);
  check('vendor: addon (UnrealBloomPass.js) serves', vAddon.status === 200, `got ${vAddon.status}`);
  // Traversal — sent PATH-AS-IS over a raw socket (fetch/URL would pre-normalize ../ and
  // %2e%2e away before the server ever saw them, testing nothing). Every attempt must 404
  // and never leak the token file's bytes.
  const rawGet = (p) => new Promise((res, rej) => {
    const req = http.request({ host: '127.0.0.1', port, path: p, method: 'GET' }, r => {
      let b = ''; r.on('data', c => b += c); r.on('end', () => res({ status: r.statusCode, body: b }));
    });
    req.on('error', rej); req.end();
  });
  for (const [label, p] of [
    ['raw ../ escape', '/vendor/../.mission-token'],
    ['%2e%2e escape', '/vendor/%2e%2e/.mission-token'],
    ['%2e%2e with a .js suffix (realpath containment)', '/vendor/%2e%2e/%2e%2e/vendor/three/build/three.module.js'],
    ['absolute-path join', '/vendor//etc/passwd.js'],
    ['non-.js file inside vendor', '/vendor/three/LICENSE'],
  ]) {
    const r = await rawGet(p);
    check(`vendor traversal guard: ${label} → 404`, r.status === 404 && !r.body.includes(token), `got ${r.status}`);
  }

  // ── [S3 opt-in] /config on the flag-ON server: token-gated, BOOLEANS only, universe:true ──
  const cfgUnauth = await fetch(`${base}/config`);
  check('auth: /config without token → 401', cfgUnauth.status === 401, `got ${cfgUnauth.status}`);
  const cfgRes = await fetch(`${base}/config?token=${encodeURIComponent(token)}`);
  const cfg = cfgRes.status === 200 ? await cfgRes.json() : null;
  check('flag ON: /config → {"universe":true}', !!cfg && cfg.universe === true, `got ${cfgRes.status} ${JSON.stringify(cfg)}`);
  check('/config carries BOOLEANS only (no secrets/paths)', !!cfg && Object.keys(cfg).length > 0 && Object.values(cfg).every(v => typeof v === 'boolean'), JSON.stringify(cfg));

  // ── [S4 theming] /universe-theme on the main server: token-gated; no .kickoff ancestor on the
  //    scratch state path → the BAKED TEMPLATE default (the shipped organic look) serves.
  const thUnauth = await fetch(`${base}/universe-theme`);
  check('auth: /universe-theme without token → 401', thUnauth.status === 401, `got ${thUnauth.status}`);
  const thRes = await fetch(`${base}/universe-theme?token=${encodeURIComponent(token)}`);
  const thDefault = thRes.status === 200 ? await thRes.json() : null;
  check('default theme: /universe-theme → 200 + the baked organic default (accent #5fa8b0)',
    !!thDefault && thDefault.palette && thDefault.palette.accent === '#5fa8b0' && thDefault.strings && thDefault.strings.genesisLabel === 'Telegram',
    `got ${thRes.status} accent=${thDefault && thDefault.palette && thDefault.palette.accent}`);

  // ── render: 390×844 phone viewport (HUD-fit's exact case), console fully captured ──
  browser = await chromium.launch({
    headless: true, executablePath: findChrome(), chromiumSandbox: false,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--window-size=390,844', ...(FLAGSETS[flagsKey] || FLAGSETS['angle-egl'])],
  });
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  // [S5 offline proof] context-wide: ABORT anything that is not our local servers and record
  // the attempt. Covers EVERY page this context opens (deck, override deck, dashboards) —
  // the deck must render fully green with the outside world unreachable, and the final
  // assert requires that nothing external was even attempted (CDN-free is structural).
  const externalAttempts = [];
  await ctx.route('**/*', (route) => {
    let host = null;
    try { host = new URL(route.request().url()).hostname; } catch {}
    if (host === '127.0.0.1') return route.continue();
    externalAttempts.push(route.request().url());
    return route.abort();
  });
  const page = await ctx.newPage();
  const consoleErrors = [], consoleWarns = [], consoleInfos = [], pageErrors = [];
  // captured text can embed the page URL (which carries ?token=…) — redact before it
  // reaches stdout/logs, the same rule as server.py's request-line redaction.
  const redact = s => String(s).replace(/token=[^&\s\]"']+/g, 'token=REDACTED');
  // Chromium tags GL DRIVER chatter as console warnings (e.g. "[.WebGL-0x…]GL Driver Message
  // (OpenGL, Performance …): GPU stall due to ReadPixels" — fired by the harness's own
  // screenshot readback). That is environment noise, not an app warn-path — filter ONLY that
  // tight signature (counted, reported); every real console.warn (three.js fallbacks etc.) still fails.
  const DRIVER_WARN_RE = /^\[\.WebGL-0x[0-9a-f]+\]GL Driver Message \(OpenGL, Performance\b/i;
  // SwiftShader (the `soft` flagset) logs "CONTEXT_LOST_WEBGL" when a WebGL context is destroyed
  // at page teardown — a deterministic, environment-only driver artifact (see the page.close note
  // below; the deck has no forceContextLoss, and every render/data/theming assert passes above).
  // Same class as DRIVER_WARN_RE → classified as GL-backend noise ONLY under soft; a real-GPU
  // (angle-egl) context loss is NOT tolerated and still fails. Counted + reported, never hidden.
  const CTXLOSS_RE = /^WebGL: CONTEXT_LOST_WEBGL\b/;
  let driverWarns = 0, softCtxLoss = 0;
  page.on('console', m => {
    if (m.type() === 'error') { const loc = m.location() || {}; consoleErrors.push(redact(m.text() + (loc.url ? ` [${loc.url}]` : ''))); }
    // warns captured too (was error/info only) — three.js has console.warn paths (e.g. shader
    // fallbacks) that would otherwise regress invisibly in this proof.
    if (m.type() === 'warning') {
      const loc = m.location() || {};
      if (DRIVER_WARN_RE.test(m.text())) driverWarns++;
      else if (flagsKey === 'soft' && CTXLOSS_RE.test(m.text())) softCtxLoss++;
      else consoleWarns.push(redact(m.text() + (loc.url ? ` [${loc.url}]` : '')));
    }
    if (m.type() === 'info') consoleInfos.push(m.text());
  });
  page.on('pageerror', e => pageErrors.push(redact(e)));
  page.on('response', r => { if (r.status() >= 400) consoleErrors.push(redact(`HTTP ${r.status()} ${r.url()}`)); });

  await page.goto(`${base}/universe?token=${encodeURIComponent(token)}&nointro`, { waitUntil: 'domcontentloaded', timeout: 60000 });
  const rendererName = await page.evaluate(() => {
    const c = document.createElement('canvas');
    const gl = c.getContext('webgl2') || c.getContext('webgl');
    if (!gl) return 'no-webgl';
    const e = gl.getExtension('WEBGL_debug_renderer_info');
    return String(e ? gl.getParameter(e.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER));
  });
  console.log('WEBGL_RENDERER:', rendererName);

  await page.waitForFunction(() => window.__mc && window.__mc.ready === true, null, { timeout: 45000 });
  await page.evaluate(() => { const b = document.getElementById('enter'); if (b) b.click(); });
  await new Promise(r => setTimeout(r, 6000)); // settle: genesis/tunnels build + first frames render

  const snap = await page.evaluate(() => {
    const rect = sel => { const el = document.querySelector(sel); if (!el) return null; const r = el.getBoundingClientRect(); return { left: r.left, right: r.right, top: r.top, bottom: r.bottom, width: r.width }; };
    const t = document.querySelector('#hud .t');
    return {
      usingLive: window.__mc.usingLive, project: window.__mc.state && window.__mc.state.project,
      coreLabel: window.__mc.coreLabel(), galaxies: window.__mc.galaxies(),
      hudTitle: t ? t.textContent : null, hudFont: t ? getComputedStyle(t).fontSize : null,
      hudMax: document.getElementById('hud') ? document.getElementById('hud').style.maxWidth : null,
      rects: { hudT: rect('#hud .t'), nav: rect('#navbtns'), back: rect('#back') },
    };
  });

  check('deck is LIVE off the served state (not demo)', snap.usingLive === true, `usingLive=${snap.usingLive}`);
  check(`core label == state.project ("${expected.project}")`, !!snap.coreLabel && snap.coreLabel.title === expected.project, `coreLabel=${JSON.stringify(snap.coreLabel)}`);
  check('HUD title carries the project name', snap.hudTitle === '⬡ ' + expected.project, `hudTitle=${JSON.stringify(snap.hudTitle)}`);
  check(`galaxy count == distinct done[].theme (${expected.galaxies})`, snap.galaxies.count === expected.galaxies, `got ${snap.galaxies.count} [${snap.galaxies.names.join(', ')}]`);
  check(`star count == done.length (${expected.stars})`, snap.galaxies.stars === expected.stars, `got ${snap.galaxies.stars}`);

  // ── [S4] default theme APPLIED == the shipped organic look, read from the LIVE engine objects
  //    (the real material/pass/fog/CSS values — never the fetch echo). knobs at 1.0 → bloom 0.84.
  const thSnapDefault = await page.evaluate(() => window.__mc.theme ? window.__mc.theme() : null);
  check('default theme: deck applied it LIVE (source=live, zero knobs clamped)',
    !!thSnapDefault && thSnapDefault.source === 'live' && (thSnapDefault.clamped || []).length === 0,
    thSnapDefault ? `source=${thSnapDefault.source} clamped=[${thSnapDefault.clamped}]` : '__mc.theme() missing');
  check('default theme: applied engine values == the shipped organic defaults',
    !!thSnapDefault && !!thSnapDefault.applied
      && thSnapDefault.applied.cssTeal === '#5fa8b0'
      && thSnapDefault.applied.coreMaterial === '#5fa8b0'
      && thSnapDefault.applied.fog === '#0e151f'
      && thSnapDefault.applied.bloomStrength === 0.84
      && thSnapDefault.applied.enterTagline === 'soft mode · the org, in space',
    thSnapDefault && thSnapDefault.applied ? JSON.stringify({ cssTeal: thSnapDefault.applied.cssTeal, core: thSnapDefault.applied.coreMaterial, fog: thSnapDefault.applied.fog, bloom: thSnapDefault.applied.bloomStrength, tagline: thSnapDefault.applied.enterTagline }) : 'no applied read-back');

  // [HUD-fit] no overlap: the title box must end left of BOTH top-right controls (2px guard)
  const hudGuard = (label, rects, extra) => {
    const { hudT, nav, back } = rects;
    let overlapOk = !!hudT, overlapDetail = `hudT.right=${hudT && hudT.right.toFixed(1)}`;
    for (const [nm, r] of [['navbtns', nav], ['back', back]]) {
      if (!r || r.width === 0) continue;
      overlapDetail += ` ${nm}.left=${r.left.toFixed(1)}`;
      if (hudT && hudT.right > r.left - 2) overlapOk = false;
    }
    check(label, overlapOk, `${overlapDetail} ${extra}`);
  };
  hudGuard('390px: HUD title clear of the top-right controls', snap.rects, `font=${snap.hudFont} max=${snap.hudMax}`);

  // [shader-noise] unit-exercise the shader-noise filter's BOTH branches (a box whose software GL
  // links the bloom clean never fires it organically): benign bloom signature → suppressed to ONE
  // info (software GL only); a real shader failure → three's full console.error, always.
  const probe = await page.evaluate(() => {
    const h = window.__uvShaderNoise; if (!h || typeof h.handler !== 'function') return null;
    const calls = { info: 0, error: 0 };
    const oi = console.info, oe = console.error;
    console.info = () => calls.info++; console.error = () => calls.error++;
    const mkgl = src => ({ getShaderSource: () => src, getProgramInfoLog: () => 'log', getShaderInfoLog: () => 'log', getError: () => 0, getProgramParameter: () => false, VALIDATE_STATUS: 1 });
    try {
      h.handler(mkgl('float gaussianPdf(in float x, in float sigma)'), {}, {}, {});  // UnrealBloom blur signature
      h.handler(mkgl('float gaussianPdf(in float x, in float sigma)'), {}, {}, {});  // again — the info must fire ONCE
      const afterBenign = { ...calls };
      h.handler(mkgl('void main(){ /* some real broken shader */ }'), {}, {}, {});   // a real failure
      return { softGL: h.softGL, afterBenign, final: { ...calls } };
    } finally { console.info = oi; console.error = oe; }
  });
  if (probe) {
    const benignOk = probe.softGL
      ? (probe.afterBenign.info === 1 && probe.afterBenign.error === 0)   // software GL: suppressed to one info
      : (probe.afterBenign.info === 0 && probe.afterBenign.error === 2);  // real GPU: NEVER suppressed
    const realOk = probe.final.error === probe.afterBenign.error + 1;      // a real failure always errors
    check(`shader-noise filter: benign bloom ${probe.softGL ? 'suppressed once (soft GL)' : 'NOT suppressed (real GPU)'}`, benignOk, JSON.stringify(probe.afterBenign));
    check('shader-noise filter: a real shader failure still errors', realOk, JSON.stringify(probe.final));
  } else {
    check('shader-noise filter exposed for verification', false, 'window.__uvShaderNoise missing');
  }

  await page.screenshot({ path: outPng });
  console.log('SHOT:', outPng);

  // [HUD-fit → 320px] the review's LOW edge: a fixed 60px maxWidth floor could exceed the real
  // free space on an iPhone SE-class viewport (~1.4px overlap). Resize → fitHudTitle()'s resize
  // listener re-measures; the SAME 2px guard must hold at 320px.
  await page.setViewportSize({ width: 320, height: 568 });
  await new Promise(r => setTimeout(r, 500)); // resize listener + layout settle
  const snap320 = await page.evaluate(() => {
    const rect = sel => { const el = document.querySelector(sel); if (!el) return null; const r = el.getBoundingClientRect(); return { left: r.left, right: r.right, top: r.top, bottom: r.bottom, width: r.width }; };
    const t = document.querySelector('#hud .t');
    return {
      hudFont: t ? getComputedStyle(t).fontSize : null,
      hudMax: document.getElementById('hud') ? document.getElementById('hud').style.maxWidth : null,
      rects: { hudT: rect('#hud .t'), nav: rect('#navbtns'), back: rect('#back') },
    };
  });
  hudGuard('320px (iPhone SE): HUD title clear of the top-right controls', snap320.rects, `font=${snap320.hudFont} max=${snap320.hudMax}`);

  // The main deck page's assertions END here — close it so its observation window ends with
  // them. Load-bearing on software GL: keeping this page's heavy WebGL context alive while
  // the S4 OVERRIDE deck (a second full soft-GL context) renders makes SwiftShader reclaim
  // the idle one — a deterministic, environment-only "CONTEXT_LOST_WEBGL" console warn on
  // the main page that would fail the ZERO-warns tally. One heavy soft-GL page at a time;
  // every main-page event up to this line is already in the tallies asserted below.
  await page.close();

  // ── [S3 opt-in] dashboard link: flag ON → 🌌 visible; flag OFF (twin server) → hidden ──
  // window.__mcConfig is set by dashboard.html the moment its /config fetch settles (any
  // failure → {}), so the hidden/visible assert never races the fetch.
  const linkState = async (b) => {
    const dash = await ctx.newPage();
    await dash.goto(`${b}/?token=${encodeURIComponent(token)}`, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await dash.waitForFunction(() => window.__mcConfig !== undefined, null, { timeout: 15000 });
    const st = await dash.evaluate(() => {
      const a = document.getElementById('modeUniverse');
      // token REDACTED from the reported href — this detail line lands in logs/relays (same rule as server.py's log redaction)
      return a ? { hidden: a.hidden, visible: !!(a.offsetParent || a.getClientRects().length), href: (a.getAttribute('href') || '').replace(/token=[^&]+/, 'token=REDACTED'), cfg: window.__mcConfig } : null;
    });
    await dash.close();
    return st;
  };
  const onLink = await linkState(base);
  check('flag ON: dashboard shows the 🌌 universe link', !!onLink && !onLink.hidden && onLink.visible, JSON.stringify(onLink));

  // the twin server runs with KICKOFF_UNIVERSE UNSET — the shipped default must be OFF
  const serverOff = spawnServer(portOff, false);
  serverOffPid = serverOff.pid;
  const baseOff = `http://127.0.0.1:${portOff}`;
  await waitUp(baseOff, serverOff, portOff);
  const offUnauth = await fetch(`${baseOff}/universe`);
  check('flag OFF: unauth /universe still → 401 (auth precedes the flag — no existence oracle)', offUnauth.status === 401, `got ${offUnauth.status}`);
  const offUni = await fetch(`${baseOff}/universe?token=${encodeURIComponent(token)}`);
  check('flag OFF (default, unset): GET /universe → 404', offUni.status === 404, `got ${offUni.status}`);
  const offCfgRes = await fetch(`${baseOff}/config?token=${encodeURIComponent(token)}`);
  const offCfg = offCfgRes.status === 200 ? await offCfgRes.json() : null;
  check('flag OFF: /config → {"universe":false}', !!offCfg && offCfg.universe === false, `got ${offCfgRes.status} ${JSON.stringify(offCfg)}`);
  const offBoard = await fetch(`${baseOff}/?token=${encodeURIComponent(token)}`);
  check('flag OFF: the 2D board still serves (GET / → 200)', offBoard.status === 200, `got ${offBoard.status}`);
  const offTheme = await fetch(`${baseOff}/universe-theme?token=${encodeURIComponent(token)}`);
  check('flag OFF: GET /universe-theme → 404 (same gate as the deck — no capability, no routes)', offTheme.status === 404, `got ${offTheme.status}`);
  const offVendor = await fetch(`${baseOff}/vendor/three/build/three.module.js`);
  check('flag OFF: GET /vendor/* → 404 (the deck is its only consumer)', offVendor.status === 404, `got ${offVendor.status}`);
  const offLink = await linkState(baseOff);
  check('flag OFF: dashboard hides the 🌌 universe link', !!offLink && offLink.hidden === true && !offLink.visible, JSON.stringify(offLink));
  await killPid(serverOffPid); serverOffPid = null;

  // ══ [S4 theming] the OVERRIDE server — REAL adopter wiring (theme DERIVED from the .kickoff
  //    ancestor of KICKOFF_STATE, no env override): retint applies, invalid color falls back,
  //    out-of-bounds knobs clamp, non-overridden keys keep defaults, the data pipeline is untouched. ══
  const serverTheme = spawnServer(portTheme, true, nestedState);
  serverThemePid = serverTheme.pid;
  const baseTheme = `http://127.0.0.1:${portTheme}`;
  await waitUp(baseTheme, serverTheme, portTheme);
  const ovRes = await fetch(`${baseTheme}/universe-theme?token=${encodeURIComponent(token)}`);
  const ovJson = ovRes.status === 200 ? await ovRes.json() : null;
  check('override: server DERIVED .kickoff/universe.theme.json from the state path (accent #a78bfa served)',
    !!ovJson && ovJson.palette && ovJson.palette.accent === '#a78bfa',
    `got ${ovRes.status} accent=${ovJson && ovJson.palette && ovJson.palette.accent}`);

  const pageOv = await ctx.newPage();
  const ovErrors = [], ovWarns = [];
  pageOv.on('console', m => {
    if (m.type() === 'error') ovErrors.push(redact(m.text()));
    if (m.type() === 'warning' && !DRIVER_WARN_RE.test(m.text())) ovWarns.push(redact(m.text()));
  });
  pageOv.on('pageerror', e => ovErrors.push(redact(e)));
  pageOv.on('response', r => { if (r.status() >= 400) ovErrors.push(redact(`HTTP ${r.status()} ${r.url()}`)); });
  await pageOv.goto(`${baseTheme}/universe?token=${encodeURIComponent(token)}&nointro`, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await pageOv.waitForFunction(() => window.__mc && window.__mc.ready === true, null, { timeout: 45000 });
  await pageOv.evaluate(() => { const b = document.getElementById('enter'); if (b) b.click(); });
  await new Promise(r => setTimeout(r, 6000)); // settle: genesis/tunnels build + first frames render

  const ov = await pageOv.evaluate(() => {
    const t = window.__mc.theme ? window.__mc.theme() : null;
    const sig = document.getElementById('enterSig');
    return t && {
      source: t.source, clamped: (t.clamped || []).slice().sort(), knobs: t.knobs, strings: t.strings,
      accentWarm: t.palette.accentWarm, applied: t.applied,
      galaxies: window.__mc.galaxies(),
      enterSig: sig ? { text: sig.textContent, shown: sig.style.display !== 'none' } : null,
    };
  });
  const ovA = ov && ov.applied;
  check('override: retint APPLIED to the live engine (CSS var + core material + fog)',
    !!ovA && ovA.cssTeal === '#a78bfa' && ovA.coreMaterial === '#a78bfa' && ovA.fog === '#140a20',
    ovA ? JSON.stringify({ cssTeal: ovA.cssTeal, core: ovA.coreMaterial, fog: ovA.fog }) : 'no read-back');
  check('override: bloom strength follows the knob (0.84 × 1.25 = 1.05)',
    !!ovA && ovA.bloomStrength === 1.05, ovA ? `got ${ovA.bloomStrength}` : 'no read-back');
  check('override: galaxy hues cycle the 3 THEME hues only',
    !!ovA && ovA.galaxyHues.length > 0 && ovA.galaxyHues.every(h => ['#a78bfa', '#f0a0c0', '#7fd0c8'].includes(h)),
    ovA ? `hues=[${[...new Set(ovA.galaxyHues)].join(',')}]` : 'no read-back');
  check('override GUARDRAIL: out-of-bounds knobs CLAMPED (particleDensity 9.9→2, starSize 0.1→0.6)',
    !!ov && ov.clamped.join(',') === 'particleDensity,starSize' && ov.knobs.particleDensity === 2 && ov.knobs.starSize === 0.6,
    ov ? `clamped=[${ov.clamped}] density=${ov.knobs.particleDensity} star=${ov.knobs.starSize}` : 'no read-back');
  check('override GUARDRAIL: invalid color STRICT-PARSED → falls back to the default (#d99a5c)',
    !!ov && ov.accentWarm === '#d99a5c', ov ? `accentWarm=${ov.accentWarm}` : 'no read-back');
  check('override: non-overridden keys keep the shipped defaults (tunnel birth #fff1d6)',
    !!ovA && ovA.tunnelBirth === '#fff1d6', ovA ? `tunnelBirth=${ovA.tunnelBirth}` : 'no read-back');
  check('override: themed strings land via textContent (tagline + signature + genesisLabel)',
    !!ov && ovA.enterTagline === 'the override cosmos' && ov.strings.genesisLabel === 'Slack'
      && !!ov.enterSig && ov.enterSig.text === 'themed by the selftest' && ov.enterSig.shown === true,
    ov ? JSON.stringify({ tagline: ovA.enterTagline, genesis: ov.strings.genesisLabel, sig: ov.enterSig }) : 'no read-back');
  check('override: the DATA pipeline is untouched (same galaxy/star counts as the state)',
    !!ov && ov.galaxies.count === expected.galaxies && ov.galaxies.stars === expected.stars,
    ov ? `galaxies=${ov.galaxies.count}/${expected.galaxies} stars=${ov.galaxies.stars}/${expected.stars}` : 'no read-back');
  check('override page: ZERO console/page errors + warns', ovErrors.length === 0 && ovWarns.length === 0,
    (ovErrors.length || ovWarns.length) ? [...ovErrors, ...ovWarns].slice(0, 3).join(' | ').slice(0, 400) : 'clean');
  await pageOv.screenshot({ path: outPngOverride });
  console.log('SHOT (override):', outPngOverride);
  await pageOv.close();
  await killPid(serverThemePid); serverThemePid = null;

  check('[S5] ZERO external requests attempted (deck + override + dashboards, offline-proof)',
    externalAttempts.length === 0,
    externalAttempts.length ? externalAttempts.slice(0, 3).join(' | ').slice(0, 300) : 'every request stayed on 127.0.0.1');
  check('ZERO console errors', consoleErrors.length === 0, consoleErrors.length ? consoleErrors.slice(0, 3).join(' | ').slice(0, 500) : 'clean');
  check('ZERO console warns', consoleWarns.length === 0, consoleWarns.length ? consoleWarns.slice(0, 3).join(' | ').slice(0, 500) : `clean${driverWarns ? ` (${driverWarns} benign GL-driver perf messages filtered)` : ''}${softCtxLoss ? ` (${softCtxLoss} SwiftShader teardown context-loss filtered — soft GL only)` : ''}`);
  check('ZERO page errors', pageErrors.length === 0, pageErrors.slice(0, 2).join(' | ').slice(0, 300));
  const bloomNote = consoleInfos.find(s => /software-GL bloom shader/i.test(s));
  console.log('bloom-suppression info fired:', bloomNote ? 'yes (software-GL path exercised)' : 'no (real GPU or shaders linked clean)');
} catch (e) {
  failed = true;
  console.log('ERROR:', e.message);
} finally {
  if (browser) await browser.close().catch(() => {});
  await killPid(serverPid);
  await killPid(serverOffPid);     // exact PID; null if never spawned / already reaped
  await killPid(serverThemePid);   // exact PID; null if never spawned / already reaped
  try { rmSync(scratch, { recursive: true, force: true }); } catch {}   // the whole scratch tree (state copies, locks, .kickoff override)
}

const bad = results.filter(r => !r.ok).length;
console.log(`\nRESULT: ${results.length - bad}/${results.length} checks passed${bad ? ' — ' + bad + ' FAILED' : ''} (state=${path.basename(stateFile)}, gl=${flagsKey}, port=${port})`);
process.exit(failed || bad ? 1 : 0);
