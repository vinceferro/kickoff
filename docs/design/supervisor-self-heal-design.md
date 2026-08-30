# Supervisor token-expiry self-heal — design (2026-07-07)

Queue item 3 (robustness). The operator asked the supervisor to self-heal a CC auth-token expiry after it went dark
~2h on 2026-07-07 ([[cc-token-expiry-kills-headless-worker]]). Design by an Opus planner, grounded file:line.
Full text: the task output for run `a3826a2c7f851ae47` (this session). BUILD is live-safety-critical — its own
fail-safe testing + adversarial review; the `supervisor.sh`/`settings.json` edits are gated self-mod → likely
STAGED as a turnkey for the operator.

## Pinned root cause of the ~2h dark gap
The supervisor watches **process** liveness, not **functional** liveness. `session_alive` = only
`kill -0 "$SESSION_PGID"` (`supervisor.sh:177-181, 241`). And `SESSION_PGID` is the **`script(1)` pty leader**,
not `claude` — the exec chain `setsid bash → exec bash session-run.sh → exec script` (`session-run.sh:193`)
makes `claude` a **child** of `script` (`session-run.sh:262-267`). On token-expiry an interactive (pty) `claude`
**HANGS** at a re-login prompt waiting for TTY input that never comes (stdin = `tail -f /dev/null`) → `script`
stays alive → `session_alive`=TRUE → **no restart trigger fires → silent forever** (Case B, matches the
observed silence). Case A (claude *exits* on expiry) would instead **restart-loop into the same expiry** — a
ping-storm, not silence — so B is the fit. The three restart triggers today: the `.kickoff/refresh-requested`
flag, the `MAX_SESSION_SECONDS` cadence (off by default), and `script`-leader death — none detect a hang.

## Architecture (minimal, additive, fail-toward-inaction)
- **NEW `scripts/auth-heal.sh`** — all logic; sourced like `rotate-log.sh` (`supervisor.sh:82-87`); **absent → a
  no-op stub** (identical to today). Acts ONLY via: touch `$REFRESH_FLAG`, the tokenless alert curl, write/clear
  `.kickoff/auth-escalated`. Never a new kill path.
- **`scripts/supervisor.sh` — exactly 2 additive guarded edits:** (1) `auth_heal_step || true` after `rotate_log`
  (`:230`) — a probe error can never abort the loop; (2) gate Trigger-3 restart with
  `&& [ ! -f "$KICKOFF_DIR/auth-escalated" ]` (`:241`) — prevents the doomed restart-loop while escalated;
  helper-absent → flag never created → byte-identical to today.
- **NEW `scripts/relogin.sh`** — the one-tap turnkey (idempotent, prints next action); on success clears the
  escalate flag → supervisor auto-resumes + announces.
- **`scripts/session-run.sh`** — meaningful announce copy (`:172`, lead-with-the-work per
  [[operator-reconnect-message-meaningful]]); optional bounded-typescript capture (`:193`) only if D1 is chosen.
- **`scripts/instance.env.example`** — `KICKOFF_AUTH_CHECK_CMD` / `KICKOFF_AUTH_REFRESH_CMD` /
  `KICKOFF_AUTH_EXPIRY_PATTERN` (all default empty/inert) + a `CADENCE`-stopgap note.
