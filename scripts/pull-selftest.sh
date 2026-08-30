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
# Ambient git env OVERRIDES `git -C <fixture>` (seen live 2026-08-23: fixture commits+tag
# landed on a live repo at the v0.39 pin and leaked a stray core-vT tag) - strip it first.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE 2>/dev/null || true
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

# ONE EXIT trap: FIRST reap every fixture PROCESS we spawned, THEN clean every mktemp dir — both
# via a file side-effect so entries recorded inside a $(command-substitution) subshell survive (an
# in-memory array would be lost there). NEVER a pattern kill / a wildcard sweep of /tmp/tmp.* — only
# the exact pids + dirs this run created.
#
# The proc-reap is the SAFETY NET the inline kills need: this suite spawns long-lived `sleep 300 &`
# live-supervisor fixtures that are each killed INLINE after their case, but under `set -euo pipefail`
# a failed assertion (or a SIGINT) BETWEEN a `sleep 300 &` and its inline kill aborts the script and
# would otherwise leak that process for up to 300s. Recording each spawn's pid + reaping the whole list
# on EXIT closes that window. (Mirrors scripts/hop-selftest.sh's cleanup(): TERM → KILL each pid.)
CLEANUP_LIST="$(mktemp)"
PID_LIST="$(mktemp)"
mk() { local d; d="$(mktemp -d)"; printf '%s\n' "$d" >> "$CLEANUP_LIST"; printf '%s' "$d"; }
rec_pid() { printf '%s\n' "$1" >> "$PID_LIST"; }   # record a fixture pid for the safety-net reap
_cleanup() {
  if [ -f "$PID_LIST" ]; then
    while IFS= read -r _p; do case "$_p" in ''|*[!0-9]*) continue ;; esac; kill -TERM "$_p" 2>/dev/null || true; done < "$PID_LIST"
    while IFS= read -r _p; do case "$_p" in ''|*[!0-9]*) continue ;; esac; kill -KILL "$_p" 2>/dev/null || true; done < "$PID_LIST"
    rm -f "$PID_LIST"
  fi
  while IFS= read -r _d; do [ -n "$_d" ] && rm -rf "$_d"; done < "$CLEANUP_LIST"
  rm -f "$CLEANUP_LIST"
}
trap _cleanup EXIT

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
  # ── vB also INTRODUCES the opencode engine-parity seam set (vA lacks it entirely) — the
  #    back-fill fixture: an adopter adopted at vA records nothing for these paths, so the
  #    pull to vB is the only chance to INTRODUCE them (the v0.35 join-time-only lesson).
  #    The agents/plugins are the REAL core-root bytes (the coordinator carries the real
  #    model pin — the strip assertion below exercises the real defect, not a defanged copy).
  mkdir -p "$core/.opencode/agent" "$core/.opencode/plugins"
  for _oc_agent in builder coordinator deployer planner reviewer; do
    cp "$REPO/.opencode/agent/$_oc_agent.md" "$core/.opencode/agent/$_oc_agent.md"
  done
  cp "$REPO/.opencode/plugins/memory-search.js" "$core/.opencode/plugins/"
  cp "$REPO/.opencode/plugins/engine-credit.js" "$core/.opencode/plugins/"
  # the ADOPTER opencode.json template — heredoc-literal like the KICKOFF.md templates above
  # (fixture self-containment; the real template's own suite — adopt-selftest §12 — holds it
  #  against the real file, including the no-model-pin stance). The JSON is INDENTED so no
  # brace sits at column 1: a col-1 `}` inside this function would end any `/^…() {/,/^}/`
  # extraction of it (the repro tooling does exactly that).
  cat > "$core/scripts/templates/opencode.json" <<'OC'
    {
      "$schema": "https://opencode.ai/config.json",
      "default_agent": "coordinator",
      "instructions": [
        "AGENTS.md"
      ],
      "autoupdate": false
    }
OC
  # …and vB's core-manifest gains the set (the existence contract pull enforces).
  cat >> "$core/scripts/core-manifest.txt" <<'OCM'
.opencode/agent/builder.md
.opencode/agent/coordinator.md
.opencode/agent/deployer.md
.opencode/agent/planner.md
.opencode/agent/reviewer.md
.opencode/plugins/memory-search.js
.opencode/plugins/engine-credit.js
scripts/templates/opencode.json
OCM
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
echo "1c. stray-tag filter: BARE pull never AUTO-SELECTS a non-numeric core-v* name"
# ══════════════════════════════════════════════════════════════════════════════════════
# Bit live 2026-08-24: fixture-debris `core-vT` in a clone version-sorts ABOVE every numeric tag
# (letters rank past digits under `sort -V`), so a bare pull pinned the debris as "latest". The
# auto-select must pick the highest NUMERIC release. (Explicit `pull <tag>` stays literal-by-name
# by design — the operator asked for it and sees it echoed; see the honest-scope note at the
# tag-resolution site.)
git -C "$RC_CORE" commit --allow-empty -qm stray-c; git -C "$RC_CORE" tag core-vT
RC_STRAY_BARE="$(rc_pull "")"
chk "BARE pull ignores stray core-vT and pins the highest numeric (core-v0.2)" \
  "printf '%s' \"\$RC_STRAY_BARE\" | grep -q 'target tag:  core-v0.2' && ! printf '%s' \"\$RC_STRAY_BARE\" | grep -q 'target tag:  core-vT'"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "1b. force-moved release tag — the pin describes what origin serves NOW, not local history"
# ══════════════════════════════════════════════════════════════════════════════════════
# Bit live 2026-08-22 (the v0.38 cut): a bulk `fetch --tags` does NOT move a local tag that
# diverged from origin (non-fast-forward needs --force), so an adopter-side clone holding the
# OLD tag sha kept resolving it and pinned the PREVIOUS release while announcing the new tag
# name. The fix: after the tag NAME is validated, kickoff force-fetches exactly
# refs/tags/$tag so resolution sees origin's CURRENT target.
# ORDER IS THE TEST: the clone must be born BEFORE the upstream move, so its stale local tag
# pre-dates the pull — a clone made after the move would fetch fresh either way and prove nothing.
FM_CORE="$(mk)"; mkdir -p "$FM_CORE/scripts/templates"
git -C "$FM_CORE" init -q; git -C "$FM_CORE" config user.email t@t.t; git -C "$FM_CORE" config user.name t
cp "$REPO/scripts/preflight.sh"      "$FM_CORE/scripts/preflight.sh"
cp "$REPO/scripts/adopt-manifest.py" "$FM_CORE/scripts/adopt-manifest.py"
printf '# KICKOFF\n' > "$FM_CORE/scripts/templates/KICKOFF.md"
printf 'scripts/preflight.sh\nscripts/adopt-manifest.py\nscripts/templates/KICKOFF.md\nscripts/core-manifest.txt\nCORE-CHANGELOG.md\n' > "$FM_CORE/scripts/core-manifest.txt"
printf '# CORE-CHANGELOG\n\n## core-v0.1\n\nfirst.\n' > "$FM_CORE/CORE-CHANGELOG.md"
git -C "$FM_CORE" add -A; git -C "$FM_CORE" commit -qm fm-c1
git -C "$FM_CORE" tag core-v0.1
FM_A="$(git -C "$FM_CORE" rev-parse core-v0.1)"
FM_CL="$(mk)/clone"; git clone -q "$FM_CORE" "$FM_CL"     # adopter clone is born holding tag→FM_A
git -C "$FM_CORE" commit --allow-empty -qm fm-c2
git -C "$FM_CORE" tag -f core-v0.1 >/dev/null             # THEN the release tag is force-moved
FM_B="$(git -C "$FM_CORE" rev-parse core-v0.1)"
[ "$FM_A" != "$FM_B" ] || { echo "  FAIL fixture degenerate: tag did not move"; exit 1; }
FM_AD="$(mk)"; mkdir -p "$FM_AD/.kickoff"
printf 'export KICKOFF_CORE_DIR="%s"\nexport KICKOFF_CORE_REMOTE="%s"\n' "$FM_CL" "$FM_CORE" > "$FM_AD/.kickoff/instance.env"
FM_OUT="$(KICKOFF_ADOPTERS_REGISTRY="$(mk)/r.json" REPO_DIR="$FM_AD" bash "$KICKOFF" pull core-v0.1 2>&1 || true)"
chk "force-moved tag: lock pins ORIGIN's current target ($FM_B), never the stale local ref ($FM_A)" \
  "grep -q \"commit $FM_B\" \"$FM_AD/.kickoff/core.lock\" && ! grep -q \"commit $FM_A\" \"$FM_AD/.kickoff/core.lock\""
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
sleep 300 & LSPID=$!; rec_pid "$LSPID"
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
sleep 300 & F4PID=$!; rec_pid "$F4PID"
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
sleep 300 & I6PID=$!; rec_pid "$I6PID"
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
sleep 300 & E7PID=$!; rec_pid "$E7PID"
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
sleep 300 & O8PID=$!; rec_pid "$O8PID"
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
# QUOTING RULE (lane D, 2026-08-29): the $(jq …) here MUST stay escaped (\$) like the pre-eject
# check above — the unescaped form ran the substitution at chk-ARGUMENT time, where the inner
# \"$REG\" passed LITERAL quote chars into jq's path (ENOENT on "/…/adopters.json"), so the built
# assertion was [ "" = 0 ] and could NEVER pass; the product behavior (row removed, registry left
# with 0 rows) was proven healthy by repro. Escaped, the substitution runs INSIDE eval with clean
# quoting — the same form every passing registry check in this suite uses.
chk "eject: REMOVES the adopter's registry row (0 rows left — Fix-7 lifecycle)" "[ \"\$(jq '.adopters|length' \"$REG\")\" = 0 ]"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "5b. ENGINE-PARITY BACK-FILL: an OLD adopter (manifest lacking the opencode entries) RECEIVES the set on pull core-vB"
# ══════════════════════════════════════════════════════════════════════════════════════
# THE v0.35 LESSON, as a lane. sync-seams walks the ADOPTER'S RECORDED ENTRIES — it can UPDATE
# a seam but never INTRODUCE one. vB introduces the opencode set, and the adopter here was
# adopted at vA, so its manifest has no opencode rows: if pull only ever synced, this adopter
# would NEVER receive the set while every leg of the pull reported green. The back-fill must
# walk the SOURCE's current seam set and deliver what is missing. RED pre-feature (nothing
# delivers; the first assertion pair below fails on the absent files).
# jsonc-tolerant parse (the template carries // comments; opencode parses opencode.json as jsonc).
oc_json_pull() {   # $1 = opencode.json path → parsed dict on stdout (comment lines stripped)
  python3 -c "
import json, re, sys
text = open(sys.argv[1]).read()
print(json.loads(re.sub(r'^\s*//.*$', '', text, flags=re.M)).get(sys.argv[2], ''))
" "$1" "$2"
}
read -r BCLONE BADOPTER _BSNAP <<< "$(build_pull_case "$CORE")"
BREG="$(mk)/adopters.json"
chk "5b fixture sanity: the vA adopter starts with NO opencode wiring (the back-fill precondition)" \
  "[ ! -e \"$BADOPTER/.opencode\" ] && [ ! -e \"$BADOPTER/opencode.json\" ]"
BPRC=0
BPOUT="$(KICKOFF_ADOPTERS_REGISTRY="$BREG" REPO_DIR="$BADOPTER" bash "$KICKOFF" pull core-vB 2>&1)" || BPRC=$?
chk "5b back-fill pull exits 0 (the delivery never breaks the pin)"                    "[ $BPRC -eq 0 ]"
chk "5b all 5 crew charters DELIVERED to the old adopter"                              "[ \$(ls \"$BADOPTER/.opencode/agent/\"*.md 2>/dev/null | wc -l) -ge 5 ]"
chk "5b both plugins DELIVERED (memory-search + engine-credit)"                        "[ -s \"$BADOPTER/.opencode/plugins/memory-search.js\" ] && [ -s \"$BADOPTER/.opencode/plugins/engine-credit.js\" ]"
chk "5b the adopter opencode.json DELIVERED"                                           "[ -s \"$BADOPTER/opencode.json\" ]"
chk "5b opencode.json: default_agent == coordinator"                                   "[ \"\$(oc_json_pull \"$BADOPTER/opencode.json\" default_agent)\" = \"coordinator\" ]"
chk "5b opencode.json: pin-free — NO model/provider key anywhere (the wedge stance)" \
  "python3 -c \"
