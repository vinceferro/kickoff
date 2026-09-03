#!/usr/bin/env bash
# adopt-migrate-selftest.sh — prove scripts/adopt-migrate.sh moves a pull-adopter from an OLD
# origin to a NEW-origin repo (no shared history, first tag a pre-release) SAFELY:
#
#   RED lanes (fail-closed, ZERO writes into the adopter):
#     R1  new origin unreachable           → refuse, instance.env byte-identical
#     R2  tag missing at the new origin    → refuse, instance.env byte-identical
#     R3  existence-contract violation (the tag's core-manifest.txt lists a file the tag
#         tree does not carry)             → refuse, instance.env byte-identical
#     R4  the ALPHA seam (documented in code): a BARE `kickoff pull` on a clone whose only
#         tag is core-v1.0.0-alpha REFUSES to auto-select it — why the turnkey names the tag
#
#   GREEN lane: migrate succeeds on the fixture and the CONSUMED state verifies — the
#     adopter's OWN files read back (instance.env remote+dir, the new clone's git origin,
#     core.lock tag+commit, the registry row) + a real `kickoff pull <tag>` re-run lands
#     'PULL OK' + the KICKOFF.md seam regenerated to the new tag's template.
#
#   IDempotence: a re-run verifies consumed state only (no new backup dir, instance.env
#     byte-identical). ROLLBACK artifact: the pre-migrate backup restores the old pin lines.
#
# Hermetic: every repo lives under ONE mktemp root (a two-dir deploy topology: OLD origin +
# NEW origin are SEPARATE repos with NO shared history, exactly the fleet-migration shape).
# NEVER runs git against a live repo — ambient GIT_*/REPO_DIR/KICKOFF_* are scrubbed first
# (the a-stray-fixture-path-runs-git-in-the-live-repo lesson).
#
# Exits non-zero on ANY failed assertion. Deps: python3 + jq + git + coreutils.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
MIGRATE="$REPO/scripts/adopt-migrate.sh"
NEWTAG="core-v1.0.0-alpha"

# ambient scrub — a preset var would beat the fixtures' own instance.env / git env overrides
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE 2>/dev/null || true
unset REPO_DIR KICKOFF_CORE_DIR KICKOFF_CORE_REMOTE INSTANCE_ENV KICKOFF_VERSIONS_DIR \
      KICKOFF_ADOPTERS_REGISTRY TELEGRAM_STATE_DIR MEMORY_DB MEMORY_INDEX MC_STATE_FILE \
      MC_TRACKER_FILE MEMORY_HOOK_LOG MEMORY_DIR CHANNEL_SPEC 2>/dev/null || true

PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
git() { command git "$@"; }   # never inherit a wrapper

# fixture-scoped env, exported BEFORE ANY fixture build: the registry writes below run
# adopt-manifest.py, whose _registry_path falls back to ~/.kickoff/adopters.json (the LIVE
# registry) when the override is absent — a late export leaks fixture rows into live state
# (bit live once while writing this suite; removed via adopters-remove). Belt AND suspenders:
# every fixture-time registry call ALSO passes --registry explicitly.
VERSIONS="$ROOT/versions"; mkdir -p "$VERSIONS"
REGISTRY="$ROOT/adopters.json"
export KICKOFF_VERSIONS_DIR="$VERSIONS" KICKOFF_ADOPTERS_REGISTRY="$REGISTRY"

# ── fixture: the OLD origin — a minimal core tagged core-vA ──────────────────────────────────
OLD_ORIGIN="$ROOT/old-origin"
mkdir -p "$OLD_ORIGIN/scripts/templates"
git -C "$OLD_ORIGIN" init -q; git -C "$OLD_ORIGIN" config user.email t@t.t; git -C "$OLD_ORIGIN" config user.name t
cp "$REPO/scripts/preflight.sh"     "$OLD_ORIGIN/scripts/preflight.sh"
cp "$REPO/scripts/adopt-manifest.py" "$OLD_ORIGIN/scripts/adopt-manifest.py"
printf '# KICKOFF (vA)\n\nCHARTER_MARKER_VA — the coordinator charter.\n\n@.kickoff/KICKOFF.local.md\n' \
  > "$OLD_ORIGIN/scripts/templates/KICKOFF.md"
