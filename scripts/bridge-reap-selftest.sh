#!/usr/bin/env bash
# bridge-reap-selftest.sh — hermetic proof of scripts/bridge-reap.sh (reap-on-startup of a
# VERIFIED-stale telegram-channel holder) WITHOUT touching any live bridge/worker.
#
# HOW IT STAYS HERMETIC:
#   - every scenario runs against a /tmp fixture state-dir + STUB processes THIS test spawns
#     and owns (bash sleep-scripts whose argv/environ mimic a bridge); on exit it kills its
#     own stubs by EXACT pid — never a pattern kill, never anyone else's process.
#   - the live repo's session-run.sh / supervisor.sh are sha256-baselined at start and
#     asserted byte-identical at the end (zero-trace).
#   - the KILL scenarios' stubs are double-fork ORPHANED (re-parented away from this test),
#     because the reap's own ancestry guard refuses to kill inside its launch tree — which
#     T7 proves directly with a NON-orphaned descendant stub.
#
# WHAT IT COVERS: the FAIL-TOWARD-NOT-KILLING verification ladder (dead pid · corrupt/nonsense
# bot.pid · missing bot.pid · blank state-dir · wrong-state-dir environ · missing environ var ·
# non-bridge argv · own-launch-tree), the exact-pid reap of a fully-verified stale holder, the
# KICKOFF_BRIDGE_REAP=0 disable knob, wrapper-survival under `set -euo pipefail` on every path,
# and the session-run.sh wiring (sourced + called between the pty-wrap and `exec claude`).
#
# RED-ON-PRE-FIX (soft, self-skipping once the helper is committed): asserts HEAD has no
# scripts/bridge-reap.sh and HEAD's session-run.sh has no call site — i.e. the helper + wiring
# checks here FAIL on the pre-fix tree. The durable post-commit value of this suite is the
# hermetic no-kill negative controls above.
#
#   bash scripts/bridge-reap-selftest.sh      # PASS/FAIL per check + summary, rc 0/1
set -uo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
LIVE_REPO="$(cd "$SCRIPTS/.." && pwd)"
HELPER="$SCRIPTS/bridge-reap.sh"
SESSION_RUN="$SCRIPTS/session-run.sh"

FIX="$(mktemp -d "${TMPDIR:-/tmp}/bridge-reap-selftest.XXXXXX")"
SPAWNED="$FIX/spawned.pids"; : > "$SPAWNED"
cleanup() {
  # reap OUR stubs by exact pid (never a pattern kill; sleep-backstopped anyway)
  local p
  while IFS= read -r p; do
    case "$p" in ''|*[!0-9]*) continue ;; esac
    kill -KILL "$p" 2>/dev/null || true
  done < "$SPAWNED" 2>/dev/null
  rm -rf "$FIX"
}
trap cleanup EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }
section() { printf '\n── %s ──\n' "$*"; }

BASE_RUN="$(sha256sum "$SESSION_RUN" | cut -d' ' -f1)"
BASE_SUP="$(sha256sum "$SCRIPTS/supervisor.sh" | cut -d' ' -f1)"

# ── stub bridge: a bash script whose argv matches the bridge signature class ──
# argv becomes "bash <FIX>/bun-telegram/server.ts" → matches *telegram*server.ts*.
# TERM-able (trap) and self-expiring (the sleep loop) as a leak backstop.
mkdir -p "$FIX/bun-telegram" "$FIX/chan" "$FIX/other-chan"
CHAN="$FIX/chan"; STUB="$FIX/bun-telegram/server.ts"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM
for _ in $(seq 1 120); do sleep 1; done
EOF

# spawn an ORPHANED stub (double-fork: the middle subshell exits, the stub re-parents away
# from this test, so the reap's ancestry guard sees a genuinely foreign process). $1 = the
# TELEGRAM_STATE_DIR value planted in its environ; rest = argv. Prints the stub pid.
spawn_orphan() {
  local tsd="$1"; shift
  local pf="$FIX/orphan.$$.$RANDOM.pid" i pid=""
  ( TELEGRAM_STATE_DIR="$tsd" "$@" >/dev/null 2>&1 & echo $! > "$pf" )
  for i in 1 2 3 4 5 6 7 8 9 10; do
    pid="$(cat "$pf" 2>/dev/null || true)"
    [ -n "$pid" ] && break
    sleep 0.1
  done
  echo "$pid" >> "$SPAWNED"
  printf '%s' "$pid"
}

