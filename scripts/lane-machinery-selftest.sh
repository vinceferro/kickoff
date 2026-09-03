#!/usr/bin/env bash
# lane-machinery-selftest.sh — the lane pipeline (lane-dispatch · lane-runner ·
# graph-executor) cannot lie about completion, and cannot hang forever.
#
#   bash scripts/lane-machinery-selftest.sh
#
# Three live defects this pins (found by adversarial review against v0.41 tip):
#
#   H1 — the completion parsers read the NEWEST message REGARDLESS OF ROLE, and the
#        runner/dispatcher's OWN user-side prompts contain the sentinels ("End your
#        run with LANE-COMPLETE…", "End with NODE-COMPLETE + summary."). Any node
#        whose model had not answered within one poll parsed its own seed as the
#        last message → green without work; error-adapt reprompts false-completed
#        instantly. Fix under test: COMPLETE counts only in ASSISTANT text.
#
#   H2 — lane-runner's stall timer subtracted opencode's MILLISECOND info.time.created
#        from date +%s (seconds): age ≈ -1.7e9, the >STALL_MIN test could never fire,
#        a hung provider polled forever. lane-status.sh treats the same field as ms
#        (cut -c1-13), proving intent. Fix under test: ms→s at the parse seam, and
#        stall keyed on silence (any role) — a provider hung on OUR prompt leaves a
#        user-role newest message, which is exactly the hung case.
#
#   M1 — docs/coordinator-dispatch-protocol.md claimed lanes are "supervised by the
#        adapt runner" with "completion via background notification" (nothing
#        auto-starts a watcher; no notification path exists outside graph-executor)
#        and called the graph.json ledger "Optional" (lane-dispatch writes it
#        unconditionally). Fix under test: the DOC matches the CODE, pinned here so
#        it cannot rot back.
#
#   L1 — completion was SELF-REPORTED: the sentinel sentence itself wrote status=done
#        and reached the operator as "✅ done" (output-truth audit leak #1). Fix under
#        test: sentinel → claimed, then the EXECUTOR runs the lane/node's declared
#        proof itself in the worktree — pass → done, fail → proof-failed, none
#        declared → unverified. "done" is machine-derived everywhere: ledger, exit
#        codes, the dep-gate, and the "N/M green" count all refuse claimed/unverified.
#
# RED-first: every defect lane below was watched go RED against the pre-fix tree;
# the positive controls (S2, G2, G3) were watched stay GREEN on it, so a guard that
# blocked legitimate completion could never hide behind a green suite.
#
# Wave-2 pins (review HOLD 2026-08-28): M2 — the stuck-`claimed` re-poll lanes
# (passing proof → done, failing proof → proof-failed); L1 — the executor's own
# exit code refuses "0 green" (a finished graph where nothing ended done is a
# failure, not a no-op).
#
# Hermetic: a fake opencode serve API on 127.0.0.1:<ephemeral>, mktemp fixtures,
# HOME sandboxed so graph-executor's Telegram notify resolves NO token/chat — it
# can only ever echo to the local log. No real engine, channel, or repo is touched.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "▶ lane-machinery self-test (completion is assistant-only · stall fires in real time · done is proof-derived · docs match code)"
echo

F="$(mktemp -d)"
STATE="$F/state"; mkdir -p "$STATE"
SRV_PID=""
cleanup() { [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; rm -rf "$F" /tmp/lane-lm-*.json; }
trap cleanup EXIT

# ── the fake opencode serve API ──────────────────────────────────────────────
# GET  /session/<sid>/message  → the CURRENT contents of $STATE/messages.json
#                                (re-read on every request, so the test can
#                                choreograph mid-run if it ever needs to)
# POST anything               → body appended to $STATE/posts.jsonl (the wire
#                               the runner's nudges and the executor's adapts
#                               are counted on), replies like the real API.
start_server() {
  python3 - "$STATE" <<'PYEOF' &
import http.server, json, os, sys, socketserver
state = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _reply(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def do_GET(self):
        try:
            msgs = json.load(open(os.path.join(state, "messages.json")))
        except Exception:
            msgs = []
        self._reply(msgs)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode()
        with open(os.path.join(state, "posts.jsonl"), "a") as f:
            f.write(json.dumps({"path": self.path, "body": body}) + "\n")
        if "prompt_async" in self.path:
            # W1: an optional injected failure — $STATE/prompt_async_reply_code makes
            # the seed POST fail like the real serve does (ProviderModelNotFoundError
            # etc. surface as non-2xx), so dispatch's fail-loud path is drivable.
            code_file = os.path.join(state, "prompt_async_reply_code")
            if os.path.exists(code_file):
                code = int(open(code_file).read().strip() or 500)
                b = json.dumps({"error": "injected seed failure"}).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)
            else:
                self._reply({})
        else:
            # POST /session: honors $STATE/session_reply when present (the respawn
            # lane drives a VALID id through); default hyphen-id is deliberately
            # invalid (a serve that cannot create sessions → loud-fail path).
            try: rid = open(os.path.join(state, "session_reply")).read().strip()
            except Exception: rid = "ses-fixture"
            self._reply({"id": rid})
class S(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
srv = S(("127.0.0.1", 0), H)
with open(os.path.join(state, "port"), "w") as fh:
    fh.write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF
  SRV_PID=$!
  local i; for i in $(seq 1 50); do [ -s "$STATE/port" ] && break; sleep 0.1; done
}
start_server
if [ ! -s "$STATE/port" ]; then echo "FATAL: fake serve API never came up" >&2; exit 1; fi
PORT="$(cat "$STATE/port")"

# ── fixture builders ──────────────────────────────────────────────────────────
now_ms()   { date +%s%3N; }
past_ms()  { echo $(( $(date +%s%3N) - $1 )); }   # $1 = milliseconds ago

mkmsg() {  # $1=id $2=role $3=created_ms $4=error(""=none) $5=text → one API message
  jq -n --arg id "$1" --arg role "$2" --argjson c "$3" --arg e "$4" --arg t "$5" \
    '{info:({id:$id, role:$role, time:{created:$c}} + (if $e == "" then {} else {error:$e} end)),
      parts:[{type:"text", text:$t}]}'
}
write_msgs() { printf '%s\n' "$@" | jq -s '.' > "$STATE/messages.json"; }
reset_posts() { : > "$STATE/posts.jsonl"; }
posts_n() { wc -l < "$STATE/posts.jsonl" 2>/dev/null | tr -d ' '; }
nudge_posts_n() { grep -c "RUNNER NUDGE" "$STATE/posts.jsonl" 2>/dev/null || true; }
session_creates_n() { grep -c '"path": "/session",' "$STATE/posts.jsonl" 2>/dev/null || true; }

# The runners' OWN prompt texts, verbatim from the shipped sources. If the wording
# drifts, this suite must be consciously updated — the sentinel-in-user-text shape
# IS the protocol these parsers have to survive.
SEED_TEXT="You are the [builder] specialist executing BACKGROUND LANE lm-1.
Rules: reversible work autonomously; gated work STOP and note it instead.
No proof was declared for this lane: your LANE-COMPLETE will be recorded as
CLAIMED/unverified — never done. Tell the coordinator to dispatch with PROOF_CMD set.
End your run with LANE-COMPLETE plus a 5-line summary."
ADAPT_TEXT="ADAPT: your previous run failed with this provider/system error:
ERR:rate_limited_upstream
Diagnose briefly, then CONTINUE the original task from where it stopped. Original task summary:
do the fixture thing
Finish and end with LANE-COMPLETE."
GX_SPAWN_TEXT="You are the [builder] specialist for graph node n1 (background, own worktree).
TASK:
fixture node task
No proof declared for this node: your NODE-COMPLETE will be recorded as CLAIMED/unverified, never done.
Work autonomously; commit to your branch; end with NODE-COMPLETE plus a 5-line summary."
GX_ADAPT_TEXT="ADAPT: previous attempt failed:
ERR:boom
Diagnose briefly and CONTINUE the node task. End with NODE-COMPLETE + summary."

# ── lane-runner fixtures ──────────────────────────────────────────────────────
REPO="$F/repo"; WT="$F/wt"; mkdir -p "$REPO/.kickoff" "$WT/.kickoff"
mk_lane_graph() {  # $1=lane-id $2=optional proof cmd → fresh single-lane ledger bound to the fake API
  jq -n --arg id "$1" --argjson port "$PORT" --arg wt "$WT" --arg proof "${2:-}" \
    '{lanes:[{id:$id, agent:"builder", status:"running", deps:[],
              worktree:$wt, branch:("lane/lm-" + $id), session:"ses-fixture",
              port:$port, created:"fixture"}
              + (if $proof == "" then {} else {proof:$proof} end)]}' > "$REPO/.kickoff/graph.json"
}
run_lane() {  # $1=lane-id $2=optional logfile → rc (STALL_MIN=1 ⇒ threshold 60s; stale fixtures cross it on poll 1)
  REPO_DIR="$REPO" HOME="$F/home" KICKOFF_LANES_ROOT="$F/lanes" \
    LANE_POLL=1 LANE_STALL_MIN=1 LANE_MAX_ATTEMPTS=3 LANE_PROOF_TIMEOUT=10 \
    timeout 12 bash "$HERE/lane-runner.sh" "$1" >"${2:-/dev/null}" 2>&1
  echo $?
}
lane_status() { jq -r '.lanes[0].status' "$REPO/.kickoff/graph.json" 2>/dev/null; }

