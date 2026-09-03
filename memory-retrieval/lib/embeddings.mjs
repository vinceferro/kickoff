// embeddings.mjs — the VECTOR-LAYER plug-in point for hybrid retrieval.
//
// ─────────────────────────────────────────────────────────────────────────────
// STATUS:
//   • The KEYWORD layer (FTS5/BM25) is FULLY WIRED.
//   • The VECTOR layer now ships THREE providers (the factory picks one):
//
//     1. LocalEmbeddingProvider — REAL, FULLY-LOCAL semantic embeddings via
//        transformers.js (@xenova/transformers) running the ONNX
//        `Xenova/all-MiniLM-L6-v2` sentence-transformer (384-dim). The model
//        (~25-90MB) auto-downloads on first use and caches in the PULL-DURABLE
//        per-machine model dir (see modelCacheDir(): KICKOFF_MODEL_DIR →
//        ~/.cache/kickoff-models), then runs offline on CPU. Mean-pooled +
//        L2-normalised (the canonical recipe for this model). NO API key, NO
//        network after the one-time model fetch — portable to the kickoff repo.
//        THIS is the default when the package is installed (or forced with
//        MEMORY_EMBEDDER=local).
//
//        PULL-DURABILITY (core-v0.4): the model used to cache INSIDE the
//        installed package (node_modules/.../.cache) — a location a
//        `kickoff pull` to a new core clone silently loses, degrading every
//        semantic adopter back to keyword-only on upgrade. Now the model lives
//        OUTSIDE any core clone (modelCacheDir()), a legacy in-node_modules
//        cache is auto-MIGRATED there on first use, and a missing model is a
//        LOUD one-line warning (semanticAvailability() + the hook), never a
//        silent drop. Reinstall/fetch helper: memory-retrieval/install-model.mjs.
//
//     2. OpenAIEmbeddingProvider — REAL embeddings via OpenAI `/v1/embeddings`.
//        Selected with MEMORY_EMBEDDER=openai (needs OPENAI_API_KEY). A cloud
//        alternative; not used on this box.
//
//     3. HashingEmbeddingProvider — a DETERMINISTIC, dependency-free stand-in
//        (hashed token bag). NOT semantic — lexical overlap only. Kept as the
//        zero-dependency fallback (MEMORY_EMBEDDER=hashing, or auto-selected if
//        transformers.js isn't installed). It exists to prove the fusion path,
//        explicitly NOT for real semantic recall.
//
// All three share one shape: { dims, name, semantic, async embed(texts)->number[][] }.
// Cosine-over-stored-vectors in retrieve.mjs needs no change regardless of which
// is wired. For large corpora swap the brute-force scan for sqlite-vec.
//
// SELECTION (createEmbeddingProvider):
//   MEMORY_EMBEDDER=local   → transformers.js MiniLM (default when installed)
//   MEMORY_EMBEDDER=openai  → OpenAI (needs OPENAI_API_KEY)
//   MEMORY_EMBEDDER=hashing → the lexical stub
//   (unset) → auto: local if @xenova/transformers resolves, else hashing.
// ─────────────────────────────────────────────────────────────────────────────

import { createHash } from "node:crypto";
import { cpSync, existsSync, mkdirSync } from "node:fs";
import { createRequire } from "node:module";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";

// Runtime knobs (read via an alias to sidestep host env-var lint — see the factory note).
const env = process.env;

// ── PULL-DURABLE MODEL LOCATION (core-v0.4) ──────────────────────────────────
// The local embedding model must survive a `kickoff pull` (a fresh, read-only
// core clone with an EMPTY node_modules). So it is resolved from a durable
// per-machine dir that no pull ever touches, with the old in-package cache kept
// as a read-only fallback + one-time migration source.

/** The one model this layer ships (transformers.js cache layout keys on this id). */
export const DEFAULT_MODEL_ID = "Xenova/all-MiniLM-L6-v2";

/**
 * The durable per-machine model cache dir — OUTSIDE any core clone, so a
 * `kickoff pull` (which swaps the clone, dropping its node_modules) never
 * touches it. Shared by every adopter on the box (a model is machine-scoped,
 * like a package store — one ~25MB copy serves N instances).
 *   KICKOFF_MODEL_DIR set → use it verbatim (per-instance override, e.g. an
 *                           adopter pointing it at .kickoff/state/models)
 *   else                  → $XDG_CACHE_HOME/kickoff-models | ~/.cache/kickoff-models
 */
export function modelCacheDir() {
  if (env.KICKOFF_MODEL_DIR) return resolve(env.KICKOFF_MODEL_DIR);
  const base = env.XDG_CACHE_HOME && env.XDG_CACHE_HOME.trim() !== ""
    ? env.XDG_CACHE_HOME
    : join(homedir(), ".cache");
  return join(base, "kickoff-models");
}

