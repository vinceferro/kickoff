#!/usr/bin/env bash
# release-gate-selftest.sh — prove every check in scripts/release-gate.sh actually gates the failure it
# exists to catch, and that the LOCKED severity model holds: HARD [FAIL] blocks the tag; ADVISORY [WARN]
# is printed + counted but NEVER flips the exit code.
#
#   bash scripts/release-gate-selftest.sh
#
# RED-FIRST. Every check gets a lane that goes RED on a tree carrying the defect and GREEN when it is
# fixed. Where the defect is REAL and HISTORICAL we gate the real tags; where it is not, we build a
# hermetic /tmp git fixture. A lane that could pass vacuously is called out and given a non-vacuity
# assertion (it must name the file / the count / the suite it actually saw).
#
#   (a) plugin-version  REAL BUG  → RED  : core-v0.7→core-v0.8 (skills changed, version stayed 0.3.1).
#   (b) plugin-version  REAL FIX  → GREEN: core-v0.8→core-v0.8.1 — and GREEN *with 2 advisories*, which
#                                          is the severity model proven on real data.
#   (c)(d) SYNTH bump / no-bump   → GREEN / RED (controlled mirror of (a)).
#   (d2)(d3) SYNTH plugin.json    → a plugin.json CONTENT edit (a command registered) with NO version bump
#                                   ⇒ RED (the HIGH finding: plugin.json is NOT carved out of the content
#                                   check — it bricks preflight #8 too); the SAME edit WITH a bump ⇒ GREEN.
#   (e)(f) fail-loud edges · --candidate defaults to HEAD.
#   (g) leak-scan       SYNTH     → RED on a scratchpad machine-path, a denylisted identity, and a
#                                   $USER-derived home path; GREEN when scrubbed; RED (fail-closed) with
#                                   NO denylist configured; RED (HARD) when scan-secrets.sh is ABSENT (g8 —
#                                   a dropped core scanner must not bank a green). REAL: clean on
#                                   core-v0.8.1, RED on dev HEAD.
#   (h) suites          SYNTH     → RED on a red suite / a timeout / a declared-but-absent suite / no
#                                   lefthook; GREEN on an all-green tree; UNMISSABLE advisory on
#                                   --skip-suites; must NOT run its own selftest (recursion); a RED suite
#                                   invoked by a NON-bash runner (`sh …`) is DISCOVERED + run (h8/h9 —
#                                   discovery is not `bash `-only); and a TIMED-OUT suite's setsid'd child
#                                   is REAPED by exact PID, never left to orphan the shared box (h10).
#   (i) manifest        SYNTH     → RED (HARD) when the manifest lists a file the tree lacks (cmd_pull
#                                   dies at step 4 → the release is untakeable); WARN (ADVISORY) for a
#                                   new unlisted file.  REAL: all 61 entries present at core-v0.8.1.
#   (j) changelog       SYNTH     → WARN on an empty top section / a --version mismatch.  REAL: PASSES on
#                                   core-v0.8.1 whose heading says "— unreleased" — the date-trap guard
#                                   (a date check would false-RED 100% of historical releases).
#   (k) installer       REAL      → WARN on core-v0.8.1 (install.sh's own header still names core-v0.8 —
#                                   a REAL, shipped defect) and PASS on core-v0.8 (all 5 URLs agree).
#   (l) severity model            → summary arithmetic (passed+failed+advisories == total), an
#                                   advisory-only run is GREEN, --only fails loud + prints PARTIAL.
#
# NOT COVERED HERE — and deliberately so: this suite does NOT run the gate's real 16-suite battery
# against a real tag. That takes ~2 min, spawns fixture supervisors, and this file runs on every
# pre-push. The suites CHECK is proven here on hermetic fixtures; the real-tag run is done out-of-band
# (see .kickoff/v0.9-slice2/build-gate.md — it is RED on core-v0.8.1 today: a PRE-EXISTING auth-heal
# drift that core-v0.8 shipped with, which is precisely the evidence the check must exist).
#
# SAFETY: read-only against the live repo (the gate's own worktree is a /tmp scratch it removes itself).
# Every fixture is a mktemp dir swept by ONE EXIT trap (only our OWN named dirs — never a /tmp/tmp.*
# wildcard). No process is ever pattern-killed. Every fixture leak-string is BUILT AT RUNTIME via printf
# so that this file — which ships inside the public tag the gate scans — contains no literal the gate's
# own leak patterns would match. Deps: bash + git + coreutils.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
GATE="${RELEASE_GATE_BIN:-$REPO/scripts/release-gate.sh}"

PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

# ONE EXIT trap cleans every mktemp dir — via a file side-effect so dirs mk() makes inside a
# $(command-substitution) subshell survive. NEVER a wildcard sweep of /tmp/tmp.* — only our dirs.
CLEANUP_LIST="$(mktemp)"
mk() { local d; d="$(mktemp -d)"; printf '%s\n' "$d" >> "$CLEANUP_LIST"; printf '%s' "$d"; }
# EXACT-PID backstop: each line of CHILD_PID_FILES names a file a fixture wrote its OWN child pid into.
# The GATE is what must reap those (finding h10); this trap only fires if a fix regressed — and it kills
# BY EXACT PID (from our own fixture), NEVER a pattern (pkill/killall are forbidden on this shared box).
CHILD_PID_FILES="$(mktemp)"
_selftest_cleanup() {
  if [ -f "$CHILD_PID_FILES" ]; then
    while IFS= read -r _pf; do
      [ -f "$_pf" ] || continue
      _p="$(cat "$_pf" 2>/dev/null)"
      case "$_p" in ''|*[!0-9]*) continue ;; esac
      kill -KILL "$_p" 2>/dev/null || true
    done < "$CHILD_PID_FILES"
    rm -f "$CHILD_PID_FILES"
  fi
  while IFS= read -r _d; do [ -n "$_d" ] && rm -rf "$_d"; done < "$CLEANUP_LIST"
  rm -f "$CLEANUP_LIST"
}
trap _selftest_cleanup EXIT

echo "▶ release-gate self-test (v0.9 slice 2 — 7 checks + the HARD/ADVISORY severity model)"
echo

command -v git >/dev/null 2>&1 || { echo "  ❌ git not found"; exit 1; }
[ -f "$GATE" ] || { echo "  ❌ gate not found: $GATE"; exit 1; }

# Fixture-sanity: the live tags this suite anchors on must exist (else the REAL lanes prove nothing).
for t in core-v0.7 core-v0.8 core-v0.8.1; do
  git -C "$REPO" rev-parse -q --verify "$t^{commit}" >/dev/null 2>&1 \
    || { echo "  ❌ anchor tag missing: $t (cannot run the REAL lanes)"; exit 1; }
