#!/usr/bin/env bash
# newbox-from-main.sh — move a clone of PUBLIC main onto the engine-development branch,
# without losing the three files that live on main and are gitignored on the dev lineage.
#
#   bash scripts/newbox-from-main.sh
#
# Run it straight off the remote, from a main checkout, in one line:
#   cd <your clone> && git fetch origin \
#     && git show origin/brownfield-devex:scripts/newbox-from-main.sh > /tmp/nb.sh && bash /tmp/nb.sh
#
# WHY THIS EXISTS. `main` (the curated public release lineage) and `brownfield-devex` (the dev
# trunk) share NO merge base — post-filter-repo they are unrelated histories, so you cannot merge
# one into the other, only check out across. Up to three tracked-on-main paths are absent or
# gitignored on the dev branch, so a bare `git checkout brownfield-devex` DELETES them from the
# working tree with no warning. WHICH ones depends on where main sits — verified 2026-08-27:
# main@17c91ac tracks the first two; TRACKER.md was tracked on older release lineages (core-v0.39)
# and is not on current main. Each is guarded by an existence test, so a missing one is a no-op:
#
#   memory/MEMORY.md                      .gitignore:32 on dev — the ALWAYS-LOADED memory roll-up.
#                                         preflight #3 fail-closes without it.
#   TRACKER.md                            .gitignore:19 on dev — instance-local on this lineage.
#   mission-control/mission-state.json    the board's state store.
#
# `memory/MEMORY.md` is restored from `origin/main`, which is its authoritative copy (it is
# hand-curated, never generated). The other two are saved aside and put back.
#
# Idempotent: safe to re-run. Already on the dev branch → it just refreshes and re-runs bring-up.
set -euo pipefail

# Resolve the repo from the CALLER'S CWD, not from $0: the documented one-liner writes this
# script to /tmp and runs it from there, where "$(dirname $0)/.." is `/`. The operator always
# runs it from inside the clone, so the git toplevel is the honest anchor.
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT" ] || { printf 'newbox: FAILED — not inside a git repository. cd into your kickoff clone first.\n' >&2; exit 1; }
DEV_BRANCH="${DEV_BRANCH:-brownfield-devex}"
log()  { printf 'newbox: %s\n' "$*"; }
die()  { printf 'newbox: FAILED — %s\n' "$*" >&2; exit 1; }

# ── preconditions ─────────────────────────────────────────────────────────────
[ -f "$ROOT/scripts/core-manifest.txt" ] \
  || die "not a kickoff engine-source checkout ($ROOT). Run this from your clone of the kickoff repo."
command -v git >/dev/null || die "git not found on PATH"
command -v node >/dev/null || die "node not found on PATH — the retrieval engine needs it"

cd "$ROOT"
if [ -n "$(git status --porcelain)" ]; then
  git status --short >&2
  die "git tree is dirty. Commit or stash first — this script switches branches and rebuilds derived state."
fi

# ── save the three cross-lineage files ────────────────────────────────────────
KEEP="$(mktemp -d)"
trap 'rm -rf "$KEEP"' EXIT
for f in TRACKER.md mission-control/mission-state.json; do
  if [ -f "$ROOT/$f" ]; then
    mkdir -p "$KEEP/$(dirname "$f")"
    cp "$ROOT/$f" "$KEEP/$f"
    log "saved $f (gitignored on $DEV_BRANCH — the checkout would delete it)"
  fi
done

# ── fetch + switch ────────────────────────────────────────────────────────────
log "fetching origin …"
git fetch origin --prune --tags >/dev/null 2>&1 || die "git fetch origin failed — check network / SSH access"

git rev-parse --verify --quiet "refs/remotes/origin/$DEV_BRANCH" >/dev/null \
  || die "origin/$DEV_BRANCH does not exist on the remote"

CUR="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CUR" = "$DEV_BRANCH" ]; then
  log "already on $DEV_BRANCH — fast-forwarding"
  git merge --ff-only "origin/$DEV_BRANCH" >/dev/null || die "cannot fast-forward $DEV_BRANCH (local commits? diverged?)"
elif git rev-parse --verify --quiet "refs/heads/$DEV_BRANCH" >/dev/null; then
  log "switching $CUR → $DEV_BRANCH"
  git checkout "$DEV_BRANCH" >/dev/null 2>&1 || die "checkout $DEV_BRANCH failed"
  git merge --ff-only "origin/$DEV_BRANCH" >/dev/null || die "cannot fast-forward $DEV_BRANCH (local commits? diverged?)"
else
  log "creating $DEV_BRANCH tracking origin/$DEV_BRANCH (from $CUR)"
  git checkout -b "$DEV_BRANCH" --track "origin/$DEV_BRANCH" >/dev/null 2>&1 || die "could not create $DEV_BRANCH"
fi
log "now on $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)"

# ── restore the three ─────────────────────────────────────────────────────────
# MEMORY.md comes from origin/main — its authoritative copy. It is hand-curated, so it may lag
# the newest facts by a few index lines; the RETRIEVAL index (built next) reads memory/*.md
# directly and is unaffected.
if [ ! -f "$ROOT/memory/MEMORY.md" ]; then
  mkdir -p "$ROOT/memory"
  if git show origin/main:memory/MEMORY.md > "$ROOT/memory/MEMORY.md" 2>/dev/null; then
    log "restored memory/MEMORY.md from origin/main ($(wc -l < "$ROOT/memory/MEMORY.md") lines)"
  else
    rm -f "$ROOT/memory/MEMORY.md"
    log "WARN: could not restore memory/MEMORY.md from origin/main — preflight #3 will flag it"
  fi
fi
for f in TRACKER.md mission-control/mission-state.json; do
  if [ ! -f "$ROOT/$f" ] && [ -f "$KEEP/$f" ]; then
    mkdir -p "$ROOT/$(dirname "$f")"
    cp "$KEEP/$f" "$ROOT/$f"
    log "restored $f"
  fi
done

[ -z "$(git status --porcelain)" ] || { git status --short >&2; die "tree is dirty after the restore — inspect before continuing"; }

# ── hand off to the bring-up turnkey ──────────────────────────────────────────
log "handing off to scripts/bringup-source-instance.sh …"
echo
exec bash "$ROOT/scripts/bringup-source-instance.sh"
