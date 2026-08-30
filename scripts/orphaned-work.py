#!/usr/bin/env python3
"""orphaned-work — find finished agent work whose session died before it landed.

THE FINDING THIS EXISTS FOR (2026-07-25/26). When a worker dies abruptly — an API/spend
limit, a supervisor refresh, a hard reset — the in-flight agent work looks lost. It is not.
Claude Code writes every subagent's transcript to ~/.claude/projects/<proj>/<session>/
subagents/ INCREMENTALLY, and a workflow additionally journals each agent's return value to
that run's journal.jsonl. None of that needs a hook, so none of it is lost to a SIGKILL, and
it lives under $HOME so it survives a reboot (unlike the /tmp task-output mirrors).

What IS lost is nobody reading it. The next session re-grounds from CLAUDE.md + memory +
TRACKER.md and has no idea six finished agents are sitting on disk. Measured on the real
2026-07-25 12:40 limit-kill: an adopter's housekeeping run had 6/6 agents complete and 116k chars
of results — including the final ranked apply-list — that were never read by anything.

So this is a READ tool, not a write tool. It reports what is recoverable and files it where
the next session actually looks.

    python3 scripts/orphaned-work.py                    # what is sitting unread
    python3 scripts/orphaned-work.py --why <run-id>     # per-agent: returned vs killed, and how
    python3 scripts/orphaned-work.py --dump <run-id>    # file it into .kickoff/checkpoints/<item>/

HONEST LIMITS:
  * "Orphaned" is a CANDIDATE, not a verdict. Liveness is inferred from the session
    transcript's mtime (a live session writes constantly) — a session thinking hard for longer
    than --live-window reads as dead. Erring that way is deliberate: over-reporting recoverable
    work costs a glance, under-reporting costs the work.
  * An agent killed mid-thought has NO journal result. Its partial transcript survives and is
    usually worth reading, but it is partial — no tool can recover a return value that was
    never produced.
  * "Never landed" is not provable from here. A run whose results the coordinator DID consume
    still appears; the tracker item it is filed under is what tells you.
"""
import argparse
import glob
import json
import os
import re
import sys
import time

PROJECTS = os.path.expanduser("~/.claude/projects")
HOME = os.path.expanduser("~")

# The dead agent names its own cause of death: a limit-killed agent's last assistant text IS
# the limit notice. Loose on purpose — this only LABELS a killed agent, it never gates recovery,
# so a vendor wording change costs a wrong label, never a lost transcript.
LIMIT_HINT = re.compile(r"(spend limit|usage limit|reached your .* limit|usage-credits)", re.I)


def repo_of(project_key):
    """A project key back to the repo it belongs to.

    Claude Code names a project directory after its absolute path with the separators
    turned into dashes, so the inverse is a prefix strip and a join. Returns None when
    the key does not live under $HOME — another machine's key, or a scratch project
    under /tmp — which the caller skips rather than guesses at.
    """
    prefix = "-" + HOME.strip("/").replace("/", "-") + "-"
    if not project_key.startswith(prefix):
        return None
    return os.path.join(HOME, project_key[len(prefix):])


def last_assistant_text(path):
    """Final assistant prose in a (possibly truncated) agent transcript."""
    text = ""
    try:
        with open(path, errors="replace") as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                content = (rec.get("message") or {}).get("content")
                if isinstance(content, list):
                    for block in content:
                        if block.get("type") == "text" and block.get("text", "").strip():
                            text = block["text"]
    except OSError:
        pass
    return text


def read_journal(path):
    """run journal -> (agent_id -> result string). Missing//malformed lines are skipped."""
    results = {}
    try:
        with open(path, errors="replace") as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if rec.get("type") == "result" and rec.get("agentId"):
                    value = rec.get("result")
                    results[rec["agentId"]] = value if isinstance(value, str) else json.dumps(value, indent=1)
    except OSError:
        pass
    return results


