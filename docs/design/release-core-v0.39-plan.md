# Release core-v0.39 + fleet opencode sweep

Date: 2026-08-22 · Status: PLAN LOCKED, build not started · Author: planner ses_fd4999206ffeN0FGLK8d2xMR0f, decisions applied by coordinator

## Goal-set

Ship core-v0.39 carrying the post-v0.38 fixes, then put every fleet org durably on opencode
via proper `kickoff pull` (not tonight's hand-edited env flips), verifying each org live.

## Verified starting facts

- Dev HEAD frozen at `a3e83842`, clean. Origin: git@github.com:vinceferro/kickoff.git
- Tags pushed: core-v0.37=dfa94a6d, core-v0.38=212b0e7f (cut today 18:55 UTC, carries WORKER_ENGINE seam dbc6907 + preflight lane e9a5325)
- Unreleased after tag: b4f7ef1 (pull: tags are origin's truth — force-fetch exact ref),
  cb77f2f (adversarial-gate fixes F1-F5: scripts/session-run.sh +30/-5, preflight.sh +1), a3e8384 (changelog restore)
- Fleet ALREADY flipped informally tonight (~20:05): every instance.env has KICKOFF_CORE_DIR=core-v0.38 +
  WORKER_ENGINE=opencode; 8 workers verified live on `opencode serve` across seven adopter orgs + this dogfood repo (concrete roster lives in the gitignored board log — never in committed docs)
- REGISTRY DRIFT: five of seven adopter rows in ~/.kickoff/adopters.json still say core-v0.37 while those repos RUN core-v0.38 (names in the gitignored board log); one legacy workspace row (core-v0.14, no channel) still present despite the item-46 registry fix

## Decisions applied (coordinator)

1. **the dogfood repo = verify-only** in the sweep (engine source; pulling onto own tag fights the dev tree)
2. **Dev frozen at a3e83842** until cut
3. **Dev-only consents** (stay out of public subset): scripts/burn-ledger.py, scripts/vibe-run.py,
   scripts/push-guard.sh, scripts/wire-red-first-into-charters.sh — all unreferenced host-wide
4. The legacy workspace row: EXCLUDED-LEGACY, untouched, named in the sweep report

## Ride / dev-only table

| RIDES v0.39 | Evidence |
|---|---|
| scripts/kickoff (b4f7ef1) | pull-tag fix; sweep trust depends on it |
| scripts/pull-selftest.sh (+32) | proof of the fix; gate runs it |
| scripts/worker-engine-selftest.sh (+238) | seam suite currently unregistered orphan |
| scripts/engine-identity-selftest.sh (+23) | already registered; tree must contain it |
| lefthook.yml, changelog, front-door pins | suite registry + release-authored files |

cb77f2f rides ONLY IF content-diff vs tag core-v0.38 shows session-run/preflight deltas unshipped.

## Slices

1. **S0 Freeze** — pin HEAD + SHAs. Proof: rev-parse == pin && porcelain empty ✅ done
2. **S1 Register suite** — worker-engine-test lane in lefthook.yml. Proof: parse shows 58 suites incl. worker-engine
3. **S2 Stage branch** — worktree squash → release/core-v0.39, parent==origin/main; changelog + front-door pins. Proof: diff-stat == approved path list exactly; zero stale install URLs
4. **S3 Gate** — release-gate candidate vs prev=core-v0.38. Proof: exit 0, 7/7, 58/58 GREEN, verdict+SHA logged
5. **S4 Adversarial pass** — separate break-it agent, read+run only; findings adjudicated; lenses dispatched == returned
6. **S5 Ship turnkey** — generator → ~/.kickoff/ship-v0.39.sh pinned to S3 SHA. NEVER executed by agents
7. **S6 TAP 1 ship** — operator: `bash ~/.kickoff/ship-v0.39.sh --push`. Proof: install URL 200 + sha match; tag on origin
8. **S7 Sweep build** — ~/.kickoff/sweep-v0.39.sh: per-org pull→cycle→/proc-verify→registry-write, serialized, resumable. Proof: dry-run prints drift table (stale rows + legacy), adopters.json checksum unchanged
9. **S8 TAP 2 sweep** — operator reviews dry-run, runs `--apply`. Proof: report all live orgs GREEN; rows match /proc reality; BLOCKED orgs named
10. **S9 Close-out** — post-cut URL check; tracker/memory/MC checkpoint

## Sweep design requirements

Per org: proper `kickoff pull core-v0.39` (never hand-edited envs; b4f7ef1 makes resolution trustworthy;
watch the lock-advances-before-seam-sync hazard) → cycle worker (supervisors keep launch env for life) →
VERIFY-THE-READ (/proc/<pid>/environ WORKER_ENGINE=opencode + opencode serve child + version dir + registry row agree).
Idempotent, resumable, serialized (one bot token = one poller; never cycle two workers at once).
Include the newest org too. Dogfood repo verify-only.

## Traps baked in

Front-door rot pins; RTK proxy → absolute binaries for load-bearing scans; flaky spawn-suites → deadline assertions not sleeps; freshness pins in turnkey refuse moved main/stale gate log; plugin bump REQUIRED if any plugin/ file differs (expect none); numbers measured fresh, never copied.

## Operator tap points

- **TAP 1:** `bash ~/.kickoff/ship-v0.39.sh --push` (after S3+S4 green)
- **TAP 2:** `bash ~/.kickoff/sweep-v0.39.sh --apply` (after reviewing dry-run drift table)

Expected gate: 58 suites (=57 + worker-engine-test); recount at S3 from the candidate tree.
