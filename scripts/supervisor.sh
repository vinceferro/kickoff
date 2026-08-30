#!/usr/bin/env bash
# supervisor.sh — the session-refresh supervisor (claude-kickoff)
#
# Sits ABOVE the agent process and owns session lifecycle, so context refresh
# never depends on a human at a terminal. A non-technical operator can't run
# `/clear` or `/compact` (those are terminal commands; sent over Telegram they
# just arrive as text — the agent cannot restart itself). This watcher does it.
#
# It restarts the session — which re-grounds from CLAUDE.md + memory/ + TRACKER.md
# (lossless, because the file-memory is the substrate) — on any of these triggers:
#   1. a refresh-flag file appears   (the agent writes it when it detects its own
#      degradation — see CLAUDE.md "Context discipline" — or a /refresh handler touches it)
#   2. a max-session cadence elapses (optional)
#   3. the managed session ends on its own (a finished -p run, a crash) → restart fresh
#
# Telegram /refresh: this supervisor does NOT poll Telegram itself (text messages
# stream straight into the agent's stdin as <channel> blocks — they do not land as
# files a watcher can read). The /refresh path is: the AGENT receives "/refresh" and
# touches the flag:  touch "$REPO_DIR/.kickoff/refresh-requested"  (one line, no
# terminal needed). That is the documented contract — the flag is the single
# mechanism the supervisor watches, and every trigger funnels through it.
#
# ── SAFETY (this script kills + restarts a session) ─────────────────────────
# It NEVER pattern-kills. It targets ONLY the one session IT launched, by:
#   - launching the session in its own PROCESS GROUP (setsid), and
#   - recording that group's PID in a PIDFILE, then signalling that group ONLY.
# No `pkill`, no `kill -f <pattern>` — a name/pattern kill can't tell the live
# board (`server.py 9200`) or demo from a throwaway, and has taken the board
# down before (see memory/dont-broad-pkill-shared-services.md). The process-group
# target means a refresh reaches the real `claude` child AND its descendants,
# while touching nothing else on the box.
#
# What it starts (START_CMD): by default scripts/session-run.sh — a PERSISTENT,
# Telegram-bridged (claude --channels), self-announcing, re-grounding interactive
# session (the real unattended worker; see RUNNING.md). NOT a one-shot `claude -p`
# (that EOFs stdin and kills the Telegram bridge after one turn).
#
# Honest scope: this manages the `claude` child IT launches (the hosted-worker /
# non-tech case). It CANNOT restart an interactive session a human is sitting in —
# for the dev case the fair-friction fallback is the human running /clear.
#
# ── USAGE ───────────────────────────────────────────────────────────────────
#   REPO_DIR=~/my-project MAX_SESSION_SECONDS=7200 bash scripts/supervisor.sh
#   DRY_RUN=1 bash scripts/supervisor.sh          # prove the logic; launches/kills NOTHING
#   touch "$REPO_DIR/.kickoff/refresh-requested"  # the /refresh trigger (agent does this)

set -euo pipefail

