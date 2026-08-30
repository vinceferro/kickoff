#!/usr/bin/env bash
# go-autonomous.sh — flip the headless supervisor's worker to AUTONOMOUS (no prompts).
#
# The supervisor's worker runs in --permission-mode default by default, which RELAYS
# each gated action to the operator's channel as an Allow/Deny. That isn't truly
# autonomous. This script restarts the worker in --permission-mode auto AND at --effort
# max (the operator's "ultracode": deepest reasoning + the Workflow/multi-agent posture):
# reversible work then runs with ZERO prompts; only genuine spend/destruction is stopped
# (the worker asks in prose + a one-tap, never a permission popup).
#
# Why this lives at the TERMINAL (and can't be a chat command): auto-mode is a
# self-executing worker, so arming it must be a deliberate, local trust-grant — a
# channel message (which could be a prompt-injection) must never be able to flip it.
#
# Safe by construction: targets ONLY the supervisor's own pidfile (never pkill /
# never a name pattern), and WAITS for the old worker to fully die before the new one
# connects — a Telegram bot allows just one listener per token, so this avoids a
# two-worker collision.
#
#   bash scripts/go-autonomous.sh
#   REPO_DIR=~/my-project bash scripts/go-autonomous.sh   # a different kickoff repo
#
# To go back to relay-mode (prompts to your phone), stop this supervisor and start
# the default one:  kill -TERM "$(cat .kickoff/supervisor.lock)"; bash scripts/start-supervisor.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$HERE/.." && pwd)}"
KICKOFF_DIR="${KICKOFF_DIR:-$REPO_DIR/.kickoff}"
LOCK="${LOCKFILE:-$KICKOFF_DIR/supervisor.lock}"
LOG="$KICKOFF_DIR/supervisor.log"

echo "▶ switching the headless worker to AUTONOMOUS (auto) mode"
echo "    repo: $REPO_DIR"
echo

# 1) stop any running supervisor — its SIGTERM handler group-kills its worker + frees the bot
if [ -f "$LOCK" ]; then
  pid="$(cat "$LOCK" 2>/dev/null || true)"
  if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
    echo "  stopping supervisor pid=$pid (it reaps its own worker)…"
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    if kill -0 "$pid" 2>/dev/null; then
      echo "  ✗ supervisor pid=$pid did not exit within 20s — ABORTING."
      echo "    (won't start a 2nd worker while the 1st may still hold the bot.)"
      exit 1
    fi
    echo "  ✓ supervisor stopped, old worker reaped, bot released"
  else
    echo "  (no live supervisor on the lock — nothing to stop)"
  fi
else
  echo "  (no lockfile — nothing to stop)"
fi

# 2) start fresh, DETACHED, autonomous (survives this terminal closing)
mkdir -p "$KICKOFF_DIR"

# Bound the append-only supervisor.log so a long-lived worker can't fill the disk (finding #18
# — kickoff's own log reached tens of MB). Use the SHARED rotator (copytruncate, NOT mv): a
# pre-launch mv would be harmless here, but the SAME helper runs IN the supervisor's poll loop
# where the stdout fd is already open — there an mv would orphan the log into .log.1. One helper,
# one discipline. Override the cap via LOG_MAX_BYTES.
LOG_MAX_BYTES="${LOG_MAX_BYTES:-10485760}"   # 10 MiB
if [ -f "$HERE/rotate-log.sh" ]; then . "$HERE/rotate-log.sh"; else rotate_log() { :; }; fi
rotate_log "$LOG"

echo "  starting the autonomous supervisor (detached)…"
# Pass the log path + cap so the supervisor's IN-LOOP rotation targets the SAME file with the
# SAME cap — the copytruncate keeps this `>>"$LOG"` fd writing into the rotated-in-place file.
nohup env PERMISSION_MODE=auto EFFORT="${EFFORT:-max}" MODEL="${MODEL:-}" REPO_DIR="$REPO_DIR" \
  KICKOFF_SUPERVISOR_LOG="$LOG" LOG_MAX_BYTES="$LOG_MAX_BYTES" \
  bash "$HERE/supervisor.sh" >>"$LOG" 2>&1 &
disown || true
sleep 3

# 3) confirm it came up
newpid="$(cat "$LOCK" 2>/dev/null || true)"
if [ -n "${newpid:-}" ] && kill -0 "$newpid" 2>/dev/null; then
  echo "  ✓ autonomous supervisor running (pid=$newpid), log: $LOG"
else
  echo "  ⚠ supervisor not confirmed yet — check the log: tail -n 40 $LOG"
fi

echo
echo "✓ Done. The autonomous worker is re-grounding now and will ANNOUNCE on its"
echo "  channel in a few seconds. From then on: no permission prompts for normal work."
