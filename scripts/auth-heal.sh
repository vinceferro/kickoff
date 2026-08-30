#!/usr/bin/env bash
# auth-heal.sh — supervisor self-heal for a Claude Code AUTH-TOKEN expiry.
#
# WHY THIS EXISTS (2026-07-07): the headless worker went silent ~2h because the CC
# auth token expired. The supervisor watches PROCESS liveness only (`kill -0` on the
# script(1) pty leader), so an expired-auth claude that HANGS at a re-login prompt
# looks "alive" forever (Case B — no trigger fires), and one that EXITS restart-loops
# into the same expiry (Case A — a doomed ping-storm). A restart can't mint a
# credential; the fix is: DETECT → pause doomed restarts → ALERT the operator with the
# one-tap turnkey → AUTO-RESUME the moment auth is valid again.
# Design: DETECT expired/invalid auth → pause doomed restarts → ONE tokenless operator alert → AUTO-RESUME when auth is valid.
#
# HOW IT'S WIRED (all edits to the supervisor are staged by scripts/install-auth-heal.sh):
#   - supervisor.sh sources this file (bash -n gated; absent/broken → a no-op stub) and
#     calls `auth_heal_step || true` once per poll, right after rotate_log.
#   - supervisor.sh's trigger-3 restart is gated on the escalation flag being absent:
#     `! session_alive && [ ! -f "$KICKOFF_DIR/auth-escalated" ]` — no doomed restarts.
#
# WHAT IT MAY DO — three actions, nothing else (never a new kill path):
#   1. touch  "$REFRESH_FLAG"              (the existing, PGID-safe restart route)
#   2. write/clear "$KICKOFF_DIR/auth-escalated"   (pauses trigger-3 restarts)
#   3. send ONE tokenless Telegram alert   (the sanctioned session-run.sh curl recipe:
#      bot token read at runtime via jq and fed to curl OFF argv through `-K -`)
#
# DETECTORS (layered; each degrades safely to inaction):
#   D3 (primary)  — a read-only, non-interactive auth probe, default
#                   `claude auth status --json` (CC ≥2.1.203, verified: no prompt, ~0.3s).
#                   rc!=0, or rc==0 with `"loggedIn": false`, counts as a failed probe;
#                   N consecutive fails (default 2) = expired. Catches BOTH the hang and
#                   the exit case, before a doomed spawn.
#   D2 (backstop) — exit-loop escalation: the session dies within T s of spawn (default
#                   60) N times in a row (default 3). Needs zero CC internals. Before
#                   escalating it consults D3 once: a VALID probe vetoes the escalation
#                   (a non-auth crash-loop stays on the normal restart path).
#
# RECOVERY: on "expired" try KICKOFF_AUTH_REFRESH_CMD if set (default EMPTY — Claude
# Max/OAuth is hard-expiry, no refresh token) → else ESCALATE (flag + alert) → then
# WAIT-AND-AUTO-RESUME: re-probe every KICKOFF_AUTH_RECHECK_INTERVAL s and, the moment
# auth is valid, clear the flag + touch the refresh flag. The operator's turnkey is
# scripts/relogin.sh (paste a fresh `claude setup-token` token; it clears the flag too).
#
# FAIL-TOWARD-INACTION (this runs inside the LIVE worker's supervisor loop):
#   - INERT unless armed: KICKOFF_AUTH_HEAL=1 (env or .kickoff/instance.env). Unarmed →
#     pure no-op (and it clears a stale escalation flag, restoring stock behavior).
#   - any doubt → HEALTHY: probe timeouts (rc 124/125), unrunnable cmds (126/127) and a
#     probe that has NEVER succeeded this supervisor-era are INDETERMINATE → no action.
#   - the whole step body runs in a SUBSHELL guarded by `|| true`: verified on this box
#     that a `set -u` unbound-variable error propagates THROUGH `fn || true` in the same
#     shell — a subshell's death is just a non-zero rc, so no helper bug can kill the
#     supervisor. Cross-poll state lives in .kickoff/auth-heal.state (defensively parsed,
#     never sourced).
#   - anti-boot-loop: ≤1 alert per KICKOFF_AUTH_ALERT_COOLDOWN (default 30 min, then
#     re-alerts while still broken); ≤1 refresh-cmd attempt per cooldown; after
#     KICKOFF_AUTH_MAX_AUTO_RESUMES failed recoveries (default 3) it stops auto-resuming
#     and waits for relogin.sh.
#   - DRY_RUN=1 (the supervisor's) → evaluates detectors read-only, logs what it WOULD
#     do, writes/sends NOTHING (streaks don't persist across polls in DRY_RUN).
#
# CONFIG (all optional; env wins over .kickoff/instance.env; see instance.env.example):
#   KICKOFF_AUTH_HEAL=1                      arm it (default 0 = fully inert)
#   KICKOFF_AUTH_CHECK_CMD                   probe (default `claude auth status --json`;
#                                            `none` disables D3 — D2-only mode)
#   KICKOFF_AUTH_REFRESH_CMD                 non-interactive re-auth (default empty)
#   KICKOFF_AUTH_CHECK_INTERVAL=300          healthy-probe period, seconds
#   KICKOFF_AUTH_RECHECK_INTERVAL=60         probe period while escalated, seconds
#   KICKOFF_AUTH_FAILS_TO_ESCALATE=2         consecutive probe fails = expired
#   KICKOFF_AUTH_EARLY_DEATH_SECONDS=60      D2 window T (0 disables D2)
#   KICKOFF_AUTH_EARLY_DEATHS_TO_ESCALATE=3  D2 streak N
#   KICKOFF_AUTH_ALERT_COOLDOWN=1800         seconds between alerts / refresh attempts
#   KICKOFF_AUTH_MAX_AUTO_RESUMES=3          failed recoveries before wait-for-relogin
#   KICKOFF_AUTH_PROBE_TIMEOUT=30            probe hard timeout, seconds
#
# The probe/refresh commands run as the supervisor user — operator config, the same
# trust level as the supervisor's own START_CMD. The probe environment imports
# CLAUDE_CODE_OAUTH_TOKEN from .kickoff/auth.env (written 0600 by relogin.sh) so the
# probe judges EXACTLY the credentials the worker will run with.
#
# USAGE
#   . scripts/auth-heal.sh        # source → defines auth_heal_step (the supervisor path)
#   bash scripts/auth-heal.sh     # standalone DIAGNOSTIC probe: prints the verdict,
#                                 # writes nothing; rc 0=valid 2=expired 3=indeterminate

