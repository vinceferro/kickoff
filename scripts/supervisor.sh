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
# BRIDGE_BOOT_RETRY_CAP FAST refreshes, then (v0.9) a widening backoff that never gives up.
# Detection only applies when the instance has a derivable
# TELEGRAM_STATE_DIR (a non-telegram START_CMD stays exempt, preserving the v0.5 inertness).
#
# v0.9 — WHY the give-up became a backoff (the 2026-07-24 deaf-worker outage). At 21:43 two
# workers on the same box restarted inside a ~2-minute bad window and their
# bridges never came up. The belt did everything right — detected, escalated, alerted (the
# operator confirmed receiving it), did its one guarded retry — and then LATCHED a permanent
# give-up. Both workers then sat DEAF (computing, but unable to reach the operator at all) for
# 26 minutes, ending only because a human counted his bots and touched the refresh flag by hand.
# Every worker that restarted at 22:00–22:02 got its bridge on the FIRST try: the blocker was
# TRANSIENT. A give-up with no floor turns a two-minute blip into an outage that ends only when
# a human happens to look — so the cap now hands over to a widening retry (10m → 20m → 40m →
# a 60m ceiling) that continues indefinitely. The traded cost is real and deliberate: a refresh
# KILLS the session's in-flight work. That is acceptable precisely BECAUSE a deaf worker cannot
# report its in-flight work to anyone anyway. An instance that legitimately has NO bridge already
# has the right escape hatch — BRIDGE_LIVENESS=0 short-circuits this entire belt — so no second
# "park forever" switch is added here; that switch is what the bug was.
BRIDGE_BOOT_GRACE_SECONDS="${BRIDGE_BOOT_GRACE_SECONDS:-120}"      # max seconds for a fresh session's bridge to APPEAR
case "$BRIDGE_BOOT_GRACE_SECONDS" in ''|*[!0-9]*) BRIDGE_BOOT_GRACE_SECONDS=120 ;; esac
BRIDGE_BOOT_RETRY_CAP="${BRIDGE_BOOT_RETRY_CAP:-1}"                # FAST (back-to-back) bridge-neverup refreshes before the widening backoff tier
case "$BRIDGE_BOOT_RETRY_CAP" in ''|*[!0-9]*) BRIDGE_BOOT_RETRY_CAP=1 ;; esac
BRIDGE_BOOT_BACKOFF_START="${BRIDGE_BOOT_BACKOFF_START:-600}"      # first backoff interval (10m); doubles per retry
case "$BRIDGE_BOOT_BACKOFF_START" in ''|*[!0-9]*) BRIDGE_BOOT_BACKOFF_START=600 ;; esac
[ "$BRIDGE_BOOT_BACKOFF_START" -lt 60 ]    && BRIDGE_BOOT_BACKOFF_START=60      # floor: each retry KILLS in-flight work, so a 1s knob would be a restart storm
[ "$BRIDGE_BOOT_BACKOFF_START" -gt 86400 ] && BRIDGE_BOOT_BACKOFF_START=86400   # ceiling: a fat-fingered knob must not mute the retry for years
BRIDGE_BOOT_BACKOFF_MAX="${BRIDGE_BOOT_BACKOFF_MAX:-3600}"         # interval ceiling (60m); retries then continue at THAT cadence forever
case "$BRIDGE_BOOT_BACKOFF_MAX" in ''|*[!0-9]*) BRIDGE_BOOT_BACKOFF_MAX=3600 ;; esac
[ "$BRIDGE_BOOT_BACKOFF_MAX" -lt "$BRIDGE_BOOT_BACKOFF_START" ] && BRIDGE_BOOT_BACKOFF_MAX="$BRIDGE_BOOT_BACKOFF_START"  # a mis-set MAX can never make retries FASTER than START
[ "$BRIDGE_BOOT_BACKOFF_MAX" -gt 86400 ] && BRIDGE_BOOT_BACKOFF_MAX=86400
BRIDGE_BOOT_REALARM_EVERY="${BRIDGE_BOOT_REALARM_EVERY:-3}"        # bounded re-alarm cadence, counted in BACKOFF retries (silence and spam are the same bug)
case "$BRIDGE_BOOT_REALARM_EVERY" in ''|*[!0-9]*) BRIDGE_BOOT_REALARM_EVERY=3 ;; esac
[ "$BRIDGE_BOOT_REALARM_EVERY" -lt 1 ]    && BRIDGE_BOOT_REALARM_EVERY=1        # a floor: 0 would divide the cadence into every-retry spam
[ "$BRIDGE_BOOT_REALARM_EVERY" -gt 1000 ] && BRIDGE_BOOT_REALARM_EVERY=1000     # a ceiling so a fat-fingered knob can't mute it forever
# v0.11 THE REFRESH CAP (the other half of deleting the give-up). The ALARM is free; the REFRESH
# costs the session's in-flight work — so bound the expensive one and never the cheap one. A
# TRANSIENTLY deaf worker recovers in one or two backoff retries (that is the 07-24 case, and the
# ladder above is exactly right for it). A PERSISTENTLY deaf one — a foreign process holding this
# channel's getUpdates slot, or a channel configured with no bot token — can NEVER satisfy the belt,
# so an unbounded ladder issues ~25 session-killing refreshes a day, forever: v0.19 lost the
# channel, an uncapped v0.20 would lose the WORK, every <=60 minutes, indefinitely. After this many
# BACKOFF-tier refreshes have demonstrably failed to help, stop restarting — and keep walking the
# same widening cadence purely as the alarm clock. This is NOT the deleted give-up: that one went
# permanently SILENT and abandoned recovery; this one keeps telling the operator it is deaf forever
# and only retires the DESTRUCTIVE action. (See the capped branch in bridge_boot_check.)
BRIDGE_BOOT_BACKOFF_REFRESH_CAP="${BRIDGE_BOOT_BACKOFF_REFRESH_CAP:-6}"  # BACKOFF-tier refreshes before restarting retires (~4h on the default ladder)
case "$BRIDGE_BOOT_BACKOFF_REFRESH_CAP" in ''|*[!0-9]*) BRIDGE_BOOT_BACKOFF_REFRESH_CAP=6 ;; esac
[ "$BRIDGE_BOOT_BACKOFF_REFRESH_CAP" -lt 1 ]    && BRIDGE_BOOT_BACKOFF_REFRESH_CAP=1     # a floor: 0 would delete the recovery action itself, which is the bug shape this release exists to fix
[ "$BRIDGE_BOOT_BACKOFF_REFRESH_CAP" -gt 1000 ] && BRIDGE_BOOT_BACKOFF_REFRESH_CAP=1000  # a ceiling: a fat-fingered knob must not restore the unbounded restart loop
BRIDGE_OUTAGE_LOG_KEEP="${BRIDGE_OUTAGE_LOG_KEEP:-20}"             # line cap on the .kickoff/bridge-outages.log breadcrumb (bounded by construction)
case "$BRIDGE_OUTAGE_LOG_KEEP" in ''|*[!0-9]*) BRIDGE_OUTAGE_LOG_KEEP=20 ;; esac
[ "$BRIDGE_OUTAGE_LOG_KEEP" -lt 1 ]    && BRIDGE_OUTAGE_LOG_KEEP=1
[ "$BRIDGE_OUTAGE_LOG_KEEP" -gt 1000 ] && BRIDGE_OUTAGE_LOG_KEEP=1000
BRIDGE_BOOT_FAILS=0                                                # consecutive FAST bridge-neverup refreshes this outage (in-process)
BRIDGE_BOOT_BACKOFF_N=0                                            # backoff retries done this outage == the doubling exponent
BRIDGE_BOOT_NEXT_AT=0                                              # SECONDS at which the next backoff retry is DUE; 0 = tier not armed yet
BRIDGE_BOOT_LAST_ALARM_N=0                                         # BACKOFF_N at the last re-alarm (the bookmark; mirrors FASTDEATH_LAST_ALARM_STREAK)
BRIDGE_BOOT_DEAF_SINCE=0                                           # SECONDS at this era's first deaf detection — powers the "~Nm deaf" re-alarm figure
# v0.8 model-quota fallback (the "alive but cannot think" gap): a personal-Max weekly model
# limit leaves the supervisor + session + bridge all ALIVE while EVERY turn fails — no existing
# belt catches it (liveness ≠ capability). The belt (unit below) scans the session's pty output
# (captured to SUPERVISOR_LOG) for the REAL limit string, switches the worker to a cheaper
# fallback model, alerts, and latches. REACTIVE only — a personal Max plan exposes NO
# non-interactive quota source, so there is no proactive/threshold tier (verified). INERT-BY-
# CONSTRUCTION: no detected limit string ⇒ zero action; on kickoff-dev (MODEL=opus, fallback
# opus) a healthy worker is never cycled. Config (MODEL_FALLBACK gate, MODEL_FALLBACK_TO target)
# is read by the belt itself from the environment / instance.env — the SAME untrusted-config
# discipline as auth-heal's KICKOFF_AUTH_* knobs — so it is DELIBERATELY off the session-run
# whitelist (a supervisor-belt knob the SESSION never needs) and off the launcher KEEP-list.
# NOT declared here with a default: env-first-then-file resolution needs the "unset" signal to
# let an instance.env value flow in (a default here would shadow the file, like auth-heal).
MODEL_FALLBACK_OFFSET=0                                            # SUPERVISOR_LOG byte offset already scanned (only-new-content)
MODEL_FALLBACK_LATCHED=0                                           # one-shot per SESSION: set when the belt acts; RESET in start_session
MODEL_FALLBACK_HITS=0                                              # confirmations in the current window (a one-off quote/grep = 1, never acts)
MODEL_FALLBACK_LAST_HIT=0                                          # SECONDS of the last wall detection (window/staleness bound)
# A real wall REPEATS (every failing turn reprints it); a one-off worker quote / a `cat supervisor.sh`
# / a design-doc render shows the string ONCE. So the belt requires the wall on N SEPARATE poll ticks
# within a window before it acts — this is the load-bearing false-positive defense (findings #1/#3):
# the pty log is newline-sparse (one physical line can be MBs), so grep's "same line" is NOT a
# proximity bound; recurrence is what actually distinguishes a stuck worker from one that merely
# rendered the string. Two distant one-off quotes never accumulate (the window resets a stale count).
MODEL_FALLBACK_CONFIRMATIONS="${MODEL_FALLBACK_CONFIRMATIONS:-2}"  # distinct ticks the wall must recur before acting
case "$MODEL_FALLBACK_CONFIRMATIONS" in ''|*[!0-9]*) MODEL_FALLBACK_CONFIRMATIONS=2 ;; esac
[ "$MODEL_FALLBACK_CONFIRMATIONS" -lt 2 ] && MODEL_FALLBACK_CONFIRMATIONS=2   # never act on a single occurrence
MODEL_FALLBACK_WINDOW_SECONDS="${MODEL_FALLBACK_WINDOW_SECONDS:-600}"         # detections >this apart are unrelated → count resets
case "$MODEL_FALLBACK_WINDOW_SECONDS" in ''|*[!0-9]*) MODEL_FALLBACK_WINDOW_SECONDS=600 ;; esac
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
# v0.8 model-fallback: START the belt's scan offset at the CURRENT log size, so a fresh
# supervisor (or an engine-hop exec, same PID, same open log fd) reacts ONLY to a limit hit
# during THIS era — never re-fires on a STALE limit line left in the append-only log by a prior
# era (which, after we already repinned MODEL, would be a spurious switch/alert on a healthy
# worker). Any doubt about the size → 0 (scan-from-top; the latch still bounds it to one action).
# `|| true` inside the substitution: a MISSING log (a direct `bash supervisor.sh` launch that
# has not created .kickoff/supervisor.log yet — finding #5) makes `wc <` fail; under `set -e` +
# pipefail that non-zero would abort the WHOLE supervisor at startup before the `case` below can
# normalise it. Fail toward inaction: swallow to empty → the `case` maps empty/non-numeric → 0.
_mf_logsize0="$(wc -c < "$SUPERVISOR_LOG" 2>/dev/null | tr -d '[:space:]' || true)"
case "$_mf_logsize0" in ''|*[!0-9]*) _mf_logsize0=0 ;; esac
MODEL_FALLBACK_OFFSET="$_mf_logsize0"
unset _mf_logsize0
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
    # v0.7 G1 slice 5: an engine hop re-execs THIS process (same PID), so a lock the
    # pre-hop code wrote is OURS — the fresh code must recognize it, or the hop would
    # refuse its own lock and exit itself into an outage. A DIFFERENT live pid is still
    # refused exactly as before (rival detection intact).
    if [ -n "$other" ] && [ "$other" = "$$" ]; then
      log "lock pid $other is our OWN pid (an engine-hop exec keeps the PID) — keeping the lock"
    elif [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
      log "another supervisor is already running (pid=$other) — refusing to start a second"
      exit 1
    else
      log "stale lock from pid=$other — reclaiming"
    fi
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
    # v0.7 G1 slice 5 (review find): when THIS startup is the landing half of an engine hop
    # (the old engine exec'd us — KICKOFF_HOP_EXEC marks it, kernel-held across the exec),
    # a red here is a DEAD worker with nothing above it to restart it. The boundary's
    # full-scope pre-exec gate makes this near-unreachable (same script, same env), but if
    # config raced in the verify→exec window, say so LOUDLY — one tokenless alert, never a
    # mute death. Gated on the marker so a plain terminal/test startup red stays log-only.
    if [ -n "${KICKOFF_HOP_EXEC:-}" ] && [ "$DRY_RUN" != "1" ]; then
      tg_send_tokenless "⛔ Engine hop landed but the NEW engine's startup preflight FAILED — this worker EXITED without starting a session (fail-closed). Fix the instance config (\`kickoff preflight\` shows the failing check), then restart:  kickoff up --auto --detach. This is NOT the usual cooking ping."
    fi
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
  # v0.8 finding #2: re-arm the model-fallback belt for THIS session (mirror BRIDGE_SEEN). Without
  # this the belt is a permanent process-wide latch: after ONE fable→opus switch it goes dead for
  # the whole supervisor era, so a LATER wall on the fallback model (opus's own weekly limit) is
  # swallowed with NO alert and the worker sits fully stalled. Re-arming per session means the next
  # wall is caught → the already-on-fallback "manual intervention" alert fires. The N-tick
  # confirmation gate below is what stops the belt's OWN switch+refresh from immediately re-firing
  # (a fresh session must show the wall on N separate ticks), so no BRIDGE_SEEN_AT-style timer is
  # needed here — the recurrence requirement IS the healthy-span guard.
  MODEL_FALLBACK_LATCHED=0
  MODEL_FALLBACK_HITS=0
  MODEL_FALLBACK_LAST_HIT=0
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
  # stdin is ALWAYS /dev/null: a supervised session is headless by definition, and
  # session-run's pty-wrap decision is `[ ! -t 0 ]` — a terminal-launched supervisor
  # must never hand its own tty stdin to the worker (the wrap would skip and claude
  # would sit on the operator's terminal fd from a detached session).
  if have_setsid; then
    setsid bash -c "cd \"$REPO_DIR\" && exec $START_CMD" </dev/null &
    SESSION_PGID=$!
  else
    # Fallback: bash job control puts a backgrounded pipeline in its own group;
    # `set -m` enables it so $! is still a group we can target with kill -- -PID.
    set -m
    ( cd "$REPO_DIR" && exec $START_CMD ) </dev/null &
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
  # (v0.9: bridge_boot_reset now clears the BACKOFF timer/exponent/bookmark too, so a later outage
  # restarts the ladder at 10m instead of resuming at the 60m ceiling. Both retry reasons still
  # start with `bridge-` — `bridge-neverup` and `bridge-neverup-backoff` — so the ladder survives
  # its OWN refreshes and can keep climbing, which is the whole point of the tier.)
  case "$why" in bridge-*) : ;; *) BRIDGE_RESPAWN_STREAK=0; BRIDGE_RESPAWN_GIVEUP=0; bridge_boot_reset ;; esac
  # v0.7 G1 slice 5: the session boundary IS the hop point — a freshly-pinned engine
  # takes over HERE (exec: same PID, the lock + grant carry) instead of starting a fresh
  # session from stale code. A no-op while no pin mismatch is pending (see the hop unit).
  engine_hop_boundary || true
  start_session
}

