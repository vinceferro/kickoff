---
name: plugins
description: Manage the project's harness plugins / MCP servers — the AGENT picks them by what the project needs (the operator never has to). Detect the stack + domain → install the relevant capability plugins; add one on demand when a need surfaces; prune unused ones (minimal surface = security). Handles the two gates: secret-bearing plugins need the human's key via a secure channel; keep the surface minimal.
---

# plugins — the agent picks the capabilities, the human never has to

A plugin / MCP server is a **capability** (eyes, a database client, a deploy CLI, current docs) — and also an
**attack surface**. The whole point of this system is that the operator doesn't have to know *which* plugin
they need: **the agent picks**, driven by what the project actually is. This skill is how.

## Two tiers

- **Generic baseline — every project gets these** (the operator interface + the always-useful):
  - **Telegram** — the control plane (the operator steers from their pocket; see `RUNNING.md`).
  - **Preview / browser** — *eyes* (render-and-look, show-don't-tell). A critical dependency for any UI work.
  - **Docs / context** (a context7-style MCP) — current library docs so agents don't code from stale memory.
  - **git / filesystem** — already built in.
- **Handpicked per-project — capability-driven, picked by what the project IS:**
  - DB → Supabase / Postgres MCP · mobile → Expo · deploy → Vercel / Netlify / Cloudflare · payments →
    Stripe · analytics → PostHog · plus any domain-specific MCP the work needs.

## The motion

1. **Detect the need.** From the stack + domain (what `bootstrap` just scaffolded, or `adopt` just read):
   an Expo app → Expo; a Supabase backend → the Supabase MCP; a payments feature → Stripe. Don't install on
   spec — install for a capability the project actually uses.
2. **Install + configure.** Add the server to the project's MCP config (`.mcp.json` / the harness's plugin
   config) — command, args, and any non-secret settings. Assign it to the **right function-agent**, not to
   everyone (`TOOLING.md` → per-function least privilege: a DB plugin goes to the builder/data agent, a deploy
   plugin to the deployer — never to comms).
3. **On demand.** When a need surfaces mid-build ("we need to query the DB"), install the one plugin that
   covers it — then and there — rather than front-loading a big toolbox.
4. **Prune.** Periodically remove plugins the project stopped using. **Minimal surface = security**, and fewer
   tool schemas = leaner, slower-degrading agents (ties to the context-discipline rule in `CLAUDE.md`).

## The two gates

1. **Secret-bearing plugins** (Supabase service key, Stripe key, a deploy token): you **configure the plugin**,
   but the **human supplies the secret** — via a secure channel, **NEVER Telegram** (chat isn't E2E; treat
   anything pasted there as exposed). This *is* the spend/secret gate on the plugin surface. The non-technical
   mechanism for this is the MC client-side-encrypted "Secrets" channel (the box holds a keypair; the human
   encrypts in their browser; the agent decrypts → writes to config) — see the secret-provisioning track. For
   the dev case, the human sets the key locally and you say so plainly. **Walk the operator through obtaining
   the key in plain words** ("Supabase → project settings → copy the service key → paste it into the secure
   input"), then it's their hands-on step, turnkey.
2. **Minimal surface.** Every plugin is a capability *and* an attack surface — install only what's needed, and
   prune what isn't. Default to the smallest set that does the job.

## Honest-stage

What plugins/MCP servers are available depends on the harness setup — these are the common, high-leverage
ones, not a fixed list. Wire the baseline first (control plane + eyes), then handpick by capability. If a
plugin can't be installed in the environment, name the gap as an unlock task for the human (don't silently
work around a missing capability) and proceed with what you have.
