# Engine parity — what works on Claude Code vs opencode

The kickoff engine is abstracted from the agent engine that runs it: the same system runs on
**Claude Code** and on **opencode** (`WORKER_ENGINE` in your `instance.env` picks which). The
charter's rule is that the system must work equally well on every supported engine — and where a
gap exists it is **recorded here, enforced by the release gate, and explained in plain language**
rather than discovered by surprise.

This page is the ledger. It is machine-checked: `scripts/parity-report.sh` probes the actual
wiring in your tree (files present, hooks configured) and fails the release if it finds drift this
page does not record — or records wrongly. Run it on your own box to see *your* parity state:

```bash
bash scripts/parity-report.sh                    # the tree you are standing in
bash scripts/parity-report.sh --root "$KICKOFF_CORE_DIR"   # the pinned core clone
```

How to read the statuses: **both** = works the same on both engines · **claude-only** = wired on
Claude Code, missing on opencode · **opencode-only** = the reverse · **none** = wired nowhere.
A recorded gap is a known limit, not a hidden one — recorded drift passes the release gate;
unrecorded drift blocks it. When a gap closes, the entry here is updated to say so (with when).

Last full audit against the live tree: 2026-08-28 (the day this ledger shipped).

---

### cap:per-prompt-memory-recall — Memory recall on every turn

Status: both

**Claude Code:** a `UserPromptSubmit` hook runs `memory-retrieval/hook.mjs` (or the plugin's
`memory-hook.sh`) on every prompt, so durable memory surfaces before the agent acts.
**opencode:** there is no session-start/per-prompt context-injection hook point, so the same
retrieval engine (`memory-retrieval/retrieve.mjs`, same `MEMORY_DB`/`MEMORY_DIR`) is exposed as a
**tool** instead (`.opencode/plugins/memory-search.js`), and the charter's re-ground rule makes
searching it part of the start-of-session ritual. The contract — recall before acting — holds on
both; the mechanism differs by necessity (hook vs tool).

### cap:per-prompt-mail-check — Agent-mail check on every turn

Status: claude-only

**Claude Code:** a `UserPromptSubmit` hook runs `plugin/hooks/agent-mail-hook.sh` every turn, so a
sibling org's finding surfaces mid-session instead of rotting unread.
**opencode:** no equivalent plugin exists yet — mail is only seen if the boot checks run it (and
see `reground-boot-prompt`, which opencode also lacks).
**Why the gap:** the opencode plugin surface is young; nothing has ported this hook yet.
**What we recommend:** if you run opencode workers, check `python3 scripts/agent-mail.py check`
manually at session start (the charter's boot-check line already names it), or port the check as a
small `.opencode/plugins/*.js` plugin.

### cap:beat-length-guard — Operator-message ceiling (the 12-line guard)

Status: claude-only

**Claude Code:** a `PreToolUse` hook on the Telegram reply/edit tools (`beat-length-guard.py`)
nudges — and past a runaway cap, denies — overlong operator messages, so the channel stays
followable.
**opencode:** the Telegram bridge is the third-party `opencode-telegram` bot; kickoff has no hook
point inside its send path, so nothing enforces the ceiling.
**What we recommend:** rely on the charter's "keep beats followable" rule (it is in the opencode
coordinator charter too); accept that enforcement is advisory-only on opencode today.

### cap:beat-nudge — Beat-length nudge before composition

Status: claude-only

**Claude Code:** a `UserPromptSubmit` nudge (`beat-nudge.py`) tells the coordinator how long its
recent beats actually ran — aimed at the band where the pain lives, before the message is written.
**opencode:** no equivalent plugin.
**What we recommend:** same as the guard above — charter rule only, no enforcement.

### cap:context-handoff-nudge — Context-fullness handoff nudge

Status: claude-only

**Claude Code:** a `UserPromptSubmit` hook (`context-handoff-nudge.py`) reads the session
transcript, measures how full the window really is, and names the handoff steps near the ceiling —
because self-noticing is unreliable by construction.
**opencode:** no equivalent plugin; `scripts/context-headroom.py` still works when run manually.
**What we recommend:** on opencode, run `context-headroom.py` yourself at natural boundaries (the
charter says when); treat the missing automatic nudge as a known limit.

### cap:mc-spine — Mission Control subagent spine (SubagentStart/Stop)

Status: claude-only

**Claude Code:** `SubagentStart`/`SubagentStop` lifecycle hooks route every subagent's allocation
into Mission Control (`mc-hook.sh`) with zero charter edits — the live board fills itself.
**opencode:** the MC board still works (the coordinator reports via `mc-update.py`), but there is
no automatic per-subagent spine, so the board shows what the coordinator reports, not every
subagent's lifecycle.
**What we recommend:** on opencode, expect a coarser board; the coordinator's own beats are the
source of truth.

### cap:canon-charter-wiring — Canon / red-first sections in function-agent charters

Status: claude-only

**Claude Code:** the `wire-*-into-charters.sh` scripts install function-scoped canon sections
("render it and look", "watch it go RED first") into `.claude/agents/*.md`, because subagents do
not inherit CLAUDE.md.
**opencode:** the same sections are **not** wired into `.opencode/agent/*.md` — opencode
subagents run without them.
**Why the gap:** the wire scripts predate the opencode crew and were never pointed at its charter
directory.
**What we recommend:** if you run opencode subagents for build/review work, port the two wire
scripts to `.opencode/agent/` (mechanical) — or review their output more carefully.

### cap:reground-boot-prompt — Headless re-ground + boot-check system prompt

