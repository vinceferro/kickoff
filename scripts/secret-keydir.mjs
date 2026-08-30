#!/usr/bin/env node
// secret-keydir.mjs — THE keydir rule for the secret-provisioning channel. One definition.
//
// WHY THIS FILE EXISTS. The rule "every consumer resolves the SAME keydir" was written as
// PROSE ("IDENTICAL TWIN … MUST stay byte-identical") and implemented three times — once in
// secret-box-keygen.mjs, once in secret-decrypt.mjs, once in mission-control/server.py. The
// three copies disagreed within one slice: the twins gated the legacy-conflict refusal on
// private.pem while the server gated it on isdir(), so an EMPTY keydir was a conflict to one
// half and not-a-conflict to the other. A comment cannot hold an invariant that a compiler
// does not check. The two .mjs consumers now IMPORT this file; server.py must re-implement it
// in Python (it has to resolve the keydir on a box with no node — node is advisory in kickoff,
// scripts/kickoff warns rather than fails), so the Python copy is held to this file by the
// conformance suite, using the machine-readable `--json` dump at the bottom.
//
// The divergence class this guards is the one that fails GREEN: the panel encrypts to the key
// under keydir A while the coordinator decrypts with keydir B, and every fingerprint,
// permission and HTTP check in between still passes.
//
// CLI (the oracle the conformance suite diffs the Python copy against):
//   node scripts/secret-keydir.mjs --json [--keydir <path>]
//
// Exit codes shared by every consumer of this module:
//   0 ok · 1 refused (key exists, bare run) · 2 bad argument / bad config
//   3 inconsistent keydir (torn or fingerprint mismatch) · 4 ambiguous keydir (derived vs.
//   machine-wide) · 5 the keydir came from a READ-ONLY source (KICKOFF_PUBKEY) and would have
//   had to be provisioned.

import { webcrypto as wc } from "node:crypto";
import { readFile, access } from "node:fs/promises";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname, resolve, basename } from "node:path";

export const LEGACY_KEYDIR = join(homedir(), ".kickoff", "secret-box");

// The three files that make up a keydir. A keydir is the unit; the trio always travels together,
// which is why KICKOFF_PUBKEY cannot name a file called anything else (see resolveKeydir).
export const PRIV_NAME = "private.pem";
export const PUB_NAME = "public.pem";
export const FP_NAME = "public.fingerprint";

export const privPathIn = (keydir) => join(keydir, PRIV_NAME);
export const pubPathIn = (keydir) => join(keydir, PUB_NAME);
export const fpPathIn = (keydir) => join(keydir, FP_NAME);

// ── RESOLUTION — first hit wins ──────────────────────────────────────────────
//   1. explicit --keydir / positional            source "explicit"   (CLI only)
//   2. $KICKOFF_PUBKEY → its dirname             source "pubkey"     READ-ONLY
//   3. $KICKOFF_SECRET_KEYDIR                    source "env"
//   4. dirname($KICKOFF_STATE ?? $MC_STATE_FILE)/secret-box   source "derived"  ← per-project
//   5. ~/.kickoff/secret-box                     source "legacy"
//
// (4) is the ordinary adopter case. That dirname is exactly the INSTANCE_DIR anchor
// mission-control/server.py already uses for the two sibling instance-private artifacts
// (.mission-token, secrets-inbox/), so the keypair is per-project by the same rule, and on an
// adopter it lands under .kickoff/state/ which the generated .kickoff/.gitignore already covers.
// (5) applies only when no instance state path resolves at all (the origin / hand-run case).
//
// KICKOFF_PUBKEY — the decision, because the three consumers disagreed about it:
//   · It is honoured EVERYWHERE (it used to be server-only, which split the flow: the board
//     served key A while the coordinator decrypted with key B — the exact fail-green shape).
//   · Its basename MUST be `public.pem`. It names a member of the trio, and a file named
//     anything else cannot say which private.pem it pairs with. Rejecting it makes the
//     unpairable state unrepresentable instead of tolerated.
//   · It is READ-ONLY: it points at a key that already exists, to be SERVED. It is never a
//     provisioning target. Previously a bare "where is the public key" config var became a
//     WRITE trigger — setting it made the server generate a stray keypair into its dirname.
//     Use KICKOFF_SECRET_KEYDIR when you want kickoff to create the key.
// Read an env var the way mission-control/server.py does: TRIMMED, and empty-after-trim counts as
// UNSET. Raw JS truthiness disagrees — `"   "` is truthy in Node and falsy after Python's .strip() —
// so `KICKOFF_PUBKEY="   "` made the Python side fall through to the derived keydir while the Node
// side resolved a keydir literally named from whitespace. Two consumers, two different keys: the
// board serves one, the coordinator decrypts with the other, and the fingerprint check still passes.
// The conformance suite caught this (3 of 106 cells red) — in the very round whose whole purpose was
// to eliminate divergence. Trimming is also the safer reading on its own merits: a whitespace-only
// path is never what an operator meant, and `resolve("   ")` silently yields a real directory name.
const envStr = (v) => (typeof v === "string" ? v.trim() : "");

