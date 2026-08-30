#!/usr/bin/env bash
# eject-selftest.sh — prove `kickoff eject` provably de-integrates kickoff from an adopter repo.
#
#   bash scripts/eject-selftest.sh
#
# Mirrors adopt-selftest.sh (mktemp fixture + ok/bad/chk asserts). eject is the reverse of adopt,
# driven ENTIRELY by the adopt-manifest. The suite proves, in layers:
#   (A)  the `reverse` verb (adopt-manifest.py) — the reversal engine — round-trips all 5 actions,
#        is credential-safe on the secret-bearing settings.local.json, and NEVER clobbers a
#        post-adopt edit (the no-clobber divergence discipline). Exercised directly, no bash CLI.
#   (B)  the acceptance test that GATES the tag: adopt → `kickoff eject` on a fixture with a
#        pre-existing .claude/ + a NON-jq-canonical settings.json + a pre-existing lefthook
#        pre-commit key → `git status --porcelain` empty afterward, the secret never archived.
#   (C)  hardening: leave-relocation, block-appended surgical fallback, --purge, the divergence
#        fail-safe, and the destructive gate (--no-archive --delete-data refuses without confirm).
#
# The three inviolable invariants proven throughout: CREDENTIAL SAFETY (the secret never leaves
# the file into an archive/log/stdout), DESTRUCTION FAIL-SAFE (archive-on + leave + keep-crew by
# default; no silent delete of a diverged file), NO CLOBBER (every drift branch preserves + reports).
#
# Exits non-zero on ANY failed assertion. Deps: python3 + jq + coreutils + grep + tar + git.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
AM="$REPO/scripts/adopt-manifest.py"
KICKOFF="$REPO/scripts/kickoff"

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

# The literal fake secrets planted in the fixture settings.local.json — they must NEVER reach an
# archive, a log, or eject's stdout/stderr (the whole point of the hook-installed credential rule).
# Both are shell vars (not source-literal credentials), so the secret-scanner sees no hardcoded
# credential in this test's own source — same posture as adopt-selftest.sh.
PLANT='FAKE_TELEGRAM_TOKEN_planted_do_not_store_123'
PLANT_PH='PLANTED_POSTHOG_KEY_do_not_store_a_fake_secret'

# The recorded hook IDENTITY is a CONTENT HASH (Fix A), computed exactly as the real adopt-install
# step will: sha256 of the CANONICAL json (`jq -S -c '<jq_path>' file`) of the exact hook entry.
# Every hook fixture below uses a NON-"kickoff" command (the real memory-hook form) — the old
# substring probe FALSE-NEGATIVED on these, leaving kickoff's hook as residue; the hash matches by
# content, wherever the element moved and whatever its command text.
hook_sha() { jq -S -c "$2" "$1" | sha256sum | awk '{print $1}'; }   # hook_sha <file> <jq_path>

# One EXIT trap cleans every mktemp dir — via a file side-effect so dirs mk() makes inside a
# $(command-substitution) subshell survive (an in-memory array would be lost there).
CLEANUP_LIST="$(mktemp)"
mk() { local d; d="$(mktemp -d)"; printf '%s\n' "$d" >> "$CLEANUP_LIST"; printf '%s' "$d"; }
trap 'while IFS= read -r _d; do [ -n "$_d" ] && rm -rf "$_d"; done < "$CLEANUP_LIST"; rm -f "$CLEANUP_LIST"' EXIT

echo "▶ kickoff eject self-test"
echo

if ! command -v python3 >/dev/null 2>&1; then echo "  ❌ python3 not found"; exit 1; fi
if ! command -v jq      >/dev/null 2>&1; then echo "  ❌ jq not found — eject needs jq to reverse a hook-installed entry"; exit 1; fi
if ! command -v git     >/dev/null 2>&1; then echo "  ❌ git not found — the acceptance test needs git"; exit 1; fi

# ══════════════════════════════════════════════════════════════════════════════════════
# (A) the `reverse` verb — the reversal engine, exercised directly (independent of the CLI)
# ══════════════════════════════════════════════════════════════════════════════════════
echo "1. reverse: all 5 recorded actions round-trip; hook-installed is credential-safe"
RFIX="$(mk)"; RPRE="$(mk)"
mkdir -p "$RFIX/.kickoff/bin" "$RFIX/.claude"

# created — a generated shim; reversed by delete, no original bytes.
printf '#!/usr/bin/env bash\nexec true\n' > "$RFIX/.kickoff/bin/mc"
python3 "$AM" record --repo "$RFIX" --path .kickoff/bin/mc --action created --class seam --source core-v0.2 >/dev/null

# modified — a plain edit. Pre-edit bytes end WITHOUT a trailing newline + carry a tab, so
# "byte-exact restore" is a real test, not a lucky line-match.
printf 'line A\nline B\n\ttab-indented line\nfinal line no trailing newline' > "$RFIX/README.md"
cp "$RFIX/README.md" "$RPRE/README.md.pre"
printf 'line A\nline B\n\ttab-indented line\nfinal line no trailing newline\nAPPENDED-BY-KICKOFF\n' > "$RFIX/README.md"
python3 "$AM" record --repo "$RFIX" --path README.md --action modified --class seam --source core-v0.2 --original-from "$RPRE/README.md.pre" >/dev/null

# block-appended — the marker-delimited @import block into an existing CLAUDE.md.
printf '# My Repo\n\nExisting operator instructions.\n' > "$RFIX/CLAUDE.md"
cp "$RFIX/CLAUDE.md" "$RPRE/CLAUDE.md.pre"
printf '\n<!-- kickoff:begin core-v0.2 -->\n@.kickoff/KICKOFF.md\n<!-- kickoff:end -->\n' >> "$RFIX/CLAUDE.md"
python3 "$AM" record --repo "$RFIX" --path CLAUDE.md --action block-appended --class seam --source core-v0.2 --original-from "$RPRE/CLAUDE.md.pre" >/dev/null

# json-merged — a NON-jq-canonical (4-space) settings.json; a jq merge re-indents to 2-space, so
# only a byte-restore reproduces the exact pre-adopt bytes.
printf '{\n    "enableAllProjectMcpServers": false\n}\n' > "$RFIX/.claude/settings.json"
cp "$RFIX/.claude/settings.json" "$RPRE/settings.json.pre"
python3 -c "import json;p='$RFIX/.claude/settings.json';d=json.load(open(p));d['enabledPlugins']={'kickoff@local':True};json.dump(d,open(p,'w'),indent=2)"
python3 "$AM" record --repo "$RFIX" --path .claude/settings.json --action json-merged --class seam --source core-v0.2 --original-from "$RPRE/settings.json.pre" >/dev/null

# hook-installed — the settings.local.json case: LIVE SECRETS (planted fake token + posthog key).
# Record ONLY the jq-path + the CONTENT HASH; NO original bytes ever touch the manifest. The command
# is the REAL non-"kickoff" memory-hook form (`$CLAUDE_PROJECT_DIR/memory-retrieval/hook.mjs`) — this
# is the fixture that FAILED on the old substring probe (no lowercase "kickoff" in the command) and
# PASSES on the content-hash reversal.
cat > "$RFIX/.claude/settings.local.json" <<EOF
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
RHOOK_SHA="$(hook_sha "$RFIX/.claude/settings.local.json" '.hooks.UserPromptSubmit[0]')"
python3 "$AM" record --repo "$RFIX" --path .claude/settings.local.json --action hook-installed --class seam --source core-v0.2 --jq-path '.hooks.UserPromptSubmit[0]' --hook-sha256 "$RHOOK_SHA" >/dev/null

