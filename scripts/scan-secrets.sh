#!/usr/bin/env bash
# scan-secrets.sh — generic, language-agnostic secret scanner (claude-kickoff)
#
# A footgun scanner shipped in the template and run by the `scan`/`harden` skills
# and the pre-commit hook (lefthook.yml). No external dependencies — just git +
# grep + coreutils, so it runs on any machine the moment the repo is cloned.
#
# It catches the leaks a non-technical builder can't be expected to spot:
# committed .env files, private keys, cloud/vendor credentials, and — the
# lesson from a prior adopter audit — a server-only "service role" key
# referenced from client-side code.
#
# Usage:
#   scripts/scan-secrets.sh                 # scan all tracked files (default)
#   scripts/scan-secrets.sh --staged        # scan only git-staged files (pre-commit)
#   scripts/scan-secrets.sh --warn-only      # never exit non-zero (advisory)
#   scripts/scan-secrets.sh path/a path/b    # scan explicit paths
#
# Exit: 1 if any finding (it is a HARD gate — secrets must never land), else 0.
# Suppress a single false positive by putting `pragma: allowlist secret` on the line.
# Skip paths by listing globs (one per line) in a `.scanignore` file at the repo root.

set -euo pipefail

# Saved BEFORE the arg-parse loop below, which SHIFTS "$@" empty. Forwarding "$@" to a workspace
# member therefore forwarded NOTHING and every member ran with DEFAULT scope: for scan-secrets
# that only over-scans, but for scan-structure it drops --strict, which is fail-OPEN. The fan-out
# shipped with this; adversarial review caught it. Placement matters — saving it after the loop
# (the first attempt) captures the already-emptied array and looks identical to a fix.
_KICKOFF_ARGV_SAVED=( "$@" )

SCRIPT_NAME="$(basename "$0")"
WARN_ONLY=0
SCOPE="all"
declare -a EXPLICIT=()

while [ $# -gt 0 ]; do
  case "$1" in
    --staged) SCOPE="staged" ;;
    --all) SCOPE="all" ;;
    --warn-only) WARN_ONLY=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) EXPLICIT+=("$1") ;;
  esac
  shift
done

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# --- workspace mode -------------------------------------------------------
# THE MULTI-REPO ROOT (2026-08-04). kickoff can be mounted on a ROOT folder holding N sibling
# repos — "a monorepo split across repos". The coordinator half of that already works; this half
# did not. From such a root there is no git work tree, so the guard below refused and the org got
# NO secret scan at all: the right failure direction (never a false green) but no coverage.
#
# So: if cwd is not itself a repo but CONTAINS repos, scan each of them. Each child invocation
# runs inside a real work tree, which means the scanning logic below is reached unchanged — no
# second implementation to drift out of sync with this one.
#
# FAIL-CLOSED IS PRESERVED AT BOTH ENDS: a root with zero sub-repos still refuses (it is not a
# workspace, it is a mistake), and any sub-repo that fails makes the whole run fail. A workspace
# scan that skipped an unreadable member and still reported green would be the exact
# report-green-on-nothing bug this guard exists to prevent.
#
# WORKSPACE-NESS IS AN EXPLICIT MARKER, NOT AN INFERENCE (v0.25). "is this a workspace?" used to be
# "is the root NOT a git repo?", which made the two mutually exclusive — so a workspace root could
# never be a git repo and an org's own charter/tracker/memory/agents could never be version-
# controlled. `.kickoff/workspace` (tracked; `kickoff adopt`/`doctor` write it at a non-git root)
# now decides, and a marked root may be BOTH: its members are scanned AND its own tracked files are.
# The marker is required rather than inferred because inference is unsafe in the other direction —
# an ordinary repo that happens to contain a nested checkout would be silently promoted.
KICKOFF_WS_MARKER=".kickoff/workspace"

