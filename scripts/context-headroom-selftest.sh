#!/usr/bin/env bash
# context-headroom-selftest.sh — RED-first lanes for the compaction blindness in context-headroom.py
#
# WHY THIS SUITE EXISTS, precisely: `current / turns` was used as a worker's cost-per-turn and it
# is wrong across an autocompaction — it divides POST-reset context by the WHOLE session's turns.
# A real memory recorded 612 tokens/turn for a worker actually growing ~1,630, and built a causal
# claim ("cost tracks delegation inversely") on top of it. CLAUDE.md warned about the trap in prose;
# the prose did not hold, because nothing counted resets. These lanes are that check.
#
# Every lane was watched going RED before being allowed to pass. Where a lane CANNOT go red
# against the pre-fix build it is named as such rather than left to look like proof — a lane with
# no way to fail is decoration, and blurring the two is how this suite once carried three live
# mutants at 27 green.
#
# MUST-NOT-BREAK lanes (they assert behaviour the pre-fix code already had and the fix had to
# preserve, so they read the same on either side): the record-less-collapse lane, the "render
# completes" lane, the 1M-window collapse lane, the small-window churn lane, and the negative
# controls that pin a threshold by hand. Each one that can carry its own control does: same
# fixture, threshold moved, verdict flips.
#
# Where a lane could not go red against the previous BUILD but a mutation still kills it, the
# mutation is the evidence and it is named here so it can be re-run:
#   `"resets": max(compactions, drops)` -> `compactions + drops`   (built into the suite: SUMSTUB)
#   `"current": turns[-1]`              -> `max(turns)`
#   the `msg.get("model") == "<synthetic>"` check                  -> deleted
#   `return max(RESET_DROP_FLOOR, peak // 2)` -> `return peak // 2`
#   `.get("isCompactSummary")` -> a key that does not exist        (kills the PRIMARY detector)
#   each clause of the per-row ⓘ condition, dropped one at a time:
#     `drop_blind` / `not resets` / `growth is not None` -> deleted, and the whole condition
#     -> `True`. The depth cut this condition replaced (`r["turns"] >= DEEP_ENOUGH`, =20) is its
#     own RED build: the current suite fails against it on the 3-turn row.
# All six survived this suite in some earlier shape; all six are killed by it now.
#
# Run the whole suite against any other build with CONTEXT_HEADROOM_TOOL=/path/to/other.py — that
# is how the RED-first evidence for the 2026-08-12 fix passes was taken.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
TOOL="$REPO/scripts/context-headroom.py"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  [ ok ] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A transcript whose usage series is given on the command line, one assistant turn per value.
# `--compact-at N` inserts the isCompactSummary record before turn N, exactly as the runtime writes
# it: a `user` record with NO usage block (which is why a usage-only prefilter never sees it).
#
# Two non-numeric tokens stand for the records that are NOT turns, copied from what the runtime
# actually writes on this box:
#   SYN  — a rate-limit / API-error notice: an `assistant` record with model "<synthetic>" and
#          every usage field 0. It never read a context window.
#   ZERO — the same impossibility from the other side: a REAL model name with an all-zero usage
#          block. A real assistant turn cannot read 0 tokens; the system prompt alone is ~43k.
#   SYN=<n> — the NAME with no zero behind it: model "<synthetic>" carrying a real usage figure.
#          Nothing on this box writes this today; it exists so the name check can be tested on its
#          own, because with SYN the zero filter catches the record first and the name check is
#          then unreachable dead weight that no lane would notice being deleted.
mk() { python3 - "$@" <<'PYEOF'
import json, sys
out, args = sys.argv[1], sys.argv[2:]
compact_at = None
if "--compact-at" in args:
    i = args.index("--compact-at"); compact_at = int(args[i + 1]); del args[i:i + 2]
with open(out, "w") as fh:
    for n, a in enumerate(args):
        if compact_at is not None and n == compact_at:
            fh.write(json.dumps({"type": "user", "isCompactSummary": True,
                                 "message": {"role": "user", "content": "compacted"}}) + "\n")
        model, v = "claude-opus-5", 0
        if a == "SYN":
            model = "<synthetic>"
        elif a.startswith("SYN="):
            model, v = "<synthetic>", int(a[4:])
        elif a != "ZERO":
            v = int(a)
        fh.write(json.dumps({"type": "assistant", "message": {
            "id": "m%d" % n, "model": model, "role": "assistant", "content": [],
            "usage": {"input_tokens": v, "cache_read_input_tokens": 0,
                      "cache_creation_input_tokens": 0}}}) + "\n")
PYEOF
}

