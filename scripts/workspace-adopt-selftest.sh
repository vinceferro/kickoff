#!/usr/bin/env bash
# workspace-adopt-selftest.sh — prove `kickoff adopt` GATES a multi-repo ROOT, and that every
# "gated" it prints is true of the world.
#
#   bash scripts/workspace-adopt-selftest.sh
#
# WHY THIS EXISTS. kickoff can be mounted on a ROOT folder holding N sibling checkouts. `kickoff
# adopt` there returned 0, wrote lefthook.yml + .kickoff/ at the root, and armed ZERO hooks — the
# root is not a git repo, so there was nothing there to arm — while reporting success. Every commit
# in every member stayed ungated behind a green summary.
#
# THE FIRST FIX FOR IT WAS HELD BY ADVERSARIAL REVIEW, which found SIX ways it printed "gated" over
# a repo where a planted secret then committed cleanly. Those six are this suite's spine:
#   1. it resolved hooks with `--git-common-dir`, which IGNORES core.hooksPath (a global one made
#      every member falsely green),
#   2. it mapped UNVERIFIABLE to gated (a repo cloned after adoption has no hooks at all — git does
#      not clone .git/hooks — and was reported protected),
#   3. it treated any pre-commit CONTAINING the substring "lefthook" as gated, comments included,
#   4. it could exit 0 with git repos under the root and none of them gated,
#   5. it wrote into repos outside the workspace that eject could not reverse,
#   6. it replaced hooks the adopter owned.
#
# SO: EVERY CLAIM HERE IS ASSERTED ON THE CONSUMING ARTIFACT — a real `git commit`, in a real
# checkout, through the real hook. "adopt recorded a hook" proves nothing; the property is that a
# commit carrying a secret is REFUSED in that member and a clean one SUCCEEDS. Both directions,
# every time — a member whose gate is BRICKED (a root-relative command resolving to exit 127 in the
# member) also refuses the secret commit, so the refusal is additionally required to come from the
# SCANNER, and the success is required to show the hook actually ran.
#
# THE FIXTURE IS THE DEPLOY TOPOLOGY: a real root directory holding real checkouts, adopted by the
# real front door. Members are named so the NOT-gated ones sort FIRST — a loop that gave up on the
# first ungated member would then leave the later ones unarmed, which the per-member commit tests
# see. (Three times in one night last week a fixture put its payload where the code never looks.)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
KO="$REPO/scripts/kickoff"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

for t in git python3; do command -v "$t" >/dev/null 2>&1 || { printf '  ❌ %s not found\n' "$t"; exit 1; }; done

# The gate is right to flag this — it is a credential-shaped literal — and the sanctioned way to
# plant one deliberately is to say so on the line, not to widen the pattern.
LEAK='const k = "AKIAIOSFODNN7EXAMPLE";'  # pragma: allowlist secret

echo "▶ workspace adopt self-test — a gate that reports ARMED must REFUSE a real secret commit"
echo

F="$(mktemp -d)"; trap 'chmod -R u+rwX "$F" 2>/dev/null; rm -rf "$F"' EXIT
n=0; mk() { n=$((n+1)); mkdir -p "$F/d$n"; printf '%s' "$F/d$n"; }
GIT="git -c user.email=t@t -c user.name=t"

mkrepo() {                      # mkrepo <path>  → a real checkout with one commit
  mkdir -p "$1"; git -c init.defaultBranch=main init -q "$1"
  printf '# repo\n' > "$1/README.md"
  ( cd "$1" && git add -A >/dev/null 2>&1 && $GIT commit -qm baseline >/dev/null 2>&1 )
}

# ── 0. a hermetic fixture CORE + a stub `claude` (the box has a real one; never touch it) ───────
CORE="$(mk)"; mkdir -p "$CORE/scripts" "$CORE/plugin/.claude-plugin"
cp "$REPO/scripts/kickoff" "$REPO/scripts/adopt-manifest.py" "$REPO/scripts/instance.env.example" \
   "$REPO/scripts/scan-secrets.sh" "$REPO/scripts/scan-structure.sh" "$CORE/scripts/"
cp -r "$REPO/scripts/templates" "$CORE/scripts/templates"
printf '{ "name": "kickoff", "version": "0.0.1", "description": "min core", "author": {"name":"k"} }\n' \
  > "$CORE/plugin/.claude-plugin/plugin.json"
printf '{ "name": "kickoff-local", "description": "min mkt", "owner": {"name":"k"}, "plugins": [ {"name":"kickoff","source":"./","description":"x"} ] }\n' \
  > "$CORE/plugin/.claude-plugin/marketplace.json"
git -C "$CORE" init -q; git -C "$CORE" add -A >/dev/null 2>&1
$GIT -C "$CORE" commit -qm core >/dev/null 2>&1; git -C "$CORE" tag -f core-vT >/dev/null 2>&1
STUB="$(mk)"; printf '#!/bin/sh\nexit 0\n' > "$STUB/claude"; chmod +x "$STUB/claude"
CFG="$(mk)"; REG="$(mk)/adopters.json"; CHAN="$(mk)"

ADOPT_OUT=""; ADOPT_RC=0
run_adopt() {                   # run_adopt <target> [extra VAR=value…]
  local tgt="$1"; shift
  ADOPT_RC=0
  ADOPT_OUT="$(env "$@" REPO_DIR="$tgt" TELEGRAM_STATE_DIR="$CHAN" KICKOFF_ADOPTERS_REGISTRY="$REG" \
       KICKOFF_CORE_DIR="$CORE" CLAUDE_CONFIG_DIR="$CFG" PATH="$STUB:$PATH" \
       bash "$KO" adopt --dir "$tgt" --accept </dev/null 2>&1)" || ADOPT_RC=$?
}
run_doctor() {                  # run_doctor <target> [extra kickoff flags…]
  local tgt="$1"; shift
  env REPO_DIR="$tgt" TELEGRAM_STATE_DIR="$CHAN" KICKOFF_ADOPTERS_REGISTRY="$REG" \
      KICKOFF_CORE_DIR="$CORE" CLAUDE_CONFIG_DIR="$CFG" PATH="$STUB:$PATH" \
      bash "$KO" doctor --dir "$tgt" "$@" </dev/null 2>&1
}
run_adopt_flags() {             # run_adopt_flags <target> [extra kickoff flags…]
  local tgt="$1"; shift
  ADOPT_RC=0
  ADOPT_OUT="$(env REPO_DIR="$tgt" TELEGRAM_STATE_DIR="$CHAN" KICKOFF_ADOPTERS_REGISTRY="$REG" \
       KICKOFF_CORE_DIR="$CORE" CLAUDE_CONFIG_DIR="$CFG" PATH="$STUB:$PATH" \
       bash "$KO" adopt --dir "$tgt" --accept "$@" </dev/null 2>&1)" || ADOPT_RC=$?
}
run_verify() {                  # run_verify <target> → its output (verify exits non-zero freely)
  env REPO_DIR="$1" TELEGRAM_STATE_DIR="$CHAN" KICKOFF_ADOPTERS_REGISTRY="$REG" \
      KICKOFF_CORE_DIR="$CORE" CLAUDE_CONFIG_DIR="$CFG" PATH="$STUB:$PATH" \
      bash "$KO" verify --dir "$1" </dev/null 2>&1
}

# THE TWO CONSUMING-ARTIFACT PROBES. Both capture the commit's own output, because the exit code
# alone cannot tell a working gate from a broken one:
#   • a refusal must come from the SCANNER (a bricked hook exits 127 and also refuses),
#   • a success must show the hook RAN (a repo with no hook at all commits cleanly too).
COMMIT_OUT=""
try_commit() {                  # try_commit <repo> <file> <content> → rc, sets COMMIT_OUT
  local rc=0
  printf '%s\n' "$3" > "$1/$2"
  ( cd "$1" && git add "$2" ) >/dev/null 2>&1
  COMMIT_OUT="$( cd "$1" && $GIT commit -m "probe $2" 2>&1 )" || rc=$?
  return $rc
}
unstage() { ( cd "$1" && git reset -q >/dev/null 2>&1; rm -f "$1/$2" ); }

