#!/usr/bin/env bash
# plugin-selftest.sh — prove §5 THE PLUGIN (slices 1–8): the engine packaged as a Claude Code plugin,
# enabled at project scope by adopt, cache re-synced by pull, hashed by preflight #8, and reversed by
# eject — plus the hermetic E2E acceptance that gates the tag.
#
#   bash scripts/plugin-selftest.sh
#
# Mirrors pull/eject/adopt-selftest.sh (mktemp fixtures + ok/bad/chk, ONE EXIT trap cleaning only our
# OWN named dirs — NEVER a /tmp/tmp.* wildcard sweep). It proves, in layers:
#   0 (Slice 1) — the plugin package + headless wiring: the manifests parse + carry `version`; the
#       thin memory-hook.sh is 0755 + resolves $KICKOFF_CORE_DIR/memory-retrieval/hook.mjs; every
#       generic skill/agent is present; the plugin file set is in core-manifest.txt; and the two
#       session-run.sh argv assertions (origin-inert / adopter-active, the dogfood-safety correction).
#   1 (Slice 2) — schema v2 + machine_entries: plugin-record → plugin-list round-trip; a v1 manifest
#       (no machine key) still verify+reverse clean; a fresh manifest is v2; entries[] byte-unchanged.
#   2 (Slice 3) — adopt enables at PROJECT scope: against a git fixture + a STUB claude + an ISOLATED
#       CLAUDE_CONFIG_DIR → EXACTLY the two settings.json keys; the manifest gains the json-merged
#       settings entry (with original) + the machine plugin row; the cache is populated; settings
#       .local.json is untouched.
#   3 (Slice 4) — pull re-syncs the cache: a fake core core-vA(0.1.0)→core-vB(0.2.0) + stub claude →
#       the cache is re-synced to 0.2.0 FRESH content; the adopter's OWN layer is byte-identical; a
#       same-version re-pull uses mechanism B (reinstall); and the DOGFOOD-SAFETY gate — a
#       no-machine-entry fixture drives ZERO `claude` invocations.
#   4 (Slice 5) — preflight #8 also hashes the cache: plugin-cache-verify GREEN on a matching cache,
#       FAIL on an edited cache file / a missing version dir, SKIP with no machine entry; and the
#       preflight #8 integration (GREEN → 'cache integrity verified'; edited → FAIL 'cache DRIFT').
#   5 (Slice 6) — eject unwires the plugin: LAST sibling → cache swept + marketplace removed + repo
#       keys byte-restored + the TRACKED tree byte-restored (the sole residue is the intentionally-
#       kept §E deliverables — a relocated kickoff-data/, and a kickoff-created CLAUDE.md where there
#       was none); a differently-tagged sibling → cache/marketplace LEFT (repo keys still removed,
#       adopters row dropped).
#   6 (Slice 8) — the hermetic E2E ACCEPTANCE that gates the tag: adopt@vA → pull core-vB (cache@0.2.0
#       fresh, preflight #8 GREEN, adopter byte-untouched, no-entry sibling → ZERO claude) → eject
#       (last: settings.json byte-restored, cache+marketplace gone, adopters row dropped, the tracked
#       tree byte-restored except the preserved kickoff-data/ deliverable, the planted secret survives
#       + is ABSENT from all eject output).
#
# HERMETIC + ISOLATED: every real plugin action goes through a STUB `claude` on PATH (encoding the
# spike behavior) under CLAUDE_CONFIG_DIR=<scratch>. The live ~/.claude/plugins/ is NEVER touched —
# the stub HARD-REFUSES to run without CLAUDE_CONFIG_DIR set. Exits non-zero on ANY failed assertion.
# Deps: python3 + jq + git + coreutils.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
AM="$REPO/scripts/adopt-manifest.py"
KICKOFF="$REPO/scripts/kickoff"
PLUGIN="$REPO/plugin"

# ── self-scrub the ambient instance.env whitelist (robust push-gate) ────────────────────────────────
# This suite builds its OWN hermetic mktemp fixtures — but when it runs INSIDE a kickoff-managed session
# (notably the lefthook pre-push gate), the ambient environment legitimately exports the LIVE repo's
# instance.env whitelist vars (TELEGRAM_STATE_DIR, MEMORY_INDEX, MC_STATE_FILE, …). A preset env var WINS
# over a fixture's instance.env by design, so an unscrubbed run leaks those live channel/data paths into
# the fixtures' preflight/engine calls and false-fails a gate that must pass regardless of the caller's
# env. Unset the whole whitelist (+ its channel/lock siblings) ONCE here — the SAME set reconcile-selftest
# .sh scrubs — BEFORE any fixture setup; the per-fixture `export`s below (incl. the §-isolation exports)
# intentionally re-set their own values AFTER this and are preserved.
unset REPO_DIR KICKOFF_CORE_DIR KICKOFF_CORE_REMOTE MC_STATE_FILE MC_TRACKER_FILE \
      MEMORY_DB MEMORY_HOOK_LOG MEMORY_DIR MEMORY_INDEX TELEGRAM_STATE_DIR CHANNEL_SPEC \
      REGROUND_PROMPT PERMISSION_MODE EFFORT MODEL MAX_CONCURRENT_AGENTS DEPLOY_BRANCH \
      CADENCE INSTANCE_ENV LOCKFILE ORIGIN_STATE_DIR OPERATOR_STATE_DIR 2>/dev/null || true

PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

# A planted FAKE token for the adopter's settings.local.json (proves the plugin flow leaves it
# byte-identical + never surfaces it). A shell var carrying "FAKE" so this test's own source trips
# no secret-scanner finding — the same posture as pull/eject/adopt-selftest's $PLANT.
PLANT='FAKE_TELEGRAM_TOKEN_planted_do_not_store_123'

# ONE EXIT trap cleans every mktemp dir — via a file side-effect so dirs mk() makes inside a
# $(command-substitution) subshell survive. NEVER a wildcard sweep of /tmp/tmp.* — only our dirs.
CLEANUP_LIST="$(mktemp)"
mk() { local d; d="$(mktemp -d)"; printf '%s\n' "$d" >> "$CLEANUP_LIST"; printf '%s' "$d"; }
trap 'while IFS= read -r _d; do [ -n "$_d" ] && rm -rf "$_d"; done < "$CLEANUP_LIST"; rm -f "$CLEANUP_LIST"' EXIT

# ── CANARY (hard backstop, §5 fix-round-3) ────────────────────────────────────────────────────────
# The ORIGIN's live .claude/settings.json must be BYTE-UNCHANGED across the WHOLE suite. The §5
# _resync_plugin_cache cwd bug wrote a project settings.json into whatever cwd the pull ran from — so a
# suite run from the repo root leaked `enabledPlugins` into the LIVE origin config (and the pre-push
# lefthook gate runs this suite). Snapshot the origin's bytes at suite START; re-compare at END; FAIL
# LOUDLY (and AUTO-RESTORE) if anything changed. This catches ANY future cwd leak into the live repo,
# independent of the stub guard (belt: the stub guard REFUSES the write; this canary DETECTS a slip).
ORIGIN_SETTINGS="$REPO/.claude/settings.json"
ORIGIN_SNAP="$(mktemp)"; printf '%s\n' "$ORIGIN_SNAP" >> "$CLEANUP_LIST"
if [ -f "$ORIGIN_SETTINGS" ]; then cp "$ORIGIN_SETTINGS" "$ORIGIN_SNAP"; ORIGIN_EXISTED=1; else ORIGIN_EXISTED=0; fi
# Same backstop for the user-global marketplace registry: the suite is CLAUDE_CONFIG_DIR-isolated, but a
# REAL prior adoption on this box (e.g. a prior adopter) legitimately registers kickoff-local in the live
# ~/.claude — so an unconditional "no kickoff-local" check false-fails. Snapshot the bytes at START;
# assert BYTE-UNCHANGED at END (a real suite leak still fails; pre-existing real-adoption residue passes).
LIVE_KM="$HOME/.claude/plugins/known_marketplaces.json"
LIVE_KM_SNAP="$(mktemp)"; printf '%s\n' "$LIVE_KM_SNAP" >> "$CLEANUP_LIST"
if [ -f "$LIVE_KM" ]; then cp "$LIVE_KM" "$LIVE_KM_SNAP"; LIVE_KM_EXISTED=1; else LIVE_KM_EXISTED=0; fi
# Same backstop for the user-global INSTALL registry (#8 install-row gate): plugin-consumers-others
# + the H1/H2/H3 topology cases read/write ONLY isolated fixture copies — snapshot the LIVE
# ~/.claude/plugins/installed_plugins.json bytes at START; assert BYTE-UNCHANGED at END (read-only
# comparison; the suite must never write to ~/.claude).
LIVE_IP="$HOME/.claude/plugins/installed_plugins.json"
LIVE_IP_SNAP="$(mktemp)"; printf '%s\n' "$LIVE_IP_SNAP" >> "$CLEANUP_LIST"
if [ -f "$LIVE_IP" ]; then cp "$LIVE_IP" "$LIVE_IP_SNAP"; LIVE_IP_EXISTED=1; else LIVE_IP_EXISTED=0; fi

echo "▶ §5 THE PLUGIN self-test (slices 1–8)"
echo

command -v python3 >/dev/null 2>&1 || { echo "  ❌ python3 not found"; exit 1; }
command -v jq      >/dev/null 2>&1 || { echo "  ❌ jq not found";      exit 1; }
command -v git     >/dev/null 2>&1 || { echo "  ❌ git not found";     exit 1; }

# ── LIVE-SAFETY ISOLATION (reviewer gap) — pin EVERY engine call's machine-level surfaces to SCRATCH
# so this suite can NEVER touch the live box. The failure the reviewer flagged: eject/E2E did NOT set
# INGRESS_DIR, so `kickoff eject` ran `ingress.sh remove <tmp-basename>` against the LIVE ~/box-ingress
# (reading its registry.json + invoking the machine Caddy singleton). Three machine surfaces + the
# ambient REPO_DIR are the leak paths; neutralize all of them ONCE here as EXPORTED scratch defaults so
# every engine call inherits them (per-case values still override where a test sets its own registry/
# cfg). Belt-and-braces: even a future-added engine call is isolated by construction.
#   • INGRESS_DIR → a NON-existent scratch path: eject's `[ ! -d "$_ingress_dir" ]` guard then SKIPS the
#     ingress step entirely (zero ingress.sh execution), so ~/box-ingress is never read, written, or
#     Caddy-reloaded — the tightest possible proof the live singleton is untouched.
#   • KICKOFF_ADOPTERS_REGISTRY → a scratch fallback: the machine registry ~/.kickoff/adopters.json is
#     never read/written (each case still points its own scratch registry; this catches any that don't).
#   • CLAUDE_CONFIG_DIR → a scratch fallback: the live ~/.claude/plugins is never touched (the stub
#     claude also HARD-REFUSES without it; each claude-driving case sets its own — this is the backstop).
#   • REPO_DIR → UNSET (the task's `env -u REPO_DIR`): the ambient REPO_DIR is the LIVE repo, and every
#     engine call already targets a fixture via --dir / --repo / an explicit REPO_DIR prefix, so stripping
#     the live value removes the last way it could leak into a front-door default. (The suite itself never
#     reads $REPO_DIR — verified — so unsetting it is inert here; the CANARY still snapshots $REPO, which
#     is derived from $HERE, not REPO_DIR.)
_ISO="$(mk)"
export INGRESS_DIR="$_ISO/no-ingress-here"                 # non-existent on purpose → eject SKIPS ingress
export KICKOFF_ADOPTERS_REGISTRY="$_ISO/fallback-adopters.json"
export CLAUDE_CONFIG_DIR="$_ISO/fallback-cfg"
unset REPO_DIR

# ══════════════════════════════════════════════════════════════════════════════════════
# The STUB `claude` — a hermetic, ISOLATED encoding of the spike's local-path-plugin behavior.
# marketplace add → known_marketplaces.json (+ extraKnownMarketplaces at project scope); install →
# installed_plugins.json + a BYTE-snapshot of the plugin source → cache/<mkt>/<plugin>/<version>/ (+
# enabledPlugins at project scope); update → version-gated re-snapshot (NO-OP unless the version
# STRING bumps — the spike finding); uninstall/marketplace-remove → delete the cache + registry. It
# HARD-REFUSES without CLAUDE_CONFIG_DIR (so a test can never touch the live ~/.claude) and LOGS every
# invocation to $CLAUDE_STUB_LOG (for the zero-invocation dogfood assertion + the session-run argv).
# ══════════════════════════════════════════════════════════════════════════════════════
write_stub_claude() {   # $1 = dir to place the `claude` stub in
  local d="$1"
  cat > "$d/claude" <<'PYEOF'
#!/usr/bin/env python3
import json, os, sys, shutil, tempfile

# LOG every invocation (argv) — the zero-invocation dogfood assertion + session-run argv read this.
_logp = os.environ.get("CLAUDE_STUB_LOG")
if _logp:
    with open(_logp, "a") as f:
        f.write(" ".join(sys.argv[1:]) + "\n")

# HARD ISOLATION GUARD — never operate against a real ~/.claude. Refuse if not isolated.
cfg = os.environ.get("CLAUDE_CONFIG_DIR")
if not cfg:
    sys.stderr.write("stub-claude: CLAUDE_CONFIG_DIR unset — refusing (test isolation guard)\n")
    sys.exit(3)

args = sys.argv[1:]
if not args or args[0] != "plugin":
    sys.exit(0)                       # e.g. `claude --channels …` (session-run) — logged above, no-op
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
    # STUB GUARD (§5 fix-round-3): `--scope project` is cwd-relative, so a mis-cwd'd resync would write a
    # project settings.json into a REAL repo (the origin, an adopter, or the read-only core clone). Every
    # test fixture lives under a temp dir (mktemp -d), so REFUSE any project-settings write whose resolved
    # path is not under $TMPDIR / the system tempdir / /tmp — a mis-cwd'd test fails fast + loud, never leaks.
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

# parse --scope/-s out of the positionals. `scope_given` tracks whether --scope was EXPLICIT — real
# claude defaults update/uninstall to USER scope when it is omitted (the crux of §5 review Fix 2).
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
        print("Updated marketplace(s)"); sys.exit(0)          # re-read manifest; no cache change here
    if sub in ("remove", "rm"):
        name = pos[2]; km = load(km_path, {}); km.pop(name, None); save(km_path, km)
        # scope-less remove clears EVERY scope (real claude: "Omit --scope to remove it from all
        # scopes"); --scope project clears just the project settings declaration. REALITY-MODEL
        # (corrected): real `claude` LOADS + RE-SERIALIZES the project settings.json (re-canonicalizing
        # 4-space→2-space, reordering keys) EVEN WHEN extraKnownMarketplaces was already absent — e.g.
        # after eject step-4 byte-restored it away. The old stub wrote ONLY when a key changed, so it
        # NEVER re-canonicalized a byte-restored file — masking the round-trip clobber a real adopter
        # hit (296 B hand-written → 412 B re-canonicalized). Model the real re-write (only if a project
        # settings.json EXISTS — never CREATE one where there was none).
        if (scope == "project" or not scope_given) and os.path.exists(proj_settings_path()):
            sd = load_proj()
            sd.get("extraKnownMarketplaces", {}).pop(name, None)
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
    # REALITY-MODEL (#8, verified vs real claude 2.1.207 under an isolated CLAUDE_CONFIG_DIR): a
    # project-scope install records projectPath = the consuming project (the cwd the scoped install
    # ran from); user-scope rows carry NO projectPath. The install-row sole-consumer gate keys on
    # this field, so the stub must model it — the old stub omitted it, which would make every
    # adopter look like an UNKNOWN consumer and mask the gate entirely.
    row = {"scope": scope, "installPath": dst, "version": ver}
    if scope == "project":
        row["projectPath"] = os.path.realpath(os.getcwd())
    ip = load(ip_path, {"version": 2, "plugins": {}}); ip.setdefault("plugins", {})[spec] = [row]; save(ip_path, ip)
    if scope == "project":
        sd = load_proj(); sd.setdefault("enabledPlugins", {})[spec] = True; save_proj(sd)
    print("Successfully installed plugin: %s (scope: %s)" % (spec, scope)); sys.exit(0)

if pos and pos[0] == "update":
    spec = pos[1]; plugin, mkt = spec.split("@", 1)
    ip = load(ip_path, {"version": 2, "plugins": {}}); rows = ip.get("plugins", {}).get(spec, [])
    installed_scope = rows[0].get("scope") if rows else None
    # SCOPE-AWARE (mirrors real claude 2.1.202 — §5 review Fix 2). `update` targets `scope` (default
    # USER when --scope is omitted). A PROJECT-scope install is not visible at user scope → a scope-less
    # update REFUSES it (rc1 "not installed at scope user"). This is the real refusal the old scope-
    # blind stub masked — the reason 114 tests passed while every real adopter upgrade was bricked.
    if not rows:
        sys.stderr.write('✘ Failed to update plugin "%s": not installed\n' % spec); sys.exit(1)
    if installed_scope != scope:
        sys.stderr.write('✘ Failed to update plugin "%s": Plugin "%s" is not installed at scope %s\n' % (spec, plugin, scope)); sys.exit(1)
    src = load(km_path, {}).get(mkt, {}).get("source", {}).get("path")
    mm = mkt_manifest(src); proot = plugin_root(src, mm, plugin); cur = plugin_ver(proot)
    installed = rows[0].get("version")
    if installed == cur:
        print("Plugin %s is already at the latest version" % spec); sys.exit(0)   # NO-OP (spike finding)
    dst = snapshot(proot, mkt, plugin, cur)
    row = {"scope": installed_scope, "installPath": dst, "version": cur}
    if rows[0].get("projectPath"):                    # update PRESERVES the row's consuming project
        row["projectPath"] = rows[0]["projectPath"]
    ip["plugins"][spec] = [row]; save(ip_path, ip)
    print("Restart to apply changes"); sys.exit(0)

if pos and pos[0] in ("uninstall", "remove"):
    spec = pos[1]; plugin, mkt = spec.split("@", 1)
    ip = load(ip_path, {"version": 2, "plugins": {}}); rows = ip.get("plugins", {}).get(spec, [])
    installed_scope = rows[0].get("scope") if rows else None
    # SCOPE-AWARE (mirrors real claude — §5 review Fix 2). `uninstall` targets `scope` (default USER).
    # A PROJECT install is "enabled at project scope" → a scope-less uninstall REFUSES it (rc1). It
    # keys off installed_plugins.json (like real claude), so `uninstall --scope project` still succeeds
    # AFTER eject has byte-restored the repo settings.json (the enabledPlugins key is already gone).
    if not rows:
        sys.stderr.write('✘ Failed to uninstall plugin "%s": not installed\n' % spec); sys.exit(1)
    if installed_scope != scope:
        sys.stderr.write('✘ Failed to uninstall plugin "%s": Plugin "%s" is enabled at %s scope\n' % (spec, spec, installed_scope)); sys.exit(1)
    pdir = os.path.join(cachedir, mkt, plugin)
    if os.path.isdir(pdir): shutil.rmtree(pdir)               # sweep ALL version dirs
    ip.get("plugins", {}).pop(spec, None); save(ip_path, ip)
    # REALITY-MODEL (corrected — the bug this whole suite missed): `uninstall --scope project` RE-
    # SERIALIZES the PROJECT settings.json (re-canonicalizing 4-space→2-space, reordering keys) AND
    # leaves a stray `enabledPlugins: {}`, EVEN WHEN the enablement key was already gone (eject step-4
    # byte-restored it away). The old stub wrote ONLY when it popped an existing key, so a byte-restored
    # settings.json was never re-canonicalized — which is EXACTLY why 149 green tests missed the
    # round-trip clobber a real adopter hit. Model the real re-write here (only if a project settings.json
    # EXISTS — never CREATE one; user-scope uninstall never touches project settings).
    if scope == "project" and os.path.exists(proj_settings_path()):
        sd = load_proj()
        sd.get("enabledPlugins", {}).pop(spec, None)
        sd.setdefault("enabledPlugins", {})                  # the stray `enabledPlugins: {}` real claude leaves
        save_proj(sd)
    print("Uninstalled %s (scope: %s)" % (spec, scope)); sys.exit(0)

sys.exit(0)
PYEOF
  chmod +x "$d/claude"
}

# ══════════════════════════════════════════════════════════════════════════════════════
echo "0. Slice 1 — plugin package + headless wiring"
# ══════════════════════════════════════════════════════════════════════════════════════
chk "plugin.json parses + name==kickoff + carries a version" \
  "python3 -c \"import json;d=json.load(open('$PLUGIN/.claude-plugin/plugin.json'));assert d['name']=='kickoff' and d.get('version')\""
chk "marketplace.json parses + name==kickoff-local + lists the kickoff plugin" \
  "python3 -c \"import json;d=json.load(open('$PLUGIN/.claude-plugin/marketplace.json'));assert d['name']=='kickoff-local';assert any(p['name']=='kickoff' for p in d['plugins'])\""
