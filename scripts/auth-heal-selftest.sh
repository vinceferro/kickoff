#!/usr/bin/env bash
# auth-heal-selftest.sh — proves the auth self-heal WITHOUT touching the live worker.
#
# PURE by construction:
#   - never runs the real `claude` (probes point at stubs; the default-cmd test uses a
#     fake `claude` shadowing PATH that only records its argv)
#   - never sends network traffic (a fake `curl` shadows PATH and records argv+stdin —
#     which also PROVES the bot token rides stdin, never argv)
#   - never touches the live repo's .kickoff/ or lifecycle scripts: every scenario runs
#     against its own mktemp fixture repo; the live supervisor.sh / session-run.sh /
#     settings.json are sha256-baselined at start and asserted byte-identical at the end
#   - the installer test runs against FIXTURE COPIES via KICKOFF_INSTALL_TARGET_DIR
#
# WHAT IT COVERS (the fail-safe rules):
#   inert-by-default · fail-toward-inaction (indeterminate probes, never-ok anchor,
#   D2 veto on valid auth) · escalate (flag + ONE tokenless alert) · anti-boot-loop
#   (alert cooldown, resume cap) · wait-and-auto-resume · DRY_RUN mutates nothing ·
#   disarm reverts · the staged source-guard survives an absent AND a corrupt helper
#   (no boot-loop, corrupt helper never executes) · relogin.sh turnkey mechanics ·
#   install-auth-heal.sh dry-run/apply/idempotency/drift-abort/rollback on fixtures.
#
#   bash scripts/auth-heal-selftest.sh          # → PASS/FAIL per test + summary, rc 0/1
set -uo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
LIVE_REPO="$(cd "$SCRIPTS/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/auth-heal-selftest.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

PASS_F="$SCRATCH/pass"; FAIL_F="$SCRATCH/fail"
: > "$PASS_F"; : > "$FAIL_F"
ok()  { echo "$1" >> "$PASS_F"; printf '  ✓ %s\n' "$1"; }
bad() { echo "$1" >> "$FAIL_F"; printf '  ✗ %s\n' "$1"; }
section() { printf '\n── %s ──\n' "$*"; }

# live-file baselines (the zero-trace assertion at the end)
BASE_SUP="$(sha256sum "$SCRIPTS/supervisor.sh"   | cut -d' ' -f1)"
BASE_RUN="$(sha256sum "$SCRIPTS/session-run.sh"  | cut -d' ' -f1)"
BASE_SET="$(sha256sum "$LIVE_REPO/.claude/settings.json" 2>/dev/null | cut -d' ' -f1 || echo none)"

# Pristine (pre-auth-heal) fixtures for the installer test (T23/T24). install-auth-heal.sh
# RETROFITS a supervisor.sh/session-run.sh that predate the wiring, so its fixture must be an
# UN-wired file — NOT the live scripts, which are themselves wired once auth-heal ships in the
# core (every edit would then read "already applied", never exercising apply/backup/drift-refusal
# — the very paths this test exists to prove). These frozen copies are byte-identical to the
# pre-wiring blobs (see scripts/testdata/auth-heal/README.md).
PRISTINE="$SCRIPTS/testdata/auth-heal"

# Auth artifacts the selftest must never LEAK into the live .kickoff/. An ARMED dogfood instance
# legitimately owns auth-heal.state (and its live supervisor churns it in place every probe); the
# test writes ONLY to its own SCRATCH fixtures, so the T24 canary flags any artifact that APPEARS
# during the run — snapshotting the pre-existing set here so a live armed instance isn't a false leak.
AUTH_ARTIFACTS="auth-escalated auth-heal.state auth.env auth-heal.alert.last"
PRE_RESIDUE=""
for f in $AUTH_ARTIFACTS; do [ -e "$LIVE_REPO/.kickoff/$f" ] && PRE_RESIDUE="$PRE_RESIDUE $f"; done

# ── shared fixture tooling ────────────────────────────────────────────────────
FIXBIN="$SCRATCH/bin"
mkdir -p "$FIXBIN"

# fake curl: records argv + stdin; never touches the network
cat > "$FIXBIN/curl" <<'EOF'
#!/usr/bin/env bash
d="${CURL_RECORD_DIR:?}"
n="$(cat "$d/count" 2>/dev/null || echo 0)"; n=$((n+1)); echo "$n" > "$d/count"
printf '%s\n' "$*" > "$d/argv.$n"
if [ ! -t 0 ]; then cat > "$d/stdin.$n"; fi
exit 0
EOF
chmod +x "$FIXBIN/curl"

# fake claude (default-cmd resolution test): records argv, emits healthy JSON
cat > "$FIXBIN/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CLAUDE_RECORD_FILE:?}"
echo '{"loggedIn": true, "authMethod": "claude.ai"}'
exit 0
EOF
chmod +x "$FIXBIN/claude"

# controllable auth probe stub: rc from $AUTHSTUB_CTL/rc, output from $AUTHSTUB_CTL/out
cat > "$FIXBIN/authstub" <<'EOF'
#!/usr/bin/env bash
c="${AUTHSTUB_CTL:?}"
rc="$(cat "$c/rc" 2>/dev/null || echo 0)"
if [ -f "$c/out" ]; then cat "$c/out"; else echo '{"loggedIn": true}'; fi
exit "$rc"
EOF
chmod +x "$FIXBIN/authstub"

# token-sensitive stub: succeeds ONLY if the probe env carries the expected token
cat > "$FIXBIN/tokecho" <<'EOF'
#!/usr/bin/env bash
if [ "${CLAUDE_CODE_OAUTH_TOKEN:-}" = "sk-ant-oat01-FAKETESTTOKEN123456" ]; then
  echo '{"loggedIn": true}'; exit 0
fi
echo 'no token in probe env'; exit 1
EOF
chmod +x "$FIXBIN/tokecho"

new_fixture() {  # $1 = name → prints the fixture repo path
  local r="$SCRATCH/$1"
  mkdir -p "$r/.kickoff" "$r/ctl" "$r/curl" "$r/tstate"
  printf '{"env":{"TELEGRAM_BOT_TOKEN":"TESTTOK-123456"}}\n' > "$r/settings.local.json"
  printf '{"allowFrom":["555000111"]}\n' > "$r/tstate/access.json"
  echo 0 > "$r/ctl/rc"
  printf '%s' "$r"
}

# every scenario runs in a subshell with THIS env — nothing ambient leaks in
# (REPO_DIR is ambiently exported on this box — memory/dogfood-repo-is-the-live-engine.md)
scenario_env() {  # $1 = fixture repo
  local r="$1"
  export REPO_DIR="$r"
  export KICKOFF_DIR="$r/.kickoff"
  export REFRESH_FLAG="$r/.kickoff/refresh-requested"
  export INSTANCE_ENV="$r/.kickoff/instance.env"
  export SETTINGS_FILE="$r/settings.local.json"
  export TELEGRAM_STATE_DIR="$r/tstate"
  export AUTH_ENV="$r/.kickoff/auth.env"
  export AUTHSTUB_CTL="$r/ctl"
  export CURL_RECORD_DIR="$r/curl"
  export CLAUDE_RECORD_FILE="$r/claude.argv"
  export PATH="$FIXBIN:$PATH"
  unset KICKOFF_AUTH_HEAL KICKOFF_AUTH_CHECK_CMD KICKOFF_AUTH_REFRESH_CMD \
        KICKOFF_AUTH_CHECK_INTERVAL KICKOFF_AUTH_RECHECK_INTERVAL \
        KICKOFF_AUTH_FAILS_TO_ESCALATE KICKOFF_AUTH_EARLY_DEATH_SECONDS \
        KICKOFF_AUTH_EARLY_DEATHS_TO_ESCALATE KICKOFF_AUTH_ALERT_COOLDOWN \
        KICKOFF_AUTH_MAX_AUTO_RESUMES KICKOFF_AUTH_PROBE_TIMEOUT \
        DRY_RUN SESSION_STARTED CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null || true
}

curl_count() { cat "${CURL_RECORD_DIR:?}/count" 2>/dev/null || echo 0; }
state_get()  { sed -n "s/^$2=//p" "$1/.kickoff/auth-heal.state" 2>/dev/null | head -1; }

# ══════════════════════════════════════════════════════════════════════════════
section "T1 syntax: bash -n on every new script"
for f in auth-heal.sh relogin.sh install-auth-heal.sh auth-heal-selftest.sh; do
  if bash -n "$SCRIPTS/$f" 2>/dev/null; then ok "bash -n $f"; else bad "bash -n $f"; fi
done

# ══════════════════════════════════════════════════════════════════════════════
section "T2 inert by default: disarmed step is a pure no-op"
R="$(new_fixture t2)"
(
  scenario_env "$R"
  set -euo pipefail            # mirror the supervisor's shell opts
  session_alive() { return 0; }
  SESSION_STARTED=1; SECONDS=100
  . "$SCRIPTS/auth-heal.sh"
  auth_heal_step
  auth_heal_step
) > "$SCRATCH/t2.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "disarmed step returns 0 under set -euo pipefail" || bad "disarmed step rc=$rc"
leftover="$(find "$R/.kickoff" -type f 2>/dev/null | wc -l)"
[ "$leftover" -eq 0 ] && ok "disarmed step writes NOTHING to .kickoff" || bad "disarmed step left $leftover file(s): $(find "$R/.kickoff" -type f)"
[ "$(CURL_RECORD_DIR="$R/curl" curl_count)" = "0" ] && ok "disarmed step sends nothing" || bad "disarmed step sent a curl"

