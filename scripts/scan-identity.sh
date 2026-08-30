#!/usr/bin/env bash
# scan-identity.sh — catch a private name or a machine path at the moment it is WRITTEN.
#
#   scripts/scan-identity.sh --staged     # pre-commit: only what you are about to commit
#   scripts/scan-identity.sh              # working tree, added-vs-HEAD
#   scripts/scan-identity.sh --all        # every tracked file (audit mode; expect inherited hits)
#
# WHY THIS EXISTS (2026-07-30, after the SECOND release-time cleanup). The identity denylist was
# consulted by exactly one thing — release-gate.sh — which is the LAST possible moment. By then the
# name is committed, often inherited across tags, and the fix is a scrub of history nobody can
# actually undo, because a public tag cannot be unpublished. Twice now a release has been held while
# someone removed a project name that had been sitting in a comment for weeks.
#
# The guard belongs where the mistake happens. This runs on pre-commit and looks ONLY at lines you
# are ADDING, so:
#   * writing a private project name into a comment fails the commit, while you still remember why
#     you typed it and can choose a generic phrasing in five seconds;
#   * the thousands of lines that already mention deliberately-published names never re-fire, so the
#     guard stays quiet enough to be believed.
#
# That added-lines-only scope is the whole design. A guard that also flags inherited content gets
# disabled within a week, and a disabled guard is worth less than no guard because it is still
# believed. Audit mode (--all) exists for the deliberate sweep; it is not what the hook runs.
#
# ESCAPE HATCH, on purpose: DELIBERATE publication is a real thing (a case-study name the operator
# has chosen to ship). ALLOW_IDENTITY=1 git commit … proceeds and SAYS SO. A guard with no sanctioned
# way past it gets bypassed with --no-verify, which disables every other gate too.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# The repo under inspection is the CALLER'S, never this script's own. A pre-commit hook runs inside
# the repo being committed, and an adopter's engine lives in a separate pinned clone — resolving
# "$HERE/.." would scan the engine and silently pass every one of the caller's commits. That exact
# origin-is-not-the-deployment slip cost three separate fixes on 2026-07-30 alone; it is written here
# so the next edit does not reintroduce it.
# NB `A || B && C` parses as `(A || B) && C`, so the obvious one-liner runs BOTH branches and
# captures two paths. Explicit if/else instead.
if REPO="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$REPO" ]; then :; else
  REPO="$(cd "$HERE/.." && pwd)"
fi
DENY="${IDENTITY_DENYLIST:-$REPO/.kickoff/leak-denylist.txt}"
SCOPE="working"
for a in "$@"; do
  case "$a" in
    --staged) SCOPE=staged ;;
    --all)    SCOPE=all ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "scan-identity: unknown option: $a" >&2; exit 2 ;;
  esac
done

cd "$REPO" || exit 2

# ── the terms ────────────────────────────────────────────────────────────────────────────────
# No denylist is not "clean" — it is "unconfigured". Say so and pass, because this hook must never
# block a fresh clone that has not set one up; the release gate is the fail-CLOSED backstop.
if [ ! -r "$DENY" ]; then
  [ "$SCOPE" = staged ] || echo "scan-identity: no denylist at $DENY — nothing to check (the release gate fails closed on this)."
  exit 0
fi
TERMS="$(grep -vE '^\s*#|^\s*$' "$DENY" 2>/dev/null | sed 's/[[:space:]]*$//' | grep -v '^$' || true)"
[ -n "$TERMS" ] || exit 0

# ── what to look at ──────────────────────────────────────────────────────────────────────────
# Added lines only (the '+' side), except in audit mode. `git diff -U0` keeps the payload small and
# means a rename or a reflow of untouched text cannot trip the hook.
case "$SCOPE" in
  staged)  DIFF="$(git diff --cached -U0 --no-color -- . 2>/dev/null)" ;;
  working) DIFF="$(git diff HEAD -U0 --no-color -- . 2>/dev/null)" ;;
  all)     DIFF="" ;;
esac

hits=0
report() { printf '  %s\n' "$1"; hits=$((hits+1)); }

