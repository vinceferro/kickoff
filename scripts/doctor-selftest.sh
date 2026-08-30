#!/usr/bin/env bash
# doctor-selftest.sh — `kickoff doctor` back-fills an ADOPTED repo's missing engine wiring.
#
#   bash scripts/doctor-selftest.sh
#
# The gap (core-v0.19 cluster 4): adopt now wires the generic lefthook gates + builds the memory
# retrieval index — but an EXISTING adopter who merely runs `kickoff pull` gets neither (`pull` is
# engine-only, `verify` is read-only). One real adopter's exact shape: adopted on an older core → ungated +
# unindexed forever, with every advisory saying "re-run `kickoff adopt`" (a full re-wire) as the
# only cure. `kickoff doctor` is the on-demand REPAIR verb: idempotent, non-destructive, back-fills
# ONLY what's missing, records what it creates via adopt-manifest (so eject reverses it), exit 0
# when there is nothing to fix.
#
# RED-FIRST: lane (a) was run against the pre-feature front door and observed RED — `kickoff
# doctor` was an unknown subcommand (usage, exit 2); nothing back-filled. Lanes (b)–(e) define the
# contract: idempotent second run, healthy no-op, non-adopted refusal, eject reversal.
#
# HERMETIC (mirrors adopt-incomplete-selftest): mktemp fixtures + ONE EXIT trap; a scratch core
# built from TODAY's engine files (no plugin dir → the plugin arm is inert, no real `claude` call)
# with the REAL memory-retrieval module grafted (index.mjs + lib/, NO node_modules → the zero-dep
# keyword arm, offline); scratch registry/config. Deps: git + python3 + coreutils (+ node ≥ 22 for
# the real index-build lanes; auto-skipped honestly when absent).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# self-scrub the ambient instance.env whitelist (same set adopt-selftest scrubs) — a preset env
# var WINS over a fixture's instance.env by design, so ambient live values must not leak in.
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

# node ≥ 22 → the REAL index build runs in the fixtures; without it those lanes skip honestly.
NODE_OK=1
command -v node >/dev/null 2>&1 || NODE_OK=0
if [ "$NODE_OK" = 1 ]; then
  _nv="$(node -v 2>/dev/null | tr -d 'v')"
  case "${_nv%%.*}" in ''|*[!0-9]*) NODE_OK=0 ;; *) [ "${_nv%%.*}" -ge 22 ] || NODE_OK=0 ;; esac
fi

CLEANUP_LIST="$(mktemp)"
mk() { local d; d="$(mktemp -d)"; printf '%s\n' "$d" >> "$CLEANUP_LIST"; printf '%s' "$d"; }
trap 'while IFS= read -r _d; do [ -n "$_d" ] && rm -rf "$_d"; done < "$CLEANUP_LIST"; rm -f "$CLEANUP_LIST"' EXIT

echo "▶ doctor selftest — the idempotent repair verb: back-fill gates + memory index on an adopted repo"
echo

# ── the scratch core: TODAY's engine + the REAL memory-retrieval module, NO plugin dir ──────────
CORE="$(mk)"
mkdir -p "$CORE/scripts" "$CORE/mission-control" "$CORE/memory-retrieval/lib"
cp "$REPO/scripts/kickoff" "$REPO/scripts/adopt-manifest.py" "$REPO/scripts/instance.env.example" \
   "$REPO/scripts/preflight.sh" "$REPO/scripts/start-supervisor.sh" "$REPO/scripts/supervisor.sh" \
   "$REPO/scripts/session-run.sh" "$CORE/scripts/"