import json, re, sys
def walk(d):
    if isinstance(d, dict): return all(k not in ('model','provider') for k in d) and all(walk(v) for v in d.values())
    if isinstance(d, list): return all(walk(v) for v in d)
    return True
text = open('$BADOPTER/opencode.json').read()
assert walk(json.loads(re.sub(r'^\s*//.*$', '', text, flags=re.M)))\""
chk "5b the delivered coordinator charter carries NO model pin (stripped at delivery)" \
  "! grep -q '^model:' \"$BADOPTER/.opencode/agent/coordinator.md\" && ! grep -q 'x-preview-f-free' \"$BADOPTER/.opencode/agent/coordinator.md\""
chk "5b the other charters travel VERBATIM (builder byte-matches the pinned core)" \
  "cmp -s \"$BADOPTER/.opencode/agent/builder.md\" \"$BCLONE/.opencode/agent/builder.md\""
chk "5b the set is RECORDED created/seam (sync-seams + eject own it from here on)" \
  "[ \$(python3 -c \"import json;print(sum(1 for e in json.load(open('$BADOPTER/.kickoff/adopt-manifest.json'))['entries'] if e['class']=='seam' and (e['path'].startswith('.opencode/') or e['path']=='opencode.json')))\" 2>/dev/null) -ge 8 ]"
chk "5b the pull DISCLOSED the introduction (an opencode line in its output)"          "printf '%s' \"\$BPOUT\" | grep -qi opencode"
BPFRC=0; BPFOUT="$(REPO_DIR="$BADOPTER" KICKOFF_CORE_DIR="$BCLONE" bash "$BCLONE/scripts/preflight.sh" 2>&1)" || BPFRC=$?
chk "5b standalone preflight after the back-fill is GREEN (the new rows hash-verify)"  "[ $BPFRC -eq 0 ]"

# ── the BOXE GUARD — the adopter-owned folklore shape. A pre-existing .opencode with
#    DIFFERING files (hand-placed, untracked, its own opencode.json carrying a model pin)
#    is NEVER clobbered: left as-is, disclosed, not recorded — and the pull stays green.
read -r XCLONE XADOPTER _XSNAP <<< "$(build_pull_case "$CORE")"
XREG="$(mk)/adopters.json"
mkdir -p "$XADOPTER/.opencode/agent"
printf -- '---\ndescription: THEIR OWN hand-placed coordinator\nmode: primary\nmodel: opencode/x-preview-f-free\n---\nTheir bytes.\n' > "$XADOPTER/.opencode/agent/coordinator.md"
printf '{\n  "default_agent": "coordinator",\n  "provider": { "opencode": { "models": { "x-preview-f-free": {} } } }\n}\n' > "$XADOPTER/opencode.json"
cp "$XADOPTER/.opencode/agent/coordinator.md" "$XADOPTER/coordinator.pre"
cp "$XADOPTER/opencode.json"                   "$XADOPTER/opencodejson.pre"
XPRC=0
XPOUT="$(KICKOFF_ADOPTERS_REGISTRY="$XREG" REPO_DIR="$XADOPTER" bash "$KICKOFF" pull core-vB 2>&1)" || XPRC=$?
chk "5b boxe: the pull exits 0 with adopter-owned .opencode present"                   "[ $XPRC -eq 0 ]"
chk "5b boxe: THEIR coordinator.md is byte-identical after the pull (never clobbered)" "cmp -s \"$XADOPTER/coordinator.pre\" \"$XADOPTER/.opencode/agent/coordinator.md\""
chk "5b boxe: THEIR opencode.json (with its model pin) is byte-identical"              "cmp -s \"$XADOPTER/opencodejson.pre\" \"$XADOPTER/opencode.json\""
chk "5b boxe: their files are NOT recorded (eject can never delete them)" \
  "python3 -c \"
import json
m = json.load(open('$XADOPTER/.kickoff/adopt-manifest.json'))
paths = [e['path'] for e in m['entries']]
assert 'opencode.json' not in paths and '.opencode/agent/coordinator.md' not in paths\""
chk "5b boxe: the pull DISCLOSED what it kept (kept/left-as-is lines)"                 "printf '%s' \"\$XPOUT\" | grep -qi 'kept\|left as-is\|not ours'"
chk "5b boxe: the REST of the set still delivered around theirs"                       "[ -s \"$XADOPTER/.opencode/agent/builder.md\" ] && [ -s \"$XADOPTER/.opencode/plugins/memory-search.js\" ]"
chk "5b boxe: their planted pin never leaks into the pull output (credential-safe posture)" \
  "! printf '%s' \"\$XPOUT\" | grep -q 'x-preview-f-free'"
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
  # The output-style seam template — a CORE-ROOT file (adopt-manifest.py's _OUTPUT_STYLE_SRC), not a
  # scripts/templates/ one. The fixture core MUST carry it: the copied adopt-manifest.py's
  # seam_template_for resolves the adopter's recorded .claude/output-styles/plain-report.md seam from
  # THIS core's root, and dies FATAL (correctly — broken-core backstop) if the file is absent. A core
  # embedding this adopt-manifest.py but lacking the file models no real tag: the real
  # scripts/core-manifest.txt lists the file as an existence contract, checked by pull step 4a.
  mkdir -p "$core/.claude/output-styles"
  cp "$REPO/.claude/output-styles/plain-report.md" "$core/.claude/output-styles/plain-report.md"
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
.claude/output-styles/plain-report.md
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
  # vB CHANGES the style template: an adopter pulling core-vB must REGENERATE the style seam
  # (cur==recorded → template-changed rewrite), not merely resolve it — so the cross-tag lanes
  # exercise the seam's write path, and eject's byte-clean round-trip covers the rewritten file.
  printf '\n<!-- fixture style delta — VB -->\n' >> "$core/.claude/output-styles/plain-report.md"
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
    bash "$KICKOFF" adopt --dir "$adopter" --accept </dev/null >/dev/null 2>&1 || true
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
# THE INCIDENT (2026-07-10 — broke a legacy adopter's v0.4.1 upgrade real-run): cmd_pull step 4f runs
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

# ══════════════════════════════════════════════════════════════════════════════════════
echo "8. v0.7 G1 slice 5 — PULL OK cycles the worker: refresh flag touched + the HONEST bottom line"
# ══════════════════════════════════════════════════════════════════════════════════════
# The old tail printed 'restart the worker' HOMEWORK; the new tail (a) touches
# $REPO_DIR/.kickoff/refresh-requested so a RUNNING worker's supervisor hops within
# ~POLL_SECONDS (the accelerator — the supervisor's engine-hop watch is the belt; see
# scripts/hop-selftest.sh for the hop itself), and (b) prints the honest run-state:
# a LIVE supervisor.lock pid → 'worker is hopping to <tag> now'; absent/stale →
# 'no worker running — start when ready' (fork 2: a pull PRESERVES run-state — it
# never starts a stopped worker, and never signals a running one).

# variant A — LIVE worker: a sleep THIS suite owns stands in for the supervisor pid
# (killed by exact pid right after the run; the pull must not signal it either way).
read -r _H1CLONE H1AD _H1SNAP <<< "$(build_pull_case "$CORE")"
sleep 300 & H1PID=$!; rec_pid "$H1PID"
printf '%s\n' "$H1PID" > "$H1AD/.kickoff/supervisor.lock"
H1RC=0
H1OUT="$(KICKOFF_ADOPTERS_REGISTRY="$(mk)/r.json" REPO_DIR="$H1AD" bash "$KICKOFF" pull core-vB 2>&1)" || H1RC=$?
H1LOCK_AFTER="$(cat "$H1AD/.kickoff/supervisor.lock" 2>/dev/null)"
H1STILL_ALIVE=0; kill -0 "$H1PID" 2>/dev/null && H1STILL_ALIVE=1
kill "$H1PID" 2>/dev/null || true
chk "live worker: PULL OK (rc=0)"                                          "[ $H1RC -eq 0 ]"
chk "live worker: refresh-requested TOUCHED (the hop accelerator)"         "[ -f \"$H1AD/.kickoff/refresh-requested\" ]"
chk "live worker: honest bottom line — 'worker is hopping to core-vB now'" \
  "printf '%s' \"\$H1OUT\" | grep -q 'worker is hopping to core-vB now'"
chk "live worker: the 'restart the worker' homework line is GONE"          \
  "! printf '%s' \"\$H1OUT\" | grep -q 'restart the worker'"
chk "live worker: pull neither signalled nor replaced the supervisor (pid alive, lock unchanged)" \
  "[ $H1STILL_ALIVE -eq 1 ] && [ \"$H1LOCK_AFTER\" = \"$H1PID\" ]"

# variant B — NO worker (no lock): run-state PRESERVED — pull starts NOTHING.
read -r _H2CLONE H2AD _H2SNAP <<< "$(build_pull_case "$CORE")"
H2RC=0
H2OUT="$(KICKOFF_ADOPTERS_REGISTRY="$(mk)/r.json" REPO_DIR="$H2AD" bash "$KICKOFF" pull core-vB 2>&1)" || H2RC=$?
chk "no worker: PULL OK (rc=0)"                                            "[ $H2RC -eq 0 ]"
chk "no worker: refresh-requested touched (consumed harmlessly at the next start)" \
  "[ -f \"$H2AD/.kickoff/refresh-requested\" ]"
chk "no worker: honest bottom line — 'no worker running — start when ready:  kickoff up --auto --detach'" \
  "printf '%s' \"\$H2OUT\" | grep -q 'no worker running — start when ready:  kickoff up --auto --detach'"
chk "no worker: pull STARTED NOTHING (no supervisor.lock, no session pidfile)" \
  "[ ! -f \"$H2AD/.kickoff/supervisor.lock\" ] && [ ! -f \"$H2AD/.kickoff/supervisor.session.pid\" ]"

# variant C — STOPPED worker (a STALE lock naming a dead pid): still the honest
# 'no worker running' line, still nothing started, the stale lock left for `kickoff up`.
read -r _H3CLONE H3AD _H3SNAP <<< "$(build_pull_case "$CORE")"
( true ) & H3PID=$!; wait "$H3PID" 2>/dev/null || true          # a genuinely DEAD pid we owned
printf '%s\n' "$H3PID" > "$H3AD/.kickoff/supervisor.lock"
H3RC=0
H3OUT="$(KICKOFF_ADOPTERS_REGISTRY="$(mk)/r.json" REPO_DIR="$H3AD" bash "$KICKOFF" pull core-vB 2>&1)" || H3RC=$?
H3LOCK_AFTER="$(cat "$H3AD/.kickoff/supervisor.lock" 2>/dev/null)"
chk "stopped worker (stale lock): PULL OK (rc=0)"                          "[ $H3RC -eq 0 ]"
chk "stopped worker: honest bottom line is the START command, not a false 'hopping'" \
  "printf '%s' \"\$H3OUT\" | grep -q 'no worker running — start when ready' && ! printf '%s' \"\$H3OUT\" | grep -q 'worker is hopping'"
chk "stopped worker: pull started NOTHING (no session pidfile; stale lock untouched)" \
  "[ ! -f \"$H3AD/.kickoff/supervisor.session.pid\" ] && [ \"$H3LOCK_AFTER\" = \"$H3PID\" ]"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "9. v0.7 G1 slice 6 — CROSS-VERSION: the pinned v0.6 cmd_pull drives the v0.7 working-tree tools"
# ══════════════════════════════════════════════════════════════════════════════════════
# The byte-stability hinge (design §3 — an adopter's pull runs their OLD pinned front door against
# the NEW tools mid-run, so those tools' interfaces are a cross-version contract, not an internal one):
# a v0.6 adopter's `kickoff pull core-v0.7` runs the OLD v0.6 cmd_pull (their pinned front door)
# calling the NEW v0.7 tools MID-RUN — the freshly-checked-out work_dir's `preflight.sh --pin`
# (v0.6 also GREPS that source for the literal `scope=pin` token — kickoff:1034@core-v0.6 — to
# label its verdict honestly) and the work_dir's adopt-manifest.py (sync-seams). Since G1 changes
# preflight.sh's BYTES, the hinge is INTERFACE stability; this lane proves it instead of arguing
# it: the REAL v0.6 engine (extracted READ-ONLY via `git archive core-v0.6 scripts` — never a
# checkout) pulls a fixture tag whose tools are the v0.7 WORKING TREE's, and must land end-to-end
# green. Frozen contracts asserted explicitly at the end (--pin + scope=pin + adopt-manifest.py's
# PULL-RELEVANT SURFACE — dispatch + args + implementation — NOT a whole-file blob-SHA; see the
# block above the surface check for why the old whole-file freeze was wrong by design). The
# counter-proof that the scope=pin detection MEANS
# something (a preflight predating pin scope → the honest PREDATES caveat) already lives in §2b.
if ! git -C "$REPO" rev-parse -q --verify "core-v0.6^{commit}" >/dev/null 2>&1; then
  bad "cross-version: tag core-v0.6 not present in $REPO — cannot run the lane"
