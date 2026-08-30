#!/usr/bin/env node

// eval.mjs — the METRICS / EVAL HARNESS.
//
// "Ground it in metrics so we know if it works." This is the offline measurement
// of retrieval QUALITY: does the right memory actually surface for a realistic
// decision-time query? It runs the labelled set in eval-set.json against the
// retriever and reports, per config:
//
//   • recall@K (K=1,3,5) — fraction of cases where the expected memory is in top-K.
//     recall@1 is the one that matters most for the HOOK: with TOP_K small, a
//     memory that isn't #1–#3 won't be injected.
//   • MRR (Mean Reciprocal Rank) — average of 1/rank of the expected memory
//     (0 if missed). Rewards ranking the right memory HIGH, not just somewhere.
//   • per-case pass/fail at K=3 (the hook's default injection depth).
//   • noise suppression — for expected:null cases, the eval applies the SAME
//     cutoff the hook uses; a noise case "passes" iff the cutoff suppresses it.
//
// It runs MULTIPLE CONFIGS so the numbers are COMPARABLE:
//   • keyword  — BM25 only (the baseline)
//   • hybrid   — keyword ⊕ vector (today: vector arm is the lexical stub)
// The keyword↔hybrid delta is the honest read on what the vector arm adds. Re-run
// after wiring a real embedder (set OPENAI_API_KEY, ./run.sh index) and the
// hybrid column should move — THAT delta is the value of real semantics.
//
// Usage:
//   ./run.sh eval                 # both configs, full report
//   ./run.sh eval --json          # machine-readable aggregates
//   ./run.sh eval --config hybrid # single config

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { buildIndex } from "./index.mjs";
import { DEFAULT_DB_PATH } from "./lib/memory.mjs";
import { retrieve } from "./retrieve.mjs";

// The labelled set. Defaults to eval-set.json next to this script; override with
// MEMORY_EVAL_SET to point the harness at a different set (e.g. a per-repo one)
// without renaming the file.
const EVAL_SET = process.env.MEMORY_EVAL_SET || join(import.meta.dirname ?? ".", "eval-set.json");
const KS = [1, 3, 5];
const POOL_K = 5; // retrieve depth — must be ≥ max(KS)

// The cutoff the HOOK applies, mirrored here so the eval measures the real
// surfaced behaviour. Defaults mirror the LIVE floors in .claude/settings.json
// (BM25 -8.0 / VEC 0.23) — NOT hook.mjs's looser *code* defaults (-5.0 / 0.3) —
// so a bare `./run.sh eval` reflects PRODUCTION, not a stricter-noise illusion.
// (A prior measurement at the code defaults read noise 2/4 when live was 4/4.)
// Keep these in sync with settings.json; override via the MEMORY_HOOK_*_FLOOR env vars.
const RRF_FLOOR = Number(process.env.MEMORY_HOOK_RRF_FLOOR || 0.016);
const BM25_FLOOR = Number(process.env.MEMORY_HOOK_BM25_FLOOR || -8.0);
const VEC_FLOOR = Number(process.env.MEMORY_HOOK_VEC_FLOOR || 0.23);

function rankOf(results, slug) {
  const i = results.findIndex((r) => r.slug === slug);
  return i === -1 ? null : i + 1;
}

/** Does the hook's cutoff surface anything? (mirror of hook.mjs evaluateCutoff) */
function cutoffSurfaces(results, meta) {
  if (results.length === 0) return false;
  const top = results[0];
  if (top.rrf < RRF_FLOOR) return false;
  if (meta.keywordHits === 0) return false;
  // Pool-wide strength gate (mirror of hook.mjs): surface iff SOME hit clears a
  // strength bar on either arm — not just hit #1.
  let bestBm25 = Number.POSITIVE_INFINITY;
  let bestVec = Number.NEGATIVE_INFINITY;
  for (const r of results) {
    const kw = r.contributions?.keyword?.score;
    const vec = r.contributions?.vector?.score;
    if (kw !== undefined && kw < bestBm25) bestBm25 = kw;
    if (vec !== undefined && vec > bestVec) bestVec = vec;
  }
  const strongKeyword = Number.isFinite(bestBm25) && bestBm25 <= BM25_FLOOR;
  const strongVector = meta.semantic && Number.isFinite(bestVec) && bestVec >= VEC_FLOOR;
  return strongKeyword || strongVector;
}

async function runConfig(cases, mode) {
  const positives = cases.filter((c) => c.expect !== null);
  const noise = cases.filter((c) => c.expect === null);

  const rows = [];
  let rrSum = 0; // reciprocal-rank sum over positives (for MRR)
  const recallHits = Object.fromEntries(KS.map((k) => [k, 0]));

  for (const c of positives) {
    const { results } = await retrieve(c.query, { k: POOL_K, mode });
    const rank = rankOf(results, c.expect);
    const rr = rank ? 1 / rank : 0;
    rrSum += rr;
    for (const k of KS) if (rank && rank <= k) recallHits[k]++;
    rows.push({
      kind: "positive",
      query: c.query,
      expect: c.expect,
      rank,
      rr,
      pass3: !!(rank && rank <= 3),
      top: results.slice(0, 3).map((r) => r.slug),
    });
  }

  // Noise cases: "pass" == the cutoff suppresses (surfaces nothing).
  let noiseSuppressed = 0;
  for (const c of noise) {
    const { results, meta } = await retrieve(c.query, { k: POOL_K, mode });
    const surfaced = cutoffSurfaces(results, meta);
    if (!surfaced) noiseSuppressed++;
    rows.push({
      kind: "noise",
      query: c.query,
      expect: null,
      suppressed: !surfaced,
      pass3: !surfaced,
      top: surfaced ? results.slice(0, 3).map((r) => r.slug) : [],
    });
  }

  const n = positives.length;
  return {
    mode,
    n,
    recall: Object.fromEntries(KS.map((k) => [k, recallHits[k] / n])),
    mrr: rrSum / n,
    noise: { total: noise.length, suppressed: noiseSuppressed },
    rows,
  };
}

