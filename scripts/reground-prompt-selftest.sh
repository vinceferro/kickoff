#!/usr/bin/env bash
# reground-prompt-selftest.sh — the re-ground prompt must INSTRUCT its boot checks, never EXECUTE them,
# and the checks it names must actually RESOLVE from the worker's real cwd — on an ADOPTER, not just here.
#
#   bash scripts/reground-prompt-selftest.sh
#
# Two bugs, both shipped, both invisible to `bash -n` and to a code-read:
#
#  1. COMMAND SUBSTITUTION (2026-07-16). The prompt named the checks in backticks inside a DOUBLE-quoted
#     bash string. Unescaped, bash ran them at prompt-build time and spliced their stdout where their
#     names belonged — so the worker was never told to run anything and read one line of stale output.
#
#  2. WRONG TOPOLOGY (caught at the core-v0.10 gate by an adversarial reviewer). The fix for #1 named the
#     checks REPO-RELATIVE (`scripts/memory-orphan-check.sh`). That resolves here, where the repo IS the
#     core — but a pull adopter runs the core from $KICKOFF_CORE_DIR while the worker's cwd is their OWN
#     repo, which has no scripts/ at all. There the command exits 127 and the prompt's "(if present)"
#     hedge silently swallows it: the mechanism is INERT for every adopter, and nothing goes red.
#     ([[pull-adopter-scripts-resolve-siblings-not-repo-dir]])
#
# So this suite builds the REAL DEPLOY TOPOLOGY — core scripts in one dir, the worker's cwd in a separate
# adopter repo holding only .kickoff/ — and asserts the instructed commands actually RUN there. A fixture
# that puts the scripts where the code expects them is exactly how bug #2 shipped; do not "simplify" this
# back into a single-dir fixture. Drift-proof (reads session-run.sh, never a copy), hermetic (mktemp).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SR="$HERE/session-run.sh"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -r "$SR" ] || { printf '  ❌ session-run.sh not readable at %s\n' "$SR"; exit 1; }

# ── Extract the REAL assignments from source (anchored on content, not line numbers) ─────────────
core_assign="$(grep -m1 '^[[:space:]]*_CORE_SCRIPTS=' "$SR" || true)"
prompt_assign="$(grep -m1 '^[[:space:]]*REGROUND_PROMPT="You are a HEADLESS' "$SR" || true)"
if [ -z "$prompt_assign" ]; then
  bad "could not find the default REGROUND_PROMPT assignment in session-run.sh (did it move/rename?)"
  printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"; exit 1
fi
ok "located the default REGROUND_PROMPT assignment in session-run.sh"
[ -n "$core_assign" ] && ok "located the _CORE_SCRIPTS resolution (checks resolve to the core, not the cwd)" \
                      || bad "no _CORE_SCRIPTS= in session-run.sh — the prompt cannot be naming core-absolute checks"

# ── Which boot checks does the prompt name? DERIVED FROM SOURCE, never hardcoded ──────────────────
# A fixed list goes stale the day someone adds a third check — and that is exactly how a boot check
# ships INERT: the suite keeps asserting on the checks it knows while the new one is untested. Read
# the names out of the assignment itself, so every check the prompt names is covered automatically.
# core-v0.21: .py counts too. The first non-shell boot check (orphaned-work.py) would otherwise be
# invisible to EVERY assertion below — including the manifest-travel test — and so ship inert to
# every adopter while this suite stayed green. Extension-blindness is the same bug class as the
# repo-relative naming the deploy test catches: the guard must cover what the prompt can actually say.
BOOT_CHECKS="$(printf '%s' "$prompt_assign" \
  | grep -oE '\$\{_CORE_SCRIPTS\}/[A-Za-z0-9._-]+\.(sh|py)' | sed 's|.*/||' | sort -u)"
if [ -z "$BOOT_CHECKS" ]; then
  bad "the prompt names NO \${_CORE_SCRIPTS}/*.{sh,py} boot check — either they were dropped, or they are no longer core-absolute"
  printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"; exit 1
fi
ok "prompt names $(printf '%s\n' "$BOOT_CHECKS" | grep -c .) boot check(s): $(printf '%s' "$BOOT_CHECKS" | tr '\n' ' ')"

