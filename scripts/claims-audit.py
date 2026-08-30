#!/usr/bin/env python3
"""claims-audit — flag done-words in a tracker that carry no evidence.

    python3 scripts/claims-audit.py [FILE] [--lines N] [--from-bottom] [--report]

THE FAILURE THIS EXISTS TO PREVENT (2026-08-27, memory: a-checkpoint-is-not-done-
until-the-remote-moved): a batch was built, reviewed, committed, and written into
TRACKER.md as "pushed to origin/brownfield-devex". The push had never run; the
next box pulled a tree without the fix and re-derived a root cause that was
sitting on a disk, unpushed. The tracker rendered the CLAIM ("pushed") with the
same weight it would render evidence — and nothing at the report layer ever
asked the claim to show its papers. That is the over-claim taxonomy's L5/L6
(unevidenced claims entering operator-visible state), and this lint is the
consumer-side check for it: read what the OPERATOR reads (the tracker text) and
flag delivery/done verbs that carry no verifiable pointer.

WHO CONSUMES THIS: the coordinator, immediately before relaying a done-report
upward ("done" lines get quoted at the operator, so they are the exact surface a
confident lie rides). It is also intended to be wired into crew charters as a
pre-relay step — that wiring is done SEPARATELY by the coordinator; this script
deliberately installs no hooks and edits no charters itself.

A LINT, NOT A PARSER. Its bias is deliberate: false positives are acceptable (a
human sees the flags and shrugs), false negatives on blatant cases are not. A
line with a done-word is EXEMPT if it (or its bullet block) carries evidence:

  * a SHA                   (6f9c065a, 4af81ac7d…) — ≥8 hex chars containing at
                              least one letter; a pointer git can re-verify. A
                              pure-decimal run ("build 12345678") is a build
                              number, not a SHA
  * a slash-path with a file extension
                              (docs/briefs/x.md, scripts/foo.sh) — a pointer you
                              can open; `origin/branchname` has no extension and
                              does NOT count — the motivating incident itself
                              said "pushed to origin/brownfield-devex", and a
                              ref is a claimant's word, not a pointer
  * a command+result fence   (a ``` block with a command line and output)
  * an honest label          (unverified/claimed/draft/pending/planned…) —
                              saying what you DON'T have is the behavior we want
  * a date-qualified pointer (2026-08-27 plus a backticked artifact)

WINDOW: this org's TRACKER.md is newest-at-top, so the default scan is the TOP
N lines (--lines, default 80) — the freshest claims sit at the top, not the
bottom. --from-bottom restores a newest-N scan for oldest-wins files.

Exit 0: "N claims, all evidenced" · Exit 1: flagged lines, numbered, with the
done-word named · Exit 2: bad invocation. --report is advisory (always exit 0,
for running places a red must not block).
"""
import argparse
import re
import sys

DONE_WORDS = re.compile(
    r"\b(done|shipped|verified|pushed|green|landed|fixed|pass|passes|passed|complete|completed|deployed|merged|works)\b",
    re.IGNORECASE,
)
SHA = re.compile(r"(?<![0-9a-fA-F])[0-9a-fA-F]{7,40}(?![0-9a-fA-F])")
HONEST_LABEL = re.compile(
    r"\b(unverified|unproven|claimed|draft|pending|planned|todo|not yet)\b",
    re.IGNORECASE,
)
DATE = re.compile(r"\d{4}-\d{2}-\d{2}")
BACKTICK = re.compile(r"`[^`]+`")
COMMAND_LINE = re.compile(
    r"^\s*(\$ |(git|python3?|bash|sh|curl|npm|pnpm|yarn|node|make|docker|npx|pip3?)\s)"
)

BULLET = re.compile(r"^\s*([-*•]|\d+\.)\s")
HEADING = re.compile(r"^#{1,6}\s")


def sha_evidence(line):
    """A hex run that can plausibly be a git SHA: at least 8 hex chars AND at
    least one letter — a decimal-only run is a build number or a count, never
    a commit pointer."""
    for m in SHA.finditer(line):
        tok = m.group(0)
        if len(tok) >= 8 and re.search(r"[a-fA-F]", tok):
            return True
    return False


def path_evidence(line):
    """A slash-path with a file extension — something you could `open`
    (scripts/x.sh, docs/y.md). Refs (origin/main, origin/brownfield-devex)
    carry no extension and are deliberately NOT paths."""
    for m in re.finditer(r"[^\s`\"()\[\]]+/[^\s`\"()\[\],]+", line):
        tok = m.group(0).rstrip(".,;:")
        if re.search(r"\.[A-Za-z][A-Za-z0-9]*$", tok):
            return True
    return False


def line_markers(line):
    return bool(
        sha_evidence(line)
        or path_evidence(line)
        or HONEST_LABEL.search(line)
        or (DATE.search(line) and BACKTICK.search(line))
    )