# ── the one public entry point ────────────────────────────────────────────────
auth_heal_step() {
  # Whole body in a SUBSHELL + `|| true`: a set -u unbound-variable error kills the
  # calling shell even through `fn || true` (verified on this box's bash 5.2) — but a
  # subshell's death is only a non-zero status here. No bug below can take the
  # supervisor down. Logs still reach the supervisor's stdout/log.
  ( _auth_heal_main ) || true
  return 0
}

# ── internals (everything namespaced _ah_/_AH_ to stay out of the supervisor's way) ──

_AH_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo scripts)"

# The config names this helper is allowed to import from instance.env (the same
# untrusted-config discipline as session-run.sh/preflight.sh: sourced in a SUBSHELL,
# only these names round-trip back; a pre-set env value wins over the file).
_AH_CFG_NAMES=(
  KICKOFF_AUTH_HEAL KICKOFF_AUTH_CHECK_CMD KICKOFF_AUTH_REFRESH_CMD
  KICKOFF_AUTH_CHECK_INTERVAL KICKOFF_AUTH_RECHECK_INTERVAL
  KICKOFF_AUTH_FAILS_TO_ESCALATE
  KICKOFF_AUTH_EARLY_DEATH_SECONDS KICKOFF_AUTH_EARLY_DEATHS_TO_ESCALATE
  KICKOFF_AUTH_ALERT_COOLDOWN KICKOFF_AUTH_MAX_AUTO_RESUMES KICKOFF_AUTH_PROBE_TIMEOUT
  TELEGRAM_STATE_DIR
)

_ah_log() { printf '[auth-heal %s] %s\n' "$(date -u +%H:%M:%S 2>/dev/null || echo now)" "$*"; }

# numeric-or-default: a malformed knob must degrade to the default, never break arithmetic
_ah_num() {
  case "${1:-}" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *)           printf '%s' "$1" ;;
  esac
}