# ── bridge-liveness + crash-loop re-alarm (findings #3 + #2) ─────────────────
# EXTRACTED as one contiguous unit (between the >>> / <<< marker lines below) by
# scripts/supervisor-liveness-selftest.sh, which drives it with stubs so the logic
# is asserted hermetically — no real session, no live worker touched.
# >>> KICKOFF-BRIDGE-UNIT >>>

# v0.9 THE CLOCK SEAM. Every time-read in the never-up belt goes through here, and here reads
# bash's own $SECONDS — monotonic for this supervisor's whole life (refresh()/start_session only
# reassign SESSION_STARTED; neither resets SECONDS). Routing it through ONE function is what makes
# a backoff measured in hours testable at all: the hermetic selftest overrides bridge_now after
# sourcing this unit — the same override-after-sourcing idiom the scenarios already use for
# bridge_present — and drives an eight-hour outage in milliseconds.
# NOTE: an engine-hop `exec` DOES reset SECONDS to 0 — but that exec replaces the shell image and
# discards every variable, so the BRIDGE_BOOT_* state resets with it. Consistent; never half-reset.
bridge_now() { printf '%s\n' "$SECONDS"; }

# v0.9 the widening retry interval for the never-up backoff tier: START << N, capped at MAX.
# PURE READ — it must stay safe inside a command substitution (a subshell can't mutate state).
bridge_boot_backoff_interval() {
  local n="${BRIDGE_BOOT_BACKOFF_N:-0}" start="${BRIDGE_BOOT_BACKOFF_START:-600}" max="${BRIDGE_BOOT_BACKOFF_MAX:-3600}" iv
  [ "$n" -gt 30 ] && n=30                        # clamp the shift exponent (same guard as the crash-loop backoff below)
  iv=$(( start << n ))
  # The `-lt start` arm catches a 64-bit shift overflowing into 0/negative: a negative interval
  # would make EVERY tick "due" and turn the backoff into the restart storm it exists to prevent.
  if [ "$iv" -gt "$max" ] || [ "$iv" -lt "$start" ]; then iv="$max"; fi
  printf '%s\n' "$iv"
}

# v0.10 THE JITTER SEAM. The 07-24 incident took TWO workers deaf inside the same ~2-minute
# window — a shared cause makes that the NORMAL shape, not the unlucky one. A fully deterministic
# ladder then cold-starts every affected worker at the same instant, forever, repeatedly spiking a
# shared box (and `claude` cold starts are the heaviest thing this supervisor does). Spread each
# due-at by a small bounded amount. It is a SEAM for exactly the reason bridge_now is: the hermetic
# scenarios override it with a pinned 0 so jitter can never make an assertion flaky, while scenario
# (u) drives the REAL one and asserts its bounds. Span is a tenth of the interval, hard-capped at
# 300s — enough to de-lockstep a handful of workers, far too little to meaningfully delay a retry.
bridge_jitter() {
  local span="${1:-0}"
  case "$span" in ''|*[!0-9]*) span=0 ;; esac      # a negative/garbage span must never reach the modulo
  [ "$span" -gt 300 ] && span=300
  [ "$span" -le 0 ] && { printf '0\n'; return 0; }
  printf '%s\n' "$(( RANDOM % (span + 1) ))"
}

# v0.11 the BACKOFF-tier refresh cap, re-validated AT THE POINT OF USE. The declaration + clamp in
# the supervisor's globals block sits OUTSIDE the KICKOFF-BRIDGE-UNIT markers, so the hermetic
# selftest can never reach it — exactly as BRIDGE_OUTAGE_LOG_KEEP's clamp is re-stated inside
# bridge_outage_trim, and as bridge_boot_backoff_interval re-clamps its own shift exponent. This
# copy is the load-bearing one: it is what runs, and it is what the suite asserts.
# PURE READ — it must stay safe inside a command substitution (a subshell can't mutate state).
bridge_boot_refresh_cap() {
  local cap="${BRIDGE_BOOT_BACKOFF_REFRESH_CAP:-6}"
  case "$cap" in ''|*[!0-9]*) cap=6 ;; esac
  [ "$cap" -lt 1 ]    && cap=1        # 0 would retire restarting before it was ever tried
  [ "$cap" -gt 1000 ] && cap=1000     # and a huge value is the unbounded restart loop by another name
  printf '%s\n' "$cap"
}

# v0.9 is a backoff RE-alarm due? Same discipline as crashloop_alarm_due: the operator used to get
# exactly ONE alert and then permanent silence while the outage ran on. Re-ping every
# BRIDGE_BOOT_REALARM_EVERY further backoff retries — bounded, never per retry.
bridge_boot_alarm_due() {
  local n="$1"
  [ "$n" -lt 1 ] && return 1
  [ "$((n - BRIDGE_BOOT_LAST_ALARM_N))" -ge "$BRIDGE_BOOT_REALARM_EVERY" ] && return 0
  return 1
}

# v0.9 clear the WHOLE never-up outage state. Lives INSIDE the unit so the reset semantics are
# finally testable (pre-v0.9 they were two inline assignments in two places, asserted nowhere).
# Called from refresh()'s NON-bridge arm (a clean restart re-arms the ladder from 10m) and from
# bridge_liveness_step's healthy first-seen latch (a recovered bridge disarms the timer too — a
# stale NEXT_AT would make the next outage resume at the 60m ceiling instead of starting over).
# (v0.10 also clears the SIGNATURE-MISS warn-once latch — that state describes ONE outage era, so
# leaving it set would silence the distinct log for every LATER signature miss on this supervisor.)
bridge_boot_reset() { BRIDGE_BOOT_FAILS=0; BRIDGE_BOOT_BACKOFF_N=0; BRIDGE_BOOT_NEXT_AT=0; BRIDGE_BOOT_LAST_ALARM_N=0; BRIDGE_BOOT_DEAF_SINCE=0; _BRIDGE_BOOT_SIGMISS_WARNED=0; }

