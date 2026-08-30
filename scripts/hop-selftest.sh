#!/usr/bin/env bash
# hop-selftest.sh — hermetic proof of the supervisor's ENGINE HOP (v0.7 G1 slice 5):
# `kickoff pull` advances the pin (instance.env KICKOFF_CORE_DIR + core.lock) while the
# RUNNING supervisor keeps executing the code it loaded at start; the hop unit closes the
# gap by re-exec'ing the pinned engine's supervisor.sh AT THE NEXT SESSION BOUNDARY —
# verified first (FULL-scope preflight FROM the new engine + bash -n), fail-loud when red
# (durable .kickoff/hop-blocked + ONE tokenless alert, re-alert only on a CHANGED target),
# execfail-armed (a failed exec logs + continues on the old engine), and ORIGIN-INERT
# (no core.lock / a pin resolving to REPO_DIR itself never hops — the dogfood origin).
#
# HOW IT STAYS HERMETIC (mirrors supervisor-liveness-selftest.sh):
#   - It EXTRACTS the hop unit from scripts/supervisor.sh (the lines between the two
#     `>>> / <<<` marker lines whose token starts KICKOFF-HOP) and drives it in isolated
#     subshells with stubs: `exec` is a bash FUNCTION stub (captured, never real), log /
#     tg_send_tokenless are observers, target engines are scratch fixtures whose
#     preflight.sh exits 0 (green) or 1 (red).
#   - TWO lanes (h10/h11, adversarial-review finds) use the REAL working-tree preflight.sh
#     in a tagged scratch git engine: h10 proves a FOSSIL exported KICKOFF_CORE_DIR (the
#     parked-worktree production shape) can no longer block the hop, and that #4 self-
#     recognizes the caller's own live lock; h11 proves a pin-green/full-RED instance is
#     BLOCKED at the boundary (flag + one alert) instead of hopping into a dead startup.
#   - acquire_lock is extracted BY CONTENT from supervisor.sh and driven with fixture
#     lock files (own pid / rival live pid / stale pid) — no real supervisor involved.
#   - ONE integration lane spawns a REAL fixture supervisor in a scratch REPO_DIR
#     (START_CMD is `sleep`, NEVER a real claude; env -i scrubbed; every kill targets the
#     exact test-spawned pid) and proves the live hop: same PID across the exec, cmdline
#     now naming the NEW engine, MODEL/EFFORT dropped + PERMISSION_MODE/REPO_DIR carried
#     in /proc/<pid>/environ. Timeout-guarded polls everywhere — never waits for exit.
#   - The LIVE repo is touched READ-ONLY exactly once: the origin-inert lane asserts the
#     real /home/…/claude-kickoff shape (no core.lock) resolves to "no hop". Nothing is
#     ever written outside mktemp dirs.
#
# RED-ON-OLD: the same assertions run against HEAD's supervisor.sh; pre-slice HEAD has no
# hop unit at all, so the suite must FAIL there (that failure IS the red-first proof).
# Byte-identical unit+acquire_lock vs HEAD (the normal post-commit state) → auto-SKIP.
#
# Usage:  bash scripts/hop-selftest.sh
# Exit non-zero on any failed assertion (or if RED-on-old is not proven).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUPERVISOR_NEW="$SCRIPT_DIR/supervisor.sh"
LIVE_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hop-selftest.XXXXXX")"

# ── (h6d) write-canary baseline: the suite must never MUTATE the live .kickoff ─
# h6c's old comment CLAIMED "we only READ the live .kickoff — never write, never
# signal" and nothing anywhere tested it. This snapshots the live .kickoff before any
# scenario runs; the paired check at the end proves the claim instead of asserting it.
# Compare the SET OF PATHS, never content or mtime: a live supervisor rewrites its own
# state files (auth-heal.state every probe), so a content/mtime diff would false-fail
# on the live org's normal churn rather than on anything this suite did.
LIVE_KICKOFF_PRE="$WORK/live-kickoff.pre"
snapshot_live_kickoff() {
  if [ -d "$LIVE_REPO/.kickoff" ]; then
    ( cd "$LIVE_REPO/.kickoff" && find . -print 2>/dev/null | LC_ALL=C sort ) > "$1"
  else
    printf '(no .kickoff dir)\n' > "$1"
  fi
}
snapshot_live_kickoff "$LIVE_KICKOFF_PRE"

# exact-pid cleanup ONLY: every pid in $WORK/pids was spawned by THIS test.
cleanup() {
  if [ -f "$WORK/pids" ]; then
    while IFS= read -r p; do
      case "$p" in ''|*[!0-9]*) continue ;; esac
      kill -TERM "$p" 2>/dev/null || true
    done < "$WORK/pids"
    sleep 1
    while IFS= read -r p; do
      case "$p" in ''|*[!0-9]*) continue ;; esac
      kill -KILL "$p" 2>/dev/null || true
      # a fixture supervisor setsids its sleep-session into its own group; reap that
      # exact group too (the pgid was recorded by the same fixture, never a pattern)
      kill -KILL -- "-$p" 2>/dev/null || true
    done < "$WORK/pids"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# ── ambient scrub: fixtures must never inherit the live org's env ─────────────
# (includes preflight's FULL instance-env whitelist: the h10/h11 lanes run the REAL
# preflight, whose preset-wins rule would let an ambient MEMORY_INDEX/MC_STATE_FILE from
# a live worker session mask the fixture's instance.env and false-fail the lane)
unset REPO_DIR KICKOFF_CORE_DIR KICKOFF_CORE_REMOTE TELEGRAM_STATE_DIR CHANNEL_SPEC \
      _PTY_WRAPPED MODEL EFFORT PERMISSION_MODE KICKOFF_ENV_KEEP INSTANCE_ENV LOCKFILE \
      REFRESH_FLAG PIDFILE START_CMD DRY_RUN PREFLIGHT_SKIP MAX_SESSION_SECONDS \
      POLL_SECONDS KICKOFF_SUPERVISOR_LOG SETTINGS_FILE \
      MC_STATE_FILE MC_TRACKER_FILE MEMORY_DB MEMORY_HOOK_LOG MEMORY_DIR MEMORY_INDEX \
      REGROUND_PROMPT MAX_CONCURRENT_AGENTS DEPLOY_BRANCH CADENCE \
      ORIGIN_STATE_DIR OPERATOR_STATE_DIR KICKOFF_HOP_EXEC \
      GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE 2>/dev/null || true
# GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE: `git -C <fixture>` is NOT containment — an
# ambient GIT_DIR overrides it, so a fixture's `git init`/`commit` would land in the
# CALLER's repo. Not set today, which is exactly why it has to be unset here rather
# than relied on: a suite this fixture-heavy is where that would bite silently.

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$1" = "$2" ]; then ok "$3 (=$1)"; else bad "$3 (want=$2 got=$1)"; fi; }

# ── extraction (by content, from a given supervisor.sh) ──────────────────────
extract_unit() {
  # the lines strictly BETWEEN the two hop-unit marker lines (the ONLY lines bearing
  # that token, so the toggle is unambiguous — same idiom as the bridge unit)
  awk '/KICKOFF-HOP-UNIT/{f=!f; next} f' "$1"
}
extract_acquire_lock() {
  awk '/^acquire_lock\(\) \{/{f=1} f{print; if ($0=="}") exit}' "$1"
}

# ── the harness: stubs + the extracted unit, sourced fresh per scenario ───────
HARNESS="$WORK/harness.sh"
cat > "$HARNESS" <<'EOF'
# observed stand-ins, never real
EXEC_LOG="${EXEC_LOG:?}"; EXEC_ENV_LOG="${EXEC_ENV_LOG:?}"; ALARM_LOG="${ALARM_LOG:?}"; HOPLOG="${HOPLOG:?}"
log() { printf '%s\n' "$*" >> "$HOPLOG"; }
# a bash FUNCTION shadows the exec builtin: the hop's `exec bash <new sup>` is CAPTURED
# (argv + the exported env at that instant), then "fails" per EXEC_STUB_RC so the
# post-execfail path is reachable too.
exec() {
  printf '%s\n' "$*" >> "$EXEC_LOG"
  command env > "$EXEC_ENV_LOG" 2>/dev/null
  return "${EXEC_STUB_RC:-1}"
}
tg_send_tokenless() { :; }                     # replaced by the observer after sourcing

REPO_DIR="${REPO_DIR:?}"; KICKOFF_DIR="${KICKOFF_DIR:?}"
SCRIPT_DIR="${SCRIPT_DIR:?}"
DRY_RUN="${DRY_RUN:-0}"

. "$UNIT_FILE"                                  # engine_hop_resolve / _step / _boundary + state

tg_send_tokenless() { printf '%s\n' "$1" >> "$ALARM_LOG"; }
EOF

run_scenario() {
  local body="$1"
  EXEC_LOG="$WORK/exec.$$.$RANDOM"; EXEC_ENV_LOG="$WORK/execenv.$$.$RANDOM"
  ALARM_LOG="$WORK/alarm.$$.$RANDOM"; HOPLOG="$WORK/hoplog.$$.$RANDOM"
  : > "$EXEC_LOG"; : > "$ALARM_LOG"; : > "$HOPLOG"
  (
    export WORK EXEC_LOG EXEC_ENV_LOG ALARM_LOG HOPLOG UNIT_FILE
    export REPO_DIR KICKOFF_DIR SCRIPT_DIR DRY_RUN
    export RUNNING_ENGINE_DIR RUNNING_ENGINE_COMMIT
    set +e
    . "$HARNESS"
    eval "$body"
  )
  X_COUNT="$(grep -c . "$EXEC_LOG" 2>/dev/null)"; X_COUNT="${X_COUNT:-0}"
  A_COUNT="$(grep -c . "$ALARM_LOG" 2>/dev/null)"; A_COUNT="${A_COUNT:-0}"
  X_LAST="$(tail -n1 "$EXEC_LOG" 2>/dev/null || echo '')"
}

# ── per-scenario fixtures ─────────────────────────────────────────────────────
# build_engine <dir> green|red : a target-engine skeleton (valid supervisor.sh; a
# preflight.sh that exits 0 or 1). NOT a git repo — the pinned commit is read from
# core.lock text, and the running commit is pre-set, so no git is needed at unit level.
build_engine() {
  mkdir -p "$1/scripts"
  printf '#!/usr/bin/env bash\ntrue\n' > "$1/scripts/supervisor.sh"
  if [ "$2" = green ]; then
    printf '#!/usr/bin/env bash\necho "stub preflight ok (args: $*)"\nexit 0\n' > "$1/scripts/preflight.sh"
  else
    printf '#!/usr/bin/env bash\necho "PF-RED-REASON: fixture preflight refuses" >&2\nexit 1\n' > "$1/scripts/preflight.sh"
  fi
}
# build_repo <dir> <pinned_core_dir> <pinned_commit> : an adopter REPO_DIR with
# instance.env + a format-2 core.lock. Empty pinned_core_dir ⇒ no KICKOFF_CORE_DIR line.
build_repo() {
  mkdir -p "$1/.kickoff"
  if [ -n "$2" ]; then
    printf 'export KICKOFF_CORE_DIR="%s"\n' "$2" > "$1/.kickoff/instance.env"
  else
    printf '# no core dir configured\n' > "$1/.kickoff/instance.env"
  fi
  if [ -n "$3" ]; then
    printf 'format 2\ntag core-vHOP\ncommit %s\n' "$3" > "$1/.kickoff/core.lock"
  fi
}

# build_real_engine <dir> : a target engine carrying the REAL working-tree preflight.sh
# (the exact gate a production hop runs) as a clean TAGGED git checkout, so the format-2
# core.lock pin (#6) genuinely verifies. Echoes the HEAD commit; tag is fixed: core-vREAL.
build_real_engine() {
  mkdir -p "$1/scripts"
  cp "$LIVE_REPO/scripts/preflight.sh" "$1/scripts/preflight.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "$1/scripts/supervisor.sh"
  git -C "$1" init -q
  git -C "$1" -c user.email=t@t.t -c user.name=t add -A
  git -C "$1" -c user.email=t@t.t -c user.name=t commit -qm engine >/dev/null
  git -C "$1" tag core-vREAL
  git -C "$1" rev-parse HEAD
}
# build_real_repo <dir> <engine_dir> <commit> : an adopter dressed to pass the REAL
# preflight FULL-scope — instance.env with a dedicated channel + in-repo data paths,
# a memory index, a zero-entry adopt-manifest, and a format-2 core.lock at <commit>.
build_real_repo() {
  mkdir -p "$1/.kickoff/memory" "$1/.kickoff/tg"
  {
    printf 'export KICKOFF_CORE_DIR="%s"\n' "$2"
    printf 'export TELEGRAM_STATE_DIR="%s/.kickoff/tg"\n' "$1"
    printf 'export MC_STATE_FILE="%s/.kickoff/state/mission-state.json"\n' "$1"
    printf 'export MEMORY_DB="%s/.kickoff/memory/index.db"\n' "$1"
    printf 'export MEMORY_HOOK_LOG="%s/.kickoff/memory/hook.log"\n' "$1"
  } > "$1/.kickoff/instance.env"
  printf 'format 2\ntag core-vREAL\ncommit %s\n' "$3" > "$1/.kickoff/core.lock"
  printf '{"entries": [], "machine_entries": []}\n' > "$1/.kickoff/adopt-manifest.json"
  printf '# memory index stub\n' > "$1/.kickoff/memory/MEMORY.md"
}

