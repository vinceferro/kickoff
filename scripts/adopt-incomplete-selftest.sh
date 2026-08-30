#!/usr/bin/env bash
# adopt-incomplete-selftest.sh — the ABANDONED-adopt detector is LOUD, and NEVER startup-breaking.
#
#   bash scripts/adopt-incomplete-selftest.sh
#
# Scout #1 (adopter stress-test): `kickoff verify` printed "GREEN exit 0" on a half-adopted repo — mechanical
# seams present, /adopt session never run, gates wholly unwired, commits landing unscanned — and
# nothing fail-closed ever noticed. The fix distinguishes a LEGIT fresh adopt (a valid state: the
# operator just hasn't run /adopt yet, and NOTHING is flowing through the repo) from an ABANDONED-
# but-ACTIVE one (commits after the adopt baseline · board activity · a live supervisor):
#   · `kickoff verify`  → a prominent "ADOPT INCOMPLETE" banner (advisory — exit code UNCHANGED)
#   · preflight         → the same signal as a LOUD [warn] the supervisor-start log surfaces
#   · NEITHER may make preflight or `kickoff up` exit non-zero — preflight runs at EVERY
#     supervisor start, and a fresh mechanical adopt MUST still boot (the hard guard).
#
# RED-FIRST: the banner/warn lanes were run against the pre-slice kickoff/preflight.sh and observed
# RED (no "ADOPT INCOMPLETE" anywhere); the fresh-adopt lanes (rc=0, no banner) were GREEN before
# AND after — they are the no-false-positive + never-breaks-startup regression guards.
#
# HERMETIC (mirrors adopt-selftest): mktemp fixtures + ONE EXIT trap; a scratch core built from
# TODAY's engine files (no plugin dir → the plugin arm is inert, no real `claude` call); scratch
# registry/config; no real supervisor is ever started (`up` only in --dry-run).
# Deps: git + python3 + coreutils. Exits non-zero on any failed assertion.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# self-scrub the ambient instance.env whitelist (same set adopt-selftest scrubs) — a preset env
# var WINS over a fixture's instance.env by design, so ambient live values must not leak in.
unset REPO_DIR KICKOFF_CORE_DIR KICKOFF_CORE_REMOTE MC_STATE_FILE MC_TRACKER_FILE \
      MEMORY_DB MEMORY_HOOK_LOG MEMORY_DIR MEMORY_INDEX TELEGRAM_STATE_DIR CHANNEL_SPEC \
      REGROUND_PROMPT PERMISSION_MODE EFFORT MODEL MAX_CONCURRENT_AGENTS DEPLOY_BRANCH \
      CADENCE INSTANCE_ENV LOCKFILE ORIGIN_STATE_DIR OPERATOR_STATE_DIR 2>/dev/null || true

PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

command -v git     >/dev/null 2>&1 || { echo "  ❌ git not found";     exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "  ❌ python3 not found"; exit 1; }

CLEANUP_LIST="$(mktemp)"
mk() { local d; d="$(mktemp -d)"; printf '%s\n' "$d" >> "$CLEANUP_LIST"; printf '%s' "$d"; }
trap 'while IFS= read -r _d; do [ -n "$_d" ] && rm -rf "$_d"; done < "$CLEANUP_LIST"; rm -f "$CLEANUP_LIST"' EXIT

echo "▶ adopt-incomplete selftest — LOUD flag on an abandoned-but-active adopt; NEVER a startup break"
echo

# ── the scratch core: TODAY's engine (front door + preflight + supervisor chain + mc), NO plugin ──
# Committed clean at an exact core-vT tag so adopt SELF-PINS and verify's core-pin check is GREEN —
# the fixtures must be hard-check-green so the exit-code assertions isolate the ADVISORY banner.
CORE="$(mk)"
mkdir -p "$CORE/scripts" "$CORE/mission-control"
cp "$REPO/scripts/kickoff" "$REPO/scripts/adopt-manifest.py" "$REPO/scripts/instance.env.example" \
   "$REPO/scripts/preflight.sh" "$REPO/scripts/start-supervisor.sh" "$REPO/scripts/supervisor.sh" \
   "$REPO/scripts/session-run.sh" "$CORE/scripts/"
[ -f "$REPO/scripts/rotate-log.sh" ] && cp "$REPO/scripts/rotate-log.sh" "$CORE/scripts/"
cp -r "$REPO/scripts/templates" "$CORE/scripts/templates"
cp "$REPO/mission-control/mc-update.py" "$CORE/mission-control/"
git -C "$CORE" init -q; git -C "$CORE" config user.email t@t.t; git -C "$CORE" config user.name t
git -C "$CORE" add -A; git -C "$CORE" commit -qm core; git -C "$CORE" tag core-vT