# Send a Telegram message WITHOUT the bot token ever reaching argv / the process table
# (token fed to curl via `-K -` on stdin; the whole send wrapped in a ( … ) || true subshell
# so no failure/leak can abort the poll loop). Mirrors session-run.sh's announce_restart recipe.
# v0.9 OBSERVABILITY (the second half of the 07-24 lesson): this send used to be entirely silent
# — `-o /dev/null`, `|| true` on every step, and no log line anywhere — so a FAILED alarm left
# ZERO trace in a 10MB log, and the only reason we know the 21:43 alert landed is that a human
# remembered receiving it. That is not evidence. Every send now says whether it delivered.
# THE LEAK CONSTRAINT is the hard part, because the bot token is IN THE URL: keep `-o /dev/null`
# (never capture the body), keep `2>/dev/null` (curl's stderr can echo the URL), and sanitise
# `-w '%{http_code}'` down to digits before it can reach `log`. Only digits and the caller's fixed
# label can ever be printed. Still non-fatal (the whole body stays in a `( … ) || true` subshell,
# a log line is not an action) and still inert when the tooling/config is missing — but INERT NOW
# SAYS SO, since silent inertness is the exact bug class this closes.
tg_send_tokenless() {
  local _text="$1" _label="${2:-alert}"
  if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    log "tg-send: jq/curl missing — $_label SKIPPED (nothing sent)"
    return 0
  fi
  (
    _tsd="${TELEGRAM_STATE_DIR:-}"
    _ienv="${INSTANCE_ENV:-$KICKOFF_DIR/instance.env}"
    if [ -z "$_tsd" ] && [ -f "$_ienv" ]; then
      _tsd="$( set +eu; . "$_ienv" >/dev/null 2>&1 || true; printf '%s' "${TELEGRAM_STATE_DIR:-}" )"
    fi
    _settings="${SETTINGS_FILE:-$REPO_DIR/.claude/settings.local.json}"
    _access="$_tsd/access.json"
    if [ -z "$_tsd" ] || [ ! -f "$_settings" ] || [ ! -f "$_access" ]; then
      log "tg-send: no state dir / settings / access.json — $_label SKIPPED (nothing sent)"
      exit 0
    fi
    _token="$(jq -r '.env.TELEGRAM_BOT_TOKEN // empty' "$_settings" 2>/dev/null || true)"
    _chat="$(jq -r '.allowFrom[0] // empty' "$_access" 2>/dev/null || true)"
    if [ -z "$_token" ] || [ -z "$_chat" ]; then
      log "tg-send: no bot token / chat id — $_label SKIPPED (nothing sent)"
      exit 0
    fi
    _code="$(printf 'url=%s\n' "https://api.telegram.org/bot${_token}/sendMessage" \
      | curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
          --data-urlencode "chat_id=${_chat}" \
          --data-urlencode "text=${_text}" \
          -K - 2>/dev/null || true)"
    case "$_code" in ''|*[!0-9]*) _code=000 ;; esac      # only digits may reach the log (000 = no response at all)
    if [ "$_code" = "200" ]; then
      log "tg-send: delivered ($_label, HTTP 200)"
    else
      log "tg-send: FAILED ($_label, HTTP $_code) — the operator did NOT receive this alert"
    fi
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
      # v0.39 engine parity: the WORKER_ENGINE=opencode bridge is the grinev
      # `opencode-telegram` bot exec'd INSIDE this session group (session-run's final
      # exec). Same trust shape as the bun signature above — a descendant of OUR pgid —
      # so accepting it here cannot see another org's bridge. Without this line the
      # never-up belt declared every healthy opencode bridge DEAF and mercy-killed it on
      # a widening backoff (bit live 2026-08-22, all eight orgs recycling).
      *opencode-telegram*) return 0 ;;
    esac
  done
  return 1
}

# G3 distinct degraded alarm: fired ONCE when the respawn CAP trips (auto-restart is giving up).
bridge_degraded_alarm() {
  tg_send_tokenless "⚠️ Telegram bridge keeps crashing on this worker — I auto-respawned it ${BRIDGE_RESPAWN_CAP}× and it died again each time, so I'm STOPPING auto-restart to avoid a refresh loop. The session is still running but INBOUND Telegram is DOWN until the next healthy refresh. Likely a plugin/runtime fault. This is NOT the usual cooking ping." "bridge-degraded"
}

# v0.6 fail-loud: the never-up alarm (fired once per outage, when the durable flag is freshly written).
# v0.9: the old text promised "at most N refresh(es), then stop" — behaviour the code no longer has,
# and an alarm that describes a system the operator does not actually own is a lie shipped to them.
# v0.11: and the text again describes the system the operator ACTUALLY owns — the retries are now
# capped (the alarms are not), so promising "I do not give up" on the retry path would be the same
# lie in the opposite direction.
bridge_neverup_alarm() {
  tg_send_tokenless "🔇 Telegram bridge NEVER came up within ${1:-?}s on this worker — it is computing but DEAF on Telegram (inbound + replies both down). I wrote .kickoff/bridge-escalated and am retrying now; if it stays down I KEEP retrying on a widening backoff (${BRIDGE_BOOT_BACKOFF_START:-600}s, doubling to a ${BRIDGE_BOOT_BACKOFF_MAX:-3600}s ceiling) for up to ${BRIDGE_BOOT_BACKOFF_REFRESH_CAP:-6} attempts. If none of them help I STOP restarting (each restart kills in-flight work) but I keep alerting you on the same cadence — I never go quiet. Likely causes: a channel spec that is not allowlisted, a plugin/runtime fault, or a foreign process holding this bot's getUpdates slot. This is NOT the usual cooking ping." "bridge-neverup"
}

# v0.9 the BOUNDED re-alarm while backing off. A SEPARATE function, not a reuse of the never-up
# alarm: it carries different facts (how long deaf, how many retries, when the next one lands),
# and keeping it distinct is also what lets the hermetic selftest observe re-alarms independently
# of the once-per-outage escalation alarm.
bridge_backoff_alarm() {
  tg_send_tokenless "🔇 Telegram bridge STILL has not come up on this worker — deaf for ~${2:-?}m now, ${1:-?} backoff retr(ies) so far. Next automatic attempt in ~$(( ${3:-0} / 60 ))m. I keep retrying on a widening interval until it returns; .kickoff/bridge-escalated is still set. This is NOT the usual cooking ping." "bridge-backoff"
}

# v0.11 the CAPPED re-alarm — a THIRD, deliberately distinct payload. Once the restarts are retired
# the operator's situation has materially changed (nothing automatic will fix this any more) and the
# alarm must say so unmistakably, name WHY, and name what a human should check. It is a separate
# function for the same reason bridge_backoff_alarm is: different facts, and the hermetic selftest
# can then tell a "still retrying" ping apart from a "stopped retrying, still watching" one — which
# is the exact distinction that would otherwise regress silently back into the deleted give-up.
bridge_backoff_capped_alarm() {
  tg_send_tokenless "🔇 Telegram bridge is STILL down on this worker — deaf for ~${2:-?}m. I restarted the session ${1:-?}× on a widening backoff and NONE of it helped, so I have STOPPED restarting (every restart kills whatever the session was working on). I am NOT going quiet: I keep watching and will keep pinging you about this. A human needs to look — likely one of: (1) a foreign process holding this bot's getUpdates slot, (2) a missing/invalid TELEGRAM_BOT_TOKEN for this channel, (3) this worker is legitimately not telegram-bridged, in which case set BRIDGE_LIVENESS=0. Next check in ~$(( ${3:-0} / 60 ))m. This is NOT the usual cooking ping." "bridge-backoff-capped"
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

# ── v0.10 THE OUTAGE BREADCRUMB ($KICKOFF_DIR/bridge-outages.log) ────────────────────────────
# WHY IT IS NOW WRITTEN AT TWO POINTS (the crumb used to lose its own race). v0.9 had exactly one
# writer — bridge_clear_escalation, on bridge_liveness_step's healthy first-seen latch — and that
# latch requires bridge_present to SUCCEED. refresh() sets BRIDGE_SEEN=0, so after a recovering
# refresh the real order is: session starts -> claude boots -> the bridge appears -> the NEXT poll
# tick clears the flag and writes the crumb. The recovered session's re-ground announce can
# therefore run BEFORE the crumb exists — announcing with the exact amnesia the crumb was built to
# prevent, which is the whole point of the artifact.
#
# CHOSEN APPROACH: a two-phase record. The OPEN half is written at the moment a recovery refresh
# is ISSUED — a point that provably PRECEDES the new session (we kill the current one on the very
# next line) and where the durable flag and its ISO start timestamp are both already in hand. The
# CLOSE half RECONCILES that same row in place when the bridge actually returns.
#
# TRADE-OFF, stated plainly: the crumb can now describe an outage that is still running, so its
# last row is sometimes an OPEN record with no end time — the consumer must read both shapes, and
# a supervisor killed mid-outage leaves an OPEN row nobody ever closes. That last case is correct,
# not a defect: it says "deafness started here, end unknown", which is exactly what happened. The
# price paid for it is a file rewrite instead of a pure append on the close path. Recovery WITHOUT
# a refresh (a bridge that comes up late on its own) is untouched: there is no OPEN row, so the
# close simply appends the complete record exactly as v0.9 did. Both writers go through
# bridge_outage_write, so ONE outage owns exactly ONE row however many retries it took.

# rc 0 = the crumb's last row is an UNFINISHED (OPEN) outage record awaiting its end time.
bridge_outage_last_is_open() {
  local crumb="$KICKOFF_DIR/bridge-outages.log"
  [ -f "$crumb" ] || return 1
  case "$(tail -n1 "$crumb" 2>/dev/null || true)" in
    *' -> OPEN ('*) return 0 ;;
  esac
  return 1
}

