#!/usr/bin/env bash
# beat-nudge-selftest.sh — RED-first lanes for plugin/hooks/beat-nudge.py
#
# The hook sits on EVERY user turn, in front of the operator's only channel. Three failure modes
# matter more than whether the nudge text is pretty:
#   1. it must never block or cost a turn (every bad input resolves to silence, exit 0);
#   2. it must never measure a DIFFERENT session — this box runs 7 orgs, several sessions can live
#      in one repo, and an adversarial pass broke the first version on exactly this twice; and
#   3. it must not become noise, or its reader learns to skip it.
# Every lane was watched going RED before it was allowed to pass; the last lane is a permanent
# negative control that proves this file can still fail.
#
# Two lanes exist because their absence already cost this project:
#   · the checker parses the WHOLE stdout the way the consumer does, never grepping a substring —
#     a suite that grepped once passed a mutant printing a stray line the real consumer could not
#     parse at all;
#   · a wiring lane asserts hooks.json actually invokes the hook, because one that is not wired
#     ships inert and green.
# And one lane exists because the FIXTURE was wrong rather than the code: the transcript-directory
# name is built here with the RUNTIME's encoding (non-alphanumerics -> '-'), not the hook's own
# rule. Building a fixture from the implementation's rule can only ever confirm the implementation.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HOOK="${BEAT_NUDGE_HOOK:-$REPO/plugin/hooks/beat-nudge.py}"
HOOKS_JSON="$REPO/plugin/hooks/hooks.json"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  [ ok ] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SEQ=0

# ── fixtures ────────────────────────────────────────────────────────────────────────────────
# One delivered telegram beat of N non-blank lines, with a stable tool_use id.
beat_record() { # $1=lines $2=tool $3=id
  python3 - "$1" "${2:-mcp__plugin_telegram_telegram__reply}" "${3:-tu_$1}" <<'PYEOF'
import json, sys
n, tool, tid = int(sys.argv[1]), sys.argv[2], sys.argv[3]
text = "\n".join("line %d" % i for i in range(n))
print(json.dumps({"message": {"content": [
    {"type": "tool_use", "id": tid, "name": tool, "input": {"text": text}}]}}))
PYEOF
}

# The result record the runtime writes back for a tool call. is_error=true is what a guard DENY
# looks like on disk — a beat the operator never received.
result_record() { # $1=tool_use_id $2=is_error(true|false)
  python3 - "$1" "$2" <<'PYEOF'
import json, sys
print(json.dumps({"message": {"content": [
    {"type": "tool_result", "tool_use_id": sys.argv[1],
     "is_error": sys.argv[2] == "true", "content": "telegram"}]}}))
PYEOF
}

payload() { # $1=transcript path (may be empty) $2=cwd $3=session_id
  python3 - "${1:-}" "${2:-}" "${3:-sess-1}" <<'PYEOF'
import json, sys
p = {"hook_event_name": "UserPromptSubmit", "prompt": "hi", "session_id": sys.argv[3]}
if sys.argv[1]:
    p["transcript_path"] = sys.argv[1]
if sys.argv[2]:
    p["cwd"] = sys.argv[2]
print(json.dumps(p))
PYEOF
}

# The RUNTIME's project-dir encoding — deliberately not the hook's rule.
cc_slug() { python3 -c 'import re,sys; print(re.sub(r"[^A-Za-z0-9]","-",sys.argv[1]))' "$1"; }

RC=0
OUT=""
run() { # $1=payload json, rest=env assignments ; sets OUT and RC
  local p="$1"; shift
  SEQ=$((SEQ+1))
  # Fresh state + log per invocation unless a lane pins them: the hook is once-per-measurement by
  # design, so sharing state across lanes would silence unrelated ones and read as a pass.
  #
  # CLAUDE_CONFIG_DIR is scrubbed unless a lane sets it. The transcript-derivation lanes govern the
  # projects root by pointing HOME at a fixture, but the hook honours CLAUDE_CONFIG_DIR FIRST (as
  # the CLI and this repo's own preflight.sh do) — so an ambient value silently redirected them to
  # a real config tree with no fixture in it, and four lanes went red inside the release gate while
  # passing on a bare shell. The code was right and the fixture was wrong: it assumed HOME governs
  # because HOME governed on MY box. A fixture that only holds under the environment its author
  # happened to have is the same defect as a check that cannot fail.
  OUT="$(printf '%s' "$p" | env -u CLAUDE_CONFIG_DIR BEAT_NUDGE_STATE="$TMP/state.$SEQ" BEAT_NUDGE_LOG="$TMP/log.$SEQ" \
        "$@" python3 "$HOOK" 2>/dev/null)"; RC=$?
}