done

# BASELINE the live repo's gate-shaped worktrees BEFORE any gate run, so (m1) can assert THIS run leaked
# none — WITHOUT flaking on another agent's concurrent worktree that was already registered (global state
# is not ours to police). (m1) compares against this snapshot, not `worktree list` in the absolute.
WT_BASELINE="$(git -C "$REPO" worktree list 2>/dev/null | grep '/wt ' | sort || true)"

# true iff pid $1 is gone within $2 seconds (the gate reaps on timeout; allow a beat for init to reap).
dead_within() {
  local pid="$1" s="$2" i=0
  [ -n "$pid" ] || return 1
  while [ "$i" -lt "$s" ]; do kill -0 "$pid" 2>/dev/null || return 0; sleep 1; i=$((i + 1)); done
  kill -0 "$pid" 2>/dev/null && return 1 || return 0
}

gi() { git -C "$1" "${@:2}"; }
new_repo() {   # echoes a fresh git repo path with identity set locally (no global config needed)
  local r; r="$(mk)"
  git -C "$r" init -q
  git -C "$r" config user.email t@t.t
  git -C "$r" config user.name  t
  printf '%s' "$r"
}

run_gate()  { G_RC=0; G_OUT="$(bash "$GATE" "$@" 2>&1)" || G_RC=$?; }
# same, with an overridden $USER — proves the leak-scan derives machine identity from the ENVIRONMENT
# instead of carrying identity literals in the (public) gate source.
run_gate_as() { local u="$1"; shift; G_RC=0; G_OUT="$(USER="$u" bash "$GATE" "$@" 2>&1)" || G_RC=$?; }
has() { printf '%s' "$G_OUT" | grep -qi -- "$1"; }

# A denylist file for the REAL-repo lanes: one literal that appears NOWHERE in the real tags, so the
# real-tree lanes exercise the structural + derived-identity patterns without this suite ever needing to
# name a private identity (it ships in the public tag; naming one here would BE the leak).
REAL_DENY="$(mk)/deny.txt"; printf '# fixture\nacme-private-org\n' > "$REAL_DENY"

# ── (a) plugin-version REAL BUG → RED (full gate) ────────────────────────────────────────────────────
echo "(a) REAL BUG — core-v0.7 → core-v0.8 (plugin skills changed, version stayed 0.3.1)"
run_gate --repo "$REPO" --candidate core-v0.8 --prev core-v0.7 --skip-suites --leak-denylist "$REAL_DENY"
A_RC=$G_RC; A_OUT="$G_OUT"
chk "(a) gate FAILS (rc!=0) — the 2026-07-13 regression is caught"        "[ $A_RC -ne 0 ]"
chk "(a) failure prints a [FAIL] line for the invariant"                  "printf '%s' \"\$A_OUT\" | grep -q '\[FAIL\] plugin-version-vs-content'"
chk "(a) failure names the version-bump remedy (plugin.json)"             "printf '%s' \"\$A_OUT\" | grep -qi 'bump' && printf '%s' \"\$A_OUT\" | grep -q 'plugin.json'"
chk "(a) SUMMARY line reports the gate RED"                               "printf '%s' \"\$A_OUT\" | grep -q '^SUMMARY:' && printf '%s' \"\$A_OUT\" | grep -qi 'RED'"
echo

# ── (b) plugin-version REAL FIX → GREEN, *with advisories* (the severity model on real data) ─────────
echo "(b) REAL FIX — core-v0.8 → core-v0.8.1 (plugin content unchanged, version 0.3.1→0.3.2)"
run_gate --repo "$REPO" --candidate core-v0.8.1 --prev core-v0.8 --skip-suites --leak-denylist "$REAL_DENY"
B_RC=$G_RC; B_OUT="$G_OUT"
chk "(b) gate PASSES (rc=0)"                                              "[ $B_RC -eq 0 ]"
chk "(b) prints a [PASS] line + GREEN summary"                            "printf '%s' \"\$B_OUT\" | grep -q '\[PASS\]' && printf '%s' \"\$B_OUT\" | grep -q 'GREEN'"
chk "(b) it is GREEN *despite* [WARN] advisories (advisories never block)" \
  "printf '%s' \"\$B_OUT\" | grep -q '\[WARN\]' && [ $B_RC -eq 0 ]"
chk "(b) the SUMMARY names the advisory count honestly"                   "printf '%s' \"\$B_OUT\" | grep -qE '^SUMMARY:.*advisor(y|ies)'"
echo

# ── (c)–(f) the plugin invariant in isolation (--only) on hermetic fixtures ──────────────────────────
# Scoped with --only so the fixture (a 2-file plugin repo, not a kickoff tree) is judged by the check it
# is built for — the other 6 checks would rightly fail-closed on a tree with no manifest/changelog.
PV=plugin-version-vs-content

build_synth_repo() {   # synth-prev (skill A, 0.1.0) → synth-nobump (skill B, version UNCHANGED) → synth-bumped (0.1.1)
  local r; r="$(new_repo)"
  mkdir -p "$r/plugin/.claude-plugin" "$r/plugin/skills/scan"
  printf '{ "name": "kickoff", "version": "0.1.0" }\n' > "$r/plugin/.claude-plugin/plugin.json"
  printf 'SKILL scan — content A\n'                    > "$r/plugin/skills/scan/SKILL.md"
  gi "$r" add -A; gi "$r" commit -qm prev;   gi "$r" tag synth-prev
  printf 'SKILL scan — content B (changed)\n'          > "$r/plugin/skills/scan/SKILL.md"   # content moves
  gi "$r" add -A; gi "$r" commit -qm nobump; gi "$r" tag synth-nobump                       # …no version bump
  printf '{ "name": "kickoff", "version": "0.1.1" }\n' > "$r/plugin/.claude-plugin/plugin.json"  # now bump
  gi "$r" add -A; gi "$r" commit -qm bumped; gi "$r" tag synth-bumped
  # plugin.json CONTENT-ONLY change (a command registered) with NO version bump — the slice-2 HIGH finding:
  # the check used to EXCLUDE plugin.json from content detection, so this bricked-but-unbumped edit passed.
  printf '{ "name": "kickoff", "version": "0.1.1", "commands": ["scan"] }\n' > "$r/plugin/.claude-plugin/plugin.json"
  gi "$r" add -A; gi "$r" commit -qm jsonnobump; gi "$r" tag synth-json-nobump
  # …the SAME kind of plugin.json edit WITH a version bump ⇒ must still PASS (not 'always fail').
  printf '{ "name": "kickoff", "version": "0.1.2", "commands": ["scan","harden"] }\n' > "$r/plugin/.claude-plugin/plugin.json"
  gi "$r" add -A; gi "$r" commit -qm jsonbump; gi "$r" tag synth-json-bump
  printf '%s' "$r"
}
SYNTH="$(build_synth_repo)"

