#!/usr/bin/env bash
# crew-review-due-selftest.sh — RED-first proof for crew-review-due.sh.
# Drives the due-check against an ISOLATED marker (never the live .kickoff/crew-review.last) across
# every branch, with negative controls (a fresh stamp is NOT due) so a green here can actually fail.
#
#   bash scripts/crew-review-due-selftest.sh   # exits non-zero on ANY failed assertion
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DUE="$HERE/crew-review-due.sh"
[ -x "$DUE" ] || DUE="bash $HERE/crew-review-due.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MARK="$TMP/crew-review.last"

pass=0; fail=0
# run the due-check with an isolated marker; capture stdout + rc
run() { CREW_REVIEW_MARKER="$MARK" CREW_REVIEW_CADENCE_DAYS="${2:-7}" bash "$HERE/crew-review-due.sh" ${1:+$1} 2>&1; }
rc()  { CREW_REVIEW_MARKER="$MARK" CREW_REVIEW_CADENCE_DAYS="${2:-7}" bash "$HERE/crew-review-due.sh" ${1:+$1} >/dev/null 2>&1; echo $?; }
t() { if [ "$2" = "$3" ]; then printf '  \342\234\223 %s\n' "$1"; pass=$((pass+1)); else printf '  \342\234\227 %s — got [%s] want [%s]\n' "$1" "$2" "$3"; fail=$((fail+1)); fi }

now="$(date +%s)"
day=86400

echo "— fail-toward-DUE controls —"
rm -f "$MARK"
t "no marker → exit DUE(0)"           "$(rc '')"        "0"
t "no marker → says DUE"              "$(o="$(run '')"; case "$o" in DUE*) echo Y;; *) echo N;; esac)" "Y"
printf 'not-a-number\n' > "$MARK"
t "corrupt marker → exit DUE(0)"      "$(rc '')"        "0"

echo "— NEGATIVE control: a fresh run is NOT due (proves the check can fail) —"
printf '%s\n' "$now" > "$MARK"
t "stamp=now → exit NOT_DUE(1)"       "$(rc '')"        "1"
t "stamp=now → says NOT_DUE"          "$(o="$(run '')"; case "$o" in NOT_DUE*) echo Y;; *) echo N;; esac)" "Y"
printf '%s\n' "$(( now - 3*day ))" > "$MARK"
t "3d ago, cadence 7 → NOT_DUE(1)"    "$(rc '')"        "1"

echo "— DUE once the window passes —"
printf '%s\n' "$(( now - 8*day ))" > "$MARK"
t "8d ago, cadence 7 → DUE(0)"        "$(rc '')"        "0"
printf '%s\n' "$(( now - 2*day ))" > "$MARK"
t "2d ago, cadence 1 → DUE(0)"        "$(rc '' 1)"      "0"
t "2d ago, cadence 30 → NOT_DUE(1)"   "$(rc '' 30)"     "1"

echo "— clock-skew: a FUTURE stamp is treated as just-run (NOT_DUE) —"
printf '%s\n' "$(( now + 5*day ))" > "$MARK"
t "future stamp → NOT_DUE(1)"         "$(rc '')"        "1"

echo "— --mark stamps a valid epoch → immediately NOT_DUE —"
rm -f "$MARK"
run '--mark' >/dev/null
t "--mark wrote a numeric epoch"      "$(head -1 "$MARK" | grep -qE '^[0-9]+$' && echo Y || echo N)" "Y"
t "after --mark → NOT_DUE(1)"         "$(rc '')"        "1"

# ── THE DEPLOY TOPOLOGY: the marker is per-INSTANCE, never the shared core ────────────────────────
# The original shipped version resolved its .kickoff from "$0" — correct in the kickoff origin, where
# the repo IS the core, and wrong everywhere else. On an adopter the core is a SHARED pinned clone, so
# every instance stamped ONE marker in that clone and the first repo to --mark silenced the cadence for
# all the others. A single-dir fixture cannot see this; build the two-dir shape or the test is theatre.
echo "— deploy topology: two instances sharing ONE core clone must NOT share a marker —"
TOPO="$(mktemp -d)"
mkdir -p "$TOPO/core/scripts" "$TOPO/instanceA/.kickoff" "$TOPO/instanceB/.kickoff"
# A real instance HAS instance.env — that file is the sentinel the script uses to refuse guessing which
# project a bare $PWD belongs to. A fixture without it would not be the deploy topology.
: > "$TOPO/instanceA/.kickoff/instance.env"; : > "$TOPO/instanceB/.kickoff/instance.env"
cp "$HERE/crew-review-due.sh" "$TOPO/core/scripts/"
_CORE_COPY="$TOPO/core/scripts/crew-review-due.sh"
( cd "$TOPO/instanceA" && env -u KICKOFF_DIR -u CREW_REVIEW_MARKER bash "$_CORE_COPY" --mark ) >/dev/null 2>&1
t "instanceA's marker lands in its OWN .kickoff" \
  "$([ -f "$TOPO/instanceA/.kickoff/crew-review.last" ] && echo Y || echo N)" "Y"
