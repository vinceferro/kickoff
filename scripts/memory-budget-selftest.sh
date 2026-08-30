#!/usr/bin/env bash
# memory-budget-selftest.sh — prove the always-loaded index stays under a context budget.
#
#   bash scripts/memory-budget-selftest.sh
#
# RED-first: an index OVER budget must FAIL (exit 1) with the compact/demote guidance, and an
# index under budget must pass (exit 0). Covers both dimensions (line count AND byte size) and
# the env overrides (MEMORY_INDEX_BUDGET_LINES / MEMORY_INDEX_BUDGET_BYTES). Hermetic (mktemp).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BC="$HERE/memory-budget-check.sh"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

gen_lines() { local n="$1" out="$2"; : > "$out"; local i=1; while [ "$i" -le "$n" ]; do printf 'line %d\n' "$i" >> "$out"; i=$((i+1)); done; }

echo "▶ memory-budget-check self-test (the index is a per-session context tax)"
echo

F="$(mktemp -d)"; IDX="$F/MEMORY.md"

# ── 1. THE RED CASE: over the default line budget (400) → exit 1 ─────────────────────────
gen_lines 500 "$IDX"
OUT="$(bash "$BC" "$IDX" 2>&1)"; RC=$?
chk "RED — 500 lines > 400 default fails (exit 1)"        "[ $RC -eq 1 ]"
# the default is load-bearing, so pin BOTH sides of it: a count between the old proxy (210) and
# the recalibrated one must now PASS on lines, or the raise silently didn't take.
gen_lines 300 "$IDX"
RC=0; bash "$BC" "$IDX" >/dev/null 2>&1 || RC=$?
chk "RED-boundary — 300 lines (over the OLD 210, under the new 400) now PASSES" "[ $RC -eq 0 ]"
gen_lines 500 "$IDX"
OUT="$(bash "$BC" "$IDX" 2>&1)"; RC=$?
chk "RED — it says OVER BUDGET loudly"                    "printf '%s' \"\$OUT\" | grep -q 'OVER BUDGET'"
chk "RED — it gives the compact/demote (CACHE not store) guidance" "printf '%s' \"\$OUT\" | grep -q 'CACHE, not the store'"

# ── 2. THE GREEN CASE: under budget → exit 0 ────────────────────────────────────────────
gen_lines 10 "$IDX"
OUT="$(bash "$BC" "$IDX" 2>&1)"; RC=$?
chk "GREEN — 10 lines passes (exit 0)"                    "[ $RC -eq 0 ]"
chk "GREEN — one-line within-budget OK"                  "printf '%s' \"\$OUT\" | grep -q 'within budget'"

# ── 3. env override drops the budget below the file → exit 1 ────────────────────────────
RC=0; MEMORY_INDEX_BUDGET_LINES=5 bash "$BC" "$IDX" >/dev/null 2>&1 || RC=$?
chk "MEMORY_INDEX_BUDGET_LINES override is honored (5 < 10 lines → exit 1)"  "[ $RC -eq 1 ]"

# ── 4. byte budget: few lines but a huge payload → exit 1 ───────────────────────────────
{ printf 'header\n'; head -c 90000 /dev/zero | tr '\0' 'a'; printf '\n'; } > "$IDX"
OUT="$(bash "$BC" "$IDX" 2>&1)"; RC=$?
chk "byte budget trips on a 2-line / 90KB index (exit 1)"  "[ $RC -eq 1 ]"
chk "byte-over report shows the byte ratio"                "printf '%s' \"\$OUT\" | grep -q 'bytes: 90008 / 84000'"

# ── 5. byte override lets the same big file pass ────────────────────────────────────────
RC=0; MEMORY_INDEX_BUDGET_BYTES=200000 bash "$BC" "$IDX" >/dev/null 2>&1 || RC=$?
chk "MEMORY_INDEX_BUDGET_BYTES override lifts the byte gate (exit 0)"  "[ $RC -eq 0 ]"
rm -rf "$F"

# ── 6. the LIVE repo index is within the shipped default (refresh-safe) ─────────────────
RC=0; bash "$BC" "$HERE/../memory/MEMORY.md" >/dev/null 2>&1 || RC=$?
chk "the live memory/MEMORY.md is within the default budget (exit 0)"  "[ $RC -eq 0 ]"

echo
echo "──────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "  ✅ budget guard enforced (RED over budget, GREEN under; line + byte + overrides)"; exit 0; } || { echo "  ❌ see failures above"; exit 1; }
