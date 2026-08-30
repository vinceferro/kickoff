#!/usr/bin/env bash
# session-run.sh — the START_CMD wrapper the supervisor spawns.
#
# Replaces the old silent `claude -p "...re-ground..."` placeholder with the REAL
# "run it from your pocket unattended" worker: a PERSISTENT, Telegram-bridged,
# self-announcing, re-grounding interactive session.
#
# WHY interactive (--channels) and not `claude -p`:
#   The Telegram plugin long-polls getUpdates and PUSHES inbound messages into the
#   session as MCP notifications (rendered as <channel> blocks); the session replies
#   via the `reply` MCP tool. `claude -p` is ONE-SHOT — it runs a single turn, stdin
#   EOFs, the plugin's poller shuts down, and the bridge dies. So this wrapper runs an
#   INTERACTIVE session (`--channels`) whose stdin NEVER EOFs (a keepalive), keeping
#   the bridge alive for the life of the session.
#
# ── HARD CONSTRAINTS (so the supervisor stays kill-safe) ─────────────────────
#   - FOREGROUND, and `exec`s into claude → PID-preserving, so the supervisor's
#     process-group target reaches the real claude child.
#   - NEVER daemonize / double-fork / setsid / disown internally. The supervisor
#     already launches us inside our OWN process group (setsid); escaping it here
#     would break refresh/kill-safety.
#   - The stdin-keepalive helper (tail -f /dev/null) MUST stay IN-GROUP — no
#     setsid/disown on it — so the supervisor's `kill -- -PGID` reaps it too and
#     no orphan `tail` is left behind.
#
# ── TWO-COORDINATOR WARNING ──────────────────────────────────────────────────
#   Telegram allows exactly ONE getUpdates consumer per bot token. If this
#   unattended worker uses the SAME bot token + STATE_DIR as a concurrent
#   interactive `--channels` session, the two pollers FIGHT (each steals the
#   other's updates). An unattended worker MUST use a DISTINCT bot token +
#   STATE_DIR. Configured per-instance in .kickoff/instance.env (TELEGRAM_STATE_DIR);
#   the core has NO default channel and FAILS LOUD if it's unset, so no instance can
#   silently inherit another's channel.
#
# ── USAGE ────────────────────────────────────────────────────────────────────
#   Set TELEGRAM_STATE_DIR (+ the rest) in .kickoff/instance.env, then:
#     bash scripts/session-run.sh
#   One-off override (wins over instance.env):
#     TELEGRAM_STATE_DIR=~/.claude/channels/telegram-worker bash scripts/session-run.sh

set -euo pipefail

# NEVER `set -x` in this script — it would echo the bot token (it transits the
# Bot-API URL). Keep tracing off.

REPO_DIR="${REPO_DIR:-$(pwd)}"
REPO_DIR="$(cd "$REPO_DIR" && pwd)"
KICKOFF_DIR="$REPO_DIR/.kickoff"
mkdir -p "$KICKOFF_DIR"

# ── INSTANCE CONFIG ──────────────────────────────────────────────────────────
# One per-instance env file (gitignored, instance-local) supplies everything that
# differs between adopters — Telegram channel, memory index, MC state file, retrieval
# paths, permission mode, caps. The CORE scripts stay parameter-clean: an adopter pulls
# this script UNCHANGED and provides their own .kickoff/instance.env (copied from
# scripts/instance.env.example). This is the line that stops copy-fragmentation — no
# adopter hand-patches this file.
#
# UNTRUSTED CONFIG, not trusted code: instance.env is gitignored (invisible in review)
# and could forge a launch-control var (PREFLIGHT_SKIP/DRY_RUN), `exit 0` to abort us, or
# redefine a shell function. So we do NOT source it into THIS shell — we source it in a
# SUBSHELL and import back ONLY the whitelisted CONFIG var NAMES (the frozen cross-file
# whitelist, identical in preflight.sh + kickoff). Values round-trip through printf %q +
# eval, so shell metacharacters in a value stay LITERAL (no import-time injection), and
# PREFLIGHT_SKIP/DRY_RUN — absent from the list — can NEVER arrive from this file; an
# `exit 0` or a function redef inside it dies with the subshell, never touching us.
INSTANCE_ENV="${INSTANCE_ENV:-$KICKOFF_DIR/instance.env}"
if [ -f "$INSTANCE_ENV" ]; then
  # shellcheck disable=SC1090
  eval "$(
    set +eu
    . "$INSTANCE_ENV" >/dev/null 2>&1 || true
    for _ie_n in REPO_DIR KICKOFF_CORE_DIR MC_STATE_FILE MC_TRACKER_FILE \
                 MEMORY_DB MEMORY_HOOK_LOG MEMORY_DIR MEMORY_INDEX \
                 TELEGRAM_STATE_DIR CHANNEL_SPEC REGROUND_PROMPT PERMISSION_MODE EFFORT \
                 MAX_CONCURRENT_AGENTS DEPLOY_BRANCH CADENCE; do
      _ie_v="${!_ie_n}"
      if [ -n "$_ie_v" ]; then printf 'export %s=%q\n' "$_ie_n" "$_ie_v"; fi
    done
  )"
