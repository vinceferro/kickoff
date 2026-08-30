#!/usr/bin/env node
// secret-decrypt.mjs — box-side decryption of a provisioned secret.
//
// Runs on the box, where the private key lives. Takes the ciphertext payload
// produced by the MC browser (or secret-encrypt.mjs), unwraps the AES key with
// the box private key, and recovers the plaintext secret. Plaintext exists only
// here, at the agent's moment of use — never in mission-state, logs, or Telegram.
//
// v2 payloads bind {v, alg, name, nonce, ts} into the AES-GCM additionalData
// (AAD): if any of those metadata fields was altered in transit, the GCM auth
// fails here and NO plaintext is emitted (M1). v1 payloads (no AAD/replay) are
// refused — re-provision through the updated Secrets panel.
//
// Usage:
//   node scripts/secret-decrypt.mjs [payload.json]            # prints plaintext to stdout
//   ... | node scripts/secret-decrypt.mjs                     # payload from stdin
//   node scripts/secret-decrypt.mjs payload.json --write-env .env --key SUPABASE_KEY   # upsert into .env
// Options:
//   --priv <path>       private key (default ~/.kickoff/secret-box/private.pem)
//   --write-env <path>  upsert KEY=plaintext into this file (mode 0600) instead of printing
//   --key <NAME>        the env var name to write (required with --write-env)
//   --allow <A,B,...>   CLOSED allow-list of permitted --key names (M2). Also read
//                       from KICKOFF_SECRET_ALLOWED_KEYS or <keydir>/allowed-keys.json.
//                       --write-env is REFUSED unless an allow-list is configured.
//   --allow-file <path> read the allow-list / pinned env path from this JSON config
//                       ({ "keys": [...], "envPath": "/abs/.env" }).
//   --env-path <path>   pin the .env path (M2). Also KICKOFF_SECRET_ENV_PATH or the
//                       config's "envPath". When pinned, --write-env MUST equal it.
//   --keep              do NOT delete the consumed inbox file (default: delete on
//                       successful consume — M3, the file is one-shot).
// (named --write-env, not --env-file, to avoid colliding with node's built-in --env-file flag.)

import { webcrypto as wc } from "node:crypto";
import { readFile, writeFile, chmod, stat, unlink } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname, resolve } from "node:path";

const ALG = "RSA-OAEP-SHA256+AES-256-GCM";
const INPUT_CAP = 64 * 1024;   // L3 — bound stdin/file so a huge input can't OOM the box

const argv = process.argv.slice(2);
const flags = {
  "--priv": undefined, "--write-env": undefined, "--key": undefined,
  "--allow": undefined, "--allow-file": undefined, "--env-path": undefined,
};
const boolFlags = new Set(["--keep"]);
const opts = { keep: false };
const positionals = [];
for (let i = 0; i < argv.length; i++) {
  if (boolFlags.has(argv[i])) { if (argv[i] === "--keep") opts.keep = true; }
  else if (Object.prototype.hasOwnProperty.call(flags, argv[i])) { flags[argv[i]] = argv[++i]; }
  else { positionals.push(argv[i]); }
}
const privPath = flags["--priv"] || join(homedir(), ".kickoff", "secret-box", "private.pem");
const envFile = flags["--write-env"];
const envKey = flags["--key"];
const payloadArg = positionals[0];

function derFromPem(pem) {
  const b64 = pem.replace(/-----BEGIN [^-]+-----/, "").replace(/-----END [^-]+-----/, "").replace(/\s+/g, "");
  return Buffer.from(b64, "base64");
}
async function readStdinCapped(cap) {
  const chunks = []; let total = 0;
  for await (const c of process.stdin) {
    total += c.length;
    if (total > cap) { console.error(`input exceeds ${cap}-byte cap — refusing (L3)`); process.exit(1); }
    chunks.push(c);
  }
  return Buffer.concat(chunks).toString("utf8");
}
const fromB64 = (s) => Buffer.from(s, "base64");
// Canonical AAD — MUST be byte-identical to secret-encrypt.mjs + mc-secrets-input.html.
function aadBytes({ v, alg, name, nonce, ts }) {
  return new TextEncoder().encode(JSON.stringify([v, alg, name ?? "", nonce, ts]));
}

// ── M2: resolve the CLOSED allow-list + pinned env path (adopter-configurable) ──
let _cfgCache;
function loadConfigFile() {
  if (_cfgCache !== undefined) return _cfgCache;
  const cfgPath = flags["--allow-file"] || join(dirname(privPath), "allowed-keys.json");
  try {
    const cfg = JSON.parse(readFileSync(cfgPath, "utf8"));
    _cfgCache = cfg && typeof cfg === "object" ? cfg : {};
  } catch { _cfgCache = {}; }
  return _cfgCache;
}

function resolveAllowList() {
  if (flags["--allow"] !== undefined) {
    return flags["--allow"].split(",").map((s) => s.trim()).filter(Boolean);
  }
  if (process.env.KICKOFF_SECRET_ALLOWED_KEYS !== undefined) {
    return process.env.KICKOFF_SECRET_ALLOWED_KEYS.split(",").map((s) => s.trim()).filter(Boolean);
  }
  const cfg = loadConfigFile();
  if (Array.isArray(cfg.keys)) return cfg.keys.map((s) => String(s).trim()).filter(Boolean);
  return null;   // NONE configured
}
function resolvePinnedPath() {
  if (flags["--env-path"]) return flags["--env-path"];
  if (process.env.KICKOFF_SECRET_ENV_PATH) return process.env.KICKOFF_SECRET_ENV_PATH;
  const cfg = loadConfigFile();
  if (typeof cfg.envPath === "string" && cfg.envPath) return cfg.envPath;
  return null;
}

