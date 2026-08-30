---
name: diagnose-fail-closed-upgrade
description: When a kickoff pull / up / preflight / engine-hop FAILS CLOSED (a [FAIL] gate, a BLOCKED hop, a "core clone origin MISMATCH", a stray core.lock), triage it the fixed way — reproduce the gate one-shot with preflight.sh (never `up --dry-run`, which LOOPS on a pass), read the EXACT [FAIL] line (not the rc, not the turnkey's SSH guess), trace the tripping guard in scripts/ (preflight.sh · kickoff · supervisor.sh engine_hop_resolve), then split root-cause-fix (the guard) from config-fix (a stray lock / a bad pin / the remote) and verify RED→GREEN. Use when an upgrade / pull / preflight / hop won't pass and you need to know WHY and WHAT to fix.
---

# diagnose-fail-closed-upgrade — turn a fail-closed upgrade gate into a named, fixed cause

The upgrade/pull path is designed to **fail closed** — a bad pin, a stray lock, a drifted plugin cache, a
mismatched remote all stop the hop rather than run a half-upgraded engine. That safety is right, but it
means every real adopter eventually hits a gate that won't pass, and the same fixed multi-step motion gets
done **by hand** each time. It fired twice in one day (an external-core self-pin that blocked the hop; a
clone-origin guard rejecting ssh↔https of the *same* repo) and recurs across prior sessions (the
`up --dry-run` loop, the `pull` origin MISMATCH, the dogfood stray-lock, the cross-version false-failure,
the plugin-cache-drift). No existing skill covers upgrade triage (adopt/bootstrap/harden/scan/… are all
something else). This crystallizes the motion so session N+1 — and every adopter who pulls it — inherits it.

## When to use
- A `kickoff pull` / `kickoff up` / `kickoff preflight` prints a `[FAIL]`, or an **engine hop is BLOCKED**
  (the supervisor drops a `.kickoff/hop-blocked` flag and the worker keeps the OLD engine), or a pull
  refuses with a "core clone origin MISMATCH" / "core pin MISMATCH".
- Any time an upgrade won't go green and you need the **cause**, not just the symptom — before you touch
  code, and before you relay "the upgrade is stuck" to the operator.
- Skip it when there's no gate involved — a normal build/test red is the `review`/`harden` path, not this;
  this skill is specifically for the **fail-closed upgrade/pull/hop guards**.

## The motion
1. **Reproduce the gate one-shot.** Run the preflight directly so you get a clean, repeatable RED that
   *returns*: `kickoff preflight` (or `bash scripts/preflight.sh`) — full scope, one shot. For a pull/pin
   problem, `bash scripts/preflight.sh --pin` runs only the pin-integrity checks (#6 core.lock + #8
   seam/plugin-cache). **Never `kickoff up --dry-run` to reproduce** — on a PASS it hands off to the
   supervisor loop and never returns, so you learn nothing and have to kill it. The supervisor's own
   hop-blocked alert tells the operator to run `kickoff preflight` for exactly this reason.
2. **Read the EXACT [FAIL] line — not the rc, not the SSH guess.** `preflight.sh` prints each failing check
   to stderr as `  [FAIL] <reason>` (`scripts/preflight.sh` `fail()`), and that text names the tripping
   check (#1…#8). The exit code only says "something failed"; the upgrade turnkey's transport guess is often
   an **SSH misdiagnosis of a clean pin** — a post-pull false-failure trips rc=1 on a pin that is actually
   clean, and a turnkey reading only the rc reports it as a transport problem. Copy the literal
   `[FAIL]` text; that is the load-bearing signal, not the summary.
3. **Confirm the real state before you trust the message.** `Read` `.kickoff/core.lock` (the pin manifest,
   `CORE_LOCK="$KICKOFF_DIR/core.lock"`) to see what is *actually* pinned vs. what the checkout is — this is
   what tells a genuine mismatch from a false-failure. **If the failing check consulted a store
   OUTSIDE this repo — a machine-level registry like `~/.kickoff/adopters.json`, a shared cache —
   read THAT too, and verify its contents against ground truth** (e.g. compare a recorded channel
   against each repo's own `instance.env`). Read it the way `scripts/kickoff`'s `_channel_of_repo`
   does: **`cd` into that repo and pin `REPO_DIR` to it, unsetting only the one value that must not
   be inherited.** Do NOT blanket-`unset REPO_DIR` — an `instance.env` may derive its paths from
   `${REPO_DIR:-$PWD}/…` (the form `instance.env.example` teaches), so dropping it silently resolves
   *your* directory instead of theirs. That is the same cross-wire in a new direction, and it is
   worse: the wrong value is non-empty, so an `empty ⇒ MERGE` guard downstream never engages.
   A guard is only as honest as the data it reads, and shared
   state is written by OTHER repos' commands — so it can be wrong while everything here is clean.
   A stray `.kickoff/core.lock` — e.g. left by running
   `kickoff pull` inside the core checkout itself, which pins that repo to an external engine it was never
   meant to run — fails preflight closed even though nothing is wrong with the code. For a blocked hop,
   `Read` `.kickoff/hop-blocked` for the recorded reason.
4. **Trace the tripping guard in scripts/.** `Grep` the `[FAIL]` phrase to the guard that emits it:
   `grep -n '<phrase>' scripts/preflight.sh scripts/kickoff scripts/supervisor.sh`. The three homes:
   - **`scripts/preflight.sh`** — the numbered checks (#6 core.lock pin/checksum, #8 seam & plugin-cache
     drift, the session-readiness checks).
   - **`scripts/kickoff`** — front-door guards, including the clone-origin compare via `_normalize_git_remote`.
   - **`scripts/supervisor.sh`** — `engine_hop_resolve` (the engine-hop gate that sets `.kickoff/hop-blocked`).
   `Read` the guard's condition — that is what decides root-cause vs. config below.
5. **Decide root-cause-fix (the guard) vs. config-fix (the state).**
   - **Root-cause** — the guard rejects a *legitimate* state, so fix the guard at the source (never a
     tolerance shim). Real cases: the clone-origin guard did a literal `!=` on ssh↔https of the SAME repo →
     fix `_normalize_git_remote` in `scripts/kickoff` so equivalent remotes compare equal; a `plugin/`
     content change shipped without a core version bump trips preflight #8 cache-drift → fix by bumping the
     core version — a `plugin/` content change and its `plugin.json` version bump must travel together, or the pull no-ops the plugin cache and every adopter fails closed at preflight #8 (the release gate now enforces this pairing).
   - **Config-fix** — the guard is right, the *state* is stray, so fix the state and leave the code alone:
     `rm` a stray `.kickoff/core.lock`; **unpin** a self-pin to an unsatisfiable external core (`rm`
     `.kickoff/core.lock` + the `KICKOFF_CORE_DIR` line, clear the stale `.kickoff/hop-blocked`); normalize
     or re-point a genuinely wrong remote.
   - **Data-fix** — the guard is right AND this repo's state is right, but the **data the guard read**
     is poisoned. Real case (2026-08-07): preflight #2's clash check reads `~/.kickoff/adopters.json`;
     `cmd_pull` had registered the adopter's channel from the AMBIENT `$TELEGRAM_STATE_DIR`, so one
     fleet sweep run from inside a worker stamped the CALLER's channel onto three orgs' rows — and a
     later, perfectly clean preflight fail-closed on a phantom clash. Repair the DATA (re-register the
     rows from each repo's own `instance.env`, backup first) to unblock now, and fix the WRITER
     separately — they are two changes with two different blast radii. Note the asymmetry: a poisoned
     row equally SUPPRESSES a real clash, so this class yields false greens as well as false reds.
     Two traps here: (a) never "fix" it by loosening the guard — prove the guard still fires by
     feeding it a genuinely-bad fixture (a negative control) after the data repair; (b) never hotfix
     the pinned `kickoff-versions/core-v*` checkout — preflight #6 requires a CLEAN git tree, so
     patching it in place fail-closes every org on that pin. The code fix goes in the source repo and
     reaches orgs only when a core ships.
   The `core.lock` read in step 3 is what tells you which side you're on — and when it is CLEAN and the
   guard is CORRECT, suspect the data before you suspect the guard. Do not guess.
6. **Verify RED→GREEN.** For a **root-cause guard fix**, write or extend a RED-first selftest that fails on
   the OLD guard and passes on the fixed one (pattern: `scripts/remote-normalize-selftest.sh`, added
   RED-first for the origin-normalize fix) — watch it go RED on the broken input *first*, then GREEN; a check
   you never saw fail proves nothing. For a **config-fix**, re-run `kickoff preflight` and confirm the exact
   `[FAIL]` from step 2 is gone. Either way, the proof is the same gate now returning GREEN.
7. **Checkpoint.** Commit the fix (+ the selftest) with a clear message, `TRACKER.md` folded in, and push —
   green gates make it reversible. A guard fix lives adopter-local under `scripts/` / `.claude/skills/` so
   adopters inherit it on their next pull. Nothing in this motion spends or destroys (a lock `rm` and a pin
   edit are reversible), so no human gate is needed — but say so plainly rather than assuming.

## Pitfalls
- **`kickoff up --dry-run` LOOPS on a pass** — it never returns, so it is useless as a reproducer. Use
  `kickoff preflight` / `bash scripts/preflight.sh` for the one-shot RED.
- **Trusting the rc or the turnkey's SSH guess over the `[FAIL]` line.** The exit code is binary and the
  transport story is a frequent misdiagnosis of a clean pin — read the literal `[FAIL]` text and `core.lock`,
  not the summary or the alert's guess.
- **Patching the symptom with a tolerance shim** (making a legitimately-rejecting guard pass by loosening it
  blindly) **or, conversely, hacking the guard when the state is actually stray.** Split root-cause vs.
  config deliberately — the `core.lock` read is the arbiter.
- **Diagnosing against a stale base.** A worktree/background worker branches off ~session-start, so a
  fail-closed on a *just-pulled* core must be traced against LIVE HEAD and the actual `.kickoff/` state, not
  the worker's snapshot — diagnose on the main checkout.
- Honest-stage: if you can't reproduce the `[FAIL]` one-shot, say "couldn't reproduce — here's the state I
  see" and hand it back; never dress a guessed cause as the found one.

## Verification checklist
- [ ] The gate was reproduced **one-shot** (`kickoff preflight` / `bash scripts/preflight.sh`), and the
      exact `[FAIL]` line was captured — not inferred from the rc or the SSH guess.
- [ ] `.kickoff/core.lock` (and `.kickoff/hop-blocked` for a hop) was read to confirm the real pin state.
- [ ] The tripping guard was located in `scripts/` (a real `grep` hit in `preflight.sh` / `kickoff` /
      `supervisor.sh`), and the root-cause-vs-config call was named explicitly.
- [ ] For a guard fix: a RED-first selftest was **watched go RED** on the old behaviour, then GREEN on the
      fix (pattern: `scripts/remote-normalize-selftest.sh`).
- [ ] Re-running `kickoff preflight` is now GREEN — the captured `[FAIL]` is gone — and `core.lock` reflects
      the intended pin.
- [ ] Committed + pushed; confirmed nothing touched spend or destruction (a lock `rm` / pin edit is
      reversible), so no human gate was required.