# run the reap exactly as session-run does: a fresh shell under `set -euo pipefail`,
# helper sourced, one call; echoes WRAPPER-SURVIVED iff the wrapper was not aborted.
run_reap() {
  local tsd="$1"; shift || true
  env -u REPO_DIR TELEGRAM_STATE_DIR="$tsd" "$@" bash -euo pipefail -c \
    ". '$HELPER'; reap_stale_bridge; echo WRAPPER-SURVIVED" 2>&1
}

section "T0 — helper parses"
if bash -n "$HELPER" 2>/dev/null; then ok "bash -n scripts/bridge-reap.sh"; else bad "bash -n scripts/bridge-reap.sh"; fi

section "T1 — verified stale holder is reaped (exact pid)"
P1="$(spawn_orphan "$CHAN" bash "$STUB")"
if [ -n "$P1" ] && kill -0 "$P1" 2>/dev/null; then
  printf '%s' "$P1" > "$CHAN/bot.pid"
  OUT1="$(run_reap "$CHAN")"
  sleep 0.3
  if ! kill -0 "$P1" 2>/dev/null; then ok "fully-verified stale holder (pid=$P1) is GONE after reap"; else bad "stale holder pid=$P1 still alive after reap"; fi
  echo "$OUT1" | grep -q 'REAPING verified-stale channel holder' && ok "reap decision logged loudly" || bad "no loud reap log: $OUT1"
  echo "$OUT1" | grep -q 'WRAPPER-SURVIVED' && ok "wrapper survives the kill path (set -euo pipefail)" || bad "wrapper aborted on the kill path"
else
  bad "could not spawn the T1 stub"
fi

section "T1b — the opencode-telegram arm (engine parity with supervisor bridge_present)"
# The WORKER_ENGINE=opencode bridge is the grinev `opencode-telegram` bot exec'd per spawn
# (session-run.sh's final exec). supervisor.sh's bridge_present has accepted that argv since
# v0.39 — but the reaper's _br_cmd_matches DRIFTED (missing the arm), so a verified-stale
# opencode bridge holding the getUpdates slot was NOT recognized and NOT reaped: the fresh
# worker boots deaf, the exact outage the reaper exists to prevent. RED-first: this lane
# FAILS on the pre-fix helper (stub survives, logged as "NOT a telegram-bridge signature").
OT="$FIX/opencode-telegram"
cat > "$OT" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM
for _ in $(seq 1 120); do sleep 1; done
EOF
P1b="$(spawn_orphan "$CHAN" bash "$OT" start)"
if [ -n "$P1b" ] && kill -0 "$P1b" 2>/dev/null; then
  printf '%s' "$P1b" > "$CHAN/bot.pid"
  OUT1b="$(run_reap "$CHAN")"
  sleep 0.3
  if ! kill -0 "$P1b" 2>/dev/null; then ok "opencode-telegram-argv stale holder (pid=$P1b) RECOGNIZED and reaped"; else bad "opencode-telegram holder pid=$P1b NOT recognized — the reaper's signature class has drifted from supervisor bridge_present again"; fi
  echo "$OUT1b" | grep -q 'REAPING verified-stale channel holder' && ok "opencode-arm reap logged loudly" || bad "no loud reap log for the opencode arm: $OUT1b"
  echo "$OUT1b" | grep -q 'WRAPPER-SURVIVED' && ok "wrapper survives the opencode-arm kill path (set -euo pipefail)" || bad "wrapper aborted on the opencode-arm kill path"
else
  bad "could not spawn the T1b stub"
fi

section "T2 — dead pid in bot.pid: NO action, file left for the fresh bridge"
sleep 0.01 & DP=$!; wait "$DP" 2>/dev/null || true
printf '%s' "$DP" > "$CHAN/bot.pid"
OUT2="$(run_reap "$CHAN")"
echo "$OUT2" | grep -q 'DEAD pid' && ok "dead holder detected, no kill attempted" || bad "dead-pid path wrong: $OUT2"
[ "$(cat "$CHAN/bot.pid")" = "$DP" ] && ok "bot.pid left untouched (fresh bridge overwrites it itself)" || bad "bot.pid was modified"
echo "$OUT2" | grep -q 'WRAPPER-SURVIVED' && ok "wrapper survives" || bad "wrapper aborted"

