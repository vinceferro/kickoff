#!/usr/bin/env python3
"""UserPromptSubmit nudge: tell a session how full it is, before it stops being able to tell.

THE GAP THIS CLOSES. The charter already says to measure degradation — "run context-headroom.py
at natural boundaries; past ~80%, hand off". `scripts/context-headroom.py` ships and works. Nothing
makes anyone run it. That is an instruction competing with a growing context, and this repo has
already watched that exact arrangement lose: `beat-length-guard.py`'s own docstring records a rule
living in CLAUDE.md, in memory, AND re-injected every turn by the recall hook, still failing.

Measured 2026-08-17 across the live fleet: one worker sat at 79% over 423 turns and never set the
refresh flag; another had already auto-compacted at 968 turns. Self-noticing is the unreliable half
BY CONSTRUCTION — a session re-deriving settled facts is, by definition, not at its sharpest for
spotting that it is doing so. And autocompaction resets the gauge, so the two are indistinguishable
from the inside. A hook does not have that problem: it reads the transcript, not its own memory.

THE LOOP IT SERVES. handoff -> reboot -> reground -> pick the WIP back up. The last three are built
(`.kickoff/refresh-requested` + the supervisor, the re-ground contract, AUTO_PICKUP in
session-run.sh). This is the FIRST one — the trigger nothing owned.

WHAT IT DOES: resolves THIS session's transcript, reads the newest real usage record from its TAIL,
and injects one line naming the real percentage — only past a floor, and at most once per band per
session. Under the floor it is silent, which is nearly every turn of a healthy session.

WHAT IT NEVER DOES: block a turn, rewrite a prompt, emit a permission decision, or act on the
session's behalf. It does NOT touch the refresh flag itself: a refresh discards uncommitted work,
so the checkpoint has to happen first and only the agent knows whether it has. Naming the steps is
the whole job; taking them is not.

WHY A TAIL READ. Occupancy is the NEWEST turn's number, which lives at the end of the file. A live
transcript here reaches 6MB, and this runs every turn — a full parse to read the last record would
be a per-turn tax on every session to answer a question the last few KB already answer.

SESSION IDENTITY IS BORROWED, NOT RE-DERIVED. Resolving "which transcript is mine" broke twice in
`beat-nudge.py` (newest-mtime picked a SIBLING session's file; keying on the payload's live `cwd`
silently resolved nothing after one `cd`). That is solved there, so this imports it rather than
writing a third copy of a problem already paid for twice. If the import fails, this stays silent.

FAIL SILENT, ALWAYS. Every failure path exits 0 with empty stdout: a measurement is never worth
costing a turn. The risk of that posture is a hook that breaks and says nothing, so the suite
carries a POSITIVE CONTROL — a fixture at high fill that must produce a nudge — and lanes on each
band boundary. A guard whose only test is "it stayed quiet" is indistinguishable from a dead one.

Knobs: HANDOFF_NUDGE=0 disables · HANDOFF_NUDGE_PCT (70) · HANDOFF_ACT_PCT (85) · HANDOFF_WINDOW
(1000000, matching scripts/context-headroom.py's measured window for this box's model).
"""

import json
import os
import sys

# Kept in step with scripts/context-headroom.py's WINDOW. Both describe the same instrument, so a
# divergence here would have this hook quote a percentage the operator's own tool contradicts.
DEFAULT_WINDOW = 1_000_000
DEFAULT_NUDGE_PCT = 70      # "start thinking about a boundary"
DEFAULT_ACT_PCT = 85        # "checkpoint and hand off now" — the charter's own line is ~80-90
TAIL_BYTES = 512 * 1024


def _silent():
    """A measurement is never worth costing the operator a turn."""
    sys.exit(0)


def _pct_env(name, default):
    """Resolve a percentage knob. Any bad value falls back to the default, never to 0 — a knob
    misread that silently set the floor to zero would nudge on every turn of every session, which
    is the noise that gets a hook switched off for good."""
    try:
        v = int(os.environ[name])
    except (KeyError, ValueError, TypeError):
        return default
    return v if 1 <= v <= 100 else default


