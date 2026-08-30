#!/usr/bin/env bash
# parity-report-selftest.sh — the parity ledger's RED-first suite: prove that scripts/parity-report.sh
# ACTUALLY catches drift, in both directions, before trusting its green.
#
#   bash scripts/parity-report-selftest.sh
#
# ── WHAT EACH LANE PROVES (and the failure it exists for) ───────────────────────────────────────
# A check never seen RED on the failing input proves nothing — it may be confirming belief, not
# testing. So every lane here is a NEGATIVE CONTROL on one load-bearing property of the parity
# gate, run against a FIXTURE TREE (a copy of the probe-relevant files into a mktemp dir), never
# against the dev checkout — sabotaging the real tree to watch a guard fire is how guard-testing
# becomes incident creation:
#
#   §1 hygiene        bash -n on the report and itself. A suite that can't parse proves nothing.
#   §2 coherent tree  the REAL tree runs GREEN — every probe verdict matches the ledger. (The one
#                     positive control; everything after it is red.)
#   §3 FIXTURE GONE   a hook FILE deleted (beat-length-guard.py) → that capability's probe flips →
#                     the report goes RED naming the capability AND the new verdict. Proves the
#                     cross-check fires in the failure direction: a gap the ledger does not know
#                     about must block.
#   §4 WIRING GONE    the hook CONFIG line removed while the file remains (outputStyle from
#                     .claude/settings.json) → still RED. Probes must read the WIRING, not file
#                     existence — a file nothing invokes is the classic false green (verify the
#                     READ, not just the write).
#   §5 LEDGER GONE    a section deleted while its gap exists (mc-spine) → RED naming the
#                     capability. Proves the mirror direction: silent ledger deletion cannot
#                     quietly retire a recorded gap.
#   §6 LEDGER LIES    a Status flipped against reality (memory-recall 'both' → 'claude-only') →
#                     RED. An under-claim is a false statement to an adopter, same as an
#                     over-claim — the ledger must match reality, not merely mention it.
#   §7 UNKNOWN CAP    a ledger section with no probe (cap:time-travel) → RED. A verdict nothing
#                     can verify is prose, not a record.
#   §8 RECORDED PASS  the §3 sabotage, but the ledger UPDATED to match (Status: none) → GREEN.
#                     The release-gate property this whole design exists for: RECORDED drift
#                     passes — the point is recording, not perfection.
#   §9 PINNED COUNTS  the real tree's summary line is pinned ("15 capability probe(s): 2 both ·
#                     12 claude-only · 1 opencode-only · 0 none"). A verdict that silently flips —
#                     a probe rewritten to rubber-stamp, a capability ported, a regression — breaks
#                     this lane and forces a conscious ledger+suite update in the same commit.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
REPORT="$REPO/scripts/parity-report.sh"

PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }

FIXTURE=""

cleanup() { [ -n "$FIXTURE" ] && [ -d "$FIXTURE" ] && rm -rf "$FIXTURE"; }
trap cleanup EXIT

# make_fixture — copy ONLY the paths the probes read, from the real tree, preserving structure
# (cp --parents). The fixture = the probe topology, not a tarball of the repo: nothing outside the
# probe set can influence a verdict, and the suite stays fast and hermetic.
make_fixture() {
  FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/parity-fixture.XXXXXX")" || return 1
  ( cd "$REPO" && cp --parents \
      docs/PARITY.md \
      scripts/parity-report.sh \
      scripts/session-run.sh \
      scripts/orphaned-work.py \
      plugin/hooks/hooks.json \
      plugin/hooks/memory-hook.sh \
      plugin/hooks/agent-mail-hook.sh \
      plugin/hooks/beat-length-guard.py \
      plugin/hooks/beat-nudge.py \
      plugin/hooks/context-handoff-nudge.py \
      plugin/hooks/mc-hook.sh \
      .claude/settings.json \
      .claude/agents/builder.md \
      .claude/agents/reviewer.md \
      .claude/output-styles/plain-report.md \
      .claude/skills/scan/SKILL.md \
      .claude/workflows/pr-adversarial-review.js \
      .opencode/plugins/memory-search.js \
      .opencode/plugins/engine-credit.js \
      .opencode/agent/builder.md \
      .opencode/agent/reviewer.md \
      "$FIXTURE" ) >/dev/null 2>&1
}

run_in_fixture() {   # run_in_fixture <outfile-var> <rc-var> — the fixture tree under test
  local out_var="$1" rc_var="$2" out rc=0
  out="$(bash "$FIXTURE/scripts/parity-report.sh" --root "$FIXTURE" 2>&1)" || rc=$?
  printf -v "$out_var" '%s' "$out"
  printf -v "$rc_var" '%s' "$rc"
}

# ── §1 hygiene ──────────────────────────────────────────────────────────────────────────────────
echo "§1  hygiene"
bash -n "$REPORT" && ok "parity-report.sh parses" || bad "parity-report.sh does not parse (bash -n)"
bash -n "$HERE/$(basename "$0")" && ok "selftest parses" || bad "selftest does not parse (bash -n)"

# ── §2 the real tree is coherent ────────────────────────────────────────────────────────────────
echo "§2  coherent tree (the positive control)"
real_out="$(bash "$REPORT" --root "$REPO" 2>&1)"; real_rc=$?
if [ "$real_rc" -eq 0 ]; then
  ok "real tree probes GREEN — ledger matches reality"
else
  bad "real tree went RED (rc=$real_rc) — the ledger and the tree disagree:\n$(printf '%s' "$real_out" | tail -n 20)"
fi

