#!/usr/bin/env bash
# plugin/hooks/memory-hook.sh — the THIN plugin memory hook (design §2.2, LOCKED decision #4).
#
# The kickoff plugin delivers ONLY this thin shell. The heavy memory-retrieval/ engine is
# NOT bundled into the plugin: bundling it would reintroduce the copy-drift the pull model
# exists to kill (FORBIDDEN). Instead this shell resolves the SINGLE-SOURCED, whole-tree-pinned
# engine from the adopter's pinned core clone and execs it. ${CLAUDE_PLUGIN_ROOT} locates only
# THIS shell — the cache holds static wiring, never the engine.
#
# WHAT IT DOES (three steps):
#   1. Source $CLAUDE_PROJECT_DIR/.kickoff/instance.env under the SAME subshell-whitelist
#      discipline as session-run.sh:68-81 — instance.env is gitignored per-adopter CONFIG, not
#      trusted code, so we source it in a SUBSHELL and import back ONLY whitelisted CONFIG var
#      NAMES, %q-round-tripped so a shell metacharacter in a value stays LITERAL (no import-time
#      injection). PREFLIGHT_SKIP/DRY_RUN et al. — absent from the list — can never arrive here.
#   2. Point REPO_DIR at $CLAUDE_PROJECT_DIR so the engine anchors its derived index/log in the
#      ADOPTER's repo (lib/memory.mjs INSTANCE_TOOL_ROOT), never the read-only core clone it
#      resolves FROM. Set AFTER the import so an instance.env value can't redirect it.
#   3. exec $KICKOFF_CORE_DIR/memory-retrieval/hook.mjs (KICKOFF_CORE_DIR comes from instance.env).
#
# FAIL-OPEN, ALWAYS: a UserPromptSubmit hook must NEVER block the user's turn (design goal of
# hook.mjs itself). Any missing piece — no CLAUDE_PROJECT_DIR, no instance.env, unset
# KICKOFF_CORE_DIR, an absent engine (core not pulled / mid-pull) — emits NOTHING and exits 0.
#
# CREDENTIAL-SAFE: reads/writes NO secret and never touches settings.local.json.

# NOT `set -e`: a hook must never abort the turn on a non-zero step. `-u` off too — we probe
# optional vars. Explicit guards below do the fail-open work.
set +eu

# CLAUDE_PROJECT_DIR is the adopter repo CC runs in. Without it we can't locate instance.env or
# anchor the index → nothing to do; never block the turn.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
[ -n "$PROJECT_DIR" ] || exit 0

INSTANCE_ENV="$PROJECT_DIR/.kickoff/instance.env"

# ── UNTRUSTED CONFIG source (identical discipline to session-run.sh:68-81 / kickoff) ──────────
# Source instance.env in a SUBSHELL and import back ONLY the whitelisted CONFIG var NAMES. Values
# round-trip through printf %q + eval, so shell metacharacters in a value stay literal. An `exit`
# or a function-redef inside instance.env dies with the subshell, never touching this shell.
if [ -f "$INSTANCE_ENV" ]; then
  # shellcheck disable=SC1090
  eval "$(
    set +eu
    . "$INSTANCE_ENV" >/dev/null 2>&1 || true
    for _ie_n in KICKOFF_CORE_DIR MEMORY_DB MEMORY_HOOK_LOG MEMORY_DIR MEMORY_INDEX; do
      _ie_v="${!_ie_n}"
      if [ -n "$_ie_v" ]; then printf 'export %s=%q\n' "$_ie_n" "$_ie_v"; fi
    done
  )"
fi

# REPO_DIR MUST be the adopter's repo so the engine anchors its index/log there (never the shared
# core clone). CLAUDE_PROJECT_DIR is authoritative — set it AFTER the import so an instance.env
# REPO_DIR value can't redirect the engine's derived-data location.
export REPO_DIR="$PROJECT_DIR"

# The single-sourced, whole-tree-pinned engine, located via KICKOFF_CORE_DIR (from instance.env).
CORE_DIR="${KICKOFF_CORE_DIR:-}"
[ -n "$CORE_DIR" ] || exit 0                 # no pinned core → nothing to exec; never block the turn
ENGINE="$CORE_DIR/memory-retrieval/hook.mjs"

# DRY-RUN seam (operator diagnostics + the selftest's path assertion): print the resolved engine
# the hook WOULD exec, then exit — WITHOUT firing node / the retriever.
if [ "${KICKOFF_MEMORY_HOOK_DRYRUN:-0}" = "1" ]; then
  printf '%s\n' "$ENGINE"
  exit 0
fi

# FAIL-OPEN: a missing engine (core not pulled / mid-pull) must not break the turn. Name the
# resolved path on stderr (an operator debugging silent memory sees WHY) + exit 0.
if [ ! -f "$ENGINE" ]; then
  printf 'kickoff memory-hook: engine not present at %s — skipping (is the core pulled? see .kickoff/README)\n' "$ENGINE" >&2
  exit 0
fi

# hook.mjs is executable (0755) + self-passes --experimental-sqlite via its shebang, exactly as
# the kickoff-itself settings.json invokes it directly. stdin (the CC event JSON) passes through.
exec "$ENGINE"