def scan(live_window_min):
    """Every workflow run on disk, newest first, with liveness of its owning session."""
    now = time.time()
    runs = []
    for journal in glob.glob(PROJECTS + "/*/*/subagents/workflows/*/journal.jsonl"):
        rundir = os.path.dirname(journal)
        parts = journal[len(PROJECTS) + 1:].split("/")
        project_key, session, run_id = parts[0], parts[1], parts[4]
        repo = repo_of(project_key)
        if repo is None:
            continue
        results = read_journal(journal)
        agents = sorted(glob.glob(rundir + "/agent-*.jsonl"))
        # A session writes its transcript on every turn; a quiet one is dead or wedged. This is
        # a heuristic and is labelled as one — see HONEST LIMITS.
        transcript = os.path.join(PROJECTS, project_key, session + ".jsonl")
        idle_min = (now - os.path.getmtime(transcript)) / 60 if os.path.exists(transcript) else None
        runs.append({
            "repo": repo,
            "name": os.path.basename(repo),
            "run": run_id,
            "dir": rundir,
            "mtime": os.path.getmtime(journal),
            "results": results,
            "agents": agents,
            "killed": [a for a in agents if os.path.basename(a)[6:-6] not in results],
            "chars": sum(len(v) for v in results.values()),
            "idle_min": idle_min,
            "live": idle_min is not None and idle_min < live_window_min,
        })
    runs.sort(key=lambda r: -r["mtime"])
    return runs


def find_run(runs, run_id):
    for run in runs:
        if run["run"] == run_id or run["run"].startswith(run_id):
            return run
    sys.exit("no run matching %r on disk (run with no arguments to list)" % run_id)


def slug(text, limit=48):
    out = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return out[:limit].strip("-") or "item"


def ledger_path(args):
    """Per-repo, beside the other .kickoff state — the boot check is --here-scoped, so each org
    owns its own ledger rather than sharing a box-wide one."""
    if args.ledger:
        return os.path.expanduser(args.ledger)
    return os.path.join(os.path.realpath(os.getcwd()), ".kickoff", "orphan-notified.json")


def load_ledger(path):
    """Fail OPEN: an unreadable ledger must never swallow a finding. Worst case we re-report
    something already seen, which is noise; the opposite is losing paid-for work silently."""
    try:
        with open(path) as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_ledger(path, data):
    """Bookkeeping failure must not fail the boot check — report and move on."""
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(data, fh, indent=2, sort_keys=True)
        os.replace(tmp, path)
        return True
    except OSError as exc:
        print("  (could not record what was shown: %s — it may be reported again)" % exc,
              file=sys.stderr)
        return False


def select(runs, args):
    """The one place the tier rules live, so --json and the human render can never drift apart."""
    cutoff = time.time() - args.days * 86400
    picked = [r for r in runs
              if r["mtime"] >= cutoff
              and (r["results"] or r["killed"])
              and (args.all or not r["live"])
              and (not args.repo or r["name"] in args.repo)]
    return [r for r in picked if r["killed"]], [r for r in picked if not r["killed"]]


def cmd_json(runs, args):
    """Machine-readable, for a sweep that mails each org its own findings.

    Emits the SAME two tiers the human render uses, via select(), and labels them — a consumer
    that treats a 'complete' run as an orphan would make exactly the over-claim this tool exists
    to avoid. Paths are deliberately absent: a sweep needs identity and volume, not another org's
    file layout."""
    interrupted, complete = select(runs, args)

    def rec(run, tier):
        return {"tier": tier, "repo": run["name"], "run": run["run"],
                "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(run["mtime"])),
                "mtime": int(run["mtime"]), "returned": len(run["results"]),
                "killed": len(run["killed"]), "chars": run["chars"], "live": bool(run["live"])}

    print(json.dumps({
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "days": args.days,
        "runs": [rec(r, "died_mid_run") for r in interrupted]
                + [rec(r, "all_returned") for r in complete],
    }, indent=2))


