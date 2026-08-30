#!/usr/bin/env bash
# adopt-brains-selftest.sh — adoption must land the BRAINS, not just the plumbing.
#
#   bash scripts/adopt-brains-selftest.sh
#
# THE DEFECT (measured on this box, 2026-08-06, across six live adopters). `kickoff adopt` wires
# every mechanical seam — gates, pin, manifest, shims, memory dir, plugin — and then hands the ONE
# step that needs a mind to a printed English sentence:
#
#     [kickoff] HANDOFF: the crew-authoring + CLAUDE.md adaptation is the INTELLIGENT step — a bash
#               script can't read your repo's domains. Run `/adopt` in a Claude Code session IN …
#
# `cmd_adopt` then returns 0. Nothing in the engine ever invokes the authoring motion: the machinery
# EXISTS and is fully implemented (`crew-probe.py`, `adopt-manifest.py gen-agent`) and had ZERO
# callers outside the skill prose and a selftest. So an adopted org gets gates, a pin, a bot and a
# worker — and then sits there, because nothing authorises it to act. Live evidence: one adopter ran
# 35 memory-writing sessions and still has no `.claude/agents/` at all; two of them carry
# the byte-identical 76-byte CLAUDE.md that is nothing but the kickoff include.
#
# THREE THINGS FAILED AT ONCE, and this suite holds each one apart:
#
#  1. NO SEAM. The only trace of the missing half was a log line. On `--accept` (the phone/headless
#     path — the one an operator who never opens a terminal actually takes) even the interactive
#     last-mile offers are suppressed, so the sentence scrolls past in a file nobody reads and NOTHING
#     durable lands on disk. A log line is not a seam: preflight, verify and the worker's re-ground
#     have nothing to key on. Fixed by a recorded `.kickoff/adopt-brains-pending` marker.
#
#  2. A DEAD DETECTOR. The escalation that was supposed to catch this — ADOPT INCOMPLETE — is
#     predicated on "the lefthook gates are unwired", and `kickoff adopt` now ALWAYS wires those
#     gates (`_ensure_kickoff_gates`, authored-by-adopt). In `kickoff verify` the escalation is
#     nested inside the `else` arm of the gate check, so it cannot execute once the gate file
#     exists. Every adopter on this box has that gate file, so not one of them could ever trip the
#     banner. The detector has been structurally dead for every modern adoption — which is the
#     "reports on a world nobody lives in" failure, reporting GREEN. THAT is why this suite's
#     detector lanes run with the gates WIRED: a fixture that strips the gates tests the old bug,
#     not this one, and would go green while a brainless org stays invisible.
#
#  3. NO HEADLESS ACTUATOR. The authoring motion could only be reached by a human typing `/adopt`
#     in an interactive session. The operator steers from a phone; a fix that depends on him
#     opening a terminal is not a fix. The re-ground prompt — the one thing that runs on EVERY
#     worker boot and can read the repo — never mentioned the crew being absent, `/adopt`,
#     crew-probe or gen-agent. It assumed specialists already existed.
#
# HONESTY ABOUT WHAT IS ASSERTED HERE. Bash cannot author a charter, and a GENERATED generic charter
# would be worse than the 76-byte stub because it LOOKS done. So this suite asserts the SEAM, the
# DETECTORS and the ACTUATOR'S WIRING — that a brainless org is marked, is loudly visible to every
# boot path, and that the worker is instructed to author before it starts queued work. The authoring
# itself is done by the worker (a real mind reading the real repo), and no assertion here claims
# otherwise.
#
# TOPOLOGY — deliberately NOT this dev checkout ([[the-origin-is-not-the-deployment]]). The core is
# a clone at a separate path carrying the WORKING-TREE scripts (so the current edit is what runs),
# driven through ITS OWN front door; the adopter is a fresh brownfield repo with two obviously
# unowned domains. A fixture where the repo IS the core resolves paths that no adopter has.
# Hermetic: scratch registry + CLAUDE_CONFIG_DIR + a stub `claude`; the live ~/.kickoff, ~/.claude,
# ~/.local/bin and every live adopter are never read or written.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# The engine reads config from the environment, and an ambient value WINS over a fixture's
# instance.env by design — so a live value leaking in false-greens the whole suite.
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

