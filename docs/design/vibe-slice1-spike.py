#!/usr/bin/env python3
# RESULT, 2026-08-19 (vibe-app-server 2.24.1, engine fork ~/vibe-kickoff @ 28d9db4,
#                     model pinned to devstral-small, ~60k prompt / 170 completion tokens total):
#   PASS  RUN 1 inject-then-ask: turn status='completed'; reply='The launch code is BLUEFIN.'
#   PASS  RUN 2 approval callback: 1 callback/call received, 1 accepted by callback/result
#   PASS  RUN 3 RED control, no inject: reply="I don't have access to any launch code information."
#   PASS  RUN 4 RED control, no capabilities: attempt entries=['effect', 'callback'];
#         files created=[]; turn status='failed'; error='Client does not support approval callbacks'
#   SPIKE GREEN (exit 0)
#
# FOUR THINGS THE RUNS SETTLED THAT SOURCE READING DID NOT:
#   - The answer method is `callback/result`. `callback/respond` (the upstream ADR's name) returns
#     the SAME method_not_found as a method I invented — it does not exist. Probed, not read.
#   - The server->client `callback/call` is a REQUEST with its own id, numbered from 1 in the
#     server's own sequence. Answering it takes TWO messages: a JSON-RPC result acknowledging
#     delivery ({callbackId, accepted:true}), then a separate `callback/result` request carrying
#     the decision. Ack only, or decision only, is not an answer.
#   - Injected context SURVIVES into a later turn: in RUN 2 the model derived the filename
#     `touch gated-bluefin.txt` from a fact injected before turn 1. Observed in the approval
#     payload, so it costs no extra model call to see.
#   - The empty-capabilities gate FAILS CLOSED and loudly: the tool effect is raised, the callback
#     entry is opened, delivery raises RuntimeError, and the turn ends `failed`. Nothing executes.
"""vibe-slice1-spike.py — the Slice 1 go/no-go spike for the Mistral Vibe port.

The whole port plan rests on three UNOBSERVED facts. This file observes them, against a live
`vibe-app-server` and a live model. Source reading does not count; that is the point of the slice.

    A. an external process can drive a live Vibe session end to end
    B. it can push a fact into that session BEFORE the model thinks
       (`session/context/inject`) and the model uses it
    C. it receives an approval `callback/call` when the agent hits a gated tool, and can answer it

FOUR RUNS, two of which are RED controls — a check never watched fail proves nothing:

    RUN 1  GREEN  inject the sentinel, ask for it back      PASS = reply contains BLUEFIN
    RUN 2  GREEN  same session, gated shell command         PASS = callback/call arrives, we answer
    RUN 3  RED    identical to run 1 with the inject GONE   PASS = the model does NOT know BLUEFIN
    RUN 4  RED    initialize with EMPTY capabilities        PASS = the gate errors/refuses,
                  then hit the same gated command                  the command does NOT run

Run 3 is what makes run 1 mean anything: if a model with no inject still says BLUEFIN, run 1 was
measuring the prompt, not the injection. Run 4 is a security control: a gate that silently
auto-approves when the client declared no approval capability is worse than no gate.

Usage (default runs all four; the flags exist so any single run is reproducible on its own):

    ./vibe-slice1-spike.py                  # all four
    ./vibe-slice1-spike.py --no-inject      # RUN 3 alone
    ./vibe-slice1-spike.py --no-callbacks   # RUN 4 alone

Needs MISTRAL_API_KEY in the environment or in --key-file (default ~/.mistral-spike.env). The key
is never printed and never written anywhere. Exit code is non-zero if any run fails its expectation.

THREE PROTOCOL TRAPS, inherited from scripts/vibe-run.py — all three cost a debugging session:

  1. THE REPLY IS STREAMED AS JSON-PATCH and exists in no single event. Assistant text arrives as
     history/entryUpdated {"op":"append","path":"/content/0/text"} fragments; reasoning arrives as
     the same op on "/text". Read the wrong path and you capture the model thinking out loud.
  2. A FAILED TURN STILL EXITS 0. Adjudicate on turn/completed's status, never on the process.
  3. THE HANDSHAKE IS TWO STEPS. `initialize` is a request; `initialized` is a NOTIFICATION with no
     id, and only that flips the server to INITIALIZED. Skip it and every later call fails with
     not_initialized, which is indistinguishable from the method not existing.
"""
from __future__ import annotations

