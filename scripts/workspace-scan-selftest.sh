#!/usr/bin/env bash
# workspace-scan-selftest.sh — prove the scanners cover a MULTI-REPO ROOT without losing
# fail-closed.
#
#   bash scripts/workspace-scan-selftest.sh
#
# WHY THIS EXISTS (2026-08-04). kickoff can be mounted on a root folder holding N sibling repos —
# "a monorepo split across repos". The coordinator half already worked; the gates did not. Both
# scanners refused at such a root ("not inside a git work tree"), which is the correct failure
# direction and still meant the org had NO secret scan and NO structural scan at all.
#
# The change makes them fan out across members. The danger in that change is obvious and is what
# this suite is mostly about: a fan-out is a new way to report green on nothing. Every assertion
# below is aimed at one of the three ways that happens —
#
#   1. scanning ZERO members and calling it clean,
#   2. scanning SOME members and calling it clean (short-circuit, or an unreadable member skipped),
#   3. losing the plain single-repo behaviour that every existing adopter depends on.
#
# THE FIXTURE IS THE DEPLOY TOPOLOGY, NOT A DEV CHECKOUT: a real root directory containing real
# git checkouts, plus a decoy plain directory that is NOT a repo. A fixture shaped like the origin
# goes green while the bug is live — and three times in one night last week a fixture put its
# payload where the code never looks, so each case here is checked to actually reach the path.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SEC="$HERE/scan-secrets.sh"
STR="$HERE/scan-structure.sh"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "▶ workspace scan self-test (a fan-out is a new way to report green on nothing)"
echo

F="$(mktemp -d)"; trap 'chmod -R u+rwX "$F" 2>/dev/null; rm -rf "$F"' EXIT
mkrepo() {                       # mkrepo <path> [file] [content]
  mkdir -p "$1"; git -c init.defaultBranch=main init -q "$1"
  if [ -n "${2:-}" ]; then printf '%s\n' "${3:-ok}" > "$1/$2"; fi
  ( cd "$1" && git add -A >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t commit -qm x >/dev/null 2>&1 )
}
# AWS's own documented example key, used as the fixture this suite plants and expects to be
# caught. pragma-allowlisted because the gate is right to flag it — it is a credential-shaped
# literal — and the sanctioned path for a deliberate one is to say so, not to widen the pattern.
LEAK='const k = "AKIAIOSFODNN7EXAMPLE";'  # pragma: allowlist secret

# ── 1. A root that is NOT a repo and holds NO repos must still REFUSE ────────────
# This is the original fail-closed guard and the fan-out must not soften it: an empty
# directory is a mistake, not a workspace, and "clean" is the wrong answer for it.
mkdir -p "$F/empty-root"
( cd "$F/empty-root" && bash "$SEC" >/dev/null 2>&1 ); chk "empty root: scan-secrets still REFUSES (rc 2)" "[ $? -eq 2 ]"
( cd "$F/empty-root" && bash "$STR" >/dev/null 2>&1 ); chk "empty root: scan-structure still REFUSES (rc 2)" "[ $? -eq 2 ]"
# A root holding only NON-repo directories is the same case — a decoy must not read as a member.
mkdir -p "$F/decoy-root/looks-like-a-repo/src"
( cd "$F/decoy-root" && bash "$SEC" >/dev/null 2>&1 ); chk "root of non-repo dirs: still REFUSES (a decoy is not a member)" "[ $? -eq 2 ]"

# ── 2. A real workspace is scanned, and a leak anywhere fails the whole run ──────
mkrepo "$F/ws/clean-a" "fine.txt" "nothing here"
mkrepo "$F/ws/leaky"   "leak.js"  "$LEAK"
mkrepo "$F/ws/clean-b" "fine.txt" "nothing here"
mkdir -p "$F/ws/notes"                       # a plain dir in the workspace: must be ignored, not scanned
printf '%s\n' "$LEAK" > "$F/ws/notes/untracked-leak.js"
OUT="$( cd "$F/ws" && bash "$SEC" 2>&1 )"; RC=$?
chk "workspace: reports workspace mode"             "printf '%s' \"\$OUT\" | grep -q 'workspace mode'"
chk "workspace: counts exactly the 3 real repos"    "printf '%s' \"\$OUT\" | grep -q '3 repo(s)'"
chk "workspace: FAILS overall on a leak in a member" "[ $RC -ne 0 ]"
chk "workspace: names the failing member"           "printf '%s' \"\$OUT\" | grep -q 'FAILED in: leaky'"
chk "workspace: the leak itself is reported"        "printf '%s' \"\$OUT\" | grep -q 'AWS access key id'"
chk "workspace: a plain dir is NOT treated as a member" "! printf '%s' \"\$OUT\" | grep -q 'notes'"