def classify(lines):
    """Per line: (in_fence, is_claim, has_evidence, fence_result_here).
    Fence contents are never claims; a command+result fence inside a block is
    evidence for the whole block."""
    in_fence = [False] * len(lines)
    fence_result = [False] * len(lines)
    i = 0
    while i < len(lines):
        if lines[i].lstrip().startswith("```"):
            j = i + 1
            body = []
            while j < len(lines) and not lines[j].lstrip().startswith("```"):
                body.append(lines[j])
                j += 1
            has_cmd = any(COMMAND_LINE.search(b) for b in body)
            is_result = has_cmd and len([b for b in body if b.strip()]) >= 2
            for k in range(i, min(j + 1, len(lines))):
                in_fence[k] = True
                fence_result[k] = is_result
            i = j + 1
        else:
            i += 1
    claims, evidence = [], []
    for idx, line in enumerate(lines):
        # Headings are structure, not claims — "## Done" would fire on every run
        # and train the reader to ignore the flags (a check that cries wolf).
        claims.append(
            (not in_fence[idx])
            and not HEADING.match(line)
            and bool(DONE_WORDS.search(line))
        )
        evidence.append(line_markers(line) or fence_result[idx])
    return claims, evidence, in_fence


def block_range(lines, idx):
    """The bullet block a line belongs to. A bullet HEADER owns everything below
    it until the next bullet/heading/blank; a CONTINUATION line belongs to the
    header above it. Headings terminate blocks and are never included (a heading
    is not a claim)."""
    lo = hi = idx
    if not BULLET.match(lines[idx]):
        while lo > 0 and lines[lo - 1].strip():
            if HEADING.match(lines[lo - 1]):
                break
            lo -= 1
            if BULLET.match(lines[lo]):
                break  # our own bullet header: include it, stop here
    while (
        hi < len(lines) - 1
        and lines[hi + 1].strip()
        and not BULLET.match(lines[hi + 1])
        and not HEADING.match(lines[hi + 1])
    ):
        hi += 1
    return lo, hi


def audit(path, n_lines, from_bottom=False):
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError as exc:
        print("claims-audit: cannot read %s: %s" % (path, exc), file=sys.stderr)
        return 2, 0, 0
    # Newest-at-top trackers land their freshest claims at the TOP: the default
    # window is the first n_lines. --from-bottom scans the newest n_lines for
    # oldest-wins files.
    if from_bottom:
        window = range(max(0, len(lines) - n_lines), len(lines))
    else:
        window = range(0, min(n_lines, len(lines)))
    claims, evidence, in_fence = classify(lines)
    flags = []
    total = 0
    for idx in window:
        if not claims[idx]:
            continue
        total += 1
        lo, hi = block_range(lines, idx)
        if not any(evidence[k] for k in range(lo, hi + 1)):
            words = sorted({m.group(0).lower() for m in DONE_WORDS.finditer(lines[idx])})
            flags.append((idx + 1, words, lines[idx].strip()))
    return 0 if not flags else 1, total, flags


def main(argv=None):
    ap = argparse.ArgumentParser(add_help=True, description="flag unevidenced done-words in a tracker")
    ap.add_argument("file", nargs="?", default="TRACKER.md")
    ap.add_argument("--lines", type=int, default=80,
                    help="how many lines to scan — the TOP N by default (newest-at-top "
                    "trackers); see --from-bottom (default 80)")
    ap.add_argument("--from-bottom", action="store_true",
                    help="scan the NEWEST N lines instead of the top N (oldest-wins files)")
    ap.add_argument("--report", action="store_true", help="advisory: print flags but always exit 0")
    args = ap.parse_args(argv)

    scope = "newest" if args.from_bottom else "top"
    rc, total, flags = audit(args.file, args.lines, from_bottom=args.from_bottom)
    if rc == 2:
        return 2
    if flags:
        for lineno, words, text in flags:
            print("L%-4d [%s] %s" % (lineno, ",".join(words), text[:100]))
        print(
            "\n%d of %d done-word claim(s) carry no evidence marker "
            "(SHA / path / command+result fence / honest label / date-qualified pointer)."
            % (len(flags), total)
        )
        print("Add the evidence, or downgrade the verb to what you actually have.")
        if args.report:
            print("(advisory --report: exit 0)")
            return 0
        return 1
    if total == 0:
        print(
            "0 done-word claims in the %s %d lines of %s — nothing to audit. "
            "(If you expected claims, check the file, the section you landed in, "
            "and the --lines/--from-bottom window.)"
            % (scope, args.lines, args.file)
        )
        return 0
    print("%d claims, all evidenced (%s %d lines of %s)" % (total, scope, args.lines, args.file))
    return 0


if __name__ == "__main__":
    sys.exit(main())