command -v git     >/dev/null 2>&1 || { echo "  ❌ git not found";     exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "  ❌ python3 not found"; exit 1; }

CLEANUP_LIST="$(mktemp)"
mk() { local d; d="$(mktemp -d)"; printf '%s\n' "$d" >> "$CLEANUP_LIST"; printf '%s' "$d"; }
trap 'while IFS= read -r _d; do [ -n "$_d" ] && rm -rf "$_d"; done < "$CLEANUP_LIST"; rm -f "$CLEANUP_LIST"' EXIT

KO="$REPO/scripts/kickoff"
CP="$REPO/scripts/crew-probe.py"
PF="$REPO/scripts/preflight.sh"
SR="$REPO/scripts/session-run.sh"
SKILL_LOCAL="$REPO/.claude/skills/adopt/SKILL.md"
SKILL_PLUGIN="$REPO/plugin/skills/adopt/SKILL.md"
for f in "$KO" "$CP" "$PF" "$SR" "$SKILL_LOCAL" "$SKILL_PLUGIN"; do
  [ -r "$f" ] || { printf '  ❌ not readable: %s\n' "$f"; exit 1; }
done

echo "▶ adopt-brains selftest — adoption lands the BRAINS (seam · detectors · headless actuator)"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "0. THE PREDICATE — one implementation, shared by every consumer"
# The brains question is asked in three places (adopt, verify, preflight). Three hand-written
# copies is the shape that let the secret-keydir contract disagree with itself four ways inside one
# slice, each failing GREEN. So it must be ONE callable, and crew-probe.py is its home — it is
# already the crew prober, and it already TRAVELS (scripts/core-manifest.txt), which is what makes
# a check named in the re-ground prompt resolve on an adopter instead of exiting 127 in silence.
chk "crew-probe.py exposes a \`brains-verdict\` verb (the single shared predicate)" \
  "python3 \"$CP\" brains-verdict --repo \"$REPO\" >/dev/null 2>&1; [ \$? -ne 2 ]"
chk "crew-probe.py's usage line advertises brains-verdict (discoverable, not a hidden verb)" \
  "python3 \"$CP\" 2>&1 | grep -q 'brains-verdict'"
chk "scripts/core-manifest.txt ships crew-probe.py (else the predicate is 127 on every adopter)" \
  "grep -q 'scripts/crew-probe.py' \"$REPO/scripts/core-manifest.txt\""

# THE CALLER TEST. The machinery was fully implemented and had NO caller anywhere in the engine —
# referenced only by skill prose and a selftest. An implementation nothing invokes is the same
# defect class as a config nothing reads ([[verify-the-read-not-just-the-write]]): every property
# holds except "does anything consume this".
chk "scripts/kickoff CALLS crew-probe.py (the crew prober finally has an engine caller)" \
  "grep -q 'crew-probe\.py' \"$KO\""
chk "preflight.sh CALLS crew-probe.py (the boot path asks the same question, not its own copy)" \
  "grep -q 'crew-probe\.py' \"$PF\""
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "1. THE PREDICATE'S OWN TRUTH TABLE (unit — no adoption yet)"
UT="$(mk)"
mkdir -p "$UT/bare" "$UT/crewed" "$UT/bodied" "$UT/both"
# (a) bare: the EXACT 76-byte shape the affected live adopters carry, and zero agents.
printf '<!-- kickoff:begin core-v0.18 -->\n@.kickoff/KICKOFF.md\n<!-- kickoff:end -->\n' > "$UT/bare/CLAUDE.md"
# (b) crewed: one real charter, charter file still the bare include.
mkdir -p "$UT/crewed/.claude/agents"
cp "$UT/bare/CLAUDE.md" "$UT/crewed/CLAUDE.md"
printf -- '---\nname: api\ndescription: owns the api\ntools: Read\n---\n\nYou own the API domain.\n' \
  > "$UT/crewed/.claude/agents/api.md"
# (c) bodied: a real charter body, no crew.
{ cat "$UT/bare/CLAUDE.md"; printf '\n# acme-shop\n\nThe real charter body a mind wrote.\n'; } > "$UT/bodied/CLAUDE.md"
# (d) both.
mkdir -p "$UT/both/.claude/agents"
cp "$UT/bodied/CLAUDE.md" "$UT/both/CLAUDE.md"
cp "$UT/crewed/.claude/agents/api.md" "$UT/both/.claude/agents/api.md"