# ── 3. It must not SHORT-CIRCUIT — every member is visited ───────────────────────
# The cheap wrong implementation stops at the first failure. Then a leak in a later repo is
# invisible for as long as an earlier repo is dirty, which is exactly a silent partial scan.
# THE ORDERING IS THE TEST. Members are visited in glob order, so this only detects a `break`
# if the FAILING member sorts BEFORE a clean one. The first version of this case had the leaky
# repo last in both fixtures, so a short-circuit mutant skipped nothing and scored a clean sheet.
mkrepo "$F/wsorder/aaa-leaky" "leak.js" "$LEAK"
mkrepo "$F/wsorder/mmm-clean" "fine.txt" "nothing"
mkrepo "$F/wsorder/zzz-clean" "fine.txt" "nothing"
OUTO="$( cd "$F/wsorder" && bash "$SEC" 2>&1 )"; RCO=$?
chk "no short-circuit: members AFTER the failing one are still visited" \
  "printf '%s' \"\$OUTO\" | grep -q '── mmm-clean' && printf '%s' \"\$OUTO\" | grep -q '── zzz-clean'"
chk "no short-circuit: and the run still fails"     "[ $RCO -ne 0 ]"
chk "no short-circuit: all 3 members were counted"  "printf '%s' \"\$OUTO\" | grep -q '3 repo(s)'"
mkrepo "$F/ws2/aaa-clean" "fine.txt" "nothing"
mkrepo "$F/ws2/zzz-leaky" "leak.js" "$LEAK"
OUT2="$( cd "$F/ws2" && bash "$SEC" 2>&1 )"; RC2=$?
chk "a leak in the LAST member (alphabetically) still fails the run" "[ $RC2 -ne 0 ]"
chk "and it is named"                                "printf '%s' \"\$OUT2\" | grep -q 'FAILED in: zzz-leaky'"

# ── 4. An all-clean workspace passes, and says how many it covered ───────────────
mkrepo "$F/ws3/one" "a.txt" "fine"; mkrepo "$F/ws3/two" "b.txt" "fine"
OUT3="$( cd "$F/ws3" && bash "$SEC" 2>&1 )"; RC3=$?
chk "clean workspace passes"                        "[ $RC3 -eq 0 ]"
chk "clean workspace states the coverage count"     "printf '%s' \"\$OUT3\" | grep -q 'clean across 2 repo(s)'"
OUT3S="$( cd "$F/ws3" && bash "$STR" 2>&1 )"; RC3S=$?
chk "scan-structure covers the workspace too"       "[ $RC3S -eq 0 ] && printf '%s' \"\$OUT3S\" | grep -q '2 repo(s)'"

# ── 5. NO REGRESSION for the single-repo case every existing adopter uses ────────
mkrepo "$F/plain-clean" "a.txt" "fine"
( cd "$F/plain-clean" && bash "$SEC" >/dev/null 2>&1 ); chk "plain repo, clean: still passes (rc 0)" "[ $? -eq 0 ]"
mkrepo "$F/plain-leaky" "leak.js" "$LEAK"
( cd "$F/plain-leaky" && bash "$SEC" >/dev/null 2>&1 ); chk "plain repo, leak: still fails" "[ $? -ne 0 ]"
PLAIN="$( cd "$F/plain-clean" && bash "$SEC" 2>&1 )"
chk "plain repo does NOT enter workspace mode"      "! printf '%s' \"\$PLAIN\" | grep -q 'workspace mode'"
# A repo that happens to CONTAIN a nested checkout is still a plain repo, not a workspace.
mkrepo "$F/nested-outer" "a.txt" "fine"; mkrepo "$F/nested-outer/vendored" "b.txt" "fine"
NEST="$( cd "$F/nested-outer" && bash "$SEC" 2>&1 )"
chk "a repo containing a nested checkout stays single-repo" "! printf '%s' \"\$NEST\" | grep -q 'workspace mode'"

# ── 6. No runaway recursion when a member is itself a root ───────────────────────
mkdir -p "$F/ws4/inner-root"; mkrepo "$F/ws4/inner-root/deep" "a.txt" "fine"; mkrepo "$F/ws4/real" "b.txt" "fine"
OUT4="$( cd "$F/ws4" && timeout 60 bash "$SEC" 2>&1 )"; RC4=$?
chk "nested workspace terminates (no runaway recursion)" "[ $RC4 -ne 124 ]"
chk "and only the real member is counted at the top"     "printf '%s' \"\$OUT4\" | grep -q '1 repo(s)'"

