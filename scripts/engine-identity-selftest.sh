#!/usr/bin/env bash
# engine-identity-selftest.sh — WHICH ENGINE IS SPEAKING, and is it the one the repo pinned?
#
#   bash scripts/engine-identity-selftest.sh
#
# ── THE BUG THIS SUITE EXISTS FOR (reproduced live, 2026-08-07) ─────────────────────────────────
# `kickoff status --dir <repo>` run from the WRONG engine printed:
#
#     ✓ core pin HOLDS — the clone is at core-v0.25 (642998fc9710…) on a clean tree (== core.lock)
#
# …while the front door printing it was ~/kickoff-versions/core-v0.24 (commit ae5d3266). The tick
# was TRUE of the pinned clone and SILENT about the speaker: the core-pin block asks whether the
# PINNED CLONE matches the lock, and never whether IT is that clone. An operator reading a green
# tick from a stale engine has no way to see that a different engine produced it.
#
# ── WHAT IS ASSERTED, AND WHY IT IS SHAPED THIS WAY ─────────────────────────────────────────────
# Five previous rounds of front-door work died on ONE disease: a guard answering a PROXY question
# in place of the real one, with the proxy failing OPEN ("did git answer?" for "is there a repo
# boundary?"; "is HEAD detached?" for "is this the engine?"; "is $HOME/kickoff-versions the
# parent?" for "is this a pulled core?"). So every lane below asserts on BEHAVIOUR — what the
# front door actually prints for a given world — never on the presence of a string in the source.
#
#   §1  TOLD, NOT SENSED. REPO_DIR may come from --dir, the REPO_DIR env var, or $0's own tree —
#       never from the filesystem AROUND the process. The lane plants a .kickoff/core.lock in an
#       ANCESTOR of the cwd (pinning the INVOKING engine, so any ambient sensing flips the answer
#       to a false "IS the pin") and asserts it changes neither the resolved target NOR THE VERDICT.
#       Both halves are needed: the resolved-target half reads the PRE-EXISTING `repo=` banner and
#       can only see a walk that moves the target, so a walk one layer in — the predicate itself
#       looking around for a lock the named repo does not have — left the banner right and the
#       verdict a lie, and passed the whole suite (mutation-proved).
#   §2  engine_is_the_pin's four outcomes, each separately observable: IS · NOT · CANNOT DETERMINE
#       · NO PIN — its env-immunity (KICKOFF_CORE_DIR/REPO_DIR/KICKOFF_RUNNING_DIR pointing at the
#       pinned engine must NOT make a different running engine claim to be it), the fact that the
#       verdict is a WHOLE-COMMIT comparison (not a path, and not a prefix of a commit), and A
#       LANE PER REACHABLE FAIL-CLOSED ARM — with the two UNREACHABLE ones named and accounted for
#       in the DECLARED GAP below, rather than left to look like oversights. That is the point of
#       the section, not a completeness exercise: every arm on which the predicate declines to
#       answer turns into a tick on an UNKNOWN under a one-line edit in its own branch, and an
#       unlaned arm cannot see it. Each lane asserts the VERDICT CLASS the operator acts on, not
#       merely a sentence that happens to appear — see lane_cannot_determine() for why.
#   §3  The report reaches status · verify · doctor · pull, and NEITHER green tick (status' "core
#       pin HOLDS", verify's "core.lock COHERENT") stands bare — beside a WRONG engine or beside
#       one whose identity could not be determined. pull is the one that MOVES the pin, so its
#       report is also asserted to come BEFORE the first fetch, not after.
#   §4  NO OVER-CLAIM: a running engine at the pinned COMMIT but on a DIRTY tree is not the pin
#       (preflight.sh #6's own definition of a satisfied pin is HEAD == commit AND the tag resolves
#       to it AND the tree is clean). A tick there would be the whole bug again, one layer in.
#
# ── FIXTURE = THE DEPLOY TOPOLOGY, NEVER THIS DEV CHECKOUT ───────────────────────────────────────
# Two REAL engine clones at two different tags/commits + a repo pinned to one of them — the shape
# `kickoff pull` actually leaves on a box (~/kickoff-versions/core-vX). A fixture built out of this
# working tree would go green while the bug is live: the dev checkout IS its own engine, so "the
# running engine is not the pin" cannot even be expressed there.
#
# EXPLICITLY OUT OF SCOPE (do not add it here): handover / re-exec to the pinned engine. This slice
# is REPORTING ONLY — no new refusal, no new exit code, no exec. The three existing PIN-REDIRECT
# blocks (cmd_adopt/cmd_doctor/cmd_up) are covered by scripts/pin-redirect-selftest.sh and are not
# this suite's business.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
KO="$HERE/kickoff"

# self-scrub: a pre-set env var WINS over a fixture's instance.env by design, so ambient live values
# must never leak into a lane (the adopt/doctor selftest idiom).
unset REPO_DIR KICKOFF_CORE_DIR KICKOFF_CORE_REMOTE KICKOFF_RUNNING_DIR KICKOFF_RUNNING_SELF MC_STATE_FILE \
      MC_TRACKER_FILE MEMORY_DB MEMORY_HOOK_LOG MEMORY_DIR MEMORY_INDEX TELEGRAM_STATE_DIR \
      CHANNEL_SPEC REGROUND_PROMPT PERMISSION_MODE EFFORT MODEL MAX_CONCURRENT_AGENTS \
      DEPLOY_BRANCH CADENCE INSTANCE_ENV 2>/dev/null || true

PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }

# ── ASSERT THE VERDICT CLASS, NOT MERELY A SENTENCE ─────────────────────────────────────────────
# Every fail-closed arm is asserted through this helper, and the reason is a proved miss: asserting
# an arm's SENTENCE is NOT enough. A ONE-TOKEN downgrade of an arm's verdict (UNKNOWN → NO-PIN)
# keeps every word of its sentence — so a sentence-only lane stays green — while it
#   · drops the "⚠ CANNOT DETERMINE" prefix, which is the thing the operator actually ACTS on, and
#   · silences _pin_speaker_suffix (which emits NOTHING for NO-PIN), putting a BARE
#     "✓ core pin HOLDS" back beside an engine of unestablished identity.
# That is the original live bug, restored, with the suite fully green. Mutation-proved on a real
# fixture: `EITP_VERDICT="NO-PIN"` prepended to the cleanliness-unverifiable arm survived 45/0.
#
# So a lane binds the CLASS and the arm's OWN sentence to the SAME LINE. Neither half alone is a
# lane: the class alone passes on a neighbouring arm's wording, and the sentence alone survives the
# downgrade. Only the pair is what the operator reads.
CD_CLASS="CANNOT DETERMINE whether the running engine is this repo's pinned engine"
lane_cannot_determine() {   # $1 = front-door output   $2 = this arm's OWN phrase   $3 = lane name
  local _out="$1" _phrase="$2" _desc="$3" _line
  case "$_out" in
    *"IS this repo's pinned engine"*)
      bad "$_desc — an \"IS the pin\" TICK was printed on an arm that established nothing"; return 0 ;;
  esac
  _line="$(printf '%s\n' "$_out" | /usr/bin/grep -F "⚠ $CD_CLASS" | head -n1)"
  if [ -z "$_line" ]; then
    bad "$_desc — the operator was never given the ⚠ CANNOT DETERMINE VERDICT CLASS (a one-token downgrade to NO-PIN keeps this arm's sentence, drops the ⚠ and the speaker-suffix, and lets a BARE \"✓ core pin HOLDS\" stand beside an engine of unestablished identity)"
    return 0
  fi
  case "$_line" in
    *"$_phrase"*) ok "$_desc" ;;
    *) bad "$_desc — the ⚠ CANNOT DETERMINE line does not carry this arm's OWN sentence (\"$_phrase\"), so the lane would pass on a neighbouring arm's wording" ;;
  esac
  return 0
}

# …AND THE SAME BINDING FOR THE TWO GLYPHS AN OPERATOR ACTUALLY SCANS FOR.
# lane_cannot_determine() above bound the ⚠ class to its arm's sentence — and for a while that was
# the ONLY class so bound. The ✗ of NOT and the ✓ of IS, which are the marks a reader's eye lands
# on first, were asserted by nothing but a bare substring match anywhere in the whole output. Two
# ways that fails, both of them the shape this suite exists to catch:
#   · the ✗/✓ GLYPH is unasserted — swap mark_no for mark_warn (or mark_ok for log) in
#     _report_running_engine and every word survives while the operator's visual verdict changes;
#   · the sentence is unbound to the class — a NOT lane matching only "is NOT this repo's pinned
#     engine" passes when a DIFFERENT NOT arm fires (dirty instead of commit-differs), so the lane
#     certifies a verdict it never checked the reason for.
# So: glyph + class + this arm's own sentence, on ONE line, or it is not a lane.
IS_CLASS="the running engine IS this repo's pinned engine"
NOT_CLASS="the running engine is NOT this repo's pinned engine"
_lane_glyph() {   # $1=out $2=glyph $3=class $4=arm phrase $5=desc $6=the other verdict's marker
  local _out="$1" _glyph="$2" _class="$3" _phrase="$4" _desc="$5" _forbid="$6" _line
  case "$_out" in
    *"$_forbid"*) bad "$_desc — the CONTRADICTORY verdict (\"$_forbid\") was printed instead"; return 0 ;;
  esac
  _line="$(printf '%s\n' "$_out" | /usr/bin/grep -F "$_glyph $_class" | head -n1)"
  if [ -z "$_line" ]; then
    bad "$_desc — no line carries the VERDICT CLASS with its \"$_glyph\" glyph (\"$_glyph $_class\"); the mark the operator scans for is what changes, and a lane that matches the sentence alone survives its removal"
    return 0
  fi
  case "$_line" in
    *"$_phrase"*) ok "$_desc" ;;
    *) bad "$_desc — the \"$_glyph\" verdict line does not carry this arm's OWN sentence (\"$_phrase\"), so the lane would pass on a different arm of the same class: $_line" ;;
  esac
  return 0
}
lane_not() { _lane_glyph "$1" "✗" "$NOT_CLASS" "$2" "$3" "✓ $IS_CLASS"; }
lane_is()  { _lane_glyph "$1" "✓" "$IS_CLASS"  "$2" "$3" "✗ $NOT_CLASS"; }

command -v git >/dev/null 2>&1 || { printf '  ❌ git not found\n'; exit 1; }
[ -r "$KO" ] || { printf '  ❌ scripts/kickoff not readable\n'; exit 1; }

T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT

# ── THE MUTANT TABLE, WRITTEN DOWN BECAUSE THE LAST ONE DID NOT SURVIVE ITS AGENT ────────────────
# A previous round of this work reported "17 mutants planted, 17 killed" in a commit body and named
# exactly one of them; the list existed nowhere in the repo, and the next agent had to RECONSTRUCT
# it and say honestly that it was "equivalent in intent, not provably the same 17". So the strongest
# evidence this file produces about whether it can FAIL was unreproducible a day later. It is
# written here instead. Each line is a SINGLE exact edit to scripts/kickoff; apply it, run this
# suite, and the stated outcome is what you must see. LAST REPLAYED IN FULL (every line below, in
# one pass, against this HEAD): 44 mutants, 38 KILLED, 6 SURVIVED — every survivor adjudicated
# below, none of them silent, and every number on the right is from THAT replay, not carried over.
#
#   KILLED (the guard is load-bearing, and this suite is what proves it):
#     EITP_VERDICT="NO-PIN" prepended to the running-cleanliness-unverifiable arm  → 121/2
#     _eitp_git's body reduced to `git "$@"` (the whole environment seal gone)     → 106/19
#     `if [ "$_tagc" != "$EITP_LOCK_COMMIT" ]` → `if false`                        → 122/1
#     EITP_VERDICT="IS" prepended to the tag-unresolvable-here arm                 → 119/4
#     the HEAD comparison keyed on $EITP_RUNNING (a PATH) instead of the commit    → 87/38
#     the HEAD comparison reduced to a one-character PREFIX                        → 121/2
#     `-q --verify` dropped from the HEAD read (the echo-back trap)                → 122/1
#     `-q --verify` dropped from the tag read (the echo-back trap)                 → 119/4
#     the tag read un-scoped from refs/tags/ back to a bare `<value>^{commit}`      → 120/3
#     the ✓'s valueless-`tag`-line clause branch deleted (3 worlds, 2 sentences)    → 119/4
#     cmd_status' core-pin `status --porcelain` back to UNSEALED `git`              → 122/1
#     cmd_verify's core.lock `status --porcelain` back to UNSEALED `git`            → 122/1
#     the `rev-parse --show-prefix` git-root guard → `if false`                    → 120/3
#     the `rev-parse --show-toplevel` == RUNNING guard → `if false`                → 122/1
#     …that same guard neutered AND the old "this tree is its own git root"
#     wording restored in the ✓ (the clause `core.worktree` falsifies)             → 120/3
#     `_eitp_trim` removed from the lock parser (CRLF / trailing spaces)           → 121/2
#     the `"format "*)` decline arm made unreachable (any format read as 2)        → 121/2
#     the `$_suppressed` index-bit check → `if false`                              → 121/2
#     mark_ok → log on the IS verdict (the ✓ glyph)                                → 105/18
#     mark_no → mark_warn on the NOT verdict (the ✗ glyph)                         → 102/21
#     _pin_speaker_suffix silenced for NOT (the ORIGINAL live bug, restored)       → 121/2
#     _pin_speaker_suffix silenced for the UNKNOWN case                            → 121/2
#     an upward $PWD walk for a core.lock reintroduced into the predicate          → 122/1
#     EITP_VERDICT="IS" prepended to the lock-legacy arm                           → 122/1
#     `env -i` downgraded to `env` in _eitp_git (allowlist → passthrough)          → 113/10
#     `--no-replace-objects` dropped from _eitp_git                                → 121/2
#     GIT_CONFIG_SYSTEM=/dev/null dropped from _eitp_git                           → 119/6
#     the PATH carry dropped from _eitp_git (`env -i` with no PATH at all)         → 122/1
#     the `[ ! -f "${KICKOFF_RUNNING_SELF:-}" ]` executing-file assertion → `if false` → 121/2
#     the `EITP_RUNNING=""` blanking removed from the running-self-not-a-file arm  → 122/1
#     ", no tracked file differs from it" put back into the ✓                      → 121/2
#     the ✓'s tag clause made unconditional again                                  → 116/7
#     the ✓'s "REPORTED, NOT PROVED" clause restated as "clean tree — VERIFIED"    → 120/3
#     the ✓'s IDENTITY clause removed (identity back out of the REPORTED tier)     → 120/3
#     the "running:" line's "resolved ITSELF to … reported, not proved" qualifier  → 121/2
#     the report's "does NOT detect:" scope line deleted                           → 122/1
#     the report's "detects:" scope line deleted                                   → 122/1
#     the scope line kept but its named routes replaced with "everything else"     → 122/1
#
#   SURVIVED (all six adjudicated — see the DECLARED GAP blocks below for the argument):
#     EITP_VERDICT="IS" in the repo-unspecified arm          — arm unreachable from any verb
#     EITP_VERDICT="IS" in the running-unresolved arm        — arm unreachable from any verb
#     the self-inside-RUNNING `case` neutered to `*) ;;`     — arm unreachable on a GNU userland
#     the `[ ! -e "$EITP_RUNNING/.git" ]` guard → `if false` — EQUIVALENT (--show-prefix and
#                                                             --show-toplevel both cover it)
#     GIT_CONFIG_GLOBAL=/dev/null dropped from _eitp_git     — EQUIVALENT (`env -i` drops HOME/XDG)
#     `_eitp_safe` dropped from the lock's `commit` value    — a REAL, pre-existing, unlaned gap
#   The last two of those were re-measured against the pre-change engine and SURVIVED there too, so
#   they are gaps this suite has always had, not regressions introduced with the guards above.

printf '▶ engine identity — which engine is SPEAKING, and is it the one the repo pinned?\n\n'

# ── the deploy topology: two real engine clones at two tags ─────────────────────────────────────
# Each is a genuine git clone carrying the WORKING-TREE front door (the code under test), given its
# own distinguishing commit + tag so the two engines are at DIFFERENT commits — exactly the
# ~/kickoff-versions/core-v0.24 vs core-v0.25 shape that produced the live bug.
# MKENGINE_WHY carries the REASON out. Every step here used to end in `2>/dev/null || return 1`,
# so the caller could only print "could not build engine A fixture" — a fail-closed guard that
# discarded the one thing needed to act on it. Cost, 2026-08-27: a second machine hit exactly this
# and the only way forward was the maintainer guessing across boxes (root? git identity? disk?),
# three of which were wrong. A guard may refuse; it may not refuse ANONYMOUSLY.
MKENGINE_WHY=""
mkengine() {   # $1 = dir  $2 = tag  $3 = marker text  $4 = 1 to leave detached at the tag
  local _e
  MKENGINE_WHY=""
  _e="$(git clone -q --local "$REPO" "$1" 2>&1)" \
    || { MKENGINE_WHY="git clone --local failed: ${_e:-<no stderr>}"; return 1; }
  _e="$(cp "$KO" "$1/scripts/kickoff" 2>&1)" \
    || { MKENGINE_WHY="could not place the kickoff front door: ${_e:-<no stderr>}"; return 1; }
  printf '%s\n' "$3" > "$1/ENGINE-MARKER" \
    || { MKENGINE_WHY="could not write ENGINE-MARKER into $1 (disk full? read-only?)"; return 1; }
  _e="$(
    cd "$1" \
      && git add -A \
      && git -c user.email=t@t -c user.name=t commit -q -m "$3" \
      && git tag -f "$2" \
      && { [ "$4" = 1 ] && git checkout -q --detach "$2" || true; }
  2>&1 )" || { MKENGINE_WHY="commit/tag/detach failed: ${_e:-<no stderr>}"; return 1; }
  # a real pinned core is a clean clone; a stray instance.env would pin KICKOFF_CORE_DIR at the
  # ORIGIN and mask the very resolution under test (the core-resolution-selftest lesson).
  [ -e "$1/.kickoff/instance.env" ] \
    && { MKENGINE_WHY="the clone carries .kickoff/instance.env — it would pin KICKOFF_CORE_DIR at the ORIGIN and mask the resolution under test"; return 1; }
  return 0
}

