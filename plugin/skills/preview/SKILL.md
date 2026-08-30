---
name: preview
description: Show a running result on the human's phone — or share a PUBLIC link a friend can open. Start the project's service(s), expose them over Tailscale (serve = your devices only; funnel = public, human-gated), and report ONE link. Two tiers: a single service (tailscale serve/funnel) or ≥2 services sharing an origin (the box-ingress Caddy). Use when the human wants to SEE the thing running, or SHARE it, not just read that tests passed.
---

# preview — a link to see it running

Closes the loop from "it builds" to "look at it on your phone." Given a runnable project, serve it and hand
back a Tailscale URL the human can open from anywhere. Pick the tier by the app's shape.

## Tier 1 — a single service (the fast path)

One process, "show me this screen": a dev server, a preview build, a static `dist/`.

1. **Start it** on a **fixed** port so the URL is stable (`npm run dev`, `expo start --web`, a static
   `dist/` via a file server, etc.). Prefer a built/prod-mode server; never background a live-reload dev
   server on a shared box.
2. **Serve it to the human's OWN devices (the default — autonomous).** Publish it on their **tailnet**
   (their phone + laptop). Private; enough to view it themselves from their pocket. But
   **`tailscale serve` is set-not-append**: pointing an already-mapped `<tailnet-port>` at a new target
   **silently replaces** the existing handler — no error, no warning — and the bare form
   (`tailscale serve --bg <port>`) maps the **:443 ROOT**, the box's front door, so on a shared box it
   darkens every app already living behind it. **Read `serve status` FIRST and pick a port that is not
   listed** — never the bare root-mapping form on a shared box:
   ```bash
   tailscale serve status                       # ① pre-check: EVERY port here is TAKEN — pick one that is NOT
   tailscale serve --bg --yes --https=<free-tailnet-port> http://127.0.0.1:<local-port>   # ② tailnet-only
   tailscale serve status                       # ③ confirm YOUR mapping exists (absent = a DARK link)
   ```
3. **Report the tailnet link.** Send `https://<machine>.<tailnet>.ts.net:<free-tailnet-port>/` so the
   human taps it and sees the app. **This link opens ONLY on the human's own devices** — it is *not*
   shareable with a friend.

### Share a PUBLIC link — the magic moment (a friend, NOT on the tailnet)  ·  HUMAN-GATED

The `serve` link above is **your-devices-only**. To hand someone a link **a friend can open in any
browser** (they are not on your tailnet), you need Tailscale **Funnel** — public HTTPS. It is **free**
(every plan incl. Personal → **zero spend**) and fully **reversible**, but it is a **public** surface, so
it stays **human-gated**: you never funnel autonomously. The engine is the same proven invocation
`scripts/ingress.sh` uses.

1. **Precondition-check enablement — don't guess.** Run `bash "$KICKOFF_CORE_DIR/scripts/share-enable.sh"` (adopted repo; in a kickoff-native
   project use `bash scripts/share-enable.sh` — `KICKOFF_CORE_DIR` is unset there by design). It reads
   `tailscale status --json` for the funnel capability). If it reports **ENABLED**, continue. If **NOT enabled**, relay its
   one-command consent turnkey to the human: they run `tailscale funnel <port>` once, tap the consent
   link it prints (forwardable to their phone), and approve — Tailscale then provisions the HTTPS cert +
   the `funnel` nodeAttr. **Only the human can approve that tap** (a browser consent); no script or agent
   can, and it edits no ACL. (Linux non-root may first need `sudo tailscale set --operator=$USER` — the
   script surfaces that one-liner; the human runs it.)
2. **Pick a FREE funnel port — `8443` or `10000`, NEVER `443` — occupancy-checked, not guessed.**
   Funnel allows only 443 / 8443 / 10000, and 443 is usually the box's primary front door (an
   ingress/serve already owns it). Funnel is **set-not-append** too: starting a funnel on an occupied
   port silently REPLACES whatever owns it. So re-run the check with your intent declared —
   `SHARE_FUNNEL_PORT=<8443|10000> SHARE_UPSTREAM=http://127.0.0.1:<local-port> bash "$KICKOFF_CORE_DIR/scripts/share-enable.sh"`
   — it reads `tailscale funnel status` and **hard-stops (exit 7) naming the current owner** if the
   port is taken by a different upstream, steering you to the free port (or to Tier 2 box-ingress
   path-routing when every safe funnel port is taken). Only an exit-0 port is yours to use.
