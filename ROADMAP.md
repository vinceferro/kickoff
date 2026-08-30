# ROADMAP — from a starter to an OS for building systems

**The vision:** an *operating system to build systems* — Claude Code-native (coordinator + specialist agents +
skills + persistent memory), that **starts small, grows with your product as you go, runs your business
functions, and is controlled entirely from a Claude Code chat or from Telegram for mobility.** Start with a
seed; iterate into a real, properly-built platform — with the discipline + quality baked in from prompt one.

> Distilled from building a real, full-stack B2B platform end-to-end — and rebuilt as a *better* version given
> everything that arc taught us. The proof that the seed→platform path works is that a real platform grew this way.

---

## Where it is today (the seed)

✅ Coordinator charter (`CLAUDE.md`) · engineer crew (planner/builder/reviewer/deployer) · `bootstrap` / `adopt`
/ `preview` skills · the **quality bar** (definition of done) + **engineering principles** (the transferable
code-craft) · the control plane (chat + Telegram, multi-instance verified) · memory + tracker · the **brownfield
engine** (`kickoff adopt · run · serve · pull · eject` — additive, pinned, fully reversible), shipped as a
**Claude Code plugin** · fail-closed `preflight` + the session-refresh supervisor (auth self-heal).

That's the **seed + the discipline + the wiring**. The gaps below are the path from there to the full OS.

---

## The gaps → the build order

**0. Validate the machinery fires (the gate — do this first).**
A fresh Claude Code session opened *in this repo*, given an idea-brief, must actually: read `CLAUDE.md` → invoke
`bootstrap` → propose a stack → scaffold + test + run → keep the back-and-forth minimal. Until that's run
end-to-end, everything else builds on an unproven base. *(Run: `claude -p "<idea-brief>"` in a fresh copy, or
interactively — see `QUICKSTART.md`.)* Tighten `CLAUDE.md`/skills from what actually fires.

**1. Codebase-evolution / scaling machinery — the big one.**
Today the repo has the *principles* that point toward good structure; it doesn't yet hand you the structure.
Distill (genericised): the **monorepo** pattern (workspace), **dependency-boundary contracts** (one-directional
layers, enforced not hoped), **layered service architecture**, and **migration + design-system governance**.
Plus the capability to **restructure as you grow** — split a file into modules, an app into surfaces, when the
*size* demands it (no premature abstraction). *Unlocks: seed → structured platform.*

**2. The multi-function org — runs business for you.**
`GROWTH.md` describes the org; ship it. Genericised specialist charters — comms · growth · sales · product ·
finance · data · legal — plus the **single-tracker + per-function HQ** pattern. *Unlocks: the system runs
business functions, not just code.*

**3. Setup automation — onboard the control plane.** ✅ **v1 shipped** — the `setup` skill
(`.claude/skills/setup`) guides Telegram (via the plugin's `/telegram:configure` + `/telegram:access`) +
Tailscale + verification of each step, scoped to the control plane (+ a light tooling note). *Unlocks:
frictionless first-run.* Fast-follows: deeper auto-detection, the multi-instance recipe as an interactive
branch, and folding in tooling/MCP setup (overlaps gap 4).

**4. Deeper harness leverage.**
Recommended MCP servers wired (eyes/hands/docs), useful hooks, slash commands. *Unlocks: more capable agents.*

**5. Distribution — package as a Claude Code plugin.** ✅ **shipped** — the capabilities (skills + crew +
memory hook) ship as a Claude Code plugin (`plugin/`, local-path marketplace) alongside the `kickoff` CLI and
the brownfield `adopt · run · serve · pull · eject` journey (core-v0.2), enabled at project scope with no
copy-drift and pinned per tag. *Unlocks: brownfield + multi-project with no cloning.* (See README
"Distribution".) Fast-follow: a curl-installer / packaged install to remove the clone-a-template step.

**6. Self-evolution (the frontier).**
The orchestrator proposing + authoring its own agents/skills as the work surfaces the need — human-approved.
Full autonomous self-mutation stays a direction, not a license.

---

## How to build it (the principles for this build, too)

- **Validate before you scale** (gate 0). Don't grow the OS on an unproven base.
- **Distill from the real arc, then improve** — take the evolved, battle-tested patterns; fix what was clunky.
- **Grow opportunistically** — add a piece when the work demands it, not speculatively.
- **Every step shippable + tested** — the quality bar applies to the OS itself.
- **Honest-stage throughout** — mark what's real vs aspirational; don't overclaim what the OS does.

*This is a deliberate, separate track from shipping the talk (done at the seed level) and from the primary
product. Build it consciously, switch contexts cleanly.*