ENGA="$T/engine-A"   # the INVOKING (stale) engine — stays on its branch so `status` with no --dir
                     # is not swallowed by the pure-pull guard (that guard is pin-redirect's lane).
ENGB="$T/engine-B"   # the PINNED engine — detached at its tag, exactly as `kickoff pull` leaves it.
mkengine "$ENGA" core-vENGA "engine A (the stale front door)" 0 \
  || { printf '  ❌ could not build engine A fixture — %s\n' "${MKENGINE_WHY:-no reason captured}"
       printf '     env: git %s · %s · TMPDIR=%s · free on that fs: %s\n' \
       "$(git --version | awk '{print $3}')" "$(uname -m)" "${TMPDIR:-/tmp}" \
       "$(df -h "$T" 2>/dev/null | tail -1 | awk '{print $4}')"; exit 1; }
mkengine "$ENGB" core-vENGB "engine B (the pinned engine)" 1 \
  || { printf '  ❌ could not build engine B fixture — %s\n' "${MKENGINE_WHY:-no reason captured}"
       printf '     env: git %s · %s · TMPDIR=%s · free on that fs: %s\n' \
       "$(git --version | awk '{print $3}')" "$(uname -m)" "${TMPDIR:-/tmp}" \
       "$(df -h "$T" 2>/dev/null | tail -1 | awk '{print $4}')"; exit 1; }

CA="$(git -C "$ENGA" rev-parse HEAD 2>/dev/null || true)"
CB="$(git -C "$ENGB" rev-parse HEAD 2>/dev/null || true)"
[ -n "$CA" ] && [ -n "$CB" ] && [ "$CA" != "$CB" ] \
  || { printf '  ❌ fixture engines are not at two distinct commits — the whole suite would be vacuous\n'; exit 1; }
[ -z "$(git -C "$ENGA" status --porcelain 2>&1)" ] && [ -z "$(git -C "$ENGB" status --porcelain 2>&1)" ] \
  || { printf '  ❌ fixture engines are not clean — the no-over-claim lane could not distinguish\n'; exit 1; }

mkrepo() { mkdir -p "$1"; ( cd "$1" && git init -q . \
  && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init ) >/dev/null 2>&1; }

# write a format-2 whole-tree core.lock ($1 = repo, $2 = tag, $3 = commit) — byte-shape identical
# to _write_core_lock's output in scripts/kickoff.
pin() {
  mkdir -p "$1/.kickoff"
  { printf '# .kickoff/core.lock — WHOLE-TREE core pin (format 2). Verified by preflight #6.\n'
    printf 'format 2\n'; printf 'tag %s\n' "$2"; printf 'commit %s\n' "$3"; } > "$1/.kickoff/core.lock"
}

# THE repo under test: pinned to engine B, its instance.env naming engine B as the core clone.
R="$T/pinned-repo"; mkrepo "$R"
pin "$R" core-vENGB "$CB"
printf 'export KICKOFF_CORE_DIR="%s"\n' "$ENGB" > "$R/.kickoff/instance.env"

# run a named engine's front door with a scrubbed environment, from a chosen cwd.
# $1 = engine dir, $2 = cwd, then the argv.
run_from() {
  local _eng="$1" _cwd="$2"; shift 2
  ( cd "$_cwd" 2>/dev/null || cd / ; env -u REPO_DIR -u KICKOFF_CORE_DIR -u KICKOFF_RUNNING_DIR -u KICKOFF_RUNNING_SELF \
      -u TELEGRAM_STATE_DIR -u MEMORY_DIR -u MEMORY_INDEX -u MEMORY_DB -u MC_STATE_FILE \
      -u MC_TRACKER_FILE -u CHANNEL_SPEC -u INSTANCE_ENV \
      timeout 180 bash "$_eng/scripts/kickoff" "$@" 2>&1 )
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
printf '1. TOLD, NOT SENSED — the filesystem AROUND the process may never establish the target\n'
# ════════════════════════════════════════════════════════════════════════════════════════════════
# The ancestor is BAITED: its planted core.lock pins engine A — the very engine doing the invoking.
# So if ANY ambient resolution (an upward walk, a $PWD probe, an ancestor .kickoff discovery, a
# registry lookup) ever creeps back in, the verdict flips from "NOT the pin" to a false "IS the
# pin" and every lane here goes RED. That is the failure mode this lane exists to catch, and it is
# a BEHAVIOUR, not a grep for a banned string.
ANC="$T/baited-ancestor"; mkrepo "$ANC"
pin "$ANC" core-vENGA "$CA"
printf 'export KICKOFF_CORE_DIR="%s"\n' "$ENGA" > "$ANC/.kickoff/instance.env"
CWD="$ANC/deep/nested/cwd"; mkdir -p "$CWD"

out_amb="$(run_from "$ENGA" "$CWD" status)"
case "$out_amb" in
  *"repo=$ANC"*) bad "AMBIENT RESOLUTION: with no --dir and no REPO_DIR, the front door resolved the baited ANCESTOR of the cwd — the upward walk is back" ;;
  *"repo=$ENGA"*) ok "no --dir, no REPO_DIR → the target is \$0's OWN tree, not the baited ancestor of the cwd" ;;
  *) bad "could not tell which repo was resolved (output named neither the ancestor nor \$0's tree):
       $(printf '%s' "$out_amb" | tail -3)" ;;
esac

# …and the VERDICT that walk would corrupt, for the SAME run. The `repo=` header above is the
# PRE-EXISTING status banner, and it can only see a walk that moves the RESOLVED TARGET. A walk
# that creeps back one layer in — engine_is_the_pin finding no lock at the named repo and
# looking AROUND for one — leaves the header correct and turns the verdict into a lie: the only
# core.lock within reach of this cwd is the baited ancestor's, which pins engine A, which is the
# engine doing the running. MUTATION-PROVED: an upward walk added to the predicate's lock lookup
# passed all 32 lanes of the suite while printing "✓ IS this repo's pinned engine" right here.
case "$out_amb" in
  *"IS this repo's pinned engine"*)
    bad "AMBIENT: with no --dir the front door ticked \"IS the pin\" — the only lock in reach is the BAITED ANCESTOR's, so something sensed it" ;;
  *"no pin to compare the running engine against"*)
    ok "no --dir → the VERDICT too reads \$0's own tree (which carries no pin), never the baited ancestor's lock" ;;
  *) bad "no engine-identity verdict on the ambient run — the lane cannot see the walk it exists to catch:
       $(printf '%s' "$out_amb" | tail -3)" ;;
esac

out_dir="$(run_from "$ENGA" "$CWD" status --dir "$R")"
case "$out_dir" in
  *"repo=$R"*) ok "--dir wins over a baited ancestor of the cwd (the named repo is the target)" ;;
  *) bad "--dir did NOT establish the target from inside a baited ancestor:
       $(printf '%s' "$out_dir" | tail -3)" ;;
esac

out_env="$(cd "$CWD" && env -u KICKOFF_CORE_DIR -u TELEGRAM_STATE_DIR -u MEMORY_DIR -u MEMORY_INDEX \
             -u MC_STATE_FILE -u CHANNEL_SPEC REPO_DIR="$R" timeout 180 bash "$ENGA/scripts/kickoff" status 2>&1)"
case "$out_env" in
  *"repo=$R"*) ok "the REPO_DIR env var wins over a baited ancestor of the cwd" ;;
  *) bad "REPO_DIR did NOT establish the target from inside a baited ancestor:
       $(printf '%s' "$out_env" | tail -3)" ;;
esac

# THE VERDICT LANE — the sharpest form of the same question. The ancestor pins engine A; engine A is
# what is running. Sensing would say "IS the pin". Identity says "NOT the pin", because the repo the
# user NAMED pins engine B.
lane_not "$out_dir" "but this repo pins ${CB:0:12}" \
  "a baited ancestor pinning the RUNNING engine does not flip the verdict — the named repo's pin is the only one read"

# ════════════════════════════════════════════════════════════════════════════════════════════════
printf '\n2. THE FOUR OUTCOMES — IS · NOT · CANNOT DETERMINE · NO PIN, each separately reportable\n'
# ════════════════════════════════════════════════════════════════════════════════════════════════
# NOT — engine A reporting on a repo pinned to engine B. This IS the live bug's exact shape.
out_not="$(run_from "$ENGA" "$T" status --dir "$R")"
lane_not "$out_not" "the running engine is commit ${CA:0:12}… but this repo pins ${CB:0:12}" \
  "NOT: the stale engine says plainly — with the ✗ the operator scans for — that it is not the repo's pinned engine, and names both commits"

# THE REMEDY TRAVELS WITH THE VERDICT — a finding with no next step is an obstacle, not a gate.
# The NOT arm named both engines and stopped there, which leaves an operator reading it on a phone
# to work out what to type. Two things are asserted, and the second matters as much as the first:
# the fix line exists, and it does NOT name `kickoff pull` — that verb re-enters the very front door
# the verdict just called wrong, so it would nag forever while changing nothing.
# HONEST LIMIT OF THIS LANE: it is a substring test, so it cannot tell a recommendation from a
# warning-off. It fires on the STRING, which is why the remedy describes the anti-remedy in words
# ("the pull that brought you here") instead of naming the verb. That keeps the check unambiguous
# at the cost of not proving intent — a stronger lane would have to parse the sentence.
case "$out_not" in
  *"fix:"*) : ;;
  *) bad "NOT carries no remedy — the operator is told which engine is wrong and never what to do about it" ;;
esac
_fix_line="$(printf '%s\n' "$out_not" | /usr/bin/grep -F "fix:" | head -n1)"
case "$_fix_line" in
  *"kickoff pull"*)
    bad "the remedy says \`kickoff pull\`, which re-enters the SAME front door this verdict just called wrong — a remedy that cannot work is worse than none" ;;
  *"$ENGA"*)
    ok "NOT carries a remedy naming the running engine, and does not send the operator back through the stale front door" ;;
  *)
    bad "the remedy does not name the running engine ($ENGA), so it cannot be acted on without more digging: $_fix_line" ;;
esac
# …and the IDENTITY LINE — "  running: <tree> @ <sha>…" — is what tells the operator WHICH tree is
# speaking, so it has to be asserted ON THAT LINE. Matching $ENGA anywhere in the whole output is
# THEATRE: the NOT speaker-suffix, the core-pin section header and the status banner all carry the
# same path, so the identity line could be blanked entirely and the lane would stay green.
# MUTATION-PROVED: replacing $EITP_RUNNING in that line with a literal "(redacted)" left the suite
# at 45 passed, 0 failed. The line is also asserted to carry the running engine's own COMMIT — the
# whole point of the line is that the operator can see which CODE is speaking, not just from where.
_id_line="$(printf '%s\n' "$out_not" | /usr/bin/grep -F '  running: ' | head -n1)"
if [ -z "$_id_line" ]; then
  bad "NOT: there is no \"running: …\" identity line at all — the operator cannot see WHICH tree is speaking"
else
  case "$_id_line" in
    *"$ENGA"*"${CA:0:12}"*) ok "NOT: the IDENTITY LINE itself names the running engine AND the commit it is at" ;;
    *"$ENGA"*) bad "NOT: the identity line names the running engine but not the commit it is at — the operator cannot see which CODE is speaking: $_id_line" ;;
    *) bad "NOT: the identity line does not name the running engine (matching \$ENGA elsewhere in the output — the speaker-suffix, the banner — is not the identity line): $_id_line" ;;
  esac
fi

# ── THE DECLARED SCOPE, PRINTED WHERE THE OPERATOR READS THE VERDICT ────────────────────────────
# Seven adversarial rounds hardened this predicate against an adversary it was never built for —
# `exec -a`, a planted argv0, a config key that silences `git status`, refs/replace — and every one
# of those findings was real and none of them was the stale symlink the thing exists to catch. The
# terminating condition is not another seal; it is SAYING WHAT THIS DETECTS, so that anything
# outside it is out of scope BY DECLARATION rather than by omission.
#
# It is asserted as OUTPUT, not as a source comment, because the operator is who acts on the ✓ and
# they will never read the comment. Both halves are bound: the accident class it DOES detect (or
# the declaration is a bare disclaimer), and the deliberate routes it does NOT (or "out of scope"
# is a word with nothing behind it). The pointer to the CONTENT PROOF is required too — a limit
# with no named way out reads as a dead end rather than as the next slice.
_scope_pos="$(printf '%s\n' "$out_not" | /usr/bin/grep -F '  detects: ' | head -n1)"
_scope_neg="$(printf '%s\n' "$out_not" | /usr/bin/grep -F '  does NOT detect: ' | head -n1)"
case "$_scope_pos" in
  *"MISMATCH REACHED BY ACCIDENT"*symlink*) ok "DECLARED SCOPE: the report says what it DOES detect — an engine-version mismatch reached by ACCIDENT, naming the rotted symlink that produced the live bug" ;;
  "") bad "DECLARED SCOPE: no \"detects:\" line — the operator is given a verdict with no statement of what it covers" ;;
  *)  bad "DECLARED SCOPE: the \"detects:\" line does not name the ACCIDENT class it exists for: $_scope_pos" ;;
esac
if [ -z "$_scope_neg" ]; then
  bad "DECLARED SCOPE: no \"does NOT detect:\" line — an undeclared limit is a lie waiting to be found, and this is the line that declares it"
else
  _missing=""
  # refs/replace is deliberately NOT in this list: the call site passes --no-replace-objects, so it
  # is DETECTED (laned below). Requiring it here made the suite enforce a disclaimer of a capability
  # the code has — a lane certifying the report into being wrong, which is this suite's own disease.
  # '$PATH' is here because the final review REPRODUCED it (a `git` shim earlier on PATH that strips
  # --no-replace-objects and lies on --porcelain) and NOBODY HAD NAMED IT. A reproduced route missing
  # from the line whose whole job is naming them is exactly the lie this declaration exists to stop.
  for _route in 'exec -a' 'bash -s' 'core.trustctime' '$PATH'; do
    case "$_scope_neg" in *"$_route"*) : ;; *) _missing="$_missing $_route" ;; esac
  done
  case "$_scope_neg" in *"git ls-tree"*) : ;; *) _missing="$_missing <the content-proof pointer>" ;; esac
  # …and the pointer must not be offered as the cure for the argv0 half, which it is not: a content
  # proof re-hashes the tree $0 NAMED, so a lie about $0 survives it untouched.
  case "$_scope_neg" in *"NO in-process remedy"*) : ;; *) _missing="$_missing <the argv0 half has no remedy>" ;; esac
  # The report must NOT disclaim a route it actually closes. Assert the POSITIVE phrase rather than
  # the absence of the word: `refs/replace` legitimately appears in this line saying it IS detected,
  # so "does the word appear" cannot tell right from wrong — and an ORDER-dependent glob over the
  # disclaimer clause is worse: the first version of this check expected `refs/replace` BEFORE
  # ".git/config" and sat green against a mutant that listed it after. Bind the claim, not the token.
  case "$_scope_neg" in
    *'refs/replace'*'IS detected'*) : ;;
    *) _missing="$_missing <refs/replace: the line must state it IS detected, not disclaim it>" ;;
  esac
  if [ -n "$_missing" ]; then
    bad "DECLARED SCOPE: the \"does NOT detect:\" line is wrong on:$_missing — a scope statement that omits a real limit, or disclaims a capability it has, declares nothing: $_scope_neg"
  else
    ok "DECLARED SCOPE: the report names every known DELIBERATE route as out of scope (exec -a · bash -s · core.trustctime · a \$PATH git shim), gives each half its OWN remedy (content proof / none), and does not disclaim refs/replace, which it detects"
  fi
fi

# IS — engine B, the pinned engine, reporting on the same repo. The ✓ is bound to the IS arm's own
# sentence, which now STATES ITS OWN SCOPE: an identity tick that leaves what it did and did not
# check implicit is how "clean" silently came to mean "`git status` printed nothing" (see the
# index-suppression lane below). If the scope clause is dropped, this goes red.
out_is="$(run_from "$ENGB" "$T" status --dir "$R")"
lane_is "$out_is" "ESTABLISHED for the tree at $ENGB: git resolves that same path as its work-tree root (so every answer below is about it, not an enclosing or relocated tree), its HEAD is ${CB:0:12}" \
  "IS: the pinned engine says plainly — with the ✓ the operator scans for — that it IS the pin, and the tick names what it ESTABLISHED"
case "$out_is" in
  *"NOT verified: the content of the tracked files"*"files git ignores"*)
    ok "IS: the tick also names what it did NOT verify (tracked-file CONTENT, and ignored files), rather than implying a total claim" ;;
  *) bad "IS: the tick states no scope — an identity claim that does not say what it left unchecked reads as a claim about everything" ;;
