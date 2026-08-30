#!/usr/bin/env bash
# ship-turnkey-selftest.sh — prove the RELEASE turnkey refuses to ship a tree the gate never saw.
#
#   bash scripts/ship-turnkey-selftest.sh
#
# WHY THIS SUITE EXISTS. The ship turnkey performs the one irreversible act in a release: it
# fast-forwards the public main and pushes a tag. Its three ordinary preconditions — the branch
# still fast-forwards the remote's main, the tag does not exist yet, the plugin-version invariant
# holds — ALL PASS ON A STALE BRANCH. That is not hypothetical: a staged release sat for a full day
# carrying the very blocker it was being held for, all three checks green, while the turnkey's own
# header advertised a gate verdict measured on a DIFFERENT commit. Nothing in the file was lying;
# nothing in the file was checking either.
#
# So the generator bakes three things into every cut, and this suite is what makes them able to
# FAIL. RED-FIRST throughout — each guard gets a lane that goes RED on the defective input and a
# negative control proving it goes GREEN on the good one:
#
#   §1/§2  the GENERATOR refuses a --gated-at that is not the branch tip, and every hostile value —
#          each lane asserting the REASON it was refused, never merely that something went wrong.
#   §3     the STRUCTURAL guard (_assert_ship_guards) refuses a RENDER whose freshness refusal, pin,
#          header SHA, or `--no-verify` justification was removed, NESTED, or commented out —
#          driven against deliberately MUTATED copies of the real render, each asserted non-vacuous
#          before it is judged.
#   §4     the EMITTED SCRIPT goes RED when the branch moves after generation — on a real throwaway
#          git repo, with the three ordinary preconditions PASSING first, which is the whole point;
#          and it goes RED again under a HOSTILE ENVIRONMENT, which `env -i` alone cannot see.
#   §5     the remaining refusals, and one real `--push` against a bare fixture origin.
#   §6     the flag and its justification travel together in the shipped artifact.
#   §7     the guard's CALL SITE, driven end to end through the real `gen-ship-turnkey` command.
#
# TWO THINGS THIS SUITE ONCE COULD NOT SEE, and now can — both found by mutating the thing itself:
#   • an ESCAPE HATCH KEYED ON THE ENVIRONMENT. run_ship uses `env -i` on purpose (no ambient
#     variable may pick a lane) — and that is exactly why wrapping the freshness refusal in
#     `if [ "${SHIP_SKIP_FRESHNESS:-0}" = 0 ]; then … fi` was invisible: every literal byte stayed
#     identical, the generator exited 0, this file stayed 76 passed / 0 failed, and the emitted
#     turnkey pushed an ungated commit AND tag. §4's hostile-env lane is the answer, with the
#     variable battery DERIVED from the rendered artifact so it cannot rot.
#   • a DISCONNECTED GUARD. §3 drives _assert_ship_guards through a python importer, so commenting
#     out its one call in cmd_gen_ship_turnkey also left this file at 76/0. §7 is the answer: mutate
#     a COPIED template, run the COPIED generator end to end, require rc != 0 AND no file written.
#
# HERMETIC + LIVE-SAFE, in three layers, because this suite drives `git` and one mistake here writes
# to the repository it is testing (it did, once, during development — an empty fixture variable made
# `git -C "$R"` fall through to the CWD and commit to the live checkout):
#   1. the suite `cd`s OUT of the repo before doing anything, so a stray relative git call has no
#      repository to land in;
#   2. every git call goes through g(), which REFUSES any directory that is not under this run's own
#      mktemp dir — an empty or wrong path is a loud exit, never a silent write somewhere real;
#   3. the ONE lane that runs `--push` pushes to a bare repo inside that same mktemp dir, and will
#      not run at all unless the fixture's own origin URL is proven to live under it.
# Every fixture is built with `git init` — never a copy of this checkout, which would drag in
# gitignored state and mask the default under test. Deps: bash + coreutils + git + python3.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
AM="$REPO/scripts/adopt-manifest.py"
TMPL="$REPO/scripts/templates/ship-turnkey.sh.tmpl"

PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

F="$(mktemp -d)"; trap 'rm -rf "$F"' EXIT
# $F is load-bearing for BOTH safety layers below (g()'s `"$F"/*` case and the push lane's origin
# check). An EMPTY $F turns `"$F"/*` into `/*`, which matches every absolute path on the box — the
# guard would still "pass" while guarding nothing. Assert it here, once, before anything uses it.
[ -n "$F" ] && [ -d "$F" ] || { echo "  ❌ FATAL: mktemp -d gave no usable scratch dir"; exit 9; }
case "$F" in /?*) ;; *) echo "  ❌ FATAL: scratch dir is not an absolute path: '$F'"; exit 9 ;; esac
mkdir -p "$F/home"

echo "▶ ship-turnkey self-test (a release turnkey is only as good as its refusal to ship a stale tree)"
echo

command -v git     >/dev/null 2>&1 || { echo "  ❌ git not found";     exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "  ❌ python3 not found"; exit 1; }
[ -f "$AM" ]   || { echo "  ❌ generator not found: $AM";  exit 1; }
[ -f "$TMPL" ] || { echo "  ❌ template not found: $TMPL"; exit 1; }

# LAYER 1: leave the repository. Nothing below has a reason to be inside it, and a git call that
# loses its -C argument must land on barren ground rather than on the tree under test.
cd "$F" || { echo "  ❌ cannot cd to the scratch dir"; exit 1; }

