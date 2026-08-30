#!/usr/bin/env bash
# install-selftest.sh — prove the one-command installer (install.sh, goal G1) actually gets you in.
#
#   bash scripts/install-selftest.sh
#
# WHAT IT PROVES (RED→GREEN in one hermetic HOME)
#   RED  before install: `command -v kickoff` does NOT resolve.
#   GREEN after install:  the core is cloned + PINNED at the latest STABLE core-v* tag; a
#                         `~/.local/bin/kickoff` link resolves and EXECUTES from the read-only core
#                         clone; the run reports the pinned tag.
#   PATH:  when the bin dir is NOT on PATH the installer prints the ONE-LINE fix (`export PATH=…`).
#   IDEMPOTENT: a re-run exits 0, re-pins the SAME tag (no re-clone), and says "already installed".
#
# HERMETIC — NEVER the live box. This builds its OWN throwaway world under a single mktemp root:
#   • a LOCAL git remote (a clone of THIS repo + synthetic core-v9.9.* tags) — no network, file paths only;
#   • a SCRATCH $HOME per install, so the core clone (~/kickoff-core), the bin link (~/.local/bin), and
#     the adopters registry (~/.kickoff/adopters.json) ALL land under mktemp — never real $HOME, never
#     the live ~/kickoff-core;
#   • every install runs under `env -i` with a hand-built SYSPATH (standard dirs only) so the operator's
#     OWN installed `kickoff` can never satisfy an assertion.
# The synthetic tags sit on DISTINCT empty commits so `describe --exact-match` is unambiguous, and a
# core-v9.9.10-rc1 pre-release proves the installer pins the latest STABLE (rc excluded), not merely newest.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# Scrub any inherited kickoff/instance env so a caller's LIVE paths never steer this fixture (same
# posture as pull-selftest.sh / reconcile-selftest.sh). HOME/PATH are overridden per-invocation below.
unset REPO_DIR KICKOFF_CORE_DIR KICKOFF_CORE_REMOTE KICKOFF_BIN_DIR KICKOFF_ADOPTERS_REGISTRY \
      KICKOFF_VERSIONS_DIR MC_STATE_FILE MC_TRACKER_FILE INSTANCE_ENV 2>/dev/null || true

# A clean, standard-dirs-only PATH — deliberately excludes ~/.local/bin so the operator's own
# installed kickoff is invisible to `command -v` assertions. Verified to carry git/bash/python3.
SYSPATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "▶ one-command installer self-test (install.sh — goal G1)"
echo

for t in git bash python3; do
  PATH="$SYSPATH" command -v "$t" >/dev/null 2>&1 || { echo "  (required tool '$t' not on SYSPATH — cannot run hermetically)"; exit 0; }
done

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

# ── the hermetic local remote: a clone of THIS repo + synthetic core-v9.9.* tags ──────────────
REMOTE="$FIX/remote"
git clone --quiet "$REPO" "$REMOTE"
git -C "$REMOTE" config user.email selftest@kickoff.local
git -C "$REMOTE" config user.name  kickoff-install-selftest
# Distinct empty commits → `describe --exact-match` is unambiguous. Empty commits keep the tree
# (and thus every core-manifest.txt file) intact, so pull's existence guard passes at each tag.
git -C "$REMOTE" commit --allow-empty -qm "synthetic core-v9.9.8";     git -C "$REMOTE" tag core-v9.9.8
git -C "$REMOTE" commit --allow-empty -qm "synthetic core-v9.9.9";     git -C "$REMOTE" tag core-v9.9.9
git -C "$REMOTE" commit --allow-empty -qm "synthetic core-v9.9.10-rc1"; git -C "$REMOTE" tag core-v9.9.10-rc1
git -C "$REMOTE" commit --allow-empty -qm "main past the tags"   # HEAD beyond every tag (fresh-clone shape)

LATEST="core-v9.9.9"   # the newest STABLE (the rc must be excluded)
chk "fixture sanity: the remote's latest STABLE core-v* tag is $LATEST (rc excluded)" \
  "[ \"\$(git -C '$REMOTE' tag -l 'core-v*' | { grep -v -- '-rc' || true; } | sort -V | tail -1)\" = '$LATEST' ]"

