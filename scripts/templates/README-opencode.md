# scripts/templates/opencode.json — the adopter's opencode config (JSON can't carry comments, so the note lives here)

No model pin: interactive sessions inherit the user's global config; headless workers get `OPENCODE_MODEL_PROVIDER`/`OPENCODE_MODEL_ID` from `.kickoff/instance.env`.
No provider stanza: origin's `opencode.json` pins the `opencode` provider — a provider that silently wedges boxes without its creds — and adopters must not inherit that.
