#!/usr/bin/env bash
# plugin/hooks/mc-hook.sh — the MECHANICAL SPINE of Mission Control reporting (v0.9 slice 4).
#
# The read-side of the brownfield mesh: when an adopter enables the kickoff plugin, EVERY
# subagent their coordinator spawns streams its allocation into Mission Control — with ZERO
# edits to any .claude/agents/*.md charter. This is a plugin LIFECYCLE hook, wired via
# plugin/hooks/hooks.json under two events; eject removes the plugin keys and it stops firing,
# clean. It rides the SAME merge mechanism as memory-hook.sh (a plugin hooks.json fires
# ALONGSIDE .claude/settings.json hooks, additive — never overrides), so activation is FREE
# with plugin-enable — no new gated settings edit, no charter touch.
#
# WHAT IT DOES — translate the subagent lifecycle to the board's agreement→work→artifact arc:
#   SubagentStart  → `mc function <agent_type> working "spawned"`   (allocation: in flight)
#   SubagentStop   → `mc function <agent_type> done`                (finished)
#                  + `mc log <agent_type> "<final message, trimmed>"`  (outcome, signal-only)
# It reports allocation granularity (spawned/finished) — NOT a per-tool play-by-play (that is
# PostToolUse feed-spam, deliberately NOT wired; MC is signal, not a debug log). The SEMANTIC
# beats the hook cannot see — a decision's "why", the shipped artifact link — are the job of the
# discoverable `mc-report` SKILL the agent reaches for, not this spine.
#
# THREE HARD INVARIANTS (all load-bearing — a slip here bricks or blocks a live subagent):
#   1. ALWAYS exit 0. A SubagentStart/Stop hook that exits 2 BLOCKS the subagent turn; any other
#      non-zero is shown on stderr. This hook is best-effort telemetry — a missing shim, a missing
#      board, malformed stdin, no python3 must SILENTLY no-op. We `set +eu` and swallow the shim's
#      rc (mc-update.py exits 2 FATAL when its target board is missing; the shim exits 1 when the
#      engine is absent) so NOTHING the reporting path does can ever block the turn.
#   2. INJECTION-SAFE. `last_assistant_message` is UNTRUSTED subagent text — it may carry quotes,
#      $(...), backticks, and newlines. It is NEVER eval'd and NEVER interpolated into a shell
#      command. python3 extracts the fields and emits them NUL-delimited; bash reads them into
#      variables and passes each as a SINGLE quoted argv value to the shim (`"$msg"`), so a shell
#      metacharacter in the message stays a literal byte all the way to the JSON store.
#   3. RIGHT BOARD. It routes through "$CLAUDE_PROJECT_DIR/.kickoff/bin/mc" — the seam shim that
#      self-resolves MC_STATE_FILE to the ADOPTER's board — never the bare mc-update.py default
#      (which lands in / FATALs on the read-only core clone: a blank board on the operator's phone).

# NOT `set -e`: a hook must never abort on a non-zero step. `-u` off too — we probe optional vars.
# Explicit guards + the final `exit 0` do the fail-open work.
set +eu

# CLAUDE_PROJECT_DIR is the authoritative adopter-repo anchor CC exports (the same value
# memory-hook.sh trusts). Without it we cannot locate the board seam → nothing to do; never block.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
[ -n "$PROJECT_DIR" ] || exit 0

# The mc seam shim: it pins REPO_DIR to the adopter repo, sources instance.env (→ MC_STATE_FILE
# anchored on the adopter board), and execs the pinned-core mc-update.py. If it is absent or not
# executable (repo not adopted / mid-pull) → fail-open, never the bare-default (wrong-board) path.
MC="$PROJECT_DIR/.kickoff/bin/mc"
[ -x "$MC" ] || exit 0

# bash cannot parse the event JSON; python3 is the parser (already a plugin-selftest dep). No
# python3 → silently no-op (best-effort telemetry, never a hard dep for the turn).
command -v python3 >/dev/null 2>&1 || exit 0

# Capture stdin once (the CC event JSON — small; JSON carries no NUL bytes) and hand it to python
# explicitly, so the extraction is unambiguous regardless of redirection.
_ev="$(cat)"

# ── Parse + sanitize with python3 → NUL-DELIMITED fields (kind, agent_type, message) ────────────
# NUL is the delimiter precisely because the untrusted message may contain ANY other byte
# (newlines included) — so a metacharacter in the message can never split a field or leak into the
# shell. python strips NULs from values, collapses control chars, and truncates the message to a
# signal length. Emits NOTHING (→ hook no-ops) on malformed JSON or a missing agent_type — the
# exact surface the RED-first selftest exercises with the REAL SubagentStop key names.
_PY='import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
agent = d.get("agent_type") or ""
if not agent:
    sys.exit(0)
event = d.get("hook_event_name") or ""
raw = d.get("last_assistant_message")
# Discriminate the lifecycle event: prefer the explicit event name; fall back to the presence of
# last_assistant_message (SubagentStop carries it, SubagentStart does not).
if event == "SubagentStart":
    kind = "start"
elif event == "SubagentStop":
    kind = "stop"
elif raw is not None:
    kind = "stop"
else:
    kind = "start"
def clean(s):
    out = []
    for ch in str(s):
        if ch == "\x00":
            continue
        if ch in ("\n", "\r", "\t"):
            out.append(" ")
        elif ch >= " ":
            out.append(ch)
    return "".join(out)
agent = clean(agent)
msg = clean(raw) if raw is not None else ""
if len(msg) > 280:
    msg = msg[:277] + "..."
sys.stdout.write(kind + "\x00" + agent + "\x00" + msg + "\x00")
'

_i=0; _kind=""; _agent=""; _msg=""
while IFS= read -r -d "" _val; do
  case "$_i" in
    0) _kind="$_val" ;;
    1) _agent="$_val" ;;
    2) _msg="$_val" ;;
  esac
  _i=$((_i + 1))
done < <(printf '%s' "$_ev" | python3 -c "$_PY" 2>/dev/null)

# No agent_type extracted (malformed / empty payload) → nothing to report; never block.
[ -n "$_agent" ] || exit 0

# ── Emit the spine writes through the shim ($agent / $msg pass as SINGLE quoted argv values — no
#    eval, no unquoted interpolation, so an injection in the message is inert). The shim's rc is
#    SWALLOWED (>/dev/null + no set -e) so a FATAL/missing-engine can never block the subagent. ───
if [ "$_kind" = "stop" ]; then
  "$MC" function "$_agent" done >/dev/null 2>&1
  [ -n "$_msg" ] && "$MC" log "$_agent" "$_msg" >/dev/null 2>&1
else
  "$MC" function "$_agent" working "spawned" >/dev/null 2>&1
fi

# ALWAYS exit 0 — telemetry must never block or fail the subagent turn.
exit 0
