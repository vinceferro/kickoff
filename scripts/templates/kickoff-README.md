<!-- kickoff:README — GENERATED SEAM (DO NOT EDIT). Regenerated from the pinned core tag on
     `kickoff pull`; hand-edits are REFUSED by seam-sync and flagged by preflight #8. It is
     machine-path-free, so every adopter's copy is byte-identical (a stable, pinned hash). -->

# `.kickoff/` — the kickoff engine seam

This directory is the **seam** between THIS repo and the kickoff engine. The engine itself is
NOT here — it lives in a separate, tag-pinned, read-only clone (`KICKOFF_CORE_DIR`). `.kickoff/`
holds only what belongs to this repo: the charter, the shims that reach the engine, this repo's
config, and derived runtime state. It is created by `kickoff adopt`, maintained by `kickoff pull`,
and removed cleanly by `kickoff eject`. Every generated file is recorded in `adopt-manifest.json`
so eject can reverse it byte-for-byte.

## What's in here

- **`KICKOFF.md`** — the coordinator charter, pulled from the core (a SEAM — regenerated on pull,
  do not edit). It `@import`s `KICKOFF.local.md`.
- **`KICKOFF.local.md`** — THIS repo's overrides: domains, specialists, operator style, guardrails.
  Adopter-owned — `kickoff pull` never regenerates it, and eject keeps it by default. Edit this.
- **`bin/`** — the shims that invoke the pinned engine (`mc`, `scan-secrets`, `scan-structure`).
  Always call the engine through these, never a bare `mission-control/…` path (absent in an adopter).
- **`memory/`** — the durable, team-shareable memory corpus (facts + the `MEMORY.md` index).
- **`instance.env`** — this instance's private config (the core clone location, channel + state
  paths). Instance-private, gitignored — never committed.
- **`adopt-manifest.json`** — the receipt of every file kickoff touched (what eject reverses,
  what preflight verifies). Instance-private, gitignored.
- **`core.lock`** — the pin: the exact core tag + commit this repo runs against. Gitignored.
- **`state/`** — derived runtime (mission-control board, memory index, logs, locks). Gitignored.

## Tracked vs. ignored

`.kickoff/.gitignore` keeps the instance-private bits (`instance.env`, `adopt-manifest.json`,
`core.lock`, `state/`, locks) out of origin, while the team-shareable seams stay **tracked**:
`KICKOFF.md`, `KICKOFF.local.md`, `bin/`, `memory/`, and this README. Commit those; ignore the rest.

## Managing it

- **`kickoff pull`** — pin/upgrade the engine to a reviewed core tag; regenerates the seams here.
- **`kickoff status`** — read-only health: adoption, the core pin, the registry, the plugin.
- **`kickoff eject`** — cleanly de-integrate: reverses every recorded touch and removes `.kickoff/`.

Don't hand-edit the generated seams (`KICKOFF.md`, `bin/`, `.gitignore`, this README) — a pull
refuses a drifted seam and preflight flags it. Put everything repo-specific in `KICKOFF.local.md`.