# ── graph-executor fixtures ───────────────────────────────────────────────────
GREPO="$F/grepo"; GWT="$F/gwt"; mkdir -p "$GREPO/.kickoff" "$GWT" "$F/lanes"
printf '%s\n' "$PORT" > "$GREPO/.kickoff/opencode-bridge.port"
mk_node_graph() {  # $1=outfile $2=optional proof cmd → single pre-RUNNING node (spawn path deliberately bypassed:
                   # these scenarios test the COMPLETION parser, not provisioning)
  jq -n --arg wt "$GWT" --arg proof "${2:-}" \
    '{name:"lm-fixture",
      nodes:[{id:"n1", agent:"builder", deps:[], task:"fixture node task",
              status:"running", session:"ses-a", worktree:$wt, branch:"lane/lm-fixture-n1"}
              + (if $proof == "" then {} else {proof:$proof} end)]}' > "$1"
}
mk_dep_graph() {  # $1=outfile → n1 (no proof declared) + n2 depending on it: pins the
                  # DEP-GATE — the machine consumer that must refuse unverified as done
  jq -n --arg wt "$GWT" \
    '{name:"lm-dep",
      nodes:[{id:"n1", agent:"builder", deps:[], task:"fixture node task",
              status:"running", session:"ses-a", worktree:$wt, branch:"lane/lm-dep-n1"},
             {id:"n2", agent:"builder", deps:["n1"], task:"dependent fixture",
              status:"pending"}]}' > "$1"
}
run_gx() {  # $1=graph-file $2=logfile → rc
  GRAPH="$1" REPO_DIR="$GREPO" HOME="$F/home" KICKOFF_LANES_ROOT="$F/lanes" \
    GRAPH_POLL=1 GRAPH_MAX_ATTEMPTS=1 GRAPH_PROOF_TIMEOUT=10 \
    timeout 8 bash "$HERE/graph-executor.sh" >"$2" 2>&1
  echo $?
}
node_status() { jq -r '.nodes[0].status' "$1" 2>/dev/null; }
node_st() { jq -r --arg id "$2" '.nodes[] | select(.id==$id) | .status' "$1" 2>/dev/null; }

# ══ 1. H1 — lane-runner: its own prompts can never read as COMPLETE ═══════════
echo "─ 1 · lane-runner completion (H1)"

reset_posts
mk_lane_graph "lm-s1"
write_msgs "$(mkmsg m1 user "$(past_ms 120000)" "" "$ADAPT_TEXT")"   # own adapt prompt, model silent
RC="$(run_lane lm-s1)"
chk "H1: the runner's own ADAPT prompt (user-role, sentinel) does NOT complete the lane" \
    '[ "$RC" = 1 ]'
chk "H1: that lane ends FAILED via the stall ladder — never done" \
    '[ "$(lane_status)" = "failed" ]'
chk "H1: exactly ONE nudge on the stall (nudge → respawn-attempt → loud fail ladder)" \
    '[ "$(nudge_posts_n)" = 1 ]'
chk "H1: post-nudge RESPAWN attempted (POST /session) and failed loudly on the invalid id" \
    '[ "$(session_creates_n)" -ge 1 ]'

reset_posts
mk_lane_graph "lm-s2"
write_msgs "$(mkmsg m1 user "$(past_ms 120000)" "" "$SEED_TEXT")" \
           "$(mkmsg m2 assistant "$(now_ms)" "" "All committed. LANE-COMPLETE done: 3 files changed, tests green.")"
RC="$(run_lane lm-s2)"
chk "H1·control: an assistant LANE-COMPLETE is still RECOGNIZED (enters verification, no re-prompt spent)" \
    '[ "$(posts_n)" = 0 ] && [ "$(lane_status)" != "failed" ]'
chk "L1: a sentinel with NO proof declared lands unverified — never done, never a success exit" \
    '[ "$RC" = 1 ] && [ "$(lane_status)" = "unverified" ]'

reset_posts
mk_lane_graph "lm-s3"
write_msgs "$(mkmsg m1 user "$(past_ms 120000)" "" "$SEED_TEXT")" \
           "$(mkmsg m2 assistant "$(past_ms 120000)" "" "still working, nothing to report yet")"
RC="$(run_lane lm-s3)"
chk "H1·control: an honest sentinel-free assistant message is never mistaken for completion" \
    '[ "$RC" = 1 ] && [ "$(lane_status)" = "failed" ]'

# ══ 2. H2 — lane-runner stall timer runs on real seconds ══════════════════════
echo "─ 2 · lane-runner stall detection (H2)"

reset_posts
mk_lane_graph "lm-s4"
# Real opencode shape: info.time.created is MILLISECONDS (lane-status.sh cuts c1-13).
# An assistant spoke 2 minutes ago and went silent; STALL_MIN=1 ⇒ must nudge, then fail.
write_msgs "$(mkmsg m1 assistant "$(past_ms 120000)" "" "made some progress earlier")"
RC="$(run_lane lm-s4)"
chk "H2: an ms-timestamped assistant message stale past STALL_MIN fires the stall (nudge sent)" \
    '[ "$(nudge_posts_n)" = 1 ]'
chk "H2: silence after the nudge fails the lane instead of polling forever" \
    '[ "$RC" = 1 ] && [ "$(lane_status)" = "failed" ]'