secret_is_refused() {           # secret_is_refused <repo> <label>
  if try_commit "$1" "leak.js" "$LEAK"; then
    bad "$2: a commit carrying a secret was ACCEPTED — this repo is NOT gated"
  elif printf '%s' "$COMMIT_OUT" | grep -qiE 'secret|AWS access key'; then
    ok "$2: a commit carrying a secret is REFUSED by the secret scan"
  else
    bad "$2: the commit failed, but NOT from the scanner (a bricked hook refuses too): ${COMMIT_OUT##*$'\n'}"
  fi
  unstage "$1" "leak.js"
}
clean_is_accepted() {           # clean_is_accepted <repo> <label>
  if ! try_commit "$1" "clean-$RANDOM.txt" "nothing to see"; then
    bad "$2: a CLEAN commit was refused — the member's gate is broken, not gating: ${COMMIT_OUT##*$'\n'}"
  elif printf '%s' "$COMMIT_OUT" | grep -q 'gate(s) from lefthook.yml'; then
    ok "$2: a clean commit SUCCEEDS, and the output proves the gate actually ran"
  else
    bad "$2: the clean commit passed but no gate ran (a commit through no hook also passes)"
  fi
}

# The gate VERDICT is read straight out of the engine, so the reporting claims below are tested on
# the real code rather than on a paraphrase of it.
VDRV="$F/verdict.sh"
{ printf 'set -uo pipefail\n'
  sed -n '/^_gate_hooks_dir() {/,/^}/p' "$KO"
  sed -n '/^_gate_hook_invokes() {/,/^}/p' "$KO"
  sed -n '/^_gate_verdict() {/,/^}/p' "$KO"
  printf '_gate_verdict "$1"\n'
} > "$VDRV"
verdict() { bash "$VDRV" "$1" 2>/dev/null; }
IDRV="$F/invokes.sh"
{ printf 'set -uo pipefail\n'
  sed -n '/^_gate_hook_invokes() {/,/^}/p' "$KO"
  printf '_gate_hook_invokes "$1"\n'
} > "$IDRV"
invokes() { bash "$IDRV" "$1" >/dev/null 2>&1; }
chk "harness: the verdict driver really carries the engine's own functions (not an empty file)" \
  "grep -q '_gate_verdict()' \"$VDRV\" && grep -q 'git-path hooks' \"$VDRV\""
chk "harness: the invocation driver carries the real detector" "grep -q '_gate_hook_invokes()' \"$IDRV\""

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo "1. THE ACCEPTANCE PROPERTY — every member gates a real commit, in both directions"
# ══════════════════════════════════════════════════════════════════════════════════════════════
# Member names sort so that the two NOT-gated ones come FIRST: a loop that stopped at the first
# member it could not arm would leave every later member unarmed, and their commit probes see it.
WS="$F/ws"; mkdir -p "$WS"
mkrepo "$WS/aaa-comment-hook"      # defect 3 — its pre-commit only MENTIONS lefthook, in a comment
mkrepo "$WS/bbb-own-lefthook"      # defect 6 — a real lefthook invocation the adopter owns
mkrepo "$WS/ccc-plain"
mkrepo "$WS/ddd-husky"             # defect 1 — core.hooksPath
mkrepo "$WS/eee-plain"             # defect 2 — hooks removed after adoption
mkrepo "$WS/fff-own-extends"       # its lefthook.yml has its OWN extends: → the wire is DEFERRED
printf 'extends:\n  - my-gates.yml\n' > "$WS/fff-own-extends/lefthook.yml"
printf 'pre-push:\n  commands:\n    mine:\n      run: echo mine\n' > "$WS/fff-own-extends/my-gates.yml"
mkdir -p "$WS/notes"               # a plain dir: not a member, never gated, never counted
OUTSIDER="$F/outsider"; mkrepo "$OUTSIDER"   # defect 5 — a repo OUTSIDE the root, must stay untouched

# the adopter's OWN hooks (byte-recorded now, compared after adopt)
cat > "$WS/aaa-comment-hook/.git/hooks/pre-commit" <<'H'
#!/bin/sh
# we migrated away from lefthook in 2024
exit 0
H
cat > "$WS/bbb-own-lefthook/.git/hooks/pre-commit" <<'H'
#!/bin/sh
exec lefthook run pre-commit "$@"
H
chmod +x "$WS/aaa-comment-hook/.git/hooks/pre-commit" "$WS/bbb-own-lefthook/.git/hooks/pre-commit"
SHA_AAA="$(sha256sum "$WS/aaa-comment-hook/.git/hooks/pre-commit" | cut -d' ' -f1)"
SHA_BBB="$(sha256sum "$WS/bbb-own-lefthook/.git/hooks/pre-commit" | cut -d' ' -f1)"
git -C "$WS/ddd-husky" config core.hooksPath .husky
# confirm the fixture reaches the path it is meant to test, BEFORE relying on it
chk "fixture: ddd-husky really has core.hooksPath set (git answers .husky, not .git/hooks)" \
  "[ \"\$(cd \"$WS/ddd-husky\" && git rev-parse --git-path hooks)\" = '.husky' ]"

run_adopt "$WS"; WS_OUT="$ADOPT_OUT"      # later sections re-read THIS run, not the newest one
chk "adopt on a multi-repo root exits 0 when members ARE gated (rc=$ADOPT_RC)" "[ $ADOPT_RC -eq 0 ]"
chk "adopt says the gates go on the MEMBERS (the root has no hooks to arm)" \
  "printf '%s' \"\$WS_OUT\" | grep -q 'the gates go on the MEMBERS'"
chk "adopt counts 4 of 6 member repos gated (owned hooks: one gated, one not; one deferred config)" \
  "printf '%s' \"\$WS_OUT\" | grep -q '4 of 6 member repo(s) gated'"
chk "a plain directory under the root is never treated as a member" \
  "! printf '%s' \"\$WS_OUT\" | grep -q 'member: notes'"

# ARMED-BUT-INERT is not gated. A member whose lefthook.yml already has its OWN `extends:` key is
# DEFERRED (a bash tool must not merge YAML lists), so its armed hook resolves ZERO gates, prints a
# warning and exits 0. Counting that as gated is the same false green in a new place.
chk "a member whose config was DEFERRED is left byte-untouched (no YAML merged by a bash tool)" \
  "grep -q 'my-gates.yml' \"$WS/fff-own-extends/lefthook.yml\" && ! grep -q 'lefthook-member' \"$WS/fff-own-extends/lefthook.yml\""
chk "…and is NOT counted gated — its hook resolves to zero gates" \
  "printf '%s' \"\$WS_OUT\" | grep -q 'fff-own-extends (armed-but-no-gates'"
if try_commit "$WS/fff-own-extends" "leak.js" "$LEAK"; then
  ok "…and the world agrees: the secret commits there, so 'gated' would have been a lie"
else
  bad "…the secret commit was refused, so this member IS gated and the report is wrong"
fi
unstage "$WS/fff-own-extends" "leak.js"

# THE POINT OF THE WHOLE EXERCISE — real commits, real hooks, both directions.
for m in ccc-plain ddd-husky eee-plain; do
  secret_is_refused "$WS/$m" "$m"
  clean_is_accepted "$WS/$m" "$m"
