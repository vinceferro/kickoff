#!/usr/bin/env node

// scope-selftest.mjs — per-function index scoping (the memory-precision fix).
//
// Covers the contract end-to-end on a synthetic pooled corpus, with the
// deterministic hashing embedder (no model dependency — keyword arm only):
//
//   1. scopeOf unit: `<name>__slug.md` prefix declares the function;
//      frontmatter `function:` wins over the prefix; no marker → null (unscoped).
//   2. The index RECORDS the scope (memories.scope column).
//   3. retrieve({scope}) narrows BOTH arms to own + unscoped — a query aimed at
//      another function's fact returns nothing under this function's scope.
//   4. coreSlugs pins a foreign fact back into the scoped pool (MEMORY_HOOK_CORE_SLUGS).
//   5. scope=null is the exact pre-knob behavior (the whole index is the pool).
//   6. Unscoped facts stay visible to every scope (the safety asymmetry: a
//      marker-less corpus behaves exactly as before the knob existed).
//   7. The INDEX ITSELF scopes: buildIndex with a scope builds own + unscoped
//      (+ pinned core) ONLY — the corpus statistics are the scoped corpus's,
//      which is what lands the measured band (a query-time filter over a merged
//      index measured 55% vs the scoped index's ≤50% gate).
//   8. Misconfiguration fails LOUD: a scope matching nothing throws; a core
//      slug naming no file throws; a core list without a scope throws.
//   9. The derived default DB path is scope-KEYED (scoped sessions sharing an
//      instance root must not clobber each other's index).
//
// Review-fix cases (memory-precision fix lane, F-2..F-5):
//   10. F-2 fail-open: a scope misconfig (core list without a scope) must
//       NEVER leave the hook dead — the umbrella resolves UNSCOPED with a
//       named warning, the lib module imports clean under the misconfig, and
//       the real hook.mjs process exits 0 with empty stdout (spawns it).
//   11. F-3 hostile-ambient: an explicitly-pinned call (scopeOpts: null) is
//       immune to a hostile ambient MEMORY_HOOK_FUNCTION — the eval's flat
//       baselines depend on this pin. The ambient-resolving no-scopeOpts call
//       keeps its production semantics (asserted, not regressed).
//   12. F-4 slug validation: MEMORY_HOOK_FUNCTION must match
//       [A-Za-z0-9._-]+ — traversal/pathed slugs throw at resolution and run
//       UNSCOPED through the umbrella (they used to key the DB filename).
//   13. F-5a: a frontmatter declaration the 16KB head read can't terminate
//       falls back to a full read — enumeration and record-scope agree.
//   14. F-5b: a top-level vs private/ filename collision resolves to ONE
//       deterministic winner (private shadows) with a LOUD warning — never a
//       silent overwrite, never a UNIQUE-constraint crash at index time.
//
// The >5-core warning lives in resolveScopeFromEnv (warn-once, measured
// posture: allowed but visible); the anti-pattern itself is measured, not
// unit-tested — see eval.mjs's reported c_core54 row.
//
// Usage: node --experimental-sqlite memory-retrieval/scope-selftest.mjs
// Exit 0 IFF every assertion holds.

import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";

const env = process.env;
const TMP = join(import.meta.dirname ?? ".", ".scope-selftest-tmp");

let pass = 0, fail = 0;
function ok(cond, label) {
  if (cond) {
    pass++;
    console.log(`  ✅ ${label}`);
  } else {
    fail++;
    console.log(`  ❌ ${label}`);
  }
}
async function throws(fn, label, needle) {
  try {
    await fn();
    ok(false, `${label} (threw nothing)`);
  } catch (e) {
    ok(String(e?.message ?? e).includes(needle), `${label} — names "${needle}"`);
  }
}

function makeCorpus() {
  rmSync(TMP, { recursive: true, force: true });
  const dir = join(TMP, "pooled");
  mkdirSync(dir, { recursive: true });
  const mem = (slug, body, fm = "") =>
    writeFileSync(
      join(dir, `${slug}.md`),
      `---\nname: ${slug}\ntype: project\n${fm}---\n${body}\n`,
    );
  mem("alpha__render-loop", "the render loop redraws the alpha widget every frame via alphawidgetmark");
  mem("alpha__api-keys", "alpha api keys live in the vault under the alpha-project entry");
  mem("beta__queue-depth", "the beta queue depth alert fires at fifty betaqueuemark pending jobs");
  mem("shared-note", "a fact with no scope marker: the shared build cache lives at varcachemark");
  // frontmatter declaration wins over naming:
  mem("plain-named", "this fact belongs to alpha by declaration only declaredmark", "function: alpha\n");
  return dir;
}

