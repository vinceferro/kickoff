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
// Usage:
//   node scripts/secret-box-keygen.mjs [keydir]        # create; refuses if a key exists
//   node scripts/secret-box-keygen.mjs --keydir <path>
//   node scripts/secret-box-keygen.mjs --ensure        # idempotent: exit 0 if already provisioned
//   node scripts/secret-box-keygen.mjs --quiet         # suppress the key/fingerprint banner
//   node scripts/secret-box-keygen.mjs --dry-run       # every guard + the same exit codes,
//                                                      # but CREATE NOTHING (how `kickoff adopt
//                                                      # --dry-run` previews this step honestly)
//
//   node scripts/secret-box-keygen.mjs --keydir <path> --keydir-source derived
//                                                      # a caller that DERIVED that path by the
//                                                      # shared rule; keeps the ambiguity guard
//                                                      # live. Passed by `kickoff adopt` — the
//                                                      # one automatic caller of this script that
//                                                      # constructs its --keydir itself.
//
//   KEYDIR RESOLUTION — defined ONCE in scripts/secret-keydir.mjs, imported here and by
//   secret-decrypt.mjs. Do not restate it in a comment and do not re-implement it: the previous
//   revision duplicated the resolver into both scripts "to avoid a manifest entry", the two
//   copies disagreed within one slice, and a keydir divergence fails GREEN.
//   The key is PER-PROJECT so two projects on one box never share a keypair, an allow-list,
//   or a pinned envPath.
//
// Exit codes: 0 ok · 1 refused (key exists, bare run) · 2 bad argument / bad config
//             3 inconsistent keydir · 4 ambiguous keydir (derived vs. machine-wide — see
//               assertNoLegacyAmbiguity(); nothing is created or moved)
//             5 the keydir is KICKOFF_PUBKEY-managed (READ-ONLY) and has no key to serve
//
// CONCURRENCY (core-v0.17). This runs automatically now, so two callers can race — two
// Mission Control boards starting together on one box is the ordinary case, not the exotic
// one. The mutex is the EXCLUSIVE CREATION of private.pem (`wx` / O_EXCL): exactly one
// process can win it, and ONLY the winner writes public.pem + public.fingerprint. That is
// what makes a torn keydir — private key from A, public key from B — unrepresentable.
// Getting this wrong fails GREEN: the fingerprint check still passes while every secret is
// encrypted to a key nobody holds.

import { webcrypto as wc } from "node:crypto";
import { open, mkdir, writeFile, rename, chmod } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join } from "node:path";
import {
  resolveKeydir, assertResolvable, assertNoLegacyAmbiguity,
  inspectSettled, fingerprint,
  privPathIn, pubPathIn, fpPathIn,
} from "./secret-keydir.mjs";

// ── args ─────────────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
let keydirArg = null;
let keydirSource = null;
let ensure = false;
let quiet = false;
let dryRun = false;
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--ensure") ensure = true;
  else if (a === "--quiet") quiet = true;
  else if (a === "--dry-run") dryRun = true;
  else if (a === "--keydir") keydirArg = argv[++i];
  else if (a === "--keydir-source") keydirSource = argv[++i];
  else if (!a.startsWith("-") && keydirArg === null) keydirArg = a;   // positional, back-compat
  else {
    console.error(`unknown argument: ${a}`);
    process.exit(2);
  }
}
// `derived` is the ONLY accepted value, deliberately. The flag exists to DEMOTE an explicit
// --keydir back to "the machinery computed this", which re-arms the ambiguity guard. The
// opposite direction — promoting a derived resolution to "explicit" from the command line —
// is exactly the laundering the guard exists to stop, so it is unrepresentable here (a human
// who really has decided passes --keydir, which is already explicit).
if (keydirSource !== null && keydirSource !== "derived") {
  console.error(`--keydir-source only takes 'derived' — got ${JSON.stringify(keydirSource)}`);
  process.exit(2);
}
if (keydirSource !== null && keydirArg === null) {
  console.error(`--keydir-source declares how --keydir was chosen; it is meaningless without --keydir`);
  process.exit(2);
}
const resolved = assertResolvable(resolveKeydir(keydirArg));
// A caller that COMPUTED this path by the shared derivation rule (kickoff adopt, the board) is
// not the operator naming a directory — it is the machinery guessing, which is precisely what
// the ambiguity guard exists for. Passing `--keydir <derived path>` alone would launder a guess
// into an explicit choice and skip the refusal by construction. Declaring the source restores it.
if (keydirSource) resolved.source = keydirSource;
assertNoLegacyAmbiguity(resolved);
const keydir = resolved.keydir;