fi

# ── AUTH ENV (scripts/relogin.sh turnkey) ─────────────────────────────────────
# .kickoff/auth.env carries ONLY a fresh CLAUDE_CODE_OAUTH_TOKEN (written 0600 by
# relogin.sh after a `claude setup-token` re-login; gitignored via .kickoff/). Imported
# with the SAME untrusted-config discipline as instance.env above: sourced in a
# SUBSHELL, only the ONE whitelisted name round-trips back through printf %q — the file
# can neither abort this wrapper nor forge launch-control vars. A pre-set env value
# wins; file absent → no-op (today's auth path, byte-identical).
AUTH_ENV="${AUTH_ENV:-$KICKOFF_DIR/auth.env}"
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -f "$AUTH_ENV" ]; then
  # shellcheck disable=SC1090
  eval "$(
    set +eu
    . "$AUTH_ENV" >/dev/null 2>&1 || true
    if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
      printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q\n' "$CLAUDE_CODE_OAUTH_TOKEN"
    fi
  )"
fi

# Which Telegram channel this worker is bridged to. NO baked-in default — fail LOUD if
# unset. Defaulting to origin's channel is exactly how two instances' pollers collide
# (one bot token = one getUpdates consumer). Each instance declares its own in instance.env.
# Trim whitespace before the empty-check so a blank "   " value can't slip past [ -z ] and
# leave the worker with no channel (mirrors preflight.sh's tsd_trimmed guard).
tsd_trimmed="${TELEGRAM_STATE_DIR:-}"
tsd_trimmed="${tsd_trimmed//[[:space:]]/}"
if [ -z "$tsd_trimmed" ]; then
  echo "FATAL: TELEGRAM_STATE_DIR is unset or blank." >&2
  echo "       Set it in ${INSTANCE_ENV} (copy scripts/instance.env.example)." >&2
  echo "       No default on purpose: inheriting origin's channel is the double-poller footgun." >&2
  exit 1
fi
# Reject the example's placeholder — two instances left on it would collide on the same channel.
case "$TELEGRAM_STATE_DIR" in
  *YOUR-WORKER*)
    echo "FATAL: TELEGRAM_STATE_DIR still holds the example placeholder ($TELEGRAM_STATE_DIR)." >&2
    echo "       Set a REAL dedicated channel dir in ${INSTANCE_ENV} — the placeholder collides." >&2
    exit 1 ;;
esac

SETTINGS_FILE="${SETTINGS_FILE:-$REPO_DIR/.claude/settings.local.json}"
ACCESS_FILE="$TELEGRAM_STATE_DIR/access.json"

# Which telegram plugin serves the bridge: the official telegram@claude-plugins-official,
# the only supported spec. Multi-project isolation is a state-dir + token concern —
# per-project TELEGRAM_STATE_DIR + TELEGRAM_BOT_TOKEN — never a plugin fork (a custom
# channel plugin is not on the approved-channels allowlist, so its bridge exits at
# boot: a silently deaf worker). NOTE: --channels needs the tagged
# plugin:<name>@<marketplace> form — a bare plugin:telegram is a parse error.
CHANNEL_SPEC="${CHANNEL_SPEC:-plugin:telegram@claude-plugins-official}"

