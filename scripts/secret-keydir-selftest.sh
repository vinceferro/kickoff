#!/usr/bin/env bash
# secret-keydir-selftest.sh — the secrets channel comes up BY ITSELF on a fresh adopter, with the
# keypair in THIS project's instance dir, and every consumer resolves that SAME keydir.
#
#   bash scripts/secret-keydir-selftest.sh
#   SECRET_CORE_UNDER_TEST=<repo-shaped dir> bash scripts/secret-keydir-selftest.sh   # RED-proof a pre-fix tree
#
# WHY THIS EXISTS (core-v0.17). Two bugs, one suite:
#
#   1. NOTHING ever created the keypair. The board served /pubkey, the panel encrypted against it,
#      and the only instruction anywhere was "run secret-box-keygen.mjs on the box" — a terminal
#      command the phone-only operator this channel exists FOR cannot run. The channel was dead on
#      every adopter and looked merely un-set-up.
#   2. The keydir was ~/.kickoff/secret-box — MACHINE-level. Every project on the box would share
#      one keypair, one write allow-list and one pinned destination .env, on the one channel that
#      carries credentials. Same sharing bug as .mission-token and secrets-inbox/ (server.py:149),
#      one blast radius worse.
#
# WHY IT IS SHAPED LIKE THIS. The first draft of this test would have PASSED with the fix deleted:
# both halves resolved the keydir under $HOME, this box is already hand-provisioned, so a fixture
# inheriting the real $HOME serves a months-old key and reports GREEN while the adopter's channel is
# dead. "A fixture matching your own box goes green while the bug is live." So: every process here
# runs under `env -i` with HOME pointed at an EMPTY fixture dir, and the suite asserts positively
# that the real ~/.kickoff/secret-box is neither read nor written.
#
# RED-FIRST. Every assertion below was verified RED against the pre-fix tree (server.py +
# secret-box-keygen.mjs + secret-decrypt.mjs from `git show HEAD:` assembled into a dir and passed
# as SECRET_CORE_UNDER_TEST). Each assertion carries a comment naming the pre-fix behaviour it
# catches. It tests the REAL artifacts — the real server.py, the real .mjs scripts, a real git
# repo answering `git check-ignore` — never a replica, so it asserts on what the system consumes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${SECRET_CORE_UNDER_TEST:-$HERE/..}"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }

command -v python3 >/dev/null 2>&1 || { printf '  ❌ python3 not found\n'; exit 1; }
command -v git     >/dev/null 2>&1 || { printf '  ❌ git not found\n'; exit 1; }
# node is ADVISORY in kickoff (a node-less box is supported and loses only the secrets channel), so
# a node-less runner can't assert provisioning happened — but it must still not report a false green.
command -v node >/dev/null 2>&1 || { echo "  (skip) node not present — the whole channel is node-conditional by design"; exit 0; }
PY3="$(command -v python3)"
for f in mission-control/server.py mission-control/dashboard.html scripts/secret-keydir.mjs \
         scripts/secret-box-keygen.mjs scripts/secret-decrypt.mjs scripts/secret-encrypt.mjs; do
  [ -f "$SRC/$f" ] || { printf '  ❌ %s not found under %s\n' "$f" "$SRC"; exit 1; }
done

echo "▶ secret-keydir self-test (the channel self-provisions · per-project keydir · one keydir everywhere)"
echo

TMP="$(mktemp -d)"
PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

# The REAL machine-level keydir. It must come out of this run byte-identical: the whole point of the
# fix is that a project no longer touches it. Snapshot size+mtime+ctime of every file in it.
REAL_LEGACY="$HOME/.kickoff/secret-box"
snap_real() { [ -d "$REAL_LEGACY" ] && find "$REAL_LEGACY" -mindepth 1 -exec stat -c '%n %s %Y %Z %a' {} \; 2>/dev/null | sort || echo ABSENT; }
REAL_BEFORE="$(snap_real)"

# An EMPTY $HOME. Every child below runs under it, so any code path that still reaches for
# ~/.kickoff/secret-box lands here — visibly — instead of silently succeeding off this box's own key.
FHOME="$TMP/home"; mkdir -p "$FHOME"