scan_added() {   # $1 = regex, $2 = label
  local re="$1" label="$2"
  # NET-NEW ONLY: report a term when it appears MORE times on the '+' side than the '-' side of the
  # same file. Counting '+' alone cannot distinguish "I added a private name" from "I edited a line
  # that already contained one" — and the second is constant, because names live in prose people keep
  # revising. Seen immediately: a commit that REMOVED one denylisted term was blocked, because the
  # same rewritten line still carried a different pre-existing one. A guard that fires on ordinary
  # editing is a guard that gets bypassed, which is the exact failure this design is scoped to avoid.
  # Comparing both sides restores the intent: you may not INCREASE the occurrences.
  printf '%s\n' "$DIFF" | awk -v re="$re" -v label="$label" '
    function flush(  i, shown) {
      shown = addc - delc
      for (i = 1; i <= an && shown > 0; i++) { printf "  %s: %s\n     %s\n", label, f, substr(plus[i],1,110); shown-- }
      an = 0; addc = 0; delc = 0
    }
    /^\+\+\+ b\// { flush(); f = substr($0,7); next }
    # CASE-FOLDED both sides: a name leaks just as well in CamelCase or ALLCAPS, and a guard matching
    # only the form you typed is blind to the variant that actually ships.
    /^\+/ && !/^\+\+\+/ { l = substr($0,2); if (tolower(l) ~ tolower(re)) { addc++; plus[++an] = l } next }
    /^-/  && !/^---/    { l = substr($0,2); if (tolower(l) ~ tolower(re)) { delc++ } next }
    END { flush() }'
}

if [ "$SCOPE" = all ]; then
  # Audit mode: whole tracked tree. Inherited hits are EXPECTED here — this is the sweep, not the hook.
  echo "▶ identity audit (whole tree — inherited hits are expected)"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    n="$(git grep -ilF -- "$t" 2>/dev/null | wc -l | tr -d ' ')"
    [ "$n" -gt 0 ] && report "term '$t' appears in $n tracked file(s)"
  done <<< "$TERMS"
  [ "$hits" -eq 0 ] && echo "  ✓ no denylisted term in the tracked tree"
  exit 0
fi

[ -n "$DIFF" ] || exit 0

OUT=""
while IFS= read -r t; do
  [ -n "$t" ] || continue
  # Case-insensitive, and matched as a bare substring: a private name leaks just as well in
  # CamelCase, in a URL, or glued to punctuation. The release-gate's own lesson is that a
  # literal-form-only guard is blind to the variant that actually ships.
  esc="$(printf '%s' "$t" | sed 's/[][\.*^$(){}?+|/]/\\&/g')"
  found="$(scan_added "$esc" "denylisted name '$t'" 2>/dev/null | grep -i -A1 "denylisted name" || true)"
  [ -n "$found" ] && OUT="$OUT$found
"
done <<< "$TERMS"

# Machine paths: structural, so no denylist entry can cover them and they leak the box itself.
for pat in "/home/[a-z_][a-z0-9_.-]{2,}/" "-home-[a-z0-9_]+-" "/tmp/claude-[0-9]+/"; do
  found="$(scan_added "$pat" "machine path" 2>/dev/null || true)"
  [ -n "$found" ] && OUT="$OUT$found
"
done

if [ -z "${OUT//[[:space:]]/}" ]; then
  exit 0
fi

if [ "${ALLOW_IDENTITY:-0}" = 1 ]; then
  echo "scan-identity: ALLOW_IDENTITY=1 — proceeding with a DELIBERATE identity reference:"
  printf '%s' "$OUT"
  exit 0
fi

echo "✗ scan-identity: this change ADDS a private name or a machine path."
printf '%s' "$OUT"
cat <<'EOF'
  Why this blocks here and not at release: by release time the line is committed, usually inherited,
  and a public tag cannot be unpublished. Right now it is one edit.

  Options:
    · rephrase generically ("a sibling repo", "an adopted checkout", "$HOME/…") — usually as clear
    · if this reference is DELIBERATE (a case-study name you intend to publish):
        ALLOW_IDENTITY=1 git commit …
    · to change the policy itself, edit .kickoff/leak-denylist.txt
EOF
exit 1
