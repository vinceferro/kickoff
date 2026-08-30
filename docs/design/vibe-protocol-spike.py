#!/usr/bin/env python3
# RESULT, 2026-08-15 (vibe-app-server 2.24.1, NO api key, NO model call, NO spend):
#   1_initialize          OK     serverInfo vibe-app-server 2.24.1
#   2_bogus_RED_CONTROL   ERROR  method_not_found   <- the control fires
#   3_context_inject      ERROR  conflict "Start, resume, or continue a session before using this method"
#   4_turn_steer          ERROR  conflict (same)
#   5_turn_interrupt      ERROR  conflict (same)
# The CONTRAST is the proof: an unknown method is method_not_found, while the three the plan
# depends on fail on missing SESSION STATE -- so they are routed and real. Four undifferentiated
# errors would have proven nothing, which is why the control is not optional.
#
# TWO CORRECTIONS TO THE PLAN, both found by running it:
#   - the handshake is TWO steps: initialize (request) then `initialized` (NOTIFICATION, no id).
#     Only the notification flips INITIALIZE_RECEIVED -> INITIALIZED (server.py:1023-1028).
#     Without it every later call returns not_initialized, which reads exactly like a missing method.
#   - initialize REJECTS protocolVersion and a top-level callbackKinds (extra="forbid").
#     The real shape is {clientInfo:{name,version}, capabilities:{callbackKinds:[...]}}.
"""Protocol spike v2 — no API key, no model call, no spend.

Proves the plumbing the whole Vibe plan rests on: the app-server starts, completes a handshake, and
ROUTES the three methods we depend on. The discriminator is the ERROR SHAPE — an unknown method must
fail differently from a real method called with a bad session. Without that contrast, "no crash"
would look like "supported".
"""
import json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = HERE + "/mistral-vibe/.venv/bin/vibe-app-server"
WS = HERE + "/vibe-spike-workspace"


def main() -> int:
    os.makedirs(WS, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if k != "MISTRAL_API_KEY"}
    p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env=env, cwd=WS, text=True, bufsize=1)
    assert p.stdin and p.stdout and p.stderr

    def call(method, params, mid, timeout=25.0):
        p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": mid, "method": method,
                                  "params": params}) + "\n")
        p.stdin.flush()
        end = time.time() + timeout
        while time.time() < end:
            line = p.stdout.readline()
            if not line:
                return {"_": "server closed stdout"}
            line = line.strip()
            if not line:
                continue
            try:
                m = json.loads(line)
            except ValueError:
                continue
            if m.get("id") == mid:
                return m
        return {"_": "timeout"}

    out = {}
    try:
        out["1_initialize"] = call("initialize", {
            "clientInfo": {"name": "kickoff-spike", "version": "0"},
            "capabilities": {"callbackKinds": ["approval"]},
        }, 1)

        # STEP 2 OF THE HANDSHAKE — an LSP-style `initialized` NOTIFICATION (no id).
        # server.py:1023-1028: only this flips INITIALIZE_RECEIVED -> INITIALIZED. Without it every
        # subsequent call returns not_initialized, which reads exactly like "the method is missing".
        p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "initialized", "params": {}}) + "\n")
        p.stdin.flush()
        time.sleep(0.5)

        # RED CONTROL, now AFTER a successful handshake so it tests unknown-method routing
        # rather than the not-initialized ordering guard (which is what tripped v1).
        out["2_bogus_RED_CONTROL"] = call("kickoff/definitelyNotReal", {}, 2, 12)

        # The three the plan depends on. A "session not found"-style error PROVES the method is
        # routed; "method not found" would prove it is not.
        out["3_context_inject"] = call("session/context/inject",
                                       {"sessionId": "no-such-session", "content": "x"}, 3, 12)
        out["4_turn_steer"] = call("turn/steer",
                                   {"sessionId": "no-such-session", "content": "x"}, 4, 12)
        out["5_turn_interrupt"] = call("turn/interrupt", {"sessionId": "no-such-session"}, 5, 12)
    finally:
        try:
            p.stdin.close()
        except Exception:
            pass
        try:
            p.terminate(); p.wait(timeout=10)
        except Exception:
            p.kill()
        out["stderr_tail"] = (p.stderr.read() or "")[-600:]

    for k, v in out.items():
        if k == "stderr_tail":
            continue
        err = (v or {}).get("error")
        if err:
            print(f"{k:26} ERROR code={err.get('code')!r:24} {str(err.get('message'))[:60]}")
        elif "result" in (v or {}):
            print(f"{k:26} OK    {json.dumps(v['result'])[:70]}")
        else:
            print(f"{k:26} {json.dumps(v)[:70]}")
    if out.get("stderr_tail"):
        print("\nstderr:", out["stderr_tail"][:300])
    return 0


if __name__ == "__main__":
    sys.exit(main())