cat > "$OLD_ORIGIN/scripts/core-manifest.txt" <<'MAN'
scripts/preflight.sh
scripts/adopt-manifest.py
scripts/templates/KICKOFF.md
scripts/core-manifest.txt
CORE-CHANGELOG.md
MAN
printf '# CORE-CHANGELOG\n\n## core-vA — 2026-01-01\n\nfirst tagged core.\n' > "$OLD_ORIGIN/CORE-CHANGELOG.md"
git -C "$OLD_ORIGIN" add -A; git -C "$OLD_ORIGIN" commit -qm "core-vA"; git -C "$OLD_ORIGIN" tag core-vA

# ── fixture: the NEW origin — NO shared history, first tag a PRE-RELEASE (the fleet shape) ───
build_new_origin() {   # $1=dest  $2=extra-manifest-line ("" = healthy)  $3=tag
  local dest="$1" extra="$2" tag="$3"
  mkdir -p "$dest/scripts/templates"
  git -C "$dest" init -q; git -C "$dest" config user.email t@t.t; git -C "$dest" config user.name t
  cp "$REPO/scripts/preflight.sh"     "$dest/scripts/preflight.sh"
  cp "$REPO/scripts/adopt-manifest.py" "$dest/scripts/adopt-manifest.py"
  cp "$REPO/scripts/kickoff"          "$dest/scripts/kickoff"
  printf '# KICKOFF (vNEW)\n\nCHARTER_MARKER_VNEW — the public-line charter.\n\n@.kickoff/KICKOFF.local.md\n' \
    > "$dest/scripts/templates/KICKOFF.md"
  cat > "$dest/scripts/core-manifest.txt" <<MAN
scripts/preflight.sh
scripts/adopt-manifest.py
scripts/kickoff
scripts/templates/KICKOFF.md
scripts/core-manifest.txt
CORE-CHANGELOG.md
MAN
  [ -n "$extra" ] && printf '%s\n' "$extra" >> "$dest/scripts/core-manifest.txt"
  printf '# CORE-CHANGELOG\n\n## %s — 2026-09-01\n\nfirst tag of the clean public line.\n' "$tag" > "$dest/CORE-CHANGELOG.md"
  git -C "$dest" add -A; git -C "$dest" commit -qm "$tag"; git -C "$dest" tag "$tag"
  git -C "$dest" commit --allow-empty -qm "post-$tag"   # main past the tag → fresh-clone prev_tag empty
}
NEW_ORIGIN="$ROOT/new-origin";          build_new_origin "$NEW_ORIGIN" ""            "$NEWTAG"
BROKEN_ORIGIN="$ROOT/broken-origin";    build_new_origin "$BROKEN_ORIGIN" "scripts/nope.ceremony" "core-vX-broken"

# ── fixture: the adopter — cloned-at-vA core + instance.env + core.lock + registry ───────────
OLD_CORE="$VERSIONS/core-vA"
git clone -q "$OLD_ORIGIN" "$OLD_CORE"; git -C "$OLD_CORE" checkout -q --detach core-vA
OLD_COMMIT="$(git -C "$OLD_CORE" rev-parse HEAD)"

