# Brownfield DevEx — the design for adopt · run · upgrade · eject

**Status: DESIGN PROPOSAL — nothing below is built unless explicitly marked "exists today."**
Grounded on the one real adopter (`~/bliz-repo`, adopted at `core-v0.1` from a pinned
`~/kickoff-core` clone) and on the installed `claude` v2.1.199 (verified 2026-07-06). Every
claim about current behaviour was verified against the actual files; every claim about proposed
behaviour is a proposal. Both load-bearing spikes have since been RUN and PASS (§7) — `@import`
loads on 2.1.199 and a `--plugin-dir` plugin carries the hook + skills; the remaining unknown is
the plugin-cache layer (Fix 3, §1.3 / §7).

The operator's steer this answers: **plug-and-play in any repo, easy integrate + easy
de-integrate, no PATH install** — with "a contained folder" as the leading hypothesis.

---

## 0. The honest headline: containment is a contract, not a folder

A literal single self-contained folder is **impossible for the interactive path**. Claude Code
discovers its config from fixed locations — root `CLAUDE.md`, `.claude/settings.json`,
`.claude/agents/`, `.claude/skills/`, `.mcp.json` — and a `CLAUDE.md` inside an arbitrary
subfolder is not auto-loaded at launch (verified: Bliz's per-package `CLAUDE.md`s load
on-demand only; this repo's own root `CLAUDE.md` is what sessions actually receive). The
headless launcher path *could* be made zero-footprint via `--plugin-dir`/`--settings`/
`--add-dir` (flags verified present in v2.1.199, unused today), but a human typing `claude`
in the adopter repo gets pure fixed-location discovery, and that path must work.

So the design redefines "contained" as the strongest thing the discovery architecture
permits — **accounted-for spread**:

> **One owned folder (`.kickoff/`) + the engine entirely outside the repo (`~/kickoff-core`)
> + a small, marker-delimited, manifest-recorded set of touches in CC's fixed homes + one
> command that provably reverses all of it.**

This is *more* de-integratable than a literal vendored folder would be: `rm -rf` on a folder
would miss the seams CC forces into fixed homes, and a manifest makes removal exact.

---

## 1. The recommended architecture

### 1.1 Three classes, not two

`CONTRIBUTING.md` §2 draws ENGINE (pulled, pinned, lives in `~/kickoff-core`) vs INSTANCE
(per-repo data, never upstream). Every live defect found in the Bliz deployment sits in a
class that table has no row for:

- the stale `mission-control/mc-update.py` copy (md5 `3ae1f0d8` vs pinned `e8401e8a`) that
  preflight #6 cannot see, because #6 checksums the clone, not repo-relative copies;
- `.claude/skills/` **empty** at Bliz — scan/review/harden/preview never arrived, despite
  `adopt` SKILL.md step 5 promising the copy;
- `.claude/ORCHESTRATION.md` parked and **never auto-loaded** — the coordinator charter is
  a placebo in every interactive session;
- the memory hook is **not** in Bliz's tracked `.claude/settings.json` at all (that file
  carries only `enabledPlugins` + a `SessionStart` entry). The live hook sits in the gitignored
  `settings.local.json` as a `UserPromptSubmit` entry exec'ing `~/bliz-memory/hook.mjs`
  — a **third forked copy** of the retrieval code (md5 `7eef163b` vs pinned `b8628dd9`), while
  the repo's `memory-retrieval/` holds only a DB. It is **live split-brain**: the hook inlines
  `MEMORY_DIR` + floors but **not** `MEMORY_DB`, so it silently defaults to
  `~/bliz-memory/memory-index.db` while `instance.env` declares the repo path — two
  *different* databases (`c9fe9046` vs `42532810`). §5's "retrieval silently degrades" is not a
  future risk here; it is **already happening**. (The earlier draft mis-attributed
  kickoff-itself's `settings.json:8` hook to Bliz — corrected.)

The missing class:

| Class | Definition | Transport | Lives |
|---|---|---|---|
| **ENGINE** | generic code + capabilities | `kickoff pull`, tag-pinned | `~/kickoff-core` only |
| **SEAM** *(new)* | engine-shaped thin files **required inside the repo** — whether CC's fixed-location discovery forces them there (the `CLAUDE.md` block, the SEAM `KICKOFF.md`) or the mechanism does (the `.kickoff/bin/` shims). *Not* "forced by CC discovery" specifically — that phrasing was too narrow; the shims are SEAM yet `.kickoff/` is no CC fixed home. | **generated** from templates in the pinned tag, recorded in the manifest with creation hash, **regenerated (never hand-merged) on pull** | the repo, thin |
| **INSTANCE** | this repo's data, config, conventions, and the domain crew authored for it | adopter-owned from day one, never upstream | the repo (mostly `.kickoff/`) |

Naming SEAM and giving it one transport discipline (generate + manifest + regenerate) closes
all four live gaps with one mechanism instead of four patches. It is the `core.lock` insight
extended to the CC-config layer that `core-manifest.txt` currently misses.

### 1.2 What lands where (the diagram-in-prose)

```
MACHINE LEVEL (one per box)
  ~/kickoff-core/                     ← THE ENGINE. Read-only clone, pinned to a core-v* tag.
    scripts/                            supervisor, session-run, preflight, kickoff CLI, scanners
    mission-control/mc-update.py        invoked ONLY via shims — never copied into a repo again
    memory-retrieval/                   hook + index code — never copied into a repo again
    plugin/                             ← NEW: the kickoff CC plugin (skills scan/review/harden/
                                          preview/bootstrap/adopt/eject · generic agents planner/
                                          builder/reviewer/deployer · the memory UserPromptSubmit
                                          hook · chrome-devtools MCP declaration)
  ~/box-ingress/  → promoted into core  ← caddy multi-app ingress (see §4)
  ~/.claude/channels/telegram-<bot>/    per-instance channel state (out of repo, by design)

ADOPTER REPO
  .kickoff/                           ← THE ONE OWNED FOLDER (grows from config-only to the
                                         whole instance layer)
    instance.env                        per-repo config (exists today)
    core.lock                           the engine pin (exists today; format widens, §2.3)
    adopt-manifest.json                 ← NEW: the adoption receipt — every touch recorded
    KICKOFF.md                          ← NEW (SEAM, engine-generated): the coordinator charter
                                          (replaces .claude/ORCHESTRATION.md), reached via @import
                                          from the CLAUDE.md block; regenerates cleanly on pull,
                                          so engine charter improvements reach adopters
    KICKOFF.local.md                    ← NEW (INSTANCE, adopter-owned): repo-tailored charter
                                          additions, @import'd BY KICKOFF.md; never regenerated,
                                          survives every pull (the managed-block pattern one level
                                          down — see §2.3 for why the split is load-bearing)
    bin/                                ← NEW: generated 3-line shims (mc, memory-hook, …)
                                          that source instance.env and exec $KICKOFF_CORE_DIR code
    state/                              ← NEW: mission-state.json, TRACKER.md render,
                                          memory-index.db (paths already parameterised by
                                          instance.env; preflight 1b already validates them)
    .gitignore                          ← NEW: dir-local ignore for runtime/state — adopt never
                                          edits the adopter's root .gitignore
    supervisor.log (rotated), locks     runtime (gitignored)

  FIXED-HOME TOUCHES (the irreducible seams — all manifest-recorded)
    CLAUDE.md                           theirs, untouched EXCEPT a 3-line marker-delimited block:
                                          <!-- kickoff:begin core-v0.2 -->
                                          @.kickoff/KICKOFF.md
                                          <!-- kickoff:end -->
                                        (drafted whole only if the repo has none — then it is
                                        an adopter asset, tagged so in the manifest)
    .claude/settings.json               key-level merge: enabledPlugins entry (+ nothing else
                                        once the memory hook moves into the plugin); exact JSON
                                        paths recorded for exact un-merge
    .claude/agents/<domain>-*.md        the domain crew adopt AUTHORS FOR this repo (Bliz's
                                        pos-app, api-money, …) — instance-seeded, adopter-owned,
                                        manifest-tagged `seeded-instance`
```

Gone from the repo relative to today: the copied `mc-update.py` (→ shim), the
`memory-retrieval/` code ambiguity (→ plugin hook + shim), `.claude/ORCHESTRATION.md`
(→ `.kickoff/KICKOFF.md`), `.mcp.json` (→ folds into the plugin), root `TRACKER.md`
(→ `.kickoff/state/`, optional root symlink — operator fork #6), and the generic eng crew
files (→ plugin).

### 1.3 The plugin (capability delivery — the biggest single fix)

Skills currently do not reach an adopter at all (gap: Bliz `.claude/skills/` empty). Copying
was the wrong transport anyway — unpinned copies drift, which is the disease the pull model
exists to kill (live specimen: `mc-update.py`). The fix is idiomatic on this box: the Telegram
control plane already ships as `plugin:telegram@claude-plugins-official`, and
`~/.claude/plugins/installed_plugins.json` shows **nine** plugins in production use (of which
three are project-scoped — live proof that per-repo `enabledPlugins` enablement works, not just
user-global).

Package the CC-discovered engine layer as a plugin at `~/kickoff-core/plugin/`:

- **Headless path**: `session-run.sh` adds `--plugin-dir "$KICKOFF_CORE_DIR/plugin"` at its
  exec (~line 228). Zero repo footprint.
- **Interactive path**: one `enabledPlugins` entry in the repo's `.claude/settings.json`
  (local-path marketplace), manifest-recorded. Per-repo enablement, not user-global — kickoff
  skills don't leak into unrelated repos, and eject stays repo-scoped.
- The **memory hook moves into the plugin**, resolves its code via `${CLAUDE_PLUGIN_ROOT}`,
  and reads per-repo config (MEMORY_DIR, floors, MEMORY_DB) from **one canonical source**:
  `$CLAUDE_PROJECT_DIR/.kickoff/instance.env`. This kills the current double-source (inline
  hook args in `settings.local.json` AND instance.env).
- Because the plugin lives inside the pulled clone, **`kickoff pull` versions it** and the
  widened lock (§2.3) pins it — the plugin version becomes the core.lock analog for the
  CC-config layer. **Caveat — the plugin-cache layer (Fix 3, load-bearing).** This clean
  "runs from the pulled clone" story holds for the headless `--plugin-dir` path (it execs
  source directly), but **all 9 installed plugins on this box run from a user-global cache**
  (`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`), not source. If a local-path
  marketplace *also* snapshots into that cache, an interactive session keeps running the
  install-time copy after `kickoff pull` moves the clone — the stale-`mc-update.py` drift
  disease reborn one layer up, and **invisible to preflight #8 as designed** (it hashes the
  clone, not the cache). Additionally, marketplace registration + `installed_plugins.json` are
  **user-global touches** that the manifest does not yet record and eject does not yet remove —
  which would contradict §0's "provably reverses all of it." The extended §7 spike (b)
  resolves this *before* build; its outcome drives the plugin-cache handling below.
- **If the spike confirms a cache snapshot**, three mechanisms are required (specified now, so
  build inherits them): (1) `kickoff pull` gains a **mandatory plugin-update step** that
  re-syncs the cache to the newly-pinned tag; (2) **preflight #8 hashes the cache copy** (not
  only the clone) against the pinned tag; (3) the manifest gains **machine-level entries** for
  the marketplace registration + `installed_plugins.json` touch, and **eject removes them when
  the last sibling ejects** (same last-sibling rule as `~/kickoff-core` itself, §2.4 step 5 — gated on the `~/.kickoff/adopters.json` registry, §2.3 item 5).