_ah_now() { printf '%(%s)T' -1; }   # epoch via bash builtin (no fork)

# ── config: env-first, then a whitelisted subshell import of instance.env ────
_ah_load_config() {
  local repo="$1" kdir="$2"
  local ienv="${INSTANCE_ENV:-$kdir/instance.env}"
  local n pair name
  # names already set in the (trusted, launcher-provided) environment win over the file
  local -A _ah_preset=()
  for n in "${_AH_CFG_NAMES[@]}"; do
    if [ -n "${!n+x}" ]; then _ah_preset["$n"]=1; fi
  done
  if [ -f "$ienv" ]; then
    while IFS= read -r -d '' pair; do
      name="${pair%%=*}"
      if ! [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then continue; fi
      case " ${_AH_CFG_NAMES[*]} " in
        *" $name "*) : ;;
        *) continue ;;
      esac
      if [ -n "${_ah_preset[$name]:-}" ]; then continue; fi
      printf -v "$name" '%s' "${pair#*=}"
    done < <(
      # UNTRUSTED CONFIG: source in this throwaway subshell only; an `exit 0`, a function
      # redef, or a forged launch-control var dies here and never reaches the supervisor.
      set +eu
      cd "$repo" 2>/dev/null || true
      # shellcheck disable=SC1090
      . "$ienv" >/dev/null 2>&1
      for _ah_n in "${_AH_CFG_NAMES[@]}"; do
        if [ -n "${!_ah_n+x}" ]; then printf '%s=%s\0' "$_ah_n" "${!_ah_n}"; fi
      done
    )
  fi
  # sanitized effective config (numerics degrade to defaults, never to errors)
  _C_HEAL="${KICKOFF_AUTH_HEAL:-0}"
  _C_CHECK_CMD="${KICKOFF_AUTH_CHECK_CMD:-claude auth status --json}"
  _C_REFRESH_CMD="${KICKOFF_AUTH_REFRESH_CMD:-}"
  _C_CHECK_INTERVAL="$(_ah_num "${KICKOFF_AUTH_CHECK_INTERVAL:-}" 300)"
  _C_RECHECK_INTERVAL="$(_ah_num "${KICKOFF_AUTH_RECHECK_INTERVAL:-}" 60)"
  _C_FAILS="$(_ah_num "${KICKOFF_AUTH_FAILS_TO_ESCALATE:-}" 2)"
  if [ "$_C_FAILS" -lt 1 ]; then _C_FAILS=1; fi
  _C_D2_T="$(_ah_num "${KICKOFF_AUTH_EARLY_DEATH_SECONDS:-}" 60)"
  _C_D2_N="$(_ah_num "${KICKOFF_AUTH_EARLY_DEATHS_TO_ESCALATE:-}" 3)"
  if [ "$_C_D2_N" -lt 1 ]; then _C_D2_N=1; fi
  _C_ALERT_COOLDOWN="$(_ah_num "${KICKOFF_AUTH_ALERT_COOLDOWN:-}" 1800)"
  _C_MAX_RESUMES="$(_ah_num "${KICKOFF_AUTH_MAX_AUTO_RESUMES:-}" 3)"
  _C_PROBE_TIMEOUT="$(_ah_num "${KICKOFF_AUTH_PROBE_TIMEOUT:-}" 30)"
  return 0
}