# A fake SHARED PINNED CORE: server.py's dir is BASE_DIR, and the keygen it shells out to is derived
# from it (server.py:307). A pinned core clone looks exactly like this — the engine here, the keydir
# in the instance — so this shape is what proves KEYGEN_PATH still resolves for an adopter.
CORE="$TMP/kickoff-versions/core-vX"
mkdir -p "$CORE/mission-control" "$CORE/scripts"
cp "$SRC/mission-control/server.py" "$SRC/mission-control/dashboard.html" "$CORE/mission-control/"
[ -f "$SRC/mission-control/secrets.html" ] && cp "$SRC/mission-control/secrets.html" "$CORE/mission-control/"
# secret-keydir.mjs is a HARD import dependency of the two consumers (the shared keydir rule),
# not an optional extra — omit it and every .mjs call here dies on an unresolved ESM specifier and
# this suite reports 13 failures that are all one missing file. It is in scripts/core-manifest.txt
# for exactly the same reason, on the adopter's side of the same seam.
cp "$SRC/scripts/secret-keydir.mjs" "$SRC/scripts/secret-box-keygen.mjs" \
   "$SRC/scripts/secret-decrypt.mjs" "$SRC/scripts/secret-encrypt.mjs" "$CORE/scripts/"
SRV="$CORE/mission-control/server.py"
GEN="$CORE/scripts/secret-box-keygen.mjs"
DEC="$CORE/scripts/secret-decrypt.mjs"
ENC="$CORE/scripts/secret-encrypt.mjs"

# instance <name> — an adopter-shaped repo: a REAL git repo with the generated .kickoff/.gitignore
# and its own .kickoff/state/mission-control/mission-state.json. Echoes the state path.
instance() {
  local d="$TMP/$1"
  mkdir -p "$d/.kickoff/state/mission-control"
  git init -q "$d" >/dev/null 2>&1
  if [ -f "$SRC/scripts/templates/kickoff.gitignore" ]; then
    cp "$SRC/scripts/templates/kickoff.gitignore" "$d/.kickoff/.gitignore"
  else
    printf 'instance.env\nstate/\n' > "$d/.kickoff/.gitignore"
  fi
  printf '{"headline":"x","in_progress":[],"functions":{},"blocked":[],"done":[],"activity":[]}' \
    > "$d/.kickoff/state/mission-control/mission-state.json"
  printf '%s\n' "$d/.kickoff/state/mission-control/mission-state.json"
}

# start_server <state-path> [PATH-for-the-server] — launch the REAL server.py the way the shipped
# launch does (`python3 server.py <port>`, MC_STATE_FILE set, KICKOFF_STATE unset — the adopter's
# stock launch), under the empty $HOME. Sets PORT + TOKEN + SRVLOG; returns 1 if it never came up.
start_server() {
  local state="$1" spath="${2:-$PATH}"
  PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
  SRVLOG="$TMP/server.$PORT.log"
  env -i PATH="$spath" HOME="$FHOME" MC_STATE_FILE="$state" "$PY3" "$SRV" "$PORT" >"$SRVLOG" 2>&1 &
  PIDS="$PIDS $!"
  local i
  for i in $(seq 1 60); do
    [ "$(http "$PORT" /healthz "" | head -1)" = "200" ] && break
    sleep 0.2
  done
  TOKEN="$(cat "$(dirname "$state")/.mission-token" 2>/dev/null)"
  [ -n "$TOKEN" ]
}

# http <port> <path> <token> — real HTTP over the loopback socket (python3, so the suite needs no
# curl). Prints the status on line 1, the body from line 2 on.
http() {
  env -i PATH="$PATH" python3 - "$1" "$2" "$3" <<'PY'
import sys, urllib.request, urllib.error
url = "http://127.0.0.1:%s%s" % (sys.argv[1], sys.argv[2])
req = urllib.request.Request(url, headers={"Authorization": "Bearer " + sys.argv[3]})
try:
    r = urllib.request.urlopen(req, timeout=5); code, body = r.getcode(), r.read()
except urllib.error.HTTPError as e:
    code, body = e.code, e.read()
except Exception as e:
    code, body = 0, str(e).encode()
sys.stdout.write("%d\n" % code); sys.stdout.write(body.decode("utf-8", "replace"))
PY
}
status() { printf '%s\n' "$1" | head -1; }
body()   { printf '%s\n' "$1" | tail -n +2; }