chk "hooks/hooks.json declares a UserPromptSubmit command hook via \${CLAUDE_PLUGIN_ROOT}" \
  "python3 -c \"import json;d=json.load(open('$PLUGIN/hooks/hooks.json'));h=d['hooks']['UserPromptSubmit'][0]['hooks'][0];assert h['type']=='command' and 'CLAUDE_PLUGIN_ROOT' in h['command'] and 'memory-hook.sh' in h['command']\""
# The agent-mail hook is the SECOND UserPromptSubmit entry, and order matters less than presence:
# a hook that ships in the manifest but is never declared here is dead weight the adopter carries
# and nobody fires — the same orphaned-artifact failure the v0.23 suite-discovery note describes.
chk "hooks/hooks.json ALSO declares the agent-mail per-turn hook" \
  "python3 -c \"import json;d=json.load(open('$PLUGIN/hooks/hooks.json'));hs=d['hooks']['UserPromptSubmit'][0]['hooks'];assert any(h['type']=='command' and 'CLAUDE_PLUGIN_ROOT' in h['command'] and 'agent-mail-hook.sh' in h['command'] for h in hs)\""
chk "the agent-mail hook file it points at actually exists in the plugin" \
  "[ -f '$PLUGIN/hooks/agent-mail-hook.sh' ]"
chk ".mcp.json declares the chrome-devtools MCP server" \
  "python3 -c \"import json;d=json.load(open('$PLUGIN/.mcp.json'));assert 'chrome-devtools' in d['mcpServers']\""
# PAIRED-FLAG INVARIANT — forcing the ANGLE backend REMOVES Chrome's automatic software-WebGL
# fallback (Chrome deprecated the implicit path; its own console warning names the opt-in flag).
# Measured 2026-07-29: `--use-gl=angle --use-angle=gl-egl` alone engages this box's discrete NVIDIA GPU and
# drops a 3D page from 9.1 cores to 0.6 — but on a machine with no NVIDIA EGL vendor library it
# leaves getContext('webgl') returning NULL, i.e. WebGL is not slow, it is GONE. Adding
# --enable-unsafe-swiftshader restores the software path, so the same config is fast where there is
# a GPU and merely slow where there is not. This is a SHIPPED config on unknown adopter hardware,
# so the two flags must never be separated by a future edit.
# BOTH configs took the identical edit, so both need the guard: the shipped plugin one protects
# adopters, the repo-root one protects this engine checkout's own eyes. Guarding only the first
# would let the second drift silently — and the second is what THIS crew renders with.
for _mcp in "$PLUGIN/.mcp.json" "$REPO/.mcp.json"; do
  [ -f "$_mcp" ] || continue
  chk "★ $(basename "$(dirname "$_mcp")")/.mcp.json: forcing ANGLE is paired with the software-WebGL fallback" \
    "python3 -c \"
import json,sys
a=' '.join(json.load(open('$_mcp'))['mcpServers']['chrome-devtools']['args'])
sys.exit(0 if ('use-angle' not in a) or ('enable-unsafe-swiftshader' in a) else 1)\""
done
chk "memory-hook.sh is executable (owner +x; umask-robust)" \
  "[ -x '$PLUGIN/hooks/memory-hook.sh' ]"

# the thin hook resolves $KICKOFF_CORE_DIR/memory-retrieval/hook.mjs from a fixture instance.env,
# WITHOUT running node (the DRY-RUN seam prints the resolved engine + exits).
HK="$(mk)"; HKCORE="$(mk)"; mkdir -p "$HK/.kickoff" "$HKCORE/memory-retrieval"
printf 'export KICKOFF_CORE_DIR=%q\n' "$HKCORE" > "$HK/.kickoff/instance.env"
RESOLVED="$(CLAUDE_PROJECT_DIR="$HK" KICKOFF_MEMORY_HOOK_DRYRUN=1 bash "$PLUGIN/hooks/memory-hook.sh" </dev/null 2>/dev/null || true)"
chk "memory-hook.sh resolves \$KICKOFF_CORE_DIR/memory-retrieval/hook.mjs (from instance.env, no node)" \
  "[ \"$RESOLVED\" = \"$HKCORE/memory-retrieval/hook.mjs\" ]"
chk "memory-hook.sh fails-OPEN with no CLAUDE_PROJECT_DIR (exit 0, no output)" \
  "OUT=\$(env -u CLAUDE_PROJECT_DIR bash '$PLUGIN/hooks/memory-hook.sh' </dev/null 2>&1); RC=\$?; [ \$RC -eq 0 ] && [ -z \"\$OUT\" ]"

# the generic skill + agent set travels in the plugin
for s in scan review harden preview bootstrap adopt plugins mission-control mc-report crew-review setup agent-mail; do
  chk "plugin skill present: $s" "[ -f \"$PLUGIN/skills/$s/SKILL.md\" ]"
done
for a in planner builder reviewer deployer; do
  chk "plugin agent present: $a" "[ -f \"$PLUGIN/agents/$a.md\" ]"
done

# the plugin file set is in core-manifest.txt (so it travels + whole-tree-pins on pull)
for p in \
  "plugin/.claude-plugin/plugin.json" "plugin/.claude-plugin/marketplace.json" \
  "plugin/hooks/hooks.json" "plugin/hooks/memory-hook.sh" "plugin/.mcp.json" \
  "plugin/skills" "plugin/agents"; do
  chk "core-manifest.txt lists $p" "grep -qxF '$p' \"$REPO/scripts/core-manifest.txt\""
done
# memory-retrieval/ stays single-sourced (NOT copied into the plugin — decision #4)
chk "memory-retrieval/hook.mjs is NOT bundled in the plugin (single-sourced, decision #4)" \
  "[ ! -e \"$PLUGIN/memory-retrieval\" ]"

# ── the two session-run.sh argv assertions (the ⚠ dogfood-safety correction) ──
# A stub `claude` on PATH records the exec'd argv to a log. Each invocation runs under script(1)
# so session-run's stdin IS a pty and its TTY-detect wrap (v0.7 G1 §2.4: decided by [ -t 0 ],
# never by an inheritable env var) skips naturally — session-run reaches the exec with no
# re-wrap and no keepalive spawned. env -u strips ambient PERMISSION_MODE/EFFORT/MODEL for determinism,
# and (core-v0.39) WORKER_ENGINE + OPENCODE_MODEL_* too: these lanes assert CLAUDE-path argv
# construction specifically, and this box now legitimately runs WORKERS on either engine — an
# opencode-engine coordinator's shell exports WORKER_ENGINE=opencode, which without the strip
# dispatches session-run down the opencode path (credential FATAL, stub never exec'd) and turns
# every presence-lane red / absence-lane vacuously green. The lanes OWN their engine input.
SR="$(mk)"; SRSTUB="$(mk)"; write_stub_claude "$SRSTUB"
mkdir -p "$SR/fix/.kickoff" "$SR/core/plugin"
# origin-shaped: no KICKOFF_CORE_DIR → argv must gain NO --plugin-dir (origin stays INERT)
env -u KICKOFF_CORE_DIR -u PERMISSION_MODE -u EFFORT -u MODEL -u CLAUDE_CONFIG_DIR \
    -u WORKER_ENGINE -u OPENCODE_MODEL_PROVIDER -u OPENCODE_MODEL_ID \
    CLAUDE_STUB_LOG="$SR/argv_origin.log" REPO_DIR="$SR/fix" \
    TELEGRAM_STATE_DIR="$SR/fix/.kickoff/chan" PATH="$SRSTUB:$PATH" \
    script -qfe -c "bash '$REPO/scripts/session-run.sh'" /dev/null </dev/null >/dev/null 2>&1 || true
chk "session-run argv (origin-shaped, no KICKOFF_CORE_DIR): NO --plugin-dir (origin INERT)" \
  "! grep -q -- '--plugin-dir' \"$SR/argv_origin.log\""
# adopter-shaped: KICKOFF_CORE_DIR set + $KICKOFF_CORE_DIR/plugin exists → argv gains --plugin-dir <dir>
env -u PERMISSION_MODE -u EFFORT -u MODEL -u CLAUDE_CONFIG_DIR \
    -u WORKER_ENGINE -u OPENCODE_MODEL_PROVIDER -u OPENCODE_MODEL_ID \
    CLAUDE_STUB_LOG="$SR/argv_adopter.log" REPO_DIR="$SR/fix" \
    TELEGRAM_STATE_DIR="$SR/fix/.kickoff/chan" KICKOFF_CORE_DIR="$SR/core" PATH="$SRSTUB:$PATH" \
    script -qfe -c "bash '$REPO/scripts/session-run.sh'" /dev/null </dev/null >/dev/null 2>&1 || true
chk "session-run argv (adopter-shaped, KICKOFF_CORE_DIR+plugin/): --plugin-dir \$KICKOFF_CORE_DIR/plugin" \
  "grep -q -- '--plugin-dir' \"$SR/argv_adopter.log\" && grep -qF '$SR/core/plugin' \"$SR/argv_adopter.log\""
# adopter-shaped but plugin/ MISSING → still NO --plugin-dir (the gate needs the dir to EXIST)
env -u PERMISSION_MODE -u EFFORT -u MODEL -u CLAUDE_CONFIG_DIR \
    -u WORKER_ENGINE -u OPENCODE_MODEL_PROVIDER -u OPENCODE_MODEL_ID \
    CLAUDE_STUB_LOG="$SR/argv_noplug.log" REPO_DIR="$SR/fix" \
    TELEGRAM_STATE_DIR="$SR/fix/.kickoff/chan" KICKOFF_CORE_DIR="$SR/fix" PATH="$SRSTUB:$PATH" \
    script -qfe -c "bash '$REPO/scripts/session-run.sh'" /dev/null </dev/null >/dev/null 2>&1 || true
chk "session-run argv (KICKOFF_CORE_DIR set but no plugin/): NO --plugin-dir (strict gate)" \
  "! grep -q -- '--plugin-dir' \"$SR/argv_noplug.log\""
# Fix 5 (RED on pre-fix): a SELF-REFERENTIAL origin — KICKOFF_CORE_DIR == REPO_DIR (supervisor.sh:60
# defaults it to the repo root) AND the repo has plugin/ → the fix must ENFORCE inertness (realpath
# compare) → NO --plugin-dir, so the live origin never auto-loads its own half-built plugin (memory-
# hook double-fire + MCP re-declaration). Pre-fix's presence-only gate added --plugin-dir the moment
# KICKOFF_CORE_DIR was set = REPO_DIR → the origin would self-load the plugin (RED on pre-fix).
env -u PERMISSION_MODE -u EFFORT -u MODEL -u CLAUDE_CONFIG_DIR \
    -u WORKER_ENGINE -u OPENCODE_MODEL_PROVIDER -u OPENCODE_MODEL_ID \
    CLAUDE_STUB_LOG="$SR/argv_selforigin.log" REPO_DIR="$SR/core" \
    TELEGRAM_STATE_DIR="$SR/fix/.kickoff/chan" KICKOFF_CORE_DIR="$SR/core" PATH="$SRSTUB:$PATH" \
    script -qfe -c "bash '$REPO/scripts/session-run.sh'" /dev/null </dev/null >/dev/null 2>&1 || true
chk "session-run argv (SELF-REFERENTIAL origin, KICKOFF_CORE_DIR==REPO_DIR w/ plugin/): NO --plugin-dir [Fix 5, RED on pre-fix]" \
  "! grep -q -- '--plugin-dir' \"$SR/argv_selforigin.log\""

# ── the MODEL knob argv assertions (finding #2 — pin the coordinator's model; DEFAULT INHERIT) ──
# A zero-behaviour-change lever: MODEL set ⇒ the exec gains `--model <val>`; MODEL UNSET ⇒ NO --model
# (inherit the box's Claude Code config — byte-for-byte today's exec, so it can NEVER silently
# downgrade the live coordinator). Same argv-recording harness; origin-shaped fixture (no --plugin-dir
# noise). `-u MODEL` strips ambient MODEL so the unset case is deterministic; the set case then sets it.
env -u KICKOFF_CORE_DIR -u PERMISSION_MODE -u EFFORT -u MODEL -u CLAUDE_CONFIG_DIR \
    -u WORKER_ENGINE -u OPENCODE_MODEL_PROVIDER -u OPENCODE_MODEL_ID \
    CLAUDE_STUB_LOG="$SR/argv_model_unset.log" REPO_DIR="$SR/fix" \
    TELEGRAM_STATE_DIR="$SR/fix/.kickoff/chan" PATH="$SRSTUB:$PATH" \
    script -qfe -c "bash '$REPO/scripts/session-run.sh'" /dev/null </dev/null >/dev/null 2>&1 || true
chk "session-run argv (MODEL unset): NO --model (inherit box config, exec byte-unchanged)" \
  "! grep -q -- '--model' \"$SR/argv_model_unset.log\""
env -u KICKOFF_CORE_DIR -u PERMISSION_MODE -u EFFORT -u MODEL -u CLAUDE_CONFIG_DIR \
    -u WORKER_ENGINE -u OPENCODE_MODEL_PROVIDER -u OPENCODE_MODEL_ID \
    CLAUDE_STUB_LOG="$SR/argv_model_set.log" REPO_DIR="$SR/fix" \
    TELEGRAM_STATE_DIR="$SR/fix/.kickoff/chan" MODEL="sonnet" PATH="$SRSTUB:$PATH" \
    script -qfe -c "bash '$REPO/scripts/session-run.sh'" /dev/null </dev/null >/dev/null 2>&1 || true
chk "session-run argv (MODEL=sonnet): --model sonnet present in the exec'd argv" \
  "grep -qE -- '--model[[:space:]]+sonnet' \"$SR/argv_model_set.log\""
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "1. Slice 2 — schema v2 + machine_entries (plugin-record / plugin-list)"
# ══════════════════════════════════════════════════════════════════════════════════════
S2="$(mk)"; mkdir -p "$S2/.kickoff"
python3 "$AM" plugin-record --repo "$S2" --marketplace kickoff-local --plugin kickoff --scope project \
  --marketplace-source "/home/u/kickoff-core/plugin" --source core-v0.2 >/dev/null
chk "plugin-record: fresh manifest is schema_version 2" \
  "python3 -c \"import json;assert json.load(open('$S2/.kickoff/adopt-manifest.json'))['schema_version']==2\""
chk "plugin-record: the machine entry is stored (kind/marketplace/plugin/scope/source)" \
  "python3 -c \"import json;e=json.load(open('$S2/.kickoff/adopt-manifest.json'))['machine_entries'][0];assert e['kind']=='plugin' and e['marketplace']=='kickoff-local' and e['plugin']=='kickoff' and e['scope']=='project' and e['source']=='core-v0.2'\""
chk "plugin-record: NO secret/bytes leak — machine entry carries only metadata keys" \
  "python3 -c \"import json;e=json.load(open('$S2/.kickoff/adopt-manifest.json'))['machine_entries'][0];assert set(e)<= {'kind','marketplace','plugin','scope','marketplace_source','source'}\""
chk "plugin-list: emits a 5-column TSV row (kind mkt plugin scope source-path)" \
  "[ \"\$(python3 \"$AM\" plugin-list --repo \"$S2\" | awk -F'\t' '{print NF}')\" = 5 ]"
chk "plugin-list: the row carries the marketplace + plugin" \
  "python3 \"$AM\" plugin-list --repo \"$S2\" | grep -qP 'kickoff-local\tkickoff'"
# upsert idempotency by (marketplace, plugin)
python3 "$AM" plugin-record --repo "$S2" --marketplace kickoff-local --plugin kickoff --scope project \
  --marketplace-source "/home/u/kickoff-core/plugin" --source core-v0.3 >/dev/null
chk "plugin-record: re-record the same (mkt,plugin) UPSERTS (1 row, source updated)" \
  "[ \"\$(python3 -c \"import json;print(len(json.load(open('$S2/.kickoff/adopt-manifest.json'))['machine_entries']))\")\" = 1 ] && python3 -c \"import json;assert json.load(open('$S2/.kickoff/adopt-manifest.json'))['machine_entries'][0]['source']=='core-v0.3'\""
chk "cmd_show renders the machine entry section" \
  "python3 \"$AM\" show --repo \"$S2\" | grep -q 'machine entr'"
chk "plugin-record REJECTS an unknown scope" \
  "! python3 \"$AM\" plugin-record --repo \"$S2\" --marketplace m --plugin p --scope BOGUS --marketplace-source x --source s"

# a hand-written v1 manifest (NO machine key) still verify + reverse CLEAN (free migration)
V1="$(mk)"; mkdir -p "$V1/.kickoff/bin"
printf '#!/usr/bin/env bash\nexec true\n' > "$V1/.kickoff/bin/mc"
V1SHA="$(sha256sum "$V1/.kickoff/bin/mc" | awk '{print $1}')"
printf '{"schema_version":1,"entries":[{"path":".kickoff/bin/mc","action":"created","class":"seam","source":"core-v0.1","sha256_at_write":"%s"}]}\n' "$V1SHA" > "$V1/.kickoff/adopt-manifest.json"
chk "v1 manifest (no machine key): verify is CLEAN" "python3 \"$AM\" verify --repo \"$V1\""
chk "v1 manifest (no machine key): plugin-list is EMPTY (→ the skip gate)" \
  "[ -z \"\$(python3 \"$AM\" plugin-list --repo \"$V1\")\" ]"
chk "v1 manifest (no machine key): reverse deletes the created file CLEAN (entries[] unchanged)" \
  "python3 \"$AM\" reverse --repo \"$V1\" >/dev/null 2>&1 && [ ! -e \"$V1/.kickoff/bin/mc\" ]"
