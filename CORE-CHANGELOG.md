# CORE-CHANGELOG

The **stability contract** between the kickoff *core* and its *adopters* is two things: the
`instance.env` variable **names** (see `scripts/instance.env.example`) and the
`scripts/core-manifest.txt` **file set**. An adopter pins a core version (a `core-v*` git tag) and
runs `kickoff pull` to update — the core flows in **once**, no hand-patched copy is ever born. This
log records what changed per core version (reverse-chronological); read it before you `kickoff pull`
a newer tag.

## core-v0.42 — unreleased

**Engine parity becomes REAL for adopters: the opencode seam set travels, the pull back-fills the
installed base, and every delivery is now verified from the consumer's own disk.** Plus the brick
fix that gated it. What an adopter gets on `kickoff pull`:

- **The opencode engine-parity set ships to adopters** (the release's point): `.opencode/agent/`
  crew charters — **model-pin-stripped** (a pinned model wedges sessions silently on boxes without
  that provider; the origin keeps its own pins) — both `.opencode/plugins/`, a pin-free
  `opencode.json` (`default_agent: coordinator`), and the `AGENTS.md` pointer. Adopt delivers +
  records it (eject-reversible, never-clobbers adopter-owned files, idempotent); **`kickoff pull`
  BACK-FILLS it for every existing adopter** — sync-seams can update a recorded seam but never
  introduce one, so without the back-fill this release's whole point reached new adopters only
  (the v0.35 join-time-only lesson, now closed on the pull path); `kickoff doctor` can repair it.
  Gated on the PIN carrying the set — a pull to an older/opencode-less tag skips honestly.
- **BRICK FIX — adopt's opencode gate is pin-rooted** (the running-engine gate recorded seams the
  pinned core never had; the next `kickoff pull` then FATALed in sync-seams resolving templates
  the pin doesn't carry). Every pull-relevant consumer resolves recorded seams against the PIN;
  the gate now reads the same root the plugin arm reads. Pinned RED-first by adopt-selftest §12(g).
- **The consumer-side VERIFY line** (the operator's original complaint): adopt + pull summaries
  now READ the delivered set back off the ADOPTER'S OWN DISK — `opencode.json` parses with
  `default_agent=coordinator`, NO model/provider key anywhere (the model-pin discipline), 5 crew
  charters non-empty, both plugins, the `AGENTS.md` pointer resolves — and print one honest scope
  line: *"verified files, not a live session."* A broken check is NAMED loudly; it is a diagnostic,
  never a gate (rc unchanged); it names keys, never values; it never touches the files. RED-first
  in adopt §21 + pull §17, including the kept-not-ours world (an adopter's own broken pre-existing
  files are named, not "verified" over).
- **FROZEN CONTRACT re-bless** (`XV_BLESSED` 05085ef8→00e15b9d): the gen-opencode surface delta —
  7 additive closure members, 2 pure insertions, zero dispatch/arg-surface drift — reviewed twice
  independently (identical verdict). Safe for v0.6-era adopters: the new branches are unreachable
  for any pre-v0.42 manifest (every pull-relevant walk is manifest-driven). Full reasoning in the
  re-bless ledger (pull-selftest).
- **Lane visibility + liveness**: `/lanes` + the live board (SSE, :9700) show every lane's true
  state; dispatch SELF-STARTS its runner (the twice-forgotten consumer step); terminal verdicts
  desktop-notify. Engine-tagged PARITY gaps documented in `docs/PARITY.md` (drift is recorded,
  never silent). The two META skills (`release-notes`, `clear-report`) ship via the plugin —
  0.3.27→**0.3.28** (content change ⇒ bump; the claims-lint line now teaches the adopter-native
  path, origin-only-path-gated).

### Also riding this cut (2026-08-26/27, second-box + memory machinery)

**A second machine cloning the engine-source repo got dead memory machinery — the source-checkout
mode existed but nothing wired it.** A fresh clone of this repo (no `kickoff init` ever run) had
interactive sessions with no `KICKOFF_CORE_DIR`, no retrieval index ever built, an env-less indexer
that died as a bare ENOENT (the `DEFAULT_MEMORY_DIR` fallback matched *no* real layout), and a
`crew-review-due.sh` that fail-closed with no escape hatch named. Fixes:

- **`memory-retrieval/lib/memory.mjs` — the env-less corpus default now probes the two REAL
  layouts** (`$REPO_DIR/memory` → `$REPO_DIR/.kickoff/memory` → the engine-source sibling
  `<tool-root>/../memory`) and, when nothing exists, fails naming the fix ("memory corpus not
  found at `<path>` — set MEMORY_DIR, see RUNNING.md") instead of a raw scandir ENOENT. Explicit
  `MEMORY_DIR` still wins verbatim — adopter paths byte-identical.
- **`.opencode/plugins/memory-search.js` — repo-local engine fallback**: an engine-source repo
  runs its own `memory-retrieval/` (no pinned core, no `KICKOFF_CORE_DIR` in interactive
  sessions), and an unset `MEMORY_DB` is no longer an error — the child gets `REPO_DIR=<project>`
  so the engine anchors its own default db. Missing-engine and missing-db now report as distinct
  honest errors.
- **`memory-retrieval/hook.mjs` — the silent no-index branch says one stderr line** naming the
  missing db + the one-command index build (fail-open preserved exactly: still returns, still
  exit 0 — a UserPromptSubmit hook never blocks a turn).
- **`scripts/crew-review-due.sh` — the not-an-instance refusal names its escape hatches**
  (`kickoff init` in source-checkout mode, or `KICKOFF_DIR`/`CREW_REVIEW_MARKER`); message-only,
  gate logic and exit codes unchanged.
- **`scripts/memory-orphan-check.sh` — an engine-source index repo skips the sibling scan**: the
  operator's other projects adopt on their own schedule (and self-skip once adopted), so flagging
  them "invisible" is noise that trains readers to ignore real orphans. One notice line, exit 0.
- **`release-gate.sh` — an ambient identity pattern no longer HARD-blocks on a word it did not
  cause.** The leak scan derives patterns from the running box's username and hostname. A second
  machine named `alarm` — an English word carried as prose in 19 files of `core-v0.8.1` — therefore
  read every clean tree as a machine-name leak, reddening `(b)`, `(g6)` and the `(l1)`/`(l2)` lanes
  that parse `(b)`'s summary, and blocking **every push from that machine** (the suite is a
  registered pre-push gate). The discriminator is INTRODUCTION, not presence: an ambient pattern
  that also matches `--prev` was not introduced by this candidate and is now an ADVISORY naming the
  collision; one the candidate introduces still hard-blocks, and an operator-authored denylist term
  always does. With no `--prev` the old HARD behaviour stands. `release-gate-selftest.sh` 72
  assertions (was 67), lane `(g12)` including the negative control.
- **`memory-defaults-selftest.sh` lane f is corpus-portable.** It asserted "the hook's own default
  floors do not rescue a stub index" — true of this box's 245-fact corpus (best bm25 -4.48), false
  on a smaller one, so it went red on a healthy tree elsewhere. It now reads the corpus's own best
  score from the suppression reason and requires silence at a STRICTER floor: deterministic
  anywhere, same invariant. The shipped-floor half is reported, not asserted.
- **`bringup-source-instance.sh` — `.kickoff/local-only` silences the Telegram offer.** A
  deliberately local-only instance was re-offered the channel setup on every run. The marker is
  instance-local, changes no behaviour, and the un-marked footer now names it.
- **`scripts/context-headroom.py` grows an OPENCODE arm — the refresh loop had no sensor on the
  second engine.** The gauge resolved `~/.claude/projects/<repo>/*.jsonl`, which opencode never
  writes, so on an all-opencode box it printed "no live worker transcripts found" and the
  measure→`refresh-requested`→supervisor-cycle loop silently did not exist (felt as "claude
  restarted itself at critical mass; opencode gets stuck"). The arm reads the org's local serve —
  `/session`, `/session/<id>/message`, `/config/providers` — and takes the fill as the LAST
  assistant turn's `input + cache.read` against that model's real `limit.context` (never the
  session-level roll-up, which is cumulative). It emits **one row per engine** rather than
  preferring the transcript: after a hop the surviving `.jsonl` is a different session, and
  preferring it mis-reported 7 of 8 orgs here — those rows are now flagged NOT this repo's worker.
  Honest gaps are marked, not faked: no delegation count, and no compaction record (only the fall
  detector can fire). `OPENCODE_BASES` is the test/override seam. `context-headroom-selftest.sh`
  58 assertions (was 54), including the load-bearing negative control — same turns, doubled window,
  the percentage must halve — proven RED by breaking the window read.
- **NEW `scripts/memory-search-probe.sh` — acceptance proof P1 becomes runnable.** P1 ("a fresh
  opencode session's `memory_search` returns real hits") had no harness; it needed a human in a
  live session. That is the wrong place for a proof: the second box (2026-08-27) could not walk it
  because headless `opencode run` was server-erroring for reasons unrelated to memory. The probe
  drives the plugin's real `execute()` — same `CORE_RETRIEVE` resolution, same child spawn — with
  `KICKOFF_CORE_DIR` and `MEMORY_DB` deliberately **unset**, because an unset `KICKOFF_CORE_DIR` is
  the interactive shape under test (nothing sets it for an interactive session on any box, by
  design). GREEN reports the resolved `semantic=` flag and warns when it is false; FAILED prints the
  real engine error; SKIPPED (exit 0) when `.opencode/node_modules` is absent. Proven green, red and
  skip.
- **`bringup-source-instance.sh` step (b2) knows what a pre-release node does to a native build**
  (reported by the second box, 2026-08-27): `@xenova/transformers` hard-depends on `sharp` (a
  regular dependency — not skippable), which falls back to a `node-gyp` build when no prebuilt
  binary matches; a **pre-release** node has no published headers, so that build 404s and the
  install dies. (b2) now detects a pre-release `process.version` up front, and on failure names
  the real remedy — one install under a stable node (`mise exec node@22 -- node
  memory-retrieval/install-model.mjs`) — instead of guessing "offline?". The alpha breaks only the
  BUILD: N-API addons load fine under it, so no repo pin and no change to the box default.
- **NEW `scripts/newbox-from-main.sh`** — the step *before* bring-up for a clone of public `main`.
  `main` and the dev trunk are unrelated histories, and up to three tracked-on-`main` paths are
  gitignored on dev — `memory/MEMORY.md` (the always-loaded roll-up; preflight #3 fail-closes
  without it), `mission-control/mission-state.json`, and on older release lineages `TRACKER.md`
  (main@17c91ac no longer tracks it) — so a bare
  `git checkout <dev>` deletes them with no warning. The turnkey saves them across the switch,
  restores `MEMORY.md` from `origin/main` (its authoritative hand-curated copy), refuses a dirty
  tree, is idempotent, and then `exec`s the bring-up. It resolves the repo from the caller's git
  toplevel, not `$0`, because the documented one-liner runs it out of `/tmp`.
- **`scripts/bringup-source-instance.sh` verifies the REAL consumer, and ensures the embedder**
  (2026-08-27, found by walking a fresh clone): the turnkey checked consumed state with
  `retrieve.mjs`, which answers fine on a `hashing-stub` index — but a session recalls through
  the UserPromptSubmit *hook*, whose strength gate needs a strong keyword arm OR a strong vector
  arm. A stub index has no usable vector arm (`meta.semantic=false` ⇒ `vcos=n/a`), and the best
  keyword score on this corpus clears neither `.claude/settings.json`'s floors (-8.0/0.23) nor
  the hook's own defaults (-5.0/0.3). Net: bring-up printed **DONE** on a clone whose recall was
  **dead in every session**. A fresh clone hits this by default — `memory-retrieval/node_modules`
  is gitignored, so `@xenova/transformers` is absent and the indexer silently picks the stub.
  New step **(b2)** runs `install-model.mjs --if-needed` before indexing; step **(d)** now
  extracts the memory hook command from `.claude/settings.json` and runs it **verbatim**,
  failing with the named one-command fix if a real turn surfaces nothing.
  Pinned by `scripts/memory-defaults-selftest.sh` lane **f** (22 assertions, was 16): stub index
  → `retrieve.mjs` answers, hook is silent at both floor settings; semantic index → surfaces
  (positive control, absence-skipped when no semantic db is on disk).
- **NEW `scripts/bringup-source-instance.sh`** — the one-command turnkey for this mode: `kickoff
  init` (absent-only) → idempotent source-mode `instance.env` patch (hand-set values left alone)
  → from-scratch index build (a manually-built db is moved aside as untrusted) → verification by
  *consumed state* (a real retrieval must answer; `crew-review-due` must give a sane verdict) →
  the printed P1–P4 acceptance proofs. Documented in RUNNING.md's *"engine-development mode"*
  section, cross-linked from QUICKSTART.

## core-v0.38 — 2026-08-22
**A second engine, under the same supervision.** Until now `claude --channels` was hard-wired into
the last line of `session-run.sh` — the harness that made an org persistent was also the thing that
made it single-engine, so one expired shared login could silence every org on a box at once while
every liveness check stayed green. This release cuts that coupling at exactly one point: the final
exec.

- **`WORKER_ENGINE` — a new instance.env name, closed set `{claude|opencode}`, validated fail-loud
  before anything spawns.** Unset means `claude`, which is byte-for-byte every session this wrapper
  has ever started; the preset-wins precedence rule is unchanged and proven by a new selftest
  (`worker-engine-selftest.sh`, 24 lanes, RED-on-old enforced — test suites never travel, but the
  discipline does).
- **The opencode path runs TWO processes in ONE supervision group**: a headless `opencode serve`
  holding the sessions, plus the grinev `opencode-telegram` bot driving them over the local server
  API. The bot is exec'd PID-preserving, so `kill -- -PGID` reaps both — the kill-safety contract
  is inherited, not re-invented. Credentials are read from the SAME pair the claude bridge reads
  (`.claude/settings.local.json` `.env` token, `$TELEGRAM_STATE_DIR/access.json` allowlist); the
  token rides env, never argv.
- **Per-org state isolation** (`OPENCODE_TELEGRAM_HOME` under `.kickoff/opencode-bridge-home/`),
  because two workers sharing one bot-state dir answered each other's operators — bit live within
  hours of the first deployment, when a "hi" landed in another org's thread.
- **Model pins travel like MODEL/EFFORT**: `OPENCODE_MODEL_PROVIDER` / `OPENCODE_MODEL_ID` are
  whitelisted instance.env names with the same argv > pre-set > file > default precedence.
- **Charter parity is now a stated principle** (CLAUDE.md): a capability that exists on one engine
  only is a fork, not a feature.

## core-v0.37 — 2026-08-18

**The charter has always told a session to measure its own degradation and hand off past ~80%.
Nothing made it look.** `scripts/context-headroom.py` ships and works; running it was an
instruction competing with a growing context, which `beat-length-guard.py`'s own docstring already
records as a losing arrangement — a rule in CLAUDE.md, in memory, *and* re-injected every turn by
the recall hook, still failing. Measured on the live fleet on 2026-08-17: one worker sat at **79%
over 423 turns** and never set the refresh flag; another had **already auto-compacted** at 968.

Self-noticing is unreliable **by construction** — a session re-deriving settled facts is, by
definition, not at its sharpest for noticing that it is — and autocompaction resets the gauge, so
from the inside "lean" and "compacted" are indistinguishable. A hook does not have that problem.

- **`plugin/hooks/context-handoff-nudge.py` — the handoff trigger, on `UserPromptSubmit`.** Reads
  this session's own transcript and injects one line naming the real percentage: silent under a
  floor (nearly every turn of a healthy session), a soft "checkpoint at the next boundary" past it,
  and near the ceiling an explicit stop that **names the handoff steps in order** — commit, write
  the durable learning to `memory/`, update the tracker so the next session can resume the WIP from
  it, *then* `touch .kickoff/refresh-requested`. The order is load-bearing: a refresh discards
  uncommitted work. **It never sets that flag itself** — only the agent knows whether it has
  checkpointed, so acting on its behalf could destroy the very work the handoff exists to preserve.
- **It tails rather than parses.** Occupancy is the newest turn's number, it runs every turn, and a
  live transcript on this box reaches 6MB. It also **borrows session identity from `beat-nudge.py`**
  rather than writing a third copy of a problem already got wrong twice there (newest-mtime picked
  a *sibling* session's file; keying on the payload's live `cwd` resolved nothing after one `cd`).
- **Fail-silent, like its siblings — and the suite is shaped around that cost.** A broken hook and
  a healthy quiet one produce byte-identical output, so the lanes are mostly *positive*: a fixture
  at high fill MUST nudge. Plus band-boundary lanes, per-session **and per-band** dedupe (a soft
  nudge must not spend the act warning), and a negative control proving an always-silent stub fails
  them. 20 lanes, 0 failed.
- **`AUTO_PICKUP` is a real per-adopter setting now.** Resume-the-WIP had no flag, was read from no
  file, and survived no upgrade — so it was live on exactly **one** org on this box, set by hand in
  July, while the rest would reboot and resume nothing. It is on the same footing as `MODEL`:
  whitelisted for `instance.env`, a `--auto-pickup` / `--no-auto-pickup` flag on `kickoff up`, and
  carried into the worker env. Because `instance.env` loads before `cmd_up`, it survives every hop
  with no turnkey change. Every engine-side guard is unchanged, including the crash-loop
  self-disable in `session-run.sh`.
- **A dead wire found one line away: `CADENCE` was whitelisted for `instance.env` and consumed
  nowhere.** `cmd_up` defaulted it to empty instead of reading it, so an adopter could set it and
  get silence — the same disease as the `AUTO_PICKUP` gap, sitting next to it. Now wired to its own
  variable. Still off by default; this is the removal of a trap, not a cadence policy.
- Suite `config-precedence-selftest.sh` 22 → 25 lanes, RED-first verified by reverting the change.
  Plugin `0.3.25 → 0.3.26`.

## core-v0.36 — 2026-08-17

**Every rule in the reporting canon capped a *part*. None capped the whole message — so a reply
could obey all of them and still be too long to read on a phone.** The operator reported exactly
that after a full session of them, and both levers turned out to be behaving precisely as written:
the style bounded sentences (20/25 words), paragraphs (6 sentences) and option lists (2), while the
`beat-length-guard` hook blocked at 20 lines. Every reply in that session landed between 8 and 19
lines. The band neither lever reached was where all the verbosity lived.

- **The style now carries a whole-message budget** — 6 lines by default, **12 as a hard ceiling**.
  It counts *lines that carry text*, which is what the guard actually measures: the guard skips
  blank lines on purpose (spacing is what makes a beat readable), so a style that counted them
  would describe a different instrument than the one enforcing it.
- **`beat-length-guard` ceiling 20 → 12 lines, 2000 → 1200 chars.** The soft nudge stays at 7.
  A cap set where *runaway* begins does not bound *verbose*; this is the backstop, and the style's
  budget is the generation-time half that does the real work.
- **The ceiling is now pinned by a test, which it never was.** The only hard-tier payload was 25
  lines — far past any plausible cap — so the suite stayed green across 20 → 12 and would have
  stayed green at 40. Two boundary lanes assert where the number actually is: 12 sends, 13 does
  not. Verified by negative control: raising the cap back to 20 turns the 13-line lane red.
- **The drift this canon warns about caught the change that wrote it.** Re-running
  `wire-canon-into-charters.sh` added nothing, because the charter block is hardcoded in that
  script and kept in step with the style *by hand*. The rule now lives in both, scoped differently
  for each: a subagent gets *"budget the whole report, push evidence into files"* and **not** the
  12-line channel ceiling, because a subagent's report is data for the coordinator, not a phone
  message. If you edit one of those two files, edit the other.
- Suite `beat-length-guard-selftest.sh` 28 → 30 lanes, 0 failed. Plugin `0.3.24 → 0.3.25`.

## core-v0.35 — 2026-08-17

**`kickoff pull` can update a seam. It structurally cannot introduce one — and nobody had noticed,
because the upgrade reports green either way.** `sync-seams` walks the **adopter's recorded entries**
and regenerates each from the core's template. A repo that joined before a seam existed records
nothing for it, so the walk visits nothing and that seam is invisible to every future pull. Delivery
of anything new is join-time only.

This was measured, not reasoned. Six orgs hopped to `core-v0.34` on six conjunctive-green verdicts —
pull rc 0, `core.lock` advanced, the old supervisor stopped on a `/proc`-verified pid, the new
supervisor alive for 90s on the new engine, model policy preserved — and **not one of them received
the output style that release existed for.** The hop's verdict measures the pull, the lock, the pid
and the policy: everything except whether the adopter now *has* the thing. One `grep` for the
settings key across six repos was the entire check that caught it.

- **`kickoff doctor` now back-fills the reporting canon.** Doctor is the right owner because that is
  already its stated contract — *"adds ONLY what's missing, records what it creates"*. Run it after a
  pull and an existing adopter gets `.claude/output-styles/plain-report.md` plus the `outputStyle`
  key, both manifest-recorded, so `kickoff eject` reverses them and preflight #8 hashes them like any
  other seam. **This is the first such back-fill; every future adopter-facing seam belongs here too**,
  or it ships to new adopters only and silently skips the installed base.
- **It delegates to the same code `adopt` uses, never a re-implementation.** So the never-clobber
  guard is inherited rather than re-derived: if you already own a file at that path, doctor leaves it
  byte-for-byte alone, records nothing, does **not** set the settings key, and reports it as *not
  wired* — never as "already wired", which is the one outcome where we deliberately wrote nothing.
  The report keys on the manifest **record**, not on file presence, because presence alone cannot
  tell those two apart.
- **The doctor fixture core now carries the style at its root**, where `_read_core_root_file` reads
  it. Omitting it would have made every style step a silent no-op and the new lanes green against a
  world where the feature cannot exist — which is exactly how `core-v0.33`'s pull fixture went 237/18.
- Suite `doctor-selftest.sh` 36 → 49 lanes, 0 failed, RED-first verified by reverting the change and
  re-running: seven lanes fail without it.

## core-v0.34 — 2026-08-17

*(There is no public `core-v0.33`. That tag was cut on the development lineage as an on-box engine pin and never published; re-pointing it would have broken the whole-tree core pin of an instance already running on it. The version is skipped rather than reused.)*

**An output style reaches the main conversation and nothing else — so the same rules had to be put
where a style cannot go.** This repo delegates nearly all real work to specialist subagents, and a
subagent runs its own system prompt. A reporting style installed alone therefore buys a
plain-speaking coordinator that relays verbose specialists, which is most of the words the operator
actually reads. The release ships the style *and* the mechanism that carries it past the boundary.

- **`.claude/output-styles/plain-report.md` — the Plain Report reporting canon.** Answer first, small
  words, short sentences, two options at most with a recommendation. It binds the text a reader meets
  first (the reply, a turnkey's output, a tracker item, a commit subject) and deliberately does **not**
  bind analysis — the mechanics come from a procedural-language spec, and an argument written under one
  loses the caveats that make it honest. Uncertainty is stated, never stacked: "I did not test this" is
  in-style; three hedging modals are not.
- **`scripts/wire-canon-into-charters.sh` — the same rules appended to every agent charter.** This is
  the part that matters. Change the style file and re-run the script, or the two drift apart.
- **`kickoff adopt` now delivers both to an adopted repo, and `kickoff eject` reverses both.** It is
  the first seam kickoff writes inside the adopter's own `.claude/` namespace — every earlier seam
  lives under `.kickoff/`, where pre-existence cannot happen, so no guard for it existed. **An adopter
  who already owns that path is now left alone:** the generator refuses with a distinct exit code
  (rc 3, a code and not a string to grep, so rewording cannot silently restore a false report), and the
  caller — which had been discarding the generator's result and printing "written" unconditionally —
  branches on it, discloses the truth, and does not claim the settings key either. Before this fix the
  path overwrote their file, recorded it as created with no original bytes, printed a green tick, and
  eject then deleted their file and left their tree dirty.
- **`adopt-manifest.py sync-seams` is now all-or-nothing.** It used to write each regenerated seam
  immediately and save the manifest only at the end, so a failure mid-walk left an adopter with a
  rewritten file and a stale recorded hash — the `file == record` invariant broken by the very command
  that maintains it. Found while fixing a pull regression, not while looking for it.
- **The leak guard had a name for the machine and no pattern for it.** Every identity pattern in the
  release gate was anchored on the literal `home`, so it could only see a machine through a home
  *path*. A hostname bare in prose, inside a MagicDNS URL, or after an `@` walked through a `[PASS]`
  that said "clean". It now derives the machine name at run time and matches it whole-token — a guard
  that cries wolf is a guard that gets bypassed, so over-tightening is a real failure here and not a
  safe one. When no usable machine name exists the result line says the axis is **not covered**,
  in the same sentence that would otherwise have claimed it.

## core-v0.32 — 2026-08-13

**A boot check that could only afford to look back two days, and a selftest that wrote to the repo
it was guarding.** Both are the same shape: a check whose stated contract was narrower or more
generous than what it actually did, and nothing testing the difference.

- **`scripts/orphaned-work.py` — the boot check now REMEMBERS what it showed you, so its window
  opens from 2 days to 14.** Two days was never a considered horizon; it was the widest window that
  did not re-print the same finding at every single boot, because the check had no memory. That
  narrowness *is* the bug: on this box, **168,000 characters of returned agent output sat unread in
  one org for twelve days** while its boot check ran clean every morning — the runs had simply aged
  out of the window between restarts. A per-repo ledger (`.kickoff/orphan-notified.json`) makes
  notify-once possible, and notify-once is what pays for the wider window.
  Nothing is ever silently dropped, which is the hazard a naive notify-once introduces — a session
  can die between the print and the acting on it. So a finding already shown **collapses to a
  one-line tail** rather than vanishing; `--dump` retires it; `--replay` shows everything again and
  records nothing; and a run where *every* agent was killed is shown once and then dropped from the
  tail, because `--dump` refuses it by design and carrying it would be a nag that can never be
  closed. The ledger **fails open** by construction: an unreadable one re-reports rather than
  hiding, and one it cannot write warns on stderr without failing the check. Noise is recoverable;
  a swallowed finding is not. Also adds `--json`, with the tier split moved into one `select()` so
  the human render and the machine output cannot drift — the render is byte-identical to v0.31's.
- **`scripts/hop-selftest.sh` — lane h6c was RED on a pre-push gate, for behaviour the engine was
  getting right.** The lane asserted that the dogfood origin has no `core.lock` and must resolve to
  no hop target. That premise died the day this repo became a **pinned adopter of its own engine**:
  a target now resolves correctly and the lane failed every run. Release pushes kept passing only
  because they run from a fresh worktree that has no `.kickoff/` at all, so nothing surfaced it.
  The unpinned-shape properties were never this lane's to carry — **h6a** (no `core.lock` → inert)
  and **h6b** (self-referential pin → no target) already prove them on fixtures — so the lane now
  asserts what only it can see and what is actually true: whatever resolves, **no exec is
  attempted**, because a live supervisor holds the lock and the boundary refuses.
  Found while fixing it: the lane's own comment claimed *"we only READ the live `.kickoff` — never
  write, never signal"*, and that was **false**. On a blocked hop the unit writes
  `> "$KICKOFF_DIR/hop-blocked"` (`supervisor.sh:1196`) and the lane pointed `KICKOFF_DIR` straight
  at the live directory, so **every run of the suite dropped a real hop-blocked flag into the live
  org** — a flag the unit reads back to decide whether to re-alert. Nothing tested the claim, which
  is why it survived. `KICKOFF_DIR` is now a copy, and a new lane proves the flag is unchanged by
  the run rather than asserting it. The fixture scrub also unsets `GIT_DIR`/`GIT_WORK_TREE`/
  `GIT_INDEX_FILE`: `git -C <fixture>` is not containment, and a suite this fixture-heavy is exactly
  where an ambient `GIT_DIR` would redirect a fixture commit into the caller's repo.
  **The first version of this fix reintroduced the same defect mirrored, and the release gate caught
  it.** Where the old lane hardcoded *"the origin has no `core.lock`"*, the replacement hardcoded
  *"the origin IS pinned and has a live supervisor"* — and asserted an alert and a flag write that
  only occur when a target actually resolves. The gate runs the suites in a **fresh worktree with no
  `.kickoff` at all**, so nothing resolved and three lanes went red on a candidate that was green in
  the dev checkout. Same disease, opposite costume: a lane encoding one deployment's shape and
  calling it the engine's behaviour. The lane now asserts the invariant **unconditionally** (no exec
  attempted; the live flag unchanged) and branches the shape-specific assertions on what the run
  *actually did* — whether a target resolved — rather than on any belief about the checkout. Both
  topologies are now covered and green: **61 lanes pinned, 60 unpinned**.
- **`scripts/orphaned-work-sweep.py` (new, manual) — box-wide detection for orgs that do not
  restart.** The boot check is `--here`-scoped, so an idle org never looks. This splits findings by
  owner and mails each org its own through the agent inbox — no org reading into another's repo. It
  is **deliberately not wired to a cadence**: it messages other orgs unprompted, which is an
  operator's decision, not a default. Only the died-mid-run tier is ever mailed (a run where every
  agent returned is a candidate, not a finding); each run is notified once; it never mails itself;
  and a failed send is not recorded as notified, so the next sweep retries it.

- **`scripts/templates/kickoff.gitignore` — eight runtime files were one `git add -A` from an
  adopter's origin, two of them credential-bearing.** The adversarial pass on this candidate found
  that the ledger this release introduces, `.kickoff/orphan-notified.json`, was not in the adopter
  template — so the first `git add -A` after pulling v0.32 would have **committed it**. The
  template's own comment already describes this exact hazard for `memory/private/`.
  It is a **class, not an instance**. The same hermetic repro (a fresh repo with the shipped
  template stages the ledger while correctly ignoring `core.lock`) shows `auth.env`, `secret.env`,
  `auth-heal.state`, `auth-escalated`, `bridge-escalated`, `hop-blocked` and `refresh-requested` all
  stageable — every one a verified engine write, and **`auth.env` and `secret.env` carry a live
  OAuth token and a bot token** (both written `0600`), so committing either publishes a credential.
  Those older ones ride this release rather than the next because **a `.gitignore` line added later
  cannot untrack a file that has already been committed** — the harm is sticky in a way the fix is
  not. Adopters whose seam is unmodified regenerate it on the same `pull`.
  The guard that should have caught this tested **five hardcoded names**, so it could not report on
  what it did not name — it reported on its own bookkeeping. It now covers all thirteen, watched RED
  first (8 failures on the old template, 19/0 with the fix), with a note to derive the list from the
  engine's writes rather than restate it.

**On the suites.** `orphaned-work-selftest.sh` 25 → 36 lanes, `hop-selftest.sh` 56 → 61, plus a new
19-lane `orphan-sweep-selftest.sh` registered in `lefthook.yml` — which is the only place
`release-gate.sh` discovers suites, so an unregistered one rots red while the gate reports green.
Every new lane was watched RED first. **One mutant initially survived, and it is the most useful
thing in this release:** the `--replay` lane compared the md5 of a ledger whose only varying field
is a second-granularity timestamp, and the suite performs both writes inside the same second — so
the file was byte-identical and the lane was **satisfied by the defect it existed to catch**. It now
asserts the ledger file is never created at all, which no clock can flatter. Two earlier mutant runs
also proved nothing for a different reason: run from a scratch directory, the copied selftest
re-resolved `LIVE_REPO` to its *own* parent via `$0` and wrote its simulated bug where nothing was
watching. A negative control has to prove it loaded the artifact before its green means anything.

## core-v0.31 — 2026-08-12

**A HOLD verdict shipped because nobody checked whether the reviewer had come back.** v0.30 was
tagged with two adversarial lenses dispatched and **zero verdicts collected** — one returned a HOLD
that went unread when the session that dispatched it died, the other was killed having written
nothing. A dead reviewer and a clean one produce the same observable: silence, which was scored as
consent. Every finding in that unread verdict reproduced against the published tag. This release
closes them, plus three more from finally running the lens the killed one never ran.

**Corrections to the v0.30 entry above, stated rather than quietly edited** — the release whose own
thesis is *a wrong number becomes a wrong rule later* shipped three claims that are not true of its
tree. (1) It says `beat-nudge-selftest.sh` **(35 lanes)**; the suite prints **37**. (2) Its commit
message says **44 new selftest lanes**; the real total is **46**. (3) It advertises *"six false-green
negative controls"* in `pin-verify-selftest.sh` as present-tense evidence — those six lanes are
**announced as SKIPPED on any tree that already carries the fix**, which is every tree from that tag
onward, so the suite an adopter is being asked to trust has **no live negative control at all**. The
suite is honest and skips loudly; the changelog was not.

- **`scripts/context-headroom.py` — the gauge counted things that were not compactions.** Claude
  Code writes assistant records with `model: "<synthetic>"` and an **all-zero usage block** for
  rate-limit and API-error notices. Nothing filtered them, so a fall to zero crossed the reset
  threshold: **12 sessions on a 7-org box carried a false "⚠ COMPACTED" flag with zero
  `isCompactSummary` records**, two more were over-counted, and the recovery back to real fill was
  counted as growth — inflating the new per-turn cost number **up to 18x**. A session whose last
  record was such a notice printed **0k / 0% / an empty headroom bar**: the strongest "safe to keep
  going" signal the tool can emit, on sessions that had peaked at 421k. False flags now **12 → 0**,
  with every genuine compaction still detected at exactly the right count.
- **The second detector was structurally dead on every window under ~500k.** `RESET_DROP` was a flat
  `100_000` — 10% of a 1M window, which ordinary churn crosses routinely (a real 94%-full session
  printed `← refresh zone` and a false COMPACTED side by side). Measured across ~2,400 transcripts,
  genuine compactions fall **920,240–946,993** and the largest ordinary fall is **103,424**; nothing
  sits between. It is now `max(150_000, peak // 2)` — scaled off the session's own peak, because a
  compaction empties a window that was full (all 8 real ones peaked at 99.2%+), floored so
  peak-scaling cannot re-derive the old bug. The residual limit is **stated in the render**, not
  silent: rows where that detector could not fire are marked, so a small-window worker can no longer
  read as "plenty of headroom" for want of a signal.
- **`growth` divided n-1 deltas by n turns**, reporting short sessions as systematically cheaper —
  always in the flattering direction, the same bias as the denominator error the field exists to
  correct. It now divides by the deltas and reports nothing under 3 turns rather than a confident
  number from a meaningless sample.
- **`plugin/hooks/beat-nudge.py` — the dedupe inverted into its own failure mode.** The
  "only once per new measurement" marker was **one file per repo** with the session id in the file's
  *value*, written last-writer-wins. Two sessions in one repo therefore de-duplicated *nothing*: each
  overwrote the other's key and **both nudged on every single turn**, injecting context and a
  user-visible warning each time — exactly the "trains its reader to ignore it" outcome the hook
  exists to avoid. The session id now lives in the **filename**, sanitised and length-capped. Also:
  the "no transcript" diagnostic was written on a session's first turn and **never cleared**, so a
  working hook left a permanent flag reading as broken.

**On the suites, because this release is mostly about evidence.** 9 → 54 lanes on the gauge (27 at
the mid-release cut) and 37 → 55 on the nudge, every new lane watched RED first. Three adversarial passes ran and **each found
something the previous missed — twice a regression introduced by the fix itself**. Raising the
threshold silently disarmed an existing fixture, so a mutant that **doubles every real compaction
count** passed a green 27-lane suite; the re-cut that fixed *that* removed the only fixture where the
primary detector was the sole signal, so the primary could be deleted while two lanes named
"compaction is detected" stayed green. Nothing was deleted and no lane was edited in either case —
a changed constant simply stopped a lane exercising the branch it was named for. Both are now
covered from both sides, and the suite carries a committed mutant asserting its own fixture still
trips both detectors.

**Known and NOT closed here, stated so it is not mistaken for covered:** the gauge's suite proves the
tool *detects* a compaction and not that it *reports the right numbers*. Forcing every percentage to
zero leaves all 54 lanes green — the code is correct today, but a regression in the percentage, the
delegation count, the turn count or the ambiguity warning would ship green. That is the next slice.

## core-v0.30 — 2026-08-12

**The backstop was watching the wrong five percent, and the gauge could not tell discipline from
amnesia.** Both of this release's changes are the same shape as v0.29's: a rule that only existed in
prose, made into something that can actually fail.

- **`plugin/hooks/beat-nudge.py` — the GENERATION-TIME half of the beat pair.** v0.29 shipped a
  PreToolUse guard that fires *after* a message is composed. Measured across **701 real beats**,
  **49.5% sit above the soft line and only 5.4% ever reach the hard deny** — so the backstop never
  sees the band where the problem lives. On each user turn this reads the session transcript, counts
  the last few **delivered** beats exactly the way the guard counts them, and injects one line
  naming the real numbers — only when the recent median is over the limit, and only **once per new
  measurement** (an earlier pass re-fired the identical nudge every turn until new beats moved the
  median, up to fifteen times for one long message). Silent when recent beats are clean.
- **It annotates; it never decides.** No permission decision, no rewrite, no truncation, and every
  failure path exits 0 with empty stdout — this one sits on the *operator's own turn*, so the
  catastrophic failure is not a wrong nudge, it is a lost turn. `BEAT_NUDGE=0` (or `BEAT_GUARD=0`)
  disables it; a threshold at or below zero disables that dimension rather than nudging on
  everything.
- **Session identity is resolved, never guessed.** An adversarial pass broke the first version twice
  on exactly this: it picked the newest transcript in the project directory, so a *sibling* session
  writing one second later won and the nudge would quote **another session's beats**; and it keyed
  the project directory on the payload's `cwd`, which is the session's **live** working directory —
  one `cd` into a subdirectory and it resolved nothing (≈500 recorded turns in one repo sit below
  its root). Now: the runtime's own `transcript_path` when present, else
  `<projects>/<slug>/<session_id>.jsonl` found by walking **up** from cwd. No session id, no nudge;
  the ambient-env fallback was deleted outright, because that is the value that leaks between orgs
  on a shared box.

- **`scripts/context-headroom.py` now counts RESETS.** The gauge could not distinguish a worker that
  stayed lean by delegating from one that **autocompacted** — both read as low fill after many
  turns. That blind spot was not theoretical: it reported the deepest delegator on a real box as the
  cheapest worker at **612 tokens/turn**, a memory recorded it, and a causal claim ("cost per turn
  tracks delegation inversely") was built on top. The 612 was `current / turns` measured straight
  across a compaction. Corrected, that worker sits at **1,627/turn** — within 1% of one that
  delegates 3.8x less, so the claim does not survive its own data.
- **Two detectors, because neither is guaranteed:** the `isCompactSummary` record (which rides a
  `user` record with *no* usage block, so a usage-only prefilter could never have seen it) and a
  single-turn collapse past 100k. They observe one event from two sides, so the count takes the
  **max** rather than adding them — an interim pass reported "2 resets" for one compaction. The
  table now flags a compacted row instead of printing a confident percentage over a reset, and
  reports a compaction-immune `grow/t` (sum of positive per-turn deltas ÷ turns) that is comparable
  between workers.

**Suites:** two new lanes-files, both registered in `lefthook.yml` — which is the only place
`release-gate.sh` discovers suites, so an unregistered suite can rot red while a release reports all
green. `beat-nudge-selftest.sh` (35 lanes) and `context-headroom-selftest.sh` (9 lanes), each lane
watched RED against the pre-fix code before being allowed to pass. Two of those lanes exist because
their absence had already cost something here: a checker that parsed the **whole** stdout the way
the consumer does rather than grepping a substring (an earlier draft of the nudge suite blinded
itself by feeding its checker via a stdin heredoc while also reading stdin, and answered "silent"
for every input), and a lane asserting `hooks.json` actually wires the hook, since one that is not
wired ships inert and green.

### The pin check told a confident wrong story, and ticked green on locks that named no tag

**A missing tag was reported as a moved one.** A pin written ahead of its release blocked an engine
hop on 2026-08-12, and `preflight` #6 explained it as *"the tag MOVED since the pull (a re-tagged
release); re-run `kickoff pull core-v0.30` after reviewing the change"*. That tag had never been
created. The remediation it printed could not work, and the story it told — someone re-tagged your
release — is the alarming one.

`git rev-parse <unknown>^{commit}` **echoes its argument on stdout** and exits non-zero, so under
`2>/dev/null || true` an absent tag is captured as the literal string `core-vX^{commit}`. Non-empty,
so it sails past the emptiness arm written to catch exactly this, and lands in the moved-tag arm
below it. The absent-tag branch was **dead code**.

**The second defect had never been observed, because nothing looked.** A bare `<value>^{commit}`
resolves *any* revision, not a tag — so a `core.lock` naming `HEAD`, a raw commit id, or a branch
**resolved**, and the pin verified GREEN while certifying nothing. For `HEAD` and a raw sha the
clause is true *by definition* once `HEAD == commit` is checked one arm above, so it could not fail
even in principle, and the operator was told a tag had been checked when no tag existed.

Both are fixed with `-q --verify` and a `refs/tags/` scope, at **both** remaining sites: `preflight`
#6 and the front door's `_verify_pin_target`. This is not a new idea in this codebase — the
engine-identity predicate (`_eitp`) made exactly this fix in **core-v0.26** and left twenty lines
explaining why. Its two siblings kept the idiom for four releases. The lesson generalises past this
bug: *a fix applied at one site is not applied until its siblings are checked*, and the reason the
drift survived is that every existing lane drove one site at a time.

**Suite:** `pin-verify-selftest.sh` grows a section that runs **both** predicates against one set of
fixtures — 31 lanes, 0 failed. Six of them are false-green negative controls: the pre-fix build is
watched actually re-exec'ing into an engine, and printing `core.lock verified`, on locks naming
`HEAD`, a raw sha, and a branch. The preflight lanes build an engine that **carries the preflight
under test** and commit it before tagging, because `core_base` and `RUNNING_CORE_DIR` must agree or
check #14 fires first and the entire pin block is skipped by the `elif` chain — a lane that got that
wrong would pass while testing nothing.

**Adopter impact: none, and it was measured rather than assumed.** Scoped and unscoped resolution
were compared across all seven live orgs before touching a gate they all boot through; identical on
every one, so no adopter's pin changes verdict. The only behaviour that changes is a lock whose
`tag` line never named a real tag — which now says so instead of ticking.

### A gate read the CLI's own bookkeeping as tampering, and put six orgs one restart from dark

**This one was not found by looking for it.** Chasing an unrelated red suite turned up preflight #8
failing on **every other org on the machine at once** — six of them, each one restart away from a
supervisor that would refuse to start a session, and an engine hop (i.e. exactly what a `kickoff
pull core-v0.30` does) would have fail-closed on all six.

The cause is one file. The CLI stamps `.orphaned_at` — a millisecond epoch — into a cached plugin
version dir once no **user-scope** marketplace references it. kickoff's marketplace is registered
**per-adopter at project scope**, so on a box where that is the only registration the CLI orphans
every cached kickoff version as ordinary housekeeping. `plugin-cache-verify` compares the cache tree
against the pinned `<core>/plugin/` as a file set, saw one extra file, and reported DRIFT — a
tampering-shaped word for the vendor tidying up after itself. The org that found it was invisible to
its own bug: kickoff-itself has no interactive plugin entry, so it skips #8 entirely and looked
perfectly healthy while its six siblings did not.

Excluded **on the cache side only, at the top level only** — the pinned core tree is still hashed
with nothing excluded at all. Three lanes hold that line: a real extra file still fails, the same
filename in the **core** still fails, and the same filename **one directory down** still fails, so
the exemption cannot become a hiding place. Measured before and after across all seven orgs.

### Two fixtures were reading this box instead of their own world

Both surfaced in the same hunt, and both are the shape where a suite's verdict is decided by the
machine rather than the case:

- **`adopt-brains-selftest.sh`** ran `preflight` without the scratch `CLAUDE_CONFIG_DIR` its sibling
  one line above already passed — so preflight's plugin-cache check read the **real** `~/.claude`.
  The suite header had claimed a hermetic config dir for four releases; this makes the claim true.
- Its stub `claude` modelled only half of `plugin install`: it wrote `settings.json` and never
  snapshotted the plugin into the cache — which is the artifact #8 actually verifies. A stub that
  models half a command leaves the check reading whatever the box happens to hold.

### The selftest could commit into the repository under test

`pin-verify-selftest.sh` built its fixtures with `git -C "$dir" …`. **`GIT_DIR` overrides `-C`**, and
every fixture git call was silenced — so with that variable exported the suite writes into the
CALLER's repository while printing an ordinary pass/fail summary. An adversarial pass proved it by
doing it. Fixture git now routes through a wrapper that strips `GIT_DIR`, `GIT_WORK_TREE` and
`GIT_INDEX_FILE`; verified against a sacrificial clone with `GIT_DIR` exported — HEAD, tags and
branches all unchanged. The suite is wired into `pre-push`, so this shipped to every adopter that
pulled it. Carriers are ordinary: `git bisect run`, `git rebase --exec`, `git submodule foreach`,
any wrapper or agent that exports `GIT_DIR`.

**Upgrade note:** no `instance.env` variable name changed and no existing `core-manifest.txt` entry
changed — `kickoff pull` asks nothing of you. The manifest gains one file
(`plugin/hooks/beat-nudge.py`), so the plugin version bump to `0.3.22` is what converges every
adopter's plugin cache on pull. If your `kickoff pull` or a supervisor start has been failing with
`plugin cache DRIFT/MISSING` and the named difference is `.orphaned_at`, this release is the fix and
nothing on your side needs cleaning up.

## core-v0.29 — 2026-08-10

**A behavioural rule that keeps failing does not need better prose, it needs a mechanism.** The
operator steers from a phone and had said plainly, twice, that dense beats lose him. By this release
the rule existed in `CLAUDE.md`, in a memory file, **and** was being injected into the coordinator's
context on essentially every turn by the recall hook — three written copies — and it still lost,
because an instruction competes with a growing context and a hook does not.

- **`plugin/hooks/beat-length-guard.py` — a PreToolUse hook on the Telegram `reply` /
  `edit_message` tools.** It travels with the plugin, so an adopter gets it on `kickoff pull` with
  nothing to wire by hand. **Two tiers**, because length is only a proxy for the real variable and a
  bad one alone — the operator's own correction was *"I don't mind receiving a long text if the
  situation actually requires it. I just need to be able to follow it logically."* Past a soft line
  count (7) it **allows** and nudges about logical order; past a runaway cap (20 lines / 2000 chars)
  it **denies** and hands back the measured numbers so the beat gets rewritten, with the detail
  pushed to the tracker or a file attachment — which reads better on a phone than a wall of chat
  text anyway.
- **It never truncates or rewords.** A PreToolUse hook *can* silently rewrite a tool's arguments
  (`updatedInput` — verified against a probe MCP server, which reported receiving the rewritten
  value rather than the original); this one deliberately does not. A script quietly editing what the
  operator reads is the wrong side of honest-stage, so the guard refuses and the coordinator
  rewrites it.
- **FAIL-OPEN by construction**, and that is the load-bearing property rather than a nicety: it sits
  in front of the **only channel out**, so a bug here would gag a worker *silently* — the failure
  mode where the way you would report the problem is the thing that broke. Malformed JSON, a missing
  field, a wrong type, an unparseable env knob and an outright crash all **allow**, with `|| true`
  at the shell layer as a second belt. **A threshold knob set to zero or negative disables that
  dimension rather than denying everything** — the switch beside them is `BEAT_GUARD=0`, so "set it
  to 0 to turn it off" is the natural misread, and read literally it would have gagged the worker
  outright. Every knob misreading resolves toward delivery. **18 of the suite's 28 lanes** exist to
  prove exactly this (13 fail-open + 5 gag-path), and a negative control (an always-allow stub)
  proves the suite can go RED.
- **The nudge annotates; it never decides.** The soft tier emits a bare `systemMessage` with **no**
  `permissionDecision`. An explicit `"allow"` does not mean "do not block" — it *auto-approves* the
  call, skipping whatever permission prompt an adopter configured, which would invert their own
  settings: short beats prompt, long ones sail through silently. Two independent adversarial
  reviewers flagged this on the same candidate; a suite lane now pins it.
- **The suite asserts on what the consumer parses.** Its deny-detector `json.loads()` the guard's
  whole stdout the way Claude Code does, rather than grepping for a substring — a mutant printing one
  stray line before its JSON passed 20/20 under the old grep while the real consumer could not parse
  it at all. A further lane parses the shipped `hooks.json` and fullmatches its matcher against tool
  names observed in real transcripts, so a dropped or typo'd wiring cannot stay green.
- **Knobs:** `BEAT_GUARD=0` disables it entirely · `BEAT_NUDGE_LINES` (7) · `BEAT_MAX_LINES` (20) ·
  `BEAT_MAX_CHARS` (2000).

## core-v0.28 — 2026-08-10

**Two gates were reading the wrong thing, and both said GREEN while they did it.** One handed a repo
to an engine it had never verified; the other judged an adopter's channel by whichever value happened
to be in the caller's environment. Neither could report the problem, because in both cases the check
was measuring something adjacent to what it was supposed to protect.

- **`scripts/kickoff` — the pin-redirect now verifies the engine before re-exec'ing into it.**
  `up` / `adopt` / `doctor` checked that `.kickoff/core.lock` EXISTED, then exec'd whatever
  `$KICKOFF_CORE_DIR` named — nothing ever read the commit the lock PINS. A repo whose `instance.env`
  named a different engine than its lock pinned was exec'd into that engine unverified. Present since
  v0.7, inherited by every release since. preflight #6 checks this exact predicate, but runs INSIDE
  the engine — after the handover — so it could never be the gate. `_verify_pin_target` reuses #6's
  predicate (HEAD == the pinned commit, the tag resolves to it, the tree is clean) on the near side of
  the exec and refuses loudly instead of falling through. **A pre-format-2 lock has no commit to
  compare: it warns and proceeds** rather than bricking an old adopter, matching the supervisor's
  existing "nothing comparable ⇒ inert" rule.

- **`scripts/preflight.sh` — a repo's own `instance.env` now owns its channel.** Check #2 treated an
  ambient `TELEGRAM_STATE_DIR` as a trusted launcher override. That premise holds for
  `KICKOFF_CORE_DIR` (the parked-worktree case it was written for) and fails for the channel: a pull
  or preflight for repo B run from inside repo A's worker session — every fleet sweep — carried A's
  channel, so #2 evaluated A's channel as if it were B's and FAILED a phantom "channel clash" against
  A itself. Fail-closed, so it blocked B's pull and A's engine hop on a box where no clash existed.
  v0.27 fixed the writers; this is the reader. Two paths closed: the variable is now exempt from
  pre-set-wins, and the import subshell unsets it so the adopter's self-defaulting
  `${TELEGRAM_STATE_DIR:-…}` form resolves to that repo's own default.

- **`scripts/memory-budget-check.sh` — the line budget was measuring half the tax it stands for**
  (210 → 400). The guard bounds a per-session context cost; bytes measure that directly and the line
  count is a proxy, calibrated when a pointer averaged ~400 bytes. Compacting an index back to real
  hooks takes the average to ~209, so the byte budget correctly falls to half-empty while the line
  count does not move — leaving a guard that demands demoting live facts to buy space that was never
  being spent. Both gates remain; whichever trips first still means the index costs too much.

- **`scripts/memory-index-triage.py` (new, ships) — which index entries have earned their place.**
  Read-only. Reads the retrieval log and reports what a usage-driven index would demote, with the
  exemptions that matter: operator-facing facts (usage is the wrong test for a standing instruction),
  entries naming a live project (`memory-orphan-check` greps the index for those), and anything whose
  age cannot be established from a trusted source. Companion to the budget check above — "demote
  something" is unactionable without the measurement behind it.

## core-v0.27 — 2026-08-07

**A pull upgraded one org and quietly rewired another.** `kickoff pull` recorded the adopter's
Telegram channel in the machine registry (`~/.kickoff/adopters.json`) by reading the ambient
`$TELEGRAM_STATE_DIR`. But `load_instance_env` deliberately refuses to override a name that is
already set — `pre-set / argv wins` — so a pull run from *inside* another worker's session never
imported the target's own value and stamped the caller's instead. One fleet-upgrade sweep wrote the
sweeping org's channel onto three other orgs' rows. Hours later that org's engine hop fail-closed on
preflight #2 "channel clash": a phantom clash, reported by a completely clean preflight reading
poisoned data written by a different repo's command.

The isolation this needed already existed — `cmd_adopt` has applied it since core-v0.3.1, with a
comment describing this exact leak. `cmd_pull` never got it. Fixing one call site and leaving its
siblings unaudited is what let the class survive four releases.

Note the asymmetry, because it is the dangerous half: a row naming the wrong channel does not only
invent clashes, it also **suppresses real ones** — the double-poller footgun that check exists to
catch would pass silently. This class yields false greens as well as false reds.

- `scripts/kickoff` — `cmd_pull` now reads the channel from *this* repo's `instance.env` in an
  isolated read that pins BOTH the cwd and `REPO_DIR` to the repo being read and unsets only
  `TELEGRAM_STATE_DIR` — the one value that must never be inherited. Both call sites now share one
  helper (`_channel_of_repo`), because the first attempt at this fix unset `REPO_DIR` too and an
  adversarial pass caught it before the tag: an `instance.env` deriving its channel from
  `${REPO_DIR:-$PWD}/…` — the anchor `instance.env.example` teaches for derived paths, applied to
  the channel line — then resolved the CALLER's
  directory — the same cross-wire in a new direction, and worse, because a non-empty wrong value
  never trips the `empty ⇒ MERGE` guard and hard-overwrites the row instead. `cmd_adopt` carried
  that same defect and is fixed in the same change: this release's own lesson, applied to itself.
- `scripts/pull-selftest.sh` — §9b, driving a real `kickoff pull` across every shape an adopter's channel line takes:
  the plain `export` form, the self-defaulting `${VAR:-…}` form that `instance.env.example` seeds
  (with a control proving only the `unset` beats it, not the subshell alone), and the empty-channel
  MERGE semantic, so the fix cannot regress into always-overwrite.

**A tool the adopter charter tells you to run had never shipped.** `scripts/templates/KICKOFF.md`
— the charter every adopter receives — tells the coordinator to measure its own context headroom with
`python3 "$KICKOFF_CORE_DIR/scripts/context-headroom.py"`. That script was tracked on the development
branch but had never been carried into a PUBLIC release tree. `$KICKOFF_CORE_DIR` is a FULL checkout
of the tag, so a file absent from the tree simply does not exist for an adopter: the command 127'd,
and the only mechanical defence against a silently degrading session was inert. It hid because
`reground-prompt-selftest.sh` held the BOOT check list against the re-ground prompt, and this one is
deliberately never-run-at-boot — named in charter prose, which nothing validated against the tree.

- `scripts/context-headroom.py` — now ships. Two corrections travelled with it. It derived the
  transcript directory from a hardcoded home path (which is why the release gate's leak scan refused
  the tree, and plausibly why it never travelled before); it now derives from `$HOME`, honouring
  `CLAUDE_CONFIG_DIR`. And it picked the newest transcript by mtime while saying nothing about that
  choice — one repo can hold several sessions, so it now names the session it measured and warns when
  others were recently active, or when the peak exceeds the assumed window. This number feeds an
  "am I safe to keep going" decision, so a silent understatement is the dangerous direction.
- `scripts/core-manifest.txt` — declares it, so `pull` refuses to pin a future tag that drops it.
  (The manifest is an existence CONTRACT, not a copy list: tree presence is what makes a file
  reachable. Both matter, for different reasons.)
- `scripts/reground-prompt-selftest.sh` — §4 asserts every core script named in ANY shipped markdown
  EXISTS in this tree; §4c asserts every manifest entry exists, because an entry without its file
  makes `pull` refuse to pin for EVERY adopter. Both watched RED on the real broken tree, then GREEN.
- `.claude/skills/diagnose-fail-closed-upgrade` — a third triage branch. The skill offered only
  "fix the guard" or "fix local state"; when both are correct and the *data the guard read* is
  poisoned, following it literally pushes you toward loosening a guard that is working.

**Upgrading:** nothing to do beyond `kickoff pull core-v0.27`. If a past sweep already poisoned your
registry, repair the affected rows by re-registering each from its own `instance.env`
(`adopt-manifest.py adopters-register --repo <r> --tag <t> --version-dir <v> --channel <real>`) —
the code fix stops new poisoning, it does not clean rows already written.

## core-v0.26 — 2026-08-07

**Two things this release settles: adoption now lands a MIND and not only plumbing, and the front
door tells you which engine is speaking before it tells you anything else.**

### Adoption authors the brains — the intelligent half stops being a printed sentence

`kickoff adopt` wired every mechanical seam — gates, pin, manifest, shims, plugin, bot, worker —
and then handed the one step that needs a mind (a domain crew, a real `CLAUDE.md` body) to a **log
line telling a human to type `/adopt`**. On the path that actually runs, `kickoff adopt --accept`
from a phone, nobody is watching stdout at all. The machinery for the intelligent half already
existed and shipped (`crew-probe.py`, `adopt-manifest.py gen-agent`) — it was reachable **only**
from a session a human started by typing `/adopt`, so on the headless path nothing ever called it.

**Measured 2026-08-06 across six live adopters:** one had run **35 memory-writing sessions with no
`.claude/agents/` at all**; two carried the byte-identical **76-byte `CLAUDE.md`** that is nothing
but the kickoff include. Those orgs were steerable and could not act, and nothing anywhere said so.

- **One predicate, three consumers.** `crew-probe.py brains-verdict --repo <dir>` is the single
  implementation of "did adoption land a mind?" — exit 0 when a crew *and* a charter body exist,
  exit 1 naming the gap. `kickoff adopt`/`doctor`, `kickoff verify` and `preflight.sh` all ask
  **it**, rather than each writing its own copy. It lives in `crew-probe.py` because that file
  already travels via `core-manifest.txt`; a predicate that does not travel is exit 127 on every
  adopter, which is silent and reads as fine.
- **Two independent halves, deliberately not one boolean.** Crew (`.claude/agents/` holds ≥1
  charter, counted as *files* — a malformed charter is still a crew someone authored) and charter
  (`CLAUDE.md` carries content beyond the `<!-- kickoff:begin/end -->` include). A repo can have
  either without the other and the fixes differ, so the verdict reports them separately.
  **Ambiguity fails toward "present"**: a hand-edited or unterminated include block counts the
  whole file as body. This never blocks a boot, and a false alarm on a repo that *has* a charter
  costs trust in every other thing the system says.
- **A durable marker, disclosed at write time and reversed by eject.**
  `.kickoff/adopt-brains-pending` is written by `adopt` at the moment of the touch (and *announced*
  there — the consent rule), is human-readable prose explaining what is missing and what happens
  next, and is **derived state**: gitignored (the seam template now ignores it, and
  `crew-plan.json`), never manifest-recorded, removed with the rest of `.kickoff/` by `eject`.
  It is **self-retiring** — every caller *syncs* rather than sets, so `doctor` clears it once the
  crew and charter exist, and back-fills it for adopters wired before this release. State that
  outlives its condition is how a detector loses the right to be believed.
- **The worker authors them at boot, then announces.** `session-run.sh`'s re-ground prompt gains
  rule **(1b)**, ahead of queued work: run `brains-verdict`; if it fails, author the brains *first*
  — read the repo, run `coverage-sources` (frontmatter alone under-counts coverage and makes you
  over-propose), gate the plan through `validate-plan`, author one agent per **uncovered** domain
  via `gen-agent`, write a real `CLAUDE.md` body — then announce over Telegram and ask for one
  word. The `adopt` skill (both copies) gains a **HEADLESS ENTRY CONTRACT** stating the same
  motion and its hard restraint: **never overwrite an existing charter, `CLAUDE.md` body, memory
  file, or any repo source.** Authoring a *first* crew is bootstrap, not mutation; changing a crew
  that exists is mutation and still goes to the operator as a proposal.
- **The detector that should have caught this was structurally dead, and is fixed.** Preflight
  check #9 and `verify`'s escalation both sat inside an `_ai_unwired` branch predicated on *"the
  lefthook gate is absent"* — and `adopt` now always writes that gate. For every modern adoption
  the whole escalation was **unreachable**, and both commands reported GREEN on a brainless org.
  All six live adopters carried the gate file, so not one of them could ever have tripped it. The
  brains question is now asked **outside** that branch, at the same nesting level, so no future
  edit to the gate chain can silently take it with it. **Advisory in both:** preflight `warn`s and
  `verify` counts a warning — exit codes are unchanged, because a brainless org must still boot;
  the worker it boots is exactly what closes the gap.
- **Proven:** `scripts/adopt-brains-selftest.sh`, **50 lanes, green** — including a negative
  control that authors a real crew and asserts *every* finding goes quiet (`brains-verdict`,
  `verify`, `preflight`, and `doctor` retiring the marker), and a reversibility section proving
  `eject` removes the marker and `eject --verify` still reports NO TRACE. The detector lanes run
  with the gates **wired**, on purpose — a fixture that strips them would test the old bug and go
  green. Registered in `lefthook.yml` under `pre-push`, which is the only place `release-gate.sh`
  discovers suites: an unlisted suite is invisible to the gate and can rot red while the release
  reports "all suites GREEN".

### The front door says which engine is speaking — and states what it did NOT establish

`~/.local/bin/kickoff` is a symlink installed once and never repointed, so it rots. On this box it
named **core-v0.24** while six orgs ran core-v0.25 and one ran core-v0.23. Reproduced live
2026-08-07: the core-v0.24 front door, run against a core-v0.25-pinned repo, printed

```
✓ core pin HOLDS — the clone is at core-v0.25 (642998fc9710…) on a clean tree (== core.lock)
```

Every word of that was true — **of the clone**. The core-pin block asks whether the *pinned clone*
matches the lock and never whether the front door printing the answer **is** that clone. So a stale
engine handed the operator a green tick it had no standing to give.

- **`status`, `verify`, `doctor` and `pull` now report the running engine first.** The verdict is
  by **identity**: the tree this process is executing from (derived from `$0` alone, snapshot at
  load — before any `cd`, before `instance.env`, before `--dir` is parsed) versus the `commit`
  recorded in the named repo's `.kickoff/core.lock`. It compares **no paths** (a path comparison is
  a proxy — two paths can name one tree) and asks git about **no tree other than the running one**
  (the pinned clone's state is preflight #6's job; conflating the two is how "the pin holds" came
  to be printed by an engine that was not the pin).
- **`REPO_DIR` is TOLD, never SENSED — now stated as the law of the file.** It may come from
  `--dir`, the `REPO_DIR` environment variable, or `$0`'s own tree, and from nothing else: no
  upward walk from `$PWD`, no ancestor discovery of a `.kickoff/`, no registry lookup. "Which repo
  did the user mean?" is not answerable from the environment — a cwd inside repo A while the user
  means repo B is indistinguishable from the honest case, so every sensing scheme fails *open*.
  Where that makes `--dir` required, `--dir` is required. Enforced behaviourally: the suite plants
  a `core.lock` in an **ancestor** of the cwd, baited to flip a "NOT the pin" verdict into a false
  "IS the pin", and asserts it changes nothing.
- **The predicate's git calls run under an allowlisted environment.** Reading no environment
  variable was not enough — *git* reads plenty, and inheriting `GIT_DIR`/`GIT_WORK_TREE` made the
  predicate print one engine's path beside another engine's commit, with a ✓. A denylist of `GIT_*`
  names has no terminating condition (`XDG_CONFIG_HOME` and `HOME` reach git's global config by
  names that are not `GIT_*` at all), so git now starts from `env -i` with **PATH** carried (kept
  deliberately: the two-directory `confstr` fallback would break every box whose git is in
  `/usr/local`, Homebrew or Nix), `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM` nulled — the *system* one
  is load-bearing, since `/etc/gitconfig` is a filesystem path no environment scrubbing unsets —
  and `--no-replace-objects`, which closes a `refs/replace` route that is a ref, not a variable.
  The same seal now covers `status`' and `verify`' **core-pin** blocks, because when the pinned
  clone *is* the running engine that was one directory answered twice under two environments on one
  screen: reproduced printing "✗ … its tree is DIRTY" and "✓ core pin HOLDS" eight lines apart.
- **The tick states what it ESTABLISHED versus what it merely REPORTED, and declares its own threat
  model in the output.** Established: the ref-identity match, about the tree git resolves as its own
  work-tree root, and a tag clause that names which of three worlds actually applied (a real tag
  resolved / the lock has no `tag` line / the line is present but valueless). Reported, not proved:
  **that this tree is the engine executing the command** — that path comes from `$0`, and `$0` is
  whatever the caller supplied — and **cleanliness**, which is what `git status` said under this
  machine's configuration. Not verified at all: **the content of the tracked files** (nothing here
  re-hashes them) and files git ignores.
- **What it detects and what it does not is printed for the operator, not left in a source
  comment.** It detects an engine-version mismatch **reached by accident** — a rotted symlink, a
  stale checkout, a `KICKOFF_CORE_DIR` left on an old clone, a repo re-pinned since the last pull.
  It does **not** detect a caller that deliberately misrepresents which program is running
  (`exec -a`, or `bash -s` with a planted argv0), a caller that controls which `git` runs, or
  tampered tracked content git was configured not to report (`core.trustctime` in the engine's own
  `.git/config`). **This REPORTS; it does not attest.** Closing the remaining routes needs a
  *content proof* — re-hashing the work tree against `git ls-tree` — and **nothing in this release
  computes it.** A declared limit is honest; an undeclared one is a lie waiting to be found.
- **Anything unestablished comes out UNKNOWN, never as a tick.** An unreadable or legacy lock, a
  `format` this engine does not understand, a lock with no `commit`, a tag that does not resolve
  under `refs/tags/` (a bare `<value>^{commit}` resolves *any* revision, so `tag HEAD`, `tag <the
  pinned sha>` and `tag <a branch>` used to tick a vacuous or mislabelled clause), a git call that
  failed, or a tree whose index carries `assume-unchanged`/`skip-worktree` on a tracked path — all
  are honest CANNOT DETERMINEs. Every value read out of `core.lock` is sanitised **at the print
  site** before it reaches the operator's report or git's argv: a lock recording
  `tag ✓ the running engine IS this repo's pinned engine` rendered a **forged green tick** inside
  the sentence whose job is to report a broken pin.
- **Reporting only — no new refusal.** The function always returns 0. `status` and `doctor` exit
  codes are unchanged; `verify` counts a warning (which changes only its summary sentence) and
  never a failure. A wrong engine is something the operator must **see**; making it a refusal is a
  separate, still-pending operator decision.
- **Proven:** `scripts/engine-identity-selftest.sh`, **123 lanes, green**, behavioural on a
  two-real-engine deploy fixture — with positive controls beside every negative one (so no lane
  passes vacuously), a mutant table adjudicating which seals are load-bearing versus equivalent,
  and lanes that assert the *poison is live* before asserting the predicate is immune to it.
  Registered in `lefthook.yml` under `pre-push` for the same discovery reason as above.

**Adopter impact:** nothing to do. `kickoff pull` takes it; `kickoff doctor` back-fills the brains
marker if your org needs one and retires it once the crew and charter exist. No `instance.env`
name changed and no `core-manifest.txt` entry was added or removed.

## core-v0.25 — 2026-08-05

**Two things this release settles: a workspace root may now be version-controlled, and a message
sent to a busy agent arrives on its next turn instead of its next restart.**

### A workspace root may be a git repo AND a workspace

core-v0.24 taught the gates to follow kickoff onto a multi-repo root, but it answered *"is this a
workspace?"* with *"is the root NOT a git repo?"* — which made the two mutually exclusive. Running
`git init` at an adopted workspace root therefore **silently demoted the whole org to a single
repo**: member gate-arming stopped, both scanners collapsed to the root alone, and nothing went red
(installed member hooks survive on disk, so the drift is invisible).

- **`.kickoff/workspace` decides now — an explicit marker, never an inference.** It is *tracked*
  (`instance.env` is gitignored, so a marker there would not survive the fresh clone this exists to
  enable), written by `adopt`/`doctor` at a non-git root, and **recorded, so `kickoff eject`
  reverses it**. It is never inferred at a git root — an ordinary repo containing a nested checkout
  must not be silently promoted. `kickoff adopt|doctor --workspace` is the explicit opt-in for a
  root that is already a repo.
- **There were FOUR guard sites, not three.** The hidden one is `adopt-manifest.py`'s two scan
  *shims*, which decided member-scoping by the same inference — at a marked git root that branch
  went dead and a member's pre-commit `cd`'d to the ROOT and scored its commit against the root's
  (usually empty) index. Only a real `git commit` inside a real member catches that.
- **A submodule is a member.** `.git` as a *file* has three shapes; the old dir-only test was false
  for all of them, so a planted key inside a submodule scanned as "no secrets found", rc 0.
  Submodules are now matched positively and **scanned** — but honestly reported as **not armable**,
  because their hooks live outside the member and cannot be recorded or ejected. The `adopt`
  hard-fail now fires on *"nothing at all is gated"* rather than *"no member is gated"*.
- **Three false greens this feature would otherwise have created are closed.** The fan-out exited
  before the root's own files were scanned (a secret in the org's own `CLAUDE.md` passed as
  "workspace clean"); `eject --verify` proved cleanliness over the root only, reporting CLEAN over
  unreversed member config and armed member hooks; and a marked root *nested inside another work
  tree* stopped scanning its own tracked files — turning a pre-feature RED into a green, in a
  topology `kickoff adopt` itself produced.