else
  XVENG="$(mk)"
  git -C "$REPO" archive core-v0.6 scripts | tar -x -C "$XVENG"
  chk "the extracted v0.6 front door carries the frozen-contract grep (the scope=pin detector, kickoff:1034)" \
    "grep -q \"grep -q 'scope=pin'\" \"$XVENG/scripts/kickoff\""
  read -r XVCLONE XVAD XVSNAP <<< "$(build_pull_case "$CORE")"
  XVRC=0
  XVOUT="$(KICKOFF_ADOPTERS_REGISTRY="$(mk)/r.json" REPO_DIR="$XVAD" timeout 120 bash "$XVENG/scripts/kickoff" pull core-vB 2>&1)" || XVRC=$?
  XVCOMMIT_B="$(git -C "$CORE" rev-parse 'core-vB^{commit}')"
  chk "v0.6 cmd_pull → v0.7 tools: the pull exits 0" "[ $XVRC -eq 0 ]"
  chk "… with the anchored 'PULL OK' verdict line" \
    "printf '%s' \"\$XVOUT\" | grep -Eq '^\[kickoff [^]]*\] PULL OK'"
  chk "… and zero '[kickoff] ERROR:' lines" \
    "! printf '%s' \"\$XVOUT\" | grep -q '^\[kickoff\] ERROR:'"
  chk "… lock ADVANCED to the fixture target (format 2 · tag core-vB · the tag's commit)" \
    "grep -q '^format 2' \"$XVAD/.kickoff/core.lock\" && grep -q '^tag core-vB$' \"$XVAD/.kickoff/core.lock\" && grep -q \"^commit $XVCOMMIT_B$\" \"$XVAD/.kickoff/core.lock\""
  chk "… pin scope DETECTED as supported — 'PIN verified', never the 'PREDATES pin scope' mislabel" \
    "printf '%s' \"\$XVOUT\" | grep -q 'PIN verified' && ! printf '%s' \"\$XVOUT\" | grep -q 'PREDATES pin scope'"
  chk "… seam-sync clean: KICKOFF.md regenerated to vB by the NEW (work_dir) adopt-manifest.py" \
    "grep -q 'CHARTER_MARKER_VB' \"$XVAD/.kickoff/KICKOFF.md\""
  chk "… KICKOFF.local.md (the adopter's own half) byte-identical across the cross-version pull" \
    "cmp -s \"$XVAD/.kickoff/KICKOFF.local.md\" \"$XVSNAP/KICKOFF.local.md\""
  chk "… the adopter-owned layer byte-identical (CLAUDE.md + source + settings.local.json)" \
    "cmp -s \"$XVAD/CLAUDE.md\" \"$XVSNAP/CLAUDE.md\" && cmp -s \"$XVAD/src/app.txt\" \"$XVSNAP/app.txt\" && cmp -s \"$XVAD/.claude/settings.local.json\" \"$XVSNAP/settings.local.json\""
  # ── the frozen contracts, asserted directly (so a future G-slice that breaks one fails HERE) ──
  chk "FROZEN CONTRACT: the v0.7 working-tree preflight.sh still carries the literal scope=pin token" \
    "grep -q 'scope=pin' \"$REPO/scripts/preflight.sh\""
  XVPFRC=0
  XVPFOUT="$(REPO_DIR="$XVAD" KICKOFF_CORE_DIR="$XVCLONE" timeout 60 bash "$XVCLONE/scripts/preflight.sh" --pin 2>&1)" || XVPFRC=$?
  chk "FROZEN CONTRACT: v0.7 preflight.sh still ACCEPTS --pin (rc=0, the pin-scope banner printed)" \
    "[ $XVPFRC -eq 0 ] && printf '%s' \"\$XVPFOUT\" | grep -q 'scope=pin'"
  # ── the adopt-manifest.py frozen contract: the PULL-RELEVANT SURFACE, not the whole file ──────
  # (v0.9 G1 slice 5.) This assertion used to be a WHOLE-FILE blob-SHA freeze ("adopt-manifest.py is
  # byte-identical to core-v0.6's copy"). That premise — the tool never changes across versions — is
  # wrong BY DESIGN: v0.9 slice 2 ADDED `gen-upgrade-turnkey` (a new handler + its subparser; no
  # existing verb touched), which is SAFE for a cross-version pull yet tripped the whole-file freeze.
  # The invariant the check was really protecting is narrower: a v0.6 adopter's `kickoff pull <newer>`
  # runs their OLD cmd_pull against the NEW tag's adopt-manifest.py, so THE SURFACE THAT OLD cmd_pull
  # INVOKES must not move under it. The rest of the file is free to grow.
  #
  # The pull-relevant verbs, read straight out of core-v0.6's kickoff (the ones called on the
  # work_dir/pinned-tag tool — i.e. the NEW code) — SIX, exhaustively:
  #     sync-seams               kickoff@core-v0.6:821,827   ($work_dir/scripts/adopt-manifest.py)
  #     plugin-list              kickoff@core-v0.6:869,872   (same work_dir tool → $plugin_tool)
  #     rehash-path              kickoff@core-v0.6:941       (same $plugin_tool, on the NORMAL
  #                                                           "settings.json was CLEAN" branch)
  #     plugin-record            kickoff@core-v0.6:449       ┐ via _resync_plugin_cache,
  #     plugin-cache-verify      kickoff@core-v0.6:464,520   ├ tool="$core_wd/scripts/adopt-manifest.py"
  #     plugin-consumers-others  kickoff@core-v0.6:499       ┘ (core_wd = the pinned work dir)
  # (`adopters-siblings` / `adopters-register` are invoked through $HERE — the adopter's OWN pinned
  # engine, i.e. the OLD copy — so they are NOT part of the new-tool surface and are not frozen here.)
  # rehash-path is NOT optional decoration: if it breaks under the pinned cmd_pull, kickoff:941 only
  # WARNS (the pull still says OK) while sha256_at_write is never re-recorded — so a later `eject`
  # reads kickoff's OWN write as operator-edited, SKIPS the byte-restore, and strands the plugin keys
  # in the adopter's repo permanently. Silent, deferred, unrecoverable: it must fail HERE.
  #
  # Three layers, all must hold — and all must be able to go RED:
  #   (a) INTERFACE — each pull-relevant verb's argparse surface (`<verb> --help`) byte-identical to
  #       v0.6's, so a dropped/renamed flag the old cmd_pull passes fails HERE, not in a live pull.
  #   (b) DISPATCH — the verb→handler mapping (`sub.add_parser("verb")` … `.set_defaults(func=H)`),
  #       read statically out of the parser. Without this, repointing a verb at a gutted no-op twin
  #       while leaving the old handler byte-identical sails through (a) and (c) untouched.
  #   (c) BEHAVIOUR — the IMPLEMENTATION reachable from the handlers layer (b) RESOLVES (transitive
  #       closure over module-level defs + constants, via AST) byte-identical to v0.6's. A NEW verb
  #       doesn't touch it; editing sync-seams — or any helper/template-constant it reaches — trips it.
  # (b)+(c) share one digest — the mapping is hashed alongside the closure, and the closure is rooted
  # in the RESOLVED handlers, not in hardcoded cmd_* names. Deliberately NOT "bump the baseline to the
  # current tag": that re-breaks on the next additive change and teaches the next session to
  # rubber-stamp the freeze away.
  # Known, accepted limits (backstopped elsewhere in this suite, and cheaper than the alternatives):
  #   · (a) freezes help TEXT, not arg SEMANTICS — flipping store_true→store_false on a flag v0.6
  #     passes renders identical help. §3 (which invokes --force-regenerate for real) catches it.
  #   · (c) hashes raw source spans, so a comment/whitespace edit inside a closure member reds. That
  #     strictness is deliberate: the invoked surface should require a re-bless.
  #   · The closure follows ast.Name references; a helper reached ONLY via getattr indirection would
  #     be missed (adopt-manifest.py has none today).
  XVAM="$(mk)"
  git -C "$REPO" show core-v0.6:scripts/adopt-manifest.py > "$XVAM/adopt-manifest.py"
  cat > "$XVAM/pull-surface.py" <<'PULLSURFACE'
# Digest of adopt-manifest.py's PULL-RELEVANT surface: the SIX verbs a v0.6 cmd_pull invokes on the
# newly-pinned tag's tool, the DISPATCH that decides which function each verb actually runs, and every
# module-level def/constant transitively reachable from those handlers. Additive verbs (new handler +
# new subparser) do not move this digest; touching a pull-relevant verb's dispatch, implementation, or
# anything it reaches, does.
import ast, hashlib, sys
VERBS = ["sync-seams", "plugin-list", "plugin-record", "plugin-cache-verify",
         "plugin-consumers-others", "rehash-path"]
src = open(sys.argv[1], "rb").read().decode()
tree = ast.parse(src)
defs, consts = {}, {}
for n in tree.body:
    if isinstance(n, (ast.FunctionDef, ast.ClassDef)):
        defs[n.name] = n
    elif isinstance(n, (ast.Assign, ast.AnnAssign, ast.AugAssign)):
        tgts = n.targets if isinstance(n, ast.Assign) else [n.target]
        for t in tgts:
            if isinstance(t, ast.Name):
                consts[t.id] = n
# ── layer (b): the DISPATCH map, read out of the parser —
#      `v = sub.add_parser("verb", …)`  …  `v.set_defaults(func=HANDLER)`
# Rooting the closure in the RESOLVED handler (not a hardcoded cmd_* name) is what makes a repointed
# set_defaults — the verb gutted to a no-op twin, the old handler left byte-identical — fail red.
var_verb, dispatch = {}, {}
for node in ast.walk(tree):
    if isinstance(node, ast.Assign) and isinstance(node.value, ast.Call) \
       and isinstance(node.value.func, ast.Attribute) and node.value.func.attr == "add_parser" \
       and node.value.args and isinstance(node.value.args[0], ast.Constant) \
       and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
        var_verb[node.targets[0].id] = node.value.args[0].value
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) \
       and node.func.attr == "set_defaults" and isinstance(node.func.value, ast.Name):
        verb = var_verb.get(node.func.value.id)
        for kw in node.keywords:
            if kw.arg == "func" and isinstance(kw.value, ast.Name) and verb:
                dispatch[verb] = kw.value.id
unmapped = [v for v in VERBS if v not in dispatch]        # verb DELETED / dispatch unreadable
missing = [dispatch[v] for v in VERBS if v in dispatch and dispatch[v] not in defs]
if unmapped or missing:                                   # → hard red, never a vacuous green
    sys.stderr.write("UNRESOLVABLE pull-relevant verb(s): %s  |  MISSING handler(s): %s\n"
                     % (",".join(unmapped) or "-", ",".join(missing) or "-"))
    sys.exit(3)
ENTRY = sorted({dispatch[v] for v in VERBS})
seen, stack = set(), list(ENTRY)
while stack:
    name = stack.pop()
    if name in seen:
        continue
    seen.add(name)
    node = defs.get(name) or consts.get(name)
    if node is None:
        continue
    for sub in ast.walk(node):
        if isinstance(sub, ast.Name) and (sub.id in defs or sub.id in consts) and sub.id not in seen:
            stack.append(sub.id)
h = hashlib.sha256()
for v in VERBS:                                           # layer (b): the dispatch itself is frozen
    h.update(("dispatch:%s=%s" % (v, dispatch[v])).encode()); h.update(b"\0")
for name in sorted(seen):                                 # layer (c): the implementation closure
    node = defs.get(name) or consts.get(name)
    if node is None:
        continue
    h.update(name.encode()); h.update(b"\0")
    h.update(ast.get_source_segment(src, node).encode()); h.update(b"\0")
if len(sys.argv) > 2 and sys.argv[2] == "--list":
    for v in VERBS:
        print("dispatch %-24s -> %s" % (v, dispatch[v]))
    for name in sorted(seen):
        print("closure  %s" % name)
else:
    print(h.hexdigest())