ADOPTER="$ROOT/adopter"
mkdir -p "$ADOPTER/src" "$ADOPTER/memory" "$ADOPTER/.kickoff/state" "$ADOPTER/.kickoff/chan" "$ADOPTER/.claude"
git -C "$ADOPTER" init -q; git -C "$ADOPTER" config user.email t@t.t; git -C "$ADOPTER" config user.name t
printf '# Operator CLAUDE\n\nMy own operator instructions — must survive the migration.\n' > "$ADOPTER/CLAUDE.md"
printf 'source the operator owns\n' > "$ADOPTER/src/app.txt"
printf '# memory index\n' > "$ADOPTER/memory/MEMORY.md"
# A planted FAKE token for the adopter's settings.local.json — a shell var whose value carries
# "FAKE" (a scan placeholder), so this test's OWN source trips no secret-scanner finding (the
# pull/adopt/eject selftest $PLANT posture).
PLANT='FAKE_TELEGRAM_TOKEN_planted_do_not_store_123'
printf '{ "telegram": { "botToken": "%s" } }\n' "$PLANT" > "$ADOPTER/.claude/settings.local.json"
git -C "$ADOPTER" add -A; git -C "$ADOPTER" commit -qm baseline
cat > "$ADOPTER/.kickoff/instance.env" <<EOF
export KICKOFF_CORE_DIR="$OLD_CORE"
export KICKOFF_CORE_REMOTE="$OLD_ORIGIN"
export TELEGRAM_STATE_DIR="$ADOPTER/.kickoff/chan"
export MC_STATE_FILE="$ADOPTER/.kickoff/state/mission-state.json"
export MEMORY_DB="$ADOPTER/.kickoff/state/memory-index.db"
export MEMORY_HOOK_LOG="$ADOPTER/.kickoff/state/memory-hook.log"
EOF
printf 'format 2\ntag core-vA\ncommit %s\n' "$OLD_COMMIT" > "$ADOPTER/.kickoff/core.lock"
python3 "$OLD_CORE/scripts/adopt-manifest.py" gen-charter --repo "$ADOPTER" --source core-vA >/dev/null
python3 "$OLD_CORE/scripts/adopt-manifest.py" adopters-register --repo "$ADOPTER" --tag core-vA \
  --version-dir "$OLD_CORE" --channel "$ADOPTER/.kickoff/chan" --registry "$REGISTRY" >/dev/null
# a SIBLING org still on the old tag (the fleet reality: 6 rows share one registry)
mkdir -p "$ROOT/sibling-org"
python3 "$OLD_CORE/scripts/adopt-manifest.py" adopters-register --repo "$ROOT/sibling-org" --tag core-vA \
  --version-dir "$OLD_CORE" --channel "$ROOT/sibling-chan" --registry "$REGISTRY" >/dev/null

# read one export var out of a fixture instance.env (subshell, like the turnkey does)
read_env_var() { ( set +u; cd /; . "$1" >/dev/null 2>&1 || true; printf '%s' "${!2:-}" ) 2>/dev/null || true; }

command -v python3 >/dev/null 2>&1 || { echo "❌ python3 not found"; exit 1; }
command -v jq      >/dev/null 2>&1 || { echo "❌ jq not found";      exit 1; }
command -v git     >/dev/null 2>&1 || { echo "❌ git not found";     exit 1; }

echo "▶ adopt-migrate self-test (fixture topology: old-origin + new-origin, no shared history)"
echo

# ══ RED lanes — every refusal must leave the adopter BYTE-UNTOUCHED ══════════════════════════
IENV_SHA_BEFORE="$(sha256sum "$ADOPTER/.kickoff/instance.env" | awk '{print $1}')"

echo "R1 — new origin unreachable"
R1_OUT="$(bash "$MIGRATE" --repo "$ADOPTER" --remote "$ROOT/no-such-origin" --tag "$NEWTAG" 2>&1)" && R1_RC=0 || R1_RC=$?
chk "R1 refuses (rc=$R1_RC)"                                        "[ \"$R1_RC\" -ne 0 ]"
chk "R1 names the unreachable origin"                               "printf '%s' \"\$R1_OUT\" | grep -q 'UNREACHABLE'"
chk "R1 wrote NOTHING (instance.env byte-identical)"                "[ \"\$(sha256sum \"$ADOPTER/.kickoff/instance.env\" | awk '{print \$1}')\" = \"$IENV_SHA_BEFORE\" ]"
chk "R1 left no pre-migrate backup dir"                              "[ -z \"\$(ls -d \"$ADOPTER/.kickoff\"/pre-migrate-* 2>/dev/null)\" ]"
echo

echo "R2 — tag missing at the new origin"
R2_OUT="$(bash "$MIGRATE" --repo "$ADOPTER" --remote "$NEW_ORIGIN" --tag core-v9.9.9 2>&1)" && R2_RC=0 || R2_RC=$?
chk "R2 refuses (rc=$R2_RC)"                                        "[ \"$R2_RC\" -ne 0 ]"
chk "R2 names the missing tag"                                      "printf '%s' \"\$R2_OUT\" | grep -q 'NOT FOUND'"
chk "R2 wrote NOTHING (instance.env byte-identical)"                "[ \"\$(sha256sum \"$ADOPTER/.kickoff/instance.env\" | awk '{print \$1}')\" = \"$IENV_SHA_BEFORE\" ]"
echo

