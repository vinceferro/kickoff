#!/usr/bin/env bash
# board-serve.sh — bring THIS repo's Mission Control board up, IDEMPOTENTLY and SAFELY (scout #4).
#
# THE GAP THIS CLOSES. mission-state.json is seeded at adopt and written every iteration — but no
# engine step ever STARTED server.py or mapped it onto the tailnet, so the operator had NO live
# board (and the secrets channel, served by the same process, was equally dark). `kickoff up` now
# calls this before launching the worker (never in --dry-run).
#
# DISCIPLINE (the mission-control SKILL's "Stand it up", verbatim — plus the share-enable
# occupancy lesson):
#   · pick a FREE local port (ss -ltn pre-check) and run server.py — binds 127.0.0.1 ONLY
#   · read `tailscale serve status` FIRST (serve is SET-not-APPEND: re-pointing a mapped port
#     silently REPLACES its handler) — pick a tailnet port that is NOT listed; NEVER bare root/443
#   · `tailscale serve --bg --yes --https=<free> http://127.0.0.1:<local>`, then curl-confirm
#     401-then-200 over the TAILNET (localhost proves nothing about the operator's phone)
#   · IDEMPOTENT: the assigned ports are recorded in .kickoff/state/mission-control/board-serve.env
#     and reused on every restart — a stable URL, never a fresh mapping per `up` (mapping-sprawl).
#   · CREDENTIAL-GUARD: the token is NEVER printed/relayed — the operator cats it themselves.
#
# FAIL-SOFT BY CONTRACT: the board is ADDITIVE. Any missing precondition (no state file, no
# server.py in the pinned core, no python3, tailscale down, no free port) is a WARN + exit 0 —
# a board hiccup must never abort the `kickoff up` worker launch.
#
#   REPO_DIR=<repo> [KICKOFF_CORE_DIR=<core>] bash scripts/board-serve.sh [--dry-run]
#
# Env overrides (the selftest points these at stubs — no real tailscale/server is ever touched):
#   TS_BIN (tailscale) · SS_BIN (ss) · CURL_BIN (curl) · PY_BIN (python3)
#   BOARD_LOCAL_PORTS  (9100 9101 … 9139)   candidate local ports, first free wins
#   BOARD_TAILNET_PORTS (8100 8101 … 8139)  candidate tailnet ports, first unlisted wins
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${REPO_DIR:-$(pwd)}"
REPO_DIR="$(cd "$REPO_DIR" 2>/dev/null && pwd || printf '%s' "$REPO_DIR")"
CORE_DIR="${KICKOFF_CORE_DIR:-$(cd "$HERE/.." && pwd)}"
TS_BIN="${TS_BIN:-tailscale}"
SS_BIN="${SS_BIN:-ss}"
CURL_BIN="${CURL_BIN:-curl}"
PY_BIN="${PY_BIN:-python3}"

DRY=0
for _a in "$@"; do case "$_a" in --dry-run) DRY=1 ;; esac; done

ok()   { printf '  \342\234\223 board: %s\n' "$*"; }   # ✓
warn() { printf '  \342\232\240 board: %s\n' "$*"; }   # ⚠ (advisory — this script NEVER exits non-zero for the launcher)
info() { printf '    %s\n' "$*"; }

