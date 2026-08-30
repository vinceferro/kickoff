#!/usr/bin/env bash
# adopt-selftest.sh — prove the adopt-manifest KEYSTONE actually holds, in one command.
#
#   bash scripts/adopt-selftest.sh
#
# Mirrors scripts/selftest.sh (mktemp fixture + ok/bad/chk asserts). Exercises
# scripts/adopt-manifest.py — the receipt every eject/preflight/shim depends on:
#   (i)   record each of the 5 actions → the manifest validates (schema + enum)
#   (ii)  a `modified` entry byte-restores the pre-edit file EXACTLY; both sha256s correct
#   (iii) a `hook-installed` entry for a settings.local.json holding a PLANTED FAKE SECRET
#         stores NO original + only jq-paths — and the planted secret is ABSENT from the
#         entire written manifest (the credential-safe proof; a failure here = a real leak)
#   (iv)  verify passes clean, then FAILS (non-zero) after a recorded file is hand-edited
#
# Exits non-zero on ANY failed assertion. Deps: python3 + coreutils + grep (+ jq for the
# hook-installed content hash, Fix A — degrades gracefully if jq is absent).

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
AM="$REPO/scripts/adopt-manifest.py"

# ── self-scrub the ambient instance.env whitelist (robust push-gate) ────────────────────────────────
# This suite builds its OWN hermetic mktemp fixtures — but when it runs INSIDE a kickoff-managed session
# (notably the lefthook pre-push gate), the ambient environment legitimately exports the LIVE repo's
# instance.env whitelist vars (TELEGRAM_STATE_DIR, MEMORY_INDEX, MC_STATE_FILE, …). A preset env var WINS
# over a fixture's instance.env by design, so an unscrubbed run leaks those live channel/data paths into
# the fixtures' preflight/engine calls and false-fails a gate that must pass regardless of the caller's
# env. Unset the whole whitelist (+ its channel/lock siblings) ONCE here — the SAME set reconcile-selftest
# .sh scrubs — BEFORE any fixture setup; the per-fixture `export`s below intentionally re-set their own
# values AFTER this and are preserved.
unset REPO_DIR KICKOFF_CORE_DIR KICKOFF_CORE_REMOTE MC_STATE_FILE MC_TRACKER_FILE \
      MEMORY_DB MEMORY_HOOK_LOG MEMORY_DIR MEMORY_INDEX TELEGRAM_STATE_DIR CHANNEL_SPEC \
      REGROUND_PROMPT PERMISSION_MODE EFFORT MODEL MAX_CONCURRENT_AGENTS DEPLOY_BRANCH \
      CADENCE INSTANCE_ENV LOCKFILE ORIGIN_STATE_DIR OPERATOR_STATE_DIR 2>/dev/null || true

PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

# The literal fake secret planted in the fixture settings.local.json. It must NEVER appear
# in the written manifest — that is the whole point of the hook-installed credential rule.
PLANT='FAKE_TELEGRAM_TOKEN_planted_do_not_store_123'

echo "▶ adopt-manifest keystone self-test"
echo

if ! command -v python3 >/dev/null 2>&1; then
  echo "  ❌ python3 not found — cannot run the adopt-manifest selftest"; exit 1
fi

# ── fixture: a mock adopter repo with a .kickoff/ + a pre-existing .claude/ ─────────
# Every fixture goes through mk() (mktemp -d), and each dir is appended to a cleanup-list FILE
# so ONE EXIT trap removes them all — even dirs mk creates inside a $(command-substitution)
# subshell (an in-memory array would be lost there; a file side-effect survives).
CLEANUP_LIST="$(mktemp)"
mk() { local d; d="$(mktemp -d)"; printf '%s\n' "$d" >> "$CLEANUP_LIST"; printf '%s' "$d"; }
trap 'while IFS= read -r _d; do [ -n "$_d" ] && rm -rf "$_d"; done < "$CLEANUP_LIST"; rm -f "$CLEANUP_LIST"' EXIT
FIX="$(mk)"
PRE="$(mk)"                              # saved verbatim pre-edit copies (what the real adopt flow captures)
export REPO_DIR="$FIX"                   # the engine's convention — adopt-manifest.py resolves the fixture
mkdir -p "$FIX/.kickoff/bin" "$FIX/.claude"
MANIFEST="$FIX/.kickoff/adopt-manifest.json"
am() { python3 "$AM" "$@"; }

# ── record all 5 actions, exactly as `kickoff adopt` would ──────────────────────────
echo "1. record each of the 5 actions"

# created — a generated shim; reversed by delete, no original bytes.
printf '#!/usr/bin/env bash\nexec python3 "$KICKOFF_CORE_DIR/mission-control/mc-update.py" "$@"\n' > "$FIX/.kickoff/bin/mc"
am record --path .kickoff/bin/mc --action created --class seam --source core-v0.2 >/dev/null

# modified — a plain in-place edit. Pre-edit bytes deliberately end WITHOUT a trailing
# newline + carry a tab, so "byte-exact restore" is a real test, not a lucky line-match.
printf 'line A\nline B\n\ttab-indented line\nfinal line no trailing newline' > "$FIX/README.md"
cp "$FIX/README.md" "$PRE/README.md.pre"
printf 'line A\nline B\n\ttab-indented line\nfinal line no trailing newline\nAPPENDED-BY-KICKOFF\n' > "$FIX/README.md"
am record --path README.md --action modified --class seam --source core-v0.2 --original-from "$PRE/README.md.pre" >/dev/null

# block-appended — the marker-delimited @import block into an existing CLAUDE.md.
printf '# My Repo\n\nExisting operator instructions.\n' > "$FIX/CLAUDE.md"
cp "$FIX/CLAUDE.md" "$PRE/CLAUDE.md.pre"
printf '\n<!-- kickoff:begin core-v0.2 -->\n@.kickoff/KICKOFF.md\n<!-- kickoff:end -->\n' >> "$FIX/CLAUDE.md"
am record --path CLAUDE.md --action block-appended --class seam --source core-v0.2 --original-from "$PRE/CLAUDE.md.pre" >/dev/null

# json-merged — a settings.json key-merge. Fixture is NON-jq-canonical (4-space indent,
# Fix 2), so a jq round-trip re-indents the whole file → byte-restore is the only clean
# reversal, and this manifest entry must carry the exact 4-space original.
printf '{\n    "enableAllProjectMcpServers": false\n}\n' > "$FIX/.claude/settings.json"
cp "$FIX/.claude/settings.json" "$PRE/settings.json.pre"
python3 -c "import json;p='$FIX/.claude/settings.json';d=json.load(open(p));d['enabledPlugins']={'kickoff@local':True};json.dump(d,open(p,'w'),indent=2)"
am record --path .claude/settings.json --action json-merged --class seam --source core-v0.2 --original-from "$PRE/settings.json.pre" >/dev/null

