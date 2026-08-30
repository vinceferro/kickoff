#!/usr/bin/env bash
# supervisor-liveness-selftest.sh — hermetic proof of the supervisor's bridge-liveness
# auto-respawn (finding #3), long-outage re-alarm (finding #2), and the v0.6 fail-loud
# never-came-up belt (boot-grace escalation: durable .kickoff/bridge-escalated flag + one
# alarm + BRIDGE_BOOT_RETRY_CAP fast refreshes — scenarios h–l), WITHOUT spawning
# any real session or touching a live worker.
#
# v0.9 (the 2026-07-24 deaf-worker outage) adds four more things to prove — scenarios i, j, m–q:
#   - the fast-retry cap no longer LATCHES a permanent give-up; it ARMS a widening backoff
#     (600 → 1200 → 2400 → a 3600s ceiling) that keeps retrying indefinitely, and the healthy
#     first-seen latch DISARMS all of it (bridge_boot_reset).
#   - the backoff re-alarms on a BOUNDED cadence (silence and spam are the same bug).
#   - a Telegram send is OBSERVABLE both ways — and the bot token, which lives in the URL,
#     still never reaches the log (a fake-token negative control asserts that, not a claim).
#   - recovery records a bounded outage breadcrumb (.kickoff/bridge-outages.log) BEFORE it
#     clears the flag, so the next session can say "I was deaf HH:MM→HH:MM" instead of
#     announcing as if nothing happened.
# The CLOCK SEAM is what makes a backoff measured in hours testable at all: the unit reads
# `bridge_now`, and these scenarios override it with a mutable FAKE_NOW — the same
# override-after-sourcing idiom the older scenarios already use for `bridge_present`.
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
# (memory/fixture-can-mask-the-bug-it-should-catch.md). When the working-tree unit is
# byte-identical to HEAD's (the normal post-commit state) the proof is N/A and auto-SKIPPED —
# the suite stays green-runnable as a plain regression gate; the proof re-arms automatically on
# the next behavioral edit (the skip triggers only on byte-identical units, so a real delta can
# never dodge it).
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

# kill: inert (a scoped-refresh test must never actually signal).
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBDIR/kill"

# curl: still ZERO network. It prints $STUB_CURL_CODE on stdout — standing in for what
# `-w '%{http_code}'` would have produced — so a scenario can drive a 200, a 401, the empty
# output of a connect failure, or (v0.10) a DIRTY non-numeric string, and exits $STUB_CURL_RC.
# It drains stdin first so the `-K -` pipe never SIGPIPEs the printf that feeds it the token.
# v0.10 STUB_CURL_LEAK_STDERR=1 makes it echo the config it received — which CONTAINS the bot
# token, because the token lives in the URL — onto stderr, exactly as a real curl error does
# ("curl: (6) Could not resolve host: api.telegram.org"-style diagnostics quote the URL). That is
# the only way to make tg_send_tokenless's `2>/dev/null` load-bearing: with a clean stub, deleting
# that guard changed nothing and the suite stayed green.
cat > "$STUBDIR/curl" <<'EOF'
#!/usr/bin/env bash
_in="$(cat 2>/dev/null || true)"
if [ "${STUB_CURL_LEAK_STDERR:-0}" = "1" ]; then
  printf 'curl: (6) Could not resolve host while fetching %s\n' "$_in" >&2
fi
printf '%s' "${STUB_CURL_CODE:-}"
exit "${STUB_CURL_RC:-0}"
EOF

# jq: answers ONLY the two queries tg_send_tokenless makes. The token it hands back is a FAKE
# sentinel on purpose — scenario (n) asserts that string appears NOWHERE in the log, which turns
# "the bot token can never leak into the log" from a claim into a negative control. (Nothing else
# in the extracted unit shells out to jq, so shadowing it globally is safe.)
cat > "$STUBDIR/jq" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    *TELEGRAM_BOT_TOKEN*) printf 'FAKE-TOKEN-do-not-log\n'; exit 0 ;;
    *allowFrom*)          printf '12345\n';                 exit 0 ;;
  esac