Status: claude-only

**Claude Code:** every headless worker boots with the full `REGROUND_PROMPT` appended
(`--append-system-prompt` in `scripts/session-run.sh`): re-ground first, run the boot checks
(orphans, memory budget, crew cadence, orphaned-work, agent-mail), the bridge-outage disclosure
rule, and the brains check.
**opencode:** the exec path carries no system-prompt append; the opencode coordinator charter
(`.opencode/agent/coordinator.md`) carries a shorter version of the re-ground + boot-check rules,
but the full prompt (orphan replay details, outage windows) does not reach it.
**What we recommend:** opencode sessions re-ground from the charter — which covers the essentials;
treat the finer boot-check choreography as claude-side until this closes.

### cap:model-pin — Coordinator model pin

Status: both

**Claude Code:** `MODEL` in `instance.env` pins the coordinator (`--model` on the exec); unset
inherits the box's config byte-for-byte.
**opencode:** `OPENCODE_MODEL_PROVIDER` + `OPENCODE_MODEL_ID` pin it (exported by
`session-run.sh`'s opencode branch; per-lane `MODEL=provider/model` overrides also exist in the
lane runner). Closed 2026-08-28 — before that, the opencode coordinator always ran the box
default.

### cap:effort-tier — Reasoning-effort tier control

Status: claude-only

**Claude Code:** `EFFORT` in `instance.env` maps to `--effort` (low→max) on the exec, with the
documented precedence chain (argv > env > instance.env > default).
**opencode:** the opencode branch reads no `EFFORT` — sessions run at the engine's default tier.
**Why the gap:** opencode's model config does not expose an equivalent tier knob in the paths
`session-run.sh` drives.
**What we recommend:** if a task needs maximum reasoning, run that lane on the claude engine, or
pin a stronger model via `OPENCODE_MODEL_*`.

### cap:verified-workflows — Verified workflows (.claude/workflows)

Status: claude-only

**Claude Code:** `.claude/workflows/*.js` define multi-step verified workflows (spec-to-green,
adversarial review) the coordinator can run.
**opencode:** no equivalent — opencode has no workflows mechanism the engine can drive, and this
repo ships none.
**What we recommend:** opencode coordinators decompose the same steps as subagent dispatches (the
task tool) — same shape, no packaging.

### cap:skills-surface — The skills surface

Status: claude-only

**Claude Code:** skills live in `.claude/skills/<name>/SKILL.md` (and travel to adopters via the
plugin's `plugin/skills/`), auto-surfacing to the model by description.
**opencode:** opencode has no skills directory in this tree — the procedures exist only as
prose (charter principles) on that engine.
**What we recommend:** treat skills as claude-side tooling; the opencode crew still gets the
*principles* (they are in the charter), just not the packaged step-by-step procedures.

### cap:orphaned-work-transcripts — Orphaned-work transcript source

Status: claude-only

**Claude Code:** `scripts/orphaned-work.py` reads `~/.claude/projects/<proj>/…` subagent
transcripts, so a killed agent's finished-but-unclaimed work is found and salvageable.
**opencode:** the script has no opencode transcript source yet — on an opencode worker, orphaned
subagent work is invisible to it.
**Why the gap:** opencode's on-disk transcript layout is engine-internal and was not mapped when
the script was written.
**What we recommend:** on opencode, rely on the lane/worktree ledger and Mission Control rows to
spot unfinished work; a port is the honest fix if you run opencode as your primary engine.

### cap:plain-report-output-style — The "Plain Report" output style

Status: claude-only

**Claude Code:** `.claude/settings.json` sets `outputStyle: "Plain Report"` — lead with the answer,
detail in files (rendered from the core's `.claude/output-styles/plain-report.md` seam).
**opencode:** no output-style mechanism is wired — the charter's honest-stage/lead-with-the-answer
rules apply as prose, but the style is not enforced by the engine.
**What we recommend:** none needed; it is a voice preference enforced by charter text on opencode.

### cap:engine-credit-attribution — Git Co-authored-by engine credit

Status: opencode-only

**opencode:** `.opencode/plugins/engine-credit.js` stamps a `Co-authored-by` trailer naming the
live model onto commits made inside sessions — attribution is harness responsibility, not LLM
memory.
**Claude Code:** no equivalent wiring exists in the plugin hooks or project settings.
**Why the gap:** this one was built opencode-first; nothing has ported it.
**What we recommend:** if you care about per-commit attribution on claude workers, a small
PreToolUse/PostToolUse hook on the commit tools is the natural port.

---

## Why some of these exist at all

Every claude-only row above is a **hook** the Claude Code engine offers (per-prompt submission,
subagent lifecycle, pre-tool-use) that opencode either lacks or exposes differently, or a surface
(workflows, skills, output styles) the engine defines. The opencode-only row is the same thing in
reverse. The engine abstraction means the *system* is portable; the *enforcement points* are not
always — so where a hook point is missing, the capability either moves to a different mechanism
(memory recall became a tool) or is recorded here as a limit.

## Adding a capability (maintainers)

1. Probe it: `probe_claude_<slug>` / `probe_opencode_<slug>` in `scripts/parity-report.sh`, plus
   the slug in `CAPS`. Probe the wiring (config reference **and** the file it names), never just a
   file's existence.
2. Record it: a `### cap:<slug>` section here with a `Status:` line — exactly one of
   `both | claude-only | opencode-only | none` — plus the adopter prose.
3. `bash scripts/parity-report.sh` must go GREEN before you commit. The release gate runs it;
   unrecorded drift blocks the release.
