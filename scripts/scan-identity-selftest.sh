#!/usr/bin/env bash
# scan-identity-selftest.sh — prove the identity guard blocks what it must and, just as importantly,
# STAYS QUIET on everything else.
#
#   bash scripts/scan-identity-selftest.sh
#
# The failure mode this suite exists for is not "misses a leak" — it is "fires so often that someone
# disables it." A guard that flags inherited content gets bypassed with --no-verify within a week,
# which silently disables every OTHER pre-commit gate too. So the quiet cases below are load-bearing
# assertions, not padding, and each one is watched failing on the input it exists to catch.
#
# Fixtures are real throwaway git repos, because the guard reads a real staged diff and resolves the
# repo from the CALLER's toplevel — a fixture that shortcut either would test something else.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/scan-identity.sh"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "▶ scan-identity self-test (a guard nobody disables is the only guard that works)"
echo

# fixture: a repo with a denylist, one committed baseline.
# Terms are SYNTHETIC on purpose: seeding a suite with a real private name makes the guard block
# its own commit, and the next person reaches for --no-verify. Never use live test data here.
mk() {
  local d; d="$(mktemp -d)"
  git -C "$d" init -q .
  mkdir -p "$d/.kickoff"
  printf 'zzfakeorg\nzzotherco\n' > "$d/.kickoff/leak-denylist.txt"
  printf 'baseline line\n' > "$d/f.txt"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
  printf '%s' "$d"
}
# stage $2 as an appended line in $1/f.txt, then run the guard; echo its rc
run() { printf '%s\n' "$2" >> "$1/f.txt"; git -C "$1" add f.txt >/dev/null 2>&1; ( cd "$1" && bash "$S" --staged >/dev/null 2>&1 ); echo $?; }

# ── it BLOCKS what it must ───────────────────────────────────────────────────────────────────
d="$(mk)"; [ "$(run "$d" '# the zzfakeorg team said so')" = 1 ] && ok "blocks a newly-added denylisted name" || bad "did NOT block a new denylisted name"
d="$(mk)"; [ "$(run "$d" 'the ZzFakeOrg integration')"    = 1 ] && ok "★ blocks a CASE-VARIANT of the term (ZzFakeOrg) — variant-blindness is how a prior cut leaked" || bad "case variant slipped through"
# The two machine-path fixtures are ASSEMBLED AT RUNTIME rather than written literally. A detector's
# own suite would otherwise contain exactly what it detects, block its own commit, and teach the next
# person to reach for --no-verify. Building them from parts keeps the assertion real — the guard sees
# a fully-formed path — while leaving no literal match in this file. No exemption, so no hole.
HOMEISH="/${HOME_WORD:-home}/someuser/notes"
SCRATCHISH="/tmp/${CLAUDE_WORD:-claude}-1234/x"
d="$(mk)"; [ "$(run "$d" "see $HOMEISH")" = 1 ] && ok "blocks a newly-added machine path (structural — no denylist entry covers it)" || bad "machine path slipped through"
d="$(mk)"; [ "$(run "$d" "ref $SCRATCHISH")" = 1 ] && ok "blocks the scratchpad path form too" || bad "scratchpad path slipped through"
d="$(mk)"; [ "$(run "$d" 'ZZOTHERCO ships tuesday')"     = 1 ] && ok "blocks an all-caps variant of a second term" || bad "all-caps variant slipped through"

# ── it STAYS QUIET otherwise — the assertions that keep it installed ─────────────────────────
d="$(mk)"; [ "$(run "$d" 'a totally ordinary line')" = 0 ] && ok "quiet on an ordinary edit" || bad "fired on an ordinary edit"

# INHERITED content must never re-fire: the name is already committed, and an unrelated edit follows.
d="$(mktemp -d)"; git -C "$d" init -q .; mkdir -p "$d/.kickoff"
printf 'zzfakeorg\n' > "$d/.kickoff/leak-denylist.txt"
printf 'we have worked with zzfakeorg for years\n' > "$d/f.txt"
git -C "$d" add -A >/dev/null 2>&1; git -C "$d" -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
[ "$(run "$d" 'an unrelated new line')" = 0 ] \
  && ok "★ QUIET on INHERITED content — an unrelated edit beside an existing name does not fire" \
  || bad "fired on inherited content (this is how a guard gets disabled)"

