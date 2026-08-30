#!/usr/bin/env bash
# scan-structure.sh — generic structural / footgun scanner (claude-kickoff)
#
# Stack-light checks for the structural footguns we have actually SEEN bite a
# real build (a prior-adopter audit + the Bliz go-live). It is ADVISORY by
# default — it prints a ranked findings list that the `harden` skill consumes
# and closes; it does not block a commit. Run it with --strict to fail on a
# HIGH finding (used as an opt-in gate).
#
# No external dependencies — git + grep + coreutils. Language-agnostic: the
# checks key on portable shapes (line counts, SQL, promise chains) and degrade
# gracefully when a signal doesn't apply to the stack.
#
# Usage:
#   scripts/scan-structure.sh            # advisory: print findings, exit 0
#   scripts/scan-structure.sh --strict   # exit 1 if any HIGH finding
#   scripts/scan-structure.sh --staged   # only consider staged files
#
# Footguns checked:
#   - oversized files (>800 LOC hard to reason about / review)
#   - data-loss writes (DELETE/UPDATE without WHERE; full-overwrite update calls)
#   - broad data-access grants (RLS USING(true) / WITH CHECK(true) / GRANT ALL)
#   - missing ErrorBoundary in a React app
#   - promise chains with no .catch (unhandled rejection)
#   - engine-fragile CSS that can't be verified headless (unprefixed backdrop-filter, color-mix oklch)

set -euo pipefail

STRICT=0
SCOPE="all"
BIG=800        # hard threshold (HIGH)
WARN=500       # soft threshold (MEDIUM)

while [ $# -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1 ;;
    --staged) SCOPE="staged" ;;
    --all) SCOPE="all" ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
  esac
  shift
done

list_files() {
  if [ "$SCOPE" = "staged" ]; then
    git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true
  else
    git ls-files 2>/dev/null || true
  fi
}