echo "R3 — existence-contract violation (tag's core-manifest lists a file the tree lacks)"
R3_OUT="$(bash "$MIGRATE" --repo "$ADOPTER" --remote "$BROKEN_ORIGIN" --tag core-vX-broken 2>&1)" && R3_RC=0 || R3_RC=$?
chk "R3 refuses (rc=$R3_RC)"                                        "[ \"$R3_RC\" -ne 0 ]"
chk "R3 names the existence violation"                              "printf '%s' \"\$R3_OUT\" | grep -q 'EXISTENCE CONTRACT'"
chk "R3 wrote NOTHING (instance.env byte-identical)"                "[ \"\$(sha256sum \"$ADOPTER/.kickoff/instance.env\" | awk '{print \$1}')\" = \"$IENV_SHA_BEFORE\" ]"
chk "R3 left the broken tag UNPINNED (core.lock still core-vA)"     "grep -q '^tag core-vA$' \"$ADOPTER/.kickoff/core.lock\""
echo

echo "R4 — the ALPHA seam: a BARE pull on the new-origin clone refuses to auto-select a pre-release tag"
# (why the turnkey always names the tag: cmd_pull's auto-select filters ^core-v[0-9]+(\.[0-9]+)+$)
R4_CLONE="$VERSIONS/probe-clone"
git clone -q "$NEW_ORIGIN" "$R4_CLONE" 2>/dev/null
R4_OUT="$(REPO_DIR="$ADOPTER" KICKOFF_CORE_DIR="$R4_CLONE" KICKOFF_CORE_REMOTE="$NEW_ORIGIN" \
  INSTANCE_ENV="$ADOPTER/.kickoff/instance.env" \
  bash "$R4_CLONE/scripts/kickoff" pull 2>&1)" && R4_RC=0 || R4_RC=$?
chk "R4 bare pull refuses (rc=$R4_RC, 'NONE shaped like a numeric release')" \
  "[ \"$R4_RC\" -ne 0 ] && printf '%s' \"\$R4_OUT\" | grep -q 'NONE shaped like a numeric release'"
echo

# ══ GREEN — the migration lands and the CONSUMED state verifies ═════════════════════════════
echo "G — migrate $ADOPTER → $NEWTAG from the new origin"
G_OUT="$(bash "$MIGRATE" --repo "$ADOPTER" --remote "$NEW_ORIGIN" --tag "$NEWTAG" 2>&1)" && G_RC=0 || G_RC=$?
printf '%s\n' "$G_OUT" | sed 's/^/    │ /'
chk "G exits 0"                                                     "[ \"$G_RC\" -eq 0 ]"
chk "G prints the MIGRATED verdict line"                            "printf '%s' \"\$G_OUT\" | grep -q 'MIGRATED ✓'"
NEW_CORE="$VERSIONS/$NEWTAG"
NEW_COMMIT="$(git -C "$NEW_CORE" rev-parse HEAD 2>/dev/null || true)"
# consumed state — the ADOPTER'S OWN FILES read back, not the migrate's self-report
chk "G·instance.env KICKOFF_CORE_REMOTE → new origin"               "[ \"\$(read_env_var \"$ADOPTER/.kickoff/instance.env\" KICKOFF_CORE_REMOTE)\" = \"$NEW_ORIGIN\" ]"
chk "G·instance.env KICKOFF_CORE_DIR → the new clone"               "[ \"\$(read_env_var \"$ADOPTER/.kickoff/instance.env\" KICKOFF_CORE_DIR)\" = \"$NEW_CORE\" ]"
chk "G·the new clone's own git origin is the new repo"              "[ \"\$(git -C \"$NEW_CORE\" remote get-url origin)\" = \"$NEW_ORIGIN\" ]"
chk "G·core.lock pins the new tag"                                  "grep -q '^tag $NEWTAG\$' \"$ADOPTER/.kickoff/core.lock\""
chk "G·core.lock commit == the new clone's HEAD"                    "grep -q \"^commit $NEW_COMMIT\$\" \"$ADOPTER/.kickoff/core.lock\""
chk "G·the registry row re-pointed (tag + version_dir) via python"  "python3 -c 'import json,sys;r=json.load(open(sys.argv[1]));a=[x for x in r[\"adopters\"] if x[\"repo\"]==sys.argv[2]][0];sys.exit(0 if a[\"tag\"]==sys.argv[3] and a[\"version_dir\"]==sys.argv[4] else 1)' \"$REGISTRY\" \"$ADOPTER\" \"$NEWTAG\" \"$NEW_CORE\""
chk "G·the KICKOFF.md seam regenerated to the NEW tag's template"   "grep -q 'CHARTER_MARKER_VNEW' \"$ADOPTER/.kickoff/KICKOFF.md\""
chk "G·the adopter's own CLAUDE.md untouched"                       "grep -q 'My own operator instructions' \"$ADOPTER/CLAUDE.md\""
chk "G·backup dir exists with the pre-migration pin"                "ls -d \"$ADOPTER/.kickoff\"/pre-migrate-*/core.lock >/dev/null 2>&1 && grep -q '^tag core-vA$' \"$ADOPTER/.kickoff\"/pre-migrate-*/core.lock"
chk "G·the OLD core dir is still on disk (rollback path kept)"      "[ -d \"$OLD_CORE\" ]"
# the strongest consumed-state proof: the adopter's own front door re-pulls GREEN post-migration
P_RC=0
P_OUT="$(REPO_DIR="$ADOPTER" KICKOFF_CORE_DIR="$NEW_CORE" KICKOFF_CORE_REMOTE="$NEW_ORIGIN" \
  INSTANCE_ENV="$ADOPTER/.kickoff/instance.env" \
  timeout 300 bash "$NEW_CORE/scripts/kickoff" pull "$NEWTAG" 2>&1)" || P_RC=$?