# The memory index the re-ground prompt points the worker at (instance-overridable
# via MEMORY_INDEX in instance.env). Interpolated into the default prompt below.
MEMORY_INDEX="${MEMORY_INDEX:-memory/MEMORY.md}"

# The re-ground system-prompt append. Overridable per-instance (set REGROUND_PROMPT in
# instance.env to change the worker's operating charter wholesale); the default template
# interpolates ${MEMORY_INDEX} so an adopter needs only set the var, not rewrite the prompt.
if [ -z "${REGROUND_PROMPT:-}" ]; then
  REGROUND_PROMPT="You are a HEADLESS supervised worker session — NO human is at the terminal; the operator steers you ONLY via Telegram. You are the same coordinator, freshly looped (not a replacement). OPERATING RULES: (1) RE-GROUND first: read CLAUDE.md, ${MEMORY_INDEX} (+ relevant memory/ files), and TRACKER.md. (2) Do all REVERSIBLE work autonomously — build, test, commit, run checks — without asking. (3) For anything GATED (spend, destruction, pushing to a shared remote, anything irreversible or risky) or any turnkey only a human-at-a-terminal can run: STOP, ASK the operator with a Telegram reply — a crisp one-line decision OR one clean runnable command — and WAIT for his explicit go before proceeding. (4) NEVER wait on a terminal permission prompt — there is no one there; route every question to Telegram, and if an action is blocked, tell him and hand him the turnkey. (5) Post brief progress beats; never go silent for long while working. (6) On THIS startup: announce yourself to the operator (you're back + caught up + a one-line state summary + what's queued next per the tracker), then AWAIT his steer — do NOT start new substantial work unprompted. (7) ULTRACODE POSTURE (operator opted in): for substantial multi-step work, author and run a Workflow — fan out to LEAST-PRIVILEGE specialist subagents (builder/reviewer/planner) that have NO Telegram tool, so they never post to his channel; YOU are the only voice to the operator and you relay the synthesis. Reserve solo work for trivial/conversational turns. Token cost is not the constraint here; correctness + thoroughness are."
fi

log() { printf '[session-run %s] %s\n' "$(date -u +%H:%M:%S 2>/dev/null || echo now)" "$*"; }