# a malformed (non-list) machine_entries is FATAL, never skeletoned over
BADMC="$(mk)"; mkdir -p "$BADMC/.kickoff"
printf '{"schema_version":2,"entries":[],"machine_entries":"nope"}\n' > "$BADMC/.kickoff/adopt-manifest.json"
chk "malformed machine_entries (non-list) is FATAL (fail-loud)" \
  "! python3 \"$AM\" show --repo \"$BADMC\""
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "2. Slice 3 — adopt enables the plugin at PROJECT scope (stub claude, isolated cfg)"
# ══════════════════════════════════════════════════════════════════════════════════════
# Build a minimal plugin tree at <core>/plugin with a given version + a content marker.
build_fake_plugin() {   # $1=core dir  $2=version  $3=marker
  local core="$1" ver="$2" marker="$3" pd="$1/plugin"
  mkdir -p "$pd/.claude-plugin" "$pd/hooks" "$pd/skills/scan" "$pd/agents"
  printf '{ "name": "kickoff", "version": "%s", "description": "fake kickoff plugin", "author": {"name":"k"} }\n' "$ver" > "$pd/.claude-plugin/plugin.json"
  printf '{ "name": "kickoff-local", "description": "fake local mkt", "owner": {"name":"k"}, "plugins": [ {"name":"kickoff","source":"./","description":"fake"} ] }\n' > "$pd/.claude-plugin/marketplace.json"
  printf '{ "hooks": { "UserPromptSubmit": [ {"hooks":[{"type":"command","command":"bash \\"${CLAUDE_PLUGIN_ROOT}/hooks/memory-hook.sh\\""}]} ] } }\n' > "$pd/hooks/hooks.json"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$pd/hooks/memory-hook.sh"; chmod 0755 "$pd/hooks/memory-hook.sh"
  printf '{ "mcpServers": { "chrome-devtools": {"command":"npx","args":["chrome-devtools-mcp"]} } }\n' > "$pd/.mcp.json"
  printf 'SKILL scan — content marker %s\n' "$marker" > "$pd/skills/scan/SKILL.md"
  printf 'agent builder — %s\n' "$marker" > "$pd/agents/builder.md"
}
# A fake git-tagged core: core-vA (plugin 0.1.0, marker VA) → core-vB (plugin 0.2.0, marker VB).
build_fake_core() {   # echoes the core path
  local core; core="$(mk)"
  mkdir -p "$core/scripts/templates"
  git -C "$core" init -q; git -C "$core" config user.email t@t.t; git -C "$core" config user.name t
  cp "$REPO/scripts/preflight.sh" "$core/scripts/preflight.sh"
  cp "$AM" "$core/scripts/adopt-manifest.py"
  printf '# KICKOFF (vA)\n\nCHARTER — the coordinator charter.\n\n@.kickoff/KICKOFF.local.md\n' > "$core/scripts/templates/KICKOFF.md"
  # F1 §G/§E: a pinned core MUST carry the FULL file-seam template set + the scan-shim engine targets
  # (core-manifest.txt is the authoritative list). Without scripts/templates/kickoff.gitignore the
  # pinned tag's adopt-manifest.py FATALs when `kickoff pull` runs sync-seams over the §G .kickoff/
  # .gitignore seam (_read_file_seam_template → die), aborting the pull BEFORE the plugin-cache
  # resync — the stale root cause of the pull/eject failures. Copy the LIVE gitignore template so the
  # seam stays byte-stable across adopt→pull (sync-seams reports "already current", never regenerates).
  # Same for the R2 .kickoff/README seam template — a real adopt records it, so a pull's sync-seams
  # regenerates it and _read_file_seam_template FATALs without the pinned template here.
  cp "$REPO/scripts/templates/kickoff.gitignore"  "$core/scripts/templates/kickoff.gitignore"
  cp "$REPO/scripts/templates/kickoff-README.md"  "$core/scripts/templates/kickoff-README.md"
  # brownfield-devex: the reporting-canon output-style seam (gen-output-style) is read directly from
  # the CORE ROOT (.claude/output-styles/plain-report.md — the _AGENT_CHARTER_TEMPLATE idiom, NOT
  # scripts/templates/), and it is class=seam → sync-seams' seam_template_for() reads it from THIS
  # pinned core clone on every `kickoff pull`. Without it here, sync-seams FATALs mid-pull (caught by
  # this suite itself, 2026-08-17) — same failure mode the gitignore/README comment above describes.
  mkdir -p "$core/.claude/output-styles"
  cp "$REPO/.claude/output-styles/plain-report.md" "$core/.claude/output-styles/plain-report.md"
  # the scan-shim engine targets (the scan-secrets/scan-structure seam shims exec these from the core);
  # stubs suffice — no test execs them, they just satisfy the pinned-core existence guard.
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
  build_fake_plugin "$core" "0.1.0" "VA"
  git -C "$core" add -A; git -C "$core" commit -qm core-vA; git -C "$core" tag core-vA
  # evolve to vB: plugin 0.2.0 + a new marker + a new changelog section
  build_fake_plugin "$core" "0.2.0" "VB"
  printf '# CORE-CHANGELOG\n\n## core-vB — 2026-02-02\n\nVB.\n\n## core-vA — 2026-01-01\n\nVA.\n' > "$core/CORE-CHANGELOG.md"
  git -C "$core" add -A; git -C "$core" commit -qm core-vB; git -C "$core" tag core-vB
  git -C "$core" commit --allow-empty -qm post-vB
  printf '%s' "$core"
}
# Build an adopter adopted@core-vA WITH the plugin enabled (stub claude, isolated cfg). Echoes
# "CLONE ADOPTER CFG SNAP STUBDIR REG" (SNAP = pre-pull byte snapshots of the adopter-owned files;
# REG = the ISOLATED adopters registry adopt registered this adopter into — Fix 1b — so later pull/
# eject in the same case reuse it, and the operator's ~/.kickoff/adopters.json is never touched).
build_adopted_case() {   # $1=core
  local core="$1" clone adopter cfg snap stub reg
  clone="$(mk)"; adopter="$(mk)"; cfg="$(mk)"; snap="$(mk)"; stub="$(mk)"; reg="$(mk)/adopters.json"
  write_stub_claude "$stub"
  git clone -q "$core" "$clone"; git -C "$clone" checkout -q --detach core-vA
  mkdir -p "$adopter/src" "$adopter/memory" "$adopter/.kickoff/state" "$adopter/.claude"
  git -C "$adopter" init -q; git -C "$adopter" config user.email t@t.t; git -C "$adopter" config user.name t
  printf '# Operator CLAUDE\n\n<!-- kickoff:begin core-vA -->\n@.kickoff/KICKOFF.md\n<!-- kickoff:end -->\n\nMy own instructions — untouched by adopt/pull.\n' > "$adopter/CLAUDE.md"
  printf 'owned source — byte-stable across adopt+pull.\n' > "$adopter/src/app.txt"
  printf '# memory index\n' > "$adopter/memory/MEMORY.md"
  printf '{ "telegram": { "botToken": "%s" } }\n' "$PLANT" > "$adopter/.claude/settings.local.json"
  # a PRE-EXISTING, NON-jq-canonical settings.json → adopt must record it json-merged (byte-restore)
  printf '{\n    "permissions": {\n        "allow": ["Bash(ls:*)"]\n    }\n}\n' > "$adopter/.claude/settings.json"
  git -C "$adopter" add -A; git -C "$adopter" commit -qm baseline
  cat > "$adopter/.kickoff/instance.env" <<EOF
export KICKOFF_CORE_DIR="$clone"
export KICKOFF_CORE_REMOTE="$core"
export TELEGRAM_STATE_DIR="$adopter/.kickoff/chan"
export MC_STATE_FILE="$adopter/.kickoff/state/mission-state.json"
export MEMORY_DB="$adopter/.kickoff/state/memory-index.db"
export MEMORY_HOOK_LOG="$adopter/.kickoff/state/memory-hook.log"
EOF
  python3 "$clone/scripts/adopt-manifest.py" gen-charter --repo "$adopter" --source core-vA >/dev/null
  # run the REAL `kickoff adopt` — it wires the mc shim, enables the plugin at project scope, AND
  # (Fix 1b) registers this adopter in the machine registry. KICKOFF_ADOPTERS_REGISTRY isolates that
  # registration to a scratch file — NEVER the operator's real ~/.kickoff/adopters.json.
  KICKOFF_ADOPTERS_REGISTRY="$reg" KICKOFF_CORE_DIR="$clone" CLAUDE_CONFIG_DIR="$cfg" PATH="$stub:$PATH" \
    bash "$KICKOFF" adopt --dir "$adopter" --accept </dev/null >/dev/null 2>&1 || true
  cp "$adopter/.claude/settings.local.json" "$snap/settings.local.json"
  cp "$adopter/CLAUDE.md"                    "$snap/CLAUDE.md"
  cp "$adopter/src/app.txt"                  "$snap/app.txt"
  cp "$adopter/.kickoff/KICKOFF.local.md"    "$snap/KICKOFF.local.md"
  printf '%s %s %s %s %s %s' "$clone" "$adopter" "$cfg" "$snap" "$stub" "$reg"
}

FCORE="$(build_fake_core)"
read -r A3CLONE A3ADOPTER A3CFG A3SNAP A3STUB A3REG <<< "$(build_adopted_case "$FCORE")"
SETTINGS="$A3ADOPTER/.claude/settings.json"
MAN3="$A3ADOPTER/.kickoff/adopt-manifest.json"
chk "adopt: EXACTLY the two settings.json keys written (extraKnownMarketplaces + enabledPlugins)" \
  "jq -e '.extraKnownMarketplaces[\"kickoff-local\"] and .enabledPlugins[\"kickoff@kickoff-local\"]==true' \"$SETTINGS\" >/dev/null"
chk "adopt: the operator's pre-existing settings.json key is PRESERVED (merge, not clobber)" \
  "jq -e '.permissions.allow[0]==\"Bash(ls:*)\"' \"$SETTINGS\" >/dev/null"
chk "adopt: manifest records the settings.json as json-merged WITH the pre-edit original bytes" \
  "python3 -c \"import json;e=[x for x in json.load(open('$MAN3'))['entries'] if x['path']=='.claude/settings.json'][0];assert e['action']=='json-merged' and e.get('original')\""
chk "adopt: manifest gains the machine plugin row (kickoff@kickoff-local, scope=project)" \
  "python3 -c \"import json;m=[x for x in json.load(open('$MAN3'))['machine_entries'] if x['plugin']=='kickoff'][0];assert m['marketplace']=='kickoff-local' and m['scope']=='project'\""
chk "adopt: the plugin cache is populated at cache/kickoff-local/kickoff/0.1.0/" \
  "[ -f \"$A3CFG/plugins/cache/kickoff-local/kickoff/0.1.0/.claude-plugin/plugin.json\" ]"
chk "adopt: settings.local.json is UNTOUCHED (no secret write; the plugin delivers the hook)" \
  "cmp -s \"$A3SNAP/settings.local.json\" \"$A3ADOPTER/.claude/settings.local.json\""
chk "adopt: NO hook-installed entry recorded (zero credential surface)" \
  "! python3 -c \"import json;assert any(e['action']=='hook-installed' for e in json.load(open('$MAN3'))['entries'])\" 2>/dev/null"
chk "adopt: the planted secret is ABSENT from the entire manifest (credential-safe)" \
  "! grep -qF '$PLANT' \"$MAN3\""
# Fix 1b (RED on pre-fix): adopt REGISTERS the adopter in the machine registry (not only pull does) —
# so an adopted-but-not-yet-pulled sibling is visible to another adopter's eject last-adopter check.
chk "adopt: registers the adopter in the machine registry (Fix 1b — 1 row @ core-vA) [RED on pre-fix]" \
  "[ \"\$(jq '.adopters|length' \"$A3REG\")\" = 1 ] && jq -e '.adopters[0].tag==\"core-vA\"' \"$A3REG\" >/dev/null"
chk "adopt: the registered adopter row points at THIS repo (realpath keyed)" \
  "[ \"\$(jq -r '.adopters[0].repo' \"$A3REG\")\" = \"\$(cd \"$A3ADOPTER\" && pwd -P)\" ]"
# ── the landed cmd_adopt seam deliverables (F1 §E/§G) — adopt now wires the FULL seam set, not just
#    the mc shim: 3 shims + the §G .kickoff/.gitignore + the §E split-charter pair. Assert each is
#    delivered on disk AND recorded with the right action/class (the eject spine + the seam-sync set).
chk "adopt: delivers the 3 seam shims, all executable (.kickoff/bin/{mc,scan-secrets,scan-structure})" \
  "[ -x \"$A3ADOPTER/.kickoff/bin/mc\" ] && [ -x \"$A3ADOPTER/.kickoff/bin/scan-secrets\" ] && [ -x \"$A3ADOPTER/.kickoff/bin/scan-structure\" ]"
chk "adopt: records all 3 shims created/seam in the manifest" \
  "python3 -c \"import json;e={x['path']:x for x in json.load(open('$MAN3'))['entries']};assert all(e.get('.kickoff/bin/'+s,{}).get('action')=='created' and e.get('.kickoff/bin/'+s,{}).get('class')=='seam' for s in ('mc','scan-secrets','scan-structure'))\""
chk "adopt: delivers + records the §G .kickoff/.gitignore (created/seam)" \
  "[ -f \"$A3ADOPTER/.kickoff/.gitignore\" ] && python3 -c \"import json;e=[x for x in json.load(open('$MAN3'))['entries'] if x['path']=='.kickoff/.gitignore'][0];assert e['action']=='created' and e['class']=='seam'\""
chk "adopt: delivers + records the §E split charter pair (KICKOFF.md seam + KICKOFF.local.md seeded-instance)" \
  "[ -f \"$A3ADOPTER/.kickoff/KICKOFF.md\" ] && [ -f \"$A3ADOPTER/.kickoff/KICKOFF.local.md\" ] && python3 -c \"import json;e={x['path']:x for x in json.load(open('$MAN3'))['entries']};assert e['.kickoff/KICKOFF.md']['class']=='seam' and e['.kickoff/KICKOFF.local.md']['class']=='seeded-instance'\""
# core.lock self-pin (§H) + the blank state seeds (§D) + the instance.env stamps (F1 item 4) — the rest
# of the landed cmd_adopt delivery, all leaving the target preflight-#6-ready without a second pull.
chk "adopt: self-pins .kickoff/core.lock (format 2 whole-tree pin @ core-vA)" \
  "[ -f \"$A3ADOPTER/.kickoff/core.lock\" ] && grep -qx 'format 2' \"$A3ADOPTER/.kickoff/core.lock\" && grep -qx 'tag core-vA' \"$A3ADOPTER/.kickoff/core.lock\""
chk "adopt: seeds the blank runtime/corpus state (mission-state.json + .kickoff/memory/MEMORY.md)" \
  "[ -f \"$A3ADOPTER/.kickoff/state/mission-control/mission-state.json\" ] && [ -f \"$A3ADOPTER/.kickoff/memory/MEMORY.md\" ]"
chk "adopt: stamps KICKOFF_CORE_DIR (=the pinned clone) + KICKOFF_CORE_REMOTE into the target instance.env" \
  "grep KICKOFF_CORE_DIR \"$A3ADOPTER/.kickoff/instance.env\" | grep -qF \"$A3CLONE\" && grep -q '^export KICKOFF_CORE_REMOTE=' \"$A3ADOPTER/.kickoff/instance.env\""
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "2a. §B — adopt CREATES .claude/settings.json → recorded created/live-config (preflight #8 EXCLUDES it)"
# ══════════════════════════════════════════════════════════════════════════════════════
# An adopter with NO pre-existing .claude/settings.json: the plugin flow CREATES it (the two plugin
# keys). kickoff records it action=created / class=live-config — NOT seam — because the LIVE system
# legitimately rewrites settings.json (the first accepted permission prompt). preflight #8 whole-file-
# hashes ONLY class=="seam", so it must EXCLUDE this file, else an accepted prompt would false-FAIL the
# preflight + brick the worker fail-closed. RED on pre-fix (a created settings.json was class=seam →
# hashed by #8). Isolated: stub claude + CLAUDE_CONFIG_DIR + an isolated adopters registry.
LC="$(mk)"; LCCLONE="$(mk)"; LCCFG="$(mk)"; LCSTUB="$(mk)"; LCREG="$(mk)/adopters.json"
write_stub_claude "$LCSTUB"
git clone -q "$FCORE" "$LCCLONE"; git -C "$LCCLONE" checkout -q --detach core-vA
mkdir -p "$LC/.kickoff/state" "$LC/memory"
git -C "$LC" init -q; git -C "$LC" config user.email t@t.t; git -C "$LC" config user.name t
printf '# memory index\n' > "$LC/memory/MEMORY.md"
git -C "$LC" add -A; git -C "$LC" commit -qm baseline
# NOTE: deliberately NO .claude/settings.json committed — adopt's plugin flow must CREATE it.
cat > "$LC/.kickoff/instance.env" <<EOF
export KICKOFF_CORE_DIR="$LCCLONE"
export KICKOFF_CORE_REMOTE="$FCORE"
export TELEGRAM_STATE_DIR="$LC/.kickoff/chan"
export MC_STATE_FILE="$LC/.kickoff/state/mission-state.json"
export MEMORY_DB="$LC/.kickoff/state/memory-index.db"
export MEMORY_HOOK_LOG="$LC/.kickoff/state/memory-hook.log"
EOF
KICKOFF_ADOPTERS_REGISTRY="$LCREG" KICKOFF_CORE_DIR="$LCCLONE" CLAUDE_CONFIG_DIR="$LCCFG" PATH="$LCSTUB:$PATH" \
  bash "$KICKOFF" adopt --dir "$LC" --accept </dev/null >/dev/null 2>&1 || true
LCMAN="$LC/.kickoff/adopt-manifest.json"
chk "2a: adopt CREATED .claude/settings.json (no pre-existing) carrying the two plugin keys" \
  "[ -f \"$LC/.claude/settings.json\" ] && jq -e '.extraKnownMarketplaces[\"kickoff-local\"] and .enabledPlugins[\"kickoff@kickoff-local\"]==true' \"$LC/.claude/settings.json\" >/dev/null"
chk "2a: the created settings.json is recorded action=created / class=live-config (NOT seam) [RED on pre-fix]" \
  "python3 -c \"import json;e=[x for x in json.load(open('$LCMAN'))['entries'] if x['path']=='.claude/settings.json'][0];assert e['action']=='created' and e['class']=='live-config'\""
chk "2a: preflight #8's class==seam+created hash selection EXCLUDES the live-config settings.json [RED on pre-fix]" \
  "! jq -r '.entries[]? | select(.class==\"seam\") | select(.action==\"created\") | .path' \"$LCMAN\" | grep -qx '.claude/settings.json'"
chk "2a: (control) the §G .gitignore + shims ARE in that same seam-hash selection (only live-config is excluded)" \
  "jq -r '.entries[]? | select(.class==\"seam\") | select(.action==\"created\") | .path' \"$LCMAN\" | grep -qx '.kickoff/.gitignore'"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "2b. Fix 3 — partial adopt (marketplace-add ok, install FAILS) rolls back the settings.json touch"
# ══════════════════════════════════════════════════════════════════════════════════════
# The review's exact repro: `claude plugin marketplace add --scope project` writes extraKnownMarket-
# places.<mkt> into .claude/settings.json IMMEDIATELY; if the next `claude plugin install` fails, the
# pre-fix code returned having recorded NOTHING → that edit was ORPHANED + unrecorded → eject (manifest
# -driven) could never reverse it → `git status` showed ` M .claude/settings.json`. The fix byte-
# restores settings.json on the install-failure branch. Stub here: add writes settings.json, install
# exits 1. RED on pre-fix (settings.json left dirty + the orphaned key survives). (brownfield-devex:
# the reporting-canon step still independently merges its own outputStyle key afterward — see the
# note at the assertions below — so settings.json is no longer byte-identical post-adopt, but the
# ORIGINAL invariant this test protects, no orphaned PLUGIN key survives a failed install, still holds.)
F3ADOPTER="$(mk)"; F3CLONE="$(mk)"; F3CFG="$(mk)"; F3STUB="$(mk)"; F3REG="$(mk)/adopters.json"
git clone -q "$FCORE" "$F3CLONE"; git -C "$F3CLONE" checkout -q --detach core-vA
mkdir -p "$F3ADOPTER/.claude" "$F3ADOPTER/.kickoff/state" "$F3ADOPTER/memory"
git -C "$F3ADOPTER" init -q; git -C "$F3ADOPTER" config user.email t@t.t; git -C "$F3ADOPTER" config user.name t
printf '# memory index\n' > "$F3ADOPTER/memory/MEMORY.md"
# a PRE-EXISTING, non-jq-canonical settings.json (4-space) — the byte-restore target
printf '{\n    "permissions": {\n        "allow": ["Bash(ls:*)"]\n    }\n}\n' > "$F3ADOPTER/.claude/settings.json"
git -C "$F3ADOPTER" add -A; git -C "$F3ADOPTER" commit -qm baseline
F3PRE="$(mk)/pre-settings.json"; cp "$F3ADOPTER/.claude/settings.json" "$F3PRE"
cat > "$F3ADOPTER/.kickoff/instance.env" <<EOF
export KICKOFF_CORE_DIR="$F3CLONE"
export KICKOFF_CORE_REMOTE="$FCORE"
export TELEGRAM_STATE_DIR="$F3ADOPTER/.kickoff/chan"
export MC_STATE_FILE="$F3ADOPTER/.kickoff/state/mission-state.json"
export MEMORY_DB="$F3ADOPTER/.kickoff/state/memory-index.db"
export MEMORY_HOOK_LOG="$F3ADOPTER/.kickoff/state/memory-hook.log"
EOF
# a stub whose marketplace-add WRITES settings.json (extraKnownMarketplaces, 2-space reindent — as
# real claude does) then install EXITS 1. Isolation-guarded (refuses without CLAUDE_CONFIG_DIR).
cat > "$F3STUB/claude" <<'PYEOF'
#!/usr/bin/env python3
import json, os, sys, tempfile
if not os.environ.get("CLAUDE_CONFIG_DIR"): sys.exit(3)   # never touch a real ~/.claude
def _assert_tmp(p):   # STUB GUARD (§5 fix-round-3): refuse a project settings.json write outside a temp dir
    rp = os.path.realpath(p)
    roots = {os.path.realpath(r) for r in (tempfile.gettempdir(), os.environ.get("TMPDIR"), "/tmp") if r}
    if not any(rp == root or rp.startswith(root + os.sep) for root in roots):
        sys.stderr.write("stub: REFUSING a project settings.json write outside a temp dir: %s (isolation guard)\n" % rp); sys.exit(4)
a = sys.argv[1:]
if len(a) >= 3 and a[0] == "plugin" and a[1] == "marketplace" and a[2] == "add":
    p = os.path.join(os.getcwd(), ".claude", "settings.json")
    _assert_tmp(p)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    try: d = json.load(open(p))
    except Exception: d = {}
    d.setdefault("extraKnownMarketplaces", {})["kickoff-local"] = {"source": {"source": "directory", "path": "x"}}
    json.dump(d, open(p, "w"), indent=2)   # re-indents 4-space → 2-space, like real claude
    print("added"); sys.exit(0)
if len(a) >= 2 and a[0] == "plugin" and a[1] in ("install", "i"):
    sys.stderr.write("stub: install deliberately fails\n"); sys.exit(1)
sys.exit(0)   # marketplace remove (the rollback's tidy step) etc. → no-op success
PYEOF
chmod +x "$F3STUB/claude"
KICKOFF_ADOPTERS_REGISTRY="$F3REG" KICKOFF_CORE_DIR="$F3CLONE" CLAUDE_CONFIG_DIR="$F3CFG" PATH="$F3STUB:$PATH" \
  bash "$KICKOFF" adopt --dir "$F3ADOPTER" --accept </dev/null >/dev/null 2>&1 || true
# NOTE (brownfield-devex): the reporting-canon step (_adopt_wire_output_style) runs AFTER the plugin
# step and is INDEPENDENT of it — it still merges its own \`outputStyle\` key even when the plugin
# install above failed and rolled back. So settings.json is no longer byte-IDENTICAL to pre-adopt —
# but the invariant this test exists to protect (no ORPHANED PLUGIN edit survives a failed install)
# still holds exactly: the operator's original keys are untouched and NEITHER plugin key appears.
chk "Fix3: the operator's original permissions key SURVIVES a failed install untouched" \
  "[ \"\$(jq -c '.permissions' "$F3ADOPTER/.claude/settings.json")\" = '{\"allow\":[\"Bash(ls:*)\"]}' ]"
chk "Fix3: no orphaned extraKnownMarketplaces key survived the failed adopt [RED on pre-fix]" \
  "! jq -e '.extraKnownMarketplaces' \"$F3ADOPTER/.claude/settings.json\" >/dev/null 2>&1"
