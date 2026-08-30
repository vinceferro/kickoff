#!/usr/bin/env bash
# memory-defaults-selftest.sh — RED-first proof for the memory-retrieval DEFAULT paths.
#
#   bash scripts/memory-defaults-selftest.sh
#
# The bug this suite pins (second-machine incident, 2026-08-26): a fresh engine-source clone
# with NO env vars died as a bare ENOENT, because lib/memory.mjs's DEFAULT_MEMORY_DIR fell
# back to <tool-root>/memory — a path that matches NO real layout (engine-source corpus is the
# SIBLING <repo>/memory; adopter corpus is <repo>/.kickoff/memory). The fix probes the REAL
# layouts and, when nothing exists, fails naming the fix instead of a raw scandir error.
#
# Lanes (each RED-first where the pre-fix tree could fail it):
#   a. engine-source layout, NO env → index succeeds, db lands next to the tool root
#   b. empty fixture, NO env → fails with the "memory corpus not found … set MEMORY_DIR" hint
#   c. adopter layout: REPO_DIR + .kickoff/memory → resolves there, db anchors in the REPO
#   d. HOSTILE explicit MEMORY_DIR still wins over all probing (env is the one knob)
#   e. hook.mjs with a missing index db → ONE stderr hint naming the db + the fix, exit 0
#   f. a STUB-embedder index leaves the recall HOOK silent — retrieve.mjs still answers, so a
#      check that only queries the engine reports GREEN on a session where recall is dead
#
# Env discipline ([[a-scrub-that-buys-determinism-can-delete-the-bug]]): lanes a-c run with
# MEMORY_DIR/MEMORY_DB/REPO_DIR *unset* because "unset" IS the input under test — and lane d
# then sets MEMORY_DIR HOSTILELY to prove the explicit value still beats every probe. Never
# scrub an input the behavior depends on; construct the case, then attack it.
#
# Hermetic: engine copies + corpora in mktemp fixtures; the live repo's index/log are never
# touched (lane e points MEMORY_DB/MEMORY_HOOK_LOG into its own fixture dir).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }

# A standalone copy of the retrieval engine (lib + CLIs, NO node_modules → the stub embedder,
# which is all these lanes need; no derived db/log/metrics dragged along).
cp_engine() {
  mkdir -p "$1/lib"
  cp "$REPO/memory-retrieval/index.mjs" "$REPO/memory-retrieval/retrieve.mjs" \
     "$REPO/memory-retrieval/hook.mjs" "$REPO/memory-retrieval/package.json" "$1/"
  cp "$REPO/memory-retrieval/lib/"*.mjs "$1/lib/"
}

fact() { printf -- '---\ntype: project\ndescription: %s\n---\n%s fact\n' "$2" "$1" > "$1.md"; }

echo "— a. engine-source layout, NO env: sibling memory/ is found, db lands by the tool root —"
S=$(mktemp -d)
cp_engine "$S/memory-retrieval"
mkdir -p "$S/memory"
fact "$S/memory/fixture-alpha" "alpha"
o=$( cd "$S" && env -u MEMORY_DIR -u MEMORY_DB -u REPO_DIR \
     node --experimental-sqlite memory-retrieval/index.mjs 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && ok "index builds with NO env (sibling memory/ probed)" \
                || bad "index failed with no env (rc=$rc): ${o##*$'\n'}"
[ -s "$S/memory-retrieval/memory-index.db" ] \
  && ok "db lands next to the tool root (memory-retrieval/memory-index.db)" \
  || bad "no db at $S/memory-retrieval/memory-index.db — wrong anchor"
# consume it back through the SAME resolution (write side and read side must agree)
o=$( cd "$S" && env -u MEMORY_DIR -u MEMORY_DB -u REPO_DIR \
     node --experimental-sqlite memory-retrieval/retrieve.mjs "alpha" --json 2>/dev/null )
case "$o" in *fixture-alpha*) ok "retrieve (same no-env resolution) finds the indexed fact" ;;
  *) bad "retrieve did not find fixture-alpha — index/retrieve resolve different paths" ;; esac
rm -rf "$S"

