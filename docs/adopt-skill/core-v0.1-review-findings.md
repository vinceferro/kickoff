# core-v0.1 — adversarial pre-ship review: findings + fix plan

**Status: 19 confirmed findings (2 HIGH · 8 MEDIUM · 9 LOW), 4 refuted. FIXES PENDING — the push of core-v0.1 is HELD until these land.**

Run 2026-07-02 as the pre-ship gate the operator requested before pushing core-v0.1 (R1+R2+R3+CLI) to Bliz (a live payments product). A 5-dimension adversarial workflow (`wf_3c75ec57-9b4`): each dimension briefed to BREAK its part, then EVERY finding adversarially verified (try-to-refute, reproduced in fixtures). This file is the actionable fix plan — **work it theme by theme, re-verify each with the harnesses (`scratchpad/*-test.sh` are session-scratch and gone after a refresh; re-derive or re-run the committed logic), then re-tag `core-v0.1` at the new HEAD (force-move; it's unpushed) and report the clean push to the operator.**

Do NOT push (the operator's gated action). These are all reversible code fixes — apply them, re-verify, re-tag, report.

---

## THEME A — pull-adopter DATA path silently defaults into the shared core  (ship-critical)
Root: R1 parameterized the data-path vars but left them OPTIONAL (commented in the example) with a silent BASE_DIR/REPO_DIR default. A pull adopter running the UNCHANGED core from `~/kickoff-core` (with `$REPO_DIR` = their own repo) gets their board + memory index written INTO the core clone — cross-instance leak, blank board on the operator's phone, and preflight #6 never catches it (mission-state.json/TRACKER.md aren't in the manifest). This is the DATA-path twin of the R3 sibling-resolution bug. Give these vars the same treatment `TELEGRAM_STATE_DIR` and `KICKOFF_CORE_DIR` got.

- **[HIGH] #1 / #9 — MC_STATE_FILE / MEMORY_DB / MEMORY_HOOK_LOG / MEMORY_DIR have no fail-loud on unset.** `mission-control/mc-update.py:71` (`state_file = os.environ.get("MC_STATE_FILE") or BASE_DIR/mission-state.json`) + the retrieval defaults in `memory-retrieval/lib/memory.mjs` / `hook.mjs`.
  **Fix:** (1) Un-comment `MC_STATE_FILE`, `MEMORY_DB`, `MEMORY_HOOK_LOG` (and `MEMORY_DIR`) as ACTIVE lines in `scripts/instance.env.example` (like `KICKOFF_CORE_DIR` already is), each defaulting to a `$PWD/…`/repo-relative path so a copy-and-forget resolves into the adopter's OWN repo, not the core. (2) Add a **preflight assertion**: when `.kickoff/core.lock` exists (⇒ this IS a pull adopter) OR `KICKOFF_CORE_DIR` resolves outside `$REPO_DIR`, REQUIRE `MC_STATE_FILE`/`MEMORY_DB`/`MEMORY_HOOK_LOG` to be set AND resolve INSIDE `$REPO_DIR`; fail-closed otherwise. (3) Optionally in mc-update.py: refuse to write when `MC_STATE_FILE` is unset and BASE_DIR is a detached-HEAD git checkout (the core clone). Kickoff-itself / greenfield keep the BASE_DIR default (no core.lock ⇒ assertion skipped).
- **[MED] #7 / #10 — `kickoff preflight`/`up`/`pull` default `REPO_DIR` to the CORE clone for a pure-pull front-door invocation.** `scripts/kickoff:49-56` (`REPO_DIR="${REPO_DIR:-$(cd "$HERE/.." && pwd)}"`), same shape in `supervisor.sh:49-50`, `preflight.sh:39`.
  **Fix:** Detect the pure-pull case (front door running from a core clone whose own `../.kickoff/instance.env` is absent) and REQUIRE `REPO_DIR` with a targeted message ("set REPO_DIR=/path/to/your/repo — the front door is running from the read-only core clone"), instead of silently targeting the core. Document `REPO_DIR` as required for pull-adopter invocations.
- **[LOW] #15 — supervisor's run_preflight doesn't pass `KICKOFF_CORE_DIR`;** check #6 base depends on instance.env precedence. `supervisor.sh:109`. **Fix:** pass `KICKOFF_CORE_DIR` through explicitly (mirror cmd_pull), or record the clone base in core.lock at write time and verify against it.
- **[LOW] #19 — preflight #6 misdiagnoses a `KICKOFF_CORE_DIR` misconfig as "a core file was hand-edited".** `preflight.sh:167-184`. **Fix:** if NONE of the manifest paths exist under `core_dir`, report "KICKOFF_CORE_DIR ($core_dir) does not contain the pinned core — set it to your ~/kickoff-core clone" instead of a tamper message.

## THEME B — config-as-code: instance.env forges launch-control vars  (ship-critical, security)
Root: `kickoff up` and preflight SOURCE `instance.env` into their own shell and pass the WHOLE env through, so a gitignored config file (invisible in review) can forge `PREFLIGHT_SKIP`/`DRY_RUN`/`PERMISSION_MODE` or even redefine shell functions. Treat instance.env as untrusted-shaped CONFIG, not trusted code.

- **[HIGH] #2 — `PREFLIGHT_SKIP=1` in `.kickoff/instance.env` fully bypasses the preflight via `kickoff up`.** `scripts/kickoff` (sources instance.env ~line 62-64, then `exec env … supervisor`) + `supervisor.sh:98-103`. Reproduced: broken instance + skip line → "SKIPPING the fail-closed preflight" → "would start". Note the R2 review said PREFLIGHT_SKIP "can't be set from instance.env" — TRUE for a direct supervisor launch, but the CLI (built after) opened this path.
  **Fix:** PREFLIGHT_SKIP must be argv/pre-set-env-ONLY, never forgeable from config. In `scripts/kickoff` + `scripts/start-supervisor.sh`, `env -u PREFLIGHT_SKIP` when exec'ing the supervisor (strip any file-injected value), OR source instance.env in a SUBSHELL that exports back only the whitelisted config VAR names (`KICKOFF_CORE_*`, `MEMORY_*`, `MC_*`, `TELEGRAM_STATE_DIR`, `PERMISSION_MODE`, `EFFORT`, `MAX_CONCURRENT_AGENTS`), never the whole env.
- **[MED] #8 / [LOW] #17 — `kickoff up` grants autonomy without `--auto` (ambient `PERMISSION_MODE=auto` leaks through) + `DRY_RUN` flippable via inherited env.** `scripts/kickoff:356-387` (cmd_up).
  **Fix:** cmd_up must OWN these: initialise `permission_mode=default` / `effort=<default>` / `dry=0` and ALWAYS append `PERMISSION_MODE`/`EFFORT`/`DRY_RUN` to the `envs` array, with `--auto`/`--dry-run` flipping them. Then ambient values are always overridden, `--auto` is the ONLY source of auto, and the deliberate-grant note fires iff auto is actually in effect.
- **[LOW] #13 — instance.env is sourced into the preflight shell AFTER fail()/warn() are defined — it can redefine them or `exit 0`, neutering every check.** `preflight.sh` (fail() at line 53, source at 63). **Fix:** source instance.env in a subshell importing only whitelisted VAR names; or read values with a parser; treat it as untrusted-shaped input, not code.

## THEME C — pull supply-chain hardening  (MEDIUM)
- **[MED] #5 — re-pull launders a hand-edited (dirty) read-only clone → preflight #6 passes on backdoored core.** `scripts/kickoff:148`. **Fix:** after checkout, require `git -C "$core_dir" status --porcelain` empty (else die "core clone is dirty — must stay read-only"), OR `git reset --hard "$tag" && git clean -fdx` before the sha256sum. Don't trust `checkout --detach` to fail on a dirty same-tag re-pull.
- **[MED] #6 — tag resolver's `$tag^{commit}` fallback accepts ANY ref (branch/HEAD/raw SHA) → pins un-reviewed code, no changelog gate.** `scripts/kickoff:136`. **Fix:** resolve ONLY tags (keep `refs/tags/$tag^{commit}`, drop the bare `$tag^{commit}` fallback) and require the resolved name to match `core-v*`. If a raw SHA is ever wanted, gate behind an explicit `--commit <sha>` flag.
- **[LOW] #16 — CRLF manifest bricks pull with a misleading "files MISSING from tag" error.** `scripts/kickoff:164`. **Fix:** strip trailing `\r` (`line="${line%$'\r'}"`) or detect CRLF and emit an explicit message.
- **[LOW] #14 — core.lock verifies the `KICKOFF_CORE_DIR` tree, not the `SCRIPT_DIR` the supervisor actually executes — a patched running copy goes unnoticed.** `preflight.sh:167-188` vs `supervisor.sh:54`. **Fix:** default the checksum base to the supervisor's `SCRIPT_DIR` (or assert `SCRIPT_DIR == KICKOFF_CORE_DIR` for pull adopters); also reject absolute/`../`-escaping paths in core.lock before `sha256sum -c`.

## THEME D — preflight check robustness  (MEDIUM)
- **[MED] #3 — deploy-fence uses an unanchored substring regex; a deny that does NOT actually block a plain `git push` still passes.** `preflight.sh` check #5 (`tostring | test("git[[:space:]]+push")`). **Fix:** structurally validate the Claude rule shape — require a `Bash(...)` deny whose prefix actually covers a bare `git push` (e.g. `Bash(git push:*)` / `Bash(git push)`), reject entries with extra required args and non-Bash tools. Bliz is push=deploy, so this fence matters.
- **[MED] #4 — `TELEGRAM_STATE_DIR` vs ORIGIN/OPERATOR is an exact string compare; trailing slash / `.` / symlink evades the guard.** `preflight.sh` check #2 (lines 87-94). **Fix:** canonicalize all three with `realpath -m`/`readlink -m` before comparing.
- **[LOW] #12 — whitespace-only `TELEGRAM_STATE_DIR` bypasses the fail-loud in session-run.sh (preflight.sh already trims; session-run.sh does not).** `scripts/session-run.sh:67-79`. **Fix:** trim before the `-z` test (`[ -z "${TELEGRAM_STATE_DIR//[[:space:]]/}" ]`).

## THEME E — hygiene  (LOW, but #11 is a real secret-exposure)
- **[MED→do it] #11 — Telegram bot token exposed in curl's argv (readable via /proc/<pid>/cmdline + ps) on every worker restart announce.** `scripts/session-run.sh:142-147`. **Fix:** feed the URL off argv — `printf 'url=%s\n' "$api_url" | curl -s -o /dev/null --max-time 10 --data-urlencode chat_id=… --data-urlencode text=… -K -` (curl reads the URL from a config on stdin). Keeps the token out of the process table.
- **[LOW] #18 — `go-autonomous.sh` appends to supervisor.log forever, no rotation → disk-fill.** `scripts/go-autonomous.sh:31,66`. **Fix:** truncate/cap on start with a size guard. (Kickoff's own supervisor.log is already ~74MB — this bites.)

## Refuted (verify stage killed these — do NOT act):
placeholder-denylist-of-one (the empty + YOUR-WORKER guard is enough); ambient-TELEGRAM-leak (a test-env artifact, not a product bug); manifest `../`/absolute path escape (partially covered; #14 handles the real bit); tag `sort -V` signature/allowlist (out of scope for the drift threat model — core.lock is drift-not-tamper by design).

---

## After fixing
1. Re-verify: re-run the harness LOGIC (preflight fail-modes, pull e2e, CLI both-journeys, the pure-pull realistic e2e that caught the R3 sibling bug) — and add a case per fixed finding, especially the reproductions (MC_STATE_FILE-into-core; PREFLIGHT_SKIP-via-up; dirty-clone launder).
2. Confirm kickoff ITSELF still works (own supervisor boots, own preflight passes fresh-boot) and both journeys still pass.
3. Commit (theme-grouped commits or one "harden core-v0.1 per pre-ship review" commit), update CORE-CHANGELOG.md, **force-move `core-v0.1` to the new HEAD** (unpushed — `git tag -f -a core-v0.1`).
4. Report to the operator: review found 2 HIGH + 17, all fixed + re-verified, here's the clean push turnkey.
