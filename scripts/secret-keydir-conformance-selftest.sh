#!/usr/bin/env bash
# secret-keydir-conformance-selftest.sh — THE CROSS-CONSUMER AGREEMENT SUITE for the secrets keydir.
#
#   bash scripts/secret-keydir-conformance-selftest.sh
#   SECRET_CORE_UNDER_TEST=<repo-shaped dir> bash scripts/...   # RED-proof a pre-fix tree
#
# WHY THIS EXISTS. Three components resolve the secret-box keydir:
#
#     scripts/secret-box-keygen.mjs · scripts/secret-decrypt.mjs · mission-control/server.py
#
# Two are Node and one is Python, so they CANNOT share an implementation — the server must resolve
# the keydir on a box with no node (node is advisory in kickoff). The contract "one identical rule
# in every consumer" was therefore written as PROSE ("IDENTICAL TWIN … MUST stay byte-identical")
# and implemented three times. Within a single slice the three copies disagreed in four separate
# ways, every one of which fails GREEN:
#
#   1. the legacy-ambiguity predicate: server.py asked `not isdir(keydir)`, the .mjs twins asked
#      about private.pem — so a keydir that EXISTS BUT IS EMPTY was a conflict to one half and
#      not to the other;
#   2. ensure_secret_keypair() declared the channel healthy on exists(public.pem) ALONE — a
#      public-only keydir reported ok while every secret encrypted to it was undecryptable;
#   3. KICKOFF_PUBKEY was honoured ONLY by server.py — set it and the board serves key A while
#      the coordinator decrypts with key B;
#   4. a KICKOFF_PUBKEY whose basename was not public.pem made the server GENERATE a stray
#      keypair into that dirname — a read-only config var that became a write trigger.
#
# A sentence cannot hold that invariant. A test can. So: for every cell of an environment matrix
# this suite asks all three components "which keydir do you resolve, and what state is it in?" and
# fails loudly on ANY disagreement. The oracle is scripts/secret-keydir.mjs's `--json` dump — the
# single canonical definition the two .mjs consumers import and the Python twin is held to.
#
# WHAT IT ASSERTS PER CELL (four phases, four INDEPENDENT copies of the same fixture shape, so no
# phase can observe another's writes):
#   A  resolve   — module --json  ≡  server.py's SECRET_KEYDIR/SOURCE/READONLY/BAD_BASENAME/
#                  LEGACY_CONFLICT/inspect_keydir(), field for field. Nothing may be written.
#   B  keygen    — secret-box-keygen.mjs --ensure exits the code the oracle's fields predict, and
#                  when it creates, it creates at the oracle's keydir and NOWHERE else.
#   C  decrypt   — secret-decrypt.mjs is handed ONE reference ciphertext. Where the oracle says
#                  `absent` it must ENOENT on exactly the oracle's privPath; everywhere else it
#                  must ROUND-TRIP, which is only possible if it opened that keydir. The `foreign-key`
#                  cell is the negative control that keeps that exit-0 from being vacuous.
#   D  server    — ensure_secret_keypair() + secret_channel_state() reach the verdict the oracle's
#                  fields predict, and refusal cells write nothing at all.
#
# ISOLATION. This box has a real months-old keydir at ~/.kickoff/secret-box. Every child here runs
# under `env -i PATH=… HOME=<fixture>` with cwd inside the fixture, and the suite asserts positively
# that the real one is byte-identical before/after. A fixture inheriting the real $HOME goes green
# while the bug is live.
#
# It runs the REAL artifacts — the real .mjs scripts, the real server.py imported as a module —
# never a replica. A fourth re-implementation of the resolution rule inside the test would just be
# another copy to drift.
#
# ── RED-FIRST (a check never watched go RED proves nothing) ──────────────────────────────────────
# Two negative controls were run. (a) The WHOLE pre-fix tree — `git show HEAD:` of server.py +
# secret-box-keygen.mjs + secret-decrypt.mjs into a scratch dir, passed as SECRET_CORE_UNDER_TEST:
# 32 passed, 80 failed. (b) MUTATION controls: each confirmed divergence reintroduced ALONE into a
# scratch copy of the current tree, to prove which cell catches which bug and that the cells are
# not merely co-firing:
#
#   finding 1  server-side legacy-conflict predicate back to isdir()/public.pem
#              → `ambiguity-emptydir` RED (server says no-conflict, provisions a SECOND key while
#                the machine-wide one holds the live one). 100 passed, 6 failed.
#   finding 2  inspect_keydir() fail-GREEN on exists(public.pem) alone
#              → `public-only` + `fp-mismatch` RED (server verdict [ok] vs [key-half-missing] /
#                [inconsistent-keydir]). 99 passed, 7 failed.
#   finding 3  secret-decrypt.mjs ignoring KICKOFF_PUBKEY (the split-flow shape)
#              → `pubkey-ok` + `pubkey-absent` + `pubkey-bad-basename` RED. 99 passed, 7 failed.
#   finding 4  KICKOFF_PUBKEY as a WRITE trigger (server guard + keygen read-only refusal removed)
#              → `pubkey-absent` + `explicit-readonly` RED on all four axes — wrong exit, keygen
#                wrote, wrong verdict, "the server WROTE while refusing". 95 passed, 11 failed.
#
# TWO ASSERTIONS COULD NOT BE MADE TO GO RED, and saying so is the point of writing it down:
#   · the `~/.kickoff/secret-box is untouched` isolation claim — making it red means damaging the
#     operator's real key material. It is a live tripwire (it fires if a fixture ever leaks $HOME),
#     but it has never been observed firing, so treat it as unproven rather than as evidence.
#   · the `foreign-key` negative control cannot be made red for its INTENDED reason (that would
#     mean RSA-OAEP decrypting under the wrong key). It went red in control (a) for the wrong
#     reason — decrypt found no key at all. Its job is to stop every "decrypt round-tripped"
#     assertion from being vacuous, and it does that; it is not itself independently proven.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SRC="${SECRET_CORE_UNDER_TEST:-$REPO}"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }

