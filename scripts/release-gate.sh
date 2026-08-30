#!/usr/bin/env bash
# release-gate.sh — fail-closed, release-TIME gate for a `core-v*` release candidate. Run it before you
# tag: it compares the candidate tree against the previous release tag and refuses a release that would
# brick adopters. It is a release tool, NOT a git hook — no commit/push side effects, read-only git
# (the ONE write is a throwaway detached worktree in /tmp, removed + pruned by an EXIT trap).
#
#   scripts/release-gate.sh --prev <prev-tag>                       # gate HEAD vs the last release
#   scripts/release-gate.sh --candidate <ref> --prev <prev-tag>     # gate an explicit candidate ref
#   scripts/release-gate.sh --repo <dir> --candidate <ref> --prev <tag>   # gate another checkout (tests)
#   scripts/release-gate.sh --prev core-v0.8.1 --skip-suites        # fast structural pass (advisory-loud)
#   scripts/release-gate.sh --prev core-v0.8.1 --only leak-scan     # re-run ONE check after a fix
#
# ── SEVERITY MODEL (LOCKED decision #3) ───────────────────────────────────────────────────────────────
#   HARD  [FAIL] — anything that LEAKS, SPENDS, or BRICKS AN ADOPTER. Flips the exit code. Do not tag.
#   ADVISORY [WARN] — cosmetics / degraded-but-takeable. Printed LOUDLY and counted, never blocks.
#   Exit is CONJUNCTIVE over the HARD checks: 0 iff ZERO [FAIL]. Advisories are always named in the
#   summary — a green with 3 advisories says so.
#
# ── CHECKS ────────────────────────────────────────────────────────────────────────────────────────────
#   HARD  plugin-version-vs-content   if ANY plugin/ file changed vs prev (plugin.json INCLUDED) then
#         (v0.9 slice 1)              plugin.json's `version` MUST have changed too — else the pull's
#                                     plugin-cache re-sync no-ops and every adopter's `kickoff pull`
#                                     fails closed at preflight #8. The real core-v0.8 bug (2026-07-13).
#                                     plugin.json is NOT carved out of the content check: preflight #8's
#                                     byte-verify hashes it too, so a commands/hooks/description edit with
#                                     no version bump bricks exactly the same population (v0.9 slice 2).
#   HARD  manifest-existence-guard    every path in the candidate's scripts/core-manifest.txt must EXIST
#                                     in the candidate tree — `kickoff pull` DIEs at step 4 ("refusing to
#                                     pin a partial core") BEFORE core.lock is written, so a missing core
#                                     file makes the release UNTAKEABLE for every adopter. Also fails on a
#                                     missing/empty manifest (pull dies on both).
#   ADV   manifest-covers-new-files   a NEW file (vs prev) in a directory the manifest already covers, but
#                                     itself unlisted. Under the format-2 WHOLE-TREE pin it still travels,
#                                     so it does not brick — it only loses the existence guard + the
#                                     documented contract. Advisory by construction.
#   ADV   changelog-top-section       the candidate's CORE-CHANGELOG.md has a topmost `## core-vX.Y`
#                                     section, it is NON-EMPTY, and it matches --version. NEVER checks the
#                                     date: every real tag ships its own heading as "— unreleased" (the
#                                     date is backfilled after the tag), so a date check would false-RED
#                                     100% of releases. `kickoff pull`'s own changelog step is explicitly
#                                     advisory ("never fails the pull") — this mirrors it.
#   ADV   installer-url-parity        every canonical tag-pinned install.sh URL (README · QUICKSTART ·
#                                     install.sh's own header) names the SAME version, == the candidate
#                                     version. Advisory: existing adopters upgrade via `kickoff pull`
#                                     (never reads README) and install.sh resolves the latest STABLE
#                                     core-v* tag dynamically — a stale doc URL breaks the FRONT DOOR for
#                                     a new stranger, it does not brick an adopter. Emits the install.sh
#                                     SHA-256 for the release notes (there is nothing to verify it against
#                                     offline — see the POST-TAG note the check prints).
#   HARD  leak-scan-on-tree           the WHOLE candidate tree (not the delta — a delta scan is blind to
#                                     inherited files; v0.5 caught 3 leaks that had been public since
#                                     v0.4) against: scan-secrets.sh, structural scratchpad/machine-path
#                                     forms, machine identity DERIVED from the environment, and an
#                                     out-of-tree identity denylist. A public tag is IRREVERSIBLE — you
#                                     cannot unpublish it. Straight "leaks" → HARD.
#   HARD  suites-on-exact-tree        every suite the candidate's own lefthook.yml declares under pre-push
#                                     is RUN from a detached worktree of the CANDIDATE REF (not the dirty
#                                     working tree), each bounded by a timeout. The suites ARE the
#                                     adopter-facing machinery (pull · plugin · journey-e2e cover the
#                                     `kickoff pull` path) — a red one on the release tree is the literal
#                                     brick-an-adopter class. `--skip-suites` opts out with an UNMISSABLE
#                                     advisory; the default is the honest heavy path (~2 min).
#   HARD  parity-ledger               engine-parity is RECORDED, never silent: scripts/parity-report.sh
#                                     (v0.9 parity slice) probes every capability's wiring per engine on
#                                     the candidate tree and holds it against docs/PARITY.md. Divergence —
#                                     an unrecorded gap, a recorded gap that closed, a lying Status, a
#                                     section no probe covers — BLOCKS the release, as does dropping
#                                     either file while the other remains. RECORDED drift passes: the
#                                     point is recording, not perfection. A tree with NO parity
#                                     machinery at all is a loud advisory (synthetic/legacy trees; a
#                                     real lineage's drop is caught HARD by manifest-existence-guard).
#
# ── DESIGN FOR EXTENSION ──────────────────────────────────────────────────────────────────────────────
#   Each check is a self-contained function that calls `record_pass`/`record_warn`/`record_fail` (which
#   print the [PASS]/[WARN]/[FAIL] line AND append to RESULTS). Register it by adding its name to CHECKS[].
#   That's the whole contract. Do not couple checks to each other; each reads only $REPO_ARG / $PREV /
#   $CANDIDATE (+ the shared, lazily-created worktree via `ensure_worktree`) and reports its own verdict.
#   A check's short name (for --only) is its function name minus `check_`, with `_` → `-`.
#
#   NEVER pipe into record_* — a pipe runs it in a subshell and the RESULTS+=() mutation is LOST there.
#   Build the message in a variable, then call record_* in the main shell.
#   `git grep` exits 1 on NO MATCH (= the CLEAN case). Never write `git grep … || record_fail`.
#
#   ROOT-ANCHOR EVERY PATHSPEC — `-- ':/…'`, never `-- .` / `-- plugin` / `-- README.md`.  A bare pathspec
#   is resolved against git's PREFIX (the CWD inside the repo), and REPO_ARG defaults to "." — so running
#   the gate from a subdirectory (`cd scripts && bash release-gate.sh …`) silently narrows every "whole
#   tree" scan and every "did plugin/ change" diff to that subdirectory. That is a FALSE GREEN in two HARD
#   checks: leak-scan-on-tree prints "candidate tree is clean" having scanned one directory, and
#   plugin-version-vs-content prints "no plugin/ content changed — invariant holds vacuously" while the
#   plugin really did change without a version bump (the exact core-v0.8 brick). `:/` is git's magic
#   "from the repo root" prefix and is prefix-independent — it makes the check say what it means.

set -uo pipefail   # NOT set -e — every check handles its own errors and reports a verdict, never aborts.

PLUGIN_DIR="plugin"
PLUGIN_JSON_PATH="plugin/.claude-plugin/plugin.json"
MANIFEST_PATH="scripts/core-manifest.txt"
CHANGELOG_PATH="CORE-CHANGELOG.md"
INSTALLER_PATH="install.sh"
LEFTHOOK_PATH="lefthook.yml"
GH_SLUG="vinceferro/kickoff"          # the public repo the canonical install URL points at

