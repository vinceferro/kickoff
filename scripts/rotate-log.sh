#!/usr/bin/env bash
# rotate-log.sh — bounded, COPYTRUNCATE rotation for the supervisor's append-only log.
#
# ── WHY COPYTRUNCATE, NOT `mv` ───────────────────────────────────────────────
# The supervisor's stdout/stderr is an already-open O_APPEND fd — the launcher
# (go-autonomous.sh / start-supervisor.sh) redirects `… >>"$LOG" 2>&1`. `mv "$LOG"
# "$LOG.1"` renames the very inode that fd still points at, so the process keeps
# appending into `.log.1` while the fresh `.log` stays empty FOREVER (finding #18:
# kickoff's own supervisor.log grew to tens of MB precisely because nothing bounded
# it). COPYTRUNCATE — copy the bytes out to `.log.1`, then truncate `.log` IN PLACE
# (`: > "$LOG"`) — keeps the SAME inode/fd, so the live writer seamlessly continues
# into the now-empty `.log`. That is the whole point of this helper existing.
#
# Bounds total to ~2x the cap: past LOG_MAX_BYTES, roll ONCE to `.log.1` (overwriting
# any previous `.log.1`). Idempotent + cheap (a `wc -c` stat), so the supervisor calls
# it every poll; it rotates only when actually over the cap.
#
# ── USAGE ────────────────────────────────────────────────────────────────────
#   . "$SCRIPT_DIR/rotate-log.sh"   # source → defines rotate_log; call `rotate_log "$LOG"`
#   bash rotate-log.sh [<log>]      # standalone (one rotation; used by the selftest)
#
# CONFIG:  log path = arg $1 > $KICKOFF_SUPERVISOR_LOG > .kickoff/supervisor.log
#          cap      = $LOG_MAX_BYTES (default 10 MiB)

rotate_log() {
  local log="${1:-${KICKOFF_SUPERVISOR_LOG:-.kickoff/supervisor.log}}"
  local cap="${LOG_MAX_BYTES:-10485760}"     # 10 MiB
  [ -n "$log" ] || return 0
  [ -f "$log" ] || return 0
  local size
  size="$(wc -c <"$log" 2>/dev/null || echo 0)"
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  [ "$size" -gt "$cap" ] || return 0
  # Copy the bytes out FIRST; only truncate if the backup succeeded (never lose the log to a
  # failed copy). `cp -f` overwrites any prior `.log.1`. Then `: > "$log"` truncates IN PLACE,
  # keeping the inode the launcher's open `>>"$log"` fd is still writing through.
  if cp -f "$log" "$log.1" 2>/dev/null; then
    : > "$log"
    printf '[rotate-log] %s: %sB > %sB cap → rolled to %s.1 (copytruncate; inode preserved)\n' \
      "$log" "$size" "$cap" "$log"
  fi
  return 0
}

# Standalone (executed, not sourced) → run one rotation. When sourced, BASH_SOURCE[0] != $0,
# so only the function is defined and the caller drives it.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  rotate_log "$@"
fi
