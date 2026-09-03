#!/usr/bin/env bash
# board-serve-selftest.sh — the auto-served Mission Control board: free-port pick, no clobber,
# idempotent reuse, fail-soft, dry-run-starts-NOTHING, token never printed (scout #4).
#
#   bash scripts/board-serve-selftest.sh
#
# HERMETIC: tailscale / ss / curl / the server's python are ALL stubs on env-var seams (TS_BIN /
# SS_BIN / CURL_BIN / PY_BIN — the share-enable.sh pattern), so NO real tailscale is ever mutated
# and NO real server is left running (stub "servers" are sleep processes, reaped by the EXIT trap).
#
# RED-FIRST: the §5 integration lanes (a non-dry `kickoff up` brings the board up; `--dry-run`
# starts NOTHING) were run against the pre-slice cmd_up and observed RED (no board-serve call
# existed), then GREEN. The unit lanes pin the discipline the mission-control SKILL mandates:
# ss pre-check → explicit free tailnet port (serve status read FIRST, 443 never) → set → confirm.
#
# Deps: bash + coreutils + git-free. Exits non-zero on any failed assertion.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BS="$REPO/scripts/board-serve.sh"

unset REPO_DIR KICKOFF_CORE_DIR MC_STATE_FILE MC_TRACKER_FILE MEMORY_DB MEMORY_HOOK_LOG MEMORY_DIR \
      MEMORY_INDEX TELEGRAM_STATE_DIR CHANNEL_SPEC REGROUND_PROMPT PERMISSION_MODE EFFORT MODEL \
      MAX_CONCURRENT_AGENTS DEPLOY_BRANCH CADENCE INSTANCE_ENV LOCKFILE 2>/dev/null || true

PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/board-serve-selftest.XXXXXX")"
# reap every stub "server" (sleep) this suite spawned — recorded pids only, never a pattern-kill
PIDS="$WORK/spawned.pids"
: > "$PIDS"
trap 'while IFS= read -r _p; do case "$_p" in ""|*[!0-9]*) continue ;; esac; kill "$_p" 2>/dev/null || true; done < "$PIDS"; rm -rf "$WORK"' EXIT

echo "▶ board-serve selftest — occupancy-safe, idempotent, fail-soft, dry-starts-nothing"
echo

# ── the stub toolchain (env-var seams; every invocation is logged for the assertions) ────────────
STUB="$WORK/stub"; mkdir -p "$STUB"

cat > "$STUB/tailscale" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TS_LOG:?}"
case "${1:-} ${2:-}" in
  "status --json") cat "${TS_STATUS_JSON:?}" ;;
  "serve status")  cat "${TS_SERVE_STATUS:?}" 2>/dev/null || true ;;
  "serve --bg")
    # model SET-not-APPEND enough for the reuse check: append the new block to the status fixture
    port=""; target=""
    for a in "$@"; do case "$a" in --https=*) port="${a#--https=}" ;; http://*) target="$a" ;; esac; done
    printf 'https://testbox.ts.net:%s/\n|-- / proxy %s\n' "$port" "$target" >> "${TS_SERVE_STATUS:?}"
    ;;
esac
exit 0
EOF

cat > "$STUB/ss" <<'EOF'
#!/usr/bin/env bash
cat "${SS_FIXTURE:?}" 2>/dev/null || true
exit 0
EOF

cat > "$STUB/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_LOG:?}"
auth=0; url=""; kcfg=0
for a in "$@"; do case "$a" in Authorization:*|"Authorization: "*) auth=1 ;; http://*|https://*) url="$a" ;; -K) kcfg=1 ;; esac; done
# curl -K - reads options (incl. our Authorization header) from STDIN — model that path too, so the
# token-via-stdin confirm is detected exactly as the old -H argv form was.
[ "$kcfg" = 1 ] && grep -qi 'Authorization:[[:space:]]*Bearer' && auth=1
case "$url" in
  *healthz*) printf '200' ;;
  *) if [ "$auth" = 1 ]; then printf '200'; else printf '401'; fi ;;