esac
# ── AND THE CLAUSE IT MAY NEVER MAKE AGAIN: A CONTENT PROOF IT DID NOT COMPUTE ──────────────────
# The ✓ used to end "…no tracked file differs from it and no index bit suppresses a comparison",
# which is a claim about the BYTES ON DISK. Nothing in this predicate hashes a byte — it asks
# `git status` and repeats the answer — and there are two REPRODUCED worlds where that answer is
# silence over tampered TRACKED content (core.trustctime=false + a same-size in-place rewrite,
# laned below; and refs/replace, laned below). The fix is not another seal, it is not saying it.
# This lane is a NEGATIVE assertion because that is what the defect was: an extra clause, not a
# missing one. It is bound to the ✓ line so it cannot be satisfied by the sentence disappearing.
_is_line="$(printf '%s\n' "$out_is" | /usr/bin/grep -F "✓ $IS_CLASS" | head -n1)"
if [ -z "$_is_line" ]; then
  bad "TICK SCOPE: no ✓ IS line at all — the content-proof lane proves nothing"
else
  case "$_is_line" in
    *"no tracked file differs from it"*)
      bad "TICK SCOPE: the ✓ still claims \"no tracked file differs from it\" — a CONTENT proof this run never computed, and one that is FALSE under the two tampering lanes below" ;;
    *"(2) CLEANLINESS: \`git status\` reported no changes"*"not a proof of what this tree CONTAINS"*)
      ok "TICK SCOPE: the ✓ reports what \`git status\` SAID, attributed to this machine's configuration, and explicitly disclaims a content proof" ;;
    *) bad "TICK SCOPE: the ✓ neither claims a content proof nor carries the downgraded \`git status\` wording — the cleanliness clause is unaccounted for: $_is_line" ;;
  esac
fi
# …and the OPINION half must not be smuggled back as a fact of the tree. "clean tree" as a bare
# assertion is the wording that made this defect invisible for six rounds.
case "$_is_line" in
  *"clean tree — VERIFIED"*) bad "TICK SCOPE: the ✓ asserts \"clean tree — VERIFIED\" as a fact of the TREE rather than as what one program reported" ;;
  *) ok "TICK SCOPE: the ✓ no longer asserts \"clean tree — VERIFIED\" as a property of the tree" ;;
esac

# CANNOT DETERMINE — a LEGACY per-file core.lock records no commit, so the question is unanswerable.
# An honest \"could not determine\" is REQUIRED here; a tick would be the whole bug.
RLEG="$T/legacy-lock"; mkrepo "$RLEG"; mkdir -p "$RLEG/.kickoff"
printf '%s  scripts/kickoff\n' "0000000000000000000000000000000000000000000000000000000000000000" \
  > "$RLEG/.kickoff/core.lock"
lane_cannot_determine "$(run_from "$ENGA" "$T" status --dir "$RLEG")" \
  "is the LEGACY per-file format" \
  "CANNOT DETERMINE: a legacy per-file lock records no commit and is reported as unknown"

# CANNOT DETERMINE — a malformed format-2 lock (no commit key at all).
RBAD="$T/malformed-lock"; mkrepo "$RBAD"; mkdir -p "$RBAD/.kickoff"
printf 'format 2\ntag core-vENGB\n' > "$RBAD/.kickoff/core.lock"
lane_cannot_determine "$(run_from "$ENGA" "$T" status --dir "$RBAD")" \
  "is format 2 but records no \`commit\` key" \
  "CANNOT DETERMINE: a format-2 lock with no commit key is reported as unknown, not as a match"

# ── THE FAIL-CLOSED ARMS, one lane each ─────────────────────────────────────────────────────────
# Every arm below is a path on which the predicate DECLINES to answer. Each was laneless, and each
# mutates into a tick on an UNKNOWN — the one failure this whole slice exists to close — by the
# single edit `EITP_VERDICT="IS"` in its own branch, invisible to every other lane. So each gets a
# fixture that REACHES it and an assertion on the honest verdict, with the tick as an explicit
# failure arm (not merely an absent one), and each asserts the arm's OWN sentence — bound to the
# VERDICT CLASS on the same line, via lane_cannot_determine() — so it can neither pass on a
# neighbouring block's wording nor survive a one-token downgrade of the verdict itself.
#
# ── DECLARED GAP: two fail-closed arms have NO LANE, and cannot get an honest one ────────────────
# `repo-unspecified` and `running-unresolved` are the two arms with no lane below. That is written
# down here rather than papered over with a fixture that reaches them by a route the front door
# never takes. Neither is reachable THROUGH THE FRONT DOOR — verified in the code, not assumed:
#
#   · repo-unspecified (the predicate called with an empty repo). All four call sites pass a value
#     that cannot be empty: cmd_status, cmd_verify and cmd_doctor each pass "$target" only after
#     their own `[ -d "$target" ] || die "…: target is not a directory"`, and cmd_pull passes
#     "$REPO_DIR", which the startup block leaves non-empty unconditionally — it falls back to $0's
#     own tree, then HARD-EXITS ("FATAL: REPO_DIR does not exist or is not accessible") rather than
#     carrying an empty value forward.
#
#   · running-unresolved ($KICKOFF_RUNNING_DIR empty). It is assigned unconditionally at load as
#     `$(cd "$HERE/.." 2>/dev/null && pwd -P || true)`, where $HERE is the directory the executing
#     script was read from. To come back empty, the engine's own root would have to stop being
#     cd-able BETWEEN this script starting and that line running.
#
# Both arms are still worth keeping — they are what makes the predicate total — and both are
# DEFENCE IN DEPTH. A lane for either would need a fixture whose outcome depends on a filesystem
# race or on who is running it, and this suite has already refused exactly that kind of fixture
# once: the unreadable-lock lane uses a DIRECTORY rather than a mode-000 file, because a mode-000
# file reads fine as root and the lane would then go green or red by WHOSE UID ran it. A lane that
# passes for environmental reasons is worse than a gap that is written down.
#
# WHAT THIS COSTS, stated plainly so no one has to rediscover it: `EITP_VERDICT="IS"` planted in
# either of those two branches SURVIVES this suite. That is the price of not faking the lane. If a
# future change makes either arm reachable from a verb, it gets a lane in that SAME change.
#
# ── AND A THIRD, ADDED WITH THE EXECUTING-FILE GUARD, for exactly the same reason ────────────────
#   · running-self-outside-running (the executing file resolves, but not inside the tree that would
#     be reported as the running engine). Its SIBLING arm — running-self-not-a-file — IS laned, by
#     the $0-fabrication lane in §2, and that is the one the `bash -s` / `bash -c` route actually
#     reaches. This one is unreachable on a GNU userland and was MEASURED so, not assumed:
#     $KICKOFF_RUNNING_SELF and $HERE are both derived from the SAME `readlink -f "$0"` at the same
#     moment, and `readlink -f` returns a fully-resolved physical path — so the self file's
#     directory IS $HERE and its parent IS RUNNING, always. It becomes reachable only where
#     `readlink -f` does not exist (non-GNU userlands), where both fall back to the literal $0 and
#     a RELATIVE $0 then correctly fails the inside-RUNNING test rather than being trusted.
#     COST, measured: neutering that `case` to `*) ;;` SURVIVES this suite (97/0).
#
# ── TWO MORE SURVIVORS, PRE-EXISTING — measured against HEAD, not introduced by this slice ───────
# Both were confirmed to survive the suite AS IT STOOD BEFORE the executing-file/allowlist work, so
# they are gaps this suite has always had rather than regressions. Written down instead of quietly
# carried:
#   · the `[ ! -e "$EITP_RUNNING/.git" ]` git-root guard replaced by `if false` SURVIVES. It is a
#     genuinely EQUIVALENT mutant: the `rev-parse --show-prefix` guard immediately below covers
#     every world it covers (and more — that is why it was added), and a tree in no repository at
#     all still falls through to an empty HEAD read. Defence in depth, correctly redundant.
#   · `_eitp_safe` removed from the LOCK'S `commit` VALUE (the tag's sanitiser IS laned, by the
#     forged-content lane) SURVIVES. Not equivalent — a real gap. Bounded, not harmless: the commit
#     value never reaches git's argv (only the tag does) and is printed truncated to 12 characters,
#     so the reachable damage is at most a short forged fragment inside the report. It is named
#     here so the next change to that parser knows the lane is missing rather than assuming it is
#     covered by the tag's.

# CANNOT DETERMINE — the lock exists but is not a readable regular file. A DIRECTORY named
# core.lock is the deterministic shape of it (a mode-000 file reads fine as root, so it would make
# the lane environment-dependent).
RUNR="$T/lock-unreadable"; mkrepo "$RUNR"; mkdir -p "$RUNR/.kickoff/core.lock"
lane_cannot_determine "$(run_from "$ENGA" "$T" status --dir "$RUNR")" \
  "exists but is not a readable regular file" \
  "CANNOT DETERMINE: an unreadable core.lock is declined, and the report says the lock could not be read"

# CANNOT DETERMINE — an EMPTY core.lock. Distinct from legacy (which has content that records no
# commit) and from no-pin (which records nothing because there is no file).
REMP="$T/lock-empty"; mkrepo "$REMP"; mkdir -p "$REMP/.kickoff"; : > "$REMP/.kickoff/core.lock"
# NB: the asserted phrase is the IDENTITY report's own. The core-pin block separately prints
# "core.lock present but EMPTY" for this fixture, and matching that would pass vacuously.
lane_cannot_determine "$(run_from "$ENGA" "$T" status --dir "$REMP")" \
  "records no pin directives" \
  "CANNOT DETERMINE: a zero-byte core.lock records no commit, and is declined rather than matched"

# …and the SAME arm reached by a file that is NOT empty: a lock holding ONLY COMMENTS. The parser
# skips blank and `#` lines, so `_first` is empty for both worlds — which is why this one used to
# be reported to the operator as "is empty" about a 72-byte file that plainly is not. A report
# that misdescribes the artifact it is looking at sends the operator to hunt a missing file, so
# the arm now says what was actually established (no pin DIRECTIVES), and this lane holds it there.
RCMT="$T/lock-comments-only"; mkrepo "$RCMT"; mkdir -p "$RCMT/.kickoff"
{ printf '# .kickoff/core.lock — WHOLE-TREE core pin (format 2). Verified by preflight #6.\n'
  printf '\n'; printf '# (every directive line was stripped by a bad edit)\n'; } > "$RCMT/.kickoff/core.lock"
if [ ! -s "$RCMT/.kickoff/core.lock" ]; then
  bad "fixture: the comments-only lock is zero bytes — it would not be distinguishable from the empty lock above"
else
  out_cmt="$(run_from "$ENGA" "$T" status --dir "$RCMT")"
  lane_cannot_determine "$out_cmt" \
    "records no pin directives" \
    "CANNOT DETERMINE: a core.lock holding only comments is declined, like the empty one"
  case "$out_cmt" in
    *"$RCMT/.kickoff/core.lock is empty"*)
      bad "the identity report calls a $(/usr/bin/wc -c < "$RCMT/.kickoff/core.lock")-byte comments-only lock \"is empty\" — the operator is sent looking for a file that is right there" ;;
    *) ok "a comments-only core.lock is NOT described to the operator as \"empty\" — the report says what is actually true of the file" ;;
  esac
fi

# ── A LOCK IS UNTRUSTED INPUT: whitespace, an unknown format, and forged content ────────────────
# Three lanes on the PARSER, each of which produced a wrong operator-facing answer.
#
# (i) TRAILING WHITESPACE / CRLF. A lock written on Windows records `commit <sha>\r`; the \r is not
# part of the sha, so the comparison failed and the operator got a DEFINITE "✗ NOT the pin" naming
# two commits that are, in fact, the same one. That is precisely the "definite-sounding wrong
# diagnosis" the tag guard's own comment warns against, and it is worse than an honest unknown
# because it sends the operator to fix a pin that is not broken. Both engines here are the SAME
# engine, so the correct answer is a ✓ — the lane fails if the trim regresses.
RCRLF="$T/lock-crlf"; mkrepo "$RCRLF"; mkdir -p "$RCRLF/.kickoff"
printf 'format 2\r\ntag core-vENGB\r\ncommit %s\r\n' "$CB" > "$RCRLF/.kickoff/core.lock"
lane_is "$(run_from "$ENGB" "$T" status --dir "$RCRLF")" \
  "this repo pins ${CB:0:12}… — they MATCH, and refs/tags/core-vENGB" \
  "CRLF LOCK: a \\r line ending is not part of the sha — the pinned engine still reads ✓ IS the pin, not a definite ✗ against itself"
RTWS="$T/lock-trailing-space"; mkrepo "$RTWS"; mkdir -p "$RTWS/.kickoff"
printf 'format 2\ntag core-vENGB  \ncommit %s   \n' "$CB" > "$RTWS/.kickoff/core.lock"
lane_is "$(run_from "$ENGB" "$T" status --dir "$RTWS")" \
  "this repo pins ${CB:0:12}… — they MATCH, and refs/tags/core-vENGB" \
  "TRAILING SPACES: invisible trailing whitespace does not turn a satisfied pin into a definite ✗"

# (ii) AN UNKNOWN `format`. The parser accepted `format <anything>` as a format-2 whole-tree pin, so
# `format 1` and `format banana` were read with format-2 rules and TICKED. A lock this engine cannot
# read is exactly the case where a confident answer from it is worthless — most sharply when a NEWER
# engine wrote it. Both fixtures carry a commit that WOULD match, so only the format check can
# produce the honest answer.
for _fmt in 1 banana; do
  RFMT="$T/lock-format-$_fmt"; mkrepo "$RFMT"; mkdir -p "$RFMT/.kickoff"
  { printf 'format %s\n' "$_fmt"; printf 'tag core-vENGB\n'; printf 'commit %s\n' "$CB"; } > "$RFMT/.kickoff/core.lock"
  lane_cannot_determine "$(run_from "$ENGB" "$T" status --dir "$RFMT")" \
    "declares \`format $_fmt\`, which this engine does not know how to read" \
    "UNKNOWN FORMAT: \`format $_fmt\` is declined, not read with format-2 rules and ticked (the commit in it would have matched)"
done

# (iii) FORGED CONTENT. The lock's tag and commit were interpolated RAW into the operator's identity
# report, so a crafted lock could render a ✓ tick — the exact glyph the operator scans for — inside
# the ✗ sentence, and ESC sequences could repaint the line. The fixture writes the verdict sentence
# itself into the `tag` value.
RFORGE="$T/lock-forged"; mkrepo "$RFORGE"; mkdir -p "$RFORGE/.kickoff"
{ printf 'format 2\n'
  printf 'tag \342\234\223 the running engine IS this repo'\''s pinned engine\n'
  printf 'commit %s\n' "$CA"; } > "$RFORGE/.kickoff/core.lock"
# The lane is on the WHOLE output of each verb, not on the identity report alone: the forged ✓ first
# landed via the PRE-EXISTING core-pin block, which echoes the lock's tag into the very line that
# announces a BROKEN pin — so sanitising only the new report would have left the forgery renderable
# from the block right beneath it. status and verify are laned separately because each has its own
# copy of that echo.
for _fv in status verify; do
  out_forge="$(run_from "$ENGB" "$T" "$_fv" --dir "$RFORGE")"
  case "$out_forge" in
    *"✓ the running engine IS this repo's pinned engine"*)
      bad "FORGED TICK [$_fv]: a crafted core.lock rendered the ✓ IS-the-pin line in the output — untrusted lock content reaches the operator's verdict area raw" ;;
    *)
      lane_not "$out_forge" "but this repo pins ${CA:0:12}" \
        "FORGED TICK [$_fv]: a core.lock whose tag IS the green verdict sentence cannot render that tick anywhere in the output — lock values are sanitised before they are printed" ;;
  esac
done

# CANNOT DETERMINE — RUNNING is not a git ROOT. `git -C <dir> rev-parse HEAD` answers happily from
# a SUBDIRECTORY of a checkout, so an engine unpacked INSIDE some other repo would otherwise report
# that repo's commit as its own. The fixture is baited: the enclosing checkout sits at exactly the
# commit the repo pins, so asking git about the wrong tree yields a match.
OUTER="$T/outer-checkout"
git clone -q --local "$ENGB" "$OUTER" >/dev/null 2>&1
git -C "$OUTER" checkout -q --detach core-vENGB >/dev/null 2>&1
mkdir -p "$OUTER/nested-engine/scripts"
cp "$KO" "$OUTER/nested-engine/scripts/kickoff"
[ "$(git -C "$OUTER" rev-parse HEAD 2>/dev/null)" = "$CB" ] \
  || bad "fixture: the enclosing checkout is not at the pinned commit — the git-root lane would be vacuous"
out_nested="$(cd "$T" && env -u REPO_DIR -u KICKOFF_CORE_DIR -u KICKOFF_RUNNING_DIR -u TELEGRAM_STATE_DIR \
                -u MEMORY_DIR -u MEMORY_INDEX -u MC_STATE_FILE -u CHANNEL_SPEC \
                timeout 180 bash "$OUTER/nested-engine/scripts/kickoff" status --dir "$R" 2>&1)"
lane_cannot_determine "$out_nested" \
  "not the root of a git checkout" \
  "CANNOT DETERMINE: an engine that is not a git ROOT does not borrow the ENCLOSING checkout's commit"