function pct(x) {
  return `${(x * 100).toFixed(1)}%`;
}

function printReport(configs, semantic) {
  const line = "─".repeat(78);
  console.log("═".repeat(78));
  console.log("MEMORY RETRIEVAL — OFFLINE EVAL");
  console.log(
    `vector arm: ${semantic ? "REAL semantic embeddings" : "STUB lexical (no embedder wired)"}`,
  );
  console.log("═".repeat(78));

  // ── Aggregate table (the headline numbers) ──
  console.log("\nHEADLINE — recall@K + MRR, per config (positives only):\n");
  const header = ["config", "n", "recall@1", "recall@3", "recall@5", "MRR", "noise-suppress"];
  const widths = [10, 4, 9, 9, 9, 7, 14];
  const fmtRow = (cells) => cells.map((c, i) => String(c).padEnd(widths[i])).join("");
  console.log(fmtRow(header));
  console.log(line);
  for (const cfg of configs) {
    console.log(
      fmtRow([
        cfg.mode,
        cfg.n,
        pct(cfg.recall[1]),
        pct(cfg.recall[3]),
        pct(cfg.recall[5]),
        cfg.mrr.toFixed(3),
        `${cfg.noise.suppressed}/${cfg.noise.total}`,
      ]),
    );
  }

  // ── Per-case detail for the richest config (hybrid if present) ──
  const detail = configs.find((c) => c.mode === "hybrid") ?? configs[0];
  console.log(`\n${line}`);
  console.log(`PER-CASE (config: ${detail.mode}) — rank of the expected memory:\n`);
  for (const r of detail.rows.filter((x) => x.kind === "positive")) {
    const mark = r.rank === 1 ? "✅ #1" : r.rank ? `▲ #${r.rank}` : "✗ MISS";
    console.log(`  ${mark.padEnd(8)} ${r.expect}`);
    console.log(`     q: "${r.query}"`);
    if (r.rank !== 1) console.log(`     top3: ${r.top.join(", ")}`);
  }
  const noiseRows = detail.rows.filter((x) => x.kind === "noise");
  if (noiseRows.length) {
    console.log(`\n  NOISE (cutoff must suppress):`);
    for (const r of noiseRows) {
      const mark = r.suppressed ? "✅ suppressed" : "✗ LEAKED";
      console.log(`  ${mark.padEnd(14)} "${r.query}"`);
      if (!r.suppressed) console.log(`     leaked: ${r.top.join(", ")}`);
    }
  }

  // ── Delta read (keyword → hybrid) ──
  const kw = configs.find((c) => c.mode === "keyword");
  const hy = configs.find((c) => c.mode === "hybrid");
  if (kw && hy) {
    console.log(`\n${line}`);
    console.log("DELTA — keyword-only → hybrid (what the vector arm changes):");
    const d1 = (hy.recall[1] - kw.recall[1]) * 100;
    const d3 = (hy.recall[3] - kw.recall[3]) * 100;
    const dm = hy.mrr - kw.mrr;
    const sign = (x) => (x > 0 ? `+${x.toFixed(1)}` : x.toFixed(1));
    console.log(`  recall@1: ${sign(d1)}pp   recall@3: ${sign(d3)}pp   MRR: ${sign(dm)}`);
    console.log(
      semantic
        ? "  (real embeddings — this delta is the semantic recall gain)"
        : "  NOTE: vector arm is the LEXICAL STUB. A near-zero/negative delta here is\n" +
            "  EXPECTED — the stub only reinforces lexical overlap and can even dilute a\n" +
            "  clean keyword #1. Wire a real embedder (OPENAI_API_KEY + ./run.sh index)\n" +
            "  and re-run; the hybrid column is where synonym/paraphrase recall shows up.",
    );
  }
  console.log("═".repeat(78));
}

async function main() {
  const args = process.argv.slice(2);
  const asJson = args.includes("--json");
  const cfgArg = args.indexOf("--config");
  const only = cfgArg !== -1 ? args[cfgArg + 1] : null;

  if (!existsSync(DEFAULT_DB_PATH)) {
    if (!asJson) console.log("No index found — building it first...\n");
    await buildIndex({ quiet: asJson });
  }

  const set = JSON.parse(readFileSync(EVAL_SET, "utf8"));
  const cases = set.cases;

  // Detect whether the index used a real embedder (for honest labelling).
  const { meta } = await retrieve("probe", { k: 1 });
  const semantic = meta.semantic;

  const modes = only ? [only] : ["keyword", "hybrid"];
  const configs = [];
  for (const mode of modes) configs.push(await runConfig(cases, mode));

  if (asJson) {
    const slim = configs.map((c) => ({
      mode: c.mode,
      n: c.n,
      recall: c.recall,
      mrr: c.mrr,
      noise: c.noise,
    }));
    console.log(JSON.stringify({ semantic, rrfFloor: RRF_FLOOR, configs: slim }, null, 2));
  } else {
    printReport(configs, semantic);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
