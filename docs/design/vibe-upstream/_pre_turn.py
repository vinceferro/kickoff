from __future__ import annotations

import logging

from vibe.core.hooks._handler import (
    HookHandler,
    HookRetryState,
    _HookAction,
)
from vibe.core.hooks.config import HookConfig
from vibe.core.hooks.models import (
    HookEndEvent,
    HookInvocation,
    HookMessageSeverity,
    HookStructuredResponse,
    HookUserMessage,
)

logger = logging.getLogger(__name__)


class PreTurnHandler(HookHandler):
    """Allow → inject ``additional_context`` before the model thinks.

    The mirror of :class:`PostAgentHandler`. That one can inject a retry *after*
    the model has spoken; this one supplies context *before* it does — the
    natural place for recalled memory or project state the agent should know
    without the user restating it every turn.

    A denial is deliberately NOT a veto here: there is no tool call to block and
    no assistant message to retry, so ``decision: "deny"`` would have nothing to
    act on. It is reported as an error and the turn proceeds, because silently
    swallowing a user's turn because a hook script exited oddly is a far worse
    failure than ignoring a meaningless verdict.
    """

    def matches(self, hook: HookConfig, invocation: HookInvocation) -> bool:
        return True

    def _context_action(
        self, hook: HookConfig, response: HookStructuredResponse, severity: HookMessageSeverity
    ) -> _HookAction:
        context = response.hook_specific_output.additional_context
        events: list[object] = [
            HookEndEvent(
                hook_name=hook.name,
                status=severity,
                content=response.system_message,
            )
        ]
        if context:
            events.append(HookUserMessage(content=context))
        return _HookAction(
            events=events,  # type: ignore[arg-type]
            next_invocation=None,
            should_break=False,
        )

    def _on_allow(
        self,
        hook: HookConfig,
        invocation: HookInvocation,
        response: HookStructuredResponse,
        retry_state: HookRetryState,
    ) -> _HookAction:
        retry_state.track_no_retry(hook.name)
        return self._context_action(hook, response, HookMessageSeverity.OK)

    def _on_deny(
        self,
        hook: HookConfig,
        invocation: HookInvocation,
        response: HookStructuredResponse,
        retry_state: HookRetryState,
    ) -> _HookAction:
        logger.debug("pre_turn hook %s returned deny; there is nothing to veto", hook.name)
        retry_state.track_no_retry(hook.name)
        return self._context_action(hook, response, HookMessageSeverity.ERROR)

    def on_passthrough(self, hook: HookConfig, retry_state: HookRetryState) -> None:
        retry_state.track_no_retry(hook.name)