- **Fail-closed no longer depends on the root's shape.** The unreadable-member sweep sat inside
  `if members > 0`, so a marked git root whose only candidate member was unreadable fell through to
  a plain root scan and exited 0, while the identical member at a non-git root correctly refused.
  Indeterminate is not clean: an unreadable `.git` file is no longer silently "not a member".
- **Silence is not the alternative to inference.** `adopt`, `doctor` and `verify` previously said
  *nothing* about the workspace shape, so the capability was reachable by exactly one ordering.
  The shape is now named once by `adopt` and `verify`, the members are reported (not just the
  root), a hand-made or freshly-cloned marker gets its missing receipt back-filled, `verify` no
  longer tells a plain non-git folder it "is a workspace root", and `doctor` no longer closes
  "nothing to fix — already healthy" six lines under a true "NOT gated" warning.

**Single-repo behaviour is byte-identical, proven rather than asserted** — an old-vs-new
differential over six topologies (plain repo · nested child repo · submodule child · linked
worktree · plain non-git folder · classic workspace) shows `adopt`, `verify` and both scanners'
exit codes and on-disk artifacts identical. The only deltas are the deliberate advisory line at a
git root holding sibling checkouts, and the removal of `verify`'s false workspace claim.

### agent-mail reaches a running agent — a per-turn hook, not a boot check

