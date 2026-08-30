---
name: bootstrap
description: Take a greenfield idea to a built, tested, running first slice. Propose a tech stack (don't assume one), scaffold it FRESH with the real CLIs, wire one proof test, run it. Use when the human asks to spin up / start / bootstrap a new project or service.
---

# bootstrap — idea → running first slice

You are the **coordinator** running the bootstrap motion — you **orchestrate** it by dispatching the
engineer specialists; **you do not build it inline.** Goal: turn a one-line idea into a
**built, tested, running first slice** the human can react to — fast, and from a *fresh scaffold*,
not a frozen template. Templates rot; reasoning about the right stack and scaffolding it live is the
L2 move. The coordinator *routing* the build to a `builder` (not doing it itself) **is** the point —
building it inline defeats the whole thesis.

## The motion

1. **Read the idea.** Pin the smallest first slice that proves it works (one endpoint, one screen, one
   command). Cut everything else — gold-plating is the enemy of a fast first green.

2. **Propose the stack — don't assume one.** Offer **2–3 options** with a one-line tradeoff each, and a
   recommendation. Bias the recommendation toward a **fast first green**: minimal deps, a scaffolding CLI
   that exists, a test runner that's quick. Examples (not a fixed menu — reason from the idea):
   - tiny HTTP API → Node + `node:http`/Hono + Vitest, or Bun.
   - web app → Vite + React, or Next.js.
   - CLI → Node + Vitest, or Python + pytest.
   - Rust service → cargo + axum (**warn: slow compile**, see below).
   Wait for the human's pick (one word). If they don't care, take your recommendation and say so.

3. **Delegate the build to the `builder`.** Dispatch the **`builder` subagent** (the Task/Agent tool) with a
   tight task: scaffold FRESH with the real CLI (`npm create vite@latest`, `cargo new`, `npm init`,
   `bun init`, `uv init`, …) into a **NEW project dir OUTSIDE the kickoff checkout** (bootstrap is
   *create-then-adopt* — you scaffold a standalone project, then wire kickoff into it in step 5; never
   scaffold *into* the kickoff repo) → implement the smallest first slice → wire ONE proof test → run it →
   report the real result + the exact run command. Hand it the chosen stack, the slice, and
   your stated assumptions. For a larger brief, dispatch the **`planner`** first for the build plan, then one
   or more `builder`s on independent parts. **You do not scaffold or write the code yourself** — you route it
   and narrate the orchestration. (No frozen template — the builder generates current scaffolding; keep deps lean.)

4. **Verify via the `reviewer`.** Dispatch the **`reviewer`** to run it itself and confirm green — or for a
   trivial slice, at minimum confirm the `builder` pasted a *real, green* result with the run command.
   **Never accept "done" on an unrun build.** For a **UI**, "green" also means it clears the **Design-quality
   bar** (`CLAUDE.md`): render it, *look*, and refine for restraint / balance / polish — *working but generic
   is not done*. Reach for a `frontend-design` skill if one's available.

5. **Adopt the kickoff engine + install the project's plugins** (once there's a first green to protect — see
   the section below). `kickoff adopt` wires the local quality machinery (scanner shims + gates +
   scan/review/harden) that makes the build *safe*, not just working — bootstrap is **create-then-adopt**.
   And invoke the **`plugins` skill** to install the handpicked plugins the stack needs (DB / mobile / deploy
   / payments) — the operator never picks; you do, by what the project is.

6. **Checkpoint + relay.** Once it's green *and the gates pass*, commit the slice as a checkpoint (clear
   message + `TRACKER.md` update — see `CLAUDE.md`) **and push it** — commit and push are reversible and
   backed by the green gates (the trust boundary is spend + destruction, not the push). Then report concisely.
   The human steers with one sentence; you re-dispatch the `builder` with the prior output as context — refine,
   don't restart.

## Adopt the kickoff engine (after the first green)

A fresh project gains the **local quality machinery** (`CLAUDE.md` → "The local quality machinery") by
**adopting the kickoff engine** — bootstrap is *create-then-adopt*: you scaffolded a standalone project OUTSIDE
the kickoff checkout, now you wire kickoff into it. kickoff is language-agnostic, so the machinery ships as a
*pattern* and **you fill the stack-specific commands** — you just chose the stack, so you know them. Do this
once, right after the first green:

1. **Make the project a git repo with a baseline.** `git init` in the project dir and commit the green first
   slice (`git add -A && git commit -m "baseline: first green slice"`). `kickoff adopt` records what it touches
   against this baseline, so the checkpoint has to exist first.
