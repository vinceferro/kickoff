#!/usr/bin/env bash
# mc-state-resolution-selftest.sh — prove Mission Control's server anchors instance-private
# artifacts (.mission-token, secrets-inbox/, the universe theme) to the INSTANCE, not the core,
# under the LAUNCH AN ADOPTER ACTUALLY USES.
#
#   bash scripts/mc-state-resolution-selftest.sh
#
# WHY THIS EXISTS (2026-07-16). core-v0.13 moved TOKEN_PATH off BASE_DIR onto INSTANCE_DIR =
# dirname(STATE_PATH) — correct, and it passed every check, because in the ORIGIN repo == core so
# every path resolved right. But server.py read the state file from KICKOFF_STATE only, while
# instance.env exports — and mc-update.py reads — MC_STATE_FILE. The two halves of Mission Control
# read DIFFERENT variables. Nothing in the shipped `python3 server.py <port>` launch sets
# KICKOFF_STATE, so STATE_PATH fell back to BASE_DIR and the token landed in the SHARED core again —
# the v0.13 fix landing INERT. It "worked" only where someone hand-set KICKOFF_STATE (an adopter's launch).
#
# This is the negative control that fix never had: assert the token lands in the INSTANCE under the
# stock launch (KICKOFF_STATE unset, MC_STATE_FILE set — the adopter case). It goes RED against the
# pre-fix server.py (verified: run it with `git stash` / against 62c8450 and case 1 fails). It tests
# the REAL server.py by importing it — never a replica — so it asserts on what the system consumes.
# Hermetic: a copied core + a separate instance under mktemp, never the live tree.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRV_REAL="$HERE/../mission-control/server.py"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -f "$SRV_REAL" ] || { printf '  ❌ server.py not found at %s\n' "$SRV_REAL"; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf '  ❌ python3 not found\n'; exit 1; }

echo "▶ MC state-resolution self-test (token/inbox/theme follow the INSTANCE, not the core)"
echo

# A fake SHARED CORE: server.py's dir becomes BASE_DIR. A pinned core clone would look exactly so.
CORE="$(mktemp -d)/kickoff-versions/core-vX"
mkdir -p "$CORE/mission-control" "$CORE/scripts/templates"
cp "$SRV_REAL" "$CORE/mission-control/server.py"
# the baked default theme lives beside the core (server.py:124) — presence must not change resolution
printf '{}' > "$CORE/scripts/templates/universe.theme.json"
SRV="$CORE/mission-control/server.py"

# A SEPARATE adopter INSTANCE — its own repo, its own .kickoff/state.
INST="$(mktemp -d)/adopter-repo"
STATE="$INST/.kickoff/state/mission-control/mission-state.json"
mkdir -p "$(dirname "$STATE")"
printf '{"headline":"x","in_progress":[],"functions":{},"blocked":[],"done":[],"activity":[]}' > "$STATE"

# probe <VAR=val ...> — import the REAL server.py with a controlled env; print the resolved constants.
# `env -i` gives a clean slate so a stray KICKOFF_STATE/MC_STATE_FILE in THIS shell can't leak in and
# mask the very fall-through this asserts (the leaked-env trap the adopt exam was built to catch).
probe() {
  env -i PATH="$PATH" SRV="$SRV" "$@" python3 - <<'PY'
import os, importlib.util
spec = importlib.util.spec_from_file_location("mcs", os.environ["SRV"])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print("STATE=" + str(m.STATE_PATH))
print("TOKEN=" + str(m.TOKEN_PATH))
print("INBOX=" + str(m.SECRETS_INBOX))
print("THEME=" + str(m.THEME_PATH))
PY
}
val() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

# ── 1. RED-FIRST — the STOCK adopter launch: KICKOFF_STATE UNSET, MC_STATE_FILE set ──────────────
# This is the bug. Pre-fix, server.py ignores MC_STATE_FILE, STATE_PATH → BASE_DIR, token → the core.
out="$(probe MC_STATE_FILE="$STATE")"
tok="$(val "$out" TOKEN)"
case "$tok" in
  "$INST"/*) ok "stock launch (MC_STATE_FILE, no KICKOFF_STATE): token lands in the INSTANCE" ;;
  "$CORE"/*) bad "INERT FIX: token landed in the SHARED CORE ($tok) — server.py ignored MC_STATE_FILE" ;;
  *) bad "stock launch: token at an unexpected path: ${tok:-<none>}" ;;
esac
# the sibling instance-private artifacts must follow too (same root cause, same STATE_PATH)
inbox="$(val "$out" INBOX)"; theme="$(val "$out" THEME)"
case "$inbox" in "$INST"/*) ok "stock launch: secrets-inbox/ follows the instance" ;;
  *) bad "secrets-inbox/ did NOT follow the instance: ${inbox:-<none>}" ;; esac
case "$theme" in "$INST"/*) ok "stock launch: the universe theme path resolves to the instance's .kickoff" ;;
  *) bad "universe theme path did not resolve to the instance: ${theme:-<none>}" ;; esac

# ── 2. explicit override still wins: KICKOFF_STATE set ────────────────────────────────────────────
out="$(probe KICKOFF_STATE="$STATE")"
tok="$(val "$out" TOKEN)"
case "$tok" in "$INST"/*) ok "explicit KICKOFF_STATE override: token lands in the instance" ;;
  *) bad "KICKOFF_STATE override did not place the token in the instance: ${tok:-<none>}" ;; esac

# ── 3. the ORIGIN: NEITHER var set → token beside the core (repo == core, correct by construction) ─
# Guards against a fix that ALWAYS relocates and would strand the origin's own board.
out="$(probe)"
tok="$(val "$out" TOKEN)"
case "$tok" in "$CORE"/mission-control/*) ok "origin (no vars): token beside the core — BASE_DIR default intact" ;;
  *) bad "origin default broke: token at ${tok:-<none>} (expected beside the core)" ;; esac

# ── 4. precedence: BOTH set to DIFFERENT dirs → KICKOFF_STATE wins (test-override back-compat) ─────
OTHER="$(mktemp -d)/other"; mkdir -p "$(dirname "$OTHER/.kickoff/state/mission-control/x")" 2>/dev/null
OSTATE="$OTHER/.kickoff/state/mission-control/mission-state.json"; mkdir -p "$(dirname "$OSTATE")"
printf '{}' > "$OSTATE"
out="$(probe KICKOFF_STATE="$OSTATE" MC_STATE_FILE="$STATE")"
tok="$(val "$out" TOKEN)"
case "$tok" in "$OTHER"/*) ok "both set: KICKOFF_STATE wins over MC_STATE_FILE (explicit override precedence)" ;;
  *) bad "precedence wrong: with both set the token went to ${tok:-<none>}, expected under KICKOFF_STATE's dir" ;; esac

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && printf '  ✅ MC state resolution enforced (instance under the stock launch · override honoured · origin intact)\n'
[ "$FAIL" -eq 0 ]
