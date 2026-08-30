---
name: setup
description: Guided one-time setup of the CONTROL PLANE — wire Telegram (steer from your pocket) + Tailscale (preview links + the hosted-worker bridge), checking and verifying each step. Use when a new user wants to set up / onboard / configure the control plane, wire Telegram or Tailscale, or asks "how do I steer this from my phone."
---

# setup — wire your control plane

Get the user steering this system from their pocket. Two pieces:
- **Telegram** — the async control channel: ping their phone, they reply in a sentence, work continues.
- **Tailscale** — the private mesh: send a running app straight to their phone (the `preview` skill), and later bridge to an always-on hosted worker.

**You guide; the human does the irreducible bits** (a bot token, a login). Check what's already present, walk them through only what's missing, and **verify each step before moving on**. Never enter or handle their credentials — route token/login steps to them.

## Run it step by step

### 1. Telegram — steer from your pocket (wire it REPO-LOCAL, never the global)
The plugin reads its bot + channel state from env, and **real env wins** over the shared global default
(`~/.claude/channels/telegram/`). Wire *this repo's* bot via repo-local env — that gives each project its own
bot and **never clobbers the user's other Claude Code sessions.** ⚠️ Do **not** run `/telegram:configure`: it
writes the shared **global** state and will overwrite an existing setup (this is a real footgun).

1. **Check the plugin's installed.** Look for the Telegram plugin + its `access` skill. If missing, tell them to install the Claude Code Telegram plugin first, then resume.
2. **Get a bot.** Have them open **BotFather** → `/newbot` → name it → copy the token. *(They do this — never handle the token yourself.)*
3. **Wire it repo-local.** Set two env vars scoped to THIS repo, in a **gitignored** local config:
   - `TELEGRAM_STATE_DIR` → a per-repo channel dir, e.g. `~/.claude/channels/telegram-<repo>` (isolated inbox + allowlist).
   - `TELEGRAM_BOT_TOKEN` → this repo's bot token.
   Cleanest vehicle: **`.claude/settings.local.json`** (gitignored) with an `"env"` block — *you* write the structure + `TELEGRAM_STATE_DIR`; the **human pastes the token** in (never you). Confirm `.claude/settings.local.json` is gitignored. *(If their Claude Code doesn't pass settings-`env` through to the plugin, fall back to the shell / `.envrc` recipe in `RUNNING.md` — same two vars.)*
4. **Apply + lock.** Restart Claude Code in the repo so the env loads, then run **`/telegram:access`** to allowlist their chat id (it writes into the now-repo-local state dir).
5. **Verify.** Have them message the bot; confirm it arrives. If it does, Telegram's live — and their other projects are untouched.

### 2. Tailscale — preview links + the worker bridge
1. **Check it's installed + up.** Run `tailscale status`. If `tailscale` isn't found, tell them to install it (macOS: `brew install tailscale` or the app; Linux: the official installer) and run `tailscale up` (a browser login).
2. **Confirm the node.** `tailscale status` should list their machine. Note the MagicDNS name (`<host>.<tailnet>.ts.net`).
3. **Two modes:** `tailscale serve <port>` = their own devices (private); `tailscale funnel <port>` = public (e.g. an audience). The **`preview`** skill drives these to send a link — `funnel` (public) stays human-approved.
4. **Enable public sharing (Funnel) — free, one-time.** `serve` covers their *own* devices; to share a link a **friend** (not on their tailnet) can open in any browser, they need **Funnel** (public HTTPS). Funnel is **free on every plan incl. Personal — zero spend.** Run **`bash "$KICKOFF_CORE_DIR/scripts/share-enable.sh"`** (adopted repo; kickoff-native: **`bash scripts/share-enable.sh`**) to check: if it reports **ENABLED**, they're set; if **NOT**, it relays the one-time consent turnkey — they run `tailscale funnel <port>` once, tap the consent link it prints (forwardable to their phone), and approve, which provisions the HTTPS cert + `funnel` nodeAttr. **Only the human can approve that tap;** no script or agent can, and it edits no ACL. *(Linux non-root may first need `sudo tailscale set --operator=$USER` — the script surfaces that one-liner; the human runs it.)* The `preview` skill's `share` step then drives the actual share, human-gated.
5. **Verify.** Optional: serve a test port and open the URL on their phone.

### 3. Confirm the plane is live
Tell them what they now have: **ping their phone from any task, reply in a sentence, and get preview links to a running app.** Then point them at the `bootstrap` skill — they're ready to build.

## Tooling note (only if needed)
The control plane needs exactly two tools: the **Telegram plugin** + the **Tailscale CLI**. For visual work later, an "eyes" MCP (a browser / devtools server) makes `preview` and visual-verification stronger — recommend it, don't require it. Anything broader is out of scope here (see `ROADMAP.md` gap 4: harness leverage).

## Honest scope
This wires the **control plane** — not the whole environment. The human does the credential + install steps; you guide + verify. If a step can't be verified, say so plainly — never claim "done" on an unverified step.