command -v python3 >/dev/null 2>&1 || { printf '  ❌ python3 not found\n'; exit 1; }
# node is ADVISORY in kickoff (a node-less box is supported and loses only the secrets channel), so
# a node-less runner cannot run the oracle at all — skip rather than report a false green.
command -v node >/dev/null 2>&1 || { echo "  (skip) node not present — the whole channel is node-conditional by design"; exit 0; }
PY3="$(command -v python3)"
for f in mission-control/server.py scripts/secret-box-keygen.mjs scripts/secret-decrypt.mjs \
         scripts/secret-encrypt.mjs; do
  [ -f "$SRC/$f" ] || { printf '  ❌ %s not found under %s\n' "$f" "$SRC"; exit 1; }
done
[ -f "$REPO/scripts/secret-keydir.mjs" ] || { printf '  ❌ the oracle scripts/secret-keydir.mjs is missing\n'; exit 1; }

echo "▶ secret-keydir CONFORMANCE self-test (keygen ≡ secret-decrypt ≡ server.py, over an env matrix)"
echo

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# The REAL machine-level keydir must come out of this run byte-identical.
REAL_LEGACY="$HOME/.kickoff/secret-box"
snap_real() { [ -d "$REAL_LEGACY" ] && find "$REAL_LEGACY" -mindepth 1 -exec stat -c '%n %s %Y %Z %a' {} \; 2>/dev/null | sort || echo ABSENT; }
REAL_BEFORE="$(snap_real)"

# ── the core under test: a shared PINNED-CORE shape (engine here, keydir in the instance) ────────
# The ORACLE is always the canon scripts/secret-keydir.mjs from THIS repo, even when the consumers
# come from a pre-fix tree — the question this suite asks is "does each consumer conform to the
# canonical rule", and a pre-fix consumer that never imports it is exactly the failure being caught.
CORE="$TMP/kickoff-versions/core-vX"
mkdir -p "$CORE/mission-control" "$CORE/scripts"
cp "$SRC/mission-control/server.py" "$CORE/mission-control/"
for h in dashboard.html secrets.html universe.html; do
  [ -f "$SRC/mission-control/$h" ] && cp "$SRC/mission-control/$h" "$CORE/mission-control/"