# ── Build the ADOPTER topology and render the prompt as the wrapper would ─────────────────────────
# $1 = the prompt assignment under test. Echoes the built prompt. Layout:
#   $S/core/scripts/{session-run.sh,<every boot check the prompt names>}  ← core lives HERE (canary stubs)
#   $S/adopter/.kickoff/memory/MEMORY.md                 ← worker cwd; NO scripts/ dir, like a real adopter
# Stubs are created for $STUB_CHECKS (defaults to the derived BOOT_CHECKS); a caller can override it to
# stub FEWER than the prompt names — that is how negative control #3 simulates a check that never shipped.
render_adopter() {
  local passign="$1" S out
  S="$(mktemp -d)" || return 1
  mkdir -p "$S/core/scripts" "$S/adopter/.kickoff/memory"
  printf '# Memory Index\n- [x](x.md) — y\n' > "$S/adopter/.kickoff/memory/MEMORY.md"
  local s
  for s in ${STUB_CHECKS-$BOOT_CHECKS}; do
    # The stub must be written in the language the prompt INVOKES it with: a bash stub handed to
    # `python3` raises NameError, so a .py check would fail the deploy test for the stub's reason
    # rather than its own — a false RED that teaches nothing.
    case "$s" in
      *.py) printf '#!/usr/bin/env python3\nprint("CANARY_EXECUTED")\n' > "$S/core/scripts/$s" ;;
      *)    printf '#!/usr/bin/env bash\necho "CANARY_EXECUTED"\n'      > "$S/core/scripts/$s" ;;
    esac
    chmod +x "$S/core/scripts/$s"
  done
  # $0 = the core's session-run.sh, cwd = the adopter repo. This is the real deploy shape.
  out="$(cd "$S/adopter" && MEMORY_INDEX=".kickoff/memory/MEMORY.md" bash -c '
    MEMORY_INDEX="${MEMORY_INDEX:-memory/MEMORY.md}"
    '"$core_assign"'
    '"$passign"'
    printf "%s" "$REGROUND_PROMPT"
  ' "$S/core/scripts/session-run.sh" 2>/dev/null)"
  printf '%s\n__SANDBOX__%s' "$out" "$S"
}

raw="$(render_adopter "$prompt_assign")"
prompt="${raw%__SANDBOX__*}"
SANDBOX="${raw##*__SANDBOX__}"

# ── 1. The prompt INSTRUCTS (no build-time execution) ────────────────────────────────────────────
case "$prompt" in
  *CANARY_EXECUTED*) bad "COMMAND SUBSTITUTION: a boot check EXECUTED at prompt-build time and its output is IN the prompt (escape the backticks: \\\`…\\\`)" ;;
  *) ok "no boot check executed at prompt-build time (no canary in the prompt)" ;;
esac
# ── 1b. THE CONSUMER SIDE of the supervisor's outage breadcrumb ──────────────────────────────────
# supervisor.sh writes .kickoff/bridge-outages.log so a worker that was DEAF on Telegram can say so
# instead of announcing as if nothing happened. This clause in the RENDERED prompt is that file's
# ONLY reader — delete it and the supervisor keeps writing a file nobody consumes, with the
# supervisor suite, the auth-heal suite and this one all still byte-identically green. That is the
# .kickoff/secret.env failure exactly ([[verify-the-read-not-just-the-write]]): a check must assert
# on what the SYSTEM consumes, and here the consumer is a rendered string, so assert on the render.
case "$prompt" in
  *bridge-outages.log*) ok "CONSUMER TEST: the rendered prompt READS .kickoff/bridge-outages.log (the supervisor's breadcrumb has a reader)" ;;
  *) bad "CONSUMER TEST: the rendered prompt never mentions bridge-outages.log — the supervisor writes an outage breadcrumb that NOTHING reads (a recovered worker announces with amnesia)" ;;
esac
case "$prompt" in
  *OPEN*) ok "CONSUMER TEST: the prompt handles the OPEN (unfinished) breadcrumb shape, which is the one a recovery refresh leaves behind" ;;
  *) bad "CONSUMER TEST: the prompt only understands a COMPLETED breadcrumb — the OPEN row written at refresh time (the common restart case) would be unread" ;;
esac

n_named=0
for s in $BOOT_CHECKS; do
  case "$prompt" in
    *"$s"*) n_named=$((n_named + 1)) ;;
    *) bad "prompt does NOT name $s in the RENDERED text — the worker is never told to run it" ;;
  esac
done
[ "$n_named" -gt 0 ] && ok "all $n_named named boot check(s) survived into the rendered prompt"

