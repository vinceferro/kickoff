#!/usr/bin/env bash
# lane-status.sh — one line per org: what is each worker ACTUALLY doing right now.
#
#   scripts/lane-status.sh              # every org under $HOME with .kickoff/instance.env
#   scripts/lane-status.sh ~/catchup    # just these orgs
#
# THE BUG THIS EXISTS FOR (2026-08-24): "how is it going?" was answered from memory or
# not at all. A coordinator must answer from STATE — the same way it must never report
# done without running a proof. This is that proof, for progress instead of correctness.
#
# Engine parity (the dual-engine house rule): both engines answer through this one tool.
#   · opencode — serve API on the org's bridge port (/session, message history)
#   · claude   — newest transcript JSONL under ~/.claude/projects/<munged-cwd>/ +
#                liveness of the session-run.sh worker
# An engine that cannot answer prints UNKNOWN + why. It never fabricates.
#
# Output columns (TSV):
#   ORG  ENGINE  STATE  LAST_ACTIVITY_AGE  LAST_MESSAGE_SNIPPET
# STATE ∈ {busy, idle, stalled(retries), down, unknown}

set -euo pipefail

NOW=$(date +%s)
SNIPPET_LEN=${LANE_STATUS_SNIPPET:-90}
RETRY_WINDOW_MIN=${LANE_STATUS_RETRY_WINDOW:-30}   # retries within window → stalled

snippet() { python3 -c "import sys; t=sys.stdin.read().replace(chr(10),' ').strip(); print(t[:$SNIPPET_LEN] + ('…' if len(t)>$SNIPPET_LEN else ''))"; }

org_engine() {  # $1=org dir → engine name on stdout
  local f="$1/.kickoff/instance.env"
  [ -f "$f" ] || { echo "none"; return; }
  local raw
  raw=$(grep -E '^(export )?WORKER_ENGINE=' "$f" 2>/dev/null | tail -1) || raw=""
  case "$raw" in
    '') echo "unknown"; return ;;
  esac
  raw=${raw#*=}
  # handle both literal ("opencode") and default-expansion ("${WORKER_ENGINE:-opencode}")
  case "$raw" in
    *'${'*) raw=$(printf '%s' "$raw" | sed -n 's/.*:-\([^}]*\)}.*/\1/p') ;;
  esac
  raw=${raw%\"}; raw=${raw#\"}; raw=${raw%\'}; raw=${raw#\'}
  [ -n "$raw" ] && echo "$raw" || echo "unknown"
}

age_human() {  # $1=epoch seconds
  local s=$(( NOW - $1 ))
  [ "$s" -lt 0 ] && s=0
  if   [ "$s" -lt 90 ];     then echo "${s}s"
  elif [ "$s" -lt 5400 ];   then echo "$((s/60))m"
  elif [ "$s" -lt 172800 ]; then echo "$((s/3600))h"
  else echo "$((s/86400))d"; fi
}