PULLSURFACE
  XVSURF_OLD="$(python3 "$XVAM/pull-surface.py" "$XVAM/adopt-manifest.py" 2>/dev/null || true)"
  XVSURF_NEW="$(python3 "$XVAM/pull-surface.py" "$REPO/scripts/adopt-manifest.py" 2>/dev/null || true)"
  # ── RE-BLESS LEDGER — accepted, reviewed deltas to the v0.6 pull surface ──────────────────────
  # The surface stays byte-identical to core-v0.6 EXCEPT the explicitly-listed, justified deltas
  # below. This is an allow-list-with-reasons (the .scanignore discipline), NOT "bump the baseline to
  # the current tag": a digest that is NEITHER v0.6's NOR a blessed value still REDs, so the guard
  # keeps catching unintended drift. A NEW blessed entry is only ever added after a real cross-version
  # safety review (why is regenerating an OLD adopter's seams with this change safe?).
  #   c7cd1eda…  core-v0.19 · commit 7a48862 (shim env-seal, scout #2): SHIM_TEMPLATES now `unset`s the
  #     ambient MC_/MEMORY_/GIT_ data-path vars before sourcing instance.env. SAFE to pull forward —
  #     the regenerated shim resolves via the adopter's own instance.env (which sets MC_STATE_FILE to a
  #     repo-relative path); for a config that LACKS that line the behaviour is unchanged (the var was
  #     already unresolved, only ever "saved" by the ambient bleed this fix closes), so it never breaks
  #     a working adopter. Only SHIM_TEMPLATES' body moved — no member added/removed, arg-surface green.
  #   9fbe910d…  core-v0.24 (workspace gate arming): the two SCAN shims no longer `cd "$REPO_DIR"`
  #     unconditionally. When — and ONLY when — the adopted root is NOT itself a git repo (a workspace
  #     of sibling checkouts) and the caller stands in a work tree strictly inside it, they cd to the
  #     CALLER's repo instead. Needed because a workspace member's git hook calls the ROOT's shim, and
  #     cd-ing to the root fans the scan across every sibling and scores that member's commit on its
  #     neighbours' staged files.
  #     SAFE to pull forward: for a single-repo adopter — i.e. EVERY adopter that exists before this
  #     tag — `git -C "$REPO_DIR" rev-parse --show-toplevel` equals REPO_DIR, so the whole new block is
  #     skipped and the `cd` is the original one, byte-for-byte, on every path (hook, manual run, run
  #     from a subdir, run from a nested checkout). The branch is likewise unreachable with no `git` on
  #     PATH (`|| true` → empty → the guard's inequality holds but the caller-top probe is empty too →
  #     fallback cd) and for a caller in an unrelated repo (no prefix match). It therefore cannot turn
  #     a blocking gate into a passing one for any existing adopter. Only SHIM_TEMPLATES' body moved —
  #     the extractor reports ZERO surface-member drift, arg-surface green.
  #   3b29ca9e…  core-v0.25 (a workspace root may BE a git repo): the same two SCAN shims gain a
  #     SECOND spelling of "this is a workspace root" — `|| [ -f "$_root_p/.kickoff/workspace" ]` —
  #     because workspace-ness is no longer inferred from "the root is not a git repo". Needed
  #     because with a MARKED git root the old inference is FALSE, so the member-scoping branch went
  #     dead and a member's pre-commit cd'd to the ROOT and scored its commit on the ROOT's index:
  #     a silent false green on every member commit (reproduced RED in workspace-adopt-selftest §10,
  #     "member scoping under a GIT root").
  #     SAFE to pull forward, and the v0.24 argument holds unchanged plus one clause: an EXISTING
  #     adopter has no `.kickoff/workspace` file — nothing before this tag ever wrote one — so the
  #     added disjunct is FALSE, the guard's value is exactly what it was, and the `cd` is
  #     byte-for-byte the old one on every path (hook, manual run, from a subdir, from a nested
  #     checkout, with no `git` on PATH). It can only ever NARROW a scan from the whole workspace to
  #     the caller's own repo, and only in a topology that must be opted into by writing the marker,
  #     so it cannot turn a blocking gate into a passing one for any repo that exists today. Only
  #     SHIM_TEMPLATES' bodies moved — the extractor reports ZERO surface-member drift, arg-surface
  #     green. (The superseded v0.24 digest 9fbe910d… stays documented above: this delta is layered
  #     on top of it, not a replacement of its reasoning.)
  #   0b0261d9…  core-v0.30 (the CLI's bookkeeping is not adopter drift): `_fileset_manifest` gains
  #     an `ignore_top` parameter — DEFAULTING TO AN EMPTY frozenset, so every existing caller is
  #     byte-equivalent — a top-level-only skip inside its walk, one new module constant
  #     `_CACHE_VENDOR_BOOKKEEPING = frozenset({".orphaned_at"})`, and ONE call site passing it: the
  #     CACHE side of plugin-cache-verify. The CORE side passes nothing and is still hashed with no
  #     exclusions at all. The extractor reports ONE added closure member (the constant) and ZERO
  #     removed; no verb, no dispatch and no arg-surface changed.
  #     WHY: the vendor CLI stamps `.orphaned_at` (a millisecond epoch) into a cached plugin version
  #     dir once no USER-scope marketplace references it, and kickoff registers its marketplace
  #     PER-ADOPTER at project scope — so on such a box that stamp is routine housekeeping. #8 read
  #     it as DRIFT, and #8 is fail-closed on supervisor start AND on every engine hop. Measured
  #     2026-08-12: SIX of the seven orgs on this machine in a hard preflight failure at once, each
  #     one restart from not booting a session, and a v0.30 rotation would have fail-closed on all
  #     six. (The seventh — kickoff-itself, no interactive plugin entry — SKIPS #8 and looked fine.)
  #     THIS IS THE FIRST BLESSED DELTA WHOSE EFFECT IS TO TURN A RED GREEN, so it is stated rather
  #     than buried: yes, a gate that was refusing now passes. It is correct because the red was
  #     FALSE, and the exemption is bounded on three axes, each with its own lane in
  #     plugin-selftest §9: a real extra file in the cache still FAILS; the same filename on the
  #     CORE side still FAILS; the same filename ONE DIRECTORY DOWN still FAILS. Nothing else about
  #     the check moved — the version dir is still located by the PINNED version, and every other
  #     file is still byte-compared — so it cannot mask a stale or substituted cache. For an adopter
  #     with no `.orphaned_at` (i.e. any box whose CLI has not orphaned that version) the compared
  #     set is unchanged and the verdict is identical to before.
  #   05085ef8…  core-v0.33 candidate · commits 141dca7 (output-style seam) + the sync-seams
  #     atomicity fix blessed together, reviewed as one delta over the blessed 0b0261d9 state.
  #     WHAT MOVED (extractor-verified vs the v0.32/0b0261d9 surface): THREE added closure members
  #     (_OUTPUT_STYLE_PATH, _OUTPUT_STYLE_SRC, _read_core_root_file) + _CORE_ROOT newly REACHABLE
  #     (pre-existing constant, body unchanged — it entered the closure via _OUTPUT_STYLE_SRC);
  #     THREE bodies changed: seam_template_for (one added branch — `norm == _OUTPUT_STYLE_PATH` →
  #     read the style template from the CORE ROOT, the _AGENT_CHARTER_TEMPLATE idiom),
  #     cmd_sync_seams (templates now ALL resolved BEFORE any seam is written), and
  #     cmd_rehash_path (DOCSTRING + die-message TEXT only — zero logic, the allowlist and
  #     arg-surface are byte-identical). ZERO members removed, ZERO dispatch changes.
  #     WHY REGENERATING AN OLD ADOPTER'S SEAMS WITH THIS IS SAFE:
  #     · An adopter WITHOUT a recorded .claude/output-styles/plain-report.md entry — i.e. EVERY
  #       adopter that exists before this tag — walks byte-identically: sync-seams only visits
  #       manifest-listed paths, none equals _OUTPUT_STYLE_PATH, so the new branch never fires.
  #     · An adopter WITH the entry pulling an OLDER tag runs that tag's OWN adopt-manifest.py
  #       (kickoff step 4b uses $work_dir's tool), whose seam_template_for returns None for the
  #       path → "[ skip ]", file untouched. No FATAL in either direction.
  #     · The new FATAL (_read_core_root_file on a missing style file) is reachable ONLY from an
  #       INCOMPLETE checkout of a tag ≥ this one: every real tag ships the file
  #       (scripts/core-manifest.txt lists it — the existence contract pull step 4a checks BEFORE
  #       sync-seams ever runs). It is the same broken-core backstop _read_file_seam_template has
  #       always had, not a new refusal on any coherent core.
  #     · The cmd_sync_seams hoist can only NARROW the blast radius of that FATAL: pre-hoist a
  #       mid-walk template failure left earlier seams regenerated with save_manifest unreached
  #       (adopter stranded at file != recorded hash — preflight #8 red, eject mis-reads kickoff's
  #       own write as a hand-edit); post-hoist the same failure aborts with ZERO seams written and
  #       the manifest intact. Proved RED on the pre-fix tool / GREEN on this one with the same
  #       broken-core fixture. On a complete core the resolved set and every write are identical.
  #   00e15b9d…  core-v0.42 candidate · commits 82b830f→61f7034 (the opencode engine-parity set:
  #     gen-opencode + its wiring), reviewed as one delta over the blessed 05085ef8 state —
  #     co-reviewed twice (coordinator inline + lane F independently, identical verdict/digest).
  #     WHAT MOVED (extractor-verified vs core-v0.33/05085ef8 — membership AND bodies, both
  #     trees diffed): SEVEN added closure members, all inert data or pure defs — _MODEL_PIN_LINE_RE
  #     (compiled regex), _OPENCODE_AGENTS/_OPENCODE_PLUGINS (tuples), _OPENCODE_AGENT_DIR/
  #     _OPENCODE_PLUGIN_DIR (os.path joins off the already-blessed _CORE_ROOT), _strip_model_pin
  #     (regex sub), _opencode_agent_template (core-root read + pin strip, die()s only on an
  #     unknown name) + TWO pure INSERTIONS in existing members — FILE_SEAM_TEMPLATES gains the
  #     opencode entries; seam_template_for gains the .opencode/agent|plugins resolution branches
  #     (its second `"/" not in name` pair is UNREACHABLE belt-and-braces — fully shadowed by the
  #     first pair; dead code cannot change behaviour, noted rather than hidden). ZERO members
  #     removed/altered, ZERO dispatch changes, arg-surface byte-identical (this suite's own
  #     check). gen-opencode itself is an ADDITIVE verb (free by the freeze's design).
  #     WHY REGENERATING AN OLD ADOPTER'S SEAMS WITH THIS IS SAFE:
  #     · Every pull-relevant walk is MANIFEST-driven: sync-seams resolves templates only for
  #       paths listed in the adopter's own manifest, and a pre-v0.42 manifest cannot contain
  #       .opencode/** rows or an opencode.json row (gen-opencode did not exist before this
  #       tag) — the new branches and entries are UNREACHABLE for every adopter that exists
  #       today; the fall-through for all old paths is byte-identical (pure insertions).
  #     · FILE_SEAM_TEMPLATES is consumed by KEYED lookups only inside the pull closure; the
  #       one iterating consumer (`known = … + sorted(FILE_SEAM_TEMPLATES)`) sits in
  #       cmd_reconcile — NOT one of the 6 pull verbs.
  #     · An adopter WITH recorded opencode seams (possible only after a core ≥ this tag
  #       delivered them — adopt's gate is pin-rooted, lane D) pulling THIS tag resolves
  #       templates from the PINNED checkout's core-root — the _read_core_root_file idiom
  #       blessed at 05085ef8; its FATAL is reachable only from an INCOMPLETE checkout, and
  #       every template read is listed in scripts/core-manifest.txt — the existence contract
  #       pull step 4a checks BEFORE sync-seams ever runs (the same broken-core backstop the
  #       style file has).
  #     · _strip_model_pin is a pure text transform on DELIVERED charter bytes (drops YAML
  #       `model:` lines — a pin silently wedges sessions on boxes without that provider);
  #       no v0.6-era seam path is a charter, so no pre-existing template byte changes.
  XV_BLESSED="00e15b9d511444b106dddbf0b4f4128f0845b2f1255a70e5b77334e48c570049"
  chk "FROZEN CONTRACT: adopt-manifest.py's PULL-RELEVANT dispatch+implementation surface (the 6 verbs a v0.6 cmd_pull invokes, the handler each one DISPATCHES to, + everything they reach) is byte-identical to core-v0.6's OR a blessed reviewed delta — additive verbs are FREE" \
    "[ -n \"$XVSURF_OLD\" ] && [ -n \"$XVSURF_NEW\" ] && { [ \"$XVSURF_OLD\" = \"$XVSURF_NEW\" ] || [ \"$XVSURF_NEW\" = \"$XV_BLESSED\" ]; }"
  if [ "$XVSURF_OLD" != "$XVSURF_NEW" ]; then
    printf '  ── pull-surface digest drift: core-v0.6=%s  working-tree=%s\n' \
      "${XVSURF_OLD:-<extractor-failed>}" "${XVSURF_NEW:-<extractor-failed>}"
    # the members that moved, named — both trees are still on disk HERE (the EXIT trap reaps $XVAM
    # only at the end of the run), so print the real diff instead of an un-runnable hint
    python3 "$XVAM/pull-surface.py" "$XVAM/adopt-manifest.py" --list > "$XVAM/old.list" 2>/dev/null || true
    python3 "$XVAM/pull-surface.py" "$REPO/scripts/adopt-manifest.py" --list > "$XVAM/new.list" 2>/dev/null || true
    diff "$XVAM/old.list" "$XVAM/new.list" | sed 's/^/  ── surface-member drift: /' || true
  fi
  XVIF_DRIFT=""
  for _xvv in sync-seams plugin-list plugin-record plugin-cache-verify plugin-consumers-others rehash-path; do
    _xva="$(COLUMNS=100 python3 "$XVAM/adopt-manifest.py" "$_xvv" --help 2>&1 || true)"
    _xvb="$(COLUMNS=100 python3 "$REPO/scripts/adopt-manifest.py" "$_xvv" --help 2>&1 || true)"
    [ "$_xva" = "$_xvb" ] && [ -n "$_xva" ] || XVIF_DRIFT="$XVIF_DRIFT $_xvv"
  done
  chk "FROZEN CONTRACT: the ARG-SURFACE of each pull-relevant verb (\`<verb> --help\`) is byte-identical to core-v0.6's — a dropped/renamed flag the pinned cmd_pull passes fails HERE" \
    "[ -z \"$XVIF_DRIFT\" ]"
  [ -n "$XVIF_DRIFT" ] && printf '  ── verbs whose arg-surface drifted from core-v0.6:%s\n' "$XVIF_DRIFT"
  true