# ── 2. THE DEPLOY TEST: do the instructed commands actually RUN from the adopter's cwd? ───────────
# Pull each backticked command out of the prompt and execute it exactly as instructed, from the
# worker's real cwd. This is the assertion bug #2 would have failed while everything else stayed green.
# Extract EVERY backticked command that invokes a *.sh — deliberately NOT filtered to BOOT_CHECKS.
# Filtering by the derived (core-absolute) names would make this test blind to exactly the bug it
# exists to catch: a check written REPO-RELATIVE never appears in BOOT_CHECKS, so it would be neither
# stubbed nor asserted, and the suite would go green while that check is inert on every adopter.
# Assert on what the prompt actually instructs, not on the subset already known to be well-formed.
instructed="$(printf '%s' "$prompt" | grep -oE '`[^`]*[A-Za-z0-9_-]+\.(sh|py)[^`]*`' | tr -d '`')"
if [ -z "$instructed" ]; then
  bad "could not extract the instructed check commands from the prompt"
else
  n_ok=0 n_bad=0
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    out="$(cd "$SANDBOX/adopter" && bash -c "$cmd" 2>&1)"
    case "$out" in
      *CANARY_EXECUTED*) n_ok=$((n_ok + 1)) ;;   # resolved + ran the real core script
      *) n_bad=$((n_bad + 1))
         printf '     ↳ instructed cmd did NOT resolve from the worker cwd: %s\n        → %s\n' "$cmd" "${out:-<no output>}" ;;
    esac
  done <<< "$instructed"
  if [ "$n_bad" -eq 0 ] && [ "$n_ok" -gt 0 ]; then
    ok "DEPLOY TEST: all $n_ok instructed check(s) resolve + run from an ADOPTER's cwd (core in a separate clone)"
  else
    bad "DEPLOY TEST: $n_bad instructed check(s) do NOT resolve on an adopter — the boot checks are INERT there (name them core-absolute, not repo-relative)"
  fi
fi
rm -rf "$SANDBOX"

# ── 2b. DOES IT TRAVEL? every named boot check must be in scripts/core-manifest.txt ───────────────
# The deploy test above proves the command resolves when the script IS in the adopter's core. What
# puts it there is the manifest — `kickoff pull` copies exactly that file set. A check named in the
# prompt but missing from the manifest resolves here (where the repo IS the core) and is 127 for
# every adopter: inert, silent, and green on every other assertion in this file.
MANIFEST="$HERE/core-manifest.txt"
if [ ! -r "$MANIFEST" ]; then
  bad "scripts/core-manifest.txt not readable — cannot prove the boot checks travel to adopters"
else
  m_bad=0
  for s in $BOOT_CHECKS; do
    grep -qxF "scripts/$s" "$MANIFEST" || { m_bad=$((m_bad + 1))
      printf '     ↳ %s is named in the boot prompt but NOT in core-manifest.txt — it will not travel\n' "$s"; }
  done
  [ "$m_bad" -eq 0 ] && ok "MANIFEST TEST: every boot check the prompt names ships in core-manifest.txt" \
                     || bad "MANIFEST TEST: $m_bad boot check(s) named in the prompt do NOT ship — INERT on every adopter"
fi

# ── 3. NEGATIVE CONTROLS — prove this suite can go RED on the real bugs ──────────────────────────
# 3a. the unescaped-backtick form (bug #1)
bad_sub='REGROUND_PROMPT="RE-GROUND: then run `'"'"'${_CORE_SCRIPTS}'"'"'/memory-orphan-check.sh` and `${_CORE_SCRIPTS}/memory-budget-check.sh` (if present)."'
raw_a="$(render_adopter 'REGROUND_PROMPT="RE-GROUND: then run `${_CORE_SCRIPTS}/memory-orphan-check.sh` and `${_CORE_SCRIPTS}/memory-budget-check.sh` (if present)."')"
p_a="${raw_a%__SANDBOX__*}"; rm -rf "${raw_a##*__SANDBOX__}"
case "$p_a" in
  *CANARY_EXECUTED*) ok "negative control #1: the unescaped-backtick form IS caught (canary fired)" ;;
  *) bad "negative control #1 FAILED — this suite cannot detect command substitution; its green means nothing" ;;
esac

# 3b. the repo-relative form (bug #2) — must NOT resolve from an adopter's cwd
raw_b="$(render_adopter 'REGROUND_PROMPT="RE-GROUND: then run \`scripts/memory-orphan-check.sh\` (if present)."')"
p_b="${raw_b%__SANDBOX__*}"; S_b="${raw_b##*__SANDBOX__}"
cmd_b="$(printf '%s' "$p_b" | grep -oE '`[^`]*memory-orphan-check\.sh[^`]*`' | tr -d '`' | head -1)"
out_b="$(cd "$S_b/adopter" && bash -c "$cmd_b" 2>&1)"
rm -rf "$S_b"
case "$out_b" in
  *CANARY_EXECUTED*) bad "negative control #2 FAILED — a repo-relative check appeared to resolve on an adopter; the deploy test cannot detect bug #2" ;;
  *) ok "negative control #2: the repo-relative form does NOT resolve on an adopter (the deploy test can go RED)" ;;