chk "Fix3: no orphaned enabledPlugins key survived the failed adopt [RED on pre-fix]" \
  "! jq -e '.enabledPlugins' \"$F3ADOPTER/.claude/settings.json\" >/dev/null 2>&1"
chk "Fix3: the independent outputStyle merge STILL landed (a failed plugin install must not block it)" \
  "[ \"\$(jq -r '.outputStyle' "$F3ADOPTER/.claude/settings.json")\" = 'Plain Report' ]"
chk "Fix3: the manifest recorded EXACTLY ONE settings.json entry — the outputStyle merge, never the rolled-back plugin keys" \
  "python3 -c \"
import json
m = json.load(open('$F3ADOPTER/.kickoff/adopt-manifest.json'))
rows = [e for e in m.get('entries', []) if e['path'] == '.claude/settings.json']
assert len(rows) == 1, rows
assert rows[0]['action'] == 'json-merged', rows
\""
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "2c. Fix A — install-fail rollback when the BARE mktemp fails MUST NOT delete a pre-existing settings.json"
# ══════════════════════════════════════════════════════════════════════════════════════
# The re-review's MEDIUM data-loss repro: `_adopt_enable_plugin` captures the pre-edit settings.json
# via a BARE `pre="$(mktemp)"` (kickoff:660). On a broken/full/misconfigured $TMPDIR the bare mktemp
# FAILS → existed=1 but pre="". Pre-fix, the install-failure rollback guard `[ existed=1 ] && [ -n
# "$pre" ]` was then FALSE → it fell to `rm -f "$settings"`, DELETING the operator's pre-existing
# settings.json (permissions/MCP/hooks/env) and logging the misleading "created". The fix keys the
# DELETE on existed=0 ALONE and WARN-and-LEAVEs a pre-existing file when there is no valid backup.
# Repro: PATH-shim a `mktemp` that FAILS the bare (TMPDIR) call but DELEGATES templated calls, a stub
# claude whose marketplace-add writes settings.json then install exits 1, and a COMMITTED settings.json
# → after adopt, settings.json SURVIVES (pre-fix: ` D .claude/settings.json`).
FAADOPTER="$(mk)"; FACLONE="$(mk)"; FACFG="$(mk)"; FASTUB="$(mk)"; FAMTBIN="$(mk)"; FAREG="$(mk)/adopters.json"
git clone -q "$FCORE" "$FACLONE"; git -C "$FACLONE" checkout -q --detach core-vA
mkdir -p "$FAADOPTER/.claude" "$FAADOPTER/.kickoff/state" "$FAADOPTER/memory"
git -C "$FAADOPTER" init -q; git -C "$FAADOPTER" config user.email t@t.t; git -C "$FAADOPTER" config user.name t
printf '# memory index\n' > "$FAADOPTER/memory/MEMORY.md"
# a PRE-EXISTING, COMMITTED settings.json carrying the operator's REAL config (permissions + env)
printf '{\n    "permissions": {\n        "allow": ["Bash(ls:*)"]\n    },\n    "env": {\n        "FOO": "bar"\n    }\n}\n' > "$FAADOPTER/.claude/settings.json"
git -C "$FAADOPTER" add -A; git -C "$FAADOPTER" commit -qm baseline
cat > "$FAADOPTER/.kickoff/instance.env" <<EOF
export KICKOFF_CORE_DIR="$FACLONE"
export KICKOFF_CORE_REMOTE="$FCORE"
export TELEGRAM_STATE_DIR="$FAADOPTER/.kickoff/chan"
export MC_STATE_FILE="$FAADOPTER/.kickoff/state/mission-state.json"
export MEMORY_DB="$FAADOPTER/.kickoff/state/memory-index.db"
export MEMORY_HOOK_LOG="$FAADOPTER/.kickoff/state/memory-hook.log"
EOF
# stub claude: marketplace-add WRITES settings.json (preserving existing keys, like real claude), then
# install EXITS 1 → drives the rollback branch. Isolation-guarded (refuses without CLAUDE_CONFIG_DIR).
cat > "$FASTUB/claude" <<'PYEOF'
#!/usr/bin/env python3
import json, os, sys, tempfile
if not os.environ.get("CLAUDE_CONFIG_DIR"): sys.exit(3)   # never touch a real ~/.claude
def _assert_tmp(p):   # STUB GUARD (§5 fix-round-3): refuse a project settings.json write outside a temp dir
    rp = os.path.realpath(p)
    roots = {os.path.realpath(r) for r in (tempfile.gettempdir(), os.environ.get("TMPDIR"), "/tmp") if r}
    if not any(rp == root or rp.startswith(root + os.sep) for root in roots):
        sys.stderr.write("stub: REFUSING a project settings.json write outside a temp dir: %s (isolation guard)\n" % rp); sys.exit(4)
a = sys.argv[1:]
if len(a) >= 3 and a[0] == "plugin" and a[1] == "marketplace" and a[2] == "add":
    p = os.path.join(os.getcwd(), ".claude", "settings.json")
    _assert_tmp(p)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    try: d = json.load(open(p))
    except Exception: d = {}
    d.setdefault("extraKnownMarketplaces", {})["kickoff-local"] = {"source": {"source": "directory", "path": "x"}}
    json.dump(d, open(p, "w"), indent=2)   # re-indents + adds the key, preserving permissions/env
    print("added"); sys.exit(0)
if len(a) >= 2 and a[0] == "plugin" and a[1] in ("install", "i"):
    sys.stderr.write("stub: install deliberately fails\n"); sys.exit(1)
sys.exit(0)   # marketplace remove (rollback's tidy step) etc. → no-op success
PYEOF
chmod +x "$FASTUB/claude"
# the mktemp PATH-shim: FAIL the bare (TMPDIR) call — the exact broken-$TMPDIR corner — but DELEGATE
# any TEMPLATED call (an arg containing XXX, e.g. kickoff's .instance.env.XXXXXX) to the real mktemp,
# so the rest of adopt is unaffected. Reads the REAL mktemp path from $FAKE_REAL_MKTEMP at runtime.
cat > "$FAMTBIN/mktemp" <<'MTEOF'
#!/usr/bin/env bash
for _a in "$@"; do
  case "$_a" in *XXX*) exec "${FAKE_REAL_MKTEMP:-/usr/bin/mktemp}" "$@" ;; esac
done
echo "fake-mktemp: simulated TMPDIR failure (Fix A repro)" >&2
exit 1
MTEOF
chmod +x "$FAMTBIN/mktemp"
FA_REAL_MKTEMP="$(command -v mktemp)"
FAOUT="$(FAKE_REAL_MKTEMP="$FA_REAL_MKTEMP" KICKOFF_ADOPTERS_REGISTRY="$FAREG" KICKOFF_CORE_DIR="$FACLONE" \
  CLAUDE_CONFIG_DIR="$FACFG" PATH="$FAMTBIN:$FASTUB:$PATH" \
  bash "$KICKOFF" adopt --dir "$FAADOPTER" --accept </dev/null 2>&1)" || true
chk "FixA: the bare mktemp actually FAILED (capture warned it could not back up settings.json)" \
  "printf '%s' \"\$FAOUT\" | grep -qi 'could not back up the pre-existing'"
chk "FixA: settings.json SURVIVES the mktemp-fail rollback — NOT deleted [RED on pre-fix: ' D']" \
  "[ -f \"$FAADOPTER/.claude/settings.json\" ]"
chk "FixA: git does NOT show settings.json DELETED (no ' D .claude/settings.json') [RED on pre-fix]" \
  "! git -C \"$FAADOPTER\" status --porcelain -- .claude/settings.json | grep -q '^ D'"
chk "FixA: the operator's REAL config survived (permissions.allow + env.FOO intact)" \
  "jq -e '.permissions.allow[0]==\"Bash(ls:*)\" and .env.FOO==\"bar\"' \"$FAADOPTER/.claude/settings.json\" >/dev/null"
chk "FixA: rollback WARNS it LEFT the file (recoverable orphan), not the misleading 'created' delete [RED on pre-fix]" \
  "printf '%s' \"\$FAOUT\" | grep -qi 'recoverable orphan' && ! printf '%s' \"\$FAOUT\" | grep -qi 'removed the .claude/settings.json that marketplace-add created'"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "3. Slice 4 — pull re-syncs the plugin cache (mechanism A/B + dogfood zero-invocation)"
# ══════════════════════════════════════════════════════════════════════════════════════
# Reuse the adopted@vA case (cache@0.1.0), then `kickoff pull core-vB` (plugin 0.2.0). Step 4c runs
# mechanism A (installed 0.1.0 ≠ pinned 0.2.0) → cache re-synced to 0.2.0 with FRESH content.
read -r P4CLONE P4ADOPTER P4CFG P4SNAP P4STUB P4REG <<< "$(build_adopted_case "$FCORE")"
P4LOG="$(mk)/stub.log"
KICKOFF_ADOPTERS_REGISTRY="$P4REG" KICKOFF_CORE_DIR="$P4CLONE" CLAUDE_CONFIG_DIR="$P4CFG" \
  CLAUDE_STUB_LOG="$P4LOG" PATH="$P4STUB:$PATH" REPO_DIR="$P4ADOPTER" \
  bash "$KICKOFF" pull core-vB >/dev/null 2>&1 || true
chk "pull(vB): cache re-synced to the 0.2.0 version dir" \
  "[ -f \"$P4CFG/plugins/cache/kickoff-local/kickoff/0.2.0/.claude-plugin/plugin.json\" ]"
chk "pull(vB): the re-synced cache carries the FRESH vB content (marker VB, not VA)" \
  "grep -q 'VB' \"$P4CFG/plugins/cache/kickoff-local/kickoff/0.2.0/skills/scan/SKILL.md\" && ! grep -q 'VA' \"$P4CFG/plugins/cache/kickoff-local/kickoff/0.2.0/skills/scan/SKILL.md\""
chk "pull(vB): mechanism A used the SCOPED plugin update (marketplace update + update --scope project) [Fix 2, RED on pre-fix]" \
  "grep -q 'marketplace update kickoff-local' \"$P4LOG\" && grep -q 'update --scope project kickoff@kickoff-local' \"$P4LOG\""
# THE INVARIANT: the adopter's OWN layer is byte-identical after the pull
chk "pull(vB) UNTOUCHED: settings.local.json byte-identical (cmp -s)" \
  "cmp -s \"$P4SNAP/settings.local.json\" \"$P4ADOPTER/.claude/settings.local.json\""
chk "pull(vB) UNTOUCHED: the operator's CLAUDE.md byte-identical (cmp -s)" \
  "cmp -s \"$P4SNAP/CLAUDE.md\" \"$P4ADOPTER/CLAUDE.md\""
chk "pull(vB) UNTOUCHED: the operator's owned source byte-identical (cmp -s)" \
  "cmp -s \"$P4SNAP/app.txt\" \"$P4ADOPTER/src/app.txt\""
chk "pull(vB) UNTOUCHED: KICKOFF.local.md byte-identical (cmp -s)" \
  "cmp -s \"$P4SNAP/KICKOFF.local.md\" \"$P4ADOPTER/.kickoff/KICKOFF.local.md\""
chk "pull(vB) CREDENTIAL-SAFE: the planted secret is ABSENT from the stub/pull log" \
  "! grep -qF '$PLANT' \"$P4LOG\""

# ── G7 VERIFY-FIRST — a healthy same-version re-pull is ZERO CHURN ─────────────────────────────────
# The pre-G7 code fired mechanism B (uninstall+install) on EVERY same-tag re-pull — an uninstall that
# SWEEPS ALL version dirs of the SHARED user-global cache, then a reinstall. G7 added verify-first: a
# re-pull whose cache already byte-matches the pinned tag drives ZERO `claude` calls (true idempotence,
# no destructive churn of the shared cache). The mechanism-A pull above left the cache at 0.2.0 AND
# byte-matching the pinned $P4CLONE/plugin@core-vB, so this second pull vB must resync NOTHING.
P4LOG2="$(mk)/stub2.log"
KICKOFF_ADOPTERS_REGISTRY="$P4REG" KICKOFF_CORE_DIR="$P4CLONE" CLAUDE_CONFIG_DIR="$P4CFG" \
  CLAUDE_STUB_LOG="$P4LOG2" PATH="$P4STUB:$PATH" REPO_DIR="$P4ADOPTER" \
  bash "$KICKOFF" pull core-vB >/dev/null 2>&1 || true
chk "pull(vB again, matching cache): ZERO-CHURN — verify-first skips the resync (NO uninstall/install in the stub log) [RED on pre-G7 every-re-pull churn]" \
  "! grep -q 'uninstall --scope project kickoff@kickoff-local' \"$P4LOG2\" && ! grep -q 'install --scope project kickoff@kickoff-local' \"$P4LOG2\""
chk "pull(vB again, matching cache): the cache is left intact at 0.2.0 (the skipped resync touched nothing)" \
  "[ -f \"$P4CFG/plugins/cache/kickoff-local/kickoff/0.2.0/.claude-plugin/plugin.json\" ]"

# ── mechanism B fires ONLY on same-version CONTENT DIVERGENCE ──────────────────────────────────────
# Verify-first skips a MATCHING cache — but a same-version cache that has DRIFTED (a stale / corrupted
# cached file) must still re-converge. Corrupt a byte of a cached file (the exact technique the Slice-5
# `plugin-cache-verify: an EDITED cache file FAILS` case proves trips the hash), then re-pull vB:
# verify-first now FAILS → sole adopter + installed==pinned (0.2.0) → mechanism B (reinstall) fires ONCE,
# and its fresh install re-converges the cache byte-for-byte (the TAMPER byte gone).
printf 'TAMPER-VB\n' >> "$P4CFG/plugins/cache/kickoff-local/kickoff/0.2.0/skills/scan/SKILL.md"
chk "pull(vB, divergence precondition): the corrupted cache FAILS plugin-cache-verify (so verify-first WON'T skip — the resync must run)" \
  "! python3 \"$AM\" plugin-cache-verify --repo \"$P4ADOPTER\" --core-dir \"$P4CLONE\" --config-dir \"$P4CFG\""
P4LOG3="$(mk)/stub3.log"
KICKOFF_ADOPTERS_REGISTRY="$P4REG" KICKOFF_CORE_DIR="$P4CLONE" CLAUDE_CONFIG_DIR="$P4CFG" \
  CLAUDE_STUB_LOG="$P4LOG3" PATH="$P4STUB:$PATH" REPO_DIR="$P4ADOPTER" \
  bash "$KICKOFF" pull core-vB >/dev/null 2>&1 || true
chk "pull(vB, diverged cache): mechanism B — SCOPED uninstall+install (--scope project) in the stub log [Fix 2, RED on pre-fix]" \
  "grep -q 'uninstall --scope project kickoff@kickoff-local' \"$P4LOG3\" && grep -q 'install --scope project kickoff@kickoff-local' \"$P4LOG3\""
chk "pull(vB, diverged cache): mechanism B RE-CONVERGED the cache — plugin-cache-verify passes again (the TAMPER byte is gone)" \
  "python3 \"$AM\" plugin-cache-verify --repo \"$P4ADOPTER\" --core-dir \"$P4CLONE\" --config-dir \"$P4CFG\""

# ── F2 (Phase-2 envelope): mechanism-B's re-enable on a pre-CLEAN settings.json PERSISTS ───────────
# The envelope decides rehash-vs-keep from the PRE-resync RECORD state (never an intent flag). Build
# the one state the old INTENDED-only envelope got WRONG: a settings.json that is CLEAN (== its
# recorded sha256_at_write) but does NOT carry the enablement — strip enabledPlugins, then
# legitimately re-record the stripped hash via the narrow rehash-path verb (the file is now
# pre-CLEAN + disabled). Corrupt the cache so verify-first cannot skip → mechanism B (uninstall+
# install) re-enables the plugin as kickoff's OWN legitimate write. THE RED ASSERTION (fails on the
# pre-fix envelope, which re-asserted the pre-resync snapshot and so silently UNDID the re-enable —
# pull claimed "resynced ✓" while the interactive plugin stayed DISABLED): the enablement PERSISTS
# in the FINAL state. Companion: the record is REHASHED to the kept bytes (file==record — eject's
# hash gate stays TRUE, its byte-restore of the pre-adopt original stays valid).
P4F2TMP="$(mk)/stripped.json"
jq 'del(.enabledPlugins)' "$P4ADOPTER/.claude/settings.json" > "$P4F2TMP" && mv "$P4F2TMP" "$P4ADOPTER/.claude/settings.json"
python3 "$AM" rehash-path --repo "$P4ADOPTER" --path .claude/settings.json >/dev/null 2>&1 || true
chk "F2 precondition: settings.json is pre-CLEAN (file==record after rehash-path) AND the plugin is NOT enabled in it" \
  "python3 -c \"import json,hashlib;m=json.load(open('$P4ADOPTER/.kickoff/adopt-manifest.json'));e=[x for x in m['entries'] if x['path']=='.claude/settings.json'][0];h=hashlib.sha256(open('$P4ADOPTER/.claude/settings.json','rb').read()).hexdigest();assert e['sha256_at_write']==h\" && ! jq -e '.enabledPlugins' \"$P4ADOPTER/.claude/settings.json\" >/dev/null 2>&1"
printf 'TAMPER-F2\n' >> "$P4CFG/plugins/cache/kickoff-local/kickoff/0.2.0/skills/scan/SKILL.md"
P4LOG4="$(mk)/stub4.log"
KICKOFF_ADOPTERS_REGISTRY="$P4REG" KICKOFF_CORE_DIR="$P4CLONE" CLAUDE_CONFIG_DIR="$P4CFG" \
  CLAUDE_STUB_LOG="$P4LOG4" PATH="$P4STUB:$PATH" REPO_DIR="$P4ADOPTER" \
  bash "$KICKOFF" pull core-vB >/dev/null 2>&1 || true
chk "F2: mechanism B fired on the pre-CLEAN file (scoped uninstall+install in the stub log)" \
  "grep -q 'uninstall --scope project kickoff@kickoff-local' \"$P4LOG4\" && grep -q 'install --scope project kickoff@kickoff-local' \"$P4LOG4\""
chk "F2: the re-enable PERSISTS — enabledPlugins TRUE in the FINAL settings.json (pre-clean → rehash keeps kickoff's own write; NOT undone by a reassert) [RED on the pre-fix INTENDED-only envelope]" \
  "jq -e '.enabledPlugins[\"kickoff@kickoff-local\"]==true' \"$P4ADOPTER/.claude/settings.json\" >/dev/null"
chk "F2: the record was REHASHED to the kept bytes (file==record — eject's hash gate + byte-restore stay valid)" \
  "python3 -c \"import json,hashlib;m=json.load(open('$P4ADOPTER/.kickoff/adopt-manifest.json'));e=[x for x in m['entries'] if x['path']=='.claude/settings.json'][0];h=hashlib.sha256(open('$P4ADOPTER/.claude/settings.json','rb').read()).hexdigest();assert e['sha256_at_write']==h\""

# ── §5 fix-round-3 (RED on pre-fix): pull resync targets the ADOPTER repo, NEVER the invocation cwd ──
# THE BUG: `claude plugin <op> --scope project` resolves "project" relative to $PWD/.claude/settings.json.
# _resync_plugin_cache did NOT cd to the adopter, so a `kickoff pull` whose invocation cwd ≠ the adopter
# wrote the adopter's enablement (mechanism B's `install --scope project`) into the WRONG project's
# settings.json — a live-config mutation of whatever repo the pull ran from (the repo root, the read-only
# core clone, $HOME…). Repro: a FRESH adopted@vA case, then `kickoff pull core-vA` (installed==pinned →
# mechanism B) run FROM a scratch INVOKE dir that is NOT the adopter. Fixed: the resync's `--scope project`
# write lands in the ADOPTER; the INVOKE cwd stays clean. (The INVOKE dir is a mktemp temp dir, so on
# pre-fix the leak is captured SAFELY there — never a real repo — which is what the NO-cwd-leak assertion
# below detects: it is RED on the pre-cwd-fix code.)
# TWO G7 interactions shape how this is OBSERVED on the current engine:
#   • VERIFY-FIRST would SKIP a matching cache (zero churn) → mechanism B never runs → nothing to observe.
#     So we first DIVERGE the cache (corrupt a cached byte, the Slice-5 technique) → verify-first fails →
#     the resync genuinely RUNS mechanism B.
#   • SETTINGS-INTEGRITY (the Phase-2 envelope, kickoff cmd_pull): the STRIP below diverges the file
#     from its recorded sha256_at_write, so the envelope classifies it pre-DIVERGED → the pull KEEPS
#     the CLI's final bytes, mechanism B's re-enable INCLUDED (F1/F2: never reassert over a legitimate
#     re-enable, never rehash over an operator edit). So the original "regains enabledPlugins" check
#     holds again AND now also proves the re-enable PERSISTS in the final state; the record is NOT
#     rehashed (no laundering), so a later eject KEEPS this file (no-clobber) instead of byte-restoring
#     the pre-adopt original over the operator's strip.
read -r CWCLONE CWADOPTER CWCFG _CWSNAP CWSTUB CWREG <<< "$(build_adopted_case "$FCORE")"
CWINVOKE="$(mk)"                       # the invocation cwd — a scratch dir that is NOT the adopter repo
CWLOG="$(mk)/stub.log"
# strip the adopter's enabledPlugins (adopt pre-set it) — an OPERATOR edit that (a) makes the resync's
# re-enablement observable as absent→present and (b) diverges the file from its record, exercising the
# envelope's pre-DIVERGED branch (keep the CLI's bytes; never rehash the record over them).
CWTMP="$(mk)/stripped.json"
jq 'del(.enabledPlugins)' "$CWADOPTER/.claude/settings.json" > "$CWTMP" && mv "$CWTMP" "$CWADOPTER/.claude/settings.json"
CWREC0="$(python3 -c "import json;m=json.load(open('$CWADOPTER/.kickoff/adopt-manifest.json'));e=[x for x in m['entries'] if x['path']=='.claude/settings.json'][0];print(e['sha256_at_write'])" 2>/dev/null || true)"
chk "cwd-leak precondition: the adopter's enabledPlugins was stripped (so the resync's re-enablement is observable)" \
  "! jq -e '.enabledPlugins' \"$CWADOPTER/.claude/settings.json\" >/dev/null 2>&1"