import argparse
import json
import os
import queue
import subprocess
import sys
import threading
import time

SENTINEL = "BLUEFIN"
FACT = f"Operational note for this session: the launch code is {SENTINEL}."
# Point VIBE_APP_SERVER at your own checkout's binary; the default resolves under $HOME
# so the file carries no machine path.
DEFAULT_SERVER = os.environ.get(
    "VIBE_APP_SERVER",
    os.path.expanduser("~/vibe-kickoff/.venv/bin/vibe-app-server"),
)
SCRATCH = os.environ.get("SPIKE_SCRATCH", "/tmp/vibe-slice1-spike")


class Conn:
    """JSON-RPC 2.0 over the app-server's stdio, in both directions.

    Both directions matter: `callback/call` is a REQUEST FROM THE SERVER carrying its own id, so a
    client that only ever reads responses deadlocks the moment a tool needs approval.
    """

    def __init__(self, server: str, cwd: str, env: dict, log: list):
        self.log = log
        self.errfile = os.path.join(cwd, "server.stderr")
        self.proc = subprocess.Popen(
            [server], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=open(self.errfile, "w"), env=env, cwd=cwd, text=True, bufsize=1,
        )
        self.q: queue.Queue = queue.Queue()
        self._id = 1000
        self.closed = False
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self) -> None:
        for line in self.proc.stdout:            # type: ignore[union-attr]
            self.q.put(line)
        self.q.put(None)

    def send(self, obj: dict) -> None:
        self.proc.stdin.write(json.dumps(obj) + "\n")   # type: ignore[union-attr]
        self.proc.stdin.flush()                          # type: ignore[union-attr]

    def request(self, method: str, params: dict) -> int:
        self._id += 1
        self.send({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params})
        return self._id

    def notify(self, method: str, params: dict) -> None:
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def events(self, timeout: float):
        """Yield ('request'|'notify'|'response', msg) until timeout or the server closes stdout."""
        end = time.time() + timeout
        while time.time() < end:
            try:
                line = self.q.get(timeout=0.5)
            except queue.Empty:
                continue
            if line is None:
                self.closed = True
                self.log.append("server closed stdout")
                return
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if msg.get("method") and msg.get("id") is not None:
                yield "request", msg
            elif msg.get("method"):
                yield "notify", msg
            else:
                yield "response", msg

    def close(self) -> dict:
        """Close stdin mid-flight and watch what the server does — that is itself an observation."""
        t0 = time.time()
        try:
            self.proc.stdin.close()                      # type: ignore[union-attr]
        except Exception:
            pass
        try:
            rc = self.proc.wait(timeout=8)
            how = f"exited {rc} on stdin close after {time.time() - t0:.1f}s"
        except subprocess.TimeoutExpired:
            self.proc.kill()
            rc = self.proc.wait(timeout=5)
            how = "did NOT exit within 8s of stdin close; killed"
        tail = ""
        if os.path.exists(self.errfile):
            tail = open(self.errfile, errors="replace").read()[-600:]
        return {"exit": how, "stderr_tail": tail}


def answer_callback(conn: Conn, sid: str, req: dict, log: list) -> str:
    """Answer an approval callback: ack the server's request, then send the decision separately."""
    cb = (req.get("params") or {}).get("callback") or {}
    cid = cb.get("callbackId") or cb.get("callback_id") or ""
    detail = cb.get("detail") or {}
    log.append(f"callback/call  kind={detail.get('kind')!r} title={cb.get('title')!r}")
    log.append("  effect: " + json.dumps(detail.get("effect"))[:300])
    # Step 1 — the JSON-RPC response to the server's own request. Delivery ack only.
    conn.send({"jsonrpc": "2.0", "id": req["id"],
               "result": {"callbackId": cid, "accepted": True}})
    # Step 2 — the decision travels as a SEPARATE client request. The upstream ADR calls this
    # `callback/respond`; the running server's method catalogue says `callback/result`.
    conn.request("callback/result", {
        "sessionId": sid,
        "result": {"callbackId": cid,
                   "output": {"type": "approval",
                              "decision": {"type": "deny"},
                              "feedback": "denied by the slice-1 spike"}},
    })
    log.append("  -> answered via callback/result (decision=deny)")
    return cid


