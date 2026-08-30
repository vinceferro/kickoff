# Hybrid Retrieval Layer over File-Based Agent Memory

A retrieval layer for markdown-file agent memory: **semantic + keyword retrieval**
so the right memory surfaces *proactively* at decision-time instead of being missed
by a flat index scan.

> **Self-contained + portable.** This directory is a drop-in module — zero
> workspace coupling. It points at any corpus of markdown agent-memory files via
> the **`MEMORY_DIR`** env var (default: a `memory/` directory next to this tool).
> Its only runtime dep is the local embedder (`@xenova/transformers`), installed
> in-place with `pnpm install --ignore-workspace`. See **[INTEGRATE.md](./INTEGRATE.md)**
> for the copy-paste wiring guide.

> **Provenance.** Originated as a prototype on a private monorepo. Its origin evidence
> — a **108-fact reference corpus** — is a third party's operational memory and does
> **not** ship, so the `60%→85%` figures it produced are not reproducible from this
> tree; [METRICS.md](./METRICS.md) marks them and describes its cases by kind rather
> than quoting them. Everything that DOES ship is measured on **kickoff's own
> `memory/` corpus** and is reproducible here: the `eval-set.json` cases, and
> `demo.mjs` (`./run.sh demo` prints its ranks live). Point `MEMORY_DIR` at any corpus
> to measure your own numbers (see INTEGRATE.md §eval).

---

## The architecture (decided with the founder)

```
   ┌─────────────────────────────────────────┐
   │  SOURCE OF TRUTH  (read-only, curated)   │
   │  memory/*.md  — one fact per file:       │
   │    frontmatter (name, description, type) │
   │    + body (the fact, with [[links]])     │
   └────────────────────┬────────────────────┘
                        │  index.mjs  (re-buildable anytime)
                        ▼
   ┌─────────────────────────────────────────┐
   │  DERIVED INDEX  (cache — blow away/rebuild)│
   │  SQLite (node:sqlite):                    │
   │    memories       one row per fact        │
   │    memories_fts   FTS5/BM25 keyword search│
   │    links          [[cross-link]] graph    │
   │    vectors        one embedding per fact  │
   └────────────────────┬────────────────────┘
                        │  retrieve.mjs  (hybrid)
                        ▼
   ┌─────────────────────────────────────────┐
   │  HYBRID RETRIEVAL                         │
   │    BM25 keyword  ⊕  vector cosine         │
   │    fused by Reciprocal Rank Fusion (RRF)  │
   │  + graph: a fact's [[link]] neighbours    │
   └─────────────────────────────────────────┘
```

The markdown files **stay the truth**. The SQLite DB is a derived cache: delete
it and rebuild from the files at any time. No operation here writes to memory.

## SQLite library choice

**`node:sqlite`** — the built-in SQLite that ships with Node 22 (22.22.3 on this
box). FTS5 is compiled in and BM25 ranking works. It's experimental, so it needs
the `--experimental-sqlite` flag (the `run.sh` wrapper passes it for you).

Chosen for **zero external dependencies** → maximally portable to the kickoff
repo with nothing to `pnpm add`. Fallbacks if a target box lacks it:
`better-sqlite3` (npm) or `sql.js` (wasm) — both expose the same SQL; only the
open/prepare calls differ.

## How to run

```bash
cd memory-retrieval/                        # this module's directory
export MEMORY_DIR=/path/to/your/memory      # the corpus to index (default: ./memory)

./run.sh index                              # (re)build the index from memory/*.md
./run.sh retrieve "your query here"         # hybrid retrieval, top 5
./run.sh retrieve "query" --k 8 --graph     # more results + show link neighbours
./run.sh retrieve "query" --json            # machine-readable
./run.sh demo                               # the motivating demo (auto-builds index)

# Proactive layer (the loop the demo exposes, now closed):
./run.sh hook "adding a button to the topbar"  # prints the context-injection block
echo '{"prompt":"..."}' | ./run.sh hook        # Claude Code event shape on stdin
./run.sh eval                                  # metrics: recall@K + MRR (kw vs hybrid)
./run.sh log-stats                             # summarize the live retrieval log
```

**The three new pieces** (the "does it work, and prove it" layer):

- **`hook.mjs`** — a Claude Code `UserPromptSubmit`-style hook. Reads the user's
  turn, retrieves, and prints a **compact context-injection block** of the top-K
  memories — with a **relevance cutoff** so weak/off-domain turns surface
  *nothing* (junk every turn is worse than silence). Sub-100ms warm; ~30–40ms
  full process incl. Node start. See **[METRICS.md](./METRICS.md)** + the wiring
  section below.
- **`eval.mjs` + `eval-set.json`** — a labelled `(query → expected-memory)` test
  set + a scorer reporting **recall@1/3/5, MRR, per-case pass/fail, noise
  suppression**, run for **keyword-only vs hybrid** so the vector arm's delta is
  visible. Ready to re-run with real embeddings.