# Bound the crumb so it cannot grow without limit inside the "contained" .kickoff/ folder.
# `mv` is safe HERE — in deliberate contrast to rotate-log.sh's copytruncate, which exists only
# because the supervisor's own stdout fd stays open on ITS log: nothing holds an open fd on the
# breadcrumb (we append and close on every write), so re-pointing the name at a fresh inode loses
# nothing. v0.10: when the tmp path is IMPOSSIBLE (an unwritable dir, or something planted at
# $crumb.tmp) v0.9 silently no-op'd — so "bounded by construction" was FALSE under exactly the
# failure modes the bound exists for, and the file then grew forever. Fall back to a non-atomic
# in-place rewrite, and if even that fails, SAY SO rather than swallowing it.
bridge_outage_trim() {
  local crumb="$KICKOFF_DIR/bridge-outages.log" keep="${BRIDGE_OUTAGE_LOG_KEEP:-20}" _n _kept
  case "$keep" in ''|*[!0-9]*) keep=20 ;; esac
  [ -f "$crumb" ] || return 0
  _n="$( { wc -l < "$crumb"; } 2>/dev/null | tr -d '[:space:]' || true)"
  case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
  [ "$_n" -gt "$keep" ] || return 0
  # Grouped for the same reason the append is (see bridge_outage_write): `> "$crumb.tmp" 2>/dev/null`
  # suppresses TAIL's stderr, not BASH's — and it is bash that fails, and loudly, when the tmp path
  # cannot be opened. Caught by scenario (v)'s planted directory leaking "Is a directory" into the
  # supervisor log while every assertion around it was already green.
  if { tail -n "$keep" "$crumb" > "$crumb.tmp"; } 2>/dev/null; then
    mv -f "$crumb.tmp" "$crumb" 2>/dev/null && return 0
  fi
  rm -f "$crumb.tmp" 2>/dev/null || true
  _kept="$(tail -n "$keep" "$crumb" 2>/dev/null || true)"
  if [ -n "$_kept" ] && { printf '%s\n' "$_kept" > "$crumb"; } 2>/dev/null; then
    log "bridge-liveness: outage breadcrumb trimmed IN PLACE ($crumb.tmp unusable) — the ${keep}-line bound holds, non-atomically"
    return 0
  fi
  log "bridge-liveness: could NOT trim the outage breadcrumb ($crumb) — it is OVER its ${keep}-line bound and will keep growing until that is fixed"
  return 0
}

# The ONE writer: append $1, or RECONCILE a trailing OPEN row with it, then bound the file.
# rc 0 = the row is on disk; rc 1 = it is NOT — and a caller must then never claim it was recorded
# (v0.9's recovery line said "recorded in <crumb>" unconditionally, including when the append had
# just failed under it).
bridge_outage_write() {
  local line="$1" crumb="$KICKOFF_DIR/bridge-outages.log" _kept rc=0
  # The braces are NOT cosmetic: `>> "$crumb" 2>/dev/null` applies the suppression AFTER bash has
  # already opened — and failed on — the crumb, so bash's own "Permission denied" escaped into the
  # supervisor log. Grouping puts the suppression outside the redirection that actually fails.
  if bridge_outage_last_is_open; then
    _kept="$(sed '$d' "$crumb" 2>/dev/null || true)"
    if [ -n "$_kept" ]; then
      { printf '%s\n%s\n' "$_kept" "$line" > "$crumb"; } 2>/dev/null || rc=1
    else
      { printf '%s\n' "$line" > "$crumb"; } 2>/dev/null || rc=1
    fi
  else
    { printf '%s\n' "$line" >> "$crumb"; } 2>/dev/null || rc=1
  fi
  [ "$rc" -eq 0 ] || return 1
  bridge_outage_trim
  return 0
}

# Phase ONE: called immediately BEFORE a recovery refresh, while the durable flag is still on disk.
# This is what beats the race — the row exists before the session that must read it is even started.
bridge_outage_open_record() {
  [ "${DRY_RUN:-0}" = "1" ] && return 0            # inert by construction (DRY_RUN never refreshes anyway)
  local flag="$KICKOFF_DIR/bridge-escalated" crumb="$KICKOFF_DIR/bridge-outages.log" _start _reason
  [ -f "$flag" ] || return 0
  _start="$(sed -n 1p "$flag" 2>/dev/null || true)"
  _reason="$(sed -n 2p "$flag" 2>/dev/null || true)"
  if bridge_outage_write "${_start:-unknown} -> OPEN (still deaf; recovery refresh issued $(date -u +%FT%TZ 2>/dev/null || echo now)) ${_reason:-unknown}"; then
    log "bridge-liveness: outage window recorded OPEN in $crumb BEFORE this refresh — the session it starts can announce its own deafness instead of announcing as if nothing happened"
  else
    log "bridge-liveness: could NOT record the OPEN outage window in $crumb — the session this refresh starts will announce without it"
  fi
}

