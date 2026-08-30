# Does the proactive memory layer actually work? — metrics & eval

> "Ground it in metrics so we know if it works." This doc is the measurement
> story for the proactive memory hook: **offline eval** (retrieval quality on a
> labelled set), the **live log** (real usage), and the **north-star** (catching
> memory-preventable errors like the chrome-miss). Prototype on
> `proto/memory-retrieval`; not merged.
>
> **In kickoff:** the headline numbers below are measured on *kickoff's own* `memory/` corpus by
> `./run.sh eval` — **recall@1 85% · recall@3 85% · recall@5 95% · noise-suppression 4/4** (24-case
> paraphrased eval-set: 20 positive + 4 noise). The technique originated on an original **108-fact
> reference-adopter corpus** (provenance — see README "Provenance"); the deeper *per-query* walkthroughs further
> down still illustrate that reference corpus, not the kickoff set. See the repo `README.md` +
> `scripts/wire-memory-hook.sh`. Re-run for any corpus with `./run.sh eval`.

---

## TL;DR — the headline numbers (REAL local embeddings · eval re-verified 2026-06-28)

20 labelled decision-time queries + 4 noise queries. `./run.sh eval`. The vector
arm runs a **real local sentence-transformer** (`Xenova/all-MiniLM-L6-v2`,
384-dim, via transformers.js — no API key, no cloud). **Keyword baseline vs. current hybrid:**

| config                          | recall@1 | recall@3 | recall@5 | MRR   | noise |
|---------------------------------|----------|----------|----------|-------|-------|
| keyword (BM25) — baseline       | 70.0%    | 90.0%    | 95.0%    | 0.804 | 4/4   |
| hybrid (lexical stub) — historical¹ | 40.0% | 55.0%    | 65.0%    | 0.481 | 3/3   |
| **hybrid (REAL embeddings) — current** | **85.0%** | **85.0%** | **95.0%** | **0.872** | **4/4** |

¹ *Historical* — the pre-real-embeddings lexical **stub** on an earlier/smaller eval-set
(hence noise 3/3, not 4/4). Kept for the before→after arc but **not re-derivable** on the
current set (the stub was replaced by real embeddings). The two live rows (keyword +
current hybrid) are reproducible now with `./run.sh eval`.

**The headline:** real embeddings lift **recall@1 from 70% → 85% (+15pp)** — the
decisive metric, because the hook injects the *top* memory and a right-answer-at-rank-1
is what actually prevents the re-litigated mistake. **recall@5 holds at 95%**, **MRR
rises 0.804 → 0.872**, and **noise stays fully suppressed (4/4)**. recall@3 sits at
rough parity (90% → 85%, −5pp) — the vector arm trades a little mid-rank breadth for
much sharper rank-1 precision. The earlier lexical *stub* actually *hurt* (it only
reinforced word overlap); the real model adds genuine synonym/paraphrase recall the
keyword arm structurally cannot reach, and concentrates it at rank 1.

**Read this honestly:**

- **The low-lexical-overlap paraphrases — where keyword search is blind — are exactly
  where the vector arm pays off, and it pulls them to rank 1.** Live example: "I adjusted
  some frosted-glass blur styling and it looks flawless in my headless screenshots — safe
  to tell him it's confirmed working on his iPhone?" → `the-render-is-not-the-device` at
  **#1**, with almost no shared content word between the query and the memory — pure
  semantic recall the BM25 arm structurally cannot reach.
- **Two fusion/cutoff changes were needed to realise the gain** (both env-tunable,
  documented below): weighted RRF (`RRF_K=10`, vector weight 2×) so a strong
  vector-#1 hit isn't buried by a crowd of lexically-adjacent facts; and a
  pool-wide vector-strength cutoff (`VEC_FLOOR=0.30`) calibrated to the MiniLM
  cosine scale so weak-keyword paraphrases surface while noise stays suppressed.
- **Noise suppression held at 4/4** — the off-domain probes (a ribeye recipe, a World
  Cup score, a robot-vacuum upgrade, a parental-leave policy) still surface **nothing**.
  The cosine floor (0.30) sits above the noise ceiling (~0.25) with margin; the
  lexical-strength + keyword-grounding gates back it up.
- **A few residual misses remain** — the most abstract paraphrases, with neither a strong
  lexical nor a strong semantic anchor in the corpus (recall@5 95% = one positive still
  outside the top 5; recall@1 85% = three not yet at rank 1). The honest ceiling of a small
  CPU model on this set.

