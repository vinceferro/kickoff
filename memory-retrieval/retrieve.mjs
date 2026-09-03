#!/usr/bin/env node

// retrieve.mjs — HYBRID retrieval over the derived index.
//
// Hybrid = FTS5/BM25 keyword score  ⊕  vector/cosine semantic score, fused with
// Reciprocal Rank Fusion (RRF). RRF is rank-based (not score-based) so it needs
// no score normalisation between the two very different scales (BM25 is an
// unbounded negative log-odds; cosine is [-1,1]) — that robustness is exactly
// why production hybrid search (Weaviate, Elastic, Vespa) defaults to it.
//
// Today the KEYWORD arm carries the result quality. The VECTOR arm runs through
// the SAME fusion, but on this box it's the deterministic stub (lexical), so it
// mostly reinforces keyword matches rather than adding true semantic recall.
// Wire a real embedder (set OPENAI_API_KEY, rebuild) and the vector arm starts
// pulling in synonym/paraphrase matches with ZERO change here.
//
// Usage:
//   node --experimental-sqlite retrieve.mjs "<query>" [--k N] [--json] [--graph]
//   ./run.sh retrieve "<query>"

import { existsSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import {
  cosine,
  createEmbeddingProvider,
  installHint,
  semanticAvailability,
  warnSemanticDegraded,
} from "./lib/embeddings.mjs";
import { DEFAULT_DB_PATH } from "./lib/memory.mjs";

// RRF damping constant. Standard RRF uses k=60, but with a REAL semantic vector
// arm we lower it (default 10) so a STRONG top-rank hit in either arm dominates
// the fusion — a smaller k makes rank-1 worth far more than rank-15. This is what
// lets a vector-#1 / keyword-absent hit (e.g. a pure-synonym query like "where do
// I find the Obsidian notes now") surface, instead of being buried by a crowd of
// lexically-adjacent facts that both arms rank only moderately. Env-tunable.
const RRF_K = Number(process.env.MEMORY_RRF_K || 10);

// Per-arm fusion weights. With real embeddings the vector arm carries genuine
// semantic recall the keyword arm lacks, so we up-weight it (default 2×). On a
// stub (lexical) index this would over-trust noise, but the hook runs keyword-only
// there anyway (see hook.mjs auto-mode), so weighting only bites on a real index.
const VECTOR_WEIGHT = Number(process.env.MEMORY_VECTOR_WEIGHT || 2);
const KEYWORD_WEIGHT = Number(process.env.MEMORY_KEYWORD_WEIGHT || 1);

// ── DoS GUARD: bound the query before it reaches EITHER arm ───────────────────
// A pasted log / stacktrace / source file is ROUTINE in a Claude Code turn. The
// keyword arm ORs one quoted FTS5 term per UNIQUE token, so an unbounded prompt
// blows the MATCH string + query-tree up ~O(n²) (measured multi-second on a
// ~100k-token paste, an effective hang at ~4MB), and the embedder would tokenize
// the whole blob. Since the hook fires on EVERY UserPromptSubmit, that stalls
// real turns. We cap BOTH dimensions: total chars fed to either arm, and the
// number of distinct OR-terms in the FTS query. These are SAFETY bounds, not
// tuning knobs — the defaults sit far above any genuine decision-time query, so
// normal-length prompts are affected IDENTICALLY (i.e. not at all). Env-tunable
// only to match this file's knob idiom.
const MAX_QUERY_CHARS = Number(process.env.MEMORY_MAX_QUERY_CHARS || 2000);
const MAX_FTS_TERMS = Number(process.env.MEMORY_MAX_FTS_TERMS || 64);

// Common English stop words. The keyword arm ORs every query term, so without
// this a question like "what is the weather for tomorrow" matches dozens of
// memories purely on "what/is/the/for" → spurious high-rank noise that defeats
// the hook's relevance cutoff. Dropping stop words leaves only CONTENT words, so
// a truly off-domain query yields ZERO keyword hits and the cutoff suppresses it.
// (Standard IR practice; the porter-stemmed FTS index is unaffected — this only
// shapes the QUERY side.)
const STOP_WORDS = new Set(
  (
    "a an and are as at be by can do does for from has have how i in is it its me my of on or so that the " +
    "their them then there these this to up us was we what when where which who why will with you your should " +
    "would could about into over after before some any all out get got want need make made does did done " +
    "if but not no yes ok okay just now new use using used run running ran"
  ).split(" "),
);

/** Escape a free-text query into a safe FTS5 MATCH string (OR of content terms). */
function toFtsQuery(query) {
  // Truncate BEFORE tokenizing so the work itself is bounded — defends this arm
  // even if it's ever called with an unbounded query (retrieve() also bounds
  // upstream). A genuine query is ≪ MAX_QUERY_CHARS, so this is a no-op for it.
  const bounded = String(query).slice(0, MAX_QUERY_CHARS);
  const all = (bounded.toLowerCase().match(/[a-z0-9]+/g) || []).filter((t) => t.length > 1);
  let terms = all.filter((t) => !STOP_WORDS.has(t));
  // If a query is ALL stop words (degenerate), fall back to the raw terms so we
  // don't crash — but such a query won't carry discriminative signal anyway.
  if (terms.length === 0) terms = all;
  if (terms.length === 0) return null;
  // Dedupe, then CAP the distinct-term set: the MATCH ORs one clause per unique
  // term, so without a cap a high-cardinality paste fans out to thousands of OR
  // clauses (the O(n²) blowup). MAX_FTS_TERMS keeps every realistic query intact
  // (a genuine turn has far fewer content terms) while bounding the worst case.
  const terms64 = [...new Set(terms)].slice(0, MAX_FTS_TERMS);
  // Quote each term (defuses FTS operators) and OR them so partial overlaps hit.
  return terms64.map((t) => `"${t}"`).join(" OR ");
}

/**
 * The scope predicate shared by both arms: this function's memories + every
 * unscoped one + the pinned core slugs. Empty when no scope is set (the whole
 * index is the pool — the pre-knob behavior). Params line up with the `?`s.
 */
function scopeClause(scope, coreSlugs) {
  if (!scope) return { where: "", params: [] };
  const coreIn = coreSlugs.length ? ` OR m.slug IN (${coreSlugs.map(() => "?").join(",")})` : "";
  return { where: ` AND (m.scope IS NULL OR m.scope = ?${coreIn})`, params: [scope, ...coreSlugs] };
}

/** Keyword arm: BM25-ranked FTS5 hits. Lower bm25() == better, so we sort asc. */
function keywordSearch(db, query, limit, { scope = null, coreSlugs = [] } = {}) {
  const match = toFtsQuery(query);
  if (!match) return [];
  // bm25(f, w_slug, w_name, w_desc, w_body) — weight name/description above
  // body so a query matching a fact's title/summary ranks above an incidental
  // body mention.
  const { where, params } = scopeClause(scope, coreSlugs);
  // The FTS5 auxiliary bm25() must reference the TABLE NAME, not a join alias —
  // `bm25(f, …)` on `memories_fts f` fails with a misleading "no such column: f"
  // (measured on this box's SQLite). Alias the table for the JOIN, name it for
  // bm25()/MATCH.
  const rows = db
    .prepare(
      `SELECT f.slug AS slug, bm25(memories_fts, 0.0, 5.0, 3.0, 1.0) AS score
       FROM memories_fts f
       LEFT JOIN memories m ON m.slug = f.slug
       WHERE memories_fts MATCH ?${where}
       ORDER BY score ASC
       LIMIT ?`,
    )
    .all(match, ...params, limit);
  return rows.map((r, i) => ({ slug: r.slug, rank: i + 1, score: r.score }));
}

/** Vector arm: cosine over stored embeddings (brute force — fine at this scale). */
async function vectorSearch(db, query, limit, { scope = null, coreSlugs = [] } = {}) {
  const { where, params } = scopeClause(scope, coreSlugs);
  const rows = db
    .prepare(
      `SELECT v.slug AS slug, v.dims AS dims, v.vector AS vector
       FROM vectors v
       LEFT JOIN memories m ON m.slug = v.slug
       WHERE 1=1${where}`,
    )
    .all(...params);
  if (rows.length === 0) return { results: [], semantic: false, degraded: null };

  const embedder = createEmbeddingProvider();

  // PROVIDER/INDEX MISMATCH GUARD (core-v0.4): a query vector from one provider
  // is meaningless against stored vectors from another — yet exactly that used
  // to happen SILENTLY after a `kickoff pull` lost the local model (the factory
  // auto-fell-back to the 256-dim lexical stub while the index held 384-dim
  // MiniLM vectors, fusing NOISE into the ranking at 2× weight). Dims are the
  // cheap, reliable tell (stub 256 / MiniLM 384 / OpenAI 1536): score only
  // matching rows; none match → skip the arm LOUDLY, never fuse garbage.
  const usable = rows.filter((r) => r.dims === embedder.dims);
  if (usable.length === 0) {
    const stored = [...new Set(rows.map((r) => r.dims))].join("/");
    const avail = semanticAvailability();
    warnSemanticDegraded(
      avail.available
        ? `stored vectors are ${stored}-dim but the active embedder '${embedder.name}' is ` +
            `${embedder.dims}-dim — vector arm skipped; rebuild the index (./run.sh index)`
        : avail.warning,
    );
    return {
      results: [],
      semantic: false,
      degraded: avail.available ? "dims-mismatch" : avail.reason,
    };
  }
  if (usable.length < rows.length) {
    // A mixed-provider index (some rows re-embedded by a different provider) —
    // still serve the matching rows, but say so: the heal is one full rebuild.
    warnSemanticDegraded(
      `${rows.length - usable.length}/${rows.length} stored vectors have foreign dims ` +
        `(mixed-provider index) — rebuild the index (./run.sh index)`,
    );
  }

  let qvec;
  try {
    [qvec] = await embedder.embed([query]);
  } catch (err) {
    // Embedding failed at run time (e.g. model files corrupt/missing + offline).
    // LOUD skip (fail-closed-values: a silent drop trained nobody to fix it).
    warnSemanticDegraded(
      `embedder '${embedder.name}' failed to load (${err.message}) → vector arm skipped; ` +
        `the native embedding runtime (onnxruntime-node) likely isn't built — rebuild it: ${installHint()}`,
    );
    return { results: [], semantic: false, degraded: "embed-failed" };
  }

  const scored = usable.map((r) => ({
    slug: r.slug,
    score: cosine(qvec, JSON.parse(r.vector)),
  }));
  scored.sort((a, b) => b.score - a.score); // higher cosine == better
  const results = scored
    .slice(0, limit)
    .map((r, i) => ({ slug: r.slug, rank: i + 1, score: r.score }));
  return { results, semantic: embedder.semantic, degraded: null };
}

// Per-arm RRF weight (keyword vs vector). Other arms default to 1×.
const ARM_WEIGHTS = { keyword: KEYWORD_WEIGHT, vector: VECTOR_WEIGHT };

/** (Weighted) Reciprocal Rank Fusion: sum w·1/(k+rank) across the arms a slug appears in. */
function rrfFuse(arms) {
  const acc = new Map();
  for (const arm of arms) {
    const w = ARM_WEIGHTS[arm.name] ?? 1;
    for (const hit of arm.results) {
      const prev = acc.get(hit.slug) || {
        slug: hit.slug,
        rrf: 0,
        contributions: {},
      };
      prev.rrf += w / (RRF_K + hit.rank);
      prev.contributions[arm.name] = { rank: hit.rank, score: hit.score };
      acc.set(hit.slug, prev);
    }
  }
  return [...acc.values()].sort((a, b) => b.rrf - a.rrf);
}

/**
 * Did the index get built with a REAL (semantic) embedder? Reads the `meta` table
 * the indexer writes — cheap, no embedding call. Lets callers (the hook) pick
 * keyword-only on a stub index and hybrid on a semantic one without a probe query.
 */
export function indexIsSemantic(dbPath = DEFAULT_DB_PATH) {
  if (!existsSync(dbPath)) return false;
  const db = new DatabaseSync(dbPath);
  try {
    const row = db.prepare(`SELECT value FROM meta WHERE key = 'embedder_semantic'`).get();
    return row?.value === "true";
  } catch {
    return false;
  } finally {
    db.close();
  }
}

// mode: "hybrid" (keyword ⊕ vector, default) | "keyword" (BM25 only — the
// baseline the eval harness compares against to isolate the vector arm's delta).
//
// ── PER-FUNCTION SCOPING (scope / coreSlugs) ─────────────────────────────────
// scope=<function name> restricts BOTH arms to (a) memories declaring that
// function (frontmatter `function:` or the `<name>__slug.md` merge prefix —
// see scopeOf in lib/memory.mjs) and (b) every UNSCOPED memory in the corpus.
// Memories declaring a DIFFERENT function are excluded — that is the measured
// precision fix (herdr-tg, 2026-09-02): fishing in other
// functions' ponds is what floats the cutoff's pool-maximum over the floor.
// coreSlugs=[...] additionally pins specific shared slugs into the pool (the
// tiny cross-function core — ≤5 facts, measured; see hook.mjs).
// scope unset → the exact pre-knob behavior (the whole index is the pool).
export async function retrieve(
  query,
  { k = 5, dbPath = DEFAULT_DB_PATH, mode = "hybrid", scope = null, coreSlugs = [] } = {},
) {
  if (!existsSync(dbPath)) {
    throw new Error(`Index not found at ${dbPath}. Run index.mjs first.`);
  }
  // DoS GUARD (root-cause chokepoint): bound the query ONCE, here, so BOTH arms —
  // the FTS keyword arm AND the embedder's vector arm — see a bounded string. A
  // huge paste otherwise stalls the keyword MATCH (O(n²) OR-fanout) and makes the
  // embedder tokenize megabytes. Normal queries (≪ MAX_QUERY_CHARS) pass through
  // unchanged, so retrieval quality is identical for real turns.
  query = String(query ?? "").slice(0, MAX_QUERY_CHARS);
  const db = new DatabaseSync(dbPath);

  // Pull a wider candidate pool per arm than k, then fuse + trim.
  const pool = Math.max(k * 4, 20);
  const keyword = keywordSearch(db, query, pool, { scope, coreSlugs });
  // Skip the vector arm entirely in keyword-only mode (the eval baseline).
  const { results: vector, semantic, degraded: vectorDegraded = null } =
    mode === "keyword"
      ? { results: [], semantic: false }
      : await vectorSearch(db, query, pool, { scope, coreSlugs });

  const arms = [{ name: "keyword", results: keyword }];
  if (mode !== "keyword") arms.push({ name: "vector", results: vector });
  const fused = rrfFuse(arms).slice(0, k);

  // Hydrate with the fact metadata for display (body included so the hook can
  // surface key lines).
  const getMem = db.prepare(
    `SELECT slug, name, description, type, file, body FROM memories WHERE slug = ?`,
  );
  const out = fused.map((f) => ({ ...getMem.get(f.slug), ...f }));

  const meta = {
    mode,
    semantic, // is the vector arm real or stub-lexical?
    vectorDegraded, // null, or WHY the vector arm was skipped (visible, not silent)
    keywordHits: keyword.length,
    vectorHits: vector.length,
    // Keyword-only ranking (BM25), exposed so callers can see what the vector
    // arm changed — useful for honestly showing the stub's effect vs a real model.
    keywordOnly: keyword.map((h) => h.slug),
  };
  db.close();
  return { results: out, meta };
}

/** GRAPH: a fact's [[link]] neighbours, both directions. */
export function neighbors(slug, { dbPath = DEFAULT_DB_PATH } = {}) {
  const db = new DatabaseSync(dbPath);
  const outgoing = db
    .prepare(
      `SELECT l.to_slug AS slug, m.name, m.type
       FROM links l LEFT JOIN memories m ON m.slug = l.to_slug
       WHERE l.from_slug = ?`,
    )
    .all(slug);
  const incoming = db
    .prepare(
      `SELECT l.from_slug AS slug, m.name, m.type
       FROM links l JOIN memories m ON m.slug = l.from_slug
       WHERE l.to_slug = ?`,
    )
    .all(slug);
  db.close();
  return { outgoing, incoming };
}

// ── CLI ──────────────────────────────────────────────────────────────────────
if (import.meta.url === `file://${process.argv[1]}`) {
  const args = process.argv.slice(2);
  const asJson = args.includes("--json");
  const showGraph = args.includes("--graph");
  const kArg = args.indexOf("--k");
  const k = kArg !== -1 ? Number(args[kArg + 1]) : 5;
  // Drop flags AND the value consumed by --k so it doesn't leak into the query.
  // Guard kArg === -1: kArg + 1 would be 0 and wrongly drop the first query word.
  const kValueIdx = kArg === -1 ? -1 : kArg + 1;
  const query = args.filter((a, i) => !a.startsWith("--") && i !== kValueIdx).join(" ");

  if (!query) {
    console.error('Usage: retrieve.mjs "<query>" [--k N] [--json] [--graph]');
    process.exit(1);
  }

  const { results, meta } = await retrieve(query, { k });

  if (asJson) {
    console.log(JSON.stringify({ query, meta, results }, null, 2));
  } else {
    const semTag = meta.semantic ? "REAL semantic" : "STUB lexical";
    console.log(`\nQuery: "${query}"`);
    console.log(
      `Hybrid: ${meta.keywordHits} keyword + ${meta.vectorHits} vector(${semTag}) candidates → top ${results.length}\n`,
    );
    results.forEach((r, i) => {
      const arms = Object.keys(r.contributions).join("+");
      console.log(`${i + 1}. [${r.type}] ${r.slug}  (rrf=${r.rrf.toFixed(4)}, arms=${arms})`);
      console.log(`   ${r.description || r.name}`);
      if (showGraph) {
        const { outgoing } = neighbors(r.slug);
        if (outgoing.length) {
          console.log(`   → links: ${outgoing.map((n) => n.slug).join(", ")}`);
        }
      }
    });
    console.log("");
  }
}