# ── STARTUP ANNOUNCE (heartbeat) ─────────────────────────────────────────────
# A one-shot "I'm (re)starting" ping so the operator sees the worker came back
# even before the session has re-grounded. Best-effort: any missing piece (jq,
# files, token, chat id, or a failed curl) skips the announce and NEVER aborts
# the wrapper. The bot token is read at RUNTIME and never echoed/logged.
announce_restart() {
  # Restart counter (tracks EVERY spawn) + a send-cooldown so a crash-loop can't
  # spam the operator's pocket. The counter still increments each restart, so when
  # an announce does send it reveals the loop ("restart #N"). Cooldown default 30s
  # (override ANNOUNCE_COOLDOWN); the supervisor's trigger-3 backoff is only ~5s.
  local count now last
  count="$(cat "$KICKOFF_DIR/announce.count" 2>/dev/null || echo 0)"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  count=$((count + 1))
  echo "$count" > "$KICKOFF_DIR/announce.count" 2>/dev/null || true
  now="$(date +%s 2>/dev/null || echo 0)"
  last="$(cat "$KICKOFF_DIR/announce.last" 2>/dev/null || echo 0)"
  [[ "$now"  =~ ^[0-9]+$ ]] || now=0
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if [ "$now" -gt 0 ] && [ "$last" -gt 0 ] && [ "$((now - last))" -lt "${ANNOUNCE_COOLDOWN:-30}" ]; then
    log "announce: restart #$count within ${ANNOUNCE_COOLDOWN:-30}s cooldown — skipping send (anti crash-loop spam)"
    return 0
  fi

  command -v jq   >/dev/null 2>&1 || { log "announce: jq not found — skipping"; return 0; }
  command -v curl >/dev/null 2>&1 || { log "announce: curl not found — skipping"; return 0; }
  [ -f "$SETTINGS_FILE" ] || { log "announce: no settings file — skipping"; return 0; }
  [ -f "$ACCESS_FILE" ]   || { log "announce: no access.json — skipping"; return 0; }

  local token chat_id
  token="$(jq -r '.env.TELEGRAM_BOT_TOKEN // empty' "$SETTINGS_FILE" 2>/dev/null || true)"
  chat_id="$(jq -r '.allowFrom[0] // empty' "$ACCESS_FILE" 2>/dev/null || true)"
  if [ -z "$token" ] || [ -z "$chat_id" ]; then
    log "announce: token or chat_id missing — skipping (no announce)"
    return 0
  fi

  # Record the send time only when we actually send, so the cooldown gates real sends.
  echo "$now" > "$KICKOFF_DIR/announce.last" 2>/dev/null || true

  # Meaningful announce (memory/operator-reconnect-message-meaningful.md): lead with
  # the WORK, not the refresh mechanics. Read the CURRENT board state — the `headline`
  # is the coordinator-maintained "what's the org doing now" line, rewritten at every
  # checkpoint; `in_progress[0]` is insertion-ordered so its [0] is the OLDEST item and
  # fossilizes as the org marches on (it froze the ping for ~10 restarts — msg 1492). So
  # prefer the headline, fall back to in_progress[0] (an adopter with no headline yet),
  # treating an empty-string headline as absent. Any failure degrades to the generic
  # line — the announce itself must never break on a board hiccup.
  local work="" text=""
  local mc_state="${MC_STATE_FILE:-$REPO_DIR/mission-control/mission-state.json}"
  if [ -f "$mc_state" ]; then
    work="$(jq -r '[.headline, .in_progress[0].text] | map(select(type=="string" and . != "")) | .[0] // ""' "$mc_state" 2>/dev/null || true)"
    work="${work//$'\n'/ }"
    if [ "${#work}" -gt 160 ]; then work="${work:0:157}…"; fi
  fi
  if [ -n "$work" ]; then
    text="👨‍🍳 Worker back (restart #${count}) — org is cooking on: ${work}"
  else
    text="👨‍🍳 Worker back (restart #${count}) — re-grounded; ping me a steer."
  fi

  # The token unavoidably transits the Bot-API URL — but it must NOT land in the process
  # table (/proc/<pid>/cmdline, ps), where every worker restart would otherwise expose it.
  # So the URL is fed to curl OFF argv: printf writes `url=<...>` to a curl config that curl
  # reads from STDIN (-K -). printf is a bash builtin (no separate process, no /proc entry),
  # and curl's argv now carries only the non-secret chat_id + text. curl -s, no -x. A
  # non-zero curl must NOT abort the wrapper (the `if` neutralises set -e/pipefail here).
  local api_url="https://api.telegram.org/bot${token}/sendMessage"
  if printf 'url=%s\n' "$api_url" | curl -s -o /dev/null \
       --max-time 10 \
       --data-urlencode "chat_id=${chat_id}" \
       --data-urlencode "text=${text}" \
       -K - 2>/dev/null; then
    log "announce: sent restart #$count heartbeat to chat ${chat_id}"
  else
    log "announce: curl failed (non-fatal) — continuing without announce"
  fi
  unset token api_url
}

# ── PTY WRAP — fix: claude --channels needs a TTY to process inbound ──────────
# Verified root cause (2026-06-25): `claude --channels` with a NON-TTY piped stdin
# (the tail -f keepalive) never enters its notification-processing loop — the
# headless worker did ZERO turns on inbound Telegram messages (no re-ground, no
# reply). script(1) allocates a /dev/pts so claude sees a TTY and goes interactive.
# We re-exec THIS script inside the pty (avoids quoting the huge prompt); the inner
# pass (_PTY_WRAPPED=1) skips this block and execs claude with the pty as stdin.
# The keepalive feeds `script`; claude inherits the pty. The supervisor kills the
# whole process-group (kill -- -PGID), so script + claude are both reaped — still
# kill-safe (group-targeted, not PID-targeted).
if [ "${_PTY_WRAPPED:-0}" != "1" ]; then
  log "pty-wrap: re-exec inside script(1) so claude --channels sees a TTY + processes inbound"
  exec script -qfe -c "_PTY_WRAPPED=1 exec bash '$0'" /dev/null < <(tail -f /dev/null)
fi

announce_restart