done
# …and MEMBER-SCOPED, not a whole-workspace fan-out: with ccc-plain holding a STAGED secret, a
# clean commit in ddd-husky must still pass. The root shim cd's to the root, where a fan-out would
# score this member's commit on its neighbour's index.
printf '%s\n' "$LEAK" > "$WS/ccc-plain/leak.js"; ( cd "$WS/ccc-plain" && git add leak.js ) >/dev/null 2>&1
clean_is_accepted "$WS/ddd-husky" "member scoping (a neighbour holds a staged secret)"
unstage "$WS/ccc-plain" "leak.js"

# IDEMPOTENCE — the manifest is append-only, so a re-adopt that re-records is a double receipt, and
# a re-adopt that rewrites a member's lefthook.yml is a clobber.
CCC_SHA="$(sha256sum "$WS/ccc-plain/lefthook.yml" | cut -d' ' -f1)"
run_adopt "$WS"
chk "re-adopt: still exactly ONE manifest entry per member path (no duplicate receipts)" \
  "python3 -c \"import json;es=json.load(open('$WS/.kickoff/adopt-manifest.json'))['entries'];ps=[e['path'] for e in es];assert ps.count('ccc-plain/lefthook.yml')==1 and ps.count('ccc-plain/.git/hooks/pre-commit')==1 and ps.count('.kickoff/lefthook-member.yml')==1, ps\""
chk "re-adopt: the member's lefthook.yml is byte-identical (never clobbered)" \
  "[ \"\$(sha256sum \"$WS/ccc-plain/lefthook.yml\" | cut -d' ' -f1)\" = \"$CCC_SHA\" ]"
chk "re-adopt: still exits 0 and still reports the members gated" \
  "[ $ADOPT_RC -eq 0 ] && printf '%s' \"\$ADOPT_OUT\" | grep -q 'already ARMED'"
secret_is_refused "$WS/ccc-plain" "ccc-plain after a re-adopt"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "2. DEFECT 1 — core.hooksPath. \`--git-common-dir\` ignores it; only \`--git-path hooks\` sees it"
# ══════════════════════════════════════════════════════════════════════════════════════════════
chk "ddd-husky: the hook was installed where git ACTUALLY looks (.husky/, not .git/hooks/)" \
  "[ -x \"$WS/ddd-husky/.husky/pre-commit\" ]"
chk "ddd-husky: nothing was written to the dead .git/hooks/pre-commit" \
  "[ ! -e \"$WS/ddd-husky/.git/hooks/pre-commit\" ]"
chk "ddd-husky: the runner sits beside the hook that execs it" \
  "[ -x \"$WS/ddd-husky/.husky/_kickoff-hook-runner\" ]"
chk "ddd-husky: the touch is recorded under the MEMBER's hooksPath, so eject reverses it" \
  "python3 -c \"import json;ps={x['path'] for x in json.load(open('$WS/.kickoff/adopt-manifest.json'))['entries']};assert 'ddd-husky/.husky/pre-commit' in ps\""
# (the real proof — a secret commit in ddd-husky is refused — ran in §1 above)

# A GLOBAL core.hooksPath is the one that made every member falsely green at once.
GWS="$F/ws-globalhooks"; mkdir -p "$GWS"; mkrepo "$GWS/one"; mkrepo "$GWS/two"
GH="$F/global-hooks"; mkdir -p "$GH"
GCFG="$F/gitconfig-global"; printf '[core]\n\thooksPath = %s\n' "$GH" > "$GCFG"
chk "fixture: the global core.hooksPath really applies (git answers the global dir)" \
  "[ \"\$(cd \"$GWS/one\" && GIT_CONFIG_GLOBAL=$GCFG git rev-parse --git-path hooks)\" = '$GH' ]"
run_adopt "$GWS" GIT_CONFIG_GLOBAL="$GCFG"
chk "global core.hooksPath: adopt NEVER reports those members gated" \
  "! printf '%s' \"\$ADOPT_OUT\" | grep -q '2 of 2 member repo(s) GATED'"
chk "global core.hooksPath: adopt names the refusal (hooks resolve OUTSIDE the repo)" \
  "printf '%s' \"\$ADOPT_OUT\" | grep -q 'OUTSIDE'"
chk "global core.hooksPath: adopt exits NON-ZERO (nothing under this root is gated; rc=$ADOPT_RC)" \
  "[ $ADOPT_RC -ne 0 ]"
chk "global core.hooksPath: NOTHING was written into the shared global hooks dir (defect 5)" \
  "[ -z \"\$(ls -A \"$GH\" 2>/dev/null)\" ]"
# and the world matches the report: those members really are ungated.
if try_commit "$GWS/one" "leak.js" "$LEAK"; then
  ok "global core.hooksPath: the report matches the world (the commit is NOT gated — and adopt said so)"
else
  bad "global core.hooksPath: the commit was refused, so the honest report should have been 'gated'"
fi
unstage "$GWS/one" "leak.js"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "3. DEFECT 2 — UNVERIFIABLE never maps to gated, anywhere"
# ══════════════════════════════════════════════════════════════════════════════════════════════
chk "verdict: a plain armed member reads 'gated' (positive control — the probe can say yes)" \
  "[ \"\$(verdict \"$WS/ccc-plain\")\" = gated ]"
chk "verdict: a hooksPath member reads 'gated' too" "[ \"\$(verdict \"$WS/ddd-husky\")\" = gated ]"
chk "verdict: a SUBDIRECTORY of a repo is 'unverifiable', never gated" \
  "mkdir -p \"$WS/ccc-plain/sub\" && [ \"\$(verdict \"$WS/ccc-plain/sub\")\" = unverifiable ]"
chk "verdict: a repo whose hooks dir is OUTSIDE it is 'unverifiable', never gated" \
  "[ \"\$(env GIT_CONFIG_GLOBAL=$GCFG bash \"$VDRV\" \"$GWS/one\" 2>/dev/null)\" = unverifiable ]"
chk "verdict: a non-repo directory is 'unverifiable', never gated" \
  "[ \"\$(verdict \"$WS/notes\")\" = unverifiable ]"
# THE HISTORY: a repo CLONED after its own adoption carries lefthook.yml but NO hooks (git does not
# clone .git/hooks). The previous attempt called that gated. It is ungated, and the world agrees.
rm -f "$WS/eee-plain/.git/hooks/pre-commit" "$WS/eee-plain/.git/hooks/pre-push" \
      "$WS/eee-plain/.git/hooks/_kickoff-hook-runner"
chk "verdict: hooks removed after adoption (the cloned-repo shape) reads 'ungated', NOT gated" \
  "[ \"\$(verdict \"$WS/eee-plain\")\" = ungated ]"
if try_commit "$WS/eee-plain" "leak.js" "$LEAK"; then
  ok "…and the world agrees: with the hooks gone, the secret really does commit (so 'gated' would be a lie)"
else
  bad "…the secret commit was still refused — the fixture did not actually remove the hooks"
fi
unstage "$WS/eee-plain" "leak.js"
DOC_OUT="$(run_doctor "$WS")"
chk "doctor back-fills the de-armed member (it is the documented recovery)" \
  "printf '%s' \"\$DOC_OUT\" | grep -q 'eee-plain'"
secret_is_refused "$WS/eee-plain" "eee-plain after \`kickoff doctor\`"
# A NON-EXECUTABLE hook is one git silently skips — inert, therefore not a gate.
mkdir -p "$WS/eee-plain/.git/hooks"; chmod -x "$WS/eee-plain/.git/hooks/pre-commit"
chk "verdict: a non-executable pre-commit reads 'ungated' (git never runs it)" \
  "[ \"\$(verdict \"$WS/eee-plain\")\" = ungated ]"
chmod +x "$WS/eee-plain/.git/hooks/pre-commit"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "4. DEFECT 3 — a pre-commit that only MENTIONS lefthook in a comment is not a gate"
# ══════════════════════════════════════════════════════════════════════════════════════════════
chk "verdict: '# we migrated away from lefthook in 2024' + 'exit 0' is NOT gated" \
  "[ \"\$(verdict \"$WS/aaa-comment-hook\")\" = foreign-hook ]"
