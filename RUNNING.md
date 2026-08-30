# RUNNING — operate it for real (control plane, scaling, hygiene)

The starter runs as a single Claude Code session steered from one Telegram bot. This is how you run it for
real: one instance, several in parallel, or hosted workers — and how to keep it healthy.

## Single instance (the default)

One Claude Code session in a repo + one Telegram bot. The channel state (bot token, allowlist, inbox) lives
**globally** at `~/.claude/channels/telegram/`:
- `.env` → `TELEGRAM_BOT_TOKEN` (the bot, from BotFather) · `access.json` → the allowlist (your chat id).
- One bot process serves the whole machine. Fine when you run one project at a time.

## Many instances in parallel (each with its own bot)

By default every Claude Code on the machine shares that one global channel. To run **several instances, each
wired to its own bot**, give each process its own channel via env vars before launch — verified from the
plugin source (`server.ts`): `STATE_DIR = process.env.TELEGRAM_STATE_DIR ?? ~/.claude/channels/telegram`, and
the per-channel `.env` is loaded but **real env wins**, so `TELEGRAM_BOT_TOKEN` overrides per process.

```bash
# one bot per project (BotFather → a token each), one isolated channel each:
TELEGRAM_STATE_DIR=~/.claude/channels/telegram-myapp \
TELEGRAM_BOT_TOKEN=<myapp-bot-token> \
  claude            # run from the project repo
```

- Each instance gets its own state dir (token, allowlist, inbox, bot pid) → no collisions.
- Pair each bot once (allowlist your chat id) the first time you DM it.
- Tip: drop those two vars in a per-repo `.envrc` (direnv) or a `run.sh`, so `cd repo && claude` just works.

## The real ceiling is the machine, not the software

Each instance + its subagents + any dev servers/builds compete for CPU/RAM. On one laptop:
- Keep **concurrency low** (≈2–4 active instances); the rest idle.
- Background workers die after ~**600s of no output** — design tasks to show progress; don't run heavy builds
  in parallel.
- Give each preview a **distinct port**; stop dev servers when done.
- Monitor load (`uptime` / Activity Monitor) and throttle — saturation is where things get flaky.

## Scaling up: hosted workers (the clean path)

Past a handful, don't cram onto your daily-driver Mac — give each project an **always-on hosted worker** (a
small VPS / cloud box): its own Claude Code instance + its own bot, **Tailscale-bridged** back to your phone.
Dedicated, parallel, always-on, and free to do anything on a disposable machine — no contention with your
laptop. The local Mac is the zero-cost starting point; hosted workers are the scale-up.

## Seeing results from your phone

Use the [`preview` skill](.claude/skills/preview/SKILL.md): serve a build → `tailscale serve` (your devices) or
`tailscale funnel` (public, human-approved) → it sends you a link to open the running app. Tailscale is in the
control plane precisely so this hop — and the hosted-worker hop — is seamless.

## Keeping the agent sharp: the session-refresh supervisor

Long sessions degrade even with memory (`CLAUDE.md` → "Context discipline"). A non-technical operator can't
run `/clear` over Telegram, and the agent can't restart itself — so the harness layer ships a thin supervisor
**above** the agent that owns session lifecycle: [`scripts/supervisor.sh`](scripts/supervisor.sh).

```bash
# THE start surface — one command, every path (v0.7). Foreground by default (Ctrl-C stops it):
bash scripts/kickoff up                                        # this repo, relay-mode worker
bash scripts/kickoff up --auto --detach                        # the headless worker: autonomous +
                                                               #   detached (setsid, own session; logs to
                                                               #   .kickoff/supervisor.log, size-rotated;
                                                               #   prints pid · log path · stop command)
bash scripts/kickoff up --auto --detach --replace              # cycle: stop THIS repo's own supervisor
                                                               #   first (exact verified lock pid, TERM →
                                                               #   ≤35s wait — never KILL -9), then start
REPO_DIR=~/my-project bash scripts/kickoff up --auto --detach  # a different repo, same one command
MAX_SESSION_SECONDS=7200 bash scripts/kickoff up               # + a 2h refresh cadence

# prove the LOGIC first without launching/killing anything real:
bash scripts/kickoff up --dry-run
```

