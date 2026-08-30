#!/usr/bin/env bash
# lane-dispatch.sh — spawn a background work-lane: worktree + session + graph node.
#
#   REPO_DIR=/path/to/your-org scripts/lane-dispatch.sh <agent> <task-file|--text> [deps]
#
#   <agent>   crew member who owns the work (builder, planner, reviewer, or grown specialist)
#   <task>    path to a task file, or "-Text" for inline text
#   [deps]    comma-separated lane ids this lane waits on (recorded in the graph;
#             scheduling honor is the coordinator's job — the ledger only records truth)
#
# WHAT YOU GET:
#   · a git worktree at ~/kickoff-worktrees/<org-slug>/lane-<id> on branch lane/<id>
#     (parallel lanes never collide in one working tree; merges happen when green)
#   · an opencode background session bound to that worktree, seeded with the crew
#     agent's charter discipline and the task
#   · a node appended to <repo>/.kickoff/graph.json — the dependency graph the
#     coordinator is the entry point to
#
# The operator's chat stays free. Nothing watches the lane automatically — start
# `scripts/lane-runner.sh <lane-id>` yourself (it polls the session for LANE-COMPLETE
# in assistant text, then VERIFIES the claim by running the lane's proof itself,
# adapts on provider errors, nudges once on silence) or drive a whole dependency
# graph with `scripts/graph-executor.sh`. `scripts/lane-status.sh` shows the lane;
# integration = merging the lane branch.
#
# COMPLETION IS MACHINE-DERIVED: dispatch with PROOF_CMD='<shell command proving the
# work>' and the runner executes it in the lane worktree after the sentinel —
# pass → done, fail → proof-failed, none declared → unverified (never done).

set -euo pipefail

REPO_DIR="${REPO_DIR:?REPO_DIR required}"
AGENT="${1:?usage: lane-dispatch.sh <agent> <task-file|-Text> [deps]}"
TASK_ARG="${2:?usage: lane-dispatch.sh <agent> <task-file|-Text> [deps]}"
DEPS="${3:-}"

PORT_FILE="$REPO_DIR/.kickoff/opencode-bridge.port"
[ -s "$PORT_FILE" ] || { echo "FATAL: no bridge port at $PORT_FILE" >&2; exit 1; }
PORT="$(head -1 "$PORT_FILE")"

SLUG="$(basename "$REPO_DIR" | tr '[:upper:]' '[:lower:]')"
LANE_ID="lane-$(date +%m%d-%H%M%S)-$$"
WT_ROOT="${KICKOFF_LANES_ROOT:-$HOME/kickoff-worktrees}/$SLUG"
WT="$WT_ROOT/$LANE_ID"
BRANCH="lane/$(basename "$REPO_DIR")-$LANE_ID"

# ── worktree: isolation by construction ──────────────────────────────────────
mkdir -p "$WT_ROOT"
git -C "$REPO_DIR" worktree add -b "$BRANCH" "$WT" HEAD >/dev/null 2>&1 || {
  # fall back: branch may exist from a retried id
  git -C "$REPO_DIR" worktree add "$WT" "$BRANCH" >/dev/null 2>&1 || {
    echo "FATAL: could not create worktree $WT" >&2; exit 1; }
}

# ── task materialization ─────────────────────────────────────────────────────
TASK_FILE="$WT/.kickoff/LANE-TASK.md"
mkdir -p "$(dirname "$TASK_FILE")"
if [ "${TASK_ARG#-}" != "$TASK_ARG" ] && [ -n "${TASK_ARG#-}" ]; then
  printf '%s\n' "${TASK_ARG#-}" > "$TASK_FILE"
elif [ -f "$TASK_ARG" ]; then
  cp "$TASK_ARG" "$TASK_FILE"
else
  echo "FATAL: task arg is neither -Text nor an existing file: $TASK_ARG" >&2
  git -C "$REPO_DIR" worktree remove --force "$WT" 2>/dev/null || true
  exit 1
fi

# ── session: bound to the worktree, seeded with charter + task ───────────────
SESSION_JSON=$(curl -s --max-time 10 -H "x-opencode-directory:$WT" \
  -X POST "http://127.0.0.1:$PORT/session" \
  -H 'Content-Type: application/json' \
  -d "{\"title\":\"lane $LANE_ID [$AGENT]\",\"directory\":\"$WT\"}")
SID=$(echo "$SESSION_JSON" | jq -r '.id // empty')
if [ -z "$SID" ]; then
  echo "FATAL: session create failed: $(echo "$SESSION_JSON" | head -c 150)" >&2
  git -C "$REPO_DIR" worktree remove --force "$WT" 2>/dev/null || true
  exit 1
fi

EFFORT="${EFFORT:-}"
MODEL="${MODEL:-}"                # lane model override: "provider/model" — bypasses the
                                  # repo opencode.json pin, which can name a provider this
                                  # box has no credentials for (silent first-turn wedge,
                                  # the second box, 2026-08-28). Leave empty to inherit the pin.