field() { # $1=transcript $2=field ; CONTEXT_HEADROOM_TOOL overrides the tool per call
  # CONTEXT_HEADROOM_RESET_DROP pins the EFFECTIVE threshold WITHOUT editing the tool, which is
  # what lets a threshold lane carry its own negative control: the same fixture, the same code, a
  # different threshold, the opposite verdict.
  #
  # It patches BOTH shapes on purpose. Builds up to 2026-08-12 read a flat module constant
  # RESET_DROP; this build derives the threshold per session from the peak. Patching only one of
  # them would leave the override silently inert against the other build — and the whole value of
  # CONTEXT_HEADROOM_TOOL is taking RED-first evidence against a build that is NOT this one, so an
  # override that quietly does nothing there would make that evidence a lie.
  # CONTEXT_HEADROOM_RESET_FLOOR patches only the floor, leaving the peak scaling live.
  python3 - "${CONTEXT_HEADROOM_TOOL:-$TOOL}" "$1" "$2" <<'PYEOF'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("ch", sys.argv[1])
ch = importlib.util.module_from_spec(spec); spec.loader.exec_module(ch)
if os.environ.get("CONTEXT_HEADROOM_RESET_DROP"):
    n = int(os.environ["CONTEXT_HEADROOM_RESET_DROP"])
    ch.RESET_DROP = n                             # flat-constant builds
    ch.reset_drop = lambda peak, _n=n: _n         # peak-derived builds
if os.environ.get("CONTEXT_HEADROOM_RESET_FLOOR"):
    ch.RESET_DROP_FLOOR = int(os.environ["CONTEXT_HEADROOM_RESET_FLOOR"])
a = ch.analyse(sys.argv[2]) or {}
print(a.get(sys.argv[3], "MISSING"))
PYEOF
}

printf '\n[context-headroom selftest] %s\n\n' "$TOOL"

# A COMMITTED MUTANT, not a stub: the tool under test with `max(compactions, drops)` rewritten to
# `compactions + drops`, and nothing else. It is how the compaction fixture below proves it drives
# BOTH detectors — with only one firing, max and sum agree and the fixture asserts nothing about
# the choice between them. That is not hypothetical: it is precisely how this suite reached 27
# green while the sum mutant lived, doubling every genuine flag on real data.
SUMSTUB="$TMP/sum-mutant.py"
if python3 - "${CONTEXT_HEADROOM_TOOL:-$TOOL}" "$SUMSTUB" <<'PYEOF'
import sys
src = open(sys.argv[1]).read()
out = src.replace('"resets": max(compactions, drops)', '"resets": compactions + drops')
sys.exit(1) if out == src else open(sys.argv[2], "w").write(out)
PYEOF
then :; else
  bad "could not build the sum mutant — the max-vs-sum lane below is not asserting anything"
fi

# ── a CLEAN session: no resets, and growth is the actual slope ──────────────────────────────
# 10 turns climbing 10k each. Ten turns hold NINE deltas of 10,000, so the slope is 10,000 and
# `growth` has to say 10,000.
#
# This lane used to assert 9,000 and its comment called 9,000 "the real slope" — the suite
# encoding the bug it exists to catch. `grown // len(turns)` divides n-1 deltas by n turns, so
# every session reads cheaper than it is, always in the flattering direction, and worse the
# shorter the session: 10 turns 10% under, 2 turns 50% under, 1 turn reads 0. A green suite
# asserting the wrong arithmetic is worse than no suite, because it makes the correct fix look
# like the regression.
mk "$TMP/clean.jsonl" 10000 20000 30000 40000 50000 60000 70000 80000 90000 100000
check "clean session reports 0 resets" "$(field "$TMP/clean.jsonl" resets)" "0"
check "clean session growth is the real slope (9 deltas of 10k)" "$(field "$TMP/clean.jsonl" growth)" "10000"

# ── a COMPACTED session: the exact shape that produced the 612 ──────────────────────────────
# Climbs to 940k, compacts to 10k, climbs again. The naive current/turns is a fraction of the
# true growth — that gap IS the defect.
#
# The FALL here is load-bearing and it was not, which cost a live lane. This fixture collapsed
# 500k->10k, a 490,000 fall chosen when RESET_DROP was 100_000 and any largish number sufficed.
# Raising the threshold to half the window put 490,000 UNDER it, so the drop detector went silent
# here and only the record detector fired — leaving max(compactions, drops) and compactions+drops
# indistinguishable on the one fixture whose whole job is to tell them apart. The sum mutant
# survived the entire suite at 27/0 while doubling every genuine flag on real data. Cut into the
# measured population instead: every compaction observed on this box falls 920,240-946,993 from a
# near-full window, so the fixture falls 930,000 and BOTH detectors fire, which is the only way
# the max-vs-sum choice below is actually asserted.
mk "$TMP/compacted.jsonl" 200000 500000 700000 940000 --compact-at 4 10000 60000 110000 160000 210000
# The naive number is derived from the tool's own output rather than restated as a literal — a
# hand-written `210000 // 10` silently stopped matching the fixture the moment it was re-cut.
NAIVE=$(python3 -c "print($(field "$TMP/compacted.jsonl" current) // $(field "$TMP/compacted.jsonl" turns))")
check "compaction is detected" "$(field "$TMP/compacted.jsonl" resets)" "1"
GROWTH=$(field "$TMP/compacted.jsonl" growth)
if [ "$GROWTH" -gt "$((NAIVE * 2))" ]; then
  ok "growth ($GROWTH) is not fooled by the reset (naive current/turns says $NAIVE)"
