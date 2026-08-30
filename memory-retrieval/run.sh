#!/usr/bin/env bash
# run.sh — thin wrapper that passes Node's --experimental-sqlite flag so you
# don't have to remember it. node:sqlite is experimental in Node 22.
#
#   ./run.sh index                 # (re)build the index from the memory files
#   ./run.sh retrieve "<query>"    # hybrid retrieval
#   ./run.sh demo                  # the motivating demo (chrome-principle + more)
#   ./run.sh hook "<query>"        # the proactive hook (prints the injection block)
#   ./run.sh eval                  # the metrics/eval harness (recall@K + MRR)
#   ./run.sh refresh-metrics       # re-derive metrics.json on the LIVE corpus + board card
#   ./run.sh metrics-status        # is metrics.json current? FRESH / STALE (+ the fix)
#   ./run.sh log-stats             # summarize the live retrieval log
#   ./run.sh install-model         # (re)install the semantic model → pull-durable cache
set -euo pipefail
cd "$(dirname "$0")"

cmd="${1:-}"; shift || true
case "$cmd" in
  index)          exec node --experimental-sqlite index.mjs "$@" ;;
  retrieve)       exec node --experimental-sqlite retrieve.mjs "$@" ;;
  demo)           exec node --experimental-sqlite demo.mjs "$@" ;;
  hook)           exec node --experimental-sqlite hook.mjs "$@" ;;
  eval)           exec node --experimental-sqlite eval.mjs "$@" ;;
  refresh-metrics) exec env NODE_NO_WARNINGS=1 node --experimental-sqlite refresh-metrics.mjs "$@" ;;
  metrics-status) exec env NODE_NO_WARNINGS=1 node --experimental-sqlite refresh-metrics.mjs status "$@" ;;
  log-stats)      exec node --experimental-sqlite log-stats.mjs "$@" ;;
  install-model)  exec node --experimental-sqlite install-model.mjs "$@" ;;
  *) echo "usage: ./run.sh {index|retrieve|demo|hook|eval|refresh-metrics|metrics-status|log-stats|install-model} [args]"; exit 1 ;;
esac