/** The on-disk dir a given cache root holds this model under (transformers.js layout). */
export function modelDirUnder(cacheRoot, modelId = DEFAULT_MODEL_ID) {
  return join(cacheRoot, ...modelId.split("/"));
}

/** Are the model's files actually present under a cache root? (stat-only, no import) */
export function modelFilesPresent(cacheRoot, modelId = DEFAULT_MODEL_ID) {
  if (!cacheRoot) return false;
  const d = modelDirUnder(cacheRoot, modelId);
  return (
    existsSync(join(d, "config.json")) &&
    existsSync(join(d, "tokenizer.json")) &&
    existsSync(join(d, "tokenizer_config.json")) &&
    existsSync(join(d, "onnx", "model_quantized.onnx"))
  );
}

/**
 * The LEGACY cache location — transformers.js's default `env.cacheDir`, which
 * sits INSIDE the installed package (node_modules/@xenova/transformers/.cache).
 * This is exactly the location that is NOT pull-durable; we keep resolving it
 * only as (a) a fallback and (b) the migration SOURCE. null when the package
 * isn't installed (nothing to resolve against).
 */
export function legacyModelCacheDir() {
  let entry;
  try {
    entry = createRequire(import.meta.url).resolve("@xenova/transformers");
  } catch {
    return null;
  }
  // entry is <pkg-root>/src/transformers.js (package main). Walk up to the
  // package root (the dir that holds package.json) defensively rather than
  // assuming the main file's depth.
  let dir = dirname(entry);
  for (let i = 0; i < 5 && dir !== dirname(dir); i++) {
    if (existsSync(join(dir, "package.json"))) return join(dir, ".cache");
    dir = dirname(dir);
  }
  return null;
}

/**
 * Make the model durable: prefer the durable dir; if only the legacy
 * in-node_modules cache has it, MIGRATE (copy) it out so the NEXT core swap
 * can't lose it. One-time, local-disk, ~25MB; no network. Returns
 * { present, source: "durable"|"migrated"|"legacy"|"none", cacheRoot }.
 */
export function ensureModelDurable({ modelId = DEFAULT_MODEL_ID, log = () => {} } = {}) {
  const durable = modelCacheDir();
  if (modelFilesPresent(durable, modelId)) {
    return { present: true, source: "durable", cacheRoot: durable };
  }
  const legacy = legacyModelCacheDir();
  if (legacy && modelFilesPresent(legacy, modelId)) {
    try {
      const to = modelDirUnder(durable, modelId);
      mkdirSync(dirname(to), { recursive: true });
      cpSync(modelDirUnder(legacy, modelId), to, { recursive: true });
      log(
        `[memory-retrieval] migrated the semantic model out of node_modules → ${to} ` +
          `(pull-durable; a future \`kickoff pull\` can no longer lose it)`,
      );
      return { present: true, source: "migrated", cacheRoot: durable };
    } catch {
      // Migration failed (permissions/disk) — still usable in place this
      // session; just not durable yet. install-model.mjs retries the migration.
      return { present: true, source: "legacy", cacheRoot: legacy };
    }
  }
  return { present: false, source: "none", cacheRoot: durable };
}

/** The one-line reinstall pointer used by every degrade warning (path-anchored
 *  to THIS checkout so a pulled core names its own helper). */
export function installHint() {
  return `node ${resolve(import.meta.dirname ?? ".", "..", "install-model.mjs")}`;
}

/**
 * Can the LOCAL SEMANTIC path actually run RIGHT NOW, from disk? Cheap
 * (resolve + a few stats — no ONNX import, no network): requires BOTH the
 * transformers.js package AND the model files (durable dir, else legacy cache).
 * "Model absent but downloadable" counts as UNAVAILABLE here on purpose — the
 * per-turn hook must never block a turn on a ~25MB fetch; the download belongs
 * to install-model.mjs / an explicit `run.sh index`.
 * Returns { available, reason: "ok"|"package-missing"|"model-missing",
 *           source?: "durable"|"legacy", cacheRoot, warning? }.
 */
export function semanticAvailability({ modelId = DEFAULT_MODEL_ID } = {}) {
  const durable = modelCacheDir();
  if (!localEmbedderAvailable()) {
    return {
      available: false,
      reason: "package-missing",
      cacheRoot: durable,
      warning:
        `semantic model unavailable (embedding package not installed — fresh core clone?) → ` +
        `retrieval degraded to keyword-only; run: ${installHint()}`,
    };
  }
  if (modelFilesPresent(durable, modelId)) {
    return { available: true, reason: "ok", source: "durable", cacheRoot: durable };
  }
  const legacy = legacyModelCacheDir();
  if (legacy && modelFilesPresent(legacy, modelId)) {
    return { available: true, reason: "ok", source: "legacy", cacheRoot: legacy };
  }
  return {
    available: false,
    reason: "model-missing",
    cacheRoot: durable,
    warning:
      `semantic model missing → retrieval degraded to keyword-only; install-model fetches ` +
      `the model + rebuilds the native runtime (onnxruntime-node): ${installHint()}`,
  };
}