section "T3 — live holder bound to a DIFFERENT state dir: SURVIVES"
P3="$(spawn_orphan "$FIX/other-chan" bash "$STUB")"
printf '%s' "$P3" > "$CHAN/bot.pid"
OUT3="$(run_reap "$CHAN")"
kill -0 "$P3" 2>/dev/null && ok "different-channel bridge survives (pid=$P3)" || bad "KILLED another channel's bridge — the one unforgivable failure"
echo "$OUT3" | grep -q 'DIFFERENT channel' && ok "state-dir mismatch named in the log" || bad "mismatch not logged: $OUT3"

section "T4 — live holder WITHOUT the signature argv (sleep): SURVIVES"
P4="$(spawn_orphan "$CHAN" sleep 120)"
printf '%s' "$P4" > "$CHAN/bot.pid"
OUT4="$(run_reap "$CHAN")"
kill -0 "$P4" 2>/dev/null && ok "non-bridge argv survives (pid=$P4 — recycled-pid protection)" || bad "KILLED a non-bridge process"
echo "$OUT4" | grep -q 'NOT a telegram-bridge signature' && ok "argv mismatch named in the log" || bad "argv mismatch not logged: $OUT4"

section "T5 — live bridge-argv holder with NO TELEGRAM_STATE_DIR in its environ: SURVIVES"
P5="$(spawn_orphan "$CHAN" env -u TELEGRAM_STATE_DIR bash "$STUB")"
printf '%s' "$P5" > "$CHAN/bot.pid"
OUT5="$(run_reap "$CHAN")"
kill -0 "$P5" 2>/dev/null && ok "environ-less holder survives (pid=$P5 — cannot prove ownership ⇒ no kill)" || bad "KILLED an unproven holder"
echo "$OUT5" | grep -q 'no TELEGRAM_STATE_DIR in its environment' && ok "missing environ binding named in the log" || bad "not logged: $OUT5"
kill -TERM "$P5" 2>/dev/null || true

section "T6 — corrupt / nonsense / absent bot.pid and blank state-dir: all clean no-ops"
printf 'garbage-42x' > "$CHAN/bot.pid"
OUT6a="$(run_reap "$CHAN")"
echo "$OUT6a" | grep -q 'corrupt' && echo "$OUT6a" | grep -q 'WRAPPER-SURVIVED' && ok "corrupt bot.pid → logged no-op, wrapper survives" || bad "corrupt path wrong: $OUT6a"
printf '1' > "$CHAN/bot.pid"
OUT6b="$(run_reap "$CHAN")"
echo "$OUT6b" | grep -q 'nonsense value' && echo "$OUT6b" | grep -q 'WRAPPER-SURVIVED' && ok "bot.pid=1 → logged no-op (never signals pid<=1)" || bad "pid<=1 path wrong: $OUT6b"
rm -f "$CHAN/bot.pid"
OUT6c="$(run_reap "$CHAN")"
echo "$OUT6c" | grep -q 'channel slot is clean' && echo "$OUT6c" | grep -q 'WRAPPER-SURVIVED' && ok "missing bot.pid → clean no-op" || bad "missing-bot.pid path wrong: $OUT6c"
OUT6d="$(run_reap "")"
echo "$OUT6d" | grep -q 'unset/blank' && echo "$OUT6d" | grep -q 'WRAPPER-SURVIVED' && ok "blank TELEGRAM_STATE_DIR → clean no-op" || bad "blank-tsd path wrong: $OUT6d"
OUT6e="$(run_reap "$FIX/does-not-exist")"
echo "$OUT6e" | grep -q 'WRAPPER-SURVIVED' && ok "nonexistent state dir → wrapper survives" || bad "nonexistent-dir path aborted: $OUT6e"

section "T7 — ancestry guard: a fully-matching stub INSIDE our own launch tree SURVIVES"
cat > "$FIX/t7.sh" <<'EOF'
set -euo pipefail
. "$HELPER"
TELEGRAM_STATE_DIR="$CHAN" bash "$STUB" >/dev/null 2>&1 &
P=$!
echo "$P" >> "$SPAWNED"
printf '%s' "$P" > "$CHAN/bot.pid"
reap_stale_bridge
if kill -0 "$P" 2>/dev/null; then echo DESCENDANT-ALIVE; else echo DESCENDANT-DEAD; fi
kill -TERM "$P" 2>/dev/null || true
echo WRAPPER-SURVIVED
EOF
OUT7="$(env -u REPO_DIR TELEGRAM_STATE_DIR="$CHAN" HELPER="$HELPER" CHAN="$CHAN" STUB="$STUB" SPAWNED="$SPAWNED" bash "$FIX/t7.sh" 2>&1)"
echo "$OUT7" | grep -q 'DESCENDANT-ALIVE' && ok "own-launch-tree descendant survives despite full signature+environ match" || bad "guard failed — killed inside our own tree: $OUT7"
echo "$OUT7" | grep -q 'inside our own launch tree' && ok "launch-tree refusal named in the log" || bad "refusal not logged: $OUT7"