# Files that live in a core directory but deliberately DO NOT travel to adopters (maintainer/host tools,
# and the test suites). Structural, not identity — safe to hardcode. Used by manifest-covers-new-files.
MAINTAINER_ONLY=(
  "scripts/release-gate.sh"
  "scripts/install-auth-heal.sh"
  "install.sh"
)

REPO_ARG="."
CANDIDATE="HEAD"
PREV=""
VERSION=""                                    # --version; else derived from the changelog's top heading
SKIP_SUITES=0
SUITE_TIMEOUT="${RELEASE_GATE_SUITE_TIMEOUT:-300}"
LEAK_DENYLIST="${KICKOFF_LEAK_DENYLIST:-}"    # a file of identity literals; NEVER baked into this script
declare -a ONLY=()

usage() {
  cat <<'EOF'
usage: release-gate.sh --prev <prev-tag> [--candidate <git-ref>] [--repo <dir>] [options]
  --prev <ref>          REQUIRED. The previous release tag to compare against (e.g. core-v0.8.1).
  --candidate <ref>     The release-candidate ref to gate. Default: HEAD.
  --repo <dir>          The git checkout to operate on. Default: the current directory.
  --version <core-vX.Y> The version being cut. Default: the topmost `## core-vX.Y` changelog heading.
  --only <check>        Run ONLY this check (repeatable). Prints a PARTIAL banner — NOT a release pass.
  --skip-suites         Do not run the suites (prints an UNMISSABLE advisory). Default: run them.
  --suite-timeout <s>   Per-suite timeout in seconds. Default: 300.
  --leak-denylist <f>   File of identity literals (one per line) the tree must NOT contain.
                        Default: <repo>/.kickoff/leak-denylist.txt  (or $KICKOFF_LEAK_DENYLIST).
  -h, --help            Show this help.

Severity: [FAIL] = HARD (leaks / spends / bricks an adopter) — blocks. [WARN] = ADVISORY — never blocks.
Exit 0 iff ZERO hard failures.
EOF
}

# ── arg parse (fail-loud on a missing value via set -u's ${2:?…}) ─────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --candidate)      CANDIDATE="${2:?--candidate needs a value}"; shift 2 ;;
    --candidate=*)    CANDIDATE="${1#*=}"; shift ;;
    --prev)           PREV="${2:?--prev needs a value}"; shift 2 ;;
    --prev=*)         PREV="${1#*=}"; shift ;;
    --repo|-C)        REPO_ARG="${2:?--repo needs a value}"; shift 2 ;;
    --repo=*)         REPO_ARG="${1#*=}"; shift ;;
    --version)        VERSION="${2:?--version needs a value}"; shift 2 ;;
    --version=*)      VERSION="${1#*=}"; shift ;;
    --only)           ONLY+=("${2:?--only needs a check name}"); shift 2 ;;
    --only=*)         ONLY+=("${1#*=}"); shift ;;
    --skip-suites)    SKIP_SUITES=1; shift ;;
    --suite-timeout)  SUITE_TIMEOUT="${2:?--suite-timeout needs a value}"; shift 2 ;;
    --suite-timeout=*) SUITE_TIMEOUT="${1#*=}"; shift ;;
    --leak-denylist)  LEAK_DENYLIST="${2:?--leak-denylist needs a value}"; shift 2 ;;
    --leak-denylist=*) LEAK_DENYLIST="${1#*=}"; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) printf 'release-gate: unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$PREV" ] || { printf 'release-gate: --prev <prev-tag> is required\n\n' >&2; usage >&2; exit 2; }

# ── check-runner plumbing ─────────────────────────────────────────────────────────────────────────────
declare -a RESULTS=()
record_pass() { RESULTS+=("PASS"); printf '[PASS] %s\n' "$1"; }
record_fail() { RESULTS+=("FAIL"); printf '[FAIL] %s\n' "$1"; }
record_warn() { RESULTS+=("WARN"); printf '[WARN] %s\n' "$1"; }   # ADVISORY: loud + counted, never blocks

g() { git -C "$REPO_ARG" "$@"; }   # every git call targets the checkout under test

# ── the shared candidate worktree (the one expensive resource; leak-scan + suites both need a real tree
#    on disk — scan-secrets.sh and every suite are CWD-bound and take no git ref). Created lazily, ONCE,
#    OUTSIDE the repo; removed + pruned by the EXIT trap even on ^C. Never `git archive`: 17 suites read
#    `git show HEAD:…` for their RED-on-old lane and FALSE-RED in a tree with no .git. ────────────────
WT=""; WT_BASE=""
cleanup_worktree() {
  [ -n "$WT" ] || return 0
  local wt="$WT" base="$WT_BASE"
  WT=""; WT_BASE=""                        # idempotent: a second EXIT/INT pass is a no-op
  g worktree remove --force "$wt" >/dev/null 2>&1
  # ORDER MATTERS: delete the DIRECTORY, *then* prune. `prune` only drops an admin entry whose working
  # dir is already gone — so pruning before the rm leaves a stale .git/worktrees/<n> entry behind
  # whenever `remove` fails for any reason. This way the rm+prune pair is a guaranteed backstop.
  [ -n "$base" ] && rm -rf "$base"
  g worktree prune >/dev/null 2>&1
}
trap cleanup_worktree EXIT INT TERM

ensure_worktree() {   # rc 0 → $WT is a detached checkout of $CANDIDATE
  [ -n "$WT" ] && return 0
  local base; base="$(mktemp -d)" || return 1
  g worktree prune >/dev/null 2>&1
  # Publish the cleanup handles BEFORE `worktree add`, not after. cleanup_worktree keys on WT/WT_BASE; a
  # signal (INT/TERM) landing in the window between a SUCCEEDING `add` and the old post-hoc `WT=`/`WT_BASE=`
  # assignment used to leave cleanup with an empty $WT → it early-returned → the just-added worktree +
  # its /tmp base leaked into the live engine repo. Setting them first means a mid-add signal still reaps
  # both by exact path (`remove --force $wt` is a harmless no-op if the entry does not exist yet).
  WT_BASE="$base"; WT="$base/wt"
  if ! g worktree add -q --detach "$base/wt" "$CANDIDATE" >/dev/null 2>&1; then
    WT=""; WT_BASE=""                        # add failed → reset so a later trap pass is a clean no-op
    rm -rf "$base"; g worktree prune >/dev/null 2>&1; return 1
  fi
  return 0
}

# echoes the plugin.json `version` value at $1 (a git ref); non-zero if the file/version is unreadable.
plugin_version_at() {
  local ref="$1" content ver
  content="$(g cat-file -p "${ref}:${PLUGIN_JSON_PATH}" 2>/dev/null)" || return 1
  [ -n "$content" ] || return 1
  ver="$(printf '%s\n' "$content" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  [ -n "$ver" ] || return 1
  printf '%s' "$ver"
}