# ── 7. An unreadable member must FAIL the run, never be silently skipped ─────────
# This is the subtlest way a fan-out reports green on nothing: one member cannot be entered and
# the aggregate still says clean.
mkrepo "$F/ws5/ok" "a.txt" "fine"; mkrepo "$F/ws5/locked" "b.txt" "fine"
chmod 000 "$F/ws5/locked"
OUT5="$( cd "$F/ws5" && bash "$SEC" 2>&1 )"; RC5=$?
chmod 755 "$F/ws5/locked" 2>/dev/null
chk "scan-secrets: an unreadable member does not read as clean"   "[ $RC5 -ne 0 ] || ! printf '%s' \"\$OUT5\" | grep -q 'clean across'"
# BOTH consumers, not just the first. The fix landed in scan-secrets and this suite went green
# while scan-structure still had the identical fail-open — a check that covers one of two callers
# is a check that reports on half a system.
chmod 000 "$F/ws5/locked"
OUT5S="$( cd "$F/ws5" && bash "$STR" 2>&1 )"; RC5S=$?
chmod 755 "$F/ws5/locked" 2>/dev/null
chk "scan-structure: an unreadable member does not read as clean" "[ $RC5S -ne 0 ] || ! printf '%s' \"\$OUT5S\" | grep -q 'clean across'"

# ── 7b. Placeholder tuning: env-driven config must not cry wolf ──────────────────
# An adopter whose FIRST scan reports four HIGH findings on a correct, env-driven Makefile learns
# to ignore the gate — and a gate that is ignored is worth less than no gate. `${VAR}` was
# already treated as a placeholder; Makefile/shell `$(VAR)` was not. Found on the first real
# workspace scan of a live adopter.
# The negative control is the load-bearing half: prove the filter did not simply go blind.
mkrepo "$F/mk"
printf 'migrate:\n\t@migrate -database "postgres://$(DB_USERNAME):$(DB_PASSWORD)@$(DB_HOST)/db"\n' > "$F/mk/Makefile"
printf 'KEY="AKIAIOSFODNN7EXAMPLE"\n' > "$F/mk/real.env"  # pragma: allowlist secret
( cd "$F/mk" && git add -A >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t commit -qm x >/dev/null 2>&1 )
MKOUT="$( cd "$F/mk" && bash "$SEC" 2>&1 )"
chk "env-driven \$(VAR) in a Makefile is NOT a finding"  "! printf '%s' \"\$MKOUT\" | grep -q 'Makefile'"
chk "NEGATIVE CONTROL: a real key in the same repo IS still caught" \
  "printf '%s' \"\$MKOUT\" | grep -q 'real.env'"
# `grep -qv` was the first attempt here and it is VACUOUS — it asks "is there any line without
# b.sh", which is true of essentially every output. Assert the absence directly instead.
printf 'p="${DB_PASSWORD}"\n' > "$F/mk/b.sh"
( cd "$F/mk" && git add -A >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t commit -qm y >/dev/null 2>&1 )
MKOUT2="$( cd "$F/mk" && bash "$SEC" 2>&1 )"
chk "\${VAR} form is still filtered too"                 "! printf '%s' \"\$MKOUT2\" | grep -q 'b.sh'"
chk "NEGATIVE CONTROL 2: the real key survives that too"  "printf '%s' \"\$MKOUT2\" | grep -q 'real.env'"

# ── 7c. FLAGS must survive the fan-out ───────────────────────────────────────────
# The arg-parse loop shifts "$@" empty, so the first version forwarded NOTHING to each member and
# every member silently ran with DEFAULT scope. Caught in adversarial review AFTER the fan-out had
# already been committed. For scan-secrets that only over-scans; for scan-structure it drops
# --strict, which is fail-OPEN — HIGH findings stop failing the run.
# Assert on BEHAVIOUR (the scope actually used, the exit code actually returned), never on the
# flag being present in some string.
mkrepo "$F/flags/m1" "ok.txt" "clean"
mkrepo "$F/flags/m2" "ok.txt" "clean"
FOUT="$( cd "$F/flags" && bash "$SEC" --staged 2>&1 )"
chk "--staged reaches every member (not silently downgraded to all-scope)" \
  "[ \$(printf '%s' \"\$FOUT\" | grep -c 'staged scope') -eq 2 ]"
chk "and no member fell back to all-scope"          "! printf '%s' \"\$FOUT\" | grep -q 'all scope'"

