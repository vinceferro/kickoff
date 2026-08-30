#!/usr/bin/env bash
# journey-e2e.sh — the END-TO-END JOURNEY test for the kickoff brownfield engine.
#
#   bash scripts/journey-e2e.sh
#
# The INTEGRATION proof of the make-or-break: the per-slice selftests (adopt / eject / pull /
# plugin / ingress) each prove ONE slice in isolation; THIS drives REALISTIC repos through the
# WHOLE journey against the REAL engine scripts and asserts each stage COMPOSES — ending on the
# headline zero-trace acceptance test.
#
# HONESTY MANDATE (why this file exists in THIS shape): a previous pass shipped a 50/0 "zero-trace"
# green while STUBBING the `/adopt` half — the intelligent, skill-driven step that authors the
# CLAUDE.md content + crew + tracker + memory + lefthook gates and RECORDS each touch. eject only
# reverses what the manifest records, so an un-recorded skill footprint is invisible to eject and
# the green lit a false headline ([[e2e-stubbing-the-intelligent-half-proves-only-the-mechanical]]).
# This e2e therefore SIMULATES the `/adopt` session for real — authoring the skill's file set and
# recording every touch EXACTLY as plugin/skills/adopt/SKILL.md instructs — so the eject reversal
# is tested against BOTH halves (the mechanical `kickoff adopt` footprint AND the skill-authored one).
#
# THE JOURNEY (each stage prints PASS/FAIL; asserts on REAL state, not just its own markers):
#   1. FIXTURE  — a realistic "already using AI" brownfield repo: git init + a CLEAN baseline commit,
#                 its OWN pre-existing CLAUDE.md, a HUMAN-WRITTEN NON-CANONICAL .claude/settings.json
#                 carrying a PRE-EXISTING top-level key, an operator crew, a PLANTED secret in
#                 settings.local.json, + source.
#   2. ADOPT    — the REAL `kickoff adopt`: additive, .kickoff/ created, the manifest records the
#                 seams, the settings.json seam is applied while the operator's key is PRESERVED.
#   3. /ADOPT   — the SIMULATED intelligent session: author the crew + CLAUDE.md content + TRACKER.md
#                 + the .kickoff/memory corpus + .kickoff/lefthook-kickoff.yml + root lefthook.yml, and
#                 RECORD each touch (seeded-instance; the CLAUDE.md content-edit as a byte-restore SEAM
#                 layered on adopt's block-append). THIS is the half the old e2e stubbed.
#   4. RUN      — the REAL `kickoff preflight` reaches GREEN; the mc seam shim RESOLVES + dispatches;
#                 instance state ACCUMULATES (a board headline/log + a memory) so eject relocation is real.
#   5. SERVE    — the REAL ingress.sh over a SCRATCH INGRESS_DIR + scratch port + fixture upstream.
#   6. UPGRADE  — the REAL `kickoff pull` re-pins the core while the operator-owned layer stays byte-identical.
#   6c. UPGRADE-HOP — THE G1 ACCEPTANCE (v0.7 slice 6): an adopter on fixture-tag N with a REAL
#                 supervisor + a stub session → ONE `kickoff pull` of N+1 → the supervisor HOPS
#                 (same PID, engine N+1's code), the session respawns from the N+1 engine dir,
#                 PERMISSION_MODE carries, instance.env MODEL/EFFORT re-resolve (not fossil env).
#   6d. RED-FIRST — the same lane against a REAL core-v0.6 supervisor (no hop unit): the hop
#                 assertions provably FAIL (no hop ever fires) — §3's honest asterisk, proven.
#   7. EJECT    — the REAL `kickoff eject --verify` (DEFAULT keep): settings.json + CLAUDE.md byte-restored
#                 to their EXACT originals (sha256); seams gone; the SKILL-AUTHORED seeded-instance
#                 deliverables SURVIVE (crew/TRACKER in place, KICKOFF.local.md + memory corpus relocated
#                 to kickoff-data/); NO tracked-file drift vs the pristine baseline; --verify: no trace.
#   8. PRISTINE — a fresh adoption, `eject --purge --delete-data` → `git status --porcelain` LITERALLY
#                 empty + tree == baseline (the strongest byte-for-byte zero-trace claim).
#   9. COMMITTED— a fresh adoption whose CREATED seams are COMMITTED → eject → --verify rc0 with the
#                 ` D` seam-deletions classified as EXPECTED reversal ("commit to finalize").
#  10. RESIDUE  — a fresh adoption with a planted `kickoff@kickoff-local` marker eject cannot account for
#                 → `--verify` exits NON-ZERO (the counter-proof that rc0 means something).
#  11. GREENFIELD— create-then-adopt OUTSIDE the clone, via a SYMLINKED front door (exercises the
#                 readlink-`$0` fix) → eject → zero-trace (de-integration comes free for greenfield).
#
# LIVE-SAFETY (the e2e must NEVER touch the live box): EVERY real-engine call runs with `env -u REPO_DIR`
# + an EXPLICIT fixture REPO_DIR/KICKOFF_CORE_DIR/KICKOFF_ADOPTERS_REGISTRY/INGRESS_DIR/CLAUDE_CONFIG_DIR/KICKOFF_MODEL_DIR
# (ambient REPO_DIR = the live worker's repo — a bare call would target PRODUCTION). Plugin actions go
# through a HERMETIC STUB `claude` under an isolated CLAUDE_CONFIG_DIR. Serving uses a scratch INGRESS_DIR
# + scratch listen port (19500) — never :9000/:443/:2019. A LIVE-SAFETY CANARY (stage 0/12) proves the
# live front door + this repo are untouched. Deps: python3 + git + jq + curl + coreutils.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
KICKOFF="$REPO/scripts/kickoff"
INGRESS_SH="$REPO/scripts/ingress.sh"
MANIFEST_SRC="$REPO/scripts/core-manifest.txt"

LISTEN="${JOURNEY_LISTEN:-19500}"          # scratch caddy listen port (NEVER 9000)
UP_PORT="${JOURNEY_UP_PORT:-18091}"        # fixture upstream port (scratch; not a reserved MC port)
LIVE_INGRESS="${INGRESS_LIVE_DIR:-$HOME/box-ingress}"   # the live singleton — for the canary only

# ── self-scrub the ambient instance.env whitelist (robust push-gate) ──────────────────────────────
# This e2e builds its OWN hermetic mktemp fixtures, but the lefthook pre-push gate runs inside a
# kickoff-managed session whose ambient env exports the LIVE repo's whitelist vars (TELEGRAM_STATE_DIR,
# MEMORY_INDEX, MC_STATE_FILE, …). A preset env var WINS over a fixture's instance.env, so an unscrubbed
# run leaks the live channel/data paths into the fixtures' engine calls and false-fails (e.g. preflight's
# pull-adopter data-path isolation). Unset the whole whitelist ONCE here — the SAME set the unit suites
# scrub — before any fixture setup; the per-fixture kf/kfl wrappers set their own values after this.
# Ambient git env OVERRIDES `git -C <fixture>` (seen live 2026-08-23: fixture commits+tag
# landed on a live repo at the v0.39 pin and leaked a stray core-vT tag) - strip it first.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE 2>/dev/null || true
unset REPO_DIR KICKOFF_CORE_DIR KICKOFF_CORE_REMOTE MC_STATE_FILE MC_TRACKER_FILE \
      MEMORY_DB MEMORY_HOOK_LOG MEMORY_DIR MEMORY_INDEX TELEGRAM_STATE_DIR CHANNEL_SPEC \
      REGROUND_PROMPT PERMISSION_MODE EFFORT MODEL MAX_CONCURRENT_AGENTS DEPLOY_BRANCH \
      CADENCE INSTANCE_ENV LOCKFILE ORIGIN_STATE_DIR OPERATOR_STATE_DIR 2>/dev/null || true

PASS=0; FAIL=0
ok()  { printf '  \342\234\205 %s\n' "$1"; PASS=$((PASS+1)); }   # ✅
bad() { printf '  \342\235\214 %s\n' "$1"; FAIL=$((FAIL+1)); }   # ❌
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
stage() { printf '\n\342\226\266 %s\n' "$1"; }                    # ▶

for t in python3 git jq curl; do
  command -v "$t" >/dev/null 2>&1 || { echo "  ❌ $t not found — cannot run the journey e2e"; exit 1; }
done

# ── ONE EXIT trap: clean our OWN mktemp dirs (never a wildcard sweep) + kill the fixture upstream ──
CLEANUP_LIST="$(mktemp)"
UPSTREAM_PID=""
# exact-pid teardown for stage (6c/6d)'s fixture supervisors + their stub sessions: every pid
# in $JRNY_PIDS was spawned BY THIS TEST (recorded at spawn) — never a pattern kill. The
# trailing group-kill reaps a fixture supervisor's setsid'd session group by that exact pgid.
JRNY_PIDS="$(mktemp)"
mk() { local d; d="$(mktemp -d)"; printf '%s\n' "$d" >> "$CLEANUP_LIST"; printf '%s' "$d"; }
cleanup() {
  [ -n "$UPSTREAM_PID" ] && kill "$UPSTREAM_PID" 2>/dev/null
  if [ -f "$JRNY_PIDS" ]; then
    while IFS= read -r _p; do
      case "$_p" in ''|*[!0-9]*) continue ;; esac
      kill -TERM "$_p" 2>/dev/null || true
    done < "$JRNY_PIDS"
    sleep 1
    while IFS= read -r _p; do
      case "$_p" in ''|*[!0-9]*) continue ;; esac
      kill -KILL "$_p" 2>/dev/null || true
      kill -KILL -- "-$_p" 2>/dev/null || true
    done < "$JRNY_PIDS"
    rm -f "$JRNY_PIDS"
  fi
  while IFS= read -r _d; do [ -n "$_d" ] && rm -rf "$_d"; done < "$CLEANUP_LIST"
  rm -f "$CLEANUP_LIST"
}
trap cleanup EXIT

# The planted fake secret — a shell VAR (never a source-literal credential), so the secret-scanner
# sees no hardcoded credential in this test's own source. It must survive eject byte-for-byte.
PLANT='FAKE_TELEGRAM_TOKEN_journey_e2e_do_not_store_0000'

echo "════════════════════════════════════════════════════════════════════"
echo "  kickoff brownfield engine — END-TO-END JOURNEY (integration proof)"
echo "════════════════════════════════════════════════════════════════════"

# ── (0) LIVE-SAFETY CANARY — snapshot the live front door BEFORE the journey ──────────────────────
canary_hash() { [ -f "$1" ] && sha256sum "$1" | awk '{print $1}' || printf 'ABSENT'; }
LIVE_REG_BEFORE="$(canary_hash "$LIVE_INGRESS/registry.json")"
LIVE_CF_BEFORE="$(canary_hash "$LIVE_INGRESS/Caddyfile")"
live_caddy_pids() { pgrep -f "$LIVE_INGRESS/Caddyfile" 2>/dev/null | sort -u | tr '\n' ' '; }
LIVE_PIDS_BEFORE="$(live_caddy_pids)"
LIVE_REPO_STATUS_BEFORE="$(git -C "$REPO" status --porcelain 2>/dev/null | sha256sum | awk '{print $1}')"
LIVE_KICKOFF_DIR_BEFORE="$(canary_hash "$REPO/.kickoff/adopt-manifest.json")"   # the live .kickoff/ (if any)

