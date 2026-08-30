#!/usr/bin/env bash
# model-fallback-selftest.sh — hermetic proof of the supervisor's REACTIVE model-quota
# fallback belt (v0.8): when the running worker hits its model's weekly quota wall, every
# turn fails while the supervisor/session/bridge all stay alive (liveness ≠ capability). The
# belt detects the limit string in the session's pty output (captured to the supervisor log),
# switches the worker to a cheaper fallback model, alerts the operator, and LATCHES — WITHOUT
# spawning any real session, cycling a real supervisor, or touching a live worker.
#
# HOW IT STAYS HERMETIC:
#   - It EXTRACTS the "KICKOFF-MODEL-FALLBACK-UNIT" block from scripts/supervisor.sh (the
#     detector, the config loader, the instance.env rewrite, the poll-step) and drives it in
#     isolated subshells against FIXTURES (a supervisor.log carrying the REAL ANSI-wrapped
#     limit line; a fixture instance.env).
#   - Its dependencies (refresh / tg_send_tokenless / log) are STUBBED so a call is OBSERVED
#     (appended to a scratch file), never real. refresh() deliberately does NOT reset the
#     belt's latch — it mirrors the real supervisor, where refresh()/start_session leave
#     MODEL_FALLBACK_LATCHED alone (that is what makes the belt one-shot across its own cycle).
#   - Everything lives under a scratch dir. No git state, no live process, no network.
#
# RED-ON-OLD: it re-runs the new-behavior assertions against a saved copy of HEAD's
# supervisor.sh and asserts at least one FAILS there — a test that passes on old code proves
# nothing. On HEAD the unit does not exist, so extraction yields an empty unit and every belt
# assertion fails (the function is undefined). When the working-tree unit is byte-identical to
# HEAD's (the normal post-commit state) the proof is N/A and auto-SKIPPED.
#
# Usage:  bash scripts/model-fallback-selftest.sh
# Exit non-zero on any failed assertion (or if RED-on-old is not proven).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUPERVISOR_NEW="$SCRIPT_DIR/supervisor.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/model-fallback-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$1" = "$2" ]; then ok "$3 (=$1)"; else bad "$3 (want=$2 got=$1)"; fi; }

