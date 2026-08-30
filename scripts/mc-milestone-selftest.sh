#!/usr/bin/env bash
# mc-milestone-selftest.sh — the backlog → milestone → COMMIT (the gate) → cook lifecycle in
# mission-control/mc-update.py. The gate is the point: agents cook ONLY a committed milestone, and
# `launch` enforces that as a MECHANISM, not a convention. RED-first: the gate assertion is proven
# against a mutant with the guard removed, so a green here means the guard is actually load-bearing.
#
#   bash scripts/mc-milestone-selftest.sh
#
# Hermetic: a temp state file, MC_STATE_FILE unset (this box sets it; the fail-loud-on-missing guard
# would otherwise fire before any write). Pure python3 + jq-free (python one-liners read the state).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MCU="$ROOT/mission-control/mc-update.py"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
F="$TMP/mission-state.json"
mc() { env -u MC_STATE_FILE python3 "$MCU" --file "$F" "$@"; }
# read a python expression against the state file; prints the value
val() { env -u MC_STATE_FILE python3 -c "import json,sys; d=json.load(open('$F')); print($1)" 2>/dev/null; }

printf '\n  mc-update milestone lifecycle — capture · pick · COMMIT (gate) · cook\n\n'

# ── 1. CAPTURE — backlog adds an uncommitted idea ────────────────────────────────────────────────
mc backlog "Add gift-card checkout" --theme Payments >/dev/null 2>&1
mc backlog "Dark mode" >/dev/null 2>&1
[ "$(val "len(d['backlog'])")" = "2" ] && ok "capture: two ideas land in backlog" || bad "capture: backlog count wrong"
[ "$(val "d['backlog'][0].get('theme')")" = "Payments" ] && ok "capture: --theme carries onto the idea" || bad "capture: theme not carried"

# ── 2. MILESTONE — create a named grouping (uncommitted by default) ──────────────────────────────
mc milestone "v1 launch" --goal "Ship the paid flow" >/dev/null 2>&1
[ "$(val "d['milestones'][0]['name']")" = "v1 launch" ] && ok "milestone: created by name" || bad "milestone: not created"
[ "$(val "d['milestones'][0]['committed']")" = "False" ] && ok "milestone: starts UNcommitted" || bad "milestone: should start uncommitted"

# ── 3. PICK — assign an idea into a milestone; refuse an unknown milestone ───────────────────────
mc pick 0 --milestone "v1 launch" >/dev/null 2>&1
[ "$(val "d['backlog'][0].get('milestone')")" = "v1 launch" ] && ok "pick: idea tagged into the milestone" || bad "pick: milestone not set"
if mc pick 1 --milestone "ghost" >/dev/null 2>&1; then bad "pick: accepted a NON-EXISTENT milestone (should refuse)"; else ok "pick: refuses an unknown milestone"; fi

# ── 4. THE GATE — launch REFUSES an uncommitted milestone ───────────────────────────────────────
if mc launch "v1 launch" >/dev/null 2>&1; then
  bad "GATE: launch ran on an UNcommitted milestone — the gate is not enforced"
else
  ok "GATE: launch refuses an uncommitted milestone (mechanism, not convention)"
fi
[ "$(val "len(d['in_progress'])")" = "0" ] && ok "GATE: nothing entered in_progress before commit" || bad "GATE: items leaked into in_progress pre-commit"

# ── 5. COMMIT then LAUNCH — the committed milestone's picked ideas cook ──────────────────────────
mc commit "v1 launch" >/dev/null 2>&1
[ "$(val "d['milestones'][0]['committed']")" = "True" ] && ok "commit: milestone marked committed" || bad "commit: not marked"
[ -n "$(val "d['milestones'][0]['committedAt']")" ] && ok "commit: stamps committedAt" || bad "commit: no committedAt"
mc launch "v1 launch" >/dev/null 2>&1
[ "$(val "[i['text'] for i in d['in_progress']]")" = "['Add gift-card checkout']" ] && ok "launch: the picked idea → in_progress" || bad "launch: picked idea did not move"
[ "$(val "[b['text'] for b in d['backlog']]")" = "['Dark mode']" ] && ok "launch: the UNpicked idea stays in backlog" || bad "launch: unpicked idea disturbed"

# ── 6. RENDER — the tracker view shows Backlog + Milestones ──────────────────────────────────────
mc render-tracker --out "$TMP/TRACKER.md" >/dev/null 2>&1
grep -q "## 💭 Backlog" "$TMP/TRACKER.md" && ok "render: Backlog section present" || bad "render: no Backlog section"
grep -q "v1 launch.*committed" "$TMP/TRACKER.md" && ok "render: milestone shows its committed state" || bad "render: milestone gate not rendered"

# ── 7. RED CONTROL — the gate assertion must FAIL on a mutant with the guard removed ─────────────
# Strip the "if not m.get('committed')" refusal from a COPY of mc-update.py and prove `launch` then
# cooks an uncommitted milestone — i.e. assertion #4 is load-bearing, not vacuous.
MUT="$TMP/mc-mutant.py"
python3 - "$MCU" "$MUT" <<'PY'
import sys, re
src = open(sys.argv[1]).read()
# remove the committed-guard block (the 3 lines: `if not m.get("committed"):` + its 2-line sys.exit)
src2 = re.sub(r'\n\s*if not m\.get\("committed"\):\n(?:\s+.*\n)+?\s+"Agents do not cook an uncommitted milestone\." % \(name, name\)\)\n',
              '\n', src, count=1)
assert src2 != src, "mutation did not apply — the guard text moved; update the RED control"
open(sys.argv[2], "w").write(src2)
PY
G="$TMP/mut-state.json"
mcmut() { env -u MC_STATE_FILE python3 "$MUT" --file "$G" "$@"; }
mcmut backlog "x" >/dev/null 2>&1
mcmut milestone "m" >/dev/null 2>&1
mcmut pick 0 --milestone "m" >/dev/null 2>&1
if mcmut launch "m" >/dev/null 2>&1; then
  ok "RED CONTROL: guard removed → launch cooks an uncommitted milestone (assertion #4 is load-bearing)"
else
  bad "RED CONTROL did NOT go red — the gate assertion would pass even without the guard (vacuous)"
fi

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then printf '  ✅ backlog → milestone → commit-gate → cook holds\n'; exit 0; else exit 1; fi
