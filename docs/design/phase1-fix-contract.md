# Phase-1 fix pass — FROZEN CROSS-FILE CONTRACT (single source of truth for all fixers + reviewers)

Branch `brownfield-devex`. Drives the adopter journey **D→AAA** (spec: `docs/design/brownfield-greenfield-validation-2026-07-07.md`).
Authored by a Fable contract-architect, **every load-bearing claim below verified against the code by the
coordinator** (actions/classes @76-77 ✓, eject marker bug @1315 ✓, gen-charter dead-code ✓, cmd_adopt @770/794 ✓,
SHIM_DIR @116-137 ✓, preflight #8 filter @518 ✓, SKILL.md cp-scan @29 ✓, instance.env.example defaults ✓).

**RULE FOR EVERY FIXER:** edit ONLY your partition's files. Honor sections A–H exactly (they are the shared
interface — divergence between two fixers is the #1 failure mode). Do NOT touch the selftests (`*-selftest.sh`)
or `journey-e2e.sh` — they assert OLD behavior and are reconciled in a SEPARATE slice after this pass; do not
try to keep them green. **LIVE-SAFETY:** THIS repo is the live worker's engine — never run the engine
(`kickoff adopt/pull/up/eject/init`) against this repo; test only in a throwaway `/tmp/.../scratchpad` fixture
with an explicit `REPO_DIR=<fixture>`; never touch `~/box-ingress`, caddy, `~/kickoff-core`, the live `.kickoff/`,
`mission-control/mission-state.json`, or any other repo. No git commit/push/checkout. Syntax-gate your file
(`bash -n` / `python3 -m py_compile`) before returning.

---

## A. Manifest record API — exact call per touch-kind

Engine: `scripts/adopt-manifest.py`. `ACTIONS = ("created","modified","block-appended","json-merged","hook-installed")` (:76);
`CLASSES` becomes `("seam","seeded-instance","live-config")` after F3 adds `live-config` (:77). `record` CLI @:1684-1698.
From bash use `"$HERE/adopt-manifest.py"`; from a skill use `"$KICKOFF_CORE_DIR/scripts/adopt-manifest.py"`.

| Touch | Exact call | Status |
|---|---|---|
| created file (engine, byte-stable) | `record --repo <r> --path <p> --action created --class seam --source <tag>` (record AFTER creating). Hashed by preflight #8. | exists |
| created file (adopter deliverable) | `record --repo <r> --path <p> --action created --class seeded-instance --source authored-for-repo` | exists |
| created `.claude/settings.json` (fresh) | `record --repo <r> --path .claude/settings.json --action created --class live-config --source <tag>` | **NEW class §B** |
| block-appended (CLAUDE.md @import) | save pre-edit bytes to a tmp FIRST → `record … --action block-appended --class seam --source <tag> --original-from <tmp>` (:366-386) | exists, NEVER called by journey (G2) |
| json-merged (pre-existing settings.json) | `record … --action json-merged --class seam --source <tag> --original-from <pre>` — live @kickoff:727 | exists |
| scanner/engine shim | `gen-shim --repo <r> --name <mc\|scan-secrets\|scan-structure> --source <tag>` → `.kickoff/bin/<name>` 0755 + created/seam upsert (:692-714) | `mc` exists; 2 NEW templates §C |
| charter pair | `gen-charter --repo <r> --source <tag>` → `.kickoff/KICKOFF.md` (created/seam) + `.kickoff/KICKOFF.local.md` (created/seeded-instance, seeded once) (:717-759) | exists — **DEAD CODE** (only selftest callers) |
| `.kickoff/.gitignore` | `gen-gitignore --repo <r> --source <tag>` → from NEW template `scripts/templates/kickoff.gitignore`, created/seam upsert | **NEW verb + template §G** |
| plugin machine entry | `plugin-record …` — live @kickoff:743 | exists |
| `hook-installed` | settings.local.json ONLY (jq-paths + `--hook-sha256`). **No Phase-1 flow uses it** — do not conflate with git hooks/lefthook. | exists, unused here |

Rules (do NOT violate): `--original-from` MANDATORY for modified/block-appended/json-merged, FORBIDDEN for created/hook-installed (:354-386);
secret-bearing basenames (`settings.local.json`) may only ever be `hook-installed` (:319-322); paths repo-relative, no absolute/`../` (:240-248).

## B. Seam-class taxonomy (item 7)

- `seam` — engine-generated; the ONLY class preflight #8 whole-file-hashes (jq `select(.class=="seam")|select(.action=="created")|select(.sha256_at_write!=null)` @preflight.sh:518). `sync-seams` regenerates only `class=="seam"` (:806-807).
- `seeded-instance` — adopter deliverable; kept by eject unless `--purge-seeded` (:1386); never regenerated.
- **NEW `live-config`** — a file kickoff CREATED but the live system legitimately mutates (an accepted permission prompt rewrites `.claude/settings.json`). Contract:
  - F3 adds it to `CLASSES` (:77) + the schema docstring (:20-31).
  - Preflight #8 needs **NO logic change** — the `class=="seam"` filter @:518 already excludes it (verified). F4 adds ONLY a comment naming the class so the exclusion is deliberate.
  - Reversal: normal `created` path (delete iff hash matches, keep on divergence, :1063-1094). Not kept-by-default (that gate is `seeded-instance`-only @:1386), not synced (not `seam` @:806). The complete set of `class` consumers is :1386, :806, preflight.sh:518, kickoff:976-978 — no others.
  - SOLE Phase-1 user: kickoff:734 (the created-settings branch) changes `--class seam`→`--class live-config`. The json-merged branch @kickoff:727 stays `seam`.

## C. `.kickoff/bin` scanner shims (item 2)

Precedent: `SHIM_DIR=".kickoff/bin"` + `_MC_SHIM` template @:116-137; registry `SHIM_TEMPLATES={"mc":_MC_SHIM}` @:135-136; written+recorded by `gen-shim`, regenerated by `sync-seams`, hash-pinned by #8; 0755 via :666.
- F3 adds `"scan-secrets"` + `"scan-structure"` to `SHIM_TEMPLATES`, same shape as `_MC_SHIM`: source `.kickoff/instance.env`, exec `"$KICKOFF_CORE_DIR/scripts/scan-secrets.sh" "$@"` / `scan-structure.sh`, missing-engine → clear message + `exit 1`. Land at `.kickoff/bin/scan-secrets` + `.kickoff/bin/scan-structure` (0755, machine-path-free, byte-identical across adopters).
- F1 calls `gen-shim` for all three in cmd_adopt (today only `mc` @:794).
- Eject removes them via the ordinary created/seam reversal — no new eject code.
- F2 stops instructing `cp scripts/scan-*.sh` (SKILL.md:29-31); references `.kickoff/bin/scan-*` in the lefthook stanzas.

## D. Runtime layout — CORPUS is a tracked asset, CACHES are ignored (items 5, 8a) — **[coordinator revision of the architect's §D: the memory CORPUS is a durable adopter asset, NOT throwaway state, so it is TRACKED under `.kickoff/memory/`, not buried under ignored `.kickoff/state/`]**

New `instance.env.example` defaults (current repo-root defaults @:55/:61/:67/:68/:84/:88; false ".kickoff/ is gitignored" @:13):

```
MEMORY_INDEX    .kickoff/memory/MEMORY.md                                        (was memory/MEMORY.md :55)
MEMORY_DIR      ${REPO_DIR:-$PWD}/.kickoff/memory                                (:61)   ← TRACKED asset (the .md corpus)
MEMORY_DB       ${REPO_DIR:-$PWD}/.kickoff/state/memory-retrieval/memory-index.db        (:67)  ← ignored cache
MEMORY_HOOK_LOG ${REPO_DIR:-$PWD}/.kickoff/state/memory-retrieval/retrieval-log.jsonl    (:68)  ← ignored log
MC_STATE_FILE   ${REPO_DIR:-$PWD}/.kickoff/state/mission-control/mission-state.json       (:84)  ← ignored runtime
MC_TRACKER_FILE (commented) ${REPO_DIR:-$PWD}/.kickoff/state/TRACKER.md          (:88)   ← ignored render
```

- **Rationale:** the memory `.md` corpus is the adopter's accumulated knowledge (a durable asset, team-shareable, like source). The DB/logs/board/tracker-render are derived + churning (the real G4 offenders). Namespacing the corpus under `.kickoff/memory/` (vs repo-root `memory/`) also avoids colliding with an adopter's pre-existing `memory/`.
- Eject relocation is FREE: any path under `$kdir` is `inside` → relocated to `kickoff-data/` on default eject (:1221-1289). Both `.kickoff/memory/` and `.kickoff/state/` relocate. State files are runtime data, handled by the instance.env data-path — **never manifest-recorded**.
- Blank seeds (init AND adopt, when ABSENT — never clobber): `.kickoff/memory/MEMORY.md` = a 2-3 line stub header; `.kickoff/state/mission-control/mission-state.json` = EXACTLY mc-update.py's `_skeleton()` shape `{"project":"<basename>","headline":"","human_plate":[],"in_progress":[],"functions":[],"blocked":[],"decided":[],"done":[],"activity":[]}` (mc-update.py:125-127). **Load-bearing:** with MC_STATE_FILE exported, a missing file makes mc-update.py FATAL (:139-142). TRACKER render needs no seed.
- Preflight #3's hardcoded `memory/MEMORY.md` (:277) becomes a CHAIN: `MEMORY_INDEX` if set → `.kickoff/memory/MEMORY.md` if it exists → `memory/MEMORY.md` (keeps kickoff-itself + Bliz green — both live on repo-root `memory/` via their OWN instance.env/defaults; the EXAMPLE change never touches a live instance.env).

## E. Charter delivery (items 1, 3)

- **gen-charter interface:** `python3 scripts/adopt-manifest.py gen-charter --repo <target> --source <tag>` → `.kickoff/KICKOFF.md` (seam, from `scripts/templates/KICKOFF.md`) + `.kickoff/KICKOFF.local.md` (seeded-instance stub, :155-171) + both receipts. cmd_adopt calls it right after the shims.
- **@import block cmd_adopt appends to the adopter root `CLAUDE.md`** — EXACT bytes (strip-regex @adopt-manifest.py:1006-1010 requires the leading `\n` before `begin` and a newline after `end`):
  ```
  \n<!-- kickoff:begin <tag> -->\n@.kickoff/KICKOFF.md\n<!-- kickoff:end -->\n
  ```
  appended verbatim, no other normalization. **Idempotence guard:** skip the append if the file already contains `<!-- kickoff:begin` (re-adopt / teammate clone must not double-block).
  - CLAUDE.md pre-exists → `record --action block-appended --class seam --original-from <pre-copy>` (byte-restore primary; strip fallback @:1103-1131; #8 never hashes block-appended @:513-518).
  - CLAUDE.md absent → create it = EXACTLY the 3 block lines + trailing newline (NO leading `\n`) → `record --action created --class seeded-instance --source authored-for-repo`.
- `--source` tag: `git -C $core_dir describe --tags --exact-match` when the core clone exists, else `_core_tag()` (kickoff:644-649) — same resolution kickoff:824-826 uses.
- **mc-shim contract text into `scripts/templates/KICKOFF.md`:** add a short "The engine seam" section — MC updates go through `.kickoff/bin/mc` (never `python3 mission-control/mc-update.py`, which doesn't exist in an adopter repo); scanners via `.kickoff/bin/scan-secrets` / `scan-structure`; a shim reporting the engine missing → run `kickoff pull`.

## F. lefthook (item 2) + eject-unhook

- Kickoff gates live in a NEW adopter file `.kickoff/lefthook-kickoff.yml`: pre-commit `secret-scan: bash .kickoff/bin/scan-secrets --staged`, pre-push `structure-scan: bash .kickoff/bin/scan-structure` (mirroring lefthook.yml:25-46) + the stack gates /adopt fills. Recorded created/seeded-instance (stack-tuned = adopter-owned, never regenerated).
- Root `lefthook.yml`: absent → author with `extends: [.kickoff/lefthook-kickoff.yml]` + a `# kickoff` marker comment, record created/seeded-instance. Present → save pre-copy, add the `extends` entry minimally, record modified/seam `--original-from <pre>` (byte-restore; #8 does not hash `modified`). Do NOT use `<!-- kickoff:begin -->` markers inside YAML — the strip regex needs the marker at raw line start (:1006-1008); a `#`-prefixed marker never strips.
- `/adopt` runs `lefthook install`; the UNHOOK is a **cmd_eject step (F1)**: in step (5) machine unwiring, when the manifest lists `lefthook.yml` or `.kickoff/lefthook-kickoff.yml` and `command -v lefthook` → `( cd "$target" && lefthook uninstall )` best-effort, dry-run aware.

## G. `.kickoff/.gitignore` — EXACT contents (Fork 1 resolved; RESOLVE 4 resolved) — **[coordinator: `memory/` TRACKED per §D; `KICKOFF.local.md` TRACKED; `core.lock` IGNORED]**

Written by `gen-gitignore` from `scripts/templates/kickoff.gitignore`; recorded created/seam; regenerated on pull; hashed by #8:

```
# kickoff — generated by `kickoff adopt` (recorded in .kickoff/adopt-manifest.json; regenerated on `kickoff pull`).
# TRACKED on purpose (team-shareable): KICKOFF.md, KICKOFF.local.md, bin/, memory/, this file.
# Instance-private config + derived runtime never reach origin:
instance.env
adopt-manifest.json
core.lock
state/
supervisor.lock
supervisor.log*
announce.lock
```

Note for docs (F6): for the seams to actually track, the adopter's ROOT `.gitignore` must NOT wholesale-ignore `.kickoff/` — adopt does not add it; a dir-local `.kickoff/.gitignore` selectively ignores the private bits.

## H. Canonical journey order — clone → pull → adopt

Docs currently order adopt before pull (README:66-72, ADOPT.md:20-37/:104-106 vs :143). The one true sequence:
1. `git clone <kickoff>` (+ optional symlink — works once F1 lands `readlink -f`)
2. `kickoff pull [core-vX]` — from the fresh clone this is **engine-prep** (see F1 pull-fence): clones+pins `~/kickoff-core`, never writes core.lock into the source checkout
3. `kickoff adopt --dir ~/my-repo` — wires, self-pins core.lock, registers, stamps `KICKOFF_CORE_REMOTE`/`KICKOFF_CORE_DIR`, delivers the charter block
4. `/adopt` in a Claude Code session in the repo — authors CLAUDE.md content/crew/tracker/memory, **records every touch seeded-instance**
5. `kickoff preflight` → `kickoff up`

Greenfield = create-then-adopt (F5): bootstrap scaffolds OUTSIDE the clone, `git init` + baseline, then step 3 `--dir <new project>`. A kickoff source checkout upgrades via `git pull`, never `kickoff pull`.

---

# COORDINATOR RESOLUTIONS (the 7 forks — all resolved; fixers follow these)

1. **Selftests + journey-e2e**: NOT in any partition; a SEPARATE post-pass slice reconciles them (RED-proven). Fixers do NOT touch `*-selftest.sh` / `journey-e2e.sh`.
2. **Pull-fence shape = "engine-prep mode"** (confirmed, not hard-refuse): `kickoff pull` when (`$REPO_DIR/.kickoff/adopt-manifest.json` absent AND the running tree resolves inside `$REPO_DIR`, i.e. REPO_DIR is the kickoff source clone) → do clone/fetch/tag-resolve/detach/clean-verify/changelog ONLY, then STOP before the core.lock write (kickoff:512), printing: this is a kickoff source/greenfield checkout — it upgrades via `git pull`; core pinned at `<tag>` in `$core_dir`; next: `kickoff adopt --dir <your repo>`. Never core.lock/seam-sync/register/auto-preflight in this mode. (create-then-adopt means real greenfield projects have a manifest + core outside REPO_DIR, so they pull normally — this fence only ever catches the source-clone-prep case.)
3. **Two skill trees**: `.claude/skills/{adopt,bootstrap}/SKILL.md` are byte-copies of the `plugin/skills/` ones. F2 owns BOTH adopt copies; F5 owns BOTH bootstrap copies — apply IDENTICAL edits to keep them byte-equal.
4. **Fork-1 residue**: `KICKOFF.local.md` TRACKED (the adopter's own charter conventions, secret-free, team-shareable — the seam @imports it); `core.lock` IGNORED (per-box verification state). See §G.
5. **`live-config` scope**: ONLY `.claude/settings.json`. A kickoff-created `CLAUDE.md` is `created/seeded-instance` (kept by default, `--purge-seeded`-able).
6. **Eject-unhook** (lefthook uninstall) is a `cmd_eject` change → **F1 owns it** (§F). F2 authors the wiring; they agree on the file/marker names via §F.
7. **Memory root = ONE root, `.kickoff/memory/` (tracked corpus)** per §D; derived caches → `.kickoff/state/` (ignored). /adopt authors into `.kickoff/memory/`; adopt/init seed `.kickoff/memory/MEMORY.md`; the hook + preflight #3 chain target it (with a repo-root `memory/` fallback for the live kickoff/Bliz instances).

---

# PER-FILE WORK ORDERS

## F1 — `scripts/kickoff` (+ `scripts/templates/KICKOFF.md`, `scripts/core-manifest.txt`) — model Fable, keystone

1. **Symlink-proof `$0`** (kickoff:50): `HERE="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")")" && pwd)"`. [item 3]
2. **Pure-pull guard** (kickoff:77-90): extend the case list `up|pull|preflight` with `init|adopt|eject`, but ONLY fire when no `--dir`/`--dir=` appears in the args (cmd_eject:911-913 documents the `--dir` false-fire). [item 3]
3. **cmd_adopt core-clone self-guard**: mirror cmd_eject:914-925 at the top of cmd_adopt (kickoff:780-782) — refuse when the resolved target IS `$KICKOFF_CORE_DIR` or a detached-HEAD `core-v*` checkout. [item 3]
4. **cmd_adopt wiring** (kickoff:770-859), after `scaffold_instance_env`, in order:
   - gen-shim `mc` (exists @:794) + gen-shim `scan-secrets` + `scan-structure` [§A/§C]
   - `gen-gitignore` [§A/§G]
   - `gen-charter` + the CLAUDE.md @import append + record, WITH the idempotence guard [§E]
   - **self-pin**: when `$_core_dir` exists at an exact `core-v*` tag with a clean tree → write format-2 `core.lock` into the target (factor/reuse the write @kickoff:512-540); else log + continue
   - **register ALWAYS** (not only in the plugin arm — today @:827 is inside plugin-enabled): `adopters-register --repo <target> --tag <tag> --version-dir $_core_dir` whenever the core clone exists
   - **stamp instance.env**: generalize `_persist_core_dir_to_instance_env` (:258-274) to persist `KICKOFF_CORE_DIR=$_core_dir` AND `KICKOFF_CORE_REMOTE=$(git -C $_core_dir remote get-url origin)` into the target instance.env
   - seed blank state when absent: `.kickoff/memory/MEMORY.md` stub + `.kickoff/state/mission-control/mission-state.json` skeleton [§D]
   - **conditional handoff** (:853-857): plugin enabled → "run `/adopt`"; core/plugin absent → "run `kickoff pull` first, then re-run `kickoff adopt`" [item 3]
5. **cmd_pull**:
   - remote fallback (:366-373): prefer the RUNNING tree's origin (`git -C "$HERE/.." remote get-url origin`) over `$REPO_DIR`'s origin — the root-cause fix for G3c ("first pull clones the adopter's OWN product")
   - **origin verify** on an existing clone (:380-383): `git -C $core_dir remote get-url origin` must equal `$remote`; mismatch → die naming both URLs
   - **engine-prep fence** [RESOLUTION 2 — implement exactly as written there]
6. **cmd_eject --verify honesty** (item 6):
   - marker grep (kickoff:1314-1315): replace `-e 'kickoff@local'` with `-e 'kickoff-local'` (matches both `extraKnownMarketplaces."kickoff-local"` and `enabledPlugins."kickoff@kickoff-local"`)
   - non-git target: before :1347, `git -C "$target" rev-parse --git-dir` — absent → print "NOT a git repo — the byte-for-byte proof is unavailable" and set the verify rc to a qualified FAIL, instead of `|| true` reporting CLEAN
   - **relocate kept/diverged in-`.kickoff` files BEFORE step-7's `rm -rf "$kdir"`** (:1291-1298): after step 4 (non-dry), for each manifest `entries[].path` under `$kdir` that still exists (kept `KICKOFF.local.md`, any diverged seam, the `.kickoff/memory/` corpus) → `mv` to `$data_target/<path rel to .kickoff/>` with the step-6 collision-divert discipline (:1272-1281)
   - **allowlist the kept deliverable in --verify**: `kept_crew` is captured (:975-978) but unused by the porcelain classifier (:1355-1373) + the marker grep — post-item-2 every default eject keeps recorded seeded-instance files, which would falsely read as residue. Exclude kept seeded-instance paths (exact + dir-prefix) from BOTH the grep and the porcelain classification; when a kept CLAUDE.md retains the block, log that its `@.kickoff/KICKOFF.md` import now dangles.
   - lefthook unhook in step 5 [§F, RESOLUTION 6]
7. **cmd_init** (kickoff:752-767): seed blank state per §D (idempotent, never clobber). [item 8a]
8. `scripts/templates/KICKOFF.md`: add the engine-seam/mc-shim section [§E]. `scripts/core-manifest.txt`: add `scripts/templates/kickoff.gitignore` (must travel, like :52) + fix the ".kickoff/ … gitignored" comment (:10-11).

## F2 — `plugin/skills/adopt/SKILL.md` AND `.claude/skills/adopt/SKILL.md` (identical edits) — model Fable

- Replace step 5's copy instruction (:29-31): scanners via the recorded `.kickoff/bin/scan-secrets` / `scan-structure` shims [§C]; lefthook via `.kickoff/lefthook-kickoff.yml` + root `extends` [§F], spelling out the exact record calls.
- Add a HARD rule + exact commands: **every file this skill authors is recorded** — `python3 "$KICKOFF_CORE_DIR/scripts/adopt-manifest.py" record --repo . --path <p> --action created --class seeded-instance --source authored-for-repo` (`KICKOFF_CORE_DIR` from `.kickoff/instance.env`); an edit to a PRE-EXISTING adopter file → `--action modified --class seeded-instance --original-from <pre-copy>`. Concrete set: `TRACKER.md`, the `.kickoff/memory/` seeds, `.claude/agents/*.md`, `.kickoff/lefthook-kickoff.yml` (+ root `lefthook.yml` if modified). [item 2 — the skill has ZERO record instructions today]
- State the consequence: this is what makes `--purge` real (ADOPT.md:163) and `--verify` honest.
- Note the charter is now delivered by `kickoff adopt` (the block + `.kickoff/KICKOFF.md`); the skill fills `.kickoff/KICKOFF.local.md` + CLAUDE.md content, not its own wiring. Memory the skill authors goes to `.kickoff/memory/` [§D].

## F3 — `scripts/adopt-manifest.py` + `scripts/instance.env.example` (+ NEW `scripts/templates/kickoff.gitignore`) — model Opus

- Add `live-config` to `CLASSES` (:77) + schema docstring (:20-31) [§B].
- Add `scan-secrets` + `scan-structure` to `SHIM_TEMPLATES` (:135-137) [§C].
- Add a `gen-gitignore` subcommand (mirror `gen-charter`'s seam half @:717-741) + register the template mapping (like `FILE_SEAM_TEMPLATES`/:147-149) + create `scripts/templates/kickoff.gitignore` with §G's EXACT contents. Confirm `_seam_mode` → 0644 for a non-`bin/` path (:662-666).
- Fix the stale comment @:100-103 (".kickoff/.gitignore" now exists + is scaffolded/recorded).
- `instance.env.example`: retarget :55/:61/:67/:68/:84/:88 to §D's paths (corpus `.kickoff/memory/`, caches `.kickoff/state/`); fix the false claim @:13 → ".kickoff/ is PARTLY tracked; the generated `.kickoff/.gitignore` keeps instance.env + derived state out of git." (kickoff:734's class change is F1's call-site edit, not yours.)

## F4 — `scripts/preflight.sh` — model Opus

- **#8**: add a one-line comment (near :518/:544) that `live-config` entries are deliberately NOT hashed (the jq filter already excludes any non-`seam` class — no logic change). Extend the manifest-missing FAIL text (:505-506) with the greenfield recovery: "a kickoff source/greenfield checkout that accidentally pulled: `rm .kickoff/core.lock` and upgrade via `git pull`". [items 7, 4]
- **#1b** (:207-242): no predicate change; update the FAIL remediation text to name the new `.kickoff/state/` + `.kickoff/memory/` defaults ("scaffolded by `kickoff adopt`/`init`").
- **#2** (:244-259): keep fail-closed (Fork 2). Rewrite the FAIL text: a DEDICATED channel dir is REQUIRED for the worker; NO bot token is needed to pass this check; the bot is wired later via `kickoff setup` + `/setup`.
- **#3** (:274-286): fallback CHAIN per §D (`MEMORY_INDEX` → `.kickoff/memory/MEMORY.md` if present → `memory/MEMORY.md`); FAIL text names the remediation (`kickoff init`/`adopt` seeds the stub).

## F5 — `plugin/skills/bootstrap/SKILL.md` AND `.claude/skills/bootstrap/SKILL.md` (identical edits) — model Opus

- Rewrite the scaffold step (:29-35) + "Wire the quality machinery" (:54-63): **create-then-adopt**. Scaffold into a NEW dir OUTSIDE the kickoff checkout (DELETE the "into the kickoff repo itself" allowance @:60-63), `git init` + a baseline commit, then `bash <kickoff>/scripts/kickoff adopt --dir <project>` (delivers shims, `.gitignore`, charter block, core.lock pin, state seeds, plugin). [item 4]
- Quality machinery: scanners via `.kickoff/bin/scan-*`; gates in `.kickoff/lefthook-kickoff.yml` [§F]; no copying `scripts/scan-*.sh` / `lefthook.yml` from the clone.
- Upgrade split: the new project upgrades its engine via `kickoff pull`; a kickoff source checkout via `git pull` (`kickoff pull` refuses that shape).

## F6 — `README.md` + `ADOPT.md` — model Opus

- **Order**: rewrite README:66-72 + ADOPT.md:20-37/:98-110 to §H clone → pull → adopt (pull moves from Upgrade-only @ADOPT.md:143 to step 2; adopt's plugin note @:104-106 stops being impossible-on-first-run).
- **Zero-trace honesty** (item 10): README:56-61 ("the *only* tracked change is a two-key merge") is FALSE post-fix — adopt now also lands tracked seams (`.kickoff/KICKOFF.md`, `KICKOFF.local.md`, `bin/`, `.gitignore`, `memory/`, the CLAUDE.md block). Restate README:71/:196 + ADOPT.md:6-11/:26: everything adopt/`/adopt` touches is RECORDED and reversed; eject byte-restores seams, keeps your deliverable (crew/CLAUDE.md/tracker/memory — relocated or left, allowlisted by `--verify`), and cannot un-make commits. Name what IS tracked vs ignored (§G).
- **Telegram** (Fork 2): README:96 "*(optional)*" → a dedicated channel dir is REQUIRED to run the worker (`kickoff up` preflights fail-closed on it); the bot/pocket loop is the optional layer.
- ADOPT.md "Adopt" section: document what adopt now writes (shims ×3, `.gitignore`, charter pair + block, core.lock self-pin, registry row, stamped instance.env, state seeds) + that `--purge` is now real (:163) + the teammate-clone note (a fresh clone runs `kickoff adopt` once to regenerate its local manifest/lock; the block-append is idempotent).
- Greenfield: README:77-93 → create-then-adopt story; document `kickoff init` (in ZERO docs today) as the maintainer/source-checkout mode; note "greenfield upgrades via `git pull`".