# nudged? = stdout parses as JSON *as a whole* and carries the nudge, the way the consumer reads it.
# Written to a FILE and fed the hook's output on stdin. An earlier draft passed this program TO
# python via a stdin heredoc while also asking it to read the hook's output FROM stdin — so it read
# an empty string and answered "silent" for every input. Every lane asserting "silent" then passed
# regardless of what the hook did, including the negative control. It was caught only because one
# lane asserted on the measured NUMBERS instead and disagreed. A check that cannot tell its two
# answers apart is not a check.
CHECKER="$TMP/is_nudge.py"
cat > "$CHECKER" <<'PYEOF'
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    print("silent"); raise SystemExit
try:
    d = json.loads(raw)          # the WHOLE stdout, exactly as Claude Code parses it
except ValueError:
    print("UNPARSEABLE"); raise SystemExit
hso = d.get("hookSpecificOutput") or {}
if "permissionDecision" in hso or "decision" in d:
    print("DECIDES"); raise SystemExit   # this hook must never make a permission decision
if hso.get("additionalContext") and d.get("systemMessage"):
    print("nudge")
else:
    print("MALFORMED")
PYEOF
is_nudge() { python3 "$CHECKER"; }
verdict() { printf '%s' "$OUT" | is_nudge; }

printf '\n[beat-nudge selftest] %s\n\n' "$HOOK"

# ── clean vs long ───────────────────────────────────────────────────────────────────────────
T="$TMP/clean.jsonl"; : > "$T"
for n in 3 4 2 5 3; do beat_record "$n" >> "$T"; done
run "$(payload "$T" "$TMP")"; check "clean beats stay silent" "$(verdict)" "silent"
check "  ...and exit 0" "$RC" "0"

LONG="$TMP/long.jsonl"; : > "$LONG"
for n in 14 9 17 12 11; do beat_record "$n" >> "$LONG"; done
run "$(payload "$LONG" "$TMP")"
check "long beats nudge" "$(verdict)" "nudge"
check "  ...and exit 0" "$RC" "0"
case "$OUT" in *"14, 9, 17, 12, 11"*) ok "nudge carries the real measured numbers" ;;
                                   *) bad "nudge carries the real measured numbers" ;; esac
case "$OUT" in *permissionDecision*|*'"decision"'*) bad "must not emit a permission decision" ;;
                                                *) ok "no permission decision on the nudge path" ;; esac

# ── kill switches + knobs ───────────────────────────────────────────────────────────────────
run "$(payload "$LONG" "$TMP")" BEAT_NUDGE=0; check "BEAT_NUDGE=0 disables" "$(verdict)" "silent"
run "$(payload "$LONG" "$TMP")" BEAT_GUARD=0; check "BEAT_GUARD=0 disables too" "$(verdict)" "silent"
run "$(payload "$LONG" "$TMP")" BEAT_NUDGE_LINES=0; check "BEAT_NUDGE_LINES=0 -> silence" "$(verdict)" "silent"
run "$(payload "$LONG" "$TMP")" BEAT_NUDGE_WINDOW=0; check "BEAT_NUDGE_WINDOW=0 -> silence" "$(verdict)" "silent"
run "$(payload "$LONG" "$TMP")" BEAT_NUDGE_LINES=banana; check "unparseable knob -> default, still nudges" "$(verdict)" "nudge"

# ── never costs a turn ──────────────────────────────────────────────────────────────────────
run 'not json at all'; check "malformed payload -> silent" "$(verdict)" "silent"
check "  ...and exit 0" "$RC" "0"
run '{}'; check "empty payload -> silent" "$(verdict)" "silent"
run '[1,2,3]'; check "non-object payload -> silent" "$(verdict)" "silent"
check "  ...and exit 0" "$RC" "0"

# ── unresolvable transcript: silent, and the diagnostic stays ONE line ───────────────────────
LOG="$TMP/unresolved.log"
for _ in 1 2 3; do
  printf '%s' "$(payload "" "$TMP/nonexistent-project")" | env BEAT_NUDGE_LOG="$LOG" python3 "$HOOK" >/dev/null 2>&1
