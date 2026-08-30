#!/usr/bin/env bash
# lanes-board.sh — the LIVE board for the lane fleet: one self-refreshing page of
# "what is each lane doing", served from the same renderer the opencode `lanes_status`
# tool and the /lanes command use (scripts/lanes-snapshot.py — one source, §7 pins it).
#
#   REPO_DIR=/… bash scripts/lanes-board.sh [--tailnet]
#
# DISCIPLINE (mirrors scripts/board-serve.sh — the mission-control serve pattern):
#   · pick a FREE local port (ss -ltn pre-check, python bind-probe fallback) — binds
#     127.0.0.1 ONLY; localhost is the default and the safe default
#   · IDEMPOTENT: the port+pid are recorded in .kickoff/state/lanes-board.env and a
#     live server is REUSED — a stable URL, never a fresh process per invocation
#   · the page is plain HTML + fetch on /lanes.json (the renderer's --json, re-run
#     per request), self-refreshing every 10s — no build step, no deps
#   · phone-readable: status emoji, agent, proof badge, respawn count, relative age
#   · --tailnet maps it onto the tailnet (tailnet-only, NEVER funnel/public): read
#     `tailscale serve status` FIRST (serve is SET-not-APPEND), never bare :443,
#     confirm the mapping appeared. Without the flag tailscale is NEVER touched.
#
# FAIL-SOFT BY CONTRACT: the board is ADDITIVE. Any missing precondition (no lane
# ledger, no python3, no free port, tailscale down) is a WARN + exit 0 — a board
# hiccup must never abort its caller. Stop the board with:
#   kill "$(grep -E '^LANES_BOARD_PID=' .kickoff/state/lanes-board.env | cut -d= -f2)"
#
# Env overrides (the selftest points these at stubs — no real tailscale is touched):
#   TS_BIN (tailscale) · SS_BIN (ss) · CURL_BIN (curl) · PY_BIN (python3)
#   LANES_BOARD_PORTS (9140 9141 … 9179)  candidate local ports, first free wins
#   (9140+, NOT board-serve's 9100-9139: those belong to Mission Control's board.)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${REPO_DIR:-$(pwd)}"
REPO_DIR="$(cd "$REPO_DIR" 2>/dev/null && pwd || printf '%s' "$REPO_DIR")"
TS_BIN="${TS_BIN:-tailscale}"
SS_BIN="${SS_BIN:-ss}"
CURL_BIN="${CURL_BIN:-curl}"
PY_BIN="${PY_BIN:-python3}"
SERVER_PY="$HERE/lanes-board-server.py"
RENDERER="$HERE/lanes-snapshot.py"
TAILNET=0
for _a in "$@"; do case "$_a" in --tailnet) TAILNET=1 ;; esac; done

ok()   { printf '  \342\234\223 lanes-board: %s\n' "$*"; }  # ✓
warn() { printf '  \342\232\240 lanes-board: %s\n' "$*"; }  # ⚠ (advisory — never a non-zero exit)
info() { printf '    %s\n' "$*"; }