# echoes the topmost `## core-vX.Y` heading's VERSION at $1 (a git ref); non-zero if unreadable/absent.
# This is the ONLY in-tree source of the CORE version (there is no VERSION file; plugin.json's "version"
# is the PLUGIN version, a different number).
changelog_version_at() {
  local ref="$1" body v
  # Two statements on purpose: `v="$(… | sed | head -n1)" || return 1` would inherit head's SIGPIPE kill
  # of sed under `pipefail` (rc 141) and false-fire (memory/pipefail-sigpipe-grep-flake.md). Test the
  # VALUE, never a head-terminated pipeline's rc.
  body="$(g cat-file -p "${ref}:${CHANGELOG_PATH}" 2>/dev/null)" || return 1
  v="$(printf '%s\n' "$body" | sed -n 's/^##[[:space:]]*\(core-v[0-9][0-9A-Za-z.]*\).*/\1/p' | head -n1)"
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

# reads the manifest at $1 (a git ref) → one path per line on stdout (CR-stripped, blanks/# skipped),
# mirroring cmd_pull's own parse. Non-zero if the manifest is unreadable.
manifest_paths_at() {
  local ref="$1" raw
  raw="$(g cat-file -p "${ref}:${MANIFEST_PATH}" 2>/dev/null)" || return 1
  # `|| true`: an all-comments manifest makes grep exit 1, which must NOT be reported as "no manifest"
  # (an EMPTY manifest and an ABSENT one are different pull deaths — say which one you actually saw).
  printf '%s\n' "$raw" | sed 's/\r$//' | grep -vE '^[[:space:]]*(#|$)' || true
  return 0
}

# ── CHECK: plugin-version-vs-content ──────────────────────────────────────────────────────────────────
check_plugin_version_vs_content() {
  local n="plugin-version-vs-content"

  # Refs must resolve (fail loud — a mistyped/missing prev tag is a release-blocker, not a pass).
  g rev-parse -q --verify "${PREV}^{commit}"      >/dev/null 2>&1 \
    || { record_fail "$n: prev ref '$PREV' does not resolve to a commit — pass a real previous release tag via --prev"; return; }
  g rev-parse -q --verify "${CANDIDATE}^{commit}" >/dev/null 2>&1 \
    || { record_fail "$n: candidate ref '$CANDIDATE' does not resolve to a commit"; return; }

  # plugin.json must exist on BOTH sides — its absence means the version can't gate anything (fail loud).
  g cat-file -e "${PREV}:${PLUGIN_JSON_PATH}" 2>/dev/null \
    || { record_fail "$n: $PLUGIN_JSON_PATH is absent at prev ref '$PREV' — cannot gate the plugin version"; return; }
  g cat-file -e "${CANDIDATE}:${PLUGIN_JSON_PATH}" 2>/dev/null \
    || { record_fail "$n: $PLUGIN_JSON_PATH is absent at candidate ref '$CANDIDATE' — cannot gate the plugin version"; return; }

  # Did ANY plugin/ tree content change — plugin.json INCLUDED? --quiet: rc 0 = no diff, 1 = diff.
  # rtk-safe (exit-status, never `git diff | grep`). plugin.json is deliberately NOT excluded: a
  # commands/hooks/agents/description edit to plugin.json with NO version bump bricks every
  # adopter-with-an-interactive-plugin at preflight #8's byte-verify — the exact class this check exists
  # to catch, at the file most likely edited without bumping. (A version-only bump also lands here and
  # PASSES via the version-changed branch below — so this stays correct for the legitimate case too.)
  # `:/` — root-anchored, NOT `-- "$PLUGIN_DIR"`: a bare pathspec resolves against the CWD, so from a
  # subdirectory this diff sees nothing, reports "no plugin/ content changed", and GREEN-LIGHTS the brick.
  local content_changed=0
  g diff --quiet "$PREV" "$CANDIDATE" -- ":/$PLUGIN_DIR" || content_changed=1

  # Version strings on both sides (parsed from cat-file — not from a truncation-prone diff|grep).
  local prev_ver cand_ver
  prev_ver="$(plugin_version_at "$PREV")"      || { record_fail "$n: could not parse a version from $PLUGIN_JSON_PATH at prev '$PREV'";      return; }
  cand_ver="$(plugin_version_at "$CANDIDATE")"  || { record_fail "$n: could not parse a version from $PLUGIN_JSON_PATH at candidate '$CANDIDATE'"; return; }

  if [ "$content_changed" -eq 0 ]; then
    record_pass "$n: no plugin/ content changed vs $PREV (version $cand_ver) — invariant holds vacuously"
    return
  fi
  if [ "$prev_ver" != "$cand_ver" ]; then
    record_pass "$n: plugin/ content changed AND plugin.json version bumped ($prev_ver → $cand_ver)"
    return
  fi

  # content changed, version did NOT bump → THE BUG. Name the offending files + the remedy.
  # Build the whole multi-line message in a variable, then call record_fail DIRECTLY — never pipe into
  # record_fail (a pipe runs it in a subshell, and the RESULTS+=("FAIL") mutation would be lost there).
  local changed msg
  changed="$(g diff --name-only "$PREV" "$CANDIDATE" -- ":/$PLUGIN_DIR" | sed 's/^/         - /')"
  msg="$n: plugin/ content changed vs $PREV but plugin.json version stayed $cand_ver.
       BUMP plugin/.claude-plugin/plugin.json \"version\" (a patch bump is fine, e.g. $cand_ver → next).
       Otherwise every adopter's \`kickoff pull\` fails closed at preflight #8 (the plugin-cache
       re-sync no-ops on an unchanged version). Changed plugin files:
$changed"
  record_fail "$msg"
}