done
if [ -s "$LOG" ]; then ok "no transcript -> leaves a diagnostic"; else bad "no transcript -> leaves a diagnostic"; fi
check "diagnostic is bounded to one line after 3 turns" "$(wc -l < "$LOG" | tr -d ' ')" "1"
case "$(cat "$LOG")" in *20[0-9][0-9]-*) ok "the diagnostic is stamped, so a stale one reads as stale" ;;
                                      *) bad "the diagnostic is stamped, so a stale one reads as stale" ;; esac

# ── ...and the diagnostic is CLEARED the moment resolution works ─────────────────────────────
# It was written and never removed. A session's transcript does not exist yet when its FIRST turn
# fires, so essentially every session tripped this once and then carried a permanent flag saying
# "the hook is broken" — live in this repo's own .kickoff/state while resolution demonstrably
# worked. The hook's own docstring said "silence means it worked"; silence is not what an adopter
# got. Written-then-never-cleared is a state machine with one edge, which is not one.
CLR="$TMP/unresolved-clear.log"
printf '%s' "$(payload "" "$TMP/nonexistent-project")" | env BEAT_NUDGE_LOG="$CLR" python3 "$HOOK" >/dev/null 2>&1
if [ -s "$CLR" ]; then ok "  (flag is present before the resolved turn)"; else bad "  (flag is present before the resolved turn)"; fi
printf '%s' "$(payload "$LONG" "$TMP")" | env BEAT_NUDGE_LOG="$CLR" BEAT_NUDGE_STATE="$TMP/clear.state" python3 "$HOOK" >/dev/null 2>&1
if [ -e "$CLR" ]; then bad "a resolved turn clears the stale 'no transcript' flag"
else ok "a resolved turn clears the stale 'no transcript' flag"; fi

# ...and at the DERIVED <repo>/.kickoff/state path, unpinned. That derivation is where the live
# symptom sat (this repo's own state dir carried a permanent flag), so a lane that pins
# BEAT_NUDGE_LOG scrubs away the very carrier it is meant to cover. The clearing turn uses CLEAN
# beats on purpose: the flag is about RESOLUTION, so a silent turn must clear it just as a nudging
# one does — tying the clear to the nudge path would leave it set on every quiet session.
DREPO="$TMP/derived"; mkdir -p "$DREPO/.kickoff"
DFLAG="$DREPO/.kickoff/state/beat-nudge-unresolved.log"
dturn() { printf '%s' "$(payload "${1:-}" "$DREPO" "d-sess")" \
  | env -u CLAUDE_CONFIG_DIR -u BEAT_NUDGE_LOG -u BEAT_NUDGE_STATE python3 "$HOOK" >/dev/null 2>&1; }
dturn ""
if [ -s "$DFLAG" ]; then ok "  (derived path: a first turn with no transcript leaves the flag)"
else bad "  (derived path: a first turn with no transcript leaves the flag)"; fi
dturn "$TMP/clean.jsonl"
if [ -e "$DFLAG" ]; then bad "a later RESOLVED turn clears it at the derived path, nudge or not"
else ok "a later RESOLVED turn clears it at the derived path, nudge or not"; fi

# ── resolution by SESSION ID, from a subdirectory, under the RUNTIME's dir encoding ──────────
# The project path carries an underscore on purpose: the first version replaced only '/', so it
# could never find these dirs — and its own fixture, built with that same rule, could not tell.
FAKEHOME="$TMP/home"; PROJ="$TMP/my_proj"; SUB="$PROJ/mission-control/deep"
PDIR="$FAKEHOME/.claude/projects/$(cc_slug "$PROJ")"
mkdir -p "$PDIR" "$SUB" "$PROJ/.kickoff"
S="$PDIR/sess-A.jsonl"; : > "$S"
for n in 14 15 16; do beat_record "$n" >> "$S"; done
run "$(payload "" "$PROJ" "sess-A")" HOME="$FAKEHOME"
check "resolves by session id when the payload omits transcript_path" "$(verdict)" "nudge"
run "$(payload "" "$SUB" "sess-A")" HOME="$FAKEHOME"
check "still resolves from a SUBDIRECTORY cwd (walks up)" "$(verdict)" "nudge"