[ -f "$REPO/scripts/rotate-log.sh" ] && cp "$REPO/scripts/rotate-log.sh" "$CORE/scripts/"
cp -r "$REPO/scripts/templates" "$CORE/scripts/templates"
# The reporting-canon seam is read from the CORE ROOT (`_read_core_root_file`), not from templates/.
# A fixture core that omits it makes every style step a silent no-op, so the (g) lanes would go green
# against a world where the feature cannot exist — the exact way core-v0.33's pull fixture went 237/18.
mkdir -p "$CORE/.claude/output-styles"
cp "$REPO/.claude/output-styles/plain-report.md" "$CORE/.claude/output-styles/plain-report.md"
# The opencode seam set is read from the CORE ROOT too (.opencode/agent + .opencode/plugins).
# A fixture core that omits it makes the (i)/(j) lanes red against a world where the set cannot
# exist — same reason the canon graft above is load-bearing. node_modules is deliberately NOT
# grafted (gitignored dev dep at the origin; a missing dev dep is not a broken instance).
mkdir -p "$CORE/.opencode/agent" "$CORE/.opencode/plugins"
cp "$REPO/.opencode/agent/"*.md "$CORE/.opencode/agent/"
cp "$REPO/.opencode/plugins/memory-search.js" "$REPO/.opencode/plugins/engine-credit.js" "$CORE/.opencode/plugins/"
cp "$REPO/mission-control/mc-update.py" "$CORE/mission-control/"
cp "$REPO/memory-retrieval/index.mjs" "$CORE/memory-retrieval/"
cp "$REPO/memory-retrieval/lib/"*.mjs "$CORE/memory-retrieval/lib/"
git -C "$CORE" init -q; git -C "$CORE" config user.email t@t.t; git -C "$CORE" config user.name t
git -C "$CORE" add -A; git -C "$CORE" commit -qm core; git -C "$CORE" tag core-vT

# build_fix → a git fixture repo, really adopted against $CORE (gates wired + index built by adopt).
build_fix() {   # $1 = registry file, $2 = config dir → echoes the fixture dir
  local f; f="$(mk)"
  git -C "$f" init -q; git -C "$f" config user.email t@t.t; git -C "$f" config user.name t
  printf '# app\n' > "$f/README.md"
  git -C "$f" add -A; git -C "$f" commit -qm baseline
  REPO_DIR="$f" TELEGRAM_STATE_DIR="" KICKOFF_ADOPTERS_REGISTRY="$1" KICKOFF_CORE_DIR="$CORE" CLAUDE_CONFIG_DIR="$2" \
    bash "$CORE/scripts/kickoff" adopt --dir "$f" --accept </dev/null >/dev/null 2>&1 || true
  # a real fact lands POST-adopt (instance DATA, uncommitted — like any live adopter's corpus);
  # doctor's index back-fill then has more than the seeded MEMORY.md stub to chew on.
  mkdir -p "$f/.kickoff/memory"
  printf -- '---\nname: a-fact\ndescription: a durable fact\n---\nThe fact body.\n' > "$f/.kickoff/memory/a-fact.md"
  printf '%s' "$f"
}
# strip_wiring → the stale-adopter shape: adopted on an old core, so gates + index never existed.
strip_wiring() {
  rm -f "$1/lefthook.yml" "$1/.kickoff/lefthook-kickoff.yml"
  rm -rf "$1/.kickoff/state/memory-retrieval"
}
run_doctor() { REPO_DIR="$1" KICKOFF_CORE_DIR="$CORE" bash "$CORE/scripts/kickoff" doctor --dir "$1" </dev/null 2>&1; }
manifest_n() { python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["entries"]))' "$1/.kickoff/adopt-manifest.json" 2>/dev/null || printf 0; }

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(a) stale-adopter fixture (gates + index REMOVED) — doctor back-fills all of it  [RED pre-feature]"
AREG="$(mk)/adopters.json"; ACFG="$(mk)"
AFIX="$(build_fix "$AREG" "$ACFG")"
strip_wiring "$AFIX"
ADB="$AFIX/.kickoff/state/memory-retrieval/memory-index.db"
a_rc=0; a_out="$(run_doctor "$AFIX")" || a_rc=$?
chk "doctor exits 0 (the verb exists and the repair ran)"                       "[ $a_rc -eq 0 ]"
chk "gate file BACK-FILLED (.kickoff/lefthook-kickoff.yml exists)"              "[ -s \"$AFIX/.kickoff/lefthook-kickoff.yml\" ]"
chk "root lefthook.yml BACK-FILLED and extends the kickoff gate"                "grep -q 'lefthook-kickoff\.yml' \"$AFIX/lefthook.yml\""
chk "doctor reports the fixes ('fixed:' lines)"                                 "printf '%s' \"\$a_out\" | grep -q 'fixed:'"
chk "doctor summary counts the back-fill ('back-filled N item(s)')"             "printf '%s' \"\$a_out\" | grep -q 'back-filled'"
if [ "$NODE_OK" = 1 ]; then
  chk "memory index BACK-FILLED (the DB exists — recall has an index again)"    "[ -s \"$ADB\" ]"
