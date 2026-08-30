#!/usr/bin/env bash
# probe-selftest.sh — prove probe.sh can tell a CLEAN result from a BLIND one.
#
# The whole value of probe.sh is one distinction: a pattern that found nothing wrong
# versus a pattern that was never capable of matching anything. If this suite cannot
# make that distinction go red, probe.sh is decoration — which is precisely the class
# of bug it was written to stop, so the suite has to be RED-first about it.
#
# Every case drives the REAL script through argv, never a copied function.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
P="$HERE/probe.sh"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
# rc <expected-rc> <label> -- <args...>  (input on stdin via $IN)
rc() { local want="$1" label="$2"; shift 3
       local got; printf '%s' "$IN" | bash "$P" "$@" >/dev/null 2>&1; got=$?
       [ "$got" = "$want" ] && ok "$label (rc=$got)" || bad "$label — want rc=$want got rc=$got"; }

echo "▶ probe self-test (a probe that matched nothing must never read as clean)"
echo

[ -x "$P" ] || chmod +x "$P" 2>/dev/null
[ -s "$P" ] && ok "probe.sh exists and is non-empty" || bad "probe.sh missing"

# ── 1. the real green: control matches, nothing bad found ────────────────────────────
IN=$'[ ok ] alpha\n[ ok ] beta\n[ ok ] gamma'
rc 0 "GREEN: control present, no findings" -- --control '\[ ok \]' --find '\[FAIL\]'

# ── 2. genuine findings ──────────────────────────────────────────────────────────────
IN=$'[ ok ] alpha\n[FAIL] beta exploded\n[ ok ] gamma'
rc 1 "FINDINGS: a real failure is reported" -- --control '\[ ok \]' --find '\[FAIL\]'

# ── 3. THE BUG: the pattern is wrong, so nothing can ever match ──────────────────────
#    Input uses ✓, the probe looks for "[ ok ]" — the exact 07-26 health-sweep miss.
#    Without a control this reports "0 findings" and reads as a pass.
IN=$'✓ alpha\n✓ beta\n✓ gamma'
rc 2 "BLIND: control pattern matches nothing → refuses to claim clean" -- --control '\[ ok \]' --find '✗'

# ── 4. and with the CORRECT control on the same input, it is a real green ────────────
IN=$'✓ alpha\n✓ beta\n✓ gamma'
rc 0 "GREEN: same input, correct control → genuine clean" -- --control '✓' --find '✗'
#    ^ 3 and 4 differ ONLY in the control. That pair IS the distinction being tested.

# ── 5. empty input satisfies every "no findings" claim ever written ──────────────────
IN=''
rc 2 "BLIND: empty input is refused, not reported clean" -- --control 'anything' --find 'bad'

# ── 6. a control is MANDATORY — you cannot opt out of the safety ─────────────────────
IN=$'[ ok ] alpha'
rc 3 "USAGE: refuses to run with no --control at all" -- --find '\[FAIL\]'

# ── 7. the findings are actually PRINTED, not just counted ───────────────────────────
IN=$'[ ok ] a\n[FAIL] the boiler burst\n[ ok ] c'
out="$(printf '%s' "$IN" | bash "$P" --control '\[ ok \]' --find '\[FAIL\]' 2>&1)"
case "$out" in *"the boiler burst"*) ok "findings are printed, so a count is never the only evidence" ;;
  *) bad "findings not printed — a bare count is what let the bad greps hide" ;; esac

# ── 8. NEGATIVE CONTROL on the suite itself: prove case 3 can fail. Give probe.sh a
#      control that DOES match and the blind-detection must stop firing. If this also
#      returned 2, case 3 would be passing for the wrong reason.
IN=$'✓ alpha'
rc 0 "negative control: blind-detection does NOT fire when the control matches" -- --control '✓' --find 'zzz'

echo
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && echo "  ✅ a blind probe cannot report clean" || echo "  ❌ see failures above"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
