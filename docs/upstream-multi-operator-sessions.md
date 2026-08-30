# Multi-Operator Telegram Sessions — Design & Upstream Proposal

*Status: implemented and battle-tested on two production dual-operator orgs, 2026-08-24.*
*Target: grinev/opencode-telegram-bot (feature request + reference implementation).*

## Problem

The bot assumes exactly one human per machine: `TELEGRAM_ALLOWED_USER_ID` is a single
integer, auth is one equality check, and one global `currentSession` pointer serves the
whole process. Real deployments break this assumption the moment a second operator
joins an org — co-founder, partner, builder. Today they either get silently rejected
(`Unauthorized access attempt from user ID: …`) or, worse, share one conversation tape.

Naive multi-user (one shared tape) is the wrong goal anyway: two operators interleaving
in one session confuses both the model and the humans. The right primitive is:

> **N authorized operators × 1 bot token = N independent session tapes**, each with its
> own `/new`, its own context, its own notification stream.

## Solution (three moving parts, ~150 lines)

### 1. Allowlist (auth layer)
`TELEGRAM_ALLOWED_USER_IDS` (comma-separated) absorbs the legacy single var. Kickoff's
launcher derives it from the channel's `access.json` `allowFrom` — **one source of
truth**, no hand-synced env. Backward compatible by construction.

### 2. Per-user session scope (store layer)
An `AsyncLocalStorage` set in `authMiddleware` tags every update with its sender's id.
The settings store resolves sessions through it:

```
getCurrentSession():
  scoped (Telegram update)   → userSessions[userId]      (persisted map)
  unscoped (event pump/boot) → legacy currentSession      (unchanged)
```

All ~70 existing call sites become per-user **without modification** — this is the key
move. `/new`, model switches, aborts, renames isolate automatically.

**Backward-compat seed**: a *solo* operator (allowlist length 1) whose map entry is
missing adopts the legacy `currentSession` on first contact — upgrading never orphans
an existing conversation. With 2+ operators nobody inherits anything: clean start per
human, by design. Net effect for existing single-user deployments is **zero behavior
change**, ever.

### 3. Ownership-aware event routing (delivery layer)
Server events arrive outside any user scope. Every delivery guard resolves the target
chat via `chatIdForSession(sessionId)`:

```
userSessions binding exists?  → that operator's chat
else legacy pointer matches?  → primary chat
else                          → background/discard path
```

Applies to partial streams, completions, tool cards, file drops, thinking ticks,
heartbeat, permission prompts, question prompts, error notices, and background-session
notifications (which now correctly ping the *owning* operator).

## Pitfalls found live (the part docs never tell you)

Each of these produced a silent failure with no error surfaced to the operator:

1. **Silent-drop guard class**: completion handlers that compare against the session
   pointer and then *clear state and return* on mismatch look identical to "no event"
   from outside. If you ship multi-user scoping, sweep every
   `currentSession.id !== sessionId` comparison — optional-chaining variants
   (`currentSession?.id !== sessionId`) evade naive regexes.
2. **Two request routes**: interactive turns use `POST /session/{id}/prompt_async`
   (204, fire-and-forget), not `POST /session/{id}/message`. Debugging against the
   wrong endpoint "works" while production fails.
3. **Compact-mode branches duplicate guards**: with `compactOutputMode: true`, partials
   take an inner branch with its *own* session check. Fixing only the outer guard
   restores half the behavior.
4. **Background classification needs ownership awareness**: a session bound to any
   operator lane must never be classified as background, or replies demote to
   notification cards.
5. **DNS family sticks**: a serve that bootstraps onto a lossy IPv6 route keeps it in
   its keep-alive pool for life; long agentic streams die mid-flight while short chats
   seem fine. Prefer `--dns-result-order=ipv4first` where v6 quality is unknown.
   (Not multi-user's fault, but it masqueraded as it for hours.)
6. **Orphaned refs after guard surgery**: removing a declaration while converting comparisons left crashes inside permission/question callbacks — agents froze awaiting permissions that could never render. Sweep every reference to every removed symbol.
7. **Session-keyed helpers need the same treatment**: flush/batch/attribution calls keyed by session id must use the event's own session, not the resolved pointer — otherwise secondary lanes' status lands on the wrong card or vanishes.

## v1 deliberate limitations

- Model / agent / project selection remain global (last setter wins) — splitting these
  triples the surface for marginal value.
- Scheduled tasks and startup heartbeats notify the primary user.
- Subagent permission requests inherit the parent lane's chat when the child session
  is known; orphan subagents fall back to primary.
- One pinned status message per chat (Telegram constraint, matches one-lane-per-chat).

## Live evidence

Two dual-operator orgs ran this in production through: allowlist gating, per-user tape
isolation across `/new`, scoped turn execution, ownership-routed streaming and
permission prompts — plus three real defects found and fixed during rollout (listed in
pitfalls). Single-operator orgs are bit-for-bit unchanged (legacy path untouched).
