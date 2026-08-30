# Secret provisioning — E2E human → agent, no terminal, no plaintext on the wire

The keystone for a non-technical operator: how do they hand the agent a secret (a Supabase service key, a
Stripe key, a deploy token) **securely**, when they have no terminal and Telegram isn't end-to-end?

**Answer: Mission Control doubles as the secure channel.** The operator pastes the secret into an MC "Secrets"
input that **encrypts it client-side with the box's public key**. Only ciphertext travels or is stored. The
agent decrypts on the box, at the moment of use. MC is an *untrusted relay* — it never sees plaintext.

This *is* the spend/secret gate (the human supplying the secret = the human-in-the-loop), just on a
phone-friendly surface instead of a terminal.

## The flow

```
  box                         operator's browser (MC)                box (agent)
  ───                         ──────────────────────                ───────────
  keygen ──pubkey──────────▶  paste secret
  (priv stays on box)         encrypt client-side ──ciphertext──▶    decrypt with priv key
                              (plaintext never leaves)               write to .env / plugin config
                                                                     use it; plaintext only here, now
```

1. **Box holds a keypair.** `node scripts/secret-box-keygen.mjs` → RSA-OAEP / SHA-256, 3072-bit. The
   **private key never leaves the box** (`~/.kickoff/secret-box/private.pem`, 0600). The public key is shared
   to MC. keygen also prints the key's **SHA-256 fingerprint** (`SHA256:…` + colon-hex) and writes it to
   `public.fingerprint` — this is the out-of-band value the operator verifies in step 2.
2. **MC encrypts client-side — after the operator verifies the key.** The operator pastes the secret into the
   Secrets input (`mc-secrets-input.html`); the panel **computes the fingerprint of the public key it's about
   to encrypt to and refuses to encrypt until the operator confirms it matches the keygen value** (C1 — an
   SSH-host-key-style check that defeats a silent key substitution). The browser then uses **WebCrypto** to
   hybrid-encrypt (a random AES-256-GCM key encrypts the secret; the box's RSA-OAEP public key wraps the AES
   key), binding `{v, alg, name, nonce, ts}` into the GCM **additionalData** (a fresh nonce + timestamp give
   replay protection). Only the ciphertext payload
   `{ v, alg, name, nonce, ts, wrappedKey, iv, ciphertext }` leaves the browser — **never the plaintext, never
   in `mission-state.json`, logs, or Telegram.**
3. **Agent decrypts on the box.** `node scripts/secret-decrypt.mjs` rebuilds + verifies the AAD, unwraps the
   AES key with the private key, and recovers the secret → writes it to the project's `.env` / plugin config
   (`--write-env <file> --key NAME`, gated by the allow-list, see below) → uses it. The consumed inbox file is
   **deleted on success** (one-shot). **Plaintext exists only at the agent's moment of use.**