# DIVERGE the cache (G7): a matching cache would be skipped by verify-first (zero churn) → mechanism B
# would never fire. Corrupt a cached byte so verify-first FAILS → the resync RUNS → the cwd-targeting is
# observable. installed==pinned (0.1.0) + sole adopter → mechanism B (uninstall+install --scope project).
printf 'TAMPER-CW\n' >> "$CWCFG/plugins/cache/kickoff-local/kickoff/0.1.0/skills/scan/SKILL.md"
chk "cwd-leak precondition: the corrupted cache FAILS plugin-cache-verify (so verify-first WON'T skip — mechanism B must fire)" \
  "! python3 \"$AM\" plugin-cache-verify --repo \"$CWADOPTER\" --core-dir \"$CWCLONE\" --config-dir \"$CWCFG\""
# run the pull FROM the INVOKE cwd (≠ adopter), REPO_DIR=the adopter. installed==pinned (0.1.0) → mech B.
( cd "$CWINVOKE" && KICKOFF_ADOPTERS_REGISTRY="$CWREG" KICKOFF_CORE_DIR="$CWCLONE" CLAUDE_CONFIG_DIR="$CWCFG" \
    CLAUDE_STUB_LOG="$CWLOG" PATH="$CWSTUB:$PATH" REPO_DIR="$CWADOPTER" \
    bash "$KICKOFF" pull core-vA >/dev/null 2>&1 ) || true
chk "cwd-leak: mechanism B fired (scoped uninstall+install in the stub log — the resync ran) [Fix 2, RED on pre-fix]" \
  "grep -q 'uninstall --scope project kickoff@kickoff-local' \"$CWLOG\" && grep -q 'install --scope project kickoff@kickoff-local' \"$CWLOG\""
chk "cwd-leak: mechanism B ran END-TO-END — plugin-cache-verify passes again (the reinstall's --scope project write executed, so a project-settings write DID happen)" \
  "python3 \"$AM\" plugin-cache-verify --repo \"$CWADOPTER\" --core-dir \"$CWCLONE\" --config-dir \"$CWCFG\""
chk "cwd-leak: NO .claude/settings.json leaked into the invocation cwd — that --scope project write targeted the ADOPTER, not the cwd [RED on pre-cwd-fix]" \
  "[ ! -f \"$CWINVOKE/.claude/settings.json\" ]"
chk "cwd-leak (F2): the ADOPTER's settings.json regained enabledPlugins — the resync targeted the ADOPTER and the re-enable PERSISTS (pre-diverged → keep; NOT undone by a reassert) [RED on the pre-fix reassert-over-re-enable envelope]" \
  "jq -e '.enabledPlugins[\"kickoff@kickoff-local\"]==true' \"$CWADOPTER/.claude/settings.json\" >/dev/null"
chk "cwd-leak (F1 no-launder): the RECORD is UNCHANGED across the pull — the pre-diverged file was never rehashed (an operator edit can never be laundered into eject's byte-restore). (Here the stub's canonical re-serialization makes the CLI's final bytes byte-converge BACK to the recorded state — benign; the invariant under test is that the record itself never moved.)" \
  "[ -n \"$CWREC0\" ] && python3 -c \"import json;m=json.load(open('$CWADOPTER/.kickoff/adopt-manifest.json'));e=[x for x in m['entries'] if x['path']=='.claude/settings.json'][0];assert e['sha256_at_write']=='$CWREC0'\""
echo

# ── DOGFOOD-SAFETY: a no-machine-entry adopter → pull drives ZERO `claude` invocations ──
# A fixture with an instance.env + core.lock but NO plugin machine entry (like kickoff-itself /
# a headless-only adopter). plugin-list is EMPTY → step 4c skips entirely → the stub is never run.
DF="$(mk)"; DFCLONE="$(mk)"; DFCFG="$(mk)"; DFLOG="$(mk)/stub.log"; DFSTUB="$(mk)"; DFREG="$(mk)/adopters.json"
write_stub_claude "$DFSTUB"
git clone -q "$FCORE" "$DFCLONE"; git -C "$DFCLONE" checkout -q --detach core-vA
mkdir -p "$DF/.kickoff/state" "$DF/memory"
printf '# memory index\n' > "$DF/memory/MEMORY.md"
cat > "$DF/.kickoff/instance.env" <<EOF
export KICKOFF_CORE_DIR="$DFCLONE"
export KICKOFF_CORE_REMOTE="$FCORE"
export TELEGRAM_STATE_DIR="$DF/.kickoff/chan"
export MC_STATE_FILE="$DF/.kickoff/state/mission-state.json"
export MEMORY_DB="$DF/.kickoff/state/memory-index.db"
export MEMORY_HOOK_LOG="$DF/.kickoff/state/memory-hook.log"
EOF
# a manifest with NO machine entry (an entries-only adopter) — the gate must skip the plugin step
python3 "$DFCLONE/scripts/adopt-manifest.py" gen-shim --repo "$DF" --name mc --source core-vA >/dev/null 2>&1 || true
: > "$DFLOG"   # ensure the log starts empty
KICKOFF_ADOPTERS_REGISTRY="$DFREG" KICKOFF_CORE_DIR="$DFCLONE" CLAUDE_CONFIG_DIR="$DFCFG" \
  CLAUDE_STUB_LOG="$DFLOG" PATH="$DFSTUB:$PATH" REPO_DIR="$DF" \
  bash "$KICKOFF" pull core-vB >/dev/null 2>&1 || true
chk "DOGFOOD: a no-machine-entry adopter drives ZERO \`claude\` invocations on pull (stub log empty)" \
  "[ ! -s \"$DFLOG\" ]"
chk "DOGFOOD: no plugin cache was created for the no-machine-entry adopter (inert)" \
  "[ ! -d \"$DFCFG/plugins/cache\" ]"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "3b. #8 — install-row sole-consumer gate (headless-only sibling convergence)"
# ══════════════════════════════════════════════════════════════════════════════════════
# THE INCIDENT (a prior adopter, core-v0.5): the G7 sibling gate read the machine ADOPTERS
# REGISTRY ("who adopted the core on this box") — but the safety invariant for mechanism B's
# uninstall/reinstall sweep is "who CONSUMES the shared interactive cache", i.e. who holds a
# kickoff@kickoff-local install row in THIS config dir's installed_plugins.json. A registered
# HEADLESS-ONLY sibling (NO install row; its worker execs source via --plugin-dir, never this
# cache) made `adopters-others` non-empty → mechanism A → the same-version `update` no-ops → a
# plain pull REFUSED to converge FOREVER (the operator needed a hand-built fix). The
# MIRROR hole: an interactive consumer NOT in the registry (registry rows are best-effort) was
# INVISIBLE to the registry query → the old gate read "positively sole" and SWEPT its live cache.
# The fix reads the install rows themselves (`plugin-consumers-others`): a consumer of THIS cache
# is by construction a row in THIS installed_plugins.json — rc0+EMPTY ⇒ positively sole.

# ── the verb itself (fail-closed semantics, hand-built installed_plugins.json fixtures) ──
PC="$(mk)"; PCADOPTER="$PC/adopter"; PCOTHER="$PC/other"; PCCFG="$PC/cfg"; PCLINK="$PC/link"
mkdir -p "$PCADOPTER" "$PCOTHER" "$PCCFG/plugins"
ln -s "$PCADOPTER" "$PCLINK"
PCSELF="$(cd "$PCADOPTER" && pwd -P)"; PCOTHERP="$(cd "$PCOTHER" && pwd -P)"
pc_rows() {   # $1 = the JSON rows array for kickoff@kickoff-local
  printf '{ "version": 2, "plugins": { "kickoff@kickoff-local": %s } }\n' "$1" \
    > "$PCCFG/plugins/installed_plugins.json"
}
pc_q() { python3 "$AM" plugin-consumers-others --repo "$PCADOPTER" --config-dir "$PCCFG" \
           --marketplace kickoff-local --plugin kickoff; }
pc_rows "[ {\"scope\":\"project\",\"projectPath\":\"$PCSELF\",\"installPath\":\"/x\",\"version\":\"0.1.0\"} ]"
chk "verb: self-only project row ⇒ rc0 + EMPTY (positively the sole consumer) [RED on pre-fix: verb absent]" \
  "OUT=\$(pc_q) && [ -z \"\$OUT\" ]"
chk "verb: self-match is realpath-keyed (querying via a symlink spelling of the adopter still ⇒ sole)" \
  "OUT=\$(python3 \"$AM\" plugin-consumers-others --repo \"$PCLINK\" --config-dir \"$PCCFG\" --marketplace kickoff-local --plugin kickoff) && [ -z \"\$OUT\" ]"
pc_rows "[ {\"scope\":\"project\",\"projectPath\":\"$PCSELF\",\"installPath\":\"/x\",\"version\":\"0.1.0\"}, {\"scope\":\"project\",\"projectPath\":\"$PCOTHERP\",\"installPath\":\"/y\",\"version\":\"0.1.0\"} ]"
chk "verb: another project's install row ⇒ NON-empty, naming its realpath (not sole)" \
  "pc_q | grep -qxF \"$PCOTHERP\""
pc_rows "[ {\"scope\":\"project\",\"installPath\":\"/x\",\"version\":\"0.1.0\"} ]"
chk "verb: a project-scope row MISSING projectPath (older claude) ⇒ an UNKNOWN other consumer (fail-closed)" \
  "pc_q | grep -qi 'NO projectPath'"
pc_rows "[ {\"scope\":\"project\",\"projectPath\":\"$PCSELF\",\"installPath\":\"/x\",\"version\":\"0.1.0\"}, {\"scope\":\"user\",\"installPath\":\"/y\",\"version\":\"0.1.0\"} ]"
chk "verb: a user-scope row (no projectPath, same shared cache) ⇒ counted as an other consumer" \
  "pc_q | grep -q 'scope=user'"
printf 'not json\n' > "$PCCFG/plugins/installed_plugins.json"
chk "verb: a CORRUPT installed_plugins.json is FATAL (rc≠0 — NEVER provably sole)" \
  "! pc_q"
rm -f "$PCCFG/plugins/installed_plugins.json"
chk "verb: a MISSING installed_plugins.json ⇒ rc0 + EMPTY (no consumers at all)" \
  "OUT=\$(pc_q) && [ -z \"\$OUT\" ]"

# ── H1 [RED on pre-fix]: a HEADLESS-ONLY registered sibling no longer blocks convergence ──
# The incident topology: this adopter is the sole INTERACTIVE consumer (its install row is the
# only one), but a headless-only sibling sits in the adopters REGISTRY (no install row — it never
# reads the cache). Same-version content drift (TAMPER, installed==pinned 0.1.0) ⇒ ONLY mechanism B
# can converge. Pre-fix: registry-others non-empty → mechanism A → the vendor `update` no-ops → the
# cache stays tampered forever. Post-fix: install-row sole → mechanism B → byte-converged.
read -r H1CLONE H1ADOPTER H1CFG H1SNAP H1STUB H1REG <<< "$(build_adopted_case "$FCORE")"
H1SIB="$(mk)"
python3 "$AM" adopters-register --repo "$H1SIB" --tag core-vA --version-dir "$H1CLONE" --registry "$H1REG" >/dev/null
printf 'TAMPER-H1\n' >> "$H1CFG/plugins/cache/kickoff-local/kickoff/0.1.0/skills/scan/SKILL.md"
chk "H1 precondition: the tampered cache FAILS plugin-cache-verify (verify-first cannot skip)" \
  "! python3 \"$AM\" plugin-cache-verify --repo \"$H1ADOPTER\" --core-dir \"$H1CLONE\" --config-dir \"$H1CFG\""
H1LOG="$(mk)/stub.log"; : > "$H1LOG"
KICKOFF_ADOPTERS_REGISTRY="$H1REG" KICKOFF_CORE_DIR="$H1CLONE" CLAUDE_CONFIG_DIR="$H1CFG" \
  CLAUDE_STUB_LOG="$H1LOG" PATH="$H1STUB:$PATH" REPO_DIR="$H1ADOPTER" \
  bash "$KICKOFF" pull core-vA >/dev/null 2>&1 || true
chk "H1: mechanism B fired — scoped uninstall+install in the stub log (a headless-only sibling no longer blocks) [RED on pre-fix]" \
  "grep -q 'uninstall --scope project kickoff@kickoff-local' \"$H1LOG\" && grep -q 'install --scope project kickoff@kickoff-local' \"$H1LOG\""
chk "H1: a plain pull CONVERGED — plugin-cache-verify GREEN (the TAMPER byte is gone) [RED on pre-fix]" \
  "python3 \"$AM\" plugin-cache-verify --repo \"$H1ADOPTER\" --core-dir \"$H1CLONE\" --config-dir \"$H1CFG\""
chk "H1: the headless sibling's registry row is INTACT (2 rows; the sibling repo still present)" \
  "[ \"\$(jq '.adopters|length' \"$H1REG\")\" = 2 ] && jq -e --arg r \"\$(cd \"$H1SIB\" && pwd -P)\" '.adopters|any(.repo==\$r)' \"$H1REG\" >/dev/null"
chk "H1: adopter-owned files byte-identical across the pull (settings.local.json + CLAUDE.md, cmp -s)" \
  "cmp -s \"$H1SNAP/settings.local.json\" \"$H1ADOPTER/.claude/settings.local.json\" && cmp -s \"$H1SNAP/CLAUDE.md\" \"$H1ADOPTER/CLAUDE.md\""

# ── H2 [RED on pre-fix, the SAFETY direction]: an UNREGISTERED interactive consumer is protected ──
# The mirror hole: the registry says "sole" (only self is registered), but a SECOND project holds a
# kickoff@kickoff-local install row in the SAME config dir (registry rows are best-effort — this
# consumer never registered). Pre-fix: registry-soleness licensed mechanism B → the uninstall
# popped the whole install key (the other consumer's row included) and swept ALL version dirs of
# the shared cache (its foreign version dir included). Post-fix: the install row is visible → the
# gate refuses, degrades to mechanism A, and the refusal WARN names the consumer.
read -r H2CLONE H2ADOPTER H2CFG _H2SNAP H2STUB H2REG <<< "$(build_adopted_case "$FCORE")"
H2OTHER="$(mk)"; H2OTHERP="$(cd "$H2OTHER" && pwd -P)"
H2IP="$H2CFG/plugins/installed_plugins.json"; H2TMP="$(mk)/ip.json"
jq --arg pp "$H2OTHERP" '.plugins["kickoff@kickoff-local"] += [{"scope":"project","projectPath":$pp,"installPath":"/nonexistent-other","version":"0.9.9"}]' \
  "$H2IP" > "$H2TMP" && mv "$H2TMP" "$H2IP"
mkdir -p "$H2CFG/plugins/cache/kickoff-local/kickoff/0.9.9"
printf 'the other consumer version dir — a mechanism-B uninstall would sweep me\n' \
  > "$H2CFG/plugins/cache/kickoff-local/kickoff/0.9.9/SENTINEL.txt"
printf 'TAMPER-H2\n' >> "$H2CFG/plugins/cache/kickoff-local/kickoff/0.1.0/skills/scan/SKILL.md"
H2LOG="$(mk)/stub.log"; : > "$H2LOG"
H2OUT="$(KICKOFF_ADOPTERS_REGISTRY="$H2REG" KICKOFF_CORE_DIR="$H2CLONE" CLAUDE_CONFIG_DIR="$H2CFG" \
  CLAUDE_STUB_LOG="$H2LOG" PATH="$H2STUB:$PATH" REPO_DIR="$H2ADOPTER" \
  bash "$KICKOFF" pull core-vA 2>&1)" || true
chk "H2: NO uninstall in the stub log — a registry-invisible consumer can no longer be swept [RED on pre-fix]" \
  "! grep -q 'uninstall --scope project kickoff@kickoff-local' \"$H2LOG\""
chk "H2: the other consumer's install ROW survived the pull (pre-fix: popped by the uninstall) [RED on pre-fix]" \
  "jq -e --arg pp \"$H2OTHERP\" '.plugins[\"kickoff@kickoff-local\"]|any(.projectPath==\$pp)' \"$H2IP\" >/dev/null"
chk "H2: the other consumer's foreign version dir SURVIVED (pre-fix: the uninstall sweeps ALL version dirs) [RED on pre-fix]" \
  "[ -f \"$H2CFG/plugins/cache/kickoff-local/kickoff/0.9.9/SENTINEL.txt\" ]"
chk "H2: the refusal WARN (REFUSING) names the actual cache consumer's path [RED on pre-fix]" \
  "printf '%s' \"\$H2OUT\" | grep -q 'REFUSING' && printf '%s' \"\$H2OUT\" | grep -qF \"$H2OTHERP\""

# ── H3 (control, green pre- AND post-fix): a registered+installed interactive sibling still refuses ──
read -r H3CLONE H3ADOPTER H3CFG _H3SNAP H3STUB H3REG <<< "$(build_adopted_case "$FCORE")"
H3SIB="$(mk)"; H3SIBP="$(cd "$H3SIB" && pwd -P)"
python3 "$AM" adopters-register --repo "$H3SIB" --tag core-vA --version-dir "$H3CLONE" --registry "$H3REG" >/dev/null
H3IP="$H3CFG/plugins/installed_plugins.json"; H3TMP="$(mk)/ip.json"
jq --arg pp "$H3SIBP" '.plugins["kickoff@kickoff-local"] += [{"scope":"project","projectPath":$pp,"installPath":"/nonexistent-sib","version":"0.1.0"}]' \
  "$H3IP" > "$H3TMP" && mv "$H3TMP" "$H3IP"
printf 'TAMPER-H3\n' >> "$H3CFG/plugins/cache/kickoff-local/kickoff/0.1.0/skills/scan/SKILL.md"
H3LOG="$(mk)/stub.log"; : > "$H3LOG"
H3OUT="$(KICKOFF_ADOPTERS_REGISTRY="$H3REG" KICKOFF_CORE_DIR="$H3CLONE" CLAUDE_CONFIG_DIR="$H3CFG" \
  CLAUDE_STUB_LOG="$H3LOG" PATH="$H3STUB:$PATH" REPO_DIR="$H3ADOPTER" \
  bash "$KICKOFF" pull core-vA 2>&1)" || true
chk "H3 (control): a registered+installed interactive sibling still REFUSES mechanism B (no uninstall + REFUSING WARN)" \
  "! grep -q 'uninstall --scope project kickoff@kickoff-local' \"$H3LOG\" && printf '%s' \"\$H3OUT\" | grep -q 'REFUSING'"
chk "H3 (control): the sibling's install row is untouched by the refused resync" \
  "jq -e --arg pp \"$H3SIBP\" '.plugins[\"kickoff@kickoff-local\"]|any(.projectPath==\$pp)' \"$H3IP\" >/dev/null"

# ── H4 [RED on pre-fix]: ANY consumer-query error degrades to mechanism A (never licenses B) ──
# The rc-fallback that also covers the MIXED pull (a new front door pulling a pinned tag whose tool
# PREDATES `plugin-consumers-others` — argparse rc2): any non-zero query rc ⇒ NOT provably sole ⇒
# mechanism A + the honest "unknown" refusal WARN. Exercised here through the FULL pull via a
# CORRUPT installed_plugins.json (the verb's own rc2, the same kickoff-side branch). (The
# no-uninstall half is green pre-fix too — a corrupt file also blanks the scope-matched
# installed_ver read, so even the registry gate fell to mechanism A; the WARN half is RED pre-fix:
# the old refusal named registry adopters, never the unreadable consumer source.)
read -r H4CLONE H4ADOPTER H4CFG _H4SNAP H4STUB H4REG <<< "$(build_adopted_case "$FCORE")"
printf 'TAMPER-H4\n' >> "$H4CFG/plugins/cache/kickoff-local/kickoff/0.1.0/skills/scan/SKILL.md"
printf 'not json — the consumer query must fail rc!=0, never license mechanism B\n' \
  > "$H4CFG/plugins/installed_plugins.json"
