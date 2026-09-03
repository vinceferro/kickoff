#!/usr/bin/env bash
# crew-review-due.sh — is an automatic crew-review LIGHT triage due?
#
# The crew-CREATION half (distill a skill) and the drift-triage run on demand + at boundaries. This
# makes the LIGHT triage fire on a CADENCE so charter/skill/memory curation happens UNPROMPTED. The
# script ONLY answers "is it due?" — the coordinator runs the actual triage, and a charter/skill change
# it proposes still needs the human's tap (only stale-memory DATA auto-applies). Detection becomes
# automatic; mutation of the crew stays gated.
#
#   bash scripts/crew-review-due.sh          # print DUE / NOT_DUE; exit 0 iff DUE
#   bash scripts/crew-review-due.sh --mark   # record that a crew-review just ran (stamp = now)
#
# Cadence: CREW_REVIEW_CADENCE_DAYS (default 7). Marker: .kickoff/crew-review.last (epoch seconds).
# Fail-toward-DUE: a missing / corrupt marker returns DUE — a light triage is cheap and safe, but
# silently skipping drift is not. A busy session should DEFER (run it at the next natural boundary),
# never suppress it.
set -uo pipefail

# WHERE THE MARKER LIVES — per-INSTANCE state, so it belongs to the repo being worked in, NEVER to the
# core. Do NOT resolve it from "$0": on an adopter the core is a SHARED, PINNED clone that several repos
# run from, so $0's parent is the core and every instance would stamp ONE marker — the first repo to
# --mark would silence the cadence for all the others, and it would write runtime state into a checkout
# that is supposed to be pull-managed. It looks correct in the kickoff origin only because there the repo
# IS the core. The worker's cwd is the instance; $0 is the engine. Resolution order:
#   $KICKOFF_DIR (explicit, wins)  →  $PWD/.kickoff (the instance the worker is running in)
#
# The $PWD fallback is right only because the worker's cwd IS the repo root — and nothing asserted that.
# A coordinator that spans several repos spends much of a session `cd`-ed into a DIFFERENT one; a boot
# check firing from there would stamp that repo's marker, silence the cadence for the wrong project,
# leave the real one unmarked, and report nothing. (Bliz coordinator, core-v0.16 review: it `cd`s into a
# sibling repo dozens of times a day — a live risk there, not a theoretical one.) So require the cwd to
# actually BE a kickoff instance, and fail loud rather than write somewhere plausible.
KDIR="${KICKOFF_DIR:-$PWD/.kickoff}"
# Only guard the GUESS. An explicit KICKOFF_DIR or CREW_REVIEW_MARKER means the caller already said
# where this belongs, so there is nothing to infer and nothing to get wrong.
if [ -z "${KICKOFF_DIR:-}" ] && [ -z "${CREW_REVIEW_MARKER:-}" ] && [ ! -f "$KDIR/instance.env" ]; then
  echo "crew-review-due: FAILED — cwd is not a kickoff instance ($PWD has no .kickoff/instance.env)."
  echo "  Refusing to guess which project this cadence belongs to. Escape hatches: run \`kickoff init\`" \
       "in this repo (source-checkout mode — see RUNNING.md), or set KICKOFF_DIR=<repo>/.kickoff or" \
       "CREW_REVIEW_MARKER=<file>." >&2
  exit 2
fi
MARKER="${CREW_REVIEW_MARKER:-$KDIR/crew-review.last}"
CADENCE_DAYS="${CREW_REVIEW_CADENCE_DAYS:-7}"
case "$CADENCE_DAYS" in ''|*[!0-9]*) CADENCE_DAYS=7 ;; esac   # non-int → safe default

now="$(date +%s)"

if [ "${1:-}" = "--mark" ]; then
  # FAIL LOUDLY. An unwritable marker must not report success: the coordinator would believe the cadence
  # was stamped while the next boot re-fires DUE forever. A check that reports green on a failed write is
  # reporting on a world nobody lives in.
  mkdir -p "$KDIR" 2>/dev/null
  if ! printf '%s\n' "$now" > "$MARKER" 2>/dev/null; then
    # Say it on BOTH streams. exit 2 alone does not survive a pipe — and piping is the natural thing to
    # do when a boot sequence runs six checks and wants the last lines of each (`… --mark 2>&1 | tail -2`
    # discards the status and reports tail's). An stdout-only consumer would otherwise see nothing at all
    # here: no success line, no failure line, indistinguishable from silence. Reported by the Bliz
    # coordinator from its real boot flow. Keep exit 2 for callers that do check.
    echo "crew-review marker FAILED: could not write $MARKER (check the path/permissions)"
    echo "crew-review marker FAILED: could not write $MARKER (check the path/permissions)" >&2
    exit 2
  fi
  echo "crew-review marker stamped: $(date -u -d "@$now" +%FT%TZ 2>/dev/null || echo "@$now")"
  exit 0
fi

last=""
[ -f "$MARKER" ] && last="$(head -1 "$MARKER" 2>/dev/null | tr -dc '0-9')"
if [ -z "$last" ]; then
  echo "DUE (no valid marker — first run or reset)"
  exit 0
fi

window=$(( CADENCE_DAYS * 86400 ))
age=$(( now - last ))
[ "$age" -lt 0 ] && age=0                     # a future stamp (clock skew) → treat as just-run
days_since=$(( age / 86400 ))

if [ "$age" -ge "$window" ]; then
  echo "DUE (${days_since}d since last crew-review, cadence ${CADENCE_DAYS}d)"
  exit 0
else
  next=$(( (window - age + 86399) / 86400 ))  # ceil, so "next in ~1d" not "~0d"
  echo "NOT_DUE (${days_since}d since last, next in ~${next}d, cadence ${CADENCE_DAYS}d)"
  exit 1
fi
