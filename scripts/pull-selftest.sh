#!/usr/bin/env bash
# pull-selftest.sh — prove `kickoff pull core-vNEXT` is a VERIFIABLE engine upgrade whose
# load-bearing invariant holds: the adopter's OWN layer (CLAUDE.md, KICKOFF.local.md, crew, code,
# memory) is PROVABLY UNTOUCHED by a pull.
#
#   bash scripts/pull-selftest.sh
#
# Mirrors eject-selftest.sh (mktemp fixtures + ok/bad/chk, ONE EXIT trap cleaning only our OWN
# named dirs — never a /tmp/tmp.* wildcard sweep). It proves, in layers:
#   (1) the ADVISORY changelog delta — first-pin, the prev→target delta (prev is the boundary),
#       and same-tag ("already at").
#   (2) the WHOLE-TREE lock (format 2) + preflight #6 dual-format: NEW verifies on a clean pin and
#       FAILS on a dirty tree / wrong commit / moved tag; an OLD per-file lock still verifies.
#   (2b) pin-scope separability (the `--pin` ARGV flag): `kickoff pull` runs preflight in `pin` scope
#       (ONLY the pin checks #6 core.lock + #8 seam/plugin) by passing `--pin`, so a LIVE foreign
#       supervisor lock — the adopter's OWN running worker — no longer false-fails the pull via #4. Pin
#       scope is ARGV-ONLY: an ambient PREFLIGHT_SCOPE env var can NEVER trigger it (LOW-1 eliminated),
#       so the DEFAULT (no `--pin`) full gate is byte-behaviour-unchanged and still fail-closes on that
#       lock; pin scope still catches a corrupt pin; a real `kickoff pull` with a live lock exits 0 +
#       'PULL OK'; and a ROLLBACK to a tag whose preflight PREDATES pin scope stays honest (it ran the
#       full gate, so a live #4 fail is reported as session-readiness, never a false 'pin not coherent').
#   (3) the split-charter regen (Fix 5): gen-charter writes KICKOFF.md (seam) + KICKOFF.local.md
#       (seeded-instance); sync-seams regenerates a stale KICKOFF.md, SKIPS KICKOFF.local.md,
#       REFUSES a hand-edited seam, and --force-regenerate restores it.
#   (4) the adopters registry (Fix 7) — register/siblings/remove — and the SYMLINK-ESCAPE refusals
#       on the gen-charter / gen-shim / adopters.json writes (the eject re-review §14 carry-forward).
#   (5) THE ACCEPTANCE that gates the tag: a real git-tagged core (core-vA + core-vB), adopt against
#       core-vA, then `kickoff pull core-vB` — assert the changelog delta, the seams regenerated to
#       vB, the adopter's OWN layer byte-identical (KICKOFF.local.md, CLAUDE.md, source), the lock
#       rewritten to the NEW format at vB's commit, and the auto-preflight GREEN. Plus the parked
#       per-tag worktree when a sibling adopter sits on a different tag.
#   (6) Phase-2 G6/G7 — the PLUGIN TRANSPORT on pull (§11-§15): a same-tag re-pull with a matching
#       cache makes ZERO `claude` calls (verify-first idempotence, kills the uninstall/install churn);
#       the 2-adopter/different-tag WORKTREE COMPOSITION re-points the marketplace source to the
#       parked worktree's plugin add-ONLY (B4, real claude 2.1.203: `marketplace remove` CASCADE-
#       uninstalls — the stub models it), resyncs the cache to the pinned version WITHOUT uninstall
#       (the sibling gate — a shared cache is never swept), re-records the settings.json hash ONLY when
#       the file was pre-CLEAN (the envelope decides on PRE-divergence, never an intent flag),
#       leaves the sibling's cache dir + preflight intact, demotes the sibling-served #8 cache
#       mismatch to WARN — but a WIPED cache dir stays FAIL (F4: the demotion verifies the cache,
#       not just the installed-version pointer) — and the full adopt→pull→eject round-trip stays
#       byte-clean (--verify rc0). Plus the narrow `rehash-path` manifest verb (path-restricted,
#       updates ONLY sha256_at_write); §14 F1 — an OPERATOR-edited settings.json is never laundered
#       (pull keeps it un-rehashed, eject keeps the bytes); §15 F3 — a MISSING adopters registry
#       never licenses mechanism B (adopters-self must ALSO prove registration, else degrade to A).
#   (7) §16 — install-model NEVER dirties the pinned clone: real pnpm >= 10 mutates its TRACKED
#       pnpm-workspace.yaml config store in cwd (the 2026-07-10 pull-breaker); the dep install is
#       sandboxed OUT of the clone (only the git-ignored node_modules is swapped back in), a
#       model-installing `kickoff pull` ends PULL OK + pin-coherent, and the step-4f drift guard
#       restores + WARNs (naming the paths) if a future tool writes tracked drift anyway.
#
# Exits non-zero on ANY failed assertion. Deps: python3 + jq + git + coreutils + grep.

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
# values AFTER this and are preserved. (Post-G10b, TELEGRAM_STATE_DIR is the one that genuinely FAILS this
# suite when set — the channel-clash check sees the shared ambient channel — not just an accidental dodge.)
unset REPO_DIR KICKOFF_CORE_DIR KICKOFF_CORE_REMOTE MC_STATE_FILE MC_TRACKER_FILE \
      MEMORY_DB MEMORY_HOOK_LOG MEMORY_DIR MEMORY_INDEX TELEGRAM_STATE_DIR CHANNEL_SPEC \
      REGROUND_PROMPT PERMISSION_MODE EFFORT MODEL MAX_CONCURRENT_AGENTS DEPLOY_BRANCH \
      CADENCE INSTANCE_ENV LOCKFILE ORIGIN_STATE_DIR OPERATOR_STATE_DIR 2>/dev/null || true

PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

# A planted FAKE token for the adopter's own settings.local.json (proves a pull leaves it
# byte-identical). A shell var whose value carries "FAKE" (a scan placeholder), so this test's
# OWN source trips no secret-scanner finding — the same posture as adopt/eject-selftest's $PLANT.
PLANT='FAKE_TELEGRAM_TOKEN_planted_do_not_store_123'

# ONE EXIT trap cleans every mktemp dir — via a file side-effect so dirs mk() makes inside a
# $(command-substitution) subshell survive (an in-memory array would be lost there). NEVER a
# wildcard sweep of /tmp/tmp.* — only the exact dirs we created.
CLEANUP_LIST="$(mktemp)"
mk() { local d; d="$(mktemp -d)"; printf '%s\n' "$d" >> "$CLEANUP_LIST"; printf '%s' "$d"; }
trap 'while IFS= read -r _d; do [ -n "$_d" ] && rm -rf "$_d"; done < "$CLEANUP_LIST"; rm -f "$CLEANUP_LIST"' EXIT

echo "▶ kickoff pull self-test"
echo

command -v python3 >/dev/null 2>&1 || { echo "  ❌ python3 not found"; exit 1; }
command -v jq      >/dev/null 2>&1 || { echo "  ❌ jq not found";      exit 1; }
command -v git     >/dev/null 2>&1 || { echo "  ❌ git not found";     exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "  ❌ sha256sum not found"; exit 1; }

# ══════════════════════════════════════════════════════════════════════════════════════
# A real, minimal, git-tagged core with core-vA + core-vB whose KICKOFF.md template + changelog
# DIFFER between the two tags — so a pull to vB visibly regenerates the seam + shows the delta.
# ══════════════════════════════════════════════════════════════════════════════════════
build_core_repo() {   # echoes the core repo path
  local core; core="$(mk)"
  mkdir -p "$core/scripts/templates"
  git -C "$core" init -q; git -C "$core" config user.email t@t.t; git -C "$core" config user.name t
  cp "$REPO/scripts/preflight.sh"     "$core/scripts/preflight.sh"
  cp "$REPO/scripts/adopt-manifest.py" "$core/scripts/adopt-manifest.py"
  printf '# KICKOFF (vA)\n\nCHARTER_MARKER_VA — the coordinator charter.\n\n@.kickoff/KICKOFF.local.md\n' \
    > "$core/scripts/templates/KICKOFF.md"
  cat > "$core/scripts/core-manifest.txt" <<'MAN'
scripts/preflight.sh
scripts/adopt-manifest.py
scripts/templates/KICKOFF.md
scripts/core-manifest.txt
CORE-CHANGELOG.md
MAN
  cat > "$core/CORE-CHANGELOG.md" <<'CL'
# CORE-CHANGELOG

Read before you pull.

## core-vA — 2026-01-01

CORE_VA_CHANGELOG_MARKER — first tagged core.
CL
  git -C "$core" add -A; git -C "$core" commit -qm "core-vA"; git -C "$core" tag core-vA
  # ── evolve to vB: a NEW KICKOFF.md template + a NEW changelog section on top ──
  printf '# KICKOFF (vB)\n\nCHARTER_MARKER_VB — the coordinator charter, improved.\n\n@.kickoff/KICKOFF.local.md\n' \
    > "$core/scripts/templates/KICKOFF.md"
  cat > "$core/CORE-CHANGELOG.md" <<'CL'
# CORE-CHANGELOG

Read before you pull.

## core-vB — 2026-02-02

CORE_VB_CHANGELOG_MARKER — the upgrade.

## core-vA — 2026-01-01

CORE_VA_CHANGELOG_MARKER — first tagged core.
CL
  git -C "$core" add -A; git -C "$core" commit -qm "core-vB"; git -C "$core" tag core-vB
  git -C "$core" commit --allow-empty -qm "post-vB"   # main past vB → a fresh clone's prev_tag is empty
  printf '%s' "$core"
}

# Build the full pull CASE: a clone pinned at core-vA + an adopter ADOPTED against core-vA (mc shim,
# split charter, an operator CLAUDE.md with a kickoff block, an owned source file, a planted secret).
# Echoes "CLONE ADOPTER SNAP" (SNAP holds the pre-pull byte snapshots of the adopter-owned files).
build_pull_case() {   # $1 = core repo
  local core="$1" clone adopter snap amv
  clone="$(mk)"; adopter="$(mk)"; snap="$(mk)"
  git clone -q "$core" "$clone"
  git -C "$clone" checkout -q --detach core-vA
  mkdir -p "$adopter/src" "$adopter/memory" "$adopter/.kickoff/state" "$adopter/.claude"
  git -C "$adopter" init -q; git -C "$adopter" config user.email t@t.t; git -C "$adopter" config user.name t
  printf '# Operator CLAUDE\n\n<!-- kickoff:begin core-vA -->\n@.kickoff/KICKOFF.md\n<!-- kickoff:end -->\n\nMy own operator instructions — MUST NOT be touched by a pull.\n' \
    > "$adopter/CLAUDE.md"
  printf 'source code the operator owns — must stay byte-identical across a pull.\n' > "$adopter/src/app.txt"
  printf '# memory index\n' > "$adopter/memory/MEMORY.md"
  printf '{ "telegram": { "botToken": "%s" } }\n' "$PLANT" > "$adopter/.claude/settings.local.json"
  git -C "$adopter" add -A; git -C "$adopter" commit -qm baseline
  cat > "$adopter/.kickoff/instance.env" <<EOF
export KICKOFF_CORE_DIR="$clone"
export KICKOFF_CORE_REMOTE="$core"
export TELEGRAM_STATE_DIR="$adopter/.kickoff/chan"
export MC_STATE_FILE="$adopter/.kickoff/state/mission-state.json"
export MEMORY_DB="$adopter/.kickoff/state/memory-index.db"
export MEMORY_HOOK_LOG="$adopter/.kickoff/state/memory-hook.log"
EOF
  amv="$clone/scripts/adopt-manifest.py"
  python3 "$amv" gen-shim    --repo "$adopter" --name mc --source core-vA >/dev/null
  python3 "$amv" gen-charter --repo "$adopter" --source core-vA           >/dev/null
  cp "$adopter/.kickoff/KICKOFF.local.md"   "$snap/KICKOFF.local.md"
  cp "$adopter/CLAUDE.md"                   "$snap/CLAUDE.md"
  cp "$adopter/src/app.txt"                 "$snap/app.txt"
  cp "$adopter/.claude/settings.local.json" "$snap/settings.local.json"
  printf '%s %s %s' "$clone" "$adopter" "$snap"
}

# A minimal (CORE, ADOPTER) pin fixture for the preflight-#6 unit cases: a clean git core checkout
# + an adopter whose instance.env makes the OTHER preflight checks pass, and a NEW-format core.lock.
build_pin_fixture() {   # echoes "CORE ADOPTER"
  local core adopter sha
  core="$(mk)"; adopter="$(mk)"
  mkdir -p "$core/scripts"
  cp "$REPO/scripts/preflight.sh" "$core/scripts/preflight.sh"
  printf 'core file a\n' > "$core/scripts/a.txt"
  git -C "$core" init -q; git -C "$core" config user.email t@t.t; git -C "$core" config user.name t
  git -C "$core" add -A; git -C "$core" commit -qm core; git -C "$core" tag core-vT
  git -C "$core" checkout -q --detach core-vT
  mkdir -p "$adopter/.kickoff/state" "$adopter/memory"
  printf '# memory index\n' > "$adopter/memory/MEMORY.md"
  cat > "$adopter/.kickoff/instance.env" <<EOF
export TELEGRAM_STATE_DIR="$adopter/.kickoff/chan"
export MC_STATE_FILE="$adopter/.kickoff/state/mission-state.json"
export MEMORY_DB="$adopter/.kickoff/state/memory-index.db"
export MEMORY_HOOK_LOG="$adopter/.kickoff/state/memory-hook.log"
EOF
  python3 "$AM" gen-shim --repo "$adopter" --name mc --source core-vT >/dev/null
  sha="$(git -C "$core" rev-parse HEAD)"
  printf 'format 2\ntag core-vT\ncommit %s\n' "$sha" > "$adopter/.kickoff/core.lock"
  printf '%s %s' "$core" "$adopter"
}
run_pf() {   # $1=core (KICKOFF_CORE_DIR + the running tree) $2=adopter (REPO_DIR) → sets PF_RC, PF_OUT
  PF_RC=0
  PF_OUT="$(REPO_DIR="$2" KICKOFF_CORE_DIR="$1" bash "$1/scripts/preflight.sh" 2>&1)" || PF_RC=$?
}

CORE="$(build_core_repo)"

