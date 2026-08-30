# Adoption-approach validation — brownfield + greenfield (Fable, 2026-07-07)

Two parallel Fable adversarial validations (operator-requested, msg 1266/1268), each checking the
**design intent vs the actually-implemented engine**. Brownfield: 5 lenses (boundary · reversibility ·
upgrade+plugin · multi-repo · adopter-DevEx) + synth. Greenfield: 3 lenses (integration · de-integration ·
shared-model) + synth. Every HIGH was re-verified against file:line by the synths **and** the coordinator
spot-checked the load-bearing ones. Full lens/synth text: the workflow transcripts
(`wf_63164df4-74a` brownfield, `wf_22db5b1c-562` greenfield).

## Headline verdict

**Engine grade A · journey grade D · ~85% there — the missing 15% is exactly where a first adopter walks.**
No lens found a *structural* flaw: the seam model, the pin/pull contract, and the manifest reversal engine
are the right design and are genuinely adversarially hardened. What all eight lenses converged on is that
**the most-designed mechanisms were never WIRED into the flows that produce an adoption** — plus a cluster of
first-run plumbing bugs. Two patterns explain nearly everything: (1) *design-specified, engine-built,
journey-never-wired* (charter, seeded-instance recording, `.gitignore`, self-pin, status, reconcile); (2)
*defects hide at untested COMPOSITIONS of individually-hardened slices* (the per-slice selftests are rigorous;
the seams between slices are where everything lives — incl. the stubbed `/adopt` in journey-e2e).

**The greenfield hypothesis ("≈ brownfield + a caution delta") is rejected AND inverted:** brownfield is the
clean path; greenfield is the entangled legacy path that fits NONE of the four lifecycle verbs (pull bricks
it, eject refuses it, upgrade is undefined, de-integration nonexistent) and has zero test coverage. But it is
fixable *by construction, cheaply* — make greenfield **create-then-adopt** and the same engine/instance/seam
model + byte-proven eject come free.

## What is SOLID (verified — do not touch)