else
  bad "growth ($GROWTH) tracked the naive current/turns baseline ($NAIVE) — either the reset was not excluded from growth, or `current` itself is wrong"
fi

# ── the record and the usage-drop are ONE event, not two ────────────────────────────────────
# Both detectors fire on the fixture above — the record IS present and the 930,000 fall IS over
# the threshold, which is exactly what the re-cut restored. Counting both would report 2 resets
# for 1 compaction, a number that would get quoted at an operator.
check "one compaction counts once, not once per detector" "$(field "$TMP/compacted.jsonl" resets)" "1"
check "...and both detectors really do fire here (else the line above asserts nothing)" \
      "$(CONTEXT_HEADROOM_TOOL="$SUMSTUB" field "$TMP/compacted.jsonl" resets)" "2"

# ── the RECORD detector, alone, with no drop to hide behind ──────────────────────────────────
# Driving BOTH detectors from one fixture is what pins max-vs-sum above — and it is also how the
# PRIMARY detector ended up defended by nothing. That re-cut made the 930,000 fall carry every
# lane, and this was the only fixture where the isCompactSummary record had been the sole reason a
# reset was flagged; afterwards no fixture used --compact-at without a qualifying drop beside it.
# Mutating `.get("isCompactSummary")` to a key that does not exist then left this suite at 46 green
# and 1 red, and the one red was the meta-assertion directly above — whose text reads "the line
# above asserts nothing", not "detection is broken". The lanes literally named "compaction is
# detected" and "one compaction counts once" both went GREEN with the primary detector dead. The
# same disease as the sum mutant, mirrored onto the other detector, introduced by its cure.
#
# So: a compaction whose fall is UNDER the threshold. Peak 500,000 puts the threshold at 250,000
# and the largest fall here is 500,000-460,000 = 40,000, so the drop detector cannot fire and the
# record is the only signal there is. That is not a contrived shape — measured 2026-08-12 over the
# 130 top-level transcripts this tool actually globs, 19 of the 93 sessions with 3+ turns are
# drop_blind, and on every one of them the record is the only detector that can fire at all.
mk "$TMP/recordonly.jsonl" 300000 400000 500000 --compact-at 3 460000 480000 500000
mk "$TMP/norecord.jsonl"   300000 400000 500000 460000 480000 500000
check "a compaction with NO qualifying drop is detected by the record alone" \
      "$(field "$TMP/recordonly.jsonl" resets)" "1"
check "...and the identical series WITHOUT the record reads clean (so it is not the drop firing)" \
      "$(field "$TMP/norecord.jsonl" resets)" "0"

# ── a reset with NO isCompactSummary record still counts ────────────────────────────────────
# The flag must not depend on one field name staying stable across CLI versions. This is also
# the lane that stops the RESET_DROP fix from "working" by simply never firing.
#
# The MAGNITUDE here is load-bearing and it did not used to be. This fixture collapsed 500k->10k,
# a 490k fall picked when the threshold was 100_000 and any largish number would do. The
# threshold is now calibrated against the real population — every genuine compaction measured on
# this box falls 920,240-946,993, from a near-full window — so a fixture has to sit IN that
# population to be testing the real shape. 490k was a number that no observed compaction has ever
# produced, and leaving it here would have pinned the threshold to a fiction.
mk "$TMP/silentdrop.jsonl" 500000 700000 940000 10000 60000 110000
check "a genuine record-less ~930k collapse is still detected" "$(field "$TMP/silentdrop.jsonl" resets)" "1"
check "negative control: an over-raised RESET_DROP blinds that collapse" \
      "$(CONTEXT_HEADROOM_RESET_DROP=10000000 field "$TMP/silentdrop.jsonl" resets)" "0"

# ── ordinary churn is NOT a reset ───────────────────────────────────────────────────────────
# Context falls all the time (a tool result ages out, a smaller turn). Only a collapse counts.
mk "$TMP/churn.jsonl" 300000 320000 290000 310000 280000 300000
check "normal churn is not reported as a reset" "$(field "$TMP/churn.jsonl" resets)" "0"