REPO_DIR="${REPO_DIR:-$(pwd)}"
REPO_DIR="$(cd "$REPO_DIR" && pwd)"               # normalise to an absolute path
# Where the CORE scripts live (this supervisor + its sibling session-run.sh / preflight.sh).
# Resolve siblings relative to THIS script, NOT $REPO_DIR: a pull adopter runs the core
# scripts from ~/kickoff-core while REPO_DIR is their OWN repo (which has no core scripts).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# The core repo ROOT (the clone a pull adopter runs these scripts FROM). SCRIPT_DIR is
# <core>/scripts, so the core root is its parent. We pass this to preflight EXPLICITLY so
# check #6 (core.lock integrity) is based on the core we are ACTUALLY executing — not on
# whatever KICKOFF_CORE_DIR instance.env happens to set (finding #15). An explicit pre-set
# value still wins (mirrors cmd_pull's precedence).
KICKOFF_CORE_DIR="${KICKOFF_CORE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
KICKOFF_DIR="$REPO_DIR/.kickoff"
REFRESH_FLAG="${REFRESH_FLAG:-$KICKOFF_DIR/refresh-requested}"
PIDFILE="${PIDFILE:-$KICKOFF_DIR/supervisor.session.pid}"   # the ONE session we manage
LOCKFILE="${LOCKFILE:-$KICKOFF_DIR/supervisor.lock}"        # single-supervisor guard
MAX_SESSION_SECONDS="${MAX_SESSION_SECONDS:-0}"   # 0 = no cadence; e.g. 7200 = refresh every 2h
POLL_SECONDS="${POLL_SECONDS:-15}"
RESTART_BACKOFF_SECONDS="${RESTART_BACKOFF_SECONDS:-5}"     # cool-down if a session crash-loops
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
# bridge-liveness (finding #3): the default session runs `claude --channels`, which spawns a
# Telegram BRIDGE (a bun process running the plugin server.ts) — the operator's ONLY inbound
# channel + the reply tool. It can CRASH while the claude session stays ALIVE (silence both ways)
# and does NOT self-respawn; a full refresh (a fresh `claude --channels`) is the proven recovery
# (memory/telegram-bridge-crash-recovery-via-refresh.md). All in-process state (no files); the
# BRIDGE_SEEN latch makes the whole feature inert whenever no bridge exists (a non-channels
# START_CMD / DRY_RUN never sets it, so it can never trigger a spurious refresh).
BRIDGE_LIVENESS="${BRIDGE_LIVENESS:-1}"                            # 1 = watch the bridge (default on, for the channels case)
BRIDGE_RESPAWN_CAP="${BRIDGE_RESPAWN_CAP:-3}"                      # consecutive bridge-triggered refreshes before giving up (G3)
case "$BRIDGE_RESPAWN_CAP" in ''|*[!0-9]*) BRIDGE_RESPAWN_CAP=3 ;; esac
[ "$BRIDGE_RESPAWN_CAP" -lt 1 ] && BRIDGE_RESPAWN_CAP=1
BRIDGE_SEEN=0                                                      # G1 latch: has THIS session shown its bridge yet?
BRIDGE_SEEN_AT=0                                                   # SECONDS when the bridge was first seen (healthy-span reset)
BRIDGE_RESPAWN_STREAK=0                                            # consecutive bridge-only respawns (mirrors FASTDEATH_STREAK)
BRIDGE_RESPAWN_GIVEUP=0                                            # latched once the cap trips — stop auto-refreshing on bridge death
# v0.6 fail-loud (the never-came-up gap): the v0.5 belt reacts only to a bridge that died AFTER
# being seen — a bridge that NEVER appears (the "silent gag": a mis-specced/gagged channel spec,
# a foreign consumer holding the bot's getUpdates slot) triggered NOTHING and the worker sat
# deaf-but-computing. bridge_boot_check (in the unit below) now escalates LOUDLY once a boot
# grace elapses with no bridge: durable flag .kickoff/bridge-escalated (mirrors auth-escalated,
# but deliberately NOT gating trigger-3 — see below) + ONE tokenless alert + at most
# BRIDGE_BOOT_RETRY_CAP guarded refreshes, then it STOPS (repeated restarts are the wrong move
# for a bridge that never boots). Detection only applies when the instance has a derivable
# TELEGRAM_STATE_DIR (a non-telegram START_CMD stays exempt, preserving the v0.5 inertness).
BRIDGE_BOOT_GRACE_SECONDS="${BRIDGE_BOOT_GRACE_SECONDS:-120}"      # max seconds for a fresh session's bridge to APPEAR
case "$BRIDGE_BOOT_GRACE_SECONDS" in ''|*[!0-9]*) BRIDGE_BOOT_GRACE_SECONDS=120 ;; esac
BRIDGE_BOOT_RETRY_CAP="${BRIDGE_BOOT_RETRY_CAP:-1}"                # guarded bridge-neverup refreshes before giving up
case "$BRIDGE_BOOT_RETRY_CAP" in ''|*[!0-9]*) BRIDGE_BOOT_RETRY_CAP=1 ;; esac
BRIDGE_BOOT_FAILS=0                                                # consecutive bridge-neverup refreshes this outage (in-process)
BRIDGE_BOOT_GIVEUP=0                                               # latched once the boot-retry cap trips
DRY_RUN="${DRY_RUN:-0}"                            # 1 = print what it WOULD do; launch/kill nothing

# The command that starts a fresh session. Override for your harness/worker.
# Default spawns the real persistent, Telegram-bridged, self-announcing,
# re-grounding worker (scripts/session-run.sh) — NOT a one-shot `claude -p`
# (which would EOF stdin and kill the Telegram bridge after one turn).
START_CMD="${START_CMD:-bash \"$SCRIPT_DIR/session-run.sh\"}"

# Bound the append-only log this supervisor's stdout is redirected into (by the launcher's
# `>>"$LOG"`) so it can't grow unbounded inside the "contained" .kickoff/ folder (RUN §2.2 /
# finding #18). We rotate it IN-PLACE (copytruncate) from the poll loop — an `mv` would orphan
# the log into .log.1 while our still-open stdout fd kept writing to the renamed inode. The
# launcher passes the path via KICKOFF_SUPERVISOR_LOG so both sides target the SAME file.
SUPERVISOR_LOG="${KICKOFF_SUPERVISOR_LOG:-$KICKOFF_DIR/supervisor.log}"
if [ -f "$SCRIPT_DIR/rotate-log.sh" ]; then
  # shellcheck source=scripts/rotate-log.sh
  . "$SCRIPT_DIR/rotate-log.sh"