# ── the REAL ANSI-laden limit line (byte-faithful to the 2026-07-13 incident log) ──────
# Both markers — the "reached your <Model> limit" phrasing AND the /usage-credits co-marker
# — land on ONE physical line, exactly as Claude Code printed it. ESC bytes are interspersed
# before/after the phrase (colour + cursor-move redraw), so this is the genuine haystack the
# raw grep must survive.
write_limit_line() {  # $1 = target log file (appends)
  printf '\033[38;5;246m  \342\216\277 \302\240\033[38;5;211mYou'\''ve reached your Fable 5 limit. Run /usage-credits to continue or switch\r\033[1B\033[39m\n' >> "$1"
}
# a DIFFERENT model's wall (same shape) — used to prove the phrasing generalises
write_opus_limit_line() {  # $1 = target log file (appends)
  printf '\033[38;5;211mYou'\''ve reached your Opus limit. Run /usage-credits to continue or switch models\r\033[1B\n' >> "$1"
}
write_sonnet_limit_line() {  # $1 = target log file (appends)
  printf '\033[38;5;211mYou'\''ve reached your Sonnet limit. Run /usage-credits to continue or switch\r\033[1B\n' >> "$1"
}
# benign worker chatter that MENTIONS limits/quota AND /usage-credits — but never both the
# model-limit phrasing AND the co-marker on the SAME line. A loose detector (grep "limit", or
# two-markers-anywhere) would FALSE-FIRE here; the same-line two-marker guard must NOT.
write_benign_log() {  # $1 = target log file (appends)
  {
    printf 'I checked and we have nearly reached your account limit for the week.\n'
    printf 'You can run /usage-credits to see the remaining balance if you want.\n'
    printf 'Approaching the weekly usage limit; quota is getting tight on this model.\n'
    printf 'The user hit your daily message cap yesterday but it reset overnight.\n'
  } >> "$1"
}
# finding #4: BOTH markers on ONE physical line (no interior newline) but FAR apart — the shape the
# real pty log takes (a single redraw burst can be MB-wide with the two markers in different UI
# regions). A same-grep-line detector FALSE-FIRES here; the tight proximity bound must NOT. ~200
# filler chars sit between "limit" and "/usage-credits", well past the .{0,24} window.
write_farline_log() {  # $1 = target log file (appends)
  printf "You've reached your Fable 5 limit%*sand separately mentions /usage-credits here\n" 200 '' >> "$1"
}

# ── a fixture instance.env (several lines incl. comments; ONE active MODEL line) ────────
write_instance_env() {  # $1 = target file, $2 = the MODEL value to pin
  cat > "$1" <<EOF
# instance.env fixture (model-fallback selftest)
export TELEGRAM_STATE_DIR="/home/x/.claude/channels/telegram-worker"
MODEL=$2
export EFFORT="high"
# a commented pin that must be left ALONE:  # MODEL=sonnet
MODEL_FALLBACK_TO=opus
export MAX_CONCURRENT_AGENTS="4"
EOF
}

# ── extract the testable unit from a given supervisor.sh ───────────────────────────────
extract_unit() {
  # prints the lines strictly BETWEEN the two KICKOFF-MODEL-FALLBACK-UNIT marker lines
  # (the ONLY lines bearing that token, so the toggle is unambiguous)
  awk '/KICKOFF-MODEL-FALLBACK-UNIT/{f=!f; next} f' "$1"
}

# ── the harness: source the extracted unit + stubs, expose state + observers ───────────
HARNESS="$WORK/harness.sh"
cat > "$HARNESS" <<'EOF'
REFRESH_LOG="${REFRESH_LOG:?}"; ALARM_LOG="${ALARM_LOG:?}"
log() { :; }                                   # quiet (scenarios that need it override)
# refresh(): OBSERVE the reason, then MIRROR the REAL refresh()→start_session, which now RE-ARMS
# the belt for the fresh session (v0.8 finding #2): it resets MODEL_FALLBACK_LATCHED and the
# recurrence counters to 0. This is what lets a LATER wall on the fallback model be caught (an
# opus-own-limit → already-on-fallback alert) instead of being swallowed forever by a permanent
# process-wide latch. The N-tick recurrence gate — not the latch — is what stops the belt's own
# switch+refresh from immediately re-firing.
refresh() {
  printf '%s\n' "$1" >> "$REFRESH_LOG"
  MODEL_FALLBACK_LATCHED=0
  MODEL_FALLBACK_HITS=0
  MODEL_FALLBACK_LAST_HIT=0
}
# the tokenless Telegram send — OBSERVED, never real
tg_send_tokenless() { printf '%s\n' "$1" >> "$ALARM_LOG"; }

# supervisor globals the unit reads (scenarios override via env)
KICKOFF_DIR="${KICKOFF_DIR:?}"; mkdir -p "$KICKOFF_DIR"
REPO_DIR="${REPO_DIR:-$WORK}"
DRY_RUN="${DRY_RUN:-0}"
MODEL_FALLBACK_OFFSET="${MODEL_FALLBACK_OFFSET:-0}"
MODEL_FALLBACK_LATCHED="${MODEL_FALLBACK_LATCHED:-0}"
MODEL_FALLBACK_HITS="${MODEL_FALLBACK_HITS:-0}"
MODEL_FALLBACK_LAST_HIT="${MODEL_FALLBACK_LAST_HIT:-0}"

. "$UNIT_FILE"                                  # define model_fallback_step / _mf_* helpers

# drive ONE poll tick that observes a fresh failing turn (append a wall line, then step). A real
# wall reprints every turn, so N ticks model N recurrences; the belt acts only once confirmed.
tick_wall()  { write_limit_line      "$SUPERVISOR_LOG"; model_fallback_step; }  # fable wall
tick_owall() { write_opus_limit_line "$SUPERVISOR_LOG"; model_fallback_step; }  # opus wall
EOF

# run one scenario body ($1) in an isolated subshell against $UNIT_FILE.
run_scenario() {
  local body="$1"
  REFRESH_LOG="$WORK/refresh.$$.$RANDOM"; ALARM_LOG="$WORK/alarm.$$.$RANDOM"
  : > "$REFRESH_LOG"; : > "$ALARM_LOG"
  (
    export WORK REFRESH_LOG ALARM_LOG UNIT_FILE KICKOFF_DIR REPO_DIR
    export DRY_RUN SUPERVISOR_LOG INSTANCE_ENV MODEL MODEL_FALLBACK MODEL_FALLBACK_TO
    export MODEL_FALLBACK_OFFSET MODEL_FALLBACK_LATCHED
    set +e
    . "$HARNESS"
    eval "$body"
  )
  R_COUNT="$(grep -c . "$REFRESH_LOG" 2>/dev/null)"; R_COUNT="${R_COUNT:-0}"
  A_COUNT="$(grep -c . "$ALARM_LOG" 2>/dev/null)";   A_COUNT="${A_COUNT:-0}"
  R_LAST="$(tail -n1 "$REFRESH_LOG" 2>/dev/null || echo '')"
  A_TEXT="$(cat "$ALARM_LOG" 2>/dev/null || echo '')"
}

# helper: reset a scenario's private KICKOFF_DIR / log / instance.env
new_env() {  # $1 = tag, $2 = MODEL pin for instance.env
  KICKOFF_DIR="$WORK/kick.$1"; mkdir -p "$KICKOFF_DIR"; rm -f "$KICKOFF_DIR/model-fallback"
  SUPERVISOR_LOG="$WORK/suplog.$1"; : > "$SUPERVISOR_LOG"
  INSTANCE_ENV="$WORK/ienv.$1"; write_instance_env "$INSTANCE_ENV" "$2"
}

# ── the assertion suite (run against NEW = expect all-green; OLD = expect reds) ─────────
# The belt requires the wall to RECUR across MODEL_FALLBACK_CONFIRMATIONS (default 2) SEPARATE ticks
# before acting — a real wall reprints every failing turn, a one-off quote/render shows it once. So
# a firing scenario drives ≥2 tick_wall calls; a false-positive scenario proves a SINGLE occurrence
# (or a benign/far-apart one) never acts.
suite() {
  # ── (a) FIRES on a RECURRING real wall: two confirmations → ONE switch (rewrite MODEL, export the
  #        fallback, refresh once, durable flag, one alert). Further ticks do NOT re-switch. ──
  new_env a fable
  cp "$INSTANCE_ENV" "$WORK/ienv.a.orig"
  MODEL=fable MODEL_FALLBACK=1 MODEL_FALLBACK_TO=opus MODEL_FALLBACK_OFFSET=0 MODEL_FALLBACK_LATCHED=0 \
  run_scenario '
    tick_wall                                 # tick 1 → 1/2 confirmations, NO action yet
    r1="$(grep -c . "$REFRESH_LOG" 2>/dev/null)"; printf "%s\n" "${r1:-0}" > "$WORK/a.r1"
    tick_wall                                 # tick 2 → 2/2 → switch + refresh (re-arms belt)
    printf "%s\n" "$MODEL" > "$WORK/a.model"
    tick_wall                                 # tick 3 → post-switch cur=opus, 1/2 again → no re-switch
  '
  check "$(cat "$WORK/a.r1")" 0 "(a) a SINGLE wall occurrence does NOT act (recurrence gate; 1/2)"
  check "$R_COUNT" 1 "(a) recurring wall -> exactly ONE refresh (the switch)"
  check "$R_LAST" "model-fallback" "(a) refresh reason is model-fallback"
  check "$A_COUNT" 1 "(a) exactly one operator alert"
  check "$(cat "$WORK/a.model")" "opus" "(a) MODEL exported to the fallback (next spawn inherits opus)"
  check "$([ -f "$WORK/kick.a/model-fallback" ] && echo yes || echo no)" "yes" "(a) durable .kickoff/model-fallback flag written"
  check "$(grep -c '^status=switched$' "$WORK/kick.a/model-fallback" 2>/dev/null | head -1)" 1 "(a) flag records a switch"
  check "$(grep -c '^from=fable$'      "$WORK/kick.a/model-fallback" 2>/dev/null | head -1)" 1 "(a) flag records from=fable"
  check "$(grep -c '^to=opus$'         "$WORK/kick.a/model-fallback" 2>/dev/null | head -1)" 1 "(a) flag records to=opus"
  # instance.env rewrite: the active MODEL line flipped to opus; the commented # MODEL=sonnet
  # and EVERY other line are byte-for-byte preserved (exactly one changed line in the diff).
  check "$(grep -c '^MODEL=opus$'  "$INSTANCE_ENV" 2>/dev/null | head -1)" 1 "(a) instance.env MODEL rewritten to opus"
  check "$(grep -c '^MODEL=fable$' "$INSTANCE_ENV" 2>/dev/null | head -1)" 0 "(a) old MODEL=fable gone"
  check "$(grep -c 'MODEL=sonnet' "$INSTANCE_ENV" 2>/dev/null | head -1)" 1 "(a) commented # MODEL=sonnet left untouched"
  check "$(diff "$WORK/ienv.a.orig" "$INSTANCE_ENV" | grep -c '^[<>]')" 2 "(a) EXACTLY one line changed (all others byte-identical)"
  check "$(grep -c '^MODEL_FALLBACK_TO=opus$' "$INSTANCE_ENV" 2>/dev/null | head -1)" 1 "(a) MODEL_FALLBACK_TO line preserved (not mistaken for MODEL=)"

  # ── (b) does NOT fire on a benign log that TALKS about limits/quota (false-positive guard).
  #        Both markers appear but never with the wall's tight proximity — a loose detector
  #        fires here; the proximity + recurrence guard must NOT. ──
  new_env b fable
  write_benign_log "$SUPERVISOR_LOG"
  MODEL=fable MODEL_FALLBACK=1 MODEL_FALLBACK_TO=opus MODEL_FALLBACK_OFFSET=0 MODEL_FALLBACK_LATCHED=0 \
  run_scenario 'model_fallback_step; model_fallback_step; printf "%s\n" "$MODEL_FALLBACK_LATCHED" > "$WORK/b.latch"'
  check "$R_COUNT" 0 "(b) benign limit/quota chatter -> NO refresh (false-positive guard)"
  check "$A_COUNT" 0 "(b) benign chatter -> NO alert"
  check "$(cat "$WORK/b.latch")" 0 "(b) belt never latched on benign content"

  # ── (b2) finding #4/#3: BOTH markers on ONE physical line but FAR apart (the real pty-redraw
  #        shape — one line can be MB-wide). grep's "same line" is NOT a proximity bound; the tight
  #        .{0,24} window IS. Even across ticks this must NEVER fire. GOES RED on the same-line
  #        two-grep detector (which fires on any same-line co-occurrence, however distant). ──
  new_env b2 fable
  MODEL=fable MODEL_FALLBACK=1 MODEL_FALLBACK_TO=opus MODEL_FALLBACK_OFFSET=0 MODEL_FALLBACK_LATCHED=0 \
  run_scenario '
    write_farline_log "$SUPERVISOR_LOG"; model_fallback_step
    write_farline_log "$SUPERVISOR_LOG"; model_fallback_step
    write_farline_log "$SUPERVISOR_LOG"; model_fallback_step
  '
  check "$R_COUNT" 0 "(b2) two markers far apart on ONE line -> NO refresh (proximity, not same-grep-line)"
  check "$A_COUNT" 0 "(b2) far-apart one-line markers -> NO alert"

  # ── (j) finding #1/#3: a SINGLE occurrence of the verbatim wall (a worker quote, a `cat
  #        supervisor.sh`, a design-doc render) must NOT act — only recurrence across ticks does.
  #        GOES RED on a detector that acts on the first sighting. ──
  new_env j fable
  cp "$INSTANCE_ENV" "$WORK/ienv.j.orig"
  MODEL=fable MODEL_FALLBACK=1 MODEL_FALLBACK_TO=opus MODEL_FALLBACK_OFFSET=0 MODEL_FALLBACK_LATCHED=0 \
  run_scenario 'tick_wall; printf "%s\n" "$MODEL" > "$WORK/j.model"'   # exactly ONE occurrence
  check "$R_COUNT" 0 "(j) single wall occurrence -> NO refresh (one-off quote/render, recurrence gate)"
  check "$A_COUNT" 0 "(j) single occurrence -> NO alert"
  check "$(cat "$WORK/j.model")" "fable" "(j) single occurrence -> MODEL NOT switched"
  check "$(diff "$WORK/ienv.j.orig" "$INSTANCE_ENV" | grep -c '^[<>]')" 0 "(j) single occurrence -> instance.env untouched"

  # ── (c) scans ONLY new content (offset). A wall line already BEHIND the offset is NOT scanned:
  #        no confirmation ever accrues (a stale limit line from a prior era can't spuriously act). ──
  new_env c fable
  write_limit_line "$SUPERVISOR_LOG"                       # an OLD limit line…
  OFF="$(wc -c < "$SUPERVISOR_LOG" | tr -d '[:space:]')"   # …fully behind this offset
  MODEL=fable MODEL_FALLBACK=1 MODEL_FALLBACK_TO=opus MODEL_FALLBACK_OFFSET="$OFF" MODEL_FALLBACK_LATCHED=0 \
  run_scenario '
    model_fallback_step; model_fallback_step             # no NEW content -> nothing scanned
    printf "%s\n" "$MODEL_FALLBACK_HITS" > "$WORK/c.hits"
  '
  check "$R_COUNT" 0 "(c) limit line BEHIND the offset -> NOT re-detected (scans only new content)"
  check "$(cat "$WORK/c.hits")" 0 "(c) no confirmation accrues on already-scanned content"
  # a banner past the offset, then a RECURRING fresh wall -> fires (offset does not block new content)
  new_env c2 fable
  printf 'startup banner line, all healthy so far\n' >> "$SUPERVISOR_LOG"
  OFF="$(wc -c < "$SUPERVISOR_LOG" | tr -d '[:space:]')"
  MODEL=fable MODEL_FALLBACK=1 MODEL_FALLBACK_TO=opus MODEL_FALLBACK_OFFSET="$OFF" MODEL_FALLBACK_LATCHED=0 \
  run_scenario 'tick_wall; tick_wall'                     # fresh walls, past the offset
  check "$R_COUNT" 1 "(c) FRESH recurring wall past the offset -> fires"

  # ── (d) log ROTATION: the file shrinks below the offset (copytruncate) -> offset resets to 0 and
  #        new content is rescanned from the top; a recurring wall there still fires. ──
  new_env d fable
  MODEL=fable MODEL_FALLBACK=1 MODEL_FALLBACK_TO=opus MODEL_FALLBACK_OFFSET=999999 MODEL_FALLBACK_LATCHED=0 \
  run_scenario 'tick_wall; tick_wall'                     # small file << 999999 offset -> reset to 0
  check "$R_COUNT" 1 "(d) rotation (size < offset) -> offset reset to 0, recurring wall re-scanned, fires"

  # ── (e) ALREADY-ON-FALLBACK edge: the wall recurs while MODEL already == the fallback. The belt
  #        CANNOT help by switching — it alerts 'also limited', latches, does NOT refresh, does NOT
  #        rewrite instance.env, does NOT loop. (Opus's own weekly limit case.) ──
  new_env e opus
  cp "$INSTANCE_ENV" "$WORK/ienv.e.orig"
  MODEL=opus MODEL_FALLBACK=1 MODEL_FALLBACK_TO=opus MODEL_FALLBACK_OFFSET=0 MODEL_FALLBACK_LATCHED=0 \
  run_scenario '
    tick_owall; tick_owall                                # 2 confirmations → already-on-fallback alert
    printf "%s\n" "$MODEL" > "$WORK/e.model"
    tick_owall                                            # latched (no refresh to re-arm) → no 2nd alert
  '
  check "$R_COUNT" 0 "(e) already-on-fallback -> NO refresh (switching cannot help)"
  check "$A_COUNT" 1 "(e) already-on-fallback -> exactly one 'also limited' alert (no loop)"
  check "$(cat "$WORK/e.model")" "opus" "(e) MODEL untouched (never switched to nothing)"
  check "$(diff "$WORK/ienv.e.orig" "$INSTANCE_ENV" | grep -c '^[<>]')" 0 "(e) instance.env NOT rewritten"
  check "$(grep -c 'also-limited' "$WORK/kick.e/model-fallback" 2>/dev/null | head -1)" 1 "(e) flag records also-limited"
  case "$A_TEXT" in *ALREADY*|*already*) ok "(e) alert names the already-on-fallback condition" ;; *) bad "(e) alert should name already-on-fallback (got: $A_TEXT)" ;; esac

  # ── (k) finding #2: the belt RE-ARMS per session, so a LATER wall on the fallback model is
  #        caught (not swallowed by a permanent latch). fable→opus switch, THEN opus hits its own
  #        wall → a SECOND (already-on-fallback) alert fires. GOES RED on a never-resetting latch. ──
  new_env k fable
  MODEL=fable MODEL_FALLBACK=1 MODEL_FALLBACK_TO=opus MODEL_FALLBACK_OFFSET=0 MODEL_FALLBACK_LATCHED=0 \
  run_scenario '
    tick_wall; tick_wall                                  # → switch fable→opus (MODEL now opus), refresh re-arms
    printf "%s\n" "$MODEL" > "$WORK/k.model1"
    tick_owall; tick_owall                                # opus now hits ITS wall → already-on-fallback alert
  '
  check "$(cat "$WORK/k.model1")" "opus" "(k) first switched fable→opus"
  check "$R_COUNT" 1 "(k) one refresh total (the switch); the later already-on-fallback does not cycle"
  check "$A_COUNT" 2 "(k) TWO alerts: the switch + a later 'also limited' (belt re-armed per session)"
  case "$A_TEXT" in *ALREADY*|*already*) ok "(k) the second alert names already-on-fallback" ;; *) bad "(k) second alert should name already-on-fallback (got: $A_TEXT)" ;; esac

  # ── (f) DRY_RUN=1 -> detect-only after confirmation: logs, but ZERO writes/cycles (no refresh, no
  #        rewrite, no flag, no alert, no export). ──
  new_env f fable
  cp "$INSTANCE_ENV" "$WORK/ienv.f.orig"
  DRY_RUN=1 MODEL=fable MODEL_FALLBACK=1 MODEL_FALLBACK_TO=opus MODEL_FALLBACK_OFFSET=0 MODEL_FALLBACK_LATCHED=0 \
  run_scenario '
    : > "$WORK/log.f"; log() { printf "%s\n" "$*" >> "$WORK/log.f"; }
    tick_wall; tick_wall
    printf "%s\n" "$MODEL" > "$WORK/f.model"
  '
  check "$R_COUNT" 0 "(f) DRY_RUN -> NO refresh"
  check "$A_COUNT" 0 "(f) DRY_RUN -> NO alert"
  check "$(cat "$WORK/f.model")" "fable" "(f) DRY_RUN -> MODEL not exported (still fable)"
  check "$(diff "$WORK/ienv.f.orig" "$INSTANCE_ENV" | grep -c '^[<>]')" 0 "(f) DRY_RUN -> instance.env untouched"
  check "$([ -f "$WORK/kick.f/model-fallback" ] && echo yes || echo no)" "no" "(f) DRY_RUN -> no durable flag"
  local fd; fd="$(grep -c 'DRY_RUN' "$WORK/log.f" 2>/dev/null)"
  check "$([ "${fd:-0}" -ge 1 ] && echo yes || echo no)" "yes" "(f) DRY_RUN -> detect-only log line emitted"

  # ── (g) INERT: fallback == current MODEL + no limit line (the kickoff-dev dogfood origin,
  #        MODEL=opus, fallback=opus) -> pure no-op, whatever the ticks. ──
  new_env g opus
  write_benign_log "$SUPERVISOR_LOG"
  MODEL=opus MODEL_FALLBACK=1 MODEL_FALLBACK_TO=opus MODEL_FALLBACK_OFFSET=0 MODEL_FALLBACK_LATCHED=0 \
  run_scenario 'model_fallback_step; model_fallback_step; printf "%s\n" "$MODEL_FALLBACK_LATCHED" > "$WORK/g.latch"'
  check "$R_COUNT" 0 "(g) MODEL==fallback + no limit -> NO refresh (dogfood-inert)"
  check "$A_COUNT" 0 "(g) MODEL==fallback + no limit -> NO alert"
  check "$(cat "$WORK/g.latch")" 0 "(g) belt never latched on a healthy dogfood worker"

  # ── (h) DISARMED (MODEL_FALLBACK=0) -> fully inert even with a recurring real wall present. ──
  new_env h fable
  cp "$INSTANCE_ENV" "$WORK/ienv.h.orig"
  MODEL=fable MODEL_FALLBACK=0 MODEL_FALLBACK_TO=opus MODEL_FALLBACK_OFFSET=0 MODEL_FALLBACK_LATCHED=0 \
  run_scenario 'tick_wall; tick_wall'
  check "$R_COUNT" 0 "(h) disarmed (MODEL_FALLBACK=0) -> NO refresh even on a real wall"
  check "$A_COUNT" 0 "(h) disarmed -> NO alert"
  check "$(diff "$WORK/ienv.h.orig" "$INSTANCE_ENV" | grep -c '^[<>]')" 0 "(h) disarmed -> instance.env untouched"

  # ── (i) COST-DIRECTION gate: a fallback PRICIER than the current model must NOT be auto-switched
  #        (that would increase spend — a human decision). Refuses, alerts, latches, never refreshes
  #        or rewrites. (sonnet wall, configured fallback opus = pricier.) ──
  new_env i sonnet
  cp "$INSTANCE_ENV" "$WORK/ienv.i.orig"
  MODEL=sonnet MODEL_FALLBACK=1 MODEL_FALLBACK_TO=opus MODEL_FALLBACK_OFFSET=0 MODEL_FALLBACK_LATCHED=0 \
  run_scenario '
    write_sonnet_limit_line "$SUPERVISOR_LOG"; model_fallback_step
    write_sonnet_limit_line "$SUPERVISOR_LOG"; model_fallback_step
    printf "%s\n" "$MODEL" > "$WORK/i.model"
  '
  check "$R_COUNT" 0 "(i) pricier fallback -> NO refresh (spend gate)"
  check "$A_COUNT" 1 "(i) pricier fallback -> one alert (manual decision)"
  check "$(cat "$WORK/i.model")" "sonnet" "(i) MODEL NOT switched to a pricier model"
  check "$(diff "$WORK/ienv.i.orig" "$INSTANCE_ENV" | grep -c '^[<>]')" 0 "(i) pricier fallback -> instance.env untouched"
  check "$(grep -c 'refused-pricier' "$WORK/kick.i/model-fallback" 2>/dev/null | head -1)" 1 "(i) flag records refused-pricier"

  # ── (l) finding #6: a duplicated active MODEL= line — ALL are rewritten (not just the first), so
  #        no stale MODEL=fable survives to win last-assignment-wins on a full restart. GOES RED on
  #        the first-only (`!done`) rewrite. ──
  new_env l fable
  printf 'MODEL=fable\n' >> "$INSTANCE_ENV"                # a 2nd active MODEL line (pathological)
  MODEL=fable MODEL_FALLBACK=1 MODEL_FALLBACK_TO=opus MODEL_FALLBACK_OFFSET=0 MODEL_FALLBACK_LATCHED=0 \
  run_scenario 'tick_wall; tick_wall'
  check "$(grep -c '^MODEL=fable$' "$INSTANCE_ENV" 2>/dev/null | head -1)" 0 "(l) NO stale MODEL=fable survives (all active MODEL lines rewritten)"
  check "$(grep -c '^MODEL=opus$'  "$INSTANCE_ENV" 2>/dev/null | head -1)" 2 "(l) both active MODEL lines are now opus"

  # ── (m) finding #7: an UNKNOWN / typo'd fallback (unrankable) must be REFUSED, not fail-open
  #        switched to a garbage --model. Alerts, latches, never rewrites/switches. GOES RED on the
  #        old gate that only blocked a KNOWN-pricier target. ──
  new_env m fable
  cp "$INSTANCE_ENV" "$WORK/ienv.m.orig"
  MODEL=fable MODEL_FALLBACK=1 MODEL_FALLBACK_TO=opsu MODEL_FALLBACK_OFFSET=0 MODEL_FALLBACK_LATCHED=0 \
  run_scenario '
    write_limit_line "$SUPERVISOR_LOG"; model_fallback_step
    write_limit_line "$SUPERVISOR_LOG"; model_fallback_step
    printf "%s\n" "$MODEL" > "$WORK/m.model"
  '
  check "$R_COUNT" 0 "(m) unknown fallback -> NO refresh (refuse, not fail-open switch)"
  check "$A_COUNT" 1 "(m) unknown fallback -> one alert (manual fix)"
  check "$(cat "$WORK/m.model")" "fable" "(m) unknown fallback -> MODEL NOT switched to a garbage model"
  check "$(diff "$WORK/ienv.m.orig" "$INSTANCE_ENV" | grep -c '^[<>]')" 0 "(m) unknown fallback -> instance.env untouched"
  check "$(grep -c 'refused-unknown' "$WORK/kick.m/model-fallback" 2>/dev/null | head -1)" 1 "(m) flag records refused-unknown"
}