# a REMOVED line mentioning the term must not fire either — you are deleting a leak, not adding one
d="$(mktemp -d)"; git -C "$d" init -q .; mkdir -p "$d/.kickoff"
printf 'zzfakeorg\n' > "$d/.kickoff/leak-denylist.txt"
printf 'zzfakeorg is mentioned here\nkeep me\n' > "$d/f.txt"
git -C "$d" add -A >/dev/null 2>&1; git -C "$d" -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
printf 'keep me\n' > "$d/f.txt"; git -C "$d" add f.txt >/dev/null 2>&1
( cd "$d" && bash "$S" --staged >/dev/null 2>&1 ) && ok "★ quiet when the change REMOVES the name (scrubbing must not be blocked)" || bad "blocked a scrub — removing a leak must always be allowed"

# ── NET-NEW, not merely present: editing near an existing name must stay quiet ────────────────
# This is the case that blocked the guard's own author on the commit that armed two new terms: a
# rewritten line that still carried a DIFFERENT, pre-existing denylisted name read as an addition.
# Names live in prose people keep revising, so this fires constantly if the rule is "appears on a +
# line" — and a guard that fires on ordinary editing is one that gets bypassed.
d="$(mktemp -d)"; git -C "$d" init -q .; mkdir -p "$d/.kickoff"
printf 'zzfakeorg\n' > "$d/.kickoff/leak-denylist.txt"
printf 'built with zzfakeorg tooling in 2024\nother\n' > "$d/f.txt"
git -C "$d" add -A >/dev/null 2>&1; git -C "$d" -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
sed -i 's/in 2024/in 2025/' "$d/f.txt"; git -C "$d" add f.txt >/dev/null 2>&1
( cd "$d" && bash "$S" --staged >/dev/null 2>&1 ) \
  && ok "★ QUIET when editing a line that ALREADY contains the name (net-new, not merely present)" \
  || bad "fired on an edit that added no new occurrence"
# ...and a genuine second occurrence must still block, or the rule above has disarmed the guard.
printf 'and zzfakeorg again\n' >> "$d/f.txt"; git -C "$d" add f.txt >/dev/null 2>&1
( cd "$d" && bash "$S" --staged >/dev/null 2>&1 ) \
  && bad "a NET-NEW occurrence slipped through — the net-new rule disarmed the guard" \
  || ok "★ …and a net-NEW occurrence in the same file still BLOCKS"

# ── the sanctioned escape, and its honesty ───────────────────────────────────────────────────
d="$(mk)"; printf '# the zzfakeorg case study\n' >> "$d/f.txt"; git -C "$d" add f.txt >/dev/null 2>&1
( cd "$d" && ALLOW_IDENTITY=1 bash "$S" --staged >/dev/null 2>&1 ) \
  && ok "ALLOW_IDENTITY=1 proceeds (a guard with no sanctioned bypass gets --no-verify'd, killing every other gate)" \
  || bad "escape hatch did not work"
( cd "$d" && ALLOW_IDENTITY=1 bash "$S" --staged 2>&1 | grep -q 'DELIBERATE' ) \
  && ok "…and it SAYS it is proceeding, rather than passing silently" || bad "escape hatch is silent"

# ── unconfigured is not 'clean' ──────────────────────────────────────────────────────────────
d="$(mktemp -d)"; git -C "$d" init -q .
printf 'x\n' > "$d/f.txt"; git -C "$d" add -A >/dev/null 2>&1
( cd "$d" && bash "$S" --staged >/dev/null 2>&1 ) \
  && ok "no denylist → passes (never block a fresh clone; the release gate fails CLOSED instead)" \
  || bad "blocked a repo with no denylist configured"

# ── NON-VACUITY: neuter the guard and the blocking assertions must collapse ──────────────────
TMPS="$(mktemp)"; sed 's/^exit 1$/exit 0/' "$S" > "$TMPS"
d="$(mk)"; printf '# the zzfakeorg team said so\n' >> "$d/f.txt"; git -C "$d" add f.txt >/dev/null 2>&1
( cd "$d" && bash "$TMPS" --staged >/dev/null 2>&1 ) \
  && ok "NON-VACUITY: with the guard's exit neutered, the block-case DOES pass (the ✅s above are load-bearing)" \
  || bad "non-vacuity control did not behave — the blocking assertions may be testing nothing"
rm -f "$TMPS"

echo
printf '  %s  %d passed, %d failed\n' "$( [ "$FAIL" -eq 0 ] && echo '✅' || echo '❌' )" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
