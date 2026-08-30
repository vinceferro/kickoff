#!/usr/bin/env bash
# pin-verify-selftest.sh — prove the pin-redirect VERIFIES its target before handing control to it.
#
#   bash scripts/pin-verify-selftest.sh
#
# The bug (pre-existing since v0.7, live in every released core): the redirect gated on core.lock
# EXISTING, then took the target from $KICKOFF_CORE_DIR and exec'd it — never reading the commit the
# lock PINS. A repo whose instance.env named a different engine than its lock pinned was exec'd into
# that engine unverified. preflight #6 checks exactly this, but runs INSIDE the engine — i.e. after
# the exec, which is too late to be the gate.
#
# RED-first: every lane below is run against BOTH the current front door and HEAD's, and the report
# names which ones HEAD lets through. A lane that passes on both is not testing the fix.
#
# Deploy topology, never the dev checkout: a real pinned engine clone (git, tagged, clean) + a DECOY
# engine at the plausible-but-wrong path that instance.env names. The engines are STUBS that print a
# marker, so "did it exec the decoy?" is directly observable rather than inferred.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
KICKOFF="$HERE/kickoff"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
command -v git >/dev/null 2>&1 || { echo "  ❌ git required"; exit 1; }

# HEAD's front door — the pre-fix build, for the RED-on-old contrast. It needs a REAL tree: the
# front door resolves its siblings from $HERE, so a bare file in an empty dir fails for reasons that
# have nothing to do with the pin and would fake a "red".
OLDTREE="$W/oldtree"; mkdir -p "$OLDTREE"
cp -r "$HERE" "$OLDTREE/scripts" 2>/dev/null || true
OLD="$OLDTREE/scripts/kickoff"
git -C "$HERE/.." show HEAD:scripts/kickoff > "$OLD" 2>/dev/null && chmod +x "$OLD"
# Once the fix is COMMITTED (and in the release tree it always is), HEAD is no longer the pre-fix
# build and the RED-on-old lane cannot go red. Detect that and SKIP it loudly instead of failing:
# a lane that is structurally unable to fail must say so, not report a red. Same "post-commit state"
# convention the hop/config-precedence suites already use. The FIRST arm is the harder-won one —
# see _old_state below: an extraction can be non-empty and still not be this file at all.
OLD_HAS_FIX=0; OLD_SKIP=""
if ! [ -s "$OLD" ]; then
  OLD_SKIP="could not be extracted from HEAD (empty)"
elif ! grep -q 'cmd_pull' "$OLD" 2>/dev/null; then
  OLD_SKIP="is not the front door at all (HEAD carries something else at that path)"
elif grep -q '_verify_pin_target' "$OLD" 2>/dev/null; then
  OLD_SKIP="already carries _verify_pin_target (post-commit state)"
fi
[ -n "$OLD_SKIP" ] && OLD_HAS_FIX=1

# ── EVERY fixture git call goes through this. `-C <dir>` is NOT containment ───────────────────
# GIT_DIR (and GIT_WORK_TREE / GIT_INDEX_FILE) OVERRIDE `-C`, so `git -C "$fixture" commit` writes
# into the CALLER's repository whenever they are exported. An adversarial pass proved it on this
# suite: one run with GIT_DIR set put SEVEN fixture commits, five fixture tags and a fixture branch
# into the live repo — while printing an ordinary pass/fail summary, because every fixture git call
# was silenced with 2>/dev/null and nothing ever looked. Carriers are real and ordinary: `git bisect
# run`, `git rebase --exec`, `git filter-branch`, `git submodule foreach`, any agent or wrapper that
# exports GIT_DIR. A test suite that can commit into the repo under test is not a test suite.
#
# fgit() strips all three on every invocation. It is deliberately NOT silenced by default: a fixture
# that fails to BUILD must be loud, or the assertions afterwards report on a world that was never
# constructed (see the `entries[]` lesson in plugin-selftest §9).
fgit() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git "$@"; }

