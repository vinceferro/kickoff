---
name: adopt
description: Apply this orchestration system to an EXISTING (brownfield) repo. Read the codebase, draft a CLAUDE.md + specialist subagents that match its real domains, add a tracker + memory — additively, without touching its source. Use when the human wants to run the coordinator pattern on a repo they already have.
---

# adopt — bring the system to an existing repo

The brownfield counterpart to `bootstrap`. `bootstrap` scaffolds a *new* project; `adopt` onboards the
coordinator pattern onto a codebase that **already exists**. It is **additive and non-destructive** — it adds
orchestration scaffolding, it does **not** rewrite the repo's source, history, or config.

## HEADLESS ENTRY CONTRACT — you are a supervised worker, and nobody is at a terminal

Everything below this section is written for a session a **human started** by typing `/adopt`. That is not
the only way in, and it was never the common one: the operator steers from a **phone**, so the path that
actually runs is `kickoff adopt --accept` (scripted consent) followed by `kickoff up`. `kickoff adopt` wires
the plumbing — gates, pin, manifest, shims, plugin — and then **cannot author the mind**, because a bash
script cannot read a repo's domains. It leaves `.kickoff/adopt-brains-pending` saying exactly that.

**Measured cost of there being no contract here (2026-08-06, six live adopters):** one had run 35
memory-writing sessions with no `.claude/agents/` at all; two of them still carried the
byte-identical **76-byte** `CLAUDE.md` that is nothing but the kickoff include. The orgs were steerable and
could not act. A worker that found the marker had no sanctioned motion, so it defaulted to **asking** — and
the person it would ask is on a phone and cannot type a slash command.

**You enter this motion when** `python3 "$KICKOFF_CORE_DIR/scripts/crew-probe.py" brains-verdict --repo .`
exits non-zero (equivalently: `.kickoff/adopt-brains-pending` exists). Then:

**Author autonomously, then announce.** On a **brainless** org there is nothing to overwrite and the work is
reversible (`kickoff eject`, or delete the charters), so do it and report — do not sit waiting for permission
to start. You may author, without asking first:
- the **first crew** — one agent per genuinely UNCOVERED domain, via `gen-agent` (step 3's procedure below,
  restraint tools included — `gen-agent` refuses to clobber an existing charter)
- the **`CLAUDE.md` body** — when and only when it is the bare kickoff include with no body
- `.kickoff/KICKOFF.local.md`, the memory seed, and the tracker, when those are still stubs

**Never, on any path:** overwrite or rewrite an existing agent charter, an existing `CLAUDE.md` body, an
existing memory file, or anything in the repo's own source. A crew that exists is the operator's — if the
crew is present and only the charter body is bare, author **only** the body and propose nothing else. The
restraint rule in step 3 is not relaxed by being headless; it is the reason this is safe to do unattended.

**Then announce over Telegram and ask for one word.** Name the domains you found, the agents you created
(one line each), and what you did not touch. Ask for *approve / tighten*. Say plainly that it is reversible
and how. Then run `kickoff doctor` to retire the marker and continue with normal work.

**Still gated, exactly as everywhere else:** spend, destruction, and anything irreversible. Authoring a first
crew is **bootstrap, not mutation** — there is nothing to overwrite. Changing a crew that already exists is
mutation, and that still goes to the operator as a proposal.

---

**Consent first (v0.7 §4) — if `kickoff adopt` hasn't run yet.** The mechanical wiring step is gated: a
non-interactive invocation (your Bash tool has no tty) **refuses to write** without `--accept`. Run the
two-step consent flow — never jump straight to the write:
1. `kickoff adopt --dry-run --dir <repo>` — read-only; prints the §4 pitch + the exact per-file plan.
   Relay it to the operator (this pitch *is* the consent surface).
2. On the operator's go: `kickoff adopt --dir <repo> --accept` — `--accept` is scripted consent for a
   coordinator acting after a dry-run, per §4.

## The motion

1. **Read the repo.** Map the layout, stack, build/test commands, and the natural domains (by service, by
   layer, by package). Note the conventions a coordinator would need to respect.

