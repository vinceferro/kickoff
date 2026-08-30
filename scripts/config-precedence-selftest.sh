#!/usr/bin/env bash
# config-precedence-selftest.sh — hermetic proof of the v0.7 G1 §2.3 config-precedence rule,
# enforced identically at every seam:
#
#     argv  >  pre-set env  >  instance.env  >  engine default
#     — and PERMISSION_MODE never comes from a file at all.
#
# What it proves, through a REAL `kickoff up` spawn chain (cmd_up → start-supervisor →
# session-run → claude argv), via a stub claude that dumps its argv+env to a file:
#   (a) instance.env MODEL=<x> reaches the claude argv as `--model <x>`      [RED on pre-slice]
#   (b) a pre-set env MODEL beats the instance.env value (preset-wins)
#   (c) a plain `PERMISSION_MODE=auto` line in instance.env does NOT change the spawned
#       permission mode — argv stays `--permission-mode default`             [RED on pre-slice:
#       the old session-run importer let the gitignored file BEAT cmd_up's env and arm autonomy]
#   (d) `kickoff up --auto` is GRANT-ONLY: --permission-mode auto flows, but the effort is
#       NOT stomped to the operator-banned `max` (engine default `high`)     [RED on pre-slice]
#   (e) unset MODEL everywhere → NO --model flag appended (inherit the box config — the
#       "unset MODEL must never downgrade" contract)
#   (f) EFFORT resolves the same rule: file beats engine default; `--effort` argv beats env
#       [RED: no such flag pre-slice]; pre-set env beats a plain file line   [RED on pre-slice]
#   (g) the go-autonomous.sh seam obeys the SAME rule (its own RED-on-old lane below): the
#       instance.env MODEL pin reaches the claude argv through its detached spawn — a
#       set-but-EMPTY MODEL in its launch env used to read as "preset" downstream and BLOCK
#       the pin — and effort is no longer stomped to the operator-banned `max` [RED on old]
#   (s) preflight.sh's whitelist copy gains MODEL, drops PERMISSION_MODE, and PRESERVES its
#       deliberate REPO_DIR exclusion (the three copies are NOT synced identical)
#
# HOW IT STAYS HERMETIC (mirrors ptywrap-selftest.sh):
#   - Runs COPIES of scripts/kickoff + scripts/session-run.sh from a scratch engine dir
#     against mktemp fixture repos (REPO_DIR is always the fixture — never the live repo).
#   - start-supervisor.sh is replaced by a STUB that execs the sibling session-run.sh —
#     the real start-supervisor/supervisor pair passes MODEL/EFFORT/PERMISSION_MODE through
#     the process env untouched (neither script reads or writes them), so the stub preserves
#     exactly the contract under test while skipping the supervisor lifecycle (out of scope).
#   - Every spawn is env-scrubbed (`env -i`): no ambient MODEL/EFFORT/PERMISSION_MODE/
#     REPO_DIR/TELEGRAM_STATE_DIR can leak in, and no live .kickoff state is ever touched.
#   - A stub `claude` on PATH dumps its argv (one token per line) + the launch env, then
#     exits 0 — no real claude, no supervisor, no network (curl is stubbed inert).
#   - A stub `tail` (exit 0) stands in for the keepalive so no orphan `tail -f` survives
#     (the pty wrap runs for real via /usr/bin/script — same shape ptywrap-selftest proves).
#
# RED-ON-OLD: it re-runs the same assertions against HEAD's kickoff/session-run.sh/preflight.sh
# and requires the spec-named checks — (c) and (d) — to FAIL there, plus at least one more.
# A check that never went RED proves nothing (memory/fixture-can-mask-the-bug-it-should-catch.md).
# When all three working-tree files are byte-identical to HEAD's (the normal post-commit state)
# the proof is N/A and auto-SKIPPED, exactly like ptywrap-selftest.sh.
#
# Usage:  bash scripts/config-precedence-selftest.sh
# Exit non-zero on any failed assertion (or if RED-on-old is not proven).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KI_NEW="$SCRIPT_DIR/kickoff"
SR_NEW="$SCRIPT_DIR/session-run.sh"
PF_NEW="$SCRIPT_DIR/preflight.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/config-precedence-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home" "$WORK/chan"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$1" = "$2" ]; then ok "$3 (=$1)"; else bad "$3 (want=$2 got=$1)"; fi; }