esac

# 3c. a check NAMED core-absolute but never SHIPPED (absent from the core) — the manifest-miss bug.
# Same shape as #2 but a different root cause: the path is right, the file simply isn't there because
# nothing put it in core-manifest.txt. Simulated by stubbing NOTHING while the prompt names a check.
raw_c="$(STUB_CHECKS='' render_adopter 'REGROUND_PROMPT="RE-GROUND: then run \`${_CORE_SCRIPTS}/memory-orphan-check.sh\`."')"
p_c="${raw_c%__SANDBOX__*}"; S_c="${raw_c##*__SANDBOX__}"
cmd_c="$(printf '%s' "$p_c" | grep -oE '`[^`]*memory-orphan-check\.sh[^`]*`' | tr -d '`' | head -1)"
out_c="$(cd "$S_c/adopter" && bash -c "$cmd_c" 2>&1)"
rm -rf "$S_c"
case "$out_c" in
  *CANARY_EXECUTED*) bad "negative control #3 FAILED — an unshipped check appeared to run; the deploy test cannot detect a manifest miss" ;;
  *) ok "negative control #3: a named-but-unshipped check does NOT run on an adopter (the deploy test can go RED)" ;;
esac

# 3d. a MIXED prompt — one well-formed core-absolute check plus one repo-relative one. The extraction
# in §2 must pick up BOTH, or a repo-relative check hides behind a correct sibling: BOOT_CHECKS only
# ever contains the \${_CORE_SCRIPTS} form, so a name-filtered extraction would silently drop the bad
# one and report green. This control asserts the extractor is command-shaped, not name-shaped.
raw_d="$(render_adopter 'REGROUND_PROMPT="RE-GROUND: run \`${_CORE_SCRIPTS}/memory-orphan-check.sh\` and \`scripts/memory-budget-check.sh\`."')"
p_d="${raw_d%__SANDBOX__*}"; S_d="${raw_d##*__SANDBOX__}"
n_d="$(printf '%s' "$p_d" | grep -oE '`[^`]*[A-Za-z0-9_-]+\.sh[^`]*`' | grep -c .)"
d_bad=0
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  out="$(cd "$S_d/adopter" && bash -c "$cmd" 2>&1)"
  case "$out" in *CANARY_EXECUTED*) ;; *) d_bad=$((d_bad + 1)) ;; esac
done <<< "$(printf '%s' "$p_d" | grep -oE '`[^`]*[A-Za-z0-9_-]+\.sh[^`]*`' | tr -d '`')"
rm -rf "$S_d"
if [ "$n_d" -eq 2 ] && [ "$d_bad" -eq 1 ]; then
  ok "negative control #4: a repo-relative check hiding beside a correct one IS extracted and DOES fail"
else
  bad "negative control #4 FAILED — extracted $n_d/2 command(s), $d_bad/1 failed to resolve; a repo-relative check could hide behind a well-formed sibling"
fi

# ── 4. PROSE names core scripts too — and NOTHING checked those ──────────────────────────────
# §3c models "named core-absolute but never SHIPPED", but its input set is only the REGROUND_PROMPT's
# BOOT_CHECKS. CLAUDE.md and the SKILLS also tell the coordinator to run `$KICKOFF_CORE_DIR/scripts/<x>`,
# and nothing held those against the shipped tree.
#
# That gap shipped a live one (found 2026-08-07): the coordinator's charter says to measure its own
# context degradation with `$KICKOFF_CORE_DIR/scripts/context-headroom.py`. The file was tracked on the
# development branch but was never carried into the PUBLIC release tree, so on a pull adopter — whose
# $KICKOFF_CORE_DIR is a checkout of the public tag — the path simply did not exist and the command 127'd.
# The only mechanical defence against a silently degrading session was inert. It hid because the practice
# is deliberately NEVER run at boot, so the boot-list guard above could not have covered it.
#
# WHAT THIS ASSERTS, and why it is existence and not manifest-membership: $KICKOFF_CORE_DIR is a FULL
# checkout of the tag (101 scripts at core-v0.26 vs 39 manifest entries), so a script is runnable there
# iff it is IN THE TREE. core-manifest.txt is a separate contract — an EXISTENCE GUARD that makes `pull`
# refuse a tag missing a declared file (scripts/kickoff, "refusing to pin a partial core"). Asserting
# manifest-membership here would false-flag legitimately-referenced non-contract scripts (e.g. the
# agent-mail selftest, which a shipped skill names and which ships in the tree).
#
# Same failure class as bug #2 in this file's header — an instruction that resolves HERE (where the repo
# IS the core) and 127s on an adopter — one layer up: prose instead of the prompt.
MANIFEST="$HERE/core-manifest.txt"
TREE_ROOT="$HERE/.."