# run reverse, capturing ALL output (stdout+stderr) for the credential-safety grep.
RRC=0; ROUT="$(python3 "$AM" reverse --repo "$RFIX" 2>&1)" || RRC=$?

chk "reverse exits 0 (all 5 actions reversible)"                         "[ $RRC -eq 0 ]"
chk "created: .kickoff/bin/mc DELETED"                                   "[ ! -e \"$RFIX/.kickoff/bin/mc\" ]"
chk "modified: README byte-restored EXACTLY (no-trailing-newline + tab)" "cmp -s \"$RPRE/README.md.pre\" \"$RFIX/README.md\""
chk "block-appended: CLAUDE byte-restored EXACTLY (block gone)"          "cmp -s \"$RPRE/CLAUDE.md.pre\" \"$RFIX/CLAUDE.md\""
chk "json-merged: 4-space settings.json byte-restored EXACTLY"           "cmp -s \"$RPRE/settings.json.pre\" \"$RFIX/.claude/settings.json\""
chk "hook-installed: the kickoff hook is GONE (UserPromptSubmit == [])" \
  "[ \"\$(jq -c '.hooks.UserPromptSubmit' \"$RFIX/.claude/settings.local.json\")\" = '[]' ]"
chk "hook-installed: the planted telegram secret SURVIVES in the file"   "grep -qF '$PLANT'    \"$RFIX/.claude/settings.local.json\""
chk "hook-installed: the planted posthog secret SURVIVES in the file"    "grep -qF '$PLANT_PH' \"$RFIX/.claude/settings.local.json\""
# THE credential proof: neither planted secret appears anywhere in reverse's stdout/stderr.
chk "CREDENTIAL-SAFE: telegram secret ABSENT from all reverse output"    "! printf '%s' \"\$ROUT\" | grep -qF '$PLANT'"
chk "CREDENTIAL-SAFE: posthog secret ABSENT from all reverse output"     "! printf '%s' \"\$ROUT\" | grep -qF '$PLANT_PH'"
# proves the grep above would catch a leak: the secret really is still in the fixture file.
chk "the planted secret really IS in the fixture (the grep can catch a leak)" \
  "grep -qF '$PLANT' \"$RFIX/.claude/settings.local.json\""
echo

echo "1b. reverse NO-CLOBBER: divergence keeps by default; edited files are never overwritten"
# created + hand-edited after record → default keep (NOT silent-deleted), then --on-divergence delete.
DFIX="$(mk)"; mkdir -p "$DFIX/.kickoff"
printf 'v1\n' > "$DFIX/newfile.txt"
python3 "$AM" record --repo "$DFIX" --path newfile.txt --action created --class seam --source core-v0.2 >/dev/null
printf 'operator edit\n' >> "$DFIX/newfile.txt"                       # diverge from the recorded hash
python3 "$AM" reverse --repo "$DFIX" >/dev/null
chk "diverged created file KEPT by default (no silent-delete)"           "[ -f \"$DFIX/newfile.txt\" ]"
python3 "$AM" reverse --repo "$DFIX" --on-divergence delete >/dev/null
chk "diverged created file DELETED only under --on-divergence delete"    "[ ! -e \"$DFIX/newfile.txt\" ]"

# modified + edited after adopt → NEVER clobber; report points at the archive.
MFIX="$(mk)"; MPRE="$(mk)"; mkdir -p "$MFIX/.kickoff"
printf 'original\n' > "$MFIX/f.txt"; cp "$MFIX/f.txt" "$MPRE/pre"
printf 'kickoff edit\n' >> "$MFIX/f.txt"
python3 "$AM" record --repo "$MFIX" --path f.txt --action modified --class seam --source core-v0.2 --original-from "$MPRE/pre" >/dev/null
printf 'OPERATOR EDIT AFTER ADOPT\n' >> "$MFIX/f.txt"                 # edit after adopt → hash diverges
MOUT="$(python3 "$AM" reverse --repo "$MFIX" 2>&1)"
chk "edited modified file NOT clobbered (operator text survives)"        "grep -q 'OPERATOR EDIT AFTER ADOPT' \"$MFIX/f.txt\""
chk "edited modified file: reverse reports 'reconcile manually'"         "printf '%s' \"\$MOUT\" | grep -q 'reconcile manually'"

# block-appended + edited after adopt → surgical strip; operator's added text SURVIVES.
EFIX="$(mk)"; EPRE="$(mk)"; mkdir -p "$EFIX/.kickoff"
printf '# Repo\n\nMine.\n' > "$EFIX/CLAUDE.md"; cp "$EFIX/CLAUDE.md" "$EPRE/pre"
printf '\n<!-- kickoff:begin core-v0.2 -->\n@.kickoff/KICKOFF.md\n<!-- kickoff:end -->\n' >> "$EFIX/CLAUDE.md"
python3 "$AM" record --repo "$EFIX" --path CLAUDE.md --action block-appended --class seam --source core-v0.2 --original-from "$EPRE/pre" >/dev/null
printf 'OPERATOR ADDED AFTER ADOPT\n' >> "$EFIX/CLAUDE.md"           # edit after adopt → hash diverges
EOUT="$(python3 "$AM" reverse --repo "$EFIX" 2>&1)"
chk "edited block-appended: the marker block is stripped"               "! grep -q 'kickoff:begin' \"$EFIX/CLAUDE.md\""
chk "edited block-appended: operator's post-adopt text SURVIVES"        "grep -q 'OPERATOR ADDED AFTER ADOPT' \"$EFIX/CLAUDE.md\""
chk "edited block-appended: reverse reports 'formatting may differ'"    "printf '%s' \"\$EOUT\" | grep -q 'formatting may differ'"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
# (B) the ACCEPTANCE TEST that gates the tag — adopt → `kickoff eject`, byte-for-byte pristine
# ══════════════════════════════════════════════════════════════════════════════════════
# Builds the real adopt footprint (fork-#4 atomic commit DISABLED → uncommitted) on a git fixture
# whose settings.json is NON-jq-canonical (4-space) and whose lefthook.yml ALREADY carries a
# top-level pre-commit key — the two cases that force the byte-restore + structure-aware paths.
# Then `kickoff eject` and assert git status --porcelain is EMPTY (Fix 2's defined baseline).

