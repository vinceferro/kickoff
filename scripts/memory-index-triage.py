#!/usr/bin/env python3
"""memory-index-triage — which always-loaded index entries have EARNED their place?

READ-ONLY BY CONSTRUCTION: this script opens nothing for writing. It reports what a
usage-driven index WOULD demote so a human can judge it before anything moves.

The always-loaded index is a per-session context tax paid on every turn by every fact,
whether or not that fact is ever used. The retrieval hook, meanwhile, reads the per-fact
FILES and skips the index entirely (memory-retrieval/INTEGRATE.md), so a fact demoted out
of the index is NOT forgotten — it still surfaces when a query matches it. That asymmetry
is what makes demotion cheap and a size budget the wrong governor.

What it will NOT demote, and why the exceptions matter more than the rule:

  PINNED    metadata.type in {user, feedback} — how the operator wants to be worked with,
            plus anything carrying `pin: true`. "Hasn't come up lately" is not "safe to
            forget" for a standing instruction; these are exactly the facts whose absence
            is silent and expensive.
  CONSUMER  the index is not only read by the session — scripts grep it. memory-orphan-check
            greps it for LIVE PROJECT NAMES as standalone words, so demoting a line that
            carries one blinds that check (observed live 2026-08-09: compacting the hooks
            took 3/3 live projects to INVISIBLE at boot). Any entry naming a live project is
            load-bearing for a consumer regardless of its own retrieval count.
  NEW       younger than --new-days: a fact written last week has not had a fair chance to
            be retrieved, so a zero count says nothing about it.
  AGE?      age could not be established from a TRUSTED source, so "old enough to judge"
            is unproven and demotion fails closed. mtime is NOT a creation date here: a bulk
            move rewrote 131 of 186 files to one identical timestamp (observed 2026-08-09),
            which would have silently exempted the whole corpus as "NEW" had that move landed
            a fortnight later. Git's add-date is authoritative where the file is tracked;
            memory/private/ is gitignored, so those have no trusted age at all.

Usage:
  memory-index-triage.py [--repo DIR] [--min-hits N] [--new-days N] [--json]
"""
import argparse, collections, glob, json, os, re, subprocess, sys, time

PTR = re.compile(r'^\s*- \[(?P<title>[^\]]+)\]\((?P<path>[^)]+)\)\s*(?:—|--)?\s*(?P<hook>.*)$')
FM_TYPE = re.compile(r'^\s*type:\s*(\S+)\s*$', re.M)
FM_PIN = re.compile(r'^\s*pin:\s*(true|yes)\s*$', re.M | re.I)


def frontmatter(path):
    """The WHOLE `---` block, never a fixed byte window.

    A single-line `description:` in this corpus runs past 1000 chars, which pushes `metadata.type`
    outside any fixed prefix — the first cut of this script read [:800] and reported the most-
    surfaced memory in the corpus as untyped. Harmless for a `reference`, but a long-described
    `feedback` fact would have read as untyped, lost its PINNED protection, and become demotable:
    the exact outcome the PINNED class exists to prevent. Read the block, not a guess at its size.
    """
    try:
        with open(path, encoding='utf-8') as fh:
            if fh.readline().strip() != '---':
                return ''
            out = []
            for line in fh:
                if line.strip() == '---':
                    return ''.join(out)
                out.append(line)
    except OSError:
        pass
    return ''


def live_projects(home):
    """Repos with a .git and recent commits — the names memory-orphan-check looks for."""
    names = set()
    for d in glob.glob(os.path.join(home, '*')):
        if os.path.isdir(os.path.join(d, '.git')):
            names.add(os.path.basename(d))
        # a workspace root holds sibling repos one level down
        for sub in glob.glob(os.path.join(d, '*')):
            if os.path.isdir(os.path.join(sub, '.git')):
                names.add(os.path.basename(sub))
    return names


def git_add_dates(repo):
    """{repo-relative path: unix ts of the commit that ADDED it}. One pass, oldest wins.

    This is the only TRUSTED age signal available: mtime reflects whatever last touched the
    file (a bulk move, a reformat), not when the fact was written.

    Known limit, deliberately not chased: without --follow a RENAME reads as an add, so a fact
    moved by the public/private split dates from the move, not from when it was written. That
    UNDERSTATES age — and understating age can only push an entry toward NEW (exempt), never
    toward DEMOTE. The error direction is fail-safe, which is why one batch pass beats 186
    per-file --follow calls here.
    """
    out = {}
    try:
        p = subprocess.run(
            ['git', '-C', repo, 'log', '--diff-filter=A', '--reverse',
             '--format=%at', '--name-only', '--', 'memory'],
            capture_output=True, text=True, timeout=60)
        if p.returncode != 0:
            return out
        ts = None
        for line in p.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            if line.isdigit():
                ts = int(line)
            elif ts is not None:
                out.setdefault(line, ts)      # --reverse ⇒ first sighting is the add
    except (OSError, subprocess.SubprocessError):
        pass
    return out


