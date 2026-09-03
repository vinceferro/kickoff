#!/usr/bin/env bash
# model-durability-selftest.sh — prove the semantic model is PULL-DURABLE (core-v0.4).
#
#   bash scripts/model-durability-selftest.sh
#
# REPRO-THEN-FIX. The local embedding model (all-MiniLM-L6-v2, 384-dim) used to cache INSIDE
# node_modules — a `kickoff pull` to a fresh core clone starts with an EMPTY node_modules, so
# semantic retrieval SILENTLY dropped back to the keyword stub (no error; every semantic adopter
# degraded on upgrade). The fix: (b) the model resolves from a durable per-machine dir OUTSIDE
# any core clone (KICKOFF_MODEL_DIR → ~/.cache/kickoff-models) + (a) install-model.mjs
# (re)installs/migrates it (wired into `kickoff pull` as an advisory step) + the drop is now
# VISIBLE (one clear warning + honest keyword fallback), never silent.
#
# WHAT THIS PROVES (hermetic — temp dirs only; never touches ~/.cache, the live board, or the
# repo; never downloads the model — it migrates/mocks instead):
#   1. RESOLUTION: the durable dir wins; the legacy in-node_modules cache is the fallback.
#   2. SIMULATED PULL: a fresh core clone (no node_modules) + the durable model → still found;
#      deps reinstalled → REAL semantic embeds load from the durable dir, fully OFFLINE.
#   3. VISIBLE DROP: semantic index + missing model → ONE clear warning (stderr + inside the
#      hook block + the jsonl log), honest keyword-only fallback, exit 0 — and the incremental
#      reindex refuses to stub-poison the semantic index.
#   4. COMPAT: a v0.3-style keyword-only instance stays quiet and fully working.
#
# Mirrors the ok/bad/chk shape of the other selftests. Exits non-zero on ANY failed assertion.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
MR="$REPO/memory-retrieval"

# Scrub inherited env so a caller's LIVE paths/knobs never steer this hermetic fixture.
unset MEMORY_DB MEMORY_DIR MEMORY_INDEX MEMORY_HOOK_LOG MEMORY_EMBEDDER MEMORY_HOOK_MODE \
      REPO_DIR KICKOFF_MODEL_DIR KICKOFF_MODEL_OFFLINE MEMORY_HOOK_REEXEC NODE_OPTIONS 2>/dev/null || true
export NODE_NO_WARNINGS=1   # keep the experimental-sqlite banner out of asserted stderr

PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "▶ semantic-model pull-durability self-test (core-v0.4)"
echo

if ! command -v node >/dev/null 2>&1; then
  echo "  (node not found — skipping)"; exit 0
fi

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

MODEL_SUB="Xenova/all-MiniLM-L6-v2"

# ── fixture helpers ───────────────────────────────────────────────────────────
# A FAKE model (the 4 files the presence check requires) — resolution tests only.
fake_model() { # $1 = cache root
  mkdir -p "$1/$MODEL_SUB/onnx"
  printf '{"fake":true}\n'      > "$1/$MODEL_SUB/config.json"
  printf '{"fake":true}\n'      > "$1/$MODEL_SUB/tokenizer.json"
  printf '{"fake":true}\n'      > "$1/$MODEL_SUB/tokenizer_config.json"
  printf 'FAKE-ONNX-%s\n' "$2"  > "$1/$MODEL_SUB/onnx/model_quantized.onnx"
}