# hook-installed — the settings.local.json case: it holds LIVE SECRETS (planted fake token +
# posthog key). Record ONLY the jq-path; NO original bytes ever touch the manifest.
# Both planted secrets are shell vars (not source-literal credential strings), so the
# secret-scanner sees no hardcoded credential in this test's own source — same as $PLANT.
PLANT_PH="PLANTED_POSTHOG_KEY_do_not_store_a_fake_secret"
# The hook command is a NON-"kickoff" form (the real wire-memory-hook.sh install shape) — the
# recorded IDENTITY is a content hash, never the substring "kickoff" (Fix A). Its literal `.tmpl`
# below keeps the JSON heredoc byte-stable for the hash the caller computes.
cat > "$FIX/.claude/settings.local.json" <<EOF
{
  "telegram": { "botToken": "$PLANT" },
  "posthog": { "apiKey": "$PLANT_PH" },
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "\$CLAUDE_PROJECT_DIR/memory-retrieval/hook.mjs" } ] }
    ]
  }
}
EOF
# The caller computes the hook's content hash = sha256 of the CANONICAL json (`jq -S -c`) of the
# exact hook entry — never the file's secret bytes. record stores it alongside the jq-path.
HOOK_SHA="$(jq -S -c '.hooks.UserPromptSubmit[0]' "$FIX/.claude/settings.local.json" | sha256sum | awk '{print $1}')" || true
am record --path .claude/settings.local.json --action hook-installed --class seam --source core-v0.2 --jq-path '.hooks.UserPromptSubmit[0]' --hook-sha256 "$HOOK_SHA" >/dev/null

chk "manifest file written"                     "[ -f \"$MANIFEST\" ]"
chk "manifest valid JSON"                       "python3 -c \"import json;json.load(open('$MANIFEST'))\""
chk "top-level schema_version == 2 (§5 THE PLUGIN bumped it; v1 still READS free)" "python3 -c \"import json;assert json.load(open('$MANIFEST')).get('schema_version')==2\""
chk "exactly 5 entries recorded"                "python3 -c \"import json;assert len(json.load(open('$MANIFEST'))['entries'])==5\""
chk "every action is in the 5-action enum"      "python3 -c \"import json;E={'created','modified','block-appended','json-merged','hook-installed'};assert all(e['action'] in E for e in json.load(open('$MANIFEST'))['entries'])\""
chk "every class is in the enum"                "python3 -c \"import json;C={'seam','seeded-instance'};assert all(e['class'] in C for e in json.load(open('$MANIFEST'))['entries'])\""
chk "record REJECTS an unknown action"          "! python3 \"$AM\" record --path x --action frobnicated --class seam --source core-v0.2"
chk "record REJECTS an unknown class"           "! python3 \"$AM\" record --path .kickoff/bin/mc --action created --class bogus --source core-v0.2"
chk "record REJECTS a path escaping the repo"   "! python3 \"$AM\" record --path ../evil --action created --class seam --source core-v0.2"
echo

# ── (ii) byte-restore + hashes for a `modified` entry ───────────────────────────────
echo "2. a modified entry byte-restores EXACTLY + both sha256s are correct"
chk "modified 'original' byte-restores README EXACTLY (incl. no trailing newline + tab)" \
  "python3 -c \"import json,base64;m=json.load(open('$MANIFEST'));e=[x for x in m['entries'] if x['path']=='README.md'][0];open('$FIX/README.restored','wb').write(base64.b64decode(e['original']))\" && cmp -s \"$PRE/README.md.pre\" \"$FIX/README.restored\""
chk "modified records the correct sha256_before_edit" \
  "python3 -c \"import json,hashlib;m=json.load(open('$MANIFEST'));e=[x for x in m['entries'] if x['path']=='README.md'][0];assert e['sha256_before_edit']==hashlib.sha256(open('$PRE/README.md.pre','rb').read()).hexdigest()\""
chk "modified records the correct sha256_at_write" \
  "python3 -c \"import json,hashlib;m=json.load(open('$MANIFEST'));e=[x for x in m['entries'] if x['path']=='README.md'][0];assert e['sha256_at_write']==hashlib.sha256(open('$FIX/README.md','rb').read()).hexdigest()\""
chk "the two hashes DIFFER (a real edge, not a no-op edit)" \
  "python3 -c \"import json;m=json.load(open('$MANIFEST'));e=[x for x in m['entries'] if x['path']=='README.md'][0];assert e['sha256_before_edit']!=e['sha256_at_write']\""
# and the hardest case (Fix 2): the NON-jq-canonical 4-space settings.json restores exactly.
chk "json-merged 'original' byte-restores the 4-space settings.json EXACTLY" \
  "python3 -c \"import json,base64;m=json.load(open('$MANIFEST'));e=[x for x in m['entries'] if x['path']=='.claude/settings.json'][0];open('$FIX/settings.restored','wb').write(base64.b64decode(e['original']))\" && cmp -s \"$PRE/settings.json.pre\" \"$FIX/settings.restored\""
chk "'created' entry carries NO original (reversed by delete)" \
  "python3 -c \"import json;m=json.load(open('$MANIFEST'));e=[x for x in m['entries'] if x['path']=='.kickoff/bin/mc'][0];assert 'original' not in e and 'sha256_at_write' in e\""
echo

# ── (iii) the credential-safe proof (a failure here is a REAL secret-leak bug) ──────
echo "3. hook-installed is credential-safe (NO bytes, only jq-paths, secret ABSENT)"
chk "hook-installed entry present for settings.local.json" \
  "python3 -c \"import json;m=json.load(open('$MANIFEST'));e=[x for x in m['entries'] if x['path']=='.claude/settings.local.json'][0];assert e['action']=='hook-installed'\""
chk "hook-installed entry has NO 'original' key" \
  "python3 -c \"import json;m=json.load(open('$MANIFEST'));e=[x for x in m['entries'] if x['path']=='.claude/settings.local.json'][0];assert 'original' not in e\""
chk "hook-installed entry has NO hash of the secret file" \
  "python3 -c \"import json;m=json.load(open('$MANIFEST'));e=[x for x in m['entries'] if x['path']=='.claude/settings.local.json'][0];assert 'sha256_at_write' not in e and 'sha256_before_edit' not in e\""
chk "hook-installed entry records ONLY the jq-paths touched" \
  "python3 -c \"import json;m=json.load(open('$MANIFEST'));e=[x for x in m['entries'] if x['path']=='.claude/settings.local.json'][0];assert e.get('jq_paths')==['.hooks.UserPromptSubmit[0]']\""
