#!/usr/bin/env bash
# reconcile-selftest.sh — prove the Phase-2 G9 operability trio, in one command.
#
#   bash scripts/reconcile-selftest.sh
#
# Mirrors adopt-selftest.sh (mk fixtures + ok/bad/chk asserts). Exercises the three G9
# additions that UNBLOCK the legacy-adopter migration:
#   (1) `kickoff adopt --reconcile` — the ALREADY-adopted, manifest-less shape (core.lock
#       present, no adopt-manifest.json → preflight #8 fail-closed). The arc: preflight RED →
#       reconcile → preflight GREEN — and the manifest records ONLY what is PROVABLE
#       (invariant 5): the template-byte-matching seams + the settings.json plugin METADATA;
#       never the hand-edited seam, never an un-original'd CLAUDE.md block. ZERO adopter-file
#       writes (mtime-proven), ZERO claude calls, then adopters-register.
#   (2) `kickoff adopt --dry-run` — the consent surface: the full presence-probed "would …"
#       plan with ZERO writes (mtime + absence + empty-claude-stub-log proven).
#   (3) `kickoff status` — read-only, FAIL-SOFT (rc0 even on a bare dir), reporting adopted?/
#       core-pin/registry/plugin/supervisor/channel.
#
# RED-PROOF: none of the three flags/subcommands existed pre-G9 — `adopt --reconcile` and
# `adopt --dry-run` died "unknown arg", `status` died "unknown subcommand" — so every rc0
# assertion below FAILS on the pre-fix front door; and #8's manifest-missing text did not name
# `--reconcile` (adopt-selftest 7(ii) pinned its absence; that assertion is now inverted there).
#
# LIVE-SAFETY (phase2-plan invariant 8): every engine invocation runs `env -u REPO_DIR` with an
# EXPLICIT fixture REPO_DIR/KICKOFF_CORE_DIR/KICKOFF_ADOPTERS_REGISTRY/CLAUDE_CONFIG_DIR/
# INGRESS_DIR, and PATH resolves a hermetic logging `claude` stub — the live repo, ~/.claude,
# ~/.kickoff/adopters.json and ~/box-ingress are NEVER touched.
#
# Exits non-zero on ANY failed assertion. Deps: bash + coreutils + git + python3 + jq-free.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
AM="$REPO/scripts/adopt-manifest.py"
KICKOFF="$REPO/scripts/kickoff"

PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "▶ reconcile / dry-run / status (Phase-2 G9) self-test"
echo

command -v python3 >/dev/null 2>&1 || { echo "  ❌ python3 not found"; exit 1; }
command -v git     >/dev/null 2>&1 || { echo "  ❌ git not found"; exit 1; }

# ── fixtures: mk() + one EXIT trap (adopt-selftest's cleanup-list idiom) ─────────────
CLEANUP_LIST="$(mktemp)"
mk() { local d; d="$(mktemp -d)"; printf '%s\n' "$d" >> "$CLEANUP_LIST"; printf '%s' "$d"; }
trap 'while IFS= read -r _d; do [ -n "$_d" ] && rm -rf "$_d"; done < "$CLEANUP_LIST"; rm -f "$CLEANUP_LIST"' EXIT

# The hermetic LOGGING `claude` stub: G9 is claude-free by contract (reconcile/dry-run/status
# make ZERO claude calls), so the stub only RECORDS any invocation — a non-empty log is a bug.
STUB="$(mk)"; STUB_LOG="$STUB/claude-calls.log"; : > "$STUB_LOG"
printf '#!/usr/bin/env bash\nprintf '\''%%s\\n'\'' "$*" >> "%s"\nexit 0\n' "$STUB_LOG" > "$STUB/claude"
chmod +x "$STUB/claude"

CFG="$(mk)"                 # isolated CLAUDE_CONFIG_DIR (live ~/.claude never touched)
REGD="$(mk)"; REG="$REGD/adopters.json"   # isolated adopters registry
ING="$(mk)"                 # scratch INGRESS_DIR (unused by G9 — belt-and-braces isolation)