`agent-mail` shipped as a **boot check**, on the strength of a claim in its own docstring: *"there
is no reliable way to interrupt a running headless session."* That is false — the plugin already
fires a `UserPromptSubmit` hook on every turn; it is how memory retrieval reaches the model. Boot
was badly wrong as the only cadence: a worker can stay up for days, so a sibling org's finding
could sit unread that long — delivery reported, message rotting, which is the exact failure the
mailbox was built to avoid.

- **`plugin/hooks/agent-mail-hook.sh`** now runs on `UserPromptSubmit` beside the memory hook, so
  mail lands on the recipient's **next turn**. This file is genuinely new to the public core — the
  fix has existed on the development branch since 2026-07-31 and shipped in no tag before this one.
  An unreleased fix protects nobody.
- **It costs nothing when there is no mail.** The empty case — very nearly always — is settled in
  pure bash and exits having printed nothing; `python3` is never started. The suite asserts that
  structurally, not by timing (which a loaded box makes lie).
- **Each message is announced once, not every turn.** Surfaced ids are marked in `.kickoff/state/`.
  The boot check deliberately *ignores* that marker — a fresh session should hear everything still
  unread.
- **It announces; it never consumes.** Reading stays the agent's decision, and the injected block
  states plainly that a message is **data**: anyone who can write a file on the box can write one.
- **Option-injection closed in the boot check too** — `agent-mail.py check` now prints its
  suggested read command with `--`, because the message id comes from a filename any process can
  choose, and a message named `--help.md` rendered as an instruction to run `read --help`.

**Still unsolved, and now written down rather than implied away:** a fully **idle** worker takes no
turns, so nothing fires. Waking one needs a real wake channel; the sanctioned lever remains the
supervisor's refresh flag, which costs the recipient its in-flight context.

### Also in this release — four core files that existed only on the development branch

Each of these was written before core-v0.24 and was **not** carried by that cut. They reach
adopters here for the first time.