# ══════════════════════════════════════════════════════════════════════════════════════
# The HERMETIC STUB `claude` — a faithful, ISOLATED model of the local-path-plugin behavior
# (lifted from plugin-selftest.sh's stub). marketplace add → known_marketplaces.json (+
# extraKnownMarketplaces at project scope); install → installed_plugins.json + a byte-snapshot of
# the plugin source into cache/<mkt>/<plugin>/<version>/ (+ enabledPlugins at project scope);
# update → version-gated re-snapshot; uninstall/marketplace-remove → delete cache + registry AND
# re-serialize the project settings.json (the real-claude re-canonicalization that the eject
# "reversal-must-be-the-final-write" re-assert exists to undo). HARD-REFUSES without
# CLAUDE_CONFIG_DIR (so a test can never touch the live ~/.claude).
# ══════════════════════════════════════════════════════════════════════════════════════
write_stub_claude() {   # $1 = dir to place the `claude` stub in
  local d="$1"
  cat > "$d/claude" <<'PYEOF'
#!/usr/bin/env python3
import json, os, sys, shutil, tempfile
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
    os.makedirs(os.path.dirname(p), exist_ok=True); json.dump(d, open(p, "w"), indent=2)
def proj_settings_path():
    return os.path.join(os.getcwd(), ".claude", "settings.json")
def _assert_proj_under_tmp(p):
    rp = os.path.realpath(p)
    roots = {os.path.realpath(r) for r in (tempfile.gettempdir(), os.environ.get("TMPDIR"), "/tmp") if r}
    if not any(rp == root or rp.startswith(root + os.sep) for root in roots):
        sys.stderr.write("stub-claude: REFUSING a project settings.json write outside a temp dir: %s\n" % rp); sys.exit(4)
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
    shutil.copytree(proot, dst); return dst
if pos and pos[0] == "marketplace":
    sub = pos[1] if len(pos) > 1 else ""
    if sub == "add":
        src = os.path.abspath(pos[2]); mm = mkt_manifest(src); name = mm["name"]
        km = load(km_path, {}); km[name] = {"source": {"source": "directory", "path": src}, "installLocation": src}; save(km_path, km)
        if scope == "project":
            sd = load_proj(); sd.setdefault("extraKnownMarketplaces", {})[name] = {"source": {"source": "directory", "path": src}}; save_proj(sd)
        print("Successfully added marketplace: %s" % name); sys.exit(0)
    if sub == "update":
        print("Updated marketplace(s)"); sys.exit(0)
    if sub in ("remove", "rm"):
        name = pos[2]; km = load(km_path, {}); km.pop(name, None); save(km_path, km)
        if (scope == "project" or not scope_given) and os.path.exists(proj_settings_path()):
            sd = load_proj(); sd.get("extraKnownMarketplaces", {}).pop(name, None); save_proj(sd)
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
    if not rows: sys.stderr.write('✘ not installed\n'); sys.exit(1)
    if installed_scope != scope: sys.stderr.write('✘ not installed at scope %s\n' % scope); sys.exit(1)
    src = load(km_path, {}).get(mkt, {}).get("source", {}).get("path")
    mm = mkt_manifest(src); proot = plugin_root(src, mm, plugin); cur = plugin_ver(proot)
    if rows[0].get("version") == cur:
        print("already at the latest version"); sys.exit(0)
    dst = snapshot(proot, mkt, plugin, cur); ip["plugins"][spec] = [{"scope": installed_scope, "installPath": dst, "version": cur}]; save(ip_path, ip)
    print("Restart to apply changes"); sys.exit(0)
if pos and pos[0] in ("uninstall", "remove"):
    spec = pos[1]; plugin, mkt = spec.split("@", 1)
    ip = load(ip_path, {"version": 2, "plugins": {}}); rows = ip.get("plugins", {}).get(spec, [])
    installed_scope = rows[0].get("scope") if rows else None
    if not rows: sys.stderr.write('✘ not installed\n'); sys.exit(1)
    if installed_scope != scope: sys.stderr.write('✘ enabled at %s scope\n' % installed_scope); sys.exit(1)
    pdir = os.path.join(cachedir, mkt, plugin)
    if os.path.isdir(pdir): shutil.rmtree(pdir)
    ip.get("plugins", {}).pop(spec, None); save(ip_path, ip)
    if scope == "project" and os.path.exists(proj_settings_path()):
        sd = load_proj(); sd.get("enabledPlugins", {}).pop(spec, None); sd.setdefault("enabledPlugins", {}); save_proj(sd)
    print("Uninstalled %s (scope: %s)" % (spec, scope)); sys.exit(0)
sys.exit(0)
PYEOF
  chmod +x "$d/claude"
}

# ── the shared scratch topology (the real pull model: core runs from a SEPARATE clone) ────────────
# $CORE  = the "origin" source repo (a git repo with the plugin + engine + a core-vE2E tag).
# $CLONE = a `git clone $CORE`, checked out detached at core-vE2E — this is KICKOFF_CORE_DIR (the
#          read-only pinned core the adopter runs from, OUTSIDE the adopter repo).
CFG="$(mk)"                 # isolated CLAUDE_CONFIG_DIR (the live ~/.claude is NEVER touched)
STUB="$(mk)"; write_stub_claude "$STUB"
REG="$(mk)/adopters.json"   # isolated adopters registry (the live ~/.kickoff/adopters.json untouched)
ING="$(mk)"                 # scratch INGRESS_DIR (the live ~/box-ingress is NEVER touched)
MODELS="$(mk)"              # isolated KICKOFF_MODEL_DIR — the live ~/.cache/kickoff-models is NEVER read.
                            # Without this, a box with a WARM live model makes pull's install-model step
                            # (`--if-needed`) read durablePresent=true → "semantic in use" → `pnpm install`
                            # into the FRESH synthetic clone → an untracked node_modules/pnpm-* dirties the
                            # read-only tree → a FALSE preflight-#6 clean-tree fail. An empty scratch dir →
                            # a clean no-op (the true keyword-only shape). (Hermeticity gap LIVE-SAFETY missed.)
ARCHIVE_DIR="$(mk)"         # scratch eject archive dir (never $HOME)
LINKDIR="$(mk)"; LINK="$LINKDIR/kickoff"; ln -s "$KICKOFF" "$LINK"   # symlinked front door (readlink -f fix)
CORE_TAG="core-vE2E"
CORE=""; CLONE=""

build_core_and_clone() {
  CORE="$(mk)"; CLONE="$(mk)"
  # Populate $CORE with EXACTLY the core-manifest.txt file set (so pull's existence guard + preflight
  # #6 whole-tree pin have every pinned file present) — copied from THIS repo's real engine.
  local rel
  while IFS= read -r rel; do
    rel="${rel%$'\r'}"; [ -z "$rel" ] && continue
    case "$rel" in \#*) continue ;; esac
    [ -e "$REPO/$rel" ] || continue
    mkdir -p "$CORE/$(dirname "$rel")"
    cp -a "$REPO/$rel" "$CORE/$rel"
  done < "$MANIFEST_SRC"
  [ -f "$CORE/CORE-CHANGELOG.md" ] || printf '# CORE-CHANGELOG\n\n## %s — 2026-07-07\n\nthe pinned journey-e2e core.\n' "$CORE_TAG" > "$CORE/CORE-CHANGELOG.md"
  git -C "$CORE" init -q; git -C "$CORE" config user.email e@e.e; git -C "$CORE" config user.name e
  git -C "$CORE" add -A; git -C "$CORE" commit -qm "core" >/dev/null; git -C "$CORE" tag "$CORE_TAG"
  git -C "$CORE" commit --allow-empty -qm "post-tag" >/dev/null    # keep $CORE HEAD on a branch (clonable)
  git clone -q "$CORE" "$CLONE"; git -C "$CLONE" checkout -q --detach "$CORE_TAG"
}

# ── env every real-engine invocation gets — LIVE-SAFE by construction ─────────────────────────────
# `env -u REPO_DIR` scrubs the ambient (live-repo) REPO_DIR FIRST, then an EXPLICIT fixture REPO_DIR is
# set — so a bare/forgotten call can never target production. KF_REPO MUST be set by the caller; a
# missing one HARD-FAILS (never silently auto-resolves to the live repo). PATH prepends the stub dir
# so `command -v claude` resolves the hermetic stub, never a real one.
KF_REPO=""
_kf_env_guard() {
  [ -n "$KF_REPO" ] && [ -n "$CLONE" ] || {
    printf '  \342\235\214 INTERNAL: engine call with KF_REPO/CLONE unset — refusing (would risk the live repo)\n' >&2
    FAIL=$((FAIL+1)); return 1
  }
}
kf() {   # run the real `kickoff` front door against the fixture, fully isolated
  _kf_env_guard || return 1
  env -u REPO_DIR \
    REPO_DIR="$KF_REPO" KICKOFF_CORE_DIR="$CLONE" KICKOFF_CORE_REMOTE="$CORE" \
    CLAUDE_CONFIG_DIR="$CFG" KICKOFF_ADOPTERS_REGISTRY="$REG" INGRESS_DIR="$ING" KICKOFF_MODEL_DIR="$MODELS" \
    PATH="$STUB:$PATH" bash "$KICKOFF" "$@"
}
kfl() {  # identical, but through the SYMLINKED front door — exercises the readlink -f "$0" fix
  _kf_env_guard || return 1
  env -u REPO_DIR \
    REPO_DIR="$KF_REPO" KICKOFF_CORE_DIR="$CLONE" KICKOFF_CORE_REMOTE="$CORE" \
    CLAUDE_CONFIG_DIR="$CFG" KICKOFF_ADOPTERS_REGISTRY="$REG" INGRESS_DIR="$ING" KICKOFF_MODEL_DIR="$MODELS" \
    PATH="$STUB:$PATH" bash "$LINK" "$@"
}
kfc() {  # the front door FROM THE PINNED CLONE — the real pull-adopter topology: a pull adopter runs
  # `kickoff preflight`/`up` FROM ~/kickoff-core (the pinned clone), so `$HERE/preflight.sh` IS the
  # pinned preflight and its running-core == KICKOFF_CORE_DIR (preflight #14). Running the SOURCE
  # front door here would run $REPO/scripts/preflight.sh → running-core=$REPO ≠ the pinned clone → #14 FAIL.
  _kf_env_guard || return 1
  env -u REPO_DIR \
    REPO_DIR="$KF_REPO" KICKOFF_CORE_DIR="$CLONE" KICKOFF_CORE_REMOTE="$CORE" \
    CLAUDE_CONFIG_DIR="$CFG" KICKOFF_ADOPTERS_REGISTRY="$REG" INGRESS_DIR="$ING" KICKOFF_MODEL_DIR="$MODELS" \
    PATH="$STUB:$PATH" bash "$CLONE/scripts/kickoff" "$@"
}

# ── build a realistic brownfield fixture at $1 (git init + a CLEAN committed baseline) ────────────
build_brownfield_fixture() {
  local f="$1"
  mkdir -p "$f/.claude/agents" "$f/src" "$f/memory"
  git -C "$f" init -q; git -C "$f" config user.email dev@acme.test; git -C "$f" config user.name dev
  # the operator's OWN CLAUDE.md (adopt must never touch its body — CLAUDE.md authoring is /adopt's job)
  printf '# ACME Widgets\n\nOur house rules. The AI helps with the widget pipeline.\n\n- Never touch billing.\n' > "$f/CLAUDE.md"
  # a HUMAN-WRITTEN, NON-jq-canonical settings.json (3-space indent, keys in operator order) carrying a
  # PRE-EXISTING top-level key (permissions) the engine's merge MUST preserve. A jq round-trip re-indents
  # the whole file, so byte-restore (not re-derivation) is the ONLY clean reversal — the acceptance target.
  cat > "$f/.claude/settings.json" <<'EOF'
{
   "permissions": {
      "allow": ["Bash(npm test:*)", "Read"],
      "deny": ["Bash(rm -rf:*)"]
   },
   "enableAllProjectMcpServers": false
}
EOF
  # settings.local.json — the operator's LIVE secret-bearing config + a memory hook. kickoff must NEVER
  # read/store/alter it. The planted secret is a shell var (never a source literal).
  cat > "$f/.claude/settings.local.json" <<EOF
{
  "telegram": { "botToken": "$PLANT" },
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "\$CLAUDE_PROJECT_DIR/memory/hook.sh" } ] }
    ]
  }
}
EOF
  # the operator's OWN crew + source + memory (all pre-existing, committed — never adopt/eject's to touch)
  cat > "$f/.claude/agents/widget-agent.md" <<'EOF'
