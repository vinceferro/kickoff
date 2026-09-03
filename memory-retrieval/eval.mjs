#!/usr/bin/env node

// eval.mjs — THE EVAL HARNESS. Two modes:
//
// ── (default) THE ACCEPTANCE SUITE — the memory-precision lane's machine proof ──
// `node --experimental-sqlite memory-retrieval/eval.mjs` (no args, from the
// worktree root) rebuilds the committed fixture indexes (eval-fixtures/) and
// re-measures herdr-tg's finding end-to-end — 124 real operator turns (fire-rate),
// 16 paraphrase recall cases + 6 noise cases, corpora grown 16 → 66 → 233:
//
//     corpus                noise suppressed   fires on real turns   recall@3
//     16  (flat)                 6/6                 44%               0.88
//     66  (flat)                 4/6                 71%               0.88
//     233 (flat)                 4/6                 79%               0.88  ← the collapse
//     233 (SCOPED)               ≥4/6                ≤50%  GATE       ≥0.88 GATE
//
// The root cause (herdr's measurement): evaluateCutoff takes a MAXIMUM over the
// candidate pool and compares it to a FIXED floor — draw more candidates (bigger
// corpus OR bigger K) and the max rises while the bar does not. The fix under
// test is PER-FUNCTION INDEX SCOPING (MEMORY_HOOK_FUNCTION + MEMORY_HOOK_CORE_SLUGS
// — see hook.mjs / lib/memory.mjs scopeOf): the pool becomes this function's own
// memories (+ ≤5 pinned core facts), never the flat merged pool. The suite drives
// the REAL mechanism — retrieve() with a scope on the same index the hook reads —
// not a simulation of it, and it scores every turn through the SHARED gate
// (lib/cutoff.mjs), the exact evaluateCutoff the hook runs. No transcription.
//
// EXIT GATES (exit 0 IFF every RUNNABLE one holds — the runner checks nothing else):
//   G1  scoped @ 233-corpus fire-rate ≤ 50%          (herdr's own-band is 44%)
//   G2  scoped @ 233-corpus recall@3 ≥ 0.88          (held — precision for free)
//   G3  own-scale (16) noise suppression 6/6         (no regression at own scale)
//   G4  scoped @ 233-corpus noise suppression ≥ 4/6  (no regression at scale)
//   G5  scoped fires strictly FEWER real turns than the flat 233 pool
//       (the lane's claim: scoping beats the pool, not just matches it)
//   G6  the scoping machinery is real end-to-end: the index records each fact's
//       function (scope column) AND a pinned MEMORY_HOOK_CORE_SLUGS fact is
//       admitted into the scoped pool (checked — their fire-rate is reported only)
//
// F-1 (environment-independence): every arm measures the mode the HOOK resolves
// ("auto": keyword on a stub index, hybrid on a semantic one) — never a
// hard-coded hybrid. G2/G4 are semantic-dependent, so on an embedder-less box
// they are SKIPPED with a loud named line (never a silent green, never an
// opaque red); G1/G3/G5/G6 stay runnable and gate the exit there. With a real
// embedder the full suite gates exactly as measured (44%/0.88 unchanged).
// Reported but NOT gated: the flat curve itself (the witnessed RED), the
// anti-pattern corpus (own + 54 cross-cutting "core" facts — herdr measured fires
// 74% ≈ flat 79%; "a shared core has to be five facts, not fifty"), and the two
// named steering fixtures ("not at the laptop right now, we can pause", "How is
// it going with that?") — stopping those is the QUERY pre-gate, a different lane.
//
// Fixtures are COMMITTED (eval-fixtures/) — no /tmp dependency, no live-org reads.
// Indexes are rebuilt from them at eval time (233 small files ≈ seconds) into the
// gitignored eval-fixtures/.cache/. MEMORY_EVAL_CACHE=1 reuses the cached builds
// (a speed lever for iteration; the default rebuild is the proof).
//
// ── --set  THE PER-REPO LABELLED SET (the original harness, preserved) ─────────
// `./run.sh eval --set` runs eval-set.json against the LIVE default index and
// reports recall@K / MRR / noise suppression per config (keyword vs hybrid).
// This was the tool's original (and only) eval mode; it answers "is THIS repo's
// corpus retrieval healthy", where the acceptance suite answers "does the hook's
// precision hold as memory pools grow".

