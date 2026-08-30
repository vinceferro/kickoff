#!/usr/bin/env bash
# beat-length-guard-selftest.sh — prove the guard bites AND that it can never gag the worker.
#
#   bash scripts/beat-length-guard-selftest.sh
#
# This guard sits in front of the ONLY channel to the operator, which makes its two failure modes
# wildly asymmetric. Denying one runaway message costs a rewrite. Denying every message costs the
# operator his worker — silently, because the way you would report the problem is the thing that
# broke. So the suite is weighted accordingly: the fail-open lanes outnumber the enforcement ones,
# and every one of them feeds the guard something genuinely malformed rather than a tidy fixture.
#
# The suite also pins the TWO-TIER shape, which exists because of a correction from the operator
# (2026-08-10): "I don't mind receiving a long text if the situation actually requires it. I just
# need to be able to follow it logically." A single hard cap fails in the expensive direction — it
# makes a warranted long answer unsendable. So the soft zone must ALLOW, and there is a dedicated
# lane proving it allows rather than merely proving the hard zone denies.
#
# RED-first throughout: each lane is watched failing on the input it exists to catch. The last lane
# is the negative control — a deliberately broken guard that always allows — because a suite that
# has never seen itself go red is measuring nothing. A guard nobody has watched fail is not a guard.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/../plugin/hooks/beat-length-guard.py"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }

# Feed the guard a hook payload; echo whatever it emits on stdout.
run() { printf '%s' "$1" | python3 "$GUARD" 2>/dev/null; }

# Build a PreToolUse payload with an arbitrary tool name and text.
payload() {
  python3 -c '
import json,sys
print(json.dumps({"hook_event_name":"PreToolUse","tool_name":sys.argv[1],
                  "tool_input":{"text":sys.argv[2]}}))' "$1" "$2"
}

# "Denied" is the only outcome that stops a message. Empty output and an annotation-only nudge are
# BOTH delivery — the fail-open lanes must accept either, or they would fail the moment a nudge fires.
#
# This PARSES the output rather than grepping it, because a grep asserts on the wrong thing: the
# consumer is Claude Code, which json.loads() the whole of stdout. A guard that printed one stray
# line before its JSON would still contain the substring "permissionDecision": "deny" and satisfy a
# grep, while the real consumer failed to parse it and the guard shipped inert. Mutation-tested: that
# exact mutant passed 20/20 under the old grep and is caught here. Assert on what the SYSTEM
# consumes, never on your own bookkeeping.
denied() {
  [ -n "$1" ] || return 1
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    o = json.loads(sys.stdin.read())
except Exception:
    sys.exit(2)   # unparseable: the consumer can act on nothing, so it is NOT a deny
sys.exit(0 if (o.get("hookSpecificOutput") or {}).get("permissionDecision") == "deny" else 1)'
}

# Whatever the guard writes must be parseable JSON on EVERY path, or the consumer cannot act on it.
parseable() {
  [ -z "$1" ] && return 0
  printf '%s' "$1" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null
}

lines_of() { python3 -c 'import sys; print("\n".join("line %d" % i for i in range(1,int(sys.argv[1])+1)))' "$1"; }

TG=mcp__plugin_telegram_telegram__reply
SHORT="all good, shipped it"
SOFT="$(lines_of 12)"     # between the nudge and the cap — long, but warranted-long
RUNAWAY="$(lines_of 25)"  # past any reasonable beat
WIDE="$(python3 -c 'print("x"*2500)')"

echo "▶ beat-length-guard self-test (the guard in front of the only channel out)"
echo
echo "── the hard tier: runaway is stopped ──"

out="$(run "$(payload "$TG" "$RUNAWAY")")"
if denied "$out"; then ok "25-line beat is DENIED"
else bad "25-line beat should be denied, got: ${out:-<empty>}"; fi

if printf '%s' "$out" | grep -q '25 lines'; then
  ok "deny reason names the measured line count"
else
  bad "deny reason should name '25 lines', got: ${out:-<empty>}"
fi

out="$(run "$(payload "$TG" "$WIDE")")"
if denied "$out"; then ok "2500-char single-line beat is DENIED (chars, not just lines)"
else bad "2500-char beat should be denied, got: ${out:-<empty>}"; fi

out="$(run "$(payload "mcp__plugin_telegram_telegram__edit_message" "$RUNAWAY")")"
if denied "$out"; then ok "edit_message is guarded too (he reads edits as well)"
else bad "edit_message should be guarded, got: ${out:-<empty>}"; fi

