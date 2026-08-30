#!/usr/bin/env node

// log-stats.mjs — summarize the live retrieval log (retrieval-log.jsonl).
//
// The hook appends one JSON line per fire. This is the LIVE half of "does it
// work": offline eval measures retrieval quality on a fixed labelled set;
// the live log measures what's actually happening in real usage —
//   • how often the hook fires
//   • how often the cutoff SUPPRESSES (high suppression on real traffic is
//     healthy: most turns don't need a memory; runaway suppression on turns that
//     SHOULD match means the cutoff is too tight)
//   • the average number of memories surfaced when it does fire
//   • which memories surface most (are a few facts dominating? dead facts?)
//
// Usage:  ./run.sh log-stats   (or: node log-stats.mjs [path])

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const path = process.argv[2] || join(import.meta.dirname ?? ".", "retrieval-log.jsonl");

if (!existsSync(path)) {
  console.log(`No log at ${path} — the hook hasn't fired yet (or logging is off).`);
  process.exit(0);
}

const lines = readFileSync(path, "utf8")
  .split("\n")
  .map((l) => l.trim())
  .filter(Boolean);

const entries = [];
for (const l of lines) {
  try {
    entries.push(JSON.parse(l));
  } catch {
    /* skip malformed line */
  }
}

const total = entries.length;
const suppressed = entries.filter((e) => e.suppressed);
const fired = entries.filter((e) => !e.suppressed);
const surfacedCounts = fired.map((e) => (e.surfaced || []).length);
const avgSurfaced = surfacedCounts.length
  ? surfacedCounts.reduce((a, b) => a + b, 0) / surfacedCounts.length
  : 0;

// Suppression reasons (why nothing surfaced).
const reasonTally = {};
for (const e of suppressed) {
  const r = (e.reason || "unknown").replace(/\(.*\)/, "(…)"); // collapse numeric detail
  reasonTally[r] = (reasonTally[r] || 0) + 1;
}

// Which memories surface most across fires.
const memTally = {};
for (const e of fired) {
  for (const s of e.surfaced || []) memTally[s.slug] = (memTally[s.slug] || 0) + 1;
}
const topMems = Object.entries(memTally)
  .sort((a, b) => b[1] - a[1])
  .slice(0, 10);

const line = "─".repeat(64);
console.log("═".repeat(64));
console.log("LIVE RETRIEVAL LOG — SUMMARY");
console.log(`source: ${path}`);
console.log("═".repeat(64));
console.log(`fires (total turns logged): ${total}`);
console.log(
  `  surfaced memory:          ${fired.length}  (${total ? ((fired.length / total) * 100).toFixed(1) : 0}%)`,
);
console.log(
  `  suppressed by cutoff:     ${suppressed.length}  (${total ? ((suppressed.length / total) * 100).toFixed(1) : 0}%)`,
);
console.log(`  avg memories surfaced/fire (when it fired): ${avgSurfaced.toFixed(2)}`);

if (Object.keys(reasonTally).length) {
  console.log(`\n${line}`);
  console.log("suppression reasons:");
  for (const [r, n] of Object.entries(reasonTally).sort((a, b) => b[1] - a[1])) {
    console.log(`  ${String(n).padStart(4)}  ${r}`);
  }
}

if (topMems.length) {
  console.log(`\n${line}`);
  console.log("most-surfaced memories:");
  for (const [slug, n] of topMems) {
    console.log(`  ${String(n).padStart(4)}  ${slug}`);
  }
}

if (entries[0]?.ts && entries[total - 1]?.ts) {
  console.log(`\n${line}`);
  console.log(`window: ${entries[0].ts}  →  ${entries[total - 1].ts}`);
}
console.log("═".repeat(64));
