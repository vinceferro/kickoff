# Phase-2 plan — Tier-2 (multi-adopter/plugin composition + operability)

Branch `brownfield-devex`, post-`1dbe950`. Architect-planned + coordinator-verified (all "primitive exists"
claims spot-checked against the current tree). Full per-item detail: the architect task output `ad0c0464fe7f212b9`.
Goal: a **second adopter on one box** is safe + a **live legacy adopter (Bliz) can migrate**.

## Report-vs-code drift (Phase 1 already changed the shape — reuse, don't rebuild)
- The G7 primitives EXIST: `adopters-others` sibling gate (adopt-manifest.py:1702) · `plugin-cache-verify`
  verify-first (adopt-manifest.py:527+, already wired into preflight #8 cache-half) · eject's snapshot +
  reassert-as-final-write (kickoff:1384/1449 snapshot, ~1505-1528 reassert incl. the absence case). G6/G7 =
  WIRE these into cmd_pull's `_resync_plugin_cache` (kickoff:360) + the resync loop, which currently ignore them.
- G10c is HALF-fixed: shims self-anchor for FINDING instance.env (`_here=$(dirname $0)`, adopt-manifest.py:129/
  144/159) but never PIN REPO_DIR → an ambient `REPO_DIR=<other>` or a foreign `$PWD` still retargets a shim.
- Register-always landed (kickoff:1081) → the registry is populated at adopt time; rows are `{repo,tag,
  version_dir}` — NO channel field yet (G10b needs one).
- adopt-selftest is GREEN (74/0) — no inherited RED. journey-e2e reconciled (Phase 1).

## Frozen contract — invariants every Phase-2 fixer honors
1. **File≠record never survives a kickoff write** — after kickoff's own write, reassert the exact bytes OR
   `rehash-path` the entry (never leave settings.json diverged from its recorded hash). (G6/G7 — the
   [[reversal-must-be-the-final-write]] fix for the PULL path.)
2. **Marketplace source == `$work_dir/plugin` after any plugin pull**; the machine entry upserts to match. (G6)
3. **No destructive shared-cache op unless positively sole** (`adopters-others` rc0 + EMPTY — eject's exact
   predicate, kickoff:1399-1402). (G7)
4. **Verify-first** — no claude invocation when `plugin-cache-verify` passes. (G7)
5. **Reconcile records only what it can PROVE** (template-byte-match or pure metadata); everything else is
   report-only; ZERO adopter-file writes. (G9)
6. **Eject tears down only identity-proven machine state** (ingress repo-guard; legacy/no-repo = skip + instruct,
   never cross-repo-delete on a guess). (G10a)
7. **Shims are self-anchored** — REPO_DIR derives from the shim's own location; explicit per-var overrides still
   win (the instance.env :20-22 contract). (G10c)
8. **Live-safety (Phase 1 verbatim):** never run the engine against this repo / `~/box-ingress` / `~/kickoff-core`;
   fixtures under the scratchpad with `env -u REPO_DIR` + explicit `REPO_DIR/KICKOFF_CORE_DIR/
   KICKOFF_ADOPTERS_REGISTRY/INGRESS_DIR/CLAUDE_CONFIG_DIR`; real-claude behavior tested ONLY under a sandbox
   `CLAUDE_CONFIG_DIR`; `bash -n`/`py_compile` before returning.

## DESIGN FORK — RESOLVED (coordinator, reversible; flag to the operator at checkpoint-2)
**#8 cache-half, different-tag plugin siblings:** the vendor CLI holds ONE installed plugin version per box, so
after adopter A's pull, adopter B's preflight cache-verify fails though B's headless worker is correct (immune
via `--plugin-dir`). **Resolution = sibling-aware WARN:** when the cache version == ANOTHER registered adopter's
pinned version (provable from registry `version_dir`s) → demote THAT mismatch to WARN ("interactive plugin serves
<repo>'s tag; headless unaffected; converge tags to clear"); any OTHER mismatch stays FAIL. (Keeps a legitimate
2-adopter box launchable; matches eject's conservative-shared-resource posture. The operator may flip to hard-FAIL =
one-tag-per-box.)