2. **Adopt.** Run `bash <kickoff>/scripts/kickoff adopt --dir <project> --accept` (where `<kickoff>` is the
   kickoff source clone). `--accept` is required here: the v0.7 §4 consent gate refuses a silent
   non-interactive adopt (your Bash tool has no tty), and in bootstrap the operator's approval of the brief
   *is* the consent — the repo was just created by this system, so no separate dry-run pitch is needed.
   This delivers, into the project — every touch recorded so it's fully reversible via
   `kickoff eject`:
   - the scanner shims `.kickoff/bin/scan-secrets`, `.kickoff/bin/scan-structure`, `.kickoff/bin/mc`;
   - the `.kickoff/.gitignore` (keeps `instance.env` + derived state out of git; tracks the seams);
   - the charter block — a `@.kickoff/KICKOFF.md` @import appended to the project `CLAUDE.md` + a
     `.kickoff/KICKOFF.local.md` stub;
   - the `core.lock` engine pin, the blank state seeds (`.kickoff/memory/MEMORY.md`,
     `.kickoff/state/mission-control/mission-state.json`), the registry row + stamped `instance.env`, the plugin.

   Do **NOT** copy `scripts/scan-*.sh` or `lefthook.yml` out of the clone by hand — adopt wires the scanners as
   the `.kickoff/bin/scan-*` shims. (The lefthook gate file `.kickoff/lefthook-kickoff.yml` is authored in the
   `/adopt` session — step 4 below — *not* by `kickoff adopt`.)
3. **Decide your stack's gates — the `/adopt` session authors them (step 4).** The `/adopt` session writes
   `.kickoff/lefthook-kickoff.yml` with the generic `secret-scan` (pre-commit → `bash .kickoff/bin/scan-secrets
   --staged`) and `structure-scan` (pre-push → `bash .kickoff/bin/scan-structure`) via the shims, plus a root
   `lefthook.yml` that `extends: [.kickoff/lefthook-kickoff.yml]`, and records both. Decide the stack's
   `typecheck` / `lint` (pre-commit) and `test` (pre-push) commands now, so you can fill them there — you chose
   the stack, so you know them. Common fills:

   | Stack | typecheck | lint | test |
   |---|---|---|---|
   | TS / Node | `npx tsc --noEmit` | `npx biome check .` (or eslint) | `npx vitest run` (or `npm test`) |
   | Rust | `cargo check` | `cargo clippy -- -D warnings` | `cargo test` |
   | Python | `mypy .` (if typed) | `ruff check .` | `pytest -q` |
   | Go | `go vet ./...` | `golangci-lint run` | `go test ./...` |

   Drop a gate the stack doesn't have (no typecheck for plain JS) rather than faking one. Keep pre-commit cheap.
4. **Author content + activate the hooks in a `/adopt` session.** Open a Claude Code session in the project and
   run `/adopt` — it authors the CLAUDE.md content / crew / tracker / memory (recording every touch
   seeded-instance), and runs `lefthook install`. Install the `lefthook` binary as fits the stack
   (`npm i -D lefthook` for Node; `brew install lefthook` / a binary release otherwise). Confirm by running the
   gates once (`lefthook run pre-commit`) and pasting the real result.

**Upgrades:** the new project upgrades its pinned engine via `kickoff pull` (it re-pins `core.lock` and
regenerates the seams). A *kickoff source checkout* upgrades via `git pull` instead — `kickoff pull` refuses
that shape (it's engine-prep for a source clone, not an adopter).

Honest note: installing the lefthook binary is the one new dependency — name it, don't assume it's there. If
it can't be installed in the environment, fall back to running the scanners (`bash .kickoff/bin/scan-secrets`,
`bash .kickoff/bin/scan-structure`) + gate commands directly before each checkpoint and say so.

## Keep the back-and-forth minimal

A simple idea-brief is the goal — so **bias to BUILD with stated assumptions, not to interrogate.** For
anything the brief left open (data model, exact fields, edge cases), pick the sensible default, **state it in
one line, and build** — the human steers *after* seeing a working thing, not through a pre-build Q&A. Cap it at
**one round-trip**: the stack pick (and if that's obvious, just pick, say so, and go). If you're about to ask a
*second* clarifying question, you're over-asking — make the call, note your assumption, and show working code instead.

## Speed + the watchdog (be honest about this)

- A background worker dies after ~**600s of no output**. Long installs / compiles can hit this. Keep the
  first slice tiny, the dep set minimal, and prefer fast toolchains for the *first* green.
- **Rust especially**: `cargo build` is slow cold. If the human wants Rust, warn that the first compile
  takes a while, pre-`cargo build` once to warm it, and keep the slice minimal.
- If an install looks slow, say so and show progress — don't go silent.

## Boundaries

Scaffold, build, test, run, **commit, and push** — all reversible and backed by the green local gates, so do
them autonomously. **Do NOT** spend (a paid deploy / hosting tier / metered API / infra / a domain), touch
credentials or secrets, or do anything destructive (wipe a DB, delete data) without explicit human approval
(see the `deployer` agent for the gated ship step). The first slice runs **locally**; going live is a
separate, human-approved step. The trust boundary is **spend + destruction, not the push** (`CLAUDE.md`).

## Honest-stage

This skill scaffolds fresh, so results vary with the model + the CLIs available. Report what actually
happened — the real test output, the real timing. If a CLI isn't installed or a step fails, say so plainly
and propose the fix; don't paper over it.
