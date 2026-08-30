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
  start_session
}

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

  # trigger 1: degradation / explicit refresh flag (also the Telegram /refresh path)
  if [ -f "$REFRESH_FLAG" ]; then refresh "flag"; fi

  # trigger 2: cadence (optional)
  if [ "$MAX_SESSION_SECONDS" -gt 0 ] && [ $((SECONDS - SESSION_STARTED)) -ge "$MAX_SESSION_SECONDS" ]; then
    refresh "cadence ${MAX_SESSION_SECONDS}s"
  fi

  # trigger 3: the managed session ended on its own (finished -p run, or a crash)
  if ! session_alive; then
    log "session ended; restarting fresh (backoff ${RESTART_BACKOFF_SECONDS}s to avoid a crash-loop)"
    SESSION_PGID=""
    sleep "$RESTART_BACKOFF_SECONDS"
    start_session
  fi

  sleep "$POLL_SECONDS"
done
