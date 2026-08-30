#!/usr/bin/env bash
# lane-runner.sh — the intelligence loop for a dispatched lane.
#
#   REPO_DIR=/… scripts/lane-runner.sh <lane-id> &
#
# Provision (lane-dispatch) → Run (serve) → ADAPT (this script):
#   · watches the lane session until LANE-COMPLETE appears in assistant text
#   · provider error on the last message → re-prompt WITH the error as context
#     ("your previous attempt failed: … — diagnose and continue")  ← the adapt step
#   · silence longer than STALL_MIN with no completion → one nudge, then fail
#   · stall post-nudge → RESPAWN: a fresh session on the SAME worktree continues
#     from disk state (worktree state survives; conversations don't — the 2026-08-28
#     stall epidemic killed sessions mid-run with nudges useless on the dead), up
#     to LANE_RESPAWN_MAX (default 2), then fail. Session-create failure falls
#     through to the loud fail — respawn is resilience, never a silent bypass.
#   · updates .kickoff/graph.json status: running → claimed → done | proof-failed
#     (no proof declared → unverified); failed on error/stall
#
# DONE IS MACHINE-DERIVED, NEVER SELF-REPORTED (output-truth audit leak #1): the
# sentinel only CLAIMS. This runner then verifies the claim itself by executing the
# lane's declared proof (PROOF_CMD at dispatch → the `proof` field in graph.json)
# in the lane's worktree — the agent never runs its own proof:
#   proof exits 0        → done            (exit 0)
#   proof exits non-zero → proof-failed    (exit 1, proof output captured + echoed)
#   no proof declared    → unverified      (exit 1 — claimed is NOT success)
# Exit codes: 0 done (proof passed), 1 everything else.

set -uo pipefail

REPO_DIR="${REPO_DIR:?REPO_DIR required}"
LANE_ID="${1:?lane-id required}"
POLL="${LANE_POLL:-20}"                 # seconds between checks
STALL_MIN="${LANE_STALL_MIN:-8}"        # minutes of total silence before nudge/fail
MAX_ATTEMPTS="${LANE_MAX_ATTEMPTS:-3}"
RESPAWN_MAX="${LANE_RESPAWN_MAX:-2}"        # fresh-session continuations before failing
PROOF_TIMEOUT="${LANE_PROOF_TIMEOUT:-300}"   # seconds a declared proof may run

GRAPH="$REPO_DIR/.kickoff/graph.json"
[ -f "$GRAPH" ] || { echo "FATAL: no graph $GRAPH" >&2; exit 1; }