# ── stub dir: claude (argv+env probe), tail (no-orphan keepalive), curl (inert) ─
STUBDIR="$WORK/stubbin"
mkdir -p "$STUBDIR"

# stub claude: dump argv one token per line + the launch env vars under test, exit 0.
cat > "$STUBDIR/claude" <<'EOF'
#!/usr/bin/env bash
out="${CLAUDE_PROBE_FILE:-}"
[ -n "$out" ] || exit 0
{
  for a in "$@"; do printf 'ARG %s\n' "$a"; done
  printf 'ENV MODEL=%s\n' "${MODEL-__unset__}"
  printf 'ENV EFFORT=%s\n' "${EFFORT-__unset__}"
  printf 'ENV PERMISSION_MODE=%s\n' "${PERMISSION_MODE-__unset__}"
  printf 'ENV AUTO_PICKUP=%s\n' "${AUTO_PICKUP-__unset__}"
} > "$out"
exit 0
EOF
# stub tail: the wrap line's `< <(tail -f /dev/null)` keepalive must not outlive the test
# (no supervisor group-kill here) — same rationale as ptywrap-selftest.sh.
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBDIR/tail"
# stub curl: inert belt — the announce path must never reach a network.
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBDIR/curl"
chmod +x "$STUBDIR"/*

# stub start-supervisor.sh: env-passthrough exec of the sibling session-run.sh (the real
# start-supervisor→supervisor pair carries MODEL/EFFORT/PERMISSION_MODE through the process
# env untouched; the supervisor lifecycle itself is ptywrap/liveness-selftest territory).
STUB_SS="$WORK/stub-start-supervisor.sh"
cat > "$STUB_SS" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
exec bash "$HERE/session-run.sh"
EOF
chmod +x "$STUB_SS"

REALPATH_DIRS="/usr/bin:/bin"   # the real script(1), jq, coreutils

# ── fixture factories ────────────────────────────────────────────────────────
make_engine() {  # $1=tag $2=kickoff-copy $3=session-run-copy ; prints the engine scripts dir
  local eng="$WORK/engine.$1"
  rm -rf "$eng"; mkdir -p "$eng/scripts"
  cp "$2" "$eng/scripts/kickoff"
  cp "$3" "$eng/scripts/session-run.sh"
  cp "$STUB_SS" "$eng/scripts/start-supervisor.sh"
  printf '%s' "$eng/scripts"
}

make_repo() {  # $1=name, rest = extra instance.env lines ; prints the fixture repo path
  local fix="$WORK/$1"; shift
  mkdir -p "$fix/.kickoff"
  {
    printf 'TELEGRAM_STATE_DIR=%s\n' "$WORK/chan"
    local l; for l in "$@"; do printf '%s\n' "$l"; done
  } > "$fix/.kickoff/instance.env"
  printf '%s' "$fix"
}

# run_up ENGINE REPO PROBE LOG [K=V ...] [-- <kickoff up args...>]
run_up() {
  local eng="$1" fix="$2" probe="$3" lg="$4"; shift 4
  local -a extra_env=() args=()
  local in_args=0 x
  for x in "$@"; do
    if [ "$x" = "--" ]; then in_args=1; continue; fi
    if [ "$in_args" = 1 ]; then args+=("$x"); else extra_env+=("$x"); fi
  done
  rm -f "$probe"
  # KICKOFF_ENV_KEEP carries the probe path through the v0.7 §2.5 spawn-hygiene boundary
  # (cmd_up drops every non-KEEP-list var — CLAUDE_PROBE_FILE included — so the stub's
  # probe path rides the documented escape hatch; this doubles as its integration proof).
  # Harmless on the pre-hygiene lane: the old kickoff ignores KICKOFF_ENV_KEEP and passes
  # the probe path through natively.
  timeout 25 env -i PATH="$STUBDIR:$REALPATH_DIRS" HOME="$WORK/home" TERM=dumb \
    REPO_DIR="$fix" CLAUDE_PROBE_FILE="$probe" KICKOFF_ENV_KEEP=CLAUDE_PROBE_FILE "${extra_env[@]}" \
    bash "$eng/kickoff" up "${args[@]}" </dev/null >"$lg" 2>&1
}

env_val() {  # $1=probe $2=var → the launch-env value the stub saw, or __no-probe__
  # The stub prints `ENV <VAR>=<value>` and writes the literal __unset__ when the variable is
  # absent, so "unset" and "set to empty" stay distinguishable here. They are different states:
  # session-run.sh parses AUTO_PICKUP for truthiness, and an empty string arriving where nothing
  # should have arrived would mean the launch path invented a value it was never given.
  awk -v v="$2" 'index($0, "ENV " v "=") == 1 { print substr($0, length(v) + 6); found = 1; exit }
    END { if (!found) print "__no-line__" }' "$1" 2>/dev/null || echo "__no-probe__"
}

flag_val() {  # $1=probe $2=flag → the argv token following the flag, or __absent__
  awk -v f="$2" '
    sub(/^ARG /, "") { if (prev == f) { print; found = 1; exit }; prev = $0 }
    END { if (!found) print "__absent__" }
  ' "$1" 2>/dev/null || echo "__no-probe__"
}

# Do these copies already carry the slice-2 precedence markers? MODEL ON the frozen whitelist
# + PERMISSION_MODE OFF it, in all three. When HEAD's copies do, a byte-different working tree
# is a precedence-UNRELATED later edit — no pre-slice baseline is left to prove RED against
# (bridge-reap-selftest's committed-at-HEAD self-skip discipline; same shape as ptywrap's
# marker skip). A working tree that REGRESSES slice 2 is still caught by the NEW lane.
slice2_markers() {  # $1=kickoff $2=session-run $3=preflight
  local l f
  for f in "$1" "$2"; do
    l="$(grep -m1 '^_INSTANCE_ENV_WHITELIST=' "$f" 2>/dev/null)" || return 1
    case "$l" in *" MODEL "*) ;; *) return 1 ;; esac
    case "$l" in *PERMISSION_MODE*) return 1 ;; esac
  done
  l="$(sed -n '/^INSTANCE_ENV_WHITELIST=(/,/^)/p' "$3" 2>/dev/null)"
  printf '%s\n' "$l" | grep -qw MODEL || return 1
  if printf '%s\n' "$l" | grep -qw PERMISSION_MODE; then return 1; fi
  if printf '%s\n' "$l" | grep -qw REPO_DIR; then return 1; fi
  return 0
}

# ── the assertion suite (NEW = expect all-green; OLD = expect the named reds) ─
# $1 = tag (new|old), $2 = kickoff copy, $3 = session-run copy, $4 = preflight copy
suite() {
  local tag="$1" kick="$2" sr="$3" pf="$4"
  local eng fix probe lg rc

  eng="$(make_engine "$tag" "$kick" "$sr")"

  bash -n "$eng/kickoff" 2>/dev/null        && ok "($tag) kickoff parses (bash -n)"     || bad "($tag) kickoff fails bash -n"
  bash -n "$eng/session-run.sh" 2>/dev/null && ok "($tag) session-run parses (bash -n)" || bad "($tag) session-run fails bash -n"
  bash -n "$pf" 2>/dev/null                 && ok "($tag) preflight parses (bash -n)"   || bad "($tag) preflight fails bash -n"

  # (s) preflight's whitelist copy — MODEL in, PERMISSION_MODE out, REPO_DIR STILL out
  # (the three copies are deliberately NOT identical: preflight never re-imports REPO_DIR).
  local wl
  wl="$(sed -n '/^INSTANCE_ENV_WHITELIST=(/,/^)/p' "$pf")"
  printf '%s\n' "$wl" | grep -qw MODEL \
    && ok "(s) preflight whitelist gains MODEL" \
    || bad "(s) preflight whitelist is missing MODEL"
  if printf '%s\n' "$wl" | grep -qw PERMISSION_MODE; then
    bad "(s) preflight whitelist still file-imports PERMISSION_MODE"
  else
    ok "(s) preflight whitelist no longer file-imports PERMISSION_MODE"
  fi
  if printf '%s\n' "$wl" | grep -qw REPO_DIR; then
    bad "(s) preflight REPO_DIR exclusion was LOST (copies must not be synced identical)"
  else
    ok "(s) preflight REPO_DIR exclusion preserved"
  fi

  # (a) instance.env MODEL reaches the claude argv as --model <x> through a cmd_up spawn
  fix="$(make_repo "repo.$tag.a" "MODEL=modelx-file")"
  probe="$WORK/$tag.probe.a"; lg="$WORK/$tag.log.a"
  run_up "$eng" "$fix" "$probe" "$lg"; rc=$?
  check "$rc" 0 "(a) kickoff up exits 0 (spawn chain reached claude)"
  check "$(flag_val "$probe" --model)" "modelx-file" "(a) instance.env MODEL reaches claude argv (--model)"

  # (b) pre-set env MODEL beats the instance.env value (preset-wins)
  fix="$(make_repo "repo.$tag.b" "MODEL=modelx-file")"
  probe="$WORK/$tag.probe.b"; lg="$WORK/$tag.log.b"
  run_up "$eng" "$fix" "$probe" "$lg" MODEL=modelx-env
  check "$(flag_val "$probe" --model)" "modelx-env" "(b) pre-set env MODEL beats the file value"

  # (c) a plain PERMISSION_MODE=auto line in instance.env must NOT arm the spawned worker —
  #     the grant never comes from a file (RED on pre-slice: the file used to win).
  fix="$(make_repo "repo.$tag.c" "PERMISSION_MODE=auto")"
  probe="$WORK/$tag.probe.c"; lg="$WORK/$tag.log.c"
  run_up "$eng" "$fix" "$probe" "$lg"
  check "$(flag_val "$probe" --permission-mode)" "default" "(c) PERMISSION_MODE=auto in instance.env stays --permission-mode default"

  # (d) `kickoff up --auto` is GRANT-ONLY: the grant flows, effort is NOT stomped to max.
  fix="$(make_repo "repo.$tag.d")"
  probe="$WORK/$tag.probe.d"; lg="$WORK/$tag.log.d"
  run_up "$eng" "$fix" "$probe" "$lg" -- --auto
  check "$(flag_val "$probe" --permission-mode)" "auto" "(d) --auto still grants --permission-mode auto"
  check "$(flag_val "$probe" --effort)" "high" "(d) --auto no longer stomps effort to max (engine default high)"

  # (d2) AUTO_PICKUP: resume-the-WIP was reachable ONLY as a hand-set launch env — no flag, nothing
  #      read it from instance.env, nothing carried it across an upgrade. It was live on exactly ONE
  #      org on this box (set by hand in July) while six others would reboot and resume nothing. It
  #      is a per-adopter policy now, on the same footing as MODEL, so these lanes pin all three
  #      directions: the file reaches the worker, argv can turn it OFF over the file, and unset stays
  #      genuinely UNSET rather than an empty string session-run.sh would have to interpret.
  fix="$(make_repo "repo.$tag.d2" "AUTO_PICKUP=1")"
  probe="$WORK/$tag.probe.d2"; lg="$WORK/$tag.log.d2"
  run_up "$eng" "$fix" "$probe" "$lg"
  check "$(env_val "$probe" AUTO_PICKUP)" "1" "(d2) instance.env AUTO_PICKUP=1 reaches the worker env"

  fix="$(make_repo "repo.$tag.d3" "AUTO_PICKUP=1")"
  probe="$WORK/$tag.probe.d3"; lg="$WORK/$tag.log.d3"
  run_up "$eng" "$fix" "$probe" "$lg" -- --no-auto-pickup
  check "$(env_val "$probe" AUTO_PICKUP)" "0" "(d3) --no-auto-pickup on argv beats the instance.env value"

  fix="$(make_repo "repo.$tag.d4")"
  probe="$WORK/$tag.probe.d4"; lg="$WORK/$tag.log.d4"
  run_up "$eng" "$fix" "$probe" "$lg"
  check "$(env_val "$probe" AUTO_PICKUP)" "__unset__" "(d4) unset everywhere stays UNSET (not an empty string)"

  # (e) unset MODEL everywhere → NO --model flag (inherit the box config; never downgrade)
  fix="$(make_repo "repo.$tag.e")"
  probe="$WORK/$tag.probe.e"; lg="$WORK/$tag.log.e"
  run_up "$eng" "$fix" "$probe" "$lg"
  if grep -qxF 'ARG --model' "$probe" 2>/dev/null; then
    bad "(e) unset MODEL still appended a --model flag"
  else
    [ -f "$probe" ] && ok "(e) unset MODEL everywhere → no --model flag appended" \
                    || bad "(e) no probe written — spawn chain never reached claude"
  fi

  # (f) EFFORT resolves the same precedence rule at every seam
  fix="$(make_repo "repo.$tag.f1" "EFFORT=xhigh")"
  probe="$WORK/$tag.probe.f1"; lg="$WORK/$tag.log.f1"
  run_up "$eng" "$fix" "$probe" "$lg"
  check "$(flag_val "$probe" --effort)" "xhigh" "(f1) instance.env EFFORT beats the engine default"

  fix="$(make_repo "repo.$tag.f2")"
  probe="$WORK/$tag.probe.f2"; lg="$WORK/$tag.log.f2"
  run_up "$eng" "$fix" "$probe" "$lg" EFFORT=xhigh -- --effort low
  check "$(flag_val "$probe" --effort)" "low" "(f2) --effort argv beats a pre-set env EFFORT"

  fix="$(make_repo "repo.$tag.f3" "EFFORT=medium")"
  probe="$WORK/$tag.probe.f3"; lg="$WORK/$tag.log.f3"
  run_up "$eng" "$fix" "$probe" "$lg" EFFORT=xhigh
  check "$(flag_val "$probe" --effort)" "xhigh" "(f3) pre-set env EFFORT beats a plain file line (preset-wins, unified importer)"
}

# ── (g) the go-autonomous seam — the OTHER launch path must obey the same rule ─
# go-autonomous.sh used to launch the supervisor with MODEL="${MODEL:-}" (SET-but-EMPTY):
# the preset-wins importer downstream reads "set" as "preset", so an adopter's instance.env
# MODEL pin was silently BLOCKED on this restart path (and EFFORT was stomped to the
# operator-banned `max` default). Since v0.7 G1 §2.2 (slice 4) go-autonomous.sh is a
# one-version deprecation shim over `kickoff up --auto --detach` — the OBSERVABLE contract
# these checks pin (file MODEL flows · effort never stomped · grant intact · preset-wins)
# must hold identically THROUGH the shim. Hermetic: the engine carries a go-autonomous copy
# + the NEW kickoff (the shim's target) + the NEW session-run.sh + a lock-writing stub
# start-supervisor (cmd_up's --detach confirms against the supervisor.lock) + a stub
# supervisor.sh (the PRE-shim go-autonomous's direct target — the old RED lane); the spawn
# is DETACHED, so we wait on the probe's last line instead of the exit.
GA_NEW="$SCRIPT_DIR/go-autonomous.sh"

STUB_SV="$WORK/stub-supervisor.sh"
cat > "$STUB_SV" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
exec bash "$HERE/session-run.sh"
EOF
chmod +x "$STUB_SV"

# stub start-supervisor for the shim chain: writes the lock (so cmd_up's --detach confirm
# poll sees a live supervisor), runs session-run, then HOLDS the lock ~2s so the confirm
# can never race a fast probe-and-exit. Self-cleans; nothing outlives the run.
STUB_SS_GA="$WORK/stub-ga-start-supervisor.sh"
cat > "$STUB_SS_GA" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "${REPO_DIR:?}/.kickoff"
echo "$$" > "$REPO_DIR/.kickoff/supervisor.lock"
bash "$HERE/session-run.sh" || true
sleep 2
rm -f "$REPO_DIR/.kickoff/supervisor.lock"
exit 0
EOF
chmod +x "$STUB_SS_GA"

make_ga_engine() {  # $1=tag $2=go-autonomous copy $3=session-run copy ; prints the engine dir
  local eng="$WORK/ga-engine.$1"
  rm -rf "$eng"; mkdir -p "$eng"
  cp "$2" "$eng/go-autonomous.sh"
  cp "$KI_NEW" "$eng/kickoff"
  cp "$3" "$eng/session-run.sh"
  cp "$STUB_SV" "$eng/supervisor.sh"
  cp "$STUB_SS_GA" "$eng/start-supervisor.sh"
  printf '%s' "$eng"
}

# run_ga ENGINE REPO PROBE LOG [K=V ...] — detached spawn: go-autonomous returns after its
# confirm, the probe lands from the detached chain; wait for the stub's LAST line (the ENV
# dump) so a half-written probe is never asserted against. KICKOFF_ENV_KEEP carries the
# probe path through the §2.5 boundary (the shim now routes through cmd_up); harmless on
# the pre-shim lane, which passes the env through natively.
run_ga() {
  local eng="$1" fix="$2" probe="$3" lg="$4"; shift 4
  rm -f "$probe"
  timeout 30 env -i PATH="$STUBDIR:$REALPATH_DIRS" HOME="$WORK/home" TERM=dumb \
    REPO_DIR="$fix" CLAUDE_PROBE_FILE="$probe" KICKOFF_ENV_KEEP=CLAUDE_PROBE_FILE "$@" \
    bash "$eng/go-autonomous.sh" </dev/null >"$lg" 2>&1
  local rc=$?
  local i
  for i in $(seq 1 30); do
    grep -q '^ENV PERMISSION_MODE=' "$probe" 2>/dev/null && break
    sleep 0.5
  done
  return $rc
}

# $1 = tag (new|old), $2 = go-autonomous copy. session-run is ALWAYS the NEW importer in
# both lanes, so the old lane isolates go-autonomous's env-construction delta alone.
ga_suite() {
  local tag="$1" ga="$2"
  local eng fix probe lg
  eng="$(make_ga_engine "$tag" "$ga" "$SR_NEW")"
  bash -n "$eng/go-autonomous.sh" 2>/dev/null && ok "($tag) go-autonomous parses (bash -n)" || bad "($tag) go-autonomous fails bash -n"

  # (g1)+(g2): the file pin flows; effort is NOT stomped (engine default high); grant intact
  fix="$(make_repo "ga-repo.$tag.g1" "MODEL=modelx-file")"
  probe="$WORK/ga.$tag.probe.g1"; lg="$WORK/ga.$tag.log.g1"
  run_ga "$eng" "$fix" "$probe" "$lg"
  check "$(flag_val "$probe" --model)" "modelx-file" "(g1) instance.env MODEL survives the go-autonomous restart path"
  check "$(flag_val "$probe" --effort)" "high" "(g2) go-autonomous no longer stomps effort to max (engine default high)"
  check "$(flag_val "$probe" --permission-mode)" "auto" "(g) go-autonomous still grants --permission-mode auto"

  # (g3) preset-wins is intact on this path: terminal-env values still beat the file pin
  fix="$(make_repo "ga-repo.$tag.g3" "MODEL=modelx-file")"
  probe="$WORK/ga.$tag.probe.g3"; lg="$WORK/ga.$tag.log.g3"
  run_ga "$eng" "$fix" "$probe" "$lg" MODEL=modelx-env EFFORT=xhigh
  check "$(flag_val "$probe" --model)" "modelx-env" "(g3) terminal-env MODEL still beats the file pin (preset-wins)"
  check "$(flag_val "$probe" --effort)" "xhigh" "(g3) terminal-env EFFORT still flows through go-autonomous"
}

# ── run NEW (expect all green) ───────────────────────────────────────────────
echo "== assertions against NEW scripts/{kickoff,session-run.sh,preflight.sh} =="
suite new "$KI_NEW" "$SR_NEW" "$PF_NEW"
echo
echo "== (g) assertions against NEW scripts/go-autonomous.sh =="
ga_suite new "$GA_NEW"
NEW_PASS=$PASS; NEW_FAIL=$FAIL

# ── RED-ON-OLD: same assertions against HEAD's copies must FAIL on (c) + (d) ─
echo
echo "== RED-on-old: same assertions against HEAD:scripts/{kickoff,session-run.sh,preflight.sh} =="
KI_OLD="$WORK/old.kickoff"; SR_OLD="$WORK/old.session-run.sh"; PF_OLD="$WORK/old.preflight.sh"
if git -C "$SCRIPT_DIR" show HEAD:scripts/kickoff        > "$KI_OLD" 2>/dev/null \
&& git -C "$SCRIPT_DIR" show HEAD:scripts/session-run.sh > "$SR_OLD" 2>/dev/null \
&& git -C "$SCRIPT_DIR" show HEAD:scripts/preflight.sh   > "$PF_OLD" 2>/dev/null; then
  if cmp -s "$KI_NEW" "$KI_OLD" && cmp -s "$SR_NEW" "$SR_OLD" && cmp -s "$PF_NEW" "$PF_OLD"; then
    # All three working-tree files are byte-identical to HEAD's (the normal post-commit
    # state): there is no behavioral delta to prove RED against — N/A, not failed.
    RED_ON_OLD=skip; printf '  skip RED-on-old n/a — kickoff/session-run.sh/preflight.sh are byte-identical to HEAD (post-commit state)\n'
  elif slice2_markers "$KI_OLD" "$SR_OLD" "$PF_OLD"; then
    # HEAD already carries slice 2 (markers hold on all three copies): the working-tree
    # delta is precedence-unrelated (a later slice editing the same files) — N/A.
    RED_ON_OLD=skip; printf '  skip RED-on-old n/a — HEAD already carries the slice-2 precedence behaviors (working-tree delta is precedence-unrelated)\n'
  else
    PASS=0; FAIL=0
    OLD_OUT="$WORK/old.suite.out"
    suite old "$KI_OLD" "$SR_OLD" "$PF_OLD" > "$OLD_OUT" 2>&1
    OLD_FAIL=$FAIL
    # The spec-named REDs: (c) file-armed PERMISSION_MODE and (d) --auto effort=max must
    # both fail on pre-slice code — a generic ">0 reds" would let either regress silently.
    if [ "$OLD_FAIL" -gt 0 ] && grep -q '^  FAIL (c)' "$OLD_OUT" && grep -q '^  FAIL (d)' "$OLD_OUT"; then
      RED_ON_OLD=1
      printf '  ok   RED-on-old proven — %s assertion(s) FAIL against HEAD, incl. the spec-named (c) + (d):\n' "$OLD_FAIL"
      grep '^  FAIL' "$OLD_OUT" | sed 's/^  FAIL/         RED/'
    else
      RED_ON_OLD=0
      printf '  FAIL RED-on-old NOT proven — old-code fails=%s, and (c)/(d) must be among them:\n' "$OLD_FAIL"
      grep '^  FAIL' "$OLD_OUT" | sed 's/^/       /' || printf '       (no failures at all — the suite proves nothing)\n'
    fi
  fi
else
  RED_ON_OLD=0; printf '  FAIL could not read the HEAD copies to prove RED-on-old\n'
fi

# ── RED-on-old (g): HEAD's go-autonomous must show the pin-block + the max stomp ─
# Its own lane (go-autonomous.sh is not one of the three files above): byte-identical to
# HEAD → post-commit state, N/A; HEAD without the EFFORT-max marker → the fix is already
# committed and the working-tree delta is unrelated, N/A. Otherwise the old copy must go
# RED on exactly the two named regressions — (g1) pin blocked, (g2) effort stomped.
echo
echo "== RED-on-old: (g) against HEAD:scripts/go-autonomous.sh =="
GA_OLD="$WORK/old.go-autonomous.sh"
if git -C "$SCRIPT_DIR" show HEAD:scripts/go-autonomous.sh > "$GA_OLD" 2>/dev/null; then
  if cmp -s "$GA_NEW" "$GA_OLD"; then
    RED_GA=skip; printf '  skip RED-on-old n/a — go-autonomous.sh is byte-identical to HEAD (post-commit state)\n'
  elif ! grep -qF 'EFFORT="${EFFORT:-max}"' "$GA_OLD"; then
    RED_GA=skip; printf '  skip RED-on-old n/a — HEAD already carries the grant-only go-autonomous (working-tree delta is unrelated)\n'
  else
    PASS=0; FAIL=0
    GA_OUT="$WORK/old.ga.out"
    ga_suite old "$GA_OLD" > "$GA_OUT" 2>&1
    GA_FAIL=$FAIL
    if [ "$GA_FAIL" -gt 0 ] && grep -q '^  FAIL (g1)' "$GA_OUT" && grep -q '^  FAIL (g2)' "$GA_OUT"; then
      RED_GA=1
      printf '  ok   RED-on-old proven — %s assertion(s) FAIL against HEAD go-autonomous, incl. the named (g1) + (g2):\n' "$GA_FAIL"
      grep '^  FAIL' "$GA_OUT" | sed 's/^  FAIL/         RED/'
    else
      RED_GA=0
      printf '  FAIL RED-on-old NOT proven for go-autonomous — old-code fails=%s, and (g1)/(g2) must be among them:\n' "$GA_FAIL"
      grep '^  FAIL' "$GA_OUT" | sed 's/^/       /' || printf '       (no failures at all — the (g) leg proves nothing)\n'
    fi
  fi
else
  RED_GA=0; printf '  FAIL could not read HEAD:scripts/go-autonomous.sh to prove RED-on-old\n'
fi

echo
echo "== summary =="
printf 'NEW: pass=%s fail=%s   RED-on-old proven=%s   RED-on-old(go-autonomous) proven=%s\n' \
  "$NEW_PASS" "$NEW_FAIL" "${RED_ON_OLD:-0}" "${RED_GA:-0}"
case "${RED_ON_OLD:-0}" in 1|skip)
  case "${RED_GA:-0}" in 1|skip)
    if [ "$NEW_FAIL" -eq 0 ]; then echo "SELFTEST PASS"; exit 0; fi ;;
  esac ;;
esac
echo "SELFTEST FAIL"; exit 1
