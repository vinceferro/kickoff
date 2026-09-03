#!/usr/bin/env bash
# auto-pickup-selftest.sh — prove the autonomy grant is bounded, and that it REFUSES itself.
#
#   bash scripts/auto-pickup-selftest.sh
#
# AUTO_PICKUP lets a fresh worker continue tracker-authorised work without a new steer. That is the
# most consequential switch in the engine, so the interesting assertions are all about it saying NO:
# off by default, off on the operator's kill switch, and — the one that matters — off when the worker
# is restarting in a loop. "Auto-resume" and "restart loop" are the same event seen from opposite
# ends: a worker that dies and resumes on every boot re-does the same work and bills for it with
# nobody watching, and ~81% of that bill is context re-ground (measured 2026-07-26), so a loop is
# expensive long before it is visible.
#
# The guards are asserted where they are ENFORCED — in the engine, before the session starts. A
# prompt can be reasoned around; a decision computed in bash cannot. RED-first throughout, with a
# negative control proving the loop guard can distinguish a loop from ordinary restarts.
set -uo pipefail
# NEUTRALISE THE CALLER'S ENVIRONMENT FIRST. A live kickoff worker EXPORTS AUTO_PICKUP=1 into every
# command it runs, so a suite launched from one inherits the box's configuration and silently tests
# the box instead of the code: the three "DEFAULT IS OFF" assertions below failed for that reason
# alone (observed 2026-07-29 — pre-existing, and unrelated to whatever change was under test, which
# is precisely what makes it expensive). Per-test `AUTO_PICKUP=1 drive …` prefixes still work; only
# the ambient inheritance is cut.
unset AUTO_PICKUP AUTO_PICKUP_MAX_RESTARTS AUTO_PICKUP_WINDOW
HERE="$(cd "$(dirname "$0")" && pwd)"
SR="$HERE/session-run.sh"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "▶ auto-pickup self-test (an autonomy grant is only as good as its refusals)"
echo

F="$(mktemp -d)"; trap 'rm -rf "$F"' EXIT

# ── Extract the REAL decision unit from session-run.sh: the knob clamps, the decision function, and
#    the rule-(6) selection, as one contiguous region. Asserted non-empty, because an extraction that
#    silently matched nothing would make every assertion below vacuously green.
UNIT="$F/unit.sh"
awk '/^# ── AUTO-PICKUP \(opt-in\)/{on=1} on{print} on&&/^esac$/{exit}' "$SR" > "$UNIT"
chk "extracted the auto-pickup unit from session-run.sh (non-vacuous)" \
  "[ -s '$UNIT' ] && grep -q 'auto_pickup_decision()' '$UNIT' && grep -q '_RULE6=' '$UNIT'"

# Drive the unit with a scratch KICKOFF_DIR; echo the decision and the rule-6 text it selected.
drive() {   # $1=KICKOFF_DIR ; remaining env comes from the caller
  KICKOFF_DIR="$1" bash -c '
    KICKOFF_DIR="$1"; mkdir -p "$KICKOFF_DIR"
    . "$2"
    printf "DECISION=%s\n" "$_AP_DECISION"
    printf "RULE6=%s\n" "$_RULE6"
  ' _ "$1" "$UNIT" 2>&1 </dev/null
}
# stdin PINNED to /dev/null, deliberately. supervisor.sh spawns START_CMD with `</dev/null` (:347,
# :353), so the outer pass under supervision is NEVER a tty; a terminal launch has a tty and skips
# the wrap entirely. Both real topologies record exactly once. Without this pin the harness inherits
# the caller's tty and simulates a third boot shape that cannot occur — which made the ★ ONE-BOOT
# assertions pass under `bash suite </dev/null` and FAIL under `script -qfe`, a false RED on correct
# shipped code. Found by the core-v0.23 adversarial gate.

# ══ 1. DEFAULT IS OFF — the grant is opt-in, never inherited ═════════════════════════════════
D="$F/d1"; out="$(drive "$D")"
chk "DEFAULT: unset AUTO_PICKUP → off:not-enabled" \
  "printf '%s' \"\$out\" | grep -q 'DECISION=off:not-enabled'"
chk "DEFAULT: rule (6) is await-a-steer" \
  "printf '%s' \"\$out\" | grep -q 'AWAIT his steer'"
chk "DEFAULT: rule (6) never mentions auto-pickup at all (no confusing dead text)" \
  "! printf '%s' \"\$out\" | grep -qi 'auto-pickup'"
chk "DEFAULT: a bogus value is treated as OFF, not as truthy" \
  "AUTO_PICKUP=maybe drive '$F/d1b' | grep -q 'DECISION=off:not-enabled'"

# ══ 2. ARMED — and the granted text spends itself on the boundaries ══════════════════════════
D="$F/d2"; out="$(AUTO_PICKUP=1 drive "$D")"
chk "ARMED: AUTO_PICKUP=1 with a clean history → on" "printf '%s' \"\$out\" | grep -q 'DECISION=on'"
chk "ARMED: it must POST the item BEFORE starting (no silent resume)" \
  "printf '%s' \"\$out\" | grep -q 'POST FIRST'"