import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { buildIndex } from "./index.mjs";
import { DEFAULT_DB_PATH, listMemoryFiles } from "./lib/memory.mjs";
import { indexIsSemantic, retrieve } from "./retrieve.mjs";
// ONE gate object with the hook — never a transcription of it (the seed harness's
// hand-mirrored gate is how RRF floors drifted; see lib/cutoff.mjs).
const { evaluateCutoff } = await import("./lib/cutoff.mjs");

const env = process.env;
// Protocol depth = the hook's default TOP_K (herdr measured at K=3).
const TOP_K = Number(env.MEMORY_HOOK_K || 3);

// db slugs carry the pooled-corpus org prefix (herdr-tg__slug); case labels don't.
const norm = (s) => s.replace(/^[^_]+__/, "");

// ── fixture paths ──────────────────────────────────────────────────────────────
const FIXTURES = join(import.meta.dirname ?? ".", "eval-fixtures");
const CACHE = join(FIXTURES, ".cache");
const CORPORA = join(FIXTURES, "corpora");
const QUERIES = join(FIXTURES, "queries");

// The scope under test: herdr-tg's own function inside the pooled corpora.
const SCOPE_PREFIX = "herdr-tg";

/** A probe word guaranteed to hit one memory's own body (for the G6 pin check). */
function distinctiveWord(body) {
  const words = (String(body).toLowerCase().match(/[a-z0-9]+/g) || []).filter((w) => w.length > 5);
  words.sort((a, b) => b.length - a.length);
  return words[0] ?? null;
}

// ── the measured protocol (mirrors herdr-tg's evaluateCutoff transcription) ────
async function measure(dbPath, { cases, real, steering, scope = null, coreSlugs = [] }) {
  // F-1: gate the mode the HOOK would run on THIS index — its "auto" resolution
  // is keyword on a stub index, hybrid on a semantic one. Hard-coding "hybrid"
  // made the suite measure a mode production never runs on an embedder-less box
  // (the hook there resolves keyword).
  const mode = indexIsSemantic(dbPath) ? "hybrid" : "keyword";
  const opts = { k: TOP_K, dbPath, mode, scope, coreSlugs };
  let r1 = 0, r3 = 0, mrr = 0;
  const positives = cases.filter((c) => c.expect);
  const noise = cases.filter((c) => !c.expect);
  for (const c of positives) {
    const { results, meta } = await retrieve(c.q, opts);
    const fired = evaluateCutoff(results, meta).surface;
    const rank = fired ? results.map((r) => norm(r.slug)).indexOf(c.expect) : -1;
    if (rank === 0) r1++;
    if (rank >= 0) {
      r3++;
      mrr += 1 / (rank + 1);
    }
  }
  let noiseSuppressed = 0;
  for (const c of noise) {
    const { results, meta } = await retrieve(c.q, opts);
    if (!evaluateCutoff(results, meta).surface) noiseSuppressed++;
  }
  let fired = 0;
  const firedTurns = [];
  for (const q of real) {
    const { results, meta } = await retrieve(q, opts);
    if (evaluateCutoff(results, meta).surface) {
      fired++;
      firedTurns.push(q);
    }
  }
  const steeringOut = steering.map((s) => ({ q: s.q, fires: firedTurns.includes(s.q) }));
  return {
    recall1: +(r1 / positives.length).toFixed(2),
    recall3: +(r3 / positives.length).toFixed(2),
    mrr: +(mrr / positives.length).toFixed(2),
    noise: `${noiseSuppressed}/${noise.length}`,
    noiseN: noiseSuppressed,
    noiseTot: noise.length,
    fires: fired,
    tot: real.length,
    fireRate: +(fired / real.length).toFixed(3),
    steering: steeringOut,
  };
}

async function buildFixtureIndex(name, scopeOpts) {
  // F-3: the FLAT arms are PINNED against hostile ambient state. This helper is
  // called with no scopeOpts for the flat baselines; listMemoryFiles resolves
  // the env knobs when scopeOpts is undefined, so an exported
  // MEMORY_HOOK_FUNCTION in the calling session used to build the "flat"
  // indexes SCOPED (witnessed: c233 enumerated 16 files, not 233) and every
  // flat-vs-scoped comparison was a lie. `scopeOpts: null` is the explicit
  // UNSCOPED pin (not {scope: null} — that is "scoped to null").
  const pinned = scopeOpts === undefined ? null : scopeOpts;
  const suffix = pinned
    ? `.scoped${pinned.coreSlugs.length ? `-${pinned.coreSlugs.length}core` : ""}`
    : "";
  const dbPath = join(CACHE, `${name}${suffix}.db`);
  if (env.MEMORY_EVAL_CACHE === "1" && existsSync(dbPath)) return dbPath;
  if (existsSync(dbPath)) rmSync(dbPath);
  await buildIndex({
    memoryDir: join(CORPORA, name),
    dbPath,
    quiet: true,
    scopeOpts: pinned,
  });
  return dbPath;
}