async function main() {
  const savedEmbedder = env.MEMORY_EMBEDDER;
  env.MEMORY_EMBEDDER = "hashing"; // deterministic stub — keyword arm only, no model

  const { scopeOf, parseMemoryFile, resolveScopeFromEnv, resolveScopeFromEnvSafe, listMemoryFiles } =
    await import("./lib/memory.mjs");
  const { buildIndex } = await import("./index.mjs");
  const { retrieve } = await import("./retrieve.mjs");

  console.log("scopeOf (declaration rules):");
  ok(scopeOf("herdr-tg__some-slug") === "herdr-tg", "`<name>__slug` prefix declares the function");
  ok(
    scopeOf("plain-named", { function: "alpha" }) === "alpha",
    "frontmatter `function:` declares it",
  );
  ok(
    scopeOf("beta__slug", { function: "alpha" }) === "alpha",
    "frontmatter wins over the prefix",
  );
  ok(scopeOf("no-marker-at-all") === null, "no marker → null (unscoped, visible to all)");
  ok(scopeOf("boxe-kickoff__boxe-app") === "boxe-kickoff", "org prefix with dots/dashes parses");

  console.log("index records the scope:");
  const dir = makeCorpus();
  const parsed = parseMemoryFile(join(dir, "plain-named.md"));
  ok(parsed.scope === "alpha", "parseMemoryFile carries scope through");
  const dbPath = join(TMP, "test.db");
  await buildIndex({ memoryDir: dir, dbPath, quiet: true });
  const { DatabaseSync } = await import("node:sqlite");
  const scopes = Object.fromEntries(
    new DatabaseSync(dbPath).prepare(`SELECT slug, scope FROM memories`).all().map((r) => [r.slug, r.scope]),
  );
  ok(scopes["alpha__render-loop"] === "alpha" && scopes["beta__queue-depth"] === "beta", "prefix-derived scopes stored");
  ok(scopes["plain-named"] === "alpha", "frontmatter-derived scope stored");
  ok(scopes["shared-note"] === null, "marker-less fact stored unscoped");

  console.log("retrieve({scope}) narrows the pool:");
  const betaOnly = await retrieve("betaqueuemark pending jobs", {
    k: 3, dbPath, mode: "keyword", scope: "alpha", coreSlugs: [],
  });
  ok(
    betaOnly.results.every((r) => r.slug !== "beta__queue-depth"),
    "another function's fact unreachable under this scope",
  );
  const betaPinned = await retrieve("betaqueuemark pending jobs", {
    k: 3, dbPath, mode: "keyword", scope: "alpha", coreSlugs: ["beta__queue-depth"],
  });
  ok(
    betaPinned.results.some((r) => r.slug === "beta__queue-depth"),
    "coreSlugs pins the foreign fact back into the pool",
  );

  console.log("unscoped facts stay visible to every scope:");
  const shared = await retrieve("varcachemark shared build cache", {
    k: 3, dbPath, mode: "keyword", scope: "beta", coreSlugs: [],
  });
  ok(
    shared.results.some((r) => r.slug === "shared-note"),
    "marker-less fact reachable under a foreign scope",
  );

  console.log("scope=null is the pre-knob behavior:");
  const flat = await retrieve("betaqueuemark pending jobs", { k: 3, dbPath, mode: "keyword" });
  ok(
    flat.results.some((r) => r.slug === "beta__queue-depth"),
    "without a scope the whole index is the pool",
  );

  console.log("buildIndex scopes the INDEX itself (corpus statistics, not just the query):");
  const scopedDb = join(TMP, "scoped.db");
  await buildIndex({
    memoryDir: dir,
    dbPath: scopedDb,
    quiet: true,
    scopeOpts: { scope: "alpha", coreSlugs: [] },
  });
  const scopedRows = new DatabaseSync(scopedDb)
    .prepare(`SELECT slug FROM memories ORDER BY slug`)
    .all()
    .map((r) => r.slug);
  ok(
    scopedRows.length === 4 &&
      scopedRows.includes("alpha__render-loop") &&
      scopedRows.includes("plain-named") &&
      scopedRows.includes("shared-note") &&
      !scopedRows.includes("beta__queue-depth"),
    "scoped index = own + unscoped only (beta excluded at build time)",
  );
  const scopedCoreDb = join(TMP, "scoped-core.db");
  await buildIndex({
    memoryDir: dir,
    dbPath: scopedCoreDb,
    quiet: true,
    scopeOpts: { scope: "alpha", coreSlugs: ["beta__queue-depth"] },
  });
  const coreRows = new DatabaseSync(scopedCoreDb)
    .prepare(`SELECT slug FROM memories`)
    .all()
    .map((r) => r.slug);
  ok(coreRows.includes("beta__queue-depth"), "pinned core fact enters the scoped INDEX");
  const betaThroughScopedIndex = await retrieve("betaqueuemark pending jobs", {
    k: 3, dbPath: scopedCoreDb, mode: "keyword", scope: "alpha", coreSlugs: ["beta__queue-depth"],
  });
  ok(
    betaThroughScopedIndex.results.some((r) => r.slug === "beta__queue-depth"),
    "pinned core fact retrievable through the scoped index",
  );

  console.log("misconfiguration fails loud:");
  {
    // A scope matches nothing only where EVERY file declares a function — an
    // unscoped fact is visible to every scope by design, so it can't be the
    // trigger. Isolate such a corpus and assert the enumeration refuses.
    const allDeclared = join(TMP, "all-declared");
    mkdirSync(allDeclared, { recursive: true });
    writeFileSync(join(allDeclared, "alpha__x.md"), "---\nname: x\ntype: project\n---\nbody\n");
    writeFileSync(join(allDeclared, "beta__y.md"), "---\nname: y\ntype: project\n---\nbody\n");
    await throws(
      () => listMemoryFiles(allDeclared, { scope: "zeta", coreSlugs: [] }),
      "a scope matching nothing refuses to enumerate",
      "zeta",
    );
  }
  await throws(
    () => buildIndex({ memoryDir: dir, dbPath: join(TMP, "badcore.db"), quiet: true, scopeOpts: { scope: "alpha", coreSlugs: ["nope__missing"] } }),
    "a core slug naming no file refuses to build",
    "nope__missing",
  );
  await throws(() => resolveScopeFromEnv({ MEMORY_HOOK_CORE_SLUGS: "x" }), "core without scope throws", "MEMORY_HOOK_FUNCTION");

  console.log("derived default DB path is scope-keyed:");
  {
    const savedDb = env.MEMORY_DB;
    const savedFn = env.MEMORY_HOOK_FUNCTION;
    try {
      delete env.MEMORY_DB;
      env.MEMORY_HOOK_FUNCTION = "herdr-tg";
      const { DEFAULT_DB_PATH: scopedPath } = await import(`./lib/memory.mjs?dbkey-${Date.now()}`);
      ok(scopedPath.includes("memory-index.herdr-tg.db"), `scoped db keyed (${scopedPath.split("/").pop()})`);
      delete env.MEMORY_HOOK_FUNCTION;
      const { DEFAULT_DB_PATH: plainPath } = await import(`./lib/memory.mjs?dbkey2-${Date.now()}`);
      ok(plainPath.endsWith("memory-index.db"), `unscoped db unchanged (${plainPath.split("/").pop()})`);
    } finally {
      if (savedDb !== undefined) env.MEMORY_DB = savedDb;
      else delete env.MEMORY_DB;
      if (savedFn !== undefined) env.MEMORY_HOOK_FUNCTION = savedFn;
      else delete env.MEMORY_HOOK_FUNCTION;
    }
  }

  console.log("F-2 · scope misconfig fails OPEN — the hook is never dead:");
  {
    const savedCore = env.MEMORY_HOOK_CORE_SLUGS;
    const savedFn = env.MEMORY_HOOK_FUNCTION;
    const savedDb = env.MEMORY_DB;
    try {
      delete env.MEMORY_DB; // anchor the derived path on the tool root, not an absolute MEMORY_DB
      delete env.MEMORY_HOOK_FUNCTION; // the misconfig: core list WITHOUT a scope
      env.MEMORY_HOOK_CORE_SLUGS = "x";
      const umbrella = await import(`./lib/memory.mjs?umbrella-${Date.now()}`);
      ok(umbrella.resolveScopeFromEnvSafe() === null, "umbrella resolves the misconfig UNSCOPED (null)");
      ok(
        umbrella.DEFAULT_DB_PATH.endsWith("memory-index.db"),
        `lib module imports clean under the misconfig — unscoped db (${umbrella.DEFAULT_DB_PATH.split("/").pop()})`,
      );
      // End-to-end: the REAL hook process with the same env pair must run, exit 0,
      // emit nothing on stdout, and name the fail-open on stderr.
      const { spawnSync } = await import("node:child_process");
      const hookEnv = { ...process.env, MEMORY_HOOK_NO_LOG: "1" };
      delete hookEnv.MEMORY_HOOK_FUNCTION;
      hookEnv.MEMORY_HOOK_CORE_SLUGS = "x";
      const r = spawnSync(
        process.execPath,
        ["--experimental-sqlite", join(import.meta.dirname ?? ".", "hook.mjs")],
        { input: '{"prompt":"q"}', env: hookEnv, timeout: 30000 },
      );
      const out = (r.stdout || "").toString();
      const errOut = (r.stderr || "").toString();
      ok(r.status === 0, `hook exits 0 under the misconfig (got ${r.status})`);
      ok(out.trim() === "", "hook emits nothing on stdout under the misconfig");
      ok(/running UNSCOPED/.test(errOut), "hook NAMES the fail-open on stderr");
    } finally {
      delete env.MEMORY_HOOK_CORE_SLUGS;
      if (savedCore !== undefined) env.MEMORY_HOOK_CORE_SLUGS = savedCore;
      if (savedFn !== undefined) env.MEMORY_HOOK_FUNCTION = savedFn;
      else delete env.MEMORY_HOOK_FUNCTION;
      if (savedDb !== undefined) env.MEMORY_DB = savedDb;
      else delete env.MEMORY_DB;
    }
  }

  console.log("F-3 · hostile ambient env cannot flip an explicitly-pinned call:");
  {
    const savedFn = env.MEMORY_HOOK_FUNCTION;
    try {
      env.MEMORY_HOOK_FUNCTION = "beta"; // hostile ambient state (the eval-session shape)
      const pinned = listMemoryFiles(dir, null); // the eval's flat-arm pin
      ok(pinned.length === 5, `explicit scopeOpts:null ignores ambient scope (flat stays flat: ${pinned.length}/5 files)`);
      const hostileDb = join(TMP, "hostile-flat.db");
      // scopeOpts: null is the UNSCOPED pin ({scope: null} would be "scoped to
      // null" — not the same thing; see listMemoryFiles' contract).
      await buildIndex({ memoryDir: dir, dbPath: hostileDb, quiet: true, scopeOpts: null });
      const rows = new DatabaseSync(hostileDb).prepare(`SELECT slug FROM memories`).all().map((r) => r.slug);
      ok(rows.length === 5 && rows.includes("beta__queue-depth"), "pinned-flat buildIndex holds all files under hostile ambient env");
      // The ambient-resolving no-scopeOpts call keeps its PRODUCTION semantics:
      // it resolves the env knobs by design (the eval must pin, not the lib ignore).
      const ambient = listMemoryFiles(dir); // no scopeOpts — resolves ambient env
      ok(
        ambient.length === 2 && !ambient.some((f) => basename(f).startsWith("alpha")),
        "no-scopeOpts call still resolves ambient env (production semantics unchanged)",
      );
    } finally {
      if (savedFn !== undefined) env.MEMORY_HOOK_FUNCTION = savedFn;
      else delete env.MEMORY_HOOK_FUNCTION;
    }
  }

  console.log("F-4 · scope slug is validated ([A-Za-z0-9._-]+):");
  {
    await throws(
      () => resolveScopeFromEnv({ MEMORY_HOOK_FUNCTION: "../../evil-scope" }),
      "traversal slug throws at resolution",
      "not a valid function slug",
    );
    await throws(
      () => resolveScopeFromEnv({ MEMORY_HOOK_FUNCTION: "sub/dir" }),
      "pathed slug throws at resolution",
      "not a valid function slug",
    );
    ok(
      resolveScopeFromEnvSafe({ MEMORY_HOOK_FUNCTION: "../../evil-scope" }) === null,
      "invalid slug runs UNSCOPED through the umbrella",
    );
    // The filename keying itself: a fresh lib import under the hostile env must
    // land on the UNSCOPED db filename, never a traversal-keyed one.
    const savedFn4 = env.MEMORY_HOOK_FUNCTION;
    const savedDb4 = env.MEMORY_DB;
    try {
      env.MEMORY_HOOK_FUNCTION = "../../evil-scope";
      delete env.MEMORY_DB;
      const { DEFAULT_DB_PATH: safePath } = await import(`./lib/memory.mjs?f4safe-${Date.now()}`);
      ok(
        basename(safePath) === "memory-index.db",
        `invalid slug cannot key the DB filename — module import lands unscoped (${basename(safePath)})`,
      );
    } finally {
      if (savedFn4 !== undefined) env.MEMORY_HOOK_FUNCTION = savedFn4;
      else delete env.MEMORY_HOOK_FUNCTION;
      if (savedDb4 !== undefined) env.MEMORY_DB = savedDb4;
      else delete env.MEMORY_DB;
    }
  }

  console.log("F-5a · frontmatter beyond the 16KB head still declares:");
  {
    const deep = join(TMP, "deep-fm");
    mkdirSync(deep, { recursive: true });
    // The closing fence sits past DECLARATION_HEAD_BYTES — the head read can't
    // see it; parseMemoryFile (full read) WOULD find the declaration. Prefix
    // says "other", declaration says alpha: the fallback must let alpha win.
    writeFileSync(
      join(deep, "other__deep.md"),
      `---\ntype: project\nnote: ${"p".repeat(20000)}\nfunction: alpha\n---\nbody\n`,
    );
    const picked = listMemoryFiles(deep, { scope: "alpha", coreSlugs: [] });
    ok(
      picked.length === 1 && basename(picked[0]) === "other__deep.md",
      "unterminated-fence declaration found via full-read fallback (enumeration = record-scope)",
    );
  }

  console.log("F-5b · top-level vs private/ collision: one deterministic winner, loudly:");
  {
    const coll = join(TMP, "collide");
    mkdirSync(join(coll, "private"), { recursive: true });
    writeFileSync(join(coll, "dupe.md"), "---\ntype: project\n---\nTOP LEVEL BODY topmark\n");
    writeFileSync(join(coll, "private", "dupe.md"), "---\ntype: project\n---\nPRIVATE BODY privmark\n");
    const warnings = [];
    const realErr = console.error;
    console.error = (...a) => warnings.push(a.join(" "));
    try {
      const picked = listMemoryFiles(coll, null); // unscoped — the collision path
      ok(picked.length === 1, `collision enumerates ONE file (got ${picked.length})`);
      ok(
        picked.length === 1 && picked[0].includes("private"),
        "private/ deterministically shadows top-level",
      );
      ok(warnings.some((w) => w.includes("dupe")), "collision warns LOUDLY (names the slug)");
      const collDb = join(TMP, "collide.db");
      await buildIndex({ memoryDir: coll, dbPath: collDb, quiet: true });
      const rows = new DatabaseSync(collDb).prepare(`SELECT slug, body FROM memories`).all();
      ok(
        rows.length === 1 && rows[0].body.includes("privmark"),
        "index builds clean under the collision — one row, the private body",
      );
    } finally {
      console.error = realErr;
    }
  }

  console.log(`\n${fail === 0 ? "ALL GREEN" : "FAILURES PRESENT"} — ${pass} passed, ${fail} failed`);
  rmSync(TMP, { recursive: true, force: true });
  if (savedEmbedder === undefined) delete env.MEMORY_EMBEDDER;
  else env.MEMORY_EMBEDDER = savedEmbedder;
  if (fail > 0) process.exit(1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
