#!/usr/bin/env python3
"""
context-headroom.py — how full is a worker's context window, and why is it not fuller?

  python3 scripts/context-headroom.py                 # every live worker on this box
  python3 scripts/context-headroom.py <repo-path>     # one project
  python3 scripts/context-headroom.py --json          # machine-readable

WHY THIS EXISTS
  "Deep in a session but still under the reboot threshold" is the property that decides whether a
  long-running worker keeps its continuity or has to be refreshed and re-ground. It was previously
  invisible — the only signal was the session dying or an operator's impression.

WHAT IT MEASURES
  Every assistant turn records `message.usage`. The tokens the model actually READ that turn are
  `input + cache_read + cache_creation` — that IS the context window occupancy at that moment.
  The newest turn is therefore the current fill.

  Two cautions the numbers depend on:
    · DE-DUPLICATE BY `message.id`. Claude Code writes one transcript line per content block and
      replays the same usage on each, so a naive sum over lines double-counts (it inflated a real
      cost figure ~1.6x before this was noticed).
    · A SUBAGENT'S CONTEXT IS NOT THE PARENT'S. Delegated work runs in its own window and returns
      only a result, which is exactly how a session stays deep and small at the same time. So
      delegation is counted separately rather than added in — it is the explanation, not the load.
"""
import json
import glob
import os
import sys
import urllib.request

# Opus 5 runs a 1M window here — measured, not assumed: a single live request on this box read
# 864,150 cached tokens, which is impossible against the 200k I first wrote. A wrong window makes
# every percentage meaningless while still looking like a number.
WINDOW = 1_000_000
REFRESH_AT = 0.80         # the zone where a refresh starts being the right call

# A turn-to-turn fall this large is a window reset, not normal churn. MEASURED across all 2,395
# transcripts present on this box on 2026-08-12 — a live corpus, so read the count as
# point-in-time — not guessed, because the shipped 100_000 was guessed and was wrong:
#   · the 11 genuine compaction drops (each the turn right after an isCompactSummary record)
#     span 920,240 - 946,993 — autocompaction fires near a full window and collapses it
#   · the largest ordinary fall between two real turns is 103,424
#   · every one of the 8 sessions that actually compacted PEAKED at 991,816 - 999,907, i.e. at
#     99.2% of the window or more
# Nothing at all lies between the first two. 100_000 sat just UNDER the largest real churn drop,
# so a clean 940k-fill session printed "94% ← refresh zone" AND "COMPACTED 1x" at the same time —
# telling the operator that a correct, alarming number was untrustworthy.
#
# WHY THE THRESHOLD IS DERIVED PER SESSION AND NOT A CONSTANT. The previous line was WINDOW // 2,
# and WINDOW is a hardcoded 1_000_000 that nothing checks against the model actually running. So
# for ANY model whose entire window is under ~500k the condition `d < -threshold` was unreachable
# and this fallback was DEAD — silently. Reproduced: a 200k-window session that compacted without
# writing a record reported 1 reset before the raise and 0 after, with no warning anywhere, since
# window_suspect only fires on peak > WINDOW and never the other way. That is the worst failure
# shape this tool has, because it renders as a compacted worker sitting at 9% full with nothing
# flagged — the exact "stayed lean by delegating" misread the resets field exists to prevent. This
# ships to adopters and the routing table sends work to models with smaller windows than this one.
#
# The third measurement above is what makes a per-session threshold sound rather than a heuristic
# dressed up as one: a compaction empties a window that was FULL, so the session's own observed
# PEAK is the pre-compaction fill, and a peak is a genuine observable — it is in the transcript,
# it needs no assumption about the model, and a session that compacted necessarily recorded its
# near-full peak in the same file. Half the peak carries the same 1.8x margin under the smallest
# real compaction that half the window did, at every window size instead of one.
#
# The FLOOR is what stops that from re-opening the 100_000 false-positive class on short sessions,
# where peak // 2 would fall back under ordinary churn. 150_000 is 1.45x the largest ordinary fall
# ever measured here, and because it is a floor the effective threshold is never below it: no
# ordinary fall in the entire 2,395-transcript corpus can cross this at any peak.
#
# THE LIMIT THIS STILL HAS, stated rather than left to be discovered: the floor dominates until a
# session peaks at 300k, so for a model whose window is under ~160k a real compaction falls short
# of 150_000 and only the isCompactSummary record can flag it. That case is reported as
# `drop_blind` instead of being silent — see analyse().
RESET_DROP_FLOOR = 150_000