# ── a sibling session in the same project dir must NEVER be measured ─────────────────────────
# It is written LAST, so a newest-mtime resolver picks it — that was a real HIGH finding.
SIB="$PDIR/sess-B.jsonl"; : > "$SIB"
for n in 40 41 42; do beat_record "$n" "" "sib_$n" >> "$SIB"; done
run "$(payload "" "$PROJ" "sess-A")" HOME="$FAKEHOME"
case "$OUT" in *"14, 15, 16"*) ok "measures OUR session, not the sibling that wrote last" ;;
               *"40, 41, 42"*) bad "measured the SIBLING session's beats" ;;
                            *) bad "measured nothing (want our own session)" ;; esac

# ── HOSTILE: an ambient CLAUDE_PROJECT_DIR from ANOTHER org must not win ─────────────────────
# This box runs 7 orgs and their env leaks across invocations — the same class of bug that once
# stamped one org's channel onto three others' registry rows. Only the payload decides.
OTHER="$TMP/other"; ODIR="$FAKEHOME/.claude/projects/$(cc_slug "$OTHER")"
mkdir -p "$ODIR" "$OTHER"
O="$ODIR/sess-A.jsonl"; : > "$O"
for n in 30 31 32; do beat_record "$n" "" "oth_$n" >> "$O"; done
run "$(payload "" "$PROJ" "sess-A")" HOME="$FAKEHOME" CLAUDE_PROJECT_DIR="$OTHER"
case "$OUT" in *"14, 15, 16"*) ok "payload cwd beats an ambient CLAUDE_PROJECT_DIR" ;;
               *"30, 31, 32"*) bad "an ambient CLAUDE_PROJECT_DIR won (measured another org)" ;;
                            *) bad "payload cwd beats an ambient CLAUDE_PROJECT_DIR (no measurement)" ;; esac

# ── CLAUDE_CONFIG_DIR is honoured (preflight.sh does; hardcoding ~/.claude would miss it) ────
ALT="$TMP/altconfig"; ADIR="$ALT/projects/$(cc_slug "$PROJ")"
mkdir -p "$ADIR"
A="$ADIR/sess-C.jsonl"; : > "$A"
for n in 21 22 23; do beat_record "$n" "" "alt_$n" >> "$A"; done
run "$(payload "" "$PROJ" "sess-C")" HOME="$TMP/no-such-home" CLAUDE_CONFIG_DIR="$ALT"
check "CLAUDE_CONFIG_DIR is honoured" "$(verdict)" "nudge"

# ── an ambient CLAUDE_CONFIG_DIR wins over HOME (documented precedence) and must stay SILENT ──
# The positive case is the lane above. This is the hostile half: a config dir that exists but holds
# no transcript for this session must produce silence and rc=0 — never a crash, and never a
# measurement borrowed from whatever else lives there.
EMPTYCFG="$TMP/emptycfg"; mkdir -p "$EMPTYCFG/projects"
run "$(payload "" "$PROJ" "sess-A")" HOME="$FAKEHOME" CLAUDE_CONFIG_DIR="$EMPTYCFG"
check "an ambient CLAUDE_CONFIG_DIR with no transcript -> silent, not a crash" "$(verdict)" "silent"
check "  ...and exit 0" "$RC" "0"

# ── beats the guard DENIED were never delivered, so they must not be counted ─────────────────
# Sized so the two readings DISAGREE: counting the denied beats gives median 30 (nudge), counting
# only delivered ones gives 3.5 (silent). A lane whose two answers coincide proves nothing — the
# earlier draft of this lane was exactly that, and passed against the code it was meant to catch.
DEN="$TMP/denied.jsonl"; : > "$DEN"
for n in 30 31 32; do beat_record "$n" "" "tu_denied_$n" >> "$DEN"; result_record "tu_denied_$n" true >> "$DEN"; done
for n in 3 4; do beat_record "$n" "" "tu_ok_$n" >> "$DEN"; result_record "tu_ok_$n" false >> "$DEN"; done
run "$(payload "$DEN" "$TMP")"
check "a DENIED beat is not counted (only delivered ones)" "$(verdict)" "silent"

