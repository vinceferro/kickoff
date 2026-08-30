#!/usr/bin/env bash
# wire-canon-into-charters.sh — fold the function-relevant operating principles into each
# subagent charter (and the charter template), so they're loaded BY DEFAULT — not just
# available in CLAUDE.md/memory that a dispatched subagent never reads. Idempotent + reversible.
#
#   bash scripts/wire-canon-into-charters.sh            # install
#   bash scripts/wire-canon-into-charters.sh --remove   # strip the wired blocks back out
#
# Why a script: editing .claude/agents/*.md (agent charters) changes the crew's own system
# prompts — a self-modification the harness gates behind explicit human action (CLAUDE.md:
# "the human approves every change to the crew"). Running this yourself IS that approval.
#
# Context (contribution ②): a subagent loads ONLY its own charter body — not the project
# CLAUDE.md or memory/. So the most-emphasized lesson ("render it and look") was ABSENT from
# the builder + reviewer charters — the two agents that build and check UI. This wires the
# function-scoped principle into each. (Strong prior: subagents don't inherit CLAUDE.md; if
# your harness DOES inject it, these are belt-and-suspenders — still beneficial.)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-install}"

python3 - "$ROOT" "$MODE" <<'PY'
import os, re, sys
root, mode = sys.argv[1], sys.argv[2]
START, END = "<!-- CANON:START (wire-canon-into-charters.sh) -->", "<!-- CANON:END -->"

# Appended to EVERY charter below. An output style shapes the main conversation only —
# subagents run their own system prompt and never see it. This repo delegates nearly all
# real work to specialists, so without this the operator gets a plain-speaking coordinator
# relaying verbose specialists. Keep in step with .claude/output-styles/plain-report.md.
SHARED = """

## Canon — report it plainly

- **Lead with the answer.** First line = what you did, whether it worked, what the reader does
  next. Assume they are tired, on a phone, and have to decide something.
- **Short sentences, small words, exact identifiers.** Instructions under 20 words, one per
  sentence, active voice. Never abbreviate a path, command or flag to shorten a line.
- **Two options at most**, plus your recommendation and one reason. Not a menu.
- **Budget the WHOLE report, not just the sentences.** Every other rule here caps a part, so a
  report can obey all of them and still be too long. Lead with the verdict; push evidence, logs
  and long lists into files and name the path. Your report costs the coordinator context it needs
  for the next decision. (The operator-facing channel has a hard 12-line ceiling on top of this —
  that one is the coordinator's to keep, and it is enforced by a hook, not by good intentions.)
- **State uncertainty, never stack it.** "I did not test this" and "this is 3 runs, not a law"
  are correct. Chained modals that hide who is unsure are not. Honesty outranks brevity — spend
  the sentence on the caveat.
- **This binds your REPORT, not your analysis.** Design notes, findings and evidence stay plain
  prose; procedure-language strips the caveats an argument needs. Full style:
  `.claude/output-styles/plain-report.md`."""

blocks = {
  ".claude/agents/builder.md": """## Canon — render it and look

- **For any UI, render it and look — and the render is not the device.** A diff that type-checks
  can still be visually broken; render the real output and look at the pixels across the width
  matrix in light + dark before calling it done. A headless-Chromium shot is NOT Safari or an
  iPhone — say "rendered, please confirm on your device" for visual sign-off; never imply you
  verified on an engine you can't run. Working != designed: one deliberate accent, real hierarchy
  (use the whole canvas), polished empty/hover/active states.""",

  ".claude/agents/reviewer.md": """## Canon — look at the UI, don't pass it on the diff

- **If it has a UI, look — don't pass a UI on the diff alone.** Render the real output and
  scrutinise the screenshot region-by-region (zoom in — the bug hides in the corner a full-frame
  view skips). A headless shot isn't the user's device; report visual checks as "rendered, not
  device-verified" and never relay a "verified" you didn't look at yourself.""",

  ".claude/agents/planner.md": """## Canon — name the visual proof

- When the brief has a UI, name the visual proof too (render-and-look across the matrix, light +
  dark), not just a unit test — "it compiles" hides "it's broken" for anything visual.""",

  ".claude/agents/deployer.md": """## Canon — verify live + fail closed

- After any go-live that touches routing/redirects, curl the real live URL(s) and confirm the
  response before reporting shipped — a redirect loop passes every local check and is still a live
  outage. Secrets fail closed: a missing key must 503, never fall back to an insecure default.""",

  ".claude/agent-charter-template.md": """## Canon — the inherited quality bar

- **Inherited quality bar (non-negotiable):** built · tested · adversarially-reviewed where it
  matters · scanned · honest-stage. Anything with a UI is rendered and looked at (the render is
  not the device — never claim cross-engine "verified"). Full set: CLAUDE.md -> "The quality bar".""",
}

# Every charter inherits the reporting rules, because no output style can reach a subagent.
blocks = {rel: body + SHARED for rel, body in blocks.items()}

changed = []
for rel, block in blocks.items():
    path = os.path.join(root, rel)
    if not os.path.exists(path):
        print("SKIP (missing): " + rel); continue
    with open(path) as f:
        text = f.read()
    # strip any prior wired block first (idempotent + the --remove path)
    text = re.sub(re.escape(START) + r".*?" + re.escape(END) + r"\n?", "", text, flags=re.S)
    if mode != "--remove":
        if not text.endswith("\n"):
            text += "\n"
        text += "\n" + START + "\n" + block + "\n" + END + "\n"
    with open(path, "w") as f:
        f.write(text)
    changed.append(rel)

print(("REMOVED from " if mode == "--remove" else "WIRED into ") + str(len(changed)) + " files:")
for c in changed:
    print("  " + c)
PY

echo ""
echo "Done. Subagents now load the function-scoped principle by construction."
echo "Reversible: bash scripts/wire-canon-into-charters.sh --remove"