echo "(c) SYNTH — plugin/ content changed AND plugin.json version bumped (0.1.0→0.1.1)"
run_gate --repo "$SYNTH" --candidate synth-bumped --prev synth-prev --only $PV; C_RC=$G_RC; C_OUT="$G_OUT"
chk "(c) gate PASSES (rc=0) — a present bump is accepted (not 'always fail')" "[ $C_RC -eq 0 ]"
chk "(c) PASS line names the bump (0.1.0→0.1.1 or 'bumped')" \
  "printf '%s' \"\$C_OUT\" | grep -q '\[PASS\]' && ( printf '%s' \"\$C_OUT\" | grep -qi 'bump' || printf '%s' \"\$C_OUT\" | grep -q '0.1.1' )"
echo

echo "(d) SYNTH — plugin/ content changed, version NOT bumped (stays 0.1.0)"
run_gate --repo "$SYNTH" --candidate synth-nobump --prev synth-prev --only $PV; D_RC=$G_RC; D_OUT="$G_OUT"
chk "(d) gate FAILS (rc!=0) — controlled mirror of the real bug"         "[ $D_RC -ne 0 ]"
chk "(d) failure names the actual changed plugin file (SKILL.md)"        "printf '%s' \"\$D_OUT\" | grep -q 'skills/scan/SKILL.md'"
echo

echo "(d2) SYNTH — plugin.json CONTENT changed (a command registered), version NOT bumped (HIGH finding)"
run_gate --repo "$SYNTH" --candidate synth-json-nobump --prev synth-bumped --only $PV; D2_RC=$G_RC; D2_OUT="$G_OUT"
chk "(d2) gate FAILS (rc!=0) — a plugin.json edit with no version bump bricks preflight #8 too" \
  "[ $D2_RC -ne 0 ] && printf '%s' \"\$D2_OUT\" | grep -q '\[FAIL\] plugin-version-vs-content'"
chk "(d2) failure names plugin.json as the changed file (the exclusion hole is closed)" \
  "printf '%s' \"\$D2_OUT\" | grep -q 'plugin/.claude-plugin/plugin.json'"
run_gate --repo "$SYNTH" --candidate synth-json-bump --prev synth-json-nobump --only $PV; D3_RC=$G_RC
chk "(d3) the SAME plugin.json edit WITH a version bump ⇒ GREEN (not 'always fail')" "[ $D3_RC -eq 0 ]"
echo

echo "(e) fail-loud edges — missing prev tag / absent plugin.json"
run_gate --repo "$SYNTH" --candidate synth-bumped --prev nope-does-not-exist --only $PV; E1_RC=$G_RC; E1_OUT="$G_OUT"
chk "(e) missing prev tag FAILS LOUD (rc!=0) + names it does not resolve" \
  "[ $E1_RC -ne 0 ] && printf '%s' \"\$E1_OUT\" | grep -qi 'resolve'"
NOPJ="$(new_repo)"
mkdir -p "$NOPJ/plugin/skills/scan"; printf 'A\n' > "$NOPJ/plugin/skills/scan/SKILL.md"
gi "$NOPJ" add -A; gi "$NOPJ" commit -qm p; gi "$NOPJ" tag np-prev
printf 'B\n' > "$NOPJ/plugin/skills/scan/SKILL.md"
gi "$NOPJ" add -A; gi "$NOPJ" commit -qm c; gi "$NOPJ" tag np-cand
run_gate --repo "$NOPJ" --candidate np-cand --prev np-prev --only $PV; E2_RC=$G_RC; E2_OUT="$G_OUT"
chk "(e) absent plugin.json FAILS LOUD (rc!=0) + names plugin.json" \
  "[ $E2_RC -ne 0 ] && printf '%s' \"\$E2_OUT\" | grep -q 'plugin.json'"
echo

echo "(f) --candidate defaults to HEAD (the common 'gate the working commit vs the last release' case)"
F_RC=0
F_OUT="$(cd "$SYNTH" && git checkout -q synth-nobump && bash "$GATE" --prev synth-prev --only $PV 2>&1)" || F_RC=$?
chk "(f) omitting --candidate gates HEAD (synth-nobump ⇒ RED, rc!=0)"     "[ $F_RC -ne 0 ]"
echo

# ── (g) leak-scan-on-tree (HARD — a public tag is irreversible) ──────────────────────────────────────
# Every leak string is ASSEMBLED AT RUNTIME (printf '%s') — this file ships inside the very tag the gate
# scans, so a literal here would make the gate fail on itself. The user token is 'acme', never a real one.
LEAK=leak-scan-on-tree
SCRATCHPAD="$(printf '/tmp/claude-%s/-home-%s-proj/out.txt' 1000 acme)"   # the hyphen-encoded form
HOMEPATH="$(printf '/home/%s/secret-project' acme)"                      # the plain machine-home form
DENYTERM="acme-private-org"
# The box's own machine name, read the SAME way the gate reads it. Never written into this file — it ships
# in the tag the gate scans. Empty (or unusable) ⇒ the hostname lanes skip out loud, they never bank a pass.
BOXNAME="$(hostname 2>/dev/null)"; BOXNAME="${BOXNAME%%$'\n'*}"
case "$BOXNAME" in ''|localhost|localhost.*) BOXNAME="" ;; ???*) ;; *) BOXNAME="" ;; esac