# ── the stub CORE (the pinned clone the adopter runs): tagged, clean, plugin-carrying ─
CORE="$(mk)"; CORE_TAG="core-vREC"
mkdir -p "$CORE/scripts/templates" "$CORE/plugin/.claude-plugin" "$CORE/plugin/skills"
cp "$REPO/scripts/preflight.sh"      "$CORE/scripts/preflight.sh"
cp "$REPO/scripts/adopt-manifest.py" "$CORE/scripts/adopt-manifest.py"
cp "$REPO/scripts/kickoff"           "$CORE/scripts/kickoff"
cp "$REPO/scripts/instance.env.example" "$CORE/scripts/instance.env.example"
cp "$REPO/scripts/templates/KICKOFF.md"        "$CORE/scripts/templates/KICKOFF.md"
cp "$REPO/scripts/templates/kickoff.gitignore" "$CORE/scripts/templates/kickoff.gitignore"
printf '{ "name": "kickoff-local", "owner": { "name": "kickoff" }, "plugins": [ { "name": "kickoff", "source": "./" } ] }\n' \
  > "$CORE/plugin/.claude-plugin/marketplace.json"
printf '{ "name": "kickoff", "version": "0.0.1" }\n' > "$CORE/plugin/.claude-plugin/plugin.json"
printf '# stub plugin content\n' > "$CORE/plugin/skills/README.md"
git -C "$CORE" init -q
git -C "$CORE" config user.email r@r.r; git -C "$CORE" config user.name r
git -C "$CORE" add -A; git -C "$CORE" commit -qm "stub core" >/dev/null
git -C "$CORE" tag "$CORE_TAG"
CORE_COMMIT="$(git -C "$CORE" rev-parse HEAD)"

# ── the legacy-shaped adopter: hand-wired kickoff files + core.lock, NO manifest ───────
# ONE byte-matching shim (.kickoff/bin/mc) + TWO byte-matching file seams (.kickoff/.gitignore,
# .kickoff/KICKOFF.md) + ONE hand-edited seam (.kickoff/bin/scan-secrets) + a plugin-keyed
# .claude/settings.json + a CLAUDE.md kickoff block with NO recorded pre-edit bytes.
FIX="$(mk)"
mkdir -p "$FIX/.kickoff/bin" "$FIX/.kickoff/memory" "$FIX/.claude" "$FIX/chan" "$FIX/src"
git -C "$FIX" init -q
git -C "$FIX" config user.email b@b.b; git -C "$FIX" config user.name b
printf 'print("app")\n' > "$FIX/src/app.py"
# the operator's CLAUDE.md ALREADY carrying the kickoff block (appended long ago; pre-bytes lost)
printf '# Adopter\n\nHouse rules.\n\n<!-- kickoff:begin core-vOLD -->\n@.kickoff/KICKOFF.md\n<!-- kickoff:end -->\n' > "$FIX/CLAUDE.md"
# seams: extract the CURRENT templates from the code under test (what a wired adopter holds)
python3 - "$AM" "$FIX" <<'PYEOF'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("am", sys.argv[1])
am = importlib.util.module_from_spec(spec); spec.loader.exec_module(am)
fix = sys.argv[2]
with open(os.path.join(fix, ".kickoff/bin/mc"), "w") as f:
    f.write(am.SHIM_TEMPLATES["mc"])                       # BYTE-MATCHING shim
with open(os.path.join(fix, ".kickoff/bin/scan-secrets"), "w") as f:
    f.write(am.SHIM_TEMPLATES["scan-secrets"] + "# HAND-EDIT: adopter patched this\n")  # HAND-EDITED
