#!/usr/bin/env bash
# ptywrap-selftest.sh — hermetic proof of session-run.sh's pty-wrap decision (v0.7 G1 §2.4):
# the wrap is decided by the REAL thing — `[ -t 0 ]` — NEVER by an inheritable env var,
# plus the fail-loud loop guard when script(1) is broken or missing.
#
# THE BUG THIS GUARDS (bit live 2026-07-12): a `_PTY_WRAPPED=1` leaked from a parent
# worker's env made a child spawn SKIP its pty wrap → claude got a non-TTY stdin →
# print-mode crash loop + silent double cost. The fix wraps iff stdin is not a tty;
# inside script(1) stdin IS a pty, so the inner pass skips naturally with no env trust.
#
# HOW IT STAYS HERMETIC:
#   - Runs a COPY of scripts/session-run.sh from a scratch dir against a mktemp fixture
#     repo (REPO_DIR is always the fixture — never ambient, never the live repo).
#   - Every invocation is env-scrubbed (`env -i`): no ambient REPO_DIR/_PTY_WRAPPED/
#     MODEL/... can leak in, and no live .kickoff state is ever touched.
#   - A stub `claude` on PATH records whether ITS stdin is a tty + the argv, then exits 0
#     — no real claude, no supervisor, no network (curl is stubbed inert as a belt).
#   - A stub `tail` (exit 0) stands in for the keepalive so a completed run leaves NO
#     orphan `tail -f /dev/null` (the real keepalive is only reaped by a supervisor's
#     group-kill, which this test must never perform).
#   - The "broken script(1)" case uses a PATH shim that FORKS the -c command without a
#     pty (exactly the failure shape of a real script(1) that can't deliver one); the
#     "missing script(1)" case uses a minimal symlink-farm PATH with no `script` at all.
#     Every run is `timeout`-bounded, so a regression to infinite re-wrap fails fast.
#
# RED-ON-OLD: it re-runs the same assertions against HEAD's session-run.sh and requires
# at least one to FAIL there — a test that passes on pre-fix code proves nothing
# (memory/fixture-can-mask-the-bug-it-should-catch.md). When the working-tree file is
# byte-identical to HEAD's (the normal post-commit state) the proof is N/A and
# auto-SKIPPED, exactly like supervisor-liveness-selftest.sh.
#
# Usage:  bash scripts/ptywrap-selftest.sh
# Exit non-zero on any failed assertion (or if RED-on-old is not proven).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SR_NEW="$SCRIPT_DIR/session-run.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ptywrap-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$1" = "$2" ]; then ok "$3 (=$1)"; else bad "$3 (want=$2 got=$1)"; fi; }

# ── stub dir: claude (tty probe), tail (no-orphan keepalive), curl (inert) ───
STUBDIR="$WORK/stubbin"
mkdir -p "$STUBDIR"

# stub claude: record whether ITS stdin is a tty + the argv, then exit 0.
cat > "$STUBDIR/claude" <<'EOF'
#!/usr/bin/env bash
out="${CLAUDE_PROBE_FILE:-}"
[ -n "$out" ] || exit 0
{
  if [ -t 0 ]; then echo "tty"; else echo "notty"; fi
  printf 'argv: %s\n' "$*"
} > "$out"
exit 0
EOF

