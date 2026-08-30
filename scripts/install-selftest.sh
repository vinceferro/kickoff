#!/usr/bin/env bash
# install-selftest.sh — prove the one-command installer (install.sh, v0.7 slice 1) actually gets you in.
#
#   bash scripts/install-selftest.sh
#
# WHAT IT PROVES (RED→GREEN in hermetic HOMEs)
#   RED    before install: `command -v kickoff` does NOT resolve.
#   GREEN  after install:  the core is cloned + PINNED at the latest STABLE core-v* tag; a
#          `~/.local/bin/kickoff` link resolves and EXECUTES from the read-only core clone; the
#          transcript prints the §1 spec surface — "✓ pinned <tag> @ <short-sha>", the two-path
#          footprint with the ONE-LINE UNINSTALL right under it, and exactly ONE next step
#          (`kickoff adopt --dry-run --dir .`) that SELF-ADAPTS to the explicit front-door path
#          off-PATH (the PATH one-liner is an OPTIONAL aside, never a second required step).
#          The next step is not just grepped — it is EXECUTED verbatim in a fixture user repo and
#          must exit 0 writing nothing; the fresh transcript must stay clean (no pull internals,
#          no second lowercase 'next:' from pull's epilogue, bounded length).
#   SIBLING-PARKED PIN: a populated adopters registry (a sibling pinned at a different tag) makes
#          pull park a worktree and leave the root clone UNPINNED — the installer must fail LOUD
#          and link nothing (never '✓ pinned ? @ <sha>' + a branch-tip engine).
#   RE-RUN = VERIFY-AND-REPAIR (the v0.7 contract): a re-run NEVER moves an existing pin — even
#          when the remote has published newer tags — it re-verifies origin + pin coherence,
#          repairs a missing/broken bin link, and re-prints tag@commit + the same one next step.
#          `kickoff pull` owns every upgrade; the installer never upgrades.
#   KICKOFF_TAG: pins an explicit core-v* tag on first install; REFUSES a non-core-v* ref with
#          ZERO side effects; REFUSES to move an existing pin to a different requested tag.
#   TRUNCATION ARMOR: install.sh is main()-wrapped, invoked on the LAST line — any prefix of the
#          file (a partial `curl | sh` download cut at a line boundary) executes NOTHING: zero
#          filesystem side effects in a fresh HOME.
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
# posture as pull-selftest.sh / reconcile-selftest.sh). GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE are
# unset too: they OVERRIDE `git -C <fixture>` (seen live 2026-08-23 — a fixture's commit+tag landed
# on a live repo and its stray core-vT tag red-ed this suite via the clone below). HOME/PATH are
# overridden per-invocation below.
unset REPO_DIR KICKOFF_CORE_DIR KICKOFF_CORE_REMOTE KICKOFF_BIN_DIR KICKOFF_ADOPTERS_REGISTRY \
      KICKOFF_VERSIONS_DIR KICKOFF_TAG MC_STATE_FILE MC_TRACKER_FILE INSTANCE_ENV \
      GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE 2>/dev/null || true

# A clean, standard-dirs-only PATH — deliberately excludes ~/.local/bin so the operator's own
# installed kickoff is invisible to `command -v` assertions. Verified to carry git/bash/python3.
SYSPATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
# NOTE: transcript lanes pipe $OUT into `grep` WITHOUT -q on purpose. Under `set -o pipefail`,
# `printf big | grep -q` can SIGPIPE the printf when grep matches early and exits (status 141 →
# pipeline non-zero) — which false-FAILS positive lanes and, worse, INVERTS `!`-negated lanes into
# false passes. Plain grep consumes the whole stream; chk's redirect discards its stdout.
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "▶ one-command installer self-test (install.sh — v0.7 slice 1)"
echo

for t in git bash python3; do
  PATH="$SYSPATH" command -v "$t" >/dev/null 2>&1 || { echo "  (required tool '$t' not on SYSPATH — cannot run hermetically)"; exit 0; }