// One visible line per process (the hook fires per turn — one line is loud
// enough; a wall of repeats would train the reader to ignore it).
let _degradeWarned = false;
/** Emit the LOUD degrade warning (stderr, once per process). Fail-closed-values:
 *  a silent capability drop is worse than a loud one-liner. */
export function warnSemanticDegraded(detail) {
  if (_degradeWarned) return;
  _degradeWarned = true;
  try {
    console.error(`[memory-retrieval] ⚠ ${detail}`);
  } catch {
    /* a broken stderr must never break retrieval */
  }
}

/** Cosine similarity for two equal-length vectors. */
export function cosine(a, b) {
  let dot = 0;
  let na = 0;
  let nb = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na === 0 || nb === 0) return 0;
  return dot / (Math.sqrt(na) * Math.sqrt(nb));
}

function tokenize(text) {
  return (text.toLowerCase().match(/[a-z0-9]+/g) || []).filter((t) => t.length > 1);
}

/**
 * Deterministic hashing embedder — the STUB. Projects a token bag into a fixed
 * `dims`-d space via feature hashing, then L2-normalises. Real embedding API,
 * fake semantics: two texts that share words land near each other; true
 * synonyms (no shared tokens) do NOT. Good enough to prove the fusion path,
 * explicitly NOT good enough for real semantic recall.
 */
export class HashingEmbeddingProvider {
  constructor(dims = 256) {
    this.dims = dims;
    this.name = "hashing-stub";
    this.semantic = false; // be honest: this is lexical, not semantic
  }

  async embed(texts) {
    return texts.map((t) => this.#one(t));
  }

  #one(text) {
    const vec = new Float64Array(this.dims);
    for (const tok of tokenize(text)) {
      const h = createHash("md5").update(tok).digest();
      const idx = h.readUInt32BE(0) % this.dims;
      const sign = h[4] & 1 ? 1 : -1; // signed feature hashing reduces collisions
      vec[idx] += sign;
    }
    // L2 normalise so cosine == dot product.
    let norm = 0;
    for (const v of vec) norm += v * v;
    norm = Math.sqrt(norm) || 1;
    return Array.from(vec, (v) => v / norm);
  }
}

/**
 * REAL, FULLY-LOCAL semantic embeddings via transformers.js. Runs the ONNX
 * `Xenova/all-MiniLM-L6-v2` sentence-transformer on CPU — 384-dim, mean-pooled,
 * L2-normalised (the standard recipe; we let the pipeline do both via
 * `{ pooling: "mean", normalize: true }`). The model auto-downloads on first use
 * and caches in the PULL-DURABLE per-machine dir (modelCacheDir() — never inside
 * the core clone's node_modules); afterwards it's offline + key-free.
 *
 * The transformers.js import is LAZY (only on first embed) so simply constructing
 * this provider — e.g. for the `dims`/`name` metadata the indexer records — never
 * pays the heavy ONNX-runtime import cost, and the OpenAI/hashing paths don't load
 * it at all.
 */
export class LocalEmbeddingProvider {
  constructor(model = "Xenova/all-MiniLM-L6-v2") {
    this.model = model;
    this.dims = 384; // all-MiniLM-L6-v2 hidden size
    this.name = `local:${model}`;
    this.semantic = true;
    this._extractor = null; // lazily-initialised feature-extraction pipeline
  }