# ── once per measurement, not once per turn ─────────────────────────────────────────────────
ST="$TMP/seen.state"
printf '%s' "$(payload "$LONG" "$TMP")" | env BEAT_NUDGE_STATE="$ST" python3 "$HOOK" > "$TMP/first.out" 2>/dev/null
printf '%s' "$(payload "$LONG" "$TMP")" | env BEAT_NUDGE_STATE="$ST" python3 "$HOOK" > "$TMP/second.out" 2>/dev/null
check "first turn nudges" "$(is_nudge < "$TMP/first.out")" "nudge"
check "same measurement on the next turn stays silent" "$(is_nudge < "$TMP/second.out")" "silent"
beat_record 19 "" "tu_new" >> "$LONG"
printf '%s' "$(payload "$LONG" "$TMP")" | env BEAT_NUDGE_STATE="$ST" python3 "$HOOK" > "$TMP/third.out" 2>/dev/null
check "a NEW long beat nudges again" "$(is_nudge < "$TMP/third.out")" "nudge"

# ── ...and it survives a SIBLING SESSION in the same repo ────────────────────────────────────
# The lane above drives ONE session, which is precisely the case that cannot see this: the marker
# was a single shared file per REPO with the session id inside the VALUE, opened truncating. A
# wrote its key, B overwrote it, A read B's and mismatched — so BOTH sessions nudged on EVERY
# turn, one injected context line plus one user-visible systemMessage each, forever. "Only once
# per new measurement" is what the changelog sells; two sessions in one repo de-duplicated
# nothing, which is the same "trains its reader to ignore it" failure the dedupe exists to stop,
# billed per turn across the fleet.
#
# This lane deliberately does NOT pin BEAT_NUDGE_STATE: the shared <repo>/.kickoff/state path is
# the thing that carried the bug, and a fixture that scrubs it away would only ever confirm the
# case that already worked. Only the ambient value is scrubbed, so a caller's env cannot decide it.
MREPO="$TMP/multi"; mkdir -p "$MREPO/.kickoff"
MA="$TMP/multi-a.jsonl"; : > "$MA"; for n in 14 15 16; do beat_record "$n" "" "ma_$n" >> "$MA"; done
MB="$TMP/multi-b.jsonl"; : > "$MB"; for n in 20 21 22; do beat_record "$n" "" "mb_$n" >> "$MB"; done
mrun() { # $1=session id, $2=transcript -> prints the verdict for one turn of that session
  printf '%s' "$(payload "$2" "$MREPO" "$1")" \
    | env -u CLAUDE_CONFIG_DIR -u BEAT_NUDGE_STATE -u BEAT_NUDGE_LOG python3 "$HOOK" 2>/dev/null | is_nudge
}
check "session A's first turn in a shared repo nudges" "$(mrun m-sess-A "$MA")" "nudge"
check "session B's first turn nudges its OWN measurement" "$(mrun m-sess-B "$MB")" "nudge"
AR=""; BR=""
for _ in 1 2 3; do AR="$AR$(mrun m-sess-A "$MA"),"; BR="$BR$(mrun m-sess-B "$MB"),"; done
check "A stays silent across 3 interleaved rounds with B" "$AR" "silent,silent,silent,"
check "B stays silent across 3 interleaved rounds with A" "$BR" "silent,silent,silent,"
case "$(ls "$MREPO/.kickoff/state" 2>/dev/null | wc -l | tr -d ' ')" in
  2) ok "each session owns its own marker file (2 in the shared repo)" ;;
  *) bad "each session owns its own marker file (got: $(ls "$MREPO/.kickoff/state" 2>/dev/null | tr '\n' ' '))" ;;
esac