# clears the durable flag on recovery (a healthy bridge = comms restored). DRY_RUN mutates nothing.
bridge_clear_escalation() {
  local flag="$KICKOFF_DIR/bridge-escalated"
  [ -f "$flag" ] || return 0
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN — would clear the bridge escalation flag ($flag)"
    return 0
  fi
  # v0.9 OUTAGE BREADCRUMB, phase TWO (see the block above bridge_outage_last_is_open for the
  # two-phase design and its trade-off). A recovered worker used to have total AMNESIA about its
  # own deafness: the flag was deleted and nothing survived it, so the next session announced as
  # if nothing had happened while the operator had spent the outage shouting into a dead channel.
  # Record the window BEFORE deleting the flag, so re-ground can say "I was deaf 21:43→22:09 —
  # here is what you may have missed" (session-run.sh's operating rule (1) is the CONSUMER that
  # reads this; a breadcrumb nothing reads would be the .kickoff/secret.env failure all over
  # again — and that read side is now asserted by scripts/reground-prompt-selftest.sh, not merely
  # believed). The START comes from the FLAG'S OWN ISO timestamp — durable, so it survives a
  # supervisor restart mid-outage, unlike the in-process BRIDGE_BOOT_DEAF_SINCE which only
  # measures THIS era.
  local crumb="$KICKOFF_DIR/bridge-outages.log"
  local _start _reason _end _s _e _dur
  _start="$(sed -n 1p "$flag" 2>/dev/null || true)"
  _reason="$(sed -n 2p "$flag" 2>/dev/null || true)"
  _end="$(date -u +%FT%TZ 2>/dev/null || echo now)"
  # `date -u -d` is GNU-only. Fine for this supervisor (it already requires pgrep -P, setsid and
  # /proc), and it degrades safely rather than portably: a GARBAGE timestamp makes it exit
  # non-zero, which yields "duration unknown" instead of breaking recovery. Clearing the flag must
  # never be blockable by the bookkeeping about clearing the flag.
  # The `-n "$_start"` guard is NOT redundant: GNU `date -d ""` SUCCEEDS and returns midnight
  # today, so an empty/truncated flag would mint a plausible-looking but entirely FABRICATED
  # duration ("468m") that the next session would relay to the operator as fact. An unparseable
  # start must produce "unknown", never an invented number.
  _s=""
  if [ -n "$_start" ]; then _s="$(date -u -d "$_start" +%s 2>/dev/null || true)"; fi
  _e="$(date -u +%s 2>/dev/null || true)"
  case "$_s" in ''|*[!0-9]*) _s="" ;; esac
  case "$_e" in ''|*[!0-9]*) _e="" ;; esac
  _dur="duration unknown"
  if [ -n "$_s" ] && [ -n "$_e" ] && [ "$_e" -ge "$_s" ]; then _dur="$(( (_e - _s) / 60 ))m"; fi
  # Completes a trailing OPEN row for this outage, or appends a fresh complete one when recovery
  # happened WITHOUT a refresh. Clearing the flag must never be blockable by the bookkeeping about
  # clearing the flag, so a failed write is REPORTED, never fatal — and never claimed as a success.
  local _wrote=0
  bridge_outage_write "$(printf '%s -> %s (%s) %s' "${_start:-unknown}" "$_end" "$_dur" "${_reason:-unknown}")" && _wrote=1
  rm -f "$flag" 2>/dev/null || true
  if [ "$_wrote" = "1" ]; then
    log "bridge-liveness: bridge is UP — cleared the escalation flag ($flag); comms restored (deaf window ${_start:-unknown} -> $_end, $_dur — recorded in $crumb)"
  else
    log "bridge-liveness: bridge is UP — cleared the escalation flag ($flag); comms restored (deaf window ${_start:-unknown} -> $_end, $_dur) — but it could NOT be recorded in $crumb, so the next session will announce without it"
  fi
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
# ONE alert, then BRIDGE_BOOT_RETRY_CAP FAST (back-to-back) refreshes with reason
# `bridge-neverup`, and after those are spent a WIDENING BACKOFF that never stops — reason
# `bridge-neverup-backoff`, at BACKOFF_START doubling to a BACKOFF_MAX ceiling and then holding
# that cadence indefinitely, re-alarming every BRIDGE_BOOT_REALARM_EVERY retries. (Both reasons
# start with `bridge-`, which refresh() classes as bridge-* so the ladder survives its OWN
# refreshes — that is what lets it keep climbing.) There is NO give-up: v0.9 deleted it, because
# a give-up with no floor was itself the 07-24 outage. v0.11 bounds only the REFRESHING half of
# that ladder (BRIDGE_BOOT_BACKOFF_REFRESH_CAP): after N restarts have demonstrably failed the
# tier keeps its cadence and keeps alarming FOREVER but stops killing the session — the alarm is
# free, the refresh costs work. An instance that legitimately has no bridge sets
# BRIDGE_LIVENESS=0, which short-circuits the whole belt.
# Corroborates with bot.pid: a live FOREIGN holder of this channel's getUpdates slot is NAMED in
# the log (detection only; the kill path lives in session-run's bridge-reap.sh), while a live
# holder INSIDE our own tree is the v0.10 SIGNATURE-MISS state — positive evidence the bridge
# exists, so the belt escalates once and then deliberately does NOT retry (see that branch).
# Guards: inert without a numeric SESSION_STARTED or a derivable TELEGRAM_STATE_DIR (a
# non-telegram START_CMD keeps the v0.5 inertness); DRY_RUN = detect-only (G4); never aborts the
# loop (G5/G6 discipline, callers add `|| true`).
bridge_boot_check() {
  case "${SESSION_STARTED:-}" in ''|*[!0-9]*) return 0 ;; esac
  local grace="${BRIDGE_BOOT_GRACE_SECONDS:-120}"
  case "$grace" in ''|*[!0-9]*) grace=120 ;; esac
  # ONE clock read per tick, through the seam: the grace gate and the backoff gate can then never
  # disagree about what "now" is (two reads either side of a slow probe could).
  local now; now="$(bridge_now)"
  [ "$((now - SESSION_STARTED))" -ge "$grace" ] || return 0
  # v0.9 QUIET GATE. Once the fast retries are spent and a backoff timer is armed, a not-yet-due
  # tick returns HERE — before the state-dir derivation, the bot.pid corroboration and the LOUD
  # log. That keeps an hour of backing off to roughly ONE log line per tier instead of one per
  # 15s poll tick (~240 of them). It takes over the cheap early-out role of the old permanent
  # give-up latch without inheriting the permanence that WAS the 07-24 outage.
  if [ "${BRIDGE_BOOT_FAILS:-0}" -ge "${BRIDGE_BOOT_RETRY_CAP:-1}" ] \
     && [ "${BRIDGE_BOOT_NEXT_AT:-0}" -gt 0 ] \
     && [ "$now" -lt "${BRIDGE_BOOT_NEXT_AT:-0}" ]; then
    return 0
  fi
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
  local holder="" extra="" sig_miss=0
  holder="$(cat "$tsd/bot.pid" 2>/dev/null || true)"
  holder="${holder//[[:space:]]/}"
  case "$holder" in ''|*[!0-9]*|0|1) holder="" ;; esac
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    if bridge_pid_in_session_tree "$holder"; then
      # v0.10 SIGNATURE MISS — a DISTINCT state, not a footnote on the deaf one. A live holder
      # inside our OWN tree is POSITIVE evidence that a bridge exists and that only
      # bridge_present's argv pattern missed it (a telegram-plugin update that renames the
      # launcher — so *bun*telegram* / *bun*server.ts* / *telegram*server.ts* stop matching — is
      # the realistic trigger). Pre-v0.10 this fact was logged and then DISCARDED into the retry
      # path; see the sig_miss branch below for why that stopped being survivable.
      sig_miss=1
      extra=" (bot.pid=$holder IS in our session tree — a bridge exists but its argv missed the signature?)"
    else
      extra=" — foreign consumer pid=$holder holds this channel's getUpdates slot ($tsd/bot.pid)"
      log "bridge-boot: foreign consumer holds this channel's getUpdates slot (pid=$holder, outside our session tree; detection only — reap-on-startup owns the kill path)"
    fi
  fi
  if [ "$DRY_RUN" = "1" ]; then                                # G4: detect-only, never flag/refresh
    log "DRY_RUN — bridge NEVER came up within ${grace}s${extra}; would escalate (flag + alert) then retry on a widening backoff (${BRIDGE_BOOT_BACKOFF_START:-600}s doubling to a ${BRIDGE_BOOT_BACKOFF_MAX:-3600}s ceiling). Detect-only, no action."
    return 0
  fi
  # v0.10 SIGNATURE-MISS quiet gate. The sig_miss branch below deliberately never arms the ladder,
  # so the backoff quiet gate above can NEVER catch these ticks — without a gate here the LOUD
  # line would repeat every poll tick (~240/hour) forever. One tick escalates and alarms; the rest
  # are silent (the state is unchanged and the operator already has the alert).
  if [ "$sig_miss" = "1" ] && [ "${_BRIDGE_BOOT_SIGMISS_WARNED:-0}" = "1" ]; then
    return 0
  fi
  log "bridge-liveness: Telegram bridge NEVER came up within ${grace}s of session start — the worker is running DEAF (silent gag)${extra}"
  # start this era's deafness clock BEFORE the flag call, so it is set even when the flag already
  # exists from a previous supervisor era (the flag's own timestamp is the durable record; this
  # in-process one only feeds the "~Nm deaf" figure in the re-alarm).
  [ "${BRIDGE_BOOT_DEAF_SINCE:-0}" -le 0 ] && BRIDGE_BOOT_DEAF_SINCE="$now"
  if bridge_escalate_flag "bridge never came up within ${grace}s${extra}"; then
    bridge_neverup_alarm "$grace"                              # the once-per-outage escalation alarm, unchanged
  fi
  # ── v0.10 SIGNATURE MISS: escalate + alarm ONCE, then STOP. NEVER retry. ────────────────────
  # We hold positive evidence the bridge is ALIVE (a live bot.pid inside our own session tree) and
  # only the argv match failed. Refreshing here is strictly HARMFUL: it kills the session's
  # in-flight work on a worker whose comms are fine, and — unlike real deafness — the trade the
  # backoff tier is built on ("a deaf worker cannot report in-flight work to anyone anyway") does
  # NOT hold, because this worker CAN reach the operator. So a human can act, and the machine must
  # not. Under the old permanent give-up, falling through cost ONE wasted refresh before the latch
  # parked it; with the give-up deleted the same fall-through costs a session-killing refresh every
  # BRIDGE_BOOT_BACKOFF_MAX (60m) FOREVER, plus recurring false "bridge NEVER came up" alarms sent
  # over the very bridge that is delivering them. The real fix for a persistent signature miss is
  # bridge_present's pattern, not a restart — which is why the log says so.
  if [ "$sig_miss" = "1" ]; then
    _BRIDGE_BOOT_SIGMISS_WARNED=1
    log "bridge-boot: SIGNATURE MISS — bot.pid=$holder is a LIVE process inside our OWN session tree, so a bridge almost certainly EXISTS and bridge_present's argv pattern is stale. NOT retrying and NOT arming the backoff: a refresh would kill this session's in-flight work on a worker whose Telegram is probably fine, and the alert above proves the operator is reachable. Fix bridge_present's signature (did the telegram plugin's launcher change?), do not restart."
    return 0
  fi
  if [ "${BRIDGE_BOOT_FAILS:-0}" -lt "${BRIDGE_BOOT_RETRY_CAP:-1}" ]; then
    BRIDGE_BOOT_FAILS=$(( ${BRIDGE_BOOT_FAILS:-0} + 1 ))
    log "bridge-boot: guarded refresh #${BRIDGE_BOOT_FAILS} (bridge-neverup) — a fresh claude --channels is the only way a bridge appears"
    bridge_outage_open_record                                 # crumb FIRST: the refresh kills this session on the next line
    refresh "bridge-neverup"
    return 0
  fi
  # ── v0.9 the WIDENING BACKOFF TIER (this replaced the permanent give-up) ────────────────────
  local iv deaf jit rcap
  if [ "${BRIDGE_BOOT_NEXT_AT:-0}" -le 0 ]; then
    # FIRST tick past the fast-retry cap: ARM the timer only, never retry. The fast refresh
    # happened moments ago; retrying again on this tick would be exactly the tight loop the old
    # give-up comment was right to fear — the fix was the missing floor, not the retrying.
    # Each retry restarts the session, which re-arms a FRESH ${grace}s boot grace before the next
    # detection can fire, so the true cadence is max(interval, grace). With the defaults
    # (600 > 120) the grace is fully absorbed inside the interval and is invisible; if an operator
    # sets a grace LONGER than BACKOFF_START the retry simply lands at grace expiry, which is
    # still correct — never retry before the grace has proven the bridge did not come up.
    iv="$(bridge_boot_backoff_interval)"
    jit="$(bridge_jitter "$(( iv / 10 ))")"                   # de-lockstep workers that went deaf together
    iv=$(( iv + jit ))
    BRIDGE_BOOT_NEXT_AT=$(( now + iv ))
    log "bridge-boot: fast retries exhausted (${BRIDGE_BOOT_FAILS:-0}) — switching to a WIDENING backoff; next retry in ${iv}s (incl. ${jit}s jitter), doubling to a ${BRIDGE_BOOT_BACKOFF_MAX:-3600}s ceiling. This NEVER gives up: a deaf worker is useless to a pocket-steered operator, and the 07-24 outage proved the blocker is usually transient. (An instance that legitimately has NO bridge should set BRIDGE_LIVENESS=0 — that short-circuits this whole belt.)"
    return 0
  fi
  if [ "$now" -ge "${BRIDGE_BOOT_NEXT_AT:-0}" ]; then
    BRIDGE_BOOT_BACKOFF_N=$(( ${BRIDGE_BOOT_BACKOFF_N:-0} + 1 ))
    iv="$(bridge_boot_backoff_interval)"                        # widened by the increment above
    jit="$(bridge_jitter "$(( iv / 10 ))")"
    iv=$(( iv + jit ))
    BRIDGE_BOOT_NEXT_AT=$(( now + iv ))
    deaf=$(( (now - ${BRIDGE_BOOT_DEAF_SINCE:-0}) / 60 ))
    [ "$deaf" -lt 0 ] && deaf=0
    # ── v0.11 THE REFRESH CAP: bound the EXPENSIVE half, never the cheap one ───────────────────
    # The ladder above keeps walking forever — but past this many BACKOFF-tier refreshes it walks
    # purely as the ALARM CLOCK. A transient blocker is long gone by now (it clears in one or two
    # retries); what is left is a PERSISTENT deafness no restart can fix — a foreign getUpdates
    # holder, a channel with no bot token — and against that the retry has stopped being recovery
    # and become pure destruction: one killed session's worth of in-flight work every <=60m,
    # forever. READ THIS BEFORE "SIMPLIFYING" IT BACK: this is NOT the v0.19 give-up. That latch
    # went permanently SILENT and abandoned the operator; this keeps alarming on the same widening
    # cadence indefinitely and only retires the destructive action, after it has demonstrably
    # failed. Never add a park/latch on the ALARM path — going silent IS the bug this release fixes.
    # BRIDGE_BOOT_BACKOFF_N is the tier's own monotonic tick counter and is incremented ONLY above,
    # so "refreshes issued from this tier" is exactly min(BACKOFF_N, rcap) — no extra state needed,
    # and the transition therefore lands on exactly one tick (N == rcap+1).
    rcap="$(bridge_boot_refresh_cap)"
    if [ "${BRIDGE_BOOT_BACKOFF_N}" -gt "$rcap" ]; then
      if [ "${BRIDGE_BOOT_BACKOFF_N}" -eq "$(( rcap + 1 ))" ]; then
        log "bridge-boot: REFRESH CAP REACHED — ${rcap} backoff restarts over ~${deaf}m did NOT bring the bridge back, so I am no longer restarting this session (each restart KILLS its in-flight work). I keep watching and keep ALARMING on the same widening cadence — this is not a give-up, only the destructive half retiring. A human should check: a foreign process holding this channel's getUpdates slot, a missing/invalid TELEGRAM_BOT_TOKEN, or set BRIDGE_LIVENESS=0 if this instance is legitimately not telegram-bridged. Next check in ${iv}s (incl. ${jit}s jitter)"
        # alarm IMMEDIATELY on the transition, off-cadence, and bookmark it: the operator's
        # situation just changed (nothing automatic will fix this now), and waiting up to
        # BRIDGE_BOOT_REALARM_EVERY more retries to say so would be an hour+ of stale silence.
        BRIDGE_BOOT_LAST_ALARM_N="$BRIDGE_BOOT_BACKOFF_N"
        bridge_backoff_capped_alarm "$rcap" "$deaf" "$iv"
      else
        log "bridge-boot: still deaf after ~${deaf}m — alarm-only (restarts retired at ${rcap}); next check in ${iv}s (incl. ${jit}s jitter)"
        if bridge_boot_alarm_due "$BRIDGE_BOOT_BACKOFF_N"; then
          BRIDGE_BOOT_LAST_ALARM_N="$BRIDGE_BOOT_BACKOFF_N"   # bookmark BEFORE the send (a failed send must still advance the cadence)
          bridge_backoff_capped_alarm "$rcap" "$deaf" "$iv"
        fi
      fi
      return 0                                                # NO refresh, NO crumb — the session lives
    fi
    log "bridge-boot: backoff retry #${BRIDGE_BOOT_BACKOFF_N} (bridge-neverup-backoff) — still deaf after ~${deaf}m; next retry in ${iv}s (incl. ${jit}s jitter)"
    if bridge_boot_alarm_due "$BRIDGE_BOOT_BACKOFF_N"; then
      # bookmark BEFORE the send, exactly as the crash-loop re-alarm does: a failed or skipped
      # send must still advance the cadence, or a broken channel becomes an alarm storm.
      BRIDGE_BOOT_LAST_ALARM_N="$BRIDGE_BOOT_BACKOFF_N"
      bridge_backoff_alarm "$BRIDGE_BOOT_BACKOFF_N" "$deaf" "$iv"
    fi
    bridge_outage_open_record                                   # crumb FIRST: the refresh kills this session on the next line
    refresh "bridge-neverup-backoff"                            # `bridge-*` ⇒ refresh() PRESERVES the ladder's state
    return 0
  fi
  return 0                                                      # armed but not due (the quiet gate normally catches this first)
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
      # v0.9: the reset also DISARMS the backoff (timer, exponent, re-alarm bookmark, deaf clock)
      # — a stale NEXT_AT surviving recovery would make the NEXT outage resume mid-ladder at the
      # 60m ceiling instead of starting over at 10m.
      bridge_boot_reset
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

