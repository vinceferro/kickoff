#!/usr/bin/env bash
# selftest.sh — prove the quality machinery actually works, in one command.
#
#   bash scripts/selftest.sh
#
# Exercises the scanners (against a planted dirty fixture + the repo itself) and
# the secret-provisioning crypto (round-trip, big-secret, tamper, injection).
# Prints PASS/FAIL per check; exits non-zero if anything fails. No deps beyond
# git + grep + coreutils + node (node only for the secret-provisioning checks).

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "▶ claude-kickoff self-test"
echo

# ── 1. scanners CATCH a planted dirty fixture ──────────────────────────────
echo "1. Scanners catch planted footguns + secrets"
T=$(mktemp -d); ( cd "$T" && git init -q && git config user.email t@t.t && git config user.name t )
mkdir -p "$T/src" "$T/db"
printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIfakekeymaterial\n-----END RSA PRIVATE KEY-----\n' > "$T/id_rsa.pem"
printf 'API_KEY=loadedhere\n' > "$T/.env"
printf 'aws = "AKIAIOSFODNN7EXAMPLE"\n' > "$T/aws.cfg"
printf 'DELETE FROM users;\nCREATE POLICY p ON t FOR SELECT USING (true);\n' > "$T/db/m.sql"
yes "// filler" | head -n 850 > "$T/src/huge.ts"
printf '{ "dependencies": { "react": "^19.0.0" } }\n' > "$T/package.json"
printf 'export const A = () => <div/>;\n' > "$T/src/App.tsx"
# a shell script with the suppressed-error-then-count footgun (advisory lane): a failing
# command whose error is discarded then counted reads as "0 found" — a silent false result.
printf 'n=$(grep foo bar 2>/dev/null | wc -l)\necho "$n"\n' > "$T/probe.sh"
( cd "$T" && git add -A )
SEC=$(cd "$T" && bash "$REPO/scripts/scan-secrets.sh" --warn-only 2>&1)
STR=$(cd "$T" && bash "$REPO/scripts/scan-structure.sh" 2>&1)
chk "private key detected"            "echo \"\$SEC\" | grep -q 'private key block'"
chk "committed .env detected"         "echo \"\$SEC\" | grep -q 'committed .env'"
chk "AWS key detected"                "echo \"\$SEC\" | grep -q 'AWS access key'"
chk "secret value is REDACTED"        "! echo \"\$SEC\" | grep -q 'AKIAIOSFODNN7EXAMPLE'"
chk "DELETE-without-WHERE detected"   "echo \"\$STR\" | grep -q 'DELETE without WHERE'"
chk "broad RLS/grant detected"        "echo \"\$STR\" | grep -q 'broad RLS'"
chk "oversized file detected"         "echo \"\$STR\" | grep -q 'oversized file'"
chk "missing ErrorBoundary detected"  "echo \"\$STR\" | grep -q 'ErrorBoundary'"
chk "suppressed-error-then-count detected" "echo \"\$STR\" | grep -q 'suppressed-error-then-count'"
chk "secret scan exits non-zero on a finding" "! (cd \"$T\" && bash \"$REPO/scripts/scan-secrets.sh\" >/dev/null 2>&1)"
rm -rf "$T"
echo

# ── 2. scanners are CLEAN on the kickoff repo itself ───────────────────────
echo "2. Scanners are clean on this repo"
chk "secret scan clean"     "cd \"$REPO\" && bash scripts/scan-secrets.sh"
# Structural findings are ADVISORY (lefthook.yml + scan-structure.sh both: "does not
# block") — the repo's own demo/experiment files legitimately raise some. Assert the
# scan RUNS, exits cleanly (advisory, non-blocking), and emits its report — NOT that it
# reports zero findings (that would contradict the advisory contract).
chk "structure scan runs clean (advisory; findings don't block)" "OUT=\$(cd \"$REPO\" && bash scripts/scan-structure.sh) && printf '%s' \"\$OUT\" | grep -qE 'scan-structure: (no structural footguns|[0-9]+ finding)'"
echo