bv() { python3 "$CP" brains-verdict --repo "$1" 2>/dev/null; }
bv_rc() { python3 "$CP" brains-verdict --repo "$1" >/dev/null 2>&1; printf '%s' "$?"; }

chk "bare 76-byte include + zero agents  → BRAINLESS (non-zero)" "[ \"\$(bv_rc \"$UT/bare\")\" != 0 ]"
chk "  … and it names BOTH gaps (no crew AND bare charter)" \
  "bv \"$UT/bare\" | grep -qi 'crew' && bv \"$UT/bare\" | grep -qi 'charter'"
chk "crew present, charter bare        → still flagged (the body is authored, the crew is not touched)" \
  "[ \"\$(bv_rc \"$UT/crewed\")\" != 0 ]"
chk "  … and it does NOT claim the crew is missing (restraint: a crew that exists is never re-proposed)" \
  "! bv \"$UT/crewed\" | grep -qi 'no domain crew'"
chk "charter bodied, no crew           → still flagged (names the crew gap)" \
  "[ \"\$(bv_rc \"$UT/bodied\")\" != 0 ] && bv \"$UT/bodied\" | grep -qi 'crew'"
chk "crew + charter body               → BRAINS PRESENT (exit 0) — the negative control" \
  "[ \"\$(bv_rc \"$UT/both\")\" = 0 ]"
# A repo with no CLAUDE.md at all is NOT an adopted repo; the predicate must not invent a finding.
chk "a dir with no CLAUDE.md at all is reported, not crashed (robust on a non-adopter)" \
  "python3 \"$CP\" brains-verdict --repo \"$UT\" >/dev/null 2>&1; [ \$? -ne 2 ]"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
# THE DEPLOY FIXTURE — a core at its own path carrying the working-tree scripts, and a brownfield
# adopter with two obviously unowned domains. `git clone --local` then overlay the working tree:
# a `cp -r` of the checkout drags in the origin's gitignored .kickoff/instance.env, which pins
# KICKOFF_CORE_DIR at the origin and false-greens the whole suite on unfixed code.
# ══════════════════════════════════════════════════════════════════════════════════════
CORE="$(mk)"
git clone -q --local --no-hardlinks "$REPO" "$CORE" 2>/dev/null || { echo "  ❌ could not clone the core"; exit 1; }
cp -a "$REPO/scripts/." "$CORE/scripts/"          # the WORKING TREE — we test the current edit
cp -a "$REPO/plugin/."  "$CORE/plugin/"
rm -rf "$CORE/.kickoff"
[ -e "$CORE/.kickoff/instance.env" ] && { echo "  ❌ fixture core carries the origin's instance.env"; exit 1; }
git -C "$CORE" add -A >/dev/null 2>&1
git -C "$CORE" -c user.email=t@t.t -c user.name=t commit -qm core >/dev/null 2>&1
git -C "$CORE" tag -f core-vT >/dev/null 2>&1
git -C "$CORE" checkout -q --detach core-vT >/dev/null 2>&1

# the stub `claude` — models ONLY `claude plugin marketplace add|install --scope project`, refuses
# to run without CLAUDE_CONFIG_DIR and refuses to write a settings.json outside a temp dir.
STUB="$(mk)"
cat > "$STUB/claude" <<'PYEOF'
#!/usr/bin/env python3
import json, os, shutil, sys, tempfile
if not os.environ.get("CLAUDE_CONFIG_DIR"):
    sys.stderr.write("stub-claude: CLAUDE_CONFIG_DIR unset — refusing (test isolation guard)\n"); sys.exit(3)