// ── read + parse the payload (size-bounded) ──
let raw;
if (payloadArg) {
  let st;
  try { st = await stat(payloadArg); } catch { console.error(`cannot stat ${payloadArg}`); process.exit(1); }
  if (st.size > INPUT_CAP) { console.error(`payload file ${st.size}B exceeds ${INPUT_CAP}-byte cap — refusing (L3)`); process.exit(1); }
  raw = await readFile(payloadArg, "utf8");
} else {
  raw = await readStdinCapped(INPUT_CAP);
}
let payload;
try { payload = JSON.parse(raw); } catch { console.error("payload is not valid JSON"); process.exit(1); }

// ── strict, fail-closed payload validation ──
if (payload.v !== 2) {
  console.error("unsupported payload version (need v2 — AAD+replay bound). v1 payloads predate replay/AAD protection; re-provision via the updated Secrets panel.");
  process.exit(1);
}
if (payload.alg !== ALG) { console.error(`unexpected alg ${JSON.stringify(payload.alg)} — refusing`); process.exit(1); }
if (!payload.wrappedKey || !payload.iv || !payload.ciphertext) {
  console.error("payload missing wrappedKey/iv/ciphertext"); process.exit(1);
}
if (typeof payload.nonce !== "string" || !payload.nonce) { console.error("payload missing nonce (v2 replay binding)"); process.exit(1); }
if (typeof payload.ts !== "number" || !Number.isFinite(payload.ts)) { console.error("payload missing/invalid ts (v2 freshness binding)"); process.exit(1); }
const name = typeof payload.name === "string" ? payload.name : "";

// ── M2: gate --write-env on the allow-list + pinned path BEFORE we ever decrypt ──
if (envFile) {
  if (!envKey) { console.error("--write-env requires --key <NAME>"); process.exit(1); }
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(envKey)) {
    console.error(`invalid --key '${envKey}' (must match ^[A-Za-z_][A-Za-z0-9_]*$)`); process.exit(1);
  }
  const allowed = resolveAllowList();
  if (allowed === null) {
    console.error("refusing --write-env: no allow-list configured. Set --allow K1,K2 / KICKOFF_SECRET_ALLOWED_KEYS / <keydir>/allowed-keys.json (M2, fail-closed).");
    process.exit(1);
  }
  if (!allowed.includes(envKey)) {
    console.error(`--key '${envKey}' is not in the allow-list [${allowed.join(", ")}] — refusing (M2).`); process.exit(1);
  }
  const pinned = resolvePinnedPath();
  if (pinned && resolve(envFile) !== resolve(pinned)) {
    console.error(`--write-env '${resolve(envFile)}' does not match the pinned env path '${resolve(pinned)}' — refusing (M2).`); process.exit(1);
  }
}

const privKey = await wc.subtle.importKey(
  "pkcs8", derFromPem(await readFile(privPath, "utf8")),
  { name: "RSA-OAEP", hash: "SHA-256" }, false, ["decrypt"],
);

let rawAes, aesKey, plaintextBuf;
try {
  rawAes = await wc.subtle.decrypt({ name: "RSA-OAEP" }, privKey, fromB64(payload.wrappedKey));
  aesKey = await wc.subtle.importKey("raw", rawAes, { name: "AES-GCM" }, false, ["decrypt"]);
  const aad = aadBytes({ v: payload.v, alg: payload.alg, name, nonce: payload.nonce, ts: payload.ts });
  plaintextBuf = await wc.subtle.decrypt({ name: "AES-GCM", iv: fromB64(payload.iv), additionalData: aad }, aesKey, fromB64(payload.ciphertext));
} catch {
  console.error("decryption failed — wrong key, corrupted payload, or tampering (GCM auth / AAD mismatch)"); process.exit(1);
}
const plaintext = new TextDecoder().decode(plaintextBuf);

if (envFile) {
  // Reject control chars in the secret value: a newline would inject extra env vars
  // (the value comes from an untrusted relay/operator).
  if (/[\r\n\0]/.test(plaintext)) {
    console.error("secret value contains a newline/control char; refusing to write to .env"); process.exit(1);
  }
  let body = "";
  try { body = await readFile(envFile, "utf8"); } catch { /* new file */ }
  const line = `${envKey}=${plaintext}`;
  const re = new RegExp(`^${envKey}=.*$`, "m");
  // Function replacer so `$&`/`$1`/etc. in the secret are written literally, not expanded.
  body = re.test(body) ? body.replace(re, () => line) : (body && !body.endsWith("\n") ? body + "\n" : body) + line + "\n";
  await writeFile(envFile, body, { mode: 0o600 });
  await chmod(envFile, 0o600);
  console.error(`✅ wrote ${envKey} to ${envFile} (0600)`);   // confirmation to stderr; plaintext never printed
} else {
  process.stdout.write(plaintext);
}

// ── M3: delete-on-consume. A successfully decrypted inbox file is one-shot —
// remove it so it can't be re-read/replayed and the blast radius shrinks. --keep opts out.
if (payloadArg && !opts.keep) {
  try { await unlink(payloadArg); console.error(`🗑  consumed ${payloadArg} (deleted; pass --keep to retain)`); }
  catch (e) { console.error(`note: could not delete consumed file ${payloadArg}: ${e.message}`); }
}