# Build the full adopt fixture; echoes the fixture dir. $1 = "" (plain) — the crew is committed
# as the adopter's deliverable (fork #3) so keeping it survives eject WITHOUT dirtying porcelain,
# while the rest of the footprint stays uncommitted (fork #4 disabled) to exercise byte-restore.
build_adopt_fixture() {
  local fix pre
  fix="$(mk)"; pre="$(mk)"
  mkdir -p "$fix/.claude"
  git -C "$fix" init -q
  git -C "$fix" config user.email t@t.t; git -C "$fix" config user.name t
  # ── pre-existing (adopter-owned) files, committed as the baseline ──
  printf '# My Repo\n\nExisting operator instructions.\n' > "$fix/CLAUDE.md"
  printf '{\n    "enableAllProjectMcpServers": false\n}\n'  > "$fix/.claude/settings.json"   # 4-space, NON-canonical
  cat > "$fix/lefthook.yml" <<'YML'
pre-commit:
  commands:
    my-lint:
      run: echo linting
YML
  printf 'the readme\n' > "$fix/README.md"
  printf '.claude/settings.local.json\n' > "$fix/.gitignore"    # ignores the secret file, NOT .kickoff/
  git -C "$fix" add -A; git -C "$fix" commit -qm baseline

  # ── the adopt footprint (uncommitted) ──
  mkdir -p "$fix/.kickoff/bin" "$fix/.claude/agents" "$fix/.kickoff/state/facts"
  cat > "$fix/.kickoff/instance.env" <<EOF
export TELEGRAM_STATE_DIR="$fix/.kickoff/chan"
export MC_STATE_FILE="$fix/.kickoff/state/mission-state.json"
export MC_TRACKER_FILE="$fix/.kickoff/state/TRACKER.md"
export MEMORY_DB="$fix/.kickoff/state/memory-index.db"
export MEMORY_INDEX="$fix/.kickoff/state/MEMORY.md"
export MEMORY_DIR="$fix/.kickoff/state/facts"
export MEMORY_HOOK_LOG="$fix/.kickoff/state/memory-hook.log"
EOF
  printf '{"board":"live"}\n' > "$fix/.kickoff/state/mission-state.json"
  printf '# TRACKER\nrendered\n'  > "$fix/.kickoff/state/TRACKER.md"
  printf 'SQLITE-INDEX-BYTES\n'   > "$fix/.kickoff/state/memory-index.db"
  printf '# memory index\n'       > "$fix/.kickoff/state/MEMORY.md"
  printf 'a durable fact\n'       > "$fix/.kickoff/state/facts/fact-1.md"
  printf 'memory hook log line 1\n' > "$fix/.kickoff/state/memory-hook.log"   # MEMORY_HOOK_LOG (Fix #6)

  # created/seam — the mc seam shim (via gen-shim, exactly as adopt does)
  python3 "$AM" gen-shim --repo "$fix" --name mc --source core-v0.2 >/dev/null

  # modified — README.md
  cp "$fix/README.md" "$pre/README.md.pre"
  printf 'the readme\nKICKOFF-APPENDED-LINE\n' > "$fix/README.md"
  python3 "$AM" record --repo "$fix" --path README.md --action modified --class seam --source core-v0.2 --original-from "$pre/README.md.pre" >/dev/null

  # block-appended — CLAUDE.md marker block
  cp "$fix/CLAUDE.md" "$pre/CLAUDE.md.pre"
  printf '\n<!-- kickoff:begin core-v0.2 -->\n@.kickoff/KICKOFF.md\n<!-- kickoff:end -->\n' >> "$fix/CLAUDE.md"
  python3 "$AM" record --repo "$fix" --path CLAUDE.md --action block-appended --class seam --source core-v0.2 --original-from "$pre/CLAUDE.md.pre" >/dev/null

  # json-merged — settings.json (jq merge re-indents 4-space → 2-space; byte-restore is the only clean reversal)
  cp "$fix/.claude/settings.json" "$pre/settings.json.pre"
  python3 -c "import json;p='$fix/.claude/settings.json';d=json.load(open(p));d['enabledPlugins']={'kickoff@local':True};json.dump(d,open(p,'w'),indent=2)"
  python3 "$AM" record --repo "$fix" --path .claude/settings.json --action json-merged --class seam --source core-v0.2 --original-from "$pre/settings.json.pre" >/dev/null

  # modified — lefthook.yml, marker-insert UNDER the existing pre-commit.commands (never a 2nd top-level pre-commit)
  cp "$fix/lefthook.yml" "$pre/lefthook.yml.pre"
  cat > "$fix/lefthook.yml" <<'YML'
pre-commit:
  commands:
    my-lint:
      run: echo linting
    # kickoff:begin core-v0.2
    kickoff-secret-scan:
      run: bash .kickoff/bin/scan-secrets
    # kickoff:end
YML
  python3 "$AM" record --repo "$fix" --path lefthook.yml --action modified --class seam --source core-v0.2 --original-from "$pre/lefthook.yml.pre" >/dev/null

  # hook-installed — settings.local.json (PLANTED SECRETS, jq-path + content hash, NO stored bytes).
  # NON-"kickoff" command (the real memory-hook form) so the acceptance test exercises the content-
  # hash reversal, not a substring that happens to say "kickoff".
  cat > "$fix/.claude/settings.local.json" <<EOF
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
  local hooksha; hooksha="$(hook_sha "$fix/.claude/settings.local.json" '.hooks.UserPromptSubmit[0]')"
  python3 "$AM" record --repo "$fix" --path .claude/settings.local.json --action hook-installed --class seam --source core-v0.2 --jq-path '.hooks.UserPromptSubmit[0]' --hook-sha256 "$hooksha" >/dev/null

  # created/seeded-instance — the domain crew authored for the repo (adopter-owned deliverable).
  printf '# domain-x agent\n\nA specialist authored for this repo.\n' > "$fix/.claude/agents/domain-x.md"
  python3 "$AM" record --repo "$fix" --path .claude/agents/domain-x.md --action created --class seeded-instance --source authored-for-repo >/dev/null
  # fork #3: the operator commits their crew deliverable — eject keeps it, so it survives WITHOUT
  # dirtying porcelain, while the rest of the footprint stays uncommitted (fork #4 disabled).
  git -C "$fix" add .claude/agents/domain-x.md; git -C "$fix" commit -qm "adopt: seeded domain crew"

  # expose the pre-edit copies to the caller via a side file (mk dirs vanish across subshells).
  printf '%s\n' "$pre" > "$fix/.PREDIR"
  printf '%s' "$fix"
}

echo "2. ACCEPTANCE (gates the tag): adopt → eject leaves the tree byte-for-byte as it was"
FIX="$(build_adopt_fixture)"; PRE="$(cat "$FIX/.PREDIR")"; rm -f "$FIX/.PREDIR"; ARCH="$(mk)"
chk "before eject: porcelain is NON-empty (adopt footprint is uncommitted)" \
  "[ -n \"\$(git -C \"$FIX\" status --porcelain)\" ]"

ERC=0
EOUT="$(bash "$KICKOFF" eject --dir "$FIX" --archive --archive-dir "$ARCH" --delete-data --confirm-destroy 2>&1)" || ERC=$?

chk "eject exits 0"                                            "[ $ERC -eq 0 ]"
chk "THE GATE: git status --porcelain is EMPTY (byte-for-byte as it was)" \
  "[ -z \"\$(git -C \"$FIX\" status --porcelain)\" ]"
chk ".kickoff/ is GONE"                                        "[ ! -e \"$FIX/.kickoff\" ]"
chk "CLAUDE.md byte-matches pre-adopt (block gone)"           "cmp -s \"$PRE/CLAUDE.md.pre\" \"$FIX/CLAUDE.md\""
chk "settings.json byte-matches pre-adopt"                    "cmp -s \"$PRE/settings.json.pre\" \"$FIX/.claude/settings.json\""
chk "settings.json is STILL 4-space (not re-indented to jq 2-space)" \
  "grep -q '^    \"enableAllProjectMcpServers\"' \"$FIX/.claude/settings.json\""
chk "lefthook.yml byte-matches pre-adopt (pre-commit mapping intact)" "cmp -s \"$PRE/lefthook.yml.pre\" \"$FIX/lefthook.yml\""
chk "README.md byte-matches pre-adopt"                        "cmp -s \"$PRE/README.md.pre\" \"$FIX/README.md\""
chk "settings.local.json hook is GONE (UserPromptSubmit == [])" \
  "[ \"\$(jq -c '.hooks.UserPromptSubmit' \"$FIX/.claude/settings.local.json\")\" = '[]' ]"