# LAYER 2: every git call in this file goes through g(). A path that is not under $F is a FATAL
# exit, not a warning — this is the guard that turns "the fixture variable was empty" from a silent
# commit in the live checkout into a stopped suite.
g() {
  local d="${1:-}"
  case "$d" in
    "$F"/*) ;;
    *) printf '  ❌ FATAL: refusing `git -C %q` — outside this run'"'"'s scratch dir (%s)\n' "$d" "$F" >&2
       exit 9 ;;
  esac
  shift
  git -C "$d" "$@"
}

BR="release/core-v9.9.1"
TAG="core-v9.9.1"
PREV="core-v9.9.0"
VERDICT="7/7 checks, 0 hard failures, 0 advisories, 38/38 declared suites GREEN"

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────
# A throwaway release topology: a bare origin, a main branch pushed to it, a PREV tag, and a release
# branch of exactly ONE commit whose parent IS origin/main — i.e. a tree on which all three ordinary
# preconditions are green. `symbolic-ref` rather than `init -b` so this runs on older git. Local
# user identity so the --push lane can write an annotated tag under `env -i`.
build_fix() {   # <name> [with_plugin] → echoes the working repo dir (or nothing, on failure)
  local n wp d R O
  n="$1"; wp="${2:-0}"; d="$F/$n"; R="$d/repo"; O="$d/origin.git"
  mkdir -p "$d" || return 1
  git init -q --bare "$O" >/dev/null 2>&1 || return 1
  git init -q "$R" >/dev/null 2>&1 || return 1
  g "$R" symbolic-ref HEAD refs/heads/main
  g "$R" config user.email selftest@example.invalid
  g "$R" config user.name  selftest
  g "$R" config commit.gpgsign false
  g "$R" config tag.gpgsign false
  printf 'installer v1\n' > "$R/install.sh"
  printf 'base\n'         > "$R/README.md"
  if [ "$wp" = 1 ]; then
    mkdir -p "$R/plugin/.claude-plugin" "$R/plugin/skills"
    printf '{ "name": "fixture", "version": "0.1.0" }\n' > "$R/plugin/.claude-plugin/plugin.json"
    printf 'skill one\n' > "$R/plugin/skills/one.md"
  fi
  g "$R" add -A && g "$R" commit -qm base || return 1
  g "$R" tag "$PREV"
  g "$R" remote add origin "$O"
  g "$R" push -q origin main --tags || return 1
  g "$R" checkout -q -b "$BR"
  printf 'installer v2\n' > "$R/install.sh"
  g "$R" add -A && g "$R" commit -qm 'release cut' || return 1
  printf '%s' "$R"
}
# A fixture that failed to build must not silently become "" and let a later `git -C ""` roam.
need_fix() {   # <name> [with_plugin] → echoes the repo dir, or aborts the whole suite
  local r
  r="$(build_fix "$@")" || true
  if [ -z "$r" ] || [ ! -d "$r/.git" ]; then
    printf '  ❌ FATAL: fixture %q did not build — aborting rather than running lanes against nothing\n' "$1" >&2
    exit 9
  fi
  printf '%s' "$r"
}
tip_of() { g "$1" rev-parse "$BR"; }
gen() {   # <repo> <out> <gated_at> [extra args…] → GEN_RC / GEN_OUT
  local r="$1" o="$2" gt="$3"; shift 3
  GEN_RC=0
  GEN_OUT="$(python3 "$AM" gen-ship-turnkey --repo "$r" --branch "$BR" --version "$TAG" \
               --prev-version "$PREV" --gated-at "$gt" --verdict "$VERDICT" --out "$o" "$@" 2>&1)" \
             || GEN_RC=$?
}
run_ship() {   # <script> <repo> [args…] → SH_RC / SH_OUT  (env -i: no ambient SHIP_*/GIT_* picks a lane)
  local s="$1" r="$2"; shift 2
  # A MISSING artifact must not bank a green. `bash /no/such/file` exits 127, which would satisfy
  # every "it exits NON-ZERO" lane below without the script ever having refused anything — the
  # mutation audit found exactly that cascade when a broken template stopped the generator emitting.
  # Report rc 0 with an error banner instead: the negative lanes then red, and so do the positive ones.
  if [ ! -s "$s" ]; then SH_RC=0; SH_OUT="SELFTEST-ERROR: nothing was emitted at $s"; return 0; fi
  SH_RC=0
  SH_OUT="$(env -i PATH="$PATH" HOME="$F/home" SHIP_REPO="$r" bash "$s" "$@" 2>&1)" || SH_RC=$?
}

# ══ §1  THE GENERATOR — it verifies --gated-at instead of trusting it ════════════════════════════
echo "1. generator: --gated-at is VERIFIED against the branch tip, not taken on trust"
R1="$(need_fix g1)"
TIP1="$(tip_of "$R1")"
MAIN1="$(g "$R1" rev-parse main)"
chk "fixture is non-vacuous: the release branch is ONE commit whose parent IS origin/main" \
  "[ \"\$(g '$R1' rev-parse '$BR^')\" = \"\$(g '$R1' rev-parse origin/main)\" ] && [ -n '$TIP1' ]"

gen "$R1" "$F/g1.sh" "$TIP1"
chk "★ NEGATIVE CONTROL: --gated-at == the branch tip → emits (rc 0)" "[ $GEN_RC -eq 0 ]"
chk "…wrote the turnkey 0755" "[ -f '$F/g1.sh' ] && [ \"\$(stat -c '%a' '$F/g1.sh')\" = 755 ]"
chk "…and it is \`bash -n\` clean (a syntax error found mid-release strands the branch)" \
  "bash -n '$F/g1.sh'"
chk "…the pin it baked IS the tip it verified" "grep -qx 'GATED_AT=\"$TIP1\"' '$F/g1.sh'"
chk "…the header states the verdict AND the SHA it was measured on, side by side" \
  "grep -qE '^#  *verdict: *7/7 checks' '$F/g1.sh' && grep -qE '^#  *gated at: *$TIP1\$' '$F/g1.sh'"
# ── the GitHub Release step (systematic per operator directive 2026-08-24) ───────────────────────
chk "…the ship PUBLISHES a GitHub Release as part of --push (never a remembered after-step)" \
  "grep -q 'gh release create' '$F/g1.sh'"
chk "…the notes are DERIVED from the tagged tree's own CORE-CHANGELOG section + derivable upgrade lines, not hand-typed" \
  "grep -q 'CORE-CHANGELOG.md' '$F/g1.sh' && grep -q '## Upgrade' '$F/g1.sh' && grep -q 'install.sh sha256' '$F/g1.sh'"
chk "…and it DEGRADES without gh (writes notes + prints the manual command — never dies post-tag)" \
  "grep -q 'gh not available/authed' '$F/g1.sh'"

gen "$R1" "$F/g2.sh" "$MAIN1"
chk "★ RED: --gated-at resolves but is NOT the branch tip → REFUSES (the copied claim at birth)" \
  "[ $GEN_RC -ne 0 ] && [ ! -e '$F/g2.sh' ]"
chk "…and says so in the operator's language (names the tip it is not)" \
  "printf '%s' \"\$GEN_OUT\" | grep -q 'NOT the current tip'"

gen "$R1" "$F/g3.sh" "0123456789abcdef0123456789abcdef01234567"
chk "★ RED: a 40-hex --gated-at that does not RESOLVE in the repo → REFUSES" \
  "[ $GEN_RC -ne 0 ] && [ ! -e '$F/g3.sh' ] && printf '%s' \"\$GEN_OUT\" | grep -q 'does not RESOLVE'"
gen "$R1" "$F/g4.sh" "${TIP1:0:7}"
chk "★ RED: an ABBREVIATED --gated-at → REFUSES (a short pin could never string-match rev-parse)" \
  "[ $GEN_RC -ne 0 ] && [ ! -e '$F/g4.sh' ]"
echo

# ══ §2  hostile values: the generator EMITS BASH the operator runs as himself ════════════════════
echo "2. generator: every interpolated value is REJECTED, never sanitized"
CANARY="$F/pwned"
# Every lane names the REASON it expects, and the lane fails if the generator refused for a
# DIFFERENT reason. Without that, a lane banks a green off the wrong check and is vacuous: deleting
# the `prev == tag` guard outright left this suite at 76 passed / 0 failed, because the fixture's
# --prev-version then failed the LATER "is not a tag in this repo" check instead. "It exited
# non-zero" is not an assertion about the thing under test.
refuse() {   # <label> <reason-substring> <args…> — non-zero, no file written, AND the right reason
  local label="$1" reason="$2"; shift 2
  local o="$F/hostile.sh" rc=0 out
  rm -f "$o"
  out="$(python3 "$AM" gen-ship-turnkey --out "$o" "$@" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then bad "$label  [did not refuse at all]"; return; fi
  if [ -e "$o" ]; then bad "$label  [refused but still wrote $o]"; return; fi
  if ! printf '%s' "$out" | grep -qF -- "$reason"; then
    bad "$label  [refused for the WRONG reason — wanted: $reason]"; return
  fi
  ok "$label"
}
BASE=(--repo "$R1" --branch "$BR" --version "$TAG" --prev-version "$PREV" --gated-at "$TIP1")
VERDICT_WHY="not a constrained one-line verdict"
refuse "REFUSES a command-substitution --verdict (it lands in a bash string)" "$VERDICT_WHY" \
  "${BASE[@]}" --verdict "\$(touch $CANARY)"