else
  rotate_log() { :; }   # an older core without the rotator must never break the supervisor
fi

# auth self-heal (CC token-expiry detector + escalate-to-turnkey; scripts/auth-heal.sh).
# INERT unless armed (KICKOFF_AUTH_HEAL=1 in .kickoff/instance.env). bash -n gates the
# source so a corrupt helper is never even parsed; missing/broken → a no-op stub —
# byte-identical behavior to a core without the helper (fail-toward-inaction).
if [ -f "$SCRIPT_DIR/auth-heal.sh" ] && bash -n "$SCRIPT_DIR/auth-heal.sh" 2>/dev/null; then
  # shellcheck source=scripts/auth-heal.sh
  . "$SCRIPT_DIR/auth-heal.sh" || true
fi
if ! command -v auth_heal_step >/dev/null 2>&1; then auth_heal_step() { :; }; fi

mkdir -p "$KICKOFF_DIR"

log() { printf '[supervisor %s] %s\n' "$(date -u +%H:%M:%S 2>/dev/null || echo now)" "$*"; }

# ── single-supervisor guard ─────────────────────────────────────────────────
# Avoid two supervisors fighting over the same managed session. Use a pidfile
# lock that's reclaimed only if the recorded supervisor is genuinely gone.
acquire_lock() {
  if [ -f "$LOCKFILE" ]; then
    local other; other="$(cat "$LOCKFILE" 2>/dev/null || echo "")"
    # Only a POSITIVE integer is a live PID (mirror preflight #4's ^[1-9][0-9]*$): a corrupt
    # '0' / negative / non-numeric lock must be RECLAIMED, not handed to `kill -0` — `kill -0 0`
    # signals our OWN process group and would falsely read as "another supervisor is running".
    case "$other" in ''|0*|*[!0-9]*) other="" ;; esac
    if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
      log "another supervisor is already running (pid=$other) — refusing to start a second"
      exit 1
    fi
    log "stale lock from pid=$other — reclaiming"
  fi
  echo "$$" > "$LOCKFILE"
}

# ── fail-closed preflight (R2) — run BEFORE acquire_lock ─────────────────────
# The instance preflight (scripts/preflight.sh) turns the adopt-time WARNINGS
# (distinct Telegram channel, resolvable memory index, single supervisor, …)
# into ENFORCED assertions. We run it here, BEFORE we take our own lock, so its
# single-supervisor check sees only OTHER live supervisors — not ourselves.
# FAIL-CLOSED: a non-zero preflight is a HARD STOP — we do NOT start a session on
# a mis-configured instance (a false-pass here is worse than not running).
# Honored even in DRY_RUN (proving the gate is the whole point); the ONLY bypass
# is PREFLIGHT_SKIP=1 for emergencies, logged loudly.
run_preflight() {
  local pf="$SCRIPT_DIR/preflight.sh"
  if [ "${PREFLIGHT_SKIP:-0}" = "1" ]; then
    log "!! PREFLIGHT_SKIP=1 — SKIPPING the fail-closed preflight (emergency override). Flying WITHOUT the instance safety contract."
    return 0
  fi
  if [ ! -f "$pf" ]; then
    log "FATAL: preflight script missing ($pf) — refusing to start (fail-closed)."
    exit 1
  fi
  log "running fail-closed preflight before acquiring lock ($pf)…"
  if REPO_DIR="$REPO_DIR" \
     INSTANCE_ENV="${INSTANCE_ENV:-$KICKOFF_DIR/instance.env}" \
     LOCKFILE="$LOCKFILE" \
     KICKOFF_CORE_DIR="$KICKOFF_CORE_DIR" \
     bash "$pf"; then
    log "preflight PASSED — proceeding to acquire lock + start session."
  else
    log "FATAL: preflight FAILED — refusing to start a session. Fix the instance config (or PREFLIGHT_SKIP=1 to force, unsafe)."
    exit 1
  fi
}

# ── session lifecycle (process-group targeted; NEVER a pattern kill) ─────────
have_setsid() { command -v setsid >/dev/null 2>&1; }

