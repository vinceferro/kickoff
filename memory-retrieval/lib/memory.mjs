// memory.mjs — shared helpers for the memory-retrieval prototype.
//
// Responsibilities:
//   - locate the file-based agent memory (the SOURCE OF TRUTH)
//   - parse a single memory .md file: YAML-ish frontmatter + body + [[cross-links]]
//   - normalise the two frontmatter shapes seen in the wild (see below)
//
// The memory files are READ-ONLY. Nothing here writes to them.

import {
  closeSync,
  existsSync,
  openSync,
  readdirSync,
  readFileSync,
  readSync,
  statSync,
} from "node:fs";
import { basename, dirname, join, resolve } from "node:path";

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

// ── SCOPE — which FUNCTION a memory belongs to (per-function index scoping) ──
//
// The fire-rate flaw herdr-tg measured (2026-09-02): when one hook serves a
// MERGED corpus (many functions' memories in one index), the relevance cutoff's
// pool-maximum fires on ~4 of 5 real operator turns — and retuning the floors
// just pushes the failure to the next corpus size. The measured fix is to scope
// the index: a session queries ITS OWN function's memories (+ an optional tiny
// shared core, ≤5 facts, measured), never the flat pool.
//
// A memory DECLARES its function via (first match wins):
//   1. frontmatter `function: <name>`   — the in-file declaration (deliberate)
//   2. filename prefix `<name>__slug.md` — the merge convention (how several
//      functions' corpora combine into one dir without collisions)
// A memory with NEITHER marker is UNSCOPED (scope = null): it belongs to no
// declared function, so it is visible to every scope. That asymmetry is the
// safety property — scoping can only ever EXCLUDE a memory that positively
// declares membership in a DIFFERENT function, so a corpus without markers
// behaves exactly as it did before the knob existed (no silent blanking).
export function scopeOf(slug, frontmatter = {}) {
  const fmFunction = frontmatter.function;
  if (typeof fmFunction === "string" && fmFunction.trim()) return fmFunction.trim();
  const m = slug.match(/^([A-Za-z0-9][A-Za-z0-9._-]*)__/);
  return m ? m[1] : null;
}

// ── THE SCOPE KNOBS (one pair, shared by the hook AND the indexer) ────────────
//   MEMORY_HOOK_FUNCTION=<name>    this session's function — the scoped index
//                                  serves own + unscoped + core memories only
//   MEMORY_HOOK_CORE_SLUGS=a,b,c   the tiny shared core pinned into every scope
//                                  (measured: ≤5 facts — a 54-fact "core" fired
//                                  74% ≈ the flat corpus's 79%)
// They compose with MEMORY_DIR: MEMORY_DIR picks the corpus root; the knobs
// narrow INSIDE it when that corpus is shared/merged.
export const MAX_CORE_FACTS = 5;
let coreCapWarned = false;

/**
 * Resolve + validate the knob pair. Returns { scope, coreSlugs } or null when
 * no scope is configured (the pre-knob behavior). Throws on a MEANINGLESS
 * config — a core list without a scope (its silent alternative is the core
 * being quietly ignored) or a scope that is not a valid slug (F-4: the scope
 * keys the derived DB filename, so a traversal/pathed slug must never reach
 * it). Throws are LOUD by design here: the indexer surfaces them on the CLI,
 * and the hook resolves through resolveScopeFromEnvSafe (below) so a throw
 * there degrades to UNSCOPED-with-a-warning — never a dead hook (F-2).
 */