# lm-s4b — the RESPAWN ladder (2026-08-28 stall epidemic): a session-less serve
# cannot revive the dead; a serve that CAN create sessions gets a fresh session
# bound to the same worktree, the ledger re-pointed, the nudge ladder reset, and
# the cap still fails loudly. Valid id via $STATE/session_reply; cap pinned at 1.
reset_posts; printf 'ses_newrespawn\n' > "$STATE/session_reply"
mk_lane_graph "lm-s4b"
write_msgs "$(mkmsg m1 assistant "$(past_ms 120000)" "" "progressed then died silently")"
RC="$(LANE_RESPAWN_MAX=1 run_lane "lm-s4b" "$F/lm-s4b.log")"
chk "RESPAWN: the post-nudge respawn CREATED a fresh session and posted the continuation" \
    '[ "$(session_creates_n)" = 1 ] && [ "$(grep -c "RESPAWN 1:" "$STATE/posts.jsonl" 2>/dev/null || true)" = 1 ]'
chk "RESPAWN: the ledger session was RE-POINTED to the fresh session id" \
    '[ "$(jq -r '.lanes[0].session' "$REPO/.kickoff/graph.json")" = "ses_newrespawn" ]'
chk "RESPAWN: the nudge ladder RESET (a second nudge fired on the still-stale fixture)" \
    '[ "$(nudge_posts_n)" = 2 ]'
chk "RESPAWN: the cap still fails loudly (never an infinite respawn loop)" \
    '[ "$RC" = 1 ] && [ "$(lane_status)" = "failed" ] && grep -q "respawn cap" "$F/lm-s4b.log" '
rm -f "$STATE/session_reply"

reset_posts
mk_lane_graph "lm-s5"
write_msgs "$(mkmsg m1 assistant "$(now_ms)" "" "just started")"
RC="$(run_lane lm-s5)"
# A fresh ms timestamp must read as ~0s old through the new ms→s seam — inside the
# 12s window the lane may neither nudge nor fail; the window kill (124) IS the proof.
chk "H2·control: a FRESH ms timestamp is not stalled by the unit conversion (no premature nudge)" \
    '[ "$(posts_n)" = 0 ] && [ "$RC" = 124 ] && [ "$(lane_status)" = "running" ]'

# ══ 3. H1 — graph-executor: spawn/adapt prompts can never mark a node done ════
echo "─ 3 · graph-executor completion (H1)"

reset_posts
GF="$F/g1.json"; mk_node_graph "$GF"
LOG="$F/g1.log"
write_msgs "$(mkmsg m1 user "$(past_ms 120000)" "" "$GX_SPAWN_TEXT")"
RC="$(run_gx "$GF" "$LOG")"
chk "H1: the executor's own SPAWN prompt (user-role, sentinel) cannot advance the node at all" \
    '[ "$(node_status "$GF")" = "running" ]'
chk "H1: executor kept polling (killed by the window, never celebrated) — no ✅, no adapt spent" \
    '[ "$RC" = 124 ] && ! grep -q "✅" "$LOG" && [ "$(posts_n)" = 0 ]'

reset_posts
GF="$F/g2.json"; mk_node_graph "$GF"; LOG="$F/g2.log"
write_msgs "$(mkmsg m1 user "$(past_ms 120000)" "" "$GX_SPAWN_TEXT")" \
           "$(mkmsg m2 assistant "$(now_ms)" "" "NODE-COMPLETE done: migrated schema, 12 rows moved.")"
RC="$(run_gx "$GF" "$LOG")"
chk "H1·control: an assistant NODE-COMPLETE is still RECOGNIZED (summary captured; sentinel honored)" \
    '[ "$RC" = 1 ] && [ "$(node_status "$GF")" != "running" ]'
chk "L1: a node sentinel with NO proof declared lands unverified — done stays reserved for proof-passed" \
    '[ "$(node_status "$GF")" = "unverified" ]'
chk "H1·control: the summary after the sentinel is extracted into the graph ledger" \
    'jq -r ".nodes[0].summary" "'$GF'" | grep -q "12 rows moved"'

reset_posts
GF="$F/g3.json"; mk_node_graph "$GF"; LOG="$F/g3.log"
write_msgs "$(mkmsg m1 assistant "$(past_ms 120000)" "upstream 500" "attempt blew up")"
RC="$(run_gx "$GF" "$LOG")"
chk "H1·control: a REAL provider error still drives the adapt path (re-prompt posted)" \
    '[ "$(posts_n)" -ge 1 ]'
chk "H1·control: exhausted attempts fail the node honestly (honest non-zero exit, ❌ notified)" \
    '[ "$RC" = 1 ] && [ "$(node_status "$GF")" = "failed" ] && grep -q "FAILED" "$LOG"'

reset_posts
GF="$F/g4.json"; mk_node_graph "$GF"; LOG="$F/g4.log"
write_msgs "$(mkmsg m1 assistant "$(past_ms 240000)" "upstream 500" "attempt blew up")" \
           "$(mkmsg m2 user "$(past_ms 120000)" "" "$GX_ADAPT_TEXT")"   # adapt posted, model silent
RC="$(run_gx "$GF" "$LOG")"
chk "H1: the executor's own ADAPT prompt sitting as newest message cannot false-complete the node" \
    '[ "$(node_status "$GF")" = "running" ] && [ "$RC" = 124 ]'

# ══ 4. L1 — lane-runner: done is PROOF-derived, not sentinel-derived ═══════════
echo "─ 4 · lane-runner proof verification (L1)"

# dispatch side first: a declared proof must reach BOTH the ledger and the worker's
# own seed prompt (the contract is visible in-band, not a coordinator secret).
DREPO="$F/drepo"; mkdir -p "$DREPO/.kickoff"
git -C "$DREPO" init -q
git -C "$DREPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m root
printf '%s\n' "$PORT" > "$DREPO/.kickoff/opencode-bridge.port"
reset_posts
REPO_DIR="$DREPO" HOME="$F/home" KICKOFF_LANES_ROOT="$F/lanes" \
  PROOF_CMD="bash prove.sh" LANE_AUTOSTART=0 \
  timeout 15 bash "$HERE/lane-dispatch.sh" builder "-do the fixture thing" >"$F/d1.log" 2>&1
chk "L1: lane-dispatch records the declared proof in the graph ledger (proof field)" \
    'jq -r ".lanes[0].proof" "$DREPO/.kickoff/graph.json" | grep -q "prove.sh"'
chk "L1: the seed prompt states the contract — completion verified by the executor-run proof" \
    'grep -q "Completion is VERIFIED" "$STATE/posts.jsonl" && grep -q "prove.sh" "$STATE/posts.jsonl"'

reset_posts
DREPO2="$F/drepo2"; mkdir -p "$DREPO2/.kickoff"
git -C "$DREPO2" init -q
git -C "$DREPO2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m root
printf '%s\n' "$PORT" > "$DREPO2/.kickoff/opencode-bridge.port"
REPO_DIR="$DREPO2" HOME="$F/home" KICKOFF_LANES_ROOT="$F/lanes" LANE_AUTOSTART=0 \
  timeout 15 bash "$HERE/lane-dispatch.sh" builder "-do the fixture thing" >"$F/d2.log" 2>&1
chk "L1: dispatch WITHOUT a proof tells the worker its completion lands CLAIMED/unverified" \
    'grep -q "CLAIMED/unverified" "$STATE/posts.jsonl" && [ "$(jq -r ".lanes[0].proof" "$DREPO2/.kickoff/graph.json")" = "null" ]'