# ── the tailnet mapping — read `serve status` FIRST; reuse ours, never clobber ───
# (board-serve's §2, lifted near-verbatim; runs only under --tailnet)
_serve_port_for_upstream() {   # $1 = serve-status text, $2 = local port → tailnet port or nothing
  printf '%s\n' "$1" | awk -v up="http://127.0.0.1:$2" '
    /^https:\/\// { p = 443
      if (match($1, /:[0-9]+\/?$/)) { p = substr($1, RSTART + 1); sub(/\//, "", p) }
      blk = p; next }
    blk != "" {
      for (i = 1; i <= NF; i++) { t = $i; sub(/\/+$/, "", t); if (t == up) { print blk; exit } }
    }'
}
_serve_port_listed() {   # rc 0 iff that tailnet port is ALREADY mapped (SET-not-APPEND guard)
  printf '%s\n' "$1" | grep -qE "^https://[^ ]+:$2/?([[:space:]]|$)"
}

do_tailnet() {   # $1 = local port → maps + confirms; every miss is a WARN (stays local)
  local lp="$1"
  if ! command -v "$TS_BIN" >/dev/null 2>&1 && [ ! -x "$TS_BIN" ]; then
    warn "tailscale not found — the board is LOCAL-ONLY (http://127.0.0.1:$lp)"
    return 0
  fi
  _ts_st="$("$TS_BIN" status --json 2>/dev/null || true)"
  _dns="$(printf '%s' "$_ts_st" | { command -v jq >/dev/null 2>&1 && jq -r '.Self.DNSName // ""' || sed -n 's/.*"DNSName"[": ]*"\([^"]*\)".*/\1/p' ; } 2>/dev/null | head -1 | sed 's/\.$//')"
  if [ -z "$_dns" ]; then
    warn "tailscale is not up (or has no MagicDNS name) — the board is LOCAL-ONLY (http://127.0.0.1:$lp)"
    return 0
  fi
  _serve_out="$("$TS_BIN" serve status 2>/dev/null || true)"
  TP="$(_serve_port_for_upstream "$_serve_out" "$lp")"
  if [ -n "$TP" ]; then
    ok "tailnet mapping already SERVES this board (https=$TP → 127.0.0.1:$lp) — reusing, not re-mapping"
  else
    for _tp in ${LANES_BOARD_TAILNET_PORTS:-$(seq 8140 8179)}; do
      [ "$_tp" = "443" ] && continue                       # NEVER bare root — the box's front door
      _serve_port_listed "$_serve_out" "$_tp" && continue  # a listed port is TAKEN, skip it
      TP="$_tp"; break
    done
    if [ -z "${TP:-}" ]; then
      warn "no free tailnet serve port in the candidate range — the board is LOCAL-ONLY (http://127.0.0.1:$lp)"
      return 0
    fi
    if ! "$TS_BIN" serve --bg --yes --https="$TP" "http://127.0.0.1:$lp" >/dev/null 2>&1; then
      warn "tailscale serve refused the mapping (--https=$TP) — the board is LOCAL-ONLY (http://127.0.0.1:$lp)"
      return 0
    fi
    _serve_out="$("$TS_BIN" serve status 2>/dev/null || true)"
    if [ "$(_serve_port_for_upstream "$_serve_out" "$lp")" != "$TP" ]; then
      warn "the serve mapping did not appear in \`tailscale serve status\` — check it by hand"
    else
      ok "tailnet mapping SET (tailnet-only, never funnel): https=$TP → http://127.0.0.1:$lp"
    fi
  fi
  ok "lanes board is UP (tailnet-only — never public)"
  info "open:   https://$_dns:${TP:-?}/"
  return 0
}

# ── preconditions — each miss is a WARN + exit 0 ─────────────────────────────────
if [ ! -f "$SERVER_PY" ]; then
  warn "the board server is missing at $SERVER_PY — repo checkout incomplete; skipping"
  exit 0
fi
if [ ! -f "$RENDERER" ]; then
  warn "the shared renderer is missing at $RENDERER — nothing to serve; skipping"
  exit 0
fi
GRAPH="$REPO_DIR/.kickoff/graph.json"
if [ ! -f "$GRAPH" ]; then
  warn "no lane ledger at $GRAPH — no lanes have been dispatched from this repo; skipping the board"
  exit 0
fi
if ! command -v "$PY_BIN" >/dev/null 2>&1 && [ ! -x "$PY_BIN" ]; then
  warn "python3 not found — cannot run the board server; skipping"
  exit 0
fi

STATE_DIR="$REPO_DIR/.kickoff/state"
RECORD="$STATE_DIR/lanes-board.env"
SERVER_LOG="$STATE_DIR/lanes-board.log"