# --strict is the fail-OPEN one: prove it by the exit code on a real HIGH finding, both ways.
mkrepo "$F/strict/m1"
python3 -c "open('$F/strict/m1/big.ts','w').write('// x\n'*900)"
( cd "$F/strict/m1" && git add -A >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t commit -qm x >/dev/null 2>&1 )
( cd "$F/strict" && bash "$STR" >/dev/null 2>&1 ); _plain=$?
( cd "$F/strict" && bash "$STR" --strict >/dev/null 2>&1 ); _strict=$?
chk "workspace: plain scan-structure stays advisory (rc 0, got $_plain)"      "[ $_plain -eq 0 ]"
chk "workspace: --strict actually BLOCKS on a HIGH finding (rc 1, got $_strict)" "[ $_strict -ne 0 ]"

# ── 8. Explicit paths still work with no git anywhere (unchanged behaviour) ──────
printf '%s\n' "$LEAK" > "$F/loose.js"
( cd "$F" && bash "$SEC" "$F/loose.js" >/dev/null 2>&1 ); chk "explicit path still scanned without git" "[ $? -ne 0 ]"

# ══════════════════════════════════════════════════════════════════════════════════
echo
echo "9. THE MARKED GIT ROOT — 'is a git repo' and 'is a workspace' are no longer exclusive"
# ══════════════════════════════════════════════════════════════════════════════════
# "is this a workspace?" used to be answered by "is the root NOT a git repo?", which made the two
# MUTUALLY EXCLUSIVE. So a workspace root could never be a git repo, and an org's own charter,
# tracker, memory and specialist agents could never be version-controlled — and `git init` there
# silently DEMOTED the whole org to a single repo, with nothing going red. An EXPLICIT marker
# (`.kickoff/workspace`) now decides. The marker is REQUIRED rather than inferred: inferring
# would silently promote an ordinary repo that happens to contain a nested checkout.
GC="git -c user.email=t@t -c user.name=t"
commit_all() { ( cd "$1" && git add -A >/dev/null 2>&1 && $GC commit -qm "${2:-x}" >/dev/null 2>&1 ); }
mark_ws() { mkdir -p "$1/.kickoff"; printf '# kickoff workspace root\n' > "$1/.kickoff/workspace"; }

# The topology: a REAL git repo at the root (its own tracked CLAUDE.md + .claude/agents/), holding
# sibling checkouts that are gitignored at the root — which is exactly how an org versions its own
# config while its projects stay separate repos.
mkrepo "$F/gws" "CLAUDE.md" "# the org charter"
printf 'member-*/\n' > "$F/gws/.gitignore"
mkdir -p "$F/gws/.claude/agents"; printf '# planner\n' > "$F/gws/.claude/agents/planner.md"
mark_ws "$F/gws"; commit_all "$F/gws" root
mkrepo "$F/gws/member-a" "fine.txt" "nothing"
mkrepo "$F/gws/member-b" "leak.js"  "$LEAK"
chk "fixture: the marked root really IS a git repo (or this section measures nothing)" \
  "[ \"\$(cd \"$F/gws\" && git rev-parse --show-toplevel)\" = \"\$(cd \"$F/gws\" && pwd -P)\" ]"
GOUT="$( cd "$F/gws" && bash "$SEC" 2>&1 )"; GRC=$?
chk "marked git root: enters WORKSPACE mode even though it is a git repo" \
  "printf '%s' \"\$GOUT\" | grep -q 'workspace mode'"
chk "marked git root: the members are scanned (a member's leak fails the run)" \
  "[ $GRC -ne 0 ] && printf '%s' \"\$GOUT\" | grep -q 'FAILED in: member-b'"
chk "marked git root: it says the root itself is scanned too"  \
  "printf '%s' \"\$GOUT\" | grep -q 'this root is itself a git repo'"

# REQUIREMENT (c) — THE ROOT'S OWN TRACKED FILES. A fan-out that returns before scanning the root
# creates a NEW false green in the exact class this change exists to remove: a secret committed
# into the org's own CLAUDE.md or .claude/agents/*.md would sail past a "workspace clean".
mkrepo "$F/gws2" "README.md" "org"
printf 'member-*/\n' > "$F/gws2/.gitignore"; mark_ws "$F/gws2"
mkdir -p "$F/gws2/.claude/agents"
printf '%s\n' "$LEAK" > "$F/gws2/.claude/agents/deployer.md"     # the secret is in the ROOT's own crew
commit_all "$F/gws2" root
mkrepo "$F/gws2/member-a" "fine.txt" "nothing"
G2="$( cd "$F/gws2" && bash "$SEC" 2>&1 )"; G2RC=$?
chk "marked git root: a secret in the ROOT's OWN tracked file FAILS the run (not just the members)" \
  "[ $G2RC -ne 0 ]"
chk "…and the root is named as the failing unit, not silently folded into the members" \
  "printf '%s' \"\$G2\" | grep -q 'FAILED in: (this root)'"
