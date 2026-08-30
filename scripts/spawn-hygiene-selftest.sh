#!/usr/bin/env bash
# spawn-hygiene-selftest.sh — hermetic proof of v0.7 G1 §2.5: engine-owned spawn-env
# hygiene — a POSITIVE KEEP-LIST applied at the org-entry boundary (cmd_up's exec of
# the supervisor), near `env -i` semantics: everything not kept simply does not exist
# in the spawned worker's world. This retires the hand-rolled caller-side SCRUB
# blacklists (~/finish-v06-restarts.sh, ~/start-*-worker.sh).
#
# THE BUG CLASS THIS GUARDS (bit live 2026-07-12): spawning another org's worker from
# inside a session inherited the caller's _PTY_WRAPPED=1 + MODEL → print-mode crash
# loop + silent 2× cost. The same class covers TELEGRAM_STATE_DIR (a spawned org
# bridging the CALLER's channel = the double-poller catastrophe), MEMORY_*,
# CHANNEL_SPEC, REGROUND_PROMPT, ANNOUNCE_COOLDOWN, and any UNKNOWN future var — a
# blacklist can never name the next leak; the keep-list makes the whole class
# structurally impossible. Spawning another org's worker from inside any session
# becomes plain `REPO_DIR=<theirs> kickoff up --auto`.
#
# What it proves, through a REAL `kickoff up` spawn chain (cmd_up → stub
# start-supervisor → session-run → claude), via a stub claude that dumps its argv +
# FULL exported env to a file:
#   (a) caller env polluted with the FULL leak list (_PTY_WRAPPED=1,
#       TELEGRAM_STATE_DIR, MEMORY_FOO, CHANNEL_SPEC, REGROUND_PROMPT,
#       ANNOUNCE_COOLDOWN, + an arbitrary unknown junk var) → the child env contains
#       NONE of them, and the spawned org derives its OWN TELEGRAM_STATE_DIR from ITS
#       instance.env (the bridge is never gagged)                    [RED on pre-slice]
#   (b) every KEEP-list var set by the caller survives into the child: PATH/HOME
#       spot-checks + CLAUDE_CODE_OAUTH_TOKEN + REPO_DIR/MODEL/EFFORT/PERMISSION_MODE
#       (+ the LC_* glob) — while a caller's KICKOFF_SUPERVISOR_LOG is DROPPED (the
#       engine derives the log path per-org; slice-4 hardening, adversarial find
#       07-12) and keeping PERMISSION_MODE opens NO ambient grant path (cmd_up's
#       argv-resolved value always wins)
#   (c) the KICKOFF_ENV_KEEP escape hatch: a named extra var survives (space or comma
#       form); unset → it does not [RED on pre-slice: everything used to pass
#       through]; PREFLIGHT_SKIP is NEVER keepable, not even by name; a glob char
#       stays LITERAL — a cwd file named like a leak-class var + KEEP='*' must not
#       resurrect that var through the boundary (adversarial-review find, 07-12)
#   (d) slice-2 integration THROUGH the new boundary: instance.env MODEL still reaches
#       the claude argv, and a pre-set env MODEL still beats the file (preset-wins)
#
# HOW IT STAYS HERMETIC (mirrors config-precedence-selftest.sh):
#   - Runs COPIES of scripts/kickoff + scripts/session-run.sh from a scratch engine
#     dir against mktemp fixture repos (REPO_DIR is always the fixture — never the
#     live repo).
#   - start-supervisor.sh is replaced by a STUB that execs the sibling session-run.sh
#     (the real start-supervisor/supervisor pair carries the launch env through the
#     process env untouched; the supervisor lifecycle is liveness-selftest territory).
#   - Every spawn starts from `env -i` with a CONTROLLED caller env, so the pollution
#     is exactly what the test plants — no live worker env can leak into the fixture,
#     and no live .kickoff state is ever touched.
#   - The stub claude writes its probe to a path BAKED IN at stub-creation time — it
#     cannot ride an env var, because dropping unknown env vars is the very behavior
#     under test. A stub `tail` (exit 0) keeps the pty wrap orphan-free (the wrap runs
#     for real via /usr/bin/script); curl is stubbed inert.
#
# RED-ON-OLD: re-runs the same assertions against HEAD's kickoff (session-run.sh stays
# the working-tree copy in both lanes, isolating cmd_up's boundary delta alone) and
# requires the spec-named checks — (a1)/(a2) leak-through + (c2) hatch-off
# pass-through — to FAIL there. A check that never went RED proves nothing
# (memory/fixture-can-mask-the-bug-it-should-catch.md). Byte-identical to HEAD (the
# normal post-commit state) or HEAD already carrying the hygiene markers (a later,
# hygiene-unrelated working-tree edit) → the lane is N/A and auto-SKIPPED, exactly
# like config-precedence-selftest.sh.
#
# Usage:  bash scripts/spawn-hygiene-selftest.sh
# Exit non-zero on any failed assertion (or if RED-on-old is not proven).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KI_NEW="$SCRIPT_DIR/kickoff"
SR_NEW="$SCRIPT_DIR/session-run.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/spawn-hygiene-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$1" = "$2" ]; then ok "$3 (=$1)"; else bad "$3 (want=$2 got=$1)"; fi; }