const privPath = privPathIn(keydir);
const pubPath = pubPathIn(keydir);
const fpPath = fpPathIn(keydir);

const pem = (b64, label) =>
  `-----BEGIN ${label}-----\n${b64.match(/.{1,64}/g).join("\n")}\n-----END ${label}-----\n`;
const toB64 = (buf) => Buffer.from(buf).toString("base64");
const say = (...a) => { if (!quiet) console.log(...a); };

// The two refusals that fire from more than one place — one wording, one exit code each,
// so a bare run, an --ensure run and a --dry-run preview cannot drift apart.
const refuseExisting = () => {
  console.error(`✋ ${privPath} already exists — refusing to overwrite the box key.`);
  console.error(`   (Re-keying invalidates every secret already provisioned. Delete it deliberately to rotate.)`);
  process.exit(1);
};
const refuseInconsistent = (state) => {
  console.error(`✗ ${keydir} is INCONSISTENT (${state}) — refusing to touch it.`);
  console.error(`   private.pem exists but the public key / fingerprint beside it ${
    state === "torn" ? "is missing or unreadable" : "does not match it"}.`);
  console.error(`   Nothing can encrypt to this keydir safely. Inspect it, and if you are certain`);
  console.error(`   no live secret depends on it, remove ${keydir} and re-run to re-provision.`);
  process.exit(3);
};

// The keydir can land inside a TRACKED directory: in the origin repo server.py's STATE_PATH
// falls back to BASE_DIR (server.py:95-99), so the INSTANCE_DIR it hands us is mission-control/
// and the keydir is mission-control/secret-box. A private key that is merely
// "not added yet" is one `git add -A` from being published, and depending on a .gitignore
// template to travel to every topology is exactly the kind of seam that rots. So the keydir
// ignores ITSELF, written at creation and repaired by --ensure — additive, unlike touching keys.
async function ensureSelfIgnore() {
  const gi = join(keydir, ".gitignore");
  if (!existsSync(gi)) await writeFile(gi, "*\n", { mode: 0o644 });
}

// ── --ensure: idempotent, and the ONLY safe mode for an automatic caller ─────
if (ensure) {
  // inspectSettled, not inspect: a legitimate concurrent creator is OBSERVABLE as `torn` for the
  // few hundred ms between winning the private.pem mutex and renaming the public half into
  // place. A single inspect here reported that healthy keydir as corruption (exit 3) and told
  // the operator to delete a live private key. Re-inspect after a bounded wait first.
  const st = await inspectSettled(keydir);
  if (st.state === "ok") {
    if (!dryRun) await ensureSelfIgnore();   // --dry-run: report, write nothing — not even the .gitignore
    say(`✓ box keypair already provisioned at ${keydir}`);
    say(`   fingerprint: SHA256:${st.fp.b64}`);
    process.exit(0);
  }
  if (st.state === "torn" || st.state === "mismatch") {
    // Never auto-repair: repairing means deleting a private key, and a deleted private key
    // is every already-provisioned secret gone. This is a human's call, deliberately.
    refuseInconsistent(st.state);
  }
  // absent → fall through and create
}

// ── the keydir is READ-ONLY when KICKOFF_PUBKEY points into it ───────────────
// KICKOFF_PUBKEY names an EXISTING public key to serve. It used to be a bare "where is the
// public key" lookup, and making the server derive a keydir from it silently turned it into a
// WRITE TRIGGER: setting it caused a stray keypair to be generated into its dirname. A config
// var that only ever read must not start creating private keys. Refuse, and name the var that
// does mean "create it here".
if (resolved.readOnly) {
  // INSPECT FIRST, refuse only if provisioning would actually be required. Exit 5 means "this
  // keydir is not a provisioning target AND it has no usable keypair" — refusing before looking
  // told a bare run on a HEALTHY, fully-provisioned KICKOFF_PUBKEY keydir that it "would have
  // had to be provisioned", which was simply false (nothing needed provisioning; the honest
  // refusal there is the ordinary key-exists one, exit 1). In --ensure mode the inspection
  // already happened above — `ok` exited 0 and torn/mismatch exited 3 — so reaching here MEANS
  // absent; only a bare run still has to look.
  const st = ensure ? { state: "absent" } : await inspectSettled(keydir);
  if (st.state === "ok") refuseExisting();
  if (st.state === "torn" || st.state === "mismatch") refuseInconsistent(st.state);
  console.error(`✗ ${keydir} is KICKOFF_PUBKEY-managed (read-only) and holds no usable keypair.`);
  console.error(`   KICKOFF_PUBKEY points at a key that already exists, to be SERVED — it is not a`);
  console.error(`   place to generate one. Nothing was created.`);
  console.error(`   To have kickoff provision a keypair here instead:`);
  console.error(`     KICKOFF_SECRET_KEYDIR=${keydir}  (and unset KICKOFF_PUBKEY)`);
  process.exit(5);
}