H4LOG="$(mk)/stub.log"; : > "$H4LOG"
H4OUT="$(KICKOFF_ADOPTERS_REGISTRY="$H4REG" KICKOFF_CORE_DIR="$H4CLONE" CLAUDE_CONFIG_DIR="$H4CFG" \
  CLAUDE_STUB_LOG="$H4LOG" PATH="$H4STUB:$PATH" REPO_DIR="$H4ADOPTER" \
  bash "$KICKOFF" pull core-vA 2>&1)" || true
chk "H4 (rc-fallback): a corrupt installed_plugins.json ⇒ NO uninstall (any query rc≠0 degrades to mechanism A — the same branch a pre-verb pinned tool hits)" \
  "! grep -q 'uninstall --scope project kickoff@kickoff-local' \"$H4LOG\""
chk "H4 (rc-fallback): the refusal WARN carries the honest 'unknown' consumer list [RED on pre-fix]" \
  "printf '%s' \"\$H4OUT\" | grep -q 'installed_plugins.json unreadable'"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "4. Slice 5 — preflight #8 also hashes the plugin cache (plugin-cache-verify)"
# ══════════════════════════════════════════════════════════════════════════════════════
# A fresh adopted@vA case → cache@0.1.0 is a byte-copy of the pinned $clone/plugin@0.1.0. Verify it
# GREEN, then corrupt it two ways (edit a file / drop the version dir) → FAIL; a no-machine-entry
# manifest → SKIP. Then the preflight #8 INTEGRATION: a standalone preflight GREEN reports the cache
# verified; an edited cache FAILS the whole preflight. All isolated via CLAUDE_CONFIG_DIR.
read -r S5CLONE S5ADOPTER S5CFG _S5SNAP _S5STUB _S5REG <<< "$(build_adopted_case "$FCORE")"
CACHE5="$S5CFG/plugins/cache/kickoff-local/kickoff/0.1.0"
chk "plugin-cache-verify: a MATCHING cache exits 0 (GREEN)" \
  "python3 \"$AM\" plugin-cache-verify --repo \"$S5ADOPTER\" --core-dir \"$S5CLONE\" --config-dir \"$S5CFG\""
# no-machine-entry manifest → SKIP (exit 0) — the inert/dogfood-safe path
S5NOENT="$(mk)"; mkdir -p "$S5NOENT/.kickoff"
printf '{"schema_version":2,"entries":[],"machine_entries":[]}\n' > "$S5NOENT/.kickoff/adopt-manifest.json"
chk "plugin-cache-verify: NO machine entry → skipped (exit 0)" \
  "python3 \"$AM\" plugin-cache-verify --repo \"$S5NOENT\" --core-dir \"$S5CLONE\" --config-dir \"$S5CFG\""

# ── preflight #8 INTEGRATION (matching cache — do this BEFORE corrupting) ──
PF5RC=0; PF5OUT="$(REPO_DIR="$S5ADOPTER" KICKOFF_CORE_DIR="$S5CLONE" CLAUDE_CONFIG_DIR="$S5CFG" bash "$S5CLONE/scripts/preflight.sh" 2>&1)" || PF5RC=$?
chk "preflight #8: a matching plugin cache passes (preflight exits 0)" "[ $PF5RC -eq 0 ]"
chk "preflight #8: reports 'plugin cache integrity verified'" \
  "printf '%s' \"\$PF5OUT\" | grep -q 'plugin cache integrity verified'"

# ── now corrupt: edit a cache file → verify FAIL + preflight #8 FAIL ──
printf 'TAMPER-VA\n' >> "$CACHE5/skills/scan/SKILL.md"
chk "plugin-cache-verify: an EDITED cache file FAILS (non-zero)" \
  "! python3 \"$AM\" plugin-cache-verify --repo \"$S5ADOPTER\" --core-dir \"$S5CLONE\" --config-dir \"$S5CFG\""
PF5ERC=0; PF5EOUT="$(REPO_DIR="$S5ADOPTER" KICKOFF_CORE_DIR="$S5CLONE" CLAUDE_CONFIG_DIR="$S5CFG" bash "$S5CLONE/scripts/preflight.sh" 2>&1)" || PF5ERC=$?
chk "preflight #8: an edited plugin cache FAILS the preflight (non-zero)" "[ $PF5ERC -ne 0 ]"
chk "preflight #8: reports 'plugin cache DRIFT'" "printf '%s' \"\$PF5EOUT\" | grep -q 'plugin cache DRIFT'"
# a MISSING version dir → verify FAIL
rm -rf "$CACHE5"
chk "plugin-cache-verify: a MISSING cache version dir FAILS (non-zero)" \
  "! python3 \"$AM\" plugin-cache-verify --repo \"$S5ADOPTER\" --core-dir \"$S5CLONE\" --config-dir \"$S5CFG\""
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "5. Slice 6 — eject unwires the plugin (cache+marketplace) on the LAST sibling"
# ══════════════════════════════════════════════════════════════════════════════════════
# LAST sibling: adopt@vA + a core.lock (tag core-vA) + a registry row (this adopter only) → eject
# sweeps the cache, removes the marketplace (isolated cfg), byte-restores the two settings keys, drops
# the adopters row, and byte-restores the TRACKED tree (the sole residue is the §E deliverable eject
# relocates to kickoff-data/ on a keep — see the porcelain assertion); the planted secret survives + never
# surfaces. Isolated: CLAUDE_CONFIG_DIR + stub claude + an isolated adopters registry.
read -r S6CLONE S6ADOPTER S6CFG _S6SNAP S6STUB S6REG <<< "$(build_adopted_case "$FCORE")"
S6VA="$(git -C "$S6CLONE" rev-parse HEAD)"
printf 'format 2\ntag core-vA\ncommit %s\n' "$S6VA" > "$S6ADOPTER/.kickoff/core.lock"
# adopt already registered THIS adopter in the isolated S6REG (Fix 1b) — it is the SOLE adopter, so
# `adopters-others` returns empty → eject removes the user-global marketplace + cache.
S6COMMITTED="$(mk)/committed-settings.json"; git -C "$S6ADOPTER" show HEAD:.claude/settings.json > "$S6COMMITTED"
[ -d "$S6CFG/plugins/cache/kickoff-local/kickoff" ] || bad "slice6 precondition: cache@0.1.0 not populated by adopt"
S6ERC=0; S6EOUT="$(CLAUDE_CONFIG_DIR="$S6CFG" KICKOFF_ADOPTERS_REGISTRY="$S6REG" PATH="$S6STUB:$PATH" \
  bash "$KICKOFF" eject --dir "$S6ADOPTER" --no-archive --delete-data --confirm-destroy 2>&1)" || S6ERC=$?
chk "eject(last): exits 0" "[ $S6ERC -eq 0 ]"
chk "eject(last): the user-global cache dir is SWEPT (all versions gone)" \
  "[ ! -d \"$S6CFG/plugins/cache/kickoff-local/kickoff\" ]"
chk "eject(last): the marketplace is REMOVED from the isolated known_marketplaces" \
  "! grep -q kickoff-local \"$S6CFG/plugins/known_marketplaces.json\""
chk "eject(last): settings.json byte-restored to the pre-adopt (committed) 4-space form" \
  "cmp -s \"$S6COMMITTED\" \"$S6ADOPTER/.claude/settings.json\""
chk "eject(last): both plugin settings keys are GONE (extraKnownMarketplaces + enabledPlugins null)" \
  "[ \"\$(jq '.extraKnownMarketplaces' \"$S6ADOPTER/.claude/settings.json\")\" = null ] && [ \"\$(jq '.enabledPlugins' \"$S6ADOPTER/.claude/settings.json\")\" = null ]"
chk "eject(last): settings.json is STILL 4-space (not re-indented to jq 2-space)" \
  "grep -q '^    \"permissions\"' \"$S6ADOPTER/.claude/settings.json\""
chk "eject(last): the adopters registry row is dropped (0 rows left)" \
  "[ \"\$(jq '.adopters|length' \"$S6REG\")\" = 0 ]"
chk "eject(last): tracked tree byte-restored — only the preserved kickoff-data/ deliverable remains (§E split-charter)" \
  "[ -d \"$S6ADOPTER/kickoff-data\" ] && [ -z \"\$(git -C \"$S6ADOPTER\" status --porcelain | grep -v '^?? kickoff-data/')\" ]"
chk "eject(last): the planted secret SURVIVES in settings.local.json" \
  "grep -qF '$PLANT' \"$S6ADOPTER/.claude/settings.local.json\""
chk "eject(last) CREDENTIAL-SAFE: the secret is ABSENT from all eject output" \
  "! printf '%s' \"\$S6EOUT\" | grep -qF '$PLANT'"

# ── --dry-run: reports the unwiring plan, changes NOTHING (cache + .kickoff/ untouched) ──
read -r S6DCLONE S6DADOPTER S6DCFG _S6DSNAP S6DSTUB S6DREG <<< "$(build_adopted_case "$FCORE")"
printf 'format 2\ntag core-vA\ncommit %s\n' "$(git -C "$S6DCLONE" rev-parse HEAD)" > "$S6DADOPTER/.kickoff/core.lock"
# adopt already registered this adopter in S6DREG (Fix 1b) — sole adopter → the last-adopter plan
S6DOUT="$(CLAUDE_CONFIG_DIR="$S6DCFG" KICKOFF_ADOPTERS_REGISTRY="$S6DREG" PATH="$S6DSTUB:$PATH" \
  bash "$KICKOFF" eject --dir "$S6DADOPTER" --no-archive --delete-data --confirm-destroy --dry-run 2>&1)" || true
chk "eject --dry-run: reports the unwiring plan (would sweep cache / remove marketplace)" \
  "printf '%s' \"\$S6DOUT\" | grep -qiE 'would (uninstall|.*sweep cache)'"
chk "eject --dry-run: the cache is UNTOUCHED (nothing swept)" \
  "[ -d \"$S6DCFG/plugins/cache/kickoff-local/kickoff\" ]"
chk "eject --dry-run: .kickoff/ is still present (nothing torn down)" "[ -d \"$S6DADOPTER/.kickoff\" ]"

# ── Fix 1 (RED on pre-fix): a SAME-TAG sibling → NOT last → cache/marketplace LEFT ──────────────────
# THE untested case the review found. The pre-fix eject used `adopters-siblings --tag <mytag>`, which
# reports ONLY DIFFERENT-tag adopters — so a SAME-tag sibling (the common multi-project-on-one-box
# case: both track the latest tag, so both land on core-vA and share the IDENTICAL user-global cache
# dir cache/kickoff-local/kickoff/0.1.0) was INVISIBLE → eject wrongly swept the shared cache out from
# under the live sibling. The fix queries `adopters-others` (ANY tag). Register a SAME-tag sibling →
# eject must LEAVE the cache + marketplace. On PRE-FIX code the same-tag sibling is hidden → eject
# REMOVES → "cache LEFT" fails. (The different-tag branch is the strictly-safer subset of this.)
read -r S6SCLONE S6SADOPTER S6SCFG _S6SSNAP S6SSTUB S6SREG <<< "$(build_adopted_case "$FCORE")"
S6SOTHER="$(mk)"
S6SVA="$(git -C "$S6SCLONE" rev-parse HEAD)"
printf 'format 2\ntag core-vA\ncommit %s\n' "$S6SVA" > "$S6SADOPTER/.kickoff/core.lock"
# adopt already registered S6SADOPTER@core-vA in S6SREG (Fix 1b). Add a SAME-TAG (core-vA) sibling —
# it shares the identical cache dir, so eject must LEAVE the shared user-global plugin.
python3 "$AM" adopters-register --repo "$S6SOTHER" --tag core-vA --version-dir "$S6SCLONE" --registry "$S6SREG" >/dev/null
S6SEOUT="$(CLAUDE_CONFIG_DIR="$S6SCFG" KICKOFF_ADOPTERS_REGISTRY="$S6SREG" PATH="$S6SSTUB:$PATH" \
  bash "$KICKOFF" eject --dir "$S6SADOPTER" --no-archive --delete-data --confirm-destroy 2>&1)" || true
chk "eject(SAME-tag sibling): the cache is LEFT (same-tag sibling shares the identical cache dir) [Fix 1, RED on pre-fix]" \
  "[ -d \"$S6SCFG/plugins/cache/kickoff-local/kickoff\" ]"
chk "eject(SAME-tag sibling): the marketplace is LEFT in the isolated known_marketplaces [Fix 1]" \
  "grep -q kickoff-local \"$S6SCFG/plugins/known_marketplaces.json\""
chk "eject(SAME-tag sibling): reports OTHER adopter(s) → LEAVING the marketplace + cache" \
  "printf '%s' \"\$S6SEOUT\" | grep -qi 'LEAVING the marketplace'"
chk "eject(SAME-tag sibling): repo settings keys removed + tracked tree byte-restored (only kickoff-data/ deliverable remains)" \
  "[ -d \"$S6SADOPTER/kickoff-data\" ] && [ -z \"\$(git -C \"$S6SADOPTER\" status --porcelain | grep -v '^?? kickoff-data/')\" ]"
chk "eject(SAME-tag sibling): THIS adopter's registry row is dropped (only the sibling row remains)" \
  "[ \"\$(jq '.adopters|length' \"$S6SREG\")\" = 1 ]"

# ── Fix 6 (RED on pre-fix): eject with `claude` ABSENT on the last-adopter path → cache + registry
#    left CONSISTENT (both INTACT, warned). Pre-fix rm -rf'd the cache OUTSIDE the claude guard →
#    cache-gone + registry-dangling. Run eject with a PATH that has coreutils/git/python3 but NO
#    claude (the stub dir excluded, ~/.local/bin excluded) so `command -v claude` is false. ─────────
read -r F6CLONE F6ADOPTER F6CFG _F6SNAP _F6STUB F6REG <<< "$(build_adopted_case "$FCORE")"
printf 'format 2\ntag core-vA\ncommit %s\n' "$(git -C "$F6CLONE" rev-parse HEAD)" > "$F6ADOPTER/.kickoff/core.lock"
[ -d "$F6CFG/plugins/cache/kickoff-local/kickoff" ] || bad "Fix6 precondition: cache@0.1.0 not populated by adopt"
grep -q kickoff-local "$F6CFG/plugins/known_marketplaces.json" || bad "Fix6 precondition: marketplace not registered by adopt"
F6ERC=0; F6EOUT="$(CLAUDE_CONFIG_DIR="$F6CFG" KICKOFF_ADOPTERS_REGISTRY="$F6REG" PATH="/usr/bin:/bin" \
  bash "$KICKOFF" eject --dir "$F6ADOPTER" --no-archive --delete-data --confirm-destroy 2>&1)" || F6ERC=$?
chk "eject(claude ABSENT, last adopter): the cache is LEFT INTACT (not orphaned) [Fix 6, RED on pre-fix]" \
  "[ -d \"$F6CFG/plugins/cache/kickoff-local/kickoff\" ]"
chk "eject(claude ABSENT): the marketplace registry entry is LEFT INTACT (consistent with the cache) [Fix 6]" \
  "grep -q kickoff-local \"$F6CFG/plugins/known_marketplaces.json\""
chk "eject(claude ABSENT): the installed_plugins entry is LEFT INTACT (consistent) [Fix 6]" \
  "grep -q 'kickoff@kickoff-local' \"$F6CFG/plugins/installed_plugins.json\""
chk "eject(claude ABSENT): warns LOUDLY that \`claude\` is not on PATH (user-global left INTACT)" \
  "printf '%s' \"\$F6EOUT\" | grep -qi 'claude. is not on PATH'"
chk "eject(claude ABSENT): repo fully ejected — tracked tree byte-restored (only kickoff-data/ deliverable remains)" \
  "[ -d \"$F6ADOPTER/kickoff-data\" ] && [ -z \"\$(git -C \"$F6ADOPTER\" status --porcelain | grep -v '^?? kickoff-data/')\" ]"

# ── Fix C (RED on pre-fix): the claude-absent eject must give SELF-CONTAINED manual cleanup commands
#    baked from the machine row (uninstall + marketplace remove + rm -rf the cache) — NOT the dead-end
#    "re-run kickoff eject" advice (eject removes .kickoff/ THIS run, so a re-run has no manifest to act
#    on → the user-global residue would be unreachable). Reuses $F6EOUT from the run above. ────────────
chk "eject(claude ABSENT): warning carries the concrete \`claude plugin uninstall --scope project kickoff@kickoff-local\` [Fix C, RED on pre-fix]" \
  "printf '%s' \"\$F6EOUT\" | grep -qF 'claude plugin uninstall --scope project kickoff@kickoff-local'"
chk "eject(claude ABSENT): warning carries the concrete \`claude plugin marketplace remove kickoff-local\` [Fix C, RED on pre-fix]" \
  "printf '%s' \"\$F6EOUT\" | grep -qF 'claude plugin marketplace remove kickoff-local'"
chk "eject(claude ABSENT): warning carries the concrete \`rm -rf <cache>\` with the REAL cache path [Fix C, RED on pre-fix]" \
  "printf '%s' \"\$F6EOUT\" | grep -qF 'rm -rf $F6CFG/plugins/cache/kickoff-local/kickoff'"
chk "eject(claude ABSENT): the dead-end 're-run kickoff eject … to finish' advice is GONE [Fix C, RED on pre-fix]" \
  "! printf '%s' \"\$F6EOUT\" | grep -qi 'Re-run .kickoff eject. with Claude Code on PATH'"

# ── Fix B (RED on pre-fix): eject --dry-run with `claude` ABSENT must preview the ACTUAL claude-absent
#    behaviour (would LEAVE/SKIP the user-global cleanup), NOT the claude-present "would uninstall +
#    sweep cache" plan a real run in that env REFUSES (Fix 6). Pre-fix the dry preview was claude-blind
#    (the Fix-6 skip was gated `[ "$dry" != 1 ]`) → it always promised the sweep. ─────────────────────
read -r FBCLONE FBADOPTER FBCFG _FBSNAP _FBSTUB FBREG <<< "$(build_adopted_case "$FCORE")"
printf 'format 2\ntag core-vA\ncommit %s\n' "$(git -C "$FBCLONE" rev-parse HEAD)" > "$FBADOPTER/.kickoff/core.lock"
FBOUT="$(CLAUDE_CONFIG_DIR="$FBCFG" KICKOFF_ADOPTERS_REGISTRY="$FBREG" PATH="/usr/bin:/bin" \
  bash "$KICKOFF" eject --dir "$FBADOPTER" --no-archive --delete-data --confirm-destroy --dry-run 2>&1)" || true
chk "eject --dry-run (claude ABSENT): preview does NOT promise the claude-present uninstall+sweep [Fix B, RED on pre-fix]" \
  "! printf '%s' \"\$FBOUT\" | grep -qiE 'would uninstall .*sweep cache'"
chk "eject --dry-run (claude ABSENT): preview reports it would SKIP/LEAVE the user-global cleanup (claude absent) [Fix B]" \
  "printf '%s' \"\$FBOUT\" | grep -qiE 'would (skip|leave).*(claude|user-global)|claude. is not on PATH'"
chk "eject --dry-run (claude ABSENT): the cache is UNTOUCHED (dry-run changed nothing)" \
  "[ -d \"$FBCFG/plugins/cache/kickoff-local/kickoff\" ]"
chk "eject --dry-run (claude ABSENT): .kickoff/ still present (dry-run changed nothing)" \
  "[ -d \"$FBADOPTER/.kickoff\" ]"

# ── Fix D (RED on pre-fix): if the EJECTING adopter is NOT in the machine registry (its register-at-
#    adopt failed), the last-adopter destructive path must FAIL SAFE and LEAVE the shared cache — an
#    adopter absent from its OWN registry is proof the registration path is unhealthy, so a sibling
#    that also failed to register could be invisible. Pre-fix (no self-in-registry gate) swept it. ────
read -r FDCLONE FDADOPTER FDCFG _FDSNAP FDSTUB FDREG <<< "$(build_adopted_case "$FCORE")"
printf 'format 2\ntag core-vA\ncommit %s\n' "$(git -C "$FDCLONE" rev-parse HEAD)" > "$FDADOPTER/.kickoff/core.lock"
# simulate a FAILED register-at-adopt: drop THIS adopter's own row (leaving it absent from its registry)
python3 "$AM" adopters-remove --repo "$FDADOPTER" --registry "$FDREG" >/dev/null
chk "FixD precondition: the ejecting adopter is ABSENT from the registry (adopters-self exits non-zero)" \
  "! python3 \"$AM\" adopters-self --repo \"$FDADOPTER\" --registry \"$FDREG\""
FDOUT="$(CLAUDE_CONFIG_DIR="$FDCFG" KICKOFF_ADOPTERS_REGISTRY="$FDREG" PATH="$FDSTUB:$PATH" \
  bash "$KICKOFF" eject --dir "$FDADOPTER" --no-archive --delete-data --confirm-destroy 2>&1)" || true
chk "eject(self NOT in registry): the shared cache is LEFT (fail-safe — registration unhealthy) [Fix D, RED on pre-fix]" \
  "[ -d \"$FDCFG/plugins/cache/kickoff-local/kickoff\" ]"
chk "eject(self NOT in registry): the marketplace is LEFT in known_marketplaces [Fix D, RED on pre-fix]" \
  "grep -q kickoff-local \"$FDCFG/plugins/known_marketplaces.json\""