t "the shared CORE clone is NOT written to" \
  "$([ -e "$TOPO/core/.kickoff/crew-review.last" ] && echo N || echo Y)" "Y"
_b_rc=0
( cd "$TOPO/instanceB" && env -u KICKOFF_DIR -u CREW_REVIEW_MARKER bash "$_CORE_COPY" ) >/dev/null 2>&1 || _b_rc=$?
t "instanceB is still DUE (no cross-instance suppression)" "$_b_rc" "0"
rm -rf "$TOPO"

echo "— --mark must FAIL LOUDLY when the marker cannot be written —"
_ro="$(mktemp)"; chmod 444 "$_ro"
_m_rc=0
CREW_REVIEW_MARKER="$_ro" bash "$HERE/crew-review-due.sh" --mark >/dev/null 2>&1 || _m_rc=$?
t "unwritable marker → non-zero exit (never a green lie)" "$([ "$_m_rc" -ne 0 ] && echo Y || echo N)" "Y"
# …and the failure must survive a PIPE. exit 2 alone does not: `… --mark 2>&1 | tail -2` reports tail's
# status, which is what an adopter's boot flow actually does when it runs six checks. An stdout-only
# consumer must still SEE the failure, not silence. (Bliz coordinator, core-v0.16 review.)
_piped="$(CREW_REVIEW_MARKER="$_ro" bash "$HERE/crew-review-due.sh" --mark 2>/dev/null | tail -2)"
t "failure is visible on STDOUT alone (survives a pipe that eats the exit code)" \
  "$(case "$_piped" in *FAILED*) echo Y ;; *) echo N ;; esac)" "Y"
rm -f "$_ro"

# ── refuse to GUESS the instance when cwd is not one ──────────────────────────────────────────────
# A coordinator spanning several repos is often `cd`-ed into a sibling; a bare $PWD fallback would
# stamp THAT repo's marker, silencing the cadence for the wrong project with nothing reporting it.
echo "— refuses to guess the instance from a cwd that is not one —"
_nodir="$(mktemp -d)"
_g_rc=0
_g_out="$( cd "$_nodir" && env -u KICKOFF_DIR -u CREW_REVIEW_MARKER bash "$HERE/crew-review-due.sh" 2>&1 )" || _g_rc=$?
t "cwd without .kickoff/instance.env → non-zero exit" "$([ "$_g_rc" -ne 0 ] && echo Y || echo N)" "Y"
t "…and says so out loud (not a silent wrong-instance write)" \
  "$(case "$_g_out" in *FAILED*) echo Y ;; *) echo N ;; esac)" "Y"
# The refusal must also NAME THE ESCAPE HATCHES. A fail-closed exit-2 with no way out reads as
# a bug to route around, and the second-machine case (a fresh engine-source clone that never ran
# `kickoff init`) has a REAL first-class fix the old message never mentioned.
t "…and names the escape hatches (kickoff init / KICKOFF_DIR / CREW_REVIEW_MARKER)" \
  "$(case "$_g_out" in *"kickoff init"*) echo Y ;; *) echo N ;; esac)" "Y"
# Must use --mark: the read-only path never writes, so asserting "no marker" without it is vacuous —
# it passes against the very code that HAS the bug. The risk being guarded is a wrong-instance WRITE.
( cd "$_nodir" && env -u KICKOFF_DIR -u CREW_REVIEW_MARKER bash "$HERE/crew-review-due.sh" --mark ) >/dev/null 2>&1
t "…and --mark from that cwd writes NO marker there (the wrong-instance write)" \
  "$([ -e "$_nodir/.kickoff/crew-review.last" ] && echo N || echo Y)" "Y"
# NEGATIVE control: the same cwd WITH an instance.env is accepted — proves the guard keys on the
# sentinel and is not just refusing everything.
mkdir -p "$_nodir/.kickoff"; : > "$_nodir/.kickoff/instance.env"
rm -f "$_nodir/.kickoff/crew-review.last"   # de-couple from the --mark above (a buggy build writes one)
_ok_rc=0
( cd "$_nodir" && env -u KICKOFF_DIR -u CREW_REVIEW_MARKER bash "$HERE/crew-review-due.sh" ) >/dev/null 2>&1 || _ok_rc=$?
t "negative control: same cwd WITH instance.env is accepted (DUE)" "$_ok_rc" "0"
rm -rf "$_nodir"

echo
if [ "$fail" -eq 0 ]; then echo "PASS: $pass/$((pass+fail)) assertions green"; exit 0
else echo "FAIL: $fail of $((pass+fail)) assertions RED"; exit 1; fi
