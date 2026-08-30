#!/usr/bin/env bash
# claims-audit-selftest.sh — prove the lint FLAGS the bare claim and PASSES the
# evidenced one, with the bias the design demands: false positives acceptable,
# false negatives on blatant cases not.
#
#   bash scripts/claims-audit-selftest.sh
#
# The load-bearing lane is (b)+: the EXACT string from the 2026-08-27 incident
# — "pushed to origin/brownfield-devex" — must FLAG. A naive path detector
# counts `origin/brownfield-devex` as "something/something" evidence and the
# motivating incident sails through green; that is the false-negative this lint
# exists to make impossible. RED-first history: the untuned core (done-words
# only, no evidence layer) was watched flagging every line including the
# evidenced ones before tuning; the final lane re-proves the engine by mutation
# — gut the done-word list and the suite must see (b) go unflagged.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CA="$HERE/claims-audit.py"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }

F="$(mktemp -d)"
run() { python3 "$CA" "$@"; }

# ── (a) done-word + a real SHA → passes ───────────────────────────────────────
cat > "$F/a.md" <<'EOF'
## Done
- Batch shipped at 6f9c065a (battery 22/22).
EOF
out="$(run "$F/a.md")"; rc=$?
[ $rc -eq 0 ] && printf '%s' "$out" | grep -q "1 claims, all evidenced" \
  && ok "(a) done-word + real SHA passes" \
  || bad "(a) should pass evidenced, got rc=$rc: $out"

# ── (b) bare 'pushed to origin' → FLAGS (the RED-first lane) ──────────────────
cat > "$F/b.md" <<'EOF'
## Done
- Pushed the batch to origin.
EOF
out="$(run "$F/b.md")"; rc=$?
if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q '\[pushed\]'; then
  ok "(b) bare 'Pushed the batch to origin.' FLAGS with the done-word named"
else
  bad "(b) the incident shape did not flag (rc=$rc): $out"
fi

# ── (b+) the EXACT incident string: origin/<branch> is NOT path evidence ──────
cat > "$F/bplus.md" <<'EOF'
## Done
- Pushed the batch to origin/brownfield-devex.
EOF
out="$(run "$F/bplus.md")"; rc=$?
if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'origin/brownfield-devex'; then
  ok "(b+) 'pushed to origin/brownfield-devex' FLAGS — a ref is a claimant's word, not a path"
else
  bad "(b+) FALSE NEGATIVE on the motivating incident string (rc=$rc): $out"
fi

# ── (c) 'verified' + command+result fence → passes ────────────────────────────
cat > "$F/c.md" <<'EOF'
## Done
- Verified the remote is current:
  ```
  $ git ls-remote origin main
  1a2b3c4d5e6f refs/heads/main
  ```
EOF
out="$(run "$F/c.md")"; rc=$?
[ $rc -eq 0 ] && printf '%s' "$out" | grep -q "1 claims, all evidenced" \
  && ok "(c) 'verified' + command+result fence passes" \
  || bad "(c) fence evidence not honoured, got rc=$rc: $out"

# a fence with ONLY a command (no result) is not evidence — output is the proof
cat > "$F/c2.md" <<'EOF'
## Done
- Pushed it, see:
  ```
  git push origin main
  ```
EOF
out="$(run "$F/c2.md")"; rc=$?
[ $rc -eq 1 ] \
  && ok "command-only fence (no result) does NOT count as evidence" \
  || bad "a command-only fence excused a bare 'pushed' (rc=$rc): $out"

# ── (d) honest label → must NOT flag ──────────────────────────────────────────
# NB the line must carry a done-word TOO, or the lane is vacuous (nothing to
# exempt) — "unverified" next to "pushed" is the honest state we want tracked.
cat > "$F/d.md" <<'EOF'
## Done
- Pushed, unverified — needs a live read-back to say so.
EOF
out="$(run "$F/d.md")"; rc=$?
[ $rc -eq 0 ] && printf '%s' "$out" | grep -q "1 claims, all evidenced" \
  && ok "(d) 'pushed, unverified — needs X' does NOT flag (honest labeling is the behavior we want)" \
  || bad "(d) honest labeling was flagged, got rc=$rc: $out"

# ── evidence shapes ───────────────────────────────────────────────────────────
cat > "$F/e.md" <<'EOF'
## Done
- Report written to docs/briefs/output-truth-audit-2026-08-28.md and green.
- Runner fixed via scripts/scan-identity.sh lane.
- Shipped 2026-08-27 (`core-v0.41`)
- Landed the patch, evidence in the block below
  (commit 71aaad7f, reviewed twice).
EOF
out="$(run "$F/e.md")"; rc=$?
[ $rc -eq 0 ] && printf '%s' "$out" | grep -q "4 claims, all evidenced" \
  && ok "paths (multi-segment and .ext), date+backtick, and block-scoped SHA all pass" \
  || bad "an evidence shape failed, got rc=$rc: $out"

# ── fence CONTENT is never a claim (verbatim artifacts, not prose) ────────────
cat > "$F/fence.md" <<'EOF'
## Log
  ```
  $ ./battery.sh
  all green, everything fixed, done
  ```