status_opencode() {  # $1=org dir (org name already printed by caller)
  local dir="$1" port pid json sid msgs logf
  port=$(cat "$dir/.kickoff/opencode-bridge.port" 2>/dev/null || true)
  case "$port" in ''|*[!0-9]*) printf 'opencode\tdown\tn/a\tserve port missing\n'; return ;; esac
  pid=$(ss -tlnp 2>/dev/null | grep ":$port " | grep -oE 'pid=[0-9]+' | head -1 || true)
  pid=${pid##pid=}
  if [ -z "$pid" ]; then printf 'opencode\tdown\tn/a\tserve not listening\n'; return; fi

  json=$(curl -s --max-time 4 "http://127.0.0.1:$port/session" 2>/dev/null || true)
  [ -z "$json" ] && { printf 'opencode\tunknown\tn/a\tserve unreachable\n'; return; }

  sid=$(echo "$json" | jq -r '[.[] | select(.time.updated)] | sort_by(.time.updated) | reverse | .[0].id // empty' 2>/dev/null || true)
  if [ -z "$sid" ]; then printf 'opencode\tidle\tn/a\tno sessions yet\n'; return; fi

  local last_epoch last_role last_text state=idle retries
  msgs=$(curl -s --max-time 6 "http://127.0.0.1:$port/session/$sid/message" 2>/dev/null || true)
  # newest message WITH text wins for display — an in-flight turn (step-start/reasoning
  # only) would otherwise blank the snippet exactly when someone is watching it work
  last_role=$(echo "$msgs"  | jq -r 'sort_by(.info.time.created) | reverse | map(select(([.parts[]? | select(.type=="text") | .text] | join("")) != "")) | first | .info.role // (sort_by(.info.time.created) | last | .info.role // empty)' 2>/dev/null || true)
  last_epoch=$(echo "$msgs" | jq -r 'sort_by(.info.time.created) | reverse | map(select(([.parts[]? | select(.type=="text") | .text] | join("")) != "")) | first | .info.time.created // (sort_by(.info.time.created) | last | .info.time.created // empty)' 2>/dev/null | cut -c1-13 || true)
  last_text=$(echo "$msgs"  | jq -r 'sort_by(.info.time.created) | reverse | map(select(([.parts[]? | select(.type=="text") | .text] | join("")) != "")) | first | [.parts[]? | select(.type=="text") | .text] | join(" ")' 2>/dev/null | snippet)

  if [ -z "$last_epoch" ]; then
    printf 'opencode\tidle\tn/a\tno visible sessions\n'; return
  fi

  logf=$(ls -t "$HOME/.kickoff/channels/telegram-$(basename "$dir")"/logs/bot-*.log 2>/dev/null | head -1 || true)
  if [ -n "$logf" ]; then
    if tail -40 "$logf" | grep -q "Marked attached session busy" \
       && ! tail -40 "$logf" | tac | grep -q "Marked attached session idle"; then
      state=busy
    fi
    retries=$(tail -200 "$logf" | grep -c "Session retry" || true)
    if [ "${retries:-0}" -ge 2 ] && find "$logf" -mmin -"$RETRY_WINDOW_MIN" 2>/dev/null | grep -q .; then
      state=stalled
    fi
  fi
  printf 'opencode\t%s\t%s ago\t%s%s\n' "$state" "$(age_human "$last_epoch")" "${last_role:+[$last_role] }" "${last_text:-(in-flight, no text yet)}"
}

status_claude() {  # $1=org dir
  local dir="$1" munged newest t_epoch role text worker_alive age_s state=idle
  worker_alive=$(pgrep -fc "session-run\.sh.*$(basename "$dir")" 2>/dev/null || true)
  worker_alive=${worker_alive:-0}
  munged=$(echo "$dir" | sed 's|/|-|g; s|^-||')
  newest=$(ls -t "$HOME/.claude/projects/$munged/"*.jsonl 2>/dev/null | head -1 || true)
  if [ -z "$newest" ]; then
    if [ "$worker_alive" -gt 0 ]; then printf 'claude\tunknown\tn/a\tworker alive, no transcript yet\n'
    else printf 'claude\tdown\tn/a\tworker not running\n'; fi
    return
  fi
  t_epoch=$(stat -c %Y "$newest" 2>/dev/null || echo "$NOW")
  role=$(tail -1 "$newest" 2>/dev/null | jq -r '.message.role // .type // "?"' 2>/dev/null || echo "?")
  text=$(tail -1 "$newest" 2>/dev/null | jq -r 'if (.message.content|type)=="array" then [.message.content[]? | select(.type=="text") | .text] | join(" ") else (.message.content // "") end' 2>/dev/null | snippet)
  age_s=$(( NOW - t_epoch )); [ "$age_s" -lt 0 ] && age_s=0
  [ "$age_s" -lt 180 ]  && [ "$role" != "user" ] && state=busy
  [ "$age_s" -gt 1800 ] && [ "$worker_alive" -gt 0 ] && state=stalled
  [ "$worker_alive" = "0" ] && state=down
  printf 'claude\t%s\t%s ago\t[%s] %s\n' "$state" "$(age_human "$t_epoch")" "$role" "${text:-no text}"
}

emit() {  # $1=org dir → full line on stdout
  local d="${1%/}" eng
  eng=$(org_engine "$d")
  case "$eng" in
    opencode) printf '%s\t' "$(basename "$d")"; status_opencode "$d" ;;
    claude)   printf '%s\t' "$(basename "$d")"; status_claude "$d" ;;
    none)     : ;;                                   # not an org instance; skip silently
    *)        printf '%s\tunknown\tn/a\tn/a\tengine unrecognized (%s)\n' "$(basename "$d")" "$eng" ;;
  esac
}

if [ $# -gt 0 ]; then
  for d in "$@"; do emit "$d"; done
else
  shopt -s nullglob
  for d in "$HOME"/*/; do [ -d "${d}.kickoff" ] && emit "$d"; done
fi