start_session() {
  SESSION_STARTED=$SECONDS
  # G1: a fresh session has NOT shown its Telegram bridge yet — reset the seen-latch so the
  # bridge-liveness probe only reacts to a MISSING bridge once THIS session has shown one.
  BRIDGE_SEEN=0
  BRIDGE_SEEN_AT=0
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN — would start a fresh session in $REPO_DIR with:"
    printf '            %s\n' "$START_CMD"
    log "DRY_RUN — would record its process-group PID in $PIDFILE"
    # simulate a live child so the rest of the loop can be exercised safely
    SESSION_PGID="DRY-$RANDOM"
    echo "$SESSION_PGID" > "$PIDFILE"
    return 0
  fi
  log "starting a fresh session in $REPO_DIR"
  # Launch in its OWN process group so we can later signal that group ONLY.
  # `setsid` makes the child a process-group/session leader; its PID == the PGID.
  if have_setsid; then
    setsid bash -c "cd \"$REPO_DIR\" && exec $START_CMD" &
    SESSION_PGID=$!
  else
    # Fallback: bash job control puts a backgrounded pipeline in its own group;
    # `set -m` enables it so $! is still a group we can target with kill -- -PID.
    set -m
    ( cd "$REPO_DIR" && exec $START_CMD ) &
    SESSION_PGID=$!
    set +m
  fi
  echo "$SESSION_PGID" > "$PIDFILE"
  log "session process-group pgid=$SESSION_PGID (pidfile=$PIDFILE)"
}

# Is the managed session still alive? (group leader still present.)
session_alive() {
  [ -n "${SESSION_PGID:-}" ] || return 1
  [ "$DRY_RUN" = "1" ] && return 0          # DRY_RUN: treat as alive until we "refresh" it
  kill -0 "$SESSION_PGID" 2>/dev/null
}

stop_session() {
  [ -n "${SESSION_PGID:-}" ] || return 0
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN — would stop ONLY process-group pgid=$SESSION_PGID with:  kill -TERM -- -$SESSION_PGID  (then -KILL after grace)"
    log "DRY_RUN — note: targets that ONE group via the pidfile — never pkill / never a name pattern"
    SESSION_PGID=""
    return 0
  fi
  if kill -0 "$SESSION_PGID" 2>/dev/null; then
    log "stopping ONLY process-group pgid=$SESSION_PGID (graceful TERM)"
    # The leading '-' targets the PROCESS GROUP, reaching the session + its
    # descendants — and nothing outside the group we launched.
    kill -TERM -- "-$SESSION_PGID" 2>/dev/null || kill -TERM "$SESSION_PGID" 2>/dev/null || true
    for _ in 1 2 3 4 5; do kill -0 "$SESSION_PGID" 2>/dev/null || break; sleep 1; done
    if kill -0 "$SESSION_PGID" 2>/dev/null; then
      log "session pgid=$SESSION_PGID did not exit on TERM — hard KILL (group only)"
      kill -KILL -- "-$SESSION_PGID" 2>/dev/null || kill -KILL "$SESSION_PGID" 2>/dev/null || true
    fi
  fi
  SESSION_PGID=""
  : > "$PIDFILE"
}

refresh() {
  local why="$1"
  log "REFRESH ($why) — checkpoint should already be in memory/ + TRACKER.md"
  stop_session
  rm -f "$REFRESH_FLAG"
  # A deliberate refresh (degradation flag / cadence) is a HEALTHY restart, not a crash: clear
  # the crash-loop streak + the spawn-announce counter so a prior fast-death streak can't carry
  # over and over-react to a later isolated blip, and session-run's next "restart #N" starts
  # fresh (#1). (Trigger-3 does the same for a natural death that lived past the threshold.)
  FASTDEATH_STREAK=0
  echo 0 > "$KICKOFF_DIR/announce.count" 2>/dev/null || true
  # bridge-liveness + re-alarm bookkeeping (added lines, existing body above preserved). A NON-bridge
  # refresh is a clean restart — clear the bridge respawn streak + the re-alarm bookmark so a later
  # blip re-alarms from scratch. A `bridge-dead` refresh must KEEP its streak so the respawn CAP (G3)
  # can trip — otherwise a persistently-failing bridge would loop forever (the session stays alive, so
  # the crash-loop breaker never sees it).
  FASTDEATH_LAST_ALARM_STREAK=0
  # (v0.6: the non-bridge arm also resets the never-up bookkeeping — a clean restart re-arms the
  # boot-grace detector from scratch; a `bridge-*` refresh keeps BOTH streaks so both caps can trip.)
  case "$why" in bridge-*) : ;; *) BRIDGE_RESPAWN_STREAK=0; BRIDGE_RESPAWN_GIVEUP=0; BRIDGE_BOOT_FAILS=0; BRIDGE_BOOT_GIVEUP=0 ;; esac
  start_session
}

# ── bridge-liveness + crash-loop re-alarm (findings #3 + #2) ─────────────────
# EXTRACTED as one contiguous unit (between the >>> / <<< marker lines below) by
# scripts/supervisor-liveness-selftest.sh, which drives it with stubs so the logic
# is asserted hermetically — no real session, no live worker touched.
# >>> KICKOFF-BRIDGE-UNIT >>>