esac
exit 0
EOF

cat > "$STUB/pyserver" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${PYSPAWN_LOG:?}"
printf '%s\n' "$$" >> "${PYSPAWN_PIDS:?}"
exec sleep 300
EOF
chmod +x "$STUB"/*

# ── fixtures ─────────────────────────────────────────────────────────────────────────────────────
mkfix() {   # $1 = name → echoes a repo fixture with a seeded board state + a planted token
  local f="$WORK/$1"
  mkdir -p "$f/.kickoff/state/mission-control"
  printf '{"project":"fix","activity":[]}\n' > "$f/.kickoff/state/mission-control/mission-state.json"
  printf 'PLANTED_BOARD_TOKEN_never_print_me_123\n' > "$f/.kickoff/state/mission-control/.mission-token"
  printf '%s' "$f"
}
CORE="$WORK/core"; mkdir -p "$CORE/mission-control"
printf '# dummy — the PY_BIN stub never reads it\n' > "$CORE/mission-control/server.py"

# one env for every board-serve run (per-lane logs/fixtures are (re)pointed as needed)
run_bs() {   # $1 = repo fixture; rest = extra args to board-serve.sh
  local f="$1"; shift
  REPO_DIR="$f" KICKOFF_CORE_DIR="$CORE" \
  TS_BIN="$STUB/tailscale" SS_BIN="$STUB/ss" CURL_BIN="$STUB/curl" PY_BIN="$STUB/pyserver" \
  TS_LOG="$TS_LOG" TS_STATUS_JSON="$TS_STATUS_JSON" TS_SERVE_STATUS="$TS_SERVE_STATUS" \
  SS_FIXTURE="$SS_FIXTURE" CURL_LOG="$CURL_LOG" PYSPAWN_LOG="$PYSPAWN_LOG" PYSPAWN_PIDS="$PIDS" \
  bash "$BS" "$@" 2>&1
}

# ══════════════════════════════════════════════════════════════════════════════════════
echo "1. --dry-run starts NOTHING (no server spawn, no tailscale mutation, no record)"
F1="$(mkfix f1)"
TS_LOG="$WORK/1.ts.log"; TS_STATUS_JSON="$WORK/1.status.json"; TS_SERVE_STATUS="$WORK/1.serve.txt"
SS_FIXTURE="$WORK/1.ss.txt"; CURL_LOG="$WORK/1.curl.log"; PYSPAWN_LOG="$WORK/1.spawn.log"
: > "$TS_LOG"; : > "$CURL_LOG"; : > "$PYSPAWN_LOG"; : > "$SS_FIXTURE"; : > "$TS_SERVE_STATUS"
printf '{"BackendState":"Running","Self":{"DNSName":"testbox.ts.net."}}\n' > "$TS_STATUS_JSON"
d_rc=0; d_out="$(run_bs "$F1" --dry-run)" || d_rc=$?
chk "dry-run exits 0" "[ $d_rc -eq 0 ]"
chk "dry-run spawned NO server (the PY stub was never invoked)" "[ ! -s \"$PYSPAWN_LOG\" ]"
chk "dry-run mutated NO tailscale mapping (no 'serve --bg' in the stub log)" \
  "! grep -q -- '--bg' \"$TS_LOG\""
chk "dry-run wrote NO port record" "[ ! -e \"$F1/.kickoff/state/mission-control/board-serve.env\" ]"
chk "dry-run SAYS it is a dry-run (would start / would map)" \
  "printf '%s' \"\$d_out\" | grep -qi 'DRY-RUN'"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "2. fresh serve — free-port pick (ss pre-check), NO clobber of an occupied tailnet port, no token leak"
F2="$(mkfix f2)"
TS_LOG="$WORK/2.ts.log"; TS_STATUS_JSON="$WORK/1.status.json"; TS_SERVE_STATUS="$WORK/2.serve.txt"
SS_FIXTURE="$WORK/2.ss.txt"; CURL_LOG="$WORK/2.curl.log"; PYSPAWN_LOG="$WORK/2.spawn.log"
: > "$TS_LOG"; : > "$CURL_LOG"; : > "$PYSPAWN_LOG"
# local 9100 is OCCUPIED (the ss pre-check must skip it); tailnet 8100 is TAKEN by ANOTHER upstream
printf 'LISTEN 0 128 127.0.0.1:9100 0.0.0.0:*\n' > "$SS_FIXTURE"
printf 'https://testbox.ts.net:8100/\n|-- / proxy http://127.0.0.1:3000\n' > "$TS_SERVE_STATUS"
f2_rc=0
f2_out="$(BOARD_LOCAL_PORTS='9100 9101' BOARD_TAILNET_PORTS='443 8100 8101' run_bs "$F2")" || f2_rc=$?
F2REC="$F2/.kickoff/state/mission-control/board-serve.env"
chk "fresh serve exits 0" "[ $f2_rc -eq 0 ]"
chk "the OCCUPIED local port 9100 was SKIPPED — the server got the free 9101 (ss pre-check honored)" \
  "grep -q ' 9101$' \"$PYSPAWN_LOG\" && ! grep -q ' 9100$' \"$PYSPAWN_LOG\""
chk "the TAKEN tailnet port 8100 was NOT clobbered and 443 was NEVER used — the mapping went to 8101" \
  "grep -q -- '--https=8101' \"$TS_LOG\" && ! grep -q -- '--https=8100' \"$TS_LOG\" && ! grep -q -- '--https=443' \"$TS_LOG\""
chk "exactly ONE serve mutation (set once, confirmed once)" \
  "[ \"\$(grep -c -- '--bg' \"$TS_LOG\")\" = 1 ]"
chk "the port record persists BOTH assigned ports (stable URL across restarts)" \
  "grep -q '^BOARD_LOCAL_PORT=9101$' \"$F2REC\" && grep -q '^BOARD_TAILNET_PORT=8101$' \"$F2REC\""
chk "the tailnet confirm ran 401-then-200 (the SKILL's step-3 both-codes assert)" \
  "printf '%s' \"\$f2_out\" | grep -q 'tailnet confirm PASSED'"
# REVERT-DETECTOR (the ce5b40b motion, fifth site): curl reads ~/.curlrc BEFORE any option, so a
# hostile trace-ascii there would capture the bearer token the -K - stdin recipe carries — `-q`
# must stay curl's FIRST argument. Asserted against the LIVE run's recorded argv (consumed state,
# the supervisor-liveness (R2) extraction): the `-K` line's first field.
chk "curlrc GUARD: the TOKEN-bearing confirm's first curl argument is -q (a hostile ~/.curlrc can't trace the bearer)" \
  "[ \"\$(awk '/ -K /{print \$1; exit}' \"$CURL_LOG\")\" = -q ]"
chk "the handoff surfaces the URL" \
  "printf '%s' \"\$f2_out\" | grep -q 'https://testbox.ts.net:8101/'"
chk "CREDENTIAL-GUARD: the token value is NEVER printed (operator cats it themselves)" \
  "! printf '%s' \"\$f2_out\" | grep -q 'PLANTED_BOARD_TOKEN' && printf '%s' \"\$f2_out\" | grep -q 'cat '"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "3. idempotent second \`up\` — REUSE the live server + the existing mapping (no port sprawl)"
i_rc=0
i_out="$(BOARD_LOCAL_PORTS='9100 9101' BOARD_TAILNET_PORTS='443 8100 8101' run_bs "$F2")" || i_rc=$?
chk "second run exits 0" "[ $i_rc -eq 0 ]"
chk "NO second server spawned (the live pid + healthz were REUSED)" \
  "[ \"\$(wc -l < \"$PYSPAWN_LOG\" | tr -d ' ')\" = 1 ]"
chk "NO second serve mutation (the existing mapping was found in serve status and reused)" \
  "[ \"\$(grep -c -- '--bg' \"$TS_LOG\")\" = 1 ]"
chk "the record still names the SAME ports (stable URL — no per-\`up\` minting)" \
  "grep -q '^BOARD_LOCAL_PORT=9101$' \"$F2REC\" && grep -q '^BOARD_TAILNET_PORT=8101$' \"$F2REC\""
chk "the output SAYS it reused (server + mapping)" \
  "printf '%s' \"\$i_out\" | grep -qi 'reusing'"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "4. fail-SOFT — every missing precondition is a warn + exit 0 (the board never blocks the worker)"
# (a) tailscale has no DNS name (down/logged-out) → LOCAL-ONLY, still exit 0, server still up
F4="$(mkfix f4)"
TS_LOG="$WORK/4.ts.log"; TS_STATUS_JSON="$WORK/4.status.json"; TS_SERVE_STATUS="$WORK/4.serve.txt"
SS_FIXTURE="$WORK/4.ss.txt"; CURL_LOG="$WORK/4.curl.log"; PYSPAWN_LOG="$WORK/4.spawn.log"
: > "$TS_LOG"; : > "$CURL_LOG"; : > "$PYSPAWN_LOG"; : > "$SS_FIXTURE"; : > "$TS_SERVE_STATUS"
printf '{"BackendState":"NeedsLogin"}\n' > "$TS_STATUS_JSON"
t_rc=0; t_out="$(BOARD_LOCAL_PORTS='9105' run_bs "$F4")" || t_rc=$?
chk "(a) tailscale down → exit 0 (fail-soft; the worker launch continues)" "[ $t_rc -eq 0 ]"
chk "(a) the local server still came up (board is LOCAL-ONLY, not absent)" "grep -q ' 9105$' \"$PYSPAWN_LOG\""
chk "(a) no serve mutation was attempted" "! grep -q -- '--bg' \"$TS_LOG\""
chk "(a) the warn NAMES the local-only consequence" "printf '%s' \"\$t_out\" | grep -qi 'LOCAL-ONLY'"
# (b) an older core without server.py → warn + exit 0, nothing spawned
F4B="$(mkfix f4b)"; CORE2="$WORK/core2"; mkdir -p "$CORE2"
PYSPAWN_LOG="$WORK/4b.spawn.log"; : > "$PYSPAWN_LOG"
b_rc=0; b_out="$(KICKOFF_CORE_DIR="$CORE2" REPO_DIR="$F4B" TS_BIN="$STUB/tailscale" SS_BIN="$STUB/ss" CURL_BIN="$STUB/curl" PY_BIN="$STUB/pyserver" TS_LOG="$TS_LOG" TS_STATUS_JSON="$TS_STATUS_JSON" TS_SERVE_STATUS="$TS_SERVE_STATUS" SS_FIXTURE="$SS_FIXTURE" CURL_LOG="$CURL_LOG" PYSPAWN_LOG="$PYSPAWN_LOG" PYSPAWN_PIDS="$PIDS" bash "$BS" 2>&1)" || b_rc=$?
chk "(b) no server.py in the core → exit 0 + nothing spawned (warn names the older-core repair)" \
  "[ $b_rc -eq 0 ] && [ ! -s \"$WORK/4b.spawn.log\" ] && printf '%s' \"\$b_out\" | grep -qi 'server.py'"
# (c) no mission-state yet → exit 0, nothing spawned
F4C="$WORK/f4c"; mkdir -p "$F4C"
PYSPAWN_LOG="$WORK/4c.spawn.log"; : > "$PYSPAWN_LOG"
c_rc=0; c_out="$(run_bs "$F4C")" || c_rc=$?
chk "(c) no mission-state.json → exit 0 + nothing spawned (nothing to serve yet)" \
  "[ $c_rc -eq 0 ] && [ ! -s \"$WORK/4c.spawn.log\" ]"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "5. INTEGRATION — \`kickoff up\` auto-serves the board; \`--dry-run\` starts NOTHING"
# An engine copy + a stub start-supervisor (exit 0) — the config-precedence-selftest shape: cmd_up
# runs for real (flag parse → spawn-env boundary → BOARD SERVE → exec), no real supervisor/claude.
ENG="$WORK/engine/scripts"; mkdir -p "$ENG"
cp "$REPO/scripts/kickoff" "$ENG/kickoff"
cp "$REPO/scripts/board-serve.sh" "$ENG/board-serve.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$ENG/start-supervisor.sh"; chmod +x "$ENG/start-supervisor.sh"
F5="$(mkfix f5)"
mkdir -p "$F5/.kickoff"
printf 'export TELEGRAM_STATE_DIR="%s"\n' "$WORK/chan" > "$F5/.kickoff/instance.env"
TS_LOG="$WORK/5.ts.log"; TS_STATUS_JSON="$WORK/1.status.json"; TS_SERVE_STATUS="$WORK/5.serve.txt"
SS_FIXTURE="$WORK/5.ss.txt"; CURL_LOG="$WORK/5.curl.log"; PYSPAWN_LOG="$WORK/5.spawn.log"
: > "$TS_LOG"; : > "$CURL_LOG"; : > "$PYSPAWN_LOG"; : > "$SS_FIXTURE"; : > "$TS_SERVE_STATUS"
run_up() {   # rest = kickoff up args
  env -i PATH="/usr/bin:/bin" HOME="$WORK" TERM=dumb \
    REPO_DIR="$F5" KICKOFF_CORE_DIR="$CORE" \
    TS_BIN="$STUB/tailscale" SS_BIN="$STUB/ss" CURL_BIN="$STUB/curl" PY_BIN="$STUB/pyserver" \
    TS_LOG="$TS_LOG" TS_STATUS_JSON="$TS_STATUS_JSON" TS_SERVE_STATUS="$TS_SERVE_STATUS" \
    SS_FIXTURE="$SS_FIXTURE" CURL_LOG="$CURL_LOG" PYSPAWN_LOG="$PYSPAWN_LOG" PYSPAWN_PIDS="$PIDS" \
    timeout 60 bash "$ENG/kickoff" up "$@" </dev/null 2>&1
}
F5REC="$F5/.kickoff/state/mission-control/board-serve.env"
ud_rc=0; ud_out="$(run_up --dry-run)" || ud_rc=$?
chk "up --dry-run exits 0 (stubbed supervisor chain)" "[ $ud_rc -eq 0 ]"
chk "up --dry-run started NOTHING: no board server spawned" "[ ! -s \"$PYSPAWN_LOG\" ]"
chk "up --dry-run started NOTHING: no tailscale mutation, no port record" \
  "! grep -q -- '--bg' \"$TS_LOG\" && [ ! -e \"$F5REC\" ]"
uu_rc=0; uu_out="$(run_up)" || uu_rc=$?
chk "a real (non-dry) up exits 0" "[ $uu_rc -eq 0 ]"
chk "a real up brought the board UP (server spawned + tailnet mapping set + record written)" \
  "[ -s \"$PYSPAWN_LOG\" ] && grep -q -- '--bg' \"$TS_LOG\" && [ -f \"$F5REC\" ]"
chk "the up transcript hands over the URL, never the token" \
  "printf '%s' \"\$uu_out\" | grep -q 'https://testbox.ts.net:' && ! printf '%s' \"\$uu_out\" | grep -q 'PLANTED_BOARD_TOKEN'"
uu2_out="$(run_up)" || true
chk "a SECOND up REUSES the same board (still one spawn, one mapping — no sprawl)" \
  "[ \"\$(wc -l < \"$PYSPAWN_LOG\" | tr -d ' ')\" = 1 ] && [ \"\$(grep -c -- '--bg' \"$TS_LOG\")\" = 1 ]"
echo

echo "──────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "  ✅ board auto-serve: occupancy-safe, idempotent, fail-soft, dry-inert"; exit 0; } || { echo "  ❌ see failures above"; exit 1; }
