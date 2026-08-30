#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# memory-orphan-check — "is anything ALIVE that memory has never heard of?"
#
# The failure this exists to prevent (observed 2026-07-13): a freshly-looped
# coordinator was asked about "the tournament app" and had NO IDEA one existed.
# The state was written in forensic detail — but as a SUBSECTION of another
# project's memory file, so the always-loaded index never mentioned it. The
# recall hook could not help either: it is query-driven, and you cannot ask
# about a project you have never heard of.
#
# A buried fact and a lost fact are operationally identical.
#
# So: at session start, look for LIVE SIGNALS on disk — a project with recent
# git activity or a running server — and check the memory index mentions it.
# Anything alive that the index has never heard of is an ORPHAN, and we say so
# LOUDLY. Deterministic, no model judgement, fails loud instead of silent.
#
#   bash scripts/memory-orphan-check.sh [workspace_root] [memory_index_path]
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

ROOT="${1:-$HOME}"
INDEX="${2:-}"
DAYS="${ORPHAN_DAYS:-14}"

# Locate the memory index if not given.
if [ -z "$INDEX" ]; then
  for c in "$ROOT/memory/MEMORY.md" \
           "$HOME/.claude/projects/$(basename "$PWD" | tr -d '\n')/memory/MEMORY.md"; do
    [ -f "$c" ] && { INDEX="$c"; break; }
  done
fi
[ -f "${INDEX:-}" ] || { echo "memory-orphan-check: no MEMORY.md found (pass one as \$2)" >&2; exit 0; }

idx=$(cat "$INDEX")