# build_fix → a git fixture repo, really adopted against $CORE (gates wired by F2's mechanical adopt).
build_fix() {   # $1 = registry file, $2 = config dir → echoes the fixture dir
  local f; f="$(mk)"
  git -C "$f" init -q; git -C "$f" config user.email t@t.t; git -C "$f" config user.name t
  printf '# app\n' > "$f/README.md"; git -C "$f" add -A; git -C "$f" commit -qm baseline
  REPO_DIR="$f" TELEGRAM_STATE_DIR="" KICKOFF_ADOPTERS_REGISTRY="$1" KICKOFF_CORE_DIR="$CORE" CLAUDE_CONFIG_DIR="$2" \
    bash "$CORE/scripts/kickoff" adopt --dir "$f" --accept </dev/null >/dev/null 2>&1 || true
  printf '%s' "$f"
}
# strip_gates → simulate the pre-slice adopter shape (adopted before the CLI wired generic gates).
strip_gates() { rm -f "$1/lefthook.yml" "$1/.kickoff/lefthook-kickoff.yml"; }

run_verify()    { REPO_DIR="$1" KICKOFF_CORE_DIR="$CORE" bash "$CORE/scripts/kickoff" verify --dir "$1" 2>&1; }
run_preflight() { REPO_DIR="$1" KICKOFF_CORE_DIR="$CORE" bash "$CORE/scripts/preflight.sh" 2>&1; }

# ══════════════════════════════════════════════════════════════════════════════════════
echo "1. FRESH just-adopted fixture — NO banner, and startup is fully green (the hard guard)"
FREG="$(mk)/adopters.json"; FCFG="$(mk)"
FFIX="$(build_fix "$FREG" "$FCFG")"
fv_rc=0; fv_out="$(run_verify "$FFIX")" || fv_rc=$?
chk "verify exits 0 on the fresh adopt (hard checks green — the fixture isolates the advisory)" \
  "[ $fv_rc -eq 0 ]"
chk "verify shows NO 'ADOPT INCOMPLETE' banner on a fresh adopt (no false positive)" \
  "! printf '%s' \"\$fv_out\" | grep -q 'ADOPT INCOMPLETE'"
fp_rc=0; fp_out="$(run_preflight "$FFIX")" || fp_rc=$?
chk "preflight exits 0 on the fresh adopt (a legit mechanical adopt MUST boot — runs at every supervisor start)" \
  "[ $fp_rc -eq 0 ]"
chk "preflight shows NO 'ADOPT INCOMPLETE' on a fresh adopt" \
  "! printf '%s' \"\$fp_out\" | grep -q 'ADOPT INCOMPLETE'"
# `up --dry-run` (foreground) deliberately keeps the supervisor's poll loop alive — so the proof is
# REACHING the launch, not the exit code: preflight passed (no fail-closed refusal) and the
# supervisor printed its would-start line. timeout bounds the loop; its kill-rc is expected.
fu_out="$(REPO_DIR="$FFIX" timeout 25 bash "$CORE/scripts/kickoff" up --dir "$FFIX" --dry-run </dev/null 2>&1 || true)"
chk "\`kickoff up --dry-run\` still REACHES the launch on the fresh adopt (preflight passed, session would start)" \
  "printf '%s' \"\$fu_out\" | grep -q 'would start a fresh session'"
chk "\`kickoff up --dry-run\` hit NO fail-closed refusal on the fresh adopt" \
  "! printf '%s' \"\$fu_out\" | grep -q 'FAIL-CLOSED: refusing'"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "2. ABANDONED-but-ACTIVE fixture (commits after adopt, gates stripped, no TRACKER) — LOUD flag"
AREG="$(mk)/adopters.json"; ACFG="$(mk)"
AFIX="$(build_fix "$AREG" "$ACFG")"
strip_gates "$AFIX"
sleep 1   # commit-date resolution is 1s — the activity commit must be STRICTLY after the manifest
printf 'work\n' >> "$AFIX/README.md"; git -C "$AFIX" add -A; git -C "$AFIX" commit -qm "feature work"
av_rc=0; av_out="$(run_verify "$AFIX")" || av_rc=$?
chk "verify fires the prominent 'ADOPT INCOMPLETE' banner (active repo + wholly-unwired gates)" \
  "printf '%s' \"\$av_out\" | grep -q 'ADOPT INCOMPLETE'"
