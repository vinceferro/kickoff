#!/usr/bin/env bash
# graph-executor.sh — run a dependency graph of background lanes to completion.
#
#   GRAPH=/…/.kickoff/graphs/<name>.json REPO_DIR=/… setsid bash graph-executor.sh &
#
# Graph schema (JSON):
# {
#   "name": "docs-audit",
#   "nodes": [
#     {"id":"n1","agent":"planner","deps":[],"task":"audit README vs routes"},
#     {"id":"n2","agent":"builder","deps":["n1"],"task":"fix the worst finding",
#      "proof":"bash scripts/selftest.sh"}
#   ]
# }
#
# DONE IS MACHINE-DERIVED, NEVER SELF-REPORTED (output-truth audit leak #1): a node's
# NODE-COMPLETE only CLAIMS. This executor then runs the node's declared `proof`
# command itself, in the node's worktree — the agent never runs its own proof:
#   proof exits 0        → done          (deps of dependents satisfied)
#   proof exits non-zero → proof-failed  (🔴 notified with the proof's output)
#   no proof declared    → unverified    (⚠️ CLAIMED — never counts as done/green)
# Node states: pending → running → claimed → done | proof-failed | unverified;
#              failed (errors/stall), blocked (an upstream did not end done).
#
# The executor: dispatches nodes whose deps are all done (each in its own worktree +
# background session, effort-routed), injects upstream summaries into dependents,
# adapts on provider failures (max 3), cascades blocks on failure, and notifies the
# operator's Telegram at graph milestones. Exit when every node is terminal
# (done/failed/blocked/proof-failed/unverified).

set -uo pipefail

GRAPH_FILE="${GRAPH:?GRAPH required}"
REPO_DIR="${REPO_DIR:?REPO_DIR required}"
POLL="${GRAPH_POLL:-20}"
MAX_ATTEMPTS="${GRAPH_MAX_ATTEMPTS:-3}"
PROOF_TIMEOUT="${GRAPH_PROOF_TIMEOUT:-300}"   # seconds a declared proof may run

PORT="$(head -1 "$REPO_DIR/.kickoff/opencode-bridge.port" 2>/dev/null || true)"
[ -n "$PORT" ] || { echo "FATAL: no bridge port" >&2; exit 1; }
# every exit path cleans the poll/proof scratch files (review HOLD L3, 2026-08-28);
# TERM/INT too — this executor's normal end-of-life is a supervisor kill.
trap 'rm -f /tmp/gx-$$.json /tmp/gx-state-$$.txt /tmp/gx-$$.proof 2>/dev/null' EXIT
trap 'exit 1' TERM INT
SLUG="$(basename "$REPO_DIR")"
SETTINGS="$HOME/.kickoff/channels/telegram-$(basename "$REPO_DIR")/settings.json"
GRAPHNAME="$(jq -r '.name // "graph"' "$GRAPH_FILE")"
# normalize: nodes without status start as pending
python3 - "$GRAPH_FILE" <<'PYEOF'
import json, sys
gp = sys.argv[1]
g = json.load(open(gp))
for n in g["nodes"]:
    n.setdefault("status", "pending")
json.dump(g, open(gp, "w"), indent=1)
PYEOF
TOKEN=$(jq -r '.env.TELEGRAM_BOT_TOKEN // empty' "$SETTINGS" 2>/dev/null || true)
CHAT=$(jq -r '(.allowFrom[0] // empty)' "$HOME/.claude/channels/telegram-$SLUG/access.json" 2>/dev/null || true)

notify() { # $1=text
  [ -n "$TOKEN" ] && [ -n "$CHAT" ] && \
    curl -s --max-time 10 "https://api.telegram.org/bot$TOKEN/sendMessage" \
      -d chat_id="$CHAT" --data-urlencode "text=$1" >/dev/null || true
  echo "[graph] $1"
}

wt_root="${KICKOFF_LANES_ROOT:-$HOME/kickoff-worktrees}/$SLUG/$$"