chk "adopt names aaa-comment-hook as NOT gated in its summary" \
  "printf '%s' \"\$WS_OUT\" | grep -q 'aaa-comment-hook (foreign-hook)'"
if try_commit "$WS/aaa-comment-hook" "leak.js" "$LEAK"; then
  ok "…and the world agrees: the secret commits cleanly there (calling it ARMED was the bug)"
else
  bad "…the secret commit was refused, so the fixture is not exercising the comment-only hook"
fi
unstage "$WS/aaa-comment-hook" "leak.js"
printf '#!/bin/sh\nexit 0  # we dropped lefthook\n' > "$F/h-trailing"
printf '#!/bin/sh\nexec lefthook run pre-commit\n'  > "$F/h-real"
chk "a TRAILING comment does not count either (\`exit 0  # we dropped lefthook\`)" "! invokes \"$F/h-trailing\""
chk "NEGATIVE CONTROL: the detector still says yes to a real invocation (it did not just go blind)" \
  "invokes \"$F/h-real\""

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "5. DEFECT 4 — exiting 0 with git repos under the root and none of them gated"
# ══════════════════════════════════════════════════════════════════════════════════════════════
NWS="$F/ws-none"; mkdir -p "$NWS"; mkrepo "$NWS/aaa"; mkrepo "$NWS/bbb"
for m in aaa bbb; do
  printf '#!/bin/sh\n# nothing to do with lefthook\nexit 0\n' > "$NWS/$m/.git/hooks/pre-commit"
  chmod +x "$NWS/$m/.git/hooks/pre-commit"
done
LOCKED="$NWS/zzz-locked"; mkrepo "$LOCKED"; chmod 000 "$LOCKED"
run_adopt "$NWS"
chmod 755 "$LOCKED" 2>/dev/null
chk "no member gated → adopt exits NON-ZERO (rc=$ADOPT_RC), never 0 over N unguarded repos" \
  "[ $ADOPT_RC -ne 0 ]"
chk "…and says so in words a human can act on" \
  "printf '%s' \"\$ADOPT_OUT\" | grep -q 'NOT ONE member repo'"
chk "an UNREADABLE member is named as not-gated, never silently dropped from the count" \
  "printf '%s' \"\$ADOPT_OUT\" | grep -q 'zzz-locked (unreadable)'"
if try_commit "$NWS/aaa" "leak.js" "$LEAK"; then
  ok "…and the world agrees: those repos really are ungated (the non-zero exit is the honest answer)"
else
  bad "…the secret commit was refused there, so the failing exit was wrong"
fi
unstage "$NWS/aaa" "leak.js"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "6. DEFECT 5 — nothing is written outside the workspace, and eject reverses every touch"
# ══════════════════════════════════════════════════════════════════════════════════════════════
chk "a git repo OUTSIDE the adopted root is never touched" \
  "[ ! -e \"$OUTSIDER/.git/hooks/pre-commit\" ] && [ ! -e \"$OUTSIDER/lefthook.yml\" ]"
chk "every manifest path stays inside the root (no absolute, no ../ escape)" \
  "python3 -c \"import json,os;ps=[x['path'] for x in json.load(open('$WS/.kickoff/adopt-manifest.json'))['entries']];assert all(not os.path.isabs(p) and not os.path.normpath(p).startswith('..') for p in ps), ps\""
chk "the member wiring is RELATIVE — no machine path leaked into a shared repo" \
  "! grep -qF \"$F\" \"$WS/ccc-plain/lefthook.yml\" \"$WS/.kickoff/lefthook-member.yml\""
chk "…and it points at the MEMBER-scoped gate file, not the root one (root-relative commands brick a member)" \
  "grep -q '\\.\\./\\.kickoff/lefthook-member\\.yml' \"$WS/ccc-plain/lefthook.yml\" && ! grep -q 'lefthook-kickoff' \"$WS/ccc-plain/lefthook.yml\""
chk "…and the member gate file's commands are member-relative" \
  "grep -q 'bash \\.\\./\\.kickoff/bin/scan-secrets --staged' \"$WS/.kickoff/lefthook-member.yml\""

EJ_ARCH="$(mk)"; EJ_RC=0
EJ_OUT="$(env REPO_DIR="$WS" KICKOFF_ADOPTERS_REGISTRY="$REG" KICKOFF_CORE_DIR="$CORE" \
      CLAUDE_CONFIG_DIR="$CFG" PATH="$STUB:$PATH" bash "$KO" eject --dir "$WS" --archive \
      --archive-dir "$EJ_ARCH" --delete-data --confirm-destroy </dev/null 2>&1)" || EJ_RC=$?
chk "eject exits 0 on the workspace footprint (rc=$EJ_RC)" "[ $EJ_RC -eq 0 ]"
chk "eject removed the member's lefthook.yml (its extends target went with .kickoff/)" \
  "[ ! -e \"$WS/ccc-plain/lefthook.yml\" ]"
chk "eject removed the member's installed hooks" \
  "[ ! -e \"$WS/ccc-plain/.git/hooks/pre-commit\" ] && [ ! -e \"$WS/ccc-plain/.git/hooks/_kickoff-hook-runner\" ]"
chk "eject removed the hooksPath member's hooks too" "[ ! -e \"$WS/ddd-husky/.husky/pre-commit\" ]"
chk "the member checkout is left byte-clean (git status is empty — no untracked kickoff leftovers)" \
  "[ -z \"\$(cd \"$WS/ccc-plain\" && git status --porcelain)\" ]"
chk "eject did NOT touch the hook the adopter owned" \
  "[ \"\$(sha256sum \"$WS/aaa-comment-hook/.git/hooks/pre-commit\" | cut -d' ' -f1)\" = \"$SHA_AAA\" ]"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "7. DEFECT 6 — a hook the adopter owns is never replaced"
# ══════════════════════════════════════════════════════════════════════════════════════════════
chk "the comment-only hook is BYTE-IDENTICAL after adopt (warned about, never overwritten)" \
  "[ \"\$(sha256sum \"$WS/aaa-comment-hook/.git/hooks/pre-commit\" | cut -d' ' -f1)\" = \"$SHA_AAA\" ]"
chk "the adopter's real lefthook hook is BYTE-IDENTICAL after adopt" \
  "[ \"\$(sha256sum \"$WS/bbb-own-lefthook/.git/hooks/pre-commit\" | cut -d' ' -f1)\" = \"$SHA_BBB\" ]"
chk "…and adopt said it was NOT overwriting the foreign one" \
  "printf '%s' \"\$WS_OUT\" | grep -q 'NOT overwriting your hook'"
chk "…and left the already-armed one alone" \
  "printf '%s' \"\$WS_OUT\" | grep -q 'already ARMED'"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "8. THE ANCESTOR BUG — adopting a SUBDIR must refuse, never arm the repo above it"
# ══════════════════════════════════════════════════════════════════════════════════════════════
ANC="$F/ancestor"; mkrepo "$ANC"; mkdir -p "$ANC/sub"
chk "fixture: the ancestor has no pre-commit before the run (or the case measures nothing)" \
  "[ ! -e \"$ANC/.git/hooks/pre-commit\" ]"
run_adopt "$ANC/sub"
chk "adopting a subdir does NOT arm the ANCESTOR repo's hooks" \
  "[ ! -e \"$ANC/.git/hooks/pre-commit\" ] && [ ! -e \"$ANC/.git/hooks/_kickoff-hook-runner\" ]"
chk "…and it says WHY, instead of printing a green ARMED over an inert hook" \
  "printf '%s' \"\$ADOPT_OUT\" | grep -q 'is not its root'"
