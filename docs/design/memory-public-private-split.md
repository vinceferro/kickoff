# Memory public/private split — execution spec (proposed 2026-07-08, awaiting the operator's approval)

Unblocks the public re-ship (G-GF3: the public repo ships the maintainer's dev-state as a newcomer's grounding).
Full 85-row per-file table: task output `ad533bd91032e7ff5` (this session). The operator's principle:
[[memory-public-private-split-for-adopters]]. Ships via [[ship-public-subset-via-worktree-squash]].

**Tally (85 memory files): 51 PUBLIC · 29 PRIVATE→vault · 5 BORDERLINE.** KEY: PUBLIC ≠ ship-as-is — a
genericization SCRUB + a regenerated MEMORY.md + stubbed tracker/board are what actually close the leak.

## VAULT (29 private → move out of the public subset)
3d-universe-showcase-2d-board-cockpit · animations-data-driven-not-decoration · bliz-memory-is-a-deliberate-vault-backed-fork ·
bliz-repo-location-and-metrics · brownfield-devex-is-the-make-or-break · cc-token-expiry-kills-headless-worker ·
claude-kickoff-north-star-and-values · continuum-is-the-universe-at-work · dogfood-repo-is-the-live-engine ·
gpu-render-fix-is-additive · headless-worker-channels-config · human-facing-docs-shorter-direct-visual ·
keep-mission-control-live · kickoff-distribution-direction-installable-tool · lean-on-the-shipping-workflows ·
client-presentation-useful-wow · narrative-leads-the-project · operator-aesthetic-organic-over-geometric ·
operator-authorized-self-refresh · operator-offline-full-autonomy-cadence · operator-ping-on-every-reconnect ·
operator-reconnect-message-meaningful · operator-voice-no-first-person · operator-wants-proactive-initiatives ·
org-as-universe-genesis-from-telegram · rtk-corrupts-git-log-measurements · telegram-bridge-crash-recovery-via-refresh ·
unattended-worker-needs-pregranted-permissions · v1-shipped-roadmap-distribute-adopt-document

## BORDERLINE (5) — recommended resolution (pending the operator)
- cc-plugin-scope-and-cwd-gotchas → **SPLIT**: generic CC-plugin gotchas PUBLIC; kickoff-engine internals PRIVATE.
- plugin-spike-isolation-via-claude-config-dir → **SPLIT**: the CLAUDE_CONFIG_DIR technique PUBLIC; this-box framing PRIVATE.
- cross-org-contribution-loop → **PRIVATE** (Bliz-specific; the generic kernel is already in the-ai-org-operating-model).
- model-selection-fable5-vs-opus48 → **PRIVATE** (opt-in decisions + Bliz + staling model IDs; CLAUDE.md says answer model Qs from the `claude-api` skill).
- index-goes-stale-reindex-after-writing → **PRIVATE** (resolved dev-history, low adopter value).
- FLAG A — a-fix-he-cant-see-isnt-a-fix (classed PUBLIC): a real reporting principle, but the whole body is an operator/continuum story → **the operator's call: vault it, or keep with a heavy scrub.**

## SCRUB before the public push (~20 PUBLIC files embed instance specifics — strip, keep the principle)
- `<machine home>` (`/home/<user>`) paths: pull-adopter-scripts-resolve-siblings · fixture-can-mask (`~/bliz-memory`) · tooling-lives-in-the-repo · ship-public-subset.
- Ports / box services (`:9200`,`:9301`,`~/expose-mc.sh`): dont-broad-pkill · multiline-bash-collapses.
- Product names (Bliz/the client pitch): integrate-sibling-org · strongest-model-final-gate · memory-system-files-as-truth · fixture-can-mask.
- Operator identity / relationship stories: a-fix-he-cant-see (heaviest) · distill-learnings · principle-0 · dont-clobber-live-operator-state · memory-public-private-split · tooling-lives-in-the-repo.

## Derived-index + template stubs (regenerate for the public subset)
- **MEMORY.md** — regenerate: drop every private/borderline-private pointer line; scrub the remaining hooks (they leak Bliz/the client pitch/north-star/operator-prefs); verify no dangling `](file.md)`.
- **TRACKER.md** (384KB dev-history) → the public template ships a short **stub** (what-this-is / start-here).
- **mission-control/mission-state.json** (56KB live board) → a blank **skeleton** (empty in_progress/done/activity, placeholder headline).
- NOT a leak (confirmed): `.kickoff/supervisor.log` (118MB) is correctly gitignored.

## Execution (after the operator approves the approach + FLAG A + the borderlines)
1. In a SEPARATE worktree on `main` ([[ship-public-subset-via-worktree-squash]]): check out the engine + the 51 public memories (minus borderline-privates), NOT the private files, NOT the private history.
2. Scrub the ~20 flagged public files (strip paths/ports/product-names/identity; keep the principle).
3. Regenerate MEMORY.md; stub TRACKER.md + mission-state.json.
4. Also fold in the Phase-1/Phase-2 engine fixes (the D→AAA work) — this re-ship is core-v0.3.
5. Scan (secrets + no-private), tag `core-v0.3`, verify no-private + clean; the operator runs the gated push.
