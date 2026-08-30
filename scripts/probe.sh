#!/usr/bin/env bash
# probe.sh — a counting check that CANNOT report a vacuous green.
#
#   probe.sh --control <regex> --find <regex> [--label <text>] [file ...]
#   … | probe.sh --control <regex> --find <regex>
#
# THE BUG THIS EXISTS FOR (three times in one day, 2026-07-26):
#   · a `pgrep` pattern matched the probe's OWN command line, so one idle worker was
#     reported as two live ones;
#   · a mutation test's `sed` matched nothing, so the suite stayed green and the
#     "mutation" proved the guard was covered when it had never been applied;
#   · a health sweep grepped for `[ ok ]` while the tool emits `✓`, and printed
#     "0 ok · 0 fail" for four repos — which reads exactly like a pass.
#
# Every one is the same shape: **a probe that matched nothing reported the same thing
# as a probe that found nothing wrong.** Zero findings and a blind instrument are
# indistinguishable unless something forces them apart. That is what --control does:
# a pattern you KNOW must appear in healthy input. If the control does not match, the
# probe is blind and this exits 2 LOUDLY instead of claiming clean.
#
# This is the same discipline `memory-orphan-check.sh` already applies to itself ("an
# empty scan is a finding about the SCAN, not an all-clear"), lifted into something
# any check — or any one-off shell line — can reach for.
#
# WHAT THIS DOES NOT COVER — the sibling failure, stated so nobody assumes it does.
# A pattern can also match TOO MUCH, and the commonest case is a process scan matching
# the scanning command itself: `pgrep -f core-v0.14` counted the very shell running it,
# turning one idle worker into "two live workers". A positive control cannot see that —
# the control matches, the count is simply wrong. For process scans the mechanism is to
# exclude your own process tree explicitly, e.g.
#
#   for p in $(pgrep -x claude); do [ "$p" = "$$" ] && continue
#     tr '\0' ' ' < /proc/$p/cmdline | grep -q 'core-v0.14' && echo "$p"; done
#
# i.e. match on /proc/<pid>/cmdline for a NAMED binary, never `pgrep -f` on a substring
# that your own argv contains. Print the pids you matched, and sanity-check the count
# against something independent before reporting it.
#
# Exit codes:  0 = control matched AND no findings (a real green)
#              1 = findings (they are printed)
#              2 = BLIND: the control never matched, so the result means nothing
#              3 = usage error
set -uo pipefail

CONTROL=""; FIND=""; LABEL="probe"; FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --control) CONTROL="${2:?--control needs a regex}"; shift 2 ;;
    --find)    FIND="${2:?--find needs a regex}";       shift 2 ;;
    --label)   LABEL="${2:?--label needs text}";        shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 3 ;;
    --) shift; FILES+=("$@"); break ;;
    -*) printf 'probe: unknown flag %s\n' "$1" >&2; exit 3 ;;
    *)  FILES+=("$1"); shift ;;
  esac
done

[ -n "$CONTROL" ] || { echo "probe: --control is REQUIRED — a probe with no positive control cannot tell 'clean' from 'blind'" >&2; exit 3; }
[ -n "$FIND" ]    || { echo "probe: --find is required" >&2; exit 3; }

# Slurp once: stdin and files both have to be counted twice (control + find), and a
# pipe can only be read once.
BUF="$(mktemp)"; trap 'rm -f "$BUF"' EXIT
if [ "${#FILES[@]}" -gt 0 ]; then cat -- "${FILES[@]}" > "$BUF" 2>/dev/null; else cat > "$BUF"; fi

# The haystack must not be empty either — an empty input satisfies "no findings" for
# every pattern ever written, which is the purest form of this bug.
if [ ! -s "$BUF" ]; then
  printf '  ✗ %s — BLIND: the input was EMPTY, so "no findings" means nothing.\n' "$LABEL" >&2
  exit 2
fi

c_hits=$(grep -cE -- "$CONTROL" "$BUF" 2>/dev/null || true)
c_hits=${c_hits:-0}
if [ "$c_hits" -eq 0 ]; then
  printf '  ✗ %s — BLIND: the positive control /%s/ matched NOTHING.\n' "$LABEL" "$CONTROL" >&2
  printf '     The probe is looking for something this input never contains, so a zero\n' >&2
  printf '     count from /%s/ is not evidence of anything. Fix the pattern, not the report.\n' "$FIND" >&2
  printf '     First lines actually seen:\n' >&2
  head -n 3 "$BUF" | sed 's/^/       | /' >&2
  exit 2
fi

f_hits=$(grep -cE -- "$FIND" "$BUF" 2>/dev/null || true)
f_hits=${f_hits:-0}
if [ "$f_hits" -eq 0 ]; then
  printf '  ✓ %s — clean (%s control match(es); the probe was demonstrably looking)\n' "$LABEL" "$c_hits"
  exit 0
fi
printf '  ✗ %s — %s finding(s):\n' "$LABEL" "$f_hits"
grep -nE -- "$FIND" "$BUF" | head -n 20 | sed 's/^/       /'
exit 1
