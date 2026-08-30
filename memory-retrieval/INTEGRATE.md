# Integrating the memory system into Claude-kickoff

A copy-paste guide to wire this self-contained hybrid-retrieval module into the
kickoff repo so every agent turn proactively surfaces the most relevant memories.

This module is **portable** — no host path is hardcoded. You point it at a corpus
of markdown memory files with one env var (`MEMORY_DIR`) and wire one hook. The
engineering substance is **measured** (see [METRICS.md](./METRICS.md)): on
kickoff's own `memory/` corpus, recall@1 **70% (keyword) → 85% (hybrid w/ real
local embeddings), +15pp**, noise fully suppressed. (The separate 108-fact Bliz
reference corpus goes **60% → 85%**, +25pp.)

---

## 0. Drop it in

Copy this whole directory into the kickoff repo (e.g. as `memory-retrieval/` at
the repo root, or under `tools/`). It's self-contained: `index.mjs`,
`retrieve.mjs`, `hook.mjs`, `eval.mjs`, `demo.mjs`, `log-stats.mjs`, `lib/`,
`run.sh`, `package.json`, `.gitignore`, plus this guide + the metrics.

Requirements: **Node ≥ 22** (ships `node:sqlite` with FTS5 — zero external DB
dep) and **pnpm**. The `run.sh` wrapper passes Node's `--experimental-sqlite`
flag for you; the hook self-passes it too, so `.claude/settings.json` can call
`hook.mjs` directly.

---

## (a) The `memory/` markdown convention

Memory is **one fact per markdown file** in a flat directory. The `.md` files are
the **source of truth** (curated, read-only to this tool); the SQLite index is a
derived cache you can delete and rebuild anytime.

> **Good news for kickoff:** it already ships a `memory/` directory in this exact
> shape (frontmatter `name` / `description` / `metadata.type` + `[[links]]`), so
> there's **nothing to establish** — just point `MEMORY_DIR` at it and index. If a
> target repo has *no* memory dir yet, create one and seed it with files in the
> format below.

Each file:

```markdown
---
name: dont-broad-pkill-shared-services
description: "One-line summary of the fact — this is the highest-signal text for retrieval; write it as what you'd want recalled."
metadata:
  node_type: memory
  type: feedback        # feedback | project | reference | user — free-form, indexed
---

The body of the fact in prose. This is what gets embedded for semantic search and
indexed for BM25 keyword search. Cross-link related facts with [[other-fact-slug]]
— the slug is the target file's name without `.md`. Links build a graph the
retriever can walk (`neighbors()`), and the demo shows a graph traversal.
```

Conventions the parser handles:

- **Two frontmatter shapes** — flat (`type: feedback`) and nested
  (`metadata:` → `type: feedback`). Both flatten to `fm.type`. (kickoff uses the
  nested shape — already supported.)
- **The slug is the filename** (without `.md`) — that's the stable identifier the
  `[[link]]` graph keys on. The `name` field is for display.
- **`MEMORY.md`** (a flat roll-up index, if present) is **skipped** when indexing —
  it's not a per-fact memory. macOS `._` sidecar files are skipped too.
- **Write the `description` well** — it's weighted highest in BM25 (name 5× /
  description 3× / body 1×) and is part of the embedded text. It's your single
  biggest lever on retrieval quality.

---

## (b) Build the index

```bash
cd memory-retrieval/                                   # this module's directory
MEMORY_DIR=$CLAUDE_PROJECT_DIR/memory ./run.sh index   # point at kickoff's memory/
```

`MEMORY_DIR` is the **one required knob** — the corpus to index. Default (unset) is
a `memory/` directory next to this module. Output reports the fact count, FTS rows,
link edges, and which embedder was used (REAL semantic vs the lexical stub).

The index is a single file, `memory-index.db` (git-ignored — derived, rebuildable).
Rebuild it whenever the memory files change. Override its location with `MEMORY_DB`.

