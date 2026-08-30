#!/usr/bin/env bash
# memory-orphan-selftest.sh — prove the orphan check can actually FAIL.
#
#   bash scripts/memory-orphan-selftest.sh
#
# This suite exists because the check shipped WITHOUT one, and an adversarial gate then found it was
# fail-open in exactly the scenario it was written to catch:
#   · it scanned only DIRECT children of $ROOT, so a repo at ~/code/tournament-app — literally the
#     motivating example in its own header — produced "✓ every live project (0) is visible", exit 0.
#   · it SUBSTRING-matched the index, so a live repo `acme` was "visible" because the index said `acmed`.
# Both printed a reassuring green. A check that cannot fail is worse than no check, so every case here
# is RED-first: assert the check FIRES on the bad input, not merely that it passes on the good one.
# Hermetic (mktemp fixtures, never the live $HOME).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
OC="$HERE/memory-orphan-check.sh"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -x "$OC" ] || [ -r "$OC" ] || { printf '  ❌ memory-orphan-check.sh not found at %s\n' "$OC"; exit 1; }

# mkrepo <path> — a git repo with one commit (a "recent activity" live signal).
mkrepo() {
  mkdir -p "$1"
  ( cd "$1" && git init -q . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m x ) 2>/dev/null
}
idx() { printf '# Memory Index\n%s\n' "${1:-}"; }

# ── 1. RED-first: a NESTED live repo is an orphan (the old direct-children-only fail-open) ───────
S=$(mktemp -d); mkrepo "$S/code/tournament-app"; idx "- [x](x.md) — unrelated" > "$S/M.md"
out=$(bash "$OC" "$S" "$S/M.md" 2>&1); rc=$?
case "$out" in *"ORPHAN: tournament-app"*) ok "nested repo (~/code/<repo>) is FOUND and flagged as an orphan" ;;
  *) bad "nested repo NOT found — the check is blind below depth 1 (its own motivating example)" ;; esac
[ "$rc" -eq 1 ] && ok "exit 1 on an orphan (blocks nothing, but reports loudly)" || bad "expected exit 1 on an orphan, got $rc"
rm -rf "$S"

# ── 2. RED-first: substring must NOT count as "in the index" ──────────────────────────────────────
S=$(mktemp -d); mkrepo "$S/acme"; idx "- [Pay](p.md) — acmed processing rules" > "$S/M.md"
out=$(bash "$OC" "$S" "$S/M.md" 2>&1)
case "$out" in *"ORPHAN: acme"*) ok "'acme' is an orphan even though the index says 'acmed' (no substring pass)" ;;
  *) bad "SUBSTRING FAIL-OPEN: 'acme' counted as visible because the index contains 'acmed'" ;; esac
rm -rf "$S"

# ── 3. a genuinely-indexed project is NOT an orphan (guard against a check that always fires) ─────
# Fixture names here are INVENTED on purpose. A test needs a realistic SHAPE, never a real identity:
# reaching for a real adopter's name put a denylisted term into this file and the release gate's
# leak-scan caught it at the core-v0.10 cut. An identity that arrives incidentally (a convenient
# fixture name) is a leak; one that arrives deliberately (a named proof story) is a decision — and
# only the second kind ever belongs in a tracked file.
S=$(mktemp -d); mkrepo "$S/orders-service"; idx "- [Orders](o.md) — orders-service is the billing backend" > "$S/M.md"
out=$(bash "$OC" "$S" "$S/M.md" 2>&1); rc=$?
case "$out" in *"ORPHAN"*) bad "FALSE POSITIVE: an indexed project was reported as an orphan" ;;
  *) ok "an indexed project is not flagged (the check is not just always-red)" ;; esac
[ "$rc" -eq 0 ] && ok "exit 0 when every live project is visible" || bad "expected exit 0 on a clean tree, got $rc"
rm -rf "$S"

# ── 4. hyphen boundary: 'orders' must not be satisfied by 'orders-service' ────────────────────────
# NB the link label must not contain the project name either — "[Orders](o.md)" would legitimately
# mention `orders` and mask what this case exists to prove ([[fixture-can-mask-the-bug-it-should-catch]]).
S=$(mktemp -d); mkrepo "$S/orders"; idx "- [Billing](o.md) — orders-service notes" > "$S/M.md"
out=$(bash "$OC" "$S" "$S/M.md" 2>&1)
case "$out" in *"ORPHAN: orders"*) ok "'orders' is an orphan despite 'orders-service' in the index (hyphen is a boundary)" ;;
  *) bad "'orders' wrongly satisfied by 'orders-service' — a real orphan would hide behind a longer name" ;; esac
