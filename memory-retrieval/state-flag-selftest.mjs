#!/usr/bin/env node
// state-flag-selftest.mjs — memory-lifecycle M1 (Truth): the recall hook flags a
// STATE-BEARING memory ("verify it's still true before acting") so a stale
// pending/blocked/open fact can't be acted on blind.
//
// hook.mjs runs main() at import (it's a command, not a library), so we can't
// import its helper. Instead we extract the TWO real regex literals straight from
// the source and test their behaviour — no drift (the patterns under test ARE the
// shipped ones), deterministic (no live corpus), fast.
//
//   node memory-retrieval/state-flag-selftest.mjs
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(HERE, "hook.mjs"), "utf8");

function extract(name) {
  // match:  const NAME = /.../flags;   (no nested slash beyond delimiters + flags)
  const m = src.match(new RegExp(`const ${name} = (/[^\\n]*?/[a-z]*);`));
  if (!m) throw new Error(`could not find ${name} in hook.mjs — did the flag get renamed/removed?`);
  // eval a single controlled source-literal from our own repo (not untrusted input)
  // eslint-disable-next-line no-eval
  return eval(m[1]);
}

const STATE_WORD_RE = extract("STATE_WORD_RE");
const STATE_MARK_RE = extract("STATE_MARK_RE");
const isStateBearing = (hay) => STATE_WORD_RE.test(hay) || STATE_MARK_RE.test(hay);

let pass = 0;
let fail = 0;
const ok = (cond, msg) => (cond ? (pass++, console.log(`  ✓ ${msg}`)) : (fail++, console.log(`  ✗ ${msg}`)));

// ── MUST flag (real pending/open state) ──────────────────────────────────────
for (const [hay, why] of [
  ["the turnkey install is still pending the operator's run", "pending"],
  ["blocked on the ruleset review", "blocked"],
  ["slice LOW debt register", "debt"],
  ["this is still unresolved", "unresolved"],
  ["TODO: reconcile the drift", "TODO marker"],
  ["an OPEN tap awaiting the operator", "OPEN marker"],
  ["WIP — do not rely on this yet", "WIP marker"],
  ["PENDING approval", "case-insensitive state word"],
]) {
  ok(isStateBearing(hay), `flags state-bearing: "${hay}"  (${why})`);
}

// ── MUST NOT flag (no live state) ────────────────────────────────────────────
for (const [hay, why] of [
  ["an open source project on github", "'open source' — uppercase-only marker must not fire"],
  ["she opened the file and read it", "'opened' — not a whole-word state marker"],
  ["a settled fact with no pending state at all… wait", "contains 'pending' → SHOULD flag"], // trap: see below
  ["the deploy is green and complete", "no state word"],
  ["the render is not the device", "durable lesson, no state"],
]) {
  // the third entry deliberately contains "pending" — it MUST flag; the rest must not.
  const expect = /\bpending\b/i.test(hay);
  ok(isStateBearing(hay) === expect, `${expect ? "flags" : "does NOT flag"}: "${hay}"  (${why})`);
}

// ── wiring guard: the flag must be EMITTED by formatBlock, not merely defined ──
ok(
  /records pending\/open state/.test(src) && /STATE_WORD_RE\.test\(stateHay\)/.test(src),
  "formatBlock actually emits the flag (pattern defined AND wired into the render loop)",
);

console.log(`\n  ${pass} passed, ${fail} failed`);
if (fail === 0) console.log("  ✅ state-bearing flag pattern holds (fires on state, quiet on 'open source')");
process.exit(fail === 0 ? 0 : 1);