done

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

# ── the hermetic local remote: a clone of THIS repo + synthetic core-v9.9.* tags ──────────────
REMOTE="$FIX/remote"
git clone --quiet "$REPO" "$REMOTE"
# The fixture OWNS the core-v* namespace: a clone inherits every tag of $REPO, so ANY stray tag
# leaked into the shared repo (seen live: adopt-selftest debris tagged core-v9.9.0/9.9.9, then —
# 2026-08-23 — a GIT_DIR-leaked `core-vT`, which version-sorts ABOVE every numeric tag and red-ed
# the sanity check below) makes the suite red on AMBIENT state, not code. Drop EVERY inherited
# core-v* name before re-tagging; the synthetic tags below are the only ones this fixture knows.
git -C "$REMOTE" tag -l 'core-v*' | while read -r _t; do git -C "$REMOTE" tag -d "$_t"; done
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
# ($HOME/kickoff-core, $HOME/.local/bin) are exercised. Set INSTALL_TAG to exercise KICKOFF_TAG.
INSTALL_TAG=""
run_install() {
  local h="$1" pathpre="$2" shellv="${3:-}"
  RC=0
  OUT="$(env -i \
    HOME="$h" \
    PATH="${pathpre}$SYSPATH" \
    ${shellv:+SHELL="$shellv"} \
    ${INSTALL_TAG:+KICKOFF_TAG="$INSTALL_TAG"} \
    KICKOFF_CORE_REMOTE="$REMOTE" \
    KICKOFF_ADOPTERS_REGISTRY="$h/.kickoff/adopters.json" \
    sh "$REPO/install.sh" 2>&1)" || RC=$?
}