# ── WHO IS A MEMBER: `.git` as a DIRECTORY, or a SUBMODULE's `.git` FILE ─────────────────────
# `[ -d "$d/.git" ]` was the whole test and it is FALSE for a submodule — git puts a FILE there
# reading `gitdir: ../.git/modules/<name>`. Measured with this scanner: a planted AWS key inside a
# submodule produced "no secrets found (all scope)", rc 0 — a silent false green, the exact class
# this fan-out exists to close.
#
# `.git`-AS-A-FILE HAS THREE SHAPES, not two, and only ONE of them is a member:
#   submodule          `gitdir: ../.git/modules/<n>`     → A MEMBER: its own index + work tree.
#   linked worktree    `gitdir: /…/.git/worktrees/<n>`   → NOT a member: another checkout of a repo
#                      we already cover, whose hooks live outside it (a prior release deliberately
#                      stopped arming worktrees for exactly that reason).
#   --separate-git-dir `gitdir: /an/arbitrary/dir`       → NOT a member: nothing marks it as part of
#                      this workspace, so a "not-a-worktree ⇒ member" rule would silently promote it.
# So match the submodule form POSITIVELY on its `/modules/` path segment — never as "not a
# worktree", and never on absoluteness (the submodule form is relative and the worktree form
# absolute in the probe, but neither spelling is guaranteed by git).
kickoff_is_member_repo() {       # $1 = candidate dir → rc 0 when it is a workspace member
  local _gd
  [ -d "$1/.git" ] && return 0
  [ -f "$1/.git" ] || return 1
  _gd="$(sed -n 's/^gitdir:[[:space:]]*//p' "$1/.git" 2>/dev/null | head -n1)"
  case "$_gd" in
    */worktrees/*)                    return 1 ;;
    .git/modules/*|*/.git/modules/*)  return 0 ;;
    *)                                return 1 ;;
  esac
}

workspace_members() {
  # Immediate children only. Depth is deliberate: a workspace is a flat root of checkouts, and
  # recursing further would wander into vendored/nested repos nobody asked to scan.
  local d
  for d in */ ; do
    kickoff_is_member_repo "${d%/}" && printf '%s\n' "${d%/}"
  done
}

# A directory we cannot look INTO is the quietest fail-open there is: `[ -d "$d/.git" ]` simply
# returns false, so the entry never becomes a member, and the aggregate happily reports "clean
# across N repos" having never opened it. Found by this suite's own unreadable-member case on the
# first run of this code. Unreadable entries are reported and fail the run — a directory that
# might be a repo and cannot be read is not a pass.
#
# AN UNREADABLE `.git` FILE IS THE SAME FAIL-OPEN, one level down. Since a submodule became a
# member, "is this a member?" can require READING `$d/.git` — and when that read fails,
# kickoff_is_member_repo's catch-all says "not a member", so the directory vanishes from the run
# with the aggregate still green (measured: a submodule holding a committed AWS key, `chmod 000
# sub/.git`, "clean across 2 repo(s)", rc 0). Indeterminate is not clean: report it.
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
# tree ⇒ exactly the old rule, so every existing adopter takes exactly the old path. The NEW arm is
# reachable only with the marker on disk.
#   _ws_scan_root=1 ⇒ this root's own files are under git, so after the members it is scanned too —
#   requirement (c). Skipping it would be a NEW false green: a secret committed into the root's own
#   CLAUDE.md or .claude/agents/*.md would pass while the fan-out reported "workspace clean".
#
# THE QUESTION IS "IS THIS ROOT'S OWN CONTENT TRACKED", NOT "IS IT THE TOPLEVEL". The first
# spelling asked `show-toplevel = pwd`, which is FALSE for a workspace root nested inside another
# work tree (an org folder inside a dotfiles/monorepo checkout) — a root that is fully tracked by
# the enclosing repo. That root was then neither a scanned unit of the fan-out nor covered by
# anything else: measured, a committed AWS key in its own CLAUDE.md scanned RED before the marker
# existed and GREEN after it, rc 0. `--is-inside-work-tree` is the question the coverage actually
# depends on; the toplevel answer is only used to WORD the line below.
_ws_mode=0; _ws_scan_root=0; _ws_root_is_top=0; _ws_top=""
if [ "${#EXPLICIT[@]}" -eq 0 ] && [ "${KICKOFF_WORKSPACE_CHILD:-0}" != "1" ]; then
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
# SCOPE FORK — the root's own pre-commit must NOT fan out. `--staged` at a marked git root is the
# ROOT's commit being scored; fanning out there would block a root commit because a NEIGHBOUR has a
# secret staged (the mirror of the member-scoping bug the shims already fixed). Each member's own
# pre-commit scans its own index. `all` scope (the `scan`/`harden` run, and pre-push) aggregates.
if [ "$_ws_scan_root" = 1 ] && [ "$SCOPE" = "staged" ]; then
  _ws_mode=0; _ws_scan_root=0
