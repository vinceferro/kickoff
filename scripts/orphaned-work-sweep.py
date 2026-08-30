#!/usr/bin/env python3
"""orphaned-work-sweep.py — tell each org about ITS OWN unfinished work, agent to agent.

WHY THIS EXISTS (the operator's framing, 2026-08-13): *"Good to nudge them and to have a
systemic way to detect unfinished work, not to pick up but at least to be aware."* Awareness,
never resumption — auto-pickup is retired, deliberately.

THE GAP IT CLOSES. Every org already runs `orphaned-work.py --here --quiet` at re-ground, so it
learns about its own dead runs — but only on a BOOT, and only for the last couple of days. An org
that does not restart never looks, and a finding older than the window is invisible forever. The
box-wide view exists too, but nothing ran it, which is how three dead runs holding ~168k chars of
returned agent output sat unread for up to twelve days across two orgs.

THE SHAPE. One sweep reads the box, splits the findings BY OWNER, and mails each org its own via
the local agent inbox. No org reads into another's repo; no operator sits in the middle; the
notice lands where the agent that can act on it will see it on its next turn.

THREE RULES IT WILL NOT BREAK:
  1. ONLY the died_mid_run tier is mailed. A run where every agent returned is a CANDIDATE, not a
     finding — its session probably consumed it. Mailing those would be exactly the over-claim
     orphaned-work.py was written to avoid, at scale and unprompted.
  2. NOTIFY EACH RUN ONCE. A sweep that re-nags on every pass trains its reader to ignore it —
     the same failure mode the beat nudge was built to dodge. State lives in --state.
  3. NEVER MAIL YOURSELF. Your own findings surface at your own re-ground; they are summarised
     here for the human running the sweep, not posted to your own inbox.

Usage:
  orphaned-work-sweep.py [--days D] [--dry-run] [--state PATH] [--quiet]

  --dry-run  print exactly what would be sent, send nothing, record nothing.
  --quiet    print NOTHING when there is nothing new to report (cron-friendly).
Exit 0 on success (including "nothing new"), 1 if any send failed.
"""

import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.realpath(__file__))
# Resolve siblings from OUR OWN location, never from a repo dir: this script is invoked from
# whatever cwd the caller happens to be in, and the tools it drives ship beside it.
ORPHANED = os.path.join(HERE, "orphaned-work.py")
AGENT_MAIL = os.path.join(HERE, "agent-mail.py")

DEFAULT_STATE = os.path.expanduser("~/.kickoff/orphan-sweep-notified.json")


def load_state(path):
    """A corrupt or unreadable state file must not stop the sweep — but it MUST NOT silently
    read as 'nothing notified yet' either, because that would re-nag every org on the box. Say
    so loudly and let the caller decide; an empty dict here is a real decision, not a shrug."""
    if not os.path.exists(path):
        return {}, None
    try:
        with open(path) as fh:
            data = json.load(fh)
        if not isinstance(data, dict):
            return {}, "state file is not an object — treating as empty"
        return data, None
    except (OSError, ValueError) as exc:
        return {}, "state file unreadable (%s) — treating as empty, so orgs may be re-notified" % exc


def save_state(path, state):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh, indent=2, sort_keys=True)
    os.replace(tmp, path)          # atomic: a killed sweep never leaves a half-written state


