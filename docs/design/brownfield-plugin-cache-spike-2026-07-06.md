# Plugin-cache spike (b) — verdict

**Date:** 2026-07-06 · **CC version:** 2.1.201 (design assumed 2.1.199 — minor bump, no behavior delta observed) · **Gate:** §7 step 1(b), Fix 3. Run BEFORE §5 (the plugin) build. Fully isolated via `CLAUDE_CONFIG_DIR=<scratch>` — the live `~/.claude/plugins/` (which the running worker + Telegram channel depend on) was verified pristine after: `known_marketplaces` = only `claude-plugins-official`, `installed_plugins` = the 9, zero `kickoff-local` references.

## The question
Does a **local-path** marketplace snapshot the plugin into the user-global cache (`~/.claude/plugins/cache/…`), or run it in-place from source (the pulled clone)? The answer drives the pull plugin-update step, preflight #8's hash target, and the machine-level manifest/eject entries.

## Verdict: **CACHE SNAPSHOT** (build the design's cache path)

| Observation | Evidence |
|---|---|
| Install snapshots into cache, **not** source | `installed_plugins.json` `installPath` = `<config>/plugins/cache/kickoff-local/kickoff-spike-plugin/0.1.0` (a cache path, not the source marketplace dir) |
| The snapshot is a **real copy**, not a symlink | cache `probe.sh` is a regular file, byte-identical to source at install time |
| **Drift is real** | edited source marker v1→v2; cache stayed at v1 (stale snapshot) |
| Marketplace registry reads from source | `known_marketplaces.json` records `source: {source: "directory", path: <src>}`; `installLocation` = the source dir (the marketplace itself is NOT copied — only the plugin is) |

## Sharp finding the design missed (folds into the build)
**`claude plugin update` is a NO-OP unless the plugin's `version` string bumps.** With source content edited but version unchanged (0.1.0), `plugin update` reported "already at the latest version" and left the cache stale. The design's mechanism (1) ("pull gains a plugin-update step that re-syncs the cache") is therefore **insufficient on its own** — it silently no-ops on a same-version content change.

### Two validated re-sync mechanisms
- **A — version bump (preferred):** bump plugin.json `version` → `claude plugin marketplace update <mkt>` (re-read the directory manifest) → `claude plugin update <plugin>@<mkt>`. Re-syncs to a **new version dir** with fresh content; prints "Restart to apply changes" (matches pull→refresh). ⚠ the **old version dir is left behind** in cache → eject/cleanup must sweep ALL version dirs; preflight #8 hashes the *pinned* version's dir.
- **B — force reinstall (fallback, version-agnostic):** `claude plugin uninstall` + `claude plugin install` picks up fresh content even at the **same** version string.

**Build rule:** `kickoff pull core-vNEXT` sets the plugin's `version` to track the core tag (guarantees a bump whenever the tag moves) → mechanism A always re-syncs deterministically. Mechanism B is the belt-and-braces fallback for a version collision.

## Eject boundary (from the project-scope probe)
`claude plugin marketplace add --scope project` + `install --scope project` (run from inside the repo) writes ONLY to the repo's `.claude/settings.json`:
```json
{
  "extraKnownMarketplaces": { "<mkt>": { "source": { "source": "directory", "path": "<clone>/plugin-marketplace" } } },
  "enabledPlugins": { "<plugin>@<mkt>": true }
}
```
- **Repo-level (eject reverses in THIS repo, manifest-recorded):** the two `.claude/settings.json` keys `extraKnownMarketplaces.<mkt>` + `enabledPlugins.<plugin>@<mkt>`.
- **Machine-level / user-global (eject reverses only on LAST sibling, gated on `~/.kickoff/adopters.json`):** the cache snapshot `~/.claude/plugins/cache/<mkt>/<plugin>/<version…>/` (all version dirs) + any user-scope `installed_plugins.json` / `known_marketplaces.json` entries.

## What §5 must build (confirmed by the spike)
1. **Package** the engine layer as a plugin at `~/kickoff-core/plugin/` (marketplace manifest + plugin.json + the memory hook via `${CLAUDE_PLUGIN_ROOT}` + skills), plugin `version` tracking the core tag.
2. **Adopt** registers the marketplace + enables the plugin at **project scope** (writes the two repo settings keys); records both a repo-level manifest entry (the settings keys) and a machine-level manifest entry (the cache + user-global touch).
3. **Pull** re-syncs the cache deterministically: bump plugin version to the tag → `marketplace update` → `plugin update` (mechanism A), with reinstall (B) as fallback.
4. **Preflight #8** additionally hashes the **cache** copy of the pinned version against the pinned tag (not only the clone) — the clone-only hash is blind to cache drift.
5. **Eject** removes the repo settings keys always; removes the user-global cache + registry entries on last-sibling (adopters.json-gated).
6. **Headless path** (`session-run.sh --plugin-dir "$KICKOFF_CORE_DIR/plugin"`) execs source directly — no cache, no drift — so it's unaffected; the cache mechanism is the **interactive** path only.
7. Retire adopt SKILL.md step 5's dead "copies skills into `.claude/skills/`" promise (plugin delivers skills now).