def cmd_list(runs, args):
    """Two tiers, because they carry very different confidence.

    A run with KILLED agents lost its session mid-flight — so the coordinator never reached the
    synthesis step, and the siblings that DID return almost certainly went unused. That is a
    strong orphan signal and it leads.

    A run where every agent returned is only a CANDIDATE: its session probably consumed it and
    moved on. Claiming those as "unread" would be the over-claim this tool exists to avoid, so
    they are listed second and labelled as unknown."""
    interrupted, complete = select(runs, args)
    picked = interrupted + complete

    # --quiet is the boot-check contract: silence on a clean box. Only the DIED MID-RUN tier is
    # worth a fresh worker's attention — the "probably consumed" tier is browsing, not a finding.
    #
    # NOTIFY-ONCE, and why it earns a wider window. This check used to be run with --days 2, not
    # because two days is the interesting horizon but because it had no memory: a wider window
    # re-printed the same finding at every single boot until it aged out, which trains a worker
    # to skim past it. With a ledger the window can be weeks, so a run that died while its org
    # was mid-session is still caught — that is the hole that let 168k chars of returned output
    # sit unread in one org for twelve days while its boot check ran clean every time.
    #
    # A run is NEVER silently dropped. Once shown, it collapses to a one-line tail rather than
    # disappearing: a finding shown once and then hidden would be worse than the re-nag, because
    # a session can die between the print and the acting on it.
    if args.quiet:
        if not interrupted:
            return
        lpath = ledger_path(args)
        seen = {} if args.replay else load_ledger(lpath)
        fresh = [r for r in interrupted if r["run"] not in seen]
        # The tail only counts runs that can ACTUALLY still be acted on. A run where every agent
        # was killed returned nothing, so --dump refuses it by design — carrying it as "still
        # unsalvaged" would be a permanent nag about work that can never be closed, which is how
        # a real signal gets tuned out. It is shown once, in full, and then it is done.
        stale = [r for r in interrupted
                 if r["run"] in seen and not seen[r["run"]].get("handled") and r["chars"] > 0]

        if fresh:
            print("ORPHANED WORK — %d run(s) died mid-flight; returned output is on disk and likely "
                  "unused:" % len(fresh))
            for run in fresh:
                print("  %s  %s  %s — %d returned (%s chars), %d killed"
                      % (time.strftime("%m-%d %H:%M", time.localtime(run["mtime"])), run["name"],
                         run["run"], len(run["results"]), f"{run['chars']:,}", len(run["killed"])))
            print("  salvage: python3 <core>/scripts/orphaned-work.py --dump <run> --item '<tracker item>'")
        if stale:
            chars = sum(r["chars"] for r in stale)
            print("  (+%d older finding(s) already shown and still unsalvaged, %s chars — "
                  "--replay to see them again)" % (len(stale), f"{chars:,}"))
        if fresh and not args.replay:
            now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            for r in fresh:
                seen[r["run"]] = {"shown_at": now, "chars": r["chars"], "handled": False}
            save_ledger(lpath, seen)
        return

    print("ORPHANED WORK — agent output on disk whose session is no longer running\n")
    if not picked:
        print("  (nothing in the last %d days outside a live session)" % args.days)
        return

    def row(run):
        when = time.strftime("%m-%d %H:%M", time.localtime(run["mtime"]))
        note = "session LIVE" if run["live"] else ""
        print(f"{when:<12} {run['name']:<16} {run['run']:<20} {len(run['results']):>5} "
              f"{len(run['killed']):>7} {run['chars']:>9,}  {note}")

    header = f"{'when':<12} {'repo':<16} {'run':<20} {'ret':>5} {'killed':>7} {'chars':>9}"
    if interrupted:
        print("── DIED MID-RUN — the session never reached synthesis, so the returned")
        print("   siblings below almost certainly went unused:\n")
        print(header)
        for run in interrupted:
            row(run)
        print()
    if complete:
        print("── every agent returned — probably consumed by its session before it ended.")
        print("   Listed for completeness; whether it landed is not knowable from here:\n")
        print(header)
        for run in complete:
            row(run)
        print()

    salvage = sum(r["chars"] for r in interrupted)
    lost = sum(len(r["killed"]) for r in interrupted)
    print(f"  {len(interrupted)} interrupted run(s): {salvage:,} chars returned and likely unused, "
          f"{lost} agent(s) killed mid-thought")
    print("  --why <run> for per-agent fate · --dump <run> to file it into .kickoff/checkpoints/")
    if not args.all:
        print("  (runs owned by a still-live session are hidden — pass --all to include them)")


def cmd_why(run, args):
    print(f"{run['run']}  in {run['name']}   ({len(run['agents'])} agents, "
          f"{len(run['results'])} returned, {len(run['killed'])} killed)\n")
    for path in run["agents"]:
        agent_id = os.path.basename(path)[6:-6]
        size_kb = os.path.getsize(path) // 1024
        if agent_id in run["results"]:
            fate = "RETURNED %6d chars" % len(run["results"][agent_id])
        else:
            tail = last_assistant_text(path)
            fate = "KILLED (spend/usage limit)" if LIMIT_HINT.search(tail) else "KILLED"
        print(f"  {agent_id[:16]:<18} {size_kb:>5}KB transcript   {fate}")
    if run["killed"]:
        print("\n  A killed agent produced no return value — but its transcript above holds every")
        print("  tool call and finding it had made. Read it; do not re-run it blind.")