# ══════════════════════════════════════════════════════════════════════════════
section "T3 fail-safe regression: the staged source-guard (absent / corrupt helper)"
# mini-supervisor embedding EXACTLY the staged S1 guard + S2 call + S3 gate shape
make_mini() {  # $1 = mini script path, $2 = SCRIPT_DIR it should use
  cat > "$1" <<MINI
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$2"
REPO_DIR="\${REPO_DIR:?}"
KICKOFF_DIR="\$REPO_DIR/.kickoff"
REFRESH_FLAG="\$KICKOFF_DIR/refresh-requested"
session_alive() { [ "\${T_ALIVE:-1}" = "1" ]; }
SESSION_STARTED=\$SECONDS

# ── the staged S1 guard, verbatim shape ──
if [ -f "\$SCRIPT_DIR/auth-heal.sh" ] && bash -n "\$SCRIPT_DIR/auth-heal.sh" 2>/dev/null; then
  . "\$SCRIPT_DIR/auth-heal.sh" || true
fi
if ! command -v auth_heal_step >/dev/null 2>&1; then auth_heal_step() { :; }; fi

for i in 1 2 3; do
  auth_heal_step || true                                   # staged S2
  if ! session_alive && [ ! -f "\$KICKOFF_DIR/auth-escalated" ]; then   # staged S3
    echo "WOULD-RESTART"
  fi
done
echo "MINI-COMPLETED"
MINI
}

# (a) helper ABSENT → identical to today, loop completes
R="$(new_fixture t3a)"; mkdir -p "$R/core"
make_mini "$R/mini.sh" "$R/core"
out="$(REPO_DIR="$R" T_ALIVE=1 bash "$R/mini.sh" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -q MINI-COMPLETED <<<"$out"; } && ok "absent helper: supervisor loop runs to completion (no-op stub)" || bad "absent helper: rc=$rc out=$out"

# (b) helper CORRUPT → bash -n gate refuses it; loop completes AND the corrupt file never EXECUTES
R="$(new_fixture t3b)"; mkdir -p "$R/core"
printf 'touch "%s/EXECUTED-MARKER"\nif then fi ((( garbage {{{\n' "$R" > "$R/core/auth-heal.sh"
make_mini "$R/mini.sh" "$R/core"
out="$(REPO_DIR="$R" T_ALIVE=1 bash "$R/mini.sh" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -q MINI-COMPLETED <<<"$out"; } && ok "corrupt helper: supervisor loop still completes (no boot-loop)" || bad "corrupt helper: rc=$rc out=$out"
[ ! -f "$R/EXECUTED-MARKER" ] && ok "corrupt helper is NEVER executed (bash -n gates the source)" || bad "corrupt helper EXECUTED its first line — the naive '. file || true' hazard"

# (c) real helper, armed, probe expired → flag written; S3 gate stops the restart
R="$(new_fixture t3c)"
make_mini "$R/mini.sh" "$SCRIPTS"       # SCRIPT_DIR = the real scripts/ (real auth-heal.sh)
printf '{"loggedIn": false}\n' > "$R/ctl/out"   # rc0+loggedIn:false = expiry evidence outright
out="$(
  scenario_env "$R"
  export KICKOFF_AUTH_HEAL=1 KICKOFF_AUTH_CHECK_CMD="$FIXBIN/authstub" \
         KICKOFF_AUTH_CHECK_INTERVAL=0 KICKOFF_AUTH_FAILS_TO_ESCALATE=1 \
         KICKOFF_AUTH_EARLY_DEATH_SECONDS=0
  T_ALIVE=0 bash "$R/mini.sh" 2>&1
)"
grep -q "ESCALATED" <<<"$out" && ok "armed+expired inside the mini-supervisor: escalates" || bad "no escalation in mini-supervisor: $out"
[ -f "$R/.kickoff/auth-escalated" ] && ok "escalation flag written" || bad "no escalation flag"
grep -q "WOULD-RESTART" <<<"$out" && bad "S3 gate FAILED: dead session still restarted while escalated" || ok "S3 gate holds: no restart while escalated"
make_mini "$SCRATCH/mini-live-shape.sh" "$SCRIPTS"   # parity: guard parses with the real helper too
bash -n "$SCRATCH/mini-live-shape.sh" && ok "staged guard parses against the real scripts/ dir" || bad "staged guard parse failure"

# ══════════════════════════════════════════════════════════════════════════════
section "T4 armed + healthy probe → no action, state recorded"
R="$(new_fixture t4)"
(
  scenario_env "$R"
  set -euo pipefail
  export KICKOFF_AUTH_HEAL=1 KICKOFF_AUTH_CHECK_CMD="$FIXBIN/authstub" KICKOFF_AUTH_CHECK_INTERVAL=0
  session_alive() { return 0; }
  SESSION_STARTED=1; SECONDS=100
  . "$SCRIPTS/auth-heal.sh"
  auth_heal_step; auth_heal_step
) > "$SCRATCH/t4.log" 2>&1
[ ! -f "$R/.kickoff/auth-escalated" ] && ok "healthy: no escalation flag" || bad "healthy: flag appeared"
[ "$(state_get "$R" EVER_OK)" = "1" ] && ok "healthy: EVER_OK=1 recorded in state" || bad "healthy: EVER_OK missing ($(cat "$R/.kickoff/auth-heal.state" 2>/dev/null))"
[ "$(CURL_RECORD_DIR="$R/curl" curl_count)" = "0" ] && ok "healthy: no alert" || bad "healthy: alert sent"

# ══════════════════════════════════════════════════════════════════════════════
section "T5 D3 escalation: N consecutive fails → flag + ONE tokenless alert"
R="$(new_fixture t5)"
(
  scenario_env "$R"
  set -euo pipefail
  export KICKOFF_AUTH_HEAL=1 KICKOFF_AUTH_CHECK_CMD="$FIXBIN/authstub" \
         KICKOFF_AUTH_CHECK_INTERVAL=0 KICKOFF_AUTH_RECHECK_INTERVAL=0 \
         KICKOFF_AUTH_FAILS_TO_ESCALATE=2 KICKOFF_AUTH_ALERT_COOLDOWN=99999 \
         KICKOFF_AUTH_EARLY_DEATH_SECONDS=0
  session_alive() { return 0; }
  SESSION_STARTED=1; SECONDS=100
  . "$SCRIPTS/auth-heal.sh"
  auth_heal_step                      # valid → EVER_OK
  echo 1 > "$AUTHSTUB_CTL/rc"
  auth_heal_step                      # fail 1/2 → no flag yet
  [ ! -f "$KICKOFF_DIR/auth-escalated" ] || { echo "PREMATURE-FLAG"; exit 9; }
  auth_heal_step                      # fail 2/2 → escalate
) > "$SCRATCH/t5.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "streak sequencing ran (no premature flag)" || bad "T5 scenario rc=$rc: $(cat "$SCRATCH/t5.log")"
[ -f "$R/.kickoff/auth-escalated" ] && ok "flag written after streak ${KICKOFF_AUTH_FAILS_TO_ESCALATE:-2}" || bad "no flag after streak"
grep -q "auth probe failed 2x" "$R/.kickoff/auth-escalated" && ok "flag records the reason" || bad "flag reason missing: $(cat "$R/.kickoff/auth-escalated" 2>/dev/null)"
cc="$(CURL_RECORD_DIR="$R/curl" curl_count)"
[ "$cc" = "1" ] && ok "exactly ONE alert sent" || bad "alert count=$cc (want 1)"
if [ -f "$R/curl/argv.1" ]; then
  grep -q "TESTTOK-123456" "$R/curl/argv.1" && bad "BOT TOKEN LEAKED ON ARGV" || ok "bot token NOT on curl argv"
  grep -q "chat_id=555000111" "$R/curl/argv.1" && ok "alert targeted the allowFrom chat" || bad "chat_id missing from alert"
  grep -q "relogin.sh" "$R/curl/argv.1" && ok "alert copy hands the operator the turnkey (relogin.sh)" || bad "alert copy lacks relogin.sh"
  grep -q "botTESTTOK-123456" "$R/curl/stdin.1" 2>/dev/null && ok "bot token rides curl stdin (-K -), off argv" || bad "token URL not on curl stdin"
  grep -q -- '^-q ' "$R/curl/argv.1" && ok "curl's FIRST argument is -q (suppresses ~/.curlrc / \$CURL_HOME/.curlrc — a trace-ascii there would write the token URL to disk)" || bad "curl's first argv is not -q (got: $(head -n1 "$R/curl/argv.1" | cut -c1-40))"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "T6 never-ok anchor: a probe that never succeeded can't escalate"
R="$(new_fixture t6)"
echo 1 > "$R/ctl/rc"
(
  scenario_env "$R"
  set -euo pipefail
  export KICKOFF_AUTH_HEAL=1 KICKOFF_AUTH_CHECK_CMD="$FIXBIN/authstub" \
         KICKOFF_AUTH_CHECK_INTERVAL=0 KICKOFF_AUTH_FAILS_TO_ESCALATE=1 \
         KICKOFF_AUTH_EARLY_DEATH_SECONDS=0
  session_alive() { return 0; }
  SESSION_STARTED=1; SECONDS=100
  . "$SCRIPTS/auth-heal.sh"
  auth_heal_step; auth_heal_step; auth_heal_step; auth_heal_step; auth_heal_step
) > "$SCRATCH/t6.log" 2>&1
[ ! -f "$R/.kickoff/auth-escalated" ] && ok "failing-from-birth probe stays INDETERMINATE (wrong-command guard)" || bad "never-ok probe escalated — false-positive hazard"
[ "$(CURL_RECORD_DIR="$R/curl" curl_count)" = "0" ] && ok "and sends no alert" || bad "never-ok probe alerted"

# ══════════════════════════════════════════════════════════════════════════════
section "T7 indeterminate rcs: 127 (missing cmd) and 124 (timeout) take no action"
R="$(new_fixture t7)"
(
  scenario_env "$R"
  set -euo pipefail
  export KICKOFF_AUTH_HEAL=1 KICKOFF_AUTH_CHECK_CMD="$FIXBIN/authstub" \
         KICKOFF_AUTH_CHECK_INTERVAL=0 KICKOFF_AUTH_FAILS_TO_ESCALATE=1 \
         KICKOFF_AUTH_EARLY_DEATH_SECONDS=0
  session_alive() { return 0; }
  SESSION_STARTED=1; SECONDS=100
  . "$SCRIPTS/auth-heal.sh"
  auth_heal_step                                          # valid → EVER_OK=1
  export KICKOFF_AUTH_CHECK_CMD="/nonexistent/kickoff-authprobe-xyz"
  auth_heal_step; auth_heal_step                          # rc 127 → indeterminate
  [ -f "$KICKOFF_DIR/auth-escalated" ] && exit 9
  export KICKOFF_AUTH_CHECK_CMD="sleep 3" KICKOFF_AUTH_PROBE_TIMEOUT=1
  auth_heal_step                                          # rc 124 → indeterminate
) > "$SCRATCH/t7.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ ! -f "$R/.kickoff/auth-escalated" ] && ok "127 + 124 stay indeterminate — no escalation" || bad "indeterminate rc escalated (rc=$rc)"

