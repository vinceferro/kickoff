#!/usr/bin/env python3
"""PreToolUse guard: bounce a runaway Telegram beat back to the coordinator.

The operator reads every beat on a phone and has said plainly that long messages lose him
("too much text I'm getting lost"). That rule lives in CLAUDE.md, in memory, and is injected
into the coordinator's context on essentially every turn by the recall hook — and it still
keeps failing, because an instruction competes with a growing context while a hook does not.

So this is the same rule expressed as a mechanism. It does NOT rewrite or truncate anything:
it denies the call and hands back the measured numbers, and the coordinator writes a shorter
message itself. Nothing the operator reads is silently altered by a script.

TWO TIERS, because length is a proxy for the real variable and a bad one on its own. The
operator's own correction (2026-08-10): *"I don't mind receiving a long text if the situation
actually requires it. I just need to be able to follow it logically."* A single hard cap gets
that wrong in the expensive direction — it makes a genuinely-warranted long answer impossible
to send at all, which is worse than the rambling it prevents. So:

  · SOFT (over NUDGE_LINES): allowed through, with a reminder to check it reads in logical
    order. Length is not the defect; an unfollowable message is.
  · HARD (over MAX_LINES): denied. This is not "long", it is runaway — the detail belongs in
    the tracker or an attached file, which reads better on a phone anyway.

Wiring — this ships wired, in the plugin's own `hooks/hooks.json`, so an adopter gets it on
`kickoff pull` with nothing to do by hand:

    "PreToolUse": [{ "matcher": "mcp__.*telegram.*__(reply|edit_message)",
      "hooks": [{ "type": "command",
                  "command": "python3 \\"${CLAUDE_PLUGIN_ROOT}/hooks/beat-length-guard.py\\" || true",
                  "timeout": 10 }] }]

(Quote the path exactly as above. An earlier draft of this docstring named a path that does not
exist — and because `|| true` makes a missing file exit 0 silently, copying it would have wired a
hook that never runs and never says so.)

FAIL-OPEN IS LOAD-BEARING. This sits in front of the only channel to the operator, so a bug
here would gag the worker completely — the exact failure this system has paid for before. Every
unexpected condition (bad JSON, missing field, unreadable env, an outright crash) allows the
call. The guard only ever denies when it has positively measured an over-long beat.

Knobs: BEAT_GUARD=0 disables · BEAT_NUDGE_LINES (7) · BEAT_MAX_LINES (12) · BEAT_MAX_CHARS (1200).
A threshold knob set to zero or negative disables THAT dimension rather than denying everything —
see `_limit_env`. Every knob misreading resolves toward delivery.
"""

import json
import os
import re
import sys
from typing import NoReturn

# The soft line is where the style's own default sits (6 lines), plus one so a beat that lands
# exactly on budget is never nudged. The ceiling was 20/2000 and the operator's complaint landed
# squarely under it: every reply in a whole session's work came in at 8-19 lines and passed, both
# levers behaving exactly as written while the result stayed too long to read on a phone. A cap set
# where RUNAWAY begins does not bound VERBOSE. Tightened with the style's new whole-message budget,
# which is the generation-time half — this stays the backstop, not the primary.
DEFAULT_NUDGE_LINES = 7
DEFAULT_MAX_LINES = 12
DEFAULT_MAX_CHARS = 1200

# Checked inside the script as well as in the settings matcher: a matcher typo that over-matches
# must not turn this into a guard on unrelated tools.
TOOL_RE = re.compile(r"^mcp__.*telegram.*__(reply|edit_message)$", re.IGNORECASE)


def _limit_env(name, default):
    """Resolve a threshold knob, degrading toward DELIVERY on every bad value.

    An unparseable knob falls back to the default rather than crashing the guard. A knob at or
    below zero disables *that dimension* (returns None) rather than denying everything — the
    switch sitting right next to these is `BEAT_GUARD=0`, so "set it to 0 to turn it off" is the
    natural misread, and a literal reading of `max_lines = 0` would deny EVERY message. That is
    the silent gag this whole file is built to make impossible, so a plausible typo must not
    reach it. Both bad-value paths therefore resolve toward sending, never toward blocking.
    """
    try:
        value = int(os.environ[name])
    except (KeyError, ValueError, TypeError):
        return default
    return value if value > 0 else None


def _allow() -> NoReturn:
    """Emit nothing: no hookSpecificOutput means the call proceeds untouched.

    Annotated NoReturn so a checker knows the guards above it are terminal. Without it,
    `text` reads as `str | None` past its own isinstance check and three phantom errors
    appear on a file that is correct — noise that trains the next reader to ignore the
    checker on this file."""
    sys.exit(0)


def main():
    if os.environ.get("BEAT_GUARD") == "0":
        _allow()

    payload = json.loads(sys.stdin.read())

    tool = payload.get("tool_name") or ""
    if not TOOL_RE.match(tool):
        _allow()

    text = (payload.get("tool_input") or {}).get("text")
    if not isinstance(text, str) or not text.strip():
        _allow()

    nudge_lines = _limit_env("BEAT_NUDGE_LINES", DEFAULT_NUDGE_LINES)
    max_lines = _limit_env("BEAT_MAX_LINES", DEFAULT_MAX_LINES)
    max_chars = _limit_env("BEAT_MAX_CHARS", DEFAULT_MAX_CHARS)

    # Blank lines are paragraph breaks, not content — counting them would punish readable
    # spacing, which is the opposite of the goal.
    lines = len([ln for ln in text.splitlines() if ln.strip()])
    chars = len(text)

    over = []
    if max_lines is not None and lines > max_lines:
        over.append("%d lines (max %d)" % (lines, max_lines))
    if max_chars is not None and chars > max_chars:
        over.append("%d chars (max %d)" % (chars, max_chars))

    if over:
        reason = (
            "Runaway beat: %s. Not sent. This is past 'long but warranted' — cut it to the "
            "decision and the state, and put the detail in the tracker or attach it as a file, "
            "which reads better on a phone than a wall of chat text anyway." % " and ".join(over)
        )
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        }))
        sys.exit(0)

    if nudge_lines is not None and lines > nudge_lines:
        # Long is fine when the situation earns it. The only question worth raising is whether it
        # can be FOLLOWED, which is what he actually asked for.
        #
        # Deliberately NO hookSpecificOutput here. An explicit "allow" does not mean "do not
        # block" — it AUTO-APPROVES the call, skipping any permission prompt the operator
        # configured. That would invert an adopter's own settings: short beats prompt, long ones
        # sail through silently, purely because a nudge fired. A bare systemMessage annotates
        # without touching the permission decision, which is all a nudge should ever do.
        print(json.dumps({
            "systemMessage": (
                "%d-line beat (soft limit %d) — allowed. Long is fine when the situation needs "
                "it; unfollowable is not. Check it leads with the answer and reads in logical "
                "order before you send the next one." % (lines, nudge_lines)
            ),
        }))
        sys.exit(0)

    _allow()


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except BaseException:
        # Never let this guard stand between the coordinator and the operator.
        _allow()
