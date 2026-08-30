#!/usr/bin/env python3
"""vibe-run.py — run one task on a Mistral Vibe session and return the answer.

The dual-engine driver. Kickoff's coordinator (on Claude Code) uses this to dispatch work to a
Mistral agent and relay the result, without a second bot or a router existing yet.

    vibe-run.py --task "read README.md and summarise it in three bullets"
    vibe-run.py --task "..." --context "recalled memory the agent should know first"
    vibe-run.py --task "..." --session-id <id>      # continue an existing session
    vibe-run.py --task "..." --json                 # machine-readable, for a caller

Requires MISTRAL_API_KEY — from the environment, or --key-file (never printed, never logged).

THREE THINGS THIS GETS RIGHT, each learned the hard way (see docs/design/vibe-model-spike.py):

  1. THE REPLY IS STREAMED AS JSON-PATCH, never emitted whole. Vibe sends
     history/entryUpdated with {"op":"append","path":"/text","value":"…"} fragments, so the text
     exists in no single event. A reader that waits for a finished assistant message gets nothing
     and reports it as "the model said nothing" — a false negative that reads like a broken engine.

  2. A FAILED TURN STILL EXITS 0. Vibe swallows a failed turn into turn/completed with a status and
     the process exits cleanly (vibe/app_server/_turns.py:493-497). Anything adjudicating on the
     exit code reports GREEN on a corpse. This reads turn/completed and fails loudly on a non-ok
     status, surfacing the TurnErrorCode.

  3. THE HANDSHAKE IS TWO STEPS. `initialize` is a request; `initialized` is a NOTIFICATION with no
     id, and only that flips the server to INITIALIZED (server.py:1023-1028). Skip it and every
     later call returns not_initialized, which is indistinguishable from the method not existing.
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

DEFAULT_SERVER = os.environ.get("VIBE_APP_SERVER", "vibe-app-server")


class VibeError(RuntimeError):
    pass


class VibeSession:
    def __init__(self, server: str, cwd: str, api_key: str, timeout: float = 300.0):
        env = dict(os.environ)
        env["MISTRAL_API_KEY"] = api_key
        self.timeout = timeout
        self._next_id = 0
        self.proc = subprocess.Popen(
            [server], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env, cwd=cwd, text=True, bufsize=1,
        )
        if not (self.proc.stdin and self.proc.stdout):
            raise VibeError("could not open pipes to the app-server")
        # A blocking readline() makes any deadline unreachable: on a quiet pipe the loop never
        # returns to its own timeout check. Reader thread + queue instead.
        self.q: queue.Queue[str] = queue.Queue()
        threading.Thread(target=self._read_loop, daemon=True).start()

    def _read_loop(self) -> None:
        assert self.proc.stdout
        for line in self.proc.stdout:
            self.q.put(line)
        self.q.put("")

    def _send(self, method: str, params: dict, mid: int | None = None) -> None:
        assert self.proc.stdin
        msg: dict = {"jsonrpc": "2.0", "method": method, "params": params}
        if mid is not None:
            msg["id"] = mid
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()

    def call(self, method: str, params: dict, timeout: float | None = None) -> dict:
        self._next_id += 1
        mid = self._next_id
        self._send(method, params, mid)
        for msg in self._drain(timeout or self.timeout):
            if msg.get("id") == mid:
                if msg.get("error"):
                    raise VibeError(f"{method}: {msg['error'].get('code')} "
                                    f"{msg['error'].get('message')}")
                return msg.get("result") or {}
        raise VibeError(f"{method}: no response within {timeout or self.timeout}s")

    def notify(self, method: str, params: dict) -> None:
        self._send(method, params)

    def _drain(self, seconds: float):
        end = time.time() + seconds
        while time.time() < end:
            try:
                line = self.q.get(timeout=1.0)
            except queue.Empty:
                continue
            if line == "":
                return
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except ValueError:
                continue

    def close(self) -> str:
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.terminate()
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()
        return (self.proc.stderr.read() if self.proc.stderr else "") or ""


def run_task(task: str, *, cwd: str, api_key: str, context: str | None = None,
             session_id: str | None = None, server: str = DEFAULT_SERVER,
             timeout: float = 300.0) -> dict:
    s = VibeSession(server, cwd, api_key, timeout)
    answer: list[str] = []
    reasoning: list[str] = []
    out: dict = {"ok": False, "answer": "", "session_id": session_id, "error": None}
    try:
        s.call("initialize", {"clientInfo": {"name": "kickoff-vibe-run", "version": "1"},
                              "capabilities": {}}, 30)
        s.notify("initialized", {})          # step 2 — without this everything is not_initialized
        time.sleep(0.3)

        if session_id:
            res = s.call("session/resume", {"sessionId": session_id}, 60)
        else:
            res = s.call("session/start", {"agentConfig": {"cwd": cwd, "autoApprove": True}}, 60)
        state = res.get("state") or {}
        sid = (state.get("session") or {}).get("id") or state.get("sessionId")
        if not sid:
            raise VibeError("no session id in the start/resume response")
        out["session_id"] = sid

        if context:
            s.call("session/context/inject",
                   {"sessionId": sid, "input": [{"type": "text", "text": context}]}, 60)

        s._next_id += 1
        turn_id = s._next_id
        s._send("turn/start", {"sessionId": sid,
                               "message": [{"type": "text", "text": task}]}, turn_id)

        status = None
        # Vibe emits TWO streams of appended text and they must not be confused:
        #   reasoning entries      patch  /text            (the chain of thought, 37 ops in a
        #                                                   typical short turn)
        #   assistant message      patch  /content/N/text  (the actual answer, often 2 ops)
        # Capturing /text yields the model THINKING OUT LOUD and reads like a rambling answer.
        # entryAdded tells us which id is which; only then does a patch mean anything.
        kind: dict[str, str] = {}
        for msg in s._drain(timeout):
            method = msg.get("method")
            params = msg.get("params") or {}
            if method == "history/entryAdded":
                e = params.get("entry") or {}
                if e.get("id"):
                    kind[e["id"]] = "assistant" if e.get("role") == "assistant" else \
                                    ("reasoning" if e.get("type") == "reasoning" else "other")
                    # The entry is CREATED CARRYING its first fragment; only later tokens arrive as
                    # patches. Seeding from patches alone silently drops the opening words —
                    # "The capital of France is Paris." arrived as "France is Paris." and reads as
                    # a terse model rather than a lossy reader.
                    if e.get("role") == "assistant":
                        for block in e.get("content") or []:
                            if isinstance(block, dict) and block.get("type") == "text":
                                answer.append(str(block.get("text", "")))
            elif method == "history/entryUpdated":
                k = kind.get(params.get("entryId", ""), "other")
                for op in params.get("patch") or []:
                    if op.get("op") != "append":
                        continue
                    path = op.get("path") or ""
                    # Fall back to the PATH SHAPE when the id is unknown: a /content/N/text patch
                    # only ever belongs to a message entry. Without this the first fragment is
                    # dropped whenever its patch is processed before the entryAdded that names it
                    # — which silently truncated "The capital of France is Paris." to "capital
                    # of France is Paris." Losing one leading token is exactly the kind of defect
                    # that never looks like a bug, it just looks like the model being terse.
                    is_msg = path.startswith("/content/") and path.endswith("/text")
                    if is_msg and k in ("assistant", "other"):
                        answer.append(str(op.get("value", "")))
                    elif k == "reasoning" and path == "/text":
                        reasoning.append(str(op.get("value", "")))
            elif method == "turn/completed":
                status = (msg.get("params") or {}).get("status") or (msg.get("params") or {})
                break
            elif msg.get("id") == turn_id and msg.get("error"):
                raise VibeError(f"turn/start: {msg['error'].get('message')}")

        out["answer"] = "".join(answer).strip()
        out["reasoning_chars"] = len("".join(reasoning))
        out["turn_status"] = status
        # A failed turn still exits 0 — adjudicate on the STATUS, never on the process.
        # Read the FIELDS. A substring scan over the serialised status matches the KEY name
        # "error" and so flags `"error": null` — a success — as a failure. That is the same
        # uncalibrated-instrument defect as [[a-broken-detector-fakes-a-finding-about-the-system]],
        # just inverted: there the detector could not pass, here it could not fail cleanly.
        turn = (status or {}).get("turn") or {}
        tstatus = turn.get("status") or (status or {}).get("status")
        terror = turn.get("error", (status or {}).get("error"))
        if status is None:
            out["error"] = f"no turn/completed within {timeout}s (answer may be partial)"
        elif terror:
            out["error"] = f"turn failed: {json.dumps(terror)[:300]}"
        elif tstatus and tstatus != "completed":
            out["error"] = f"turn ended with status {tstatus!r}"
        else:
            out["ok"] = True
    except VibeError as e:
        out["error"] = str(e)
    finally:
        err = s.close()
        if err.strip() and not out["ok"]:
            out["stderr_tail"] = err[-400:]
    return out


def load_key(key_file: str | None) -> str:
    if os.environ.get("MISTRAL_API_KEY"):
        return os.environ["MISTRAL_API_KEY"]
    for cand in ([key_file] if key_file else []) + [os.path.expanduser("~/.mistral-spike.env")]:
        if cand and os.path.exists(cand):
            for line in open(cand):
                if line.startswith("MISTRAL_API_KEY="):
                    v = line.split("=", 1)[1].strip()
                    if v:
                        return v
    raise SystemExit("no MISTRAL_API_KEY in the environment or a key file "
                     "(pass --key-file, or export it)")


def main() -> int:
    ap = argparse.ArgumentParser(description="Run one task on a Mistral Vibe session.")
    ap.add_argument("--task", required=True)
    ap.add_argument("--context", help="text injected BEFORE the task — this is how memory travels")
    ap.add_argument("--session-id", help="resume an existing session instead of starting one")
    ap.add_argument("--cwd", default=os.getcwd())
    ap.add_argument("--key-file", help="file holding MISTRAL_API_KEY=… (never printed)")
    ap.add_argument("--server", default=DEFAULT_SERVER)
    ap.add_argument("--timeout", type=float, default=300.0)
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    a = ap.parse_args()

    res = run_task(a.task, cwd=a.cwd, api_key=load_key(a.key_file), context=a.context,
                   session_id=a.session_id, server=a.server, timeout=a.timeout)
    if a.json:
        print(json.dumps(res, indent=2))
    else:
        if res["answer"]:
            print(res["answer"])
        if res["error"]:
            print(f"\n✗ {res['error']}", file=sys.stderr)
        print(f"\n[session {res['session_id']}]", file=sys.stderr)
    return 0 if res["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