echo "— b. empty fixture, NO env: fails NAMING THE FIX, not a bare ENOENT —"
S=$(mktemp -d)
cp_engine "$S/memory-retrieval"      # no sibling memory/, no REPO_DIR → nothing to probe
o=$( cd "$S" && env -u MEMORY_DIR -u MEMORY_DB -u REPO_DIR \
     node --experimental-sqlite memory-retrieval/index.mjs 2>&1 ); rc=$?
[ "$rc" -ne 0 ] && ok "index exits non-zero when no corpus exists anywhere" \
                || bad "index 'succeeded' with no corpus — it indexed nothing and said so to nobody"
case "$o" in
  *"memory corpus not found"*) ok "…says 'memory corpus not found at <path>'" ;;
  *) bad "missing-corpus failure is a bare crash (no named cause): ${o##*$'\n'}" ;; esac
case "$o" in
  *MEMORY_DIR*) ok "…and names the fix (set MEMORY_DIR)" ;;
  *) bad "failure does not mention MEMORY_DIR — the operator cannot self-serve the fix" ;; esac
rm -rf "$S"

echo "— c. adopter layout: REPO_DIR set + .kickoff/memory → corpus + db anchor in the REPO —"
S=$(mktemp -d)
cp_engine "$S/core/memory-retrieval"                # engine in a "core" dir, NOT the repo
mkdir -p "$S/repo/.kickoff/memory"
fact "$S/repo/.kickoff/memory/fixture-beta" "beta"
o=$( cd "$S" && env -u MEMORY_DIR -u MEMORY_DB REPO_DIR="$S/repo" \
     node --experimental-sqlite "$S/core/memory-retrieval/index.mjs" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && ok "index builds from \$REPO_DIR/.kickoff/memory" \
                || bad "adopter-layout index failed (rc=$rc): ${o##*$'\n'}"
[ -s "$S/repo/memory-retrieval/memory-index.db" ] \
  && ok "db anchors in the ADOPTER's repo (\$REPO_DIR/memory-retrieval/)" \
  || bad "no db at \$REPO_DIR/memory-retrieval/ — the adopter anchor is broken"
[ ! -e "$S/core/memory-retrieval/memory-index.db" ] \
  && ok "the core clone stays clean (no derived data leaked into it)" \
  || bad "db leaked into the core clone — the cross-instance data leak is back"
o=$( cd "$S" && env -u MEMORY_DIR -u MEMORY_DB REPO_DIR="$S/repo" \
     node --experimental-sqlite "$S/core/memory-retrieval/retrieve.mjs" "beta" --json 2>/dev/null )
case "$o" in *fixture-beta*) ok "retrieve resolves the same adopter corpus+db" ;;
  *) bad "retrieve did not find fixture-beta under REPO_DIR" ;; esac
rm -rf "$S"

echo "— d. HOSTILE explicit MEMORY_DIR wins over every probe (env is the one knob) —"
S=$(mktemp -d)
cp_engine "$S/core/memory-retrieval"
mkdir -p "$S/repo/.kickoff/memory" "$S/hostile-memory"
fact "$S/repo/.kickoff/memory/fixture-beta" "beta"
fact "$S/hostile-memory/fixture-gamma" "gamma"
o=$( cd "$S" && env -u MEMORY_DB REPO_DIR="$S/repo" MEMORY_DIR="$S/hostile-memory" \
     node --experimental-sqlite "$S/core/memory-retrieval/index.mjs" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && ok "index accepts the explicit MEMORY_DIR (with REPO_DIR also set)" \
                || bad "hostile-MEMORY_DIR index failed (rc=$rc): ${o##*$'\n'}"
o=$( cd "$S" && env -u MEMORY_DB REPO_DIR="$S/repo" MEMORY_DIR="$S/hostile-memory" \
     node --experimental-sqlite "$S/core/memory-retrieval/retrieve.mjs" "gamma" --json 2>/dev/null )
case "$o" in
  *fixture-gamma*) ok "the EXPLICIT corpus was indexed — MEMORY_DIR beats the REPO_DIR probe" ;;
  *fixture-beta*)  bad "REPO_DIR probing overrode an explicit MEMORY_DIR — the precedence inverted" ;;
  *)               bad "retrieve found neither corpus — explicit-MEMORY_DIR handling broken" ;; esac
rm -rf "$S"

