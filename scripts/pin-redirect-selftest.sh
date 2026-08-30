#!/usr/bin/env bash
# pin-redirect-selftest.sh — a repo's PIN is authoritative: every verb that acts on an adopted repo
# must run the engine the pin names, not whichever front door happens to be on PATH.
#
#   bash scripts/pin-redirect-selftest.sh
#
# The bug (2026-07-16, a live adoption — found by the operator doing something nobody had done):
# he ran `kickoff pull core-v0.13 --dir ~/their-repo`, which worked perfectly — core.lock and instance.env
# both moved to v0.13. Then `kickoff adopt --dir ~/their-repo` ran his STALE v0.12 front door, because
# cmd_up had a pin-redirect and cmd_adopt did NOT. Two different engines against one repo, silently:
# the v0.12 code wrote the bot token to a file nothing reads, so the channel stayed mute and the pin
# said something that was not true. "pull then re-adopt" is the obvious repair sequence, and it was
# a trap.
#
# The pin is the wrapper-killer (v0.7 G1 §2.2): ANY kickoff binary on the box must start the RIGHT
# engine. A verb that ignores it makes the whole pinning story a lie.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
KO="$HERE/kickoff"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
[ -r "$KO" ] || { printf '  ❌ scripts/kickoff not readable\n'; exit 1; }

# ── 1. structural: every repo-acting verb carries the redirect ───────────────────────────────────
for v in up adopt doctor; do
  A="$(grep -n "^cmd_${v}()" "$KO" | cut -d: -f1)"
  B="$(awk -v s="$A" 'NR>s && /^cmd_[a-z]+\(\)/ {print NR; exit}' "$KO")"; B="${B:-99999}"
  if sed -n "${A},${B}p" "$KO" | grep -q 'PIN-REDIRECT'; then
    ok "kickoff $v honours the repo's pin"
  else
    bad "kickoff $v has NO pin-redirect — it would run whichever front door is on PATH, not the pinned engine"
  fi
done

T="$(mktemp -d)"; trap 'git -C "$REPO" worktree remove --force "$T/engineA" >/dev/null 2>&1; git -C "$REPO" worktree remove --force "$T/engineB" >/dev/null 2>&1; rm -rf "$T"' EXIT
if ! git -C "$REPO" worktree add -q --detach "$T/engineA" HEAD 2>/dev/null \
   || ! git -C "$REPO" worktree add -q --detach "$T/engineB" HEAD 2>/dev/null; then
  printf '  … skipped the behavioural lanes (no git worktree) — the REAL shape is UNPROVEN here\n'
  printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; exit $?
fi
cp "$KO" "$T/engineA/scripts/kickoff"; cp "$KO" "$T/engineB/scripts/kickoff"

mkrepo() { mkdir -p "$1"; ( cd "$1" && git init -q . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m i ) 2>/dev/null; }
run_a() { ( cd /tmp && env -u REPO_DIR -u KICKOFF_CORE_DIR -u TELEGRAM_STATE_DIR -u MEMORY_INDEX \
             -u MC_STATE_FILE -u MEMORY_DIR -u CHANNEL_SPEC \
             timeout 90 bash "$T/engineA/scripts/kickoff" "$@" 2>&1 ); }

# ── 2. BEHAVIOURAL: pinned to engine B, invoked via front door A → must re-exec B ────────────────
R="$T/pinned"; mkrepo "$R"; mkdir -p "$R/.kickoff"
printf '{"tag":"core-vTEST"}\n' > "$R/.kickoff/core.lock"
printf 'export KICKOFF_CORE_DIR="%s"\n' "$T/engineB" > "$R/.kickoff/instance.env"
out="$(run_a adopt --dry-run --dir "$R")"
case "$out" in
  *pin-redirect*) ok "BEHAVIOURAL: adopt re-execs the PINNED engine, not the invoking front door" ;;
  *) bad "BEHAVIOURAL: adopt ran the stale front door against a pinned repo — pull-then-adopt runs two engines" ;;
esac

# doctor MUTATES (writes gates, builds the index) too — it must honour the pin exactly like adopt.
# The redirect fires at cmd_doctor's top, BEFORE its adopted-repo check, so R (pinned to B, no manifest)
# still proves it: engineA sees the pin and re-execs B's front door.
outd="$(run_a doctor --dir "$R")"
case "$outd" in
  *pin-redirect*) ok "BEHAVIOURAL: doctor re-execs the PINNED engine, not the invoking front door" ;;
  *) bad "BEHAVIOURAL: doctor ran the stale front door against a pinned repo — a repair with the WRONG engine's templates" ;;
esac

# ── 3. a FRESH repo must NOT redirect — adopt is what CREATES the pin ────────────────────────────
R2="$T/fresh"; mkrepo "$R2"
out2="$(run_a adopt --dry-run --dir "$R2")"
case "$out2" in
  *pin-redirect*) bad "a repo with NO core.lock was redirected — first adopt would break" ;;
  *) ok "no redirect on an unpinned repo (adopt creates the pin; the origin runs itself)" ;;
esac

# ── 4. a pin naming a BROKEN front door must die LOUD, never fall through to the wrong engine ────
R3="$T/broken"; mkrepo "$R3"; mkdir -p "$R3/.kickoff"
printf '{"tag":"core-vTEST"}\n' > "$R3/.kickoff/core.lock"
printf 'export KICKOFF_CORE_DIR="%s"\n' "$T/nonexistent-engine" > "$R3/.kickoff/instance.env"
out3="$(run_a adopt --dry-run --dir "$R3")"; rc3=$?
[ "$rc3" -ne 0 ] && ok "a pin naming a missing engine dies LOUD (never silently uses the wrong one)" \
                 || bad "a pin naming a missing engine fell through — it adopted with the WRONG engine"
case "$out3" in *"pinned"*) ok "the failure names the pin (the user can see what disagrees)" ;;
  *) bad "the failure does not explain the pin mismatch" ;; esac

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && printf '  ✅ the pin is authoritative for every repo-acting verb\n'
[ "$FAIL" -eq 0 ]