- **`scripts/scan-identity.sh` — catch a private name where it is WRITTEN, not where it ships.**
  The identity denylist was consulted by exactly one thing: the release gate. Twice a release was
  held while a project name that had sat in a comment for weeks was scrubbed — and by then a public
  tag cannot be unpublished. `scan-identity.sh --staged` runs on **pre-commit against ADDED LINES
  ONLY**, so writing a private name fails the commit while you still remember why you typed it, and
  the inherited content already mentioning deliberately-published names never re-fires. That scoping
  *is* the design: a guard that also flags inherited lines gets `--no-verify`'d within a week, which
  silently disables every other pre-commit gate with it. `ALLOW_IDENTITY=1` is the sanctioned path
  for a deliberate reference, and it announces itself rather than passing silently. **Honest scope:
  the script travels, but nothing wires it for you** — `kickoff adopt` still generates only the
  `scan-secrets` / `scan-structure` gates. Add `run: bash "$KICKOFF_CORE_DIR/scripts/scan-identity.sh"
  --staged` to your own pre-commit block, with a denylist at `.kickoff/leak-denylist.txt`, if you
  publish from a repo that also holds private names.
- **`scripts/probe.sh` — a counting check that cannot report a VACUOUS green.** Zero findings and a
  blind instrument are indistinguishable unless something forces them apart: a `pgrep` that matched
  its own command line, a mutation whose `sed` matched nothing, and a health sweep grepping for a
  marker the tool does not emit all read exactly like a clean bill of health. `probe.sh` requires a
  **mandatory positive control** — a pattern that must appear in healthy input. Control silent, or
  input empty, and it exits 2 loudly instead of claiming clean. Findings are always printed, so a
  bare count is never the only evidence.
- **`scripts/templates/ship-turnkey.sh.tmpl` — the release turnkey is generated, and pins the SHA
  the gate certified.** The turnkey's three ordinary preconditions (the branch fast-forwards the
  remote, the tag is new, the plugin-version invariant holds) **all pass on a stale branch** — which
  is how a staged release once sat for a day carrying the very blocker it was held for, three checks
  green, while its header advertised a gate run from a different commit. The generator now pins the
  gated SHA into the emitted script and re-asserts it before any push.
- **`mission-control/dashboard.html` — the board works wherever it is mounted, not only at `/`.**
  Every data call was root-absolute, so a board served behind a path-routing ingress loaded and
  authenticated and then 404'd every fetch — presenting as "the board isn't reading the token".
  `MC_BASE` is now derived from `location.pathname` once and all five endpoints route through an
  `mcUrl()` helper. Root-mounted adopters are unaffected: a strict improvement, not a trade. Found
  by the operator on his own device, minutes after a cutover — a `curl` of the page had "verified"
  it, which tests the PAGE and never what the page then fetches.

### Smaller changes

- **`memory-retrieval/lib/memory.mjs` indexes a gitignored `memory/private/` subdir.** The indexer
  reads the **filesystem**, not git, so a private fact stays out of version control and still
  recalls. This is what lets "no private information in the public repo" coexist with "recall still
  sees it".
  **The `gitignored` half of that sentence is now actually true.** It shipped as a comment: no rule
  for `memory/private/` existed in this repo's `.gitignore`, nor in the `.kickoff/.gitignore` seam
  every adopter is given — so a private fact was untracked-**but-stageable**, and the next
  `git add -A` committed it. Both rules now exist, and `private-corpus-selftest.mjs` asserts them
  against **git itself** rather than against the text of a rule file: one case runs `git check-ignore`
  here, another builds a throwaway repo from the shipped seam template and proves `git add -A` does
  not stage `.kickoff/memory/private/` while still tracking the team-shareable corpus beside it.
  Both were watched go red with the rules removed. The original three cases proved the feature
  *recalls*; nothing proved it *stayed private*, which is the half that matters on a public remote.
- **The release gate's identity denylist was matching regex entries as fixed strings.** It scanned
  with `grep -F`, so every denylist entry written as a pattern — word-anchored names, an
  optional-hyphen vertical — was searched as that literal character sequence, backslashes included,
  and could never match anything. The gate still counted them and printed "N denylisted term(s)", so
  an inert guard reported as a live one, and a real occurrence of the operator's name in a shipped
  `memory/` file rode several releases behind a green gate. It now matches with `-E`, like the
  structural patterns beside it always did, and **no longer passes `-I`** — binaries are scanned too.
  The one deliberate exemption is the `LICENSE` copyright attribution, carved out by line shape
  rather than by file, so a name pasted anywhere else in `LICENSE` still fails the gate. That
  memory file is scrubbed to anonymized phrasing.
- **A docs asset rendered the operator's name in pixels.** `docs/assets/mission-control-sanitized.webp`
  — linked from `README.md` and the GitHub Pages talk — showed it three times (an owner chip, a
  section header, a plate title). It was named "sanitized" and had been scrubbed of everything a
  text scanner can see, which is precisely why it survived: **no text gate can read pixels**, and
  the file had been byte-identical since before the previous tag. The three sites now read `owner`,
  matching the dashboard's own vocabulary for that field. The leak check's PASS line now states its
  scope out loud — it proves no denylisted name is in any file's **bytes**, and nothing about text
  drawn into an image; those have to be looked at.
- **`scripts/scan-secrets.sh` / `scripts/scan-structure.sh`** carry the workspace fan-out changes
  above (root included as a unit, submodule members matched, unreadable members refused).
- **`scripts/memory-orphan-check.sh`** — a comment example had been over-scrubbed into nonsense by a
  previous anonymization pass; the example is readable again. No behaviour change.
- **`.kickoff/KICKOFF.md` (the pulled coordinator charter) gains the session-degradation loop** —
  measure your context fill at natural boundaries, hand off (memory · tracker · commits) past ~80%,
  then `touch .kickoff/refresh-requested` and let the supervisor start a fresh session that
  re-grounds from the files. Delegation is the other half: a subagent reads in its own window, so
  its context never lands in yours — but a low reading is not proof you delegated well, because
  autocompaction resets the gauge too and looks identical.
- **The `agent-mail` skill doc now states when a message actually lands** — next turn for a working
  recipient, next re-ground for an idle one — instead of the old "picked up on the recipient's next
  re-ground". Both copies of the skill (`plugin/skills/` and `.claude/skills/`) are updated; they are
  held byte-identical by a gate, because drift ships adopters something untested.
- **`plugin/.claude-plugin/plugin.json` → 0.3.18.** Required: this release changes `plugin/` files,
  and without the version bump every adopter's `kickoff pull` fails closed on the plugin-cache
  drift check.
- **The release gate's suite discovery now sees seven previously-unregistered suites.** It finds
  suites *only* from `lefthook.yml`'s `pre-push` block, so an unlisted suite is invisible to it and
  can rot red while the release reports all-green. `mc-mountpoint-test`, `probe-test`,
  `agent-mail-hook-test`, `shim-env-seal-test`, `identity-test`, `ship-turnkey-test` and
  `memory-private-corpus-test` are now registered, and `mc-milestone-test` moved from `pre-commit`
  to `pre-push` (it is a full suite, not a cheap gate).

**Upgrade note.** No `instance.env` variable name changed. `scripts/core-manifest.txt` **gained four
entries** (`scripts/probe.sh`, `scripts/scan-identity.sh`, `scripts/templates/ship-turnkey.sh.tmpl`,
`plugin/hooks/agent-mail-hook.sh`) — additive, so `kickoff pull` asks nothing of you. Your generated
gate file is untouched: `adopt` still wires `scan-secrets` and `scan-structure` only. Your
`.kickoff/.gitignore` **is** regenerated by the pull (it is a seam) and gains one line,
`memory/private/` — additive, and it only ever stops a file from being committed. If you already
adopted and put private facts in `.kickoff/memory/private/` before this tag, **check whether they
were committed**: `git log --oneline -- .kickoff/memory/private/`. The new rule stops future
commits; it cannot retract one already pushed. One more thing is
worth doing after the pull — **if you run kickoff on a multi-repo root that is itself a git repo**,
run `kickoff doctor --workspace --dir <root>` (idempotent) to write the marker and arm the members.
That shape was previously unreachable and is never inferred, so nothing will do it for you.

## core-v0.24 — 2026-08-04

**A workspace root — one folder holding N sibling repos — adopted cleanly and armed nothing.** The
root is not a git repo, so there was no hook to install: `kickoff adopt` returned 0, wrote the gate
config, printed a green summary, and every commit in every member landed with no secret scan. A
live 5-repo org adopted on core-v0.23 and got exactly that. Both halves of the machinery — the
gates and the scanners — now follow kickoff onto a multi-repo root.

- **`kickoff adopt` arms every member.** A root with no `.git` gets `.kickoff/lefthook-member.yml`
  (member-scoped, with member-relative commands); each member gets a `lefthook.yml` that
  `extends: ../.kickoff/lefthook-member.yml`; and each member's git hooks are armed and **recorded
  under `<member>/…`, so `kickoff eject` reverses them**. A member cannot simply extend the *root's*
  gate file — its commands are root-relative and resolve to missing files inside a member (exit
  127), which bricks every commit there rather than gating it.
- **The verdict is read back from the filesystem, and zero gated members is a hard failure** —
  `adopt` exits 1 rather than report success over N unguarded repos. The hooks directory is resolved
  with `git rev-parse --git-path hooks`, which honours `core.hooksPath`; `--git-common-dir` does
  not, so the old code wrote into `.git/hooks` in a `.husky` repo and then reported that repo ARMED.
  Unverifiable never maps to gated (a repo cloned after its adoption has no hooks — git does not
  clone them), and a `pre-commit` whose only mention of `lefthook` is in a comment no longer counts.
- **`scan-secrets` and `scan-structure` fan out across members.** From a multi-repo root both
  scanners previously refused outright — the right failure direction, and it meant a workspace org
  had no secret scan and no structural scan at all. Fail-closed is preserved at both ends: a root
  with zero members still refuses, an unreadable directory is named rather than silently skipped,
  and any member that fails fails the whole run.
- **A real fail-open in that fan-out is fixed.** It forwarded none of its own flags to the members,
  so `scan-structure --strict` was silently dropped and HIGH findings stopped failing the run — a
  pre-push gate asking for `--strict` got an advisory pass, from a workspace root, with no signal.
- **Fewer false HIGHs.** `${VAR}` counted as a placeholder but Makefile/shell `$(VAR)` did not, so an
  ordinary env-driven Makefile produced four HIGH findings. That would hit every adopter with a
  Makefile, and a first run that cries wolf teaches an operator to ignore the gate. The negative
  control still holds: a real key in the same repo is caught.

**Two DELIBERATE behaviour changes, both toward refusing rather than pretending:**

- **A linked worktree is no longer armed.** Its hooks live outside the worktree, so arming it wrote
  into a tree the adopt does not own — and it was done UNRECORDED, which meant `kickoff eject` could
  not reverse it. It is now refused, out loud, instead.
- **A single repo with a global `core.hooksPath` now gets a refusal** where it previously got a green
  `✓ ARMED` over a hook git never runs. Nothing about your actual gating changed — the report stopped
  lying about it.

**Still open, stated rather than hidden:**

- **`kickoff verify` has no workspace awareness.** On a workspace root it warns about the root and
  says nothing about the members. It over-warns rather than under-warns, but it will not tell you
  which member is ungated — read the `adopt` / `kickoff doctor` workspace summary for that.
- **The root-level analogue of the "armed but inert" hole is untouched.** If your own root
  `lefthook.yml` carries its own `extends:` key, the kickoff wire is deferred, the hooks are still
  armed, and `verify` reports ARMED over a config that resolves to zero gates. That check was closed
  inside the *member* path only — the choice that kept single-repo behaviour byte-identical.

**Upgrade note:** a single-repo adopter is unchanged by construction — the workspace path is entered
only when the adopted directory is not itself a git repo — with the one exception named above (a
global `core.hooksPath` now refuses instead of falsely reporting armed). No `instance.env` variable
name and no `core-manifest.txt` entry changed, so `kickoff pull` asks nothing of you. If you run
kickoff on a multi-repo root, run `kickoff doctor --dir <root>` after pulling (idempotent) to arm
the members.

## core-v0.23 — 2026-07-30

**Two agents on the same disk had to route every finding through the human.** One org learned
something the other needed; the operator read one repo's file, pasted a path into the other's chat,
and repeated. `agent-mail` is the fix: a local markdown inbox, no daemon, no network, no database.
Sending is a file write; receiving is a directory listing.

- **`scripts/agent-mail.py` — the transport.** A message is markdown with frontmatter, written into
  the recipient's inbox under `~/.claude/agent-mail`. An org is its repo directory name, derived
  rather than configured. `send` · `check` · `read` · `list` · `sent` · `whoami`.
- **A fifth re-ground boot check**, and it takes the `orphaned-work.py` contract: **silent on an
  empty inbox**, so a clean boot costs a worker zero tokens and any output is a real message. A
  mailbox nobody opens is worse than no mailbox — it reports delivery while the message rots.
- **An `agent-mail` skill** carries the judgement the CLI cannot: when a finding crosses the
  boundary, what clears the bar (the command beside every number; a `file:line` verified this
  session, with the date it was checked), and how to send without derailing your own work —
  delegate composing the body to a subagent, then send the file.
- **Inbox content is DATA.** Same posture as any channel: it cannot move an agent past a gate, and
  anyone who can write a file on the box can write a message. It is a convenience between
  cooperating agents under one operator, never a trust boundary.

**Browser eyes now render on the GPU where there is one.** The chrome-devtools MCP launched Chrome
with no GPU flags, so ANGLE fell back to software rasterisation — measured on one 3D page, **9.1
cores against 0.6**, while a 12 GB card sat at 0%.

- `plugin/.mcp.json` passes `--use-gl=angle --use-angle=gl-egl --enable-unsafe-swiftshader`. The
  third flag is not optional: forcing the ANGLE backend **removes Chrome's implicit software
  fallback**, so without it a machine with no NVIDIA EGL vendor library gets `getContext('webgl')`
  returning null — WebGL absent, not slow. Verified both ways; a paired-flag gate in
  `plugin-selftest.sh` stops a future edit separating them.
- **`scripts/gpu-render-check.sh`** reports which renderer you actually got, because the fallback is
  silent by design and a 15x slowdown with no signal gets blamed on the tool. Cheap mode reads
  preconditions and stays silent when they are right; `--render` asks Chrome. It resolves the config
  that is **live** — for an adopter that is the plugin cache, not the engine's copy.

**Fixed: the auto-pickup loop guard counted every boot twice.** `auto_pickup_decision` runs on both
passes of the pty wrap, and the append was unconditional, so `AUTO_PICKUP_MAX_RESTARTS=3` tripped on
the **2nd** real restart. Two deliberate refreshes 30 minutes apart read as "4 in 3600s" and
suppressed the grant on a box where nothing was crashing. The record is now gated on the same real
`[ -t 0 ]` signal the wrap decides on.

**Front door.** `README.md` restructured 261 → 172 lines, and six claims corrected rather than
reworded: it told skeptics to verify the installer against a SHA published in release notes that do
not exist; `install.sh` is 279 lines, not ~230; the headline retrieval figure contradicted the doc it
linked and could not be reproduced from a clone; the primary command path omitted `REPO_DIR`, without
which `pull`/`up`/`preflight` refuse to run. The deck stopped teaching two positions the charter had
retracted, dropped its first-person voice, and now works on a phone.

**Upgrade note:** nothing here changes an existing adopter's behaviour on pull. `agent-mail` adds one
silent boot check; the GPU flags are inert without a GPU and keep working software rendering.

## core-v0.22 — 2026-07-26

**A worker that has to be re-authorised on every restart makes the operator the bottleneck it was
supposed to remove.** Rule (6) has always been await-a-steer: the worker announces itself and stops.
That is right for the first restart and wrong for the tenth — the tracker already says what is
authorised, and the operator ends up re-saying it. `AUTO_PICKUP=1` lets a fresh worker **continue** an
`in_progress` item the tracker already authorises. It is the most consequential switch in the engine,
so most of it is refusals, and **every guard is enforced in the engine before the session starts** —
a prompt can be reasoned around; a decision computed in bash cannot.

- **Off by default, and a non-truthy value reads as off.** Nobody inherits this by upgrading.
- **The crash-loop guard, which is the one that matters.** "Auto-resume" and "restart loop" are the
  same event seen from opposite ends: a worker that dies and resumes on every boot re-does the same
  work and bills for it with nobody watching. Above `AUTO_PICKUP_MAX_RESTARTS` (3) starts inside
  `AUTO_PICKUP_WINDOW` (3600s), the grant **revokes itself** for that boot and the prompt carries the
  reason so the worker tells the operator instead of quietly behaving like the default. `announce.count`
  could not serve as the signal — it is a lifetime counter with no timestamps, so it cannot tell ten
  restarts over a week from ten in an hour; hence a bounded `.kickoff/restart-history`.
- **It announces which world you are in.** "Worker back" reads as *waiting for you*, so an armed
  worker's restart ping says so and the prompt requires it to **name the item before starting it**. A
  suppressed grant is named too, with its reason.
- **The operator's kill switch wins.** `touch .kickoff/auto-pickup-off` beats the knob, always — a
  phone-only operator has no terminal, so it is a file the coordinator creates on request.
- **It cannot be armed from `instance.env`.** Same rule as `PERMISSION_MODE`: that file is gitignored
  and invisible in review, so it may *configure* a worker but must never *arm* one. Arming happens in
  the launch environment. The suite pins this — if `AUTO_PICKUP` ever joins that whitelist it goes red.
- **What the granted prompt actually permits:** only a written-down `in_progress` item (never a backlog
  idea, an inference, an `approval_needed`/`your_action` item, or anything Blocked); **nothing gated,
  ever** (spend · destruction · shared-remote push still stop and ask); read salvaged work rather than
  re-running it; **one item, then report and wait**; and ambiguity is a steer request, not a judgement call.

Proof: `scripts/auto-pickup-selftest.sh` (**27**, hermetic — the real decision unit is extracted from
`session-run.sh` and the extraction is asserted non-vacuous) plus `scripts/reground-prompt-selftest.sh`
(13). Mutation-audited: disabling the loop guard reds 6 assertions. The negative control proves the
guard distinguishes a loop from ordinary restarts spread over days — without it, a lifetime counter
would look identical.

**Adopters:** `kickoff pull` changes nothing on its own — auto-pickup is off until you arm it at
supervisor launch (`AUTO_PICKUP=1 bash scripts/start-supervisor.sh`, or via
`KICKOFF_ENV_KEEP="AUTO_PICKUP"`). And a supervisor keeps its old code until it restarts, so arming
means cycling it.

## core-v0.21 — 2026-07-26

**Writing the gate config was never wiring — and an adopter paid for that in silence.** `adopt`
authored `lefthook.yml` + `.kickoff/lefthook-kickoff.yml` and then left *arming* them to the
external `lefthook` binary. On a machine without that binary — the default — a repo could be fully
adopted, pass `verify`, and commit through **no gate at all**: the config on disk, nothing executing
it. The adopters that did have working hooks only had them because their own `package.json` happened
to carry lefthook as a dev dependency. Found live 2026-07-26: one adopter had been committing
unguarded since the day it was adopted, and `kickoff doctor` run against it reported *"nothing to fix
— already healthy."* The origin repo had already paid this bill once, when a real private key rode in
through `git add -A` because the pre-commit secret scan had never been wired.