chk "G·post-migration re-pull via the adopter's own front door: PULL OK (rc=$P_RC)" \
  "[ \"$P_RC\" -eq 0 ] && printf '%s' \"\$P_OUT\" | grep -Eq 'PULL OK'"
echo

# ══ IDEMPOTENCE — re-run verifies, writes nothing ════════════════════════════════════════════
echo "I — idempotent re-run"
IENV_SHA_MIGRATED="$(sha256sum "$ADOPTER/.kickoff/instance.env" | awk '{print $1}')"
BK_COUNT_BEFORE="$(ls -d "$ADOPTER/.kickoff"/pre-migrate-* 2>/dev/null | wc -l)"
I_OUT="$(bash "$MIGRATE" --repo "$ADOPTER" --remote "$NEW_ORIGIN" --tag "$NEWTAG" 2>&1)" && I_RC=0 || I_RC=$?
chk "I re-run exits 0"                                              "[ \"$I_RC\" -eq 0 ]"
chk "I re-run says already-migrated (verifies only)"                "printf '%s' \"\$I_OUT\" | grep -q 'already migrated'"
chk "I instance.env byte-identical across the re-run"               "[ \"\$(sha256sum \"$ADOPTER/.kickoff/instance.env\" | awk '{print \$1}')\" = \"$IENV_SHA_MIGRATED\" ]"
chk "I no new backup dir on the re-run"                             "[ \"\$(ls -d \"$ADOPTER/.kickoff\"/pre-migrate-* 2>/dev/null | wc -l)\" -eq \"$BK_COUNT_BEFORE\" ]"
echo

# ══ ROLLBACK — the printed artifacts actually restore the old pin ════════════════════════════
echo "RB — rollback artifact restores the pre-migration pin lines"
BK_DIR="$(ls -d "$ADOPTER/.kickoff"/pre-migrate-* 2>/dev/null | head -1)"
cp -p "$BK_DIR/instance.env" "$ADOPTER/.kickoff/instance.env"
chk "RB restored instance.env names the OLD remote"                 "[ \"\$(read_env_var \"$ADOPTER/.kickoff/instance.env\" KICKOFF_CORE_REMOTE)\" = \"$OLD_ORIGIN\" ]"
chk "RB restored instance.env names the OLD core dir"               "[ \"\$(read_env_var \"$ADOPTER/.kickoff/instance.env\" KICKOFF_CORE_DIR)\" = \"$OLD_CORE\" ]"
echo

printf '▶ adopt-migrate self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