# ── dispatch SELF-START (2026-08-28): dispatch is ONE step ────────────────────
# The runner is spawned by dispatch itself (a live serve + no existing runner),
# recorded in the ledger, and never double-started. The lanes above run with
# LANE_AUTOSTART=0 to stay hermetic; THIS lane opts in and cleans up its runner.
reset_posts
DREPO3="$F/drepo3"; mkdir -p "$DREPO3/.kickoff"
git -C "$DREPO3" init -q
git -C "$DREPO3" -c user.email=t@t -c user.name=t commit -q --allow-empty -m root
printf '%s\n' "$PORT" > "$DREPO3/.kickoff/opencode-bridge.port"
REPO_DIR="$DREPO3" HOME="$F/home" KICKOFF_LANES_ROOT="$F/lanes" \
  timeout 15 bash "$HERE/lane-dispatch.sh" builder "-do the fixture thing" >"$F/d3.log" 2>&1
SELF_PID="$(jq -r '.lanes[0].runner_pid // 0' "$DREPO3/.kickoff/graph.json" 2>/dev/null)"
chk "SELF-START: dispatch spawns its runner and records the pid in the ledger" \
    'grep -q "self-started" "$F/d3.log" && [ -n "$SELF_PID" ] && [ "$SELF_PID" != "0" ]'
chk "SELF-START: the spawned runner is a LIVE process" \
    '[ -n "$SELF_PID" ] && [ "$SELF_PID" != "0" ] && [ -d "/proc/$SELF_PID" ]'
[ -n "$SELF_PID" ] && [ "$SELF_PID" != "0" ] && kill "$SELF_PID" 2>/dev/null

# ── W1 (2026-09-01): the seed POST is not fire-and-discarded ─────────────────
# Real cost: three planner lanes sat SILENT (user message delivered, zero assistant
# tokens, no error surfaced anywhere the coordinator looks) because dispatch threw
# away the seed prompt_async response (`-o /dev/null -w "" || true`). Fix under
# test: a failed seed → dispatch exits non-zero NAMING prompt_async, deletes the
# session, removes its worktree+branch, and writes NO graph node.
reset_posts
DREPO4="$F/drepo4"; mkdir -p "$DREPO4/.kickoff"
git -C "$DREPO4" init -q
git -C "$DREPO4" -c user.email=t@t -c user.name=t commit -q --allow-empty -m root
printf '%s\n' "$PORT" > "$DREPO4/.kickoff/opencode-bridge.port"
printf '500\n' > "$STATE/prompt_async_reply_code"
D4_RC=0
REPO_DIR="$DREPO4" HOME="$F/home" KICKOFF_LANES_ROOT="$F/lanes" LANE_AUTOSTART=0 \
  timeout 15 bash "$HERE/lane-dispatch.sh" builder "-do the fixture thing" >"$F/d4.log" 2>&1 || D4_RC=$?
rm -f "$STATE/prompt_async_reply_code"
chk "W1: dispatch FAILS loudly when the seed prompt_async fails" '[ "$D4_RC" -ne 0 ]'
chk "W1: the failure NAMES the seed (prompt_async), not a generic error" \
    'grep -q "prompt_async" "$F/d4.log"'
chk "W1: no graph node is written for a failed-seed dispatch" \
    '[ "$(jq ".lanes | length" "$DREPO4/.kickoff/graph.json" 2>/dev/null || echo 0)" = "0" ]'
chk "W1: the lane worktree is cleaned up (no orphan tree)" \
    '! git -C "$DREPO4" worktree list | grep -q "lanes/drepo4"'
chk "W1: the lane branch is cleaned up" \
    '! git -C "$DREPO4" branch --list "lane/*" | grep -q .'


reset_posts
rm -f "$WT/p1-marker"
mk_lane_graph "lm-p1" "ls $WT/p1-marker"
LOG="$F/p1.log"
write_msgs "$(mkmsg m1 assistant "$(now_ms)" "" "Trust me, all done. LANE-COMPLETE shipped it.")"
RC="$(run_lane lm-p1 "$LOG")"
chk "L1: a LYING worker (sentinel, no work) lands proof-failed — NEVER done" \
    '[ "$RC" = 1 ] && [ "$(lane_status)" = "proof-failed" ]'
chk "L1: the runner says PROOF FAILED loudly, with the proof's actual output" \
    'grep -q "PROOF FAILED" "$LOG" && jq -r ".lanes[0].proof_out" "$REPO/.kickoff/graph.json" | grep -q "p1-marker"'
chk "L1: the lying lane's proof-failed is terminal for the runner (no nudge/adapt spent after it)" \
    '[ "$(posts_n)" = 0 ]'

reset_posts
touch "$WT/p2-marker"
mk_lane_graph "lm-p2" "test -f $WT/p2-marker"
LOG="$F/p2.log"
write_msgs "$(mkmsg m1 assistant "$(now_ms)" "" "Work committed, marker in place. LANE-COMPLETE.")"
RC="$(run_lane lm-p2 "$LOG")"
chk "L1·control: honest work + passing executor proof → done, exit 0, proof PASSED on the record" \
    '[ "$RC" = 0 ] && [ "$(lane_status)" = "done" ] && grep -q "PROOF PASSED" "$LOG"'
rm -f "$WT/p2-marker"

reset_posts
mk_lane_graph "lm-p3"
LOG="$F/p3.log"
write_msgs "$(mkmsg m1 assistant "$(now_ms)" "" "Done-ish. LANE-COMPLETE.")"
RC="$(run_lane lm-p3 "$LOG")"
chk "L1: no proof declared → unverified, and the runner names the fix (declare PROOF_CMD at dispatch)" \
    '[ "$RC" = 1 ] && [ "$(lane_status)" = "unverified" ] && grep -q "CLAIMED without proof" "$LOG"'

reset_posts
mk_lane_graph "lm-p4" "test -f $WT/never-created"
LOG="$F/p4.log"
write_msgs "$(mkmsg m1 assistant "$(past_ms 240000)" "api exploded" "attempt blew up")"
RC="$(run_lane lm-p4 "$LOG")"
chk "L1·control: a DEAD worker (provider error) with a proof declared still fails via the error path — never done/claimed" \
    '[ "$RC" = 1 ] && [ "$(lane_status)" = "failed" ]'

# ══ 5. L1 — graph-executor: proof verdicts + the consumers of status ══════════
echo "─ 5 · graph-executor proof verification + status consumers (L1)"

reset_posts
rm -f "$GWT/n1-done"
GF="$F/p5a.json"; mk_node_graph "$GF" "ls $GWT/n1-done"; LOG="$F/p5a.log"
write_msgs "$(mkmsg m1 assistant "$(now_ms)" "" "All migrated, trust me. NODE-COMPLETE done: 12 rows moved.")"
RC="$(run_gx "$GF" "$LOG")"
chk "L1: a LYING node (sentinel, work absent) lands proof-failed — NEVER done, 🔴 with the proof output" \
    '[ "$RC" = 1 ] && [ "$(node_status "$GF")" = "proof-failed" ] && grep -q "PROOF FAILED" "$LOG" && grep -q "🔴" "$LOG"'
chk "L1: proof-failed is terminal (executor exits) and does not count as green" \
    'grep -q "0/1 nodes green" "$LOG"'