chk "the banner names the ACTIVITY signal (commits landed after adopt)" \
  "printf '%s' \"\$av_out\" | grep -qi 'commit(s) landed after adopt'"
chk "the banner names the missing TRACKER.md (the /adopt session never ran)" \
  "printf '%s' \"\$av_out\" | grep -qi 'TRACKER.md'"
chk "the banner is ADVISORY: verify's exit code is UNCHANGED (still 0 — hard checks green)" \
  "[ $av_rc -eq 0 ]"
ap_rc=0; ap_out="$(run_preflight "$AFIX")" || ap_rc=$?
chk "preflight surfaces the SAME signal as a LOUD [warn] (the supervisor-start log shows it)" \
  "printf '%s' \"\$ap_out\" | grep 'ADOPT INCOMPLETE' | grep -q '\[warn\]'"
chk "preflight STILL exits 0 (LOUD flag, NEVER a startup-breaking refusal)" \
  "[ $ap_rc -eq 0 ]"
au_out="$(REPO_DIR="$AFIX" timeout 25 bash "$CORE/scripts/kickoff" up --dry-run --dir "$AFIX" </dev/null 2>&1 || true)"
chk "\`kickoff up --dry-run\` STILL reaches the launch on the abandoned shape (the flag never bricks \`up\`)" \
  "printf '%s' \"\$au_out\" | grep -q 'would start a fresh session'"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "3. ACTIVITY VARIANTS — board activity alone escalates; stripped-but-idle does NOT"
# (a) board-activity signal: NO extra commits, but mission-state.json carries activity entries.
BREG="$(mk)/adopters.json"; BCFG="$(mk)"
BFIX="$(build_fix "$BREG" "$BCFG")"
strip_gates "$BFIX"
python3 - "$BFIX/.kickoff/state/mission-control/mission-state.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["activity"] = [{"ts": "2026-07-24T00:00:00Z", "text": "shipped the checkout slice"}]
json.dump(d, open(p, "w"), indent=2)
PY
bv_out="$(run_verify "$BFIX")" || true
chk "(a) board activity ALONE (no extra commits) escalates — the banner fires" \
  "printf '%s' \"\$bv_out\" | grep -q 'ADOPT INCOMPLETE'"
chk "(a) the banner names the board-activity signal" \
  "printf '%s' \"\$bv_out\" | grep -qi 'activity'"
# (b) the false-positive guard: gates stripped but NOTHING is active → ordinary warns only, no banner.
CREG="$(mk)/adopters.json"; CCFG="$(mk)"
CFIX="$(build_fix "$CREG" "$CCFG")"
strip_gates "$CFIX"
cv_rc=0; cv_out="$(run_verify "$CFIX")" || cv_rc=$?
chk "(b) stripped-but-IDLE (no commits, no activity, no supervisor) → NO banner (a legit pre-gate adopter)" \
  "! printf '%s' \"\$cv_out\" | grep -q 'ADOPT INCOMPLETE'"
chk "(b) the ordinary gate warn still shows (the state is named, just not escalated)" \
  "printf '%s' \"\$cv_out\" | grep -qi 'lefthook gate not wired'"
chk "(b) verify still exits 0" "[ $cv_rc -eq 0 ]"
cp_out="$(run_preflight "$CFIX")" || true
chk "(b) preflight does not escalate the idle shape either" \
  "! printf '%s' \"\$cp_out\" | grep -q 'ADOPT INCOMPLETE'"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "4. SKILL honesty — adopt SKILL step 7 no longer over-claims what \`verify\` hard-fails on"
ASK="$REPO/plugin/skills/adopt/SKILL.md"
chk "the SKILL no longer claims verify 'exits non-zero on any failure' (gates warn, they don't fail)" \
  "! grep -q 'exits non-zero on any failure' \"$ASK\""
chk "the SKILL states the hard-fail vs loud-advisory split explicitly" \
  "grep -qi 'hard' \"$ASK\" && grep -qi 'advisor' \"$ASK\""
chk "the SKILL names the ADOPT INCOMPLETE escalation" \
  "grep -q 'ADOPT INCOMPLETE' \"$ASK\""
chk "the two adopt SKILL copies are BYTE-IDENTICAL" \
  "cmp -s \"$REPO/plugin/skills/adopt/SKILL.md\" \"$REPO/.claude/skills/adopt/SKILL.md\""
echo

echo "──────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "  ✅ incomplete-adopt detection: loud, honest, never startup-breaking"; exit 0; } || { echo "  ❌ see failures above"; exit 1; }