PYEOF
chmod 0755 "$FIX/.kickoff/bin/mc" "$FIX/.kickoff/bin/scan-secrets"
cp "$REPO/scripts/templates/kickoff.gitignore" "$FIX/.kickoff/.gitignore"   # BYTE-MATCHING file seam
cp "$REPO/scripts/templates/KICKOFF.md"        "$FIX/.kickoff/KICKOFF.md"   # BYTE-MATCHING file seam
# the plugin keys exactly as `claude plugin marketplace add/install --scope project` writes them
printf '{\n  "extraKnownMarketplaces": { "kickoff-local": { "source": { "source": "directory", "path": "%s/plugin" } } },\n  "enabledPlugins": { "kickoff@kickoff-local": true }\n}\n' "$CORE" > "$FIX/.claude/settings.json"
# instance config + the data paths preflight #1b requires inside the repo
cat > "$FIX/.kickoff/instance.env" <<EOF
export TELEGRAM_STATE_DIR="$FIX/chan"
export MC_STATE_FILE="$FIX/.kickoff/state/mission-control/mission-state.json"
export MEMORY_DB="$FIX/.kickoff/state/memory-index.db"
export MEMORY_HOOK_LOG="$FIX/.kickoff/state/memory-hook.log"
EOF
printf '# memory index\n' > "$FIX/.kickoff/memory/MEMORY.md"
# the format-2 core.lock pinning the stub core (what `kickoff pull` left behind)
cat > "$FIX/.kickoff/core.lock" <<EOF
# .kickoff/core.lock — WHOLE-TREE core pin (format 2). Verified by preflight #6.
format 2
tag $CORE_TAG
commit $CORE_COMMIT
EOF
git -C "$FIX" add -A >/dev/null 2>&1 || true
git -C "$FIX" commit -qm "adopter baseline (hand-wired kickoff, no manifest)" >/dev/null 2>&1 || true
# the INSTALLED plugin state: a project-scope row + a cache snapshot byte-equal to \$CORE/plugin
mkdir -p "$CFG/plugins/cache/kickoff-local/kickoff/0.0.1"
cp -a "$CORE/plugin/." "$CFG/plugins/cache/kickoff-local/kickoff/0.0.1/"
rm -rf "$CFG/plugins/cache/kickoff-local/kickoff/0.0.1/.git" 2>/dev/null || true
printf '{ "version": 2, "plugins": { "kickoff@kickoff-local": [ { "scope": "project", "installPath": "%s", "version": "0.0.1" } ] } }\n' \
  "$CFG/plugins/cache/kickoff-local/kickoff/0.0.1" > "$CFG/plugins/installed_plugins.json"

# ── isolated runners (invariant 8 — explicit env, never the live repo) ───────────────
# SCRUB the ENTIRE instance-env whitelist, not just REPO_DIR: this suite runs INSIDE a
# kickoff-managed session (lefthook pre-push too), whose ambient environment legitimately
# exports the LIVE repo's data-path vars (MEMORY_INDEX=memory/MEMORY.md, MC_STATE_FILE, …) —
# a preset env var WINS over the fixture's instance.env by design, so an unscrubbed run
# false-fails preflight #3 against a path in the FIXTURE that only exists in the live repo.
_SCRUB=(-u REPO_DIR -u KICKOFF_CORE_DIR -u KICKOFF_CORE_REMOTE -u MC_STATE_FILE -u MC_TRACKER_FILE
        -u MEMORY_DB -u MEMORY_HOOK_LOG -u MEMORY_DIR -u MEMORY_INDEX -u TELEGRAM_STATE_DIR
        -u CHANNEL_SPEC -u REGROUND_PROMPT -u PERMISSION_MODE -u EFFORT -u MODEL -u MAX_CONCURRENT_AGENTS -u DEPLOY_BRANCH
        -u CADENCE -u INSTANCE_ENV -u LOCKFILE -u ORIGIN_STATE_DIR -u OPERATOR_STATE_DIR)
