---
name: release-notes
description: Release notes / upgrade pitch — write the outsider-facing "what do I get by upgrading" for a release or major change. Use when cutting a release, turning a changelog into notes, or asked "what changed / why should I upgrade". Turns real, shipped changes into a few direct engine-tagged value lines.
---

# release-notes — changelog-to-pitch in the house voice

Crystallized 2026-08-28 from the operator's direct coaching: outsiders want few words,
outcomes not implementation, and to know **which engine** each fix is for — most adopters
run one environment only.

## When to use
- Cutting a release, writing the "what's new" for a tag, or preparing the upgrade pitch.
- Asked "what did we ship / why upgrade / what changed" by anyone outside the build team.
- Skip it for internal checkpoints and maintainer-only changelog entries — those stay in
  the changelog.

## The motion
1. **Ground in artifacts, not memory**: Read the actual changelog section + the release
   diff (`git log`/`git diff` for the tag). Only items that verifiably SHIPPED make the
   notes — never intent, never "should land", never in-flight work.
2. **Translate to adopter outcome**: each bullet is "X now means Y" — what changes for the
   person upgrading. Implementation detail ("refactored the executor", file names) stays
   behind.
3. **Tag the engine**: group as *Both engines* / *Claude Code* / *opencode*. Most adopters
   run ONE engine — they read only their group. An item that exists on one engine only gets
   a short parenthetical saying why (e.g. "the other engine already had this").
4. **Cut**: maintainer-only items, internal codenames, incident IDs, jargon, hedges. A
   bullet that needs a second line is two bullets or it's cut.
5. **Close with one honest theme line** — a single sentence a stranger could repeat.
6. **Verify before shipping the notes**: every bullet maps to a real diff/changelog entry;
   engine tags match the paths each item actually touches; if `scripts/claims-audit.py`
   exists, run it on the draft — release notes obey the same evidence rule as any report.

Shape (generic):

> **Upgrading to <version>:**
>
> *Both engines*
> - "<claim> now means <verified outcome>"
>
> *<one engine> only*
> - <outcome> *(the other engine already had this / this engine lacked <X>)*
>
> One line: **<theme> — by construction, not by promise.**

## Pitfalls
- Writing from memory of intent — a note about an unfinished thing is a confident lie in
  marketing clothes (the phantom-"pushed" class).
- Assuming both engines benefit — engine-parity gaps are exactly what the tags expose.
- Internal names leaking — project codenames, agent names, box names mean nothing outside.
- Length — the audience decides in ~15 seconds; the changelog carries the detail.

## Verification checklist
- [ ] Every bullet maps to a real shipped change (verified against diff/changelog this session)
- [ ] Engine tags verified against the paths each item touches
- [ ] Claims lint: `python3 "$KICKOFF_CORE_DIR/scripts/claims-audit.py" <draft>` — origin repos
      run it as `python3 scripts/claims-audit.py <draft>`; flags mean rewrite
- [ ] Read aloud once: would a busy one-engine outsider get it in 15 seconds?