2. **Draft a `CLAUDE.md` for THIS repo.** An orchestrator charter specific to the codebase: how it's
   structured, how to build/test it, how to decompose and dispatch work in it, the conventions to honour.
   Keep it tight. Present it for the human to approve/tighten — don't assume you read the conventions right.
   The charter *wiring* is already delivered by `kickoff adopt` (the `@.kickoff/KICKOFF.md` import block in
   the root `CLAUDE.md` + the generated `.kickoff/KICKOFF.md` charter, both recorded in the adopt manifest) —
   this skill authors the repo-specific **content**: the `CLAUDE.md` body and the `.kickoff/KICKOFF.local.md`
   conventions stub. Do not re-create or duplicate the wiring.

3. **Propose specialist subagents that match its real domains — but only where the crew has a GAP.** Not
   planner/builder/reviewer in the abstract — specialists that fit how the code is actually split (e.g.
   `frontend`, `api`, `migrations`, `tests`, or one per service). Draft the charters; **the human approves**
   before they land in `.claude/agents/`.

   **The ceiling of touch — restraint is the product (G2 #2).** If the repo already carries a GOOD crew
   under `.claude/agents/` that covers its real domains, **propose ZERO new agents** — run THEIRS as-is and
   **mesh only Mission Control** onto them; add nothing else. This is exactly what the
   `kickoff adopt --dry-run` mesh sentence promised the operator ("found your N agents — I run YOURS and
   add specialists only where a domain has no owner; mesh only Mission Control"), so it must be TRUE:
   extend the crew **only** where a domain has no owner, never to impose the abstract
   planner/builder/reviewer shape on a crew that already works. Meshing with a good crew, not fighting it, is the make-or-break promise of adoption.

   **The procedure — DRIVE the restraint tools, don't eyeball coverage (G3b).** On a brownfield repo
   *with* an existing crew, run this concrete loop, not a by-hand judgement (`KICKOFF_CORE_DIR` comes
   from `.kickoff/instance.env`):
   1. **Probe the crew AND its coverage sources.** `python3 "$KICKOFF_CORE_DIR/scripts/crew-probe.py" map
      --repo .` returns the structured crew — each existing agent + what its *frontmatter* says it owns.
      **Consume the JSON**; do NOT re-parse the `.claude/agents/*.md` by hand. Then, **BEFORE you infer
      coverage**, run `python3 "$KICKOFF_CORE_DIR/scripts/crew-probe.py" coverage-sources --repo .` and
      **READ everything it lists** — the root/nested `CLAUDE.md` + `AGENTS.md`, the `.agents/skills`/
      `.claude/skills` dirs, and the charter BODIES (a body can scope a domain IN *or* explicitly OUT).
      `map`'s frontmatter view alone **UNDER-counts** coverage → you would **OVER-propose** (the exact
      failure this restraint exists to prevent). Do NOT judge coverage from `map` frontmatter alone.
   2. **Infer the repo's REAL domains** from ITS code/structure (free-form — read from THEIR repo; never a
      fixed kickoff vocabulary, which would be the "impose our shape" failure).
   3. **Map each domain → its owning agent** (from the crew map), computing the UNCOVERED domains.
   4. **Author a gap-plan** (`{domains, coverage, proposed[], deferred[]}`) and run
      `python3 "$KICKOFF_CORE_DIR/scripts/crew-probe.py" validate-plan --repo . --plan <plan.json>`
      **BEFORE** proposing anything to the operator. `validate-plan` is the restraint gate — a
      fully-covered crew MUST yield an empty `proposed[]` (it exits non-zero on a breach: over-propose for
      an already-owned domain, a name collision, or imposing the planner/builder/reviewer shape). **For an
      uncovered domain you deliberately choose NOT to fill**, record it in the plan's `deferred` array as
      `{ "domain": "<uncovered domain>", "reason": "<why you're declining it>" }` — so the restraint
      decision ("saw it, declined it") is **captured**, not merely spoken. `validate-plan` checks it: you
      can only defer an *uncovered* domain, the reason must be non-empty, and no domain may be in both
      `proposed` and `deferred`. A `coverage` value may be a bare `"agent-name"` (back-compat) **or** the
      layered form `{ "primary": "<name>"|null, "contributors": ["<name>", …] }` when build/review/test all
      touch one domain — a domain is UNCOVERED iff its **primary** is null/absent (contributors alone do NOT
      cover it), and the honesty check verifies the primary *and* every contributor exists. Pass `--json` to
      also get the machine-readable result on stdout (`{ok, exit, breaches:[{rule,message}], uncovered,
      advisory}`) — the exit code is unchanged; the `advisory` breadth summary is informational, never a gate.
      Surface the proposal to the operator; nothing is written without approval.
   5. **For each operator-APPROVED gap**, run
      `python3 "$KICKOFF_CORE_DIR/scripts/adopt-manifest.py" gen-agent --repo . --name <kebab> --domain <d> --source <core-vX>`
      to write the **gap-filler** charter from the template (least-privilege, records it seeded-instance,
      eject-reversible). `gen-agent` **REFUSES to overwrite** an existing charter — never edit an adopter's
      own agent.
   6. Mission Control is meshed by the lifecycle HOOK (next section) — **NEVER a charter edit.**

   **Mesh Mission Control via a lifecycle HOOK, not a charter edit (G2 #3).** The MC reporting each agent
   streams (its function row + the 📡 feed) is wired by a `.claude/settings.json` lifecycle hook — **zero
   agent-file touch**, eject-clean. Do **not** edit an existing agent's charter to bolt MC reporting on; the
   hook meshes MC onto the crew you found without rewriting a single agent file. (New agents you draft from
   the charter template still carry their own "Report to Mission Control" section — that is a new file, not
   an edit to someone's existing work.)

4. **Add the spine.** A `TRACKER.md` (single source of truth) and the memory seed under **`.kickoff/memory/`**
   (durable facts: conventions, gotchas, decisions — the `.md` corpus is a tracked, team-shareable asset;
   derived caches/DBs live in the gitignored `.kickoff/state/`). Additive only, and **every file you author
   here is recorded** (see "The record rule" below).

5. **Install the quality machinery** (`CLAUDE.md` → "The local quality machinery") — **additively**:
   - **Scanners are NOT copied in.** `kickoff adopt` already delivered the recorded engine shims
     **`.kickoff/bin/scan-secrets`** and **`.kickoff/bin/scan-structure`** (they source `.kickoff/instance.env`
     and exec the pinned core's scanners). Never copy `scripts/scan-*.sh` or the kickoff repo's `lefthook.yml`
     into the adopter repo. The `scan`, `review`, and `harden` **skills themselves are delivered by the kickoff
     plugin** (the marketplace-add + install at project scope below) — they are **no longer copied into
     `.claude/skills/`**.
   - **Add the STACK gates to the lefthook wiring `kickoff adopt` already laid down.** The GENERIC gates are
     no longer yours to author: `kickoff adopt` mechanically wrote **`.kickoff/lefthook-kickoff.yml`**
     (pre-commit `secret-scan: bash .kickoff/bin/scan-secrets --staged`, pre-push
     `structure-scan: bash .kickoff/bin/scan-structure`), wired the root `lefthook.yml` `extends` (created
     with a `# kickoff` marker when absent; ONE appended entry recorded seam/byte-restorable when
     pre-existing), recorded both in the manifest, and attempted `lefthook install`. Your session's job:
     1. **ADD the stack gates** (typecheck · lint · test) for the detected stack to the **existing**
        `.kickoff/lefthook-kickoff.yml` (the same per-stack table as the `bootstrap` skill: TS →
        tsc/biome/vitest · Rust → cargo · Python → ruff/pytest · …); keep the existing repo's own gate
        commands if it already has them. The file itself is already recorded created/seeded-instance by
        `kickoff adopt` — record **your edit** per the record rule (save the pre-edit bytes to a tmp FIRST):
        `python3 "$KICKOFF_CORE_DIR/scripts/adopt-manifest.py" record --repo . --path .kickoff/lefthook-kickoff.yml --action modified --class seeded-instance --source authored-for-repo --original-from <tmp>`
        (the layered created+modified pair reverses cleanly — never re-record it *created*).
     2. **Close the one deferral**: if the root `lefthook.yml` already had its OWN `extends:` key,
        `kickoff adopt` warned and left it untouched (a bash tool must not merge YAML). Merge
        `.kickoff/lefthook-kickoff.yml` into that extends list yourself — save the pre-edit bytes to a tmp
        file FIRST, change nothing else, then record it seam so eject byte-restores it:
        `python3 "$KICKOFF_CORE_DIR/scripts/adopt-manifest.py" record --repo . --path lefthook.yml --action modified --class seam --source authored-for-repo --original-from <tmp>`
        Never put `<!-- kickoff:begin -->` markers inside YAML — the strip regex only matches them at raw line
        start; the `#`-prefixed `# kickoff` comment is the marker here.
     3. If `kickoff adopt` warned that lefthook wasn't on PATH, install + activate the hooks
        (`lefthook install`). Name the new dependency; if it can't be installed, fall back to running the
        `.kickoff/bin/scan-*` shims directly and say so. (`kickoff eject` runs `lefthook uninstall` and
        byte-restores/removes the files.) **Do not touch the repo's source or history here** — these are all
        new files + a git-hook install.
   - Invoke the **`plugins` skill** to install the plugins the detected stack/domain needs (DB / mobile /
     deploy / …) — the agent picks by what the repo is; the operator only supplies a secret if one's needed.
   - **`kickoff adopt` also registers + enables the kickoff plugin at PROJECT scope** (a local-path
     marketplace `kickoff-local` → the pinned `~/kickoff-core/plugin`) — which is what now **delivers** the
     coordinator/specialist skills, the crew, the proactive memory hook, and the chrome-devtools MCP, so they
     need not be hand-copied into the repo. It writes exactly two `.claude/settings.json` keys
     (`extraKnownMarketplaces.kickoff-local` + `enabledPlugins."kickoff@kickoff-local"`), recorded **json-merged**
     (byte-restore-reversible), plus a manifest machine entry; `kickoff eject` reverses both. No secret is
     touched and no `settings.local.json` is written — the memory hook is delivered *by* the plugin.
   - **`kickoff adopt` also delivers the reporting canon ("Plain Report" output style)** — it copies
     `.claude/output-styles/plain-report.md` verbatim (recorded **created/seam**) and merges the ONE
     `.claude/settings.json` key that enables it (`outputStyle`). **Disclosed at write time**: the console
     shows `✓ .claude/output-styles/plain-report.md written…` and `✓ .claude/settings.json outputStyle key
     merged…` (or `recorded json-merged…`/`created + recorded…` for a repo the plugin step never touched).
     `kickoff eject` reverses both — the style file is deleted and the settings.json key/file is
     byte-restored to its exact pre-adopt state. An output style reaches the **main conversation only**; the
     subagent half of the same canon travels separately, baked into `.claude/agent-charter-template.md`'s
     CANON block, which every newly-authored specialist charter carries verbatim.

6. **Run an initial `harden` pass — scan now, fix on the branch.** This is how a brownfield repo "follows the
   new directions". Run the `scan` skill (read-only) immediately and report the ranked footgun list. Then,
   honoring adopt's non-destructive contract, the *fixes* don't land autonomously: surface the proposed
   hardening plan and apply the confirmed fixes **on the adopt branch, behind the `review` gate, for the human
   to review and merge** — never rewrite someone's existing source without a go. (A fresh `bootstrap`'d repo,
   being yours, can be hardened autonomously; an adopted one is someone's existing work.)

7. **Prove it, then report.** Run the one-shot health check —
   `bash "$KICKOFF_CORE_DIR/scripts/kickoff" verify --dir .` (`KICKOFF_CORE_DIR` comes from
   `.kickoff/instance.env`) — which checks the seams `kickoff adopt` + this session wired plus a dependency
   report, and **be precise about what its exit code means**:
   - **Hard failures (exit non-zero):** an incoherent `core.lock` · missing/broken `.kickoff/bin` shims ·
     a failed `mc render-tracker` round-trip · a recorded plugin that isn't enabled · missing
     git/jq/python3. Any ✗ must be fixed before you report done.
   - **Loud advisories (⚠ — exit stays 0):** the lefthook gate wiring, the lefthook binary/hooks install,
     node/claude/semantic-memory availability. These do NOT flip the exit — so **read the output, don't
     trust the exit code alone**: a GREEN with ⚠ lines is *conditionally* healthy, and your report must
     name the ⚠s and what closes them.
   - **The escalation:** on an ACTIVE repo (commits after adopt · board activity · a live supervisor)
     whose gates are wholly unwired, `verify` and the supervisor-start preflight print a prominent
     **`ADOPT INCOMPLETE`** banner/warn — still advisory (a bring-up is never blocked), but it means
     commits are landing unscanned: treat it as this session's first job, not a footnote.
   It needs **no Telegram** (run it before the bot is wired). **Report the GREEN — and its ⚠s honestly** —
   this is the brownfield "it worked" proof, the counterpart to greenfield's passing test. Then summarise
   what you added (all additive), the scan findings + proposed hardening, and suggest one small recurring
   task to run through the new setup.

## The record rule (HARD — no unrecorded touches)

**Every file this skill authors or edits is recorded in the adopt manifest.** `KICKOFF_CORE_DIR` comes from
`.kickoff/instance.env` (`source .kickoff/instance.env` first); run the record from the repo root, right
after each touch:

- **A new file you create** (an adopter deliverable):
  `python3 "$KICKOFF_CORE_DIR/scripts/adopt-manifest.py" record --repo . --path <p> --action created --class seeded-instance --source authored-for-repo`
- **An edit to a PRE-EXISTING adopter file**: save the pre-edit bytes to a tmp file FIRST, then
  `python3 "$KICKOFF_CORE_DIR/scripts/adopt-manifest.py" record --repo . --path <p> --action modified --class seeded-instance --source authored-for-repo --original-from <tmp>`

The concrete set a normal adopt session records: `TRACKER.md`, the `.kickoff/memory/` seeds,
`.claude/agents/*.md`, the stack-gate edit to `.kickoff/lefthook-kickoff.yml` (modified/seeded-instance,
step 5.1), and (only in the own-`extends:` deferral case, step 5.2) the root `lefthook.yml` merge —
recorded `--class seam` with `--original-from` so eject byte-restores it. `CLAUDE.md`'s wiring (the import
block, or its creation when absent), the gate file's creation, and the normal root `lefthook.yml` wire are
already recorded by `kickoff adopt` — don't double-record those.

**Why this is a hard rule:** the manifest is what makes `kickoff eject --purge` real (seeded deliverables
are findable and removable) and `eject --verify` honest (recorded, kept deliverables are allowlisted instead
of falsely reading as residue). An unrecorded file is invisible to both — untracked residue the byte-for-byte
eject proof can't account for.

## Boundaries (important — this touches someone's existing work)

- **Additive only.** Author `CLAUDE.md` content + `.kickoff/KICKOFF.local.md`, create `.claude/agents/*`,
  `TRACKER.md`, `.kickoff/memory/`, add the stack gates to the existing `.kickoff/lefthook-kickoff.yml`,
  and install the git hooks — new files plus a `.git/hooks` install, each new file **recorded** per the
  record rule.
  The scanners are the `.kickoff/bin/scan-*` shims `kickoff adopt` delivered; the `scan`/`review`/`harden`
  skills are **delivered by the kickoff plugin** — neither is copied in. Do **not** modify the repo's
  existing source, build config, or history.
- **Hardening fixes land on a branch.** The initial `harden` pass *scans* read-only and *reports*; any actual
  fix to existing source goes on the adopt branch, behind the `review` gate, for the human to merge — not autonomously.
- **Human approves the charters.** You draft; the human confirms the conventions are right before relying on them.
- **Never touch a repo you weren't pointed at.** And if it's someone else's repo, get explicit go first; prefer
  running on a **copy** to prove it non-destructively.
- Same trust boundary as everything else: build/test/commit/push reversible and autonomous; **spend, secrets,
  and destructive ops** human-approved (`CLAUDE.md`).

## Honest-stage

You're inferring conventions from code — you'll get some wrong. Say what you assumed, flag what you're unsure
of, and let the human correct the drafted `CLAUDE.md` before the crew leans on it. A tight, *accurate* charter
is what makes the coordinator effective on an existing codebase.
