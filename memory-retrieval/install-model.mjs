#!/usr/bin/env node

// install-model.mjs — (re)install the LOCAL SEMANTIC EMBEDDING model into the
// PULL-DURABLE per-machine cache. The recovery half of the core-v0.4
// pull-durability fix (see lib/embeddings.mjs).
//
// THE GAP THIS CLOSES: the model used to live inside node_modules — a
// `kickoff pull` to a fresh core clone starts with an EMPTY node_modules, so
// every semantic adopter silently degraded to keyword-only on upgrade. Now the
// model resolves from modelCacheDir() (KICKOFF_MODEL_DIR → ~/.cache/kickoff-models),
// which no pull ever touches — and THIS script puts it there:
//
//   1. model already durable → no-op (fast, idempotent);
//   2. model only in a LEGACY in-node_modules cache → MIGRATE it out (copy,
//      local-disk, no network);
//   3. deps missing (the fresh-clone shape) → `pnpm install`, then `npm install` as the
//      native-build fallback — both SANDBOXED in a throwaway stage OUTSIDE the clone
//      (pnpm >= 10 mutates its tracked pnpm-workspace.yaml config store in cwd; the
//      READ-ONLY core clone must stay byte-clean or the next pull's whole-tree pin
//      check fails closed), with only node_modules swapped back in on success;
//   4. model missing everywhere → fetch-on-first-use via transformers.js
//      straight INTO the durable dir (~25MB, one-time, needs network).
//
// USAGE
//   node install-model.mjs                # ensure (verbose) — the operator path
//   node install-model.mjs --if-needed    # fast no-op unless semantic is in use
//                                         #   and broken (the `kickoff pull` hook)
//   node install-model.mjs --check        # report only, never modify
//                                         #   exit 0 healthy/not-in-use, 3 recovery needed
//   ./run.sh install-model [...]          # same, via the wrapper
//
// EXIT: 0 = semantic ready (or legitimately not in use) · 1 = recovery failed
// (message names the next step) · 3 = --check found recovery needed.