# ── a stub "engine": a git repo whose scripts/kickoff prints WHICH engine ran ──────────────────
mk_engine() {  # $1=dir $2=marker $3=tag
  local d="$1" m="$2" t="$3"
  mkdir -p "$d/scripts"
  printf '#!/usr/bin/env bash\necho "EXECD:%s"\nexit 0\n' "$m" > "$d/scripts/kickoff"
  chmod +x "$d/scripts/kickoff"
  fgit -C "$d" init -q 2>/dev/null
  fgit -C "$d" -c user.email=t@t -c user.name=t add -A 2>/dev/null
  fgit -C "$d" -c user.email=t@t -c user.name=t commit -qm "$m" 2>/dev/null
  [ -n "$t" ] && fgit -C "$d" tag -f "$t" >/dev/null 2>&1
  fgit -C "$d" rev-parse HEAD 2>/dev/null
}

mk_adopter() {  # $1=dir $2=core_dir_for_instance_env $3=tag $4=commit
  local r="$1"
  mkdir -p "$r/.kickoff/memory"
  printf 'export KICKOFF_CORE_DIR="${KICKOFF_CORE_DIR:-%s}"\n' "$2" > "$r/.kickoff/instance.env"
  printf '# m\n' > "$r/.kickoff/memory/MEMORY.md"
  { printf 'format 2\n'; [ -n "$3" ] && printf 'tag %s\n' "$3"; [ -n "$4" ] && printf 'commit %s\n' "$4"; } \
    > "$r/.kickoff/core.lock"
}

# Run `doctor` (a redirecting verb) from the adopter; capture output+rc. $1=front door $2=repo.
#
# KICKOFF_CORE_DIR is SCRUBBED, and that is load-bearing rather than tidiness: this suite is itself
# run from inside a worker session that exports it, and load_instance_env deliberately skips pre-set
# names ("pre-set / argv wins"). Left ambient, the caller's engine wins over the fixture's
# instance.env and every lane silently tests the CALLER's pin instead of the one it just built —
# the fixture would be measuring this box, not the case. (Pre-set-wins is correct for this variable:
# `kickoff pull` passes it as a trusted override for the parked-worktree case. The right containment
# for an ambient value that is not the pin is to REFUSE loudly, which is what is under test here.)
run_doctor() {
  local fd="$1" repo="$2"
  ( env -u KICKOFF_CORE_DIR REPO_DIR="$repo" bash "$fd" doctor --dir "$repo" 2>&1; printf 'RC=%d' "$?" )
}

echo "▶ pin-redirect verify-before-exec self-test"
echo

# ══════════════════════════════════════════════════════════════════════════════════
echo "1. THE BUG: instance.env names a DECOY engine; core.lock pins the REAL one"
# ══════════════════════════════════════════════════════════════════════════════════
REAL="$W/real-engine"; DECOY="$W/decoy-engine"; AD="$W/adopter"
REAL_C="$(mk_engine "$REAL" real core-vREAL)"
mk_engine "$DECOY" DECOY core-vDECOY >/dev/null
mk_adopter "$AD" "$DECOY" core-vREAL "$REAL_C"     # lock pins REAL, env points at DECOY

NEW_OUT="$(run_doctor "$KICKOFF" "$AD")"
OLD_OUT="$(run_doctor "$OLD" "$AD")"

chk "fixture is SHARP: the decoy front door really is executable (it COULD be exec'd)" \
  "[ -x '$DECOY/scripts/kickoff' ]"
chk "NEW: refuses — does NOT exec the decoy" \
  "! printf '%s' \"\$NEW_OUT\" | grep -q 'EXECD:DECOY'"
chk "NEW: names the mismatch (PIN MISMATCH), not a vague failure" \
  "printf '%s' \"\$NEW_OUT\" | grep -q 'PIN MISMATCH'"
chk "NEW: non-zero exit (fail-closed, not a warning)" \
  "! printf '%s' \"\$NEW_OUT\" | grep -q 'RC=0'"