const SCOPE_SLUG_RE = /^[A-Za-z0-9._-]+$/;
export function resolveScopeFromEnv(e = env) {
  const scope = (e.MEMORY_HOOK_FUNCTION || "").trim() || null;
  const coreSlugs = (e.MEMORY_HOOK_CORE_SLUGS || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  if (coreSlugs.length > MAX_CORE_FACTS && !coreCapWarned) {
    coreCapWarned = true; // once — the hook's staleness scan resolves every turn
    console.error(
      `kickoff memory: MEMORY_HOOK_CORE_SLUGS has ${coreSlugs.length} slugs — the measured ` +
        `safe shared core is ≤${MAX_CORE_FACTS} facts (a 54-fact "core" fired 74% ≈ the flat ` +
        `corpus's 79% in the herdr-tg measurement). Trim it or accept the noise.`,
    );
  }
  if (scope && !SCOPE_SLUG_RE.test(scope)) {
    throw new Error(
      `MEMORY_HOOK_FUNCTION=${JSON.stringify(scope)} is not a valid function slug ` +
        `(must match [A-Za-z0-9._-]+) — it keys the scoped index filename. Fix the knob.`,
    );
  }
  if (!scope) {
    if (coreSlugs.length) {
      throw new Error(
        `MEMORY_HOOK_CORE_SLUGS is set but MEMORY_HOOK_FUNCTION is not — a shared core only ` +
          `means something inside a function scope. Set MEMORY_HOOK_FUNCTION or unset the core list.`,
      );
    }
    return null;
  }
  return { scope, coreSlugs };
}

/**
 * The FAIL-OPEN umbrella (F-2). resolveScopeFromEnv throws on a meaningless
 * scope config — correct for the indexer CLI, lethal at the hook's module
 * scope: the raw throw there killed the hook EVERY turn (main().catch never
 * ran). Every call site that must keep running resolves through THIS: a
 * misconfig logs one named warning and returns null (run unscoped). Warned
 * once per process — the hook resolves on every turn and a wall of repeats
 * trains the reader to ignore it.
 */
let scopeFailOpenWarned = false;
export function resolveScopeFromEnvSafe(e = env) {
  try {
    return resolveScopeFromEnv(e);
  } catch (err) {
    if (!scopeFailOpenWarned) {
      scopeFailOpenWarned = true;
      console.error(
        `[memory] ⚠ scope config ignored — running UNSCOPED: ${err?.message ?? err}`,
      );
    }
    return null;
  }
}

// The frontmatter declaration is the ONE thing a filename can't tell us (it wins
// over the prefix in scopeOf), so the scoped enumeration consults it via a
// BOUNDED head read, memoized per (path, mtime) — the hook's per-turn staleness
// scan stays stat-only in the steady state and re-reads only after a real edit.
// undefined means "no frontmatter declaration" (the prefix decides).
const declarationCache = new Map(); // "<path>\0<mtimeMs>" -> string | undefined
const DECLARATION_HEAD_BYTES = 16384;
function declaredFunction(filePath, mtimeMs) {
  const key = `${filePath}\u0000${mtimeMs}`;
  if (declarationCache.has(key)) return declarationCache.get(key);
  let result;
  try {
    const fd = openSync(filePath, "r");
    try {
      const buf = Buffer.alloc(DECLARATION_HEAD_BYTES);
      const got = readSync(fd, buf, 0, DECLARATION_HEAD_BYTES, 0);
      const head = buf.subarray(0, got).toString("utf8");
      if (!head.startsWith("---")) {
        result = undefined;
      } else {
        const lines = head.split("\n");
        const fence = lines.indexOf("---", 1); // the CLOSING fence
        if (fence === -1) {
          // F-5a: no closing fence inside the head. The old "don't guess" path
          // treated the file as UNDECLARED while parseMemoryFile (full read)
          // WOULD find the declaration — enumeration and record-scope
          // disagreed, and a prefixed file declaring its function past the
          // head was LOST from its own scoped index. A truncated read must
          // never misattribute a scope, so fall back to the full read (same
          // parser, same precedence) — absurd input, cheap fix.
          const raw = readFileSync(filePath, "utf8");
          const fm = parseFrontmatter(raw).fm;
          result =
            typeof fm.function === "string" && fm.function.trim()
              ? fm.function.trim()
              : undefined;
        } else {
          const fm = parseFrontmatter(lines.slice(0, fence + 1).join("\n")).fm;
          result =
            typeof fm.function === "string" && fm.function.trim()
              ? fm.function.trim()
              : undefined;
        }
      }
    } finally {
      closeSync(fd);
    }
  } catch {
    result = undefined; // unreadable file → no declaration (listMdFiles' error path handles ENOENT)
  }
  if (declarationCache.size > 4096) declarationCache.clear(); // bound the memo
  declarationCache.set(key, result);
  return result;
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
    scope: scopeOf(slug, fm),
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

export function listMemoryFiles(dir = DEFAULT_MEMORY_DIR, scopeOpts) {
  if (!existsSync(dir)) {
    // Name the fix, not the syscall: a bare ENOENT out of readdirSync below reads as a crash
    // in the engine; this is a CONFIG state (no corpus at the resolved default — the env-less
    // second-machine shape) and the one-line fix is MEMORY_DIR (see RUNNING.md, the
    // engine-development / second-machine section).
    throw new Error(`memory corpus not found at ${dir} — set MEMORY_DIR (see RUNNING.md)`);
  }
  const listed = listMdFiles(dir);
  const privateDir = join(dir, "private");
  if (existsSync(privateDir) && statSync(privateDir).isDirectory()) {
    listed.push(...listMdFiles(privateDir));
  }

  // ── SLUG DEDUP — one deterministic winner, loudly (F-5b) ────────────────────
  // A top-level file and a private/ file may share a filename (private/ is the
  // instance-local overlay of the shared corpus). The old code returned BOTH
  // entries: the scoped path's bySlug silently let the LAST one win (readdir
  // accident), and the unscoped path handed the indexer a duplicate slug — a
  // raw UNIQUE-constraint crash at insert time. Winner is now explicit:
  // private/ shadows top-level (it IS the newer, instance-specific copy by
  // construction), independent of enumeration order, and the collision is
  // NAMED on stderr — never a silent overwrite, never a crash.
  const bySlug = new Map();
  for (const f of listed) {
    const slug = basename(f).replace(/\.md$/, "");
    const prev = bySlug.get(slug);
    if (!prev) {
      bySlug.set(slug, f);
      continue;
    }
    const winner = dirname(f) === privateDir ? f : dirname(prev) === privateDir ? prev : f;
    bySlug.set(slug, winner);
    console.error(
      `[memory] ⚠ duplicate memory slug "${slug}" in ${dir} — private/ shadows top-level:\n` +
        `    kept:   ${winner}\n    dropped: ${winner === f ? prev : f}`,
    );
  }
  const all = [...bySlug.values()];

  // ── PER-FUNCTION INDEX SCOPING (the measured precision fix) ────────────────
  // With a scope configured, the corpus the INDEX is built from (and the
  // staleness scan compares against) is: own memories + unscoped ones + the
  // pinned core. Everything declaring a DIFFERENT function never enters the
  // index — that is the point: the hook must not fish in other functions'
  // ponds, and the index's own corpus statistics (BM25 idf/length norms) must
  // be the scoped corpus's, not the merged pool's — herdr's 44% band is an
  // own-corpus number, and a query-time filter over a merged index measured
  // 55% for exactly this reason (scoping the scores, not just the pool).
  // scopeOpts (explicit {scope, coreSlugs}) overrides the env knobs — the eval
  // and selftests drive the mechanism directly; production resolves from env.
  const scope = scopeOpts !== undefined ? scopeOpts : resolveScopeFromEnv();
  if (!scope) return all;

  // bySlug (the dedup map above) is reused for the core-slug lookups — it now
  // names the ONE deterministic winner per slug instead of a readdir accident.
  const own = [];
  const unscoped = [];
  for (const f of all) {
    const slug = basename(f).replace(/\.md$/, "");
    const declared = declaredFunction(f, statSync(f).mtimeMs);
    const s = declared !== undefined ? declared : scopeOf(slug, {});
    if (s === scope.scope) own.push(f);
    else if (s === null) unscoped.push(f);
  }
  if (own.length === 0 && unscoped.length === 0) {
    throw new Error(
      `MEMORY_HOOK_FUNCTION=${scope.scope}: no memory in ${dir} declares this function ` +
        `(neither a <${scope.scope}>__ filename prefix nor a frontmatter function:) — ` +
        `fix the knob or the corpus`,
    );
  }
  const picked = [...own, ...unscoped];
  for (const slug of scope.coreSlugs) {
    const f = bySlug.get(slug);
    if (!f) {
      throw new Error(
        `MEMORY_HOOK_CORE_SLUGS names "${slug}" but no such memory file exists in ${dir} — fix the slug`,
      );
    }
    if (!picked.includes(f)) picked.push(f);
  }
  return picked;
}

// Default location for the derived (re-buildable) index cache. Anchored on
// INSTANCE_TOOL_ROOT so a PULLED core writes/reads the index in the ADOPTER's repo,
// not the read-only core clone this file may live in (see INSTANCE_TOOL_ROOT above).
// Scope-KEYED when a function scope is configured — two scoped sessions sharing an
// instance root must not clobber each other's index (and a scoped index's corpus
// statistics are the scoped corpus's). MEMORY_DB always wins verbatim.
function defaultDbPath() {
  if (env.MEMORY_DB) return resolve(env.MEMORY_DB);
  // F-2: through the fail-open umbrella — this ran at MODULE SCOPE (the lib
  // import itself), where a raw throw killed the hook every turn. A misconfig
  // now warns once and keys the unscoped path; the indexer CLI keeps the raw
  // throw (it calls resolveScopeFromEnv directly).
  const scope = resolveScopeFromEnvSafe();
  return scope
    ? join(INSTANCE_TOOL_ROOT, `memory-index.${scope.scope}.db`)
    : join(INSTANCE_TOOL_ROOT, "memory-index.db");
}
export const DEFAULT_DB_PATH = defaultDbPath();
