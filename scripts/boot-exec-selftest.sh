#!/usr/bin/env bash
# boot-exec-selftest.sh — the telegram-bot launcher must EXEC, not just parse: catches a
# dist sync stripping the exec bit from the installed entrypoint's TARGET.
#
#   bash scripts/boot-exec-selftest.sh
#   BOT_BIN=/tmp/fixture/opencode-telegram bash scripts/boot-exec-selftest.sh   # fixture override
#
# The bug class (2026-08-26 fleet incident): a dist sync left
#   ~/.local/bin/opencode-telegram -> ../lib/node_modules/@grinev/opencode-telegram-bot/dist/cli.js
# with the TARGET at mode 664. Every FUTURE session boot died "Permission denied" while
# already-running bots kept serving — the outage was invisible until the next restart.
# No gate caught it because every existing check READS the file (`node <file>`, cmp, grep)
# and `node <file>` BYPASSES the exec bit; only the kernel's execve path enforces it.
#
# What this lane proves, in order:
#   1. the launcher resolves (BOT_BIN override, else `command -v opencode-telegram`);
#      absent → loud SKIP + exit 0 — a box without the bot is not a red.
#   2. the symlink is followed (readlink -f) and owner-exec is asserted on the TARGET
#      (stat -c %A) — never on the link itself, whose mode is always lrwxrwxrwx and
#      would make the check vacuous.
#   3. the entrypoint is EXEC-LAUNCHED via the launcher path itself (not via `node`):
#      `<bin> --help` — the argv parser (dist/cli/args.js:47) prints usage and exits 0
#      before any bot machinery is imported, so it can never start or signal a bot.
#      `start` (and bare invocation, which DEFAULTS to start, cli.js:181) is NEVER run.
#   4. negative control: a /tmp COPY of the real cli.js at mode 664 behind a fake
#      symlink must turn this whole lane RED with the incident's exact shape
#      ("Permission denied" from the exec probe). The control never chmods or execs
#      the LIVE install — it copies, breaks the copy, and asserts the live modes
#      survived untouched.
#
# RED-first proven 2026-08-26: the control below was watched go RED on the fixture
# before the lane was registered in lefthook.yml.
#
# Set -e is deliberately NOT used: we aggregate failures and report once (mirrors
# check-bot-patch-drift.sh:15 and check-bot-imports-selftest.sh:30).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }

BIN="${BOT_BIN:-}"
[[ -n "$BIN" ]] || BIN="$(command -v opencode-telegram || true)"
if [[ -z "$BIN" ]]; then
  echo "⏭️  SKIP boot-exec self-test — no opencode-telegram launcher on PATH (set BOT_BIN to point at one); nothing to guard"
  exit 0
fi

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

echo "▶ boot-exec self-test (the launcher must EXEC — a lost exec bit deafens future boots)"
echo

# ── 1 · resolution: launcher present, symlink followed to a real file ─────────
echo "── resolution ──"
ok "launcher present: $BIN"
TARGET="$(readlink -f "$BIN" 2>/dev/null || true)"
if [[ -n "$TARGET" && -f "$TARGET" ]]; then
  if [[ -L "$BIN" ]]; then
    ok "symlink resolves to a real entrypoint: $BIN → $TARGET (mode on the LINK is always 777 — the assert below is on the target)"
  else
    ok "not a symlink — the launcher IS the file: $TARGET"
  fi
else
  TARGET=""
  bad "launcher does not resolve to a regular file: $BIN (readlink -f → '${TARGET:-<nothing}')"
fi

# ── 2 · the incident class: owner-exec on the RESOLVED TARGET ─────────────────
echo "── owner-exec on the resolved target (2026-08-26 incident class) ──"
PERMS=""
if [[ -n "$TARGET" ]]; then
  PERMS="$(stat -c %A "$TARGET" 2>/dev/null || true)"
fi
if [[ -n "$PERMS" && "${PERMS:1:3}" == *x* ]]; then
  ok "resolved target carries the owner-exec bit: $TARGET ($PERMS)"
else
  bad "exec bit MISSING on resolved target — link: $BIN → target: $TARGET (${PERMS:-unstatable}). Future boots die 'Permission denied' while already-running bots keep serving (2026-08-26 incident class); fix: chmod u+x '$TARGET'"
fi

# ── 3 · the real thing: EXEC-LAUNCH via the launcher path itself ──────────────
# NOT via `node <file>` — that bypasses the exec bit, which is the whole point.
# Probe order is read from the shipped CLI's own source: `--help`/-h is honoured by
# the argv parser and exits 0 printing usage; `--version` is NOT a known flag, exits 2
# with usage — either shape proves node ran the real parser. rc 126/127 = the exec
# itself was denied/failed (the incident's shape); rc 124 = hung argv, try the next.
echo "── exec-launch through the launcher path (never via \`node\`) ──"
FOUND_ARGV=""; FOUND_RC=""; DENIED_ERR=""
if [[ -n "$TARGET" ]]; then
  for argv in --help --version; do
    OUT="$(timeout 10 "$BIN" "$argv" 2>"$W/exec.err")"; RC=$?
    ERR="$(<"$W/exec.err")"
    if [[ $RC -eq 126 || $RC -eq 127 ]]; then
      DENIED_ERR="$(printf 'exec of `%s %s` failed rc=%d: %s' "$BIN" "$argv" "$RC" "$ERR")"
      break
    fi
    if [[ $RC -eq 124 ]]; then continue; fi
    if [[ $RC -eq 0 || ( $RC -eq 2 && "$(printf '%s' "$OUT" | grep -c 'Usage')" -gt 0 ) ]] \
       && [[ "$(printf '%s' "$OUT" | grep -c 'Usage')" -gt 0 ]]; then
      FOUND_ARGV="$argv"; FOUND_RC="$RC"; break
    fi
  done