# run_install HOME PATH_PREFIX [SHELL] -> sets RC + OUT. env -i = a truly clean environment; only the
# vars below cross in. CORE_DIR / BIN_DIR are left UNSET on purpose so the installer's OWN defaults
# ($HOME/kickoff-core, $HOME/.local/bin) are exercised.
run_install() {
  local h="$1" pathpre="$2" shellv="${3:-}"
  RC=0
  OUT="$(env -i \
    HOME="$h" \
    PATH="${pathpre}$SYSPATH" \
    ${shellv:+SHELL="$shellv"} \
    KICKOFF_CORE_REMOTE="$REMOTE" \
    KICKOFF_ADOPTERS_REGISTRY="$h/.kickoff/adopters.json" \
    sh "$REPO/install.sh" 2>&1)" || RC=$?
}

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# CASE 1 — RED baseline: a fresh scratch HOME has NO kickoff on PATH yet.
# ═══════════════════════════════════════════════════════════════════════════════════════════════
H1="$FIX/home1"; mkdir -p "$H1"
CORE1="$H1/kickoff-core"; BIN1="$H1/.local/bin"; LINK1="$BIN1/kickoff"
echo "1. RED baseline — no install yet"
CV_BEFORE="$(env -i HOME="$H1" PATH="$BIN1:$SYSPATH" sh -c 'command -v kickoff' 2>/dev/null || true)"
chk "RED: \`command -v kickoff\` does NOT resolve before install" "[ -z \"$CV_BEFORE\" ]"
chk "RED: no core clone exists yet"                               "[ ! -e \"$CORE1\" ]"
echo

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# CASE 2 — GREEN: install into H1 (bin dir ON path) → cloned, pinned, linked, runnable.
# ═══════════════════════════════════════════════════════════════════════════════════════════════
echo "2. GREEN — first install (bin dir on PATH)"
run_install "$H1" "$BIN1:"
chk "install exits 0"                                            "[ ${RC:-1} -eq 0 ]"
chk "core clone created at the default \$HOME/kickoff-core"      "[ -d \"$CORE1/.git\" ]"
chk "core is PINNED at the latest STABLE tag ($LATEST)" \
  "[ \"\$(git -C '$CORE1' describe --tags --exact-match 2>/dev/null)\" = '$LATEST' ]"
chk "core clone is a DETACHED-HEAD read-only pin (not on a branch)" \
  "! git -C '$CORE1' symbolic-ref -q HEAD >/dev/null 2>&1"
chk "the bin link was created at the default \$HOME/.local/bin/kickoff" "[ -L \"$LINK1\" ]"
chk "the link points AT the core clone's scripts/kickoff" \
  "[ \"\$(readlink '$LINK1')\" = '$CORE1/scripts/kickoff' ]"
# command -v resolves through the controlled PATH…
CV_AFTER="$(env -i HOME="$H1" PATH="$BIN1:$SYSPATH" sh -c 'command -v kickoff' 2>/dev/null || true)"
chk "GREEN: \`command -v kickoff\` now resolves to the installed link" "[ \"$CV_AFTER\" = \"$LINK1\" ]"
# …and the linked front door actually EXECUTES from the read-only clone (usage banner via the symlink).
KH="$(env -i HOME="$H1" PATH="$BIN1:$SYSPATH" kickoff help 2>&1 || true)"
chk "the linked kickoff EXECUTES through the symlink (prints its usage banner)" \
  "printf '%s' \"\$KH\" | grep -q 'turnkey CLI'"