# ── a <synthetic> notice mid-series is NOT a turn ───────────────────────────────────────────
# Claude Code writes rate-limit and API-error notices as an `assistant` record with model
# "<synthetic>" and an all-zero usage block. Admitted to the series, that 0 was the single
# largest source of wrong numbers in this tool: the fall to 0 crosses RESET_DROP (so `resets`
# read 1 on a session that never compacted — 12 of the 20 flagged sessions on this box) and the
# climb back to real fill re-enters as one huge positive delta (so `growth` inflates: the worst
# case on this box read 15,888/turn against a corrected 894).
#
# The fill has to be REAL-SIZED for this lane to bite: the notice does its damage by dropping the
# series from wherever the session actually was, and the sessions this hit on this box were at
# 128k-422k when the notice landed. A toy 50k series makes the same fixture pass against the
# broken code for the wrong reason. `synthbase` is the identical series without the notice — the
# splice must change NOTHING.
mk "$TMP/synthbase.jsonl" 200000 300000 400000 500000 600000     700000 800000 900000
mk "$TMP/synthmid.jsonl"  200000 300000 400000 500000 600000 SYN 700000 800000 900000
check "a mid-series <synthetic> notice is not a reset" "$(field "$TMP/synthmid.jsonl" resets)" "0"
check "a mid-series <synthetic> notice is not a turn" \
      "$(field "$TMP/synthmid.jsonl" turns)" "$(field "$TMP/synthbase.jsonl" turns)"
check "a mid-series <synthetic> notice does not inflate growth" \
      "$(field "$TMP/synthmid.jsonl" growth)" "$(field "$TMP/synthbase.jsonl" growth)"
# 8 values are SEVEN deltas. The label said eight — an n-vs-n-1 miscount inside the suite whose
# entire subject is n-vs-n-1. The asserted 100000 was right (700,000 over 7 deltas); only the
# printed claim was wrong, which is the version of this bug that survives a green run.
check "...and that shared slope is the real one (7 deltas of 100k)" \
      "$(field "$TMP/synthmid.jsonl" growth)" "100000"

# The model name is not the load-bearing part — the zero is. A record with a real model name and
# an all-zero usage block has to be dropped on the same grounds, or the filter is a name check
# that stops working the day the runtime renames "<synthetic>".
mk "$TMP/zeromid.jsonl" 200000 300000 400000 500000 600000 ZERO 700000 800000 900000
check "an all-zero usage record is not a reset even under a real model name" "$(field "$TMP/zeromid.jsonl" resets)" "0"
check "an all-zero usage record is not a turn either" \
      "$(field "$TMP/zeromid.jsonl" turns)" "$(field "$TMP/synthbase.jsonl" turns)"

# ...and the NAME check is not thereby redundant. Every fixture above pairs "<synthetic>" with an
# all-zero usage block, because that is the only pairing the runtime writes today — so the zero
# filter catches all of them FIRST and the name check was unreachable. Deleting it outright left
# the suite fully green, which means it was shipped, documented and defended by nothing.
#
# This lane splits the two: a "<synthetic>" record carrying REAL usage. Only the name can exclude
# it. That also pins the ORDER the code currently only implies — the name is tested BEFORE the
# read, so a notice is dropped on identity rather than on happening to read zero.
mk "$TMP/synthbase4.jsonl" 200000 300000 400000 500000
mk "$TMP/synthreal.jsonl"  200000 300000 400000 SYN=900000 500000
check "a <synthetic> record with NON-ZERO usage is excluded by the name alone (turns)" \
      "$(field "$TMP/synthreal.jsonl" turns)" "$(field "$TMP/synthbase4.jsonl" turns)"
check "a <synthetic> record with NON-ZERO usage does not become the peak" \
      "$(field "$TMP/synthreal.jsonl" peak)" "500000"

# ── a TRAILING <synthetic> notice must not become the reading ───────────────────────────────
# `current` is the newest turn, so a session that ended on a rate-limit notice printed 0k / 0% /
# an empty headroom bar — the strongest possible "safe to keep going" signal this tool can emit —
# on real sessions that had peaked at 128k-422k. `model` leaked "<synthetic>" beside it. Whatever
# else this tool gets wrong, it must never answer "am I safe to keep going" with a confident,
# inverted yes.
#
# The series is deliberately NOT monotone. It used to climb 100k->400k, which made current, peak
# and max(turns) all 400000 at once — so `"current": turns[-1]` rewritten to `max(turns)` read
# identically and survived the whole suite. `current` is the NEWEST turn, not the largest one, and
# the difference is the entire question this tool answers; peaking at 500k and ending at 400k is
# what separates them.
mk "$TMP/synthtail.jsonl" 100000 500000 300000 400000     SYN
check "a trailing <synthetic> notice does not zero the current fill" "$(field "$TMP/synthtail.jsonl" current)" "400000"
check "current is the NEWEST turn, not the largest (peak differs here on purpose)" \
      "$(field "$TMP/synthtail.jsonl" peak)" "500000"