# ── 1. NO MANUAL STEP: a fresh adopter instance reaches a usable /pubkey ─────────────────────────
# RED pre-fix: nothing ever ran the keygen, so /pubkey is 404 forever — the dead channel itself.
STATE_A="$(instance adopter-a)"
INST_A="$(dirname "$STATE_A")"
KEYDIR_A="$INST_A/secret-box"
if start_server "$STATE_A"; then
  R="$(http "$PORT" /pubkey "$TOKEN")"
  if [ "$(status "$R")" = "200" ] && printf '%s' "$(body "$R")" | grep -q 'BEGIN PUBLIC KEY'; then
    ok "fresh adopter: GET /pubkey serves a public key with NO manual step"
  else
    bad "fresh adopter: /pubkey → $(status "$R") $(body "$R" | head -2 | tr '\n' ' ') (expected 200 + a PEM)"
  fi
else
  bad "the board never came up on the adopter fixture — see $SRVLOG"
  PORT=0; TOKEN=""
fi

# ── 2. WHERE the key landed: the instance, never $HOME ───────────────────────────────────────────
# RED pre-fix: PUBKEY_PATH was ~/.kickoff/secret-box/public.pem, so with a real $HOME this served a
# months-old machine key (fail-GREEN) and with an isolated one served nothing. Either way the
# instance keydir does not exist.
if [ -f "$KEYDIR_A/private.pem" ] && [ -f "$KEYDIR_A/public.pem" ]; then
  ok "the keydir is the INSTANCE's: dirname(state)/secret-box"
else
  bad "no keypair at $KEYDIR_A — the keydir did not follow the instance"
fi
t="$(stat -c '%a' "$KEYDIR_A/private.pem" 2>/dev/null)"
[ "$t" = "600" ] && ok "private.pem is 0600" || bad "private.pem mode is [$t], want [600]"
# The empty $HOME is the negative control: anything still reaching for ~/.kickoff lands HERE.
n="$(find "$FHOME" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
[ "$n" = "0" ] && ok "nothing was written under \$HOME (the machine-level keydir is not used at all)" \
                || bad "$n entries appeared under the fixture \$HOME — something still anchors to ~/.kickoff"

# ── 3. the SERVED key is the one on disk — cross-checked by openssl, not by the writer ───────────
# RED pre-fix: no key is served at all, so there is nothing to match. Post-fix this catches the
# subtler regression: a board serving a public.pem from a keydir other than the one it recorded.
if command -v openssl >/dev/null 2>&1 && [ "${PORT:-0}" != "0" ]; then
  printf '%s' "$(body "$(http "$PORT" /pubkey "$TOKEN")")" > "$TMP/served.pem"
  CALC="SHA256:$(openssl pkey -pubin -in "$TMP/served.pem" -outform DER 2>/dev/null | openssl dgst -sha256 -binary | base64 | tr -d '=')"
  RECORDED="$(head -1 "$KEYDIR_A/public.fingerprint" 2>/dev/null)"
  if [ -n "$RECORDED" ] && [ "$CALC" = "$RECORDED" ]; then
    ok "the key served by /pubkey == <keydir>/public.fingerprint (digest computed by openssl)"
  else
    bad "served key does not match the recorded fingerprint — served [$CALC] recorded [$RECORDED]"
  fi
else
  echo "  (skip) openssl unavailable — independent fingerprint cross-check not run"
fi

# ── 4. THE FAIL-GREEN GUARD: keygen and secret-decrypt resolve the SAME keydir ───────────────────
# Asserted end-to-end rather than by comparing two strings: encrypt with the key the BOARD SERVED,
# decrypt with no key flags at all under the same env. If the two halves ever diverge, the panel
# encrypts to a key the coordinator cannot read and every check in between still passes.
# RED pre-fix: secret-decrypt.mjs had no keydir resolution — it read ~/.kickoff/secret-box/private.pem,
# which under the isolated $HOME does not exist → "private key not found".
if [ -s "$TMP/served.pem" ]; then
  PLAIN="k1ckoff-e2e-plaintext"
  env -i PATH="$PATH" HOME="$FHOME" node "$ENC" "$TMP/served.pem" "$PLAIN" --name TEST_KEY > "$TMP/payload.json" 2>/dev/null
  GOT="$(env -i PATH="$PATH" HOME="$FHOME" MC_STATE_FILE="$STATE_A" node "$DEC" "$TMP/payload.json" --keep 2>/dev/null)"
  [ "$GOT" = "$PLAIN" ] && ok "E2E: encrypt with the SERVED key → decrypt with the DERIVED private key (same keydir)" \
                        || bad "E2E round-trip failed — got [$GOT] want [$PLAIN]; the two halves resolved different keydirs"
  # Negative control — the same payload against a DIFFERENT instance's derived keydir MUST fail.
  # Without this the assertion above could be passing on a keydir shared by everything. Guarded on a
  # NON-EMPTY payload: "decryption failed" on a missing file would pass this vacuously.
  STATE_N="$(instance decoy-instance)"
  env -i PATH="$PATH" HOME="$FHOME" node "$GEN" --ensure --quiet --keydir "$(dirname "$STATE_N")/secret-box" >/dev/null 2>&1
  if [ ! -s "$TMP/payload.json" ]; then
    bad "no ciphertext was produced — the per-project negative control could not be run"
  elif env -i PATH="$PATH" HOME="$FHOME" MC_STATE_FILE="$STATE_N" node "$DEC" "$TMP/payload.json" --keep >/dev/null 2>&1; then
    bad "negative control FAILED: another project's keydir decrypted this project's payload"
  else
    ok "negative control: a different project's keydir CANNOT decrypt it (the keys are per-project)"
  fi