# A FRESH CORE CLONE of the tool — tracked files only, NO node_modules (the exact
# shape `kickoff pull` checks out).
fresh_core() { # $1 = target dir
  mkdir -p "$1/memory-retrieval/lib"
  cp "$MR"/run.sh "$MR"/*.mjs "$MR"/package.json "$MR"/.npmrc "$MR"/pnpm-workspace.yaml "$1/memory-retrieval/"
  cp "$MR"/lib/*.mjs "$1/memory-retrieval/lib/"
}

# Evaluate a JS snippet against a given checkout's lib/embeddings.mjs.
probe() { # $1 = tool dir, $2 = js expression body (has `m` = the module)
  node --input-type=module -e "const m = await import('file://$1/lib/embeddings.mjs'); $2"
}

seed_corpus() { # $1 = corpus dir
  mkdir -p "$1"
  printf '%s\n' '---' 'type: project' 'description: scrollbite viewport rendering quirk fact' '---' \
    'The scrollbite viewport freezes when quantum flux exceeds threshold nine.' \
    > "$1/scrollbite-viewport.md"
  printf '%s\n' '---' 'type: reference' 'description: the deploy ordering rule' '---' \
    'Always run schema migrations before flipping the traffic switch.' \
    > "$1/deploy-ordering.md"
  # Filler facts (no query-term overlap): BM25's IDF degenerates to ~0 on a 2-doc
  # corpus (ln((N-df+.5)/(df+.5)) with N=2,df=1 → 0), which would suppress every
  # keyword hit; a realistic small corpus restores discriminative scores.
  local i
  for i in 1 2 3 4 5 6; do
    printf '%s\n' '---' 'type: reference' "description: filler fact number $i about gardening" '---' \
      "Water the tomato seedlings twice daily and rotate the planter box weekly ($i)." \
      > "$1/filler-$i.md"
  done
}

sqlite_eval() { # $1 = js body (has `db` open on $2)
  NODE_OPTIONS=--experimental-sqlite node --input-type=module -e "
    import { DatabaseSync } from 'node:sqlite';
    const db = new DatabaseSync('$2'); $1; db.close();"
}

# ══════════════════════════════════════════════════════════════════════════════
echo "── 1. durable-location RESOLUTION (the model survives outside the clone) ──"
DUR_A="$FIX/models-a"; fake_model "$DUR_A" "A"

out="$(KICKOFF_MODEL_DIR="$DUR_A" probe "$MR" 'console.log(JSON.stringify(m.semanticAvailability()))')"
chk "durable dir with model → available:true"            "printf '%s' \"\$out\" | grep -q '\"available\":true'"
chk "…and the source is the DURABLE dir (not legacy)"    "printf '%s' \"\$out\" | grep -q '\"source\":\"durable\"'"

# The legacy-fallback leg probes a FIXTURE core (stub package + a planted fake legacy cache —
# the §3 idiom), never this box's ambient node_modules: a clean checkout has NO in-tree model,
# and the leg must test the FALLBACK MECHANISM, not whatever the running box happens to hold.
COREL="$FIX/core-legacy-fallback"; fresh_core "$COREL"
PKGL="$COREL/memory-retrieval/node_modules/@xenova/transformers"
mkdir -p "$PKGL/src"
printf '{"name":"@xenova/transformers","main":"./src/transformers.js"}\n' > "$PKGL/package.json"
printf '// stub\n' > "$PKGL/src/transformers.js"
fake_model "$PKGL/.cache" "LEGACY-FALLBACK"
out="$(KICKOFF_MODEL_DIR="$FIX/empty-a" probe "$COREL/memory-retrieval" 'console.log(JSON.stringify(m.semanticAvailability()))')"
chk "durable empty → falls back to the legacy in-node_modules cache (fixture-planted — hermetic, not this box's ambient files)" \
  "printf '%s' \"\$out\" | grep -q '\"source\":\"legacy\"'"

out="$(probe "$MR" 'console.log(m.modelCacheDir())' )"
chk "no KICKOFF_MODEL_DIR → default is a per-machine cache dir (…/kickoff-models)" \
  "printf '%s' \"\$out\" | grep -q 'kickoff-models$'"

# ══════════════════════════════════════════════════════════════════════════════
echo
echo "── 2. SIMULATED PULL — a fresh core clone (empty node_modules) ──"
CORE1="$FIX/pulled-core"; fresh_core "$CORE1"

out="$(KICKOFF_MODEL_DIR="$DUR_A" probe "$CORE1/memory-retrieval" 'console.log(JSON.stringify(m.semanticAvailability()))')"
chk "fresh clone, deps NOT reinstalled → available:false, reason package-missing (honest)" \
  "printf '%s' \"\$out\" | grep -q '\"reason\":\"package-missing\"'"
chk "…and the ready-made warning names keyword-only + the install-model fix" \
  "printf '%s' \"\$out\" | grep -q 'keyword-only' && printf '%s' \"\$out\" | grep -q 'install-model.mjs'"

out="$(KICKOFF_MODEL_DIR="$DUR_A" probe "$CORE1/memory-retrieval" \
  'const p = m.createEmbeddingProvider(); const [v] = await p.embed(["offline lexical still works"]); console.log(p.name, v.length)')"
chk "…the offline lexical-stub path still WORKS (no model, no network → keyword)" \
  "printf '%s' \"\$out\" | grep -q 'hashing-stub 256'"

# Deps reinstalled on the pulled core (simulated: link the tool deps in) + durable model:
ln -s "$MR/node_modules" "$CORE1/memory-retrieval/node_modules"
out="$(KICKOFF_MODEL_DIR="$DUR_A" probe "$CORE1/memory-retrieval" 'console.log(JSON.stringify(m.semanticAvailability()))')"
chk "deps reinstalled + durable model → available from the DURABLE dir (durable wins over legacy)" \
  "printf '%s' \"\$out\" | grep -q '\"available\":true' && printf '%s' \"\$out\" | grep -q '\"source\":\"durable\"'"

# ══════════════════════════════════════════════════════════════════════════════
echo
echo "── 3. LEGACY→DURABLE MIGRATION (install-model, no network) ──"
CORE2="$FIX/core-legacy"; fresh_core "$CORE2"
# a stub package (resolvable, never imported) with a FAKE legacy in-package model cache
PKG="$CORE2/memory-retrieval/node_modules/@xenova/transformers"
mkdir -p "$PKG/src"
printf '{"name":"@xenova/transformers","main":"./src/transformers.js"}\n' > "$PKG/package.json"
printf '// stub\n' > "$PKG/src/transformers.js"
fake_model "$PKG/.cache" "LEGACY-SENTINEL"

DUR_M="$FIX/models-m"
mig_rc=0
mig_out="$(KICKOFF_MODEL_DIR="$DUR_M" node "$CORE2/memory-retrieval/install-model.mjs" --if-needed 2>&1)" || mig_rc=$?
chk "install-model --if-needed exits 0"                          "[ $mig_rc -eq 0 ]"
chk "…migrated the legacy model into the durable dir"            "[ -f \"$DUR_M/$MODEL_SUB/onnx/model_quantized.onnx\" ]"
chk "…byte-for-byte (the sentinel travelled)"                    "grep -q 'LEGACY-SENTINEL' \"$DUR_M/$MODEL_SUB/onnx/model_quantized.onnx\""
chk "…and says so (migrated → pull-durable)"                     "printf '%s' \"\$mig_out\" | grep -qi 'pull-durable'"
chk "…legacy source left intact (copy, not move)"                "[ -f \"$PKG/.cache/$MODEL_SUB/onnx/model_quantized.onnx\" ]"

# idempotent second run: fast no-op
mig2_out="$(KICKOFF_MODEL_DIR="$DUR_M" node "$CORE2/memory-retrieval/install-model.mjs" --if-needed 2>&1)" || true
chk "second run is a no-op (already durable)"                    "printf '%s' \"\$mig2_out\" | grep -qi 'nothing to do'"

# ══════════════════════════════════════════════════════════════════════════════
echo
echo "── 4. VISIBLE DROP — semantic index, model gone (the post-pull degrade) ──"
INST="$FIX/instance"; seed_corpus "$INST/memory"
DB="$INST/state/memory-index.db"
LOG="$INST/state/retrieval-log.jsonl"

# Build a keyword(stub) index from the PULLED core (no model), then FABRICATE the
# post-pull semantic shape: meta says the index was built with the real 384-dim
# model (exactly what an adopter's durable index looks like after the clone swap).
rm -f "$CORE1/memory-retrieval/node_modules"   # back to the no-deps pulled shape
b_rc=0
MEMORY_DIR="$INST/memory" MEMORY_DB="$DB" bash "$CORE1/memory-retrieval/run.sh" index >/dev/null 2>&1 || b_rc=$?
chk "index builds on the pulled core (stub embedder — still functional)"  "[ $b_rc -eq 0 ]"
sqlite_eval "
  db.prepare(\"UPDATE meta SET value='true' WHERE key='embedder_semantic'\").run();
  db.prepare(\"UPDATE meta SET value='local:Xenova/all-MiniLM-L6-v2' WHERE key='embedder'\").run();
  db.prepare('UPDATE vectors SET dims=384').run();" "$DB"

hk_rc=0
hk_out="$(printf '{"prompt":"the scrollbite viewport freezes above quantum flux threshold"}' \
  | MEMORY_DIR="$INST/memory" MEMORY_DB="$DB" MEMORY_HOOK_LOG="$LOG" \
    KICKOFF_MODEL_DIR="$FIX/nowhere" MEMORY_HOOK_BM25_FLOOR=-1 \
    node "$CORE1/memory-retrieval/hook.mjs" 2>"$FIX/hk_err")" || hk_rc=$?
hk_err="$(cat "$FIX/hk_err")"
chk "hook exits 0 (a degrade must never break the turn)"          "[ $hk_rc -eq 0 ]"
chk "ONE clear warning on stderr (…degraded to keyword-only; run install-model)" \
  "printf '%s' \"\$hk_err\" | grep -q 'degraded to keyword-only' && printf '%s' \"\$hk_err\" | grep -q 'install-model.mjs'"
chk "retrieval still WORKS keyword-only (the fact surfaces)"      "printf '%s' \"\$hk_out\" | grep -q 'scrollbite-viewport'"
chk "the injected block carries the ⚠ note (the agent can see + heal it)" \
  "printf '%s' \"\$hk_out\" | grep -q '⚠' && printf '%s' \"\$hk_out\" | grep -q 'install-model.mjs'"
chk "the jsonl log records the drop (mode:keyword + semanticDegraded)" \
  "grep -q '\"mode\":\"keyword\"' \"$LOG\" && grep -q '\"semanticDegraded\":true' \"$LOG\""

# POISON GUARD: edit a fact → the hook's auto-reindex must NOT stub-poison the
# semantic index (keyword side refreshed; the changed slug's vector dropped; meta kept).
sleep 1  # ensure the edit's mtime advances past the build
printf 'An extra line so the content hash changes.\n' >> "$INST/memory/scrollbite-viewport.md"
printf '{"prompt":"the scrollbite viewport freezes above quantum flux threshold"}' \
  | MEMORY_DIR="$INST/memory" MEMORY_DB="$DB" MEMORY_HOOK_LOG="$LOG" \
    KICKOFF_MODEL_DIR="$FIX/nowhere" MEMORY_HOOK_BM25_FLOOR=-1 \
    node "$CORE1/memory-retrieval/hook.mjs" >/dev/null 2>&1 || true
vec_state="$(sqlite_eval "
  const gone = db.prepare(\"SELECT COUNT(*) AS n FROM vectors WHERE slug='scrollbite-viewport'\").get().n;
  const kept = db.prepare(\"SELECT COUNT(*) AS n FROM vectors WHERE slug='deploy-ordering' AND dims=384\").get().n;
  const sem  = db.prepare(\"SELECT value FROM meta WHERE key='embedder_semantic'\").get().value;
  const fts  = db.prepare(\"SELECT COUNT(*) AS n FROM memories_fts WHERE memories_fts MATCH 'extra'\").get().n;
  console.log(JSON.stringify({gone, kept, sem, fts}));" "$DB")"
chk "changed fact re-indexed on the KEYWORD side (edit is searchable)"  "printf '%s' \"\$vec_state\" | grep -q '\"fts\":1'"
chk "…its stale vector DROPPED, not replaced by a 256-dim stub vector"  "printf '%s' \"\$vec_state\" | grep -q '\"gone\":0'"
chk "…surviving real vectors + semantic meta KEPT (no silent flip to keyword)" \
  "printf '%s' \"\$vec_state\" | grep -q '\"kept\":1' && printf '%s' \"\$vec_state\" | grep -q '\"sem\":\"true\"'"

# v0.3 COMPAT: a never-semantic (stub) index stays QUIET — no degrade noise.
INST2="$FIX/instance-v03"; seed_corpus "$INST2/memory"
DB2="$INST2/state/memory-index.db"
MEMORY_DIR="$INST2/memory" MEMORY_DB="$DB2" bash "$CORE1/memory-retrieval/run.sh" index >/dev/null 2>&1 || true
q_rc=0
q_out="$(printf '{"prompt":"the scrollbite viewport freezes above quantum flux threshold"}' \
  | MEMORY_DIR="$INST2/memory" MEMORY_DB="$DB2" MEMORY_HOOK_LOG="$INST2/log.jsonl" \
    KICKOFF_MODEL_DIR="$FIX/nowhere" MEMORY_HOOK_BM25_FLOOR=-1 \
    node "$CORE1/memory-retrieval/hook.mjs" 2>"$FIX/q_err")" || q_rc=$?
chk "keyword-only (v0.3-style) instance: hook works, exit 0"      "[ $q_rc -eq 0 ] && printf '%s' \"\$q_out\" | grep -q 'scrollbite-viewport'"
chk "…and stays QUIET (no degrade warning for an instance that never had semantic)" \
  "! grep -q 'degraded to keyword-only' \"$FIX/q_err\""

# install-model failure UX: recovery needed but no package manager on PATH → loud exit 1.
mkdir -p "$FIX/bin" && ln -s "$(command -v node)" "$FIX/bin/node"
f_rc=0
f_out="$(PATH="$FIX/bin" MEMORY_DB="$DB" KICKOFF_MODEL_DIR="$FIX/nowhere" \
  "$FIX/bin/node" "$CORE1/memory-retrieval/install-model.mjs" --if-needed 2>&1)" || f_rc=$?
chk "install-model with no pnpm/npm on PATH: fails LOUD (exit 1, names the manual npm heal)" \
  "[ $f_rc -eq 1 ] && printf '%s' \"\$f_out\" | grep -q '&& npm install'"

# ══════════════════════════════════════════════════════════════════════════════
echo
echo "── 5. REAL MODEL, REAL EMBEDS — durable load survives the clone swap, OFFLINE ──"
# Uses the REAL model already on this box (migrates it — never downloads). Skipped
# gracefully if this checkout has no real model installed.
have_real="$(probe "$MR" 'const l=m.legacyModelCacheDir(); console.log(l && m.modelFilesPresent(l) ? "yes" : "no")')"
if [ "$have_real" != "yes" ]; then
  echo "  (no real model in this checkout's node_modules — skipping the real-embed leg)"
else
  DUR_R="$FIX/models-real"
  r_rc=0
  KICKOFF_MODEL_DIR="$DUR_R" node "$MR/install-model.mjs" --if-needed >/dev/null 2>&1 || r_rc=$?
  onnx="$DUR_R/$MODEL_SUB/onnx/model_quantized.onnx"
  chk "install-model migrated the REAL model into the durable dir (exit 0)"  "[ $r_rc -eq 0 ] && [ -f \"$onnx\" ]"
  chk "…and it is the real artifact (>10MB), not a stub"  "[ \$(stat -c%s \"$onnx\") -gt 10000000 ]"

  # A SECOND fresh core clone with deps but its in-package legacy cache REMOVED —
  # cp -al (hardlink farm, instant, same-fs) with a plain-copy fallback.
  CORE3="$FIX/pulled-core-real"; fresh_core "$CORE3"
  if cp -al "$MR/node_modules" "$CORE3/memory-retrieval/node_modules" 2>/dev/null \
     || cp -a "$MR/node_modules" "$CORE3/memory-retrieval/node_modules" 2>/dev/null; then
    rm -rf "$CORE3"/memory-retrieval/node_modules/.pnpm/@xenova+transformers*/node_modules/@xenova/transformers/.cache
    chk "fixture: pulled core has deps but NO legacy model cache" \
      "probe \"$CORE3/memory-retrieval\" 'const l=m.legacyModelCacheDir(); console.log(l && m.modelFilesPresent(l) ? \"present\" : \"absent\")' | grep -q absent"
    chk "paranoia: the REAL repo's legacy cache is untouched by the fixture" \
      "probe \"$MR\" 'const l=m.legacyModelCacheDir(); console.log(m.modelFilesPresent(l) ? \"present\" : \"absent\")' | grep -q present"

    # THE PULL-SURVIVAL PROOF: new clone + durable model + NETWORK PINNED OFF → real 384-dim embeds.
    e_out="$(KICKOFF_MODEL_DIR="$DUR_R" KICKOFF_MODEL_OFFLINE=1 probe "$CORE3/memory-retrieval" \
      'const p = new m.LocalEmbeddingProvider(); const [v] = await p.embed(["the screen does not move when I scroll"]); console.log("dims", v.length, "semantic", p.semantic)')" || true
    chk "REAL semantic embedding from the DURABLE dir, fully offline, on a fresh clone (384-dim)" \
      "printf '%s' \"\$e_out\" | grep -q 'dims 384 semantic true'"

    # NEGATIVE CONTROL: same clone, EMPTY durable dir, offline → must FAIL (proves the
    # positive leg read the durable dir and nothing else — no hidden fallback).
    n_rc=0
    KICKOFF_MODEL_DIR="$FIX/empty-n" KICKOFF_MODEL_OFFLINE=1 probe "$CORE3/memory-retrieval" \
      'const p = new m.LocalEmbeddingProvider(); await p.embed(["x"])' >/dev/null 2>&1 || n_rc=$?
    chk "negative control: empty durable + offline → embed FAILS (no silent source)"  "[ $n_rc -ne 0 ]"

    # END-TO-END on the REAL hook path: build a REAL semantic index on the pulled core
    # (offline, model from the durable dir), then fire the hook → hybrid + semantic:true.
    INST3="$FIX/instance-real"; seed_corpus "$INST3/memory"
    DB3="$INST3/state/memory-index.db"; LOG3="$INST3/log.jsonl"
    bi_rc=0
    MEMORY_DIR="$INST3/memory" MEMORY_DB="$DB3" KICKOFF_MODEL_DIR="$DUR_R" KICKOFF_MODEL_OFFLINE=1 \
      bash "$CORE3/memory-retrieval/run.sh" index >/dev/null 2>&1 || bi_rc=$?
    sem3="$(sqlite_eval "console.log(db.prepare(\"SELECT value FROM meta WHERE key='embedder_semantic'\").get().value)" "$DB3" 2>/dev/null || echo unreadable)"
    chk "REAL semantic index builds OFFLINE on the pulled core (exit 0, meta semantic:true)" \
      "[ $bi_rc -eq 0 ] && [ \"\$sem3\" = true ]"
    h3_rc=0
    h3_out="$(printf '{"prompt":"the scrollbite viewport freezes above quantum flux threshold"}' \
      | MEMORY_DIR="$INST3/memory" MEMORY_DB="$DB3" MEMORY_HOOK_LOG="$LOG3" \
        KICKOFF_MODEL_DIR="$DUR_R" KICKOFF_MODEL_OFFLINE=1 MEMORY_HOOK_BM25_FLOOR=-1 \
        node "$CORE3/memory-retrieval/hook.mjs" 2>/dev/null)" || h3_rc=$?
    chk "hook on the pulled core runs HYBRID with REAL semantics (mode:hybrid, semantic:true)" \
      "[ $h3_rc -eq 0 ] && grep -q '\"mode\":\"hybrid\"' \"$LOG3\" && grep -q '\"semantic\":true' \"$LOG3\""
    chk "…and surfaces the fact"  "printf '%s' \"\$h3_out\" | grep -q 'scrollbite-viewport'"
  else
    echo "  (could not clone node_modules into the fixture — skipping the fresh-clone real-embed leg)"
  fi

  # CORRUPT durable model + REAL provider: embed fails at load → LOUD skip, keyword
  # results still served (retrieve CLI path; dims 384 match so the embed is attempted).
  c_rc=0
  c_out="$(MEMORY_DB="$DB" KICKOFF_MODEL_DIR="$DUR_A" KICKOFF_MODEL_OFFLINE=1 \
    bash "$MR/run.sh" retrieve "scrollbite viewport quantum flux" 2>&1)" || c_rc=$?
  chk "corrupt model files → retrieve still serves keyword results (exit 0)" \
    "[ $c_rc -eq 0 ] && printf '%s' \"\$c_out\" | grep -q 'scrollbite-viewport'"
  chk "…with the LOUD embed-failure warning (not a silent drop)" \
    "printf '%s' \"\$c_out\" | grep -q 'vector arm skipped'"
fi

# ══════════════════════════════════════════════════════════════════════════════
echo
echo "── 6. install-model SELF-HEAL — pnpm-nonzero → npm fallback (fresh sandbox stage per manager) ──"
# FIX #3 control flow: pnpm >=10 won't build the native onnxruntime-node dep, so on a box WITH
# npm present install-model must FALL THROUGH from a non-zero pnpm to npm — and npm's native
# rebuild must run over a CLEAN slate. Post-sandbox (the pnpm>=10 clone-dirty fix), the clean
# slate is BY CONSTRUCTION: each manager installs into a FRESH stage OUTSIDE the clone (its cwd
# is the stage, so the stubs write CWD-RELATIVE, like real pnpm/npm), and the stale half-installed
# node_modules disappears in the wholesale swap on success. Hermetic: stub pnpm (mutates its
# ./pnpm-workspace.yaml copy like real pnpm >=10, then exit 1) + npm (succeeds, plants a
# resolvable @xenova/transformers in ./node_modules) on PATH; a faked durable model lets the heal
# complete GREEN with NO network. TOOL_DIR is a FRESH CORE CLONE — never the live memory-retrieval.
COREB="$FIX/core-heal"; fresh_core "$COREB"
MRB="$COREB/memory-retrieval"

# A pre-existing HALF-installed node_modules whose sentinel is NOT @xenova/transformers (so
# packagePresent() stays false → installDeps runs); its removal proves npm's install REPLACED
# the stale tree wholesale (the clean-slate heal, formerly a pre-wipe).
mkdir -p "$MRB/node_modules/leftover"
printf 'STALE\n' > "$MRB/node_modules/leftover/sentinel"

# PATH stubs: like the REAL tools, ONLY `<pm> install …` has side effects — any other argv
# (a `--version` probe etc.) answers a version + exits 0 and touches NOTHING. (A stub that acted
# on ANY argv once left a latent stub node_modules at the SUITE CALLER'S cwd — the live repo
# root — via a cwd-less `npm --version` probe.) On install: pnpm mutates ./pnpm-workspace.yaml
# in its cwd (real pnpm >=10's config-store write) then exits 1 (native build blocked); npm
# "succeeds" and plants a resolvable @xenova/transformers CWD-RELATIVE (its cwd is
# install-model's sandbox stage; the swap moves it into the clone) so packagePresent() flips
# true afterward. Each drops a sentinel on install so we can prove BOTH managers were reached,
# in order. (Prepend to PATH so real pnpm/npm are shadowed.)
BINB="$FIX/bin-heal"; mkdir -p "$BINB"
ln -s "$(command -v node)" "$BINB/node"
cat > "$BINB/pnpm" <<PNPM
#!/bin/sh
[ "\${1:-}" = install ] || { echo "10.99.0-stub"; exit 0; }
: > "$FIX/pnpm-was-run"
printf 'ignoredBuiltDependencies:\n  - onnxruntime-node\n' >> ./pnpm-workspace.yaml
echo "stub pnpm>=10: config store mutated; refusing to build native deps (simulated non-zero)" >&2
exit 1
PNPM
cat > "$BINB/npm" <<NPM
#!/bin/sh
[ "\${1:-}" = install ] || { echo "10.99.0-stub"; exit 0; }
: > "$FIX/npm-was-run"
mkdir -p ./node_modules/@xenova/transformers
printf '{"name":"@xenova/transformers","main":"index.js"}\n' > ./node_modules/@xenova/transformers/package.json
: > ./node_modules/@xenova/transformers/index.js
echo "stub npm: installed (native build ran over a clean tree)"
exit 0
NPM
chmod +x "$BINB/pnpm" "$BINB/npm"

# Stub hygiene (the repo-root-residue regression): a `--version` PROBE must answer cleanly and
# plant NOTHING at its cwd. Runs BEFORE the heal leg so the was-run sentinels also prove the
# probes never fire them. [RED pre-repair]
HYGB="$FIX/hyg-heal"; mkdir -p "$HYGB"
hyg_rc=0
hyg_out="$( (cd "$HYGB" && PATH="$BINB:$PATH" pnpm --version && PATH="$BINB:$PATH" npm --version) 2>&1)" || hyg_rc=$?
chk "stub hygiene [RED pre-repair]: '--version' probes answer versions + exit 0 and plant NOTHING at their cwd" \
  "[ $hyg_rc -eq 0 ] && printf '%s' \"\$hyg_out\" | grep -Eq '^[0-9]+\.' && [ -z \"\$(ls -A \"$HYGB\")\" ] && [ ! -e \"$FIX/pnpm-was-run\" ] && [ ! -e \"$FIX/npm-was-run\" ]"

# A faked durable model so the heal reaches OK without a fetch (offline; no network).
DURB="$FIX/models-heal"; fake_model "$DURB" "HEAL"

heal_rc=0
# KICKOFF_EMBED_PROBE=0: this leg's stack is FAKE by construction (sentinel-planted
# package.json, no real sharp), so the functional embed probe cannot pass here — the
# hermeticity lever, same class as KICKOFF_MODEL_OFFLINE=1. The NEXT leg proves the
# probe still refuses to bless this fake stack when left on.
heal_out="$(PATH="$BINB:$PATH" KICKOFF_MODEL_DIR="$DURB" KICKOFF_MODEL_OFFLINE=1 KICKOFF_EMBED_PROBE=0 MEMORY_DB="$FIX/no-such.db" \
  node "$MRB/install-model.mjs" 2>&1)" || heal_rc=$?
chk "pnpm WAS tried first"                                                     "[ -f \"$FIX/pnpm-was-run\" ]"
chk "…and after pnpm's NON-ZERO exit, npm WAS tried (the fix: no early bail)"  "[ -f \"$FIX/npm-was-run\" ]"
chk "…npm's result landed over a CLEAN slate (the stale node_modules sentinel is gone — replaced wholesale)" \
  "[ ! -e \"$MRB/node_modules/leftover/sentinel\" ] && [ -f \"$MRB/node_modules/@xenova/transformers/package.json\" ]"
chk "…install-model reports the npm fallback + heals GREEN (exit 0)" \
  "[ $heal_rc -eq 0 ] && printf '%s' \"\$heal_out\" | grep -q 'deps installed via npm'"

# The embed probe guards the blessing: the SAME fake stack, probe left ON, must now FAIL
# loudly — a green-resolution-but-dead-runtime stack must never be reported ready. [fix-B]
probe_rc=0
probe_out="$(PATH="$BINB:$PATH" KICKOFF_MODEL_DIR="$DURB" KICKOFF_MODEL_OFFLINE=1 MEMORY_DB="$FIX/no-such.db" \
  node "$MRB/install-model.mjs" 2>&1)" || probe_rc=$?
chk "embed probe left ON refuses to bless the fake stack (non-zero + names the embed failure + the remedies)" \
  "[ $probe_rc -ne 0 ] && printf '%s' \"\$probe_out\" | grep -qi 'embed' && printf '%s' \"\$probe_out\" | grep -q 'install-model.mjs' && printf '%s' \"\$probe_out\" | grep -q 'node@22'"

# ══════════════════════════════════════════════════════════════════════════════
echo
echo "── 7. kickoff verify — semantic FUNCTION probe (prove function, keep exit-0 GREEN) ──"
# FIX #5: verify must prove semantic memory can actually RUN (semanticAvailability() in the
# PINNED CORE), not merely that node exists — but a not-yet-built model is an ADVISORY amber ⚠,
# never a hard fail (verify's exit-0/GREEN contract). Hermetic: a throwaway TAGGED+clean core
# clone (→ core.lock coherent) + stub .kickoff seams (shims + an mc that round-trips) so the ONLY
# non-green signal is the semantic probe; model dir empty + offline → available:false.
if command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  VCORE="$FIX/verify-core"; fresh_core "$VCORE"
  git -C "$VCORE" init -q
  git -C "$VCORE" add -A
  git -C "$VCORE" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm core >/dev/null 2>&1
  git -C "$VCORE" tag vtest
  VCOMMIT="$(git -C "$VCORE" rev-parse HEAD)"

  VTARGET="$FIX/verify-target"; mkdir -p "$VTARGET/.kickoff/bin"
  { printf '# hermetic fixture core.lock\n'; printf 'format 2\n'; printf 'tag vtest\n'; printf 'commit %s\n' "$VCOMMIT"; } > "$VTARGET/.kickoff/core.lock"
  # scan-* shims need only be present+executable; mc must round-trip `render-tracker --out <tmp>`.
  for s in scan-secrets scan-structure; do printf '#!/bin/sh\nexit 0\n' > "$VTARGET/.kickoff/bin/$s"; chmod +x "$VTARGET/.kickoff/bin/$s"; done
  cat > "$VTARGET/.kickoff/bin/mc" <<'MC'
#!/bin/sh
out=""
while [ $# -gt 0 ]; do case "$1" in --out) shift; out="$1" ;; --out=*) out="${1#--out=}" ;; esac; shift; done
[ -n "$out" ] && printf 'stub tracker\n' > "$out"
exit 0
MC
  chmod +x "$VTARGET/.kickoff/bin/mc"

  v_rc=0
  v_out="$(REPO_DIR="$VTARGET" KICKOFF_CORE_DIR="$VCORE" KICKOFF_MODEL_DIR="$FIX/verify-nomodel" \
    KICKOFF_MODEL_OFFLINE=1 bash "$REPO/scripts/kickoff" verify --dir "$VTARGET" 2>&1)" || v_rc=$?
  chk "verify EXITS 0 (GREEN) though the model is absent — keyword-only is advisory, not a fail" \
    "[ $v_rc -eq 0 ]"
  chk "verify emits the amber semantic line naming keyword-only + the install-model heal" \
    "printf '%s' \"\$v_out\" | grep -q 'keyword-only' && printf '%s' \"\$v_out\" | grep -q 'install-model.mjs'"
  chk "…and it is an advisory ⚠, NOT a hard ✗ (semantic never flips verify red)" \
    "printf '%s' \"\$v_out\" | grep -q '⚠ semantic memory' && ! printf '%s' \"\$v_out\" | grep -q '✗ semantic'"
  chk "…the probe rode on a GREEN node-≥22 check" \
    "printf '%s' \"\$v_out\" | grep -q 'node present'"
else
  echo "  (git/jq/python3 not all present — skipping the verify exit-0 leg)"
fi

# ══════════════════════════════════════════════════════════════════════════════
echo
echo "── 8. RUNTIME degrade is AGENT-VISIBLE — a native embed failure surfaces the ⚠ note ──"
# FIX #4: a native-runtime load failure (onnxruntime-node present but UNLOADABLE) is caught at
# EMBED time (meta.vectorDegraded) but the pre-retrieve availability check can't see it — so the
# agent-visible ⚠ note used to stay silent. Hermetic repro: build the index with NO @xenova
# (hashing stub → clean keyword index), fabricate the post-build semantic shape, THEN plant a
# @xenova/transformers that RESOLVES (availability:true) but THROWS on import (the unloadable-
# native shape) + a faked model → the hook falls through to embed, degrades, and STILL surfaces ⚠.
HCORE="$FIX/core-runtime"; fresh_core "$HCORE"
HMR="$HCORE/memory-retrieval"
HDUR="$FIX/models-runtime"; fake_model "$HDUR" "RT"
HINST="$FIX/instance-runtime"; seed_corpus "$HINST/memory"
HDB="$HINST/state/memory-index.db"; HLOG="$HINST/state/retrieval-log.jsonl"

MEMORY_DIR="$HINST/memory" MEMORY_DB="$HDB" bash "$HMR/run.sh" index >/dev/null 2>&1 || true
sqlite_eval "
  db.prepare(\"UPDATE meta SET value='true' WHERE key='embedder_semantic'\").run();
  db.prepare(\"UPDATE meta SET value='local:Xenova/all-MiniLM-L6-v2' WHERE key='embedder'\").run();
  db.prepare('UPDATE vectors SET dims=384').run();" "$HDB"

HPKG="$HMR/node_modules/@xenova/transformers"; mkdir -p "$HPKG"
printf '{"name":"@xenova/transformers","main":"index.js"}\n' > "$HPKG/package.json"
printf 'throw new Error("onnxruntime-node native binding failed to load (stub)");\n' > "$HPKG/index.js"

rt_rc=0
rt_out="$(printf '{"prompt":"the scrollbite viewport freezes above quantum flux threshold"}' \
  | MEMORY_DIR="$HINST/memory" MEMORY_DB="$HDB" MEMORY_HOOK_LOG="$HLOG" \
    KICKOFF_MODEL_DIR="$HDUR" KICKOFF_MODEL_OFFLINE=1 MEMORY_HOOK_BM25_FLOOR=-1 \
    node "$HMR/hook.mjs" 2>"$FIX/rt_err")" || rt_rc=$?
chk "hook exits 0 (a runtime degrade never breaks the turn)"       "[ $rt_rc -eq 0 ]"
chk "…retrieval still WORKS keyword-only (the fact surfaces)"       "printf '%s' \"\$rt_out\" | grep -q 'scrollbite-viewport'"
chk "…the injected block carries the ⚠ RUNTIME-degrade note + install-model heal (agent-visible)" \
  "printf '%s' \"\$rt_out\" | grep -q '⚠' && printf '%s' \"\$rt_out\" | grep -q 'runtime' && printf '%s' \"\$rt_out\" | grep -q 'install-model.mjs'"
chk "…the jsonl log records vectorDegraded (embed-failed), not a silent drop" \
  "grep -q '\"vectorDegraded\":\"embed-failed\"' \"$HLOG\""

echo
echo "──────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "  ✅ the semantic model is pull-durable — and a missing one is LOUD, never silent"; exit 0; } \
                  || { echo "  ❌ see failures above"; exit 1; }
