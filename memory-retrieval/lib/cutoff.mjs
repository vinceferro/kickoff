// cutoff.mjs — the relevance gate, as ONE shared module.
//
// Extracted from hook.mjs so the hook and the eval harness run the SAME gate
// object instead of a transcription of it. The drift this closes is real: the
// seed eval harness (herdr-tg's, 2026-09-02) transcribed the gate by hand and
// carried RRF_FLOOR 0.0001 where the hook ships 0.016 — harmless at these
// scales (a single-arm rank-1 is ~0.091, so the RRF floor never binds), but a
// hand-mirrored gate is a floor-tune away from silently measuring a different
// hook. Import this; never copy it.
//
// The gate answers ONE question: should the hook surface ANYTHING for this
// turn? Suppressing a weak query is a FEATURE (a block of irrelevant memory
// every turn trains the agent to ignore the block).

// Indirect process.env read, matching the repo's knob idiom (runtime knobs are
// not build inputs).
const env = process.env;

// RELEVANCE CUTOFF — the core "don't surface junk" guard. The retriever ALWAYS
// ranks SOMETHING #1 (BM25 + RRF never return empty for any overlapping term),
// and under weighted-RRF with a small k the raw RRF magnitude no longer separates
// noise from signal (a lone rank-1 hit already scores high) — so the RRF floor is
// only a sanity backstop. The REAL guard is per-arm STRENGTH over the candidate
// pool. We surface iff SOME hit in the pool clears a strength bar on either arm:
//
//   (a) keyword grounding: at least one KEYWORD (BM25) hit must exist — real
//       lexical overlap with the corpus. Kills pure gibberish (keywordHits===0).
//   (b) lexical STRENGTH: some hit's BM25 must be ≤ BM25_FLOOR (BM25 is negative;
//       MORE negative == stronger, more specific match). A real query lands a
//       specific memory at a strong BM25 (e.g. −9…−20); an off-domain question
//       only grazes a memory on incidental words (BM25 ~ −2…−4). Suppresses
//       "weather forecast tomorrow" / "sourdough recipe".
//   (c) SEMANTIC strength: some hit's vector cosine must be ≥ VEC_FLOOR. This is
//       what REAL embeddings add — a pure-synonym query with NO strong keyword
//       (e.g. "where do I find the Obsidian notes now", whose best BM25 is only
//       ~−2.9) still surfaces because the target's cosine clears the floor, while
//       off-domain queries stay below it.
//
// We check the candidate POOL (top-K), not just hit #1: a strong unique signal can
// live at rank 2-3 after fusion (the vault-moved fact is vector-#1 but keyword-
// absent, so it fuses to #2 behind a keyword-grounded neighbour). Gating only on #1
// would wrongly suppress it. The two floors are calibrated against the eval set:
// noise tops out at BM25~−2.8 / cosine~0.25; the weakest legit semantic hit
// (the vault query) sits at cosine 0.33 — VEC_FLOOR 0.30 separates them with margin.
//
// ── THE MEASURED LIMIT (herdr-tg, 2026-09-02 — why scoping exists) ───────────
// A pool-maximum vs a FIXED floor is a multiple-comparisons trap: draw more
// candidates from the same score distribution (a bigger corpus OR a bigger K)
// and the maximum rises while the bar does not. Measured on real operator
// turns: fires 44% on a 16-memory own corpus, 79% on the 233-memory merged
// corpus — same queries, same gate, only distractors grew. Retuning the floors
// for 233 just pushes the same failure out to 500. The fix is NOT a better
// floor here; it is SCOPING THE POOL (MEMORY_HOOK_FUNCTION — see hook.mjs):
// query the function's own memories, not the flat merged corpus.
export const BM25_FLOOR = Number(env.MEMORY_HOOK_BM25_FLOOR || -5.0);
// Vector cosine floor for the all-MiniLM-L6-v2 scale. Genuine paraphrase matches
// for this model run ~0.30-0.55; off-domain queries stay ≤0.25. (A different model
// — e.g. OpenAI text-embedding-3 — has a different scale; retune if you swap it.)
export const VEC_FLOOR = Number(env.MEMORY_HOOK_VEC_FLOOR || 0.3);
export const RRF_FLOOR = Number(env.MEMORY_HOOK_RRF_FLOOR || 0.016);
export const REQUIRE_KEYWORD_GROUNDING = env.MEMORY_HOOK_NO_KEYWORD_GUARD !== "1";

/**
 * The relevance gate. Returns { surface: boolean, reason }. Called with the
 * fused top-K results + the retrieve() meta (keywordHits / semantic).
 */
export function evaluateCutoff(results, meta) {
  if (results.length === 0) return { surface: false, reason: "no-results" };
  const top = results[0];
  // RRF floor is now only a sanity backstop (weighted-RRF magnitudes don't
  // separate noise) — still reject a degenerate near-zero top.
  if (top.rrf < RRF_FLOOR) {
    return { surface: false, reason: `below-rrf-floor(${top.rrf.toFixed(4)}<${RRF_FLOOR})` };
  }
  if (REQUIRE_KEYWORD_GROUNDING && meta.keywordHits === 0) {
    return { surface: false, reason: "no-keyword-grounding" };
  }
  // Strength gate over the candidate POOL (not just hit #1): surface iff SOME hit
  // clears a strength bar on either arm. A strong unique signal can land at rank
  // 2-3 after fusion (a vector-only hit fuses behind a keyword-grounded neighbour).
  let bestBm25 = Number.POSITIVE_INFINITY; // more negative == stronger
  let bestVec = Number.NEGATIVE_INFINITY;
  for (const r of results) {
    const kw = r.contributions?.keyword?.score;
    const vec = r.contributions?.vector?.score;
    if (kw !== undefined && kw < bestBm25) bestBm25 = kw;
    if (vec !== undefined && vec > bestVec) bestVec = vec;
  }
  const strongKeyword = Number.isFinite(bestBm25) && bestBm25 <= BM25_FLOOR;
  const strongVector = meta.semantic && Number.isFinite(bestVec) && bestVec >= VEC_FLOOR;
  if (!strongKeyword && !strongVector) {
    const bm = Number.isFinite(bestBm25) ? bestBm25.toFixed(2) : "n/a";
    const vc = Number.isFinite(bestVec) ? bestVec.toFixed(3) : "n/a";
    return {
      surface: false,
      reason: `weak-match(bm25=${bm}>${BM25_FLOOR}, vcos=${vc}<${VEC_FLOOR})`,
    };
  }
  return { surface: true, reason: "ok" };
}
