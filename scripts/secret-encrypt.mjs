#!/usr/bin/env node
// secret-encrypt.mjs — REFERENCE of the client-side (MC browser) encryption.
//
// The browser does this with WebCrypto (see docs/secret-provisioning/mc-secrets-input.html);
// this node port is the canonical algorithm + the round-trip test fixture. It
// produces the exact payload layout the browser produces (AES-GCM appends its
// 16-byte tag to the ciphertext), so browser-encrypt ↔ box-decrypt interoperate.
//
// Hybrid: random AES-256-GCM key encrypts the secret; the box's RSA-OAEP public
// key wraps the AES key. Only this ciphertext payload ever travels or is stored.
//
// v2 (this build) binds {v, alg, name, nonce, ts} into the AES-GCM additionalData
// (AAD): tampering any of those metadata fields fails the GCM auth on the box
// (M1), and the fresh nonce + timestamp give the relay replay protection (H2).
//
// Usage:  node scripts/secret-encrypt.mjs <public.pem> [plaintext] [--name NAME]
//   plaintext read from stdin if omitted. Prints the JSON payload to stdout.

import { webcrypto as wc } from "node:crypto";
import { readFile } from "node:fs/promises";

const argv = process.argv.slice(2);
const flags = { "--name": "" };
const positionals = [];
for (let i = 0; i < argv.length; i++) {
  if (Object.prototype.hasOwnProperty.call(flags, argv[i])) { flags[argv[i]] = argv[++i]; }
  else { positionals.push(argv[i]); }
}
const pubPath = positionals[0];
if (!pubPath) { console.error("usage: secret-encrypt.mjs <public.pem> [plaintext] [--name NAME]"); process.exit(1); }

const plaintext = positionals[1] ?? await readStdin();
if (!plaintext) { console.error("no plaintext given (arg or stdin)"); process.exit(1); }
const name = flags["--name"] || "";

function derFromPem(pem) {
  const b64s = pem.replace(/-----BEGIN [^-]+-----/, "").replace(/-----END [^-]+-----/, "").replace(/\s+/g, "");
  return Buffer.from(b64s, "base64");
}
async function readStdin() {
  const chunks = []; for await (const c of process.stdin) chunks.push(c);
  return Buffer.concat(chunks).toString("utf8").replace(/\n$/, "");
}
const b64 = (buf) => Buffer.from(buf).toString("base64");
// Canonical AAD — MUST be byte-identical here, in mc-secrets-input.html, and in
// secret-decrypt.mjs. A positional JSON array fixes the field order across engines.
function aadBytes({ v, alg, name, nonce, ts }) {
  return new TextEncoder().encode(JSON.stringify([v, alg, name ?? "", nonce, ts]));
}

const pubKey = await wc.subtle.importKey(
  "spki", derFromPem(await readFile(pubPath, "utf8")),
  { name: "RSA-OAEP", hash: "SHA-256" }, false, ["encrypt"],
);

const v = 2;
const alg = "RSA-OAEP-SHA256+AES-256-GCM";
const nonce = b64(wc.getRandomValues(new Uint8Array(18)));   // H2 replay nonce
const ts = Date.now();                                       // H2 freshness (ms)
const aad = aadBytes({ v, alg, name, nonce, ts });           // M1 metadata binding

const aesKey = await wc.subtle.generateKey({ name: "AES-GCM", length: 256 }, true, ["encrypt", "decrypt"]);
const iv = wc.getRandomValues(new Uint8Array(12));
const ct = await wc.subtle.encrypt({ name: "AES-GCM", iv, additionalData: aad }, aesKey, new TextEncoder().encode(plaintext));
const rawAes = await wc.subtle.exportKey("raw", aesKey);
const wrappedKey = await wc.subtle.encrypt({ name: "RSA-OAEP" }, pubKey, rawAes);

console.log(JSON.stringify({
  v, alg, name,
  nonce, ts,
  wrappedKey: b64(wrappedKey),
  iv: b64(iv),
  ciphertext: b64(ct),
}));