# ══════════════════════════════════════════════════════════════════════════════
section "T8 rc0 + loggedIn:false counts as a failed probe"
R="$(new_fixture t8)"
(
  scenario_env "$R"
  set -euo pipefail
  export KICKOFF_AUTH_HEAL=1 KICKOFF_AUTH_CHECK_CMD="$FIXBIN/authstub" \
         KICKOFF_AUTH_CHECK_INTERVAL=0 KICKOFF_AUTH_FAILS_TO_ESCALATE=1 \
         KICKOFF_AUTH_ALERT_COOLDOWN=99999 KICKOFF_AUTH_EARLY_DEATH_SECONDS=0
  session_alive() { return 0; }
  SESSION_STARTED=1; SECONDS=100
  . "$SCRIPTS/auth-heal.sh"
  auth_heal_step                                          # loggedIn:true → EVER_OK
  printf '{"loggedIn": false}\n' > "$AUTHSTUB_CTL/out"    # rc stays 0!
  auth_heal_step
) > "$SCRATCH/t8.log" 2>&1
[ -f "$R/.kickoff/auth-escalated" ] && ok "rc0 + loggedIn:false escalates (logged-out shape caught)" || bad "loggedIn:false missed"

# ══════════════════════════════════════════════════════════════════════════════
section "T9 anti-boot-loop: ≤1 alert per cooldown; cooldown=0 re-alerts"
R="$(new_fixture t9)"
(
  scenario_env "$R"
  set -euo pipefail
  export KICKOFF_AUTH_HEAL=1 KICKOFF_AUTH_CHECK_CMD="$FIXBIN/authstub" \
         KICKOFF_AUTH_CHECK_INTERVAL=0 KICKOFF_AUTH_RECHECK_INTERVAL=0 \
         KICKOFF_AUTH_FAILS_TO_ESCALATE=1 KICKOFF_AUTH_ALERT_COOLDOWN=99999 \
         KICKOFF_AUTH_EARLY_DEATH_SECONDS=0
  session_alive() { return 0; }
  SESSION_STARTED=1; SECONDS=100
  . "$SCRIPTS/auth-heal.sh"
  auth_heal_step                      # valid
  echo 1 > "$AUTHSTUB_CTL/rc"
  auth_heal_step                      # escalate + alert #1
  auth_heal_step; auth_heal_step; auth_heal_step   # escalated re-checks — cooldown musn't re-send
) > "$SCRATCH/t9.log" 2>&1
cc="$(CURL_RECORD_DIR="$R/curl" curl_count)"
[ "$cc" = "1" ] && ok "cooldown holds: 1 alert across 4 escalated polls" || bad "cooldown broke: $cc alerts"
(
  scenario_env "$R"
  set -euo pipefail
  export KICKOFF_AUTH_HEAL=1 KICKOFF_AUTH_CHECK_CMD="$FIXBIN/authstub" \
         KICKOFF_AUTH_CHECK_INTERVAL=0 KICKOFF_AUTH_RECHECK_INTERVAL=0 \
         KICKOFF_AUTH_FAILS_TO_ESCALATE=1 KICKOFF_AUTH_ALERT_COOLDOWN=0 \
         KICKOFF_AUTH_EARLY_DEATH_SECONDS=0
  session_alive() { return 0; }
  SESSION_STARTED=1; SECONDS=100
  . "$SCRIPTS/auth-heal.sh"
  auth_heal_step; auth_heal_step      # still escalated + expired → reminder each poll
) > "$SCRATCH/t9b.log" 2>&1
cc2="$(CURL_RECORD_DIR="$R/curl" curl_count)"
[ "$cc2" -gt "$cc" ] && ok "cooldown=0 re-alerts while still broken (reminder path)" || bad "no reminder with cooldown=0 ($cc → $cc2)"

# ══════════════════════════════════════════════════════════════════════════════
section "T10 wait-and-auto-resume: valid again → flag cleared + refresh touched"
R="$(new_fixture t10)"
(
  scenario_env "$R"
  set -euo pipefail
  export KICKOFF_AUTH_HEAL=1 KICKOFF_AUTH_CHECK_CMD="$FIXBIN/authstub" \
         KICKOFF_AUTH_CHECK_INTERVAL=0 KICKOFF_AUTH_RECHECK_INTERVAL=0 \
         KICKOFF_AUTH_FAILS_TO_ESCALATE=1 KICKOFF_AUTH_ALERT_COOLDOWN=99999 \
         KICKOFF_AUTH_EARLY_DEATH_SECONDS=0
  session_alive() { return 0; }
  SESSION_STARTED=1; SECONDS=100
  . "$SCRIPTS/auth-heal.sh"
  auth_heal_step                      # valid → EVER_OK
  echo 1 > "$AUTHSTUB_CTL/rc"
  auth_heal_step                      # escalate
  [ -f "$KICKOFF_DIR/auth-escalated" ] || exit 9
  echo 0 > "$AUTHSTUB_CTL/rc"         # operator fixed auth (relogin.sh / new login)
  auth_heal_step                      # → auto-resume
) > "$SCRATCH/t10.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ ! -f "$R/.kickoff/auth-escalated" ] && ok "flag cleared the moment auth is valid" || bad "auto-resume failed (rc=$rc)"
[ -f "$R/.kickoff/refresh-requested" ] && ok "refresh flag touched (restart via the existing PGID-safe path)" || bad "refresh flag not touched"
[ "$(state_get "$R" RESUME_COUNT)" = "1" ] && ok "resume counted (RESUME_COUNT=1)" || bad "RESUME_COUNT=$(state_get "$R" RESUME_COUNT)"
[ "$(CURL_RECORD_DIR="$R/curl" curl_count)" = "1" ] && ok "no extra alert on resume (announce covers it)" || bad "resume sent an alert"

# ══════════════════════════════════════════════════════════════════════════════
section "T11 resume cap: after K failed recoveries, wait for relogin"
R="$(new_fixture t11)"
(
  scenario_env "$R"
  set -euo pipefail
  export KICKOFF_AUTH_HEAL=1 KICKOFF_AUTH_CHECK_CMD="$FIXBIN/authstub" \
         KICKOFF_AUTH_CHECK_INTERVAL=0 KICKOFF_AUTH_RECHECK_INTERVAL=0 \
         KICKOFF_AUTH_FAILS_TO_ESCALATE=1 KICKOFF_AUTH_ALERT_COOLDOWN=0 \
         KICKOFF_AUTH_MAX_AUTO_RESUMES=1 KICKOFF_AUTH_EARLY_DEATH_SECONDS=0
  session_alive() { return 0; }
  SESSION_STARTED=1; SECONDS=100
  . "$SCRIPTS/auth-heal.sh"
  auth_heal_step                          # valid (EVER_OK; RESUME_COUNT reset)
  echo 1 > "$AUTHSTUB_CTL/rc"; auth_heal_step        # escalate #1
  echo 0 > "$AUTHSTUB_CTL/rc"; auth_heal_step        # resume #1 (cap reached)
  rm -f "$KICKOFF_DIR/refresh-requested"
  echo 1 > "$AUTHSTUB_CTL/rc"; auth_heal_step        # flaps: re-escalate
  echo 0 > "$AUTHSTUB_CTL/rc"; auth_heal_step        # valid again — but cap says WAIT
  [ -f "$KICKOFF_DIR/auth-escalated" ] || exit 9     # must STILL be escalated
  [ ! -f "$KICKOFF_DIR/refresh-requested" ] || exit 8
) > "$SCRATCH/t11.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "auto-resume capped after K=1 failed recovery (flag stays, no refresh)" || bad "resume cap broken (rc=$rc): $(tail -3 "$SCRATCH/t11.log")"
grep -qi "capped" "$SCRATCH/t11.log" && ok "cap is logged for the operator" || bad "cap not logged"

# ══════════════════════════════════════════════════════════════════════════════
section "T12 D2 exit-loop: N early deaths escalate (probe disabled → backstop mode)"
R="$(new_fixture t12)"
(
  scenario_env "$R"
  set -euo pipefail
  export KICKOFF_AUTH_HEAL=1 KICKOFF_AUTH_CHECK_CMD="none" \
         KICKOFF_AUTH_EARLY_DEATH_SECONDS=60 KICKOFF_AUTH_EARLY_DEATHS_TO_ESCALATE=3 \
         KICKOFF_AUTH_ALERT_COOLDOWN=99999
  T_ALIVE=0
  session_alive() { [ "${T_ALIVE:-1}" = "1" ]; }
  SECONDS=1000
  SESSION_STARTED=990;  auth_heal_step_wrap() { auth_heal_step; }
  . "$SCRIPTS/auth-heal.sh"
  auth_heal_step                          # death 1 (age 10 < 60)
  auth_heal_step                          # SAME spawn seen again → must NOT double-count
  SESSION_STARTED=1005; SECONDS=1010; auth_heal_step    # death 2
  [ -f "$KICKOFF_DIR/auth-escalated" ] && exit 9        # not yet (2/3)
  SESSION_STARTED=1020; SECONDS=1030; auth_heal_step    # death 3 → escalate
) > "$SCRATCH/t12.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ -f "$R/.kickoff/auth-escalated" ] && ok "3 distinct early deaths escalate (D2)" || bad "D2 escalation failed (rc=$rc): $(tail -3 "$SCRATCH/t12.log")"
grep -q "exit-loop D2" "$R/.kickoff/auth-escalated" 2>/dev/null && ok "flag names the D2 reason" || bad "flag reason wrong"
grep -c "early-death streak 1/3" "$SCRATCH/t12.log" | grep -q '^1$' && ok "same dead spawn counted once (dedupe)" || bad "dedupe failed: $(grep -c 'early-death streak 1/3' "$SCRATCH/t12.log")x streak-1 lines"

