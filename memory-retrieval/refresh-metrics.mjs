#!/usr/bin/env node

// refresh-metrics.mjs — keep the recall figure CURRENT, never a hand-run snapshot.
//
// The staleness problem this closes: the docs used to cite "measured on a 45-fact
// snapshot; corpus now N — re-run for current." There was no machine-readable
// current number and no signal when it had gone stale. This script makes the
// number a FILE (metrics.json) that any agent/human can read, and gives a one-shot
// staleness check so the builder ALWAYS knows whether it's current.
//
//   ./run.sh refresh-metrics    → rebuild the index on the LIVE corpus, run the
//                                 eval, WRITE metrics.json, upsert the Mission
//                                 Control health card, then print the status.
//   ./run.sh metrics-status     → compare metrics.json's corpus_size to the CURRENT
//                                 count of memory/*.md. FRESH (equal) or STALE
//                                 (differs, with both counts + the one-command fix).
//
// It reuses the canonical eval harness verbatim (`eval.mjs --json`, the machine-
// readable mode built "for CI / tracking") so the numbers here are exactly what a
// human gets from `./run.sh eval` — no re-implemented scoring to drift.
//
// MEMORY_DIR: honoured if set (portability); otherwise defaults to the repo-root
// `memory/` next to this tool — so `./run.sh refresh-metrics` "just works" here.
// measured_at uses `new Date().toISOString()` — this is a normal Node script, not
// a sandboxed hook, so wall-clock is available (unlike hook.mjs).

import { DatabaseSync } from "node:sqlite";
import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

const TOOL_DIR = import.meta.dirname ?? resolve(".");
const REPO_ROOT = resolve(TOOL_DIR, "..");
const MEMORY_DIR = process.env.MEMORY_DIR
  ? resolve(process.env.MEMORY_DIR)
  : join(REPO_ROOT, "memory");
const METRICS_PATH = join(TOOL_DIR, "metrics.json");
const DB_PATH = process.env.MEMORY_DB ? resolve(process.env.MEMORY_DB) : join(TOOL_DIR, "memory-index.db");
const MC_UPDATE = join(REPO_ROOT, "mission-control", "mc-update.py");

// The index roll-up file is not a per-fact memory — excluded from the corpus count
// (mirrors lib/memory.mjs, which skips MEMORY.md when indexing).
const INDEX_FILE = "MEMORY.md";

// recall floor for the health card colour: at/above the keyword baseline is "ok".
const RECALL_OK_FLOOR = 0.7;

const childEnv = { ...process.env, MEMORY_DIR, NODE_NO_WARNINGS: "1" };

/** Count of memory/*.md files, excluding the MEMORY.md roll-up index. */
function countCorpus(dir) {
  if (!existsSync(dir)) return 0;
  return readdirSync(dir).filter((f) => f.endsWith(".md") && f !== INDEX_FILE).length;
}

function pct(x) {
  return `${Math.round(x * 100)}%`;
}