chk "…and the finding itself points at the root's crew file" \
  "printf '%s' \"\$G2\" | grep -q '.claude/agents/deployer.md'"

# An all-clean marked git root counts ITSELF in the coverage number — a count that omitted the root
# would be quietly reporting on less than it scanned.
mkrepo "$F/gws3" "README.md" "org"; printf 'member-*/\n' > "$F/gws3/.gitignore"
mark_ws "$F/gws3"; commit_all "$F/gws3" root
mkrepo "$F/gws3/member-a" "a.txt" "fine"; mkrepo "$F/gws3/member-b" "b.txt" "fine"
G3="$( cd "$F/gws3" && bash "$SEC" 2>&1 )"; G3RC=$?
chk "marked git root, all clean: passes"                      "[ $G3RC -eq 0 ]"
chk "marked git root, all clean: counts 3 units (2 members + the root)" \
  "printf '%s' \"\$G3\" | grep -q 'clean across 3 repo(s)'"
G3S="$( cd "$F/gws3" && bash "$STR" 2>&1 )"; G3SRC=$?
chk "scan-structure covers the marked git root the same way" \
  "[ $G3SRC -eq 0 ] && printf '%s' \"\$G3S\" | grep -q 'clean across 3 repo(s)'"

# SCOPE FORK — the ROOT's own pre-commit must NOT fan out. `--staged` there is the ROOT's commit
# being scored; fanning out would block a root commit because a NEIGHBOUR has a secret staged
# (the mirror of the member-scoping bug the .kickoff/bin shims already fixed).
printf '%s\n' "$LEAK" > "$F/gws3/member-a/staged-leak.js"
( cd "$F/gws3/member-a" && git add staged-leak.js ) >/dev/null 2>&1
G3ST="$( cd "$F/gws3" && bash "$SEC" --staged 2>&1 )"; G3STRC=$?
chk "marked git root, --staged: does NOT fan out (the root scores its own index only)" \
  "! printf '%s' \"\$G3ST\" | grep -q 'workspace mode'"
chk "…so a neighbour's STAGED secret does not block the root's own commit" "[ $G3STRC -eq 0 ]"
( cd "$F/gws3/member-a" && git reset -q >/dev/null 2>&1; rm -f staged-leak.js )
# NEGATIVE CONTROL: the root's own staged secret still blocks it — the fork did not go blind.
printf '%s\n' "$LEAK" > "$F/gws3/root-leak.js"; ( cd "$F/gws3" && git add root-leak.js ) >/dev/null 2>&1
( cd "$F/gws3" && bash "$SEC" --staged >/dev/null 2>&1 )
chk "NEGATIVE CONTROL: the ROOT's own staged secret still fails --staged at the root" "[ $? -ne 0 ]"
( cd "$F/gws3" && git reset -q >/dev/null 2>&1; rm -f root-leak.js )

# ══════════════════════════════════════════════════════════════════════════════════
echo
echo "10. .git AS A FILE — a submodule is a member; a worktree and a separate-git-dir are NOT"
# ══════════════════════════════════════════════════════════════════════════════════
# MEASURED, not assumed: in a submodule `.git` is a FILE reading `gitdir: ../.git/modules/<n>`, so
# `[ -d "$d/.git" ]` is FALSE and the member never existed. A planted AWS key inside one produced
# "no secrets found", rc 0 — a silent false green. But `.git`-as-a-FILE has THREE shapes and only
# one is a member, so a naive relaxation to `[ -e ]` swaps one bug for two.
SUBSRC="$F/subsrc"; mkrepo "$SUBSRC" "lib.js" "$LEAK"        # the secret lives in the submodule
mkrepo "$F/sws" "README.md" "org"; mark_ws "$F/sws"
( cd "$F/sws" && $GC -c protocol.file.allow=always submodule add -q "$SUBSRC" sub >/dev/null 2>&1 )
commit_all "$F/sws" addsub
chk "fixture: the submodule's .git is a FILE, not a directory (or the case measures nothing)" \
  "[ -f \"$F/sws/sub/.git\" ] && [ ! -d \"$F/sws/sub/.git\" ]"
chk "fixture: and it names the modules path git actually uses" \
  "grep -q 'gitdir:.*modules/sub' \"$F/sws/sub/.git\""
SOUT="$( cd "$F/sws" && bash "$SEC" 2>&1 )"; SRC=$?
chk "submodule: counted as a member (the dir-only test missed it entirely)" \
  "printf '%s' \"\$SOUT\" | grep -q '── sub'"
chk "submodule: its planted secret FAILS the run (this was a silent green, rc 0)" \
  "[ $SRC -ne 0 ] && printf '%s' \"\$SOUT\" | grep -q 'FAILED in: sub'"