The agent **walks the operator through obtaining the key in plain words** ("Supabase → project settings → copy
the service key → paste it into the Secrets input"), then it's E2E from their browser to the agent.

## Why hybrid (not raw RSA)

RSA-OAEP can only encrypt ~190 bytes (3072-bit). Real secrets (a Supabase service-role JWT is ~220+ bytes)
exceed that. So a random AES-256-GCM key encrypts the secret (any size), and RSA wraps just the 32-byte AES
key. Standard construction; both sides use WebCrypto so the browser and `secret-decrypt.mjs` interoperate by
construction. AES-GCM also authenticates: a tampered ciphertext fails to decrypt (verified).

## Security properties

- **Private key is the trust anchor.** It never leaves the box; protect the box = protect the secrets (same as
  any vault). Re-keying invalidates every already-provisioned secret — keygen refuses to overwrite, so rotation
  is deliberate (runbook below).
- **Pubkey integrity is verified, not assumed (C1).** The panel shows the SHA-256 fingerprint of the key it will
  encrypt to and **blocks sending until the operator confirms it matches the box's out-of-band value** — so a
  substituted/MITM'd public key surfaces as a visible mismatch instead of silently re-routing every secret to an
  attacker's key. Integrators can pin the key/fingerprint at build time (`EMBEDDED_PUBKEY` / `EMBEDDED_FINGERPRINT`)
  instead of the mutable `GET /pubkey` fetch.
- **Replay-protected (H2).** Each payload carries a fresh nonce + timestamp; the relay rejects a replayed nonce and
  any timestamp outside a small freshness window. The nonce ledger survives delete-on-consume, so a captured POST
  can't be re-sent.
- **Metadata-authenticated (M1).** `{v, alg, name, nonce, ts}` are bound into the AES-GCM AAD on both ends — tampering
  any of them fails the GCM auth on the box (no plaintext out), not just the ciphertext+tag.
- **Ciphertext-only relay.** MC, its state file, and any logs only ever hold ciphertext. Telegram is never used
  for secrets (it isn't E2E).
- **Authenticated.** AES-GCM rejects tampering; a corrupted/altered payload fails closed (no plaintext out).
- **Lifecycle-bounded (M3).** The inbox deletes each ciphertext on successful consume, sweeps un-consumed files on a
  TTL, and caps the file count — retained ciphertext (the blast radius of a future key compromise) stays small.
- **Allow-listed writes (M2).** `--write-env` only writes a `--key` on a closed, adopter-configured allow-list, to a
  pinned `.env` path — a mis-driven invocation can't upsert an arbitrary var into an arbitrary file.
- **Plaintext is ephemeral.** It exists in the operator's browser pre-encryption and on the box at use — nowhere
  in between, and the reference UI clears the input field on encrypt.

## Wiring it into Mission Control

**The bundled `mission-control/` server + `secrets.html` panel are now v2-consistent** — `GET /secrets` serves the
v2 panel (C1 fingerprint-gate + H2 nonce/ts + M1 AAD), `GET /pubkey` serves the box key (loopback-only), and
`POST /secret` accepts the v2 ciphertext payload `{v, alg, name, nonce, ts, wrappedKey, iv, ciphertext}` into
`secrets-inbox/`, rejecting replays, stale posts, and v1 downgrades. A project spun up from kickoff gets this
secure channel by running the keygen once and consuming the inbox.

**Scope of "verified" (read this before funds-adjacent use):** what the automated suite covers is the crypto
round-trip, the relay's replay + AAD-tamper + loopback gates, and the panel's *fingerprint-verify-gates-encrypt*
logic (`secrets.html` produces a v2 payload the server accepts and round-trips to decrypt; a v1 payload is
refused). What is **not** yet done is the funds-adjacent sign-off itself — a human/pentest confirming C1 + H2 hold
in practice, and a real-engine (Safari/iOS) confirmation of the panel (it is exercised headless, not on-device).
Do not flow a funds-adjacent secret until that final gate clears (a pre-prod security review + checklist gates it).

Wiring it into a *pre-existing / external* MC (e.g. a live ops board you already run) is the human-gated step
(it modifies a live surface + needs the box keypair generated on that box):

1. On the box: `node scripts/secret-box-keygen.mjs` (once). Keep the public key **and its printed fingerprint** handy.
2. Add the Secrets panel to MC (adapt `mc-secrets-input.html`). Prefer pinning the key + fingerprint at build time
   (`EMBEDDED_PUBKEY` / `EMBEDDED_FINGERPRINT`) over the mutable `GET /pubkey` fetch.
3. Route the ciphertext payload to the box (a file drop / an authenticated endpoint — ciphertext only).
4. Configure the box's allow-list (`<keydir>/allowed-keys.json` or `KICKOFF_SECRET_ALLOWED_KEYS`, see below).
5. The agent runs `secret-decrypt.mjs` to land it in the right `.env` / plugin config.

### TLS precondition (H3)

`POST /secret` carries the token in the URL and confidentiality depends on the transport. The bundled server
serves plain HTTP and is meant to sit behind **`tailscale serve`**, which terminates TLS upstream and proxies to
`127.0.0.1`. To make that explicit, `GET /pubkey` and `POST /secret` **refuse non-loopback connections** — a
direct plaintext hit from off-box is rejected (403). The board routes (`/`, `/state`, `/events`, `/3d`,
`/secrets`) are unaffected. **Do not expose these two routes without TLS in front of them.**

### Allow-list + pinned path (M2)

`secret-decrypt.mjs --write-env` is **fail-closed**: it refuses to write unless a closed allow-list of permitted
`--key` names is configured. Configure it any of:

- `--allow KEY1,KEY2` on the command line, or
- `KICKOFF_SECRET_ALLOWED_KEYS=KEY1,KEY2` in the environment, or
- `<keydir>/allowed-keys.json` (next to `private.pem`): `{ "keys": ["SUPABASE_SERVICE_KEY"], "envPath": "/abs/.env" }`.

Pin the destination with `envPath` / `KICKOFF_SECRET_ENV_PATH` / `--env-path` — when set, `--write-env` must match
it exactly. Decrypt-to-stdout (no `--write-env`) needs no allow-list. The consumed inbox file is deleted on success
unless `--keep` is passed.

## Honest caveats

- This is a **standard hybrid construction**, but it's hand-assembled crypto. Before trusting it with real,
  funds-adjacent secrets in production, **get it reviewed** — or swap in a vetted library (`age` / libsodium
  sealed boxes do the same job with fewer pubkey-handling footguns; the only reason WebCrypto is used here is
  zero browser dependencies). See "libsodium follow-up" below.
- **Pubkey substitution is the sharpest risk (C1), and it's now *mitigated, not eliminated*.** If an attacker
  can tamper the PEM the browser encrypts to, the browser would encrypt every secret to the attacker's key —
  silently. The fingerprint-verify step defends this **only if the operator actually compares the displayed
  fingerprint against the box's out-of-band value** (and the out-of-band channel itself isn't MITM'd). Pinning
  `EMBEDDED_PUBKEY`/`EMBEDDED_FINGERPRINT` at build time over the TLS-served page is stronger than a runtime
  paste. Treat the fingerprint check as load-bearing, not cosmetic.
- It protects the secret **in transit and at rest in the relay** — not against a compromised box (the private
  key and the moment-of-use plaintext live there) or a compromised operator browser. Those are the trust anchors,
  same as any secrets system.
- **Confidentiality depends on TLS in front of the relay (H3).** The token rides in the URL; on plain HTTP it is
  sniffable. The secret routes refuse non-loopback plaintext, but that is a *backstop* — you must still run
  `tailscale serve` (or equivalent TLS) upstream. Without it, do not use these routes off-box.

### What IS and ISN'T covered (scope honestly — post-hardening)

- **Covered + self-tested here:** crypto round-trip (incl. non-ASCII secret) browser-mirror ↔ box; GCM
  tamper-reject; **AAD metadata binding (M1)**; **replay + stale-timestamp rejection on the relay (H2)**;
  **pubkey-fingerprint verify gate (C1)** with a verified browser/keygen fingerprint match; **inbox
  delete-on-consume + TTL + count cap (M3)**; **`--write-env` allow-list + pinned path (M2)**; **input size
  cap (L3)**; loopback-only secret routes (H3); the prior `--write-env` string-safety (newline reject, literal
  write, `--key` shape). These pass an automated suite (`node --check`, `py_compile`, a round-trip + 9 attack
  cases — all fail closed).
- **NOT covered / still on you:** a real browser/engine confirmation of the panel (it was rendered in headless
  Chromium, **not** Safari/iOS — confirm on your device); a third-party crypto audit; box/OS compromise; the
  integrity of the out-of-band channel you read the fingerprint over; operator-browser compromise; and any
  long-lived nonce-ledger durability across server restarts (the ledger is a file, but a wiped inbox dir resets
  it — replays are still bounded by the timestamp window).
- The browser's `name` field is just a **label** — `secret-decrypt.mjs` ignores it for the write and the box
  re-specifies `--key` (which must be on the allow-list). The operator-chosen name never reaches the `.env`
  write, so it can't inject an env var. It *is* bound into the AAD, so it can't be silently swapped in transit.

## Key rotation / re-provision runbook (L1)

keygen refuses to overwrite, and re-keying invalidates every already-provisioned ciphertext, so rotation is a
deliberate, ordered operation:

1. **Quiesce.** Stop new provisioning; consume or clear any pending `secrets-inbox/` files (they're encrypted to
   the *old* key and won't decrypt under the new one).
2. **Rotate the box key.** Move the old pair aside, then regenerate:
   `mv ~/.kickoff/secret-box ~/.kickoff/secret-box.old && node scripts/secret-box-keygen.mjs`.
   Note the **new fingerprint** it prints.
3. **Re-pin the panel.** Update the Secrets panel's public key (and `EMBEDDED_FINGERPRINT` if pinned) to the new
   key; restart/redeploy MC so `GET /pubkey` serves the new key.
4. **Re-provision.** The operator re-enters each secret through the panel, **verifying the new fingerprint**, and
   the agent re-consumes them under the new key.
5. **Destroy the old key.** Once every secret is re-provisioned and confirmed working, securely delete the old
   private key: `shred -u ~/.kickoff/secret-box.old/private.pem` (or `rm -P` / platform equivalent), then remove
   the dir. This is a one-way door — only do it after re-provisioning is verified.

> Rotate when: the box may be compromised, the key is past its planned lifetime, or an operator/contributor with
> box access departs. A libsodium/`age` swap (below) would remove the RSA-size dance and the manual fingerprint
> step in favour of a self-certifying key format — a reasonable thing to fold into a rotation.

## libsodium follow-up (recommended, not done in this pass)

This pass **hardened the existing RSA-OAEP-3072 + AES-256-GCM hybrid** rather than rewriting the primitive — the
crypto math was already correct, and the gaps were missing *controls*, not a broken cipher. A worthwhile
follow-up is to swap the primitive to **libsodium sealed boxes** (or `age`): a sealed box is a single vetted
construction (X25519 + XSalsa20-Poly1305) that removes the RSA key-size/`OAEP` handling, gives AAD/anonymous-sender
semantics for free, and ships self-certifying short keys (easier to pin/compare than a 3072-bit SPKI). **Tradeoff:**
it adds a dependency (libsodium-wrappers in the browser bundle — no longer zero-dependency WebCrypto) and is a
browser-crypto rewrite (re-test the whole round-trip + the panel on every target engine). Worth it before scaling
to many funds-adjacent secrets; not required to ship this hardened hybrid.
