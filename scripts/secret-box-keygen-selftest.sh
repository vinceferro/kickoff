#!/usr/bin/env bash
# secret-box-keygen-selftest.sh — the keypair provisioner is now called AUTOMATICALLY, so the
# properties an automatic caller depends on have to be asserted, not assumed.
#
#   bash scripts/secret-box-keygen-selftest.sh   # exits non-zero on ANY failed assertion
#
# WHY THIS EXISTS. core-v0.17 wires `--ensure` into `kickoff adopt` and the Mission Control
# server so an adopter never types a command to get a secrets channel. That turns three
# latent properties of a hand-run script into load-bearing ones:
#
#   1. IDEMPOTENCE — the old script `process.exit(1)`d whenever the key existed, so an
#      ensure-on-every-boot caller would have failed on every boot but the first.
#   2. RACE SAFETY — it was a plain TOCTOU (exists() → writeFile) with three separate
#      writes. Two boards starting together could leave private.pem from one process and
#      public.pem+fingerprint from another. That fails GREEN: the panel's fingerprint check
#      passes while every secret is encrypted to a key nobody holds. A one-way door.
#   3. HONEST REFUSAL — a torn or tampered keydir must never be silently "repaired",
#      because repairing means deleting a private key, i.e. every provisioned secret.
#
# Every assertion below is verified RED against the pre-core-v0.17 script (git show), so a
# green run here means the properties hold, not that the test is agreeable.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GEN="${KEYGEN_UNDER_TEST:-$HERE/secret-box-keygen.mjs}"
pass=0; fail=0
t() { if [ "$2" = "$3" ]; then printf '  \342\234\223 %s\n' "$1"; pass=$((pass+1));
      else printf '  \342\234\227 %s — got [%s] want [%s]\n' "$1" "$2" "$3"; fail=$((fail+1)); fi }

command -v node >/dev/null 2>&1 || { echo "  (skip) node not present — provisioning is node-conditional by design"; exit 0; }
[ -f "$GEN" ] || { echo "FATAL: $GEN not found" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
run() { node "$GEN" --keydir "$1" --quiet "${@:2}" >/dev/null 2>&1; echo $?; }

echo "— create, then be IDEMPOTENT under --ensure (the automatic caller's contract) —"
K="$TMP/a"
t "fresh create → rc 0"                "$(run "$K")"           "0"
t "private.pem is 0600"                "$(stat -c '%a' "$K/private.pem" 2>/dev/null)" "600"
t "--ensure on a provisioned keydir → rc 0" "$(run "$K" --ensure)" "0"
t "--ensure again → still rc 0 (every boot, not just the first)" "$(run "$K" --ensure)" "0"

echo "— rotation stays DELIBERATE: a bare re-run must still refuse —"
t "bare re-run over an existing key → rc 1" "$(run "$K")"       "1"
t "…and the private key is untouched"  "$(stat -c '%s' "$K/private.pem" 2>/dev/null | awk '{print ($1>1000)?"big":"small"}')" "big"

echo "— refuse an INCONSISTENT keydir; never auto-repair (deleting a key deletes secrets) —"
TORN="$TMP/torn"; mkdir -p "$TORN"; echo fake > "$TORN/private.pem"
t "torn keydir (private only) → rc 3"  "$(run "$TORN" --ensure)" "3"
t "…and it was NOT overwritten"        "$(cat "$TORN/private.pem")" "fake"
MIS="$TMP/mis"; run "$MIS" >/dev/null; printf 'SHA256:bogus\nde:ad\n' > "$MIS/public.fingerprint"
t "fingerprint not matching public.pem → rc 3" "$(run "$MIS" --ensure)" "3"

echo "— the recorded fingerprint MUST match the served public key —"
FP="$(head -1 "$K/public.fingerprint")"
CALC="SHA256:$(openssl pkey -pubin -in "$K/public.pem" -outform DER 2>/dev/null | openssl dgst -sha256 -binary | base64 | tr -d '=' )"
if command -v openssl >/dev/null 2>&1 && [ -n "$CALC" ] && [ "$CALC" != "SHA256:" ]; then
  t "public.fingerprint == SHA-256(SPKI DER) computed independently by openssl" "$FP" "$CALC"
else
  echo "  (skip) openssl unavailable — independent fingerprint cross-check not run"
fi

echo "— CONCURRENCY: N racers, one keypair, never a torn pair —"
# The property that fails GREEN if broken, so assert it directly rather than trusting the design.
C="$TMP/race"
for _ in 1 2 3 4 5 6 7 8; do node "$GEN" --keydir "$C" --ensure --quiet >/dev/null 2>&1 & done
wait
t "exactly ONE private.pem"            "$(ls "$C"/private.pem 2>/dev/null | wc -l | tr -d ' ')" "1"
t "exactly ONE public.pem"             "$(ls "$C"/public.pem  2>/dev/null | wc -l | tr -d ' ')" "1"
t "no stray temp files left behind"    "$(ls "$C"/*.tmp.* 2>/dev/null | wc -l | tr -d ' ')"     "0"
t "the surviving pair is CONSISTENT"   "$(run "$C" --ensure)" "0"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && printf '  \342\234\205 keypair provisioning is idempotent, race-safe, and honestly fail-closed\n'
[ "$fail" -eq 0 ]