chk "submodule: the finding itself is reported, not just a red exit" \
  "printf '%s' \"\$SOUT\" | grep -q 'AWS access key id'"

# A LINKED WORKTREE also has `.git` as a FILE — `gitdir: …/.git/worktrees/<n>`. It is NOT a member:
# it is another checkout of a repo already covered, and its hooks live outside it (which is why a
# prior release deliberately stopped arming worktrees). This is the assertion a naive `-e` breaks.
WMAIN="$F/wws/main"; mkdir -p "$F/wws"; mkrepo "$WMAIN" "a.txt" "fine"
git -C "$WMAIN" worktree add -q "$F/wws/linked" >/dev/null 2>&1
printf '%s\n' "$LEAK" > "$F/wws/linked/wt-leak.js"
( cd "$F/wws/linked" && git add wt-leak.js >/dev/null 2>&1 && $GC commit -qm wt >/dev/null 2>&1 )
chk "fixture: the linked worktree's .git is a FILE naming a worktrees/ path" \
  "[ -f \"$F/wws/linked/.git\" ] && grep -q 'gitdir:.*worktrees/' \"$F/wws/linked/.git\""
WOUT="$( cd "$F/wws" && bash "$SEC" 2>&1 )"
chk "linked worktree: NOT counted as a member (only the main checkout is)" \
  "printf '%s' \"\$WOUT\" | grep -q '1 repo(s)' && ! printf '%s' \"\$WOUT\" | grep -q '── linked'"

# THE THIRD SHAPE: `git init --separate-git-dir` also writes a `.git` FILE, pointing at an
# arbitrary directory that is neither `/modules/` nor `/worktrees/`. Nothing marks it as part of
# this workspace, so a "not-a-worktree ⇒ member" rule would silently promote it.
mkdir -p "$F/dws/loose" "$F/dws/elsewhere"; mkrepo "$F/dws/real" "a.txt" "fine"
git -c init.defaultBranch=main init -q --separate-git-dir "$F/dws-gitdir" "$F/dws/loose" >/dev/null 2>&1
chk "fixture: the separate-git-dir child's .git file points OUTSIDE both modules/ and worktrees/" \
  "[ -f \"$F/dws/loose/.git\" ] && ! grep -qE 'modules/|worktrees/' \"$F/dws/loose/.git\""
DOUT="$( cd "$F/dws" && bash "$SEC" 2>&1 )"
chk "separate-git-dir child: NOT promoted to a member" \
  "printf '%s' \"\$DOUT\" | grep -q '1 repo(s)' && ! printf '%s' \"\$DOUT\" | grep -q '── loose'"

# ══════════════════════════════════════════════════════════════════════════════════
echo
echo "11. NO MARKER ⇒ BYTE-IDENTICAL. Five live adopters depend on this"
# ══════════════════════════════════════════════════════════════════════════════════
# The pre-existing nested-checkout case asserted only the ABSENCE of a log string. For a
# byte-identical claim it has to assert on the CONSUMING ARTIFACT: the finding list and the exit
# code. A single repo containing a child repo whose file holds a secret must behave exactly as it
# does today — the child is a gitlink/untracked to the outer repo, so the run is CLEAN.
mkrepo "$F/nomark" "a.txt" "fine"
mkrepo "$F/nomark/child" "leak.js" "$LEAK"
NM="$( cd "$F/nomark" && bash "$SEC" 2>&1 )"; NMRC=$?
chk "no marker + nested child repo: still single-repo (no fan-out)" \
  "! printf '%s' \"\$NM\" | grep -q 'workspace mode'"
chk "no marker + nested child repo: rc 0 — the child is NOT scanned (today's behaviour, unchanged)" \
  "[ $NMRC -eq 0 ] && printf '%s' \"\$NM\" | grep -q 'no secrets found'"
# …and the same for a SUBMODULE child under an UNMARKED git root, and a WORKTREE child.
mkrepo "$F/nomark2" "a.txt" "fine"
( cd "$F/nomark2" && $GC -c protocol.file.allow=always submodule add -q "$SUBSRC" sub >/dev/null 2>&1 )
commit_all "$F/nomark2" addsub
NM2="$( cd "$F/nomark2" && bash "$SEC" 2>&1 )"; NM2RC=$?
chk "no marker + a SUBMODULE child: still single-repo, rc 0 (unchanged — the marker is the switch)" \
  "[ $NM2RC -eq 0 ] && ! printf '%s' \"\$NM2\" | grep -q 'workspace mode'"