# ── v0.7 G1 slice 5: the ENGINE HOP — `kickoff pull` cycles the RUNNING worker ─
# `kickoff pull` advances the pin (instance.env KICKOFF_CORE_DIR + core.lock) while THIS
# process keeps executing the code it loaded at start. The hop unit closes that gap:
# every poll tick fresh-resolves the PINNED engine and compares it with the RUNNING one;
# a mismatch is acted on ONLY at the next session boundary (exactly where start_session
# would run after a session death/refresh — never mid-session), where the new engine is
# verified first (FULL-scope preflight run FROM the new engine — the pin checks #6/#8
# PLUS the session-readiness gate its own startup will enforce fail-closed, so a
# pin-green/full-red instance can never hop into a silent post-exec death — + bash -n on
# its supervisor.sh) and then taken over via `exec`. `exec` is the whole trick: same PID ⇒
# supervisor.lock stays valid (no stop/start window, no second-supervisor race), the TERM
# trap is re-armed by the new code, and the PERMISSION_MODE grant + REPO_DIR identity
# carry in the KERNEL-HELD process env — never re-read from a forgeable file. MODEL /
# EFFORT (and the now-fossil KICKOFF_CORE_DIR) are UNSET at the exec so the new engine
# re-resolves them from instance.env / its own root: durable config beats fossil env.
# A red verification NEVER hops: stay on the old engine, write a durable
# .kickoff/hop-blocked flag, send ONE tokenless alert (re-alert only when the TARGET
# changes — a blocked hop must not ping every boundary). ORIGIN-INERT: no core.lock, or
# a pin that resolves to REPO_DIR itself (the kickoff-dev dogfood origin), keeps the
# whole watch a no-op — a stray lock must never make the origin hop.
# EXTRACTED as one contiguous unit (between the >>> / <<< marker lines) by
# scripts/hop-selftest.sh and driven with stubs — testable without a real supervisor.
# >>> KICKOFF-HOP-UNIT >>>

RUNNING_ENGINE_DIR="${RUNNING_ENGINE_DIR:-$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd -P || printf '%s' "$SCRIPT_DIR/..")}"
# the commit whose code THIS process actually loaded — captured ONCE at start. The
# single-adopter pull moves the SAME checkout under us (git checkout --detach), so the
# mismatch is only visible against this snapshot, never against a re-read of HEAD.
RUNNING_ENGINE_COMMIT="${RUNNING_ENGINE_COMMIT:-$(git -C "${RUNNING_ENGINE_DIR}" rev-parse HEAD 2>/dev/null || true)}"
HOP_TARGET_DIR=""            # set by engine_hop_resolve while a mismatch is pending
HOP_TARGET_COMMIT=""
HOP_LOGGED_TARGET=""         # last pending target logged (one line per target, not per tick)
HOP_ALERTED_TARGET=""        # last target alerted BLOCKED for (re-alert only on a CHANGE)