check "a trailing <synthetic> notice does not leak into the model field" "$(field "$TMP/synthtail.jsonl" model)" "claude-opus-5"
check "a trailing <synthetic> notice is not a reset" "$(field "$TMP/synthtail.jsonl" resets)" "0"

# ── a 150k fall is CHURN, not a compaction ──────────────────────────────────────────────────
# RESET_DROP shipped at 100_000 — 10% of a 1M window — so ordinary churn crossed it. Measured on
# every transcript on this box the two populations do not come close: 10 genuine compaction drops
# span 920,240-946,993, and the largest ordinary fall between two real turns is 103,424. A real
# 940k-fill session printed "94% ← refresh zone" AND "COMPACTED 1x" at once, which tells the
# operator that a correct and alarming number is untrustworthy.
mk "$TMP/bigchurn.jsonl" 400000 550000 400000 560000 410000
check "a 150k churn drop is not a reset" "$(field "$TMP/bigchurn.jsonl" resets)" "0"
check "negative control: the shipped RESET_DROP=100000 called that churn 2 resets" \
      "$(CONTEXT_HEADROOM_RESET_DROP=100000 field "$TMP/bigchurn.jsonl" resets)" "2"

# ── the threshold follows the SESSION, because a flat one goes dead on a smaller window ──────
# WINDOW is a hardcoded 1_000_000 that nothing derives from the running model, so a flat
# WINDOW // 2 meant that for any model whose ENTIRE window is under ~500k the drop condition was
# unreachable and this fallback was dead — silently, since window_suspect only fires on
# peak > WINDOW and never the other way. The routing table sends work to models with smaller
# windows than this box's, and this tool ships to adopters, so "dead on their model" is the
# default case, not the edge one.
#
# The threshold is now half the session's OWN observed peak, floored. That is not a heuristic
# dressed as an observable: measured 2026-08-12, all 8 sessions on this box that actually
# compacted peaked at 991,816-999,907 — a compaction empties a window that was FULL, so the peak
# IS the pre-compaction fill, and a session that compacted necessarily recorded that peak in the
# same transcript.
mk "$TMP/win1m.jsonl"   300000 600000 900000 980000 12000 60000
mk "$TMP/win200k.jsonl" 60000 120000 180000 192000 9000 45000 90000
check "1M window: a record-less near-full collapse is still detected" "$(field "$TMP/win1m.jsonl" resets)" "1"
check "1M window: the threshold is half the peak, not half an assumed window" \
      "$(field "$TMP/win1m.jsonl" drop_threshold)" "490000"
check "200k window: a record-less collapse is detected at all" "$(field "$TMP/win200k.jsonl" resets)" "1"
check "negative control: the flat WINDOW//2 threshold was blind to that same collapse" \
      "$(CONTEXT_HEADROOM_RESET_DROP=500000 field "$TMP/win200k.jsonl" resets)" "0"

# ...and widening it must not re-open the false-positive class the raise was for. No ordinary fall
# in the whole 2,395-transcript corpus reaches 103,424, and the floor sits 1.45x above that.
mk "$TMP/churn200k.jsonl" 150000 190000 100000 185000 95000
check "200k window: ordinary churn inside a small window is not a reset" \
      "$(field "$TMP/churn200k.jsonl" resets)" "0"
check "negative control: a threshold under that churn calls it 2 resets" \
      "$(CONTEXT_HEADROOM_RESET_DROP=50000 field "$TMP/churn200k.jsonl" resets)" "2"

# The FLOOR is the half that stops peak-scaling from re-deriving the shipped 100_000 bug on short
# sessions: this fall is 130,000, over half its own 250k peak, but under the largest ordinary fall
# ever measured plus its margin. Scaling alone would flag it; the floor is why it does not.
mk "$TMP/floorguard.jsonl" 120000 250000 120000
check "the floor blocks a fall that bare peak-scaling would have flagged" \
      "$(field "$TMP/floorguard.jsonl" resets)" "0"
check "negative control: with the floor removed, peak-scaling alone flags it" \
      "$(CONTEXT_HEADROOM_RESET_FLOOR=0 field "$TMP/floorguard.jsonl" resets)" "1"