a = sys.argv[1:]
if not a or a[0] != "plugin": sys.exit(0)
a = a[1:]; scope = "user"; pos = []; i = 0
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
    # The real CLI does TWO things on install: it enables the plugin AND it SNAPSHOTS the plugin
    # tree into <config>/plugins/cache/<mkt>/<plugin>/<version>/. preflight #8 verifies exactly
    # that snapshot — so a stub that models only the settings.json half leaves #8 with nothing of
    # its own to read, and the check falls through to whatever the REAL box's cache happens to
    # hold. That is how this fixture's verdict came to be decided by a marketplace retirement on
    # 2026-08-12 rather than by anything it asserts. Model the snapshot, and #8 has a hermetic
    # world to verify.
    name, _, mkt = pos[1].partition("@")
    src = ((load().get("extraKnownMarketplaces", {}).get(mkt) or {}).get("source") or {}).get("path")
    if src:   # unknown marketplace => nothing was added at project scope => nothing to snapshot
        try:
            mj = json.load(open(os.path.join(src, ".claude-plugin", "marketplace.json")))
            ent = next((p for p in mj.get("plugins", []) if p.get("name") == name), None)
            if ent is None: raise KeyError("plugin %r not in marketplace %r" % (name, mkt))
            pdir = os.path.normpath(os.path.join(src, ent.get("source") or "./"))
            ver = str(json.load(open(os.path.join(pdir, ".claude-plugin", "plugin.json")))["version"])
            dst = os.path.join(os.environ["CLAUDE_CONFIG_DIR"], "plugins", "cache", mkt, name, ver)
            if os.path.exists(dst): shutil.rmtree(dst)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copytree(pdir, dst)
        except Exception as e:
            # LOUD, never silent: a stub that half-models the command and says nothing is how a
            # fixture starts reporting on a world nobody lives in.
            sys.stderr.write("stub-claude: could not snapshot %s into the cache: %s\n" % (pos[1], e))
            sys.exit(5)
    print("installed %s" % pos[1]); sys.exit(0)
sys.exit(0)
PYEOF
chmod +x "$STUB/claude"

REG="$(mk)/adopters.json"; CFG="$(mk)"
FIX="$(mk)"
mkdir -p "$FIX/src/api" "$FIX/src/web"
printf '{ "name": "acme-shop", "scripts": { "test": "vitest" } }\n' > "$FIX/package.json"
printf 'export const listOrders = () => [];\n' > "$FIX/src/api/orders.ts"
printf 'export const Cart = () => null;\n'     > "$FIX/src/web/cart.tsx"
printf '# acme-shop\n'                         > "$FIX/README.md"
git -C "$FIX" init -q; git -C "$FIX" config user.email t@t.t; git -C "$FIX" config user.name t
git -C "$FIX" add -A; git -C "$FIX" commit -qm baseline

ADOPT_LOG="$(mk)/adopt.log"
adopt_rc=0
REPO_DIR="$FIX" TELEGRAM_STATE_DIR="" KICKOFF_ADOPTERS_REGISTRY="$REG" KICKOFF_CORE_DIR="$CORE" \
  CLAUDE_CONFIG_DIR="$CFG" PATH="$STUB:$PATH" \
  bash "$CORE/scripts/kickoff" adopt --dir "$FIX" --accept </dev/null > "$ADOPT_LOG" 2>&1 || adopt_rc=$?

run_verify()    { REPO_DIR="$1" KICKOFF_CORE_DIR="$CORE" CLAUDE_CONFIG_DIR="$CFG" \
                  KICKOFF_ADOPTERS_REGISTRY="$REG" PATH="$STUB:$PATH" \
                  bash "$CORE/scripts/kickoff" verify --dir "$1" 2>&1; }
# CLAUDE_CONFIG_DIR is as load-bearing here as it is in run_verify one line above, and this lane
# is where it was missing: preflight's plugin-cache check (#8) reads the config dir's plugin cache,
# so without the scratch $CFG it reads the REAL ~/.claude and this fixture's verdict is decided by
# whatever state the BOX's plugin cache happens to be in. Observed 2026-08-12: a `kickoff-local`
# marketplace retired by a plugin audit left an `.orphaned_at` marker in every cached version, which
# reads as DRIFT, which fails preflight, which fails the "a brainless org must still BOOT" lane —
# for a reason that has nothing to do with brains, adoption, or the candidate release. The suite
# header already claims a scratch CLAUDE_CONFIG_DIR; this line is what makes the claim true.
run_preflight() { REPO_DIR="$1" KICKOFF_CORE_DIR="$CORE" CLAUDE_CONFIG_DIR="$CFG" \
                  bash "$CORE/scripts/preflight.sh" 2>&1; }