if [ "$OLD_HAS_FIX" = "1" ]; then
  echo "  skip RED-on-old — HEAD's front door $OLD_SKIP"
else
  chk "RED-on-old: HEAD's front door DID exec the decoy (the lane is a real negative control)" \
    "printf '%s' \"\$OLD_OUT\" | grep -q 'EXECD:DECOY'"
  printf '%s' "$OLD_OUT" | grep -q 'EXECD:DECOY' || printf '     ── old output was: %s\n' "$(printf '%s' "$OLD_OUT" | tail -2 | tr '\n' ' ')"
fi
echo

# ══════════════════════════════════════════════════════════════════════════════════
echo "2. POSITIVE CONTROL: a CORRECTLY pinned target still redirects (not just disabled)"
# ══════════════════════════════════════════════════════════════════════════════════
AD2="$W/adopter-ok"
mk_adopter "$AD2" "$REAL" core-vREAL "$REAL_C"
OK_OUT="$(run_doctor "$KICKOFF" "$AD2")"
chk "a valid pin still re-execs the pinned engine (the redirect is intact)" \
  "printf '%s' \"\$OK_OUT\" | grep -q 'EXECD:real'"
chk "a valid pin does not print a mismatch" \
  "! printf '%s' \"\$OK_OUT\" | grep -q 'PIN MISMATCH'"
echo

# ══════════════════════════════════════════════════════════════════════════════════
echo "3. MUTANTS — each breaks the pin a DIFFERENT way; all must refuse"
# ══════════════════════════════════════════════════════════════════════════════════
# (a) dirty tree — a copied-and-patched core is not the pin it claims to be
AD3="$W/adopter-dirty"; DIRTY="$W/dirty-engine"
DIRTY_C="$(mk_engine "$DIRTY" dirty core-vD)"
mk_adopter "$AD3" "$DIRTY" core-vD "$DIRTY_C"
printf 'patched\n' >> "$DIRTY/scripts/kickoff"
D_OUT="$(run_doctor "$KICKOFF" "$AD3")"
chk "(a) DIRTY pinned tree → refuses + says DIRTY" \
  "printf '%s' \"\$D_OUT\" | grep -q 'DIRTY' && ! printf '%s' \"\$D_OUT\" | grep -q 'EXECD:dirty'"

# (b) the tag MOVED since the pull — lock commit no longer what the tag resolves to
AD4="$W/adopter-moved"; MOVED="$W/moved-engine"
MOVED_C="$(mk_engine "$MOVED" moved core-vM)"
printf 'next\n' >> "$MOVED/scripts/kickoff"
fgit -C "$MOVED" -c user.email=t@t -c user.name=t commit -aqm second 2>/dev/null
fgit -C "$MOVED" tag -f core-vM >/dev/null 2>&1          # tag now points at the 2nd commit
mk_adopter "$AD4" "$MOVED" core-vM "$MOVED_C"           # lock still pins the 1st
M_OUT="$(run_doctor "$KICKOFF" "$AD4")"
chk "(b) MOVED tag → refuses (HEAD≠lock caught before the tag check)" \
  "! printf '%s' \"\$M_OUT\" | grep -q 'EXECD:moved'"

# (c) target is not a git checkout at all
AD5="$W/adopter-nogit"; NOGIT="$W/nogit-engine"
mkdir -p "$NOGIT/scripts"; printf '#!/usr/bin/env bash\necho EXECD:nogit\n' > "$NOGIT/scripts/kickoff"
chmod +x "$NOGIT/scripts/kickoff"
mk_adopter "$AD5" "$NOGIT" core-vREAL "$REAL_C"
N_OUT="$(run_doctor "$KICKOFF" "$AD5")"
chk "(c) target is NOT a git checkout → refuses" \
  "! printf '%s' \"\$N_OUT\" | grep -q 'EXECD:nogit'"

