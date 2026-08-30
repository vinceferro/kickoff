#!/usr/bin/env bash
# start-surface-selftest.sh — hermetic proof of v0.7 G1 §2.2: `kickoff up` is the ONLY
# start surface — `--detach` (go-autonomous.sh's one real job, rebuilt ON the slice-3
# hygiene boundary), `--replace` (the finish-v06 stop discipline: exact verified lock
# pid, TERM → ≤35s wait → refuse-to-escalate), and the PIN-REDIRECT (the wrapper-killer:
# any kickoff binary on the box hands off to the repo's PINNED engine, argv verbatim).
#
# THE BUG CLASS THIS GUARDS (the v0.6 incident): lifecycle smeared across per-version
# ~/start-*-worker.sh wrappers that rotted within one version (hardcoded old engine
# paths) — upgrade turnkeys advanced pins but the muscle-memory start command kept
# launching the OLD engine. The pin-redirect makes the command structurally rot-proof;
# --detach/--replace fold the wrapper's remaining jobs into the engine itself.
#
# What it proves, through a REAL `kickoff up` run (cmd_up → stub start-supervisor):
#   (a) --detach: the spawned worker SURVIVES the caller's exit in its OWN session
#       (setsid), the lock is written, the supervisor log is created + appended, the
#       size-based rotate fires past LOG_MAX_BYTES, and pid + log path + the one-line
#       stop command are printed                                     [RED on pre-slice]
#   (b) --replace: a fixture supervisor (a tiny bash script literally named
#       scripts/supervisor.sh, holding a lock the test wrote) is TERM'd + waited and
#       the new start proceeds; a FOREIGN-cmdline pid in the lock → REFUSE loudly,
#       never signal; a live kickoff supervisor belonging to a DIFFERENT org
#       (environ REPO_DIR mismatch) → REFUSE loudly, never signal; a CORRUPT lock
#       line ('18 60600') is never digit-squashed into a live pid — stale-with-eyes,
#       proceed, signal nothing; a dead-pid stale lock → cleaned + proceed; no lock
#       → plain start (not an error)                                 [RED on pre-slice]
#   (c) pin-redirect: a fixture repo pinned (instance.env KICKOFF_CORE_DIR +
#       .kickoff/core.lock) to engine-B, engine-A's `kickoff up …` → the spawn
#       PROVABLY ran engine-B's kickoff with argv preserved (incl. --auto)
#       [MUST be RED on pre-slice]; realpath-same → no redirect (no infinite
#       re-exec); no core.lock → no redirect (the origin/dogfood case); pinned
#       engine missing → LOUD die, rc!=0, never a silent wrong-engine start
#   (d) shim: go-autonomous.sh is a one-version deprecation shim — it prints ONE
#       deprecation line and execs `kickoff up --auto --detach` (removed in v0.8)
#   (e) boundary intact: the slice-3 spawn-hygiene leak-drop holds THROUGH the
#       --detach path (the new path uses the same build_worker_env boundary)
#   (f) --detach under a LIVE supervisor without --replace → dies LOUD pre-spawn
#       (points at --replace); it must NEVER report the OLD pid as a fresh start
#       succeeding (the false-success cell — adversarial find, 07-12)
#   (g) a LEAKED ambient KICKOFF_SUPERVISOR_LOG (every worker session carries one)
#       never becomes the redirect/rotate target: the worker logs into ITS org's
#       own .kickoff/supervisor.log and the decoy (another org's live log) is
#       byte-unchanged, never copytruncated (adversarial find, 07-12)
#
# HOW IT STAYS HERMETIC (mirrors spawn-hygiene-selftest.sh):
#   - Runs COPIES of scripts/kickoff + scripts/go-autonomous.sh from scratch engine
#     dirs against mktemp fixture repos (REPO_DIR is always the fixture — never the
#     live repo; no live supervisor is ever read, signalled, or replaced).
#   - start-supervisor.sh is replaced by a STUB whose probe path is BAKED IN at
#     creation (dropping unknown env vars is part of the behavior under test); a mode
#     file switches it between exit-fast (foreground runs) and hold-a-lock (--detach).
#   - Every run starts from `env -i` with a CONTROLLED caller env — the live worker
#     env cannot leak in; no `claude` binary (real or stub) is ever spawned.
#   - Every process the test spawns (detached stubs, fixture supervisors, sleeps) has
#     its EXACT pid recorded and killed EXACTLY (kill <pid>, cmdline-verified first —
#     never a pattern kill); every stub also self-exits within ~30s as a belt.
#
# RED-ON-OLD: re-runs the same assertions against HEAD's kickoff + go-autonomous.sh
# and requires the spec-named checks — (c1) pin-redirect + (b1) replace-cycles — to
# FAIL there. A check that never went RED proves nothing
# (memory/fixture-can-mask-the-bug-it-should-catch.md). Byte-identical to HEAD (the
# normal post-commit state) or HEAD already carrying the slice-4 markers (a later,
# start-surface-unrelated working-tree edit) → the lane is N/A and auto-SKIPPED,
# exactly like spawn-hygiene-selftest.sh.
#
# Usage:  bash scripts/start-surface-selftest.sh
# Exit non-zero on any failed assertion (or if RED-on-old is not proven).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KI_NEW="$SCRIPT_DIR/kickoff"
GA_NEW="$SCRIPT_DIR/go-autonomous.sh"
RL_NEW="$SCRIPT_DIR/rotate-log.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/start-surface-selftest.XXXXXX")"
mkdir -p "$WORK/home"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$1" = "$2" ]; then ok "$3 (=$1)"; else bad "$3 (want=$2 got=$1)"; fi; }

