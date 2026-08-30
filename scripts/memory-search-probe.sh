#!/usr/bin/env bash
# memory-search-probe.sh — prove the opencode `memory_search` TOOL answers, without opencode.
#
#   bash scripts/memory-search-probe.sh ["your query"]
#
# WHY. Acceptance proof P1 ("a fresh opencode session's memory_search returns real hits") had no
# runnable check — it needed a human in a live session. That is a bad place for a proof to live
# when the engine itself can be down for unrelated reasons: the second box (2026-08-27) could not
# walk P1 because headless `opencode run` was server-erroring, which says nothing about memory.
#
# This drives the plugin's real `execute` directly — same CORE_RETRIEVE resolution, same child
# spawn, same output — so it isolates the MEMORY half from the ENGINE half. A green here plus a
# broken opencode means the engine is the problem, not recall.
#
# It deliberately runs with KICKOFF_CORE_DIR and MEMORY_DB UNSET, because that is the interactive
# shape under test: nothing sets KICKOFF_CORE_DIR for an interactive session on any box (by
# design — see session-run.sh's origin-inertness comment), so the repo-local fallback is what a
# real session exercises. Scrubbing them would delete the input this probe exists to check.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUERY="${1:-read the operator early}"
PLUGIN="$ROOT/.opencode/plugins/memory-search.js"

[ -f "$PLUGIN" ] || { echo "probe: no $PLUGIN — not an engine-source checkout?" >&2; exit 1; }
command -v node >/dev/null || { echo "probe: node not on PATH" >&2; exit 1; }

# ABSENCE-SKIP, not a failure: .opencode/node_modules is gitignored, so a fresh clone has the
# plugin source but not @opencode-ai/plugin. That is a missing dev dep, not a broken instance.
if [ ! -d "$ROOT/.opencode/node_modules/@opencode-ai/plugin" ]; then
  echo "probe: SKIPPED — @opencode-ai/plugin not installed (.opencode/node_modules is gitignored)."
  echo "probe:   install it with:  ( cd .opencode && npm install )   — then re-run."
  exit 0
fi

OUT="$( cd "$ROOT" && env -u KICKOFF_CORE_DIR -u MEMORY_DB NODE_NO_WARNINGS=1 node --input-type=module -e "
const mod = await import('$PLUGIN');
const plugin = mod.MemorySearchPlugin ?? Object.values(mod)[0];
const inst = await plugin({ project: { worktree: '$ROOT' }, directory: '$ROOT' });
const t = inst?.tool?.memory_search;
if (!t) { console.error('no memory_search tool exported'); process.exit(2); }
const exec = t.execute ?? t.run ?? t.handler;
if (!exec) { console.error('memory_search exports no execute()'); process.exit(2); }
const out = await exec({ query: ${QUERY@Q}, k: 3 }, { agent: 'probe', sessionID: 'probe' });
console.log(String(out));
" 2>&1 )"; rc=$?

if [ "$rc" -ne 0 ]; then
  printf 'probe: FAILED (rc=%s) — memory_search did not execute:\n%s\n' "$rc" "$OUT" >&2
  exit 1
fi
case "$OUT" in
  *unavailable*)
    printf 'probe: FAILED — the tool reported itself unavailable:\n%s\n' "$OUT" >&2
    printf 'probe:   the repo-local fallback should cover an unset KICKOFF_CORE_DIR. Is the index built?\n' >&2
    printf 'probe:   run: bash scripts/bringup-source-instance.sh\n' >&2
    exit 1 ;;
  *'"results"'*|*'"meta"'*|*keywordHits*)
    sem="$( printf '%s' "$OUT" | sed -n 's/.*"semantic":[[:space:]]*\([a-z]*\).*/\1/p' | head -1 )"
    printf 'probe: GREEN — memory_search answered "%s" (semantic=%s, KICKOFF_CORE_DIR unset).\n' \
      "$QUERY" "${sem:-?}"
    [ "$sem" = "true" ] || printf 'probe: NOTE semantic=false — a stub index; the recall HOOK will be silent. See (b2).\n'
    exit 0 ;;
  *)
    printf 'probe: FAILED — memory_search returned an error or unrecognised output:\n%s\n' "$OUT" >&2
    exit 1 ;;
esac