# ── ...and a caller PINNING BEAT_NUDGE_STATE cannot pin the shared-file world back either ────
# The lane above scrubs BEAT_NUDGE_STATE on purpose, so that the real <repo>/.kickoff/state path —
# the one that carried the bug — is what gets exercised. That is right, and it left the OVERRIDE
# path defended by nothing: the dedupe lane pins the variable but drives ONE session, this lane
# drives two but unsets it, and no lane anywhere ran two sessions through a pinned base. So
# `return override + suffix` -> `return override` survived all 50 lanes of this suite.
#
# That mutant is exactly the shared-mutable-file bug, reachable through an env var: both sessions
# resolve to one path, A writes its measurement, B overwrites it, A reads B's and mismatches, and
# both nudge forever. _state_path's docstring makes it a stated GUARANTEE — "BEAT_NUDGE_STATE names
# a BASE path and takes the same suffix, so no caller — a test fixture included — can pin the
# one-file-per-repo world back into existence" — and a guarantee no lane can falsify is decoration.
# Adopter impact is nil (BEAT_NUDGE_STATE is test-only and absent from hooks.json); the point is
# that the sentence is now checked rather than believed.
#
# This is the HOSTILE half of the pair: the lane above unsets the variable so the fixture's own
# world is clean, this one hands the hook a caller's value and asserts the per-session split
# survives it anyway. A scrub that buys determinism is also capable of deleting the bug's carrier,
# so the carrier gets its own lane rather than a cleverer scrub.
PIN="$TMP/pinned.state"
prun() { # $1=session id, $2=transcript -> the verdict for one turn, BEAT_NUDGE_STATE PINNED
  printf '%s' "$(payload "$2" "$MREPO" "$1")" \
    | env -u CLAUDE_CONFIG_DIR -u BEAT_NUDGE_LOG BEAT_NUDGE_STATE="$PIN" python3 "$HOOK" 2>/dev/null | is_nudge
}
check "pinned state: session A's first turn nudges" "$(prun p-sess-A "$MA")" "nudge"
check "pinned state: session B's first turn nudges its OWN measurement" "$(prun p-sess-B "$MB")" "nudge"
# The order matters: B wrote through the same base path between A's two turns. With a flat
# override A now reads B's key, mismatches, and nudges again — which is the inverted dedupe.
check "pinned state: A is still deduped after B wrote through the same base path" \
      "$(prun p-sess-A "$MA")" "silent"
check "pinned state: B is still deduped after A wrote through the same base path" \
      "$(prun p-sess-B "$MB")" "silent"
case "$(ls "$TMP" | /usr/bin/grep -c '^pinned\.state-')" in
  2) ok "the pinned base took a session suffix (2 marker files, not 1 shared one)" ;;
  *) bad "the pinned base did NOT split per session (got: $(ls "$TMP" | /usr/bin/grep '^pinned\.state' | tr '\n' ' '))" ;;
esac
# A hostile session id lands in a FILENAME: it must not escape the state dir.
printf '%s' "$(payload "$MA" "$MREPO" "../../../../escaped")" \
  | env -u CLAUDE_CONFIG_DIR -u BEAT_NUDGE_STATE python3 "$HOOK" >/dev/null 2>&1
if [ -e "$TMP/escaped" ] || [ -e "$MREPO/escaped" ] || [ -e "$MREPO/.kickoff/escaped" ]
then bad "a hostile session id escaped the state directory"
else ok "a hostile session id cannot escape the state directory"; fi

# ── counting rules ──────────────────────────────────────────────────────────────────────────
T="$TMP/mixed.jsonl"; : > "$T"
beat_record 14 "" a >> "$T"; printf '{"message": {"content": "telegram not-a-list"}}\n' >> "$T"
printf 'telegram {broken json\n' >> "$T"; beat_record 15 "" b >> "$T"; beat_record 16 "" c >> "$T"
run "$(payload "$T" "$TMP")"
case "$OUT" in *"14, 15, 16"*) ok "tolerates malformed records mid-transcript" ;;
                            *) bad "tolerates malformed records mid-transcript" ;; esac

T="$TMP/blank.jsonl"
python3 - "$T" <<'PYEOF'
import json, sys
text = "\n\n".join("line %d" % i for i in range(5))   # 5 real lines, 9 with the blanks
open(sys.argv[1], "w").write(json.dumps({"message": {"content": [
    {"type": "tool_use", "id": "x", "name": "mcp__plugin_telegram_telegram__reply",
     "input": {"text": text}}]}}) + "\n")
PYEOF
run "$(payload "$T" "$TMP")"; check "blank lines are not counted (5 real < 7)" "$(verdict)" "silent"

T="$TMP/othertool.jsonl"; : > "$T"
for n in 30 31 32; do beat_record "$n" "mcp__plugin_telegram_telegram__react" "r_$n" >> "$T"; done
run "$(payload "$T" "$TMP")"; check "a non-beat telegram tool is ignored" "$(verdict)" "silent"
T="$TMP/nontg.jsonl"; : > "$T"
for n in 30 31 32; do beat_record "$n" "Bash" "b_$n" >> "$T"; done
run "$(payload "$T" "$TMP")"; check "a non-telegram tool is ignored" "$(verdict)" "silent"

