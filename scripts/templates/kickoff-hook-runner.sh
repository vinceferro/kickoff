#!/usr/bin/env bash
# _kickoff-hook-runner — run the gates declared in lefthook.yml for one git hook.
#
#   <hooks-dir>/_kickoff-hook-runner <hook-name>
#
# WHY THIS SHIPS. `kickoff adopt` writes the gate CONFIG (lefthook.yml + .kickoff/lefthook-kickoff.yml)
# but arming it was left to the external `lefthook` binary — which is absent on a plain machine. So a
# repo could be "adopted", pass every check, and still commit completely ungated: config on disk,
# nothing running it. Observed 2026-07-26 on a live adopter that had been committing unguarded since
# adoption, while `kickoff doctor` called it healthy. The origin repo paid the same bill earlier — a
# real RSA private key rode in via `git add -A` because the pre-commit secret scan was never wired.
#
# It DERIVES the command list from the config instead of hardcoding it. Hardcoding is how a gate
# silently drifts: a gate added to the yaml would never run here, and the hook would keep reporting
# green — the "shipped but inert" failure this machinery exists to prevent.
#
# EXTENDS IS LOAD-BEARING, NOT A NICETY. An adopter's root lefthook.yml is usually *just*
#     extends:
#       - .kickoff/lefthook-kickoff.yml
# with ZERO `run:` lines of its own. A runner that reads only the root file finds nothing, prints
# "nothing to run", and exits 0 — a hook that gates nothing while reporting success. So `extends:`
# is followed, and a hook that resolves to zero commands says so loudly rather than passing quietly.
#
# HONEST SCOPE — this is NOT lefthook. It runs each `run:` line under the named hook, in order, and
# fails on the first non-zero. It does NOT implement lefthook's globs, parallelism, staged-file
# templating, or per-command `skip:` beyond the merge/rebase guard below. If the repo gains a real
# lefthook binary, delete these hooks and let `lefthook install` generate its own.
#
# Escape hatch matches lefthook's own convention: LEFTHOOK=0 skips.
set -uo pipefail

HOOK="${1:?usage: _kickoff-hook-runner <hook-name>}"
ROOT="$(git rev-parse --show-toplevel)" || exit 1
cd "$ROOT" || exit 1

[ "${LEFTHOOK:-}" = "0" ] && { echo "kickoff-hooks: LEFTHOOK=0 — skipping $HOOK"; exit 0; }
[ -f lefthook.yml ] || { echo "kickoff-hooks: no lefthook.yml — nothing to run"; exit 0; }

# lefthook skips during merge/rebase; the generated pre-commit entries declare exactly that.
# --git-common-dir, NOT --git-dir: the latter is worktree-LOCAL and resolves wrong inside a linked
# worktree, which is where release staging happens.
GITDIR="$(git rev-parse --git-common-dir 2>/dev/null || git rev-parse --git-dir)"
if [ "$HOOK" = "pre-commit" ]; then
  if [ -f "$GITDIR/MERGE_HEAD" ] || [ -d "$GITDIR/rebase-merge" ] || [ -d "$GITDIR/rebase-apply" ]; then
    echo "kickoff-hooks: merge/rebase in progress — skipping $HOOK (matches the yaml's skip:)"
    exit 0
  fi
fi

# Collect `run:` lines under `<hook>:` across lefthook.yml AND every file it `extends:` (one level,
# which is the shape adopt authors). Missing extends targets are reported, never silently dropped.
mapfile -t CMDS < <(python3 - "$HOOK" <<'PY'
import os, re, sys

hook = sys.argv[1]


def runs(path):
    """`run:` values nested under a column-0 `<hook>:` key, plus the files this one extends."""
    cmds, extends, cur, in_ext = [], [], None, False
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        return cmds, extends
    for line in lines:
        top = re.match(r"^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$", line)
        if top:
            cur = top.group(1)
            in_ext = cur == "extends"
            continue
        if in_ext:
            item = re.match(r"^\s*-\s*(.+?)\s*$", line)
            if item:
                extends.append(item.group(1).strip("'\""))
            continue
        if cur != hook:
            continue
        r = re.match(r"^\s+run:\s*(.+?)\s*$", line)
        if r:
            cmds.append(r.group(1))
    return cmds, extends


cmds, extends = runs("lefthook.yml")
for rel in extends:
    if not os.path.exists(rel):
        # Loud on stderr: an extends pointing at nothing is a gate that silently stopped existing.
        sys.stderr.write("kickoff-hooks: WARNING — lefthook.yml extends '%s' but it is missing\n" % rel)
        continue
    more, _ = runs(rel)
    cmds.extend(more)
for c in cmds:
    print(c)
PY
)

if [ "${#CMDS[@]}" -eq 0 ]; then
  # NOT exit 0. Reaching here means the hook is installed but resolves to no gates — the exact
  # "armed but inert" state that reads as healthy while nothing is checked. Say so, every time.
  echo "kickoff-hooks: ⚠ $HOOK is installed but resolved ZERO gates from lefthook.yml (+extends)."
  echo "               Nothing was checked. Run \`kickoff doctor\` — this is a broken wiring, not a pass."
  exit 0
fi

echo "kickoff-hooks: $HOOK — ${#CMDS[@]} gate(s) from lefthook.yml"
i=0
for c in "${CMDS[@]}"; do
  i=$((i + 1))
  printf '  [%d/%d] %s\n' "$i" "${#CMDS[@]}" "$c"
  # `sh -c` so a trailing `|| true` in the yaml keeps its advisory meaning.
  if ! sh -c "$c"; then
    echo
    echo "  ✗ $HOOK BLOCKED — gate failed: $c"
    echo "    Fix it, or bypass deliberately with:  LEFTHOOK=0 git ${HOOK#pre-} …   (say so if you do)"
    exit 1
  fi
done
echo "kickoff-hooks: $HOOK — all ${#CMDS[@]} gate(s) passed"
exit 0