# ── cross-poll state (a file, because the step body is a subshell) ───────────
# NEVER sourced — parsed line-by-line against a key whitelist; corrupt lines are
# dropped; a different supervisor pid resets the era (the escalation FLAG persists
# on purpose: a supervisor bounce must not un-escalate a real expiry).
_ah_state_load() {
  local f="$1" line k v
  _S_SUP_PID=""; _S_EVER_OK=0; _S_FAIL_STREAK=0; _S_LAST_PROBE_TS=0
  _S_D2_STREAK=0; _S_D2_LAST_START=""; _S_RESUME_COUNT=0; _S_LAST_REFRESH_TS=0
  _S_LAST_VERDICT=""
  if [ -f "$f" ]; then
    while IFS= read -r line; do
      k="${line%%=*}"; v="${line#*=}"
      case "$k" in
        SUP_PID|EVER_OK|FAIL_STREAK|LAST_PROBE_TS|D2_STREAK|D2_LAST_START|RESUME_COUNT|LAST_REFRESH_TS)
          case "$v" in ''|*[!0-9]*) continue ;; esac
          printf -v "_S_$k" '%s' "$v" ;;
        LAST_VERDICT)
          case "$v" in valid|expired|indeterminate) _S_LAST_VERDICT="$v" ;; esac ;;
      esac
    done < "$f"
  fi
  if [ "${_S_SUP_PID:-}" != "$$" ]; then
    _S_SUP_PID="$$"; _S_EVER_OK=0; _S_FAIL_STREAK=0; _S_LAST_PROBE_TS=0
    _S_D2_STREAK=0; _S_D2_LAST_START=""; _S_RESUME_COUNT=0; _S_LAST_REFRESH_TS=0
    _S_LAST_VERDICT=""
  fi
  return 0
}

_ah_state_save() {
  local f="$1" content old=""
  content="SUP_PID=${_S_SUP_PID:-}
EVER_OK=${_S_EVER_OK:-0}
FAIL_STREAK=${_S_FAIL_STREAK:-0}
LAST_PROBE_TS=${_S_LAST_PROBE_TS:-0}
D2_STREAK=${_S_D2_STREAK:-0}
D2_LAST_START=${_S_D2_LAST_START:-}
RESUME_COUNT=${_S_RESUME_COUNT:-0}
LAST_REFRESH_TS=${_S_LAST_REFRESH_TS:-0}
LAST_VERDICT=${_S_LAST_VERDICT:-}"
  if [ -f "$f" ]; then old="$(cat "$f" 2>/dev/null || true)"; fi
  if [ "$content" = "$old" ]; then return 0; fi
  if printf '%s\n' "$content" > "$f.tmp" 2>/dev/null; then
    mv -f "$f.tmp" "$f" 2>/dev/null || true
  fi
  return 0
}

# ── the probe (D3) — read-only, timeout-wrapped, judged fail-toward-inaction ─
# Sets: _AH_VERDICT (valid|expired|indeterminate), _AH_PROBE_RC, _AH_PROBE_HEAD.
# Runs the check cmd with CLAUDE_CODE_OAUTH_TOKEN imported from .kickoff/auth.env
# (if present and not already in the env) so the verdict matches the credentials the
# WORKER will actually spawn with. The token stays inside the capture subshell —
# never on argv, never logged.
_ah_probe() {
  local cmd="${_C_CHECK_CMD:-}" tmo="${_C_PROBE_TIMEOUT:-30}"
  local auth_env="${AUTH_ENV:-${_AH_KDIR:-.kickoff}/auth.env}"
  local out="" rc=0
  _AH_VERDICT="indeterminate"; _AH_PROBE_RC=0; _AH_PROBE_HEAD=""
  _S_LAST_PROBE_TS="$(_ah_now)"
  if [ -z "$cmd" ] || [ "$cmd" = "none" ]; then return 0; fi
  out="$(
    set +eu
    if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -f "$auth_env" ]; then
      eval "$(
        set +eu
        # shellcheck disable=SC1090
        . "$auth_env" >/dev/null 2>&1 || true
        if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
          printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q\n' "$CLAUDE_CODE_OAUTH_TOKEN"
        fi
      )" 2>/dev/null
    fi
    if command -v timeout >/dev/null 2>&1; then
      timeout "$tmo" bash -c "$cmd" 2>&1
    else
      bash -c "$cmd" 2>&1
    fi
  )" && rc=0 || rc=$?
  _AH_PROBE_RC="$rc"
  _AH_PROBE_HEAD="$(printf '%s' "$out" | tr -d '\r' | tr '\n' ' ' | head -c 160 || true)"
  case "$rc" in
    0)
      # CC ≥2.1.203 reports {"loggedIn": true|false}; rc 0 + loggedIn:false = logged out
      if printf '%s' "$out" | grep -Eq '"loggedIn"[[:space:]]*:[[:space:]]*false'; then
        _AH_VERDICT="expired"
      else
        _AH_VERDICT="valid"; _S_EVER_OK=1
      fi ;;
    124|125) _AH_VERDICT="indeterminate" ;;   # probe timed out / timeout(1) failed — not auth evidence
    126|127) _AH_VERDICT="indeterminate" ;;   # cmd not runnable — a config problem, not an expiry
    *)
      # a probe that has NEVER succeeded this era can't prove an expiry (it may simply
      # be the wrong command on this box) — fail toward inaction
      if [ "${_S_EVER_OK:-0}" = "1" ]; then _AH_VERDICT="expired"; else _AH_VERDICT="indeterminate"; fi ;;
  esac
  return 0
}