# ── §3 FIXTURE GONE: delete a hook file → gap flips → cross-check must fail ─────────────────────
echo "§3  probe sabotage: hook file deleted → report flips RED naming the capability"
make_fixture
rm -f "$FIXTURE/plugin/hooks/beat-length-guard.py"
run_in_fixture out3 rc3
if [ "$rc3" -ne 0 ]; then
  ok "sabotaged tree is RED (rc=$rc3)"
else
  bad "deleting a wired hook file did NOT flip the report — the probe or cross-check is blind"
fi
printf '%s' "$out3" | grep -q 'beat-length-guard' \
  && ok "RED names the capability (beat-length-guard)" \
  || bad "RED output does not name the capability — an adopter could not act on it"
printf '%s' "$out3" | grep -qE "probes as 'none'" \
  && ok "RED names the new verdict (none)" \
  || bad "RED output does not name the new verdict"

# ── §4 WIRING GONE: config line removed, file present → still RED ───────────────────────────────
echo "§4  wiring sabotage: config line removed (file intact) → still RED"
make_fixture
grep -v '"outputStyle"' "$FIXTURE/.claude/settings.json" > "$FIXTURE/.claude/settings.json.new" \
  && mv "$FIXTURE/.claude/settings.json.new" "$FIXTURE/.claude/settings.json"
run_in_fixture out4 rc4
if [ "$rc4" -ne 0 ]; then
  ok "config-only sabotage is RED (rc=$rc4) — probes read the wiring, not file existence"
else
  bad "removing the config wiring did NOT flip the report — the probe trusts an uninvoked file (false green)"
fi
printf '%s' "$out4" | grep -q 'plain-report-output-style' \
  && ok "RED names the capability (plain-report-output-style)" \
  || bad "RED output does not name the capability"

# ── §5 LEDGER GONE: section removed while its gap exists ────────────────────────────────────────
echo "§5  ledger sabotage: mc-spine section removed while the gap exists"
make_fixture
awk '
  /^### cap:mc-spine/ { skip=1; next }
  /^### cap:/ && skip { skip=0 }
  /^## / && skip { skip=0 }
  !skip { print }
' "$FIXTURE/docs/PARITY.md" > "$FIXTURE/docs/PARITY.md.new" \
  && mv "$FIXTURE/docs/PARITY.md.new" "$FIXTURE/docs/PARITY.md"
run_in_fixture out5 rc5
if [ "$rc5" -ne 0 ]; then
  ok "section deletion is RED (rc=$rc5)"
else
  bad "deleting a ledger section for a LIVE gap went GREEN — a ledger edit can silently retire a gap"
fi
printf '%s' "$out5" | grep -q 'mc-spine' \
  && ok "RED names the capability (mc-spine)" \
  || bad "RED output does not name the capability"

# ── §6 LEDGER LIES: Status flipped against reality ──────────────────────────────────────────────
echo "§6  ledger lies: memory-recall recorded as a gap while it probes 'both'"
make_fixture
sed -i 's/^Status: both/Status: claude-only/' "$FIXTURE/docs/PARITY.md"
run_in_fixture out6 rc6
if [ "$rc6" -ne 0 ]; then
  ok "under-claim is RED (rc=$rc6) — the ledger must match reality, not just mention it"
else
  bad "a Status flipped against reality went GREEN — the check only tests one direction"
fi
printf '%s' "$out6" | grep -q "per-prompt-memory-recall" \
  && ok "RED names the capability" \
  || bad "RED output does not name the capability"

# ── §7 UNKNOWN CAP: a ledger section with no probe ──────────────────────────────────────────────
echo "§7  ledger rot: a section nothing can verify"
make_fixture
cat >> "$FIXTURE/docs/PARITY.md" <<'EOF'

### cap:time-travel — Retroactive fixups

Status: both

Fake capability planted by the selftest.
EOF
run_in_fixture out7 rc7
if [ "$rc7" -ne 0 ]; then
  ok "unprobeable section is RED (rc=$rc7)"
else
  bad "a ledger section with no probe went GREEN — unverifiable verdicts are prose, not records"
fi
printf '%s' "$out7" | grep -q 'time-travel' \
  && ok "RED names the unknown capability" \
  || bad "RED output does not name the unknown capability"

# ── §8 RECORDED PASS: same sabotage as §3, ledger updated to match → GREEN ──────────────────────
echo "§8  recorded drift passes (the release-gate property)"
make_fixture
rm -f "$FIXTURE/plugin/hooks/beat-length-guard.py"
awk '
  /^### cap:beat-length-guard/ { inslug=1 }
  inslug && /^Status: claude-only/ { print "Status: none"; inslug=0; next }
  { print }
' "$FIXTURE/docs/PARITY.md" > "$FIXTURE/docs/PARITY.md.new" \
  && mv "$FIXTURE/docs/PARITY.md.new" "$FIXTURE/docs/PARITY.md"
run_in_fixture out8 rc8
if [ "$rc8" -eq 0 ]; then
  ok "drift RECORDED in the ledger passes (rc=0) — the point is recording, not perfection"
else
  bad "recorded drift still blocked — the gate punishes honesty instead of enforcing it"
fi

# ── §9 PINNED COUNTS: the real tree's summary is load-bearing ───────────────────────────────────
echo "§9  pinned summary counts"
printf '%s' "$real_out" | grep -qF '15 capability probe(s): 2 both · 12 claude-only · 1 opencode-only · 0 none' \
  && ok "summary line matches the pinned probe set + verdicts" \
  || bad "summary line drifted from the pin — a verdict changed without a conscious ledger+suite update"

echo
echo "parity-report-selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