mkrepo "$F/nomark3" "a.txt" "fine"
git -C "$F/nomark3" worktree add -q "$F/nomark3/wt" >/dev/null 2>&1
NM3="$( cd "$F/nomark3" && bash "$SEC" 2>&1 )"; NM3RC=$?
chk "no marker + a linked-WORKTREE child: still single-repo, rc 0" \
  "[ $NM3RC -eq 0 ] && ! printf '%s' \"\$NM3\" | grep -q 'workspace mode'"
# A MARKED root that is NOT a git repo is the classic workspace and must be unchanged by the marker.
mkrepo "$F/markednongit/one" "a.txt" "fine"; mkrepo "$F/markednongit/two" "b.txt" "fine"
mark_ws "$F/markednongit"
MNG="$( cd "$F/markednongit" && bash "$SEC" 2>&1 )"; MNGRC=$?
chk "marked NON-git root: unchanged — fan-out over 2 members, no root unit to add" \
  "[ $MNGRC -eq 0 ] && printf '%s' \"\$MNG\" | grep -q 'clean across 2 repo(s)'"
# And the misconfiguration is NAMED, never a silent pass: a marker over zero members.
mkrepo "$F/markedempty" "a.txt" "fine"; mark_ws "$F/markedempty"
ME="$( cd "$F/markedempty" && bash "$SEC" 2>&1 )"; MERC=$?
chk "marker + ZERO members: says so out loud instead of passing in silence" \
  "printf '%s' \"\$ME\" | grep -q 'ZERO member repos'"
chk "…and still scans the root itself (rc 0 on a clean root)" "[ $MERC -eq 0 ]"

# ══════════════════════════════════════════════════════════════════════════════════
echo
echo "12. THE ROOT'S OWN FILES — 'tracked' is the question, not 'is the toplevel'"
# ══════════════════════════════════════════════════════════════════════════════════
# THE REGRESSION THIS SECTION EXISTS FOR (adversarial review, blocker). `_ws_scan_root` was set
# only when `git rev-parse --show-toplevel` EQUALLED pwd. A workspace root NESTED inside another
# work tree — an org folder inside a dotfiles repo or a monorepo, which is also exactly what
# `kickoff adopt` used to produce there — is fully TRACKED by that enclosing repo but is not a
# toplevel. So it was neither a unit of the fan-out nor covered by anything else: a committed AWS
# key in the org's own CLAUDE.md scanned RED before this feature and GREEN after it, rc 0. The
# marker turned a red into a green. Section 9 could not see it — its fixture is a toplevel.
mkrepo "$F/outer" "a.txt" "fine"
mkdir -p "$F/outer/org/.kickoff" "$F/outer/org/.claude/agents"
mark_ws "$F/outer/org"
printf '%s\n' "$LEAK" > "$F/outer/org/.claude/agents/deployer.md"   # the ORG's own crew file
printf 'org/alpha/\norg/beta/\n' > "$F/outer/.gitignore"
mkrepo "$F/outer/org/alpha" "a.txt" "fine"
mkrepo "$F/outer/org/beta"  "b.txt" "fine"
commit_all "$F/outer" org
chk "fixture: the nested root is NOT a toplevel but IS inside a work tree (or this measures nothing)" \
  "[ \"\$(cd \"$F/outer/org\" && git rev-parse --show-toplevel)\" != \"\$(cd \"$F/outer/org\" && pwd -P)\" ] && ( cd \"$F/outer/org\" && git rev-parse --is-inside-work-tree )"
chk "fixture: and the planted secret really is TRACKED by the enclosing repo" \
  "git -C \"$F/outer\" ls-files | grep -q 'org/.claude/agents/deployer.md'"
NST="$( cd "$F/outer/org" && bash "$SEC" 2>&1 )"; NSTRC=$?
chk "nested marked root: a secret in the ROOT's own tracked file FAILS the run (was rc 0, 'workspace clean')" \
  "[ $NSTRC -ne 0 ]"
chk "…and the root is NAMED as the failing unit"       "printf '%s' \"\$NST\" | grep -q 'FAILED in: (this root)'"
chk "…and the finding itself points at the org's crew file" \
  "printf '%s' \"\$NST\" | grep -q '.claude/agents/deployer.md'"
chk "…and it says WHERE the root's files are tracked, rather than implying it has none" \
  "printf '%s' \"\$NST\" | grep -q \"tracked by the git repo at $F/outer\""
# THE ISOLATION CONTROL, and the whole point: the marker must never flip a RED to a GREEN. Same
# tree, same planted secret, only the marker moves.
mv "$F/outer/org/.kickoff/workspace" "$F/outer/org/.kickoff/workspace.off"
( cd "$F/outer/org" && bash "$SEC" >/dev/null 2>&1 ); NOMK=$?
mv "$F/outer/org/.kickoff/workspace.off" "$F/outer/org/.kickoff/workspace"
chk "CONTROL: the same file is RED with the marker REMOVED too (the marker changes coverage, never the verdict)" \
  "[ $NOMK -ne 0 ]"