# ── helpers (board-serve's, kept verbatim in spirit) ─────────────────────────────
_port_free() {   # $1 = port → rc 0 iff nothing LISTENs; unknowable → OCCUPIED (never clobber)
  local p="$1"
  if command -v "$SS_BIN" >/dev/null 2>&1 || [ -x "$SS_BIN" ]; then
    "$SS_BIN" -ltn 2>/dev/null | grep -qE "[:.]$p[[:space:]]" && return 1
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$p" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
    return $?
  fi
  return 1
}

_lanes_json_ok() {  # $1 = port → rc 0 iff the board answers 200 on /lanes.json
  [ "$("$CURL_BIN" -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$1/lanes.json" 2>/dev/null)" = "200" ]
}

# ── the recorded assignment — reuse a live server, never double-serve ────────────
REC_PORT=""; REC_PID=""
if [ -f "$RECORD" ]; then
  # fixed shape, our own write — a whitelist read-back (the preflight idiom)
  eval "$(grep -E '^(LANES_BOARD_LOCAL_PORT|LANES_BOARD_PID)=[0-9]*$' "$RECORD" 2>/dev/null | sed 's/^LANES_BOARD_LOCAL_PORT=/REC_PORT=/; s/^LANES_BOARD_PID=/REC_PID=/')"
fi
if [ -n "$REC_PORT" ] && [ -n "$REC_PID" ] && kill -0 "$REC_PID" 2>/dev/null && _lanes_json_ok "$REC_PORT"; then
  ok "board already LIVE for this repo (pid $REC_PID, http://127.0.0.1:$REC_PORT) — reusing, not re-spawning"
  LOCAL_PORT="$REC_PORT"
  if [ "$TAILNET" = 1 ]; then do_tailnet "$LOCAL_PORT"; fi
  exit 0
fi

# ── pick a free local port and start the server (binds 127.0.0.1 ONLY) ───────────
LOCAL_PORT=""
for _p in ${LANES_BOARD_PORTS:-$(seq 9140 9179)}; do
  _port_free "$_p" && { LOCAL_PORT="$_p"; break; }
done
if [ -z "$LOCAL_PORT" ]; then
  warn "no free local port in the candidate range — skipping the board"
  exit 0
fi
mkdir -p "$STATE_DIR" 2>/dev/null || true
# setsid + nohup + /dev/null stdin: outlives this shell. A stdlib single-process
# server — NOT a dev server — safe to background (the board-serve rule).
setsid nohup "$PY_BIN" "$SERVER_PY" "$LOCAL_PORT" "$GRAPH" "$RENDERER" \
  </dev/null >>"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
_i=0; _up=0
while [ "$_i" -lt 20 ]; do
  _lanes_json_ok "$LOCAL_PORT" && { _up=1; break; }
  kill -0 "$SERVER_PID" 2>/dev/null || break
  sleep 0.25; _i=$((_i + 1))
done
if [ "$_up" != 1 ]; then
  warn "the board server did not answer /lanes.json on 127.0.0.1:$LOCAL_PORT (died or slow — see $SERVER_LOG); skipping"
  kill "$SERVER_PID" 2>/dev/null || true
  exit 0
fi
ok "board LIVE on http://127.0.0.1:$LOCAL_PORT (pid $SERVER_PID; binds 127.0.0.1 only)"

# ── record the assignment (stable URL on every restart) ──────────────────────────
umask 077
printf 'LANES_BOARD_LOCAL_PORT=%s\nLANES_BOARD_PID=%s\n' "$LOCAL_PORT" "$SERVER_PID" > "$RECORD" 2>/dev/null \
  || warn "could not write $RECORD — the next run may mint a fresh port (URL not stable)"

if [ "$TAILNET" = 1 ]; then
  do_tailnet "$LOCAL_PORT"
else
  ok "lanes board is UP (localhost-only — pass --tailnet to reach your phone)"
  info "open:   http://127.0.0.1:$LOCAL_PORT/"
fi
exit 0