# SAME RULE, THE OTHER SHAPE — and a deliberate behaviour CHANGE, pinned here so it stays deliberate:
# a LINKED WORKTREE runs the MAIN repo's hooks, which sit outside the worktree. Arming used to write
# them there anyway, unrecorded (eject could not reverse a touch in a tree it does not own). It now
# refuses and says so; the honest warning replaces a green over someone else's git dir.
WTM="$F/wt-main"; mkrepo "$WTM"
git -C "$WTM" worktree add -q "$F/wt-linked" >/dev/null 2>&1
chk "fixture: the linked worktree exists and its hooks resolve to the MAIN repo" \
  "[ -d \"$F/wt-linked\" ] && [ \"\$(cd \"$F/wt-linked\" && git rev-parse --git-path hooks)\" = \"$WTM/.git/hooks\" ]"
run_adopt "$F/wt-linked"
chk "a linked worktree adopt does NOT write into the MAIN repo's hooks dir" \
  "[ ! -e \"$WTM/.git/hooks/pre-commit\" ] && [ ! -e \"$WTM/.git/hooks/_kickoff-hook-runner\" ]"
chk "…and it names the refusal (OUTSIDE the repo being armed), rather than reporting ARMED" \
  "printf '%s' \"\$ADOPT_OUT\" | grep -q 'refusing to write hooks outside the repo being armed'"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "9. NO REGRESSION — the single-repo adopt every existing adopter uses"
# ══════════════════════════════════════════════════════════════════════════════════════════════
SOLO="$F/solo"; mkrepo "$SOLO"
run_adopt "$SOLO"
chk "single-repo adopt still exits 0" "[ $ADOPT_RC -eq 0 ]"
chk "single-repo adopt arms .git/hooks (unchanged location)" \
  "[ -x \"$SOLO/.git/hooks/pre-commit\" ] && [ -x \"$SOLO/.git/hooks/pre-push\" ] && [ -x \"$SOLO/.git/hooks/_kickoff-hook-runner\" ]"
chk "single-repo adopt records the hooks at the SAME unprefixed paths as before" \
  "python3 -c \"import json;ps={x['path'] for x in json.load(open('$SOLO/.kickoff/adopt-manifest.json'))['entries']};assert '.git/hooks/pre-commit' in ps and '.git/hooks/_kickoff-hook-runner' in ps\""
chk "single-repo adopt extends the ROOT gate file (root-relative commands — unchanged)" \
  "grep -q 'lefthook-kickoff.yml' \"$SOLO/lefthook.yml\" && grep -q 'bash .kickoff/bin/scan-secrets --staged' \"$SOLO/.kickoff/lefthook-kickoff.yml\""
chk "single-repo adopt writes NO member gate file (that path is workspace-only)" \
  "[ ! -e \"$SOLO/.kickoff/lefthook-member.yml\" ]"
chk "single-repo adopt prints no workspace section at all" \
  "! printf '%s' \"\$ADOPT_OUT\" | grep -q 'the gates go on the MEMBERS'"
secret_is_refused "$SOLO" "single repo"
clean_is_accepted "$SOLO" "single repo"
# a nested checkout inside a single repo stays a single repo (it is not a workspace)
mkrepo "$SOLO/vendored"
run_adopt "$SOLO"
chk "a repo CONTAINING a nested checkout is still adopted as a single repo" \
  "! printf '%s' \"\$ADOPT_OUT\" | grep -q 'the gates go on the MEMBERS'"
# …asserted on the CONSUMING ARTIFACTS, not just the absence of a log line: no workspace marker was
# invented, no member gate file appeared, the nested checkout was never armed, and adopt exits 0.
chk "…and NO workspace marker was invented (inference would silently promote it)" \
  "[ ! -e \"$SOLO/.kickoff/workspace\" ]"
chk "…and the nested checkout's hooks were never armed" \
  "[ ! -e \"$SOLO/vendored/.git/hooks/pre-commit\" ] && [ ! -e \"$SOLO/vendored/lefthook.yml\" ]"
chk "…and the manifest holds NO member-prefixed paths" \
  "python3 -c \"import json;ps=[x['path'] for x in json.load(open('$SOLO/.kickoff/adopt-manifest.json'))['entries']];assert not any(p.startswith('vendored/') for p in ps), ps\""
secret_is_refused "$SOLO" "single repo, after a nested checkout appeared"
# The same for the two `.git`-as-a-FILE shapes under an UNMARKED root — the marker is the switch.
SOLO2="$F/solo-sub"; mkrepo "$SOLO2"
SUBSRC="$F/subsrc"; mkrepo "$SUBSRC"
( cd "$SOLO2" && $GIT -c protocol.file.allow=always submodule add -q "$SUBSRC" sub >/dev/null 2>&1 )
( cd "$SOLO2" && git add -A >/dev/null 2>&1 && $GIT commit -qm addsub >/dev/null 2>&1 )
run_adopt "$SOLO2"
chk "no marker + a SUBMODULE child: still adopted as a single repo (rc=$ADOPT_RC)" \
  "[ $ADOPT_RC -eq 0 ] && ! printf '%s' \"\$ADOPT_OUT\" | grep -q 'the gates go on the MEMBERS'"
chk "…and the submodule was neither wired nor armed" \
  "[ ! -e \"$SOLO2/sub/lefthook.yml\" ] && [ ! -e \"$SOLO2/.git/modules/sub/hooks/pre-commit\" ]"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "10. A WORKSPACE ROOT MAY NOW BE A GIT REPO — the marker, and the \`git init\` that demoted an org"
# ══════════════════════════════════════════════════════════════════════════════════════════════
# "is this a workspace?" was answered by "is the root NOT a git repo?", so the two were MUTUALLY
# EXCLUSIVE: an org's own charter/tracker/memory/specialist agents could never be version-
# controlled, and `git init` at a workspace root SILENTLY demoted the whole org to a single repo —
# member gate-arming stopped, both scanners collapsed to the root alone, and NOTHING went red
# (already-installed member hooks survive on disk, so the drift is invisible until someone re-runs
# the secret-commit probe). This section walks that exact sequence on the real front door.
MWS="$F/ws-marker"; mkdir -p "$MWS"
mkrepo "$MWS/aaa"; mkrepo "$MWS/bbb"
run_adopt "$MWS"
chk "adopt on a NON-git workspace root writes the explicit marker .kickoff/workspace" \
  "[ -f \"$MWS/.kickoff/workspace\" ]"
chk "…and RECORDS it, so \`kickoff eject\` reverses it (an unrecorded touch is invisible to eject)" \
  "python3 -c \"import json;ps={x['path'] for x in json.load(open('$MWS/.kickoff/adopt-manifest.json'))['entries']};assert '.kickoff/workspace' in ps\""
chk "…and the marker is NOT gitignored by the shipped .kickoff/.gitignore (it must survive a clone)" \
  "! grep -qx 'workspace' \"$MWS/.kickoff/.gitignore\" 2>/dev/null"
MARK_SHA="$(sha256sum "$MWS/.kickoff/workspace" | cut -d' ' -f1)"
run_adopt "$MWS"
chk "re-adopt: the marker is byte-identical and recorded exactly once (idempotent back-fill)" \
  "[ \"\$(sha256sum \"$MWS/.kickoff/workspace\" | cut -d' ' -f1)\" = \"$MARK_SHA\" ] && python3 -c \"import json;ps=[x['path'] for x in json.load(open('$MWS/.kickoff/adopt-manifest.json'))['entries']];assert ps.count('.kickoff/workspace')==1, ps\""