# ── 3. secret-provisioning crypto round-trips ──────────────────────────────
echo "3. Secret provisioning (E2E crypto)"
if command -v node >/dev/null 2>&1; then
  KD=$(mktemp -d)
  node "$REPO/scripts/secret-box-keygen.mjs" "$KD" >/dev/null 2>&1
  chk "keypair generated (private 0600)" "[ \"\$(stat -c '%a' \"$KD/private.pem\" 2>/dev/null || stat -f '%Lp' \"$KD/private.pem\")\" = 600 ]"
  S="sk_test_roundtrip_value_123456"
  R=$(node "$REPO/scripts/secret-encrypt.mjs" "$KD/public.pem" "$S" | node "$REPO/scripts/secret-decrypt.mjs" --priv "$KD/private.pem" 2>/dev/null)
  chk "secret round-trips"        "[ \"$R\" = \"$S\" ]"
  BIG="eyJ$(head -c 400 /dev/urandom | base64 | tr -d '\n=+/')"
  R2=$(node "$REPO/scripts/secret-encrypt.mjs" "$KD/public.pem" "$BIG" | node "$REPO/scripts/secret-decrypt.mjs" --priv "$KD/private.pem" 2>/dev/null)
  chk "JWT-sized secret round-trips (hybrid)" "[ \"$R2\" = \"$BIG\" ]"
  P=$(node "$REPO/scripts/secret-encrypt.mjs" "$KD/public.pem" "$S")
  # Tamper by DELETING the first ciphertext char — always corrupts. (Do NOT "replace with a fixed
  # char X": the base64 first char already equals X ~1/64 of runs, making the tamper a no-op → the
  # payload still decrypts → this check false-fails. That was a real ~2% flake; deletion can't no-op.)
  echo "$P" | sed 's/"ciphertext":"./"ciphertext":"/' > "$KD/bad.json"
  chk "tampered payload is rejected" "! node \"$REPO/scripts/secret-decrypt.mjs\" --priv \"$KD/private.pem\" \"$KD/bad.json\" >/dev/null 2>&1"
  node "$REPO/scripts/secret-encrypt.mjs" "$KD/public.pem" "$(printf 'v\nEVIL=1')" | node "$REPO/scripts/secret-decrypt.mjs" --priv "$KD/private.pem" --write-env "$KD/x.env" --key K >/dev/null 2>&1
  chk "newline injection into .env refused" "! grep -q EVIL \"$KD/x.env\" 2>/dev/null"
  # POSITIVE CONTROL for --write-env (the happy path the negative check above cannot prove — it passes
  # identically whether the write SUCCEEDS or the process CRASHES before writing). A dropped `join`
  # import shipped exactly this way: --write-env threw ReferenceError, x.env was never written, and the
  # "refused" assertion above went green on the crash. This cell fails on that crash: it asserts the
  # value actually LANDS. Mirrors the command the mission-control skill documents (--allow + --key).
  node "$REPO/scripts/secret-encrypt.mjs" "$KD/public.pem" "sk_pos_control_9f3a" | node "$REPO/scripts/secret-decrypt.mjs" --priv "$KD/private.pem" --write-env "$KD/w.env" --key POSK --allow POSK >/dev/null 2>&1
  chk "--write-env upserts the value (positive control)" "grep -q '^POSK=sk_pos_control_9f3a\$' \"$KD/w.env\" 2>/dev/null"
  rm -rf "$KD"
else
  echo "  ⚠ node not found — skipping the secret-provisioning checks"
fi
echo

# ── 4. gate config present ─────────────────────────────────────────────────
echo "4. Gate config"
chk "lefthook.yml present"  "[ -f \"$REPO/lefthook.yml\" ]"
chk "lefthook has secret-scan + structure-scan" "grep -q scan-secrets \"$REPO/lefthook.yml\" && grep -q scan-structure \"$REPO/lefthook.yml\""
echo