rm -rf "$S"

# ── 4b. the repo that OWNS the index is never an orphan TO it ────────────────────────────────────
# RED-first: the index names the owning repo only INSIDE a longer filename, which the name-boundary
# rule (case 4) correctly refuses — so without the owner-skip the repo self-flags on every boot.
S=$(mktemp -d); mkrepo "$S/myproj"
idx "- [North star](myproj-north-star-and-values.md) — the thesis" > "$S/myproj/M.md"
out=$(bash "$OC" "$S" "$S/myproj/M.md" 2>&1)
case "$out" in *"ORPHAN: myproj"*) bad "the index's OWN repo self-flagged as an orphan (fires for every adopter, every boot)" ;;
  *) ok "the repo that owns the index is not an orphan to it" ;; esac
rm -rf "$S"

# ── 4c. a pinned kickoff-core clone is an ENGINE, not a project ──────────────────────────────────
# Its commits are release artifacts, so it would red for ~ORPHAN_DAYS after every release.
S=$(mktemp -d); mkrepo "$S/kickoff-core"; mkdir -p "$S/kickoff-core/scripts"
touch "$S/kickoff-core/scripts/core-manifest.txt"
idx "- [x](x.md) — y" > "$S/M.md"
out=$(bash "$OC" "$S" "$S/M.md" 2>&1)
case "$out" in *"ORPHAN: kickoff-core"*) bad "a pinned core clone flagged as an orphan project (noise after every release)" ;;
  *) ok "a pinned kickoff-core clone is skipped (engine, not a project)" ;; esac
rm -rf "$S"

# ── 4e. an ENGINE-SOURCE index repo: siblings are OTHER projects, adopted on their own schedule ──
# On a second machine running kickoff's own tree, every sibling under $HOME is the operator's
# OTHER project — invisible to THIS index BY DESIGN until each adopts its own memory (then it
# self-skips via its own MEMORY.md). Flagging them trains the reader to ignore real orphans.
# RED-first: the pre-fix check flags the bare sibling even when the index's own repo is engine-source.
S=$(mktemp -d); mkrepo "$S/engine-repo"; mkdir -p "$S/engine-repo/scripts"
touch "$S/engine-repo/scripts/core-manifest.txt"     # the engine-source heuristic (upgrade-turnkey's)
mkrepo "$S/bare-sibling"                             # live, un-adopted → the noise fixture
idx "- [x](x.md) — y" > "$S/engine-repo/M.md"
out=$(bash "$OC" "$S" "$S/engine-repo/M.md" 2>&1); rc=$?
case "$out" in
  *"engine-source repo"*) ok "engine-source index repo: the un-adopted sibling is NOT flagged (adoption is per-project)" ;;
  *"ORPHAN: bare-sibling"*) bad "an engine-source repo's un-adopted sibling flagged as an orphan — noise, not signal" ;;
  *) bad "engine-source guard produced unexpected output: ${out:-<none>}" ;; esac
[ "$rc" -eq 0 ] && ok "…and exits 0 (advisory quiet — never blocks a boot)" || bad "expected exit 0, got $rc"
# NEGATIVE control: the same sibling under a PLAIN repo must still flag — the guard keys on the
# index repo being engine-source, not on the sibling's existence (a guard that ate the real
# detection would green here too).
S2=$(mktemp -d); mkrepo "$S2/plain-repo"; mkrepo "$S2/bare-sibling"
idx "- [x](x.md) — y" > "$S2/plain-repo/M.md"
out=$(bash "$OC" "$S2" "$S2/plain-repo/M.md" 2>&1)
case "$out" in *"ORPHAN: bare-sibling"*) ok "negative control: a plain repo still flags the bare sibling" ;;
  *) bad "negative control FAILED — the engine-source guard ate the real orphan detection" ;; esac
rm -rf "$S" "$S2"