# ── …AND A `.git` THAT EXISTS BUT IS NOT A USABLE GITDIR ────────────────────────────────────────
# The lane above is reached by a nested engine with NO `.git`. That guard asked `[ -e .git ]`, which
# is a PROXY for "is this its own repository root" — and it failed OPEN: a nested engine carrying a
# STRAY `.git` sailed past it, git skipped the unusable gitdir, walked UP, and answered about the
# enclosing checkout. All three shapes below were REPRODUCED printing the full false green
#     ✓ the running engine IS this repo's pinned engine — core-vENGB …, clean tree
# from a tree with no commits of its own at all. They are not exotic: (a) is what `mkdir .git`
# leaves, (b) is the interrupted-clone shape, (c) is a `.git` symlinked out of the tree.
#
# The enclosing checkout is BAITED exactly as above (it sits at the pinned commit), and the three
# nested dirs are EXCLUDED from it so the outer tree reads CLEAN — without that the dirty arm would
# rescue the verdict and the fixture would prove nothing about the root guard.
mkdir -p "$OUTER/.git/info"
printf 'nested-engine/\nstray-empty/\nstray-partial/\nstray-symlink/\n' > "$OUTER/.git/info/exclude"
mkdir -p "$OUTER/stray-empty/scripts" "$OUTER/stray-partial/scripts" "$OUTER/stray-symlink/scripts"
for _sd in stray-empty stray-partial stray-symlink; do cp "$KO" "$OUTER/$_sd/scripts/kickoff"; done
mkdir -p "$OUTER/stray-empty/.git"                                    # (a) empty .git directory
mkdir -p "$OUTER/stray-partial/.git/objects" "$OUTER/stray-partial/.git/refs"   # (b) interrupted clone
mkdir -p "$T/plain-not-a-gitdir"; ln -sfn "$T/plain-not-a-gitdir" "$OUTER/stray-symlink/.git"   # (c) symlink
for _sd in stray-empty stray-partial stray-symlink; do
  # NEGATIVE CONTROL PER SHAPE: assert this world REALLY IS the false green before the guard —
  # git must answer the pinned commit for the nested dir AND report a clean tree. If either stops
  # holding, the lane below would pass without the guard doing anything.
  _sd_head="$(git -C "$OUTER/$_sd" rev-parse -q --verify HEAD 2>/dev/null || true)"
  _sd_dirt="$(git -C "$OUTER/$_sd" status --porcelain 2>/dev/null || printf 'UNVERIFIABLE')"
  if [ "$_sd_head" != "$CB" ] || [ -n "$_sd_dirt" ]; then
    bad "fixture [$_sd]: the stray-.git engine does not borrow the enclosing checkout's PINNED commit on a clean tree (head='${_sd_head:-<none>}', dirt='${_sd_dirt}') — the lane would be vacuous"
    continue
  fi
  out_stray="$(cd "$T" && env -u REPO_DIR -u KICKOFF_CORE_DIR -u KICKOFF_RUNNING_DIR \
                 -u TELEGRAM_STATE_DIR -u MEMORY_DIR -u MEMORY_INDEX -u MC_STATE_FILE -u CHANNEL_SPEC \
                 timeout 180 bash "$OUTER/$_sd/scripts/kickoff" status --dir "$R" 2>&1)"
  lane_cannot_determine "$out_stray" \
    "its own .git is not a usable gitdir" \
    "STRAY .git [$_sd]: a \`.git\` that EXISTS but is not a usable gitdir is not a git root — the enclosing checkout's commit is not borrowed"
  # …and the IDENTITY LINE must not carry the borrowed sha either. The verdict being honest while
  # the line above it prints "<this engine> @ <someone else's commit>" is the same fabrication as
  # the env-poisoning arm, one layer up, and no verdict lane can see it.
  _sl="$(printf '%s\n' "$out_stray" | /usr/bin/grep -F '  running: ' | head -n1)"
  case "$_sl" in
    *"${CB:0:12}"*) bad "STRAY .git [$_sd]: the identity line prints this engine's path next to the ENCLOSING checkout's commit — a borrowed sha presented as this engine's own: $_sl" ;;
    *"$_sd"*) ok "STRAY .git [$_sd]: the identity line names the tree and carries NO borrowed commit" ;;
    *) bad "STRAY .git [$_sd]: there is no identity line naming the running tree: ${_sl:-<absent>}" ;;
  esac
done

# ── …AND AN EMPTY `--show-prefix` IS STILL NOT A GIT ROOT: `core.worktree` MOVES THE ROOT ────────
# The lane above closes "RUNNING is a SUBDIRECTORY of an enclosing checkout" — a NON-EMPTY prefix.
# `core.worktree = <somewhere else>` produces the opposite shape and walks straight past it: the
# cwd is not under the work tree at all, so the prefix is EMPTY, git reads HEAD fine, and `status`
# answers about the OTHER directory. REPRODUCED against the pre-change front door on this exact
# fixture: with core.worktree pointed at a pristine copy of the pinned commit and the ACTUAL
# running tree's tracked ENGINE-MARKER tampered, it printed
#     ✓ … ESTABLISHED: this tree is its own git root … `git status` reported no changes
# — both clauses true of the DECOY, false of the tree the code was executing from, and both sitting
# in the ESTABLISHED tier. That is not an unhelpful tick; it is a printed lie about a directory.
#
# The engine here is a LOCAL CLONE of engine B detached at the SAME pinned commit, so everything
# else about it checks out and the moved work tree is the only thing between this world and a ✓.
WTM="$T/engine-worktree-moved"
WTDECOY="$T/worktree-decoy"
if ! git clone -q --local "$ENGB" "$WTM" >/dev/null 2>&1 \
   || ! git -C "$WTM" checkout -q --detach "$CB" >/dev/null 2>&1; then
  bad "fixture [core.worktree]: could not build a clone of engine B detached at the pinned commit — the lane would be vacuous"
else
  mkdir -p "$WTDECOY"
  GIT_DIR="$WTM/.git" git checkout-index -a -f --prefix="$WTDECOY/" >/dev/null 2>&1
  printf 'TAMPERED — this is not what the pinned commit contains\n' >> "$WTM/ENGINE-MARKER"
  git -C "$WTM" config core.worktree "$WTDECOY" >/dev/null 2>&1
  # NEGATIVE CONTROLS — four, because every one of them is a way this lane could go green for a
  # reason that has nothing to do with the guard: the prefix must be EMPTY (so `--show-prefix`
  # genuinely cannot see this), HEAD must still read as the pinned commit, `status` must be SILENT
  # (the decoy is what git is diffing), and the two trees must really differ (or there is no lie).
  _wt_prefix="$(git -C "$WTM" rev-parse --show-prefix 2>/dev/null || printf 'PREFIX-FAILED')"
  _wt_head="$(git -C "$WTM" rev-parse -q --verify HEAD 2>/dev/null || true)"
  _wt_dirt="$(git -C "$WTM" status --porcelain 2>/dev/null || printf 'STATUS-FAILED')"
  _wt_real="$(cat "$WTM/ENGINE-MARKER" 2>/dev/null || true)"
  _wt_decoy="$(cat "$WTDECOY/ENGINE-MARKER" 2>/dev/null || true)"
  if [ -n "$_wt_prefix" ]; then
    bad "fixture [core.worktree]: \`rev-parse --show-prefix\` is NOT empty here (got '$_wt_prefix') — the existing git-root guard would already catch this and the lane would prove nothing new"
  elif [ "$_wt_head" != "$CB" ]; then
    bad "fixture [core.worktree]: HEAD does not read as the pinned commit (got '${_wt_head:-<none>}') — the lane would go green on the commit-differs arm instead"
  elif [ -n "$_wt_dirt" ]; then
    bad "fixture [core.worktree]: \`git status\` still reports the tamper (got '${_wt_dirt%%$'\n'*}') — the lane would be the ordinary dirty lane again"
  elif [ "$_wt_real" = "$_wt_decoy" ] || [ -z "$_wt_decoy" ]; then
    bad "fixture [core.worktree]: the running tree and the decoy work tree hold the SAME marker — there is no false claim for the lane to catch"
  else
    ok "NEGATIVE CONTROL [core.worktree]: with the work-tree root MOVED, \`--show-prefix\` is EMPTY, HEAD still reads the pinned commit, and \`git status\` is SILENT while the tree the code runs from carries a TAMPERED tracked file — the false green is one comparison away"
    out_wtm="$(run_from "$WTM" "$T" status --dir "$R")"
    lane_cannot_determine "$out_wtm" \
      "is not the work tree git resolves for it" \
      "core.worktree: a MOVED work-tree root is not \"this tree is its own git root\" — the answers would be about a different directory, so the verdict is declined, not ticked"
    # …and the clause itself, separately: no surviving line may tell the operator that the tree it
    # is running from is its own git root, because in this world that sentence is FALSE.
    case "$out_wtm" in
      *"this tree is its own git root"*)
        bad "core.worktree: a line still asserts \"this tree is its own git root\" about a tree whose work-tree root git resolves ELSEWHERE — the demoted clause is back" ;;
      *) ok "core.worktree: nothing on screen claims the running tree is its own git root (the clause a moved work-tree root falsifies is not printed here)" ;;
    esac
  fi
fi

# CANNOT DETERMINE — the running engine's HEAD cannot be read. `.git` is present (so the git-root
# arm above is passed) but DANGLING: the git-WORKTREE shape, a `gitdir:` FILE pointing at an
# administrative dir that is gone — what a copied or half-moved engine actually looks like on a
# box. rev-parse then writes nothing to stdout, and nothing is what must be reported.
BWT="$T/broken-worktree"; mkdir -p "$BWT/scripts"; cp "$KO" "$BWT/scripts/kickoff"
printf 'gitdir: %s/no-such-admin-dir/.git/worktrees/x\n' "$T" > "$BWT/.git"
if [ -n "$(git -C "$BWT" rev-parse HEAD 2>/dev/null || true)" ]; then
  bad "fixture: the dangling worktree still yields a HEAD — the head-unreadable lane would be vacuous"
else
  lane_cannot_determine "$(run_from "$BWT" "$T" status --dir "$R")" \
    "has no readable HEAD commit" \
    "CANNOT DETERMINE: an engine whose own HEAD is unreadable is declined, and the report says so"
fi

# CANNOT DETERMINE — a running engine that IS a git root but whose HEAD DOES NOT RESOLVE: a plain
# `git init` with NO COMMITS (an unborn HEAD). Same arm as the dangling worktree above, reached by
# a different world, and it earns its own lane because this is the ECHO-BACK trap — the one shape
# of unreadable HEAD that produced a FALSE GREEN rather than a wrong diagnosis.
#
# `git rev-parse HEAD` does NOT fail quietly on an unborn HEAD: it WRITES THE LITERAL STRING
# "HEAD" to stdout and exits 128. An unguarded `$(… 2>/dev/null || true)` capture is therefore
# NON-EMPTY, sails past the emptiness test, and compares EQUAL to a lock whose commit is the
# literal string "HEAD" — so the fixture pins exactly that. Before `rev-parse -q --verify` guarded
# that read, this world printed "✓ the running engine IS this repo's pinned engine" from an engine
# with ZERO COMMITS (reproduced live under `env -i`). It is the same trap already documented and
# fixed on the tag read below — one arm earlier, unguarded.
#
# The tree is deliberately kept CLEAN (everything excluded), so the dirty arm cannot be what
# rescues the verdict: the guarded read is the only thing between this world and a tick.
NOC="$T/engine-unborn-head"; mkdir -p "$NOC/scripts"; cp "$KO" "$NOC/scripts/kickoff"
( cd "$NOC" && git init -q . ) >/dev/null 2>&1
mkdir -p "$NOC/.git/info"; printf '*\n' > "$NOC/.git/info/exclude"
RNOC="$T/pinned-to-literal-HEAD"; mkrepo "$RNOC"; mkdir -p "$RNOC/.kickoff"
{ printf 'format 2\n'; printf 'commit HEAD\n'; } > "$RNOC/.kickoff/core.lock"
# NEGATIVE CONTROL ON THE FIXTURE: assert the trap is actually LIVE in this git before asserting
# the guard defeats it. If `rev-parse HEAD` ever stopped echoing the ref back, the lane below would
# pass for a reason that has nothing to do with the guard under test.
_noc_plain="$(git -C "$NOC" rev-parse HEAD 2>/dev/null || true)"
_noc_guarded="$(git -C "$NOC" rev-parse -q --verify HEAD 2>/dev/null || true)"
if [ "$_noc_plain" != "HEAD" ] || [ -n "$_noc_guarded" ] \
   || [ -n "$(git -C "$NOC" status --porcelain 2>/dev/null)" ]; then
  bad "fixture: the unborn-HEAD engine does not exhibit the echo-back on a CLEAN tree (plain='$_noc_plain', guarded='$_noc_guarded') — the false-green lane would be vacuous"
else
  lane_cannot_determine "$(run_from "$NOC" "$T" status --dir "$RNOC")" \
    "has no readable HEAD commit" \
    "ECHO-BACK: an engine with NO COMMITS is not the pin of a lock recording \`commit HEAD\` — an unguarded \`rev-parse HEAD\` echoes the ref back and the whole-string compare MATCHES"
fi

# CANNOT DETERMINE — the running engine is AT the pinned commit and its CLEANLINESS cannot be
# established. This is the sharpest of the fail-closed arms: everything the operator would look at
# agrees, and the one arm that would disqualify it (preflight #6's clean tree) is unanswerable. A
# broken index is the reachable shape — rev-parse still reads refs, `status` cannot run at all.
CLU="$T/cleanliness-unverifiable"
if git clone -q --local "$ENGB" "$CLU" >/dev/null 2>&1 \
   && git -C "$CLU" checkout -q --detach core-vENGB >/dev/null 2>&1; then
  rm -f "$CLU/.git/index"; mkdir -p "$CLU/.git/index"
fi
if [ "$(git -C "$CLU" rev-parse HEAD 2>/dev/null || true)" != "$CB" ] \
   || git -C "$CLU" status --porcelain >/dev/null 2>&1; then
  bad "fixture: the broken-index engine is not \"at the pinned commit with status failing\" — the cleanliness lane would be vacuous"
else
  out_clu="$(run_from "$CLU" "$T" status --dir "$R")"
  lane_cannot_determine "$out_clu" \
    "whether its tree is CLEAN could not be established" \
    "CANNOT DETERMINE: the pinned commit with UNVERIFIABLE cleanliness is declined, not ticked"
  # …and the CONSEQUENCE of the class, asserted separately, because it is the operator-visible
  # half. This fixture's pinned CLONE genuinely is coherent, so status prints its "✓ core pin
  # HOLDS" — and beside a speaker of unestablished identity that tick may not stand BARE. Downgrade
  # the arm's verdict by one token (UNKNOWN → NO-PIN) and _pin_speaker_suffix emits nothing: the
  # bare tick returns, which IS the live bug. Proved on this exact fixture.
  case "$out_clu" in
    *"core pin HOLDS"*"whether that IS the engine this pin names could NOT be determined"*)
      ok "the ✓ core-pin tick is qualified by the UNKNOWN speaker on the cleanliness arm (the bare tick cannot come back unnoticed)" ;;
    *"core pin HOLDS"*)
      bad "\"✓ core pin HOLDS\" stands BARE beside an engine whose cleanliness — and so whose identity — could not be established" ;;
    *) bad "the core-pin block did not affirm for the broken-index engine — this consequence lane proves nothing" ;;
  esac
fi

# CANNOT DETERMINE — git itself is not on PATH, so the running engine's own HEAD cannot be read at
# all. Built by mirroring the REAL PATH minus `git`, so everything else the front door shells out
# to still resolves and only the one fact under test is missing.
NOGIT="$T/nogit-bin"; mkdir -p "$NOGIT"
_ng_ifs="$IFS"; IFS=:
for _ng_d in $PATH; do
  [ -d "$_ng_d" ] || continue
  for _ng_b in "$_ng_d"/*; do
    [ -f "$_ng_b" ] && [ -x "$_ng_b" ] || continue
    _ng_n="${_ng_b##*/}"
    [ "$_ng_n" = git ] && continue
    [ -e "$NOGIT/$_ng_n" ] || ln -s "$_ng_b" "$NOGIT/$_ng_n" 2>/dev/null || true
  done
done
IFS="$_ng_ifs"
if [ -n "$(env PATH="$NOGIT" sh -c 'command -v git' 2>/dev/null || true)" ] \
   || [ -z "$(env PATH="$NOGIT" sh -c 'command -v timeout' 2>/dev/null || true)" ]; then
  bad "fixture: the git-less PATH still finds git (or lost timeout) — the git-unavailable lane would be vacuous"
else
  out_nogit="$(cd "$T" && env -u REPO_DIR -u KICKOFF_CORE_DIR -u KICKOFF_RUNNING_DIR \
                 -u TELEGRAM_STATE_DIR -u MEMORY_DIR -u MEMORY_INDEX -u MC_STATE_FILE -u CHANNEL_SPEC \
                 PATH="$NOGIT" timeout 180 bash "$ENGA/scripts/kickoff" status --dir "$R" 2>&1)"
  lane_cannot_determine "$out_nogit" \
    "git is not on PATH" \
    "CANNOT DETERMINE: with git absent the running engine's HEAD is unreadable, and that is reported as unknown"
fi

# NO PIN — a repo carrying no core.lock at all. Distinct from \"cannot determine\": there is simply
# nothing to be.
RNP="$T/unpinned"; mkrepo "$RNP"
out_np="$(run_from "$ENGA" "$T" status --dir "$RNP")"
# NB: the phrase asserted here must be the ENGINE-IDENTITY report's own. The core-pin block already
# prints "✗ no .kickoff/core.lock — the core is not pinned" for this fixture, so matching that would
# pass vacuously against the UNCHANGED front door (observed on the RED run — the lane certified a
# line this slice does not own).
case "$out_np" in
  *"no pin to compare the running engine against"*) ok "NO PIN: an unpinned repo is reported as carrying no pin for the running engine to be" ;;
  *) bad "an unpinned repo produced no engine-identity \"no pin\" statement" ;;