---
name: widget-agent
tools: Read, Edit, Bash
---
You own the widget pipeline.
EOF
  cat > "$f/.claude/agents/billing-agent.md" <<'EOF'
---
name: billing-agent
tools: Read
---
You answer billing questions (read-only).
EOF
  printf '#!/usr/bin/env bash\n# the operator OWN memory hook (pre-existing)\necho retrieve\n' > "$f/memory/hook.sh"; chmod +x "$f/memory/hook.sh"
  printf '# memory index\n\n- widgets ship weekly\n' > "$f/memory/MEMORY.md"
  printf 'export function widget(){ return 42 }\n' > "$f/src/index.js"
  printf 'node_modules/\n' > "$f/.gitignore"
  git -C "$f" add -A; git -C "$f" commit -qm "baseline: acme-widgets already using AI" >/dev/null
}

# ── write a coherent instance.env into $1 (§D data layout, ABSOLUTE paths anchored at the repo) ───
# Absolute (not the example's ${REPO_DIR:-$PWD}/… defaults) so the mc shim + preflight + eject resolve
# the SAME repo-internal data paths no matter the invoking cwd. Overwrites adopt's scaffold on purpose.
write_fixture_instance_env() {
  local r="$1"
  cat > "$r/.kickoff/instance.env" <<EOF
export KICKOFF_CORE_DIR="$CLONE"
export KICKOFF_CORE_REMOTE="$CORE"
export TELEGRAM_STATE_DIR="$r/.kickoff/chan"
export MC_STATE_FILE="$r/.kickoff/state/mission-control/mission-state.json"
export MC_TRACKER_FILE="$r/.kickoff/state/TRACKER.md"
export MEMORY_DIR="$r/.kickoff/memory"
export MEMORY_INDEX="$r/.kickoff/memory/MEMORY.md"
export MEMORY_DB="$r/.kickoff/state/memory-retrieval/memory-index.db"
export MEMORY_HOOK_LOG="$r/.kickoff/state/memory-retrieval/retrieval-log.jsonl"
EOF
}

# ══════════════════════════════════════════════════════════════════════════════════════
# SIMULATE the `/adopt` session — the intelligent half a bash CLI can't do. Author the crew +
# CLAUDE.md content + TRACKER + the .kickoff/memory corpus + lefthook gates, and RECORD EVERY touch
# EXACTLY as plugin/skills/adopt/SKILL.md instructs — via the PINNED CORE's adopt-manifest.py (the
# skill uses `$KICKOFF_CORE_DIR/scripts/adopt-manifest.py`). Recording each touch is what makes the
# eject reversal HONEST: an un-recorded skill footprint is invisible to eject.
#   • adopter deliverables (crew, TRACKER, memory corpus, lefthook)  →  created/seeded-instance
#   • an edit to a pre-existing operator file that must byte-restore →  modified/seam --original-from
#     (SKILL.md step 5.2's exact form for a pre-existing root lefthook.yml). The CLAUDE.md content-edit
#     uses this: seeded-instance would be KEPT and leave adopt's block-append to surgical-strip (residue);
#     a SEAM byte-restores, so the layered reversal (reverse-order) unwinds CLAUDE.md to its EXACT original.
# ══════════════════════════════════════════════════════════════════════════════════════
simulate_adopt_session() {
  local repo="$1"
  local AMC="$CLONE/scripts/adopt-manifest.py"   # the pinned core's tool, as the skill invokes it
  local pre; pre="$(mk)"
  mkdir -p "$repo/.claude/agents"

  # (1) crew — specialists /adopt proposes for THIS repo's domains (adopter-owned deliverable)
  cat > "$repo/.claude/agents/pipeline-agent.md" <<'EOF'
---
name: pipeline-agent
tools: Read, Edit, Bash
---
You own the widget build+release pipeline for this repo.
EOF
  python3 "$AMC" record --repo "$repo" --path .claude/agents/pipeline-agent.md --action created --class seeded-instance --source authored-for-repo >/dev/null
  cat > "$repo/.claude/agents/qa-agent.md" <<'EOF'
---
name: qa-agent
tools: Read, Bash
---
You run the test suite and report red/green honestly.
EOF
  python3 "$AMC" record --repo "$repo" --path .claude/agents/qa-agent.md --action created --class seeded-instance --source authored-for-repo >/dev/null

  # (2) TRACKER.md — the single source of truth (adopter-owned deliverable)
  printf '# TRACKER — acme-widgets\n\n## In progress\n- adopt the kickoff coordinator pattern\n' > "$repo/TRACKER.md"
  python3 "$AMC" record --repo "$repo" --path TRACKER.md --action created --class seeded-instance --source authored-for-repo >/dev/null

  # (3) the .kickoff/memory corpus — a durable authored fact (created) + the index update (modified).
  #     The corpus is a TRACKED, team-shareable asset under .kickoff/memory/ (§D); the seed created
  #     MEMORY.md, so authoring into it is a modify of a pre-existing file.
  printf '# widget release cadence\n\nWidgets ship weekly on Thursdays; never hand-edit the release tag.\n' > "$repo/.kickoff/memory/widget-cadence.md"
  python3 "$AMC" record --repo "$repo" --path .kickoff/memory/widget-cadence.md --action created --class seeded-instance --source authored-for-repo >/dev/null
  cp "$repo/.kickoff/memory/MEMORY.md" "$pre/MEMORY.md.pre"
  printf -- '- widget-cadence — ships weekly Thursdays\n' >> "$repo/.kickoff/memory/MEMORY.md"
  python3 "$AMC" record --repo "$repo" --path .kickoff/memory/MEMORY.md --action modified --class seeded-instance --source authored-for-repo --original-from "$pre/MEMORY.md.pre" >/dev/null

  # (4) .kickoff/lefthook-kickoff.yml — `kickoff adopt` now authors + records the GENERIC gate file
  #     mechanically (scout #1/#2); the session only ADDS the stack gates to the EXISTING file, recording
  #     its edit modified/seeded-instance WITH the pre-edit bytes (the record rule for an edit to a
  #     pre-existing adopter file). The layered created+modified pair reverses like CLAUDE.md's: the
  #     modify byte-restores adopt's generic file, then --purge deletes the now-pristine created file —
  #     zero trace. Guard the old-core shape (file absent) for back-compat.
  if [ -f "$repo/.kickoff/lefthook-kickoff.yml" ]; then
    cp "$repo/.kickoff/lefthook-kickoff.yml" "$pre/lefthook-kickoff.yml.pre"
    cat >> "$repo/.kickoff/lefthook-kickoff.yml" <<'YML'
# stack gates added by the /adopt session (detected stack)
pre-merge-commit:
  commands:
    stack-test:
      run: echo stack-test
YML
    python3 "$AMC" record --repo "$repo" --path .kickoff/lefthook-kickoff.yml --action modified --class seeded-instance --source authored-for-repo --original-from "$pre/lefthook-kickoff.yml.pre" >/dev/null
  else
    cat > "$repo/.kickoff/lefthook-kickoff.yml" <<'YML'
pre-commit:
  commands:
    secret-scan:
      run: bash .kickoff/bin/scan-secrets --staged
pre-push:
  commands:
    structure-scan:
      run: bash .kickoff/bin/scan-structure
YML
    python3 "$AMC" record --repo "$repo" --path .kickoff/lefthook-kickoff.yml --action created --class seeded-instance --source authored-for-repo >/dev/null
  fi

  # (5) root lefthook.yml — normally ALREADY wired by `kickoff adopt`; author it only when absent
  #     (the old-core back-compat shape), recorded created/seeded exactly as adopt would.
  if [ ! -f "$repo/lefthook.yml" ]; then
    printf 'extends: [.kickoff/lefthook-kickoff.yml]\n# kickoff\n' > "$repo/lefthook.yml"
    python3 "$AMC" record --repo "$repo" --path lefthook.yml --action created --class seeded-instance --source authored-for-repo >/dev/null
  fi

  # (6) CLAUDE.md content — the repo-specific charter body appended to the operator's CLAUDE.md.
  #     Recorded modified/SEAM (byte-restore-reversible) so eject unwinds it, LAYERED on adopt's
  #     block-append (both seams, both reversed in reverse-record order → the EXACT pre-adopt bytes).
  cp "$repo/CLAUDE.md" "$pre/CLAUDE.md.pre"
  printf '\n## Coordinator notes (authored by /adopt)\n\n- pipeline-agent owns build+release.\n- qa-agent is read+run only.\n' >> "$repo/CLAUDE.md"
  python3 "$AMC" record --repo "$repo" --path CLAUDE.md --action modified --class seam --source "$CORE_TAG" --original-from "$pre/CLAUDE.md.pre" >/dev/null

  # (7) KICKOFF.local.md — the adopter conventions stub gen-charter already recorded created/seeded;
  #     /adopt fills its CONTENT. Editing a pre-existing recorded file → record modified/seeded WITH the
  #     pre-edit original (SKILL.md's record rule). Load-bearing: an UNrecorded edit would diverge from
  #     gen-charter's hash → --purge would (correctly) no-clobber-KEEP it → residue; recording the edit
  #     lets --purge byte-restore to the stub then delete it (kept on a default eject either way).
  if [ -f "$repo/.kickoff/KICKOFF.local.md" ]; then
    cp "$repo/.kickoff/KICKOFF.local.md" "$pre/KICKOFF.local.md.pre"
    printf '\n## This repo\n\n- Ship widgets weekly; never touch billing writes.\n' >> "$repo/.kickoff/KICKOFF.local.md"
    python3 "$AMC" record --repo "$repo" --path .kickoff/KICKOFF.local.md --action modified --class seeded-instance --source authored-for-repo --original-from "$pre/KICKOFF.local.md.pre" >/dev/null
  fi
}

build_core_and_clone

# ══════════════════════════════════════════════════════════════════════════════════════
stage "(1) FIXTURE — a realistic 'already using AI' brownfield repo, CLEAN baseline"
# ══════════════════════════════════════════════════════════════════════════════════════
FIXPARENT="$(mk)"
FIX="$FIXPARENT/acme-widgets"       # the project basename ingress + eject key off
build_brownfield_fixture "$FIX"

PROJECT="$(basename "$FIX")"
SETTINGS="$FIX/.claude/settings.json"
MANIFEST="$FIX/.kickoff/adopt-manifest.json"
# THE acceptance anchors — captured from the PRISTINE baseline, before kickoff touches anything.
ORIG_SETTINGS_SHA="$(sha256sum "$SETTINGS" | awk '{print $1}')"
ORIG_LOCAL_SHA="$(sha256sum "$FIX/.claude/settings.local.json" | awk '{print $1}')"
ORIG_CLAUDE_SHA="$(sha256sum "$FIX/CLAUDE.md" | awk '{print $1}')"
BASELINE_TREE="$(git -C "$FIX" rev-parse HEAD)"

chk "fixture git baseline is CLEAN (a canonical fixture would mask the byte-restore bug)" \
  "[ -z \"\$(git -C \"$FIX\" status --porcelain)\" ]"
chk "settings.json is NON-jq-canonical (3-space indent — a jq round-trip would re-serialize it)" \
  "grep -q '^   \"permissions\"' \"$SETTINGS\""
chk "settings.json carries the operator's PRE-EXISTING top-level 'permissions' key" \
  "jq -e '.permissions.allow | index(\"Read\")' \"$SETTINGS\" >/dev/null"
chk "the planted secret really IS in settings.local.json (proves later grep would catch a leak)" \
  "grep -qF '$PLANT' \"$FIX/.claude/settings.local.json\""

