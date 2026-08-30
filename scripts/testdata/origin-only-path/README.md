# RED-control fixtures for `scripts/origin-only-path-selftest.sh`

Two byte-copies of `plugin/skills/mission-control/SKILL.md` as it stood *before* each of the two
documentation instances of the origin-only-path bug was fixed. The suite scans them and requires the
gate to flag them; if it stops flagging either, the gate has stopped catching a bug we actually shipped.

| fixture | what it is | the bug it pins |
|---|---|---|
| `mc-skill.pre-e53096c.md` | the SKILL before the board-write fix | taught `python3 mission-control/mc-update.py` ×10 and never named `.kickoff/bin/mc` → on an adopter the board stayed EMPTY, with no error |
| `mc-skill.pre-02d5db9.md` | the SKILL before the secrets last-mile fix | taught `node scripts/secret-decrypt.mjs mission-control/secrets-inbox/…` → wrong script path on an adopter, AND a bare inbox path that resolves into the SHARED core clone (a cross-project secret leak) |

## Why these are committed files and not `git show <sha>:`

Both pre-fix texts exist only in this repo's *development* history. A published release is a single
squashed commit, so those SHAs are unreachable from the public tag — a SHA-anchored fixture would make
this suite go RED for everyone who clones the public repo. A gate against origin-only assumptions that
only works in the origin is the exact bug it exists to catch.

The suite's third RED control is deliberately still git-anchored (`core-v0.16:scripts/kickoff`): a
published tag is present in every clone.

These files are inert test data. Do not "fix" the origin-only paths inside them — the findings are the
point. `scripts/scan-*.sh` and the release leak scan treat them as ordinary tracked files, so keep them
free of box-specific paths and real credentials (they contain neither).