# Send a Telegram message WITHOUT the bot token ever reaching argv / the process table
# (token fed to curl via `-K -` on stdin; the whole send wrapped in a ( … ) || true subshell
# so no failure/leak can abort the poll loop). Mirrors session-run.sh's announce_restart recipe.
tg_send_tokenless() {
  local _text="$1"
  command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 || return 0
  (
    _tsd="${TELEGRAM_STATE_DIR:-}"
    _ienv="${INSTANCE_ENV:-$KICKOFF_DIR/instance.env}"
    if [ -z "$_tsd" ] && [ -f "$_ienv" ]; then
      _tsd="$( set +eu; . "$_ienv" >/dev/null 2>&1 || true; printf '%s' "${TELEGRAM_STATE_DIR:-}" )"
    fi
    _settings="${SETTINGS_FILE:-$REPO_DIR/.claude/settings.local.json}"
    _access="$_tsd/access.json"
    [ -n "$_tsd" ] && [ -f "$_settings" ] && [ -f "$_access" ] || exit 0
    _token="$(jq -r '.env.TELEGRAM_BOT_TOKEN // empty' "$_settings" 2>/dev/null || true)"
    _chat="$(jq -r '.allowFrom[0] // empty' "$_access" 2>/dev/null || true)"
    [ -n "$_token" ] && [ -n "$_chat" ] || exit 0
    printf 'url=%s\n' "https://api.telegram.org/bot${_token}/sendMessage" \
      | curl -s -o /dev/null --max-time 10 \
          --data-urlencode "chat_id=${_chat}" \
          --data-urlencode "text=${_text}" \
          -K - 2>/dev/null || true
  ) || true
}

# Finding #2: is a crash-loop alarm DUE for this fast-death streak? Fires ONCE as the streak
# crosses the alarm point, then RE-fires only every FASTDEATH_REALARM_EVERY further fast-deaths
# — bounded, so a persistent outage re-pings but never spams (silence and spam are the same bug).
crashloop_alarm_due() {
  local streak="$1"
  local alarm_point=$((FASTDEATH_ALARM_AT + 1))
  [ "$streak" -lt "$alarm_point" ] && return 1                                      # below the alarm point: no alarm
  [ "$streak" -eq "$alarm_point" ] && return 0                                      # first alarm, exactly as before
  [ "$((streak - FASTDEATH_LAST_ALARM_STREAK))" -ge "$FASTDEATH_REALARM_EVERY" ] && return 0  # bounded re-alarm
  return 1
}

# Finding #3: is THIS session's Telegram bridge (a bun telegram-plugin process) present?
# Scoped STRICTLY to the DESCENDANT TREE of SESSION_PGID — NEVER a box-wide pattern match.
# Two facts force the subtree walk: (1) the bridge lives in claude's OWN process group, not
# SESSION_PGID's (script(1)'s pty setup puts claude in a new group), so `pgrep -g $SESSION_PGID`
# misses it; (2) several projects run near-identical bun telegram bridges on this box, so a
# `pgrep -f telegram` would match the WRONG project's bridge (memory/dont-broad-pkill-shared-services.md).
# We ppid-walk from SESSION_PGID and match the bun/telegram signature only among ITS descendants.
bridge_present() {
  [ -n "${SESSION_PGID:-}" ] || return 1
  command -v pgrep >/dev/null 2>&1 || return 1
  command -v ps    >/dev/null 2>&1 || return 1
  local frontier="$SESSION_PGID" all="" next pid child cmd guard=0
  while [ -n "$frontier" ] && [ "$guard" -lt 64 ]; do          # guard: never spin on a pathological tree
    guard=$((guard + 1)); next=""
    for pid in $frontier; do
      for child in $(pgrep -P "$pid" 2>/dev/null || true); do
        case " $all " in *" $child "*) : ;; *) all="$all $child"; next="$next $child" ;; esac
      done
    done
    frontier="$next"
  done
  for pid in $all; do
    cmd="$(ps -o args= -p "$pid" 2>/dev/null || true)"
    case "$cmd" in
      *bun*telegram*|*bun*server.ts*|*telegram*server.ts*) return 0 ;;
    esac
  done
  return 1
}

# G3 distinct degraded alarm: fired ONCE when the respawn CAP trips (auto-restart is giving up).
bridge_degraded_alarm() {
  tg_send_tokenless "⚠️ Telegram bridge keeps crashing on this worker — I auto-respawned it ${BRIDGE_RESPAWN_CAP}× and it died again each time, so I'm STOPPING auto-restart to avoid a refresh loop. The session is still running but INBOUND Telegram is DOWN until the next healthy refresh. Likely a plugin/runtime fault. This is NOT the usual cooking ping."
}

