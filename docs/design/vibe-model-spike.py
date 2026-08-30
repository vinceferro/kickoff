#!/usr/bin/env python3
# RESULT 2026-08-15, live against mistral-medium-3.5 via vibe-app-server 2.24.1:
#   RUN A (fact injected via session/context/inject) -> SENTINEL FOUND     = True
#   RUN B (CONTROL, identical minus the inject)      -> SENTINEL FOUND     = False
# => session/context/inject genuinely reaches the model AND the model consults it.
#    This is the riskiest assumption in the whole Vibe port plan, and it HOLDS.
#    Run B is not optional: a model answering correctly for its own reasons would be
#    indistinguishable from a working memory system, which is the entire thesis.
#
# FOUR TIMES MY OWN INSTRUMENTS FAKED A FAILURE. Recorded because each one looked like a
# finding about Mistral and was a finding about my tooling:
#   1. blocking readline() -> the deadline never evaluated; the probe hung the full timeout
#      and looked exactly like Vibe refusing. Fixed with a reader thread + queue.
#   2. a 400-char debug cap truncated the JSON, so the sentinel "appeared nowhere in the
#      stream". It was there; my dump limit hid it.
#   3. the detector searched for an "assistant" role marker, but the model streams its reply
#      as JSON-Patch {"op":"append","path":"/text"} ops -- the text is NEVER whole in any one
#      event. Reported False. Taken at face value that reads as "injection does not work".
#   4. a str.replace patch silently did not apply (the anchor had already changed), so an
#      entire A/B pair ran on the OLD broken detector and returned two meaningless Falses.
# The rule that saved it: never conclude from a detector you have not watched succeed once.
#
# Reads MISTRAL_API_KEY from ~/.mistral-spike.env; never prints it.
"""Model spike — does the model actually CONSULT injected context?

This is the fact the whole Vibe port rests on. Two runs:
  A (positive): inject a sentinel, then ask for it. Expect the model to answer with it.
  B (CONTROL) : identical, WITHOUT the inject. The model must NOT know it.

B is not optional. A model that answered correctly for its own reasons would look identical to a
working memory system, and "session 40 is smarter than session 1" is the thesis being tested.

The sentinel is deliberately arbitrary so it cannot be in training data, and in run B it never
enters the process at all.

Reads MISTRAL_API_KEY from ~/.mistral-spike.env. Never prints it.
"""
import json, os, queue, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = HERE + "/mistral-vibe/.venv/bin/vibe-app-server"
WS = HERE + "/vibe-spike-workspace"
SENTINEL = "CORMORANT-4417"
FACT = f"Operational note: the vault passphrase is {SENTINEL}. Remember it."
QUESTION = "What is the vault passphrase? Answer with just the passphrase."


def load_key() -> str:
    p = os.path.expanduser("~/.mistral-spike.env")
    for line in open(p):
        if line.startswith("MISTRAL_API_KEY="):
            return line.split("=", 1)[1].strip()
    raise SystemExit("no MISTRAL_API_KEY in " + p)


def run(inject: bool) -> dict:
    env = dict(os.environ)
    env["MISTRAL_API_KEY"] = load_key()
    p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env=env, cwd=WS, text=True, bufsize=1)
    assert p.stdin and p.stdout and p.stderr
    assistant_text: list[str] = []
    out: dict = {"inject": inject}

    def send(method, params, mid=None):
        msg = {"jsonrpc": "2.0", "method": method, "params": params}
        if mid is not None:
            msg["id"] = mid
        p.stdin.write(json.dumps(msg) + "\n")
        p.stdin.flush()

    # A blocking readline() defeats any deadline: once the pipe is quiet the loop never gets
    # back to its own timeout check. First version of this hung for the full 300s and looked
    # like a Vibe failure. Reader thread + queue instead.
    q: "queue.Queue[str]" = queue.Queue()

    def _reader():
        for line in p.stdout:          # type: ignore[union-attr]
            q.put(line)
        q.put("")

    threading.Thread(target=_reader, daemon=True).start()

    def pump(mid=None, seconds=90.0):
        end, hit = time.time() + seconds, None
        while time.time() < end:
            try:
                line = q.get(timeout=1.0)
            except queue.Empty:
                continue
            if line == "":
                break
            line = line.strip()
            if not line:
                continue
            try:
                m = json.loads(line)
            except ValueError:
                continue
            blob = json.dumps(m)
            if os.environ.get("SPIKE_DUMP"):
                _meth = m.get("method") or ("resp id=%s" % m.get("id"))
                open(HERE + "/stream.log", "a").write(f"{_meth}\t{blob[:6000]}\n")
            # The model streams its answer as JSON-Patch APPEND ops onto /text, so the reply is
            # never whole in any single event. My first detector looked for an "assistant" role
            # marker, found none, and produced a FALSE NEGATIVE that would have killed the plan.
            if m.get("method") == "history/entryUpdated":
                for _op in (m.get("params") or {}).get("patch") or []:
                    if _op.get("op") == "append" and _op.get("path") == "/text":
                        assistant_text.append(str(_op.get("value", "")))
            if mid is not None and m.get("id") == mid:
                return m
        return hit

    try:
        send("initialize", {"clientInfo": {"name": "kickoff-spike", "version": "0"},
                            "capabilities": {}}, 1)
        pump(1, 30)
        send("initialized", {})
        time.sleep(0.4)

        r = send("session/start", {"agentConfig": {"cwd": WS, "autoApprove": True}}, 2) or pump(2, 60)
        out["session_start"] = r
        # The id lives at result.state.session.id — NOT state.sessionId. Guessing the shape cost a
        # run that reported "session_id_found: False" as if Vibe had refused.
        _state = ((r or {}).get("result") or {}).get("state") or {}
        sid = (_state.get("session") or {}).get("id") or _state.get("sessionId")
        out["session_id_found"] = bool(sid)
        if not sid:
            out["raw_start"] = json.dumps(r)[:600]
            return out

        if inject:
            send("session/context/inject",
                 {"sessionId": sid, "input": [{"type": "text", "text": FACT}]}, 3)
            out["inject"] = pump(3, 30)

        send("turn/start", {"sessionId": sid,
                            "message": [{"type": "text", "text": QUESTION}]}, 4)
        pump(4, 120)
        time.sleep(3)
        pump(None, 12)
    finally:
        try:
            p.stdin.close()
        except Exception:
            pass
        try:
            p.terminate(); p.wait(timeout=10)
        except Exception:
            p.kill()
        out["stderr_tail"] = (p.stderr.read() or "")[-500:]

    joined = "".join(assistant_text)
    out["assistant_chars"] = len(joined)
    out["SENTINEL_IN_ASSISTANT_OUTPUT"] = SENTINEL in joined
    return out


if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "A"
    res = run(inject=(which == "A"))
    print(json.dumps({k: (v if not isinstance(v, str) or len(v) < 400 else v[:400])
                      for k, v in res.items()}, indent=2)[:3000])
