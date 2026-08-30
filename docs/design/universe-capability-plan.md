# Design — the Universe as a reusable, opt-in Mission Control capability (core-v0.4)

Design-first plan (planner-scoped 2026-07-08, coordinator-relayed to the operator). Goal: turn kickoff's
bespoke 3D "universe" showcase into a **reusable, opt-in, personalizable** capability shipped in the
core, rendering **any adopter's** `mission-state.json`. See memory `universe-as-reusable-mc-capability`.

## Headline finding (de-risks the whole effort)
The current experiment decks are **already data-driven** off `/state` + SSE, reading the **standard**
`mission-state.json` schema. Genericization is therefore **surface-level** (identity strings + theme
extraction + a neutral demo seed), **NOT** a data-pipeline rewrite. **Zero schema additions needed.**

## Recommended base deck
`mission-control/experiments/3d-deck.jarvis.intro.html` (~8,100 lines, newest, untracked). A strict
superset: galaxy organic-aesthetic pass (nebula texture, soft additive-point shaders, quantum-tunnel
links) + Jarvis luminous command layer + the guided genesis→tunnel→galaxy narrative intro. Already
`fetch('/state')` + `EventSource('/events')` + `applyState()`; renders core label from `state.project`;
graceful DEMO-seed fallback when `/state` is unreachable. Leaner fallback: `3d-deck.jarvis.html` (minus the intro).