# Every `$KICKOFF_CORE_DIR/scripts/<file>` named in ANY markdown in the tree, repo-root-relative.
core_paths_in_prose() {
  local root="$1"
  find "$root" -name '.git' -prune -o -name '*.md' -type f -print 2>/dev/null \
    | xargs grep -ohE '\$\{?KICKOFF_CORE_DIR\}?/scripts/[A-Za-z0-9._-]+' 2>/dev/null \
    | sed -E 's#.*/scripts/#scripts/#' | sort -u
}
# Report each referenced path MISSING from the tree (one per line; empty ⇒ every reference resolves).
missing_from_tree() {
  local root="$1" p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -e "$root/$p" ] || printf '%s\n' "$p"
  done <<< "$(core_paths_in_prose "$root")"
}

n_ref="$(core_paths_in_prose "$TREE_ROOT" | grep -c . || true)"
if [ "$n_ref" -eq 0 ]; then
  bad "4: extracted ZERO \$KICKOFF_CORE_DIR/scripts/... references from any markdown under $TREE_ROOT — the extractor is broken (the shipped skills alone name several), so this check would pass vacuously forever"
else
  miss="$(missing_from_tree "$TREE_ROOT")"
  if [ -n "$miss" ]; then
    bad "4: prose instructs the coordinator to run core script(s) ABSENT from this tree — the path 127s on a pull adopter, whose \$KICKOFF_CORE_DIR is a checkout of exactly this tree: $(printf '%s' "$miss" | tr '\n' ' ')"
  else
    ok "4: every core script named in prose ($n_ref) exists in this tree — the path resolves on an adopter"
  fi
fi

# 4b. NEGATIVE CONTROL — the same production helper, against a tree where a referenced script is
# absent, MUST report it. Without this, a silently-broken extractor (or a find that matches nothing)
# reports green forever and the guard is decoration. Builds a throwaway tree rather than touching ours.
ctl_first="$(core_paths_in_prose "$TREE_ROOT" | head -1)"
if [ -n "$ctl_first" ]; then
  ctl_root="$(mktemp -d)"
  mkdir -p "$ctl_root/scripts"
  printf 'run `$KICKOFF_CORE_DIR/%s` at a boundary.\n' "$ctl_first" > "$ctl_root/CTL.md"
  ctl_miss="$(missing_from_tree "$ctl_root")"        # the script is deliberately NOT created there
  rm -rf "$ctl_root"
  case "$ctl_miss" in
    *"$ctl_first"*) ok "negative control #5: a referenced script ABSENT from the tree IS detected (the check can go RED)" ;;
    *)              bad "negative control #5 FAILED — a missing $ctl_first went UNDETECTED; check 4 cannot fail and proves nothing" ;;
  esac
else
  bad "negative control #5: no reference to build a control from — check 4 is unverifiable"
fi

# 4c. MANIFEST EXISTENCE GUARD — separate contract, same failure if broken. `kickoff pull` refuses a
# tag whose manifest lists a file the checkout lacks ("refusing to pin a partial core"), so a manifest
# entry without its file BRICKS every adopter's upgrade. Assert the release cannot ship that way.
if [ ! -r "$MANIFEST" ]; then
  bad "4c: cannot read core-manifest.txt ($MANIFEST)"
else
  mf_missing=""
  while IFS= read -r p; do
    case "$p" in ''|\#*) continue ;; esac
    [ -e "$TREE_ROOT/$p" ] || mf_missing="$mf_missing $p"
  done < "$MANIFEST"
  if [ -n "$mf_missing" ]; then
    bad "4c: core-manifest.txt lists file(s) MISSING from this tree — \`kickoff pull\` would refuse to pin this tag for EVERY adopter:$mf_missing"
  else
    ok "4c: every core-manifest.txt entry exists in this tree — \`pull\` can pin this tag"
  fi
fi

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