export function resolveKeydir(explicit, env = process.env) {
  const PUBKEY_ENV = envStr(env.KICKOFF_PUBKEY);
  const KEYDIR_ENV = envStr(env.KICKOFF_SECRET_KEYDIR);
  const STATE_ENV = envStr(env.KICKOFF_STATE) || envStr(env.MC_STATE_FILE);
  if (explicit) {
    const keydir = resolve(explicit);
    // READ-ONLY is a property of the KEYDIR, not of how this particular caller spelled it.
    // mission-control/server.py resolves the keydir itself and then shells out with an explicit
    // `--keydir`, so a rule keyed on `source === "pubkey"` would be bypassed by construction on
    // the one path that matters. Ask the question the rule is actually about: is this the
    // directory KICKOFF_PUBKEY points into?
    const managed = PUBKEY_ENV && dirname(resolve(PUBKEY_ENV)) === keydir;
    return { keydir, source: "explicit", readOnly: !!managed };
  }
  if (PUBKEY_ENV) {
    const p = resolve(PUBKEY_ENV);
    if (basename(p) !== PUB_NAME) {
      return { keydir: dirname(p), source: "pubkey", readOnly: true, badBasename: p };
    }
    return { keydir: dirname(p), source: "pubkey", readOnly: true };
  }
  if (KEYDIR_ENV) {
    return { keydir: resolve(KEYDIR_ENV), source: "env", readOnly: false };
  }
  const statePath = STATE_ENV;
  if (statePath) {
    return { keydir: join(dirname(resolve(statePath)), "secret-box"), source: "derived", readOnly: false };
  }
  return { keydir: LEGACY_KEYDIR, source: "legacy", readOnly: false };
}

// A bad KICKOFF_PUBKEY is a config error, not something to work around silently: exit 2 with
// the one line that fixes it. Every consumer calls this immediately after resolveKeydir.
export function assertResolvable(r) {
  if (!r.badBasename) return r;
  console.error(`✗ KICKOFF_PUBKEY must name a file called ${PUB_NAME} — got ${r.badBasename}`);
  console.error(`   The keydir is the unit: ${PRIV_NAME} · ${PUB_NAME} · ${FP_NAME} live together,`);
  console.error(`   and a public key under another name cannot say which private key it pairs with.`);
  console.error(`   Fix one of:`);
  console.error(`     · KICKOFF_PUBKEY=${join(dirname(r.badBasename), PUB_NAME)}`);
  console.error(`     · KICKOFF_SECRET_KEYDIR=${dirname(r.badBasename)}   (and kickoff may provision it)`);
  process.exit(2);
}