chk "settings.local.json fake telegram secret SURVIVES"       "grep -qF '$PLANT'    \"$FIX/.claude/settings.local.json\""
chk "settings.local.json fake posthog secret SURVIVES"        "grep -qF '$PLANT_PH' \"$FIX/.claude/settings.local.json\""
chk "domain-x.md still present (crew kept by default)"        "[ -f \"$FIX/.claude/agents/domain-x.md\" ]"

# archive present + contains state/tracker/memory
ARCHFILE="$ARCH/kickoff-eject-$(basename "$FIX")-$(date +%F).tgz"
chk "archive tarball exists"                                  "[ -f \"$ARCHFILE\" ]"
chk "archive contains the mission-state"                      "tar tzf \"$ARCHFILE\" | grep -q 'mission-state.json'"
chk "archive contains the TRACKER render"                     "tar tzf \"$ARCHFILE\" | grep -q 'TRACKER.md'"
chk "archive contains the memory index"                       "tar tzf \"$ARCHFILE\" | grep -q 'memory-index.db'"

# ── CREDENTIAL SAFETY (invariant #1): the secret is ABSENT from the archive AND all eject output ──
chk "CREDENTIAL-SAFE: telegram secret ABSENT from all eject stdout/stderr" "! printf '%s' \"\$EOUT\" | grep -qF '$PLANT'"
chk "CREDENTIAL-SAFE: posthog secret ABSENT from all eject stdout/stderr"  "! printf '%s' \"\$EOUT\" | grep -qF '$PLANT_PH'"
chk "CREDENTIAL-SAFE: settings.local.json is NOT in the archive listing"   "! tar tzf \"$ARCHFILE\" | grep -q 'settings.local.json'"
EXTRACT="$(mk)"; tar xzf "$ARCHFILE" -C "$EXTRACT" 2>/dev/null || true
chk "CREDENTIAL-SAFE: telegram secret ABSENT from the extracted archive tree" "! grep -rqF '$PLANT'    \"$EXTRACT\""
chk "CREDENTIAL-SAFE: posthog secret ABSENT from the extracted archive tree"  "! grep -rqF '$PLANT_PH' \"$EXTRACT\""
echo

# ══════════════════════════════════════════════════════════════════════════════════════
# (C) hardening — leave-relocation, surgical fallback, --purge, divergence fail-safe, the gate
# ══════════════════════════════════════════════════════════════════════════════════════

echo "3. hardening: leave-relocation (default) moves in-.kickoff data to kickoff-data/"
LFIX="$(build_adopt_fixture)"; rm -f "$LFIX/.PREDIR"; LARCH="$(mk)"
LRC=0; LOUT="$(bash "$KICKOFF" eject --dir "$LFIX" --archive-dir "$LARCH" --verify 2>&1)" || LRC=$?
chk "leave: eject exits 0"                                     "[ $LRC -eq 0 ]"
chk "leave: kickoff-data/ exists (data relocated, not deleted)" "[ -d \"$LFIX/kickoff-data\" ]"
chk "leave: mission-state relocated into kickoff-data/"        "[ -f \"$LFIX/kickoff-data/state/mission-state.json\" ]"
chk "leave: memory index relocated into kickoff-data/"         "[ -f \"$LFIX/kickoff-data/state/memory-index.db\" ]"
chk "leave: facts dir relocated into kickoff-data/"            "[ -d \"$LFIX/kickoff-data/state/facts\" ]"
chk "leave: .kickoff/ is GONE"                                 "[ ! -e \"$LFIX/.kickoff\" ]"
chk "leave --verify: reports 'no trace'"                       "printf '%s' \"\$LOUT\" | grep -q 'no trace'"
chk "leave --verify: allowlists kickoff-data/ as RETAINED data" "printf '%s' \"\$LOUT\" | grep -q 'RETAINED data'"
echo

echo "4. hardening: block-appended SURGICAL fallback when CLAUDE.md was edited after adopt"
SFIX="$(build_adopt_fixture)"; rm -f "$SFIX/.PREDIR"; SARCH="$(mk)"
printf 'OPERATOR ADDED THIS AFTER ADOPT\n' >> "$SFIX/CLAUDE.md"     # edit after adopt → hash diverges
SOUT="$(bash "$KICKOFF" eject --dir "$SFIX" --archive-dir "$SARCH" --delete-data --confirm-destroy 2>&1)" || true
chk "surgical: the marker block is stripped from CLAUDE.md"    "! grep -q 'kickoff:begin' \"$SFIX/CLAUDE.md\""
chk "surgical: operator's post-adopt text SURVIVES (no clobber)" "grep -q 'OPERATOR ADDED THIS AFTER ADOPT' \"$SFIX/CLAUDE.md\""
chk "surgical: the operator's pre-existing text SURVIVES"      "grep -q 'Existing operator instructions' \"$SFIX/CLAUDE.md\""
chk "surgical: eject reports 'formatting may differ'"          "printf '%s' \"\$SOUT\" | grep -q 'formatting may differ'"
echo

echo "5. hardening: --purge removes the domain crew (hash-gated)"
PFIX="$(build_adopt_fixture)"; rm -f "$PFIX/.PREDIR"; PARCH="$(mk)"
bash "$KICKOFF" eject --dir "$PFIX" --archive-dir "$PARCH" --purge --delete-data --confirm-destroy >/dev/null 2>&1 || true
chk "--purge: domain-x.md is DELETED (crew removed, hash matched)" "[ ! -e \"$PFIX/.claude/agents/domain-x.md\" ]"
echo

echo "6. hardening: DIVERGENCE fail-safe — an edited crew file is NOT silently purged"
DFIX="$(build_adopt_fixture)"; rm -f "$DFIX/.PREDIR"; DARCH="$(mk)"
printf 'OPERATOR TUNED THIS AGENT AFTER ADOPT\n' >> "$DFIX/.claude/agents/domain-x.md"   # diverge the crew hash
DOUT="$(bash "$KICKOFF" eject --dir "$DFIX" --archive-dir "$DARCH" --purge --delete-data --confirm-destroy 2>&1)" || true
chk "divergence: edited crew file KEPT under --purge (no silent-delete)" "[ -f \"$DFIX/.claude/agents/domain-x.md\" ]"
chk "divergence: the operator's tuning SURVIVES"              "grep -q 'OPERATOR TUNED THIS AGENT' \"$DFIX/.claude/agents/domain-x.md\""
chk "divergence: eject reports the crew file DIVERGED (kept)"  "printf '%s' \"\$DOUT\" | grep -qi 'DIVERGED'"
echo

echo "7. hardening: DESTRUCTIVE gate — --no-archive --delete-data refuses without --confirm-destroy"
GFIX="$(build_adopt_fixture)"; rm -f "$GFIX/.PREDIR"
GRC=0; GOUT="$(bash "$KICKOFF" eject --dir "$GFIX" --no-archive --delete-data 2>&1)" || GRC=$?
chk "gate: refuses (non-zero exit) — the sole-copy delete is blocked" "[ $GRC -ne 0 ]"
chk "gate: the refusal names --confirm-destroy"               "printf '%s' \"\$GOUT\" | grep -q -- '--confirm-destroy'"
chk "gate: NOTHING was touched (.kickoff/ still present)"      "[ -d \"$GFIX/.kickoff\" ]"
chk "gate: the manifest is intact (no partial teardown)"      "[ -f \"$GFIX/.kickoff/adopt-manifest.json\" ]"
echo