_hop_canon() { readlink -f -- "$1" 2>/dev/null || (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }

# Fresh-resolve the PINNED engine — instance.env's KICKOFF_CORE_DIR is re-read from the
# FILE on every call (a parked-worktree pull rewrites it mid-run; the file is sourced in
# a subshell with the var UNSET first, so instance.env's self-exporting `${VAR:-…}` form
# can't echo our own stale env back at us) + core.lock's pinned commit — and compare with
# the RUNNING engine. Sets HOP_TARGET_DIR/_COMMIT on a genuine mismatch; empties them
# otherwise. Fail-toward-inaction: anything unparseable/unresolvable means NO hop.
engine_hop_resolve() {
  HOP_TARGET_DIR=""; HOP_TARGET_COMMIT=""
  local lock="$KICKOFF_DIR/core.lock"
  if [ ! -f "$lock" ]; then return 0; fi       # ORIGIN-INERT: an un-pinned repo never hops
  local pinned_commit
  pinned_commit="$(awk '$1=="commit"{print $2; exit}' "$lock" 2>/dev/null || true)"
  if [ -z "$pinned_commit" ]; then return 0; fi  # pre-format-2 lock: nothing comparable — inert
  local ienv="${INSTANCE_ENV:-$KICKOFF_DIR/instance.env}" pinned_dir=""
  if [ -f "$ienv" ]; then
    pinned_dir="$( set +eu; unset KICKOFF_CORE_DIR; cd "$REPO_DIR" 2>/dev/null || true; . "$ienv" >/dev/null 2>&1 || true; printf '%s' "${KICKOFF_CORE_DIR:-}" )"
  fi
  if [ -z "$pinned_dir" ]; then pinned_dir="${KICKOFF_CORE_DIR:-}"; fi   # file silent → startup resolution
  if [ -z "$pinned_dir" ]; then return 0; fi
  local pinned_rp repo_rp running_rp
  pinned_rp="$(_hop_canon "$pinned_dir")"
  repo_rp="$(_hop_canon "$REPO_DIR")"
  if [ "$pinned_rp" = "$repo_rp" ]; then return 0; fi   # ORIGIN-INERT: self-referential pin (dogfood origin)
  running_rp="$(_hop_canon "$RUNNING_ENGINE_DIR")"
  if [ "$pinned_rp" = "$running_rp" ]; then
    # same checkout — a hop is due only if it MOVED under us (pinned commit ≠ the commit
    # this process loaded). Unknown running commit ⇒ can't prove a mismatch ⇒ inert.
    if [ -z "${RUNNING_ENGINE_COMMIT:-}" ]; then return 0; fi
    if [ "$pinned_commit" = "$RUNNING_ENGINE_COMMIT" ]; then return 0; fi
  fi
  HOP_TARGET_DIR="$pinned_rp"; HOP_TARGET_COMMIT="$pinned_commit"
  return 0
}

# The per-tick step: DETECT + log (once per target). The hop itself is DEFERRED to the
# next session boundary — a healthy mid-flight session is never cut for an upgrade; the
# pull's refresh-flag touch is what makes that boundary arrive within ~POLL_SECONDS.
engine_hop_step() {
  engine_hop_resolve || true
  if [ -n "$HOP_TARGET_DIR" ]; then
    if [ "$HOP_LOGGED_TARGET" != "$HOP_TARGET_DIR@$HOP_TARGET_COMMIT" ]; then
      HOP_LOGGED_TARGET="$HOP_TARGET_DIR@$HOP_TARGET_COMMIT"
      log "engine-hop: pinned engine ($HOP_TARGET_DIR @ $HOP_TARGET_COMMIT) ≠ running ($RUNNING_ENGINE_DIR @ ${RUNNING_ENGINE_COMMIT:-unknown}) — hop DEFERRED to the next session boundary"
    fi
  else
    HOP_LOGGED_TARGET=""
  fi
  return 0
}

# The session-boundary hook (called from refresh() and trigger-3, right where
# start_session would run): verify the pinned engine FROM the pinned engine, then exec
# its supervisor.sh. Never returns non-zero (callers sit inside the set -e poll loop).
engine_hop_boundary() {
  engine_hop_resolve || true
  if [ -z "$HOP_TARGET_DIR" ]; then return 0; fi
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN — would hop to the pinned engine ($HOP_TARGET_DIR @ $HOP_TARGET_COMMIT): full-scope preflight + bash -n from the new engine, then exec its supervisor.sh. Detect-only, no action."
    return 0
  fi
  local tsup="$HOP_TARGET_DIR/scripts/supervisor.sh" tpf="$HOP_TARGET_DIR/scripts/preflight.sh"
  local reason="" pf_out="" pf_tmp=""
  if [ ! -f "$tsup" ]; then
    reason="pinned engine has no scripts/supervisor.sh ($tsup)"
  elif ! bash -n "$tsup" 2>/dev/null; then
    reason="bash -n FAILED on the pinned engine's supervisor.sh ($tsup)"
  elif [ ! -f "$tpf" ]; then
    reason="pinned engine has no scripts/preflight.sh ($tpf)"
  else
    # FULL-scope preflight, run FROM the pinned engine, with the exact env the new engine's
    # own startup gate (run_preflight) will see. TWO adversarial-review finds live here:
    #  (1) KICKOFF_CORE_DIR is pinned to the TARGET *explicitly* (mirrors cmd_pull): the child
    #      otherwise inherits THIS process's kernel-held KICKOFF_CORE_DIR — the OLD engine dir,
    #      carried by every kickoff-up launch — and preflight's preset-wins rule makes #6
    #      hard-fail "the core that is RUNNING is NOT the pinned KICKOFF_CORE_DIR" on EVERY
    #      parked-worktree hop (the multi-org case), permanently blocking the hop.
    #  (2) FULL scope, not --pin: the freshly-exec'd supervisor runs the FULL gate fail-closed
    #      before starting a session, so a pin-green/full-red instance would hop straight into
    #      a silent post-exec death (exit 1, no alert, nothing above us to restart). Running
    #      the same full gate HERE keeps any red on the OLD engine — alive, durable flag +
    #      ONE alert: the red path the hop promises. Check #4 (single supervisor) self-
    #      recognizes OUR lock because this is a PLAIN command, never a command substitution:
    #      the child preflight's $PPID is deterministically OUR pid — the pid in the lock
    #      (verified: a command-substitution child false-fails #4 as "another supervisor").
    pf_tmp="$KICKOFF_DIR/.hop-preflight.$$"
    REPO_DIR="$REPO_DIR" \
      INSTANCE_ENV="${INSTANCE_ENV:-$KICKOFF_DIR/instance.env}" \
      LOCKFILE="${LOCKFILE:-$KICKOFF_DIR/supervisor.lock}" \
      KICKOFF_CORE_DIR="$HOP_TARGET_DIR" \
      bash "$tpf" > "$pf_tmp" 2>&1 \
      || reason="full-scope preflight FAILED from the pinned engine ($tpf, KICKOFF_CORE_DIR=$HOP_TARGET_DIR)"
    if [ -n "$reason" ]; then pf_out="$(cat "$pf_tmp" 2>/dev/null || true)"; fi
    rm -f "$pf_tmp" 2>/dev/null || true
  fi
  if [ -n "$reason" ]; then
    log "engine-hop: BLOCKED — $reason — STAYING on the old engine ($RUNNING_ENGINE_DIR @ ${RUNNING_ENGINE_COMMIT:-unknown}); retrying at every session boundary"
    if [ -n "$pf_out" ]; then printf '%s\n' "$pf_out"; fi
    printf 'target=%s\ncommit=%s\nreason=%s\nat=%s\n' \
      "$HOP_TARGET_DIR" "$HOP_TARGET_COMMIT" "$reason" "$(date -u +%FT%TZ 2>/dev/null || echo now)" \
      > "$KICKOFF_DIR/hop-blocked" 2>/dev/null || true
    if [ "$HOP_ALERTED_TARGET" != "$HOP_TARGET_DIR@$HOP_TARGET_COMMIT" ]; then
      HOP_ALERTED_TARGET="$HOP_TARGET_DIR@$HOP_TARGET_COMMIT"
      tg_send_tokenless "⛔ Engine hop BLOCKED on this worker: the freshly-pinned engine did NOT verify ($reason). The worker keeps running the OLD engine; details in .kickoff/hop-blocked. Run \`kickoff preflight\` in the repo to see the failing check — a pin problem needs a re-pull, a config problem needs the instance.env fixed; the hop retries at every session boundary. This is NOT the usual cooking ping."
    fi
    return 0
  fi
  # GREEN → hop. Clear any stale block flag for this pin, then exec: same PID, so the
  # lock, the launch grant, and the log fd all carry; the new code re-arms its own trap.
  rm -f "$KICKOFF_DIR/hop-blocked" 2>/dev/null || true
  log "engine-hop: verified GREEN — exec'ing the pinned engine's supervisor.sh (pid $$ carries; $HOP_TARGET_DIR @ $HOP_TARGET_COMMIT)"
  export REPO_DIR                                # identity: must survive even a pwd-derived value
  if [ -n "${PERMISSION_MODE+x}" ]; then export PERMISSION_MODE; fi   # the grant, kernel-held
  unset MODEL EFFORT KICKOFF_CORE_DIR            # durable config beats fossil env (doc §2.1/§2.3)
  export KICKOFF_HOP_EXEC=1                      # landing marker: if the new engine's OWN startup gate
                                                 # still reds (config raced since our verify), it alerts
                                                 # LOUDLY instead of dying mute (see run_preflight)
  shopt -s execfail                              # a failed exec must LOG + continue, never kill the worker
  exec bash "$tsup"
  shopt -u execfail
  unset KICKOFF_HOP_EXEC                         # exec failed — still the OLD engine; never leak the marker into sessions
  log "engine-hop: exec FAILED (execfail) — STAYING on the old engine ($RUNNING_ENGINE_DIR); will retry at the next session boundary"
  return 0
}
# <<< KICKOFF-HOP-UNIT <<<

# ── v0.8: the REACTIVE model-quota fallback belt ─────────────────────────────
# When the running worker hits its model's weekly quota wall, the supervisor, the session, and
# the Telegram bridge all stay ALIVE while EVERY turn fails — the "alive but cannot think" gap
# (liveness ≠ capability; see the core-v0.8 CORE-CHANGELOG entry). Claude Code
# prints the wall to the session's pty, which the supervisor already captures to SUPERVISOR_LOG:
#     You've reached your Fable 5 limit. Run /usage-credits to continue or switch models
# The belt scans ONLY NEW log content each tick (a byte offset; a shrink = rotation → reset to
# 0) for that string, then — INSIDE the supervisor's own shell, so the fix sticks — rewrites
# instance.env's MODEL to the fallback (atomic; every other line byte-for-byte preserved),
# `export MODEL=<fallback>` to defeat the fossilised MODEL the running supervisor passes down
# (a FILE repin alone does nothing — session-run's importer is preset-wins), refreshes the
# session to adopt it, writes a durable .kickoff/model-fallback flag, alerts the operator
# plainly (a silent downgrade is a lie by omission), and LATCHES one-shot per era.
# GUARDRAILS (each a hard line a reviewer will hunt):
#   - ONE-WAY LADDER: only switch TOWARD the fallback; never auto-escalate back (restore is a
#     manual/cron decision — a just-reset quota re-exhausts into a flip-flop).
#   - SPEND-SAFE: fable→opus is CHEAPER, so no gate. But a fallback PRICIER than the current
#     model would INCREASE spend → refuse + alert (a human decision), never auto-switch.
#   - ALREADY-ON-FALLBACK: if MODEL already == the fallback (e.g. opus's own weekly limit),
#     switching cannot help → alert "also limited", latch, never switch-to-nothing or loop.
#   - DRY_RUN=1 → detect-only (log "would switch…"), zero writes/cycles.
#   - INERT-BY-CONSTRUCTION: no detection ⇒ no action; disarmed (MODEL_FALLBACK=0) ⇒ inert;
#     no resolvable fallback ⇒ inert. G6: called `|| true` in the loop — a probe error must
#     NEVER abort the supervisor loop.
# The false-positive crux: the WORKER itself can print "reached your limit" while merely
# DISCUSSING quota. Detection therefore requires BOTH the model-limit phrasing AND the highly
# distinctive `/usage-credits` co-marker on the SAME line (faithful to the observed verbatim
# wall), so a worker talking about limits over a paragraph never trips it.
# EXTRACTED as one contiguous unit (between the >>> / <<< marker lines) by
# scripts/model-fallback-selftest.sh and driven with stubs — testable without a real supervisor.
# >>> KICKOFF-MODEL-FALLBACK-UNIT >>>

# Resolve the belt's two knobs: MODEL_FALLBACK (gate, default ON) + MODEL_FALLBACK_TO (target,
# default opus). ENV-FIRST (a value already in the supervisor's environment wins), else a
# whitelisted SUBSHELL import of instance.env (the same untrusted-config discipline as
# auth-heal/session-run — sourced in a throwaway subshell; an `exit`, a fn-redef, or a forged
# launch var dies there and never reaches us). Sets _MF_GATE / _MF_TO.
_mf_load_config() {
  local ienv="${INSTANCE_ENV:-${KICKOFF_DIR:-.kickoff}/instance.env}"
  local gate="" to=""
  [ -n "${MODEL_FALLBACK+x}" ]    && gate="$MODEL_FALLBACK"
  [ -n "${MODEL_FALLBACK_TO+x}" ] && to="$MODEL_FALLBACK_TO"
  if { [ -z "${MODEL_FALLBACK+x}" ] || [ -z "${MODEL_FALLBACK_TO+x}" ]; } && [ -f "$ienv" ]; then
    local kv fg ft
    kv="$(
      set +eu
      # shellcheck disable=SC1090
      . "$ienv" >/dev/null 2>&1 || true
      printf '%s\t%s' "${MODEL_FALLBACK:-}" "${MODEL_FALLBACK_TO:-}"
    )" || true
    IFS=$'\t' read -r fg ft <<< "$kv"
    [ -z "${MODEL_FALLBACK+x}" ]    && gate="$fg"
    [ -z "${MODEL_FALLBACK_TO+x}" ] && to="$ft"
  fi
  _MF_GATE="${gate:-1}"
  _MF_TO="${to:-opus}"
  return 0
}

# Relative COST rank for the spend-direction guard (higher = pricier; unknown = -1). Family
# aliases only, matched loosely so a versioned string still ranks. Fable 5 $10/$50 > Opus 4.8
# $5/$25 > Sonnet $3/$15 > Haiku — so fable→opus is a cost DECREASE (safe, no gate).
_mf_cost_rank() {
  case "$1" in
    *fable*|*Fable*)   printf 40 ;;
    *opus*|*Opus*)     printf 30 ;;
    *sonnet*|*Sonnet*) printf 20 ;;
    *haiku*|*Haiku*)   printf 10 ;;
    *)                 printf -- -1 ;;
  esac
}

# The DETECTOR: does the given text contain the Claude Code model-quota wall? Requires the three
# wall anchors — "reached/hit your" … "limit" … "/usage-credits" — within a TIGHT character window
# on one line. First STRIP the ANSI/CSI escapes the pty capture interleaves through the toast, THEN
# a single bounded regex enforces PROXIMITY. This is deliberately not two greps on "the same grep
# line": the pty/SUPERVISOR_LOG is newline-SPARSE (a single physical line can be megabytes of redraw
# — finding #3), so grep's line is NOT a proximity bound; two markers in unrelated redraw regions
# would collapse onto one line and falsely match. The `.{0,40}`/`.{0,24}` gaps ARE the bound: on the
# genuine toast the anchors sit ~6 bytes apart ("limit. Run /usage-credits"), so the true positive
# survives while a megabyte-wide coincidence and cross-paragraph quota discussion (finding #1) are
# rejected — the tight `.{0,24}` between "limit" and "/usage-credits" captures the wall's imperative
# form ("limit. Run …", "limit. You can run …") but not a casual clause ("limit this week; you should
# probably run /usage-credits soon"). `.` never spans a
# newline, so markers on different lines still can't match. NOTE: a VERBATIM quote of the wall, or a
# `cat` of this file / the design doc, still matches by content — that vector is closed by the N-tick
# recurrence gate in model_fallback_step (a one-off render shows the string once; a real wall repeats).
_mf_detect() {
  printf '%s' "${1:-}" \
    | sed 's/\x1b\[[0-9;?]*[ -/]*[@-~]//g' 2>/dev/null \
    | grep -aiqE '(reached your|hit your).{0,40}limit.{0,24}/usage-credits'
}

