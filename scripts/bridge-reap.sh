#!/usr/bin/env bash
# bridge-reap.sh — reap-on-startup of a VERIFIED-stale holder of THIS project's Telegram channel.
#
# WHY (2026-07-11, the bridge-murder root cause — .kickoff/TELEGRAM-DURABLE-FIX-2026-07-11.md):
# Telegram allows exactly ONE getUpdates consumer per bot token. The official plugin's bridge
# SIGTERMs whatever pid $TELEGRAM_STATE_DIR/bot.pid names at ITS boot (the boot-time takeover,
# official server.ts L61-68) and then writes its own pid (L69) — but claude NEVER respawns a
# `--channels` bridge that later loses that war. So a stale consumer left holding the slot (an
# orphan from a prior core migration, a nested `claude -p` that inherited the worker's env and
# took the slot over) leaves the NEXT worker session DEAF: it reads messages into the void and
# never replies. Reaping the verified-stale holder BEFORE our claude spawns means the fresh
# bridge boots into a clean slot — and the stale consumer is permanently gone (a killed poller
# is never respawned by its own dead session either).
#
# HOW IT'S WIRED: session-run.sh sources this file (bash -n gated; absent/broken → a no-op
# stub — the auth-heal.sh discipline) and calls `reap_stale_bridge` exactly once per spawn:
# inside the pty-wrapped inner pass, after announce_restart, BEFORE `exec claude`.
# session-run.sh is fresh-read on every session spawn, so this takes effect at the next
# worker refresh with NO supervisor restart.
#
# SAFETY (this box runs SIBLING projects' near-identical bridges — never touch theirs):
#   FAIL TOWARD NOT KILLING. A live bot.pid holder is killed ONLY after ALL of:
#     1. /proc/<pid>/cmdline matches the bridge signature class (the same classes as
#        supervisor.sh's bridge_present): *bun*telegram* / *bun*server.ts* / *telegram*server.ts*
#     2. /proc/<pid>/environ (readable ⇒ same uid; unreadable ⇒ AMBIGUOUS ⇒ no kill) carries
#        TELEGRAM_STATE_DIR=<exactly OUR state dir> (raw and pwd -P-resolved forms compared,
#        fixed-string — a DIFFERENT project's bridge can never match)
#     3. an ancestry walk proves it is NOT inside our own launch tree (neither our pid nor our
#        parent appears in its PPid chain, and it is not our own ancestor) — an ambiguous walk
#        (a /proc entry vanishing mid-read) counts as related ⇒ no kill
#   and then it is the EXACT pid only: kill -TERM, ≤5s grace, then kill -KILL. NEVER a process
#   group (the stale group may contain an operator's interactive session; killing the single
#   poller frees the getUpdates slot) and NEVER a name/pattern kill (the sibling bridges).
#   Every decision is logged loudly. Any TOCTOU vanishing (/proc gone mid-check, bot.pid
#   removed by a clean shutdown) degrades to "gone — nothing to reap".
#
#   A DEAD or corrupt bot.pid needs NO action: the fresh bridge's own boot path parseInt-fails
#   or kill(pid,0)-throws into its catch and simply overwrites the file (server.ts L61-69) —
#   we log it and leave the file alone.
#
# KNOB: KICKOFF_BRIDGE_REAP=0 disables (default ON). A plain env var on purpose — deliberately
# NOT an instance.env whitelist var, so the frozen cross-file whitelist (session-run.sh /
# preflight.sh / kickoff) stays untouched.
#
# USAGE
#   . scripts/bridge-reap.sh     # source → defines reap_stale_bridge (the session-run.sh path)

# ── the one public entry point ────────────────────────────────────────────────
reap_stale_bridge() {
  # Whole body in a SUBSHELL + `|| true` (the proven auth-heal.sh pattern): session-run runs
  # `set -euo pipefail`, and a set -u unbound-variable error kills the calling shell even
  # through `fn || true` — but a subshell's death is only a non-zero status here. No bug
  # below can abort the wrapper and cost the worker its spawn.
  ( _br_main ) || true
  return 0
}

# ── internals (everything namespaced _br_ to stay out of the wrapper's way) ───

_br_log() { printf '[bridge-reap %s] %s\n' "$(date -u +%H:%M:%S 2>/dev/null || echo now)" "$*"; }

# the same signature CLASS as supervisor.sh's bridge_present — keep the two in sync
_br_cmd_matches() {
  case "$1" in
    *bun*telegram*|*bun*server.ts*|*telegram*server.ts*) return 0 ;;
    *) return 1 ;;
  esac
}

# prints the numeric parent pid of $1, or nothing when unreadable/vanished/non-numeric
_br_ppid_of() {
  local pp
  pp="$(awk '/^PPid:/{print $2; exit}' "/proc/$1/status" 2>/dev/null || true)"
  case "$pp" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$pp"
}

# Is candidate $1 related to OUR launch tree? rc 0 = related-or-AMBIGUOUS (DO NOT KILL),
# rc 1 = provably unrelated. Two bounded PPid-chain walks via /proc/<p>/status:
#   (a) up from the candidate — if $$ or $PPID appears, it descends from our launch tree;
#   (b) up from us — if the candidate appears, it is our own ancestor (killing it kills us).
_br_related_to_us() {
  local cand="$1" p pp guard
  p="$cand"; guard=0
  while [ "$p" -gt 1 ] 2>/dev/null && [ "$guard" -lt 64 ]; do
    guard=$((guard + 1))
    if [ "$p" = "$$" ] || [ "$p" = "$PPID" ]; then return 0; fi
    pp="$(_br_ppid_of "$p" || true)"
    [ -n "$pp" ] || return 0     # chain unreadable mid-walk → AMBIGUOUS → treat as related (no kill)
    p="$pp"
  done
  p="$$"; guard=0
  while [ "$p" -gt 1 ] 2>/dev/null && [ "$guard" -lt 64 ]; do
    guard=$((guard + 1))
    [ "$p" = "$cand" ] && return 0
    pp="$(_br_ppid_of "$p" || true)"
    [ -n "$pp" ] || return 1     # a hole in OUR OWN chain just ends the walk (candidate ≠ any seen ancestor)
    p="$pp"
  done
  return 1
}