chk "record REFUSES --original-from on a hook-installed action (code-level enforcement)" \
  "! python3 \"$AM\" record --path .claude/settings.local.json --action hook-installed --class seam --source core-v0.2 --jq-path '.x' --original-from \"$PRE/CLAUDE.md.pre\""
chk "the refused record wrote NOTHING (still exactly 5 entries)" \
  "python3 -c \"import json;assert len(json.load(open('$MANIFEST'))['entries'])==5\""
# THE proof: grep the ENTIRE written manifest for the planted secret → it MUST be absent.
chk "PLANTED SECRET is ABSENT from the entire manifest (credential-safe)" \
  "! grep -qF '$PLANT' \"$MANIFEST\""
chk "the planted secret really IS in the fixture (proves the grep would catch a leak)" \
  "grep -qF '$PLANT' \"$FIX/.claude/settings.local.json\""
# Fix A (record side): a hook-installed entry stores a CONTENT HASH per jq-path (hook_sha256s),
# aligned 1:1, so eject removes the hook by identity (never a substring / bare index). The hash is
# a 64-hex digest, NOT the secret bytes — the credential rule still holds on the new field.
chk "hook-installed records hook_sha256s aligned 1:1 with jq_paths (Fix A)" \
  "python3 -c \"import json;e=[x for x in json.load(open('$MANIFEST'))['entries'] if x['path']=='.claude/settings.local.json'][0];assert len(e.get('hook_sha256s',[]))==len(e.get('jq_paths',[]))==1\""
chk "hook_sha256s is a 64-hex content hash, NOT the secret bytes (credential-safe)" \
  "python3 -c \"import json,re;e=[x for x in json.load(open('$MANIFEST'))['entries'] if x['path']=='.claude/settings.local.json'][0];assert re.fullmatch(r'[0-9a-f]{64}', e['hook_sha256s'][0])\""
chk "the planted secret is ABSENT from the hook_sha256s field too (a hash is not bytes)" \
  "! python3 -c \"import json;e=[x for x in json.load(open('$MANIFEST'))['entries'] if x['path']=='.claude/settings.local.json'][0];import sys;sys.exit(0 if '$PLANT' in ''.join(e.get('hook_sha256s',[])) else 1)\""
chk "record REFUSES hook-installed with a jq-path/hook-sha256 count MISMATCH (Fix A)" \
  "! am record --path .claude/settings.local.json --action hook-installed --class seam --source core-vHB --jq-path '.a' --jq-path '.b' --hook-sha256 deadbeef"
echo

# ── (iv) verify: clean pass, then fail after a hand-edit ────────────────────────────
echo "4. verify passes clean, then FAILS after a recorded file is hand-edited"
chk "verify PASSES on the untouched fixture (exit 0)" \
  "python3 \"$AM\" verify"
# Hand-edit a recorded `created` file → its sha256 no longer matches sha256_at_write.
printf 'HAND-EDITED-AFTER-ADOPT\n' >> "$FIX/.kickoff/bin/mc"
chk "verify FAILS (non-zero) after the hand-edit" \
  "! python3 \"$AM\" verify"
# `|| true` neutralises verify's intentional exit-1 so pipefail lets grep's status decide.
chk "verify names the drifted file in its report" \
  "{ python3 \"$AM\" verify 2>&1 || true; } | grep -q '.kickoff/bin/mc'"
echo

# ── (B §1.4) gen-shim: the .kickoff/bin/mc SEAM shim ────────────────────────────────
echo "5. gen-shim generates the .kickoff/bin/mc seam (execs the PINNED engine; clear msg if absent)"
STUBCORE="$(mk)"                          # a stub core whose mc-update.py just ECHOES its args
mkdir -p "$STUBCORE/mission-control"
printf '#!/usr/bin/env python3\nimport sys\nprint("STUB-MC-ARGS: " + " ".join(sys.argv[1:]))\n' \
  > "$STUBCORE/mission-control/mc-update.py"
SHIMFIX="$(mk)"                           # a mock adopter repo whose instance.env points at the stub core
mkdir -p "$SHIMFIX/.kickoff"
printf 'export KICKOFF_CORE_DIR="%s"\n' "$STUBCORE" > "$SHIMFIX/.kickoff/instance.env"
python3 "$AM" gen-shim --repo "$SHIMFIX" --name mc --source core-vTEST >/dev/null
SHIM="$SHIMFIX/.kickoff/bin/mc"

chk "gen-shim wrote .kickoff/bin/mc"            "[ -f \"$SHIM\" ]"
chk "the mc shim is executable (0755)"          "[ \"\$(stat -c '%a' \"$SHIM\")\" = 755 ]"
chk "the shim is machine-path-free (no stub-core path baked in → stable hash)" \
  "! grep -qF \"$STUBCORE\" \"$SHIM\""
# engine PRESENT: the shim sources instance.env, finds the stub, passes args, exits 0.
shim_rc=0
shim_out="$("$SHIM" show foo bar 2>&1)" || shim_rc=$?
chk "mc shim exits 0 when the engine is present"          "[ $shim_rc -eq 0 ]"
chk "mc shim passes args through (STUB-MC-ARGS: show foo bar)" \
  "printf '%s' \"\$shim_out\" | grep -q 'STUB-MC-ARGS: show foo bar'"
# engine MISSING: rename the stub's mc-update.py → a CLEAR message + non-zero, never a raw bash error.
mv "$STUBCORE/mission-control/mc-update.py" "$STUBCORE/mission-control/mc-update.py.bak"
miss_rc=0
miss_out="$("$SHIM" show 2>&1)" || miss_rc=$?
chk "mc shim exits NON-zero when the engine is missing"   "[ $miss_rc -ne 0 ]"
chk "mc shim prints the CLEAR 'engine not present' message" \
  "printf '%s' \"\$miss_out\" | grep -q 'kickoff engine not present'"
chk "mc shim does NOT emit a raw bash 'No such file' error" \
  "! printf '%s' \"\$miss_out\" | grep -qi 'No such file'"
# manifest: the shim recorded as created/seam with a hash that matches the on-disk bytes.
MSHIM="$SHIMFIX/.kickoff/adopt-manifest.json"
chk "manifest recorded the mc shim as created/seam" \
  "python3 -c \"import json;e=[x for x in json.load(open('$MSHIM'))['entries'] if x['path']=='.kickoff/bin/mc'][0];assert e['action']=='created' and e['class']=='seam'\""
chk "manifest hash matches the on-disk shim bytes" \
  "python3 -c \"import json,hashlib;e=[x for x in json.load(open('$MSHIM'))['entries'] if x['path']=='.kickoff/bin/mc'][0];assert e['sha256_at_write']==hashlib.sha256(open('$SHIM','rb').read()).hexdigest()\""
echo

