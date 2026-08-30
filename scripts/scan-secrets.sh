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

# --- file list -------------------------------------------------------------
list_files() {
  if [ "${#EXPLICIT[@]}" -gt 0 ]; then
    printf '%s\n' "${EXPLICIT[@]}"
  elif [ "$SCOPE" = "staged" ]; then
    git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true
  else
    git ls-files 2>/dev/null || true
  fi
}

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
PLACEHOLDER='pragma: allowlist secret|process\.env|os\.environ|import\.meta\.env|getenv|System\.getenv|ENV\[|env\(|<[^>]*>|\$\{|\bexample\b|\bplaceholder\b|\bchangeme\b|\bredacted\b|\bdummy\b|\bsample\b|\bfake\b|\bmock\b|\blocalhost\b|127\.0\.0\.1|your[-_]|xxxxxx|\*\*\*|test[_-]|[_-]test|new-password|current-password|one-time-code'

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
done < <(list_files)

# --- content scan ----------------------------------------------------------
while IFS= read -r f; do
  [ -z "$f" ] && continue
  should_skip "$f" && continue
  scan_one "$f"
done < <(list_files)

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