# ══════════════════════════════════════════════════════════════════════════════
section "T13 D2 veto: crash-loop with VALID auth does NOT escalate"
R="$(new_fixture t13)"
(
  scenario_env "$R"
  set -euo pipefail
  export KICKOFF_AUTH_HEAL=1 KICKOFF_AUTH_CHECK_CMD="$FIXBIN/authstub" \
         KICKOFF_AUTH_CHECK_INTERVAL=99999 \
         KICKOFF_AUTH_EARLY_DEATH_SECONDS=60 KICKOFF_AUTH_EARLY_DEATHS_TO_ESCALATE=2
  T_ALIVE=0
  session_alive() { [ "${T_ALIVE:-1}" = "1" ]; }
  SECONDS=1000; SESSION_STARTED=995
  . "$SCRIPTS/auth-heal.sh"
  auth_heal_step                                        # death 1
  SESSION_STARTED=1005; SECONDS=1010; auth_heal_step    # death 2 → streak hits N → probe says VALID → veto
) > "$SCRATCH/t13.log" 2>&1
[ ! -f "$R/.kickoff/auth-escalated" ] && ok "valid probe VETOES the D2 escalation (non-auth crash-loop left alone)" || bad "D2 escalated despite valid auth"
grep -q "NOT escalating" "$SCRATCH/t13.log" && ok "veto is logged" || bad "veto not logged"
[ "$(state_get "$R" D2_STREAK)" = "0" ] && ok "streak reset after veto" || bad "streak not reset: $(state_get "$R" D2_STREAK)"

# ══════════════════════════════════════════════════════════════════════════════
section "T14 D2 survivor reset: a session outliving T clears the streak"
R="$(new_fixture t14)"
(
  scenario_env "$R"
  set -euo pipefail
  export KICKOFF_AUTH_HEAL=1 KICKOFF_AUTH_CHECK_CMD="none" \
         KICKOFF_AUTH_EARLY_DEATH_SECONDS=60 KICKOFF_AUTH_EARLY_DEATHS_TO_ESCALATE=3
  T_ALIVE=0
  session_alive() { [ "${T_ALIVE:-1}" = "1" ]; }
  SECONDS=1000; SESSION_STARTED=995
  . "$SCRIPTS/auth-heal.sh"
  auth_heal_step                                        # death 1
  SESSION_STARTED=1005; SECONDS=1010; auth_heal_step    # death 2 (streak 2)
  T_ALIVE=1; SESSION_STARTED=1020; SECONDS=1100; auth_heal_step   # survivor (age 80 ≥ 60) → reset
) > "$SCRATCH/t14.log" 2>&1
[ "$(state_get "$R" D2_STREAK)" = "0" ] && ok "survivor resets the early-death streak" || bad "streak survived a healthy session: $(state_get "$R" D2_STREAK)"
[ ! -f "$R/.kickoff/auth-escalated" ] && ok "and no flag" || bad "flag appeared"

# ══════════════════════════════════════════════════════════════════════════════
section "T15 DRY_RUN: evaluates + logs intent, mutates NOTHING"
R="$(new_fixture t15)"
echo 1 > "$R/ctl/rc"
printf 'SUP_PID=%s\nEVER_OK=1\n' "$$" > "$R/.kickoff/auth-heal.state"
before="$(cat "$R/.kickoff/auth-heal.state")"
(
  scenario_env "$R"
  set -euo pipefail
  export DRY_RUN=1
  export KICKOFF_AUTH_HEAL=1 KICKOFF_AUTH_CHECK_CMD="$FIXBIN/authstub" \
         KICKOFF_AUTH_CHECK_INTERVAL=0 KICKOFF_AUTH_FAILS_TO_ESCALATE=1 \
         KICKOFF_AUTH_EARLY_DEATH_SECONDS=0
  session_alive() { return 0; }
  SESSION_STARTED=1; SECONDS=100
  . "$SCRIPTS/auth-heal.sh"
  auth_heal_step
) > "$SCRATCH/t15.log" 2>&1
grep -q "DRY_RUN — would ESCALATE" "$SCRATCH/t15.log" && ok "DRY_RUN logs the would-escalate intent" || bad "DRY_RUN intent not logged: $(cat "$SCRATCH/t15.log")"
[ ! -f "$R/.kickoff/auth-escalated" ] && ok "DRY_RUN writes no flag" || bad "DRY_RUN wrote the flag"
[ "$(CURL_RECORD_DIR="$R/curl" curl_count)" = "0" ] && ok "DRY_RUN sends nothing" || bad "DRY_RUN sent an alert"
[ "$(cat "$R/.kickoff/auth-heal.state")" = "$before" ] && ok "DRY_RUN leaves state byte-identical" || bad "DRY_RUN mutated state"

# ══════════════════════════════════════════════════════════════════════════════
section "T16 disarm reverts: stale flag cleared, stock behavior restored"
R="$(new_fixture t16)"
printf '%s\nstale reason\n' "$(date -u +%FT%TZ)" > "$R/.kickoff/auth-escalated"
(
  scenario_env "$R"
  set -euo pipefail
  session_alive() { return 0; }
  SESSION_STARTED=1; SECONDS=10
  . "$SCRIPTS/auth-heal.sh"
  auth_heal_step
) > "$SCRATCH/t16.log" 2>&1
[ ! -f "$R/.kickoff/auth-escalated" ] && ok "disarmed step clears a stale escalation flag" || bad "stale flag survived disarm — would gate restarts forever"

# ══════════════════════════════════════════════════════════════════════════════
section "T17 config via instance.env (whitelist import; env wins)"
R="$(new_fixture t17)"
printf 'export KICKOFF_AUTH_HEAL=1\nexport KICKOFF_AUTH_CHECK_CMD="%s"\nexport KICKOFF_AUTH_CHECK_INTERVAL=0\n' "$FIXBIN/authstub" > "$R/.kickoff/instance.env"
(
  scenario_env "$R"
  set -euo pipefail
  session_alive() { return 0; }
  SESSION_STARTED=1; SECONDS=10
  . "$SCRIPTS/auth-heal.sh"
  auth_heal_step
) > "$SCRATCH/t17.log" 2>&1
[ "$(state_get "$R" EVER_OK)" = "1" ] && ok "armed via instance.env (whitelist import works)" || bad "instance.env arming failed"
(
  scenario_env "$R"
  set -euo pipefail
  export KICKOFF_AUTH_HEAL=0            # pre-set env must WIN over the file
  session_alive() { return 0; }
  SESSION_STARTED=1; SECONDS=10
  . "$SCRIPTS/auth-heal.sh"
  rm -f "$KICKOFF_DIR/auth-heal.state"
  auth_heal_step
) > "$SCRATCH/t17b.log" 2>&1
[ ! -f "$R/.kickoff/auth-heal.state" ] && ok "pre-set env (HEAL=0) wins over instance.env (HEAL=1)" || bad "file overrode the environment"

# ══════════════════════════════════════════════════════════════════════════════
section "T18 default probe cmd resolves to: claude auth status --json"
R="$(new_fixture t18)"
(
  scenario_env "$R"
  set -euo pipefail
  export KICKOFF_AUTH_HEAL=1 KICKOFF_AUTH_CHECK_INTERVAL=0    # CHECK_CMD deliberately unset
  session_alive() { return 0; }
  SESSION_STARTED=1; SECONDS=10
  . "$SCRIPTS/auth-heal.sh"
  auth_heal_step
) > "$SCRATCH/t18.log" 2>&1
[ "$(cat "$R/claude.argv" 2>/dev/null)" = "auth status --json" ] && ok "default cmd is exactly 'claude auth status --json' (fake claude intercepted it)" || bad "default cmd wrong: '$(cat "$R/claude.argv" 2>/dev/null)'"
[ "$(state_get "$R" EVER_OK)" = "1" ] && ok "default cmd verdict parsed as valid" || bad "default cmd verdict failed"

# ══════════════════════════════════════════════════════════════════════════════
section "T19 malformed knobs degrade to defaults (never to a crash)"
R="$(new_fixture t19)"
(
  scenario_env "$R"
  set -euo pipefail
  export KICKOFF_AUTH_HEAL=1 KICKOFF_AUTH_CHECK_CMD="$FIXBIN/authstub" \
         KICKOFF_AUTH_CHECK_INTERVAL="abc" KICKOFF_AUTH_FAILS_TO_ESCALATE="-2" \
         KICKOFF_AUTH_ALERT_COOLDOWN="1e9" KICKOFF_AUTH_EARLY_DEATH_SECONDS="sixty"
  session_alive() { return 0; }
  SESSION_STARTED=1; SECONDS=10
  . "$SCRIPTS/auth-heal.sh"
  auth_heal_step; auth_heal_step
) > "$SCRATCH/t19.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ -f "$R/.kickoff/auth-heal.state" ] && ok "garbage knobs: step completes + state written (defaults applied)" || bad "garbage knobs broke the step (rc=$rc)"

# ══════════════════════════════════════════════════════════════════════════════
section "T20 structural armor: subshell absorbs a set -u unbound-var bug"
(
  set -euo pipefail
  buggy() { ( echo "$THIS_VAR_IS_UNBOUND_XYZ" ) || true; return 0; }
  buggy
  echo "ARMOR-HELD" > "$SCRATCH/t20.marker"
) >/dev/null 2>&1
[ -f "$SCRATCH/t20.marker" ] && ok "the '( body ) || true' pattern survives an unbound-var bug (same armor as auth_heal_step)" || bad "subshell armor failed on this bash"
grep -q '( _auth_heal_main ) || true' "$SCRIPTS/auth-heal.sh" && ok "auth_heal_step actually uses the subshell armor" || bad "auth_heal_step is NOT subshell-armored"