PROBE="$WORK/probe.out"

# Probe-anchored assertion helpers: every ABSENCE check first requires a live probe, so
# a spawn chain that never reached claude can't fake a green (fixture-can-mask lesson).
present(){ # $1=exact probe line $2=desc
  if grep -qxF "$1" "$PROBE" 2>/dev/null; then ok "$2"; else bad "$2 (missing: $1)"; fi
}
absent(){  # $1=exact probe line $2=desc
  if [ ! -s "$PROBE" ]; then bad "$2 (no probe — spawn chain never reached claude)"; return; fi
  if grep -qxF "$1" "$PROBE"; then bad "$2 (leaked through: $1)"; else ok "$2"; fi
}
absent_name(){ # $1=env var NAME $2=desc — no `CENV NAME=` line at all
  if [ ! -s "$PROBE" ]; then bad "$2 (no probe — spawn chain never reached claude)"; return; fi
  if grep -q "^CENV $1=" "$PROBE"; then bad "$2 ($(grep -m1 "^CENV $1=" "$PROBE"))"; else ok "$2"; fi
}

# ── stub dir: claude (argv + FULL-env probe), tail (no-orphan keepalive), curl ─
STUBDIR="$WORK/stubbin"
mkdir -p "$STUBDIR"

# stub claude: dump argv one token per line + EVERY exported var as `CENV NAME=VALUE`.
# The probe path is BAKED IN at creation (never env-carried): the boundary under test
# drops unknown env vars, so an env-carried probe path would vanish with the leak class.
cat > "$STUBDIR/claude" <<EOF
#!/usr/bin/env bash
{
  for a in "\$@"; do printf 'ARG %s\n' "\$a"; done
  while IFS= read -r n; do printf 'CENV %s=%s\n' "\$n" "\${!n}"; done < <(compgen -e)
} > "$PROBE"
exit 0
EOF
chmod +x "$STUBDIR/claude"
# stub tail: the wrap line's `< <(tail -f /dev/null)` keepalive must not outlive the
# test (no supervisor group-kill here) — same rationale as config-precedence-selftest.
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBDIR/tail"
# stub curl: inert belt — the announce path must never reach a network.
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBDIR/curl"
chmod +x "$STUBDIR"/*

# stub start-supervisor.sh: env-passthrough exec of the sibling session-run.sh (the
# real pair passes the launch env through untouched — config-precedence's shape).
STUB_SS="$WORK/stub-start-supervisor.sh"
cat > "$STUB_SS" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
exec bash "$HERE/session-run.sh"
EOF
chmod +x "$STUB_SS"

REALPATH_DIRS="/usr/bin:/bin"   # the real script(1), jq, coreutils

# ── fixture factories (config-precedence-selftest.sh's shape) ────────────────
make_engine() {  # $1=tag $2=kickoff-copy $3=session-run-copy ; prints the engine scripts dir
  local eng="$WORK/engine.$1"
  rm -rf "$eng"; mkdir -p "$eng/scripts"
  cp "$2" "$eng/scripts/kickoff"
  cp "$3" "$eng/scripts/session-run.sh"
  cp "$STUB_SS" "$eng/scripts/start-supervisor.sh"
  printf '%s' "$eng/scripts"
}

make_repo() {  # $1=name, rest = extra instance.env lines ; prints the fixture repo path
  # Each fixture declares its OWN channel dir ($fix/.kickoff/chan), so the suite can
  # prove the spawned org derives ITS OWN TELEGRAM_STATE_DIR — never the caller's.
  local fix="$WORK/$1"; shift
  mkdir -p "$fix/.kickoff"
  {
    printf 'TELEGRAM_STATE_DIR=%s\n' "$fix/.kickoff/chan"
    local l; for l in "$@"; do printf '%s\n' "$l"; done
  } > "$fix/.kickoff/instance.env"
  printf '%s' "$fix"
}

# run_up ENGINE REPO LOG [K=V ...] [-- <kickoff up args...>] — a CONTROLLED caller env:
# env -i wipes the test's own env first, then the K=V operands plant exactly the
# pollution / keeps each check needs. The probe lands at the baked-in $PROBE.
run_up() {
  local eng="$1" fix="$2" lg="$3"; shift 3
  local -a extra_env=() args=()
  local in_args=0 x
  for x in "$@"; do
    if [ "$x" = "--" ]; then in_args=1; continue; fi
    if [ "$in_args" = 1 ]; then args+=("$x"); else extra_env+=("$x"); fi
  done
  rm -f "$PROBE"
  timeout 25 env -i PATH="$STUBDIR:$REALPATH_DIRS" HOME="$WORK/home" TERM=dumb \
    REPO_DIR="$fix" "${extra_env[@]}" \
    bash "$eng/kickoff" up "${args[@]}" </dev/null >"$lg" 2>&1
}

flag_val() {  # $1=flag → the argv token following the flag in $PROBE, or __absent__
  awk -v f="$1" '
    sub(/^ARG /, "") { if (prev == f) { print; found = 1; exit }; prev = $0 }
    END { if (!found) print "__absent__" }
  ' "$PROBE" 2>/dev/null || echo "__no-probe__"
}

# Does this kickoff copy already carry the slice-3 hygiene boundary (build_worker_env +
# the KEEP-list)? When HEAD's copy does, a byte-different working tree is a hygiene-
# UNRELATED later edit — no pre-slice baseline is left to prove RED against (the
# committed-at-HEAD self-skip discipline, same shape as config-precedence-selftest.sh).
slice3_markers() {  # $1=kickoff
  grep -q '^_WORKER_ENV_KEEP=' "$1" 2>/dev/null || return 1
  grep -q 'build_worker_env'   "$1" 2>/dev/null || return 1
  return 0
}

# The FULL leak list (v0.7 G1 §2.5 + the 07-12 incident class). Values are unique
# sentinels so every assertion is value-anchored — a same-name var legitimately set by
# the chain itself (e.g. the fixture's own TELEGRAM_STATE_DIR) can never mask a leak.
LEAK_TSD="$WORK/LEAKED-caller-chan"   # never created; bridge-reap fails toward not killing
LEAK_ENV=(
  "_PTY_WRAPPED=1"
  "TELEGRAM_STATE_DIR=$LEAK_TSD"
  "MEMORY_FOO=leak-mem"
  "CHANNEL_SPEC=leak-chanspec"
  "REGROUND_PROMPT=leak-prompt"
  "ANNOUNCE_COOLDOWN=7777"
  "SOME_UNKNOWN_JUNK=leak-junk"
)

# ── the assertion suite (NEW = expect all-green; OLD = expect the named reds) ─
# $1 = tag (new|old), $2 = kickoff copy. session-run.sh is ALWAYS the working-tree
# copy in both lanes, so the old lane isolates cmd_up's org-entry boundary delta alone.
suite() {
  local tag="$1" kick="$2"
  local eng fix lg rc

  eng="$(make_engine "$tag" "$kick" "$SR_NEW")"

  bash -n "$eng/kickoff" 2>/dev/null        && ok "($tag) kickoff parses (bash -n)"     || bad "($tag) kickoff fails bash -n"
  bash -n "$eng/session-run.sh" 2>/dev/null && ok "($tag) session-run parses (bash -n)" || bad "($tag) session-run fails bash -n"

  # (a) the FULL leak list in the caller env → the child contains NONE of it
  fix="$(make_repo "repo.$tag.a")"
  lg="$WORK/$tag.log.a"
  run_up "$eng" "$fix" "$lg" "${LEAK_ENV[@]}"; rc=$?
  check "$rc" 0 "(a) kickoff up exits 0 under full caller pollution"
  absent_name "_PTY_WRAPPED"                           "(a1) _PTY_WRAPPED does not exist in the child env"
  absent "CENV TELEGRAM_STATE_DIR=$LEAK_TSD"           "(a2) the caller's TELEGRAM_STATE_DIR does not reach the child"
  present "CENV TELEGRAM_STATE_DIR=$fix/.kickoff/chan" "(a3) the spawned org derives its OWN TELEGRAM_STATE_DIR from ITS instance.env (bridge not gagged)"
  absent_name "MEMORY_FOO"                             "(a4) the MEMORY_* class does not exist in the child env"
  absent "CENV CHANNEL_SPEC=leak-chanspec"             "(a5) the caller's CHANNEL_SPEC does not reach the child"
  absent "CENV REGROUND_PROMPT=leak-prompt"            "(a6) the caller's REGROUND_PROMPT does not reach the child"
  if [ -s "$PROBE" ]; then
    if [ "$(flag_val --append-system-prompt)" = "leak-prompt" ]; then
      bad "(a6') claude argv still carries the leaked re-ground prompt"
    else
      ok "(a6') claude argv re-ground prompt is the engine's own, not the leaked one"
    fi
  else
    bad "(a6') no probe — spawn chain never reached claude"
  fi
  absent_name "ANNOUNCE_COOLDOWN"                      "(a7) ANNOUNCE_COOLDOWN does not exist in the child env"
  absent_name "SOME_UNKNOWN_JUNK"                      "(a8) an arbitrary unknown junk var does not exist in the child env"

  # (b) every KEEP-list var set by the caller survives into the child
  fix="$(make_repo "repo.$tag.b")"
  lg="$WORK/$tag.log.b"
  run_up "$eng" "$fix" "$lg" \
    CLAUDE_CODE_OAUTH_TOKEN=tok-keep MODEL=modelx-env EFFORT=xhigh LC_ALL=C \
    KICKOFF_SUPERVISOR_LOG="$WORK/LEAKED-caller-org.log" -- --auto
  rc=$?
  check "$rc" 0 "(b) kickoff up exits 0"
  if grep -q "^CENV PATH=$STUBDIR:" "$PROBE" 2>/dev/null; then
    ok "(b1) PATH survives into the child"
  else
    bad "(b1) PATH did not survive into the child"
  fi
  present "CENV HOME=$WORK/home"                      "(b2) HOME survives"
  present "CENV CLAUDE_CODE_OAUTH_TOKEN=tok-keep"     "(b3) CLAUDE_CODE_OAUTH_TOKEN survives (auth intact)"
  present "CENV REPO_DIR=$fix"                        "(b4) REPO_DIR survives (the org identity)"
  present "CENV MODEL=modelx-env"                     "(b5) MODEL survives"
  check "$(flag_val --model)" "modelx-env"            "(b5') MODEL reaches the claude argv"
  present "CENV EFFORT=xhigh"                         "(b6) EFFORT survives"
  check "$(flag_val --effort)" "xhigh"                "(b6') EFFORT reaches the claude argv"
  present "CENV PERMISSION_MODE=auto"                 "(b7) PERMISSION_MODE (argv --auto) survives"
  check "$(flag_val --permission-mode)" "auto"        "(b7') the grant reaches the claude argv"
  present "CENV LC_ALL=C"                             "(b8) the LC_* glob family survives"
  # (b9) KICKOFF_SUPERVISOR_LOG is NOT keepable (slice-4 hardening, adversarial find
  # 07-12): a worker session always carries the CALLER org's value — keeping it let a
  # cross-org spawn redirect + copytruncate the caller org's live log. The engine owns
  # the path (cmd_up derives it per-org); the ambient value must never reach the child.
  absent "CENV KICKOFF_SUPERVISOR_LOG=$WORK/LEAKED-caller-org.log" "(b9) a leaked caller-org KICKOFF_SUPERVISOR_LOG does NOT reach the child"

  # (b10) keeping PERMISSION_MODE on the KEEP-list opens NO ambient grant path: cmd_up's
  # argv-resolved value is applied AFTER the kept pairs on the env command line, so it
  # always wins (slice-2 invariant: the grant is argv / at-the-terminal only).
  fix="$(make_repo "repo.$tag.b10")"
  lg="$WORK/$tag.log.b10"
  run_up "$eng" "$fix" "$lg" PERMISSION_MODE=auto
  check "$(flag_val --permission-mode)" "default" "(b10) ambient PERMISSION_MODE=auto cannot arm the worker through \`up\`"

  # (c) the KICKOFF_ENV_KEEP escape hatch
  fix="$(make_repo "repo.$tag.c1")"
  lg="$WORK/$tag.log.c1"
  run_up "$eng" "$fix" "$lg" ODD_BOX_VAR=keepme KICKOFF_ENV_KEEP=ODD_BOX_VAR
  present "CENV ODD_BOX_VAR=keepme" "(c1) KICKOFF_ENV_KEEP names an extra var → it survives"

  fix="$(make_repo "repo.$tag.c2")"
  lg="$WORK/$tag.log.c2"
  run_up "$eng" "$fix" "$lg" ODD_BOX_VAR=keepme
  absent_name "ODD_BOX_VAR" "(c2) KICKOFF_ENV_KEEP unset → the same var does NOT survive"

  fix="$(make_repo "repo.$tag.c3")"
  lg="$WORK/$tag.log.c3"
  run_up "$eng" "$fix" "$lg" ODD_BOX_VAR=keepme PREFLIGHT_SKIP=1 "KICKOFF_ENV_KEEP=PREFLIGHT_SKIP,ODD_BOX_VAR"
  present "CENV ODD_BOX_VAR=keepme" "(c3) the comma-separated KICKOFF_ENV_KEEP form works"
  absent_name "PREFLIGHT_SKIP"      "(c3') PREFLIGHT_SKIP is NEVER keepable — not even named in KICKOFF_ENV_KEEP"

  # (c4) glob chars in the hatch stay LITERAL — pathname expansion must never run on
  # KICKOFF_ENV_KEEP. The pre-fix unquoted split glob-expanded against the CALLER's
  # cwd: a cwd file named like a leak-class var + KICKOFF_ENV_KEEP='*' matched that
  # filename into the keep-list and resurrected the caller's value through the
  # boundary (adversarial-review find, 07-12). The dir also plants ODD_BOX_VAR so the
  # literal-'*' semantics are pinned: a glob is a malformed NAME that keeps NOTHING —
  # never "everything the cwd happens to contain".
  fix="$(make_repo "repo.$tag.c4")"
  lg="$WORK/$tag.log.c4"
  local globcwd="$WORK/$tag.globcwd"
  mkdir -p "$globcwd"; touch "$globcwd/TELEGRAM_STATE_DIR" "$globcwd/ODD_BOX_VAR"
  rm -f "$PROBE"
  ( cd "$globcwd" && timeout 25 env -i PATH="$STUBDIR:$REALPATH_DIRS" HOME="$WORK/home" TERM=dumb \
      REPO_DIR="$fix" "TELEGRAM_STATE_DIR=$LEAK_TSD" ODD_BOX_VAR=keepme 'KICKOFF_ENV_KEEP=*' \
      bash "$eng/kickoff" up </dev/null >"$lg" 2>&1 )
  rc=$?
  check "$rc" 0 "(c4) kickoff up exits 0 with KICKOFF_ENV_KEEP='*' from a glob-matching cwd"
  absent "CENV TELEGRAM_STATE_DIR=$LEAK_TSD"           "(c4') a cwd file + KEEP='*' cannot resurrect the caller's TELEGRAM_STATE_DIR"
  present "CENV TELEGRAM_STATE_DIR=$fix/.kickoff/chan" "(c4'') the spawned org still derives its OWN channel dir"
  absent_name "ODD_BOX_VAR"                            "(c4''') the '*' stays literal — it keeps nothing, not the cwd's file names"

  # (d) slice-2 integration THROUGH the new boundary (config-precedence stays intact)
  fix="$(make_repo "repo.$tag.d1" "MODEL=modelx-file")"
  lg="$WORK/$tag.log.d1"
  run_up "$eng" "$fix" "$lg"
  check "$(flag_val --model)" "modelx-file" "(d1) instance.env MODEL still reaches the claude argv through the boundary"

  fix="$(make_repo "repo.$tag.d2" "MODEL=modelx-file")"
  lg="$WORK/$tag.log.d2"
  run_up "$eng" "$fix" "$lg" MODEL=modelx-env
  check "$(flag_val --model)" "modelx-env" "(d2) pre-set env MODEL still beats the file (preset-wins through the boundary)"
}

# ── run NEW (expect all green) ───────────────────────────────────────────────
echo "== assertions against NEW scripts/kickoff (session-run.sh = working tree) =="
suite new "$KI_NEW"
NEW_PASS=$PASS; NEW_FAIL=$FAIL

# ── RED-ON-OLD: same assertions against HEAD's kickoff must FAIL on (a1)/(a2)/(c2) ─
echo
echo "== RED-on-old: same assertions against HEAD:scripts/kickoff =="
KI_OLD="$WORK/old.kickoff"
if git -C "$SCRIPT_DIR" show HEAD:scripts/kickoff > "$KI_OLD" 2>/dev/null; then
  if cmp -s "$KI_NEW" "$KI_OLD"; then
    # Working-tree kickoff is byte-identical to HEAD's (the normal post-commit state):
    # there is no behavioral delta to prove RED against — N/A, not failed.
    RED_ON_OLD=skip; printf '  skip RED-on-old n/a — kickoff is byte-identical to HEAD (post-commit state)\n'
  elif slice3_markers "$KI_OLD"; then
    # HEAD already carries the hygiene boundary: the working-tree delta is hygiene-
    # unrelated (a later slice editing the same file) — N/A.
    RED_ON_OLD=skip; printf '  skip RED-on-old n/a — HEAD already carries the spawn-hygiene boundary (working-tree delta is hygiene-unrelated)\n'
  else
    PASS=0; FAIL=0
    OLD_OUT="$WORK/old.suite.out"
    suite old "$KI_OLD" > "$OLD_OUT" 2>&1
    OLD_FAIL=$FAIL
    # The spec-named REDs: (a1) _PTY_WRAPPED leak, (a2) TELEGRAM_STATE_DIR leak, and
    # (c2) hatch-off pass-through must all fail on pre-slice code — a generic ">0 reds"
    # would let any one of them regress silently.
    if [ "$OLD_FAIL" -gt 0 ] && grep -q '^  FAIL (a1)' "$OLD_OUT" && grep -q '^  FAIL (a2)' "$OLD_OUT" && grep -q '^  FAIL (c2)' "$OLD_OUT"; then
      RED_ON_OLD=1
      printf '  ok   RED-on-old proven — %s assertion(s) FAIL against HEAD, incl. the spec-named (a1) + (a2) + (c2):\n' "$OLD_FAIL"
      grep '^  FAIL' "$OLD_OUT" | sed 's/^  FAIL/         RED/'
    else
      RED_ON_OLD=0
      printf '  FAIL RED-on-old NOT proven — old-code fails=%s, and (a1)/(a2)/(c2) must be among them:\n' "$OLD_FAIL"
      grep '^  FAIL' "$OLD_OUT" | sed 's/^/       /' || printf '       (no failures at all — the suite proves nothing)\n'
    fi
  fi
else
  RED_ON_OLD=0; printf '  FAIL could not read HEAD:scripts/kickoff to prove RED-on-old\n'
fi

echo
echo "== summary =="
printf 'NEW: pass=%s fail=%s   RED-on-old proven=%s\n' "$NEW_PASS" "$NEW_FAIL" "${RED_ON_OLD:-0}"
case "${RED_ON_OLD:-0}" in 1|skip)
  if [ "$NEW_FAIL" -eq 0 ]; then echo "SELFTEST PASS"; exit 0; fi ;;
esac
echo "SELFTEST FAIL"; exit 1