# ══════════════════════════════════════════════════════════════════════════════════════
echo "1. changelog delta (advisory): first-pin, prev→target delta (prev is the boundary), same-tag"
# ══════════════════════════════════════════════════════════════════════════════════════
CLAD="$(mk)"; CLCLONE="$(mk)"; mkdir -p "$CLAD/.kickoff"
printf 'export KICKOFF_CORE_DIR="%s"\nexport KICKOFF_CORE_REMOTE="%s"\n' "$CLCLONE" "$CORE" > "$CLAD/.kickoff/instance.env"
# first pin (fresh clone; main is past vB → prev_tag empty). preflight will fail on the bare
# instance.env — irrelevant; the changelog prints BEFORE preflight, so `|| true` keeps the output.
CL1="$(KICKOFF_ADOPTERS_REGISTRY="$(mk)/r.json" REPO_DIR="$CLAD" bash "$KICKOFF" pull core-vA 2>&1 || true)"
chk "first pin: reports 'first pin'"                       "printf '%s' \"\$CL1\" | grep -q 'first pin'"
chk "first pin: prints the core-vA section"               "printf '%s' \"\$CL1\" | grep -q 'CORE_VA_CHANGELOG_MARKER'"
# delta: clone now at core-vA → pull core-vB shows the vB section, with core-vA as the boundary.
CL2="$(KICKOFF_ADOPTERS_REGISTRY="$(mk)/r.json" REPO_DIR="$CLAD" bash "$KICKOFF" pull core-vB 2>&1 || true)"
chk "delta: labels it 'new since core-vA'"                "printf '%s' \"\$CL2\" | grep -q 'new since core-vA'"
chk "delta: prints the core-vB section"                   "printf '%s' \"\$CL2\" | grep -q 'CORE_VB_CHANGELOG_MARKER'"
chk "delta: core-vA is the BOUNDARY (its section excluded)" "! printf '%s' \"\$CL2\" | grep -q 'CORE_VA_CHANGELOG_MARKER'"
# same tag: clone now at core-vB → pull core-vB again → 'already at core-vB'.
CL3="$(KICKOFF_ADOPTERS_REGISTRY="$(mk)/r.json" REPO_DIR="$CLAD" bash "$KICKOFF" pull core-vB 2>&1 || true)"
chk "same tag: reports 'already at core-vB'"              "printf '%s' \"\$CL3\" | grep -q 'already at core-vB'"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "1b. rc-tag filter: a BARE pull auto-pins the highest STABLE tag, never a *-rc* pre-release"
# ══════════════════════════════════════════════════════════════════════════════════════
# A dedicated core with NUMERIC tags (core-v0.1 < core-v0.2 < core-v9.9-rc1 under `sort -V`) so the
# rc tag is the one a bare pull WOULD auto-pin pre-fix — the build_core_repo letter tags (vA/vB)
# can't prove this because `sort -V` ranks a numeric "9.9" BELOW the letters, so the rc would never
# win there. Bare pull must exclude the rc and pin the highest non-rc (core-v0.2); an EXPLICIT
# `pull core-v9.9-rc1` must STILL resolve (rc pulls stay possible, just never automatic).
RC_CORE="$(mk)"; mkdir -p "$RC_CORE/scripts/templates"
git -C "$RC_CORE" init -q; git -C "$RC_CORE" config user.email t@t.t; git -C "$RC_CORE" config user.name t
cp "$REPO/scripts/preflight.sh"      "$RC_CORE/scripts/preflight.sh"
cp "$REPO/scripts/adopt-manifest.py" "$RC_CORE/scripts/adopt-manifest.py"
printf '# KICKOFF\n@.kickoff/KICKOFF.local.md\n' > "$RC_CORE/scripts/templates/KICKOFF.md"
printf 'scripts/preflight.sh\nscripts/adopt-manifest.py\nscripts/templates/KICKOFF.md\nscripts/core-manifest.txt\nCORE-CHANGELOG.md\n' > "$RC_CORE/scripts/core-manifest.txt"
printf '# CORE-CHANGELOG\n\n## core-v0.2\n\nsecond.\n\n## core-v0.1\n\nfirst.\n' > "$RC_CORE/CORE-CHANGELOG.md"
git -C "$RC_CORE" add -A; git -C "$RC_CORE" commit -qm rc-c1;                git -C "$RC_CORE" tag core-v0.1
git -C "$RC_CORE" commit --allow-empty -qm rc-c2;                           git -C "$RC_CORE" tag core-v0.2
git -C "$RC_CORE" commit --allow-empty -qm rc-crc;                          git -C "$RC_CORE" tag core-v9.9-rc1
git -C "$RC_CORE" commit --allow-empty -qm rc-post
rc_pull() {   # $1 = tag (empty ⇒ BARE pull) → echoes the pull output (the `target tag:` line included)
  local ad cl; ad="$(mk)"; cl="$(mk)/clone"; mkdir -p "$ad/.kickoff"
  printf 'export KICKOFF_CORE_DIR="%s"\nexport KICKOFF_CORE_REMOTE="%s"\n' "$cl" "$RC_CORE" > "$ad/.kickoff/instance.env"
  KICKOFF_ADOPTERS_REGISTRY="$(mk)/r.json" REPO_DIR="$ad" bash "$KICKOFF" pull ${1:+"$1"} 2>&1 || true
}
RC_BARE="$(rc_pull "")"
RC_EXPL="$(rc_pull "core-v9.9-rc1")"
chk "BARE pull pins the highest NON-rc (core-v0.2), never core-v9.9-rc1; EXPLICIT \`pull core-v9.9-rc1\` still resolves" \
  "printf '%s' \"\$RC_BARE\" | grep -q 'target tag:  core-v0.2' && ! printf '%s' \"\$RC_BARE\" | grep -q 'target tag:  core-v9.9-rc1' && printf '%s' \"\$RC_EXPL\" | grep -q 'target tag:  core-v9.9-rc1'"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "2. whole-tree lock (format 2) + preflight #6 dual-format (NEW pass/dirty/wrong-commit/moved; OLD still verifies)"
# ══════════════════════════════════════════════════════════════════════════════════════
read -r PC PA <<< "$(build_pin_fixture)"
run_pf "$PC" "$PA"
chk "NEW clean pin: preflight exits 0"                    "[ $PF_RC -eq 0 ]"
chk "NEW clean pin: #6 reports 'whole-tree pin holds'"    "printf '%s' \"\$PF_OUT\" | grep -q 'whole-tree pin holds'"
chk "core.lock IS the NEW format (format 2 header)"       "grep -q '^format 2' \"$PA/.kickoff/core.lock\""

read -r DC DA <<< "$(build_pin_fixture)"
printf 'tampered\n' >> "$DC/scripts/a.txt"                # dirty a TRACKED file in the clone
run_pf "$DC" "$DA"
chk "NEW dirty tree: preflight FAILS (non-zero)"          "[ $PF_RC -ne 0 ]"
chk "NEW dirty tree: #6 reports the checkout is DIRTY"    "printf '%s' \"\$PF_OUT\" | grep -q 'DIRTY'"

read -r WC WA <<< "$(build_pin_fixture)"
printf 'format 2\ntag core-vT\ncommit %s\n' "0000000000000000000000000000000000000000" > "$WA/.kickoff/core.lock"
run_pf "$WC" "$WA"
chk "NEW wrong commit: preflight FAILS (non-zero)"        "[ $PF_RC -ne 0 ]"
chk "NEW wrong commit: #6 reports a pin MISMATCH"         "printf '%s' \"\$PF_OUT\" | grep -q 'MISMATCH'"

read -r MC MA <<< "$(build_pin_fixture)"
MC0="$(git -C "$MC" rev-parse HEAD)"
git -C "$MC" commit --allow-empty -qm two >/dev/null 2>&1    # HEAD → a new commit (detached)
git -C "$MC" tag -f core-vT >/dev/null 2>&1                  # move core-vT to the new commit
git -C "$MC" checkout -q --detach "$MC0"                     # HEAD back to the lock's commit
run_pf "$MC" "$MA"
chk "NEW moved tag: preflight FAILS (non-zero)"          "[ $PF_RC -ne 0 ]"
chk "NEW moved tag: #6 reports the tag MOVED"            "printf '%s' \"\$PF_OUT\" | grep -qi 'MOVED'"

read -r OC OA <<< "$(build_pin_fixture)"
( cd "$OC" && sha256sum scripts/a.txt scripts/preflight.sh ) > "$OA/.kickoff/core.lock"   # OLD per-file lock
run_pf "$OC" "$OA"
chk "OLD per-file lock STILL verifies: preflight exits 0" "[ $PF_RC -eq 0 ]"
chk "OLD per-file lock: #6 verifies via the per-file path" "printf '%s' \"\$PF_OUT\" | grep -q 'all recorded core files match'"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "2b. PREFLIGHT_SCOPE separability: pull runs pin scope (#6+#8 only), skipping #4's live-worker false-fail"
# ══════════════════════════════════════════════════════════════════════════════════════
# A pull adopter's OWN running worker holds the supervisor lock; the pull's auto-preflight used to run
# in FULL scope, so #4 (single-supervisor) HARD-failed on that live lock and the whole pull returned
# rc=1 even though the pin verified. The fix scopes the pull's preflight to PIN via the `--pin` ARGV
# flag (only the pin checks #6/#8): pin scope is reachable ONLY by passing `--pin` on the invocation —
# an environment variable can no longer trigger it, so supervisor.sh's worker-start gate and a manual
# `kickoff preflight` (neither passes `--pin`) are FULL scope BY CONSTRUCTION (the fail-closed default,
# no ambient-env-inheritance seam). These cases prove: `--pin` skips session-readiness #4 while the
# DEFAULT (no flag) full gate is byte-behaviour-unchanged; an ambient PREFLIGHT_SCOPE=pin env var is
# IGNORED (CASE 7 — LOW-1 eliminated); pin scope still catches a corrupt pin; and a rollback pull to a
# tag whose preflight PREDATES pin scope stays HONEST (CASE 8). LIVE-LOCK FIXTURE: a throwaway
# `sleep 300 &` we own (foreign to preflight's $$/$PPID), whose PID is written into the fixture's default
# LOCKFILE ($adopter/.kickoff/supervisor.lock), killed immediately after the run. Nothing real is
# touched — the fixture lives under mktemp dirs.
run_pf_pin() {   # $1=core (KICKOFF_CORE_DIR + running tree) $2=adopter (REPO_DIR) → sets PF_RC, PF_OUT
  PF_RC=0
  PF_OUT="$(REPO_DIR="$2" KICKOFF_CORE_DIR="$1" bash "$1/scripts/preflight.sh" --pin 2>&1)" || PF_RC=$?
}

# CASE 1 (the core bug, RED→GREEN): pin scope skips #4 with a LIVE competing supervisor lock → rc=0.
read -r LSC LSA <<< "$(build_pin_fixture)"
sleep 300 & LSPID=$!
printf '%s\n' "$LSPID" > "$LSA/.kickoff/supervisor.lock"     # a genuinely LIVE foreign supervisor lock
run_pf_pin "$LSC" "$LSA"
kill "$LSPID" 2>/dev/null || true
chk "pin scope: a LIVE foreign supervisor lock does NOT fail the pull (#4 skipped) — rc=0" "[ $PF_RC -eq 0 ]"
chk "pin scope: prints the scope=pin banner"                    "printf '%s' \"\$PF_OUT\" | grep -q 'scope=pin'"
chk "pin scope: #4 single-supervisor is SKIPPED (no 'another supervisor is LIVE')" \
  "! printf '%s' \"\$PF_OUT\" | grep -q 'another supervisor is LIVE'"

# CASE 2 (behaviour preserved): the DEFAULT full scope (run_pf sets NO PREFLIGHT_SCOPE) STILL
# fail-closes on the same live foreign lock — proving the default gate is untouched.
read -r F4C F4A <<< "$(build_pin_fixture)"
sleep 300 & F4PID=$!
printf '%s\n' "$F4PID" > "$F4A/.kickoff/supervisor.lock"
run_pf "$F4C" "$F4A"
kill "$F4PID" 2>/dev/null || true
chk "default full scope: STILL fails on a competing live supervisor (rc!=0)"    "[ $PF_RC -ne 0 ]"
chk "default full scope: #4 reports 'another supervisor is LIVE' (gate untouched)" \
  "printf '%s' \"\$PF_OUT\" | grep -q 'another supervisor is LIVE'"

# CASE 3 (pin scope still catches pin failures): a corrupt commit in pin scope → rc!=0 (#6 NOT skipped).
read -r PMC PMA <<< "$(build_pin_fixture)"
printf 'format 2\ntag core-vT\ncommit %s\n' "0000000000000000000000000000000000000000" > "$PMA/.kickoff/core.lock"
run_pf_pin "$PMC" "$PMA"
chk "pin scope: STILL catches a corrupt pin — #6 is NOT skipped (rc!=0)"         "[ $PF_RC -ne 0 ]"
chk "pin scope: #6 reports a pin MISMATCH"                       "printf '%s' \"\$PF_OUT\" | grep -q 'MISMATCH'"

# CASE 4 (default path byte-behaviour-preserved): clean fixture, NO lock, no PREFLIGHT_SCOPE → rc=0, no banner.
read -r D4C D4A <<< "$(build_pin_fixture)"
run_pf "$D4C" "$D4A"
chk "default full scope: clean fixture (no lock) exits 0"        "[ $PF_RC -eq 0 ]"
chk "default full scope: NO scope banner (default output byte-behaviour-preserved)" \
  "! printf '%s' \"\$PF_OUT\" | grep -q 'scope=pin'"

# CASE 5 (pin-scope happy path): clean fixture, no lock, pin scope → rc=0, banner, #6 ran, #3 skipped.
read -r P5C P5A <<< "$(build_pin_fixture)"
run_pf_pin "$P5C" "$P5A"
chk "pin scope: clean fixture exits 0 with the banner" \
  "[ $PF_RC -eq 0 ] && printf '%s' \"\$PF_OUT\" | grep -q 'scope=pin'"
chk "pin scope: #6 ran (core.lock verified — the pin was checked)" \
  "printf '%s' \"\$PF_OUT\" | grep -q 'core.lock verified'"
chk "pin scope: session-readiness #3 (memory index) was SKIPPED" \
  "! printf '%s' \"\$PF_OUT\" | grep -q 'memory index resolves'"

# CASE 6 (STRONGEST integration, RED→GREEN): a REAL `kickoff pull` with a LIVE foreign supervisor lock
# planted in the adopter exits 0 + 'PULL OK', with no misleading 'fix your instance.env' hint.
read -r I6CLONE I6ADOPTER _I6SNAP <<< "$(build_pull_case "$CORE")"
I6REG="$(mk)/adopters.json"
sleep 300 & I6PID=$!
printf '%s\n' "$I6PID" > "$I6ADOPTER/.kickoff/supervisor.lock"
I6RC=0
I6OUT="$(KICKOFF_ADOPTERS_REGISTRY="$I6REG" REPO_DIR="$I6ADOPTER" bash "$KICKOFF" pull core-vB 2>&1)" || I6RC=$?
kill "$I6PID" 2>/dev/null || true
chk "integration: a real pull with a LIVE foreign supervisor lock exits 0 (pin scope skips #4)" "[ $I6RC -eq 0 ]"
chk "integration: the pull reports 'PULL OK'"                    "printf '%s' \"\$I6OUT\" | grep -q 'PULL OK'"
chk "integration: the pull drops the misleading 'fix your instance.env' hint" \
  "! printf '%s' \"\$I6OUT\" | grep -q 'fix your instance.env'"

# CASE 7 (LOW-1 ELIMINATED — argv-only pin scope): pin scope is reachable ONLY via the `--pin` argv
# flag. An ambient PREFLIGHT_SCOPE=pin in the ENVIRONMENT (inherited from a parent shell, or smuggled
# via a launcher / instance.env) is IGNORED, so it can NEVER silence the session-readiness gate. With a
# LIVE foreign supervisor lock AND PREFLIGHT_SCOPE=pin exported but NO `--pin`, the FULL gate still runs:
# #4 fires, rc!=0, and no scope=pin banner prints. (GREEN post-fix; RED on an env-triggered variant —
# where the env var WOULD select pin scope, skip #4, and exit 0 — which is exactly the regression this
# case forbids.)
read -r E7C E7A <<< "$(build_pin_fixture)"
sleep 300 & E7PID=$!
printf '%s\n' "$E7PID" > "$E7A/.kickoff/supervisor.lock"     # a genuinely LIVE foreign supervisor lock
E7RC=0
E7OUT="$(PREFLIGHT_SCOPE=pin REPO_DIR="$E7A" KICKOFF_CORE_DIR="$E7C" bash "$E7C/scripts/preflight.sh" 2>&1)" || E7RC=$?
kill "$E7PID" 2>/dev/null || true
chk "argv-only: an ambient PREFLIGHT_SCOPE=pin env var is IGNORED (no --pin) — the FULL gate ran (rc!=0)" \
  "[ $E7RC -ne 0 ]"
chk "argv-only: the env var did NOT select pin scope (no 'scope=pin' banner)" \
  "! printf '%s' \"\$E7OUT\" | grep -q 'scope=pin'"
chk "argv-only: #4 single-supervisor FIRED on the live lock (env could not silence session-readiness)" \
  "printf '%s' \"\$E7OUT\" | grep -q 'another supervisor is LIVE'"

# CASE 8 (MED honesty — a ROLLBACK to a PRE-pin-scope tag stays honest): a `kickoff pull` of a tag whose
# preflight PREDATES pin scope (a rollback to an older core) can't be scoped — the old preflight IGNORES
# `--pin` and runs the FULL gate, so a live-worker #4 fail contaminates pf_rc. The summary MUST NOT then
# cry "pin NOT coherent" / "PULL FAILED" (the pin is fine — only session-readiness fired); it detects the
# missing pin-scope support (grep 'scope=pin' the pinned preflight) and prints the honest "PREDATES pin
# scope" branch instead. FIXTURE: a dedicated core with core-vA (the LIVE preflight, adopted against) +
# core-vOLD (the live preflight with its pin-scope machinery NEUTERED — no 'scope=pin' marker AND `--pin`
# ignored, exactly a pre-remediation core); adopt@core-vA, then roll back via `pull core-vOLD` under a
# LIVE worker lock. (GREEN post-fix; RED on the pre-remediation cmd_pull, whose 2-way summary printed
# "preflight FAIL … fix your instance.env" and never "PREDATES pin scope".)
C8CORE="$(mk)"; mkdir -p "$C8CORE/scripts/templates"
git -C "$C8CORE" init -q; git -C "$C8CORE" config user.email t@t.t; git -C "$C8CORE" config user.name t
cp "$REPO/scripts/preflight.sh"      "$C8CORE/scripts/preflight.sh"       # core-vA: the LIVE (pin-scope) preflight
cp "$REPO/scripts/adopt-manifest.py" "$C8CORE/scripts/adopt-manifest.py"
printf '# KICKOFF (vA)\n\nCHARTER_MARKER_VA — the coordinator charter.\n\n@.kickoff/KICKOFF.local.md\n' > "$C8CORE/scripts/templates/KICKOFF.md"
printf 'scripts/preflight.sh\nscripts/adopt-manifest.py\nscripts/templates/KICKOFF.md\nscripts/core-manifest.txt\nCORE-CHANGELOG.md\n' > "$C8CORE/scripts/core-manifest.txt"
printf '# CORE-CHANGELOG\n\n## core-vA — 2026-01-01\n\nCORE_VA_CHANGELOG_MARKER.\n' > "$C8CORE/CORE-CHANGELOG.md"
git -C "$C8CORE" add -A; git -C "$C8CORE" commit -qm "core-vA"; git -C "$C8CORE" tag core-vA
# core-vOLD: the SAME core but with a preflight that PREDATES pin scope — the live preflight NEUTERED so
# it (a) carries NO 'scope=pin' marker (cmd_pull's support-detection grep is FALSE) and (b) IGNORES
# `--pin` (PREFLIGHT_SCOPE can never leave 'full') ⇒ it runs the FULL gate, exactly like a pre-remediation
# core. Derived from the live file (not a hand-written stub) so it exercises the REAL checks; the
# fixture-sanity chk below fails LOUD if a refactor ever breaks the neuter.
sed -e 's/--pin) PREFLIGHT_SCOPE=pin ;;/--pin) : ;;/' -e 's/scope=pin/scope=xxx/g' \
    "$REPO/scripts/preflight.sh" > "$C8CORE/scripts/preflight.sh"