def run_turn(conn: Conn, sid: str, prompt: str, *, timeout: float, answer_cbs: bool,
             log: list) -> dict:
    """Start one turn, assemble the streamed reply, service callbacks, stop on turn/completed."""
    conn.request("turn/start", {"sessionId": sid,
                                "message": [{"type": "text", "text": prompt}]})
    answer: list[str] = []
    kind: dict[str, str] = {}
    out: dict = {"answer": "", "turn": None, "callbacks": [], "acks": [], "errors": [],
                 "entries": []}
    for typ, msg in conn.events(timeout):
        if typ == "request":
            if msg.get("method") == "callback/call":
                out["callbacks"].append(msg)
                if answer_cbs:
                    answer_callback(conn, sid, msg, log)
                else:
                    log.append("callback/call arrived but this run does not answer it")
            else:
                conn.send({"jsonrpc": "2.0", "id": msg["id"],
                           "error": {"code": -32601, "message": "not implemented by the spike"}})
            continue
        if typ == "response":
            if msg.get("error"):
                out["errors"].append(msg["error"])
                log.append(f"response error: {json.dumps(msg['error'])[:220]}")
            elif isinstance(msg.get("result"), dict) and msg["result"].get("accepted"):
                out["acks"].append(msg["result"])
                log.append(f"callback/result ack: {json.dumps(msg['result'])[:120]}")
            continue
        method, params = msg.get("method"), msg.get("params") or {}
        if method == "history/entryAdded":
            e = params.get("entry") or {}
            # Keep a summary of every entry: the RED controls need POSITIVE evidence that the run
            # actually happened. "No file was created" also describes a session that never ran.
            out["entries"].append({"type": e.get("type"), "role": e.get("role"),
                                   "title": e.get("title"), "raw": json.dumps(e)[:600]})
            if e.get("id"):
                kind[e["id"]] = ("assistant" if e.get("role") == "assistant"
                                 else "reasoning" if e.get("type") == "reasoning" else "other")
                # The entry is CREATED CARRYING its first fragment; later tokens are patches.
                if e.get("role") == "assistant":
                    for b in e.get("content") or []:
                        if isinstance(b, dict) and b.get("type") == "text":
                            answer.append(str(b.get("text", "")))
        elif method == "history/entryUpdated":
            k = kind.get(params.get("entryId", ""), "other")
            for op in params.get("patch") or []:
                if op.get("op") != "append":
                    continue
                path = op.get("path") or ""
                if path.startswith("/content/") and path.endswith("/text") \
                        and k in ("assistant", "other"):
                    answer.append(str(op.get("value", "")))
        elif method == "turn/completed":
            out["turn"] = params.get("turn") or params
            break
    out["answer"] = "".join(answer).strip()
    return out


