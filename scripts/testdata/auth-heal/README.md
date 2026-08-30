# auth-heal test fixtures — frozen pre-wiring lifecycle scripts

`supervisor.sh` and `session-run.sh` here are **byte-identical frozen copies of the
pre-auth-heal versions** (the blobs at the commit before the self-heal wiring landed in the
core). They are the fixture `scripts/auth-heal-selftest.sh` seeds T23/T24 from.

## Why frozen copies, not the live scripts

`install-auth-heal.sh` **retrofits** the auth-heal wiring onto a supervisor.sh / session-run.sh
that predate it. Once the wiring ships in the core, the *live* scripts are already wired — so
seeding the installer test from them makes every anchored edit read *"already applied"* and the
apply / backup / drift-refusal paths (the whole point of that test) never run. A frozen
pre-wiring file is the correct, hermetic retrofit target and keeps the test green regardless of
whether the running instance has adopted + armed the feature.

## These are intentionally static

They represent a historical retrofit target and should **not** be "refreshed" to track later
supervisor.sh changes. If the installer's anchors are ever edited to target a line that isn't
in these files, that's a real signal (the anchors no longer match a real pre-wiring file), not a
reason to regenerate the fixtures.