# scan-structure takes the same path — a HIGH finding in the nested root's own tracked file.
python3 -c "open('$F/outer/org/big.ts','w').write('// x\n'*900)"
commit_all "$F/outer" big
( cd "$F/outer/org" && bash "$STR" --strict >/dev/null 2>&1 ); NSTS=$?
chk "scan-structure: the nested root's own tracked files are scanned too (--strict blocks, rc=$NSTS)" \
  "[ $NSTS -ne 0 ]"

# ══════════════════════════════════════════════════════════════════════════════════
echo
echo "13. FAIL-CLOSED MUST NOT DEPEND ON THE ROOT'S SHAPE"
# ══════════════════════════════════════════════════════════════════════════════════
# The unreadable-member guard lived INSIDE `if members > 0`. At a marked GIT root whose ONLY
# candidate member is unreadable, zero members enumerate — so the guard never ran, the directory
# was never named, and the run fell through to the plain root scan and exited 0. The same single
# unreadable member at a NON-git root fails closed. A gate whose fail-closed depends on which
# root shape you have is not fail-closed.
mkrepo "$F/hidroot" "README.md" "org"; printf 'hidden/\n' > "$F/hidroot/.gitignore"
mark_ws "$F/hidroot"; commit_all "$F/hidroot" root
mkrepo "$F/hidroot/hidden" "leak.js" "$LEAK"
chmod 000 "$F/hidroot/hidden"
HID="$( cd "$F/hidroot" && bash "$SEC" 2>&1 )"; HIDRC=$?
HIDS="$( cd "$F/hidroot" && bash "$STR" --strict 2>&1 )"; HIDSRC=$?
chmod 755 "$F/hidroot/hidden" 2>/dev/null
chk "marked GIT root, ONLY member unreadable: scan-secrets FAILS (was rc 0 + 'no secrets found')" \
  "[ $HIDRC -ne 0 ]"
chk "…and names the directory it could not open"  "printf '%s' \"\$HID\" | grep -q 'unreadable director'"
chk "…and never claims a clean sweep"             "! printf '%s' \"\$HID\" | grep -q 'clean across'"
chk "marked GIT root, ONLY member unreadable: scan-structure FAILS too (rc=$HIDSRC)" "[ $HIDSRC -ne 0 ]"
# NEGATIVE CONTROL: readable again, nothing to hide → the same fixture passes. The guard did not
# simply learn to fail.
mkrepo "$F/okroot" "README.md" "org"; printf 'plain/\n' > "$F/okroot/.gitignore"
mark_ws "$F/okroot"; commit_all "$F/okroot" root
mkrepo "$F/okroot/plain" "a.txt" "fine"
( cd "$F/okroot" && bash "$SEC" >/dev/null 2>&1 ); chk "NEGATIVE CONTROL: the same shape, readable + clean, still passes" "[ $? -eq 0 ]"

# AN UNREADABLE `.git` FILE is the same fail-open one level down: since a submodule became a
# member, membership can require READING `$d/.git`, and a failed read fell through to the
# catch-all "not a member" — the member vanished and the aggregate counted one repo fewer, green.
SUB2="$F/subsrc2"; mkrepo "$SUB2" "lib.js" "$LEAK"
mkrepo "$F/gsub" "README.md" "org"; mark_ws "$F/gsub"
( cd "$F/gsub" && $GC -c protocol.file.allow=always submodule add -q "$SUB2" sub >/dev/null 2>&1 )
commit_all "$F/gsub" addsub
mkrepo "$F/gsub/plain" "a.txt" "fine"
GS0="$( cd "$F/gsub" && bash "$SEC" 2>&1 )"; GS0RC=$?
chk "fixture: with .git readable the submodule's secret IS caught (or the next case proves nothing)" \
  "[ $GS0RC -ne 0 ] && printf '%s' \"\$GS0\" | grep -q 'FAILED in: sub'"
chmod 000 "$F/gsub/sub/.git"
GS1="$( cd "$F/gsub" && bash "$SEC" 2>&1 )"; GS1RC=$?
chmod 644 "$F/gsub/sub/.git" 2>/dev/null
chk "an UNREADABLE .git file is reported as indeterminate, not silently dropped (was rc 0, 'clean across 2')" \
  "[ $GS1RC -ne 0 ] && printf '%s' \"\$GS1\" | grep -q 'sub'"

echo
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