chk "ARMED: gated actions are still refused (spend · destruction · shared-remote push)" \
  "printf '%s' \"\$out\" | grep -q 'NOTHING GATED'"
chk "ARMED: approval_needed / blocked items are excluded by name" \
  "printf '%s' \"\$out\" | grep -q 'approval_needed' && printf '%s' \"\$out\" | grep -q 'Blocked'"
chk "ARMED: bounded to ONE item, then report and wait" \
  "printf '%s' \"\$out\" | grep -q 'ONE item'"
chk "ARMED: it is told to read salvaged work rather than re-run it" \
  "printf '%s' \"\$out\" | grep -qi 'salvage'"
chk "ARMED: ambiguity is a steer request, not a judgement call" \
  "printf '%s' \"\$out\" | grep -qi 'ambiguous'"

# ══ 3. THE CRASH-LOOP GUARD — the assertion this file exists for ═════════════════════════════
# 4 starts inside the window with max 3 → the grant must revoke ITSELF for this boot.
D="$F/d3"; mkdir -p "$D"; now=$(date +%s)
for k in 0 30 60 90; do echo $((now - k)) >> "$D/restart-history"; done
out="$(AUTO_PICKUP=1 AUTO_PICKUP_MAX_RESTARTS=3 drive "$D")"
chk "LOOP GUARD: 4 starts in the window (max 3) → off:restart-loop" \
  "printf '%s' \"\$out\" | grep -q 'DECISION=off:restart-loop'"
chk "LOOP GUARD: rule (6) falls back to await-a-steer" \
  "printf '%s' \"\$out\" | grep -q 'AWAIT his steer'"
chk "LOOP GUARD: …and the worker is told to TELL the operator it was suppressed" \
  "printf '%s' \"\$out\" | grep -q 'SUPPRESSED' && printf '%s' \"\$out\" | grep -q 'SAY THAT'"
chk "LOOP GUARD: …and to investigate what is killing the session first" \
  "printf '%s' \"\$out\" | grep -qi 'investigate that before resuming'"

# NEGATIVE CONTROL: the guard must distinguish a LOOP from ordinary restarts spread over time.
# Without this, a threshold that simply counted lifetime restarts would look identical here.
D="$F/d4"; mkdir -p "$D"; now=$(date +%s)
for k in 7200 9000 100000 200000; do echo $((now - k)) >> "$D/restart-history"; done
chk "NEGATIVE CONTROL: 4 OLD starts outside the window do NOT trip the guard" \
  "AUTO_PICKUP=1 AUTO_PICKUP_MAX_RESTARTS=3 drive '$D' | grep -q 'DECISION=on'"

# ══ 4. THE OPERATOR'S KILL SWITCH beats the knob, always ═════════════════════════════════════
D="$F/d5"; mkdir -p "$D"; : > "$D/auto-pickup-off"
chk "KILL SWITCH: .kickoff/auto-pickup-off overrides AUTO_PICKUP=1" \
  "AUTO_PICKUP=1 drive '$D' | grep -q 'DECISION=off:kill-switch'"
chk "KILL SWITCH: rule (6) reverts to await-a-steer" \
  "AUTO_PICKUP=1 drive '$D' | grep -q 'AWAIT his steer'"

# ══ 5. CLAMPS + BOUNDED STATE — a fat-fingered knob must not delete the guard ════════════════
D="$F/d6"; mkdir -p "$D"; now=$(date +%s)
for k in 0 5 10 15 20 25; do echo $((now - k)) >> "$D/restart-history"; done
chk "CLAMP: AUTO_PICKUP_MAX_RESTARTS=0 is floored to 1 (0 would disable the guard)" \
  "AUTO_PICKUP=1 AUTO_PICKUP_MAX_RESTARTS=0 drive '$D' | grep -q 'DECISION=off:restart-loop'"
chk "CLAMP: a garbage window falls back to the default rather than counting nothing" \
  "AUTO_PICKUP=1 AUTO_PICKUP_MAX_RESTARTS=3 AUTO_PICKUP_WINDOW=abc drive '$D' | grep -q 'DECISION=off:restart-loop'"
D="$F/d7"; mkdir -p "$D"; i=0; while [ $i -lt 80 ]; do echo 1 >> "$D/restart-history"; i=$((i+1)); done
AUTO_PICKUP=1 drive "$D" >/dev/null 2>&1
chk "BOUNDED: restart-history is trimmed to <= 51 lines (never grows without limit)" \
  "[ \"\$(wc -l < '$D/restart-history')\" -le 51 ]"

