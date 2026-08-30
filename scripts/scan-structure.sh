#!/usr/bin/env bash
# scan-structure.sh — generic structural / footgun scanner (claude-kickoff)
#
# Stack-light checks for the structural footguns we have actually SEEN bite a
# real build (a prior-adopter audit + a production go-live). It is ADVISORY by
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

# Saved BEFORE the arg-parse loop below, which SHIFTS "$@" empty. Forwarding "$@" to a workspace
# member therefore forwarded NOTHING and every member ran with DEFAULT scope: for scan-secrets
# that only over-scans, but for scan-structure it drops --strict, which is fail-OPEN. The fan-out
# shipped with this; adversarial review caught it. Placement matters — saving it after the loop
# (the first attempt) captures the already-emptied array and looks identical to a fix.
_KICKOFF_ARGV_SAVED=( "$@" )

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

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# --- workspace mode -------------------------------------------------------
# THE MULTI-REPO ROOT (2026-08-04). kickoff can be mounted on a ROOT folder holding N sibling
# repos — "a monorepo split across repos". The coordinator half of that already works; this half
# did not. From such a root there is no git work tree, so the guard below refused and the org got
# NO structural scan at all: the right failure direction (never a false green) but no coverage.
#
# If cwd is not itself a repo but CONTAINS repos, scan each. Each child runs inside a real work
# tree, so the logic below is reached unchanged — no second implementation to drift.
#
# FAIL-CLOSED PRESERVED AT BOTH ENDS: a root with zero sub-repos still refuses, and any member
# that fails fails the whole run.
#
# WORKSPACE-NESS IS AN EXPLICIT MARKER, NOT AN INFERENCE (v0.25) — `.kickoff/workspace`, written by
# `kickoff adopt`/`doctor` at a non-git root and TRACKED, so it survives a fresh clone. A marked
# root may be a git repo AND a workspace: members scanned, and the root's own tracked files too.
# (The rule is the twin of scan-secrets.sh's — see the long note there for why the marker is
# required rather than inferred, and for the three shapes of a `.git` FILE.)
KICKOFF_WS_MARKER=".kickoff/workspace"

kickoff_is_member_repo() {       # $1 = candidate dir → rc 0 when it is a workspace member
  local _gd
  [ -d "$1/.git" ] && return 0
  [ -f "$1/.git" ] || return 1
  _gd="$(sed -n 's/^gitdir:[[:space:]]*//p' "$1/.git" 2>/dev/null | head -n1)"
  case "$_gd" in
    */worktrees/*)                    return 1 ;;   # a linked worktree is never a member
    .git/modules/*|*/.git/modules/*)  return 0 ;;   # a submodule is
    *)                                return 1 ;;   # --separate-git-dir: not ours to claim
  esac
}

workspace_members() {
  local d
  for d in */ ; do
    kickoff_is_member_repo "${d%/}" && printf '%s\n' "${d%/}"
  done
}

# A directory we cannot look INTO is the quietest fail-open there is: `[ -d "$d/.git" ]` simply
# returns false, so the entry never becomes a member and the aggregate reports "clean across N
# repos" having never opened it. Unreadable entries fail the run instead. An unreadable `.git`
# FILE is the same fail-open one level down — since a submodule became a member, deciding
# membership can require READING `$d/.git`, and a failed read fell through to "not a member".
workspace_unreadable() {
  local d
  for d in */ ; do
    d="${d%/}"
    [ -d "$d" ] || continue
    if [ ! -r "$d" ] || [ ! -x "$d" ]; then printf '%s\n' "$d"; continue; fi
    if [ -f "$d/.git" ] && [ ! -r "$d/.git" ]; then printf '%s\n' "$d"; fi
  done
}

# TWO ARMS, and the LEGACY one is byte-identical to what shipped: no marker + not inside a work
# tree ⇒ exactly the old rule. The NEW arm is reachable only with the marker on disk.
#
# THE QUESTION IS "IS THIS ROOT'S OWN CONTENT TRACKED", NOT "IS IT THE TOPLEVEL" — a marked root
# nested inside another work tree is fully tracked there, and asking `show-toplevel = pwd` dropped
# it from the fan-out entirely (see the twin note in scan-secrets.sh: a committed key in the org's
# own CLAUDE.md scanned RED before the marker and GREEN after).
_ws_mode=0; _ws_scan_root=0; _ws_root_is_top=0; _ws_top=""
if [ "${KICKOFF_WORKSPACE_CHILD:-0}" != "1" ]; then
  if [ -f "$KICKOFF_WS_MARKER" ]; then
    _ws_mode=1
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      _ws_scan_root=1
      _ws_pwd="$(pwd -P)"
      _ws_top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
      [ -n "$_ws_top" ] && _ws_top="$(cd "$_ws_top" 2>/dev/null && pwd -P || printf '%s' "$_ws_top")"
      [ "$_ws_top" = "$_ws_pwd" ] && _ws_root_is_top=1
    fi
  elif ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    _ws_mode=1
  fi