// ── --dry-run: the last stop before anything is written ──────────────────────
// Every guard above ran for real (bad flag 2 · ambiguity 4 · read-only 5 · inconsistent 3), so
// the preview and the real run share one code path and cannot disagree. All that is left is the
// creation itself — report it and stop. `kickoff adopt --dry-run` depends on this to preview the
// keypair step with the ACTUAL exit code the real adopt would get, instead of restating any of
// the predicates in bash.
if (dryRun) {
  if (!ensure) {
    // --ensure mode reaches here only when the keydir is absent (ok exited 0, torn/mismatch 3
    // above). A bare dry-run has not inspected yet, and must predict the exit-1 refusal a real
    // bare run would hit at the O_EXCL mutex — private.pem present in ANY state means EEXIST —
    // by looking instead of taking a lock a dry run must not take.
    const st = await inspectSettled(keydir);
    if (st.state !== "absent") refuseExisting();
  }
  say(`· dry-run: would provision a box keypair at ${keydir} — nothing was created`);
  process.exit(0);
}

// ── create ───────────────────────────────────────────────────────────────────
const pair = await wc.subtle.generateKey(
  { name: "RSA-OAEP", modulusLength: 3072, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
  true,
  ["encrypt", "decrypt"],
);
const spki = await wc.subtle.exportKey("spki", pair.publicKey);
const pkcs8 = await wc.subtle.exportKey("pkcs8", pair.privateKey);
const fp = await fingerprint(spki);

await mkdir(keydir, { recursive: true, mode: 0o700 });
await ensureSelfIgnore();

// THE MUTEX. O_EXCL create of private.pem: exactly one racer wins, and only the winner goes
// on to write the public half — so the pair can never be torn across two processes.
let fh;
try {
  fh = await open(privPath, "wx", 0o600);
} catch (e) {
  if (e && e.code === "EEXIST") {
    if (!ensure) refuseExisting();
    // --ensure and we lost the race: the winner may still be writing the public half.
    // Wait, bounded — then re-inspect rather than assume. Same settle used by the --ensure
    // fast path above, one implementation, so the two windows cannot drift apart.
    const st = await inspectSettled(keydir, { settleMs: 5000 });
    if (st.state === "ok") {
      say(`✓ box keypair provisioned concurrently at ${keydir}`);
      process.exit(0);
    }
    console.error(`✗ another process claimed ${privPath} but never completed the keydir.`);
    console.error(`   Inspect ${keydir} — it is in the inconsistent state described above.`);
    process.exit(3);
  }
  throw e;
}

try {
  await fh.write(pem(toB64(pkcs8), "PRIVATE KEY"));
} finally {
  await fh.close();
}
await chmod(privPath, 0o600);

// Public half: temp + rename, so a reader never observes a half-written public key or a
// fingerprint that does not yet correspond to it.
const tmp = (p) => `${p}.tmp.${process.pid}`;
await writeFile(tmp(pubPath), pem(toB64(spki), "PUBLIC KEY"), { mode: 0o644 });
await rename(tmp(pubPath), pubPath);
await writeFile(tmp(fpPath), `SHA256:${fp.b64}\n${fp.hex}\n`, { mode: 0o644 });
await rename(tmp(fpPath), fpPath);

say(`✅ box keypair written to ${keydir}`);
say(`   private: ${privPath}  (0600 — never leaves this box)`);
say(`   public:  ${pubPath}   (served to the MC Secrets panel)`);
say(`\n=== PUBLIC KEY FINGERPRINT (SHA-256 of SPKI DER) — VERIFY THIS IN THE PANEL ===`);
say(`   SHA256:${fp.b64}`);
say(`   hex: ${fp.hex}`);
say(`   ↳ The operator must confirm the panel shows THIS value before sending any secret,`);
say(`     having received it OUT-OF-BAND (Telegram) — not read off the same page.`);
if (!quiet) {
  console.log(`\n--- PUBLIC KEY (paste into the MC Secrets input config) ---`);
  console.log(pem(toB64(spki), "PUBLIC KEY").trim());
}