fi
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "9b. Fix C for PULL — a pull run from INSIDE another worker's session stamps the ADOPTER's channel, never the CALLER's"
# ══════════════════════════════════════════════════════════════════════════════════════
# THE INCIDENT (live, 2026-08-07: one fleet sweep poisoned three orgs' rows). cmd_pull's step-4d
# adopters-register used to pass the AMBIENT `${TELEGRAM_STATE_DIR:-}` as --channel, on the premise
# that the ambient value is "whitelist-loaded from THIS adopter's instance.env". It is NOT — not
# whenever the CALLER already has one set: load_instance_env deliberately SKIPS every pre-set name
# (`# pre-set / argv wins`, kickoff:272), so a `kickoff pull` for repo B run from INSIDE repo A's
# worker session (the fleet-upgrade sweep) keeps A's channel and stamps it onto B's row.
# The damage runs BOTH ways, and both land on a CONSUMER — this is not cosmetic bookkeeping:
# preflight #2 (adopters-channel-clash) then reports a PHANTOM clash against A, blocking A's own
# engine hop; and a row naming the wrong channel can no longer detect the REAL double-poller that
# check exists for.
# The fix is the isolation cmd_adopt has had since core-v0.3.1 ("Fix C", kickoff:2831, proved by
# adopt-selftest §12) and pull never got: read the channel from THIS repo's instance.env in a
# subshell with TELEGRAM_STATE_DIR + REPO_DIR unset. Every lane below drives the REAL `kickoff pull`
# (never a re-implementation of the idiom) and asserts the ROW the system consumes — plus the
# consumer verb itself.
ch_row() {   # $1=registry $2=adopter repo $3=field → that field of THIS repo's row ('' when no row)
  python3 -c '
import json, os, sys
try:
    rows = json.load(open(sys.argv[1]))["adopters"]
except Exception:
    sys.exit(0)
for a in rows:
    p = a.get("repo") or ""                       # blank/missing repo ⇒ never realpath("") (→ CWD)
    if p and os.path.realpath(p) == os.path.realpath(sys.argv[2]):
        print(a.get(sys.argv[3], "") or ""); break' "$1" "$2" "$3"
}
ch_canon() { python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$1"; }

# ── CASE A [RED pre-fix — THE INCIDENT] ── the adopter's instance.env names its OWN channel; the
# CALLER's session exports a DIFFERENT one. The registered row must carry the ADOPTER's. The caller
# (org A) is itself a registered adopter here, so the clash consumer has the live two-row topology.
read -r _CH1CLONE CH1AD _CH1SNAP <<< "$(build_pull_case "$CORE")"
CH1REG="$(mk)/adopters.json"; CH1CALLER="$(mk)"; CH1CALLER_CHAN="$(mk)/caller-chan"; mkdir -p "$CH1CALLER_CHAN"
CH1AD_CHAN="$(ch_canon "$CH1AD/.kickoff/chan")"     # what build_pull_case wrote into the adopter's instance.env
python3 "$AM" adopters-register --repo "$CH1CALLER" --tag core-vA --version-dir "$CH1CALLER" \
  --channel "$CH1CALLER_CHAN" --registry "$CH1REG" >/dev/null
CH1RC=0
CH1OUT="$(KICKOFF_VERSIONS_DIR="$(mk)/vers" KICKOFF_ADOPTERS_REGISTRY="$CH1REG" REPO_DIR="$CH1AD" TELEGRAM_STATE_DIR="$CH1CALLER_CHAN" \
  bash "$KICKOFF" pull core-vB 2>&1)" || CH1RC=$?
CH1ROW_CHAN="$(ch_row "$CH1REG" "$CH1AD" channel)"
CH1CLASH="$(python3 "$AM" adopters-channel-clash --repo "$CH1CALLER" --channel "$CH1CALLER_CHAN" --registry "$CH1REG" 2>/dev/null || true)"
chk "caller-session pull: PULL OK (rc=0) — the lane really ran a whole pull, so the row below is a real register" \
  "[ $CH1RC -eq 0 ] && printf '%s' \"\$CH1OUT\" | grep -q 'PULL OK'"
chk "caller-session pull [RED pre-fix]: the row carries the ADOPTER's OWN channel (its instance.env value)" \
  "[ \"$CH1ROW_CHAN\" = \"$CH1AD_CHAN\" ]"
chk "caller-session pull [RED pre-fix]: the CALLER's channel was NOT stamped onto the adopter's row" \
  "[ \"$CH1ROW_CHAN\" != \"\$(ch_canon \"$CH1CALLER_CHAN\")\" ]"
chk "caller-session pull [RED pre-fix]: the CONSUMER agrees — adopters-channel-clash (preflight #2) reports NO phantom clash for the caller" \
  "[ -z \"$CH1CLASH\" ]"
[ "$CH1ROW_CHAN" = "$CH1AD_CHAN" ] || printf '  ── row channel: %s\n  ── expected the ADOPTER'\''s: %s\n  ── the CALLER'\''s was:      %s\n' \
  "${CH1ROW_CHAN:-<no row/channel>}" "$CH1AD_CHAN" "$(ch_canon "$CH1CALLER_CHAN")"

# ── CASE B [RED pre-fix — the SHARPEST form] ── the adopter ships the SELF-DEFAULTING
# `export TELEGRAM_STATE_DIR="${TELEGRAM_STATE_DIR:-…}"` line real adopters carry (the shape
# instance.env.example seeds). That form keeps an ambient value even on a PLAIN `source`, so it is what makes the `unset
# TELEGRAM_STATE_DIR` INSIDE the fix's subshell load-bearing rather than decoration — a "fix" that
# only sub-shelled the source would still stamp the caller's channel here.
read -r _CH2CLONE CH2AD _CH2SNAP <<< "$(build_pull_case "$CORE")"
CH2REG="$(mk)/adopters.json"; CH2CALLER_CHAN="$(mk)/caller-chan"; mkdir -p "$CH2CALLER_CHAN"
CH2CHAN="$CH2AD/.kickoff/telegram-fixture"
sed -i "s|^export TELEGRAM_STATE_DIR=.*|export TELEGRAM_STATE_DIR=\"\${TELEGRAM_STATE_DIR:-$CH2CHAN}\"|" \
  "$CH2AD/.kickoff/instance.env"
chk "CASE B fixture: the adopter's instance.env really uses the self-defaulting \${TELEGRAM_STATE_DIR:-…} form" \
  "grep -q 'export TELEGRAM_STATE_DIR=\"\${TELEGRAM_STATE_DIR:-' \"$CH2AD/.kickoff/instance.env\""
# the fixture's SHARPNESS, asserted (a negative control): under the caller's ambient value a NAIVE
# source yields the CALLER's channel — the `:-` default never fires. Run in a command-substitution
# subshell so the export can never reach THIS suite's environment.
CH2NAIVE="$(export TELEGRAM_STATE_DIR="$CH2CALLER_CHAN"; set +u; . "$CH2AD/.kickoff/instance.env" >/dev/null 2>&1 || true; printf '%s' "${TELEGRAM_STATE_DIR:-}")"
chk "CASE B fixture is SHARP: a NAIVE source under the ambient value keeps the CALLER's channel (only an \`unset\` beats the :- default)" \
  "[ \"$CH2NAIVE\" = \"$CH2CALLER_CHAN\" ]"
CH2RC=0
CH2OUT="$(KICKOFF_VERSIONS_DIR="$(mk)/vers" KICKOFF_ADOPTERS_REGISTRY="$CH2REG" REPO_DIR="$CH2AD" TELEGRAM_STATE_DIR="$CH2CALLER_CHAN" \
  bash "$KICKOFF" pull core-vB 2>&1)" || CH2RC=$?
CH2ROW_CHAN="$(ch_row "$CH2REG" "$CH2AD" channel)"
chk "self-defaulting form: PULL OK (rc=0)" \
  "[ $CH2RC -eq 0 ] && printf '%s' \"\$CH2OUT\" | grep -q 'PULL OK'"
chk "self-defaulting form [RED pre-fix]: the row carries the adopter's OWN :- DEFAULT, not the caller's ambient value" \
  "[ \"$CH2ROW_CHAN\" = \"\$(ch_canon \"$CH2CHAN\")\" ]"
chk "self-defaulting form [RED pre-fix]: the caller's channel is ABSENT from the ENTIRE registry" \
  "! grep -qF \"\$(ch_canon \"$CH2CALLER_CHAN\")\" \"$CH2REG\""
[ "$CH2ROW_CHAN" = "$(ch_canon "$CH2CHAN")" ] || printf '  ── row channel: %s\n  ── expected the adopter'\''s :- default: %s\n  ── the CALLER'\''s was:                %s\n' \
  "${CH2ROW_CHAN:-<no row/channel>}" "$(ch_canon "$CH2CHAN")" "$(ch_canon "$CH2CALLER_CHAN")"

# ── CASE C — the MERGE semantic must NOT be weakened ── an adopter whose instance.env sets NO
# channel resolves to EMPTY, and adopters-register's `empty ⇒ MERGE` must PRESERVE whatever the row
# already holds (a channel the operator wired later, or an earlier register stored). Two regressions
# fail HERE: the ambient leak (pre-fix the caller's channel OVERWROTE the stored one) and an
# over-correction that always overwrites (an empty --channel would WIPE it). The tag assertion keeps
# the merge one honest — a pull that silently skipped registration would otherwise pass vacuously.
read -r _CH3CLONE CH3AD _CH3SNAP <<< "$(build_pull_case "$CORE")"
CH3REG="$(mk)/adopters.json"; CH3CALLER_CHAN="$(mk)/caller-chan"; CH3STORED="$(mk)/stored-chan"
mkdir -p "$CH3CALLER_CHAN" "$CH3STORED"
sed -i '/^export TELEGRAM_STATE_DIR=/d' "$CH3AD/.kickoff/instance.env"
chk "CASE C fixture: the adopter's instance.env sets NO channel at all" \
  "! grep -q 'TELEGRAM_STATE_DIR' \"$CH3AD/.kickoff/instance.env\""
python3 "$AM" adopters-register --repo "$CH3AD" --tag core-vA --version-dir "$CH3AD" \
  --channel "$CH3STORED" --registry "$CH3REG" >/dev/null
CH3RC=0
CH3OUT="$(KICKOFF_VERSIONS_DIR="$(mk)/vers" KICKOFF_ADOPTERS_REGISTRY="$CH3REG" REPO_DIR="$CH3AD" TELEGRAM_STATE_DIR="$CH3CALLER_CHAN" \
  bash "$KICKOFF" pull core-vB 2>&1)" || CH3RC=$?
CH3ROW_CHAN="$(ch_row "$CH3REG" "$CH3AD" channel)"
CH3ROW_TAG="$(ch_row "$CH3REG" "$CH3AD" tag)"
chk "no-channel adopter: PULL OK (rc=0)" \
  "[ $CH3RC -eq 0 ] && printf '%s' \"\$CH3OUT\" | grep -q 'PULL OK'"
chk "no-channel adopter: the register REALLY ran (the row's tag advanced to core-vB) — no vacuous merge pass" \
  "[ \"$CH3ROW_TAG\" = core-vB ]"
chk "no-channel adopter [RED pre-fix]: the PREVIOUSLY-STORED row channel SURVIVES the pull (empty ⇒ MERGE, never overwrite)" \
  "[ \"$CH3ROW_CHAN\" = \"\$(ch_canon \"$CH3STORED\")\" ]"
[ "$CH3ROW_CHAN" = "$(ch_canon "$CH3STORED")" ] || printf '  ── row channel: %s\n  ── expected the STORED one: %s\n  ── the CALLER'\''s was:      %s\n' \
  "${CH3ROW_CHAN:-<no row/channel>}" "$(ch_canon "$CH3STORED")" "$(ch_canon "$CH3CALLER_CHAN")"

# ── CASE D [RED under the OVER-CORRECTION] ── the adopter DERIVES its channel from its own repo
# root, and the pull runs from ANOTHER directory (the fleet-sweep: standing in org A's checkout,
# upgrading org B). Cases A–C all pin the channel to a LITERAL absolute path, so none of them can
# see where a *derivation* resolves — that gap is why the first fix's regression was invisible.
# The first fix read the channel as `(unset TELEGRAM_STATE_DIR REPO_DIR; . instance.env)`: no cwd
# pin, no REPO_DIR. Against a derived config that resolves the CALLER's directory — the SAME
# cross-wire the fix existed to close, and strictly WORSE than the original bug, because the wrong
# value is NON-EMPTY, so adopters-register's `empty ⇒ MERGE` guard never engages and the row is
# HARD-OVERWRITTEN. _channel_of_repo passes because it pins BOTH the cwd and REPO_DIR to the repo
# being read — and BOTH pins are asserted here, in the two spellings that separate them:
#   D1  `${REPO_DIR:-$PWD}/…`  — the anchor scripts/instance.env.example teaches for DERIVED paths
#       (MEMORY_DIR :146, MC_STATE_FILE :184); its own channel line is `${TELEGRAM_STATE_DIR:-}`, so
#       this models an adopter applying that idiom to their channel too. The `$PWD` fallback
#       makes the CWD pin the load-bearing one: drop it and the value anchors on the caller's dir.
#   D2  `$REPO_DIR/…`          — the same anchor without the fallback, so the REPO_DIR pin is the
#       load-bearing one: drop it and (under `set +u`) the value anchors on `/`. D1 alone CANNOT
#       see that — with the cwd pinned, `${REPO_DIR:-$PWD}` resolves identically whether REPO_DIR
#       is exported or unset, so a lane carrying only D1 would leave half the fix untested.
# ── D1: `${REPO_DIR:-$PWD}/.kickoff/chan` — the caller's channel is its own `<caller>/.kickoff/chan`
# (the standard layout), so the over-correction reproduces THE INCIDENT exactly: org A's channel on
# org B's row.
read -r _CH4CLONE CH4AD _CH4SNAP <<< "$(build_pull_case "$CORE")"
CH4REG="$(mk)/adopters.json"; CH4CALLER="$(mk)"; CH4CALLER_CHAN="$CH4CALLER/.kickoff/chan"
mkdir -p "$CH4CALLER_CHAN"
CH4AD_CHAN="$(ch_canon "$CH4AD/.kickoff/chan")"      # where the DERIVATION must land: the ADOPTER's own
sed -i "s|^export TELEGRAM_STATE_DIR=.*|export TELEGRAM_STATE_DIR=\"\${TELEGRAM_STATE_DIR:-\${REPO_DIR:-\$PWD}/.kickoff/chan}\"|" \
  "$CH4AD/.kickoff/instance.env"
chk "CASE D fixture: the adopter's instance.env DERIVES its channel from \${REPO_DIR:-\$PWD} (the instance.env.example idiom), not a literal path" \
  "grep -qF 'export TELEGRAM_STATE_DIR=\"\${TELEGRAM_STATE_DIR:-\${REPO_DIR:-\$PWD}/.kickoff/chan}\"' \"$CH4AD/.kickoff/instance.env\""
# the fixture's SHARPNESS, asserted (a negative control, CASE B's shape): read this SAME file the way
# the over-correction did — REPO_DIR unset, cwd left at the caller's — and it resolves the CALLER's
# directory, not the adopter's. So the lane below constrains WHERE the derivation anchors, and can't
# be passing for an unrelated reason. In a command-substitution subshell: the cd/unset never escape.
CH4UNPINNED="$(cd "$CH4CALLER" 2>/dev/null || true; unset TELEGRAM_STATE_DIR REPO_DIR; set +u; . "$CH4AD/.kickoff/instance.env" >/dev/null 2>&1 || true; printf '%s' "${TELEGRAM_STATE_DIR:-}")"
chk "CASE D fixture is SHARP: a read that UNSETS REPO_DIR (cwd unpinned) resolves the CALLER's directory — the over-correction, reproduced on this very file" \
  "[ \"$CH4UNPINNED\" = \"$CH4CALLER_CHAN\" ] && [ \"$CH4UNPINNED\" != \"$CH4AD/.kickoff/chan\" ]"
CH4RC=0
CH4OUT="$(cd "$CH4CALLER" && KICKOFF_VERSIONS_DIR="$(mk)/vers" KICKOFF_ADOPTERS_REGISTRY="$CH4REG" REPO_DIR="$CH4AD" TELEGRAM_STATE_DIR="$CH4CALLER_CHAN" \
  bash "$KICKOFF" pull core-vB 2>&1)" || CH4RC=$?
CH4ROW_CHAN="$(ch_row "$CH4REG" "$CH4AD" channel)"
CH4ROW_TAG="$(ch_row "$CH4REG" "$CH4AD" tag)"
chk "REPO_DIR-derived channel: PULL OK (rc=0) — run from the CALLER's directory, so the row below is a real fleet-sweep register" \
  "[ $CH4RC -eq 0 ] && printf '%s' \"\$CH4OUT\" | grep -q 'PULL OK'"
chk "REPO_DIR-derived channel: the register REALLY ran (the row's tag advanced to core-vB) — no vacuous pass" \
  "[ \"$CH4ROW_TAG\" = core-vB ]"
chk "REPO_DIR-derived channel [RED under the over-correction]: the row carries the ADOPTER-anchored resolution (<adopter>/.kickoff/chan), never the caller-anchored one" \
  "[ \"$CH4ROW_CHAN\" = \"$CH4AD_CHAN\" ]"
chk "REPO_DIR-derived channel [RED under the over-correction]: the caller's CHANNEL is ABSENT from the ENTIRE registry" \
  "[ -s \"$CH4REG\" ] && ! grep -qF \"\$(ch_canon \"$CH4CALLER_CHAN\")\" \"$CH4REG\""
chk "REPO_DIR-derived channel [RED under the over-correction]: the caller's DIRECTORY appears NOWHERE in the registry (the \$PWD fallback never anchored a value)" \
  "[ -s \"$CH4REG\" ] && ! grep -qF \"\$(ch_canon \"$CH4CALLER\")\" \"$CH4REG\""
[ "$CH4ROW_CHAN" = "$CH4AD_CHAN" ] || printf '  ── row channel: %s\n  ── expected the ADOPTER-anchored: %s\n  ── the CALLER-anchored was:      %s\n' \
  "${CH4ROW_CHAN:-<no row/channel>}" "$CH4AD_CHAN" "$(ch_canon "$CH4CALLER_CHAN")"

# ── D2: the SAME derivation without the `$PWD` fallback — `$REPO_DIR/.kickoff/chan`. This is the
# half only the REPO_DIR pin can hold: under `set +u` an unset REPO_DIR expands to EMPTY, so the row
# gets the root-anchored `/.kickoff/chan` — non-empty garbage, which (per the MERGE guard) HARD-
# OVERWRITES whatever channel the row already carried. The adopter's row is pre-registered with its
# real channel so that overwrite is what the assertion actually observes.
read -r _CH5CLONE CH5AD _CH5SNAP <<< "$(build_pull_case "$CORE")"
CH5REG="$(mk)/adopters.json"; CH5CALLER="$(mk)"; CH5CALLER_CHAN="$CH5CALLER/.kickoff/chan"
mkdir -p "$CH5CALLER_CHAN"
CH5AD_CHAN="$(ch_canon "$CH5AD/.kickoff/chan")"
sed -i "s|^export TELEGRAM_STATE_DIR=.*|export TELEGRAM_STATE_DIR=\"\${TELEGRAM_STATE_DIR:-\$REPO_DIR/.kickoff/chan}\"|" \
  "$CH5AD/.kickoff/instance.env"
chk "CASE D2 fixture: the adopter's instance.env anchors its channel on a BARE \$REPO_DIR (no \$PWD fallback to rescue it)" \
  "grep -qF 'export TELEGRAM_STATE_DIR=\"\${TELEGRAM_STATE_DIR:-\$REPO_DIR/.kickoff/chan}\"' \"$CH5AD/.kickoff/instance.env\""
# the fixture's SHARPNESS, asserted: read this file with the cwd CORRECTLY pinned to the adopter but
# REPO_DIR unset — the pin combination the cwd-only fix would leave — and it still resolves to the
# root-anchored value. That is the proof D2 constrains the REPO_DIR pin SPECIFICALLY: no cwd pin can
# stand in for it here, so this assertion cannot be passing for an unrelated reason.
CH5UNPINNED="$(cd "$CH5AD" 2>/dev/null || true; unset TELEGRAM_STATE_DIR REPO_DIR; set +u; . "$CH5AD/.kickoff/instance.env" >/dev/null 2>&1 || true; printf '%s' "${TELEGRAM_STATE_DIR:-}")"
chk "CASE D2 fixture is SHARP: even with the CWD pinned to the adopter, a read that UNSETS REPO_DIR resolves the ROOT-anchored /.kickoff/chan — the cwd pin cannot cover this spelling" \
  "[ \"$CH5UNPINNED\" = /.kickoff/chan ]"
python3 "$AM" adopters-register --repo "$CH5AD" --tag core-vA --version-dir "$CH5AD" \
  --channel "$CH5AD_CHAN" --registry "$CH5REG" >/dev/null
CH5RC=0
CH5OUT="$(cd "$CH5CALLER" && KICKOFF_VERSIONS_DIR="$(mk)/vers" KICKOFF_ADOPTERS_REGISTRY="$CH5REG" REPO_DIR="$CH5AD" TELEGRAM_STATE_DIR="$CH5CALLER_CHAN" \
  bash "$KICKOFF" pull core-vB 2>&1)" || CH5RC=$?
CH5ROW_CHAN="$(ch_row "$CH5REG" "$CH5AD" channel)"
CH5ROW_TAG="$(ch_row "$CH5REG" "$CH5AD" tag)"
chk "bare-\$REPO_DIR channel: PULL OK (rc=0)" \
  "[ $CH5RC -eq 0 ] && printf '%s' \"\$CH5OUT\" | grep -q 'PULL OK'"
chk "bare-\$REPO_DIR channel: the register REALLY ran (the row's tag advanced to core-vB) — no vacuous pass on the pre-registered row" \
  "[ \"$CH5ROW_TAG\" = core-vB ]"
chk "bare-\$REPO_DIR channel [RED when the REPO_DIR pin is dropped]: the row still carries the ADOPTER-anchored channel — REPO_DIR was SET to the repo being read while its instance.env was sourced" \
  "[ \"$CH5ROW_CHAN\" = \"$CH5AD_CHAN\" ]"
chk "bare-\$REPO_DIR channel [RED when the REPO_DIR pin is dropped]: no ROOT-anchored /.kickoff/chan was HARD-OVERWRITTEN onto any row in the registry" \
  "[ -s \"$CH5REG\" ] && ! grep -qF '\"/.kickoff/chan\"' \"$CH5REG\""
[ "$CH5ROW_CHAN" = "$CH5AD_CHAN" ] || printf '  ── row channel: %s\n  ── expected the ADOPTER-anchored: %s\n  ── an unset REPO_DIR would give:  %s\n' \
  "${CH5ROW_CHAN:-<no row/channel>}" "$CH5AD_CHAN" "/.kickoff/chan"

# ── CASE E [RED under the OLD `${INSTANCE_ENV:-…}` CALL SITE] ── the caller must not get to choose
# WHICH FILE the channel is read out of. Cases A–D2 all pin where a read RESOLVES (the ambient value,
# the cwd, REPO_DIR) and every one of them takes for granted that the file being read is the
# ADOPTER's. A first cut of this fix passed a second argument:
#     _channel_of_repo "$REPO_DIR" "${INSTANCE_ENV:-$KICKOFF_DIR/instance.env}"
# "so a relocated config is registered as the running instance uses it". But INSTANCE_ENV is
# CALLER-ENVIRONMENT ONLY — deliberately NOT in _INSTANCE_ENV_WHITELIST (kickoff:245), so no repo's
# instance.env can ever set it and nothing repo-anchored ever fills it; the only thing that does is
# the session that invoked the pull. A worker session exports its own INSTANCE_ENV, so the sweep read
# org A's FILE for org B's row: THE INCIDENT again, through a third door — and in the HARD-OVERWRITE
# direction, because the wrong value is non-empty and adopters-register's `empty ⇒ MERGE` guard never
# engages. Pinning the cwd and REPO_DIR buys nothing when the caller picks the file: all three pins
# hold and the answer is still the caller's (asserted below, on the real helper). The call site is now
# `_channel_of_repo "$REPO_DIR"` — repo-anchored, no second argument — and THAT is what this lane locks.
read -r _CH6CLONE CH6AD _CH6SNAP <<< "$(build_pull_case "$CORE")"
CH6REG="$(mk)/adopters.json"; CH6CALLER="$(mk)"; CH6VERS="$(mk)"
CH6CALLER_CHAN="$CH6CALLER/.kickoff/chan"; mkdir -p "$CH6CALLER/.kickoff/state" "$CH6CALLER_CHAN"
CH6AD_CHAN="$(ch_canon "$CH6AD/.kickoff/chan")"
CH6CALLER_ENV="$CH6CALLER/.kickoff/instance.env"
# THE CALLER's own config — another worker's instance.env: its OWN channel, its OWN state paths, and
# the core clone/remote lines lifted VERBATIM from the adopter's file. That last part is deliberate:
# the ambient INSTANCE_ENV is what the engine load-imports for the WHOLE run, so sharing the two
# clone-locating lines makes the pull mechanically identical to CASE A's whichever file gets loaded —
# leaving WHICH FILE THE CHANNEL CAME FROM as the single variable this lane moves.
{ grep -E '^export (KICKOFF_CORE_DIR|KICKOFF_CORE_REMOTE)=' "$CH6AD/.kickoff/instance.env"
  printf 'export TELEGRAM_STATE_DIR="%s"\n' "$CH6CALLER_CHAN"
  printf 'export MC_STATE_FILE="%s"\n'      "$CH6CALLER/.kickoff/state/mission-state.json"
  printf 'export MEMORY_DB="%s"\n'          "$CH6CALLER/.kickoff/state/memory-index.db"
} > "$CH6CALLER_ENV"
chk "CASE E fixture: the CALLER's instance.env declares its OWN distinct channel and names the adopter's channel NOWHERE" \
  "grep -qF 'export TELEGRAM_STATE_DIR=\"$CH6CALLER_CHAN\"' \"$CH6CALLER_ENV\" && ! grep -qF '$CH6AD/.kickoff/chan' \"$CH6CALLER_ENV\""
chk "CASE E fixture: the ADOPTER's own instance.env still declares the ADOPTER's channel (the file a repo-anchored read must land on)" \
  "grep -qF 'export TELEGRAM_STATE_DIR=\"$CH6AD/.kickoff/chan\"' \"$CH6AD/.kickoff/instance.env\""
# the fixture's SHARPNESS, asserted (a negative control) — and this one is run against the REAL
# helper, sed-extracted from the engine under test (the adopt-selftest §20(b) driver idiom), driven
# with the OLD call site's argv over THESE fixtures. It shows the cwd pin, the REPO_DIR pin and the
# `unset` all doing their job and the answer STILL being the caller's, which is precisely why the
# second argument had to go. Extracted, not re-implemented: no re-statement of the idiom can drift.
CH6DRV="$(mk)/drv.sh"
{ printf 'set -uo pipefail\n'
  sed -n '/^_channel_of_repo() {/,/^}/p' "$KICKOFF"
  printf '_channel_of_repo %q %q\n' "$CH6AD" "$CH6CALLER_ENV"
} > "$CH6DRV"
CH6HONOURED="$(cd "$CH6CALLER" && bash "$CH6DRV" 2>/dev/null || true)"
chk "CASE E fixture is SHARP: the REAL helper driven with the OLD call site's argv (\$INSTANCE_ENV as arg 2) returns the CALLER's channel — every pin held, and the caller still chose the value" \
  "[ \"$CH6HONOURED\" = \"$CH6CALLER_CHAN\" ] && [ \"$CH6HONOURED\" != \"$CH6AD/.kickoff/chan\" ]"
chk "CASE E control really executed the ENGINE's own helper (body sed-extracted from the engine under test, non-empty read)" \
  "[ -n \"$CH6HONOURED\" ] && grep -q '^_channel_of_repo() {' \"$CH6DRV\" && grep -q 'unset TELEGRAM_STATE_DIR' \"$CH6DRV\""
# THE RUN — the real front door, FROM the caller's cwd, with the caller's INSTANCE_ENV ambient. The
# adopter's row is pre-registered with its REAL channel so the hard-overwrite is what fails, not a
# missing row. (KICKOFF_VERSIONS_DIR is redirected into a fixture dir on principle — this lane has no
# different-tag sibling so no worktree is parked, but no lane may ever be able to write ~/kickoff-versions.)
python3 "$AM" adopters-register --repo "$CH6AD" --tag core-vA --version-dir "$CH6AD" \
  --channel "$CH6AD_CHAN" --registry "$CH6REG" >/dev/null
CH6RC=0
CH6OUT="$(cd "$CH6CALLER" && KICKOFF_ADOPTERS_REGISTRY="$CH6REG" KICKOFF_VERSIONS_DIR="$CH6VERS" \
  REPO_DIR="$CH6AD" INSTANCE_ENV="$CH6CALLER_ENV" bash "$KICKOFF" pull core-vB 2>&1)" || CH6RC=$?
CH6ROW_CHAN="$(ch_row "$CH6REG" "$CH6AD" channel)"
CH6ROW_TAG="$(ch_row "$CH6REG" "$CH6AD" tag)"
chk "caller-INSTANCE_ENV pull: PULL OK (rc=0) — the caller's config was ambient for the WHOLE run and the pull still completed, so the row below is a real register" \
  "[ $CH6RC -eq 0 ] && printf '%s' \"\$CH6OUT\" | grep -q 'PULL OK'"
chk "caller-INSTANCE_ENV pull: the register REALLY ran (the row's tag advanced to core-vB) — no vacuous pass on the pre-registered row" \
  "[ \"$CH6ROW_TAG\" = core-vB ]"
chk "caller-INSTANCE_ENV pull [RED under the \${INSTANCE_ENV:-…} call site]: the row carries the ADOPTER's OWN channel — which FILE was read is decided by the REPO, never by the caller's environment" \
  "[ \"$CH6ROW_CHAN\" = \"$CH6AD_CHAN\" ]"
chk "caller-INSTANCE_ENV pull [RED under the \${INSTANCE_ENV:-…} call site]: the caller's channel is ABSENT from the ENTIRE registry (no row was hard-overwritten with it)" \
  "[ -s \"$CH6REG\" ] && ! grep -qF \"\$(ch_canon \"$CH6CALLER_CHAN\")\" \"$CH6REG\""
[ "$CH6ROW_CHAN" = "$CH6AD_CHAN" ] || printf '  ── row channel: %s\n  ── expected the ADOPTER'\''s:            %s\n  ── the caller'\''s INSTANCE_ENV names: %s\n' \
  "${CH6ROW_CHAN:-<no row/channel>}" "$CH6AD_CHAN" "$(ch_canon "$CH6CALLER_CHAN")"

# ── CASE F [RED when the `cd "$repo"` pin is dropped] ── the CWD pin, on the one spelling that can
# SEE it. Neither D1 nor D2 can: D1's `${REPO_DIR:-$PWD}` is satisfied by EITHER pin (with REPO_DIR
# exported to the repo the `$PWD` fallback never fires, so deleting the cd changes nothing there), and
# D2's bare `$REPO_DIR` has no `$PWD` in it at all. Only an anchor that is `$PWD` and NOTHING ELSE
# makes `cd "$repo"` load-bearing — and that is a real adopter's file, not a contrivance: it is what
# instance.env.example's taught `${REPO_DIR:-$PWD}` becomes when an adopter editing their config from
# inside their own repo keeps the half that worked. The pull then runs from ANOTHER directory (the
# fleet sweep: standing in org A's checkout, upgrading org B) and the anchor resolves wherever the
# reader happens to stand — non-empty, so the `empty ⇒ MERGE` guard never engages and org A's
# directory HARD-OVERWRITES org B's row.
# SCOPE: this drives the REAL `kickoff pull` end-to-end (no helper driver needed) — cmd_pull never
# cd's, so at the step-4d call site $PWD is still the caller's cwd and the deletion is observable
# through the front door.
read -r _CH7CLONE CH7AD _CH7SNAP <<< "$(build_pull_case "$CORE")"
CH7REG="$(mk)/adopters.json"; CH7CALLER="$(mk)"; CH7VERS="$(mk)"; mkdir -p "$CH7CALLER/.kickoff/chan"
CH7AD_CHAN="$(ch_canon "$CH7AD/.kickoff/chan")"
sed -i "s|^export TELEGRAM_STATE_DIR=.*|export TELEGRAM_STATE_DIR=\"\${TELEGRAM_STATE_DIR:-\$PWD/.kickoff/chan}\"|" \
  "$CH7AD/.kickoff/instance.env"
chk "CASE F fixture: the adopter's instance.env anchors its channel on a BARE \$PWD — no REPO_DIR anywhere in the expression, so ONLY the cwd pin can resolve it" \
  "grep -qF 'export TELEGRAM_STATE_DIR=\"\${TELEGRAM_STATE_DIR:-\$PWD/.kickoff/chan}\"' \"$CH7AD/.kickoff/instance.env\" && ! grep 'TELEGRAM_STATE_DIR' \"$CH7AD/.kickoff/instance.env\" | grep -q 'REPO_DIR'"
# the fixture's SHARPNESS, asserted (a negative control): the EXACT mutant read — the `unset` and the
# REPO_DIR pin still in place, ONLY the cd removed, cwd left at the caller's — lands in the CALLER's
# directory over this very file. So the lane below constrains the cwd pin SPECIFICALLY and cannot be
# passing because REPO_DIR happened to cover it. In a command-substitution subshell: nothing escapes.
CH7UNPINNED="$(cd "$CH7CALLER" 2>/dev/null || true; unset TELEGRAM_STATE_DIR; REPO_DIR="$CH7AD"; export REPO_DIR; set +u; . "$CH7AD/.kickoff/instance.env" >/dev/null 2>&1 || true; printf '%s' "${TELEGRAM_STATE_DIR:-}")"
chk "CASE F fixture is SHARP: the same read WITHOUT the cd (unset + REPO_DIR pin both kept) resolves the CALLER's directory — the exact mutant, reproduced on this file" \
  "[ \"$CH7UNPINNED\" = \"$CH7CALLER/.kickoff/chan\" ] && [ \"$CH7UNPINNED\" != \"$CH7AD/.kickoff/chan\" ]"
# THE RUN — from the CALLER's cwd, with NO ambient channel set: the caller's cwd is the lane's only
# caller-side input, so nothing but the cd pin can be under test. Row pre-registered with the
# adopter's real channel, so a caller-anchored value is observed as the hard OVERWRITE it is.
python3 "$AM" adopters-register --repo "$CH7AD" --tag core-vA --version-dir "$CH7AD" \
  --channel "$CH7AD_CHAN" --registry "$CH7REG" >/dev/null
CH7RC=0
CH7OUT="$(cd "$CH7CALLER" && KICKOFF_ADOPTERS_REGISTRY="$CH7REG" KICKOFF_VERSIONS_DIR="$CH7VERS" \
  REPO_DIR="$CH7AD" bash "$KICKOFF" pull core-vB 2>&1)" || CH7RC=$?
CH7ROW_CHAN="$(ch_row "$CH7REG" "$CH7AD" channel)"
CH7ROW_TAG="$(ch_row "$CH7REG" "$CH7AD" tag)"
chk "bare-\$PWD channel: PULL OK (rc=0) — run from the CALLER's directory, so the row below is a real fleet-sweep register" \
  "[ $CH7RC -eq 0 ] && printf '%s' \"\$CH7OUT\" | grep -q 'PULL OK'"
chk "bare-\$PWD channel: the register REALLY ran (the row's tag advanced to core-vB) — no vacuous pass on the pre-registered row" \
  "[ \"$CH7ROW_TAG\" = core-vB ]"
chk "bare-\$PWD channel [RED when the cd pin is dropped]: the row carries the ADOPTER-anchored resolution (<adopter>/.kickoff/chan) — the cwd was pinned to the repo being READ, not left at the caller's" \
  "[ \"$CH7ROW_CHAN\" = \"$CH7AD_CHAN\" ]"
chk "bare-\$PWD channel [RED when the cd pin is dropped]: the CALLER's DIRECTORY appears NOWHERE in the registry, raw or realpath (no \$PWD anchored a value there)" \
  "[ -s \"$CH7REG\" ] && ! grep -qF \"$CH7CALLER\" \"$CH7REG\" && ! grep -qF \"\$(ch_canon \"$CH7CALLER\")\" \"$CH7REG\""
[ "$CH7ROW_CHAN" = "$CH7AD_CHAN" ] || printf '  ── row channel: %s\n  ── expected the ADOPTER-anchored: %s\n  ── the caller-anchored would be:  %s\n' \
  "${CH7ROW_CHAN:-<no row/channel>}" "$CH7AD_CHAN" "$CH7CALLER/.kickoff/chan"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "10. suite hygiene — NO fixture process this suite spawned outlives the run"
# ══════════════════════════════════════════════════════════════════════════════════════
# Every `sleep 300 &` live-supervisor fixture is killed INLINE after its case; the EXIT trap is the
# safety net for a set -e abort between spawn and kill. Assert HERE (before the trap fires) that the
# suite's OWN reaping already left nothing alive — a skipped kill or a leaked spawn fails LOUD. Scoped
# to THIS run's exact recorded pids (kill -0), never a `ps|grep` pattern that would catch another org.
LEAKED_PIDS=""
while IFS= read -r _p; do
  case "$_p" in ''|*[!0-9]*) continue ;; esac
  kill -0 "$_p" 2>/dev/null && LEAKED_PIDS="$LEAKED_PIDS $_p"
