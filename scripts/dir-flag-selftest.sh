#!/usr/bin/env bash
# dir-flag-selftest.sh — every verb that needs a repo must honour --dir.
#
#   bash scripts/dir-flag-selftest.sh
#
# The bug (found 2026-07-16 by the operator, on his first launch of a freshly adopted repo):
#
#     $ kickoff up --dir ~/their-repo
#     ERROR: REPO_DIR is unset ... Set REPO_DIR (or pass --dir) and re-run
#
# He had passed --dir. `up`, `pull` and `setup` silently IGNORED it while the SHARED not-your-repo
# error advised the very flag they dropped — so the advice could not work and the user was stranded
# at the first thing they do after adopting. adopt/eject/status/verify parsed it all along; the
# inconsistency was invisible because nobody had ever run `up` from outside a repo.
#
# Ignoring --dir is worse than rejecting it: `kickoff pull --dir <repo>` silently upgraded whatever
# REPO_DIR happened to resolve to instead of the repo named on the command line.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
KO="$HERE/kickoff"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
[ -r "$KO" ] || { printf '  ❌ scripts/kickoff not readable\n'; exit 1; }

# ── 1. structural: every repo-targeting verb parses --dir ────────────────────────────────────────
# The error at the top of this file is SHARED by these verbs, so each one must honour the flag it
# tells the user to pass.
for v in adopt eject status verify up pull; do
  A="$(grep -n "^cmd_${v}()" "$KO" | cut -d: -f1)"
  if [ -z "$A" ]; then bad "cmd_${v}() not found (renamed? this suite is now blind to it)"; continue; fi
  B="$(awk -v s="$A" 'NR>s && /^cmd_[a-z]+\(\)/ {print NR; exit}' "$KO")"; B="${B:-99999}"
  if sed -n "${A},${B}p" "$KO" | grep -qE '^\s*--dir\)'; then
    ok "kickoff $v parses --dir"
  else
    bad "kickoff $v IGNORES --dir — but the shared not-your-repo error tells the user to pass it"
  fi
done

# ── 2. the helper it depends on must EXIST (an invented identifier is a runtime-only failure) ────
if grep -q '^_set_repo_dir_from_argv()' "$KO"; then
  ok "_set_repo_dir_from_argv() is defined (not an invented name)"
else
  bad "_set_repo_dir_from_argv() is CALLED but never defined — --dir would die at runtime"
fi
# and it must normalise: a relative --dir leaking into instance.env/the registry is a silent trap
if awk '/^_set_repo_dir_from_argv\(\) \{/,/^\}/' "$KO" | grep -q 'cd .*&& pwd'; then
  ok "--dir is normalised to an absolute path (no relative path reaches instance.env)"
else
  bad "--dir is NOT normalised — a relative path would be persisted"
fi

# ── 3. BEHAVIOURAL: `up --dir <repo>` must target THAT repo ──────────────────────────────────────
# The structural check alone would pass on a --dir case that parsed the flag and dropped it.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
TARGET="$T/myrepo"; mkdir -p "$TARGET/.kickoff"
( cd "$TARGET" && git init -q . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m i ) 2>/dev/null
out="$(cd "$T" && env -u REPO_DIR -u TELEGRAM_STATE_DIR -u KICKOFF_CORE_DIR -u MC_STATE_FILE \
        -u MEMORY_INDEX -u MEMORY_DIR -u CHANNEL_SPEC \
        timeout 90 bash "$KO" up --dir "$TARGET" --dry-run 2>&1)"
case "$out" in
  *"$TARGET"*) ok "BEHAVIOURAL: \`up --dir <repo>\` targets that repo (the flag is honoured, not just parsed)" ;;
  *"REPO_DIR is unset"*) bad "BEHAVIOURAL: \`up --dir <repo>\` still says 'REPO_DIR is unset ... pass --dir' — the exact bug" ;;
  *) bad "BEHAVIOURAL: \`up --dir <repo>\` did not name the target repo:
       $(printf '%s' "$out" | tail -2)" ;;
esac

# ── 3b. THE SHAPE THAT ACTUALLY FAILS: the front door running from a DETACHED core ──────────────
# Case 3 passes against the dev checkout — which sits on a BRANCH, so the pure-pull guard never
# fires and --dir is never really tested. A real adopter runs the PINNED front door, which is a
# DETACHED core: there the guard kills the process ~3800 lines before any verb parses argv, and
# tells the user to "pass --dir" — which they did. That is the exact bug, and this suite MISSED it
# locally while the release gate caught it on a detached candidate tree. Reproduce the real shape.
DCORE="$T/core"
if git -C "$HERE/.." rev-parse --git-dir >/dev/null 2>&1 \
   && git -C "$HERE/.." worktree add -q --detach "$DCORE" HEAD 2>/dev/null; then
  cp "$KO" "$DCORE/scripts/kickoff" 2>/dev/null
  out_d="$(cd /tmp && env -u REPO_DIR -u TELEGRAM_STATE_DIR -u KICKOFF_CORE_DIR -u MC_STATE_FILE \
            -u MEMORY_INDEX -u MEMORY_DIR -u CHANNEL_SPEC \
            timeout 90 bash "$DCORE/scripts/kickoff" up --dir "$TARGET" --dry-run 2>&1)"
  case "$out_d" in
    *"REPO_DIR is unset"*)
      bad "DETACHED CORE: --dir is killed by the pure-pull guard before any verb reads it — the exact bug (it tells you to pass the flag you passed)" ;;
    *"$TARGET"*)
      ok "DETACHED CORE: --dir survives the pure-pull guard (the real adopter shape)" ;;
    *)
      bad "DETACHED CORE: could not tell — output named neither:
       $(printf '%s' "$out_d" | tail -2)" ;;
  esac
  git -C "$HERE/.." worktree remove --force "$DCORE" >/dev/null 2>&1
else
  printf '  … skipped the detached-core lane (no git worktree) — the REAL shape is UNPROVEN here\n'
fi

# ── 4. a bad --dir must fail CLOSED, never fall back to a silent default ─────────────────────────
out2="$(cd "$T" && env -u REPO_DIR -u KICKOFF_CORE_DIR timeout 60 bash "$KO" up --dir "$T/does-not-exist" --dry-run 2>&1)"; rc2=$?
[ "$rc2" -ne 0 ] && ok "a nonexistent --dir fails closed (never silently targets something else)" \
                 || bad "a nonexistent --dir was accepted (rc=0) — it would target a fallback repo"

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && printf '  ✅ --dir is honoured by every verb that advertises it\n'
[ "$FAIL" -eq 0 ]
