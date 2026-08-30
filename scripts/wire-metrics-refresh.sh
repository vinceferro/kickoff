#!/usr/bin/env bash
# wire-metrics-refresh.sh — install (or remove) an auto-refresh git post-commit
# hook that re-derives memory-retrieval/metrics.json whenever a commit touches a
# per-fact memory file. Idempotent + reversible.
#
#   bash scripts/wire-metrics-refresh.sh            # install
#   bash scripts/wire-metrics-refresh.sh --remove   # take it back out
#
# WHY A SCRIPT — the operator's one-tap. Installing a git hook changes how THIS
# clone behaves on every commit, i.e. it modifies the agent's own runtime; the
# harness (correctly) gates the agent editing hooks/settings directly. Running
# this script yourself IS that explicit human action. It merges into any existing
# post-commit WITHOUT clobbering it (a marker-delimited block), and re-running
# never duplicates the block.
#
# WHAT THE HOOK DOES: on each commit, if the commit changed a top-level memory/*.md
# file (excluding the MEMORY.md roll-up index), it runs
# `memory-retrieval/run.sh refresh-metrics` — rebuild the index on the live corpus,
# re-derive metrics.json, update the Mission Control card. So the recall figure
# tracks the corpus automatically instead of drifting to a stale hand-run snapshot.
# (post-commit runs AFTER the commit, so metrics.json is refreshed in the working
# tree right after — commit it to record the new number. A one-commit lag, and the
# metrics.json/card timestamp keeps it honest in the meantime.)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-install}"

# Respect core.hooksPath (lefthook/husky) if set; else the default .git/hooks.
HOOKS_DIR="$(cd "$ROOT" && git rev-parse --git-path hooks)"
case "$HOOKS_DIR" in /*) ;; *) HOOKS_DIR="$ROOT/$HOOKS_DIR" ;; esac
HOOK="$HOOKS_DIR/post-commit"

python3 - "$HOOK" "$MODE" <<'PY'
import os, stat, sys
hook_path, mode = sys.argv[1], sys.argv[2]
BEGIN = "# >>> memory-metrics-refresh (wire-metrics-refresh.sh) >>>"
END   = "# <<< memory-metrics-refresh <<<"
BLOCK = BEGIN + "\n" + r'''# Auto-refresh memory-recall metrics when a commit touches a per-fact memory file.
# Installed by scripts/wire-metrics-refresh.sh. Remove: bash scripts/wire-metrics-refresh.sh --remove
if git rev-parse --show-toplevel >/dev/null 2>&1; then
  __mmr_root="$(git rev-parse --show-toplevel)"
  __mmr_changed="$(git diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null | grep -E '^memory/[^/]+\.md$' | grep -v '^memory/MEMORY\.md$' || true)"
  if [ -n "$__mmr_changed" ] && [ -x "$__mmr_root/memory-retrieval/run.sh" ]; then
    echo "[memory-metrics] memory changed -- refreshing recall metrics..."
    ( cd "$__mmr_root/memory-retrieval" && ./run.sh refresh-metrics ) \
      || echo "[memory-metrics] refresh failed (non-fatal); run ./memory-retrieval/run.sh refresh-metrics"
    echo "[memory-metrics] metrics + board refreshed (uncommitted) -- commit to record the new figure."
  fi
fi
''' + END

def strip_block(text):
    out, skip = [], False
    for ln in text.splitlines():
        if ln.strip() == BEGIN: skip = True; continue
        if ln.strip() == END:   skip = False; continue
        if not skip: out.append(ln)
    return "\n".join(out)

existing = ""
if os.path.exists(hook_path):
    with open(hook_path) as f:
        existing = f.read()

body = strip_block(existing).rstrip("\n") if existing else ""
if not body.startswith("#!"):                      # a hook must lead with a shebang
    body = "#!/usr/bin/env bash" + ("\n" + body if body else "")

if mode != "--remove":
    body = body + "\n\n" + BLOCK + "\n"

# On --remove, if nothing but the shebang remains, drop the file so we leave it clean.
meaningful = [l for l in body.splitlines() if l.strip() and not l.startswith("#!")]
if mode == "--remove" and not meaningful:
    if os.path.exists(hook_path):
        os.remove(hook_path)
    print("REMOVED memory-metrics post-commit hook -> " + hook_path + " (nothing else in it; file deleted)")
    sys.exit(0)

os.makedirs(os.path.dirname(hook_path), exist_ok=True)
with open(hook_path, "w") as f:
    f.write(body if body.endswith("\n") else body + "\n")
os.chmod(hook_path, os.stat(hook_path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
print(("REMOVED" if mode == "--remove" else "INSTALLED") + " memory-metrics post-commit hook -> " + hook_path)
PY

echo "Done."
if [ "$MODE" != "--remove" ]; then
  echo "It fires on your NEXT commit that changes memory/*.md, running:"
  echo "    memory-retrieval/run.sh refresh-metrics"
  echo "Run it now (no commit needed):  ./memory-retrieval/run.sh refresh-metrics"
fi