# ── the tokenless Telegram alert (the sanctioned session-run.sh recipe) ───────
# Best-effort: any missing piece (jq, curl, settings, access.json, token, chat id)
# logs and skips — it must NEVER fail the step. Bot token read at runtime via jq and
# fed to curl OFF argv (`-K -` reads the url= line from stdin; printf is a builtin,
# so the token never lands in /proc/<pid>/cmdline). ≤1 send per cooldown.
_ah_alert() {
  local text="$1"
  local stamp="${_AH_KDIR:-.kickoff}/auth-heal.alert.last"
  local now last settings access token chat_id api_url
  if [ "${DRY_RUN:-0}" = "1" ]; then
    _ah_log "DRY_RUN — would send Telegram alert: $(printf '%s' "$text" | tr '\n' ' ' | head -c 120 || true)…"
    return 0
  fi
  now="$(_ah_now)"
  last="$(cat "$stamp" 2>/dev/null || echo 0)"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$last" -gt 0 ] && [ $(( now - last )) -lt "${_C_ALERT_COOLDOWN:-1800}" ]; then
    _ah_log "alert suppressed (cooldown: $(( now - last ))s < ${_C_ALERT_COOLDOWN:-1800}s since the last one)"
    return 0
  fi
  command -v jq   >/dev/null 2>&1 || { _ah_log "alert skipped: jq not found"; return 0; }
  command -v curl >/dev/null 2>&1 || { _ah_log "alert skipped: curl not found"; return 0; }
  settings="${SETTINGS_FILE:-${REPO_DIR:-.}/.claude/settings.local.json}"
  access="${TELEGRAM_STATE_DIR:-}/access.json"
  [ -f "$settings" ] || { _ah_log "alert skipped: no settings file ($settings)"; return 0; }
  [ -n "${TELEGRAM_STATE_DIR:-}" ] && [ -f "$access" ] || { _ah_log "alert skipped: no access.json (TELEGRAM_STATE_DIR unset or file missing)"; return 0; }
  token="$(jq -r '.env.TELEGRAM_BOT_TOKEN // empty' "$settings" 2>/dev/null || true)"
  chat_id="$(jq -r '.allowFrom[0] // empty' "$access" 2>/dev/null || true)"
  if [ -z "$token" ] || [ -z "$chat_id" ]; then
    _ah_log "alert skipped: token or chat_id missing"
    return 0
  fi
  echo "$now" > "$stamp" 2>/dev/null || true
  api_url="https://api.telegram.org/bot${token}/sendMessage"
  if printf 'url=%s\n' "$api_url" | curl -s -o /dev/null \
       --max-time 10 \
       --data-urlencode "chat_id=${chat_id}" \
       --data-urlencode "text=${text}" \
       -K - 2>/dev/null; then
    _ah_log "alert sent to chat ${chat_id}"
  else
    _ah_log "alert curl failed (non-fatal)"
  fi
  unset token api_url
  return 0
}

_ah_alert_escalated() {
  # the standard escalation/reminder copy — meaningful + actionable, never a token
  local reason="$1" repo_name
  repo_name="$(basename "${REPO_DIR:-$(pwd)}" 2>/dev/null || echo worker)"
  _ah_alert "🔐 ${repo_name} worker: Claude Code auth needs a re-login — ${reason}
Restarts are paused; I probe every ${_C_RECHECK_INTERVAL:-60}s and auto-resume the moment auth is valid.
Fix (~2 min):
1) on any machine with a browser:  claude setup-token
2) on the box:  bash ${_AH_SCRIPTS_DIR}/relogin.sh   (paste the token)
(re-alerts every $(( ${_C_ALERT_COOLDOWN:-1800} / 60 ))m until fixed)"
  return 0
}