esac
case "$out_np" in
  *"IS this repo's pinned engine"*) bad "an UNPINNED repo produced an \"IS the pin\" claim — a tick with nothing behind it" ;;
  *) ok "NO PIN: no engine-identity claim is made where there is no pin" ;;
esac

# ── IDENTITY IS A COMMIT, NOT A PATH ────────────────────────────────────────────────────────────
# The sharpest lane in the suite, and it was added because a mutant SURVIVED without it: replacing
# the commit comparison with a PATH comparison against KICKOFF_CORE_DIR passed every other lane,
# because in all of them the configured path happens to name the running engine's own directory.
# This is precisely the disease that killed r3/r4 (and the defect still live in the three
# PIN-REDIRECT blocks, which exec on a path difference and never read the lock's commit): the path
# AGREES while the commit DISAGREES, and a path-comparer calls that "the pin".
#
# The fixture: the repo's instance.env names engine B as its core clone — which IS the engine doing
# the running — but its lock pins an OLDER COMMIT of engine B. By path, this engine is the pin. By
# identity, it is not, and identity is the one that is true.
RPATH="$T/path-agrees-commit-differs"; mkrepo "$RPATH"
CB_PARENT="$(git -C "$ENGB" rev-parse 'HEAD~1' 2>/dev/null || true)"
if [ -z "$CB_PARENT" ] || [ "$CB_PARENT" = "$CB" ]; then
  bad "fixture: no distinct parent commit in engine B — the path-vs-commit lane would be vacuous"
else
  mkdir -p "$RPATH/.kickoff"
  # deliberately NO `tag` line: it isolates the COMMIT comparison as the only thing that can
  # produce the verdict (with a tag present, a path-comparer would trip the tag check instead and
  # die for the wrong reason — the lane would then not be testing what it claims to test).
  { printf 'format 2\n'; printf 'commit %s\n' "$CB_PARENT"; } > "$RPATH/.kickoff/core.lock"
  printf 'export KICKOFF_CORE_DIR="%s"\n' "$ENGB" > "$RPATH/.kickoff/instance.env"
  out_path="$(run_from "$ENGB" "$T" status --dir "$RPATH")"
  lane_not "$out_path" "but this repo pins ${CB_PARENT:0:12}" \
    "the verdict is a COMMIT comparison, not a path comparison (right path, wrong commit → ✗ NOT the pin, naming the commit actually pinned)"
fi

# ── …AND THE WHOLE COMMIT, NOT A PREFIX OF ONE ──────────────────────────────────────────────────
# Every other NOT lane compares two UNRELATED shas, which disagree in their first character ~15/16
# of the time — so a truncated comparison dies there by LUCK, not by design, and one that is not
# fixed-length does not die at all. Two fixtures, because the two truncations fail differently and
# neither fixture catches both:
#   · a lock whose commit is the running engine's own with only its LAST character changed — any
#     FIXED-length prefix comparison (`${…:0:N}` for N<40) then says "IS the pin";
#   · a lock recording an ABBREVIATED 12-hex commit — a comparison of the running head's prefix
#     "to the length of what the lock recorded" then says "IS the pin", and that one is the
#     plausible-looking convenience someone would actually write. It is also the real shape of a
#     hand-edited or short-sha lock, where the honest answer is that the pin is not established.
# Neither carries a `tag` line, for the same reason as the lane above: with one present a
# prefix-comparer would die on the tag instead, for the wrong reason.
case "$CB" in
  *0) CB_FLIP="${CB%?}1" ;;
  *)  CB_FLIP="${CB%?}0" ;;
esac
CB_ABBREV="${CB:0:12}"
if [ "$CB_FLIP" = "$CB" ] || [ "${#CB_FLIP}" != "${#CB}" ] || [ "${#CB_ABBREV}" != 12 ]; then
  bad "fixture: could not build the truncated/last-character-different shas — the full-sha lanes would be vacuous"
else
  RFULL="$T/full-sha-last-char"; mkrepo "$RFULL"; mkdir -p "$RFULL/.kickoff"
  { printf 'format 2\n'; printf 'commit %s\n' "$CB_FLIP"; } > "$RFULL/.kickoff/core.lock"
  printf 'export KICKOFF_CORE_DIR="%s"\n' "$ENGB" > "$RFULL/.kickoff/instance.env"
  out_full="$(run_from "$ENGB" "$T" status --dir "$RFULL")"
  lane_not "$out_full" "but this repo pins ${CB_FLIP:0:12}" \
    "the comparison runs to the LAST hex digit — a sha differing only in its final character is ✗ NOT the pin"

  RABB="$T/full-sha-abbreviated"; mkrepo "$RABB"; mkdir -p "$RABB/.kickoff"
  { printf 'format 2\n'; printf 'commit %s\n' "$CB_ABBREV"; } > "$RABB/.kickoff/core.lock"
  printf 'export KICKOFF_CORE_DIR="%s"\n' "$ENGB" > "$RABB/.kickoff/instance.env"
  out_abb="$(run_from "$ENGB" "$T" status --dir "$RABB")"
  lane_not "$out_abb" "but this repo pins ${CB_ABBREV}" \
    "an ABBREVIATED lock commit is not a match — the pin is a whole 40-hex commit or it is not established"
fi

# ── ENV-IMMUNITY: identity is not configuration ─────────────────────────────────────────────────
# Point every plausible env var at the PINNED engine while running the STALE one. A predicate that
# reads any of them would now claim to be the pin. r4 died here (it answered "is $HOME/kickoff-
# versions the parent?" instead of "which tree am I?"), so this is asserted as behaviour.
for v in KICKOFF_CORE_DIR KICKOFF_RUNNING_DIR REPO_DIR; do
  out_v="$(cd "$T" && env -u TELEGRAM_STATE_DIR -u MEMORY_DIR -u MEMORY_INDEX -u MC_STATE_FILE \
             -u CHANNEL_SPEC "$v=$ENGB" timeout 180 bash "$ENGA/scripts/kickoff" status --dir "$R" 2>&1)"
  lane_not "$out_v" "the running engine is commit ${CA:0:12}" \
    "env-immune: $v=<the pinned engine> does not make the STALE engine claim to be it"
done

# ── …AND THE ENVIRONMENT GIT ITSELF READS ────────────────────────────────────────────────────────
# The loop above covers the vars the PREDICATE could read. It could never have caught this one,
# because the predicate does not read it — GIT does. Ambient GIT_DIR/GIT_WORK_TREE redirected every
# git call the predicate makes onto ANOTHER TREE while the identity line still printed the running
# engine's own path. REPRODUCED before the fix, on this exact fixture shape:
#     running: …/engine-A @ <engine B's commit>
#     ✓ the running engine IS this repo's pinned engine
# The path is engine A's, the commit is engine B's, and the sentence is a fabrication — a false
# green on a stale engine, which is the one class this whole slice exists to prevent. With GIT_DIR
# alone it corrupts differently (a DEFINITE ✗ "…but its tree is DIRTY" about engine A, computed from
# engine B), so both are laned: a fix that neutralises one and not the other is still broken.
#
# The fix reuses this repo's OWN seal: scripts/adopt-manifest.py's generated shims already
# `unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE`, held there by shim-env-seal-selftest.sh §(e).
#
# EVERY VAR IS LANED SEPARATELY, not just the pair that produced the original repro. A seal that
# unsets some of them looks identical to a complete one under a lane that always sets GIT_DIR:
# MUTATION-PROVED — dropping GIT_WORK_TREE from the unset list SURVIVED a two-lane version of this
# block, because with GIT_DIR still sealed the rest of the poison never reached git. Each var below
# was MEASURED to corrupt this predicate ON ITS OWN in git 2.43.0, and each carries its own
# NEGATIVE CONTROL, because a lane whose poison is inert proves nothing at all.
_gp_run() {   # $1 = the poison env (word-split deliberately), then the engine + argv
  local _poison="$1" _eng="$2"; shift 2
  # shellcheck disable=SC2086
  ( cd "$T" && env -u REPO_DIR -u KICKOFF_CORE_DIR -u KICKOFF_RUNNING_DIR -u KICKOFF_RUNNING_SELF \
      -u TELEGRAM_STATE_DIR \
      -u MEMORY_DIR -u MEMORY_INDEX -u MC_STATE_FILE -u CHANNEL_SPEC -u INSTANCE_ENV $_poison \
      timeout 180 bash "$_eng/scripts/kickoff" "$@" 2>&1 )
}
# (i) the vars that make git answer about ANOTHER TREE. Engine A is genuinely NOT the pin, so the
#     honest verdict is ✗ with the commit-differs sentence — poison turns it into either a ✓ IS
#     (engine B's commit read under engine A's path: the original repro) or a definite ✗ "…its tree
#     is DIRTY" about a tree that is clean. Both are caught by binding the ARM, not just the class.
for _gp in "GIT_DIR=$ENGB/.git GIT_WORK_TREE=$ENGB" "GIT_DIR=$ENGB/.git" \
           "GIT_OBJECT_DIRECTORY=$T/no-such-object-dir"; do
  # NEGATIVE CONTROL: this env must visibly change what `git -C <engine A>` says about engine A.
  # shellcheck disable=SC2086
  _gp_head="$(env $_gp git -C "$ENGA" rev-parse -q --verify HEAD 2>/dev/null || true)"
  # shellcheck disable=SC2086
  _gp_dirt="$(env $_gp git -C "$ENGA" status --porcelain 2>/dev/null || printf 'STATUS-FAILED')"
  if [ "$_gp_head" = "$CA" ] && [ -z "$_gp_dirt" ]; then
    bad "fixture [$_gp]: this env does NOT change what git says about engine A in this git — the lane below would be vacuous"
    continue
  fi
  ok "NEGATIVE CONTROL [$_gp]: the poison is LIVE (raw \`git -C <engine A>\` under it reports head='${_gp_head:-<none>}' dirt='${_gp_dirt:0:24}')"
  out_poison="$(_gp_run "$_gp" "$ENGA" status --dir "$R")"
  lane_not "$out_poison" "the running engine is commit ${CA:0:12}… but this repo pins ${CB:0:12}" \
    "git-env-immune [$_gp]: the stale engine still reports its OWN commit and ✗ NOT the pin"
  # …and the IDENTITY LINE, separately, because that is where the fabrication was VISIBLE: engine
  # A's path paired with engine B's sha. The verdict lane above cannot see a corrupted line that
  # still lands on the same class.
  _pl="$(printf '%s\n' "$out_poison" | /usr/bin/grep -F '  running: ' | head -n1)"
  case "$_pl" in
    *"${CB:0:12}"*) bad "FABRICATED IDENTITY [$_gp]: the identity line prints the running engine's path next to the OTHER engine's commit — git answered about a tree that is not this one: $_pl" ;;
    *"$ENGA"*"${CA:0:12}"*) ok "git-env-immune [$_gp]: the identity line pairs the running engine's path with ITS OWN commit" ;;
    *) bad "git-env-immune [$_gp]: the identity line names neither the running engine nor its commit: ${_pl:-<absent>}" ;;
  esac
done
# (ii) the vars that redirect only the WORK TREE or the INDEX — and which therefore CANNOT be laned
#      from the stale engine at all. MUTATION-PROVED, and it is the reason this group exists
#      separately: dropping GIT_WORK_TREE (or GIT_INDEX_FILE) from the seal's unset list SURVIVED a
#      version of this suite that ran every poison from engine A. Engine A's HEAD differs from the
#      pin, so the predicate returns at commit-differs BEFORE `git status` is ever called, and the
#      poison never reaches the arm it corrupts. It has to be run from the engine that IS the pin,
#      where HEAD matches and cleanliness is the last thing standing between the world and a ✓ —
#      there, an ambient work-tree/index redirect makes a CLEAN engine read DIRTY and turns the
#      honest tick into a definite ✗ about a tree that is fine.
for _gp in "GIT_WORK_TREE=$ENGA" "GIT_INDEX_FILE=$ENGA/.git/index"; do
  # shellcheck disable=SC2086
  _gp_dirt="$(env $_gp git -C "$ENGB" status --porcelain 2>/dev/null || printf 'STATUS-FAILED')"
  if [ -n "$(git -C "$ENGB" status --porcelain 2>/dev/null)" ]; then
    bad "fixture [$_gp]: engine B is not clean to begin with — the work-tree/index redirect lane would be vacuous"
  elif [ -z "$_gp_dirt" ]; then
    bad "fixture [$_gp]: this env does NOT make raw \`git -C <engine B> status\` report dirt in this git — the lane below would be vacuous"
  else
    ok "NEGATIVE CONTROL [$_gp]: the poison is LIVE (raw \`git -C <engine B> status\` under it reports '${_gp_dirt%%$'\n'*}' on a clean tree)"
    lane_is "$(_gp_run "$_gp" "$ENGB" status --dir "$R")" "ESTABLISHED for the tree at" \
      "git-env-immune [$_gp]: an ambient work-tree/index redirect does not make the PINNED engine report itself dirty and disown the pin"
  fi
done
# (iii) CONFIG INJECTION — the sharpest of the family, because it manufactures a ✓ rather than a ✗.
#      `status.showUntrackedFiles=no` handed to git through the environment makes `status
#      --porcelain` SILENT about untracked files, so a genuinely DIRTY pinned engine reads CLEAN and
#      is ticked "IS the pin". Run from ENGINE B — the engine that really is the pin — with an
#      untracked file present, so the only thing between this world and a false green is the seal.
printf 'an untracked file that is not in the pinned commit\n' > "$ENGB/UNTRACKED-POISON-PROBE"
for _gp in "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=status.showUntrackedFiles GIT_CONFIG_VALUE_0=no" \
           "GIT_CONFIG_PARAMETERS='status.showUntrackedFiles=no'"; do
  # shellcheck disable=SC2086
  _gp_dirt="$(env $_gp git -C "$ENGB" status --porcelain 2>/dev/null || printf 'STATUS-FAILED')"
  if [ -z "$(git -C "$ENGB" status --porcelain 2>/dev/null)" ]; then
    bad "fixture [$_gp]: engine B does not read DIRTY without the poison — the false-green lane would be vacuous"
  elif [ -n "$_gp_dirt" ]; then
    bad "fixture [$_gp]: the config injection does not silence \`status\` in this git (got '$_gp_dirt') — the lane below would be vacuous"
  else
    ok "NEGATIVE CONTROL [$_gp]: the injection really does make a DIRTY engine B read CLEAN to raw git — the false green is one seal away"
    lane_not "$(_gp_run "$_gp" "$ENGB" status --dir "$R")" "but its tree is DIRTY" \
      "git-env-immune [$_gp]: config injected through the ENVIRONMENT cannot silence \`status\` into a ✓ IS on a dirty engine"
  fi
done
# (iv) THE VARS THAT ARE NOT GIT_* AT ALL — and which is why the seal is now an ALLOWLIST.
#      Groups (i)–(iii) are every name the old `unset` denylist knew about, and the denylist was
#      correct about all of them. These two walked straight past it, because git's global config is
#      reachable by names the list could not contain:
#        · XDG_CONFIG_HOME=<dir> → git reads <dir>/git/config;
#        · HOME=<dir>            → git reads <dir>/.gitconfig. HOME is ALWAYS set, so "add it to
#                                  the unset list" was never even an available move.
#      Both were REPRODUCED against the pre-change front door: a genuinely DIRTY engine B (an
#      untracked file that is not in the pinned commit) read CLEAN and was ticked "✓ IS the pin".
#      That is the same false green as group (iii), reached by a name nobody had enumerated — which
#      is the whole argument for `env -i` plus GIT_CONFIG_GLOBAL=/dev/null. Each carries its own
#      NEGATIVE CONTROL, because a poison that is inert proves nothing.
#      MEASURED, so the seal's two halves are not both credited to these lanes: it is the `env -i`
#      that kills these two, and GIT_CONFIG_GLOBAL=/dev/null is belt-and-braces. Dropping
#      GIT_CONFIG_GLOBAL alone SURVIVES this suite (97/0) — an EQUIVALENT mutant, because `env -i`
#      has already removed HOME and XDG_CONFIG_HOME from git's environment, so there is no global
#      config left to point at (verified directly: `env -i PATH=… git config --get
#      status.showUntrackedFiles` finds nothing under either poison). Downgrading `env -i` to `env`
#      is what these lanes actually kill.
_xdgp="$T/xdg-poison"; mkdir -p "$_xdgp/git"
printf '[status]\n\tshowUntrackedFiles = no\n' > "$_xdgp/git/config"
_homep="$T/home-poison"; mkdir -p "$_homep"
printf '[status]\n\tshowUntrackedFiles = no\n' > "$_homep/.gitconfig"
for _gp in "XDG_CONFIG_HOME=$_xdgp" "HOME=$_homep"; do
  # shellcheck disable=SC2086
  _gp_dirt="$(env $_gp git -C "$ENGB" status --porcelain 2>/dev/null || printf 'STATUS-FAILED')"
  if [ -z "$(git -C "$ENGB" status --porcelain 2>/dev/null)" ]; then
    bad "fixture [$_gp]: engine B does not read DIRTY without the poison — the non-GIT_* false-green lane would be vacuous"
  elif [ -n "$_gp_dirt" ]; then
    bad "fixture [$_gp]: this NON-GIT_* var does not silence \`status\` in this git (got '$_gp_dirt') — the lane below would be vacuous"
  else
    ok "NEGATIVE CONTROL [$_gp]: a var that is not a GIT_* name at all makes a DIRTY engine B read CLEAN to raw git — no denylist of GIT_* names can reach this"
    lane_not "$(_gp_run "$_gp" "$ENGB" status --dir "$R")" "but its tree is DIRTY" \
      "env-ALLOWLIST [$_gp]: config injected through a NON-GIT_* variable cannot silence \`status\` into a ✓ IS on a dirty engine"
  fi
