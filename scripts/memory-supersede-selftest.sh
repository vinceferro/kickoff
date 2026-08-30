#!/usr/bin/env bash
# memory-supersede-selftest.sh — prove the "a correction DELETES what it corrects" invariant.
#
#   bash scripts/memory-supersede-selftest.sh
#
# RED-first: the load-bearing assertion is that the check FAILS (exit 1) on the VIOLATING
# input — a memory that supersedes a file still present on disk — and only goes GREEN once
# that file is deleted. Also covers: fail-closed on a malformed field, the frontmatter-only
# guard (prose mentions of "supersedes:" don't trip it), multi-slug lists, and the git-backed
# typo guard (a legitimately-deleted slug ≠ a typo'd slug). Hermetic (mktemp fixtures).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SC="$HERE/memory-supersede-check.sh"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

# run the check against a memory dir → sets RC (exit code) + OUT (combined output)
run() { OUT="$(bash "$SC" "$1" 2>&1)"; RC=$?; }

mem() { # mem <dir> <slug> <extra-frontmatter-line-or-empty> <body>
  local d="$1" slug="$2" extra="$3" body="$4"
  { printf '%s\n' '---' "name: $slug"; [ -n "$extra" ] && printf '%s\n' "$extra"; printf '%s\n' '---' "$body"; } > "$d/$slug.md"
}

echo "▶ memory-supersede-check self-test (a correction DELETES what it corrects)"
echo

# ── 1. THE RED CASE: superseded file STILL on disk → exit 1 ──────────────────────────────
F="$(mktemp -d)"
mem "$F" old-wrong-fact "" "The old belief. Body prose even says supersedes: something — a decoy for the frontmatter-only guard."
mem "$F" new-correct-fact "supersedes: old-wrong-fact" "The correction."
run "$F"
chk "RED — superseded file present makes the check FAIL (exit 1)"  "[ $RC -eq 1 ]"
chk "RED — it names the contradiction LOUDLY"                       "printf '%s' \"\$OUT\" | grep -q 'CONTRADICTION'"
chk "RED — it points at the file that STILL EXISTS"                 "printf '%s' \"\$OUT\" | grep -q 'STILL EXISTS'"

# ── 2. THE GREEN CASE: delete the superseded file → exit 0 ───────────────────────────────
rm "$F/old-wrong-fact.md"
run "$F"
chk "GREEN — deleting the superseded file makes it pass (exit 0)"   "[ $RC -eq 0 ]"
rm -rf "$F"

# ── 3. frontmatter-only guard: a BODY mention of supersedes: is ignored ──────────────────
F="$(mktemp -d)"
mem "$F" a-fact "" "This body discusses supersedes: another-fact but declares nothing in frontmatter."
run "$F"
chk "prose 'supersedes:' in the BODY is NOT treated as a declaration (exit 0)" "[ $RC -eq 0 ]"
chk "reports nothing to enforce"  "printf '%s' \"\$OUT\" | grep -q 'nothing to enforce'"
rm -rf "$F"

# ── 4. malformed fields fail CLOSED (exit 1) ─────────────────────────────────────────────
F="$(mktemp -d)"
mem "$F" empty-decl "supersedes:" "empty value"
run "$F"
chk "empty supersedes: field fails closed (exit 1)"  "[ $RC -eq 1 ] && printf '%s' \"\$OUT\" | grep -q 'MALFORMED'"
rm "$F/empty-decl.md"
mem "$F" traversal "supersedes: ../../etc/passwd" "path traversal token"
run "$F"
chk "path-traversal token fails closed (exit 1)"     "[ $RC -eq 1 ] && printf '%s' \"\$OUT\" | grep -q 'MALFORMED'"
rm -rf "$F"

# ── 5. multi-slug list — one still present → exit 1 ; both absent → exit 0 ────────────────
F="$(mktemp -d)"
mem "$F" present-a "" "still here"
mem "$F" corr "supersedes: present-a, absent-b" "correction citing two"
run "$F"
chk "a comma-list with ONE present slug fails (exit 1)"  "[ $RC -eq 1 ]"
rm "$F/present-a.md"
run "$F"
chk "same list with BOTH absent passes (exit 0)"         "[ $RC -eq 0 ]"
rm -rf "$F"

# ── 6. git typo guard: deleted-with-history ≠ never-existed ──────────────────────────────
if command -v git >/dev/null 2>&1; then
  F="$(mktemp -d)"
  ( cd "$F" && git init -q && git config user.email t@t.t && git config user.name t )
  mem "$F" was-real "" "a fact that will be retired"
  ( cd "$F" && git add -A && git commit -qm seed )
  rm "$F/was-real.md"                                   # legitimately deleted → HAS git history
  mem "$F" corr "supersedes: was-real, never-typo" "correction"
  ( cd "$F" && git add -A && git commit -qm corr )
  run "$F"
  chk "git — a legitimately-retired slug is NOT a typo note" "printf '%s' \"\$OUT\" | grep -q 'correctly retired was-real'"
  chk "git — a never-existed slug IS a soft typo note"       "printf '%s' \"\$OUT\" | grep -q 'typo.*never-typo'"
  chk "git — a typo alone stays advisory (exit 0)"           "[ $RC -eq 0 ]"
  rm -rf "$F"
else
  echo "  ⚠ git not found — skipping the typo-guard checks"
fi

# ── 7. NESTED memories are covered (the 2026-07-22 inert-check regression) ───────────────
# The check used to glob ONE level (`"$MEMDIR"/*.md`). The 07-20 public/private split then
# moved 94 of 154 facts into memory/private/, so lefthook's argument-less invocation scanned
# only the public 60 and printed "no supersedes: declared — nothing to enforce" while a real
# contradiction sat nested and unenforced. These assertions go RED against the flat-glob
# version (verified by running it against `git show <pre-fix>:scripts/memory-supersede-check.sh`).
F="$(mktemp -d)"
mkdir -p "$F/private"
mem "$F/private" nested-old-fact "" "The stale nested belief."
mem "$F/private" nested-new-fact "supersedes: nested-old-fact" "The correction, also nested."
run "$F"
chk "NESTED — a contradiction in a subdir is CAUGHT (exit 1)"      "[ $RC -eq 1 ]"
chk "NESTED — it names the contradiction"                          "printf '%s' \"\$OUT\" | grep -q 'CONTRADICTION'"
chk "NESTED — it prints the REAL relative path, not memory/<slug>" "printf '%s' \"\$OUT\" | grep -q 'private/nested-old-fact.md STILL EXISTS'"
rm "$F/private/nested-old-fact.md"
run "$F"
chk "NESTED — deleting the superseded nested file passes (exit 0)"  "[ $RC -eq 0 ]"
# A superseder at the TOP level must still find its slug nested below it (and vice versa) —
# otherwise a correction that moves a fact public→private would read as "correctly retired".
mem "$F" top-new-fact "supersedes: cross-level-old" "Top-level correction of a nested fact."
mem "$F/private" cross-level-old "" "The stale fact, one level down."
run "$F"
chk "CROSS-LEVEL — top-level superseder finds its slug nested"      "[ $RC -eq 1 ]"
rm -rf "$F"

# ── 8. the LIVE repo memory/ is clean (refresh-safe) ─────────────────────────────────────
run "$HERE/../memory"
chk "the live memory/ dir passes the supersede check (exit 0)"  "[ $RC -eq 0 ]"

echo
echo "──────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "  ✅ supersede invariant enforced (RED on a live contradiction, GREEN once deleted)"; exit 0; } || { echo "  ❌ see failures above"; exit 1; }