# stub tail: the wrap line's `< <(tail -f /dev/null)` keepalive must not outlive the
# test (no supervisor group-kill here). script(1) runs its -c child to completion even
# after stdin EOFs (verified), so an instant-exit stand-in is safe AND orphan-free.
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBDIR/tail"
# stub curl: inert belt — the announce path must never reach a network.
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBDIR/curl"
chmod +x "$STUBDIR"/*

# ── script(1) shim: records each invocation, then FORKS the -c command WITHOUT a pty ─
# Doubles as (b)'s double-wrap detector (count must stay 0 under a real pty) and (c)'s
# broken-script(1): it forks like the real one (so the inner pass's PPID == the wrapping
# PID) but never allocates a pty — the exact shape the loop guard must catch.
SHIMDIR="$WORK/shimbin"
mkdir -p "$SHIMDIR"
cat > "$SHIMDIR/script" <<'EOF'
#!/usr/bin/env bash
[ -n "${SHIM_COUNT_FILE:-}" ] && echo hit >> "$SHIM_COUNT_FILE"
cmd=""
while [ $# -gt 0 ]; do case "$1" in -c) cmd="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "$cmd" ] || exit 2
bash -c "$cmd"
exit $?
EOF
chmod +x "$SHIMDIR/script"

# ── symlink farm: a minimal PATH with NO `script` at all (case d) ────────────
FARM="$WORK/farm"
mkdir -p "$FARM"
# dirname: the pre-pty path resolves core scripts absolutely (e462090, the
# pull-adopter sibling-resolution lesson) — without it the wrapper dies at 186 on an
# unrelated axis and the (d) check reds for the wrong reason (found live 2026-08-29).
for b in bash mkdir date cat dirname; do
  p="$(command -v "$b" 2>/dev/null)" && ln -s "$p" "$FARM/$b"
done
cp -p "$STUBDIR/claude" "$STUBDIR/tail" "$STUBDIR/curl" "$FARM/"

REALPATH_DIRS="/usr/bin:/bin"   # the real script(1), jq, coreutils

# ── fixture repo factory (per suite run, so new/old never share .kickoff state) ─
make_fixture() {  # $1 = name; prints the fixture repo path
  local fix="$WORK/$1"
  mkdir -p "$fix/.kickoff"
  printf 'TELEGRAM_STATE_DIR=%s\n' "$WORK/chan" > "$fix/.kickoff/instance.env"
  printf '%s\n' "$fix"
}

# ── the assertion suite (run against NEW = expect all-green; OLD = expect reds) ─
# $1 = tag (new|old), $2 = the session-run.sh copy under test
suite() {
  local tag="$1" target="$2"
  local fix probe lg shimcnt rc
  fix="$(make_fixture "repo.$tag")"

  bash -n "$target" 2>/dev/null && ok "($tag) target parses (bash -n)" || bad "($tag) target fails bash -n"

  # (s) static invariant: the wrap decision tests the tty, not an inheritable env var
  grep -q '\[ ! -t 0 \]' "$target" \
    && ok "(s) wrap decision is a real TTY test ([ ! -t 0 ])" \
    || bad "(s) no [ ! -t 0 ] wrap decision found"
  # the CODE form (`${_PTY_WRAPPED…}` expansion) — comments may name the old var as history
  if grep -q '\${_PTY_WRAPPED' "$target"; then
    bad "(s) inheritable-env trust (\${_PTY_WRAPPED} expansion) still present in code"
  else
    ok "(s) no inheritable-env trust (\${_PTY_WRAPPED} expansion) remains in code"
  fi

  # (a) LEAKED-FLAG: _PTY_WRAPPED=1 in env + NON-tty stdin → must STILL wrap; claude
  #     must see a tty. (The 2026-07-12 crash-loop shape: old code trusts the flag,
  #     skips the wrap, and hands claude the non-TTY stdin.)
  probe="$WORK/$tag.probe.a"; lg="$WORK/$tag.log.a"; rm -f "$probe"
  timeout 20 env -i PATH="$STUBDIR:$REALPATH_DIRS" HOME="$WORK/home" TERM=dumb \
    REPO_DIR="$fix" CLAUDE_PROBE_FILE="$probe" _PTY_WRAPPED=1 \
    bash "$target" </dev/null >"$lg" 2>&1
  rc=$?
  check "$rc" 0 "(a) leaked flag + non-tty stdin -> wrapper exits 0"
  check "$(head -n1 "$probe" 2>/dev/null || echo no-probe)" "tty" "(a) claude exec'd WITH a tty despite the leaked flag"
  grep -q -- '--channels' "$probe" 2>/dev/null \
    && ok "(a) exec reached claude with the real argv (--channels)" \
    || bad "(a) claude argv missing from the probe"
  grep -q 'pty-wrap: re-exec' "$lg" \
    && ok "(a) the wrap actually occurred (pty-wrap log line)" \
    || bad "(a) no pty-wrap log line — the wrap was skipped"

  # (b) INNER-PASS: stdin IS a real pty (the test provides one via the REAL script(1))
  #     → no double-wrap: the PATH-first script shim must record ZERO invocations and
  #     claude must inherit the pty.
  probe="$WORK/$tag.probe.b"; lg="$WORK/$tag.log.b"; rm -f "$probe"
  shimcnt="$WORK/$tag.shimcnt.b"; : > "$shimcnt"
  timeout 20 env -i PATH="$SHIMDIR:$STUBDIR:$REALPATH_DIRS" HOME="$WORK/home" TERM=dumb \
    REPO_DIR="$fix" CLAUDE_PROBE_FILE="$probe" SHIM_COUNT_FILE="$shimcnt" \
    /usr/bin/script -qfe -c "bash '$target'" /dev/null </dev/null >"$lg" 2>&1
  rc=$?
  check "$rc" 0 "(b) pty stdin -> wrapper exits 0"
  check "$(grep -c . "$shimcnt")" 0 "(b) pty stdin -> NO re-wrap (script(1) never invoked)"
  check "$(head -n1 "$probe" 2>/dev/null || echo no-probe)" "tty" "(b) claude inherits the pty directly"

  # (c) BROKEN-WRAP: script(1) present but delivers NO pty (the forking shim) → the
  #     loop guard must fail LOUD (exit 1), never re-wrap infinitely, never exec claude.
  probe="$WORK/$tag.probe.c"; lg="$WORK/$tag.log.c"; rm -f "$probe"
  shimcnt="$WORK/$tag.shimcnt.c"; : > "$shimcnt"
  timeout 15 env -i PATH="$SHIMDIR:$STUBDIR:$REALPATH_DIRS" HOME="$WORK/home" TERM=dumb \
    REPO_DIR="$fix" CLAUDE_PROBE_FILE="$probe" SHIM_COUNT_FILE="$shimcnt" \
    bash "$target" </dev/null >"$lg" 2>&1
  rc=$?
  check "$rc" 1 "(c) broken script(1) -> loud exit 1 (124 would mean an infinite re-wrap loop)"
  grep -q 'STILL not a TTY' "$lg" \
    && ok "(c) the loop guard names the failure (FATAL: … STILL not a TTY)" \
    || bad "(c) no fail-loud FATAL line"
  check "$([ -f "$probe" ] && echo execd || echo not-execd)" "not-execd" "(c) claude NEVER exec'd on a non-TTY stdin"
  check "$(grep -c . "$shimcnt")" 1 "(c) wrapped exactly ONCE (no re-wrap loop)"

  # (d) MISSING-WRAP: no script(1) on PATH at all → fail LOUD (exit 1) before any exec.
  probe="$WORK/$tag.probe.d"; lg="$WORK/$tag.log.d"; rm -f "$probe"
  timeout 15 env -i PATH="$FARM" HOME="$WORK/home" TERM=dumb \
    REPO_DIR="$fix" CLAUDE_PROBE_FILE="$probe" \
    bash "$target" </dev/null >"$lg" 2>&1
  rc=$?
  check "$rc" 1 "(d) script(1) missing -> loud exit 1"
  grep -q 'script(1) is missing' "$lg" \
    && ok "(d) the guard names the missing dependency" \
    || bad "(d) no missing-script(1) FATAL line"
  check "$([ -f "$probe" ] && echo execd || echo not-execd)" "not-execd" "(d) claude never exec'd without a pty"
}

# ── run NEW (expect all green) ───────────────────────────────────────────────
echo "== assertions against NEW scripts/session-run.sh =="
cp -p "$SR_NEW" "$WORK/sr.new.sh"    # a copy in a bare dir: bridge-reap.sh absent → no-op stub
suite new "$WORK/sr.new.sh"
NEW_PASS=$PASS; NEW_FAIL=$FAIL

# ── RED-ON-OLD: same assertions against HEAD's session-run.sh must FAIL ──────
echo
echo "== RED-on-old: same assertions against HEAD:scripts/session-run.sh =="
OLD_SRC="$WORK/sr.old.sh"
if git -C "$SCRIPT_DIR" show HEAD:scripts/session-run.sh > "$OLD_SRC" 2>/dev/null; then
  if cmp -s "$WORK/sr.new.sh" "$OLD_SRC"; then
    # Working-tree file is byte-identical to HEAD's (the normal post-commit state):
    # there is no behavioral delta to prove RED against — the proof is N/A, not failed.
    RED_ON_OLD=skip; printf '  skip RED-on-old n/a — session-run.sh is byte-identical to HEAD (post-commit state; nothing new to prove)\n'
  elif grep -q '\[ ! -t 0 \]' "$OLD_SRC" && ! grep -q '\${_PTY_WRAPPED' "$OLD_SRC"; then
    # HEAD ALREADY carries the TTY-decide fix (the suite's own (s) markers hold on it), so a
    # byte-different working tree is a pty-UNRELATED later edit to session-run.sh (e.g. the
    # v0.7 §2.3 importer unification) — there is no pre-fix baseline left to prove RED
    # against. N/A like the byte-identical skip (bridge-reap-selftest's committed-at-HEAD
    # self-skip discipline). A working tree that REGRESSES the fix is still caught: the
    # NEW-lane (s)/(a) assertions fail regardless of this lane.
    RED_ON_OLD=skip; printf '  skip RED-on-old n/a — HEAD already carries the TTY-decide fix (working-tree delta is pty-unrelated)\n'
  else
    PASS=0; FAIL=0
    suite old "$OLD_SRC" >/dev/null 2>&1
    OLD_FAIL=$FAIL
    if [ "$OLD_FAIL" -gt 0 ]; then
      RED_ON_OLD=1; printf '  ok   RED-on-old proven — %s assertion(s) FAIL against HEAD (behavior is genuinely new)\n' "$OLD_FAIL"
    else
      RED_ON_OLD=0; printf '  FAIL RED-on-old NOT proven — the suite passed on OLD code (it proves nothing)\n'
    fi
  fi
else
  RED_ON_OLD=0; printf '  FAIL could not read HEAD:scripts/session-run.sh to prove RED-on-old\n'
fi

echo
echo "== summary =="
printf 'NEW: pass=%s fail=%s   RED-on-old proven=%s\n' "$NEW_PASS" "$NEW_FAIL" "${RED_ON_OLD:-0}"
case "${RED_ON_OLD:-0}" in 1|skip)
  if [ "$NEW_FAIL" -eq 0 ]; then echo "SELFTEST PASS"; exit 0; fi ;;
esac
echo "SELFTEST FAIL"; exit 1