build_leak_repo() {   # leak-prev(clean) → leak-scratchpad → leak-home → leak-deny → leak-clean(scrubbed)
  local r; r="$(new_repo)"                            #                                → leak-noscanner
  mkdir -p "$r/docs" "$r/scripts"
  # a stub of the CORE secret scanner — present so the fixture exercises the structural/identity/denylist
  # patterns with the scanner in place (leak-noscanner below is the one tag that DROPS it, to prove the
  # HARD 'absent scanner' verdict). Exits 0 (clean) and contains no leak literal of its own.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$r/scripts/scan-secrets.sh"
  printf 'kickoff docs — nothing to see here\n' > "$r/docs/guide.md"
  gi "$r" add -A; gi "$r" commit -qm base; gi "$r" tag leak-prev
  printf 'see the agent output at %s\n' "$SCRATCHPAD" > "$r/docs/guide.md"
  gi "$r" add -A; gi "$r" commit -qm sp;   gi "$r" tag leak-scratchpad
  printf 'the repo lives at %s\n' "$HOMEPATH"        > "$r/docs/guide.md"
  gi "$r" add -A; gi "$r" commit -qm hp;   gi "$r" tag leak-home
  printf 'ported from the %s monorepo\n' "$DENYTERM" > "$r/docs/guide.md"
  gi "$r" add -A; gi "$r" commit -qm dl;   gi "$r" tag leak-deny
  printf 'kickoff docs — scrubbed\n'                 > "$r/docs/guide.md"
  gi "$r" add -A; gi "$r" commit -qm cl;   gi "$r" tag leak-clean
  # The MACHINE-NAME axis. Derived at run time from THIS box — never a literal, same rule as every string
  # above. Two tags on purpose: the leak itself, and the near-miss that proves the pattern is whole-token.
  if [ -n "$BOXNAME" ]; then
    printf 'the board runs on %s and is reachable there\n' "$BOXNAME" > "$r/docs/guide.md"
    gi "$r" add -A; gi "$r" commit -qm hn;  gi "$r" tag leak-hostname
    # the hostname INSIDE a longer word — a substring guard fires here, a whole-token guard must not
    printf 'the %ser utility is unrelated\n' "my${BOXNAME}"          > "$r/docs/guide.md"
    gi "$r" add -A; gi "$r" commit -qm hnn; gi "$r" tag leak-hostnear
    printf 'kickoff docs — scrubbed\n'                               > "$r/docs/guide.md"
    gi "$r" add -A; gi "$r" commit -qm cl2; gi "$r" tag leak-clean2
  fi
  # DROP the core secret scanner from an otherwise-clean tree → the HARD leak check must NOT bank a green
  # on the surviving structural patterns (they miss keys/tokens); a public tag is irreversible.
  gi "$r" rm -q scripts/scan-secrets.sh; gi "$r" commit -qm noscan; gi "$r" tag leak-noscanner
  printf '%s' "$r"
}
LK="$(build_leak_repo)"
LK_DENY="$(mk)/deny.txt"; printf '# fixture denylist\n%s\n' "$DENYTERM" > "$LK_DENY"

echo "(g) leak-scan-on-tree — the whole candidate tree, HARD (a public tag cannot be unpublished)"
run_gate --repo "$LK" --candidate leak-scratchpad --prev leak-prev --only $LEAK --leak-denylist "$LK_DENY"
chk "(g1) a scratchpad machine-path (hyphen-encoded) ⇒ RED"              "[ $G_RC -ne 0 ] && has '\[FAIL\] leak-scan'"
chk "(g1) …and it names the offending file"                              "has 'docs/guide.md'"
run_gate --repo "$LK" --candidate leak-deny --prev leak-prev --only $LEAK --leak-denylist "$LK_DENY"
chk "(g2) a DENYLISTED identity (private org / third-party adopter) ⇒ RED" "[ $G_RC -ne 0 ] && has 'denylisted term'"
run_gate_as acme --repo "$LK" --candidate leak-home --prev leak-prev --only $LEAK --leak-denylist "$LK_DENY"
chk "(g3) a /home/<user> path ⇒ RED via identity DERIVED from \$USER (no literal in the gate)" \
  "[ $G_RC -ne 0 ] && has 'home\[/.-\]acme'"
run_gate --repo "$LK" --candidate leak-clean --prev leak-prev --only $LEAK --leak-denylist "$LK_DENY"
chk "(g4) the scrubbed tree (scanner present) ⇒ GREEN (not 'always fail')" "[ $G_RC -eq 0 ] && has '\[PASS\] leak-scan'"
chk "(g4) …and the PASS is HONEST that scan-secrets.sh actually RAN (rc=0)" \
  "has 'scan-secrets.sh: rc=0'"
run_gate --repo "$LK" --candidate leak-clean --prev leak-prev --only $LEAK --leak-denylist "$LK/nonexistent.txt"
chk "(g5) NO denylist configured ⇒ FAIL-CLOSED (rc!=0), never a silent green" \
  "[ $G_RC -ne 0 ] && has 'denylist'"
# FINDING (slice 2): an otherwise-CLEAN tree that DROPPED scripts/scan-secrets.sh must be HARD RED — the
# structural patterns alone do NOT catch keys/tokens, so banking a green here would certify a secret-carrying
# release. The scanner is a core file; its absence is itself a defect. (Was a silent [PASS] before the fix.)
run_gate --repo "$LK" --candidate leak-noscanner --prev leak-prev --only $LEAK --leak-denylist "$LK_DENY"
chk "(g8) an ABSENT scan-secrets.sh ⇒ HARD RED (rc!=0), never a banked green" \
  "[ $G_RC -ne 0 ] && has '\[FAIL\] leak-scan' && has 'scan-secrets.sh is ABSENT'"
# (g9) THE MACHINE-NAME AXIS. Until this landed, every identity pattern was anchored on the literal `home`,
# so the guard saw a machine only through a home PATH — and a hostname bare in prose, in a MagicDNS URL, or
# after an `@` walked straight through. Not hypothetical: this repo's own TRACKER-ARCHIVE.md carries this
# box's hostname and the gate certified that tree clean. Three lanes, because one would prove the wrong
# thing: the CATCH, the NO-FALSE-FIRE control (a guard that cries wolf gets bypassed, so over-tightening is
# a real failure here, not a safe one), and the STILL-GREEN control (proves the new pattern is not always-fire).
if [ -n "$BOXNAME" ]; then
  run_gate --repo "$LK" --candidate leak-hostname --prev leak-prev --only $LEAK --leak-denylist "$LK_DENY"
  chk "(g9) the box's HOSTNAME bare in prose ⇒ RED (identity derived at run time, no literal in the gate)" \
    "[ $G_RC -ne 0 ] && has '\[FAIL\] leak-scan' && has 'docs/guide.md'"
  run_gate --repo "$LK" --candidate leak-hostnear --prev leak-prev --only $LEAK --leak-denylist "$LK_DENY"
  chk "(g9) the hostname INSIDE a longer word ⇒ GREEN (whole-token, not substring — no cry-wolf)" \
    "[ $G_RC -eq 0 ] && has '\[PASS\] leak-scan'"
  run_gate --repo "$LK" --candidate leak-clean2 --prev leak-prev --only $LEAK --leak-denylist "$LK_DENY"
  chk "(g9) a tree with no machine name ⇒ GREEN, and the PASS SAYS the axis is covered (no silent drop)" \
    "[ $G_RC -eq 0 ] && has 'hostname: covered'"
else
  printf '  ⏭  (g9) skipped — this box has no usable machine name to derive from (nothing to prove, not a pass)\n'
