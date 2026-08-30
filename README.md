# kickoff

[![core release](https://img.shields.io/badge/core-v1.0.0--alpha-2ea44f)](../../releases/tag/core-v1.0.0-alpha)
[![engines](https://img.shields.io/badge/engines-claude%20%7C%20opencode-blue)](#pick-your-battery)
[![licence](https://img.shields.io/badge/licence-MIT-green)](./LICENSE)
[**See it live →**](https://vinceferro.github.io/kickoff/)

**A company that builds itself, steered from a pocket.**
*Runs on Claude Code or OpenCode. Your org outlives your vendor.*

Not a better prompt and not a single agent — a small, persistent system: one coordinator, a crew of
specialists, memory that compounds across sessions, and a phone as the control plane. Give it one
brief and it plans, builds, tests, reviews and reports while you steer in a sentence at a time.

```
         YOUR PHONE                            ANY ENGINE
    Telegram · one sentence              Claude Code · OpenCode
             │   ▲                              │
             ▼   │                              │  the SEAM:
     ┌───────────┴───────────────────┐           │  one supervision contract,
     │          COORDINATOR          │◀──────────┤  two interchangeable batteries
     │ decides · dispatches · relays │           │
     └───────────────┬───────────────┘           │
                     │ in parallel, own context  │
                     ▼                           │
        planner → builder → reviewer → deployer │
```

## The leverage model

| Level | Shape | Where the human sits |
|---|---|---|
| L0 | prompt → output | you are the CPU |
| L1 | agent → one task | hand off, then review |
| **L2** | **system → whole domain** | **build the builder once, then steer** |

Parallel. Persistent. Async. Context-partitioned. Pocket-accessible.
And the core is **engine-agnostic** — your org's memory, charters and history live in YOUR
repos. Engines are replaceable components — we flipped the entire fleet mid-flight to prove it.
Models are still someone's service; switching them costs one line, not a migration.

## It drives agents — you approve the irreducible

The org runs everything reversible autonomously: scaffolding, building, testing, committing,
pushing behind local gates, previewing over Tailscale. It stops for exactly three things:

- **SPEND** — anything that bills: *"ready to ship X to Y, ~Z/mo — go?"*
- **DESTRUCTION** — data loss you can't undo
- **CREDENTIALS & PERMISSIONS** — rotating secrets, granting access

Everything else: decide, run, report. One-line beats while working — silence reads as death.

## The standard org (engine-neutral by design)

Adopt wires **the union** — everything both engines need, always on disk:

| Concern | Lives in | Claude reads | OpenCode reads |
|---|---|---|---|
| Charter | `CLAUDE.md` → `AGENTS.md` | ✓ | ✓ |
| Crew charters | `.claude/agents/` + `.opencode/agent/` | ✓ | ✓ |
| Memory recall | `memory/` + `MEMORY_DB` | recall hook | `memory_search` tool |
| Commit attribution | native | native | plugin + git hook |
| Telegram bridge | per-org token + state dir | official plugin | opencode-telegram |

**Switching engines costs one line:**

```bash
export WORKER_ENGINE=opencode   # or claude — in .kickoff/instance.env
kickoff up                      # supervisor cycles; nothing else moves
```

No porting. No re-adoption. No lock-in. Your memory, tracker, charters and history are the
asset; engines are batteries.

## Pick your battery

| | Claude Code | OpenCode |
|---|---|---|
| **Needs** | Claude subscription/API | Node ≥ 22 (free-tier models available) |
| **Bridge** | official telegram plugin | [opencode-telegram](https://github.com/grinev/opencode-telegram-bot) |
| **Ships in core since** | v0.1 | v0.38 |

Either alone suffices; running both is belt-and-suspenders — when one vendor has a bad week,
your fleet doesn't notice.

## Quickstart

```bash
# 1 · install (pins a reviewed release; prints tag @ commit so you can audit)
curl -fsSL https://raw.githubusercontent.com/vinceferro/kickoff/core-v1.0.0-alpha/install.sh | sh

# 2 · adopt a project — installs the standard org, engine-neutral
cd ~/my-app && kickoff adopt

# 3 · wire your pocket — one Telegram bot per org, isolated by state-dir + token
kickoff setup

# 4 · pick your battery
echo 'export WORKER_ENGINE="${WORKER_ENGINE:-opencode}"' >> .kickoff/instance.env
kickoff up

# 5 · steer from anywhere
#   brief:      "plan and build X"        → beats arrive while it works
#   preview:    https://<box>.ts.net/<project>/<app>
#   boards:     http://<tailnet-box>:9001/mc/<project>/   (tailnet-only, token-gated)
```

Deep dive: [QUICKSTART](./QUICKSTART.md) · [RUNNING](./RUNNING.md) · [ADOPT](./ADOPT.md) ·
[TOOLING](./TOOLING.md) · [the live site](https://vinceferro.github.io/kickoff/)

## What it realistically does

- Take an idea to a running, tested first slice — previewed from your phone within the hour
- Carry it toward production through human-approved deploys
- Run a multi-function org around it, each specialist under a least-privilege charter,
  all reporting into Mission Control
- Compound: session 40 is smarter than session 1 because memory compounded — not because
  the model changed

It does not write production software unattended, and it does not replace you.
It replaces the part of you that context-switches.

---

*Proof-of-work: this repository is developed BY its own system — releases v0.38→v0.39 were cut,
gated, and fleet-deployed by coordinators running on both engines.*