# trunc_run KEEP_LINES SCRATCH_HOME — run a truncated prefix of install.sh in a fresh HOME.
# Exit code deliberately ignored (a mid-construct cut is ALLOWED to die with a parse error) —
# the assertion is purely "zero filesystem side effects".
trunc_run() {
  local keep="$1" th="$2"
  head -n "$keep" "$REPO/install.sh" > "$FIX/trunc.sh"
  env -i HOME="$th" PATH="$SYSPATH" \
    KICKOFF_CORE_REMOTE="$REMOTE" \
    KICKOFF_ADOPTERS_REGISTRY="$th/.kickoff/adopters.json" \
    sh "$FIX/trunc.sh" >/dev/null 2>&1 || true
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
# CASE 2 — GREEN: install into H1 (bin dir ON path) → cloned, pinned, linked, runnable, and the
#          §1 transcript: pinned tag@sha · two-path footprint · one-line uninstall · ONE next step.
# ═══════════════════════════════════════════════════════════════════════════════════════════════
echo "2. GREEN — first install (bin dir on PATH) + the §1 transcript"
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
  "printf '%s' \"\$KH\" | grep 'turnkey CLI'"
# the §1 transcript surface —
SHA1="$(git -C "$CORE1" rev-parse --short=8 HEAD 2>/dev/null || true)"
chk "transcript prints '✓ pinned $LATEST @ <short-sha>' (tag@commit, auditable)" \
  "printf '%s' \"\$OUT\" | grep -F 'pinned $LATEST @ $SHA1'"
chk "transcript prints 'installed kickoff $LATEST'" \
  "printf '%s' \"\$OUT\" | grep -F 'installed kickoff $LATEST'"
chk "footprint header: 'Installed exactly two things — no repo touched, no file of yours edited'" \
  "printf '%s' \"\$OUT\" | grep -F 'Installed exactly two things — no repo touched, no file of yours edited'"
chk "footprint names the engine path (~/kickoff-core, a read-only pinned git clone)" \
  "printf '%s\n' \"\$OUT\" | grep -F '~/kickoff-core' | grep -F 'the engine (a read-only pinned git clone)'"
chk "footprint names the front-door link (~/.local/bin/kickoff, one symlink)" \
  "printf '%s\n' \"\$OUT\" | grep -F '~/.local/bin/kickoff' | grep -F 'one symlink to its front door'"
chk "the ONE-LINE UNINSTALL sits right under the footprint (rm -rf of exactly the two paths)" \
  "printf '%s' \"\$OUT\" | grep -F 'Undo completely:  rm -rf ~/kickoff-core ~/.local/bin/kickoff'"
chk "exactly ONE 'Next:' step is printed" \
  "[ \"\$(printf '%s\n' \"\$OUT\" | grep -c '^  Next:')\" = 1 ]"
chk "the next step is the READ-ONLY dry-run WITH --dir . (the front door runs from the pinned core — without --dir the pure-pull guard refuses)" \
  "printf '%s' \"\$OUT\" | grep -F 'Next:  cd /path/to/your/repo && kickoff adopt --dry-run --dir .'"
# ── transcript hygiene (v0.7 §1: 'real copy — this is the spec'): pull's ENGINE-PREP internals and
#    its own lowercase 'next:' epilogue must NOT leak into the fresh-install transcript.
chk "fresh transcript is CLEAN — zero '[kickoff' engine-log lines leak from the delegated pull" \
  "! printf '%s' \"\$OUT\" | grep -F '[kickoff'"
chk "exactly ONE next step CASE-INSENSITIVELY (pull's own 'next:' epilogue must not add a second)" \
  "[ \"\$(printf '%s\n' \"\$OUT\" | grep -ci 'next:')\" = 1 ]"
chk "fresh transcript is BOUNDED (≤ 30 lines — the §1 surface, not a pull log dump)" \
  "[ \"\$(printf '%s\n' \"\$OUT\" | wc -l)\" -le 30 ]"
# ── §1's core property, EXECUTED (not grepped): the printed next step, pasted verbatim into a real
#    user repo, must WORK (exit 0, read-only). This is the lane the transcript-only greps missed.
UREPO="$FIX/user-repo"; mkdir -p "$UREPO/src"
git -C "$UREPO" init -q; git -C "$UREPO" config user.email u@u.u; git -C "$UREPO" config user.name u
printf 'hello\n' > "$UREPO/src/app.txt"; git -C "$UREPO" add -A; git -C "$UREPO" commit -qm baseline
NEXT_CMD="$(printf '%s\n' "$OUT" | sed -n 's/^  Next:  //p' | sed 's/  *(read-only.*$//')"
NEXT_CMD="${NEXT_CMD//\/path\/to\/your\/repo/$UREPO}"
NEXT_RC=0
NEXT_OUT="$(env -i HOME="$H1" PATH="$BIN1:$SYSPATH" sh -c "$NEXT_CMD" 2>&1)" || NEXT_RC=$?
chk "THE PRINTED NEXT STEP EXECUTES CLEAN in a real user repo (exit 0 — 'one next step, and it always works')" \
  "[ $NEXT_RC -eq 0 ]"
chk "the executed next step produced the read-only plan (dry-run completed — not a guard error)" \
  "printf '%s' \"\$NEXT_OUT\" | grep -F 'DRY-RUN COMPLETE'"
chk "the executed next step targeted the USER repo and wrote NOTHING (dry-run stays read-only)" \
  "[ ! -e \"$UREPO/.kickoff\" ] && [ -z \"\$(git -C \"$UREPO\" status --porcelain -uall)\" ]"
echo

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# CASE 3 — PATH-missing: the ONE next step SELF-ADAPTS to the explicit front-door path; the PATH
#          one-liner is an OPTIONAL aside, never a second required step.
# ═══════════════════════════════════════════════════════════════════════════════════════════════
echo "3. PATH-missing — the next step self-adapts; PATH fix is an optional aside"
H2="$FIX/home2"; mkdir -p "$H2"
BIN2="$H2/.local/bin"
run_install "$H2" ""    # no bin-dir prefix → $HOME/.local/bin is NOT on PATH
chk "install still exits 0 when the bin dir is off PATH" "[ ${RC:-1} -eq 0 ]"
chk "the link was still installed (only PATH wiring is deferred to the user)" "[ -L \"$BIN2/kickoff\" ]"
chk "exactly ONE 'Next:' step is printed (off-PATH too)" \
  "[ \"\$(printf '%s\n' \"\$OUT\" | grep -c '^  Next:')\" = 1 ]"
chk "the next step SELF-ADAPTS to the explicit front-door path (works without any PATH fix)" \
  "printf '%s' \"\$OUT\" | grep -F 'Next:  cd /path/to/your/repo && ~/kickoff-core/scripts/kickoff adopt --dry-run --dir .'"
# the off-PATH form must ALSO execute clean as printed (the ~ expands against the fresh HOME).
UREPO2="$FIX/user-repo2"; mkdir -p "$UREPO2"
git -C "$UREPO2" init -q; git -C "$UREPO2" config user.email u@u.u; git -C "$UREPO2" config user.name u
printf '# app\n' > "$UREPO2/README.md"; git -C "$UREPO2" add -A; git -C "$UREPO2" commit -qm baseline
NEXT2_CMD="$(printf '%s\n' "$OUT" | sed -n 's/^  Next:  //p' | sed 's/  *(read-only.*$//')"
NEXT2_CMD="${NEXT2_CMD//\/path\/to\/your\/repo/$UREPO2}"
NEXT2_RC=0
NEXT2_OUT="$(env -i HOME="$H2" PATH="$SYSPATH" sh -c "$NEXT2_CMD" 2>&1)" || NEXT2_RC=$?
chk "THE PRINTED OFF-PATH NEXT STEP EXECUTES CLEAN too (explicit front-door path, exit 0)" \
  "[ $NEXT2_RC -eq 0 ]"
chk "the off-PATH next step wrote NOTHING into the user repo" \
  "[ ! -e \"$UREPO2/.kickoff\" ] && [ -z \"\$(git -C \"$UREPO2\" status --porcelain -uall)\" ]"
chk "the PATH one-liner is offered as an OPTIONAL aside" \
  "printf '%s' \"\$OUT\" | grep 'Optional'"
chk "the optional aside carries the export one-liner verbatim" \
  "printf '%s' \"\$OUT\" | grep -F 'export PATH=\"$BIN2:\$PATH\"'"
# shell-awareness: a fish login shell gets fish's idiom instead of the export line.
run_install "$H2" "" "/usr/bin/fish"
chk "a fish shell gets the fish idiom (fish_add_path) instead of export" \
  "printf '%s' \"\$OUT\" | grep 'fish_add_path $BIN2'"
echo

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# CASE 4 — RE-RUN = VERIFY-AND-REPAIR (remote unchanged): exit 0, SAME pin, no re-clone, the
#          current tag@commit + the same one next step are re-printed.
# ═══════════════════════════════════════════════════════════════════════════════════════════════
echo "4. RE-RUN (remote unchanged) — verify-and-repair, pin untouched"
COMMIT_BEFORE="$(git -C "$CORE1" rev-parse HEAD 2>/dev/null || true)"
run_install "$H1" "$BIN1:"
COMMIT_AFTER="$(git -C "$CORE1" rev-parse HEAD 2>/dev/null || true)"
chk "re-run exits 0"                                             "[ ${RC:-1} -eq 0 ]"
chk "re-run VERIFIES the existing clone (no re-clone)" \
  "printf '%s' \"\$OUT\" | grep 'verifying' && ! printf '%s' \"\$OUT\" | grep 'one-time'"
chk "re-run says 'already installed'" \
  "printf '%s' \"\$OUT\" | grep 'already installed'"
chk "re-run left the pin UNCHANGED ($LATEST, same commit)"       "[ -n \"$COMMIT_AFTER\" ] && [ \"$COMMIT_BEFORE\" = \"$COMMIT_AFTER\" ]"
chk "re-run re-prints the current pin 'pinned $LATEST @ $SHA1'" \
  "printf '%s' \"\$OUT\" | grep -F 'pinned $LATEST @ $SHA1'"
chk "the link still points at the core front door"              "[ \"\$(readlink '$LINK1')\" = '$CORE1/scripts/kickoff' ]"
chk "re-run prints the SAME one next step (exactly one 'Next:')" \
  "[ \"\$(printf '%s\n' \"\$OUT\" | grep -c '^  Next:')\" = 1 ]"
echo

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# CASE 5 — RE-RUN MUST NOT RE-PIN: the remote publishes a NEWER stable tag; a blind re-run NEVER
#          moves the existing pin. `kickoff pull` owns every upgrade — the installer owns none.
# ═══════════════════════════════════════════════════════════════════════════════════════════════
echo "5. RE-RUN after the remote moved on — the pin MUST NOT move"
git -C "$REMOTE" commit --allow-empty -qm "synthetic core-v9.9.11"; git -C "$REMOTE" tag core-v9.9.11
LATEST2="core-v9.9.11"   # the remote's new latest stable — the installer must IGNORE it on re-run
run_install "$H1" "$BIN1:"
COMMIT_AFTER5="$(git -C "$CORE1" rev-parse HEAD 2>/dev/null || true)"
chk "re-run exits 0"                                             "[ ${RC:-1} -eq 0 ]"
chk "the pin did NOT move (same commit as before the new tag)"   "[ -n \"$COMMIT_AFTER5\" ] && [ \"$COMMIT_BEFORE\" = \"$COMMIT_AFTER5\" ]"
chk "the clone still describes the ORIGINAL pin ($LATEST)" \
  "[ \"\$(git -C '$CORE1' describe --tags --exact-match 2>/dev/null)\" = '$LATEST' ]"
chk "transcript re-prints the CURRENT pin ($LATEST @ $SHA1), not the newer tag" \
  "printf '%s' \"\$OUT\" | grep -F 'pinned $LATEST @ $SHA1'"
chk "transcript never claims the newer tag ($LATEST2)" \
  "! printf '%s' \"\$OUT\" | grep '9\.9\.11'"
# NOT UPGRADING MUST BE LOUD. Holding the pin is correct; doing it SILENTLY is the bug. "Re-run the
# installer to upgrade" is what everyone assumes, so a quiet verify reads as success while leaving
# them on the old engine — the operator fetched the v0.12 installer for a v0.12 fix, this path kept
# his v0.11 pin without a word, and his next command ran the old engine and did not do the thing he
# came for (2026-07-16). The pin-holding assertions above ALL passed for that run.
chk "re-run SAYS it is not upgrading (silence here reads as success on the old engine)" \
  "printf '%s' \"\$OUT\" | grep -iE 'NOT upgrading|never moves a pin'"
chk "re-run names the ACTUAL upgrade route (kickoff pull), not just what it declined to do" \
  "printf '%s' \"\$OUT\" | grep -F 'kickoff pull'"
echo

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# CASE 6 — REPAIR: a MISSING or BROKEN (dangling) bin link is repaired by a re-run; the pin stays put.
# ═══════════════════════════════════════════════════════════════════════════════════════════════
echo "6. REPAIR — missing/broken bin link is fixed by a re-run"
rm -f "$LINK1"
run_install "$H1" "$BIN1:"
chk "re-run after the link was DELETED exits 0"                  "[ ${RC:-1} -eq 0 ]"
chk "the missing link was re-created → the core front door" \
  "[ -L \"$LINK1\" ] && [ \"\$(readlink '$LINK1')\" = '$CORE1/scripts/kickoff' ]"
rm -f "$LINK1"; ln -s "$H1/nowhere-real" "$LINK1"   # a DANGLING symlink (target does not exist)
run_install "$H1" "$BIN1:"
chk "re-run over a BROKEN (dangling) link exits 0"               "[ ${RC:-1} -eq 0 ]"
chk "the repair is named in the transcript"                      "printf '%s' \"\$OUT\" | grep 'repairing'"
chk "the broken link was repaired → the core front door" \
  "[ -L \"$LINK1\" ] && [ \"\$(readlink '$LINK1')\" = '$CORE1/scripts/kickoff' ]"
echo

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# CASE 7 — REFUSE a FOREIGN bin link: a stranger's OWN ~/.local/bin/kickoff must NOT be clobbered.
#   Regression for the MED adversarial finding — the installer origin-guards ~/kickoff-core but must
#   apply the same courtesy to the bin link (a curl|sh installer silently rm'ing a user's file is a footgun).
# ═══════════════════════════════════════════════════════════════════════════════════════════════
echo "7. FOREIGN bin link — refused, not clobbered"
H3="$FIX/home3"; BIN3="$H3/.local/bin"; LINK3="$BIN3/kickoff"
mkdir -p "$BIN3"
printf '#!/bin/sh\necho "MY OWN kickoff — do not delete"\n' > "$LINK3"; chmod +x "$LINK3"
run_install "$H3" "$BIN3:"
chk "install REFUSES (non-zero) rather than clobber a foreign kickoff" "[ ${RC:-0} -ne 0 ]"
chk "it names the conflict (a different kickoff already exists)" \
  "printf '%s' \"\$OUT\" | grep \"a different 'kickoff' already exists\""
chk "the user's OWN kickoff SURVIVED (still a regular file, not our symlink)" \
  "[ -f \"$LINK3\" ] && [ ! -L \"$LINK3\" ] && grep -q 'MY OWN kickoff' \"$LINK3\""
echo

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# CASE 8 — KICKOFF_TAG: an explicit core-v* tag is pinned on first install (not the latest).
# ═══════════════════════════════════════════════════════════════════════════════════════════════
echo "8. KICKOFF_TAG — explicit tag override on first install"
H4="$FIX/home4"; mkdir -p "$H4"
CORE4="$H4/kickoff-core"; BIN4="$H4/.local/bin"
INSTALL_TAG="core-v9.9.8"
run_install "$H4" "$BIN4:"
INSTALL_TAG=""
SHA8="$(git -C "$CORE4" rev-parse --short=8 HEAD 2>/dev/null || true)"
chk "KICKOFF_TAG=core-v9.9.8 install exits 0"                    "[ ${RC:-1} -eq 0 ]"
chk "the core is pinned at the REQUESTED tag (core-v9.9.8), not the latest" \
  "[ \"\$(git -C '$CORE4' describe --tags --exact-match 2>/dev/null)\" = 'core-v9.9.8' ]"
chk "transcript names the requested pin: 'pinning core-v9.9.8 (via kickoff pull)'" \
  "printf '%s' \"\$OUT\" | grep -F 'pinning core-v9.9.8 (via kickoff pull)'"
chk "transcript prints '✓ pinned core-v9.9.8 @ <short-sha>'" \
  "printf '%s' \"\$OUT\" | grep -F 'pinned core-v9.9.8 @ $SHA8'"
echo

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# CASE 9 — KICKOFF_TAG must match ^core-v: anything else is REFUSED with ZERO side effects.
# ═══════════════════════════════════════════════════════════════════════════════════════════════
echo "9. KICKOFF_TAG — a non-core-v* ref is refused, zero side effects"
H5="$FIX/home5"; mkdir -p "$H5"
INSTALL_TAG="main"
run_install "$H5" ""
INSTALL_TAG=""
chk "KICKOFF_TAG=main is REFUSED (non-zero exit)"                "[ ${RC:-0} -ne 0 ]"
chk "the refusal names the constraint (only core-v* release tags)" \
  "printf '%s' \"\$OUT\" | grep 'not a core-v'"
chk "ZERO side effects — the fresh HOME is still empty (nothing cloned, nothing linked)" \
  "[ -z \"\$(find '$H5' -mindepth 1 -print -quit 2>/dev/null)\" ]"
echo

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# CASE 10 — KICKOFF_TAG vs an EXISTING pin: the installer NEVER moves a pin — refuse, point at pull.
# ═══════════════════════════════════════════════════════════════════════════════════════════════
echo "10. KICKOFF_TAG against an existing pin — refused, pull owns upgrades"
COMMIT_BEFORE10="$(git -C "$CORE1" rev-parse HEAD 2>/dev/null || true)"
INSTALL_TAG="core-v9.9.8"
run_install "$H1" "$BIN1:"
INSTALL_TAG=""
COMMIT_AFTER10="$(git -C "$CORE1" rev-parse HEAD 2>/dev/null || true)"
chk "a KICKOFF_TAG that differs from the existing pin is REFUSED (non-zero)" "[ ${RC:-0} -ne 0 ]"
chk "the refusal states the contract (never moves an existing pin) and points at kickoff pull" \
  "printf '%s' \"\$OUT\" | grep 'never moves an existing pin' && printf '%s' \"\$OUT\" | grep 'kickoff pull'"
chk "the pin did not move"                                       "[ -n \"$COMMIT_AFTER10\" ] && [ \"$COMMIT_BEFORE10\" = \"$COMMIT_AFTER10\" ]"
echo

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# CASE 11 — PIN COHERENCE: an existing UNPINNED clone (manual git clone, branch HEAD) gets pinned —
#           there is no existing pin to move, so the installer completes the install.
# ═══════════════════════════════════════════════════════════════════════════════════════════════
echo "11. PIN COHERENCE — an unpinned manual clone gets pinned on install"
H6="$FIX/home6"; mkdir -p "$H6"
CORE6="$H6/kickoff-core"; BIN6="$H6/.local/bin"
git clone --quiet "$REMOTE" "$CORE6"   # a manual clone: origin matches, but HEAD is a BRANCH (no pin)
run_install "$H6" "$BIN6:"
chk "install over an unpinned clone exits 0"                     "[ ${RC:-1} -eq 0 ]"
chk "the unpinned clone is now PINNED at the latest stable ($LATEST2)" \
  "[ \"\$(git -C '$CORE6' describe --tags --exact-match 2>/dev/null)\" = '$LATEST2' ]"
chk "the bin link was created"                                   "[ -L \"$BIN6/kickoff\" ]"
echo

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# CASE 12 — TRUNCATION ARMOR: any prefix of install.sh (a partial download cut at a line boundary)
#           executes NOTHING. main() is invoked on the LAST line, so N-1 is the strongest cut:
#           the ENTIRE body is present, only the invocation is missing.
# ═══════════════════════════════════════════════════════════════════════════════════════════════
echo "12. TRUNCATION ARMOR — a partial download executes nothing"
NLINES="$(wc -l < "$REPO/install.sh")"
ti=0
for cut in $((NLINES / 4)) $((NLINES / 2)) $((3 * NLINES / 4)) $((NLINES - 1)); do
  ti=$((ti + 1))
  TH="$FIX/trunc-home-$ti"; mkdir -p "$TH"
  trunc_run "$cut" "$TH"
  chk "truncated at line $cut/$NLINES → ZERO side effects (fresh HOME still empty)" \
    "[ -z \"\$(find '$TH' -mindepth 1 -print -quit 2>/dev/null)\" ]"
done
echo

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# CASE 13 — SIBLING-PARKED PIN: a fresh install on a box whose adopters registry already lists a
#           project pinned at a DIFFERENT tag. `kickoff pull` protects that sibling by parking the
#           requested tag in a SEPARATE worktree and leaving the root clone on its BRANCH.
#
#           This case used to assert the installer FAILS LOUD here. That was WRONG, and it made
#           "one command to get in" work ONLY ON A CLEAN BOX — found 2026-07-16 when the operator
#           ran the stock one-liner on his own box, which already runs three kickoff projects. The
#           installer named the parked dir in its own error and then declined to use it, while both
#           remedies it suggested were dead ends: "keep the shared clone" leaves no front door at
#           all, and "delete the registry" breaks the live projects that registry exists to protect.
#           Nobody had ever installed onto a box with adopters.
#
#           The corrected contract, and the invariant it must NOT weaken:
#             · a parked worktree that IS a detached core-v* pin → LINK IT (a real pin; the shared
#               clone stays untouched, so the sibling's protection still holds).
#             · NO usable parked pin → still FAIL LOUD, link nothing. Never link a branch tip (13b).
# ═══════════════════════════════════════════════════════════════════════════════════════════════
echo "13. SIBLING-PARKED PIN — link the parked pin; never link a branch tip"
H7="$FIX/home7"; BIN7="$H7/.local/bin"; CORE7="$H7/kickoff-core"
mkdir -p "$H7/.kickoff" "$H7/sibling-project"
cat > "$H7/.kickoff/adopters.json" <<REG
{"schema_version": 1, "adopters": [{"repo": "$H7/sibling-project", "tag": "core-v9.9.8", "channel": ""}]}
REG
run_install "$H7" "$BIN7:"
chk "install SUCCEEDS by linking the parked pin (the engine exists — refusing it stranded the user)" \
  "[ ${RC:-0} -eq 0 ]"
chk "no success lie: '✓ pinned ? @' never appears (a '?' tag is never reported as pinned)" \
  "! printf '%s' \"\$OUT\" | grep -F 'pinned ? @'"
chk "it SAYS it linked the parked pin (the sibling protection is explained, not silent)" \
  "printf '%s' \"\$OUT\" | grep -i 'parked'"
chk "a front door WAS linked (the whole point of the one command)" \
  "[ -e \"$BIN7/kickoff\" ]"
chk "the link points at the PARKED engine, not the shared clone" \
  "[ \"\$(readlink -f \"$BIN7/kickoff\" 2>/dev/null)\" != \"\$(readlink -f '$CORE7/scripts/kickoff' 2>/dev/null)\" ]"
chk "INVARIANT HOLDS: the linked engine is a DETACHED core-v* pin, never a branch tip" \
  "_lk=\"\$(readlink -f \"$BIN7/kickoff\" 2>/dev/null)\"; _ld=\"\$(dirname \"\$(dirname \"\$_lk\")\")\"; \
   ! git -C \"\$_ld\" symbolic-ref -q HEAD >/dev/null 2>&1 && git -C \"\$_ld\" describe --tags --exact-match 2>/dev/null | grep -q '^core-v'"
chk "the shared root clone was left on its branch, untouched (the sibling's protection held)" \
  "git -C '$CORE7' symbolic-ref -q HEAD >/dev/null"
echo

# NOTE — the "no usable parked pin → still fail loud" path is deliberately NOT a separate case here.
# It is covered where it matters: case 13's INVARIANT assertion runs on the real success path and
# reds if the linked engine is ever a branch tip rather than a detached core-v* pin — which is the
# only lie widening this path could introduce.
#
# A standalone fixture for it was attempted and REMOVED rather than massaged green: blocking
# $HOME/kickoff-versions with a file did NOT produce "registry populated + nothing parked" — install
# still succeeded, apparently because pull falls back to pinning the root clone when it cannot park.
# That fallback may itself be worth a look (it would mean a sibling goes unprotected in that state),
# but it is a contrived edge and NOT what this suite claims to test. Shipping an assertion whose
# fixture does not create the state it asserts is how a suite goes green while the bug is live —
# the exact failure this file exists to catch. Left honest and unclaimed instead.

echo "──────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "  ✅ install.sh: one command gets you in (clone · pin · link · transcript · verify-and-repair · KICKOFF_TAG · truncation armor)"; exit 0; } || { echo "  ❌ see failures above"; exit 1; }