# ══════════════════════════════════════════════════════════════════════════════════════
stage "(2) ADOPT — the REAL \`kickoff adopt\`: additive, .kickoff/ created, seams recorded"
# ══════════════════════════════════════════════════════════════════════════════════════
KF_REPO="$FIX"
ADOPT_OUT="$(kf adopt --dir "$FIX" --accept </dev/null 2>&1)"; ADOPT_RC=$?   # --accept: §4 scripted consent (the fixture tests the wiring, not the gate)
chk "adopt exits 0" "[ $ADOPT_RC -eq 0 ]"
chk ".kickoff/ was created" "[ -d \"$FIX/.kickoff\" ]"
chk ".kickoff/bin/mc seam shim was generated (0755)" \
  "[ -f \"$FIX/.kickoff/bin/mc\" ] && [ \"\$(stat -c '%a' \"$FIX/.kickoff/bin/mc\")\" = 755 ]"
chk ".kickoff/bin/scan-secrets + scan-structure shims were generated (§C)" \
  "[ -f \"$FIX/.kickoff/bin/scan-secrets\" ] && [ -f \"$FIX/.kickoff/bin/scan-structure\" ]"
chk ".kickoff/.gitignore seam was generated (keeps instance-private bits out of origin)" \
  "[ -f \"$FIX/.kickoff/.gitignore\" ] && grep -q '^state/' \"$FIX/.kickoff/.gitignore\""
chk ".kickoff/KICKOFF.md (charter seam) + KICKOFF.local.md (yours) were generated" \
  "[ -f \"$FIX/.kickoff/KICKOFF.md\" ] && [ -f \"$FIX/.kickoff/KICKOFF.local.md\" ]"
chk "the adopt-manifest records the mc shim seam (created/seam)" \
  "python3 -c \"import json;e=[x for x in json.load(open('$MANIFEST'))['entries'] if x['path']=='.kickoff/bin/mc'][0];assert e['action']=='created' and e['class']=='seam'\""
chk "the adopt-manifest records the settings.json seam json-merged WITH the pre-edit original bytes" \
  "python3 -c \"import json;e=[x for x in json.load(open('$MANIFEST'))['entries'] if x['path']=='.claude/settings.json'][0];assert e['action']=='json-merged' and e.get('original')\""
chk "the CLAUDE.md @import block was recorded block-appended (byte-restore-reversible)" \
  "python3 -c \"import json;e=[x for x in json.load(open('$MANIFEST'))['entries'] if x['path']=='CLAUDE.md'][0];assert e['action']=='block-appended' and e['class']=='seam' and e.get('original')\""
chk "the manifest gains the machine plugin row (kickoff@kickoff-local, scope=project)" \
  "python3 -c \"import json;m=[x for x in json.load(open('$MANIFEST'))['machine_entries'] if x['plugin']=='kickoff'][0];assert m['marketplace']=='kickoff-local' and m['scope']=='project'\""
# the settings.json SEAM applied while the pre-existing key is preserved (merge, not clobber)
chk "seam applied: settings.json now carries extraKnownMarketplaces + enabledPlugins[kickoff@kickoff-local]" \
  "jq -e '.extraKnownMarketplaces[\"kickoff-local\"] and .enabledPlugins[\"kickoff@kickoff-local\"]==true' \"$SETTINGS\" >/dev/null"
chk "PRESERVED: the operator's pre-existing 'permissions' key survived the merge" \
  "jq -e '.permissions.allow | index(\"Read\")' \"$SETTINGS\" >/dev/null"
chk "additive: the operator's CLAUDE.md body is byte-UNTOUCHED by adopt (only the block appended)" \
  "grep -q 'Never touch billing' \"$FIX/CLAUDE.md\" && head -1 \"$FIX/CLAUDE.md\" | grep -q '# ACME Widgets'"
chk "additive: settings.local.json (the secret) is byte-UNTOUCHED by adopt" \
  "[ \"\$(sha256sum \"$FIX/.claude/settings.local.json\" | awk '{print \$1}')\" = \"$ORIG_LOCAL_SHA\" ]"
chk "additive: the operator's own crew (.claude/agents) is byte-UNTOUCHED" \
  "git -C \"$FIX\" diff --quiet HEAD -- .claude/agents"
chk "credential-safe: the planted secret is ABSENT from the entire adopt-manifest" \
  "! grep -qF '$PLANT' \"$MANIFEST\""
# brownfield-first-green (G2): adopt DEFAULTS a dedicated per-repo TELEGRAM_STATE_DIR into instance.env
# (telegram-<basename>) so `kickoff up` no longer fail-closes at preflight #2 on the empty/placeholder.
chk "adopt defaulted a dedicated per-repo TELEGRAM_STATE_DIR (telegram-$PROJECT — no more empty/placeholder stumble)" \
  "grep -qE '^export TELEGRAM_STATE_DIR=.*telegram-$PROJECT' \"$FIX/.kickoff/instance.env\""

# coherent instance.env (§D data layout) — overwrites adopt's placeholder scaffold; sets a real channel.
write_fixture_instance_env "$FIX"

# ══════════════════════════════════════════════════════════════════════════════════════
stage "(3) /ADOPT — the SIMULATED intelligent session: author the crew + content, RECORD each touch"
# ══════════════════════════════════════════════════════════════════════════════════════
# This is the half the old e2e STUBBED. Author the skill's real file set + record every touch, so the
# eject reversal below is tested against BOTH the mechanical adopt AND the skill-authored footprint.
simulate_adopt_session "$FIX"
_ENTRY() { python3 -c "import json,sys;e=[x for x in json.load(open('$MANIFEST'))['entries'] if x['path']==sys.argv[1]];print(e[0][sys.argv[2]] if e else 'MISSING')" "$1" "$2" 2>/dev/null; }
chk "/adopt authored the crew — .claude/agents/pipeline-agent.md present" "[ -f \"$FIX/.claude/agents/pipeline-agent.md\" ]"
chk "manifest RECORDS the crew created/seeded-instance (findable+reversible → --purge/--verify real)" \
  "[ \"\$(_ENTRY .claude/agents/pipeline-agent.md action)\" = created ] && [ \"\$(_ENTRY .claude/agents/pipeline-agent.md class)\" = seeded-instance ]"
chk "/adopt authored TRACKER.md + it is RECORDED created/seeded-instance" \
  "[ -f \"$FIX/TRACKER.md\" ] && [ \"\$(_ENTRY TRACKER.md class)\" = seeded-instance ]"
chk "/adopt authored the .kickoff/memory corpus + RECORDED it (created/seeded-instance)" \
  "[ -f \"$FIX/.kickoff/memory/widget-cadence.md\" ] && [ \"\$(_ENTRY .kickoff/memory/widget-cadence.md class)\" = seeded-instance ]"
chk "the MEMORY.md index edit is RECORDED modified/seeded-instance WITH the pre-edit original" \
  "[ \"\$(_ENTRY .kickoff/memory/MEMORY.md action)\" = modified ] && python3 -c \"import json;e=[x for x in json.load(open('$MANIFEST'))['entries'] if x['path']=='.kickoff/memory/MEMORY.md'][0];assert e.get('original')\""
chk "the gate file .kickoff/lefthook-kickoff.yml exists (kickoff adopt authored it) + RECORDED created/seeded-instance" \
  "[ -f \"$FIX/.kickoff/lefthook-kickoff.yml\" ] && [ \"\$(_ENTRY .kickoff/lefthook-kickoff.yml class)\" = seeded-instance ]"
chk "the /adopt session ADDED its stack gate to the EXISTING gate file + RECORDED the edit modified/seeded-instance (layered, byte-restorable)" \
  "grep -q 'stack-test' \"$FIX/.kickoff/lefthook-kickoff.yml\" && python3 -c \"import json;es=[e for e in json.load(open('$MANIFEST'))['entries'] if e['path']=='.kickoff/lefthook-kickoff.yml'];assert any(e['action']=='created' for e in es);assert any(e['action']=='modified' and e.get('original') for e in es)\""
chk "root lefthook.yml wired (extends the kickoff gate) + RECORDED created/seeded-instance" \
  "[ -f \"$FIX/lefthook.yml\" ] && grep -q 'extends' \"$FIX/lefthook.yml\" && [ \"\$(_ENTRY lefthook.yml class)\" = seeded-instance ]"
chk "/adopt added CLAUDE.md content + RECORDED it modified/SEAM (byte-restore, LAYERED on adopt's block)" \
  "grep -q 'Coordinator notes' \"$FIX/CLAUDE.md\" && python3 -c \"import json;es=[x for x in json.load(open('$MANIFEST'))['entries'] if x['path']=='CLAUDE.md'];assert any(e['action']=='modified' and e['class']=='seam' and e.get('original') for e in es), 'no modified/seam CLAUDE.md entry';assert any(e['action']=='block-appended' for e in es), 'no block-appended CLAUDE.md entry'\""
chk "credential-safe: the planted secret is STILL absent from the manifest after /adopt records" \
  "! grep -qF '$PLANT' \"$MANIFEST\""

# ══════════════════════════════════════════════════════════════════════════════════════
stage "(4) RUN — the REAL \`kickoff preflight\` reaches GREEN; the mc shim dispatches; state ACCUMULATES"
# ══════════════════════════════════════════════════════════════════════════════════════
KF_REPO="$FIX"
PF_OUT="$(kfc preflight 2>&1)"; PF_RC=$?   # from the PINNED CLONE (the real pull-adopter topology)
chk "kickoff preflight exits 0 — the adopted instance is runnable (all HARD checks green)" "[ $PF_RC -eq 0 ]"
chk "preflight verified the adopt-manifest seam integrity (#8)" \
  "printf '%s' \"\$PF_OUT\" | grep -q 'seam integrity verified'"
chk "preflight enforced pull-adopter data-path isolation (MC_STATE_FILE resolves inside the repo)" \
  "printf '%s' \"\$PF_OUT\" | grep -q 'MC_STATE_FILE resolves inside the repo'"
chk "preflight: the one expected supervisor-lock state — no competing supervisor" \
  "printf '%s' \"\$PF_OUT\" | grep -q 'no supervisor lock present'"
# the mc seam shim RESOLVES the pinned engine (KICKOFF_CORE_DIR from instance.env) + dispatches. Then
# ACCUMULATE real state (a headline + an activity log) so eject's data relocation has something to move.
# .kickoff/state/ is gitignored (via .kickoff/.gitignore) so this never dirties porcelain — only relocation.
SHIM_OUT="$("$FIX/.kickoff/bin/mc" show 2>&1)"; SHIM_RC=$?
chk "the mc shim resolves the pinned engine + dispatches (\`mc show\` prints board JSON, rc0)" \
  "[ $SHIM_RC -eq 0 ] && printf '%s' \"\$SHIM_OUT\" | grep -q '{'"
chk "the mc shim did NOT hit the 'engine not present' path (the pinned clone resolved)" \
  "! printf '%s' \"\$SHIM_OUT\" | grep -q 'engine not present'"
"$FIX/.kickoff/bin/mc" set headline "widget adoption underway" >/dev/null 2>&1
"$FIX/.kickoff/bin/mc" log dev "authored the crew + tracker" >/dev/null 2>&1
printf '# session note\n\nadopted on 2026-07-08.\n' > "$FIX/.kickoff/memory/session-note.md"   # an accumulated memory (instance data)
chk "instance state ACCUMULATED: the board headline was set (mc mutated MC_STATE_FILE)" \
  "grep -q 'widget adoption underway' \"$FIX/.kickoff/state/mission-control/mission-state.json\""