def reset_drop(peak):
    """The fall that counts as a reset for a session that peaked at `peak`."""
    return max(RESET_DROP_FLOOR, peak // 2)


def analyse(path):
    """Latest context fill, peak, turns, delegations, AND whether the session was RESET.

    RESETS ARE THE LOAD-BEARING ADDITION. Autocompaction drops the window back to ~zero and the
    session keeps going, so a compacted worker reads as *low fill, many turns* — indistinguishable
    from one that stayed lean by delegating well. CLAUDE.md warns about exactly this in prose, and
    the warning did not hold: a memory concluded that the deepest delegator was the cheapest worker
    at 612 tokens/turn, when 612 was `current / turns` measured across a compaction — post-reset
    context divided by the whole session's turns. Corrected, that worker sits at 1,627/turn, within
    1% of a worker that delegates 3.8x less. A whole causal claim rested on a denominator error
    that no check could catch, because nothing here counted resets.

    That 1,627 is itself now HISTORICAL, and saying so is the whole point of the paragraph above.
    It is what this tool computed before the synthetic-record filter and the deltas divisor below
    landed; re-measured under the corrected tool ON 2026-08-12 the same transcript read 1,574/turn,
    because a phantom rate-limit notice was adding both a turn and a large phantom recovery delta.
    Read 1,574 as a reading TAKEN ON A DATE and not as a standing property of that worker: the
    transcript belongs to a live session that keeps growing, so the figure moves as it runs and
    carries no guarantee of still holding by the time you read this. Every other number in this
    file is dated for exactly that reason and this one had been left in the present tense.
    (Do not upgrade that to a claim it HAS drifted without re-measuring — the deepest worker on
    this box still printed 1,574/turn on 2026-08-12, hours after the figure was written. A drift
    asserted rather than measured is the same defect as a constant asserted rather than measured,
    which is what the whole comment above this one is about.) The "within 1%"
    comparison rests on the older pair of numbers and has NOT been re-verified against the
    corrected tool — treat it as the story of a denominator bug, not as a live measurement.

    So this now reports `resets` and a compaction-immune `growth` (the sum of positive per-turn
    deltas ÷ the number of DELTAS). Never divide `current` by `turns` when `resets` is non-zero.

    `growth` is WORK growth: it sums deltas, so the first turn's fixed boot load (system prompt +
    CLAUDE.md + tool schemas, ~43k here) is excluded rather than amortised. That is the number
    worth comparing between workers; a short session's headline cost is dominated by boot
    amortisation, which says more about session length than about how the worker behaves.
    """
    seen = set()
    turns = []
    delegated = 0
    compactions = 0
    model = ""
    for line in open(path, errors="replace"):
        # isCompactSummary rides a `user` record with no usage block, so it would never reach the
        # parser if this prefilter only admitted usage/Task lines.
        if '"isCompactSummary"' in line:
            try:
                if json.loads(line).get("isCompactSummary"):
                    compactions += 1
                    continue
            except Exception:
                pass
        if '"usage"' not in line and '"Task"' not in line:
            continue
        try:
            rec = json.loads(line)
        except Exception:
            continue
        msg = rec.get("message") or {}
        # delegation: a Task tool call means work went to a subagent's OWN window
        for blk in (msg.get("content") or []) if isinstance(msg.get("content"), list) else []:
            # The delegation tools are Workflow / Agent / Task. Counting only "Task" reported
            # zero delegation for a worker that had run 25 workflows — a confident, wrong zero.
            if isinstance(blk, dict) and blk.get("type") == "tool_use" \
                    and blk.get("name") in ("Workflow", "Agent", "Task"):
                delegated += 1
        u, mid = msg.get("usage"), msg.get("id")
        if not u or not mid or mid in seen:
            continue
        seen.add(mid)
        # NOT A TURN. Claude Code writes rate-limit and API-error notices as an `assistant`
        # record with model "<synthetic>" and an all-zero usage block. Nothing read a context
        # window there, and a real assistant turn CANNOT read 0 tokens — the system prompt alone
        # is ~43k here. Admitting those zeros to the series was the single largest source of
        # wrong numbers in this tool, three ways at once:
        #   · the fall to 0 crosses RESET_DROP, so `resets` read 1 on sessions that never
        #     compacted — 12 of the 20 flagged sessions on this box, none of which held a single
        #     isCompactSummary record
        #   · the climb back to real fill re-enters as one huge positive delta, inflating
        #     `growth` — the worst case on this box read 15,888/turn against a corrected 894, 18x
        #     (that session is 3 real turns; the notice had been inflating both the numerator and
        #     the turn count at once)
        #   · a session whose LAST record was a notice reported 0k / 0% / an empty headroom bar —
        #     the strongest possible "safe to keep going" signal this tool can emit — on sessions
        #     that had peaked at 128k-422k, and leaked "<synthetic>" as the model
        # The zero is the real tell, so it is checked on its own rather than trusting the name
        # "<synthetic>" to stay stable.
        if msg.get("model") == "<synthetic>":
            continue
        read = (int(u.get("input_tokens", 0))
                + int(u.get("cache_read_input_tokens", 0))
                + int(u.get("cache_creation_input_tokens", 0)))
        if read == 0:
            continue
        model = msg.get("model") or model
        turns.append(read)
    if not turns:
        return None
    # Compaction-immune growth: only POSITIVE deltas. A reset shows up as a large negative step,
    # which this skips rather than letting it cancel out real growth.
    #
    # The isCompactSummary record is the PRIMARY reset signal; the drop detector below is the
    # documented FALLBACK for when no record was written, so the flag does not depend on one
    # field name staying stable. Scaling the threshold to half the session's own PEAK keeps that
    # fallback alive at every window size instead of only at 1M (see reset_drop above), but the
    # blind spot it leaves is worth naming rather than burying: a record-less compaction fired
    # from below ~50% fill is still not caught by the drop alone, and below the floor nothing is.
    # Every compaction actually observed here wrote the record and fired from 99.2%+ of the
    # window, whereas the false positives were frequent and measured (60% of all flags). Trading
    # an unobserved under-count for a measured over-count is the right way round — but it is a
    # trade, not a free win, which is why the under-count now reports itself as `drop_blind`.
    peak = max(turns)
    threshold = reset_drop(peak)
    grown = 0
    drops = 0
    for prev, cur in zip(turns, turns[1:]):
        d = cur - prev
        if d > 0:
            grown += d
        elif d < -threshold:
            drops += 1
    # The two detectors see the SAME event from different sides — a compaction writes the record
    # AND collapses the usage series. Adding them reports "2 resets" for one compaction, which is
    # a number that would get quoted. Take the larger: either signal alone is enough to invalidate
    # current/turns, and neither is trusted to be present.
    #
    # n turns hold n-1 deltas. Dividing by `turns` understated every worker's cost, always in the
    # flattering direction and worse the shorter the session (10 turns 10% under, 2 turns 50%
    # under, 1 turn reads a confident 0). Under 3 turns the sample cannot answer the question at
    # all, so it returns None and the display dashes it out rather than printing a number nobody
    # should quote.
    # `drop_blind` is the honest statement of when the fallback CANNOT fire for this session: no
    # fall can exceed the peak, so if the threshold is at or above the peak the drop detector is
    # structurally inert here and only the record can flag a reset. It is always in the JSON,
    # because a limit reported only when someone thinks to look is the silent failure again.
    return {"turns": len(turns), "current": turns[-1], "peak": peak,
            "delegated": delegated, "model": model, "resets": max(compactions, drops),
            "drop_threshold": threshold, "drop_blind": peak <= threshold,
            "growth": grown // (len(turns) - 1) if len(turns) >= 3 else None}


def live_workers():
    """repo -> newest transcript, for every running channels worker."""
    out = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open("/proc/%s/environ" % pid, "rb") as f:
                env = dict(kv.split("=", 1) for kv in
                           f.read().decode("utf-8", "replace").split("\0") if "=" in kv)
        except OSError:
            continue
        repo = env.get("REPO_DIR")
        if not repo:
            continue
        # `pgrep -f` on a substring would match this very process — read argv[0] instead.
        try:
            with open("/proc/%s/cmdline" % pid, "rb") as f:
                argv = f.read().decode("utf-8", "replace").split("\0")
        except OSError:
            continue
        if not argv or os.path.basename(argv[0]) != "claude":
            continue
        out[repo] = pid
    return out


RECENT_WINDOW = 900          # seconds; another transcript touched this recently ⇒ ambiguous


def transcript_for(repo):
    """Newest transcript for a repo, plus how many OTHER sessions were recently active.

    Derive the projects dir from the running user's HOME — never a hardcoded /home/<name>.
    This shipped as a literal for its whole life, which is precisely why the file could not
    travel into the public tree: the release gate's leak scan (correctly) refuses a tree
    containing a machine path. CLAUDE_CONFIG_DIR wins when set, matching how the CLI relocates
    its state.

    HONEST LIMIT: newest-mtime is a HEURISTIC for "the running worker", not a proof. One repo can
    hold many sessions (a workflow, a resumed session, a dead predecessor), and this picks whichever
    was written last. A reviewer once read a stale sibling here and reported a worker at 30% that
    they believed was at 70% — wrong in that instance (the sibling was a killed predecessor), but
    the ambiguity is real and the failure is SILENT and understating, which is the dangerous
    direction for a number whose whole job is "am I safe to keep going". So: return the file we
    chose and the count of other recently-touched sessions, and let the caller SAY SO rather than
    print a confident percentage over an unstated guess.
    """
    cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    proj = os.path.join(cfg, "projects", "-" + repo.strip("/").replace("/", "-"))
    fs = glob.glob(proj + "/*.jsonl")
    if not fs:
        return None, 0
    chosen = max(fs, key=os.path.getmtime)
    newest = os.path.getmtime(chosen)
    others = sum(1 for f in fs if f != chosen and newest - os.path.getmtime(f) < RECENT_WINDOW)
    return chosen, others



# ── OPENCODE ARM (engine parity, 2026-08-27) ─────────────────────────────────
# Everything above reads a Claude Code TRANSCRIPT. On a box running WORKER_ENGINE=opencode
# there is no such file, so this tool printed "no live worker transcripts found" and the
# whole degradation-driven refresh loop — measure headroom, touch .kickoff/refresh-requested,
# let the supervisor cycle the session — silently did not exist. The operator felt it as
# "claude restarted itself at critical mass; opencode just gets stuck". The gauge was the
# missing half, not the supervisor.
#
# opencode exposes the same facts over its LOCAL serve (127.0.0.1, per-org port):
#   GET /session                     → sessions, each with `directory` and `model`
#   GET /session/<id>/message        → per-message `tokens {input, output, cache{read}}`
#   GET /config/providers            → per-model `limit.context`
#
# CONTEXT FILL = the LAST assistant turn's (input + cache.read). Verified against a live
# session 2026-08-27: 88,734 against glm-5.3's 1,000,000 → 8.9%. Do NOT use the session-level
# `tokens` roll-up — it is CUMULATIVE across the whole session (that same session read
# 1,522,525 there, which "exceeds" a 1M window and is not a context fill at all).
#
# Honest gaps vs the claude arm, surfaced rather than faked:
#   • deleg is not exposed by the API → reported as 0 and marked, never invented.
#   • there is no isCompactSummary record → only the FALL detector can fire, so drop_blind
#     is forced True and the row carries the same ⓘ the claude arm uses for that case.
#   • the window is the model's REAL limit from the API, not the module default.

def _oc_json(url, timeout=5):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8", "replace"))
    except Exception:
        return None


def opencode_workers():
    """repo -> serve base URL, for every running opencode telegram bridge on this box.

    OPENCODE_BASES is a test/override seam ("repo=base,repo=base"): opencode_workers reads
    /proc, which a hermetic suite cannot fake, so without a seam the whole arm would be
    provable only on a live box — i.e. never RED-first. It is also genuinely useful by hand
    to point the gauge at one serve.
    """
    ov = os.environ.get("OPENCODE_BASES")
    if ov:
        return dict(kv.split("=", 1) for kv in ov.split(",") if "=" in kv)
    out = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open("/proc/%s/environ" % pid, "rb") as f:
                env = dict(kv.split("=", 1) for kv in
                           f.read().decode("utf-8", "replace").split("\0") if "=" in kv)
            with open("/proc/%s/cmdline" % pid, "rb") as f:
                argv = f.read().decode("utf-8", "replace").split("\0")
        except OSError:
            continue
        repo, url = env.get("REPO_DIR"), env.get("OPENCODE_API_URL")
        if not repo or not url:
            continue
        # argv[0] is `node`; the bridge is identified by its script path, not by a -f substring
        # match (which would also match this very process).
        if not any("opencode-telegram" in a for a in argv[:3]):
            continue
        out[repo] = url.rstrip("/")
    return out


_OC_WINDOW_CACHE = {}


def _oc_window(base, model):
    """The model's REAL context limit from the serve, or None — never a guess."""
    key = (base, (model or {}).get("providerID"), (model or {}).get("id"))
    if key in _OC_WINDOW_CACHE:
        return _OC_WINDOW_CACHE[key]
    win, d = None, _oc_json(base + "/config/providers")
    provs = d.get("providers") if isinstance(d, dict) else d
    for p in provs or []:
        if p.get("id") != (model or {}).get("providerID"):
            continue
        m = (p.get("models") or {}).get((model or {}).get("id")) or {}
        win = (m.get("limit") or {}).get("context")
    _OC_WINDOW_CACHE[key] = win
    return win


def opencode_analyse(base, repo):
    """Row for the newest opencode session in `repo`, plus the ambiguity count."""
    sessions = _oc_json(base + "/session")
    if not isinstance(sessions, list):
        return None, 0
    want = repo.rstrip("/")
    mine = [x for x in sessions if (x.get("directory") or "").rstrip("/") == want]
    if not mine:
        return None, 0
    upd = lambda x: ((x.get("time") or {}).get("updated") or 0)
    mine.sort(key=upd, reverse=True)
    s = mine[0]
    # Same honest-ambiguity rule as the claude arm: one repo can hold several sessions.
    others = sum(1 for o in mine[1:] if (upd(s) - upd(o)) < RECENT_WINDOW * 1000)

    msgs = _oc_json(base + "/session/" + s["id"] + "/message")
    msgs = msgs if isinstance(msgs, list) else (msgs or {}).get("messages") or []
    turns = []
    for m in msgs:
        info = m.get("info") or m
        if info.get("role") != "assistant":
            continue
        t = info.get("tokens")
        if not t:
            continue
        turns.append((t.get("input") or 0) + ((t.get("cache") or {}).get("read") or 0))
    if not turns:
        return None, others

    peak = max(turns)
    grown = sum(b - a for a, b in zip(turns, turns[1:]) if b > a)
    threshold = max(RESET_DROP_FLOOR, peak // 2)
    drops = sum(1 for a, b in zip(turns, turns[1:]) if a - b > threshold)
    win = _oc_window(base, s.get("model"))
    return {
        "turns": len(turns), "current": turns[-1], "peak": peak,
        "delegated": 0, "model": (s.get("model") or {}).get("id"),
        "resets": drops, "drop_threshold": threshold,
        # Compute this the SAME way the claude arm does — it is a statement about the peak, and
        # forcing it True made the row print "peak 173k <= 150k", which is simply false. The
        # engine-specific fact (no isCompactSummary record exists here, so ONLY the fall detector
        # can ever fire) is a different claim and gets its own note below.
        "drop_blind": peak <= threshold,
        "no_record_detector": True,
        "growth": grown // (len(turns) - 1) if len(turns) >= 3 else None,
        "engine": "opencode", "window": win, "session_id": s["id"],
        "no_deleg_signal": True,
    }, others

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    as_json = "--json" in sys.argv
    oc = opencode_workers()
    repos = args or sorted(set(live_workers().keys()) | set(oc.keys()))
    rows = []
    for repo in repos:
        found = []
        # BOTH arms, never a preference. Preferring the transcript looked right and was WRONG on a
        # box that had hopped to opencode: the .jsonl that survives is a DIFFERENT session — a
        # human's interactive one, or a stale pre-hop worker — and the tool reported it as "the
        # worker" with a confident percentage. Measured 2026-08-27: 7 of 8 orgs on this box are
        # opencode workers, and every one of them resolved to a claude transcript that was not the
        # worker at all. Emit one row per engine and let the reader see which is which.
        t, amb = transcript_for(repo)
        if t:
            a = analyse(t)
            if a:
                a["session"] = os.path.basename(t)[:8]
                a["engine"] = "claude"
                a["ambiguous"] = amb
                # The load-bearing warning: this repo's actual WORKER is the opencode bridge.
                a["not_the_worker"] = repo in oc
                found.append(a)
        if repo in oc:
            a, amb2 = opencode_analyse(oc[repo], repo)
            if a:
                a["session"] = "oc:" + a["session_id"][4:10]
                a["ambiguous"] = amb2
                found.append(a)
        for a in found:
            a["repo"] = os.path.basename(repo.rstrip("/"))
            # An opencode row carries the model's REAL limit from the serve; the claude arm has
            # no such source and keeps the module assumption. Never overwrite a measured window.
            a["window"] = a.get("window") or WINDOW
            a["pct"] = a["current"] / a["window"]
            # A peak above the window is a CONTRADICTION, not a big number: the window is wrong,
            # so every percentage is meaningless. Say that, not a confident >100%.
            a["window_suspect"] = a["peak"] > a["window"]
            rows.append(a)

    if as_json:
        print(json.dumps(rows, indent=2))
        return 0
    if not rows:
        print("  no live workers found (no claude transcript, no opencode bridge)")
        return 0
    print("  %-18s %-9s %8s %8s %7s %6s %7s  %s"
          % ("worker", "session", "context", "peak", "turns", "deleg", "grow/t", "headroom"))
    for r in sorted(rows, key=lambda x: -x["pct"]):
        bar = "█" * int(r["pct"] * 20) + "·" * (20 - int(r["pct"] * 20))
        flag = "  ← refresh zone" if r["pct"] >= REFRESH_AT else ""
        if r["ambiguous"]:
            flag += "  ⚠ %d other session(s) active — may not be this worker" % r["ambiguous"]
        if r.get("not_the_worker"):
            flag += "  ⚠ NOT this repo's worker — it runs an opencode bridge; this transcript is a different (interactive or pre-hop) session"
        if r.get("no_deleg_signal"):
            flag += "  ⓘ opencode: deleg not exposed by the API (shown 0, not measured)"
        if r.get("no_record_detector") and not r["resets"]:
            flag += "  ⓘ opencode has no compaction RECORD — only the fall detector can fire here"
        if r["window_suspect"]:
            flag += "  ⚠ peak EXCEEDS the assumed %dk window — the percentage is meaningless" % (r["window"] // 1000)
        if r["resets"]:
            flag += ("  ⚠ COMPACTED %dx — this fill is post-reset; do NOT read it as 'stayed lean'"
                     % r["resets"])
        # The drop fallback is inert on this row and nothing else flagged a reset, so the operator
        # is reading a clean row produced by a detector that could not have fired. Say so.
        #
        # THE CUT IS TIED TO `growth`, NOT TO A FREQUENCY, and the knob it replaced is worth the
        # epitaph because it was this file's own signature bug committed a third time. A
        # `r["turns"] >= DEEP_ENOUGH` (=20) cut used to sit here, justified in these words:
        # "measured over the 2,075 sessions with a real turn on 2026-08-12, 70% are drop_blind at
        # 3+ turns and 30% at 20+, and a warning printed on seven rows out of ten is one an
        # operator learns to skip past". Both numbers were wrong, in two different ways:
        #   · WRONG POPULATION. transcript_for() globs `proj + "/*.jsonl"` — NON-RECURSIVE — so
        #     this tool only ever opens the TOP level of a project directory. The 70/30 was taken
        #     over the full recursive set (2,405 files), 95% of which is subagent transcripts that
        #     nothing here can reach. It described a corpus the tool cannot see.
        #   · WRONG DENOMINATOR. The "30%" was 636 sessions blind at 20+ turns divided by the 2,014
        #     sessions with 3+ turns — a joint frequency printed as a conditional rate. The actual
        #     conditional over that same (wrong) population is 636/1,163 = 55%. That is precisely
        #     the error class the analyse() docstring above exists to memorialise, re-committed in
        #     the comment justifying a knob.
        # RE-MEASURED with this build's own analyse() over the population the tool actually reads —
        # the 130 top-level transcripts under ~/.claude/projects on this box, 2026-08-12, a live
        # corpus so read these as point-in-time: drop_blind is 19/93 = 20% at 3+ turns and
        # 8/82 = 10% at 20+. At two rows in ten "an operator learns to skip it" is false, and the
        # cut was measurably suppressing this note on 11 of those 19 sessions — under-reporting a
        # real limit, the one direction everything else here refuses to err in.
        #
        # Deleting the cut outright was the first fix and it was wrong, which is why the ROW is
        # counted here and not the transcript: a row on screen is a REPO (transcript_for picks one
        # file per repo), and over the 43 repos with a transcript on this box an uncut marker lands
        # on 36 of them — 84%, worse than the 70% that was used to justify the cut in the first
        # place. 32 of those 36 are one- and two-turn sessions.
        #
        # So the cut is now `growth is not None`, i.e. the SAME 3-turn boundary analyse() already
        # uses to refuse a growth number, and it is justified structurally rather than by a
        # frequency that will rot: this note exists to stop a clean-looking row being read as
        # "stayed lean by delegating", and that misreading is a misreading OF `growth`. Where the
        # tool already prints a dash instead of a cost, there is no number to protect. That is the
        # whole claim, and it is deliberately not the stronger one: a 2-turn session CAN have
        # compacted record-lessly, --json still reports it drop_blind, and the footnote still
        # states the limit — there is simply no "stayed lean" reading on that row for the per-row
        # note to correct. Measured on the same day: this suppresses NONE of the 19 blind
        # top-level 3+ sessions (the defect above is fully closed) and holds the render at 4/43 =
        # 9% rather than 84%. The JSON always carries drop_blind and the footnote always states the
        # limit, so nothing here changes what is DETECTED — only which rows are annotated.
        if r["drop_blind"] and not r["resets"] and r["growth"] is not None:
            # On opencode there is no isCompactSummary record at all, so naming one as the
            # remaining detector would be false — that row already carries its own note above.
            if r.get("no_record_detector"):
                flag += ("  ⓘ …and the fall detector is inert here too (peak %dk ≤ %dk) — a reset"
                         " on this row would be UNDETECTABLE"
                         % (r["peak"] // 1000, r["drop_threshold"] // 1000))
            else:
                flag += ("  ⓘ drop-detector inert here (peak %dk ≤ %dk) — only an isCompactSummary"
                         " record could flag a reset on this row"
                         % (r["peak"] // 1000, r["drop_threshold"] // 1000))
        # growth is None under 3 turns — too few deltas to mean anything. Print the dash, not a 0.
        print("  %-18s %-9s %7dk %7dk %7d %6d %7s  %s %3d%%%s"
              % (r["repo"], r["session"], r["current"] // 1000, r["peak"] // 1000, r["turns"],
                 r["delegated"], "-" if r["growth"] is None else r["growth"],
                 bar, r["pct"] * 100, flag))
    print()
    print("  context = tokens read on the newest turn (input + cache read + cache creation),")
    print("  de-duplicated by message.id. deleg = Task calls, whose context is NOT counted here")
    print("  because a subagent runs in its own window — that is how a session stays deep and small.")
    print("  session = what was measured: an 8-char transcript name (claude), or oc:<id> read live")
    print("  from that org's opencode serve. A repo can show BOTH — a surviving claude transcript is")
    print("  NOT the worker once the org has hopped to opencode, and is flagged as such.")
    print("  One repo can hold several sessions;")
    print("  if the ⚠ shows, confirm it is the session you mean before trusting the number.")
    print("  grow/t = context GROWTH per turn (sum of positive per-turn deltas / number of")
    print("  deltas, which is turns-1; '-' means under 3 turns, too small a sample to say) — the")
    print("  compaction-immune cost number. current/turns is NOT that: across a reset it divides")
    print("  post-compaction context by the whole session and reports a worker as far cheaper than")
    print("  it is. If ⚠ COMPACTED shows, current/turns is meaningless for that row.")
    print("  %% is against an assumed %dk window — verify it matches the model actually running."
          % (WINDOW // 1000))
    print("  a reset is flagged by the isCompactSummary record OR by a fall over half the session's")
    print("  own peak, floored at %dk. That floor is the honest limit of the second detector: on a"
          % (RESET_DROP_FLOOR // 1000))
    print("  model whose window is under ~160k a real compaction falls short of it, so a record-less")
    print("  compaction there is NOT flagged — the ⓘ marks rows where that detector could not fire.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