_br_main() {
  if [ "${KICKOFF_BRIDGE_REAP:-1}" = "0" ]; then
    _br_log "disabled (KICKOFF_BRIDGE_REAP=0) — no reap"
    return 0
  fi
  local tsd="${TELEGRAM_STATE_DIR:-}" trimmed
  trimmed="${tsd//[[:space:]]/}"
  if [ -z "$trimmed" ]; then
    # session-run.sh fail-louds on this long before we run; sourced anywhere else it is a clean no-op
    _br_log "TELEGRAM_STATE_DIR unset/blank — nothing to check"
    return 0
  fi
  local pidfile="$tsd/bot.pid" pid=""
  if [ ! -f "$pidfile" ]; then
    _br_log "no bot.pid ($pidfile) — channel slot is clean, nothing to reap"
    return 0
  fi
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  pid="${pid//[[:space:]]/}"
  case "$pid" in
    ''|*[!0-9]*)
      _br_log "bot.pid is corrupt (non-numeric: '${pid:0:32}') — HARMLESS (the fresh bridge's boot overwrites it); NO action"
      return 0 ;;
  esac
  if [ "$pid" -le 1 ]; then
    _br_log "bot.pid names pid $pid (<=1) — nonsense value, HARMLESS; NO action"
    return 0
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    if [ -d "/proc/$pid" ]; then
      _br_log "bot.pid names live pid $pid we cannot signal (EPERM — different uid) — NOT ours to judge, NOT killing"
    else
      _br_log "stale bot.pid names DEAD pid $pid — nothing to reap (the fresh bridge will replace the file)"
    fi
    return 0
  fi
  # ── live holder → POSITIVE identity verification; ALL must pass or DO NOT KILL ──
  # (1) argv carries the bridge signature
  local cmdline=""
  cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
  if [ -z "${cmdline//[[:space:]]/}" ]; then
    _br_log "pid $pid: /proc cmdline unreadable/empty (vanished mid-check, or a zombie) — AMBIGUOUS, NOT killing"
    return 0
  fi
  if ! _br_cmd_matches "$cmdline"; then
    _br_log "pid $pid argv is NOT a telegram-bridge signature ('${cmdline:0:100}') — bot.pid likely recycled to an unrelated process, NOT killing"
    return 0
  fi
  # (2) its environment binds it to OUR state dir (not a sibling project's bridge)
  if [ ! -r "/proc/$pid/environ" ]; then
    _br_log "pid $pid: /proc environ unreadable (different uid or vanished) — AMBIGUOUS, NOT killing"
    return 0
  fi
  local env_tsd=""
  env_tsd="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -m1 '^TELEGRAM_STATE_DIR=' || true)"
  env_tsd="${env_tsd#TELEGRAM_STATE_DIR=}"
  if [ -z "$env_tsd" ]; then
    _br_log "pid $pid: no TELEGRAM_STATE_DIR in its environment — cannot prove it holds OUR channel, NOT killing"
    return 0
  fi
  local ours_resolved="" theirs_resolved="" match=0
  ours_resolved="$(cd "$tsd" 2>/dev/null && pwd -P || true)"
  theirs_resolved="$(cd "$env_tsd" 2>/dev/null && pwd -P || true)"
  [ "$env_tsd" = "$tsd" ] && match=1
  [ -n "$ours_resolved" ] && [ "$env_tsd" = "$ours_resolved" ] && match=1
  [ -n "$ours_resolved" ] && [ -n "$theirs_resolved" ] && [ "$theirs_resolved" = "$ours_resolved" ] && match=1
  if [ "$match" != "1" ]; then
    _br_log "pid $pid holds a DIFFERENT channel (its TELEGRAM_STATE_DIR='$env_tsd', ours='$tsd') — another project's bridge, NOT killing"
    return 0
  fi
  # (3) never kill inside our own launch tree (pre-exec our tree has no bridge, but check anyway)
  if _br_related_to_us "$pid"; then
    _br_log "pid $pid is inside our own launch tree (or its ancestry is ambiguous) — NOT killing"
    return 0
  fi
  # ── verified: a live bridge-signature process holding OUR state dir, outside our tree —
  # the stale consumer that would leave the fresh worker deaf. Reap the EXACT pid only. ──
  _br_log "REAPING verified-stale channel holder: pid=$pid ('${cmdline:0:100}') holds TELEGRAM_STATE_DIR=$tsd — kill -TERM $pid (exact pid; NEVER a group/pattern kill)"
  kill -TERM "$pid" 2>/dev/null || true
  local i
  for i in 1 2 3 4 5; do
    if ! kill -0 "$pid" 2>/dev/null; then
      _br_log "stale holder pid=$pid exited after TERM (~${i}s) — getUpdates slot is FREE for the fresh bridge"
      return 0
    fi
    sleep 1
  done
  _br_log "stale holder pid=$pid survived TERM for 5s — kill -KILL $pid (exact pid)"
  kill -KILL "$pid" 2>/dev/null || true
  if kill -0 "$pid" 2>/dev/null; then
    _br_log "pid=$pid STILL alive after KILL — leaving it (the fresh bridge's boot takeover is the last resort); channel may stay contended"
  else
    _br_log "stale holder pid=$pid reaped — getUpdates slot is FREE for the fresh bridge"
  fi
  return 0
}
