#!/usr/bin/env bash
# wire-memory-hook.sh — install (or remove) the proactive memory-retrieval hook
# in this repo's .claude/settings.json (UserPromptSubmit). Idempotent + reversible.
#
#   bash scripts/wire-memory-hook.sh            # install
#   bash scripts/wire-memory-hook.sh --remove   # take it back out
#
# Why a script instead of the agent editing settings.json directly: editing
# .claude/settings.json changes the agent's OWN startup config — a self-modification
# the harness (correctly) gates behind an explicit human action. Running this script
# yourself IS that explicit action. It merges WITHOUT clobbering any existing hooks.
#
# Floors (MEMORY_HOOK_BM25_FLOOR=-8.0 / VEC_FLOOR=0.20) were tuned against THIS repo's
# memory corpus via the eval harness: noise-suppression 4/4, recall@1 85% / @3 95%.
# Retune for a different corpus with `./memory-retrieval/run.sh eval` and edit below.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="$ROOT/.claude/settings.json"
MODE="${1:-install}"

python3 - "$SETTINGS" "$MODE" <<'PY'
import json, os, sys
settings_path, mode = sys.argv[1], sys.argv[2]
cmd = ("MEMORY_DIR=$CLAUDE_PROJECT_DIR/memory "
       "MEMORY_HOOK_BM25_FLOOR=-8.0 MEMORY_HOOK_VEC_FLOOR=0.20 "
       "NODE_NO_WARNINGS=1 $CLAUDE_PROJECT_DIR/memory-retrieval/hook.mjs")
data = {}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        data = json.load(f) or {}
hooks = data.setdefault("hooks", {})
ups = hooks.setdefault("UserPromptSubmit", [])
def is_ours(entry):
    return any("memory-retrieval/hook.mjs" in h.get("command", "")
               for h in entry.get("hooks", []))
ups[:] = [e for e in ups if not is_ours(e)]          # idempotent: drop any prior copy
if mode != "--remove":
    ups.append({"hooks": [{"type": "command", "command": cmd, "timeout": 10}]})
if not ups:                                          # leave the file clean if empty
    hooks.pop("UserPromptSubmit", None)
if not hooks:
    data.pop("hooks", None)
os.makedirs(os.path.dirname(settings_path), exist_ok=True)
with open(settings_path, "w") as f:
    json.dump(data, f, indent=2); f.write("\n")
print(("REMOVED" if mode == "--remove" else "INSTALLED") + " memory hook -> " + settings_path)
PY

echo "Done. The hook fires on your next UserPromptSubmit (start a fresh session if it doesn't hot-reload)."
echo "Smoke-test it:  echo '{\"prompt\":\"about to delete some test data\"}' | MEMORY_DIR=$ROOT/memory $ROOT/memory-retrieval/hook.mjs"
