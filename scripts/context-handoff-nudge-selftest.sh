#!/usr/bin/env bash
# context-handoff-nudge-selftest.sh — the trigger nothing owned, and the lanes that keep it honest.
#
# WHY THIS SUITE IS SHAPED LIKE THIS. The hook FAILS SILENT on every error path: a measurement is
# never worth costing a turn. That posture has one cost, and it is the whole reason this file
# exists — a hook that breaks and a hook with nothing to say produce byte-identical output. So the
# load-bearing lanes here are the POSITIVE ones: a fixture at high fill MUST produce a nudge. A
# suite that only proved "it stayed quiet" would pass against a hook deleted from disk.
#
# It also runs on EVERY user turn of every worker, so a regression is charged to the whole fleet
# once per turn — the same argument that put beat-nudge-selftest.sh in lefthook.yml.
set -uo pipefail
cd "$(dirname "$0")/.."
HOOK="$PWD/plugin/hooks/context-handoff-nudge.py"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/handoff-nudge.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/repo/.kickoff/state"

# A transcript whose NEWEST real record reads $2 tokens. Three records, so "last one wins" is
# actually exercised rather than trivially true on a single-line file.
mk() {
  python3 -c "
import json,sys
tok=int(sys.argv[2])
rows=[]
for i in range(3):
    rows.append({'message':{'model':'claude-opus-5','id':'m%d'%i,
                 'usage':{'input_tokens':10,'cache_read_input_tokens':tok-10,
                          'cache_creation_input_tokens':0}}})
open(sys.argv[1],'w').write('\n'.join(json.dumps(r) for r in rows)+'\n')" "$1" "$2"
}
run() {  # $1=session $2=transcript $3=cwd  [$4=hook override] → OUT / RC
  local h="${4:-$HOOK}"
  OUT="$(python3 -c "
import json,sys
print(json.dumps({'session_id':sys.argv[1],'transcript_path':sys.argv[2],'cwd':sys.argv[3]}))" \
    "$1" "$2" "$3" | python3 "$h" 2>/dev/null)"; RC=$?
}
says() { printf '%s' "$OUT" | grep -q "$1"; }

echo "▶ context-handoff-nudge self-test (the handoff TRIGGER — silent hooks need positive lanes)"
echo
echo "── the bands ──"
mk "$WORK/low.jsonl" 300000
run s-low "$WORK/low.jsonl" "$WORK/repo"
[ -z "$OUT" ] && [ "$RC" -eq 0 ] && ok "30% full ⇒ silent (a healthy session pays nothing)" \
  || bad "30% should be silent, got rc=$RC out=${OUT:-<empty>}"

mk "$WORK/mid.jsonl" 750000
run s-mid "$WORK/mid.jsonl" "$WORK/repo"
if says '"systemMessage"' && says '75%'; then ok "75% ⇒ NUDGE naming the real percentage"
else bad "75% should nudge with the number, got: ${OUT:-<empty>}"; fi
says 'Not urgent' && ok "…and the soft band says it is NOT urgent (a cry-wolf nudge gets ignored)" \
  || bad "soft band should be explicitly non-urgent, got: ${OUT:-<empty>}"

mk "$WORK/high.jsonl" 900000
run s-high "$WORK/high.jsonl" "$WORK/repo"
if says 'CONTEXT 90% FULL'; then ok "90% ⇒ ACT band, naming the real percentage"
else bad "90% should hit the act band, got: ${OUT:-<empty>}"; fi
# The steps are the POINT of the act band. An urgent message that does not say what to do is a
# nag; and the ORDER is load-bearing, because a refresh discards uncommitted work.
for step in 'commit the work' 'memory/' 'tracker' 'refresh-requested'; do
  says "$step" && ok "act band names the step: $step" || bad "act band omits the step: $step"
done
says 'Order matters' && ok "…and says the order matters (checkpoint BEFORE the refresh)" \
  || bad "act band must state that order matters"

echo
echo "── dedupe: per session AND per band ──"
run s-high "$WORK/high.jsonl" "$WORK/repo"
[ -z "$OUT" ] && ok "same session, same band, second turn ⇒ silent (no per-turn nagging)" \
  || bad "a repeat in the same band must be silent, got: ${OUT:-<empty>}"