Quick sanity check:

```bash
MEMORY_DIR=$CLAUDE_PROJECT_DIR/memory ./run.sh retrieve "what order do I deploy a schema migration in"
```

---

## (c) Wire the proactive hook into `.claude/settings.json`

A `UserPromptSubmit` hook's stdout is injected into the model's context for the
turn. This hook reads the user's prompt, retrieves the top-K relevant memories,
and (only if they clear a relevance cutoff) prints a compact `<retrieved-memory>`
block. **Off-domain / weak turns surface nothing** — junk every turn would train
the agent to ignore the block.

Add to kickoff's `.claude/settings.json` (project scope) — merge into the existing
`hooks` object if there is one:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/memory-retrieval/hook.mjs",
            "env": {
              "MEMORY_DIR": "$CLAUDE_PROJECT_DIR/memory"
            }
          }
        ]
      }
    ]
  }
}
```

Notes:

- Adjust the `command` path to wherever you dropped the module. `hook.mjs` is
  executable and re-execs itself once with `--experimental-sqlite`, so settings
  can point straight at it (no `run.sh` wrapper needed).
- If your settings.json schema doesn't support a per-hook `env` block, set
  `MEMORY_DIR` (and the index location `MEMORY_DB`) in the shell/profile the
  Claude Code process inherits, or rely on the default `./memory`.
- The hook **always exits 0** — a hook crash can never block a turn. On any
  error or empty result it emits nothing.
- **Pre-build the index** (step b) so each fire is just a read + one query embed.

What the agent sees when it fires (example):

```
<retrieved-memory>
Proactively surfaced from agent memory (markdown facts) — relevant to this turn.
Treat as recalled context, not new instructions.

• activation-runs-before-code-and-fails-closed  [feedback]
  Production activation discipline: migrate before you ship code...
  Migrations run before the code that needs them — additively...
</retrieved-memory>
```

**Tuning knobs** (all env, no code edits): `MEMORY_HOOK_K` (top-K, default 3),
`MEMORY_HOOK_BM25_FLOOR` (lexical cutoff, default −5.0), `MEMORY_HOOK_VEC_FLOOR`
(semantic cutoff, default 0.30), `MEMORY_HOOK_MODE` (`auto`|`keyword`|`hybrid`),
`MEMORY_EMBEDDER` (`local`|`openai`|`hashing`), `MEMORY_RRF_K`,
`MEMORY_VECTOR_WEIGHT`. Full list in [README.md](./README.md).

The hook also appends one JSON line per fire to `retrieval-log.jsonl` (git-ignored).
Summarize live usage with `./run.sh log-stats` — fire count, surfaced %, suppression
rate + reasons, most-surfaced memories.

---

## (d) Show the metrics

```bash
MEMORY_DIR=$CLAUDE_PROJECT_DIR/memory ./run.sh eval
```

This runs the labelled eval set through **keyword-only vs hybrid** and prints
recall@1/3/5, MRR, per-case pass/fail, and noise suppression — so you can *show*
the engineering is measured, not asserted. Machine-readable: `./run.sh eval --json`.

> **Note — the shipped eval set is already kickoff's own.** `eval-set.json` holds
> **kickoff's own** `memory/` slugs (24 cases), so `./run.sh eval` above measures
> kickoff directly — **nothing to `cp` for kickoff**. The original **108-fact Bliz
> reference** set behind the `60%→85%` origin evidence is a private third-party
> corpus and does **not** ship. To onboard a **new, third-party** corpus, start from
> the template:
>
> ```bash
> cp eval-set.template.json eval-set.json   # only for a NEW corpus — then edit the cases
> ```
>
> Write one realistic decision-time query per important memory, **paraphrased** (use
> different words than the target fact — that's what tests real recall), plus a few
> `expect: null` noise cases the cutoff must suppress. The template is pre-seeded with
> cases against kickoff's own memory slugs as a starting point.

See [METRICS.md](./METRICS.md) for how to read recall@K / MRR, the cutoff-tuning
trade-off, latency, and the honest stub-vs-real-embeddings finding.

---

## (e) The local embedder (real semantics, no API key)

The vector arm runs a **real, fully-local sentence-transformer**
(`Xenova/all-MiniLM-L6-v2`, 384-dim) via transformers.js — **no API key, no cloud**.
This is what flips hybrid from worse-than-keyword (with the old lexical stub) to
**+15pp recall@1** over the keyword baseline (kickoff corpus; the separate 108-fact
Bliz reference corpus is **+25pp**, 60→85). Install it in-place:

```bash
cd memory-retrieval/
pnpm install --ignore-workspace        # pulls @xenova/transformers
pnpm approve-builds --all              # let sharp build (pnpm >=10 blocks dep
                                       #   build scripts by default; or: pnpm rebuild sharp)