C_OLD="0000000000000000000000000000000000000000"
C_NEW="1111111111111111111111111111111111111111"
C_NEW2="2222222222222222222222222222222222222222"

# ── the assertion suite (run against NEW = all green; OLD = must produce reds) ──
suite() {
  local n="$1"    # fixture namespace (new/old) so state never bleeds across runs

  local RUNENG="$WORK/$n.runeng"; mkdir -p "$RUNENG/scripts"
  local GREEN="$WORK/$n.green";   build_engine "$GREEN" green
  local RED="$WORK/$n.red";       build_engine "$RED"   red
  local RED2="$WORK/$n.red2";     build_engine "$RED2"  red

  SCRIPT_DIR="$RUNENG/scripts"
  RUNNING_ENGINE_DIR="$RUNENG"
  RUNNING_ENGINE_COMMIT="$C_OLD"
  DRY_RUN=0

  # (h1) pinned-engine mismatch + session at boundary → exec target is the NEW engine's supervisor.sh
  local R1="$WORK/$n.repo1"; build_repo "$R1" "$GREEN" "$C_NEW"
  REPO_DIR="$R1"; KICKOFF_DIR="$R1/.kickoff"
  EXEC_STUB_RC=0 run_scenario '
    export EXEC_STUB_RC=0
    export MODEL=fable EFFORT=max PERMISSION_MODE=auto
    engine_hop_boundary'
  check "$X_COUNT" 1 "(h1) mismatch at boundary -> exactly one exec"
  check "$X_LAST" "bash $GREEN/scripts/supervisor.sh" "(h1) exec target is the NEW engine's supervisor.sh"

  # (h7) env at the exec: MODEL/EFFORT (and the fossil KICKOFF_CORE_DIR) UNSET;
  #      PERMISSION_MODE + REPO_DIR carried (captured from the stub's env dump)
  check "$(grep -c '^MODEL=' "$EXEC_ENV_LOG")" 0 "(h7) MODEL unset at exec"
  check "$(grep -c '^EFFORT=' "$EXEC_ENV_LOG")" 0 "(h7) EFFORT unset at exec"
  check "$(grep -c '^KICKOFF_CORE_DIR=' "$EXEC_ENV_LOG")" 0 "(h7) fossil KICKOFF_CORE_DIR unset at exec (new engine re-resolves its own root)"
  check "$(grep -c '^PERMISSION_MODE=auto$' "$EXEC_ENV_LOG")" 1 "(h7) PERMISSION_MODE=auto carried through the exec"
  check "$(grep -c "^REPO_DIR=$R1\$" "$EXEC_ENV_LOG")" 1 "(h7) REPO_DIR carried through the exec"
  check "$(grep -c '^KICKOFF_HOP_EXEC=1$' "$EXEC_ENV_LOG")" 1 "(h7) KICKOFF_HOP_EXEC=1 landing marker exported at the exec (a post-exec startup red alerts, never dies mute)"

  # (h2) mismatch MID-SESSION (poll ticks) → NO hop until the boundary
  local R2="$WORK/$n.repo2"; build_repo "$R2" "$GREEN" "$C_NEW"
  REPO_DIR="$R2"; KICKOFF_DIR="$R2/.kickoff"
  run_scenario '
    engine_hop_step; engine_hop_step; engine_hop_step
    printf "%s\n" "$HOP_TARGET_DIR" > "$WORK/h2.target"
    ticks_execs="$(grep -c . "$EXEC_LOG")"
    printf "%s\n" "$ticks_execs" > "$WORK/h2.mid"
    engine_hop_boundary'
  check "$(cat "$WORK/h2.mid" 2>/dev/null)" 0 "(h2) three mid-session ticks -> NO exec (deferred)"
  check "$(cat "$WORK/h2.target" 2>/dev/null)" "$GREEN" "(h2) tick DID detect the pending target (deferred, not blind)"
  check "$X_COUNT" 1 "(h2) the boundary then hops (one exec)"

  # (h3) new-engine preflight RED → no exec + durable hop-blocked (target+reason) +
  #      exactly ONE alert; unchanged target on later boundaries → no re-alert;
  #      CHANGED target → one new alert.
  local R3="$WORK/$n.repo3"; build_repo "$R3" "$RED" "$C_NEW"
  REPO_DIR="$R3"; KICKOFF_DIR="$R3/.kickoff"
  run_scenario '
    engine_hop_boundary          # blocked: flag + ONE alert
    engine_hop_boundary          # same target: NO re-alert
    engine_hop_boundary          # same target: NO re-alert
    a_same="$(grep -c . "$ALARM_LOG")"; printf "%s\n" "$a_same" > "$WORK/h3.same"
    printf "export KICKOFF_CORE_DIR=\"%s\"\n" "'"$RED2"'" > "$REPO_DIR/.kickoff/instance.env"
    printf "format 2\ntag core-vHOP2\ncommit %s\n" "'"$C_NEW2"'" > "$REPO_DIR/.kickoff/core.lock"
    engine_hop_boundary          # CHANGED target: one NEW alert
    engine_hop_boundary          # unchanged again: no more'
  check "$X_COUNT" 0 "(h3) preflight red -> NO exec ever"
  check "$([ -f "$R3/.kickoff/hop-blocked" ] && echo yes || echo no)" "yes" "(h3) durable .kickoff/hop-blocked written"
  check "$(grep -c "target=$RED2" "$R3/.kickoff/hop-blocked" 2>/dev/null)" 1 "(h3) hop-blocked names the (latest) target engine"
  check "$(grep -c '^reason=' "$R3/.kickoff/hop-blocked" 2>/dev/null)" 1 "(h3) hop-blocked carries a reason"
  check "$(cat "$WORK/h3.same" 2>/dev/null)" 1 "(h3) exactly ONE alert while the target is unchanged"
  check "$A_COUNT" 2 "(h3) a CHANGED target re-alerts exactly once more"

  # (h4) execfail → logged + still running on the old engine (no death)
  local R4="$WORK/$n.repo4"; build_repo "$R4" "$GREEN" "$C_NEW"
  REPO_DIR="$R4"; KICKOFF_DIR="$R4/.kickoff"
  run_scenario '
    export EXEC_STUB_RC=1
    engine_hop_boundary
    rc=$?
    printf "alive rc=%s\n" "$rc" >> "$HOPLOG"'
  check "$X_COUNT" 1 "(h4) the exec was attempted"
  check "$(grep -c 'exec FAILED' "$HOPLOG")" 1 "(h4) execfail path LOGGED"
  check "$(grep -c 'alive rc=0' "$HOPLOG")" 1 "(h4) boundary returned 0 — old engine keeps running"

  # (h6) origin-inert: (a) NO core.lock → inert; (b) pinned dir == REPO_DIR → inert
  local R6a="$WORK/$n.repo6a"; build_repo "$R6a" "$GREEN" ""     # no core.lock
  REPO_DIR="$R6a"; KICKOFF_DIR="$R6a/.kickoff"
  run_scenario '
    engine_hop_step; engine_hop_boundary
    printf "%s\n" "${HOP_TARGET_DIR:-EMPTY}" > "$WORK/h6a.target"'
  check "$X_COUNT" 0 "(h6a) no core.lock -> inert (no exec)"
  local R6b="$WORK/$n.repo6b"; build_repo "$R6b" "PLACEHOLDER" "$C_NEW"
  printf 'export KICKOFF_CORE_DIR="%s"\n' "$R6b" > "$R6b/.kickoff/instance.env"   # pin == the repo ITSELF
  REPO_DIR="$R6b"; KICKOFF_DIR="$R6b/.kickoff"
  run_scenario '
    engine_hop_resolve
    printf "%s\n" "${HOP_TARGET_DIR:-EMPTY}" > "$WORK/h6b.target"
    engine_hop_boundary'
  check "$(cat "$WORK/h6b.target" 2>/dev/null | sed 's/^$/EMPTY/')" "EMPTY" "(h6b) self-referential pin (dogfood origin) -> no target"
  check "$X_COUNT" 0 "(h6b) a stray lock pinning the repo itself never hops"

  # (h8) instance.env KICKOFF_CORE_DIR is re-read FRESH each tick — a mid-run rewrite
  #      (the parked-worktree pull) is picked up, and a stale exported env value can't mask it
  local R8="$WORK/$n.repo8"; build_repo "$R8" "$GREEN" "$C_NEW"
  REPO_DIR="$R8"; KICKOFF_DIR="$R8/.kickoff"
  run_scenario '
    export KICKOFF_CORE_DIR="'"$RED"'"       # a stale ambient value — the FILE must win
    engine_hop_resolve
    printf "%s\n" "${HOP_TARGET_DIR:-EMPTY}" > "$WORK/h8.first"
    printf "export KICKOFF_CORE_DIR=\"%s\"\n" "'"$RED2"'" > "$REPO_DIR/.kickoff/instance.env"
    engine_hop_resolve
    printf "%s\n" "${HOP_TARGET_DIR:-EMPTY}" > "$WORK/h8.second"'
  check "$(cat "$WORK/h8.first" 2>/dev/null)"  "$GREEN" "(h8) tick 1 reads the FILE's core dir (ambient env can't mask it)"
  check "$(cat "$WORK/h8.second" 2>/dev/null)" "$RED2"  "(h8) a mid-run instance.env rewrite is picked up on the next tick"

  # (h9, DRY_RUN discipline) detect-only: no exec, no flag, a DRY_RUN log line
  local R9="$WORK/$n.repo9"; build_repo "$R9" "$GREEN" "$C_NEW"
  REPO_DIR="$R9"; KICKOFF_DIR="$R9/.kickoff"
  DRY_RUN=1 run_scenario 'engine_hop_boundary'
  check "$X_COUNT" 0 "(h9) DRY_RUN -> no exec"
  check "$([ -f "$R9/.kickoff/hop-blocked" ] && echo yes || echo no)" "no" "(h9) DRY_RUN -> no flag"
  DRY_RUN=0

  # (h10, review find: the fossil KICKOFF_CORE_DIR) — the boundary's child preflight must
  # NOT inherit this process's stale engine dir. Production shape: every kickoff-up launch
  # kernel-holds KICKOFF_CORE_DIR=<the engine it started>, so after a parked-worktree pull
  # that env value is a FOSSIL naming the OLD engine; preflight's preset-wins rule would
  # make #6 hard-fail ("running is not the pinned") on EVERY hop, forever. Target engine
  # carries the REAL working-tree preflight.sh (stubs can't catch this class); the adopter
  # is dressed FULL-green; the fossil is exported; a LIVE own lock (this subshell's
  # $BASHPID == the plain-command child's $PPID) proves #4 self-recognition en passant.
  local RENG="$WORK/$n.realeng" RENG_C
  RENG_C="$(build_real_engine "$RENG")"
  local R10="$WORK/$n.repo10"; build_real_repo "$R10" "$RENG" "$RENG_C"
  REPO_DIR="$R10"; KICKOFF_DIR="$R10/.kickoff"
  run_scenario '
    export EXEC_STUB_RC=0
    export KICKOFF_CORE_DIR="'"$RUNENG"'"                 # the fossil: the OLD engine dir
    echo "$BASHPID" > "$KICKOFF_DIR/supervisor.lock"      # a LIVE own lock — #4 must not refuse it
    engine_hop_boundary'
  check "$X_COUNT" 1 "(h10) REAL preflight + fossil KICKOFF_CORE_DIR -> boundary verifies GREEN (one exec)"
  check "$([ -f "$R10/.kickoff/hop-blocked" ] && echo yes || echo no)" "no" "(h10) no hop-blocked flag (the fossil can no longer block the hop)"
  check "$(grep -c 'verified GREEN' "$HOPLOG")" 1 "(h10) hop logged the green verification (own live lock self-recognized by #4)"

  # (h11, review find: pin-green/full-RED) — the boundary runs the FULL gate (exactly what
  # the new engine's own startup enforces fail-closed), so a session-readiness red (here: a
  # missing memory index — invisible to pin scope) BLOCKS the hop: stay on the OLD engine,
  # durable flag + ONE alert — never an exec into an immediate silent startup death.
  local R11="$WORK/$n.repo11"; build_real_repo "$R11" "$RENG" "$RENG_C"
  rm -f "$R11/.kickoff/memory/MEMORY.md"                  # full-scope #3 red; pin (#6/#8) stays green
  REPO_DIR="$R11"; KICKOFF_DIR="$R11/.kickoff"
  run_scenario 'engine_hop_boundary >/dev/null'
  check "$X_COUNT" 0 "(h11) pin-green/full-RED -> NO exec (no hop into a dead startup)"
  check "$([ -f "$R11/.kickoff/hop-blocked" ] && echo yes || echo no)" "yes" "(h11) durable hop-blocked written on the full-scope red"
  check "$A_COUNT" 1 "(h11) exactly ONE alert for the blocked full-red hop"

  # (h5 unit) acquire_lock: lock pid == OWN pid accepted (exec keeps the PID);
  #           a DIFFERENT live pid still refused; a stale pid still reclaimed.
  local AL="$WORK/$n.acquire_lock.sh"
  extract_acquire_lock "$SRC_FILE" > "$AL"
  local L5="$WORK/$n.lock5"
  # own pid: a fresh bash writes ITS OWN $$ into the lock (the post-exec state), then acquires
  local own_rc
  own_rc="$(LOCKFILE="$L5" bash -c '
    log() { :; }
    . "'"$AL"'" 2>/dev/null || exit 99
    echo "$$" > "$LOCKFILE"
    acquire_lock && [ "$(cat "$LOCKFILE")" = "$$" ] && echo OK' 2>/dev/null || true)"
  check "${own_rc:-REFUSED}" "OK" "(h5) acquire_lock accepts lock pid == OWN pid (post-exec state)"
  # rival: a genuinely LIVE foreign pid (a sleep THIS test owns) must still be refused
  sleep 30 & RIVAL=$!; printf '%s\n' "$RIVAL" >> "$WORK/pids"
  local rival_out
  rival_out="$(LOCKFILE="$L5" bash -c '
    log() { printf "%s\n" "$*"; }
    . "'"$AL"'" 2>/dev/null || exit 99
    echo "'"$RIVAL"'" > "$LOCKFILE"
    acquire_lock
    echo "NOT-REFUSED"' 2>/dev/null || true)"
  kill "$RIVAL" 2>/dev/null || true
  check "$(printf '%s' "$rival_out" | grep -c 'another supervisor is already running')" 1 "(h5) a DIFFERENT live pid is still refused (rival detection intact)"
  check "$(printf '%s' "$rival_out" | grep -c 'NOT-REFUSED')" 0 "(h5) rival refusal exits (never proceeds past the lock)"
  # stale: a dead pid is still reclaimed (existing behavior preserved)
  local stale_rc
  stale_rc="$(LOCKFILE="$L5" bash -c '
    log() { :; }
    . "'"$AL"'" 2>/dev/null || exit 99
    echo 999999999 > "$LOCKFILE"
    acquire_lock && [ "$(cat "$LOCKFILE")" = "$$" ] && echo OK' 2>/dev/null || true)"
  check "${stale_rc:-REFUSED}" "OK" "(h5) a stale (dead-pid) lock is still reclaimed"
}