done
exit 0
EOF
chmod +x "$STUBDIR"/*

# ── extract the testable unit from a given supervisor.sh ─────────────────────
extract_unit() {
  # prints the lines strictly BETWEEN the two marker lines, ANCHORED on the exact marker LINES —
  # never on a line that merely MENTIONS the token.
  #
  # WHY ANCHORED (core-v0.20, cost: a whole-suite false collapse). This used to be
  # `awk '/KICKOFF-BRIDGE-UNIT/{f=!f; next} f'`, carrying the comment "these are the ONLY lines
  # bearing that token, so the toggle is unambiguous" — an invariant that NOTHING ENFORCED. A
  # v0.20 comment inside the unit, explaining which knobs sit OUTSIDE the markers, mentioned the
  # token in prose: the toggle flipped OFF there, the real closing marker flipped it back ON, and
  # the extracted "unit" silently lost the belt's tail and gained the supervisor's MAIN LOOP.
  # `bash -n` passed — the swallowed text is valid bash — and 87 of 106 assertions went red for a
  # reason that had nothing to do with the code under test.
  # Anchoring makes a prose mention inert; unit_bounds_ok() below turns the invariant from a
  # comment into an assertion. Both halves matter: the anchor prevents THIS bug, the assertion
  # catches the next way the bounds break (a renamed/dropped/duplicated marker).
  # Non-zero exit = the file did not carry exactly one open + one close marker.
  awk '
    /^# >>> KICKOFF-BRIDGE-UNIT >>>$/ { f=1; o++; next }
    /^# <<< KICKOFF-BRIDGE-UNIT <<<$/ { f=0; c++; next }
    f
    END { if (o+0 != 1 || c+0 != 1) exit 3 }
  ' "$1"
}

# ── the CONTAINMENT check `bash -n` structurally cannot do ───────────────────
# A mis-bounded extraction is SYNTACTICALLY PERFECT — that is exactly how the v0.20 collapse read
# green to `bash -n` while every scenario failed. So assert the bounds by CONTENT, in both
# directions, because the two failure modes are opposite and a one-sided check misses one:
#   POSITIVE — the belt's two entry points ARE present  (an under-run / empty unit can't pass mute)
#   NEGATIVE — the supervisor's main loop is NOT present (symbols that exist only OUTSIDE the markers)
# The consumer this protects: `suite` sources $UNIT_FILE for every scenario, so a bad extraction
# invalidates the ENTIRE run — including the RED-on-old proof, which would then be "proving" a
# delta in the harness rather than in the code (a mis-bounded OLD unit fails every assertion and
# thereby MANUFACTURES a passing RED-on-old). That is why this reports through HARNESS_FATAL
# rather than through bad(): a broken harness is not a test failure to be tallied alongside the
# others, it means the run said NOTHING and must not be readable as a result.
HARNESS_FATAL=0
unit_bounds_ok() {
  local u="$1" tag="$2" rc=0 sym
  for sym in bridge_boot_check bridge_liveness_step; do
    grep -q "^${sym}()" "$u" || {
      printf '  FAIL HARNESS: extracted unit (%s) is MISSING %s() — extraction UNDER-ran\n' "$tag" "$sym"; rc=1; }
  done
  for sym in run_preflight acquire_lock; do
    if grep -q "\\b${sym}\\b" "$u"; then
      printf '  FAIL HARNESS: extracted unit (%s) CONTAINS %s — extraction OVER-ran past the closing marker\n' "$tag" "$sym"; rc=1
    fi
  done
  [ "$rc" -eq 0 ] || HARNESS_FATAL=1
  return "$rc"
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
# The v0.6/v0.9 never-up belt's knobs + state. These live OUTSIDE the extracted unit (they are
# declared in the supervisor's globals block), so the harness MUST restate them — including for
# the RED-on-old run, where an unbound var under `set -u` would produce fake reds that prove
# nothing about behavior. Defaults mirror supervisor.sh's.
BRIDGE_BOOT_GRACE_SECONDS="${BRIDGE_BOOT_GRACE_SECONDS:-120}"
BRIDGE_BOOT_RETRY_CAP="${BRIDGE_BOOT_RETRY_CAP:-1}"
BRIDGE_BOOT_FAILS="${BRIDGE_BOOT_FAILS:-0}"
BRIDGE_BOOT_BACKOFF_START="${BRIDGE_BOOT_BACKOFF_START:-600}"
BRIDGE_BOOT_BACKOFF_MAX="${BRIDGE_BOOT_BACKOFF_MAX:-3600}"
BRIDGE_BOOT_REALARM_EVERY="${BRIDGE_BOOT_REALARM_EVERY:-3}"
BRIDGE_BOOT_BACKOFF_REFRESH_CAP="${BRIDGE_BOOT_BACKOFF_REFRESH_CAP:-6}"
BRIDGE_OUTAGE_LOG_KEEP="${BRIDGE_OUTAGE_LOG_KEEP:-20}"
BRIDGE_BOOT_BACKOFF_N="${BRIDGE_BOOT_BACKOFF_N:-0}"
BRIDGE_BOOT_NEXT_AT="${BRIDGE_BOOT_NEXT_AT:-0}"
BRIDGE_BOOT_LAST_ALARM_N="${BRIDGE_BOOT_LAST_ALARM_N:-0}"
BRIDGE_BOOT_DEAF_SINCE="${BRIDGE_BOOT_DEAF_SINCE:-0}"

. "$UNIT_FILE"                                  # define bridge_present / bridge_liveness_step / crashloop_alarm_due / …

# observe the alarms (override AFTER sourcing the unit; harmless no-ops on an old unit that
# never calls them — which is exactly why the backoff observer stays honest on OLD too)
# v0.10: the observers RECORD THEIR ARGS. Discarding them proved only THAT an alarm fired, never
# WHAT it says — and the deafness figure is the number the operator actually acts on. (Neutering
# the DEAF_SINCE latch made the text say "~86m" instead of "~70m" with the suite fully green.)
bridge_degraded_alarm() { printf 'degraded\n' >> "$ALARM_LOG"; }
bridge_neverup_alarm()  { printf 'neverup %s\n' "${1:-}" >> "$ALARM_LOG"; }
bridge_backoff_alarm()  { printf 'backoff %s %s %s\n' "${1:-}" "${2:-}" "${3:-}" >> "$ALARM_LOG"; }
# v0.11: the CAPPED re-alarm is observed SEPARATELY from the still-retrying one on purpose — that
# is what lets scenario (w) assert "stopped refreshing" and "STILL alarming" as two independent
# facts. Conflating them would let the belt regress into the deleted give-up with the suite green.
bridge_backoff_capped_alarm() { printf 'capped %s %s %s\n' "${1:-}" "${2:-}" "${3:-}" >> "$ALARM_LOG"; }
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
    export BRIDGE_BOOT_GRACE_SECONDS BRIDGE_BOOT_RETRY_CAP BRIDGE_BOOT_FAILS
    export BRIDGE_BOOT_BACKOFF_START BRIDGE_BOOT_BACKOFF_MAX BRIDGE_BOOT_REALARM_EVERY
    export BRIDGE_BOOT_BACKOFF_REFRESH_CAP
    export BRIDGE_OUTAGE_LOG_KEEP BRIDGE_BOOT_BACKOFF_N BRIDGE_BOOT_NEXT_AT
    export BRIDGE_BOOT_LAST_ALARM_N BRIDGE_BOOT_DEAF_SINCE
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

  # (a2) v0.39 engine parity: an OPENCODE bridge inside our group is OUR bridge too.
  #  Same topology, but the descendant is the grinev bot (`opencode-telegram`), whose argv
  #  matches none of the bun signatures. Before the parity case this reported NEVER-UP and
  #  mercy-killed healthy workers on a widening backoff (all eight orgs, 2026-08-22).
  printf '1000 1001\n1001 1002\n2000 2001\n2001 2002\n' > "$tree"
  printf '1001|claude --channels\n1002|node /home/x/.local/bin/opencode-telegram start\n' > "$args"
  BRIDGE_SEEN=0 BRIDGE_RESPAWN_STREAK=0 run_scenario '
    bridge_liveness_step
    printf "%s\n" "$BRIDGE_SEEN" > "$WORK/seen.a2"'
  check "$R_COUNT" 0 "(a2) opencode bridge present -> NO refresh"
  check "$(cat "$WORK/seen.a2")" 1 "(a2) opencode bridge present -> latch set"

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
    BRIDGE_BOOT_FAILS=0; BRIDGE_BOOT_BACKOFF_N=0; BRIDGE_BOOT_NEXT_AT=0
    bridge_liveness_step'
  check "$R_COUNT" 1 "(h) never-up past grace -> exactly one refresh"
  check "$R_LAST" "bridge-neverup" "(h) refresh reason is bridge-neverup"
  check "$A_COUNT" 1 "(h) exactly one never-up alarm"
  check "$([ -f "$WORK/kick.h/bridge-escalated" ] && echo yes || echo no)" "yes" "(h) durable flag written (.kickoff/bridge-escalated)"
  local fc; fc="$(grep -c 'bridge-boot: foreign consumer' "$WORK/log.h" 2>/dev/null)"
  check "${fc:-0}" 1 "(h) foreign channel-holder corroboration logged (detection only)"

  # (i) the fast-retry cap ARMS the widening backoff instead of parking forever.
  #     PRESERVED (green on old too): no second back-to-back refresh, and still exactly ONE
  #     escalation alarm per outage. NEW: instead of latching a permanent give-up, the tier is
  #     armed with a due-at timestamp one BACKOFF_START (600s) in the future — that armed timer
  #     is the difference between a transient blocker and a 26-minute outage.
  BRIDGE_SEEN=0 BRIDGE_RESPAWN_STREAK=0 run_scenario '
    KICKOFF_DIR="$WORK/kick.i"; mkdir -p "$KICKOFF_DIR"; rm -f "$KICKOFF_DIR/bridge-escalated"
    TELEGRAM_STATE_DIR="$WORK/chan.i"; mkdir -p "$TELEGRAM_STATE_DIR"
    bridge_present() { return 1; }
    bridge_now() { printf "%s\n" "${FAKE_NOW:-1000}"; }     # the clock seam, pinned
    bridge_jitter() { printf "0\n"; }                       # the jitter seam, pinned (scenario (u) drives the real one)
    SESSION_STARTED=0; BRIDGE_BOOT_GRACE_SECONDS=0; BRIDGE_BOOT_RETRY_CAP=1
    BRIDGE_BOOT_FAILS=0; BRIDGE_BOOT_BACKOFF_N=0; BRIDGE_BOOT_NEXT_AT=0
    BRIDGE_BOOT_BACKOFF_START=600; BRIDGE_BOOT_BACKOFF_MAX=3600
    bridge_liveness_step        # trip 1: flag + alarm + FAST refresh #1
    bridge_liveness_step        # trip 2: cap reached -> ARM the backoff (no refresh this tick)
    bridge_liveness_step        # trip 3: not due yet -> quiet
    printf "%s\n" "$BRIDGE_BOOT_NEXT_AT" > "$WORK/nextat.i"'
  check "$R_COUNT" 1 "(i) cap reached -> NO second back-to-back refresh"
  check "$A_COUNT" 1 "(i) still exactly ONE escalation alarm (no spam)"
  check "$(cat "$WORK/nextat.i")" 1600 "(i) backoff ARMED at now+BACKOFF_START (not a permanent give-up)"
  check "$([ -f "$WORK/kick.i/bridge-escalated" ] && echo yes || echo no)" "yes" "(i) flag persists while backing off"

  # (j) bridge appears within grace → no flag/refresh/alarm; a pre-planted flag CLEARS and the
  #     healthy first-seen latch resets the WHOLE outage bookkeeping — not just the fail count.
  #     A stale NEXT_AT/BACKOFF_N surviving recovery would make the NEXT outage resume mid-ladder
  #     (at the 60m ceiling instead of 10m), which is why all four are dumped and asserted.
  printf '1000 1001\n1001 1002\n' > "$tree"
  printf '1001|claude --channels\n1002|bun run --cwd /x/plugins/cache/claude-plugins-official/telegram/0.0.6 start\n' > "$args"
  BRIDGE_SEEN=0 BRIDGE_RESPAWN_STREAK=0 run_scenario '
    KICKOFF_DIR="$WORK/kick.j"; mkdir -p "$KICKOFF_DIR"
    printf "planted\n" > "$KICKOFF_DIR/bridge-escalated"
    SESSION_STARTED=0; BRIDGE_BOOT_GRACE_SECONDS=999; BRIDGE_BOOT_RETRY_CAP=1
    BRIDGE_BOOT_FAILS=1; BRIDGE_BOOT_NEXT_AT=1234; BRIDGE_BOOT_BACKOFF_N=2; BRIDGE_BOOT_DEAF_SINCE=99
    bridge_liveness_step
    printf "%s\n" "$BRIDGE_BOOT_FAILS"      > "$WORK/bootfails.j"
    printf "%s\n" "$BRIDGE_BOOT_NEXT_AT"    > "$WORK/nextat.j"
    printf "%s\n" "$BRIDGE_BOOT_BACKOFF_N"  > "$WORK/backoffn.j"
    printf "%s\n" "$BRIDGE_BOOT_DEAF_SINCE" > "$WORK/deaf.j"'
  check "$R_COUNT" 0 "(j) bridge up -> no refresh"
  check "$A_COUNT" 0 "(j) bridge up -> no alarm"
  check "$([ -f "$WORK/kick.j/bridge-escalated" ] && echo yes || echo no)" "no" "(j) pre-planted flag cleared on healthy latch"
  check "$(cat "$WORK/bootfails.j")" 0 "(j) boot-fail streak reset on healthy latch"
  check "$(cat "$WORK/nextat.j")" 0 "(j) healthy latch DISARMS the backoff timer"
  check "$(cat "$WORK/backoffn.j")" 0 "(j) healthy latch resets the backoff exponent"
  check "$(cat "$WORK/deaf.j")" 0 "(j) healthy latch clears the deaf-since clock"

  # (k) DRY_RUN → detect-only: no flag, no refresh, streak untouched, a DRY_RUN log line emitted
  DRY_RUN=1 BRIDGE_SEEN=0 BRIDGE_RESPAWN_STREAK=0 run_scenario '
    KICKOFF_DIR="$WORK/kick.k"; mkdir -p "$KICKOFF_DIR"; rm -f "$KICKOFF_DIR/bridge-escalated"
    TELEGRAM_STATE_DIR="$WORK/chan.k"; mkdir -p "$TELEGRAM_STATE_DIR"
    bridge_present() { return 1; }
    : > "$WORK/log.k"; log() { printf "%s\n" "$*" >> "$WORK/log.k"; }
    SESSION_STARTED=0; BRIDGE_BOOT_GRACE_SECONDS=0
    BRIDGE_BOOT_FAILS=0; BRIDGE_BOOT_BACKOFF_N=0; BRIDGE_BOOT_NEXT_AT=0
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

  # ── v0.9 widening-backoff belt (scenarios m–q) ────────────────────────────────

  # (m) the backoff FIRES when due, the interval WIDENS 600 → 1200 → 2400 → capped 3600, and it
  #     never stops. FAKE_NOW drives the clock seam, so an eight-hour outage runs in milliseconds.
  #     The two "1s early" ticks are the negative control on the due-at gate: if the gate were
  #     wrong in either direction the refresh count would move.
  printf '1000 1001\n' > "$tree"; printf '1001|claude --channels\n' > "$args"
  BRIDGE_SEEN=0 BRIDGE_RESPAWN_STREAK=0 run_scenario '
    KICKOFF_DIR="$WORK/kick.m"; mkdir -p "$KICKOFF_DIR"; rm -f "$KICKOFF_DIR/bridge-escalated"
    TELEGRAM_STATE_DIR="$WORK/chan.m"; mkdir -p "$TELEGRAM_STATE_DIR"
    bridge_present() { return 1; }
    FAKE_NOW=1000; bridge_now() { printf "%s\n" "$FAKE_NOW"; }
    bridge_jitter() { printf "0\n"; }    # the jitter seam, pinned (see scenario (u) for the real one)
    : > "$WORK/log.m"; log() { printf "%s\n" "$*" >> "$WORK/log.m"; }
    SESSION_STARTED=0; BRIDGE_BOOT_GRACE_SECONDS=42; BRIDGE_BOOT_RETRY_CAP=1
    BRIDGE_BOOT_FAILS=0; BRIDGE_BOOT_BACKOFF_N=0; BRIDGE_BOOT_NEXT_AT=0
    BRIDGE_BOOT_BACKOFF_START=600; BRIDGE_BOOT_BACKOFF_MAX=3600
    BRIDGE_BOOT_REALARM_EVERY=3; BRIDGE_BOOT_LAST_ALARM_N=0
    bridge_liveness_step                 # fast refresh #1
    bridge_liveness_step                 # arm the tier: due at 1600
    FAKE_NOW=1599; bridge_liveness_step   # 1s early -> nothing
    FAKE_NOW=1600; bridge_liveness_step   # due -> retry #1, iv 1200, next 2800
    FAKE_NOW=2799; bridge_liveness_step   # 1s early -> nothing
    FAKE_NOW=2800; bridge_liveness_step   # due -> retry #2, iv 2400, next 5200
    FAKE_NOW=5200; bridge_liveness_step   # due -> retry #3, iv capped 3600, next 8800 (+ re-alarm)
    FAKE_NOW=8800; bridge_liveness_step   # due -> retry #4, iv capped 3600, next 12400
    printf "%s\n" "$BRIDGE_BOOT_NEXT_AT"   > "$WORK/nextat.m"
    printf "%s\n" "$BRIDGE_BOOT_BACKOFF_N" > "$WORK/backoffn.m"'
  check "$R_COUNT" 5 "(m) 1 fast + 4 backoff refreshes — the give-up floor is gone"
  check "$R_LAST" "bridge-neverup-backoff" "(m) backoff refresh reason is bridge-neverup-backoff"
  check "$(cat "$WORK/backoffn.m")" 4 "(m) four backoff retries fired (only when due)"
  check "$(cat "$WORK/nextat.m")" 12400 "(m) intervals widened 600,1200,2400 then the 3600 cap held twice"
  check "$A_COUNT" 2 "(m) one escalation alarm + exactly one bounded re-alarm"
  local mb; mb="$(grep -c '^backoff ' "$ALARM_LOG" 2>/dev/null)"
  check "${mb:-0}" 1 "(m) re-alarm is BOUNDED (fired at retry 3, not once per retry)"
  #     …and WHAT it says, not just THAT it fired. The deafness figure is the number the operator
  #     acts on: deaf-since is latched at the first deaf tick (now=1000), retry #3 lands at 5200,
  #     so the honest figure is (5200-1000)/60 = 70m. A DEAF_SINCE latch that never sets would say
  #     86m — a fabricated number relayed to a human as fact, and previously invisible to this suite.
  local mba mna
  mba="$(grep -m1 '^backoff ' "$ALARM_LOG" 2>/dev/null || true)"
  mna="$(grep -m1 '^neverup ' "$ALARM_LOG" 2>/dev/null || true)"
  check "$mba" "backoff 3 70 3600" "(m) re-alarm PAYLOAD: retry #3, deaf ~70m, next attempt in 3600s"
  check "$mna" "neverup 42" "(m) escalation alarm PAYLOAD: the REAL grace figure (42s), not a placeholder"
  #     …and the QUIET GATE: 8 ticks, but only the 6 that ACT may log LOUD. Without the gate an
  #     8h outage writes ~1900 "running DEAF" lines instead of ~1 per backoff tier.
  local mq; mq="$(grep -c 'running DEAF (silent gag)' "$WORK/log.m" 2>/dev/null)"
  check "${mq:-0}" 6 "(m) QUIET GATE bounds the LOUD line to the 6 ACTING ticks (of 8) — not one per poll"

  # (n) a Telegram send is OBSERVABLE both ways — and the bot token NEVER reaches the log.
  #     The old tg_send_tokenless was entirely silent (-o /dev/null, `|| true` on every step, no
  #     log line anywhere): a FAILED alarm left ZERO trace in a 10MB log, and the only reason we
  #     know the 07-24 alert landed is that a human remembered receiving it. The token lives IN
  #     THE URL, so the FAKE-TOKEN assertion is the negative control on the leak constraint.
  run_scenario '
    KICKOFF_DIR="$WORK/kick.n"; mkdir -p "$KICKOFF_DIR"
    TELEGRAM_STATE_DIR="$WORK/chan.n"; mkdir -p "$TELEGRAM_STATE_DIR"
    printf "{}\n" > "$TELEGRAM_STATE_DIR/access.json"
    SETTINGS_FILE="$WORK/settings.n.json"; printf "{}\n" > "$SETTINGS_FILE"
    INSTANCE_ENV="$KICKOFF_DIR/instance.env"
    : > "$WORK/log.n"; log() { printf "%s\n" "$*" >> "$WORK/log.n"; }
    export STUB_CURL_CODE=200; tg_send_tokenless "hello" "test-ok"
    export STUB_CURL_CODE=401; tg_send_tokenless "hello" "test-bad"'
  local nd nf nt
  nd="$(grep -c "tg-send: delivered" "$WORK/log.n" 2>/dev/null)"
  nf="$(grep -c "tg-send: FAILED.*HTTP 401" "$WORK/log.n" 2>/dev/null)"
  nt="$(grep -c "FAKE-TOKEN" "$WORK/log.n" 2>/dev/null)"
  check "${nd:-0}" 1 "(n) a delivered send logs exactly one 'delivered' line"
  check "${nf:-0}" 1 "(n) a failed send logs exactly one 'FAILED … HTTP 401' line"
  check "${nt:-0}" 0 "(n) the bot token NEVER reaches the log (negative control)"
  #     …and the two LEAK GUARDS, driven by a HOSTILE curl instead of a clean one. The old negative
  #     control could not cover either of them: the stub always emitted a tidy numeric code on
  #     stdout and nothing at all on stderr, so BOTH the `%{http_code}` sanitiser and curl's
  #     `2>/dev/null` survived deletion with the suite fully green. Here curl returns a NON-numeric
  #     body carrying the token sentinel AND echoes the token-bearing URL on stderr. The scenario
  #     redirects its own stderr into the log file because that is production's real topology —
  #     the supervisor's stdout AND stderr both land in SUPERVISOR_LOG, so an unsuppressed curl
  #     diagnostic is a token in the log, not a message to nowhere.
  run_scenario '
    KICKOFF_DIR="$WORK/kick.n2"; mkdir -p "$KICKOFF_DIR"
    TELEGRAM_STATE_DIR="$WORK/chan.n2"; mkdir -p "$TELEGRAM_STATE_DIR"
    printf "{}\n" > "$TELEGRAM_STATE_DIR/access.json"
    SETTINGS_FILE="$WORK/settings.n2.json"; printf "{}\n" > "$SETTINGS_FILE"
    INSTANCE_ENV="$KICKOFF_DIR/instance.env"
    : > "$WORK/log.n2"; log() { printf "%s\n" "$*" >> "$WORK/log.n2"; }
    export STUB_CURL_LEAK_STDERR=1
    export STUB_CURL_CODE="200 <html>FAKE-TOKEN-do-not-log</html>"
    { tg_send_tokenless "hello" "test-dirty"; } 2>> "$WORK/log.n2"'
  local n2t n2c
  n2t="$(grep -c "FAKE-TOKEN" "$WORK/log.n2" 2>/dev/null)"
  n2c="$(grep -c "tg-send: FAILED (test-dirty, HTTP 000)" "$WORK/log.n2" 2>/dev/null)"
  check "${n2t:-1}" 0 "(n) a HOSTILE curl (dirty stdout + token on stderr) still leaks NO token to the log"
  check "${n2c:-0}" 1 "(n) a non-numeric %{http_code} is SANITISED to 000 before it can reach the log"

  # (o) recovery records a BOUNDED outage breadcrumb BEFORE clearing the flag. Without it a
  #     recovered worker has total amnesia about its own deafness and announces as if nothing
  #     happened, while the operator had been shouting into a dead channel.
  printf '1000 1001\n1001 1002\n' > "$tree"
  printf '1001|claude --channels\n1002|bun run --cwd /x/plugins/cache/claude-plugins-official/telegram/0.0.6 start\n' > "$args"
  BRIDGE_SEEN=0 BRIDGE_RESPAWN_STREAK=0 run_scenario '
    KICKOFF_DIR="$WORK/kick.o"; mkdir -p "$KICKOFF_DIR"
    printf "2026-07-24T21:43:00Z\nbridge never came up within 120s\n" > "$KICKOFF_DIR/bridge-escalated"
    : > "$KICKOFF_DIR/bridge-outages.log"
    i=1; while [ "$i" -le 30 ]; do printf "old-%s\n" "$i" >> "$KICKOFF_DIR/bridge-outages.log"; i=$((i+1)); done
    BRIDGE_OUTAGE_LOG_KEEP=5
    SESSION_STARTED=0; BRIDGE_BOOT_GRACE_SECONDS=999
    bridge_liveness_step'
  local ocrumb="$WORK/kick.o/bridge-outages.log" olast="" olines=0
  olast="$(tail -n1 "$ocrumb" 2>/dev/null || echo '')"
  olines="$(grep -c . "$ocrumb" 2>/dev/null)"; olines="${olines:-0}"
  check "$(case "$olast" in "2026-07-24T21:43:00Z ->"*) echo yes ;; *) echo no ;; esac)" "yes" \
        "(o) breadcrumb's last line records the outage START from the flag's own timestamp"
  check "$(case "$olast" in *"bridge never came up within 120s") echo yes ;; *) echo no ;; esac)" "yes" \
        "(o) breadcrumb carries the outage reason"
  check "$olines" 5 "(o) breadcrumb bounded to BRIDGE_OUTAGE_LOG_KEEP (oldest dropped)"
  check "$([ -f "$WORK/kick.o/bridge-escalated" ] && echo yes || echo no)" "no" "(o) flag still cleared AFTER the breadcrumb"
  check "$R_COUNT" 0 "(o) recovery -> no refresh"
  check "$A_COUNT" 0 "(o) recovery -> no alarm"
  #     …and a flag whose timestamp is EMPTY/truncated must say "unknown", never invent a number.
  #     GNU `date -d ""` SUCCEEDS and returns midnight-today, so the naive version of this code
  #     minted a plausible-looking fabricated duration (caught by probing it, not by reading it).
  BRIDGE_SEEN=0 BRIDGE_RESPAWN_STREAK=0 run_scenario '
    KICKOFF_DIR="$WORK/kick.o2"; mkdir -p "$KICKOFF_DIR"; rm -f "$KICKOFF_DIR/bridge-outages.log"
    printf "\nsome reason\n" > "$KICKOFF_DIR/bridge-escalated"
    SESSION_STARTED=0; BRIDGE_BOOT_GRACE_SECONDS=999
    bridge_liveness_step'
  local o2; o2="$(tail -n1 "$WORK/kick.o2/bridge-outages.log" 2>/dev/null || echo '')"
  check "$(case "$o2" in *"(duration unknown)"*) echo yes ;; *) echo no ;; esac)" "yes" \
        "(o) an empty flag timestamp yields 'duration unknown' — never a fabricated figure"
  #     …and a FUTURE-dated flag (clock skew, or a flag hand-edited by an operator) must do the
  #     same. Without the `_e -ge _s` sanity guard the arithmetic mints a NEGATIVE duration, and
  #     the re-ground consumer relays it to the operator as fact ("I was deaf -37m").
  BRIDGE_SEEN=0 BRIDGE_RESPAWN_STREAK=0 run_scenario '
    KICKOFF_DIR="$WORK/kick.o3"; mkdir -p "$KICKOFF_DIR"; rm -f "$KICKOFF_DIR/bridge-outages.log"
    printf "%s\nclock skew\n" "$(date -u -d "+1 hour" +%FT%TZ)" > "$KICKOFF_DIR/bridge-escalated"
    SESSION_STARTED=0; BRIDGE_BOOT_GRACE_SECONDS=999
    bridge_liveness_step'
  local o3; o3="$(tail -n1 "$WORK/kick.o3/bridge-outages.log" 2>/dev/null || echo '')"
  check "$(case "$o3" in *"(duration unknown)"*) echo yes ;; *) echo no ;; esac)" "yes" \
        "(o) a FUTURE-dated flag yields 'duration unknown' — never a NEGATIVE duration relayed as fact"

  # (p) DRY_RUN stays detect-only across EVERY new mutation (G4). Green on old AND new — this is
  #     a preserved-guard assertion, not a new-behavior one.
  printf '1000 1001\n' > "$tree"; printf '1001|claude --channels\n' > "$args"
  DRY_RUN=1 BRIDGE_SEEN=0 BRIDGE_RESPAWN_STREAK=0 run_scenario '
    KICKOFF_DIR="$WORK/kick.p"; mkdir -p "$KICKOFF_DIR"; rm -f "$KICKOFF_DIR/bridge-escalated"
    TELEGRAM_STATE_DIR="$WORK/chan.p"; mkdir -p "$TELEGRAM_STATE_DIR"
    bridge_present() { return 1; }
    bridge_now() { printf "%s\n" "1000"; }
    : > "$WORK/log.p"; log() { printf "%s\n" "$*" >> "$WORK/log.p"; }
    SESSION_STARTED=0; BRIDGE_BOOT_GRACE_SECONDS=0; BRIDGE_BOOT_RETRY_CAP=1
    BRIDGE_BOOT_FAILS=0; BRIDGE_BOOT_BACKOFF_N=0; BRIDGE_BOOT_NEXT_AT=0; BRIDGE_BOOT_DEAF_SINCE=0
    bridge_liveness_step; bridge_liveness_step
    printf "%s %s %s %s\n" "$BRIDGE_BOOT_FAILS" "$BRIDGE_BOOT_NEXT_AT" "$BRIDGE_BOOT_BACKOFF_N" "$BRIDGE_BOOT_DEAF_SINCE" > "$WORK/state.p"'
  check "$R_COUNT" 0 "(p) DRY_RUN deaf path -> NO refresh"
  check "$([ -f "$WORK/kick.p/bridge-escalated" ] && echo yes || echo no)" "no" "(p) DRY_RUN deaf path -> no flag written"
  check "$(cat "$WORK/state.p")" "0 0 0 0" "(p) DRY_RUN mutates NO backoff state (fails/next-at/exponent/deaf-since)"
  local pd; pd="$(grep -c 'DRY_RUN' "$WORK/log.p" 2>/dev/null)"
  check "$([ "${pd:-0}" -ge 1 ] && echo yes || echo no)" "yes" "(p) DRY_RUN deaf path -> detect-only log line emitted"
  #     …and the RECOVERY path mutates nothing either: flag stays, no breadcrumb is written.
  printf '1000 1001\n1001 1002\n' > "$tree"
  printf '1001|claude --channels\n1002|bun run --cwd /x/plugins/cache/claude-plugins-official/telegram/0.0.6 start\n' > "$args"
  DRY_RUN=1 BRIDGE_SEEN=0 BRIDGE_RESPAWN_STREAK=0 run_scenario '
    KICKOFF_DIR="$WORK/kick.p2"; mkdir -p "$KICKOFF_DIR"; rm -f "$KICKOFF_DIR/bridge-outages.log"
    printf "2026-07-24T21:43:00Z\nplanted\n" > "$KICKOFF_DIR/bridge-escalated"
    SESSION_STARTED=0; BRIDGE_BOOT_GRACE_SECONDS=999
    bridge_liveness_step'
  check "$([ -f "$WORK/kick.p2/bridge-escalated" ] && echo yes || echo no)" "yes" "(p) DRY_RUN recovery -> flag NOT cleared"
  check "$([ -f "$WORK/kick.p2/bridge-outages.log" ] && echo yes || echo no)" "no" "(p) DRY_RUN recovery -> no breadcrumb written"

  # (q) bridge_boot_reset() directly. It exists so the reset semantics live INSIDE the testable
  #     unit — refresh()'s non-bridge arm calls this same helper, and refresh() itself is stubbed
  #     here, so this asserts the semantics; the WIRING is proven only by reading the diff.
  run_scenario '
    BRIDGE_BOOT_FAILS=7; BRIDGE_BOOT_BACKOFF_N=5; BRIDGE_BOOT_NEXT_AT=99999
    BRIDGE_BOOT_LAST_ALARM_N=3; BRIDGE_BOOT_DEAF_SINCE=42; _BRIDGE_BOOT_SIGMISS_WARNED=1
    bridge_boot_reset
    printf "%s %s %s %s %s %s\n" "$BRIDGE_BOOT_FAILS" "$BRIDGE_BOOT_BACKOFF_N" "$BRIDGE_BOOT_NEXT_AT" \
                              "$BRIDGE_BOOT_LAST_ALARM_N" "$BRIDGE_BOOT_DEAF_SINCE" \
                              "${_BRIDGE_BOOT_SIGMISS_WARNED:-unset}" > "$WORK/reset.q"'
  check "$(cat "$WORK/reset.q" 2>/dev/null || echo missing)" "0 0 0 0 0 0" "(q) bridge_boot_reset zeroes the WHOLE outage state (incl. the v0.10 signature-miss latch)"

  # ── v0.10 adversarial-review fixes (scenarios r–v) ────────────────────────────

  # (r) SIGNATURE MISS — bot.pid names a LIVE process that IS inside our OWN session tree. That is
  #     POSITIVE evidence a bridge exists and only bridge_present's argv pattern missed it (a
  #     telegram-plugin update that switches the launcher from bun to node does exactly this).
  #     Refreshing a worker whose comms are actually FINE is strictly harmful — it kills in-flight
  #     work — so the belt escalates + alarms ONCE (the state IS degraded/unknown, and the operator
  #     is demonstrably reachable) and then STOPS: no fast retry, no armed ladder, ever.
  #     THE REGRESSION THIS PINS: under the old permanent give-up, falling through cost ONE wasted
  #     refresh and then the latch parked it. With the give-up deleted, the same fall-through costs
  #     a session-killing refresh every 60 MINUTES FOREVER plus recurring false "bridge NEVER came
  #     up" alarms — sent over the bridge that is demonstrably working.
  #     bot.pid must be a pid that is BOTH really alive (bridge_boot_check uses the `kill -0`
  #     BUILTIN, which no PATH stub can shadow) AND inside the stubbed subtree — so the fixture
  #     splices this process's own $$ into the tree, exactly as scenario (h) does for the foreign case.
  BRIDGE_SEEN=0 BRIDGE_RESPAWN_STREAK=0 run_scenario '
    printf "1000 1001\n1001 %s\n" "$$" > "$STUB_TREE_FILE"
    printf "1001|claude --channels\n%s|node /x/plugins/cache/tg-next/1.2.0/dist/bridge.js\n" "$$" > "$STUB_ARGS_FILE"
    KICKOFF_DIR="$WORK/kick.r"; mkdir -p "$KICKOFF_DIR"; rm -f "$KICKOFF_DIR/bridge-escalated"
    TELEGRAM_STATE_DIR="$WORK/chan.r"; mkdir -p "$TELEGRAM_STATE_DIR"
    printf "%s\n" "$$" > "$TELEGRAM_STATE_DIR/bot.pid"
    : > "$WORK/log.r"; log() { printf "%s\n" "$*" >> "$WORK/log.r"; }
    FAKE_NOW=1000; bridge_now() { printf "%s\n" "$FAKE_NOW"; }
    bridge_jitter() { printf "0\n"; }
    SESSION_STARTED=0; BRIDGE_BOOT_GRACE_SECONDS=0; BRIDGE_BOOT_RETRY_CAP=1
    BRIDGE_BOOT_FAILS=0; BRIDGE_BOOT_BACKOFF_N=0; BRIDGE_BOOT_NEXT_AT=0
    BRIDGE_BOOT_BACKOFF_START=600; BRIDGE_BOOT_BACKOFF_MAX=3600
    bridge_liveness_step                     # tick 1: escalate + alarm, then STOP
    FAKE_NOW=99999;  bridge_liveness_step    # far past every interval: still nothing
    FAKE_NOW=999999; bridge_liveness_step
    printf "%s %s %s\n" "$BRIDGE_BOOT_FAILS" "$BRIDGE_BOOT_NEXT_AT" "$BRIDGE_BOOT_BACKOFF_N" > "$WORK/state.r"'
  check "$R_COUNT" 0 "(r) signature miss -> NEVER refreshes (a working bridge must not be killed)"
  check "$A_COUNT" 1 "(r) signature miss -> exactly ONE escalation alarm (the operator IS reachable)"
  check "$(cat "$WORK/state.r" 2>/dev/null || echo missing)" "0 0 0" "(r) signature miss -> the backoff ladder is never armed or advanced"
  check "$([ -f "$WORK/kick.r/bridge-escalated" ] && echo yes || echo no)" "yes" "(r) signature miss -> the durable flag is still written"
  local rs rl
  rs="$(grep -c 'SIGNATURE MISS' "$WORK/log.r" 2>/dev/null)"
  check "${rs:-0}" 1 "(r) signature miss logged DISTINCTLY and exactly once (not once per poll tick)"
  rl="$(grep -c 'running DEAF (silent gag)' "$WORK/log.r" 2>/dev/null)"
  check "${rl:-0}" 1 "(r) signature miss does not re-log the LOUD deaf line on every tick"

  # (s) THE REAL CLOCK. Every other backoff scenario overrides bridge_now with a fake, and the
  #     ones that don't pin SESSION_STARTED=0 + grace=0 so the read never matters — which left the
  #     single time source the WHOLE belt hangs off completely unasserted. The mutant
  #     `bridge_now() { printf "%s\n" 0; }` kept the suite fully green while making the belt
  #     PERMANENTLY INERT in production (SESSION_STARTED comes from $SECONDS, so now-SESSION_STARTED
  #     is always <=0 and the grace gate never opens). These two scenarios do NOT override
  #     bridge_now; they move bash's own $SECONDS (assignable — that is the whole trick) so the
  #     REAL read is load-bearing in both directions.
  printf '1000 1001\n' > "$tree"; printf '1001|claude --channels\n' > "$args"
  BRIDGE_SEEN=0 BRIDGE_RESPAWN_STREAK=0 run_scenario '
    KICKOFF_DIR="$WORK/kick.s"; mkdir -p "$KICKOFF_DIR"; rm -f "$KICKOFF_DIR/bridge-escalated"
    TELEGRAM_STATE_DIR="$WORK/chan.s"; mkdir -p "$TELEGRAM_STATE_DIR"
    bridge_present() { return 1; }
    bridge_jitter() { printf "0\n"; }
    SECONDS=100000                                  # move the REAL clock; bridge_now is NOT stubbed
    SESSION_STARTED=$(( $(bridge_now) - 5 )); BRIDGE_BOOT_GRACE_SECONDS=1
    BRIDGE_BOOT_RETRY_CAP=1; BRIDGE_BOOT_FAILS=0; BRIDGE_BOOT_BACKOFF_N=0; BRIDGE_BOOT_NEXT_AT=0
    bridge_liveness_step'
  check "$R_COUNT" 1 "(s) REAL bridge_now: 5s past a 1s grace -> the belt FIRES (a stuck clock would make it inert forever)"
  check "$([ -f "$WORK/kick.s/bridge-escalated" ] && echo yes || echo no)" "yes" "(s) REAL bridge_now: the escalation flag is written on the real clock"
  BRIDGE_SEEN=0 BRIDGE_RESPAWN_STREAK=0 run_scenario '
    KICKOFF_DIR="$WORK/kick.s2"; mkdir -p "$KICKOFF_DIR"; rm -f "$KICKOFF_DIR/bridge-escalated"
    TELEGRAM_STATE_DIR="$WORK/chan.s2"; mkdir -p "$TELEGRAM_STATE_DIR"
    bridge_present() { return 1; }
    SECONDS=100000
    SESSION_STARTED=$(bridge_now); BRIDGE_BOOT_GRACE_SECONDS=99999
    BRIDGE_BOOT_RETRY_CAP=1; BRIDGE_BOOT_FAILS=0; BRIDGE_BOOT_BACKOFF_N=0; BRIDGE_BOOT_NEXT_AT=0
    bridge_liveness_step'
  check "$R_COUNT" 0 "(s) REAL bridge_now: inside the grace -> the belt stays INERT (the gate reads the clock both ways)"
  check "$([ -f "$WORK/kick.s2/bridge-escalated" ] && echo yes || echo no)" "no" "(s) REAL bridge_now: no flag written inside the grace"

  # (t) THE BREADCRUMB MUST NOT LOSE ITS OWN RACE. v0.9 had exactly ONE writer — the healthy
  #     first-seen latch — which requires bridge_present to SUCCEED. refresh() sets BRIDGE_SEEN=0,
  #     so after a recovering refresh the order is: session starts -> claude boots -> bridge
  #     appears -> the NEXT poll tick writes the crumb. The recovered session's re-ground announce
  #     could therefore run BEFORE the crumb existed and announce with the exact amnesia the crumb
  #     was built to prevent. The record is now OPENED at the moment the recovery refresh is
  #     issued (provably before the new session exists) and RECONCILED in place on recovery.
  #     ONE outage owns exactly ONE row, however many retries it took.
  printf '1000 1001\n' > "$tree"; printf '1001|claude --channels\n' > "$args"
  BRIDGE_SEEN=0 BRIDGE_RESPAWN_STREAK=0 run_scenario '
    KICKOFF_DIR="$WORK/kick.t"; mkdir -p "$KICKOFF_DIR"
    rm -f "$KICKOFF_DIR/bridge-escalated" "$KICKOFF_DIR/bridge-outages.log"
    TELEGRAM_STATE_DIR="$WORK/chan.t"; mkdir -p "$TELEGRAM_STATE_DIR"
    bridge_present() { return 1; }
    FAKE_NOW=1000; bridge_now() { printf "%s\n" "$FAKE_NOW"; }
    bridge_jitter() { printf "0\n"; }
    SESSION_STARTED=0; BRIDGE_BOOT_GRACE_SECONDS=0; BRIDGE_BOOT_RETRY_CAP=1
    BRIDGE_BOOT_FAILS=0; BRIDGE_BOOT_BACKOFF_N=0; BRIDGE_BOOT_NEXT_AT=0
    BRIDGE_BOOT_BACKOFF_START=600; BRIDGE_BOOT_BACKOFF_MAX=3600
    bridge_liveness_step                   # fast refresh #1 -> the OPEN row lands BEFORE the refresh
    cp "$KICKOFF_DIR/bridge-outages.log" "$WORK/crumb.t1" 2>/dev/null || : > "$WORK/crumb.t1"
    bridge_liveness_step                   # arm the ladder
    FAKE_NOW=1600; bridge_liveness_step    # backoff retry #1 -> reconcile, do NOT stack a 2nd row
    cp "$KICKOFF_DIR/bridge-outages.log" "$WORK/crumb.t2" 2>/dev/null || : > "$WORK/crumb.t2"
    bridge_present() { return 0; }         # …and the bridge finally returns
    bridge_liveness_step'
  local t1n t1l t2n t3n t3l
  t1n="$(grep -c . "$WORK/crumb.t1" 2>/dev/null)"; t1l="$(tail -n1 "$WORK/crumb.t1" 2>/dev/null || echo '')"
  t2n="$(grep -c . "$WORK/crumb.t2" 2>/dev/null)"
  t3n="$(grep -c . "$WORK/kick.t/bridge-outages.log" 2>/dev/null)"
  t3l="$(tail -n1 "$WORK/kick.t/bridge-outages.log" 2>/dev/null || echo '')"
  check "${t1n:-0}" 1 "(t) the outage row exists the moment the recovery refresh is issued (no race with re-ground)"
  check "$(case "$t1l" in *" -> OPEN ("*) echo yes ;; *) echo no ;; esac)" "yes" "(t) that first row is an OPEN (unfinished) record"
  check "${t2n:-0}" 1 "(t) a SECOND retry in the same outage reconciles the row — never double-writes it"
  check "${t3n:-0}" 1 "(t) recovery COMPLETES the same row (one outage = one row, still)"
  check "$(case "$t3l" in *" -> OPEN ("*) echo no ;; *"bridge never came up"*) echo yes ;; *) echo no ;; esac)" "yes" \
        "(t) the completed row is CLOSED and carries the outage reason"
  check "$([ -f "$WORK/kick.t/bridge-escalated" ] && echo yes || echo no)" "no" "(t) the flag is still cleared on recovery"

  # (u) THE JITTER SEAM ITSELF — driven UNSTUBBED (every other scenario pins it to 0, which is
  #     what keeps them deterministic). The 07-24 incident took TWO workers down in the same
  #     ~2-minute window; a shared cause makes that the normal shape, so a fully deterministic
  #     ladder cold-starts every affected worker at the same instant forever, spiking a shared box.
  run_scenario '
    bad=0; distinct=""; mx=0
    i=1; while [ "$i" -le 200 ]; do
      j="$(bridge_jitter 60)"
      case "$j" in ""|*[!0-9]*) bad=$((bad+1)); j=0 ;; esac
      [ "$j" -gt 60 ] && bad=$((bad+1))
      case " $distinct " in *" $j "*) : ;; *) distinct="$distinct $j" ;; esac
      i=$((i+1))
    done
    k=1; while [ "$k" -le 50 ]; do
      j="$(bridge_jitter 100000)"                 # the hard cap must hold whatever a caller asks
      case "$j" in ""|*[!0-9]*) bad=$((bad+1)); j=0 ;; esac
      [ "$j" -gt "$mx" ] && mx="$j"
      k=$((k+1))
    done
    printf "%s\n" "$bad" > "$WORK/jit.bad"
    printf "%s\n" "$(printf "%s" "$distinct" | wc -w)" > "$WORK/jit.distinct"
    printf "%s\n" "$([ "$mx" -le 300 ] && echo capped || echo "OVER:$mx")" > "$WORK/jit.cap"
    printf "%s %s\n" "$(bridge_jitter 0)" "$(bridge_jitter -5)" > "$WORK/jit.edge"'
  check "$(cat "$WORK/jit.bad" 2>/dev/null || echo missing)" 0 "(u) real bridge_jitter: 250 draws are ALL numeric and inside their bound"
  check "$([ "$(cat "$WORK/jit.distinct" 2>/dev/null || echo 1)" -gt 1 ] && echo yes || echo no)" "yes" \
        "(u) real bridge_jitter actually VARIES (that is the whole point — no lockstep)"
  check "$(cat "$WORK/jit.cap" 2>/dev/null || echo missing)" "capped" "(u) real bridge_jitter honours the 300s hard cap"
  check "$(cat "$WORK/jit.edge" 2>/dev/null || echo missing)" "0 0" "(u) real bridge_jitter: a zero/garbage span yields 0, never garbage arithmetic"

  # (v) THE BREADCRUMB'S OWN FAILURE MODES. Each was silent or unsound: the recovery line claimed
  #     "recorded in <crumb>" even when the append had just failed; the `2>/dev/null` sat AFTER the
  #     redirection that fails, so bash's own error escaped into the supervisor log; and the trim
  #     silently no-op'd when $crumb.tmp could not be created — making "bounded by construction"
  #     FALSE under exactly the failure modes the bound exists for.
  printf '1000 1001\n1001 1002\n' > "$tree"
  printf '1001|claude --channels\n1002|bun run --cwd /x/plugins/cache/claude-plugins-official/telegram/0.0.6 start\n' > "$args"
  BRIDGE_SEEN=0 BRIDGE_RESPAWN_STREAK=0 run_scenario '
    KICKOFF_DIR="$WORK/kick.v"; mkdir -p "$KICKOFF_DIR"
    printf "2026-07-24T21:43:00Z\nplanted\n" > "$KICKOFF_DIR/bridge-escalated"
    : > "$WORK/log.v"; log() { printf "%s\n" "$*" >> "$WORK/log.v"; }
    chmod a-w "$KICKOFF_DIR"                      # the crumb can no longer be created
    SESSION_STARTED=0; BRIDGE_BOOT_GRACE_SECONDS=999
    { bridge_liveness_step; } 2>> "$WORK/log.v"   # production topology: stderr lands in the log too
    chmod u+w "$KICKOFF_DIR"'
  chmod u+w "$WORK/kick.v" 2>/dev/null || true
  local vh vc ve
  vh="$(grep -c 'could NOT be recorded' "$WORK/log.v" 2>/dev/null)"
  vc="$(grep -c -- '— recorded in' "$WORK/log.v" 2>/dev/null)"
  ve="$(grep -ci 'permission denied' "$WORK/log.v" 2>/dev/null)"
  check "${vh:-0}" 1 "(v) a FAILED breadcrumb append is reported as failed…"
  check "${vc:-1}" 0 "(v) …and the recovery line does NOT claim the outage was recorded"
  check "${ve:-1}" 0 "(v) bash's own redirection error never escapes into the supervisor log"
  #     …and the trim stays sound when the atomic tmp path is impossible (a DIRECTORY planted at
  #     $crumb.tmp reproduces it). Without a fallback the file just keeps growing, unbounded.
  BRIDGE_SEEN=0 BRIDGE_RESPAWN_STREAK=0 run_scenario '
    KICKOFF_DIR="$WORK/kick.v2"; mkdir -p "$KICKOFF_DIR"
    printf "2026-07-24T21:43:00Z\nplanted\n" > "$KICKOFF_DIR/bridge-escalated"
    i=1; while [ "$i" -le 30 ]; do printf "old-%s\n" "$i" >> "$KICKOFF_DIR/bridge-outages.log"; i=$((i+1)); done
    mkdir -p "$KICKOFF_DIR/bridge-outages.log.tmp"    # the atomic tail>tmp;mv path is now impossible
    BRIDGE_OUTAGE_LOG_KEEP=5
    : > "$WORK/log.v2"; log() { printf "%s\n" "$*" >> "$WORK/log.v2"; }
    SESSION_STARTED=0; BRIDGE_BOOT_GRACE_SECONDS=999
    { bridge_liveness_step; } 2>> "$WORK/log.v2"      # production topology: stderr lands in the log too
    printf "%s\n" "$KICKOFF_DIR" > "$WORK/kdir.v2"'
  local v2n v2m v2e
  v2n="$(grep -c . "$WORK/kick.v2/bridge-outages.log" 2>/dev/null)"
  v2m="$(grep -c 'trimmed IN PLACE' "$WORK/log.v2" 2>/dev/null)"
  v2e="$(grep -ciE 'is a directory|permission denied' "$WORK/log.v2" 2>/dev/null)"
  check "${v2n:-0}" 5 "(v) an unusable \$crumb.tmp falls back to an in-place trim — the bound STILL holds"
  check "${v2m:-0}" 1 "(v) …and the non-atomic fallback SAYS so instead of swallowing the failure"
  check "${v2e:-1}" 0 "(v) …and the TRIM path leaks no bash redirection error into the log either"

  # ── v0.11 the BACKOFF-tier REFRESH CAP (scenarios w–x) ────────────────────────
  # THE BLOCKER THIS PINS. v0.9 deleted the permanent give-up because it went silent on a
  # TRANSIENTLY deaf worker — correct. But the replacement ladder retries INDEFINITELY, and a
  # PERSISTENTLY deaf worker (a foreign process holding the channel's getUpdates slot, a channel
  # with no bot token) can never satisfy it: ~25 session-killing refreshes a day, forever. v0.19
  # lost the CHANNEL; an uncapped v0.20 loses the WORK, every <=60 minutes, indefinitely.
  # The fix bounds ONLY the expensive half. Both halves are asserted here, and the SECOND one is
  # the one that would silently regress into the original bug:
  #     (1) the refreshes STOP at BRIDGE_BOOT_BACKOFF_REFRESH_CAP, and
  #     (2) the ALARMS DO NOT — they keep firing on the same widening cadence for the whole
  #         multi-day outage, with a DISTINCT payload that says why we stopped restarting.
  # A suite that asserted only (1) would go green on a straight re-introduction of the give-up.

  # (w) a ~5-DAY persistent outage driven through the pinned clock seam: 122 belt ticks, cap 3.
  printf '1000 1001\n' > "$tree"; printf '1001|claude --channels\n' > "$args"
  BRIDGE_SEEN=0 BRIDGE_RESPAWN_STREAK=0 run_scenario '
    KICKOFF_DIR="$WORK/kick.w"; mkdir -p "$KICKOFF_DIR"; rm -f "$KICKOFF_DIR/bridge-escalated"
    TELEGRAM_STATE_DIR="$WORK/chan.w"; mkdir -p "$TELEGRAM_STATE_DIR"
    bridge_present() { return 1; }                       # persistently deaf: no restart can ever fix it
    FAKE_NOW=1000; bridge_now() { printf "%s\n" "$FAKE_NOW"; }
    bridge_jitter() { printf "0\n"; }                    # the jitter seam, pinned (scenario (u) drives the real one)
    : > "$WORK/log.w"; log() { printf "%s\n" "$*" >> "$WORK/log.w"; }
    SESSION_STARTED=0; BRIDGE_BOOT_GRACE_SECONDS=0; BRIDGE_BOOT_RETRY_CAP=1
    BRIDGE_BOOT_FAILS=0; BRIDGE_BOOT_BACKOFF_N=0; BRIDGE_BOOT_NEXT_AT=0; BRIDGE_BOOT_DEAF_SINCE=0
    BRIDGE_BOOT_BACKOFF_START=600; BRIDGE_BOOT_BACKOFF_MAX=3600
    BRIDGE_BOOT_REALARM_EVERY=3; BRIDGE_BOOT_LAST_ALARM_N=0
    BRIDGE_BOOT_BACKOFF_REFRESH_CAP=3
    bridge_liveness_step                                 # fast refresh #1
    bridge_liveness_step                                 # arm the tier (due at 1600)
    i=1; while [ "$i" -le 120 ]; do                      # walk the ladder to its next due-at, 120 times
      FAKE_NOW="$BRIDGE_BOOT_NEXT_AT"; bridge_liveness_step; i=$((i+1))
    done
    printf "%s\n" "$BRIDGE_BOOT_BACKOFF_N" > "$WORK/backoffn.w"
    printf "%s\n" "$(( (FAKE_NOW - 1000) / 3600 ))" > "$WORK/hours.w"'
  local wh wc wb wl wr wa wg wt
  wh="$(cat "$WORK/hours.w" 2>/dev/null || echo 0)"
  check "$([ "${wh:-0}" -ge 96 ] && echo yes || echo no)" "yes" "(w) the simulated outage really is multi-day (${wh}h of ladder walked)"
  # ── half ONE: the DESTRUCTIVE action is bounded ──
  check "$R_COUNT" 4 "(w) exactly 1 fast + CAP(3) backoff refreshes in ~${wh}h — then the session is never killed again"
  wb="$(grep -c 'bridge-neverup-backoff' "$REFRESH_LOG" 2>/dev/null)"
  check "${wb:-0}" 3 "(w) …and exactly CAP of them came from the BACKOFF tier (the fast tier is counted separately)"
  check "$(cat "$WORK/backoffn.w" 2>/dev/null || echo missing)" 120 "(w) the ladder keeps WALKING all 120 ticks — it is now the alarm clock, not a retry timer"
  # ── half TWO: the CHEAP action is NOT bounded (the half that would regress into the old bug) ──
  wc="$(grep -c '^capped ' "$ALARM_LOG" 2>/dev/null)"
  check "${wc:-0}" 39 "(w) the ALARM never stops — 39 capped re-alarms keep firing after the last refresh"
  wl="$(tail -n1 "$ALARM_LOG" 2>/dev/null || echo '')"
  check "$(case "$wl" in capped*) echo yes ;; *) echo no ;; esac)" "yes" \
        "(w) the FINAL word of a ~${wh}h outage is an ALARM, not silence (silence IS the deleted give-up)"
  check "$(grep -c '^backoff ' "$ALARM_LOG" 2>/dev/null)" 1 "(w) the still-retrying re-alarm stops when the retries do (its payload would be a lie after that)"
  wa="$(grep -m1 '^capped ' "$ALARM_LOG" 2>/dev/null || true)"
  check "$wa" "capped 3 130 3600" "(w) capped-alarm PAYLOAD: 3 restarts tried, deaf ~130m, next check in 3600s"
  # ── and the transition SAYS so, unmistakably and exactly once ──
  wr="$(grep -c 'REFRESH CAP REACHED' "$WORK/log.w" 2>/dev/null)"
  check "${wr:-0}" 1 "(w) the cap transition is logged DISTINCTLY and exactly once (not once per tick)"
  wg="$(grep -c 'alarm-only (restarts retired' "$WORK/log.w" 2>/dev/null)"
  check "${wg:-0}" 116 "(w) every later tick says alarm-only — the belt is awake and saying so, all 116 of them"
  wt="$(grep -c 'getUpdates slot.*TELEGRAM_BOT_TOKEN.*BRIDGE_LIVENESS=0' "$WORK/log.w" 2>/dev/null)"
  check "${wt:-0}" 1 "(w) the cap line names WHAT A HUMAN SHOULD CHECK (getUpdates holder / bot token / BRIDGE_LIVENESS=0)"

  # (x) the knob's USE-SITE clamp, and the capped alarm's actual operator-facing TEXT.
  #     THE CLAMP CAVEAT, stated rather than implied: the declaration + clamp in supervisor.sh's
  #     globals block sits OUTSIDE the KICKOFF-BRIDGE-UNIT markers and is UNREACHABLE by this
  #     suite — it can never be asserted here. bridge_boot_refresh_cap is the copy that actually
  #     runs inside the belt (the same pattern bridge_outage_trim uses for BRIDGE_OUTAGE_LOG_KEEP),
  #     so this asserts the clamp that is load-bearing at the decision point.
  run_scenario '
    unset BRIDGE_BOOT_BACKOFF_REFRESH_CAP; a="$(bridge_boot_refresh_cap)"          # unset -> default
    BRIDGE_BOOT_BACKOFF_REFRESH_CAP=nonsense; b="$(bridge_boot_refresh_cap)"       # garbage -> default
    BRIDGE_BOOT_BACKOFF_REFRESH_CAP=0;        c="$(bridge_boot_refresh_cap)"       # 0 -> floor (never delete recovery outright)
    BRIDGE_BOOT_BACKOFF_REFRESH_CAP=99999;    d="$(bridge_boot_refresh_cap)"       # huge -> ceiling (no unbounded restart loop)
    BRIDGE_BOOT_BACKOFF_REFRESH_CAP=4;        e="$(bridge_boot_refresh_cap)"       # a sane value passes through
    printf "%s %s %s %s %s\n" "$a" "$b" "$c" "$d" "$e" > "$WORK/cap.x"
    . "$UNIT_FILE"                                  # restore the units REAL alarm bodies over the harness observers
    : > "$WORK/tg.x"; tg_send_tokenless() { printf "%s|%s\n" "$1" "$2" >> "$WORK/tg.x"; }
    bridge_backoff_capped_alarm 6 250 3600'
  check "$(cat "$WORK/cap.x" 2>/dev/null || echo missing)" "6 6 1 1000 4" \
        "(x) the use-site refresh-cap clamp: default 6, garbage->6, 0->1, 99999->1000, 4 passes through"
  local x1 x2 x3
  x1="$(grep -c 'bridge-backoff-capped' "$WORK/tg.x" 2>/dev/null)"
  x2="$(grep -c 'STOPPED restarting' "$WORK/tg.x" 2>/dev/null)"
  x3="$(grep -c 'getUpdates slot.*TELEGRAM_BOT_TOKEN.*BRIDGE_LIVENESS=0' "$WORK/tg.x" 2>/dev/null)"
  check "${x1:-0}" 1 "(x) the capped alarm sends under its OWN label (bridge-backoff-capped), not the retrying one"
  check "${x2:-0}" 1 "(x) …and its TEXT tells the operator we STOPPED restarting and are still watching"
  check "${x3:-0}" 1 "(x) …and names the three things a human should check"
}

# ── run NEW (expect all green) ───────────────────────────────────────────────
echo "== assertions against NEW scripts/supervisor.sh =="
UNIT_FILE="$WORK/unit.new.sh"
if ! extract_unit "$SUPERVISOR_NEW" > "$UNIT_FILE"; then
  printf '  FAIL HARNESS: %s does not carry exactly one open + one close KICKOFF-BRIDGE-UNIT marker\n' "$SUPERVISOR_NEW"
  HARNESS_FATAL=1
fi
if ! bash -n "$UNIT_FILE" 2>/dev/null; then bad "extracted unit fails bash -n (new)"; fi
unit_bounds_ok "$UNIT_FILE" new || true    # reported + latched inside; the suite still runs so the failures are visible
suite
NEW_PASS=$PASS; NEW_FAIL=$FAIL

# ── RED-ON-OLD: same assertions against HEAD's supervisor.sh must FAIL ────────
echo
echo "== RED-on-old: same assertions against HEAD:scripts/supervisor.sh =="
OLD_SRC="$WORK/supervisor.old.sh"
if git -C "$SCRIPT_DIR" show HEAD:scripts/supervisor.sh > "$OLD_SRC" 2>/dev/null; then
  UNIT_FILE="$WORK/unit.old.sh"
  if ! extract_unit "$OLD_SRC" > "$UNIT_FILE"; then
    printf '  FAIL HARNESS: HEAD:scripts/supervisor.sh does not carry exactly one open + one close marker\n'
    HARNESS_FATAL=1
  fi
  # Load-bearing on THIS side too: a mis-bounded OLD unit fails every assertion, which the block
  # below would read as a passing RED-on-old proof. Checking only the NEW side would leave the
  # proof itself forgeable by a harness bug.
  unit_bounds_ok "$UNIT_FILE" old || true
  if cmp -s "$WORK/unit.new.sh" "$UNIT_FILE"; then
    # Working-tree unit is byte-identical to HEAD's (the normal post-commit state):
    # there is no behavioral delta to prove RED against — the proof is N/A, not failed.
    # The skip triggers ONLY on byte-identical units, so a real delta can never dodge it.
    RED_ON_OLD=skip; printf '  skip RED-on-old n/a — unit is byte-identical to HEAD (post-commit state; nothing new to prove)\n'
  else
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
  fi
else
  RED_ON_OLD=0; printf '  FAIL could not read HEAD:scripts/supervisor.sh to prove RED-on-old\n'
fi

echo
echo "== summary =="
printf 'NEW: pass=%s fail=%s   RED-on-old proven=%s   harness=%s\n' \
  "$NEW_PASS" "$NEW_FAIL" "${RED_ON_OLD:-0}" "$([ "$HARNESS_FATAL" -eq 0 ] && echo ok || echo BROKEN)"
# HARNESS_FATAL is checked FIRST and unconditionally: if the extraction was mis-bounded, neither
# the pass count nor the RED-on-old proof means anything, and reporting a number would be worse
# than reporting nothing.
if [ "$HARNESS_FATAL" -ne 0 ]; then
  echo "SELFTEST FAIL — harness broken (extraction bounds), results above are MEANINGLESS"; exit 1
fi
case "${RED_ON_OLD:-0}" in 1|skip)
  if [ "$NEW_FAIL" -eq 0 ]; then echo "SELFTEST PASS"; exit 0; fi ;;
esac
echo "SELFTEST FAIL"; exit 1