# ── when the fallback CANNOT fire, the tool says so instead of reading clean ─────────────────
# No fall can exceed the peak, so a session peaking at or under the threshold has a structurally
# inert drop detector. Under ~160k of window that is a real compaction going unflagged, which is
# the shape this whole field exists to prevent being read as "stayed lean". Silence there is the
# original bug wearing a new threshold, so it is reported.
mk "$TMP/tinypeak.jsonl" 40000 80000 120000 30000
check "a session that cannot trip the drop detector reports drop_blind" \
      "$(field "$TMP/tinypeak.jsonl" drop_blind)" "True"
check "...and is not silently counted as a clean session either way" \
      "$(field "$TMP/tinypeak.jsonl" resets)" "0"
check "a session that CAN trip it is not marked blind" "$(field "$TMP/win200k.jsonl" drop_blind)" "False"
check "blinding the threshold by hand makes the session admit it" \
      "$(CONTEXT_HEADROOM_RESET_DROP=10000000 field "$TMP/silentdrop.jsonl" drop_blind)" "True"

# ── growth over 1-2 turns is not a measurement ──────────────────────────────────────────────
# One turn holds no delta at all and two hold one. The field answered with a number anyway —
# a confident answer to a question the sample cannot answer. Dash it instead.
mk "$TMP/oneturn.jsonl" 50000
check "growth is suppressed on a 1-turn session" "$(field "$TMP/oneturn.jsonl" growth)" "None"
mk "$TMP/twoturn.jsonl" 50000 60000
check "growth is suppressed on a 2-turn session" "$(field "$TMP/twoturn.jsonl" growth)" "None"
mk "$TMP/threeturn.jsonl" 50000 60000 70000
check "growth is reported from 3 turns up, over the deltas" "$(field "$TMP/threeturn.jsonl" growth)" "10000"

# ── END-TO-END: the RENDER has to survive what analyse() now returns ────────────────────────
# analyse() is only half the tool. A suppressed growth is safe only if the display prints it, and
# a corrected `current` is only useful if the operator sees it. transcript_for() honours
# CLAUDE_CONFIG_DIR (that is how the CLI relocates its own state), so point it at a fixture tree
# and run the real main() end to end. Column 7 is grow/t, column 3 is the context fill.
mkdir -p "$TMP/cfg/projects/-fixture-growthless" "$TMP/cfg/projects/-fixture-tailnotice"
cp "$TMP/twoturn.jsonl"   "$TMP/cfg/projects/-fixture-growthless/aaaaaaaa-0000.jsonl"
cp "$TMP/synthtail.jsonl" "$TMP/cfg/projects/-fixture-tailnotice/bbbbbbbb-0000.jsonl"
RENDER="$(CLAUDE_CONFIG_DIR="$TMP/cfg" python3 "${CONTEXT_HEADROOM_TOOL:-$TOOL}" /fixture/growthless /fixture/tailnotice 2>&1)"
check "render: a suppressed growth prints as a dash, not a number" \
      "$(printf '%s\n' "$RENDER" | awk '$1 == "growthless" {print $7}')" "-"
check "render: a session ending on a notice does not print 0k" \
      "$(printf '%s\n' "$RENDER" | awk '$1 == "tailnotice" {print $3}')" "400k"
case "$RENDER" in
  *Traceback*) bad "render: main() raised on the fixture tree" ;;
  *)           ok  "render: main() completes over both fixtures" ;;
esac

# ── END-TO-END: the inert-detector limit reaches the operator, wherever there is a number ────
# A limit that only appears in --json is the silent failure again, so the footnote states it on
# every render unconditionally and every blind reset-less row WITH A GROWTH NUMBER carries the ⓘ.
#
# This block used to assert the opposite of the lane below it: that a 3-turn session was blind but
# deliberately UNMARKED, because a `turns >= DEEP_ENOUGH` (=20) display cut sat in main(). That
# cut's whole justification was "70% are drop_blind at 3+ turns and 30% at 20+, so a marker on
# seven rows in ten is one an operator scrolls past" — measured over all 2,405 transcripts on this
# box, when the tool globs `proj + "/*.jsonl"` NON-recursively and can only ever open the 130 at
# the top level. Re-measured 2026-08-12 with the tool's own analyse() over the population it does
# read: 19/93 = 20% at 3+ turns, 8/82 = 10% at 20+. (The "30%" was additionally 636/2,014 — the
# 20+-blind count over the 3+ DENOMINATOR, a joint frequency dressed as a conditional rate; the
# real conditional there is 55%.) The cut was suppressing the note on 11 of those 19 sessions.
#
# The replacement is `growth is not None` — the same 3-turn boundary analyse() already uses to
# refuse a growth number — and NOT a frequency, so it cannot rot the way the number above did.
# Full reasoning and the render-population measurement are in main(). The five fixtures below pin
# the whole condition, `drop_blind and not resets and growth is not None`, from every side:
#   deeplow     blind, 21 turns          -> marked
#   shallowlow  blind,  3 turns          -> marked   (the flip; the old cut suppressed this)
#   tooshallow  blind,  2 turns, growth - -> NOT marked (the new cut)
#   notblind    drop detector CAN fire   -> NOT marked
#   blindreset  blind but already reset  -> NOT marked
# The three negatives are what stop "mark every row" from passing as the fix, which was the first
# version of this change and measured worse than the bug.
DEEPVALS=""; for i in $(seq 1 21); do DEEPVALS="$DEEPVALS $((i * 5000))"; done
mk "$TMP/deeplow.jsonl" $DEEPVALS
# peak 320k, threshold 160k: this row's drop detector CAN fire, so it must NOT be marked.
mk "$TMP/notblind.jsonl" 300000 320000 290000 310000 280000 300000
# blind (peak 120k <= the 150k floor) AND compacted: the reset is already shouted at the operator
# by the COMPACTED warning, so the "only a record could flag it" note is not the story on this row.
mk "$TMP/blindreset.jsonl" 40000 80000 --compact-at 2 120000
mkdir -p "$TMP/cfg/projects/-fixture-deeplow" "$TMP/cfg/projects/-fixture-shallowlow" \
         "$TMP/cfg/projects/-fixture-notblind" "$TMP/cfg/projects/-fixture-blindreset" \
         "$TMP/cfg/projects/-fixture-tooshallow"
