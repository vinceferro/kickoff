# Quickstart — try it tonight

The loop runs through your own agent engine (Claude Code by default; opencode via one env line in .kickoff/instance.env) + model, so treat outputs as a starting point, not a guarantee.
There are no static templates — the system scaffolds fresh.

**Get in with one command** — clones + pins the engine at the reviewed release tag and links the
`kickoff` front door into `~/.local/bin` (already on your PATH if that dir is; if not, the installer
prints the full path plus an optional one-liner — no dotfile edit). Safe to re-run: it verifies and
repairs, never moves an existing pin — `kickoff pull` owns upgrades (alpha note: name the tag — `kickoff pull core-v1.0.0-alpha`; bare auto-select waits for the first stable release):

```bash
curl -fsSL https://raw.githubusercontent.com/vinceferro/kickoff/core-v1.0.0-alpha/install.sh | sh
```

Rather read it before you run it? Same install, long form — one POSIX-sh file, 279 lines, no sudo and
no dotfile edits:

```bash
curl -fsSLO https://raw.githubusercontent.com/vinceferro/kickoff/core-v1.0.0-alpha/install.sh
less install.sh && sh install.sh
git -C ~/kickoff-core log -1 --format='%H'   # the commit you are pinned to; cross-check CORE-CHANGELOG.md
```

---

## 1. Bootstrap something new (greenfield)

1. Make the repo you want to build in, wire kickoff into it, and open **Claude Code** there. You never
   clone kickoff itself — the installer already pinned the engine:

   ```bash
   mkdir ~/my-idea && cd ~/my-idea && git init
   kickoff adopt --dir ~/my-idea     # additive; `adopt` handles a brand-new empty repo
   claude                            # this session reads CLAUDE.md and acts as the coordinator
   ```
2. Give it a brief — the **idea + a scope bar, not a spec.** Let it own the engineering (stack, API, design).
   Try this verbatim:

   > *"Build me a small URL shortener — paste a long link, get a short one back that redirects. Keep it tiny:
   > an endpoint or two, with a test. Propose the stack and build it."*

   *(Briefs are idea + scope, not a spec. Spelling out the endpoints/data model does the system's job for it —
   the point is it makes those calls. Add "no deps, single file" only if you want it dead-predictable.)*

3. The **bootstrap skill** runs its motion: propose a stack (with tradeoffs) → on your pick, scaffold fresh
   with the real CLI → wire one proof test → run it → report. Steer with one sentence to refine — it doesn't
   start over.

   *(Verified: the skill's motion scaffolds a fresh project to a green test in ~26s on the zero-dep fast
   path — expect a few minutes when your stack pulls real dependencies.)*

That's the whole motion: **brief → run → review → steer → run again.**

---

## 2. Adopt it into a repo you already have

Most of your work isn't greenfield. See [`ADOPT.md`](./ADOPT.md) — add a `CLAUDE.md` + specialist subagents +
a tracker to your existing codebase and steer it the same way. This is the on-ramp that makes it real for
day-to-day engineering.

---

## 3. Steer it from your pocket

Wire the control plane (see [`README.md`](./README.md)): a **Telegram** relay + **Tailscale** mesh, with
**SSH/Termius** as the fallback shell. Once it's async, a phone is enough to run the whole thing.

---

## Grow it

[`GROWTH.md`](./GROWTH.md) — the path from starter → system + the function catalogue ·
[`TOOLING.md`](./TOOLING.md) — MCP + tool recommendations. Ask the coordinator to author new specialists as the
work demands — it writes the charter, you approve.

Developing kickoff itself on another machine? See [`RUNNING.md`](./RUNNING.md) → *"Run kickoff's own harness on a
second machine (engine-development mode)"* — one command wires the clone.

## Make it yours

`CLAUDE.md` = how the coordinator behaves · `.claude/agents/` = your crew · `.claude/skills/` = capabilities
like `bootstrap` · `memory/` = durable facts · `TRACKER.md` = the source of truth. A starting point, not a
finished framework.