# ── THE `git init` — the move that used to demote the org, run for real ──────────────────────
git -c init.defaultBranch=main init -q "$MWS"
printf 'aaa/\nbbb/\n' > "$MWS/.gitignore"
printf '# the org charter\n' > "$MWS/CLAUDE.md"
( cd "$MWS" && git add .gitignore CLAUDE.md >/dev/null 2>&1 && $GIT commit -qm charter >/dev/null 2>&1 )
chk "fixture: the workspace root really IS a git repo now (or this section measures nothing)" \
  "[ \"\$(cd \"$MWS\" && git rev-parse --show-toplevel)\" = \"\$(cd \"$MWS\" && pwd -P)\" ]"
# doctor is the documented back-fill verb, and the one an existing adopter actually runs.
MDOC="$(run_doctor "$MWS")"
chk "after \`git init\`: doctor STILL treats the root as a workspace (it is not demoted)" \
  "printf '%s' \"\$MDOC\" | grep -q 'the gates go on the MEMBERS'"
chk "…and says the root is a git repo AND a marked workspace root" \
  "printf '%s' \"\$MDOC\" | grep -q 'is a git repo AND a marked workspace root'"
chk "…and the ROOT's own hooks are armed (its charter/agents are gated too)" \
  "[ -x \"$MWS/.git/hooks/pre-commit\" ] && [ -x \"$MWS/.git/hooks/_kickoff-hook-runner\" ]"
chk "…and the count includes the root as a gated unit, not just the members" \
  "printf '%s' \"\$MDOC\" | grep -q '3 of 3 gated unit(s) (2 member(s) + this root)'"

# THE ACCEPTANCE PROPERTY, on the real consuming artifact — commits, in every direction.
secret_is_refused "$MWS" "the marked git ROOT itself (its own CLAUDE.md/agents are gated)"
clean_is_accepted "$MWS" "the marked git ROOT itself"
for m in aaa bbb; do
  secret_is_refused "$MWS/$m" "member $m under a GIT workspace root"
  clean_is_accepted "$MWS/$m" "member $m under a GIT workspace root"
done
# GUARD SITE 4 — the .kickoff/bin shims. They decided "am I a workspace member?" with the SAME
# root-is-not-a-repo inference, so at a marked GIT root that branch went dead and a member's
# pre-commit cd'd to the ROOT and scored its commit on the ROOT's (usually empty) index. Every
# member commit would have passed on someone else's index — a silent false green invisible to any
# test that drives the scanners directly. Both directions are required:
printf '%s\n' "$LEAK" > "$MWS/aaa/leak.js"; ( cd "$MWS/aaa" && git add leak.js ) >/dev/null 2>&1
clean_is_accepted "$MWS/bbb" "member scoping under a GIT root (a neighbour holds a staged secret)"
unstage "$MWS/aaa" "leak.js"
printf '%s\n' "$LEAK" > "$MWS/root-leak.js"; ( cd "$MWS" && git add root-leak.js ) >/dev/null 2>&1
clean_is_accepted "$MWS/aaa" "member scoping under a GIT root (the ROOT holds a staged secret)"
( cd "$MWS" && git reset -q >/dev/null 2>&1; rm -f "$MWS/root-leak.js" )

# ── eject reverses the marker too ────────────────────────────────────────────────────────────
MEJ="$(mk)"; MEJ_RC=0
MEJ_OUT="$(env REPO_DIR="$MWS" KICKOFF_ADOPTERS_REGISTRY="$REG" KICKOFF_CORE_DIR="$CORE" \
      CLAUDE_CONFIG_DIR="$CFG" PATH="$STUB:$PATH" bash "$KO" eject --dir "$MWS" --archive \
      --archive-dir "$MEJ" --delete-data --confirm-destroy </dev/null 2>&1)" || MEJ_RC=$?
chk "eject on a marked GIT workspace root exits 0 (rc=$MEJ_RC)" "[ $MEJ_RC -eq 0 ]"
chk "eject removed the workspace marker" "[ ! -e \"$MWS/.kickoff/workspace\" ]"
chk "eject removed the members' gate wiring under a GIT root too" \
  "[ ! -e \"$MWS/aaa/lefthook.yml\" ] && [ ! -e \"$MWS/aaa/.git/hooks/_kickoff-hook-runner\" ]"

# ── eject --verify must NOT report CLEAN over unreversed MEMBER wiring ───────────────────────
# The porcelain proof only ever looks at the ROOT. On a marked git root that produces a real
# "clean" while adopt's lefthook.yml + armed hooks sit untouched in every member — strictly worse
# than the honest "unprovable" a non-git root used to get. Plant that exact state and demand a red.
VWS="$F/ws-verify"; mkdir -p "$VWS"; mkrepo "$VWS/aaa"
run_adopt "$VWS"                          # a real adopt: it writes the marker at this non-git root
git -c init.defaultBranch=main init -q "$VWS"; printf 'aaa/\n.kickoff/\n' > "$VWS/.gitignore"
( cd "$VWS" && git add .gitignore >/dev/null 2>&1 && $GIT commit -qm base >/dev/null 2>&1 )
chk "fixture: --verify target is a marked GIT root with real member wiring on disk" \
  "[ -f \"$VWS/.kickoff/workspace\" ] && [ -f \"$VWS/aaa/lefthook.yml\" ] && [ -x \"$VWS/aaa/.git/hooks/_kickoff-hook-runner\" ]"
# THE PLANT: make the member's wiring un-reversible by dropping its manifest entries, so eject
# leaves it behind. The root's own porcelain is still perfectly clean — which is exactly the shape
# that would print "✓ no trace" while every member stayed wired.
python3 - "$VWS/.kickoff/adopt-manifest.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
n = len(d["entries"])
d["entries"] = [e for e in d["entries"] if not e["path"].startswith("aaa/")]
assert len(d["entries"]) < n, "fixture removed nothing — the member entries were not named aaa/…"
json.dump(d, open(p, "w"), indent=2)
PY
VRC=0
VOUT="$(env REPO_DIR="$VWS" KICKOFF_ADOPTERS_REGISTRY="$REG" KICKOFF_CORE_DIR="$CORE" \
      CLAUDE_CONFIG_DIR="$CFG" PATH="$STUB:$PATH" bash "$KO" eject --dir "$VWS" --verify \
      --archive-dir "$(mk)" </dev/null 2>&1)" || VRC=$?
# The fixture only proves something if the ROOT's own proof came back clean — literally empty, or
# every line allowlisted. Otherwise the non-zero exit could be coming from root residue and the
# member sweep would be untested.
chk "fixture: the ROOT's own byte-for-byte proof found NO residue (or the case proves nothing)" \
  "printf '%s' \"\$VOUT\" | grep -qE 'working tree CLEAN|every entry is your retained kickoff-data'"
chk "…and it is NOT the root proof that failed the verify" \
  "! printf '%s' \"\$VOUT\" | grep -q 'NOT byte-for-byte clean — change'"
chk "eject --verify NAMES member residue instead of claiming a clean root proof" \
  "printf '%s' \"\$VOUT\" | grep -q 'workspace MEMBER residue'"
chk "…and exits NON-ZERO over it (rc=$VRC), never 'no trace'" \
  "[ $VRC -ne 0 ] && ! printf '%s' \"\$VOUT\" | grep -q 'no trace'"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "11. .git AS A FILE — a SUBMODULE member is real; a linked WORKTREE is not"