printf '# CORE-CHANGELOG\n\n## core-vOLD — 2026-03-03\n\nCORE_VOLD_CHANGELOG_MARKER.\n\n## core-vA — 2026-01-01\n\nCORE_VA_CHANGELOG_MARKER.\n' > "$C8CORE/CORE-CHANGELOG.md"
git -C "$C8CORE" add -A; git -C "$C8CORE" commit -qm "core-vOLD"; git -C "$C8CORE" tag core-vOLD
chk "CASE8 fixture: core-vOLD's preflight has NO 'scope=pin' marker (it predates pin scope)" \
  "! grep -q 'scope=pin' \"$C8CORE/scripts/preflight.sh\""
# adopt against core-vA (the modern core), then ROLL BACK to core-vOLD with the adopter's OWN live lock planted.
read -r O8CLONE O8ADOPTER _O8SNAP <<< "$(build_pull_case "$C8CORE")"
O8REG="$(mk)/adopters.json"
sleep 300 & O8PID=$!
printf '%s\n' "$O8PID" > "$O8ADOPTER/.kickoff/supervisor.lock"     # the adopter's OWN live worker lock
O8RC=0
O8OUT="$(KICKOFF_ADOPTERS_REGISTRY="$O8REG" REPO_DIR="$O8ADOPTER" bash "$KICKOFF" pull core-vOLD 2>&1)" || O8RC=$?
kill "$O8PID" 2>/dev/null || true
chk "honest rollback: a pull of a PRE-pin-scope tag prints the honest 'PREDATES pin scope' branch" \
  "printf '%s' \"\$O8OUT\" | grep -q 'PREDATES pin scope'"
chk "honest rollback: it does NOT falsely claim the pin is 'NOT coherent'" \
  "! printf '%s' \"\$O8OUT\" | grep -q 'NOT coherent'"
chk "honest rollback: it does NOT print 'PULL FAILED' (the pin verified; only session-readiness fired)" \
  "! printf '%s' \"\$O8OUT\" | grep -q 'PULL FAILED'"
chk "honest rollback: the rc!=0 came from session-readiness (#4 live lock), while the pin (#6) verified" \
  "printf '%s' \"\$O8OUT\" | grep -q 'another supervisor is LIVE' && printf '%s' \"\$O8OUT\" | grep -q 'core.lock verified'"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "3. split-charter regen (Fix 5): gen-charter, sync-seams regenerate/skip/refuse/force"
# ══════════════════════════════════════════════════════════════════════════════════════
GC="$(mk)"
python3 "$AM" gen-charter --repo "$GC" --source core-vA >/dev/null
chk "gen-charter: KICKOFF.md recorded created/seam" \
  "python3 -c \"import json;e=[x for x in json.load(open('$GC/.kickoff/adopt-manifest.json'))['entries'] if x['path']=='.kickoff/KICKOFF.md'][0];assert e['action']=='created' and e['class']=='seam'\""
chk "gen-charter: KICKOFF.local.md recorded created/seeded-instance" \
  "python3 -c \"import json;e=[x for x in json.load(open('$GC/.kickoff/adopt-manifest.json'))['entries'] if x['path']=='.kickoff/KICKOFF.local.md'][0];assert e['action']=='created' and e['class']=='seeded-instance'\""
chk "gen-charter: the seam @imports the adopter-owned local charter" \
  "grep -q '@.kickoff/KICKOFF.local.md' \"$GC/.kickoff/KICKOFF.md\""

# sync-seams regenerates a STALE KICKOFF.md, SKIPS the seeded KICKOFF.local.md, updates the hash.
GS="$(mk)"; GSNAP="$(mk)"; mkdir -p "$GS/.kickoff"
printf 'OLD CHARTER v0 — superseded\n' > "$GS/.kickoff/KICKOFF.md"
python3 "$AM" record --repo "$GS" --path .kickoff/KICKOFF.md --action created --class seam --source core-vOLD >/dev/null
printf 'ADOPTER LOCAL — must survive a sync\n' > "$GS/.kickoff/KICKOFF.local.md"
python3 "$AM" record --repo "$GS" --path .kickoff/KICKOFF.local.md --action created --class seeded-instance --source authored-for-repo >/dev/null
cp "$GS/.kickoff/KICKOFF.local.md" "$GSNAP/local"
python3 "$AM" sync-seams --repo "$GS" --source core-vNEW >/dev/null
chk "sync-seams: stale KICKOFF.md regenerated to the current template" \
  "grep -q 'coordinator charter' \"$GS/.kickoff/KICKOFF.md\" && ! grep -q 'OLD CHARTER v0' \"$GS/.kickoff/KICKOFF.md\""
chk "sync-seams: recorded KICKOFF.md hash now matches the regenerated file" \
  "[ \"\$(python3 -c \"import json;print([x for x in json.load(open('$GS/.kickoff/adopt-manifest.json'))['entries'] if x['path']=='.kickoff/KICKOFF.md'][0]['sha256_at_write'])\")\" = \"\$(sha256sum \"$GS/.kickoff/KICKOFF.md\" | awk '{print \$1}')\" ]"
chk "sync-seams: KICKOFF.local.md UNTOUCHED (seeded-instance skipped)" \
  "cmp -s \"$GSNAP/local\" \"$GS/.kickoff/KICKOFF.local.md\""

# a HAND-EDITED KICKOFF.md is REFUSED with a diff + the --force-regenerate hatch, then restored.
printf '\n# HAND-EDIT by the operator\n' >> "$GS/.kickoff/KICKOFF.md"
HE="$(sha256sum "$GS/.kickoff/KICKOFF.md" | awk '{print $1}')"
SRC=0; SROUT="$(python3 "$AM" sync-seams --repo "$GS" --source core-vNEW 2>&1)" || SRC=$?
chk "sync-seams: hand-edited KICKOFF.md REFUSED (non-zero — pull would block)" "[ $SRC -ne 0 ]"
chk "sync-seams: refusal prints a diff (@@ hunk) + names --force-regenerate" \
  "printf '%s' \"\$SROUT\" | grep -q '@@' && printf '%s' \"\$SROUT\" | grep -q -- '--force-regenerate'"
chk "sync-seams: the refused seam is left UNTOUCHED (not overwritten)" \
  "[ \"$HE\" = \"\$(sha256sum \"$GS/.kickoff/KICKOFF.md\" | awk '{print \$1}')\" ]"
python3 "$AM" sync-seams --repo "$GS" --source core-vNEW --force-regenerate >/dev/null
chk "sync-seams --force-regenerate: hand-edit DISCARDED, template restored" \
  "! grep -q 'HAND-EDIT by the operator' \"$GS/.kickoff/KICKOFF.md\""
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "4. adopters registry (register/siblings/remove) + symlink-escape refusals (re-review §14 carry-forward)"
# ══════════════════════════════════════════════════════════════════════════════════════
R4="$(mk)/r.json"; A4="$(mk)"; B4="$(mk)"
python3 "$AM" adopters-register --repo "$A4" --tag core-vA --version-dir "$A4" --registry "$R4" >/dev/null
chk "register: writes a schema-versioned row"            "jq -e '.schema_version==1 and (.adopters|length==1)' \"$R4\" >/dev/null"
chk "register: the registry file is 0600"                "[ \"\$(stat -c '%a' \"$R4\")\" = 600 ]"
python3 "$AM" adopters-register --repo "$B4" --tag core-vB --version-dir "$B4" --registry "$R4" >/dev/null
chk "siblings: A (on core-vA) sees B's different tag core-vB" \
  "python3 \"$AM\" adopters-siblings --repo \"$A4\" --tag core-vA --registry \"$R4\" | grep -q core-vB"
chk "siblings: querying A's OWN tag with no other different-tag adopter is empty" \
  "[ -z \"\$(python3 \"$AM\" adopters-siblings --repo \"$B4\" --tag core-vA --registry \"$R4\")\" ]"
python3 "$AM" adopters-remove --repo "$B4" --registry "$R4" >/dev/null
chk "remove: registry now has exactly 1 row (only A)"    "[ \"\$(jq '.adopters|length' \"$R4\")\" = 1 ]"
chk "remove: is idempotent (removing B again is a no-op, exit 0)" \
  "python3 \"$AM\" adopters-remove --repo \"$B4\" --registry \"$R4\""

# symlink-escape: gen-shim / gen-charter / adopters.json writes must NOT follow a planted symlink
# out of the target (the eject re-review §14 attack, carried forward to every record-path write).
SX="$(mk)"; SXOUT="$(mk)"; mkdir -p "$SX/.kickoff/bin"
printf 'SINK-EMPTY\n' > "$SXOUT/sink"; ln -s "$SXOUT/sink" "$SX/.kickoff/bin/mc"
GSX=0; python3 "$AM" gen-shim --repo "$SX" --name mc --source core-vA >/dev/null 2>&1 || GSX=$?
chk "gen-shim: refuses a symlink-escaping shim path (non-zero)"   "[ $GSX -ne 0 ]"
chk "gen-shim: the out-of-repo sink was NOT written"              "grep -q 'SINK-EMPTY' \"$SXOUT/sink\""

CX="$(mk)"; CXOUT="$(mk)"; mkdir -p "$CX/.kickoff"
printf 'SINK-EMPTY\n' > "$CXOUT/sink"; ln -s "$CXOUT/sink" "$CX/.kickoff/KICKOFF.md"
GCX=0; python3 "$AM" gen-charter --repo "$CX" --source core-vA >/dev/null 2>&1 || GCX=$?
chk "gen-charter: refuses a symlink-escaping KICKOFF.md path (non-zero)" "[ $GCX -ne 0 ]"
chk "gen-charter: the out-of-repo sink was NOT written"                  "grep -q 'SINK-EMPTY' \"$CXOUT/sink\""

AX="$(mk)"; AXOUT="$(mk)"; AXREG="$(mk)/adopters.json"
printf 'SINK-EMPTY\n' > "$AXOUT/sink"
ln -s "$AXOUT/sink" "$AXREG.tmp"     # THE ATTACK: a symlink at the OLD predictable-tmp name
python3 "$AM" adopters-register --repo "$AX" --tag core-vA --version-dir "$AX" --registry "$AXREG" >/dev/null 2>&1 || true
chk "adopters.json: a predictable-<registry>.tmp symlink did NOT redirect the write (sink untouched)" \
  "grep -q 'SINK-EMPTY' \"$AXOUT/sink\""
chk "adopters.json: the registry was still written correctly (mkstemp random name, not the symlink)" \
  "jq -e '.adopters[0].tag==\"core-vA\"' \"$AXREG\" >/dev/null"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "5. ACCEPTANCE (gates the tag): adopt@core-vA → \`kickoff pull core-vB\` — the adopter's own layer UNTOUCHED"
# ══════════════════════════════════════════════════════════════════════════════════════
read -r CLONE ADOPTER SNAP <<< "$(build_pull_case "$CORE")"
REG="$(mk)/adopters.json"
PRC=0
POUT="$(KICKOFF_ADOPTERS_REGISTRY="$REG" REPO_DIR="$ADOPTER" bash "$KICKOFF" pull core-vB 2>&1)" || PRC=$?
VB="$(git -C "$CLONE" rev-parse HEAD)"

chk "pull exits 0 (pull + auto-preflight GREEN under the new format)"     "[ $PRC -eq 0 ]"
chk "changelog: the core-vB section printed, core-vA is the boundary" \
  "printf '%s' \"\$POUT\" | grep -q 'CORE_VB_CHANGELOG_MARKER' && ! printf '%s' \"\$POUT\" | grep -q 'CORE_VA_CHANGELOG_MARKER'"
# seams regenerated to the vB template
chk "seam: KICKOFF.md regenerated to the vB template (CHARTER_MARKER_VB, not VA)" \
  "grep -q 'CHARTER_MARKER_VB' \"$ADOPTER/.kickoff/KICKOFF.md\" && ! grep -q 'CHARTER_MARKER_VA' \"$ADOPTER/.kickoff/KICKOFF.md\""
chk "seam: manifest KICKOFF.md hash updated to the vB template" \
  "[ \"\$(python3 -c \"import json;print([x for x in json.load(open('$ADOPTER/.kickoff/adopt-manifest.json'))['entries'] if x['path']=='.kickoff/KICKOFF.md'][0]['sha256_at_write'])\")\" = \"\$(sha256sum \"$CLONE/scripts/templates/KICKOFF.md\" | awk '{print \$1}')\" ]"
chk "seam: KICKOFF.md source re-stamped to core-vB" \
  "python3 -c \"import json;e=[x for x in json.load(open('$ADOPTER/.kickoff/adopt-manifest.json'))['entries'] if x['path']=='.kickoff/KICKOFF.md'][0];assert e['source']=='core-vB'\""
chk "seam: the mc shim was synced (source re-stamped to core-vB)" \
  "python3 -c \"import json;e=[x for x in json.load(open('$ADOPTER/.kickoff/adopt-manifest.json'))['entries'] if x['path']=='.kickoff/bin/mc'][0];assert e['source']=='core-vB'\""
# THE INVARIANT: the adopter's OWN layer is byte-identical
chk "UNTOUCHED: KICKOFF.local.md byte-identical (cmp -s)"                  "cmp -s \"$SNAP/KICKOFF.local.md\" \"$ADOPTER/.kickoff/KICKOFF.local.md\""
chk "UNTOUCHED: the operator's CLAUDE.md byte-identical (cmp -s)"         "cmp -s \"$SNAP/CLAUDE.md\" \"$ADOPTER/CLAUDE.md\""
chk "UNTOUCHED: the operator's owned source file byte-identical (cmp -s)" "cmp -s \"$SNAP/app.txt\" \"$ADOPTER/src/app.txt\""
chk "UNTOUCHED: the adopter's settings.local.json byte-identical (cmp -s)" "cmp -s \"$SNAP/settings.local.json\" \"$ADOPTER/.claude/settings.local.json\""
chk "UNTOUCHED: the planted secret still survives in the adopter's file"  "grep -qF '$PLANT' \"$ADOPTER/.claude/settings.local.json\""
# lock rewritten to the NEW format at vB's commit
chk "lock: core.lock rewritten to the NEW format (format 2)"             "grep -q '^format 2' \"$ADOPTER/.kickoff/core.lock\""
chk "lock: core.lock pins vB's commit + tag"                             "grep -q \"^commit $VB\" \"$ADOPTER/.kickoff/core.lock\" && grep -q '^tag core-vB' \"$ADOPTER/.kickoff/core.lock\""
# a STANDALONE preflight (as a pull adopter runs it, from the pinned clone) is GREEN too
PF2RC=0; PF2OUT="$(REPO_DIR="$ADOPTER" KICKOFF_CORE_DIR="$CLONE" bash "$CLONE/scripts/preflight.sh" 2>&1)" || PF2RC=$?
chk "kickoff preflight exits 0 (standalone, against the pinned clone)"    "[ $PF2RC -eq 0 ]"
# registry: this adopter registered at core-vB pointing at the root clone (no sibling → no worktree)
chk "registry: the adopter is registered at core-vB → the root clone" \
  "python3 -c \"import json,os;a=[x for x in json.load(open('$REG'))['adopters'] if os.path.realpath(x['repo'])==os.path.realpath('$ADOPTER')][0];assert a['tag']=='core-vB' and os.path.realpath(a['version_dir'])==os.path.realpath('$CLONE')\""