cp "$TMP/deeplow.jsonl"    "$TMP/cfg/projects/-fixture-deeplow/cccccccc-0000.jsonl"
cp "$TMP/threeturn.jsonl"  "$TMP/cfg/projects/-fixture-shallowlow/dddddddd-0000.jsonl"
cp "$TMP/notblind.jsonl"   "$TMP/cfg/projects/-fixture-notblind/eeeeeeee-0000.jsonl"
cp "$TMP/blindreset.jsonl" "$TMP/cfg/projects/-fixture-blindreset/ffffffff-0000.jsonl"
cp "$TMP/twoturn.jsonl"    "$TMP/cfg/projects/-fixture-tooshallow/99999999-0000.jsonl"
BLIND="$(CLAUDE_CONFIG_DIR="$TMP/cfg" python3 "${CONTEXT_HEADROOM_TOOL:-$TOOL}" \
         /fixture/deeplow /fixture/shallowlow /fixture/notblind /fixture/blindreset \
         /fixture/tooshallow 2>&1)"
check "render: the floor is stated on every render, not only when it bites" \
      "$(printf '%s\n' "$BLIND" | /usr/bin/grep -c 'floored at 150k')" "1"
check "render: a deep session with an inert drop detector is marked" \
      "$(printf '%s\n' "$BLIND" | /usr/bin/grep -c '^  deeplow .*ⓘ drop-detector inert')" "1"
check "render: a 3-turn session with an inert drop detector is marked too (the cut was at 20)" \
      "$(printf '%s\n' "$BLIND" | /usr/bin/grep -c '^  shallowlow .*ⓘ drop-detector inert')" "1"
check "render: a row too short for a growth number is not marked (nothing to misread)" \
      "$(printf '%s\n' "$BLIND" | /usr/bin/grep -c '^  tooshallow .*ⓘ')" "0"
check "render: a row whose drop detector CAN fire is not marked" \
      "$(printf '%s\n' "$BLIND" | /usr/bin/grep -c '^  notblind .*ⓘ')" "0"
check "render: a blind row that ALREADY reports a reset is not marked" \
      "$(printf '%s\n' "$BLIND" | /usr/bin/grep -c '^  blindreset .*ⓘ')" "0"
check "...and --json reports every one of them blind regardless of what is annotated" \
      "$(field "$TMP/threeturn.jsonl" drop_blind)|$(field "$TMP/deeplow.jsonl" drop_blind)|$(field "$TMP/blindreset.jsonl" drop_blind)|$(field "$TMP/twoturn.jsonl" drop_blind)" \
      "True|True|True|True"
check "...while the unmarked non-blind row is genuinely not blind (else that lane is vacuous)" \
      "$(field "$TMP/notblind.jsonl" drop_blind)" "False"
check "...and the blind+compacted row really does report its reset" \
      "$(field "$TMP/blindreset.jsonl" resets)" "1"

# ── NEGATIVE CONTROL: a stub analyse() that never reports resets must fail lane 2 ────────────
STUB="$TMP/stub.py"
cat > "$STUB" <<'PYEOF'
def analyse(path):
    return {"turns": 10, "current": 210000, "peak": 500000, "delegated": 0,
            "model": "x", "resets": 0, "growth": 21000}
PYEOF
check "negative control: a reset-blind stub reports 0 on the compacted fixture" \
      "$(CONTEXT_HEADROOM_TOOL="$STUB" field "$TMP/compacted.jsonl" resets)" "0"