# ── (C §2.3 item 2) sync-seams on pull: regenerate unmodified, REFUSE hand-edited ───
echo "6. sync-seams (pull) regenerates an UNMODIFIED seam + REFUSES a hand-edited one"
OLD_SHIM=$'#!/usr/bin/env bash\n# OLD SHIM v0 (a superseded template)\nexec true\n'

# (i) UNMODIFIED-since-generation + template changed → regenerate + update the recorded hash.
#     Simulated by recording an OLD shim on disk; the current template differs → sync rewrites it.
SYNCI="$(mk)"; mkdir -p "$SYNCI/.kickoff/bin"
printf '%s' "$OLD_SHIM" > "$SYNCI/.kickoff/bin/mc"
python3 "$AM" record --repo "$SYNCI" --path .kickoff/bin/mc --action created --class seam --source core-vOLD >/dev/null
MI="$SYNCI/.kickoff/adopt-manifest.json"
old_rec=$(python3 -c "import json;print([x for x in json.load(open('$MI'))['entries'] if x['path']=='.kickoff/bin/mc'][0]['sha256_at_write'])")
python3 "$AM" sync-seams --repo "$SYNCI" --source core-vNEW >/dev/null
new_rec=$(python3 -c "import json;print([x for x in json.load(open('$MI'))['entries'] if x['path']=='.kickoff/bin/mc'][0]['sha256_at_write'])")
chk "unmodified seam: file no longer holds the OLD template (regenerated)" \
  "! grep -qF 'OLD SHIM v0' \"$SYNCI/.kickoff/bin/mc\""
chk "unmodified seam: file now IS the current template (execs the pinned engine)" \
  "grep -qF 'exec python3 \"\$_engine\" \"\$@\"' \"$SYNCI/.kickoff/bin/mc\""
chk "unmodified seam: recorded hash was UPDATED (old != new)"                 "[ \"$old_rec\" != \"$new_rec\" ]"
chk "unmodified seam: recorded hash now matches the regenerated file on disk" \
  "[ \"$new_rec\" = \"\$(sha256sum \"$SYNCI/.kickoff/bin/mc\" | awk '{print \$1}')\" ]"
chk "unmodified seam: provenance re-stamped to the new tag" \
  "python3 -c \"import json;e=[x for x in json.load(open('$MI'))['entries'] if x['path']=='.kickoff/bin/mc'][0];assert e['source']=='core-vNEW'\""

# (ii) HAND-EDITED since generation → REFUSE with a diff + name --force-regenerate + leave it be.
SYNCII="$(mk)"; mkdir -p "$SYNCII/.kickoff/bin"
printf '%s' "$OLD_SHIM" > "$SYNCII/.kickoff/bin/mc"
python3 "$AM" record --repo "$SYNCII" --path .kickoff/bin/mc --action created --class seam --source core-vOLD >/dev/null
printf '# HAND-EDIT by the operator\n' >> "$SYNCII/.kickoff/bin/mc"
edited_hash=$(sha256sum "$SYNCII/.kickoff/bin/mc" | awk '{print $1}')
sync_rc=0
sync_out="$(python3 "$AM" sync-seams --repo "$SYNCII" --source core-vNEW 2>&1)" || sync_rc=$?
chk "hand-edited seam: sync-seams exits NON-zero (pull blocked, fail-closed)" "[ $sync_rc -ne 0 ]"
chk "hand-edited seam: prints a unified diff (an @@ hunk)"        "printf '%s' \"\$sync_out\" | grep -q '@@'"
chk "hand-edited seam: names the --force-regenerate escape hatch" "printf '%s' \"\$sync_out\" | grep -q -- '--force-regenerate'"
chk "hand-edited seam: file left UNTOUCHED (refused, not overwritten)" \
  "[ \"$edited_hash\" = \"\$(sha256sum \"$SYNCII/.kickoff/bin/mc\" | awk '{print \$1}')\" ]"
# and the escape hatch: --force-regenerate DISCARDS the hand-edit + restores the template.
python3 "$AM" sync-seams --repo "$SYNCII" --source core-vNEW --force-regenerate >/dev/null
chk "hand-edited seam: --force-regenerate restores the pinned template" \
  "! grep -qF 'HAND-EDIT by the operator' \"$SYNCII/.kickoff/bin/mc\""

# integration: cmd_pull actually WIRES sync-seams (after the core.lock write, before preflight).
chk "cmd_pull wires the seam-sync step (kickoff calls sync-seams)" \
  "grep -q 'sync-seams --repo' \"$REPO/scripts/kickoff\""
echo

# ── (D Fix 9) preflight #8: adopter seam integrity, fail-closed absence + drift ─────
echo "7. preflight #8 verifies adopter seams (fail-closed on missing manifest / drift; skips non-adopter)"

# Build a fixture that runs a COPY of the (edited) preflight.sh, so RUNNING_CORE_DIR resolves
# INTO the fixture and we control the adopter predicate. A fully-valid instance.env makes the
# OTHER 7 checks pass, so the whole-preflight exit code reflects #8's verdict.
build_preflight_fixture() {   # $1 = adopter|nonadopter → echoes the fixture dir
  local kind="$1" fx
  fx="$(mk)"
  mkdir -p "$fx/scripts" "$fx/.kickoff/bin" "$fx/memory" "$fx/chan"
  cp "$REPO/scripts/preflight.sh" "$fx/scripts/preflight.sh"
  cat > "$fx/.kickoff/instance.env" <<EOF
export TELEGRAM_STATE_DIR="$fx/chan"
export MC_STATE_FILE="$fx/.kickoff/state/mission-state.json"
export MEMORY_DB="$fx/.kickoff/state/memory-index.db"
export MEMORY_HOOK_LOG="$fx/.kickoff/state/memory-hook.log"
EOF
  printf '# memory index\n' > "$fx/memory/MEMORY.md"
  python3 "$AM" gen-shim --repo "$fx" --name mc --source core-vDTEST >/dev/null   # a real seam + receipt
  if [ "$kind" = "adopter" ]; then
    # core.lock present → ADOPTER (predicate clause 1) AND #6 verifies it against KICKOFF_CORE_DIR
    # = <fx> = RUNNING_CORE_DIR (the copied preflight), so #6's running-core assertion (#14) holds.
    ( cd "$fx" && sha256sum scripts/preflight.sh ) > "$fx/.kickoff/core.lock"
  fi
  printf '%s' "$fx"
}
run_preflight_fixture() {     # $1 = fixture → sets PF_OUT + PF_RC
  local fx="$1"
  PF_RC=0
  PF_OUT="$(REPO_DIR="$fx" KICKOFF_CORE_DIR="$fx" bash "$fx/scripts/preflight.sh" 2>&1)" || PF_RC=$?
}