# Crossing INTO the act band must still fire even though the soft band was already spent — the
# bug a single per-session marker would have: one nudge at 70% and then silence to 100%.
run s-mid "$WORK/high.jsonl" "$WORK/repo"
says 'CONTEXT 90% FULL' && ok "a session that already nudged SOFT still gets the ACT warning" \
  || bad "band escalation must not be swallowed by the soft marker, got: ${OUT:-<empty>}"
run s-other "$WORK/high.jsonl" "$WORK/repo"
says 'CONTEXT 90% FULL' && ok "a DIFFERENT session in the same repo is not silenced by the first" \
  || bad "markers must be per-session, got: ${OUT:-<empty>}"

echo
echo "── fail-open: nothing here may ever cost a turn ──"
printf 'not json' | python3 "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] && ok "unparseable stdin ⇒ exit 0, no output" || bad "bad stdin must exit 0"
run s-x "$WORK/does-not-exist.jsonl" "$WORK/repo"
[ -z "$OUT" ] && [ "$RC" -eq 0 ] && ok "missing transcript ⇒ silent, exit 0" || bad "missing transcript must be silent"
printf '{}' | python3 "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] && ok "empty payload (no session, no transcript) ⇒ exit 0" || bad "empty payload must exit 0"
OUT="$(python3 -c "
import json;print(json.dumps({'session_id':'s-off3','transcript_path':'$WORK/high.jsonl','cwd':'$WORK/repo'}))" \
  | HANDOFF_NUDGE=0 python3 "$HOOK" 2>/dev/null)"
[ -z "$OUT" ] && ok "HANDOFF_NUDGE=0 disables it (the escape hatch works)" || bad "HANDOFF_NUDGE=0 must silence it"

echo
echo "── the consumer's view ──"
mk "$WORK/c.jsonl" 950000
run s-parse "$WORK/c.jsonl" "$WORK/repo"
python3 -c "
import json,sys
s=sys.argv[1]
if s.strip(): json.loads(s)          # the WHOLE stdout must parse, never a substring match
" "$OUT" 2>/dev/null && ok "stdout is parseable JSON (or empty) — what the runtime actually does" \
  || bad "stdout must be valid JSON or empty, got: ${OUT:-<empty>}"
python3 -c "
import json,sys
d=json.load(open('plugin/hooks/hooks.json'))
hs=d['hooks']['UserPromptSubmit'][0]['hooks']
sys.exit(0 if any('context-handoff-nudge.py' in h.get('command','') for h in hs) else 1)" \
  && ok "shipped hooks.json WIRES it on UserPromptSubmit (an unwired hook ships inert and green)" \
  || bad "hooks.json does not register the hook — it would never run"
python3 -c "
import sys
w=open('scripts/context-headroom.py').read()
h=open('plugin/hooks/context-handoff-nudge.py').read()
sys.exit(0 if ('WINDOW = 1_000_000' in w and 'DEFAULT_WINDOW = 1_000_000' in h) else 1)" \
  && ok "the window matches scripts/context-headroom.py (same instrument, same number)" \
  || bad "window drifted from context-headroom.py — the hook would quote a contradicting percentage"

echo
echo "── negative control: prove these lanes can go RED ──"
STUB="$WORK/always-silent.py"
# Drains stdin before exiting: a stub that exits first makes the writer see EPIPE and print a
# BrokenPipeError over the suite's own output — noise that reads like a failure and is not.
printf '#!/usr/bin/env python3\nimport sys\nsys.stdin.read()\nsys.exit(0)\n' > "$STUB"
run s-neg "$WORK/high.jsonl" "$WORK/repo" "$STUB"
[ -z "$OUT" ] && ok "an always-silent stub produces nothing — so the positive lanes above are real" \
  || bad "the negative control itself emitted output; the suite proves nothing"

echo
echo "──────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "  ✅ the handoff trigger fires, escalates, dedupes per band, and never costs a turn"; exit 0; } || { echo "  ❌ see failures above"; exit 1; }
