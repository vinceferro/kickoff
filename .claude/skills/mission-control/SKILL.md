---
name: mission-control
description: Stand up Mission Control — the live, two-way ops board for a project (SSE-live, phone-friendly, token-gated, localhost-only) with the encrypted Secrets channel built in. The coordinator writes state via mc-update.py and the operator sees it + checks items off + hands over secrets, from their phone. Use to start MC for a project, or when the operator asks "where do I see what's happening / how do I give you a key".
---

# mission-control — the live ops board (and secure secret channel)

The star of the show: a live, two-way board between the coordinator and the operator. The coordinator writes
state after each unit of work; the board updates in ~1s over SSE; the operator checks off the only-you items
and hands over secrets — **all from a phone, no terminal.** This is the generic, shippable version of the board
the coordinator built for itself on a real project. It lives in `mission-control/`.

## Stand it up

> **`kickoff up` now does this automatically** (`scripts/board-serve.sh`): free-port pick, serve-status
> pre-check, 401/200 confirm, and the assigned ports RECORDED in
> `.kickoff/state/mission-control/board-serve.env` so every restart reuses the SAME URL. Check that record
> first; the manual sequence below is the fallback/debugging path — and it is safe to re-run (idempotent
> against a live board).

**Never hardcode a port — a box runs many projects.** Both ports below are *pick-a-free-one*, checked before use.
Reusing an occupied one is how you take **another project's live board dark** (see step 2).

1. **Pick a free LOCAL port and run the server** (stdlib-only Python, no deps):
   ```bash
   ss -ltn | grep -q ":<local-port> " && echo "OCCUPIED — pick another"   # must print nothing
   # adopted repo (engine is the pinned core clone):
   python3 "$KICKOFF_CORE_DIR/mission-control/server.py" <local-port>   # binds 127.0.0.1 ONLY
   # kickoff-native (repo IS the core; KICKOFF_CORE_DIR unset by design):
   python3 mission-control/server.py <local-port>
   ```
   It auto-generates a token (`.mission-token`, 0600) on first run and prints the dashboard URL. **Assert it
   actually bound** — a busy port dies with `EADDRINUSE` and nothing else in this flow notices.