# (d) the bounded carve-out: a pre-format-2 lock has nothing to compare — WARN, don't brick
AD6="$W/adopter-fmt1"
mk_adopter "$AD6" "$REAL" "" ""                          # no tag, no commit
printf 'format 1\n' > "$AD6/.kickoff/core.lock"
F1_OUT="$(run_doctor "$KICKOFF" "$AD6")"
chk "(d) pre-format-2 lock → proceeds (migration carve-out, an old adopter is not bricked)" \
  "printf '%s' \"\$F1_OUT\" | grep -q 'EXECD:real'"
chk "(d) …and says so loudly rather than silently skipping the check" \
  "printf '%s' \"\$F1_OUT\" | grep -qi 'pre-format-2'"
echo

# ══════════════════════════════════════════════════════════════════════════════════
echo "4. HOW THE TAG IS RESOLVED — both predicates, because they DRIFTED apart"
# ══════════════════════════════════════════════════════════════════════════════════
# Two sites verify the same pin: the FRONT DOOR (_verify_pin_target, before the re-exec) and
# PREFLIGHT #6 (inside the engine, before a session). A third — the engine-identity predicate
# (_eitp) — fixed this idiom in v0.26 and wrote 20 lines explaining why; its two siblings kept
# it. So these lanes run BOTH remaining sites against the SAME fixtures: a lane that only ever
# drove one of them is how the drift survived a release.
#
# Defect 1 (fired LIVE 2026-08-12): a plain `rev-parse <unknown>^{commit}` ECHOES its argument,
#   so an ABSENT tag is captured non-empty and misreported as "the tag MOVED (a re-tagged
#   release)" — a confident wrong story whose remediation cannot work.
# Defect 2: a bare `<value>^{commit}` resolves ANY revision, so a lock naming HEAD / a raw sha /
#   a branch RESOLVES and the pin ticks GREEN while certifying nothing.
#
# The old-vs-new contrast is the whole point: for defect 1 both builds refuse and the lane is on
# WHICH STORY they tell; for defect 2 the old build actually PROCEEDS, so the lane is a real
# false-green negative control.
OLDPF="$OLDTREE/scripts/preflight.sh.head"
git -C "$HERE/.." show HEAD:scripts/preflight.sh > "$OLDPF" 2>/dev/null
# THREE states, not two — and the third is why this is spelled out. `git show HEAD:<path>` can fail
# (a detached/odd HEAD, a tree that does not carry the path, a repo mid-surgery) and the redirect
# still creates an EMPTY file. An empty pre-fix build then "fails to tell the wrong story" and every
# RED-on-old lane reports a red that says nothing about the code under test. Observed here while the
# repo's HEAD sat on unrelated commits: ten lanes went red and none of them meant anything. A lane
# that cannot run must SAY it cannot run — the one thing it must never do is imply a verdict.
# NON-EMPTY IS NOT USABLE — the second half of this guard cost a confusing half hour to learn. While
# this repo's HEAD sat on fixture commits left by an adversarial run, `git show HEAD:scripts/kickoff`
# returned 43 bytes: the FIXTURE's stub front door (`echo "EXECD:pf"`). Non-empty, so an emptiness
# test passed it, and six RED-on-old lanes then "proved" that the pre-fix build failed to refuse —
# by running a stub that does nothing at all. A negative control must establish that it extracted
# THE ARTIFACT, not merely bytes; so each side names a marker that exists in every real version of
# its file, pre-fix and post-fix alike.
_old_state() {  # $1=extracted file $2=plausibility marker → prints "" (usable) | a reason
  [ -s "$1" ] || { printf 'could not be extracted from HEAD (empty) — the pre-fix build is unavailable'; return; }
  grep -q "$2" "$1" 2>/dev/null \
    || { printf 'is not the file under test (HEAD carries something else at that path, %s bytes) — the pre-fix build is unavailable' "$(wc -c < "$1" | tr -d ' ')"; return; }
  grep -q 'refs/tags/\$lock_tag' "$1" 2>/dev/null \
    && printf 'already scopes to refs/tags/ (post-commit state)'
}
OLD_PF_SKIP="$(_old_state "$OLDPF" 'fail-closed instance preflight')"
OLD_FD_SKIP="$(_old_state "$OLD"   'cmd_pull')"
OLD_PF_HAS_FIX=0; OLD_FD_HAS_FIX=0
[ -n "$OLD_PF_SKIP" ] && OLD_PF_HAS_FIX=1
[ -n "$OLD_FD_SKIP" ] && OLD_FD_HAS_FIX=1

