#!/usr/bin/env node
// gpu-render.mjs — render a URL on the box's NVIDIA GPU (real bloom/glow) and report the
// WebGL renderer + screenshot. Requires the GPU GL libs (scripts/enable-gpu-gl.sh) + playwright.
//
// Usage: NODE_PATH=<your-app>/node_modules node scripts/gpu-render.mjs <url> <outPng> [flagset]
// CONFIRMED 2026-06-28: flagset 'angle-egl' → "ANGLE (NVIDIA GeForce …)" on a discrete NVIDIA GPU, full bloom.
// NOTE: use the FULL chromium (chromium-*), not chrome-headless-shell, for GPU. The chrome-devtools
// MCP browser is launched once at session start (pre-fix) so it can stay on swiftshader — use THIS.
import { createRequire } from 'node:module';
import { existsSync, readdirSync } from 'node:fs';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

function findChrome() {
  const home = process.env.HOME || require('node:os').homedir();
  const base = process.env.PLAYWRIGHT_BROWSERS_PATH || `${home}/.cache/ms-playwright`;
  try {
    for (const d of readdirSync(base)) {
      if (d.startsWith('chromium-') && !d.includes('headless')) {
        const p = `${base}/${d}/chrome-linux64/chrome`;
        if (existsSync(p)) return p;
      }
    }
  } catch {}
  return undefined; // let playwright pick its default
}

const url = process.argv[2] || 'http://127.0.0.1:9319/3d-deck.jarvis.html';
const out = process.argv[3] || '/tmp/gpu-render.png';
const flagsKey = process.argv[4] || 'angle-egl';
const FLAGSETS = {
  'angle-egl': ['--use-gl=angle','--use-angle=gl-egl','--ignore-gpu-blocklist','--enable-gpu-rasterization'],
  'egl':       ['--use-gl=egl','--ignore-gpu-blocklist','--enable-gpu-rasterization'],
};

const browser = await chromium.launch({
  headless: true,
  executablePath: findChrome(),
  chromiumSandbox: false,
  args: ['--no-sandbox','--disable-setuid-sandbox','--window-size=390,844', ...(FLAGSETS[flagsKey] || FLAGSETS['angle-egl'])],
});
try {
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  const page = await ctx.newPage();
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
  const info = await page.evaluate(() => {
    const c = document.createElement('canvas');
    const gl = c.getContext('webgl2') || c.getContext('webgl');
    if (!gl) return { err: 'no webgl context' };
    const e = gl.getExtension('WEBGL_debug_renderer_info');
    return { renderer: e ? gl.getParameter(e.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER) };
  });
  console.log('WEBGL_RENDERER:', info.renderer || JSON.stringify(info));
  console.log('GPU_ACTIVE:', !/swiftshader|software|llvmpipe/i.test(JSON.stringify(info)));
  await page.evaluate(() => { const b = document.getElementById('enter') || [...document.querySelectorAll('*')].find(x => /tap to enter/i.test(x.textContent || '')); if (b) b.click(); });
  await new Promise(r => setTimeout(r, 5500));
  await page.screenshot({ path: out });
  console.log('SHOT:', out);
} catch (e) {
  console.log('ERROR:', e.message);
} finally {
  await browser.close();
}