_ah_escalate() {
  local reason="$1"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    _ah_log "DRY_RUN — would ESCALATE (write ${_AH_FLAG:-auth-escalated} + alert + pause restarts): $reason"
    return 0
  fi
  if [ ! -f "${_AH_FLAG:?}" ]; then
    printf '%s\n%s\n' "$(date -u +%FT%TZ 2>/dev/null || echo now)" "$reason" > "$_AH_FLAG" 2>/dev/null || true
    _ah_log "ESCALATED: $reason"
    _ah_log "restarts paused (flag: $_AH_FLAG) — auto-resume on valid auth; turnkey: bash ${_AH_SCRIPTS_DIR}/relogin.sh"
  fi
  _ah_alert_escalated "$reason"
  return 0
}

_ah_resume() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    _ah_log "DRY_RUN — would AUTO-RESUME (clear flag + touch refresh flag)"
    return 0
  fi
  rm -f "${_AH_FLAG:?}" 2>/dev/null || true
  : >> "${_AH_REFRESH_FLAG:?}" 2>/dev/null || true
  _S_RESUME_COUNT=$(( ${_S_RESUME_COUNT:-0} + 1 ))
  _S_FAIL_STREAK=0; _S_D2_STREAK=0; _S_LAST_VERDICT="valid"
  _ah_log "auth VALID again — auto-resuming: escalation flag cleared + refresh flag touched (resume #${_S_RESUME_COUNT}); the fresh session will announce itself"
  return 0
}

# optional non-interactive credential refresh (KICKOFF_AUTH_REFRESH_CMD; default empty).
# ≤1 attempt per alert-cooldown. rc 0 AND a subsequent VALID probe = success.
_ah_try_refresh() {
  local cmd="${_C_REFRESH_CMD:-}" now rc=0 out=""
  if [ -z "$cmd" ]; then return 1; fi
  now="$(_ah_now)"
  if [ $(( now - ${_S_LAST_REFRESH_TS:-0} )) -lt "${_C_ALERT_COOLDOWN:-1800}" ]; then
    return 1
  fi
  _S_LAST_REFRESH_TS="$now"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    _ah_log "DRY_RUN — would attempt credential refresh: $cmd"
    return 1
  fi
  _ah_log "attempting non-interactive credential refresh: $cmd"
  out="$(
    set +eu
    if command -v timeout >/dev/null 2>&1; then
      timeout $(( ${_C_PROBE_TIMEOUT:-30} * 4 )) bash -c "$cmd" 2>&1
    else
      bash -c "$cmd" 2>&1
    fi
  )" && rc=0 || rc=$?
  _ah_log "refresh cmd rc=$rc: $(printf '%s' "$out" | tr '\n' ' ' | head -c 120 || true)"
  if [ "$rc" -ne 0 ]; then return 1; fi
  _ah_probe
  if [ "${_AH_VERDICT:-}" = "valid" ]; then return 0; fi
  return 1
}

# ── D2: exit-loop escalation (zero CC-internals backstop) ─────────────────────
_ah_d2() {
  if [ "${_C_D2_T:-0}" -le 0 ]; then return 0; fi
  command -v session_alive >/dev/null 2>&1 || return 0
  case "${SESSION_STARTED:-}" in ''|*[!0-9]*) return 0 ;; esac
  local age=$(( ${SECONDS:-0} - SESSION_STARTED ))
  if [ "$age" -lt 0 ]; then age=0; fi
  if session_alive; then
    if [ "$age" -ge "$_C_D2_T" ] && [ "${_S_D2_STREAK:-0}" -gt 0 ]; then
      _ah_log "session survived ${age}s — early-death streak reset (was ${_S_D2_STREAK})"
      _S_D2_STREAK=0
    fi
    return 0
  fi
  # the managed session is DEAD (observed before trigger-3 restarts it)
  if [ "$age" -ge "$_C_D2_T" ]; then
    # a session that lived past the window ending is a normal end, not an early death
    if [ "${_S_D2_STREAK:-0}" -gt 0 ]; then _S_D2_STREAK=0; fi
    return 0
  fi
  if [ "${_S_D2_LAST_START:-x}" = "${SESSION_STARTED}" ]; then return 0; fi   # this spawn already counted
  _S_D2_LAST_START="${SESSION_STARTED}"
  _S_D2_STREAK=$(( ${_S_D2_STREAK:-0} + 1 ))
  _ah_log "session died ${age}s after spawn — early-death streak ${_S_D2_STREAK}/${_C_D2_N} (D2)"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    _ah_log "DRY_RUN — note: streaks do not persist across polls in DRY_RUN"
  fi
  if [ "$_S_D2_STREAK" -lt "$_C_D2_N" ]; then return 0; fi
  # streak reached → consult the probe once; a VALID probe VETOES the escalation
  # (a non-auth crash-loop stays on the normal restart path — fail-toward-inaction)
  _ah_probe
  if [ "${_AH_VERDICT:-}" = "valid" ]; then
    _ah_log "exit-loop streak ${_S_D2_STREAK}x but auth probe is VALID — NOT escalating (normal restart path continues); streak reset"
    _S_D2_STREAK=0
    return 0
  fi
  _ah_escalate "session died <${_C_D2_T}s after spawn, ${_S_D2_STREAK}x in a row (exit-loop D2; auth probe: ${_AH_VERDICT:-indeterminate})"
  return 0
}