else
  chk "(node<22 box) doctor WARNS the index stays unbuilt and still exits 0"    "printf '%s' \"\$a_out\" | grep -qi 'node' && [ $a_rc -eq 0 ]"
fi
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(b) IDEMPOTENT — a second doctor run fixes nothing, records nothing, clobbers nothing"
b_n_pre="$(manifest_n "$AFIX")"
b_gate_sha="$(sha256sum "$AFIX/.kickoff/lefthook-kickoff.yml" | cut -d' ' -f1)"
b_root_sha="$(sha256sum "$AFIX/lefthook.yml" | cut -d' ' -f1)"
b_gate_mt="$(stat -c %Y "$AFIX/.kickoff/lefthook-kickoff.yml")"
b_root_mt="$(stat -c %Y "$AFIX/lefthook.yml")"
[ "$NODE_OK" = 1 ] && b_db_sha="$(sha256sum "$ADB" | cut -d' ' -f1)" || b_db_sha=absent
sleep 1   # mtime resolution is 1s — a rewrite inside the same second would hide from stat
b_rc=0; b_out="$(run_doctor "$AFIX")" || b_rc=$?
b_n_post="$(manifest_n "$AFIX")"
chk "second run exits 0 (a repair tool succeeds when there's nothing to fix)"   "[ $b_rc -eq 0 ]"
chk "second run says 'nothing to fix'"                                          "printf '%s' \"\$b_out\" | grep -q 'nothing to fix'"
chk "NO duplicate manifest records (entry count stable: $b_n_pre)"              "[ \"$b_n_pre\" = \"$b_n_post\" ]"
chk "gate file NOT clobbered (bytes stable)"    "[ \"$b_gate_sha\" = \"\$(sha256sum \"$AFIX/.kickoff/lefthook-kickoff.yml\" | cut -d' ' -f1)\" ]"
chk "root lefthook.yml NOT clobbered (bytes stable)" "[ \"$b_root_sha\" = \"\$(sha256sum \"$AFIX/lefthook.yml\" | cut -d' ' -f1)\" ]"
chk "gate file NOT rewritten (mtime stable)"    "[ \"$b_gate_mt\" = \"\$(stat -c %Y \"$AFIX/.kickoff/lefthook-kickoff.yml\")\" ]"
chk "root lefthook.yml NOT rewritten (mtime stable)" "[ \"$b_root_mt\" = \"\$(stat -c %Y \"$AFIX/lefthook.yml\")\" ]"
if [ "$NODE_OK" = 1 ]; then
  chk "index DB NOT rebuilt (bytes stable — doctor only adds what's missing)" "[ \"$b_db_sha\" = \"\$(sha256sum \"$ADB\" | cut -d' ' -f1)\" ]"
fi
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(c) fully-HEALTHY adopted fixture — doctor is a clean no-op"
CREG="$(mk)/adopters.json"; CCFG="$(mk)"
CFIX="$(build_fix "$CREG" "$CCFG")"
c_n_pre="$(manifest_n "$CFIX")"
c_rc=0; c_out="$(run_doctor "$CFIX")" || c_rc=$?
chk "healthy fixture: doctor exits 0"                                           "[ $c_rc -eq 0 ]"
chk "healthy fixture: 'nothing to fix — already healthy'"                       "printf '%s' \"\$c_out\" | grep -q 'nothing to fix'"
chk "healthy fixture: NO 'fixed:' lines (it didn't invent work)"                "! printf '%s' \"\$c_out\" | grep -q 'fixed:'"
chk "healthy fixture: NO new manifest records"                                  "[ \"$c_n_pre\" = \"\$(manifest_n \"$CFIX\")\" ]"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(d) NON-adopted dir — clean refusal, non-zero exit (never silently 'fixes' a random dir)"
DDIR="$(mk)"
printf 'just a file\n' > "$DDIR/notes.txt"
d_rc=0; d_out="$(run_doctor "$DDIR")" || d_rc=$?
chk "doctor REFUSES a non-adopted dir (non-zero exit)"                          "[ $d_rc -ne 0 ]"
chk "the refusal names the state + the cure ('not an adopted repo' → adopt)"    "printf '%s' \"\$d_out\" | grep -qi 'not an adopted repo'"
chk "nothing was written into the refused dir (no .kickoff, no lefthook.yml)"   "[ ! -e \"$DDIR/.kickoff\" ] && [ ! -e \"$DDIR/lefthook.yml\" ]"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(e) EJECT-REVERSAL — after doctor back-fills, eject removes exactly what doctor added"
EREG="$(mk)/adopters.json"; ECFG="$(mk)"; EARCH="$(mk)"
EFIX="$(build_fix "$EREG" "$ECFG")"
EBASE="$(git -C "$EFIX" rev-parse HEAD)"
strip_wiring "$EFIX"
run_doctor "$EFIX" >/dev/null 2>&1 || true
chk "(pre) doctor re-wired the stripped fixture (gate + root extends present)" \
  "[ -s \"$EFIX/.kickoff/lefthook-kickoff.yml\" ] && grep -q 'lefthook-kickoff\.yml' \"$EFIX/lefthook.yml\""