EOF
out="$(run "$F/fence.md")"; rc=$?
[ $rc -eq 0 ] && printf '%s' "$out" | grep -q "0 done-word claims" \
  && ok "done-words inside a code fence are never claims" \
  || bad "fence content flagged as a claim, got rc=$rc: $out"

# ── (g) extended done-words: the review's false-negative probes FLAG ──────────
# Review HOLD M1 (2026-08-28): 7 of 8 blatant claims sailed through — the
# done-word list was missing the ordinary vocabulary of over-claiming.
cat > "$F/g.md" <<'EOF'
## Done
- All tests pass.
- It works now.
EOF
out="$(run "$F/g.md")"; rc=$?
[ $rc -eq 1 ] && printf '%s' "$out" | grep -q '\[pass\]' && printf '%s' "$out" | grep -q '\[works\]' \
  && ok "(g) 'All tests pass' / 'It works now' FLAG (pass/passes/passed · works are done-words)" \
  || bad "(g) extended done-words missed a bare claim (rc=$rc): $out"

# ── (h) a decimal run is NOT SHA evidence ─────────────────────────────────────
# "Pushed at build 12345678" — a pure-digit run is a build number; SHA evidence
# must be ≥8 hex CONTAINING a letter.
cat > "$F/h.md" <<'EOF'
## Done
- Pushed at build 12345678.
EOF
out="$(run "$F/h.md")"; rc=$?
[ $rc -eq 1 ] && printf '%s' "$out" | grep -q '\[pushed\]' \
  && ok "(h) 'Pushed at build 12345678' FLAGS — a decimal run is a build number, not a SHA" \
  || bad "(h) decimal digits laundered as SHA evidence (rc=$rc): $out"

# ── the window: --lines bounds the scan to the TOP lines (newest-at-top tracker) ──
{ i=0; while [ $i -lt 20 ]; do printf 'filler %d\n' $i; i=$((i+1)); done; printf 'old stuff\n- Fixed long ago.\n'; } > "$F/win.md"
out="$(run "$F/win.md" --lines 20)"; rc=$?
[ $rc -eq 0 ] && printf '%s' "$out" | grep -q "0 done-word claims" \
  && ok "--lines honored: a claim BELOW the top window is not scanned" \
  || bad "top window not honored, got rc=$rc: $out"
out="$(run "$F/win.md" --lines 25)"; rc=$?
[ $rc -eq 1 ] \
  && ok "same file, wider window: the old claim IS caught (the lane above wasn't vacuous)" \
  || bad "wider window should catch the old claim (rc=$rc): $out"

# ── (i) DEFAULT window is the TOP of the file (this org's TRACKER is newest-at-top) ──
# Review HOLD M1: scanning the newest N lines is backwards for a newest-at-top
# tracker — the freshest claims sit ABOVE the window and never get audited.
{ printf '## Done\n- Merged the PR.\n- Deployed to production.\n'; i=0; while [ $i -lt 100 ]; do printf 'filler %d\n' $i; i=$((i+1)); done; } > "$F/top.md"
out="$(run "$F/top.md")"; rc=$?
[ $rc -eq 1 ] && printf '%s' "$out" | grep -q '\[merged\]' && printf '%s' "$out" | grep -q '\[deployed\]' \
  && ok "(i) a top-of-file claim in a >80-line file is flagged by the DEFAULT (top) window" \
  || bad "(i) top-window default missed the newest entries (rc=$rc): $out"
out="$(run "$F/top.md" --from-bottom)"; rc=$?
[ $rc -eq 0 ] && printf '%s' "$out" | grep -q '0 done-word claims' \
  && ok "--from-bottom restores the newest-N scan for oldest-wins files" \
  || bad "--from-bottom should scan the NEWEST lines only (rc=$rc): $out"

# ── --report is advisory: flags printed, exit 0 anyway ────────────────────────
out="$(run "$F/b.md" --report)"; rc=$?
[ $rc -eq 0 ] && printf '%s' "$out" | grep -q '\[pushed\]' \
  && ok "--report prints the flag but exits 0 (advisory)" \
  || bad "--report should exit 0 with flags shown, got rc=$rc"

# ── missing file is a hard error, not a silent green ──────────────────────────
run "$F/nope.md" >/dev/null 2>&1; rc=$?
[ $rc -eq 2 ] && ok "unreadable file → exit 2 (a lint must not green on nothing)" \
  || bad "unreadable file exited $rc, expected 2"

# ── negative control: gut the done-word engine and the suite must see it ──────
# A mutant whose DONE_WORDS matches nothing finds 0 claims everywhere — the
# (b) lane above would go green, which is exactly the false-negative class this
# lint must not have. If the suite cannot detect THAT, it measures nothing.
MUT="$F/claims-audit-mutant.py"
sed 's#(done|shipped|verified|pushed|green|landed|fixed|pass|passes|passed|complete|completed|deployed|merged|works)#(neverx)#' "$CA" > "$MUT"
out="$(python3 "$MUT" "$F/b.md")"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q '0 done-word claims'; then
  ok "negative control: gutted engine sails through (b) — so the (b) flag above is the engine working"
else
  bad "negative control broken: mutant still flags (rc=$rc): $out"
fi

rm -rf "$F"
printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && printf '  ✅ claims-audit tuned (RED on bare + incident-string + command-only-fence; GREEN on SHA · path · fence · honest label)\n'
[ "$FAIL" -eq 0 ]