fi
# REAL: the curated release tree is clean; the dev tree is not.
run_gate --repo "$REPO" --candidate core-v0.8.1 --prev core-v0.8 --only $LEAK --leak-denylist "$REAL_DENY"
chk "(g6) REAL core-v0.8.1 (a ~300-file curated tree) ⇒ GREEN — no false positive" "[ $G_RC -eq 0 ]"
chk "(g6) non-vacuity: the PASS names the patterns + that scan-secrets.sh really ran (rc=0)" \
  "has 'structural/identity patterns' && has 'scan-secrets.sh: rc=0'"
# The dev branch carries real machine paths (TRACKER-ARCHIVE, design docs). Derive the token at runtime —
# NEVER write it here. If this checkout has no such path (a fresh clone by another user), the lane has
# nothing to catch: say so out loud rather than bank a vacuous pass.
DEV_TOK="$(id -un 2>/dev/null)"
if git -C "$REPO" grep -IilE -e "home[/.-]${DEV_TOK}" HEAD -- . >/dev/null 2>&1; then
  run_gate --repo "$REPO" --candidate HEAD --prev core-v0.8.1 --only $LEAK --leak-denylist "$REAL_DENY"
  chk "(g7) REAL dev HEAD (uncurated) ⇒ RED — tagging the dev tree would publish machine paths" \
    "[ $G_RC -ne 0 ] && has '\[FAIL\] leak-scan'"
else
  printf '  ⏭  (g7) skipped — this checkout carries no machine path for the lane to catch (nothing to prove, not a pass)\n'
fi
echo

# ── (g12) AMBIENT IDENTITY IS A GUESS — it must not HARD-block on a word it did not cause ─────────────
# Cost, 2026-08-27: a second machine whose hostname is `alarm` ran THIS suite on byte-identical code
# and got 60 pass / 7 fail while this box got 67/0. The leak scan derives patterns from the running
# box's username and hostname (correctly — naming identity literals in a public gate WOULD be the
# leak), and `alarm` is 5 chars, so it cleared the >=3 guard and was grepped against the whole tree.
# core-v0.8.1 carries that word in 19 files of ordinary prose ("escalation alarm", "re-alarm"), so the
# scan reported a HARD leak. Lanes (b), (g6) and — because they parse (b)'s SUMMARY — (l1)/(l2) all
# went red together, and since this suite is a registered pre-push gate it blocked EVERY push from
# that machine. Nothing was leaking. The gate was reading the box's name into the tree.
#
# The rule now: an AMBIENT pattern that ALSO matches the PREVIOUS tag was not introduced by this
# candidate, so it is an ADVISORY. An operator-authored denylist term stays HARD in every case.
# HOSTNAME is the seam — the gate reads `hostname`, $HOSTNAME and /etc/hostname, so overriding the
# variable adds the pattern without renaming the box.
echo "(g12) ambient identity (hostname) — advisory when pre-existing, HARD when introduced"
run_gate_host() { local h="$1"; shift; G_RC=0; G_OUT="$(HOSTNAME="$h" bash "$GATE" "$@" 2>&1)" || G_RC=$?; }

# Only meaningful if the word really is in the old tree — otherwise the lane proves nothing.
if [ "$(git -C "$REPO" grep -IilF -e alarm core-v0.8.1 -- ':/' 2>/dev/null | wc -l)" -gt 0 ]; then
  run_gate_host alarm --repo "$REPO" --candidate core-v0.8.1 --prev core-v0.8 --only $LEAK --leak-denylist "$REAL_DENY"
  chk "(g12a) a hostname colliding with ordinary prose does NOT block (rc=0) [RED pre-fix]" "[ $G_RC -eq 0 ]"
  chk "(g12b) …it is reported as an ADVISORY, not silently dropped" "has '\[WARN\] leak-scan'"
  chk "(g12c) …and the advisory names the colliding pattern"        "has 'alarm'"
  chk "(g12d) …while the check itself still PASSES the tree"        "has '\[PASS\] leak-scan'"
else
  printf '  ⏭  (g8a-d) skipped — core-v0.8.1 no longer carries the collision word (nothing to prove)\n'
fi

# NEGATIVE CONTROL — the load-bearing half. Without it the fix could be "never hard-block on a
# hostname", which would be a hole, not a fix. A term the candidate INTRODUCES must still block.
if [ "$(git -C "$REPO" grep -IilF -e opencode core-v0.8.1 -- ':/' 2>/dev/null | wc -l)" -eq 0 ] \
   && [ "$(git -C "$REPO" grep -IilF -e opencode HEAD -- ':/' 2>/dev/null | wc -l)" -gt 0 ]; then
  run_gate_host opencode --repo "$REPO" --candidate HEAD --prev core-v0.8.1 --only $LEAK --leak-denylist "$REAL_DENY"
  chk "(g12e) NEGATIVE CONTROL: a hostname the candidate INTRODUCES still HARD-blocks (rc≠0)" \
    "[ $G_RC -ne 0 ] && has '\[FAIL\] leak-scan'"
else
  printf '  ⏭  (g12e) skipped — no term found that HEAD introduces over core-v0.8.1 (the control would be vacuous)\n'
fi
echo

# ── (h) suites-on-exact-tree (HARD — the suites ARE the adopter-facing machinery) ────────────────────
SUITES=suites-on-exact-tree
lefthook_with() {   # $1=repo, rest = suite paths to declare under pre-push
  local r="$1"; shift
  { printf 'pre-commit:\n  commands:\n    secret-scan:\n      run: true\n\npre-push:\n  commands:\n'
    local s
    for s in "$@"; do printf '    %s:\n      run: bash %s\n' "$(basename "$s" .sh)" "$s"; done
  } > "$r/lefthook.yml"
}
build_suites_repo() {
  local r; r="$(new_repo)"
  mkdir -p "$r/scripts"
  printf '#!/usr/bin/env bash\necho "alpha suite: 3 passed, 0 failed"\nexit 0\n' > "$r/scripts/alpha-selftest.sh"
  printf '#!/usr/bin/env bash\necho "beta suite: 2 passed, 0 failed"\nexit 0\n'  > "$r/scripts/beta-selftest.sh"
  lefthook_with "$r" scripts/alpha-selftest.sh scripts/beta-selftest.sh
  gi "$r" add -A; gi "$r" commit -qm green; gi "$r" tag suites-green
  # a suite goes RED (the shape of core-v0.8 shipping a red pull/plugin suite)
  printf '#!/usr/bin/env bash\necho "beta suite: 1 passed, 1 failed"\necho "  x pull: adopter would brick"\nexit 1\n' > "$r/scripts/beta-selftest.sh"
  gi "$r" add -A; gi "$r" commit -qm red;   gi "$r" tag suites-red
  # a suite HANGS (bounded by --suite-timeout; the gate must never wait forever on a release)
  printf '#!/usr/bin/env bash\nsleep 60\n' > "$r/scripts/beta-selftest.sh"
  gi "$r" add -A; gi "$r" commit -qm slow;  gi "$r" tag suites-slow
  # a suite is DECLARED but ABSENT from the tree
  gi "$r" rm -q scripts/beta-selftest.sh
  gi "$r" commit -qm gone; gi "$r" tag suites-absent
  # lefthook.yml itself is gone → nothing declares what proves this tree
  gi "$r" rm -q lefthook.yml; gi "$r" commit -qm nolh; gi "$r" tag suites-nolefthook
  printf '%s' "$r"
}
SU="$(build_suites_repo)"