refuse "REFUSES a backtick --verdict" "$VERDICT_WHY" \
  "${BASE[@]}" --verdict 'all green `touch '"$CANARY"'`'
refuse "REFUSES a MULTI-LINE --verdict (a newline breaks it out of the header comment into code)" \
  "$VERDICT_WHY" "${BASE[@]}" --verdict "$(printf 'green\nrm -rf /')"
refuse "REFUSES a TRAILING-newline --verdict (python's \`\$\` matches before it — \\Z does not)" \
  "$VERDICT_WHY" "${BASE[@]}" --verdict "all green"$'\n'
refuse "REFUSES a quote-breakout --verdict" "$VERDICT_WHY" \
  "${BASE[@]}" --verdict 'x" ; $(id) ; "'
refuse "REFUSES an empty --verdict (a turnkey that states no verdict states nothing)" \
  "$VERDICT_WHY" "${BASE[@]}" --verdict ''
refuse "REFUSES a shell-metachar --branch" "not a safe ref name" \
  --repo "$R1" --branch 'release/x;rm -rf /' --version "$TAG" --prev-version "$PREV" \
  --gated-at "$TIP1" --verdict "$VERDICT"
refuse "REFUSES a '..' --branch (bad git ref-format, and a traversal shape)" "not a safe ref name" \
  --repo "$R1" --branch 'release/../../x' --version "$TAG" --prev-version "$PREV" \
  --gated-at "$TIP1" --verdict "$VERDICT"
refuse "REFUSES an arbitrary git ref as --version (main)" "not a core release tag" \
  --repo "$R1" --branch "$BR" --version main --prev-version "$PREV" \
  --gated-at "$TIP1" --verdict "$VERDICT"
refuse "REFUSES --prev-version == --version (the plugin invariant would hold vacuously)" \
  "equals --version" \
  --repo "$R1" --branch "$BR" --version "$TAG" --prev-version "$TAG" \
  --gated-at "$TIP1" --verdict "$VERDICT"
refuse "REFUSES a --prev-version tag that does not exist (the diff would adjudicate on nothing)" \
  "is not a tag in" \
  --repo "$R1" --branch "$BR" --version "$TAG" --prev-version core-v9.0.0 \
  --gated-at "$TIP1" --verdict "$VERDICT"
refuse "REFUSES a --branch that does not resolve (nothing is staged)" "does not resolve in" \
  --repo "$R1" --branch release/core-v9.9.7 --version "$TAG" --prev-version "$PREV" \
  --gated-at "$TIP1" --verdict "$VERDICT"
refuse "REFUSES a --repo that is not a git repository" "not a git repository" \
  --repo "$F/home" --branch "$BR" --version "$TAG" --prev-version "$PREV" \
  --gated-at "$TIP1" --verdict "$VERDICT"

# ── the TRAILING-NEWLINE class. Python's `$` also matches immediately before a final newline, so
#    `^core-v[0-9]+…$` ACCEPTED "core-v9.9.1\n" and the rendered header line
#    `# ship-@@VER@@.sh — publish @@TAG@@` split in two, putting `.sh — publish …` in EXECUTABLE
#    position (observed on a real render: `line 4: .sh: command not found`). \Z, not $.
refuse "REFUSES a TRAILING-newline --version (\`\$\` matched before it; the header split in two)" \
  "not a core release tag" \
  --repo "$R1" --branch "$BR" --version "$TAG"$'\n' --prev-version "$PREV" \
  --gated-at "$TIP1" --verdict "$VERDICT"
refuse "REFUSES a TRAILING-newline --prev-version" "not a core release tag" \
  --repo "$R1" --branch "$BR" --version "$TAG" --prev-version "$PREV"$'\n' \
  --gated-at "$TIP1" --verdict "$VERDICT"
refuse "REFUSES a TRAILING-newline --gated-at" "not a full 40-hex commit SHA" \
  --repo "$R1" --branch "$BR" --version "$TAG" --prev-version "$PREV" \
  --gated-at "$TIP1"$'\n' --verdict "$VERDICT"
refuse "REFUSES a TRAILING-newline --branch" "not a safe ref name" \
  --repo "$R1" --branch "$BR"$'\n' --version "$TAG" --prev-version "$PREV" \
  --gated-at "$TIP1" --verdict "$VERDICT"
chk "★ NO hostile input ever executed (the \$(touch) canary never fired)" "[ ! -e '$CANARY' ]"

# ── --out is a value too. It was the ONE interpolated value with neither a regex nor shlex.quote,
#    and it lands in header lines 10-11 — ABOVE `set -uo pipefail`. A newline in it emitted a bare
#    `touch SYNTH-RCE` at line 11, and running the result with NO --push (a PREVIEW, the run made
#    precisely because it is believed to be safe) executed it. rc was 0 and the guard passed. ─────
refuse_out() {   # <label> <reason-substring> <out-value>
  local label="$1" reason="$2" o="$3" rc=0 out
  out="$(python3 "$AM" gen-ship-turnkey "${BASE[@]}" --verdict "$VERDICT" --out "$o" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then bad "$label  [did not refuse at all]"; return; fi
  if ! printf '%s' "$out" | grep -qF -- "$reason"; then
    bad "$label  [refused for the WRONG reason — wanted: $reason]"; return
  fi
  ok "$label"
}
RCE_DIR="$F/rce"; mkdir -p "$RCE_DIR"
RCE_CANARY="$F/SYNTH-RCE"
rm -f "$RCE_CANARY"
refuse_out "★ RED: a NEWLINE in --out → REFUSES (it is interpolated ABOVE \`set -uo pipefail\`)" \
  "not a safe script path" "$(printf '%s/pwn\ntouch %s\n#.sh' "$RCE_DIR" "$RCE_CANARY")"
chk "★ …and nothing at all was written into the --out directory" \
  "[ -z \"\$(ls -A '$RCE_DIR')\" ]"