- **`log-stats.mjs`** — summarizes `retrieval-log.jsonl` (the hook's live log):
  fire count, surfaced %, suppression rate + reasons, most-surfaced memories.

**Headline eval result — reference-adopter corpus (108 facts, REAL local embeddings, 2026-06-26):** hybrid with a
real local sentence-transformer (`Xenova/all-MiniLM-L6-v2`) hits **recall@1 85% /
recall@3 90% / recall@5 90% / MRR 0.875**, noise suppression **3/3** — a
**+25pp recall@1** jump over the keyword-only baseline (60%) and a decisive win
over the old lexical *stub* (40%, which actually hurt). The synonym-gap queries
that missed before now hit (KYB→#1, Obsidian-vault→#2). Full BEFORE→AFTER table,
the fusion/cutoff re-tune, latency, and the residual misses:
**[METRICS.md](./METRICS.md)**.

> Run on **kickoff's own `memory/` corpus**, `./run.sh eval` reports **recall@1 85% / recall@3 85% /
> recall@5 95% / MRR 0.872 / noise 4/4** (historical 24-case run — the shipped default is the neutral eval-set template);
> see METRICS.md.

### Wiring the hook into Claude Code

`UserPromptSubmit` hook stdout is injected into the model's context for the turn.
Add to `.claude/settings.json` (project or user scope) — point straight at the
script (it self-passes `--experimental-sqlite` by re-execing once) or at
`run.sh hook`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "$CLAUDE_PROJECT_DIR/memory-retrieval/hook.mjs" }
        ]
      }
    ]
  }
}
```

The hook reads the turn from the event JSON on stdin (`{"prompt": "..."}`), raw
stdin, or argv; **always exits 0** (a hook crash must never block a turn); and on
any error/empty-result emits nothing. **Tuning knobs** (all env, no code edits):
`MEMORY_HOOK_K` (top-K, default 3), `MEMORY_HOOK_BM25_FLOOR` (lexical cutoff,
default −5.0), `MEMORY_HOOK_VEC_FLOOR` (semantic cutoff, default 0.30),
`MEMORY_HOOK_MODE` (`auto`|`keyword`|`hybrid`), `MEMORY_EMBEDDER`
(`local`|`openai`|`hashing`), `MEMORY_RRF_K` (fusion damping, default 10),
`MEMORY_VECTOR_WEIGHT` (default 2), `MEMORY_HOOK_BODY_LINES`, `MEMORY_HOOK_NO_LOG`,
`MEMORY_HOOK_LOG`, `MEMORY_HOOK_TS`. Pre-build the index (`./run.sh index`) so
every fire is just a read + one query embed.

**Point it at your memory corpus** with the `MEMORY_DIR` env var — this is the one
required knob for a new repo. No path is hardcoded; the default is a `memory/`
directory next to this module.

```bash
MEMORY_DIR=/path/to/your/repo/memory ./run.sh index
```

(`MEMORY_DB` overrides the derived-index location; defaults to `memory-index.db`
next to this module.)

## What's WIRED (honest)

| Layer | Status | Notes |
|---|---|---|
| Markdown parse (2 frontmatter shapes, `[[links]]`) | ✅ wired | `lib/memory.mjs` |
| SQLite index + FTS5 + links graph | ✅ wired | `index.mjs` |
| **Keyword retrieval (BM25)** | ✅ wired | `retrieve.mjs` |
| Weighted RRF hybrid fusion | ✅ wired | `RRF_K=10`, vector weight 2× (env-tunable) |
| Graph traversal (neighbours, both directions) | ✅ wired | `neighbors()` |
| **Vector / semantic retrieval** | ✅ **wired — REAL local embeddings** | `Xenova/all-MiniLM-L6-v2` via transformers.js |

**The vector layer now runs a real, fully-local sentence-transformer.** Three
providers sit behind one factory (`lib/embeddings.mjs → createEmbeddingProvider()`):

1. **`LocalEmbeddingProvider`** — REAL, fully-local 384-dim embeddings via
   transformers.js running the ONNX `Xenova/all-MiniLM-L6-v2` model on CPU.
   Mean-pooled + L2-normalised. The model (~25–90MB) auto-downloads on first use
   into the **pull-durable per-machine cache** (`KICKOFF_MODEL_DIR` →
   `~/.cache/kickoff-models` — never inside a core clone's `node_modules`, so a
   `kickoff pull` can't lose it; a legacy in-`node_modules` cache is auto-migrated
   out on first use), then runs offline with no API key. **This is the default**
   (and what the headline numbers above use). Selected automatically when
   `@xenova/transformers` is installed, or forced with `MEMORY_EMBEDDER=local`.
   Reinstall/heal any time: `./run.sh install-model` (a missing model is a LOUD
   one-line warning + keyword-only fallback, never a silent drop).
2. **`OpenAIEmbeddingProvider`** — REAL embeddings via OpenAI `/v1/embeddings`
   (`MEMORY_EMBEDDER=openai`, needs `OPENAI_API_KEY`). A cloud alternative.
3. **`HashingEmbeddingProvider`** — the original deterministic, dependency-free
   stub (hashed token-bag). **Lexical, not semantic.** Kept as the zero-dep
   fallback (`MEMORY_EMBEDDER=hashing`, or auto-selected if transformers.js isn't
   installed). It *hurt* recall — the real model replaced it.

### Install the local embedder

It's a **tool-local** dependency (not a host workspace package), installed in
this directory so it stays self-contained + portable:

```bash
cd memory-retrieval/              # this module's directory
pnpm install --ignore-workspace   # pulls @xenova/transformers
pnpm approve-builds --all         # let sharp build its native binary (pnpm >=10
                                  #   blocks dep build scripts by default)