# ── CHECK: manifest-existence-guard (HARD — a missing core file makes the release UNTAKEABLE) ─────────
check_manifest_existence_guard() {
  local n="manifest-existence-guard"

  local paths
  paths="$(manifest_paths_at "$CANDIDATE")" || {
    record_fail "$n: $MANIFEST_PATH is ABSENT at candidate '$CANDIDATE' — \`kickoff pull\` dies
       (\"no core-manifest.txt found\") and NO adopter can take this release."
    return
  }
  [ -n "$paths" ] || {
    record_fail "$n: $MANIFEST_PATH at '$CANDIDATE' lists NO core files — \`kickoff pull\` dies
       (\"manifest lists no core files\"). Every adopter is blocked."
    return
  }

  # cmd_pull step 4's EXISTENCE GUARD, replayed at release time: every listed path must be present in the
  # tag's tree (git cat-file -e resolves blobs AND trees, so directory entries like plugin/skills work).
  local p total=0 missing=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    total=$((total + 1))
    g cat-file -e "${CANDIDATE}:${p}" 2>/dev/null || missing="${missing}
         - ${p}"
  done <<< "$paths"

  if [ -n "$missing" ]; then
    record_fail "$n: the manifest lists file(s) MISSING from the candidate tree '$CANDIDATE'.
       \`kickoff pull\` DIEs at step 4 (\"refusing to pin a partial core\") BEFORE core.lock is written —
       fail-closed, but EVERY adopter is blocked from taking this release entirely. Missing:${missing}
       FIX: add the file back, or drop its line from $MANIFEST_PATH."
    return
  fi
  record_pass "$n: all $total manifest entries exist in the candidate tree ($CANDIDATE) — cmd_pull's step-4 existence guard would pass"
}

# ── CHECK: manifest-covers-new-files (ADVISORY — it still travels under the whole-tree pin) ───────────
check_manifest_covers_new_files() {
  local n="manifest-covers-new-files"

  local paths
  paths="$(manifest_paths_at "$CANDIDATE")" || {
    record_warn "$n: no readable $MANIFEST_PATH at '$CANDIDATE' — coverage not assessed (the HARD manifest-existence-guard owns that failure)"
    return
  }

  # The manifest's "core directories": the dirname of every listed FILE. A new file is only interesting
  # if it lands in a directory the manifest already speaks for (this is what keeps the advisory quiet —
  # docs/ and mission-control/experiments/ hold no manifest entries, so they never fire).
  local -a core_dirs=() entries=()
  local p d
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    entries+=("$p")
    d="$(dirname "$p")"
    case " ${core_dirs[*]-} " in *" $d "*) ;; *) core_dirs+=("$d") ;; esac
  done <<< "$paths"

  local added f uncovered="" count=0
  added="$(g diff --name-only --diff-filter=A "$PREV" "$CANDIDATE" 2>/dev/null)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in *-selftest.sh|*-selftest.mjs) continue ;; esac     # test suites never travel (any runner)
    local skip=0 m
    for m in "${MAINTAINER_ONLY[@]}"; do [ "$f" = "$m" ] && skip=1; done
    [ "$skip" -eq 1 ] && continue
    d="$(dirname "$f")"
    case " ${core_dirs[*]-} " in *" $d "*) ;; *) continue ;; esac    # not in a core directory → not ours
    # covered? exact match, or under a directory entry (e.g. plugin/skills covers plugin/skills/x/SKILL.md)
    local covered=0 e
    for e in ${entries[@]+"${entries[@]}"}; do
      [ "$f" = "$e" ] && { covered=1; break; }
      case "$f" in "$e"/*) covered=1; break ;; esac
    done
    [ "$covered" -eq 1 ] && continue
    count=$((count + 1))
    uncovered="${uncovered}
         - ${f}"
  done <<< "$added"

  if [ "$count" -gt 0 ]; then
    record_warn "$n: ADVISORY — $count new file(s) live in a manifest-covered directory but are NOT listed in $MANIFEST_PATH:${uncovered}
       They STILL TRAVEL (core.lock format 2 pins the WHOLE tag tree), so this does not brick a pull —
       but they lose the step-4 existence guard, per-file pinning for legacy per-file-lock adopters, and
       the documented core contract. If a file is core → add it to the manifest. If it is maintainer-only
       (a host tool, a test) → ignore this line, or add it to MAINTAINER_ONLY in this gate."
    return
  fi
  record_pass "$n: every new file (vs $PREV) in a manifest-covered directory is manifest-listed"
}

# ── CHECK: changelog-top-section (ADVISORY — mirrors cmd_pull's own advisory changelog step) ──────────
check_changelog_top_section() {
  local n="changelog-top-section"

  local body
  body="$(g cat-file -p "${CANDIDATE}:${CHANGELOG_PATH}" 2>/dev/null)" || {
    record_warn "$n: ADVISORY — no $CHANGELOG_PATH at candidate '$CANDIDATE'. Adopters read the changelog
       delta on every \`kickoff pull\` (an advisory step there too) — they would pull blind."
    return
  }

  local ver
  ver="$(printf '%s\n' "$body" | sed -n 's/^##[[:space:]]*\(core-v[0-9][0-9A-Za-z.]*\).*/\1/p' | head -n1)"
  if [ -z "$ver" ]; then
    record_warn "$n: ADVISORY — $CHANGELOG_PATH has no \`## core-vX.Y\` heading at all. Add the section for
       the version you are cutting; adopters pull blind without it."
    return
  fi

  # Section body = the lines after the topmost heading, up to the next `## `. NON-EMPTINESS is the check.
  # We deliberately DO NOT check the date: every real tag ships its own heading as "— unreleased" (the
  # date is backfilled in a later dev commit), so a date check would false-RED 100% of historical releases.
  local content
  content="$(printf '%s\n' "$body" | awk '/^## /{ if (seen) exit; seen=1; next } seen' | grep -cvE '^[[:space:]]*$')"
  local heading
  heading="$(printf '%s\n' "$body" | grep -m1 '^## ')"

  if [ "${content:-0}" -eq 0 ]; then
    record_warn "$n: ADVISORY — the topmost section \"$heading\" is EMPTY. Write what changed; adopters
       read exactly this delta on \`kickoff pull\`."
    return
  fi

  if [ -n "$VERSION" ] && [ "$VERSION" != "$ver" ]; then
    record_warn "$n: ADVISORY — you are cutting '$VERSION' but the topmost changelog heading is '$ver'
       (\"$heading\"). Adopters would pull $VERSION and read $ver's notes. Add/rename the section."
    return
  fi

  local delta
  delta="$(g diff --name-only "$PREV" "$CANDIDATE" 2>/dev/null | grep -c .)"
  record_pass "$n: topmost section \"$heading\" is present and non-empty ($content lines) for $ver — covering ${delta:-0} changed file(s) since $PREV
       (date NOT checked on purpose: every real tag ships its heading as \"— unreleased\"; the date is backfilled after tagging)"
}

# ── CHECK: installer-url-parity (ADVISORY — breaks the FRONT DOOR for a stranger, not an adopter) ─────
check_installer_url_parity() {
  local n="installer-url-parity"

  local want="$VERSION"
  if [ -z "$want" ]; then
    want="$(changelog_version_at "$CANDIDATE")" || {
      record_warn "$n: ADVISORY — cannot determine the candidate's core version (no --version, and no
       \`## core-vX.Y\` heading in $CHANGELOG_PATH at '$CANDIDATE') — URL parity not assessed."
      return
    }
  fi

  # Every canonical, TAG-PINNED installer URL in the tree. `/main/` is the deliberate moving alias
  # (README labels it as such) — we do not treat it as a version site.
  local hits
  hits="$(g grep -In -E -e "raw\.githubusercontent\.com/${GH_SLUG}/core-v[0-9][0-9A-Za-z.]*/install\.sh" \
            "$CANDIDATE" -- ":/README.md" ":/QUICKSTART.md" ":/$INSTALLER_PATH" 2>/dev/null)"

  local sha=""
  sha="$(g cat-file -p "${CANDIDATE}:${INSTALLER_PATH}" 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1)"

  local post_tag="POST-TAG ONLY (nothing offline can prove these — the tag does not exist on the remote yet,
       and NO sha is recorded in the tree; README/QUICKSTART carry the literal <published-sha> placeholder):
         · that https://raw.githubusercontent.com/${GH_SLUG}/${want}/install.sh resolves 200
         · that it is byte-identical to the tagged install.sh
       AFTER pushing the tag:  curl -fsSL https://raw.githubusercontent.com/${GH_SLUG}/${want}/install.sh | sha256sum
       RELEASE ARTIFACT — install.sh SHA-256 at ${CANDIDATE} (paste into the GitHub release notes):
         ${sha:-<unreadable>}  install.sh"

  if [ -z "$hits" ]; then
    record_warn "$n: ADVISORY — no tag-pinned install.sh URL found in README.md / QUICKSTART.md / $INSTALLER_PATH
       at '$CANDIDATE'. The canonical one-liner must be TAG-PINNED (\`/${want}/install.sh\`); \`/main/\` is
       only the labelled moving alias. A stranger's \`curl … | sh\` is the front door.
       $post_tag"
    return
  fi

  # A stale doc URL naming a version that will never exist ⇒ the one-liner 404s ⇒ no stranger can install.
  local line ref bad="" nsites=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    nsites=$((nsites + 1))
    ref="$(printf '%s' "$line" | sed -n "s#.*kickoff/\(core-v[0-9][0-9A-Za-z.]*\)/install\.sh.*#\1#p" | head -n1)"
    [ "$ref" = "$want" ] && continue
    bad="${bad}
         - ${line#${CANDIDATE}:}
           names ${ref:-?}, expected ${want}"
  done <<< "$hits"

  # A hardcoded 64-hex where the <published-sha> placeholder belongs is a STALE sha nobody can have checked.
  local baked
  baked="$(g grep -In -E -e 'sha256sum -c .*[0-9a-f]{64}' "$CANDIDATE" -- ":/README.md" ":/QUICKSTART.md" 2>/dev/null)"
  if [ -n "$baked" ]; then
    bad="${bad}
         - a literal 64-hex SHA is baked into the verify line (expected the <published-sha> placeholder —
           the real SHA lives in the GitHub release notes, authored AFTER the tag):
$(printf '%s\n' "$baked" | sed 's/^/           /')"
  fi

  if [ -n "$bad" ]; then
    record_warn "$n: ADVISORY — installer URL/SHA parity is OFF for ${want}:${bad}
       Every canonical install.sh URL (README.md · QUICKSTART.md · $INSTALLER_PATH's own header comment)
       must name ${want}. A version that never gets tagged ⇒ the \`curl … | sh\` one-liner 404s ⇒ NO
       stranger can install (a broken front door). It does NOT brick an existing adopter — they upgrade
       via \`kickoff pull\` (never reads README) and install.sh resolves the latest STABLE core-v* tag
       dynamically — which is why this is ADVISORY, not HARD.
       $post_tag"
    return
  fi

  record_pass "$n: all $nsites canonical install.sh URL(s) name $want (README.md · QUICKSTART.md · $INSTALLER_PATH); the <published-sha> placeholder is intact
       $post_tag"
}

# ── CHECK: leak-scan-on-tree (HARD — a public tag is irreversible; you cannot unpublish it) ───────────
check_leak_scan_on_tree() {
  local n="leak-scan-on-tree"

  # The identity denylist (private orgs, third-party adopter names, credential-file paths) is DATA, held
  # OUT OF TREE on purpose: this repo is PUBLIC, and a guard that embeds identity literals IS the leak
  # (memory/public-phrasing-lives-in-shipped-files.md). FAIL-CLOSED when it is absent — an empty default
  # would silently green-light exactly the release class this check exists to stop.
  local deny="$LEAK_DENYLIST"
  [ -n "$deny" ] || deny="$REPO_ARG/.kickoff/leak-denylist.txt"
  if [ ! -f "$deny" ]; then
    record_fail "$n: NO identity denylist configured — refusing to certify this tree as leak-free (fail-closed).
       This gate ships ZERO identity literals on purpose (the repo is public; a denylist baked into a
       shipped file IS the leak). Provide the data out-of-tree — .kickoff/ is gitignored:
         printf '%s\\n' 'private-github-org' 'third-party-adopter' > $REPO_ARG/.kickoff/leak-denylist.txt
       (one literal per line, # comments allowed; or pass --leak-denylist <file> / \$KICKOFF_LEAK_DENYLIST).
       Do NOT list the operator's own product name — it is deliberately public in the shipped decks/docs."
    return
  fi

  local findings="" nterms=0

  # 1. STRUCTURAL forms that must NEVER appear in a shipped tree. Written so the patterns do not match
  #    THEMSELVES (the char class follows the fixed prefix directly), because this file is in the tree too.
  #    The hyphen form is the one a literal `home/<user>` grep is blind to — it cost a real near-miss.
  local -a struct=(
    '-home-[a-z0-9_]+-'          # scratchpad encoding of /home/<user>/… (dir-name form)
    '/tmp/claude-[0-9]+'         # the agent scratchpad root
    '/Users/[a-z_][a-z0-9_.-]{2,}/'   # a macOS machine home
    '/home/[a-z_][a-z0-9_.-]{2,}/'    # a Linux machine home for ANY user — see below
  )
  # The Linux-home pattern is GENERIC on purpose. The env-derived `home[/.-]$tok` patterns below only know
  # the RUNNER's own username, so before this line a shipped doc naming a THIRD PARTY's machine or
  # credential file (a CI box, a client's home, another engineer's path) scanned CLEAN — and so did the
  # operator's own `/home/<them>/…` whenever the release was cut by a different user or as root (root is
  # skipped below). scan-secrets.sh does not backstop it: it hunts key/token VALUES, not credential PATHS —
  # and a credential-file path is exactly what v0.5's whole-tree scan caught. A public tag is irreversible,
  # so this fails CLOSED: if a hit is a deliberate placeholder in a doc, write it as `~/…` or `/home/<user>/`
  # (angle-bracket form), which this pattern does not match — do not weaken the pattern.

  # 2. MACHINE IDENTITY, derived from the environment at run time — never hardcoded. `home[/.-]<user>`
  #    catches BOTH /home/<user>/… and the -home-<user>- hyphen form in one pattern (the literal
  #    `home/<user>` grep that was blind to the hyphen form is exactly the near-miss of core-v0.3 —
  #    memory/leak-guard-must-catch-variant-encodings-of-machine-paths.md).
  local tok t2 dup
  local -a toks=()
  for tok in "${USER:-}" "$(id -un 2>/dev/null)" "$(basename "${HOME:-/}" 2>/dev/null)"; do
    case "$tok" in
      ''|/|root) continue ;;
      ???*) ;;                    # ≥3 chars — a 1-2 char name would false-fire on doc placeholders
      *) continue ;;
    esac
    dup=0
    for t2 in ${toks[@]+"${toks[@]}"}; do [ "$t2" = "$tok" ] && dup=1; done
    [ "$dup" -eq 1 ] && continue     # plain string dedup — a `case` glob would read [/.-] as a char class
    toks+=("$tok")
    struct+=("home[/.-]$tok")
  done

  # 2b. MACHINE NAME — the same identity axis as 2, a DIFFERENT encoding, and it was uncovered until now.
  #     Every pattern above is anchored on the literal `home`, so the guard could only see a machine through
  #     a home PATH. A hostname leaks in shapes that never touch `home`: bare in prose, in a MagicDNS URL
  #     (`<host>.<tailnet>.ts.net`), after an `@` in an ssh target, inside a service path. FOUND ON THE REAL
  #     TREE, not hypothesised: TRACKER-ARCHIVE.md on the dev branch carries this box's hostname in prose and
  #     this check certified that tree clean. Same shape as the core-v0.3 hyphen-form near-miss — an identity
  #     axis the guard had a NAME for and no PATTERN for.
  #
  #     Derived at run time, never hardcoded (this file ships inside the very tag it scans). Sources are all
  #     LOCAL — `hostname -f` is deliberately NOT used: it consults the resolver, and a release gate must not
  #     be able to hang on DNS. Nothing is lost by that, because the short name matches inside the FQDN: `.`
  #     is deliberately OUTSIDE the boundary class, so `<host>.tailnet.ts.net` still fires on `<host>`.
  #
  #     WHOLE-TOKEN, not substring. A bare substring would fire inside an ordinary word for any host whose
  #     name is also a common string, and a guard that cries wolf is a guard that gets bypassed. `localhost`
  #     is skipped because it identifies no machine and appears in ordinary docs — that is a no-op skip, not
  #     a coverage hole. There is NO env override on purpose: an override is a bypass, and this axis exists
  #     because the leak we already had was one nobody was looking for.
  #
  #     Deduped against its OWN list, never against $toks: if the hostname equals the username the two still
  #     need BOTH patterns, because `home[/.-]<user>` does not match the bare form. Sharing the dedup list
  #     would silently delete this axis on exactly the boxes where the names coincide.
  local hn esc hcov="" hdup
  local -a htoks=()
  for hn in "$(hostname 2>/dev/null)" "${HOSTNAME:-}" "$(cat /etc/hostname 2>/dev/null)"; do
    hn="${hn%%$'\n'*}"; hn="${hn%$'\r'}"
    case "$hn" in
      ''|localhost|localhost.*) continue ;;
      ???*) ;;                    # ≥3 chars — the same rule the user tokens get, for the same reason
      *) continue ;;
    esac
    hdup=0
    for t2 in ${htoks[@]+"${htoks[@]}"}; do [ "$t2" = "$hn" ] && hdup=1; done
    [ "$hdup" -eq 1 ] && continue
    htoks+=("$hn")
    esc="$(printf '%s' "$hn" | sed 's/[.[\*^$+?(){}|\\]/\\&/g')"   # a hostname may carry regex metachars
    struct+=("(^|[^a-z0-9])${esc}([^a-z0-9]|\$)")
    hcov="${hcov}${hcov:+,}${hn}"
  done
  # No silent coverage drop: if no usable machine name exists, the result line SAYS the axis is uncovered.
  local hnote="covered ($hcov)"
  [ -n "$hcov" ] || hnote="NOT COVERED — no usable machine name (empty, localhost, or under 3 chars)"

  local pat hit ambient_pre=""
  for pat in "${struct[@]}"; do
    # `-- ':/'` = the WHOLE tree from the repo ROOT. `-- .` resolved against the CWD, so `cd scripts &&
    # release-gate.sh …` scanned ONLY scripts/ and still printed "candidate tree … is clean" (false GREEN).
    hit="$(g grep -I -i -n -E -e "$pat" "$CANDIDATE" -- ':/' 2>/dev/null)"   # rc 1 = NO match = CLEAN
    [ -n "$hit" ] || continue
    # ── AMBIENT PATTERNS ARE A GUESS, AND A GUESS MUST NOT HARD-BLOCK ON A WORD IT DID NOT CAUSE ──
    # Every pattern in $struct is derived from THIS BOX's username and hostname. That is ambient
    # identity, not an operator claim, and it collides with ordinary English. Cost, 2026-08-27: a
    # second machine whose hostname is `alarm` (5 chars — it clears the >=3 guard) turned every
    # occurrence of that word into a HARD leak finding. core-v0.8.1 carries it in 19 files of plain
    # prose ("escalation alarm", "re-alarm"), so release-gate-selftest went 60/7 RED there and GREEN
    # here on byte-identical code, and — because that suite is a registered pre-push gate — it
    # blocked EVERY push from that machine. Reproduced on this box with HOSTNAME=alarm: same tree,
    # same denylist, hostname the only variable, GREEN -> RED.
    #
    # The discriminator is INTRODUCTION, not presence. If the PREVIOUS released tag already carries
    # the pattern, this candidate did not leak it — the word was public before this box existed, and
    # tagging cannot make it more public. Say so loudly as an ADVISORY and keep going.
    # The operator-authored denylist below stays HARD in every case: an explicit term is a claim.
    # With no --prev there is nothing to compare against, so the old HARD behaviour stands.
    if [ -n "$PREV" ] && g grep -I -i -q -E -e "$pat" "$PREV" -- ':/' 2>/dev/null; then
      ambient_pre="${ambient_pre}${ambient_pre:+, }/$pat/"
      continue
    fi
    findings="${findings}
       ── pattern /$pat/
$(printf '%s\n' "$hit" | head -n 8 | cut -c1-160 | sed 's/^/         /')"
  done

  if [ -n "$ambient_pre" ]; then
    record_warn "$n: ambient identity pattern(s) $ambient_pre match the candidate — but they ALSO match
       the previous tag '$PREV', so this candidate did not introduce them. This is almost always this
       box's own hostname or username colliding with an ordinary word (host '$(hostname 2>/dev/null)').
       ADVISORY, not a block. If it really is a leak, it leaked before '$PREV' and needs a scrub of the
       published history, not a gate failure here. To assert it deliberately, add the literal to the
       identity denylist — an explicit term always blocks."
  fi

  # 3. The out-of-tree identity denylist (fixed strings, case-insensitive).
  #    `|| [ -n "$term" ]` — WITHOUT it, `read` returns 1 on a final line that has no trailing newline and
  #    the loop exits BEFORE processing it, so the LAST term is silently never scanned. The documented way
  #    to add a term is `printf … >> <denylist>`, and an editor that omits the final newline is ordinary —
  #    so the guard would go blind to exactly the identity literal just added, and still certify the tree
  #    clean. This check fails CLOSED on an absent denylist; it must not fail OPEN on a truncated one.
  local term
  while IFS= read -r term || [ -n "$term" ]; do
    term="${term%$'\r'}"
    case "$term" in ''|'#'*) continue ;; esac
    nterms=$((nterms + 1))
    hit="$(g grep -I -i -n -F -e "$term" "$CANDIDATE" -- ':/' 2>/dev/null)"
    [ -n "$hit" ] || continue
    findings="${findings}
       ── denylisted term (from $(basename "$deny"))
$(printf '%s\n' "$hit" | head -n 8 | cut -c1-160 | sed 's/^/         /')"
  done < "$deny"

  # 4. scan-secrets.sh, run ON THE CANDIDATE TREE (it is CWD-bound: `git ls-files` + the tree's own
  #    .scanignore — it takes no git ref, so a real checkout is required). Exit 1 on ANY finding.
  local sec_rc=0 sec_out="" sec_note=""
  if ensure_worktree; then
    if [ -f "$WT/scripts/scan-secrets.sh" ]; then
      sec_out="$( cd "$WT" && bash scripts/scan-secrets.sh 2>&1 )" || sec_rc=$?
      sec_note="scan-secrets.sh: rc=$sec_rc"
      if [ "$sec_rc" -ne 0 ]; then
        findings="${findings}
       ── scan-secrets.sh (rc=$sec_rc) on the candidate tree
$(printf '%s\n' "$sec_out" | tail -n 20 | sed 's/^/         /')"
      fi
    else
      # HARD, not a banked green: scripts/scan-secrets.sh is a CORE file (it ships in core-manifest.txt).
      # Its absence means the release tree DROPPED the primary secret scanner — and the remaining
      # structural/identity/denylist patterns do NOT detect API keys, tokens, or high-entropy secrets, so
      # a candidate carrying a real secret would be certified clean. A missing scanner is itself a release
      # defect: fail closed. (An absent scanner that ALSO gets dropped from the manifest is invisible to
      # manifest-existence-guard, so THIS check must own it — a public tag is irreversible.)
      sec_note="scan-secrets.sh: ABSENT — HARD"
      findings="${findings}
       ── the primary secret scanner scripts/scan-secrets.sh is ABSENT from the candidate tree
         It is a CORE file (core-manifest.txt). Without it, this HARD leak check rests only on the
         structural/identity patterns — which do NOT catch keys/tokens/high-entropy secrets — so a real
         secret would pass unseen. Restore scripts/scan-secrets.sh before cutting the tag."
    fi
  else
    findings="${findings}
       ── could not create a worktree of '$CANDIDATE' — scan-secrets.sh could NOT be run on the real tree"
    sec_note="scan-secrets.sh: NOT RUN (no worktree)"
  fi

  if [ -n "$findings" ]; then
    record_fail "$n: LEAK(S) in the candidate tree '$CANDIDATE'. A public tag is IRREVERSIBLE — you cannot
       unpublish it. Scrub the tree and re-cut the release commit BEFORE tagging.${findings}
       (whole-tree scan, not the delta — a delta scan is blind to files inherited from an earlier tag)"
    return
  fi
  record_pass "$n: candidate tree '$CANDIDATE' is clean — ${#struct[@]} structural/identity patterns + $nterms denylisted term(s); hostname: $hnote; $sec_note"
}

# ── CHECK: parity-ledger (HARD — engine drift the ledger does not record ships a silent fork) ────
# The chartered principle: the engine is abstracted; it must work equally well on every supported
# engine, and where a gap exists it is RECORDED (docs/PARITY.md) — never silent. scripts/parity-report.sh
# is that principle's mechanism: it probes each engine's wiring on the CANDIDATE TREE and compares the
# findings to the ledger. Divergence (a gap nobody recorded, a recorded gap that closed, a Status that
# lies, a section nothing can verify) exits non-zero and BLOCKS the release — while RECORDED drift
# passes, because the point is recording, not perfection. Runs on the shared candidate worktree like
# the other CWD-bound scans (the probes read $ROOT-relative paths; a detached checkout of $CANDIDATE
# is the only honest thing to probe — the dirty working tree proves nothing about the tag).
check_parity_ledger() {
  local n="parity-ledger"

  # The worktree comes FIRST — the existence checks below read $WT, and before ensure_worktree
  # runs, $WT is empty (a check that would fail on every release for the wrong reason).
  ensure_worktree || {
    record_fail "$n: could not create a worktree of '$CANDIDATE' — parity must be probed on the exact
       candidate tree, not the working tree."
    return
  }

  # Severity by shape. WHOLLY absent (no report AND no ledger) = a synthetic or pre-parity tree:
  # there is nothing to cross-check, and the drop case for a REAL release lineage is already a
  # HARD manifest-existence-guard failure (both files are listed in core-manifest.txt) — so this
  # shape is a loud ADVISORY, not a block (mirrors the ambient-identity reasoning: do not
  # hard-block on a tree class the machinery was never part of). HALF-present is the opposite:
  # a report without a ledger means drift would ship UNRECORDED; a ledger without a report means
  # the enforcement was dropped while the record stayed — both are HARD.
  if [ ! -f "$WT/scripts/parity-report.sh" ] && [ ! -f "$WT/docs/PARITY.md" ]; then
    record_warn "$n: ADVISORY — the candidate tree carries NO engine-parity machinery (no
       scripts/parity-report.sh, no docs/PARITY.md). Nothing was cross-checked: drift on this tree
       would ship unrecorded. If this is a real release lineage, that is a defect — restore both
       (they are CORE files); the manifest-existence-guard would also have failed on the drop."
    return
  fi
  if [ ! -f "$WT/scripts/parity-report.sh" ]; then
    record_fail "$n: scripts/parity-report.sh is ABSENT from the candidate tree while docs/PARITY.md
       remains — the ledger ships with its enforcement dropped, so nothing re-checks the record.
       Restore the probe (it is a CORE file) before tagging."
    return
  fi
  if [ ! -f "$WT/docs/PARITY.md" ]; then
    record_fail "$n: docs/PARITY.md is ABSENT from the candidate tree while scripts/parity-report.sh
       remains — drift would ship UNRECORDED. Restore the ledger (it is a CORE file) before tagging."
    return
  fi

  local rc=0 out
  out="$(bash "$WT/scripts/parity-report.sh" --root "$WT" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    record_fail "$n: UNRECORDED engine drift (or ledger rot) on the candidate tree — parity-report rc=$rc.
       A capability the ledger does not correctly record is a silent fork for every opencode (or claude)
       adopter. Fix the named items (restore the wiring, or update docs/PARITY.md so the record is true):
$(printf '%s\n' "$out" | grep -E '^(LEDGER |UNRECORDED|FAIL:)' | head -n 12 | cut -c1-160 | sed 's/^/         /')"
    return
  fi
  record_pass "$n: engine-parity ledger matches the probes on '$CANDIDATE'
$(printf '%s\n' "$out" | grep -E '^SUMMARY:' | cut -c1-160 | sed 's/^/         /')"
}