// ── THE LEGACY-AMBIGUITY PREDICATE ───────────────────────────────────────────
// NO SILENT FALLBACK from the derived keydir to the machine-wide one. If this instance derived
// its own keydir, has no key there, and the old machine-wide keydir DOES hold one, there are two
// plausible intentions — "provision a fresh per-project key" and "you meant the machine key" —
// and guessing wrong is invisible either way: it strands secrets already provisioned to the old
// key, or silently shares one key (and one allow-list, and one pinned .env) across every project
// on the box. Refuse and make the operator choose. Never move a private key on their behalf.
//
// THE PREDICATE IS private.pem-BASED, on BOTH sides, and this is the divergence that shipped:
// server.py asked `not isdir(keydir)` and `exists(LEGACY/public.pem)`, the twins asked about
// private.pem. So a keydir that EXISTS BUT IS EMPTY — the ordinary shape after a keygen that
// only got as far as mkdir, and after `mkdir -p` by any sibling tooling — was a conflict to one
// consumer and not to the other. private.pem is the right question in both places because the
// private half is what makes a keydir USABLE and what cannot be regenerated; a public half
// without it is undecryptable, and a directory without either is simply empty.
export function legacyConflict({ keydir, source }) {
  if (source !== "derived") return false;              // explicit/env/pubkey = the operator said so
  if (resolve(keydir) === resolve(LEGACY_KEYDIR)) return false;
  if (existsSync(privPathIn(keydir))) return false;    // this project already has its own key
  return existsSync(privPathIn(LEGACY_KEYDIR));        // …and the machine-wide one holds one
}

export function assertNoLegacyAmbiguity(r) {
  if (!legacyConflict(r)) return;
  console.error("✗ ambiguous secret keydir — refusing to guess (nothing was created or moved).");
  console.error(`   this project's keydir : ${r.keydir}  (no ${PRIV_NAME})`);
  console.error(`   machine-wide keydir   : ${LEGACY_KEYDIR}  (holds a ${PRIV_NAME})`);
  console.error("   Decide explicitly, then re-run:");
  console.error(`     · a key of its own for this project  →  --keydir ${r.keydir}`);
  console.error(`     · reuse the machine-wide key         →  KICKOFF_SECRET_KEYDIR=${LEGACY_KEYDIR}`);
  console.error("       (shared by every project on this box — its allow-list and pinned .env too)");
  process.exit(4);
}

// ── THE STATE PREDICATE ──────────────────────────────────────────────────────
// Exactly four states, and "provisioned" means `ok` — nothing weaker. The weaker test is the one
// that shipped on the Python side: it declared the keydir healthy on exists(public.pem) ALONE,
// so a public-only keydir reported ok while every secret encrypted to it was undecryptable —
// fail-green, in the function written to prevent fail-green. Checking presence alone would also
// call a torn or tampered keydir "fine".
//
//   absent   — no private.pem. Nothing here; safe to create.
//   torn     — private.pem exists but the public half or the fingerprint is missing/unreadable.
//   mismatch — all three exist, but public.fingerprint ≠ SHA-256(SPKI DER of public.pem).
//   ok       — all three exist and the fingerprint matches. THE ONLY provisioned state.
//
// Deliberately implementable with a stdlib-only Python twin: base64-decode the PEM body,
// hashlib.sha256, compare. No crypto library needed on the server side.
const exists = (p) => access(p).then(() => true).catch(() => false);
export const derOf = (pemText) =>
  Buffer.from(pemText.replace(/-----(BEGIN|END)[^-]*-----/g, "").replace(/\s+/g, ""), "base64");

export async function fingerprint(spkiDer) {
  const d = new Uint8Array(await wc.subtle.digest("SHA-256", spkiDer));
  return {
    b64: Buffer.from(d).toString("base64").replace(/=+$/, ""),
    hex: [...d].map((b) => b.toString(16).padStart(2, "0")).join(":"),
  };
}

