---
name: harden
description: The agent CLOSES the structural issues a non-technical operator can't — runs the scanners + reads the gate/review status, fixes the real footguns (and leaked secrets) behind the review gate, and checkpoints. Fire at session-start as a health check, and on demand. Velocity-first: session-start is a quick triage, not a refactor marathon.
---

# harden — close the gaps a non-technical operator can't

This is the answer to the follow-through gap. A scanner *finds* a data-loss write, a broad grant, a leaked
key, a missing ErrorBoundary — but a non-technical operator **can't close any of them.** `harden` is where
the agent does: it reads the footgun list and the gate/review status, and **fixes the real issues locally,
behind the review gate, then checkpoints.** Working code → *safe* working code.

## When to fire

- **At session-start** — a quick **health check**: run `scan`, glance at gate status, close anything cheap and
  unambiguous, surface the rest. This is triage, **not** a refactor marathon — keep it light so it doesn't eat
  the session (velocity-first). If it's clean, say so in a line and move on.
- **On demand** — "harden this" / before a meaningful ship → the deeper pass: work the full findings list down.
- **After `adopt`** — the initial hardening pass on a freshly-onboarded repo (its first real cleanup).

## The motion

1. **Scan.** Run the `scan` skill (`scripts/scan-secrets.sh` + `scripts/scan-structure.sh`). Get the ranked list.

2. **Check the gate status.** Are the `lefthook` hooks installed and green? Run the project's gate commands
   (typecheck · lint · tests) or `lefthook run pre-commit` / `lefthook run pre-push`. A red gate is a finding too.

3. **Triage — real vs. false positive.** These are heuristic scanners; not every hit is a bug. Read each
   finding against the code. A genuine false positive gets an allowlist marker (`pragma: allowlist secret`) or
   a `.scanignore` path **with a one-line reason** — never to silence a real one. Rank what's left by severity.

4. **Close the real ones.** By class:
   - **Leaked secret** (hard stop): remove it from the code, move the value to env-loaded config, gitignore the
     `.env`, and **purge it from history if it was committed.** The credential is now burned — so the *rotation
     of the live key* is a human action (it's a credential op): hand it over turnkey ("this key leaked — rotate
     it in <vendor>, here's where"). Removing it from the tree is yours; rotating the live secret is theirs.
   - **Data-loss write** — add the `WHERE` / scope the write to the row; make a full-overwrite update a merge.
   - **Broad grant** (RLS `USING(true)` / `GRANT ALL`) — scope it to the owner/row; least privilege.
   - **Missing ErrorBoundary** — add one at the app boundary so a thrown render doesn't blank the screen.
   - **Unhandled promise** — add the `.catch` / error path.
   - **Oversized file** — split it along its real seams (behaviour-preserving; refactor and behaviour-change
     stay separate steps).
   - **Engine-fragile CSS** — add the prefix / a fallback; flag "confirm on the real device" (render ≠ device).

5. **Fix behind the review gate.** A hardening fix can introduce its own edge — so a non-trivial fix goes
   through the **`review`** skill (sized to the fix). Re-run the gates; confirm green.

6. **Checkpoint.** Commit the hardening with a clear message, `TRACKER.md` folded in. Per the trust boundary,
   commit *and push* freely — fixes backed by green gates are reversible. **Stop and ask only at the
   irreducible:** rotating a live credential, a destructive data fix on real/prod data, anything that spends.

## Velocity-first (don't let it become the thing that catches you)

Session-start `harden` is a **30-second triage**, not a deep clean — close the obvious, list the rest, keep
moving. Reserve the deep pass for "harden this" or a pre-ship. If hardening is blocking the build more than
protecting it, you're over-running it — dial it back to triage.

## Honest-stage

`harden` closes the **known** footguns; it is not a security audit or a guarantee. Report what you fixed, what
you deferred and why, and what needs the human (a live-key rotation, a destructive data fix). "Hardened the
real findings; 2 deferred (noted in TRACKER); 1 needs you — rotate the leaked key" beats "all clean."
