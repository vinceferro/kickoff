#!/usr/bin/env bash
# start-supervisor.sh — the operator's ONE-TAP to turn on the session-refresh
# supervisor on a worker box. Idempotent: refuses to start a second one.
#
#   bash scripts/start-supervisor.sh                 # this repo, no cadence
#   REPO_DIR=~/my-project bash scripts/start-supervisor.sh
#   MAX_SESSION_SECONDS=7200 bash scripts/start-supervisor.sh   # + a 2h cadence
#
# Verify the LOGIC first, without launching/killing anything real:
#   DRY_RUN=1 bash scripts/start-supervisor.sh
#
# To stop it later:  send SIGTERM to the pid this prints, or:
#   kill -TERM "$(cat "$REPO_DIR/.kickoff/supervisor.lock")"
#
# The Telegram /refresh path needs no script — the agent just touches the flag:
#   touch "$REPO_DIR/.kickoff/refresh-requested"

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$HERE/.." && pwd)}"

echo "▶ starting the session-refresh supervisor"
echo "    repo:    $REPO_DIR"
echo "    cadence: ${MAX_SESSION_SECONDS:-0}s (0 = none)"
echo "    dry_run: ${DRY_RUN:-0}"
echo "    permission-mode: ${PERMISSION_MODE:-default}   (← set PERMISSION_MODE=auto for the autonomous worker)"
echo
echo "  it watches:  $REPO_DIR/.kickoff/refresh-requested  (the flag — also the /refresh path)"
echo "  managed pid: $REPO_DIR/.kickoff/supervisor.session.pid"
echo "  stop with:   kill -TERM \$(cat $REPO_DIR/.kickoff/supervisor.lock)"
echo

# Launch-control flags (PREFLIGHT_SKIP, DRY_RUN) are honored ONLY from this invocation's
# real pre-set env / argv — NEVER forged from instance.env. This script never sources
# instance.env (the file-injection defense lives at kickoff's exec boundary + session-run's
# subshell import), so here we make the boundary explicit + consistent: `env -u` strips any
# copy from the exec env, then we re-inject ONLY what was genuinely pre-set. This preserves
# the documented `DRY_RUN=1 bash …` dry-run and the `PREFLIGHT_SKIP=1 bash …` emergency
# bypass, while nothing can ride a forged value into the supervisor's launch-control here.
launch_env=( -u PREFLIGHT_SKIP -u DRY_RUN "REPO_DIR=$REPO_DIR" )
if [ -n "${DRY_RUN:-}" ];        then launch_env+=( "DRY_RUN=$DRY_RUN" ); fi
if [ -n "${PREFLIGHT_SKIP:-}" ]; then launch_env+=( "PREFLIGHT_SKIP=$PREFLIGHT_SKIP" ); fi
exec env "${launch_env[@]}" bash "$HERE/supervisor.sh"
