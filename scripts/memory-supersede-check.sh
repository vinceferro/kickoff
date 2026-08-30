#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# memory-supersede-check — "a correction DELETES what it corrects."
#
# Memory is one-fact-per-file. A corrective memory REPLACES the fact(s) it fixes;
# if the old file is left on disk, two memories now CONTRADICT each other and a
# future session can retrieve the STALE one — a silent regression a non-technical
# operator will never see coming. So a corrective memory declares what it kills:
#
#     ---
#     name: new-correct-fact
#     supersedes: old-wrong-fact          # (or:  slug-a, slug-b   /   slug-a slug-b)
#     ---
#
# and this check enforces the truth invariant: every named slug's file MUST be
# GONE (the old fact was deleted, not left to rot).
#
#   - a superseded memory/<slug>.md STILL on disk → LOUD contradiction, exit 1
#   - a supersedes: naming a slug that never existed → soft typo note, exit 0
#   - a malformed supersedes: field → fail CLOSED, exit 1
#
# Deterministic, no model judgement, fails loud instead of silent — same posture
# as memory-orphan-check.sh.
#
#   bash scripts/memory-supersede-check.sh [memory_dir]
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
MEMDIR="${1:-$REPO/memory}"

[ -d "$MEMDIR" ] || { echo "memory-supersede-check: no memory dir at $MEMDIR (pass one as \$1)" >&2; exit 0; }

violations=0
malformed=0
typos=0
declared=0

# git-history probe for the typo guard — best-effort, a no-op without git / outside a repo,
# so a plain (non-git) memory dir still gets the load-bearing "file must be absent" invariant.
git_ok=0
if command -v git >/dev/null 2>&1 && git -C "$MEMDIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_ok=1
fi
ever_existed() {  # $1 = slug ; return 0 = has git history, 1 = none / unknown
  [ "$git_ok" -eq 1 ] || return 1
  # Pathspec must match the slug ANYWHERE in the tree, not just at the top — see the
  # recursion note below. `:(glob)**/` covers nested; the bare form covers top-level.
  [ -n "$(git -C "$MEMDIR" log --all --format=%H -- "$1.md" ":(glob)**/$1.md" 2>/dev/null | head -n1)" ]
}

# Locate a superseded slug ANYWHERE under MEMDIR. The existence test is the load-bearing
# half of this check ("a correction DELETES what it corrects"), so scoping it to the top
# level would fail OPEN for any nested file — reporting green on a live contradiction.
find_slug() {  # $1 = slug ; prints the first matching path, empty if none
  find "$MEMDIR" -type f -name "$1.md" 2>/dev/null | head -n1
}

# Emit ONLY the frontmatter block (between the first two `---` fences). Memory BODIES
# routinely discuss "supersedes" in prose — never let that trip the check.
#
# Robust about the opening fence, because every tolerance here is a FAIL-OPEN: a file whose first line
# is not byte-exactly `---` used to yield "no frontmatter" -> "✓ no supersedes: declared", so a UTF-8 BOM
# (editors add one invisibly) or one leading blank line let a LIVE contradiction pass with a reassuring
# green. Strip a BOM, strip CRLF, and skip leading blanks before demanding the fence.
frontmatter() {
  sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' "$1" 2>/dev/null | awk '
    !started && /^[[:space:]]*$/ { next }                    # leading blank lines: tolerate
    !started { if ($0 !~ /^---[[:space:]]*$/) exit; started=1; next }   # first real line must be the fence
    /^---[[:space:]]*$/ { exit }                             # closing fence: stop
    { print }
  '
}

is_slug() { case "$1" in *[!A-Za-z0-9._-]*|*..*|"") return 1 ;; *) return 0 ;; esac; }

