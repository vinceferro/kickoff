#!/usr/bin/env bash
# remote-normalize-selftest.sh — guard the core-clone origin check's URL normalization.
#
# THE BUG (2026-07-20): `kickoff pull` refused a real adopter (bliz) because the shared
# core clone's origin was `https://github.com/…` while KICKOFF_CORE_REMOTE resolved to
# `git@github.com:…` — the SAME repo over a different transport. The guard compared the
# two URLs LITERALLY, so a fleet whose adopters disagree on ssh-vs-https could never all
# satisfy it (aligning the clone for one adopter breaks another).
#
# THE FIX: `_normalize_git_remote` reduces any transport of one repo to `host/path`, and
# the guard compares NORMALIZED forms. This selftest proves, on the ACTUAL shipped
# function (extracted from scripts/kickoff — never a re-implementation):
#   • RED control: the raw https and ssh URLs are literally UNEQUAL (the pre-fix compare).
#   • GREEN: their normalized forms are EQUAL (the same-repo/different-transport case).
#   • NEGATIVE controls: a different repo NAME or a different HOST stays UNEQUAL, so the
#     guard is not defeated — it still fails-closed on a genuinely wrong clone.
#
#   bash scripts/remote-normalize-selftest.sh   # exits non-zero on ANY failed assertion
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KICKOFF="$HERE/kickoff"
[ -f "$KICKOFF" ] || { echo "FATAL: $KICKOFF not found" >&2; exit 2; }

# Load the ACTUAL function from the shipped script (the exact text that runs in a pull).
_fn="$(sed -n '/^_normalize_git_remote() {/,/^}/p' "$KICKOFF")"
[ -n "$_fn" ] || { echo "FATAL: _normalize_git_remote not found in $KICKOFF (renamed?)" >&2; exit 2; }
eval "$_fn"

pass=0; fail=0
t() { # $1=desc  $2=got  $3=expected
  if [ "$2" = "$3" ]; then printf '  \342\234\223 %s\n' "$1"; pass=$((pass+1));
  else printf '  \342\234\227 %s — got [%s] want [%s]\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}
norm() { _normalize_git_remote "$1"; }
eq()   { [ "$(norm "$1")" = "$(norm "$2")" ] && echo EQUAL || echo DIFF; }

SSH='git@github.com:vinceferro/kickoff.git'
HTTPS='https://github.com/vinceferro/kickoff.git'
SSHURL='ssh://git@github.com/vinceferro/kickoff.git'
NOGIT='https://github.com/vinceferro/kickoff'
OTHER='git@github.com:vinceferro/other-repo.git'
OWNER='git@github.com:someoneelse/claude-kickoff.git'
HOST='https://gitlab.com/vinceferro/kickoff.git'
CANON='github.com/vinceferro/kickoff'

echo "— RED control: the pre-fix LITERAL compare would reject the same repo —"
t "raw https != raw ssh (the bug the fix removes)" "$([ "$HTTPS" != "$SSH" ] && echo UNEQUAL || echo EQUAL)" "UNEQUAL"

echo "— GREEN: every transport of the SAME repo normalizes to one string —"
t "ssh scp-like"     "$(norm "$SSH")"    "$CANON"
t "https"            "$(norm "$HTTPS")"  "$CANON"
t "ssh:// full"      "$(norm "$SSHURL")" "$CANON"
t "https no .git"    "$(norm "$NOGIT")"  "$CANON"
t "https == ssh"     "$(eq "$HTTPS" "$SSH")"    "EQUAL"
t "https == ssh://"  "$(eq "$HTTPS" "$SSHURL")" "EQUAL"

echo "— NEGATIVE controls: a genuinely different clone still fails-closed —"
t "different repo name → DIFF"  "$(eq "$OTHER" "$SSH")"  "DIFF"
t "different owner → DIFF"       "$(eq "$OWNER" "$SSH")"  "DIFF"
t "different host → DIFF"        "$(eq "$HOST"  "$HTTPS")" "DIFF"

# ── HOSTILE controls: the normalizer must never make a DIFFERENT host look canonical ──────────────
# Found by an adversarial pass on core-v0.16. The userinfo strip was `${u#*@}` — UNANCHORED, so it
# deleted everything up to the FIRST '@' ANYWHERE in the URL, host included. Any attacker-controlled
# host with an '@' later in the path therefore normalized to the canonical core and the guard ACCEPTED
# a clone of a completely different repo. Loosening a fail-closed guard is the one direction that must
# never regress, so these assertions are the point of this file, not an extra.
# ── FALSE-REJECT controls: a VALID url for the same repo must not be refused ──────────────────────
# Found by the Bliz coordinator reviewing core-v0.16 from the adopter side, by running the shipped
# function rather than reading it. All three fail CLOSED (the safe direction) — but each produces a
# "core clone origin MISMATCH" for a URL that is perfectly legal, and the message blames your config
# rather than the spelling, so the diagnosis cost is high. `repo.git/` is the one that bites for real:
# git accepts it and tooling emits it.
echo "— FALSE-REJECT controls: legal spellings of the SAME repo must normalize equal —"
t "trailing slash after .git (repo.git/)" "$(eq 'https://github.com/vinceferro/kickoff.git/' "$HTTPS")" "EQUAL"
t "uppercase scheme (HTTPS://)"           "$(eq 'HTTPS://github.com/vinceferro/kickoff' "$HTTPS")"        "EQUAL"
t "uppercase host (RFC: case-insensitive)" "$(eq 'https://GITHUB.COM/vinceferro/kickoff' "$HTTPS")"       "EQUAL"
t "bare trailing slash still fine"        "$(eq 'https://github.com/vinceferro/kickoff/' "$HTTPS")"       "EQUAL"
# The PATH stays case-SENSITIVE: only the host is case-insensitive per RFC, and forges differ on
# whether org/repo are. Lowercasing the whole URL would make two genuinely different repos compare
# equal — a false-accept, the direction that must never regress.
t "path case is PRESERVED (not a false-accept)" "$(eq 'https://github.com/vinceferro/Claude-Kickoff' "$HTTPS")"  "DIFF"

echo "— HOSTILE controls: an '@' in the PATH must not launder a foreign host —"
t "evil host, canonical tail after @"      "$(eq 'https://evil.com/a@github.com/vinceferro/kickoff' "$HTTPS")" "DIFF"
t "evil host, bare @ before canonical"     "$(eq 'https://evil.com/@github.com/vinceferro/kickoff' "$HTTPS")" "DIFF"
t "evil host over ssh://"                  "$(eq 'ssh://evil.com/x@github.com/vinceferro/kickoff' "$HTTPS")" "DIFF"
t "evil host, scp-like with @ in path"     "$(eq 'evil.com:mirror@github.com/vinceferro/kickoff' "$HTTPS")" "DIFF"
t "canonical host, @ inside the repo path" "$(norm 'https://github.com/vinceferro/kickoff/a@b')" "github.com/vinceferro/kickoff/a@b"

echo
if [ "$fail" -eq 0 ]; then echo "PASS: $pass/$((pass+fail)) assertions green"; exit 0
else echo "FAIL: $fail of $((pass+fail)) assertions RED"; exit 1; fi
