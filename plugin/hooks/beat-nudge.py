#!/usr/bin/env python3
"""UserPromptSubmit nudge: tell the coordinator how long its RECENT beats actually ran.

This is the operator's own design call (2026-08-10): enforce at GENERATION time, not as a hard
limit. `beat-length-guard.py` is the backstop and it fires late — by the time a PreToolUse hook
denies a message, the message has already been composed. Measured across 701 real beats on this
box: **49.5% sit above the 7-line soft limit and only 5.4% ever reach the hard deny.** The guard
therefore never sees the band where the operator's actual pain lives; a nudge that arrives BEFORE
composition is aimed at that band instead.

Why a hook and not a line in CLAUDE.md: the rule is already in CLAUDE.md, already in memory, and
already re-injected on essentially every turn by the recall hook — and beats still ran long. An
instruction competes with a growing context. A hook does not. The difference between this and the
prose is that this one carries a MEASUREMENT of what the coordinator just did, which prose cannot.

WHAT IT DOES: resolves THIS session's transcript, finds the last few Telegram `reply`/
`edit_message` calls that were actually DELIVERED, counts their non-blank lines exactly the way
the guard counts them, and — only when the recent median is over the soft limit, and only once per
new beat — injects one line naming the real numbers. Silent otherwise, in the same "output IS the
finding" idiom as `orphaned-work.py` and `agent-mail-hook.sh`.

WHAT IT NEVER DOES: block a turn, rewrite a prompt, truncate anything, or emit a permission
decision. It annotates; it does not decide. Every failure path exits 0 with empty stdout.

SESSION IDENTITY IS THE LOAD-BEARING PART. An adversarial pass broke the first version here twice:
it resolved the transcript by newest-mtime inside the project directory, so a *sibling* session
writing one second later won and the nudge quoted **another session's beats**; and it keyed the
project directory on the payload's `cwd`, which is the session's LIVE cwd — one `cd` into a
subdirectory (≈500 recorded turns in this repo alone) and it silently resolved nothing. So now:
the runtime's own `transcript_path` when present, else `<projects>/<slug>/<session_id>.jsonl`
walking UP from cwd to find the project root — and **never** a guess. No session id, no nudge.

Session identity is load-bearing a SECOND time, in the dedupe marker: it lives in the marker's
FILENAME, not inside a shared file's contents. The first version kept one `beat-nudge-seen` per
repo with the session id in the value, opened truncating — so two sessions in one repo overwrote
each other every turn and BOTH nudged on EVERY turn. See `_state_path`.

Transcript-directory naming is derived, not assumed: Claude Code replaces non-alphanumeric
characters (not only path separators) with '-', which the first version got wrong and its own
fixture could not catch, because the fixture was built with the hook's rule instead of the
runtime's. Both encodings are tried, and only an existing directory is ever used.

Knobs: BEAT_NUDGE=0 disables · BEAT_GUARD=0 also disables (one switch for the whole beat
machinery) · BEAT_NUDGE_LINES (7, shared with the guard) · BEAT_NUDGE_WINDOW (5 recent beats).
A threshold at or below zero disables that dimension rather than nudging on everything — the same
"every knob misreading resolves toward silence" rule the guard documents.
"""

import json
import os
import re
import sys
import time

DEFAULT_NUDGE_LINES = 7
DEFAULT_WINDOW = 5

TOOL_RE = re.compile(r"^mcp__.*telegram.*__(reply|edit_message)$", re.IGNORECASE)


def _silent():
    """Emit nothing. The turn proceeds untouched — this hook must never cost the operator a turn."""
    sys.exit(0)


def _limit_env(name, default):
    """Resolve a knob, degrading toward SILENCE on every bad value.

    Same shape as the guard's `_limit_env`, and for the same reason: the switch beside these is
    `BEAT_NUDGE=0`, so "set it to 0 to turn it off" is the natural misread. Read literally, a
    window of 0 would measure nothing and a limit of 0 would nudge on every single turn — noise
    on every prompt, which is how a useful signal gets disabled for good. Both resolve to off.
    """
    try:
        value = int(os.environ[name])
    except (KeyError, ValueError, TypeError):
        return default
    return value if value > 0 else None


def _projects_root():
    """Where Claude Code keeps per-project transcripts.

    `CLAUDE_CONFIG_DIR` is honoured because this engine's own `preflight.sh` honours it and the
    supervisor forwards it into child sessions — hardcoding `~/.claude` would make the hook look
    in the wrong place on exactly the installs that moved it.
    """
    base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    return os.path.join(base, "projects")


def _slugs(path):
    """Candidate directory names for a project path, most-literal first.

    The runtime replaces non-alphanumeric characters with '-'; an earlier version replaced only
    the path separator, which made every project whose path contains '_' or '.' permanently
    unresolvable (9 of 43 real project dirs on this box). Both forms are tried and only a
    directory that EXISTS is ever used, so widening the search can never select the wrong one.
    """
    out = []
    for s in (path.replace(os.sep, "-"), re.sub(r"[^A-Za-z0-9]", "-", path)):
        if s and s not in out:
            out.append(s)
    return out