- **The engine arms the hooks itself.** A new `scripts/templates/kickoff-hook-runner.sh` ships and is
  installed by `adopt` / `doctor` whenever nothing else has armed the repo. An already-armed hook is
  never touched (lefthook-generated or ours — the adopter's arrangement wins), a real `lefthook` on
  PATH still gets to generate its own, and an adopter's *own* `pre-commit` is reported rather than
  overwritten. Everything written is recorded in the adopt manifest, so `kickoff eject` reverses it.
  The hooks dir resolves via `--git-common-dir`, not the worktree-local `--git-dir`.
- **The runner follows `extends:`, which is the whole point.** An adopter's root `lefthook.yml` is
  usually *just* `extends: [.kickoff/lefthook-kickoff.yml]` with **zero** `run:` lines. A runner that
  reads only the root file resolves nothing, prints "nothing to run" and exits 0 — a hook that gates
  nothing while reporting success, which is the same failure one layer deeper. It now follows the
  extends chain, reports a missing extends target loudly, and treats **zero resolved gates as a
  finding**, never a quiet pass.
- **`verify` asks the question the system actually depends on.** "Are the hooks installed?" used to be
  asked *only* when the lefthook binary happened to be on PATH — so on a machine without it the
  question was never asked at all, and a config-present-but-inert repo produced the same soft warn as
  a fully armed one. The binary is an implementation detail of the answer, not a precondition for
  asking. An unarmed repo is now a named warning that says commits are landing with no secret scan.

Proof: `scripts/adopt-selftest.sh` (**359**, 8 new — including that the armed hook reaches the
*extended* gate, that the zero-gate state never appears on a wired repo, that the install is
recorded, and that an adopter's own hook survives), `scripts/doctor-selftest.sh` (31),
`scripts/eject-selftest.sh` (126), `scripts/adopt-incomplete-selftest.sh` (23). One pre-existing
assertion was **inverted on purpose**: adopt-selftest used to demand that a missing lefthook merely be
*named*, which encoded the bug as the contract — it went red the moment the behaviour was correct.

**Adopters:** `kickoff pull`, then **`kickoff doctor` once** — that is what arms the hooks on a repo
adopted before this release. Check it worked by committing anything: you should see a
`kickoff-hooks: pre-commit — N gate(s)` line. If you see `resolved ZERO gates`, the wiring is broken
and doctor will say so. No `instance.env` name and no manifest file was removed.

## core-v0.20 — 2026-07-26

**A give-up with no floor turns a transient blocker into an outage that ends only when a human looks.** On 2026-07-24 at 21:43 two workers restarted inside a ~2-minute bad window and their Telegram bridges never came up. The v0.6 belt did everything right — detected, escalated, wrote the durable flag, alerted the operator (he confirmed receiving it), did its one guarded retry — and then latched `BRIDGE_BOOT_GIVEUP=1` **permanently**. Both workers sat DEAF (computing, but unable to reach the operator at all) for 26 minutes, ending only because a human counted his bots and touched the refresh flag by hand. Every worker that restarted at 22:00–22:02 got its bridge on the *first* try: the blocker was **transient**. Six changes, all in the supervisor:

- **The permanent give-up is now a widening backoff that never stops.** After the existing `BRIDGE_BOOT_RETRY_CAP` fast retries, `bridge_boot_check` keeps retrying on a doubling interval — **10m → 20m → 40m → a 60m ceiling, then at that cadence indefinitely** (reason `bridge-neverup-backoff`, which `refresh()` classes as `bridge-*` so the ladder survives its own refreshes). `BRIDGE_BOOT_GIVEUP` is **deleted**. New knobs: `BRIDGE_BOOT_BACKOFF_START` (600) and `BRIDGE_BOOT_BACKOFF_MAX` (3600), both clamped. The trade is deliberate and stated: **a refresh KILLS the session's in-flight work** — acceptable precisely because a deaf worker cannot report in-flight work to anyone anyway. An instance that legitimately has *no* bridge must set **`BRIDGE_LIVENESS=0`** (it short-circuits the whole belt); no second "park forever" switch was added, because that switch is what the bug was.
- **The RETRIES are capped; the ALARMS never are.** Deleting the give-up fixed the transient case and broke the persistent one: a channel that can *never* satisfy the belt — a foreign consumer holding this bot's `getUpdates` slot, a channel with no bot token (preflight has zero token checks) — would take a session-killing refresh roughly every hour, forever. v0.19 lost the channel; an uncapped v0.20 would lose the **work**. So the two halves are now separated by cost: after `BRIDGE_BOOT_BACKOFF_REFRESH_CAP` (**6**, ~4h on the default ladder) backoff-tier refreshes have demonstrably failed to help, **restarting retires** — while the ladder keeps walking as an alarm clock, re-pinging on the same widening cadence under its own label (`bridge-backoff-capped`) with a payload that says plainly that nothing automatic will fix this now and names what a human should check. This is **not** the deleted give-up: that one went permanently *silent* and abandoned recovery; this one abandons only the destructive action and never stops telling you. The cap is clamped 1..1000 (0 would delete the recovery action itself; a huge value is the unbounded loop under another name) and is **re-validated at its point of use**, because the globals-block clamp sits outside the `KICKOFF-BRIDGE-UNIT` markers the hermetic selftest extracts — a floor the suite cannot reach is a floor that rots silently.
- **Work that outlived its session is now findable — because none of it was ever actually lost.** An abrupt end (a spend/usage limit, a refresh, a hard reset) looks like it destroys in-flight agent work. It does not: Claude Code persists every subagent transcript, and each workflow agent's return value, under `~/.claude/projects/<proj>/<session>/subagents/` **incrementally and hook-free** — so it survives a `SIGKILL`, and living under `$HOME` it survives a reboot. What was missing is that **nothing read it**: the next session re-grounds from `CLAUDE.md` + memory + the tracker and cannot know that six finished agents are sitting on disk. `scripts/orphaned-work.py` closes that (list · `--why` per-agent fate, including the vendor limit notice a killed agent leaves as its own last message · `--dump` to file results under a tracker item), `mc-update.py render-tracker` surfaces filed checkpoints under the item they belong to — and under their own heading when they match none, since a salvage nobody surfaces is the write-only file this path exists to avoid — and the re-ground prompt runs the check at every boot, **printing nothing on a clean box**. The join key is the **verbatim** tracker-item text in the checkpoint's front matter, never the directory slug, so re-wording an item moves where new checkpoints land without orphaning the ones already filed. This deliberately replaces an earlier `SubagentStop`-hook design: a hook cannot fire on the death that matters.
- **The operator gets re-pinged while the outage runs.** Previously: exactly one alert, then permanent silence. Now a distinct `bridge_backoff_alarm` re-fires every `BRIDGE_BOOT_REALARM_EVERY` (default 3) backoff retries, carrying how long the worker has been deaf and when the next attempt lands. Bounded — silence and spam are the same bug. The once-per-outage escalation alarm is unchanged. Note the cadence is counted in *retries*, so with the defaults the re-pings land at roughly **+70min, +4h10m, +7h10m** (plus the per-tier jitter below, which only ever adds).
- **A Telegram send is finally OBSERVABLE.** `tg_send_tokenless` was entirely silent (`-o /dev/null`, `|| true` on every step, no log line): a **failed** alarm left zero trace in a 10MB log, and the only reason we know the 21:43 alert landed is that a human remembered receiving it. It now logs `delivered`/`FAILED (HTTP nnn)` and names the skip reason when jq/curl or the config are missing. The bot token lives in the URL, so the leak constraints are held explicitly (`-o /dev/null` kept, curl's stderr kept suppressed, `%{http_code}` sanitised to digits before logging) — and the negative control that proves it is a **hostile** curl stub, not a clean one: it returns a non-numeric body carrying the fake-token sentinel *and* echoes the token-bearing URL on stderr, with the scenario redirecting its own stderr into the log because that is production's real topology. Deleting either the sanitiser or curl's `2>/dev/null` now goes red; against the first (clean-stub) version of this control, both survived deletion silently. Still non-fatal, still inert without tooling — but inert now *says so*.
- **Recovery leaves a breadcrumb instead of amnesia — written in TWO phases so it cannot lose its own race.** The outage window (start read from the flag's own durable ISO timestamp, plus end and duration) lands in **`.kickoff/bridge-outages.log`**, bounded to `BRIDGE_OUTAGE_LOG_KEEP` (20) lines. Writing it *only* on recovery was a race: the sole writer was the healthy first-seen latch, which needs `bridge_present` to succeed, so the recovered session's re-ground announce could run **before** the crumb existed. The row is now **OPENED** at the instant a recovery refresh is issued (provably before the new session exists) and **RECONCILED in place** on recovery — one outage owns exactly one row however many retries it took, and recovery *without* a refresh still just appends a complete row. The cost, stated plainly: the last row can describe an outage still in flight, and a supervisor killed mid-outage leaves an OPEN row nobody closes (which is honest — "deafness started here, end unknown"). `session-run.sh`'s re-ground prompt is the **consumer** and reads both shapes; that read is now **asserted** (`reground-prompt-selftest.sh`), because deleting the clause left every other suite byte-identically green — the `.kickoff/secret.env` failure shape exactly. (An adopter who overrides `REGROUND_PROMPT` in `instance.env` does not inherit the clause.)
- **A live bot.pid inside our OWN session tree is now its own state, not a footnote.** That is positive evidence the bridge *exists* and only `bridge_present`'s argv pattern missed it (a telegram-plugin launcher rename does exactly this). v0.9 logged that fact and then discarded it into the retry path — which the permanent give-up used to bound to one wasted refresh, but which with the give-up deleted would cost a **session-killing refresh every 60 minutes forever**, plus recurring false "bridge NEVER came up" alarms sent over the bridge that is demonstrably delivering them. It now escalates and alarms **once** (the state is genuinely degraded, and the operator is reachable, so a human can act) and then stops: no retry, no armed ladder, and a distinct log line naming the real fix (`bridge_present`'s signature, not a restart).
- **The ladder is jittered, because deaf workers arrive in cohorts.** The 07-24 incident took two workers down in the same ~2-minute window; a shared cause makes that the normal shape, and a fully deterministic ladder then cold-starts every affected worker at the same instant forever. `bridge_jitter` spreads each due-at by up to a tenth of the interval (hard-capped at 300s). It is a **seam** for the same reason `bridge_now` is — the hermetic scenarios pin it to 0, so it can never make an assertion flaky, while one scenario drives the real one and asserts its bounds, its variance and its clamps.

Proof: `scripts/supervisor-liveness-selftest.sh` (**106** assertions, RED-on-old enforced — the backoff is driven through a `bridge_now` clock seam, so an 8-hour outage runs hermetically in milliseconds), `scripts/auth-heal-selftest.sh` (132, including the `refresh()` → `bridge_boot_reset` wiring assertion), `scripts/reground-prompt-selftest.sh` (13) and `scripts/bridge-reap-selftest.sh` (29). Every guard added here was proven by **mutation**: the reviewer's `bridge_now() { printf 0; }` (which made the whole belt permanently inert in production while the suite stayed green), the neutered `DEAF_SINCE` latch (which reported "~86m deaf" where the truth was 70m), the deleted quiet gate, the deleted `%{http_code}` sanitiser, the deleted curl stderr guard, the deleted `_e -ge _s` sanity guard and the deleted breadcrumb consumer were each re-applied and each now goes red. **Honest scope: the retry path has never been observed retrying on a real deaf worker** — the ladder is asserted against a stubbed clock and a stubbed process tree only, and the signature-miss branch has never been observed on a real launcher rename. And as with every supervisor change, this is **DORMANT on a running supervisor until it restarts** (one long-running bash keeps the old inode); a `kickoff pull` alone changes nothing.

The salvage path is covered by `scripts/orphaned-work-selftest.sh` (**25**, hermetic — a fake `$HOME` with its own `~/.claude/projects` tree) and mutation-audited in both directions: disabling the render's checkpoint index turns 5 assertions red, and breaking the boot check's silence-on-a-clean-box turns its negative control red. `reground-prompt-selftest.sh` was extended to recognise `.py` boot checks at all — it matched only `*.sh`, so the first Python one would have bypassed its manifest-travel and deploy assertions and shipped **inert to every adopter** while the suite stayed green.

**Adopters:** `kickoff pull` brings the refresh cap, the observable Telegram send, the outage breadcrumb, and the salvage path. Two behaviours to know: a persistently deaf worker now stops being restarted after ~4h but keeps alerting you (set `BRIDGE_LIVENESS=0` to silence a channel you have decided not to fix), and `.kickoff/checkpoints/` + `.kickoff/active-item` are new runtime paths the generated `.gitignore` excludes. **The supervisor changes are dormant until each supervisor restarts.**

## core-v0.19 — 2026-07-24

**The release that walked the adopter's path.** Every fix below came from one real person running two stock commands on a repo the engine had never seen — the gap the origin repo structurally can't exercise, because in the origin the engine *is* the repo (paths resolve, the env is pre-set, the trust dialog was answered months ago). The findings were **silent**: gates that never armed, scanners that passed an empty tree, a board that was written to but never served, a half-finished adopt that looked done. This release closes them and adds a **repair verb** so a repo that adopted before the fixes can be brought up to standard in one command.

- **`adopt` wires the safety machinery mechanically — no agent turn required.** The generic gates (`scan-secrets` · `scan-structure` on the git hooks) and the memory-retrieval index are now written by the adopt script itself, at adopt time. Previously they depended on a coordinator session actually running the wiring step; if it didn't, the adopter shipped with the gates inert and recall dead. Now recall fires from day one and the commit/push gates are armed the moment adopt finishes.
- **`kickoff doctor` — the idempotent repair verb.** Back-fills an *already-adopted* repo's missing generic gates + memory index (the "pulled a newer core but never re-ran the wiring" shape). It records exactly what it creates (so `eject` reverses it), refuses a non-adopted directory, and never clobbers or re-records on a second run — run it as many times as you like.
- **A half-finished adopt is flagged LOUDLY, never silently broken.** `verify` and `preflight` now raise an `ADOPT-INCOMPLETE` banner on an abandoned-but-active adopt (missing tracker / unwired hooks), while a legitimate fresh adopt stays green *and* bootable. The hard guard: this is never a startup-breaking refusal — `preflight` runs at every supervisor start, so it warns, it does not wedge the worker.
- **The scanners fail CLOSED.** `scan-secrets` / `scan-structure` now `cd` into the repo root and fail *loud* on an empty or failed git file-listing, instead of scanning nothing and printing a green. A scanner that can't see the tree is a failure, not a pass.
- **Adopter shims sealed against ambient env.** The mission-control / memory shims unset any inherited `MC_STATE_FILE` / `MEMORY_*` after pinning `REPO_DIR`, so a shim invoked inside another repo's environment can't write to the wrong store.
- **`kickoff up` brings up the Mission Control board.** The board is now served automatically and idempotently on start — a free port is picked (occupancy pre-checked), the serve-status is read *first* so a mapped port is never clobbered and a bare `:443` is never taken, it fails soft if exposure isn't available, `--dry-run` starts nothing, and the token is never printed. Being written to but never served was why the board could sit dark for a week.
- **Safe expose discipline.** `share` / expose never publishes a bare root and uses an exact-match occupancy gate before taking a port.
- **Memory recall hardening.** The no-index breadcrumb survives a first run (its log parent is created), `memory-orphan-check` is scoped to live repos that have their own index (killing the shared-box false-positive storm at session start), and runtime markers are ignored by the index.
- **`eject` reverses the root `lefthook.yml` it created.** When adopt creates a root `lefthook.yml` (a repo that had none), `eject` now deletes it if unchanged or keeps it if you diverged it — via a content-hash gate. Previously it was left behind, dangling its `extends` after `.kickoff/` was removed.

Covered by new RED-first suites: `adopt-incomplete-selftest.sh`, `doctor-selftest.sh`, `board-serve-selftest.sh`, `share-occupancy-selftest.sh`, `shim-env-seal-selftest.sh`, `memory-recall-hygiene-selftest.sh` (all hermetic — mktemp fixtures + a scratch core, no real tailscale/DB ever touched).

**Adopters:** `kickoff pull` brings the mechanical gate-wiring, the `doctor` verb, the board auto-serve, and the recall/scanner hardening; the plugin bump (**0.3.13 → 0.3.14**) is required or `pull` fails closed at preflight #8. Purely additive — no `instance.env` name and no manifest file was removed. After pulling, run `kickoff doctor` once to back-fill the gates + memory index your earlier adopt may have missed, then restart Mission Control to pick up the board auto-serve.

## core-v0.18 — 2026-07-23

**Plan before the agents cook.** Ideas used to jump straight to "in progress"; there was no home to capture a raw idea, and no explicit gate between "we've been talking about this" and "the agents are building it." This release adds the planning primitives — a **backlog**, named **milestones**, and a **commit** that is the operator's "what do we build next" call — into the *same single store* the board already runs on. No second board, no Jira.

- **The `backlog → milestone → commit → cook` lifecycle (`mission-control/mc-update.py`).** Five verbs, all writing the one canonical `mission-state.json`:
  - `backlog "idea" [--theme --note]` — capture an idea, uncommitted.
  - `milestone "name" [--goal …]` — name a grouping to commit to (starts uncommitted).
  - `pick <idx> --milestone "name"` — put a backlog idea into a milestone (refuses an unknown milestone).
  - `commit "name"` — **the gate.** The operator commits a milestone; it stamps `committedAt`.
  - `launch "name"` — dispatch a committed milestone's ideas into `in_progress`. **It REFUSES an uncommitted milestone** — the gate is a mechanism, not a convention, so agents can never cook a milestone the operator hasn't committed to. `render-tracker` gains Backlog + Milestones sections.
- **Commit from your phone (`mission-control/server.py`, `mission-control/dashboard.html`).** The board grows a **Backlog** panel (your captured ideas) and a **Milestones** panel — each milestone shows its goal and picked ideas with a teal **Commit** button (or a "committed" badge once you've committed, its items marked *cooking*). A new `POST /commit-milestone {index}` endpoint sets `committed` + `committedAt` — one-way (the board only commits; rolling back is a deliberate CLI action), token-gated and localhost-only exactly like the existing check-off/ship writes, on its own write path so the `/checkoff` gate is untouched. Committing goes through a confirm, because it unlocks the agents.
- **Why keep it in the one store.** The board the org writes to *is* the source the operator reads and the plan they commit — the same one-store rule that already governs the tracker. The commit is the control loop's "approve only the irreducible" made concrete: the coordinator surfaces a milestone; the operator commits it; only then does the fleet build.

Covered by `scripts/mc-milestone-selftest.sh` (RED-first — a mutant with the commit-guard removed makes `launch` cook an uncommitted milestone, proving the gate assertion is load-bearing).

**Adopters:** `kickoff pull` brings the new verbs, the board panels, and the commit endpoint; the plugin bump (**0.3.12 → 0.3.13**) is required or `pull` fails closed at preflight #8. Purely additive — no `instance.env` name and no manifest file was removed. Restart Mission Control after pulling to pick up the board panel + the commit endpoint.
## core-v0.17 — 2026-07-23

**The release that stopped writing instructions only the origin can follow.** Every headline fix below is one shape: a command, a path or a filename that resolves in *this* repo — where the engine **is** the repo — and is silently dead in an adopted one. Three shipped instances surfaced in a single week; the fourth thing this release ships is a **gate**, because each hand-fix landed on one surface while its siblings kept teaching the same motion. On top of that, the secrets channel — the way you hand a credential to your coordinator with no terminal — went from specified to **actually working phone-to-box**.

- **Channel setup no longer tells you to write the bot token to a file nothing reads (`scripts/kickoff`) — HIGH.** Two operator-facing lines in `_offer_channel_setup` (the non-interactive path, and the write-failure fallback) said to put `TELEGRAM_BOT_TOKEN` into `$TELEGRAM_STATE_DIR/secret.env`. **Nothing reads that file.** The bridge reads `<state>/.env`; the startup announce reads `<repo>/.claude/settings.local.json → env.TELEGRAM_BOT_TOKEN`. Following either instruction reproduces the exact core-v0.12 dead-file state — the bridge never authenticates, never boots, and **your org is mute with no error**. This is not theoretical: it took a live org down this week. Worse, the same function *already detected* the state ("found a token in `secret.env`, but NOT in the files the bridge and announce read") and then handed over the **wrong remedy** — a detector wired to a wrong remedy is worse than no detector. The code has written both real files since v0.13; only the prose was stale. `scripts/channel-offer-selftest.sh` now fails any operator-facing `log`/`mark_no`/`mark_warn` that names `secret.env` without naming the file that is actually read, and it discriminates: against the v0.15/v0.16 text it flags exactly the two bad instructions and not the back-compat write beside them.

- **The Mission Control skill's board-write loop resolves on an adopter (`plugin/skills/mission-control/SKILL.md`) — HIGH.** It documented the coordinator's entire board-write motion as `python3 mission-control/mc-update.py` — **ten invocations**, never once naming `.kickoff/bin/mc`. In an adopted repo `mission-control/` lives in the pinned core clone, not in your repo, so every one of those calls resolved to nothing: **the board sat empty and no error was ever printed.** core-v0.14 fixed this same bug in `.claude/agent-charter-template.md` — which since then has mandated the shim — while the skill teaching the same motion kept demonstrating the forbidden form. The skill now **branches by topology** rather than blanket-replacing: in an adopted repo use `.kickoff/bin/mc`, in this origin (and in a greenfield bootstrap) `KICKOFF_CORE_DIR` is unset by design and the repo-relative form is the correct one. A blanket "always use the shim" rule was drafted first and rejected — it is wrong in the origin and breaks every greenfield bootstrap.

- **New gate: an adopter-facing surface may not teach an origin-only path (`scripts/origin-only-path-selftest.sh`).** The two fixes above plus the decrypt-path fix below are the same class, found three times by hand. The gate scans `plugin/skills/**/*.md` and the **operator-facing prose** in `scripts/kickoff` (`log`/`mark_*`/`die` strings — engine code legitimately runs its own scripts by repo-relative path, and flagging that is the false positive that gets a gate switched off). A line fails if it invokes an engine artifact bare (`python3|node|bash|sh` + `mission-control/*.py` or `scripts/*.{sh,mjs,py}`, not via `$KICKOFF_CORE_DIR/` or `.kickoff/bin/`) or names an instance-state path bare (`mission-control/{secrets-inbox,.mission-token,mission-state.json}`, not under `.kickoff/state/`) — **unless the enclosing passage is topology-branched**, i.e. gives the adopter form too. On its first run it found **five more instances in four files no hand-fix had touched**, including the `scan` skill teaching `bash scripts/scan-secrets.sh` while `kickoff` generates `.kickoff/bin/` shims for exactly those two scanners. **Honest about its strength:** two adversarial passes rated it EVADABLE. A green means *no known-shape violation*, not *proven clean* — section-keyed branch markers can over-broadly excuse a passage, the rule kinds are matched else-if so a line matching one rule skips the other, and `plugin/agents/**` and `plugin/hooks/**` are out of scope. Hardening is queued; the three real pre-fix texts are wired as RED controls so it cannot silently stop catching what it already caught.

- **The secrets channel works phone-to-box, and the keypair is per-project (`scripts/secret-keydir.mjs`, `scripts/secret-box-keygen.mjs`, `scripts/secret-decrypt.mjs`, `mission-control/server.py`, `scripts/kickoff`) — HIGH.** The channel exists so you can hand over an API key with **no terminal**. On an adopter it could not do that at all: nothing ever created the keypair, and every command handed to the coordinator used paths that resolve only here. Now:
  - **The keypair is provisioned automatically** by `kickoff adopt` and by Mission Control startup, and it is **per-project** — `dirname(<instance state>)/secret-box`, the same INSTANCE_DIR anchor core-v0.14 gave `.mission-token` and `secrets-inbox/`, so it lands under `.kickoff/state/` which your generated `.kickoff/.gitignore` already covers. The old machine-wide `~/.kickoff/secret-box` is **not** silently fallen back to: a shared keydir means project A's `allowed-keys.json` — which pins the destination `.env` — governs project B's **writes**.
  - **One rule, one definition, mechanically enforced.** "Every consumer resolves the same keydir" used to be a *sentence* in a brief, implemented three times (two Node, one Python — `server.py` must resolve without node, since node is advisory here). Within a single slice the copies disagreed four ways, each of which fails **green**: the board encrypts to key A, the coordinator decrypts with key B, and every fingerprint, permission and HTTP check in between still passes. `scripts/secret-keydir.mjs` is now the one definition, and `scripts/secret-keydir-conformance-selftest.sh` holds the stdlib-Python copy to it over a 19-cell environment matrix. It caught its own authors on the first run.
  - **A torn keypair is unrepresentable.** `secret-box-keygen.mjs --ensure` is idempotent and takes an `O_EXCL` mutex on `private.pem`, so only the winner writes the public half. On an inconsistent or mismatched keydir it **refuses** (exit 3) and never auto-repairs — "repair" there means deleting a private key, i.e. every secret ever provisioned to it.
  - **A handed-over secret is no longer silent.** `store_secret` used to write the ciphertext and tell nobody while a 24h TTL swept it: you tapped send, saw "ok", and the secret vanished — after you had plausibly deleted your own copy. Arrival now posts to the board's activity feed (a **label only** — no ciphertext, no wrapped key, no PEM reaches `mission-state.json`), best-effort by construction so a feed write can never turn a stored secret into a reported failure.
  - **`POST /secret` no longer returns 200 on a dead channel.** It returns 503 with a plain-English reason, from the *same* predicate the rest of the flow uses.
  - **The decrypt instructions resolve where you are.** They were bare repo-relative — wrong script path on an adopter, and a bare `mission-control/secrets-inbox/` that resolves **into the shared core clone**, i.e. a cross-project secret leak. Now topology-branched, verified on two real adopted repos.
  - **Known gaps, stated rather than buried.** `--ensure` proves `public.pem` ↔ `public.fingerprint` and only that `private.pem` **exists** — not that it is the matching half; a pairing check was built, proven to catch a grafted keydir, and then **reverted**, because stdlib Python cannot derive a public key from a private one and a Node-only check reproduced the very divergence the shared module exists to kill. A conformance suite proves *consistency*, not *correctness* — three consumers can agree and all be wrong. Mutation testing also found holes in the conformance gate itself (two loosened predicates survive it), and `mission-control/secrets.html` was reviewed on the diff and never visually rendered.

- **The "a correction deletes what it corrects" check had been inert for most of the memory store (`scripts/memory-supersede-check.sh`) — MEDIUM.** It globbed one directory level (`memory/*.md`). Once memories are split into a public set and a gitignored `memory/private/` vault — the layout core-v0.15 introduced and this repo uses — the check scanned only the top level and printed *"no supersedes: declared — nothing to enforce"* while the majority of the store went unchecked. Here that was **61% of 154 facts, silently, for two days.** It now discovers memories recursively, locates a superseded slug anywhere in the tree, and prints the **real relative path** in the contradiction message (telling someone to delete a file that is not there is how a true finding gets dismissed). Five new assertions, four of them RED-verified against the flat-glob version.

- **`kickoff pull` stopped rejecting three ordinary remote spellings (`scripts/kickoff`) — MEDIUM.** Found by a sibling org reviewing core-v0.16 **by running it on the adopter side**, which is why it caught what our own gate and adversarial pass did not. `_normalize_git_remote` stripped `.git` before trailing slashes, so `…/repo.git/` — the commonest form git accepts — failed to canonicalize and the core-clone origin guard fail-closed on a perfectly good clone. Scheme stripping was case-sensitive, so `HTTPS://` survived and got rewritten into `HTTPS///host/…`; hostnames were compared case-sensitively though they are case-insensitive per RFC. Fixed as slashes → one `.git` → slashes, case-insensitive scheme, and case-folding the **authority only** — paths stay case-sensitive deliberately, since lowercasing a whole URL makes two different repos compare equal, which is a false *accept*.

- **Two adopter-side signal bugs in the cadence check (`scripts/crew-review-due.sh`) — MEDIUM.** From the same review. `--mark` failure now prints on **both** streams (exit 2 does not survive a pipe, and `… --mark 2>&1 | tail -2` is what a real boot flow runs). And the `$PWD` fallback now **requires `$PWD/.kickoff/instance.env`** and fails loudly: it was only ever correct because the working directory happened to be the repo root, and a coordinator spanning several repos is often `cd`-ed into a sibling — where it would stamp the *wrong* project's marker, silence that project's cadence, and report nothing. Explicit `KICKOFF_DIR` / `CREW_REVIEW_MARKER` are untouched; only the guess is guarded.

- **Every skill in `plugin/skills/` is now parity-checked against its `.claude/skills/` twin (`scripts/plugin-selftest.sh`).** Exactly one skill had been checked, so the other mirrors could drift unnoticed — and had: the shipped plugin tree was ahead of the development tree in one place and behind it in another, which means **a release cut from the wrong side would have shipped a stale skill.** Default-deny with a declared allow-list for intentional divergence, plus a non-vacuity assertion.

**Adopters:** `kickoff pull` brings all of it; the plugin bump (**0.3.11 → 0.3.12**) is required or `pull` fails closed at preflight #8. Purely additive — no `instance.env` name and no `core-manifest.txt` file was removed. Four things want your attention:

- **If your bot has a token but has never pinged you**, look for a token in `<state>/secret.env` and nothing in `<state>/.env`. That is the dead-file state described above, and it is what kept the bridge from booting. Re-run `kickoff adopt --dir <repo>` and re-enter the token (you always re-enter it by hand; it is never read back), or write it to `<state>/.env` as `TELEGRAM_BOT_TOKEN=…` at mode `0600` **and** to `<repo>/.claude/settings.local.json` under `env.TELEGRAM_BOT_TOKEN`.
- **Re-run `kickoff adopt --dir <repo>` to get the secrets keypair.** It is provisioned there (and at Mission Control startup), needs **node ≥ 22**, and is a clean no-op on a re-run. Without node you get an honest warning rather than a silent no-op, and nothing is provisioned — the channel simply stays unavailable until node is installed and adopt is re-run.
- **If you already have a machine-wide `~/.kickoff/secret-box`**, adopt will **refuse to guess** and warn instead of creating anything (it will not block the adopt). Decide explicitly: run `node "$KICKOFF_CORE_DIR/scripts/secret-box-keygen.mjs" --ensure --keydir <repo>/.kickoff/state/mission-control/secret-box` by hand for a key of this project's own (that is the resolvable form on an adopter, where the engine lives in the pinned core clone — a bare `scripts/…` would not resolve), or set `KICKOFF_SECRET_KEYDIR` to the machine-wide dir to keep sharing it — knowing its allow-list and pinned `.env` are shared by every project on the box.
- **Restart Mission Control after pulling** so the server picks up the keydir rule and the 503-on-dead-channel behaviour.

- **If you generated agents or copied board-write commands before v0.17**, grep them for `python3 mission-control/mc-update.py` and repoint at `.kickoff/bin/mc`. `pull` fixes the skill and the template; it never touches `.claude/agents/`, which is yours.
## core-v0.16 — 2026-07-21

**Crew curation stops being something you remember to ask for.** v0.15 gave the crew the ability to *create* a skill; it still only ever looked at itself when a human said "run a crew-review". This release puts the *noticing* on a cadence and carries it to adopters through the boot prompt — the detection is automatic, every mutation of the crew stays behind your tap.

- **New `scripts/crew-review-due.sh` — the cadence check, wired into the adopter boot prompt (`scripts/session-run.sh`).** It answers exactly one question — *is a light crew-review triage due?* — from a marker at **your repo's** `.kickoff/crew-review.last` and a window of `CREW_REVIEW_CADENCE_DAYS` (default **7**). Boot rule 1 in `REGROUND_PROMPT` now runs it alongside the memory-lifecycle checks: on **DUE**, the coordinator runs a *light* triage at the next natural boundary — charters, skills and memory held against the recent delta — then `--mark`s it. **Where it lives matters:** adopters get their boot checks from `REGROUND_PROMPT`, not from `CLAUDE.md`, so a cadence documented only in the charter is inert for everyone but the origin repo. It ships in `scripts/core-manifest.txt` next to the memory checks, for the same reason they do — the prompt names it, so it has to travel. **Fail-toward-DUE:** a missing or corrupt marker returns DUE (a light triage is cheap; silently skipping drift is not), a future stamp from clock skew is treated as just-run, and a non-integer cadence falls back to 7. A busy session should *defer* to the next boundary, never suppress. **The marker is per-instance, and `--mark` fails loudly:** it resolves `$KICKOFF_DIR`, else `$PWD/.kickoff` — deliberately **not** the script's own directory, because on an adopter that is the *shared, pinned core clone* several repos run from, and one marker there would let the first repo to `--mark` silence the cadence for all the others. An unwritable marker exits non-zero rather than printing "stamped".
- **`CREW_REVIEW_CADENCE_DAYS` is a real per-instance knob.** Added to `session-run.sh`'s `instance.env` whitelist — without that line the variable was documented and **inert**, silently dropped before the session ever saw it — and documented in `scripts/instance.env.example`, the per-instance config contract. A fast-moving repo can set 2; the shipped default stays 7.
- **The `crew-review` skill's gardener half is now ACTIVE, and it covers charters as well as skills.** v0.15 deferred pruning until there was a library to garden. It now flags near-duplicate charters/skills, structural staleness (a cited identifier that no longer exists in the tree), and the ~15–20 tripwire — and proposes prune/merge **as a one-tap turnkey, never an auto-delete**. Only stale-**memory** data auto-applies; nothing under `.claude/agents/` or `.claude/skills/` is ever edited without the human. Honest limit, stated in the skill: there is no usage telemetry here, so it flags on *overlap*, not on "nobody ran this".
- **New shipped skill: `diagnose-fail-closed-upgrade`.** The first skill this system distilled from its own recurring work (a `crew-review` run, adversarially vetted, human-approved). It encodes the triage motion for a `pull` / `up` / preflight / engine-hop that fails **closed**: reproduce the gate one-shot with `preflight.sh` (never `up --dry-run`, which loops on a pass), read the exact `[FAIL]` line rather than the exit code or the turnkey's guess, trace the tripping guard, then split *root-cause fix* (the guard) from *config fix* (a stray `core.lock`, a bad pin, the wrong remote) and verify RED→GREEN. It rides the `plugin/skills` channel, so `kickoff pull` + the plugin bump is all you need.
- **`kickoff pull` no longer rejects a core clone over the "wrong" transport (`scripts/kickoff`) — MEDIUM.** The core-clone origin guard compared remote URLs with a literal `!=`. A fleet that *shares one core clone* while its repos disagree on transport (one adopter cloned over https, another set an ssh `KICKOFF_CORE_REMOTE`) hit an **unsatisfiable** guard: fixing one adopter broke the other, and the only escape was moving the clone aside. A new `_normalize_git_remote` reduces any transport to `host/path` (`git@github.com:org/repo.git`, `https://github.com/org/repo.git` and `ssh://git@github.com/org/repo` all become `github.com/org/repo`) and the guard compares the normalized forms. **Conservative by construction:** it can only make same-repo/different-transport URLs equal — a different owner, name or host still fails closed, and any exotic form it doesn't reduce stays unequal, i.e. the safe direction. The userinfo strip is **anchored to the authority**: an unanchored one would delete through any `@` in the *path*, so `https://evil.com/a@github.com/org/repo` would reduce to the canonical string and the guard would **accept a clone of a different repo** — the one direction a fail-closed guard must never move. Covered by `scripts/remote-normalize-selftest.sh` (15/15: a RED control, negative controls, and five hostile-URL controls); like every suite here, the selftest itself does not travel.

**Adopters:** `kickoff pull` brings the new check, the manifest entry, the gardener update and the new skill; the plugin bump (**0.3.10 → 0.3.11**) is required or `pull` fails closed at preflight #8. Purely additive — no `instance.env` name and no manifest file was removed. The first session after the pull will report **DUE** (no marker yet) and run one light triage; that is expected, not a bug.

## core-v0.15 — 2026-07-20

**The crew can now distill a recurring procedure into a skill of its own — the creation half of a self-improving loop.** Recall and storage were already free (Claude Code lists any `SKILL.md` by its `description` and invokes it via the Skill tool); the missing piece was *noticing* a procedure the crew keeps re-doing by hand and crystallizing it into a native, **human-gated** `.claude/skills/<name>/SKILL.md`, the way a new agent accretes to `.claude/agents/`.

- **New `.claude/skill-template.md` — the sibling of `.claude/agent-charter-template.md`.** A new skill is authored from it: byte-0 `name` + `description` frontmatter (the `description` is the whole recall surface — Claude Code auto-lists and invokes by it), then an Overview → When-to-use → motion → Pitfalls → Verification skeleton. It travels in `scripts/core-manifest.txt`, so `kickoff pull` brings it to your repo alongside the charter template.

- **`crew-review` gains the skill-CREATION branch.** Its "Evolving the system" signals were missing the third system-evolution move: alongside *propose an agent* and *bake a correction into a charter*, a **reusable procedure the crew keeps re-doing → distill it into a skill**. The new "Distill a recurring procedure into a skill" section spells out the guardrails — crystallize **only** what is recurring (~2–3×), generalizable, and not already covered (dedupe against `.claude/skills/`, refuse on overlap; producing nothing is the correct outcome when nothing qualifies, and under-use beats clutter); draft it **native** to this substrate (never a foreign agent's tool names); and land it **behind the human gate** (a `wire-*.sh` turnkey or a present-draft-then-accept), never a silent auto-write and **never a Stop/SessionEnd hook** — a new skill is a procedure the whole crew will load and obey. Accepted skills land adopter-local in `.claude/skills/`, not the pinned `plugin/skills/` release channel.

- **The adopter coordinator charter (`scripts/templates/KICKOFF.md`) gains an "Evolving the system" section.** Regenerated into `.kickoff/KICKOFF.md` on `kickoff pull`, it now lists the crew's self-evolution moves — propose an agent, **distill a skill**, bake a charter correction, split — so an adopted repo's coordinator natively knows the capability, and `crew-review`'s reference to those signals resolves in the adopter's own charter (it had pointed at a section adopters never had).

The gardener half (pruning/consolidating a grown skill library) is deliberately deferred until there is a library to garden; a tripwire at **~15–20 skills** marks when to build it.

**Adopters:** `kickoff pull` brings the template + the crew-review update; the plugin bump (**0.3.9 → 0.3.10**) is required or `pull` fails closed at preflight #8. No `instance.env` names or manifest files were removed — this is **purely additive**, nothing breaks.

## core-v0.14 — 2026-07-16

**The release the adopted repo wrote.** v0.12 was the release a real adopter found the bugs in; this is the one where the adopted repo's *own coordinator* found them — reading kickoff's template to write its crew, and flagging two of these unprompted. Every fix here is one shape: **it resolves in the kickoff origin, where the repo IS the core, and is silently dead in an adopted repo.** Two of them are v0.12's and v0.13's own fixes failing that exact way again.

- **`kickoff adopt` re-asks for a bot token when the channel isn't actually wired (`scripts/kickoff`) — HIGH.** v0.13 moved the token to the two files that are read and told anyone stranded by v0.12 to re-run `kickoff adopt`. **That repair could never run.** The "is a token configured?" sentinel still tested `secret.env` — the dead file v0.12 wrote and nothing reads — so adopt reported `✓ channel: a bot token is already in place — left untouched`, skipped the prompt, and left the two real files missing. Every box that ran v0.12's channel setup was **permanently unfixable by the documented remedy**. The sentinel now tests `.env` (the bridge's copy) and `env.TELEGRAM_BOT_TOKEN` in `.claude/settings.local.json` (what the announce reads); a token found only in `secret.env` gets a plain explanation and a re-ask. The old token is never read back or reshaped — **you re-enter it by hand**, the same posture as every other credential here. v0.13's bug wearing the check's clothes: the write was verified with the write's own artifact.

- **`kickoff adopt` honours the repo's pin (`scripts/kickoff`) — HIGH.** `cmd_up` re-execs the engine `core.lock` names; `cmd_adopt` had no redirect. So **`kickoff pull` followed by `kickoff adopt` — the obvious repair sequence — silently ran two different engines against one repo**: the pull correctly moved `core.lock` and `instance.env` to the new tag, then adopt ran whatever front door you typed, which for anyone repairing a channel was the stale v0.12 one that writes the token to the dead file. The pin said one thing; adopt did another. Any `kickoff` binary on the box must start the engine the pin names, or pinning is a lie. Mirrors `up`'s contract and its guards: no `core.lock` → no redirect (adopt is what *creates* a pin; an un-adopted repo runs itself); realpath-equal → no re-exec; **a pin naming a missing or non-executable front door now dies loud** rather than falling through to the wrong engine — a new, deliberate hard failure.

- **Generated agent charters report through `.kickoff/bin/mc` (`.claude/agent-charter-template.md`).** Every charter `adopt-manifest.py gen-agent` rendered told the agent to run `python3 mission-control/mc-update.py` — a path that exists **only in this repo, where the repo is the core**. An adopted repo has no `mission-control/`, so every generated specialist **silently failed to report and the board sat empty with no error**. It now points at the `.kickoff/bin/mc` shim adopt generates (it sources `instance.env` and execs the pinned core's engine). **`kickoff pull` fixes the template, not charters you already generated** — `.claude/agents/` is yours, and the manifest never touches it. Grep it for `mission-control/mc-update.py` and repoint any hit, or regenerate.

- **Mission Control anchors every per-instance secret to the instance — and now actually does so under the documented launch (`mission-control/server.py`).** `.mission-token`, `secrets-inbox/` and the universe-theme path all hung off `BASE_DIR` — the *server file's* directory, i.e. the core. Here core == repo, so it looked right for months. For an adopter the core is a **shared, pinned clone every project on that tag runs from**: two projects on one tag would share one board token (either operator could open the other's board) and — worse — **share the `secrets-inbox/` the operator hands credentials through**. v0.13 re-anchored these to `INSTANCE_DIR = dirname(STATE_PATH)` — correct, and **inert**: `server.py` read `STATE_PATH` from `KICKOFF_STATE` alone, a variable **nothing in the shipped `python3 server.py <port>` launch sets**, while `instance.env` exports — and `mc-update.py` reads — `MC_STATE_FILE`. The board-server and the board-writer read **different variables**, so `STATE_PATH` fell back to the core and the token relocated only where a coordinator had hand-set `KICKOFF_STATE`. **v0.14 makes `server.py` read `MC_STATE_FILE`** (with `KICKOFF_STATE` kept as an explicit override) — the same store the rest of Mission Control already used — so the relocation lands on the launch you actually run. In the origin `MC_STATE_FILE` equals the `BASE_DIR` default, so nothing there moves. No live cross-instance leak occurred (the live projects sat on different cores that day — luck, not design). Proven by a new self-test that boots the real server under the stock launch and asserts token, inbox and theme land in the instance; red against the pre-fix server.

- **The boot orphan check stopped randomly calling indexed projects orphans (`scripts/memory-orphan-check.sh`).** `printf '%s' "$idx" | grep -q …` under `set -o pipefail` returns 141 once the haystack passes the ~64KB pipe buffer: `grep -q` exits at the first match, the still-writing `printf` takes SIGPIPE, and `pipefail` surfaces the **writer's** death as the pipeline status — so a project that *is* in `MEMORY.md` reads as not-found and gets flagged an orphan. Racy, hence 3-of-5 runs. `MEMORY.md` here is ~67KB: **this check started lying the day the index grew past the buffer** — which is to say the day your memory got useful. Now a here-string: no pipe, no writer to kill. If your index is anywhere near 64KB, you were getting false orphan reports on every boot.

**Adopters:** `kickoff pull` brings all of it; the plugin bump (0.3.8 → 0.3.9) is required or `pull` fails closed at preflight #8. Three things need your hands:

- **If your bot has a token but has never pinged you** (a v0.12 channel), re-run `kickoff adopt --dir <repo>` — this is the release where that repair actually works. Have the BotFather token ready; you re-enter it.
- **If you generated agents before v0.14**, repoint their MC calls at `.kickoff/bin/mc` — `pull` can't do it for you.
- **If you run Mission Control**, restart the server after pulling. The token now relocates to `<repo>/.kickoff/state/mission-control/.mission-token` automatically — no `KICKOFF_STATE` needed; the server reads the `MC_STATE_FILE` your session already exports. A **new token is minted at the new path**, so your old `?token=` URL stops working and the board must be re-opened. Anything in the old shared-core `secrets-inbox/` does not migrate — re-send it.

Nothing else breaks. The one new hard failure is deliberate: `adopt` on a repo whose `core.lock` names a missing front door now refuses instead of guessing.

## core-v0.13 — 2026-07-16

**v0.12's one-command channel setup was a no-op. This is the fix.** It wrote the bot token to
`$TELEGRAM_STATE_DIR/secret.env` — a file nothing reads — so the bridge could not authenticate, the
startup announce found no token, and the worker ran in total silence. It passed twenty-six checks
(written · `0600` · never echoed · never logged · fails closed on a typo · a positive control proving
it *writes*): every property except **does anything read this**. Found within the hour by the operator
whose bot never pinged.

- **The token now reaches both real read paths (`scripts/kickoff`).** Verified from the consumer's
  own source and a working install, not chosen by plausibility:
  - `$TELEGRAM_STATE_DIR/.env` — what the **bridge** reads (`ENV_FILE = join(STATE_DIR, '.env')`).
  - `$REPO_DIR/.claude/settings.local.json` → `env.TELEGRAM_BOT_TOKEN` — what the **announce** reads,
    and what Claude Code exports into the session. `env.TELEGRAM_STATE_DIR` is set alongside it, which
    is what points the plugin at *this* orchestrator's own channel rather than a shared one.

  `settings.local.json` is **merged, never rewritten**: it legitimately holds other credentials and a
  `permissions` block, so clobbering it would silently destroy unrelated secrets. Written via an
  atomic same-dir temp; a malformed one is never overwritten (unparseable is not empty); the token
  reaches python through the environment, never argv (`/proc` is world-readable). `secret.env` is
  still written, since existing channels carry it — it is simply not the live path.

**Adopters:** `kickoff pull` brings it. If you set a bot token with v0.12 and your worker has never
pinged you, re-run `kickoff adopt --dir <repo>` — it finishes the channel and puts the token where the
bridge and announce actually look. Nothing else changed.

## core-v0.12 — 2026-07-16

**The release a real adopter wrote.** Every fix here came from one operator adopting one repo with the
stock commands and being asked to report friction instead of working around it. He found five of these
in about forty-five minutes; months of review, suites and reasoning had found none of them, because
kickoff-dev *is* the core and never runs the motion an adopter runs. Each was **silent** — no error, no
red, just nothing happening.

- **`kickoff adopt` finishes the channel — setup is one command (`scripts/kickoff`).** After the bot
  token it now asks for your **Telegram user id** and writes the allowlist (`access.json`:
  `dmPolicy=allowlist`, `allowFrom:["<id>"]`, `0600`), then offers to **trust the folder**. A token was
  only half a channel: without an allowlist the bot has no owner, the startup announce (which reads the
  chat id from `.allowFrom[0]`) skips, and **the worker runs in total silence** — three launches, zero
  pings, no error a human would ever see. kickoff **asks**; it never chooses who may reach a bot. An
  agent adding an identity to an allowlist is precisely the shape of a prompt-injection and cannot be
  authenticated by reading the request, so the human types it, at their own terminal, with their own
  authority — the same posture as the token itself.
  **Re-running adopt repairs a half-configured channel** (token present, allowlist missing): that state
  is what the previous flow produced, so the obvious remedy has to actually work.
- **Trust the folder at adopt time, because nothing else can (`scripts/kickoff`) — BLOCKER.** Claude Code
  blocks on a "trust this folder?" dialog the first time it opens a repo, and a freshly adopted repo is
  never on that list. `kickoff up` binds the worker's stdin to a keepalive and detaches it with `setsid`,
  so that dialog is **unanswerable there — by anyone, including a human at that exact terminal**. The
  first launch of every new adopter was an unpassable wall the supervisor restarted into forever. `adopt`
  is the only step with a real tty, so it offers; it never forges the answer, and it never clobbers a
  `~/.claude.json` it cannot parse.
- **install.sh no longer strands you on a box that already runs kickoff (`install.sh`) — HIGH.** With
  projects pinned at other tags, `kickoff pull` correctly refuses to move the shared clone and **parks**
  the requested tag in its own worktree. install.sh then inspected only the shared clone, found it on a
  branch, and refused to link **anything** — while the pinned engine sat one directory away. It named
  that directory in its own error and declined to use it, and both remedies it suggested were dead ends
  (keep the clone → no front door; delete the registry → break the live projects it exists to protect).
  **"One command to get in" only ever worked on a clean machine.** It now links the parked pin; the
  invariant is unchanged — never link a branch tip, never link a tag you did not ask for.
- **`up` and `pull` honour `--dir` (`scripts/kickoff`).** They silently ignored it while the shared
  not-your-repo error told you to *"pass --dir"*. That is every new adopter's first launch, with advice
  that could not work. Ignoring it was worse than rejecting it: `kickoff pull --dir <repo>` upgraded
  whatever `REPO_DIR` happened to resolve to. `--dir` is normalised to an absolute path, and a
  nonexistent one fails closed.

**Adopters:** `kickoff pull` brings all of it. If your bot has a token but has never pinged you, re-run
`kickoff adopt --dir <repo>` — it will finish the channel.

## core-v0.11 — 2026-07-16

**Adoption is one command now** — and the release that admits the adopter path was never actually
exercised. kickoff-dev *is* the core, so in it every path resolves and every var is already set. An
adopter has none of that, and v0.11 fixes two silent failures that only appear on the far side of that
gap. Both were found the first time anything walked a stranger's path: `curl install.sh | sh` into a
clean layout, then `kickoff adopt --dry-run` on a repo that was never shaped for kickoff.

- **`kickoff adopt` offers the project's Telegram bot (`scripts/kickoff`).** Adopt was already one
  interactive command (it prints the plan and prompts `[y/N]`; `--accept` only skips that gate for
  scripts) — but setup then bounced you into a second command and a doc to hand-place the bot token.
  Setup isn't done when a path is configured; it's done when you can reach the thing from your phone.
  Adopt now ends by offering it: BotFather steps → a hidden prompt → `0600 secret.env` in the project's
  **own** channel dir → `next: kickoff up`. It **asks** rather than doing it for you: a credential is
  the one thing an agent must never handle. Interactive only — a piped/CI run prints instructions and
  writes nothing (silence is never consent), and the target's `TELEGRAM_STATE_DIR` is read with the var
  **unset** first, so a caller that exports it can't hand the adoptee its own channel.
- **The front door adopts onto the core it IS, not `~/kickoff-core` (`scripts/kickoff`) — HIGH.** All six
  `core_dir` resolutions defaulted to a hardcoded `$HOME/kickoff-core` while the script resolved its own
  location and ignored it. The `kickoff` symlink carries no env, so the moment install.sh's **own
  documented `KICKOFF_CORE_DIR` override** put the core anywhere else (e.g. a per-version
  `~/kickoff-versions/core-vX` layout), a later invocation silently fell back. A **v0.10 front door
  planned to adopt a repo onto a stale core-v0.1**: wrong tag pinned, **the entire plugin layer skipped**
  (that core has no `plugin/`, so no skills, no crew, no memory hook), and a **local dev checkout stamped
  as the public `KICKOFF_CORE_REMOTE`** — the adoptee's future `kickoff pull` would fetch from a working
  copy. No warning at any point. Now one `KICKOFF_CORE_DEFAULT` derived from the running script feeds all
  six; identical to the old default for a stock install, and an explicit `KICKOFF_CORE_DIR` still wins.
- **The orphan check stops crying wolf (`scripts/memory-orphan-check.sh`).** It flagged two things that
  are not projects: the repo that **owns** the index (which self-flagged whenever the index named it only
  inside a longer string — that would fire for every adopter on every boot; a project cannot be an orphan
  to its own memory), and a **pinned core clone** (an engine, whose commits are release artifacts, so it
  reddened for ~`ORPHAN_DAYS` after every release). Both skipped. Noise isn't cosmetic in a check: one
  that cries wolf trains you to skim past the real orphan.
- **The published retrieval metrics no longer quote a private corpus** (`memory-retrieval/`). The
  reference eval set behind METRICS.md's `60%→85%` is a third party's operational memory; it disclosed
  business process by *shape*, which a name-based scanner cannot see. METRICS.md now describes each case
  by **paraphrase kind** with its **real measured ranks intact** (no substitute queries — a metrics doc
  must not describe an experiment that never ran), and `demo.mjs` is repointed at kickoff's **own public
  corpus**, which also **fixes** it: its `expect` slugs did not exist here, so the demo missed on its own
  box. It now ranks 4/4 at #1 and shows the semantic win live (one case: hybrid #1, keyword-only miss).

**Adopters:** `kickoff pull` brings all of it. If you installed with a custom `KICKOFF_CORE_DIR`, this is
the release that makes that override actually work — check `kickoff status` names the tag you expect.

## core-v0.10 — 2026-07-16

The **memory-lifecycle** release: memory that *corrects* and *forgets*, not just accumulates. An index
only grows, so the failure modes are quiet ones — a fact that was true when written and is a lie today,
a correction that left the thing it corrected on disk, a live project the index never mentions. This
release ships the checks that make those loud, and wires two of them into the worker's re-ground.

- **The re-ground boot checks (`scripts/session-run.sh`).** The default `REGROUND_PROMPT` now tells a
  freshly-looped worker to run `memory-orphan-check.sh` + `memory-budget-check.sh` after reading its
  charter/index/tracker, and to heed what they say before acting. The checks are named **core-absolute**
  (resolved from the running script, not the worker's cwd) — a pull adopter's worker runs in their own
  repo, which has no `scripts/`, so a repo-relative name would 127 and the `(if present)` hedge would
  silently swallow it. Both checks exit 0 when they cannot find an index, so a custom `REGROUND_PROMPT`
  or a partial core degrades quietly instead of blocking a boot.
- **Orphan detection (`scripts/memory-orphan-check.sh`, new).** Answers the one question a query-driven
  recall hook structurally cannot: *is something ALIVE that memory has never heard of?* You cannot ask
  about a project you have never been told exists. It looks for live signals on disk — recent git
  activity, a bound port whose process sits under the root — and reds each project the index does not
  mention. Matching is name-boundaried, not substring (a repo `an adopter` is NOT satisfied by an index that
  merely says `acmed`), vendored trees are pruned, and an empty scan reports itself as a finding about
  the scan rather than a green all-clear. Takes `<root> [index]` (root defaults to `$HOME`), tunable via
  `ORPHAN_DAYS` (default 14) and `ORPHAN_DEPTH` (default 3 — nested layouts like `~/code/<repo>` need
  ≥ 3). All four knobs below pass through `instance.env`.
- **Index budget guard (`scripts/memory-budget-check.sh`, new).** The index is loaded into *every*
  session, so its size is a standing context tax. Warns loudly past 210 lines / 84 000 bytes
  (`MEMORY_INDEX_BUDGET_LINES` / `MEMORY_INDEX_BUDGET_BYTES`). Advisory by design: compacting an index
  is a judgement call, not something a hook should fail a commit over.
- **Supersede truth-invariant (`scripts/memory-supersede-check.sh`, new).** A correction must DELETE
  what it corrects. A memory declaring `supersedes: <slug>` in its frontmatter must have removed that
  slug's file — otherwise the stale fact and its correction both sit on disk and a future session can
  retrieve the wrong one. Frontmatter-scoped (body prose cannot trip it) and fail-closed on path
  traversal. The opening fence tolerates a UTF-8 BOM, CRLF, and leading blank lines — each of those
  otherwise reads as "no frontmatter" and lets a live contradiction pass with a green. Exit 1 on a real
  contradiction; a pure no-op when nothing declares `supersedes`.
- **Recall surfaces stale state (`memory-retrieval/hook.mjs`).** A retrieved memory whose description or
  body carries open state — `pending`/`blocked`/`debt`/`unresolved` any case, or `TODO`/`OPEN`/`WIP`
  uppercase-only so "open source" stays quiet — is now tagged *"⚠ verify it's still true before acting"*.
  The fact was true when written, not necessarily now.
- **Suppressed-error scan lane (`scripts/scan-structure.sh`).** A new advisory-LOW finding for the
  `2>/dev/null | wc -l` shape — a footgun that turns a broken command into a confident `0`.

**Adopters:** `kickoff pull` brings the three checks and the re-ground wiring. The charter *rules* that
pair with them (tasks live in the tracker not memory; a correction deletes what it corrects) are not in
this delta — `CLAUDE.md` is yours, not core's. The rules are in kickoff's own `CLAUDE.md` if you want to
copy them into yours. The `*-selftest.sh` suites and `lefthook.yml` stanzas are maintainer-only and do
not travel; wire the checks into your own hooks if you want them enforced on commit.

## core-v0.9 — 2026-07-15

The **brownfield make-or-break** release: adopting kickoff onto a repo that *already* has its own AI
crew, without fighting it — plus the release/upgrade robustness that lets a solo maintainer ship
these safely, and Mission Control reporting an adopter can turn on with zero charter edits.

- **Adopt gets a brain — restraint-first crew meshing (`scripts/crew-probe.py`, adopt SKILL).** When
  `kickoff adopt` lands on a repo that already has its own `.claude/agents`, it now READS that crew and
  meshes minimally instead of imposing a fixed roster. `crew-probe map` inventories the existing agents
  (and surfaces each one's `model` + `disallowedTools`, so a locked-down or model-pinned charter is not
  misread as unrestricted); `coverage-sources` reads the repo's `CLAUDE.md` / `AGENTS.md` / skills /
  charter bodies to see which domains ALREADY have an owner (killing the over-propose risk that a
  name-only `map` can't see); `validate-plan` gates any gap-fill proposal so a new specialist is
  proposed ONLY where a domain genuinely has no owner — and REFUSES (exit 1) an over-proposal against a
  good crew, with a `deferred` field that records deliberate restraint. `gen-agent` (an
  `adopt-manifest.py` verb the adopt SKILL invokes) authors a gap-filler charter in the repo's own
  convention, additive and fully `kickoff eject`-reversible. Validated on 3
  real public repos (a 13-agent repo → **0** proposed; a 6-agent repo → 1; a 2-agent repo → 3 — never
  over-proposed). `validate-plan --json` emits a structured verdict for tooling; a breadth advisory and
  a `coverage-sources` present/notes surface make an absent `AGENTS.md`/skills legible rather than a
  silent empty result. These are advisory hints — they never gate.

- **`kickoff adopt --dry-run` states the mesh in one honest sentence, before any write.** The dry run
  prints the consent surface — *"found your N agents — I run YOURS and add specialists only where a
  domain has no owner (you approve each); I use your gates + memory as-is and mesh only Mission Control
  onto your crew"* — adapting for the crew it found (no crew / one agent / many). The surface names
  **every** file the adoption touches (the `CLAUDE.md` import, `.claude/settings.json`, `.gitignore`,
  your `memory/`, the one eject-reversible lefthook `extends:` line) — informed consent, not a surprise —
  and the dry run itself writes nothing.

- **Mission Control reporting is plug-and-play — a lifecycle hook + a skill, zero agent-file edits
  (`plugin/hooks/`, `plugin/skills/mc-report/`).** An adopter's agents stream into their own Mission
  Control board through a plugin **lifecycle HOOK** (`SubagentStart` → `function <agent> working`,
  `SubagentStop` → `function done` + a trimmed outcome line) — no charter edit, routed through the
  adopter's own `.kickoff` seam, injection-safe (untrusted agent text becomes quoted argv, never eval),
  and **always exits 0** so a reporting hiccup never blocks a subagent. `kickoff eject` just removes the
  settings keys. A discoverable **`mc-report` skill** adds the semantic beats a mechanical hook can't
  see — a decision reached, a milestone hit, a completion-with-artifact. Signal, not play-by-play
  (`PostToolUse` is deliberately not wired).

- **Release-gate (`scripts/release-gate.sh`) — a fail-closed, release-TIME gate that refuses a release
  that would brick adopters.** Run before a tag, it compares the candidate tree against the previous
  `core-v*` tag. **HARD** checks (flip the exit code): plugin-version-vs-content (any `plugin/` change
  demands a `plugin.json` version bump — the real core-v0.8 brick), manifest-existence, whole-tree
  leak-scan, and every pre-push suite RUN on a detached worktree of the exact candidate ref.
  **ADVISORY** checks (named loudly, never block): changelog-top-section, installer-URL parity,
  manifest-covers-new-files. Every pathspec is root-anchored (`:/…`) so the gate cannot false-green when
  run from a subdirectory — a CWD-relative pathspec had made the plugin-version HARD check pass
  vacuously, certifying the very brick it exists to catch.

- **Policy-neutral upgrade turnkeys (`scripts/adopt-manifest.py gen-upgrade-turnkey`).** The generator
  emits an adopter's upgrade one-tap whose model/effort resolution **mirrors the engine**: an adopter
  who never pinned a model gets no `--model` (inherits the box) and `high` effort, never a baked
  default; an existing pin is preserved verbatim. It structurally rejects any hardcoded model family or
  non-`high` tier anywhere in its default chain. This kills the class where a turnkey retargeted from a
  prior version silently carries that version's stale policy (a v0.8 turnkey once clobbered an adopter's
  `opus` pin with a `fable` default). Template travels via `scripts/core-manifest.txt`.

- **Plugin version `0.3.2` → `0.3.8`** (`plugin/.claude-plugin/plugin.json`) — the adopt SKILLs, the MC
  reporting hook + `mc-report` skill all changed plugin content, so the version bumps to route every
  adopter's `kickoff pull` through the deterministic plugin-cache re-sync.

## core-v0.8.1 — 2026-07-13

- **Packaging fix — plugin version bump `0.3.1` → `0.3.2` (`plugin/.claude-plugin/plugin.json`).** core-v0.8
  edited `plugin/skills/{adopt,bootstrap}/SKILL.md` but left the plugin version unchanged. The pull re-syncs
  the shared interactive plugin cache by version bump (`claude plugin update` is a NO-OP on an unchanged
  version string, and the belt-and-braces reinstall is deliberately gated off when a sibling shares the
  cache — it must never sweep a shared cache out from under a live consumer). So a same-version content
  change lands as a preflight-#8 cache drift that **fail-closes every adopter's `kickoff pull`** (the pin
  advances, but the worker is correctly left untouched). The bump routes the pull to the version-bump path,
  which re-syncs deterministically. No behavior change beyond the cache re-sync. A release-checklist guard
  (`docs/release-checklist.md` §1) now flags plugin content changing without a version bump so this can't recur.

## core-v0.8 — 2026-07-13

- **Reactive model-quota fallback belt (`scripts/supervisor.sh`).** Closes the "alive but cannot
  think" gap: when a worker hits its model's weekly quota wall, every turn fails while the
  supervisor, session, and Telegram bridge all stay healthy — no prior belt noticed. The new
  `model_fallback_step` (poll-loop, `|| true`) scans the session's own captured output for the wall,
  and on a confirmed hit switches the worker to a cheaper fallback model — a multi-hour silent outage
  becomes a ~60s self-heal. It runs in the supervisor's own loop shell, so it `export MODEL=<fallback>`
  in-process (defeating the fossilised env with no re-exec) **and** rewrites every active `MODEL=` line
  in `instance.env` atomically (durable across full restarts), refreshes the session, writes
  `.kickoff/model-fallback`, sends one Telegram alert (a silent downgrade is a lie by omission), and
  latches one-shot per session. Guardrails: **one-way ladder** (only switches toward the cheaper model;
  a pricier fallback is refused as spend, an unknown model family refused fail-closed); already-on-
  fallback → alert not loop; `DRY_RUN=1` → detect-only; inert-by-construction (no detection / disarmed
  / no resolvable fallback → zero action). The detector ANSI-strips then requires **both** the limit
  phrasing **and** the `/usage-credits` marker in a tight one-line window, plus an N-tick recurrence
  gate, so a worker merely quoting or `cat`-ing the wall never trips it — only a wall that reprints.
  There is deliberately **no proactive/threshold tier**: a personal subscription exposes no
  non-interactive quota source to read a percentage from, so reactive detection is the whole feature.
  **Stability contract — NEW `instance.env` variable names** (all optional, safe defaults, see
  `scripts/instance.env.example`): `MODEL_FALLBACK` (gate, default on), `MODEL_FALLBACK_TO` (target,
  default `opus`), `MODEL_FALLBACK_CONFIRMATIONS`, `MODEL_FALLBACK_WINDOW_SECONDS`. Proof:
  `scripts/model-fallback-selftest.sh` (NEW; lefthook pre-push; RED-on-old proven against HEAD).

- **Adopt consent gate (§4) — `kickoff adopt` states what it will do and gets a yes before any write
  (`scripts/kickoff`).** A pitch grounded in the target repo's real detection (its memory corpus, its
  gates) prints BEFORE the first write; the write path then requires an explicit consent — an
  interactive `[y/N]` (default No) or `--accept` (scripted consent for a coordinator that has read a
  `--dry-run`); a piped/CI invocation with neither **refuses to write**. `--dry-run` heads the same
  pitch over the read-only per-file plan. The pitch names **every** existing file the adoption
  touches — `CLAUDE.md` (one import block), `.claude/settings.json` (plugin keys), `.gitignore` (one
  ignore line), and, if you already run lefthook, the one eject-reversible `extends:` line — so consent
  is informed, not a surprise. Every touch stays additive, manifest-recorded, and `kickoff eject`-reversible.

- **One-command curl installer (`install.sh`) — a stranger onboards without cloning a template.**
  `curl -fsSL …/core-v*/install.sh | sh` clones a read-only engine core, pins it at the latest reviewed
  `core-v*` tag (reusing `kickoff pull`, never reinventing the pin), and links the `kickoff` front door
  into `~/.local/bin` — a symlink, never a PATH or dotfile mutation (an off-PATH shell gets a printed
  optional one-liner). Idempotent: a re-run verifies + repairs (origin, pin, symlink) and never moves an
  existing pin (`kickoff pull` owns upgrades). One installed front door serves every pinned org on the
  box via the v0.7 pin-redirect. The long-form read-then-run path (download → read → `sha256sum -c` →
  run) is documented beside the one-liner; each release publishes the installer SHA-256 and the
  tag→commit mapping. Proof: `scripts/install-selftest.sh`.

## core-v0.7 — 2026-07-13

- **Config precedence (G1 §2.3) — one rule enforced identically at every seam: argv > pre-set
  env > instance.env > engine default.** `MODEL` joins the frozen instance.env whitelist (all
  three copies: `kickoff`, `session-run.sh`, `preflight.sh`), so a per-adopter model pin set in
  `.kickoff/instance.env` now survives every restart path; unset still means "inherit the box's
  Claude Code model config" (no `--model` flag is ever added — unset never downgrades).
  `session-run.sh` now imports instance.env with the same preset-wins mechanics as the front
  door (a pre-set env value is never overridden by a file line), and `kickoff up --auto` is
  **grant-only**: it no longer forces `EFFORT=max` — effort resolves `--effort` argv > `EFFORT`
  env/instance.env > engine default `high` (`--effort` / `--model` are new `kickoff up` flags).
  `scripts/go-autonomous.sh` follows the same rule: it no longer defaults `EFFORT=max`, and it
  passes `EFFORT`/`MODEL` into the launch env only when non-empty — its old set-but-empty
  `MODEL=` read as "preset" downstream and silently blocked the file pin on that restart path.
  **BREAKING (the removed path was already against intent): `PERMISSION_MODE` no longer
  file-imports — a `PERMISSION_MODE=auto` line in instance.env is now IGNORED by every core
  script; grant autonomy at the terminal instead (`kickoff up --auto`, or `PERMISSION_MODE=auto`
  in the launching shell's env).** Proof: `scripts/config-precedence-selftest.sh` (NEW; lefthook
  pre-push `config-precedence-test` — hermetic stub-claude spawn chain, RED-on-old proven
  against HEAD incl. the file-armed-PERMISSION_MODE and `--auto`-stomps-effort shapes, plus a
  dedicated go-autonomous lane proving the set-but-empty-`MODEL` pin-block + `EFFORT=max`
  stomp RED on HEAD).

- **One start surface (G1 §2.2): `kickoff up` is the only way a worker starts.** New flags:
  `--detach` (setsid+nohup daemonized launch; same log, shared copytruncate rotation) and
  `--replace` (gracefully cycles THIS org's running supervisor — strict lock parse, /proc
  cmdline + own-org REPO_DIR assertion so a foreign or other-org process is REFUSED never
  signaled, TERM → bounded wait → refuse-to-escalate). **Pin-redirect:** when a repo is pinned
  (`.kickoff/core.lock`) to a different engine dir, ANY `kickoff up` re-execs the pinned
  engine's own front door argv-verbatim — one front door over N installed versions; an
  unpinned repo (origin included) is inert, no behavior change. `scripts/go-autonomous.sh` is
  now a deprecation shim (`exec kickoff up --auto --detach`, REMOVED in v0.8) — its silent
  auto-cycle is gone: a second `up` against a live supervisor dies loud, cycling is the
  explicit `--replace`. Proof: `scripts/start-surface-selftest.sh` (NEW; lefthook pre-push).

- **The engine hop (G1 §2.4): `kickoff pull` now finishes the job — a RUNNING worker cycles
  itself onto the new engine.** The pull touches the supervisor's refresh flag; at the next
  session boundary the supervisor re-runs the full fail-closed preflight against the NEW
  engine (explicit `KICKOFF_CORE_DIR`, fossil env unset so a stale export can never beat the
  fresh `core.lock` read) and re-execs itself from it — same PID, run-state preserved,
  MODEL/EFFORT re-resolved fresh from instance.env, the autonomy grant carried. Upgrading
  v0.6→v0.7 is therefore the LAST manual cycle: a v0.6 supervisor has no hop unit, so this
  one hop still needs a stop + `kickoff up`; every upgrade after lands with `kickoff pull`
  alone. Proof: `scripts/hop-selftest.sh` (NEW) + `journey-e2e.sh`'s upgrade lane (a real
  v0.7 supervisor provably lands on tag N+1 after one pull, same PID).

- **Spawn-env hygiene (G1 §2.5): the worker launches from a CLEAN env.** `kickoff up` now
  builds the worker env from a positive KEEP-list (system basics + auth + the engine's owned
  launch vars, applied last) via `env -i` — ambient shell vars no longer leak into the worker
  (the class that crash-looped a worker on 2026-07-12: an inherited `_PTY_WRAPPED`, a stray
  `MODEL`, another org's channel state dir). **Possibly breaking if you relied on ambient env
  reaching the worker:** the terminal-only `KICKOFF_ENV_KEEP` escape hatch (comma-separated
  names, deliberately NOT importable from instance.env) is the supported way to pass extras.
  Proof: `scripts/spawn-hygiene-selftest.sh` (NEW; lefthook pre-push).

- **pty self-detection: `session-run.sh` decides its `script(1)` wrap from a real TTY probe
  (`[ ! -t 0 ]`), never from the inheritable `_PTY_WRAPPED` flag** — the print-mode
  crash-loop class from an inherited flag is structurally dead, and a missing `script(1)`
  now fails loud instead of silently degrading. Proof: `scripts/ptywrap-selftest.sh` (NEW;
  lefthook pre-push).

## core-v0.6 — 2026-07-11

- **G2 (retired unshipped) — the `plugin-telegram/` fork is GONE; the official plugin is the only
  supported telegram bridge.** The vendored fork (0.0.6-kickoff.1, marketplace `kickoff-telegram`)
  never reached an adopter: its delivery was gated on the v0.6 tag, which was never cut, and the
  origin box's one manual enable was reverted. It is now fully removed — the fork tree, the
  adopt/pull enable + resync-skip + preflight verify paths, its manifest section, and its selftest
  gates. **THE RULE this bakes in: never fork the telegram plugin.** Multi-project isolation is a
  state-dir + token concern, not a plugin concern: run ONE official
  `telegram@claude-plugins-official` and give each project its own `TELEGRAM_STATE_DIR` +
  `TELEGRAM_BOT_TOKEN` — one plugin, N isolated bots. A custom channel plugin is not on the
  approved-channels allowlist, so its bridge boots then exits immediately — the worker goes
  silently deaf (exactly the outage the fork was meant to prevent). The G2 root-cause diagnosis
  **STANDS**: upstream's boot-time stale-poller takeover (official server.ts L61-68, still present)
  — any overlapping claude sharing `TELEGRAM_STATE_DIR` (typically a nested `claude -p` inheriting
  the worker's env) unconditionally SIGTERMs the healthy bridge, and claude never respawns a dead
  `--channels` server. The durable mitigations are env-hygiene on nested claude calls, the
  supervisor's bridge-liveness respawn belt (v0.5), and the two hardening pieces (reap-on-startup
  of a verified-stale channel holder + a fail-loud never-came-up belt — the next entry).

- **Telegram-channel hardening — reap-on-startup + a fail-LOUD dead/never-up-bridge belt (the two
  durable mitigations from the 2026-07-11 handoff).**
  (1) **`scripts/bridge-reap.sh` (NEW, travels in the manifest).** session-run.sh runtime-sources
  it (bash -n gated, no-op stub if absent — the auth-heal.sh discipline; the helper's body runs in
  a subshell so no bug can abort the wrapper) and calls it once per spawn, before `exec claude`:
  it reads `$TELEGRAM_STATE_DIR/bot.pid` and reaps a VERIFIED-stale holder of this project's
  getUpdates slot, so the fresh bridge boots into a clean slot instead of losing (or winning-then-
  losing) upstream's boot-takeover war. Kill happens ONLY after ALL of: bridge argv signature
  (`*bun*telegram*`/`*bun*server.ts*`/`*telegram*server.ts*`), `/proc/<pid>/environ` carrying the
  SAME `TELEGRAM_STATE_DIR` (raw + `pwd -P`-resolved), and an ancestry walk proving it is outside
  our own launch tree — every ambiguity (unreadable /proc, missing env binding, mid-walk TOCTOU)
  FAILS TOWARD NOT KILLING, and the kill is the EXACT pid only (never a group/pattern kill —
  sibling projects run near-identical bridges on the same box). Dead/corrupt/absent bot.pid = a
  logged no-op (the fresh bridge overwrites the file itself). `KICKOFF_BRIDGE_REAP=0` disables — a
  plain env knob, deliberately NOT an instance.env whitelist var (the frozen cross-file whitelist
  is untouched). Takes effect at the next session refresh (session-run.sh is fresh-read per spawn).
  (2) **supervisor fail-loud belt (KICKOFF-BRIDGE-UNIT).** The v0.5 belt only reacted to a bridge
  that died AFTER being seen; a bridge that NEVER came up — the "silent gag" — triggered nothing.
  New `bridge_boot_check`: once `BRIDGE_BOOT_GRACE_SECONDS` (default 120) elapse with no bridge
  latched, it logs LOUD, writes the durable flag **`.kickoff/bridge-escalated`** (timestamp +
  reason; mirrors `auth-escalated` but deliberately does NOT gate trigger-3 restarts — a deaf
  session still computes; blocking restarts would turn a comms outage into a work outage), sends
  ONE tokenless alert, and auto-refreshes at most `BRIDGE_BOOT_RETRY_CAP` (default 1) times with
  reason `bridge-neverup`, then STOPS (repeated restarts are the wrong move). **Superseded in
  v0.20 — see below: the "then STOPS" give-up was itself the outage, and it is now a widening
  retry that never gives up.** It corroborates with
  bot.pid and NAMES a live foreign holder of the channel's slot in the log (detection only — the
  kill path stays in bridge-reap.sh); it is inert without a derivable `TELEGRAM_STATE_DIR` (a
  non-telegram START_CMD keeps the v0.5 inertness) and detect-only under DRY_RUN. The existing
  died-mid-session give-up now also writes the flag; a healthy bridge clears it and resets the
  boot bookkeeping. Supervisor changes are DORMANT on a running supervisor until the operator
  restarts it (one long-running bash keeps the old inode). Proof: `scripts/bridge-reap-selftest.sh`
  (NEW; lefthook pre-push `bridge-reap-test` — hermetic /tmp stubs, exact-pid ownership, RED-on-
  pre-fix soft check) + `supervisor-liveness-selftest.sh` scenarios h–l (RED-on-old proven against
  the pre-fix HEAD).

- **#8 — plugin-resync install-row sole-consumer gate (headless-only sibling convergence).**
  `kickoff pull`'s G7 sibling gate now decides mechanism-B safety from **who actually consumes the
  shared interactive plugin cache** — the `<plugin>@<mkt>` install rows in the config dir's
  `installed_plugins.json` (new `adopt-manifest.py plugin-consumers-others` verb; verified against
  real claude 2.1.207: a project-scope install records `projectPath` = the consuming project) —
  instead of the machine adopters registry, which answered the wrong question and was wrong in
  BOTH directions. Unblocked: a registered **headless-only** sibling (no install row — its worker
  execs source via `--plugin-dir` and never reads the cache) no longer blocks a same-version
  content convergence forever (the prior-adopter pull that needed a hand-built
  fix). Closed: an **unregistered interactive consumer** (registry rows are
  best-effort) is now structurally visible — the old gate read "positively sole" off the registry
  and would have swept its live cache. Fail-closed semantics: corrupt/unreadable
  `installed_plugins.json`, a row missing `projectPath` (older claude), a user-scope row, or a
  pinned tag whose tool predates the verb ⇒ never provably sole ⇒ mechanism A only + a refusal
  WARN naming the actual consumer(s). G6 stays add-only (never `marketplace remove`), all
  lifecycle ops stay scoped + cwd-of-the-adopter, verify-first still guarantees zero churn on a
  matching cache. Follow-up recorded: eject's last-adopter predicate stays registry-based (a
  different blast radius — it also removes the marketplace + registry rows); the asymmetry is
  deliberate for now. Proof: `plugin-selftest.sh` §3b (verb semantics + H1 headless-only
  convergence + H2 unregistered-consumer protection + H3 refusal control + a live
  `installed_plugins.json` dogfood canary).

- **install-model dep install sandboxed OUT of the pinned clone (the pnpm >= 10 pull-breaker) +
  step-4f drift guard.** Real pnpm >= 10 treats `pnpm-workspace.yaml` as its WRITABLE config store —
  `pnpm install` run with cwd = the freshly-pinned core clone mutated that TRACKED file (appending
  `ignoredBuiltDependencies` etc., sometimes exiting non-zero on top), so the clone went git-dirty
  between the pull's lock-write and its pin verify and preflight #6 correctly failed closed on
  EVERY model-installing `kickoff pull` (the 2026-07-10 Bliz v0.4.1 upgrade breaker). Root-cause
  fix in `memory-retrieval/install-model.mjs`: each package manager now runs in a throwaway stage
  OUTSIDE the clone (copies of only the install inputs; staged under the durable model-cache dir,
  since adopter `/tmp` can be noexec) — it may mutate its copies freely — and on success ONLY the
  stage's `node_modules` is swapped into the tool dir (a git-ignored path; atomic rename with an
  EXDEV verbatim-symlink copy fallback), so the pinned clone stays byte-clean BY CONSTRUCTION for
  any pnpm/npm version or future config-write behavior. The pnpm→npm fallback keeps its turn after
  a non-zero pnpm, now over a FRESH stage per manager (the stale half-installed `node_modules` is
  replaced wholesale on success, no longer pre-wiped — a failed npm can no longer leave nothing).
  Complement, NOT the fix: `kickoff pull` step 4f gains a drift guard — porcelain drift left in the
  pinned clone after the model step is definitionally machinery-caused, so it restores the pinned
  state (`git checkout -- . && git clean -fd`, never `-x` — the git-ignored `node_modules`/model
  cache survive) and WARNs loudly naming the paths, keeping 4f's advisory never-fails-the-pull
  posture while the pin stays coherent. Proof: `pull-selftest.sh` §16 (a real-shaped pnpm>=10 shim
  that ALWAYS mutates its tracked config store in cwd; a model-installing pull ends PULL OK +
  pin-coherent; the drift guard restores + WARNs when a tool writes tracked drift anyway) +
  `model-durability-selftest.sh` §6 (fresh-stage-per-manager fallback heal + stub-probe hygiene).

## core-v0.5 — 2026-07-10

**The open-source on-ramp, end to end: one command in → a green proof → a shareable public
link — plus a reliability spine that keeps the unattended worker honest and self-healing.** Every
slice adversarially reviewed. **Additive — a v0.4.x adopter pulls v0.5 with no config edits** (new
capabilities are opt-in / additive; `instance.env` gains only optional knobs).

### The on-ramp — the adopter journey works start to finish

- **G1 — Get in with one command.** A POSIX `curl -fsSL <raw>/install.sh | sh` installs `kickoff`
  on PATH + pins the engine at the latest `core-v*` — killing the clone-and-symlink friction (the
  #1 DevEx concern) and the two-clone confusion. It delegates the pin to `kickoff pull` (reuses, not
  reinvents), detects a missing PATH and prints the one-line fix, and is idempotent. Proof:
  `scripts/install-selftest.sh` (hermetic — scratch HOME + a `file://` remote, never the live core).
- **G2 — Brownfield first-green.** A new `kickoff verify` gives an adopted repo a runnable "it
  worked" — seam health (core.lock, shims, `mc` round-trip, lefthook, plugin) + a minimal dep report
  — WITHOUT needing the Telegram channel; `/adopt` step 7 runs it. Adopt now derives a real
  `TELEGRAM_STATE_DIR` default so `kickoff up` no longer fail-closes on a placeholder, and
  `kickoff pull` ends with one plain-English line. Proof: `journey-e2e.sh` + a scratch-repo verify.
- **G3 — Share a public link, zero-spend.** A `share` flow in the `preview` skill: precondition-check
  the Tailscale Funnel, pick a free funnel port (never fighting box-ingress), start it human-gated,
  and relay ONE public URL a friend off your tailnet can open — or hand the one-tap consent turnkey
  if Funnel isn't enabled yet. `setup` gains the enablement sub-step + zero-spend copy. Proof:
  `scripts/share-selftest.sh` (stubbed) + a live off-tailnet fetch of a funnelled page.
- **G4 — One true story.** The adopter-facing surfaces (README, QUICKSTART, ADOPT, RUNNING,
  `docs/for-ai-adopters.md`, `docs/what-is-this-and-why.md`) reconciled to what the seam actually does
  — the one-command install fronted, `kickoff verify` + share documented, stale version pins dropped
  for bare `kickoff pull`, the real seam paths (`.kickoff/bin/mc`, `.kickoff/memory/`), and a real
  (anonymized) brownfield adoption story surfaced.

### The reliability spine — the unattended worker stays honest + self-heals

Distilled from a real adopter running the supervised worker in production. In `scripts/supervisor.sh`
/ `session-run.sh` (pulled core) — **latent until a supervisor restart; a live worker is undisturbed
by the pull.**

- **Crash-loop circuit-breaker.** A fast-dying session (e.g. a weekly usage-limit death where auth
  stays valid, so auth-heal self-vetoes) was restarted every 5s forever — burning quota while the
  cheerful ping said all was well. Now an in-process fast-death streak drives exponential backoff
  (capped 30m, never wedges — auto-recovers the instant the cause clears) + one distinct degraded
  alarm at the crossing.
- **Long-outage re-alarm.** The degraded alarm no longer fires once and goes silent forever — it
  re-fires on a bounded cadence while the outage persists (silence and spam are the same bug).
- **Telegram bridge-liveness auto-respawn.** The `--channels` worker's bun bridge can crash while the
  session stays alive — silencing the operator's only channel, with no self-recovery (a real,
  recurring production outage). The supervisor now watches its OWN bridge (scoped strictly to its
  session's process descendants — never a box-wide match that could touch another project's bridge)
  and auto-refreshes if it dies, with a seen-latch + a respawn cap so it can never loop. Proof:
  `scripts/supervisor-liveness-selftest.sh`.
- **Honest signals + self-heal grafts.** `kickoff verify` proves the memory function actually *works*
  (not just that files exist); the memory-model install self-heals a degraded cache; a degraded
  semantic-memory state is now agent-visible (not silent); + an optional `MODEL` knob.
- **Maintainer retrofit kept in lockstep.** `scripts/install-auth-heal.sh` (maintainer-only, does not
  ship to adopters) now retrofits the full circuit-breaker + re-alarm + the `refresh()` streak-reset,
  with a twin-lockstep selftest that stays byte-for-byte with the core.

**Upgrading FROM v0.4.x:** the pull is clean + additive — no `instance.env` or manifest breaking
changes. The reliability changes to `supervisor.sh` / `session-run.sh` take effect on the next
supervisor restart; a live worker keeps running its loaded copy until then.

## core-v0.4.1 — 2026-07-09

**Reliable updates: `kickoff pull` no longer false-fails when the adopter's own worker is live.**
A patch — **additive, no config changes; a v0.4 adopter pulls v0.4.1 clean** (no `instance.env` or
manifest changes).

- **`kickoff pull` now verifies only the PIN it just wrote** (`#6` core.lock + `#8` seam/plugin
  integrity), not full session-readiness. The full preflight's `#4` single-supervisor check is
  designed for a worker *start*; run as the pull's post-write gate it **false-failed on the adopter's
  OWN already-running worker**, returning `rc=1` on a pin that was actually clean. Pin scope is a new
  internal `--pin` flag on `preflight.sh` — **argv-only**, so it can't be inherited from the
  environment or set via `instance.env`; `supervisor.sh`'s worker-start gate and a manual
  `kickoff preflight` stay the FULL fail-closed gate **by construction**. Default (no `--pin`) is
  byte-for-byte the previous behaviour.
- **Honest pull reporting.** The pull summary now separates a real pin failure from a
  session-readiness one, and — on a **rollback** to a tag whose preflight predates pin scope — says so
  plainly instead of misattributing the failure to pin corruption.

**Upgrading FROM v0.4:** the running (old) `cmd_pull` still runs the full gate for this one hop, so a
pull done while your worker is live may print `rc=1` from the `#4` guard even though the pin is clean
— confirm `.kickoff/core.lock` advanced to the target commit and that the only `[FAIL]` is `#4
another supervisor is LIVE`. From v0.4.1 onward this is handled automatically.

## core-v0.4 — 2026-07-09

The **reusable Mission Control universe** — the 3D showcase becomes an opt-in, personalizable
capability any adopter can turn on — plus semantic memory that survives upgrades. Every slice
adversarially reviewed. **Additive — a v0.3/v0.3.1 adopter pulls v0.4 with no config edits** (the
universe ships OFF by default).

- **The universe is now a first-class, opt-in, personalizable capability** (was a bespoke
  kickoff-dev-only showcase). `mission-control/universe.html` renders ANY adopter's org **data-driven**
  off the same `mission-state.json` the 2D board uses (core = project · galaxies = `done` themes ·
  stars = shipped · forging = in_progress · agents = functions) — no hardcoded org, no schema change.
  1. **Opt-in, default OFF** — `KICKOFF_UNIVERSE` (process-env). Off ⇒ `/universe` 404 + the dashboard
     link hidden; on ⇒ served + linked. A new `/config` route exposes only the boolean.
  2. **Personalizable** — a per-instance `.kickoff/universe.theme.json` (seeded once from
     `scripts/templates/universe.theme.json`, adopter-editable, never drift-pinned) retints the palette +
     tunes bounded knobs (particle density, bloom, sizes). The **organic aesthetic is the default AND the
     guardrail** — a theme can retint/rescale but cannot turn the soft forms into hard shapes or inject
     (hostile theme reviewed: prototype-pollution / XSS / raw-GLSL all inert).
  3. **Offline-safe + travels** — Three.js is **vendored** under `mission-control/vendor/` (no CDN; served
     by a realpath-contained `/vendor` route with `nosniff`), and `universe.html` + the theme template +
     the whole MC served surface are pinned in `core-manifest.txt`, so `kickoff pull` delivers + drift-pins it.
  Proof: `scripts/universe-selftest.mjs` (53 assertions — data-driven render on unseen states, GPU +
  SwiftShader, ZERO external requests offline, 320px HUD guard, opt-in matrix).

- **Semantic memory model is now PULL-DURABLE (+ a missing one is LOUD, not silent).** The local
  embedding model (`Xenova/all-MiniLM-L6-v2`, 384-dim, offline CPU) used to cache INSIDE
  `node_modules` — a `kickoff pull` to a fresh core clone starts with an empty `node_modules`, so
  every semantic adopter **silently degraded to keyword-only on upgrade** (surfaced by
  the first real adopter). Additive fix, four parts:
  1. the model now resolves from a **durable per-machine cache** (`KICKOFF_MODEL_DIR` →
     `~/.cache/kickoff-models`, XDG-aware) that no pull ever touches; a legacy in-`node_modules`
     cache is auto-**migrated** out on first use (no re-download);
  2. new **`memory-retrieval/install-model.mjs`** (also `./run.sh install-model`) reinstalls
     deps + migrates/fetches the model idempotently; `kickoff pull` runs it `--if-needed` as an
     **advisory** step (fast no-op for keyword-only instances — never surprise-installs);
  3. a semantic index whose model went missing now **falls back to keyword-only VISIBLY** — one
     clear warning (hook stderr + inside the injected block + the jsonl log) naming the one-command
     heal — and the vector arm gains a **dims guard** so a stub query-vector is never fused against
     real 384-dim stored vectors (that was silent ranking noise at 2× weight);
  4. the incremental reindex **refuses to stub-poison a semantic index** (changed facts reindex
     keyword-side; their stale vectors drop instead of being replaced by 256-dim stub vectors; the
     index keeps its semantic identity).
  A v0.3 keyword-only adopter is untouched (no new deps, no warnings, zero config). New env knobs
  (process-env, both optional): `KICKOFF_MODEL_DIR`, `KICKOFF_MODEL_OFFLINE=1`. Manifest adds
  `memory-retrieval/install-model.mjs`. Repro/proof: `scripts/model-durability-selftest.sh` (37
  assertions: durable resolution · simulated pull with REAL offline embeds from the durable dir ·
  visible-drop + poison-guard · v0.3-compat quiet path).

## core-v0.3.1 — 2026-07-08

Adoption-robustness patch — three fixes the **first real external adopter** surfaced that no
self-test caught, because a real adopter has a pre-existing corpus + an
autonomous worker doing `git add -A`. **Additive only — a v0.3 adopter pulls v0.3.1 with no config
edits**; each fix ships with a RED-before/GREEN-after repro test.

- **Memory engine self-heals its cache dir (functional bug).** `memory-retrieval/index.mjs` now
  `mkdir -p`s the `MEMORY_DB` parent before opening the SQLite DB, in both the full and incremental
  paths. The DB lives under a gitignored dir (absent on every fresh clone), so the first
  `run.sh index` (and the hook's first reindex) died `unable to open database file` — and the hook
  swallowed the error, silently returning no memories. Now it self-heals. (`scripts/memory-mkdir-selftest.sh`)
- **`adopt` auto-ignores the machine-specific `.claude/settings.json`.** The project-scope plugin
  enablement embeds an absolute core path; adopt now adds it to the adopter's root `.gitignore`
  (byte-restore-recorded so `eject` reverses it), so a blanket `git add -A` can't commit a
  non-portable path.
- **`adopt` no longer leaks the calling session's env into the adoptee.** Adopting from inside
  another worker's session leaked that worker's `REPO_DIR`/`TELEGRAM_STATE_DIR` — cross-wiring the
  memory corpus and the registered channel. Adopt now reads the target's channel with the ambient
  vars unset, and stamps a resolved **absolute** `MEMORY_DIR` anchored on the target.

## core-v0.3 — 2026-07-08

Adopter-journey completeness, reversibility-hardened engine upgrades, and a self-healing supervisor.
Every slice adversarially reviewed; all seven gate suites green end-to-end. **Additive only — a v0.2
adopter pulls v0.3 with no config edits** (no existing `instance.env` name or manifest path changed).

- **The adopter journey, wired end-to-end (D→AAA).** `kickoff adopt` now delivers the full first run in
  one shot — the split charter, the `.kickoff/bin` seam shims, `.kickoff/.gitignore`, a self-pinned
  `core.lock`, adopter registration, `instance.env` stamps, and blank state seeds — and `eject` reverses
  **both** halves (including the files a `/adopt` session authors). A `live-config` seam class + an
  engine-prep fence close the last-mile gaps, proven by the un-stubbed `scripts/journey-e2e.sh`.
- **`kickoff pull` — reversibility-hardened upgrades.** The plugin-cache resync is verify-first (zero-churn),
  sibling-gated, and snapshot-reassert-or-rehash, so a pull never voids `eject`'s byte-restore; a new
  path-restricted `rehash-path` verb keeps the manifest honest.
- **`kickoff adopt --reconcile` — the already-adopted path.** Generates a manifest for a repo adopted before
  the manifest existed (the migration path), recording **only** provably-kickoff artifacts, zero adopter
  writes. Plus `kickoff status` and `adopt --dry-run`.
- **Identity/collision hardening (G10).** Ingress repo-guard, channel-registry clash detection, and
  REPO_DIR-anchored shim resolution — two adopters on one box never collide.
- **Supervisor auth self-heal — inert by default.** A token-expiry detector (`scripts/auth-heal.sh`) that
  fails toward inaction, escalates with one tokenless alert, and auto-resumes when auth returns; a one-tap
  `scripts/relogin.sh` re-login turnkey; and a meaningful restart announce. Armed per-instance via
  `KICKOFF_AUTH_HEAL` (unset ⇒ today's behavior, byte-identical).

**Contract changes since v0.2** (read before you pull):
- `scripts/core-manifest.txt` gains `scripts/auth-heal.sh` + `scripts/relogin.sh` (the self-heal capability
  now travels + pins), `scripts/templates/kickoff.gitignore` (the `.kickoff/.gitignore` seam template), and
  `scripts/templates/kickoff-README.md` (the `.kickoff/README` seam template).
- `instance.env` gains the optional `KICKOFF_AUTH_*` family (self-heal tuning; all inert unless
  `KICKOFF_AUTH_HEAL=1`). The plugin `version` is bumped to `0.3.0` (baked into this tag).
- **The new `.kickoff/README` seam is fresh-adopt only.** It's generated at `adopt` time on core-v0.3+; a
  pre-v0.3 adopter running `kickoff pull` will **not** retroactively receive it — `sync-seams` only
  regenerates seams already recorded in that adopter's own manifest. Gaining it needs a re-adopt (or
  `adopt --reconcile`, or a one-off `gen-readme`).

## core-v0.2 — 2026-07-07

The **brownfield adoption engine** — kickoff meshes into a repo you already have, additively and fully
reversibly, and upgrades by pulling a pinned tag. Built slice by slice, each adversarially reviewed, and
proven end-to-end.

- **`kickoff adopt` — additive mesh.** `scripts/adopt-manifest.py` wires kickoff into an existing repo and
  records every touch in `.kickoff/adopt-manifest.json` (the reversal spine). The *only* tracked change is a
  two-key merge into `.claude/settings.json` (`extraKnownMarketplaces.kickoff-local` +
  `enabledPlugins."kickoff@kickoff-local"`); your `CLAUDE.md`, crew, and `settings.local.json` are byte-untouched.
- **`kickoff eject --verify` — zero-trace reversal.** De-integrates entirely from the manifest and asserts
  `git status --porcelain` is empty afterward — every seam byte-restored to its exact pre-adopt bytes (the
  byte-restore is the FINAL write, undoing any tool re-serialization). Credential-safe (never reads
  `settings.local.json`); destruction-fail-safe (data archived + left in place by default). Proven end-to-end
  by `scripts/journey-e2e.sh` (adopt → run → serve → upgrade → eject on a realistic non-canonical repo).
- **The engine AS a Claude Code plugin.** `plugin/` packages the skills + crew + memory hook (`kickoff`
  v0.2.0) via a local-path marketplace, enabled at **project scope** by adopt — capabilities land with no
  copy-drift, stay cache-synced on `pull`, and are cleanly removed on eject.
- **Local serving.** `scripts/ingress.sh` (one Caddy, path-routed `/<project>/<app>`, loopback-bound, with a
  fail-closed drop-guard so a regen never silently drops a hand-edited route) + the two-tier `preview` skill
  put an adopted app on your phone over Tailscale.
- **The SEAM boundary + preflight #8.** A third class between the pinned ENGINE (`~/kickoff-core`) and your
  INSTANCE (your repo, untouched): the few additive edits adopt makes, recorded in the manifest and
  byte-restored on eject. `preflight` #8 verifies the seams; `kickoff pull` re-syncs seam templates from the
  new tag and refuses to clobber a hand-edited seam.
- **The adopter guide** `ADOPT.md` documents the full journey, and `README.md` leads with it.

## core-v0.1 — 2026-07-02

First tagged core: the adopt-by-pull mechanism and the parameter-clean boundary it rests on.

- **R1 — parameterize the instance boundary.** Everything that differs per adopter moved into ONE
  gitignored `.kickoff/instance.env` (copied from `scripts/instance.env.example`); the core scripts
  are parameter-clean and pulled unchanged. Fail-loud channel config (`TELEGRAM_STATE_DIR` has no
  default — silently inheriting a channel is the double-poller footgun), plus `MC_STATE_FILE` /
  `MC_TRACKER_FILE` and the retrieval-path vars so a pulled core resolves against the adopter's own
  data, not the shared clone.
- **R2 — fail-closed `preflight`.** `scripts/preflight.sh` turns the adopt-time WARNINGS into
  ASSERTIONS that run before a session starts (and from the supervisor on every start): instance.env
  present, worker channel distinct, memory index resolves, single supervisor, a deploy-fence when a
  push=deploy branch is declared, and (wired here for R3) the core.lock checksum. Fail-closed by
  construction — a false-pass green-lights a broken instance, so every ambiguous case leans FAIL.
- **R3 — the `kickoff pull` mechanism.** `scripts/kickoff pull [<tag>]` clones/fetches origin into a
  read-only pinned clone (`$KICKOFF_CORE_DIR`, default `~/kickoff-core`), checks out a `core-v*` tag
  detached, and regenerates `.kickoff/core.lock` (`<sha256>  <path>` per `core-manifest.txt` entry,
  paths relative to the clone). preflight check #6 then verifies that lock — closing the R1↔R2↔R3
  loop: **pull writes the pin, preflight enforces it**, so a copied-and-patched core file can never
  go unnoticed. Adds `scripts/core-manifest.txt` (the travelling core set) and this changelog.
  `kickoff pull` is a HUMAN-RUN turnkey (pulling a new core = self-modifying the code the box runs),
  never an auto-sync daemon.
- **The `kickoff` front-door CLI.** `scripts/kickoff` is the one command an adopter runs from a fresh
  clone, serving both journeys — NEWCOMER: `init` (scaffold `.kickoff/instance.env`) → `setup`
  (mechanical control-plane status, then the guided `/setup` skill) → `up` (start the supervisor;
  `--auto` for the autonomous worker); ADOPTER: `pull` → `preflight` → `up`. It does the DETERMINISTIC
  wiring and delegates the intelligent steps to Claude Code skills (`adopt` → `/adopt`, `setup` →
  `/setup`) — bash scaffolds, the skills reason. `kickoff up` is gated by the R2 preflight, so a
  mis-wired instance can't start.
- **Pre-ship hardening (adversarial review).** Before the first push, a 5-dimension adversarial
  review — every finding verified by re-triggering it in a fixture — found **19 issues** across
  R1+R2+R3+CLI (2 HIGH), all fixed here and re-verified by an independent adversarial pass:
  - **Pull-adopter DATA-path isolation (HIGH).** A pulled core running with `MC_STATE_FILE` / `MEMORY_*`
    unset no longer defaults the adopter's board + memory index into the *shared* core clone. The
    retrieval libs + `instance.env.example` now anchor on the adopter's own repo; `preflight` REQUIRES
    those vars set + resolving inside the repo when `core.lock` is present; and `mc-update.py` refuses
    to write when its default target is a detached-HEAD core clone. (kickoff-itself, on a branch, is
    never affected.)
  - **`instance.env` as UNTRUSTED config (HIGH).** Every launcher + `preflight` now sources it in a
    subshell that imports back ONLY the whitelisted var names, so a gitignored config file can no
    longer forge `PREFLIGHT_SKIP` / `DRY_RUN` (which closed a `kickoff up` preflight-bypass), redefine
    a check function, or run code in the launcher shell.
  - **`kickoff pull` supply-chain.** Refuses a dirty (hand-edited) read-only clone instead of laundering
    it; pins ONLY reviewed `core-v*` tags (dropped the any-ref fallback); CRLF-safe manifest; core.lock
    verifies the tree that actually runs and rejects path-escapes.
  - **preflight robustness + hygiene.** Structural deploy-fence validation (a deny that doesn't cover a
    bare `git push` no longer false-passes); canonicalized channel compare (trailing-slash / symlink
    can't disguise a shared channel dir); Telegram bot token fed off curl's argv; supervisor-log size cap.
  - **Strongest-model (Fable 5) final pass.** A second, independent review by the strongest model
    confirmed the above holds and caught **4 more** (all fixed, each reproduced in a fixture): a
    **symlink-path regression** in the new #6 running-tree check (`core_base` used `realpath` while
    `RUNNING_CORE_DIR` used a logical `pwd`, so a core clone under a symlinked `$HOME` false-failed and
    hard-stopped the worker — now both identity paths are canonicalized once); **`DEPLOY_BRANCH`
    undocumented** in `instance.env.example` (the deploy-fence trigger — a push=deploy adopter would
    never enable the fence; now a prominent "Deploy safety" section, plus `MC_TRACKER_FILE`/`CADENCE`);
    a missing **numeric-PID guard** in the supervisor lock (a corrupt `0` lock could false-read as a live
    supervisor); and the **`render-tracker` path** bypassing the detached-clone write guard.