# ══════════════════════════════════════════════════════════════════════════════════════════════
# In a submodule `.git` is a FILE (`gitdir: ../.git/modules/<n>`), so the dir-only member test was
# simply FALSE and the member never existed — measured: a planted AWS key inside one scanned as
# "no secrets found", rc 0. It IS a member now. It still cannot be ARMED: git runs its hooks from
# <root>/.git/modules/<n>/hooks, OUTSIDE the member, and writing there is a touch eject cannot
# reverse. The honest answer is "scanned, named as not gated" — never a green over an unguarded repo.
SWS="$F/ws-sub"; mkdir -p "$SWS"
SSRC="$F/sub-src"; mkrepo "$SSRC"
mkrepo "$SWS/plain"                       # one ordinary member, so the root is not the only unit
git -c init.defaultBranch=main init -q "$SWS"
mkdir -p "$SWS/.kickoff"; printf '# workspace\n' > "$SWS/.kickoff/workspace"
printf 'plain/\n' > "$SWS/.gitignore"
( cd "$SWS" && git add .gitignore >/dev/null 2>&1 && $GIT commit -qm base >/dev/null 2>&1 )
( cd "$SWS" && $GIT -c protocol.file.allow=always submodule add -q "$SSRC" sub >/dev/null 2>&1 )
( cd "$SWS" && git add -A >/dev/null 2>&1 && $GIT commit -qm addsub >/dev/null 2>&1 )
chk "fixture: the submodule's .git is a FILE naming a modules/ path (or the case measures nothing)" \
  "[ -f \"$SWS/sub/.git\" ] && grep -q 'gitdir:.*modules/sub' \"$SWS/sub/.git\""
run_adopt "$SWS"
chk "a SUBMODULE is enumerated as a member (the dir-only test skipped it entirely)" \
  "printf '%s' \"\$ADOPT_OUT\" | grep -q 'member: sub'"
chk "…and adopt does NOT hard-fail: the root and the plain member ARE gated (rc=$ADOPT_RC)" \
  "[ $ADOPT_RC -eq 0 ]"
chk "…and the submodule is named as NOT gated, honestly, rather than counted green" \
  "printf '%s' \"\$ADOPT_OUT\" | grep -q 'sub (unverifiable)'"
chk "…and NOTHING was written into <root>/.git/modules/sub/hooks (a touch eject cannot reverse)" \
  "[ ! -e \"$SWS/.git/modules/sub/hooks/pre-commit\" ] && [ ! -e \"$SWS/.git/modules/sub/hooks/_kickoff-hook-runner\" ]"
# the world agrees with the report — and the SCAN still covers it, which is the point of (d).
if try_commit "$SWS/sub" "leak.js" "$LEAK"; then
  ok "…and the world agrees: the submodule really is ungated (so 'gated' would have been a lie)"
else
  bad "…the secret commit in the submodule was refused, so the honest report should have said gated"
fi
unstage "$SWS/sub" "leak.js"
printf '%s\n' "$LEAK" > "$SWS/sub/leak.js"
( cd "$SWS/sub" && git add leak.js >/dev/null 2>&1 && $GIT commit -qm leak >/dev/null 2>&1 )
SSCAN_RC=0
SSCAN="$( cd "$SWS" && bash "$CORE/scripts/scan-secrets.sh" 2>&1 )" || SSCAN_RC=$?
chk "the submodule IS scanned by the workspace fan-out (rc=$SSCAN_RC — this was a silent rc 0)" \
  "[ $SSCAN_RC -ne 0 ] && printf '%s' \"\$SSCAN\" | grep -q 'FAILED in: sub'"

# A LINKED WORKTREE also carries `.git` as a FILE — and must NOT become a member. Its hooks live in
# the MAIN repo, outside it; a prior release deliberately stopped arming worktrees for that reason,
# and a naive relaxation of the member test to "any .git entry" would silently re-arm them.
TWS="$F/ws-worktree"; mkdir -p "$TWS"; mkrepo "$TWS/main"
git -C "$TWS/main" worktree add -q "$TWS/linked" >/dev/null 2>&1
chk "fixture: the linked worktree's .git is a FILE naming a worktrees/ path" \
  "[ -f \"$TWS/linked/.git\" ] && grep -q 'gitdir:.*worktrees/' \"$TWS/linked/.git\""
run_adopt "$TWS"
chk "a linked WORKTREE under a workspace root is NOT enumerated as a member" \
  "! printf '%s' \"\$ADOPT_OUT\" | grep -q 'member: linked'"
chk "…and it is counted as ONE member (the main checkout), not two" \
  "printf '%s' \"\$ADOPT_OUT\" | grep -q '1 of 1 member repo(s) GATED'"
chk "…and nothing was written into the MAIN repo's hooks on its behalf" \
  "[ ! -e \"$TWS/linked/lefthook.yml\" ]"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "12. THE GIT ROOT THAT IS ALREADY A WORKSPACE — detected and NAMED, never inferred"
# ══════════════════════════════════════════════════════════════════════════════════════════════
# Section 10 reaches a git-rooted workspace by ONE ordering: adopt while the root is not yet a
# repo, THEN `git init`. The natural entry — "I already have a repo whose subdirs are my org's
# checkouts" — landed in the old silent demotion: adopt, doctor and verify said NOTHING about
# workspaces (grep -ic 'workspace|member repo' = 0, 0, 0), no marker, no member wiring, and a
# member's committed secret then scanned CLEAN from the root. Inferring the shape is still refused
# (a repo that vendors a checkout must not start arming gates inside it) — but SILENCE is not the
# alternative. The shape is named once, with the flag that fixes it.
GWS="$F/ws-git-first"; mkrepo "$GWS"; mkrepo "$GWS/aaa"; mkrepo "$GWS/bbb"
chk "fixture: the root IS a git toplevel holding 2 sibling checkouts (or this section measures nothing)" \
  "[ \"\$(cd \"$GWS\" && git rev-parse --show-toplevel)\" = \"\$(cd \"$GWS\" && pwd -P)\" ] && [ -d \"$GWS/aaa/.git\" ] && [ -d \"$GWS/bbb/.git\" ]"
run_adopt "$GWS"
chk "adopt on a git root holding sibling checkouts NAMES the workspace shape (was total silence)" \
  "printf '%s' \"\$ADOPT_OUT\" | grep -q 'workspace shape NOT assumed'"
chk "…names the members it is NOT covering, and the flag that would" \
  "printf '%s' \"\$ADOPT_OUT\" | grep -q 'aaa bbb' && printf '%s' \"\$ADOPT_OUT\" | grep -q -- '--workspace'"
# BYTE-IDENTICAL BEHAVIOUR: naming the shape must change nothing else. Assert on the ARTIFACTS.
chk "…and STILL does not infer: no marker was written (rc=$ADOPT_RC)" \
  "[ $ADOPT_RC -eq 0 ] && [ ! -e \"$GWS/.kickoff/workspace\" ]"
chk "…no member was wired or armed, and the manifest holds no member-prefixed path" \
  "[ ! -e \"$GWS/aaa/lefthook.yml\" ] && [ ! -e \"$GWS/aaa/.git/hooks/_kickoff-hook-runner\" ] && python3 -c \"import json;ps=[x['path'] for x in json.load(open('$GWS/.kickoff/adopt-manifest.json'))['entries']];assert not any(p.startswith(('aaa/','bbb/')) for p in ps), ps\""
secret_is_refused "$GWS" "the git root itself (adopted as a single repo, unchanged)"
VG="$(run_verify "$GWS")"
chk "verify names the shape too (it was silent while N sibling repos committed unscanned)" \
  "printf '%s' \"\$VG\" | grep -q 'immediate child checkout' && printf '%s' \"\$VG\" | grep -q 'doctor --workspace'"

# ── THE OPT-IN — one flag, and it RECORDS the marker (a hand-made one leaves eject no receipt) ──
MDOC2="$(run_doctor "$GWS" --workspace)"
chk "\`doctor --workspace\` promotes the git root to a marked workspace" \
  "[ -f \"$GWS/.kickoff/workspace\" ] && printf '%s' \"\$MDOC2\" | grep -q 'is a git repo AND a marked workspace root'"
chk "…and RECORDS the marker exactly once, so \`kickoff eject\` reverses it" \
  "python3 -c \"import json;ps=[x['path'] for x in json.load(open('$GWS/.kickoff/adopt-manifest.json'))['entries']];assert ps.count('.kickoff/workspace')==1, ps\""