def spike(label: str, *, inject: bool, callbacks: bool, phases: list[str], api_key: str,
          server: str, model: str | None, timeout: float) -> dict:
    ws = os.path.join(SCRATCH, f"ws-{label}")
    os.makedirs(ws, exist_ok=True)
    log: list[str] = []
    env = {k: v for k, v in os.environ.items()}
    env["MISTRAL_API_KEY"] = api_key
    if model:
        env["VIBE_ACTIVE_MODEL"] = model
    conn = Conn(server, ws, env, log)
    res: dict = {"label": label, "log": log, "phases": {}, "workspace": ws}
    try:
        caps = {"callbackKinds": ["approval", "user_input"]} if callbacks else {}
        mid = conn.request("initialize", {"clientInfo": {"name": "kickoff-slice1", "version": "1"},
                                          "capabilities": caps})
        for typ, msg in conn.events(30):
            if typ == "response" and msg.get("id") == mid:
                log.append(f"initialize -> {json.dumps(msg.get('result') or msg.get('error'))[:160]}")
                break
        conn.notify("initialized", {})       # step 2 — without it everything is not_initialized
        time.sleep(0.4)

        mid = conn.request("session/start", {"agentConfig": {
            "cwd": ws, "headless": False, "trustWorkspace": True, "autoApprove": False,
            "maxTurns": 12, "maxPrice": 0.25,
        }})
        sid = None
        for typ, msg in conn.events(60):
            if typ == "response" and msg.get("id") == mid:
                if msg.get("error"):
                    raise RuntimeError(f"session/start: {json.dumps(msg['error'])[:200]}")
                state = (msg.get("result") or {}).get("state") or {}
                sid = (state.get("session") or {}).get("id")
                break
        if not sid:
            raise RuntimeError("session/start returned no session id")
        log.append(f"session/start -> sessionId={sid}")
        res["session_id"] = sid

        if inject:
            mid = conn.request("session/context/inject",
                               {"sessionId": sid, "input": [{"type": "text", "text": FACT}]})
            for typ, msg in conn.events(30):
                if typ == "response" and msg.get("id") == mid:
                    ok = "error" not in msg
                    log.append(f"session/context/inject -> {'ok' if ok else json.dumps(msg['error'])[:200]}")
                    break
        else:
            log.append("session/context/inject SKIPPED (this is the RED control)")

        if "ask" in phases:
            res["phases"]["ask"] = run_turn(
                conn, sid, "What is the launch code? Reply with one short sentence.",
                timeout=timeout, answer_cbs=callbacks, log=log)
        if "gate" in phases:
            # The filename carries the sentinel on purpose: if the injected fact survives into a
            # SECOND turn, the command in the approval payload says so, at no extra model call.
            prompt = ("Use the bash tool to run exactly this command, nothing else: "
                      "touch gated-<code>.txt  — where <code> is the launch code in lowercase. "
                      "If you do not know the launch code, use the word unknown instead."
                      if inject else
                      "Use the bash tool to run exactly this command, nothing else: "
                      "touch gated-proof.txt")
            res["phases"]["gate"] = run_turn(conn, sid, prompt, timeout=timeout,
                                             answer_cbs=callbacks, log=log)
    except Exception as e:                       # noqa: BLE001 — a spike reports, never raises
        res["fatal"] = f"{type(e).__name__}: {e}"
        log.append(f"FATAL {res['fatal']}")
    finally:
        res["shutdown"] = conn.close()
        res["workspace_files"] = sorted(f for f in os.listdir(ws) if f != "server.stderr")
    return res


def verdicts(runs: dict) -> list[tuple[str, bool, str]]:
    """Turn observations into PASS/FAIL. Every expectation is stated before it is checked."""
    v: list[tuple[str, bool, str]] = []
    g = runs.get("green")
    if g:
        ask = (g.get("phases") or {}).get("ask")
        if ask is not None:
            status = (ask.get("turn") or {}).get("status")
            said = SENTINEL.lower() in ask["answer"].lower()
            v.append(("RUN 1 inject-then-ask", bool(said and status == "completed"),
                      f"turn status={status!r}; reply={ask['answer'][:160]!r}"))
        gate = (g.get("phases") or {}).get("gate")
        if gate is not None:
            got = len(gate["callbacks"])
            acked = len(gate["acks"])
            v.append(("RUN 2 approval callback", bool(got and acked),
                      f"{got} callback/call received, {acked} accepted by callback/result; "
                      f"turn status={(gate.get('turn') or {}).get('status')!r}"))
    r = runs.get("noinject")
    if r:
        ask = (r.get("phases") or {}).get("ask")
        if ask is not None:
            said = SENTINEL.lower() in ask["answer"].lower()
            status = (ask.get("turn") or {}).get("status")
            # An empty answer also contains no sentinel. Demand the positive first: the turn
            # completed and the model said SOMETHING. Otherwise this control passes on emptiness
            # and validates nothing about RUN 1.
            ran_at_all = status == "completed" and len(ask["answer"]) > 10
            v.append(("RUN 3 RED control, no inject", bool(ran_at_all and not said),
                      f"turn status={status!r}; reply={ask['answer'][:200]!r}"))
    r = runs.get("nocb")
    if r:
        gate = (r.get("phases") or {}).get("gate")
        if gate is not None:
            ran = [f for f in r["workspace_files"] if f.startswith("gated-")]
            delivered = len(gate["callbacks"])
            # Same trap, other side: "no file was created" also describes a session that never
            # got as far as trying. Require observed evidence of the attempt — the server still
            # RAISES the tool effect and OPENS the callback entry; only delivery is refused.
            attempted = [e["type"] for e in gate["entries"] if e["type"] in ("effect", "callback")]
            terr = ((gate.get("turn") or {}).get("error") or {}).get("message")
            # PASS = the agent tried, and the gated command did NOT execute. A file on disk is the
            # only proof that cannot be argued with; the turn's own prose can claim anything.
            v.append(("RUN 4 RED control, no capabilities", bool(attempted and not ran),
                      f"attempt entries={attempted}; files created={ran}; "
                      f"callback/call delivered={delivered}; "
                      f"turn status={(gate.get('turn') or {}).get('status')!r}; "
                      f"turn error={terr!r}"))
    return v