echo "— e. hook with a missing index db: ONE stderr hint, still fail-open (exit 0) —"
S=$(mktemp -d)
o=$( cd "$REPO" && echo '{"prompt":"status of the tournament app"}' | \
     env -u MEMORY_DIR -u REPO_DIR MEMORY_DB="$S/absent.db" MEMORY_HOOK_LOG="$S/hook-log.jsonl" \
     node --experimental-sqlite memory-retrieval/hook.mjs 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && ok "hook exits 0 on a missing db (a UserPromptSubmit hook never blocks a turn)" \
                || bad "hook exited $rc on a missing db — fail-open is load-bearing"
case "$o" in
  *"first index build not done"*) ok "…stderr names the cause (first index build not done)" ;;
  *) bad "no stderr hint — the silent no-index branch is still silent" ;; esac
case "$o" in
  *absent.db*) ok "…stderr names the missing db path ($S/absent.db)" ;;
  *) bad "stderr does not name the missing db path — undiagnosable from the terminal" ;; esac
case "$o" in
  *index.mjs*) ok "…stderr names the one-line fix (run memory-retrieval/index.mjs)" ;;
  *) bad "stderr does not name the fix command" ;; esac
rm -rf "$S"

# ── f. the STUB-index silence (second-machine incident #2, 2026-08-27) ────────────────────
# A fresh clone has no memory-retrieval/node_modules (gitignored), so @xenova/transformers is
# absent and index.mjs silently picks the 'hashing-stub' embedder. retrieve.mjs then answers
# perfectly — which is why bringup's original consumed-state check passed — but the hook's
# strength gate needs a strong KEYWORD arm or a strong VECTOR arm, and a stub index has no
# usable vector arm (meta.semantic=false ⇒ vcos=n/a). Result: recall is DEAD in every session
# while every check reports green. cp_engine deliberately ships no node_modules, so the stub
# is what this fixture gets — the bug's carrier is the input here, not something to scrub.
echo "— f. a STUB-embedder index leaves the recall hook SILENT (retrieve still answers) —"
S=$(mktemp -d); E="$S/eng"; cp_engine "$E"
MEMORY_DIR="$REPO/memory" MEMORY_DB="$S/stub.db" NODE_NO_WARNINGS=1 \
  node --experimental-sqlite "$E/index.mjs" >/dev/null 2>&1
if [ ! -s "$S/stub.db" ]; then
  bad "fixture: could not build a stub index over the repo corpus"