should_skip() {
  local f="$1"
  case "$f" in
    scripts/scan-secrets.sh|scripts/scan-structure.sh|.scanignore) return 0 ;;
    */node_modules/*|node_modules/*|*/dist/*|dist/*|*/.git/*|*/vendor/*|vendor/*|*/build/*) return 0 ;;
    *.lock|*-lock.json|*-lock.yaml|*.min.js|*.min.css|*.map|*.snap) return 0 ;;
    *.tsbuildinfo) return 0 ;;   # generated build cache (was suppressing the ErrorBoundary check)
  esac
  [ -f "$f" ] || return 0
  if [ -f .scanignore ]; then
    while IFS= read -r pat; do
      [ -z "$pat" ] && continue
      case "$pat" in \#*) continue ;; esac
      # shellcheck disable=SC2254
      case "$f" in $pat) return 0 ;; esac
    done < .scanignore
  fi
  return 1
}

declare -a FINDINGS=()
add() { FINDINGS+=("$1	$2	$3"); }   # severity, location, message

is_code_for_size() {
  case "$1" in
    *.json|*.csv|*.tsv|*.svg|*.md|*.markdown|*.txt|*.html|*.xml|*.yaml|*.yml|*.po|*.lock) return 1 ;;
    *) return 0 ;;
  esac
}

REACT_HINT=0
HAS_ERROR_BOUNDARY=0

while IFS= read -r f; do
  [ -z "$f" ] && continue
  should_skip "$f" && continue
  grep -Iq . "$f" 2>/dev/null || continue   # skip binary / empty files

  # Documentation files hold cautionary prose (e.g. "don't use unprefixed
  # backdrop-filter") — never run the code-shape heuristics on them.
  IS_DOC=0
  case "$f" in *.md|*.markdown|*.txt|*.rst|*.adoc) IS_DOC=1 ;; esac
  IS_TEST=0
  case "$f" in *.test.*|*.spec.*|*_test.*|*/__tests__/*|*/tests/*|*/test/*) IS_TEST=1 ;; esac

  # 1. oversized files (test files run long by nature — cap them at MEDIUM so the
  # HIGH tier stays focused on oversized source).
  if [ "$IS_DOC" -eq 0 ] && is_code_for_size "$f"; then
    loc=$(wc -l < "$f" 2>/dev/null | tr -d ' ' || echo 0)
    if [ "${loc:-0}" -gt "$BIG" ]; then
      if [ "$IS_TEST" -eq 1 ]; then
        add MEDIUM "$f" "large test file (${loc} LOC) — consider splitting by scenario"
      else
        add HIGH "$f" "oversized file (${loc} LOC > ${BIG}) — split it; large files hide bugs and resist review"
      fi
    elif [ "${loc:-0}" -gt "$WARN" ]; then
      add MEDIUM "$f" "large file (${loc} LOC > ${WARN}) — consider splitting"
    fi
  fi

  if [ "$IS_DOC" -eq 0 ]; then
  # 2. data-loss writes
  while IFS= read -r m; do
    add HIGH "$f:${m%%:*}" "DELETE without WHERE — deletes every row (data loss)"
  done < <(grep -IniE 'delete[[:space:]]+from[[:space:]]+[a-z0-9_."]+[[:space:]]*(;|$)' "$f" 2>/dev/null | grep -viE 'where' || true)
  while IFS= read -r m; do
    add MEDIUM "$f:${m%%:*}" "UPDATE without WHERE on this line — verify it isn't a full-table overwrite"
  done < <(grep -IniE 'update[[:space:]]+[a-z0-9_."]+[[:space:]]+set[[:space:]]' "$f" 2>/dev/null | grep -viE 'where' || true)
  # ORM .update/.upsert — collapse to one finding per file (a DB-heavy app has many,
  # and most are legitimately scoped; this is a row-scope/merge checklist, not N bugs).
  upd=$(grep -cE '\.(update|upsert)\(' "$f" 2>/dev/null || true)
  if [ "${upd:-0}" -gt 0 ]; then
    add LOW "$f" "${upd} .update/.upsert call(s) — confirm each merges (not overwrites) and is row-scoped"
  fi

  # 3. broad data-access grants
  while IFS= read -r m; do
    add HIGH "$f:${m%%:*}" "broad RLS/grant (USING(true)/WITH CHECK(true)/GRANT ALL) — gates nothing"
  done < <(grep -IniE 'using[[:space:]]*\([[:space:]]*true[[:space:]]*\)|with[[:space:]]+check[[:space:]]*\([[:space:]]*true[[:space:]]*\)|grant[[:space:]]+all' "$f" 2>/dev/null || true)

  # 5. unhandled promise rejections (per-file heuristic)
  case "$f" in
    *.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs|*.vue|*.svelte)
      thens=$(grep -cE '\.then\(' "$f" 2>/dev/null || true)
      catches=$(grep -cE '\.catch\(' "$f" 2>/dev/null || true)
      if [ "${thens:-0}" -gt 0 ] && [ "${catches:-0}" -eq 0 ]; then
        add MEDIUM "$f" "${thens} .then() chain(s) with no .catch() — unhandled rejection risk"
      fi ;;
  esac

  # 6. engine-fragile CSS (can't verify headless — the render-is-not-the-device lesson)
  while IFS= read -r m; do
    add LOW "$f:${m%%:*}" "unprefixed backdrop-filter — add -webkit-backdrop-filter; verify on real Safari/iOS"
  done < <(grep -InE 'backdrop-filter' "$f" 2>/dev/null | grep -viE '\-webkit\-backdrop\-filter' || true)
  while IFS= read -r m; do
    add LOW "$f:${m%%:*}" "color-mix(in oklch …) — engine-fragile; confirm on the target browser"
  done < <(grep -InE 'color-mix\(in oklch' "$f" 2>/dev/null || true)

  if grep -qiE 'errorboundary|componentDidCatch|getDerivedStateFromError' "$f" 2>/dev/null; then
    HAS_ERROR_BOUNDARY=1
  fi
  fi   # end IS_DOC guard

  # React detection (for the ErrorBoundary check below) — extension/path based, safe on docs
  case "$f" in
    *.jsx|*.tsx) REACT_HINT=1 ;;
    package.json) grep -qE '"react"[[:space:]]*:' "$f" 2>/dev/null && REACT_HINT=1 ;;
  esac
  case "$f" in */error.tsx|error.tsx|*/error.jsx|error.jsx) HAS_ERROR_BOUNDARY=1 ;; esac
done < <(list_files)

# 4. missing ErrorBoundary (project-level)
if [ "$REACT_HINT" -eq 1 ] && [ "$HAS_ERROR_BOUNDARY" -eq 0 ]; then
  add MEDIUM "(project)" "React app with no ErrorBoundary — one thrown render crashes the whole UI to a blank screen"
fi

# --- report ----------------------------------------------------------------
if [ "${#FINDINGS[@]}" -eq 0 ]; then
  echo "✅ scan-structure: no structural footguns found ($SCOPE scope)"
  exit 0
fi

high=0
echo "🟠 scan-structure: ${#FINDINGS[@]} finding(s) (advisory — fed to \`harden\`)"
echo
for sev in HIGH MEDIUM LOW; do
  for row in "${FINDINGS[@]}"; do
    [ "${row%%	*}" = "$sev" ] || continue
    [ "$sev" = "HIGH" ] && high=$((high+1))
    rest="${row#*	}"; loc="${rest%%	*}"; msg="${rest#*	}"
    printf '  [%s] %s\n        %s\n' "$sev" "$loc" "$msg"
  done
done
echo
echo "These are candidates for the \`harden\` skill to close. False positive? add a path to .scanignore."

if [ "$STRICT" -eq 1 ] && [ "$high" -gt 0 ]; then
  exit 1
fi
exit 0