# ── exact-pid cleanup (never a pattern kill) ─────────────────────────────────
# kill_mine PID PATTERN — signal ONLY a pid this test spawned, and only after its
# /proc cmdline matches the shape we spawned (a reused pid is never signalled).
kill_mine() {
  local p="${1:-}" pat="${2:-}" c
  [ -n "$p" ] || return 0
  c="$(tr '\0' ' ' 2>/dev/null < "/proc/$p/cmdline" || true)"
  [ -n "$c" ] || return 0                      # already gone
  case "$c" in
    *"$pat"*) kill "$p" 2>/dev/null || true ;;
    *) printf '  WARN refusing to kill pid %s — cmdline does not match ours (%s)\n' "$p" "$c" ;;
  esac
}
CLEANUP_PIDS=()   # "pid|pattern" pairs — the EXIT belt
cleanup() {
  local e p
  for e in ${CLEANUP_PIDS[@]+"${CLEANUP_PIDS[@]}"}; do
    kill_mine "${e%%|*}" "${e#*|}"
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

# wait_dead PID [tries] — poll until the pid is gone (0.2s steps)
wait_dead() {
  local p="$1" n="${2:-50}" i
  for i in $(seq 1 "$n"); do kill -0 "$p" 2>/dev/null || return 0; sleep 0.2; done
  return 1
}

PROBE_SS="$WORK/probe.ss"        # written by the stub start-supervisor (baked path)
PROBE_B="$WORK/probe.engineB"    # written by engine-B's stub kickoff (baked path)
SS_MODE="$WORK/ss-mode"          # exit | hold — switches the stub per run

ohas()  { if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (missing in output: $2)"; fi; }
omiss() { if grep -qF -- "$2" "$1" 2>/dev/null; then bad "$3 (present in output: $2)"; else ok "$3"; fi; }
# probe-anchored env assertions (fixture-can-mask lesson: absence needs a live probe)
sshas() { if grep -qxF -- "SSENV $1" "$PROBE_SS" 2>/dev/null; then ok "$2"; else bad "$2 (missing: SSENV $1)"; fi; }
ssmiss_name() {
  if [ ! -s "$PROBE_SS" ]; then bad "$2 (no probe — the start never ran)"; return; fi
  if grep -q "^SSENV $1=" "$PROBE_SS"; then bad "$2 ($(grep -m1 "^SSENV $1=" "$PROBE_SS"))"; else ok "$2"; fi
}

REALPATH_DIRS="/usr/bin:/bin"    # setsid, nohup, ps, coreutils — no stub claude, ever

# ── fixture factories (spawn-hygiene-selftest.sh's shape) ────────────────────
make_engine() {  # $1=tag $2=kickoff-copy $3=go-autonomous-copy ; prints the engine scripts dir
  local eng="$WORK/engine.$1"
  rm -rf "$eng"; mkdir -p "$eng/scripts"
  cp "$2" "$eng/scripts/kickoff"
  cp "$3" "$eng/scripts/go-autonomous.sh"
  cp "$RL_NEW" "$eng/scripts/rotate-log.sh"
  # stub start-supervisor: probe (baked path) + mode-switched lock-hold. In `hold`
  # mode it acts like a real supervisor for the lifecycle under test: writes the lock,
  # logs a line (stdout → the supervisor log in --detach), traps TERM to clean the
  # lock, and SELF-EXITS in ≤20s as the no-orphan belt.
  cat > "$eng/scripts/start-supervisor.sh" <<EOF
#!/usr/bin/env bash
KD="\${REPO_DIR:?}/.kickoff"; mkdir -p "\$KD"
{
  printf 'SS-RUN pid=%s\n' "\$\$"
  while IFS= read -r n; do printf 'SSENV %s=%s\n' "\$n" "\${!n}"; done < <(compgen -e)
} > "$PROBE_SS"
mode="\$(cat "$SS_MODE" 2>/dev/null || echo exit)"
if [ "\$mode" = hold ]; then
  echo "\$\$" > "\$KD/supervisor.lock"
  printf 'STUB-SUP holding pid=%s\n' "\$\$"
  trap 'rm -f "\$KD/supervisor.lock"; exit 0' TERM INT
  c=0; while [ "\$c" -lt 100 ]; do sleep 0.2; c=\$((c+1)); done
  rm -f "\$KD/supervisor.lock"
fi
exit 0
EOF
  chmod +x "$eng/scripts/"*
  printf '%s' "$eng/scripts"
}

make_repo() {  # $1=name, rest = extra instance.env lines ; prints the fixture repo path
  local fix="$WORK/$1"; shift
  mkdir -p "$fix/.kickoff"
  {
    printf 'TELEGRAM_STATE_DIR=%s\n' "$fix/.kickoff/chan"
    local l; for l in "$@"; do printf '%s\n' "$l"; done
  } > "$fix/.kickoff/instance.env"
  printf '%s' "$fix"
}

# engine-B: a STUB front door that only proves it was exec'd with which argv
make_engine_b() {
  local root="$WORK/engineB"
  rm -rf "$root"; mkdir -p "$root/scripts"
  cat > "$root/scripts/kickoff" <<EOF
#!/usr/bin/env bash
{
  printf 'B-KICKOFF %s\n' "\$0"
  for a in "\$@"; do printf 'BARG %s\n' "\$a"; done
} > "$PROBE_B"
exit 0
EOF
  chmod +x "$root/scripts/kickoff"
  printf '%s' "$root"
}

# fixture "supervisor": a tiny bash script literally named scripts/supervisor.sh, so
# its /proc cmdline IS a kickoff-supervisor shape (a bare `sleep` could never match).
make_fixture_supervisor() {
  local root="$WORK/fixsup"
  mkdir -p "$root/scripts"
  cat > "$root/scripts/supervisor.sh" <<'EOF'
#!/usr/bin/env bash
lock="$1"
mkdir -p "$(dirname "$lock")"
echo "$$" > "$lock"
trap 'rm -f "$lock"; exit 0' TERM INT
sleep 30 & wait $!
rm -f "$lock"
exit 0
EOF
  chmod +x "$root/scripts/supervisor.sh"
  printf '%s' "$root/scripts/supervisor.sh"
}
FIXSUP="$(make_fixture_supervisor)"

# run_up ENGINE REPO LOG [K=V ...] [-- <kickoff up args...>] — CONTROLLED caller env:
# env -i wipes the test's own env; the K=V operands plant exactly what a check needs.
run_up() {
  local eng="$1" fix="$2" lg="$3"; shift 3
  local -a extra_env=() args=()
  local in_args=0 x
  for x in "$@"; do
    if [ "$x" = "--" ]; then in_args=1; continue; fi
    if [ "$in_args" = 1 ]; then args+=("$x"); else extra_env+=("$x"); fi
  done
  rm -f "$PROBE_SS" "$PROBE_B"
  timeout 60 env -i PATH="$REALPATH_DIRS" HOME="$WORK/home" TERM=dumb \
    REPO_DIR="$fix" ${extra_env[@]+"${extra_env[@]}"} \
    bash "$eng/kickoff" up ${args[@]+"${args[@]}"} </dev/null >"$lg" 2>&1
}

run_shim() {  # ENGINE REPO LOG — the go-autonomous.sh deprecation shim, same controlled env
  local eng="$1" fix="$2" lg="$3"
  rm -f "$PROBE_SS" "$PROBE_B"
  timeout 60 env -i PATH="$REALPATH_DIRS" HOME="$WORK/home" TERM=dumb \
    REPO_DIR="$fix" bash "$eng/go-autonomous.sh" </dev/null >"$lg" 2>&1
}

# Does this kickoff copy already carry the slice-4 start surface? (the committed-at-
# HEAD self-skip discipline — same shape as spawn-hygiene-selftest.sh's slice3_markers)
slice4_markers() {  # $1=kickoff
  grep -q -- '--detach'      "$1" 2>/dev/null || return 1
  grep -q -- '--replace'     "$1" 2>/dev/null || return 1
  grep -q    'pin-redirect'  "$1" 2>/dev/null || return 1
  return 0
}

LEAK_TSD="$WORK/LEAKED-caller-chan"   # never created — a leak would be value-anchored

# ── the assertion suite (NEW = expect all-green; OLD = expect the named reds) ─
suite() {
  local tag="$1" kick="$2" goauto="$3"
  local eng engroot fix lg rc pid sid fpid spid dpid lock suplog decoy decoy_sha

  eng="$(make_engine "$tag" "$kick" "$goauto")"
  engroot="${eng%/scripts}"

  bash -n "$eng/kickoff" 2>/dev/null           && ok "($tag) kickoff parses (bash -n)"       || bad "($tag) kickoff fails bash -n"
  bash -n "$eng/go-autonomous.sh" 2>/dev/null  && ok "($tag) go-autonomous parses (bash -n)" || bad "($tag) go-autonomous fails bash -n"

  # ── (a) --detach: survive the caller, lock, log append, rotate, printed stop line ─
  fix="$(make_repo "repo.$tag.a")"
  lg="$WORK/$tag.log.a"
  lock="$fix/.kickoff/supervisor.lock"
  suplog="$fix/.kickoff/supervisor.log"
  printf 'old-log-line %0.s' $(seq 1 400) > "$suplog"   # ~5.6KB seed, past the 1KB cap below
  printf 'hold\n' > "$SS_MODE"
  run_up "$eng" "$fix" "$lg" LOG_MAX_BYTES=1024 -- --auto --detach; rc=$?
  check "$rc" 0 "(a) kickoff up --detach exits 0"
  pid="$(head -n1 "$lock" 2>/dev/null | tr -dc '0-9')"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    CLEANUP_PIDS+=( "$pid|$engroot" )
    ok "(a1) lock written and the detached worker is ALIVE after the caller exited (pid $pid)"
    sid="$(ps -o sid= -p "$pid" 2>/dev/null | tr -dc '0-9')"
    check "$sid" "$pid" "(a2) the worker leads its OWN session (setsid — survives any caller teardown)"
  else
    bad "(a1) no live detached worker (lock pid '${pid:-none}')"
    bad "(a2) setsid session check skipped — no live worker"
  fi
  if grep -qF 'STUB-SUP holding' "$suplog" 2>/dev/null; then
    ok "(a3) supervisor log created + appended by the detached worker"
  else
    bad "(a3) supervisor log has no worker output ($suplog)"
  fi
  if [ -f "$suplog.1" ] && ! grep -qF 'old-log-line' "$suplog" 2>/dev/null; then
    ok "(a4) size-based rotate fired past LOG_MAX_BYTES (copytruncate → $suplog.1)"
  else
    bad "(a4) rotate did not fire (no $suplog.1 / old bytes still in $suplog)"
  fi
  [ -n "$pid" ] && ohas "$lg" "pid:  $pid"  "(a5) the detached pid is printed" || bad "(a5) the detached pid is printed (no pid)"
  ohas "$lg" "log:  $suplog"                "(a6) the log path is printed"
  ohas "$lg" 'kill -TERM'                   "(a7) the one-line stop command is printed"
  sshas "PERMISSION_MODE=auto"              "(a8) --auto reaches the detached worker (grant intact)"
  kill_mine "$pid" "$engroot"; [ -n "$pid" ] && wait_dead "$pid"

  # ── (b) --replace: the finish-v06 stop discipline ────────────────────────────
  # (b1) a live fixture supervisor holding the lock → TERM'd, waited, new start proceeds
  fix="$(make_repo "repo.$tag.b1")"
  lg="$WORK/$tag.log.b1"
  lock="$fix/.kickoff/supervisor.lock"
  # the fixture supervisor carries ITS org in /proc/<pid>/environ (REPO_DIR), exactly
  # like a real engine-launched supervisor — the own-org check reads it before TERM
  env REPO_DIR="$fix" bash "$FIXSUP" "$lock" & fpid=$!
  CLEANUP_PIDS+=( "$fpid|$WORK" )
  for _ in $(seq 1 25); do [ -s "$lock" ] && break; sleep 0.2; done
  check "$(head -n1 "$lock" 2>/dev/null)" "$fpid" "(b0) fixture supervisor holds the lock (pid $fpid)"
  printf 'exit\n' > "$SS_MODE"
  run_up "$eng" "$fix" "$lg" -- --replace; rc=$?
  check "$rc" 0 "(b1) kickoff up --replace exits 0"
  ohas "$lg" "supervisor pid $fpid" "(b1a) it targeted exactly the lock pid"
  ohas "$lg" "stopped clean"        "(b1b) TERM → waited → stopped clean (no escalation)"
  if kill -0 "$fpid" 2>/dev/null; then bad "(b1c) old supervisor still alive after --replace"; else ok "(b1c) old supervisor is gone"; fi
  [ -s "$PROBE_SS" ] && ok "(b1d) the new start proceeded (start-supervisor ran)" || bad "(b1d) the new start never ran"
  [ ! -f "$lock" ] && ok "(b1e) the old lock is cleaned" || bad "(b1e) the old lock is still present"

  # (b2) FOREIGN-cmdline pid in the lock → REFUSE loudly, never signal
  fix="$(make_repo "repo.$tag.b2")"
  lg="$WORK/$tag.log.b2"
  lock="$fix/.kickoff/supervisor.lock"
  sleep 30 & spid=$!
  CLEANUP_PIDS+=( "$spid|sleep" )
  echo "$spid" > "$lock"
  printf 'exit\n' > "$SS_MODE"
  run_up "$eng" "$fix" "$lg" -- --replace; rc=$?
  [ "$rc" -ne 0 ] && ok "(b2) --replace with a foreign lock pid exits non-zero (rc=$rc)" || bad "(b2) --replace with a foreign lock pid exited 0"
  ohas "$lg" 'NOT a kickoff supervisor' "(b2a) the refusal names the real state (cmdline-verified)"
  ohas "$lg" 'REFUSING'                 "(b2b) it REFUSES loudly"
  if kill -0 "$spid" 2>/dev/null; then ok "(b2c) the foreign pid was NEVER signalled (still alive)"; else bad "(b2c) the foreign pid died — it was signalled"; fi
  [ ! -s "$PROBE_SS" ] && ok "(b2d) no new start after the refusal" || bad "(b2d) a new start ran despite the refusal"
  kill_mine "$spid" "sleep"; wait_dead "$spid"

  # (b3) dead-pid stale lock → cleaned + proceed
  fix="$(make_repo "repo.$tag.b3")"
  lg="$WORK/$tag.log.b3"
  lock="$fix/.kickoff/supervisor.lock"
  sleep 0.01 & dpid=$!; wait "$dpid" 2>/dev/null
  echo "$dpid" > "$lock"
  printf 'exit\n' > "$SS_MODE"
  run_up "$eng" "$fix" "$lg" -- --replace; rc=$?
  check "$rc" 0 "(b3) --replace over a stale lock exits 0"
  ohas "$lg" 'STALE' "(b3a) the stale lock is named"
  [ ! -f "$lock" ] && ok "(b3b) the stale lock is cleaned" || bad "(b3b) the stale lock survived"
  [ -s "$PROBE_SS" ] && ok "(b3c) the start proceeded" || bad "(b3c) the start never ran"

  # (b4) no lock at all → plain start, NOT an error
  fix="$(make_repo "repo.$tag.b4")"
  lg="$WORK/$tag.log.b4"
  printf 'exit\n' > "$SS_MODE"
  run_up "$eng" "$fix" "$lg" -- --replace; rc=$?
  check "$rc" 0 "(b4) --replace with no lock exits 0 (plain start)"
  ohas "$lg" 'nothing to stop' "(b4a) it says so honestly"
  [ -s "$PROBE_SS" ] && ok "(b4b) the start proceeded" || bad "(b4b) the start never ran"

  # (b5) a LIVE kickoff supervisor whose ORG (environ REPO_DIR) is NOT this repo →
  # REFUSE loudly, never signal. "a kickoff supervisor" alone is not "OUR supervisor":
  # several orgs run supervisors on one box, and a stale lock + reused pid could name
  # another org's live worker (adversarial find, 07-12 — never a cross-org kill).
  fix="$(make_repo "repo.$tag.b5")"
  lg="$WORK/$tag.log.b5"
  lock="$fix/.kickoff/supervisor.lock"
  env REPO_DIR="$WORK/some-other-org" bash "$FIXSUP" "$lock" & fpid=$!
  CLEANUP_PIDS+=( "$fpid|$WORK" )
  for _ in $(seq 1 25); do [ -s "$lock" ] && break; sleep 0.2; done
  printf 'exit\n' > "$SS_MODE"
  run_up "$eng" "$fix" "$lg" -- --replace; rc=$?
  [ "$rc" -ne 0 ] && ok "(b5) --replace with a foreign-ORG supervisor exits non-zero (rc=$rc)" || bad "(b5) --replace with a foreign-ORG supervisor exited 0"
  ohas "$lg" 'NOT this org' "(b5a) the refusal names the cross-org state"
  if kill -0 "$fpid" 2>/dev/null; then ok "(b5b) the other org's supervisor was NEVER signalled (still alive)"; else bad "(b5b) the other org's supervisor died — it was signalled"; fi
  [ ! -s "$PROBE_SS" ] && ok "(b5c) no new start after the refusal" || bad "(b5c) a new start ran despite the refusal"
  kill_mine "$fpid" "$WORK"; wait_dead "$fpid"

  # (b6) a CORRUPT lock line must never be digit-squashed into a pid: '1 2345'
  # squashing to a LIVE pid that was never in the lock is a minted kill target
  # (adversarial find, 07-12). Strict parse → stale-with-eyes → proceed, signal NOTHING.
  fix="$(make_repo "repo.$tag.b6")"
  lg="$WORK/$tag.log.b6"
  lock="$fix/.kickoff/supervisor.lock"
  env REPO_DIR="$fix" bash "$FIXSUP" "$fix/.kickoff/decoy.lock" & fpid=$!   # alive — but NEVER in the real lock
  CLEANUP_PIDS+=( "$fpid|$WORK" )
  for _ in $(seq 1 25); do [ -s "$fix/.kickoff/decoy.lock" ] && break; sleep 0.2; done
  printf '%s %s\n' "${fpid:0:1}" "${fpid:1}" > "$lock"    # digit-squashes to exactly $fpid
  printf 'exit\n' > "$SS_MODE"
  run_up "$eng" "$fix" "$lg" -- --replace; rc=$?
  check "$rc" 0 "(b6) --replace over a corrupt lock exits 0 (stale-with-eyes, plain start)"
  ohas "$lg" 'CORRUPT' "(b6a) the corrupt line is named loudly"
  if kill -0 "$fpid" 2>/dev/null; then ok "(b6b) the live pid the squash would mint was NEVER signalled (still alive)"; else bad "(b6b) the squashed-digit pid was signalled (blind kill)"; fi
  [ -s "$PROBE_SS" ] && ok "(b6c) the start proceeded" || bad "(b6c) the start never ran"
  kill_mine "$fpid" "$WORK"; wait_dead "$fpid"

  # ── (c) pin-redirect: the wrapper-killer ─────────────────────────────────────
  local engB; engB="$(make_engine_b)"

  # (c1) pinned to engine-B → engine-A's front door EXECs engine-B's, argv verbatim
  fix="$(make_repo "repo.$tag.c1" "KICKOFF_CORE_DIR=$engB")"
  : > "$fix/.kickoff/core.lock"
  lg="$WORK/$tag.log.c1"
  printf 'exit\n' > "$SS_MODE"
  run_up "$eng" "$fix" "$lg" -- --auto --detach; rc=$?
  check "$rc" 0 "(c1) redirected run exits 0 (engine-B's stub rc)"
  if grep -qxF "B-KICKOFF $engB/scripts/kickoff" "$PROBE_B" 2>/dev/null; then
    ok "(c1a) the spawn PROVABLY ran engine-B's kickoff (pin-redirect fired)"
  else
    bad "(c1a) engine-B's kickoff never ran — no redirect"
  fi
  if [ -s "$PROBE_B" ] && [ "$(grep -c '^BARG ' "$PROBE_B")" = 3 ] \
     && grep -qxF 'BARG up' "$PROBE_B" && grep -qxF 'BARG --auto' "$PROBE_B" && grep -qxF 'BARG --detach' "$PROBE_B"; then
    ok "(c1b) the ORIGINAL argv reached engine-B verbatim (up --auto --detach)"
  else
    bad "(c1b) argv not preserved through the redirect ($(tr '\n' ' ' 2>/dev/null < "$PROBE_B" || echo 'no probe'))"
  fi
  [ ! -s "$PROBE_SS" ] && ok "(c1c) engine-A never started its own worker" || bad "(c1c) engine-A ALSO started its own worker"

  # (c2) pinned to ITSELF (realpath-equal) → no redirect, no infinite re-exec
  fix="$(make_repo "repo.$tag.c2" "KICKOFF_CORE_DIR=$engroot")"
  : > "$fix/.kickoff/core.lock"
  lg="$WORK/$tag.log.c2"
  printf 'exit\n' > "$SS_MODE"
  run_up "$eng" "$fix" "$lg"; rc=$?
  check "$rc" 0 "(c2) realpath-same pin exits 0 (ran itself, no re-exec loop)"
  [ -s "$PROBE_SS" ] && ok "(c2a) the engine ran its OWN start" || bad "(c2a) the engine never started"
  omiss "$lg" 'pin-redirect' "(c2b) no redirect is announced"

  # (c3) NO core.lock → no redirect (origin / un-adopted repo runs itself — dogfood)
  fix="$(make_repo "repo.$tag.c3" "KICKOFF_CORE_DIR=$engB")"
  lg="$WORK/$tag.log.c3"
  printf 'exit\n' > "$SS_MODE"
  run_up "$eng" "$fix" "$lg"; rc=$?
  check "$rc" 0 "(c3) no core.lock exits 0"
  [ -s "$PROBE_SS" ] && ok "(c3a) the invoked engine ran itself (a stray KICKOFF_CORE_DIR alone never redirects)" || bad "(c3a) the invoked engine never started"
  [ ! -s "$PROBE_B" ] && ok "(c3b) engine-B was NOT exec'd" || bad "(c3b) engine-B ran without a core.lock"

  # (c4) pinned engine MISSING → die LOUD, never fall through to the wrong engine
  fix="$(make_repo "repo.$tag.c4" "KICKOFF_CORE_DIR=$WORK/no-such-engine")"
  : > "$fix/.kickoff/core.lock"
  lg="$WORK/$tag.log.c4"
  printf 'exit\n' > "$SS_MODE"
  run_up "$eng" "$fix" "$lg"; rc=$?
  [ "$rc" -ne 0 ] && ok "(c4) missing pinned engine exits non-zero (rc=$rc)" || bad "(c4) missing pinned engine exited 0"
  ohas "$lg" 'missing or not executable' "(c4a) the die names the real state"
  [ ! -s "$PROBE_SS" ] && ok "(c4b) it did NOT silently start on the wrong engine" || bad "(c4b) it silently started on the wrong engine"

  # ── (d) go-autonomous.sh → one-version deprecation shim ─────────────────────
  fix="$(make_repo "repo.$tag.d")"
  lg="$WORK/$tag.log.d"
  lock="$fix/.kickoff/supervisor.lock"
  printf 'hold\n' > "$SS_MODE"
  run_shim "$eng" "$fix" "$lg"; rc=$?
  check "$rc" 0 "(d) go-autonomous.sh exits 0"
  ohas "$lg" 'DEPRECATED' "(d1) ONE deprecation line is printed (shim; removed in v0.8)"
  sshas "PERMISSION_MODE=auto" "(d2) the shim execs cmd_up with --auto (grant reaches the worker)"
  pid="$(head -n1 "$lock" 2>/dev/null | tr -dc '0-9')"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    CLEANUP_PIDS+=( "$pid|$engroot" )
    ok "(d3) the shim's start is DETACHED (--detach — a live worker survived the shim's exit)"
    kill_mine "$pid" "$engroot"; wait_dead "$pid"
  else
    bad "(d3) no live detached worker after the shim ran"
  fi

  # ── (e) the slice-3 hygiene boundary holds THROUGH --detach ──────────────────
  fix="$(make_repo "repo.$tag.e")"
  lg="$WORK/$tag.log.e"
  lock="$fix/.kickoff/supervisor.lock"
  printf 'hold\n' > "$SS_MODE"
  run_up "$eng" "$fix" "$lg" \
    _PTY_WRAPPED=1 "TELEGRAM_STATE_DIR=$LEAK_TSD" MEMORY_FOO=leak-mem SOME_UNKNOWN_JUNK=leak-junk \
    CLAUDE_CODE_OAUTH_TOKEN=tok-keep -- --auto --detach; rc=$?
  check "$rc" 0 "(e) polluted-caller --detach exits 0"
  ssmiss_name "_PTY_WRAPPED"                     "(e1) _PTY_WRAPPED does not exist in the detached worker"
  ssmiss_name "MEMORY_FOO"                       "(e2) the MEMORY_* class does not exist in the detached worker"
  ssmiss_name "SOME_UNKNOWN_JUNK"                "(e3) unknown junk does not exist in the detached worker"
  if [ -s "$PROBE_SS" ]; then
    if grep -qxF "SSENV TELEGRAM_STATE_DIR=$LEAK_TSD" "$PROBE_SS"; then
      bad "(e4) the caller's TELEGRAM_STATE_DIR leaked through --detach"
    else
      ok "(e4) the caller's TELEGRAM_STATE_DIR does not reach the detached worker"
    fi
  else
    bad "(e4) no probe — the detached start never ran"
  fi
  sshas "CLAUDE_CODE_OAUTH_TOKEN=tok-keep"       "(e5) KEEP-list auth survives through --detach"
  pid="$(head -n1 "$lock" 2>/dev/null | tr -dc '0-9')"
  [ -n "$pid" ] && CLEANUP_PIDS+=( "$pid|$engroot" ) && kill_mine "$pid" "$engroot" && wait_dead "$pid"

  # ── (f) --detach under a LIVE supervisor without --replace → die LOUD, pre-spawn ──
  # The false-success cell (adversarial find, 07-12): the spawn refuses via the
  # single-instance guard INSIDE the detached child, so the front door must never
  # read the pre-existing lock pid back as "DETACHED and live" rc=0 — the exact
  # shape the go-autonomous shim routes into when a worker is already up.
  fix="$(make_repo "repo.$tag.f")"
  lg="$WORK/$tag.log.f"
  lock="$fix/.kickoff/supervisor.lock"
  env REPO_DIR="$fix" bash "$FIXSUP" "$lock" & fpid=$!
  CLEANUP_PIDS+=( "$fpid|$WORK" )
  for _ in $(seq 1 25); do [ -s "$lock" ] && break; sleep 0.2; done
  printf 'exit\n' > "$SS_MODE"
  run_up "$eng" "$fix" "$lg" -- --auto --detach; rc=$?
  [ "$rc" -ne 0 ] && ok "(f) --detach under a live supervisor (no --replace) exits non-zero (rc=$rc)" || bad "(f) --detach under a live supervisor exited 0 (false success)"
  ohas "$lg" 'ALREADY RUNNING'      "(f1) it names the live supervisor and points at --replace"
  omiss "$lg" 'DETACHED and live'   "(f2) it never claims 'DETACHED and live' for the old pid"
  if kill -0 "$fpid" 2>/dev/null; then ok "(f3) the running supervisor was NEVER signalled (still alive)"; else bad "(f3) the running supervisor died"; fi
  [ ! -s "$PROBE_SS" ] && ok "(f4) nothing was spawned (the guard fires BEFORE the spawn)" || bad "(f4) a spawn still happened despite the live supervisor"
  kill_mine "$fpid" "$WORK"; wait_dead "$fpid"

  # ── (g) a leaked ambient KICKOFF_SUPERVISOR_LOG never hijacks the log target ─────
  # Every worker session carries KICKOFF_SUPERVISOR_LOG pointing at ITS org's live
  # log; spawning another org's worker from inside one must not redirect into (and
  # copytruncate-rotate!) the caller org's log (adversarial find, 07-12 — the old
  # go-autonomous always derived the path per-org).
  fix="$(make_repo "repo.$tag.g")"
  lg="$WORK/$tag.log.g"
  lock="$fix/.kickoff/supervisor.lock"
  suplog="$fix/.kickoff/supervisor.log"
  decoy="$WORK/$tag.decoy-other-org.log"
  printf 'decoy-org-history %0.s' $(seq 1 200) > "$decoy"   # ~3.6KB, past the 1KB cap
  decoy_sha="$(sha256sum "$decoy" | cut -d' ' -f1)"
  printf 'hold\n' > "$SS_MODE"
  run_up "$eng" "$fix" "$lg" "KICKOFF_SUPERVISOR_LOG=$decoy" LOG_MAX_BYTES=1024 -- --auto --detach; rc=$?
  check "$rc" 0 "(g) --detach with a leaked KICKOFF_SUPERVISOR_LOG exits 0"
  pid="$(head -n1 "$lock" 2>/dev/null | tr -dc '0-9')"
  [ -n "$pid" ] && CLEANUP_PIDS+=( "$pid|$engroot" )
  if grep -qF 'STUB-SUP holding' "$suplog" 2>/dev/null; then
    ok "(g1) the worker logged into ITS OWN org's supervisor.log"
  else
    bad "(g1) the worker did not log into its own supervisor.log ($suplog)"
  fi
  check "$(sha256sum "$decoy" | cut -d' ' -f1)" "$decoy_sha" "(g2) the decoy (another org's live log) is byte-unchanged"
  [ ! -f "$decoy.1" ] && ok "(g3) the decoy was never copytruncate-rotated" || bad "(g3) the decoy was rotated ($decoy.1 exists)"
  ohas "$lg" "log:  $suplog" "(g4) the printed log path is this org's own"
  [ -n "$pid" ] && kill_mine "$pid" "$engroot" && wait_dead "$pid"
  return 0
}

# ── run NEW (expect all green) ───────────────────────────────────────────────
echo "== assertions against NEW scripts/kickoff + go-autonomous.sh =="
suite new "$KI_NEW" "$GA_NEW"
NEW_PASS=$PASS; NEW_FAIL=$FAIL

# ── RED-ON-OLD: same assertions against HEAD must FAIL on (c1*) + (b1*) ──────
echo
echo "== RED-on-old: same assertions against HEAD:scripts/{kickoff,go-autonomous.sh} =="
KI_OLD="$WORK/old.kickoff"
GA_OLD="$WORK/old.go-autonomous.sh"
if git -C "$SCRIPT_DIR" show HEAD:scripts/kickoff > "$KI_OLD" 2>/dev/null \
   && git -C "$SCRIPT_DIR" show HEAD:scripts/go-autonomous.sh > "$GA_OLD" 2>/dev/null; then
  if cmp -s "$KI_NEW" "$KI_OLD"; then
    # Working-tree kickoff is byte-identical to HEAD's (the normal post-commit state):
    # there is no behavioral delta to prove RED against — N/A, not failed.
    RED_ON_OLD=skip; printf '  skip RED-on-old n/a — kickoff is byte-identical to HEAD (post-commit state)\n'
  elif slice4_markers "$KI_OLD"; then
    # HEAD already carries the slice-4 start surface: the working-tree delta is
    # start-surface-unrelated (a later slice editing the same file) — N/A.
    RED_ON_OLD=skip; printf '  skip RED-on-old n/a — HEAD already carries the slice-4 start surface (working-tree delta is unrelated)\n'
  else
    PASS=0; FAIL=0
    OLD_OUT="$WORK/old.suite.out"
    suite old "$KI_OLD" "$GA_OLD" > "$OLD_OUT" 2>&1
    OLD_FAIL=$FAIL
    # The spec-named REDs: (c1a) pin-redirect never fired and (b1b) --replace never
    # cycled must both fail on pre-slice code — a generic ">0 reds" would let either
    # regress silently.
    if [ "$OLD_FAIL" -gt 0 ] && grep -q '^  FAIL (c1a)' "$OLD_OUT" && grep -q '^  FAIL (b1b)' "$OLD_OUT"; then
      RED_ON_OLD=1
      printf '  ok   RED-on-old proven — %s assertion(s) FAIL against HEAD, incl. the spec-named (c1a) + (b1b):\n' "$OLD_FAIL"
      grep '^  FAIL' "$OLD_OUT" | sed 's/^  FAIL/         RED/'
    else
      RED_ON_OLD=0
      printf '  FAIL RED-on-old NOT proven — old-code fails=%s, and (c1a)/(b1b) must be among them:\n' "$OLD_FAIL"
      grep '^  FAIL' "$OLD_OUT" | sed 's/^/       /' || printf '       (no failures at all — the suite proves nothing)\n'
    fi
  fi
else
  RED_ON_OLD=0; printf '  FAIL could not read HEAD:scripts/{kickoff,go-autonomous.sh} to prove RED-on-old\n'
fi

echo
echo "== summary =="
printf 'NEW: pass=%s fail=%s   RED-on-old proven=%s\n' "$NEW_PASS" "$NEW_FAIL" "${RED_ON_OLD:-0}"
case "${RED_ON_OLD:-0}" in 1|skip)
  if [ "$NEW_FAIL" -eq 0 ]; then echo "SELFTEST PASS"; exit 0; fi ;;
esac
echo "SELFTEST FAIL"; exit 1