# ── D3: the periodic auth probe ───────────────────────────────────────────────
_ah_d3() {
  local cmd="${_C_CHECK_CMD:-}" now
  if [ -z "$cmd" ] || [ "$cmd" = "none" ]; then return 0; fi
  now="$(_ah_now)"
  if [ $(( now - ${_S_LAST_PROBE_TS:-0} )) -lt "${_C_CHECK_INTERVAL:-300}" ]; then return 0; fi
  _ah_probe
  case "${_AH_VERDICT:-indeterminate}" in
    valid)
      if [ "${_S_LAST_VERDICT:-}" != "valid" ]; then
        _ah_log "auth probe: VALID (healthy; re-probing every ${_C_CHECK_INTERVAL}s, logging only on change)"
      fi
      _S_FAIL_STREAK=0
      _S_RESUME_COUNT=0 ;;
    expired)
      _S_FAIL_STREAK=$(( ${_S_FAIL_STREAK:-0} + 1 ))
      _ah_log "auth probe FAILED (rc=${_AH_PROBE_RC:-?}: ${_AH_PROBE_HEAD:-}) — streak ${_S_FAIL_STREAK}/${_C_FAILS} (D3)"
      if [ "${DRY_RUN:-0}" = "1" ]; then
        _ah_log "DRY_RUN — note: streaks do not persist across polls in DRY_RUN"
      fi
      if [ "$_S_FAIL_STREAK" -ge "${_C_FAILS:-2}" ]; then
        if _ah_try_refresh; then
          _ah_log "credential refresh succeeded — touching refresh flag for a clean restart into the fresh credentials"
          if [ "${DRY_RUN:-0}" != "1" ]; then : >> "${_AH_REFRESH_FLAG:?}" 2>/dev/null || true; fi
          _S_FAIL_STREAK=0
        else
          _ah_escalate "auth probe failed ${_S_FAIL_STREAK}x (D3: ${cmd})"
        fi
      fi ;;
    *)
      if [ "${_S_LAST_VERDICT:-}" != "indeterminate" ]; then
        _ah_log "auth probe INDETERMINATE (rc=${_AH_PROBE_RC:-?}; timeout/unrunnable/never-succeeded) — NO action (fail-toward-inaction)"
      fi ;;
  esac
  _S_LAST_VERDICT="${_AH_VERDICT:-indeterminate}"
  return 0
}