reset_posts
touch "$GWT/n1-done"
GF="$F/p5b.json"; mk_node_graph "$GF" "test -f $GWT/n1-done"; LOG="$F/p5b.log"
write_msgs "$(mkmsg m1 assistant "$(now_ms)" "" "Migrated for real. NODE-COMPLETE done: 12 rows moved.")"
RC="$(run_gx "$GF" "$LOG")"
chk "L1·control: honest node + passing executor proof → done with '✅ … done (proof passed)'" \
    '[ "$RC" = 0 ] && [ "$(node_status "$GF")" = "done" ] && grep -q "done (proof passed)" "$LOG" && grep -q "1/1 nodes green" "$LOG"'
rm -f "$GWT/n1-done"

reset_posts
GF="$F/p5c.json"; mk_node_graph "$GF"; LOG="$F/p5c.log"
write_msgs "$(mkmsg m1 assistant "$(now_ms)" "" "NODE-COMPLETE done: schema migrated.")"
RC="$(run_gx "$GF" "$LOG")"
chk "L1: no proof declared → ⚠️ CLAIMED (no proof declared), status unverified, honest non-zero exit" \
    '[ "$RC" = 1 ] && [ "$(node_status "$GF")" = "unverified" ] && grep -q "CLAIMED (no proof declared)" "$LOG"'
chk "L1: unverified does not read as success ANYWHERE — no ✅, not counted green" \
    '! grep -q "✅" "$LOG" && grep -q "0/1 nodes green" "$LOG"'

reset_posts
GF="$F/p5d.json"; mk_dep_graph "$GF"; LOG="$F/p5d.log"
write_msgs "$(mkmsg m1 assistant "$(now_ms)" "" "NODE-COMPLETE done: upstream thing.")"
RC="$(run_gx "$GF" "$LOG")"
chk "L1·consumer: a dep that ended unverified BLOCKS its dependent — the dep-gate refuses it as done" \
    '[ "$(node_st "$GF" n1)" = "unverified" ] && [ "$(node_st "$GF" n2)" = "blocked" ] && ! grep -q "dispatching node 'n2'" "$LOG"'
chk "L1·consumer: the graph totals count only verified dones (0/2), and the executor terminates" \
    '[ "$RC" = 1 ] && grep -q "0/2 nodes green" "$LOG"'

# ══ 5b. M2 — a stuck `claimed` node self-heals on re-poll · L1 honest exit ═══
echo "─ 5b · stuck-claimed re-poll (M2) + graph exit honesty (L1)"

mk_claimed_graph() {  # $1=outfile $2=proof → a node STUCK at claimed: the shape
                      # an executor that died mid-proof leaves in the ledger. A
                      # restart must re-enter the completion branch, re-run the
                      # proof, and land done/proof-failed — not hang the graph.
  jq -n --arg wt "$GWT" --arg proof "$2" \
    '{name:"lm-repoll",
      nodes:[{id:"n1", agent:"builder", deps:[], task:"fixture node task",
              status:"claimed", session:"ses-a", worktree:$wt, branch:"lane/lm-repoll-n1",
              summary:"fixture summary"}
              + (if $proof == "" then {} else {proof:$proof} end)]}' > "$1"
}

reset_posts
touch "$GWT/n1-done"
GF="$F/rp1.json"; mk_claimed_graph "$GF" "test -f $GWT/n1-done"; LOG="$F/rp1.log"
write_msgs "$(mkmsg m1 assistant "$(now_ms)" "" "NODE-COMPLETE done: the work.")"
RC="$(run_gx "$GF" "$LOG")"
chk "M2: stuck claimed + PASSING proof re-polls to done (a died-mid-proof executor self-heals)" \
    '[ "$(node_status "$GF")" = "done" ] && [ "$RC" = 0 ] && grep -q "done (proof passed)" "$LOG"'
rm -f "$GWT/n1-done"

reset_posts
GF="$F/rp2.json"; mk_claimed_graph "$GF" "test -f $GWT/never-created"; LOG="$F/rp2.log"
write_msgs "$(mkmsg m1 assistant "$(now_ms)" "" "NODE-COMPLETE done: the work.")"
RC="$(run_gx "$GF" "$LOG")"
chk "M2: stuck claimed + FAILING proof re-polls to proof-failed — never done" \
    '[ "$(node_status "$GF")" = "proof-failed" ] && [ "$RC" = 1 ] && grep -q "PROOF FAILED" "$LOG"'

# L1 — the graph's OWN exit code: zero green with nodes that ended non-done is a
# failure, not a no-op (every non-done lane above now pins rc=1); a 0-node graph
# (nothing was asked) stays exit 0.
GF="$F/empty.json"; printf '{"name":"lm-empty","nodes":[]}' > "$GF"; LOG="$F/empty.log"
RC="$(run_gx "$GF" "$LOG")"
chk "L1: a 0-node no-op graph still exits 0" \
    '[ "$RC" = 0 ] && grep -q "0/0 nodes green" "$LOG"'

# ══ 6. M1 — the dispatch-protocol doc describes the machinery as it is ════════
echo "─ 6 · dispatch-protocol doc agreement (M1)"

DOC="$HERE/../docs/coordinator-dispatch-protocol.md"
chk "M1: doc no longer claims lanes are 'supervised by the adapt runner' (nothing auto-starts one)" \
    '! grep -q "supervised by the adapt runner" "$DOC"'
chk "M1: doc no longer claims 'completion via background notification' (no such path exists)" \
    '! grep -q "background notification" "$DOC"'
chk "M1: doc no longer calls the graph.json ledger Optional (lane-dispatch writes it unconditionally)" \
    '! grep -q "Optional \`graph.json\` ledger" "$DOC"'
chk "M1: doc tells the coordinator to START the runner itself" \
    'grep -q "lane-runner.sh <lane-id>" "$DOC"'
chk "M1: doc states the ledger is written unconditionally" \
    'grep -qi "unconditional" "$DOC"'
chk "M1: lane-dispatch.sh's own header makes the same false claim no more" \
    '! grep -q "background notification" "$HERE/lane-dispatch.sh"'
chk "M1: doc documents the verification ladder — claimed → executor proof → done|proof-failed|unverified" \
    'grep -q "claimed" "$DOC" && grep -q "unverified" "$DOC" && grep -q "proof-failed" "$DOC"'
chk "M1: doc names the dispatch-side declaration (PROOF_CMD env / node spec proof field)" \
    'grep -q "PROOF_CMD" "$DOC" && grep -q "\"proof\"" "$DOC"'

# ══ 7. LANE VISIBILITY — the shared renderer (lanes-snapshot.py) ══════════════
# The /lanes tool (opencode plugin), the lanes.md command, and the live board all
# render from THIS one script — one source of truth for "what is each lane doing",
# tested here so every surface inherits the proof.
echo "─ 7 · lanes-snapshot renderer (shared source for tool + board)"