import { cpSync, existsSync, mkdirSync, mkdtempSync, renameSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// node:sqlite (the index-semantic check) is experimental in Node 22 → re-exec
// once with the flag, exactly like hook.mjs, so `node install-model.mjs` works bare.
if (
  !process.execArgv.some((a) => a.includes("experimental-sqlite")) &&
  !(process.env.NODE_OPTIONS || "").includes("experimental-sqlite") &&
  process.env.MEMORY_HOOK_REEXEC !== "1"
) {
  const { spawnSync } = await import("node:child_process");
  const res = spawnSync(process.execPath, [process.argv[1], ...process.argv.slice(2)], {
    stdio: "inherit",
    env: {
      ...process.env,
      MEMORY_HOOK_REEXEC: "1",
      NODE_OPTIONS: `${process.env.NODE_OPTIONS || ""} --experimental-sqlite`.trim(),
    },
  });
  process.exit(res.status ?? 0);
}

const {
  DEFAULT_MODEL_ID,
  LocalEmbeddingProvider,
  ensureModelDurable,
  legacyModelCacheDir,
  modelCacheDir,
  modelDirUnder,
  modelFilesPresent,
} = await import("./lib/embeddings.mjs");
const { DEFAULT_DB_PATH } = await import("./lib/memory.mjs");

const TOOL_DIR = dirname(fileURLToPath(import.meta.url));
const env = process.env;

const args = new Set(process.argv.slice(2));
const IF_NEEDED = args.has("--if-needed");
const CHECK_ONLY = args.has("--check");
const QUIET = args.has("--quiet");

const say = (...a) => {
  if (!QUIET) console.log("[install-model]", ...a);
};
const shout = (...a) => console.log("[install-model]", ...a); // the final verdict always prints
const err = (...a) => console.error("[install-model] ✗", ...a);

/** Can @xenova/transformers be resolved from THIS checkout? (no import) */
async function packagePresent() {
  const { createRequire } = await import("node:module");
  try {
    createRequire(import.meta.url).resolve("@xenova/transformers");
    return true;
  } catch {
    return false;
  }
}

/** Was this instance's retrieval index built with REAL embeddings? (cheap meta read) */
async function indexSemantic(dbPath) {
  if (!existsSync(dbPath)) return false;
  try {
    const { DatabaseSync } = await import("node:sqlite");
    const db = new DatabaseSync(dbPath);
    try {
      return (
        db.prepare(`SELECT value FROM meta WHERE key = 'embedder_semantic'`).get()?.value ===
        "true"
      );
    } finally {
      db.close();
    }
  } catch {
    return false; // unreadable index → can't claim semantic was in use
  }
}

/** Reinstall the tool deps — SANDBOXED outside the read-only core clone (pnpm first;
 *  npm as the native-build fallback).
 *
 *  WHY THE SANDBOX (the 2026-07-10 pull-breaker): pnpm >= 10 treats pnpm-workspace.yaml
 *  as its WRITABLE config store — `pnpm install` mutates that TRACKED file in its cwd
 *  (it writes ignoredBuiltDependencies etc., and can exit non-zero on top). Run with
 *  cwd = the pinned clone, that made the clone git-dirty between the pull's lock-write
 *  and its pin verify, so preflight #6 correctly failed closed on EVERY model-installing
 *  pull. The root-cause fix: each package manager runs in a throwaway STAGE outside the
 *  repo, holding COPIES of only the install inputs — it can mutate its copy freely — and
 *  on success only the stage's node_modules is swapped into TOOL_DIR/node_modules (a
 *  git-ignored path, so even crash residue is invisible to git). The clone stays
 *  byte-clean BY CONSTRUCTION, for any pnpm/npm version or future config-write behavior. */
async function installDeps() {
  const { spawnSync } = await import("node:child_process");
  const runs = [
    { cmd: "pnpm", argv: ["install", "--ignore-workspace"] },
    { cmd: "npm", argv: ["install", "--no-package-lock", "--no-audit", "--no-fund"] },
  ];
  // The stage lives under the durable model cache dir — known-writable on adopter boxes
  // (where /tmp can be noexec, which would break the native build scripts). A cross-
  // filesystem TOOL_DIR is covered by the EXDEV fallback in swapIn below.
  const stageRoot = join(modelCacheDir(), ".deps-stage");
  const inputs = ["package.json", ".npmrc", "pnpm-workspace.yaml", "pnpm-lock.yaml"];
  const makeStage = () => {
    mkdirSync(stageRoot, { recursive: true });
    const stage = mkdtempSync(join(stageRoot, "install-"));
    for (const f of inputs) {
      const src = join(TOOL_DIR, f);
      if (existsSync(src)) cpSync(src, join(stage, f));
    }
    return stage;
  };
  // Swap the stage's freshly-built node_modules into the tool dir WHOLESALE. This (a)
  // replaces any stale half-installed tree only AFTER a success — the pre-fix code
  // pre-wiped it before npm even ran, so a failed npm left nothing; and (b) lands ONLY
  // at the git-ignored node_modules path, never a tracked file or a stray sibling name.
  const swapIn = (stage) => {
    const built = join(stage, "node_modules");
    if (!existsSync(built)) return false; // exit 0 but nothing built → not a success
    const dest = resolve(TOOL_DIR, "node_modules");
    rmSync(dest, { recursive: true, force: true });
    try {
      renameSync(built, dest); // same-filesystem: one atomic move
    } catch (e) {
      if (e?.code !== "EXDEV") throw e;
      // Cross-filesystem stage (e.g. tmpfs vs the clone's disk): copy verbatim — pnpm's
      // layout is RELATIVE symlinks into node_modules/.pnpm, so the copy stays coherent.
      cpSync(built, dest, { recursive: true, verbatimSymlinks: true });
    }
    return true;
  };
  // Remember WHY the last manager we actually reached failed, so a NON-ZERO pnpm no
  // longer short-circuits the fallback — npm still gets its turn (the fresh-pull heal).
  // npm needs no pre-wipe: every manager installs into a FRESH stage (a clean slate by
  // construction, so npm's native build scripts run over a clean tree), and the stale
  // half-installed node_modules disappears in the wholesale swap on success.
  let lastWhy;
  for (const { cmd, argv } of runs) {
    let stage;
    try {
      stage = makeStage();
    } catch (e) {
      return { ok: false, why: `cannot create the install stage under ${stageRoot}: ${e?.message ?? e}` };
    }
    try {
      say(`installing deps: ${cmd} ${argv.join(" ")}  (staged in ${stage}; the read-only clone is never a package-manager cwd)`);
      const res = spawnSync(cmd, argv, {
        cwd: stage,
        stdio: QUIET ? "ignore" : "inherit",
      });
      if (res.error && res.error.code === "ENOENT") {
        say(`${cmd} not found — trying the next package manager`);
        continue;
      }
      if (res.status === 0) {
        try {
          if (swapIn(stage)) return { ok: true, via: cmd };
          lastWhy = `${cmd} install exited 0 but produced no node_modules`;
        } catch (e) {
          lastWhy = `${cmd} installed, but swapping node_modules into ${TOOL_DIR} failed: ${e?.message ?? e}`;
        }
        continue;
      }
      // Non-zero exit: record it and FALL THROUGH to the next manager (the pre-fix code
      // `return`ed here, so a failed pnpm never let npm run).
      lastWhy = `${cmd} install exited ${res.status}`;
    } finally {
      rmSync(stage, { recursive: true, force: true });
    }
  }
  // CAVEAT owned honestly: a pnpm-ONLY box (no npm on PATH) still can't heal this way —
  // pnpm 11.x won't build the native onnxruntime-node dep under any config, and the npm
  // fallback ENOENTs — so the fallback is "npm if present", not a universal heal.
  return { ok: false, why: lastWhy ?? "no package manager found (install pnpm or npm)" };
}

/** Fetch the model into the durable dir via transformers.js fetch-on-first-use
 *  (LocalEmbeddingProvider pins cacheDir to the durable dir when nothing is on
 *  disk yet, so the download lands pull-durable by construction). */
async function fetchModel() {
  if (env.KICKOFF_MODEL_OFFLINE === "1") {
    return { ok: false, why: "KICKOFF_MODEL_OFFLINE=1 pins offline mode — cannot fetch" };
  }
  say(`fetching ${DEFAULT_MODEL_ID} (~25MB, one-time) → ${modelCacheDir()} …`);
  try {
    const provider = new LocalEmbeddingProvider();
    const [probe] = await provider.embed(["kickoff semantic model warm-up probe"]);
    if (!Array.isArray(probe) || probe.length !== provider.dims) {
      return { ok: false, why: `probe embed returned ${probe?.length ?? "nothing"} dims` };
    }
    return { ok: true };
  } catch (e) {
    return { ok: false, why: e?.message ?? String(e) };
  }
}

async function main() {
  const durable = modelCacheDir();
  const legacy = legacyModelCacheDir();
  let pkg = await packagePresent();
  let durablePresent = modelFilesPresent(durable);
  const legacyPresent = legacy ? modelFilesPresent(legacy) : false;
  const indexSem = await indexSemantic(DEFAULT_DB_PATH);
  const choice = (env.MEMORY_EMBEDDER || "").toLowerCase();

  say(`durable model dir: ${modelDirUnder(durable)} ${durablePresent ? "(present)" : "(absent)"}`);
  say(
    `legacy in-node_modules cache: ${legacy ? modelDirUnder(legacy) : "(package not installed)"}` +
      `${legacyPresent ? " (present)" : ""}`,
  );
  say(`embedding package installed here: ${pkg} · index semantic: ${indexSem}`);

  // Explicitly steered AWAY from the local model → nothing to manage here.
  if (choice === "hashing" || choice === "openai") {
    shout(`MEMORY_EMBEDDER=${choice} — the local semantic model is not in use; nothing to do.`);
    return 0;
  }

  const healthy = pkg && durablePresent;
  const inUse = choice === "local" || pkg || durablePresent || legacyPresent || indexSem;

  if (CHECK_ONLY) {
    if (healthy) {
      shout("OK — semantic model present in the durable dir and the package is installed.");
      return 0;
    }
    if (!inUse) {
      shout("semantic not in use (keyword-only instance) — nothing to recover.");
      return 0;
    }
    shout(
      `RECOVERY NEEDED — ${pkg ? "" : "deps missing; "}${durablePresent ? "" : "model not durable; "}` +
        `run: node ${resolve(TOOL_DIR, "install-model.mjs")}`,
    );
    return 3;
  }

  if (IF_NEEDED && healthy) {
    shout("OK — semantic model already pull-durable; nothing to do.");
    return 0;
  }
  if (IF_NEEDED && !inUse) {
    // A keyword-only (v0.3-style) instance: no package, no model, stub index.
    // Stay a no-op — never surprise-install ~200MB of deps on an adopter that
    // never opted into semantic search.
    shout("semantic not in use (keyword-only instance) — nothing to recover.");
    return 0;
  }

  // ── 1. migrate a legacy in-node_modules model out (no network) ──────────────
  if (!durablePresent && legacyPresent) {
    const r = ensureModelDurable({ log: (m) => say(m) });
    durablePresent = r.source === "migrated" || modelFilesPresent(durable);
    if (!durablePresent) {
      err(`could not migrate the legacy model into ${durable} (permissions/disk?)`);
      // fall through — a fetch can still populate the durable dir
    }
  }

  // ── 2. deps (the fresh-core-clone shape) ────────────────────────────────────
  if (!pkg) {
    const r = await installDeps();
    if (!r.ok) {
      err(`dependency install failed: ${r.why}`);
      err(`heal by hand:  cd ${TOOL_DIR} && npm install`);
      return 1;
    }
    pkg = await packagePresent();
    if (!pkg) {
      err("deps installed but @xenova/transformers still does not resolve — inspect node_modules");
      return 1;
    }
    say(`deps installed via ${r.via}`);
  }

  // ── 3. model (download only if it is nowhere on disk) ───────────────────────
  if (!durablePresent) {
    const r = await fetchModel();
    if (!r.ok) {
      err(`model fetch failed: ${r.why}`);
      err(
        `retrieval keeps working KEYWORD-ONLY until healed — re-run this script with network` +
          ` (or pre-seed ${modelDirUnder(durable)} from another machine).`,
      );
      return 1;
    }
    durablePresent = modelFilesPresent(durable);
    if (!durablePresent) {
      err(`probe embed succeeded but the model did not land in ${modelDirUnder(durable)}`);
      return 1;
    }
  }

  shout(`OK — semantic model ready + pull-durable at ${modelDirUnder(durable)}.`);
  if (indexSem) {
    say("index is already semantic — the hook picks the model up on its next fire.");
  } else {
    say("to (re)build the index with real embeddings:  ./run.sh index");
  }
  return 0;
}

main().then(
  (code) => process.exit(code),
  (e) => {
    err(e?.stack ?? String(e));
    process.exit(1);
  },
);
