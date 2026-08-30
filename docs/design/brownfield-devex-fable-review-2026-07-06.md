# Brownfield DevEx design — Fable-5 adversarial + Principle-0 review

**Date:** 2026-07-06 · **Reviewed doc:** `docs/design/brownfield-devex-design.md`
**Method:** 6 adversarial lenses (4 grounding clusters + charter-principles + design-soundness), all on `claude-fable-5`, read-only (`reviewer` agents), each verifying the design as a CLAIM against the live system as the FACT; a `claude-fable-5` synthesis adjudicated. Workflow `wf_017cc216-4aa` · 566k subagent tokens · 146 tool calls · 7/7 agents clean.

> Triggered by the operator's ask: *"did fable also review those on principles?"* — the answer was "not yet," so this is that pass. It paid for itself.

---

## Verdict: **REFINE** (a focused doc pass, not a redesign)

> The architecture is sounder than the design dared claim (both load-bearing spikes PASS, the drift evidence is even stronger than stated), but one false Bliz inventory, a falsified eject acceptance test, a repo-bricking lefthook rule, and the unexamined plugin-cache layer must be fixed in the doc before docs/build touch an adopter's repo.

**Grounding:** ~20/22 deduped current-behaviour claims verified TRUE (many exact to md5/line-number, several *stronger* than stated). 2 WRONG (Bliz memory-hook anatomy — high consequence; "six plugins" — nine at writing). 1 drifted (v2.1.198 → 2.1.199, true at writing). **Both spike-gated unknowns now PASS** — the reviewer re-ran `@import` itself (token round-trip through the exact marker block on 2.1.199) and confirmed a `--plugin-dir` plugin carries the UserPromptSubmit hook + skills.

---

## Must-fix (before docs/build)

### HIGH
1. **§1.1 defect #4 is a false inventory.** Bliz's *tracked* `.claude/settings.json` has NO memory hook (only `enabledPlugins` + SessionStart). The live hook is in gitignored `settings.local.json` (UserPromptSubmit) exec'ing `~/bliz-memory/hook.mjs` — a THIRD forked copy (md5 `7eef163b` vs pinned `b8628dd9`); `memory-retrieval/` holds only a DB; and it's live **split-brain** (hook inlines MEMORY_DIR+floors but not MEMORY_DB → defaults to `~/bliz-memory/memory-index.db` while `instance.env` declares the repo path; the two DBs differ, `c9fe9046` vs `42532810`). The design quoted **kickoff-itself's** `settings.json:8` and attributed it to Bliz. *§5's "retrieval silently degrades" is already happening.*
   **Fix:** correct §1.1; widen §2.4 `--reconcile`/§7-step-2 to retire/re-point `~/bliz-memory`, remove the `settings.local.json` UserPromptSubmit entry when the plugin hook lands (else memory injects twice), reconcile the two DBs. **`settings.local.json` carries live credentials (Telegram bot token, PostHog key)** → edits must be surgical jq-path ops, never rewrite-whole, never log contents. The plugin-hook + instance.env-canonical direction survives — the disease is real and worse than stated.