# ══════════════════════════════════════════════════════════════════════════════
section "T21 probe imports the relogin token from .kickoff/auth.env"
R="$(new_fixture t21)"
printf 'export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-FAKETESTTOKEN123456\n' > "$R/.kickoff/auth.env"
(
  scenario_env "$R"
  set -euo pipefail
  export KICKOFF_AUTH_HEAL=1 KICKOFF_AUTH_CHECK_CMD="$FIXBIN/tokecho" KICKOFF_AUTH_CHECK_INTERVAL=0
  session_alive() { return 0; }
  SESSION_STARTED=1; SECONDS=10
  . "$SCRIPTS/auth-heal.sh"
  auth_heal_step
) > "$SCRATCH/t21.log" 2>&1
[ "$(state_get "$R" EVER_OK)" = "1" ] && ok "probe env carried the auth.env token (worker-consistent verdicts)" || bad "auth.env token did not reach the probe"
grep -q "FAKETESTTOKEN" "$SCRATCH/t21.log" && bad "TOKEN LEAKED into the step log" || ok "token never appears in the step log"

# ══════════════════════════════════════════════════════════════════════════════
section "T22 relogin.sh turnkey (fixture; stubbed probe; no real claude)"
R="$(new_fixture t22)"
printf '%s\nauth probe failed 2x (D3)\n' "$(date -u +%FT%TZ)" > "$R/.kickoff/auth-escalated"
out="$(
  scenario_env "$R"
  export KICKOFF_AUTH_CHECK_CMD="$FIXBIN/authstub"
  CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-FAKETESTTOKEN123456" bash "$SCRIPTS/relogin.sh" 2>&1
)"; rc=$?
[ "$rc" -eq 0 ] && ok "relogin (env token, valid probe) exits 0" || bad "relogin rc=$rc: $out"
[ -f "$R/.kickoff/auth.env" ] && ok "auth.env written" || bad "auth.env missing"
[ "$(stat -c '%a' "$R/.kickoff/auth.env" 2>/dev/null)" = "600" ] && ok "auth.env is 0600" || bad "auth.env perms: $(stat -c '%a' "$R/.kickoff/auth.env" 2>/dev/null)"
grep -q "FAKETESTTOKEN123456" "$R/.kickoff/auth.env" && ok "token persisted (printf %q round-trip)" || bad "token not in auth.env"
[ ! -f "$R/.kickoff/auth-escalated" ] && ok "escalation flag cleared" || bad "flag not cleared"
[ -f "$R/.kickoff/refresh-requested" ] && ok "refresh flag touched (supervisor auto-resumes)" || bad "refresh flag not touched"
grep -q "supervisor is NOT running" <<<"$out" && ok "prints the next action (start the supervisor)" || bad "next action missing"

R="$(new_fixture t22b)"
printf '%s\nauth probe failed 2x (D3)\n' "$(date -u +%FT%TZ)" > "$R/.kickoff/auth-escalated"
echo 1 > "$R/ctl/rc"
out="$(
  scenario_env "$R"
  export KICKOFF_AUTH_CHECK_CMD="$FIXBIN/authstub"
  CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-STILLBADTOKEN9999999" bash "$SCRIPTS/relogin.sh" 2>&1
)"; rc=$?
[ "$rc" -eq 2 ] && ok "bad token → verify fails → rc 2 (honest red)" || bad "bad-token rc=$rc (want 2)"
[ -f "$R/.kickoff/auth-escalated" ] && ok "flag NOT cleared on a failed verify" || bad "flag cleared despite failed verify"
[ ! -f "$R/.kickoff/refresh-requested" ] && ok "no refresh on a failed verify" || bad "refresh touched despite failed verify"

R="$(new_fixture t22c)"
out="$(
  scenario_env "$R"
  bash "$SCRIPTS/relogin.sh" "sk-ant-oat01-ARGV-LEAKED-TOKEN-123" 2>&1
)"; rc=$?
[ "$rc" -ne 0 ] && grep -qi "never pass the token" <<<"$out" && ok "token on argv is REFUSED (leak guard)" || bad "argv token accepted?! rc=$rc"
[ ! -f "$R/.kickoff/auth.env" ] && ok "argv refusal changed nothing" || bad "argv refusal still wrote auth.env"

out="$(
  scenario_env "$R"
  printf 'export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-FAKETESTTOKEN123456\n' > "$R/.kickoff/auth.env"
  bash "$SCRIPTS/relogin.sh" --clear 2>&1
)"
[ ! -f "$R/.kickoff/auth.env" ] && [ -f "$R/.kickoff/auth.env.prev" ] && ok "--clear removes auth.env (backup kept)" || bad "--clear failed: $out"
out="$(
  scenario_env "$R"
  export KICKOFF_AUTH_CHECK_CMD="$FIXBIN/authstub"
  bash "$SCRIPTS/relogin.sh" --status 2>&1
)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "auth probe:" <<<"$out" && ok "--status reports (no secrets shown)" || bad "--status rc=$rc"

# ══════════════════════════════════════════════════════════════════════════════
section "T23 install-auth-heal.sh on FIXTURE copies (never the live files)"
IF="$SCRATCH/installfix"; mkdir -p "$IF/scripts" "$IF/.kickoff"
# pristine supervisor/session-run (the retrofit target) + the REAL auth-heal.sh the wiring sources
cp -p "$PRISTINE/supervisor.sh" "$PRISTINE/session-run.sh" "$IF/scripts/"
cp -p "$SCRIPTS/auth-heal.sh" "$IF/scripts/"
sup0="$(sha256sum "$IF/scripts/supervisor.sh" | cut -d' ' -f1)"
run0="$(sha256sum "$IF/scripts/session-run.sh" | cut -d' ' -f1)"

out="$(KICKOFF_INSTALL_TARGET_DIR="$IF/scripts" bash "$SCRIPTS/install-auth-heal.sh" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "dry-run exits 0" || bad "dry-run rc=$rc: $(tail -5 <<<"$out")"
grep -q "would apply" <<<"$out" && ok "dry-run stages all edits" || bad "dry-run staged nothing"
[ "$(sha256sum "$IF/scripts/supervisor.sh" | cut -d' ' -f1)" = "$sup0" ] && ok "dry-run leaves supervisor.sh byte-identical" || bad "DRY-RUN MUTATED supervisor.sh"
[ "$(sha256sum "$IF/scripts/session-run.sh" | cut -d' ' -f1)" = "$run0" ] && ok "dry-run leaves session-run.sh byte-identical" || bad "DRY-RUN MUTATED session-run.sh"