STATE_DIR="$REPO_DIR/.kickoff/state/mission-control"
STATE_FILE="${MC_STATE_FILE:-$STATE_DIR/mission-state.json}"
case "$STATE_FILE" in /*) : ;; *) STATE_FILE="$REPO_DIR/$STATE_FILE" ;; esac
RECORD="$STATE_DIR/board-serve.env"
TOKEN_FILE="$STATE_DIR/.mission-token"
SERVER_PY="$CORE_DIR/mission-control/server.py"
SERVER_LOG="$STATE_DIR/board-server.log"

# ── preconditions — each miss is a WARN + exit 0 (additive; never blocks the worker) ─────────────
if [ ! -f "$STATE_FILE" ]; then
  warn "no mission-state at $STATE_FILE — nothing to serve yet (kickoff adopt/init seeds it); skipping the board"
  exit 0
fi
if [ ! -f "$SERVER_PY" ]; then
  warn "the engine has no mission-control/server.py at $SERVER_PY — skipping the board (an older/partial core; \`kickoff pull\` a full one)"
  exit 0
fi
if ! command -v "$PY_BIN" >/dev/null 2>&1 && [ ! -x "$PY_BIN" ]; then
  warn "python3 not found — cannot run the board server; skipping"
  exit 0
fi

# ── helpers ──────────────────────────────────────────────────────────────────────────────────────
# A local TCP port is FREE iff nothing LISTENs on it. ss -ltn is the SKILL's pre-check; a box
# without ss falls back to a real python bind-probe (system python3, independent of PY_BIN so a
# stubbed test server never distorts the probe). Unknowable → treat as OCCUPIED (never clobber).
_port_free() {   # $1 = port → rc 0 iff free
  local p="$1"
  if command -v "$SS_BIN" >/dev/null 2>&1 || [ -x "$SS_BIN" ]; then
    if "$SS_BIN" -ltn 2>/dev/null | grep -qE "[:.]$p[[:space:]]"; then return 1; fi
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

_healthz() {   # $1 = local port → rc 0 iff the board answers 200 on /healthz (the no-auth route)
  [ "$("$CURL_BIN" -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$1/healthz" 2>/dev/null)" = "200" ]
}

# The tailnet port (block header) whose handler already proxies OUR local upstream — EXACT match
# on the http://127.0.0.1:<port> token (the share-enable prefix-collision lesson: a substring
# check green-lights the very SET-not-APPEND clobber the pre-check exists to refuse).
_serve_port_for_upstream() {   # $1 = serve-status text, $2 = local port → echoes the tailnet port, or nothing
  printf '%s\n' "$1" | awk -v up="http://127.0.0.1:$2" '
    /^https:\/\// { p = 443
      if (match($1, /:[0-9]+\/?$/)) { p = substr($1, RSTART + 1); sub(/\//, "", p) }
      blk = p; next }
    blk != "" {
      for (i = 1; i <= NF; i++) { t = $i; sub(/\/+$/, "", t); if (t == up) { print blk; exit } }
    }'
}
_serve_port_listed() {   # $1 = serve-status text, $2 = tailnet port → rc 0 iff that port is ALREADY mapped
  printf '%s\n' "$1" | grep -qE "^https://[^ ]+:$2/?([[:space:]]|$)"
}

# ── the recorded assignment (stable URL across restarts — never mint per `up`) ───────────────────
REC_LOCAL=""; REC_TAILNET=""; REC_PID=""
if [ -f "$RECORD" ]; then
  # fixed shape, our own write — a subshell source with a whitelist read-back (the preflight idiom)
  eval "$(grep -E '^(BOARD_LOCAL_PORT|BOARD_TAILNET_PORT|BOARD_SERVER_PID)=[0-9]*$' "$RECORD" 2>/dev/null | sed 's/^BOARD_LOCAL_PORT=/REC_LOCAL=/; s/^BOARD_TAILNET_PORT=/REC_TAILNET=/; s/^BOARD_SERVER_PID=/REC_PID=/')"
fi

# ── 1. the LOCAL server — reuse a live one, else pick a free port and start it ───────────────────
LOCAL_PORT=""
SERVER_PID=""
if [ -n "$REC_LOCAL" ] && [ -n "$REC_PID" ] && kill -0 "$REC_PID" 2>/dev/null && _healthz "$REC_LOCAL"; then
  LOCAL_PORT="$REC_LOCAL"; SERVER_PID="$REC_PID"
  ok "server already LIVE for this repo (pid $SERVER_PID, http://127.0.0.1:$LOCAL_PORT) — reusing, not re-spawning"
else
  _candidates="${BOARD_LOCAL_PORTS:-}"
  if [ -z "$_candidates" ]; then
    _candidates="${REC_LOCAL:+$REC_LOCAL }$(seq 9100 9139 | tr '\n' ' ')"
  fi
  for _p in $_candidates; do
    _port_free "$_p" && { LOCAL_PORT="$_p"; break; }
  done
  if [ -z "$LOCAL_PORT" ]; then
    warn "no free local port in the candidate range — skipping the board (the worker launch continues)"
    exit 0
  fi
  if [ "$DRY" = 1 ]; then
    ok "DRY-RUN — would start server.py on the free local port $LOCAL_PORT (binds 127.0.0.1 only); starting NOTHING"
  else
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    # setsid + nohup + /dev/null stdin: the server must outlive this shell AND the `kickoff up`
    # foreground exec. A stdlib single-process server — NOT a dev server — safe to background.
    setsid nohup env MC_STATE_FILE="$STATE_FILE" "$PY_BIN" "$SERVER_PY" "$LOCAL_PORT" </dev/null >>"$SERVER_LOG" 2>&1 &
    SERVER_PID=$!
    _i=0; _up=0
    while [ "$_i" -lt 20 ]; do
      _healthz "$LOCAL_PORT" && { _up=1; break; }
      kill -0 "$SERVER_PID" 2>/dev/null || break
      sleep 0.25; _i=$((_i + 1))
    done
    if [ "$_up" != 1 ]; then
      warn "server.py did not answer /healthz on 127.0.0.1:$LOCAL_PORT (died or slow — see $SERVER_LOG); skipping the board"
      kill "$SERVER_PID" 2>/dev/null || true
      exit 0
    fi
    ok "server LIVE on http://127.0.0.1:$LOCAL_PORT (pid $SERVER_PID; binds 127.0.0.1 only)"
  fi
fi

# ── 2. the TAILNET mapping — read `serve status` FIRST; reuse ours, never clobber theirs ─────────
if ! command -v "$TS_BIN" >/dev/null 2>&1 && [ ! -x "$TS_BIN" ]; then
  warn "tailscale not found — the board is LOCAL-ONLY (http://127.0.0.1:${LOCAL_PORT:-<port>}); install tailscale for the phone-reachable URL"
  exit 0
fi
_ts_st="$("$TS_BIN" status --json 2>/dev/null || true)"
_dns="$(printf '%s' "$_ts_st" | { command -v jq >/dev/null 2>&1 && jq -r '.Self.DNSName // ""' || sed -n 's/.*"DNSName"[": ]*"\([^"]*\)".*/\1/p' ; } 2>/dev/null | head -1 | sed 's/\.$//')"
if [ -z "$_dns" ]; then
  warn "tailscale is not up (or has no MagicDNS name) — the board is LOCAL-ONLY for now; \`tailscale up\`, then re-run \`kickoff up\`"
  exit 0
