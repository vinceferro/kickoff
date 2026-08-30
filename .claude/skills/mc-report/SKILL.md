---
name: mc-report
description: Report a semantic beat to Mission Control — a decision reached, a milestone hit, or a completion-with-artifact (what shipped + its link). Use when you agree on an approach with the operator, hit a real milestone, get blocked/unblocked, or finish a workstream with something to show — the "why" and the artifact the automatic lifecycle hook can't see. Complements (does not replace) the spawned/working/done spine the plugin's lifecycle hook streams for free.
---

# mc-report — stream the SEMANTIC beats to Mission Control

Mission Control has **two reporting layers**, and this skill is the rich one:

- **The mechanical spine (automatic — you do nothing).** The kickoff plugin's lifecycle hook streams
  every subagent's allocation on its own: `SubagentStart → function <agent> working`, `SubagentStop →
  function <agent> done` + a trimmed final message on the 📡 feed. That gives the operator *in flight /
  finished* granularity with zero charter edits — but it can only see the mechanics, never the meaning.
- **This rich layer (deliberate — you reach for it).** The hook cannot know *what was agreed*, *which
  milestone just landed*, or *what shipped and where to see it*. That is the signal the operator actually
  steers on — so you report it, at the meaningful boundaries, by calling `mc-update.py` yourself.

Shape every report on the arc the operator cares about: **agreement → work → completion + artifact.** What
was agreed, what is being built, what shipped and its link. **Signal, not a play-by-play** — the feed is for
the human, not a debug log. Silence and spam are the same bug.

## The entrypoint

Use your repo's mc entrypoint (they take the same verbs — the seam self-targets *your* board):

- **Adopted repo** (a repo you ran `kickoff adopt` on): `.kickoff/bin/mc <verb> …`
- **kickoff-native project** (bootstrap/greenfield): `python3 mission-control/mc-update.py <verb> …`

Below, `mc` stands for whichever applies. Every write is atomic + concurrency-safe (flock), so you stream
your own lane **directly and concurrently** with every other agent — no coordinator bottleneck.

## The three beats to report

**1. Agreement — a decision is reached (the "why").**
```bash
mc add decided "JSON is the canonical store; the tracker renders from it"   # a locked call, on the record
mc add in_progress "Wiring the payment webhook" --theme Payments            # what the agreement became — work
```
Report an agreement when the operator OKs an approach or you lock a design call — so the board shows *why*
the work in flight exists, not just that an agent is busy.

**2. Milestone — a real boundary lands (not every edit).**
```bash
mc log <agent> "payments slice green — 42 tests pass, adversarial review clean"   # a landing, on the 📡 feed
mc function <agent> blocked "needs the Stripe key (Secrets panel)"                 # a status flip worth surfacing
```
Log at meaningful boundaries only: a slice landed, you got blocked, you got unblocked. The lifecycle hook
already covers spawned/finished — you add the *substance* the hook can't see.

**3. Completion + artifact — the work ships, with something to show.**
```bash
mc log <agent> "shipped the checkout page → https://preview.myapp.dev/checkout"   # the artifact LINK, not prose
mc done in_progress 0 --theme Payments                                            # move the workstream to Done
```
Always pair a completion with its **artifact** — a preview URL, a PR link, a screenshot path. `done` needs a
`--theme` (its constellation) or its star won't group on the continuum; carry the theme from `in_progress`.

## When to reach for this

Reach for `mc-report` the moment you cross a **semantic** boundary — an approach agreed, a milestone hit, a
block/unblock, a workstream shipped with an artifact. Do **not** narrate routine tool calls or every file
edit: that is the spine's job (or noise). If you're unsure, ask "would the operator *steer* on this?" — if
yes, report it; if it's just mechanics, let the hook handle it.

## Honest-stage

The board reflects only what you write — an unreported milestone is invisible, an over-reported feed buries
the signal. Report the landings and the artifacts, skip the keystrokes. See the `mission-control` skill for
standing up the board itself and the Secrets channel.