# (i) adopter, all matching → whole preflight exits 0 AND #8 reports integrity.
DFA="$(build_preflight_fixture adopter)"; run_preflight_fixture "$DFA"
chk "adopter, all matching: whole preflight exits 0 (every check incl #8 passes)" "[ $PF_RC -eq 0 ]"
chk "adopter, all matching: #8 reports seam integrity verified" \
  "printf '%s' \"\$PF_OUT\" | grep -q 'seam integrity verified'"
# (ii) delete the manifest → #8 FAILs, names BOTH recoveries: `kickoff adopt --reconcile` for the
# ALREADY-adopted shape (core.lock + no manifest — the exact fixture here; G9 made it real) and
# plain `kickoff adopt` for the never-wired one.
DFB="$(build_preflight_fixture adopter)"; rm -f "$DFB/.kickoff/adopt-manifest.json"; run_preflight_fixture "$DFB"
chk "missing manifest: preflight FAILS (non-zero — fail-closed absence)" "[ $PF_RC -ne 0 ]"
chk "missing manifest: #8 names \`kickoff adopt --reconcile\` for the already-adopted shape (G9)" \
  "printf '%s' \"\$PF_OUT\" | grep -q -- 'kickoff adopt --reconcile'"
chk "missing manifest: #8 still names plain \`kickoff adopt\` for the never-wired shape" \
  "printf '%s' \"\$PF_OUT\" | grep -q 'kickoff adopt\`'"
# (iii) hand-edit the seam → #8 FAILs, flags the seam path + the NOT-anti-tamper caveat.
DFC="$(build_preflight_fixture adopter)"; printf '\n# HAND-EDIT\n' >> "$DFC/.kickoff/bin/mc"; run_preflight_fixture "$DFC"
chk "hand-edited seam: preflight FAILS (non-zero)" "[ $PF_RC -ne 0 ]"
chk "hand-edited seam: #8 flags the drifted seam path" "printf '%s' \"\$PF_OUT\" | grep -q '.kickoff/bin/mc'"
chk "hand-edited seam: #8 states the NOT-anti-tamper caveat (unsigned)" \
  "printf '%s' \"\$PF_OUT\" | grep -qi 'anti-tamper'"
# (iv) non-adopter (no core.lock, core inside repo) → #8 SKIPS, preflight exits 0.
DFN="$(build_preflight_fixture nonadopter)"; run_preflight_fixture "$DFN"
chk "non-adopter: whole preflight exits 0" "[ $PF_RC -eq 0 ]"
chk "non-adopter: #8 SKIPS with an ok() line" \
  "printf '%s' \"\$PF_OUT\" | grep -q 'adopt-manifest seam check skipped'"
echo

# ── (E) supervisor.log rotation is COPYTRUNCATE (keeps the open-fd's inode) ─────────
echo "8. supervisor.log rotation is COPYTRUNCATE — bounds the log without orphaning the open fd"
ROT="$REPO/scripts/rotate-log.sh"
ELOG="$(mk)"

# over cap → .log.1 gets the exact old bytes, .log truncates to 0, and .log keeps the SAME inode.
LOGF="$ELOG/supervisor.log"
head -c 4096 /dev/zero | tr '\0' 'x' > "$LOGF"       # 4096 bytes > a 1024-byte test cap
cp "$LOGF" "$ELOG/orig"
inode_before="$(stat -c %i "$LOGF")"
LOG_MAX_BYTES=1024 bash "$ROT" "$LOGF" >/dev/null
inode_after="$(stat -c %i "$LOGF")"
chk "over cap: .log.1 holds the EXACT old content"        "cmp -s \"$ELOG/orig\" \"$LOGF.1\""
chk "over cap: .log truncated to 0 bytes"                 "[ \"\$(wc -c < \"$LOGF\")\" -eq 0 ]"
chk "over cap: .log keeps the SAME inode (proves COPYTRUNCATE, not mv)" "[ \"$inode_before\" = \"$inode_after\" ]"

# THE proof: an already-open O_APPEND fd must keep writing into .log AFTER rotation. With `mv`
# the fd would follow the inode into .log.1 and .log would stay empty forever — the exact bug.
LIVE="$ELOG/live.log"
: > "$LIVE"
exec 9>>"$LIVE"                                      # like the supervisor's redirected stdout
head -c 4096 /dev/zero | tr '\0' 'y' >&9             # grow past cap THROUGH the open fd
LOG_MAX_BYTES=1024 bash "$ROT" "$LIVE" >/dev/null    # rotate (a separate process, as in the loop)
printf 'AFTER_ROTATE_MARKER\n' >&9                   # write via the SAME open fd, post-rotation
exec 9>&-
chk "open fd: post-rotation write LANDS in .log (copytruncate kept the inode)" \
  "grep -q AFTER_ROTATE_MARKER \"$LIVE\""
chk "open fd: post-rotation write did NOT leak into .log.1 (an mv-rotation would put it there)" \
  "! grep -q AFTER_ROTATE_MARKER \"$LIVE.1\""

# below cap → no rotation (idempotent + cheap to call every poll).
SMALL="$ELOG/small.log"
printf 'tiny\n' > "$SMALL"
LOG_MAX_BYTES=1024 bash "$ROT" "$SMALL" >/dev/null
chk "below cap: no .log.1 created" "[ ! -f \"$SMALL.1\" ]"
chk "below cap: .log left intact"  "[ \"\$(wc -c < \"$SMALL\")\" -gt 0 ]"

# both launch paths use the ONE shared helper (not two forked rotation bodies).
chk "supervisor.sh sources rotate-log.sh + calls rotate_log in its loop" \
  "grep -q 'rotate-log.sh' \"$REPO/scripts/supervisor.sh\" && grep -q 'rotate_log \"\$SUPERVISOR_LOG\"' \"$REPO/scripts/supervisor.sh\""
chk "go-autonomous.sh uses the shared rotate-log.sh helper (no inline mv-rotation)" \
  "grep -q 'rotate-log.sh' \"$REPO/scripts/go-autonomous.sh\" && grep -q 'rotate_log \"\$LOG\"' \"$REPO/scripts/go-autonomous.sh\""
echo

# ── (review-hardening) path-based credential backstop + verify escape guard ─────────
echo "9. review-hardening: credential PATH-backstop + verify escape-guard (adversarial-review fixes)"
# Fix 1: settings.local.json may be recorded ONLY as hook-installed. A byte-restore action (the
# "natural" json-merged) must be REFUSED — else the live secret bytes would be base64'd into the
# manifest. Reuses section 3's fixture ($FIX/.claude/settings.local.json holds $PLANT + $PLANT_PH).
chk "record REFUSES settings.local.json as json-merged (PATH backstop, not just hook-installed)" \
  "! am record --path .claude/settings.local.json --action json-merged --class seam --source core-vHB --original-from \"$FIX/.claude/settings.local.json\""
