#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# memory-budget-check — the always-loaded index is a per-session context TAX.
#
# memory/MEMORY.md is read at the START of every session, so its size is a cost
# paid on every single session, forever. Left unbounded it silently grows until
# the index ALONE eats a meaningful slice of the context budget — and a degrading
# long session is exactly when you can least afford it. This warns LOUD when the
# index crosses a budget, so it gets compacted BEFORE it hurts.
#
# The index is a CACHE, not the store: the one-fact-per-file memories under
# memory/ are the truth and stay fully searchable by the retrieval hook. Demoting
# a line from MEMORY.md drops a boot-time POINTER, not the fact — so compacting is
# cheap and lossless.
#
#   bash scripts/memory-budget-check.sh [memory_index_path]
#
# Budget (env-overridable; defaults sit ~40% over the current index size):
#   MEMORY_INDEX_BUDGET_LINES  (default 210)
#   MEMORY_INDEX_BUDGET_BYTES  (default 84000)
#
# Over EITHER budget → loud compact/demote guidance + exit 1; under → exit 0.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
INDEX="${1:-}"

# Locate the memory index if not given.
if [ -z "$INDEX" ]; then
  for c in "$REPO/memory/MEMORY.md" "$PWD/memory/MEMORY.md"; do
    [ -f "$c" ] && { INDEX="$c"; break; }
  done
fi
[ -f "${INDEX:-}" ] || { echo "memory-budget-check: no MEMORY.md found (pass one as \$1)" >&2; exit 0; }

# 210 -> 400 (2026-08-09). The thing this guard protects is the per-session context TAX, and
# BYTES measure that directly; the line budget is a proxy for it, calibrated when a pointer
# averaged ~400 bytes (210 x 400 ~= the 84000 byte budget). Compacting the index to real hooks
# — the spec's "one line, a hook, never memory content" — took the average to ~209 bytes, so
# the proxy started binding at roughly HALF the tax it stands for and would have demanded
# demoting live facts while the real budget sat 54% empty. 400 x 209 ~= 84000 restores the
# two gates to the same underlying limit. Re-derive this if the hook style changes again.
LINE_BUDGET="${MEMORY_INDEX_BUDGET_LINES:-400}"
BYTE_BUDGET="${MEMORY_INDEX_BUDGET_BYTES:-84000}"

# Validate the overrides, because an unvalidated one fails OPEN and SILENTLY: `set -uo pipefail` has no
# -e, so `[ "$lines" -gt abc ]` errors to stderr and returns 2, `&& over=1` never fires, and a 5000-line
# index prints "✓ within budget". A typo'd env var must not disable the guard it configures.
for _v in LINE_BUDGET BYTE_BUDGET; do
  eval "_val=\${$_v}"
  case "${_val:-}" in
    ''|*[!0-9]*)
      case "$_v" in
        LINE_BUDGET) _env=MEMORY_INDEX_BUDGET_LINES ;;
        *)           _env=MEMORY_INDEX_BUDGET_BYTES ;;
      esac
      echo "memory-budget-check: $_env='${_val}' is not a non-negative integer — refusing to run a guard that cannot fail." >&2
      exit 2 ;;
  esac
done

lines=$(wc -l < "$INDEX" | tr -d ' ')
bytes=$(wc -c < "$INDEX" | tr -d ' ')

over=0
[ "$lines" -gt "$LINE_BUDGET" ] && over=1
[ "$bytes" -gt "$BYTE_BUDGET" ] && over=1

if [ "$over" -eq 1 ]; then
  echo "  ⚠ memory index OVER BUDGET — MEMORY.md is loaded EVERY session (a context tax)."
  echo "     lines: $lines / $LINE_BUDGET      bytes: $bytes / $BYTE_BUDGET"
  echo "     Compact / demote the index: it is a CACHE, not the store. Drop the weakest"
  echo "     pointer LINE from MEMORY.md — the memory/<slug>.md file stays on disk and fully"
  echo "     searchable by the retrieval hook, so nothing is lost. (Raise the budget with"
  echo "     MEMORY_INDEX_BUDGET_LINES / MEMORY_INDEX_BUDGET_BYTES only if it truly earns its tax.)"
  exit 1
fi
echo "  ✓ memory index within budget (lines $lines/$LINE_BUDGET · bytes $bytes/$BYTE_BUDGET)."
exit 0