else
  bad "no served public key to round-trip — skipping the E2E keydir-agreement assertion (counts as failed)"
fi

# ── 5. the private key is UNCOMMITTABLE — asserted on git's answer, not on a file's contents ─────
# 5a. the adopter shape: the generated .kickoff/.gitignore `state/` rule already covers it.
if git -C "$TMP/adopter-a" check-ignore -q .kickoff/state/mission-control/secret-box/private.pem; then
  ok "adopter repo: git ignores the instance keydir's private.pem"
else
  bad "adopter repo: git does NOT ignore .kickoff/state/mission-control/secret-box/private.pem"
fi
# 5b. the belt, and the ORIGIN's only cover: a keydir inside a TRACKED directory (in the origin
# STATE_PATH falls back to BASE_DIR, so the keydir is mission-control/secret-box). Nothing above it
# ignores anything here — only the keydir's OWN .gitignore can save it.
# RED pre-fix: the keygen wrote no .gitignore, so check-ignore exits 1 and the private key was one
# `git add -A` from being published.
TRK="$TMP/tracked-repo"; mkdir -p "$TRK/mission-control"; git init -q "$TRK" >/dev/null 2>&1
env -i PATH="$PATH" HOME="$FHOME" node "$GEN" --ensure --quiet --keydir "$TRK/mission-control/secret-box" >/dev/null 2>&1
[ -f "$TRK/mission-control/secret-box/.gitignore" ] && ok "the keydir writes its own .gitignore at creation" \
                                                    || bad "no .gitignore inside the keydir — it does not ignore itself"
if git -C "$TRK" check-ignore -q mission-control/secret-box/private.pem; then
  ok "keydir inside a TRACKED dir: git ignores private.pem on the keydir's own .gitignore alone"
else
  bad "TRACKED-dir keydir: git would COMMIT private.pem — the self-ignore is not working"
fi
# --ensure must repair a deleted self-ignore (additive, unlike touching a key) rather than call the
# keydir provisioned-and-fine. RED pre-fix: nothing ever wrote it in the first place.
rm -f "$TRK/mission-control/secret-box/.gitignore"
env -i PATH="$PATH" HOME="$FHOME" node "$GEN" --ensure --quiet --keydir "$TRK/mission-control/secret-box" >/dev/null 2>&1
[ -f "$TRK/mission-control/secret-box/.gitignore" ] && ok "--ensure repairs a deleted keydir .gitignore" \
                                                    || bad "--ensure left the keydir without its .gitignore"

# ── 6. NO NODE: the channel degrades, the BOARD does not ─────────────────────────────────────────
# node is advisory in kickoff, so a node-less box is supported — it must lose the secrets channel and
# keep the board, and /pubkey must say WHICH kind of missing this is (this one never fixes itself).
# RED pre-fix: /pubkey returned a bland 404 with no `reason` and a body telling a phone-only operator
# to go run secret-box-keygen.mjs on the box.
STATE_B="$(instance nodeless)"
NOBIN="$TMP/nodeless-bin"; mkdir -p "$NOBIN"
if start_server "$STATE_B" "$NOBIN"; then
  R="$(http "$PORT" /pubkey "$TOKEN")"
  if [ "$(status "$R")" = "404" ] && printf '%s' "$(body "$R")" | grep -q '"reason": *"node-missing"'; then
    ok "no node: /pubkey reports reason=node-missing (a state that will NOT fix itself by reloading)"
  else
    bad "no node: /pubkey → $(status "$R") $(body "$R" | head -1) (expected 404 + reason node-missing)"
  fi
  [ "$(status "$(http "$PORT" /healthz "")")" = "200" ] && ok "no node: /healthz still 200 — the board came up anyway" \
                                                        || bad "no node: the board did not come up — provisioning was made fatal"
  [ "$(status "$(http "$PORT" / "$TOKEN")")" = "200" ] && ok "no node: the board itself still serves (GET / → 200)" \
                                                       || bad "no node: GET / did not serve the board"