fi
if [[ -n "$FOUND_ARGV" ]]; then
  ok "EXEC via the launcher path worked: \`$BIN $FOUND_ARGV\` → rc $FOUND_RC, usage printed (kernel execve + shebang + node all exercised)"
elif [[ -n "$DENIED_ERR" ]]; then
  bad "EXEC DENIED on the launcher path — $DENIED_ERR — this is the 2026-08-26 incident's exact runtime shape: future boots cannot start"
else
  # Fallback of last resort: no argv that safely fast-exits. Assert the bit by test -x
  # on BOTH the link resolution and the target, with a LOUD note that no real exec ran.
  printf '  ⚠ NOTE: no safe fast-exit argv found for this CLI — exec-bit proven by test -x only, the execve path was NOT exercised\n'
  if [[ -n "$TARGET" && -x "$BIN" && -x "$TARGET" ]]; then
    ok "fallback: link resolution AND target both pass test -x (see NOTE above — weaker than a real exec)"
  else
    bad "fallback test -x failed: launcher='$BIN' target='$TARGET' — launcher exec? $([[ -x "$BIN" ]] && echo yes || echo NO), target exec? $([[ -x "$TARGET" ]] && echo yes || echo NO)"
  fi
fi

# ── 4 · negative control: re-break a COPY, the whole lane must go RED ─────────
# The live install is only ever READ (cp). The copy is what gets chmod 664'd and
# exec'd; the live target's mode is asserted unchanged afterwards. Guarded by
# BOOT_EXEC_NO_CONTROL so the self-invocation below cannot recurse.
if [[ -z "${BOOT_EXEC_NO_CONTROL:-}" && -n "$TARGET" && -f "$TARGET" ]]; then
  echo "── negative control: a 664 COPY must go RED with the incident's shape ──"
  FX="$W/fx"; mkdir -p "$FX"
  cp "$TARGET" "$FX/cli-copy.js"
  chmod 664 "$FX/cli-copy.js"
  ln -s cli-copy.js "$FX/opencode-telegram"
  FX_PERMS="$(stat -c %A "$FX/cli-copy.js")"
  if [[ "${FX_PERMS:1:3}" != *x* ]]; then
    ok "fixture is SHARP: copy of the real entrypoint sits at $FX_PERMS behind a symlink (never touched the live install)"
  else
    bad "fixture broken — chmod 664 did not stick ($FX_PERMS); cannot construct the RED control"
  fi
  LIVE_PERMS_BEFORE="$(stat -c %A "$TARGET" 2>/dev/null || true)"
  BOOT_EXEC_NO_CONTROL=1 BOT_BIN="$FX/opencode-telegram" bash "$HERE/boot-exec-selftest.sh" >"$W/ctl.out" 2>&1
  CTL_RC=$?
  if [[ $CTL_RC -ne 0 ]] && grep -qF "$FX/opencode-telegram" "$W/ctl.out" && grep -qF "$FX/cli-copy.js" "$W/ctl.out"; then
    ok "RED-on-copy: nested lane exits $CTL_RC naming BOTH paths (link + resolved target)"
  else
    bad "control did not bite — nested rc=$CTL_RC; output: $(tr '\n' ';' <"$W/ctl.out" | cut -c1-300)"
  fi
  if grep -qi 'permission denied' "$W/ctl.out"; then
    ok "incident shape reproduced: the nested run carries the 'Permission denied' exec failure"
  else
    bad "control lost the incident's runtime shape — no Permission-denied text in the nested run"
  fi
  LIVE_PERMS_AFTER="$(stat -c %A "$TARGET" 2>/dev/null || true)"
  if [[ -n "$LIVE_PERMS_BEFORE" && "$LIVE_PERMS_BEFORE" == "$LIVE_PERMS_AFTER" ]]; then
    ok "LIVE install untouched by the control (mode $LIVE_PERMS_BEFORE before == after)"
  else
    bad "control touched the live target's modes?! before='$LIVE_PERMS_BEFORE' after='$LIVE_PERMS_AFTER'"
  fi
fi

# ── verdict ───────────────────────────────────────────────────────────────────
echo
echo "──────────────────────────────"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && echo "  ✅ the launcher execs end-to-end — a stripped exec bit would go RED here" \
                   || echo "  ❌ boot-exec FAILED — future boots of this bot will hit the exec wall"
exit $(( FAIL > 0 ? 1 : 0 ))