gn() { jq -r --arg id "$1" '.nodes[] | select(.id==$id)' "$GRAPH_FILE"; }
set_node() { # id field value
  python3 - "$GRAPH_FILE" "$1" "$2" "$3" <<'EOF'
import json, sys, time
gp, nid, k, v = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
g = json.load(open(gp))
for n in g["nodes"]:
    if n["id"] == nid:
        n[k] = v
        n["updated"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
json.dump(g, open(gp, "w"), indent=1)
EOF
}
node_deps() { gn "$1" | jq -r 'if (.deps|type)=="array" then .deps[] else empty end' 2>/dev/null; }
node_val() { gn "$1" | jq -r ".$2 // empty"; }

spawn_node() { # $1=node id
  local id="$1" agent task proof wt branch sid summary=""
  agent=$(node_val "$id" agent); task=$(node_val "$id" task); proof=$(node_val "$id" proof)
  # inject upstream summaries along deps edges — data flows through the graph
  for dep in $(node_deps "$id"); do
    s=$(node_val "$dep" summary)
    [ -n "$s" ] && summary+="— upstream [$dep]: ${s}"$'\n'
  done
  wt="$wt_root/$id"; branch="lane/$SLUG-$GRAPHNAME-$id"
  git -C "$REPO_DIR" worktree add -b "$branch" "$wt" HEAD >/dev/null 2>&1 \
    || git -C "$REPO_DIR" worktree add "$wt" "$branch" >/dev/null 2>&1 || return 1
  mkdir -p "$wt/.kickoff"
  printf '%s\n' "$task" > "$wt/.kickoff/NODE-TASK.md"
  [ -n "$summary" ] && printf '%s' "$summary" > "$wt/.kickoff/UPSTREAM.md"

  sid=$(curl -s --max-time 10 -H "x-opencode-directory:$wt" -X POST \
    "http://127.0.0.1:$PORT/session" -H 'Content-Type: application/json' \
    -d "{\"title\":\"$GRAPHNAME/$id [$agent]\",\"directory\":\"$wt\"}" | jq -r '.id // empty')
  [ -n "$sid" ] || return 1

  local payload
  payload=$(jq -n --arg s "$sid" --arg d "$wt" --arg a "$agent" --arg t "$task" \
    --arg up "$summary" --arg v "$(node_val "$id" effort)" --arg pr "$proof" '
    {sessionID:$s, directory:$d,
     parts:[{type:"text",text:("You are the ["+$a+"] specialist for graph node "+$s+" (background, own worktree).\nTASK:\n"+$t+"\n"+(if $up!="" then "UPSTREAM RESULTS:\n"+$up else "" end)
     + (if $pr != "" then "\nCompletion is VERIFIED, not self-reported: on NODE-COMPLETE the executor itself runs this proof in your worktree — "+$pr+" — and only a passing proof marks the node done." else "\nNo proof declared for this node: your NODE-COMPLETE will be recorded as CLAIMED/unverified, never done." end)
     +"\nWork autonomously; commit to your branch; end with NODE-COMPLETE plus a 5-line summary.")}]}
    | (if $v != "" then . + {variant:$v} else . end)')
  curl -s --max-time 15 -H "x-opencode-directory:$wt" -X POST \
    "http://127.0.0.1:$PORT/session/$sid/prompt_async" -H 'Content-Type: application/json' \
    -d "$payload" -o /dev/null || true

  set_node "$id" session "$sid"; set_node "$id" status running
  set_node "$id" worktree "$wt"; set_node "$id" branch "$branch"
}

mkdir -p "$wt_root" 2>/dev/null || true
attempts_file="$wt_root/.attempts-$GRAPHNAME"; : > "$attempts_file" 2>/dev/null || true

while true; do
  sleep "$POLL"
  progress=0; all_terminal=1

  # pass 1: running nodes — completion / adaptation. `claimed` is re-polled too: if
  # the executor died mid-proof, the restart re-enters the completion branch and
  # re-runs the proof — a stuck claim self-heals instead of hanging the graph.
  for id in $(jq -r '.nodes[] | select(.status=="running" or .status=="claimed") | .id' "$GRAPH_FILE"); do
    sid=$(node_val "$id" session); wt=$(node_val "$id" worktree)
    curl -s --max-time 6 -H "x-opencode-directory:$wt" \
      "http://127.0.0.1:$PORT/session/$sid/message" -o "/tmp/gx-$$.json" || continue
    python3 - "/tmp/gx-$$.json" <<'EOF' > /tmp/gx-state-$$.txt 2>/dev/null || continue
import json, sys, time
d = json.load(open(sys.argv[1]))
last = sorted(d, key=lambda x: x["info"]["time"]["created"])[-1]
i = last["info"]
texts = [p.get("text","") for p in last.get("parts",[]) if p.get("type")=="text"]
joined = "\n".join(texts).strip()
# Completion contract: NODE-COMPLETE counts ONLY in assistant text — our own
# spawn/adapt prompts are user-role and contain the sentinel, so an unanswered
# prompt must parse as silence, never as done.
complete = i.get("role") == "assistant" and "NODE-COMPLETE" in joined
summary = ""
if complete:
    idx = joined.rfind("NODE-COMPLETE")
    summary = joined[idx+13:idx+700].strip()
errtxt = ("ERR:"+str(i.get("error"))[:280]) if i.get("error") else "-"
errtxt = errtxt.replace(" ", "_").replace("\n", "_")   # single field → keeps read-alignment below
print(i["time"]["created"], errtxt, ("COMPLETE") if complete else "-", summary.replace("\n"," ⏎ ")[:600])
EOF
    read -r created errflag complete summary < /tmp/gx-state-$$.txt 2>/dev/null || continue
    if [ "$complete" = "COMPLETE" ]; then
      # The sentinel is a CLAIM, never a verdict. Verify with the executor-run
      # proof before "done" is allowed to exist in the ledger.
      set_node "$id" status claimed; set_node "$id" summary "$summary"
      proof="$(node_val "$id" proof)"
      if [ -z "$proof" ]; then
        set_node "$id" status unverified
        notify "⚠️ [$GRAPHNAME] node '$id' CLAIMED (no proof declared) — NOT verified, NOT done"
      elif ( cd "$wt" 2>/dev/null && timeout "$PROOF_TIMEOUT" bash -c "$proof" ) > "/tmp/gx-$$.proof" 2>&1; then
        set_node "$id" status done
        notify "✅ [$GRAPHNAME] node '$id' done (proof passed) — $summary"
      else
        prc=$?
        set_node "$id" status proof-failed
        ptail="$(tail -c 400 "/tmp/gx-$$.proof" 2>/dev/null | tr '\n' ' ')"
        set_node "$id" proof_out "$ptail"
        notify "🔴 [$GRAPHNAME] node '$id' PROOF FAILED (rc=$prc): ${ptail:-(no output)}"
      fi
      progress=1
    elif [ "$errflag" != "-" ]; then
      # grep -c PRINTS 0 and RETURNS 1 on no-match — `|| echo 0` here emitted TWO
      # zeroes, the arithmetic blew up, and the error killed the main loop mid-graph
      # (executor reported "finished: 0/N green" over running nodes). Default on EMPTY only.
      att=$(grep -c "^$id " "$attempts_file" 2>/dev/null)
      [ -n "$att" ] || att=0
      if [ "${att:-0}" -ge "$MAX_ATTEMPTS" ]; then
        set_node "$id" status failed
        notify "❌ [$GRAPHNAME] node '$id' FAILED after $MAX_ATTEMPTS attempts — dependents blocked"
        progress=1
      else
        echo "$id x" >> "$attempts_file"
        curl -s --max-time 15 -H "x-opencode-directory:$wt" -X POST \
          "http://127.0.0.1:$PORT/session/$sid/prompt_async" -H 'Content-Type: application/json' \
          -d "$(jq -n --arg s "$sid" --arg d "$wt" --arg e "$errflag" \
                '{sessionID:$s,directory:$d,parts:[{type:"text",text:("ADAPT: previous attempt failed:\n"+$e+"\nDiagnose briefly and CONTINUE the node task. End with NODE-COMPLETE + summary.")}]}')" \
          -o /dev/null
        echo "[graph] adapt $id (attempt $((att+1)))"
      fi
    fi
  done

  # pass 2: pending nodes whose deps are ALL done → spawn. Anything that is not
  # `done` — failed, proof-failed, unverified — is NOT satisfied: a self-reported
  # upstream claim must never unblock a dependent.
  for id in $(jq -r '.nodes[] | select(.status=="pending") | .id' "$GRAPH_FILE"); do
    ready=1
    for dep in $(node_deps "$id"); do
      st=$(node_val "$dep" status)
      case "$st" in done) ;; failed|proof-failed|unverified) set_node "$id" status blocked
        notify "⛔ [$GRAPHNAME] node '$id' BLOCKED (upstream '$dep' ended '$st')"; progress=1 ;;
      *) ready=0 ;; esac
    done
    if [ "$ready" = "1" ] && [ "$(node_val "$id" status)" = "pending" ]; then
      notify "🛫 [$GRAPHNAME] dispatching node '$id'"
      if spawn_node "$id"; then progress=1; else set_node "$id" status failed; fi
    fi
  done

  # terminal check
  for st in $(jq -r '.nodes[].status' "$GRAPH_FILE" | sort -u); do
    case "$st" in done|failed|blocked|proof-failed|unverified) ;; *) all_terminal=0 ;; esac
  done
  [ "$all_terminal" = "1" ] && break
done

DONE=$(jq -r '[.nodes[] | select(.status=="done")] | length' "$GRAPH_FILE")
TOTAL=$(jq -r '.nodes | length' "$GRAPH_FILE")
notify "🏁 [$GRAPHNAME] graph finished: $DONE/$TOTAL nodes green."
# A finished graph where NOTHING ended done is a failure, not a no-op (review HOLD
# L1, 2026-08-28): callers reading the exit code must not mistake 0-green for
# success. A 0-node graph (nothing was asked) stays exit 0.
if [ "$TOTAL" -gt 0 ] && [ "$DONE" -eq 0 ]; then
  echo "[graph] zero of $TOTAL nodes green — exiting non-zero" >&2
  exit 1
fi
exit 0