def _resolve_transcript(payload):
    """This session's transcript, or None. Never another session's.

    Order: the runtime's own `transcript_path` (authoritative when present), else the file named
    for this `session_id` — transcripts are `<sessionId>.jsonl` — searched from the payload's cwd
    UPWARD, because cwd is the live working directory and may sit below the project root.

    There is deliberately no newest-mtime fallback and no ambient-env fallback. Both were real
    defects: mtime hands you whichever sibling session wrote last, and an ambient
    CLAUDE_PROJECT_DIR is precisely the value that leaks between orgs on a shared box. Quoting
    another session's beats is worse than saying nothing, so the failure mode is silence.
    """
    given = payload.get("transcript_path")
    if isinstance(given, str) and os.path.isfile(given):
        return given

    session_id = payload.get("session_id")
    cwd = payload.get("cwd")
    if not isinstance(session_id, str) or not session_id or not isinstance(cwd, str) or not cwd:
        return None

    root = _projects_root()
    d = os.path.abspath(cwd)
    while True:
        for slug in _slugs(d):
            candidate = os.path.join(root, slug, session_id + ".jsonl")
            if os.path.isfile(candidate):
                return candidate
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def _unresolved_path(payload, create=False):
    """Where the "resolution is broken" flag lives, or None if this project keeps no kickoff state.

    Shared by the writer and the clearer so the two can never disagree about which file they mean —
    the flag was previously written in one place and removed in none.
    """
    cwd = payload.get("cwd")
    if not isinstance(cwd, str) or not cwd:
        return None
    path = os.environ.get("BEAT_NUDGE_LOG")
    if path:
        return path
    if not os.path.isdir(os.path.join(cwd, ".kickoff")):
        return None
    path = os.path.join(cwd, ".kickoff", "state", "beat-nudge-unresolved.log")
    if create:
        os.makedirs(os.path.dirname(path), exist_ok=True)
    return path


def _note_unresolved(payload, reason):
    """Leave ONE stamped line when the transcript could not be resolved.

    Bounded on purpose, after an earlier version appended a line per turn forever and created a
    `.kickoff/state/` tree inside whatever directory the session happened to be sitting in. It
    now writes only where kickoff state already lives, and truncates rather than appends: this is
    a "does resolution work" flag, not a log.

    The stamp is not decoration. A session's transcript does not exist yet when its FIRST turn
    fires, so essentially every session trips this once — and an unstamped flag then sits there
    reading as "the hook is broken" long after resolution started working. `_clear_unresolved`
    removes it on the next resolved turn; the stamp is the fallback for the case where the state
    directory is writable enough to have kept an old flag but not to drop it.
    """
    try:
        path = _unresolved_path(payload, create=True)
        if not path:
            return
        with open(path, "w") as fh:
            fh.write("beat-nudge: no transcript (%s) [%s]\n"
                     % (reason, time.strftime("%Y-%m-%dT%H:%M:%S%z")))
    except BaseException:
        pass


def _clear_unresolved(payload):
    """Drop a flag left by an earlier turn, now that resolution demonstrably works.

    Best-effort and silent: the flag is a diagnostic, and failing to remove one is never worth
    costing the operator a turn. Without this the docstring above ("silence means it worked") was
    a claim about a file that nothing ever cleared — true of the code path, false on disk.
    """
    try:
        path = _unresolved_path(payload)
        if path:
            os.remove(path)
    except BaseException:
        pass


def _beat_lines(transcript_path, window):
    """(id, line-count) of the last `window` Telegram beats that were actually DELIVERED.

    Counts EXACTLY as beat-length-guard.py does (blank lines are paragraph breaks, not content) —
    if the two disagreed, the nudge would coach toward a number the guard does not enforce.

    Beats the guard DENIED are dropped. They were never sent, so counting them would make the
    nudge loudest precisely when the backstop had already done its job — nagging about a message
    the operator never received.

    Reads line-by-line and tolerates malformed records: a transcript is an append-only log that
    may be mid-write when a hook fires, so one unparseable tail line must not lose the whole
    measurement.
    """
    beats = []            # [(tool_use_id, lines)] in order
    failed = set()        # tool_use_ids whose result came back an error (denied / not sent)
    with open(transcript_path, "r", errors="replace") as fh:
        for raw in fh:
            low = raw.lower()
            # Cheap prefilter — lowercased because TOOL_RE is case-insensitive and a
            # case-sensitive test would silently disagree with the regex it exists to speed up.
            if "telegram" not in low and "is_error" not in low:
                continue
            try:
                rec = json.loads(raw)
            except ValueError:
                continue
            content = ((rec.get("message") or {}).get("content")) or []
            if not isinstance(content, list):
                continue
            for part in content:
                if not isinstance(part, dict):
                    continue
                kind = part.get("type")
                if kind == "tool_use" and TOOL_RE.match(part.get("name") or ""):
                    text = (part.get("input") or {}).get("text")
                    if isinstance(text, str) and text.strip():
                        n = len([ln for ln in text.splitlines() if ln.strip()])
                        beats.append((part.get("id"), n))
                elif kind == "tool_result" and part.get("is_error"):
                    failed.add(part.get("tool_use_id"))

    delivered = [(i, n) for (i, n) in beats if i not in failed]
    return delivered[-window:]