# An engine that CARRIES the preflight under test, so preflight's RUNNING_CORE_DIR is the fixture
# engine — deploy topology, not the dev checkout. It matters: core_base and RUNNING_CORE_DIR must
# agree or check #14 fires FIRST and the whole pin block is skipped by the elif chain, and the
# lane would pass while testing nothing. preflight.sh is COMMITTED into the engine (never dropped
# in after) so the pinned tree stays CLEAN and the dirty-tree arm cannot mask the tag arm.
mk_pf_engine() {  # $1=dir $2=preflight-file $3=tag → prints commit
  local d="$1"
  mkdir -p "$d/scripts"
  cp "$2" "$d/scripts/preflight.sh"
  printf '#!/usr/bin/env bash\necho "EXECD:pf"\nexit 0\n' > "$d/scripts/kickoff"
  chmod +x "$d/scripts/kickoff"
  fgit -C "$d" init -q 2>/dev/null
  fgit -C "$d" -c user.email=t@t -c user.name=t add -A 2>/dev/null
  fgit -C "$d" -c user.email=t@t -c user.name=t commit -qm pf 2>/dev/null
  fgit -C "$d" tag -f "$3" >/dev/null 2>&1
  fgit -C "$d" rev-parse HEAD 2>/dev/null
}
run_preflight() {  # $1=engine $2=repo
  ( env -u KICKOFF_CORE_DIR REPO_DIR="$2" bash "$1/scripts/preflight.sh" 2>&1; printf 'RC=%d' "$?" )
}

PFNEW="$W/pf-new"; PFOLD="$W/pf-old"
PFNEW_C="$(mk_pf_engine "$PFNEW" "$HERE/preflight.sh" core-vPF)"
PFOLD_C="$(mk_pf_engine "$PFOLD" "$OLDPF" core-vPF)"

# ── (e) THE LIVE BUG: the lock names a tag that was NEVER CREATED ────────────────────────────
ADG="$W/adopter-ghost"; ADGO="$W/adopter-ghost-old"
mk_adopter "$ADG"  "$PFNEW" core-vGHOST "$PFNEW_C"
mk_adopter "$ADGO" "$PFOLD" core-vGHOST "$PFOLD_C"
G_NEW="$(run_preflight "$PFNEW" "$ADG")"
G_OLD="$(run_preflight "$PFOLD" "$ADGO")"

chk "(e) fixture is SHARP: the ghost tag really is absent from the engine" \
  "! git -C '$PFNEW' rev-parse -q --verify refs/tags/core-vGHOST >/dev/null 2>&1"
chk "(e) preflight NEW: says the TAG does not resolve" \
  "printf '%s' \"\$G_NEW\" | grep -q 'no such TAG resolves'"
chk "(e) preflight NEW: does NOT claim the tag MOVED (the wrong story)" \
  "! printf '%s' \"\$G_NEW\" | grep -q 'tag MOVED'"
if [ "$OLD_PF_HAS_FIX" = "1" ]; then
  echo "  skip (e)/preflight RED-on-old — HEAD's preflight $OLD_PF_SKIP"
else
  chk "(e) RED-on-old: HEAD's preflight DID tell the wrong story ('tag MOVED')" \
    "printf '%s' \"\$G_OLD\" | grep -q 'tag MOVED'"
fi