done < "$PID_LIST"
chk "no fixture process this suite spawned is still alive (all recorded \`sleep 300 &\` pids reaped)" \
  "[ -z \"$LEAKED_PIDS\" ]"
[ -n "$LEAKED_PIDS" ] && printf '  ── leaked fixture pids (should be empty):%s\n' "$LEAKED_PIDS"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "17. consumer-verify — the pull summary READS the delivered opencode set back off the adopter's disk"
# ══════════════════════════════════════════════════════════════════════════════════════
# THE COMPLAINT THIS CLOSES: the pull summary CLAIMED the opencode engine-parity set was
# back-filled; nothing ever READ the delivered files back off the ADOPTER'S OWN DISK — the
# writer's bookkeeping graded its own homework. After the 4b-2 back-fill, the summary now
# verifies the FIVE surfaces (opencode.json parses + default_agent=coordinator · NO
# model/provider key anywhere · the 5 crew charters · BOTH plugins · the AGENTS.md pointer
# resolves) and prints ONE honest scope line: files verified, NOT a live session (no spawn).
# A failed check is NAMED loudly — a diagnostic, never a gate (rc stays 0, the success line
# never prints over a broken set).
#
# RED-FIRST: these lanes ran against the pre-slice kickoff and were observed RED (no verify
# line on a green back-fill pull; pre-existing broken files went unnamed). The RED lanes are
# BOXE-SHAPED by necessity: a RECORDED seam's hand-edit REFUSES the whole pull at 4b (fail-
# closed, by design — a different guard), so a broken file must arrive as the adopter's own
# PRE-EXISTING bytes (kept, never clobbered, never recorded) for the pull to go green while
# the consumer's disk is wrong — precisely the silence this feature exists to end.
# HERMETIC: build_pull_case fixtures + scratch registries; the verify is asserted READ-ONLY.
# jsonc-tolerant pin walk (opencode parses opencode.json as jsonc — the §5b tolerance).
cv_pinfree() {   # $1 = opencode.json path → rc 0 iff NO model/provider-ish key anywhere in it
  python3 -c "
import json, re, sys
def walk(d):
    if isinstance(d, dict):
        return all(('model' not in k.lower() and 'provider' not in k.lower()) for k in d) and all(walk(v) for v in d.values())
    if isinstance(d, list): return all(walk(v) for v in d)
    return True
text = open(sys.argv[1]).read()
sys.exit(0 if walk(json.loads(re.sub(r'^\s*//.*$', '', text, flags=re.M))) else 1)
" "$1"
}