chk "record REFUSES settings.local.json as modified too (any byte-restore action)" \
  "! am record --path .claude/settings.local.json --action modified --class seam --source core-vHB --original-from \"$FIX/.claude/settings.local.json\""
chk "after the refused byte-restore records, the planted secret is STILL absent from the manifest" \
  "! grep -q \"$PLANT\" \"$MANIFEST\""
# Fix 2: verify must reject an absolute / ..-escaping entry path in a crafted manifest (as record()
# + preflight #8 do), never silently sha256 a file OUTSIDE the repo.
VFX="$(mk)"; mkdir -p "$VFX/.kickoff"
printf '{"schema_version":1,"entries":[{"path":"/etc/hostname","action":"created","class":"seam","source":"x","sha256_at_write":"deadbeef"}]}\n' > "$VFX/.kickoff/adopt-manifest.json"
vrc=0; vout="$(REPO_DIR="$VFX" python3 "$AM" verify 2>&1)" || vrc=$?
chk "verify FAILS (non-zero) on an absolute/escaping entry path" "[ \"$vrc\" -ne 0 ]"
chk "verify names the escape + refuses to hash outside the repo" "printf '%s' \"$vout\" | grep -q 'ESCAPES the repo'"
echo

# ── (R2) .kickoff/README seam: adopt GENERATES + RECORDS it; eject REMOVES it zero-trace ────
echo "10. .kickoff/README seam — adopt generates + records it (created/seam); eject removes it zero-trace"
# The shims + charter print "see .kickoff/README", but nothing created that file — a DANGLING
# reference. gen-readme (the R2 verb cmd_adopt now calls) writes it from the pinned template as a
# created/seam, so it travels/pins/regenerates like .gitignore AND eject reverses it byte-for-byte.
# RED before the fix: gen-readme did not exist → the README-exists assertion fails.
if command -v git >/dev/null 2>&1; then
  RDFIX="$(mk)"; RDARCH="$(mk)"
  mkdir -p "$RDFIX/.claude" "$RDFIX/.kickoff/state/facts"
  git -C "$RDFIX" init -q; git -C "$RDFIX" config user.email t@t.t; git -C "$RDFIX" config user.name t
  printf '# Repo\n\noperator rules.\n' > "$RDFIX/CLAUDE.md"; printf 'src\n' > "$RDFIX/app.txt"
  git -C "$RDFIX" add -A; git -C "$RDFIX" commit -qm baseline
  cat > "$RDFIX/.kickoff/instance.env" <<EOF
export TELEGRAM_STATE_DIR="$RDFIX/.kickoff/chan"
export MC_STATE_FILE="$RDFIX/.kickoff/state/mission-state.json"
export MEMORY_DB="$RDFIX/.kickoff/state/memory-index.db"
export MEMORY_INDEX="$RDFIX/.kickoff/state/MEMORY.md"
export MEMORY_DIR="$RDFIX/.kickoff/state/facts"
export MEMORY_HOOK_LOG="$RDFIX/.kickoff/state/memory-hook.log"
EOF
  printf 'x\n' > "$RDFIX/.kickoff/state/mission-state.json"; printf 'x\n' > "$RDFIX/.kickoff/state/memory-index.db"
  printf 'x\n' > "$RDFIX/.kickoff/state/MEMORY.md";          printf 'x\n' > "$RDFIX/.kickoff/state/memory-hook.log"
  # the seams a real adopt lays down (gen-shim + gen-gitignore are pre-existing; gen-readme is R2)
  python3 "$AM" gen-shim      --repo "$RDFIX" --name mc --source core-vRD >/dev/null
  python3 "$AM" gen-gitignore --repo "$RDFIX" --source core-vRD >/dev/null
  RDMAN="$RDFIX/.kickoff/adopt-manifest.json"
  # gen-readme with rc capture so a pre-fix MISSING verb REDs the assertions (not a set -e abort).
  rd_rc=0; python3 "$AM" gen-readme --repo "$RDFIX" --source core-vRD >/dev/null 2>&1 || rd_rc=$?
  chk "gen-readme exits 0 (the verb cmd_adopt calls)"            "[ $rd_rc -eq 0 ]"
  chk "adopt generates .kickoff/README (0644)" \
    "[ -f \"$RDFIX/.kickoff/README\" ] && [ \"\$(stat -c '%a' \"$RDFIX/.kickoff/README\")\" = 644 ]"
  chk "README is machine-path-free (byte-identical to the pinned template → stable seam hash)" \
    "cmp -s \"$RDFIX/.kickoff/README\" \"$REPO/scripts/templates/kickoff-README.md\""
  chk "adopt RECORDS .kickoff/README as created/seam with the on-disk hash" \
    "python3 -c \"import json,hashlib;e=[x for x in json.load(open('$RDMAN'))['entries'] if x['path']=='.kickoff/README'][0];assert e['action']=='created' and e['class']=='seam' and e['sha256_at_write']==hashlib.sha256(open('$RDFIX/.kickoff/README','rb').read()).hexdigest()\""
  chk "cmd_adopt WIRES gen-readme (front door calls it, not just the verb existing)" \
    "grep -q 'gen-readme --repo' \"$REPO/scripts/kickoff\""
  # eject the README-bearing footprint → the seam is reversed, leaving zero git trace.
  erc=0; REPO_DIR="$RDFIX" bash "$REPO/scripts/kickoff" eject --dir "$RDFIX" --verify \
      --archive-dir "$RDARCH" --delete-data --confirm-destroy >/dev/null 2>&1 || erc=$?
  chk "eject exits 0 on the README-bearing footprint"           "[ $erc -eq 0 ]"
  chk "eject REMOVED .kickoff/README (recorded seam → deleted)" "[ ! -e \"$RDFIX/.kickoff/README\" ]"
  chk "eject zero-trace: git status --porcelain is CLEAN (README left no residue)" \
    "[ -z \"\$(git -C \"$RDFIX\" status --porcelain)\" ]"
else
  echo "  (git not found — skipping the README adopt→eject lifecycle proof)"
fi
echo

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# core-v0.3.1 Fix B + Fix C — the first-adopter fixes, proven end-to-end via REAL
# `kickoff adopt` (the front door, not the unit verbs above). Both need a stub `claude` (encodes the
# local-path plugin enablement — it writes .claude/settings.json with the marketplace source = an
# ABSOLUTE core path, the exact non-portable footgun) + a minimal git-tagged core with a plugin/.
# HERMETIC + ISOLATED: the stub HARD-REFUSES without CLAUDE_CONFIG_DIR + refuses to write a project
# settings.json outside a temp dir; every adopt/eject pins KICKOFF_ADOPTERS_REGISTRY + CLAUDE_CONFIG_DIR
# at SCRATCH — the live ~/.claude + ~/.kickoff are never read or written.
# ══════════════════════════════════════════════════════════════════════════════════════════════════
FIXBC_OK=1
command -v git >/dev/null 2>&1 || { FIXBC_OK=0; echo "  (git not found — skipping the Fix B/C real-adopt proofs)"; echo; }