ADGF="$W/adopter-ghost-fd"
mk_adopter "$ADGF" "$REAL" core-vGHOST "$REAL_C"
GF_NEW="$(run_doctor "$KICKOFF" "$ADGF")"
GF_OLD="$(run_doctor "$OLD" "$ADGF")"
chk "(e) front door NEW: says the TAG does not resolve, and still refuses" \
  "printf '%s' \"\$GF_NEW\" | grep -q 'no such TAG resolves' && ! printf '%s' \"\$GF_NEW\" | grep -q 'EXECD:real'"
chk "(e) front door NEW: does NOT claim the tag MOVED (the twin of the preflight lane above)" \
  "! printf '%s' \"\$GF_NEW\" | grep -q 'tag MOVED'"
if [ "$OLD_FD_HAS_FIX" = "1" ]; then
  echo "  skip (e)/front-door RED-on-old — HEAD's front door $OLD_FD_SKIP"
else
  chk "(e) RED-on-old: HEAD's front door DID tell the wrong story ('tag MOVED')" \
    "printf '%s' \"\$GF_OLD\" | grep -q 'tag MOVED'"
fi
echo

# ── (f) THE VACUOUS TICK: three lock values that are NOT tags but RESOLVE anyway ─────────────
# Each one made the old predicate certify "the pinned tag resolves to that same commit" — for
# HEAD and a raw sha that is TRUE BY DEFINITION once HEAD==commit is checked one arm above, so
# the clause could not fail; for a branch it resolves and is simply not a tag. All three ticked.
fgit -C "$PFNEW" branch pinbranch >/dev/null 2>&1
fgit -C "$PFOLD" branch pinbranch >/dev/null 2>&1
fgit -C "$REAL"  branch pinbranch >/dev/null 2>&1
for _v in HEAD SHA pinbranch; do
  case "$_v" in
    SHA) _new_tag="$PFNEW_C"; _old_tag="$PFOLD_C"; _fd_tag="$REAL_C"; _label="a raw commit id" ;;
    *)   _new_tag="$_v";      _old_tag="$_v";      _fd_tag="$_v";     _label="$_v" ;;
  esac
  ADV="$W/adopter-vac-$_v"; ADVO="$W/adopter-vac-old-$_v"; ADVF="$W/adopter-vac-fd-$_v"
  mk_adopter "$ADV"  "$PFNEW" "$_new_tag" "$PFNEW_C"
  mk_adopter "$ADVO" "$PFOLD" "$_old_tag" "$PFOLD_C"
  mk_adopter "$ADVF" "$REAL"  "$_fd_tag"  "$REAL_C"
  V_NEW="$(run_preflight "$PFNEW" "$ADV")"
  V_OLD="$(run_preflight "$PFOLD" "$ADVO")"
  VF_NEW="$(run_doctor "$KICKOFF" "$ADVF")"
  VF_OLD="$(run_doctor "$OLD" "$ADVF")"

  # ASSERT THE POSITIVE REFUSAL, not merely the absence of a tick. An absence-grep is satisfied by
  # a fixture that was never built — an adversarial pass demonstrated exactly that here, twice: once
  # with GIT_DIR retargeting the fixture commits, and once with a hostile global gitconfig
  # (commit.gpgsign=true, gpg.program=/bin/false) that made every fixture commit fail. Both left the
  # `! grep` lanes green with nothing under them. Requiring the specific message the fix emits means
  # the lane can only pass if the predicate actually ran and actually refused.
  chk "(f) preflight NEW: a lock naming $_label is REFUSED, naming the reason" \
    "printf '%s' \"\$V_NEW\" | grep -q 'no such TAG resolves' && ! printf '%s' \"\$V_NEW\" | grep -q 'whole-tree pin holds'"
  chk "(f) front door NEW: a lock naming $_label refuses, naming the reason, and does not re-exec" \
    "printf '%s' \"\$VF_NEW\" | grep -q 'no such TAG resolves' && ! printf '%s' \"\$VF_NEW\" | grep -q 'EXECD:real'"
  if [ "$OLD_PF_HAS_FIX" = "1" ]; then
    echo "  skip (f)/preflight RED-on-old ($_label) — HEAD's preflight $OLD_PF_SKIP"
  else
    chk "(f) RED-on-old: HEAD's preflight TICKED a lock naming $_label (false green)" \
      "printf '%s' \"\$V_OLD\" | grep -q 'whole-tree pin holds'"
  fi
  if [ "$OLD_FD_HAS_FIX" = "1" ]; then
    echo "  skip (f)/front-door RED-on-old ($_label) — HEAD's front door $OLD_FD_SKIP"
  else
    chk "(f) RED-on-old: HEAD's front door EXEC'D on a lock naming $_label (false green)" \
      "printf '%s' \"\$VF_OLD\" | grep -q 'EXECD:real'"
  fi