# Belt AND braces: if a future edit ever lets one through, RUN whatever landed and prove the header
# canary stays cold. Pre-fix this loop found a file, ran a pure preview, and the canary FIRED.
for _leak in "$RCE_DIR"/*; do
  [ -e "$_leak" ] || continue
  env -i PATH="$PATH" HOME="$F/home" SHIP_REPO="$R1" bash "$_leak" >/dev/null 2>&1
done
chk "★★ the --out header canary NEVER fired (a PREVIEW run cannot execute an injected line)" \
  "[ ! -e '$RCE_CANARY' ]"
refuse_out "REFUSES an --out that does not end '.sh' (a turnkey is a script)" \
  "not a safe script path" "$F/notascript"
refuse_out "REFUSES an --out carrying a shell metacharacter" \
  "not a safe script path" "$F/ship\$(id).sh"
refuse_out "★ REFUSES an --out INSIDE the release repo (a turnkey is an operator artifact, not a seam)" \
  "INSIDE the repo" "$R1/ship-inside.sh"
chk "★ …and no untracked 0755 script was dropped in the repo" "[ ! -e '$R1/ship-inside.sh' ]"

gen "$R1" "$F/g1.sh" "$TIP1"
chk "REFUSES to clobber an existing --out without --force" "[ $GEN_RC -ne 0 ]"
gen "$R1" "$F/g1.sh" "$TIP1" --force
chk "--force DOES overwrite (the explicit escape hatch)" "[ $GEN_RC -eq 0 ]"
echo

# ══ §3  THE STRUCTURAL GUARD — a render that lost a guarantee cannot be written ══════════════════
# Driven against MUTATED copies of the REAL render: strip the thing, watch _assert_ship_guards
# refuse. Every mutation asserts it actually changed the text first — a mutation that matched
# nothing would make its lane vacuously green, which is the failure mode this whole file is about.
echo "3. _assert_ship_guards: the render cannot lose the freshness refusal, the header SHA, or the justification"
DRIVE="$F/guard_drive.py"
cat > "$DRIVE" <<'PYEOF'
import importlib.util as u, re, sys

am, render, case = sys.argv[1], sys.argv[2], sys.argv[3]
spec = u.spec_from_file_location("am", am); m = u.module_from_spec(spec); spec.loader.exec_module(m)
text = open(render, encoding="utf-8").read()

REFUSAL = m._SHIP_REFUSAL_LINE
GATE = m._SHIP_PREVIEW_GATE
ANCHOR = m._SHIP_JUSTIFY_ANCHOR
CASES = {}
def case_fn(name):
    def deco(f):
        CASES[name] = f
        return f
    return deco

@case_fn("strip-refusal")            # the pin stays; the branch that acts on it goes
def _(t):
    ls = t.splitlines(True)
    i = next(k for k, l in enumerate(ls) if l.rstrip("\n") == REFUSAL)
    j = i
    while ls[j].rstrip("\n") != "fi":
        j += 1
    return "".join(ls[:i] + ls[j + 1:])

@case_fn("strip-pin")                # the refusal stays; the SHA it refuses on goes
def _(t):
    return re.sub(r'^GATED_AT="[0-9a-f]{40}"\n', "", t, flags=re.M)

@case_fn("refusal-does-not-exit")    # it prints, then falls through to the push
def _(t):
    ls = t.splitlines(True)
    i = next(k for k, l in enumerate(ls) if l.rstrip("\n") == REFUSAL)
    j = next(k for k in range(i, i + 12) if "exit 1" in ls[k])
    return "".join(ls[:j] + ls[j + 1:])

@case_fn("exit-only-in-a-comment")   # the same fall-through, with the words `exit 1` left behind
def _(t):                            # in a COMMENT — which the old substring scan accepted
    ls = t.splitlines(True)
    i = next(k for k, l in enumerate(ls) if l.rstrip("\n") == REFUSAL)
    j = next(k for k in range(i, i + 12) if "exit 1" in ls[k])
    out = "".join(ls[:j] + ["  # this branch used to exit 1 here\n"] + ls[j + 1:])
    assert "exit 1" in out, "the mutation must LEAVE the words behind — that is the point"
    return out

@case_fn("refusal-indented")         # one space. `lines.index` raised an uncaught ValueError here —
def _(t):                            # a python traceback in place of the written refusal
    return t.replace(REFUSAL, " " + REFUSAL, 1)

@case_fn("refusal-nested-in-a-condition")   # BLOCKER 1: every literal byte identical; only nesting
def _(t):                                   # changed. Generator exited 0; the turnkey then pushed
    ls = t.splitlines(True)                 # an ungated commit AND tag.
    i = next(k for k, l in enumerate(ls) if l.rstrip("\n") == REFUSAL)
    j = i
    while ls[j].rstrip("\n") != "fi":
        j += 1
    out = "".join(ls[:i] + ['if [ "${SHIP_SKIP_FRESHNESS:-0}" = 0 ]; then\n']
                  + ls[i:j + 1] + ["fi\n"] + ls[j + 1:])
    assert REFUSAL in out, "the refusal line itself must survive VERBATIM — that is the point"
    return out

@case_fn("preview-gate-nested-in-a-condition")   # a gate inside a condition is a gate with a bypass
def _(t):
    ls = t.splitlines(True)
    i = next(k for k, l in enumerate(ls) if l.rstrip("\n") == GATE)
    j = i
    while ls[j].rstrip("\n") != "fi":
        j += 1
    out = "".join(ls[:i] + ['if [ "${SHIP_FORCE:-0}" = 0 ]; then\n']
                  + ls[i:j + 1] + ["fi\n"] + ls[j + 1:])
    assert GATE in out
    return out

@case_fn("eval-push-above-gate")     # MED 4: `startswith("git push")` never saw an eval
def _(t):
    return t.replace(GATE, 'eval "git push \\"$REMOTE\\" \\"$BR:$MAIN\\""\n' + GATE, 1)

@case_fn("git-C-push-above-gate")    # …nor a `-C` between `git` and `push`
def _(t):
    return t.replace(GATE, 'git -C . push "$REMOTE" "$BR:$MAIN"\n' + GATE, 1)

@case_fn("var-git-push-above-gate")  # …nor the command name held in a variable
def _(t):
    return t.replace(GATE, 'GIT_BIN=git; $GIT_BIN push "$REMOTE" "$BR:$MAIN"\n' + GATE, 1)

@case_fn("header-executable-line")   # BLOCKER 2: a newline in --out put a bare command at line 11,
def _(t):                            # ABOVE `set -uo pipefail` — and a PREVIEW run executed it
    return t.replace("#   Preview:  bash ", "touch SYNTH-HEADER-RCE\n#   Preview:  bash ", 1)

@case_fn("header-verdict-blank")     # a turnkey that never states what the gate said
def _(t):
    return re.sub(r"^#([ \t]+)verdict:[ \t]+[^\n]*$", r"#\1verdict:", t, flags=re.M, count=1)

@case_fn("header-sha-removed")       # a verdict with no commit beside it — a rumour
def _(t):
    return re.sub(r"^#[ \t]+gated at:[ \t]+[0-9a-f]{40}[ \t]*\n", "", t, flags=re.M, count=1)

@case_fn("header-sha-mismatch")      # THE shipped bug: header claims one commit, the guard admits another
def _(t):
    pin = re.search(r'^GATED_AT="([0-9a-f]{40})"$', t, re.M).group(1)
    other = ("b" if pin[0] != "b" else "c") + pin[1:]
    return re.sub(r"^(#[ \t]+gated at:[ \t]+)[0-9a-f]{40}", lambda mo: mo.group(1) + other,
                  t, flags=re.M, count=1)

@case_fn("strip-justification")      # the flag survives; the argument for it does not
def _(t):
    ls = t.splitlines(True)
    i = next(k for k, l in enumerate(ls) if l.startswith(ANCHOR))
    j = i
    while ls[j].lstrip().startswith("#"):
        j += 1
    return "".join(ls[:i] + ls[j:])

@case_fn("strip-flat-rule")          # the one line that stops a reader copying the flag onward
def _(t):
    return t.replace("# " + m._SHIP_JUSTIFY_RULE + "\n", "")

@case_fn("gut-justification-body")   # heading kept, reasoning deleted — it still LOOKS argued
def _(t):
    return t.replace("The release gate ALREADY ran", "we skip it")

@case_fn("noverify-above-refusal")   # a gate-skip upstream of the proof that earns it
def _(t):
    return t.replace("set -uo pipefail\n",
                     "set -uo pipefail\n# note: the pushes below use --no-verify\n", 1)

@case_fn("push-above-preview-gate")  # a preview that pushes is not a preview
def _(t):
    return t.replace(GATE, 'git push "$REMOTE" "$BR:$MAIN"\n' + GATE, 1)

@case_fn("unsubstituted-token")      # a value the generator failed to supply, that bash reads as a word
def _(t):
    return t.replace('REMOTE="origin"', 'REMOTE="@@REMOTE@@"', 1)

@case_fn("syntax-broken")            # no shellcheck on the box; `bash -n` is the validator
def _(t):
    return t + "\nif [ 1 = 1 ]; then\n  echo unterminated\n"

# ── the refusal RUNS, EXITS, and is still defeated ────────────────────────────────────────────────
# Confirmed by an adversarial re-verification: the nesting proof (column 0 + nothing open above) and
# the hostile-env lane between them still let FOUR variants through, each shipping an ungated commit
# AND tag with the whole suite green. They share one shape — the refusal compares $BRC against
# $GATED_AT, so anything that quietly reassigns either, or neuters `exit`, makes the comparison a
# formality. The worst printed the FULL refusal text and pushed anyway: output an operator cannot
# distinguish from a real check passing.
def _after_pin(t, line):
    return re.sub(r'^(GATED_AT="[0-9a-f]{40}"\n)', lambda mo: mo.group(1) + line + "\n",
                  t, flags=re.M, count=1)

@case_fn("hatch-reassigns-brc")      # `[ -f … ] && BRC="$GATED_AT"` — column 0, so the nesting proof
def _(t):                            # sees nothing, and it is keyed on a FILE so no env battery hits it
    return _after_pin(t, '[ -f "$REPO/.ship-anyway" ] && BRC="$GATED_AT"')

@case_fn("hatch-reassigns-gated-at") # the mirror image: move the pin to the tip instead
def _(t):
    return _after_pin(t, 'GATED_AT="$BRC"')

@case_fn("brc-reassigned-in-a-block")  # the assignment need not start the line
def _(t):
    return _after_pin(t, 'if true; then BRC="$GATED_AT"; fi')

@case_fn("exit-shadowed")            # the refusal runs, prints in full, and `exit` does nothing
def _(t):
    return _after_pin(t, "exit() { command true; }")

@case_fn("helper-redefined")         # a second definition wins at run time, far from where it is used
def _(t):
    return _after_pin(t, "die() { :; }")

@case_fn("exit-after-the-fi")        # a proximity scan accepted an `exit 1` OUTSIDE the branch
def _(t):
    ls = t.splitlines(True)
    r = next(k for k, l in enumerate(ls) if l.startswith('if [ "$BRC" != "$GATED_AT" ]'))
    f = next(k for k in range(r + 1, len(ls)) if ls[k].rstrip("\n") == "fi")
    body = [l for l in ls[r:f] if "exit 1" not in l]
    return "".join(ls[:r] + body + [ls[f]] + ["[ -f /nonexistent/never ] && exit 1\n"] + ls[f + 1:])

@case_fn("noverify-quote-split")     # `--no-""verify` contains no literal `--no-verify`; bash runs one
def _(t):
    ls = t.splitlines(True)
    i = next(k for k, l in enumerate(ls) if l.startswith(ANCHOR))
    j = i
    while ls[j].lstrip().startswith("#"):
        j += 1
    stripped = "".join(ls[:i] + ls[j:])
    return stripped.replace("--no-verify", '--no-""verify')

if case == "fixed":
    try:
        m._assert_ship_guards(text)
    except SystemExit:
        print("FAIL: the guard REJECTED the REAL render — generation is broken")
        sys.exit(2)
    sys.exit(0)

if case not in CASES:
    print("FAIL: unknown case %r" % case)
    sys.exit(4)
mut = CASES[case](text)
if mut == text:
    print("FAIL: mutation %r matched NOTHING — the lane would be vacuously green" % case)
    sys.exit(3)
try:
    m._assert_ship_guards(mut)
except SystemExit:
    sys.exit(0)          # correctly REFUSED
print("FAIL: the guard ACCEPTED a render mutated by %r" % case)
sys.exit(1)
PYEOF

REND="$F/g1.sh"
chk "the driver has a real render to mutate (non-vacuous fixture)" \
  "[ -s '$REND' ] && grep -q '^GATED_AT=' '$REND'"
chk "★ NEGATIVE CONTROL: the guard ACCEPTS the real render (it is not just refusing everything)" \
  "python3 '$DRIVE' '$AM' '$REND' fixed"
for c in strip-refusal strip-pin refusal-does-not-exit exit-only-in-a-comment refusal-indented \
         refusal-nested-in-a-condition preview-gate-nested-in-a-condition \
         header-verdict-blank header-sha-removed header-sha-mismatch header-executable-line \
         strip-justification strip-flat-rule gut-justification-body noverify-above-refusal \
         push-above-preview-gate eval-push-above-gate git-C-push-above-gate \
         var-git-push-above-gate unsubstituted-token syntax-broken \
         hatch-reassigns-brc hatch-reassigns-gated-at brc-reassigned-in-a-block \
         exit-shadowed helper-redefined exit-after-the-fi noverify-quote-split; do
  chk "★ RED: guard REFUSES a render mutated by '$c'" "python3 '$DRIVE' '$AM' '$REND' $c"
done
# The refusal message IS the product here — this file's whole subject is a guard whose output an
# operator reads once, at speed, mid-release. `lines.index()` on a one-space-indented refusal raised
# an uncaught ValueError: fail-CLOSED, but what the operator got was a python traceback instead of
# the sentence explaining what is wrong and what to do. Assert the prose, not just the exit code.
IND_OUT="$(python3 "$DRIVE" "$AM" "$REND" refusal-indented 2>&1)"; IND_RC=$?
chk "★ …and the INDENTED refusal dies with WRITTEN PROSE, never a python traceback" \
  "[ $IND_RC -eq 0 ] && ! printf '%s' \"\$IND_OUT\" | grep -q 'Traceback (most recent call last)'"
echo

# ══ §4  THE EMITTED SCRIPT — it goes RED when the branch moves after it was generated ════════════
echo "4. the emitted script: the branch moved after the gate → REFUSE (the miss this exists for)"
R2="$(need_fix e1)"
TIP2="$(tip_of "$R2")"
gen "$R2" "$F/e1.sh" "$TIP2"
chk "generated against the fixture tip (rc 0)" "[ $GEN_RC -eq 0 ] && [ -s '$F/e1.sh' ]"

# baseline the bare origin BEFORE any run, so "pushed nothing" is measured, not assumed
O2="$F/e1/origin.git"
OM_BEFORE="$(g "$O2" rev-parse main)"
OT_BEFORE="$(g "$O2" tag | sort | tr '\n' ' ')"
chk "baseline is non-vacuous (the bare origin has a main and the PREV tag)" \
  "[ -n '$OM_BEFORE' ] && printf '%s' '$OT_BEFORE' | grep -q '$PREV'"

run_ship "$F/e1.sh" "$R2"
chk "UNMOVED: the no-flag run reaches the PREVIEW and exits 0" \
  "[ $SH_RC -eq 0 ] && printf '%s' \"\$SH_OUT\" | grep -q 'PREVIEW ONLY'"
chk "★ PREVIEW pushed NOTHING: the bare origin's main is unchanged" \
  "[ \"\$(g '$O2' rev-parse main)\" = '$OM_BEFORE' ]"
chk "★ PREVIEW pushed NOTHING: no new tag on the origin, and none created locally either" \
  "[ \"\$(g '$O2' tag | sort | tr '\n' ' ')\" = '$OT_BEFORE' ] && ! g '$R2' rev-parse -q --verify 'refs/tags/$TAG' >/dev/null"

# THE LANE. Re-stage the branch — the real shape of the miss: the tip changes but its parent is
# STILL origin/main, so all three ordinary preconditions stay green (fast-forwards, tag still new,
# plugin/ still unchanged). Only the freshness pin can tell that this is not what was gated.
printf 'the late fix nobody re-gated\n' >> "$R2/README.md"
g "$R2" add -A
g "$R2" commit -q --amend --no-edit
MOVED="$(tip_of "$R2")"
chk "fixture moved for real (tip changed, parent is STILL origin/main → the old checks stay green)" \
  "[ \"$MOVED\" != \"$TIP2\" ] && [ \"\$(g '$R2' rev-parse '$BR^')\" = \"\$(g '$R2' rev-parse origin/main)\" ]"

run_ship "$F/e1.sh" "$R2"
chk "★ MOVED: the emitted script exits NON-ZERO" "[ $SH_RC -ne 0 ]"
chk "★ MOVED: it says the branch moved after it was gated, naming BOTH SHAs" \
  "printf '%s' \"\$SH_OUT\" | grep -q 'MOVED after it was gated' && printf '%s' \"\$SH_OUT\" | grep -q '${MOVED:0:7}' && printf '%s' \"\$SH_OUT\" | grep -q '${TIP2:0:7}'"
chk "★ MOVED: it says NOT pushing" "printf '%s' \"\$SH_OUT\" | grep -q 'NOT pushing'"
chk "★★ THE POINT: the three ORDINARY preconditions PASSED on this stale branch — only the pin caught it" \
  "printf '%s' \"\$SH_OUT\" | grep -q 'clean fast-forward, tag is new' && ! printf '%s' \"\$SH_OUT\" | grep -q 'no longer fast-forwards' && ! printf '%s' \"\$SH_OUT\" | grep -q 'already exists'"
chk "★ MOVED: still pushed nothing (origin main + tags unchanged)" \
  "[ \"\$(g '$O2' rev-parse main)\" = '$OM_BEFORE' ] && [ \"\$(g '$O2' tag | sort | tr '\n' ' ')\" = '$OT_BEFORE' ]"

run_ship "$F/e1.sh" "$R2" --push
chk "★ MOVED: it refuses under --push too (the flag is not a way past the pin)" "[ $SH_RC -ne 0 ]"
chk "★ MOVED --push: the origin is STILL untouched (the refusal is upstream of every push)" \
  "[ \"\$(g '$O2' rev-parse main)\" = '$OM_BEFORE' ] && [ \"\$(g '$O2' tag | sort | tr '\n' ' ')\" = '$OT_BEFORE' ]"

# ── THE HOSTILE-ENVIRONMENT LANE ────────────────────────────────────────────────────────────────
# run_ship uses `env -i` DELIBERATELY: no ambient variable may pick a lane. That is also the one
# thing it structurally cannot test. An escape hatch keyed on ANY environment variable — the shape a
# hurried "just this once" edit takes — is invisible to a suite that never sets one. Reproduced:
# `if [ "${SHIP_SKIP_FRESHNESS:-0}" = 0 ]; then` … `fi` around an UNTOUCHED refusal kept every
# literal byte, kept this suite at 76/0, and pushed an ungated commit and tag to the bare origin.
# So run the SAME moved-branch case with a battery of plausible escape-hatch names exported. The
# battery is DERIVED from the rendered artifact (every `${VAR:-…}` it actually reads) plus a fixed
# list, so a future `${SOME_NEW_KNOB:-0}` is covered the day it is added rather than the day it bites.
derived_env_names() {   # <script> → the ${VAR:-…} names the artifact itself reads
  grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*:-' "$1" | sed 's/^\${//; s/:-$//' | sort -u
}
DERIVED="$(derived_env_names "$F/e1.sh" | tr '\n' ' ')"
chk "the env-name extractor WORKS against the real artifact (it finds SHIP_REPO — non-vacuous)" \
  "printf '%s' '$DERIVED' | grep -qw SHIP_REPO"
HOSTILE_NAMES="$( { derived_env_names "$F/e1.sh"
    printf '%s\n' SHIP_SKIP_FRESHNESS SHIP_REMOTE SHIP_FORCE SHIP_PUSH GATED_AT BRC PUSH FORCE \
                  SKIP CI DEBUG VERIFY NO_VERIFY DRY_RUN YES ASSUME_YES OVERRIDE UNSAFE ALLOW_STALE
  } | sort -u | grep -vxE 'PATH|HOME|SHIP_REPO' | tr '\n' ' ')"
chk "the hostile battery is non-vacuous and carries the known escape-hatch name" \
  "[ \"\$(printf '%s' '$HOSTILE_NAMES' | wc -w)\" -ge 15 ] && printf '%s' '$HOSTILE_NAMES' | grep -qw SHIP_SKIP_FRESHNESS"

run_ship_hostile() {   # run_ship, but with every plausible escape hatch EXPORTED non-empty and =1
  local s="$1" r="$2"; shift 2
  if [ ! -s "$s" ]; then SH_RC=0; SH_OUT="SELFTEST-ERROR: nothing was emitted at $s"; return 0; fi
  local -a envargs=(PATH="$PATH" HOME="$F/home" SHIP_REPO="$r")
  local n
  for n in $HOSTILE_NAMES; do envargs+=("$n=1"); done
  SH_RC=0
  SH_OUT="$(env -i "${envargs[@]}" bash "$s" "$@" 2>&1)" || SH_RC=$?
}

run_ship_hostile "$F/e1.sh" "$R2"
chk "★★ HOSTILE ENV, moved branch: the emitted script STILL exits non-zero" "[ $SH_RC -ne 0 ]"
chk "★★ HOSTILE ENV: it still refuses for the freshness reason, naming both SHAs" \
  "printf '%s' \"\$SH_OUT\" | grep -q 'MOVED after it was gated' && printf '%s' \"\$SH_OUT\" | grep -q '${MOVED:0:7}' && printf '%s' \"\$SH_OUT\" | grep -q '${TIP2:0:7}'"
run_ship_hostile "$F/e1.sh" "$R2" --push
chk "★★ HOSTILE ENV + --push: STILL exits non-zero (no variable is a way past the pin)" \
  "[ $SH_RC -ne 0 ]"
chk "★★ HOSTILE ENV + --push: the bare origin's main and tags are BYTE-IDENTICAL to the baseline" \
  "[ \"\$(g '$O2' rev-parse main)\" = '$OM_BEFORE' ] && [ \"\$(g '$O2' tag | sort | tr '\n' ' ')\" = '$OT_BEFORE' ]"
chk "★★ HOSTILE ENV: no tag was created locally either" \
  "! g '$R2' rev-parse -q --verify 'refs/tags/$TAG' >/dev/null"
echo

# ══ §5  the other refusals, and the one lane that actually pushes (hermetically) ═════════════════
echo "5. the emitted script: the remaining preconditions, and a real --push against a bare fixture origin"
R3="$(need_fix e2)"; TIP3="$(tip_of "$R3")"; gen "$R3" "$F/e2.sh" "$TIP3"
g "$R3" tag "$TAG" "$BR"
run_ship "$F/e2.sh" "$R3"
chk "RED: the tag already exists → refuses (a published tag is not re-cut)" \
  "[ $SH_RC -ne 0 ] && printf '%s' \"\$SH_OUT\" | grep -q 'already exists'"

R4="$(need_fix e3)"; TIP4="$(tip_of "$R4")"; gen "$R4" "$F/e3.sh" "$TIP4"
g "$R4" checkout -q main
printf 'someone else landed\n' >> "$R4/README.md"
g "$R4" add -A; g "$R4" commit -qm 'main moved'
g "$R4" push -q origin main
run_ship "$F/e3.sh" "$R4"
chk "RED: origin/main moved under the branch → refuses (no longer a fast-forward)" \
  "[ $SH_RC -ne 0 ] && printf '%s' \"\$SH_OUT\" | grep -q 'no longer fast-forwards'"

R5="$(need_fix e4)"; TIP5="$(tip_of "$R5")"; gen "$R5" "$F/e4.sh" "$TIP5"
g "$R5" remote remove origin
run_ship "$F/e4.sh" "$R5"
chk "RED: an absent/unreachable remote → fail-closed BEFORE any precondition is adjudicated" \
  "[ $SH_RC -ne 0 ] && printf '%s' \"\$SH_OUT\" | grep -q 'git fetch'"

run_ship "$F/e4.sh" "$R5" --nonsense
chk "RED: an unknown argument → refuses (never a silent fallthrough to the default posture)" \
  "[ $SH_RC -ne 0 ] && printf '%s' \"\$SH_OUT\" | grep -q 'unknown argument'"
run_ship "$F/e4.sh" "$R5" --help
chk "--help exits 0 and names the PREVIEW default" \
  "[ $SH_RC -eq 0 ] && printf '%s' \"\$SH_OUT\" | grep -q 'PREVIEW'"

# the CONDITIONAL plugin invariant: a bump is required if and only if plugin/ content changed
R6="$(need_fix e5 1)"
printf 'skill one, edited\n' > "$R6/plugin/skills/one.md"
g "$R6" add -A; g "$R6" commit -q --amend --no-edit
TIP6="$(tip_of "$R6")"; gen "$R6" "$F/e5.sh" "$TIP6"
chk "plugin fixture is non-vacuous (plugin/ really differs from $PREV)" \
  "! g '$R6' diff --quiet '$PREV' '$BR' -- ':/plugin'"
run_ship "$F/e5.sh" "$R6"
chk "★ RED: plugin/ content CHANGED with no plugin.json version bump → refuses" \
  "[ $SH_RC -ne 0 ] && printf '%s' \"\$SH_OUT\" | grep -q 'plugin.json version did not'"
printf '{ "name": "fixture", "version": "0.2.0" }\n' > "$R6/plugin/.claude-plugin/plugin.json"
g "$R6" add -A; g "$R6" commit -q --amend --no-edit
TIP6B="$(tip_of "$R6")"; gen "$R6" "$F/e5b.sh" "$TIP6B"
run_ship "$F/e5b.sh" "$R6"
chk "★ GREEN (negative control): the SAME change WITH a bump reaches the preview" \
  "[ $SH_RC -eq 0 ] && printf '%s' \"\$SH_OUT\" | grep -q '0.1.0 → 0.2.0' && printf '%s' \"\$SH_OUT\" | grep -q 'PREVIEW ONLY'"

# The one lane that pushes. Hermetic BY ASSERTION, not by hope.
R7="$(need_fix e6)"; TIP7="$(tip_of "$R7")"; gen "$R7" "$F/e6.sh" "$TIP7"
O7="$F/e6/origin.git"
FIX_ORIGIN="$(g "$R7" remote get-url origin)"
# The `case` below is the ONLY thing standing between this lane and a real push. Its pattern is
# built from $F, so an EMPTY $F would collapse it to `/*` — matching every absolute path on the box
# while still reading as a guard. $F was asserted non-empty and absolute at the top of this file;
# assert the rest of the premise here so the pattern cannot be true for the wrong reason.
[ -n "$FIX_ORIGIN" ] || { echo "  ❌ FATAL: the fixture has no origin URL — refusing the push lane"; exit 9; }
[ "$FIX_ORIGIN" = "$O7" ] || { echo "  ❌ FATAL: the fixture's origin is not the bare repo this lane built ($FIX_ORIGIN != $O7)"; exit 9; }
[ -d "$O7" ] && [ -n "$F" ] && [ -d "$F" ] || { echo "  ❌ FATAL: scratch dir or bare origin missing — refusing the push lane"; exit 9; }
case "$FIX_ORIGIN" in
  "$F"/*)
    ok "push lane guard: the fixture's origin is a bare repo inside this run's own scratch dir"
    run_ship "$F/e6.sh" "$R7" --push
    chk "★ --push fast-forwards the bare origin's main to the release commit" \
      "[ $SH_RC -eq 0 ] && [ \"\$(g '$O7' rev-parse main)\" = '$TIP7' ]"
    chk "★ --push publishes the annotated tag on the release commit" \
      "[ \"\$(g '$O7' rev-parse '$TAG^{commit}')\" = '$TIP7' ]"
    chk "…and it announced the gate-skip with the SHA the gate certified" \
      "printf '%s' \"\$SH_OUT\" | grep -q 'pre-push skipped' && printf '%s' \"\$SH_OUT\" | grep -q '${TIP7:0:7}'"
    chk "…and it said plainly the live-installer check was SKIPPED, rather than implying it passed" \
      "printf '%s' \"\$SH_OUT\" | grep -q 'installer verification SKIPPED'"
    # A second run must refuse. It refuses on the FAST-FORWARD check rather than the tag check,
    # because a successful publish moves the remote's main ONTO the release commit — so the branch's
    # parent is no longer the remote head. Assert the real reason, not the one that reads nicest.
    run_ship "$F/e6.sh" "$R7"
    chk "…a SECOND run refuses — never a double publish" "[ $SH_RC -ne 0 ]"
    chk "…and refuses for the RIGHT reason (the publish moved the remote main onto the release commit)" \
      "printf '%s' \"\$SH_OUT\" | grep -q 'no longer fast-forwards'"
    chk "…and the published refs are untouched by the refused re-run" \
      "[ \"\$(g '$O7' rev-parse main)\" = '$TIP7' ] && [ \"\$(g '$O7' rev-parse '$TAG^{commit}')\" = '$TIP7' ]"
    ;;
  *)
    bad "push lane guard: the fixture's origin is NOT inside the scratch dir — REFUSED to run the push lane"
    ;;
esac
echo

# ══ §6  the flag and its justification travel together in the SHIPPED artifact ══════════════════
echo "6. the emitted artifact carries the gate-skip WITH its argument (never the flag alone)"
ART="$F/e1.sh"
NV_COUNT="$(grep -cE '^git push --no-verify' "$ART")"
NV_FIRST_ANY="$(grep -n -e '--no-verify' "$ART" | head -1 | cut -d: -f1)"
NV_FIRST_PUSH="$(grep -nE '^git push --no-verify' "$ART" | head -1 | cut -d: -f1)"
JUST_LINE="$(grep -n 'why these pushes skip the pre-push hook' "$ART" | head -1 | cut -d: -f1)"
REFUSE_LINE="$(grep -nF 'if [ "$BRC" != "$GATED_AT" ]; then' "$ART" | head -1 | cut -d: -f1)"
chk "extraction is non-vacuous (found the pushes, the justification, and the refusal)" \
  "[ -n '$NV_FIRST_ANY' ] && [ -n '$NV_FIRST_PUSH' ] && [ -n '$JUST_LINE' ] && [ -n '$REFUSE_LINE' ]"
chk "both release pushes carry --no-verify (exactly 2)" "[ '$NV_COUNT' = 2 ]"
chk "the justification block is present and ends on the flat rule" \
  "grep -qF 'Never \`--no-verify\` a push that was not gated.' '$ART'"
chk "★ the justification sits ABOVE the first --no-verify push (a downward reader meets it first)" \
  "[ '$JUST_LINE' -lt '$NV_FIRST_PUSH' ]"
chk "★ NO --no-verify appears anywhere above the freshness refusal" \
  "[ '$NV_FIRST_ANY' -gt '$REFUSE_LINE' ]"
chk "the artifact bakes NO owner/repo slug — the public installer URL is derived at run time" \
  "! grep -qE 'raw\.githubusercontent\.com/[A-Za-z0-9]' '$ART' && grep -qF 'git remote get-url' '$ART'"
chk "the SHIPPED template carries no machine home path (the public-phrasing gate)" \
  "! grep -qE '/(home|Users)/[a-z_][a-z0-9_.-]{2,}/' '$TMPL'"
# The push REMOTE was `${SHIP_REMOTE:-origin}` — an env knob retargeting the ONE irreversible act in
# the file, with zero legitimate consumers (its only other appearance in the tree was this suite's
# own mutation anchor, which REPLACED it). An escape hatch nobody uses is one only an attacker, or a
# hurried future edit, will find. SHIP_REPO stays: the hermetic fixture genuinely needs it.
chk "★ the push REMOTE is HARDCODED — no environment variable can retarget the irreversible act" \
  "[ \"\$(grep -cE '^REMOTE=' '$ART')\" = 1 ] && grep -qx 'REMOTE=\"origin\"' '$ART' \
   && [ \"\$(grep -cE '^REMOTE=' '$TMPL')\" = 1 ] && grep -qx 'REMOTE=\"origin\"' '$TMPL'"

echo

# ══ §7  THE GUARD'S CALL SITE — proven END TO END through the real command ══════════════════════
# §3 drives _assert_ship_guards through a python importer. That proves the FUNCTION works and
# nothing else. Commenting out the single `_assert_ship_guards(text)` call in cmd_gen_ship_turnkey
# left this suite at 76 passed / 0 failed: a guard nothing calls is a guard that does not exist, and
# the only suite that could have said so was testing it through a door the product does not use.
# So: mutate a COPIED template, run the COPIED generator from argv to file, and require rc != 0 AND
# that no artifact was written. A positive control first, so a RED here means "refused", not "broke".
echo "7. the call site: a mutated TEMPLATE must stop the REAL \`gen-ship-turnkey\` command"
CS="$F/callsite"
mkdir -p "$CS/scripts/templates"
cp "$AM" "$CS/scripts/adopt-manifest.py"
cp -R "$REPO/scripts/templates/." "$CS/scripts/templates/"
CSAM="$CS/scripts/adopt-manifest.py"
CSTMPL="$CS/scripts/templates/ship-turnkey.sh.tmpl"
R8="$(need_fix e7)"; TIP8="$(tip_of "$R8")"
cs_gen() {   # <out> → CS_RC / CS_OUT, through the COPIED generator's real argv path
  local o="$1"; CS_RC=0
  rm -f "$o"
  CS_OUT="$(python3 "$CSAM" gen-ship-turnkey --repo "$R8" --branch "$BR" --version "$TAG" \
              --prev-version "$PREV" --gated-at "$TIP8" --verdict "$VERDICT" --out "$o" 2>&1)" \
            || CS_RC=$?
}
cs_gen "$F/cs-control.sh"
chk "★ POSITIVE CONTROL: the COPIED generator + COPIED template emit normally (the copy works)" \
  "[ $CS_RC -eq 0 ] && [ -s '$F/cs-control.sh' ]"

# Mutation A — delete the GATED_AT pin. `bash -n` still passes on the result, so ONLY the guard can
# catch it: that is what makes this a CALL-SITE probe rather than a syntax probe.
python3 - "$CSTMPL" <<'PYEOF'
import re, sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
n = re.sub(r'^GATED_AT="@@GATED_AT@@"\n', "", t, flags=re.M, count=1)
assert n != t, "call-site mutation A matched nothing — the lane would be vacuously green"
open(p, "w", encoding="utf-8").write(n)
PYEOF
chk "call-site mutation A really changed the COPIED template (non-vacuous)" \
  "! cmp -s '$CSTMPL' '$TMPL'"
cs_gen "$F/cs-nopin.sh"
chk "★★ RED end-to-end: the REAL command REFUSES a render with no GATED_AT pin" "[ $CS_RC -ne 0 ]"
chk "★★ …and wrote NO file (a refusal that still emits is not a refusal)" "[ ! -e '$F/cs-nopin.sh' ]"
chk "…and it is the GUARD that spoke, not \`bash -n\`" \
  "printf '%s' \"\$CS_OUT\" | grep -q 'no GATED_AT pin'"

# Mutation B — the BLOCKER-1 shape, end to end: nest the untouched refusal inside an env condition.
cp "$TMPL" "$CSTMPL"
python3 - "$CSTMPL" <<'PYEOF'
import sys
p = sys.argv[1]; ls = open(p, encoding="utf-8").read().splitlines(True)
REFUSAL = 'if [ "$BRC" != "$GATED_AT" ]; then'
i = next(k for k, l in enumerate(ls) if l.rstrip("\n") == REFUSAL)
j = i
while ls[j].rstrip("\n") != "fi":
    j += 1
out = "".join(ls[:i] + ['if [ "${SHIP_SKIP_FRESHNESS:-0}" = 0 ]; then\n']
              + ls[i:j + 1] + ["fi\n"] + ls[j + 1:])
assert REFUSAL in out, "the refusal must survive VERBATIM — the whole point of this mutation"
open(p, "w", encoding="utf-8").write(out)
PYEOF
chk "call-site mutation B keeps the refusal line BYTE-IDENTICAL (only the nesting changed)" \
  "grep -qxF 'if [ \"\$BRC\" != \"\$GATED_AT\" ]; then' '$CSTMPL'"
cs_gen "$F/cs-wrapped.sh"
chk "★★ RED end-to-end: the REAL command REFUSES a freshness refusal nested in a condition" \
  "[ $CS_RC -ne 0 ]"
chk "★★ …and wrote NO file" "[ ! -e '$F/cs-wrapped.sh' ]"
chk "…and it named the TOP-LEVEL requirement (not a syntax error, not a missing byte)" \
  "printf '%s' \"\$CS_OUT\" | grep -q 'NOT at top level'"

echo
echo "──────────────────────────────"
echo "  $PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
  echo "  ✅ the ship turnkey refuses a tree the gate never saw, and the flag that skips the hook cannot outlive its argument"
  exit 0
fi
echo "  ❌ see failures above"; exit 1
