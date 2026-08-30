import { tool } from "@opencode-ai/plugin"
import { execFile } from "node:child_process"
import { existsSync } from "node:fs"
import { promisify } from "node:util"

const run = promisify(execFile)

// memory-search — the kickoff memory hook, ported to opencode (engine-parity principle).
//
// The claude side recalls via a SessionStart/UserPromptSubmit hook (memory-retrieval/).
// Opencode has no session-start context-injection hook, so the SAME retrieval engine is
// exposed as a TOOL instead: the coordinator's charter makes searching it part of the
// re-ground ritual, which preserves the contract ("recall before acting") without needing
// a hook point that does not exist here.
//
// Zero rewrite: this wraps memory-retrieval/retrieve.mjs (hybrid FTS5+vector, RRF-fused)
// from the pinned core clone. Paths come from the SAME instance.env vars the claude hook
// reads — MEMORY_DB / MEMORY_DIR — so an org's memory is identical whichever engine asks.
// Degrades honestly when an org has no memory wired.
//
// ENGINE-SOURCE FALLBACK (second-machine incident, 2026-08-26): a repo that IS the kickoff
// engine-source tree runs its OWN memory-retrieval/ — there is no pinned core clone and no
// KICKOFF_CORE_DIR in an interactive session, but the engine is the tree the session stands
// in. So CORE_RETRIEVE falls back to <project>/memory-retrieval/retrieve.mjs, and an unset
// MEMORY_DB no longer fails: the child gets REPO_DIR=<project> so the engine anchors its own
// default db path (lib/memory.mjs anchors on REPO_DIR). See RUNNING.md, engine-development
// mode.

const CORE_RETRIEVE = (projectRoot) => {
  const core = process.env.KICKOFF_CORE_DIR
  if (core) {
    const p = `${core}/memory-retrieval/retrieve.mjs`
    if (existsSync(p)) return p
  }
  // Repo-local fallback: engine-source repos run their own tree.
  if (projectRoot) {
    const p = `${projectRoot}/memory-retrieval/retrieve.mjs`
    if (existsSync(p)) return p
  }
  return null
}

export const MemorySearchPlugin = async ({ project }) => {
  return {
    tool: {
      memory_search: tool({
        description:
          "Search this org's persistent memory (hybrid keyword+semantic over the derived index). " +
          "Part of the re-ground ritual: search BEFORE acting on anything tracker/memory might answer. " +
          "Returns the top facts with their file paths.",
        args: {
          query: tool.schema.string().describe("Natural-language query about durable facts, decisions, operator preferences, past work"),
          k: tool.schema.number().optional().describe("Max results (default 5)"),
        },
        async execute({ query, k }) {
          const projectRoot = project?.worktree || process.cwd()
          const script = CORE_RETRIEVE(projectRoot)
          if (!script) {
            return (
              "memory_search unavailable: no retrieval engine found — neither " +
              "KICKOFF_CORE_DIR/memory-retrieval/retrieve.mjs nor <repo>/memory-retrieval/retrieve.mjs " +
              "exists in this environment."
            )
          }
          // Distinct honest errors: engine missing is checked above; db state below. An unset
          // MEMORY_DB is NOT an error — the child anchors its own default via REPO_DIR.
          const db = process.env.MEMORY_DB
          if (db && !existsSync(db)) {
            return (
              `memory_search unavailable: MEMORY_DB is set but ${db} does not exist — ` +
              "first index build not done? (see RUNNING.md, second-machine section)"
            )
          }
          const args = [script, query, "--json"]
          if (k && Number.isFinite(k) && k > 0) args.push("--k", String(Math.floor(k)))
          try {
            const { stdout } = await run("node", ["--experimental-sqlite", ...args], {
              cwd: projectRoot,
              env: db
                ? process.env
                : { ...process.env, REPO_DIR: projectRoot }, // engine anchors its default db
              timeout: 15000,
            })
            const trimmed = stdout.trim()
            if (!trimmed) return "No memory matched that query."
            // Cap output to protect coordinator context; the full record lives on disk.
            return trimmed.length > 6000 ? trimmed.slice(0, 6000) + "\n…(truncated)" : trimmed
          } catch (e) {
            return `memory_search failed: ${e.message}. (Engine degraded — say so; do not guess.)`
          }
        },
      }),
    },
  }
}
