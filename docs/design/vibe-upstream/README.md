# A `pre_turn` hook for Mistral Vibe

An upstream contribution candidate for [mistral-vibe](https://github.com/mistralai/mistral-vibe)
(Apache-2.0), drafted 2026-08-15. **Not submitted** — opening the PR is the operator's call, since it
is public and goes out under his identity.

Against upstream `4530b9ce6f74`. Apply with `git apply 0001-pre-turn-hook.patch` from a clone, then
drop `_pre_turn.py` into `vibe/core/hooks/` (it is a new file, so the patch alone is not enough).

## What it does

Vibe's `HookType` is a closed three-value enum — `POST_AGENT`, `PRE_TOOL`, `POST_TOOL`. Nothing fires
*before* a turn, so a hook cannot supply the model with context. This adds `PRE_TURN`, which fires
once per user turn and injects `hook_specific_output.additional_context` as a user message before the
model thinks.

**Why it is small:** the machinery already existed. `post_agent` already turns a `HookUserMessage`
into `LLMMessage(role=user, injected=True)` in order to inject a *retry*. This mirrors that path in
the other direction. 57 lines across 4 files, plus one new handler modelled on `_post_agent.py`.

| file | change |
|---|---|
| `vibe/core/hooks/models.py` | `PRE_TURN` enum member, `PreTurnInvocation`, widen the `additional_context` comment |
| `vibe/core/hooks/_pre_turn.py` | **new** — `PreTurnHandler` |
| `vibe/core/hooks/manager.py` | register the handler |
| `vibe/core/agent_loop_hooks.py` | `_run_pre_turn_hooks` + `_dispatch_pre_turn_hooks`, mirroring the post-agent pair |
| `vibe/core/agent_loop/_loop.py` | fire once per user turn, before the loop |

## Two deliberate design choices

**Fired outside the turn loop, not inside it.** The loop re-runs for tool round-trips; firing per
iteration would re-inject the same memory on every tool call.

**A `deny` verdict is not a veto.** There is no tool call to block and no assistant message to retry,
so denial has nothing to act on. It is reported as an error and the turn proceeds — silently
swallowing a user's turn because a hook script exited oddly is a far worse failure than ignoring a
verdict that cannot mean anything here.

## Evidence

RED→GREEN at the config layer: unpatched Vibe rejects `type = "pre_turn"` with a `ValidationError`;
patched, it accepts and round-trips.

End to end, against live `mistral-medium-3.5`:

| workspace | hook | model knows the injected fact |
|---|---|---|
| pristine | **on** | yes |
| pristine | off | no |
| *reused* | off | **yes — confounded** |

That third row is the reason the control matters, and it is worth keeping in the record. The first
"success" was run in a workspace where the hook had already fired, and **Vibe persists session
history per directory** — so the model may have been remembering rather than being told. Stopping at
the positive would have reported a working patch on evidence that did not support it. Only the
pristine pair settles it.

## Before this is PR-quality

- Tests in **their** suite. It is currently proven by our harness, not theirs.
- Their `AGENTS.md` conventions pass (Pydantic validators, discriminated unions, `Raises:` docs).
- A docs entry for the new hook type alongside the existing three.
