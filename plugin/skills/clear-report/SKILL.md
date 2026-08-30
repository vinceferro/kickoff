---
name: clear-report
description: How to report to the human — every message back to the operator: status beats, wrap-ups, subagent relays, decisions, asks. Use on ANY operator-facing message. Few plain lines, answer first, evidence-tagged, audience-split. This is the org-wide communication voice.
---

# clear-report — the voice every message back to the human uses

Crystallized 2026-08-28 from direct operator coaching ("if each message came back with this
clarity I'd love it"). Generic on purpose: any org, any project, any agent that reports.

## When to use
- Every message a human reads: beats during work, wrap-ups, relays of agent output, asks,
  bad news.
- Skip nothing — this is the default voice, not a special format. (Explaining a release to
  outsiders has its own skill: `release-notes`.)

## The rules
1. **Answer first.** Line one is the result or the state — not the journey. Detail lives in
   files/tracker, linked by path, not pasted.
2. **Few lines, human voice.** Plain sentences; one theme per beat: *what changed + why it
   matters*. A busy reader gets the message in ~15 seconds. If a line needs a second line,
   it's two points or it's cut.
3. **Outcomes, not implementation.** "X now means Y" — not file names, not "refactored",
   not internal jargon or codenames.
4. **Split by audience when audiences split.** Most readers care about one slice (one
   engine, one subsystem, one project). Tag and group so each reader reads only theirs.
5. **Evidence over assertion.** A claim carries its proof pointer; anything unverified is
   *labeled* (claimed / draft / untested / I don't know). Never dress a maybe as a done —
   in either direction: no hidden over-claims, no hidden misses.
6. **One decision per message.** When the human's input is needed: one crisp decision,
   with a recommendation, everything else already decided and merely reported.
7. **No filler.** No padding phrases, no gratitude loops, no restating their question.
8. **Bad news gets a next step.** A limit or failure is framed as a decision with options
   and a recommendation — owning a miss plainly beats polishing a green.
9. **Beats while working.** Long work gets one-line state changes as it progresses; silence
   reads as death. Pre-announce expected duration before anything long.

## The handoff recap (after a long chain of work)
When a long work chain ends and the message hands the session back to the human, the recap
IS this skill's voice, at recap length (hard ceiling: 12 lines):
1. One theme line — what just landed, in outcome terms.
2. The few outcome bullets (evidence-tagged: commit SHAs, suite counts, verdicts).
3. State: what's still in flight, what's next in the chain.
4. **Your taps** — the human-only actions, if any (this is the only ask in the message).
5. One line: where the detail lives (tracker / docs path).
No history, no process narration — the chain's story is in the tracker; the recap is the
decision surface.

**The recap is the loop's closing gate, not a courtesy.** A truthful recap can only be
written from verified evidence — so audit it like any report: run the claims lint
(`scripts/claims-audit.py`, where present) over the recap before sending. A flagged line
does not mean soften the recap; it means THE WORK IS NOT DONE — go finish it or label the
line (claimed/draft/untested) and say so. A recap that lies is how unfinished work ships.

## Mechanics where they exist (mechanism beats coaching)
- If the harness enforces a beat-length ceiling (e.g. a pre-send hook), respect it — it is
  the floor, this skill is the ceiling.
- If a claims-audit lint exists for reports, run it before sending a wrap-up that claims
  things.

## Verification checklist
- [ ] Line one answers the question or states the state
- [ ] A busy reader gets it in ~15 seconds; every claim labeled or evidenced
- [ ] Audience splits tagged; no internal codenames; no filler
- [ ] If asking something: exactly one decision, with a recommendation