echo
echo "── the soft tier: long-but-warranted still gets through ──"
# The lane that encodes his correction. If this ever goes red, the guard has silently become the
# single hard cap he explicitly rejected.
out="$(run "$(payload "$TG" "$SOFT")")"
if denied "$out"; then
  bad "12-line beat MUST be allowed — a warranted long message has to be sendable"
else
  ok "12-line beat is ALLOWED (not denied)"
fi
if printf '%s' "$out" | grep -q 'logical order'; then
  ok "soft tier still nudges about followability"
else
  bad "soft tier should carry a followability nudge, got: ${out:-<empty>}"
fi

# A nudge must ANNOTATE, never decide. An explicit "allow" auto-approves the call and skips whatever
# permission prompt the operator configured — which would invert an adopter's own settings: short
# beats prompt, long ones sail through silently. Two independent adversarial reviewers flagged this
# on the same candidate; the lane exists so it cannot come back.
if printf '%s' "$out" | grep -q 'permissionDecision'; then
  bad "soft-tier nudge MUST NOT carry a permissionDecision (an explicit allow auto-approves)"
else
  ok "soft-tier nudge carries no permissionDecision (annotates, does not decide)"
fi

# THE CEILING ITSELF, pinned. Until now the only hard-tier payload was 25 lines — far past any
# plausible cap — so the suite stayed green across a change from 20 to 12 and would have stayed
# green at 40. The constant is policy the operator chose, not an implementation detail, and nothing
# asserted where it sits. These two lanes are the whole assertion: exactly at the ceiling sends,
# one line over does not. They also protect the lane above, which now sits ON the boundary with
# zero margin: lower the cap without updating both and the failure names itself.
out="$(run "$(payload "$TG" "$(lines_of 12)")")"
if denied "$out"; then bad "12 lines is AT the ceiling and must send (cap moved below the documented default)"
else ok "boundary: 12 lines (exactly at the ceiling) is allowed"; fi
out="$(run "$(payload "$TG" "$(lines_of 13)")")"
if denied "$out"; then ok "boundary: 13 lines (one over) is DENIED — the ceiling is where it says it is"
else bad "13 lines must be denied — the 12-line ceiling is not being enforced"; fi

echo
echo "── the gag path: a mis-set knob must never deny everything ──"
# BEAT_GUARD=0 means "off", so "set it to 0 to turn it off" is the natural misread of the threshold
# knobs sitting beside it. Read literally, max_lines=0 denies EVERY message — the silent gag this
# whole file exists to prevent, behind a one-word typo.
for knob in "BEAT_MAX_LINES=0" "BEAT_MAX_LINES=-5" "BEAT_MAX_CHARS=0" "BEAT_NUDGE_LINES=0"; do
  out="$(printf '%s' "$(payload "$TG" "$SHORT")" | env "$knob" python3 "$GUARD" 2>/dev/null)"
  if denied "$out"; then
    bad "$knob GAGS a short beat — a mis-set knob must degrade toward delivery"
  else
    ok "allows: $knob on a short beat (knob <= 0 disables that dimension)"
  fi
done
out="$(printf '%s' "$(payload "$TG" "$RUNAWAY")" | BEAT_MAX_LINES=0 python3 "$GUARD" 2>/dev/null)"
if denied "$out"; then
  bad "BEAT_MAX_LINES=0 still denies a 25-line beat — the dimension is not actually disabled"
else
  ok "allows: BEAT_MAX_LINES=0 disables the line dimension even for a runaway beat"
fi

echo
echo "── fail-open: nothing here may ever block a message ──"

for case in \
  "short beat|$(payload "$TG" "$SHORT")" \
  "unrelated tool (Bash) with a long command|$(payload "Bash" "$RUNAWAY")" \
  "unrelated MCP tool|$(payload "mcp__probe__shout" "$RUNAWAY")" \
  "malformed JSON|not json at all" \
  "empty stdin|" \
  "missing tool_input|{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"$TG\"}" \
  "text is null|{\"tool_name\":\"$TG\",\"tool_input\":{\"text\":null}}" \
  "text is a number|{\"tool_name\":\"$TG\",\"tool_input\":{\"text\":12345}}" \
  "whitespace-only text|{\"tool_name\":\"$TG\",\"tool_input\":{\"text\":\"   \"}}" \
  ; do
  name="${case%%|*}"; body="${case#*|}"
  out="$(run "$body")"; rc=$?
  if ! denied "$out" && [ "$rc" -eq 0 ]; then
    ok "allows: $name"
  else
    bad "MUST allow ($name) — emitted '${out:-<empty>}' rc=$rc"
  fi
