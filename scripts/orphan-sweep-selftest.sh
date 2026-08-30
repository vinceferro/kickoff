#!/usr/bin/env bash
# orphan-sweep-selftest.sh — proof of orphaned-work-sweep.py's three rules.
#
# The sweep mails other orgs unprompted, on a cadence, with no human in the loop. That is
# exactly the shape where a quiet bug becomes noise in someone else's inbox — so each rule
# gets a lane AND a mutant proving the lane can fail.
#
# HERMETIC: a fake orphaned-work.py + a fake agent-mail.py are dropped in a scratch dir and the
# sweep is pointed at THEM by copying the sweep beside them. That is load-bearing — the sweep
# resolves its siblings from its OWN location ($0), so a copy run from elsewhere would drive the
# REAL tools against the REAL box and mail live orgs from a test. Never point this at $HOME.
#
# Usage: bash scripts/orphan-sweep-selftest.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWEEP="$SCRIPT_DIR/orphaned-work-sweep.py"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/orphan-sweep-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$1" = "$2" ]; then ok "$3 (=$1)"; else bad "$3 (want=$2 got=$1)"; fi; }

# ── the fixture bin: fakes the sweep will drive ──────────────────────────────
BIN="$WORK/bin"; mkdir -p "$BIN"
cp "$SWEEP" "$BIN/orphaned-work-sweep.py"

# fake orphaned-work.py — emits a fixed corpus covering every tier we care about
cat > "$BIN/orphaned-work.py" <<'PY'
import json, sys
if "--json" not in sys.argv:
    print("selftest fake: only --json is implemented"); sys.exit(2)
print(json.dumps({"generated_at": "2026-08-13T00:00:00Z", "days": 14, "runs": [
  {"tier":"died_mid_run","repo":"orgA","run":"wf_aaa","at":"2026-08-10T20:46:00Z",
   "mtime":1786567560,"returned":2,"killed":1,"chars":22231,"live":False},
  {"tier":"died_mid_run","repo":"orgA","run":"wf_bbb","at":"2026-08-01T01:44:00Z",
   "mtime":1785894240,"returned":10,"killed":1,"chars":146570,"live":False},
  {"tier":"died_mid_run","repo":"orgB","run":"wf_ccc","at":"2026-08-12T18:18:00Z",
   "mtime":1786558680,"returned":0,"killed":4,"chars":0,"live":False},
  {"tier":"all_returned","repo":"orgC","run":"wf_ddd","at":"2026-08-11T09:00:00Z",
   "mtime":1786467600,"returned":3,"killed":0,"chars":9999,"live":False},
  {"tier":"died_mid_run","repo":"SELFORG","run":"wf_self","at":"2026-08-09T09:00:00Z",
   "mtime":1786381200,"returned":1,"killed":1,"chars":4242,"live":False}
]}))
PY

# fake agent-mail.py — records every send instead of delivering it
cat > "$BIN/agent-mail.py" <<'PY'
import os, sys
LOG = os.environ["SENDLOG"]
if len(sys.argv) > 1 and sys.argv[1] == "whoami":
    print(os.environ.get("FAKE_ME", "SELFORG")); sys.exit(0)
if len(sys.argv) > 1 and sys.argv[1] == "send":
    to = sys.argv[sys.argv.index("--to") + 1]
    subj = sys.argv[sys.argv.index("--subject") + 1] if "--subject" in sys.argv else ""
    body = sys.stdin.read()
    if os.environ.get("FAIL_FOR") == to:
        sys.stderr.write("fixture: refusing to deliver to %s\n" % to); sys.exit(3)
    with open(LOG, "a") as fh:
        fh.write("SEND\t%s\t%s\t%d\n" % (to, subj, len(body)))
    with open(os.path.join(os.path.dirname(LOG), "body.%s.md" % to), "w") as fh:
        fh.write(body)
    print("sent to %s" % to); sys.exit(0)
sys.exit(9)
PY

SENDLOG="$WORK/sends.tsv"; export SENDLOG
: > "$SENDLOG"
STATE="$WORK/state.json"
run_sweep() { ( cd "$WORK" && python3 "$BIN/orphaned-work-sweep.py" --state "$STATE" "$@" ) 2>"$WORK/err.txt"; }