# ── run NEW (expect all green) ─────────────────────────────────────────────────────────
echo "== assertions against NEW scripts/supervisor.sh =="
UNIT_FILE="$WORK/unit.new.sh"; extract_unit "$SUPERVISOR_NEW" > "$UNIT_FILE"
if ! bash -n "$UNIT_FILE" 2>/dev/null; then bad "extracted unit fails bash -n (new)"; fi
suite
NEW_PASS=$PASS; NEW_FAIL=$FAIL

# ── RED-ON-OLD: same assertions against HEAD's supervisor.sh must FAIL ──────────────────
echo
echo "== RED-on-old: same assertions against HEAD:scripts/supervisor.sh =="
OLD_SRC="$WORK/supervisor.old.sh"
if git -C "$SCRIPT_DIR" show HEAD:scripts/supervisor.sh > "$OLD_SRC" 2>/dev/null; then
  UNIT_FILE="$WORK/unit.old.sh"; extract_unit "$OLD_SRC" > "$UNIT_FILE"
  if cmp -s "$WORK/unit.new.sh" "$UNIT_FILE"; then
    RED_ON_OLD=skip; printf '  skip RED-on-old n/a — unit is byte-identical to HEAD (post-commit state; nothing new to prove)\n'
  else
    PASS=0; FAIL=0
    suite >/dev/null 2>&1
    OLD_FAIL=$FAIL
    if [ "$OLD_FAIL" -gt 0 ]; then
      RED_ON_OLD=1; printf '  ok   RED-on-old proven — %s assertion(s) FAIL against HEAD (behavior is genuinely new)\n' "$OLD_FAIL"
    else
      RED_ON_OLD=0; printf '  FAIL RED-on-old NOT proven — the suite passed on OLD code (it proves nothing)\n'
    fi
  fi
else
  RED_ON_OLD=0; printf '  FAIL could not read HEAD:scripts/supervisor.sh to prove RED-on-old\n'
fi

echo
echo "== summary =="
printf 'NEW: pass=%s fail=%s   RED-on-old proven=%s\n' "$NEW_PASS" "$NEW_FAIL" "${RED_ON_OLD:-0}"
case "${RED_ON_OLD:-0}" in 1|skip)
  if [ "$NEW_FAIL" -eq 0 ]; then echo "SELFTEST PASS"; exit 0; fi ;;
esac
echo "SELFTEST FAIL"; exit 1