# RECURSE — do NOT glob one level (`"$MEMDIR"/*.md`).
#
# That was the shipped behaviour until 2026-07-22, and it made this check INERT for the
# majority of the store. The 07-20 public/private memory split moved every instance-specific
# fact into `memory/private/` — 94 of 154 files here — and lefthook runs this script with no
# argument, so it scanned the 60 public ones and printed "✓ no supersedes: declared —
# nothing to enforce". Reassuring, and about a world nobody lives in: the corrections that
# actually get made are made in the private half. Found when a real supersedes: declaration
# in memory/private/ was silently not enforced.
#
# NUL-delimited so a path with whitespace can never word-split into two bogus files.
while IFS= read -r -d '' f; do
  base="$(basename "$f")"
  [ "$base" = "MEMORY.md" ] && continue

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    declared=$((declared + 1))
    val="${line#*supersedes:}"
    # A YAML inline comment is legal and must not read as slugs: `supersedes: old  # fixed 2026-01-04`
    # otherwise tokenizes to old/#/fixed/2026-01-04 and the date trips MALFORMED — a false RED that
    # blocks a correct commit. Strip from the first `#` (guarding a value that IS only a comment).
    val="${val%%#*}"
    # normalise: drop YAML inline-list brackets + quotes, treat comma as a separator
    val="${val//[/ }"; val="${val//]/ }"; val="${val//\"/ }"; val="${val//\'/ }"; val="${val//,/ }"

    # Word-split WITHOUT pathname expansion. Unquoted `$val` also globs against the caller's cwd, so
    # `supersedes: *` would expand to whatever files happen to sit there — silently checking real slugs
    # instead of failing closed on a malformed field, which is the documented contract.
    set -f
    got=0
    for slug in $val; do
      slug="${slug%.md}"
      if ! is_slug "$slug"; then
        printf '  ✗ MALFORMED: %s declares a supersedes token %q — not a valid memory slug (fail-closed)\n' "$base" "$slug"
        malformed=$((malformed + 1)); got=$((got + 1)); continue
      fi
      got=$((got + 1))
      hit="$(find_slug "$slug")"
      if [ -n "$hit" ]; then
        # Print the REAL path, not a reconstructed `memory/<slug>.md` — with nesting, the
        # reconstructed one may not exist, and telling someone to delete a file that isn't
        # there is how a true finding gets dismissed as a false positive.
        printf '  ✗ CONTRADICTION: %s supersedes %s — but %s STILL EXISTS\n' "$base" "$slug" "${hit#"$MEMDIR"/}"
        violations=$((violations + 1))
      elif ! ever_existed "$slug"; then
        printf '  ⚠ typo?  %s supersedes %s — no memory/%s.md and no git history for it (check the slug)\n' "$base" "$slug" "$slug"
        typos=$((typos + 1))
      else
        printf '  ✓ %s correctly retired %s (file deleted)\n' "$base" "$slug"
      fi
    done
    set +f

    if [ "$got" -eq 0 ]; then
      printf '  ✗ MALFORMED: %s has an empty supersedes: field (fail-closed)\n' "$base"
      malformed=$((malformed + 1))
    fi
  done < <(frontmatter "$f" | grep -E '^[[:space:]]*supersedes:[[:space:]]*' || true)
done < <(find "$MEMDIR" -type f -name '*.md' -print0 2>/dev/null)

echo
if [ "$violations" -gt 0 ] || [ "$malformed" -gt 0 ]; then
  echo "  ⚠ $violations superseded file(s) still on disk, $malformed malformed field(s)."
  echo "    A correction must DELETE what it corrects — a stale + a corrected memory both on"
  echo "    disk means a future session can retrieve the WRONG one. Delete the superseded"
  echo "    memory/<slug>.md (and drop its MEMORY.md line), or fix the supersedes: field."
  exit 1
fi
if [ "$declared" -eq 0 ]; then
  echo "  ✓ no supersedes: declared — nothing to enforce."
else
  note=""
  [ "$typos" -gt 0 ] && note=", $typos typo note(s)"
  echo "  ✓ every superseded memory was deleted ($declared supersedes field(s) checked$note)."
fi
exit 0
