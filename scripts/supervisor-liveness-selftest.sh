#!/usr/bin/env bash
# supervisor-liveness-selftest.sh — hermetic proof of the supervisor's bridge-liveness
# auto-respawn (finding #3), long-outage re-alarm (finding #2), and the v0.6 fail-loud
# never-came-up belt (boot-grace escalation: durable .kickoff/bridge-escalated flag + one
# alarm + at most BRIDGE_BOOT_RETRY_CAP guarded refreshes — scenarios h–l), WITHOUT spawning
# any real session or touching a live worker.
#
# HOW IT STAYS HERMETIC:
#   - It EXTRACTS the "KICKOFF-BRIDGE-UNIT" block from scripts/supervisor.sh (the bridge probe,
#     the poll-step, the crash-loop alarm-due decision) and drives it in isolated subshells.
#   - Its dependencies (refresh / session_alive / log / the Telegram send) are STUBBED so a call
#     is OBSERVED (appended to a scratch file), never real. `pgrep`/`ps` are stubbed via a stub
#     dir first on PATH, reading a fixed process-tree fixture — so `bridge_present` runs FOR REAL
#     against a deterministic tree (that is what proves subtree-scoping, not box-wide matching).
#   - Everything lives under a scratch dir. No git state, no live process, no network is touched.
#
# RED-ON-OLD: it re-runs the new-behavior assertions against a saved copy of HEAD's supervisor.sh
# and asserts at least one FAILS there — a test that passes on old code proves nothing
# (memory/fixture-can-mask-the-bug-it-should-catch.md). NOTE: this makes the suite a COMMIT-TIME
# proof — it is only meaningful while the working-tree supervisor.sh differs behaviorally from
# HEAD's (which is why it is deliberately NOT wired into lefthook/selftest.sh).
#
# Usage:  bash scripts/supervisor-liveness-selftest.sh
# Exit non-zero on any failed assertion (or if RED-on-old is not proven).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUPERVISOR_NEW="$SCRIPT_DIR/supervisor.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sup-liveness-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$1" = "$2" ]; then ok "$3 (=$1)"; else bad "$3 (want=$2 got=$1)"; fi; }

# ── stub dir: deterministic pgrep / ps / kill / curl ─────────────────────────
STUBDIR="$WORK/stubbin"
mkdir -p "$STUBDIR"

# pgrep -P <ppid>: emit children of <ppid> from the tree fixture ($STUB_TREE_FILE, "ppid child" lines).
cat > "$STUBDIR/pgrep" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-P" ]; then
  [ -f "${STUB_TREE_FILE:-}" ] || exit 1
  out="$(awk -v p="$2" '$1==p{print $2}' "$STUB_TREE_FILE")"
  [ -n "$out" ] || exit 1
  printf '%s\n' $out
  exit 0
fi
exit 1
EOF