chk "…and counts the root as a gated unit alongside its members" \
  "printf '%s' \"\$MDOC2\" | grep -q '3 of 3 gated unit(s) (2 member(s) + this root)'"
for m in aaa bbb; do
  secret_is_refused "$GWS/$m" "member $m after \`doctor --workspace\` on a GIT root"
  clean_is_accepted "$GWS/$m" "member $m after \`doctor --workspace\` on a GIT root"
done
# …and the SCAN follows the gate: a secret forced past a member's hook still fails the root's scan.
printf '%s\n' "$LEAK" > "$GWS/bbb/forced.js"
( cd "$GWS/bbb" && git add forced.js >/dev/null 2>&1 && $GIT commit --no-verify -qm forced >/dev/null 2>&1 )
GSCAN_RC=0; GSCAN="$( cd "$GWS" && bash "$CORE/scripts/scan-secrets.sh" 2>&1 )" || GSCAN_RC=$?
chk "the fan-out from the git root catches a member's committed secret (rc=$GSCAN_RC — this was rc 0)" \
  "[ $GSCAN_RC -ne 0 ] && printf '%s' \"\$GSCAN\" | grep -q 'FAILED in: bbb'"

# ── --workspace over ZERO members is a typo, not an org: refuse, and say why ────────────────────
ZWS="$F/ws-zero"; mkrepo "$ZWS"
run_adopt_flags "$ZWS" --workspace
chk "\`--workspace\` at a root with ZERO member repos does NOT write the marker" \
  "[ ! -e \"$ZWS/.kickoff/workspace\" ]"
chk "…and says why, instead of minting a workspace the scanners then warn about forever" \
  "printf '%s' \"\$ADOPT_OUT\" | grep -q 'ZERO immediate child repos'"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "13. A ROOT NESTED INSIDE ANOTHER WORK TREE — 'not the toplevel' is NOT 'not a git repo'"
# ══════════════════════════════════════════════════════════════════════════════════════════════
# THE BLOCKER (adversarial review). `_root_is_repo` was `show-toplevel = pwd`, so a directory that
# is INSIDE another work tree — fully tracked there — read as "not a git repo" and adopt wrote the
# workspace marker into it. Both scanners then treated it as a root with no files of its own: a
# committed AWS key in the org's own .claude/agents/*.md went from RED (pre-change) to "workspace
# clean", rc 0. The auto-write now fires only where the root is inside NO work tree at all.
NOUT="$F/nested-outer"; mkrepo "$NOUT"
mkdir -p "$NOUT/org"; mkrepo "$NOUT/org/alpha"
printf 'org/alpha/\n' > "$NOUT/.gitignore"
( cd "$NOUT" && git add -A >/dev/null 2>&1 && $GIT commit -qm base >/dev/null 2>&1 )
chk "fixture: the target is inside a work tree but is NOT its toplevel (or this measures nothing)" \
  "( cd \"$NOUT/org\" && git rev-parse --is-inside-work-tree ) && [ \"\$(cd \"$NOUT/org\" && git rev-parse --show-toplevel)\" != \"\$(cd \"$NOUT/org\" && pwd -P)\" ]"
run_adopt "$NOUT/org"
chk "adopt does NOT write the workspace marker into a directory another repo already tracks (rc=$ADOPT_RC)" \
  "[ $ADOPT_RC -eq 0 ] && [ ! -e \"$NOUT/org/.kickoff/workspace\" ]"
chk "…and says out loud WHICH repo owns its files, instead of implying it has none" \
  "printf '%s' \"\$ADOPT_OUT\" | grep -q 'is INSIDE the git repo at' && printf '%s' \"\$ADOPT_OUT\" | grep -q 'not its own toplevel'"
chk "…while the members are still wired exactly as before (behaviour unchanged where it was right)" \
  "[ -f \"$NOUT/org/alpha/lefthook.yml\" ]"
secret_is_refused "$NOUT/org/alpha" "a member under a root nested inside another work tree"

# ── A HAND-MADE MARKER GETS ITS RECEIPT BACK-FILLED ────────────────────────────────────────────
# The marker is TRACKED and the manifest is gitignored, so a teammate's fresh clone of the org root
# has the marker and NO receipt for it — and `eject --verify` then reports its own reversal as
# unexplained drift. adopt's "already present — left as-is" branch never recorded it.
HWS="$F/ws-handmade"; mkdir -p "$HWS/.kickoff"; mkrepo "$HWS/one"
printf '# workspace\n' > "$HWS/.kickoff/workspace"
run_adopt "$HWS"
chk "a pre-existing (hand-made / freshly-cloned) marker is left byte-as-is" \
  "grep -q '^# workspace$' \"$HWS/.kickoff/workspace\""
chk "…and its MISSING manifest receipt is back-filled exactly once (eject had no record of it)" \
  "python3 -c \"import json;ps=[x['path'] for x in json.load(open('$HWS/.kickoff/adopt-manifest.json'))['entries']];assert ps.count('.kickoff/workspace')==1, ps\""
run_adopt "$HWS"
chk "…and a re-adopt does not add a second receipt (idempotent)" \
  "python3 -c \"import json;ps=[x['path'] for x in json.load(open('$HWS/.kickoff/adopt-manifest.json'))['entries']];assert ps.count('.kickoff/workspace')==1, ps\""

# ── THE SUMMARY LINE MUST AGREE WITH THE WARN SIX LINES ABOVE IT ──────────────────────────────
# `doctor: nothing to fix — already healthy` printed under `⚠ workspace gates: 1 of 2 … NOT gated:
# ownext` — and a real AWS-key commit then landed in ownext. The workspace verdict never reached
# doctor's counters, so the one line a non-technical operator actually reads contradicted the
# world. (`_KICKOFF_GATE_HARD_FAIL` covered only the NOTHING-gated case.)
PWS2="$F/ws-partial"; mkdir -p "$PWS2"; mkrepo "$PWS2/alpha"; mkrepo "$PWS2/ownext"
printf 'extends:\n  - ./their-own.yml\n' > "$PWS2/ownext/lefthook.yml"   # its own extends: ⇒ DEFERRED
run_adopt "$PWS2"
DPART="$(run_doctor "$PWS2")"
chk "fixture: the deferred member really is reported ungated (or this case measures nothing)" \
  "printf '%s' \"\$DPART\" | grep -q 'NOT gated: ownext'"
chk "doctor's SUMMARY carries the ungated member as an item needing attention (it said 'already healthy')" \
  "printf '%s' \"\$DPART\" | grep -q '• NOT gated: ownext'"
chk "…and the run never closes with 'nothing to fix — already healthy' over an ungated member" \
  "! printf '%s' \"\$DPART\" | grep -q 'nothing to fix — already healthy'"
if try_commit "$PWS2/ownext" "leak.js" "$LEAK"; then
  ok "…and the world agrees: a secret really does commit in that member (so the warn was true)"
else
  bad "…the secret commit was refused, so 'NOT gated' was the wrong report"
fi
unstage "$PWS2/ownext" "leak.js"

# ── VERIFY MUST NOT TELL A PLAIN FOLDER IT IS A WORKSPACE ──────────────────────────────────────
# The predicate is `marker OR not-a-git-repo`, whose second half fires for ANY non-git directory —
# so verify asserted "this is a workspace root but holds ZERO member repos" about an ordinary
# folder, while adopt on that same folder is correctly silent. Every printed claim must be true.
PWS="$F/plain-folder"; mkdir -p "$PWS"; printf 'x\n' > "$PWS/a.txt"
run_adopt "$PWS"
VP="$(run_verify "$PWS")"
chk "verify says NOTHING about workspaces for a plain non-git folder with no marker and no members" \
  "! printf '%s' \"\$VP\" | grep -qi 'workspace root'"

echo
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