# ══ 5b. ONE BOOT = ONE RECORDED START ═══════════════════════════════════════════════════════
# The guard counts restarts, so miscounting them IS the bug — and it is invisible, because a
# double-counted history looks exactly like a box that is genuinely restarting twice as often.
# Shipped in core-v0.22 and bit live 2026-07-29: the decision runs on BOTH passes of the pty wrap
# (the outer pass re-execs into script(1); the inner pass re-runs everything above it), so every
# start was appended twice and MAX_RESTARTS=3 tripped on the 2nd real restart. Two deliberate
# refreshes 30 min apart read as "4 in 3600s" and suppressed the grant on a box where nothing was
# crashing. The pass that records must be the pass that goes on to exec claude — the same real
# `[ -t 0 ]` signal the wrap decides on, never an inheritable marker.
D="$F/d8"; mkdir -p "$D"
AUTO_PICKUP=1 drive "$D" >/dev/null 2>&1                                  # outer pass: no pty
chk "ONE-BOOT: the pass that will re-exec away records NOTHING (no tty)" \
  "[ ! -s '$D/restart-history' ]"

# The inner pass, driven under a REAL pty — script(1) is what the wrap itself uses, so this is the
# genuine signal and not a simulation of it.
pty_drive() { script -qfe -c "AUTO_PICKUP=1 KICKOFF_DIR='$1' bash -c '. \"\$0\"; printf \"DECISION=%s\\n\" \"\$_AP_DECISION\"' '$UNIT'" /dev/null >/dev/null 2>&1; }
D="$F/d9"; mkdir -p "$D"; pty_drive "$D"
chk "ONE-BOOT: the pass that goes on to exec claude records exactly one start (pty)" \
  "[ \"\$(wc -l < '$D/restart-history' 2>/dev/null || echo 0)\" -eq 1 ]"

# THE REGRESSION ITSELF: a whole boot is outer THEN inner. Exactly one line, or the guard is
# counting a phantom restart for every real one.
D="$F/d10"; mkdir -p "$D"
AUTO_PICKUP=1 drive "$D" >/dev/null 2>&1; pty_drive "$D"
chk "★ ONE-BOOT: a full boot (outer pass THEN inner pass) records the start EXACTLY ONCE" \
  "[ \"\$(wc -l < '$D/restart-history' 2>/dev/null || echo 0)\" -eq 1 ]"

# NEGATIVE CONTROL: the assertion above must be able to tell one append from two. Seed a second
# line by hand and prove the same check goes red — otherwise it is a count nobody has watched fail.
printf '%s\n' "$(date +%s)" >> "$D/restart-history"
chk "NEGATIVE CONTROL: the exactly-once check DOES go red on a double-count" \
  "[ \"\$(wc -l < '$D/restart-history')\" -ne 1 ]"

# ══ 6. THE ANNOUNCE SAYS WHICH WORLD THE OPERATOR IS IN ═════════════════════════════════════
# "Worker back" reads as "waiting for you". If the worker is about to continue by itself, or was
# granted the right and had it suppressed, the ping must say so — that was the operator's condition.
chk "ANNOUNCE: session-run.sh notes an ARMED grant in the restart ping" \
  "grep -q 'auto-pickup ARMED' '$SR'"
chk "ANNOUNCE: …and names a SUPPRESSED grant with its reason" \
  "grep -q 'auto-pickup SUPPRESSED' '$SR'"
chk "ANNOUNCE: …and the kill-switch case is distinct from a suppression" \
  "grep -q 'your kill switch' '$SR'"

# ══ 7. THE PER-ADOPTER AUTONOMY PIN RIDES THE WHITELIST — PERMISSION_MODE NEVER DOES ═════════
# AUTO_PICKUP is durable per-adopter policy, on the SAME FOOTING AS MODEL/EFFORT (cmd_up reads it
# from the environment, and instance.env is imported before that read): a line in instance.env
# ARMS auto-pickup for this instance and survives every launch and hop. PERMISSION_MODE is the
# other half of the frozen contract and stays OFF the whitelist in BOTH importers: that grant
# flows argv / terminal env ONLY — a gitignored file (invisible in review) must never arm it.
for _wl in "$SR" "$HERE/kickoff"; do
  chk "AUTO_PICKUP IS on the instance.env whitelist ($(basename "$_wl")) — it rides like MODEL/EFFORT" \
    "grep -E '^_INSTANCE_ENV_WHITELIST=' '$_wl' | grep -q 'AUTO_PICKUP'"
  chk "…while PERMISSION_MODE is NOT on the same whitelist (that grant never comes from a gitignored file)" \
    "! grep -E '^_INSTANCE_ENV_WHITELIST=' '$_wl' | grep -q 'PERMISSION_MODE'"
done
chk "instance.env.example documents the pin as EFFECTIVE (a line there arms auto-pickup for this instance)" \
  "grep -qi 'a line here arms auto-pickup' '$HERE/instance.env.example'"
chk "…and the old inert-policy wording ('a line in THIS FILE DOES NOTHING') is GONE" \
  "! grep -qi 'DOES NOTHING' '$HERE/instance.env.example'"

echo
echo "──────────────────────────────"
echo "  $PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
  echo "  ✅ auto-pickup is opt-in, loop-guarded, kill-switchable, and it announces which world you are in"
  exit 0
fi
echo "  ❌ see failures above"; exit 1