# ps -o args= -p <pid>: emit args for <pid> from the args fixture ($STUB_ARGS_FILE, "pid|args" lines).
cat > "$STUBDIR/ps" <<'EOF'
#!/usr/bin/env bash
pid=""
while [ $# -gt 0 ]; do case "$1" in -p) pid="$2"; shift 2 ;; *) shift ;; esac; done
[ -f "${STUB_ARGS_FILE:-}" ] || exit 1
line="$(awk -F'|' -v p="$pid" '$1==p{print $2}' "$STUB_ARGS_FILE")"
[ -n "$line" ] || exit 1
printf '%s\n' "$line"
EOF

# kill / curl: inert (a scoped-refresh test must never actually signal or hit the network).
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBDIR/kill"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBDIR/curl"
chmod +x "$STUBDIR"/*

# ── extract the testable unit from a given supervisor.sh ─────────────────────
extract_unit() {
  # prints the lines strictly BETWEEN the two KICKOFF-BRIDGE-UNIT marker lines (which are the
  # ONLY lines bearing that token, so the toggle is unambiguous)
  awk '/KICKOFF-BRIDGE-UNIT/{f=!f; next} f' "$1"
}

# ── the harness: source the extracted unit + stubs, expose state + observers ──
# Written once to disk and sourced by each scenario subshell so every scenario starts clean.
HARNESS="$WORK/harness.sh"
cat > "$HARNESS" <<'EOF'
# minimal stand-ins for the supervisor's ambient dependencies (observed, never real)
REFRESH_LOG="${REFRESH_LOG:?}"; ALARM_LOG="${ALARM_LOG:?}"
log() { :; }                                   # quiet
session_alive() { return 0; }                  # our session is alive for every scenario
# refresh(): observe the reason AND mimic the real side effect (start_session resets BRIDGE_SEEN).
refresh() { printf '%s\n' "$1" >> "$REFRESH_LOG"; BRIDGE_SEEN=0; BRIDGE_SEEN_AT=0; }

# supervisor globals the unit reads (defaults; scenarios override)
KICKOFF_DIR="$WORK/kickoff"; mkdir -p "$KICKOFF_DIR"
REPO_DIR="$WORK"; SETTINGS_FILE=""; ACCESS_FILE=""
DRY_RUN="${DRY_RUN:-0}"
BRIDGE_LIVENESS="${BRIDGE_LIVENESS:-1}"
FASTDEATH_THRESHOLD_SECONDS="${FASTDEATH_THRESHOLD_SECONDS:-60}"
FASTDEATH_ALARM_AT="${FASTDEATH_ALARM_AT:-3}"
FASTDEATH_REALARM_EVERY="${FASTDEATH_REALARM_EVERY:-12}"
FASTDEATH_LAST_ALARM_STREAK="${FASTDEATH_LAST_ALARM_STREAK:-0}"
BRIDGE_RESPAWN_CAP="${BRIDGE_RESPAWN_CAP:-3}"
BRIDGE_SEEN="${BRIDGE_SEEN:-0}"; BRIDGE_SEEN_AT="${BRIDGE_SEEN_AT:-0}"
BRIDGE_RESPAWN_STREAK="${BRIDGE_RESPAWN_STREAK:-0}"; BRIDGE_RESPAWN_GIVEUP="${BRIDGE_RESPAWN_GIVEUP:-0}"

. "$UNIT_FILE"                                  # define bridge_present / bridge_liveness_step / crashloop_alarm_due / …

# observe the alarms (override AFTER sourcing the unit; harmless no-ops on an old unit that
# never calls them)
bridge_degraded_alarm() { printf 'degraded\n' >> "$ALARM_LOG"; }
bridge_neverup_alarm()  { printf 'neverup\n'  >> "$ALARM_LOG"; }
EOF

# run one scenario body ($1) in an isolated subshell against the given unit file ($UNIT_FILE env).
# The body has REFRESH_LOG / ALARM_LOG scratch files and the harness helpers in scope.
run_scenario() {
  local body="$1"
  REFRESH_LOG="$WORK/refresh.$$.$RANDOM"; ALARM_LOG="$WORK/alarm.$$.$RANDOM"
  : > "$REFRESH_LOG"; : > "$ALARM_LOG"
  (
    PATH="$STUBDIR:$PATH"
    export WORK STUB_TREE_FILE STUB_ARGS_FILE REFRESH_LOG ALARM_LOG UNIT_FILE
    export DRY_RUN BRIDGE_LIVENESS FASTDEATH_THRESHOLD_SECONDS FASTDEATH_ALARM_AT
    export FASTDEATH_REALARM_EVERY FASTDEATH_LAST_ALARM_STREAK BRIDGE_RESPAWN_CAP
    export BRIDGE_SEEN BRIDGE_SEEN_AT BRIDGE_RESPAWN_STREAK BRIDGE_RESPAWN_GIVEUP SESSION_PGID
    set +e
    . "$HARNESS"
    eval "$body"
  )
  R_COUNT="$(grep -c . "$REFRESH_LOG" 2>/dev/null)"; R_COUNT="${R_COUNT:-0}"
  A_COUNT="$(grep -c . "$ALARM_LOG" 2>/dev/null)";   A_COUNT="${A_COUNT:-0}"
  R_LAST="$(tail -n1 "$REFRESH_LOG" 2>/dev/null || echo '')"
}

# ── the assertion suite (run against NEW = expect all-green; OLD = expect reds) ──
# emits PASS/FAIL for the current $UNIT_FILE; each scenario resets its own state.
suite() {
  local tree="$WORK/tree" args="$WORK/args"
  STUB_TREE_FILE="$tree"; STUB_ARGS_FILE="$args"
  export SESSION_PGID=1000

  # our topology: 1000 (script wrapper) -> 1001 (claude) -> 1002 (bun bridge)
  # a DIFFERENT project's live bridge: 2000 -> 2001 -> 2002 (bun telegram) — must be IGNORED.
  printf '1000 1001\n1001 1002\n2000 2001\n2001 2002\n' > "$tree"
  printf '1001|claude --channels\n1002|bun run --cwd /x/plugins/cache/claude-plugins-official/telegram/0.0.6 start\n2002|bun /y/bin/bun server.ts\n' > "$args"

  # (a) bridge present -> no action, latch set
  BRIDGE_SEEN=0 BRIDGE_RESPAWN_STREAK=0 run_scenario '
    bridge_liveness_step
    printf "%s\n" "$BRIDGE_SEEN" > "$WORK/seen.a"'
  check "$R_COUNT" 0 "(a) bridge present -> NO refresh"
  check "$(cat "$WORK/seen.a")" 1 "(a) bridge present -> latch set"

  # (b) bridge gone AFTER being seen -> refresh (bridge-dead)
  #  first tick sees the bridge (latch), then the bridge process disappears, second tick refreshes.
  BRIDGE_SEEN=0 BRIDGE_RESPAWN_STREAK=0 run_scenario '
    bridge_liveness_step                       # sees 1002 -> latch
    # drop the bridge: remove 1001->1002 edge and 1002 args
    printf "1000 1001\n2000 2001\n2001 2002\n" > "$STUB_TREE_FILE"
    printf "1001|claude --channels\n2002|bun /y/bin/bun server.ts\n" > "$STUB_ARGS_FILE"
    bridge_liveness_step'
  check "$R_COUNT" 1 "(b) bridge gone-after-seen -> refresh fired"
  check "$R_LAST" "bridge-dead" "(b) refresh reason is bridge-dead"

  # (c) bridge NEVER seen (non-channels session, no bun descendant) -> NO refresh, ever
  printf '1000 1001\n' > "$tree"                # only claude, never a bun bridge
  printf '1001|claude -p "do one task"\n' > "$args"
  BRIDGE_SEEN=0 BRIDGE_RESPAWN_STREAK=0 run_scenario '
    bridge_liveness_step; bridge_liveness_step; bridge_liveness_step
    printf "%s\n" "$BRIDGE_SEEN" > "$WORK/seen.c"'
  check "$R_COUNT" 0 "(c) bridge never seen -> NO refresh"
  check "$(cat "$WORK/seen.c")" 0 "(c) latch never set (non-channels)"

  # (d) subtree-scoping: OUR bridge gone but a DIFFERENT session's bridge present -> refresh.
  #  A box-wide `pgrep -f telegram` would find 2002 and wrongly report "present". The subtree walk
  #  from SESSION_PGID=1000 must NOT reach 2002, so it correctly sees OUR bridge as gone.
  printf '1000 1001\n2000 2001\n2001 2002\n' > "$tree"   # 1000's subtree has NO bun; 2000's does
  printf '1001|claude --channels\n2002|bun /y/telegram server.ts\n' > "$args"
  BRIDGE_SEEN=1 BRIDGE_RESPAWN_STREAK=0 run_scenario 'bridge_liveness_step'
  check "$R_COUNT" 1 "(d) our bridge gone, other project's present -> refresh (subtree-scoped)"
  #  and prove the raw probe agrees: bridge_present is FALSE for our subtree despite 2002 existing
  BRIDGE_SEEN=1 run_scenario 'if bridge_present; then echo present > "$WORK/bp.d"; else echo gone > "$WORK/bp.d"; fi'
  check "$(cat "$WORK/bp.d")" "gone" "(d) bridge_present=gone (never box-wide matched 2002)"

  # (e) respawn CAP bounds a persistent bridge-death (no infinite loop)
  #  bridge is permanently gone; each tick we re-mark it seen (a bridge that reappears then dies).
  BRIDGE_SEEN=1 BRIDGE_RESPAWN_STREAK=0 BRIDGE_RESPAWN_GIVEUP=0 BRIDGE_RESPAWN_CAP=3 run_scenario '
    bridge_present() { return 1; }             # bridge always gone
    for _ in 1 2 3 4 5 6; do BRIDGE_SEEN=1; bridge_liveness_step; done'
  check "$R_COUNT" 3 "(e) CAP bounds respawns to BRIDGE_RESPAWN_CAP (=3)"
  check "$A_COUNT" 1 "(e) exactly ONE degraded alarm when the cap trips"

  # (f) re-alarm cadence: fires at the alarm point, then every FASTDEATH_REALARM_EVERY, NOT every restart
  FASTDEATH_ALARM_AT=3 FASTDEATH_REALARM_EVERY=12 run_scenario '
    FASTDEATH_LAST_ALARM_STREAK=0
    # verdict must update the bookmark in the CURRENT shell (no command-substitution subshell),
    # exactly as the poll loop does when an alarm fires — so redirect the whole for-loop instead.
    verdict() { if crashloop_alarm_due "$1"; then FASTDEATH_LAST_ALARM_STREAK="$1"; V=y; else V=n; fi; }
    for s in 3 4 5 10 15 16 17 28; do verdict "$s"; printf "%s:%s\n" "$s" "$V"; done > "$WORK/realarm"'
  local got; got="$(tr "\n" " " < "$WORK/realarm")"
  check "$got" "3:n 4:y 5:n 10:n 15:n 16:y 17:n 28:y " "(f) re-alarm bounded (fires at 4,16,28 — not every restart)"

  # (g) DRY_RUN inertness: detect-only, never refresh, never increment the streak
  DRY_RUN=1 BRIDGE_SEEN=1 BRIDGE_RESPAWN_STREAK=0 run_scenario '
    bridge_present() { return 1; }             # bridge gone
    bridge_liveness_step
    printf "%s\n" "$BRIDGE_RESPAWN_STREAK" > "$WORK/streak.g"'
  check "$R_COUNT" 0 "(g) DRY_RUN -> NO refresh"
  check "$(cat "$WORK/streak.g")" 0 "(g) DRY_RUN -> streak not incremented"

  # ── v0.6 fail-loud never-came-up belt (scenarios h–l) ─────────────────────────
  # Scenarios drive bridge_liveness_step with BRIDGE_SEEN=0 (never latched) past an elapsed
  # boot grace (SESSION_STARTED=0 + BRIDGE_BOOT_GRACE_SECONDS=0). TELEGRAM_STATE_DIR points at
  # a scratch fixture dir (the detector is inert without one — the non-telegram exemption).
  # Each scenario uses its OWN scratch KICKOFF_DIR so flag state never bleeds across scenarios
  # or across the NEW/OLD suite runs.

  # (h) bridge never present, grace elapsed → durable flag + ONE alarm + exactly one refresh
  #     (bridge-neverup) + the foreign-consumer corroboration (bot.pid = OUR live selftest pid,
  #     which is NOT in the stubbed session subtree → named in the log, detection only).
  printf '1000 1001\n' > "$tree"; printf '1001|claude --channels\n' > "$args"   # no bridge in the subtree
  BRIDGE_SEEN=0 BRIDGE_RESPAWN_STREAK=0 run_scenario '
    KICKOFF_DIR="$WORK/kick.h"; mkdir -p "$KICKOFF_DIR"; rm -f "$KICKOFF_DIR/bridge-escalated"
    TELEGRAM_STATE_DIR="$WORK/chan.h"; mkdir -p "$TELEGRAM_STATE_DIR"
    printf "%s\n" "$$" > "$TELEGRAM_STATE_DIR/bot.pid"
    : > "$WORK/log.h"; log() { printf "%s\n" "$*" >> "$WORK/log.h"; }
    SESSION_STARTED=0; BRIDGE_BOOT_GRACE_SECONDS=0; BRIDGE_BOOT_RETRY_CAP=1
    BRIDGE_BOOT_FAILS=0; BRIDGE_BOOT_GIVEUP=0
    bridge_liveness_step'
  check "$R_COUNT" 1 "(h) never-up past grace -> exactly one refresh"
  check "$R_LAST" "bridge-neverup" "(h) refresh reason is bridge-neverup"
  check "$A_COUNT" 1 "(h) exactly one never-up alarm"
  check "$([ -f "$WORK/kick.h/bridge-escalated" ] && echo yes || echo no)" "yes" "(h) durable flag written (.kickoff/bridge-escalated)"
  local fc; fc="$(grep -c 'bridge-boot: foreign consumer' "$WORK/log.h" 2>/dev/null)"
  check "${fc:-0}" 1 "(h) foreign channel-holder corroboration logged (detection only)"

  # (i) second consecutive never-up → NO second refresh (give-up latch), flag persists, still ONE alarm
  BRIDGE_SEEN=0 BRIDGE_RESPAWN_STREAK=0 run_scenario '
    KICKOFF_DIR="$WORK/kick.i"; mkdir -p "$KICKOFF_DIR"; rm -f "$KICKOFF_DIR/bridge-escalated"
    TELEGRAM_STATE_DIR="$WORK/chan.i"; mkdir -p "$TELEGRAM_STATE_DIR"
    bridge_present() { return 1; }
    SESSION_STARTED=0; BRIDGE_BOOT_GRACE_SECONDS=0; BRIDGE_BOOT_RETRY_CAP=1
    BRIDGE_BOOT_FAILS=0; BRIDGE_BOOT_GIVEUP=0
    bridge_liveness_step        # trip 1: flag + alarm + guarded refresh #1
    bridge_liveness_step        # trip 2: cap reached -> give up (no refresh)
    bridge_liveness_step        # latched -> inert
    printf "%s\n" "$BRIDGE_BOOT_GIVEUP" > "$WORK/giveup.i"'
  check "$R_COUNT" 1 "(i) give-up latch -> NO second refresh"
  check "$A_COUNT" 1 "(i) still exactly ONE alarm (no spam)"
  check "$(cat "$WORK/giveup.i")" 1 "(i) BRIDGE_BOOT_GIVEUP latched"
  check "$([ -f "$WORK/kick.i/bridge-escalated" ] && echo yes || echo no)" "yes" "(i) flag persists at give-up"

  # (j) bridge appears within grace → no flag/refresh/alarm; a pre-planted flag CLEARS and the
  #     boot-fail streak resets on the healthy first-seen latch.
  printf '1000 1001\n1001 1002\n' > "$tree"
  printf '1001|claude --channels\n1002|bun run --cwd /x/plugins/cache/claude-plugins-official/telegram/0.0.6 start\n' > "$args"
  BRIDGE_SEEN=0 BRIDGE_RESPAWN_STREAK=0 run_scenario '
    KICKOFF_DIR="$WORK/kick.j"; mkdir -p "$KICKOFF_DIR"
    printf "planted\n" > "$KICKOFF_DIR/bridge-escalated"
    SESSION_STARTED=0; BRIDGE_BOOT_GRACE_SECONDS=999; BRIDGE_BOOT_RETRY_CAP=1
    BRIDGE_BOOT_FAILS=1; BRIDGE_BOOT_GIVEUP=0
    bridge_liveness_step
    printf "%s\n" "$BRIDGE_BOOT_FAILS" > "$WORK/bootfails.j"'
  check "$R_COUNT" 0 "(j) bridge up -> no refresh"
  check "$A_COUNT" 0 "(j) bridge up -> no alarm"
  check "$([ -f "$WORK/kick.j/bridge-escalated" ] && echo yes || echo no)" "no" "(j) pre-planted flag cleared on healthy latch"
  check "$(cat "$WORK/bootfails.j")" 0 "(j) boot-fail streak reset on healthy latch"

  # (k) DRY_RUN → detect-only: no flag, no refresh, streak untouched, a DRY_RUN log line emitted
  DRY_RUN=1 BRIDGE_SEEN=0 BRIDGE_RESPAWN_STREAK=0 run_scenario '
    KICKOFF_DIR="$WORK/kick.k"; mkdir -p "$KICKOFF_DIR"; rm -f "$KICKOFF_DIR/bridge-escalated"
    TELEGRAM_STATE_DIR="$WORK/chan.k"; mkdir -p "$TELEGRAM_STATE_DIR"
    bridge_present() { return 1; }
    : > "$WORK/log.k"; log() { printf "%s\n" "$*" >> "$WORK/log.k"; }
    SESSION_STARTED=0; BRIDGE_BOOT_GRACE_SECONDS=0
    BRIDGE_BOOT_FAILS=0; BRIDGE_BOOT_GIVEUP=0
    bridge_liveness_step
    printf "%s\n" "$BRIDGE_BOOT_FAILS" > "$WORK/bootfails.k"'
  check "$R_COUNT" 0 "(k) DRY_RUN -> no refresh"
  check "$([ -f "$WORK/kick.k/bridge-escalated" ] && echo yes || echo no)" "no" "(k) DRY_RUN -> no flag written"
  check "$(cat "$WORK/bootfails.k")" 0 "(k) DRY_RUN -> boot-fail streak untouched"
  local kd; kd="$(grep -c 'DRY_RUN' "$WORK/log.k" 2>/dev/null)"
  check "$([ "${kd:-0}" -ge 1 ] && echo yes || echo no)" "yes" "(k) DRY_RUN -> detect-only log line emitted"

  # (l) the EXISTING died-after-seen cap-trip give-up now ALSO writes the durable flag
  BRIDGE_SEEN=1 BRIDGE_RESPAWN_STREAK=0 BRIDGE_RESPAWN_GIVEUP=0 BRIDGE_RESPAWN_CAP=3 run_scenario '
    KICKOFF_DIR="$WORK/kick.l"; mkdir -p "$KICKOFF_DIR"; rm -f "$KICKOFF_DIR/bridge-escalated"
    bridge_present() { return 1; }             # bridge always gone (after having been seen)
    for _ in 1 2 3 4 5 6; do BRIDGE_SEEN=1; bridge_liveness_step; done'
  check "$R_COUNT" 3 "(l) cap still bounds respawns to BRIDGE_RESPAWN_CAP (=3)"
  check "$A_COUNT" 1 "(l) still exactly one degraded alarm"
  check "$([ -f "$WORK/kick.l/bridge-escalated" ] && echo yes || echo no)" "yes" "(l) cap-trip give-up writes the durable flag"
}

# ── run NEW (expect all green) ───────────────────────────────────────────────
echo "== assertions against NEW scripts/supervisor.sh =="
UNIT_FILE="$WORK/unit.new.sh"; extract_unit "$SUPERVISOR_NEW" > "$UNIT_FILE"
if ! bash -n "$UNIT_FILE" 2>/dev/null; then bad "extracted unit fails bash -n (new)"; fi
suite
NEW_PASS=$PASS; NEW_FAIL=$FAIL

# ── RED-ON-OLD: same assertions against HEAD's supervisor.sh must FAIL ────────
echo
echo "== RED-on-old: same assertions against HEAD:scripts/supervisor.sh =="
OLD_SRC="$WORK/supervisor.old.sh"
if git -C "$SCRIPT_DIR" show HEAD:scripts/supervisor.sh > "$OLD_SRC" 2>/dev/null; then
  UNIT_FILE="$WORK/unit.old.sh"; extract_unit "$OLD_SRC" > "$UNIT_FILE"
  PASS=0; FAIL=0
  # whatever HEAD's unit lacks (originally the whole unit; now e.g. the v0.6 never-up belt)
  # must make at least one assertion fail loudly here — that failure IS the RED proof.
  suite >/dev/null 2>&1
  OLD_FAIL=$FAIL
  if [ "$OLD_FAIL" -gt 0 ]; then
    RED_ON_OLD=1; printf '  ok   RED-on-old proven — %s assertion(s) FAIL against HEAD (behavior is genuinely new)\n' "$OLD_FAIL"
  else
    RED_ON_OLD=0; printf '  FAIL RED-on-old NOT proven — the suite passed on OLD code (it proves nothing)\n'
  fi
else
  RED_ON_OLD=0; printf '  FAIL could not read HEAD:scripts/supervisor.sh to prove RED-on-old\n'
fi

echo
echo "== summary =="
printf 'NEW: pass=%s fail=%s   RED-on-old proven=%s\n' "$NEW_PASS" "$NEW_FAIL" "${RED_ON_OLD:-0}"
if [ "$NEW_FAIL" -eq 0 ] && [ "${RED_ON_OLD:-0}" = "1" ]; then
  echo "SELFTEST PASS"; exit 0
fi
echo "SELFTEST FAIL"; exit 1