# ── REAP-ON-STARTUP — free THIS channel's getUpdates slot before claude spawns ─
# The official plugin's bridge SIGTERMs whatever pid bot.pid names at ITS boot (server.ts
# boot-time takeover) — but claude never RESPAWNS a bridge that later loses that war, so a
# stale consumer (an orphan from a prior core, a nested `claude -p` that inherited this
# worker's env) leaves the fresh worker DEAF. scripts/bridge-reap.sh reaps the VERIFIED-stale
# holder here — bot.pid-anchored, /proc-verified (bridge argv signature + the SAME
# TELEGRAM_STATE_DIR in its environ + never inside our own launch tree), EXACT pid only,
# FAIL TOWARD NOT KILLING — so the fresh bridge boots into a clean slot. Runs exactly once
# per spawn (inner pty pass), before `exec claude`. Sourced with the auth-heal.sh discipline:
# bash -n gated, no-op stub if absent/broken, and the helper's body runs in a subshell so no
# bug (incl. set -u) can abort this wrapper. KICKOFF_BRIDGE_REAP=0 disables (plain env knob,
# deliberately NOT an instance.env whitelist var).
_BR_HELPER="$(cd "$(dirname "$0")" && pwd)/bridge-reap.sh"
if [ -f "$_BR_HELPER" ] && bash -n "$_BR_HELPER" 2>/dev/null; then
  # shellcheck source=scripts/bridge-reap.sh
  . "$_BR_HELPER" || true
fi
if ! command -v reap_stale_bridge >/dev/null 2>&1; then reap_stale_bridge() { :; }; fi
reap_stale_bridge || true

# ── STDIN KEEPALIVE ──────────────────────────────────────────────────────────
# The interactive claude must read a stdin that never EOFs, or the plugin's
# poller shuts down when stdin closes and the bridge dies. `tail -f /dev/null`
# is an endless, empty stream. Wiring it via process substitution keeps the
# `tail` IN this process group (no setsid/disown), so the supervisor's
# `kill -- -PGID` reaps it along with claude — no orphan tail.
log "starting interactive Telegram-bridged session (channel=$CHANNEL_SPEC, state_dir=$TELEGRAM_STATE_DIR)"
log "stdin keepalive: tail -f /dev/null (in-group)"

# PERMISSION MODE — SAFE BY DEFAULT, AUTO IS OPT-IN AT THE TERMINAL.
#   Defaults to 'default': the worker prompts on gated actions, and those prompts relay to
#   the operator's phone (the telegram plugin's permission relay) for Allow/Deny. To run the
#   worker FULL auto (execute REVERSIBLE work without asking — the cure for the read-only
#   wall, see memory/unattended-worker-needs-pregranted-permissions.md), the operator opts in
#   AT THE TERMINAL: `PERMISSION_MODE=auto bash scripts/start-supervisor.sh`. Arming an
#   autonomous self-executing worker is a deliberate HUMAN grant that an untrusted channel
#   (a Telegram message) must NOT authorize — the harness blocks doing it from the chat.
#   Spend/destruction stay gated by the harness regardless of mode.
# NO STDIN TRIGGER: feeding claude an initial stdin message makes `claude --channels` behave
# ONE-SHOT (process the line, then exit) → a restart cycle (observed live). So stdin is a pure
# never-EOF keepalive (tail -f, in-group) and the worker stays interactive. The startup
# heartbeat (curl above) tells the operator it's up; his FIRST Telegram message kicks the
# worker's first turn (it re-grounds + announces per REGROUND_PROMPT). A hands-free
# auto-announce mechanism is under investigation.