MEMORY_EMBEDDER=local ./run.sh index   # re-index with real 384-dim embeddings
```

Notes:
- `--ignore-workspace` keeps deps in **this directory's own** `node_modules`, so it
  never perturbs the host repo's dependency graph. `node_modules` + the lockfile are
  git-ignored — re-installable, never committed.
- The `approve-builds --all` step (or `pnpm rebuild sharp`) is needed because pnpm
  ≥10 blocks dependency build scripts by default. The shipped `.npmrc`
  (`onlyBuiltDependencies[]=sharp`) and `pnpm-workspace.yaml` (`allowBuilds`) opt it
  in on pnpm versions that honor those, but `approve-builds` is the version-robust
  fallback. **sharp is optional** (transformers.js only uses it for IMAGE inputs) —
  if it won't build, text embedding still works; the indexer just falls back to
  keyword-only and tells you.

## The extension point (swapping the vector layer)

Everything routes through **one factory** in `lib/embeddings.mjs`. Pick a provider
via `MEMORY_EMBEDDER` — **no other file changes**:

```bash
MEMORY_EMBEDDER=local   ./run.sh index   # transformers.js MiniLM (default, fully local)
MEMORY_EMBEDDER=openai  ./run.sh index   # OpenAI /v1/embeddings (needs OPENAI_API_KEY)
MEMORY_EMBEDDER=hashing ./run.sh index   # the lexical stub (zero deps)
```

A new backend (Voyage / Cohere / a larger local model) is one class implementing
`{ dims, name, semantic, async embed(texts) -> number[][] }` plus a branch in the
factory. The stored-vector cosine in `retrieve.mjs` is provider-agnostic. If you
swap to a model with a different cosine scale, retune `MEMORY_HOOK_VEC_FLOOR`
(the all-MiniLM default is `0.30`).

`retrieve.mjs` does brute-force cosine over stored vectors — fine for hundreds of
facts. For tens of thousands, swap the `vectors` table + cosine scan for
**`sqlite-vec`** (an ANN index); the retriever isolates that behind
`vectorSearch()`.

## Files

| File | Role |
|---|---|
| `lib/memory.mjs` | Parse memory `.md` (frontmatter + body + links); enumerate files |
| `lib/embeddings.mjs` | Embedding providers + the factory (the vector plug-in point) |
| `index.mjs` | Build the derived SQLite index (memories, FTS5, links, vectors) |
| `retrieve.mjs` | Hybrid retriever (BM25 ⊕ cosine → RRF) + graph neighbours + CLI; `mode` (keyword/hybrid) + `indexIsSemantic()` |
| `demo.mjs` | The motivating demo + 3 more queries + graph walk |
| `hook.mjs` | The proactive `UserPromptSubmit` hook — retrieve → cutoff → inject; live-logs each fire |
| `eval.mjs` + `eval-set.json` | Labelled eval set + scorer (recall@K, MRR, noise suppression; keyword vs hybrid) |
| `log-stats.mjs` | Summarize the live retrieval log |
| `METRICS.md` | How to run the eval, interpret recall@K/MRR, tune the cutoff, "how we'll know it works" |
| `run.sh` | Wrapper that passes `--experimental-sqlite` (commands: index/retrieve/demo/hook/eval/log-stats) |

## What would make it production-grade for live agent recall

DONE in this iteration (✅) vs still ahead:

- ✅ **A relevance threshold / cutoff** — built (`hook.mjs evaluateCutoff`): RRF
  floor + keyword grounding + BM25 lexical-strength gate. Off-domain turns surface
  *nothing*; verified 3/3 noise-suppressed in the eval.
- ✅ **An agent hook** — built (`hook.mjs`): runs retrieval on the user's turn,
  injects the top-K, closes the loop the demo exposed. Wiring above.
- ✅ **An eval harness + metrics** — built (`eval.mjs`): recall@K / MRR, keyword
  vs hybrid, noise suppression. So we can *measure* whether it works. See
  [METRICS.md](./METRICS.md).
- ⬜ **Real embeddings** (the one stub → swap above) — the single biggest upgrade;
  unlocks synonym/paraphrase recall the keyword arm can't reach. The eval is built
  to re-run after this and quantify the gain (the four paraphrase misses in
  METRICS.md are the predicted beneficiaries).
- ⬜ **Incremental indexing** by `mtime` instead of full rebuild (already stored).
- ⬜ **Chunking long facts** before embedding (some bodies are large; one vector
  per fact blurs multi-topic facts).
- ⬜ **Graph-boosted re-ranking**: lift facts linked to already-strong hits
  (the `links` table is built and ready for this).
