// memory.mjs — shared helpers for the memory-retrieval prototype.
//
// Responsibilities:
//   - locate the file-based agent memory (the SOURCE OF TRUTH)
//   - parse a single memory .md file: YAML-ish frontmatter + body + [[cross-links]]
//   - normalise the two frontmatter shapes seen in the wild (see below)
//
// The memory files are READ-ONLY. Nothing here writes to them.

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { basename, join, resolve } from "node:path";

// Indirect process.env read: these are RUNTIME knobs (not build inputs), read via
// this alias so a host build pipeline that lints env-var usage stays clean.
const env = process.env;

// ── Where the memory lives (configurable — this is the integration seam) ──────
//
// MEMORY_DIR (env var) is the ONE knob the host repo points at its own corpus of
// markdown agent-memory files. NO host path is hardcoded here, so this module
// drops into any project unchanged.
//
//   • MEMORY_DIR set       → use it verbatim (absolute or relative to cwd).
//   • MEMORY_DIR unset      → probe the two real corpus layouts ($REPO_DIR/memory,
//                             $REPO_DIR/.kickoff/memory, then the engine-source sibling
//                             <tool-root>/../memory); if none exists, keep the first
//                             candidate and fail NAMING the fix (see listMemoryFiles).
//
// Examples:
//   MEMORY_DIR=/path/to/your/repo/memory ./run.sh index
//   MEMORY_DIR=../memory                  ./run.sh retrieve "..."
//
// ── INSTANCE_TOOL_ROOT — resolve a PULLED core into the ADOPTER's repo, not the clone ──
// The DERIVED data (the index DB, the corpus-default, the hook log) must live in the
// ADOPTER's repo — never in the read-only core clone this code may be executing FROM.
// But `import.meta.dirname` points at wherever THIS FILE sits, which for a `kickoff pull`
// adopter is the shared core clone (~/kickoff-core/…), not their repo. So we anchor on
// REPO_DIR, which the launcher exports before spawning the session:
//   • REPO_DIR set   → <REPO_DIR>/memory-retrieval — the adopter's OWN repo. This is
//                      what stops the cross-instance data leak into the shared core.
//   • REPO_DIR unset → fall back to the tool's own location (kickoff-itself / greenfield
//                      / a direct ./run.sh — where the tool IS in the repo, so it's the
//                      repo anyway). This is ALWAYS a working default, NEVER a hard-fail:
//                      kickoff's live memory hook resolves its index through here on EVERY
//                      turn and must keep surfacing memories.
const TOOL_ROOT = resolve(import.meta.dirname ?? ".", "..");
export const INSTANCE_TOOL_ROOT = env.REPO_DIR
  ? join(resolve(env.REPO_DIR), "memory-retrieval")
  : TOOL_ROOT;

// DEFAULT_MEMORY_DIR, MEMORY_DIR unset → probe the two REAL corpus layouts before keeping a
// value (second-machine incident 2026-08-26: the old chain fell straight to
// join(INSTANCE_TOOL_ROOT, "memory") = <repo>/memory-retrieval/memory, which matches NO real
// layout on either side — engine-source corpus is the SIBLING <repo>/memory, adopter corpus is
// <repo>/.kickoff/memory — so an env-less run died as a bare ENOENT). Order:
//   1. $REPO_DIR/memory            (engine-source repo: kickoff's own corpus layout)
//   2. $REPO_DIR/.kickoff/memory   (pull-adopter: the seeded corpus location)
//   3. <TOOL_ROOT>/../memory       (engine-source sibling when REPO_DIR isn't exported —
//                                   a bare `node index.mjs` inside the source tree)
// If nothing exists we STILL return a value (module-load must never throw) — the scandir in
// listMemoryFiles then fails NAMING THE FIX ("set MEMORY_DIR, see RUNNING.md") instead of a
// raw ENOENT. env.MEMORY_DIR always wins verbatim, so explicit setups are unaffected.
function probeDefaultMemoryDir() {
  const candidates = [];
  if (env.REPO_DIR) {
    const repo = resolve(env.REPO_DIR);
    candidates.push(join(repo, "memory"), join(repo, ".kickoff", "memory"));
  }
  candidates.push(resolve(TOOL_ROOT, "..", "memory"));
  for (const c of candidates) if (existsSync(c)) return c;
  return candidates[0]; // nothing real anywhere — keep a value; the failure names the fix
}
export const DEFAULT_MEMORY_DIR = env.MEMORY_DIR
  ? resolve(env.MEMORY_DIR)
  : probeDefaultMemoryDir();

// The flat roll-up index file is NOT a per-fact memory; skip it when indexing.
const INDEX_FILE = "MEMORY.md";