def names_a_project(hook, projects):
    for n in projects:
        if re.search(r'(^|[^A-Za-z0-9_-])' + re.escape(n) + r'([^A-Za-z0-9_-]|$)', hook):
            return n
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', default='.')
    ap.add_argument('--min-hits', type=int, default=1,
                    help="demote candidates are entries surfaced FEWER than this many times (default 1 = never)")
    ap.add_argument('--new-days', type=int, default=14,
                    help="facts younger than this are exempt — no fair usage history yet")
    ap.add_argument('--json', action='store_true')
    a = ap.parse_args()

    repo = os.path.abspath(a.repo)
    index = os.path.join(repo, 'memory', 'MEMORY.md')
    logp = os.path.join(repo, 'memory-retrieval', 'retrieval-log.jsonl')
    for p in (index, logp):
        if not os.path.exists(p):
            print(f"missing: {p}", file=sys.stderr)
            return 2

    hits, first_ts, last_ts = collections.Counter(), None, None
    turns = 0
    with open(logp, encoding='utf-8') as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except ValueError:
                continue
            turns += 1
            first_ts = first_ts or r.get('ts')
            last_ts = r.get('ts') or last_ts
            for s in r.get('surfaced') or []:
                if s.get('slug'):
                    hits[s['slug']] += 1

    projects = live_projects(os.path.dirname(repo))
    added = git_add_dates(repo)
    now, rows = time.time(), []
    for i, line in enumerate(open(index, encoding='utf-8').read().splitlines(), 1):
        if not line.lstrip().startswith('- ['):
            continue
        m = PTR.match(line)
        if not m:
            continue
        path = m['path']
        slug = os.path.basename(path)[:-3] if path.endswith('.md') else os.path.basename(path)
        fp = os.path.join(repo, 'memory', path)
        head = frontmatter(fp)
        ftype = (FM_TYPE.search(head).group(1) if FM_TYPE.search(head) else '(none)')
        pinned_fm = bool(FM_PIN.search(head))
        gts = added.get(os.path.join('memory', path))
        age_days = (now - gts) / 86400 if gts else None      # None ⇒ no TRUSTED age
        proj = names_a_project(m['hook'], projects)
        n = hits.get(slug, 0)

        if ftype in ('user', 'feedback') or pinned_fm:
            cls = 'PINNED'
        elif proj:
            cls = 'CONSUMER'
        elif age_days is None:
            cls = 'AGE?'                                     # fail closed: never demote blind
        elif age_days < a.new_days:
            cls = 'NEW'
        elif n >= a.min_hits:
            cls = 'KEEP'
        else:
            cls = 'DEMOTE'
        rows.append(dict(line=i, slug=slug, type=ftype, hits=n, cls=cls,
                         project=proj, age_days=None if age_days is None else round(age_days, 1),
                         bytes=len(line) + 1, missing=not os.path.exists(fp)))

    if a.json:
        print(json.dumps(dict(turns=turns, window=[first_ts, last_ts], rows=rows), indent=1))
        return 0

    by = collections.Counter(r['cls'] for r in rows)
    dem = [r for r in rows if r['cls'] == 'DEMOTE']
    idx_bytes = os.path.getsize(index)
    saved = sum(r['bytes'] for r in dem)

    print(f"index   : {index}")
    print(f"window  : {(first_ts or '?')[:10]} → {(last_ts or '?')[:10]}  ({turns} logged turns)")
    print(f"entries : {len(rows)}   " + "  ".join(f"{k}={by[k]}" for k in
          ('PINNED', 'CONSUMER', 'NEW', 'AGE?', 'KEEP', 'DEMOTE') if by[k]))
    print(f"demote  : {len(dem)} entries = {saved:,} bytes off a {idx_bytes:,}-byte index "
          f"({saved * 100 // idx_bytes if idx_bytes else 0}%)")
    miss = [r for r in rows if r['missing']]
    if miss:
        print(f"⚠ {len(miss)} index entr(ies) point at a MISSING file: " +
              ", ".join(r['slug'] for r in miss[:5]))
    print()
    print("DEMOTE candidates — file stays on disk and still surfaces via the retrieval hook:")
    for r in sorted(dem, key=lambda r: (r['type'], r['slug'])):
        print(f"  [{r['type']:9s}] {r['slug']}  (age {r['age_days']}d)")
    print()
    print("NOT demoted, by reason:")
    for k, why in (('PINNED', 'operator-facing (user/feedback) or pin:true — usage is not the test'),
                   ('CONSUMER', 'names a live project; memory-orphan-check greps the index for these'),
                   ('NEW', f'younger than {a.new_days}d — no fair usage history yet'),
                   ('AGE?', 'no TRUSTED age (untracked by git); mtime is not a creation date, so fail closed')):
        if by[k]:
            print(f"  {by[k]:3d}  {k:9s} {why}")
    print()
    print("READ-ONLY: nothing was modified. Surfaced-count is 'was retrieved', not 'was useful'.")
    return 0


sys.exit(main())