# (a) the happy back-fill: the verify line is present AND all five checks demonstrably true
#     on the adopter's own disk.
read -r CV_CLONE CV_ADOPTER _CV_SNAP <<< "$(build_pull_case "$CORE")"
CV_REG="$(mk)/adopters.json"
CV_RC=0
CV_OUT="$(KICKOFF_ADOPTERS_REGISTRY="$CV_REG" REPO_DIR="$CV_ADOPTER" bash "$KICKOFF" pull core-vB 2>&1)" || CV_RC=$?
chk "17 (a) the back-fill pull exits 0"                                                        "[ $CV_RC -eq 0 ]"
chk "17 (a) the summary carries the consumer-verify line (files verified, NOT a live session)" \
  "printf '%s' \"\$CV_OUT\" | grep -qF 'opencode: verified files, not a live session'"
chk "17 (a) the verify line names all five surfaces it verified" \
  "printf '%s' \"\$CV_OUT\" | grep -F 'opencode: verified files' | grep -q 'default_agent=coordinator' \
   && printf '%s' \"\$CV_OUT\" | grep -F 'opencode: verified files' | grep -q 'no model/provider pin' \
   && printf '%s' \"\$CV_OUT\" | grep -F 'opencode: verified files' | grep -q 'charters' \
   && printf '%s' \"\$CV_OUT\" | grep -F 'opencode: verified files' | grep -q 'plugins' \
   && printf '%s' \"\$CV_OUT\" | grep -F 'opencode: verified files' | grep -q 'AGENTS.md resolves'"
