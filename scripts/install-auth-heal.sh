#!/usr/bin/env bash
# install-auth-heal.sh — the GATED turnkey that wires the auth self-heal into the two
# LIVE lifecycle scripts. This exists because this repo IS the live worker's engine
# (memory/dogfood-repo-is-the-live-engine.md): a working-tree edit to supervisor.sh /
# session-run.sh goes live on the next refresh, so those edits are STAGED here and the
# OPERATOR applies them deliberately — dry-run first, backup-first, reversible.
#
# WHAT IT CHANGES (targeted, anchored edits — never a rewrite; everything else stays
# byte-identical):
#   scripts/supervisor.sh
#     S0  declare the crash-loop circuit-breaker globals (FASTDEATH_* + the backoff cap;
#         findings #1 + #8) — the S3 body reads them as bare set -u vars
#     S1  source scripts/auth-heal.sh (bash -n gated; absent/broken → a no-op stub)
#     S2  `auth_heal_step || true` once per poll, right after rotate_log
#     S3  gate the trigger-3 restart on `[ ! -f "$KICKOFF_DIR/auth-escalated" ]` AND add the
#         crash-loop circuit-breaker body + the finding #2 re-alarm (exponential backoff + a
#         distinct degraded alarm gated by crashloop_alarm_due, re-fired on a bounded cadence;
#         while auth is expired, restarting only spawns doomed sessions — additive to the gate)
#     S3d inject crashloop_alarm_due() (the finding #2 re-alarm cadence gate S3 now calls) as its
#         own anchored edit; the shipped core keeps this helper in the bridge unit, which this
#         maintainer retrofit does NOT ship (see SCOPE below) — so it is injected standalone.
#     S4  reset the crash-loop state on a HEALTHY refresh() (FASTDEATH_STREAK=0 +
#         FASTDEATH_LAST_ALARM_STREAK=0 + zero
#         announce.count) so a stale fast-death streak can't survive a deliberate refresh
#   SCOPE (deliberate): this retrofits the CRASH-LOOP CIRCUIT-BREAKER FAMILY = auth-heal +
#   circuit-breaker + the finding #2 long-outage re-alarm. It does NOT retrofit BRIDGE-LIVENESS
#   (finding #3): the BRIDGE_* globals + bridge_present/bridge_liveness_step/tg_send_tokenless/
#   bridge_degraded_alarm ship ONLY in the baked core supervisor.sh (adopters get them via
#   `kickoff pull`), never through this maintainer retrofit. The selftest's twin checks strip
#   those bridge lines from BOTH sides before the byte-compare (scope-matched, not gutted).
#   scripts/session-run.sh
#     R1  import CLAUDE_CODE_OAUTH_TOKEN from .kickoff/auth.env (0600, written by
#         relogin.sh) — the delivery leg of the re-login turnkey
#     R2  meaningful spawn announce: lead with the current work item off the mission
#         board, not "re-grounding…" (memory/operator-reconnect-message-meaningful.md)
#
# Deliberately NOT touched: .claude/settings.json — the SessionStart initialUserMessage
# hook is -p-mode-only per CC-internals (2026-07-07), so the pty --channels worker
# relies on the R2 spawn-heartbeat instead; the hook stays an unverified option.
#
# WHEN THE EDITS TAKE EFFECT (important):
#   - session-run.sh → the NEXT session refresh (touch .kickoff/refresh-requested)
#   - supervisor.sh  → only when the SUPERVISOR ITSELF restarts (it parsed its copy at
#     launch): kill -TERM "$(cat .kickoff/supervisor.lock)" && bash scripts/go-autonomous.sh
#   - and the whole thing stays INERT until KICKOFF_AUTH_HEAL=1 is set in
#     .kickoff/instance.env (re-read every poll — arming needs no further restart).
#
# USAGE
#   bash scripts/install-auth-heal.sh              # DRY-RUN: show the exact diff, change nothing
#   bash scripts/install-auth-heal.sh --apply      # selftest → backup → apply → bash -n verify
#   bash scripts/install-auth-heal.sh --rollback   # restore the most recent backup pair
#   bash scripts/install-auth-heal.sh --rollback <backup-dir>
#
# Test override (the selftest uses this — NEVER edits the real scripts):
#   KICKOFF_INSTALL_TARGET_DIR=/path/to/fixture/scripts bash scripts/install-auth-heal.sh --apply
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET_DIR="${KICKOFF_INSTALL_TARGET_DIR:-$HERE}"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
TARGET_REPO="$(cd "$TARGET_DIR/.." && pwd)"
SUP="$TARGET_DIR/supervisor.sh"
RUN="$TARGET_DIR/session-run.sh"
BACKUP_ROOT="${KICKOFF_INSTALL_BACKUP_DIR:-$TARGET_REPO/.kickoff/backups}"
MODE="${1:-dry-run}"