chk "eject(self NOT in registry): reports conservatively LEAVING (NOT recorded in the registry) [Fix D]" \
  "printf '%s' \"\$FDOUT\" | grep -qi 'NOT recorded in the machine registry'"
chk "eject(self NOT in registry): repo fully ejected — tracked tree byte-restored (only kickoff-data/ deliverable remains)" \
  "[ -d \"$FDADOPTER/kickoff-data\" ] && [ -z \"\$(git -C \"$FDADOPTER\" status --porcelain | grep -v '^?? kickoff-data/')\" ]"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "5b. ROUND-TRIP byte-integrity [RED on pre-fix]: a HAND-WRITTEN non-canonical settings.json"
#     survives the full plugin lifecycle byte-for-byte. eject step-4 byte-restores settings.json, but
#     the step-5 `claude plugin uninstall --scope project`/`marketplace remove` RE-SERIALIZE it AFTER
#     that (re-canonicalize + a stray `enabledPlugins: {}`) — the re-assert must undo ONLY that mangle.
#     The fixture uses the REAL adversarial form the validation hit: MIXED indentation (6-space nested
#     "allow", 4-space "TZ") + UNSORTED keys (permissions, env, hooks) — a jq/json re-serialize changes
#     every one of these, so byte-identity is a real test (NOT a lucky line-match — the memory scar).
# ══════════════════════════════════════════════════════════════════════════════════════
RSCLONE="$(mk)"; RSADOPTER="$(mk)"; RSCFG="$(mk)"; RSSTUB="$(mk)"; RSREG="$(mk)/adopters.json"
write_stub_claude "$RSSTUB"
git clone -q "$FCORE" "$RSCLONE"; git -C "$RSCLONE" checkout -q --detach core-vA
mkdir -p "$RSADOPTER/.claude" "$RSADOPTER/.kickoff/state" "$RSADOPTER/memory"
git -C "$RSADOPTER" init -q; git -C "$RSADOPTER" config user.email t@t.t; git -C "$RSADOPTER" config user.name t
printf '# memory index\n' > "$RSADOPTER/memory/MEMORY.md"
printf '{ "telegram": { "botToken": "%s" } }\n' "$PLANT" > "$RSADOPTER/.claude/settings.local.json"
# THE adversarial fixture (the exact shape the e2e validation flagged): mixed-indent, unsorted-keys.
cat > "$RSADOPTER/.claude/settings.json" <<'JSON'
{
  "permissions": {
      "allow": ["Bash(node:*)", "Read", "Edit", "Bash(git status:*)"]
  },
  "env": {
    "ACME_ENV": "dev",
      "TZ": "UTC"
  },
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "node .claude/hooks/my-memory.mjs" } ] }
    ]
  }
}
JSON
git -C "$RSADOPTER" add -A; git -C "$RSADOPTER" commit -qm baseline
RSPRE_SHA="$(sha256sum "$RSADOPTER/.claude/settings.json" | awk '{print $1}')"          # pre-adopt bytes
RSLOCAL_SHA="$(sha256sum "$RSADOPTER/.claude/settings.local.json" | awk '{print $1}')"  # the secret file
cat > "$RSADOPTER/.kickoff/instance.env" <<EOF
export KICKOFF_CORE_DIR="$RSCLONE"
export KICKOFF_CORE_REMOTE="$FCORE"
export TELEGRAM_STATE_DIR="$RSADOPTER/.kickoff/chan"
export MC_STATE_FILE="$RSADOPTER/.kickoff/state/mission-state.json"
export MEMORY_DB="$RSADOPTER/.kickoff/state/memory-index.db"
export MEMORY_HOOK_LOG="$RSADOPTER/.kickoff/state/memory-hook.log"
EOF
python3 "$RSCLONE/scripts/adopt-manifest.py" gen-charter --repo "$RSADOPTER" --source core-vA >/dev/null
# adopt@vA (enables the plugin at project scope + records the machine entry + registers this adopter)
KICKOFF_ADOPTERS_REGISTRY="$RSREG" KICKOFF_CORE_DIR="$RSCLONE" CLAUDE_CONFIG_DIR="$RSCFG" PATH="$RSSTUB:$PATH" \
  bash "$KICKOFF" adopt --dir "$RSADOPTER" --accept </dev/null >/dev/null 2>&1 || true
# pull core-vB (full plugin lifecycle — mechanism A cache resync). pull's rc is OUT OF SCOPE here (a
# known preflight papercut) so it is not asserted; the eject byte-restores from the manifest regardless.
KICKOFF_ADOPTERS_REGISTRY="$RSREG" KICKOFF_CORE_DIR="$RSCLONE" CLAUDE_CONFIG_DIR="$RSCFG" PATH="$RSSTUB:$PATH" \
  REPO_DIR="$RSADOPTER" bash "$KICKOFF" pull core-vB >/dev/null 2>&1 || true
# eject (sole adopter in RSREG → adopters-others empty → LAST → the claude-present unwiring path runs).
RSERC=0; RSEOUT="$(CLAUDE_CONFIG_DIR="$RSCFG" KICKOFF_ADOPTERS_REGISTRY="$RSREG" PATH="$RSSTUB:$PATH" \
  bash "$KICKOFF" eject --dir "$RSADOPTER" --no-archive --delete-data --confirm-destroy --verify 2>&1)" || RSERC=$?
RSPOST_SHA="$(sha256sum "$RSADOPTER/.claude/settings.json" | awk '{print $1}')"
RSLOCAL_POST_SHA="$(sha256sum "$RSADOPTER/.claude/settings.local.json" | awk '{print $1}')"
chk "5b: eject --verify exits 0 (a clean round-trip)"                          "[ $RSERC -eq 0 ]"
chk "5b THE FIX: settings.json is BYTE-IDENTICAL (sha256) to the hand-written pre-adopt original [RED on pre-fix]" \
  "[ \"$RSPOST_SHA\" = \"$RSPRE_SHA\" ]"
# 5b uniquely has NO pre-existing CLAUDE.md, so adopt CREATES one (created/seeded-instance — the
# adopter's deliverable-to-be, kept by eject unless --purge-seeded) AND relocates KICKOFF.local.md to
# kickoff-data/. BOTH are intentionally-kept kickoff-created deliverables; everything ELSE must be
# byte-restored (a settings.json left ' M' — the pre-fix bug — surfaces here → RED).
chk "5b: tracked tree byte-restored — only the kickoff-created deliverables (CLAUDE.md + kickoff-data/) remain (settings.json not left ' M') [RED on pre-fix]" \
  "[ -f \"$RSADOPTER/CLAUDE.md\" ] && [ -d \"$RSADOPTER/kickoff-data\" ] && [ -z \"\$(git -C \"$RSADOPTER\" status --porcelain | grep -vxF -e '?? CLAUDE.md' -e '?? kickoff-data/')\" ]"
chk "5b: settings.json keeps its hand-written 6-space \"allow\" indent (not re-canonicalized to jq 2-space) [RED on pre-fix]" \
  "grep -q '^      \"allow\"' \"$RSADOPTER/.claude/settings.json\""
chk "5b: NO stray \"enabledPlugins\" key survived the eject (the plugin CLI's residue) [RED on pre-fix]" \
  "! jq -e 'has(\"enabledPlugins\")' \"$RSADOPTER/.claude/settings.json\" >/dev/null 2>&1"
chk "5b --verify: reports 'no trace' (the tree really IS clean now)"           "printf '%s' \"\$RSEOUT\" | grep -q 'no trace'"
# CREDENTIAL-SAFE: the snapshot/re-assert only ever touch settings.json — settings.local.json is untouched.
chk "5b CREDENTIAL-SAFE: settings.local.json is BYTE-IDENTICAL (never snapshotted/re-asserted)" \
  "[ \"$RSLOCAL_POST_SHA\" = \"$RSLOCAL_SHA\" ]"
chk "5b CREDENTIAL-SAFE: the planted secret SURVIVES in settings.local.json"   "grep -qF '$PLANT' \"$RSADOPTER/.claude/settings.local.json\""
chk "5b CREDENTIAL-SAFE: the planted secret is ABSENT from all eject output"   "! printf '%s' \"\$RSEOUT\" | grep -qF '$PLANT'"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "5c. --verify HONESTY [RED on pre-fix]: a DIVERGED settings.json (operator edited after adopt)"
#     is not byte-for-byte reversible (LOCKED D3, no-clobber) → --verify must exit NON-ZERO + NOT claim
#     'no trace' over the dirty tree (the old marker-only scan was BLIND to it), while the re-assert
#     still PRESERVES the operator's edit (never clobbers it back to the plugin CLI's re-serialization).
# ══════════════════════════════════════════════════════════════════════════════════════
DVCLONE="$(mk)"; DVADOPTER="$(mk)"; DVCFG="$(mk)"; DVSTUB="$(mk)"; DVREG="$(mk)/adopters.json"
write_stub_claude "$DVSTUB"
git clone -q "$FCORE" "$DVCLONE"; git -C "$DVCLONE" checkout -q --detach core-vA
mkdir -p "$DVADOPTER/.claude" "$DVADOPTER/.kickoff/state" "$DVADOPTER/memory"
git -C "$DVADOPTER" init -q; git -C "$DVADOPTER" config user.email t@t.t; git -C "$DVADOPTER" config user.name t
printf '# memory index\n' > "$DVADOPTER/memory/MEMORY.md"
printf '{ "telegram": { "botToken": "%s" } }\n' "$PLANT" > "$DVADOPTER/.claude/settings.local.json"
printf '{\n    "permissions": {\n        "allow": ["Bash(ls:*)"]\n    }\n}\n' > "$DVADOPTER/.claude/settings.json"
git -C "$DVADOPTER" add -A; git -C "$DVADOPTER" commit -qm baseline
cat > "$DVADOPTER/.kickoff/instance.env" <<EOF
export KICKOFF_CORE_DIR="$DVCLONE"
export KICKOFF_CORE_REMOTE="$FCORE"
export TELEGRAM_STATE_DIR="$DVADOPTER/.kickoff/chan"
export MC_STATE_FILE="$DVADOPTER/.kickoff/state/mission-state.json"
export MEMORY_DB="$DVADOPTER/.kickoff/state/memory-index.db"
export MEMORY_HOOK_LOG="$DVADOPTER/.kickoff/state/memory-hook.log"
EOF
python3 "$DVCLONE/scripts/adopt-manifest.py" gen-charter --repo "$DVADOPTER" --source core-vA >/dev/null
KICKOFF_ADOPTERS_REGISTRY="$DVREG" KICKOFF_CORE_DIR="$DVCLONE" CLAUDE_CONFIG_DIR="$DVCFG" PATH="$DVSTUB:$PATH" \
  bash "$KICKOFF" adopt --dir "$DVADOPTER" --accept </dev/null >/dev/null 2>&1 || true
# OPERATOR EDIT after adopt → settings.json diverges from the recorded json-merged hash (step-4 keeps it).
python3 - "$DVADOPTER/.claude/settings.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["operatorAddedKey"] = "OPERATOR_EDIT_MARKER"
json.dump(d, open(p, "w"), indent=2)
PY
DVERC=0; DVEOUT="$(CLAUDE_CONFIG_DIR="$DVCFG" KICKOFF_ADOPTERS_REGISTRY="$DVREG" PATH="$DVSTUB:$PATH" \
  bash "$KICKOFF" eject --dir "$DVADOPTER" --no-archive --delete-data --confirm-destroy --verify 2>&1)" || DVERC=$?
chk "5c --verify: exits NON-ZERO when settings.json is dirty (diverged — not byte-for-byte clean) [RED on pre-fix]" \
  "[ $DVERC -ne 0 ]"
chk "5c --verify: does NOT print 'no trace' over the dirty settings.json [RED on pre-fix]" \
  "! printf '%s' \"\$DVEOUT\" | grep -q 'no trace'"
chk "5c NO-CLOBBER: the operator's post-adopt edit SURVIVES the re-assert (not lost to the plugin CLI)" \
  "grep -q 'OPERATOR_EDIT_MARKER' \"$DVADOPTER/.claude/settings.json\""
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "6. Slice 8 — ACCEPTANCE (gates the tag): adopt@vA → pull core-vB → eject(last), hermetic + isolated"
# ══════════════════════════════════════════════════════════════════════════════════════
read -r E8CLONE E8ADOPTER E8CFG E8SNAP E8STUB E8REG <<< "$(build_adopted_case "$FCORE")"
E8LOG="$(mk)/stub.log"
E8COMMITTED="$(mk)/committed-settings.json"; git -C "$E8ADOPTER" show HEAD:.claude/settings.json > "$E8COMMITTED"
# ── (1) adopt@vA (already run by build_adopted_case) — the vA baseline ──
chk "E2E(1) adopt@vA: EXACTLY the two settings keys present" \
  "jq -e '.extraKnownMarketplaces[\"kickoff-local\"] and .enabledPlugins[\"kickoff@kickoff-local\"]==true' \"$E8ADOPTER/.claude/settings.json\" >/dev/null"
chk "E2E(1) adopt@vA: manifest carries the json-merged settings row + the machine plugin row" \
  "python3 -c \"import json;m=json.load(open('$E8ADOPTER/.kickoff/adopt-manifest.json'));assert any(e['path']=='.claude/settings.json' and e['action']=='json-merged' for e in m['entries']);assert any(x['plugin']=='kickoff' for x in m['machine_entries'])\""
chk "E2E(1) adopt@vA: cache @ 0.1.0 populated" \
  "[ -f \"$E8CFG/plugins/cache/kickoff-local/kickoff/0.1.0/.claude-plugin/plugin.json\" ]"
chk "E2E(1) adopt@vA: the planted secret + owned source are UNTOUCHED (cmp -s)" \
  "cmp -s \"$E8SNAP/settings.local.json\" \"$E8ADOPTER/.claude/settings.local.json\" && cmp -s \"$E8SNAP/app.txt\" \"$E8ADOPTER/src/app.txt\""

# ── (2) pull core-vB → cache@0.2.0 fresh + preflight #8 GREEN + adopter byte-untouched ──
E8PRC=0; E8POUT="$(KICKOFF_ADOPTERS_REGISTRY="$E8REG" KICKOFF_CORE_DIR="$E8CLONE" CLAUDE_CONFIG_DIR="$E8CFG" \
  CLAUDE_STUB_LOG="$E8LOG" PATH="$E8STUB:$PATH" REPO_DIR="$E8ADOPTER" bash "$KICKOFF" pull core-vB 2>&1)" || E8PRC=$?
chk "E2E(2) pull vB: exits 0 (pull + auto-preflight GREEN)" "[ $E8PRC -eq 0 ]"
chk "E2E(2) pull vB: cache re-synced to the 0.2.0 version dir with FRESH content (VB, not VA)" \
  "grep -q VB \"$E8CFG/plugins/cache/kickoff-local/kickoff/0.2.0/skills/scan/SKILL.md\" && ! grep -q VA \"$E8CFG/plugins/cache/kickoff-local/kickoff/0.2.0/skills/scan/SKILL.md\""
chk "E2E(2) pull vB: the pull's auto-preflight #8 reports the plugin cache verified" \
  "printf '%s' \"\$E8POUT\" | grep -q 'plugin cache integrity verified'"
# a STANDALONE preflight (as a pull adopter runs it) is GREEN + verifies the cache @ 0.2.0
PF8RC=0; PF8OUT="$(REPO_DIR="$E8ADOPTER" KICKOFF_CORE_DIR="$E8CLONE" CLAUDE_CONFIG_DIR="$E8CFG" bash "$E8CLONE/scripts/preflight.sh" 2>&1)" || PF8RC=$?
chk "E2E(2) preflight #8 (standalone, post-pull): GREEN against cache @ 0.2.0" \
  "[ $PF8RC -eq 0 ] && printf '%s' \"\$PF8OUT\" | grep -q 'plugin cache integrity verified'"
# THE INVARIANT: the adopter's OWN layer is byte-identical after the pull
chk "E2E(2) UNTOUCHED: settings.local.json byte-identical (cmp -s)" "cmp -s \"$E8SNAP/settings.local.json\" \"$E8ADOPTER/.claude/settings.local.json\""
chk "E2E(2) UNTOUCHED: the operator's CLAUDE.md byte-identical (cmp -s)" "cmp -s \"$E8SNAP/CLAUDE.md\" \"$E8ADOPTER/CLAUDE.md\""
chk "E2E(2) UNTOUCHED: the operator's owned source byte-identical (cmp -s)" "cmp -s \"$E8SNAP/app.txt\" \"$E8ADOPTER/src/app.txt\""
chk "E2E(2) UNTOUCHED: KICKOFF.local.md byte-identical (cmp -s)" "cmp -s \"$E8SNAP/KICKOFF.local.md\" \"$E8ADOPTER/.kickoff/KICKOFF.local.md\""
chk "E2E(2) CREDENTIAL-SAFE: the planted secret is ABSENT from all pull output" "! printf '%s' \"\$E8POUT\" | grep -qF '$PLANT'"

# no-machine-entry sibling → ZERO claude on pull (the dogfood-safety gate, in the E2E flow)
E8DF="$(mk)"; E8DFCLONE="$(mk)"; E8DFCFG="$(mk)"; E8DFLOG="$(mk)/stub.log"; E8DFSTUB="$(mk)"; E8DFREG="$(mk)/adopters.json"
write_stub_claude "$E8DFSTUB"
git clone -q "$FCORE" "$E8DFCLONE"; git -C "$E8DFCLONE" checkout -q --detach core-vA
mkdir -p "$E8DF/.kickoff/state" "$E8DF/memory"; printf '# memory index\n' > "$E8DF/memory/MEMORY.md"
cat > "$E8DF/.kickoff/instance.env" <<EOF
export KICKOFF_CORE_DIR="$E8DFCLONE"
export KICKOFF_CORE_REMOTE="$FCORE"
export TELEGRAM_STATE_DIR="$E8DF/.kickoff/chan"
export MC_STATE_FILE="$E8DF/.kickoff/state/mission-state.json"
export MEMORY_DB="$E8DF/.kickoff/state/memory-index.db"
export MEMORY_HOOK_LOG="$E8DF/.kickoff/state/memory-hook.log"
EOF
python3 "$E8DFCLONE/scripts/adopt-manifest.py" gen-shim --repo "$E8DF" --name mc --source core-vA >/dev/null 2>&1 || true
: > "$E8DFLOG"
KICKOFF_ADOPTERS_REGISTRY="$E8DFREG" KICKOFF_CORE_DIR="$E8DFCLONE" CLAUDE_CONFIG_DIR="$E8DFCFG" \
  CLAUDE_STUB_LOG="$E8DFLOG" PATH="$E8DFSTUB:$PATH" REPO_DIR="$E8DF" bash "$KICKOFF" pull core-vB >/dev/null 2>&1 || true
chk "E2E(2) DOGFOOD: a no-machine-entry sibling drives ZERO \`claude\` calls on pull (stub log empty)" "[ ! -s \"$E8DFLOG\" ]"

# ── (3) eject (last sibling) → full teardown, byte-for-byte pristine ──
E8ERC=0; E8EOUT="$(CLAUDE_CONFIG_DIR="$E8CFG" KICKOFF_ADOPTERS_REGISTRY="$E8REG" PATH="$E8STUB:$PATH" \
  bash "$KICKOFF" eject --dir "$E8ADOPTER" --no-archive --delete-data --confirm-destroy 2>&1)" || E8ERC=$?
chk "E2E(3) eject: exits 0" "[ $E8ERC -eq 0 ]"
chk "E2E(3) eject: settings.json byte-restored to the pre-adopt (committed) 4-space form (both keys gone)" \
  "cmp -s \"$E8COMMITTED\" \"$E8ADOPTER/.claude/settings.json\""
chk "E2E(3) eject: settings.json is STILL 4-space" "grep -q '^    \"permissions\"' \"$E8ADOPTER/.claude/settings.json\""
chk "E2E(3) eject: the user-global cache (ALL versions) is removed (isolated cfg)" \
  "[ ! -d \"$E8CFG/plugins/cache/kickoff-local/kickoff\" ]"
chk "E2E(3) eject: the marketplace is removed from the isolated known_marketplaces" \
  "! grep -q kickoff-local \"$E8CFG/plugins/known_marketplaces.json\""
chk "E2E(3) eject: the adopters registry row is dropped (0 rows left)" "[ \"\$(jq '.adopters|length' \"$E8REG\")\" = 0 ]"
chk "E2E(3) eject: tracked tree byte-restored — only the preserved kickoff-data/ deliverable remains (§E split-charter)" \
  "[ -d \"$E8ADOPTER/kickoff-data\" ] && [ -z \"\$(git -C \"$E8ADOPTER\" status --porcelain | grep -v '^?? kickoff-data/')\" ]"
chk "E2E(3) eject: the planted secret SURVIVES in settings.local.json" \
  "grep -qF '$PLANT' \"$E8ADOPTER/.claude/settings.local.json\""
chk "E2E(3) eject CREDENTIAL-SAFE: the secret is ABSENT from all eject output" \
  "! printf '%s' \"\$E8EOUT\" | grep -qF '$PLANT'"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "7. Slice 4 — MC lifecycle hook (spine) + rich mc-report skill (v0.9)"
