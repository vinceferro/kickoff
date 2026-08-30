#!/usr/bin/env bash
# orphaned-work-selftest.sh — prove agent work that outlived its session is FOUND, FILED, and READ.
#
#   bash scripts/orphaned-work-selftest.sh
#
# The bug this whole path exists to prevent is not a missing write — Claude Code already persists
# every subagent transcript. It is that NOTHING READS IT. So the load-bearing assertions here are
# the read ones: a salvaged checkpoint must appear in the rendered TRACKER.md under the exact
# tracker item it belongs to, and a checkpoint that matches no active item must still be surfaced
# rather than silently swallowed.
#
# RED-first throughout, and every green assertion has a negative control proving it CAN go red —
# a read-side check that was never watched fail is the same write-only file in another costume.
# Hermetic: a fake $HOME with its own ~/.claude/projects tree; the real box is never touched.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
OW="$HERE/orphaned-work.py"
MC="$HERE/../mission-control/mc-update.py"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "▶ orphaned-work self-test (work outlives the session; the READ is what was missing)"
echo

F="$(mktemp -d)"; trap 'rm -rf "$F"' EXIT
H="$F/home"; REPO="$H/myrepo"
mkdir -p "$REPO/.kickoff" "$REPO/mission-control"
# The project-key encoding orphaned-work.py reverses: $HOME/myrepo -> -<home-with-dashes>-myrepo
KEY="-$(printf '%s' "${H#/}" | tr '/' '-')-myrepo"
PROJ="$H/.claude/projects/$KEY"

# ── fixture builder: one workflow run, N returned agents + M killed ones ─────────────────────
# A "killed" agent is exactly what the real corpse looks like: an agent-*.jsonl transcript on disk
# with NO matching result record in the journal.
mk_run() {                       # $1 session  $2 run-id  $3 n_returned  $4 n_killed
  local sess="$1" run="$2" nret="$3" nkill="$4" d i
  d="$PROJ/$sess/subagents/workflows/$run"; mkdir -p "$d"
  : > "$d/journal.jsonl"
  for i in $(seq 1 "$nret"); do
    printf '{"type":"started","key":"k%d","agentId":"aret%d"}\n' "$i" "$i" >> "$d/journal.jsonl"
    printf '{"type":"result","key":"k%d","agentId":"aret%d","result":"FIXTURE RESULT %d — the finding that must survive"}\n' \
      "$i" "$i" "$i" >> "$d/journal.jsonl"
    printf '{"message":{"content":[{"type":"text","text":"done %d"}]}}\n' "$i" > "$d/agent-aret$i.jsonl"
  done
  for i in $(seq 1 "$nkill"); do
    printf '{"type":"started","key":"x%d","agentId":"akill%d"}\n' "$i" "$i" >> "$d/journal.jsonl"
    printf '{"message":{"content":[{"type":"text","text":"You'"'"'ve hit your monthly spend limit · raise it at claude.ai/settings/usage"}]}}\n' \
      > "$d/agent-akill$i.jsonl"
  done
  : > "$PROJ/$sess.jsonl"
  touch -d "3 days ago" "$PROJ/$sess.jsonl"     # a quiet transcript = the session is gone
}

run_ow() { ( cd "$REPO" && HOME="$H" python3 "$OW" "$@" ) 2>&1; }

# ══ 1. FIND — an interrupted run is reported, and --quiet treats it as a finding ═════════════
mk_run "sess-dead" "wf_fixture-a" 2 1
OUT="$(run_ow --here --quiet --days 30)"
chk "FIND: --quiet reports the interrupted run (2 returned, 1 killed)" \
  "printf '%s' \"\$OUT\" | grep -q 'wf_fixture-a'"
chk "FIND: it names the returned count, not just the run"  "printf '%s' \"\$OUT\" | grep -q '2 returned'"
chk "FIND: it names the killed count"                      "printf '%s' \"\$OUT\" | grep -q '1 killed'"
chk "FIND: --why labels the killed agent's cause of death from its own transcript" \
  "run_ow --why wf_fixture-a | grep -q 'KILLED (spend/usage limit)'"
chk "FIND: --why labels the survivors as RETURNED"  "run_ow --why wf_fixture-a | grep -q 'RETURNED'"

# ── NEGATIVE CONTROL for the boot-check contract: a run where NOTHING was killed is not a
#    finding, and --quiet must then print NOTHING AT ALL. Without this, a --quiet that always
#    printed would look identical on a green box and cost every worker tokens forever.
rm -rf "$PROJ/sess-dead"
mk_run "sess-clean" "wf_fixture-clean" 3 0
OUT="$(run_ow --here --quiet --days 30)"
chk "NEGATIVE CONTROL: no interrupted run → --quiet prints absolutely nothing" "[ -z \"\$OUT\" ]"
chk "...but the same run IS visible in the normal listing (it was found, just not flagged)" \
  "run_ow --here --days 30 | grep -q 'wf_fixture-clean'"

# ── liveness: a run whose session is still writing belongs to a LIVE session — hidden by default
mk_run "sess-live" "wf_fixture-live" 1 1
touch "$PROJ/sess-live.jsonl"                    # fresh mtime = alive
chk "LIVENESS: a live session's run is hidden by default (it may still consume it)" \
  "! run_ow --here --days 30 --quiet | grep -q 'wf_fixture-live'"
chk "LIVENESS: --all reveals it"  "run_ow --here --days 30 --all | grep -q 'wf_fixture-live'"

# ══ 2. FILE — salvage lands under the tracker item, keyed by VERBATIM text ═══════════════════
ITEM="Ship the checkout slice"
OUT="$(run_ow --dump wf_fixture-clean --item "$ITEM")"
CP="$(find "$REPO/.kickoff/checkpoints" -name '*.md' | head -1)"
chk "FILE: --dump wrote checkpoint file(s)"                "[ -n \"$CP\" ]"
chk "FILE: 3 returned agents → 3 checkpoint files"         "[ \$(find '$REPO/.kickoff/checkpoints' -name '*.md' | wc -l) -eq 3 ]"
chk "FILE: the VERBATIM item text is the front-matter join key (not the slug)" \
  "grep -qxF 'item: $ITEM' '$CP'"
chk "FILE: the agent's actual returned content is in the body (not a summary of it)" \
  "grep -q 'FIXTURE RESULT' '$CP'"
chk "FILE: it records where it was recovered from (so the full transcript stays reachable)" \
  "grep -q '^recovered_from:' '$CP'"

# ── the pointer path: .kickoff/active-item is read when --item is omitted
rm -rf "$REPO/.kickoff/checkpoints"
printf '%s\n' "$ITEM" > "$REPO/.kickoff/active-item"
run_ow --dump wf_fixture-clean >/dev/null
chk "FILE: .kickoff/active-item is used when --item is omitted" \
  "grep -rqxF 'item: $ITEM' '$REPO/.kickoff/checkpoints'"

# ── and with NO pointer at all, salvage is still kept — never dropped on the floor
rm -rf "$REPO/.kickoff/checkpoints" "$REPO/.kickoff/active-item"
run_ow --dump wf_fixture-clean >/dev/null
chk "FILE: with no active item the work lands in _unfiled/ rather than being lost" \
  "[ -d '$REPO/.kickoff/checkpoints/_unfiled' ]"

# ══ 3. READ — the whole point: does a fresh session actually SEE it? ═════════════════════════
render() { HOME="$H" python3 "$MC" render-tracker \
             --file "$REPO/mission-control/mission-state.json" --out "$REPO/TRACKER.md" >/dev/null 2>&1; }
printf '{"project":"fx","in_progress":[{"text":"%s"}],"human_plate":[],"backlog":[],"functions":[],"blocked":[],"decided":[],"done":[],"activity":[]}\n' \
  "$ITEM" > "$REPO/mission-control/mission-state.json"

rm -rf "$REPO/.kickoff/checkpoints"
render
chk "READ NEGATIVE CONTROL: with no checkpoints, the tracker shows NO recovered-work line" \
  "! grep -q 'recovered checkpoint' '$REPO/TRACKER.md'"

printf '%s\n' "$ITEM" > "$REPO/.kickoff/active-item"
run_ow --dump wf_fixture-clean >/dev/null
render
chk "READ: the rendered TRACKER.md surfaces the recovered checkpoints" \
  "grep -q 'recovered checkpoint' '$REPO/TRACKER.md'"
chk "READ: they are attached to the RIGHT in-progress item" \
  "grep -A2 -F '$ITEM' '$REPO/TRACKER.md' | grep -q 'recovered checkpoint'"
chk "READ: the tracker gives the path to actually open" \
  "grep -q '.kickoff/checkpoints/' '$REPO/TRACKER.md'"

# ── nothing may vanish: a checkpoint filed against an item that is NOT in progress (finished,
#    re-worded, or _unfiled) must STILL be rendered, or salvage silently disappears from view.
printf '{"project":"fx","in_progress":[{"text":"something else entirely"}],"human_plate":[],"backlog":[],"functions":[],"blocked":[],"decided":[],"done":[],"activity":[]}\n' \
  > "$REPO/mission-control/mission-state.json"
render
chk "READ: a checkpoint matching NO active item still appears (under 'not matched')" \
  "grep -q 'Recovered work not matched to an active item' '$REPO/TRACKER.md'"
chk "READ: ...and it names the item it was filed under" \
  "grep -qF '$ITEM' '$REPO/TRACKER.md'"

# ── the render must never explode on a malformed checkpoint; a tracker is not optional.
#    Assert the fixture EXISTS before asserting on it — the first version of this check wrote into
#    a directory a previous step had deleted, so it passed while exercising nothing.
mkdir -p "$REPO/.kickoff/checkpoints/_unfiled"
printf 'not front matter at all\n'      > "$REPO/.kickoff/checkpoints/_unfiled/broken.md"
printf -- '---\nrun: x\n---\nno item\n' > "$REPO/.kickoff/checkpoints/_unfiled/no-item.md"
chk "ROBUST fixture is real (both malformed files exist)" \
  "[ -s '$REPO/.kickoff/checkpoints/_unfiled/broken.md' ] && [ -s '$REPO/.kickoff/checkpoints/_unfiled/no-item.md' ]"
render; RC=$?
chk "ROBUST: malformed checkpoints (no front matter / no item:) do not break the render" "[ $RC -eq 0 ]"
chk "ROBUST: ...and the render still produced a tracker" "[ -s '$REPO/TRACKER.md' ]"

# ══ 7. NOTIFY-ONCE — the ledger that lets the boot check look back weeks ═════════════════════
# The window used to be 2 days ONLY because this check had no memory: anything wider re-printed
# the same finding at every boot until it aged out. That narrowness is what let returned agent
# output sit unread for twelve days in a real org while its boot check ran clean every time.
# These lanes hold the contract that buys the wider window.
LG="$F/ledger.json"
rm -f "$LG"
mk_run "sess-led" "wf_led-rich" 2 1            # salvageable: agents returned
OUT1="$(run_ow --here --quiet --days 30 --ledger "$LG")"
chk "LEDGER: a FRESH finding is reported in full" \
  "printf '%s' \"\$OUT1\" | grep -q 'wf_led-rich'"
OUT2="$(run_ow --here --quiet --days 30 --ledger "$LG")"
chk "LEDGER: the SECOND boot does not re-print it" \
  "! printf '%s' \"\$OUT2\" | grep -q '08-\|wf_led-rich —'"
chk "LEDGER: ...it collapses to a one-line tail instead of vanishing" \
  "printf '%s' \"\$OUT2\" | grep -q 'older finding'"

# NEGATIVE CONTROL: "quiet on the second run" is also what a totally broken check produces.
# A fresh ledger must make the SAME corpus report in full again.
OUT3="$(run_ow --here --quiet --days 30 --ledger "$F/fresh.json")"
chk "NEGATIVE CONTROL: a fresh ledger re-reports it — so the quiet above meant dedupe, not breakage" \
  "printf '%s' \"\$OUT3\" | grep -q 'wf_led-rich'"

# --replay must show everything again AND record nothing (it is a read-only lens).
# Point it at a path that does NOT exist and assert the file is never created. The earlier
# version of this lane compared the md5 of an EXISTING ledger before and after — and a mutant
# that made --replay write survived it, because the ledger's only varying field is a
# second-granularity timestamp and the suite runs both writes inside the same second, producing
# a byte-identical file. The lane was satisfied by the defect. Existence is timing-independent.
LG_RO="$F/replay-must-not-create.json"; rm -f "$LG_RO"
OUT4="$(run_ow --here --quiet --days 30 --ledger "$LG_RO" --replay)"
chk "LEDGER: --replay shows the full finding again" "printf '%s' \"\$OUT4\" | grep -q 'wf_led-rich'"
chk "LEDGER: --replay records NOTHING (it never even creates the ledger)" "[ ! -f '$LG_RO' ]"

# Salvaging is the resolution: it must retire the run from the tail entirely.
run_ow --dump wf_led-rich --item "ledger lane" --ledger "$LG" >/dev/null
OUT5="$(run_ow --here --quiet --days 30 --ledger "$LG")"
chk "LEDGER: salvaging retires it — the tail is gone" "[ -z \"\$OUT5\" ]"

# A run where EVERY agent was killed returned nothing, so --dump refuses it by design. Carrying
# it as 'still unsalvaged' forever would be a nag that can never be closed.
LG2="$F/ledger2.json"; rm -f "$LG2"     # define BEFORE use — set -u catches the other order
mk_run "sess-empty" "wf_led-empty" 0 3
OUT6="$(run_ow --here --quiet --days 30 --ledger "$LG2")"
chk "LEDGER: an unsalvageable (0-returned) run is still reported the first time" \
  "printf '%s' \"\$OUT6\" | grep -q 'wf_led-empty'"
OUT7="$(run_ow --here --quiet --days 30 --ledger "$LG2")"
# Assert the actual claim — THIS run does not recur — not "total silence". This ledger is fresh,
# so it still legitimately carries the salvageable run from the lanes above in its tail; demanding
# an empty string here asserted a property of the whole corpus rather than of the 0-returned run.
chk "LEDGER: ...but the unsalvageable run never becomes a permanent nag" \
  "! printf '%s' \"\$OUT7\" | grep -q 'wf_led-empty'"

# FAIL OPEN: bookkeeping must never swallow a finding. A corrupt ledger re-reports rather than
# hiding — noise is recoverable, a silently dropped finding is not.
printf 'not json' > "$F/corrupt.json"
OUT8="$(run_ow --here --quiet --days 30 --ledger "$F/corrupt.json")"
chk "LEDGER: a CORRUPT ledger fails OPEN — the finding is still reported" \
  "printf '%s' \"\$OUT8\" | grep -q 'wf_led-empty'"

# The default location is per-repo, so each org owns its own ledger.
rm -f "$REPO/.kickoff/orphan-notified.json"
run_ow --here --quiet --days 30 >/dev/null
chk "LEDGER: the default ledger is written per-repo at .kickoff/orphan-notified.json" \
  "[ -s '$REPO/.kickoff/orphan-notified.json' ]"

echo
echo "──────────────────────────────"
echo "  $PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
  echo "  ✅ salvaged work is found, filed under its tracker item, and READ back by the render"
  exit 0
fi
echo "  ❌ see failures above"; exit 1
