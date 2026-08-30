#!/usr/bin/env node --experimental-sqlite
// private-corpus-selftest.mjs — RED-first proof that listMemoryFiles indexes a
// gitignored `<memory>/private/` subdir alongside the public corpus.
//
// This is what lets "no private info tracked in the public repo" coexist with
// "the memory indexer still recalls the private facts": private memories live in
// `memory/private/` (gitignored, never pushed) but stay on disk, and the indexer
// reads the FILESYSTEM (readdirSync), not git — so a gitignored file indexes
// exactly like a tracked one. If this test goes red, private recall is broken.
//
// Usage: node --experimental-sqlite memory-retrieval/private-corpus-selftest.mjs
import { mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { listMemoryFiles } from "./lib/memory.mjs";

let failed = 0;
const eq = (got, want, label) => {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) { console.log(`  ✓ ${label}`); }
  else { console.log(`  ✗ ${label}\n      got:  ${g}\n      want: ${w}`); failed++; }
};

// A deterministic scratch dir (no Math.random / Date.now — those are unavailable
// in some harness contexts and break reproducibility). Cleaned before + after.
const base = join(tmpdir(), "kickoff-private-corpus-selftest");
rmSync(base, { recursive: true, force: true });
mkdirSync(base, { recursive: true });

const rel = (files) => files.map((f) => f.slice(base.length + 1)).sort();

// ── Case 1 (negative control): NO private/ subdir → only the public file,
//    and the MEMORY.md roll-up is skipped. Proves the change didn't widen the
//    public path.
writeFileSync(join(base, "public-a.md"), "---\nname: public-a\n---\nbody");
writeFileSync(join(base, "MEMORY.md"), "roll-up index — must be skipped");
writeFileSync(join(base, "._apple.md"), "AppleDouble sidecar — must be skipped");
eq(rel(listMemoryFiles(base)), ["public-a.md"],
   "no private/ → only the public fact (MEMORY.md + ._ sidecar skipped)");

// ── Case 2: WITH a private/ subdir → BOTH the public and the private fact are
//    indexed. This is the whole point — a gitignored private memory still recalls.
mkdirSync(join(base, "private"), { recursive: true });
writeFileSync(join(base, "private", "secret-b.md"), "---\nname: secret-b\n---\nbody");
writeFileSync(join(base, "private", "MEMORY.md"), "must be skipped in private/ too");
eq(rel(listMemoryFiles(base)), ["private/secret-b.md", "public-a.md"],
   "private/ fact IS indexed alongside the public one (private MEMORY.md skipped)");

// ── Case 3: an EMPTY private/ dir is harmless (no crash, public-only result).
rmSync(join(base, "private"), { recursive: true, force: true });
mkdirSync(join(base, "private"), { recursive: true });
eq(rel(listMemoryFiles(base)), ["public-a.md"],
   "empty private/ dir → public-only, no crash");

rmSync(base, { recursive: true, force: true });

if (failed) { console.log(`\n✗ ${failed} check(s) failed`); process.exit(1); }
console.log("\n✅ private-corpus-selftest: 3/3 — gitignored private/ recalls, public path unchanged");