# grep -c PRINTS 0 and RETURNS 1 on no-match, so `grep -c … || echo 0` emits TWO zeroes and the
# check reads "0\n0" — a want=0 got=0-looking failure that costs a minute to see. Capture instead.
sends_to() { local n; n="$(grep -c "^SEND	$1	" "$SENDLOG" 2>/dev/null)"; printf '%s' "${n:-0}"; }

# ── RULE 1: only died_mid_run is mailed; all_returned is never a finding ─────
run_sweep --days 14 > "$WORK/out1.txt"
check "$(sends_to orgA)" 1 "(r1) orgA — the org with dead runs was mailed"
check "$(sends_to orgB)" 1 "(r1) orgB — the returned-nothing org was mailed too"
check "$(sends_to orgC)" 0 "(r1) orgC (all_returned only) was NOT mailed — a candidate is not a finding"

# ── RULE 3: never mail yourself; report it locally instead ───────────────────
check "$(sends_to SELFORG)" 0 "(r3) the sweep did NOT mail its own org"
check "$(grep -c 'wf_self' "$WORK/out1.txt")" 1 "(r3) ...but it DID surface its own finding to stdout"

# ── body correctness: the worked example cites the BIGGEST salvage ───────────
check "$(grep -c 'dump wf_bbb' "$WORK/body.orgA.md")" 1 "(body) orgA's example cites the 146k run, not the 22k one"
check "$(grep -c 'Nothing to salvage' "$WORK/body.orgB.md")" 1 "(body) orgB is told plainly there is nothing to read"
check "$(grep -c 'DATED' "$WORK/body.orgA.md")" 1 "(body) the stale-findings warning rides along with a salvage"

# ── RULE 2: notify once — a second sweep must be silent ──────────────────────
: > "$SENDLOG"
run_sweep --days 14 > "$WORK/out2.txt"
check "$(wc -l < "$SENDLOG")" 0 "(r2) a second sweep mails NOTHING — every run already notified"
check "$(grep -c 'nothing new' "$WORK/out2.txt")" 1 "(r2) ...and says so"

# ── RULE 2 negative control: the lane above must be able to FAIL ─────────────
# Without this, "0 sends" would also be what a totally broken sweep produces.
: > "$SENDLOG"
run_sweep --days 14 --state "$WORK/fresh-state.json" > /dev/null
check "$(wc -l < "$SENDLOG")" 2 "(r2-control) a FRESH ledger re-sends both orgs — so 0 above meant dedupe, not breakage"

# ── a FAILED send is not recorded as notified (it must retry next sweep) ─────
: > "$SENDLOG"
FS="$WORK/retry-state.json"
FAIL_FOR=orgA run_sweep --days 14 --state "$FS" > /dev/null
rc_failed=$?
check "$rc_failed" 1 "(retry) the sweep exits non-zero when a send fails"
check "$(python3 -c "
import json;d=json.load(open('$FS'))
print(sum(1 for k,v in d.items() if v['repo']=='orgA'))" 2>/dev/null || echo ERR)" 0 \
  "(retry) orgA's runs were NOT marked notified after the failed send"
: > "$SENDLOG"
run_sweep --days 14 --state "$FS" > /dev/null
check "$(sends_to orgA)" 1 "(retry) ...so the NEXT sweep retries orgA"

# ── --dry-run sends nothing and records nothing ──────────────────────────────
: > "$SENDLOG"
DS="$WORK/dry-state.json"
run_sweep --days 14 --dry-run --state "$DS" > "$WORK/dry.txt"
check "$(wc -l < "$SENDLOG")" 0 "(dry) --dry-run sent nothing"
check "$([ -f "$DS" ] && echo wrote || echo none)" "none" "(dry) --dry-run recorded nothing"
check "$(grep -c 'would mail orgA' "$WORK/dry.txt")" 1 "(dry) ...but it showed what it would send"

# ── a corrupt ledger must WARN, not silently re-nag ──────────────────────────
: > "$SENDLOG"
CS="$WORK/corrupt.json"; printf 'not json at all' > "$CS"
run_sweep --days 14 --state "$CS" > /dev/null
check "$(grep -c 'state file unreadable' "$WORK/err.txt")" 1 "(corrupt) an unreadable ledger warns loudly on stderr"
check "$(wc -l < "$SENDLOG")" 2 "(corrupt) ...and the sweep still runs rather than dying"

echo
echo "== summary =="
printf 'pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"; exit 1