function gitShortSha() {
  try {
    return execFileSync("git", ["rev-parse", "--short", "HEAD"], {
      cwd: REPO_ROOT,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return "unknown";
  }
}

/** The embedder the index was ACTUALLY built with (honest source: the DB meta). */
function embedderFromDb() {
  try {
    const db = new DatabaseSync(DB_PATH, { readOnly: true });
    const row = db.prepare("SELECT value FROM meta WHERE key = 'embedder'").get();
    db.close();
    return row?.value ?? "unknown";
  } catch {
    return "unknown";
  }
}

function rebuildIndex() {
  // Full rebuild against the LIVE corpus so the measured numbers cannot be stale.
  // stdio inherited → the operator sees "Indexed N memories…" progress.
  execFileSync(process.execPath, ["--experimental-sqlite", join(TOOL_DIR, "index.mjs")], {
    cwd: TOOL_DIR,
    env: childEnv,
    stdio: ["ignore", "inherit", "inherit"],
  });
}

/** Run the canonical eval in --json mode and parse its aggregates. */
function runEval() {
  const out = execFileSync(
    process.execPath,
    ["--experimental-sqlite", join(TOOL_DIR, "eval.mjs"), "--json"],
    { cwd: TOOL_DIR, env: childEnv, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
  );
  const start = out.indexOf("{"); // defensive: strip any stray leading output
  return JSON.parse(start >= 0 ? out.slice(start) : out);
}

function pickConfig(evalOut, mode) {
  return evalOut.configs.find((c) => c.mode === mode);
}

/** Upsert the single Mission Control health card (best-effort — never fails refresh). */
function updateBoard(metrics) {
  if (!existsSync(MC_UPDATE)) {
    return { ok: false, reason: `mc-update.py not found at ${MC_UPDATE}` };
  }
  const fresh = metrics.corpus_size === countCorpus(MEMORY_DIR);
  const status = fresh && metrics.recall_at_1 >= RECALL_OK_FLOOR ? "green" : "amber";
  const value = `recall@1 ${pct(metrics.recall_at_1)} · noise ${metrics.noise_pass}/${metrics.noise_total}`;
  const note = `as of ${metrics.corpus_size} facts, ${metrics.measured_at}; ./run.sh refresh-metrics to update`;
  try {
    // key `memory_recall` = the EXISTING card → upsert in place (no duplicate card).
    execFileSync(
      "python3",
      [
        MC_UPDATE, "health", "memory_recall",
        "--label", "Memory recall",
        "--value", value,
        "--target", "recall@1 ≥ 85% · noise 4/4",
        "--status", status,
        "--note", note,
      ],
      { cwd: REPO_ROOT, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
    );
    return { ok: true, status, value };
  } catch (e) {
    return { ok: false, reason: (e.stderr || e.message || String(e)).trim() };
  }
}

function refresh() {
  console.log(`Refreshing memory-recall metrics on: ${MEMORY_DIR}`);
  rebuildIndex();
  const evalOut = runEval();
  const hy = pickConfig(evalOut, "hybrid");
  const kw = pickConfig(evalOut, "keyword");
  if (!hy) throw new Error("eval --json returned no 'hybrid' config");

  const metrics = {
    recall_at_1: hy.recall["1"],
    recall_at_3: hy.recall["3"],
    recall_at_5: hy.recall["5"],
    mrr: hy.mrr,
    noise_pass: hy.noise.suppressed,
    noise_total: hy.noise.total,
    corpus_size: countCorpus(MEMORY_DIR),
    eval_case_count: hy.n + hy.noise.total, // positives + noise = full labelled set
    embedder: embedderFromDb(),
    config: "hybrid",
    // Keyword baseline kept so the honest "recall@3 vs keyword" framing stays
    // machine-readable (the vector arm can trade a little mid-rank breadth for
    // rank-1 precision — currently NO drop: both at recall@3 90% on this corpus).
    baseline_keyword: kw
      ? { recall_at_1: kw.recall["1"], recall_at_3: kw.recall["3"], recall_at_5: kw.recall["5"], mrr: kw.mrr }
      : null,
    measured_at: new Date().toISOString(),
    git_sha: gitShortSha(),
  };

  writeFileSync(METRICS_PATH, JSON.stringify(metrics, null, 2) + "\n");
  console.log(`\nWrote ${METRICS_PATH}`);

  const board = updateBoard(metrics);
  console.log(
    board.ok
      ? `Board: upserted health card 'memory_recall' → ${board.status} (${board.value})`
      : `Board: NOT updated — ${board.reason}`,
  );

  console.log("");
  printStatus(metrics); // ends FRESH — we just measured the live corpus
}

function printStatus(metrics) {
  const current = countCorpus(MEMORY_DIR);
  const line = "─".repeat(60);
  console.log(line);
  if (metrics.corpus_size === current) {
    console.log(`FRESH — metrics.json matches the live corpus (${current} facts).`);
    console.log(
      `  recall@1 ${pct(metrics.recall_at_1)} · recall@3 ${pct(metrics.recall_at_3)} · ` +
        `recall@5 ${pct(metrics.recall_at_5)} · MRR ${metrics.mrr.toFixed(3)} · ` +
        `noise ${metrics.noise_pass}/${metrics.noise_total}`,
    );
    console.log(`  embedder ${metrics.embedder} · measured ${metrics.measured_at}`);
    console.log(line);
    return 0;
  }
  console.log(`STALE — corpus changed since metrics were measured.`);
  console.log(`  metrics.json: ${metrics.corpus_size} facts   |   live corpus now: ${current} facts`);
  console.log(`  measured ${metrics.measured_at} (git ${metrics.git_sha})`);
  console.log(`  fix:  ./run.sh refresh-metrics`);
  console.log(line);
  return 1;
}

function status() {
  if (!existsSync(METRICS_PATH)) {
    console.log(`STALE — no metrics.json yet (never measured).`);
    console.log(`  live corpus: ${countCorpus(MEMORY_DIR)} facts`);
    console.log(`  fix:  ./run.sh refresh-metrics`);
    return 2;
  }
  const metrics = JSON.parse(readFileSync(METRICS_PATH, "utf8"));
  return printStatus(metrics);
}

function main() {
  const sub = process.argv[2];
  if (sub === "status") {
    process.exit(status());
  }
  refresh();
}

main();
