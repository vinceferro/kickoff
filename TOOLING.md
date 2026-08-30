# TOOLING — give the agents eyes, hands, and current knowledge

An agent is only as capable as the tools you give it. The coordinator + subagents ship with file access and
a shell; wire a few MCP servers to make them genuinely capable — and give each subagent only what its charter
needs (least privilege).

**Two tiers, and the AGENT picks (the operator never has to):** a **generic baseline** ships with every
project (the list below); **handpicked** plugins are added per-project by *what the project is* (Supabase for
a DB, Expo for mobile, Vercel for deploy, Stripe for payments, …). The **`plugins` skill**
(`.claude/skills/plugins`) does the picking — detect the stack/domain → install the right plugins → prune the
unused — and `bootstrap`/`adopt` invoke it. The operator never chooses a plugin; they only supply a secret
when a secret-bearing plugin needs one, via a secure channel (never Telegram). See the `plugins` skill.

## MCP servers worth wiring — the generic baseline

- **Telegram relay** — the control plane. The agent pings your phone, you reply in a sentence, it continues.
  This is what makes the whole thing pocket-steerable (see `README.md`).
- **Browser / DevTools** (e.g. a chrome-devtools MCP) — *eyes* for web work. Render and look at the real
  output; don't trust code-only checks. The single highest-leverage tool for anything with a UI — treat it as
  a **critical dependency** for any UI task, not a nice-to-have. **Detect and announce loss-of-eyes
  immediately** ("my preview/screenshot tool is down") so the human can restart it — silent degradation is the
  trap, where you keep shipping UI you never actually *looked at*. With eyes down, keep building but say plainly
  "verified by tests, not visually" and ask the human to eyeball the running preview — never imply visual
  sign-off you didn't do.
  **Eyes have a second, quieter failure: they work, but on the CPU.** The shipped MCP config forces the
  ANGLE GL backend *and* keeps a software fallback, so it uses a GPU where there is one and silently
  degrades where there isn't. Silent is right for the page and wrong for you — measured on one 3D page,
  software cost **9.1 cores vs 0.6** on a GPU, and a 15× slowdown with no signal gets blamed on the tool
  instead of on unwired hardware. Before a heavy visual pass, or when rendering feels slow, ask:
  `bash scripts/gpu-render-check.sh --render` → prints the real renderer string (exit 3 = on the CPU,
  2 = WebGL unavailable). Its cheap mode (no flag) reads only the preconditions and stays **silent** when
  they're right — it can prove "this will be software" but never claims the positive, because the only
  thing that knows which renderer Chrome picked is Chrome.
- **Docs** (e.g. a context7-style MCP) — *current* library/framework docs, so agents don't code from stale
  training memory.
- **GitHub** — PRs, issues, CI status, releases.
- Built-in: filesystem + shell (already there); add language servers / test runners as your stack needs.

## Per-function least privilege (each agent gets ONLY its function's tools)

The coordinator holds the broad coordination set, but **every function-agent it dispatches declares its
minimal profile** in its `.claude/agents/*.md` frontmatter (`tools:` — a real Claude Code capability) and
gets *only* that. Match tools to the charter:

- `planner` — read + search, **no write**.
- `builder` — read/write/edit + shell (it builds and runs) + the stack's plugins.
- `reviewer` — read + shell only (it runs and inspects; it does **not** rewrite — fixes go back to the
  builder, so it can't "helpfully" fix what it found and hide the signal). This is why the `review` skill's
  break-it reviewers are read-only.
- `deployer` — read + shell, **no secret access**; the go-live is human-approved (the spend/destructive gate).
- a `comms`/content agent — web + write to its own docs, **no DB, no deploy**.

Three reasons this matters — it's not just hygiene:

1. **Focus.** A toolset that matches the job → cleaner reasoning, fewer wrong-tool detours.
2. **Least-privilege security.** A comms agent literally *can't* touch the DB or deploy → smaller blast
   radius. Only the agents that *could* spend/destroy carry those tools, and those stay gated.
3. **Context efficiency.** Fewer tool schemas per agent = less context burned on irrelevant tools = leaner,
   slower-degrading agents. This directly serves the context-discipline rule (`CLAUDE.md`): the cheapest way
   to keep an agent sharp is to not load it with capabilities it never uses.

**Assign project plugins to the *right* function**, not to everyone: a DB plugin (Supabase) goes to the
builder/data agents, not comms; a deploy plugin goes to the deployer. Least-privilege by default; expand a
profile only on a genuine, recurring need. Don't hand every agent every tool — scoped tools keep each agent
focused and keep the trust boundary clean.

## Honest note

MCP availability depends on your Claude Code setup — these are recommendations, not a fixed dependency list.
Wire the ones the work needs; skip the rest. Start with the relay (control plane) + a browser MCP (eyes).
