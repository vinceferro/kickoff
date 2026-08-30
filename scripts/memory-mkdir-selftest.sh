#!/usr/bin/env bash
# memory-mkdir-selftest.sh — prove the memory index self-heals its cache dir on first run.
#
#   bash scripts/memory-mkdir-selftest.sh
#
# REPRO-THEN-FIX (core-v0.3.1 Fix A). MEMORY_DB lives under a GITIGNORED dir — the instance.env
# default is ${REPO_DIR:-$PWD}/.kickoff/state/memory-retrieval/memory-index.db, and .kickoff/ is
# gitignored — so on a FRESH clone that parent dir is ABSENT. Before the fix, the first
# `run.sh index` died `ERR_SQLITE_ERROR: unable to open database file`, and the proactive hook
# SWALLOWED the reindex error → memory silently returned nothing. The fix mkdir -p's the DB's
# parent dir before every write-open (buildIndex + reindexIncremental). This test builds from a
# clean corpus with NO pre-existing DB dir and asserts the index builds, retrieves, and re-indexes.
#
# Mirrors the ok/bad/chk shape of the other selftests. Exits non-zero on ANY failed assertion.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
MR="$REPO/memory-retrieval"

# Scrub any inherited MEMORY_*/REPO_DIR so a caller's LIVE paths never steer this hermetic fixture
# (the same posture adopt-selftest.sh / reconcile-selftest.sh take on the instance.env whitelist).
unset MEMORY_DB MEMORY_DIR MEMORY_INDEX MEMORY_HOOK_LOG REPO_DIR 2>/dev/null || true

PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "▶ memory index mkdir self-heal self-test (core-v0.3.1 Fix A)"
echo

if ! command -v node >/dev/null 2>&1; then
  echo "  (node not found — skipping the memory mkdir selftest)"; exit 0
fi

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/corpus"
# A memory file with a distinctive body so retrieve can actually find it.
printf '%s\n' '---' 'type: reference' 'description: the chrome principle fact' '---' \
  'Always render the UI and look at the real pixels before calling it done.' \
  > "$FIX/corpus/chrome-principle.md"

# THE KEY: MEMORY_DB points at a NESTED dir that does not exist yet — mirrors a fresh clone's
# gitignored .kickoff/state/memory-retrieval/. buildIndex must mkdir -p it, not die.
DB="$FIX/state/memory-retrieval/memory-index.db"
chk "the DB parent dir does NOT pre-exist (the fresh-clone shape)" "[ ! -d \"$FIX/state\" ]"

# ── 1. buildIndex path (run.sh index) — the exact command preflight / the operator runs ──────
idx_rc=0
idx_out="$(MEMORY_DIR="$FIX/corpus" MEMORY_DB="$DB" bash "$MR/run.sh" index 2>&1)" || idx_rc=$?
chk "run.sh index SUCCEEDS from a clean corpus with a missing DB dir (exit 0)" "[ $idx_rc -eq 0 ]"
chk "run.sh index did NOT emit 'unable to open database file' (the pre-fix death)" \
  "! printf '%s' \"\$idx_out\" | grep -qi 'unable to open database file'"
chk "the DB file was created under the auto-made parent dir" "[ -f \"$DB\" ]"
chk "the gitignored parent dir was mkdir -p'd" "[ -d \"$FIX/state/memory-retrieval\" ]"

# ── 2. retrieve round-trip against the freshly-built index (memory actually surfaces) ────────
ret_rc=0
ret_out="$(MEMORY_DIR="$FIX/corpus" MEMORY_DB="$DB" bash "$MR/run.sh" retrieve "chrome principle render pixels" 2>&1)" || ret_rc=$?
chk "run.sh retrieve SUCCEEDS against the built index (exit 0)" "[ $ret_rc -eq 0 ]"
chk "retrieve surfaces the indexed fact (chrome-principle)" \
  "printf '%s' \"\$ret_out\" | grep -q 'chrome-principle'"

# ── 3. the incremental entrypoint ALSO self-heals a missing DB dir ───────────────────────────
# Blow the whole cache dir away, add a file, run index.mjs --incremental. With the DB gone it
# falls back to a full build, which must mkdir the parent again (covers the second write-open
# entrypoint, not just `run.sh index`).
rm -rf "$FIX/state"
printf '%s\n' '---' 'type: reference' 'description: a second fact' '---' 'Restraint: one accent, used deliberately.' \
  > "$FIX/corpus/restraint.md"
inc_rc=0
inc_out="$(MEMORY_DIR="$FIX/corpus" MEMORY_DB="$DB" node --experimental-sqlite "$MR/index.mjs" --incremental 2>&1)" || inc_rc=$?
chk "index.mjs --incremental self-heals the missing DB dir too (exit 0)" "[ $inc_rc -eq 0 ]"
chk "incremental did NOT emit 'unable to open database file'" \
  "! printf '%s' \"\$inc_out\" | grep -qi 'unable to open database file'"
chk "the DB dir was re-created by the incremental/full path" "[ -f \"$DB\" ]"

echo
echo "──────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "  ✅ memory index self-heals its cache dir"; exit 0; } || { echo "  ❌ see failures above"; exit 1; }
