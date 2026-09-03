#!/usr/bin/env bash
# up-dir-config-selftest.sh — `kickoff up --dir` must not inherit the CALLER's launch config.
#
#   bash scripts/up-dir-config-selftest.sh
#
# THE BUG: cmd_up binds effort/model/cadence/auto_pickup from the ambient env, and the top-level
# instance.env import reads whatever INSTANCE_ENV resolves to — the CALLER org's file when
# INSTANCE_ENV rides in ambient (it does across the pty-wrap/hop topology). `--dir <target>`
# re-points REPO_DIR but never re-resolves those four launch vars, so the caller org's values land
# in `envs+=` as PRE-SET names — which BEAT the target org's own instance.env downstream
# (session-run.sh's preset-wins import). The caller org's effort pin and auto-pickup arm silently
# launch ANOTHER org's worker.
#
# REQUIRED PRECEDENCE:  argv flag > true pre-set terminal env > TARGET org's instance.env.
# Names the launcher sourced from the CALLER's file are FILE values, not pre-sets — they must be
# re-resolved from the TARGET's file, or fall back to the engine default when the target sets
# nothing. The blessed form `REPO_DIR=<target> kickoff up` (REPO_DIR resolves before the load)
# must keep behaving exactly as today.
#
# The proof surface is the REAL `kickoff up --dir <target> --dry-run` output: start-supervisor.sh
# prints the launch plan (repo · cadence · effort/model/auto-pickup · permission-mode) from the
# env it was actually handed — what WOULD launch. Like auto-pickup-selftest.sh, the caller's
# ambient env is SCRUBBED first: a live kickoff worker exports AUTO_PICKUP/EFFORT into everything
# it spawns, and a suite that inherits the box's config tests the box instead of the code.
set -uo pipefail
unset AUTO_PICKUP AUTO_PICKUP_MAX_RESTARTS AUTO_PICKUP_WINDOW EFFORT MODEL CADENCE \
      MAX_SESSION_SECONDS INSTANCE_ENV REPO_DIR TELEGRAM_STATE_DIR KICKOFF_CORE_DIR
HERE="$(cd "$(dirname "$0")" && pwd)"
KO="$HERE/kickoff"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

F="$(mktemp -d)"; trap 'rm -rf "$F"' EXIT
CALLER="$F/orgA"; TARGET="$F/orgB"; TARGET_NOFILE="$F/orgC"
mkdir -p "$CALLER/.kickoff" "$TARGET/.kickoff" "$TARGET_NOFILE/.kickoff"
printf 'export EFFORT="xhigh"\nexport AUTO_PICKUP="1"\n' > "$CALLER/.kickoff/instance.env"
printf 'export EFFORT="low"\n' > "$TARGET/.kickoff/instance.env"

up_dry() {  # org [more kickoff args…] — the caller-org ambient comes from the caller's env
  local org="$1"; shift
  timeout 60 bash "$KO" up --dir "$org" --dry-run "$@" 2>&1
}
launch_line() { printf '%s\n' "$1" | grep -E '^[[:space:]]*launch:' | tail -n1; }

# ══ 1. THE CROSS-ORG LEAK — a caller-org instance.env must not arm/ pin the TARGET's launch ═══
# INSTANCE_ENV rides in ambient (the pty-wrap/hop topology), pointing at the CALLER org's file;
# --dir names a DIFFERENT org whose own file pins EFFORT=low and says nothing about auto-pickup.
out="$(INSTANCE_ENV="$CALLER/.kickoff/instance.env" up_dry "$TARGET")"
chk "(1) the launch plan names the TARGET repo (--dir really redirected)" \
  "printf '%s' \"\$out\" | grep -q \"repo:.*$TARGET\""
chk "(1) launch effort comes from the TARGET's file (low), not the CALLER's (xhigh)" \
  "launch_line \"\$out\" | grep -q 'effort=low'"
chk "(1) auto-pickup is NOT armed from the CALLER org's file (prints 0 = off)" \
  "launch_line \"\$out\" | grep -q 'auto-pickup=0'"

# ══ 1b. CALLER FILE VALUE + TARGET SETS NOTHING → the caller value must not survive either ═══
# A file-sourced value is not a pre-set: with no target-file line it falls back to the engine
# default, never silently carries org A's policy into org B.
out="$(INSTANCE_ENV="$CALLER/.kickoff/instance.env" up_dry "$TARGET_NOFILE")"
chk "(1b) no target-file EFFORT → the caller's pin falls back to the engine default (high)" \
  "launch_line \"\$out\" | grep -q 'effort=high'"
chk "(1b) …and auto-pickup still not armed from the caller" \
  "launch_line \"\$out\" | grep -q 'auto-pickup=0'"

# ══ 2. ARGV BEATS BOTH FILES — an explicit --effort max wins over caller and target alike ════
out="$(INSTANCE_ENV="$CALLER/.kickoff/instance.env" up_dry "$TARGET" --effort max)"
chk "(2) explicit --effort max argv beats both instance.env files" \
  "launch_line \"\$out\" | grep -q 'effort=max'"