# ══════════════════════════════════════════════════════════════════════════════════════
stage "(5) SERVE — the REAL ingress.sh over a SCRATCH INGRESS_DIR + scratch port + fixture upstream"
# ══════════════════════════════════════════════════════════════════════════════════════
STATICROOT="$(mk)"; printf 'ok\n' > "$STATICROOT/index.html"
python3 -m http.server "$UP_PORT" --bind 127.0.0.1 --directory "$STATICROOT" >/dev/null 2>&1 &
UPSTREAM_PID=$!
for _ in $(seq 1 30); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$UP_PORT/" && break; sleep 0.2; done
cat > "$ING/registry.json" <<EOF
{ "funnel_port": 443, "listen": $LISTEN, "public_base": "https://scratch.ts.net",
  "projects": { "$PROJECT": { "apps": {
    "api": { "type": "proxy",  "target": "127.0.0.1:$UP_PORT", "strip_prefix": true },
    "web": { "type": "static", "target": "$STATICROOT",        "strip_prefix": true } } } } }
EOF
GEN_OUT="$(INGRESS_DIR="$ING" bash "$INGRESS_SH" gen 2>&1)"; GEN_RC=$?
chk "ingress gen exits 0 (Caddyfile generated from the scratch registry)" "[ $GEN_RC -eq 0 ]"
chk "SERVE binds LOOPBACK 127.0.0.1:$LISTEN (never a wildcard/LAN-reachable bind)" \
  "grep -q '127.0.0.1:$LISTEN' \"$ING/Caddyfile\""
chk "the fixture project's route /$PROJECT/api is present in the Caddyfile" \
  "grep -q '/$PROJECT/api' \"$ING/Caddyfile\""
HEALTH_OUT="$(INGRESS_DIR="$ING" bash "$INGRESS_SH" health 2>&1)"; HEALTH_RC=$?
chk "ingress health is GREEN (proxy upstream answering + static root exists)" "[ $HEALTH_RC -eq 0 ]"

# ══════════════════════════════════════════════════════════════════════════════════════
stage "(6) UPGRADE — the REAL \`kickoff pull\` re-pins the core; the operator-owned layer stays BYTE-IDENTICAL"
# ══════════════════════════════════════════════════════════════════════════════════════
snap_owned() {   # sha256 the operator-OWNED tracked layer (incl. the /adopt CLAUDE.md content) into $1
  { git -C "$FIX" ls-files -- CLAUDE.md .claude/agents .claude/settings.local.json src memory .gitignore \
      | while IFS= read -r f; do sha256sum "$FIX/$f"; done; } | sort > "$1"
}
OWNED_BEFORE="$(mk)/owned.before"; OWNED_AFTER="$(mk)/owned.after"
snap_owned "$OWNED_BEFORE"
KF_REPO="$FIX"
PULL_OUT="$(kf pull "$CORE_TAG" 2>&1)"; PULL_RC=$?
snap_owned "$OWNED_AFTER"
chk "pull wrote .kickoff/core.lock (a format-2 whole-tree lock at the tag)" \
  "[ -f \"$FIX/.kickoff/core.lock\" ] && grep -q '^format 2' \"$FIX/.kickoff/core.lock\""
chk "pull pinned the requested tag ($CORE_TAG)" \
  "grep -q '^tag $CORE_TAG' \"$FIX/.kickoff/core.lock\""
chk "INVARIANT: the operator-owned layer (incl. /adopt's CLAUDE.md content) is BYTE-IDENTICAL across the pull" \
  "cmp -s \"$OWNED_BEFORE\" \"$OWNED_AFTER\""
chk "pull re-ran preflight against the freshly-pinned core and it PASSED (rc0)" "[ $PULL_RC -eq 0 ]"
chk "pull verified the whole-tree core pin (#6 green — core.lock holds)" \
  "printf '%s' \"\$PULL_OUT\" | grep -q 'core.lock verified'"

# ══════════════════════════════════════════════════════════════════════════════════════
stage "(6b) VERIFY — \`kickoff verify\` GREEN on the adopted repo; a tampered core.lock → NON-ZERO"
# ══════════════════════════════════════════════════════════════════════════════════════
# The brownfield "it worked" proof (goal G2): a one-shot health check that RETURNS a verdict (green/red) —
# the counterpart to greenfield's passing test. It asserts the seams adopt+/adopt wired are coherent + the
# deps are present, needs NO Telegram, and the TAMPER case is the counter-proof that its rc0 means something.
# It is READ-ONLY w.r.t. the fixture (the render-tracker probe writes only to a throwaway temp file), so it
# leaves stage 7's eject invariants untouched; the tamper is snapshot→corrupt→restore byte-for-byte.
KF_REPO="$FIX"
VERIFY_OUT="$(kf verify 2>&1)"; VERIFY_RC=$?
chk "kickoff verify exits 0 — the adopted instance is HEALTHY (seams coherent, deps present)" "[ $VERIFY_RC -eq 0 ]"
chk "verify checked the core.lock seam COHERENT (the format-2 whole-tree pin holds)" \
  "printf '%s' \"\$VERIFY_OUT\" | grep -q 'core.lock COHERENT'"
chk "verify confirmed ALL 3 engine shims present (mc + scan-secrets + scan-structure)" \
  "printf '%s' \"\$VERIFY_OUT\" | grep -q 'bin/mc shim present' && printf '%s' \"\$VERIFY_OUT\" | grep -q 'bin/scan-secrets shim present' && printf '%s' \"\$VERIFY_OUT\" | grep -q 'bin/scan-structure shim present'"
chk "verify ROUND-TRIPPED the mc render-tracker seam (the shim resolved the pinned engine + rendered)" \
  "printf '%s' \"\$VERIFY_OUT\" | grep -q 'render-tracker ROUND-TRIPS'"
chk "verify saw the lefthook gate WIRED (/adopt authored root lefthook.yml extends the kickoff gate)" \
  "printf '%s' \"\$VERIFY_OUT\" | grep -q 'lefthook gate WIRED'"
chk "verify confirmed the plugin ENABLED (kickoff@kickoff-local in .claude/settings.json)" \
  "printf '%s' \"\$VERIFY_OUT\" | grep -q 'plugin ENABLED'"
chk "verify reported the dependency set (git/jq/python3 present)" \
  "printf '%s' \"\$VERIFY_OUT\" | grep -q 'git present' && printf '%s' \"\$VERIFY_OUT\" | grep -q 'python3 present'"
chk "verify needed NO Telegram channel (it never gated on TELEGRAM_STATE_DIR)" \
  "! printf '%s' \"\$VERIFY_OUT\" | grep -qi 'TELEGRAM_STATE_DIR'"
# TAMPER — corrupt core.lock's pinned commit → verify MUST exit non-zero, then RESTORE byte-identical for eject.
VLOCK="$FIX/.kickoff/core.lock"
VLOCK_SNAP="$(mk)/core.lock.snap"; cp "$VLOCK" "$VLOCK_SNAP"
python3 - "$VLOCK" <<'PYEOF'
import sys, re
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(re.sub(r'(?m)^commit .*$', 'commit deadbeefdeadbeefdeadbeefdeadbeefdeadbeef', s))
PYEOF
VERIFY_TAMPER_OUT="$(kf verify 2>&1)"; VERIFY_TAMPER_RC=$?
chk "TAMPER: a corrupted core.lock makes verify exit NON-ZERO (the counter-proof that rc0 MEANS something)" \
  "[ $VERIFY_TAMPER_RC -ne 0 ]"
chk "TAMPER: verify NAMES the incoherent core.lock pin (not a silent pass)" \
  "printf '%s' \"\$VERIFY_TAMPER_OUT\" | grep -q 'core.lock INCOHERENT'"
cp "$VLOCK_SNAP" "$VLOCK"   # byte-restore so stage 7 eject's byte-for-byte invariants are untouched
VERIFY_RESTORE_RC=0; kf verify >/dev/null 2>&1 || VERIFY_RESTORE_RC=$?
chk "TAMPER restored: verify is GREEN again after byte-restoring core.lock (fixture left pristine for eject)" \
  "[ $VERIFY_RESTORE_RC -eq 0 ]"

# ══════════════════════════════════════════════════════════════════════════════════════
stage "(6c) UPGRADE-HOP — THE G1 ACCEPTANCE: one \`kickoff pull\` leaves the RUNNING worker on the new engine"
# ══════════════════════════════════════════════════════════════════════════════════════
# v0.7 G1 slice 6 (design §4 journey-e2e row): an adopter fixture pinned to fixture-tag N runs a
# REAL v0.7 supervisor whose default START_CMD spawns ITS OWN engine's REAL session-run.sh, whose
# `exec claude` resolves to a hermetic worker-stub `claude` on PATH (records argv/env, then sleeps —
# NEVER a real claude). One REAL `kickoff pull core-vJ2` — run from inside the fixture via the
# pinned engine's own front door, exactly the production flow — must leave the worker fully on the
# new engine: the supervisor HOPS (same PID, engine N+1's supervisor.sh executing), the stub session
# is respawned from the N+1 engine dir, PERMISSION_MODE rides the exec unchanged, and instance.env's
# MODEL/EFFORT are intact and RE-RESOLVED (the launch env carries deliberately-DIFFERENT fossil
# values, so a fossil surviving the hop is detectable). REAL gates end-to-end — the engines carry
# the real preflight.sh and the supervisor runs its full fail-closed gate at launch, at the hop
# boundary, and at the post-exec startup ([[fixture-can-mask-the-bug-it-should-catch]]: no stub
# preflights anywhere on this lane).
#
# A SIBLING adopter registered at tag N forces the pull onto the parked-worktree path (the real
# multi-org topology — multiple adopter orgs share one box), so engine N+1 lands at a genuinely
# DIFFERENT dir ($KICKOFF_VERSIONS_DIR/core-vJ2) and "respawned from the N+1 engine dir" is
# unambiguous. NOTE the refresh-flag proof is structural: MAX_SESSION_SECONDS=0 + an immortal stub
# session means the ONLY path to a session boundary (where the hop fires) is the flag the pull
# touches — a hop landing at all PROVES the flag was touched and consumed.

build_upgrade_origin() {   # $1 = dir, $2 = green|red — a core origin with tags core-vJ1 (N) + core-vJ2 (N+1)
  local o="$1" mode="$2" rel
  while IFS= read -r rel; do
    rel="${rel%$'\r'}"; [ -z "$rel" ] && continue
    case "$rel" in \#*) continue ;; esac
    [ -e "$REPO/$rel" ] || continue
    mkdir -p "$o/$(dirname "$rel")"
    cp -a "$REPO/$rel" "$o/$rel"
  done < "$MANIFEST_SRC"
  [ -f "$o/CORE-CHANGELOG.md" ] || printf '# CORE-CHANGELOG\n' > "$o/CORE-CHANGELOG.md"
  if [ "$mode" = red ]; then
    # RED-first fixture: engine N's supervisor.sh is the REAL core-v0.6 one (no hop unit) —
    # extracted READ-ONLY via `git show` (never a checkout, never a tag/branch mutation).
    git -C "$REPO" show core-v0.6:scripts/supervisor.sh > "$o/scripts/supervisor.sh"
  fi
  git -C "$o" init -q; git -C "$o" config user.email e@e.e; git -C "$o" config user.name e
  git -C "$o" add -A; git -C "$o" commit -qm "engine N" >/dev/null; git -C "$o" tag core-vJ1
  if [ "$mode" = red ]; then
    cp -a "$REPO/scripts/supervisor.sh" "$o/scripts/supervisor.sh"   # N+1 is the full v0.7 engine again
  fi
  printf 'engine N+1 marker\n' > "$o/ENGINE-J2-MARKER"
  printf '\n## core-vJ2 — 2026-07-13\n\nthe upgrade-lane target tag.\n' >> "$o/CORE-CHANGELOG.md"
  git -C "$o" add -A; git -C "$o" commit -qm "engine N+1" >/dev/null; git -C "$o" tag core-vJ2
  git -C "$o" commit --allow-empty -qm post >/dev/null
}