# ── run NEW (expect all green) ───────────────────────────────────────────────
echo "== assertions against NEW scripts/supervisor.sh =="
SRC_FILE="$SUPERVISOR_NEW"
UNIT_FILE="$WORK/unit.new.sh"; extract_unit "$SUPERVISOR_NEW" > "$UNIT_FILE"
if ! bash -n "$UNIT_FILE" 2>/dev/null; then bad "extracted hop unit fails bash -n (new)"; fi
suite new

# ── (h6c) NO-EXEC against the REAL live repo — READ-ONLY ─────────────────────
# What this lane is for: the shipped engine, pointed at THIS checkout, must not hop it.
#
# It used to assert that by hardcoding "the origin has a live supervisor and NO
# core.lock" and demanding the target resolve EMPTY. That premise died the day this
# repo became a pinned adopter of its own engine: a core.lock now exists, a target
# correctly resolves, and the lane went RED on a pre-push gate for behaviour the
# engine was getting right. Release pushes kept passing only because they run from a
# fresh worktree with no .kickoff/ at all, so nothing surfaced it.
#
# The unpinned-shape properties are NOT lost — h6a (no core.lock -> inert) and h6b
# (self-referential pin -> no target) already prove them on fixtures, which is where a
# shape assertion belongs. What only this lane can cover is the REAL checkout, and the
# guarantee that still holds there is the stronger one anyway: whatever resolves, no
# exec is attempted, because a live supervisor holds the lock and the boundary refuses.
# Asserting the true property keeps the workshop-never-hops cover; asserting the dead
# one would only have told us about the fixture's shape, which h6a already does.
#
# KICKOFF_DIR IS A COPY, AND THAT IS LOAD-BEARING. The old lane pointed it straight at
# the live .kickoff under a comment claiming "we only READ the live .kickoff — never
# write". That claim was FALSE and nothing tested it: on a blocked hop the unit writes
# `> "$KICKOFF_DIR/hop-blocked"` (supervisor.sh:1196), so every run of this suite dropped
# a real hop-blocked flag into the live org — a flag the unit itself reads back to decide
# whether to re-alert, so the residue could suppress or trigger a genuine alert later.
# Copying the directory keeps the lane's fidelity (same shape, same pin, same core.lock)
# and moves the write into $WORK where it belongs. h6d below proves the copy holds.
H6C_PINNED="$([ -f "$LIVE_REPO/.kickoff/core.lock" ] && echo pinned || echo unpinned)"
H6C_FLAG_PRE="$([ -f "$LIVE_REPO/.kickoff/hop-blocked" ] && echo present || echo absent)"
H6C_KICKOFF="$WORK/h6c.live-kickoff-copy"
mkdir -p "$H6C_KICKOFF"
if [ -d "$LIVE_REPO/.kickoff" ]; then cp -a "$LIVE_REPO/.kickoff/." "$H6C_KICKOFF/" 2>/dev/null || true; fi
rm -f "$H6C_KICKOFF/hop-blocked"          # start from "not currently blocked", whatever the live org's state
REPO_DIR="$LIVE_REPO"; KICKOFF_DIR="$H6C_KICKOFF"
SCRIPT_DIR="$LIVE_REPO/scripts"; RUNNING_ENGINE_DIR="$LIVE_REPO"; RUNNING_ENGINE_COMMIT="$C_OLD"
DRY_RUN=0
run_scenario '
  engine_hop_resolve
  printf "%s\n" "${HOP_TARGET_DIR:-EMPTY}" > "$WORK/h6c.target"
  engine_hop_boundary'