echo "2. THE ADOPTION ITSELF — the plumbing lands (control), the brains do not (the defect)"
chk "adopt exits 0 (the headless \`--accept\` path an operator on a phone actually takes)" "[ $adopt_rc -eq 0 ]"
# The controls. If these ever go red the fixture stopped adopting for real and every assertion
# below is vacuous — a suite that reports on a world nobody lives in.
chk "CONTROL: gates ARE wired (.kickoff/lefthook-kickoff.yml) — so the gate-predicated detector is dead here" \
  "[ -f '$FIX/.kickoff/lefthook-kickoff.yml' ]"
chk "CONTROL: engine pinned (.kickoff/core.lock)"      "[ -f '$FIX/.kickoff/core.lock' ]"
chk "CONTROL: manifest written"                        "[ -f '$FIX/.kickoff/adopt-manifest.json' ]"
chk "CONTROL: the adopter really IS brainless — zero .claude/agents/*.md" \
  "! ls '$FIX'/.claude/agents/*.md >/dev/null 2>&1"
chk "CONTROL: the adopter's CLAUDE.md really IS the bare include (the live 76-byte shape)" \
  "[ \"\$(wc -c < '$FIX/CLAUDE.md')\" -lt 200 ]"
echo

echo "3. THE SEAM — a brainless adoption leaves DURABLE, DISCLOSED, REVERSIBLE evidence"
# A log line is not a seam. On --accept nobody reads stdout, so the marker is the ONLY thing
# preflight, verify and the worker's re-ground can key on.
MARK="$FIX/.kickoff/adopt-brains-pending"
chk "adopt wrote the durable marker .kickoff/adopt-brains-pending" "[ -f '$MARK' ]"
chk "the marker EXPLAINS itself (a human opening it learns what is missing and what happens next)" \
  "grep -qi 'crew' '$MARK' && grep -qi 'charter' '$MARK'"
# CONSENT RULE: anything written into a repo we do not own is disclosed at the moment it happens…
chk "adopt DISCLOSED the marker in its own output (written, not smuggled)" \
  "grep -q 'adopt-brains-pending' '$ADOPT_LOG'"
chk "adopt's output states plainly that adoption is HALF-finished (not a bare rc=0)" \
  "grep -qi 'BRAINS PENDING\|brains half' '$ADOPT_LOG'"
# …and REVERSIBLE by eject. The marker is DERIVED STATE, so it follows the idiom every other
# derived file in .kickoff/ follows (crew-review.last, announce.count, restart-history): NOT
# manifest-recorded, reversed by the .kickoff/ teardown. Recording it would be actively wrong —
# `adopt-manifest.py verify` reports a recorded-but-absent path as [ FAIL ], so the moment doctor
# retired the marker the repo would fail its own integrity check over a file that did its job.
chk "the marker is NOT manifest-recorded (derived state — recording it would FAIL verify once retired)" \
  "! python3 -c \"import json;m=json.load(open('$FIX/.kickoff/adopt-manifest.json'));raise SystemExit(0 if any(e['path']=='.kickoff/adopt-brains-pending' for e in m['entries']) else 1)\""
chk "the manifest still verifies clean with the marker on disk (no phantom entry)" \
  "python3 \"$CORE/scripts/adopt-manifest.py\" verify --repo '$FIX' >/dev/null 2>&1"
chk "the marker never reaches origin (.kickoff/.gitignore covers it — derived state, not team-shareable)" \
  "git -C '$FIX' check-ignore -q .kickoff/adopt-brains-pending"
# NOT a blanket porcelain-clean: adopt legitimately leaves untracked wiring (.kickoff/, lefthook.yml,
# CLAUDE.md) for the operator to commit. The claim this suite owns is narrower and exact — the MARKER
# is never one of the things a teammate has to ask about.
chk "the marker never surfaces in \`git status -uall\` (it is state, not something to explain)" \
  "! git -C '$FIX' status --porcelain -uall | grep -q 'adopt-brains-pending'"
echo