# ══ 3. THE BLESSED FORM IS UNCHANGED — `REPO_DIR=<target> kickoff up` honors the target file ══
out="$(REPO_DIR="$TARGET" timeout 60 bash "$KO" up --dry-run 2>&1)"
chk "(3) blessed form: the target repo's own EFFORT=low still launches" \
  "launch_line \"\$out\" | grep -q 'effort=low'"
chk "(3) blessed form: no ambient caller file, nothing arms auto-pickup" \
  "launch_line \"\$out\" | grep -q 'auto-pickup=0'"

# ══ 4. PLAIN `--dir` WITH NO CALLER CONFIG — byte-neutral: the target file still wins ═════════
out="$(up_dry "$TARGET")"
chk "(4) plain --dir, clean env: the target's EFFORT=low is honored (no regression)" \
  "launch_line \"\$out\" | grep -q 'effort=low'"

# ══ 5. THE KEEP-LIST CLASS — a file-sourced name must never leak through the child env ════════
# build_worker_env keeps KEEP-listed EXPORTED GLOBALS into the child (compgen -e), and envs[]
# carries MODEL only when non-empty — so a caller-file MODEL that re-resolves to EMPTY must have
# its global NEUTRALIZED, or the caller's model launches the target org's worker (the D1 repro:
# launch printed `model=caller-model` while effort was already correctly the target's).
CALLER_M="$F/orgA-m"; TARGET_M="$F/orgB-m"; TARGET_SP="$F/orgB-sp"; TARGET_CAD="$F/orgB-cad"
mkdir -p "$CALLER_M/.kickoff" "$TARGET_M/.kickoff" "$TARGET_SP/.kickoff" "$TARGET_CAD/.kickoff"
printf 'export EFFORT="xhigh"\nexport AUTO_PICKUP="1"\nexport CADENCE="999"\nexport MODEL="caller-model"\n' > "$CALLER_M/.kickoff/instance.env"
printf 'export EFFORT="low"\nexport MODEL="tgt-model"\n' > "$TARGET_M/.kickoff/instance.env"
printf 'export EFFORT="low"\nexport MODEL="my model"\nexport AUTO_PICKUP=""\n' > "$TARGET_SP/.kickoff/instance.env"
printf 'export EFFORT="low"\nexport CADENCE="abc"\n' > "$TARGET_CAD/.kickoff/instance.env"

# (5a) THE D1 REPRO: caller file MODEL=caller-model, target sets NO MODEL.
out="$(INSTANCE_ENV="$CALLER_M/.kickoff/instance.env" up_dry "$TARGET")"
chk "(5a/D1) the caller's file-sourced MODEL does NOT reach the target's launch" \
  "! launch_line \"\$out\" | grep -q 'model=caller-model'"
chk "(5a/D1) no target MODEL ⇒ the launch stays <box inherit> (UNSET — never the caller's, never empty)" \
  "launch_line \"\$out\" | grep -q 'model=<box inherit>'"

# (5b) target-file MODEL beats the caller's file MODEL.
out="$(INSTANCE_ENV="$CALLER_M/.kickoff/instance.env" up_dry "$TARGET_M")"
chk "(5b) target-file MODEL=tgt-model wins over the caller's MODEL" \
  "launch_line \"\$out\" | grep -q 'model=tgt-model'"

# (5c) %q round-trip: _target_launch_config emits name=<%q value>; a raw `${line#*=}` assignment
# turned `my model` into `my\ model` (literal backslash) and "" into literal quotes.
out="$(INSTANCE_ENV="$CALLER_M/.kickoff/instance.env" up_dry "$TARGET_SP")"
chk "(5c) a space-bearing target value round-trips INTACT (no literal backslash)" \
  "launch_line \"\$out\" | grep -q 'model=my model'"
chk "(5c) an empty %q target value round-trips as EMPTY (unarmed), not literal quotes" \
  "launch_line \"\$out\" | grep -q 'auto-pickup=0'"

# (5d) a non-numeric target-file CADENCE fails LOUD — the re-resolved value must pass the SAME
# digit validation as argv CADENCE (it used to be assigned after the check, bypassing it).
out_cad="$(INSTANCE_ENV="$CALLER_M/.kickoff/instance.env" timeout 60 bash "$KO" up --dir "$TARGET_CAD" --dry-run 2>&1)"; rc_cad=$?
chk "(5d) non-numeric target-file CADENCE fails loud with the existing --cadence message" \
  "[ \"$rc_cad\" -ne 0 ] && printf '%s' \"\$out_cad\" | grep -q -- '--cadence must be a non-negative integer'"

echo
echo "──────────────────────────────"
echo "  $PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
  echo "  ✅ --dir launches the TARGET org's config: argv > true pre-set env > target's instance.env"
  exit 0
fi
echo "  ❌ see failures above"; exit 1