# ── what holds in EVERY topology, asserted unconditionally ───────────────────
# The release gate runs this suite in a FRESH WORKTREE, which has no .kickoff at all —
# and that caught the first version of this fix red-handed. The lane it replaced hardcoded
# "the origin has NO core.lock"; my replacement hardcoded the mirror image, "the origin IS
# pinned and has a live supervisor", and asserted an alert + a flag write that simply do not
# happen when nothing resolves. Same disease, opposite costume: a lane that encodes ONE
# deployment's shape and calls it the engine's behaviour.
# So: assert the invariant unconditionally, and gate the shape-specific assertions on what
# the run ACTUALLY DID (did a target resolve?) rather than on a guess about the checkout.
check "$X_COUNT" 0 "(h6c) the LIVE checkout attempts NO exec (shape=$H6C_PINNED, read-only)"
H6C_FLAG_POST="$([ -f "$LIVE_REPO/.kickoff/hop-blocked" ] && echo present || echo absent)"
check "$H6C_FLAG_POST" "$H6C_FLAG_PRE" \
  "(h6c) the live hop-blocked flag is UNCHANGED by this lane"

H6C_TARGET="$(cat "$WORK/h6c.target" 2>/dev/null | sed 's/^$/EMPTY/')"
if [ "$H6C_TARGET" = "EMPTY" ]; then
  # Unpinned checkout (a fresh release worktree): nothing resolves, so there is nothing to
  # block and nothing to alert about. Silence IS the correct behaviour — assert it.
  check "$A_COUNT" 0 "(h6c/unpinned) no target resolved, so no alert is raised"
  check "$([ -f "$H6C_KICKOFF/hop-blocked" ] && echo present || echo absent)" "absent" \
    "(h6c/unpinned) ...and no blocked-hop flag is written anywhere"