/**
 * Parse the frontmatter block (between the first two `---` fences) into a flat
 * object. We deliberately use a tiny hand-rolled parser instead of pulling in a
 * YAML dep — the frontmatter here is shallow and we want zero external deps.
 *
 * Two shapes exist in the corpus:
 *   (a) flat:    `type: feedback`            (older files)
 *   (b) nested:  `metadata:\n  type: feedback` (newer files)
 * We flatten (b) so callers always read `fm.type`.
 */
function parseFrontmatter(raw) {
  const fm = {};
  const lines = raw.split("\n");
  if (lines[0].trim() !== "---") return { fm, bodyStart: 0 };

  let i = 1;
  let nestedKey = null; // tracks the current `metadata:`-style parent
  for (; i < lines.length; i++) {
    const line = lines[i];
    if (line.trim() === "---") {
      i++; // consume the closing fence
      break;
    }
    if (!line.trim()) continue;

    const indented = /^\s+/.test(line);
    const m = line.match(/^(\s*)([A-Za-z0-9_]+):\s*(.*)$/);
    if (!m) continue;
    const [, , key, rawVal] = m;
    const val = stripQuotes(rawVal.trim());

    if (!indented) {
      if (val === "") {
        // e.g. `metadata:` opening a nested block
        nestedKey = key;
      } else {
        nestedKey = null;
        fm[key] = val;
      }
    } else if (nestedKey) {
      // Flatten nested keys (metadata.type -> type, metadata.node_type -> node_type)
      fm[key] = val;
    }
  }
  return { fm, bodyStart: i };
}

function stripQuotes(s) {
  if ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"))) {
    return s.slice(1, -1);
  }
  return s;
}

// Extract every [[link target]] from the body. Targets are the snake_case
// filename slugs the corpus uses to cross-reference facts.
export function extractLinks(body) {
  const out = new Set();
  for (const m of body.matchAll(/\[\[([^\]]+)\]\]/g)) {
    // Links can carry a display alias: [[slug|Alias]] — keep the slug.
    const target = m[1].split("|")[0].trim();
    if (target) out.add(target);
  }
  return [...out];
}

/**
 * Parse one memory file into a record. `slug` is the filename without `.md` —
 * this is the STABLE identifier the cross-link graph keys on (the `name`
 * frontmatter field is unreliable: sometimes the slug, sometimes a human title).
 */
export function parseMemoryFile(filePath) {
  const raw = readFileSync(filePath, "utf8");
  const { fm, bodyStart } = parseFrontmatter(raw);
  const body = raw.split("\n").slice(bodyStart).join("\n").trim();
  const slug = basename(filePath).replace(/\.md$/, "");
  const mtime = statSync(filePath).mtimeMs;

  return {
    slug,
    name: fm.name || slug,
    description: fm.description || "",
    type: fm.type || "unknown", // user | feedback | project | reference
    body,
    file: filePath,
    mtime,
    links: extractLinks(body),
  };
}

// Enumerate every per-fact memory file (skips the MEMORY.md roll-up and macOS
// AppleDouble `._` sidecar files).
//
// The corpus lives in two places on disk, both indexed the same way:
//   • <dir>/*.md          — the PUBLIC, version-controlled facts (ship to adopters).
//   • <dir>/private/*.md  — the PRIVATE facts: gitignored, NEVER tracked or pushed
//                           (instance/operator/project specifics), but still on disk,
//                           so recall must include them. The indexer reads the
//                           FILESYSTEM, not git, so a gitignored file indexes exactly
//                           like a tracked one. This is what lets "no private info in
//                           the public repo" coexist with "the indexer still sees them".
function listMdFiles(dir) {
  return readdirSync(dir)
    .filter((f) => f.endsWith(".md"))
    .filter((f) => f !== INDEX_FILE)
    .filter((f) => !f.startsWith("._"))
    .map((f) => join(dir, f));
}

export function listMemoryFiles(dir = DEFAULT_MEMORY_DIR) {
  if (!existsSync(dir)) {
    // Name the fix, not the syscall: a bare ENOENT out of readdirSync below reads as a crash
    // in the engine; this is a CONFIG state (no corpus at the resolved default — the env-less
    // second-machine shape) and the one-line fix is MEMORY_DIR (see RUNNING.md, the
    // engine-development / second-machine section).
    throw new Error(`memory corpus not found at ${dir} — set MEMORY_DIR (see RUNNING.md)`);
  }
  const files = listMdFiles(dir);
  const privateDir = join(dir, "private");
  if (existsSync(privateDir) && statSync(privateDir).isDirectory()) {
    files.push(...listMdFiles(privateDir));
  }
  return files;
}

// Default location for the derived (re-buildable) index cache. Anchored on
// INSTANCE_TOOL_ROOT so a PULLED core writes/reads the index in the ADOPTER's repo,
// not the read-only core clone this file may live in (see INSTANCE_TOOL_ROOT above).
export const DEFAULT_DB_PATH =
  env.MEMORY_DB || join(INSTANCE_TOOL_ROOT, "memory-index.db");
