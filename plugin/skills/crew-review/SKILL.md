---
name: crew-review
description: The adversarial review turned on the CREW itself — hold each agent charter, skill, CLAUDE.md principle, and memory against RECENT OUTCOMES, find where the crew config would let a known failure recur, and close the gap. Auto-apply the ungated fixes (a stale/contradictory memory); stage the gated ones (charter/CLAUDE.md edits) as a one-tap turnkey. Fire at natural boundaries + on demand. Velocity-first triage by default.
---

# crew-review — adversarial review, turned on the crew itself

Every other quality skill audits the **product**: `scan` finds footguns, `review` breaks a diff,
`harden` closes the gaps. **Nothing audits the crew** — the charters, skills, CLAUDE.md principles,
and memory that *produce* the work. So the crew is frozen at clone-time while the work evolves past
it, and a charter can quietly contradict a corrected principle (observed: a `MEMORY.md` index line
still said "no pty" long after the fact body was corrected to "a pty IS required").

This closes that loop. It's the system's own **"build the builder, then keep the builder honest"**:
hold each agent + skill + principle against what actually happened recently, find what's stale /
missing / contradicting, and **fix it** — auto-applying what's safe, staging what's gated.

**Why this is what makes autonomous crew-evolution trustworthy:** the confidence to update the crew
without a human reading every line comes from the **adversarial check** (a separate agent briefed to
*break* the crew config), not from optimism. The human stays the cheap final gate on crew mutations —
one tap on a pre-vetted turnkey — because a bad autonomous charter edit silently degrades *every*
future build (a one-way door). The system does the toil; the human clicks apply.

## When to fire

- **At natural boundaries** — a milestone, a refresh, ~every N sessions: a **light triage**. Does any
  charter contradict a principle? Did a recent miss slip a gap a charter should have caught? Close the
  obvious, list the rest. If the crew's clean, say so in a line and move on (velocity-first). **This
  boundary triage is now AUTOMATED:** `scripts/crew-review-due.sh` fires it on a cadence
  (`CREW_REVIEW_CADENCE_DAYS`, default 7) — the coordinator runs it at re-ground when DUE, then `--mark`
  (see CLAUDE.md "Context discipline"). It still fires only at a natural boundary, never mid-urgent-task.