echo "8. hardening: --dry-run reports the plan and changes NOTHING"
YFIX="$(build_adopt_fixture)"; rm -f "$YFIX/.PREDIR"; YARCH="$(mk)"
YOUT="$(bash "$KICKOFF" eject --dir "$YFIX" --archive-dir "$YARCH" --delete-data --confirm-destroy --dry-run 2>&1)" || true
chk "--dry-run: .kickoff/ still present (nothing torn down)"   "[ -d \"$YFIX/.kickoff\" ]"
chk "--dry-run: README not restored yet (still the kickoff edit)" "grep -q 'KICKOFF-APPENDED-LINE' \"$YFIX/README.md\""
chk "--dry-run: no archive tarball written"                   "[ -z \"\$(ls -A \"$YARCH\" 2>/dev/null)\" ]"
chk "--dry-run: reports the plan (says 'WOULD'/'would')"       "printf '%s' \"\$YOUT\" | grep -qi 'would'"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
# (D) adversarial-review regression — the fixtures below use the REAL forms that EXPOSE the
#     bugs the old fixtures masked. Each FAILS on the pre-hardening code and PASSES on the fix.
# ══════════════════════════════════════════════════════════════════════════════════════

# build a settings.local.json with the planted secrets + a UserPromptSubmit array whose entries
# are one hook per command string passed. Used by the Fix-A content-hash regression tests.
write_hooks() {   # $1=file ; $2..=command strings
  local f="$1"; shift
  local arr="[]" c
  for c in "$@"; do
    arr="$(printf '%s' "$arr" | jq --arg cmd "$c" '. + [{"hooks":[{"type":"command","command":$cmd}]}]')"
  done
  jq -n --arg tok "$PLANT" --arg ph "$PLANT_PH" --argjson ups "$arr" \
    '{telegram:{botToken:$tok}, posthog:{apiKey:$ph}, hooks:{UserPromptSubmit:$ups}}' > "$f"
}
KHOOK='$CLAUDE_PROJECT_DIR/memory-retrieval/hook.mjs'   # kickoff's real hook command — NO "kickoff"
OTHER_HOOK='node /opt/adopter-memory/hook.mjs'          # an adopter's own hook form — NO "kickoff" substring
record_hook() {   # $1=repo — records .claude/settings.local.json hook [0] by its content hash
  python3 "$AM" record --repo "$1" --path .claude/settings.local.json --action hook-installed \
    --class seam --source core-v0.2 --jq-path '.hooks.UserPromptSubmit[0]' \
    --hook-sha256 "$(hook_sha "$1/.claude/settings.local.json" '.hooks.UserPromptSubmit[0]')" >/dev/null
}

echo "9. Fix A: hook identity is a CONTENT HASH — non-\"kickoff\" removal, reorder, no-clobber, not-found"
# (a) FALSE-NEGATIVE fixed: a non-"kickoff" adopter command IS removed (old substring probe left it as residue).
A1="$(mk)"; mkdir -p "$A1/.claude"
write_hooks "$A1/.claude/settings.local.json" "$OTHER_HOOK"; record_hook "$A1"
A1OUT="$(python3 "$AM" reverse --repo "$A1" 2>&1)"
chk "Fix A (false-neg): a non-\"kickoff\" adopter hook is REMOVED by content hash (UserPromptSubmit==[])" \
  "[ \"\$(jq -c '.hooks.UserPromptSubmit' \"$A1/.claude/settings.local.json\")\" = '[]' ]"
chk "Fix A (false-neg): the planted secret SURVIVES the removal"          "grep -qF '$PLANT' \"$A1/.claude/settings.local.json\""
chk "Fix A (false-neg): the secret is ABSENT from all reverse output"     "! printf '%s' \"\$A1OUT\" | grep -qF '$PLANT'"

# (b) REORDER: operator prepends their own hook → kickoff's shifts to [1]; hash finds it anyway.
A2="$(mk)"; mkdir -p "$A2/.claude"
write_hooks "$A2/.claude/settings.local.json" "$KHOOK"; record_hook "$A2"
write_hooks "$A2/.claude/settings.local.json" 'my-own-linter --check' "$KHOOK"   # op at [0], kickoff at [1]
python3 "$AM" reverse --repo "$A2" >/dev/null 2>&1
chk "Fix A (reorder): kickoff's hook removed by hash even after it shifted to [1]" \
  "! grep -qF 'memory-retrieval/hook.mjs' \"$A2/.claude/settings.local.json\""
chk "Fix A (reorder): the operator's OWN hook SURVIVES"                    "grep -qF 'my-own-linter' \"$A2/.claude/settings.local.json\""
chk "Fix A (reorder): exactly one hook remains (the operator's)" \
  "[ \"\$(jq '.hooks.UserPromptSubmit | length' \"$A2/.claude/settings.local.json\")\" = 1 ]"

# (c) NO-CLOBBER (false-positive fixed): an operator hook whose command CONTAINS "kickoff" sits at
#     the OLD recorded index [0]; the real kickoff hook is at [1]. Old substring code deleted [0]
#     (the operator's) + left [1] as residue; the hash deletes ONLY the real hook.
A3="$(mk)"; mkdir -p "$A3/.claude"
write_hooks "$A3/.claude/settings.local.json" "$KHOOK"; record_hook "$A3"
write_hooks "$A3/.claude/settings.local.json" 'my-kickoff-helper --run' "$KHOOK"   # op "kickoff" at [0]
python3 "$AM" reverse --repo "$A3" >/dev/null 2>&1
chk "Fix A (no-clobber): operator's OWN \"kickoff\"-named hook at [0] SURVIVES (hash mismatch)" \
  "grep -qF 'my-kickoff-helper' \"$A3/.claude/settings.local.json\""
chk "Fix A (no-clobber): kickoff's REAL hook (now at [1]) is removed by content hash" \
  "! grep -qF 'memory-retrieval/hook.mjs' \"$A3/.claude/settings.local.json\""
chk "Fix A (no-clobber): exactly one hook remains (the operator's)" \
  "[ \"\$(jq '.hooks.UserPromptSubmit | length' \"$A3/.claude/settings.local.json\")\" = 1 ]"

# (d) NOT-FOUND: operator removed kickoff's hook post-adopt → 'not found, left as-is', exit 0, no clobber.
A4="$(mk)"; mkdir -p "$A4/.claude"
write_hooks "$A4/.claude/settings.local.json" "$KHOOK"; record_hook "$A4"
write_hooks "$A4/.claude/settings.local.json" 'my-own-linter --check'    # operator replaced it
A4RC=0; A4OUT="$(python3 "$AM" reverse --repo "$A4" 2>&1)" || A4RC=$?
chk "Fix A (not-found): reverse exits 0 (a vanished hook is not a failure)"   "[ $A4RC -eq 0 ]"
chk "Fix A (not-found): reports 'not found … left as-is'"                     "printf '%s' \"\$A4OUT\" | grep -qi 'not found'"
chk "Fix A (not-found): the operator's replacement hook is untouched (no clobber)" \
  "grep -qF 'my-own-linter' \"$A4/.claude/settings.local.json\""
echo