SNAP="$HERE/lanes-snapshot.py"
VREPO="$F/vrepo"; mkdir -p "$VREPO/.kickoff"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
NOW_S=$(date +%s)
printf '%s\n' "$PORT" > "$VREPO/.kickoff/opencode-bridge.port"
mk_vis_graph() {  # 3 lanes in 3 states: done(old) · running(fresh, respawned, proof) · claimed(claimed+proof)
  # `updated` MUST be the ledger's real shape — an ISO gmtime string (lane-dispatch /
  # lane-runner / graph-executor all write strftime %Y-%m-%dT%H:%M:%SZ), never a raw
  # epoch number. The first draft passed epoch ints here and the minutes check went red
  # because the renderer honestly rendered n/a for a timestamp shape the ledger never writes.
  jq -n --argjson port "$PORT" --arg d "$(iso $((NOW_S-7200)))" --arg r "$(iso $((NOW_S-300)))" --arg c "$(iso $((NOW_S-60)))" '
    {lanes:[
      {id:"lane-0826-090000-111", agent:"reviewer", status:"done",
       worktree:"/tmp/w1", branch:"lane/b1", session:"ses-a", port:$port,
       created:"x", updated:$d},
      {id:"lane-0828-110000-222", agent:"builder", status:"running", respawns:1,
       worktree:"/tmp/w2", branch:"lane/b2", session:"ses-b", port:$port,
       proof:"bash scripts/selftest.sh",
       created:"x", updated:$r},
      {id:"lane-0827-100000-333", agent:"planner", status:"claimed",
       worktree:"/tmp/w3", branch:"lane/b3", session:"ses-c", port:$port,
       proof:"test -f x", created:"x", updated:$c}
     ]}' > "$VREPO/.kickoff/graph.json"
}
snap_out() { python3 "$SNAP" "$VREPO/.kickoff/graph.json" 2>&1; }
snap_json() { python3 "$SNAP" --json "$VREPO/.kickoff/graph.json" 2>/dev/null; }

mk_vis_graph
snap="$(snap_out)"
chk "VIS: the renderer exists and renders one line per lane (3 states → 3 lines)" \
    '[ "$(printf "%s\n" "$snap" | grep -cv "^$")" = 3 ]'
chk "VIS: sort is running → claimed → terminal(done) — live work reads first" \
    'printf "%s\n" "$snap" | sed -n 1p | grep -q "running" && printf "%s\n" "$snap" | sed -n 2p | grep -q "claimed" && printf "%s\n" "$snap" | sed -n 3p | grep -q "done"'
chk "VIS: each line carries agent + short-id (0828-1100 form, not the full pid-suffixed id)" \
    'printf "%s\n" "$snap" | grep -q "0828-1100.*builder" && printf "%s\n" "$snap" | grep -q "0826-0900.*reviewer"'
chk "VIS: minutes-since-updated renders (fresh running lane reads ~5m, done reads ~2h)" \
    'printf "%s\n" "$snap" | grep "running" | grep -qE "(^|[^0-9])5m([^0-9]|$)" && printf "%s\n" "$snap" | grep " done" | grep -qE "(^|[^0-9])120m([^0-9]|$)"'
chk "VIS: a respawned lane shows its respawn count" \
    'printf "%s\n" "$snap" | grep "running" | grep -qE "respawn[^0-9]*1"'
chk "VIS: proof state renders — declared on running/claimed, none needed on done" \
    'printf "%s\n" "$snap" | grep "claimed" | grep -qi "proof" && printf "%s\n" "$snap" | grep "running" | grep -qi "proof"'

vj="$(snap_json)"
chk "VIS: --json is machine-shaped for the board endpoint (lanes[0] is the running lane)" \
    'printf "%s" "$vj" | jq -r ".lanes[0].status" 2>/dev/null | grep -q running'
chk "VIS: --json carries total/shown so a caller can say \"+N more\"" \
    'printf "%s" "$vj" | jq -e ".total == 3 and .shown == 3" >/dev/null'

# the activity probe: messages via the serve API when a port exists (fake serve → 2 msgs)
write_msgs "$(mkmsg vm1 assistant "$(now_ms)" "" "working")" \
           "$(mkmsg vm2 user "$(now_ms)" "" "nudge")"
vj="$(python3 "$SNAP" --json --activity "$VREPO/.kickoff/graph.json" 2>/dev/null)"
chk "VIS: --activity counts messages via the serve API when the port exists" \
    'printf "%s" "$vj" | jq -e ".lanes[] | select(.status==\"running\") | .msgs == 2" >/dev/null'

# the skip-silently contract has a BOUND: the serve is ONE process, so the first failed
# count means every later ask fails too — stop after the first, never 1.5s × N lanes.
# Fixture: a server that ACCEPTS and never answers (the only case the 1.5s timeout
# actually bites; connection-refused fails instantly and never needed the bound).
HANGS="$F/hang"; mkdir -p "$HANGS"
python3 - "$HANGS" <<'PYEOF' &
import os, socket, sys
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(5)
with open(os.path.join(sys.argv[1], "port"), "w") as fh:
    fh.write(str(s.getsockname()[1]))
held = []   # HOLD the accepted sockets: a discarded one is closed → RST → the client
while True: # fails instantly and the timeout we are testing never gets to bite
    held.append(s.accept())
PYEOF
HANG_PID=$!
for i in $(seq 1 50); do [ -s "$HANGS/port" ] && break; sleep 0.1; done
chk "VIS·fixture: the hanging serve stub came up (a dead fixture must fail the suite, not fake a pass)" \
    '[ -s "$HANGS/port" ]'
jq --argjson hp "$(cat "$HANGS/port")" '.lanes = [.lanes[] | .port = $hp]' \
   "$VREPO/.kickoff/graph.json" > "$VREPO/.kickoff/graph.hang.json"
H_T0=$(date +%s%N)
H_OUT="$(timeout 10 python3 "$SNAP" --activity "$VREPO/.kickoff/graph.hang.json" 2>&1)"; H_RC=$?
H_MS=$(( ($(date +%s%N) - H_T0) / 1000000 ))
kill "$HANG_PID" 2>/dev/null; rm -f "$VREPO/.kickoff/graph.hang.json"
chk "VIS: a dead serve still renders ALL lanes, exit 0 (activity is garnish, never a failure)" \
    '[ "$H_RC" = 0 ] && [ "$(printf "%s\n" "$H_OUT" | grep -cv "^$")" = 3 ]'
chk "VIS: that dead-serve bound is ONE timeout, not one per lane (<3.5s for 3 lanes; per-lane shape ≈4.5s)" \
    '[ "$H_MS" -lt 3500 ]'

# the cap: 22 lanes → 20 lines + a "+2 more" tail, context protected
jq '.lanes = (.lanes + [range(0;19) as $i | {id:("lane-0101-0000" + ($i|tostring) + "-x"), agent:"builder", status:"done", worktree:"/tmp/w", branch:"b", session:"s", port:1, created:"x", updated:"2026-01-01T00:00:00Z"}])' \
   "$VREPO/.kickoff/graph.json" > "$VREPO/.kickoff/graph.22.json"
cap_out="$(python3 "$SNAP" "$VREPO/.kickoff/graph.22.json" 2>&1)"
chk "VIS: output caps at 20 lane lines with a +N more tail (caller context protected)" \
    '[ "$(printf "%s\n" "$cap_out" | grep -cv "^$")" = 21 ] && printf "%s\n" "$cap_out" | tail -1 | grep -q "^+2 more$"'

rm -f "$VREPO/.kickoff/graph.22.json"
snap_miss="$(python3 "$SNAP" "$VREPO/.kickoff/graph.missing.json" 2>&1 || true)"
chk "VIS: a missing ledger fails LOUD (non-zero + names the path), never an empty green" \
    'python3 "$SNAP" "$VREPO/.kickoff/graph.missing.json" >/dev/null 2>&1; [ $? -ne 0 ] && printf "%s" "$snap_miss" | grep -q "graph.missing.json"'