build_upgrade_adopter() {   # $1 = repo, $2 = engine dir, $3 = origin, $4 = engine-N commit
  mkdir -p "$1/.kickoff/memory" "$1/.kickoff/tg"
  {
    printf 'export KICKOFF_CORE_DIR="%s"\n' "$2"
    printf 'export KICKOFF_CORE_REMOTE="%s"\n' "$3"
    printf 'export TELEGRAM_STATE_DIR="%s/.kickoff/tg"\n' "$1"
    printf 'export MC_STATE_FILE="%s/.kickoff/state/mission-state.json"\n' "$1"
    printf 'export MEMORY_DB="%s/.kickoff/memory/index.db"\n' "$1"
    printf 'export MEMORY_HOOK_LOG="%s/.kickoff/memory/hook.log"\n' "$1"
    printf 'export MODEL="stub-sonnet"\n'      # the durable per-adopter pair the hop must re-resolve
    printf 'export EFFORT="xhigh"\n'
  } > "$1/.kickoff/instance.env"
  printf 'format 2\ntag core-vJ1\ncommit %s\n' "$4" > "$1/.kickoff/core.lock"
  printf '{"entries": [], "machine_entries": []}\n' > "$1/.kickoff/adopt-manifest.json"
  printf '# memory index stub\n' > "$1/.kickoff/memory/MEMORY.md"
}

write_worker_stub_claude() {   # $1 = dir — records every spawn (argv/env/cwd), then sleeps (never a real claude)
  cat > "$1/claude" <<'EOF'
#!/usr/bin/env bash
d="${CLAUDE_PROBE_DIR:?stub-claude(worker): CLAUDE_PROBE_DIR unset — refusing (test isolation guard)}"
n=1; while [ -e "$d/argv.$n" ]; do n=$((n+1)); done
printf '%s\n' "$*" > "$d/argv.$n"
env > "$d/env.$n" 2>/dev/null || true
pwd > "$d/cwd.$n" 2>/dev/null || true
exec sleep 600
EOF
  chmod +x "$1/claude"
}

run_upgrade_fixture() {   # $1 = green|red — spins the fixture + supervisor, runs THE pull, gathers evidence
  local mode="$1" i
  UJ_ORIGIN="$(mk)"; UJ_ENG="$(mk)/engine-n"; UJ_FIX="$(mk)/adopter"; UJ_VERS="$(mk)"
  UJ_PROBE="$(mk)"; UJ_STUBDIR="$(mk)"; UJ_REG="$(mk)/adopters.json"
  UJ_CFG="$(mk)"; UJ_MODELS="$(mk)"; UJ_LOG="$UJ_PROBE/supervisor.log"
  UJ_TMP="$(mk)"   # the swept fixture-temp root — pinned as the supervisor's TMPDIR (see the spawn below)
  build_upgrade_origin "$UJ_ORIGIN" "$mode"
  git clone -q "$UJ_ORIGIN" "$UJ_ENG"; git -C "$UJ_ENG" checkout -q --detach core-vJ1
  UJ_CN="$(git -C "$UJ_ENG" rev-parse HEAD)"
  mkdir -p "$UJ_FIX"
  build_upgrade_adopter "$UJ_FIX" "$UJ_ENG" "$UJ_ORIGIN" "$UJ_CN"
  write_worker_stub_claude "$UJ_STUBDIR"
  # the sibling row (pinned at N) that routes the pull onto the parked-worktree path
  local dummy; dummy="$(mk)/sibling"; mkdir -p "$dummy"
  python3 "$UJ_ENG/scripts/adopt-manifest.py" adopters-register --repo "$dummy" --tag core-vJ1 \
    --version-dir "$UJ_ENG" --registry "$UJ_REG" >/dev/null 2>&1
  # the REAL supervisor from engine N — default START_CMD (its own session-run.sh → the stub
  # `claude` on PATH), REAL full-scope preflight, env -i scrubbed. MODEL/EFFORT here are the
  # deliberate FOSSILS (≠ instance.env's stub-sonnet/xhigh): pre-hop they win (preset-wins,
  # the production launch shape); post-hop the exec DROPS them, so a fossil surviving = RED.
  # TMPDIR="$UJ_TMP" pins the fixture supervisor's (and its session-run grandchildren's) temp trees —
  # the stub-claude pty/session scratch — INSIDE a swept mktemp dir, so cleanup's `rm -rf` reaps them.
  # Without it, env -i scrubs TMPDIR → grandchildren default to /tmp/tmp.* and leak OUTSIDE the fixture
  # tree even on a clean teardown (name-indistinguishable from another org's fixtures → uncleanable).
  env -i PATH="$UJ_STUBDIR:$PATH" HOME="$HOME" TERM=dumb TMPDIR="$UJ_TMP" \
    REPO_DIR="$UJ_FIX" KICKOFF_CORE_DIR="$UJ_ENG" \
    POLL_SECONDS=1 RESTART_BACKOFF_SECONDS=1 BRIDGE_LIVENESS=0 BRIDGE_BOOT_GRACE_SECONDS=600 \
    MAX_SESSION_SECONDS=0 PERMISSION_MODE=auto MODEL=fossil-model EFFORT=max \
    CLAUDE_PROBE_DIR="$UJ_PROBE" \
    bash "$UJ_ENG/scripts/supervisor.sh" > "$UJ_LOG" 2>&1 &
  UJ_SUP=$!
  printf '%s\n' "$UJ_SUP" >> "$JRNY_PIDS"
  # bounded: our pid holds the lock AND the stub session's first spawn probe landed
  i=0
  while [ $i -lt 60 ]; do
    [ "$(cat "$UJ_FIX/.kickoff/supervisor.lock" 2>/dev/null)" = "$UJ_SUP" ] && [ -f "$UJ_PROBE/argv.1" ] && break
    kill -0 "$UJ_SUP" 2>/dev/null || break
    i=$((i+1)); sleep 0.5
  done
  UJ_UP=0
  [ "$(cat "$UJ_FIX/.kickoff/supervisor.lock" 2>/dev/null)" = "$UJ_SUP" ] && [ -f "$UJ_PROBE/argv.1" ] && UJ_UP=1
  # capture the LAUNCH env (pre-hop) so the TMPDIR pin can be asserted on the real process — the
  # grandchildren inherit it, so their temp trees land under the swept $UJ_TMP, never a leaked /tmp.*.
  UJ_SUP_LAUNCH_ENV="$(tr '\0' '\n' < "/proc/$UJ_SUP/environ" 2>/dev/null || true)"
  UJ_SESS1="$(cat "$UJ_FIX/.kickoff/supervisor.session.pid" 2>/dev/null || true)"
  case "$UJ_SESS1" in ''|*[!0-9]*) UJ_SESS1="" ;; *) printf '%s\n' "$UJ_SESS1" >> "$JRNY_PIDS" ;; esac
  UJ_SESS1_CMD=""
  [ -n "$UJ_SESS1" ] && UJ_SESS1_CMD="$(tr '\0' ' ' < "/proc/$UJ_SESS1/cmdline" 2>/dev/null || true)"
  # THE ONE COMMAND — the real pull, from inside the fixture, via the pinned engine's front door
  UJ_PULL_RC=0
  UJ_PULL_OUT="$(cd "$UJ_FIX" && env -u REPO_DIR REPO_DIR="$UJ_FIX" \
      KICKOFF_ADOPTERS_REGISTRY="$UJ_REG" KICKOFF_VERSIONS_DIR="$UJ_VERS" \
      CLAUDE_CONFIG_DIR="$UJ_CFG" KICKOFF_MODEL_DIR="$UJ_MODELS" \
      PATH="$UJ_STUBDIR:$PATH" timeout 120 bash "$UJ_ENG/scripts/kickoff" pull core-vJ2 2>&1)" || UJ_PULL_RC=$?
  UJ_NEWENG="$UJ_VERS/core-vJ2"
  # bounded watch for the hop (green expects it; red must NOT see it — anchored on the
  # POSITIVE respawn event argv.2 + a short post-respawn grace, never a blind sleep)
  UJ_HOPPED=0; i=0
  local grace=-1
  while [ $i -lt 60 ]; do
    if tr '\0' ' ' < "/proc/$UJ_SUP/cmdline" 2>/dev/null | grep -qF "$UJ_NEWENG/scripts/supervisor.sh"; then
      UJ_HOPPED=1; break
    fi
    kill -0 "$UJ_SUP" 2>/dev/null || break
    if [ "$mode" = red ] && [ -f "$UJ_PROBE/argv.2" ]; then
      [ "$grace" -lt 0 ] && grace=$i
      [ $((i - grace)) -ge 6 ] && break        # respawn seen + 6 ticks of grace → verdict: no hop
    fi
    i=$((i+1)); sleep 0.5
  done
  # bounded: the post-boundary session spawn probe (green: post-hop; red: the v0.6 plain refresh)
  i=0
  while [ $i -lt 40 ]; do
    [ -f "$UJ_PROBE/argv.2" ] && break
    kill -0 "$UJ_SUP" 2>/dev/null || break
    i=$((i+1)); sleep 0.5
  done
  UJ_SESS2="$(cat "$UJ_FIX/.kickoff/supervisor.session.pid" 2>/dev/null || true)"
  case "$UJ_SESS2" in ''|*[!0-9]*) UJ_SESS2="" ;; *) printf '%s\n' "$UJ_SESS2" >> "$JRNY_PIDS" ;; esac
  UJ_SESS2_CMD=""
  [ -n "$UJ_SESS2" ] && UJ_SESS2_CMD="$(tr '\0' ' ' < "/proc/$UJ_SESS2/cmdline" 2>/dev/null || true)"
  UJ_SUP_ENV="$(tr '\0' '\n' < "/proc/$UJ_SUP/environ" 2>/dev/null || true)"
  UJ_LOCK_AFTER="$(cat "$UJ_FIX/.kickoff/supervisor.lock" 2>/dev/null || true)"
}

teardown_upgrade_fixture() {   # TERM the exact fixture supervisor; its trap reaps its session group
  [ -n "${UJ_SUP:-}" ] || return 0
  kill -TERM "$UJ_SUP" 2>/dev/null || true
  local i=0
  while [ $i -lt 20 ]; do kill -0 "$UJ_SUP" 2>/dev/null || break; i=$((i+1)); sleep 0.5; done
}

run_upgrade_fixture green
chk "fixture worker up on engine N: REAL supervisor holds the lock + REAL preflight PASSED at launch" \
  "[ $UJ_UP -eq 1 ] && grep -q 'preflight PASSED' \"$UJ_LOG\""
chk "hygiene: the fixture supervisor's TMPDIR was pinned into the swept fixture root (grandchild temp trees can't leak to /tmp)" \
  "printf '%s\n' \"\$UJ_SUP_LAUNCH_ENV\" | grep -qF 'TMPDIR=$UJ_TMP'"
chk "pre-hop stub session runs FROM engine N (session leader cmdline names its session-run.sh)" \
  "printf '%s' \"\$UJ_SESS1_CMD\" | grep -qF \"$UJ_ENG/scripts/session-run.sh\""
chk "pre-hop argv: launch-env presets win (--model fossil-model, --effort max) + --permission-mode auto" \
  "grep -q -- '--model fossil-model' \"$UJ_PROBE/argv.1\" && grep -q -- '--effort max' \"$UJ_PROBE/argv.1\" && grep -q -- '--permission-mode auto' \"$UJ_PROBE/argv.1\""
chk "THE pull exits 0 with the anchored 'PULL OK' verdict" \
  "[ $UJ_PULL_RC -eq 0 ] && printf '%s' \"\$UJ_PULL_OUT\" | grep -Eq '^\[kickoff [^]]*\] PULL OK'"
chk "the pull's honest bottom line: 'worker is hopping to core-vJ2 now' (live worker detected)" \
  "printf '%s' \"\$UJ_PULL_OUT\" | grep -q 'worker is hopping to core-vJ2 now'"
chk "the pull parked engine N+1 + persisted KICKOFF_CORE_DIR (instance.env names the worktree)" \
  "grep -qF \"KICKOFF_CORE_DIR=\\\"$UJ_NEWENG\\\"\" \"$UJ_FIX/.kickoff/instance.env\""