2. **§2.4 eject acceptance test is falsified by the design's own mechanism.** jq add-then-del on Bliz's 4-space `settings.json` re-indents the *whole file* to jq's 2-space → every untouched line differs → `git status --porcelain` NOT empty. Also incoherent: step 3 says "restore stored originals for modified" but the manifest action enum (`created|block-appended|json-merged|hook-installed`) defines no `modified`; and the test's git baseline is undefined against fork #4's atomic adoption commit.
   **Fix:** make **restore-stored-original-bytes the PRIMARY reversal** for every modified file (schema's `original` slot exists), gated on hash-unchanged-since-adopt; jq-path removal only as the interleaved-edit fallback with an honest "formatting may differ" report. Define the test's git baseline. Fixture MUST include a non-jq-canonical `settings.json`.

3. **Third unacknowledged load-bearing assumption: the plugin runs from a user-global CACHE, not source.** All 9 installed plugins execute from `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`. If a local-path marketplace also snapshots, interactive sessions keep running the install-time copy after `pull` moves the clone — the stale-`mc-update.py` drift disease reborn one layer up, invisible to preflight #8 as designed. Marketplace registration + `installed_plugins.json` are user-global touches the manifest never records and eject never removes → contradicts §0's "provably reverses all of it."
   **Fix:** extend §7 spike (b): after `claude plugin marketplace add ~/kickoff-core/plugin` + enable, check where `installPath` points. If cache → (1) `pull` gains a mandatory plugin-update step, (2) preflight #8 hashes the cache against the pinned tag, (3) manifest gains machine-level entries + eject removes them when the last sibling ejects.

### MEDIUM
4. **§2.1 lefthook EXTEND rule bricks the adopter's gate suite.** Reproduced with Bliz's own lefthook binary + config: appending a second top-level `pre-commit:` key → `yaml: mapping key "pre-commit" already defined` → whole config unloadable, every existing gate stops. The opposite of additive.
   **Fix:** structure-aware insertion under the existing `pre-commit.commands` mapping (marker comments work in nested YAML; eject strips the marked lines), or lefthook `extends:` with `.kickoff/lefthook-kickoff.yml`. Fixture needs a pre-existing `pre-commit:` key.

5. **KICKOFF.md is never classified + its upgrade semantics are undefined.** If SEAM → a repo-tailored charter is permanently "modified" → §2.3 seam-sync refuses on every pull (charter-upgrade path dead); if INSTANCE → engine charter improvements never reach adopters. SEAM definition also leaks: §1.4 calls `.kickoff/bin/` shims SEAM, but `.kickoff/` is not a CC fixed home and nothing in discovery forces them there.
   **Fix:** split the charter — an engine-generated SEAM `KICKOFF.md` that `@import`s an adopter-owned `KICKOFF.local.md` (the managed-block pattern one level down). Redefine SEAM as "engine-shaped file *required inside the repo*", dropping "forced by CC fixed-location discovery."

6. **Eject sequence contradicts its own default.** Step 6(b) default = "your data — leave in place", but `mission-state.json` / TRACKER render / `memory-index.db` live in `.kickoff/state/` — inside the folder step 7 unconditionally deletes. `--verify`'s "no trace" is incompatible with "leave." With `--archive` off, the only protection is a prompt the sequence then violates.
   **Fix:** define "leave" mechanically (relocate `state/` out of `.kickoff/` before delete, or a verify-allowlist); require the explicit destructive yes for `--no-archive` + delete.

7. **§2.3 items 4 & 5 collide.** Whole-tree clean-check + nested worktree versioning break each other: `git worktree add versions/core-v0.2` makes the parent clone's porcelain show `?? versions/`, so any adopter whose `KICKOFF_CORE_DIR` still points at the root clone (Bliz today) fails its clean-tree check the moment adopter #2 triggers the first worktree — the new lock manufactures the incident item 5 exists to prevent. Prune step is undecidable (nothing enumerates adopters).
   **Fix:** park version checkouts OUTSIDE the clone (`~/kickoff-versions/<tag>/`) or make `~/kickoff-core` bare; or exempt `versions/` in the clean-check. Add a machine-level adopters registry before any prune logic.

8. **§4 ingress promotion — three verified gaps, one an active outage path.** (a) the live investor pitch-deck route is a hand-edited `basic_auth` block (bcrypt users for named external people) that the generator destroys — the preview skill's own `gen && up` takes that shared URL **offline on first run**; (b) `RESERVED_PRIVATE_PORTS` guard lives only in `add_app()` — `gen()/up` regenerate from the hand-editable registry with no check → one registry edit + up can publish Mission Control to the internet; (c) caddy wildcard-binds `*:9000` (verified via `ss`) → "funnel-only" understates LAN exposure and the tailnet-private default is not private until the bind moves to `127.0.0.1`.
   **Fix:** add an `auth` field to the registry schema + generate `basic_auth` from it; move reserved-port validation into `gen()`; add "bind caddy to 127.0.0.1:9000" to §4 prerequisites; preview must health-check each upstream before sending the ONE URL (`/bliz/dashboard` 502s today).

### LOW
9. **Fail-closed absence semantics unspecified for the new manifest** (preflight #6 today is "Absent → skip"; if #8 inherits it, deleting `adopt-manifest.json` silently disables seam verification + removes eject's spine = fail-open). Plus freshness discipline: binary is 2.1.199, 9 plugins not 6.
   **Fix:** once `.kickoff/` exists, a missing manifest is a preflight FAIL with `adopt --reconcile` as recovery; add the "NOT anti-tamper" caveat for the unsigned manifest; stamp env claims with version+date; **update §5/§6.1/§7: spike (a) @import is PASSED (verified 2.1.199) — only the taste call of fork #1 remains**; cite the 3 project-scoped plugin entries as live proof of per-repo scoping.

---

## What got STRONGER under attack (reassurance)
- **Nothing invalidates the SEAM / manifest / shim / plugin / eject architecture.** REFINE, not BLOCK.
- **Both load-bearing spikes PASS** — `@import` loads `.kickoff/KICKOFF.md` (reproduced on 2.1.199; live specimen `~/.claude/CLAUDE.md = '@RTK.md'` resolves every session); a `--plugin-dir` plugin carries the hook + skills (MCP-in-plugin proven by the production telegram plugin). *Fork #1 reduces to a pure taste call.* (Verified headless — one interactive smoke before "device-verified.")
- **The core drift specimen is worse than stated** (strongest evidence FOR the design): Bliz's stale `mc-update.py` is 314 vs 393 lines, ZERO `MC_STATE_FILE` support, no detached-HEAD write-guard — so the `instance.env` contract is silently ignored by the code 8+ Bliz charters invoke repo-relatively.

## Sequencing (from the synthesis)
Fixes map cleanly onto the design's own §7: fix 1 → step 2 · fix 2 → step 3 · fix 7 → step 4 · fix 3 → step 5 (run extended spike (b) first) · fix 8 → step 6. A focused refine pass, not a redesign. After the doc pass: **BUILD** in the design's own order; fixture repo must include a pre-existing non-jq-canonical `.claude/` and a `lefthook.yml` with a `pre-commit:` key.

**Key paths:** `docs/design/brownfield-devex-design.md` · `~/bliz-repo/.claude/settings.local.json` · `~/bliz-memory/hook.mjs` · `~/kickoff-core/scripts/preflight.sh` · `~/kickoff-core/scripts/kickoff` · `~/box-ingress/{ingress.sh,Caddyfile,registry.json}` · `~/.claude/plugins/installed_plugins.json`

_Full machine-readable synthesis: `wf_017cc216-4aa` task output._
