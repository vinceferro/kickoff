#!/usr/bin/env node
// secret-box-keygen.mjs — generate the box keypair for E2E secret provisioning.
//
// The trust anchor for the whole secret-provisioning flow (see
// docs/secret-provisioning/README.md). The PRIVATE key never leaves the box;
// the PUBLIC key is shared to the MC "Secrets" input, which encrypts secrets
// client-side so only ciphertext ever travels or is stored.
//
// Uses WebCrypto (node:crypto.webcrypto) so the algorithm is identical to the
// browser's by construction — RSA-OAEP / SHA-256, 3072-bit.
//
// Usage:  node scripts/secret-box-keygen.mjs [keydir]
//   keydir defaults to ~/.kickoff/secret-box  (private key written 0600)

import { webcrypto as wc } from "node:crypto";
import { mkdir, writeFile, chmod, access } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

const keydir = process.argv[2] || join(homedir(), ".kickoff", "secret-box");
const privPath = join(keydir, "private.pem");
const pubPath = join(keydir, "public.pem");

function pem(b64, label) {
  const lines = b64.match(/.{1,64}/g).join("\n");
  return `-----BEGIN ${label}-----\n${lines}\n-----END ${label}-----\n`;
}
const toB64 = (buf) => Buffer.from(buf).toString("base64");

const exists = async (p) => access(p).then(() => true).catch(() => false);

if (await exists(privPath)) {
  console.error(`✋ ${privPath} already exists — refusing to overwrite the box key.`);
  console.error(`   (Re-keying invalidates every secret already provisioned. Delete it deliberately to rotate.)`);
  process.exit(1);
}

const pair = await wc.subtle.generateKey(
  { name: "RSA-OAEP", modulusLength: 3072, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
  true,
  ["encrypt", "decrypt"],
);

const spki = await wc.subtle.exportKey("spki", pair.publicKey);
const pkcs8 = await wc.subtle.exportKey("pkcs8", pair.privateKey);

// C1 — pubkey integrity binding. The SHA-256 of the SPKI DER is the public key's
// fingerprint: the MC Secrets panel computes the SAME hash over the key it's about
// to encrypt to and gates sending on the operator confirming it matches THIS value
// (read out-of-band, SSH-host-key style). A substituted pubkey changes the
// fingerprint, so a silent MITM key-swap becomes a visible mismatch.
const fpDigest = new Uint8Array(await wc.subtle.digest("SHA-256", spki));
const fpHex = [...fpDigest].map((b) => b.toString(16).padStart(2, "0")).join(":");
const fpB64 = toB64(fpDigest).replace(/=+$/, "");

await mkdir(keydir, { recursive: true });
await writeFile(privPath, pem(toB64(pkcs8), "PRIVATE KEY"), { mode: 0o600 });
await chmod(privPath, 0o600);
await writeFile(pubPath, pem(toB64(spki), "PUBLIC KEY"), { mode: 0o644 });
// Persist the fingerprint next to the key so an integrator can embed it statically.
await writeFile(join(keydir, "public.fingerprint"), `SHA256:${fpB64}\n${fpHex}\n`, { mode: 0o644 });

console.log(`✅ box keypair written to ${keydir}`);
console.log(`   private: ${privPath}  (0600 — never leaves this box)`);
console.log(`   public:  ${pubPath}   (share this to the MC Secrets input)`);
console.log(`\n=== PUBLIC KEY FINGERPRINT (SHA-256 of SPKI DER) — VERIFY THIS IN THE PANEL ===`);
console.log(`   SHA256:${fpB64}`);
console.log(`   hex: ${fpHex}`);
console.log(`   ↳ In the MC Secrets panel, confirm the displayed fingerprint matches this`);
console.log(`     EXACTLY before sending any secret. A mismatch means the key was swapped.`);
console.log(`\n--- PUBLIC KEY (paste into the MC Secrets input config) ---`);
console.log(pem(toB64(spki), "PUBLIC KEY").trim());
