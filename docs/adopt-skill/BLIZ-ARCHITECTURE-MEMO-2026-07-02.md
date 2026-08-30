# Kickoff ↔ Bliz — architecture memo (Fable 5 pass, 2026-07-02)

*Decision-ready memo from the Fable 5 architecture pass over both briefs (`kickoff-side-architecture-brief.md`, `bliz-side-integration-brief-2026-07-02.md`) + both live repos (`~/claude-kickoff`, `~/bliz-repo`). Relay is coordinator-to-coordinator via the founder.*

## 1. Thesis

Both briefs are right about the disease but the repos say the cure is smaller than "a dependency mechanism." Verified directly: there are already **six copy-lineages** on this box (three of `memory-retrieval`, two `mc-update.py` schema-lineages, a byte-for-byte workflow pair, a 292-line supervisor reimplementation) — and the *only* reason any had to exist as patched copies is **one unparameterized string** (`REGROUND_PROMPT` in `claude-kickoff/scripts/session-run.sh:58`, with `memory/MEMORY.md` and kickoff's own Telegram channel baked in). Meanwhile kickoff has **zero git tags, a dirty working tree, and a live worker committing to its own checkout** — so even a willing puller has nothing stable to pull. The longevity answer is not a package registry; it is three cheap, ordered moves: **(1) parameterize the instance boundary so no copy is ever forced, (2) give adopters a stable thing to pull (a tag-pinned, read-only core checkout per box + a `kickoff pull` turnkey with a lockfile), (3) turn the adopt-time warnings into a fail-closed preflight contract every supervisor start re-asserts.** Everything else hangs off those three. The rule that makes it hold: every file in an adopter is either **generated-then-owned** (charters, CLAUDE.md — never synced) or **pulled-and-pinned** (scripts, retrieval code — never hand-edited). The forbidden middle state, *copied-and-patched*, is exactly what `bliz-finalize-adoption.sh` step 4 would create — and it hasn't been applied yet (`bliz-repo/.kickoff/` doesn't exist), so there is a short window to never birth that copy at all.

## 2. Ranked recommendations

**R1 — Parameterize the instance boundary in core (first; everything depends on it).** In kickoff: make `session-run.sh`'s `REGROUND_PROMPT` overridable + interpolate a `MEMORY_INDEX` var instead of the literal `memory/MEMORY.md`; change `TELEGRAM_STATE_DIR` default from kickoff's own channel to **fail loudly if unset** (defaulting to origin's channel is exactly how Bliz's blocker #1 double-poller happens); add `MC_STATE_FILE` to `mc-update.py`; parameterize the retrieval index-db + log paths (why `bliz-repo/tools/memory-retrieval/` exists as a stray data copy). Define one `.kickoff/instance.env` the core scripts source (memory path · channel · permission mode · MC state file · caps · deploy-fence). ~½ day. **Land before Bliz applies finalize** → the launcher step collapses to `START_CMD`+env, no copy.

**R2 — Preflight contract: enforce, don't warn.** Generalize Bliz's finalize preflight into core as `kickoff preflight` — fail-closed assertions at finalize AND every supervisor start: worker channel ≠ operator's (and ≠ origin's) · memory path resolves · if a deploy branch is declared, assert the tool-layer fence exists (no blanket `git push` allow, explicit deny) · single supervisor lock · load headroom · **pulled files match lockfile checksum** (hand-editing fails preflight → copied-and-patched becomes mechanically impossible). All 3 footgun blockers were "documented as warnings, enforced by nothing." Highest-generalizability contribute-back. ~1 day.

**R3 — Consumption: a tag-pinned, read-only core checkout per box + `kickoff pull` + per-adopter lockfile (NOT a package, NOT a submodule).** `~/kickoff-core/` = a separate clone at a tag, never a working tree anyone edits; adopters reference by absolute path (Bliz's hook → `~/kickoff-core/memory-retrieval/hook.mjs`, `START_CMD` → `~/kickoff-core/scripts/session-run.sh`). `kickoff pull` = `git fetch && checkout <tag>` + run each adopter's preflight + update `.kickoff/core.lock`. Then delete the copies (`~/bliz-memory/` code [keep its data], `bliz-repo/mission-control/mc-update.py`, `tools/memory-retrieval/`). Not the live checkout (dirty + a worker commits to it). Not a submodule inside a deploy-on-push repo. Not a registry (2½ adopters, one box = over-build; identical semantics at ~zero machinery; generalizes off-box later). Drift is live: `~/bliz-memory/` already diverged, and kickoff's recall-metrics upgrade (commit 824dc5d) never reached Bliz. ~½ day after R1. `kickoff pull` stays a **human-run turnkey** (self-modification).

**R4 — Version core + PR-shaped loop (release-discipline-lite).** Kickoff tags (`core-v0.x`) + a short `CORE-CHANGELOG.md`; `instance.env` param names = the stability contract; findings flow as origin PRs carrying the **general lesson only** (generalizability gate) with `Found-by:` attribution. Kickoff has **no tags today** — pull has nothing to pin against. Hours.

**R5 — Mission-state: version the schema, guard the write, keep two boards.** Add `"schema":"kickoff-mc/1"`; `mc-update.py` refuses to write a mismatched store (cross-write guard, enforced). Do NOT unify Bliz's two stores now (box cockpit vs eng spine = two unrelated programs sharing a filename; box board is live operator state). Hours.

**R6 — Box policy as instance config.** `instance.env` carries `MAX_CONCURRENT_AGENTS`/effort tier; preflight promotes the load check to a soft gate; rotate `supervisor.log` (kickoff's is at ~71MB). Hours, opportunistic.

**Sequence:** R1 (kickoff) → apply Bliz finalize's *safety half* (fence/bot/excludes) → R3+R2 land with the first tag (R4) → Bliz launcher via `START_CMD`+env, copies deleted → R5/R6 opportunistic. ~3 focused days across both sides; then a kickoff improvement reaches every adopter as one tag bump + one human tap.

## 3. Reusable-vs-instance boundary

Governing rule: **pulled-and-pinned** (never hand-edit; parameterize) vs **generated-then-owned** (never synced). *Copied-and-patched is forbidden; R2's checksum assertion makes it fail preflight.*

| Travels via core (pulled, pinned) | Stays instance (owned locally) |
|---|---|
| `supervisor.sh` · `session-run.sh` · `start-supervisor.sh` · `go-autonomous.sh` | `.kickoff/instance.env` — memory path, channel/bot, permission mode, state file, caps, deploy-fence |
| `memory-retrieval/` code + eval-set **template** | Memory facts, `MEMORY.md`, `memory-index.db`, log, **tuned floors** (Bliz VEC 0.30 vs kickoff 0.20), `eval-set.json` |
| `mc-update.py` + mission-state **schema** (versioned) + `render-tracker` | `mission-state.json` **data**; the box cockpit (`mission-v2`) entirely |
| Preflight/finalize framework (the assertions) | The fence *values*: deploy branch, channel IDs, chat |
| Charter **template** + `bootstrap`/`adopt` skills | The 17 authored charters, `ORCHESTRATION.md`, every `CLAUDE.md` |
| Adversarial-review workflow **scripts** (byte-identical both sides today) | Which paths *mandate* review (money·signing·auth·migrations) |
| Quality-bar pattern; health-scorecard **shape** | Bliz's 19 CI workflows, `lefthook`, sqlx/Atlas — never displaced by core's scanners |
| Trust-boundary **shape** ("spend+destruction stops for a human") | Trust-boundary **specifics** ("push-to-main = prod deploy") → settings deny + required review check |

**Open items resolved:** mission-state schema → core (versioned, guarded); scorecard → shape core, gate commands instance; domain skills → instance until a 2nd adopter needs one (rule of two); trust boundary → shape core, specifics instance.

## 4. The founder's forks

**Fork A — Consume core: PULL (pinned checkout + lockfile) vs vendored-divergent copies. → PULL, now, thin form.** Copies: the observed decay compounds (3 `memory-retrieval` variants after one month/one adopter; recall-metrics already stranded; every fix re-ports by hand — the 40× DoS precedent); by adopter #4 kickoff is a template that rots. Pull: Bliz gives up hand-patching (routes through upstream params — R1 makes that near-free); kickoff takes on Fork C's discipline. **Timing sub-fork: do it now** — the finalize isn't applied yet, so acting now means the worst copy (`bliz-session-run.sh`) is *never created*.

**Fork B — Worker permission on a live-money repo: relay-default vs auto. → relay-default now.** Live evidence decisive: blanket `git push`/`git merge` allow + empty deny on a push=prod-deploy repo = auto today is an unreviewed-deploy path held back by prose. Auto is discussable only after 3 enforced preconditions: tool-layer push deny + a **required** adversarial-review status check on main + the dedicated worker bot verified by preflight. Relay costs one tap per push (the trust boundary working); premature auto risks the one error no rollback fixes.

**Fork C — Kickoff posture: release-disciplined vs living-HEAD. → release-discipline-lite (tags + changelog + param stability; no registry/semver ceremony).** Living-HEAD makes `kickoff pull` roulette against a dirty tree a worker commits to → adopters re-freeze into private copies, silently undoing Fork A. Discipline = a small permanent maintainer tax, which is the honest cost of being "one system that builds systems."

## 5. What NOT to build yet (ship > over-build)

- A **package registry / npm packaging** — 2½ adopters, one box; pinned clone gives identical semantics free. Revisit at first off-box adopter or #4.
- **sqlite-vec / a vector store** — retrieval is FTS5/BM25 + local embeddings + brute-force cosine, comfortable into the thousands; Bliz at 133 facts. The real near-term memory work (recall metrics, eval harness) already exists in kickoff and just needs to *reach* Bliz (R3). Revisit at ~5–10k facts.
- **Unifying the two mission-state stores** — different products, one live operator state. Version + guard (R5); unify only as a deliberate MC-v3 design.
- **Any auto-sync daemon** — `kickoff pull` stays human-run (self-mod gate).
- **Porting Bliz's 47-agent footgun-review harness into core as a mandatory adopt step** — keep review opt-in + sized; what graduates to core is its *output* (R2's assertions), not its cost.
