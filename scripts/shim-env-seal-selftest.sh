#!/usr/bin/env bash
# shim-env-seal-selftest.sh — prove the generated SEAM shims are sealed against AMBIENT
# data-path env, and the scanners FAIL CLOSED outside a git work tree.
#
#   bash scripts/shim-env-seal-selftest.sh
#
# WHY THIS EXISTS (2026-07-24, adopter stress-test — both reproduced live):
#   1. SHIM ENV-SEAL. The shim exports REPO_DIR from its own location (G10c), but
#      instance.env sets MC_STATE_FILE/MC_TRACKER_FILE/MEMORY_DB/MEMORY_HOOK_LOG/
#      MEMORY_INDEX as ${VAR:-default} — so an AMBIENT value from a parent shell (the
#      fleet coordinator's session) WON, and one adopter's `mc render-tracker` silently
#      rewrote ANOTHER repo's TRACKER.md. The shim must unset those vars before sourcing
#      instance.env so the per-repo defaults always resolve to ITS repo.
#   2. SCANNER FAIL-OPEN. scan-secrets/scan-structure did `git ls-files || true` with no
#      cd — from a non-git cwd the list was EMPTY and the secret gate printed green on
#      ZERO files (rc=0). And the scan shims exec'd the engine without cd-ing to
#      REPO_DIR, so they scanned whatever cwd they were called from.
#
# Tests the REAL generator (adopt-manifest.py gen-shim) + the REAL scanners — never a
# replica. Hermetic: everything under mktemp; ambient whitelist vars are passed only via
# explicit `env`; no live repo is ever read or written.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
AM="$HERE/adopt-manifest.py"
SS="$HERE/scan-secrets.sh"
ST="$HERE/scan-structure.sh"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }

