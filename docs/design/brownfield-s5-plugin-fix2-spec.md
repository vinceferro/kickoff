# §5 THE PLUGIN — fix-round-2 spec (re-review findings)

The focused 2-lens re-review of fix-round-1 found 6 CONFIRMED (1 fix-introduced MEDIUM + 3 distinct LOW). All in `scripts/kickoff`. Fix at root; every regression test RED-on-pre-fix + the REAL trigger. Full detail/repro: `<session scratchpad>/tasks/w0xa05bap.output` (no longer resolvable — the finding text below is the durable record).

## FIX A — [MEDIUM] Fix-3 rollback DELETES the adopter's pre-existing settings.json when mktemp fails (fix-introduced data loss)
**File:** `scripts/kickoff` `_adopt_enable_plugin` (~660 capture; ~680-687 rollback).
**Root:** line 660 `existed=1; pre="$(mktemp)" && cp "$settings" "$pre"` — the bare `mktemp` can fail (unwritable/full/misconfigured `$TMPDIR`, out-of-inodes); `set -e` does NOT catch it (`pre=$(mktemp)` is the non-final command in an `&&` list). Result: `existed=1` but `pre=""`. On install-failure rollback, the guard `[ "$existed" = 1 ] && [ -n "$pre" ]` is FALSE → falls through to the else `rm -f "$settings"` → **DELETES the adopter's pre-existing settings.json** (permissions allowlist / MCP / hooks / env), with a MISLEADING log ("removed the settings.json that marketplace-add created" — it pre-existed). Sibling variant: mktemp ok but `cp` fails → `pre` non-empty but empty-content → restore branch `cp "$pre" "$settings"` overwrites settings.json with an EMPTY file (corruption).
**Fix:**
- The `rm -f "$settings"` delete branch must key on **`existed=0` ALONE** (only delete a file the add genuinely CREATED — no pre-existing file to lose).
- When `existed=1` but there is NO valid backup (`$pre` empty OR `! [ -s "$pre" ]`), **WARN-and-LEAVE** the mutated settings.json (a recoverable orphan — finding #2 from round 1 — is far better than deleting the operator's real config). Fix the log to be accurate (not "created").
- The restore branch must verify `[ -s "$pre" ]` (non-empty backup) before `cp "$pre" "$settings"`; if the backup is empty/missing, WARN-and-LEAVE, never overwrite with empty.
- Consider capturing `$pre` via `_open_secure_tmp`-style discipline or at least validating it, consistent with the repo's mktemp hygiene.
**Regression test (RED on pre-fix):** stub install-fail + a PRE-EXISTING committed settings.json + a `mktemp` that fails on the bare call (PATH-shim a fake mktemp that fails TMPDIR-based calls, delegates templated ones) → after `kickoff adopt`, settings.json is STILL PRESENT (pre-fix: ` D .claude/settings.json`). Also the cp-fail → no empty overwrite.

## FIX B — [LOW] eject --dry-run misreports the plan when `claude` is absent
**File:** `scripts/kickoff` cmd_eject dry-run branch (~1031).
**Root:** the last-adopter dry-run always prints "would uninstall + remove marketplace + sweep cache", but with `claude` absent the real run (Fix 6) SKIPS the whole user-global removal — so `--dry-run` misleads.
**Fix:** make the dry-run branch check `command -v claude` and report the ACTUAL behavior — "would SKIP user-global cleanup (claude absent; re-run with claude on PATH)" vs "would uninstall … + sweep cache". Keep it consistent with the real Fix-6 path.
**Regression test (RED on pre-fix):** `eject --dry-run` with `claude` absent → the plan reflects the skip (pre-fix: says "would uninstall …").

## FIX C — [LOW] Fix-6 claude-absent remediation is a dead-end (manifest removed same run → permanent orphan)
**File:** `scripts/kickoff` cmd_eject Fix-6 branch (~1016-1022).
**Root:** the warning says "re-run `kickoff eject` with claude on PATH to finish cleanup" — but eject REMOVES `.kickoff/` (the manifest carrying the machine entry) at the end of THIS run, so a re-run has no manifest → cannot clean up → the user-global marketplace + cache are orphaned with no recorded way to remove them.
**Fix:** replace the dead-end advice with the EXACT, self-contained manual cleanup commands, baked from the machine entry we are reading RIGHT NOW (so the operator has them even after the manifest is gone): `claude plugin uninstall --scope <scope> <plugin>@<mkt>; claude plugin marketplace remove <mkt>; rm -rf <cachepath>`. (The residue is harmless — nothing enables it, the repo keys are already reversed — but the guidance must be actionable, not circular.)
**Regression test (RED on pre-fix):** the claude-absent eject warning CONTAINS the concrete uninstall/marketplace-remove/rm-rf commands with the real mkt/plugin/cache path (pre-fix: says "re-run kickoff eject").

## FIX D — [LOW] register-at-adopt is best-effort → a registration failure re-opens the shared-cache tear (narrow residual)
**File:** `scripts/kickoff` cmd_adopt registration (~790-797) + cmd_eject last-adopter gate (~1003-1006).
**Root:** register-at-adopt is best-effort/non-fatal; if it silently fails, the adopter is absent from the registry → a sibling's `adopters-others` returns empty → the sibling's eject destroys the shared cache (the HIGH we closed, re-openable through a registration gap).
**Fix (proportionate for LOW — do NOT add fragile new destruction logic):**
- Make a register-at-adopt FAILURE **loud** (a prominent WARNING that this adopter is NOT registered → a sibling's eject may affect its shared plugin cache → re-run `kickoff adopt`/`kickoff pull` to register), not a quiet `log`.
- Add a cheap SAFE gate on eject's destructive path: proceed with user-global removal only if the registry is present AND contains THIS ejecting adopter (proof the registry is being maintained); if the ejecting adopter isn't even in its own registry, the registration path is unhealthy → conservatively LEAVE. (Fails safe; catches the "my registration failed" half.)
- Document the best-effort limitation in the design revision-log (the registry is the shared-cache-safety signal; a registration failure narrows same-tag protection; recoverable via re-adopt).
**Regression test (RED on pre-fix):** eject where the ejecting adopter is NOT in the registry (simulating a failed registration) → eject LEAVES the shared cache (pre-fix: removes it).

## After all fixes
- Re-run ALL suites (plugin/adopt/pull/eject/selftest) + scan-secrets — paste tallies. New regressions present + green + proven RED-on-pre-fix (state which).
- Confirm the live `~/.claude/plugins/` PRISTINE after + origin dogfood-inert.
- Reconcile the design revision-log with these fixes.