echo "4. THE DETECTOR — with the gates WIRED (the state every live adopter is in)"
# This is the lane that was structurally impossible before: the ADOPT INCOMPLETE escalation is
# nested inside the `else` arm of the gate check, and adopt always writes the gate. So a brainless
# org could not be seen by verify OR preflight. The gates are wired above — deliberately.
v_rc=0; v_out="$(run_verify "$FIX")" || v_rc=$?
chk "verify FLAGS the brainless org even though the gates are wired" \
  "printf '%s' \"\$v_out\" | grep -q 'BRAINS INCOMPLETE'"
chk "verify's flag names the missing crew" \
  "printf '%s' \"\$v_out\" | grep -A6 'BRAINS INCOMPLETE' | grep -qi 'crew'"
chk "verify's flag is ADVISORY — the exit code is unchanged (it must never brick a bring-up)" \
  "[ $v_rc -eq 0 ]"
p_rc=0; p_out="$(run_preflight "$FIX")" || p_rc=$?
chk "preflight WARNS 'BRAINS INCOMPLETE' at supervisor start (with the gates wired)" \
  "printf '%s' \"\$p_out\" | grep 'BRAINS INCOMPLETE' | grep -q '\[warn\]'"
chk "preflight STILL exits 0 — a brainless org must BOOT (the worker is what fixes it)" \
  "[ $p_rc -eq 0 ]"
# The two predicates must be INDEPENDENT. Folding brains into the gates check is how this defect
# hid for six adopters; a gates-wired repo must still be able to report a brains gap, and the
# gates check must still report its own finding on its own.
chk "preflight still reports the GATES verdict separately (the two predicates did not get merged)" \
  "printf '%s' \"\$p_out\" | grep -qi 'adopt-completeness'"
echo

echo "5. THE HEADLESS ACTUATOR — the worker is told to author the brains BEFORE queued work"
# The operator steers from a phone. A fix that needs him to open a terminal and type `/adopt` is
# not a fix. The re-ground prompt is the only thing that runs on EVERY boot and can read the repo.
chk "the re-ground prompt names the brains predicate (crew-probe.py brains-verdict)" \
  "grep -q 'brains-verdict' \"$SR\""
chk "the re-ground prompt names the durable marker it keys on" \
  "grep -q 'adopt-brains-pending' \"$SR\""
chk "the re-ground prompt orders it BEFORE queued work (author first, not after)" \
  "grep -qi 'before .*queued work\|do NOT start queued work' \"$SR\""
chk "the re-ground prompt routes the drafted crew to the operator for approval (author-then-announce)" \
  "grep -qi 'announce' \"$SR\" && grep -q 'brains' \"$SR\""
# The skill is the procedure the worker follows. Without a headless contract a worker that finds
# the marker has no sanctioned motion and defaults to ASKING — which is the phone-unreachable
# failure all over again.
chk "the adopt SKILL carries a HEADLESS ENTRY CONTRACT" \
  "grep -qi 'HEADLESS ENTRY' \"$SKILL_LOCAL\""
chk "the headless contract names the marker as the entry condition" \
  "grep -q 'adopt-brains-pending' \"$SKILL_LOCAL\""
chk "the headless contract states the RESTRAINT boundary (nothing pre-existing is overwritten)" \
  "grep -qi 'never overwrite\|nothing pre-existing\|only where a domain has no owner' \"$SKILL_LOCAL\""
# The plugin copy is the one adopters actually load. A fix on one surface while the sibling keeps
# teaching the old motion is exactly the class origin-only-path-selftest exists for.
chk "the PLUGIN copy of the adopt skill is byte-identical (adopters load THAT one)" \
  "cmp -s \"$SKILL_LOCAL\" \"$SKILL_PLUGIN\""
echo

echo "6. NEGATIVE CONTROL — author the brains for real; every finding must go quiet"
# Without this, "it flags a brainless org" could be a check that flags EVERYTHING. The brains are
# authored with the engine's OWN machinery (gen-agent), which is the motion the worker runs.
python3 "$CORE/scripts/adopt-manifest.py" gen-agent --repo "$FIX" \
  --name acme-api --domain api --source core-vT >/dev/null 2>&1
python3 "$CORE/scripts/adopt-manifest.py" gen-agent --repo "$FIX" \
  --name acme-web --domain web --source core-vT >/dev/null 2>&1
cat >> "$FIX/CLAUDE.md" <<'CMEOF'

# acme-shop