# ── 4d. A REAL-SIZED INDEX — the pipe-buffer flake ───────────────────────────────────────────────
# Every fixture above uses a TINY index, and a tiny index CANNOT reproduce this bug — which is why
# this suite was green for hours while the live check flapped 3-of-5 runs on the real 67KB MEMORY.md.
# `printf "$idx" | grep -q` under `set -o pipefail` returns 141 (SIGPIPE) once the haystack exceeds
# the ~64KB pipe buffer: grep -q exits at the first match, the still-writing printf dies, and pipefail
# surfaces the WRITER's death as the pipeline status → a project that IS indexed reports as an ORPHAN.
# Racy by nature, so assert over MANY runs: one false orphan in N is the bug.
# ([[pipefail-sigpipe-grep-flake]] — banked, then written anyway.)
S=$(mktemp -d); mkrepo "$S/realproj"
{ printf '# Memory Index\n- [Real](realproj.md) — realproj is the live one\n'
  # pad well past the pipe buffer with realistic index lines
  i=0; while [ "$i" -lt 900 ]; do
    printf -- '- [Filler %s](filler-%s.md) — %s\n' "$i" "$i" "$(head -c 60 /dev/zero | tr '\0' 'x')"
    i=$((i + 1))
  done
} > "$S/M.md"
sz=$(wc -c < "$S/M.md")
flakes=0
for _ in $(seq 1 12); do
  bash "$OC" "$S" "$S/M.md" 2>&1 | grep -q 'ORPHAN: realproj' && flakes=$((flakes + 1))
done
if [ "$flakes" -eq 0 ]; then
  ok "a REAL-SIZED index (${sz}B > the 64KB pipe buffer) resolves deterministically — 12/12 runs"
else
  bad "PIPE-BUFFER FLAKE: an INDEXED project reported as an orphan in $flakes/12 runs on a ${sz}B index — \`printf | grep -q\` under pipefail dies of SIGPIPE; use a here-string"
fi
rm -rf "$S"

# ── 5. an EMPTY scan must not report a green all-clear ────────────────────────────────────────────
S=$(mktemp -d); idx "- [x](x.md) — y" > "$S/M.md"       # no repos at all
out=$(bash "$OC" "$S" "$S/M.md" 2>&1)
case "$out" in
  *"✓ every live project (0) is visible"*) bad "A CHECK THAT CANNOT FAIL: an empty scan printed a green all-clear" ;;
  *"no live project found"*) ok "an empty scan reports a finding about the SCAN, not a false all-clear" ;;
  *) bad "empty scan produced unexpected output: ${out:-<none>}" ;;
esac
rm -rf "$S"

# ── 6. vendored trees are pruned (a big \$HOME must not stall a boot) ─────────────────────────────
S=$(mktemp -d); mkrepo "$S/app/node_modules/some-dep"; idx "- [x](x.md) — y" > "$S/M.md"
out=$(bash "$OC" "$S" "$S/M.md" 2>&1)
case "$out" in *"some-dep"*) bad "a repo inside node_modules was scanned — vendored trees must be pruned" ;;
  *) ok "node_modules is pruned (a vendored repo is not a project)" ;; esac
rm -rf "$S"

# ── 7. depth is tunable, and the default reaches a nested repo ────────────────────────────────────
S=$(mktemp -d); mkrepo "$S/a/b/deep-repo"; idx "- [x](x.md) — y" > "$S/M.md"
out=$(ORPHAN_DEPTH=1 bash "$OC" "$S" "$S/M.md" 2>&1)
case "$out" in *"ORPHAN: deep-repo"*) bad "ORPHAN_DEPTH=1 still found a depth-3 repo — the knob does nothing" ;;
  *) ok "ORPHAN_DEPTH is honoured (depth 1 does not reach a depth-3 repo)" ;; esac
rm -rf "$S"

# ── 8. missing index → exit 0, never a boot-blocking failure ──────────────────────────────────────
S=$(mktemp -d)
out=$(bash "$OC" "$S" "$S/does-not-exist.md" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "a missing index exits 0 (an advisory check must never block a boot)" \
                || bad "a missing index exited $rc — this runs at boot and must fail open"
rm -rf "$S"

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && printf '  ✅ orphan check enforced (RED on nested · substring · empty-scan; GREEN when truly visible)\n'
[ "$FAIL" -eq 0 ]