done

# ── (v) THE SYSTEM-SCOPED CONFIG — the one root `env -i` CANNOT reach ────────────────────────────
# Groups (i)–(iv) are all ENVIRONMENT, and `env -i` is what kills them. /etc/gitconfig is not: it is
# a FILESYSTEM PATH compiled into git, and no amount of environment scrubbing unsets a file. So
# GIT_CONFIG_SYSTEM=/dev/null in _eitp_git is LOAD-BEARING, not the belt-and-braces its own comment
# used to call it — and it had NO LANE, which is how it came to be mislabelled in the first place.
#
# WHY THIS LANE USES A `git` SHIM, said plainly rather than dressed up: this test user cannot write
# /etc/gitconfig, and git exposes NO other handle onto the system scope (`unshare --map-root-user`
# to bind-mount one is refused on this box: "write failed /proc/self/uid_map"). The shim IS the
# poisoned /etc/gitconfig — it supplies a system config to any caller that did not null the system
# root, which is precisely what a real /etc/gitconfig does, and nothing to a caller that did. The
# assertion is still the printed VERDICT, not a source string.
#
# THE WITNESS is the part that stops this lane going green for the wrong reason: if the predicate's
# git were resolved OFF this PATH (execvp's confstr fallback is `/bin:/usr/bin`, where the real git
# lives), the shim would never run, no poison would be injected, and the ✗ would be printed by a
# world this lane never built. So the shim records every invocation, and the lane requires to SEE
# the predicate's own fingerprint — `--no-replace-objects`, which only _eitp_git passes — carrying
# GIT_CONFIG_SYSTEM=/dev/null. That is also the direct observation that _eitp_git's PATH carry is
# what reaches git (see its corrected comment in scripts/kickoff).
_sysp="$T/etc-gitconfig-poison"
printf '[status]\n\tshowUntrackedFiles = no\n' > "$_sysp"
_sysshim="$T/sysconf-shim"; mkdir -p "$_sysshim"
_syswit="$T/sysconf-witness.txt"
_sysgit="$(command -v git 2>/dev/null || printf '/usr/bin/git')"
{ printf '#!/bin/sh\n'
  printf '# stand-in for a poisoned /etc/gitconfig (see the block above) — supply a system config\n'
  printf '# to any caller that did not null the system root, exactly as the real file would.\n'
  printf 'if [ -z "${GIT_CONFIG_SYSTEM+x}" ]; then GIT_CONFIG_SYSTEM=%s; export GIT_CONFIG_SYSTEM; fi\n' "$_sysp"
  printf 'printf "SYS=%%s ARGV=%%s\\n" "$GIT_CONFIG_SYSTEM" "$*" >> %s\n' "$_syswit"
  printf 'exec %s "$@"\n' "$_sysgit"
} > "$_sysshim/git"
chmod +x "$_sysshim/git"
printf 'an untracked file that is not in the pinned commit\n' > "$ENGB/UNTRACKED-POISON-PROBE"
: > "$_syswit"
# NEGATIVE CONTROL, in BOTH directions — the poison must really silence a dirty engine, and nulling
# the system root must really restore it. Either half missing and the lane proves nothing.
_sys_poisoned="$(PATH="$_sysshim:$PATH" git -C "$ENGB" status --porcelain 2>/dev/null || printf 'STATUS-FAILED')"
_sys_nulled="$(PATH="$_sysshim:$PATH" env GIT_CONFIG_SYSTEM=/dev/null git -C "$ENGB" status --porcelain 2>/dev/null || printf 'STATUS-FAILED')"
if [ -n "$_sys_poisoned" ]; then
  bad "fixture [system-scoped config]: the stand-in /etc/gitconfig does NOT silence \`status\` on a dirty engine B (got '$_sys_poisoned') — the lane would be vacuous"
elif [ -z "$_sys_nulled" ]; then
  bad "fixture [system-scoped config]: GIT_CONFIG_SYSTEM=/dev/null does not restore the dirt to view — the lane would be asserting nothing"
else
  ok "NEGATIVE CONTROL [system-scoped config]: a SYSTEM-scoped \`status.showUntrackedFiles=no\` makes a DIRTY engine B read CLEAN to raw git, and GIT_CONFIG_SYSTEM=/dev/null restores it — \`env -i\` cannot reach this root, because it is a FILE"
  _sys_out="$( cd "$T" && env -u REPO_DIR -u KICKOFF_CORE_DIR -u KICKOFF_RUNNING_DIR -u KICKOFF_RUNNING_SELF \
      -u TELEGRAM_STATE_DIR -u MEMORY_DIR -u MEMORY_INDEX -u MC_STATE_FILE -u CHANNEL_SPEC -u INSTANCE_ENV \
      PATH="$_sysshim:$PATH" timeout 180 bash "$ENGB/scripts/kickoff" status --dir "$R" 2>&1 )"
  lane_not "$_sys_out" "but its tree is DIRTY" \
    "system-config-immune: a SYSTEM-scoped config cannot silence \`status\` into a ✓ IS on a dirty engine (GIT_CONFIG_SYSTEM=/dev/null is what \`env -i\` cannot do)"
  # …and the WITNESS, without which the lane above passes on a shim that never ran.
  if /usr/bin/grep -Fq -- 'SYS=/dev/null ARGV=--no-replace-objects' "$_syswit"; then
    ok "WITNESS [system-scoped config]: the predicate's OWN git calls (\`--no-replace-objects\`) were resolved through this PATH and carried GIT_CONFIG_SYSTEM=/dev/null — the lane above was not green because the shim was bypassed"
  else
    bad "WITNESS [system-scoped config]: no \`--no-replace-objects\` invocation carrying GIT_CONFIG_SYSTEM=/dev/null was seen by the shim — the predicate's git was resolved OFF this PATH, so the lane above proves nothing: $(head -3 "$_syswit" 2>/dev/null | tr '\n' '|')"
  fi
fi
rm -f "$ENGB/UNTRACKED-POISON-PROBE"
lane_is "$(run_from "$ENGB" "$T" status --dir "$R")" "ESTABLISHED for the tree at" \
  "POSITIVE CONTROL: with the probe file removed engine B IS the pin again (the injection lanes above are not vacuous)"

# ── refs/replace/ — A FALSE GREEN WITH NO ENVIRONMENT VARIABLE AND NO CONFIG KEY ────────────────
# The sharpest of the set, because every seal above is an ENVIRONMENT seal and this one is not
# reachable by any of them. `git replace <HEAD's commit> <a commit whose tree is the TAMPERED one>`
# writes a ref inside the running engine; git then substitutes that commit at OBJECT-READ time, so
#   · `rev-parse HEAD` still prints the PINNED sha (replace does not move ref resolution), and
#   · `status --porcelain` prints NOTHING, because the index it diffs HEAD against now matches.
# REPRODUCED: the front door ticked "✓ IS the pin" on an engine whose tracked ENGINE-MARKER
# demonstrably differed from the commit the lock names. The seal is `--no-replace-objects` on every
# call — a git FLAG, because the attack is a ref and no amount of env scrubbing reaches a ref.
_rep_marker="$ENGB/ENGINE-MARKER"
_rep_head="$(git -C "$ENGB" rev-parse HEAD 2>/dev/null || true)"
_rep_parent="$(git -C "$ENGB" rev-parse -q --verify 'HEAD^' 2>/dev/null || true)"
if [ -z "$_rep_head" ] || [ -z "$_rep_parent" ] || [ ! -f "$_rep_marker" ]; then
  bad "fixture [refs/replace]: engine B has no HEAD/parent/marker file to tamper — the replace lane would be vacuous"
else
  printf 'TAMPERED — this is not what the pinned commit contains\n' > "$_rep_marker"
  git -C "$ENGB" add ENGINE-MARKER >/dev/null 2>&1
  _rep_tree="$(git -C "$ENGB" write-tree 2>/dev/null || true)"
  _rep_new="$(git -C "$ENGB" -c user.email=t@t -c user.name=t commit-tree "$_rep_tree" -p "$_rep_parent" -m tampered 2>/dev/null || true)"
  git -C "$ENGB" replace -f "$_rep_head" "$_rep_new" >/dev/null 2>&1
  # NEGATIVE CONTROL, in BOTH directions — the lane is worthless unless the replace really does
  # manufacture the silence, AND the flag really does undo it.
  _rep_dirty="$(git -C "$ENGB" status --porcelain 2>/dev/null || printf 'STATUS-FAILED')"
  _rep_honest="$(git -C "$ENGB" --no-replace-objects status --porcelain 2>/dev/null || printf 'STATUS-FAILED')"
  _rep_sha="$(git -C "$ENGB" rev-parse -q --verify HEAD 2>/dev/null || true)"
  if [ -n "$_rep_dirty" ]; then
    bad "fixture [refs/replace]: the replace ref does NOT silence \`git status\` in this git (got '$_rep_dirty') — the lane would be vacuous"
  elif [ -z "$_rep_honest" ]; then
    bad "fixture [refs/replace]: \`--no-replace-objects\` does not restore the tamper to view — the lane would be asserting nothing"
  elif [ "$_rep_sha" != "$CB" ]; then
    bad "fixture [refs/replace]: HEAD no longer reads as the pinned commit ($_rep_sha) — the lane would go green for the wrong reason"
  else
    ok "NEGATIVE CONTROL [refs/replace]: a replace ref makes raw \`git status\` SILENT over a tampered TRACKED file while \`rev-parse HEAD\` still prints the pinned sha — the false green is one flag away"
    lane_not "$(run_from "$ENGB" "$T" status --dir "$R")" "but its tree is DIRTY" \
      "refs/replace-immune: a replace ref inside the running engine cannot silence \`status\` into a ✓ IS over tampered TRACKED content"
  fi
  git -C "$ENGB" replace -d "$_rep_head" >/dev/null 2>&1
  git -C "$ENGB" reset -q --hard "$_rep_head" >/dev/null 2>&1
fi
lane_is "$(run_from "$ENGB" "$T" status --dir "$R")" "ESTABLISHED for the tree at" \
  "POSITIVE CONTROL: with the replace ref deleted engine B IS the pin again (the refs/replace lane is not vacuous)"

# ── IDENTITY IS A FILE THAT IS EXECUTING, NOT A DIRECTORY GUESSED FROM \$0 ───────────────────────
# $HERE is `dirname "$0"`, and when $0 names NO FILE — `bash -s`, `bash -c`, i.e. every ordinary way
# to run a script that arrived over a pipe — `dirname` of it is `.`, so $HERE is the CWD and the
# running engine is read off wherever the caller happened to be standing.
# REPRODUCED, and it is the purest false green in the set: engine A's front door, piped into
# `bash -s` from a cwd of <engine B>/scripts, printed
#     running: …/engine-B @ <engine B's commit>
#     ✓ the running engine IS this repo's pinned engine
# — the STALE engine's code, wearing the PINNED engine's name, with no env var, no config key and
# no ref involved. The identity was not merely wrong, it was FABRICATED: nothing in that run had
# anything to do with engine B.
# The honest answer is CANNOT DETERMINE. Both halves of the output are laned, because the verdict
# class alone cannot see a fabricated "running:" line that still lands on the right class.
out_fab="$( cd "$ENGB/scripts" 2>/dev/null && env -u REPO_DIR -u KICKOFF_CORE_DIR -u KICKOFF_RUNNING_DIR \
             -u KICKOFF_RUNNING_SELF -u TELEGRAM_STATE_DIR -u MEMORY_DIR -u MEMORY_INDEX -u MC_STATE_FILE \
             -u MC_TRACKER_FILE -u CHANNEL_SPEC -u INSTANCE_ENV \
             timeout 180 bash -s status --dir "$R" < "$ENGA/scripts/kickoff" 2>&1 )"
case "$out_fab" in
  *"running engine (which core is executing THIS command)"*)
    ok "fixture [\$0-fabrication]: engine A's code, run via \`bash -s\` from engine B's scripts/, does reach the identity report (the lane is not vacuous)" ;;
  *) bad "fixture [\$0-fabrication]: the piped run never reached the identity report — the lane proves nothing:
       $(printf '%s' "$out_fab" | tail -3)" ;;
esac
lane_cannot_determine "$out_fab" "\$0 does not name a file that exists" \
  "\$0-FABRICATION: code piped into \`bash -s\` establishes no running engine — the verdict is declined, not a tick on the cwd's parent"
_fab_line="$(printf '%s\n' "$out_fab" | /usr/bin/grep -F '  running: ' | head -n1)"
case "$_fab_line" in
  *"${CB:0:12}"*) bad "FABRICATED IDENTITY [\$0]: the identity line prints the PINNED engine's commit for a run of the STALE engine's code: $_fab_line" ;;
  *"$ENGB"*)      bad "FABRICATED IDENTITY [\$0]: the identity line names engine B, which contributed nothing but a cwd, to a run of engine A's code: $_fab_line" ;;
  *)              ok "\$0-FABRICATION: the identity line claims neither the cwd's engine nor its commit" ;;
esac

# ── …AND THE TWO ROUTES THAT SUPPLY A FILE, WHICH THE GUARD ABOVE DOES NOT CLOSE ─────────────────
# The lane above closes an identity read off a cwd with NO FILE behind it. A caller that supplies a
# file behind it is supplying the answer, and both routes below do exactly that — REPRODUCED, each
# running one file's bytes while the report names a different tree:
#   · `exec -a "<engine B>/scripts/kickoff" bash -s < <other bytes>` — $0 is engine B's real path,
#     so $KICKOFF_RUNNING_SELF resolves to a real regular file INSIDE engine B and every guard
#     passes. The engine reports engine B.
#   · plain `bash -s` from a cwd holding any regular file named `bash` — $0 is "bash",
#     `readlink -f` makes it <cwd>/bash, which exists. Same fabrication, no `exec -a`.
# NEITHER IS SEALED HERE and neither is claimed to be: they are DELIBERATE misrepresentation of
# which program is running, which is out of this predicate's declared scope (see the scope lines
# the report prints). What is asserted is the thing that IS in scope — that the output does not
# assert the identity as ESTABLISHED. The identity belongs in the REPORTED tier, and this is the
# world in which putting it anywhere else would be a printed lie.
#
# The piped bytes are made SELF-IDENTIFYING so the fabrication is visible rather than assumed: the
# copy announces its own path on stderr, and the lane requires to see BOTH that line and a report
# naming a DIFFERENT tree before it asserts anything.
PIPED="$T/piped-front-door"
{ head -n1 "$KO"; printf 'printf "BYTES-EXECUTING-FROM: %%s\\n" "%s" >&2\n' "$PIPED"; tail -n +2 "$KO"; } > "$PIPED"
# route (a): a crafted argv0 naming engine B's real front-door file.
out_argv0="$( cd "$T" && env -u REPO_DIR -u KICKOFF_CORE_DIR -u KICKOFF_RUNNING_DIR -u KICKOFF_RUNNING_SELF \
    -u TELEGRAM_STATE_DIR -u MEMORY_DIR -u MEMORY_INDEX -u MC_STATE_FILE -u MC_TRACKER_FILE \
    -u CHANNEL_SPEC -u INSTANCE_ENV \
    timeout 180 bash -c 'exec -a "$1" bash -s -- status --dir "$2" < "$3"' _ \
      "$ENGB/scripts/kickoff" "$R" "$PIPED" 2>&1 )"
# route (b): a plain `bash -s` with a regular file named `bash` sitting in the cwd. A DEDICATED
# clone, so the excluded probe file cannot leak into any later lane's view of engine B.
PLB="$T/engine-planted-bash"
if git clone -q --local "$ENGB" "$PLB" >/dev/null 2>&1 && git -C "$PLB" checkout -q --detach "$CB" >/dev/null 2>&1; then
  mkdir -p "$PLB/.git/info"; printf 'scripts/bash\n' >> "$PLB/.git/info/exclude"
  : > "$PLB/scripts/bash"
  out_pbash="$( cd "$PLB/scripts" && env -u REPO_DIR -u KICKOFF_CORE_DIR -u KICKOFF_RUNNING_DIR -u KICKOFF_RUNNING_SELF \
      -u TELEGRAM_STATE_DIR -u MEMORY_DIR -u MEMORY_INDEX -u MC_STATE_FILE -u MC_TRACKER_FILE \
      -u CHANNEL_SPEC -u INSTANCE_ENV \
      timeout 180 bash -s -- status --dir "$R" < "$PIPED" 2>&1 )"
else
  out_pbash=""
  bad "fixture [planted-bash]: could not build a clone of engine B detached at the pinned commit — the planted-\`bash\` lane cannot run"