def cmd_dump(run, args):
    if not run["results"]:
        sys.exit("run %s has no returned agent output to file (all %d agents were killed)"
                 % (run["run"], len(run["killed"])))
    repo = run["repo"]
    item = args.item
    pointer = os.path.join(repo, ".kickoff", "active-item")
    if item is None and os.path.exists(pointer):
        with open(pointer, errors="replace") as fh:
            item = fh.readline().strip()
    label = item or "(unfiled — no tracker item was active)"
    outdir = os.path.join(repo, ".kickoff", "checkpoints", slug(item) if item else "_unfiled")
    os.makedirs(outdir, exist_ok=True)

    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(run["mtime"]))
    written = []
    for n, (agent_id, body) in enumerate(sorted(run["results"].items()), 1):
        path = os.path.join(outdir, f"{stamp}-{run['run']}-{n:02d}.md")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("---\n")
            # The VERBATIM item text is the join key, not the slug: a re-worded tracker item
            # changes the directory but must never orphan the content inside it.
            fh.write("item: %s\n" % label.replace("\n", " "))
            fh.write("run: %s\nagent: %s\nrecovered_from: %s\n" % (run["run"], agent_id, run["dir"]))
            fh.write("agent_returned_at: %s\n" % time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(run["mtime"])))
            fh.write("---\n\n")
            fh.write(body)
        written.append(path)
    print("filed %d recovered agent result(s) under %s" % (len(written), outdir))
    for path in written:
        print("  %s  (%d chars)" % (os.path.relpath(path, repo), os.path.getsize(path)))
    if run["killed"]:
        print("\n%d agent(s) in this run were killed and returned nothing — their partial "
              "transcripts stay in\n%s (use --why to see which)." % (len(run["killed"]), run["dir"]))
    if not item:
        print("\nNo tracker item was active, so this landed in _unfiled/. Re-run with "
              "--item '<tracker item text>' to file it, or set .kickoff/active-item.")

    # Salvaging IS the resolution, so retire it from the boot check's tail. Without this the
    # "already shown and still unsalvaged" line would keep counting work that has been dealt
    # with — a nag that outlives its cause is how a real signal gets tuned out.
    lpath = ledger_path(args)
    seen = load_ledger(lpath)
    entry = seen.get(run["run"], {})
    entry.update({"handled": True, "handled_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                  "filed_to": os.path.relpath(outdir, repo)})
    seen[run["run"]] = entry
    save_ledger(lpath, seen)


def main():
    ap = argparse.ArgumentParser(description="Find agent work whose session died before it landed.")
    ap.add_argument("--repo", action="append", help="limit to this repo name (repeatable)")
    ap.add_argument("--why", metavar="RUN", help="per-agent fate for one run (returned vs killed)")
    ap.add_argument("--dump", metavar="RUN", help="file a run's returned output into .kickoff/checkpoints/")
    ap.add_argument("--item", help="tracker item text to file under (default: .kickoff/active-item)")
    ap.add_argument("--all", action="store_true", help="include runs owned by a still-live session")
    ap.add_argument("--days", type=int, default=7, metavar="D",
                    help="how far back to look (default 7)")
    ap.add_argument("--here", action="store_true",
                    help="scope to the repo containing the cwd (what a boot check wants)")
    ap.add_argument("--quiet", action="store_true",
                    help="print NOTHING unless a run died mid-flight — for the re-ground boot check, "
                         "where a clean box must cost the worker zero tokens and zero noise")
    ap.add_argument("--live-window", type=int, default=20, metavar="MIN",
                    help="a session quiet longer than this reads as dead (default 20)")
    ap.add_argument("--json", action="store_true",
                    help="machine-readable findings for a sweep (same two tiers, labelled)")
    ap.add_argument("--ledger", metavar="PATH",
                    help="notify-once ledger (default: <cwd repo>/.kickoff/orphan-notified.json). "
                         "What lets --quiet look back weeks without re-nagging every boot.")
    ap.add_argument("--replay", action="store_true",
                    help="with --quiet, show every finding again and record nothing")
    args = ap.parse_args()

    if args.here:
        # The boot-check shape: the worker's cwd IS its repo, and it only cares about its own.
        args.repo = (args.repo or []) + [os.path.basename(os.path.realpath(os.getcwd()))]
    if not os.path.isdir(PROJECTS):
        # A boot check must never fail loudly on a box that simply has no history yet.
        # --json has the same contract as --quiet here: a consumer parses stdout, so an
        # empty box must still yield a VALID empty document, never prose it would choke on.
        if args.json:
            print(json.dumps({"generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                              "days": args.days, "runs": []}, indent=2))
        elif not args.quiet:
            print("no %s on this box — nothing to scan" % PROJECTS)
        return
    runs = scan(args.live_window)
    if args.why:
        cmd_why(find_run(runs, args.why), args)
    elif args.dump:
        cmd_dump(find_run(runs, args.dump), args)
    elif args.json:
        cmd_json(runs, args)
    else:
        cmd_list(runs, args)


if __name__ == "__main__":
    main()