echo "10. Fix B: REALPATH escape containment — a symlink can't lure a write/delete out of the repo"
BFIX="$(mk)"; BOUT="$(mk)"; mkdir -p "$BFIX/.kickoff"
ln -s "$BOUT" "$BFIX/escape"                              # BFIX/escape → BOUT (OUTSIDE the repo)
printf 'operator victim content\n' > "$BOUT/victim.txt"  # an OUTSIDE file a `modified` entry targets
printf 'operator del content\n'    > "$BOUT/del.txt"      # an OUTSIDE file a `created` entry targets
# a crafted manifest whose entries are LEXICALLY clean (no '..', not absolute) but resolve OUT via
# the symlink. escape/victim.txt (modified, hash matches → would byte-restore PWNED out); escape/del.txt
# (created, would DELETE the outside file).
cat > "$BFIX/.kickoff/adopt-manifest.json" <<JSON
{ "schema_version": 1, "entries": [
  { "path": "escape/victim.txt", "action": "modified", "class": "seam", "source": "x",
    "sha256_before_edit": "00", "sha256_at_write": "$(sha256sum "$BOUT/victim.txt" | awk '{print $1}')",
    "original_encoding": "base64", "original": "$(printf 'PWNED\n' | base64 | tr -d '\n')" },
  { "path": "escape/del.txt", "action": "created", "class": "seam", "source": "x",
    "sha256_at_write": "$(sha256sum "$BOUT/del.txt" | awk '{print $1}')" }
] }
JSON
BRC=0; BREVOUT="$(python3 "$AM" reverse --repo "$BFIX" 2>&1)" || BRC=$?
chk "Fix B: reverse exits NON-zero (refused the symlink-escaping entries)"     "[ $BRC -ne 0 ]"
chk "Fix B: the OUTSIDE victim.txt was NOT overwritten (operator content intact)" \
  "grep -qF 'operator victim content' \"$BOUT/victim.txt\""
chk "Fix B: the PWNED bytes were NEVER written outside the repo"               "! grep -qF 'PWNED' \"$BOUT/victim.txt\""
chk "Fix B: the OUTSIDE del.txt was NOT deleted"                               "[ -f \"$BOUT/del.txt\" ]"
chk "Fix B: reverse reports refusing to touch OUTSIDE the repo"               "printf '%s' \"\$BREVOUT\" | grep -qi 'OUTSIDE the repo'"
echo

echo "11. Fix C: secret tmp crash-safety (Ctrl-C leaves no tmp) + --verify flags/removes a stray tmp"
CFIX="$(mk)"; mkdir -p "$CFIX/.claude"
# a command containing ".kickoff" so BOTH the fixed (content-hash) and the pre-fix (substring)
# reversal REACH the del→tmp path — isolating the crash-safety fix (the try/finally) as the thing
# under test (a non-"kickoff" command would make the old substring probe skip the del path entirely
# and never create a tmp, masking the leak). The hash still matches it under the fix.
write_hooks "$CFIX/.claude/settings.local.json" 'node .kickoff/bin/memory-hook'; record_hook "$CFIX"
# Simulate a Ctrl-C mid-reversal: monkeypatch subprocess.call to run the real jq (populating the
# 0600 tmp) and THEN raise KeyboardInterrupt — the review's exact repro. The try/finally must unlink
# the secret-bearing tmp on the interrupt (it escapes .gitignore's exact-name rule + the marker scan).
AM="$AM" CFIX="$CFIX" python3 - <<'PY' || true
import os, json, subprocess, importlib.util
am_path = os.environ["AM"]; repo = os.environ["CFIX"]
spec = importlib.util.spec_from_file_location("adopt_manifest", am_path)
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
real_call = subprocess.call
def boom(*a, **k):
    real_call(*a, **k)        # run the real jq → writes the 0600 tmp
    raise KeyboardInterrupt   # …then the operator hits Ctrl-C before os.replace
mod.subprocess.call = boom
entry = json.load(open(os.path.join(repo, ".kickoff", "adopt-manifest.json")))["entries"][0]
try:
    mod._reverse_hook_installed(repo, entry, False)
except KeyboardInterrupt:
    pass
PY
CLEFT="$(find "$CFIX" -name '*.kickoff-eject.tmp' 2>/dev/null || true)"
chk "Fix C (crash): a Ctrl-C mid-reversal leaves NO secret-bearing *.kickoff-eject.tmp"  "[ -z \"$CLEFT\" ]"
chk "Fix C (crash): settings.local.json still holds the planted secret (untouched by the interrupt)" \
  "grep -qF '$PLANT' \"$CFIX/.claude/settings.local.json\""

# --verify: a stray *.kickoff-eject.tmp (as an interrupted run would leave) is flagged AND removed,
# and its secret never reaches --verify's output.
VTFIX="$(build_adopt_fixture)"; rm -f "$VTFIX/.PREDIR"; VTARCH="$(mk)"
printf 'leftover secret botToken %s\n' "$PLANT" > "$VTFIX/leftover.kickoff-eject.tmp"
VTOUT="$(bash "$KICKOFF" eject --dir "$VTFIX" --archive-dir "$VTARCH" --delete-data --confirm-destroy --verify 2>&1)" || true
chk "Fix C (--verify): flags a leftover *.kickoff-eject.tmp as residue"        "printf '%s' \"\$VTOUT\" | grep -q 'eject temp file'"
chk "Fix C (--verify): REMOVES the leftover tmp (secret residue purged)"       "[ ! -e \"$VTFIX/leftover.kickoff-eject.tmp\" ]"
chk "Fix C (--verify): the planted tmp's secret is ABSENT from verify output"  "! printf '%s' \"\$VTOUT\" | grep -qF '$PLANT'"
echo

echo "12. Fix D: marker-strip regex — CRLF blocks strip cleanly; a stray begin never clobbers prose"
# (a) CRLF block, edited after adopt (surgical path) → stripped; old `[ \t]*\n` never matched \r\n.
DCR="$(mk)"; DCRPRE="$(mk)"; mkdir -p "$DCR/.kickoff"
printf '# Repo\r\n\r\nOperator content.\r\n' > "$DCR/CLAUDE.md"; cp "$DCR/CLAUDE.md" "$DCRPRE/pre"
printf '\r\n<!-- kickoff:begin core-v0.2 -->\r\n@.kickoff/KICKOFF.md\r\n<!-- kickoff:end -->\r\n' >> "$DCR/CLAUDE.md"
python3 "$AM" record --repo "$DCR" --path CLAUDE.md --action block-appended --class seam --source core-v0.2 --original-from "$DCRPRE/pre" >/dev/null
printf 'OPERATOR ADDED AFTER ADOPT (crlf)\r\n' >> "$DCR/CLAUDE.md"   # edit after adopt → surgical
python3 "$AM" reverse --repo "$DCR" >/dev/null 2>&1
chk "Fix D (CRLF): the CRLF kickoff block is stripped (no begin residue)"      "! grep -q 'kickoff:begin' \"$DCR/CLAUDE.md\""
chk "Fix D (CRLF): no end-marker residue either"                              "! grep -q 'kickoff:end' \"$DCR/CLAUDE.md\""
chk "Fix D (CRLF): operator's post-adopt text SURVIVES"                       "grep -q 'OPERATOR ADDED AFTER ADOPT' \"$DCR/CLAUDE.md\""
chk "Fix D (CRLF): the operator's pre-existing content SURVIVES"              "grep -q 'Operator content' \"$DCR/CLAUDE.md\""

# (b) a STRAY begin in operator prose BEFORE the real block → operator content between is PRESERVED
#     (old non-greedy from the first begin deleted it). Single end marker → strip the real block.
DSB="$(mk)"; DSBPRE="$(mk)"; mkdir -p "$DSB/.kickoff"
printf '# Repo\n\nHere is a note about markers:\n<!-- kickoff:begin note -->\nOperator text between a stray begin and the real block — MUST SURVIVE.\n' > "$DSB/CLAUDE.md"
cp "$DSB/CLAUDE.md" "$DSBPRE/pre"
printf '\n<!-- kickoff:begin core-v0.2 -->\n@.kickoff/KICKOFF.md\n<!-- kickoff:end -->\n' >> "$DSB/CLAUDE.md"
python3 "$AM" record --repo "$DSB" --path CLAUDE.md --action block-appended --class seam --source core-v0.2 --original-from "$DSBPRE/pre" >/dev/null
printf 'OPERATOR EDIT AFTER ADOPT\n' >> "$DSB/CLAUDE.md"   # edit after adopt → surgical
python3 "$AM" reverse --repo "$DSB" >/dev/null 2>&1
chk "Fix D (stray begin): operator content between the stray begin and real block SURVIVES (no clobber)" \
  "grep -q 'MUST SURVIVE' \"$DSB/CLAUDE.md\""