A storefront: `src/api/` owns orders and fulfilment, `src/web/` owns the cart and checkout UI.
The two domains ship independently and are owned by `acme-api` and `acme-web` respectively.
CMEOF
chk "NEG: gen-agent really authored a crew (the control's control)" \
  "ls '$FIX'/.claude/agents/*.md >/dev/null 2>&1"
chk "NEG: brains-verdict now exits 0 on the real adopter" "[ \"\$(bv_rc \"$FIX\")\" = 0 ]"
nv_out="$(run_verify "$FIX")"
chk "NEG: verify no longer flags BRAINS INCOMPLETE" \
  "! printf '%s' \"\$nv_out\" | grep -q 'BRAINS INCOMPLETE'"
np_out="$(run_preflight "$FIX")"
chk "NEG: preflight no longer warns BRAINS INCOMPLETE" \
  "! printf '%s' \"\$np_out\" | grep -q 'BRAINS INCOMPLETE'"
# The marker is state, and stale state is a lie the day after. `doctor` is the idempotent repair
# verb — it must retire a marker whose condition no longer holds.
REPO_DIR="$FIX" KICKOFF_CORE_DIR="$CORE" CLAUDE_CONFIG_DIR="$CFG" KICKOFF_ADOPTERS_REGISTRY="$REG" \
  PATH="$STUB:$PATH" bash "$CORE/scripts/kickoff" doctor --dir "$FIX" >/dev/null 2>&1 || true
chk "NEG: \`kickoff doctor\` CLEARS the now-stale marker (state that outlives its condition is a lie)" \
  "[ ! -f '$MARK' ]"
echo

echo "7. REVERSIBILITY — eject leaves the repo as it was found"
# The consent rule's second half: anything written into a repo we do not own must be reversible.
# Re-arm the marker so eject has something to reverse (doctor cleared it above).
EFIX="$(mk)"
mkdir -p "$EFIX/src"
printf '# ejectme\n' > "$EFIX/README.md"; printf 'x\n' > "$EFIX/src/a.ts"
git -C "$EFIX" init -q; git -C "$EFIX" config user.email t@t.t; git -C "$EFIX" config user.name t
git -C "$EFIX" add -A; git -C "$EFIX" commit -qm baseline
EREG="$(mk)/adopters.json"; ECFG="$(mk)"; EARCH="$(mk)"
REPO_DIR="$EFIX" TELEGRAM_STATE_DIR="" KICKOFF_ADOPTERS_REGISTRY="$EREG" KICKOFF_CORE_DIR="$CORE" \
  CLAUDE_CONFIG_DIR="$ECFG" PATH="$STUB:$PATH" \
  bash "$CORE/scripts/kickoff" adopt --dir "$EFIX" --accept </dev/null >/dev/null 2>&1 || true
chk "eject fixture: the marker is present before eject (else the reversal proof is vacuous)" \
  "[ -f '$EFIX/.kickoff/adopt-brains-pending' ]"
e_rc=0
e_out="$(REPO_DIR="$EFIX" KICKOFF_ADOPTERS_REGISTRY="$EREG" KICKOFF_CORE_DIR="$CORE" CLAUDE_CONFIG_DIR="$ECFG" \
  PATH="$STUB:$PATH" bash "$CORE/scripts/kickoff" eject --dir "$EFIX" --verify \
  --archive-dir "$EARCH" --delete-data --confirm-destroy 2>&1)" || e_rc=$?
chk "eject exits 0 on a footprint carrying the brains marker" "[ $e_rc -eq 0 ]"
chk "eject REMOVED the marker (recorded → reversed)" "[ ! -e '$EFIX/.kickoff/adopt-brains-pending' ]"
# eject deliberately KEEPS the operator's CLAUDE.md and the retained kickoff-data/ — its own
# --verify allowlists both and prints the verdict. So assert on THAT verdict, not on a blanket
# porcelain-clean eject never promised, and assert the marker is not among the residue it names.
chk "eject --verify still reports NO TRACE with the marker in the footprint" \
  "printf '%s' \"\$e_out\" | grep -q 'no trace'"
chk "eject's residue scan never names the marker" \
  "! printf '%s' \"\$e_out\" | grep -q 'adopt-brains-pending'"
echo

printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
