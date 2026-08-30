#!/usr/bin/env bash
# memory-recall-hygiene-selftest.sh — adopter stress-test fixes, cluster 2.
#
#   bash scripts/memory-recall-hygiene-selftest.sh
#
# Three independent, RED-first checks:
#
#   2A. memory-retrieval/hook.mjs logFire() must land the "no-index" breadcrumb even when
#       the log's parent dir was never created. Before the fix, appendFileSync threw ENOENT
#       (gitignored .kickoff/state/... absent on a fresh clone / before the first `index`),
#       the throw was swallowed by the "logging must never break the hook" catch, and the
#       hook silently no-op'd with ZERO diagnostic — the exact reason recall silently never
#       fired on a live adopter went undetected.
#   2B. scripts/memory-orphan-check.sh must NOT flag a sibling dir that has its OWN memory
#       index (its own .kickoff/memory/MEMORY.md or memory/MEMORY.md) as an orphan of THIS
#       index — on a shared box every OTHER adopted repo was a 100% false positive, training
#       the operator to ignore the check.
#   2C. scripts/templates/kickoff.gitignore must cover the runtime markers the engine writes
#       into .kickoff/ (crew-review.last, announce.count, announce.last,
#       supervisor.session.pid, model-fallback) so they never get committed in adopters.
#
# Hermetic throughout (mktemp fixtures only; never touches the live repo/box state).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
MR="$REPO/memory-retrieval"
OC="$HERE/memory-orphan-check.sh"
GI="$REPO/scripts/templates/kickoff.gitignore"

PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }

mkrepo() { # mkrepo <path> — a git repo with one commit (a "recent activity" live signal)
  mkdir -p "$1"
  ( cd "$1" && git init -q . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m x ) 2>/dev/null
}

echo "▶ memory recall hygiene self-test (adopter stress-test cluster 2: breadcrumb + orphan-scope + gitignore)"
echo

# ── 2A. the no-index breadcrumb must land even with a missing state dir ──────────────────────
if ! command -v node >/dev/null 2>&1; then
  echo "  (node not found — skipping the 2A hook breadcrumb check)"
else
  FIX="$(mktemp -d)"
  mkdir -p "$FIX/corpus"
  DB="$FIX/state/nope/memory-index.db"        # never built — triggers the no-index path
  LOG="$FIX/state/memory-retrieval/retrieval-log.jsonl"   # parent dir does NOT pre-exist
  [ ! -d "$FIX/state" ] || bad "fixture setup: state dir must not pre-exist"
  MEMORY_DIR="$FIX/corpus" MEMORY_DB="$DB" MEMORY_HOOK_LOG="$LOG" MEMORY_AUTO_REINDEX=0 \
    node --experimental-sqlite "$MR/hook.mjs" "what is the chrome principle" >/dev/null 2>&1
  hook_rc=$?
  [ "$hook_rc" -eq 0 ] && ok "the hook itself still exits 0 with a missing index + missing state dir" \
    || bad "the hook exited $hook_rc — must never break the user's turn"
  if [ -f "$LOG" ] && grep -q '"reason":"no-index"' "$LOG"; then
    ok "the no-index breadcrumb LANDS in the log despite the missing parent dir (the fix)"
  else
    bad "NO BREADCRUMB: the log was never written — a missing-index hook no-ops with zero diagnostic"
  fi
  rm -rf "$FIX"
fi

# ── 2B. a sibling with its OWN memory index is not an orphan OF THIS index ───────────────────
S=$(mktemp -d)
mkrepo "$S/sibling-with-own-index"
mkdir -p "$S/sibling-with-own-index/.kickoff/memory"
printf '# Memory Index\n- own stuff\n' > "$S/sibling-with-own-index/.kickoff/memory/MEMORY.md"
mkrepo "$S/sibling-with-plain-index"
mkdir -p "$S/sibling-with-plain-index/memory"
printf '# Memory Index\n- own stuff\n' > "$S/sibling-with-plain-index/memory/MEMORY.md"
mkrepo "$S/genuine-orphan"
printf '# Memory Index\n- unrelated\n' > "$S/M.md"
out=$(bash "$OC" "$S" "$S/M.md" 2>&1); rc=$?
case "$out" in
  *"ORPHAN: sibling-with-own-index"*) bad "FALSE POSITIVE: a sibling with its OWN .kickoff/memory/MEMORY.md flagged as an orphan" ;;
  *) ok "a sibling with its own .kickoff/memory/MEMORY.md is NOT flagged as an orphan" ;;
esac
case "$out" in
  *"ORPHAN: sibling-with-plain-index"*) bad "FALSE POSITIVE: a sibling with its OWN memory/MEMORY.md flagged as an orphan" ;;
  *) ok "a sibling with its own memory/MEMORY.md is NOT flagged as an orphan" ;;
esac
case "$out" in
  *"ORPHAN: genuine-orphan"*) ok "a live sibling with NO index anywhere is still correctly flagged" ;;
  *) bad "a genuine orphan (no index anywhere) went unflagged — the scope fix over-corrected" ;;
esac
[ "$rc" -eq 1 ] && ok "exit 1 — the one real orphan still blocks nothing but reports loudly" \
                || bad "expected exit 1 (one real orphan present), got $rc"
rm -rf "$S"

# ── 2C. the runtime markers the engine writes into .kickoff/ must be gitignored ──────────────
F=$(mktemp -d)
mkdir -p "$F/.kickoff"
git -C "$F" init -q
cp "$GI" "$F/.kickoff/.gitignore"
# This list WAS five names, and that narrowness is exactly why EIGHT stageable runtime files went
# unseen until an adversarial pass on core-v0.32 looked for them. A guard that hardcodes a sample
# cannot report on what it does not name — it reports on its own bookkeeping. Every name below is a
# verified engine write; auth.env and secret.env are the two that carry credentials.
# TODO(v0.33): derive this list from the engine's own writes rather than restating it here.
KICKOFF_RUNTIME_MARKERS="crew-review.last announce.count announce.last supervisor.session.pid
model-fallback orphan-notified.json auth.env secret.env auth-heal.state auth-escalated
bridge-escalated hop-blocked refresh-requested"
for f in $KICKOFF_RUNTIME_MARKERS; do
  touch "$F/.kickoff/$f"
done
git -C "$F" add -A >/dev/null 2>&1
staged=$(git -C "$F" status --porcelain)
for f in $KICKOFF_RUNTIME_MARKERS; do
  if printf '%s\n' "$staged" | grep -q "\.kickoff/$f"; then
    bad "runtime marker .kickoff/$f is NOT gitignored — would be committed in an adopter"
  else
    ok "runtime marker .kickoff/$f is gitignored"
  fi
done
rm -rf "$F"

echo
echo "──────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "  ✅ cluster 2 fixes hold"; exit 0; } || { echo "  ❌ see failures above"; exit 1; }