// ── the suite ──────────────────────────────────────────────────────────────────
async function runAcceptanceSuite() {
  for (const d of [CORPORA, QUERIES]) {
    if (!existsSync(d)) {
      // Two honest cases: the private line's eval assets were never committed
      // (pull/re-clone) — or this is the PUBLIC line, where eval-fixtures/ is
      // a scoped export drop BY CONTRACT (operator corpora never ship). Name both.
      console.error(
        `acceptance suite: missing fixtures at ${d} — eval-fixtures/ must be committed ` +
          `on the private line, or this is the public release line (fixtures are an ` +
          `export drop there by contract: eval assets stay local)`,
      );
      process.exit(1);
    }
  }
  mkdirSync(CACHE, { recursive: true });

  const real = JSON.parse(readFileSync(join(QUERIES, "real-turns.json"), "utf8"));
  const cases = JSON.parse(readFileSync(join(QUERIES, "paraphrase-cases.json"), "utf8")).cases;
  const steering = JSON.parse(readFileSync(join(QUERIES, "steering-cases.json"), "utf8")).cases;

  // The MEMORY_HOOK_CORE_SLUGS knob check: two deterministic cross-function facts
  // (sorted, first two non-herdr-tg slugs in the pooled corpus — arbitrary but
  // FIXED, so the run is reproducible). Their ADMISSION is gated; their numbers
  // are reported only.
  const coreCandidates = readdirSync(join(CORPORA, "c233"))
    .filter((f) => f.endsWith(".md") && !f.startsWith(`${SCOPE_PREFIX}__`))
    .sort()
    .slice(0, 2)
    .map((f) => f.replace(/\.md$/, ""));

  const flat = {};
  for (const name of ["c16", "c66", "c233", "c_core54"]) {
    flat[name] = await measure(await buildFixtureIndex(name), { cases, real, steering });
  }
  // ── F-3 CANARY — the check that CAN fail ────────────────────────────────────
  // If ambient scope env ever leaks past the flat-arm pin again, the flat c233
  // index silently holds ~16 rows instead of the full corpus and every
  // flat-vs-scoped comparison below (incl. G5) is a lie. Assert the pin held,
  // naming the failure mode.
  {
    const expected = listMemoryFiles(join(CORPORA, "c233"), null).length;
    const { DatabaseSync: DS } = await import("node:sqlite");
    const got = new DS(join(CACHE, "c233.db")).prepare(`SELECT COUNT(*) AS n FROM memories`).get().n;
    if (got !== expected) {
      console.error(
        `F-3 CANARY FAILED: flat c233 index has ${got} rows but the corpus enumerates ${expected} — ` +
          `ambient scope env leaked into the flat arms (the baseline is scoped; every flat comparison is a lie).`,
      );
      process.exit(1);
    }
  }
  // The scoped runs: the scoped knob narrows the corpus the INDEX is built from
  // (own + unscoped + core — the same enumeration production uses), so the
  // index's corpus statistics are the scoped corpus's. That is the measured
  // fix: a query-time filter over the merged index alone lands ~55% because
  // BM25 still scores against the merged pool; the scoped index reproduces
  // herdr's own-corpus band. The retrieve() scope opts below mirror the hook
  // exactly (defense in depth on top of the scoped index).
  const scoped = {};
  for (const name of ["c16", "c233"]) {
    scoped[name] = await measure(await buildFixtureIndex(name, { scope: SCOPE_PREFIX, coreSlugs: [] }), {
      cases, real, steering, scope: SCOPE_PREFIX, coreSlugs: [],
    });
  }
  const scopedCore = await measure(await buildFixtureIndex("c233", { scope: SCOPE_PREFIX, coreSlugs: coreCandidates }), {
    cases, real, steering, scope: SCOPE_PREFIX, coreSlugs: coreCandidates,
  });

  // G6 — the machinery, straight from the DBs + one pinned admission probe.
  // (Guarded: against a pre-knob indexer the scope column doesn't exist — the
  // suite must FAIL the gate, not crash the run. That graceful RED is the
  // witness that the check can fail.)
  const { DatabaseSync } = await import("node:sqlite");
  const scopedDb = join(CACHE, "c233.scoped.db");
  const scopedCoreDb = join(CACHE, "c233.scoped-2core.db");
  let scopedCount = null;
  try {
    scopedCount = new DatabaseSync(scopedDb)
      .prepare(`SELECT COUNT(*) AS n FROM memories WHERE scope = ?`)
      .get(SCOPE_PREFIX).n;
  } catch {
    scopedCount = null; // no scope column → the fix isn't in this index
  }
  const pinnedSlug = coreCandidates[0];
  let pinnedBody = null;
  try {
    pinnedBody = new DatabaseSync(scopedCoreDb)
      .prepare(`SELECT body FROM memories WHERE slug = ?`)
      .get(pinnedSlug)?.body;
  } catch {
    pinnedBody = null;
  }
  const probeWord = distinctiveWord(pinnedBody);
  let pinnedAdmitted = false;
  if (probeWord) {
    // F-1: the probe runs the mode the hook would resolve on this index (auto).
    const { results } = await retrieve(probeWord, {
      k: TOP_K, dbPath: scopedCoreDb, mode: indexIsSemantic(scopedCoreDb) ? "hybrid" : "keyword",
      scope: SCOPE_PREFIX, coreSlugs: coreCandidates,
    });
    pinnedAdmitted = results.map((r) => r.slug).includes(pinnedSlug);
  }

  // ── report ───────────────────────────────────────────────────────────────────
  const semantic = indexIsSemantic(join(CACHE, "c233.db"));
  const line = "─".repeat(78);
  console.log("═".repeat(78));
  console.log("MEMORY PRECISION — ACCEPTANCE SUITE (herdr-tg fire-rate curve, per-function scoping)");
  console.log(
    semantic
      ? "vector arm: REAL semantic embeddings (comparable to the measured baseline)"
      : "⚠ vector arm: NOT semantic — recall numbers are NOT comparable to the baseline",
  );
  console.log("═".repeat(78));
  console.log(
    "\ncorpus                     noise   fires on real turns   recall@1  recall@3   MRR",
  );
  console.log(line);
  const row = (label, m) =>
    console.log(
      `${label.padEnd(24)} ${m.noise.padEnd(7)} ${(m.fireRate * 100).toFixed(0).padStart(3)}% ` +
        `(${String(m.fires).padStart(3)}/${m.tot})`.padEnd(21) +
        `  ${m.recall1.toFixed(2).padStart(7)}  ${m.recall3.toFixed(2).padStart(8)}  ${m.mrr.toFixed(2).padStart(5)}`,
    );
  row("16  flat (own only)", flat.c16);
  row("66  flat", flat.c66);
  row("233 flat (all orgs)", flat.c233);
  row(`${SCOPE_PREFIX} scoped @ 16`, scoped.c16);
  row(`${SCOPE_PREFIX} scoped @ 233`, scoped.c233);
  row(`${SCOPE_PREFIX} scoped+core2 @ 233`, scopedCore);
  row("70  own + 54 core (flat)", flat.c_core54);

  console.log(`\nSTEERING FIXTURES (named cases — REPORTED, not gated; the query pre-gate owns them):`);
  for (const s of scoped.c233.steering) {
    console.log(
      `  scoped@233 fires=${s.fires ? "YES" : "no "}  flat@233 fires=${
        flat.c233.steering.find((x) => x.q === s.q)?.fires ? "YES" : "no "
      }  "${s.q}"`,
    );
  }

  // ── gates ────────────────────────────────────────────────────────────────────
  // F-1: G2/G4 are SEMANTIC-dependent (recall@3 ≥ 0.88 is unreachable on the
  // lexical stub — measured 0.69 there). On an embedder-less box they are
  // SKIPPED, loudly and by name — never silently passed, never an opaque red.
  // The remaining gates (G1/G3/G5/G6) stay runnable and must pass for exit 0.
  const gates = [
    {
      id: "G1",
      desc: `scoped@233 fire-rate ≤ 50% (herdr own-band 44%)`,
      ok: scoped.c233.fireRate <= 0.5,
      got: `${(scoped.c233.fireRate * 100).toFixed(0)}%`,
    },
    ...(semantic
      ? [
          {
            id: "G2",
            desc: `scoped@233 recall@3 ≥ 0.88`,
            ok: scoped.c233.recall3 >= 0.88,
            got: scoped.c233.recall3,
          },
        ]
      : []),
    { id: "G3", desc: `own-scale noise suppression 6/6`, ok: scoped.c16.noiseN === scoped.c16.noiseTot, got: scoped.c16.noise },
    ...(semantic
      ? [
          {
            id: "G4",
            desc: `scoped@233 noise suppression ≥ 4/6`,
            ok: scoped.c233.noiseN >= 4,
            got: scoped.c233.noise,
          },
        ]
      : []),
    {
      id: "G5",
      desc: `scoped@233 fires strictly fewer real turns than flat@233`,
      ok: scoped.c233.fires < flat.c233.fires,
      got: `${scoped.c233.fires} < ${flat.c233.fires}`,
    },
    {
      id: "G6",
      desc: `index records function scopes (${scopedCount}× ${SCOPE_PREFIX}) + pinned core slug admitted via probe "${probeWord}"`,
      ok: scopedCount === 16 && pinnedAdmitted,
      got: `scope-rows=${scopedCount}, pinned=${pinnedAdmitted}`,
    },
  ];
  console.log(`\nGATES (exit 0 IFF all hold${semantic ? "" : " — G2/G4 skipped, embedder-less box"}):`);
  for (const g of gates) {
    console.log(`  ${g.ok ? "PASS" : "FAIL"}  ${g.id}  ${g.desc}  [got: ${g.got}]`);
  }
  if (!semantic) {
    console.log(`  SKIP  G2  SKIP: G2/G4 need the embedder — install-model first (node memory-retrieval/install-model.mjs)`);
    console.log(`  SKIP  G4  SKIP: G2/G4 need the embedder — install-model first (node memory-retrieval/install-model.mjs)`);
    console.log(
      `\n  ⚠ semantic gates SKIPPED, not passed — this box has no embedder, so recall/noise\n` +
        `    gates are unproven here. Keyword-runnable gates all pass above.`,
    );
  }
  const anti = flat.c_core54;
  console.log(
    `\nanti-pattern (reported): own + 54 cross-cutting core facts fires ` +
      `${(anti.fireRate * 100).toFixed(0)}% ≈ the flat pool's ${(flat.c233.fireRate * 100).toFixed(0)}% — ` +
      `a shared core has to be five facts, not fifty (the hook warns above 5).`,
  );
  console.log("═".repeat(78));

  if (env.MEMORY_EVAL_JSON === "1") {
    console.log(
      JSON.stringify(
        { semantic, coreCandidates, flat, scoped, scopedCore, gates, steering: scoped.c233.steering },
        null,
        2,
      ),
    );
  }
  if (gates.some((g) => !g.ok)) process.exit(1);
}