fi
# SCOPE FORK — `--staged` at a marked git root is the ROOT's own commit being scored; fanning out
# there would block it on a NEIGHBOUR's staged files. pre-push (`all`) aggregates root + members.
if [ "$_ws_scan_root" = 1 ] && [ "$SCOPE" = "staged" ]; then
  _ws_mode=0; _ws_scan_root=0
fi
if [ "$_ws_mode" = 1 ]; then
  members=(); while IFS= read -r m; do [ -n "$m" ] && members+=("$m"); done < <(workspace_members)
  # The unreadable sweep runs BEFORE the members>0 fork — nested inside it, a marked GIT root whose
  # ONLY candidate member is unreadable enumerated zero members, never named the directory, and
  # exited 0 through the plain root scan (see the twin note in scan-secrets.sh).
  unreadable=(); while IFS= read -r u; do [ -n "$u" ] && unreadable+=("$u"); done < <(workspace_unreadable)
  if [ "${#members[@]}" -eq 0 ] && [ "${#unreadable[@]}" -eq 0 ] && [ "$_ws_scan_root" = 1 ]; then
    echo "⚠ scan-structure.sh: $PWD carries the workspace marker ($KICKOFF_WS_MARKER) but holds ZERO member repos — scanning this root only" >&2
  fi
  if [ "${#members[@]}" -gt 0 ] || [ "${#unreadable[@]}" -gt 0 ]; then
    echo "▶ scan-structure.sh: workspace mode — ${#members[@]} repo(s) under $PWD"
    if [ "$_ws_root_is_top" = 1 ]; then
      echo "  (…and this root is itself a git repo — its own tracked files are scanned too)"
    elif [ "$_ws_scan_root" = 1 ]; then
      echo "  (…and this root's own files are tracked by the git repo at ${_ws_top:-?} — they are scanned too)"
    fi
    ws_rc=0; ws_failed=()
    if [ "${#unreadable[@]}" -gt 0 ]; then
      ws_rc=1; ws_failed+=("${unreadable[@]}")
      echo "🔴 unreadable director(ies) — cannot tell if they are repos, refusing to call this clean: ${unreadable[*]}" >&2
    fi
    for m in "${members[@]}"; do
      echo
      echo "── $m ───────────────────────────────────────────────"
      ( cd "$m" && KICKOFF_WORKSPACE_CHILD=1 bash "$SELF" "${_KICKOFF_ARGV_SAVED[@]}" ) || { ws_rc=1; ws_failed+=("$m"); }
    done
    ws_tot="${#members[@]}"
    # The root is one more unit, reached by re-entering THIS script with the recursion guard set.
    if [ "$_ws_scan_root" = 1 ]; then
      ws_tot=$((ws_tot+1))
      echo
      echo "── (this root) ──────────────────────────────────────"
      ( KICKOFF_WORKSPACE_CHILD=1 bash "$SELF" "${_KICKOFF_ARGV_SAVED[@]}" ) || { ws_rc=1; ws_failed+=("(this root)"); }
    fi
    echo
    if [ "$ws_rc" -ne 0 ]; then
      echo "🔴 scan-structure.sh: workspace FAILED in: ${ws_failed[*]}" >&2
    else
      echo "✅ scan-structure.sh: workspace clean across $ws_tot repo(s)"
    fi
    exit "$ws_rc"
  fi
fi

# FAIL CLOSED, not open: `git ls-files 2>/dev/null || true` from a non-git cwd yielded an
# EMPTY list and a green "no footguns" on ZERO files (rc=0). Both scopes here are git-backed;
# a legitimately-empty real repo (0 tracked files) still passes green.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "🔴 scan-structure.sh: not inside a git work tree (cwd: $PWD) — refusing to report green on zero files" >&2
  exit 2
fi

list_files() {
  if [ "$SCOPE" = "staged" ]; then
    git diff --cached --name-only --diff-filter=ACM
  else
    git ls-files
  fi
}

# capture ONCE and check git's exit status — inside a `< <(list_files)` process substitution
# a git failure is silently swallowed and reads as "0 files".
FILE_LIST="$(list_files)" || { echo "🔴 scan-structure.sh: git file listing failed — cannot scan" >&2; exit 2; }

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

  # 7. suppressed-error-then-count assertions (shell): `foo 2>/dev/null | … | wc -l`
  #    silently reads a FAILING command as "0 found" — the count swallows the error and a
  #    false result flows on downstream. ADVISORY ONLY (never HIGH): a linter genuinely
  #    can't tell a legitimate probe (`git rev-parse --verify X 2>/dev/null | wc -l`) from a
  #    masking assertion, so this is a heads-up to eyeball, NOT a gate. One finding per file.
  case "$f" in
    *.sh|*.bash)
      sup=$(grep -cE '2>/dev/null[^|]*\|.*wc[[:space:]]+-l' "$f" 2>/dev/null || true)
      if [ "${sup:-0}" -gt 0 ]; then
        add LOW "$f" "${sup} suppressed-error-then-count assertion(s) (2>/dev/null | … | wc -l) — a failing command reads as 0; check the exit status separately, don't count a masked error"
      fi ;;
  esac

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
done <<< "$FILE_LIST"

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
