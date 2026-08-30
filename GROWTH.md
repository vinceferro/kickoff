# GROWTH — from a starter to a system

This repo starts lean on purpose: a coordinator, a few engineer subagents, a bootstrap skill, memory,
a tracker. It's a **seed**, not a finished system. Here's the path it grows along — each stage is real,
human-steered, and adds only what you need.

> The system grows itself: the orchestrator proposes, **you approve**, the orchestrator authors. There are
> no static agent templates — specialists are written on demand, the same way projects are scaffolded fresh.

## The path

**Stage 0 — Bootstrap one thing.** Open the repo in Claude Code, give a brief, the `bootstrap` skill
proposes a stack and scaffolds a running first slice. (See `QUICKSTART.md`.)

**Stage 1 — Memory + tracker.** Start writing durable facts to `memory/` and keeping `TRACKER.md` current.
This is what makes session 40 smarter than session 1.

**Stage 2 — Engineer crew → ship.** The coordinator already dispatches `planner` → `builder` → `reviewer`.
When you're ready to go live, `deployer` takes a green build to a URL — **you approve the go-live.**

**Stage 3 — Grow a multi-function org.** Code isn't the only domain. When work recurs in a non-build area,
**ask the coordinator to author a specialist** ("write me a comms specialist") — it drafts the charter (from
`.claude/agent-charter-template.md`, so least-privilege tools + streaming to Mission Control come baked in),
you approve, it lands in `.claude/agents/`. Each function then streams its own lane into MC live — the org's
push-surface. A useful catalogue to grow into:

| Function | Owns |
|---|---|
| comms | brand voice, content, posts, landing copy, assets |
| growth | the acquisition→activation→retention funnel, experiments, growth loops |
| sales | the 1:1 pipeline, outreach, partnerships, closing |
| product | the spec, roadmap, the demo, prioritisation |
| finance | unit economics, pricing, runway/budget, the model |
| data | the metrics view, instrumentation, "what's working" |
| legal | first-pass ToS/privacy DRAFTS + a counsel brief (never authoritative advice) |

Add only the ones the work demands. The starter stays lean; the org grows to fit.

**Stage 4 — Steer from your pocket.** Wire the control plane (`README.md`): Telegram relay + Tailscale mesh.
Now you run all of it async, from your phone.

**Stage 5 — The system surfaces its own growth.** A mature coordinator proactively offers a small, ranked set
of growth moves — a new specialist, a next capability — *including the honest "ship, don't over-build" counter*.
You approve; it authors. (Fuller autonomous self-mutation is a direction, not a license — every change is
human-approved.)

## The worked example (how a real system grew)

Honest, genericised: **chats & research** (disposable) → **coding sessions** (first "it built a whole thing")
→ **a single get-it-done agent** (faster, but you're the bottleneck) → **agentic loops** (one thread, context
fills) → **coordinator + specialists + a Telegram relay** (parallel, persistent, async) → **a multi-function
org around a real, shipped product.** Months, not minutes — built alongside the product, steered from a phone.
That arc is the proof the path works; this repo is the seed you start it from.

## The loop, applied to this repo

This starter is itself kept honest by the loop it describes — **continuously refined from real builds**, not
frozen. Earlier pass: the sharpest operational learnings from running a real full-stack build (months, solo) were
distilled back in — see the **"Distilled from real builds"** section of `CLAUDE.md` and the matching
`memory/` entries (the render is not the device · fix the shared source not a local hack · workers can't be
steered mid-flight · the machine is the real ceiling · turnkey the human's hands-on asks · verify live
behaviour after deploy). A later pass folded in a full build day steered by a **non-technical operator over
Telegram**: give the agent reliable **eyes** (the browser MCP is a critical dependency — announce loss-of-eyes,
never imply visual sign-off you didn't do) and a reliable **heartbeat** (set a completion watchdog; don't stall
while subagents run), **read the operator early** (ask only taste calls, execute reversible, show don't tell,
detect stream-vs-batch), and **surface structural limits as decisions** routed to the owner. The control loop
that carried that day — granular verified commits, a preview/screenshot with essentially every change,
specialist subagents per layer at least privilege — is exactly what the charter already encodes, confirmed
under real load.

The most recent pass distilled from a **cross-org AI-orchestrated go-live** (from-zero GCP/Cloud-Run
bring-up with a multi-function AI org). Three learnings that folded in:

1. **Adversarial review is structural, not optional.** An independent agent briefed to BREAK the build (not
   approve it) caught genuine HIGH-severity security bugs and deploy-blocking config bugs invisible to the
   implementer. This pattern — build → adversarial-review-by-a-different-agent → fix → re-review — is now a
   first-class quality gate for security/money/irreversible paths in `CLAUDE.md` and the agent roster.

2. **The org-as-cockpit keeps the human in command without blocking them.** A multi-function org around a
   live critical path creates a real risk: the human gets overwhelmed by parallel streams and derails the
   active build to chase every idea that surfaces. The clean pattern: **every function streams into one
   surface** (the tracker / Mission Control), each entry is a concrete next-up for the human, and the
   coordinator captures new ideas in the right function's backlog *without* routing them to the human until
   the active path is clear. The human steers one thing at a time; the org parallelises the rest.

3. **From-zero bring-ups are iterative loops, not one-shots** (see `CLAUDE.md` + memory file). Fast
   log-diagnosis + honest "expected friction" framing is the value — not pretending the first run is clean.

That round-trip — a real build teaches a lesson, the lesson folds back into the method — *is* the
living-system loop, applied to the system itself.