section "T8 — KICKOFF_BRIDGE_REAP=0 disables (then the enabled run reaps the same stub)"
P8="$(spawn_orphan "$CHAN" bash "$STUB")"
printf '%s' "$P8" > "$CHAN/bot.pid"
OUT8a="$(run_reap "$CHAN" KICKOFF_BRIDGE_REAP=0)"
kill -0 "$P8" 2>/dev/null && ok "knob off → verified stale holder deliberately left alive" || bad "knob off but the holder was killed"
echo "$OUT8a" | grep -q 'disabled (KICKOFF_BRIDGE_REAP=0)' && ok "disable decision logged" || bad "disable not logged: $OUT8a"
OUT8b="$(run_reap "$CHAN")"
sleep 0.3
if ! kill -0 "$P8" 2>/dev/null; then ok "same stub reaped once re-enabled (default-on)" ; else bad "re-enabled run did not reap"; fi

section "T9 — session-run.sh wiring (source + call between the pty-wrap and exec claude)"
grep -q 'bridge-reap\.sh' "$SESSION_RUN" && ok "session-run.sh sources bridge-reap.sh" || bad "no bridge-reap.sh source in session-run.sh"
PTY_LN="$(grep -n 'exec script -qfe -c' "$SESSION_RUN" | head -1 | cut -d: -f1)"
CALL_LN="$(grep -n '^reap_stale_bridge' "$SESSION_RUN" | head -1 | cut -d: -f1)"
EXEC_LN="$(grep -n '^exec claude' "$SESSION_RUN" | head -1 | cut -d: -f1)"
if [ -n "$PTY_LN" ] && [ -n "$CALL_LN" ] && [ -n "$EXEC_LN" ] && [ "$PTY_LN" -lt "$CALL_LN" ] && [ "$CALL_LN" -lt "$EXEC_LN" ]; then
  ok "reap runs once per spawn: after the pty re-exec (:$PTY_LN), before exec claude (:$EXEC_LN) — at :$CALL_LN"
else
  bad "call site missing or mis-ordered (pty=$PTY_LN call=$CALL_LN exec=$EXEC_LN)"
fi
grep -q 'bash -n .*bridge-reap\|bash -n "\$_BR_HELPER"' "$SESSION_RUN" && ok "source is bash -n gated (corrupt helper never parsed)" || bad "no bash -n gate on the source"

section "T10 — RED on the pre-fix (HEAD) tree"
if git -C "$LIVE_REPO" show HEAD:scripts/bridge-reap.sh >/dev/null 2>&1; then
  ok "helper already committed at HEAD — RED-on-old self-skips (the hermetic negative controls above are the durable value)"
else
  ok "RED proven: HEAD has NO scripts/bridge-reap.sh (every helper check above fails on the pre-fix tree)"
  if git -C "$LIVE_REPO" show HEAD:scripts/session-run.sh > "$FIX/session-run.head" 2>/dev/null; then
    if ! grep -q 'reap_stale_bridge' "$FIX/session-run.head"; then
      ok "RED proven: HEAD session-run.sh has NO reap call site (the T9 wiring check fails on the pre-fix tree)"
    else
      bad "HEAD session-run.sh already calls reap_stale_bridge but the helper is missing — inconsistent tree"
    fi
  else
    bad "could not read HEAD:scripts/session-run.sh"
  fi
fi

section "T11 — zero-trace on the live tree"
[ "$(sha256sum "$SESSION_RUN" | cut -d' ' -f1)" = "$BASE_RUN" ] && ok "session-run.sh byte-identical" || bad "session-run.sh CHANGED during the test"
[ "$(sha256sum "$SCRIPTS/supervisor.sh" | cut -d' ' -f1)" = "$BASE_SUP" ] && ok "supervisor.sh byte-identical" || bad "supervisor.sh CHANGED during the test"

echo
echo "──────────────────────────────"
printf '  %s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  SELFTEST PASS"; exit 0; fi
echo "  SELFTEST FAIL"; exit 1
