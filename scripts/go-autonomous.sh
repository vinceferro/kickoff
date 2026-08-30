#!/usr/bin/env bash
# go-autonomous.sh — DEPRECATION SHIM (one version only; DELETED in v0.8).
#
# v0.7 G1 §2.2: `kickoff up` is the ONLY start surface. Everything this script used
# to own — the detached launch (setsid/nohup), the supervisor-log wiring + size-based
# rotation, the env contract — lives in cmd_up now:
#
#   bash scripts/go-autonomous.sh   ==   kickoff up --auto --detach
#
# The trust posture is unchanged: --auto stays an at-the-terminal grant (argv-only,
# printed loudly by cmd_up — a channel message can never flip it), and it is
# GRANT-ONLY (no effort/model stomp; EFFORT/MODEL pre-set in THIS shell still ride
# along under the one precedence rule: argv > pre-set env > instance.env > engine
# default). REPO_DIR=<your repo> works exactly as before. Need to cycle a running
# worker too? That is `kickoff up --auto --detach --replace`.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
echo "⚠ DEPRECATED: go-autonomous.sh is now a one-version shim — use \`kickoff up --auto --detach\` (this file is REMOVED in v0.8)." >&2
exec bash "$HERE/kickoff" up --auto --detach
