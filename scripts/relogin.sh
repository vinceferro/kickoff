#!/usr/bin/env bash
# relogin.sh — the one-tap re-login turnkey for a Claude Code auth expiry.
#
# WHY: the headless worker authenticates as the operator's Claude account. That OAuth
# is HARD-EXPIRY (no refresh token) and re-login needs a BROWSER → localhost redirect,
# which a headless box doesn't have. The only headless path (CC-internals, 2026-07-07)
# is a pre-generated long-lived token: `claude setup-token`, run ONCE on any machine
# with a browser. This script is the box half of that turnkey:
#
#   1) on your phone/laptop:   claude setup-token          (copy the sk-ant-oat… token)
#   2) on the box:             bash scripts/relogin.sh     (paste it — input is hidden)
#
# It then: persists the token to .kickoff/auth.env (0600, gitignored — the session
# launcher imports it at every spawn), VERIFIES auth with the token, clears the
# supervisor's escalation flag (.kickoff/auth-escalated) and touches the refresh flag —
# so the supervisor auto-resumes with a fresh, announced session. Idempotent; every
# exit path prints your next action.
#
# SECRET DISCIPLINE: the token is NEVER accepted as a command argument (argv lands in
# /proc/<pid>/cmdline + shell history). Paste it at the hidden prompt, or pre-set
# CLAUDE_CODE_OAUTH_TOKEN in the environment for scripted use. It is never echoed or
# logged; the file is written 0600 under the gitignored .kickoff/.
#
# USAGE
#   bash scripts/relogin.sh              # interactive: hidden paste prompt
#   CLAUDE_CODE_OAUTH_TOKEN=… bash scripts/relogin.sh   # scripted (env, not argv)
#   bash scripts/relogin.sh --status     # auth/escalation/supervisor state (no secrets)
#   bash scripts/relogin.sh --clear      # remove the token file (revert to the box's
#                                        # own `claude auth login` credentials)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${REPO_DIR:-$(pwd)}"
REPO_DIR="$(cd "$REPO_DIR" && pwd)"
KICKOFF_DIR="${KICKOFF_DIR:-$REPO_DIR/.kickoff}"
AUTH_ENV="${AUTH_ENV:-$KICKOFF_DIR/auth.env}"
FLAG="$KICKOFF_DIR/auth-escalated"
REFRESH_FLAG="${REFRESH_FLAG:-$KICKOFF_DIR/refresh-requested}"
LOCKFILE="${LOCKFILE:-$KICKOFF_DIR/supervisor.lock}"

say() { printf '%s\n' "$*"; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

# the shared probe/config helpers (source-safe: defines functions only)
if [ -f "$HERE/auth-heal.sh" ] && bash -n "$HERE/auth-heal.sh" 2>/dev/null; then
  # shellcheck source=scripts/auth-heal.sh
  . "$HERE/auth-heal.sh"
else
  die "sibling scripts/auth-heal.sh missing or broken — pull/checkout the core scripts first"
fi

[ -d "$KICKOFF_DIR" ] || die "no $KICKOFF_DIR here — run from your kickoff repo root (or REPO_DIR=/path bash $0)"

supervisor_state() {
  local pid
  pid="$(cat "$LOCKFILE" 2>/dev/null || true)"
  case "$pid" in ''|0*|*[!0-9]*) pid="" ;; esac
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    printf 'running (pid %s)' "$pid"
  else
    printf 'not running'
  fi
}

probe_now() {
  # read-only; uses the same probe the supervisor uses (imports .kickoff/auth.env, so
  # it judges exactly the credentials the worker will spawn with)
  _AH_KDIR="$KICKOFF_DIR"
  _ah_load_config "$REPO_DIR" "$KICKOFF_DIR"
  _S_EVER_OK=1   # diagnostic semantics: a plain rc-failure reads as expired, not never-ok
  _ah_probe
}

case "${1:-}" in
  -h|--help)
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  --status)
    say "── relogin status ─────────────────────────────────────────────"
    say "repo:        $REPO_DIR"
    if [ -f "$AUTH_ENV" ]; then
      say "token file:  $AUTH_ENV (present, $(stat -c '%a' "$AUTH_ENV" 2>/dev/null || echo '?') — token itself never shown)"
    else
      say "token file:  none ($AUTH_ENV) — worker uses the box's own claude login"
    fi
    if [ -f "$FLAG" ]; then
      say "escalation:  ACTIVE since $(sed -n '1p' "$FLAG" 2>/dev/null || echo '?')"
      say "  reason:    $(sed -n '2p' "$FLAG" 2>/dev/null | tr -cd '[:print:]' | head -c 200 || true)"
    else
      say "escalation:  none"
    fi
    say "supervisor:  $(supervisor_state)"
    probe_now
    say "auth probe:  ${_AH_VERDICT:-indeterminate} (rc=${_AH_PROBE_RC:-?} cmd=${_C_CHECK_CMD:-})"
    exit 0 ;;
  --clear)
    if [ -f "$AUTH_ENV" ]; then
      cp -f "$AUTH_ENV" "$AUTH_ENV.prev" 2>/dev/null || true
      chmod 600 "$AUTH_ENV.prev" 2>/dev/null || true
      rm -f "$AUTH_ENV"
      say "✓ removed $AUTH_ENV (backup: $AUTH_ENV.prev, 0600)"
      say "  the worker reverts to the box's own claude credentials on its next spawn."
      say "  next: touch $REFRESH_FLAG   # to restart the worker onto them now"
    else
      say "nothing to clear — $AUTH_ENV does not exist."
    fi
    exit 0 ;;
  '')
    : ;;
  *)
    # never accept the token as an argument — argv leaks to /proc + shell history
    die "unexpected argument. NEVER pass the token on the command line (it leaks into shell history and /proc). Run plain \`bash $0\` and paste at the hidden prompt — see --help"
    ;;