# v0.6 fail-loud: the never-up alarm (fired once per outage, when the durable flag is freshly written).
bridge_neverup_alarm() {
  tg_send_tokenless "🔇 Telegram bridge NEVER came up within ${1:-?}s on this worker — it is computing but DEAF on Telegram (inbound + replies both down). I wrote .kickoff/bridge-escalated and will retry at most ${BRIDGE_BOOT_RETRY_CAP:-1} refresh(es), then stop (repeated restarts are the wrong move). Likely causes: a channel spec that is not allowlisted, a plugin/runtime fault, or a foreign process holding this bot's getUpdates slot. This is NOT the usual cooking ping."
}

# v0.6: the DURABLE escalation artifact — $KICKOFF_DIR/bridge-escalated, a sibling of
# auth-heal's auth-escalated (timestamp + reason). DELIBERATELY NOT gating trigger-3
# restarts (contrast the auth-escalated gate): a bridge-less session is DEGRADED — deaf on
# Telegram — but still computes; blocking restarts would turn a comms outage into a work
# outage. rc 0 = freshly written (callers alert exactly once per outage); rc 1 = already
# present / could not write.
bridge_escalate_flag() {
  local reason="$1" flag="$KICKOFF_DIR/bridge-escalated"
  [ -f "$flag" ] && return 1
  printf '%s\n%s\n' "$(date -u +%FT%TZ 2>/dev/null || echo now)" "$reason" > "$flag" 2>/dev/null || return 1
  log "bridge-liveness: ESCALATED (durable flag $flag): $reason"
  return 0
}

# clears the durable flag on recovery (a healthy bridge = comms restored). DRY_RUN mutates nothing.
bridge_clear_escalation() {
  local flag="$KICKOFF_DIR/bridge-escalated"
  [ -f "$flag" ] || return 0
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN — would clear the bridge escalation flag ($flag)"
    return 0
  fi
  rm -f "$flag" 2>/dev/null || true
  log "bridge-liveness: bridge is UP — cleared the escalation flag ($flag); comms restored"
}

# is pid $1 anywhere in OUR managed session's descendant tree? (same bounded ppid-walk as
# bridge_present — subtree-scoped, NEVER a box-wide match). Used for detection/logging only.
bridge_pid_in_session_tree() {
  local needle="$1"
  [ -n "${SESSION_PGID:-}" ] || return 1
  command -v pgrep >/dev/null 2>&1 || return 1
  [ "$needle" = "${SESSION_PGID:-}" ] && return 0
  local frontier="$SESSION_PGID" all="" next pid child guard=0
  while [ -n "$frontier" ] && [ "$guard" -lt 64 ]; do
    guard=$((guard + 1)); next=""
    for pid in $frontier; do
      for child in $(pgrep -P "$pid" 2>/dev/null || true); do
        case " $all " in *" $child "*) : ;; *) all="$all $child"; next="$next $child" ;; esac
      done
    done
    frontier="$next"
  done
  case " $all " in *" $needle "*) return 0 ;; esac
  return 1
}