# ── escalated: wait-and-auto-resume ───────────────────────────────────────────
_ah_wait_branch() {
  local now
  now="$(_ah_now)"
  if [ $(( now - ${_S_LAST_PROBE_TS:-0} )) -lt "${_C_RECHECK_INTERVAL:-60}" ]; then return 0; fi
  _ah_probe
  case "${_AH_VERDICT:-indeterminate}" in
    valid)
      if [ "${_S_RESUME_COUNT:-0}" -ge "${_C_MAX_RESUMES:-3}" ]; then
        _ah_log "auth VALID but auto-resume is CAPPED after ${_S_RESUME_COUNT} failed recoveries — staying escalated (anti boot-loop); relogin.sh clears it"
        _ah_alert "🔐 $(basename "${REPO_DIR:-$(pwd)}" 2>/dev/null || echo worker) worker: auth looks valid again, but auto-resume is capped after ${_S_RESUME_COUNT} failed recoveries (anti boot-loop). Run: bash ${_AH_SCRIPTS_DIR}/relogin.sh — or rm ${_AH_FLAG} — to resume."
        return 0
      fi
      _ah_resume ;;
    expired)
      if _ah_try_refresh; then
        _ah_resume
        return 0
      fi
      # still expired → reminder alert (cooldown-gated inside _ah_alert)
      _ah_alert_escalated "$(sed -n '2p' "${_AH_FLAG}" 2>/dev/null | tr -cd '[:print:]' | head -c 200 || echo 'auth still expired')" ;;
    *)
      if [ "${_S_LAST_VERDICT:-}" != "indeterminate" ]; then
        _ah_log "escalated + probe INDETERMINATE — waiting (relogin.sh is the way out)"
      fi ;;
  esac
  _S_LAST_VERDICT="${_AH_VERDICT:-indeterminate}"
  return 0
}

# ── the per-poll main (runs inside the auth_heal_step subshell) ───────────────
_auth_heal_main() {
  local repo="${REPO_DIR:-$(pwd)}"
  _AH_KDIR="${KICKOFF_DIR:-$repo/.kickoff}"
  _AH_FLAG="$_AH_KDIR/auth-escalated"
  _AH_REFRESH_FLAG="${REFRESH_FLAG:-$_AH_KDIR/refresh-requested}"
  local statef="$_AH_KDIR/auth-heal.state"

  _ah_load_config "$repo" "$_AH_KDIR"

  # DISARMED (the default) → fully inert; also clear a stale escalation flag so a
  # disarm always reverts to stock supervisor behavior (nothing left gating restarts).
  if [ "${_C_HEAL:-0}" != "1" ]; then
    if [ -f "$_AH_FLAG" ]; then
      if [ "${DRY_RUN:-0}" = "1" ]; then
        _ah_log "DRY_RUN — disarmed; would clear the stale escalation flag ($_AH_FLAG)"
      else
        rm -f "$_AH_FLAG" 2>/dev/null || true
        _ah_log "disarmed (KICKOFF_AUTH_HEAL!=1) — cleared the stale escalation flag; stock supervisor behavior restored"
      fi
    fi
    return 0
  fi

  if [ ! -d "$_AH_KDIR" ]; then mkdir -p "$_AH_KDIR" 2>/dev/null || return 0; fi

  _ah_state_load "$statef"

  if [ -f "$_AH_FLAG" ]; then
    _ah_wait_branch
  else
    _ah_d2
    # d2 may have escalated — the wait branch takes over from the NEXT poll
    if [ ! -f "$_AH_FLAG" ]; then _ah_d3; fi
  fi

  if [ "${DRY_RUN:-0}" != "1" ]; then _ah_state_save "$statef"; fi
  return 0
}

# ── standalone: a read-only diagnostic probe (no writes, no alerts) ───────────
# bash scripts/auth-heal.sh   → prints the verdict; rc 0=valid 2=expired 3=indeterminate
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  set -u
  REPO_DIR="${REPO_DIR:-$(pwd)}"
  _AH_KDIR="${KICKOFF_DIR:-$REPO_DIR/.kickoff}"
  _ah_load_config "$REPO_DIR" "$_AH_KDIR"
  _S_EVER_OK=1   # diagnostic mode: report a plain rc-failure as expired, not never-ok
  _ah_probe
  printf 'auth probe verdict: %s (rc=%s cmd=%s)\n' "${_AH_VERDICT:-indeterminate}" "${_AH_PROBE_RC:-?}" "${_C_CHECK_CMD:-}"
  if [ -n "${_AH_PROBE_HEAD:-}" ]; then printf '  output: %s\n' "$_AH_PROBE_HEAD"; fi
  case "${_AH_VERDICT:-indeterminate}" in
    valid) exit 0 ;;
    expired) exit 2 ;;
    *) exit 3 ;;
  esac
fi