fi
for _fabcase in "argv0:$ENGB" "pbash:$PLB"; do
  _fk="${_fabcase%%:*}"; _ftree="${_fabcase#*:}"
  case "$_fk" in argv0) _fout="$out_argv0" ;; *) _fout="$out_pbash" ;; esac
  [ -n "$_fout" ] || continue
  # NEGATIVE CONTROL — the fabrication must actually be ON SCREEN: bytes from one file, identity
  # from another tree. Without both halves the lane below is asserting about a world it never built.
  _fabline="$(printf '%s\n' "$_fout" | /usr/bin/grep -F '  running: ' | head -n1)"
  case "$_fout" in *"BYTES-EXECUTING-FROM: $PIPED"*) : ;;
    *) bad "fixture [$_fk]: the piped bytes did not announce themselves — the run may not be executing $PIPED at all"; continue ;; esac
  case "$_fabline" in *"$_ftree"*) : ;;
    *) bad "fixture [$_fk]: the report does not name $_ftree as the running engine, so no identity was fabricated and the lane would be vacuous: ${_fabline:-<absent>}"; continue ;; esac
  ok "NEGATIVE CONTROL [$_fk]: the bytes executing are $PIPED and the report names $_ftree as the running engine — the identity IS fabricated in this run, by a caller that supplied a file"
  # THE LANE: whatever verdict is reached, the identity may not be asserted as established.
  case "$_fout" in
    *"✓ $IS_CLASS"*)
      case "$_fout" in
        *"REPORTED, NOT PROVED — (1) THAT THIS TREE IS THE ENGINE EXECUTING THIS COMMAND"*)
          ok "IDENTITY IS REPORTED, NOT ESTABLISHED [$_fk]: the ✓ names the identity as the path the process resolved ITSELF to from \$0 — true of this run, fabrication and all" ;;
        *) bad "IDENTITY OVER-CLAIM [$_fk]: the ✓ was printed with the identity NOT marked as reported-only, in a run whose identity is demonstrably fabricated: $(printf '%s\n' "$_fout" | /usr/bin/grep -F "✓ $IS_CLASS" | head -n1)" ;;
      esac ;;
    *) ok "IDENTITY IS REPORTED, NOT ESTABLISHED [$_fk]: no ✓ is printed here at all — stronger than required" ;;
  esac
  # …and the "running:" line itself, which is what the eye lands on before any verdict.
  case "$_fabline" in
    *"resolved ITSELF to"*) ok "IDENTITY LINE [$_fk]: the path is labelled at the point it is printed as what the process resolved itself to — not stated as a fact this code established" ;;
    *) bad "IDENTITY LINE [$_fk]: \"running: <path>\" is printed unqualified, reading as a fact this code established, in a run where it is fabricated: $_fabline" ;;
  esac
done

# ════════════════════════════════════════════════════════════════════════════════════════════════
printf '\n3. THE REPORT REACHES status · verify · doctor · pull — and the green tick is no longer bare\n'
# ════════════════════════════════════════════════════════════════════════════════════════════════
# THE LIVE BUG, closed. Engine A still reports the pin (that is true of the CLONE and stays true),
# but the affirmation may no longer stand alone: the operator must be able to see that a DIFFERENT
# engine produced it.
case "$out_not" in
  *"core pin HOLDS"*)
    case "$out_not" in
      *"core pin HOLDS — the clone is at"*"NOT the engine this pin names"*)
        ok "the ✓ core-pin affirmation now names the wrong-engine speaker inline (the live bug is closed)" ;;
      *) bad "\"✓ core pin HOLDS\" is still printed BARE by an engine that is not the pin — the live bug is open" ;;
    esac ;;
  *) bad "the core-pin block did not run at all in the fixture — the lane proves nothing" ;;
esac

# …and the SAME tick beside an engine whose identity is UNKNOWN. "NOT the pin" was the loud half of
# the live bug; this is the quiet half, and it was unasserted: an unknown speaker is not a permitted
# one, so the ✓ may not stand bare there either. The fixture is the nested (non-git-root) engine
# from §2 — the pinned CLONE genuinely is coherent, and the engine reporting it has no established
# identity at all.
case "$out_nested" in
  *"core pin HOLDS"*"whether that IS the engine this pin names could NOT be determined"*)
    ok "the ✓ core-pin affirmation also names its speaker when that speaker's identity is UNKNOWN" ;;
  *"core pin HOLDS"*)
    bad "\"✓ core pin HOLDS\" stands BARE beside an engine whose identity could NOT be determined — the tick is unattributed on an unknown" ;;
  *) bad "the core-pin block did not affirm for the nested engine — the lane proves nothing" ;;
esac

# verify — same repo, same stale engine. The report must be present; the EXIT CODE must not change.
out_v_stale="$(run_from "$ENGA" "$T" verify --dir "$R")"; rc_v_stale=$?
out_v_pinned="$(run_from "$ENGB" "$T" verify --dir "$R")"; rc_v_pinned=$?
lane_not "$out_v_stale" "the running engine is commit ${CA:0:12}" \
  "verify reports — with the ✗ — that the running engine is not the pin"
lane_is "$out_v_pinned" "ESTABLISHED for the tree at" \
  "verify reports ✓ IS when run from the pinned engine"
# verify has its OWN green core-pin tick ("core.lock COHERENT"), written by its own block — and it
# is the one an operator reaches for as the health verdict. It carried the speaker suffix and
# nothing asserted it, so deleting the suffix from that one line left the suite fully green.
case "$out_v_stale" in
  *"core.lock COHERENT"*"NOT the engine this pin names"*)
    ok "verify's ✓ core.lock COHERENT names the wrong-engine speaker inline, exactly as status' does" ;;
  *"core.lock COHERENT"*)
    bad "verify's \"✓ core.lock COHERENT\" is printed BARE by an engine that is not the pin — the live bug is open on verify's own tick" ;;
  *) bad "verify's core-pin seam did not affirm in the fixture — the lane proves nothing" ;;
esac
# NO NEW EXIT CODE: this slice is REPORTING. Both fixtures are unadopted repos, so verify is RED for
# its own (pre-existing) reasons in both — what matters is that the wrong engine does not introduce
# a NEW verdict of its own.
[ "$rc_v_stale" = "$rc_v_pinned" ] \
  && ok "verify's exit code is UNCHANGED by which engine ran it (reporting, not control flow)" \
  || bad "verify exited $rc_v_stale from the stale engine vs $rc_v_pinned from the pinned one — the report became control flow"
# The rc lane above CANNOT see a report that starts driving `fails`: both fixtures are already RED
# for their own reasons, so rc is 1 either way (confirmed by mutation — a `fails=$((fails+1))` in
# the engine-identity block SURVIVED it). The HARD-FAIL COUNT can see it: NOT would add one and IS
# would not, so the two runs would disagree.
nf_stale="$(printf '%s' "$out_v_stale"   | sed -n 's/.*— \([0-9][0-9]*\) hard check(s) FAILED.*/\1/p' | head -n1)"
nf_pinned="$(printf '%s' "$out_v_pinned" | sed -n 's/.*— \([0-9][0-9]*\) hard check(s) FAILED.*/\1/p' | head -n1)"
if [ -z "$nf_stale" ] || [ -z "$nf_pinned" ]; then
  bad "could not read verify's hard-fail count from either run — the control-flow lane proves nothing"
elif [ "$nf_stale" = "$nf_pinned" ]; then
  ok "verify's HARD-FAIL COUNT is identical from both engines ($nf_stale) — the engine report drives no failure"
else
  bad "verify counted $nf_stale hard failures from the stale engine vs $nf_pinned from the pinned one — the engine report became a GATE"
fi
# ── THE ONE NON-PRINTING BEHAVIOUR CHANGE THIS SLICE MAKES, AND IT WAS LANED BY NOTHING ──────────
# Everything else here is output. verify's engine-identity block also bumps `warns` on any verdict
# that is not IS/NO-PIN — a real, asserted, operator-visible difference in verify's summary line —
# and the two lanes above are both blind to it BY CONSTRUCTION: rc is unchanged and `fails` is
# unchanged, which is exactly the point of them. So deleting the bump, or promoting it to `fails`,
# passed the whole suite. The advisory count is where it is visible: NOT adds one, IS adds none, so
# the same repo checked by the two engines must differ by EXACTLY one warning.
nw_stale="$(printf '%s' "$out_v_stale"   | sed -n 's/.*, \([0-9][0-9]*\) advisory warning(s).*/\1/p' | head -n1)"
nw_pinned="$(printf '%s' "$out_v_pinned" | sed -n 's/.*, \([0-9][0-9]*\) advisory warning(s).*/\1/p' | head -n1)"
if [ -z "$nw_stale" ] || [ -z "$nw_pinned" ]; then
  bad "could not read verify's ADVISORY WARNING count from either run (stale='${nw_stale:-}', pinned='${nw_pinned:-}') — the slice's only non-printing behaviour change is unasserted"
elif [ "$nw_stale" = "$((nw_pinned + 1))" ]; then
  ok "verify's ADVISORY WARNING count is exactly one HIGHER from the wrong engine ($nw_stale vs $nw_pinned) — the report is an advisory, and it is actually raised"
elif [ "$nw_stale" = "$nw_pinned" ]; then
  bad "verify raised the SAME advisory count from both engines ($nw_stale) — the wrong-engine verdict raises no warning at all, so verify's summary is identical whoever ran it"
else
  bad "verify's advisory count differs by more than the one engine-identity warning (stale=$nw_stale, pinned=$nw_pinned) — the report is driving more than its own advisory"
fi

# doctor — the mutating repair verb. It pin-redirects first (pin-redirect-selftest's lane), so the
# process that reaches the report is engine B; the report must be there and must say IS.
RDOC="$T/adopted-repo"; mkrepo "$RDOC"
pin "$RDOC" core-vENGB "$CB"
printf 'export KICKOFF_CORE_DIR="%s"\n' "$ENGB" > "$RDOC/.kickoff/instance.env"
printf '{"entries":[],"machine_entries":[]}\n' > "$RDOC/.kickoff/adopt-manifest.json"
out_doc="$(run_from "$ENGA" "$T" doctor --dir "$RDOC")"
case "$out_doc" in
  *"IS this repo's pinned engine"*) ok "doctor reports the running engine after the pin-redirect (it IS the pin)" ;;
  *"is NOT this repo's pinned engine"*) ok "doctor reports the running engine (NOT the pin — visible, as it should be)" ;;
  *) bad "doctor never says which engine is doing the repair" ;;
esac

# pull — the verb that MOVES the pin, i.e. the box's own self-modification path. The other three
# verbs report ON a pin; this one rewrites it, so "which engine did that" is the fact the log has
# to carry. The fixture aims the core clone at a path that does not exist and the core remote at a
# repo that does not exist, so pull dies at the clone — which is the point: the report must already
# have been printed by then, BEFORE the first fetch and long before core.lock is rewritten.
RPULL="$T/pull-target"; mkrepo "$RPULL"
pin "$RPULL" core-vENGB "$CB"
out_pull="$(cd "$T" && env -u REPO_DIR -u KICKOFF_RUNNING_DIR -u TELEGRAM_STATE_DIR -u MEMORY_DIR \
             -u MEMORY_INDEX -u MC_STATE_FILE -u CHANNEL_SPEC -u INSTANCE_ENV \
             KICKOFF_CORE_DIR="$T/pull-core-never-created" KICKOFF_CORE_REMOTE="$T/no-such-core-remote" \
             timeout 180 bash "$ENGA/scripts/kickoff" pull --dir "$RPULL" 2>&1)"
case "$out_pull" in
  *"is NOT this repo's pinned engine"*) ok "pull — the verb that MOVES the pin — says which engine is moving it" ;;
  *) bad "pull rewrites the pin and never says which engine did it:
       $(printf '%s' "$out_pull" | tail -3)" ;;
esac
# …and says it BEFORE it acts. A report printed after the fetch would name the engine that already
# changed the repo, which is the thing an operator cannot then go back and question.
_pl_rep="$(printf '%s\n' "$out_pull" | /usr/bin/grep -n "running engine (which core is executing THIS command)" | head -n1 | cut -d: -f1)"
_pl_act="$(printf '%s\n' "$out_pull" | /usr/bin/grep -nE "cloning core|fetching tags" | head -n1 | cut -d: -f1)"
if [ -z "$_pl_rep" ] || [ -z "$_pl_act" ]; then
  bad "could not locate both the engine report and the first clone/fetch in pull's output — the ordering lane proves nothing"
elif [ "$_pl_rep" -lt "$_pl_act" ]; then
  ok "pull says who is speaking BEFORE it touches the core (report at line $_pl_rep, first fetch/clone at $_pl_act)"
else
  bad "pull reported the running engine only AFTER it had already started moving the pin (report at line $_pl_rep, first fetch/clone at $_pl_act)"
fi
[ -f "$RPULL/.kickoff/core.lock" ] \
  && [ "$(/usr/bin/grep -c "^commit $CB\$" "$RPULL/.kickoff/core.lock" 2>/dev/null || printf 0)" = 1 ] \
  && ok "the failed pull left the existing core.lock untouched (the report is reporting, not writing)" \
  || bad "the pull fixture's core.lock was rewritten or lost — the lane is no longer reporting-only"

# ════════════════════════════════════════════════════════════════════════════════════════════════
printf '\n4. NO OVER-CLAIM — the pinned COMMIT on a DIRTY tree is NOT the pin\n'
# ════════════════════════════════════════════════════════════════════════════════════════════════
# scripts/preflight.sh #6 (the format-2 arm) defines a satisfied pin as HEAD == commit AND the tag
# resolving to that commit AND a CLEAN tree — a dirty checkout is a copied-and-patched core. So an
# engine sitting at the right commit with local edits is running code that is NOT the pinned code,
# and must not be ticked as "IS the pin".
printf 'a local edit that is not in the pinned commit\n' > "$ENGB/DIRTY-EDIT"
out_dirty="$(run_from "$ENGB" "$T" status --dir "$R")"
rm -f "$ENGB/DIRTY-EDIT"
# The core-pin block already prints "tree=DIRTY/unverifiable" about the CLONE, so a bare *dirty*
# match passes vacuously (observed on the RED run) — hence the ✗ glyph, the verdict CLASS and the
# identity report's OWN sentence bound to one line.
lane_not "$out_dirty" "but its tree is DIRTY" \
  "a DIRTY running tree at the pinned commit is ✗ NOT the pin, and the verdict says WHY (the RUNNING tree is dirty)"
# and the positive control for the lane above: with the edit removed, the SAME engine is the pin
# again. Without this, "never says IS" would pass vacuously.
out_clean="$(run_from "$ENGB" "$T" status --dir "$R")"
lane_is "$out_clean" "ESTABLISHED for the tree at" \
  "POSITIVE CONTROL: with the edit removed the same engine IS the pin again (the lane above is not vacuous)"

# ── …AND "CLEAN" MAY NOT MEAN "`git status` PRINTED NOTHING" ────────────────────────────────────
# The dirty lane above is answered by `git status --porcelain` — and status is SILENT about a
# tracked file the INDEX has been told not to compare. MEASURED: `git update-index
# --assume-unchanged README.md` followed by an edit leaves `status --porcelain` EMPTY, and the
# front door ticked "✓ IS the pin" on a tree whose code demonstrably differs from the pinned commit.
# `--skip-worktree` is the same hole with a different bit. This is the DIRTY lane's own failure mode
# reached through the instrument instead of the tree, so it gets its own lane per bit — and the
# honest answer is CANNOT DETERMINE (the question was not answered), never a tick.
for _bit in assume-unchanged skip-worktree; do
  git -C "$ENGB" update-index "--$_bit" README.md >/dev/null 2>&1
  printf 'a local edit that is not in the pinned commit\n' >> "$ENGB/README.md"
  # NEGATIVE CONTROL: the whole point is that `status` cannot see this. If it CAN, the lane is just
  # the dirty lane again and proves nothing about the index bit.
  if [ -n "$(git -C "$ENGB" status --porcelain 2>/dev/null)" ]; then
    bad "fixture [$_bit]: \`git status --porcelain\` still reports the modified file, so the index bit is not suppressing anything — the lane would be vacuous"
  else
    lane_cannot_determine "$(run_from "$ENGB" "$T" status --dir "$R")" \
      "its index marks tracked path(s) as un-comparable" \
      "INDEX-SUPPRESSED CLEANLINESS [$_bit]: a modified tracked file that \`git status\` cannot see is not a clean tree — the pin is declined, not ticked"
  fi
  git -C "$ENGB" update-index "--no-$_bit" README.md >/dev/null 2>&1
  git -C "$ENGB" checkout -- README.md >/dev/null 2>&1
done
lane_is "$(run_from "$ENGB" "$T" status --dir "$R")" "ESTABLISHED for the tree at" \
  "POSITIVE CONTROL: with the index bits cleared the same engine IS the pin again (the two lanes above are not vacuous)"

# ── the two remaining arms of preflight #6's definition, each with a lane that has been WATCHED
# ── to fail. Both were added because a mutant SURVIVED without them: neutering the tag comparison,
# ── and turning "the tag does not resolve here" into a tick, both passed the suite unnoticed.
# A MOVED TAG: the running engine is at the pinned commit on a clean tree, but its own tag now
# names something else — a re-tagged release. preflight #6 calls that a failed pin; so must this.
git -C "$ENGB" tag -f core-vENGB "$CB_PARENT" >/dev/null 2>&1
out_moved="$(run_from "$ENGB" "$T" status --dir "$R")"
git -C "$ENGB" tag -f core-vENGB "$CB" >/dev/null 2>&1
case "$out_moved" in
  *"IS this repo's pinned engine"*) bad "OVER-CLAIM: a MOVED tag was ticked as the pin — preflight #6 requires the tag to resolve to the pinned commit" ;;
  *"tag core-vENGB now names"*)     ok "a MOVED tag is not the pin, and the report says the tag moved" ;;
  *"is NOT this repo's pinned engine"*|*"CANNOT DETERMINE"*) ok "a MOVED tag is not ticked as the pin" ;;
  *) bad "no verdict on the moved-tag engine" ;;
esac
# A TAG THAT DOES NOT RESOLVE HERE: everything checkable checks out, and the last arm cannot be
# established. That is an UNKNOWN, and an unknown may not be ticked.
RNT="$T/tag-not-here"; mkrepo "$RNT"
pin "$RNT" core-vNOSUCHTAG "$CB"
printf 'export KICKOFF_CORE_DIR="%s"\n' "$ENGB" > "$RNT/.kickoff/instance.env"
lane_cannot_determine "$(run_from "$ENGB" "$T" status --dir "$RNT")" \
  "is not a TAG in it — only refs/tags/ is consulted" \
  "a pinned tag that does not resolve in the running engine is an honest CANNOT DETERMINE, not a tick"