# v0.6 fail-loud core: the never-came-up detector. Called from bridge_liveness_step's
# not-present path while BRIDGE_SEEN=0 — exactly the case the v0.5 G1 latch bailed on
# silently. Once BRIDGE_BOOT_GRACE_SECONDS elapse with no bridge: LOUD log + durable flag +
# ONE alert, then at most BRIDGE_BOOT_RETRY_CAP guarded refreshes (reason `bridge-neverup`,
# which refresh() classes as bridge-* so the streaks survive it), then give up and leave the
# flag for the operator. Corroborates with bot.pid (a live foreign holder of this channel's
# getUpdates slot is NAMED in the log — detection only; the kill path lives in session-run's
# bridge-reap.sh). Guards: inert without a numeric SESSION_STARTED or a derivable
# TELEGRAM_STATE_DIR (a non-telegram START_CMD keeps the v0.5 inertness); DRY_RUN =
# detect-only (G4); never aborts the loop (G5/G6 discipline, callers add `|| true`).
bridge_boot_check() {
  [ "${BRIDGE_BOOT_GIVEUP:-0}" = "1" ] && return 0
  case "${SESSION_STARTED:-}" in ''|*[!0-9]*) return 0 ;; esac
  local grace="${BRIDGE_BOOT_GRACE_SECONDS:-120}"
  case "$grace" in ''|*[!0-9]*) grace=120 ;; esac
  [ "$((SECONDS - SESSION_STARTED))" -ge "$grace" ] || return 0
  # derive the state dir (env → instance.env), the tg_send_tokenless recipe; no state dir ⇒ inert
  local tsd="${TELEGRAM_STATE_DIR:-}" ienv="${INSTANCE_ENV:-$KICKOFF_DIR/instance.env}"
  if [ -z "$tsd" ] && [ -f "$ienv" ]; then
    tsd="$( set +eu; . "$ienv" >/dev/null 2>&1 || true; printf '%s' "${TELEGRAM_STATE_DIR:-}" )"
  fi
  if [ -z "$tsd" ]; then
    if [ "${_BRIDGE_BOOT_TSD_WARNED:-0}" != "1" ]; then
      log "bridge-boot: no TELEGRAM_STATE_DIR derivable — never-up detector inert (not a telegram-bridged instance?)"
      _BRIDGE_BOOT_TSD_WARNED=1
    fi
    return 0
  fi
  # corroborate with bot.pid: who holds this channel's getUpdates slot right now?
  local holder="" extra=""
  holder="$(cat "$tsd/bot.pid" 2>/dev/null || true)"
  holder="${holder//[[:space:]]/}"
  case "$holder" in ''|*[!0-9]*|0|1) holder="" ;; esac
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    if bridge_pid_in_session_tree "$holder"; then
      extra=" (bot.pid=$holder IS in our session tree — a bridge exists but its argv missed the signature?)"
    else
      extra=" — foreign consumer pid=$holder holds this channel's getUpdates slot ($tsd/bot.pid)"
      log "bridge-boot: foreign consumer holds this channel's getUpdates slot (pid=$holder, outside our session tree; detection only — reap-on-startup owns the kill path)"
    fi
  fi
  if [ "$DRY_RUN" = "1" ]; then                                # G4: detect-only, never flag/refresh
    log "DRY_RUN — bridge NEVER came up within ${grace}s${extra}; would escalate (flag + alert) then refresh (bridge-neverup). Detect-only, no action."
    return 0
  fi
  log "bridge-liveness: Telegram bridge NEVER came up within ${grace}s of session start — the worker is running DEAF (silent gag)${extra}"
  if bridge_escalate_flag "bridge never came up within ${grace}s${extra}"; then
    bridge_neverup_alarm "$grace"
  fi
  if [ "${BRIDGE_BOOT_FAILS:-0}" -lt "${BRIDGE_BOOT_RETRY_CAP:-1}" ]; then
    BRIDGE_BOOT_FAILS=$(( ${BRIDGE_BOOT_FAILS:-0} + 1 ))
    log "bridge-boot: guarded refresh #${BRIDGE_BOOT_FAILS} (bridge-neverup) — a fresh claude --channels is the only way a bridge appears"
    refresh "bridge-neverup"
  else
    BRIDGE_BOOT_GIVEUP=1
    log "bridge-boot: bridge STILL never came up after ${BRIDGE_BOOT_FAILS:-0} boot-retry refresh(es) — GIVING UP auto-refresh (repeated restarts are the wrong move); the durable flag stays ($KICKOFF_DIR/bridge-escalated)"
  fi
  return 0
}