write_stub_claude() {   # $1 = dir to place the `claude` stub in
  cat > "$1/claude" <<'PYEOF'
#!/usr/bin/env python3
# Minimal hermetic stub of `claude plugin ...` — models ONLY what adopt's plugin arm calls
# (marketplace add + install at --scope project), writing .claude/settings.json under $CWD with the
# marketplace source = the ABSOLUTE plugin path (the non-portable core path Fix B gitignores).
import json, os, sys, tempfile
if not os.environ.get("CLAUDE_CONFIG_DIR"):
    sys.stderr.write("stub-claude: CLAUDE_CONFIG_DIR unset — refusing (test isolation guard)\n"); sys.exit(3)
a = sys.argv[1:]
if not a or a[0] != "plugin": sys.exit(0)
a = a[1:]
scope, pos, i = "user", [], 0
while i < len(a):
    if a[i] in ("--scope", "-s") and i + 1 < len(a): scope = a[i + 1]; i += 2; continue
    pos.append(a[i]); i += 1
def proj(): return os.path.join(os.getcwd(), ".claude", "settings.json")
def guard(p):
    rp = os.path.realpath(p)
    roots = {os.path.realpath(r) for r in (tempfile.gettempdir(), os.environ.get("TMPDIR"), "/tmp") if r}
    if not any(rp == r or rp.startswith(r + os.sep) for r in roots):
        sys.stderr.write("stub-claude: REFUSING settings.json write outside a temp dir: %s\n" % rp); sys.exit(4)
def load():
    try: return json.load(open(proj()))
    except Exception: return {}
def save(d):
    guard(proj()); os.makedirs(os.path.dirname(proj()), exist_ok=True); json.dump(d, open(proj(), "w"), indent=2)
if pos[:2] == ["marketplace", "add"]:
    src = os.path.abspath(pos[2]); name = json.load(open(os.path.join(src, ".claude-plugin", "marketplace.json")))["name"]
    if scope == "project":
        d = load(); d.setdefault("extraKnownMarketplaces", {})[name] = {"source": {"source": "directory", "path": src}}; save(d)
    print("added %s" % name); sys.exit(0)
if pos and pos[0] in ("install", "i"):
    if scope == "project":
        d = load(); d.setdefault("enabledPlugins", {})[pos[1]] = True; save(d)
    print("installed %s" % pos[1]); sys.exit(0)
sys.exit(0)
PYEOF
  chmod +x "$1/claude"
}

# A minimal git core: a plugin/ (marketplace.json + plugin.json), tagged core-vT on a clean tree.
build_min_core() {
  local core; core="$(mk)"
  mkdir -p "$core/plugin/.claude-plugin"
  git -C "$core" init -q; git -C "$core" config user.email t@t.t; git -C "$core" config user.name t
  printf '{ "name": "kickoff", "version": "0.3.1", "description": "min core", "author": {"name":"k"} }\n' > "$core/plugin/.claude-plugin/plugin.json"
  printf '{ "name": "kickoff-local", "description": "min mkt", "owner": {"name":"k"}, "plugins": [ {"name":"kickoff","source":"./","description":"x"} ] }\n' > "$core/plugin/.claude-plugin/marketplace.json"
  git -C "$core" add -A; git -C "$core" commit -qm core-vT; git -C "$core" tag core-vT
  printf '%s' "$core"
}

# Run a real `kickoff adopt` on $1 against core $2 / stub $3 / cfg $4 / registry $5, with the ambient
# REPO_DIR/TELEGRAM_STATE_DIR = $6/$7 (the pollution — pass "" to run REPO_DIR=<target>, chan unset).
run_real_adopt() {   # target core stub cfg reg pollute_repo pollute_chan
  REPO_DIR="${6:-$1}" TELEGRAM_STATE_DIR="${7:-}" \
    KICKOFF_ADOPTERS_REGISTRY="$5" KICKOFF_CORE_DIR="$2" CLAUDE_CONFIG_DIR="$4" PATH="$3:$PATH" \
    bash "$REPO/scripts/kickoff" adopt --dir "$1" >/dev/null 2>&1 || true
}