else
  # Pinned checkout with a live supervisor (the dogfood box): a target resolves, full-scope
  # preflight from the pinned engine refuses because the lock is held, and the unit raises
  # exactly ONE tokenless alert. That is the designed fail-loud path, not a defect.
  check "$A_COUNT" 1 "(h6c/pinned) exactly ONE fail-loud alert is raised"
  check "$(grep -c 'Engine hop BLOCKED' "$ALARM_LOG" 2>/dev/null)" 1 \
    "(h6c/pinned) that alert is a BLOCK, not a hop"
  check "$([ -f "$H6C_KICKOFF/hop-blocked" ] && echo present || echo absent)" "present" \
    "(h6c/pinned) the FIXTURE took the flag write — positive control that it happened somewhere"
fi
NEW_PASS=$PASS; NEW_FAIL=$FAIL

# ── (h5 integration) THE REAL HOP: same PID across the exec ──────────────────
# Two scratch ENGINE git repos (A = running, B = pinned-next), both carrying the REAL
# working-tree supervisor.sh AND the REAL preflight.sh (review find: an exit-0 stub here
# let the fossil-KICKOFF_CORE_DIR block ship — the launch env below carries
# KICKOFF_CORE_DIR=$ENG_A, which after the pin-advance is EXACTLY the production fossil,
# so this lane now exercises the true full-scope gate end-to-end). A REAL supervisor is
# spawned from A (env -i scrubbed; START_CMD=`sleep 600` — never a claude), then the test
# advances the pin to B + touches the refresh flag and watches the SAME pid re-exec into
# B's supervisor.sh. Every wait is a bounded poll; teardown TERMs the exact spawned pid.
echo
echo "== h5 integration: real fixture supervisor hops engines, PID unchanged =="
INT_OK=1
ENG_A="$WORK/int.engineA"; ENG_B="$WORK/int.engineB"; IREPO="$WORK/int.repo"
for e in "$ENG_A" "$ENG_B"; do
  mkdir -p "$e/scripts"
  cp "$SUPERVISOR_NEW" "$e/scripts/supervisor.sh"
  cp "$LIVE_REPO/scripts/preflight.sh" "$e/scripts/preflight.sh"
  git -C "$e" init -q
  git -C "$e" -c user.email=t@t.t -c user.name=t add -A
done
git -C "$ENG_A" -c user.email=t@t.t -c user.name=t commit -qm engineA
git -C "$ENG_A" tag core-vA
printf 'engine B marker\n' > "$ENG_B/MARKER"
git -C "$ENG_B" -c user.email=t@t.t -c user.name=t add -A
git -C "$ENG_B" -c user.email=t@t.t -c user.name=t commit -qm engineB
git -C "$ENG_B" tag core-vB
CA="$(git -C "$ENG_A" rev-parse HEAD)"
CB="$(git -C "$ENG_B" rev-parse HEAD)"
# the adopter, dressed to pass the REAL preflight FULL-scope (channel + in-repo data paths
# + memory index + zero-entry manifest); write_int_env pins an engine SURGICALLY — the
# core-dir line changes, every other config line is preserved (mirrors cmd_pull's persist).
mkdir -p "$IREPO/.kickoff/memory" "$IREPO/.kickoff/tg"
write_int_env() {
  {
    printf 'export KICKOFF_CORE_DIR="%s"\n' "$1"
    printf 'export TELEGRAM_STATE_DIR="%s/.kickoff/tg"\n' "$IREPO"
    printf 'export MC_STATE_FILE="%s/.kickoff/state/mission-state.json"\n' "$IREPO"
    printf 'export MEMORY_DB="%s/.kickoff/memory/index.db"\n' "$IREPO"
    printf 'export MEMORY_HOOK_LOG="%s/.kickoff/memory/hook.log"\n' "$IREPO"
  } > "$IREPO/.kickoff/instance.env"
}
write_int_env "$ENG_A"
printf '{"entries": [], "machine_entries": []}\n' > "$IREPO/.kickoff/adopt-manifest.json"
printf '# memory index stub\n' > "$IREPO/.kickoff/memory/MEMORY.md"
printf 'format 2\ntag core-vA\ncommit %s\n' "$CA" > "$IREPO/.kickoff/core.lock"