# Finding #3 core: the poll-loop probe. If the session is ALIVE but a bridge that was SEEN this
# session is now GONE → refresh (the only way the bun bridge returns is a fresh `claude --channels`).
# Guards: G1 first-seen latch (never react before a bridge exists — a non-channels/DRY_RUN session
# never sets it), G2 startup grace (the latch IS the grace — fire only after first-seen), G3 respawn
# CAP (a bridge-only crash never trips the session-death breaker, so cap the consecutive respawns,
# then fire ONE degraded alarm and leave the session bridge-less), G4 DRY_RUN detect-only, G5
# tooling-gated, G6 never aborts the loop (callers add `|| true`, and every probe error is swallowed).
bridge_liveness_step() {
  [ "${BRIDGE_LIVENESS:-1}" = "1" ] || return 0
  if ! command -v pgrep >/dev/null 2>&1 || ! command -v ps >/dev/null 2>&1; then   # G5
    if [ "${_BRIDGE_TOOL_WARNED:-0}" != "1" ]; then
      log "bridge-liveness: pgrep/ps unavailable — inert"; _BRIDGE_TOOL_WARNED=1
    fi
    return 0
  fi
  session_alive || return 0                                    # only meaningful while OUR session lives
  if bridge_present; then
    if [ "${BRIDGE_SEEN:-0}" != "1" ]; then
      BRIDGE_SEEN=1; BRIDGE_SEEN_AT=$SECONDS
      log "bridge-liveness: Telegram bridge detected for this session (latched)"
      # v0.6 fail-loud recovery: a healthy bridge ends any boot-fail outage — reset the
      # never-up bookkeeping and clear the durable escalation flag (comms restored).
      BRIDGE_BOOT_FAILS=0; BRIDGE_BOOT_GIVEUP=0
      bridge_clear_escalation
    elif [ "${BRIDGE_RESPAWN_STREAK:-0}" -gt 0 ] \
         && [ "$((SECONDS - ${BRIDGE_SEEN_AT:-0}))" -ge "$FASTDEATH_THRESHOLD_SECONDS" ]; then
      # a bridge that has now lived a healthy span → the respawn loop is broken; reset the streak
      log "bridge-liveness: bridge healthy for ${FASTDEATH_THRESHOLD_SECONDS}s+ — clearing respawn streak"
      BRIDGE_RESPAWN_STREAK=0; BRIDGE_RESPAWN_GIVEUP=0
    fi
    return 0
  fi
  # bridge NOT present right now
  if [ "${BRIDGE_SEEN:-0}" != "1" ]; then                      # G1/G2: the RESPAWN belt never reacts before first-seen —
    bridge_boot_check                                          # but a bridge that NEVER comes up is the "silent gag";
    return 0                                                   # hand it to the v0.6 boot-grace detector, don't bail mute
  fi
  [ "${BRIDGE_RESPAWN_GIVEUP:-0}" = "1" ] && return 0          # G3: already gave up — leave it bridge-less
  if [ "$DRY_RUN" = "1" ]; then                                # G4: detect-only, never refresh/kill
    log "DRY_RUN — bridge GONE after being seen; would refresh (bridge-dead). Detect-only, no action."
    return 0
  fi
  BRIDGE_RESPAWN_STREAK=$((${BRIDGE_RESPAWN_STREAK:-0} + 1))
  if [ "$BRIDGE_RESPAWN_STREAK" -gt "$BRIDGE_RESPAWN_CAP" ]; then   # G3 cap tripped
    BRIDGE_RESPAWN_GIVEUP=1
    log "bridge-liveness: bridge died again after $BRIDGE_RESPAWN_CAP auto-respawns (cap) — GIVING UP auto-refresh, leaving session bridge-less; firing degraded alarm"
    # v0.6: also leave the DURABLE artifact next to the one-shot alarm (the flag persists for
    # the operator / the next session to see; it does NOT gate trigger-3 — see bridge_escalate_flag)
    bridge_escalate_flag "bridge died after ${BRIDGE_RESPAWN_CAP} auto-respawns (died-mid-session cap)" || true
    bridge_degraded_alarm
    return 0
  fi
  log "bridge-liveness: Telegram bridge GONE while session alive — refresh #$BRIDGE_RESPAWN_STREAK to respawn it (bridge-dead)"
  refresh "bridge-dead"
  return 0
}
# <<< KICKOFF-BRIDGE-UNIT <<<

cleanup() {
  log "supervisor exiting"
  stop_session
  rm -f "$LOCKFILE"
  exit 0
}
trap cleanup INT TERM

run_preflight
acquire_lock
log "watching: flag=$REFRESH_FLAG  cadence=${MAX_SESSION_SECONDS}s  poll=${POLL_SECONDS}s  dry_run=$DRY_RUN"
start_session

while true; do
  # bound the append-only log IN PLACE (copytruncate — this supervisor's stdout is an open fd
  # on it, so a rename would leave us writing into .log.1 and .log empty; see rotate-log.sh)
  rotate_log "$SUPERVISOR_LOG"

  # auth self-heal probe (scripts/auth-heal.sh; a no-op unless armed). `|| true`: a
  # probe error must NEVER abort the supervisor loop (fail-toward-inaction).
  auth_heal_step || true

  # trigger 1: degradation / explicit refresh flag (also the Telegram /refresh path)
  if [ -f "$REFRESH_FLAG" ]; then refresh "flag"; fi

  # trigger 2: cadence (optional)
  if [ "$MAX_SESSION_SECONDS" -gt 0 ] && [ $((SECONDS - SESSION_STARTED)) -ge "$MAX_SESSION_SECONDS" ]; then
    refresh "cadence ${MAX_SESSION_SECONDS}s"
  fi

  # trigger 2.5 (finding #3): bridge-liveness. The Telegram bridge (a bun process under the
  # claude child) can crash while the claude session stays ALIVE, silencing the operator's ONLY
  # inbound channel + reply tool. It does NOT self-respawn; a full refresh (fresh `claude
  # --channels`) is the proven recovery. Placed BEFORE the session-death check because the session
  # is still alive here. `|| true` (G6): a probe error must NEVER abort the loop, like auth_heal_step.
  bridge_liveness_step || true

  # trigger 3: the managed session ended on its own (finished -p run, or a crash).
  # Gated on the auth-heal escalation flag: while auth is expired a restart only spawns
  # a doomed session (a restart can't mint a credential) — auth-heal clears the flag +
  # touches the refresh flag the moment auth is valid again (or relogin.sh does).
  # DELIBERATELY NOT gated on .kickoff/bridge-escalated (v0.6): a bridge-less session is
  # DEGRADED (deaf on Telegram) but still computes — blocking restarts would turn a comms
  # outage into a work outage. Contrast auth-escalated, where every restart is a doomed spawn.
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

  sleep "$POLL_SECONDS"
done