- **On demand** — "crew-review" / "is the crew still sharp?": the **deep adversarial pass**.
- **Signal-triggered** (the CLAUDE.md "Evolving the system" signals): a domain recurring with no owner
  → propose an agent; a correction you keep re-making → bake it into the charter; a **reusable procedure
  the crew keeps re-doing by hand → distill it into a native skill** (§"Distill a recurring procedure
  into a skill"); a task too big for the crew → propose a split.

## The motion

1. **Gather — the crew + the outcomes.** The config: `.claude/agents/*.md` (charters),
   `.claude/skills/`, CLAUDE.md's principle sections, `.claude/agent-charter-template.md`, and the
   `memory/` corpus. The outcomes: `TRACKER.md` history, recent commits, and the
   operator-correction / near-miss memories written **since the last crew-review**. Bound it to the
   recent delta — not all history.

2. **Hold each agent + skill against (a) the principles and (b) the outcomes.** Three questions per
   agent: *Did this charter cause, or fail to prevent, a recent miss? Does any charter/memory now
   contradict a principle (the stale-pty case)? Does a recent miss prove a charter is missing a
   principle it needs (e.g. "render it and look" absent from the builder + reviewer charters)?*

3. **Adversarial pass — this is where the confidence comes from.** Brief a SEPARATE agent (strongest
   model, **read-only**) to *BREAK the crew config*: "find where a charter, skill, or memory would let
   a known failure recur." Same discipline as `review` / the `*-adversarial-review` workflows, but the
   target is `.claude/` + `memory/`, not a product diff. Reuse that machinery; don't rebuild it.

4. **Verify every finding against the real config + a real outcome.** Tie each to an actual charter
   line AND an actual miss/principle — not a vibe. A finding you can't ground in both is not a finding
   (the [[verify-load-bearing-claims-before-acting]] discipline, applied to the crew). Triage real vs.
   noise; rank by how badly the gap bites a future build.

5. **Close the gap — split by gate.** This split is what delivers "autonomous with confidence":
   - **Ungated → auto-apply.** A stale/contradictory `MEMORY.md` line, a wrong fact, a memory that
     duplicates another. Memory is *data, not config* — fix it directly, then re-checkpoint. (This is
     the part the crew-review ships on its own.)
   - **Gated crew-mutation → stage as a one-tap turnkey.** A charter / CLAUDE.md / template edit (add a
     missing principle, fix a contradicting one). Editing the crew's own config is a gated
     self-modification ([[agent-config-edits-are-gated-self-modification]]) — do NOT apply it with
     Write/Edit (or a Bash workaround). Package it as an idempotent, reversible `scripts/wire-*.sh`
     (the pattern of `wire-canon-into-charters.sh`); the human running it IS the approval.
   - **New capability → propose or distill.** A domain with no owner → a new agent charter authored
     from `.claude/agent-charter-template.md`; a **reusable procedure the crew keeps re-doing by hand →
     a new skill** authored from `.claude/skill-template.md` (§"Distill a recurring procedure into a
     skill" for the threshold + dedupe + gate); a task too big → a split. Author on the human's yes
     (CLAUDE.md "Evolving the system — orchestrator-authored, human-approved").

6. **Staged report.** Rank the stale / missing / contradicting items + the fixes: what was
   **auto-applied** (the ungated ones), what's **staged as a turnkey** (the gated ones), what's
   **proposed** (new capabilities). Route to the human as a one-line decision: *"crew-review: fixed N
   stale memories, staged M charter wirings as `wire-*.sh`, propose K — run the turnkey?"*

## Distill a recurring procedure into a skill (the skill-CREATION branch)

The third system-evolution move, alongside propose-an-agent and bake-into-a-charter: when the crew keeps
re-doing the SAME multi-step procedure by hand, crystallize it into a native `.claude/skills/<name>/SKILL.md`
so the builder **accretes capability** instead of re-deriving it. This is the creation half of a
self-improving loop; **recall is already free** — Claude Code auto-lists any `SKILL.md` by its
`description` and invokes it via the Skill tool, so there is nothing to build for retrieval (no hook, no
index, no learning graph). The only new work is the gated author-trigger below.

**Threshold — crystallize only what clears all three (under-use beats clutter):**
- **RECURRING** — the procedure was observed ~2–3+ times across sessions, never distilled from a single
  session. One occurrence is not a pattern.
- **GENERALIZABLE** — it's a reusable motion, not a one-off specific to a single task, repo, or day.
- **NOT ALREADY COVERED** — dedupe against `.claude/skills/` (crew-review already ingests it) and the
  charters. **Refuse-on-overlap:** if an existing skill or charter section already owns the motion,
  extend or point to it — do NOT author a near-duplicate. If nothing clears the bar, produce nothing:
  **low volume is the correct outcome**, and the dominant risk here is UNDER-use, not over-accretion.

**Draft NATIVE, from the template.** Author the candidate from `.claude/skill-template.md`. Every tool
reference must be native to this substrate — `Bash / Task / Grep / Glob / Read / Write / Edit / Skill` —
never a foreign agent's tool names or paths (no `terminal` / `delegate_task` / `search_files` /
`skill_manage` / `~/.hermes/...`). Byte-0 `---` frontmatter with exactly `name` + `description`;
front-load the description's trigger words (that string is the whole recall surface).

**Gate the write behind the human.** A new `.claude/skills/` file is a procedure the whole crew will
auto-load and obey — a behavior mutation and a supply-chain surface — so it lands behind the same human
gate as a charter/CLAUDE.md edit ([[agent-config-edits-are-gated-self-modification]]), NOT a silent
auto-write. Stage it as a one-tap turnkey (a `scripts/wire-*.sh` that writes the vetted `SKILL.md`, the
`wire-canon-into-charters.sh` pattern), or present the draft and land it on the human's explicit accept.
**Never a Stop/SessionEnd hook** — a hook that silently writes a skill breaks the fail-open /
never-self-mutate posture every kickoff hook holds.

**Land adopter-local.** Accepted skills go in `.claude/skills/<name>/SKILL.md` (mirroring how agents
accrete to `.claude/agents/`) — NOT the version-pinned `plugin/skills/` release channel, which is the
maintainer's. A proven local skill graduates upstream later via the cross-org contribution loop.

**The gardener half — prune / consolidate (charters + skills).** The curation counterpart to creation:
when the crew ACCRETES config, curate it. This runs as part of the automatic cadence triage (a `DUE`
`crew-review-due.sh` at re-ground) and covers BOTH `.claude/skills/` AND `.claude/agents/*.md` charters:
- **Flag near-duplicates** — two skills (or two charters) whose descriptions / domains overlap. Propose a
  merge, naming which absorbs which.
- **Flag structural staleness** — a skill/charter that cites a file, script, command, or flag that no
  longer exists (grep the cited identifiers — a dangling reference is the signal), or a charter whose
  domain the crew no longer does.
- **Tripwire** — when `.claude/skills/` passes **~15–20** (baseline: 12), or duplicates/staleness show,
  escalate from flagging to an active consolidation pass.
- **Charters** — crew-review already holds each charter against the principles + recent misses (that IS
  charter curation); the gardener adds the dedupe + structural-staleness sweep on top.

**Gate it — flag + propose, NEVER auto-remove.** Pruning or merging a skill/charter is a behavior mutation
(and a supply-chain change), so it lands behind the same human gate as any crew-config edit: the gardener
proposes prune/merge as a one-tap turnkey (backup + reversible), or presents the case and acts on the
human's accept — it never deletes or rewrites a skill/charter on its own. Only stale-**memory** DATA
auto-applies ([[agent-config-edits-are-gated-self-modification]]).

**Honest limit — no usage telemetry.** A true "prune the UNUSED" needs per-skill/charter invocation
counts, which this substrate does not collect. So the gardener is **flag-and-propose on OVERLAP +
STRUCTURAL staleness**, not usage-based auto-removal. If nothing clears the bar, produce nothing —
under-use beats clutter, and a wrongly-pruned skill/charter is a one-way door.

## Velocity-first (don't let it become the thing that catches you)

A boundary crew-review is a **light triage** — any contradiction? any recent-miss-left-uncovered? —
not a full audit. Reserve the deep adversarial pass for "crew-review" on demand or a meaningful
crew-evolution moment. If it's clean, one line and move on. If reviewing the crew is eating the
session, you're over-running it — dial back to triage.

## Honest-stage

The adversarial check gives **confidence, not a guarantee** — report what was auto-fixed, what's
staged for the human, and what's proposed, plainly. "Fixed 1 stale memory, staged the render-and-look
charter wiring as a turnkey, propose a comms agent — your tap" beats "crew is all clean." A
crew-review that rubber-stamps a drifting crew is worse than none — the same bar `review` holds for a
product diff, turned inward.