chk "Fix D (stray begin): the operator's stray-begin line SURVIVES"           "grep -q 'note about markers' \"$DSB/CLAUDE.md\""
chk "Fix D (stray begin): the REAL kickoff block (the @import) is stripped"    "! grep -q 'KICKOFF.md' \"$DSB/CLAUDE.md\""
chk "Fix D (stray begin): the operator's post-adopt edit SURVIVES"            "grep -q 'OPERATOR EDIT AFTER ADOPT' \"$DSB/CLAUDE.md\""

# (c) AMBIGUOUS (2+ end markers): a complete stray block before the real one → REFUSE to strip
#     (no clobber) rather than delete the wrong span. Old non-greedy deleted the operator's block.
DAMB="$(mk)"; DAMBPRE="$(mk)"; mkdir -p "$DAMB/.kickoff"
printf '# Repo\n\nOperator note with an embedded block:\n<!-- kickoff:begin op -->\nMINE-KEEP\n<!-- kickoff:end -->\nmore operator text\n' > "$DAMB/CLAUDE.md"
cp "$DAMB/CLAUDE.md" "$DAMBPRE/pre"
printf '\n<!-- kickoff:begin core-v0.2 -->\n@.kickoff/KICKOFF.md\n<!-- kickoff:end -->\n' >> "$DAMB/CLAUDE.md"
python3 "$AM" record --repo "$DAMB" --path CLAUDE.md --action block-appended --class seam --source core-v0.2 --original-from "$DAMBPRE/pre" >/dev/null
printf 'OPERATOR EDIT AFTER ADOPT\n' >> "$DAMB/CLAUDE.md"
DAMBRC=0; DAMBOUT="$(python3 "$AM" reverse --repo "$DAMB" 2>&1)" || DAMBRC=$?
chk "Fix D (ambiguous): 2+ end markers → the operator's own block is NOT clobbered" "grep -q 'MINE-KEEP' \"$DAMB/CLAUDE.md\""
chk "Fix D (ambiguous): reverse REFUSES the ambiguous strip (kickoff block left, reported)" \
  "grep -q 'KICKOFF.md' \"$DAMB/CLAUDE.md\""
chk "Fix D (ambiguous): reverse reports the ambiguity (reconcile manually)"    "printf '%s' \"\$DAMBOUT\" | grep -qi 'ambiguous\|reconcile'"
echo

echo "13. Fix E: data-relocation safety — MEMORY_HOOK_LOG survives; no clobber; no nested layout"
# #6 — MEMORY_HOOK_LOG lives in .kickoff/; a DEFAULT safe eject must ARCHIVE + RELOCATE it, never
# destroy it with .kickoff/ ("leave = relocate, never the void"). (Old code dropped it from both loops.)
EF6="$(build_adopt_fixture)"; rm -f "$EF6/.PREDIR"; EF6ARCH="$(mk)"
bash "$KICKOFF" eject --dir "$EF6" --archive-dir "$EF6ARCH" >/dev/null 2>&1 || true
EF6ARCHFILE="$EF6ARCH/kickoff-eject-$(basename "$EF6")-$(date +%F).tgz"
chk "Fix E #6: memory-hook.log IS in the archive tarball"                     "tar tzf \"$EF6ARCHFILE\" | grep -q 'memory-hook.log'"
chk "Fix E #6: memory-hook.log relocated into kickoff-data/ (not destroyed on default leave)" \
  "[ -f \"$EF6/kickoff-data/state/memory-hook.log\" ]"
chk "Fix E #6: the relocated log keeps its content"                          "grep -q 'memory hook log line 1' \"$EF6/kickoff-data/state/memory-hook.log\""

# #7 — the relocation mv had no -n: a --data-dir already holding a colliding relative path would be
# SILENTLY overwritten (unrecoverable). Now: never overwrite; divert kickoff's copy to a timestamped subdir.
EF7="$(build_adopt_fixture)"; rm -f "$EF7/.PREDIR"; EF7ARCH="$(mk)"; EF7DATA="$(mk)"
mkdir -p "$EF7DATA/state"
printf 'OPERATOR OWNED DATA — must not be overwritten\n' > "$EF7DATA/state/mission-state.json"
bash "$KICKOFF" eject --dir "$EF7" --archive-dir "$EF7ARCH" --data-dir "$EF7DATA" >/dev/null 2>&1 || true
chk "Fix E #7: the operator's pre-existing data-dir file is NOT overwritten (survives)" \
  "grep -q 'OPERATOR OWNED DATA' \"$EF7DATA/state/mission-state.json\""
chk "Fix E #7: kickoff's colliding copy was diverted to a timestamped subdir (both survive)" \
  "ls \"$EF7DATA\"/kickoff-eject-*/state/mission-state.json >/dev/null 2>&1"

# #8 — a MEMORY_DIR that is a PARENT of another listed data path must not double-nest into
# kickoff-data/<sub>/<sub>/. The de-dup relocates the parent as a unit. (Cosmetic; recoverable.)
EF8="$(mk)"; mkdir -p "$EF8/.kickoff/state"
printf '{}\n'    > "$EF8/.kickoff/state/mission-state.json"
printf 'INDEX\n' > "$EF8/.kickoff/state/idx.db"
printf '{ "schema_version":1, "entries":[] }\n' > "$EF8/.kickoff/adopt-manifest.json"
cat > "$EF8/.kickoff/instance.env" <<EOF
export MC_STATE_FILE="$EF8/.kickoff/state/mission-state.json"
export MEMORY_DIR="$EF8/.kickoff/state"
export MEMORY_DB="$EF8/.kickoff/state/idx.db"
EOF
bash "$KICKOFF" eject --dir "$EF8" --archive-dir "$(mk)" >/dev/null 2>&1 || true
chk "Fix E #8: nested data relocates as a unit (kickoff-data/state/idx.db exists)" "[ -f \"$EF8/kickoff-data/state/idx.db\" ]"
chk "Fix E #8: NO pathological kickoff-data/state/state/ double-nesting"           "[ ! -e \"$EF8/kickoff-data/state/state\" ]"
echo

echo "14. re-review HIGH: the hook-rewrite tmp is SYMLINK-SAFE — a planted <file>.kickoff-eject.tmp can't exfil secrets"
# The Fix-B realpath guard covered abs_path, but the jq-del wrote through a PREDICTABLE sibling tmp
# (abs_path + '.kickoff-eject.tmp') opened without O_EXCL/O_NOFOLLOW. An attacker who plants a symlink
# at that exact name (Fix B's own threat model — a repo carrying attacker symlinks) redirected the
# de-hooked settings (the OTHER live secrets) OUT of the repo, while eject printed "secrets untouched".
# Now the tmp is a random mkstemp name → the planted symlink is never opened. FAILS on the old code.
TXFIX="$(mk)"; TXOUT="$(mk)"; mkdir -p "$TXFIX/.claude" "$TXFIX/.kickoff"
cat > "$TXFIX/.claude/settings.local.json" <<'EOF'
{ "env": { "TELEGRAM_BOT_TOKEN": "FAKE-TG-EXFIL-TARGET-9999" },
  "hooks": { "UserPromptSubmit": [ { "hooks": [ { "type": "command", "command": "node .kickoff/bin/memory-hook" } ] } ] } }