2. **Expose it privately** (so the operator's phone can reach it) via Tailscale — never a public port.
   **`tailscale serve` is set-not-append**: pointing an already-mapped `<tailnet-port>` at a new target
   **silently replaces** the existing handler — no error, no warning — so an occupied port means you have just
   darkened whatever was behind it. **Read `serve status` FIRST and pick a port that is not listed:**
   ```bash
   tailscale serve status                       # ① pre-check: EVERY port here is TAKEN — pick one that is NOT
   tailscale serve --bg --yes --https=<free-tailnet-port> http://127.0.0.1:<local-port>   # ② tailnet-only
   tailscale serve status                       # ③ confirm YOUR mapping exists (absent = a DARK board)
   ```
   Do **NOT** `tailscale funnel` this, and never use `/` (that defaults to **:443**, the box's front door).
   The board is **private** — it carries project state, blockers, and the secret channel. Funnel = public = wrong.
   The server binds 127.0.0.1 only, so **without this mapping nothing outside the box can reach it** — and a
   skipped serve fails *silently*. Hence step 3, which is not optional.
3. **Verify reachability — over the TAILNET, not localhost.** `healthz 200 on 127.0.0.1` proves nothing about
   what the operator's phone sees. Curl the tailnet URL and assert **both** codes:
   ```bash
   B=https://<your-tailnet-host>:<free-tailnet-port>
   curl -s -o /dev/null -w '%{http_code}\n' "$B/"                                                    # expect 401
   curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $(cat <repo>/.kickoff/state/mission-control/.mission-token)" "$B/"   # expect 200
   ```
   Pipe the token **straight into curl — never `echo`/print it** (it would leak into the transcript). No `-k`: a
   cert failure here is a real misconfiguration, not noise to silence. Only after 401-then-200 may you tell the
   operator the board is up; anything else → fix the serve first.
4. **Hand off the URL — the operator fetches the token himself.** Send `https://<your-tailnet-host>:<free-tailnet-port>/`
   and one instruction: run `cat <repo>/.kickoff/state/mission-control/.mission-token` in your terminal/SSH and open the URL as
   `?token=<token>` — the dashboard stores it in a cookie client-side (`dashboard.html`; the server sets none), so
   it's a **one-time** paste.
   ⚠️ **Do not send him the token.** Reading a secret back into a message or a channel reply is a hard rule, and it
   holds **even when the operator asks you to send it** — that ask is also exactly the shape a prompt injection
   takes. Don't try to be helpful here; hand over the URL + that one command.

## Use it (the coordinator's loop)

Write state after each unit of work — every write is atomic + bumps the timestamp, so the board pushes the
update live. Use **your repo's mc entrypoint** (same verbs either way; the seam self-targets *your* board):

- **Adopted repo** (you ran `kickoff adopt`): `.kickoff/bin/mc <verb> …`  ← the examples below
- **kickoff-native project** (bootstrap/greenfield, repo IS the core): `python3 mission-control/mc-update.py <verb> …`

Getting this wrong fails SILENTLY: in an adopted repo `mission-control/` lives in the pinned core clone, not in
your repo, so a bare `mission-control/mc-update.py` resolves to nothing and the board just stays empty. That is
the bug core-v0.14 fixed in `.claude/agent-charter-template.md` — which mandates the shim for exactly this reason.

```bash
.kickoff/bin/mc set headline "Building the checkout slice"
.kickoff/bin/mc plate "Approve deploy to prod (~$5/mo)"   # an only-you item (checkable)
.kickoff/bin/mc add in_progress "Wiring the payment webhook"
.kickoff/bin/mc function eng active "on the API"          # the org streaming in
.kickoff/bin/mc log eng "tests green on the payments slice"   # append to the live feed
.kickoff/bin/mc add blocked "Stripe key" --on "you (Secrets panel)"
.kickoff/bin/mc add decided "json is the canonical store; tracker renders from it"
.kickoff/bin/mc done in_progress 0                         # move to Done
.kickoff/bin/mc render-tracker                             # regenerate TRACKER.md from state
.kickoff/bin/mc show
```

**`mission-state.json` is the single source of truth — `TRACKER.md` is a render of it, not a twin.** The
sections: **`human_plate`** = the irreducible only-you items (the operator taps them done), **`in_progress`/
`blocked`/`decided`/`done`** = the work, **`functions`** = each org function's live status, **`activity`** = the
feed. Update state via `mc-update.py`, then `render-tracker` to refresh `TRACKER.md` for reading/committing/
re-grounding (the board reads state live over SSE). **Never hand-edit `TRACKER.md`** — it's generated; edit state.
This is the one-store rule: the board the org writes to *is* the source the human reads — no second file to drift.

**Planning — capture → commit → cook (the operator's prioritization gate).** Ideas don't jump straight to building. Capture them to the **backlog**, let the operator pick a few into a **milestone** and **commit** it, *then* the agents cook — the commit is the irreducible "what do we build next" call, kept theirs:

```bash
.kickoff/bin/mc backlog "Add gift-card checkout" --theme Payments   # CAPTURE an idea (uncommitted)
.kickoff/bin/mc milestone "v1 launch" --goal "Ship the paid flow"   # name a milestone to group into
.kickoff/bin/mc pick 0 --milestone "v1 launch"                      # pick a backlog idea into it
.kickoff/bin/mc commit "v1 launch"        # THE GATE — the operator commits (surface it for them; don't self-commit)
.kickoff/bin/mc launch "v1 launch"        # dispatch the committed milestone's ideas → in_progress (REFUSES if uncommitted)
```

From the operator's pocket: they say "backlog: X" → you `mc backlog "X"`; they say "commit v1 launch" → you `mc commit`. **`launch` refuses an uncommitted milestone by construction** — agents never cook one the operator hasn't committed. `commit` is a values call (theirs); surface the milestone for their commit rather than self-committing (the control loop's "approve only the irreducible").

## Agent-managed + multi-source (snappy, accurate, streamed as it lands)

MC is **not** the coordinator hand-relaying status — **every agent/function writes its own lane directly and
concurrently.** The board is the live confluence of all the work streams at once. This is safe and accurate
because every `mc-update.py` write takes the **same flock + atomic replace**: simultaneous writers serialize
for the instant of the write, each reads the latest state and appends, so **no update is ever lost or
corrupted** (verified: 30 concurrent writers → 30 entries, 0 lost). The server's SSE then streams each change
to the board in ~1s.

So when you build the multi-function org, give **each function-agent MC-write in its charter**: it owns its
`functions` row (`function <name> <status> <note>`) and streams what it just did to the shared feed
(`log <source> <text>`). The operator watches the **📡 Live feed** fill in real time from eng · comms · growth
· … all at once — no coordinator bottleneck, no stale relay. That's the org's push-surface: parallel work,
one live window.

## The Secrets channel (E2E, built in)

This is how the operator hands you a secret with no terminal and no plaintext on the wire.

**The keypair provisions itself** — `kickoff adopt` and every board start-up run an idempotent ensure
(node ≥22 required; a node-less box says so plainly instead of silently doing nothing). You do not
generate it by hand, and you never ask the operator to run anything on the box.

The board's **🔐 Provide a secret** link (`/secrets`) lets the operator paste a key; the browser encrypts
it client-side with the box public key (`/pubkey`) and POSTs **ciphertext only** to `/secret`.

**You will be told when one arrives** — it lands on the activity feed as `🔐 secret received from the
operator: <LABEL>` (label only, never the value). It is swept after 24h, so consume it promptly.

**Both paths below are topology-dependent — same failure as the `mc` seam above, so read the same way:**

- **Adopted repo:** the scripts live in the pinned core clone, the inbox lives in *your* repo.
  ```bash
  node "$KICKOFF_CORE_DIR/scripts/secret-decrypt.mjs" \
       .kickoff/state/mission-control/secrets-inbox/<file>.json \
       --write-env .env --allow SUPABASE_KEY --key SUPABASE_KEY
  rm .kickoff/state/mission-control/secrets-inbox/<file>.json   # consume once used
  ```
- **kickoff-native project** (bootstrap/greenfield, repo IS the core — `KICKOFF_CORE_DIR` is unset there
  by design, so the form above would break):
  ```bash
  node scripts/secret-decrypt.mjs mission-control/secrets-inbox/<file>.json \
       --write-env .env --allow SUPABASE_KEY --key SUPABASE_KEY
  ```

`--allow <KEY>` is required for `--write-env`: the writer fails closed without an allow-list, and the
inline form keeps that property per invocation without depending on an `allowed-keys.json` that nothing
creates. The inbox path is **instance-private** (`INSTANCE_DIR/secrets-inbox`) — a bare
`mission-control/secrets-inbox/` resolves into the SHARED core clone on an adopter, which is both wrong
and a cross-project leak.

Walk the operator through getting the key in plain words ("Supabase → settings → copy the service key →
paste it into the Secrets panel"). Plaintext exists only in their browser and on the box at use — never in
`mission-state.json`, logs, or Telegram.

## Security (carried from the hardened original)

127.0.0.1 bind only · bearer-token gate on every sensitive route · `/checkoff` only flips an existing `done`
boolean at a validated path (no arbitrary writes) · `/secret` stores ciphertext only (refuses plaintext-shaped
payloads, size-capped) · connection cap + socket timeout · state/token files 0600. Don't loosen these; if you
extend the board, keep the gate.

## Honest-stage

It's a single-file stdlib server — deliberately simple so it can't rot. It's private-by-design (localhost +
token + tailnet); that's the security model, not defense against a compromised box. The board reflects what you
write — keep `mc-update.py` current or it goes stale, exactly like the tracker.