# and an empty-but-present ledger renders as zero lanes, exit 0 (a repo with no lanes yet is not an error)
printf '{"lanes":[]}' > "$VREPO/.kickoff/graph.json"
chk "VIS: an empty ledger renders as zero lanes with exit 0" \
    '[ -z "$(python3 "$SNAP" "$VREPO/.kickoff/graph.json" 2>/dev/null)" ] && python3 "$SNAP" "$VREPO/.kickoff/graph.json" >/dev/null 2>&1; [ $? -eq 0 ]'

# ══ 8. LANE VISIBILITY — the opencode surface (lanes_status tool + /lanes command) ══
echo "─ 8 · opencode surface (plugin tool + command)"
# The plugin is a VERIFIED pattern in this engine (memory-search.js ships the same
# shape); the command file was probed VERIFIED on opencode 1.18.24 (`opencode debug
# config` resolved a probe .opencode/command/*.md into a named command). These checks
# pin the CONTRACT the surface must keep, not the engine internals.

PLUGIN="$HERE/../.opencode/plugins/lanes-status.js"
CMDMD="$HERE/../.opencode/command/lanes.md"
chk "OC: the lanes_status plugin exists in .opencode/plugins/ (the memory-search pattern)" \
    '[ -f "$PLUGIN" ]'
chk "OC: it registers a lanes_status tool (the name sessions see)" \
    'grep -q "lanes_status" "$PLUGIN" && grep -q "tool(" "$PLUGIN"'
chk "OC: it renders through the SHARED renderer — one source of line shape, never a re-implementation" \
    'grep -q "lanes-snapshot.py" "$PLUGIN"'
chk "OC: it resolves the ledger from the session project root, like memory-search does" \
    'grep -q "worktree" "$PLUGIN" && grep -q "graph.json" "$PLUGIN"'
chk "OC: it caps its output (caller-context protection, the memory-search cap idiom)" \
    'grep -qE "(6000|truncat)" "$PLUGIN"'
chk "OC: a missing ledger degrades HONESTLY (a returned message, not a thrown tool)" \
    'grep -q "no lane ledger" "$PLUGIN"'
if command -v node >/dev/null 2>&1; then
  chk "OC: the plugin parses (node --check)" \
      'node --check "$PLUGIN"'
fi
chk "OC: the /lanes command ships (probed VERIFIED: .opencode/command resolves on 1.18.24)" \
    '[ -f "$CMDMD" ] && grep -qiE "^(description|agent|model):" "$CMDMD" && grep -q "lanes" "$CMDMD"'
chk "OC: it garnishes with --activity when the bridge port file exists (cheaply derivable; the renderer skips silently)" \
    'grep -q -- "--activity" "$PLUGIN" && grep -q "opencode-bridge.port" "$PLUGIN"'

# ── OC·smoke: drive the tool's execute() for real ────────────────────────────
# The static checks above pin the contract's text; this pins its BEHAVIOR. The plugin
# imports the bare specifier "@opencode-ai/plugin" (the engine provides it at runtime);
# the smoke stubs that module at .opencode/plugins/node_modules/ — the FIRST hit on the
# ESM ancestor walk from the plugin file — so execute() runs exactly as shipped
# (gitignored; the suite creates and removes it). Fixture: a doctored graph with 3
# lanes in 3 states, the suite's live fake serve as the bridge, scripts/ symlinked to
# the real renderer (an adopted repo's shape).
if command -v node >/dev/null 2>&1; then
  SMOKE="$F/ocsmoke"; mkdir -p "$SMOKE/repo/scripts" "$SMOKE/repo/.kickoff" "$SMOKE/repo2/scripts"
  ln -sfn "$HERE/lanes-snapshot.py" "$SMOKE/repo/scripts/lanes-snapshot.py"
  ln -sfn "$HERE/lanes-snapshot.py" "$SMOKE/repo2/scripts/lanes-snapshot.py"
  NM="$HERE/../.opencode/plugins/node_modules/@opencode-ai/plugin"
  mkdir -p "$NM"
  printf '{"name":"@opencode-ai/plugin","version":"0.0.0","type":"module","main":"index.js"}' > "$NM/package.json"
  cat > "$NM/index.js" <<'EOFSTUB'
// the engine's `tool` helper carries a zod-like .schema; the stub mirrors just that
// shape (chainable, self-returning) so the plugin body executes exactly as shipped
const any = new Proxy(function () {}, {
  get: (_t, k) => (k === "describe" ? () => any : any),
  apply: () => any,
})
export const tool = Object.assign((spec) => spec, { schema: any })
EOFSTUB
  iso_sm() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
  S_NOW=$(date +%s)
  jq -n --argjson port "$PORT" \
        --arg d "$(iso_sm $((S_NOW-7200)))" --arg r "$(iso_sm $((S_NOW-300)))" --arg c "$(iso_sm $((S_NOW-60)))" '
    {lanes:[
      {id:"lane-0826-090000-111", agent:"reviewer", status:"done", worktree:"/tmp/w1",
       branch:"lane/b1", session:"ses-a", port:$port, created:"x", updated:$d},
      {id:"lane-0828-110000-222", agent:"builder", status:"running", respawns:1,
       worktree:"/tmp/w2", branch:"lane/b2", session:"ses-b", port:$port,
       proof:"bash x", created:"x", updated:$r},
      {id:"lane-0827-100000-333", agent:"planner", status:"claimed", worktree:"/tmp/w3",
       branch:"lane/b3", session:"ses-c", port:$port, proof:"test -f x", created:"x", updated:$c}
    ]}' > "$SMOKE/repo/.kickoff/graph.json"
  printf '%s\n' "$PORT" > "$SMOKE/repo/.kickoff/opencode-bridge.port"
  write_msgs "$(mkmsg s1 assistant "$(now_ms)" "" "a")" \
             "$(mkmsg s2 user "$(now_ms)" "" "b")" \
             "$(mkmsg s3 assistant "$(now_ms)" "" "c")"
  OC_RUN='import { writeFileSync } from "node:fs";
    import { pathToFileURL } from "node:url";
    const mod = await import(pathToFileURL(process.env.OC_TOOL).href);
    const p = await mod.LanesStatusPlugin({ project: { worktree: process.env.OC_REPO } });
    writeFileSync(process.env.OC_OUT, await p.tool.lanes_status.execute(process.env.OC_ARGS ? JSON.parse(process.env.OC_ARGS) : {}));'
  OC_TOOL="$PLUGIN" OC_REPO="$SMOKE/repo" OC_OUT="$SMOKE/out.txt" OC_ARGS="" \
    node --input-type=module -e "$OC_RUN"
  chk "OC·smoke: 3 lanes in 3 states → 3 lines, running first (the brief's sort, through the tool)" \
      '[ "$(grep -cv "^$" "$SMOKE/out.txt")" = 3 ] && sed -n 1p "$SMOKE/out.txt" | grep -q "running"'
  chk "OC·smoke: the done lane reads proof passed; the respawned running lane carries its respawn count" \
      'grep "reviewer" "$SMOKE/out.txt" | grep -q "proof passed" && grep "builder" "$SMOKE/out.txt" | grep -qE "respawn[^0-9]*1"'
  chk "OC·smoke: activity garnish — msgs counted via the serve API when the bridge port file exists" \
      'grep -qE "[0-9]+ msgs" "$SMOKE/out.txt"'
  OC_TOOL="$PLUGIN" OC_REPO="$SMOKE/repo" OC_OUT="$SMOKE/out_cap.txt" OC_ARGS='{"cap":1}' \
    node --input-type=module -e "$OC_RUN"
  chk "OC·smoke: cap=1 → one lane line + a \"+2 more\" tail (caller context protected)" \
      '[ "$(grep -cv "^$" "$SMOKE/out_cap.txt")" = 2 ] && grep -q "^+2 more" "$SMOKE/out_cap.txt"'
  OC_TOOL="$PLUGIN" OC_REPO="$SMOKE/repo2" OC_OUT="$SMOKE/out_miss.txt" OC_ARGS="" \
    node --input-type=module -e "$OC_RUN"
  chk "OC·smoke: a repo with no ledger → the honest no-lanes message, not a thrown tool" \
      'grep -q "no lane ledger" "$SMOKE/out_miss.txt"'
  rm -rf "$HERE/../.opencode/plugins/node_modules"