# TMPDIR="$WORK" pins the fixture supervisor's (and its session-run grandchildren's) temp trees —
# pty wrappers, mktemp scratch — INSIDE $WORK, so the existing `rm -rf "$WORK"` on EXIT sweeps them.
# Without it, env -i scrubs TMPDIR → grandchildren default to /tmp/tmp.* and leak OUTSIDE $WORK even
# on a clean teardown (indistinguishable from another org's fixtures, so uncleanable by name).
env -i PATH="$PATH" HOME="$HOME" TMPDIR="$WORK" \
  REPO_DIR="$IREPO" POLL_SECONDS=1 RESTART_BACKOFF_SECONDS=1 \
  START_CMD="sleep 600" BRIDGE_LIVENESS=0 MAX_SESSION_SECONDS=0 \
  PERMISSION_MODE=auto MODEL=fable EFFORT=max KICKOFF_CORE_DIR="$ENG_A" \
  bash "$ENG_A/scripts/supervisor.sh" > "$WORK/int.sup.log" 2>&1 &
SUP=$!
printf '%s\n' "$SUP" >> "$WORK/pids"

# wait (bounded) for the lock to appear with OUR spawned pid
i=0; while [ $i -lt 40 ]; do
  [ "$(cat "$IREPO/.kickoff/supervisor.lock" 2>/dev/null)" = "$SUP" ] && break
  kill -0 "$SUP" 2>/dev/null || break
  i=$((i+1)); sleep 0.5
done
if [ "$(cat "$IREPO/.kickoff/supervisor.lock" 2>/dev/null)" = "$SUP" ]; then
  ok "(h5i) fixture supervisor up on engine A (pid $SUP holds the lock)"
else
  bad "(h5i) fixture supervisor failed to start (see $WORK/int.sup.log)"; INT_OK=0
fi

if [ "$INT_OK" = 1 ]; then
  # hygiene: the pin actually reached the live process — so its session-run grandchildren inherit it
  # and their pty/temp trees land under $WORK (swept on EXIT), never a leaked /tmp/tmp.* tree.
  check "$(tr '\0' '\n' < "/proc/$SUP/environ" 2>/dev/null | grep -c "^TMPDIR=$WORK\$")" 1 \
    "(h5i) fixture supervisor TMPDIR pinned to \$WORK (grandchild temp trees land in the swept root)"
  # record the managed session's pgid for exact-target teardown
  SESS="$(cat "$IREPO/.kickoff/supervisor.session.pid" 2>/dev/null || true)"
  case "$SESS" in ''|*[!0-9]*) : ;; *) printf '%s\n' "$SESS" >> "$WORK/pids" ;; esac
  # advance the pin to engine B + accelerate (exactly what cmd_pull's tail does —
  # surgical env update, other config lines preserved)
  write_int_env "$ENG_B"
  printf 'format 2\ntag core-vB\ncommit %s\n' "$CB" > "$IREPO/.kickoff/core.lock"
  touch "$IREPO/.kickoff/refresh-requested"
  # wait (bounded) for the SAME pid's cmdline to name engine B's supervisor.sh
  hopped=0; i=0
  while [ $i -lt 60 ]; do
    if tr '\0' ' ' < "/proc/$SUP/cmdline" 2>/dev/null | grep -q "$ENG_B/scripts/supervisor.sh"; then hopped=1; break; fi
    kill -0 "$SUP" 2>/dev/null || break
    i=$((i+1)); sleep 0.5
  done
  check "$hopped" 1 "(h5i) SAME pid $SUP now executes engine B's supervisor.sh (exec hop landed)"
  # engine B's startup (the REAL preflight + a managed-session spawn) is ASYNC to the exec itself —
  # under box load it can land whole seconds after `hopped` reads true, and asserting immediately
  # made this lane a coin-flip (3 in-battery REDs on 2026-08-24, all `want=2 got=1` / no-session,
  # each green standalone minutes later). Wait BOUNDED for both post-hop markers first: expiry falls
  # through to the UNCHANGED assertions below, so a genuinely-dead startup still REDs exactly as before.
  HOP_DEADLINE=$(( $(date +%s) + 90 ))
  while [ "$(date +%s)" -lt "$HOP_DEADLINE" ]; do
    _pf="$(grep -c 'preflight PASSED' "$WORK/int.sup.log" 2>/dev/null || true)"
    _sp="$(cat "$IREPO/.kickoff/supervisor.session.pid" 2>/dev/null || true)"
    [ "${_pf:-0}" -ge 2 ] && [ -n "$_sp" ] && break
    sleep 1
  done
  check "$(cat "$IREPO/.kickoff/supervisor.lock" 2>/dev/null)" "$SUP" "(h5i) lock pid UNCHANGED across the hop (exec semantics)"
  if [ "$hopped" = 1 ]; then
    ENVDUMP="$(tr '\0' '\n' < "/proc/$SUP/environ" 2>/dev/null || true)"
    check "$(printf '%s\n' "$ENVDUMP" | grep -c '^MODEL=')"  0 "(h5i) MODEL dropped from the live process env at the exec"
    check "$(printf '%s\n' "$ENVDUMP" | grep -c '^EFFORT=')" 0 "(h5i) EFFORT dropped from the live process env at the exec"
    check "$(printf '%s\n' "$ENVDUMP" | grep -c '^KICKOFF_CORE_DIR=')" 0 "(h5i) fossil KICKOFF_CORE_DIR dropped at the exec"
    check "$(printf '%s\n' "$ENVDUMP" | grep -c '^PERMISSION_MODE=auto$')" 1 "(h5i) PERMISSION_MODE=auto carried (kernel-held grant)"
    check "$(printf '%s\n' "$ENVDUMP" | grep -c "^REPO_DIR=$IREPO\$")" 1 "(h5i) REPO_DIR carried (identity)"
    check "$(printf '%s\n' "$ENVDUMP" | grep -c '^KICKOFF_HOP_EXEC=1$')" 1 "(h5i) hop-landing marker present in the exec image (post-exec startup red would alert)"
    check "$(grep -c 'engine-hop: verified GREEN' "$WORK/int.sup.log")" 1 "(h5i) hop logged the green verification exactly once"
    # the REAL full-scope gate ran green on BOTH starts: engine A's launch AND engine B's
    # post-exec startup (an exit-0 stub could never prove this — review find)
    check "$(grep -c 'preflight PASSED' "$WORK/int.sup.log")" 2 "(h5i) REAL preflight PASSED at launch AND at the post-hop startup (fossil defeated end-to-end)"
    check "$([ -f "$IREPO/.kickoff/hop-blocked" ] && echo yes || echo no)" "no" "(h5i) no hop-blocked flag (the fossil KICKOFF_CORE_DIR=engineA in the launch env could not block)"
    # the new engine's supervisor must have ACCEPTED its own lock (no refusal, no exit)
    check "$(grep -c 'refusing to start a second' "$WORK/int.sup.log")" 0 "(h5i) post-hop acquire_lock did NOT refuse its own pid"
    # and it restarted a managed session from the NEW engine
    NSESS="$(cat "$IREPO/.kickoff/supervisor.session.pid" 2>/dev/null || true)"
    case "$NSESS" in ''|*[!0-9]*) NSESS="" ;; *) printf '%s\n' "$NSESS" >> "$WORK/pids" ;; esac
    check "$([ -n "$NSESS" ] && kill -0 "$NSESS" 2>/dev/null && echo yes || echo no)" "yes" "(h5i) a fresh managed session is running post-hop"
    if [ -n "$NSESS" ]; then
      SESS_ENV="$(tr '\0' '\n' < "/proc/$NSESS/environ" 2>/dev/null || true)"
      check "$(printf '%s\n' "$SESS_ENV" | grep -c '^KICKOFF_HOP_EXEC=')" 0 "(h5i) landing marker NOT leaked into the managed session's env"
    fi
  fi
  # teardown: TERM the exact spawned supervisor (its trap reaps its own session group)
  kill -TERM "$SUP" 2>/dev/null || true
  i=0; while [ $i -lt 20 ]; do kill -0 "$SUP" 2>/dev/null || break; i=$((i+1)); sleep 0.5; done
  check "$(kill -0 "$SUP" 2>/dev/null && echo alive || echo gone)" "gone" "(h5i) fixture supervisor torn down clean (exact pid, TERM only)"