chk "instance.env MODEL/EFFORT lines byte-INTACT across the pull (the surgical persist)" \
  "grep -q '^export MODEL=\"stub-sonnet\"$' \"$UJ_FIX/.kickoff/instance.env\" && grep -q '^export EFFORT=\"xhigh\"$' \"$UJ_FIX/.kickoff/instance.env\""
chk "THE HOP: the SAME pid now executes engine N+1's supervisor.sh (flag touched → boundary → exec; no cadence + an immortal session means the flag is the ONLY boundary path)" \
  "[ $UJ_HOPPED -eq 1 ]"
chk "supervisor.lock pid UNCHANGED across the hop (exec semantics — no stop/start window)" \
  "[ \"$UJ_LOCK_AFTER\" = \"$UJ_SUP\" ]"
chk "the hop VERIFIED first: 'engine-hop: verified GREEN' + the REAL full gate PASSED on BOTH starts" \
  "[ \"\$(grep -c 'engine-hop: verified GREEN' \"$UJ_LOG\")\" = 1 ] && [ \"\$(grep -c 'preflight PASSED' \"$UJ_LOG\")\" = 2 ]"
chk "ACCEPTANCE: the stub session RESPAWNED FROM THE N+1 ENGINE DIR (leader cmdline names its session-run.sh)" \
  "printf '%s' \"\$UJ_SESS2_CMD\" | grep -qF \"$UJ_NEWENG/scripts/session-run.sh\""
chk "ACCEPTANCE: PERMISSION_MODE=auto UNCHANGED through the hop (kernel-held grant → session argv)" \
  "printf '%s\n' \"\$UJ_SUP_ENV\" | grep -q '^PERMISSION_MODE=auto$' && grep -q -- '--permission-mode auto' \"$UJ_PROBE/argv.2\""
chk "ACCEPTANCE: MODEL/EFFORT RE-RESOLVED from instance.env, not fossil env (--model stub-sonnet, --effort xhigh)" \
  "grep -q -- '--model stub-sonnet' \"$UJ_PROBE/argv.2\" && grep -q -- '--effort xhigh' \"$UJ_PROBE/argv.2\""
chk "the fossil MODEL/EFFORT were DROPPED from the live supervisor env at the exec" \
  "! printf '%s\n' \"\$UJ_SUP_ENV\" | grep -q '^MODEL=' && ! printf '%s\n' \"\$UJ_SUP_ENV\" | grep -q '^EFFORT='"
teardown_upgrade_fixture
chk "fixture supervisor torn down clean (exact pid, TERM only)" \
  "! kill -0 $UJ_SUP 2>/dev/null"

# ══════════════════════════════════════════════════════════════════════════════════════
stage "(6d) UPGRADE-HOP RED-FIRST — a core-v0.6 supervisor (no hop unit) provably NEVER hops"
# ══════════════════════════════════════════════════════════════════════════════════════
# The honest asterisk design §3 names: a v0.6 adopter's RUNNING supervisor has no hop-watch, so
# the auto-cycle can't fire on the v0.6→v0.7 hop (that one is manual: the adopter one-taps).
# Same lane, but engine N's supervisor.sh is the REAL core-v0.6 one (git show, read-only): the
# pull still lands green and touches the flag, the v0.6 supervisor consumes it as a PLAIN refresh
# — and the session respawns from the OLD engine, no hop ever fires. This is the lane's RED-first
# proof: run against a non-hopping supervisor, the (6c) hop assertions genuinely FAIL — so the
# lane detects exactly the rot class it exists to kill.
run_upgrade_fixture red
chk "RED fixture is honest: engine N's supervisor.sh is BYTE-IDENTICAL to core-v0.6's (git show)" \
  "git -C \"$REPO\" show core-v0.6:scripts/supervisor.sh | cmp -s - \"$UJ_ENG/scripts/supervisor.sh\""
chk "RED: the v0.6 supervisor came up + ran its stub session from engine N" \
  "[ $UJ_UP -eq 1 ] && printf '%s' \"\$UJ_SESS1_CMD\" | grep -qF \"$UJ_ENG/scripts/session-run.sh\""
chk "RED: the cross-version pull itself still lands green (PULL OK — the pin advanced)" \
  "[ $UJ_PULL_RC -eq 0 ] && printf '%s' \"\$UJ_PULL_OUT\" | grep -Eq '^\[kickoff [^]]*\] PULL OK'"
chk "RED: the flag WAS consumed — the v0.6 supervisor refreshed (a second stub session spawned)" \
  "[ -f \"$UJ_PROBE/argv.2\" ]"
chk "RED-FIRST PROVEN: NO hop ever fires — the SAME pid still executes the OLD (v0.6) supervisor.sh" \
  "[ $UJ_HOPPED -eq 0 ] && tr '\0' ' ' < \"/proc/$UJ_SUP/cmdline\" | grep -qF \"$UJ_ENG/scripts/supervisor.sh\""
chk "RED-FIRST PROVEN: the respawned session still runs OLD-engine code (the exact rot the hop kills)" \
  "printf '%s' \"\$UJ_SESS2_CMD\" | grep -qF \"$UJ_ENG/scripts/session-run.sh\" && ! grep -q 'engine-hop' \"$UJ_LOG\""
teardown_upgrade_fixture
chk "RED fixture supervisor torn down clean (exact pid, TERM only)" \
  "! kill -0 $UJ_SUP 2>/dev/null"

# ══════════════════════════════════════════════════════════════════════════════════════
stage "(7) EJECT (default keep, --verify) — byte-restore + SKILL-AUTHORED deliverables SURVIVE"
# ══════════════════════════════════════════════════════════════════════════════════════
# The acceptance test for the WHOLE journey: eject reverses adopt+pull+/adopt. settings.json + CLAUDE.md
# byte-restore to their EXACT non-canonical originals (sha256) EVEN THOUGH the machine unwiring's stub
# `claude uninstall` re-serializes settings.json AND CLAUDE.md carries TWO layered seams (adopt's block +
# /adopt's content). The recorded seeded-instance deliverables SURVIVE (crew/TRACKER kept in place;
# KICKOFF.local.md + the memory corpus relocated to kickoff-data/). No TRACKED-file drift vs the pristine
# baseline; every untracked leftover is an allowlisted kept deliverable → --verify: no trace.
KF_REPO="$FIX"
EJECT_OUT="$(kf eject --dir "$FIX" --verify --archive-dir "$ARCHIVE_DIR" 2>&1)"; EJECT_RC=$?
NOW_SETTINGS_SHA="$(sha256sum "$SETTINGS" 2>/dev/null | awk '{print $1}')"
NOW_LOCAL_SHA="$(sha256sum "$FIX/.claude/settings.local.json" 2>/dev/null | awk '{print $1}')"
NOW_CLAUDE_SHA="$(sha256sum "$FIX/CLAUDE.md" 2>/dev/null | awk '{print $1}')"
TRACKED_DRIFT="$(git -C "$FIX" status --porcelain -uno)"   # tracked-file changes ONLY (no untracked)

chk "eject --verify exits 0 (no residue, no byte-drift; kept deliverables allowlisted)" "[ $EJECT_RC -eq 0 ]"
chk "ACCEPTANCE: settings.json byte-restored to its EXACT original bytes (sha256 match)" \
  "[ \"$NOW_SETTINGS_SHA\" = \"$ORIG_SETTINGS_SHA\" ]"
chk "settings.json is once again NON-jq-canonical (3-space indent — a true byte-restore, not a re-serialize)" \
  "grep -q '^   \"permissions\"' \"$SETTINGS\""
chk "ACCEPTANCE: CLAUDE.md byte-restored to its EXACT original (sha256) — block + /adopt content GONE" \
  "[ \"$NOW_CLAUDE_SHA\" = \"$ORIG_CLAUDE_SHA\" ]"
chk "CLAUDE.md carries NEITHER the kickoff block NOR the /adopt content after eject" \
  "! grep -q 'kickoff:begin' \"$FIX/CLAUDE.md\" && ! grep -q 'Coordinator notes' \"$FIX/CLAUDE.md\""
chk "settings.local.json (the secret) is byte-identical to baseline (never read/altered/archived)" \
  "[ \"$NOW_LOCAL_SHA\" = \"$ORIG_LOCAL_SHA\" ]"
chk ".kickoff/ is fully removed" "[ ! -d \"$FIX/.kickoff\" ]"
chk "the mc + scanner seam shims are gone (created/seam reversed)" \
  "[ ! -e \"$FIX/.kickoff/bin/mc\" ] && [ ! -e \"$FIX/.kickoff/bin/scan-secrets\" ]"
# the SKILL-AUTHORED seeded-instance deliverables SURVIVE (the honest half the old e2e never tested)
chk "SURVIVES: the /adopt crew (.claude/agents/pipeline-agent.md) is kept in place" \
  "[ -f \"$FIX/.claude/agents/pipeline-agent.md\" ]"
chk "SURVIVES: TRACKER.md is kept in place (adopter deliverable)" "[ -f \"$FIX/TRACKER.md\" ]"
chk "SURVIVES + RELOCATED: KICKOFF.local.md moved to kickoff-data/ (out of the .kickoff/ teardown)" \
  "[ -f \"$FIX/kickoff-data/KICKOFF.local.md\" ]"
chk "SURVIVES + RELOCATED: the .kickoff/memory corpus moved to kickoff-data/memory/" \
  "[ -f \"$FIX/kickoff-data/memory/widget-cadence.md\" ]"
chk "SURVIVES + RELOCATED: the accumulated board state moved to kickoff-data/state/" \
  "[ -f \"$FIX/kickoff-data/state/mission-control/mission-state.json\" ]"
# the operator's OWN pre-existing crew is byte-identical to baseline (never touched)
chk "the operator's OWN crew (widget-agent.md) is byte-identical to the committed baseline" \
  "git -C \"$FIX\" diff --quiet $BASELINE_TREE -- .claude/agents/widget-agent.md"
# THE HEADLINE — no TRACKED drift vs the pristine baseline; the untracked leftovers are allowlisted deliverables.
chk "HEADLINE: NO tracked-file drift vs the pristine baseline (git status --porcelain -uno EMPTY)" \
  "[ -z \"$TRACKED_DRIFT\" ]"
chk "HEADLINE: HEAD unmoved + every TRACKED file matches the pristine baseline commit (zero content drift)" \
  "git -C \"$FIX\" diff --quiet $BASELINE_TREE -- . && [ \"\$(git -C \"$FIX\" rev-parse HEAD)\" = \"$BASELINE_TREE\" ]"
chk "eject --verify itself reported 'no trace' (kept deliverables + kickoff-data/ allowlisted, not residue)" \
  "printf '%s' \"\$EJECT_OUT\" | grep -q 'no trace'"
if [ -n "$TRACKED_DRIFT" ]; then
  printf '  ── residual TRACKED drift (should be empty):\n'; printf '%s\n' "$TRACKED_DRIFT" | sed 's/^/      /'
fi

# ══════════════════════════════════════════════════════════════════════════════════════
stage "(8) PRISTINE — a fresh adoption fully PURGED → \`git status --porcelain\` LITERALLY empty"
# ══════════════════════════════════════════════════════════════════════════════════════
# The strongest byte-for-byte zero-trace claim: adopt + /adopt, then `eject --purge --delete-data
# --confirm-destroy` removes EVERYTHING kickoff (seams + the seeded deliverables + the data) → the tree
# returns to its EXACT pristine baseline. This is the literal `git status --porcelain` == empty proof.
PFIX="$(mk)/pristine-app"
build_brownfield_fixture "$PFIX"
PBASE="$(git -C "$PFIX" rev-parse HEAD)"
KF_REPO="$PFIX"; kf adopt --dir "$PFIX" --accept </dev/null >/dev/null 2>&1
write_fixture_instance_env "$PFIX"
simulate_adopt_session "$PFIX"
KF_REPO="$PFIX"
PURGE_OUT="$(kf eject --dir "$PFIX" --purge --delete-data --confirm-destroy --verify --archive-dir "$ARCHIVE_DIR" 2>&1)"; PURGE_RC=$?
PPORC="$(git -C "$PFIX" status --porcelain)"
chk "purge-eject --verify exits 0" "[ $PURGE_RC -eq 0 ]"
chk "PRISTINE HEADLINE: git status --porcelain is LITERALLY EMPTY — the engine restores EXACT pre-adopt bytes" \
  "[ -z \"$PPORC\" ]"