T="$TMP/case.jsonl"; : > "$T"
for n in 14 15 16; do beat_record "$n" "MCP__Plugin_TELEGRAM_x__reply" "u_$n" >> "$T"; done
run "$(payload "$T" "$TMP")"
check "case-insensitive tool match agrees with the prefilter" "$(verdict)" "nudge"

T="$TMP/window.jsonl"; : > "$T"
for n in 40 41 42 43 44; do beat_record "$n" "" "w_$n" >> "$T"; done
for n in 2 3 2 3 2; do beat_record "$n" "" "s_$n" >> "$T"; done
run "$(payload "$T" "$TMP")"
check "window=5 measures the RECENT beats, not the whole session" "$(verdict)" "silent"

# ── RUNTIME BUDGET — this runs on EVERY user turn of EVERY adopter ───────────────────────────
# Nothing in this suite bounded the hook's runtime, so a mutant with `time.sleep(30)` at the top
# of main() passed all of it. Production wires it under `timeout: 10` and the `|| true` belt does
# NOT cover a timeout kill — a slow regression here is a stall charged to every turn of every
# adopter, which is exactly the cost class this gate exists to catch. Measured against a real-
# sized transcript, not a toy one: the shape that costs time is the whole-file scan, not the beats.
# The budget is deliberately generous (this box is shared and loaded); it catches an order-of-
# magnitude regression, not jitter.
BIG="$TMP/big.jsonl"
python3 - "$BIG" <<'PYEOF'
import json, sys
target = 30 * 1024 * 1024
beat = lambda n, tid: json.dumps({"message": {"content": [
    {"type": "tool_use", "id": tid, "name": "mcp__plugin_telegram_telegram__reply",
     "input": {"text": "\n".join("line %d" % i for i in range(n))}}]}})
# Bulk that the hook's cheap prefilter skips — the realistic majority of a real transcript.
filler = json.dumps({"type": "assistant", "message": {"content": [
    {"type": "text", "text": "x" * 400}]}})
written = 0
i = 0
with open(sys.argv[1], "w") as fh:
    while written < target:
        i += 1
        rec = beat(12 + (i % 5), "big_%d" % i) if i % 200 == 0 else filler
        fh.write(rec + "\n")
        written += len(rec) + 1
PYEOF
BIG_MB=$(( $(wc -c < "$BIG") / 1048576 ))
BUDGET_MS=2000
T0=$(date +%s%N)
run "$(payload "$BIG" "$TMP")"
ELAPSED_MS=$(( ($(date +%s%N) - T0) / 1000000 ))
check "the big fixture still nudges (so the clock is on the REAL path)" "$(verdict)" "nudge"
if [ "$ELAPSED_MS" -le "$BUDGET_MS" ]
then ok "runtime is bounded: ${ELAPSED_MS}ms on a ${BIG_MB}MB transcript (budget ${BUDGET_MS}ms)"
else bad "runtime BLEW the budget: ${ELAPSED_MS}ms on a ${BIG_MB}MB transcript (budget ${BUDGET_MS}ms)"; fi

# ── the SHIPPED wiring — a hook nobody wires is inert and green ──────────────────────────────
if python3 - "$HOOKS_JSON" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
hooks = d.get("hooks", d)
ups = hooks.get("UserPromptSubmit") or []
cmds = [h.get("command", "") for entry in ups for h in (entry.get("hooks") or [])]
mine = [c for c in cmds if "beat-nudge.py" in c]
assert mine, "beat-nudge.py is NOT wired into UserPromptSubmit"
assert all("|| true" in c for c in mine), "beat-nudge wiring lacks the || true belt"
PYEOF
then ok "hooks.json wires beat-nudge.py on UserPromptSubmit"; else bad "hooks.json wires beat-nudge.py on UserPromptSubmit"; fi

# ── NEGATIVE CONTROL — the same input that nudges must go silent on a stub ───────────────────
STUB="$TMP/stub.py"; printf 'import sys\nsys.exit(0)\n' > "$STUB"
SAVED="$HOOK"; HOOK="$STUB"
run "$(payload "$LONG" "$TMP")"
if [ "$(verdict)" = "silent" ]; then ok "negative control: lane-2's input goes SILENT on a stub (this suite can go RED)"
else bad "negative control did not behave as expected"; fi
HOOK="$SAVED"

printf '\n[beat-nudge selftest] %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
