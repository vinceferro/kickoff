#!/usr/bin/env python3
"""burn-ledger — what did the money BUY?

Correlates token spend (from Claude Code's own session transcripts) against durable
artifacts (commits landed in the repo that spent it), bucketed by hour.

The question it answers is not "how much did I spend" — the CLI already shows that —
but "how much did I spend and get NOTHING back", which is the failure mode that
actually hurts: an agent burns an hour, the session dies or the context rots, and no
commit, no file, no checkpoint survives it.

    python3 scripts/burn-ledger.py                  # last 48h, all repos
    python3 scripts/burn-ledger.py --since '2026-07-25 05:00'
    python3 scripts/burn-ledger.py --repo myproject

HONEST LIMITS (read these before quoting a number):
  * Costs are API LIST PRICE for the model named in each turn. On a subscription with
    credit overage this is an upper-bound proxy, not your invoice. The RATIOS are the
    signal; the absolute dollars are an estimate.
  * "Artifact" means a git commit. Durable work that never reaches a commit is invisible
    here — including gitignored paths (kickoff's own memory/ is gitignored, so memory
    writes read as zero-artifact). A zero-artifact hour is a QUESTION, not a verdict.
  * A long-running agent that legitimately needs 3h before its first commit will look
    wasteful at hour 1. Read the run, not just the flag.
"""
import argparse
import collections
import datetime as dt
import glob
import json
import os
import subprocess

PROJECTS = os.path.expanduser("~/.claude/projects")
HOME = os.path.expanduser("~")

# $/Mtok: (uncached-in, cache-write, cache-read, out)
PRICES = {
    "claude-opus": (5.0, 6.25, 0.50, 25.0),
    "claude-fable": (10.0, 12.50, 1.00, 50.0),
    "claude-sonnet": (3.0, 3.75, 0.30, 15.0),
    "claude-haiku": (1.0, 1.25, 0.10, 5.0),
}
FIELDS = (
    ("input_tokens", 0),
    ("cache_creation_input_tokens", 1),
    ("cache_read_input_tokens", 2),
    ("output_tokens", 3),
)


def price_for(model):
    for prefix, p in PRICES.items():
        if model.startswith(prefix):
            return p
    for key, p in PRICES.items():
        if key.split("-")[1] in model:
            return p
    return (0.0, 0.0, 0.0, 0.0)


def repo_of(project_key):
    """A project-dir name back to the repo it belongs to (None if not under $HOME).

    Claude Code names the directory after the repo's absolute path with the separators
    turned into dashes; this strips the $HOME prefix back off.
    """
    prefix = "-" + HOME.strip("/").replace("/", "-") + "-"
    if not project_key.startswith(prefix):
        return None
    return project_key[len(prefix):]


def collect_spend(since):
    """(repo, hour) -> {cost, msgs, out, ctx} for every turn newer than `since`."""
    spend = collections.defaultdict(lambda: collections.Counter())
    for path in glob.glob(PROJECTS + "/**/*.jsonl", recursive=True):
        try:
            if os.path.getmtime(path) < since.timestamp():
                continue
        except OSError:
            continue
        repo = repo_of(path[len(PROJECTS) + 1:].split("/")[0])
        if repo is None:
            continue
        try:
            fh = open(path, errors="replace")
        except OSError:
            continue
        with fh:
            for line in fh:
                if '"usage"' not in line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                stamp = rec.get("timestamp")
                if not stamp:
                    continue
                try:
                    when = dt.datetime.fromisoformat(stamp.replace("Z", "+00:00")).astimezone()
                except ValueError:
                    continue
                if when < since:
                    continue
                msg = rec.get("message") or {}
                usage = msg.get("usage") or {}
                if not usage:
                    continue
                rate = price_for(msg.get("model", ""))
                cell = spend[(repo, when.replace(minute=0, second=0, microsecond=0))]
                for field, idx in FIELDS:
                    tok = usage.get(field, 0) or 0
                    # Share is measured in COST, not tokens: cache-read tokens outnumber
                    # output tokens ~100:1 but are priced 50x cheaper, so a token-share
                    # column reads 99% everywhere and says nothing.
                    cell["cost_micro"] += tok * rate[idx]
                    if idx in (0, 1, 2):
                        cell["ctx_micro"] += tok * rate[idx]
                    else:
                        cell["out_micro"] += tok * rate[idx]
                cell["msgs"] += 1
    return spend