fi
NEW_PASS=$PASS; NEW_FAIL=$FAIL

# ── RED-ON-OLD: the same unit assertions must FAIL against HEAD ───────────────
echo
echo "== RED-on-old: same assertions against HEAD:scripts/supervisor.sh =="
OLD_SRC="$WORK/supervisor.old.sh"
if git -C "$SCRIPT_DIR" show HEAD:scripts/supervisor.sh > "$OLD_SRC" 2>/dev/null; then
  UNIT_OLD="$WORK/unit.old.sh"; extract_unit "$OLD_SRC" > "$UNIT_OLD"
  AL_NEW="$WORK/al.new.probe"; AL_OLD="$WORK/al.old.probe"
  extract_acquire_lock "$SUPERVISOR_NEW" > "$AL_NEW"
  extract_acquire_lock "$OLD_SRC"       > "$AL_OLD"
  if cmp -s "$WORK/unit.new.sh" "$UNIT_OLD" && cmp -s "$AL_NEW" "$AL_OLD"; then
    RED_ON_OLD=skip; printf '  skip RED-on-old n/a — hop unit + acquire_lock byte-identical to HEAD (post-commit state)\n'
  else
    PASS=0; FAIL=0
    SRC_FILE="$OLD_SRC"
    UNIT_FILE="$UNIT_OLD"
    suite old >/dev/null 2>&1
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

# ── suite hygiene: NO fixture process this suite spawned outlives the run ──────
# Every recorded pid (the integration supervisor + its managed sessions, the h5 rival sleeps) is
# reaped inline / by teardown; the EXIT trap is the safety net. Assert here (before the trap fires)
# that nothing this run spawned is still alive — scoped to THIS run's exact recorded pids (kill -0),
# never a pattern scan that would catch another org's live worker. Folded into NEW_* (the summary's).
HYG_LEAK=""
if [ -f "$WORK/pids" ]; then
  while IFS= read -r p; do
    case "$p" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$p" 2>/dev/null && HYG_LEAK="$HYG_LEAK $p"
  done < "$WORK/pids"
fi
if [ -z "$HYG_LEAK" ]; then
  printf '  ok   (hygiene) no fixture process this suite spawned outlives the run\n'; NEW_PASS=$((NEW_PASS+1))
else
  printf '  FAIL (hygiene) fixture process(es) still alive after the run:%s\n' "$HYG_LEAK"; NEW_FAIL=$((NEW_FAIL+1))
fi

# (h6d) the paired half of the baseline taken at the top: prove read-only, don't claim it.
LIVE_KICKOFF_POST="$WORK/live-kickoff.post"
snapshot_live_kickoff "$LIVE_KICKOFF_POST"
if [ "${H6D_FORCE_LEAK:-0}" = "1" ]; then
  # negative control: proves this canary can actually go RED (see the RED-first note in
  # the header). Writes ONLY into $WORK's copy of the manifest, never the live repo.
  printf './h6d-negative-control\n' >> "$LIVE_KICKOFF_POST"
fi
if H6D_DIFF="$(diff "$LIVE_KICKOFF_PRE" "$LIVE_KICKOFF_POST" 2>&1)" && [ -z "$H6D_DIFF" ]; then
  printf '  ok   (h6d) the suite created/removed nothing in the live .kickoff (read-only honoured)\n'; NEW_PASS=$((NEW_PASS+1))
else
  printf '  FAIL (h6d) the live .kickoff path set CHANGED across this run — the suite wrote to the live repo:\n%s\n' "$H6D_DIFF"; NEW_FAIL=$((NEW_FAIL+1))
fi

echo
echo "== summary =="
printf 'NEW: pass=%s fail=%s   RED-on-old proven=%s\n' "$NEW_PASS" "$NEW_FAIL" "${RED_ON_OLD:-0}"
case "${RED_ON_OLD:-0}" in 1|skip)
  if [ "$NEW_FAIL" -eq 0 ]; then echo "SELFTEST PASS"; exit 0; fi ;;
esac
echo "SELFTEST FAIL"; exit 1