else
  emb=$( node --experimental-sqlite -e "
    const {DatabaseSync}=require('node:sqlite');
    const d=new DatabaseSync('$S/stub.db');
    const m=Object.fromEntries(d.prepare('select key,value from meta').all().map(r=>[r.key,r.value]));
    console.log((m.embedder||'?')+' '+(m.embedder_semantic||'?'));" 2>/dev/null )
  case "$emb" in
    *"hashing-stub false"*) ok "fixture is a STUB index (embedder=hashing-stub, semantic=false)" ;;
    *) bad "fixture is not the stub index this lane needs (got: $emb)" ;;
  esac

  # f0 — the query engine ANSWERS. This is exactly why an engine-only check reports green.
  r=$( MEMORY_DB="$S/stub.db" MEMORY_DIR="$REPO/memory" NODE_NO_WARNINGS=1 \
       node --experimental-sqlite "$E/retrieve.mjs" "read the operator early" --json 2>/dev/null )
  case "$r" in
    *read-the-operator-early*) ok "retrieve.mjs DOES answer on the stub index (the false-green trap)" ;;
    *) bad "retrieve.mjs did not answer on the stub index — fixture assumption broken" ;;
  esac

  # f1 — the real consumer surfaces NOTHING at the repo's own settings.json floors.
  o=$( echo '{"prompt":"read the operator early"}' | \
       env -u MEMORY_DIR -u REPO_DIR MEMORY_DB="$S/stub.db" MEMORY_HOOK_LOG="$S/f1.jsonl" \
       MEMORY_HOOK_BM25_FLOOR=-8.0 MEMORY_HOOK_VEC_FLOOR=0.23 NODE_NO_WARNINGS=1 \
       node --experimental-sqlite "$E/hook.mjs" 2>/dev/null )
  # Corpus-conditional by nature: whether the SHIPPED floors suppress depends on how strongly this
  # particular corpus scores. Report it, do not fail on it — f2 below pins the code invariant.
  if [ -z "$o" ]; then
    ok "…yet the HOOK surfaces nothing at the shipped floors (-8.0/0.23) — recall is dead on a stub"
  else
    printf '  ⓘ  this corpus clears the shipped keyword bar even on a stub, so the hook is not silent\n'
    printf '     here. That is a property of THIS corpus, not of the code — f2 pins the invariant.\n'
  fi
  case "$( cat "$S/f1.jsonl" 2>/dev/null )" in
    *"vcos=n/a"*) ok "…suppressed as weak-match with vcos=n/a (the vector arm is inert)" ;;
    *) bad "suppression reason is not the inert-vector-arm shape — mechanism changed" ;;
  esac

  # f2 — the DERIVED-FLOOR lane. An earlier version asserted "the hook's own code defaults do not
  # rescue it either", which was true of THIS box's 245-fact corpus (best bm25 -4.48) and FALSE on a
  # second box with a smaller corpus, where the same code cleared the -5.0 default and the lane went
  # red on a healthy tree (reported 2026-08-27). A suite must assert a property of the CODE, not an
  # emergent property of whatever corpus happens to be checked out. So: read the corpus's own best
  # keyword score out of the suppression reason, set the floor STRICTER than it, and require silence.
  # That is deterministic on any corpus and still pins the real invariant — with no vector arm, the
  # keyword arm alone decides, and a bar it cannot clear means nothing surfaces.
  best=$( sed -n 's/.*bm25=\(-\?[0-9.]*\).*/\1/p' "$S/f1.jsonl" 2>/dev/null | tail -1 )
  if [ -z "$best" ]; then
    bad "could not read the corpus's best bm25 from the suppression reason — lane cannot be derived"
  else
    strict=$( awk -v b="$best" 'BEGIN{printf "%.2f", b-1}' )
    o2=$( echo '{"prompt":"read the operator early"}' | \
          env -u MEMORY_DIR -u REPO_DIR MEMORY_DB="$S/stub.db" MEMORY_HOOK_LOG="$S/f2.jsonl" \
          MEMORY_HOOK_BM25_FLOOR="$strict" MEMORY_HOOK_VEC_FLOOR=0.23 NODE_NO_WARNINGS=1 \
          node --experimental-sqlite "$E/hook.mjs" 2>/dev/null )
    [ -z "$o2" ] \
      && ok "…silent at a floor stricter than this corpus's own best score ($strict < $best) — the keyword arm alone decides" \
      || bad "surfaced despite a floor below the corpus's best keyword score — the strength gate is not gating"
  fi

  # f3 — POSITIVE CONTROL: a SEMANTIC index surfaces the same query. Absence-skip: a clone that
  # has never installed the model has no semantic db, and that is not a failure of this lane.
  LIVE="$REPO/memory-retrieval/memory-index.db"
  live_sem=""
  [ -s "$LIVE" ] && live_sem=$( node --experimental-sqlite -e "
      const {DatabaseSync}=require('node:sqlite');
      const d=new DatabaseSync('$LIVE');
      const m=Object.fromEntries(d.prepare('select key,value from meta').all().map(r=>[r.key,r.value]));
      console.log(m.embedder_semantic||'');" 2>/dev/null )
  if [ "$live_sem" = "true" ]; then
    o3=$( echo '{"prompt":"read the operator early"}' | \
          env -u MEMORY_DIR -u REPO_DIR MEMORY_DB="$LIVE" MEMORY_HOOK_LOG="$S/f3.jsonl" \
          MEMORY_HOOK_BM25_FLOOR=-8.0 MEMORY_HOOK_VEC_FLOOR=0.23 NODE_NO_WARNINGS=1 \
          node --experimental-sqlite "$REPO/memory-retrieval/hook.mjs" 2>/dev/null )
    case "$o3" in
      *retrieved-memory*) ok "positive control: a SEMANTIC index DOES surface the same query" ;;
      *) bad "semantic index surfaced nothing — the query/corpus premise is broken, not the embedder" ;;
    esac
  else
    printf '  ⏭  positive control skipped (no semantic index on disk — run install-model.mjs)\n'
  fi
fi
rm -rf "$S"

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && printf '  ✅ memory defaults enforced (sibling probed · hint named · env wins · fail-open · stub-index silence pinned)\n'
[ "$FAIL" -eq 0 ]