chk "17 (a) [1] delivered opencode.json parses + default_agent=coordinator (on the adopter's disk)" \
  "[ \"\$(oc_json_pull \"$CV_ADOPTER/opencode.json\" default_agent)\" = \"coordinator\" ]"
chk "17 (a) [2] NO model/provider key anywhere in the delivered opencode.json"                 "cv_pinfree \"$CV_ADOPTER/opencode.json\""
chk "17 (a) [3] all 5 crew charters present on the adopter's disk"                             "[ \$(ls \"$CV_ADOPTER/.opencode/agent/\"*.md 2>/dev/null | wc -l) -ge 5 ]"
chk "17 (a) [4] BOTH plugins present on the adopter's disk" \
  "[ -s \"$CV_ADOPTER/.opencode/plugins/memory-search.js\" ] && [ -s \"$CV_ADOPTER/.opencode/plugins/engine-credit.js\" ]"
chk "17 (a) [5] the AGENTS.md pointer exists AND resolves (not a dangling link)"               "[ -e \"$CV_ADOPTER/AGENTS.md\" ]"

# (b) THE RED PROOF — the adopter's OWN pre-existing broken files (a pinned opencode.json, an
#     emptied charter, a dangling AGENTS.md link) are KEPT by the never-clobber back-fill, the
#     pull goes green — and the verify must NAME each broken check, loudly, rc 0, no success
#     line, and NEVER touch the adopter's files (read-only diagnostic).
read -r CVX_CLONE CVX_ADOPTER _CVX_SNAP <<< "$(build_pull_case "$CORE")"
CVX_REG="$(mk)/adopters.json"
mkdir -p "$CVX_ADOPTER/.opencode/agent"
printf '{"default_agent":"coordinator","provider":{"stub":{"models":{"m":{}}}}}\n' > "$CVX_ADOPTER/opencode.json"
: > "$CVX_ADOPTER/.opencode/agent/planner.md"
ln -s NOWHERE "$CVX_ADOPTER/AGENTS.md"     # lexists=true → never clobbered; does NOT resolve
cp "$CVX_ADOPTER/opencode.json" "$CVX_ADOPTER/ocjson.pre"
cp "$CVX_ADOPTER/.opencode/agent/planner.md" "$CVX_ADOPTER/planner.pre"
CVX_RC=0
CVX_OUT="$(KICKOFF_ADOPTERS_REGISTRY="$CVX_REG" REPO_DIR="$CVX_ADOPTER" bash "$KICKOFF" pull core-vB 2>&1)" || CVX_RC=$?
chk "17 (b) the pull still exits 0 over broken consumer files — the verify is a diagnostic, NEVER a gate" "[ $CVX_RC -eq 0 ]"
chk "17 (b) the verify output is LOUD about the broken set (opencode VERIFY ...)"              "printf '%s' \"\$CVX_OUT\" | grep -q 'opencode VERIFY'"
chk "17 (b) [2 RED] their pinned opencode.json is NAMED (the model/provider check)"           "printf '%s' \"\$CVX_OUT\" | grep -q 'model/provider key'"
chk "17 (b) [3 RED] their emptied charter is NAMED (planner)"                                 "printf '%s' \"\$CVX_OUT\" | grep -q 'planner' && printf '%s' \"\$CVX_OUT\" | grep -qi 'charter'"
chk "17 (b) [5 RED] their dangling AGENTS.md link is NAMED (the pointer-resolves check)"      "printf '%s' \"\$CVX_OUT\" | grep -q 'AGENTS.md pointer'"
chk "17 (b) NO success line over a broken set (a failed read-back never claims 'verified')"   "! printf '%s' \"\$CVX_OUT\" | grep -qF 'opencode: verified files'"
chk "17 (b) the verify is READ-ONLY: their opencode.json is byte-identical after the pull"     "cmp -s \"$CVX_ADOPTER/ocjson.pre\" \"$CVX_ADOPTER/opencode.json\""
chk "17 (b) the verify is READ-ONLY: their emptied charter is byte-identical after the pull"   "cmp -s \"$CVX_ADOPTER/planner.pre\" \"$CVX_ADOPTER/.opencode/agent/planner.md\""

# (c) the HONEST SKIP — a pull to an opencode-LESS tag (the pinned core-vA clone predates the
#     set) runs the whole path with NO back-fill, NO verify line, and NO crash: nothing was
#     delivered, so nothing is claimed (the same silence as the back-fill's own skip discipline).
read -r CVS_CLONE CVS_ADOPTER _CVS_SNAP <<< "$(build_pull_case "$CORE")"
CVS_REG="$(mk)/adopters.json"
CVS_RC=0
CVS_OUT="$(KICKOFF_ADOPTERS_REGISTRY="$CVS_REG" REPO_DIR="$CVS_ADOPTER" bash "$KICKOFF" pull core-vA 2>&1)" || CVS_RC=$?
chk "17 (c) an older/opencode-less-tag pull exits 0 (no crash on a world without the set)"     "[ $CVS_RC -eq 0 ]"
chk "17 (c) NO verify line and NO VERIFY FAILED — nothing claimed where nothing was delivered" \
  "! printf '%s' \"\$CVS_OUT\" | grep -qF 'opencode: verified files' && ! printf '%s' \"\$CVS_OUT\" | grep -q 'opencode VERIFY'"
echo

echo "──────────────────────────────"
echo "  $PASS passed, $FAIL failed"
# The failure summary deliberately does NOT carry the "  ❌" check-marker: lane D's executor proof
# counts "  ❌" lines in this suite's output as the FAILED-CHECK count (exactly 1 = the frozen
# digest line only). A second marker here would make every honest one-failure run unprovable.
[ "$FAIL" -eq 0 ] && { echo "  ✅ kickoff pull holds"; exit 0; } || { echo "  ══ see failures above — this run is NOT green"; exit 1; }