e_rc=0
e_out="$(REPO_DIR="$EFIX" KICKOFF_CORE_DIR="$CORE" bash "$CORE/scripts/kickoff" eject --dir "$EFIX" \
          --purge --delete-data --confirm-destroy --archive-dir "$EARCH" </dev/null 2>&1)" || e_rc=$?
chk "eject exits 0 on the doctored repo"                                        "[ $e_rc -eq 0 ]"
chk "doctor's gate file is GONE"                                                "[ ! -e \"$EFIX/.kickoff/lefthook-kickoff.yml\" ]"
chk "doctor's root lefthook.yml is GONE"                                        "[ ! -e \"$EFIX/lefthook.yml\" ]"
chk ".kickoff/ is GONE (index DB torn down wholesale with it)"                  "[ ! -e \"$EFIX/.kickoff\" ]"
chk "BYTE-CLEAN: git status --porcelain is EMPTY (tree back to the pre-adopt baseline)" \
  "[ -z \"\$(git -C \"$EFIX\" status --porcelain)\" ]"
chk "BYTE-CLEAN: HEAD unmoved + every tracked file matches the baseline"        \
  "git -C \"$EFIX\" diff --quiet $EBASE -- . && [ \"\$(git -C \"$EFIX\" rev-parse HEAD)\" = \"$EBASE\" ]"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(f) node-less lane — doctor on an unindexed repo WARNS (named consequence) and still exits 0"
FREG="$(mk)/adopters.json"; FCFG="$(mk)"; FSTUB="$(mk)"
FFIX="$(build_fix "$FREG" "$FCFG")"
rm -rf "$FFIX/.kickoff/state/memory-retrieval"   # index only — gates stay wired
printf '#!/usr/bin/env bash\nexit 1\n' > "$FSTUB/node"; chmod +x "$FSTUB/node"
f_rc=0
f_out="$(REPO_DIR="$FFIX" KICKOFF_CORE_DIR="$CORE" PATH="$FSTUB:$PATH" \
          bash "$CORE/scripts/kickoff" doctor --dir "$FFIX" </dev/null 2>&1)" || f_rc=$?
chk "node-less doctor still exits 0 (warn + continue, exactly like adopt)"      "[ $f_rc -eq 0 ]"
chk "the warn NAMES the consequence (index NOT built / node ≥ 22)"              "printf '%s' \"\$f_out\" | grep -qi 'node ≥ 22'"
chk "no DB was conjured (honestly absent, not a 0-byte lie)"                    "[ ! -e \"$FFIX/.kickoff/state/memory-retrieval/memory-index.db\" ]"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
# (g) THE PRE-STYLE ADOPTER — the shape that made this lane necessary, reproduced.
# `sync-seams` walks the ADOPTER'S RECORDED ENTRIES, so it can only UPDATE a seam, never INTRODUCE
# one: a repo that joined before a seam existed records nothing for it and every future pull is a
# no-op for that seam. Six real orgs hopped to core-v0.34 on six conjunctive-green verdicts and not
# one received the output style the release existed for. So the fixture strips the seam the way
# HISTORY strips it — file AND manifest row AND settings key, i.e. a repo that never had it — not by
# deleting a file out of an otherwise-recorded adoption, which is a different (and easier) shape.
echo "(g) PRE-STYLE adopter (joined before the seam existed) — doctor back-fills the reporting canon"
GREG="$(mk)/adopters.json"; GCFG="$(mk)"
GFIX="$(build_fix "$GREG" "$GCFG")"
GOS="$GFIX/.claude/output-styles/plain-report.md"
# non-vacuity: adopt must have wired it in the first place, or (g) proves nothing about doctor
chk "(g0) NON-VACUOUS: adopt wired the canon, so the fixture core really carries it"  "[ -s \"$GOS\" ]"
rm -f "$GOS"
python3 - "$GFIX" <<'PY'
import json, os, sys
r = sys.argv[1]
m = os.path.join(r, ".kickoff", "adopt-manifest.json")
d = json.load(open(m))
d["entries"] = [e for e in d.get("entries", [])
                if e.get("path") != ".claude/output-styles/plain-report.md"]