- **`.claude/settings.json`** — a worker-scoped `SessionStart` `initialUserMessage` hook (hands-free meaningful
  announce; gate on a worker-only env var so dev sessions don't inherit it). Gated self-mod.

## Detectors (layered; each degrades safely to the next)
- **D2 (day-one, ZERO CC-internals):** exit-loop escalation — session dies within `T`s of spawn, `N`× in a row →
  escalate (stop restarting; a restart can't mint a credential). Fixes the Case-A loop + "left dark" with no CC
  knowledge.
- **D3 (preferred; catches the HANG):** a read-only `KICKOFF_AUTH_CHECK_CMD` run before each spawn + periodically;
  "expired" → escalate without spawning a doomed session. Secret-free, pre-empts the hang. Needs Q5 #2.
- **D1 (fallback for the hang, no CC cooperation):** scan a bounded/600/gitignored typescript tail for a
  tightly-anchored `KICKOFF_AUTH_EXPIRY_PATTERN` (empty→inert). NOT mtime-staleness (a healthy idle session is
  also static). Carries a TTY-secret-exposure surface → scan-and-truncate + flag for adversarial review. Needs Q5 #5.

## Recover → guarantee the ping
Detector "expired" → try non-interactive refresh if one exists (`KICKOFF_AUTH_REFRESH_CMD`, Q5 #3; success →
touch refresh flag → clean restart+announce = **fully autonomous**) → else escalate: write `.kickoff/auth-escalated`,
send a **tokenless** Telegram alert via the sanctioned in-script recipe (`session-run.sh:168-177`, bot token read
off-argv — NOT the agent-extracts-token path the guard blocks), then **wait-and-auto-resume** (re-check auth,
resume the moment it's valid). Silence bounded to alert latency (seconds). Announce guaranteed two ways: the
meaningful spawn-heartbeat (CC-independent) + the SessionStart hook.

## Fail-safe rules (this runs the LIVE worker)
Fail **toward inaction** (any doubt → HEALTHY/no-op — the inverse of preflight's fail-closed; a false positive
kills a GOOD session) · hard rate-limit + anti-boot-loop (≤1 action/cooldown; after `K` failed recoveries →
alert-and-wait) · no new kill surface (restart via the existing PGID-safe `refresh`) · inert-by-default detectors.

## Testing (WITHOUT risking the live worker)
`auth-heal-selftest.sh` (synthetic typescripts + stubbed auth-check → assert verdict + side-effect; pure fn, no
claude) · `DRY_RUN=1` loop (inject "expired" → asserts intent, kills nothing) · **fail-safe regression** (delete/
corrupt the helper → supervisor runs identically to today, no boot-loop) · anti-boot-loop · alert-path on a
throwaway bot · adversarial review (brief a breaker: boot-loop? false-kill idle? typescript secret leak? wedged
wait-state? alert storm?).

## Day-one slice (green, zero CC-internals) — HONEST CAVEAT
`auth-heal.sh` **D2 + tokenless meaningful alert + relogin.sh + the 2 guarded supervisor edits**, proven by the
selftest + DRY_RUN + fail-safe-regression. Removes the restart-loop-into-expiry + the left-dark consequence.
**But the LIKELY real incident was the HANG (Case B), which D2 does NOT catch** — the hang-catcher (D3) needs the
CC-internals answers. Don't let the green D2 slice read as "hang solved."

## Q5 — CC-internals unknowns → claude-code-guide (dispatched) / operator
1. On expiry does headless/pty `claude` EXIT or HANG? exit code/stdout-stderr signature?
2. A NON-INTERACTIVE auth-status check (`claude auth status`/whoami) OR a credentials file (e.g.
   `~/.claude/.credentials.json`) with a readable `expires_at` the supervisor can `stat` without running claude?
3. A REFRESH TOKEN / non-interactive re-auth (`claude auth refresh`)? → is fully-autonomous recovery possible, or
   is it a hard-expiring key needing human re-login?
4. The exact headless RE-LOGIN command — and is re-login even completable on a no-browser box (browser-only OAuth
   there is itself a problem)?
5. The exact auth-expiry ERROR STRING(S) (the D1 pattern).
6. Does a `SessionStart` `initialUserMessage` hook inject a first turn for a `--channels` worker (hands-free)?

## CC-internals ANSWERS (claude-code-guide, CC 2.1.203, 2026-07-07) — these sharpen the build
1. **Exit vs HANG on expiry: UNKNOWN** (undocumented) → keep BOTH the process-death detector and a hang/no-output
   probe — BUT #2 makes this moot for detection.
2. **Non-interactive auth check: YES — `claude auth status --json`** (confirmed live: returns login-method/org/
   email JSON, no prompt). → **THIS is the clean D3 detector — lead with it** (beats D2's exit-loop heuristic AND
   catches the hang). The credentials file `~/.claude/.credentials.json` (0600, keys `claudeAiOauth`/`mcpOAuth`)
   is guard-protected → do NOT parse it; use `auth status --json`.
3. **Auto-refresh: NO for OAuth** (the operator's account is Claude Max / OAuth per the auth-status output). OAuth is
   HARD-EXPIRY, no refresh token. (`apiKeyHelper` auto-refreshes, but that's a different auth path.) → recovery
   CANNOT be autonomous re-auth.
4. **Headless re-login: NOT completable on a headless box** — all `claude auth login` variants need a browser →
   localhost redirect. The headless path is `CLAUDE_CODE_OAUTH_TOKEN=<token>`, generated ONCE via
   `claude setup-token` on a browser machine. → **recovery = a GATED turnkey: the operator runs `claude setup-token` on
   his phone/laptop → pastes the token into `relogin.sh` → the worker restarts with a fresh
   `CLAUDE_CODE_OAUTH_TOKEN`.** This is the ONLY headless recovery; the escalate-to-turnkey path is confirmed
   necessary. The worker should also RUN with a pre-generated `CLAUDE_CODE_OAUTH_TOKEN` (headless-stable) rather
   than a browser-login session — a setup step to confirm with the operator.
5. **Error strings: partial** — `403 forbidden`, "token expired" (pattern-match HTTP status, not prose — weak;
   prefer the #2 `auth status` probe).
6. **SessionStart `initialUserMessage`: `-p` mode ONLY, NOT interactive/pty.** Our `--channels` worker runs in a
   pty → the SessionStart hands-free announce likely WON'T fire. → rely on the **meaningful spawn-heartbeat**
   (CC-independent, `session-run.sh`) as the guaranteed announce; verify the SessionStart path before depending
   on it. (This CONFLICTS with [[headless-worker-channels-config]]'s SessionStart-announce claim → re-verify that
   memory when building.)

**REVISED day-one slice (now buildable with no blocking unknowns):** D3 (`claude auth status --json` probe in
`auth-heal.sh`, before each spawn + periodically) + escalate-to-turnkey (`relogin.sh` accepts a fresh
`CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`) + the tokenless meaningful alert + the meaningful
spawn-heartbeat announce + the 2 guarded supervisor edits. D2 (exit-loop escalation) stays as a cheap backup.

## Gated
The actual re-login credential (the `relogin.sh` one-tap + Telegram alert) · `PERMISSION_MODE=auto` arming stays
terminal-only ([[unattended-worker-needs-pregranted-permissions]]).