kf() {   # kf <repo> <args…> — the front door UNDER TEST (the source tree's)
  local r="$1"; shift
  [ -n "$r" ] || { echo "INTERNAL: kf with empty repo" >&2; return 99; }
  env "${_SCRUB[@]}" REPO_DIR="$r" KICKOFF_CORE_DIR="$CORE" KICKOFF_ADOPTERS_REGISTRY="$REG" \
      CLAUDE_CONFIG_DIR="$CFG" INGRESS_DIR="$ING" PATH="$STUB:$PATH" \
      bash "$KICKOFF" "$@"
}
pf() {   # pf <repo> — the preflight FROM the pinned core (running-core == KICKOFF_CORE_DIR, #14)
  PF_RC=0
  PF_OUT="$(env "${_SCRUB[@]}" REPO_DIR="$1" KICKOFF_CORE_DIR="$CORE" KICKOFF_ADOPTERS_REGISTRY="$REG" \
      CLAUDE_CONFIG_DIR="$CFG" INGRESS_DIR="$ING" PATH="$STUB:$PATH" \
      bash "$CORE/scripts/preflight.sh" 2>&1)" || PF_RC=$?
}
snap() { find "$1" -type f -printf '%p %T@\n' 2>/dev/null | LC_ALL=C sort; }   # mtime snapshot

# ══════════════════════════════════════════════════════════════════════════════════════
echo "1. the legacy-adopter arc: core.lock + hand-wired files + NO manifest → preflight #8 RED"
pf "$FIX"
chk "pre-reconcile: whole preflight FAILS (rc≠0 — #8 fail-closed absence)"    "[ $PF_RC -ne 0 ]"
chk "pre-reconcile: #8 names the manifest as MISSING" \
  "printf '%s' \"\$PF_OUT\" | grep -q 'adopt-manifest.json MISSING'"
chk "pre-reconcile: the FAIL text names \`kickoff adopt --reconcile\` for exactly this shape" \
  "printf '%s' \"\$PF_OUT\" | grep -q -- 'kickoff adopt --reconcile'"
echo

echo "2. adopt --reconcile: manifest generated, ONLY the provable recorded, zero writes"
BEFORE_FIX="$(snap "$FIX")"
: > "$STUB_LOG"
rec_rc=0
rec_out="$(kf "$FIX" adopt --reconcile --dir "$FIX" 2>&1)" || rec_rc=$?
MF="$FIX/.kickoff/adopt-manifest.json"
chk "reconcile exits 0"                                   "[ $rec_rc -eq 0 ]"
chk "manifest written (valid JSON, schema_version 2)" \
  "python3 -c \"import json;m=json.load(open('$MF'));assert m['schema_version']==2 and isinstance(m['entries'],list) and isinstance(m['machine_entries'],list)\""
chk "manifest is 0600 (the keystone's mode discipline)" \
  "[ \"\$(stat -c '%a' \"$MF\")\" = 600 ]"
chk "RECORDED: .kickoff/bin/mc (byte-matching shim) as created/seam with the on-disk hash" \
  "python3 -c \"import json,hashlib;e=[x for x in json.load(open('$MF'))['entries'] if x['path']=='.kickoff/bin/mc'][0];assert e['action']=='created' and e['class']=='seam' and e['sha256_at_write']==hashlib.sha256(open('$FIX/.kickoff/bin/mc','rb').read()).hexdigest()\""
chk "RECORDED: .kickoff/.gitignore + .kickoff/KICKOFF.md (byte-matching file seams)" \
  "python3 -c \"import json;ps=[e['path'] for e in json.load(open('$MF'))['entries']];assert '.kickoff/.gitignore' in ps and '.kickoff/KICKOFF.md' in ps\""
chk "NOT recorded: the hand-edited .kickoff/bin/scan-secrets (bytes ≠ template)" \
  "python3 -c \"import json;ps=[e['path'] for e in json.load(open('$MF'))['entries']];assert '.kickoff/bin/scan-secrets' not in ps\""
