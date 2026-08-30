# Skill template — crystallize a recurring procedure into a skill from this

Copy the fenced block into `.claude/skills/<name>/SKILL.md` and fill it in when the crew keeps re-doing
the SAME multi-step procedure by hand and it clears the bar (see `crew-review` → "Distill a recurring
procedure into a skill": recurring ~2–3×, generalizable, not already covered). The coordinator authors
this **on the human's approval** — a new `.claude/skills/` file is a procedure the whole crew will
auto-load and obey, so it's gated like a charter/CLAUDE.md edit, never a silent auto-write. Delete this
comment block; keep the frontmatter + sections.

> **⚠ Write every tool reference NATIVE to this substrate — `Bash / Task / Grep / Glob / Read / Write /
> Edit / Skill`.** This is the load-bearing gotcha when a procedure is borrowed from another agent
> system: never a foreign agent's tool names or paths (no `terminal` / `delegate_task` / `search_files`
> / `skill_manage` / `~/.hermes/...`). A skill that names a tool the harness doesn't have is dead on
> arrival, silently — it will look authored and never work.
>
> **Recall is free — do NOT build any retrieval machinery.** Claude Code auto-lists every `SKILL.md` by
> its `description` in the per-turn skill listing and invokes it via the Skill tool (`/<name>`). The
> `description` string IS the whole recall surface, so front-load its trigger words. No hook, no
> embedding index, no learning graph.
>
> Everything below the fence is copied verbatim into the skill, so keep notes like this one OUTSIDE it.

---
```
---
name: <kebab-case-name>            # e.g. release-notes, db-migrate, triage-flake
description: <one line — WHAT this procedure does + WHEN to reach for it. Front-load the trigger words;
             this string is the whole recall surface (Claude Code auto-lists + Skill-invokes by it), so
             a vague description is a skill that never fires. Mirror the house style of the shipped
             skills' descriptions.>
---

# <name> — <the one-line motion>

<One-paragraph overview: the recurring procedure this crystallizes, and why it earned a skill — it was
done by hand ~2–3+ times, it generalizes beyond the one task, and nothing already covered it.>

## When to use
- <the concrete trigger(s) — the situation that should make a future session reach for this>
- Skip it when <the cheap negative case>, so the skill stays sharp instead of firing on everything.

## The motion
1. <step one — native tools only: Bash / Task / Grep / Glob / Read / Write / Edit / Skill>
2. <step two — keep each step verifiable; name the runnable proof where the procedure has one>
3. <...>

## Pitfalls
- <the mistake this procedure keeps hitting — the reason it's worth capturing, not just the happy path>
- Honest-stage: say "draft / untested / I don't know"; never dress a failure as success.

## Verification checklist
- [ ] <the runnable check that proves the procedure worked — a passing test, a byte-compare, a live curl>
- [ ] Scanned / gated where it touches secrets, spend, or anything irreversible.
```