chk "PRISTINE: HEAD unmoved + tree byte-identical to the pristine baseline" \
  "git -C \"$PFIX\" diff --quiet $PBASE -- . && [ \"\$(git -C \"$PFIX\" rev-parse HEAD)\" = \"$PBASE\" ]"
chk "PRISTINE: .kickoff/ + kickoff-data/ + the /adopt crew are ALL gone (full purge)" \
  "[ ! -e \"$PFIX/.kickoff\" ] && [ ! -e \"$PFIX/kickoff-data\" ] && [ ! -e \"$PFIX/.claude/agents/pipeline-agent.md\" ]"
if [ -n "$PPORC" ]; then printf '  ── residual porcelain (should be empty):\n'; printf '%s\n' "$PPORC" | sed 's/^/      /'; fi

# ══════════════════════════════════════════════════════════════════════════════════════
stage "(9) COMMITTED-seams — committed CREATED seams eject to ' D' deletions classified as EXPECTED"
# ══════════════════════════════════════════════════════════════════════════════════════
# §G makes the seams TRACKED; a by-the-book adopter COMMITS them. A PERFECT eject then leaves ` D <path>`
# in porcelain (the reversal of committed wiring, finished by committing the deletions). --verify must
# classify those as EXPECTED (rc0), never as residue. (Committing the block/merge seams is a different
# case — eject byte-restores OLDER bytes than HEAD → ` M`, which --verify correctly flags; so we commit
# the CREATED seams the design's §G note names, and leave CLAUDE.md/settings.json uncommitted.)
CFIX="$(mk)/committed-app"
build_brownfield_fixture "$CFIX"
KF_REPO="$CFIX"; kf adopt --dir "$CFIX" --accept </dev/null >/dev/null 2>&1
write_fixture_instance_env "$CFIX"
simulate_adopt_session "$CFIX"
git -C "$CFIX" add .kickoff/bin .kickoff/.gitignore .kickoff/KICKOFF.md 2>/dev/null
git -C "$CFIX" commit -qm "adopt: commit the kickoff created seams (§G tracked)" >/dev/null 2>&1
KF_REPO="$CFIX"
COMMIT_OUT="$(kf eject --dir "$CFIX" --verify --archive-dir "$ARCHIVE_DIR" 2>&1)"; COMMIT_RC=$?
CPORC="$(git -C "$CFIX" status --porcelain)"
chk "committed-seams eject --verify exits 0 (the ' D' deletions are EXPECTED, not residue)" "[ $COMMIT_RC -eq 0 ]"
chk "committed created seam shows as a ' D' deletion in porcelain (the reversal of committed wiring)" \
  "printf '%s' \"\$CPORC\" | grep -qE '^ D .kickoff/bin/mc'"
chk "--verify classified the deletions as EXPECTED reversal ('commit ... to finalize')" \
  "printf '%s' \"\$COMMIT_OUT\" | grep -qi 'expected deletions' && printf '%s' \"\$COMMIT_OUT\" | grep -qi 'finalize'"
chk "--verify still reports 'no trace' over the expected deletions (rc0)" \
  "printf '%s' \"\$COMMIT_OUT\" | grep -q 'no trace'"

# ══════════════════════════════════════════════════════════════════════════════════════
stage "(10) RESIDUE — a planted \`kickoff@kickoff-local\` marker eject can't account for → --verify rc1"
# ══════════════════════════════════════════════════════════════════════════════════════
# The counter-proof that rc0 MEANS something: plant a stray kickoff marker in a TRACKED operator file
# (an incomplete de-integration eject cannot reverse — it is not in the manifest). --verify's marker
# scan must catch it and exit NON-ZERO, never falsely report 'no trace'.
RFIX="$(mk)/residue-app"
build_brownfield_fixture "$RFIX"
KF_REPO="$RFIX"; kf adopt --dir "$RFIX" --accept </dev/null >/dev/null 2>&1
write_fixture_instance_env "$RFIX"
simulate_adopt_session "$RFIX"
printf '\n// leftover: kickoff@kickoff-local (a hand-copied ref eject cannot reverse)\n' >> "$RFIX/src/index.js"
KF_REPO="$RFIX"
RES_OUT="$(kf eject --dir "$RFIX" --verify --archive-dir "$ARCHIVE_DIR" 2>&1)"; RES_RC=$?
chk "RESIDUE: eject --verify exits NON-ZERO on the unaccounted kickoff marker (fails LOUD)" "[ $RES_RC -ne 0 ]"
chk "RESIDUE: --verify names the residue (a kickoff marker / not byte-for-byte clean)" \
  "printf '%s' \"\$RES_OUT\" | grep -qiE 'residue|NOT byte-for-byte'"

# ══════════════════════════════════════════════════════════════════════════════════════
stage "(11) GREENFIELD — create-then-adopt OUTSIDE the clone, via a SYMLINKED front door → zero-trace"
# ══════════════════════════════════════════════════════════════════════════════════════
# Proves eject/de-integration come FREE for greenfield, AND exercises the readlink-`$0` fix: every engine
# call here goes through a `ln -s`'d front door, so HERE must resolve to the real scripts/ (or every
# sibling lookup breaks). A NEW project scaffolded OUTSIDE the kickoff clone: git init + baseline, adopt,
# a small recorded /adopt, then full-purge eject → the tree returns to its pristine scaffold.
GF="$(mk)/green-app"
mkdir -p "$GF/src"
git -C "$GF" init -q; git -C "$GF" config user.email dev@green.test; git -C "$GF" config user.name dev
printf '# green-app\n\nA freshly-scaffolded project.\n' > "$GF/README.md"
printf 'console.log("hi")\n' > "$GF/src/main.js"
printf 'node_modules/\n' > "$GF/.gitignore"
git -C "$GF" add -A; git -C "$GF" commit -qm "scaffold: green-app baseline" >/dev/null
GBASE="$(git -C "$GF" rev-parse HEAD)"
KF_REPO="$GF"
GADOPT_OUT="$(kfl adopt --dir "$GF" --accept </dev/null 2>&1)"; GADOPT_RC=$?     # via the SYMLINK; --accept: §4 scripted consent
write_fixture_instance_env "$GF"
simulate_adopt_session "$GF"
chk "greenfield adopt via the SYMLINKED front door exits 0 (readlink -f \$0 resolved the real engine)" \
  "[ $GADOPT_RC -eq 0 ]"
chk "greenfield adopt wired .kickoff/ + created a CLAUDE.md (absent → seeded)" \
  "[ -d \"$GF/.kickoff\" ] && [ -f \"$GF/CLAUDE.md\" ]"
chk "greenfield adopt did NOT resolve HERE to the live repo (no live-repo path in its output)" \
  "! printf '%s' \"\$GADOPT_OUT\" | grep -qF '$REPO/.kickoff'"
KF_REPO="$GF"
GEJECT_OUT="$(kfl eject --dir "$GF" --purge --delete-data --confirm-destroy --verify --archive-dir "$ARCHIVE_DIR" 2>&1)"; GEJECT_RC=$?
GPORC="$(git -C "$GF" status --porcelain)"
chk "greenfield eject via the SYMLINK exits 0 (--verify)" "[ $GEJECT_RC -eq 0 ]"
chk "GREENFIELD zero-trace: git status --porcelain is LITERALLY EMPTY — back to the scaffold baseline" \
  "[ -z \"$GPORC\" ]"
chk "GREENFIELD: HEAD unmoved + tree byte-identical to the scaffold baseline; .kickoff/ gone" \
  "git -C \"$GF\" diff --quiet $GBASE -- . && [ ! -e \"$GF/.kickoff\" ]"
if [ -n "$GPORC" ]; then printf '  ── residual porcelain (should be empty):\n'; printf '%s\n' "$GPORC" | sed 's/^/      /'; fi

# ══════════════════════════════════════════════════════════════════════════════════════
stage "(12) LIVE-SAFETY CANARY — the live front door + this repo are UNTOUCHED by the journey"
# ══════════════════════════════════════════════════════════════════════════════════════
chk "CANARY: live ~/box-ingress registry.json byte-identical (before==after)" \
  "[ \"$LIVE_REG_BEFORE\" = \"$(canary_hash "$LIVE_INGRESS/registry.json")\" ]"
chk "CANARY: live ~/box-ingress Caddyfile byte-identical (before==after)" \
  "[ \"$LIVE_CF_BEFORE\" = \"$(canary_hash "$LIVE_INGRESS/Caddyfile")\" ]"
if [ -n "$LIVE_PIDS_BEFORE" ]; then
  ALL_ALIVE=1; for p in $LIVE_PIDS_BEFORE; do kill -0 "$p" 2>/dev/null || ALL_ALIVE=0; done
  chk "CANARY: the live box-ingress caddy pid(s) are still alive [$LIVE_PIDS_BEFORE]" "[ $ALL_ALIVE -eq 1 ]"
  chk "CANARY: the live caddy pid set is unchanged (none killed/spawned)" \
    "[ \"$LIVE_PIDS_BEFORE\" = \"$(live_caddy_pids)\" ]"
else
  ok "CANARY: no live box-ingress caddy detected on this box (nothing to endanger)"
fi
chk "CANARY: the live repo's .kickoff/adopt-manifest.json is byte-identical (never adopted/ejected)" \
  "[ \"$LIVE_KICKOFF_DIR_BEFORE\" = \"$(canary_hash "$REPO/.kickoff/adopt-manifest.json")\" ]"
chk "CANARY: this repo's own working-tree status is unchanged (the journey wrote only to scratch)" \
  "[ \"$LIVE_REPO_STATUS_BEFORE\" = \"\$(git -C \"$REPO\" status --porcelain 2>/dev/null | sha256sum | awk '{print \$1}')\" ]"

# ══════════════════════════════════════════════════════════════════════════════════════
stage "(13) SUITE HYGIENE — no fixture supervisor/session this journey spawned outlives the run"
# ══════════════════════════════════════════════════════════════════════════════════════
# The (6c/6d) fixture supervisors + their stub sessions are torn down inline (teardown_upgrade_fixture);
# the EXIT trap is the safety net. Assert here (before the trap fires) that the suite's OWN teardown
# already left nothing alive — a skipped teardown or a leaked session fails LOUD. Scoped to THIS run's
# exact recorded pids (kill -0), never a `ps|grep` pattern that would catch another org's live worker.
JRNY_LEAK=""
if [ -f "$JRNY_PIDS" ]; then
  while IFS= read -r _p; do
    case "$_p" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$_p" 2>/dev/null && JRNY_LEAK="$JRNY_LEAK $_p"
  done < "$JRNY_PIDS"
fi
chk "no fixture supervisor/session this journey spawned is still alive (all recorded pids reaped)" \
  "[ -z \"$JRNY_LEAK\" ]"
[ -n "$JRNY_LEAK" ] && printf '  ── leaked fixture pids (should be empty):%s\n' "$JRNY_LEAK"

echo
echo "════════════════════════════════════════════════════════════════════"
echo "  $PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
  echo "  ✅ the brownfield engine COMPOSES end-to-end — adopt→/adopt→run→serve→pull→eject, HONESTLY zero-trace"
  exit 0
else
  echo "  ❌ integration FAILURE — a stage did not compose (see the stage above)"
  exit 1
fi