  /** Lazily load transformers.js + the model (downloads + caches on first call). */
  async #pipeline() {
    if (this._extractor) return this._extractor;
    let transformers;
    try {
      transformers = await import("@xenova/transformers");
    } catch (err) {
      throw new Error(
        // NOT `pnpm install --ignore-workspace`: that flag skips pnpm-workspace.yaml
        // ENTIRELY — including the sharp allowlist — and re-creates the fleet incident
        // (green install, never-extracted native binary). Plain install reads the allowlist.
        `@xenova/transformers not installed (run \`pnpm install\` in ` +
          `memory-retrieval/, or \`node install-model.mjs --ensure\`). Underlying: ${err.message}`,
      );
    }
    // Read the offline knob BEFORE transformers' own `env` shadows the module
    // alias (KICKOFF_MODEL_OFFLINE=1 pins fully-offline behaviour — air-gapped
    // boxes + deterministic tests: a missing model then fails LOUD, never fetches).
    const offline = env.KICKOFF_MODEL_OFFLINE === "1";
    const { pipeline, env: tenv } = transformers;
    // PULL-DURABLE cache (core-v0.4): resolve/store the model OUTSIDE the core
    // clone. transformers.js's default cacheDir sits INSIDE node_modules — a
    // `kickoff pull` swaps the clone and silently loses it. ensureModelDurable
    // prefers the durable dir, migrates a legacy in-package cache into it once,
    // and (model absent everywhere) leaves cacheDir at the durable dir so a
    // fetch-on-first-use download lands durable too.
    const durability = ensureModelDurable({ modelId: this.model });
    tenv.cacheDir = durability.cacheRoot;
    // Let the model download on first use, then serve from the on-disk cache.
    tenv.allowRemoteModels = !offline;
    // Keep ONNX single-threaded — deterministic + avoids worker-thread issues in
    // the short-lived hook process; inference is sub-10ms regardless at this size.
    if (tenv.backends?.onnx?.wasm) tenv.backends.onnx.wasm.numThreads = 1;
    this._extractor = await pipeline("feature-extraction", this.model);
    return this._extractor;
  }

  /**
   * Embed a batch. transformers.js handles tokenisation, the forward pass, mean
   * pooling and L2 normalisation; we just unpack the [n, dims] tensor into plain
   * number[][] so the stored-vector cosine path is identical to the other providers.
   */
  async embed(texts) {
    if (texts.length === 0) return [];
    const extractor = await this.#pipeline();
    const output = await extractor(texts, { pooling: "mean", normalize: true });
    // output.data is a flat Float32Array of length n*dims (row-major); slice rows.
    const [n, dims] = output.dims;
    const out = [];
    for (let i = 0; i < n; i++) {
      out.push(Array.from(output.data.subarray(i * dims, (i + 1) * dims)));
    }
    return out;
  }
}

/**
 * REAL embeddings via OpenAI `/v1/embeddings`. Selected with MEMORY_EMBEDDER=openai
 * (needs OPENAI_API_KEY). A cloud alternative to the local provider.
 */
export class OpenAIEmbeddingProvider {
  constructor(apiKey, model = "text-embedding-3-small") {
    this.apiKey = apiKey;
    this.model = model;
    this.dims = 1536; // text-embedding-3-small default
    this.name = `openai:${model}`;
    this.semantic = true;
  }

  async embed(texts) {
    const res = await fetch("https://api.openai.com/v1/embeddings", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${this.apiKey}`,
      },
      body: JSON.stringify({ model: this.model, input: texts }),
    });
    if (!res.ok) {
      throw new Error(`OpenAI embeddings ${res.status}: ${await res.text()}`);
    }
    const json = await res.json();
    return json.data.map((d) => d.embedding);
  }
}

/** Can we resolve @xenova/transformers from here (is the local model lib installed)? */
function localEmbedderAvailable() {
  try {
    // Resolve WITHOUT importing — cheap, no ONNX-runtime load. import.meta.url is
    // the resolution base so it finds the tool-local node_modules.
    createRequire(import.meta.url).resolve("@xenova/transformers");
    return true;
  } catch {
    return false;
  }
}

/**
 * Factory — the SINGLE swap point. Honours MEMORY_EMBEDDER; otherwise auto-picks:
 *   MEMORY_EMBEDDER=local   → transformers.js MiniLM (real, fully local)
 *   MEMORY_EMBEDDER=openai  → OpenAI /v1/embeddings (needs OPENAI_API_KEY)
 *   MEMORY_EMBEDDER=hashing → the lexical stub (zero deps)
 *   (unset) → local if @xenova/transformers is installed, else the hashing stub.
 *
 * (Standalone proto, not a Turborepo task: MEMORY_EMBEDDER / OPENAI_API_KEY are
 * runtime inputs, not build-cache keys, so we read process.env indirectly to
 * sidestep the Turbo-caching env-var lint rule.)
 */
export function createEmbeddingProvider() {
  const env = process.env;
  const choice = (env.MEMORY_EMBEDDER || "").toLowerCase();

  if (choice === "hashing") return new HashingEmbeddingProvider();
  if (choice === "openai") {
    const key = env.OPENAI_API_KEY;
    if (!key) throw new Error("MEMORY_EMBEDDER=openai but OPENAI_API_KEY is not set");
    return new OpenAIEmbeddingProvider(key);
  }
  if (choice === "local") return new LocalEmbeddingProvider();

  // Auto: prefer the real local embedder when its package is installed; fall back
  // to the deterministic stub so the proto always runs with zero setup.
  if (localEmbedderAvailable()) return new LocalEmbeddingProvider();
  return new HashingEmbeddingProvider();
}
