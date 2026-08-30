#!/usr/bin/env python3
"""lanes-snapshot.py — one renderer for "what is each lane doing", three consumers.

    python3 scripts/lanes-snapshot.py [--json] [--activity] [--cap N] <graph.json>

The lane ledger (.kickoff/graph.json — lanes[] and graph-executor's nodes[], same
idea) is machine state with no human surface. This script is the SINGLE renderer
every visibility surface shares, so the sort order and the line shape are pinned
in exactly one place:

    · the opencode plugin tool `lanes_status` (.opencode/plugins/lanes-status.js)
    · the `/lanes` command (.opencode/command/lanes.md)
    · the live board (scripts/lanes-board.sh serves this script's --json per request)

Sort: running first, then claimed, then everything terminal — live work reads
first. Output is capped (--cap, default 20) with a "+N more" tail so a caller's
context is protected; the full ledger stays on disk.

--activity: when a lane recorded a serve port, count its session messages via the
opencode serve API (cheap liveness signal). ANY failure (no port, serve down,
timeout) skips silently — activity is garnish, never a reason to fail the render.

Exit codes: unreadable ledger → stderr names the path, exit 1 (LOUD). An empty
but present ledger is not an error → zero lines, exit 0.
"""

import calendar
import json
import sys
import time
import urllib.request

CAP_DEFAULT = 20
STATUS_ORDER = {"running": 0, "claimed": 1}  # everything else is terminal → 2
ICON = {
    "running": "▶", "claimed": "⏳", "done": "✅", "proof-failed": "🔴",
    "unverified": "⚠️", "failed": "❌", "blocked": "⛔", "pending": "·",
}


def short_id(lid):
    # "lane-0828-172442-3579602" → "0828-1724" (the pid suffix is noise in a line);
    # graph-node ids ("n1") pass through trimmed.
    body = lid[5:] if lid.startswith("lane-") else lid
    return body[:9] if lid.startswith("lane-") else body[:12]


def updated_epoch(ts):
    if not ts:
        return None
    try:
        # the ledger writes gmtime ISO strings — parse as UTC (timegm), never local
        return calendar.timegm(time.strptime(ts.replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S%z"))
    except ValueError:
        return None


def age_human(minutes):
    if minutes is None:
        return "n/a"
    if minutes < 600:
        return f"{minutes}m"
    if minutes < 7 * 1440:
        return f"{minutes // 60}h"
    return f"{minutes // 1440}d"


def proof_state(status, proof):
    if status == "done":
        return "proof passed"
    if status == "proof-failed":
        return "proof FAILED"
    if not proof:
        return "no proof"
    return "proof declared"


def count_msgs(port, session):
    url = f"http://127.0.0.1:{port}/session/{session}/message"
    try:
        with urllib.request.urlopen(url, timeout=1.5) as r:
            return len(json.load(r))
    except Exception:
        return None  # serve down / no port / timeout — activity is skip-silently


def rows(graph):
    out = []
    for lane in graph.get("lanes", []) + graph.get("nodes", []):
        if not isinstance(lane, dict) or not lane.get("id"):
            continue
        up = updated_epoch(lane.get("updated"))
        out.append({
            "id": lane["id"],
            "short": short_id(lane["id"]),
            "agent": lane.get("agent", "?"),
            "status": lane.get("status", "unknown"),
            "respawns": lane.get("respawns", 0) or 0,
            "proof": bool(lane.get("proof")),
            "updated": lane.get("updated"),
            "age_min": (max(0, int((time.time() - up) / 60)) if up else None),
            "port": lane.get("port"),
            "session": lane.get("session"),
        })
    return out


def sort_key(r):
    return (STATUS_ORDER.get(r["status"], 2), -(r["age_min"] is not None and -r["age_min"] or 0))


def main():
    args = sys.argv[1:]
    as_json = "--json" in args
    activity = "--activity" in args
    cap = CAP_DEFAULT
    path = None
    skip_next = False
    for a in args:
        if skip_next:
            cap = int(a)
            skip_next = False
            continue
        if a in ("--json", "--activity"):
            continue
        if a == "--cap":
            skip_next = True
            continue
        path = a
        break
    if not path:
        print("lanes-snapshot: no graph.json path given", file=sys.stderr)
        return 1

    try:
        with open(path) as fh:
            graph = json.load(fh)
        if not isinstance(graph, dict):
            raise ValueError("not an object")
    except Exception as e:
        print(f"lanes-snapshot: cannot read lane ledger {path}: {e}", file=sys.stderr)
        return 1

    lane_rows = rows(graph)
    lane_rows.sort(key=sort_key)

    if activity:
        serve_dead = False   # ONE serve instance serves every lane: the first failed
        for r in lane_rows:  # count means every later ask fails too — stop after one,
            if serve_dead:   # never 1.5s × N lanes of timeouts on a dead bridge.
                break
            if r.get("port") and r.get("session"):
                n = count_msgs(r["port"], r["session"])
                if n is None:
                    serve_dead = True  # skip-silently: activity is garnish, never a failure
                else:
                    r["msgs"] = n

    shown = lane_rows[:cap]
    if as_json:
        print(json.dumps({
            "lanes": [{k: v for k, v in r.items() if k not in ("port", "session")}
                      for r in shown],
            "total": len(lane_rows), "shown": len(shown),
            "truncated": len(lane_rows) - len(shown),
        }))
        return 0

    for r in shown:
        parts = [ICON.get(r["status"], "·"), r["short"], r["agent"], r["status"],
                 "·", age_human(r["age_min"])]
        if r["respawns"]:
            parts.append(f"· respawn {r['respawns']}")
        parts.append(f"· {proof_state(r['status'], r['proof'])}")
        if r.get("msgs") is not None:
            parts.append(f"· {r['msgs']} msgs")
        print(" ".join(str(p) for p in parts))
    if len(lane_rows) > len(shown):
        print(f"+{len(lane_rows) - len(shown)} more")
    return 0


if __name__ == "__main__":
    sys.exit(main())