The manifest reversal engine (realpath containment, mkstemp/O_EXCL atomic writes, byte-restore-primary with
hash gating, credential rule enforced at record+reverse+reassert, hook removal by content hash, no-clobber on
every divergence, ambiguity refusal). Eject's destruction gating (--delete-data + --confirm-destroy double
gate, archive-first 0600 + credential exclusion, settings.json reassert-as-final-write). The pull spine
(tag-only pinning, dirty-clone refusal, moved-tag fail-closed, format-2 whole-tree lock, seam-sync refuses
hand-edits). The adopters registry (realpath-keyed, flock'd, siblings/others/self distinction). The
untrusted-config subshell-whitelist posture, uniform across entry points. The headless-worker `--plugin-dir`
path (immune to the plugin-cache problem by construction). Preflight fail-closed + its greenfield/pull
carve-out (#1b). The selftest culture (500+ assertions, RED-proven) — its failure is **scope, not rigor**.

## Confirmed gaps — merged + ranked across both journeys

### TIER 1 — breaks the trust guarantee or the first-run (must-fix before ANY adopter)

- **G1 — the `/adopt` skill's entire output is manifest-invisible; "zero-trace" covers only the mechanical
  half.** [both passes; verified: `plugin/skills/adopt/SKILL.md` has 0 `record` instructions; it authors
  CLAUDE.md/agents/TRACKER/memory + **copies** `scripts/scan-*.sh` (SKILL.md:29-31, unpinned = the drift
  disease) + `lefthook install` git hooks — none recorded `seeded-instance`.] So eject can't reverse them,
  `--purge` is vacuous (ADOPT.md:163 dead letter), `--verify` flags them as residue. **journey-e2e passes its
  headline only because it never runs the `/adopt` half.** The shipped ADOPT.md/README "de-integrates
  completely, nothing to undo" is overstated. → Fix: rewrite the skill contract (record every touch;
  scanners via `.kickoff/bin` shims not copies; lefthook via extends/marker + eject-unhook); extend e2e to a
  simulated `/adopt` file set.
- **G2 — the charter delivery (the design's centerpiece) is dead code.** [verified: `gen-charter`'s only
  callers are `pull-selftest.sh` + `plugin-selftest.sh`; `cmd_adopt` (kickoff:770-859) never touches
  CLAUDE.md; the skill never mentions KICKOFF.md.] Every adopter reproduces the exact Bliz "charter never
  loads interactively" defect the design was written to kill; Fix-5's pull-charter transport is dormant; the
  block-strip eject machinery guards a block nothing writes. → Fix: wire `gen-charter` + the recorded
  `block-appended` @import into `cmd_adopt` (3 fixed lines, schema exists); put the `.kickoff/bin/mc`
  contract into the KICKOFF.md template.
- **G3 — the documented first-run breaks at ~4 moves + wrong-target defaults are systemic.** [each repro'd]
  (a) README:41 symlink install breaks every subcommand; (b) README/ADOPT order adopt BEFORE pull → hollow
  adoption (no core → no plugin → the printed "run /adopt" is impossible; no core.lock → preflight #6/#8
  inert); (c) the first pull clones the adopter's OWN product into ~/kickoff-core; (d) bare
  `kickoff preflight/up/pull/eject` target the kickoff CLONE, and **ambient REPO_DIR silently retargets
  everything — proven live**: a validation lens accidentally wrote `.kickoff/adopt-manifest.json` + `bin/mc`
  + a fake `core-v9.9` tag into THIS repo (removed; live repo verified clean). A forgotten `--dir` can adopt
  the read-only core clone, bricking every sibling's pulls. → Fix: `readlink -f $0`; add adopt/init/eject to
  the pure-pull guard + a core-clone self-guard; adopt self-pins + registers + stamps `KICKOFF_CORE_REMOTE`
  into instance.env; pull verifies the clone's origin; docs reorder **clone → pull → adopt**.
- **G4 — runtime state lands un-ignored at the repo ROOT, no `.kickoff/.gitignore` exists, docs claim
  otherwise.** [the known gap, WIDER: `instance.env.example:61/67/84` default MEMORY_DIR/DB/MC_STATE to
  repo-root; :13 falsely says ".kickoff/ is gitignored"; eject relocates only in-`.kickoff` paths; e2e
  passes only via a hand-written non-default state layout + deleting state pre-eject.] Scenario A: an adopter
  commits `.kickoff/` (docs invited it) → the 0600 manifest (base64-storing their ENTIRE pre-adopt
  settings.json), machine paths, churning locks land at origin. Scenario B: a repo that RAN → `mission-control/`,
  `memory-retrieval/`, `memory/`, `TRACKER.md` strewn at root → `--verify` honestly reports NOT clean. → Fix:
  scaffold `.kickoff/.gitignore` (recorded); move state defaults to `.kickoff/state/`; fix the false claims.
- **G5 — eject `--verify` has 3 honesty holes.** [verified: kickoff:1315 greps `kickoff@local`, NOT a
  substring of the real `kickoff@kickoff-local` (selftests plant the stale key → green-light the miss);
  kickoff:1347 `git status || true` reports a non-git target CLEAN; step-7 `rm -rf .kickoff` destroys files
  the reversal promised were "kept".] → Fix: correct the marker; fail/qualify verify on non-git; relocate
  kept/diverged before rm -rf.
- **G-GF1 — greenfield DE-INTEGRATION does not exist.** [CRITICAL; verified: `cmd_eject` hard-dies without
  `.kickoff/adopt-manifest.json` (kickoff:919-921); `cmd_init` writes only instance.env; bootstrap records
  nothing; a greenfield project is born INSIDE the clone (bootstrap SKILL.md:60-63), sharing kickoff's git
  history + read-only origin.] The operator's "de-integration is part of BOTH" is implemented for one side.
  → Fix (the elegant one): **greenfield = create-then-adopt** — bootstrap scaffolds OUTSIDE the clone (own
  `git init` + baseline), then `kickoff adopt --dir <it>`. Eject/de-integration then come free; one journey.
- **G-GF2 — `kickoff pull` on a greenfield clone self-bricks it.** [verified: pull writes core.lock
  unconditionally; preflight #1b keys pull-adopter mode on core.lock → hard-fails; check #8's recovery advice
  is wrong for this shape; recovery `rm .kickoff/core.lock` documented nowhere.] → Fix: pull refuses the
  greenfield shape (no manifest AND core inside REPO_DIR) with "greenfield upgrades via `git pull`".
- **G-GF3 — the public repo ships the MAINTAINER's live state as the newcomer's grounding.** [verified on
  origin/main `ae71c1f`: TRACKER.md = 326KB dev history; **79 `memory/` files** incl. operator-prefs +
  Bliz/client-pitch/3D-universe specifics; mission-state.json = 34KB.] CLAUDE.md mandates re-grounding on
  memory+tracker → a newcomer's session grounds in the maintainer's facts; also a privacy leak; also
  guarantees `git pull` merge conflicts (the only greenfield upgrade motion). Ties directly to the operator's
  "not a template repo → installable tool" direction ([[kickoff-distribution-direction-installable-tool]]).
  → Fix: `kickoff init` seeds blank tracker/memory-index/state; quarantine/template-ize the shipped
  maintainer memories + tracker (also the private/public split I under-did on the core-v0.2 ship — many
  operator-preference memories are public that should be vaulted per [[memory-public-private-split-for-adopters]]).

### TIER 2 — multi-adopter / plugin composition + operability (before adopter #2 on one box)
- **G6** plugin marketplace source is a frozen single machine path → a worktree pull resyncs the WRONG plugin
  version + bricks fail-closed (circular remediation). → re-point to `$work_dir/plugin` on worktree pull.
- **G7** pull's mechanism-B is a destructive shared-cache op with no sibling gate, fires on every same-tag
  re-pull ("idempotent" is false), re-serializes settings.json with no reassert (voids eject byte-restore),
  version read is `rows[0]` scope-blind. → verify-first resync; gate on adopters-others; snapshot+reassert.
- **G8** a freshly-CREATED `.claude/settings.json` is classed seam+hash-pinned → the first accepted permission
  prompt fail-closes preflight #8. → record it as a no-hash-check class.
- **G9** `kickoff status`, `adopt --dry-run` (the consent surface), `adopt --reconcile` don't exist. **Bliz —
  the only live adopter — has core.lock but no manifest → it hits preflight #8 the moment it pulls this core,
  and the migration path doesn't exist.** (The tracker's "§7 step 2 BUILT reconcile" claim is wrong.)
- **G10** identity/collisions: ingress teardown + archive names keyed on repo BASENAME (ejecting `~/work/app`
  can delete `~/clients/x/app`'s live routes; logs "removed" on no-op); the sibling-channel-equality check
  compares env vars nothing sets (dead code) → two adopters can share a bot; the mc shim resolves paths from
  ambient REPO_DIR. → record ingress projects + eject only recorded; registry-backed channel check; anchor
  REPO_DIR in the shim.

### TIER 3 — real but cheap (docs + strings)
UPGRADING.md documents the retired lock format + the "exactly two things" (now three) contract · README calls
Telegram "(optional)" while preflight hard-FAILs without it + nothing creates `memory/MEMORY.md` before
preflight demands it (two guaranteed first-preflight failures) · the mc shim error points at a `.kickoff/README`
nothing creates · main-branch provenance stamps are non-tags that confuse sibling detection · `up --dry-run`
never exits · `--deep` is a parsed no-op whose stated blocker has landed · README's reversibility trust line
sits above the greenfield section it doesn't apply to · two disconnected greenfield stories (`kickoff init`
appears in ZERO docs).

## The fix plan (unified, phased)

**PHASE 1 — must-fix before ANY wider adoption (~1 focused session + e2e):**
1. Wire the charter: `gen-charter` + recorded @import block into `cmd_adopt`; mc-shim contract into the
   KICKOFF.md template. (G2)
2. Rewrite `/adopt` SKILL.md: record every touch `seeded-instance`; scanners via shims; lefthook via
   extends/marker + eject-unhook. (G1)
3. Journey plumbing batch: `readlink -f`; guard adopt/init/eject (pure-pull case list + core-clone self-guard);
   adopt self-pins + registers + stamps KICKOFF_CORE_REMOTE; pull verifies clone origin; conditional /adopt
   handoff; docs reorder clone→pull→adopt; the Telegram/memory-stub first-preflight fixes. (G3 + Tier-3)
4. Greenfield = **create-then-adopt**: bootstrap scaffolds OUTSIDE the clone (own git init), then adopt →
   eject/de-integration come free; fence `kickoff pull` against the greenfield shape. (G-GF1, G-GF2)
5. State + git boundary: scaffold `.kickoff/.gitignore` (recorded); default state to `.kickoff/state/`; fix
   the false "gitignored" claims. (G4)
6. eject `--verify` honesty: marker fix, non-git refusal, relocate-not-delete before rm -rf. (G5)
7. Reclassify the created settings.json out of the hash-pinned seam class. (G8)
8. Instance-state reset + repo-hygiene: `kickoff init` seeds blank tracker/memory/state; template-ize /
   vault the shipped maintainer memories + tracker (G-GF3 + finish the public/private memory split).
9. **Make journey-e2e HONEST**: run on scaffolded defaults, with state present at eject, through a symlinked
   front door, **with a simulated `/adopt` file set + a GREENFIELD leg** — this is what stops the whole class
   recurring (it's why G1/G-GF2 shipped). Add to pre-push.
10. Correct the overstated ADOPT.md/README "zero-trace" claim to match reality until 1-9 land (it is LIVE on
    origin/main now — own the miss).

**PHASE 2 — before adopter #2 / before migrating Bliz:** plugin transport (G6+G7) + one real-claude pass for
the 3 PLAUSIBLEs (mechanism-B whole-cache-delete, double-adopt reinstall, absence-case reassert) · `adopt
--reconcile` (G9 — **Bliz cannot migrate without it**) · `kickoff status` + registry-backed collision checks (G10).

**PHASE 3 — nice-to-have:** UPGRADING.md rewrite · `.kickoff/README` · error-string cleanup (circular
remediations, "removed"-on-no-op) · rc-tag filter · plugin-version release gate · `--deep` implement-or-remove.

## Needs the operator's judgment (genuine forks, not defects)
1. **Commit-the-seams posture** (design fork #4): track `.kickoff/KICKOFF.md` + `bin/` in git (team-shareable,
   a teammate's clone works without re-adopt) vs keep `.kickoff/` fully ignored (every clone re-runs adopt)?
   The Phase-1 item-5 `.gitignore` contents depend on this call.
2. **Telegram**: a hard requirement (fix the README to say so) or a degrade-gracefully worker (fix preflight)?
   The minimum-viable-adoption product call.
3. **Bliz migration timing**: pulling this core before Phase-2 `adopt --reconcile` lands will fail-close Bliz's
   preflight — sequence deliberately.

## Bottom line
The architecture is the right design, hardened for real. The last mile was never wired: the journey a real
adopter walks doesn't yet reach the engine built for them. Close Phase 1 and the headline promise becomes true
as written. This validation is exactly the strongest-model gate paying off — it caught that our shipped
"proven zero-trace" holds only for the mechanical half, before an adopter did.