fi
if [ "$_ws_mode" = 1 ]; then
  members=(); while IFS= read -r m; do [ -n "$m" ] && members+=("$m"); done < <(workspace_members)
  # THE UNREADABLE SWEEP RUNS BEFORE THE members>0 FORK, never inside it. Nested in the fork it was
  # unreachable in the one shape where it matters most: a marked GIT root whose ONLY candidate
  # member is unreadable enumerates ZERO members, so the guard never ran, the directory was never
  # named, and the run fell through to the plain root scan and exited 0 — a pre-commit/pre-push
  # gate passing over a repo it could not open. Fail-closed must not depend on the root's shape.
  unreadable=(); while IFS= read -r u; do [ -n "$u" ] && unreadable+=("$u"); done < <(workspace_unreadable)
  if [ "${#members[@]}" -eq 0 ] && [ "${#unreadable[@]}" -eq 0 ] && [ "$_ws_scan_root" = 1 ]; then
    # An EXPLICIT marker with zero members is a misconfiguration, not a pass. The root is still a
    # real repo so the scan below covers it — say plainly that it covers nothing else.
    echo "⚠ $SCRIPT_NAME: $PWD carries the workspace marker ($KICKOFF_WS_MARKER) but holds ZERO member repos — scanning this root only" >&2
  fi
  if [ "${#members[@]}" -gt 0 ] || [ "${#unreadable[@]}" -gt 0 ]; then
    echo "▶ $SCRIPT_NAME: workspace mode — ${#members[@]} repo(s) under $PWD"
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
      # KICKOFF_WORKSPACE_CHILD stops a member that is itself a root from fanning out again.
      ( cd "$m" && KICKOFF_WORKSPACE_CHILD=1 bash "$SELF" "${_KICKOFF_ARGV_SAVED[@]}" ) || { ws_rc=1; ws_failed+=("$m"); }
    done
    ws_tot="${#members[@]}"
    # THE ROOT IS ONE MORE UNIT, not a short-circuit. Re-entering THIS script with the recursion
    # guard set is what reaches the ordinary single-repo logic below unchanged — no second
    # implementation to drift, and the aggregate rc still fails on either half.
    if [ "$_ws_scan_root" = 1 ]; then
      ws_tot=$((ws_tot+1))
      echo
      echo "── (this root) ──────────────────────────────────────"
      ( KICKOFF_WORKSPACE_CHILD=1 bash "$SELF" "${_KICKOFF_ARGV_SAVED[@]}" ) || { ws_rc=1; ws_failed+=("(this root)"); }
    fi
    echo
    if [ "$ws_rc" -ne 0 ]; then
      echo "🔴 $SCRIPT_NAME: workspace FAILED in: ${ws_failed[*]}" >&2
    else
      echo "✅ $SCRIPT_NAME: workspace clean across $ws_tot repo(s)"
    fi
    exit "$ws_rc"
  fi
fi

# --- file list -------------------------------------------------------------
# FAIL CLOSED, not open: `git ls-files 2>/dev/null || true` from a non-git cwd yielded an
# EMPTY list and a green "no secrets found" on ZERO files (rc=0 — a secret gate passing on
# nothing). Guard the git-backed scopes up front; explicit paths need no git, and a
# legitimately-empty real repo (0 tracked files) still passes green.
if [ "${#EXPLICIT[@]}" -eq 0 ] && ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "🔴 $SCRIPT_NAME: not inside a git work tree (cwd: $PWD) — refusing to report green on zero files" >&2
  exit 2
fi

list_files() {
  if [ "${#EXPLICIT[@]}" -gt 0 ]; then
    printf '%s\n' "${EXPLICIT[@]}"
  elif [ "$SCOPE" = "staged" ]; then
    git diff --cached --name-only --diff-filter=ACM
  else
    git ls-files
  fi
}