Cost: per-query embed is ~1.7ms warm; the hook is ~265ms end-to-end (vs ~31ms
keyword-only) — the delta is one-time transformers.js/ONNX init per hook process.
See **Performance** below.

---

## How to run

```bash
cd tools/memory-retrieval
./run.sh eval              # both configs, full per-case report + delta
./run.sh eval --json       # machine-readable aggregates (for CI / tracking)
./run.sh eval --config keyword   # one config only
```

The harness auto-builds the index if missing. The labelled set is
`eval-set.json` — edit it to add cases (each is `{query, expect, note}`; an
`expect: null` case is a NOISE case the cutoff must suppress).

> **Current machine-readable figure lives in [`metrics.json`](./metrics.json)** — `./run.sh refresh-metrics`
> rebuilds the index on the live corpus, re-derives it, and updates the board; `./run.sh metrics-status`
> reports FRESH/STALE by comparing its `corpus_size` to the live `memory/*.md` count (so the number is never a
> stale hand-run snapshot). Wire it to auto-refresh on memory change with `scripts/wire-metrics-refresh.sh`.

---

## Interpreting the metrics

- **recall@K** — fraction of positive cases where the expected memory is in the
  top K. **recall@1 and recall@3 are the ones that matter for the hook**, because
  it injects only the top `TOP_K` (default 3). A memory that retrieves at #7 is
  correct-but-useless — it never reaches the model.
- **MRR (Mean Reciprocal Rank)** — average of `1/rank` (0 on a miss). Rewards
  ranking the right memory *high*, not just *somewhere*. MRR 0.65 ≈ "the right
  memory is, on average, around rank 1.5 when it's found."
- **noise-suppress** — `N/total` noise cases the cutoff correctly silenced. This
  must stay at `total/total`; a regression here means the hook is injecting junk.
- **DELTA (keyword → hybrid)** — what the vector arm changes. **Positive on the metric
  that matters with real embeddings (+15pp recall@1, MRR +0.07; recall@5 holds at 95%)** —
  that rank-1 lift is the measured value of semantics: synonym/paraphrase recall the keyword
  arm structurally cannot reach, concentrated at the top. (recall@3 is −5pp — a little
  mid-rank breadth traded for rank-1 precision. With the *stub* the whole delta was
  negative — lexical overlap reinforced, no new recall.)

### The predicted beneficiaries — confirmed

Before real embeddings, the misses were all **low-lexical-overlap paraphrases** —
exactly where keyword search is blind. Real embeddings were predicted to fix them.
**They did.**

> **The queries below are described by KIND, not quoted.** This corpus is a third
> party's operational memory and does not ship, so its literal queries and memory
> titles are withheld. **The ranks are the real measured outcomes** — nothing here is
> reconstructed or invented. For a fully reproducible worked example, `./run.sh demo`
> runs against kickoff's own public `memory/` corpus and prints its ranks live.

| paraphrase kind (query ↔ memory) | before (keyword) | after (real hybrid) |
|---|---|---|
| **acronym gap** — the query spells out a process the memory names by its initials | MISS | **#1** ✅ |
| **synonym drift** — the query's word for a thing and the memory's word differ entirely | MISS | **#2** ✅ |
| **situation → policy** — a concrete "should I do this right now?" vs. a standing rule | #? weak | **#1** ✅ |
| **symptom → model** — a user-facing error vs. the data model that explains it | weak | **#1** ✅ |
| **action → incident** — "I'm about to run X" vs. the postmortem of when X went wrong | #2 | **#1** ✅ |

The query and the memory mean the same thing in different words — a semantic vector
captures it, BM25 cannot. Two abstract paraphrases still miss (a comms-style rule and a
host-load rule): no strong lexical *or* semantic anchor — the honest ceiling of a small
CPU model on a 108-fact corpus.

---

## Tuning the relevance cutoff

The cutoff is the "don't surface junk" guard. It lives in `hook.mjs`
(`evaluateCutoff`) and is mirrored in `eval.mjs` (`cutoffSurfaces`) so the eval
measures *actually-surfaced* behaviour. A hit must clear:

1. **RRF floor** (`MEMORY_HOOK_RRF_FLOOR`, default `0.016`) — now only a sanity
   backstop. Under weighted-RRF with small `k`, raw RRF magnitude no longer
   separates noise (a lone rank-1 hit already scores high), so the real work moved
   to the per-arm strength gates below.
2. **keyword grounding** — at least one real BM25 hit must exist (kills gibberish:
   no corpus term matches → `keywordHits===0` → suppress).