if [ "$(field "$TMP/compacted.jsonl" resets)" != "$(CONTEXT_HEADROOM_TOOL="$STUB" field "$TMP/compacted.jsonl" resets)" ]; then
  ok "...and the real tool disagrees with it (this suite can go RED)"
else
  bad "the real tool matches a reset-blind stub — the lanes above prove nothing"
fi

# ── OPENCODE ARM (engine parity, 2026-08-27) ──────────────────────────────────
# The arm exists because on a WORKER_ENGINE=opencode box this tool printed "no live worker
# transcripts found" — the degradation-driven refresh loop had no gauge, so a session ran
# unbounded ("claude restarted itself at critical mass; opencode just gets stuck").
#
# opencode_workers() reads /proc, which a hermetic suite cannot fake, so the arm is driven
# through its OPENCODE_BASES seam against a stub serve. The stub answers the three real
# routes with the real JSON shapes (verified against a live serve the day this shipped).
#
# The load-bearing lane is the NEGATIVE CONTROL: the same turns against a DOUBLED window must
# halve the percentage. If the tool were assuming the module's 1M default instead of reading
# limit.context off the API, both lanes would print the same number and the arm would be a lie.
echo "— opencode arm (stub serve via the OPENCODE_BASES seam) —"
OC_STUB="$TMP/oc-stub.py"
cat > "$OC_STUB" <<'OCEOF'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
REPO = sys.argv[1]; TURNS = json.loads(sys.argv[2]); CTX = int(sys.argv[3])
SESS = "ses_deadbeefcafe0001"
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/session":
            b = [{"id": SESS, "directory": REPO,
                  "model": {"id": "stub-m", "providerID": "stub-p"}, "time": {"updated": 1000}}]
        elif self.path.startswith("/session/") and self.path.endswith("/message"):
            b = [{"info": {"role": "assistant",
                           "tokens": {"input": t, "output": 1, "cache": {"read": 0}}}} for t in TURNS]
        elif self.path == "/config/providers":
            b = {"providers": [{"id": "stub-p", "models": {"stub-m": {"limit": {"context": CTX}}}}]}
        else:
            b = {}
        d = json.dumps(b).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(d))); self.end_headers(); self.wfile.write(d)
s = HTTPServer(("127.0.0.1", 0), H)
print(s.server_port, flush=True)
s.serve_forever()
OCEOF

oc_pct() {   # turns_json context_window -> the rendered percentage
  local turns="$1" ctx="$2" port line
  python3 "$OC_STUB" /fake/repo "$turns" "$ctx" > "$TMP/oc-port.$$" 2>/dev/null &
  local pid=$!
  for _ in $(seq 1 50); do
    port="$(head -1 "$TMP/oc-port.$$" 2>/dev/null)"; [ -n "$port" ] && break
    python3 -c "import time;time.sleep(0.1)"
  done
  if [ -z "$port" ]; then kill "$pid" 2>/dev/null; echo "NOPORT"; return; fi
  line="$(OPENCODE_BASES="/fake/repo=http://127.0.0.1:$port" \
          python3 "$TOOL" /fake/repo 2>/dev/null | sed -n '2p')"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  printf '%s' "$line" | sed -n 's/.*[^0-9]\([0-9]\+\)%.*/\1/p'
}

OC_1M="$(oc_pct '[100000,400000,800000]' 1000000)"
OC_2M="$(oc_pct '[100000,400000,800000]' 2000000)"
check "opencode: 800k of a 1M window renders 80%" "$OC_1M" "80"
check "opencode NEGATIVE CONTROL: same turns, 2M window renders 40% (the window is READ, not assumed)" "$OC_2M" "40"
if [ -n "$OC_1M" ] && [ "$OC_1M" != "$OC_2M" ]; then
  ok "...the two windows disagree — the arm is not printing a constant"
else
  bad "both windows rendered the same percentage — limit.context is being ignored"
fi
OC_ZONE="$(python3 "$OC_STUB" /fake/repo '[100000,400000,800000]' 1000000 > "$TMP/p2.$$" 2>/dev/null &
  for _ in $(seq 1 50); do p="$(head -1 "$TMP/p2.$$" 2>/dev/null)"; [ -n "$p" ] && break; python3 -c "import time;time.sleep(0.1)"; done
  OPENCODE_BASES="/fake/repo=http://127.0.0.1:$p" python3 "$TOOL" /fake/repo 2>/dev/null | grep -c 'refresh zone'
  pkill -f "$OC_STUB" 2>/dev/null || true)"
check "opencode: 80% trips the refresh zone (the whole point of the gauge)" "$OC_ZONE" "1"

printf '\n[context-headroom selftest] %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