def collect_commits(repos, since):
    """(repo, hour) -> commit count, for commits on ANY branch."""
    commits = collections.Counter()
    for repo in repos:
        path = os.path.join(HOME, repo)
        if not os.path.isdir(os.path.join(path, ".git")):
            continue
        try:
            out = subprocess.run(
                ["git", "-C", path, "log", "--all", "--no-merges",
                 "--since", since.strftime("%Y-%m-%d %H:%M"),
                 "--date=format:%Y-%m-%d %H", "--format=%ad"],
                capture_output=True, text=True, timeout=30,
            ).stdout
        except (OSError, subprocess.SubprocessError):
            continue
        for stamp in out.split("\n"):
            if not stamp.strip():
                continue
            try:
                hour = dt.datetime.strptime(stamp.strip(), "%Y-%m-%d %H").astimezone()
            except ValueError:
                continue
            commits[(repo, hour)] += 1
    return commits


def main():
    ap = argparse.ArgumentParser(description="Correlate token spend against durable artifacts.")
    ap.add_argument("--since", help="local time, e.g. '2026-07-25 05:00' (default: 48h ago)")
    ap.add_argument("--repo", action="append", help="limit to this repo (repeatable)")
    ap.add_argument("--waste-floor", type=float, default=2.0,
                    help="only flag a zero-commit hour above this $ (default 2.00)")
    ap.add_argument("--grace", type=int, default=1, metavar="H",
                    help="hours of slack before calling an hour barren — work started at 07:50 "
                         "usually commits at 08:10, and bucket boundaries must not invent waste "
                         "(default 1)")
    args = ap.parse_args()

    since = (dt.datetime.strptime(args.since, "%Y-%m-%d %H:%M").astimezone()
             if args.since else dt.datetime.now().astimezone() - dt.timedelta(hours=48))

    spend = collect_spend(since)
    if args.repo:
        spend = {k: v for k, v in spend.items() if k[0] in args.repo}
    if not spend:
        print(f"no session spend recorded since {since:%Y-%m-%d %H:%M}")
        return

    commits = collect_commits({repo for repo, _ in spend}, since)

    print(f"BURN LEDGER — since {since:%Y-%m-%d %H:%M}   (list-price estimate, see --help)\n")
    print(f"{'hour':<9} {'repo':<18} {'$est':>7} {'commits':>8} {'ctx$%':>6}  flag")
    total = zero = 0.0
    per_repo = collections.defaultdict(lambda: [0.0, 0, 0.0])
    for (repo, hour), cell in sorted(spend.items(), key=lambda kv: (kv[0][1], kv[0][0])):
        cost = cell["cost_micro"] / 1e6
        landed = commits[(repo, hour)]
        # Grace: a commit any time in [hour, hour+grace] redeems the hour that produced it.
        redeemed = any(commits[(repo, hour + dt.timedelta(hours=n))]
                       for n in range(args.grace + 1))
        ctx_share = 100.0 * cell["ctx_micro"] / max(1.0, cell["cost_micro"])
        total += cost
        barren = not redeemed and cost >= args.waste_floor
        if barren:
            zero += cost
        per_repo[repo][0] += cost
        per_repo[repo][1] += landed
        if barren:
            per_repo[repo][2] += cost
        print(f"{hour:%m-%d %H}  {repo:<18} {cost:7.2f} {landed:8d} {ctx_share:5.0f}%  "
              f"{'← spent, nothing landed' if barren else ''}")

    print(f"\n{'':<9} {'REPO TOTALS':<18} {'$est':>7} {'commits':>8} {'$ w/ no commit':>16}")
    for repo, (cost, landed, waste) in sorted(per_repo.items(), key=lambda kv: -kv[1][0]):
        print(f"{'':<9} {repo:<18} {cost:7.2f} {landed:8d} {waste:16.2f}")

    pct = 100.0 * zero / total if total else 0.0
    print(f"\n  spent ${total:.2f} · ${zero:.2f} of it ({pct:.0f}%) in hours that produced no commit")
    print("  a zero-commit hour is a question, not a verdict — see the HONEST LIMITS in --help")


if __name__ == "__main__":
    main()