fi

_serve_out="$("$TS_BIN" serve status 2>/dev/null || true)"
TAILNET_PORT="$(_serve_port_for_upstream "$_serve_out" "$LOCAL_PORT")"
if [ -n "$TAILNET_PORT" ]; then
  ok "tailnet mapping already SERVES this board (https=$TAILNET_PORT → 127.0.0.1:$LOCAL_PORT) — reusing, not re-mapping"
else
  _tp_candidates="${BOARD_TAILNET_PORTS:-}"
  if [ -z "$_tp_candidates" ]; then
    _tp_candidates="${REC_TAILNET:+$REC_TAILNET }$(seq 8100 8139 | tr '\n' ' ')"
  fi
  for _tp in $_tp_candidates; do
    [ "$_tp" = "443" ] && continue                       # NEVER bare root — :443 is the box's front door
    _serve_port_listed "$_serve_out" "$_tp" && continue  # SET-not-APPEND: a listed port is TAKEN, skip it
    TAILNET_PORT="$_tp"; break
  done
  if [ -z "$TAILNET_PORT" ]; then
    warn "no free tailnet serve port in the candidate range — the board is LOCAL-ONLY (http://127.0.0.1:$LOCAL_PORT)"
    exit 0
  fi
  if [ "$DRY" = 1 ]; then
    ok "DRY-RUN — would map: tailscale serve --bg --yes --https=$TAILNET_PORT http://127.0.0.1:$LOCAL_PORT; mapping NOTHING"
    exit 0
  fi
  if ! "$TS_BIN" serve --bg --yes --https="$TAILNET_PORT" "http://127.0.0.1:$LOCAL_PORT" >/dev/null 2>&1; then
    warn "tailscale serve refused the mapping (--https=$TAILNET_PORT) — the board is LOCAL-ONLY (http://127.0.0.1:$LOCAL_PORT)"
    exit 0
  fi
  # confirm the mapping actually EXISTS (a skipped/failed serve fails SILENTLY otherwise)
  _serve_out="$("$TS_BIN" serve status 2>/dev/null || true)"
  if [ "$(_serve_port_for_upstream "$_serve_out" "$LOCAL_PORT")" != "$TAILNET_PORT" ]; then
    warn "the serve mapping did not appear in \`tailscale serve status\` — the board may be LOCAL-ONLY; check \`tailscale serve status\` by hand"
  else
    ok "tailnet mapping SET (tailnet-only, never funnel): https=$TAILNET_PORT → http://127.0.0.1:$LOCAL_PORT"
  fi
