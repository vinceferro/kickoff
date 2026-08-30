#!/usr/bin/env node
// demo.mjs — DEMONSTRATE THE WIN.
//
// Shows the retriever PROACTIVELY surfacing the right memory at decision-time —
// the moment a flat MEMORY.md scan misses because the query words don't appear
// verbatim in the one-line index entry.
//
// THE motivating example (real): a headless-Chromium screenshot was treated as proof
// that a UI worked on a phone. The memory saying exactly why that's a lie ("the render
// is not the device") existed but wasn't surfaced at decision-time. This demo poses
// that decision as a query and shows the retriever rank that memory #1.
//
// NOTE — these QUERIES + TARGET run against KICKOFF'S OWN memory/ corpus, so they are
// reproducible: clone, `./run.sh index`, `./run.sh demo`, and see the ranks below. (The
// published METRICS.md numbers were measured on a larger PRIVATE corpus that does not
// ship — see its note.) To demo against YOUR corpus, swap the QUERIES array + TARGET
// for your own slugs — or use `./run.sh retrieve "..."` / `./run.sh eval` (with your
// own eval-set.json) for a corpus-agnostic check.
//
// Usage:  node --experimental-sqlite demo.mjs   (or ./run.sh demo)

import { existsSync } from "node:fs";
import { buildIndex } from "./index.mjs";
import { DEFAULT_DB_PATH } from "./lib/memory.mjs";
import { neighbors, retrieve } from "./retrieve.mjs";

const TARGET = "the-render-is-not-the-device"; // a screenshot is not the target engine

const QUERIES = [
  {
    q: "is a headless chromium shot enough to say it works on his iphone",
    why: "THE motivating case — should surface 'the render is not the device'. The query says 'chromium'/'iphone'; the memory says neither.",
    expect: TARGET,
  },
  {
    q: "can I send him the api key in a message",
    why: "Paraphrase — the fact is about relaying a CREDENTIAL through the CHANNEL; the query says 'api key' and 'message'.",
    expect: "credential-guard-blocks-channel-relay",
  },
  {
    q: "he said the build looks broken, should I add a workaround",
    why: "Intent recall — 'workaround' should surface the rule against local hacks over fixing the shared source.",
    expect: "fix-the-shared-source-not-a-local-hack",
  },
  {
    q: "should I kill all the node processes to free up the box",
    why: "Situation → constraint — the host is the real ceiling; the query never says 'concurrency' or 'load'.",
    expect: "the-machine-is-the-real-ceiling",
  },
];

function rankOf(results, slug) {
  const i = results.findIndex((r) => r.slug === slug);
  return i === -1 ? null : i + 1;
}

async function main() {
  if (!existsSync(DEFAULT_DB_PATH)) {
    console.log("No index found — building it first...\n");
    await buildIndex({ quiet: false });
    console.log("");
  }

  console.log("═".repeat(78));
  console.log("HYBRID MEMORY RETRIEVAL — DEMO");
  console.log("═".repeat(78));

  let hits = 0;
  for (const { q, why, expect } of QUERIES) {
    const { results, meta } = await retrieve(q, { k: 5 });
    const rank = rankOf(results, expect);
    const ok = rank === 1 ? "✅ #1" : rank ? `▲ #${rank}` : "✗ MISS";
    if (rank === 1) hits++;
    const kwRank = meta.keywordOnly.indexOf(expect);
    const kwTag = kwRank === -1 ? "miss" : `#${kwRank + 1}`;

    console.log(`\n${"─".repeat(78)}`);
    console.log(`QUERY:    "${q}"`);
    console.log(`WHY:      ${why}`);
    console.log(
      `EXPECT:   ${expect}  →  hybrid ${ok} | keyword-only ${kwTag}` +
        `   (vector arm: ${meta.semantic ? "REAL" : "STUB-lexical"})`,
    );
    console.log("TOP 5:");
    results.forEach((r, i) => {
      const star = r.slug === expect ? " ◀── target" : "";
      const arms = Object.keys(r.contributions).join("+");
      console.log(`   ${i + 1}. [${r.type}] ${r.slug}  (rrf=${r.rrf.toFixed(4)}, ${arms})${star}`);
    });
  }

  // GRAPH demo: from the chrome-principle fact, walk its [[cross-links]].
  console.log(`\n${"═".repeat(78)}`);
  console.log(`GRAPH TRAVERSAL — neighbours of ${TARGET}`);
  console.log("═".repeat(78));
  const { outgoing, incoming } = neighbors(TARGET);
  console.log(`outgoing [[links]] (${outgoing.length}):`);
  for (const n of outgoing) {
    const resolved = n.name ? "" : "  (dangling — no such file)";
    console.log(`   → ${n.slug}${resolved}`);
  }
  console.log(`incoming back-links (${incoming.length}):`);
  for (const n of incoming) console.log(`   ← ${n.slug}`);

  console.log(`\n${"═".repeat(78)}`);
  console.log(`RESULT: ${hits}/${QUERIES.length} target memories ranked #1 by hybrid retrieval.`);
  console.log("═".repeat(78));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