echo "(h) suites-on-exact-tree — run from a detached worktree of the CANDIDATE REF, bounded, HARD"
run_gate --repo "$SU" --candidate suites-green --prev suites-green --only $SUITES
chk "(h1) an all-green tree ⇒ GREEN (rc=0)"                              "[ $G_RC -eq 0 ] && has '\[PASS\] suites-on-exact-tree'"
chk "(h1) non-vacuity: it names the suites it ACTUALLY ran (2, by name)" \
  "has 'all 2 declared suite' && has 'alpha-selftest.sh' && has 'beta-selftest.sh'"
run_gate --repo "$SU" --candidate suites-red --prev suites-green --only $SUITES
chk "(h2) a RED suite on the tag tree ⇒ RED (rc!=0) — the brick-an-adopter class" \
  "[ $G_RC -ne 0 ] && has '\[FAIL\] suites-on-exact-tree'"
chk "(h2) …names the failing suite AND shows its real output"            "has 'beta-selftest.sh: rc=1' && has 'adopter would brick'"
run_gate --repo "$SU" --candidate suites-slow --prev suites-green --only $SUITES --suite-timeout 2
chk "(h3) a HANGING suite is BOUNDED (--suite-timeout) ⇒ RED, never an infinite gate" \
  "[ $G_RC -ne 0 ] && has 'TIMED OUT'"
run_gate --repo "$SU" --candidate suites-absent --prev suites-green --only $SUITES
chk "(h4) a DECLARED-but-ABSENT suite ⇒ RED (the tree is unproven)"      "[ $G_RC -ne 0 ] && has 'ABSENT'"
run_gate --repo "$SU" --candidate suites-nolefthook --prev suites-green --only $SUITES
chk "(h5) NO lefthook.yml ⇒ FAIL-CLOSED (rc!=0) — never certify a tree nothing tested" \
  "[ $G_RC -ne 0 ] && has 'cannot determine which suites'"
run_gate --repo "$SU" --candidate suites-red --prev suites-green --only $SUITES --skip-suites
chk "(h6) --skip-suites ⇒ ADVISORY, rc=0 (it does not block) …"          "[ $G_RC -eq 0 ] && has '\[WARN\] suites-on-exact-tree'"
chk "(h6) … but the advisory is UNMISSABLE (banner + 'SUITES NOT RUN' + 'DO NOT TAG')" \
  "has 'SUITES NOT RUN' && has 'DO NOT TAG' && has '╔'"
# ANTI-RECURSION: the live lefthook.yml declares release-gate-selftest.sh (which runs THIS gate). If the
# suites check ran it, the gate would recurse forever. It must self-exclude — and say that it did.
SR="$(new_repo)"; mkdir -p "$SR/scripts"
printf '#!/usr/bin/env bash\necho ok\nexit 0\n' > "$SR/scripts/alpha-selftest.sh"
printf '#!/usr/bin/env bash\necho "RECURSED — the gate ran its own selftest"\nexit 1\n' > "$SR/scripts/release-gate-selftest.sh"
lefthook_with "$SR" scripts/alpha-selftest.sh scripts/release-gate-selftest.sh
gi "$SR" add -A; gi "$SR" commit -qm sr; gi "$SR" tag sr-1
run_gate --repo "$SR" --candidate sr-1 --prev sr-1 --only $SUITES
chk "(h7) the gate does NOT run its own selftest (infinite recursion) — and says it excluded it" \
  "[ $G_RC -eq 0 ] && has 'excluded scripts/release-gate-selftest.sh' && ! has 'RECURSED'"
echo

# FINDING (slice 2): discovery must NOT require the literal `bash ` prefix — a suite invoked by another
# runner (sh/node/python/./) must be discovered AND run, else a RED non-bash suite ships unseen.
lefthook_run() {   # $1=repo; rest = literal `run:` command lines to declare under pre-push, one per suite
  local r="$1"; shift
  { printf 'pre-commit:\n  commands:\n    s:\n      run: true\n\npre-push:\n  commands:\n'
    local i=0 c
    for c in "$@"; do i=$((i + 1)); printf '    suite%d:\n      run: %s\n' "$i" "$c"; done
  } > "$r/lefthook.yml"
}
echo "(h8) non-bash runner discovery — a RED suite invoked as \`sh …\` must be caught (not skipped)"
F3="$(new_repo)"; mkdir -p "$F3/scripts"
printf '#!/usr/bin/env bash\necho "alpha ok"\nexit 0\n'                        > "$F3/scripts/alpha-selftest.sh"
printf '#!/usr/bin/env sh\necho "critical RED: adopter would BRICK"\nexit 1\n' > "$F3/scripts/critical-selftest.sh"
lefthook_run "$F3" "bash scripts/alpha-selftest.sh" "sh scripts/critical-selftest.sh"
gi "$F3" add -A; gi "$F3" commit -qm f3; gi "$F3" tag f3-1
run_gate --repo "$F3" --candidate f3-1 --prev f3-1 --only $SUITES
chk "(h8) a RED \`sh …\` suite is DISCOVERED + run ⇒ RED, both suites ran (2/2)" \
  "[ $G_RC -ne 0 ] && has 'critical-selftest.sh: rc=1' && has 'adopter would BRICK' && has '2/2 ran'"
echo "(h9) a GREEN non-bash-only suite is actually RUN — not skipped into a vacuous green"
F3G="$(new_repo)"; mkdir -p "$F3G/scripts"
printf '#!/usr/bin/env sh\necho "sh-runner suite green"\nexit 0\n' > "$F3G/scripts/only-selftest.sh"
lefthook_run "$F3G" "sh scripts/only-selftest.sh"
gi "$F3G" add -A; gi "$F3G" commit -qm f3g; gi "$F3G" tag f3g-1
run_gate --repo "$F3G" --candidate f3g-1 --prev f3g-1 --only $SUITES
chk "(h9) a GREEN \`sh …\` suite ⇒ GREEN naming it (1 declared, NOT zero-discovered)" \
  "[ $G_RC -eq 0 ] && has '\[PASS\] suites-on-exact-tree' && has 'all 1 declared suite'"