# ── bounded suite runner + exact-PID subtree reaping ──────────────────────────────────────────────────
#   A suite that HANGS is killed on the timeout — but a fixture supervisor it setsid'd into its OWN
#   session used to survive: `timeout`/process-group signals cannot reach a detached grandchild, and THIS
#   box forbids pattern-kill (pkill/killall — other orgs share it) AND blocks unprivileged PID namespaces
#   (`unshare` → EPERM), so neither of the usual containments is available. The one that IS: while the
#   suite is still alive its WHOLE subtree — setsid'd children included — is still reachable via /proc
#   PPID links (the child reparents to init only once we kill its parents). So on timeout we enumerate the
#   subtree FIRST, then reap every pid we captured BY EXACT PID (+ its own session-group when it setsid'd)
#   — never a name pattern, never the gate's own group. TERM (a suite that traps TERM gets to reap its own
#   recorded fixtures) → short grace → KILL. We do NOT rely on the suite's EXIT trap (a final SIGKILL
#   skips it). Residual (named honestly): a grandchild that setsids AND spawns a fresh child in the narrow
#   window between our enumeration and our kill can still slip — unreapable here without a pidfile contract.
_desc_pids() {   # every live descendant PID of $1 (breadth-first, recursive, via /proc), one per line
  local root="$1" p st after pid
  local -a queue=("$root") out=()
  while [ "${#queue[@]}" -gt 0 ]; do
    p="${queue[0]}"; queue=("${queue[@]:1}")
    for st in /proc/[0-9]*/stat; do
      [ -r "$st" ] || continue
      pid="${st#/proc/}"; pid="${pid%/stat}"
      # robust PPID: comm (field 2) can hold spaces/parens — everything after the LAST ') ' is
      # 'state ppid pgrp …', so ppid is the 2nd field of that tail.
      after="$(cat "$st" 2>/dev/null)" || continue
      after="${after##*') '}"
      set -- $after
      [ "${2:-}" = "$p" ] || continue
      out+=("$pid"); queue+=("$pid")
    done
  done
  [ "${#out[@]}" -gt 0 ] && printf '%s\n' "${out[@]}"
}
_pgid_of() { local a; a="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1; a="${a##*') '}"; set -- $a; printf '%s' "${3:-}"; }
_signal_pids() {   # $1=SIG; rest=pids. Signal each EXACT pid; if a pid leads its OWN group (it setsid'd),
                   # reap that whole group too — a group we traced to OUR suite, never the gate's, never a pattern.
  local sig="$1"; shift
  local p pg seen=" "
  for p in "$@"; do
    case "$p" in ''|*[!0-9]*) continue ;; esac
    case "$seen" in *" $p "*) continue ;; esac
    seen="$seen$p "
    pg="$(_pgid_of "$p")"                     # read the group BEFORE we kill the pid (stat vanishes after)
    kill -"$sig" "$p" 2>/dev/null || true
    [ -n "$pg" ] && [ "$pg" = "$p" ] && [ "$pg" -gt 1 ] 2>/dev/null && kill -"$sig" -- "-$pg" 2>/dev/null || true
  done
}
SUITE_RC=0
run_suite_bounded() {   # $1=command (run verbatim via `sh -c`, exactly as lefthook would), $2=logfile, $3=timeout-s
  local cmd="$1" logf="$2" tmo="$3"
  ( cd "$WT" && exec sh -c "$cmd" ) >"$logf" 2>&1 < /dev/null &
  local pid=$! waited=0
  while [ "$waited" -lt "$tmo" ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1; waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    local -a tree; mapfile -t tree < <(_desc_pids "$pid")           # enumerate while the subtree is intact
    _signal_pids TERM "$pid" ${tree[@]+"${tree[@]}"}
    local g=0; while [ "$g" -lt 2 ]; do sleep 1; g=$((g + 1)); done  # grace for a TERM-trapping suite
    local -a tree2; mapfile -t tree2 < <(_desc_pids "$pid")
    _signal_pids KILL "$pid" ${tree[@]+"${tree[@]}"} ${tree2[@]+"${tree2[@]}"}
    wait "$pid" 2>/dev/null || true
    SUITE_RC=124
    return
  fi
  wait "$pid"; SUITE_RC=$?
}

# ── CHECK: suites-on-exact-tree (HARD — the suites ARE the adopter-facing machinery) ──────────────────
check_suites_on_exact_tree() {
  local n="suites-on-exact-tree"

  if [ "$SKIP_SUITES" -eq 1 ]; then
    record_warn "$n: ╔══════════════════════════════════════════════════════════════════════════════╗
       ║  SUITES NOT RUN  (--skip-suites)                                             ║
       ║  This release candidate is NOT proven on its own tree. The suites are what    ║
       ║  cover \`kickoff pull\` / the plugin cache / the whole adopt→pull→eject journey ║
       ║  — the exact machinery a bad release bricks. DO NOT TAG on this run alone:    ║
       ║  re-run the gate WITHOUT --skip-suites before you cut the tag.                ║
       ╚══════════════════════════════════════════════════════════════════════════════╝"
    return
  fi

  # The suite list is DISCOVERED FROM THE CANDIDATE's own lefthook.yml (pre-push block) — never hardcoded:
  # each tag declares its own gate suite, and a hardcoded list would both miss new suites and break on
  # older candidates.
  local lh
  lh="$(g cat-file -p "${CANDIDATE}:${LEFTHOOK_PATH}" 2>/dev/null)" || {
    record_fail "$n: no $LEFTHOOK_PATH at candidate '$CANDIDATE' — cannot determine which suites this
       release declares, so the tree is UNPROVEN. Fail-closed (a release nobody tested is the brick class)."
    return
  }

  # DISCOVER each pre-push command's `run:` value — the FULL command line lefthook would execute, NOT only
  # `bash `-prefixed ones. A gate suite declared as `node x.mjs` / `sh x.sh` / `python x.py` / `./x` must
  # be discovered and RUN too; the old `bash `-only grep silently SKIPPED any other runner, so a RED
  # non-bash suite would ship unseen (and if it was the pull/plugin/journey suite, the gate would pass a
  # brick). Each command is run verbatim through `sh -c` — exactly how lefthook runs it — and a script-file
  # token is derived from it for the DECLARED-BUT-ABSENT guard + the anti-recursion self-exclusion.
  local -a S_CMD=() S_TOK=()
  local cmd tok d skip
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    tok="$(printf '%s' "$cmd" | grep -oE '(\.{0,2}/)?([A-Za-z0-9._-]+/)*[A-Za-z0-9_.-]+\.(sh|bash|mjs|cjs|js|py|rb)' | head -n1)"
    # SELF-EXCLUSION (structural, not a tolerance patch): this gate's OWN selftest runs this gate, which
    # would run the suites, which would run the selftest… → infinite recursion. It runs on pre-push.
    case "$tok" in release-gate-selftest.sh|*/release-gate-selftest.sh) continue ;; esac
    skip=0
    if [ "${#S_CMD[@]}" -gt 0 ]; then
      for d in "${S_CMD[@]}"; do [ "$d" = "$cmd" ] && skip=1; done   # dedup identical run: lines
    fi
    [ "$skip" -eq 1 ] && continue
    S_CMD+=("$cmd"); S_TOK+=("$tok")
  done < <(printf '%s\n' "$lh" \
             | awk '/^pre-push:/{p=1; next} /^[A-Za-z_-]+:/{ if (p) p=0 } p' \
             | sed -n 's/^[[:space:]]*run:[[:space:]]*//p')

  if [ "${#S_CMD[@]}" -eq 0 ]; then
    record_fail "$n: $LEFTHOOK_PATH at '$CANDIDATE' declares NO pre-push suites — the tree is UNPROVEN.
       Fail-closed rather than certify a release nothing tested."
    return
  fi

  ensure_worktree || {
    record_fail "$n: could not create a detached worktree of '$CANDIDATE' — the suites MUST run on the
       exact tag tree (the dirty working tree proves nothing about what you are about to tag)."
    return
  }

  printf '       running %d declared suite(s) from a detached worktree of %s (timeout %ss each)…\n' \
    "${#S_CMD[@]}" "$CANDIDATE" "$SUITE_TIMEOUT"

  local log; log="$(mktemp)"
  local rc t0 dt red="" ran=0 excluded="" name ran_names="" i
  case "$lh" in *release-gate-selftest.sh*) excluded=" (excluded scripts/release-gate-selftest.sh — it runs THIS gate; it is covered on pre-push)" ;; esac

  for i in "${!S_CMD[@]}"; do
    cmd="${S_CMD[$i]}"; tok="${S_TOK[$i]}"; name="${tok:-$cmd}"
    # DECLARED-BUT-ABSENT: only assertable when the command names a locatable script (a runner-only
    # command like `make test` has none — it still RUNS below, we just cannot pre-flight its file).
    if [ -n "$tok" ] && [ ! -e "$WT/$tok" ]; then
      printf '       · %-34s DECLARED BUT ABSENT\n' "$name"
      red="${red}
         - ${name}: declared in $LEFTHOOK_PATH (run: $cmd) but its script is ABSENT from the tree"
      continue
    fi
    t0=$SECONDS
    SUITE_RC=0
    run_suite_bounded "$cmd" "$log" "$SUITE_TIMEOUT"
    rc=$SUITE_RC
    dt=$((SECONDS - t0))
    ran=$((ran + 1)); ran_names="${ran_names}${name} "
    if [ "$rc" -eq 0 ]; then
      printf '       · %-34s PASS (%ss)\n' "$name" "$dt"
      continue
    fi
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
      printf '       · %-34s TIMEOUT after %ss\n' "$name" "$SUITE_TIMEOUT"
      red="${red}
         - ${name}: TIMED OUT after ${SUITE_TIMEOUT}s (rc=$rc) — its process subtree was reaped by exact PID"
      continue
    fi
    printf '       · %-34s FAIL (rc=%s, %ss)\n' "$name" "$rc" "$dt"
    red="${red}
         - ${name}: rc=$rc
$(tail -n 12 "$log" | cut -c1-160 | sed 's/^/           | /')"
  done
  rm -f "$log"

  if [ -n "$red" ]; then
    record_fail "$n: suite(s) RED on the exact candidate tree '$CANDIDATE' (${ran}/${#S_CMD[@]} ran)${red}
       These suites cover the adopter-facing machinery (pull · plugin cache · the adopt→pull→eject
       journey). Shipping a tag with a red suite is how core-v0.8 bricked every adopter's pull. Fix the
       code — do NOT exclude the suite (that just blinds the gate).${excluded}"
    return
  fi
  record_pass "$n: all ${ran} declared suite(s) GREEN on a detached worktree of '$CANDIDATE'${excluded}
       ran: ${ran_names}"
}

# ── registry: add a check name here to register it (design-for-extension seam) ─────────────────────────
#    Ordered cheap → expensive, so a fast structural failure is on screen long before the ~2min suites.
CHECKS=(
  check_plugin_version_vs_content
  check_manifest_existence_guard
  check_manifest_covers_new_files
  check_changelog_top_section
  check_installer_url_parity
  check_leak_scan_on_tree
  check_parity_ledger
  check_suites_on_exact_tree
)

short_name() { local s="${1#check_}"; printf '%s' "${s//_/-}"; }

# --only: run a subset. It is a DEBUG/RE-RUN aid, never a release pass — the banner + summary say so.
declare -a RUN=()
if [ "${#ONLY[@]}" -gt 0 ]; then
  for want in "${ONLY[@]}"; do
    hit=""
    for c in "${CHECKS[@]}"; do [ "$(short_name "$c")" = "$want" ] && hit="$c"; done
    if [ -z "$hit" ]; then
      printf 'release-gate: --only: unknown check %s\n  known checks:\n' "$want" >&2
      for c in "${CHECKS[@]}"; do printf '    %s\n' "$(short_name "$c")" >&2; done
      exit 2
    fi
    RUN+=("$hit")
  done
else
  RUN=("${CHECKS[@]}")
fi

printf 'release-gate: repo=%s  candidate=%s  prev=%s%s\n' "$REPO_ARG" "$CANDIDATE" "$PREV" \
  "$([ -n "$VERSION" ] && printf '  version=%s' "$VERSION")"
if [ "${#ONLY[@]}" -gt 0 ]; then
  printf '*** PARTIAL RUN (--only): %d of %d checks — this is NOT a release-gate pass. ***\n' \
    "${#RUN[@]}" "${#CHECKS[@]}"
fi
echo
for _c in "${RUN[@]}"; do "$_c"; done

# ── conjunctive summary + honest exit ─────────────────────────────────────────────────────────────────
#    Three outcomes now. `passed = total - failed` would SILENTLY ABSORB the advisories — count all three.
total=${#RESULTS[@]}; failed=0; warned=0
for _r in "${RESULTS[@]}"; do
  case "$_r" in FAIL) failed=$((failed+1)) ;; WARN) warned=$((warned+1)) ;; esac
done
passed=$((total - failed - warned))
_partial=""; [ "${#ONLY[@]}" -gt 0 ] && _partial="PARTIAL "
_adv="$warned advisories"; [ "$warned" -eq 1 ] && _adv="1 advisory"
echo
if [ "$failed" -eq 0 ]; then
  printf 'SUMMARY: %d/%d checks passed, 0 FAILED (hard), %s (WARN — do not block) — %srelease gate GREEN\n' \
    "$passed" "$total" "$_adv" "$_partial"
  [ "$warned" -gt 0 ] && printf '         advisories do not block the tag — read them before you cut it.\n'
  [ "${#ONLY[@]}" -gt 0 ] && printf '         PARTIAL: only %d of %d checks ran — re-run the FULL gate before tagging.\n' "${#RUN[@]}" "${#CHECKS[@]}"
  exit 0
fi
printf 'SUMMARY: %d/%d checks passed, %d FAILED (hard — blocks), %s (WARN — do not block) — %srelease gate RED (do not tag this candidate)\n' \
  "$passed" "$total" "$failed" "$_adv" "$_partial"
exit 1