out="$(KICKOFF_INSTALL_TARGET_DIR="$IF/scripts" KICKOFF_INSTALL_NO_SELFTEST=1 bash "$SCRIPTS/install-auth-heal.sh" --apply 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "--apply exits 0" || bad "--apply rc=$rc: $(tail -5 <<<"$out")"
grep -q 'auth_heal_step || true' "$IF/scripts/supervisor.sh" && ok "S2 landed (auth_heal_step per poll)" || bad "S2 missing"
grep -q 'auth-escalated' "$IF/scripts/supervisor.sh" && ok "S3 landed (trigger-3 gate)" || bad "S3 missing"
grep -q 'FASTDEATH_STREAK=0' "$IF/scripts/supervisor.sh" && ok "S0 landed (crash-loop circuit-breaker globals)" || bad "S0 missing (FASTDEATH_* globals)"
grep -q 'crash-looping' "$IF/scripts/supervisor.sh" && ok "S3 landed the crash-loop circuit-breaker body (#1 + #8)" || bad "S3 circuit-breaker body missing"
# S4 retrofits refresh() to reset the streak. RED-on-old: this asserts the reset is INSIDE
# refresh() (S0 also injects FASTDEATH_STREAK=0 but into the GLOBALS, so a plain file-wide grep
# would false-pass without S4) — extract just the refresh() body and look there.
rf_of() { awk '/^refresh\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$1"; }
rf_of "$IF/scripts/supervisor.sh" | grep -q 'FASTDEATH_STREAK=0' && ok "S4 landed: retrofitted refresh() resets FASTDEATH_STREAK" || bad "S4 missing: refresh() carries no streak reset (stale streak survives a refresh)"
rf_of "$IF/scripts/supervisor.sh" | grep -q 'announce.count' && ok "S4 landed: refresh() zeroes announce.count too" || bad "S4 missing: refresh() does not reset announce.count"
# finding #2 LONG-OUTAGE RE-ALARM retrofit landed. RED-on-old: a pre-re-alarm installer injects NONE
# of these, so each assertion FAILS if the S0/S3/S4 re-alarm additions are absent (proven separately).
cad_of() { awk '/^crashloop_alarm_due\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$1"; }
# tok_of: the REAL tg_send_tokenless (the alarm sender trigger-3 now calls). Same zero-drift
# rationale as cad_of: extract the live definition and drive the TRUE send — the fixtures carry a
# real token/chat (new_fixture), the fake curl records what the sender actually does, so the
# argv/stdin assertions below keep their exact meaning against the real sender, not a stub.
tok_of() { awk '/^tg_send_tokenless\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$1"; }
t3_of() { awk '/^  if ! session_alive && \[ ! -f "\$KICKOFF_DIR\/auth-escalated" \]; then$/{f=1} f{print} f&&/^  fi$/{exit}' "$1"; }
grep -q 'FASTDEATH_REALARM_EVERY=' "$IF/scripts/supervisor.sh" && ok "re-alarm #2: S0 injects the FASTDEATH_REALARM_EVERY global" || bad "re-alarm #2 MISSING: no FASTDEATH_REALARM_EVERY global (S0)"
t3_of "$IF/scripts/supervisor.sh" | grep -q 'if crashloop_alarm_due ' && ok "re-alarm #2: S3 trigger-3 alarm gate is crashloop_alarm_due (bounded re-fire, not once-only)" || bad "re-alarm #2 MISSING: trigger-3 still uses the once-only -eq gate"
rf_of "$IF/scripts/supervisor.sh" | grep -q 'FASTDEATH_LAST_ALARM_STREAK=0' && ok "re-alarm #2: S4 refresh() clears the re-alarm bookmark" || bad "re-alarm #2 MISSING: refresh() does not reset FASTDEATH_LAST_ALARM_STREAK"
# S3's gate CALLS crashloop_alarm_due, so the retrofit MUST also DEFINE it (S3d) — else a fast death
# aborts the supervisor on command-not-found. Assert it is defined AND byte-identical to the core.
grep -q '^crashloop_alarm_due() {' "$IF/scripts/supervisor.sh" && ok "re-alarm #2: S3d defines crashloop_alarm_due() in the retrofit (S3's gate can't dangle)" || bad "re-alarm #2 MISSING: crashloop_alarm_due CALLED but never DEFINED — retrofit would abort on a fast death"
{ [ -n "$(cad_of "$IF/scripts/supervisor.sh")" ] && [ "$(cad_of "$IF/scripts/supervisor.sh")" = "$(cad_of "$SCRIPTS/supervisor.sh")" ]; } && ok "CAD twin: injected crashloop_alarm_due() byte-identical to live supervisor.sh" || bad "CAD twin DRIFT: injected crashloop_alarm_due != live"
grep -q 'AUTH_ENV=' "$IF/scripts/session-run.sh" && ok "R1 landed (auth.env import)" || bad "R1 missing"
grep -q 'org is cooking on' "$IF/scripts/session-run.sh" && ok "R2 landed (meaningful announce)" || bad "R2 missing"
bash -n "$IF/scripts/supervisor.sh" && bash -n "$IF/scripts/session-run.sh" && ok "patched fixtures parse (bash -n)" || bad "patched fixtures broken"
# TWIN LOCKSTEP: the installer's S0/S3/S4 must reproduce the LIVE supervisor.sh's crash-loop
# circuit-breaker + finding #2 re-alarm byte-for-byte, so a retrofit == the shipped core for the
# family it retrofits. Extract each block and compare (patched fixture vs live).
#
# SCOPE FILTER (strip_bridge): the installer deliberately does NOT retrofit BRIDGE-LIVENESS
# (finding #3), the v0.6 fail-loud boot-grace belt, the v0.7 G1 slice-5 ENGINE HOP, or the v0.8
# MODEL-QUOTA FALLBACK belt — the BRIDGE_* / BRIDGE_BOOT_* / MODEL_FALLBACK_* globals, the
# bridge-* refresh reset, and the engine_hop_boundary
# session-boundary hooks ship ONLY in the baked core (adopters get them via `kickoff pull`;
# retrofitting the hop CALL without the hop UNIT would spray command-not-found at every
# boundary). So the LIVE globals + refresh() + trigger-3 carry lines the installer never
# injects. strip_bridge drops EXACTLY those lines from BOTH sides before the
# byte-compare, so each twin asserts "the installer reproduces the core's circuit-breaker+re-alarm
# byte-for-byte, IGNORING the separately-shipped bridge-liveness + engine-hop + model-fallback
# features." It is a
# PRECISE filter (specific comment-block heads + the BRIDGE_ token + the bridge-* reset line +
# the two hop comment-blocks/calls + the one model-fallback globals block), NOT a blunt "drop
# anything mentioning bridge/hop/model": a
# mutation to any circuit-breaker/re-alarm line survives it and still
# trips the twin (proven by the mutation test below), so the filter never guts drift-catching.
# trigger-3 gained the slice-5 hop hook, so t3_of is now compared THROUGH the same filter
# (pre-slice-5 it was a direct byte-compare; the filter drops only the hop lines there).
#
# v0.8 model-fallback is the SAME CATEGORY as bridge-liveness, and the check is that it is
# core-only END-TO-END: install-auth-heal.sh injects NO model_fallback_step UNIT, NO call site,
# and therefore must inject NO MODEL_FALLBACK_* globals either — retrofitting inert config for a
# belt the retrofit never installs would be dead weight that re-drifts on the next belt edit.
# (Asserted below: the installer mentions MODEL_FALLBACK nowhere. If that EVER changes, this
# filter clause is what must be revisited — the twin is only allowed to ignore what the installer
# genuinely does not ship.)
strip_bridge() {
  awk '
    /^# bridge-liveness \(finding #3\):/ { b=1 }                  # globals: bridge comment head ...
    b { if (/^BRIDGE_RESPAWN_GIVEUP=/) b=0; next }                #   ... through the last BRIDGE_ global (one block)
    /^# v0\.6 fail-loud \(the never-came-up gap\):/ { d=1 }       # globals: v0.6 boot-grace comment head ...
    d { if (/^BRIDGE_BOOT_DEAF_SINCE=/) d=0; next }               #   ... through the last BRIDGE_BOOT_ global (one block; v0.9 moved the terminator off the deleted BRIDGE_BOOT_GIVEUP)
    /^# v0\.8 model-quota fallback \(the "alive but cannot think" gap\):/ { m=1 }  # globals: v0.8 model-fallback head ...
    m { if (/^case "\$MODEL_FALLBACK_WINDOW_SECONDS"/) m=0; next }                 #   ... through the last MODEL_FALLBACK_ global (one block)
    /^  # bridge-liveness \+ re-alarm bookkeeping/ { c=1; next }  # refresh(): bridge+re-alarm comment head ...
    c && /^  #/ { next }                                          #   ... its contiguous comment body
    c { c=0 }                                                     #   ... first non-comment line ends it (and prints)
    /^  # \(v0\.6: the non-bridge arm/ { e=1; next }              # refresh(): v0.6 boot-reset comment head ...
    e && /^  #/ { next }                                          #   ... its contiguous comment body
    e { e=0 }                                                     #   ... first non-comment line ends it (and prints)
    /^  case "\$why" in bridge-/ { next }                         # refresh(): the bridge-only streak-reset line (v0.5+v0.6)
    /^  # v0\.7 G1 slice 5: the session boundary IS the hop point/ { g=1; next }   # refresh(): hop comment head ...
    g && /^  #/ { next }                                          #   ... its contiguous comment body
    g { g=0 }                                                     #   ... first non-comment line ends it (and prints)
    /^    # v0\.7 G1 slice 5: a natural session death is ALSO a session boundary/ { h=1; next }  # trigger-3: hop comment head ...
    h && /^    #/ { next }                                        #   ... its contiguous comment body
    h { h=0 }                                                     #   ... first non-comment line ends it (and prints)
    /^ *engine_hop_boundary \|\| true$/ { next }                  # the hop call itself (both boundary sites)
    { print }
  '
}
t3_of() { awk '/^  if ! session_alive && \[ ! -f "\$KICKOFF_DIR\/auth-escalated" \]; then$/{f=1} f{print} f&&/^  fi$/{exit}' "$1"; }
gl_of() { awk '/^RESTART_BACKOFF_SECONDS="\$\{RESTART_BACKOFF_SECONDS:-5\}"/{f=1} f{print} /^DRY_RUN=/{if(f)exit}' "$1"; }
[ "$(gl_of "$IF/scripts/supervisor.sh" | strip_bridge)" = "$(gl_of "$SCRIPTS/supervisor.sh" | strip_bridge)" ] && ok "S0 twin: patched globals == live circuit-breaker+re-alarm (bridge-liveness filtered)" || bad "S0 twin DRIFT: installer globals != live supervisor.sh (circuit-breaker+re-alarm)"
# FILTER HONESTY GUARD: strip_bridge is only ENTITLED to ignore the model-fallback globals for as
# long as the installer ships NO part of that belt. The moment install-auth-heal.sh learns to
# retrofit model-fallback, ignoring its globals would hide a REAL twin gap (globals retrofitted
# without the unit, or the unit without its globals) — so fail loudly here and force the filter
# clause to be revisited, rather than letting the scope filter quietly rot into a blind spot.
# `[ -r … ]` FIRST: `grep -q PAT /nonexistent` exits 2, and `!` inverts that to TRUE — so without the
# readability test this guard would print a happy ✓ about a file it never opened (a vacuous pass).
[ -r "$SCRIPTS/install-auth-heal.sh" ] && ! grep -q 'MODEL_FALLBACK\|model_fallback' "$SCRIPTS/install-auth-heal.sh" && ok "filter honesty: installer ships NO model-fallback (so S0 may ignore its core-only globals)" || bad "filter honesty BROKEN (or install-auth-heal.sh is unreadable): strip_bridge must stop ignoring MODEL_FALLBACK_* globals"
[ "$(t3_of "$IF/scripts/supervisor.sh" | strip_bridge)" = "$(t3_of "$SCRIPTS/supervisor.sh" | strip_bridge)" ] && ok "S3 twin: patched trigger-3 block == live supervisor.sh (core-only hop lines filtered)" || bad "S3 twin DRIFT: installer trigger-3 != live supervisor.sh"
# S3t: the trigger-3 body CALLS tg_send_tokenless, and a pre-bridge retrofit target does not define
# it — the installer must ship the parse-time-guarded fallback or the first alarm aborts (set -e).
grep -q '^if ! command -v tg_send_tokenless >/dev/null 2>&1; then' "$IF/scripts/supervisor.sh" \
  && ok "S3t: a parse-time-guarded tg_send_tokenless fallback ships (the alarm call resolves on a pre-bridge core; a real sender is never shadowed)" \
  || bad "S3t MISSING or wrong shape: retrofitted supervisor calls tg_send_tokenless with no guaranteed definition — first alarm aborts under set -e"
[ "$(rf_of "$IF/scripts/supervisor.sh" | strip_bridge)" = "$(rf_of "$SCRIPTS/supervisor.sh" | strip_bridge)" ] && ok "S4 twin: retrofitted refresh() == live reset (bridge-liveness + hop filtered)" || bad "S4 twin DRIFT: installer refresh() != live supervisor.sh"
bdir="$(ls -1d "$IF/.kickoff/backups"/auth-heal-* 2>/dev/null | tail -1)"
[ -n "$bdir" ] && [ "$(sha256sum "$bdir/supervisor.sh" | cut -d' ' -f1)" = "$sup0" ] && ok "backup byte-matches the pre-apply original" || bad "backup wrong/missing"

sup1="$(sha256sum "$IF/scripts/supervisor.sh" | cut -d' ' -f1)"
out="$(KICKOFF_INSTALL_TARGET_DIR="$IF/scripts" KICKOFF_INSTALL_NO_SELFTEST=1 bash "$SCRIPTS/install-auth-heal.sh" --apply 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "already applied" <<<"$out" && ok "second --apply is idempotent (already applied)" || bad "idempotency broke: rc=$rc"
[ "$(sha256sum "$IF/scripts/supervisor.sh" | cut -d' ' -f1)" = "$sup1" ] && ok "second --apply changes nothing" || bad "second --apply mutated the file"
[ "$(grep -c 'A deliberate refresh (degradation flag / cadence)' "$IF/scripts/supervisor.sh")" = "1" ] && ok "S4 idempotent: exactly ONE refresh reset block after two applies" || bad "S4 duplicated/missing after two applies"

out="$(KICKOFF_INSTALL_TARGET_DIR="$IF/scripts" bash "$SCRIPTS/install-auth-heal.sh" --rollback 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "--rollback exits 0" || bad "--rollback rc=$rc: $(tail -3 <<<"$out")"
[ "$(sha256sum "$IF/scripts/supervisor.sh" | cut -d' ' -f1)" = "$sup0" ] && ok "rollback restores supervisor.sh byte-identically" || bad "rollback diverged (supervisor.sh)"
[ "$(sha256sum "$IF/scripts/session-run.sh" | cut -d' ' -f1)" = "$run0" ] && ok "rollback restores session-run.sh byte-identically" || bad "rollback diverged (session-run.sh)"

# drift-abort: a live file that no longer matches the anchors must be REFUSED untouched
ID="$SCRATCH/driftfix"; mkdir -p "$ID/scripts" "$ID/.kickoff"
cp -p "$PRISTINE/supervisor.sh" "$PRISTINE/session-run.sh" "$ID/scripts/"
sed -i 's/  rotate_log "\$SUPERVISOR_LOG"/  rotate_log "$SUPERVISOR_LOG"  # drifted/' "$ID/scripts/supervisor.sh"
d0="$(sha256sum "$ID/scripts/supervisor.sh" | cut -d' ' -f1)"
out="$(KICKOFF_INSTALL_TARGET_DIR="$ID/scripts" KICKOFF_INSTALL_NO_SELFTEST=1 bash "$SCRIPTS/install-auth-heal.sh" --apply 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "drifted anchor → --apply REFUSES (rc=$rc)" || bad "drifted anchor was applied anyway"
[ "$(sha256sum "$ID/scripts/supervisor.sh" | cut -d' ' -f1)" = "$d0" ] && ok "refusal left the drifted file untouched" || bad "refusal still wrote the file"

# pull-adopter guard: a core.lock repo must be refused
PL="$SCRATCH/pullfix"; mkdir -p "$PL/scripts" "$PL/.kickoff"
cp -p "$PRISTINE/supervisor.sh" "$PRISTINE/session-run.sh" "$PL/scripts/"
echo "lock" > "$PL/.kickoff/core.lock"
out="$(KICKOFF_INSTALL_TARGET_DIR="$PL/scripts" bash "$SCRIPTS/install-auth-heal.sh" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "core.lock" <<<"$out" && ok "pull-adopter repo (core.lock) is refused" || bad "core.lock repo not refused (rc=$rc)"

# ══════════════════════════════════════════════════════════════════════════════
section "T24 core manifest: the self-heal capability TRAVELS (R6)"
# supervisor.sh (wiring) sources auth-heal.sh and session-run.sh references relogin.sh — all three
# must be pinned in core-manifest.txt or an adopter's PULLED supervisor.sh dangles on a file the
# pull never delivered (ships the wiring but not the capability). install-auth-heal.sh is NOT
# expected to travel (adopters get the wiring pre-baked; it is a maintainer retrofit only).
MAN="$SCRIPTS/core-manifest.txt"
grep -qxF 'scripts/auth-heal.sh' "$MAN" && ok "core-manifest pins scripts/auth-heal.sh (capability travels)" || bad "auth-heal.sh MISSING from core-manifest — ships the wiring but not the capability"
grep -qxF 'scripts/relogin.sh'  "$MAN" && ok "core-manifest pins scripts/relogin.sh (recovery turnkey travels)" || bad "relogin.sh MISSING from core-manifest"

# ══════════════════════════════════════════════════════════════════════════════
section "T25 crash-loop circuit-breaker (findings #1 + #8): backoff growth + one alarm + survivor reset"
# Drives the REAL trigger-3 circuit-breaker block, extracted live from supervisor.sh (zero drift),
# through a fast-death streak then a survivor. Hermetic: fake curl (records argv+stdin, no network),
# the REAL crashloop_alarm_due + tg_send_tokenless extracted live (the gate AND the sender the
# block calls — the alarm path is driven end-to-end against the true send, not a stub), stubbed
# sleep/start_session/session_alive/engine_hop_boundary, its own mktemp fixture. Proves exponential
# backoff growth, ONE distinct tokenless alarm at the crossing, and that a normal-lifetime session
# resets BOTH the streak AND announce.count (so session-run's "restart #N" tracks the current bad
# streak).
R="$(new_fixture t25cb)"
cb_t3_of() { awk '/^  if ! session_alive && \[ ! -f "\$KICKOFF_DIR\/auth-escalated" \]; then$/{f=1} f{print} f&&/^  fi$/{exit}' "$1"; }
cb_t3_of "$SCRIPTS/supervisor.sh" > "$R/t3block.sh"
{ [ -s "$R/t3block.sh" ] && grep -q 'FASTDEATH_STREAK' "$R/t3block.sh"; } && ok "extracted the live trigger-3 circuit-breaker block (zero-drift harness)" || bad "could not extract the trigger-3 block"
# trigger-3 now CALLS crashloop_alarm_due (finding #2), defined ELSEWHERE in supervisor.sh (its bridge
# unit). Extract the REAL helper (zero drift) so the isolated block drives the TRUE gate, not a stub —
# and the first-alarm-at-crossing behavior is PRESERVED (crashloop_alarm_due returns true at ALARM_AT+1).
cad_of "$SCRIPTS/supervisor.sh" > "$R/cad.sh"
{ [ -s "$R/cad.sh" ] && grep -q '^crashloop_alarm_due() {' "$R/cad.sh"; } && ok "extracted the live crashloop_alarm_due gate (drives the REAL re-alarm, #2)" || bad "could not extract crashloop_alarm_due"
tok_of "$SCRIPTS/supervisor.sh" > "$R/tok.sh"
{ [ -s "$R/tok.sh" ] && grep -q '^tg_send_tokenless() {' "$R/tok.sh"; } && ok "extracted the live tg_send_tokenless sender (drives the REAL alarm send, not a stub)" || bad "could not extract tg_send_tokenless"
echo 7 > "$R/.kickoff/announce.count"     # seed non-zero to prove fast deaths do NOT reset it
(
  scenario_env "$R"
  set -euo pipefail                        # mirror the supervisor's shell opts (proves set -e/-u safety)
  RESTART_BACKOFF_SECONDS=5; RESTART_BACKOFF_CAP_SECONDS=1800
  FASTDEATH_THRESHOLD_SECONDS=60; FASTDEATH_ALARM_AT=3; FASTDEATH_STREAK=0
  FASTDEATH_REALARM_EVERY=12; FASTDEATH_LAST_ALARM_STREAK=0       # re-alarm knobs the extracted gate reads (#2)
  eval "$(cat "$R/cad.sh")"                                       # define the REAL crashloop_alarm_due in-harness
  eval "$(cat "$R/tok.sh")"                                       # …and the REAL tokenless sender the alarm calls
  SESSION_PGID="live"
  log() { :; }
  sleep() { printf '%s\n' "$1" >> "$KICKOFF_DIR/sleeps.log"; }          # capture backoff, never really sleep
  start_session() { SESSION_STARTED="$SECONDS"; printf 'x\n' >> "$KICKOFF_DIR/restarts.log"; }
  session_alive() { return 1; }                                        # dead each poll → drives trigger-3
  # the trigger-3 block ends at the session boundary (engine_hop_boundary → start_session): stub
  # it OBSERVABLY — the block MUST clear the boundary on every death (never wedge before it), so
  # its call count is asserted against the restart count below, not left as undefined-command noise.
  engine_hop_boundary() { printf 'x\n' >> "$KICKOFF_DIR/hops.log"; }
  blk="$(cat "$R/t3block.sh")"
  drive() {                                # $1 = simulated session lifetime (seconds)
    SECONDS=100000; SESSION_STARTED=$((SECONDS - $1))
    eval "$blk"
    printf '%s\n' "$FASTDEATH_STREAK" >> "$KICKOFF_DIR/streaks.log"
    printf '%s\n' "$(cat "$KICKOFF_DIR/announce.count" 2>/dev/null || echo MISSING)" >> "$KICKOFF_DIR/counts.log"
  }
  drive 10; drive 10; drive 10; drive 10; drive 10   # 5 fast deaths (crossing at streak #4)
  drive 100                                          # a survivor: resets streak + announce.count
  drive 10                                           # fast again (no fresh alarm — crossing already passed)
) > "$SCRATCH/t25cb.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "block runs clean under set -euo pipefail (no unbound var, no loop-abort)" || bad "block aborted rc=$rc: $(tail -5 "$SCRATCH/t25cb.log")"
sleeps="$(tr '\n' ' ' < "$R/.kickoff/sleeps.log" 2>/dev/null)"
[ "$sleeps" = "5 5 5 10 20 5 5 " ] && ok "backoff: flat 5 5 5, then exponential 10 20, survivor resets to 5" || bad "backoff sequence wrong: [$sleeps] (want 5 5 5 10 20 5 5)"
streaks="$(tr '\n' ' ' < "$R/.kickoff/streaks.log" 2>/dev/null)"
[ "$streaks" = "1 2 3 4 5 0 1 " ] && ok "FASTDEATH_STREAK grows 1..5, a survivor resets it to 0, then 1" || bad "streak sequence wrong: [$streaks]"
counts="$(tr '\n' ' ' < "$R/.kickoff/counts.log" 2>/dev/null)"
[ "$counts" = "7 7 7 7 7 0 0 " ] && ok "announce.count untouched through the streak, zeroed by the survivor (#8)" || bad "announce.count sequence wrong: [$counts]"
cc="$(CURL_RECORD_DIR="$R/curl" curl_count)"
[ "$cc" = "1" ] && ok "degraded alarm fired EXACTLY once (at the streak crossing)" || bad "alarm count=$cc (want 1)"
[ "$(wc -l < "$R/.kickoff/restarts.log" 2>/dev/null)" = "7" ] && ok "start_session ran after every death (never wedges — always retries)" || bad "restart count wrong: $(wc -l < "$R/.kickoff/restarts.log" 2>/dev/null)"
[ "$(wc -l < "$R/.kickoff/hops.log" 2>/dev/null)" = "7" ] && ok "engine_hop_boundary fired on every death boundary (hop and restart stay in lockstep)" || bad "hop count wrong: $(wc -l < "$R/.kickoff/hops.log" 2>/dev/null)"
if [ -f "$R/curl/argv.1" ]; then
  grep -q "crash-looping" "$R/curl/argv.1" && ok "alarm copy is the DISTINCT degraded message (crash-looping)" || bad "alarm copy is not the degraded message"
  grep -q "org is cooking on" "$R/curl/argv.1" && bad "alarm reuses the cheerful ping's phrase (must be distinct — #8)" || ok "alarm is distinct from the cheerful 'org is cooking on' ping (#8)"
  grep -q "TESTTOK-123456" "$R/curl/argv.1" && bad "BOT TOKEN LEAKED ON ARGV" || ok "bot token NOT on curl argv"
  grep -q "chat_id=555000111" "$R/curl/argv.1" && ok "alarm targeted the allowFrom chat" || bad "chat_id missing from alarm"
  grep -q "botTESTTOK-123456" "$R/curl/stdin.1" 2>/dev/null && ok "bot token rides curl stdin (-K -), off argv" || bad "token URL not on curl stdin"
  grep -q -- '^-q ' "$R/curl/argv.1" && ok "curl's FIRST argument is -q (suppresses ~/.curlrc / \$CURL_HOME/.curlrc — a trace-ascii there would write the token URL to disk)" || bad "curl's first argv is not -q (got: $(head -n1 "$R/curl/argv.1" | cut -c1-40))"
fi
# cap + overflow safety (the "never wedges" property): a long outage grows the streak
# unboundedly — the backoff must CAP at RESTART_BACKOFF_CAP_SECONDS and the shift must never
# overflow 64-bit into a 0/negative sleep (a tight loop) or a huge one (a wedge).
Rc="$(new_fixture t25cap)"
cb_t3_of "$SCRIPTS/supervisor.sh" > "$Rc/t3block.sh"
cad_of "$SCRIPTS/supervisor.sh" > "$Rc/cad.sh"     # the REAL re-alarm gate the block calls (#2)
tok_of "$SCRIPTS/supervisor.sh" > "$Rc/tok.sh"     # the REAL sender the alarm calls (FIX C seam)
(
  scenario_env "$Rc"
  set -euo pipefail
  RESTART_BACKOFF_SECONDS=5; RESTART_BACKOFF_CAP_SECONDS=1800
  FASTDEATH_THRESHOLD_SECONDS=60; FASTDEATH_ALARM_AT=3; FASTDEATH_STREAK=0
  FASTDEATH_REALARM_EVERY=12; FASTDEATH_LAST_ALARM_STREAK=0      # re-alarm knobs (#2)
  eval "$(cat "$Rc/cad.sh")"                                     # define the REAL crashloop_alarm_due
  eval "$(cat "$Rc/tok.sh")"                                     # …and the REAL tokenless sender
  SESSION_PGID="live"; log() { :; }
  sleep() { printf '%s\n' "$1" >> "$KICKOFF_DIR/sleeps.log"; }
  start_session() { SESSION_STARTED="$SECONDS"; }
  session_alive() { return 1; }
  engine_hop_boundary() { :; }                                   # observed in the cb scenario; no-op here
  blk="$(cat "$Rc/t3block.sh")"
  i=0; while [ "$i" -lt 40 ]; do SECONDS=100000; SESSION_STARTED=$((SECONDS - 5)); eval "$blk"; i=$((i + 1)); done
) > "$SCRATCH/t25cap.log" 2>&1
caprc=$?
lastbk="$(tail -1 "$Rc/.kickoff/sleeps.log" 2>/dev/null)"
maxbk="$(sort -n "$Rc/.kickoff/sleeps.log" 2>/dev/null | tail -1)"
minbk="$(sort -n "$Rc/.kickoff/sleeps.log" 2>/dev/null | head -1)"
[ "$caprc" -eq 0 ] && ok "40-death streak runs clean (no shift-overflow abort)" || bad "cap scenario aborted rc=$caprc: $(tail -3 "$SCRATCH/t25cap.log")"
[ "$lastbk" = "1800" ] && ok "backoff CAPS at RESTART_BACKOFF_CAP_SECONDS (1800) under a long outage" || bad "backoff not capped: last=$lastbk"
[ "$maxbk" = "1800" ] && ok "backoff never exceeds the cap (no overflow to a huge sleep = no wedge)" || bad "backoff exceeded cap: max=$maxbk"
{ [ -n "$minbk" ] && [ "$minbk" -ge 5 ]; } && ok "backoff never drops below the base (no 0/negative tight-loop sleep)" || bad "backoff went below base: min=$minbk"

# a HEALTHY refresh (degradation flag / cadence) also clears the streak + announce.count so a
# stale crash-loop streak can't survive it (task: "a session that lived normally, incl. a normal
# refresh"). Drives the REAL refresh() extracted from supervisor.sh with stubbed lifecycle calls.
Rr="$(new_fixture t25ref)"
awk '/^refresh\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SCRIPTS/supervisor.sh" > "$Rr/refresh.sh"
echo 9 > "$Rr/.kickoff/announce.count"
(
  scenario_env "$Rr"
  set -euo pipefail
  FASTDEATH_STREAK=5
  log() { :; }; stop_session() { :; }; start_session() { :; }
  # v0.9: refresh()'s non-bridge arm now calls bridge_boot_reset (the helper lives in the
  # bridge unit, which this fixture deliberately does NOT extract). Stub it OBSERVABLY rather
  # than as a no-op: the supervisor-liveness suite proves what bridge_boot_reset DOES, but it
  # stubs refresh() and so cannot prove refresh() CALLS it. This is the only harness that drives
  # the real refresh(), so recording the call is what closes that wiring gap with an assertion
  # instead of leaving it "proven by reading the diff".
  bridge_boot_reset() { printf 'called\n' >> "$KICKOFF_DIR/boot_reset_calls"; }
  : > "$REFRESH_FLAG"
  eval "$(cat "$Rr/refresh.sh")"
  refresh "test"
  printf '%s\n' "$FASTDEATH_STREAK" > "$KICKOFF_DIR/ref_streak"
  refresh "bridge-neverup-backoff"      # a bridge-* reason must PRESERVE the ladder (no reset call)
) > "$SCRATCH/t25ref.log" 2>&1
[ "$(cat "$Rr/.kickoff/ref_streak" 2>/dev/null)" = "0" ] && ok "refresh() resets FASTDEATH_STREAK (healthy restart, not a crash)" || bad "refresh() did not reset the streak"
[ "$(cat "$Rr/.kickoff/announce.count" 2>/dev/null)" = "0" ] && ok "refresh() zeroes announce.count (next restart announces #1)" || bad "refresh() did not reset announce.count"
[ "$(grep -c . "$Rr/.kickoff/boot_reset_calls" 2>/dev/null || echo 0)" = "1" ] && ok "refresh(): a NON-bridge reason calls bridge_boot_reset ONCE; a bridge-* reason preserves the backoff ladder" || bad "refresh() bridge_boot_reset wiring wrong (want exactly 1 call from the non-bridge refresh, got $(grep -c . "$Rr/.kickoff/boot_reset_calls" 2>/dev/null || echo 0))"

# ══════════════════════════════════════════════════════════════════════════════
section "T26 zero-trace: the LIVE lifecycle files + .kickoff are untouched"
[ "$(sha256sum "$SCRIPTS/supervisor.sh" | cut -d' ' -f1)" = "$BASE_SUP" ] && ok "live supervisor.sh byte-identical" || bad "LIVE supervisor.sh CHANGED"
[ "$(sha256sum "$SCRIPTS/session-run.sh" | cut -d' ' -f1)" = "$BASE_RUN" ] && ok "live session-run.sh byte-identical" || bad "LIVE session-run.sh CHANGED"
now_set="$(sha256sum "$LIVE_REPO/.claude/settings.json" 2>/dev/null | cut -d' ' -f1 || echo none)"
[ "$now_set" = "$BASE_SET" ] && ok "live .claude/settings.json byte-identical" || bad "LIVE settings.json CHANGED"
live_residue=0
for f in $AUTH_ARTIFACTS; do
  # a leak is a NEW artifact; ones present at start belong to an armed live instance's own supervisor
  case " $PRE_RESIDUE " in *" $f "*) continue ;; esac
  [ -e "$LIVE_REPO/.kickoff/$f" ] && live_residue=1 && bad "live .kickoff/$f appeared during the run — selftest leaked into the live instance"
done
[ "$live_residue" -eq 0 ] && ok "no NEW auth-heal residue leaked into the live .kickoff/"

# ══════════════════════════════════════════════════════════════════════════════
p="$(wc -l < "$PASS_F")"; f="$(wc -l < "$FAIL_F")"
printf '\n══ auth-heal selftest: %s passed, %s failed ══\n' "$p" "$f"
if [ "$f" -gt 0 ]; then
  printf 'FAILURES:\n'; sed 's/^/  ✗ /' "$FAIL_F"
  exit 1
fi
exit 0