export async function inspectKeydir(keydir) {
  if (!(await exists(privPathIn(keydir)))) return { state: "absent" };
  if (!(await exists(pubPathIn(keydir))) || !(await exists(fpPathIn(keydir)))) return { state: "torn" };
  try {
    const fp = await fingerprint(derOf(await readFile(pubPathIn(keydir), "utf8")));
    const recorded = (await readFile(fpPathIn(keydir), "utf8")).split("\n")[0].trim();
    // KNOWN GAP (2026-07-22, characterised not fixed): "ok" proves public.pem agrees with
    // public.fingerprint. It does NOT prove private.pem is the matching half — a keydir holding
    // key A's private and key B's public+fingerprint is self-consistent and reports "ok" while
    // every secret provisioned through the board is undecryptable.
    // A pairing check via createPublicKey(private).export(spki) WORKS here and was verified to
    // catch it. It was reverted deliberately: mission-control/server.py is stdlib-only and cannot
    // derive a public key from a private one, so adding it to Node ALONE reproduces the exact
    // cross-consumer divergence this module exists to eliminate (measured: Node "mismatch" vs
    // Python "ok" on the same keydir). Fixing it properly means either an ASN.1 modulus compare
    // in Python or a distinct "pairing-unverified" state asserted by the conformance matrix —
    // its own slice, with its own unpaired-keydir conformance cell (which does not exist yet,
    // which is why the suite reported 105/0 while this hole was open).
    return recorded === `SHA256:${fp.b64}` ? { state: "ok", fp } : { state: "mismatch", fp, recorded };
  } catch {
    return { state: "torn" };
  }
}

// TORN IS ALSO THE MID-CREATION WINDOW. A legitimate creator holds the O_EXCL mutex on
// private.pem and only then writes the public half — so a concurrent observer that inspects
// once sees exactly the `torn` shape and, before this, exited 3 "INCONSISTENT — refusing to
// touch it" on a keydir that was perfectly healthy 200ms later. Corruption reported for
// correctness. So: on `torn`, wait and RE-INSPECT, bounded, before believing it. Only a keydir
// that is still torn after the settle window is called torn — and a genuinely torn keydir is
// still NEVER auto-repaired, because repairing means deleting a private key, i.e. deleting
// every secret already provisioned to it.
export const SETTLE_MS = 3000;
export const SETTLE_POLL_MS = 100;

export async function inspectSettled(keydir, { settleMs = SETTLE_MS, pollMs = SETTLE_POLL_MS } = {}) {
  let st = await inspectKeydir(keydir);
  if (st.state !== "torn") return st;                 // absent/ok/mismatch are never transient
  const deadline = Date.now() + settleMs;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, pollMs));
    st = await inspectKeydir(keydir);
    if (st.state !== "torn") return st;
  }
  return st;
}

// ── the oracle: `--json`, one line, what every consumer must agree on ────────
if (import.meta.url === `file://${process.argv[1]}`) {
  const argv = process.argv.slice(2);
  let explicit = null;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--keydir") explicit = argv[++i];
    else if (argv[i] !== "--json") { console.error(`unknown argument: ${argv[i]}`); process.exit(2); }
  }
  const r = resolveKeydir(explicit);
  const st = r.badBasename ? { state: "unresolvable" } : await inspectKeydir(r.keydir);
  console.log(JSON.stringify({
    keydir: r.keydir,
    source: r.source,
    readOnly: !!r.readOnly,
    badBasename: r.badBasename || null,
    privPath: privPathIn(r.keydir),
    pubPath: pubPathIn(r.keydir),
    fpPath: fpPathIn(r.keydir),
    legacyKeydir: LEGACY_KEYDIR,
    legacyConflict: r.badBasename ? false : legacyConflict(r),
    state: st.state,
    fingerprint: st.fp ? `SHA256:${st.fp.b64}` : null,
  }));
}