fi

[ "$DRY" = 1 ] && exit 0

# ── 3. record the assignment (stable URL on every restart) ───────────────────────────────────────
mkdir -p "$STATE_DIR" 2>/dev/null || true
umask 077
printf 'BOARD_LOCAL_PORT=%s\nBOARD_TAILNET_PORT=%s\nBOARD_SERVER_PID=%s\n' \
  "$LOCAL_PORT" "$TAILNET_PORT" "${SERVER_PID:-$REC_PID}" > "$RECORD" 2>/dev/null \
  || warn "could not write $RECORD — the next \`kickoff up\` may mint fresh ports (URL not stable)"

# ── 4. confirm over the TAILNET (401 no-auth, then 200 with the token) — the SKILL's step 3 ──────
# The token is PIPED straight into curl and NEVER printed/echoed (credential-guard). A confirm
# failure is a WARN — the operator's device is the final gate, not this box's curl.
BASE="https://$_dns:$TAILNET_PORT"
_c1="$("$CURL_BIN" -s -o /dev/null -w '%{http_code}' "$BASE/" 2>/dev/null || true)"
_c2=""
if [ -f "$TOKEN_FILE" ]; then
  # -K - reads the auth header from STDIN (fed by the bash-builtin printf), so the token never lands
  # in curl's argv (/proc/<pid>/cmdline) the way -H "Bearer $(cat …)" would — matching the note above.
  _c2="$(printf 'header = "Authorization: Bearer %s"\n' "$(cat "$TOKEN_FILE")" \
        | "$CURL_BIN" -s -o /dev/null -w '%{http_code}' -K - "$BASE/" 2>/dev/null || true)"
fi
if [ "$_c1" = "401" ] && [ "$_c2" = "200" ]; then
  ok "tailnet confirm PASSED (401 unauthenticated, 200 with the token)"
else
  warn "tailnet confirm inconclusive (no-auth=$_c1 token=${_c2:-<no token file yet>}) — the mapping is set; verify from your device"
fi

# ── 5. the handoff — URL only; the operator fetches the token THEMSELVES ─────────────────────────
ok "Mission Control board is UP (tailnet-only — never public)"
info "open:   $BASE/"
info "token:  run  cat $TOKEN_FILE  in your terminal/SSH and open the URL once as ?token=<it>"
info "        (stored client-side after that; the token is never printed or sent over any channel)"
exit 0