// ── --set: the original per-repo labelled-set harness (preserved) ───────────────
async function runLabelledSet({ asJson, only }) {
  const EVAL_SET = env.MEMORY_EVAL_SET || join(import.meta.dirname ?? ".", "eval-set.json");
  const KS = [1, 3, 5];
  const POOL_K = 5;
  const { evaluateCutoff } = await import("./lib/cutoff.mjs");
  // The live-settings mirror this mode always used (settings.json's tighter floors,
  // NOT the hook's code defaults — see the original header note).
  const saved = {};
  for (const k of ["MEMORY_HOOK_BM25_FLOOR", "MEMORY_HOOK_VEC_FLOOR"]) saved[k] = env[k];
  env.MEMORY_HOOK_BM25_FLOOR = saved.MEMORY_HOOK_BM25_FLOOR || "-8.0";
  env.MEMORY_HOOK_VEC_FLOOR = saved.MEMORY_HOOK_VEC_FLOOR || "0.23";
  const gate = await import(`./lib/cutoff.mjs?set-${Date.now()}`);

  const rankOf = (results, slug) => {
    const i = results.findIndex((r) => r.slug === slug);
    return i === -1 ? null : i + 1;
  };
  const runConfig = async (casesIn, mode) => {
    const positives = casesIn.filter((c) => c.expect !== null);
    const noise = casesIn.filter((c) => c.expect === null);
    const rows = [];
    let rrSum = 0;
    const recallHits = Object.fromEntries(KS.map((k) => [k, 0]));
    for (const c of positives) {
      const { results } = await retrieve(c.query, { k: POOL_K, mode });
      const rank = rankOf(results, c.expect);
      if (rank) {
        rrSum += 1 / rank;
        for (const k of KS) if (rank <= k) recallHits[k]++;
      }
      rows.push({ kind: "positive", query: c.query, expect: c.expect, rank, pass3: !!(rank && rank <= 3), top: results.slice(0, 3).map((r) => r.slug) });
    }
    let noiseSuppressed = 0;
    for (const c of noise) {
      const { results, meta } = await retrieve(c.query, { k: POOL_K, mode });
      const surfaced = gate.evaluateCutoff(results, meta).surface;
      if (!surfaced) noiseSuppressed++;
      rows.push({ kind: "noise", query: c.query, suppressed: !surfaced, pass3: !surfaced, top: surfaced ? results.slice(0, 3).map((r) => r.slug) : [] });
    }
    const n = positives.length;
    return { mode, n, recall: Object.fromEntries(KS.map((k) => [k, recallHits[k] / n])), mrr: rrSum / n, noise: { total: noise.length, suppressed: noiseSuppressed }, rows };
  };

  if (!existsSync(DEFAULT_DB_PATH)) {
    if (!asJson) console.log("No index found — building it first...\n");
    await buildIndex({ quiet: asJson });
  }
  const set = JSON.parse(readFileSync(EVAL_SET, "utf8"));
  const { meta } = await retrieve("probe", { k: 1 });
  const semantic = meta.semantic;
  const modes = only ? [only] : ["keyword", "hybrid"];
  const configs = [];
  for (const mode of modes) configs.push(await runConfig(set.cases, mode));

  if (asJson) {
    console.log(JSON.stringify({ semantic, configs: configs.map(({ mode, n, recall, mrr, noise }) => ({ mode, n, recall, mrr, noise })) }, null, 2));
  } else {
    const line = "─".repeat(78);
    const pct = (x) => `${(x * 100).toFixed(1)}%`;
    console.log("═".repeat(78));
    console.log("MEMORY RETRIEVAL — LABELLED-SET EVAL (--set: this repo's eval-set.json vs the live index)");
    console.log(`vector arm: ${semantic ? "REAL semantic embeddings" : "STUB lexical (no embedder wired)"}`);
    console.log("═".repeat(78));
    console.log("\nHEADLINE — recall@K + MRR, per config (positives only):\n");
    const header = ["config", "n", "recall@1", "recall@3", "recall@5", "MRR", "noise-suppress"];
    const widths = [10, 4, 9, 9, 9, 7, 14];
    console.log(header.map((c, i) => String(c).padEnd(widths[i])).join(""));
    console.log(line);
    for (const cfg of configs) {
      console.log([cfg.mode, cfg.n, pct(cfg.recall[1]), pct(cfg.recall[3]), pct(cfg.recall[5]), cfg.mrr.toFixed(3), `${cfg.noise.suppressed}/${cfg.noise.total}`].map((c, i) => String(c).padEnd(widths[i])).join(""));
    }
    const detail = configs.find((c) => c.mode === "hybrid") ?? configs[0];
    console.log(`\n${line}\nPER-CASE (config: ${detail.mode}) — rank of the expected memory:\n`);
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
        console.log(`  ${r.suppressed ? "✅ suppressed".padEnd(14) : "✗ LEAKED".padEnd(14)} "${r.query}"`);
        if (!r.suppressed) console.log(`     leaked: ${r.top.join(", ")}`);
      }
    }
    console.log("═".repeat(78));
  }
  for (const k of Object.keys(saved)) {
    if (saved[k] === undefined) delete env[k];
    else env[k] = saved[k];
  }
}

// ── CLI ────────────────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const asJson = args.includes("--json") || env.MEMORY_EVAL_JSON === "1";
const onlyIdx = args.indexOf("--config");
try {
  if (args.includes("--set")) {
    await runLabelledSet({ asJson, only: onlyIdx !== -1 ? args[onlyIdx + 1] : null });
  } else {
    await runAcceptanceSuite();
  }
} catch (e) {
  console.error(e);
  process.exit(1);
}