# CREDENTIAL-SAFE: a pull never surfaces the adopter's secret in its output
chk "CREDENTIAL-SAFE: the planted secret is ABSENT from all pull output"  "! printf '%s' \"\$POUT\" | grep -qF '$PLANT'"
# the other half of the Fix-7 lifecycle: `kickoff eject` REMOVES the adopter's registry row.
chk "registry (pre-eject): the adopter's row is present"                  "[ \"\$(jq '.adopters|length' \"$REG\")\" = 1 ]"
KICKOFF_ADOPTERS_REGISTRY="$REG" bash "$KICKOFF" eject --dir "$ADOPTER" --no-archive --purge --delete-data --confirm-destroy >/dev/null 2>&1 || true
chk "eject: REMOVES the adopter's registry row (0 rows left — Fix-7 lifecycle)" "[ \"\$(jq '.adopters|length' \"$REG\")\" = 0 ]"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "6. parked worktree: a SIBLING adopter on a different tag routes this pull to ~/kickoff-versions/<tag>/"
# ══════════════════════════════════════════════════════════════════════════════════════
read -r WCLONE WADOPTER _WSNAP <<< "$(build_pull_case "$CORE")"
WREG="$(mk)/adopters.json"; VERS="$(mk)"; OTHER="$(mk)"
# pre-seed a DIFFERENT adopter pinned at core-vA (a sibling on a different tag than our core-vB)
python3 "$AM" adopters-register --repo "$OTHER" --tag core-vA --version-dir "$WCLONE" --registry "$WREG" >/dev/null
WPRC=0
WPOUT="$(KICKOFF_ADOPTERS_REGISTRY="$WREG" KICKOFF_VERSIONS_DIR="$VERS" REPO_DIR="$WADOPTER" bash "$KICKOFF" pull core-vB 2>&1)" || WPRC=$?
chk "worktree: pull reports it is using a parked worktree"                "printf '%s' \"\$WPOUT\" | grep -q 'parked worktree'"
chk "worktree: ~/kickoff-versions/<tag>/ exists and is a git worktree"    "git -C \"$VERS/core-vB\" rev-parse --git-dir >/dev/null 2>&1"
chk "worktree: the parked worktree is detached at core-vB"                "[ \"\$(git -C \"$VERS/core-vB\" describe --tags --exact-match 2>/dev/null)\" = core-vB ]"
chk "worktree: the root clone is LEFT at core-vA (the sibling keeps it)"  "[ \"\$(git -C \"$WCLONE\" describe --tags --exact-match 2>/dev/null)\" = core-vA ]"
chk "worktree: the adopter is registered with version_dir = the worktree" \
  "python3 -c \"import json,os;a=[x for x in json.load(open('$WREG'))['adopters'] if os.path.realpath(x['repo'])==os.path.realpath('$WADOPTER')][0];assert os.path.realpath(a['version_dir'])==os.path.realpath('$VERS/core-vB')\""
chk "worktree: the pull + its auto-preflight are GREEN against the worktree" "[ $WPRC -eq 0 ]"
# ── Fix C: a worktree pull must PERSIST KICKOFF_CORE_DIR so the NEXT standalone launch works ──
# The pull parks the worktree + rewrites core.lock to the new tag, but the adopter's instance.env
# still names the ROOT clone (left on the sibling's tag). On the current code the pull's auto-
# preflight passes ONLY via a transient KICKOFF_CORE_DIR=<worktree> override, so the NEXT standalone
# `kickoff preflight`/`up` resolves KICKOFF_CORE_DIR from instance.env = the root clone → preflight
# #6/#14 fail-closed → the worker never starts (yet the pull printed "preflight PASS"). The fix
# surgically persists KICKOFF_CORE_DIR=<worktree> into instance.env.
WORKTREE="$VERS/core-vB"
chk "Fix C: the pull PERSISTED KICKOFF_CORE_DIR=<worktree> into the adopter's instance.env" \
  "grep -q \"KICKOFF_CORE_DIR=.*$VERS/core-vB\" \"$WADOPTER/.kickoff/instance.env\""
chk "Fix C: instance.env's OTHER lines are preserved (surgical replace, not a wholesale rewrite)" \
  "grep -q 'MC_STATE_FILE=' \"$WADOPTER/.kickoff/instance.env\" && grep -q 'TELEGRAM_STATE_DIR=' \"$WADOPTER/.kickoff/instance.env\""
# THE regression: a STANDALONE preflight (from the worktree, NO transient KICKOFF_CORE_DIR — it is
# resolved from the just-persisted instance.env) is GREEN. FAILS on the current code (fails-closed).
PFCRC=0; PFCOUT="$(REPO_DIR="$WADOPTER" bash "$WORKTREE/scripts/preflight.sh" 2>&1)" || PFCRC=$?
chk "Fix C: a STANDALONE preflight (KICKOFF_CORE_DIR from instance.env, no override) is GREEN — sibling not bricked" \
  "[ $PFCRC -eq 0 ]"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "7. Fix A: a SYMLINK seam can't leak an out-of-repo file's contents via the refusal diff"
# ══════════════════════════════════════════════════════════════════════════════════════
# A manifest-listed seam (.kickoff/bin/mc) is replaced by a SYMLINK to an out-of-repo file holding a
# planted secret (committed seams → a malicious PR, or a local attacker in .kickoff/). On the current
# code sync-seams follows the symlink: sha256_file() hashes the target, the on-disk hash ≠ recorded →
# the REFUSE branch → _print_seam_diff opens the target + prints its contents (the secret) to stdout.
FA="$(mk)"; FAOUT="$(mk)"; mkdir -p "$FA/.kickoff/bin"
printf 'OUT-OF-REPO PLANTED-VALUE %s\n' "$PLANT" > "$FAOUT/secret.txt"   # the exfil target (a fake secret)
printf '#!/usr/bin/env bash\nexec true\n' > "$FA/.kickoff/bin/mc"        # a normal shim, recorded created/seam
python3 "$AM" record --repo "$FA" --path .kickoff/bin/mc --action created --class seam --source core-vA >/dev/null
rm -f "$FA/.kickoff/bin/mc"; ln -s "$FAOUT/secret.txt" "$FA/.kickoff/bin/mc"   # THE ATTACK: seam → out-of-repo symlink
FARC=0; FAOUT_TXT="$(python3 "$AM" sync-seams --repo "$FA" --source core-vB 2>&1)" || FARC=$?
chk "Fix A: the out-of-repo secret is ABSENT from all sync-seams output (no leak via the diff)" \
  "! printf '%s' \"\$FAOUT_TXT\" | grep -qF '$PLANT'"
chk "Fix A: the symlink seam is REFUSED (reported as a symlink / outside-repo)" \
  "printf '%s' \"\$FAOUT_TXT\" | grep -qiE 'symlink|OUTSIDE the repo'"
chk "Fix A: sync-seams exits NON-zero (the refused seam blocks the pull)"        "[ $FARC -ne 0 ]"
chk "Fix A: the out-of-repo target was NOT regenerated/overwritten (secret intact)" \
  "grep -qF '$PLANT' \"$FAOUT/secret.txt\""
chk "Fix A: the seam path is left as the symlink (refused, never read/written)"  "[ -L \"$FA/.kickoff/bin/mc\" ]"
# proves the grep can catch a leak: the secret really is in the out-of-repo target.
chk "Fix A: the planted secret really IS in the out-of-repo target (the grep can catch a leak)" \
  "grep -qF '$PLANT' \"$FAOUT/secret.txt\""
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "8. Fix B: core.lock is written via a RANDOM mktemp name — a predictable-tmp symlink can't redirect it"
# ══════════════════════════════════════════════════════════════════════════════════════
# The whole-tree lock writer used `$lock.tmp.$$` + a plain `>` redirect — a symlink pre-planted at
# .kickoff/core.lock.tmp.<pid> is FOLLOWED, writing the lock text out-of-repo + making core.lock a
# symlink out. `exec` preserves the PID, so the wrapper's $$ IS the PID kickoff runs under: the
# planted symlink lands at exactly the name the OLD writer would open. Mirrors eject-selftest §14.
read -r BCLONE BADOPTER _BSNAP <<< "$(build_pull_case "$CORE")"
BREG="$(mk)/adopters.json"; BSINK="$(mk)/out-of-repo-sink.txt"; BKDIR="$BADOPTER/.kickoff"
printf 'SINK-EMPTY\n' > "$BSINK"
KICKOFF_ADOPTERS_REGISTRY="$BREG" REPO_DIR="$BADOPTER" bash -c '
  ln -s "$1" "$2/core.lock.tmp.$$"    # predictable-name symlink → out-of-repo sink, planted BEFORE exec
  exec bash "$3" pull core-vB
' _ "$BSINK" "$BKDIR" "$KICKOFF" >/dev/null 2>&1 || true
chk "Fix B: the out-of-repo sink was NOT written (the predictable-tmp symlink was not followed)" \
  "grep -q 'SINK-EMPTY' \"$BSINK\" && ! grep -q 'format 2' \"$BSINK\""
chk "Fix B: core.lock is a REAL file, not a symlink"                     "[ -f \"$BKDIR/core.lock\" ] && [ ! -L \"$BKDIR/core.lock\" ]"
chk "Fix B: core.lock holds the whole-tree pin (format 2)"              "grep -q '^format 2' \"$BKDIR/core.lock\""
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "9. Fix D: concurrent adopters-register does not lose rows (registry RMW is OS-locked)"
# ══════════════════════════════════════════════════════════════════════════════════════
# cmd_adopters_register did load→mutate→save with NO lock; two concurrent pulls each read the same
# registry + write back their own +1 row → one row is LOST. A dropped row → a sibling mis-detected →
# the shared clone moves out from under it. The fix holds an fcntl.flock over the whole RMW window.
DREG="$(mk)/adopters.json"; DBASE="$(mk)"; DN=20
for i in $(seq 1 "$DN"); do
  ri="$DBASE/repo-$i"; mkdir -p "$ri"
  python3 "$AM" adopters-register --repo "$ri" --tag "core-v$i" --version-dir "$ri" --registry "$DREG" >/dev/null 2>&1 &
done
wait
chk "Fix D (concurrency): all $DN concurrent registrations survived (no lost update)" \
  "[ \"\$(jq '.adopters|length' \"$DREG\")\" = $DN ]"