chk "the run reports the installed tag ($LATEST)" "printf '%s' \"\$OUT\" | grep -q 'installed kickoff $LATEST'"
chk "the run confirms the bin dir is on PATH"     "printf '%s' \"\$OUT\" | grep -q 'on your PATH'"
echo

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# CASE 3 — PATH-missing: install into a fresh HOME with the bin dir OFF path → prints the one-line fix.
# ═══════════════════════════════════════════════════════════════════════════════════════════════
echo "3. PATH-missing — the one-line fix is printed"
H2="$FIX/home2"; mkdir -p "$H2"
BIN2="$H2/.local/bin"
run_install "$H2" ""    # no bin-dir prefix → $HOME/.local/bin is NOT on PATH
chk "install still exits 0 when the bin dir is off PATH" "[ ${RC:-1} -eq 0 ]"
chk "it warns the bin dir is not on PATH"                "printf '%s' \"\$OUT\" | grep -q 'not on your PATH'"
chk "it prints the ONE-LINE fix: export PATH=\"<bindir>:\$PATH\"" \
  "printf '%s' \"\$OUT\" | grep -qF 'export PATH=\"$BIN2:\$PATH\"'"
# even off-PATH, the install itself completed (the link is real; only PATH wiring is left to the user).
chk "the link was still installed (only PATH wiring is deferred to the user)" "[ -L \"$BIN2/kickoff\" ]"
# shell-awareness: a fish login shell gets fish's idiom instead of the export line.
run_install "$H2" "" "/usr/bin/fish"
chk "a fish shell gets the fish idiom (fish_add_path) instead of export" \
  "printf '%s' \"\$OUT\" | grep -q 'fish_add_path $BIN2'"
echo

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# CASE 4 — IDEMPOTENT: re-run into H1 → exit 0, SAME pin, no re-clone, "already installed".
# ═══════════════════════════════════════════════════════════════════════════════════════════════
echo "4. IDEMPOTENT — a re-run updates in place"
COMMIT_BEFORE="$(git -C "$CORE1" rev-parse HEAD 2>/dev/null || true)"
run_install "$H1" "$BIN1:"
COMMIT_AFTER="$(git -C "$CORE1" rev-parse HEAD 2>/dev/null || true)"
chk "re-run exits 0"                                             "[ ${RC:-1} -eq 0 ]"
chk "re-run says 'already installed — updated to $LATEST'" \
  "printf '%s' \"\$OUT\" | grep -q 'already installed' && printf '%s' \"\$OUT\" | grep -q 'updated to $LATEST'"
chk "re-run did NOT re-clone (updated the existing clone in place)" \
  "printf '%s' \"\$OUT\" | grep -q 'updating' && ! printf '%s' \"\$OUT\" | grep -q 'one-time'"
chk "re-run left the pin UNCHANGED ($LATEST, same commit)"       "[ -n \"$COMMIT_AFTER\" ] && [ \"$COMMIT_BEFORE\" = \"$COMMIT_AFTER\" ]"
chk "the link still points at the core front door"              "[ \"\$(readlink '$LINK1')\" = '$CORE1/scripts/kickoff' ]"
echo

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# CASE 5 — REFUSE a FOREIGN bin link: a stranger's OWN ~/.local/bin/kickoff must NOT be clobbered.
#   Regression for the MED adversarial finding — the installer origin-guards ~/kickoff-core but must
#   apply the same courtesy to the bin link (a curl|sh installer silently rm'ing a user's file is a footgun).
# ═══════════════════════════════════════════════════════════════════════════════════════════════
echo "5. FOREIGN bin link — refused, not clobbered"
H3="$FIX/home3"; BIN3="$H3/.local/bin"; LINK3="$BIN3/kickoff"
mkdir -p "$BIN3"
printf '#!/bin/sh\necho "MY OWN kickoff — do not delete"\n' > "$LINK3"; chmod +x "$LINK3"
run_install "$H3" "$BIN3:"
chk "install REFUSES (non-zero) rather than clobber a foreign kickoff" "[ ${RC:-0} -ne 0 ]"
chk "it names the conflict (a different kickoff already exists)" \
  "printf '%s' \"\$OUT\" | grep -q \"a different 'kickoff' already exists\""
chk "the user's OWN kickoff SURVIVED (still a regular file, not our symlink)" \
  "[ -f \"$LINK3\" ] && [ ! -L \"$LINK3\" ] && grep -q 'MY OWN kickoff' \"$LINK3\""
echo

echo "──────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "  ✅ install.sh: one command gets you in (clone · pin · link · PATH-fix · idempotent)"; exit 0; } || { echo "  ❌ see failures above"; exit 1; }