## Data mapping (existing fields → universe entities)
- Core/company ← `state.project`
- Galaxies (constellations) ← `done[].theme` → fallback `done[].owner` (the server's own `/ship` grouping)
- Shipped stars ← `done[]`; time ← `shippedAt` → `shipOrder` → index; edges ← `connections`/`deps`
- Forging work ← `in_progress[]` (+ `theme` → target constellation)
- Agents orbiting / drill target ← `functions[]`
- Continuum / genesis bursts ← `activity[]`

## Genericization (surface work only)
1. Fork base → `mission-control/universe.html`; keep the `/state`+SSE pipeline untouched.
2. Parameterize the signature/tagline (→ theme config). Default empty or `state.project`.
3. Neutralize the demo seed → load `mission-control/mission-state.sample.json` (already exists) as the fallback.
4. Genericize `// the operator:` comments + identity strings (`0xTheV`, `BLIZ`, `Claude Kickoff`) so scanners stay clean.

## Integration
- **Serve:** add `/universe` route to `mission-control/server.py` (mirror the `/3d` handler ~line 527); reuse the token wiring dashboard.html already carries.
- **Manifest + pre-existing gap:** today `core-manifest.txt` pins only `mc-update.py`; `server.py`/`dashboard.html`/`secrets.html` travel via the full `kickoff pull` checkout but are NOT drift-pinned. **Decision: pin the whole served MC surface** (server.py, dashboard.html, secrets.html, universe.html) together — otherwise we pin the deck but not the server that routes it.
- **NOT self-contained today:** both jarvis decks load Three.js (`three@0.160.0` + OrbitControls/EffectComposer/RenderPass/UnrealBloomPass) from **unpkg via importmap**. **Decision: vendor Three.js locally** (`mission-control/vendor/three/`, importmap rewritten local, static-serve with MIME + realpath traversal guard, verified offline) — a shipped capability must not depend on a CDN.

## Opt-in (default OFF)
- Add `KICKOFF_UNIVERSE` to `scripts/instance.env.example`, default unset/`0`.
- `server.py`: when OFF, `GET /universe` → 404. Add `GET /config` → `{"universe": bool}` so `dashboard.html` conditionally renders the `🌌 universe` link (today unconditional — must be gated for default-OFF to be real).
- Flip flag + `kickoff up` (or supervisor's ~15s env re-read) turns it on; no adopter code edit.

## Personalization / theming
- Template→seam pattern: `scripts/templates/universe.theme.json` (default organic theme, core-manifest-pinned) → seeded to `.kickoff/universe.theme.json` at adopt (per-instance, editable, NOT drift-pinned).
- Deck fetches `GET /universe-theme` → applies palette to CSS vars (`--teal`/`--orange`/`--bg1`/`--bg2`) + JS color/knob constants.
- **Adopter-tunable:** accent + bg-depth palette, galaxy/star/nebula/core hues, bounded form knobs (particle density, bloom, sizes, tunnel intensity), signature/tagline, and the genesis label ("Telegram" default → themeable string).
- **Fixed (protect the aesthetic):** the organic primitives — soft additive round-point stars, offset-blob nebula, halos-not-rings, curved tunnels. Retint + rescale, but cannot become hard discs/rings. **[FORK — the operator: palette+bounded-knobs (lean) vs full reshape.]**

## Build slices (smallest-first, each green)
- **S1 — Genericize + serve (keystone):** fork → `universe.html`, strip identity, add `/universe`. Proof: renders the sample/DEMO fallback, 0 console errors, grep finds no kickoff-dev identity outside config.
- **S2 — Data-driven proof (THE success criterion):** run `server.py` with a supplied state file (exact-PID, unique port — NEVER pattern-kill `server.py`, it'd drop the live :9200 board). Automated headless assert: core label == `project`, galaxy count == distinct `done[].theme`, star count == `done.length`, 0 console errors. Re-run vs beauty circle's real state.
- **S3 — Opt-in + default OFF:** `KICKOFF_UNIVERSE` gate + `/config` + conditional link. Proof: off → 404 + hidden; on → 200 + shown.
- **S4 — Theming:** extract config, ship organic default, seed per-instance, deck applies. Proof: default + an override → assert applied color reflects override. Render on GPU light+dark + look; then the operator's iPhone (honest caveat).
- **S5 — Manifest + pull (+ vendoring):** pin in `core-manifest.txt`; vendor Three.js; verify offline; fresh `kickoff pull` delivers it; `core.lock` pins it; preflight #6 green.

**Success criterion (runnable check):** `scripts/universe-selftest.mjs` starts `server.py` against a supplied `mission-state.json`, loads `/universe`, asserts the render reflects THAT state (core=project, one galaxy per distinct done-theme, stars=done length), zero console errors, zero kickoff-dev identity strings served.

## Risks
- **Render-is-not-the-device:** headless GPU-ANGLE ≠ Safari/iPhone; bloom/feel gate on the operator's real phone; WebKit untestable here — say "rendered, confirm on your phone."
- **WebGL perf on a low-end phone:** heavy; mitigate via the particle-budget knob; it's a showcase (demanding-but-optional acceptable).
- **CDN/CSP:** unpkg at runtime → offline/CSP/supply-chain; vendoring removes it.
- **Manifest coherence:** pinning the deck but not its server is a half-measure → close the gap.
- **Single-file size (~8.1k lines):** structure-scan advisory LOW; accept as the single-file constraint.
- **Don't clobber live state:** theme config stays OUT of `mission-state.json`.

## Forks
1. **Narrative intro** — DECIDED: keep on `jarvis.intro`, default-skippable.
2. **Personalization depth** — **THE OPERATOR'S CALL:** palette + bounded knobs, organic forms fixed (lean) vs full reshape.
3. **Self-contained vs CDN** — DECIDED: vendor Three.js locally.
4. **Opt-in default + manifest scope** — DECIDED: default OFF, `KICKOFF_UNIVERSE`, `/universe`; close the manifest gap (pin the whole MC surface).
- Genesis label themeable — DECIDED: yes (default "Telegram").

## UPDATE 2026-07-08 (post-relay) — decisions confirmed + scope expanded

**the operator confirmed (msg 1374):** personalization = **palette + bounded knobs, organic forms FIXED**
(Fork 2 resolved — my lean). **Build with Fable-5** (he authorized "fable intelligence" for this).

**NEW v0.4 scope — semantic-memory pull-durability (a real core gap, surfaced by Claudio on
beauty circle).** Claudio installed a local embedding model (`all-MiniLM-L6-v2`, 384-dim, offline
CPU, cost-zero) to upgrade the memory retrieval's vector arm beyond the core's lexical `hashing-stub`
— real embeddings now, paraphrase queries hit #1. He worked around a `sharp` compile issue by
dropping the prebuilt binary straight into `node_modules` (pnpm blocks build scripts; core config
is versioned/untouchable). **The gap:** the model lives in `node_modules`, so a `kickoff pull` to a
new core loses it → semantic **silently** drops back to keyword-only. Every adopter would degrade on
upgrade. **v0.4 must make the semantic model pull-durable** — options to weigh at build time:
(a) a post-pull step that detects semantic-enabled + model-missing and reinstalls it; (b) the model
lives in a durable location OUTSIDE the core clone (e.g. `~/.cache/kickoff-models/` or the instance's
`.kickoff/state/`) that pulls never touch, resolved by the hook; (c) bundle/fetch-on-first-use.
Likely (b)+(a). Ties to the Fix-C completeness thread in [[kickoff-v0.3-core-gaps-first-adopter]].

**Coordination (RESOLVED, msg 1376):** the operator confirmed — Claudio's aware; their feedback packs into
a new release for beauty circle to pull. So: **I build the ONE reusable capability into the core;
beauty circle adopts it.** the operator went offline (overnight full-autonomy cook); Bliz onboarding tomorrow AM.

## Claudio's feedback (msg 1376) — distilled
- **[FOLD IN] #1 HUD title overflow on narrow phones.** On a 390px viewport a longer `project` name
  ("Beauty Circle") collides with the top-right icon row ("BLIZ" was short + didn't). A REAL reusable
  mobile fix (any adopter's name length varies): truncate/scale the HUD title or wrap the icon row
  below a width breakpoint. Mobile-first — bake it into the genericization (S1).
- **[FOLD IN] #3 Headless shader warning.** On software GPU (SwiftShader) `UnrealBloomPass` logs
  `THREE.WebGLProgram VALIDATE_STATUS false` (bloom still renders) — noise in the headless verify.
  Silence/filter it so the `universe-selftest` proof is clean (S2/verify).
- **[DOC CAVEAT, not core code] #2 SPA path capture.** Serving the deck under a path shared with an
  SPA, its `try_files … /index.html` fallback captures `/universe/` and serves the app. The CORE
  serves the universe from its own MC `server.py` `/universe` route (own port), sidestepping this —
  so it's a serving caveat to DOCUMENT for adopters who serve the static deck behind their own SPA
  (use an explicit file / own prefix), not a core code change.
- **[DOC CAVEAT, not core code] #4 Build-folder durability.** If the static deck lives in a build
  output (Expo `dist/` with `--clear`), a rebuild deletes it. The CORE serves it from the pinned
  core (stable), sidestepping this — document: don't home the served deck in a cleared build dir.
- **[OUT OF SCOPE] Aside:** the app's web tab says "Care Circle" not "Beauty Circle" — a beauty circle
  APP bug (not kickoff, not the universe). Flagged back to their side; not folded here.

## OVERNIGHT OUTCOME — 2026-07-09 (what LANDED, what REMAINS)

Cooked via the Fable workflow wf_ade2f8d1-c5d (2 build+adversarial-review stages), coordinator-verified,
leak-scrubbed, committed on brownfield-devex. **Both slices reviewed GREEN + independently re-verified.**

**LANDED (committed):**
- **Semantic-model pull-durability** (`2e66789`) — COMPLETE + shippable. Durable per-machine model cache
  (`~/.cache/kickoff-models`), `install-model.mjs`, `kickoff pull --if-needed` advisory, VISIBLE degrade
  + dims-guard + no-stub-poison. Reviewed 4/4; `model-durability-selftest.sh` 37/37; v0.3 keyword adopter
  untouched. Manifest pins `install-model.mjs`. (Side effect: kickoff-dev itself now runs REAL semantic
  from the durable cache — validated live; the shipped DEFAULT stays lexical-offline.)
- **Universe keystone** (`a6a499f`) — FOUNDATION, not yet adopter-shippable. `mission-control/universe.html`
  renders ANY adopter's mission-state.json; `/universe` route; HUD auto-fit; software-GL warning silenced.
  Reviewed 5/5 (data-driven proven on unseen states); `universe-selftest.mjs` 15/15 (real GPU + SwiftShader).
  Identity scrubbed (adopter name + a person's name removed from shipped comments).

**REMAINS to make v0.4 adopter-shippable (the finish-line, ~1-2 slices):**
- S3 — opt-in gate (`KICKOFF_UNIVERSE` default-OFF) + `/config` route + conditional dashboard link.
- S4 — theming/personalization (palette + bounded knobs, organic default) — the operator's confirmed depth.
- S5 — pin `universe.html` (+ the whole MC served surface) in `core-manifest.txt`; **vendor Three.js**
  (currently unpkg-CDN → offline adopters get a dead deck).
- Review follow-ups (LOW): 320px HUD floor edge; capture `warn` in `universe-selftest`; corrupt-model
  size/magic-bytes floor; 4f install timeout; the separate three `console.warn` shader path (needs Claudio's env).
- Changelog: the v0.4 entry currently covers only the semantic fix; add the universe when it's shippable.

## SHIP STATUS 2026-07-09 — v0.4 SHIP-READY; one gated tap left (the operator's push)

**v0.4 is built, reviewed (S3/S4/S5 each GREEN + a hostile-theme + traversal + offline pass), and
COMMITTED on brownfield-devex** (`d0dd155` completion + `a6a499f` keystone + `2e66789` semantic;
`82bbf9a` /3d retirement). Independently re-verified: universe-selftest 53/53, machinery 26/0, leak-clean,
live board + worker untouched.

**BLOCKER RESOLVED — /3d retired (`82bbf9a`).** The old `/3d` route served the private
`mission-control/experiments/3d-deck.html` (not shipped → 500 for adopters, a pre-existing v0.3 papercut);
v0.4's `/universe` replaces it. Removed the route + `THREED_HTML_PATH` (server.py), the "3D mode" link + its
JS (dashboard.html), and repointed the selftest assertion to VERIFY the retirement (`GET /3d → 404`, count
stays 53). Also tidied the software-GL fallback: SwiftShader's deterministic teardown `CONTEXT_LOST_WEBGL`
is now classified as GL-backend noise ONLY under `soft` (real-GPU loss still fails), counted + reported →
**universe-selftest 53/53 on BOTH angle-egl (RTX 3080 Ti) AND soft (software-GL).**

**Public ship RE-STAGED + verified:** release commit **`bb98790`, tag `core-v0.4`, parent `83cb648`
(= origin/main = core-v0.3.1 → clean fast-forward)**. Built by materializing the exact 31-file leak-scanned
subset from the retirement-inclusive HEAD (`82bbf9a`) onto a fresh worktree at `83cb648`. **Integrity proven:**
`bb98790`'s tree vs the previously-vetted `a81e162` differs in ONLY the 3 retirement files — nothing else
slipped in. Leak-scan re-run (variant-aware: machine-home hyphen/dot form · scratchpad-session path · identity) CLEAN; residual `Bliz`
strings are pre-vetted public-safe attribution/detector/comments. Ship gate GREEN on the SHIPPED worktree
tree: universe-selftest 53/53 both backends, `/3d → 404`. (Prior leak-narrowing that produced the 31-file
set — excluding `docs/adopt-skill/BLIZ-*`, machine paths, identity strings, and kickoff-dev's real
`mission-state.sample.json` → embedded neutral DEMO fallback — still holds.)

**Turnkey ready + dry-run GREEN:** `~/ship-kickoff-v0.4.sh` (fail-closed, idempotent, ff-only, `DRY_RUN`
guard). The `DRY_RUN=1` run passed all preconditions and would ff `83cb648 → bb98790` + push the tag;
`git push --dry-run` confirms a clean fast-forward with the tag absent on origin. **ONE gated tap left
(the operator):** `bash ~/ship-kickoff-v0.4.sh`.

**Then the locked sequence:** beauty circle `kickoff pull core-v0.4` (the UPGRADE-path proof) → Bliz adoption.
origin/main = `83cb648`; v0.4 parent = `83cb648`; push is a clean fast-forward.
