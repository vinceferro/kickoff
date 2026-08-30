#!/usr/bin/env bash
# wire-red-first-into-charters.sh — fold the RED-first / negative-control discipline into the
# build+check charters, so the agents that write and accept tests are told that a green suite is
# not evidence until something has been watched go red. Idempotent + reversible.
#
#   bash scripts/wire-red-first-into-charters.sh            # install
#   bash scripts/wire-red-first-into-charters.sh --remove   # strip the wired blocks back out
#
# Why a script: editing .claude/agents/*.md changes the crew's own system prompts — a
# self-modification the harness gates behind explicit human action (CLAUDE.md: "the human
# approves every change to the crew"). Running this yourself IS that approval.
#
# Why this block, and why now (crew-review 2026-08-10). CLAUDE.md already carries "Prove the
# check can fail" and the newer "a scrub that buys determinism can be deleting the bug's
# carrier" — but a dispatched subagent loads ONLY its own charter, and neither builder nor
# reviewer says any of it. builder.md says "make it real and make it pass"; the one word absent
# is FAIL. Three separate misses inside four days, each a check that reported green over a world
# it was not measuring:
#   · every preflight channel lane SCRUBBED the ambient variable the live bug rode on — green
#     suite, shipped release, guard inverted into a phantom fail-closed;
#   · a hand-written repro passed GREEN while the command under test never executed at all
#     (an `env` argument-order slip), asserting on empty output;
#   · a triage tool keyed on mtime, where 131 of 186 files share one bulk-move timestamp — it
#     would have reported "nothing to demote" and read as CLEAN.
# The reviewer's existing "is the test meaningful, or does it pass trivially?" is the closest
# line in the crew and it is still weaker than the discipline: trivially-passing is something you
# judge by reading, red-first is something you OBSERVE.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-install}"

python3 - "$ROOT" "$MODE" <<'PY'
import os, sys
root, mode = sys.argv[1], sys.argv[2]
START, END = "<!-- REDFIRST:START (wire-red-first-into-charters.sh) -->", "<!-- REDFIRST:END -->"

blocks = {
  ".claude/agents/builder.md": """## Canon — watch it go RED before you call it green

- **A test you never saw fail proves nothing.** Before reporting green, run the test against the
  UNFIXED code (stash the fix, or point it at the pre-fix path) and confirm it goes RED for the
  reason you expect. A check that cannot fail is not evidence — it is a green light wired to
  nothing, and it is worse than no test because it authorises the next person to stop looking.
- **Assert the run actually happened.** A harness slip — a command that never executed, an empty
  capture, a pipeline whose last stage always exits 0 — makes every downstream assertion pass on
  emptiness. Assert on a positive the run must produce (a count, a marker, the tool's own output)
  before reading anything out of it.
- **Ask what your fixture removes.** Test setup neutralises ambient state to stay deterministic;
  if the thing you neutralised is an INPUT to the behaviour under test, you have covered only the
  safe case and the defect lives in what the setup deleted. Add a second lane that sets it
  hostilely — the clean fixture and the hostile one are both required, and neither substitutes.""",

  ".claude/agents/reviewer.md": """## Canon — a green suite is a claim, not evidence

- **Ask what input would turn this red, and whether the test can still supply it.** A suite that
  passes over a live bug is the normal case, not the exotic one — usually because the setup pins,
  stubs, or unsets the exact variable the bug rides on. Read what the fixture holds CONSTANT, not
  only what it asserts.
- **Require the red-first evidence, don't infer it.** If the builder reports green without having
  watched it fail on the unfixed code, that is an incomplete review, not a passing one — say so
  and hand it back. "It passes" and "it would have caught this" are different claims.
- **A check must assert on what the SYSTEM consumes.** Built around an artifact nothing depends
  on, it reports on a world nobody lives in — and reports green. Name the consumer each check
  protects; if you cannot, the check is testing its own bookkeeping.""",

  ".claude/agents/planner.md": """## Canon — name the negative control, not just the proof

- **Every success criterion ships with its negative control.** Alongside "the test that proves it
  works", name the input that MUST make that test fail. A proof with no stated failing input is
  unfalsifiable, and the build will satisfy it without touching the real behaviour.""",
}

changed = []
for rel, body in blocks.items():
    p = os.path.join(root, rel)
    if not os.path.exists(p):
        print(f"  skip (absent): {rel}")
        continue
    s = open(p, encoding="utf-8").read()
    if START in s and END in s:                      # idempotent: replace in place
        pre, rest = s.split(START, 1)
        _, post = rest.split(END, 1)
        s2 = pre + (f"{START}\n{body}\n{END}" if mode != "--remove" else "").rstrip("\n") + post
        if mode == "--remove":
            s2 = (pre.rstrip("\n") + "\n" + post.lstrip("\n")).rstrip("\n") + "\n"
    elif mode == "--remove":
        print(f"  not wired: {rel}")
        continue
    else:
        s2 = s.rstrip("\n") + f"\n\n{START}\n{body}\n{END}\n"
    if s2 != s:
        open(p, "w", encoding="utf-8").write(s2)
        changed.append(rel)
        print(f"  {'stripped' if mode == '--remove' else 'wired'}: {rel}")
    else:
        print(f"  already current: {rel}")
print(f"\n{len(changed)} charter(s) changed.")
PY

echo
echo "Charters are the crew's system prompts — re-read one to confirm it says what you want:"
echo "  cat .claude/agents/builder.md"
echo "Reverse at any time:  bash scripts/wire-red-first-into-charters.sh --remove"