def _load_sibling():
    """Import beat-nudge.py by path (its filename is not a valid module name) for the ONE thing
    worth sharing: session-identity resolution. Its `main()` sits behind an __main__ guard, so an
    import runs only module-level constants."""
    import importlib.util
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "beat-nudge.py")
    spec = importlib.util.spec_from_file_location("_kickoff_beat_nudge", path)
    if spec is None or spec.loader is None:
        return None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _newest_fill(transcript_path):
    """Tokens occupying the window on the newest real turn, or None.

    Mirrors scripts/context-headroom.py exactly: input + cache_read + cache_creation, skipping
    `<synthetic>` records and any record reading 0. Those skips are not cosmetic — a synthetic
    notice reports ~0 tokens, and admitting it made that tool report an EMPTY bar (the strongest
    possible "safe to keep going" signal) on sessions that had peaked past 400k.
    """
    try:
        size = os.path.getsize(transcript_path)
    except OSError:
        return None

    def scan(lines):
        best = None
        for raw in lines:
            if '"usage"' not in raw:
                continue
            try:
                rec = json.loads(raw)
            except ValueError:
                continue
            msg = rec.get("message") or {}
            if msg.get("model") == "<synthetic>":
                continue
            u = msg.get("usage") or {}
            try:
                read = (int(u.get("input_tokens", 0))
                        + int(u.get("cache_read_input_tokens", 0))
                        + int(u.get("cache_creation_input_tokens", 0)))
            except (TypeError, ValueError):
                continue
            if read > 0:
                best = read          # keep walking: the LAST match is the newest turn
        return best

    try:
        with open(transcript_path, "r", errors="replace") as fh:
            if size > TAIL_BYTES:
                fh.seek(size - TAIL_BYTES)
                fh.readline()        # drop the partial first line the seek landed inside
            found = scan(fh)
            if found is not None:
                return found
            # The tail held no usable record (a long stretch of tool results can fill 512KB).
            # Widening to a full scan is the same cost beat-nudge.py already pays every turn, and
            # it is rare — better than reporting "no reading" on a session that has one.
            fh.seek(0)
            return scan(fh)
    except OSError:
        return None


def _marker(mod, payload, band):
    """One nudge per BAND per session. Band lives in the filename beside the session id, so
    crossing 70 does not spend the 85 nudge, and two sessions in one repo cannot silence each
    other — the shared-file bug beat-nudge.py's own docstring records."""
    try:
        base = mod._state_path(payload)      # .kickoff/state/beat-nudge-seen-<session>
    except BaseException:
        return None
    return os.path.join(os.path.dirname(base), "handoff-nudge-%s%s" % (band, mod._session_suffix(payload)))


def _already(path):
    if not path:
        return True                          # cannot dedupe => do not risk nudging every turn
    if os.path.exists(path):
        return True
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write("1\n")
    except OSError:
        return True
    return False


def main():
    if os.environ.get("HANDOFF_NUDGE") == "0":
        _silent()

    try:
        payload = json.loads(sys.stdin.read())
    except ValueError:
        _silent()

    mod = _load_sibling()
    if mod is None:
        _silent()

    transcript = mod._resolve_transcript(payload)
    if not transcript:
        _silent()

    read = _newest_fill(transcript)
    if read is None:
        _silent()

    # NOT _pct_env: that clamps to 1..100 for percentages and would mangle a token count.
    try:
        window = int(os.environ.get("HANDOFF_WINDOW", DEFAULT_WINDOW))
    except (TypeError, ValueError):
        window = DEFAULT_WINDOW
    if window < 1:
        window = DEFAULT_WINDOW

    nudge_pct = _pct_env("HANDOFF_NUDGE_PCT", DEFAULT_NUDGE_PCT)
    act_pct = _pct_env("HANDOFF_ACT_PCT", DEFAULT_ACT_PCT)
    if act_pct <= nudge_pct:
        nudge_pct, act_pct = DEFAULT_NUDGE_PCT, DEFAULT_ACT_PCT

    pct = int(round(100.0 * read / window))
    if pct < nudge_pct:
        _silent()

    band = "act" if pct >= act_pct else "nudge"
    if _already(_marker(mod, payload, band)):
        _silent()

    if band == "act":
        msg = (
            "CONTEXT %d%% FULL (%dk of %dk) — hand off now, do not push through. You cannot feel "
            "this from the inside and autocompaction would hide it. Order matters, because a "
            "refresh discards anything uncommitted: (1) commit the work, (2) write any durable "
            "learning to memory/, (3) update the tracker so the NEXT session can resume the WIP "
            "from it — name the exact item, not the vibe, (4) then `touch .kickoff/refresh-requested`. "
            "The supervisor cycles you and the fresh session re-grounds from those files."
            % (pct, read // 1000, window // 1000)
        )
    else:
        msg = (
            "Context %d%% full (%dk of %dk). Not urgent. Aim to finish the current slice and "
            "checkpoint at the next natural boundary rather than opening a new thread — a handoff "
            "you choose is lossless, a compaction you drift into is not."
            % (pct, read // 1000, window // 1000)
        )

    print(json.dumps({"systemMessage": msg}))
    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except BaseException:
        _silent()