## Per-item (summaries — full detail in the architect output + each builder's brief)
- **G6** — plugin marketplace source frozen at the adopt-time machine path → worktree pull resyncs the wrong
  version + bricks fail-closed. Fix: re-point to `$work_dir/plugin` on any plugin-carrying pull (inside G7's
  snapshot/rehash envelope, since it rewrites settings.json).
- **G7** — cmd_pull's `_resync_plugin_cache` is destructive/un-gated/non-idempotent/byte-dirty/scope-blind. Fix:
  verify-first · sibling-gate · snapshot+reassert-or-rehash · scope-matched row read. + a NEW narrow
  `rehash-path` manifest verb (path-restricted to `.claude/settings.json`, updates only `sha256_at_write`).
- **G9** — `kickoff status` / `adopt --dry-run` / `adopt --reconcile` DON'T EXIST; Bliz (core.lock, no manifest)
  hits preflight #8 the moment it pulls this core, and the migration path is missing. BUILD all three
  (autonomous); reconcile records ONLY provable-kickoff artifacts (template-byte-match seams + settings plugin
  keys), touches NO adopter file/data path. **Applying reconcile to LIVE Bliz is GATED.** Update #8's FAIL text
  to name `adopt --reconcile` for the already-adopted shape.
- **G10** — (a) ingress teardown by BASENAME can delete a same-named sibling's live routes → add a `repo` field
  to the ingress registry + a `remove --if-repo` guard + honest no-op logging; (b) dead channel-equality check
  (env vars nothing sets) → registry-backed `--channel` field + `adopters-channel-clash` + preflight #2
  sub-check; (c) shims don't pin REPO_DIR → set+export REPO_DIR from the shim's own location before sourcing
  instance.env (explicit overrides still win).

## Work plan — sequential single-fixer main lane (kickoff/manifest/preflight interlock; never 2 agents on 1 file)
| Builder | Content | Model | RED-proven test |
|---|---|---|---|
| **B1** | G6+G7 plugin transport (cmd_pull resync + `rehash-path` + #8 WARN) | Fable | same-tag re-pull w/ plugin entry → ZERO uninstall/install in stub log; the composition (2 adopters diff tags → source==worktree, cache==pinned, settings byte-stable, sibling cache intact, auto-preflight green; adopt→pull→eject → --verify rc0) |
| **B2** | G9 reconcile/status/dry-run | Fable/Opus | core.lock+hand-wired no-manifest → #8 RED → reconcile → GREEN, zero adopter-file mtime change; dry-run → zero writes/claude-calls |
| **B3** | G10 ingress repo-guard + channel registry + shim REPO_DIR anchor | Opus | two same-basename repos → eject removes only its own; two rows same channel → FAIL; ambient REPO_DIR=<other>+foreign cwd → mc writes the shim's OWN repo state |
| **B4** | real-claude sandbox pass (`CLAUDE_CONFIG_DIR=<scratch>`) — re-point order, uninstall sweep, rows shape → then full suite + journey-e2e green | — | the sandbox transcript is the artifact; all green = exit gate |

Each builder: build → I verify + adversarial-review the trust-critical bits → local checkpoint. B1 (voids eject's
byte-restore if wrong) gets a full adversarial pass. The success criterion = B1's composition test (the untested
composition the validation named) + the whole suite + journey-e2e green.

## Gated vs autonomous
- **Autonomous:** all code · selftests · fixture runs · the real-claude pass under a sandbox `CLAUDE_CONFIG_DIR` ·
  branch commits.
- **Gated (one-line approvals for the operator's wake):** applying `adopt --reconcile` to LIVE Bliz + sequencing its
  core pull + the 2-DB/state merge · the public push · anything touching live `~/box-ingress`/caddy.