# Ports currently bound by a process whose cwd sits under $ROOT → that project is RUNNING.
running_dirs() {
  command -v ss >/dev/null 2>&1 || return 0
  ss -ltnp 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u | while read -r pid; do
    d=$(readlink -f "/proc/$pid/cwd" 2>/dev/null) || continue
    case "$d" in "$ROOT"/*) echo "$d" ;; esac
  done
}

orphans=0
alive=0

# Does the index mention this project by NAME? Substring matching fails OPEN in the worst way: a repo
# named `acme` is "found" in an index that only ever says `acmed`, and the orphan stays invisible — the
# exact miss this script exists to prevent. So require the name to stand alone, treating [A-Za-z0-9_-]
# as name characters (`acme` must not match `acmed`; `orders` must not match `orders-service`).
index_mentions() {
  local esc
  esc=$(printf '%s' "$1" | sed 's/[][\.^$*+?(){}|\/-]/\\&/g')
  # HERE-STRING, never `printf … | grep -q`. Under `set -o pipefail` that pipeline returns 141
  # (SIGPIPE) whenever the haystack exceeds the ~64KB pipe buffer: grep -q exits at the FIRST match,
  # the still-writing printf dies, and pipefail surfaces the writer's death as the pipeline status —
  # so a project that IS in the index reports as an ORPHAN. It is RACY (it depends on whether printf
  # finished before grep exited), which is why it flapped 3-of-5 runs rather than failing outright.
  # MEMORY.md sits right at that boundary (~67KB), so this check started lying the day the index grew.
  # This is [[pipefail-sigpipe-grep-flake]] — my own banked memory, and I wrote the bug anyway hours
  # after fixing this very script. A here-string has no pipe and no writer to kill.
  grep -qiE "(^|[^A-Za-z0-9_-])${esc}([^A-Za-z0-9_-]|\$)" <<< "$idx"
}

# Candidate projects: git repos up to $ORPHAN_DEPTH levels under $ROOT. Direct children ONLY was a
# fail-open: a repo at ~/code/tournament-app — literally this script's own motivating example — yielded
# alive=0 and an "everything is visible" green. Prune the usual dense/vendored trees so a big $HOME
# cannot stall a boot. `-type d -name .git` also skips linked worktrees (their .git is a FILE).
DEPTH="${ORPHAN_DEPTH:-3}"

# The repo that OWNS this index can never be an orphan TO it — walk up from the index to its repo root.
# Without this, the owning repo self-flags whenever the index only names it inside a longer string (e.g.
# a filename like `claude-kickoff-north-star.md` — the name-boundary rule correctly refuses that), which
# would fire on EVERY adopter, every boot. A check that cries wolf is a check that gets ignored.
INDEX_REPO=""
_d="$(cd "$(dirname "$INDEX")" 2>/dev/null && pwd)"
while [ -n "$_d" ] && [ "$_d" != "/" ]; do
  [ -e "$_d/.git" ] && { INDEX_REPO="$_d"; break; }
  _d="$(dirname "$_d")"
done

# An ENGINE-SOURCE repo (kickoff's own tree — scripts/core-manifest.txt present; the same
# heuristic the upgrade turnkey uses to refuse pulling onto the source) is not an operator
# workspace: every sibling under $ROOT is the operator's OTHER project, adopted on its own
# schedule. "Invisible to THIS index" is noise by definition until a sibling adopts (then it
# self-skips via its own MEMORY.md below) — and noise trains the reader to ignore the real
# orphans. So skip the sibling-visibility scan entirely, with one honest notice.
if [ -n "$INDEX_REPO" ] && [ -f "$INDEX_REPO/scripts/core-manifest.txt" ]; then
  echo "  … engine-source repo — sibling adoption tracked per-project, not here."
  exit 0
fi

while IFS= read -r gitdir; do
  [ -n "$gitdir" ] || continue
  dir="${gitdir%/.git}"
  name=$(basename "$dir")

  # Skip the index's own repo (tautologically known) and any pinned kickoff-core clone: a core is the
  # ENGINE an adopter pulls, not a project someone works on. Its commits are release artifacts, so it
  # would red for ~ORPHAN_DAYS after every release and train the reader to skim past real orphans.
  [ -n "$INDEX_REPO" ] && [ "$(cd "$dir" 2>/dev/null && pwd)" = "$INDEX_REPO" ] && continue
  [ -f "$dir/scripts/core-manifest.txt" ] && continue

  # A sibling with its OWN memory index is a DIFFERENT project's adopted repo, not an
  # orphan OF THIS index — on a shared box every OTHER adopted repo (its
  # own .kickoff/memory/MEMORY.md or memory/MEMORY.md) was 100% false-flagged as invisible
  # to THIS index, training the operator to ignore the check. Only a repo with LIVE signal
  # and NO index anywhere is a real orphan.
  [ -f "$dir/.kickoff/memory/MEMORY.md" ] && continue
  [ -f "$dir/memory/MEMORY.md" ] && continue

  recent=""
  last=$(git -C "$dir" log -1 --format=%ct 2>/dev/null || echo 0)
  if [ "$last" -gt 0 ]; then
    age_days=$(( ( $(date +%s) - last ) / 86400 ))
    [ "$age_days" -le "$DAYS" ] && recent="commits ${age_days}d ago"
  fi

  serving=""
  if running_dirs | grep -qx "$(readlink -f "$dir")"; then serving="a server is RUNNING"; fi

  # Only care about projects showing a LIVE signal.
  [ -z "$recent" ] && [ -z "$serving" ] && continue
  alive=$((alive + 1))

  signal=$(printf '%s' "$recent${recent:+${serving:+, }}$serving")

  # Does the always-loaded index mention it at all?
  if index_mentions "$name"; then
    printf '  ✓ %-22s %s\n' "$name" "— in the index ($signal)"
  else
    printf '  ⚠ ORPHAN: %-14s %s — but NOT in MEMORY.md\n' "$name" "$signal"
    orphans=$((orphans + 1))
  fi
done <<EOF
$(find "$ROOT" -maxdepth "$DEPTH" \
    \( -name node_modules -o -name .cache -o -name vendor -o -name .venv \
       -o -name .direnv -o -name target -o -name dist \) -prune -o \
    -type d -name .git -print 2>/dev/null)
EOF

echo
if [ "$orphans" -gt 0 ]; then
  echo "  ⚠ $orphans/$alive live project(s) are INVISIBLE at boot."
  echo "    A future session will not know they exist. Give each its OWN memory file"
  echo "    and its OWN line in MEMORY.md — what · where (path + port) · status ·"
  echo "    open taps · deadline. Never as a subsection of another project's file."
  exit 1
fi
if [ "$alive" -eq 0 ]; then
  # A green here would be a check that cannot fail: no live projects found means the SCAN came up empty,
  # which is far more often a wrong $ROOT / too-shallow $ORPHAN_DEPTH than a genuinely idle box. Say so.
  echo "  … no live project found under $ROOT (depth ≤ $DEPTH, active ≤ ${DAYS}d)."
  echo "    That is a finding about the SCAN, not an all-clear: check the root and ORPHAN_DEPTH"
  echo "    if you expected repos here (nested layouts like ~/code/<repo> need depth ≥ 3)."
  exit 0
fi
echo "  ✓ every live project ($alive) is visible in the memory index."