read_lane() { jq -r --arg id "$LANE_ID" '.lanes[] | select(.id==$id)' "$GRAPH"; }
set_field() {  # $1=field $2=value
  python3 - "$GRAPH" "$LANE_ID" "$1" "$2" <<'EOF'
import json, sys, time
gp, lid, k, v = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
g = json.load(open(gp))
for l in g["lanes"]:
    if l["id"] == lid:
        l[k] = v
        l["updated"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
json.dump(g, open(gp, "w"), indent=1)
EOF
}
set_status() { set_field status "$1"; }
notify_lane() {  # $1=one-line verdict — desktop ping on local-only boxes; silent no-op anywhere else
  [ "${LANE_NOTIFY:-1}" = "1" ] || return 0
  command -v notify-send >/dev/null 2>&1 || return 0
  notify-send -t 5000 "kickoff lane ${LANE_ID##*lane-}" "$1" 2>/dev/null || true
}

row=$(read_lane); [ -n "$row" ] || { echo "FATAL: lane $LANE_ID not in graph" >&2; exit 1; }
PORT=$(echo "$row"    | jq -r .port)
SID=$(echo "$row"     | jq -r .session)
DIR=$(echo "$row"     | jq -r .worktree)
PROOF=$(echo "$row"   | jq -r '.proof // empty')
HDR="x-opencode-directory:$DIR"

# Scratch files: the proof output goes to an UNPREDICTABLE mktemp path (review
# HOLD L3, 2026-08-28 — the old /tmp/lane-$LANE_ID.proof was guessable), and the
# EXIT trap removes both on every exit path, not just the happy ones.
STATE_TMP="/tmp/lane-$$.state"
PROOF_TMP="$(mktemp "/tmp/lane-${LANE_ID}.proof.XXXXXX")"
trap 'rm -f "$STATE_TMP" "$PROOF_TMP" 2>/dev/null' EXIT
trap 'exit 1' TERM INT   # a killed runner must not leak its scratch files either

attempts=0; nudged=0
while true; do
  sleep "$POLL"
  curl -s --max-time 6 -H "$HDR" "http://127.0.0.1:$PORT/session/$SID/message" -o /tmp/lane-$LANE_ID.json 2>/dev/null || continue
  [ -s /tmp/lane-$LANE_ID.json ] || continue

  python3 - /tmp/lane-$LANE_ID.json <<'EOF' > "$STATE_TMP"
import json, sys
d = json.load(open(sys.argv[1]))
if not isinstance(d, list): print("parse-error"); raise SystemExit
last = sorted(d, key=lambda x: x["info"]["time"]["created"])[-1]
i = last["info"]
texts = [p.get("text","") for p in last.get("parts",[]) if p.get("type")=="text"]
joined = " ".join(texts)
# Completion contract (header): LANE-COMPLETE counts ONLY in assistant text. Our own
# seed/adapt/nudge prompts are user-role and contain the sentinel, so an unanswered
# prompt must parse as silence, never as done.
complete = i["role"] == "assistant" and "LANE-COMPLETE" in joined
errtxt = ("ERR:" + str(i.get("error"))[:300]) if i.get("error") else "-"
errtxt = errtxt.replace(" ", "_").replace("\n", "_")   # single field → keeps read-alignment below
# info.time.created is MILLISECONDS (opencode API; cf. lane-status.sh cut -c1-13) → seconds
print(i["role"], i["time"]["created"] // 1000, errtxt,
      ("COMPLETE" if complete else "-"), joined[:120].replace("\n"," "))
EOF
  read -r role created errflag complete snippet < "$STATE_TMP" || true

  if [ "$complete" = "COMPLETE" ]; then
    # The sentinel is a CLAIM, never a verdict. Verify it with the executor-run
    # proof before "done" is allowed to exist in the ledger.
    set_status claimed
    echo "[runner] lane $LANE_ID CLAIMED — verifying with the executor-run proof"
    if [ -z "$PROOF" ]; then
      set_status unverified; notify_lane "⚠️ CLAIMED without proof — unverified"
      echo "[runner] lane $LANE_ID CLAIMED without proof — status=unverified, NOT done"
      echo "[runner] fix: dispatch with PROOF_CMD='<shell command proving the work>' so completion is machine-checked"
      exit 1
    fi
    if ( cd "$DIR" 2>/dev/null && timeout "$PROOF_TIMEOUT" bash -c "$PROOF" ) > "$PROOF_TMP" 2>&1; then
      set_status done; notify_lane "✅ done — proof passed"
      echo "[runner] lane $LANE_ID done — PROOF PASSED: $PROOF"
      exit 0
    else
      prc=$?
      set_status proof-failed; notify_lane "🔴 proof FAILED"
      proof_tail="$(tail -c 600 "$PROOF_TMP" 2>/dev/null | tr '\n' ' ')"
      set_field proof_out "$proof_tail"
      echo "[runner] lane $LANE_ID PROOF FAILED (rc=$prc) — status=proof-failed, NOT done. Proof output:"
      echo "[runner] proof: ${proof_tail:-(no output)}"
      exit 1
    fi
  fi

  if [ "$errflag" != "-" ]; then
    attempts=$((attempts+1))
    if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
      set_status failed; notify_lane "❌ failed (error ladder exhausted)"; echo "[runner] lane $LANE_ID FAILED after $attempts attempts: $errflag"
      exit 1
    fi
    echo "[runner] adapt #$attempts: re-prompting with error context"
    curl -s --max-time 15 -H "$HDR" -X POST "http://127.0.0.1:$PORT/session/$SID/prompt_async" \
      -H 'Content-Type: application/json' \
      -d "$(jq -n --arg s "$SID" --arg d "$DIR" --arg e "$errflag" --arg t "$(cat "$DIR/.kickoff/LANE-TASK.md" 2>/dev/null | head -c 1500)" \
            '{sessionID:$s,directory:$d,parts:[{type:"text",text:("ADAPT: your previous run failed with this provider/system error:\n"+$e+"\nDiagnose briefly, then CONTINUE the original task from where it stopped. Original task summary:\n"+$t+"\nFinish and end with LANE-COMPLETE.")}]}')" \
      -o /dev/null
    nudged=0
  else
    # Stall = SILENCE, whatever role the newest message has: a provider hung on OUR
    # seed/adapt/nudge leaves user-role text as the newest message — exactly the
    # hung case the nudge exists for.
    case "${created:-}" in
    ''|*[!0-9]*) : ;;   # no usable timestamp this poll (parse hiccup) — skip, never insta-stall
    *)
      now=$(date +%s); age=$(( now - created ))
      if [ "$age" -gt $(( STALL_MIN*60 )) ]; then
        if [ "$nudged" -eq 0 ]; then
          nudged=1
          echo "[runner] stall detected — nudging once"
          curl -s --max-time 15 -H "$HDR" -X POST "http://127.0.0.1:$PORT/session/$SID/prompt_async" \
        -H 'Content-Type: application/json' \
        -d "{\"sessionID\":\"$SID\",\"directory\":\"$DIR\",\"parts\":[{\"type\":\"text\",\"text\":\"RUNNER NUDGE: no output observed for ${STALL_MIN}m. Continue the lane task; end with LANE-COMPLETE.\"}]}" -o /dev/null
        elif [ "${RESPAWNS:-0}" -lt "$RESPAWN_MAX" ]; then
          # The nudge went unanswered — the session is likely dead, and prompts cannot
          # revive the dead. RESPAWN instead of failing: a FRESH session on this same
          # worktree re-grounds from disk (task brief + git state) and continues.
          RESPAWNS=$((${RESPAWNS:-0}+1))
          new_sid="$(curl -s --max-time 10 -H "$HDR" -X POST "http://127.0.0.1:$PORT/session" \
            -H 'Content-Type: application/json' \
            -d "{\"directory\":\"$DIR\",\"title\":\"respawn-$LANE_ID-$RESPAWNS\"}" \
            | jq -r '.id // empty' 2>/dev/null || true)"
          if [ -n "$new_sid" ] && [ "${new_sid#ses_}" != "$new_sid" ]; then
            SID="$new_sid"
            set_field session "$SID"
            set_field respawns "$RESPAWNS"
            model_json=""
            m_pin="$(jq -r --arg id "$LANE_ID" '.lanes[] | select(.id==$id) | .model // empty' "$GRAPH")"
            [ -n "$m_pin" ] && model_json="$(jq -nc --arg m "$m_pin" '{model:{providerID:($m|split("/"))[0],modelID:($m|split("/"))[1]}}')"
            task_head="$(head -c 1200 "$DIR/.kickoff/LANE-TASK.md" 2>/dev/null || true)"
            curl -s --max-time 15 -H "$HDR" -X POST "http://127.0.0.1:$PORT/session/$SID/prompt_async" \
              -H 'Content-Type: application/json' \
              -d "$(jq -nc --arg s "$SID" --arg d "$DIR" --arg t "$task_head" --arg r "$RESPAWNS" --arg mj "$model_json" \
                '({sessionID:$s,directory:$d,parts:[{type:"text",text:("RESPAWN "+$r+": your predecessor session stalled mid-task and could not be revived. The worktree holds its real state. Re-ground NOW: (1) read .kickoff/LANE-TASK.md in full — the original brief; (2) git log --oneline -8 and git status --short — what your predecessor committed and left. Then CONTINUE the task from that state; do not restart from zero. Brief head:\n"+$t+"\n…End with LANE-COMPLETE plus a 5-line summary.")}]}) + (if $mj != "" then ($mj|fromjson) else {} end)')" \
              -o /dev/null
            nudged=0; attempts=0
            echo "[runner] lane $LANE_ID stalled post-nudge — RESPAWN #$RESPAWNS: fresh session $SID continues from worktree state"
          else
            set_status failed; echo "[runner] lane $LANE_ID stalled post-nudge and respawn session-create failed — failing"
            exit 1
          fi
        else
          set_status failed; echo "[runner] lane $LANE_ID stalled post-nudge, respawn cap ($RESPAWN_MAX) reached — failing"
          exit 1
        fi
      fi
      ;;
    esac
  fi
done