else
  bad "no node: the board never came up at all — the keypair must never outrank the board"
fi

# ── 7. NO SILENT FALLBACK to the machine-level keydir ────────────────────────────────────────────
# Derived keydir absent + a machine-level one present is ambiguous in the one way that fails GREEN:
# guess "reuse it" and every project on the box shares one key, one allow-list, one pinned .env;
# guess "make a fresh one" and already-provisioned secrets are stranded. Refuse, name both paths.
# RED pre-fix: the server read ~/.kickoff/secret-box/public.pem unconditionally and served the
# machine key with a cheerful 200 — the silent fallback, invisible to the operator.
LEGACY="$FHOME/.kickoff/secret-box"
env -i PATH="$PATH" HOME="$FHOME" node "$GEN" --ensure --quiet --keydir "$LEGACY" >/dev/null 2>&1
LEG_FP="$(head -1 "$LEGACY/public.fingerprint" 2>/dev/null)"
STATE_C="$(instance conflict)"
if start_server "$STATE_C"; then
  R="$(http "$PORT" /pubkey "$TOKEN")"
  B="$(body "$R")"
  if [ "$(status "$R")" = "404" ] && printf '%s' "$B" | grep -q '"reason": *"legacy-keydir-conflict"'; then
    ok "conflict: /pubkey refuses loudly instead of serving the machine-level key"
  else
    bad "conflict: /pubkey → $(status "$R") $(printf '%s' "$B" | head -1) (expected 404 + legacy-keydir-conflict)"
  fi
  if printf '%s' "$B" | grep -q "$(dirname "$STATE_C")/secret-box" && printf '%s' "$B" | grep -q "$LEGACY"; then
    ok "conflict: the message names BOTH paths (the operator can act on it)"
  else
    bad "conflict: the message does not name both keydirs — nobody can resolve it from that"
  fi
  [ -e "$(dirname "$STATE_C")/secret-box" ] && bad "conflict: a second keypair was provisioned anyway" \
                                            || ok "conflict: nothing was created in the project keydir"
  [ "$(head -1 "$LEGACY/public.fingerprint" 2>/dev/null)" = "$LEG_FP" ] \
    && ok "conflict: the machine-level key was not moved, rewritten, or re-keyed" \
    || bad "conflict: the machine-level keydir CHANGED — a private key was touched automatically"
else
  bad "conflict: the board did not come up — the refusal must not take the board down"
fi
# the same refusal in the two .mjs consumers, so a coordinator on the CLI cannot pick a different
# winner than the board did. RED pre-fix: neither script knew the derived keydir existed (exit 0/1).
rc="$(env -i PATH="$PATH" HOME="$FHOME" MC_STATE_FILE="$STATE_C" node "$GEN" --ensure --quiet >/dev/null 2>&1; echo $?)"
[ "$rc" = "4" ] && ok "keygen refuses the ambiguity too (exit 4)" || bad "keygen exit [$rc], want [4]"
rc="$(env -i PATH="$PATH" HOME="$FHOME" MC_STATE_FILE="$STATE_C" node "$DEC" "$TMP/payload.json" >/dev/null 2>&1; echo $?)"
[ "$rc" = "4" ] && ok "secret-decrypt refuses the ambiguity too (exit 4)" || bad "secret-decrypt exit [$rc], want [4]"

# ── 8. the REAL machine keydir came out of this run untouched ────────────────────────────────────
# The claim the isolation is worth nothing without: this suite provisioned five keypairs and never
# wrote to the operator's own ~/.kickoff/secret-box. (Nothing READ it either — every process ran
# with HOME pointed at the empty fixture, and every key served above matched an instance keydir.)
if [ "$(snap_real)" = "$REAL_BEFORE" ]; then
  ok "the real ~/.kickoff/secret-box is byte-identical before/after (untouched by this suite)"
else
  bad "the real ~/.kickoff/secret-box CHANGED during this run — the test is not \$HOME-isolated"
fi

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && printf '  ✅ the secrets channel self-provisions, per project, and every consumer agrees on the keydir\n'
[ "$FAIL" -eq 0 ]