chk "NOT recorded: CLAUDE.md (no pre-edit bytes → recording it would arm data loss)" \
  "python3 -c \"import json;ps=[e['path'] for e in json.load(open('$MF'))['entries']];assert 'CLAUDE.md' not in ps\""
chk "NOT recorded: .claude/settings.json as a file entry (metadata-only honesty)" \
  "python3 -c \"import json;ps=[e['path'] for e in json.load(open('$MF'))['entries']];assert '.claude/settings.json' not in ps\""
chk "RECORDED: the machine plugin row kickoff@kickoff-local (scope=project, source path kept)" \
  "python3 -c \"import json;m=[x for x in json.load(open('$MF'))['machine_entries'] if x.get('kind')=='plugin'][0];assert m['marketplace']=='kickoff-local' and m['plugin']=='kickoff' and m['scope']=='project' and m['marketplace_source']=='$CORE/plugin'\""
chk "exactly 3 entries + 1 machine entry (nothing more slipped in)" \
  "python3 -c \"import json;m=json.load(open('$MF'));assert len(m['entries'])==3 and len(m['machine_entries'])==1\""
chk "the report SAYS what was recorded vs report-only (names the hand-edited seam + CLAUDE.md)" \
  "printf '%s' \"\$rec_out\" | grep -q 'REPORT-ONLY' && printf '%s' \"\$rec_out\" | grep -q 'scan-secrets' && printf '%s' \"\$rec_out\" | grep -q 'CLAUDE.md'"
chk "adopters-register ran: the registry holds this repo @ the core.lock tag" \
  "python3 -c \"import json,os;rows=json.load(open('$REG'))['adopters'];r=[a for a in rows if os.path.realpath(a['repo'])==os.path.realpath('$FIX')][0];assert r['tag']=='$CORE_TAG'\""
# THE zero-write proof: every pre-existing adopter file has an UNCHANGED path+mtime; the ONLY
# new file is the manifest itself; and the claude stub was never invoked.
AFTER_FIX="$(snap "$FIX" | grep -v '/.kickoff/adopt-manifest.json ')"
chk "ZERO adopter-file writes (mtime snapshot identical; only the manifest is new)" \
  "[ \"\$BEFORE_FIX\" = \"\$AFTER_FIX\" ]"
chk "ZERO claude calls during reconcile (stub log empty)"  "[ ! -s \"$STUB_LOG\" ]"
echo

echo "3. the arc closes: preflight #8 GREEN after reconcile (seam half + plugin-cache half)"
pf "$FIX"
chk "post-reconcile: WHOLE preflight exits 0"             "[ $PF_RC -eq 0 ]"
chk "post-reconcile: #8 seam integrity verified (the recorded byte-matching seams)" \
  "printf '%s' \"\$PF_OUT\" | grep -q 'seam integrity verified'"
chk "post-reconcile: #8 plugin cache integrity verified (machine row + byte-equal cache)" \
  "printf '%s' \"\$PF_OUT\" | grep -q 'plugin cache integrity verified'"
# refusal: reconcile is NOT the idempotent path — a second run must refuse, naming `kickoff adopt`
rec2_rc=0
rec2_out="$(kf "$FIX" adopt --reconcile --dir "$FIX" 2>&1)" || rec2_rc=$?
chk "re-run REFUSED (manifest exists) with rc≠0"          "[ $rec2_rc -ne 0 ]"
chk "the refusal names \`kickoff adopt\` as the idempotent re-wire" \
  "printf '%s' \"\$rec2_out\" | grep -q 'kickoff adopt'"
echo

