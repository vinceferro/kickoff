# Bliz adoption findings — `adopt` skill v1 contribute-back

**Adoptee:** Bliz monorepo (`<org>/<monorepo>`)
**Review date:** 2026-07-02
**Status:** critical review complete — adopt-subset-now verdict; 4 improvements for the `adopt` skill

This document feeds generalizable improvements back to the kickoff orchestrator so the `adopt` skill is
sharper for all future adoptees. The Bliz case is the concrete evidence; every recommendation is written
for any brownfield repo, not Bliz specifically. The full internal review lives at
`~/obsidian-vault/Engineering/kickoff-adoption-review-2026-07-01.md`.

---

## What `adopt` got right (read this first)

These are worth calling out explicitly — the skill is additive and cautious in the right ways.

- **Independently verified the real repo structure.** Instead of trusting the adopted repo's own docs, the
  proposal ran `find apps/api/crates -maxdepth 1 -type d -name 'bliz-*'` and discovered 12 crates where
  the repo's `CLAUDE.md` implied ~6. It also verified the real gate commands by reading `package.json` and
  `CLAUDE.md` files directly. This independent ground-truth pass is the right default and should be made
  explicit in the skill's step 1.

- **Additive, nothing-overwritten posture.** Every proposed new file landed in a new path or new directory.
  Existing agents, workflows, and docs were left intact and explicitly listed as "untouched."

- **Self-modification gate respected.** The `adopt` skill correctly treats writing `.claude/settings.json`
  and git hooks as a human-run turnkey step — never a coordinator self-edit. The draft-then-human-approves
  charter flow matches the self-modification gate the repo already encodes.

- **Detected existing gates and proposed to REUSE them.** The `eng-reviewer` in the proposal was wired to
  run the repo's own `pnpm --filter @bliz/api lint:all`, `cargo nextest`, and `pnpm check-types` — not
  kickoff's generic scanners. This "reuse the adoptee's stronger gates" principle is sound.

---

## Finding 1 — State-spine detection must look BEYOND the repo root

**What happened.** `adopt` probed for `mission-control/`, `TRACKER.md`, and `memory/` at the repo root,
found none, and concluded "state spine absent → install one." But the adoptee ran a LIVE Mission Control
and memory system OUTSIDE the repo:

- `~/box-ingress/mission-v2/` — a live `mission-state.json` (48.7 KB) actively used from the operator's
  phone, with `.bak`, `.precleanup`, and `.pre-adopt-20260623` snapshots, the last of which is direct
  evidence of a prior adopt run already having collided with it.
- `~/bliz-memory/` — the mature BM25+vector hybrid memory hook, already wired and operational, descended
  from a prior Bliz→kickoff contribute-back.

Installing a new `mission-control/` + `memory/` would have created a second, clashing board with real
clobber risk. The `.pre-adopt-20260623` snapshot is proof this collision already happened once and had to
be backed up.

**Why the repo-root probe is insufficient.** Coordinator-pattern state spines are intentionally kept
outside the repo on many deployments (Obsidian Sync, coordinator-box `~/` dirs, running services) — because
the operator wants state to survive repo resets, CI clones, and worktree operations. Probing only the repo
root gives a false-absent signal for a running live setup.

**Recommendation.** Before concluding "state spine absent," `adopt` should:

1. Ask the adoptee: *"Where does your live coordinator state live — is there a running Mission Control
   board or memory system on the box?"*
2. Probe common out-of-repo locations (`~/box-ingress/`, `~/.kickoff/`, `~/bliz-memory/` or equivalents)
   for signs of a live spine (a running `mc-update.py`, a `mission-state.json`, a `memory/` hook install).
3. Default to **RECONCILE** over **install-fresh**: add a lane / reuse the existing memory rather than
   standing up a second board. The live MC already has per-source lane support (`mc-update.py` accepts
   source tags) — a new `eng` lane wires in without duplication.

---

## Finding 2 — Crew sizing must use actual LOC + commit velocity, not a generic N-split; reuse existing machinery

**What happened.** The proposed 8-agent split bundled `bliz-accounting` (17k LOC, active build surface —
the 5-provider platform had just shipped) into `api-platform` alongside `bliz-merchants`, `bliz-auth`,
`bliz-fx`, and `bliz-chains` (~52k LOC total). The proposal acknowledged "split later when it bites." But
`api-accounting` is already the largest single feature in that bundle and was the hot build surface —
authoring a bundled charter during the next accounting build would be far more disruptive than getting the
split right from day one.

Separately, the proposal included `pos-app` as a persistent domain owner for `apps/app` — the least-active
surface in the repo at adoption time (near-zero recent commits; focus is dashboard + records-layer + GTM).
A persistent agent with no dispatch volume is pure overhead.

