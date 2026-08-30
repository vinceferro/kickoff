#!/usr/bin/env bash
# core-resolution-selftest.sh — the front door must adopt onto the core it IS, not one it assumes.
#
#   bash scripts/core-resolution-selftest.sh
#
# The bug (found 2026-07-16 at a live adopter's adopt, before it touched anything): every core_dir in
# `scripts/kickoff` defaulted to a hardcoded `$HOME/kickoff-core`. The `kickoff` symlink carries no
# env, so once install.sh's own documented KICKOFF_CORE_DIR override put the core anywhere else — e.g.
# the real per-version layout, ~/kickoff-versions/core-vX — a LATER invocation silently fell back to
# ~/kickoff-core. A v0.10 front door then adopted a repo onto a stale core-v0.1 sitting there: wrong
# tag pinned, THE WHOLE PLUGIN LAYER SKIPPED (that old core had no plugin/), and a local dev path
# stamped as the public KICKOFF_CORE_REMOTE. No warning. The script knew where it lived the whole time.
#
# So: build the real failing shape — a front door OUTSIDE $HOME/kickoff-core, with a DECOY core sitting
# at the old default — and assert the front door picks ITSELF. Hermetic: a fake $HOME, mktemp fixtures,
# `--dry-run` only (writes nothing), never the live box.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }

# ── 0. structural: no hardcoded default may come back ────────────────────────────────────────────
n_hard=$(grep -cE ':-\$HOME/kickoff-core|:-~/kickoff-core' "$REPO/scripts/kickoff" 2>/dev/null || true)
[ "${n_hard:-0}" -eq 0 ] && ok "no hardcoded ~/kickoff-core default in scripts/kickoff" \
  || bad "$n_hard hardcoded ~/kickoff-core default(s) back in scripts/kickoff — the wrong-core bug returns"
grep -q '^KICKOFF_CORE_DEFAULT=' "$REPO/scripts/kickoff" \
  && ok "KICKOFF_CORE_DEFAULT is defined (the self-resolved core root)" \
  || bad "KICKOFF_CORE_DEFAULT missing — nothing anchors core_dir to the running front door"

# ── build the fixture: fake $HOME, a DECOY at the old default, the real core elsewhere ───────────
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT
FAKE_HOME="$T/home"; mkdir -p "$FAKE_HOME"

# the DECOY: a core-shaped git clone parked at the OLD hardcoded default. If the front door picks
# THIS, the bug is back. Deliberately carries NO plugin/ — the real decoy's tell.
DECOY="$FAKE_HOME/kickoff-core"
mkdir -p "$DECOY/scripts"
( cd "$DECOY" && git init -q . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m decoy \
  && git tag core-vDECOY ) 2>/dev/null

# The REAL core the front door lives in, at a per-version path (the layout that broke).
#
# CLONE — never `cp -r`. A real pinned core is a clean git clone: TRACKED FILES ONLY. `cp -r` drags in
# the origin's gitignored `.kickoff/instance.env`, which pins KICKOFF_CORE_DIR=<the origin repo> and
# overrides the very default under test — the fixture then FALSE-GREENS on the pre-fix code (observed
# while writing this suite; the fixture must match the real deploy shape, not the dev checkout —
# [[pull-adopter-scripts-resolve-siblings-not-repo-dir]] · [[a-check-without-a-selftest-cannot-fail]]).
CORE="$FAKE_HOME/kickoff-versions/core-vTEST"
mkdir -p "$(dirname "$CORE")"
git clone -q --local --no-hardlinks "$REPO" "$CORE" 2>/dev/null || { bad "could not clone the core fixture"; }
# the file under test is the WORKING-TREE one, not HEAD's (we are testing the current edit)
cp "$REPO/scripts/kickoff" "$CORE/scripts/kickoff" 2>/dev/null
[ -e "$CORE/.kickoff/instance.env" ] && bad "fixture carries a .kickoff/instance.env — it would mask the default under test"
# A --local clone's origin IS a filesystem path, which would trip the local-path assertion below on its
# own fixture. Give it a public-shaped remote so that check tests the CODE, not the fixture's plumbing.
git -C "$CORE" remote set-url origin "https://github.com/example/kickoff-fixture.git" 2>/dev/null
( cd "$CORE" && git add -A >/dev/null 2>&1 \
  && git -c user.email=t@t -c user.name=t commit -q -m core 2>/dev/null; git tag -f core-vTEST >/dev/null 2>&1 ) 2>/dev/null

# a target repo to dry-run the adopt against
TARGET="$T/target"; mkdir -p "$TARGET"
( cd "$TARGET" && git init -q . && echo x > f.txt && git add -A \
  && git -c user.email=t@t -c user.name=t commit -q -m init ) 2>/dev/null

# ── 1. THE DEPLOY TEST: no KICKOFF_CORE_DIR, decoy present → must resolve ITSELF ─────────────────
out="$(cd "$TARGET" && env -u KICKOFF_CORE_DIR -u REPO_DIR -u TELEGRAM_STATE_DIR -u MEMORY_DIR \
        -u MEMORY_INDEX -u MC_STATE_FILE -u CHANNEL_SPEC \
        HOME="$FAKE_HOME" timeout 180 bash "$CORE/scripts/kickoff" adopt --dry-run --dir . 2>&1)"

case "$out" in
  *core-vDECOY*) bad "WRONG CORE: the front door resolved the DECOY at \$HOME/kickoff-core, not the core it lives in" ;;
  *core-vTEST*)  ok  "the front door resolves the core it IS part of (not the decoy at the old default)" ;;
  *)             bad "could not tell which core was chosen — output named neither tag:
       $(printf '%s' "$out" | tail -3)" ;;
esac

# the plugin layer is the loudest casualty: a stale/plugin-less core silently skips it
case "$out" in
  *"skipping plugin enablement"*) bad "PLUGIN LAYER SKIPPED — the resolved core has no plugin/ (the decoy's tell)" ;;
  *"would enable the plugin"*)    ok  "plugin enablement is planned (the resolved core carries plugin/)" ;;
esac

# and the remote must be the real one, never a local path
case "$out" in
  *"KICKOFF_CORE_REMOTE=/"*|*"KICKOFF_CORE_REMOTE=$FAKE_HOME"*)
    bad "a LOCAL PATH was stamped as KICKOFF_CORE_REMOTE — the adoptee's future pull would fetch from a dev checkout" ;;
  *) ok "no local path stamped as the public KICKOFF_CORE_REMOTE" ;;
esac

# ── 2. an EXPLICIT KICKOFF_CORE_DIR still wins (the documented override must keep working) ───────
out2="$(cd "$TARGET" && env -u REPO_DIR -u TELEGRAM_STATE_DIR -u MEMORY_DIR -u MEMORY_INDEX \
         -u MC_STATE_FILE -u CHANNEL_SPEC \
         HOME="$FAKE_HOME" KICKOFF_CORE_DIR="$DECOY" timeout 180 bash "$CORE/scripts/kickoff" \
         adopt --dry-run --dir . 2>&1)"
case "$out2" in
  *core-vDECOY*) ok "an explicit KICKOFF_CORE_DIR still overrides the default (documented behaviour intact)" ;;
  *) bad "explicit KICKOFF_CORE_DIR was IGNORED — the fix broke the documented override" ;;
esac

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && printf '  ✅ front door resolves its OWN core (RED on the decoy; explicit override still wins)\n'
[ "$FAIL" -eq 0 ]