# ── §5 THE PLUGIN — headless path (design §1.3/§2.4 + the coordinator dogfood-safety correction) ─
# The interactive adopter runs the kickoff plugin from the user-global CACHE; the HEADLESS worker
# instead execs the plugin from SOURCE via `--plugin-dir "$KICKOFF_CORE_DIR/plugin"` (cache-free,
# drift-free — the pinned clone is the source of truth). Build the arg as an ARRAY, gated STRICTLY
# on BOTH: KICKOFF_CORE_DIR is set AND $KICKOFF_CORE_DIR/plugin exists — with NO $REPO_DIR/plugin
# fallback. This is load-bearing dogfood-safety: THIS repo IS the live headless worker's engine, and
# the origin has NO KICKOFF_CORE_DIR (verified) + NO enabledPlugins (verified). A KICKOFF_CORE_DIR-
# gated arg keeps the origin 100% INERT on its next refresh — its argv gains NO --plugin-dir, so it
# never auto-loads the half-built plugin (which would risk a memory-hook double-fire + MCP conflict).
# A $REPO_DIR/plugin fallback would activate the plugin for the live origin the moment plugin/ exists
# — FORBIDDEN. An adopter (KICKOFF_CORE_DIR set to their pinned clone + plugin present) gets the arg.
PLUGIN_ARGS=()
if [ -n "${KICKOFF_CORE_DIR:-}" ] && [ -d "$KICKOFF_CORE_DIR/plugin" ]; then
  # Fix 5 — ENFORCE origin-inertness (don't merely rely on KICKOFF_CORE_DIR happening to be unset). An
  # ADOPTER's core is a SEPARATE pinned clone (KICKOFF_CORE_DIR != the adopter repo); the ORIGIN is
  # SELF-REFERENTIAL — supervisor.sh:60 defaults KICKOFF_CORE_DIR to the repo root, so if that value
  # ever reaches the session env (a stray `export`, a `set -a`, an instance.env line) KICKOFF_CORE_DIR
  # would EQUAL REPO_DIR and the live origin would auto-load its own HALF-BUILT plugin — the memory-
  # hook double-fire + chrome-devtools MCP re-declaration the spec names as the highest-consequence
  # dogfood risk. So add --plugin-dir ONLY when the core resolves to a DIFFERENT repo than this one.
  # Both are symlink-resolved (pwd -P) for a like-for-like compare.
  _kcd_real="$(cd "$KICKOFF_CORE_DIR" 2>/dev/null && pwd -P || printf '%s' "$KICKOFF_CORE_DIR")"
  _repo_real="$(cd "$REPO_DIR" 2>/dev/null && pwd -P || printf '%s' "$REPO_DIR")"
  if [ "$_kcd_real" = "$_repo_real" ]; then
    log "plugin: KICKOFF_CORE_DIR == REPO_DIR (self-referential origin) — argv gains NO --plugin-dir (origin stays INERT, dogfood-safe)"
  else
    PLUGIN_ARGS=(--plugin-dir "$KICKOFF_CORE_DIR/plugin")
    log "plugin: headless --plugin-dir $KICKOFF_CORE_DIR/plugin (source-exec, cache-free)"
  fi
else
  log "plugin: no KICKOFF_CORE_DIR/plugin — origin-inert, argv gains NO --plugin-dir (dogfood-safe)"
fi

# stdin is already the pty (from the script(1) wrap above) — do NOT redirect it,
# or claude loses the TTY and stops processing channel notifications.
# EFFORT — the reasoning tier. 'max' = the operator's "ultracode" ask (deepest reasoning
# + the Workflow/multi-agent posture in REGROUND_PROMPT rule 7). Env-overridable; the
# autonomous switch (go-autonomous.sh) sets EFFORT=max. Levels: low|medium|high|xhigh|max.
# MODEL — pin the coordinator's model (a FAMILY alias: sonnet|opus). DEFAULT UNSET ⇒ MODEL_ARGS
# stays EMPTY ⇒ zero args added ⇒ the exec inherits the box's Claude Code model config, byte-for-
# byte today's behaviour (unset MODEL must NEVER downgrade the live coordinator). Set it (a one-off,
# or go-autonomous.sh) to override. Same empty-array idiom as PLUGIN_ARGS — NOT `local` (this is
# top-level scope, where `local` aborts under set -e).
MODEL_ARGS=(); [ -n "${MODEL:-}" ] && MODEL_ARGS=(--model "$MODEL")
# "${PLUGIN_ARGS[@]}" + "${MODEL_ARGS[@]}" are empty-array-safe under set -u on bash 4.4+ (this box: 5.2).
exec claude \
  --channels "$CHANNEL_SPEC" \
  "${PLUGIN_ARGS[@]}" \
  "${MODEL_ARGS[@]}" \
  --permission-mode "${PERMISSION_MODE:-default}" \
  --effort "${EFFORT:-high}" \
  --append-system-prompt "$REGROUND_PROMPT"