if [ "$FIXBC_OK" = 1 ]; then
  echo "11. Fix B — adopt gitignores the plugin-enabled .claude/settings.json + records it eject-reversibly"
  BCORE="$(build_min_core)"

  # (a) PRE-EXISTING root .gitignore → adopt APPENDS (recorded modified/seam, byte-restore on eject).
  BSTUB="$(mk)"; write_stub_claude "$BSTUB"; BADO="$(mk)"; BCFG="$(mk)"; BREG="$(mk)/adopters.json"
  git -C "$BADO" init -q; git -C "$BADO" config user.email t@t.t; git -C "$BADO" config user.name t
  printf 'node_modules/\n*.log\n' > "$BADO/.gitignore"; printf '# repo\n' > "$BADO/README.md"
  git -C "$BADO" add -A; git -C "$BADO" commit -qm baseline
  run_real_adopt "$BADO" "$BCORE" "$BSTUB" "$BCFG" "$BREG" "" ""
  BMAN="$BADO/.kickoff/adopt-manifest.json"
  chk "Fix B(present): adopt created .claude/settings.json (the plugin arm ran)" "[ -f \"$BADO/.claude/settings.json\" ]"
  chk "Fix B(present): settings.json holds the ABSOLUTE core path (the footgun a git add -A would commit)" \
    "grep -qF \"$BCORE/plugin\" \"$BADO/.claude/settings.json\""
  chk "Fix B(present): git check-ignore .claude/settings.json SUCCEEDS (now ignored)" \
    "git -C \"$BADO\" check-ignore -q .claude/settings.json"
  chk "Fix B(present): a blanket status -uall does NOT surface .claude/settings.json (git add -A won't stage it)" \
    "! git -C \"$BADO\" status --porcelain -uall | grep -q '\\.claude/settings\\.json'"
  chk "Fix B(present): the .gitignore touch is recorded modified/seam WITH pre-edit original bytes (byte-restore)" \
    "python3 -c \"import json;e=[x for x in json.load(open('$BMAN'))['entries'] if x['path']=='.gitignore'][0];assert e['action']=='modified' and e['class']=='seam' and e.get('original')\""
  chk "Fix B(present): the operator's pre-existing .gitignore lines are PRESERVED (append, not clobber)" \
    "grep -qx 'node_modules/' \"$BADO/.gitignore\""
  bde_out="$(REPO_DIR="$BADO" KICKOFF_ADOPTERS_REGISTRY="$BREG" KICKOFF_CORE_DIR="$BCORE" CLAUDE_CONFIG_DIR="$BCFG" PATH="$BSTUB:$PATH" bash "$REPO/scripts/kickoff" eject --dir "$BADO" --dry-run --no-archive 2>&1 || true)"
  chk "Fix B(present): eject --dry-run WOULD byte-restore the root .gitignore (it pre-existed)" \
    "printf '%s' \"\$bde_out\" | grep ' \\.gitignore ' | grep -qi 'byte-restore'"

  # (b) ABSENT root .gitignore → adopt CREATES it (recorded created/live-config, reversed by delete).
  ASTUB="$(mk)"; write_stub_claude "$ASTUB"; AADO="$(mk)"; ACFG="$(mk)"; AREG="$(mk)/adopters.json"
  git -C "$AADO" init -q; git -C "$AADO" config user.email t@t.t; git -C "$AADO" config user.name t
  printf '# repo\n' > "$AADO/README.md"                    # NO root .gitignore
  git -C "$AADO" add -A; git -C "$AADO" commit -qm baseline
  run_real_adopt "$AADO" "$BCORE" "$ASTUB" "$ACFG" "$AREG" "" ""
  AMAN="$AADO/.kickoff/adopt-manifest.json"
  chk "Fix B(absent): adopt CREATED the root .gitignore" "[ -f \"$AADO/.gitignore\" ]"
  chk "Fix B(absent): git check-ignore .claude/settings.json SUCCEEDS" \
    "git -C \"$AADO\" check-ignore -q .claude/settings.json"
  chk "Fix B(absent): a blanket status -uall does NOT surface .claude/settings.json" \
    "! git -C \"$AADO\" status --porcelain -uall | grep -q '\\.claude/settings\\.json'"
  # created/live-config (NOT seam): a root .gitignore is operator-edited; created/seam is whole-file-
  # hashed by preflight #8 → an operator edit would false-fail the worker. live-config is excluded.
  chk "Fix B(absent): the .gitignore is recorded created/live-config (NOT the created/seam #8 hashes)" \
    "python3 -c \"import json;e=[x for x in json.load(open('$AMAN'))['entries'] if x['path']=='.gitignore'][0];assert e['action']=='created' and e['class']=='live-config'\""
  ade_out="$(REPO_DIR="$AADO" KICKOFF_ADOPTERS_REGISTRY="$AREG" KICKOFF_CORE_DIR="$BCORE" CLAUDE_CONFIG_DIR="$ACFG" PATH="$ASTUB:$PATH" bash "$REPO/scripts/kickoff" eject --dir "$AADO" --dry-run --no-archive 2>&1 || true)"
  chk "Fix B(absent): eject --dry-run WOULD DELETE the created root .gitignore" \
    "printf '%s' \"\$ade_out\" | grep ' \\.gitignore ' | grep -qi 'delete'"

  # (c) the preflight-#8 safety property, explicit: NO .gitignore entry is created/seam (the ONLY
  #     shape #8 whole-file-hashes → the one that would brick a worker when the operator edits it).
  chk "Fix B: no .gitignore entry is created/seam (preflight #8 never whole-file-hashes it)" \
    "python3 -c \"import json;bad=[e for m in ['$BMAN','$AMAN'] for e in json.load(open(m))['entries'] if e['path']=='.gitignore' and e['action']=='created' and e['class']=='seam'];assert not bad\""
  echo
fi

if [ "$FIXBC_OK" = 1 ]; then
  echo "12. Fix C — adopt does NOT leak the CALLING session's env into the adoptee (corpus + channel)"
  CCORE="$(build_min_core)"; CSTUB="$(mk)"; write_stub_claude "$CSTUB"
  CADO="$(mk)"; CCFG="$(mk)"; CREG="$(mk)/adopters.json"
  git -C "$CADO" init -q; git -C "$CADO" config user.email t@t.t; git -C "$CADO" config user.name t
  printf '# repo\n' > "$CADO/README.md"; git -C "$CADO" add -A; git -C "$CADO" commit -qm baseline
  # THE POLLUTION — an EXISTING caller repo + channel (the front door requires REPO_DIR to exist),
  # distinct from the target: models `kickoff adopt` run from INSIDE another worker's live session.
  CBOGUS_REPO="$(mk)"; CBOGUS_CHAN="$(mk)"; mkdir -p "$CBOGUS_REPO/.kickoff/memory"
  run_real_adopt "$CADO" "$CCORE" "$CSTUB" "$CCFG" "$CREG" "$CBOGUS_REPO" "$CBOGUS_CHAN"

  # (1) CORPUS — the stamped MEMORY_DIR resolves to the TARGET in a CLEAN env (cwd=/, REPO_DIR unset):
  #     pre-fix it was ${REPO_DIR:-$PWD}/.kickoff/memory (caller/cwd-dependent); post-fix it is the
  #     absolute target path stamped at adopt time.
  C_MEMDIR="$(cd / && unset REPO_DIR MEMORY_DIR; set +u; . "$CADO/.kickoff/instance.env" >/dev/null 2>&1 || true; printf '%s' "${MEMORY_DIR:-}")"
  chk "Fix C(corpus): stamped MEMORY_DIR resolves to the TARGET in a clean env (not the caller/cwd)" \
    "[ \"$C_MEMDIR\" = \"$CADO/.kickoff/memory\" ]"
  chk "Fix C(corpus): MEMORY_DIR did NOT resolve into the leaked caller REPO_DIR" \
    "[ -n \"$C_MEMDIR\" ] && ! printf '%s' \"$C_MEMDIR\" | grep -qF \"$CBOGUS_REPO\""

  # (2) CHANNEL — the adopters-registry row for THIS target has NO channel (the operator sets it
  #     later); pre-fix the caller's TELEGRAM_STATE_DIR leaked through ${TELEGRAM_STATE_DIR:-}.
  chk "Fix C(channel): the target registered with an EMPTY channel (no caller-channel leak)" \
    "python3 -c \"import json,os;reg=json.load(open('$CREG'))['adopters'];row=[a for a in reg if os.path.realpath(a['repo'])==os.path.realpath('$CADO')][0];assert not row.get('channel')\""
  chk "Fix C(channel): the caller's channel path is ABSENT from the entire registry" \
    "! grep -qF \"$CBOGUS_CHAN\" \"$CREG\""
  echo
fi

echo "──────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "  ✅ adopt-manifest keystone holds"; exit 0; } || { echo "  ❌ see failures above"; exit 1; }
