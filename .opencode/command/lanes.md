---
description: Live glance at the kickoff fleet — one line per lane from .kickoff/graph.json
agent: build
---

Run the lane snapshot for this repo and show it verbatim, then add ONE sentence: the
single most urgent lane (oldest running lane with no recent activity, or any
proof-failed/failed lane) and what to do about it.

Use the `lanes_status` tool (no args) — it renders .kickoff/graph.json through the
shared renderer (scripts/lanes-snapshot.py): running lanes first, then claimed, then
terminal; capped at 20 with a "+N more" tail. If the tool is unavailable, fall back to
`python3 scripts/lanes-snapshot.py .kickoff/graph.json` via bash.

Do not re-derive lane state from git or session logs — the ledger is the source.