done
cp "$SRC/scripts/secret-box-keygen.mjs" "$SRC/scripts/secret-decrypt.mjs" "$SRC/scripts/secret-encrypt.mjs" "$CORE/scripts/"
cp "$REPO/scripts/secret-keydir.mjs" "$CORE/scripts/"
SRV="$CORE/mission-control/server.py"
GEN="$CORE/scripts/secret-box-keygen.mjs"
DEC="$CORE/scripts/secret-decrypt.mjs"
ENC="$CORE/scripts/secret-encrypt.mjs"
ORACLE="$CORE/scripts/secret-keydir.mjs"

# ── the server.py probes ─────────────────────────────────────────────────────────────────────────
# Imported as a MODULE, not replicated: these are the very constants GET /pubkey and the keygen
# shell-out read. Importing is side-effect-free (token creation and provisioning both live inside
# main(), behind the __main__ guard) — probe `ensure` opts INTO the provisioning explicitly.
cat > "$TMP/probe-resolve.py" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("mcsrv_probe", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(json.dumps({
    "keydir": m.SECRET_KEYDIR, "source": m.SECRET_KEYDIR_SOURCE,
    "readOnly": bool(m.SECRET_KEYDIR_READONLY),
    "badBasename": m.SECRET_KEYDIR_BAD_BASENAME,
    "legacyConflict": bool(m.SECRET_KEYDIR_LEGACY_CONFLICT),
    "state": m.inspect_keydir(),
}))
PY
cat > "$TMP/probe-ensure.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mcsrv_probe", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.ensure_secret_keypair()
print(m.secret_channel_state())
PY
# RED-PROOF SHIM. A pre-fix server.py has none of these names — it had one line, `PUBKEY_PATH =
# $KICKOFF_PUBKEY or ~/.kickoff/secret-box/public.pem`, and no provisioner at all. A probe that
# merely CRASHED there would read as a broken test rather than as the divergence it is, so this
# variant degrades to that older shape and lets the COMPARISON do the reporting. Against the
# current tree it is byte-for-byte the strict probes above (every getattr hits).
cat > "$TMP/probe-resolve-compat.py" <<'PY'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("mcsrv_probe", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
keydir = getattr(m, "SECRET_KEYDIR", None) or os.path.dirname(m.PUBKEY_PATH)
source = getattr(m, "SECRET_KEYDIR_SOURCE", None) or ("pubkey" if os.environ.get("KICKOFF_PUBKEY") else "legacy")
f = getattr(m, "inspect_keydir", None)
# the pre-fix fail-green predicate: "the public key file is there" == provisioned
state = f() if f else ("ok" if os.path.exists(m.PUBKEY_PATH) else "absent")
print(json.dumps({
    "keydir": keydir, "source": source,
    "readOnly": bool(getattr(m, "SECRET_KEYDIR_READONLY", False)),
    "badBasename": getattr(m, "SECRET_KEYDIR_BAD_BASENAME", None),
    "legacyConflict": bool(getattr(m, "SECRET_KEYDIR_LEGACY_CONFLICT", False)),
    "state": state,
}))
PY
cat > "$TMP/probe-ensure-compat.py" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("mcsrv_probe", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
ensure = getattr(m, "ensure_secret_keypair", None)
if ensure: ensure()
verdict = getattr(m, "secret_channel_state", None)
if verdict: print(verdict())
else: print("ok" if os.path.exists(m.PUBKEY_PATH) else "not-provisioned")   # pre-fix: file-exists
PY

# ── fixture material: ONE reference keypair, copied into shapes (RSA-3072 once, not 16 times) ────
REFHOME="$TMP/refhome"; mkdir -p "$REFHOME"
REF="$TMP/ref"
env -i PATH="$PATH" HOME="$REFHOME" node "$GEN" --quiet --keydir "$REF" >/dev/null 2>&1
[ -f "$REF/private.pem" ] || { printf '  ❌ could not generate the reference keypair with %s\n' "$GEN"; exit 1; }
# A SECOND, unrelated keypair — the negative control that keeps "decrypt exited 0" from being vacuous.
FOREIGN="$TMP/foreign"
env -i PATH="$PATH" HOME="$REFHOME" node "$GEN" --quiet --keydir "$FOREIGN" >/dev/null 2>&1
# The one reference ciphertext every phase-C probe is handed. Encrypted to REF's PUBLIC half, so it
# decrypts if and only if the consumer opened a keydir holding REF's private half.
PLAIN="k1ckoff-conformance-plaintext"
env -i PATH="$PATH" HOME="$REFHOME" node "$ENC" "$REF/public.pem" "$PLAIN" --name CONFORMANCE_KEY \
  > "$TMP/payload.json" 2>/dev/null
[ -s "$TMP/payload.json" ] || { printf '  ❌ could not produce the reference ciphertext\n'; exit 1; }

put_all()  { mkdir -p "$1"; cp "$REF/private.pem" "$REF/public.pem" "$REF/public.fingerprint" "$1/"; chmod 600 "$1/private.pem"; }
put_pub()  { mkdir -p "$1"; cp "$REF/public.pem" "$REF/public.fingerprint" "$1/"; }
put_priv() { mkdir -p "$1"; cp "$REF/private.pem" "$1/"; chmod 600 "$1/private.pem"; }
put_bad()  { put_all "$1"; printf 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\ndeadbeef\n' > "$1/public.fingerprint"; }
put_foreign() { mkdir -p "$1"; cp "$FOREIGN/private.pem" "$FOREIGN/public.pem" "$FOREIGN/public.fingerprint" "$1/"; chmod 600 "$1/private.pem"; }

# instance <root> <name> — an adopter-shaped instance dir; echoes its state-file path.
instance() {
  local d="$1/$2"
  mkdir -p "$d/.kickoff/state/mission-control"
  printf '{"headline":"x","in_progress":[],"functions":{},"blocked":[],"done":[],"activity":[]}' \
    > "$d/.kickoff/state/mission-control/mission-state.json"
  printf '%s\n' "$d/.kickoff/state/mission-control/mission-state.json"
}

# ── THE MATRIX ───────────────────────────────────────────────────────────────────────────────────
# build_shape <shape> <root> — materialise the shape under $root. Writes the child environment to
# $root/.env-spec (ONE assignment per line, so a value containing spaces survives — the `blank`
# cell depends on that) and any explicit --keydir argument to $root/.keydir-arg.
build_shape() {
  local shape="$1" root="$2" st legacy
  mkdir -p "$root/home"
  legacy="$root/home/.kickoff/secret-box"
  : > "$root/.env-spec"; : > "$root/.keydir-arg"
  case "$shape" in
    nothing)              ;;                                   # origin / greenfield: legacy, absent
    legacy-provisioned)   put_all "$legacy" ;;                  # legacy, ok
    mc-state)             st="$(instance "$root" repo)"; echo "MC_STATE_FILE=$st" >> "$root/.env-spec" ;;
    kickoff-state)        st="$(instance "$root" repo)"; echo "KICKOFF_STATE=$st" >> "$root/.env-spec" ;;
    both)                 st="$(instance "$root" repo-a)"
                          echo "KICKOFF_STATE=$st" >> "$root/.env-spec"
                          st="$(instance "$root" repo-b)"
                          echo "MC_STATE_FILE=$st" >> "$root/.env-spec" ;;
    env-keydir)           st="$(instance "$root" repo)"
                          echo "MC_STATE_FILE=$st" >> "$root/.env-spec"
                          echo "KICKOFF_SECRET_KEYDIR=$root/chosen" >> "$root/.env-spec" ;;
    pubkey-ok)            st="$(instance "$root" repo)"; put_all "$root/served"
                          echo "MC_STATE_FILE=$st" >> "$root/.env-spec"
                          echo "KICKOFF_PUBKEY=$root/served/public.pem" >> "$root/.env-spec" ;;
    pubkey-absent)        st="$(instance "$root" repo)"; mkdir -p "$root/served"
                          echo "MC_STATE_FILE=$st" >> "$root/.env-spec"
                          echo "KICKOFF_PUBKEY=$root/served/public.pem" >> "$root/.env-spec" ;;
    pubkey-bad-basename)  st="$(instance "$root" repo)"; put_all "$root/served"
                          cp "$root/served/public.pem" "$root/served/box.pem"
                          echo "MC_STATE_FILE=$st" >> "$root/.env-spec"
                          echo "KICKOFF_PUBKEY=$root/served/box.pem" >> "$root/.env-spec" ;;
    explicit-readonly)    st="$(instance "$root" repo)"; mkdir -p "$root/served"
                          echo "MC_STATE_FILE=$st" >> "$root/.env-spec"
                          echo "KICKOFF_PUBKEY=$root/served/public.pem" >> "$root/.env-spec"
                          printf '%s\n' "$root/served" > "$root/.keydir-arg" ;;
    blank)                printf 'KICKOFF_PUBKEY=   \n' >> "$root/.env-spec"
                          printf 'KICKOFF_SECRET_KEYDIR=  \n' >> "$root/.env-spec" ;;
    empty)                st="$(instance "$root" repo)"
                          echo "MC_STATE_FILE=$st" >> "$root/.env-spec"
                          echo "KICKOFF_PUBKEY=" >> "$root/.env-spec"
                          echo "KICKOFF_SECRET_KEYDIR=" >> "$root/.env-spec" ;;
    ambiguity)            put_all "$legacy"; st="$(instance "$root" repo)"
                          echo "MC_STATE_FILE=$st" >> "$root/.env-spec" ;;
    ambiguity-emptydir)   put_all "$legacy"; st="$(instance "$root" repo)"
                          mkdir -p "$(dirname "$st")/secret-box"
                          echo "MC_STATE_FILE=$st" >> "$root/.env-spec" ;;
    public-only)          st="$(instance "$root" repo)"; put_pub "$(dirname "$st")/secret-box"
                          echo "MC_STATE_FILE=$st" >> "$root/.env-spec" ;;
    private-only)         st="$(instance "$root" repo)"; put_priv "$(dirname "$st")/secret-box"
                          echo "MC_STATE_FILE=$st" >> "$root/.env-spec" ;;
    fp-mismatch)          st="$(instance "$root" repo)"; put_bad "$(dirname "$st")/secret-box"
                          echo "MC_STATE_FILE=$st" >> "$root/.env-spec" ;;
    provisioned)          st="$(instance "$root" repo)"; put_all "$(dirname "$st")/secret-box"
                          echo "MC_STATE_FILE=$st" >> "$root/.env-spec" ;;
    foreign-key)          st="$(instance "$root" repo)"; put_foreign "$(dirname "$st")/secret-box"
                          echo "MC_STATE_FILE=$st" >> "$root/.env-spec" ;;
    *) printf '  ❌ unknown shape %s\n' "$shape"; exit 1 ;;
  esac
}