done
echo

# ── (h) THE HOSTILE LANE — the scrub above removes an INPUT, so one lane must NOT scrub ──────
# run_doctor/run_preflight strip KICKOFF_CORE_DIR so the fixture's own instance.env decides the
# engine. That is right for isolation and WRONG as the only lane: preflight's check #14 fires when
# an ambient KICKOFF_CORE_DIR names a different tree than the one running, and #14 sits in the SAME
# elif chain as the pin block — so it SKIPS the tag arm entirely. Every absence-grep above would
# stay green in that world while the predicate under test never executed. This is the canon's
# "second lane that sets the variable HOSTILELY": hand the caller's value in and assert the target
# still refuses for a reason it NAMES, rather than passing by never being asked.
ADH="$W/adopter-hostile"
mk_adopter "$ADH" "$PFNEW" core-vGHOST "$PFNEW_C"
H_OUT="$( KICKOFF_CORE_DIR="$REAL" REPO_DIR="$ADH" bash "$PFNEW/scripts/preflight.sh" 2>&1; printf 'RC=%d' "$?" )"
chk "(h) hostile ambient KICKOFF_CORE_DIR: preflight still REFUSES (never RC=0)" \
  "! printf '%s' \"\$H_OUT\" | grep -q 'RC=0'"
chk "(h) …and says WHICH world it is in — the running core is not the declared pin (#14)" \
  "printf '%s' \"\$H_OUT\" | grep -q 'is NOT the pinned KICKOFF_CORE_DIR'"
chk "(h) …and never claims the pin HOLDS while the tag arm was skipped" \
  "! printf '%s' \"\$H_OUT\" | grep -q 'whole-tree pin holds'"
echo

# ── (i) THE TWO SITES DISAGREED: a format-2 lock with a commit but NO tag line ───────────────
# preflight #6 fail-closes on it ("missing its tag/commit keys"). The front door used to gate the
# whole tag block on `[ -n "$lock_tag" ]`, so the same lock skipped tag verification and re-exec'd
# with rc 0 — the permissive site being the one that runs BEFORE the handover, which inverts the
# entire point of verify-before-exec. Both must refuse, and both must SAY the lock is malformed.
ADT="$W/adopter-tagless"; ADTP="$W/adopter-tagless-pf"
mk_adopter "$ADT"  "$REAL"  "" "$REAL_C"
mk_adopter "$ADTP" "$PFNEW" "" "$PFNEW_C"
T_FD="$(run_doctor "$KICKOFF" "$ADT")"
T_PF="$(run_preflight "$PFNEW" "$ADTP")"
chk "(i) fixture is SHARP: the lock really is format 2 with a commit and no tag" \
  "grep -qx 'format 2' '$ADT/.kickoff/core.lock' && grep -q '^commit ' '$ADT/.kickoff/core.lock' && ! grep -q '^tag ' '$ADT/.kickoff/core.lock'"
chk "(i) front door NEW: refuses a tagless format-2 lock instead of re-exec'ing" \
  "! printf '%s' \"\$T_FD\" | grep -q 'EXECD:real'"
chk "(i) front door NEW: names it as malformed (NO tag line), not a vague failure" \
  "printf '%s' \"\$T_FD\" | grep -q 'NO tag line'"