# capture ONCE and check git's exit status — inside a `< <(list_files)` process substitution
# a git failure is silently swallowed and reads as "0 files".
FILE_LIST="$(list_files)" || { echo "🔴 $SCRIPT_NAME: git file listing failed — cannot scan" >&2; exit 2; }

# Always-skip: the scanners themselves (they contain the patterns by design),
# lockfiles, vendored/build dirs, and anything the repo lists in .scanignore.
should_skip() {
  local f="$1"
  case "$f" in
    scripts/scan-secrets.sh|scripts/scan-structure.sh|.scanignore) return 0 ;;
    */node_modules/*|node_modules/*|*/dist/*|dist/*|*/.git/*|*/vendor/*|vendor/*) return 0 ;;
    *.lock|*-lock.json|*-lock.yaml|*.min.js|*.map) return 0 ;;
  esac
  [ -f "$f" ] || return 0   # skip deleted/missing
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

# --- secret patterns: "ERE<TAB>SEVERITY<TAB>label" ------------------------
# grep -I skips binary files; -n gives line numbers; -E extended regex.
PATTERNS=$(cat <<'PAT'
-----BEGIN (RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----	CRITICAL	private key block
AKIA[0-9A-Z]{16}	CRITICAL	AWS access key id
sk_live_[0-9A-Za-z]{20,}	CRITICAL	Stripe live secret key
rk_live_[0-9A-Za-z]{20,}	CRITICAL	Stripe live restricted key
AIza[0-9A-Za-z_-]{35}	HIGH	Google API key
gh[pousr]_[0-9A-Za-z]{36,}	HIGH	GitHub token
xox[baprs]-[0-9A-Za-z-]{10,}	HIGH	Slack token
"private_key"[[:space:]]*:[[:space:]]*"[^"]{40,}	HIGH	GCP service-account private key
glpat-[0-9A-Za-z_-]{20,}	HIGH	GitLab personal access token
npm_[0-9A-Za-z]{36}	HIGH	npm access token
eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}	HIGH	JWT (if a service-role/secret key: remove; if a public anon/publishable key: allowlist)
[a-z][a-z0-9+.-]*://[^/[:space:]:@"']+:[^/[:space:]:@"']+@	HIGH	credentials embedded in a URL/connection string
sk_test_[0-9A-Za-z]{20,}	MEDIUM	Stripe test secret key
PAT
)

# Generic "<secret-ish name> = '<long literal>'" assignment (case-insensitive).
# A quoted literal of 12+ non-space chars — env reads (process.env.X, ${X}) stay unquoted, so they don't match.
GENERIC_ERE='(secret|token|password|passwd|api[_-]?key|access[_-]?key|client[_-]?secret|auth[_-]?token|private[_-]?key)["'"'"']?[[:space:]]*[:=]>?[[:space:]]*["'"'"'][^"'"'"'[:space:]]{12,}'

# Obvious placeholders / non-literals to drop (keeps the gate velocity-first).
# Includes config env-references (env(VAR) — Supabase/etc.) and HTML autocomplete tokens.
# `\$\(` was added 2026-08-04: `${VAR}` was treated as a placeholder but Makefile/shell
# `$(VAR)` was not, so a perfectly correct env-driven Makefile
# (`postgres://$(DB_USERNAME):$(DB_PASSWORD)@...`) produced four HIGH findings. Found on the
# first real workspace scan — four of that adopter's 22 findings were this one gap, and an
# adopter whose first run cries wolf learns to ignore the gate.
PLACEHOLDER='pragma: allowlist secret|process\.env|os\.environ|import\.meta\.env|getenv|System\.getenv|ENV\[|env\(|<[^>]*>|\$\{|\$\(|\bexample\b|\bplaceholder\b|\bchangeme\b|\bredacted\b|\bdummy\b|\bsample\b|\bfake\b|\bmock\b|\blocalhost\b|127\.0\.0\.1|your[-_]|xxxxxx|\*\*\*|test[_-]|[_-]test|new-password|current-password|one-time-code'

declare -a FINDINGS=()

scan_one() {
  local f="$1" hits ere sev label
  # built-in named patterns. NOTE the `--`: several patterns start with `-` (the
  # private-key block), which grep would otherwise parse as an option (a silent
  # total miss — caught in adversarial review).
  while IFS=$'\t' read -r ere sev label; do
    [ -z "$ere" ] && continue
    hits=$(grep -InE -- "$ere" "$f" 2>/dev/null || true)
    [ -z "$hits" ] && continue
    while IFS= read -r line; do
      echo "$line" | grep -qiE "$PLACEHOLDER" && continue
      FINDINGS+=("$sev	$f:${line%%:*}	$label	$(redact "${line#*:}")")
    done <<< "$hits"
  done <<< "$PATTERNS"
  # generic assignment pattern. Test files are NOT exempted (a renamed *.test.* file
  # would otherwise bypass the gate); fixture credentials are filtered by PLACEHOLDER.
  hits=$(grep -IniE -- "$GENERIC_ERE" "$f" 2>/dev/null || true)
  if [ -n "$hits" ]; then
    while IFS= read -r line; do
      echo "$line" | grep -qiE "$PLACEHOLDER" && continue
      FINDINGS+=("HIGH	$f:${line%%:*}	hardcoded credential literal	$(redact "${line#*:}")")
    done <<< "$hits"
  fi
  # service-role key referenced from client-side code (prior-adopter footgun)
  case "$f" in
    */src/*|src/*|*/app/*|app/*|*/components/*|*/pages/*|*/public/*|public/*|*/web/*|*.client.*|*.tsx|*.jsx|*.vue|*.svelte)
      hits=$(grep -IniE 'service[_-]?role|SUPABASE_SERVICE|SERVICE_ROLE_KEY' "$f" 2>/dev/null || true)
      if [ -n "$hits" ]; then
        while IFS= read -r line; do
          echo "$line" | grep -qiE "$PLACEHOLDER" && continue
          FINDINGS+=("HIGH	$f:${line%%:*}	server-only service-role key referenced in client code	$(redact "${line#*:}")")
        done <<< "$hits"
      fi ;;
  esac
}

# Redact the secret value so it never prints to a log. Two passes: mask the
# contents of any quoted string (≥8 inner chars — catches values with punctuation),
# then mask any long credential-shaped run (≥10 — catches unquoted tokens, and the
# 12+ char generic-gate matches the 16-char rule used to miss).
redact() {
  printf '%s' "$1" \
    | sed -E "s#([\"'])[^\"']{8,}([\"'])#\1***REDACTED***\2#g" \
    | sed -E 's#[A-Za-z0-9_+/=.@!#%&-]{10,}#***REDACTED***#g' \
    | cut -c1-100
}

# --- committed .env files (whole-file finding) -----------------------------
while IFS= read -r f; do
  [ -z "$f" ] && continue
  should_skip "$f" && continue
  case "$f" in
    .env|.env.*|*/.env|*/.env.*)
      case "$f" in *.example|*.sample|*.template|*.dist) ;; *) FINDINGS+=("CRITICAL	$f	committed .env file	env files must be gitignored, not committed") ;; esac ;;
  esac