json.dump(d, open(m, "w"), indent=2)
s = os.path.join(r, ".claude", "settings.json")
if os.path.exists(s):
    c = json.load(open(s)); c.pop("outputStyle", None); json.dump(c, open(s, "w"), indent=2)
PY
g_key() { python3 -c "
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(1)
sys.exit(0 if isinstance(d,dict) and 'outputStyle' in d else 1)" "$GFIX/.claude/settings.json" 2>/dev/null; }
chk "(g1) RED baseline: the style file is gone"                                  "[ ! -e \"$GOS\" ]"
chk "(g1) RED baseline: the outputStyle key is gone"                             "! g_key"
g_rc=0; g_out="$(run_doctor "$GFIX")" || g_rc=$?
chk "(g2) doctor exits 0"                                                        "[ $g_rc -eq 0 ]"
chk "(g2) the style file is BACK-FILLED"                                         "[ -s \"$GOS\" ]"
chk "(g2) it is BYTE-IDENTICAL to the core's own canon (one source of truth)"    "cmp -s \"$GOS\" \"$CORE/.claude/output-styles/plain-report.md\""
chk "(g2) the outputStyle key is SET — the half that actually switches it on"    "g_key"
chk "(g2) it is RECORDED (so eject reverses it and preflight #8 hashes it)"      "grep -q 'output-styles/plain-report.md' \"$GFIX/.kickoff/adopt-manifest.json\""
chk "(g2) doctor REPORTS the back-fill, naming the canon"                        "printf '%s' \"\$g_out\" | grep -q 'fixed: reporting canon back-filled'"
# idempotence on the NEW item specifically — the (b) lane predates it and cannot cover it
g_sha="$(sha256sum "$GOS" | cut -d' ' -f1)"; g_n="$(manifest_n "$GFIX")"
g2_rc=0; g2_out="$(run_doctor "$GFIX")" || g2_rc=$?
chk "(g3) a second run says 'nothing to fix' (the new item is idempotent too)"   "printf '%s' \"\$g2_out\" | grep -q 'nothing to fix'"
chk "(g3) the style file was NOT rewritten (bytes stable)"                       "[ \"$g_sha\" = \"\$(sha256sum \"$GOS\" | cut -d' ' -f1)\" ]"
chk "(g3) NO duplicate manifest row (entry count stable: $g_n)"                  "[ \"$g_n\" = \"\$(manifest_n \"$GFIX\")\" ]"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
# (h) THE ADOPTER ALREADY OWNS THAT PATH. Over-tightening is the real risk here: doctor writing into
# a repo it does not own is worse than doctor doing nothing. The guard lives in gen-output-style
# (rc 3) and doctor must INHERIT it, not re-derive it — and must not report the refusal as "wired".
echo "(h) an adopter-OWNED plain-report.md — doctor leaves it alone and says so"
HREG="$(mk)/adopters.json"; HCFG="$(mk)"
HFIX="$(build_fix "$HREG" "$HCFG")"
HOS="$HFIX/.claude/output-styles/plain-report.md"
rm -f "$HOS"
python3 - "$HFIX" <<'PY'
import json, os, sys
r = sys.argv[1]
m = os.path.join(r, ".kickoff", "adopt-manifest.json")
d = json.load(open(m))
d["entries"] = [e for e in d.get("entries", [])
                if e.get("path") != ".claude/output-styles/plain-report.md"]
json.dump(d, open(m, "w"), indent=2)
s = os.path.join(r, ".claude", "settings.json")
if os.path.exists(s):
    c = json.load(open(s)); c.pop("outputStyle", None); json.dump(c, open(s, "w"), indent=2)
PY
mkdir -p "$(dirname "$HOS")"
printf '# MY OWN STYLE\nWrite however I like.\n' > "$HOS"
h_own_sha="$(sha256sum "$HOS" | cut -d' ' -f1)"
h_key() { python3 -c "
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(1)
sys.exit(0 if isinstance(d,dict) and 'outputStyle' in d else 1)" "$HFIX/.claude/settings.json" 2>/dev/null; }
h_rc=0; h_out="$(run_doctor "$HFIX")" || h_rc=$?
chk "(h1) doctor still exits 0 (a refusal is not a crash)"                       "[ $h_rc -eq 0 ]"
chk "(h1) THEIR file is byte-for-byte untouched"                                 "[ \"$h_own_sha\" = \"\$(sha256sum \"$HOS\" | cut -d' ' -f1)\" ]"
chk "(h1) the outputStyle key was NOT set (never activate a file we do not manage)" "! h_key"
chk "(h1) NOTHING was recorded for that path (eject can never delete their file)" "! grep -q 'output-styles/plain-report.md' \"$HFIX/.kickoff/adopt-manifest.json\""
chk "(h1) doctor reports it as NOT wired, not as 'already wired'"                "printf '%s' \"\$h_out\" | grep -q 'NOT wired: .claude/output-styles/plain-report.md already exists and is NOT ours'"
chk "(h1) …and the summary does NOT close with 'nothing to fix'"                 "! printf '%s' \"\$h_out\" | grep -q 'nothing to fix'"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
# (i)+(j) THE OPENCODE SET — engine parity for adoption (RED-first 2026-08-28). The origin runs
# BOTH engines; adopt wired only the claude half, so an adopter's .opencode/ was folklore
# (hand-placed, untracked, never updated by any pull). The contract, mirroring (g)/(h):
#   (i) a fresh adopt WIRES the set (5 charters stripped of any model pin + 2 plugins + a
#       pin-free opencode.json + the AGENTS.md→CLAUDE.md pointer) and RECORDS it;
#   (j) a pre-opencode adopter (joined before the set existed — file AND row stripped) gets it
#       BACK-FILLED by doctor, and a second run is idempotent.
echo "(i) a fresh adopt wires the opencode engine-parity set  [RED pre-feature]"
IREG="$(mk)/adopters.json"; ICFG="$(mk)"
IFIX="$(build_fix "$IREG" "$ICFG")"
chk "(i1) adopt delivered all 5 crew charters"                                   "[ \$(ls \"$IFIX/.opencode/agent/\"*.md 2>/dev/null | wc -l) -ge 5 ]"
chk "(i1) adopt delivered both plugins"                                          "[ -s \"$IFIX/.opencode/plugins/memory-search.js\" ] && [ -s \"$IFIX/.opencode/plugins/engine-credit.js\" ]"
chk "(i1) adopt delivered the adopter opencode.json"                             "[ -s \"$IFIX/opencode.json\" ]"
chk "(i1) opencode.json: NO model/provider pin anywhere (the wedge stance)" \
  "python3 -c \"
import json, re, sys
def walk(d):
    if isinstance(d, dict): return all(k not in ('model','provider') for k in d) and all(walk(v) for v in d.values())
    if isinstance(d, list): return all(walk(v) for v in d)
    return True
text = open('$IFIX/opencode.json').read()
assert walk(json.loads(re.sub(r'^\s*//.*$', '', text, flags=re.M)))\""
chk "(i1) the delivered coordinator charter carries NO model pin (stripped at delivery)" \
  "! grep -q '^model:' \"$IFIX/.opencode/agent/coordinator.md\" && ! grep -q 'x-preview-f-free' \"$IFIX/.opencode/agent/coordinator.md\""
chk "(i1) the OTHER charters travel verbatim (builder byte-matches the scratch core)" "cmp -s \"$IFIX/.opencode/agent/builder.md\" \"$CORE/.opencode/agent/builder.md\""
chk "(i1) the AGENTS.md pointer exists → CLAUDE.md (the origin's own shape)"     "[ -L \"$IFIX/AGENTS.md\" ] && [ \"\$(readlink \"$IFIX/AGENTS.md\")\" = \"CLAUDE.md\" ]"
chk "(i1) the set is RECORDED created/seam (sync-seams + eject own it from here)" \
  "[ \$(python3 -c \"import json;print(sum(1 for e in json.load(open('$IFIX/.kickoff/adopt-manifest.json'))['entries'] if e['class']=='seam' and (e['path'].startswith('.opencode/') or e['path']=='opencode.json')))\" 2>/dev/null) -ge 8 ]"
echo

echo "(j) PRE-OPENCODE adopter (joined before the set existed) — doctor back-fills it"
JREG="$(mk)/adopters.json"; JCFG="$(mk)"
JFIX="$(build_fix "$JREG" "$JCFG")"
# strip the set the way HISTORY strips it — file AND pointer AND manifest row (a repo that never had it)
rm -rf "$JFIX/.opencode" "$JFIX/opencode.json"
[ -L "$JFIX/AGENTS.md" ] && rm -f "$JFIX/AGENTS.md"
python3 - "$JFIX" <<'PY'
import json, os, sys
r = sys.argv[1]
m = os.path.join(r, ".kickoff", "adopt-manifest.json")
d = json.load(open(m))
d["entries"] = [e for e in d.get("entries", [])
                if not (e.get("path", "").startswith(".opencode/") or e.get("path") == "opencode.json")]
json.dump(d, open(m, "w"), indent=2)
PY
chk "(j1) RED baseline: the set is gone (files, pointer, rows)"                  "[ ! -e \"$JFIX/.opencode\" ] && [ ! -e \"$JFIX/opencode.json\" ] && [ ! -L \"$JFIX/AGENTS.md\" ]"
j_rc=0; j_out="$(run_doctor "$JFIX")" || j_rc=$?
chk "(j2) doctor exits 0"                                                        "[ $j_rc -eq 0 ]"
chk "(j2) the 5 charters are BACK-FILLED"                                        "[ \$(ls \"$JFIX/.opencode/agent/\"*.md 2>/dev/null | wc -l) -ge 5 ]"
chk "(j2) both plugins are BACK-FILLED"                                          "[ -s \"$JFIX/.opencode/plugins/memory-search.js\" ] && [ -s \"$JFIX/.opencode/plugins/engine-credit.js\" ]"
chk "(j2) the opencode.json is BACK-FILLED + pin-free"                           "[ -s \"$JFIX/opencode.json\" ] && ! grep -q 'x-preview-f-free' \"$JFIX/opencode.json\""
chk "(j2) the back-filled coordinator charter carries NO model pin"              "! grep -q '^model:' \"$JFIX/.opencode/agent/coordinator.md\""
chk "(j2) the AGENTS.md pointer is BACK-FILLED"                                  "[ -L \"$JFIX/AGENTS.md\" ]"
chk "(j2) the back-fill is RECORDED (eject reverses it, preflight #8 hashes it)" \
  "[ \$(python3 -c \"import json;print(sum(1 for e in json.load(open('$JFIX/.kickoff/adopt-manifest.json'))['entries'] if e['class']=='seam' and (e['path'].startswith('.opencode/') or e['path']=='opencode.json')))\" 2>/dev/null) -ge 8 ]"
chk "(j2) doctor REPORTS the back-fill, naming opencode"                         "printf '%s' \"\$j_out\" | grep -qi 'fixed.*opencode'"
j_n="$(manifest_n "$JFIX")"
j2_rc=0; j2_out="$(run_doctor "$JFIX")" || j2_rc=$?
chk "(j3) a second run says 'nothing to fix' (the new item is idempotent too)"   "printf '%s' \"\$j2_out\" | grep -q 'nothing to fix'"
chk "(j3) NO duplicate manifest rows (entry count stable: $j_n)"                 "[ \"$j_n\" = \"\$(manifest_n \"$JFIX\")\" ]"
echo

echo "──────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "  ✅ kickoff doctor: idempotent back-fill, honest refusal, eject-reversible"; exit 0; } || { echo "  ❌ see failures above"; exit 1; }