echo "4. adopt --dry-run on a fresh brownfield repo: the full plan, ZERO writes"
DFIX="$(mk)"
mkdir -p "$DFIX/src"
git -C "$DFIX" init -q
git -C "$DFIX" config user.email d@d.d; git -C "$DFIX" config user.name d
printf '# Fresh Repo\n\nOperator rules.\n' > "$DFIX/CLAUDE.md"
printf 'x = 1\n' > "$DFIX/src/lib.py"
git -C "$DFIX" add -A >/dev/null; git -C "$DFIX" commit -qm base >/dev/null
BEFORE_D="$(snap "$DFIX")"
REG_SHA_BEFORE="$(sha256sum "$REG" | awk '{print $1}')"
: > "$STUB_LOG"
dry_rc=0
dry_out="$(kf "$DFIX" adopt --dry-run --dir "$DFIX" 2>&1)" || dry_rc=$?
chk "dry-run exits 0"                                     "[ $dry_rc -eq 0 ]"
for _would in \
  "would scaffold .*instance.env" \
  "would gen-shim .kickoff/bin/mc" \
  "would gen-shim .kickoff/bin/scan-secrets" \
  "would gen-shim .kickoff/bin/scan-structure" \
  "would gen-gitignore .kickoff/.gitignore" \
  "would gen-charter .kickoff/KICKOFF.md" \
  "would append the @.kickoff/KICKOFF.md block" \
  "would enable the plugin" \
  "would self-pin .kickoff/core.lock @ $CORE_TAG" \
  "would register this adopter" \
  "would stamp KICKOFF_CORE_DIR" \
  "would seed .kickoff/memory/MEMORY.md" \
  "would seed .kickoff/state/mission-control/mission-state.json" \
  "DRY-RUN COMPLETE"
do
  chk "plan line: \"$_would\"" "printf '%s' \"\$dry_out\" | grep -q \"$_would\""
done
AFTER_D="$(snap "$DFIX")"
chk "ZERO writes: no .kickoff/ was created"               "[ ! -e \"$DFIX/.kickoff\" ]"
chk "ZERO writes: file+mtime snapshot identical"          "[ \"\$BEFORE_D\" = \"\$AFTER_D\" ]"
chk "ZERO claude calls (stub log empty)"                  "[ ! -s \"$STUB_LOG\" ]"
chk "ZERO registry writes (registry bytes unchanged)" \
  "[ \"\$REG_SHA_BEFORE\" = \"\$(sha256sum \"$REG\" | awk '{print \$1}')\" ]"
chk "CLAUDE.md untouched (no block appended)"             "! grep -q 'kickoff:begin' \"$DFIX/CLAUDE.md\""
chk "--reconcile + --dry-run together are REFUSED (reconcile's report IS the consent surface)" \
  "! kf \"$DFIX\" adopt --reconcile --dry-run --dir \"$DFIX\""
echo

echo "5. kickoff status: read-only, rc0, reports the wired truth (and fail-soft on a bare dir)"
# a LIVE supervisor lock (this test shell's own pid) to exercise the live-pid probe
printf '%s\n' "$$" > "$FIX/.kickoff/supervisor.lock"
MF_SHA_BEFORE="$(sha256sum "$MF" | awk '{print $1}')"
: > "$STUB_LOG"
st_rc=0
st_out="$(kf "$FIX" status --dir "$FIX" 2>&1)" || st_rc=$?
chk "status exits 0 on the adopted fixture"               "[ $st_rc -eq 0 ]"
chk "reports adopted + the counts (3 recorded, 1 machine)" \
  "printf '%s' \"\$st_out\" | grep -q 'adopted — adopt-manifest.json present (3 recorded touch(es), 1 machine entry)'"
chk "reports the core pin HOLDS (core.lock tag/commit == the actual clone, clean tree)" \
  "printf '%s' \"\$st_out\" | grep -q 'core pin HOLDS' && printf '%s' \"\$st_out\" | grep -q \"$CORE_TAG\""
chk "reports the registry self-row (repo · tag)" \
  "printf '%s' \"\$st_out\" | grep -q 'self: registered' && printf '%s' \"\$st_out\" | grep -q \"$CORE_TAG\""
