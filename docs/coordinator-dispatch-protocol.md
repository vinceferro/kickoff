# Coordinator Dispatch Protocol (hardened)

*Status: v0.41 candidate — charter-template change, engine-neutral (applies identically to
opencode `.opencode/agent/*.md` and claude `.claude/agents/*.md`).*
*Evidence that motivated it: one production org's 142-message build session contained
`bash ×121, read ×20, glob ×1, task ×0`. The crew existed; the dispatch never happened.*

## The rule

**The coordinator is an air-traffic controller, not a builder.**

Any work expected to span more than one tool round-trip MUST be dispatched:

```
planner  → decompose into slices with runnable success criteria
builder  → implement a slice AND its test; report green/red honestly
reviewer → independently verify; adversarial pass, no rubber-stamp
```

Independent slices dispatch **concurrently**; dependent ones chain. The coordinator
synthesizes and relays — it does not implement.

## Coordinator's own tools

On substantial work: `read`, `glob`, `grep`, memory search, `task`, operator relay.
Implementation tools (`bash`, `edit`, `write`) are not the coordinator's hands.

**Solo exception** (be honest about which side you're on): trivial single-command
turns, conversational answers, status reads, and handoffs. If you're three bash calls
into "just checking something", you are building — dispatch.

## Relay discipline

Subagent verdicts pass through **unedited**. You add synthesis, sequencing, and
operator-facing brevity — never spin a red as amber. Every subagent completion is one
status beat to the operator.

## Two-tier doctrine (validated live)

**Tier 1 — default: engine-native `task` dispatch.** Dynamic, model-driven: dispatch,
collect reports, adapt, iterate until the goal is met. Verified end-to-end on one org:
planner → builder → reviewer chain, independent review gate before commit, landed fix
(`20a668e`), tracker noted — fully autonomous from a one-line natural-language request.

**Tier 2 — escape hatch: script lanes** (`lane-dispatch.sh` + `lane-runner.sh`) for
work too long or too scheduled to hold a session hostage: detached execution on git
worktrees. Dispatch provisions the worktree + session and **always** appends the node
to `<repo>/.kickoff/graph.json` — the ledger is written unconditionally, not
optionally. Nothing auto-starts a watcher: the coordinator runs
`lane-runner.sh <lane-id>` beside the lane (it polls the session for LANE-COMPLETE in
assistant text, verifies the claim with the lane's declared proof, adapts on provider
errors, nudges once on silence) — or `graph-executor.sh` to drive a whole dependency
graph, which also notifies Telegram at milestones when channel settings exist.
Plain lanes have NO notification path: check `graph.json` / `scripts/lane-status.sh`
instead.

Choose Tier 1 unless the job would hold the session hostage past a couple of minutes.

## The proof contract (lane/graph completion is machine-derived)

A sentinel sentence — `LANE-COMPLETE` / `NODE-COMPLETE` in assistant text — is a
**claim, never a verdict**. The watcher (lane-runner / graph-executor) verifies it
itself by running the lane's declared proof command in the lane's worktree; the
agent never runs its own proof. State ladder:

```
running ──sentinel──▶ claimed ──proof exits 0──▶ done            (✅ proof passed)
                       │        └─proof non-zero─▶ proof-failed  (🔴 proof output relayed)
                       └─no proof declared───────▶ unverified    (⚠️ CLAIMED, not done)
errors/stall ──▶ failed          upstream not done ──▶ blocked
```

Declaring the proof at dispatch:

- **lanes**: `PROOF_CMD='<shell command proving the work>' scripts/lane-dispatch.sh …`
  — recorded as the lane's `proof` field in `graph.json`.
- **graph nodes**: a `"proof"` field in the node spec (`{"id":"n2",…,"proof":"bash
  scripts/selftest.sh"}`).

`done` means *the proof passed* — everywhere. Exit codes (`lane-runner` exits 0 only
on a passed proof), the dependency gate (a dependent spawns only when its dep ended
`done`; `unverified`/`proof-failed` block it), the "N/M nodes green" graph totals,
and the Telegram notifications all refuse `claimed`/`unverified` as success. A lane
dispatched without a proof can never read as done — tell the coordinator to re-dispatch
with `PROOF_CMD` set.

`graph.json` is an honesty architecture, not a security boundary: same-user workers
can write it directly — the proof contract catches a lying *claim*, not a hostile writer.

## Crew discovery & growth (orgs are living things)

The planner→builder→reviewer trio is the **fallback spine, not the ceiling**. Orgs grow
their own specialists over time (a deployer, a migrations owner, a design-eye). At every
reground the coordinator re-enumerates its actual crew and routes accordingly:

1. **Discover**: list available subagents (agent definitions present in the repo).
2. **Route to owners**: a slice matching a grown specialist's domain goes to *them*,
   not to the generic builder. Existing ownership always beats default routing.
3. **Restraint**: never propose or spawn a specialist for a domain someone already owns.
4. **Growth signal**: the same domain recurring 3× with no owner → propose a new
   charter to the operator (author-on-approval), per the evolving-the-system rules.

This is the opengine expression of claude's **dynamic workflows**: the coordinator
authors a fan-out plan against the *current* crew, whatever it has grown to be.

## Effort routing (spend brain where it pays)

Dispatch carries a reasoning budget, not just a name — the model-class analogue of
claude's per-task effort optimization:

| Change type | Agent | EFFORT |
|---|---|---|
| Read-only audit / research / status | planner | low |
| Single-file fix, small feature | builder | unset (default) |
| Multi-file build, migration, risky surgery | builder | max |
| Anything touching shipped behavior | reviewer | high |

`lane-dispatch.sh` takes `EFFORT=low|max` as env; the ledger records what was spent
per node, so the graph doubles as a cost/attention audit trail.

## Why structural, not stylistic

Under the claude harness, Task-tool dispatch was *structural*: charters were the only
path to heavy work. Ported crews without ported dispatch discipline produce decorative
crews — available, chartered, and never invoked (see evidence). The protocol must live
in the coordinator's system prompt as invocation rules, with the primary agent's
implementation tools constrained by config where the engine allows.

## Org wiring (opencode)

Append to `.opencode/agent/coordinator.md` body:

```markdown
## DISPATCH PROTOCOL (binding)
Multi-step work is dispatched, never soloed:
1. planner → slices + criteria    2. builder → code+tests per slice
3. reviewer → independent verify  4. you → synthesize + relay
Your implementation tools stay holstered while any specialist can run.
Solo only for: single-command turns, conversation, status reads, handoffs.
```

And ensure the primary agent block keeps `task` enabled (subagents declare
`mode: subagent` with least-privilege `tools:`).