3. **Get the human's explicit go, THEN start it:** `tailscale funnel --bg --https=<free-funnel-port> http://127.0.0.1:<port>`.
   This is the one action you do not run on your own — wait for the yes.
4. **Relay the PUBLIC url:** `https://<machine>.<tailnet>.ts.net:<free-funnel-port>/`. Confirm it actually
   responds before calling it live. **A friend can now open this in any browser** — that's the magic moment.
5. **State the honest limits.** Funnel is **bandwidth-limited** — fine for sharing a link, not for
   production traffic. Teardown is one reversible line, no data loss: `tailscale funnel --https=<free-funnel-port> off`.

## Tier 2 — ≥2 services sharing an origin (the box-ingress Caddy)

The moment an app is **two or more services that must share one origin** (a frontend calling a relative
`/api`, cookies, CORS), single-port serving structurally breaks and Funnel's 3-port ceiling caps you at
three public apps. Route them through the one machine-level Caddy instead: one Funnel :443 → one Caddy →
`/<project>/<app>` path-routing. `scripts/ingress.sh` owns it; state is `registry.json` (machine-level,
zero repo footprint). `<project>` mirrors the repo basename.

1. **Detect the services** and their ports (frontend + api + any gateway).
2. **Set each app's base path — the ONE thing ingress cannot do for the app.** Each app must own its
   `/<project>/<app>` prefix via config, not a hardcoded `/`:
   - Next.js → `basePath: '/<project>/<app>'` (next.config) or the app's `*_BASE_PATH` env.
   - Expo web → build with `baseUrl: '/<project>/<app>'`.
   - **If an app hardcodes `/` (no configurable base path), STOP and REPORT it** — do not serve it: deep
     links and assets will 404. Say which app and what it needs, rather than hand over a broken URL.
3. **Register each service:** `INGRESS_REPO="$REPO_DIR" ingress.sh add-app <project> <app> <static|proxy> <target> [strip]`
   (static export → `static`; a running server that owns its basePath → `proxy` with `strip=false`).
   `INGRESS_REPO` tags the route with the serving repo (its canonical path) so **`kickoff eject`
   auto-removes it** — without it the route registers repo-less and eject hits the fail-safe SKIP
   (it prints a manual `ingress.sh remove` instead of tearing the route down for you).
   Reserved private-serve ports (Mission Control) are refused at both add and gen time — by design.
4. **Generate + bring up:** `ingress.sh gen && ingress.sh up` (validate + zero-downtime reload). Caddy
   binds `127.0.0.1:<listen>` (loopback) — tailnet-private, not LAN-reachable.
5. **Health-gate before you send anything:** `ingress.sh health`. It curls every proxy upstream and
   checks every static root. **If ANY app is down, do NOT send the URL** — report which upstream is down
   (e.g. a Next.js server that isn't running 502s). An **empty/misregistered registry (zero apps) also
   fails the gate** — nothing is registered, so there is nothing to hand over. A blind "here's your link"
   to a dead (or absent) route is the failure this gate exists to stop.
6. **Report ONE tailnet URL.** All apps live under the single `https://<host>.ts.net/<project>/<app>`.
   The **funnel → public flip stays human-gated** — the default is tailnet-private; you never funnel
   autonomously.

## Honest notes

- Tier-1 servers and the Tier-2 Caddy are **background processes** — they stay up until stopped. Fine on
  an always-on box; stop Tier-1 when done (`tailscale serve --https=<free-tailnet-port> off` — the SAME
  explicit port you served on, never a root/443 teardown, which would drop someone else's mapping; then
  kill the dev server). The Caddy
  is a shared machine singleton — `ingress.sh remove <project>` drops just your routes (this is what
  `kickoff eject` calls); never stop the whole Caddy out from under other projects.
- `serve` (tailnet) is private to your devices; `funnel` (public) is the trust-boundary one — the human
  runs it. Tier 2's loopback bind (Fix 8c) is what makes "tailnet-private" genuinely private.
- A preview is **not a deploy**. To actually ship, that's the `deployer` (human-approved go-live).
- Confirm the URL actually responds before claiming it's live — render-and-look applies here too. For a
  visual result, say "rendered, please confirm on your device" — a headless shot is not the phone.