chk "reports the plugin recorded-vs-installed, scope-matched (installed 0.0.1 == pinned 0.0.1)" \
  "printf '%s' \"\$st_out\" | grep -q 'kickoff@kickoff-local' && printf '%s' \"\$st_out\" | grep -q 'installed 0.0.1 == pinned 0.0.1'"
chk "reports the plugin-cache-verify byte-check GREEN" \
  "printf '%s' \"\$st_out\" | grep -q 'plugin-cache-verify: cache byte-matches'"
chk "reports the LIVE supervisor pid"                     "printf '%s' \"\$st_out\" | grep -q \"supervisor LIVE (pid $$\""
chk "reports the channel dir present"                     "printf '%s' \"\$st_out\" | grep -q 'channel dir: .*chan (present)'"
chk "status is READ-ONLY (manifest bytes unchanged)" \
  "[ \"\$MF_SHA_BEFORE\" = \"\$(sha256sum \"$MF\" | awk '{print \$1}')\" ]"
chk "status makes ZERO claude calls (stub log empty)"     "[ ! -s \"$STUB_LOG\" ]"
# FAIL-SOFT: a bare, never-adopted dir still exits 0 and says so
BARE="$(mk)"
st2_rc=0
st2_out="$(kf "$BARE" status --dir "$BARE" 2>&1)" || st2_rc=$?
chk "fail-soft: status on a bare dir still exits 0"       "[ $st2_rc -eq 0 ]"
chk "fail-soft: reports NOT adopted + no core.lock (absence, not error)" \
  "printf '%s' \"\$st2_out\" | grep -q 'not adopted' && printf '%s' \"\$st2_out\" | grep -q 'no .kickoff/core.lock'"
chk "fail-soft: names --reconcile for the manifest-less recovery" \
  "printf '%s' \"\$st2_out\" | grep -q -- 'kickoff adopt --reconcile'"
echo

echo "6. R1 realpath hygiene: a corrupt repo:\"\" row must NOT phantom-match the CWD (realpath('')→CWD)"
# A blank/missing repo previously canonicalized via os.path.realpath("") == the process CWD, so a
# corrupt registry row PHANTOM-matched THIS dir: `adopters-self` reported this repo as registered
# when it is NOT, and `adopters-siblings` SKIPPED the row as "self" (hiding a real sibling — the
# UNSAFE direction). Fixed _canon_repo maps blank/missing → "" (≠ any real repo). Query FROM INSIDE
# the target (CWD == target — the exact shape that armed the phantom) against a registry whose ONLY
# row is corrupt (repo:"") and is NOT this repo. --repo/--registry explicit so nothing bleeds from
# the live env (belt: -u REPO_DIR -u KICKOFF_ADOPTERS_REGISTRY).
PHREPO="$(mk)"
PHREG="$(mk)/adopters.json"
printf '{ "schema_version": 2, "adopters": [ { "repo": "", "tag": "core-vSIB", "version_dir": "%s" } ] }\n' "$PHREPO" > "$PHREG"
self_ph_rc=0
( cd "$PHREPO" && env -u REPO_DIR -u KICKOFF_ADOPTERS_REGISTRY python3 "$AM" adopters-self \
    --repo "$PHREPO" --registry "$PHREG" ) >/dev/null 2>&1 || self_ph_rc=$?
sib_ph_out="$( cd "$PHREPO" && env -u REPO_DIR -u KICKOFF_ADOPTERS_REGISTRY python3 "$AM" adopters-siblings \
    --repo "$PHREPO" --tag core-vMINE --registry "$PHREG" 2>/dev/null || true )"
chk "corrupt repo:\"\" row: adopters-self does NOT phantom-self-match CWD (rc≠0) AND adopters-siblings surfaces it as a real sibling (not phantom-skipped as self)" \
  "[ $self_ph_rc -ne 0 ] && printf '%s' \"\$sib_ph_out\" | grep -q core-vSIB"
echo

echo "──────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "  ✅ G9 reconcile/dry-run/status hold"; exit 0; } || { echo "  ❌ see failures above"; exit 1; }