chk "(i) preflight: refuses the same lock (the two sites now agree)" \
  "! printf '%s' \"\$T_PF\" | grep -q 'whole-tree pin holds'"
if [ "$OLD_FD_HAS_FIX" = "1" ]; then
  echo "  skip (i) RED-on-old — HEAD's front door $OLD_FD_SKIP"
else
  chk "(i) RED-on-old: HEAD's front door RE-EXEC'D on the tagless lock (the false green)" \
    "printf '%s' \"\$(run_doctor \"\$OLD\" \"\$ADT\")\" | grep -q 'EXECD:real'"
fi
echo

# ── (j) PARITY WITH _eitp: trim the value, and never print it raw ────────────────────────────
# The engine-identity predicate has trimmed and sanitised lock values since v0.26. These two sites
# did neither, and the comment claiming they matched _eitp was an overclaim an adversarial pass
# called out. Both halves are operator-visible: a CRLF lock makes a REAL pin read as an absent tag
# (fail-closed on a healthy adopter), and a lock is a file this engine did not write, interpolated
# straight into the message the operator reads.
ADCR="$W/adopter-crlf"
mk_adopter "$ADCR" "$REAL" core-vREAL "$REAL_C"
printf 'format 2\r\ntag core-vREAL\r\ncommit %s\r\n' "$REAL_C" > "$ADCR/.kickoff/core.lock"
CR_OUT="$(run_doctor "$KICKOFF" "$ADCR")"
chk "(j) a CRLF core.lock still verifies — trailing \\r does not turn a real pin into an absent tag" \
  "printf '%s' \"\$CR_OUT\" | grep -q 'EXECD:real'"

# A forged tick + an ESC sequence in the tag line. The refusal must still be a refusal on screen:
# the operator must not see the lock's own sentence rendered as though the engine said it.
ADEV="$W/adopter-evil"
mk_adopter "$ADEV" "$REAL" "core-vREAL" "$REAL_C"
printf 'format 2\ntag \033[32m✓ the pin HOLDS\033[0m\ncommit %s\n' "$REAL_C" > "$ADEV/.kickoff/core.lock"
EV_OUT="$(run_doctor "$KICKOFF" "$ADEV")"
chk "(j) a lock forging a green tick does NOT reach the terminal verbatim" \
  "! printf '%s' \"\$EV_OUT\" | grep -q '✓ the pin HOLDS'"
chk "(j) …and no raw ESC from the lock is emitted (the line cannot be repainted)" \
  "! printf '%s' \"\$EV_OUT\" | grep -q \$'\033\[32m'"
chk "(j) …and it still REFUSES (sanitising the message never softens the verdict)" \
  "! printf '%s' \"\$EV_OUT\" | grep -q 'EXECD:real'"
echo

# ── (g) POSITIVE CONTROL for section 4: a REAL tag still verifies, both sites ────────────────
# Without this, every lane above is satisfiable by a predicate that refuses everything.
ADOK="$W/adopter-pf-ok"; ADOKF="$W/adopter-fd-ok"
mk_adopter "$ADOK"  "$PFNEW" core-vPF   "$PFNEW_C"
mk_adopter "$ADOKF" "$REAL"  core-vREAL "$REAL_C"
OKPF="$(run_preflight "$PFNEW" "$ADOK")"
OKFD="$(run_doctor "$KICKOFF" "$ADOKF")"
chk "(g) preflight NEW: a REAL tag still verifies the pin (the fix did not brick the good case)" \
  "printf '%s' \"\$OKPF\" | grep -q 'core.lock verified'"
chk "(g) front door NEW: a REAL tag still re-execs the pinned engine" \
  "printf '%s' \"\$OKFD\" | grep -q 'EXECD:real'"
echo

echo "──────────────────────────────"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && echo "  ✅ the redirect verifies its target before handing over control" \
                  || echo "  ❌ pin-redirect verification is NOT holding"
[ "$FAIL" -eq 0 ]