echo

# FINDING (slice 2): a TIMED-OUT suite must not leak a fixture supervisor it setsid'd into its OWN session
# onto this shared box (no pattern-kill, no PID-namespaces here). The gate enumerates the subtree BEFORE
# signalling and reaps by EXACT PID; the fixture records its child's pid so we can PROVE the reap (and the
# EXIT trap backstops it by that exact pid if a fix ever regresses — never a pattern).
echo "(h10) a hanging suite's setsid'd child is REAPED by the gate on timeout (no orphan on the box)"
F4="$(new_repo)"; mkdir -p "$F4/scripts"
F4_PIDFILE="$(mk)/child.pid"                       # outside the gate's worktree, so it survives gate cleanup
printf '%s\n' "$F4_PIDFILE" >> "$CHILD_PID_FILES"  # backstop-reap this exact pid on EXIT
cat > "$F4/scripts/hang-selftest.sh" <<EOF
#!/usr/bin/env bash
setsid bash -c 'echo \$\$ > "$F4_PIDFILE"; exec sleep 300' < /dev/null &
sleep 300
EOF
lefthook_run "$F4" "bash scripts/hang-selftest.sh"
gi "$F4" add -A; gi "$F4" commit -qm f4; gi "$F4" tag f4-1
run_gate --repo "$F4" --candidate f4-1 --prev f4-1 --only $SUITES --suite-timeout 2
F4_CHILD="$(cat "$F4_PIDFILE" 2>/dev/null)"
chk "(h10) the hanging suite ⇒ RED (TIMED OUT), bounded — never an infinite gate" \
  "[ $G_RC -ne 0 ] && has 'TIMED OUT'"
chk "(h10) …and its setsid'd child ($F4_CHILD) is DEAD after the gate — contained by exact-PID reap" \
  "dead_within '$F4_CHILD' 6"
echo

# ── (i) manifest coherence — HARD one way, ADVISORY the other ────────────────────────────────────────
MEX=manifest-existence-guard
MCOV=manifest-covers-new-files
build_manifest_repo() {
  local r; r="$(new_repo)"
  mkdir -p "$r/scripts"
  printf '#!/usr/bin/env bash\n:\n' > "$r/scripts/supervisor.sh"
  printf '#!/usr/bin/env bash\n:\n' > "$r/scripts/preflight.sh"
  printf '# the core manifest\nscripts/supervisor.sh\nscripts/preflight.sh\n' > "$r/scripts/core-manifest.txt"
  gi "$r" add -A; gi "$r" commit -qm ok; gi "$r" tag man-ok
  # a manifest-listed core file vanishes from the tree → cmd_pull DIEs at its step-4 existence guard
  gi "$r" rm -q scripts/preflight.sh; gi "$r" commit -qm missing; gi "$r" tag man-missing
  # a NEW core-dir file that nobody listed → it still travels (whole-tree pin) ⇒ ADVISORY, not a brick
  gi "$r" checkout -q man-ok -- scripts/preflight.sh
  printf '#!/usr/bin/env bash\n:\n' > "$r/scripts/new-engine-bit.sh"
  gi "$r" add -A; gi "$r" commit -qm uncovered; gi "$r" tag man-uncovered
  # an EMPTY manifest → cmd_pull dies ("manifest lists no core files")
  printf '# nothing\n' > "$r/scripts/core-manifest.txt"
  gi "$r" add -A; gi "$r" commit -qm empty; gi "$r" tag man-empty
  printf '%s' "$r"
}
MN="$(build_manifest_repo)"

echo "(i) manifest coherence — HARD when a listed file is missing, ADVISORY when a new file is unlisted"
run_gate --repo "$MN" --candidate man-missing --prev man-ok --only $MEX
chk "(i1) manifest lists a file the tree LACKS ⇒ RED (every adopter's pull dies at step 4)" \
  "[ $G_RC -ne 0 ] && has '\[FAIL\] manifest-existence-guard' && has 'partial core'"
chk "(i1) …and it names the missing path"                                "has 'scripts/preflight.sh'"
run_gate --repo "$MN" --candidate man-ok --prev man-ok --only $MEX
chk "(i2) the coherent tree ⇒ GREEN, naming how many entries it checked" "[ $G_RC -eq 0 ] && has 'all 2 manifest entries exist'"
run_gate --repo "$MN" --candidate man-empty --prev man-ok --only $MEX
chk "(i3) an EMPTY manifest ⇒ RED (cmd_pull dies: 'lists no core files')" "[ $G_RC -ne 0 ] && has 'NO core files'"
run_gate --repo "$MN" --candidate man-uncovered --prev man-ok --only $MCOV
chk "(i4) a NEW unlisted file in a core dir ⇒ ADVISORY [WARN], rc=0 (it still travels)" \
  "[ $G_RC -eq 0 ] && has '\[WARN\] manifest-covers-new-files' && has 'new-engine-bit.sh'"
run_gate --repo "$REPO" --candidate core-v0.8.1 --prev core-v0.8 --only $MEX
chk "(i5) REAL core-v0.8.1 ⇒ GREEN, non-vacuously (all 61 real manifest entries checked)" \
  "[ $G_RC -eq 0 ] && has 'all 61 manifest entries exist'"
echo

# ── (j) changelog-covers-delta (ADVISORY) — and THE DATE TRAP ────────────────────────────────────────
CL=changelog-top-section
build_changelog_repo() {
  local r; r="$(new_repo)"
  printf '## core-v0.1 — unreleased\n\n- **Base.** the first cut.\n' > "$r/CORE-CHANGELOG.md"
  gi "$r" add -A; gi "$r" commit -qm base; gi "$r" tag cl-prev
  printf '## core-v0.2 — unreleased\n\n## core-v0.1 — 2026-01-01\n\n- **Base.** the first cut.\n' > "$r/CORE-CHANGELOG.md"
  gi "$r" add -A; gi "$r" commit -qm empty; gi "$r" tag cl-empty          # heading with NO content
  printf '## core-v0.2 — unreleased\n\n- **Thing.** it changed.\n\n## core-v0.1 — 2026-01-01\n\n- **Base.**\n' > "$r/CORE-CHANGELOG.md"
  gi "$r" add -A; gi "$r" commit -qm full; gi "$r" tag cl-full
  printf '%s' "$r"
}
CLR="$(build_changelog_repo)"