**Per-version start-wrapper scripts are DEAD.** The `~/start-<project>-worker.sh` pattern is retired: both
such wrappers rotted within one version (hardcoded old engine paths, stale version gates) and caused the
v0.6 incident — an upgrade advanced the engine pins while the muscle-memory command kept starting the OLD
engine. `kickoff up` cannot rot that way: at entry it resolves the repo's **pinned** engine
(`.kickoff/core.lock` + `KICKOFF_CORE_DIR` from `.kickoff/instance.env`) and, when the binary you invoked
is not the pinned engine's, **re-execs the pinned engine's `kickoff up` with your argv verbatim** — so any
`kickoff` on the box starts the right engine. (No `core.lock` → the repo runs itself, the un-adopted /
engine-development case; a pinned engine that's missing dies loud instead of silently starting the wrong
one.) `scripts/go-autonomous.sh` is now a one-version deprecation shim for `kickoff up --auto --detach`
and is removed in v0.8.

**Upgrades cycle the worker by themselves (the engine hop).** `kickoff pull <tag>` doesn't leave you restart
homework: the running supervisor watches the repo's pin (`.kickoff/core.lock` + `KICKOFF_CORE_DIR`), and when a
pull advances it, the supervisor **re-execs the newly pinned engine's `supervisor.sh` at the next session
boundary** — same PID, so the lock and the `--auto` grant carry, with no stop/start window. The pull touches the
refresh flag so that boundary arrives within ~15 s ("upgrade and you're on the new version right away"). Before
hopping, the new engine is verified from the new engine itself (its full fail-closed preflight + a syntax check —
the same gate the freshly-exec'd supervisor runs at startup, so a hop can never land on an instance that would
then refuse to start); if that
comes back red the worker **stays on the old engine**, writes a durable `.kickoff/hop-blocked` flag, and sends
one Telegram alert. A pull never changes run-state: a stopped worker stays stopped (the pull prints the one
`kickoff up --auto --detach` line to start it when you're ready).
(v0.6 → v0.7 is the **last manual-cycle upgrade** — a running v0.6 supervisor has no hop-watch, so that one hop
is a one-tap: `kickoff pull core-v0.7` + the new engine's `kickoff up --auto --detach`; from v0.7 onward
`kickoff pull` completes on its own.)

It restarts a **fresh** session (which re-grounds from `CLAUDE.md` + `memory/` + `TRACKER.md`, lossless) on
any of:
- **the refresh flag** `.kickoff/refresh-requested` — the agent touches it when it notices its own degradation
  (after checkpointing), or the Telegram `/refresh` path touches it (see below);
- **a cadence** (`MAX_SESSION_SECONDS`) — refresh at a natural interval;
- **the session ending** — restart so the worker stays live (with a short backoff so a crash can't busy-loop).

**The Telegram `/refresh` path** needs no extra wiring: text messages stream straight into the agent's stdin
as `<channel>` blocks (they do **not** land as files a watcher could poll), so the supervisor watches the flag
only and the agent funnels `/refresh` into it — one line, no terminal:
```bash
touch "$REPO_DIR/.kickoff/refresh-requested"   # the agent runs this on a /refresh (or self-detected degradation)
```

**Safety — it never pattern-kills.** The supervisor launches the session in its **own process group**
(`setsid`) and records that group's PID in `.kickoff/supervisor.session.pid`; a refresh signals **only that
group** (`kill -TERM -- -PGID`), reaching the `claude` child and its descendants and **nothing else** on the
box. There is no `pkill` / name-pattern kill anywhere — a name match can't tell a throwaway from the live
board (`server.py 9200`) and has taken the board down before (`memory/dont-broad-pkill-shared-services.md`).
A `.kickoff/supervisor.lock` keeps a single supervisor per repo. Stop it with
`kill -TERM "$(cat "$REPO_DIR/.kickoff/supervisor.lock")"`.

**What `START_CMD` runs — the real unattended worker.** The supervisor's `START_CMD` defaults to
[`scripts/session-run.sh`](scripts/session-run.sh), which spawns a **persistent, Telegram-bridged,
self-announcing, re-grounding** session — the actual "run it from your pocket unattended" worker. The recipe
it implements (and that you'd adapt for any worker):

- **Persistent Telegram bridge → an INTERACTIVE session, not `claude -p`.** The session is launched with
  `claude --channels plugin:telegram@claude-plugins-official`. The plugin long-polls `getUpdates` and **pushes**
  inbound Telegram messages into the session as MCP notifications (rendered as `<channel>` blocks); the session
  replies via the `reply` MCP tool. A one-shot `claude -p` runs a single turn, **EOFs stdin, the poller shuts
  down, and the bridge dies** — so the worker must be the interactive `--channels` form.
- **stdin must never EOF *and* must be a real TTY (keepalive + PTY).** Two requirements, both learned the hard way:
  - **Never-EOF.** An interactive session whose stdin closes tears the bridge down, so the wrapper feeds it an
    endless empty stream — `tail -f /dev/null`.
  - **A real TTY.** `claude --channels` fed a *non-TTY piped* stdin (the bare `tail -f` keepalive) **never enters
    its notification-processing loop** — verified root cause 2026-06-25: the headless worker did **zero** turns on
    inbound Telegram (no re-ground, no reply). The fix is a pseudo-terminal: the wrapper **re-execs itself inside
    `script(1)`** (which allocates a `/dev/pts`), with the keepalive feeding `script`, and lets `claude` inherit
    that pty as its stdin:
    ```bash
    # outer pass (stdin NOT a tty — the wrap is decided by [ -t 0 ], never by an inheritable
    # env var; a leaked flag once made a child skip its wrap → print-mode crash loop, 2026-07-12):
    exec script -qfe -c "_KICKOFF_PTY_GEN=$$ exec bash '$0'" /dev/null < <(tail -f /dev/null)
    # inner pass — stdin IS the pty now, so the wrap block skips naturally; do NOT redirect
    # stdin again or claude loses the TTY (_KICKOFF_PTY_GEN only DETECTS a broken script(1):
    # wrapped once + still no tty → fail-loud exit 1, never an infinite re-wrap):
    exec claude --channels … --append-system-prompt "$REGROUND_PROMPT"
    ```
  Both `script` and the `tail` keepalive stay **in the supervisor's process group** (no `setsid`/`disown`/background)
  so a refresh's `kill -- -PGID` reaps them too — no orphan `tail`, and still group-targeted (never PID/name-killed).
- **Startup announce (heartbeat).** Before exec'ing claude, the wrapper best-effort curls the Bot-API
  `sendMessage` ("🔄 Worker session (re)starting — re-grounding…") so the operator sees the worker came back even
  before it has re-grounded. The bot token is read at **runtime** (`jq` from `.claude/settings.local.json`),
  never hardcoded or echoed; any missing piece (token, chat id, a failed curl) **skips the announce and never
  aborts** the wrapper. (Caveat: the token transits the Bot-API **URL**, so it is briefly visible in `ps` for
  that one `curl` — a known, minimal-window trade-off of the Bot API; for a hardened worker, move to a
  `--data`/`stdin`-fed sender or a per-worker bot whose token leaking matters less.)
- **Re-ground on (re)start.** The wrapper passes `--append-system-prompt` telling the fresh session to read
  `CLAUDE.md` + `memory/MEMORY.md` (+ relevant `memory/`) + `TRACKER.md`, send ONE Telegram confirmation naming
  the in-progress item, then continue — making every refresh lossless (the memory + tracker discipline is what
  makes that true).

> ⚠️ **TWO-COORDINATOR WARNING (one getUpdates consumer per bot).** Telegram allows **exactly one** `getUpdates`
> long-poller per bot token. If an unattended worker uses the **same bot token + `TELEGRAM_STATE_DIR`** as a
> concurrent interactive `--channels` session (e.g. you, in a terminal), the two pollers **fight** — each steals
> the other's updates and messages go missing. An unattended worker **MUST** use a **distinct bot token +
> `TELEGRAM_STATE_DIR`** from any other concurrent `--channels` session. **Recommendation: give the worker a
> dedicated bot** (BotFather → a second token), point it at its own state dir, and pair it once.
>
> This is configured per-instance in **`.kickoff/instance.env`** (copy `scripts/instance.env.example`):
> ```bash
> # .kickoff/instance.env
> export TELEGRAM_STATE_DIR="$HOME/.claude/channels/telegram-worker"
> ```
> The core `session-run.sh` has **no default channel** — it **fails loud** if `TELEGRAM_STATE_DIR` is
> unset (or still holds the `YOUR-WORKER` placeholder), so no instance can silently inherit another's
> channel — the double-poller footgun killed at the root. Supply the dedicated bot token in that
> channel's `.env` / real env.

Honest scope: the supervisor manages a session it launched (the hosted-worker / non-tech path); it **can't**
restart an interactive session a human is in — there the fallback is the human running `/clear`. Adapt
`START_CMD`/`session-run.sh` to your worker.

## Run kickoff's own harness on a second machine (engine-development mode)

The sanctioned **source-checkout mode**: you clone the kickoff repo itself (to develop it, or to
run the harness on a second box without adopting a pinned core into some other project). Until
2026-08-26 this mode was documented nowhere and hand-wired — interactive sessions had no
`KICKOFF_CORE_DIR`, no retrieval index was ever built, and the env-less indexer died as a bare
ENOENT. One command now wires the whole thing:

```bash
git clone <the kickoff repo> && cd kickoff
bash scripts/bringup-source-instance.sh      # idempotent — safe to re-run after git pull
```

**Already cloned the PUBLIC `main` branch?** Then you are on the curated release lineage, which
shares **no merge base** with the dev trunk — and up to three tracked-on-`main` paths are
gitignored on it (`memory/MEMORY.md` — the always-loaded roll-up —
`mission-control/mission-state.json`, and on older release lineages `TRACKER.md`), so a bare
`git checkout` **deletes them silently**. Use the
switch turnkey instead; it saves them across, restores `MEMORY.md` from `origin/main`, and then
execs the bring-up above:

```bash
cd <your clone>
git fetch origin
git show origin/brownfield-devex:scripts/newbox-from-main.sh > /tmp/nb.sh && bash /tmp/nb.sh
```

What it does: `kickoff init` (only if `.kickoff/instance.env` is absent — never clobbers), then
patches `instance.env` to source mode (self-pinning `KICKOFF_CORE_DIR` to **this tree** — the
memory plugin/hook seam runs the checkout you're developing; `MEMORY_DIR=<repo>/memory`,
`MEMORY_DB`/`MEMORY_HOOK_LOG` in `memory-retrieval/`; a hand-set value is left alone), then a
**from-scratch index build** — an existing `memory-index.db` is moved aside first, because a db
built by hand under whatever env was live is untrusted — then verifies by **consumed state**: a
real retrieval must answer `read the operator early` with `memory/read-the-operator-early.md`,
and `crew-review-due.sh` must print a DUE/NOT_DUE verdict (never its exit-2 "not an instance"
refusal).

P1 is also runnable without a live session — `bash scripts/memory-search-probe.sh` drives the
plugin's real `execute()` with `KICKOFF_CORE_DIR` unset (the interactive shape) and reports
GREEN/FAILED, or SKIPPED when `.opencode/node_modules` is absent. Use it to tell a memory problem
apart from an engine problem when opencode itself is unhealthy.

It ends by printing the acceptance proofs (P1–P4): a fresh **opencode** session's `memory_search`
answers; a fresh **claude** session's recall hook surfaces memory (and its stderr stays quiet —
"first index build not done" is the tell it didn't); adding/removing a temp file under `memory/`
reindexes in the same turn (the hook's auto-reindex); `crew-review-due.sh` gives a sane verdict.
Walk them once — the origin is not the deployment.

Two things this mode deliberately does **without**:

- **Live Telegram steering** — optional and separate: it needs *your* bot token (BotFather), wired
  per [Many instances in parallel](#many-instances-in-parallel-each-with-its-own-bot) into the
  default `TELEGRAM_STATE_DIR` the turnkey sets. Until then the instance is fully local.
- **`kickoff pull` / upgrade turnkeys** — they *refuse* engine-source trees **by design**: this
  repo **is** the engine, so it upgrades via plain `git pull` (then re-run the bringup script to
  rebuild the index).

---

*Verified against the Claude Code Telegram plugin v0.0.6. The definitive end-to-end check is a fresh Claude Code
session wired to a brand-new bot — do that once to confirm your setup before relying on it.*