esac

say "── Claude Code re-login (headless turnkey) ────────────────────"
say "repo:       $REPO_DIR"
say "supervisor: $(supervisor_state)"
if [ -f "$FLAG" ]; then
  say "escalation: ACTIVE — $(sed -n '2p' "$FLAG" 2>/dev/null | tr -cd '[:print:]' | head -c 120 || true)"
else
  say "escalation: none (proactive token rotation is fine too)"
fi
say ""

# ── token intake: env var, else a hidden prompt — never argv ─────────────────
tok="${CLAUDE_CODE_OAUTH_TOKEN:-}"
if [ -n "$tok" ]; then
  say "using CLAUDE_CODE_OAUTH_TOKEN from the environment (len ${#tok})"
else
  say "if you haven't yet: run  claude setup-token  on any machine with a browser, copy the token."
  printf 'paste the fresh CLAUDE_CODE_OAUTH_TOKEN (input hidden): '
  IFS= read -rs tok || true
  printf '\n'
fi
tok="${tok//[$'\r\n\t ']/}"   # strip whitespace a paste can drag in
[ -n "$tok" ] || die "no token provided — nothing changed. Next: claude setup-token (browser machine), then re-run this."
[ "${#tok}" -ge 20 ] || die "that's too short to be a token (len ${#tok}) — nothing changed. Copy the full sk-ant-oat… value from claude setup-token."
if ! [[ "$tok" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
  die "token contains unexpected characters — paste the raw sk-ant-oat… value only. Nothing changed."
fi
case "$tok" in
  sk-ant-*) : ;;
  *) say "⚠ token doesn't start with sk-ant- (setup-token normally emits sk-ant-oat…) — continuing, the verify step below is the real gate" ;;
esac

# ── persist: 0600, atomic, backup-first, gitignored (.kickoff/) ───────────────
umask 077
mkdir -p "$KICKOFF_DIR"
if [ -f "$AUTH_ENV" ]; then
  cp -f "$AUTH_ENV" "$AUTH_ENV.prev" 2>/dev/null || true
  chmod 600 "$AUTH_ENV.prev" 2>/dev/null || true
fi
printf '# written by scripts/relogin.sh %s — imported by session-run.sh at every spawn\nexport CLAUDE_CODE_OAUTH_TOKEN=%q\n' \
  "$(date -u +%FT%TZ)" "$tok" > "$AUTH_ENV.tmp"
chmod 600 "$AUTH_ENV.tmp"
mv -f "$AUTH_ENV.tmp" "$AUTH_ENV"
say "✓ token persisted: $AUTH_ENV (0600; ${#tok} chars — never logged)"

# ── verify: the same probe the supervisor runs, with the NEW token ────────────
export CLAUDE_CODE_OAUTH_TOKEN="$tok"
probe_now
verdict="${_AH_VERDICT:-indeterminate}"
say "auth verify: $verdict (rc=${_AH_PROBE_RC:-?} cmd=${_C_CHECK_CMD:-})"

finish_resume() {
  # clear the escalation + ask the supervisor for a fresh session (its existing,
  # PGID-safe refresh path — relogin itself never kills anything)
  if [ -f "$FLAG" ]; then
    rm -f "$FLAG"
    say "✓ escalation flag cleared ($FLAG)"
  fi
  : >> "$REFRESH_FLAG"
  say "✓ refresh flag touched ($REFRESH_FLAG)"
  if [ "$(supervisor_state)" = "not running" ]; then
    say ""
    say "NEXT: the supervisor is NOT running — start it:"
    say "  bash $HERE/start-supervisor.sh          # relay mode"
    say "  bash $HERE/go-autonomous.sh             # autonomous mode"
  else
    say ""
    say "NEXT: nothing — the supervisor picks the flag up within ~15s and spawns a fresh"
    say "session with the new token; it will announce itself on Telegram."
  fi
}

case "$verdict" in
  valid)
    finish_resume
    ;;
  expired)
    say ""
    say "✗ auth STILL FAILING with the new token — flag NOT cleared, worker stays paused."
    say "  output: ${_AH_PROBE_HEAD:-}"
    say "NEXT: the token may be mistyped/revoked — run claude setup-token again and re-run:"
    say "  bash $0"
    say "  (to revert to the box's own claude login instead: bash $0 --clear)"
    exit 2
    ;;
  *)
    say ""
    say "⚠ could not VERIFY (probe unavailable on this box: rc=${_AH_PROBE_RC:-?}) — trusting your paste."
    finish_resume
    say "if the worker re-escalates, the token didn't take — run claude setup-token again."
    ;;
esac

unset tok CLAUDE_CODE_OAUTH_TOKEN
exit 0