for f in "$AM" "$SS" "$ST"; do
  [ -f "$f" ] || { printf '  ❌ missing: %s\n' "$f"; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { printf '  ❌ python3 not found\n'; exit 1; }

# scrub the ambient instance.env whitelist so a live shell's exports can't mask (or fake)
# the very leak this asserts — the adopt-selftest lesson.
unset MC_STATE_FILE MC_TRACKER_FILE MEMORY_DB MEMORY_HOOK_LOG MEMORY_INDEX MEMORY_DIR \
      TELEGRAM_STATE_DIR REPO_DIR KICKOFF_CORE_DIR GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE 2>/dev/null || true

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

echo "▶ shim env-seal + scanner fail-closed self-test"
echo

# ── fixtures ─────────────────────────────────────────────────────────────────────────
# A stub CORE whose engines just report what they were handed (env / cwd).
STUB="$TMPROOT/core"
mkdir -p "$STUB/mission-control" "$STUB/scripts"
cat > "$STUB/mission-control/mc-update.py" <<'PY'
import os
for v in ("MC_STATE_FILE", "MC_TRACKER_FILE", "MEMORY_DB", "MEMORY_HOOK_LOG", "MEMORY_INDEX"):
    print(v + "=" + os.environ.get(v, ""))
PY
printf '#!/usr/bin/env bash\npwd -P\n' > "$STUB/scripts/scan-secrets.sh"
printf '#!/usr/bin/env bash\npwd -P\n' > "$STUB/scripts/scan-structure.sh"
chmod +x "$STUB/scripts/scan-secrets.sh" "$STUB/scripts/scan-structure.sh"

# An adopter repo with REAL generated shims + an instance.env carrying the REAL template's
# ${VAR:-default} idiom (the exact lines an ambient var could override).
A="$TMPROOT/adopter-a"; mkdir -p "$A/.kickoff"
for name in mc scan-secrets scan-structure; do
  python3 "$AM" gen-shim --repo "$A" --name "$name" --source core-vTEST >/dev/null 2>&1 \
    || { bad "gen-shim $name failed"; exit 1; }
done
cat > "$A/.kickoff/instance.env" <<EOF
export KICKOFF_CORE_DIR="\${KICKOFF_CORE_DIR:-$STUB}"
export MEMORY_INDEX="\${MEMORY_INDEX:-.kickoff/memory/MEMORY.md}"
export MEMORY_DB="\${MEMORY_DB:-\${REPO_DIR:-\$PWD}/.kickoff/state/memory-retrieval/memory-index.db}"
export MEMORY_HOOK_LOG="\${MEMORY_HOOK_LOG:-\${REPO_DIR:-\$PWD}/.kickoff/state/memory-retrieval/retrieval-log.jsonl}"
export MC_STATE_FILE="\${MC_STATE_FILE:-\${REPO_DIR:-\$PWD}/.kickoff/state/mission-control/mission-state.json}"
export MC_TRACKER_FILE="\${MC_TRACKER_FILE:-\${REPO_DIR:-\$PWD}/.kickoff/state/TRACKER.md}"
EOF
A_R="$(cd "$A" && pwd -P)"
OTHER="$TMPROOT/OTHER-repo"   # the foreign repo an ambient var points at (never written)
val() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(a) SHIM ENV-SEAL — ambient MC_/MEMORY_ vars must NOT survive into the shim's engine"
# ══════════════════════════════════════════════════════════════════════════════════════
# RED pre-fix: the ambient value WINS over instance.env's ${VAR:-default} → the shim
# reads/writes the OTHER repo's board/tracker (the live cross-repo rewrite).
OUT="$(env MC_STATE_FILE="$OTHER/board.json" MC_TRACKER_FILE="$OTHER/TRACKER.md" \
           MEMORY_DB="$OTHER/mem.db" MEMORY_HOOK_LOG="$OTHER/log.jsonl" \
           MEMORY_INDEX="$OTHER/MEMORY.md" "$A/.kickoff/bin/mc" render-tracker 2>/dev/null || true)"
for v in MC_STATE_FILE MC_TRACKER_FILE MEMORY_DB MEMORY_HOOK_LOG; do
  got="$(val "$OUT" "$v")"
  case "$got" in
    "$A"/*|"$A_R"/*) ok "seal: $v resolves into the shim's OWN repo despite an ambient override" ;;
    "$OTHER"/*)      bad "LEAK: $v resolved to the AMBIENT foreign repo ($got) — cross-repo write path" ;;
    *)               bad "seal: $v at an unexpected value: ${got:-<none>}" ;;
  esac
done
got="$(val "$OUT" MEMORY_INDEX)"
case "$got" in
  ".kickoff/memory/MEMORY.md") ok "seal: MEMORY_INDEX falls back to the repo-relative default" ;;
  "$OTHER"/*)                  bad "LEAK: MEMORY_INDEX resolved to the AMBIENT foreign repo ($got)" ;;
  *)                           bad "seal: MEMORY_INDEX at an unexpected value: ${got:-<none>}" ;;
esac
# control: an explicit value written IN instance.env still wins over the repo anchor.
KCUST="$TMPROOT/custom-board.json"
cp "$A/.kickoff/instance.env" "$TMPROOT/instance.env.bak"
printf 'export KICKOFF_CORE_DIR="${KICKOFF_CORE_DIR:-%s}"\nexport MC_STATE_FILE="${MC_STATE_FILE:-%s}"\n' \
  "$STUB" "$KCUST" > "$A/.kickoff/instance.env"
OUT2="$(env MC_STATE_FILE="$OTHER/board.json" "$A/.kickoff/bin/mc" x 2>/dev/null || true)"
[ "$(val "$OUT2" MC_STATE_FILE)" = "$KCUST" ] \
  && ok "control: an explicit absolute default IN instance.env still wins (override > anchor)" \
  || bad "control: instance.env's own explicit value no longer wins ($(val "$OUT2" MC_STATE_FILE))"
cp "$TMPROOT/instance.env.bak" "$A/.kickoff/instance.env"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(b) SCAN SHIM cd — the shims must scan their OWN repo, not the caller's cwd"
# ══════════════════════════════════════════════════════════════════════════════════════
F="$TMPROOT/foreign-cwd"; mkdir -p "$F"
for name in scan-secrets scan-structure; do
  got="$(cd "$F" && "$A/.kickoff/bin/$name" 2>/dev/null || true)"
  if [ "$got" = "$A_R" ]; then ok "shim $name execs the engine FROM the shim's own repo"
  else bad "shim $name ran the engine from '$got' (caller's cwd) — scans the wrong tree"; fi
done
# the shim stays machine-path-free + byte-identical across adopters (the preflight-#8 hash pin)
B="$TMPROOT/adopter-b"; mkdir -p "$B/.kickoff"
for name in mc scan-secrets scan-structure; do
  python3 "$AM" gen-shim --repo "$B" --name "$name" --source core-vTEST >/dev/null 2>&1
  if cmp -s "$A/.kickoff/bin/$name" "$B/.kickoff/bin/$name" && ! grep -q "$TMPROOT" "$A/.kickoff/bin/$name"; then
    ok "shim $name is byte-identical across adopters + machine-path-free"
  else
    bad "shim $name differs across adopters or embeds a machine path (hash pin breaks)"
  fi
done
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(c) SCANNER FAIL-CLOSED — non-git cwd must fail LOUD; an empty real repo stays green"
# ══════════════════════════════════════════════════════════════════════════════════════
NONGIT="$TMPROOT/nongit"; mkdir -p "$NONGIT"
# RED pre-fix: '|| true' swallows git's error → 0 files scanned → '✅ no secrets' rc=0.
for scanner in "$SS" "$ST"; do
  nm="$(basename "$scanner")"
  rc=0; out="$(cd "$NONGIT" && env GIT_CEILING_DIRECTORIES="$TMPROOT" bash "$scanner" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then ok "$nm: non-git cwd → LOUD non-zero exit (rc=$rc)"
  else bad "FAIL-OPEN: $nm exited 0 in a non-git cwd — a gate green on ZERO files: ${out}"; fi
done
rc=0; out="$(cd "$NONGIT" && env GIT_CEILING_DIRECTORIES="$TMPROOT" bash "$SS" --staged 2>&1)" || rc=$?
[ "$rc" -ne 0 ] && ok "scan-secrets.sh: --staged in a non-git cwd also fails loud (rc=$rc)" \
  || bad "FAIL-OPEN: scan-secrets.sh --staged exited 0 in a non-git cwd"
# a legitimately-EMPTY real repo (0 tracked files) is a valid green, not an error
EMPTY="$TMPROOT/empty-repo"; git init -q "$EMPTY"
for scanner in "$SS" "$ST"; do
  nm="$(basename "$scanner")"
  rc=0; out="$(cd "$EMPTY" && bash "$scanner" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] && ok "$nm: legitimately-empty git repo → still green (rc=0)" \
    || bad "$nm: rc=$rc on an EMPTY-but-real repo — fail-closed overshot: ${out}"
done
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(d) DETECTION CONTROLS — the gate still catches a real secret in every scope"
# ══════════════════════════════════════════════════════════════════════════════════════
# a tracked fake AWS key (fixture-only, never a real credential) must still trip the gate
SECRET_LINE='const awsId = "AKIAABCDEFGHIJKLMNOP";'
SR="$TMPROOT/secret-repo"; git init -q "$SR"
printf '%s\n' "$SECRET_LINE" > "$SR/config.js"
git -C "$SR" add config.js
rc=0; out="$(cd "$SR" && bash "$SS" 2>&1)" || rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'AWS access key id'; then
  ok "all scope: a tracked AWS key is still FOUND (rc=1)"
else
  bad "all scope: the AWS-key control did not trip (rc=$rc): ${out}"
fi
rc=0; out="$(cd "$SR" && bash "$SS" --staged 2>&1)" || rc=$?
[ "$rc" -eq 1 ] && ok "staged scope: the staged AWS key is still FOUND (rc=1)" \
  || bad "staged scope: the AWS-key control did not trip (rc=$rc)"
# explicit paths need no git at all — that scope must keep working even OUTSIDE a repo
printf '%s\n' "$SECRET_LINE" > "$NONGIT/leak.js"
rc=0; out="$(cd "$NONGIT" && env GIT_CEILING_DIRECTORIES="$TMPROOT" bash "$SS" leak.js 2>&1)" || rc=$?
[ "$rc" -eq 1 ] && ok "explicit scope: scanning a named file outside a repo still works (rc=1, found)" \
  || bad "explicit scope broke outside a git repo (rc=$rc): ${out}"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(e) GIT_DIR SEAL — an ambient GIT_DIR must NOT steer the shim's scanner off its own repo"
# ══════════════════════════════════════════════════════════════════════════════════════
# The scan shims cd to REPO_DIR, but `git ls-files` honors an ambient absolute GIT_DIR regardless
# of cwd — so unless the shim also unsets GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE, a foreign GIT_DIR
# redirects the entire scan. Uses the REAL scanner (this repo's core), not the pwd-stub.
REALCORE="$(cd "$(dirname "$AM")/.." && pwd -P)"        # $AM=.../scripts/adopt-manifest.py
G="$TMPROOT/git-seal-adopter"; mkdir -p "$G/.kickoff"
python3 "$AM" gen-shim --repo "$G" --name scan-secrets --source core-vTEST >/dev/null 2>&1
printf 'export KICKOFF_CORE_DIR="%s"\n' "$REALCORE" > "$G/.kickoff/instance.env"
git init -q "$G"; printf 'clean = true\n' > "$G/ok.txt"; git -C "$G" add ok.txt
FGN="$TMPROOT/foreign-secret"; git init -q "$FGN"      # foreign repo, reachable ONLY via GIT_DIR
printf 'const awsId = "AKIAABCDEFGHIJKLMNOP";\n' > "$FGN/leak.js"; git -C "$FGN" add leak.js
rc=0; out="$(cd "$G" && env GIT_DIR="$FGN/.git" GIT_WORK_TREE="$FGN" "$G/.kickoff/bin/scan-secrets" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then ok "ambient GIT_DIR ignored — shim scanned its OWN clean repo (rc=0), not the foreign secret"
else bad "GIT_DIR LEAK: shim scan hit the foreign repo (rc=$rc) — ambient GIT_DIR steered git ls-files: ${out}"; fi
echo

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && printf '  ✅ shims env-sealed + repo-anchored; scanners fail CLOSED, detection intact\n'
[ "$FAIL" -eq 0 ]