SHAPES="nothing legacy-provisioned mc-state kickoff-state both env-keydir pubkey-ok pubkey-absent \
pubkey-bad-basename explicit-readonly blank empty ambiguity ambiguity-emptydir public-only \
private-only fp-mismatch provisioned foreign-key"

# run_in <root> <cmd…> — the child, hermetically: `env -i`, HOME at the fixture, cwd INSIDE the
# fixture (so a relative resolution lands somewhere visible instead of in this repo).
run_in() {
  local root="$1"; shift
  local -a E=()
  mapfile -t E < "$root/.env-spec"
  ( cd "$root" && env -i PATH="$PATH" HOME="$root/home" "${E[@]}" "$@" )
}

# tree <root> — everything under the fixture except its bookkeeping files, for stray-write checks.
tree() { find "$1" -mindepth 1 \! -name .env-spec \! -name .keydir-arg 2>/dev/null | sort; }

# ── the phases ───────────────────────────────────────────────────────────────────────────────────
for shape in $SHAPES; do
  echo "── cell: $shape"
  ROOTA="$TMP/A-$shape"; ROOTB="$TMP/B-$shape"; ROOTC="$TMP/C-$shape"; ROOTD="$TMP/D-$shape"
  for r in "$ROOTA" "$ROOTB" "$ROOTC" "$ROOTD"; do mkdir -p "$r"; build_shape "$shape" "$r"; done
  KDA="$(cat "$ROOTA/.keydir-arg")"

  # ── PHASE A: module oracle ≡ server.py, field for field ────────────────────────────────────────
  A_BEFORE="$(tree "$ROOTA")"
  if [ -n "$KDA" ]; then
    OJ="$(run_in "$ROOTA" node "$ORACLE" --json --keydir "${KDA/#$ROOTA/$ROOTA}")"
  else
    OJ="$(run_in "$ROOTA" node "$ORACLE" --json)"
  fi
  if [ -z "$OJ" ]; then
    bad "$shape: the oracle produced no output — every assertion in this cell is unrunnable"
    continue
  fi
  eval "$(printf '%s' "$OJ" | "$PY3" -c '
import json, shlex, sys
d = json.load(sys.stdin)
def sh(k, v): print("%s=%s" % (k, shlex.quote(str(v))))
sh("O_KEYDIR", d["keydir"]); sh("O_SOURCE", d["source"])
sh("O_READONLY", "1" if d["readOnly"] else "0")
sh("O_BADBASE", d["badBasename"] or "")
sh("O_CONFLICT", "1" if d["legacyConflict"] else "0")
sh("O_STATE", d["state"]); sh("O_PRIV", d["privPath"]); sh("O_PUB", d["pubPath"])
')"
  ORACLE_REC="keydir=$O_KEYDIR|source=$O_SOURCE|readOnly=$O_READONLY|badBasename=$O_BADBASE|legacyConflict=$O_CONFLICT|state=$O_STATE"

  # server.py takes no --keydir, so a cell that carries one is not a cell the server participates
  # in on that axis — its own explicit-keydir path is covered by phase D (it shells the keygen out
  # with `--keydir SECRET_KEYDIR`, which is exactly what `explicit-readonly` exercises).
  if [ -n "$KDA" ]; then
    echo "  (n/a) phase A: this cell passes an explicit --keydir; server.py has no such input"
  else
    SJ="$(run_in "$ROOTA" "$PY3" "$TMP/probe-resolve-compat.py" "$SRV" 2>"$TMP/srv.err")"
    if [ -z "$SJ" ]; then
      bad "$shape: server.py could not be probed — $(head -1 "$TMP/srv.err")"
    else
      SERVER_REC="$(printf '%s' "$SJ" | "$PY3" -c '
import json, sys
d = json.load(sys.stdin)
print("keydir=%s|source=%s|readOnly=%s|badBasename=%s|legacyConflict=%s|state=%s" % (
    d["keydir"], d["source"], "1" if d["readOnly"] else "0", d["badBasename"] or "",
    "1" if d["legacyConflict"] else "0", d["state"]))
')"
      if [ "$SERVER_REC" = "$ORACLE_REC" ]; then
        ok "$shape: server.py ≡ secret-keydir.mjs  ($O_SOURCE · $O_STATE$([ "$O_CONFLICT" = 1 ] && echo ' · conflict')$([ "$O_READONLY" = 1 ] && echo ' · read-only'))"
      else
        bad "$shape: server.py ≢ secret-keydir.mjs"
        printf '        module: %s\n        server: %s\n' "$ORACLE_REC" "$SERVER_REC"
      fi
    fi
  fi
  [ "$(tree "$ROOTA")" = "$A_BEFORE" ] || bad "$shape: the read-only resolve probes WROTE to the fixture"

  # ── the contract, computed from the ORACLE's fields (never restated per cell) ───────────────────
  if   [ -n "$O_BADBASE" ];    then WANT_GEN=2; WANT_DEC=2; WANT_SRV="pubkey-bad-basename"
  elif [ "$O_CONFLICT" = 1 ];  then WANT_GEN=4; WANT_DEC=4; WANT_SRV="legacy-keydir-conflict"
  elif [ "$O_STATE" = ok ];    then WANT_GEN=0; WANT_DEC=0; WANT_SRV="ok"
  elif [ "$O_STATE" = torn ] || [ "$O_STATE" = mismatch ]; then
                                    WANT_GEN=3; WANT_DEC=0; WANT_SRV="inconsistent-keydir"
  elif [ "$O_READONLY" = 1 ];  then WANT_GEN=5; WANT_DEC=1; WANT_SRV="readonly-keydir-unprovisioned"
  elif [ -f "$O_PUB" ];        then WANT_GEN=0; WANT_DEC=1; WANT_SRV="key-half-missing"
  else                              WANT_GEN=0; WANT_DEC=1; WANT_SRV="ok"
  fi
  # WANT_DEC=0 for torn/mismatch is not a typo: secret-decrypt.mjs needs only the PRIVATE half, and
  # these fixtures hold the reference private key — so a round-trip proves it opened this keydir.
  # WANT_GEN=0 with an orphan public.pem is the ONE SANCTIONED divergence: the keygen provisions
  # over it, the server declines to (`key-half-missing`). Asserted below in the strict direction.

  # ── PHASE B: secret-box-keygen.mjs — the exit code, and WHERE it creates ───────────────────────
  BKEY="${O_PRIV/#$ROOTA/$ROOTB}"
  B_TREE_BEFORE="$(tree "$ROOTB")"
  B_KEYS_BEFORE="$(find "$ROOTB" -name private.pem 2>/dev/null | sort)"
  if [ -n "$KDA" ]; then
    run_in "$ROOTB" node "$GEN" --ensure --quiet --keydir "${KDA/#$ROOTA/$ROOTB}" >/dev/null 2>&1
  else
    run_in "$ROOTB" node "$GEN" --ensure --quiet >/dev/null 2>&1
  fi
  rc=$?
  [ "$rc" = "$WANT_GEN" ] && ok "$shape: keygen exit $rc (the oracle's fields predict $WANT_GEN)" \
                          || bad "$shape: keygen exit [$rc], the oracle's fields predict [$WANT_GEN]"
  B_KEYS_AFTER="$(find "$ROOTB" -name private.pem 2>/dev/null | sort)"
  if [ "$WANT_GEN" != 0 ]; then
    # A REFUSAL. Every guard fires before the keydir is even mkdir'd, so nothing may change at all —
    # this is what catches "a read-only config var started generating a stray keypair into its dirname".
    if [ "$(tree "$ROOTB")" = "$B_TREE_BEFORE" ]; then
      ok "$shape: keygen refused and wrote NOTHING, anywhere under the fixture"
    else
      bad "$shape: keygen refused but the fixture changed:"
      diff <(printf '%s\n' "$B_TREE_BEFORE") <(tree "$ROOTB") | sed 's/^/        /'
    fi
  elif [ "$O_STATE" = ok ]; then
    [ "$B_KEYS_AFTER" = "$B_KEYS_BEFORE" ] \
      && ok "$shape: keygen was idempotent on an already-provisioned keydir (no new private key)" \
      || bad "$shape: keygen re-keyed an already-provisioned keydir — [$B_KEYS_BEFORE] → [$B_KEYS_AFTER]"
  else
    # It provisioned. It must have provisioned at the ORACLE's keydir, and there must be no second
    # private.pem anywhere else under the fixture.
    [ -f "$BKEY" ] && ok "$shape: keygen created the keypair at exactly the oracle's keydir" \
                   || bad "$shape: keygen exited 0 but $BKEY does not exist (keys found: ${B_KEYS_AFTER:-none})"
    WANT_KEYS="$(printf '%s\n%s\n' "$B_KEYS_BEFORE" "$BKEY" | grep -v '^$' | sort -u)"
    [ "$B_KEYS_AFTER" = "$WANT_KEYS" ] \
      || bad "$shape: a private.pem appeared somewhere unexpected — got [$(printf '%s' "$B_KEYS_AFTER" | tr '\n' ' ')], want [$(printf '%s' "$WANT_KEYS" | tr '\n' ' ')]"
  fi

  # ── PHASE C: secret-decrypt.mjs — one reference ciphertext, in every cell ──────────────────────
  cp "$TMP/payload.json" "$ROOTC/payload.json"
  if [ -n "$KDA" ]; then
    COUT="$(run_in "$ROOTC" node "$DEC" "$ROOTC/payload.json" --keep --keydir "${KDA/#$ROOTA/$ROOTC}" 2>&1)"
  else
    COUT="$(run_in "$ROOTC" node "$DEC" "$ROOTC/payload.json" --keep 2>&1)"
  fi
  crc=$?
  CKEY="${O_PRIV/#$ROOTA/$ROOTC}"
  if [ "$shape" = foreign-key ]; then
    # THE NEGATIVE CONTROL. Without it, every "decrypt exited 0" above could be passing on a keydir
    # shared by everything, or on a decrypt that ignores the keydir entirely.
    if [ "$crc" != 0 ] && printf '%s' "$COUT" | grep -q 'decryption failed'; then
      ok "$shape: negative control — a keydir holding a DIFFERENT key cannot decrypt this payload"
    else
      bad "$shape: negative control FAILED — decrypt exit [$crc] on a foreign key: $(printf '%s' "$COUT" | head -1)"
    fi
  elif [ "$WANT_DEC" = 0 ]; then
    [ "$crc" = 0 ] && [ "$COUT" = "$PLAIN" ] \
      && ok "$shape: secret-decrypt round-tripped — it opened the oracle's keydir" \
      || bad "$shape: secret-decrypt exit [$crc] out [$(printf '%s' "$COUT" | head -1)] — it did not open $CKEY"
  elif [ "$WANT_DEC" = 1 ]; then
    # `absent`: the ONLY honest proof of which path it reached for is the path in the error.
    if [ "$crc" != 0 ] && printf '%s' "$COUT" | grep -q -F "$CKEY"; then
      ok "$shape: secret-decrypt reached for exactly the oracle's private key path"
    else
      bad "$shape: secret-decrypt exit [$crc] never names $CKEY — $(printf '%s' "$COUT" | head -1)"
    fi
  else
    [ "$crc" = "$WANT_DEC" ] && ok "$shape: secret-decrypt exit $crc (the oracle's fields predict $WANT_DEC)" \
                            || bad "$shape: secret-decrypt exit [$crc], want [$WANT_DEC] — $(printf '%s' "$COUT" | head -1)"
  fi

  # ── PHASE D: server.py's own verdict — ensure_secret_keypair() → secret_channel_state() ────────
  D_BEFORE="$(tree "$ROOTD")"
  DSTATE="$(run_in "$ROOTD" "$PY3" "$TMP/probe-ensure-compat.py" "$SRV" 2>"$TMP/srvd.err")"
  [ -n "$DSTATE" ] || DSTATE="<probe failed: $(head -1 "$TMP/srvd.err")>"
  [ "$DSTATE" = "$WANT_SRV" ] && ok "$shape: server verdict '$DSTATE' (the oracle's fields predict '$WANT_SRV')" \
                              || bad "$shape: server verdict [$DSTATE], the oracle's fields predict [$WANT_SRV]"
  if [ "$WANT_SRV" != "ok" ] && [ "$O_STATE" != ok ]; then
    [ "$(tree "$ROOTD")" = "$D_BEFORE" ] \
      && ok "$shape: the server wrote NOTHING while refusing" \
      || { bad "$shape: the server WROTE while refusing:"; diff <(printf '%s\n' "$D_BEFORE") <(tree "$ROOTD") | sed 's/^/        /'; }
  fi
  echo
done

# ── the ONE sanctioned divergence, asserted in the strict direction ──────────────────────────────
# An orphan public.pem is `absent` to the shared predicate. The keygen provisions over it; the
# server declines to at unattended start-up (overwriting a public key whose private half may be on
# someone's backup). That is a POLICY difference on top of an AGREED state, and it is only safe in
# one direction — the server stricter, never looser. Pin the direction so a future "simplification"
# that makes the server provision here has to argue with a test.
echo "── the one sanctioned policy divergence (server STRICTER than keygen on an orphan public half)"
PO="$TMP/D-public-only"
if [ -d "$PO" ]; then
  if [ ! -f "$PO/repo/.kickoff/state/mission-control/secret-box/private.pem" ]; then
    ok "public-only: the server did NOT provision over the orphan public.pem"
  else
    bad "public-only: the server provisioned over an orphan public key at start-up"
  fi
  if [ -f "$TMP/B-public-only/repo/.kickoff/state/mission-control/secret-box/private.pem" ]; then
    ok "public-only: the keygen DID provision (the divergence is real, and it is policy, not state)"
  else
    bad "public-only: the keygen did not provision either — the divergence direction is unproven"
  fi
else
  bad "public-only fixtures missing — the sanctioned-divergence assertion could not run"
fi
echo

# ── the isolation claim, without which every green above is worth nothing ────────────────────────
if [ "$(snap_real)" = "$REAL_BEFORE" ]; then
  ok "the real ~/.kickoff/secret-box is byte-identical before/after (untouched by this suite)"
else
  bad "the real ~/.kickoff/secret-box CHANGED during this run — the suite is not \$HOME-isolated"
fi

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && printf '  ✅ all three keydir consumers answer identically across the whole environment matrix\n'
[ "$FAIL" -eq 0 ]
