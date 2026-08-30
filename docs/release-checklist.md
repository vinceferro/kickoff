# Release checklist — shipping a `core-v*` release

**This is the ship process the coordinator runs** for every core release. It turns the release
discipline in [`CONTRIBUTING.md`](../CONTRIBUTING.md) (§5 — the tag + changelog contract; §6 — the
mechanics) into a concrete, ordered checklist. Every box, every release — a skipped box is a defect,
not a shortcut. The `core-v*` tag is what an adopter's `kickoff pull` trusts, so the tag certifies
that all of this actually ran.

## 1 · Stage the release

- [ ] **Curated subset** — assemble the release delta from the reviewed, travelling file set
      ([`scripts/core-manifest.txt`](../scripts/core-manifest.txt) is the contract of what ships).
      The release commit must be a clean child of the previous `core-v*` tag.
- [ ] **Stability contract** — update `scripts/core-manifest.txt` (file set) and/or
      `scripts/instance.env.example` (config variable *names*) only if they actually moved; any break
      is announced in the changelog.
- [ ] **Plugin version invariant (LOCKED decision #1)** — if ANY `plugin/` file changed vs the previous
      tag, `plugin/.claude-plugin/plugin.json`'s `version` string MUST bump. The pull re-syncs the shared
      interactive plugin cache by version bump (`claude plugin update` is a NO-OP on an unchanged version,
      and the reinstall fallback is gated off when a sibling shares the cache), so a same-version content
      change lands as a preflight-#8 drift that fail-closes every adopter's pull. Verify against the prev tag:
      `git diff --quiet <prev-tag> HEAD -- plugin ':(exclude)plugin/.claude-plugin/plugin.json' || git diff <prev-tag> HEAD -- plugin/.claude-plugin/plugin.json | grep -q '^[+-].*"version"'`
      (fails iff plugin content moved without a version-line change). Missed in core-v0.8 → fixed in v0.8.1.

## 2 · Gate it

- [ ] **Leak-scan the exact release tree** — no secrets, no machine paths, no per-instance or operator
      data. A hit is a **hard stop**: fix at source, re-stage, re-scan.
- [ ] **Suites green on the exact release tree** — run the self-test suites against the staged tree
      (not the dev tree) and record the real pass/fail counts. Green claimed without a run is a defect.
- [ ] **Adversarial gate** — a separate agent, briefed to *break* the release (read + run only); every
      finding verified against the code; confirmed findings fixed at source, re-staged, and re-verified
      firsthand.

## 3 · Ship it

- [ ] **`CORE-CHANGELOG.md` entry** — what changed, in adopter-facing terms (this is what a sibling
      reads before pulling).
- [ ] **PR** on the public repo; merge once every gate above is green.
- [ ] **Verify the merged tree matches the gated tree**, then **tag `core-vX.Y` on the merged tip and
      push the tag**. (Signed tags are the queued upgrade here — not yet in force.)

## 4 · Release-channel integrity (the installer)

- [ ] **Publish the GitHub Release page** — SYSTEMATIC since core-v0.40 (operator directive,
      2026-08-24): the ship turnkey's `--push` does it as step 4/4, with notes ASSEMBLED from the
      tagged tree's own `CORE-CHANGELOG` section plus the derivable upgrade/install lines. If `gh`
      is unavailable where the turnkey runs, it writes the assembled notes to disk and prints the
      exact manual command — finishing by hand is the fallback, skipping is not.
- [ ] **Publish the installer's SHA-256 in the release notes** — `sha256sum install.sh` computed on the
      tagged tree. This backs the long-form download → read → verify → run path documented next to the
      one-liner.
- [ ] **Publish the tag→commit mapping in the release notes** — `core-vX.Y @ <full commit SHA>` — so
      the pin the installer prints is auditable after the fact.
- [ ] **Verify the canonical install URL points at the new tag.** The one-liner in `README.md` and
      `QUICKSTART.md` must fetch the **release-tag raw path**
      (`https://raw.githubusercontent.com/vinceferro/kickoff/core-vX.Y/install.sh`), with the
      long-form read-then-run block beside it; the moving-`main` path appears only as the
      explicitly-labeled "latest" alias. Then fetch the canonical URL and diff it against the tagged
      `install.sh` — they must be byte-identical.

## 5 · After the tag

- [ ] Adopters inherit by `kickoff pull` (see [`UPGRADING.md`](../UPGRADING.md)); their preflight
      verifies the pin on the next start. Nothing else to do — the installer never upgrades anyone.