EOF
python3 "$AM" record --repo "$TXFIX" --path .claude/settings.local.json --action hook-installed --class seam --source core-v0.2 \
  --jq-path '.hooks.UserPromptSubmit[0]' --hook-sha256 "$(hook_sha "$TXFIX/.claude/settings.local.json" '.hooks.UserPromptSubmit[0]')" >/dev/null
printf 'SINK-EMPTY\n' > "$TXOUT/EXFIL-SINK.txt"
ln -s "$TXOUT/EXFIL-SINK.txt" "$TXFIX/.claude/settings.local.json.kickoff-eject.tmp"   # THE ATTACK: predictable-name symlink out
python3 "$AM" reverse --repo "$TXFIX" >/dev/null 2>&1 || true
chk "re-review HIGH: the out-of-repo sink was NOT written (secret never exfiltrated via the tmp symlink)" \
  "! grep -q 'FAKE-TG-EXFIL' \"$TXOUT/EXFIL-SINK.txt\""
chk "re-review HIGH: the kickoff hook was still removed (real in-repo work done)" \
  "jq -e '.hooks.UserPromptSubmit | length == 0' \"$TXFIX/.claude/settings.local.json\" >/dev/null"
chk "re-review HIGH: the operator's secret is PRESERVED in-file"                    "grep -q 'FAKE-TG-EXFIL' \"$TXFIX/.claude/settings.local.json\""
chk "re-review HIGH: settings.local.json was not turned into a symlink"             "[ ! -L \"$TXFIX/.claude/settings.local.json\" ]"
echo

echo "15. reassert-file: the hardened settings.json re-assert primitive (the eject round-trip fix)"
# eject step-5's `claude plugin uninstall`/`marketplace remove` RE-SERIALIZE the project settings.json
# AFTER step-4 byte-restored it (re-canonicalize + a stray enabledPlugins:{}). cmd_eject snapshots the
# post-reversal bytes then re-asserts them via THIS verb, the FINAL authoritative write. Exercised
# directly here (independent of the CLI, mirroring section A's discipline): byte-exact restore of a
# real MIXED-INDENT/UNSORTED settings.json, idempotent no-op, credential-refuse, symlink-escape-refuse.
# The full adopt→plugin-lifecycle→eject round-trip is proven in plugin-selftest.sh §5b/§5c (which owns
# the reality-modeling stub claude — kept single-sourced there, never forked, to avoid a drifting model).
RAFIX="$(mk)"; RASNAP="$(mk)"; mkdir -p "$RAFIX/.claude"
cat > "$RAFIX/.claude/settings.json" <<'JSON'
{
  "permissions": {
      "allow": ["Bash(node:*)", "Read"]
  },
  "env": {
    "ACME_ENV": "dev"
  }
}
JSON
cp "$RAFIX/.claude/settings.json" "$RASNAP/settings.json.snap"          # the post-reversal snapshot
RAPRE_SHA="$(sha256sum "$RAFIX/.claude/settings.json" | awk '{print $1}')"
# simulate the plugin CLI's mangle: re-canonicalize to 2-space + add the stray enabledPlugins:{}
python3 -c "import json;p='$RAFIX/.claude/settings.json';d=json.load(open(p));d['enabledPlugins']={};json.dump(d,open(p,'w'),indent=2)"
RAMANGLED_SHA="$(sha256sum "$RAFIX/.claude/settings.json" | awk '{print $1}')"
chk "reassert precondition: the mangle actually changed the bytes"                 "[ \"$RAMANGLED_SHA\" != \"$RAPRE_SHA\" ]"
python3 "$AM" reassert-file --repo "$RAFIX" --path .claude/settings.json --from "$RASNAP/settings.json.snap" >/dev/null
chk "reassert: settings.json byte-restored to the EXACT snapshot (mixed-indent/unsorted preserved)"  "cmp -s \"$RASNAP/settings.json.snap\" \"$RAFIX/.claude/settings.json\""
chk "reassert: the stray enabledPlugins key is GONE (the plugin CLI's mangle undone)"                "! jq -e 'has(\"enabledPlugins\")' \"$RAFIX/.claude/settings.json\" >/dev/null 2>&1"
python3 "$AM" reassert-file --repo "$RAFIX" --path .claude/settings.json --from "$RASNAP/settings.json.snap" >/dev/null
chk "reassert: idempotent — a second call keeps it byte-identical"                                   "cmp -s \"$RASNAP/settings.json.snap\" \"$RAFIX/.claude/settings.json\""
# CREDENTIAL: refuses a secret-bearing basename outright (never writes settings.local.json)
RARC=0; python3 "$AM" reassert-file --repo "$RAFIX" --path .claude/settings.local.json --from "$RASNAP/settings.json.snap" >/dev/null 2>&1 || RARC=$?
chk "reassert CREDENTIAL-SAFE: REFUSES a secret-bearing basename (settings.local.json)"              "[ $RARC -ne 0 ]"
chk "reassert CREDENTIAL-SAFE: it did NOT create/write settings.local.json"                          "[ ! -e \"$RAFIX/.claude/settings.local.json\" ]"
# CREDENTIAL (hardening): a TRAILING SLASH must NOT evade the basename guard — normpath closes it
# ('.claude/settings.local.json/' → basename '' pre-fix slips the guard into an ugly makedirs
# traceback; → 'settings.local.json' after normpath → the CLEAN credential die). Assert the clean
# refusal (die message present, NO python traceback) so this discriminates the fix, not just exit≠0.
RARC1b=0; RAERR="$(python3 "$AM" reassert-file --repo "$RAFIX" --path .claude/settings.local.json/ --from "$RASNAP/settings.json.snap" 2>&1)" || RARC1b=$?
RACLEAN=0; { [ $RARC1b -ne 0 ] && printf '%s' "$RAERR" | grep -qi 'secret-bearing' && ! printf '%s' "$RAERR" | grep -q 'Traceback'; } && RACLEAN=1
chk "reassert CREDENTIAL-SAFE: a TRAILING-SLASH secret basename is refused by a CLEAN die (no traceback)" "[ $RACLEAN -eq 1 ]"
chk "reassert CREDENTIAL-SAFE: the trailing-slash variant did NOT create settings.local.json"           "[ ! -e \"$RAFIX/.claude/settings.local.json\" ]"
# SYMLINK ESCAPE: refuses to write through a symlink that resolves OUTSIDE the repo (Fix-B posture)
RAOUT="$(mk)"; printf 'victim\n' > "$RAOUT/v.txt"; ln -s "$RAOUT" "$RAFIX/escape"
RARC2=0; python3 "$AM" reassert-file --repo "$RAFIX" --path escape/v.txt --from "$RASNAP/settings.json.snap" >/dev/null 2>&1 || RARC2=$?
chk "reassert SYMLINK-SAFE: REFUSES a path resolving OUTSIDE the repo (exit non-zero)"               "[ $RARC2 -ne 0 ]"
chk "reassert SYMLINK-SAFE: the out-of-repo victim was NOT overwritten"                              "grep -qx 'victim' \"$RAOUT/v.txt\""
echo

echo "──────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "  ✅ kickoff eject holds"; exit 0; } || { echo "  ❌ see failures above"; exit 1; }