done

# A blank line is a paragraph break. Counting it would punish the readable formatting we want.
SPACED="$(python3 -c 'print("\n\n".join("line %d" % i for i in range(1,6)))')"
out="$(run "$(payload "$TG" "$SPACED")")"
if [ -z "$out" ]; then
  ok "allows silently: 5 lines spaced with blank lines (blank lines are not content)"
else
  bad "blank-line-spaced beat should pass with no output, got: $out"
fi

out="$(printf '%s' "$(payload "$TG" "$SHORT")" | BEAT_MAX_LINES=abc python3 "$GUARD" 2>/dev/null)"
if ! denied "$out"; then ok "allows: unparseable BEAT_MAX_LINES falls back to the default"
else bad "bad env knob should degrade to default, got: $out"; fi

out="$(printf '%s' "$(payload "$TG" "$RUNAWAY")" | BEAT_GUARD=0 python3 "$GUARD" 2>/dev/null)"
if [ -z "$out" ]; then ok "allows: BEAT_GUARD=0 disables enforcement entirely (the escape hatch works)"
else bad "BEAT_GUARD=0 should disable the guard, got: $out"; fi

out="$(printf '%s' "$(payload "$TG" "$RUNAWAY")" | BEAT_MAX_LINES=50 BEAT_MAX_CHARS=9000 BEAT_NUDGE_LINES=99 python3 "$GUARD" 2>/dev/null)"
if [ -z "$out" ]; then ok "allows: a raised ceiling lets the same 25-line beat through"
else bad "raised ceiling should allow the runaway beat, got: $out"; fi

echo
echo "── the consumer's view: stdout must PARSE, and the wiring must reach it ──"
# Claude Code json.loads() the whole of stdout. Anything unparseable on any path is a guard the
# consumer cannot act on — inert, and silently so.
allparse=1
for body in "$(payload "$TG" "$RUNAWAY")" "$(payload "$TG" "$SOFT")" "$(payload "$TG" "$SHORT")" \
            "$(payload "$TG" "$WIDE")" "$(payload "Bash" "$RUNAWAY")" "not json at all"; do
  parseable "$(run "$body")" || allparse=0
done
[ "$allparse" -eq 1 ] && ok "every emitting path produces parseable JSON (or nothing at all)" \
                      || bad "some path emitted unparseable stdout — the consumer sees an inert guard"

# The guard being correct is worthless if nothing invokes it. A suite that only pipes into the
# script by hand would stay green while a merge dropped the wiring — so assert the SHIPPED wiring,
# and fullmatch its matcher against a tool name observed in real transcripts.
python3 - "$HERE/../plugin/hooks/hooks.json" <<'PY' && ok "shipped hooks.json wires the guard, and its matcher matches the REAL tool name" || bad "shipped hooks.json wiring is missing, misrouted, or its matcher does not match the real tool name"
import json, re, sys
blocks = json.load(open(sys.argv[1]))["hooks"].get("PreToolUse") or []
for b in blocks:
    if not any("beat-length-guard.py" in h.get("command", "") for h in b.get("hooks") or []):
        continue
    pat = b.get("matcher") or ""
    real = ["mcp__plugin_telegram_telegram__reply", "mcp__plugin_telegram_telegram__edit_message"]
    never = ["mcp__plugin_telegram_telegram__react", "Bash"]
    if all(re.fullmatch(pat, t) for t in real) and not any(re.fullmatch(pat, t) for t in never):
        sys.exit(0)
sys.exit(1)
PY

echo
echo "── negative control: prove this suite can go RED ──"
# A guard that always allows must FAIL the hard-tier lanes. Without this, a guard that silently
# stopped working would sail through every fail-open check, since "does not deny" is their pass
# condition — the always-allow stub passes those trivially and must still be caught here.
BROKEN="$(mktemp)"; printf '#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n' > "$BROKEN"
out="$(printf '%s' "$(payload "$TG" "$RUNAWAY")" | python3 "$BROKEN" 2>/dev/null)"
rm -f "$BROKEN"
if ! denied "$out"; then
  ok "an always-allow stub does NOT deny the runaway — so the hard-tier lanes above are real"
else
  bad "negative control is broken: the stub guard emitted '$out'"
fi

echo
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