On the shared-roles side, `eng-reviewer` partially duplicated two adversarial-review workflows already in
the repo (`pr-adversarial-review.js`, `spec-adversarial-review.js`) that are structurally stronger than a
single subagent — they fan out independent lens-reviewers with adversarial verification. A reviewer agent
that doesn't know to run these is a weaker gate than what already exists.

**Recommendation.** `adopt`'s crew-sizing step should:

1. **Read per-domain LOC and recent commit velocity.** `git log --since="90 days ago" -- <path> | wc -l`
   per domain takes seconds and gives a real signal. Size the crew to the actual churn: domains above a
   clear LOC + velocity threshold earn their own owner; dormant domains get ad-hoc dispatch.
2. **Detect existing review/CI/deploy machinery and default to REUSE.** If the repo already has an
   adversarial-review workflow, the reviewer charter should be a thin *dispatcher* of it — not a
   standalone agent that duplicates the pattern. If deploy is CI/IaC-owned, there is no `eng-deployer`
   role; encoding it anyway creates a dangerous charter with no valid job.

---

## Finding 3 — Phase adoption by build-volume; scar-driven subset first

**What happened.** The proposal offered an 8-agent engineering crew as the adoption unit. At Bliz's
adoption point — polish + GTM phase, low active build volume — most of that crew was good infra for the
next build phase, not an unlock for the current one. The 5-provider accounting platform had just shipped
via ad-hoc coordinator dispatch, proving the existing pattern was working well.

The two agents with immediate, session-independent value were the ones encoding irreversible scars: a
`data-migrations` agent hard-gated to never touch the prod DB (a prod-DB-destroy incident lived in the
repo's incident log), and an `api-money` agent requiring an adversarial-review pass on every funds-path
change. These earn their keep at any build volume because the scar they encode is always live.

**Recommendation.** `adopt` should offer a phased plan explicitly:

- **Phase 1 (now, any build volume):** safety-critical, scar-driven charters only — migrations (never
  prod DB) + money gates (adversarial review on funds paths). These are cheap to author, high value
  immediately, and never premature.
- **Phase 2 (when active multi-domain build begins):** domain owners for the surfaces with actual churn,
  sized by the LOC + velocity signals from Finding 2.
- **Phase 3 (mature):** the full crew, shared roles, state-spine integrations.

Framing this as a phased plan sets the right expectation and gives the adoptee a concrete, low-risk first
step instead of a binary "adopt all 8 agents now or nothing."

---

## Finding 4 — Verify canonical docs against the real tree; flag staleness before authoring charters

**What happened.** The repo's root `CLAUDE.md` described the API as `apps/api/src/features/<feature>`
with subdirectories `domain`, `application`, `infrastructure`, `presentation`. The real structure was a
12-crate Cargo workspace under `apps/api/crates/bliz-*`. Any domain-agent charter authored from the
`CLAUDE.md` description would point at directory paths that do not exist.

**Credit where it's due.** The `adopt` proposal *did* independently verify the real crate list (the
verification log explicitly ran `find apps/api/crates -maxdepth 1 -type d -name 'bliz-*'` and corrected
the count to 12). The gap is that this discrepancy — `CLAUDE.md` says one thing, the real tree is another
— was surfaced only as a "delta" footnote rather than a blocker. Charters authored before the stale doc is
corrected will silently inherit the wrong map.

**Recommendation.** `adopt`'s step 2 (draft the CLAUDE.md) should explicitly include a diff gate:

1. For each claim in the adoptee's existing canonical docs that references a file path, import path, or
   directory structure, verify it against the real tree.
2. Surface every stale claim back to the adoptee with a concrete diff (what the doc says vs. what the
   real tree shows).
3. **Block charter authoring until the stale docs are corrected or the charters explicitly note the
   discrepancy.** A charter that points at a dead directory is worse than no charter.

This is the `adopt` equivalent of `cargo sqlx prepare --check` — the canonical map and the live tree must
match before any downstream artifact relies on the map.

---

## Summary of recommendations

1. **State-spine probe beyond the repo root** — ask where the live spine lives, probe `~/` and common
   locations, default to RECONCILE (add a lane) not install-fresh.
2. **Size the crew to real LOC + commit velocity** — measure per-domain, skip dormant surfaces, and
   detect + reuse existing review/deploy machinery rather than adding redundant agents.
3. **Phase adoption: scar-driven safety charters first** — money + migrations gates earn their keep at
   any build volume; the fuller crew earns its keep only when build-volume justifies it.
4. **Diff canonical docs vs. the real tree; block charter authoring on stale claims** — the ground-truth
   verification `adopt` already does should produce an explicit staleness report and gate authoring on it.