# ── 5. Mission Control ─────────────────────────────────────────────────────
echo "5. Mission Control"
chk "server + update CLI present"  "[ -f \"$REPO/mission-control/server.py\" ] && [ -f \"$REPO/mission-control/mc-update.py\" ]"
chk "server binds 127.0.0.1 (not 0.0.0.0)" "grep -q 'HOST = \"127.0.0.1\"' \"$REPO/mission-control/server.py\" && ! grep -q '\"0.0.0.0\"' \"$REPO/mission-control/server.py\""
if command -v python3 >/dev/null 2>&1; then
  chk "python syntax ok" "python3 -c \"import ast; ast.parse(open('$REPO/mission-control/server.py').read()); ast.parse(open('$REPO/mission-control/mc-update.py').read())\""
  MT=$(mktemp -d); cp "$REPO/mission-control/mc-update.py" "$REPO/mission-control/mission-state.json" "$MT/"
  python3 "$MT/mc-update.py" --file "$MT/mission-state.json" set headline "selftest" >/dev/null 2>&1
  python3 "$MT/mc-update.py" --file "$MT/mission-state.json" plate "tap me" >/dev/null 2>&1
  chk "mc-update set/plate round-trips" "python3 \"$MT/mc-update.py\" --file \"$MT/mission-state.json\" show | grep -q '\"headline\": \"selftest\"'"
  # Seed an EMPTY activity baseline so the concurrency assert is deterministic even on a dirty
  # working tree: a clean clone's mission-state.json has 0 feed entries, but a live board can carry
  # up to ACTIVITY_CAP. The guarantee under test — "8 concurrent writes lose nothing" — only reads
  # cleanly from a known 0 baseline (8 writes → exactly 8 entries).
  python3 -c "import json; p='$MT/mission-state.json'; d=json.load(open(p)); d['activity']=[]; json.dump(d, open(p,'w'))"
  for i in 1 2 3 4 5 6 7 8; do python3 "$MT/mc-update.py" --file "$MT/mission-state.json" log "s$i" "m$i" >/dev/null 2>&1 & done; wait
  chk "concurrent multi-source writes lose nothing (8 writes, empty baseline)" "[ \"\$(python3 -c \"import json;print(len(json.load(open('$MT/mission-state.json'))['activity']))\")\" = 8 ]"
  python3 "$MT/mc-update.py" --file "$MT/mission-state.json" render-tracker --out "$MT/T.md" >/dev/null 2>&1
  chk "render-tracker renders state → TRACKER.md (one store, two views)" "grep -q 'rendered from mission-control/mission-state.json' \"$MT/T.md\" && grep -q 'selftest' \"$MT/T.md\""
  cp "$REPO/mission-control/simulate.py" "$MT/"
  python3 "$MT/simulate.py" --file "$MT/mission-state.json" --speed 0.05 --reset >/dev/null 2>&1
  chk "org simulation lights up the board (multi-source feed)" "[ \"\$(python3 -c \"import json;print(len(json.load(open('$MT/mission-state.json'))['functions']))\")\" = 5 ]"
  rm -rf "$MT"
else
  echo "  ⚠ python3 not found — skipping MC checks"
fi
echo

# ── 6. §5 THE PLUGIN — the engine packaged as a Claude Code plugin (slices 1–8) ──────
# Delegate to plugin-selftest.sh (hermetic: a STUB `claude` + an ISOLATED CLAUDE_CONFIG_DIR,
# so the live ~/.claude/plugins/ is NEVER touched). It is the gate that proves adopt enables
# the plugin, pull re-syncs its cache, preflight #8 hashes it, and eject reverses it.
echo "6. §5 THE PLUGIN (plugin-selftest.sh — hermetic, isolated)"
if command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  if bash "$REPO/scripts/plugin-selftest.sh" >/dev/null 2>&1; then
    ok "plugin-selftest.sh passes (slices 1–8: package · adopt · pull-cache · preflight #8 · eject)"
  else
    bad "plugin-selftest.sh FAILED — run \`bash scripts/plugin-selftest.sh\` for the detail"
  fi
else
  echo "  ⚠ git/jq/python3 not all present — skipping the plugin self-test"
fi
echo

echo "──────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "  ✅ machinery works"; exit 0; } || { echo "  ❌ see failures above"; exit 1; }