3. **lexical strength** (`MEMORY_HOOK_BM25_FLOOR`, default `-5.0`) — some hit in the
   pool must have BM25 ≤ the floor (BM25 is negative; *more negative = stronger*).
   A real query lands a memory at a strong BM25 (−9…−20); an off-domain question
   only grazes one on filler words (≈ −2…−4). (Stop words are stripped first — see
   `retrieve.mjs`.)
4. **semantic strength** (`MEMORY_HOOK_VEC_FLOOR`, default `0.30`) — *new with real
   embeddings*. Some hit's vector cosine must clear the floor. This is what lets a
   pure-synonym query with **no** strong keyword (e.g. "where do I find the Obsidian
   notes now", best BM25 only ≈ −2.9) still surface, because the target's cosine
   (0.33) clears 0.30 while off-domain queries stay ≤ 0.25.

**Two changes from the stub-era cutoff:** (a) the strength gates now scan the
**candidate pool**, not just hit #1 — a strong unique signal can fuse to rank 2-3
(the vault-moved fact is vector-#1 but keyword-absent, so it lands at #2 behind a
keyword-grounded neighbour; gating only on #1 wrongly suppressed it). (b) the
vector floor is calibrated to the **all-MiniLM-L6-v2 scale** (genuine paraphrase
matches run ~0.30–0.55 for this model, *not* the 0.55 a different model might use —
retune `VEC_FLOOR` if you swap the embedder).

**Tuning trade-off / calibration evidence (this eval set):** noise tops out at
BM25 ≈ −2.8 and cosine ≈ 0.25; the weakest legit semantic hit (the vault query)
sits at cosine 0.33. `VEC_FLOOR=0.30` separates them with margin. Lower it and
noise leaks; raise it past 0.33 and the vault query is suppressed again.

Sweep the floors AND the fusion knobs without code edits:

```bash
MEMORY_HOOK_BM25_FLOOR=-6 ./run.sh eval   # stricter lexical gate
MEMORY_HOOK_VEC_FLOOR=0.35 ./run.sh eval  # stricter semantic gate (watch vault query drop)
MEMORY_HOOK_VEC_FLOOR=0.25 ./run.sh eval  # looser (watch noise leak)
MEMORY_RRF_K=20 MEMORY_VECTOR_WEIGHT=1 ./run.sh eval  # back toward unweighted RRF
```

---

## The live log — measuring real usage

Offline eval is a fixed labelled set; the **live log** is what actually happens
turn-to-turn. The hook appends one JSON line per fire to `retrieval-log.jsonl`
(timestamp, query summary, surfaced memories + RRF, whether the cutoff
suppressed and why). Summarize:

```bash
./run.sh log-stats
```

reports **fire count · surfaced% · suppressed% · avg memories/fire · suppression
reasons · most-surfaced memories**. What to watch:

- **Suppression rate is HEALTHY when high** — most turns don't need a memory.
  Runaway suppression on turns that *should* match means the cutoff is too tight.
- **A few facts dominating "most-surfaced"** → those facts are too broad (match
  everything) or genuinely central. Dead facts that never surface are candidates
  to sharpen or retire.
- The timestamp comes from `MEMORY_HOOK_TS` (caller-provided, since `Date.now()`
  can be restricted in some sandboxes) and falls back to ISO `new Date()`.

---

## Performance — latency (real local embedder)

The hook runs **every turn**, so latency matters. Measured on this box (Node
22.22.3, CPU-only ONNX):

| path | latency | notes |
|---|---|---|
| query embed — warm | **~1.7ms** | one MiniLM forward pass, already-loaded pipeline |
| query embed — cold | ~217ms | includes transformers.js + ONNX-runtime init + model load from disk cache |
| **hook end-to-end — real hybrid** | **~265ms** | fresh process per fire → pays the cold init each time |
| hook end-to-end — keyword-only | ~31ms | no embedder loaded (the prior baseline) |
| corpus index (108 facts, batch embed) | ~3-4s | one-time, on `./run.sh index` |

**The honest read:** inference itself is trivial (~1.7ms). The ~230ms hook delta
is almost entirely **one-time library/model init** that a short-lived hook process
re-pays on every fire (the model is cached on disk after first download — there is
no network call per turn). 265ms once per user prompt is acceptable for a proactive
hook, but if it ever needs to be hot, the fix is a **warm embedding daemon** (a
persistent process that holds the pipeline; the hook talks to it over a socket) —
that would drop the hook to the keyword-only ~31ms + ~2ms embed. Out of scope for
this experiment; noted as the obvious next optimisation. The first run also does a
one-time **model download** (~25–90MB) which is then cached under
`node_modules/@xenova/.../.cache`.

### Incremental / auto-reindex (self-healing index)

The hook now **self-heals** the index: a cheap staleness check every turn and, on a
hit, an INCREMENTAL reindex that re-embeds **only the changed files** (reusing every
unchanged embedding) before retrieving — so an edited/added/deleted memory is
recall-ready the very next turn, with no manual `./run.sh index`. The cost is bounded
because the work scales with *what changed*, not with corpus size:

| path | kickoff (45 facts) | reference adopter (108 facts) | notes |
|---|---|---|---|
| full build (`./run.sh index`)   | ~4.0s wall      | ~9.97s            | O(N) embeds — every fact re-embedded |
| staleness check (no change)     | ~0.4ms / call   | —                 | stat-scan + 2 meta SELECTs, no file reads |
| no-op reindex (mtime touch only)| ~18ms (0 embeds)| —                 | refreshes the signal, embeds nothing |
| 1-file incremental              | ~0.33s (**~12×**) | ~0.27s (**~37×**) | ~one embed + a single transaction |

**The read:** the speedup over a full rebuild **scales with corpus size** — a full
build is O(N) embeds, an incremental is ~one embed regardless of N, so the bigger the
corpus the larger the win (**~12×** at 45 facts → **~37×** at 108). Inside a turn the
hook calls `reindexIncremental({ allowFullRebuild: false })`: a corrupt / old-schema DB
throws rather than triggering a ~seconds-long full rebuild that could blow the hook
timeout — it's caught and retrieval proceeds on the existing index (**fail-open**). The
operator heals a corrupt/old DB with a manual `./run.sh index`. Disable the whole
feature with `MEMORY_AUTO_REINDEX=0`.

---

## How we'll know it works — the three-legged answer

1. **Offline eval (retrieval quality).** recall@K / MRR on the labelled set, run
   for keyword vs hybrid. **Bar cleared:** real embeddings make hybrid recall@1
   **85% > keyword 70%** (recall@5 holds at 95%, noise at 4/4) — the low-overlap
   paraphrases the keyword arm missed now rank #1; see the headline table at the top.
2. **Live log (real usage).** Does it fire sensibly — surfacing on real
   decision-time turns, staying quiet on the rest? `log-stats` is the read-out.
3. **North-star (memory-preventable errors).** The whole reason this exists: an agent
   put an action button into a nav bar that a standing design rule reserved for chrome.
   The memory forbidding exactly that **existed and was not surfaced at decision-time**.
   The reference eval included that exact moment as a case, and the hook ranked it
   **#1 and injected it** — the miss would not have happened. The ultimate metric is
   *fewer re-litigated, memory-preventable mistakes* — which the offline + live legs are
   proxies for until there's enough real traffic to count directly.

   The same shape, from kickoff's own corpus and reproducible via `./run.sh demo`: a
   headless-Chromium screenshot treated as proof a UI worked on a phone, while
   `the-render-is-not-the-device` sat unread in `memory/`. The hook ranks it **#1**.

---

## What would move the numbers (ranked)

1. ~~**Real embeddings**~~ — **DONE** (2026-06-26). Local `all-MiniLM-L6-v2` via
   transformers.js. Lifted the hybrid delta to **+15pp recall@1** (rank-1 precision —
   the metric the hook depends on); the predicted low-overlap paraphrase misses are now
   hits. This was the biggest lever and it paid off.
   Remaining embedding upgrades: a larger model (`all-mpnet-base-v2`, 768-dim) or
   OpenAI `text-embedding-3` for the last 2 abstract misses (retune `VEC_FLOOR`).
2. **Acronym / synonym expansion** at index or query time (KYB↔business
   verification, rg↔ripgrep↔search, vault↔Obsidian↔notes) — cheap, helps even
   keyword-only, and complements embeddings.
3. **Graph-boosted re-ranking** — lift facts `[[linked]]` to a strong hit (the
   `links` table is already built; the demo walks it).
4. **Per-fact `trigger` field** in the memory frontmatter (a curated "surface me
   when…" phrase) — turns retrieval from inferred to partly authored; highest
   precision for the facts that matter most.
5. **Chunking long facts** before embedding — some bodies are large; one vector
   per multi-topic fact blurs it.
