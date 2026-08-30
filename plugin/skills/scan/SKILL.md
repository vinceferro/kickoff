---
name: scan
description: Run the generic footgun scanners (secrets + structural) over the repo and return a ranked findings list. Language-agnostic, no deps. Use at session-start (as part of harden), before a checkpoint, and on demand to answer "is anything unsafe or fragile in here?".
---

# scan — find the footguns a non-technical operator can't

A thin runner over the two shipped scanners (`scripts/scan-secrets.sh` + `scripts/scan-structure.sh`).
They are **generic and language-agnostic** (git + grep + coreutils, no dependencies), so they work the
moment a repo exists — that's the point: the secret/structural footguns are the same shapes in every stack,
so they don't wait on `bootstrap`/`adopt` to wire a toolchain.

## The motion

1. **Run both scanners** from the repo root — via the seam shims (adopted repo). In a
   kickoff-native project (bootstrap/greenfield, repo IS the core) the shims do not exist;
   use `bash scripts/scan-secrets.sh` / `bash scripts/scan-structure.sh` there. A bare
   `scripts/…` path on an ADOPTER resolves into that project's own `scripts/` (or nothing)
   and never reaches the engine — verified on a live adopter:
   - `.kickoff/bin/scan-secrets` — leaked credentials. **A finding is a hard stop** (exit 1): a committed
     `.env`, a private key, a cloud/vendor token, a hardcoded credential literal, or a server-only service-role
     key referenced from client code. The output redacts the secret value (never echo a secret into a log).
   - `.kickoff/bin/scan-structure` — structural footguns (advisory): oversized files, DELETE/UPDATE without
     a WHERE, broad RLS/`GRANT ALL`, a React app with no ErrorBoundary, promise chains with no `.catch`,
     engine-fragile CSS. This feeds `harden`; it does not block on its own.
   - Scope flags: `--staged` (only staged files, used by the pre-commit hook), `--strict` (structural scan
     exits non-zero on a HIGH finding — use when you want it as a gate, not advice).

2. **If the scanners aren't present** (a brownfield repo before `adopt` installed the machinery), say so and
   offer to run `adopt` / drop them in — don't silently report "clean".

3. **Rank + report.** The scanners already rank by severity (CRITICAL → HIGH → MEDIUM → LOW). Relay the
   ranked list concisely. Don't dump raw output if it's long — summarise counts by severity + the top items.

4. **Hand off.** Secret findings → fix now (remove, rotate, move to env-loaded config) before anything else.
   Structural findings → hand the list to the **`harden`** skill, which decides real-vs-false-positive and
   closes the real ones. A genuine false positive gets a `pragma: allowlist secret` line marker or a path in
   `.scanignore` — with a one-line reason, never to silence a real finding.

## Honest-stage

These are **heuristic** scanners tuned for low noise and velocity, not a security product — they catch the
footguns we've actually seen bite a build, not every possible one. A clean scan means "none of the known
footguns," not "provably safe." For security/money/irreversible paths, pair it with the `review` skill (an
adversarial agent briefed to break it) — the scanner finds shapes, the reviewer finds reasoning bugs.
