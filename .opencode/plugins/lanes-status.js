import { tool } from "@opencode-ai/plugin"
import { execFile } from "node:child_process"
import { existsSync } from "node:fs"
import { pathToFileURL } from "node:url"
import { promisify } from "node:util"

const run = promisify(execFile)

// lanes_status — the fleet's state surfaced INTO opencode (engine-parity principle,
// the LANE VISIBILITY lane 2026-08-28). Lane state lives in .kickoff/graph.json and
// coordinator reports only; the operator asked to "see things happening under the
// hood" from inside a session. This tool is that surface: one line per lane —
// short-id, agent, status, respawns, proof state, minutes since last activity —
// running first, capped so the caller's context is protected.
//
// Zero re-implementation: it shells the SAME renderer the /lanes command and the
// live board use (scripts/lanes-snapshot.py). Sort order and line shape are pinned
// in exactly one place and one test suite (lane-machinery-selftest.sh §7) covers
// all three consumers. See the file head of lanes-snapshot.py.
//
// Degrades honestly: no ledger → a returned message the coordinator can relay,
// never a thrown tool. The board (scripts/lanes-board.sh) is the richer cousin —
// this tool is the in-session glance.

const CAP_CHARS = 6000 // same caller-context cap as memory-search.js

export const LanesStatusPlugin = async ({ project }) => {
  return {
    tool: {
      lanes_status: tool({
        description:
          "One-line-per-lane glance at the kickoff fleet's live state from " +
          ".kickoff/graph.json: short-id, agent, status (running first, then claimed, " +
          "then terminal), respawns, proof state, minutes since last activity. " +
          "Use when the operator asks what the lanes/fleet are doing, before " +
          "reporting lane progress, or before dispatching onto a busy graph.",
        args: {
          cap: tool.schema.number().optional().describe("Max lanes shown (default 20, tail reported as '+N more')"),
        },
        async execute({ cap }) {
          const projectRoot = project?.worktree || process.cwd()
          const graph = `${projectRoot}/.kickoff/graph.json`
          if (!existsSync(graph)) {
            return (
              `no lane ledger at ${graph} — no lanes have been dispatched from this ` +
              "repo (scripts/lane-dispatch.sh creates it). Nothing is running under the hood."
            )
          }
          const script = `${projectRoot}/scripts/lanes-snapshot.py`
          if (!existsSync(script)) {
            return `lanes_status unavailable: the shared renderer ${script} is missing (repo checkout incomplete).`
          }
          // The renderer is the SCRIPT's first argument; flags after it are the
          // script's. (The first draft ran `python3 --json <graph>` — the renderer
          // never on the argv — and only the behavioral smoke caught it: every
          // render returned the degraded message. Green checks had only grepped.)
          const args = [script, "--json"]
          if (cap && Number.isFinite(cap) && cap > 0) args.push("--cap", String(Math.floor(cap)))
          // Activity garnish: count session messages via the serve API, but only when
          // a bridge port is even recorded — the renderer skips silently otherwise.
          if (existsSync(`${projectRoot}/.kickoff/opencode-bridge.port`)) args.push("--activity")
          args.push(graph)
          try {
            const { stdout } = await run("python3", args, {
              cwd: projectRoot,
              timeout: 15000,
            })
            const data = JSON.parse(stdout)
            if (!data.total) return "No lanes in the ledger — the fleet is idle."
            // Render from the JSON rows: stable, no ANSI, one line per lane — the
            // same fields the script's text mode prints, minus its icon column.
            const lines = data.lanes.map((r) => {
              const age = r.age_min == null ? "n/a" : r.age_min < 600 ? `${r.age_min}m` : r.age_min < 10080 ? `${Math.floor(r.age_min / 60)}h` : `${Math.floor(r.age_min / 1440)}d`
              const proof = r.status === "done" ? "proof passed" : r.status === "proof-failed" ? "proof FAILED" : r.proof ? "proof declared" : "no proof"
              const bits = [r.short, r.agent, r.status, age]
              if (r.respawns) bits.push(`respawn ${r.respawns}`)
              bits.push(proof)
              if (r.msgs != null) bits.push(`${r.msgs} msgs`)
              return bits.join(" · ")
            })
            if (data.truncated > 0) lines.push(`+${data.truncated} more (of ${data.total}) — ask with a higher cap or read ${graph}`)
            const out = lines.join("\n")
            return out.length > CAP_CHARS ? out.slice(0, CAP_CHARS) + "\n…(truncated)" : out
          } catch (e) {
            return `lanes_status failed: ${e.message}. (Renderer degraded — say so; do not guess lane state.)`
          }
        },
      }),
    },
  }
}

// pathToFileURL is imported for parity with sibling plugins that exec repo scripts;
// keep the import honest by exposing the renderer path resolution for tests.
export const rendererUrl = (projectRoot) => pathToFileURL(`${projectRoot}/scripts/lanes-snapshot.py`).href