**Spike-gated** (§7). Fallback if the interactive plugin flow fails on v2.1.199:
manifest-hashed copies into `.claude/skills/` + a new preflight check verifying them against
the pinned tag — a larger seam surface (~15 files), same manifest discipline, workable.

### 1.4 Shims (killing the copied-core class)

Core files get copied into repos because agents invoke them repo-relatively
(`python3 mission-control/mc-update.py`). Replace every such copy with a generated shim:

```
.kickoff/bin/mc      → sources ../instance.env; exec python3 "$KICKOFF_CORE_DIR/mission-control/mc-update.py" "$@"
```

Agents invoke `.kickoff/bin/mc …`. The pinned code runs; nothing drifts; the shim is a SEAM
file (generated, manifest-listed, regenerated on pull, trivially ejected). Committed files
stay stable and repo-relative; the machine path lives only in the gitignored `instance.env`,
which already owns that knowledge. Shims must fail with a clear message ("kickoff engine not
present — see .kickoff/README") when the clone is missing, not a bash error. Bliz migration:
sweep the stale copy, one greppable rewrite of charter references (§7).

---

## 2. The lifecycle flows

### 2.1 DISCOVER → ADOPT

**Discover.** One clone, and it *is* the core (kills today's two-clone confusion where you
clone kickoff and it clones itself again):

```
git clone <kickoff-remote> ~/kickoff-core
bash ~/kickoff-core/scripts/kickoff adopt --dir ~/my-repo
```

`adopt` **self-pins** as its first act: checkout the latest `core-v*` tag, write the
adopter's `.kickoff/core.lock`. No PATH install, honoring the constraint; the verbose
`bash ~/kickoff-core/scripts/kickoff <cmd>` invocation is the honest price, mitigated by the
AI driving everything post-adoption and any hands-on ask arriving as one runnable line (the
charter's turnkey rule). `docs/for-ai-adopters.md` stays the AI's on-ramp.

**Adopt = mechanical CLI step + intelligent skill step.**

*Phase 0 — the mesh plan (`--dry-run` first-class).* Before touching anything, inventory the
existing setup — their `CLAUDE.md`, `.claude/agents/*` (Bliz had 9 of its own),
`.claude/skills/*`, `settings.json` hooks, `.mcp.json`, `lefthook.yml` — and print the exact
plan: every path, classified **CREATE** (no collision) / **EXTEND** (append into an existing
structure: the CLAUDE.md block, the settings keys, an optional lefthook stanza) /
**CONFLICT** (name or hook collision → surfaced to the human, never silently resolved).
This is the brownfield analog of bootstrap's plan step, and it converts "additive" from
prose into something verifiable — and converts the one file edit (below) into consent.

*Mesh rules per fixed home:*

| Fixed home | Rule |
|---|---|
| root `CLAUDE.md` | **managed block, never a rewrite**: 3 marker-delimited lines `@import`ing `.kickoff/KICKOFF.md`. The lefthook/direnv/nvm pattern — a delimited region the tool owns inside a file the user owns. If no `CLAUDE.md` exists, draft one (whole file then manifest-tagged as created). This is the ONE edit to an adopter-owned file, and it is what makes the coordinator actually load interactively — today at Bliz it never does. |
| `.claude/settings.json` | structural merge via jq, never replace: append to the `UserPromptSubmit` array only if the plugin fallback is in play; add `enabledPlugins`. Exact JSON paths recorded. A semantically-colliding existing hook is a CONFLICT line, not an overwrite. |
| `.claude/agents/` | generic eng crew **stops landing here** (plugin). Only the domain crew authored for this repo lands, adopter-owned from day one, `seeded-instance` in the manifest. Light `eng-`/domain prefix for human scanning; **the manifest, not naming or the incidental tracked/untracked git signal, is the ownership record.** |
| `.claude/skills/` | **nothing lands here anymore** (plugin). Update adopt SKILL.md step 5, which currently promises a copy that never happened at Bliz. |
| `lefthook.yml` | detect-and-defer (Bliz proved the instinct: theirs kept, untouched). Gate-less repo → kickoff's file wholesale. Existing gates → **never append a second top-level `pre-commit:` key** — verified against Bliz's own lefthook binary + config: a duplicate top-level key throws `yaml: mapping key "pre-commit" already defined` and the **whole config stops loading**, so *every* existing gate dies (the exact opposite of additive). Instead either **structure-aware insert** kickoff's secret-scan command *under the existing `pre-commit.commands` mapping* (marker comments survive in nested YAML; eject strips the marked lines), or use lefthook's own **`extends:`** pointing at a kickoff-owned `.kickoff/lefthook-kickoff.yml` (zero edits to their mapping bodies). Either path is one marker-recorded, manifest-recorded change. |
| root `.gitignore` | never touched — `.kickoff/.gitignore` covers kickoff's runtime. |

> **Design note — `settings.local.json` carries live credentials.** At Bliz this gitignored
> file holds a Telegram bot token and a PostHog key (and the forked memory hook, Fix 1). Any
> kickoff edit to it — installing or removing the fallback `UserPromptSubmit` hook, reconciling
> the memory config — MUST be a **surgical `jq`-path operation on the single target key, never a
> whole-file rewrite**, and its contents MUST NEVER be logged, echoed into the mesh plan, or
> stored verbatim in the manifest's `original` slot. Record the JSON *paths* touched, not the
> secret-bearing values; if a byte-restore is genuinely needed, store only the sub-tree kickoff
> replaced, never the whole file.

*The manifest.* Everything adopt does is written to **`.kickoff/adopt-manifest.json`**
(schema versioned from day one):

```json
{ "path": "...",
  "action": "created | modified | block-appended | json-merged | hook-installed",
  "class": "seam | seeded-instance", "sha256_at_write": "...",
  "source": "core-v0.2 | authored-for-repo",
  "sha256_before_edit": "<hash of the file as it was BEFORE kickoff touched it>",
  "original": "<verbatim pre-edit bytes, stored for EVERY modified/block-appended/json-merged
              file so eject can byte-restore the file exactly as it was — never a re-derived
              reconstruction>" }
```

`modified` is the general in-place-edit action; `block-appended` / `json-merged` are its two
structured specializations, and **all three carry stored original bytes** — this is what lets
eject (§2.4) reverse them without re-formatting the file (Fix 2). The fifth action,
**`hook-installed`**, is deliberately distinct: the fallback `UserPromptSubmit` hook written
into the secret-bearing `settings.local.json` — by design it carries **no** stored `original`
bytes (the §2.1 credential design note forbids storing that file) and is reversed by a
**surgical `jq`-path removal of exactly the kickoff hook entry** at eject (§2.4 step 4), never a
byte-restore; `created` files reverse by deletion (§2.4 step 2). One file that is
simultaneously the eject spine, the upgrade-safety record, and the audit answer to "what did
kickoff do to my repo?".

*Finish.* The adoption report is the manifest rendered ("added 12 files, appended one marked
block to your CLAUDE.md, merged 1 settings key, touched zero source files — here's
`git status`"), plus **one atomic adoption commit offered on a branch** (operator fork #4):
the whole footprint in a single revertable sha, giving eject a git-level fallback.

### 2.2 RUN

Mostly exists today (setup/up, the 7 fail-closed preflight checks, REPO_DIR sibling
resolution). Additions:

- **`kickoff status`** — one screen: pinned tag vs latest, supervisor alive, preflight
  summary, board URL, **manifest integrity** (every seam file hash-checked). The "is my
  install healthy" answer that currently requires knowing four files.
- **Preflight #8** — verify manifest-listed seams/shims match the pinned tag. This extends
  the core.lock guarantee to the half of the engine that touches the repo — exactly where it
  is broken today (the stale `mc-update.py` is invisible to #6). **Fail-closed absence semantics
  (Fix 9):** unlike preflight #6's "absent → skip", once `.kickoff/` exists a *missing*
  `adopt-manifest.json` is a **preflight FAIL** (recovery: `adopt --reconcile`) — otherwise
  deleting the manifest would silently disable seam verification *and* remove eject's spine, a
  fail-open hole. **Caveat — the manifest is an integrity record, NOT anti-tamper:** it is
  unsigned, so #8 catches accidental drift, not a malicious edit that rewrites both the file and
  its recorded hash. That is the right scope for a solo-builder trust model; naming it keeps the
  guarantee honest. (If the plugin snapshots to a user-global cache, #8 also hashes that cache —
  §1.3 / Fix 3.)
- **supervisor.log rotation** — 78.5 MB live in kickoff-itself; once `.kickoff/` is pitched
  as *the* contained folder, an unbounded log inside it is the first thing an adopter judges.

### 2.3 UPGRADE — `kickoff pull core-vNEXT`, instance untouched by construction

Keeps its contract (tag-only, changelog-first, a deliberate human act) and gains:

1. **Changelog delta printed automatically** between the previously-pinned and new tag.
2. **Seam sync**: regenerate manifest-listed seam files/shims from the new tag's templates —
   *only* where the recorded hash shows the file unmodified since generation. A hand-edited
   seam → **refuse and show the diff** (the same fail-closed posture pull already takes on a
   dirty clone), with a `--force-regenerate` escape hatch. Instance-class files are never in
   the regeneration set — the manifest's `class` field is the guarantee, not a convention.
   **Why the charter is split (Fix 5):** classify `KICKOFF.md` as SEAM and it would be
   permanently "modified" the moment a repo tailors it → seam-sync refuses on *every* pull and
   the charter-upgrade path dies; classify it as INSTANCE and engine charter improvements never
   reach adopters. The split resolves both: the SEAM `KICKOFF.md` stays byte-identical to its
   template (all repo-specific charter text lives in the adopter-owned `KICKOFF.local.md` it
   `@import`s), so seam-sync regenerates it cleanly every pull — improvements flow, and the
   repo's tailoring in `KICKOFF.local.md` (INSTANCE, never in the regeneration set) is never
   touched.
3. **Auto-run preflight after pull**, so a bad upgrade fails at the terminal, not at 2am
   under the supervisor.
4. **Widen the pin**: replace the 25-file hash list with whole-tree integrity —
   `core.lock = tag + commit sha + clean-tree check`. The clone is already an atomic tag
   checkout; per-file hashing was only ever diagnostic, and today it leaves ~181 files
   (the MC server, dashboards, all skills, the new plugin/) running unpinned. Simpler lock,
   total coverage, and it pins the plugin for free. **The clean-tree check must scope to the
   pinned version checkout (or a bare-clone HEAD), NOT a parent clone that could contain sibling
   worktrees** — see item 5, which this item would otherwise collide with. Migration: preflight
   #6 accepts both formats for one version.
5. **Version-addressed checkouts before adopter #2** (currently latent, guaranteed breakage
   at two siblings on different tags: `preflight.sh:341` checksums the single shared checkout,
   so sibling B pulling `core-v0.2` breaks sibling A's pin). Fix: git worktrees — but (Fix 7)
   **parked OUTSIDE the clone at `~/kickoff-versions/<tag>/`, never `~/kickoff-core/versions/…`**.
   A worktree *inside* the clone makes the parent's `git status --porcelain` show `?? versions/`,
   so the new whole-tree clean-check (item 4) would **fail for any adopter still pointing
   `KICKOFF_CORE_DIR` at the root clone (Bliz today) the moment adopter #2 creates the first
   worktree** — the widened lock would manufacture the very incident this item exists to prevent.
   (Equivalent alternatives: make `~/kickoff-core` a bare repo, or explicitly exempt a
   `versions/` path from the clean-check; parking outside the clone is the simplest.) Each
   adopter's `instance.env` points `KICKOFF_CORE_DIR` at its pinned version dir; pull adds a
   worktree and moves that adopter's pointer. **Pruning requires a machine-level adopters
   registry** (Fix 7): "prune worktrees no sibling references" is *undecidable* today because
   nothing enumerates the adopters — so land a `~/.kickoff/adopters.json` registry (each
   adopt/eject updates it) BEFORE any prune logic, and until it exists, never auto-prune. Cheap
   now, expensive as an incident later.

The stability contract (`CONTRIBUTING.md` §5) grows from two artifacts to three:
instance.env variable names + the core file set + **the seam-template set** (versioned inside
each tag, exactly as the tag defines its core set).

### 2.4 EJECT — the missing counterpart, one command, verifiable

**Does not exist today in any form** — the sharpest gap against the operator's steer.

`kickoff eject --dir ~/my-repo`, driven entirely by the manifest, in order:

1. **`--archive` first** (default on): tar mission-state.json, TRACKER render, memory index
   + the facts dir *chased from `MEMORY_DIR` in instance.env* (at Bliz the facts live out of
   repo under `~/.claude/projects/…` — eject must follow the config, not assume `memory/`)
   → `~/kickoff-eject-<repo>-<date>.tgz`. Adopter data goes to the archive, never the void.
2. For each `created` file: hash matches the record → delete; hash differs (they edited it)
   → prompt keep/delete, never silent-delete.
3. For every `modified` / `block-appended` / `json-merged` file: **byte-restore the stored
   `original` as the PRIMARY reversal** (Fix 2) — gated on the file's current hash matching
   `sha256_at_write` (untouched since adopt) → write the stored original bytes back exactly, so
   `git status` sees no change *at all*. This is what makes the acceptance test pass on a
   non-jq-canonical `settings.json`: a jq add-then-delete round-trip re-indents the whole file
   (4-space → jq's 2-space), so *every* untouched line would differ and porcelain would never be
   empty. Only when the file was edited by them after adopt (current hash ≠ `sha256_at_write`)
   fall back to **surgical, interleaved-edit reversal** — strip the marked block byte-exactly,
   jq-remove exactly the recorded JSON paths — and **report honestly that "formatting may differ
   from the pre-adopt file."** Never silent-rewrite. (For `settings.local.json` the surgical
   jq-path fallback is *mandatory*, per the §2.1 credential design note — never a byte-restore
   of the whole secret-bearing file.)
4. Unwire machinery: `lefthook uninstall` iff adopt installed it (or remove only the
   marker-commented stanza if adopt merged into theirs); remove `enabledPlugins`; delete
   gitignored runtime — the surgical `jq`-path removal of the `settings.local.json` kickoff hook keys (reversing the `hook-installed` action), plus the index and tokens.
5. Machine level: stop the supervisor; deregister the repo's ingress entries
   (`ingress.sh remove <project>`, §4); offer removal of the Telegram channel dir; **leave
   `~/kickoff-core`** (shared by siblings) unless `--deep` and it is the last sibling — and **last-sibling determination requires the `~/.kickoff/adopters.json` registry (§2.3 item 5); until that registry lands, `--deep` never auto-removes `~/kickoff-core`.**
6. Two prompts only: *(a)* "the domain crew adopt authored for you — keep (default) or
   remove (`--purge`)?" *(b)* "your data — archived (§step 1); also **leave the live copy in
   place**, or **delete** it?" (default leave). **"Leave" is defined mechanically** (Fix 6):
   the live data (`mission-state.json`, TRACKER render, `memory-index.db`) lives in
   `.kickoff/state/`, which step 7 deletes — so "leave" is **not a no-op; it relocates `state/`
   out to `<repo>/kickoff-data/` (or a `--data-dir`) before the folder is removed.** **Delete**
   sits inside the TRULY-DESTRUCTIVE gate, and any `--no-archive` eject that also deletes
   requires the **explicit destructive yes** — with the archive off, that copy is the only one,
   so the sequence must never proceed on a bare prompt.
7. Delete `.kickoff/` **last** — only *after* `state/` has been archived and either relocated
   (the "leave" default) or explicitly approved for deletion per step 6(b) — then `--verify`:
   grep the repo for every kickoff-known path/marker, print "no trace" or the residue list, and
   end with `git status` as the proof. `--verify` **allowlists the relocated `kickoff-data/`**
   when the operator chose "leave" — that directory is their retained data, not residue, so
   "no trace" and "leave" no longer contradict.

**The acceptance test that defines done** (and gates the core tag shipping this):
`adopt → eject` on a fixture repo *with a pre-existing `.claude/` and CLAUDE.md* — and (Fix 2)
the fixture's `settings.json` **MUST be non-jq-canonical (e.g. 4-space indent)** and its
`lefthook.yml` **MUST already carry a top-level `pre-commit:` key** (Fix 4), so the test
actually exercises the byte-restore and structure-aware-insert paths rather than the easy cases.
The assertion: `git status --porcelain` empty afterward. **The git baseline is defined
explicitly** (Fix 2): the acceptance run executes with fork #4's atomic adoption commit
*disabled* (adopt leaves its footprint uncommitted), so the baseline is the fixture's pre-adopt
commit and "empty porcelain" means the working tree byte-matches it. With the atomic adoption
commit *enabled*, the equivalent proof is a clean `git revert` of that single sha, asserted as a
separate case. That test is the executable meaning of "leave their repo as it was." Honest
limit: eject cannot rewrite history — commits made *with* kickoff stay; "as it was" means
"working tree pristine going forward," and the eject report says so.

**Bliz migration**: it predates the manifest. Ship `kickoff adopt --reconcile` — infer a
manifest from the known adopt file-set (the tracked/untracked git signal is incidentally
accurate today), sweep the stale `mc-update.py`, rewrite charter invocations to
`.kickoff/bin/mc`, and (Fix 1) **untangle the memory split-brain**: retire the third forked
`~/bliz-memory/hook.mjs` copy, re-point retrieval at the plugin hook, **surgically
remove the `UserPromptSubmit` entry from the gitignored `settings.local.json`** (a jq-path op
per the §2.1 credential design note — otherwise, once the plugin hook lands, memory injects
twice), and reconcile the two divergent databases (`~/bliz-memory/memory-index.db`,
which the hook silently defaults to, vs the `instance.env` repo path) down to the single
`MEMORY_DB` that `instance.env` declares. One-time cost to bring the single real adopter onto
the invariant.

---

## 3. The engine/instance boundary — the resolved rule

**Verdict: keep the engine OUTSIDE the repo (pull), do not vendor.** The live evidence
decides it: the one core file also physically copied into Bliz is the one that drifted stale,
invisibly. Vendoring the engine into a per-repo folder multiplies that hole by 25+ files × N
adopters — it re-opens the copy-fragmentation R1 was built to kill. The "machine-level
dependency" con is real but cheap: kickoff is already irreducibly box-anchored (supervisor,
Telegram state, embedder cache, caddy/tailscale); a bare `git clone` of the adopter repo was
never going to run kickoff regardless. Mitigations: `KICKOFF_CORE_REMOTE` in instance.env
re-materialises a missing clone in one `kickoff pull`; preflight fails closed if it's absent;
shims fail with a clear message.

**Changes to `CONTRIBUTING.md` §2** (the table is right but incomplete):

1. Add the **SEAM row** (§1.1) — engine-shaped, **required in-repo** (whether CC discovery
   forces it, like the CLAUDE.md block, or the mechanism does, like the `.kickoff/bin/` shims),
   transported by generate-from-pinned-template + manifest + regenerate-on-pull.
2. **`mc-update.py` row correction**: "travels via pull" stays true, but the *invocation*
   contract changes — it is never copied into a repo; repos reach it via `.kickoff/bin/mc`.
3. **Skills/generic agents**: currently absent from the table entirely (and from
   `core-manifest.txt`); they become ENGINE, delivered via the plugin, pinned by the
   whole-tree lock.
4. **The domain crew** row gains its precise name: `seeded-instance` — authored by adopt,
   adopter-owned from day one (a consultant's deliverable), which is why eject keeps it by
   default.
5. §5's stability contract: two artifacts → three (add the seam-template set).

---

## 4. Local serving — the caddy + Tailscale story

Two tiers, chosen by the app's shape, folded into ONE upgraded `preview` skill:

**Tier 1 — exists today, keep as-is.** Single service, "show me this screen":
`tailscale serve --bg <port>` (tailnet-private, autonomous; `funnel` public, human-gated).
The box runs ~8 of these live. Right fast path; don't touch it.

**Tier 2 — promote `~/box-ingress` into the engine.** The moment an app is ≥2 services that
must share an origin, single-port serving structurally fails: the frontend's relative `/api`
calls, cookies, and CORS all break across different host:ports, and Funnel's hard 3-port
ceiling (443/8443/10000) caps public apps at three per box. The pattern is already proven
live: one Funnel :443 → one Caddy :9000 → `/<project>/<app>` path-routing for 6 apps across
two projects, with SPA fallback, per-asset-class cache-control, `basic_auth` gating, and hot
reload. Two honest caveats the promotion must close (Fix 8): the `RESERVED_PRIVATE_PORTS`
guard lives **only in `add_app()`**, not in `gen()`/`up`, so it does *not* actually keep
Mission Control off the public surface if the hand-editable registry is edited directly; and
caddy currently wildcard-binds `*:9000` (verified via `ss`), so it is LAN-reachable, not
private, until that bind moves to loopback.

What kickoff adds (the machinery exists; this is packaging, not building):

- Move `ingress.sh` + the registry pattern into the pinned core as a **machine-level
  singleton** (like `~/kickoff-core` — one caddy per box serving all adopters; registry.json
  is already multi-project).
- `ingress.sh add|remove <project> <app> <type> <target>` so registration is a command, not
  a hand-edit.
- **Add an `auth` field to the registry schema and generate `basic_auth` from it** (Fix 8a).
  The live investor pitch-deck route is currently a **hand-edited `basic_auth` block** (bcrypt
  users for named external people) that a blind regenerate destroys — so the preview skill's own
  `gen && up` would take that shared, externally-shared URL **offline on the first run**. Making
  auth a first-class registry field means `gen` reproduces it instead of erasing it; hand-edited
  auth blocks are migrated into the registry as part of the promotion.
- **Move `RESERVED_PRIVATE_PORTS` validation from `add_app()` into `gen()`** (Fix 8b) — today
  the guard runs only on the `add` path, but `gen`/`up` regenerate from the hand-editable
  `registry.json` with no check, so a single manual registry edit + `up` can **publish Mission
  Control to the internet**. Validating at generation makes the guard actually load-bearing.
- The preview skill's Tier-2 motion: detect services → set each app's base path (Next
  `basePath` / Expo `baseUrl` — the one thing the ingress cannot do *for* the app; detect
  hardcoded `/` and say so rather than serve broken deep links) → `ingress.sh add` each →
  `gen && up` (validate + zero-downtime reload) → **health-check every upstream (Fix 8c) and
  refuse to send the URL if any is down** → send ONE URL. (Verified need: `/bliz/dashboard`
  502s today — a blind "here's your link" would hand the operator a dead route.)
- **Trust boundary preserved and improved**: default the caddy listener behind
  `tailscale serve` (tailnet-private) so a same-origin multi-service preview stays inside
  the autonomous boundary; the `funnel` flip to public remains the human-gated step. **This is
  only actually private once caddy binds `127.0.0.1:9000` instead of `*:9000`** (Fix 8c — a
  prerequisite below), otherwise the app is LAN-reachable regardless of Funnel. (Today
  box-ingress is funnel-only; the tailnet-private mode is designed, not yet proven — spike.)
- **Ejectability by construction**: ingress state is machine-level (registry.json), zero repo
  footprint; eject runs `ingress.sh remove <project>`.

Prerequisites before this is engine-grade: **bind caddy to `127.0.0.1:9000` instead of the
current wildcard `*:9000`** (Fix 8c — so "tailnet-private" is genuinely private, not just
LAN-reachable); caddy reboot persistence (userland `caddy start` today; the README's TODO
user-systemd `install.sh`); the `auth`-field + `gen()`-side port-guard changes above landed
into `ingress.sh` before promotion; and a spike on whether `tailscale serve --set-path` covers
simple 2-service cases without caddy at all (caddy still owns strip_prefix, SPA fallback,
cache-control, basic_auth).

---

## 5. Rough edges → fixes (the honest friction map)

| Stage | Edge | Fix |
|---|---|---|
| DISCOVER | two-clone confusion | first clone IS the core; adopt self-pins |
| DISCOVER | no PATH ⇒ verbose commands | no fix that honors the constraint; mitigation = AI drives post-adoption + turnkey one-liners. Named, not smuggled around |
| ADOPT | `@import` from root CLAUDE.md, **load-bearing** | **VERIFIED PASS on 2.1.199** (spike ran: token round-trip through the exact marker block; live specimen `~/.claude/CLAUDE.md = '@RTK.md'` resolves every session) — fork #1 reduces to a taste call. Fallback (unused): marked block carries an imperative pointer line, same eject semantics |
| ADOPT | interactive plugin flow (local marketplace + `enabledPlugins`; hook + MCP via `${CLAUDE_PLUGIN_ROOT}`) | hook + skills **VERIFIED** carried by a `--plugin-dir` plugin; the remaining unknown is the **plugin-CACHE layer** (Fix 3), not the flow — extended spike (b) resolves cache-vs-source; fallback = manifest-hashed skill copies + preflight #8 |
| ADOPT | plugin may run from a user-global CACHE, not the pulled clone (Fix 3) — drift reborn one layer up, invisible to preflight #8 as first drafted | extended §7 spike (b) decides; if cache → pull plugin-update step + cache-hashing #8 + machine-level manifest/eject entries |
| ADOPT | editing their CLAUDE.md breaks today's "additive only" letter | mesh plan surfaces it for consent; 3 lines, marker-delimited, byte-reversible; the alternative (charter silently never loads — Bliz's live state) is a correctness failure dressed as politeness |
| ADOPT | settings.json JSON merge — no comment markers possible | manifest records exact JSON paths; tolerant differ at eject; jq round-trip churns their key order in the diff — named in the dry-run plan |
| RUN | 78.5 MB supervisor.log inside "the contained folder" | rotation lands with this change, not after |
| RUN | hook config double-source (inline `settings.local.json` args AND instance.env) | one canonical source: instance.env; plugin hook sources it — get this wrong and retrieval silently degrades to default floors |
| UPGRADE | hand-edited seam turns one-command pull into a manual reconcile | correct (fail-closed) but real friction; `--force-regenerate` escape hatch |
| UPGRADE | shared-clone version collision at adopter #2 | worktree versioning **parked outside the clone** (`~/kickoff-versions/<tag>/`) + a machine-level adopters registry before any prune (Fix 7); land before it's an incident |
| UPGRADE | lock-format migration (25 hashes → tag+sha+clean) | preflight #6 accepts both for one version |
| EJECT | pre-existing lefthook config adopt merged into | manifest records merged stanzas, not just whole files |
| EJECT | memory facts out of repo | archive chases `MEMORY_DIR` from instance.env |
| EJECT | git history keeps kickoff-era commits | stated plainly in the eject report; the atomic adoption commit + revert is the closest approximation |
| SERVING | caddy no reboot persistence; tailnet-private ingress unproven; per-app base-path needs app cooperation | install.sh (user systemd unit); serve-mode spike; preview skill detects and reports base-path blockers |
| SERVING | `gen && up` destroys the hand-edited pitch-deck `basic_auth` (URL offline on first run); reserved-port guard skips `gen()`; caddy binds `*:9000` (LAN-exposed) (Fix 8) | registry `auth` field generates `basic_auth`; move the port guard into `gen()`; bind `127.0.0.1:9000`; preview health-checks each upstream before sending the URL |
| ADOPT | appending a 2nd top-level `pre-commit:` to their `lefthook.yml` bricks the whole gate suite (Fix 4) | structure-aware insert under `pre-commit.commands`, or lefthook `extends:` a kickoff-owned file |
| EJECT | jq round-trip re-indents an adopter's non-canonical `settings.json` → `git status` never clean (Fix 2) | byte-restore stored original as the primary reversal (hash-gated); jq-path strip only as interleaved-edit fallback, reported honestly |
| EJECT | `state/` lives inside the `.kickoff/` that eject deletes, contradicting the "leave your data" default (Fix 6) | "leave" relocates `state/` to `kickoff-data/` before delete; `--verify` allowlists it; `--no-archive` delete needs the explicit destructive yes |
| SCOPE | everything grounded on ONE adopter, ONE tag | manifest schema versioned day one; mechanisms ship small and individually testable on the Bliz + fixture pair, not framework-sized for a fleet that doesn't exist |

---

## 6. Open forks for the operator

The decisions that are taste/tradeoff/scope calls — each with a recommendation to react to:

1. **The managed block.** Accept a 3-line, marker-delimited, manifest-recorded,
   consent-surfaced `@import` block appended to the adopter's existing `CLAUDE.md` — the one
   breach of "touch zero adopter files" — in exchange for the coordinator charter actually
   auto-loading in interactive sessions? **Recommend: yes.** **The mechanism is no longer a
   gamble: spike (a) has RUN and `@import` loads `.kickoff/KICKOFF.md` on 2.1.199 (Fix 9), so
   this fork is now a pure taste/consent call, not a mechanism risk.** The alternative is Bliz's
   live state: a charter that silently never loads. If no: the charter stays headless-only
   (injected via `--append-system-prompt`) and interactive sessions run uncoordinated. (Note the
   charter split, Fix 5: the block `@import`s the SEAM `KICKOFF.md`, which in turn `@import`s the
   adopter-owned `KICKOFF.local.md`.)

2. **Skills/agents transport.** Plugin (`~/kickoff-core/plugin/`, `--plugin-dir` headless +
   one `enabledPlugins` line interactive) vs manifest-hashed copies into `.claude/skills/`.
   **Recommend: plugin**, spike-gated — cleaner eject, version-pinned by the widened lock,
   idiomatic on this box; copies are the working fallback if the spike fails.

3. **Domain-crew ownership at eject.** The agents adopt authors for the repo (pos-app,
   api-money…): keep by default with `--purge` to remove, or remove by default for a truly
   pristine tree? **Recommend: keep** — they are a deliverable authored for the repo, like a
   consultant's work product. This is the definitional taste call on what "de-integrate" means.

4. **Adoption commit posture.** One atomic adoption commit on a branch (revertable sha,
   kickoff visible in their history, exposes kickoff files to their CI/lint) vs leave
   everything uncommitted (Bliz's current incidental state). **Recommend: the atomic commit
   on a branch** — the boundary becomes explicit and git-revertable; the dry-run plan warns
   about CI/lint exposure. Related sub-call: commit the seams (team-shareable, visible in
   PRs) vs gitignore them (every clone re-runs adopt). **Recommend: commit the seams.**

5. **Ingress promotion.** Fold box-ingress (caddy + registry + ingress.sh + a persistence
   install.sh) into the pinned core as a machine-level capability, or leave it a documented
   box-local pattern the preview skill points at? **Recommend: fold it in** — otherwise the
   "complex app on my phone" story, which the operator explicitly flagged, stays tribal
   knowledge that dies with this box. Cost: the engine owns one more machine-level service.
   Sub-call: tailnet-private ingress registration stays autonomous, only the funnel flip
   human-gated? **Recommend: yes** (matches today's serve/funnel boundary).

6. **TRACKER.md placement.** Contained at `.kickoff/state/TRACKER.md` with an optional root
   symlink (proven pattern — Bliz ships `AGENTS.md → CLAUDE.md`), or keep the root file for
   human discoverability at the cost of one more manifest entry? **Recommend: contain +
   symlink.** Lowest stakes fork; purely taste.

---

## 7. Sequencing (what to build, in what order)

1. **The spikes, before anything is committed to** — (a) `@import` from root CLAUDE.md:
   **already RUN, PASS on 2.1.199** (Fix 9) — retained here as the gate's record, not pending
   work; (b) local-path plugin: marketplace/`enabledPlugins` interactive enablement + whether a
   plugin can carry the UserPromptSubmit hook and the chrome-devtools MCP declaration with
   `${CLAUDE_PLUGIN_ROOT}` resolution (hook + skills already VERIFIED) — **extend this spike
   (Fix 3) to determine whether a local-path marketplace snapshots into the user-global plugin
   CACHE (`~/.claude/plugins/cache/…`) or runs from the pulled clone**, since the answer drives
   the pull plugin-update step, preflight #8's hash target, and the machine-level manifest/eject
   entries (§1.3). Run this extended spike (b) BEFORE step 5. Each path has a named fallback
   (§5); the design states verified mechanisms, not "documented, unverified."
2. **The manifest + shims + seam class** in adopt (and `adopt --reconcile` for Bliz — sweep the
   stale `mc-update.py` **and untangle the `~/bliz-memory` memory split-brain: retire the third
   forked hook copy, re-point to the plugin hook, surgically drop the `settings.local.json`
   `UserPromptSubmit` entry, reconcile the two DBs; Fix 1**) + preflight #8 (**fail-closed on a
   missing manifest, Fix 9**) + supervisor.log rotation.
3. **Eject** + the adopt→eject fixture acceptance test gating the tag — **byte-restore-primary
   reversal with a defined git baseline (Fix 2) and the mechanically-defined "leave" for
   `state/` (Fix 6). The fixture MUST carry a non-jq-canonical `settings.json` AND a pre-existing
   top-level `pre-commit:` key in its `lefthook.yml`** (Fixes 2 + 4).
4. **Pull upgrades**: changelog delta, seam sync (**incl. the split-charter regeneration,
   Fix 5**), auto-preflight, whole-tree lock (dual-format #6 for one version), and worktree
   versioning **parked OUTSIDE the clone at `~/kickoff-versions/<tag>/`, with a machine-level
   adopters registry landed before any prune logic** (Fix 7).
5. **The plugin** (or the copy fallback) — **run the extended cache-layer spike (b) first
   (Fix 3)**; if it snapshots to cache, land the pull plugin-update step + cache-hashing
   preflight #8 + machine-level manifest/eject entries — + retiring adopt SKILL.md step 5's
   dead promise.
6. **Serving**: preview skill Tier-2 + ingress promotion (**registry `auth` field,
   `gen()`-side reserved-port guard, `127.0.0.1:9000` caddy bind, per-upstream health-check
   before the URL; Fix 8**) + caddy install.sh + the serve-mode and `--set-path` spikes.

Each step is a small mechanism testable on the fixture + the one real adopter — deliberately
not a framework sized for a fleet that does not exist.

---

## Revision log — 2026-07-06 Fable-5 refine

Applied the 9 must-fix findings from `brownfield-devex-fable-review-2026-07-06.md` (verdict:
REFINE). Each entry: fix → section(s) changed → what changed.

- **Fix 1 (HIGH)** → §1.1, §2.1 (design note), §2.4 (`--reconcile`), §7 step 2, header.
  Corrected the false Bliz memory-hook inventory: the hook is not in tracked `settings.json` but
  in gitignored `settings.local.json` (`UserPromptSubmit` exec'ing a *third* forked
  `~/bliz-memory/hook.mjs`), a live split-brain across two DBs; the earlier draft
  mis-attributed kickoff-itself's `settings.json:8`. Added the `settings.local.json`
  live-credentials design note (surgical jq-path edits only, never rewrite/log). Widened
  `--reconcile` + §7-step-2 to retire/re-point `~/bliz-memory`, drop the `UserPromptSubmit`
  entry, and reconcile the DBs.
- **Fix 2 (HIGH)** → §2.1 (manifest schema), §2.4 (eject step 3 + acceptance test), §7 step 3,
  §5. Added `modified` to the manifest action enum and made **stored-original-bytes the primary
  eject reversal** (hash-gated), with jq-path strip as the interleaved-edit fallback that
  honestly reports formatting may differ. Defined the acceptance test's git baseline (fork-#4
  commit disabled) and required a non-jq-canonical fixture `settings.json`.
- **Fix 3 (HIGH)** → §1.3, §7 step 1 & 5, §5, header. Acknowledged the plugin-cache layer: the
  interactive plugin may run from a user-global cache, not the pulled clone. Extended §7 spike
  (b) as a build-time step to determine cache-vs-source; specified the pull plugin-update step,
  cache-hashing preflight #8, and machine-level manifest/eject entries if it snapshots.
- **Fix 4 (MEDIUM)** → §2.1 (lefthook rule), §7 step 3, §5. Replaced the repo-bricking "append a
  second top-level `pre-commit:`" rule with structure-aware insertion under `pre-commit.commands`
  or lefthook `extends:`. Fixture must carry a pre-existing `pre-commit:` key.
- **Fix 5 (MEDIUM)** → §1.1 (SEAM definition), §1.2, §2.3 (item 2), §3, §6 fork #1. Redefined
  SEAM as "engine-shaped file required inside the repo" (dropping "forced by CC discovery"), and
  split the charter into a SEAM `KICKOFF.md` (regenerates on pull) that `@import`s an
  adopter-owned `KICKOFF.local.md` (never regenerated) — keeping the charter-upgrade path alive.
- **Fix 6 (MEDIUM)** → §2.4 (eject steps 6b & 7). Defined "leave your data" mechanically:
  relocate `state/` out to `kickoff-data/` before deleting `.kickoff/`, `--verify` allowlists it,
  and `--no-archive` delete requires the explicit destructive yes.
- **Fix 7 (MEDIUM)** → §2.3 (items 4 & 5), §7 step 4, §5. Resolved the whole-tree-lock ×
  worktree collision: park version checkouts OUTSIDE the clone (`~/kickoff-versions/<tag>/`),
  scope the clean-check to the version dir, and require a machine-level `adopters.json` registry
  before any prune logic.
- **Fix 8 (MEDIUM)** → §4 (ingress), §7 step 6, §5. Added a registry `auth` field so `gen`
  reproduces the hand-edited pitch-deck `basic_auth` instead of destroying it; moved
  `RESERVED_PRIVATE_PORTS` validation into `gen()`; added the `127.0.0.1:9000` bind prerequisite;
  required per-upstream health-checks before the preview URL is sent.
- **Fix 9 (LOW)** → §2.2 (preflight #8), §5, §6 fork #1, §7 step 1, §1.3, header. Made a missing
  manifest a preflight FAIL once `.kickoff/` exists (fail-closed) with a NOT-anti-tamper caveat;
  stamped the env claim as v2.1.199 (2026-07-06); corrected "six plugins" → nine (three
  project-scoped, cited as per-repo-scoping proof); recorded that spike (a) `@import` PASSED so
  fork #1 is now a pure taste call.

**Post-refine adversarial coherence pass (2026-07-06)** — 3 diverse-lens reviewers (fidelity ·
coherence · grounding, all read-only) checked the refine; fidelity + grounding came back clean,
coherence caught 3 internal-consistency slips, all closed:
- **Fix 1 half-propagation** → §1.3, §5: still said the memory hook's inline args live in
  `settings.json` — corrected to `settings.local.json`, matching the §1.1 correction.
- **Fix 2 enum orphan** → §2.1, §2.4 step 4: the new `hook-installed` manifest action had no
  enumerated reversal — §2.1 now states it is reversed by surgical `jq`-path removal at eject
  step 4 (never a byte-restore, per the credential note), and step 4 names it.
- **Fix 7 cross-ref** → §1.3, §2.4 step 5: the eject "last sibling" logic now references the
  `~/.kickoff/adopters.json` registry prerequisite (§2.3 item 5) it depends on.

**Post-build hardening (2026-07-06)** — §7 step 2 (foundation) + step 3 (eject) were BUILT, then run
through two adversarial-review rounds (build → review → fix → re-review). 15 findings on the first pass +
2 on the re-review, all confirmed and closed; the fixtures were tightened to use the REAL adopter forms
after the review showed convenient stand-ins were masking bugs. Where the implementation diverged from
this design (the design is the record; the code is the built truth — these are the reconciling deltas):
- **Hook identity is a CONTENT HASH, not a substring or bare positional index** → §2.1, §2.4 step 4. The
  design's "surgical `jq`-path removal of the recorded entry" was positional; a substring identity check
  shipped and FAILED on the real hook commands (Bliz `~/bliz-memory/hook.mjs`, prod `memory-retrieval/hook.mjs`
  contain no "kickoff"). The manifest `hook-installed` entry now also stores `hook_sha256s` (sha256 of the
  `jq -S -c` canonical hook object — credential-safe, a hash is not bytes); reverse matches by hash wherever
  the hook moved (reorder-safe, content-agnostic) and never clobbers an operator's own hook.
- **`json-merged` edited-after-adopt → honest-limit, not surgical un-merge** → §2.4 step 3 (Fix 2/D3). The
  schema records NO `jq_paths` for `json-merged` (byte-restore-primary is the reversal); when the file was
  edited after adopt, eject leaves it + points at the archived pre-adopt original, rather than the
  originally-stated jq-path removal (which the schema deliberately does not carry).
- **Atomic tmp writes are `mkstemp` (symlink-safe)** → the re-review found the realpath containment (Fix B)
  guarded the logical target but the write went through a PREDICTABLE sibling tmp (`<file>.kickoff-eject.tmp`);
  a planted symlink at that name exfiltrated the neighbouring secrets out-of-repo. All tmp writes now use a
  random `mkstemp` name (O_EXCL → a planted symlink is never opened).
- **Tracked follow-ups (LOW, non-blocking):** number-representation drift in the hook hash (a jq-version change
  could orphan a hook as residue while eject reports clean) — eject `--verify` should not claim unqualified
  "clean" when a hook-installed entry was "kept"; and gen-shim's adopt-time `open(abs_path,'w')` should gain
  the same realpath containment for defense-in-depth.

**Post-build hardening — §7 step 4 pull-upgrades (2026-07-06)** — step 4 (changelog delta · split-charter
regen Fix 5 · whole-tree dual-format lock Fix 6 · adopters-registry + parked worktrees Fix 7) was built on the
existing `cmd_pull`/`sync-seams`/preflight #6 spine, then run through an engine-critical adversarial review (a
broken pull can brick an adopter's engine). 6 confirmed findings + 1 HIGH a verify-agent tool-error had dropped
from the synthesis (recovered from the journal), all closed at root with regression tests proven RED on the
unfixed code:
- **[HIGH]** `cmd_sync_seams`'s refusal diff (`_print_seam_diff`) followed a symlinked seam and printed the
  target file's contents into the pull output (arbitrary out-of-repo read / secret leak) → a hard REFUSE of any
  seam that is a symlink or resolves outside the repo, BEFORE any read/hash/diff.
- **[MEDIUM]** the whole-tree `core.lock` was the ONE atomic write still using a predictable `$lock.tmp.$$` (a
  planted symlink redirected it out-of-repo — the same class the eject re-review closed) → random `mktemp`
  (O_EXCL). The gen-shim containment follow-up above was ALSO closed here (`_write_seam` routes gen-shim +
  gen-charter + sync-seams through `_real_within` + the secure tmp).
- **[MEDIUM]** a worktree pull (sibling on a different tag) rewrote `core.lock` + parked the worktree but did
  not persist which core the next launch resolves → the sibling bricked on its next start (preflight #6
  fail-closed) while the pull reported "PULL OK" → surgically persist `KICKOFF_CORE_DIR` into the adopter's
  `instance.env` on a worktree pull.
- **[LOW×2]** adopters-registry lost-update under concurrent writes → `flock` on a sidecar lock; and a
  corrupt/unreadable registry was swallowed to "no siblings" (moving the shared clone) → fail-closed on a
  non-zero siblings query. Green after: pull-selftest 80/0, adopt 74/0, eject 108/0, machinery 25/0, scan clean;
  the live-engine preflight is unaffected (step-4 preflight changes are inert without a `core.lock`).

**Post-build §5-review hardening (2026-07-07)** — §7 step 5 (THE PLUGIN) was BUILT, then run through a
3-lens adversarial review (credential-containment · cache-integrity-upgrade · reversal-residue-dogfood).
7 findings, all CONFIRMED + verified against the real code and real claude 2.1.202 under isolated
`CLAUDE_CONFIG_DIR`; all closed at root. The 114 green plugin-selftest assertions had masked every one —
the STUB `claude` ignored `--scope`, so the fixtures could not see the bugs. Reconciling deltas:
- **[HIGH] eject's last-adopter gate must count ANY-tag adopters, not different-tag** → §1.3, §2.4 step 5.
  It reused `adopters-siblings` (different-tag only — built for pull's worktree decision), so a SAME-tag
  sibling (the default: both track the latest tag) shares the IDENTICAL user-global cache dir yet was
  invisible → eject swept the shared plugin out from under a live sibling. New `adopters-others` query
  (any tag) drives the removal decision; and adopt now REGISTERS the adopter (not only pull did), so an
  adopted-but-not-yet-pulled sibling is visible.
- **[HIGH] pull/eject cache ops must thread `--scope`** → §1.3, §2.3, §2.4. adopt installs at PROJECT
  scope, but `claude plugin update/uninstall/install` default to USER scope and REFUSE a project install
  (verified real claude: scope-less `update` → rc1 "not installed at scope user"; `uninstall` → rc1
  "enabled at project scope"). So every version-bumping pull's resync failed → cache never gained the new
  version → auto-preflight #8 bricked the worker fail-closed. Fix threads the recorded scope onto
  update/uninstall/install. VERIFIED scope surface: `marketplace update` takes NO `--scope`; `marketplace
  remove` is deliberately SCOPE-LESS in eject (the project settings.json was already byte-restored at
  step 4, so `--scope project` would fail "not declared in project settings" — scope-less removes from
  every scope AND clears the user-global `known_marketplaces.json`).
- **[MEDIUM] partial adopt (add ok, install fails) orphaned an unrecorded settings.json edit** → §2.1.
  `marketplace add --scope project` writes `extraKnownMarketplaces.<mkt>` immediately; on an install
  failure the code returned recording nothing → eject could never reverse it → dirty tree. Fix
  byte-restores settings.json (or removes a file the add created) on the install-failure branch.
- **[LOW] `json-merged` stores the whole settings.json → a secret there is at-rest** → §2.1 credential
  note. The absolute invariant claim ("no secret by ANY code path") was corrected to its true scope: no
  secret from a DESIGNATED secret-bearing basename. `.claude/settings.json` is non-secret BY DESIGN
  (decision #3) but CAN carry a secret → stored at-rest in the 0600 manifest — LOW because (i) no
  output/log leak (`show`/`verify` print byte-counts only), (ii) settings.json is itself co-equally
  un-gitignored. NOTE (reconciliation): adopt scaffolds **no `.kickoff/.gitignore`**, so the manifest is
  gitignored only if the adopter's root `.gitignore` already covers `.kickoff/` — a candidate follow-up
  (scaffold a `.kickoff/.gitignore`) if the manifest's at-rest exposure is ever tightened.
- **[LOW] origin dogfood-inertness was incidental, now ENFORCED** → §1.3, §7 step 1. `session-run.sh`'s
  `--plugin-dir` gate was presence-only; `supervisor.sh:60` defaults `KICKOFF_CORE_DIR` to the repo root,
  so one stray `export`/`set -a` would make the live origin auto-load its own half-built plugin (memory-
  hook double-fire + MCP re-declaration). Fix adds `--plugin-dir` ONLY when `realpath KICKOFF_CORE_DIR` !=
  `realpath REPO_DIR` (an adopter's core is a separate clone; the origin's equals its own repo).
- **[LOW] claude-absent eject swept the cache but orphaned the registry** → §2.4 step 5. The `rm -rf` sat
  OUTSIDE the `command -v claude` guard, so with claude absent the cache was deleted while the registry
  entries (which only `claude` clears) survived → dangling. Fix keeps state consistent: on the last-adopter
  path with claude absent, skip the WHOLE user-global removal and warn to re-run with claude on PATH.

Green after: plugin-selftest 126/0 (12 new regression assertions, each proven RED on pre-fix), adopt 74/0,
pull 80/0, eject 108/0, machinery 26/0, scan clean. Live `~/.claude/plugins` verified PRISTINE throughout
(known_marketplaces = only claude-plugins-official, installed = 9); origin stays inert (plugin-list empty,
argv gains no `--plugin-dir` even self-referentially — the Fix above STRENGTHENS dogfood-safety).

**Post-build §5 fix-round-2 — focused re-review hardening (2026-07-07)** — the round-1 fixes above were run
back through a focused 2-lens adversarial RE-REVIEW (eject-reversal-registration · upgrade-scope-containment)
briefed to re-trigger each original bug AND hunt fix-introduced holes. 6 CONFIRMED, collapsing to **4 distinct
root causes** (the dry-run×claude-absent and the register-best-effort residual were each independently found by
both lenses), all reproduced against the real code under isolated `CLAUDE_CONFIG_DIR`, all closed at root.
Reconciling deltas:
- **[MEDIUM · fix-introduced] Fix-3 rollback DELETED a pre-existing settings.json when the bare `mktemp`
  fails** → §2.1. `_adopt_enable_plugin` captured the pre-edit bytes via a bare `pre="$(mktemp)"`; a broken/
  full/misconfigured `$TMPDIR` (or out-of-inodes) fails it — exempt from `set -e` as the non-final command in
  an `&&` list — leaving `existed=1, pre=""`. The install-failure rollback guard `[ existed=1 ] && [ -n "$pre" ]`
  was then FALSE → control fell to `rm -f "$settings"`, DELETING the operator's real config (permissions/MCP/
  hooks/env) with a misleading "created" log; a sibling variant (mktemp ok, cp fails) would empty-overwrite it.
  Fix keys the DELETE on `existed=0` ALONE (only a file the add genuinely created), validates the backup up-
  front and re-verifies `[ -s "$pre" ]` before trusting it, and WARN-and-LEAVEs a pre-existing file when there
  is no valid backup — a recoverable orphan (one stray marketplace key) beats destroying the operator's config.
- **[LOW] eject `--dry-run` misreported the plan when `claude` is absent** → §2.4 step 5. The Fix-6 claude-absent
  skip was gated `[ "$dry" != 1 ] && ! command -v claude`, so `--dry-run` never reached it and always printed
  "would uninstall + sweep cache" even though a real run in that env LEAVES everything (Fix 6). Fix drops the
  `[ "$dry" != 1 ]` guard (the branch is action-free — correct for both dry and real) and prints a claude-aware
  "would SKIP/LEAVE the user-global cleanup (claude absent)" preview.
- **[LOW] Fix-6 claude-absent remediation was a dead-end** → §2.4 step 5. It advised "re-run `kickoff eject`
  with claude on PATH", but eject removes `.kickoff/` (the manifest carrying the machine entry) in the SAME run
  → a re-run has no manifest → the user-global marketplace + cache would be permanently unreachable. Fix emits
  the EXACT self-contained cleanup commands (`claude plugin uninstall --scope <s> <p>@<m>` · `marketplace remove
  <m>` · `rm -rf <cachepath>`) baked from the machine rows read THIS run — actionable even after `.kickoff/` is
  gone. The residue is inert (nothing enables it; repo keys already reversed) but now reclaimable, not circular.
- **[LOW] register-at-adopt is best-effort → a registration failure narrows the shared-cache gate** → §1.3,
  §2.4 step 5. A silent register-at-adopt failure leaves an adopter invisible to a sibling's `adopters-others`,
  re-opening the closed-HIGH cache tear through the registration gap. Proportionate LOW fix (deliberately NOT
  new destruction logic): (i) a register failure is now LOUD — a prominent WARNING naming the one-command repair
  — not a quiet log; and (ii) eject's destructive path gates on a new READ-ONLY `adopters-self` query: it
  proceeds with the user-global sweep ONLY if the ejecting adopter is provably in its OWN registry (an adopter
  absent from its own registry ⇒ the registration path is unhealthy ⇒ conservatively LEAVE, fail-safe).
  **Best-effort limitation (held consciously):** the machine adopters-registry is THE shared-cache-safety signal;
  a registration failure narrows same-tag protection to the "my OWN registration failed" half — the `adopters-
  self` gate catches exactly that, but a sibling whose registration failed while the ejecting adopter registered
  fine remains a narrow residual (a transient registry write-failure AND that sibling never runs `kickoff pull`,
  which re-registers). Recoverable by re-running `kickoff adopt`/`kickoff pull` across the adopters to repair the
  registry; a registry ERROR still fails safe (malformed ⇒ `_load_registry` dies ⇒ query non-zero ⇒ LEAVE).

Green after: plugin-selftest 144/0 (+18 round-2 regression assertions — FixA×5, FixB×4, FixC×4, FixD×5; 14 of
them flip RED on the pre-fix code, the other 4 being dry-run-changes-nothing / precondition invariants that must
hold in BOTH states), adopt 74/0, pull 80/0, eject 108/0, machinery 26/0, scan-secrets clean, scan-structure
advisory-only. Live `~/.claude/plugins` verified PRISTINE throughout (known_marketplaces = only claude-plugins-
official, installed = 9, byte-identical hashes before/after); origin stays inert (dogfood-safe).

**Post-build §5 fix-round-3 — resync cwd containment (2026-07-07)** — a follow-up review of THE PLUGIN's pull
path found a real cwd bug that ALSO leaked the test suite into the LIVE origin config. `_resync_plugin_cache`
ran its `claude plugin … --scope project` calls WITHOUT cd'ing to the adopter repo; `--scope project` resolves
"project" relative to `$PWD/.claude/settings.json`, so a `kickoff pull` whose invocation cwd ≠ the adopter wrote
the adopter's enablement (mechanism B's `install --scope project`) into the WRONG project's settings.json.
Contrast `_adopt_enable_plugin` + eject's uninstall, which already `( cd "$target" && claude … )`. Impact:
- **PRODUCTION (not test-only)** → §1.3, §5. The pure-pull guard's own design has a pull adopter run the front
  door FROM the read-only core clone with `REPO_DIR=<their repo>`, so cwd ≠ the adopter is the EXPECTED shape.
  Mechanism B (a same-version re-pull) then writes `enabledPlugins` into whatever cwd the pull ran from — the
  read-only core clone (dirtying it → the NEXT pull's clean-tree guard fail-closes), `$HOME`, or an unrelated
  repo. Mechanism A's `plugin update` is a re-snapshot (no enablement write), so the sharp edge is mechanism B.
- **TEST leak** → the mechanism-B re-pull assertion drove `bash scripts/plugin-selftest.sh` from the repo root
  to write `{"enabledPlugins":{"kickoff@kickoff-local":true}}` into the ORIGIN's `.claude/settings.json` — a
  live-config mutation, and the pre-push lefthook gate runs this suite.
Fixed at ROOT: thread `REPO_DIR` (the adopter) into `_resync_plugin_cache` as arg 1 and wrap BOTH mechanisms'
claude calls in `( cd "$adopter" && … )` (the scope-less `marketplace update` doesn't need it, but cd'ing the
whole chain keeps the two mechanisms symmetric). Origin stays dogfood-inert: no machine plugin entry → the §4c
resync block is skipped → `claude` is called 0×, so the edit cannot touch the origin. Three test-hygiene
backstops added: (1) a **regression test** — a pull from an invocation cwd ≠ the adopter must re-enable in the
ADOPTER and leave the invocation cwd's settings.json absent (both discriminator assertions RED on pre-fix);
(2) a **CANARY** — the origin's `.claude/settings.json` is snapshotted at suite start, re-compared at end, and
FAILs loudly + AUTO-RESTORES on any drift (catches ANY future cwd leak into the live repo, independent of the
stub); (3) a **STUB GUARD** — the stub `claude` (and the two inline stubs) now REFUSE to write a project
settings.json whose realpath is not under `$TMPDIR`/the system tempdir/`/tmp`, exiting 4 loudly so a mis-cwd'd
test fails fast instead of silently leaking into a real repo.

Green after: plugin-selftest 149/0 (+5: 4 cwd-leak regression assertions [2 flip RED on pre-fix — the adopter-
re-enable + no-invocation-cwd-leak discriminators; the other 2 being the strip precondition + mechanism-B-fired
invariants that hold in BOTH states] + the canary), adopt 74/0, pull 80/0, eject 108/0, machinery 26/0, scan-
secrets clean. The pre-fix RED was proven by reverting ONLY the cd (147/2). Live `~/.claude/plugins` verified
PRISTINE throughout (known_marketplaces = only claude-plugins-official, installed = 9, no kickoff-local residue),
and the origin `.claude/settings.json` stayed BYTE-UNCHANGED across every run (the stub guard blocks the write;
the canary confirms).