echo "(j) changelog-top-section — ADVISORY (cmd_pull's own changelog step never fails a pull)"
run_gate --repo "$CLR" --candidate cl-empty --prev cl-prev --only $CL
chk "(j1) an EMPTY top section ⇒ [WARN], rc=0 (advisory: adopters pull blind, but nothing bricks)" \
  "[ $G_RC -eq 0 ] && has '\[WARN\] changelog-top-section' && has 'EMPTY'"
run_gate --repo "$CLR" --candidate cl-full --prev cl-prev --only $CL --version core-v0.9
chk "(j2) cutting core-v0.9 while the top heading says core-v0.2 ⇒ [WARN] naming both" \
  "[ $G_RC -eq 0 ] && has 'core-v0.9' && has 'core-v0.2'"
run_gate --repo "$CLR" --candidate cl-full --prev cl-prev --only $CL --version core-v0.2
chk "(j3) a real, non-empty, matching section ⇒ GREEN"                   "[ $G_RC -eq 0 ] && has '\[PASS\] changelog-top-section'"
# THE DATE TRAP: every real release tag ships its own heading as "— unreleased" (the date is backfilled
# AFTER tagging). A "the section has a real date" check would have false-RED 100% of historical releases.
run_gate --repo "$REPO" --candidate core-v0.8.1 --prev core-v0.8 --only $CL --version core-v0.8.1
chk "(j4) REAL core-v0.8.1 ⇒ GREEN even though its heading literally says '— unreleased' (date NOT checked)" \
  "[ $G_RC -eq 0 ] && has 'core-v0.8.1 — unreleased' && has 'date NOT checked'"
echo

# ── (k) installer-url-parity (ADVISORY) — a REAL shipped defect, on the real tags ────────────────────
IP=installer-url-parity
echo "(k) installer-url-parity — the front door. REAL RED on v0.8.1, REAL GREEN on v0.8"
run_gate --repo "$REPO" --candidate core-v0.8.1 --prev core-v0.8 --only $IP
K1_OUT="$G_OUT"; K1_RC=$G_RC
chk "(k1) REAL core-v0.8.1 ⇒ [WARN]: install.sh's own header still names core-v0.8 (a shipped defect)" \
  "[ $K1_RC -eq 0 ] && has '\[WARN\] installer-url-parity' && has 'install.sh:4' && has 'names core-v0.8, expected core-v0.8.1'"
chk "(k1) …and it stays ADVISORY (rc=0): a stale doc URL breaks a NEW install, it does not brick an adopter" \
  "[ $K1_RC -eq 0 ]"
run_gate --repo "$REPO" --candidate core-v0.8 --prev core-v0.7 --only $IP
chk "(k2) REAL core-v0.8 ⇒ GREEN: all 5 canonical URLs agree (proves it is not 'always warn')" \
  "[ $G_RC -eq 0 ] && has '\[PASS\] installer-url-parity' && has 'name core-v0.8'"
chk "(k3) it EMITS the install.sh SHA-256 as a release artifact (64 hex)" \
  "printf '%s' \"\$K1_OUT\" | grep -qE '[0-9a-f]{64}  install.sh'"
chk "(k3) …and states plainly what ONLY a POST-TAG curl can prove"       "printf '%s' \"\$K1_OUT\" | grep -q 'POST-TAG ONLY'"
echo

# ── (l) the LOCKED severity model + the summary's arithmetic ─────────────────────────────────────────
echo "(l) severity model — HARD blocks, ADVISORY never does; the summary is conjunctive AND honest"
S_LINE="$(printf '%s\n' "$B_OUT" | grep '^SUMMARY:')"
s_pass="$(printf '%s' "$S_LINE" | sed -n 's/^SUMMARY: \([0-9]*\)\/[0-9]*.*/\1/p')"
s_tot="$(printf  '%s' "$S_LINE" | sed -n 's/^SUMMARY: [0-9]*\/\([0-9]*\).*/\1/p')"
s_fail="$(printf '%s' "$S_LINE" | sed -n 's/.*passed, \([0-9]*\) FAILED.*/\1/p')"
s_warn="$(printf '%s' "$S_LINE" | sed -n 's/.*(hard), \([0-9]*\) advisor.*/\1/p')"
chk "(l1) the summary's arithmetic adds up (passed + FAILED + advisories == total)" \
  "[ $((${s_pass:-0} + ${s_fail:-0} + ${s_warn:-0})) -eq ${s_tot:-0} ] && [ ${s_tot:-0} -gt 0 ]"
chk "(l2) an advisory-only run is GREEN (advisories are counted, never blocking)" \
  "[ ${s_fail:-9} -eq 0 ] && [ ${s_warn:-0} -gt 0 ] && [ $B_RC -eq 0 ]"
chk "(l3) a HARD fail flips the exit code even when advisories are present" \
  "printf '%s' \"\$A_OUT\" | grep -q 'FAILED (hard — blocks)' && [ $A_RC -ne 0 ]"
run_gate --repo "$REPO" --prev core-v0.8 --only no-such-check
chk "(l4) --only with an unknown check FAILS LOUD (rc=2) + lists the known checks" \
  "[ $G_RC -eq 2 ] && has 'unknown check' && has 'leak-scan-on-tree'"
chk "(l5) --only prints a PARTIAL banner — a subset run can never read as a release pass" \
  "printf '%s' \"\$K1_OUT\" | grep -q 'PARTIAL RUN' && printf '%s' \"\$K1_OUT\" | grep -q 'PARTIAL release gate'"
echo

# ── hygiene: the gate must leave NO NEW worktree behind (it writes one into .git/worktrees on every run) ──
# Scoped to THIS run against the pre-run baseline — a concurrent agent's worktree that was already there is
# NOT our leak, so the release-critical selftest no longer flakes RED on global live-repo state.
echo "(m) hygiene — the gate's scratch worktree is always reaped (it runs on the LIVE engine repo)"
WT_NOW="$(git -C "$REPO" worktree list 2>/dev/null | grep '/wt ' | sort || true)"
WT_LEAKED="$(comm -13 <(printf '%s\n' "$WT_BASELINE") <(printf '%s\n' "$WT_NOW") | grep -c '/wt ' || true)"
chk "(m1) THIS run leaked NO new gate worktree into the live repo (scoped to our runs, not global state)" \
  "[ '${WT_LEAKED:-0}' -eq 0 ]"
echo

echo "──────────────────────────────"
printf 'NEW: pass=%s fail=%s\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "SELFTEST PASS"; exit 0; fi
echo "SELFTEST FAIL"; exit 1