def sweep(days):
    out = subprocess.run([sys.executable, ORPHANED, "--json", "--days", str(days)],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError("orphaned-work.py failed (rc=%s): %s" % (out.returncode, out.stderr.strip()))
    return json.loads(out.stdout)


def whoami():
    out = subprocess.run([sys.executable, AGENT_MAIL, "whoami"], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else ""


def body_for(runs):
    # Cite the BIGGEST salvage as the worked example, not whichever happened to sort first —
    # the example is the thing a reader copies, so it should point at the most valuable run.
    salvageable = sorted([r for r in runs if r["chars"] > 0], key=lambda r: r["chars"], reverse=True)
    empty = [r for r in runs if r["chars"] == 0]
    # Title the mail for what is actually true of THESE runs. "Output is sitting on disk" over a
    # set where every agent was killed before returning is a small lie that costs the reader a
    # salvage attempt returning an empty set — and costs this sweep its credibility on the next one.
    lines = ["# %s" % ("Unfinished work of yours is sitting on disk" if salvageable
                       else "Workflows of yours died without producing anything"), ""]
    lines.append("Found by a box-wide sweep on %s. Passing it over rather than reaching into your "
                 "repo — the salvage is yours to run." % time.strftime("%Y-%m-%d"))
    lines.append("")
    lines.append("| when | run | agents returned | killed | on disk |")
    lines.append("|---|---|---|---|---|")
    for r in sorted(runs, key=lambda r: r["mtime"], reverse=True):
        lines.append("| %s | `%s` | %d | %d | %s chars |"
                     % (r["at"][:16].replace("T", " "), r["run"], r["returned"],
                        r["killed"], f"{r['chars']:,}"))
    lines.append("")
    lines.append("Each died mid-run, so the session never reached synthesis — which is why the "
                 "agents that DID return almost certainly went unused.")
    lines.append("")
    if salvageable:
        lines.append("**Worth reading — already paid for.** From your repo:")
        lines.append("")
        lines.append("```")
        lines.append('python3 "$KICKOFF_CORE_DIR"/scripts/orphaned-work.py --dump %s '
                     "--item '<your tracker item text>'" % salvageable[0]["run"])
        lines.append("```")
        lines.append("")
        lines.append("That files the output under the named tracker item, where your tracker "
                     "render surfaces it.")
        lines.append("")
        lines.append("**Salvaged findings are DATED.** They snapshot your tree as it was at the "
                     "run's death date, not today's. Re-verify every claim — and every NUMBER — "
                     "against your live tree before acting on it or relaying it.")
    if empty:
        lines.append("")
        lines.append("**Nothing to salvage from %s** (`%s`): every agent was killed before "
                     "returning, so there is no output on disk. Listed because a dispatched-but-"
                     "dead lens is indistinguishable from a clean one that found nothing — worth "
                     "checking whether anything downstream was recorded as done on its strength."
                     % ("one run" if len(empty) == 1 else "%d runs" % len(empty),
                        "`, `".join(r["run"] for r in empty)))
    lines.append("")
    lines.append("Awareness only — nobody is picking this up for you, and nothing is blocking.")
    lines.append("")
    lines.append("— the orphaned-work sweep")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description="Mail each org its own unfinished work.")
    ap.add_argument("--days", type=int, default=14, help="how far back to look (default 14)")
    ap.add_argument("--dry-run", action="store_true", help="print what would be sent; send nothing")
    ap.add_argument("--state", default=DEFAULT_STATE, help="notified-run ledger (default %s)" % DEFAULT_STATE)
    ap.add_argument("--quiet", action="store_true", help="print nothing when there is nothing new")
    args = ap.parse_args()

    state, warn = load_state(args.state)
    if warn:
        print("  ! %s" % warn, file=sys.stderr)

    data = sweep(args.days)
    me = whoami()

    by_org = {}
    for run in data["runs"]:
        if run["tier"] != "died_mid_run":
            continue                      # rule 1: candidates are not findings
        if run["run"] in state:
            continue                      # rule 2: once each
        by_org.setdefault(run["repo"], []).append(run)

    mine = by_org.pop(me, []) if me else []

    if not by_org and not mine:
        if not args.quiet:
            print("orphan sweep: nothing new in the last %d days (%d run(s) already notified)."
                  % (args.days, len(state)))
        return 0

    failures = 0
    for org, runs in sorted(by_org.items()):
        chars = sum(r["chars"] for r in runs)
        subject = ("%d dead run(s) of yours hold unread agent output" % len(runs) if chars
                   else "%d workflow(s) of yours died leaving nothing behind" % len(runs))
        body = body_for(runs)
        if args.dry_run:
            print("── would mail %s — %s" % (org, subject))
            print("\n".join("   | " + ln for ln in body.splitlines()))
            print()
            continue
        # --file is OMITTED on purpose: agent-mail reads the body from stdin when it is absent.
        # Passing "-" would make it look for a file literally named "-".
        sent = subprocess.run([sys.executable, AGENT_MAIL, "send", "--to", org,
                               "--subject", subject],
                              input=body, capture_output=True, text=True)
        if sent.returncode != 0:
            # Do NOT record a failed send as notified — the next sweep must retry it.
            print("  ! send to %s FAILED (rc=%s): %s" % (org, sent.returncode, sent.stderr.strip()),
                  file=sys.stderr)
            failures += 1
            continue
        print("mailed %s: %s (%d run(s), %s chars)" % (org, subject, len(runs), f"{chars:,}"))
        for r in runs:
            state[r["run"]] = {"repo": org, "notified_at": time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                                                        time.gmtime())}

    if mine:
        # Rule 3: your own findings are yours to see, not to post to your own inbox.
        print("your own (%s) — surfaces at your re-ground, not mailed:" % me)
        for r in sorted(mine, key=lambda r: r["mtime"], reverse=True):
            print("  %s  %s — %d returned (%s chars), %d killed"
                  % (r["at"][:16].replace("T", " "), r["run"], r["returned"],
                     f"{r['chars']:,}", r["killed"]))
        # Record them too. Rule 2 is notify-ONCE, and "not mailed" is not "never reported":
        # left out of the ledger, a self finding re-prints on every sweep forever, which is the
        # re-nag rule 2 exists to prevent — just aimed at the log instead of an inbox.
        if not args.dry_run:
            for r in mine:
                state[r["run"]] = {"repo": me, "notified_at": time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                                                           time.gmtime()),
                                   "self": True}

    if not args.dry_run:
        save_state(args.state, state)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