say() { printf '%s\n' "$*"; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || die "python3 required (the anchored-edit engine)"
[ -f "$SUP" ] || die "target supervisor.sh not found: $SUP"
[ -f "$RUN" ] || die "target session-run.sh not found: $RUN"

# A PULL ADOPTER's repo pins its core via .kickoff/core.lock — hand-editing core files
# is exactly the drift preflight #6 fails closed on. Refuse; the origin repo has no lock.
if [ -f "$TARGET_REPO/.kickoff/core.lock" ]; then
  die "this repo pins a pulled core (.kickoff/core.lock present) — do not hand-edit core scripts here. Take these edits via a core release (kickoff pull), or edit your pinned core deliberately and regenerate the lock."
fi

# ── the anchored-edit engine (python3: byte-exact, atomic os.replace) ─────────
# env: ENGINE_MODE (check|write) ENGINE_SUP ENGINE_RUN ENGINE_OUT
# For each edit: 'marker present' = already applied; else the anchor must appear
# EXACTLY once or we abort (a drifted live file must never be half-patched).
run_engine() {
  local engine_mode="$1" outdir="$2"
  ENGINE_MODE="$engine_mode" ENGINE_SUP="$SUP" ENGINE_RUN="$RUN" ENGINE_OUT="$outdir" \
  python3 - <<'PYEOF'
import sys, os

mode     = os.environ['ENGINE_MODE']
sup_path = os.environ['ENGINE_SUP']
run_path = os.environ['ENGINE_RUN']
outdir   = os.environ['ENGINE_OUT']

# S0 injects the crash-loop circuit-breaker GLOBALS (findings #1 + #8) PLUS the finding #2 re-alarm
# globals (FASTDEATH_LAST_ALARM_STREAK + FASTDEATH_REALARM_EVERY + its clamps). The S3 body below
# references $FASTDEATH_STREAK / $FASTDEATH_THRESHOLD_SECONDS / $FASTDEATH_ALARM_AT /
# $RESTART_BACKOFF_CAP_SECONDS as bare (set -u) vars, so a retrofit MUST declare them at the
# top or the first session death would abort the supervisor on an unbound var. S0_OLD is the
# pre-wiring RESTART_BACKOFF_SECONDS/DRY_RUN pair (byte-identical to the frozen fixture); S0_MARK
# (FASTDEATH_THRESHOLD_SECONDS= — a string UNIQUE to the S0 globals block, deliberately NOT
# 'FASTDEATH_STREAK=0' which S4 ALSO injects into refresh(): sharing that marker would let a
# partial-state target that carries S4's refresh-reset but not S0's globals falsely skip S0,
# leaving FASTDEATH_THRESHOLD_SECONDS/ALARM_AT/BACKOFF_CAP unbound → a set -u abort on the first
# death) is the idempotency marker.
S0_OLD = r'''RESTART_BACKOFF_SECONDS="${RESTART_BACKOFF_SECONDS:-5}"     # cool-down if a session crash-loops
DRY_RUN="${DRY_RUN:-0}"                            # 1 = print what it WOULD do; launch/kill nothing
'''
S0_NEW = r'''RESTART_BACKOFF_SECONDS="${RESTART_BACKOFF_SECONDS:-5}"     # cool-down if a session crash-loops
# crash-loop circuit-breaker (findings #1 + #8). The supervisor is ONE long-running process,
# so the crash-loop state is an IN-PROCESS shell var: no file, no pause-flag (a flag that
# never clears is a silent permanent outage, worse than the loop). FASTDEATH_STREAK counts
# consecutive FAST deaths (a session that lived < FASTDEATH_THRESHOLD_SECONDS = a doomed
# spawn, e.g. a weekly usage-limit death where auth stays VALID so auth-heal's D2 self-vetoes).
# Past FASTDEATH_ALARM_AT the restart backoff doubles per fast death up to
# RESTART_BACKOFF_CAP_SECONDS, killing the quota-burning tight loop while STILL retrying at the
# capped cadence, so it AUTO-RECOVERS the moment the cause clears (no manual clear, no flag).
FASTDEATH_THRESHOLD_SECONDS="${FASTDEATH_THRESHOLD_SECONDS:-60}"   # a death younger than this = a fast (doomed) death
FASTDEATH_ALARM_AT="${FASTDEATH_ALARM_AT:-3}"                      # flat backoff up to here; exponential + one alarm past it
RESTART_BACKOFF_CAP_SECONDS="${RESTART_BACKOFF_CAP_SECONDS:-1800}" # backoff ceiling (30m); never wedges, keeps retrying to auto-recover
FASTDEATH_STREAK=0                                                 # in-process streak; a normal-lifetime session resets it
# long-outage re-alarm (finding #2): the crash-loop alarm must not fire exactly ONCE and then go
# permanently silent while the outage persists — silence and spam are the same bug. Re-send the
# degraded alarm every FASTDEATH_REALARM_EVERY further fast-deaths (bounded, never every restart).
FASTDEATH_LAST_ALARM_STREAK=0                                      # streak at which we last alarmed (the re-alarm bookmark)
FASTDEATH_REALARM_EVERY="${FASTDEATH_REALARM_EVERY:-12}"           # re-send cadence in further fast-deaths (clamped below)
case "$FASTDEATH_REALARM_EVERY" in ''|*[!0-9]*) FASTDEATH_REALARM_EVERY=12 ;; esac
[ "$FASTDEATH_REALARM_EVERY" -lt 2 ]    && FASTDEATH_REALARM_EVERY=2      # a floor so it can never approximate every-restart spam
[ "$FASTDEATH_REALARM_EVERY" -gt 1000 ] && FASTDEATH_REALARM_EVERY=1000   # a ceiling so a fat-fingered knob can't mute it forever
DRY_RUN="${DRY_RUN:-0}"                            # 1 = print what it WOULD do; launch/kill nothing
'''
S0_MARK = 'FASTDEATH_THRESHOLD_SECONDS='

S1_OLD = r'''if [ -f "$SCRIPT_DIR/rotate-log.sh" ]; then
  # shellcheck source=scripts/rotate-log.sh
  . "$SCRIPT_DIR/rotate-log.sh"
else
  rotate_log() { :; }   # an older core without the rotator must never break the supervisor
fi
'''
S1_NEW = S1_OLD + r'''
# auth self-heal (CC token-expiry detector + escalate-to-turnkey; scripts/auth-heal.sh).
# INERT unless armed (KICKOFF_AUTH_HEAL=1 in .kickoff/instance.env). bash -n gates the
# source so a corrupt helper is never even parsed; missing/broken → a no-op stub —
# byte-identical behavior to a core without the helper (fail-toward-inaction).
if [ -f "$SCRIPT_DIR/auth-heal.sh" ] && bash -n "$SCRIPT_DIR/auth-heal.sh" 2>/dev/null; then
  # shellcheck source=scripts/auth-heal.sh
  . "$SCRIPT_DIR/auth-heal.sh" || true
fi
if ! command -v auth_heal_step >/dev/null 2>&1; then auth_heal_step() { :; }; fi
'''
S1_MARK = '. "$SCRIPT_DIR/auth-heal.sh" || true'

S2_OLD = r'''  # bound the append-only log IN PLACE (copytruncate — this supervisor's stdout is an open fd
  # on it, so a rename would leave us writing into .log.1 and .log empty; see rotate-log.sh)
  rotate_log "$SUPERVISOR_LOG"
'''
S2_NEW = S2_OLD + r'''
  # auth self-heal probe (scripts/auth-heal.sh; a no-op unless armed). `|| true`: a
  # probe error must NEVER abort the supervisor loop (fail-toward-inaction).
  auth_heal_step || true
'''
S2_MARK = 'auth_heal_step || true'

# S3 reproduces the FULL trigger-3 block (not just its head) so a retrofit lands BOTH the
# auth-escalated gate AND the crash-loop circuit-breaker (findings #1 + #8) in lockstep with
# the live supervisor.sh. S3_OLD is the pre-wiring FLAT block (byte-identical to the frozen
# testdata fixture); S3_NEW is the live gated + exponential-backoff block. The circuit-breaker
# is ADDITIVE to the gate — the `[ ! -f "$KICKOFF_DIR/auth-escalated" ]` condition (S3_MARK,
# the idempotency marker) is unchanged, so auth-expiry still pauses via the flag while the
# backoff is the separate always-on layer for valid-auth loops. S3_NEW's alarm gate is now
# crashloop_alarm_due (finding #2, injected by S3d) so the degraded alarm re-fires on a bounded
# cadence (FASTDEATH_REALARM_EVERY) instead of firing exactly once then going permanently silent.
S3_OLD = r'''  # trigger 3: the managed session ended on its own (finished -p run, or a crash)
  if ! session_alive; then
    log "session ended; restarting fresh (backoff ${RESTART_BACKOFF_SECONDS}s to avoid a crash-loop)"
    SESSION_PGID=""
    sleep "$RESTART_BACKOFF_SECONDS"
    start_session
  fi
'''
S3_NEW = r'''  # trigger 3: the managed session ended on its own (finished -p run, or a crash).
  # Gated on the auth-heal escalation flag: while auth is expired a restart only spawns
  # a doomed session (a restart can't mint a credential) — auth-heal clears the flag +
  # touches the refresh flag the moment auth is valid again (or relogin.sh does).
  if ! session_alive && [ ! -f "$KICKOFF_DIR/auth-escalated" ]; then
    SESSION_PGID=""
    # crash-loop circuit-breaker (findings #1 + #8): a session that lived a normal span
    # (incl. a normal refresh) resets the streak AND zeroes announce.count, so session-run's
    # "restart #N" counts the CURRENT bad streak, not lifetime (#8); a FAST death (younger
    # than the threshold = a doomed spawn) grows the streak and, past the alarm point, grows
    # the backoff, stopping a quota-burning tight loop without ever wedging.
    lifetime=$((SECONDS - SESSION_STARTED))
    if [ "$lifetime" -lt "$FASTDEATH_THRESHOLD_SECONDS" ]; then
      FASTDEATH_STREAK=$((FASTDEATH_STREAK + 1))
    else
      FASTDEATH_STREAK=0
      FASTDEATH_LAST_ALARM_STREAK=0                             # a normal-lifetime restart clears the re-alarm bookmark too
      echo 0 > "$KICKOFF_DIR/announce.count" 2>/dev/null || true
    fi
    # flat backoff up to the alarm point; above it, double per fast death, capped. Clamp the
    # shift exponent so a long outage's unbounded streak can't overflow the 64-bit shift into
    # a 0/negative sleep (which would itself become a tight loop / a failing sleep).
    if [ "$FASTDEATH_STREAK" -le "$FASTDEATH_ALARM_AT" ]; then
      backoff="$RESTART_BACKOFF_SECONDS"
    else
      fd_exp=$((FASTDEATH_STREAK - FASTDEATH_ALARM_AT))
      if [ "$fd_exp" -gt 30 ]; then fd_exp=30; fi
      backoff=$((RESTART_BACKOFF_SECONDS << fd_exp))
      if [ "$backoff" -gt "$RESTART_BACKOFF_CAP_SECONDS" ] || [ "$backoff" -lt "$RESTART_BACKOFF_SECONDS" ]; then
        backoff="$RESTART_BACKOFF_CAP_SECONDS"
      fi
    fi
    # honest alarm, fired ONCE as the streak crosses the alarm point: a DISTINCT degraded
    # message, NOT the cheerful "org is cooking" ping (#8). The whole send is a ( ... ) || true
    # subshell so the bot token never lands in a supervisor-scope var and no curl failure can
    # abort this loop; it reuses session-run.sh's tokenless recipe (token on curl stdin via
    # -K -, never argv). No quota-reset time is claimed (the session's stdout is /dev/null).
    if crashloop_alarm_due "$FASTDEATH_STREAK"; then
      # bookmark this streak so the NEXT re-alarm waits a bounded interval (finding #2) — never
      # every restart. Set before the send so a skipped/failed send still advances the bookmark.
      FASTDEATH_LAST_ALARM_STREAK="$FASTDEATH_STREAK"
      log "crash-loop: $FASTDEATH_STREAK fast deaths (<${FASTDEATH_THRESHOLD_SECONDS}s each) in a row; exponential backoff engaged (${backoff}s); sending the degraded alarm (re-alarm cadence every ${FASTDEATH_REALARM_EVERY})"
      if command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
        (
          _cb_tsd="${TELEGRAM_STATE_DIR:-}"
          _cb_ienv="${INSTANCE_ENV:-$KICKOFF_DIR/instance.env}"
          if [ -z "$_cb_tsd" ] && [ -f "$_cb_ienv" ]; then
            _cb_tsd="$( set +eu; . "$_cb_ienv" >/dev/null 2>&1 || true; printf '%s' "${TELEGRAM_STATE_DIR:-}" )"
          fi
          _cb_settings="${SETTINGS_FILE:-$REPO_DIR/.claude/settings.local.json}"
          _cb_access="$_cb_tsd/access.json"
          [ -n "$_cb_tsd" ] && [ -f "$_cb_settings" ] && [ -f "$_cb_access" ] || exit 0
          _cb_token="$(jq -r '.env.TELEGRAM_BOT_TOKEN // empty' "$_cb_settings" 2>/dev/null || true)"
          _cb_chat="$(jq -r '.allowFrom[0] // empty' "$_cb_access" 2>/dev/null || true)"
          [ -n "$_cb_token" ] && [ -n "$_cb_chat" ] || exit 0
          _cb_text="⚠️ Worker is crash-looping: $FASTDEATH_STREAK restarts in a row, each dying within ~${FASTDEATH_THRESHOLD_SECONDS}s. Likely out of quota (weekly cap) or a persistent fault. Backing off to ${backoff}s between retries and will keep trying; it AUTO-RECOVERS the moment the cause clears (quota reset / fault gone). This is NOT the usual cooking ping."
          printf 'url=%s\n' "https://api.telegram.org/bot${_cb_token}/sendMessage" \
            | curl -s -o /dev/null --max-time 10 \
                --data-urlencode "chat_id=${_cb_chat}" \
                --data-urlencode "text=${_cb_text}" \
                -K - 2>/dev/null || true
        ) || true
      else
        log "crash-loop alarm: jq/curl missing, degraded alert skipped (backoff still engaged)"
      fi
    fi
    log "session ended after ${lifetime}s; restarting fresh (fast-death streak $FASTDEATH_STREAK, backoff ${backoff}s)"
    sleep "$backoff"
    start_session
  fi
'''
S3_MARK = '[ ! -f "$KICKOFF_DIR/auth-escalated" ]'

# S4 retrofits refresh() to reset the crash-loop state on a HEALTHY restart, in lockstep with
# the live refresh() (FASTDEATH_STREAK=0 + FASTDEATH_LAST_ALARM_STREAK=0 + zero announce.count).
# Without it a retrofitted
# adopter carries a stale streak across refreshes (correct-but-suboptimal: extra backoff, never
# wedges) — S3 already grew the streak, only trigger-3's natural-death path reset it. The reset
# body is BYTE-IDENTICAL to the live refresh() block. S4_MARK is the DISTINCT comment first line
# (NOT 'FASTDEATH_STREAK=0' — that is S0's marker, which S0 injects into the globals, so it would
# false-positive "already applied" here; the comment is unique to the refresh reset). A newer core
# whose refresh() already carries the reset trips the marker → skip (never double-injects); and its
# anchor (the bare stop_session→rm→start_session shape) is absent there anyway, so no corruption.
S4_OLD = r'''  stop_session
  rm -f "$REFRESH_FLAG"
  start_session
}
'''
S4_NEW = r'''  stop_session
  rm -f "$REFRESH_FLAG"
  # A deliberate refresh (degradation flag / cadence) is a HEALTHY restart, not a crash: clear
  # the crash-loop streak + the spawn-announce counter so a prior fast-death streak can't carry
  # over and over-react to a later isolated blip, and session-run's next "restart #N" starts
  # fresh (#1). (Trigger-3 does the same for a natural death that lived past the threshold.)
  FASTDEATH_STREAK=0
  echo 0 > "$KICKOFF_DIR/announce.count" 2>/dev/null || true
  FASTDEATH_LAST_ALARM_STREAK=0
  start_session
}
'''
S4_MARK = 'A deliberate refresh (degradation flag / cadence) is a HEALTHY restart'

# S3d injects crashloop_alarm_due() — the re-alarm cadence gate (finding #2) that S3's trigger-3
# now CALLS. In the shipped core this helper lives inside the KICKOFF-BRIDGE-UNIT, but the installer
# does NOT retrofit bridge-liveness (finding #3 ships only via the baked core), so it injects the
# helper STANDALONE, right before refresh() — parsed + defined well before the poll loop runs
# trigger-3. Body is BYTE-IDENTICAL to supervisor.sh's; a retrofit that called it without defining
# it would abort on the first fast death. S_CAD_MARK ('crashloop_alarm_due() {') is unique to the
# DEFINITION — S3's CALL site does not contain it, so the marker can't false-hit 'already applied'.
S_CAD_OLD = r'''refresh() {
'''
S_CAD_NEW = r'''# crashloop_alarm_due (finding #2): is a crash-loop alarm DUE for this fast-death streak? Fires
# ONCE as the streak crosses the alarm point, then RE-fires only every FASTDEATH_REALARM_EVERY
# further fast-deaths (bounded, so a persistent outage re-pings but never spams). RETROFIT NOTE:
# the shipped core defines this inside its bridge unit; this installer injects it STANDALONE here
# (right before refresh(), so it is parsed + defined before the poll loop runs trigger-3) because
# it does NOT retrofit bridge-liveness (finding #3, which ships only via the baked core).
crashloop_alarm_due() {
  local streak="$1"
  local alarm_point=$((FASTDEATH_ALARM_AT + 1))
  [ "$streak" -lt "$alarm_point" ] && return 1                                      # below the alarm point: no alarm
  [ "$streak" -eq "$alarm_point" ] && return 0                                      # first alarm, exactly as before
  [ "$((streak - FASTDEATH_LAST_ALARM_STREAK))" -ge "$FASTDEATH_REALARM_EVERY" ] && return 0  # bounded re-alarm
  return 1
}

refresh() {
'''
S_CAD_MARK = 'crashloop_alarm_due() {'

R1_OLD = r'''# Which Telegram channel this worker is bridged to. NO baked-in default — fail LOUD if
'''
R1_NEW = r'''# ── AUTH ENV (scripts/relogin.sh turnkey) ─────────────────────────────────────
# .kickoff/auth.env carries ONLY a fresh CLAUDE_CODE_OAUTH_TOKEN (written 0600 by
# relogin.sh after a `claude setup-token` re-login; gitignored via .kickoff/). Imported
# with the SAME untrusted-config discipline as instance.env above: sourced in a
# SUBSHELL, only the ONE whitelisted name round-trips back through printf %q — the file
# can neither abort this wrapper nor forge launch-control vars. A pre-set env value
# wins; file absent → no-op (today's auth path, byte-identical).
AUTH_ENV="${AUTH_ENV:-$KICKOFF_DIR/auth.env}"
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -f "$AUTH_ENV" ]; then
  # shellcheck disable=SC1090
  eval "$(
    set +eu
    . "$AUTH_ENV" >/dev/null 2>&1 || true
    if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
      printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q\n' "$CLAUDE_CODE_OAUTH_TOKEN"
    fi
  )"
fi

# Which Telegram channel this worker is bridged to. NO baked-in default — fail LOUD if
'''
R1_MARK = 'AUTH_ENV="${AUTH_ENV:-$KICKOFF_DIR/auth.env}"'

R2A_OLD = r'''  # Record the send time only when we actually send, so the cooldown gates real sends.
  echo "$now" > "$KICKOFF_DIR/announce.last" 2>/dev/null || true
'''
R2A_NEW = R2A_OLD + r'''
  # Meaningful announce (memory/operator-reconnect-message-meaningful.md): lead with
  # the WORK, not the refresh mechanics. Read the CURRENT board state — the `headline`
  # is the coordinator-maintained "what's the org doing now" line, rewritten at every
  # checkpoint; `in_progress[0]` is insertion-ordered so its [0] is the OLDEST item and
  # fossilizes as the org marches on (it froze the ping for ~10 restarts — msg 1492). So
  # prefer the headline, fall back to in_progress[0] (an adopter with no headline yet),
  # treating an empty-string headline as absent. Any failure degrades to the generic
  # line — the announce itself must never break on a board hiccup.
  local work="" text=""
  local mc_state="${MC_STATE_FILE:-$REPO_DIR/mission-control/mission-state.json}"
  if [ -f "$mc_state" ]; then
    work="$(jq -r '[.headline, .in_progress[0].text] | map(select(type=="string" and . != "")) | .[0] // ""' "$mc_state" 2>/dev/null || true)"
    work="${work//$'\n'/ }"
    if [ "${#work}" -gt 160 ]; then work="${work:0:157}…"; fi
  fi
  if [ -n "$work" ]; then
    text="👨‍🍳 Worker back (restart #${count}) — org is cooking on: ${work}"
  else
    text="👨‍🍳 Worker back (restart #${count}) — re-grounded; ping me a steer."
  fi
'''
R2A_MARK = 'org is cooking on: ${work}'

R2B_OLD = r'''       --data-urlencode "text=🔄 Worker session restart #${count} — re-grounding…" \
'''
R2B_NEW = r'''       --data-urlencode "text=${text}" \
'''
R2B_MARK = '--data-urlencode "text=${text}" \\'

EDITS = {
    sup_path: [('S0 crash-loop circuit-breaker globals', S0_OLD, S0_NEW, S0_MARK),
               ('S1 source auth-heal.sh (guarded)', S1_OLD, S1_NEW, S1_MARK),
               ('S2 auth_heal_step per poll',       S2_OLD, S2_NEW, S2_MARK),
               ('S3 gate trigger-3 + crash-loop circuit-breaker', S3_OLD, S3_NEW, S3_MARK),
               ('S3d crashloop_alarm_due() helper (re-alarm cadence, #2)', S_CAD_OLD, S_CAD_NEW, S_CAD_MARK),
               ('S4 refresh() resets the crash-loop streak + re-alarm bookmark', S4_OLD, S4_NEW, S4_MARK)],
    run_path: [('R1 import .kickoff/auth.env token', R1_OLD, R1_NEW, R1_MARK),
               ('R2a meaningful announce text',      R2A_OLD, R2A_NEW, R2A_MARK),
               ('R2b announce uses ${text}',         R2B_OLD, R2B_NEW, R2B_MARK)],
}

failures, results = [], []
for path, edits in EDITS.items():
    with open(path, encoding='utf-8') as f:
        content = f.read()
    changed = False
    for label, old, new, mark in edits:
        if mark in content:
            results.append(f'= {os.path.basename(path)}: {label} — already applied')
            continue
        n = content.count(old)
        if n != 1:
            failures.append(f'{os.path.basename(path)}: {label} — anchor found {n}x (expected exactly 1; live file has drifted, refusing)')
            continue
        content = content.replace(old, new, 1)
        changed = True
        results.append(f'+ {os.path.basename(path)}: {label} — {"applied" if mode == "write" else "would apply"}')
    out = os.path.join(outdir, os.path.basename(path))
    if mode == 'write' and changed and not failures:
        tmp = path + '.new'
        st = os.stat(path)
        with open(tmp, 'w', encoding='utf-8') as f:
            f.write(content)
        os.chmod(tmp, st.st_mode & 0o7777)
        os.replace(tmp, path)   # atomic: a running bash keeps its old inode untouched
    if mode == 'check':
        with open(out, 'w', encoding='utf-8') as f:
            f.write(content)

print('\n'.join(results))
if failures:
    print('ANCHOR FAILURES:', file=sys.stderr)
    print('\n'.join(failures), file=sys.stderr)
    sys.exit(1)
PYEOF
}

show_next_actions() {
  say ""
  say "next actions:"
  say "  1. arm it (takes effect within ~15s, no restart):  add to $TARGET_REPO/.kickoff/instance.env:"
  say "       export KICKOFF_AUTH_HEAL=\"\${KICKOFF_AUTH_HEAL:-1}\""
  say "  2. session-run.sh edits go live on the NEXT session refresh:"
  say "       touch $TARGET_REPO/.kickoff/refresh-requested     (or Telegram /refresh)"
  say "  3. supervisor.sh edits need a SUPERVISOR restart (it parsed its copy at launch):"
  say "       kill -TERM \"\$(cat $TARGET_REPO/.kickoff/supervisor.lock)\" && bash $TARGET_DIR/go-autonomous.sh"
  say "  4. watch it:  tail -f $TARGET_REPO/.kickoff/supervisor.log   (look for [auth-heal] lines)"
  say "  5. revert anytime:  bash $HERE/install-auth-heal.sh --rollback"
}

case "$MODE" in
  dry-run|--dry-run)
    say "── install-auth-heal DRY-RUN (nothing will change) ─────────────"
    say "target: $SUP"
    say "        $RUN"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    run_engine check "$tmp" || die "anchors did not match — the live files have drifted from what these edits were built against. Re-stage against the current files before applying."
    say ""
    say "exact staged diff:"
    for f in supervisor.sh session-run.sh; do
      if ! diff -u "$TARGET_DIR/$f" "$tmp/$f" > "$tmp/$f.diff" 2>/dev/null; then :; fi
      if [ -s "$tmp/$f.diff" ]; then cat "$tmp/$f.diff"; else say "  $f: no change (already applied)"; fi
    done
    say ""
    for f in supervisor.sh session-run.sh; do
      bash -n "$tmp/$f" || die "the STAGED $f does not parse — refusing (report this, do not apply)"
    done
    say "✓ both staged results parse (bash -n)"
    say ""
    say "apply with:  bash $HERE/install-auth-heal.sh --apply"
    ;;

  --apply)
    say "── install-auth-heal APPLY ─────────────────────────────────────"
    # gate on the selftest unless the selftest itself is driving us
    if [ "${KICKOFF_INSTALL_NO_SELFTEST:-0}" != "1" ]; then
      if [ -f "$HERE/auth-heal-selftest.sh" ]; then
        say "running auth-heal-selftest.sh first (KICKOFF_INSTALL_NO_SELFTEST=1 skips)…"
        bash "$HERE/auth-heal-selftest.sh" >/dev/null 2>&1 || die "auth-heal-selftest.sh FAILED — not applying anything. Run it directly to see why."
        say "✓ selftest green"
      else
        say "⚠ no auth-heal-selftest.sh next to this script — applying without the test gate"
      fi
    fi
    # nothing-to-do guard: if every edit is already applied, do NOT create a backup —
    # a backup of already-patched files would become the "newest" rollback target and
    # make --rollback restore the PATCHED state instead of the original.
    pre="$(mktemp -d)"
    if precheck="$(run_engine check "$pre")" && ! grep -q '^+' <<<"$precheck"; then
      rm -rf "$pre"
      say "$precheck"
      say "already installed — every edit is in place; nothing to do."
      show_next_actions
      exit 0
    fi
    rm -rf "$pre"
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    bdir="$BACKUP_ROOT/auth-heal-$ts"
    mkdir -p "$bdir"
    cp -p "$SUP" "$bdir/supervisor.sh"
    cp -p "$RUN" "$bdir/session-run.sh"
    say "✓ backups: $bdir/{supervisor.sh,session-run.sh}"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    run_engine write "$tmp" || { say "anchors failed — nothing was written (files untouched)"; exit 1; }
    ok=1
    for f in "$SUP" "$RUN"; do
      if ! bash -n "$f" 2>&1; then ok=0; fi
    done
    if [ "$ok" != "1" ]; then
      say "✗ post-apply bash -n FAILED — AUTO-ROLLBACK from $bdir"
      cp -p "$bdir/supervisor.sh" "$SUP"
      cp -p "$bdir/session-run.sh" "$RUN"
      die "rolled back; live files restored byte-identically. Report this."
    fi
    say "✓ post-apply bash -n green on both files"
    say ""
    say "applied diff (vs the backup):"
    if ! diff -u "$bdir/supervisor.sh" "$SUP"; then :; fi
    if ! diff -u "$bdir/session-run.sh" "$RUN"; then :; fi
    show_next_actions
    ;;

  --rollback)
    pick="${2:-}"
    if [ -z "$pick" ]; then
      pick="$(ls -1d "$BACKUP_ROOT"/auth-heal-* 2>/dev/null | sort | tail -1 || true)"
    fi
    [ -n "$pick" ] && [ -d "$pick" ] || die "no backup found under $BACKUP_ROOT (nothing to roll back to)"
    [ -f "$pick/supervisor.sh" ] && [ -f "$pick/session-run.sh" ] || die "backup incomplete: $pick"
    say "── install-auth-heal ROLLBACK from $pick ──"
    cp -p "$pick/supervisor.sh" "$SUP.new" && mv -f "$SUP.new" "$SUP"
    cp -p "$pick/session-run.sh" "$RUN.new" && mv -f "$RUN.new" "$RUN"
    for f in "$SUP" "$RUN"; do bash -n "$f" || die "restored $f does not parse?! Inspect $pick manually."; done
    say "✓ restored supervisor.sh + session-run.sh from the backup (bash -n green)"
    say "  remember: the RUNNING supervisor still uses what it parsed at ITS launch —"
    say "  restart it to make the rollback live:  kill -TERM \"\$(cat $TARGET_REPO/.kickoff/supervisor.lock)\" && bash $TARGET_DIR/go-autonomous.sh"
    ;;

  *)
    die "unknown mode '$MODE' — use: (no args = dry-run) | --apply | --rollback [backup-dir]"
    ;;
esac