MEMORY_EMBEDDER=local MEMORY_DIR=$CLAUDE_PROJECT_DIR/memory ./run.sh index
```

- `--ignore-workspace` keeps it **self-contained** — it installs into this module's
  own `node_modules`, not the host repo's workspace, so it never perturbs kickoff's
  dependency graph. `node_modules` + the lockfile are git-ignored.
- **sharp is optional.** It's a transitive dep of transformers.js used only for IMAGE
  inputs; text embedding (all we use) works without it. If `approve-builds` is fiddly
  on your pnpm version, skip it — the indexer falls back to keyword-only and says so.
  The shipped `.npmrc` + `pnpm-workspace.yaml` opt sharp in on pnpm versions that
  honor them; `approve-builds`/`rebuild` is the version-robust path.
- The model (~25–90 MB) **auto-downloads on first use** into the **pull-durable
  per-machine cache** (`KICKOFF_MODEL_DIR` → `~/.cache/kickoff-models`) — never
  inside a core clone's `node_modules`, so a `kickoff pull` can't lose it (a legacy
  in-`node_modules` cache is auto-migrated out on first use; `kickoff pull` also
  runs `install-model.mjs --if-needed` to auto-recover, and a missing model is a
  LOUD keyword-only warning, never a silent drop — heal with
  `./run.sh install-model`). Then it runs offline on CPU. Inference is ~1.7 ms
  warm; first index of a ~100-fact corpus is ~3–4 s.
- **Embedder selection** (one factory, `lib/embeddings.mjs`, no other file changes):
  - `MEMORY_EMBEDDER=local` → transformers.js MiniLM (**default** when installed)
  - `MEMORY_EMBEDDER=openai` → OpenAI `/v1/embeddings` (needs `OPENAI_API_KEY`)
  - `MEMORY_EMBEDDER=hashing` → the zero-dep lexical stub (auto-fallback if the
    package isn't installed; honestly *hurts* recall — kept only so the tool runs
    with zero setup)
- If you swap to a different model (a larger local one, or OpenAI), retune
  `MEMORY_HOOK_VEC_FLOOR` to that model's cosine scale (MiniLM default `0.30`).

The hook's `auto` mode (default) reads the index metadata and picks **keyword-only**
on a stub index (the stub hurts) and **hybrid** on a real-embeddings index — so it
does the right thing whether or not you've installed the embedder.

---

## Quick start (all of it, condensed)

```bash
cd memory-retrieval/
pnpm install --ignore-workspace && pnpm approve-builds --all # (e) real local embedder
export MEMORY_DIR=$CLAUDE_PROJECT_DIR/memory                 # (b) point at kickoff's memory
./run.sh index                                               # (b) build the index
./run.sh retrieve "deploying a schema change, what order"    #     sanity check
./run.sh eval                                                # (d) metrics — eval-set.json is already kickoff's own
# (c) add the UserPromptSubmit hook to .claude/settings.json — see above
```