PROOF_CMD="${PROOF_CMD:-}"              # executor-run proof: '<cmd>' → done only if it passes
PROMPT="You are the [$AGENT] specialist executing BACKGROUND LANE $LANE_ID.
Worktree: $WT (branch $BRANCH). Commit your work to this branch as you go.
Your task brief is at .kickoff/LANE-TASK.md — read it first, then execute.
Rules: reversible work autonomously; gated work (push/spend/credentials) STOP and note it
in your final message instead."
if [ -n "$PROOF_CMD" ]; then
  PROMPT+="
Completion is VERIFIED, not self-reported: when you end with LANE-COMPLETE the lane
executor itself runs this proof in your worktree — $PROOF_CMD — and only a passing
proof marks the lane done."
else
  PROMPT+="
No proof was declared for this lane: your LANE-COMPLETE will be recorded as
CLAIMED/unverified — never done. Tell the coordinator to dispatch with PROOF_CMD set."
fi
PROMPT+="
End your run with LANE-COMPLETE plus a 5-line summary."

PAYLOAD=$(jq -n --arg s "$SID" --arg d "$WT" --arg p "$PROMPT" --arg v "$EFFORT" --arg m "$MODEL" '
  {sessionID:$s, directory:$d, parts:[{type:"text",text:$p}]}
  | (if $v != "" then . + {variant:$v} else . end)
  | (if $m != "" then . + {model: {providerID: ($m|split("/"))[0], modelID: ($m|split("/"))[1]}} else . end)')
curl -s --max-time 15 -H "x-opencode-directory:$WT" \
  -X POST "http://127.0.0.1:$PORT/session/$SID/prompt_async" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD" -o /dev/null -w "" || true

# ── graph node ───────────────────────────────────────────────────────────────
GRAPH="$REPO_DIR/.kickoff/graph.json"
EFFORT="${EFFORT:-}"
python3 - "$GRAPH" "$EFFORT" <<EOF
import json, sys, time
graph_path = sys.argv[1]
try:
    g = json.load(open(graph_path))
    if not isinstance(g, dict): raise ValueError
except Exception:
    g = {"lanes": []}
g.setdefault("lanes", []).append({
    "id": "$LANE_ID", "agent": "$AGENT", "status": "running",
    "deps": [d for d in """$DEPS""".split(",") if d],
    "worktree": "$WT", "branch": "$BRANCH",
    "session": "$SID", "port": "$PORT",
    "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "effort": """${EFFORT}""" or None,
    "model": """${MODEL}""" or None,
    "proof": """${PROOF_CMD}""" or None,
})
json.dump(g, open(graph_path, "w"), indent=1)
EOF

# ── self-start: dispatch is ONE step ─────────────────────────────────────────
# The runner is the CONSUMER of the lane — omitting it (2026-08-28, twice) leaves a
# dispatched lane unwatched forever. Spawn it here, detached, idempotently (a live
# runner for this lane is never double-started). LANE_AUTOSTART=0 disables (tests).
if [ "${LANE_AUTOSTART:-1}" = "1" ] && bash -c "exec 3<>/dev/tcp/127.0.0.1/${PORT}" 2>/dev/null; then
  existing_pid="$(jq -r --arg id "$LANE_ID" '.lanes[] | select(.id==$id) | .runner_pid // 0' "$GRAPH" 2>/dev/null)"
  if [ "$existing_pid" != "0" ] && [ -n "$existing_pid" ] && [ -d "/proc/$existing_pid" ]; then
    echo "  runner:   pid $existing_pid already alive — not double-started"
  else
    RUNNER_LOG="$REPO_DIR/.kickoff/lane-runner-$LANE_ID.log"
    HERE_D="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
    setsid nohup env REPO_DIR="$REPO_DIR" bash "$HERE_D/lane-runner.sh" "$LANE_ID" >"$RUNNER_LOG" 2>&1 &
    RUNNER_PID=$!
    python3 - "$GRAPH" "$LANE_ID" "$RUNNER_PID" <<'EOF'
import json, sys
gp, lid, pid = sys.argv[1], sys.argv[2], sys.argv[3]
g = json.load(open(gp))
for l in g["lanes"]:
    if l["id"] == lid: l["runner_pid"] = int(pid)
json.dump(g, open(gp, "w"), indent=1)
EOF
    echo "  runner:   pid $RUNNER_PID (self-started; log $RUNNER_LOG)"
  fi
else
  echo "  runner:   NOT started (LANE_AUTOSTART=0 or no serve on :$PORT) — start manually:"
  echo "            REPO_DIR=$REPO_DIR bash scripts/lane-runner.sh $LANE_ID &"
fi

echo "LANE $LANE_ID"
echo "  agent:    $AGENT"
echo "  worktree: $WT"
echo "  branch:   $BRANCH"
echo "  session:  $SID"
echo "  deps:     ${DEPS:-none}"
echo "  effort:   ${EFFORT:-default}"
echo "  model:    ${MODEL:-repo pin (opencode.json default)}"
echo "  proof:    ${PROOF_CMD:-none — completion will land unverified, never done}"
echo "  graph:    $GRAPH"