# and the positive control for BOTH lanes above: with the tag restored and the real lock, the same
# engine IS the pin. Without it, "never says IS" would be passing for the wrong reason.
out_restored="$(run_from "$ENGB" "$T" status --dir "$R")"
case "$out_restored" in
  *"IS this repo's pinned engine"*) ok "POSITIVE CONTROL: tag restored → the same engine IS the pin again (the two lanes above are not vacuous)" ;;
  *) bad "POSITIVE CONTROL FAILED: the engine is never the pin after the tag lanes, so they prove nothing" ;;
esac

# ── A CLAUSE ABOUT A CHECK THAT NEVER RAN ───────────────────────────────────────────────────────
# The tag arm runs ONLY when the lock records a `tag` line. The ✓ printed "the tag resolves to it"
# UNCONDITIONALLY — so for a tag-less lock the operator read an affirmation of a comparison that no
# line of code performed. Not a false verdict; a false REASON, which is worse, because it is what
# the operator would go and check if they doubted the tick.
RNOTAG="$T/lock-no-tag"; mkrepo "$RNOTAG"; mkdir -p "$RNOTAG/.kickoff"
printf 'format 2\ncommit %s\n' "$CB" > "$RNOTAG/.kickoff/core.lock"
printf 'export KICKOFF_CORE_DIR="%s"\n' "$ENGB" > "$RNOTAG/.kickoff/instance.env"
out_notag="$(run_from "$ENGB" "$T" status --dir "$RNOTAG")"
lane_is "$out_notag" "the lock records no \`tag\` line, so no tag was checked" \
  "TAG-LESS LOCK: the ✓ says the lock records NO tag, instead of affirming a tag comparison that never ran"
_notag_line="$(printf '%s\n' "$out_notag" | /usr/bin/grep -F "✓ $IS_CLASS" | head -n1)"
case "$_notag_line" in
  *"resolves to that same commit"*|*"the tag resolves to it"*)
    bad "TAG-LESS LOCK: the ✓ still affirms that a tag resolves, for a lock that records no tag and an arm that never ran: $_notag_line" ;;
  *) ok "TAG-LESS LOCK: the ✓ carries no tag-resolution clause at all when there was no tag to resolve" ;;
esac
# …and the POSITIVE half, on the SAME clause: with a tag in the lock the arm DOES run, and the ✓
# must say so. Without this, deleting the clause outright would pass the lane above.
case "$(printf '%s\n' "$out_is" | /usr/bin/grep -F "✓ $IS_CLASS" | head -n1)" in
  *"refs/tags/core-vENGB in this tree resolves to that same commit"*)
    ok "POSITIVE CONTROL: with a tag IN the lock the ✓ does name the tag it resolved (the tag-less lane is not vacuous)" ;;
  *) bad "POSITIVE CONTROL: the ✓ never names a resolved tag even when the lock records one — the tag-less lane would pass on a deleted clause" ;;
esac

# ── A THIRD WORLD THE TWO-BRANCH CLAUSE DESCRIBED WITH THE WRONG SENTENCE ────────────────────────
# A `tag` line carrying NO VALUE (`tag`, or `tag ` — trailing-trimmed to the same thing) does not
# match the parser's `"tag "*` arm, so $EITP_LOCK_TAG stays empty and the ✓ told the operator "the
# lock records no tag". The lock records one; it is just unusable. Three worlds, two sentences —
# one of them was describing a file that is not the file on disk.
for _tv in 'tag' 'tag '; do
  RBARE="$T/lock-bare-tag-$(printf '%s' "$_tv" | tr -d ' ' | wc -c)"; mkrepo "$RBARE"; mkdir -p "$RBARE/.kickoff"
  { printf 'format 2\n'; printf '%s\n' "$_tv"; printf 'commit %s\n' "$CB"; } > "$RBARE/.kickoff/core.lock"
  printf 'export KICKOFF_CORE_DIR="%s"\n' "$ENGB" > "$RBARE/.kickoff/instance.env"
  out_bare="$(run_from "$ENGB" "$T" status --dir "$RBARE")"
  lane_is "$out_bare" "the lock's \`tag\` line carries no value, so there was no tag name to look up" \
    "VALUELESS \`tag\` LINE ['$_tv']: the ✓ says the line is there and empty — not that the lock records no tag at all"
  case "$(printf '%s\n' "$out_bare" | /usr/bin/grep -F "✓ $IS_CLASS" | head -n1)" in
    *"records no \`tag\` line"*)
      bad "VALUELESS \`tag\` LINE ['$_tv']: the ✓ tells the operator the lock records NO \`tag\` line, about a lock whose first directive after \`format 2\` IS one" ;;
    *) ok "VALUELESS \`tag\` LINE ['$_tv']: the ✓ does not claim the \`tag\` line is absent" ;;
  esac
done

# ── AND THE THREE LOCK VALUES FOR WHICH "THE PINNED TAG RESOLVES" WAS VACUOUS OR MISLABELLED ─────
# `rev-parse <value>^{commit}` resolves ANY revision. So for three lock values the ✓ printed a
# tag-resolution clause that certified nothing — ALL THREE REPRODUCED printing "✓ IS the pin":
#   · `tag HEAD`             — `HEAD^{commit}` IS HEAD. Once HEAD == the pinned commit (already
#                              checked one arm earlier) this clause CANNOT fail. Vacuous by
#                              construction, and it calls HEAD a tag.
#   · `tag <the pinned sha>` — a commit id resolves to itself. Same tautology.
#   · `tag <a branch name>`  — resolves, and is not a tag at all.
# The fix is this file's OWN idiom, already applied once in cmd_pull for the same reason: scope the
# lookup to refs/tags/. Each of the three now comes out as an honest CANNOT DETERMINE.
# The BRANCH case is the sharpest and gets a NEGATIVE CONTROL, because it is the one that is not
# self-evidently degenerate: a branch is a real ref, at the real commit, and the old clause named
# it "the pinned tag".
git -C "$ENGB" branch -f not-a-tag "$CB" >/dev/null 2>&1
if [ -z "$(git -C "$ENGB" rev-parse -q --verify 'not-a-tag^{commit}' 2>/dev/null)" ]; then
  bad "fixture [non-tag revisions]: the planted BRANCH does not resolve in engine B — the lane would be vacuous"
elif [ -n "$(git -C "$ENGB" rev-parse -q --verify 'refs/tags/not-a-tag^{commit}' 2>/dev/null)" ]; then
  bad "fixture [non-tag revisions]: \`not-a-tag\` somehow IS a tag in engine B — the lane would prove nothing"
else
  ok "NEGATIVE CONTROL [non-tag revisions]: a BRANCH at the pinned commit resolves under a bare \`<value>^{commit}\` and NOT under refs/tags/ — the old lookup could not tell the two apart"
  for _tv in HEAD "$CB" not-a-tag; do
    RNTV="$T/lock-nontag-$(printf '%s' "$_tv" | cut -c1-8)"; mkrepo "$RNTV"; mkdir -p "$RNTV/.kickoff"
    { printf 'format 2\n'; printf 'tag %s\n' "$_tv"; printf 'commit %s\n' "$CB"; } > "$RNTV/.kickoff/core.lock"
    printf 'export KICKOFF_CORE_DIR="%s"\n' "$ENGB" > "$RNTV/.kickoff/instance.env"
    lane_cannot_determine "$(run_from "$ENGB" "$T" status --dir "$RNTV")" \
      "is not a TAG in it — only refs/tags/ is consulted" \
      "NON-TAG \`tag\` VALUE ['${_tv:0:12}']: a lock value that is not a tag is declined, not ticked with a clause claiming a tag resolved"
  done
fi
git -C "$ENGB" branch -D not-a-tag >/dev/null 2>&1
lane_is "$(run_from "$ENGB" "$T" status --dir "$R")" "ESTABLISHED for the tree at" \
  "POSITIVE CONTROL: with the real tag lock the same engine IS the pin again (the non-tag lanes are not vacuous)"

# ── ONE SCREEN MAY NOT CONTRADICT ITSELF: the core-pin ✓ used UNSEALED git ───────────────────────
# _report_running_engine asks about $EITP_RUNNING through _eitp_git's allowlisted environment; the
# core-pin block eight lines below asked about $core_dir with PLAIN `git`. In the ordinary case
# those are the SAME DIRECTORY — so one screen answered one question twice, under two environments.
# REPRODUCED with the system-scoped poison from §(v): the identity block printed
#     ✗ … its tree is DIRTY
# and the core-pin block printed
#     ✓ core pin HOLDS — … on a clean tree
# about the same path, on the same screen. The wrong half was the unsealed ✓.
if [ ! -x "$_sysshim/git" ]; then
  bad "fixture [one screen]: the system-config shim from §(v) is missing — the contradiction lane cannot run"
else
  printf 'an untracked file that is not in the pinned commit\n' > "$ENGB/UNTRACKED-POISON-PROBE"
  _1s_out="$( cd "$T" && env -u REPO_DIR -u KICKOFF_CORE_DIR -u KICKOFF_RUNNING_DIR -u KICKOFF_RUNNING_SELF \
      -u TELEGRAM_STATE_DIR -u MEMORY_DIR -u MEMORY_INDEX -u MC_STATE_FILE -u CHANNEL_SPEC -u INSTANCE_ENV \
      PATH="$_sysshim:$PATH" timeout 180 bash "$ENGB/scripts/kickoff" status --dir "$R" 2>&1 )"
  rm -f "$ENGB/UNTRACKED-POISON-PROBE"
  # both halves, on the SAME output: the identity block must call it dirty, and the core-pin block
  # must NOT print a clean-tree tick about the very same directory.
  case "$_1s_out" in
    *"but its tree is DIRTY"*) : ;;
    *) bad "fixture [one screen]: the identity block did not report engine B dirty under the poison — the contradiction lane would be vacuous" ;;
  esac
  case "$_1s_out" in
    *"core pin HOLDS"*"on a clean tree"*)
      bad "ONE SCREEN: the core-pin block still ticks \"HOLDS — … on a clean tree\" about the SAME directory the identity block eight lines above called DIRTY — it is reading git under an environment that block refuses to trust" ;;
    *"core pin BROKEN"*)
      ok "ONE SCREEN: with the identity block reporting the running engine DIRTY, the core-pin block reports the SAME directory BROKEN — the two halves of the screen agree, because both now read git through the same seal" ;;
    *) bad "ONE SCREEN: the core-pin block printed neither HOLDS nor BROKEN — the lane cannot see what it exists to catch: $(printf '%s\n' "$_1s_out" | /usr/bin/grep -F 'core pin' | head -2 | tr '\n' '|')" ;;
  esac
  # …AND THE SAME TICK IN `verify`. §3 above already pairs status' "core pin HOLDS" with verify's
  # "core.lock COHERENT" — they are the same claim on the same screen, and they read git the same
  # way or one of them is the unsealed half.
  printf 'an untracked file that is not in the pinned commit\n' > "$ENGB/UNTRACKED-POISON-PROBE"
  _1v_out="$( cd "$T" && env -u REPO_DIR -u KICKOFF_CORE_DIR -u KICKOFF_RUNNING_DIR -u KICKOFF_RUNNING_SELF \
      -u TELEGRAM_STATE_DIR -u MEMORY_DIR -u MEMORY_INDEX -u MC_STATE_FILE -u CHANNEL_SPEC -u INSTANCE_ENV \
      PATH="$_sysshim:$PATH" timeout 180 bash "$ENGB/scripts/kickoff" verify --dir "$R" 2>&1 )"
  rm -f "$ENGB/UNTRACKED-POISON-PROBE"
  case "$_1v_out" in
    *"but its tree is DIRTY"*) : ;;
    *) bad "fixture [one screen · verify]: the identity block did not report engine B dirty under the poison — the verify half of the lane would be vacuous" ;;
  esac
  case "$_1v_out" in
    *"core.lock COHERENT"*"on a clean tree"*)
      bad "ONE SCREEN [verify]: \`verify\` still ticks \"core.lock COHERENT — … on a clean tree\" about the SAME directory its own identity block called DIRTY" ;;
    *"core.lock INCOHERENT"*)
      ok "ONE SCREEN [verify]: verify's tick reads git through the same seal as its identity block — the screen agrees with itself" ;;
    *) bad "ONE SCREEN [verify]: verify printed neither COHERENT nor INCOHERENT — the lane cannot see what it exists to catch: $(printf '%s\n' "$_1v_out" | /usr/bin/grep -F 'core.lock' | head -2 | tr '\n' '|')" ;;
  esac
fi
lane_is "$(run_from "$ENGB" "$T" status --dir "$R")" "ESTABLISHED for the tree at" \
  "POSITIVE CONTROL: with the probe removed engine B IS the pin again (the one-screen lane is not vacuous)"

# ── THE HOLE THAT IS NOT SEALED, AND MUST THEREFORE NOT BE CLAIMED ──────────────────────────────
# `core.trustctime=false` in the running engine's OWN `.git/config`, next to a same-size in-place
# rewrite of a tracked file with its mtime restored, leaves `git status` SILENT about TAMPERED
# TRACKED CONTENT. REPRODUCED. It is NOT sealed: that config file is inside the repository the call
# is asking about, so nulling it would be asking git a different question, and re-hashing the tree
# is a separate slice. What changed is what the ✓ SAYS — and this lane is the one that holds it,
# because it is the world in which the old wording ("no tracked file differs from it") was a
# provable lie printed to the operator.
_tt_file="$ENGB/ENGINE-MARKER"
_tt_pinned="$(git -C "$ENGB" show "HEAD:ENGINE-MARKER" 2>/dev/null || true)"
if [ -z "$_tt_pinned" ] || [ ! -f "$_tt_file" ]; then
  bad "fixture [core.trustctime]: no tracked marker file to tamper — the lane would be vacuous"
else
  _tt_mtime="$(stat -c %y "$_tt_file" 2>/dev/null || true)"
  # SAME SIZE, in place: change one byte and nothing else, then put the mtime back. ctime still
  # moves — and core.trustctime=false is precisely the instruction to ignore that.
  python3 -c 'import sys
p=sys.argv[1]; b=bytearray(open(p,"rb").read())
for i,c in enumerate(b):
    if chr(c).isalpha(): b[i]=ord("Z") if chr(c)!="Z" else ord("Y"); break
f=open(p,"r+b"); f.write(bytes(b)); f.close()' "$_tt_file" 2>/dev/null
  [ -n "$_tt_mtime" ] && touch -d "$_tt_mtime" "$_tt_file" 2>/dev/null
  git -C "$ENGB" config core.trustctime false >/dev/null 2>&1
  _tt_now="$(cat "$_tt_file" 2>/dev/null || true)"
  _tt_dirt="$(git -C "$ENGB" status --porcelain 2>/dev/null || printf 'STATUS-FAILED')"
  if [ "$_tt_now" = "$_tt_pinned" ]; then
    bad "fixture [core.trustctime]: the in-place rewrite did not change the file — the lane would be vacuous"
  elif [ -n "$_tt_dirt" ]; then
    bad "fixture [core.trustctime]: \`git status\` still reports the tamper in this git (got '$_tt_dirt') — the lane would be the ordinary dirty lane again"
  else
    ok "NEGATIVE CONTROL [core.trustctime]: a same-size in-place rewrite of a TRACKED file is INVISIBLE to \`git status\` here (on-disk '${_tt_now}' vs pinned '${_tt_pinned}')"
    out_tt="$(run_from "$ENGB" "$T" status --dir "$R")"
    # The verdict IS still ✓ — honestly so: HEAD matches and git reported nothing. What may not
    # survive is the CONTENT claim, because the content demonstrably differs from the pin.
    _tt_line="$(printf '%s\n' "$out_tt" | /usr/bin/grep -F "✓ $IS_CLASS" | head -n1)"
    if [ -z "$_tt_line" ]; then
      ok "TAMPERED TRACKED CONTENT [core.trustctime]: the front door does not tick at all here — stronger than required"
    else
      case "$_tt_line" in
        *"no tracked file differs from it"*)
          bad "TAMPERED TRACKED CONTENT [core.trustctime]: the ✓ tells the operator \"no tracked file differs from it\" while a tracked file demonstrably does — the exact over-claim, printed in the operator's own words: $_tt_line" ;;
        *"not a proof of what this tree CONTAINS"*"NOT verified: the content of the tracked files"*)
          ok "TAMPERED TRACKED CONTENT [core.trustctime]: the ✓ claims only the ref-identity match and names tracked-file CONTENT as NOT verified — true of this world, tamper and all" ;;
        *) bad "TAMPERED TRACKED CONTENT [core.trustctime]: the ✓ neither over-claims nor carries the content disclaimer — unaccounted for: $_tt_line" ;;
      esac
    fi
  fi
  git -C "$ENGB" config --unset core.trustctime >/dev/null 2>&1
  git -C "$ENGB" checkout -- ENGINE-MARKER >/dev/null 2>&1
  git -C "$ENGB" reset -q --hard HEAD >/dev/null 2>&1
fi
lane_is "$(run_from "$ENGB" "$T" status --dir "$R")" "ESTABLISHED for the tree at" \
  "POSITIVE CONTROL: with the tamper reverted engine B IS the pin again (the trustctime lane is not vacuous)"

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && printf '  ✅ the engine says which engine it is — told, not sensed; no tick on an unknown\n'
[ "$FAIL" -eq 0 ]