# ══════════════════════════════════════════════════════════════════════════════════════
# The read-side of the brownfield mesh, in TWO plug-and-play layers, NEITHER touching a charter:
#   (A) the MECHANICAL SPINE — plugin/hooks/mc-hook.sh, wired via hooks.json under SubagentStart +
#       SubagentStop (wildcard matcher), streams every subagent's allocation (working/done + the
#       final message) into the ADOPTER's board with ZERO agent-file edits; eject drops the plugin
#       keys and it stops, clean.
#   (B) the RICH LAYER — the discoverable mc-report SKILL (byte-mirrored across plugin/ + .claude/)
#       the agent reaches for at the semantic beats (decision / milestone / completion-with-artifact).
# The hook is proven against a FIXTURE adopter board in mktemp -d (never the live core board), with
# the REAL SubagentStop key names, an INJECTION probe, the board-targeting canary, the non-fatality
# lanes, and a RED-FIRST mutation showing the lane fails on a mis-mapped payload.

# ── (a) hooks.json wires SubagentStart + SubagentStop → mc-hook.sh (wildcard matcher); NOT PostToolUse
chk "hooks.json: SubagentStart → mc-hook.sh via \${CLAUDE_PLUGIN_ROOT} (wildcard matcher '*')" \
  "python3 -c \"import json;d=json.load(open('$PLUGIN/hooks/hooks.json'));e=d['hooks']['SubagentStart'][0];h=e['hooks'][0];assert e.get('matcher')=='*';assert h['type']=='command' and 'CLAUDE_PLUGIN_ROOT' in h['command'] and 'mc-hook.sh' in h['command']\""
chk "hooks.json: SubagentStop → mc-hook.sh via \${CLAUDE_PLUGIN_ROOT} (wildcard matcher '*')" \
  "python3 -c \"import json;d=json.load(open('$PLUGIN/hooks/hooks.json'));e=d['hooks']['SubagentStop'][0];h=e['hooks'][0];assert e.get('matcher')=='*';assert h['type']=='command' and 'CLAUDE_PLUGIN_ROOT' in h['command'] and 'mc-hook.sh' in h['command']\""
chk "hooks.json: PostToolUse is NOT wired (MC is signal, not a per-tool play-by-play)" \
  "python3 -c \"import json;d=json.load(open('$PLUGIN/hooks/hooks.json'));assert 'PostToolUse' not in d['hooks']\""
chk "mc-hook.sh is present + executable" "[ -x '$PLUGIN/hooks/mc-hook.sh' ]"
chk "mc-hook.sh NEVER emits a literal 'exit 2' (a Subagent-hook exit 2 BLOCKS the turn)" \
  "! grep -qE 'exit[[:space:]]+2' '$PLUGIN/hooks/mc-hook.sh'"
chk "mc-hook.sh routes through the adopter shim (.kickoff/bin/mc), never the bare mc-update.py default" \
  "grep -qF '.kickoff/bin/mc' '$PLUGIN/hooks/mc-hook.sh' && ! grep -qF 'mission-control/mc-update.py' '$PLUGIN/hooks/mc-hook.sh'"

# ── (b) the rich mc-report skill: present in BOTH trees + BYTE-IDENTICAL + a triggering description
chk "plugin skill present: mc-report" "[ -f '$PLUGIN/skills/mc-report/SKILL.md' ]"
chk "mc-report SKILL copies are BYTE-IDENTICAL (plugin/ vs .claude/)" \
  "cmp -s '$PLUGIN/skills/mc-report/SKILL.md' '$REPO/.claude/skills/mc-report/SKILL.md'"

# ── SKILL PARITY, ALL OF THEM — default-deny, exceptions must be DECLARED ─────────────────────────
# Until core-v0.16 exactly ONE skill (mc-report, above) was parity-checked, so every other skill could
# diverge in silence — and adopters run the plugin/ copy, so a divergence means they get something
# other than what was tested here. It bit for real: the v0.16 candidate carried the gardener rewrite in
# .claude/skills/crew-review/ while plugin/skills/crew-review/ still held the old text, and it was
# caught by a hand-run `diff` during the release, not by any gate.
#
# Some divergence is INTENTIONAL — the plugin copy ships to adopters, where repo != core, so an
# origin-only aside is correctly absent there. That is exactly why this is default-deny with a named
# allow-list: an intentional difference costs one line and a reason here; an accidental one goes RED.
# To add an exception, state WHY the two copies must differ. If you cannot, they must not.
_PARITY_EXCEPT=" mission-control "   # plugin copy omits an origin-only "(where repo==core)" aside
_parity_bad=""; _parity_n=0; _parity_skipped=""
for _sk in "$REPO"/.claude/skills/*/; do
  _s="$(basename "$_sk")"
  [ -f "$PLUGIN/skills/$_s/SKILL.md" ] || continue          # plugin-absent is the shipping-set question, not parity
  case "$_PARITY_EXCEPT" in *" $_s "*) _parity_skipped="$_parity_skipped $_s"; continue ;; esac
  _parity_n=$((_parity_n + 1))
  cmp -s "$_sk/SKILL.md" "$PLUGIN/skills/$_s/SKILL.md" || _parity_bad="$_parity_bad $_s"
done
chk "ALL skills present in both trees are BYTE-IDENTICAL (checked:$_parity_n, declared exceptions:${_parity_skipped:- none}) — drift ships adopters something untested${_parity_bad:+ — DIVERGED:$_parity_bad}" \
  "[ -z '$_parity_bad' ]"
# Non-vacuity: a parity loop that checked nothing would pass silently, which is the failure this file
# exists to prevent. Assert it actually compared a meaningful number of skills.
chk "skill-parity loop is NON-VACUOUS (compared >= 5 skills, not an empty glob)" \
  "[ '$_parity_n' -ge 5 ]"
chk "mc-report description triggers on the semantic-report moment (decision · milestone · completion/artifact)" \
  "python3 -c \"t=open('$PLUGIN/skills/mc-report/SKILL.md').read();fm=t.split('---')[1].lower();assert 'decision' in fm and 'milestone' in fm and ('artifact' in fm or 'completion' in fm)\""

# ── (c) THE HOOK LANE — feed REAL SubagentStart/Stop JSON to a FIXTURE adopter board ──
# Board-targeting defect canary: snapshot the LIVE core board bytes; a wrong-board write is the real
# bug this hook must never make, so assert the core board is byte-UNCHANGED after every fixture write.
S4CORE="$REPO/mission-control/mission-state.json"
S4CORE_SNAP="$(mktemp)"; printf '%s\n' "$S4CORE_SNAP" >> "$CLEANUP_LIST"
S4CORE_EXISTED=0; if [ -f "$S4CORE" ]; then cp "$S4CORE" "$S4CORE_SNAP"; S4CORE_EXISTED=1; fi

S4="$(mk)"; mkdir -p "$S4/.kickoff/bin" "$S4/.kickoff/state/mission-control"
# the REAL mc seam shim (gen-shim → byte-identical to what a real `kickoff adopt` writes)
python3 "$AM" gen-shim --repo "$S4" --name mc --source core-vTEST >/dev/null
S4BOARD="$S4/.kickoff/state/mission-control/mission-state.json"
# instance.env points KICKOFF_CORE_DIR at the REAL core (so the shim finds mc-update.py) + MC_STATE_FILE
# at the FIXTURE board (so mc-update writes THERE, never the core default).
printf 'export KICKOFF_CORE_DIR=%q\nexport MC_STATE_FILE=%q\n' "$REPO" "$S4BOARD" > "$S4/.kickoff/instance.env"
# a PRISTINE skeleton — never seeded from a live script (a live-seeded fixture rots on the dogfood board's next change)
printf '{"project":"fixture","headline":"","human_plate":[],"in_progress":[],"functions":[],"blocked":[],"decided":[],"done":[],"activity":[]}\n' > "$S4BOARD"

# SubagentStart (REAL key: agent_type) → function planner working
S4_START_RC=0
printf '{"hook_event_name":"SubagentStart","agent_type":"planner","session_id":"s","agent_id":"a","cwd":"%s"}' "$S4" \
  | CLAUDE_PROJECT_DIR="$S4" bash "$PLUGIN/hooks/mc-hook.sh" || S4_START_RC=$?
chk "hook SubagentStart: exit 0 (telemetry never blocks the subagent turn)" "[ $S4_START_RC -eq 0 ]"
chk "hook SubagentStart: functions[planner].status==working landed in the FIXTURE board" \
  "python3 -c \"import json;d=json.load(open('$S4BOARD'));assert any(x['name']=='planner' and x['status']=='working' for x in d['functions'])\""

# SubagentStop with a HOSTILE message (untrusted last_assistant_message) → done + log, NO injection.
# Build the payload in python (avoids bash quoting hell): the message carries $()/backtick/quote/; payloads.
S4_STOP_RC=0
python3 -c "import sys,json;fix=sys.argv[1];msg='pwn: \$(touch %s/INJECTED) \`touch %s/INJECTED2\` \"; echo MARKER_S4_PWNED'%(fix,fix);print(json.dumps({'hook_event_name':'SubagentStop','agent_type':'planner','last_assistant_message':msg}))" "$S4" \
  | CLAUDE_PROJECT_DIR="$S4" bash "$PLUGIN/hooks/mc-hook.sh" || S4_STOP_RC=$?
chk "hook SubagentStop: exit 0" "[ $S4_STOP_RC -eq 0 ]"
chk "hook SubagentStop: functions[planner] flipped to status==done (upsert by name, not a 2nd row)" \
  "python3 -c \"import json;d=json.load(open('$S4BOARD'));f=[x for x in d['functions'] if x['name']=='planner'];assert len(f)==1 and f[0]['status']=='done'\""
chk "hook SubagentStop: the final message is on the 📡 feed sourced 'planner' (signal-only)" \
  "python3 -c \"import json;d=json.load(open('$S4BOARD'));a=d['activity'];assert a[-1]['source']=='planner' and 'MARKER_S4_PWNED' in a[-1]['text']\""
chk "hook INJECTION-SAFE: the \$()/backtick payload was stored as LITERAL text, NEVER executed" \
  "[ ! -e '$S4/INJECTED' ] && [ ! -e '$S4/INJECTED2' ]"
if [ "$S4CORE_EXISTED" = 1 ]; then
  chk "hook BOARD-TARGET: live core mission-state.json byte-UNCHANGED (wrote the ADOPTER board only)" \
    "cmp -s \"$S4CORE_SNAP\" \"$S4CORE\""
fi

# ── (d) NON-FATALITY lanes — garbage / missing shim / no project dir → exit 0, no corruption ──
S4SNAP="$(mktemp)"; printf '%s\n' "$S4SNAP" >> "$CLEANUP_LIST"; cp "$S4BOARD" "$S4SNAP"
S4_GARBAGE_RC=0
printf 'this is not json at all }{' | CLAUDE_PROJECT_DIR="$S4" bash "$PLUGIN/hooks/mc-hook.sh" || S4_GARBAGE_RC=$?
chk "hook NON-FATAL: garbage stdin → exit 0 AND the board is byte-unchanged (no corruption)" \
  "[ $S4_GARBAGE_RC -eq 0 ] && cmp -s \"$S4SNAP\" \"$S4BOARD\""

S4NOADOPT="$(mk)"   # a dir with NO .kickoff/bin/mc — repo not adopted / mid-pull
S4_NOSHIM_RC=0
printf '{"hook_event_name":"SubagentStart","agent_type":"planner"}' \
  | CLAUDE_PROJECT_DIR="$S4NOADOPT" bash "$PLUGIN/hooks/mc-hook.sh" || S4_NOSHIM_RC=$?
chk "hook NON-FATAL: no .kickoff/bin/mc shim (unadopted repo / mid-pull) → fail-open exit 0" "[ $S4_NOSHIM_RC -eq 0 ]"

S4_NOPROJ_RC=0
printf '{"agent_type":"planner"}' | env -u CLAUDE_PROJECT_DIR bash "$PLUGIN/hooks/mc-hook.sh" || S4_NOPROJ_RC=$?
chk "hook NON-FATAL: no CLAUDE_PROJECT_DIR → exit 0 (nothing to anchor)" "[ $S4_NOPROJ_RC -eq 0 ]"

# ── (e) RED-FIRST proof (non-vacuity) — a MIS-MAPPED payload field makes the lane RED ──
# Break the hook's field extraction (agent_type → agent, a key the REAL payload never carries), fire
# the SAME Start payload at a FRESH fixture board, and assert NO row lands: the (c) assertion above
# would go RED on this broken hook — proving the lane isn't vacuous (a fixture that can't fail is no test).
S4MUT="$(mk)"; mkdir -p "$S4MUT/.kickoff/bin" "$S4MUT/.kickoff/state/mission-control"
python3 "$AM" gen-shim --repo "$S4MUT" --name mc --source core-vTEST >/dev/null
S4MBOARD="$S4MUT/.kickoff/state/mission-control/mission-state.json"
printf 'export KICKOFF_CORE_DIR=%q\nexport MC_STATE_FILE=%q\n' "$REPO" "$S4MBOARD" > "$S4MUT/.kickoff/instance.env"
printf '{"project":"fixture","headline":"","human_plate":[],"in_progress":[],"functions":[],"blocked":[],"decided":[],"done":[],"activity":[]}\n' > "$S4MBOARD"
sed 's/d.get("agent_type")/d.get("agent")/' "$PLUGIN/hooks/mc-hook.sh" > "$S4MUT/broken-hook.sh"
S4_MUT_RC=0
printf '{"hook_event_name":"SubagentStart","agent_type":"planner"}' \
  | CLAUDE_PROJECT_DIR="$S4MUT" bash "$S4MUT/broken-hook.sh" >/dev/null 2>&1 || S4_MUT_RC=$?
chk "RED-FIRST: a hook that mis-maps agent_type lands NO row (the lane FAILS on broken code — non-vacuous)" \
  "! python3 -c \"import json;d=json.load(open('$S4MBOARD'));assert any(x.get('name')=='planner' for x in d['functions'])\""
chk "RED-FIRST: even the BROKEN hook exits 0 (a broken telemetry hook must never block the turn)" "[ $S4_MUT_RC -eq 0 ]"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "9. #8 — the CLI's own bookkeeping is not adopter drift (2026-08-12, the whole fleet)"
# ══════════════════════════════════════════════════════════════════════════════════════
# WHAT HAPPENED. The vendor CLI stamps `.orphaned_at` (a millisecond epoch) into a cached plugin
# version dir once no USER-scope marketplace references it. kickoff's marketplace is registered
# PER-ADOPTER at project scope, so on any box where that is the only registration the CLI orphans
# every cached kickoff version as a matter of course. The cache-vs-core file-set compare then saw
# one extra file and reported DRIFT — and #8 is fail-closed, on supervisor start AND on every engine
# hop. Measured on this machine: SIX orgs in a hard preflight failure simultaneously, each one
# restart away from not booting a session, while the org that found it (no interactive plugin entry,
# so it skips #8 entirely) looked perfectly healthy.
#
# WHY A LANE AND NOT JUST A FIX. Nothing detected this. It surfaced because an unrelated suite went
# red and the first assumption — "my change broke it" — happened to be wrong. A drift check that
# cries tampering at the vendor's housekeeping erodes exactly the trust it exists to build.
#
# The lanes are the whole contract: ignore the marker, still catch real drift, and refuse to let the
# exemption travel to the core side or one directory down, where a payload could hide behind the
# same name.
VB_CORE="$(mk)"; VB_CFG="$(mk)"; VB_REPO="$(mk)"
mkdir -p "$VB_CORE/plugin/.claude-plugin" "$VB_CORE/plugin/hooks" "$VB_REPO/.kickoff"
printf '{"name":"vbp","version":"9.9.9"}\n' > "$VB_CORE/plugin/.claude-plugin/plugin.json"
printf 'payload\n'                          > "$VB_CORE/plugin/hooks/h.py"
# `entries` is REQUIRED — the loader calls a manifest without it malformed and exits FATAL. A first
# draft of this fixture omitted it, and every lane went red for a reason that had nothing to do with
# the check: the world could not be built, so the assertions were reporting on nothing. That is why
# the CONTROL lane below runs first and asserts the clean tree VERIFIES rather than assuming it.
printf '{"entries":[],"machine_entries":[{"kind":"plugin","marketplace":"vbm","plugin":"vbp"}]}\n' \
  > "$VB_REPO/.kickoff/adopt-manifest.json"
VB_CACHE="$VB_CFG/plugins/cache/vbm/vbp/9.9.9"
mkdir -p "$(dirname "$VB_CACHE")"
cp -a "$VB_CORE/plugin" "$VB_CACHE"
vb_verify() { python3 "$AM" plugin-cache-verify --repo "$VB_REPO" --core-dir "$VB_CORE" --config-dir "$VB_CFG" >/dev/null 2>&1; }

chk "(9) CONTROL: a byte-identical cache verifies (else every lane below is vacuous)" "vb_verify"
printf '1786521416169\n' > "$VB_CACHE/.orphaned_at"
chk "(9) the CLI's top-level .orphaned_at is NOT drift — the fleet-killer case" "vb_verify"
rm -f "$VB_CACHE/.orphaned_at"
printf 'x\n' > "$VB_CACHE/EXTRA.md"
chk "(9) NEGATIVE CONTROL: a real extra file STILL fails (the check was not disabled)" "! vb_verify"
rm -f "$VB_CACHE/EXTRA.md"
printf '1\n' > "$VB_CORE/plugin/.orphaned_at"
chk "(9) the exemption is CACHE-SIDE only: the same name in the pinned CORE is still seen" "! vb_verify"
rm -f "$VB_CORE/plugin/.orphaned_at"
mkdir -p "$VB_CACHE/hooks"; printf '1\n' > "$VB_CACHE/hooks/.orphaned_at"
chk "(9) the exemption is TOP-LEVEL only: the same name one dir down is not a hiding place" "! vb_verify"
rm -f "$VB_CACHE/hooks/.orphaned_at"
chk "(9) …and removing it returns the tree to verified (the lane cleaned up after itself)" "vb_verify"
echo

# ── belt-and-braces: the LIVE ~/.claude/plugins was NEVER touched by this whole run ──
# BYTE-UNCHANGED vs the suite-start snapshot (mirrors the ORIGIN settings.json CANARY): tolerant of a
# pre-existing real-adoption kickoff-local entry, but catches ANY write the isolated suite leaks.
if [ "$LIVE_KM_EXISTED" = 1 ]; then
  chk "ISOLATION: live known_marketplaces BYTE-UNCHANGED across the suite (never touched)" \
    "cmp -s \"$LIVE_KM_SNAP\" \"$LIVE_KM\""
elif [ -f "$LIVE_KM" ]; then
  bad "ISOLATION: the suite CREATED a live known_marketplaces.json — a leak into ~/.claude!"
fi
# …and the live INSTALL registry (#8 dogfood canary): sha256/byte compare vs the suite-start
# snapshot — the new install-row gate + its topology cases must never have touched ~/.claude.
if [ "$LIVE_IP_EXISTED" = 1 ]; then
  chk "ISOLATION (#8): live installed_plugins.json BYTE-UNCHANGED across the suite (never touched)" \
    "cmp -s \"$LIVE_IP_SNAP\" \"$LIVE_IP\""
elif [ -f "$LIVE_IP" ]; then
  bad "ISOLATION (#8): the suite CREATED a live installed_plugins.json — a leak into ~/.claude!"
fi

# ── CANARY check (§5 fix-round-3): the ORIGIN's live .claude/settings.json must be byte-identical to its
#    pre-suite snapshot. Any cwd leak into the live repo (the _resync_plugin_cache bug, or a regression of
#    it) dirties it — FAIL LOUDLY here AND auto-restore so the suite never LEAVES the origin dirtied. ─────
if [ "$ORIGIN_EXISTED" = 1 ] && cmp -s "$ORIGIN_SNAP" "$ORIGIN_SETTINGS"; then
  ok "CANARY: the ORIGIN's .claude/settings.json is BYTE-UNCHANGED across the whole suite (no cwd leak into the live repo)"
elif [ "$ORIGIN_EXISTED" = 0 ] && [ ! -f "$ORIGIN_SETTINGS" ]; then
  ok "CANARY: no origin .claude/settings.json existed or was created during the suite (no cwd leak)"
else
  bad "CANARY: the ORIGIN's .claude/settings.json CHANGED during the suite — a cwd LEAK into the LIVE repo!"
  printf '     ↳ the §5 _resync_plugin_cache cwd bug (or a regression of it) wrote into %s\n' "$ORIGIN_SETTINGS"
  if [ "$ORIGIN_EXISTED" = 1 ]; then
    cp "$ORIGIN_SNAP" "$ORIGIN_SETTINGS" && printf '     ↳ AUTO-RESTORED %s from the pre-suite snapshot\n' "$ORIGIN_SETTINGS"
  else
    rm -f "$ORIGIN_SETTINGS" && printf '     ↳ AUTO-REMOVED the leaked %s (it did not exist pre-suite)\n' "$ORIGIN_SETTINGS"
  fi
fi

echo "──────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "  ✅ §5 THE PLUGIN (slices 1–8) holds"; exit 0; } || { echo "  ❌ see failures above"; exit 1; }
