---
name: review
description: Adversarial review of a diff run on LOCAL compute — fan out independent reviewers briefed to BREAK the change, verify each finding against the code, fix the confirmed ones, light re-review on the fix. Sized to the diff (trivial → skip; substantial / security / money / irreversible → run). Use before a substantial commit.
---

# review — adversarial review, run locally

The single most valuable quality move we learned on a real build: **a separate agent, briefed to break the
change — not approve it — catches what the builder can't.** A reviewer on the same reasoning path as the
builder rubber-stamps; an adversarial one on a fresh path finds the real bugs. This skill runs that pattern
on **local compute** — the harness spawns the reviewers, no hosted CI or service needed.

## First: size it to the diff (velocity-first)

Quality is a fast safety net, not bureaucracy. **Decide the depth before you spend agents:**

- **Trivial / mechanical** (a copy tweak, a one-line fix, a rename, a doc edit) → **skip.** A self-check is enough.
- **Substantial, OR touches security / money / auth / data / anything irreversible** → **run the full pass.**
- **In between** → one reviewer, one dimension (correctness), not the full fan-out.

If you're unsure which, look at the diff: `git diff` (unstaged), `git diff --staged`, or `git diff <base>..HEAD`.
Bigger blast radius → deeper review. Don't run a 5-agent panel on a typo; don't skip review on an auth change.

## The motion (for a full pass)

1. **Scope the diff.** Pin exactly what changed (`git diff …`) — the reviewers review *the change*, with the
   surrounding code as context, not the whole repo.

2. **Fan out independent reviewers — briefed to BREAK it.** Dispatch a small panel of `reviewer` subagents
   (the `reviewer` agent is read + run only — least privilege, so it can't "helpfully" fix what it finds and
   hide the signal). One dimension each; run them in parallel:
   - **correctness** — does it do what the brief asked? edge cases, off-by-ones, wrong assumptions, a test
     that passes trivially.
   - **security / data-safety** — leaked secrets, injection, broad grants, auth bypass, a full-overwrite
     write, PII in the wrong place. (Pair with the `scan` skill — scanner finds shapes, reviewer finds reasoning.)
   - **regressions / blast radius** — what else calls this? shared component / hot path? does the change ripple?
   Brief each one explicitly: *"Your job is to break this, not to bless it. Assume it's wrong and prove how."*

3. **Adversarially verify every finding — refute by default.** A plausible finding is not a real one. For each
   reported issue, **check it against the actual code** (read the lines, run the case) before believing it.
   Default to "refuted / not a real bug" unless the code confirms it. This is what stops confident-but-wrong
   findings from driving wasted fixes (an alarming claim suppresses the check — verify the underlying fact).

4. **Fix the confirmed findings.** Hand them to the `builder` (or fix inline for a small one). Real bugs only —
   don't bikeshed style the formatter owns.

5. **Light re-review on the fix diff.** A fix can introduce its own edge (observed, not hypothetical) — so do
   one **targeted** re-review on just the fix, not a full re-run. Stop once a fix is a direct port of
   already-proven code. Knowing when to stop matters as much as when to review.

6. **Converge + report.** Report the confirmed findings, what was fixed, and the dismissed false-positives
   (so the human sees the review had teeth). Then the change is clear to checkpoint.

## Local-compute reality (honest)

- The box is the ceiling, not the model. **Check load before fanning out** (`uptime`); keep the panel small
  (2–3 reviewers); don't stack it on top of a heavy build. A background worker dies after ~600s of silence.
- Size the panel to the risk, not to look thorough — three focused reviewers beat ten redundant ones.
- If a richer multi-agent orchestration tool is available in your harness, it can run the fan-out + verify;
  the portable path here is dispatching `reviewer` subagents directly.

## Why local + adversarial (not a hosted gate)

Hosted CI runs the *deterministic* gates (`lefthook` does that locally here). This skill runs the
*judgment* gate — the part that needs a reasoning agent — on the same box, no dependency on a hosted service.
That's the whole CI-less model: deterministic gates in the hooks, adversarial judgment in this skill, both local.