done <<< "$FILE_LIST"

# --- content scan ----------------------------------------------------------
while IFS= read -r f; do
  [ -z "$f" ] && continue
  should_skip "$f" && continue
  scan_one "$f"
done <<< "$FILE_LIST"

# --- report ----------------------------------------------------------------
if [ "${#FINDINGS[@]}" -eq 0 ]; then
  echo "✅ scan-secrets: no secrets found ($SCOPE scope)"
  exit 0
fi

echo "🔴 scan-secrets: ${#FINDINGS[@]} potential secret(s) found"
echo
# rank CRITICAL > HIGH > MEDIUM, then print
for sev in CRITICAL HIGH MEDIUM; do
  for row in "${FINDINGS[@]}"; do
    [ "${row%%	*}" = "$sev" ] || continue
    rest="${row#*	}"; loc="${rest%%	*}"
    rest="${rest#*	}"; label="${rest%%	*}"; snippet="${rest#*	}"
    printf '  [%s] %s\n        %s\n        %s\n' "$sev" "$loc" "$label" "$snippet"
  done
done
echo
echo "If a finding is a false positive, add 'pragma: allowlist secret' to that line"
echo "or a path glob to .scanignore. Real secrets: remove, rotate, and load from env."

[ "$WARN_ONLY" -eq 1 ] && exit 0
exit 1