# Rewrite EVERY active MODEL assignment in instance.env → the fallback, ATOMICALLY (temp+mv),
# preserving EVERY other line (and the leading whitespace + optional `export ` on each MODEL line
# itself) byte-for-byte. ALL active MODEL= lines are rewritten (not just the first — finding #6):
# a duplicated active `MODEL=` would otherwise leave a stale later assignment that, being
# last-assignment-wins when session-run sources the file on a full restart, would silently revert
# the worker to the walled model. A commented `# MODEL=…` is left alone (only a real assignment is
# matched); if no active MODEL line exists, one is appended. `MODEL_FALLBACK_TO=` / `MODEL_X=`
# never match (the `=` must follow MODEL exactly). rc 0 = rewritten, rc 1 = could not.
_mf_rewrite_model() {
  local f="$1" to="$2" tmp
  [ -f "$f" ] || return 1
  tmp="$f.mf.$$"
  awk -v to="$to" '
    $0 ~ /^[[:space:]]*(export[[:space:]]+)?MODEL=/ {
      match($0, /^[[:space:]]*(export[[:space:]]+)?/)
      printf "%sMODEL=%s\n", substr($0, 1, RLENGTH), to
      done=1
      next
    }
    { print }
    END { if (!done) printf "MODEL=%s\n", to }
  ' "$f" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

# The poll-loop step. INERT unless armed AND a fallback is resolvable; scans only new
# SUPERVISOR_LOG content; on a confirmed wall, acts ONCE (switch / already-on-fallback-alert /
# pricier-refuse) then latches. Never aborts the loop (caller adds `|| true`).
model_fallback_step() {
  [ "${MODEL_FALLBACK_LATCHED:-0}" = "1" ] && return 0          # one-shot per era: already acted
  _mf_load_config
  [ "${_MF_GATE:-1}" = "1" ] || return 0                       # disarmed → inert
  local to="${_MF_TO:-opus}" cur="${MODEL:-}"
  [ -n "$to" ] || return 0                                     # no resolvable fallback → inert
  local logf="${SUPERVISOR_LOG:-${KICKOFF_DIR:-.kickoff}/supervisor.log}"
  [ -f "$logf" ] || return 0

  # scan ONLY new content since the last offset; a shrink (copytruncate rotation) resets to 0
  local size off
  size="$(wc -c < "$logf" 2>/dev/null | tr -d '[:space:]')"
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  off="${MODEL_FALLBACK_OFFSET:-0}"; case "$off" in ''|*[!0-9]*) off=0 ;; esac
  if [ "$size" -lt "$off" ]; then off=0; fi                    # rotation → rescan from the top
  if [ "$size" -le "$off" ]; then MODEL_FALLBACK_OFFSET="$size"; return 0; fi
  local new
  new="$(tail -c +$((off + 1)) "$logf" 2>/dev/null || true)"
  MODEL_FALLBACK_OFFSET="$size"                                # advance offset regardless of match
  _mf_detect "$new" || return 0

  # ── RECURRENCE GATE (findings #1/#3): the wall string is in the fresh output — but a one-off
  #    worker quote, a `cat supervisor.sh`, or a rendered design-doc shows it ONCE, whereas a real
  #    quota wall REPRINTS every failing turn. Require the wall on N SEPARATE ticks within a window
  #    before acting. The offset has already advanced past THIS content, so the next confirmation
  #    must come from genuinely NEW wall output — a single render can never self-confirm. A stale
  #    prior hit older than the window resets the count (two unrelated one-off quotes never add up).
  local now confs win
  now="$SECONDS"; case "$now" in ''|*[!0-9]*) now=0 ;; esac
  confs="${MODEL_FALLBACK_CONFIRMATIONS:-2}"; case "$confs" in ''|*[!0-9]*) confs=2 ;; esac
  [ "$confs" -lt 2 ] && confs=2
  win="${MODEL_FALLBACK_WINDOW_SECONDS:-600}"; case "$win" in ''|*[!0-9]*) win=600 ;; esac
  if [ "${MODEL_FALLBACK_HITS:-0}" -gt 0 ] && [ "$((now - ${MODEL_FALLBACK_LAST_HIT:-0}))" -le "$win" ]; then
    MODEL_FALLBACK_HITS=$((MODEL_FALLBACK_HITS + 1))
  else
    MODEL_FALLBACK_HITS=1                                      # first hit, or a stale prior hit aged out of the window
  fi
  MODEL_FALLBACK_LAST_HIT="$now"
  if [ "${MODEL_FALLBACK_HITS:-0}" -lt "$confs" ]; then
    log "model-fallback: model-limit string in fresh output — confirmation ${MODEL_FALLBACK_HITS}/${confs} (MODEL=${cur:-<unset>}); awaiting recurrence before acting (a one-off quote/render does not repeat)"
    return 0
  fi

  # ── a model-quota WALL is CONFIRMED in the fresh output (recurred across ticks) ──
  log "model-fallback: model-quota WALL CONFIRMED in fresh worker output after ${MODEL_FALLBACK_HITS} recurrences (MODEL=${cur:-<unset>}, fallback=$to)"
  if [ "${DRY_RUN:-0}" = "1" ]; then                           # detect-only
    log "DRY_RUN — would switch MODEL ${cur:-<unset>} → $to (rewrite instance.env, export, refresh, flag, alert) — or alert if already-on-fallback / pricier. Detect-only, no action."
    return 0
  fi
  local flag="${KICKOFF_DIR:-.kickoff}/model-fallback"
  local ts; ts="$(date -u +%FT%TZ 2>/dev/null || echo now)"

  # ALREADY-ON-FALLBACK: MODEL already == the fallback → a switch cannot help.
  if [ -n "$cur" ] && [ "$cur" = "$to" ]; then
    MODEL_FALLBACK_LATCHED=1
    log "model-fallback: MODEL is ALREADY the fallback ($cur) — cannot switch cheaper; alerting for manual intervention (latched, no cycle)"
    printf 'status=also-limited\nmodel=%s\ntrigger=model-quota-wall\nat=%s\n' "$cur" "$ts" > "$flag" 2>/dev/null || true
    tg_send_tokenless "⛔ Worker hit its model quota wall, but it is ALREADY on the fallback model ($cur) — I cannot switch it any cheaper. Every turn will fail until the weekly quota resets or you intervene. Options: wait for the reset, top up (/usage-credits), or repin a different model. This is NOT the usual cooking ping."
    return 0
  fi

  local rc_cur rc_to
  rc_cur="$(_mf_cost_rank "$cur")"; rc_to="$(_mf_cost_rank "$to")"

  # VALIDATE the fallback (finding #7): refuse to switch to an UNKNOWN / unrankable model family
  # (a typo'd MODEL_FALLBACK_TO). The old spend gate FAILED OPEN — an unrankable target skipped the
  # `rc_to >= 0` conjunct, so the belt would switch and the next spawn would get `--model <garbage>`
  # and fail every turn. We also cannot establish the cost direction for an unknown target. So this
  # is a hard refuse+alert+latch, mirroring the pricier branch — a bad target is a misconfig, not a
  # recovery. (The default target `opus` is always rankable; any real billable model contains a
  # rankable family substring, so a correctly-configured belt never reaches here.)
  if [ "$rc_to" -lt 0 ]; then
    MODEL_FALLBACK_LATCHED=1
    log "model-fallback: configured fallback ($to) is NOT a known model family — REFUSING to switch (a bad --model would fail every turn, and cost-direction is unknowable); alerting for a manual fix (latched)"
    printf 'status=refused-unknown\nfrom=%s\nto=%s\ntrigger=model-quota-wall\nat=%s\n' "${cur:-unknown}" "$to" "$ts" > "$flag" 2>/dev/null || true
    tg_send_tokenless "⛔ Worker hit its ${cur:-current} quota wall, but the configured fallback (MODEL_FALLBACK_TO=$to) is not a model family I recognise — switching to it would make every turn fail. I did NOT switch. Fix MODEL_FALLBACK_TO in .kickoff/instance.env (opus | sonnet | haiku). This is NOT the usual cooking ping."
    return 0
  fi

  # SPEND-DIRECTION gate: refuse to auto-switch to a PRICIER model (that is spend — a human call).
  if [ "$rc_cur" -ge 0 ] && [ "$rc_to" -ge 0 ] && [ "$rc_to" -gt "$rc_cur" ]; then
    MODEL_FALLBACK_LATCHED=1
    log "model-fallback: configured fallback ($to) is PRICIER than the current model ($cur) — REFUSING to auto-switch (would increase spend); alerting for a manual decision (latched)"
    printf 'status=refused-pricier\nfrom=%s\nto=%s\ntrigger=model-quota-wall\nat=%s\n' "$cur" "$to" "$ts" > "$flag" 2>/dev/null || true
    tg_send_tokenless "⛔ Worker hit its $cur quota wall. The configured fallback ($to) is a MORE EXPENSIVE model, so I did NOT auto-switch — increasing spend is a decision only you should make. The worker is stalled on $cur until quota resets or you repin (edit MODEL_FALLBACK_TO / MODEL in .kickoff/instance.env). This is NOT the usual cooking ping."
    return 0
  fi

  # SWITCH toward the cheaper fallback (the fable→opus recovery path).
  local ienv="${INSTANCE_ENV:-${KICKOFF_DIR:-.kickoff}/instance.env}"
  if _mf_rewrite_model "$ienv" "$to"; then
    log "model-fallback: rewrote MODEL → $to in $ienv (durable across full restarts)"
  else
    log "model-fallback: could NOT rewrite $ienv — the in-process export below still switches the live worker for this era"
  fi
  export MODEL="$to"                                           # defeat the fossilised MODEL for the next spawn
  MODEL_FALLBACK_LATCHED=1                                     # latch BEFORE refresh (refresh re-enters the loop)
  printf 'status=switched\nfrom=%s\nto=%s\ntrigger=model-quota-wall\nat=%s\n' "${cur:-unknown}" "$to" "$ts" > "$flag" 2>/dev/null || true
  tg_send_tokenless "🔻 Worker hit its ${cur:-current}-model weekly quota wall (every turn was failing). I switched it to the cheaper fallback model ($to) and refreshed the session — it is working again, but on $to, not ${cur:-its pinned model}, so reasoning quality may differ. This is a ONE-WAY switch; restoring ${cur:-the original} is a manual/cron decision once quota resets. This is NOT the usual cooking ping."
  log "model-fallback: MODEL ${cur:-<unset>} → $to; exported for the next spawn; refreshing the session to adopt it"
  refresh "model-fallback"
  return 0
}
# <<< KICKOFF-MODEL-FALLBACK-UNIT <<<

cleanup() {
  log "supervisor exiting"
  stop_session
  rm -f "$LOCKFILE"
  exit 0
}
trap cleanup INT TERM

run_preflight
# the hop-landing marker did its job (a red startup post-hop alerts inside run_preflight,
# above) — drop it here so it can never leak into the sessions this supervisor spawns.
unset KICKOFF_HOP_EXEC
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

  # v0.7 G1 slice 5: the engine-hop watch — fresh-resolve the pinned engine every tick
  # (instance.env KICKOFF_CORE_DIR re-read from the file + core.lock's commit; detection
  # only — the hop itself fires at the next session boundary). `|| true`: a probe error
  # must NEVER abort the supervisor loop (fail-toward-inaction).
  engine_hop_step || true

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

  # trigger 2.6 (v0.8): model-quota fallback. A weekly model limit leaves the supervisor,
  # session, AND bridge all ALIVE while every turn fails (liveness ≠ capability) — no belt
  # above catches it. This scans the session's captured pty output for the real limit string
  # and switches the worker to a cheaper fallback model (INSIDE this shell, so the fossilised
  # MODEL is beaten), then refreshes + alerts + latches. INERT-BY-CONSTRUCTION: no detected
  # limit ⇒ no action; on kickoff-dev (MODEL=opus, fallback opus) a healthy worker is never
  # cycled. `|| true` (G6): a probe error must NEVER abort the loop, like the belts above.
  model_fallback_step || true

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
    # v0.7 G1 slice 5: a natural session death is ALSO a session boundary — hop here
    # (the belt) even when no pull touched the flag (the flag is only the accelerator).
    engine_hop_boundary || true
    start_session
  fi

  sleep "$POLL_SECONDS"
done