def load_key(path: str) -> str:
    if os.environ.get("MISTRAL_API_KEY"):
        return os.environ["MISTRAL_API_KEY"]
    if os.path.exists(path):
        for line in open(path):
            if line.startswith("MISTRAL_API_KEY="):
                val = line.split("=", 1)[1].strip()
                if val:
                    return val
    raise SystemExit(f"no MISTRAL_API_KEY in the environment or {path}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--no-inject", action="store_true", help="RUN 3 alone: the RED control")
    ap.add_argument("--no-callbacks", action="store_true", help="RUN 4 alone: empty capabilities")
    ap.add_argument("--server", default=DEFAULT_SERVER)
    ap.add_argument("--key-file", default=os.path.expanduser("~/.mistral-spike.env"))
    ap.add_argument("--model", default="devstral-small", help="alias pinned via VIBE_ACTIVE_MODEL")
    ap.add_argument("--timeout", type=float, default=180.0)
    ap.add_argument("--json-out", help="write the full observation log here")
    a = ap.parse_args()

    key = load_key(a.key_file)
    os.makedirs(SCRATCH, exist_ok=True)
    common = dict(api_key=key, server=a.server, model=a.model, timeout=a.timeout)
    runs: dict = {}
    if a.no_inject and not a.no_callbacks:
        runs["noinject"] = spike("noinject", inject=False, callbacks=True,
                                 phases=["ask"], **common)
    elif a.no_callbacks and not a.no_inject:
        runs["nocb"] = spike("nocb", inject=False, callbacks=False, phases=["gate"], **common)
    elif a.no_inject and a.no_callbacks:
        runs["nocb"] = spike("nocb", inject=False, callbacks=False,
                             phases=["ask", "gate"], **common)
    else:
        runs["green"] = spike("green", inject=True, callbacks=True,
                              phases=["ask", "gate"], **common)
        runs["noinject"] = spike("noinject", inject=False, callbacks=True,
                                 phases=["ask"], **common)
        runs["nocb"] = spike("nocb", inject=False, callbacks=False, phases=["gate"], **common)

    for name, r in runs.items():
        print(f"\n===== {name} =====")
        for line in r["log"]:
            print("  " + line)
        print(f"  workspace files: {r['workspace_files']}")
        print(f"  shutdown: {r['shutdown']['exit']}")
        if r.get("fatal"):
            print(f"  FATAL: {r['fatal']}")
        if r["shutdown"]["stderr_tail"].strip():
            print("  stderr tail: " + r["shutdown"]["stderr_tail"][-400:].replace("\n", " | "))

    print("\n===== VERDICTS =====")
    vs = verdicts(runs)
    ok = True
    for name, passed, why in vs:
        ok = ok and passed
        print(f"{'PASS' if passed else 'FAIL'}  {name}: {why}")
    if not vs:
        print("FAIL  no verdicts produced — nothing was observed")
        ok = False
    print(f"\nSPIKE {'GREEN' if ok else 'RED'}")
    if a.json_out:
        with open(a.json_out, "w") as fh:
            json.dump({"runs": runs, "verdicts": vs}, fh, indent=2, default=str)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