def _median(values):
    s = sorted(values)
    n = len(s)
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2.0


def _session_suffix(payload):
    """A filename-safe, bounded form of this session id — never a path, never empty.

    The session id decides a FILENAME here, and the payload is untrusted input: `../../etc/x` or a
    4 kB id must not decide where this hook writes. Reduced to [A-Za-z0-9_-] and cut to 64 chars.
    """
    sid = payload.get("session_id")
    if not isinstance(sid, str):
        sid = ""
    safe = re.sub(r"[^A-Za-z0-9_-]", "-", sid).strip("-")[:64]
    return "-" + (safe or "no-session")


def _state_path(payload):
    """Where THIS SESSION's last-nudged marker lives, or None if the project keeps no kickoff state.

    The session id is in the FILENAME. It used to be inside the VALUE of one shared
    `<repo>/.kickoff/state/beat-nudge-seen`, written with a truncating open — so with two sessions
    in one repo, A wrote its key, B overwrote it, A read B's key and mismatched, and BOTH sessions
    nudged on EVERY turn. The dedupe did not merely weaken there, it inverted: the guard against
    "a signal that trains its reader to ignore it" became the thing generating the noise, at one
    injected context line plus one user-visible systemMessage per turn per session. A shared
    mutable file cannot dedupe per session; a per-session path needs no coordination at all.

    BEAT_NUDGE_STATE names a BASE path and takes the same suffix, so no caller — a test fixture
    included — can pin the one-file-per-repo world back into existence.
    """
    cwd = payload.get("cwd")
    if not isinstance(cwd, str) or not cwd:
        return None
    suffix = _session_suffix(payload)
    override = os.environ.get("BEAT_NUDGE_STATE")
    if override:
        return override + suffix
    d = os.path.abspath(cwd)
    while True:
        if os.path.isdir(os.path.join(d, ".kickoff")):
            return os.path.join(d, ".kickoff", "state", "beat-nudge-seen" + suffix)
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def _already_nudged(payload, marker):
    """True when this exact measurement has already been reported.

    Without this the same nudge re-fires on every turn until three new short beats push the
    median down — up to fifteen identical injections for one long beat, which is how a signal
    trains its reader to ignore it. The file holds only the measurement; WHICH session it belongs
    to is the path (`_state_path`), so two sessions in one repo neither silence each other nor
    trample each other's marker. Best-effort: if the state cannot be read or written, nudge (a
    repeat is a much smaller failure than never nudging at all).
    """
    path = _state_path(payload)
    if not path:
        return False
    try:
        with open(path, "r") as fh:
            if fh.read().strip() == marker:
                return True
    except BaseException:
        pass
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(marker)
    except BaseException:
        pass
    return False


def main():
    if os.environ.get("BEAT_NUDGE") == "0" or os.environ.get("BEAT_GUARD") == "0":
        _silent()

    payload = json.loads(sys.stdin.read())

    nudge_lines = _limit_env("BEAT_NUDGE_LINES", DEFAULT_NUDGE_LINES)
    window = _limit_env("BEAT_NUDGE_WINDOW", DEFAULT_WINDOW)
    if nudge_lines is None or window is None:
        _silent()

    transcript = _resolve_transcript(payload)
    if not transcript:
        _note_unresolved(payload, "no transcript_path in payload and no session file under the project dir")
        _silent()

    # Resolution works on this turn, so any flag from an earlier one (every session's first turn
    # fires before its transcript exists) is stale and must not keep reading as a live breakage.
    _clear_unresolved(payload)

    beats = _beat_lines(transcript, window)
    if not beats:
        _silent()  # no delivered beats yet this session — nothing measured, so nothing to say

    counts = [n for (_, n) in beats]
    med = _median(counts)
    if med <= nudge_lines:
        _silent()  # recent beats are clean; a nudge here would be noise that trains you to ignore it

    if _already_nudged(payload, "%s:%s" % (beats[-1][0], med)):
        _silent()  # same measurement as last time — say it once, not every turn until it changes

    line = (
        "Your last %d beats ran %s lines (median %g, soft limit %d). Lead with the answer, then "
        "STATE / NEXT / NEEDS-YOU; detail belongs in the tracker or an attached file. Long is fine "
        "when the situation earns it — unfollowable is not."
        % (len(counts), ", ".join(str(c) for c in counts), med, nudge_lines)
    )

    # Both keys are accepted by this runtime — checked against the shipped binary's own schema,
    # not the docs: UserPromptSubmit's hookSpecificOutput carries an optional additionalContext,
    # and systemMessage is an optional top-level warning shown to the user.
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": line,
        },
        "systemMessage": line,
    }))
    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except BaseException:
        # A measurement is never worth costing the operator a turn.
        _silent()