fi

# ══ 9. LANE VISIBILITY — the live board (lanes-board.sh) ══════════════════════
# The board is lanes-board.sh on the board-serve discipline: free-port pick, recorded
# assignment (stable URL), fail-soft (WARN + exit 0, never aborts a caller),
# localhost-only by default, tailscale strictly OPT-IN behind --tailnet (never auto).
echo "─ 9 · live board (lanes-board.sh)"

BOARD="$HERE/lanes-board.sh"
chk "BOARD: the script exists and parses (bash -n)" '[ -f "$BOARD" ] && bash -n "$BOARD"'

BREPO="$F/brepo"; mkdir -p "$BREPO/.kickoff"
chk "BOARD: no ledger → warn + exit 0 (the fail-soft contract: a board hiccup never aborts its caller)" \
    'B_OUT="$(REPO_DIR='"$BREPO"' bash '"$BOARD"' 2>&1)"; [ $? = 0 ] && printf "%s" "$B_OUT" | grep -qi "warn\|no lane ledger\|skipping"'

# fixture: the brief's 3-lane / 3-state shape (renderer fixture semantics, board consumer)
iso_b() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
B_NOW=$(date +%s)
jq -n --arg d "$(iso_b $((B_NOW-7200)))" --arg r "$(iso_b $((B_NOW-300)))" --arg c "$(iso_b $((B_NOW-60)))" '
  {lanes:[
    {id:"lane-0826-090000-111", agent:"reviewer", status:"done", worktree:"/tmp/w1",
     branch:"lane/b1", session:"ses-a", port:1, created:"x", updated:$d},
    {id:"lane-0828-110000-222", agent:"builder", status:"running", respawns:1,
     worktree:"/tmp/w2", branch:"lane/b2", session:"ses-b", port:1,
     proof:"bash x", created:"x", updated:$r},
    {id:"lane-0827-100000-333", agent:"planner", status:"claimed", worktree:"/tmp/w3",
     branch:"lane/b3", session:"ses-c", port:1, proof:"test -f x", created:"x", updated:$c}
  ]}' > "$BREPO/.kickoff/graph.json"
B_OUT="$(REPO_DIR="$BREPO" bash "$BOARD" 2>&1)"; B_RC=$?
BREC="$BREPO/.kickoff/state/lanes-board.env"
BPORT="$(grep -E '^LANES_BOARD_LOCAL_PORT=[0-9]+$' "$BREC" 2>/dev/null | cut -d= -f2)"
chk "BOARD: with a ledger it comes up on a free local port and records the assignment (stable URL across restarts)" \
    '[ "$B_RC" = 0 ] && [ -n "$BPORT" ]'
chk "BOARD: the JSON endpoint serves the shared renderer's --json (lanes[0] is the running lane)" \
    'curl -s --max-time 3 "http://127.0.0.1:$BPORT/lanes.json" | jq -r ".lanes[0].status" 2>/dev/null | grep -q running'
chk "BOARD: the endpoint carries what the phone needs (respawns, proof, relative age)" \
    'curl -s --max-time 3 "http://127.0.0.1:$BPORT/lanes.json" | jq -e ".lanes[0] | has(\"respawns\") and has(\"age_min\") and has(\"proof\")" >/dev/null'
chk "BOARD: the page is a no-deps self-refreshing fetch of that endpoint (plain HTML + fetch + interval)" \
    'curl -s --max-time 3 "http://127.0.0.1:$BPORT/" | grep -q "lanes.json" && curl -s --max-time 3 "http://127.0.0.1:$BPORT/" | grep -q "setInterval"'
chk "BOARD: binds 127.0.0.1 ONLY (localhost by default — the tailnet is opt-in, never the world)" \
    'ss -ltn 2>/dev/null | grep -E "127\.0\.0\.1:$BPORT[[:space:]]" | grep -q LISTEN && ! ss -ltn 2>/dev/null | grep -E "(0\.0\.0\.0|\*|\[::\]):$BPORT[[:space:]]" | grep -q .'
chk "BOARD: a second run REUSES the live server — same port, still one listener, and it says so" \
    'B_OUT2="$(REPO_DIR='"$BREPO"' bash '"$BOARD"' 2>&1)"; printf "%s" "$B_OUT2" | grep -qi "already" && [ "$(grep -E "^LANES_BOARD_LOCAL_PORT=" "$BREC" | cut -d= -f2)" = "$BPORT" ] && [ "$(ss -ltn 2>/dev/null | grep -cE "[:.]$BPORT[[:space:]]")" = 1 ]'

# tailscale is STRICTLY opt-in: a stub binary proves it is never touched without the flag,
# and (positive control) IS touched with it — otherwise the stub could pass by never mattering.
FAKETS="$F/fakets"; mkdir -p "$FAKETS"
cat > "$FAKETS/tailscale" <<'EOF'
#!/usr/bin/env bash
touch "$TS_CALLED"    # the marker path comes from the test, never from the script
exit 0
EOF
chmod +x "$FAKETS/tailscale"
BREPO2="$F/brepo2"; mkdir -p "$BREPO2/.kickoff"
printf '{"lanes":[]}' > "$BREPO2/.kickoff/graph.json"
rm -f "$F/ts-called"
REPO_DIR="$BREPO2" TS_CALLED="$F/ts-called" PATH="$FAKETS:$PATH" bash "$BOARD" >/dev/null 2>&1
chk "BOARD: tailscale is NEVER invoked without --tailnet (mapping is opt-in, never auto)" \
    '[ ! -e "$F/ts-called" ]'
REPO_DIR="$BREPO2" TS_CALLED="$F/ts-called" PATH="$FAKETS:$PATH" bash "$BOARD" --tailnet >/dev/null 2>&1
chk "BOARD: --tailnet is the (only) path to the tailnet — positive control, the stub IS reached" \
    '[ -e "$F/ts-called" ]'

# section hygiene: the board servers must not outlive the suite
for _brec in "$BREC" "$BREPO2/.kickoff/state/lanes-board.env"; do
  _bp="$(grep -E '^LANES_BOARD_PID=[0-9]+$' "$_brec" 2>/dev/null | cut -d= -f2)"
  [ -n "$_bp" ] && kill "$_bp" 2>/dev/null
done

# ══ verdict ═══════════════════════════════════════════════════════════════════
echo
printf '◆ %s passed · %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