# DETERMINISTIC proof (never flaky): an externally-held flock on <registry>.lock makes a register
# with a short timeout fail-CLOSED — proving the RMW is actually serialized by the sidecar lock. On
# the current (unlocked) code the held lock is ignored → the register succeeds → this FAILS.
DLKRC=0
python3 - "$DREG.lock" "$AM" "$DBASE/late" "$DREG" <<'PY' || DLKRC=$?
import sys, os, fcntl, subprocess
lockpath, am, repo, reg = sys.argv[1:5]
os.makedirs(repo, exist_ok=True)
fd = os.open(lockpath, os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)                 # hold the registry lock across the child's attempt
env = dict(os.environ, KICKOFF_REGISTRY_LOCK_TIMEOUT="1")
rc = subprocess.call([sys.executable, am, "adopters-register", "--repo", repo, "--tag", "core-vLATE",
                      "--version-dir", repo, "--registry", reg], env=env,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
fcntl.flock(fd, fcntl.LOCK_UN); os.close(fd)
sys.exit(0 if rc != 0 else 1)                  # EXPECT the blocked register to fail-closed (non-zero)
PY
chk "Fix D (deterministic): a register blocked by a held lock fails-closed (RMW is serialized)" \
  "[ $DLKRC -eq 0 ]"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "10. Fix E: a CORRUPT adopters registry does not silently move the shared root clone"
# ══════════════════════════════════════════════════════════════════════════════════════
# `sibling_diff="$(... adopters-siblings ... 2>/dev/null || true)"` swallowed a NON-zero exit from a
# corrupt registry as "" → read as "no siblings" → the pull moved the SHARED root clone even when a
# differently-pinned sibling exists (bricking it). The fix distinguishes empty (exit 0) from error
# (non-zero) and aborts rather than moving the root clone.
read -r ECLONE EADOPTER _ESNAP <<< "$(build_pull_case "$CORE")"
EREG="$(mk)/adopters.json"
git -C "$ECLONE" checkout -q --detach core-vA          # the shared root clone starts at core-vA
printf 'this is NOT valid json {{{\n' > "$EREG"        # a corrupt registry → adopters-siblings FATALs
ERC=0; EOUT="$(KICKOFF_ADOPTERS_REGISTRY="$EREG" REPO_DIR="$EADOPTER" bash "$KICKOFF" pull core-vB 2>&1)" || ERC=$?
chk "Fix E: the pull does NOT silently move the root clone to core-vB (root left at core-vA)" \
  "[ \"\$(git -C \"$ECLONE\" describe --tags --exact-match 2>/dev/null)\" = core-vA ]"
chk "Fix E: the pull aborts / refuses (non-zero) on the corrupt registry"       "[ $ERC -ne 0 ]"
chk "Fix E: the refusal names the registry as the cause"                        "printf '%s' \"\$EOUT\" | grep -qi 'registry'"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
# Phase-2 G6/G7 — THE PLUGIN TRANSPORT (§11-§13). Isolation fallbacks for everything below:
# every engine call still passes its own explicit REPO_DIR/KICKOFF_CORE_DIR/
# KICKOFF_ADOPTERS_REGISTRY/CLAUDE_CONFIG_DIR; these exported fallbacks are the BACKSTOP so a
# missed one can never reach the live ~/.claude/plugins, ~/.kickoff/adopters.json, or ~/box-ingress.
# ══════════════════════════════════════════════════════════════════════════════════════
_P2ISO="$(mk)"
export CLAUDE_CONFIG_DIR="$_P2ISO/fallback-cfg"
export KICKOFF_ADOPTERS_REGISTRY="$_P2ISO/fallback-adopters.json"
export INGRESS_DIR="$_P2ISO/no-ingress-here"     # non-existent on purpose → eject SKIPS ingress
unset REPO_DIR 2>/dev/null || true

# The STUB `claude` — MIRRORS plugin-selftest.sh's reality model (which owns it; any behavior
# correction lands THERE first, then is mirrored here — never diverge the model). marketplace add →
# known_marketplaces.json (+ extraKnownMarketplaces at project scope); install → installed_plugins
# .json + a BYTE-snapshot of the plugin source → cache/<mkt>/<plugin>/<version>/ (+ enabledPlugins at
# project scope); update → version-gated re-snapshot (NO-OP unless the version STRING bumps — the
# spike finding); uninstall → sweep ALL version dirs + registry row; uninstall/marketplace-remove at
# project scope RE-SERIALIZE the project settings.json (the round-trip clobber). HARD-REFUSES without
# CLAUDE_CONFIG_DIR; LOGS every invocation to $CLAUDE_STUB_LOG.
write_stub_claude() {   # $1 = dir to place the `claude` stub in
  local d="$1"
  cat > "$d/claude" <<'PYEOF'
#!/usr/bin/env python3
import json, os, sys, shutil, tempfile

_logp = os.environ.get("CLAUDE_STUB_LOG")
if _logp:
    with open(_logp, "a") as f:
        f.write(" ".join(sys.argv[1:]) + "\n")

cfg = os.environ.get("CLAUDE_CONFIG_DIR")
if not cfg:
    sys.stderr.write("stub-claude: CLAUDE_CONFIG_DIR unset — refusing (test isolation guard)\n")
    sys.exit(3)

args = sys.argv[1:]
if not args or args[0] != "plugin":
    sys.exit(0)
args = args[1:]

plugdir  = os.path.join(cfg, "plugins")
cachedir = os.path.join(plugdir, "cache")
km_path  = os.path.join(plugdir, "known_marketplaces.json")
ip_path  = os.path.join(plugdir, "installed_plugins.json")

def load(p, default):
    try:    return json.load(open(p))
    except Exception: return default
def save(p, d):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    json.dump(d, open(p, "w"), indent=2)
def proj_settings_path():
    return os.path.join(os.getcwd(), ".claude", "settings.json")
def _assert_proj_under_tmp(p):
    rp = os.path.realpath(p)
    roots = {os.path.realpath(r) for r in (tempfile.gettempdir(), os.environ.get("TMPDIR"), "/tmp",
                                           os.environ.get("KICKOFF_STUB_FIXTURE_ROOT")) if r}
    if not any(rp == root or rp.startswith(root + os.sep) for root in roots):
        sys.stderr.write("stub-claude: REFUSING to write a project settings.json OUTSIDE a temp dir: %s "
                         "(isolation guard — a mis-cwd'd test must fail fast, never leak into a real repo)\n" % rp)
        sys.exit(4)
def load_proj():
    try:    return json.load(open(proj_settings_path()))
    except Exception: return {}
def save_proj(d):
    p = proj_settings_path(); _assert_proj_under_tmp(p); os.makedirs(os.path.dirname(p), exist_ok=True)
    json.dump(d, open(p, "w"), indent=2)

scope, scope_given, pos, i = "user", False, [], 0
while i < len(args):
    a = args[i]
    if a in ("--scope", "-s") and i + 1 < len(args):
        scope = args[i + 1]; scope_given = True; i += 2; continue
    pos.append(a); i += 1

def mkt_manifest(src):
    return json.load(open(os.path.join(src, ".claude-plugin", "marketplace.json")))
def plugin_root(src, mm, plugin):
    for p in mm.get("plugins", []):
        if p.get("name") == plugin:
            return os.path.normpath(os.path.join(src, p.get("source", "./")))
    return None
def plugin_ver(proot):
    return json.load(open(os.path.join(proot, ".claude-plugin", "plugin.json"))).get("version", "0.0.0")
def snapshot(proot, mkt, plugin, ver):
    dst = os.path.join(cachedir, mkt, plugin, ver)
    if os.path.exists(dst): shutil.rmtree(dst)
    shutil.copytree(proot, dst)
    return dst

if pos and pos[0] == "marketplace":
    sub = pos[1] if len(pos) > 1 else ""
    if sub == "add":
        src = os.path.abspath(pos[2]); mm = mkt_manifest(src); name = mm["name"]
        km = load(km_path, {}); km[name] = {"source": {"source": "directory", "path": src}, "installLocation": src}
        save(km_path, km)
        if scope == "project":
            sd = load_proj(); sd.setdefault("extraKnownMarketplaces", {})[name] = {"source": {"source": "directory", "path": src}}; save_proj(sd)
        print("Successfully added marketplace: %s" % name); sys.exit(0)
    if sub == "update":
        print("Updated marketplace(s)"); sys.exit(0)
    if sub in ("remove", "rm"):
        # B4-VALIDATED (real claude 2.1.203): `marketplace remove` CASCADE-uninstalls — it clears
        # EVERY installed row of the marketplace's plugins from the user-global installed_plugins
        # .json (scope-less remove: ALL adopters' rows — the same-box-sibling collateral) AND
        # empties them from the cwd project's enabledPlugins, alongside popping the marketplace
        # from extraKnownMarketplaces. The pre-B4 stub modeled pop-the-marketplace-ONLY, which
        # MASKED the remove-then-add re-point break (plugin left uninstalled+disabled).
        name = pos[2]; km = load(km_path, {}); km.pop(name, None); save(km_path, km)
        ip = load(ip_path, {"version": 2, "plugins": {}})
        for spec in [s for s in ip.get("plugins", {}) if s.endswith("@" + name)]:
            ip["plugins"].pop(spec, None)
        save(ip_path, ip)
        if (scope == "project" or not scope_given) and os.path.exists(proj_settings_path()):
            sd = load_proj()
            sd.get("extraKnownMarketplaces", {}).pop(name, None)
            for spec in [s for s in list(sd.get("enabledPlugins", {})) if s.endswith("@" + name)]:
                sd["enabledPlugins"].pop(spec, None)
            save_proj(sd)
        print("Removed marketplace: %s" % name); sys.exit(0)
    sys.exit(0)

if pos and pos[0] in ("install", "i"):
    spec = pos[1]; plugin, mkt = spec.split("@", 1)
    src = load(km_path, {}).get(mkt, {}).get("source", {}).get("path")
    if not src: sys.stderr.write("stub: marketplace %s not found\n" % mkt); sys.exit(1)
    mm = mkt_manifest(src); proot = plugin_root(src, mm, plugin)
    if not proot: sys.stderr.write("stub: plugin %s not in %s\n" % (plugin, mkt)); sys.exit(1)
    ver = plugin_ver(proot); dst = snapshot(proot, mkt, plugin, ver)
    ip = load(ip_path, {"version": 2, "plugins": {}}); ip.setdefault("plugins", {})[spec] = [{"scope": scope, "installPath": dst, "version": ver}]; save(ip_path, ip)
    if scope == "project":
        sd = load_proj(); sd.setdefault("enabledPlugins", {})[spec] = True; save_proj(sd)
    print("Successfully installed plugin: %s (scope: %s)" % (spec, scope)); sys.exit(0)

if pos and pos[0] == "update":
    spec = pos[1]; plugin, mkt = spec.split("@", 1)
    ip = load(ip_path, {"version": 2, "plugins": {}}); rows = ip.get("plugins", {}).get(spec, [])
    installed_scope = rows[0].get("scope") if rows else None
    if not rows:
        sys.stderr.write('✘ Failed to update plugin "%s": not installed\n' % spec); sys.exit(1)
    if installed_scope != scope:
        sys.stderr.write('✘ Failed to update plugin "%s": Plugin "%s" is not installed at scope %s\n' % (spec, plugin, scope)); sys.exit(1)
    src = load(km_path, {}).get(mkt, {}).get("source", {}).get("path")
    mm = mkt_manifest(src); proot = plugin_root(src, mm, plugin); cur = plugin_ver(proot)
    installed = rows[0].get("version")
    if installed == cur:
        print("Plugin %s is already at the latest version" % spec); sys.exit(0)
    dst = snapshot(proot, mkt, plugin, cur)
    ip["plugins"][spec] = [{"scope": installed_scope, "installPath": dst, "version": cur}]; save(ip_path, ip)
    print("Restart to apply changes"); sys.exit(0)

if pos and pos[0] in ("uninstall", "remove"):
    spec = pos[1]; plugin, mkt = spec.split("@", 1)
    ip = load(ip_path, {"version": 2, "plugins": {}}); rows = ip.get("plugins", {}).get(spec, [])
    installed_scope = rows[0].get("scope") if rows else None
    if not rows:
        sys.stderr.write('✘ Failed to uninstall plugin "%s": not installed\n' % spec); sys.exit(1)
    if installed_scope != scope:
        sys.stderr.write('✘ Failed to uninstall plugin "%s": Plugin "%s" is enabled at %s scope\n' % (spec, spec, installed_scope)); sys.exit(1)
    pdir = os.path.join(cachedir, mkt, plugin)
    if os.path.isdir(pdir): shutil.rmtree(pdir)               # sweep ALL version dirs
    ip.get("plugins", {}).pop(spec, None); save(ip_path, ip)
    if scope == "project" and os.path.exists(proj_settings_path()):
        sd = load_proj()
        sd.get("enabledPlugins", {}).pop(spec, None)
        sd.setdefault("enabledPlugins", {})
        save_proj(sd)
    print("Uninstalled %s (scope: %s)" % (spec, scope)); sys.exit(0)

sys.exit(0)
PYEOF
  chmod +x "$d/claude"
}

# A minimal plugin tree at <core>/plugin (version + content marker) — mirrors plugin-selftest.sh.
build_plugin_tree() {   # $1=core dir  $2=version  $3=marker
  local pd="$1/plugin"
  mkdir -p "$pd/.claude-plugin" "$pd/hooks" "$pd/skills/scan" "$pd/agents"
  printf '{ "name": "kickoff", "version": "%s", "description": "fake kickoff plugin", "author": {"name":"k"} }\n' "$2" > "$pd/.claude-plugin/plugin.json"
  printf '{ "name": "kickoff-local", "description": "fake local mkt", "owner": {"name":"k"}, "plugins": [ {"name":"kickoff","source":"./","description":"fake"} ] }\n' > "$pd/.claude-plugin/marketplace.json"
  printf '{ "hooks": { "UserPromptSubmit": [ {"hooks":[{"type":"command","command":"bash \\"${CLAUDE_PLUGIN_ROOT}/hooks/memory-hook.sh\\""}]} ] } }\n' > "$pd/hooks/hooks.json"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$pd/hooks/memory-hook.sh"; chmod 0755 "$pd/hooks/memory-hook.sh"
  printf '{ "mcpServers": { "chrome-devtools": {"command":"npx","args":["chrome-devtools-mcp"]} } }\n' > "$pd/.mcp.json"
  printf 'SKILL scan — content marker %s\n' "$3" > "$pd/skills/scan/SKILL.md"
  printf 'agent builder — %s\n' "$3" > "$pd/agents/builder.md"
}
# A git-tagged PLUGIN-CARRYING core: core-vA (plugin 0.1.0, marker VA) → core-vB (0.2.0, VB).
build_plugin_core() {   # echoes the core path
  local core; core="$(mk)"
  mkdir -p "$core/scripts/templates"
  git -C "$core" init -q; git -C "$core" config user.email t@t.t; git -C "$core" config user.name t
  cp "$REPO/scripts/preflight.sh"      "$core/scripts/preflight.sh"
  cp "$REPO/scripts/adopt-manifest.py" "$core/scripts/adopt-manifest.py"
  cp "$REPO/scripts/templates/kickoff.gitignore"  "$core/scripts/templates/kickoff.gitignore"
  cp "$REPO/scripts/templates/kickoff-README.md"  "$core/scripts/templates/kickoff-README.md"   # R2 seam — sync-seams regenerates .kickoff/README on pull
  printf '# KICKOFF (vA)\n\nCHARTER — the coordinator charter.\n\n@.kickoff/KICKOFF.local.md\n' > "$core/scripts/templates/KICKOFF.md"
  printf '#!/usr/bin/env bash\n# fake core scan-secrets (stub)\nexit 0\n'   > "$core/scripts/scan-secrets.sh";   chmod +x "$core/scripts/scan-secrets.sh"
  printf '#!/usr/bin/env bash\n# fake core scan-structure (stub)\nexit 0\n' > "$core/scripts/scan-structure.sh"; chmod +x "$core/scripts/scan-structure.sh"
  cat > "$core/scripts/core-manifest.txt" <<'MAN'
scripts/preflight.sh
scripts/adopt-manifest.py
scripts/scan-secrets.sh
scripts/scan-structure.sh
scripts/templates/KICKOFF.md
scripts/templates/kickoff.gitignore
scripts/templates/kickoff-README.md
scripts/core-manifest.txt
CORE-CHANGELOG.md
plugin/.claude-plugin/plugin.json
plugin/.claude-plugin/marketplace.json
plugin/hooks/hooks.json
plugin/hooks/memory-hook.sh
plugin/.mcp.json
plugin/skills
plugin/agents
MAN
  printf '# CORE-CHANGELOG\n\n## core-vA — 2026-01-01\n\nVA.\n' > "$core/CORE-CHANGELOG.md"
  build_plugin_tree "$core" "0.1.0" "VA"
  git -C "$core" add -A; git -C "$core" commit -qm core-vA; git -C "$core" tag core-vA
  build_plugin_tree "$core" "0.2.0" "VB"
  printf '# CORE-CHANGELOG\n\n## core-vB — 2026-02-02\n\nVB.\n\n## core-vA — 2026-01-01\n\nVA.\n' > "$core/CORE-CHANGELOG.md"
  git -C "$core" add -A; git -C "$core" commit -qm core-vB; git -C "$core" tag core-vB
  git -C "$core" commit --allow-empty -qm post-vB
  printf '%s' "$core"
}
# Adopt ONE adopter against a SHARED clone/cfg/registry (the one-box composition: two adopters
# share ONE plugin cache + ONE machine registry, exactly like a real box). Runs the REAL
# `kickoff adopt` through the stub claude. Echoes the adopter path.
adopt_plugin_case() {   # $1=core  $2=shared clone  $3=shared cfg  $4=shared registry  $5=stub dir
  local core="$1" clone="$2" cfg="$3" reg="$4" stub="$5" adopter
  adopter="$(mk)"
  mkdir -p "$adopter/src" "$adopter/memory" "$adopter/.kickoff/state" "$adopter/.claude"
  git -C "$adopter" init -q; git -C "$adopter" config user.email t@t.t; git -C "$adopter" config user.name t
  printf '# Operator CLAUDE\n\nMy own instructions — untouched by adopt/pull.\n' > "$adopter/CLAUDE.md"
  printf 'owned source — byte-stable across adopt+pull.\n' > "$adopter/src/app.txt"
  printf '# memory index\n' > "$adopter/memory/MEMORY.md"
  printf '{ "telegram": { "botToken": "%s" } }\n' "$PLANT" > "$adopter/.claude/settings.local.json"
  # a PRE-EXISTING, NON-jq-canonical settings.json → adopt records it json-merged (byte-restore)
  printf '{\n    "permissions": {\n        "allow": ["Bash(ls:*)"]\n    }\n}\n' > "$adopter/.claude/settings.json"
  # -f: the operator's GLOBAL gitignore may exclude settings.local.json — force-track it so the
  # baseline (and the eject --verify porcelain proof) is deterministic on ANY box.
  git -C "$adopter" add -Af; git -C "$adopter" commit -qm baseline
  # instance.env lands AFTER the baseline commit — UNTRACKED, as in a real adoption (the §G
  # .kickoff/.gitignore seam ignores it; committing it would false-dirty the eject --verify proof).
  cat > "$adopter/.kickoff/instance.env" <<EOF
export KICKOFF_CORE_DIR="$clone"
export KICKOFF_CORE_REMOTE="$core"
export TELEGRAM_STATE_DIR="$adopter/.kickoff/chan"
export MC_STATE_FILE="$adopter/.kickoff/state/mission-state.json"
export MEMORY_DB="$adopter/.kickoff/state/memory-index.db"
export MEMORY_HOOK_LOG="$adopter/.kickoff/state/memory-hook.log"
EOF
  KICKOFF_ADOPTERS_REGISTRY="$reg" KICKOFF_CORE_DIR="$clone" CLAUDE_CONFIG_DIR="$cfg" PATH="$stub:$PATH" \
    bash "$KICKOFF" adopt --dir "$adopter" >/dev/null 2>&1 || true
  printf '%s' "$adopter"
}
# read one field of the manifest's .claude/settings.json entry (empty on any failure)
settings_entry_field() {   # $1=adopter  $2=field
  python3 -c "
import json,sys
try:
    m=json.load(open(sys.argv[1]))
    e=[x for x in m.get('entries',[]) if x.get('path')=='.claude/settings.json'][0]
    print(e.get(sys.argv[2],''))
except Exception:
    print('')" "$1/.kickoff/adopt-manifest.json" "$2" 2>/dev/null || true
}

# ══════════════════════════════════════════════════════════════════════════════════════
echo "11. Phase-2 G7 verify-first: a same-tag re-pull with a MATCHING cache makes ZERO claude calls"
# ══════════════════════════════════════════════════════════════════════════════════════
# adopted@vA (cache 0.1.0 byte-matches the pinned clone) → `kickoff pull core-vA` again. Pre-fix,
# installed==pinned fired mechanism B UNCONDITIONALLY (uninstall+install churn on EVERY re-pull —
# and uninstall SWEEPS the shared cache dir, the same-tag-sibling brick). Post-fix, plugin-cache-
# verify passes → the resync is SKIPPED entirely: true idempotence, zero churn, byte-stable repo.
PCORE="$(build_plugin_core)"
S11CLONE="$(mk)"; S11CFG="$(mk)"; S11REG="$(mk)/adopters.json"; S11STUB="$(mk)"
write_stub_claude "$S11STUB"
git clone -q "$PCORE" "$S11CLONE"; git -C "$S11CLONE" checkout -q --detach core-vA
S11AD="$(adopt_plugin_case "$PCORE" "$S11CLONE" "$S11CFG" "$S11REG" "$S11STUB")"
S11SNAP="$(mk)"
cp "$S11AD/.claude/settings.json" "$S11SNAP/settings.post-adopt.json"
chk "precondition: adopt enabled the plugin (cache 0.1.0 + machine entry + settings keys)" \
  "[ -f \"$S11CFG/plugins/cache/kickoff-local/kickoff/0.1.0/.claude-plugin/plugin.json\" ] && jq -e '.enabledPlugins[\"kickoff@kickoff-local\"]==true' \"$S11AD/.claude/settings.json\" >/dev/null && [ -n \"\$(python3 \"$AM\" plugin-list --repo \"$S11AD\")\" ]"
S11LOG="$(mk)/stub.log"; : > "$S11LOG"
S11RC=0
S11OUT="$(KICKOFF_ADOPTERS_REGISTRY="$S11REG" KICKOFF_CORE_DIR="$S11CLONE" CLAUDE_CONFIG_DIR="$S11CFG" \
  CLAUDE_STUB_LOG="$S11LOG" PATH="$S11STUB:$PATH" REPO_DIR="$S11AD" \
  bash "$KICKOFF" pull core-vA 2>&1)" || S11RC=$?
chk "G7 idempotence: the same-tag re-pull exits 0 (auto-preflight GREEN)" "[ $S11RC -eq 0 ]"
chk "G7 idempotence: ZERO uninstall/install in the stub log (no mechanism-B churn) [RED pre-fix]" \
  "! grep -qE '^plugin (uninstall|install) ' \"$S11LOG\""
chk "G7 idempotence: ZERO claude invocations AT ALL (verify-first skip — the stub log is EMPTY) [RED pre-fix]" \
  "[ ! -s \"$S11LOG\" ]"
chk "G7 idempotence: the pull names the skip (cache already matches)" \
  "printf '%s' \"\$S11OUT\" | grep -qi 'already matches'"
chk "G7 idempotence: .claude/settings.json byte-identical across the re-pull" \
  "cmp -s \"$S11SNAP/settings.post-adopt.json\" \"$S11AD/.claude/settings.json\""
chk "G7 idempotence: file==record — settings.json still matches its recorded sha256_at_write" \
  "[ \"\$(settings_entry_field \"$S11AD\" sha256_at_write)\" = \"\$(sha256sum \"$S11AD/.claude/settings.json\" | awk '{print \$1}')\" ]"
chk "G7 idempotence: the 0.1.0 cache dir is UNTOUCHED (still present + fresh)" \
  "[ -f \"$S11CFG/plugins/cache/kickoff-local/kickoff/0.1.0/skills/scan/SKILL.md\" ]"
chk "CREDENTIAL-SAFE: the planted secret is ABSENT from the pull output + stub log" \
  "! printf '%s' \"\$S11OUT\" | grep -qF '$PLANT' && ! grep -qF '$PLANT' \"$S11LOG\" 2>/dev/null"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "12. Phase-2 G6+G7 COMPOSITION: 2 adopters @ different tags — worktree pull re-points + resyncs, sibling intact"
# ══════════════════════════════════════════════════════════════════════════════════════
# THE composition the validation named as never-tested: adopters X + Y share one box (one plugin
# cache, one registry, one root clone @ core-vA). X pulls core-vB → a parked worktree. The plugin
# transport must: re-point the marketplace source to the WORKTREE's plugin with `marketplace add`
# ALONE (G6 — pre-fix it stayed frozen at the adopt-time clone path, so mechanism A resynced from
# the WRONG tag and the pull bricked fail-closed; B4 — remove-then-add cascade-uninstalls, see the
# inline block below), resync X's cache to 0.2.0 WITHOUT uninstall (G7 sibling gate — uninstall
# sweeps ALL version dirs of the SHARED cache → bricks Y), keep Y's 0.1.0 cache dir intact, rehash
# the settings.json record after the INTENDED re-point write (eject's byte-restore stays valid),
# demote Y's #8 cache mismatch to WARN when the cache provably serves X's tag, and keep the full
# adopt→pull→eject round-trip byte-clean (--verify rc0).
S12CLONE="$(mk)"; S12CFG="$(mk)"; S12REG="$(mk)/adopters.json"; S12STUB="$(mk)"; S12VERS="$(mk)"
write_stub_claude "$S12STUB"
git clone -q "$PCORE" "$S12CLONE"; git -C "$S12CLONE" checkout -q --detach core-vA
S12X="$(adopt_plugin_case "$PCORE" "$S12CLONE" "$S12CFG" "$S12REG" "$S12STUB")"
S12Y="$(adopt_plugin_case "$PCORE" "$S12CLONE" "$S12CFG" "$S12REG" "$S12STUB")"
chk "precondition: BOTH adopters registered @ core-vA (one box, one registry)" \
  "[ \"\$(jq '.adopters|length' \"$S12REG\")\" = 2 ]"
# post-adopt record fields for X (the rehash must NEVER touch original/sha256_before_edit)
S12ORIG0="$(settings_entry_field "$S12X" original)"
S12BEFORE0="$(settings_entry_field "$S12X" sha256_before_edit)"
S12LOG="$(mk)/stub.log"; : > "$S12LOG"
S12RC=0
S12OUT="$(KICKOFF_ADOPTERS_REGISTRY="$S12REG" KICKOFF_CORE_DIR="$S12CLONE" KICKOFF_VERSIONS_DIR="$S12VERS" \
  CLAUDE_CONFIG_DIR="$S12CFG" CLAUDE_STUB_LOG="$S12LOG" PATH="$S12STUB:$PATH" REPO_DIR="$S12X" \
  bash "$KICKOFF" pull core-vB 2>&1)" || S12RC=$?
S12WT="$S12VERS/core-vB"
chk "composition: the pull parked a worktree @ core-vB (root clone stays on Y's core-vA)" \
  "[ \"\$(git -C \"$S12WT\" describe --tags --exact-match 2>/dev/null)\" = core-vB ] && [ \"\$(git -C \"$S12CLONE\" describe --tags --exact-match 2>/dev/null)\" = core-vA ]"
chk "composition: pull + auto-preflight GREEN (rc0) [RED pre-fix: #8 bricked on the stale cache]" \
  "[ $S12RC -eq 0 ]"
# ── G6: the effective marketplace source == the WORKTREE's plugin ──
chk "G6: known_marketplaces.json source re-pointed to \$work_dir/plugin (the worktree) [RED pre-fix]" \
  "[ \"\$(jq -r '.\"kickoff-local\".source.path' \"$S12CFG/plugins/known_marketplaces.json\")\" = \"$S12WT/plugin\" ]"
chk "G6: settings.json extraKnownMarketplaces re-pointed to the worktree plugin [RED pre-fix]" \
  "[ \"\$(jq -r '.extraKnownMarketplaces.\"kickoff-local\".source.path' \"$S12X/.claude/settings.json\")\" = \"$S12WT/plugin\" ]"
chk "G6: the machine entry's marketplace_source UPSERTED to the worktree plugin [RED pre-fix]" \
  "python3 \"$AM\" plugin-list --repo \"$S12X\" | grep -qF \"$S12WT/plugin\""
# ── B4 (validated vs REAL claude 2.1.203): the re-point must be `marketplace add` ALONE ──
# Real `marketplace remove` CASCADE-uninstalls (clears the installed rows + empties enabledPlugins/
# extraKnownMarketplaces in the cwd project's settings.json — and the scope-less remove clips the
# same-box SIBLING's rows too), and the follow-up add does NOT re-install/re-enable — so the old
# remove-then-add re-point left the plugin UNINSTALLED+DISABLED with mechanism A failing rc1 "not
# installed" and B unreachable. The stub above models the real cascade, so these four are RED on
# remove-then-add and prove the add-only fix (add on a same-named marketplace with a different
# source re-points IN PLACE — rc0, install+enable untouched, no cascade).
chk "B4 add-only re-point: ZERO \`marketplace remove\` in the stub log [RED on remove-then-add]" \
  "! grep -qE '^plugin marketplace remove ' \"$S12LOG\""
chk "B4 add-only re-point: X's plugin STAYS installed (no cascade-uninstall) [RED on remove-then-add]" \
  "jq -e '(.plugins[\"kickoff@kickoff-local\"] // []) | length > 0' \"$S12CFG/plugins/installed_plugins.json\" >/dev/null"
chk "B4 add-only re-point: X's plugin STAYS enabled in settings.json (no cascade-disable) [RED on remove-then-add]" \
  "jq -e '.enabledPlugins[\"kickoff@kickoff-local\"]==true' \"$S12X/.claude/settings.json\" >/dev/null"
chk "B4 sibling collateral: Y is NOT left enabled-but-uninstalled (enabled flag still backed by installed rows) [RED on remove-then-add]" \
  "jq -e '.enabledPlugins[\"kickoff@kickoff-local\"]==true' \"$S12Y/.claude/settings.json\" >/dev/null && jq -e '(.plugins[\"kickoff@kickoff-local\"] // []) | length > 0' \"$S12CFG/plugins/installed_plugins.json\" >/dev/null"
# ── G7: cache resynced to the pinned version, sibling-safe (no uninstall) ──
chk "G7: X's cache resynced to the pinned 0.2.0 with FRESH vB content [RED pre-fix]" \
  "grep -q 'VB' \"$S12CFG/plugins/cache/kickoff-local/kickoff/0.2.0/skills/scan/SKILL.md\" 2>/dev/null"
chk "G7 sibling gate: ZERO \`plugin uninstall\` in the stub log (the shared cache was never swept)" \
  "! grep -qE '^plugin uninstall ' \"$S12LOG\""
chk "G7 sibling gate: Y's 0.1.0 cache dir INTACT (same-box sibling not bricked)" \
  "[ -f \"$S12CFG/plugins/cache/kickoff-local/kickoff/0.1.0/skills/scan/SKILL.md\" ]"
# ── G7: the INTENDED settings write is re-recorded (file≠record never survives a kickoff write) ──
chk "G7 rehash: settings.json matches its RE-RECORDED sha256_at_write after the re-point [RED on a rehash-less fix]" \
  "[ \"\$(settings_entry_field \"$S12X\" sha256_at_write)\" = \"\$(sha256sum \"$S12X/.claude/settings.json\" | awk '{print \$1}')\" ]"
chk "G7 rehash NARROW: the entry's original bytes are UNTOUCHED (byte-restore payload preserved)" \
  "[ -n \"$S12ORIG0\" ] && [ \"\$(settings_entry_field \"$S12X\" original)\" = \"$S12ORIG0\" ]"
chk "G7 rehash NARROW: sha256_before_edit UNTOUCHED" \
  "[ -n \"$S12BEFORE0\" ] && [ \"\$(settings_entry_field \"$S12X\" sha256_before_edit)\" = \"$S12BEFORE0\" ]"
chk "registry: X re-registered @ core-vB → the worktree; Y still @ core-vA" \
  "python3 -c \"
import json,os
reg=json.load(open('$S12REG'))['adopters']
x=[a for a in reg if os.path.realpath(a['repo'])==os.path.realpath('$S12X')][0]
y=[a for a in reg if os.path.realpath(a['repo'])==os.path.realpath('$S12Y')][0]
assert x['tag']=='core-vB' and os.path.realpath(x['version_dir'])==os.path.realpath('$S12WT'), x
assert y['tag']=='core-vA', y\""
chk "CREDENTIAL-SAFE: the planted secret is ABSENT from the pull output + stub log" \
  "! printf '%s' \"\$S12OUT\" | grep -qF '$PLANT' && ! grep -qF '$PLANT' \"$S12LOG\" 2>/dev/null"
# ── both adopters' STANDALONE preflights are green after the pull ──
S12PXRC=0; REPO_DIR="$S12X" KICKOFF_CORE_DIR="$S12WT" CLAUDE_CONFIG_DIR="$S12CFG" KICKOFF_ADOPTERS_REGISTRY="$S12REG" \
  bash "$S12WT/scripts/preflight.sh" >/dev/null 2>&1 || S12PXRC=$?
chk "X standalone preflight GREEN against the worktree (cache verified @ 0.2.0) [RED pre-fix]" "[ $S12PXRC -eq 0 ]"
S12PYRC=0; REPO_DIR="$S12Y" KICKOFF_CORE_DIR="$S12CLONE" CLAUDE_CONFIG_DIR="$S12CFG" KICKOFF_ADOPTERS_REGISTRY="$S12REG" \
  bash "$S12CLONE/scripts/preflight.sh" >/dev/null 2>&1 || S12PYRC=$?
chk "Y standalone preflight GREEN (its 0.1.0 cache dir survived X's pull)" "[ $S12PYRC -eq 0 ]"
# ── #8 sibling-aware WARN: the vendor holds ONE interactive plugin per box — simulate it (Y's
# version dir swept, installed version = X's 0.2.0) → Y's cache mismatch is PROVABLY serving X's
# tag → WARN (launchable), while an UNPROVABLE mismatch stays FAIL (fail-closed kept).
rm -rf "$S12CFG/plugins/cache/kickoff-local/kickoff/0.1.0"
S12PWRC=0; S12PWOUT="$(REPO_DIR="$S12Y" KICKOFF_CORE_DIR="$S12CLONE" CLAUDE_CONFIG_DIR="$S12CFG" KICKOFF_ADOPTERS_REGISTRY="$S12REG" \
  bash "$S12CLONE/scripts/preflight.sh" 2>&1)" || S12PWRC=$?
chk "#8 WARN: a sibling-served cache mismatch is DEMOTED to WARN — Y's preflight exits 0 [RED pre-fix]" \
  "[ $S12PWRC -eq 0 ]"
chk "#8 WARN: the warning names the sibling + the headless immunity + the converge fix" \
  "printf '%s' \"\$S12PWOUT\" | grep -qi 'sibling' && printf '%s' \"\$S12PWOUT\" | grep -qi 'headless' && printf '%s' \"\$S12PWOUT\" | grep -qi 'converge'"
S12EMPTYREG="$(mk)/empty-adopters.json"
S12PNRC=0; REPO_DIR="$S12Y" KICKOFF_CORE_DIR="$S12CLONE" CLAUDE_CONFIG_DIR="$S12CFG" KICKOFF_ADOPTERS_REGISTRY="$S12EMPTYREG" \
  bash "$S12CLONE/scripts/preflight.sh" >/dev/null 2>&1 || S12PNRC=$?
chk "#8 WARN fail-closed: the SAME mismatch WITHOUT a provable sibling stays FAIL (rc≠0)" \
  "[ $S12PNRC -ne 0 ]"
# ── F4: the demotion must verify the CACHE, not just the installed-version POINTER ──
# Wipe the WHOLE plugin cache (X's 0.2.0 version dir included). installed_plugins.json still says
# 0.2.0 and the registry still proves X pins 0.2.0 — the pointer-only demotion would read that as
# the launchable sibling shape and WARN (rc0). But there is NOTHING for an interactive session to
# load: a wiped cache is a REAL missing-cache failure → #8 must keep the FAIL.
rm -rf "$S12CFG/plugins/cache/kickoff-local/kickoff"
S12PFRC=0; REPO_DIR="$S12Y" KICKOFF_CORE_DIR="$S12CLONE" CLAUDE_CONFIG_DIR="$S12CFG" KICKOFF_ADOPTERS_REGISTRY="$S12REG" \
  bash "$S12CLONE/scripts/preflight.sh" >/dev/null 2>&1 || S12PFRC=$?
chk "#8 F4: a WIPED cache dir stays FAIL even with a provable sibling POINTER (rc≠0) — the demotion requires the cache dir to exist [RED pre-fix: pointer-only demotion → WARN/rc0]" \
  "[ $S12PFRC -ne 0 ]"
# ── the round-trip: eject X (sibling present) → --verify rc0, repo byte-for-byte pristine ──
S12ERC=0
S12EOUT="$(KICKOFF_ADOPTERS_REGISTRY="$S12REG" CLAUDE_CONFIG_DIR="$S12CFG" PATH="$S12STUB:$PATH" \
  bash "$KICKOFF" eject --dir "$S12X" --no-archive --purge --delete-data --confirm-destroy --verify 2>&1)" || S12ERC=$?
chk "round-trip: adopt→pull→eject → eject --verify exits 0 (no residue, no drift)" "[ $S12ERC -eq 0 ]"
chk "round-trip: git status --porcelain LITERALLY empty (byte-for-byte pre-adopt)" \
  "[ -z \"\$(git -C \"$S12X\" -c core.excludesFile=/dev/null status --porcelain -uall 2>/dev/null)\" ]"
chk "round-trip: settings.json restored — NO plugin keys, NO worktree path" \
  "! grep -q 'kickoff-local' \"$S12X/.claude/settings.json\" && ! grep -qF \"$S12WT\" \"$S12X/.claude/settings.json\""
chk "round-trip: the sibling Y is STILL registered (eject removed only X's row)" \
  "[ \"\$(jq '.adopters|length' \"$S12REG\")\" = 1 ] && [ \"\$(jq -r '.adopters[0].repo' \"$S12REG\")\" = \"\$(cd \"$S12Y\" && pwd -P)\" ]"
chk "round-trip: Y's user-global plugin state survived X's eject (marketplace + registry entries kept)" \
  "jq -e '.\"kickoff-local\"' \"$S12CFG/plugins/known_marketplaces.json\" >/dev/null && jq -e '.plugins[\"kickoff@kickoff-local\"]' \"$S12CFG/plugins/installed_plugins.json\" >/dev/null"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "13. Phase-2: the narrow \`rehash-path\` verb — path-restricted, updates ONLY sha256_at_write"
# ══════════════════════════════════════════════════════════════════════════════════════
# The manifest half of the G6/G7 envelope: after kickoff's own INTENDED settings.json write (the
# marketplace re-point), re-record sha256_at_write so eject's hash gate stays TRUE — while the
# byte-restore payload (original/sha256_before_edit) is untouchable, and NO other path is reachable.
RH="$(mk)"; RHORIG="$(mk)/orig.json"; mkdir -p "$RH/.claude" "$RH/src"
printf '{\n   "permissions": { "allow": ["Read"] }\n}\n' > "$RH/.claude/settings.json"
cp "$RH/.claude/settings.json" "$RHORIG"
python3 "$AM" record --repo "$RH" --path .claude/settings.json --action json-merged --class seam \
  --source core-vT --original-from "$RHORIG" >/dev/null 2>&1 || true
printf 'operator source\n' > "$RH/src/app.txt"
python3 "$AM" record --repo "$RH" --path src/app.txt --action created --class seam --source core-vT >/dev/null 2>&1 || true
RHB4="$(settings_entry_field "$RH" sha256_before_edit)"
# the legitimate kickoff-driven write (what the re-point does)
printf '{\n  "permissions": { "allow": ["Read"] },\n  "extraKnownMarketplaces": { "kickoff-local": { "source": { "source": "directory", "path": "/new/worktree/plugin" } } }\n}\n' > "$RH/.claude/settings.json"
chk "rehash-path: re-records sha256_at_write for .claude/settings.json (rc0) [RED pre-fix: verb absent]" \
  "python3 \"$AM\" rehash-path --repo \"$RH\" --path .claude/settings.json"
chk "rehash-path: the recorded sha256_at_write now equals the file's hash" \
  "[ \"\$(settings_entry_field \"$RH\" sha256_at_write)\" = \"\$(sha256sum \"$RH/.claude/settings.json\" | awk '{print \$1}')\" ]"
chk "rehash-path: original is UNTOUCHED (still byte-restores the pre-adopt file)" \
  "[ \"\$(settings_entry_field \"$RH\" original)\" = \"\$(base64 -w0 \"$RHORIG\")\" ]"
chk "rehash-path: sha256_before_edit is UNTOUCHED" \
  "[ \"\$(settings_entry_field \"$RH\" sha256_before_edit)\" = \"$RHB4\" ]"
chk "rehash-path: idempotent — a second call is a clean no-op (rc0)" \
  "python3 \"$AM\" rehash-path --repo \"$RH\" --path .claude/settings.json"
chk "rehash-path: eject's byte-restore fires after the rehash (reverse restores the ORIGINAL bytes)" \
  "python3 \"$AM\" reverse --repo \"$RH\" >/dev/null 2>&1; cmp -s \"$RHORIG\" \"$RH/.claude/settings.json\""
RH2="$(mk)"; mkdir -p "$RH2/.claude" "$RH2/src" "$RH2/.kickoff"; printf 'x\n' > "$RH2/src/app.txt"
printf '{}\n' > "$RH2/.claude/settings.json"
printf '{ "t": "%s" }\n' "$PLANT" > "$RH2/.claude/settings.local.json"
printf '{"schema_version":2,"entries":[{"path":"src/app.txt","action":"created","class":"seam","source":"core-vT","sha256_at_write":"0"}],"machine_entries":[]}\n' > "$RH2/.kickoff/adopt-manifest.json"
chk "rehash-path PATH-RESTRICTED: refuses ANY path other than .claude/settings.json (src/app.txt, rc≠0)" \
  "! python3 \"$AM\" rehash-path --repo \"$RH2\" --path src/app.txt"
chk "rehash-path PATH-RESTRICTED: the src/app.txt entry's hash was NOT rewritten" \
  "python3 -c \"import json;e=[x for x in json.load(open('$RH2/.kickoff/adopt-manifest.json'))['entries'] if x['path']=='src/app.txt'][0];assert e['sha256_at_write']=='0'\""
chk "rehash-path CREDENTIAL-SAFE: refuses the secret-bearing settings.local.json (rc≠0)" \
  "! python3 \"$AM\" rehash-path --repo \"$RH2\" --path .claude/settings.local.json"
chk "rehash-path: refuses when NO manifest entry exists for settings.json (rc≠0, fail-loud)" \
  "! python3 \"$AM\" rehash-path --repo \"$RH2\" --path .claude/settings.json"
RH3="$(mk)"; RH3OUT="$(mk)"; mkdir -p "$RH3/.claude" "$RH3/.kickoff"
printf '{}\n' > "$RH3OUT/sink.json"; ln -s "$RH3OUT/sink.json" "$RH3/.claude/settings.json"
printf '{"schema_version":2,"entries":[{"path":".claude/settings.json","action":"created","class":"live-config","source":"core-vT","sha256_at_write":"0"}],"machine_entries":[]}\n' > "$RH3/.kickoff/adopt-manifest.json"
chk "rehash-path SYMLINK-SAFE: refuses a symlinked settings.json (rc≠0 — never hashes through a link)" \
  "! python3 \"$AM\" rehash-path --repo \"$RH3\" --path .claude/settings.json"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "14. Phase-2 F1 — an OPERATOR-edited settings.json is never laundered: pull(re-point) keeps it, eject keeps it"
# ══════════════════════════════════════════════════════════════════════════════════════
# THE DATA-LOSS BUG (review F1): the old envelope branched on an INTENDED flag alone — a worktree
# pull's G6 re-point set it, and the envelope REHASHED the record over whatever bytes the file held,
# INCLUDING an operator's post-adopt edit. That laundering made a later eject's hash gate read
# file==record → BYTE-RESTORE the pre-adopt original → the operator's edit silently DESTROYED.
# The fix branches on PRE-divergence: an operator-edited file is KEPT (no rehash, no reassert), and
# the un-rehashed record makes eject classify it EDITED → keep (no-clobber). Fixture: X+Y @ vA share
# one box (Y holds the root clone at vA, so X's pull to vB parks a WORKTREE → the re-point fires —
# the exact INTENDED-write path that used to launder).
S14CLONE="$(mk)"; S14CFG="$(mk)"; S14REG="$(mk)/adopters.json"; S14STUB="$(mk)"; S14VERS="$(mk)"
write_stub_claude "$S14STUB"
git clone -q "$PCORE" "$S14CLONE"; git -C "$S14CLONE" checkout -q --detach core-vA
S14X="$(adopt_plugin_case "$PCORE" "$S14CLONE" "$S14CFG" "$S14REG" "$S14STUB")"
S14Y="$(adopt_plugin_case "$PCORE" "$S14CLONE" "$S14CFG" "$S14REG" "$S14STUB")"
# the OPERATOR EDIT (post-adopt): a real config key kickoff must never destroy
S14TMP="$(mk)/edited.json"
jq '. + {"operatorEdit":"OPERATOR-F1-SENTINEL-do-not-clobber"}' "$S14X/.claude/settings.json" > "$S14TMP" \
  && mv "$S14TMP" "$S14X/.claude/settings.json"
S14REC0="$(settings_entry_field "$S14X" sha256_at_write)"
chk "F1 precondition: the operator edit DIVERGED the file from its record (hash ≠ recorded sha256_at_write)" \
  "[ -n \"$S14REC0\" ] && [ \"\$(sha256sum \"$S14X/.claude/settings.json\" | awk '{print \$1}')\" != \"$S14REC0\" ]"
S14LOG="$(mk)/stub.log"; : > "$S14LOG"
S14RC=0
S14OUT="$(KICKOFF_ADOPTERS_REGISTRY="$S14REG" KICKOFF_CORE_DIR="$S14CLONE" KICKOFF_VERSIONS_DIR="$S14VERS" \
  CLAUDE_CONFIG_DIR="$S14CFG" CLAUDE_STUB_LOG="$S14LOG" PATH="$S14STUB:$PATH" REPO_DIR="$S14X" \
  bash "$KICKOFF" pull core-vB 2>&1)" || S14RC=$?
chk "F1 precondition: the worktree pull ran the G6 re-point (marketplace re-add in the stub log — the INTENDED-write path)" \
  "grep -q 'marketplace add --scope project' \"$S14LOG\""
chk "F1: the operator's key SURVIVES the pull (the plugin CLI json-merges, never wipes)" \
  "jq -e '.operatorEdit==\"OPERATOR-F1-SENTINEL-do-not-clobber\"' \"$S14X/.claude/settings.json\" >/dev/null"
chk "F1 NO-LAUNDER: the record's sha256_at_write is UNCHANGED (the pre-diverged file was NOT rehashed) [RED pre-fix: the INTENDED-only envelope rehashed over the operator edit]" \
  "[ \"\$(settings_entry_field \"$S14X\" sha256_at_write)\" = \"$S14REC0\" ]"
chk "F1: the pull says so honestly (operator-edited → left as-is, eject will keep)" \
  "printf '%s' \"\$S14OUT\" | grep -qi 'operator-edited'"
# eject X — the round-trip half of the invariant: the hash gate reads file≠record → KEEP (no-clobber).
# (Y stays registered → X is not-last → the machine plugin unwiring is skipped; this isolates the
# reverse hash-gate as the thing under test.)
S14ERC=0
S14EOUT="$(KICKOFF_ADOPTERS_REGISTRY="$S14REG" CLAUDE_CONFIG_DIR="$S14CFG" PATH="$S14STUB:$PATH" \
  bash "$KICKOFF" eject --dir "$S14X" --no-archive --purge --delete-data --confirm-destroy 2>&1)" || S14ERC=$?
chk "F1: eject completes (rc0 — a kept diverged file is a success, not a failure)" "[ $S14ERC -eq 0 ]"
chk "F1 THE PROOF: the operator's bytes SURVIVE the eject — the sentinel key is still there (NOT byte-restored over) [RED pre-fix: laundering made file==record → eject clobbered it with the pre-adopt original]" \
  "jq -e '.operatorEdit==\"OPERATOR-F1-SENTINEL-do-not-clobber\"' \"$S14X/.claude/settings.json\" >/dev/null"
chk "F1: eject classified it honestly (EDITED after adopt → kept, reconcile manually)" \
  "printf '%s' \"\$S14EOUT\" | grep -q 'EDITED after adopt'"
chk "CREDENTIAL-SAFE: the planted secret is ABSENT from the pull + eject output + stub log" \
  "! printf '%s' \"\$S14OUT\" | grep -qF '$PLANT' && ! printf '%s' \"\$S14EOUT\" | grep -qF '$PLANT' && ! grep -qF '$PLANT' \"$S14LOG\" 2>/dev/null"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "15. Phase-2 F3 — a MISSING adopters registry NEVER licenses the destructive resync (mechanism B)"
# ══════════════════════════════════════════════════════════════════════════════════════
# THE HOLE (review F3): \`adopters-others\` exits rc0+EMPTY when the registry FILE is missing —
# vacuously "no others" — and the old gate read that as POSITIVELY SOLE → mechanism B's uninstall
# swept ALL version dirs of the SHARED user-global cache out from under a live-but-INVISIBLE
# sibling. The original fix mirrored eject's Fix-D (positively-sole ALSO required \`adopters-self\`
# rc0). SUPERSEDED by the #8 install-row sole-consumer gate (2026-07-11): the G7 gate now reads
# \`plugin-consumers-others\` — the install rows in THIS config dir's installed_plugins.json — and
# never consults the registry at all, so a missing registry STILL never licenses mechanism B: this
# fixture's shared-cfg install row (a project-scope row this stub writes WITHOUT projectPath — an
# UNKNOWN consumer, fail-closed) blocks the sweep, and the refusal WARN names the consumer(s).
# Fixture: X+Y @ vA share one cfg (Y = the sibling the registry has forgotten); the registry file
# is DELETED; a third sibling's foreign version dir sits in the shared cache (exactly what
# mechanism B's sweep destroys); X's own 0.1.0 cache is corrupted so verify-first cannot skip
# (installed==pinned 0.1.0 → the pre-fix gate picks mechanism B).
S15CLONE="$(mk)"; S15CFG="$(mk)"; S15REG="$(mk)/adopters.json"; S15STUB="$(mk)"
write_stub_claude "$S15STUB"
git clone -q "$PCORE" "$S15CLONE"; git -C "$S15CLONE" checkout -q --detach core-vA
S15X="$(adopt_plugin_case "$PCORE" "$S15CLONE" "$S15CFG" "$S15REG" "$S15STUB")"
S15Y="$(adopt_plugin_case "$PCORE" "$S15CLONE" "$S15CFG" "$S15REG" "$S15STUB")"
rm -f "$S15REG"                              # the F3 hole: NO registry file at all
mkdir -p "$S15CFG/plugins/cache/kickoff-local/kickoff/0.9.9"
printf 'a sibling adopter version dir — mechanism B uninstall would sweep me\n' \
  > "$S15CFG/plugins/cache/kickoff-local/kickoff/0.9.9/SENTINEL.txt"
printf 'TAMPER-F3\n' >> "$S15CFG/plugins/cache/kickoff-local/kickoff/0.1.0/skills/scan/SKILL.md"
S15LOG="$(mk)/stub.log"; : > "$S15LOG"
S15RC=0
S15OUT="$(KICKOFF_ADOPTERS_REGISTRY="$S15REG" KICKOFF_CORE_DIR="$S15CLONE" CLAUDE_CONFIG_DIR="$S15CFG" \
  CLAUDE_STUB_LOG="$S15LOG" PATH="$S15STUB:$PATH" REPO_DIR="$S15X" \
  bash "$KICKOFF" pull core-vA 2>&1)" || S15RC=$?
chk "F3 [RED pre-fix]: NO \`plugin uninstall\` in the stub log — the missing registry did NOT license mechanism B" \
  "! grep -qE '^plugin uninstall ' \"$S15LOG\""
chk "F3 [RED pre-fix]: the sibling's foreign version dir SURVIVED (mechanism B's sweep would have destroyed it)" \
  "[ -f \"$S15CFG/plugins/cache/kickoff-local/kickoff/0.9.9/SENTINEL.txt\" ]"
chk "F3: the pull REFUSES the destructive resync + WARNs naming the cache consumer(s) (install-row gate, fail-closed)" \
  "printf '%s' \"\$S15OUT\" | grep -q 'REFUSING'"
chk "F3: mechanism A ran instead (marketplace update + scoped plugin update in the stub log)" \
  "grep -q 'marketplace update kickoff-local' \"$S15LOG\" && grep -q 'update --scope project kickoff@kickoff-local' \"$S15LOG\""
chk "F3 heals: the pull's register step re-created the registry with this adopter's row" \
  "[ -f \"$S15REG\" ] && KICKOFF_ADOPTERS_REGISTRY=\"$S15REG\" python3 \"$AM\" adopters-self --repo \"$S15X\" >/dev/null 2>&1"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "16. install-model NEVER dirties the pinned clone (real pnpm >= 10 mutates its tracked config store)"
# ══════════════════════════════════════════════════════════════════════════════════════
# THE INCIDENT (2026-07-10 — broke the Bliz v0.4.1 upgrade real-run): cmd_pull step 4f runs
# install-model.mjs against the freshly-pinned checkout; its dep install used to run the package
# manager WITH cwd = that clone, and REAL pnpm >= 10 treats pnpm-workspace.yaml as its WRITABLE
# config store — `pnpm install` APPENDS fields (ignoredBuiltDependencies …) to that TRACKED file
# (and can exit non-zero on top). The clone went git-dirty between the pull's lock-write and its
# pin verify, so preflight #6 correctly failed closed on EVERY model-installing pull. ROOT-CAUSE
# FIX under test: the install is sandboxed OUT of the clone (a throwaway stage holds copies of
# the install inputs; only the git-ignored node_modules is swapped back on success) — the
# mutation is physically unable to land in the clone. COMPLEMENT: a step-4f drift guard restores
# + WARNs loudly if some FUTURE tool writes tracked drift anyway. The pnpm shim here behaves like
# REAL pnpm >= 10: it ALWAYS mutates ./pnpm-workspace.yaml in its cwd; leg (a) exits 0 + plants
# deps cwd-relative, leg (b) mutates-then-FAILS with npm healing after (the 928bc9c fallthrough).
# Pre-capture whether the SUITE CALLER'S cwd already holds a resolvable @xenova/transformers
# (e.g. a JS project) — the end-of-section guard below asserts §16 ADDED none (the repo-root
# residue shape: fixture side effects escaping the fixtures into the invoker's tree).
S16_CALLER_STUB_PRE=0
if [ -e ./node_modules/@xenova/transformers ]; then S16_CALLER_STUB_PRE=1; fi
MODEL_SUB16="Xenova/all-MiniLM-L6-v2"
fake_model16() {   # $1 = cache root — the 4 files install-model's presence check requires
  mkdir -p "$1/$MODEL_SUB16/onnx"
  printf '{"fake":true}\n' > "$1/$MODEL_SUB16/config.json"
  printf '{"fake":true}\n' > "$1/$MODEL_SUB16/tokenizer.json"
  printf '{"fake":true}\n' > "$1/$MODEL_SUB16/tokenizer_config.json"
  printf 'FAKE-ONNX\n'     > "$1/$MODEL_SUB16/onnx/model_quantized.onnx"
}
# A git-COMMITTED clone carrying memory-retrieval exactly as a pinned core ships it (tracked
# pnpm-workspace.yaml + .gitignore, EMPTY node_modules) — the shape step 4f runs against.
build_mr_clone() {   # echoes the clone dir
  local c; c="$(mk)"
  mkdir -p "$c/memory-retrieval/lib"
  cp "$REPO/memory-retrieval/run.sh" "$REPO/memory-retrieval"/*.mjs "$REPO/memory-retrieval/package.json" \
     "$REPO/memory-retrieval/.npmrc" "$REPO/memory-retrieval/pnpm-workspace.yaml" \
     "$REPO/memory-retrieval/.gitignore" "$c/memory-retrieval/"
  cp "$REPO/memory-retrieval/lib/"*.mjs "$c/memory-retrieval/lib/"
  git -C "$c" init -q; git -C "$c" config user.email t@t.t; git -C "$c" config user.name t
  git -C "$c" add -A; git -C "$c" commit -qm mr-core
  printf '%s' "$c"
}
# PATH shims that model REAL pnpm >= 10 / npm — INCLUDING their argv narrowness: only
# `<pm> install …` has side effects; any other argv (a `--version` probe etc.) answers a version
# + exits 0 and touches NOTHING, exactly like the real tools. (A shim that acted on ANY argv once
# left a latent stub node_modules at the SUITE CALLER'S cwd — the live repo root — via a cwd-less
# `npm --version` probe; a fixture must never be a worse citizen than the tool it models.)
# On `install`: the pnpm shim ALWAYS appends to ./pnpm-workspace.yaml in its cwd (the
# config-store write real pnpm does); mode `ok` then plants a resolvable @xenova/transformers
# CWD-RELATIVE + exits 0, mode `fail` exits 1 (mutate-then-fail). The npm shim plants
# cwd-relative + exits 0. DRIFT_TARGET (set only in the drift-guard leg) models a FUTURE
# regressed tool writing tracked drift via an ABSOLUTE path — past any sandbox. Each shim drops
# a sentinel on install so the legs can prove which managers actually ran.
write_pm_shims() {   # $1 = shim dir  $2 = pnpm mode: ok|fail  $3 = sentinel dir
  cat > "$1/pnpm" <<SH
#!/bin/sh
[ "\${1:-}" = install ] || { echo "10.99.0-stub"; exit 0; }
: > "$3/pnpm-ran"
printf 'ignoredBuiltDependencies:\n  - onnxruntime-node\n' >> ./pnpm-workspace.yaml
if [ -n "\${DRIFT_TARGET:-}" ]; then printf 'regressed-tool drift\n' >> "\$DRIFT_TARGET"; fi
if [ "$2" = ok ]; then
  mkdir -p ./node_modules/@xenova/transformers
  printf '{"name":"@xenova/transformers","main":"index.js"}\n' > ./node_modules/@xenova/transformers/package.json
  : > ./node_modules/@xenova/transformers/index.js
  exit 0
fi
echo "stub pnpm>=10: config store mutated; native build refused (non-zero)" >&2
exit 1
SH
  cat > "$1/npm" <<SH
#!/bin/sh
[ "\${1:-}" = install ] || { echo "10.99.0-stub"; exit 0; }
: > "$3/npm-ran"
mkdir -p ./node_modules/@xenova/transformers
printf '{"name":"@xenova/transformers","main":"index.js"}\n' > ./node_modules/@xenova/transformers/package.json
: > ./node_modules/@xenova/transformers/index.js
exit 0
SH
  chmod +x "$1/pnpm" "$1/npm"
}

# ── shim hygiene: a `--version` PROBE must answer cleanly and touch NOTHING (the repo-root
#    residue regression). Pre-repair shims planted on ANY argv, so a cwd-less probe (the
#    pre-fix install-model's pm detection, cwd inherited from the suite caller) left a stub
#    node_modules at the LIVE repo root — latent poison: if memory-retrieval/node_modules is
#    ever wiped, Node's ancestor walk resolves the EMPTY stub and install-model reports deps
#    healthy while embedding fails. ──
HYG_SHIM="$(mk)"; HYG_SENT="$(mk)"; HYG_CWD="$(mk)"
write_pm_shims "$HYG_SHIM" ok "$HYG_SENT"
HYG_P_RC=0; HYG_P_OUT="$(cd "$HYG_CWD" && PATH="$HYG_SHIM:$PATH" pnpm --version 2>&1)" || HYG_P_RC=$?
HYG_N_RC=0; HYG_N_OUT="$(cd "$HYG_CWD" && PATH="$HYG_SHIM:$PATH" npm --version 2>&1)" || HYG_N_RC=$?
chk "shim hygiene [RED pre-repair]: 'pnpm --version' / 'npm --version' answer a version + exit 0 (probe-safe, like the real tools)" \
  "[ $HYG_P_RC -eq 0 ] && [ $HYG_N_RC -eq 0 ] && printf '%s' \"\$HYG_P_OUT\" | grep -Eq '^[0-9]+\.' && printf '%s' \"\$HYG_N_OUT\" | grep -Eq '^[0-9]+\.'"
chk "shim hygiene [RED pre-repair]: the probes planted/mutated NOTHING at their cwd (no node_modules, no pnpm-workspace.yaml, no sentinel)" \
  "[ -z \"\$(ls -A \"$HYG_CWD\")\" ] && [ ! -e \"$HYG_SENT/pnpm-ran\" ] && [ ! -e \"$HYG_SENT/npm-ran\" ]"

# ── leg (a): pnpm >= 10 exit-0 shape — mutates its config store AND succeeds ──
MRC_A="$(build_mr_clone)"; SHIM_A="$(mk)"; SENT_A="$(mk)"; MDL_A="$(mk)"
write_pm_shims "$SHIM_A" ok "$SENT_A"; fake_model16 "$MDL_A"
IMRC_A=0
IMOUT_A="$(PATH="$SHIM_A:$PATH" KICKOFF_MODEL_DIR="$MDL_A" KICKOFF_MODEL_OFFLINE=1 MEMORY_DB="$(mk)/no-such.db" \
  node "$MRC_A/memory-retrieval/install-model.mjs" --if-needed 2>&1)" || IMRC_A=$?
chk "leg (a): install-model heals GREEN via pnpm (exit 0 — no skip-by-default regression)" \
  "[ $IMRC_A -eq 0 ] && [ -f \"$SENT_A/pnpm-ran\" ] && printf '%s' \"\$IMOUT_A\" | grep -q 'deps installed via pnpm'"
chk "leg (a): deps really landed in the clone's git-ignored node_modules (resolvable)" \
  "[ -f \"$MRC_A/memory-retrieval/node_modules/@xenova/transformers/package.json\" ]"
chk "leg (a) THE INVARIANT [RED pre-fix]: the clone is git-CLEAN after the install (porcelain EMPTY)" \
  "[ -z \"\$(git -C \"$MRC_A\" status --porcelain)\" ]"
chk "leg (a) [RED pre-fix]: the tracked pnpm-workspace.yaml is byte-identical to HEAD (the config-store write never reached it)" \
  "git -C \"$MRC_A\" diff --quiet HEAD -- memory-retrieval/pnpm-workspace.yaml"

# ── leg (b): pnpm >= 10 mutate-then-FAIL — npm fallthrough heals; clone still clean ──
MRC_B="$(build_mr_clone)"; SHIM_B="$(mk)"; SENT_B="$(mk)"; MDL_B="$(mk)"
write_pm_shims "$SHIM_B" fail "$SENT_B"; fake_model16 "$MDL_B"
mkdir -p "$MRC_B/memory-retrieval/node_modules/leftover"      # a stale half-installed tree (git-ignored)
printf 'STALE\n' > "$MRC_B/memory-retrieval/node_modules/leftover/sentinel"
IMRC_B=0
IMOUT_B="$(PATH="$SHIM_B:$PATH" KICKOFF_MODEL_DIR="$MDL_B" KICKOFF_MODEL_OFFLINE=1 MEMORY_DB="$(mk)/no-such.db" \
  node "$MRC_B/memory-retrieval/install-model.mjs" --if-needed 2>&1)" || IMRC_B=$?
chk "leg (b): after pnpm's mutate-then-FAIL, npm still gets its turn + heals GREEN (928bc9c kept)" \
  "[ $IMRC_B -eq 0 ] && [ -f \"$SENT_B/pnpm-ran\" ] && [ -f \"$SENT_B/npm-ran\" ] && printf '%s' \"\$IMOUT_B\" | grep -q 'deps installed via npm'"
chk "leg (b): the stale node_modules was replaced WHOLESALE (sentinel gone, deps resolvable — npm's clean-slate heal kept)" \
  "[ ! -e \"$MRC_B/memory-retrieval/node_modules/leftover/sentinel\" ] && [ -f \"$MRC_B/memory-retrieval/node_modules/@xenova/transformers/package.json\" ]"
chk "leg (b) THE INVARIANT [RED pre-fix]: clone git-CLEAN even though pnpm mutated AND failed (porcelain EMPTY)" \
  "[ -z \"\$(git -C \"$MRC_B\" status --porcelain)\" ]"

# ── keyword-only leg: --if-needed stays a FAST NO-OP (never surprise-installs) + clone clean ──
MRC_K="$(build_mr_clone)"; SHIM_K="$(mk)"; SENT_K="$(mk)"
write_pm_shims "$SHIM_K" ok "$SENT_K"
IMRC_K=0
IMOUT_K="$(PATH="$SHIM_K:$PATH" KICKOFF_MODEL_DIR="$(mk)/empty-models" KICKOFF_MODEL_OFFLINE=1 MEMORY_DB="$(mk)/no-such.db" \
  node "$MRC_K/memory-retrieval/install-model.mjs" --if-needed 2>&1)" || IMRC_K=$?
chk "keyword-only leg: --if-needed is a fast no-op (exit 0, 'nothing to recover', NO package manager invoked)" \
  "[ $IMRC_K -eq 0 ] && printf '%s' \"\$IMOUT_K\" | grep -q 'nothing to recover' && [ ! -e \"$SENT_K/pnpm-ran\" ] && [ ! -e \"$SENT_K/npm-ran\" ]"
chk "keyword-only leg: the clone stays git-CLEAN (porcelain EMPTY)" \
  "[ -z \"\$(git -C \"$MRC_K\" status --porcelain)\" ]"

# ── EXDEV leg: a CROSS-FILESYSTEM stage (tmpfs /dev/shm) — the node_modules swap falls back
#    from rename to a verbatim copy; deps still resolve and the clone stays clean. Skipped
#    gracefully where /dev/shm is unavailable or on the same filesystem as the fixtures.
XDEV_PROBE="$(mk)"
if [ -d /dev/shm ] && [ -w /dev/shm ] && [ "$(stat -c %d /dev/shm 2>/dev/null)" != "$(stat -c %d "$XDEV_PROBE" 2>/dev/null)" ]; then
  XDEV_MDL="$(mktemp -d -p /dev/shm)"; printf '%s\n' "$XDEV_MDL" >> "$CLEANUP_LIST"
  fake_model16 "$XDEV_MDL"
  MRC_X="$(build_mr_clone)"; SHIM_X="$(mk)"; SENT_X="$(mk)"
  write_pm_shims "$SHIM_X" ok "$SENT_X"
  IMRC_X=0
  PATH="$SHIM_X:$PATH" KICKOFF_MODEL_DIR="$XDEV_MDL" KICKOFF_MODEL_OFFLINE=1 MEMORY_DB="$(mk)/no-such.db" \
    node "$MRC_X/memory-retrieval/install-model.mjs" --if-needed >/dev/null 2>&1 || IMRC_X=$?
  chk "EXDEV leg: cross-filesystem stage → the swap's rename→copy fallback heals GREEN (deps resolve)" \
    "[ $IMRC_X -eq 0 ] && [ -f \"$MRC_X/memory-retrieval/node_modules/@xenova/transformers/package.json\" ]"
  chk "EXDEV leg: the clone stays git-CLEAN (porcelain EMPTY)" \
    "[ -z \"\$(git -C \"$MRC_X\" status --porcelain)\" ]"
else
  echo "  (/dev/shm unavailable or same filesystem — skipping the EXDEV leg)"
fi

# ── end-to-end: a model-installing `kickoff pull` — THE INCIDENT SHAPE, now PULL OK ──
# A git-tagged core that SHIPS memory-retrieval (the real files), so cmd_pull's step 4f finds
# install-model.mjs in the pinned checkout exactly like the live engine.
build_model_core() {   # echoes the core path
  local core; core="$(mk)"
  mkdir -p "$core/scripts/templates" "$core/memory-retrieval/lib"
  git -C "$core" init -q; git -C "$core" config user.email t@t.t; git -C "$core" config user.name t
  cp "$REPO/scripts/preflight.sh"      "$core/scripts/preflight.sh"
  cp "$REPO/scripts/adopt-manifest.py" "$core/scripts/adopt-manifest.py"
  printf '# KICKOFF (vA)\n\nCHARTER_MARKER_VA — the coordinator charter.\n\n@.kickoff/KICKOFF.local.md\n' \
    > "$core/scripts/templates/KICKOFF.md"
  cp "$REPO/memory-retrieval/run.sh" "$REPO/memory-retrieval"/*.mjs "$REPO/memory-retrieval/package.json" \
     "$REPO/memory-retrieval/.npmrc" "$REPO/memory-retrieval/pnpm-workspace.yaml" \
     "$REPO/memory-retrieval/.gitignore" "$core/memory-retrieval/"
  cp "$REPO/memory-retrieval/lib/"*.mjs "$core/memory-retrieval/lib/"
  printf 'scripts/preflight.sh\nscripts/adopt-manifest.py\nscripts/templates/KICKOFF.md\nscripts/core-manifest.txt\nCORE-CHANGELOG.md\nmemory-retrieval/install-model.mjs\n' \
    > "$core/scripts/core-manifest.txt"
  printf '# CORE-CHANGELOG\n\n## core-vA — 2026-01-01\n\nCORE_VA_CHANGELOG_MARKER.\n' > "$core/CORE-CHANGELOG.md"
  git -C "$core" add -A; git -C "$core" commit -qm core-vA; git -C "$core" tag core-vA
  printf '# CORE-CHANGELOG\n\n## core-vB — 2026-02-02\n\nCORE_VB_CHANGELOG_MARKER.\n\n## core-vA — 2026-01-01\n\nCORE_VA_CHANGELOG_MARKER.\n' > "$core/CORE-CHANGELOG.md"
  git -C "$core" add -A; git -C "$core" commit -qm core-vB; git -C "$core" tag core-vB
  git -C "$core" commit --allow-empty -qm post-vB
  printf '%s' "$core"
}
MCORE="$(build_model_core)"
read -r E1CLONE E1AD _E1SNAP <<< "$(build_pull_case "$MCORE")"
E1SHIM="$(mk)"; E1SENT="$(mk)"; E1MDL="$(mk)"; E1REG="$(mk)/adopters.json"
write_pm_shims "$E1SHIM" ok "$E1SENT"; fake_model16 "$E1MDL"
E1RC=0
E1OUT="$(KICKOFF_ADOPTERS_REGISTRY="$E1REG" REPO_DIR="$E1AD" PATH="$E1SHIM:$PATH" \
  KICKOFF_MODEL_DIR="$E1MDL" KICKOFF_MODEL_OFFLINE=1 MEMORY_DB="$(mk)/no-such.db" \
  bash "$KICKOFF" pull core-vB 2>&1)" || E1RC=$?
chk "e2e [RED pre-fix — THE INCIDENT]: a model-installing pull ends 'PULL OK' + pin-scope preflight GREEN (rc0)" \
  "[ $E1RC -eq 0 ] && printf '%s' \"\$E1OUT\" | grep -q 'PULL OK'"
chk "e2e: the install REALLY ran inside the pull (pnpm shim reached) and healed deps into the pinned clone" \
  "[ -f \"$E1SENT/pnpm-ran\" ] && [ -f \"$E1CLONE/memory-retrieval/node_modules/@xenova/transformers/package.json\" ]"
chk "e2e: the pinned clone is git-CLEAN after the pull (porcelain EMPTY — the whole-tree pin is coherent)" \
  "[ -z \"\$(git -C \"$E1CLONE\" status --porcelain)\" ]"
chk "e2e: the sandbox prevented the drift AT SOURCE — the step-4f drift guard never had to fire" \
  "! printf '%s' \"\$E1OUT\" | grep -q 'left the pinned core clone DIRTY'"

# ── drift guard: a FUTURE regressed tool writes tracked drift anyway → restore + LOUD warn ──
read -r E2CLONE E2AD _E2SNAP <<< "$(build_pull_case "$MCORE")"
E2SHIM="$(mk)"; E2SENT="$(mk)"; E2MDL="$(mk)"; E2REG="$(mk)/adopters.json"
write_pm_shims "$E2SHIM" ok "$E2SENT"; fake_model16 "$E2MDL"
E2RC=0
E2OUT="$(KICKOFF_ADOPTERS_REGISTRY="$E2REG" REPO_DIR="$E2AD" PATH="$E2SHIM:$PATH" \
  DRIFT_TARGET="$E2CLONE/memory-retrieval/pnpm-workspace.yaml" \
  KICKOFF_MODEL_DIR="$E2MDL" KICKOFF_MODEL_OFFLINE=1 MEMORY_DB="$(mk)/no-such.db" \
  bash "$KICKOFF" pull core-vB 2>&1)" || E2RC=$?
chk "drift guard [RED pre-fix]: a tool that STILL writes tracked drift → the pull ends pin-coherent (rc0 + PULL OK)" \
  "[ $E2RC -eq 0 ] && printf '%s' \"\$E2OUT\" | grep -q 'PULL OK'"
chk "drift guard: the ⚠ warning fired and NAMES the drifted file (pnpm-workspace.yaml)" \
  "printf '%s' \"\$E2OUT\" | grep -q 'left the pinned core clone DIRTY' && printf '%s' \"\$E2OUT\" | grep -q 'pnpm-workspace.yaml'"
chk "drift guard: the tracked file was RESTORED to the pinned bytes (clone porcelain EMPTY)" \
  "[ -z \"\$(git -C \"$E2CLONE\" status --porcelain)\" ] && git -C \"$E2CLONE\" diff --quiet HEAD -- memory-retrieval/pnpm-workspace.yaml"
chk "drift guard: the git-ignored node_modules SURVIVED the restore (clean -fd, never -x)" \
  "[ -f \"$E2CLONE/memory-retrieval/node_modules/@xenova/transformers/package.json\" ]"

# ── suite hygiene: §16's fixtures leaked NOTHING into the invoker's tree — the exact incident
#    (a planted stub node_modules at the repo root) can never recur silently. ──
chk "suite hygiene: §16 planted NO stub node_modules at the suite caller's cwd (the repo-root-residue shape)" \
  "[ $S16_CALLER_STUB_PRE -eq 1 ] || [ ! -e ./node_modules/@xenova/transformers ]"
echo

echo "──────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "  ✅ kickoff pull holds"; exit 0; } || { echo "  ❌ see failures above"; exit 1; }
