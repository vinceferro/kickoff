#!/usr/bin/env python3
"""crew-probe.py — read + validate an EXISTING repo's agent crew (the restraint teeth).

kickoff's brownfield /adopt must MESH with a repo's existing crew, never impose its own
shape. The failure that kills adoption is OVER-PROPOSING — suggesting a new specialist for
a domain the crew already owns. This tool makes that restraint decision MECHANICAL:

  map               enumerate .claude/agents/*.md → JSON [{name,description,tools,path}]
  coverage-sources  ENUMERATE the coverage-establishing sources PRESENT in the repo (CLAUDE.md /
                    AGENTS.md / skills dirs / charter bodies) so the /adopt session READS them
                    before judging coverage — `map`'s frontmatter view alone UNDER-counts
  validate-plan     the RESTRAINT GATE — fail (non-zero) if a gap-fill plan over-proposes
  brains-verdict    HAS THIS REPO BEEN GIVEN A MIND? exit 0 = yes, 1 = a gap (see below)

It writes NOTHING to the target (eject-neutral): map, coverage-sources, and validate-plan only READ.

Domains are FREE-FORM: the plan carries whatever domain strings the /adopt session inferred
from THAT repo. This tool validates INTERNAL consistency only — it deliberately has no fixed
domain vocabulary, because a canonical vocabulary would be the exact "impose our shape"
failure restraint exists to prevent.

stdlib-only (no PyYAML — the frontmatter parser below is tolerant + hand-rolled).

──────────────────────────────────────────────────────────────────────────────────────────
plan.json schema (the /adopt session authors this; documented here as the contract):

  {
    "domains":  ["auth", "billing", "notifications", "search"],  // free-form, inferred from the repo
    "coverage": { "auth": "auth-agent",                    // domain -> owning agent name …
                  "billing": null,                         // … or null / absent = UNCOVERED
                  "notifications": "comms-agent",
                  "search": { "primary": "search-agent",   // … OR the LAYERED form: a primary owner
                              "contributors": ["build-agent", "review-agent"] } },  // + contributors
    "proposed": [ { "name": "billing-agent",               // new agent to ADD …
                    "domain": "billing" } ],               // … for the domain it fills
    "deferred": [ { "domain": "notifications",             // an UNCOVERED domain the session
                    "reason": "out of scope for now" } ]   // DELIBERATELY declined (restraint)
  }

  coverage[d] is OPTIONALLY an object { "primary": name|null, "contributors": [name, …] } instead of a
  bare string — so LAYERED ownership (build+review+test all touching one domain) is expressible. It is
  BACKWARD-COMPATIBLE + ADDITIVE: a plain string value behaves EXACTLY as before (that string IS the
  primary, no contributors). CHOICE: a domain is UNCOVERED iff its PRIMARY is null/absent/"" —
  contributors ALONE do NOT make a domain covered (a domain with contributors but no primary is still
  UNCOVERED). The coverage-honesty check verifies the primary AND every contributor exists in the crew.

  uncovered := { d in domains : primary-of(coverage[d]) is null / absent / "" }
               where primary-of(string)=that string, primary-of({primary,contributors})=primary

  The gate ASSERTS (each breach → a distinct stderr line + a non-zero exit; clean → exit 0):
    (a) every proposed[].domain is in uncovered   — never propose for an already-owned domain
    (b) uncovered == ∅  ⇒  proposed == ∅          — the ZERO-new thesis: a covered crew gets NOTHING
    (c) no proposed[].name collides with an existing crew name (checked against the REAL crew)
    (d) the proposed set is never the abstract {planner,builder,reviewer} trio imposed on a
        crew that already has >=1 agent — guards the specific "impose the default shape" failure
    (e) every deferred[].domain is in uncovered   — you can only DECLINE a domain no agent owns
    (f) every deferred[].reason is a non-empty string — the restraint judgment must be RECORDED
    (g) no domain appears in BOTH proposed and deferred — fill it or decline it, never both
  Plus a coverage-honesty check: a coverage claim naming agent A for domain d (as primary OR as a
  contributor) is a breach unless agent A actually exists in the real crew (a plan can't invent an owner).

  validate-plan accepts an OPTIONAL --json flag: it ALSO writes a structured result to stdout
  ({ "ok": bool, "exit": 0|1, "breaches": [{ "rule": "a"|…, "message": … }], "uncovered": [...],
  "advisory": {…} }) so an orchestrator gets the per-breach rule letters + a breadth advisory without
  scraping stderr prose. --json changes NOTHING about the exit code — it only adds the stdout report.

  The `deferred` field is OPTIONAL and BACKWARD-COMPATIBLE: a plan with NO `deferred` key behaves
  EXACTLY as before (rules e/f/g simply have nothing to check). It exists so a null-coverage domain
  the session deliberately chose NOT to fill is captured as a decision (the "saw it, declined it"
  restraint signal), not lost to prose.
──────────────────────────────────────────────────────────────────────────────────────────
coverage-sources output — the sources a repo uses to establish domain coverage BEYOND agent-charter
frontmatter (which `map` alone reads → it UNDER-counts → the session OVER-proposes). This verb only
ENUMERATES what is PRESENT (it never semantically parses — judging coverage stays the model's job):

  { "claude_md":   ["CLAUDE.md", "src/foo/CLAUDE.md"],       // root + nested CLAUDE.md, repo-relative
    "agents_md":   ["AGENTS.md"],                            // root + nested AGENTS.md
    "skills_dirs": [".claude/skills", "src/app/.agents/skills"],  // .claude/skills + .agents/skills dirs
    "charters_with_body": [ { "name": "engineer",            // charters whose BODY (beyond frontmatter)
                              "path": ".claude/agents/engineer.md",   // carries coverage the map can't see
                              "body_lines": 142 } ],
    "present": { "claude_md": true, "agents_md": false,      // ADDITIVE legibility summary: which source
                 "skills_dirs": true, "charters_with_body": true },  // KINDS are present at all …
    "notes":   ["no AGENTS.md found"] }                       // … + a note NAMING each absent kind, so a
                                                              // session cannot miss an absent source silently
──────────────────────────────────────────────────────────────────────────────────────────
"""
import sys
import os
import re
import json
import glob


# ── frontmatter parsing (tolerant, stdlib-only) ─────────────────────────────────────────────

def _extract_frontmatter(text):
    """Return the list of lines inside the leading '---' fenced block, or None if absent/unclosed."""
    lines = text.splitlines()
    i = 0
    # tolerate leading blank lines before the opening fence
    while i < len(lines) and lines[i].strip() == "":
        i += 1
    if i >= len(lines) or lines[i].strip() != "---":
        return None
    i += 1
    body = []
    closed = False
    while i < len(lines):
        if lines[i].strip() == "---":
            closed = True
            break
        body.append(lines[i])
        i += 1
    if not closed:
        return None
    return body


def _parse_frontmatter_kv(fm_lines):
    """Parse simple 'key: value' frontmatter tolerantly. Supports:
         key: scalar
         key: [a, b, c]        (inline YAML list)
         key:                  (then '- item' continuation lines = a YAML list)
       'tools' is captured best-effort as a str (CSV/scalar) or a list.
    """
    data = {}
    key = None
    for line in fm_lines:
        if line.strip() == "":
            continue
        # a YAML list item belonging to the current key
        m_item = re.match(r"^\s*-\s+(.*)$", line)
        if m_item and key is not None:
            val = m_item.group(1).strip().strip("\"'")
            if not isinstance(data.get(key), list):
                data[key] = []
            data[key].append(val)
            continue
        # a 'key: value' line
        m_kv = re.match(r"^\s*([A-Za-z_][\w-]*)\s*:\s?(.*)$", line)
        if m_kv:
            key = m_kv.group(1).strip()
            raw = m_kv.group(2).strip()
            if raw == "":
                data[key] = ""            # a list may follow on continuation lines
            elif raw.startswith("[") and raw.endswith("]"):
                inner = raw[1:-1]
                data[key] = [x.strip().strip("\"'") for x in inner.split(",") if x.strip()]
            else:
                data[key] = raw.strip("\"'")
            continue
        # anything else (stray prose, bad indentation) — ignore, never crash
    return data


def _agents_dir(repo):
    return os.path.join(repo, ".claude", "agents")


def map_crew(repo):
    """Return (agents, warnings). agents = [{name,description,tools,path}]. Malformed charters
    are SKIPPED with a warning — an adopt run must survive a messy real-world crew, never crash."""
    agents = []
    warnings = []
    adir = _agents_dir(repo)
    if not os.path.isdir(adir):
        return agents, warnings                 # missing dir → empty crew, not an error
    for path in sorted(glob.glob(os.path.join(adir, "*.md"))):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError as e:
            warnings.append("skipped %s: cannot read (%s)" % (path, e))
            continue
        if text.strip() == "":
            warnings.append("skipped %s: empty file" % path)
            continue
        fm = _extract_frontmatter(text)
        if fm is None:
            warnings.append("skipped %s: no frontmatter block" % path)
            continue
        kv = _parse_frontmatter_kv(fm)
        name = kv.get("name")
        if not name or (isinstance(name, str) and name.strip() == ""):
            warnings.append("skipped %s: frontmatter has no 'name'" % path)
            continue
        if not isinstance(name, str):
            warnings.append("skipped %s: 'name' is not a scalar" % path)
            continue
        model = kv.get("model", "")
        disallowed = kv.get("disallowedTools", [])
        agents.append({
            "name": name.strip(),
            "description": kv.get("description", "") if isinstance(kv.get("description", ""), str) else kv.get("description"),
            "tools": kv.get("tools", ""),
            # least-privilege can also be a deny-list (disallowedTools) or a model pin instead of a tools
            # allowlist — surface both so a `tools:""` charter isn't misread as no-restriction. Absent →
            # "" (model) / [] (disallowedTools), consistently.
            "model": model if isinstance(model, str) else "",
            "disallowedTools": disallowed if isinstance(disallowed, (list, str)) else [],
            "path": path,
        })
    return agents, warnings


# ── coverage-sources: enumerate the coverage-establishing sources PRESENT in the repo ─────────
#
# `map` reads only agent-charter FRONTMATTER, but a repo also establishes domain coverage via
# root/nested CLAUDE.md + AGENTS.md, a .agents/skills or .claude/skills dir, and the BODY of the
# charters. A session trusting `map` alone UNDER-counts coverage → OVER-proposes. This verb tells
# the session which sources to READ before judging — it ENUMERATES presence, never parses meaning.

_PRUNE_DIRS = {".git", "node_modules", "target", "dist", "build", "vendor"}
_WALK_MAX_DIRS = 20000       # hard cap on directories visited — a huge/hostile tree can't hang an adopt
_WALK_MAX_DEPTH = 12         # relative-depth cap below the repo root (bounds a pathological deep tree)


def _bounded_walk(root):
    """Yield (dirpath, dirnames, filenames) under root, pruning heavy/noise dirs, capped in depth
    AND total count. followlinks=False (the os.walk default) means a symlink cycle can't loop it."""
    visited = 0
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        visited += 1
        if visited > _WALK_MAX_DIRS:
            return
        rel = os.path.relpath(dirpath, root)
        depth = 0 if rel == os.curdir else rel.count(os.sep) + 1
        if depth >= _WALK_MAX_DEPTH:
            dirnames[:] = []            # don't descend past the depth cap
        # prune heavy/noise dirs in-place (os.walk honors the mutation)
        dirnames[:] = [d for d in dirnames if d not in _PRUNE_DIRS]
        yield dirpath, dirnames, filenames


def _body_line_count(text):
    """Count non-empty lines AFTER the leading frontmatter fence — the charter BODY that `map`'s
    frontmatter view never sees. No frontmatter block at all → the WHOLE file is that unseen body."""
    lines = text.splitlines()
    i = 0
    while i < len(lines) and lines[i].strip() == "":
        i += 1
    if i >= len(lines) or lines[i].strip() != "---":
        return sum(1 for ln in lines if ln.strip() != "")   # no frontmatter → all of it is body
    i += 1
    while i < len(lines) and lines[i].strip() != "---":
        i += 1
    if i >= len(lines):
        return 0                                             # unclosed fence → no delimited body
    i += 1                                                   # step past the closing fence
    return sum(1 for ln in lines[i:] if ln.strip() != "")


def _charters_with_body(repo):
    """For each .claude/agents/*.md, report {name,path,body_lines} IF it has body beyond the
    frontmatter — so the session reads the body (which can scope a domain IN or OUT), not just map."""
    out = []
    adir = _agents_dir(repo)
    if not os.path.isdir(adir):
        return out
    for path in sorted(glob.glob(os.path.join(adir, "*.md"))):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        body_lines = _body_line_count(text)
        if body_lines <= 0:
            continue
        name = None
        fm = _extract_frontmatter(text)
        if fm is not None:
            nm = _parse_frontmatter_kv(fm).get("name")
            if isinstance(nm, str) and nm.strip():
                name = nm.strip()
        if not name:
            name = os.path.splitext(os.path.basename(path))[0]
        out.append({"name": name, "path": os.path.relpath(path, repo), "body_lines": body_lines})
    return out


def coverage_sources(repo):
    """Return the enumerated coverage-source map. Robust: missing everything → empty arrays."""
    root = os.path.abspath(repo)
    claude_md, agents_md, skills_dirs = [], [], []
    if os.path.isdir(root):
        for dirpath, _dirnames, filenames in _bounded_walk(root):
            base = os.path.basename(dirpath)
            parent = os.path.basename(os.path.dirname(dirpath))
            if base == "skills" and parent in (".agents", ".claude"):
                skills_dirs.append(os.path.relpath(dirpath, root))
            for fn in filenames:
                if fn == "CLAUDE.md":
                    claude_md.append(os.path.relpath(os.path.join(dirpath, fn), root))
                elif fn == "AGENTS.md":
                    agents_md.append(os.path.relpath(os.path.join(dirpath, fn), root))
    charters = _charters_with_body(root)
    # ADDITIVE absent-source signal: a missing AGENTS.md / skills dir today yields a silent empty array —
    # a session can miss it. Make absence LEGIBLE with a present-boolean summary + a note naming each kind
    # that is absent, so "there is no AGENTS.md here" is a stated fact, not an easily-overlooked empty list.
    present = {
        "claude_md": bool(claude_md),
        "agents_md": bool(agents_md),
        "skills_dirs": bool(skills_dirs),
        "charters_with_body": bool(charters),
    }
    _labels = {
        "claude_md": "no CLAUDE.md found",
        "agents_md": "no AGENTS.md found",
        "skills_dirs": "no .agents/skills or .claude/skills dir found",
        "charters_with_body": "no charter carries a body beyond frontmatter",
    }
    notes = [_labels[k] for k in ("claude_md", "agents_md", "skills_dirs", "charters_with_body") if not present[k]]
    return {
        "claude_md": sorted(claude_md),
        "agents_md": sorted(agents_md),
        "skills_dirs": sorted(skills_dirs),
        "charters_with_body": charters,
        "present": present,
        "notes": notes,
    }


# ── verbs ───────────────────────────────────────────────────────────────────────────────────

def cmd_coverage_sources(repo):
    json.dump(coverage_sources(repo), sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


def cmd_map(repo):
    agents, warnings = map_crew(repo)
    for w in warnings:
        sys.stderr.write("crew-probe: warning: %s\n" % w)
    json.dump(agents, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


# ── brains-verdict — the SHARED predicate for "adoption landed a mind, not just plumbing" ────
#
# `kickoff adopt` wires every mechanical seam and then hands the one step that needs a mind to a
# printed sentence telling a human to type `/adopt`. Nothing enforced that the step ever happened,
# so six live adopters ran for weeks on the 76-byte CLAUDE.md that is nothing but the kickoff
# include — one of them through 35 memory-writing sessions with no .claude/agents/ at all.
#
# THIS is the one implementation of that question. Three consumers ask it (adopt, `kickoff verify`,
# preflight.sh) and each writing its own copy is precisely how the secret-keydir contract came to
# disagree with itself four ways inside one slice, every disagreement failing GREEN. It lives here
# because crew-probe.py is already the crew prober and already travels via core-manifest.txt — a
# predicate that does not travel is exit 127 on every adopter, which is silent and reads as fine.
#
# TWO INDEPENDENT HALVES, deliberately not collapsed into one boolean:
#   crew    — .claude/agents/ holds >=1 charter. Counted as FILES, not as successfully-parsed
#             charters: a malformed or frontmatter-less charter is still a crew someone authored,
#             and the restraint promise ("I run YOURS and add specialists only where a domain has
#             no owner") must never be broken by a parse failure. Fails toward "you have a crew".
#   charter — CLAUDE.md carries content beyond the <!-- kickoff:begin/end --> include block.
# A repo can have either without the other, and the fixes differ (author a crew vs. author a body),
# so the verdict reports them separately and the caller says only what is actually missing.
#
# AMBIGUITY FAILS TOWARD "PRESENT". An unterminated or hand-edited kickoff block leaves the whole
# file counted as body. This detector never blocks a boot, and a false alarm on a repo that HAS a
# real charter costs trust in every other thing the system says; a missed one is caught by the crew
# half, by verify, and by the operator's own eyes.

# The include block adopt writes. Mirrors _KICKOFF_BLOCK_RE in adopt-manifest.py (the eject-side
# stripper) in the two ways that bite: CRLF tolerance, and the (?!begin) guard so a stray operator
# `begin` marker cannot make one block swallow the real charter between them. It differs in ONE
# deliberate way — the leading newline is optional, because adopt writes the block at byte 0 when
# it CREATES CLAUDE.md (the exact shape the affected live adopters carry) and requiring \n misses it there.
_KICKOFF_BLOCK_RE = re.compile(
    r"(?:\A|\n)<!-- kickoff:begin\b(?:(?!<!-- kickoff:begin).)*?<!-- kickoff:end -->[ \t]*\r?\n?",
    re.DOTALL)


def charter_verdict(repo):
    """Return (state, detail) for the repo's root CLAUDE.md: 'missing' | 'bare' | 'body'."""
    path = os.path.join(repo, "CLAUDE.md")
    if not os.path.isfile(path):
        return "missing", "no CLAUDE.md at the repo root"
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as e:
        # Unreadable is not evidence of absence — say so and fail toward present.
        return "body", "CLAUDE.md unreadable (%s) — not judged" % e
    stripped = _KICKOFF_BLOCK_RE.sub("\n", text)
    body_lines = [ln for ln in stripped.splitlines() if ln.strip() != ""]
    if not body_lines:
        return "bare", "CLAUDE.md is the bare kickoff include — no charter body (%d bytes)" % len(text)
    return "body", "CLAUDE.md carries %d non-blank line(s) beyond the kickoff include" % len(body_lines)


def brains_verdict(repo):
    """Return the structured verdict dict. Writes NOTHING (eject-neutral, like every verb here)."""
    adir = _agents_dir(repo)
    charters = sorted(glob.glob(os.path.join(adir, "*.md"))) if os.path.isdir(adir) else []
    parsed, _warnings = map_crew(repo)
    ch_state, ch_detail = charter_verdict(repo)

    gaps = []
    if not charters:
        gaps.append("no domain crew — .claude/agents/ holds 0 charters, so no specialist owns any "
                    "domain of this repo")
    if ch_state == "bare":
        gaps.append("bare charter — %s" % ch_detail)
    elif ch_state == "missing":
        gaps.append("no charter — %s" % ch_detail)

    return {
        "ok": not gaps,
        "crew_charters": len(charters),
        "crew_parsed": len(parsed),
        "crew_names": [a.get("name") for a in parsed],
        "charter": ch_state,
        "charter_detail": ch_detail,
        "gaps": gaps,
    }


def cmd_brains_verdict(repo, json_out=False):
    v = brains_verdict(repo)
    if json_out:
        json.dump(v, sys.stdout, indent=2)
        sys.stdout.write("\n")
    elif v["ok"]:
        sys.stdout.write("brains: PRESENT — %d charter(s) in .claude/agents/ (%s); %s\n"
                         % (v["crew_charters"], ", ".join(n for n in v["crew_names"] if n) or "unparsed",
                            v["charter_detail"]))
    else:
        sys.stdout.write("brains: MISSING — %s\n" % "; ".join(v["gaps"]))
    return 0 if v["ok"] else 1


TRIO = {"planner", "builder", "reviewer"}


def _is_null(v):
    return v is None or (isinstance(v, str) and v.strip() == "")


# ── coverage-value helpers: a value is a STRING (the primary, back-compat) OR an object form
#    { "primary": name|null, "contributors": [name, …] }. These assume the value already passed the
#    shape guard below, so they never hit an unexpected type. ──────────────────────────────────────

def _coverage_primary(v):
    """The owning (primary) agent of a coverage value: a string form IS the primary; the object form's
    'primary' key. Returns a str or None (always hashable — never a dict/list into a set op)."""
    if isinstance(v, dict):
        return v.get("primary")
    return v


def _coverage_contributors(v):
    """The contributor names of a coverage value (object form only; the string form has none)."""
    if isinstance(v, dict):
        c = v.get("contributors", [])
        return c if isinstance(c, list) else []
    return []


def _coverage_shape_error(d, v):
    """Return a 'shape invalid' message if coverage value v is a malformed shape, else None. Allowed:
    null, a string, OR { "primary": string|null, "contributors": [string, …] }. Follows the existing
    element-type-guard pattern so a bad inner type is a CLEAN exit-2, never an unhashable-crash-as-exit-1."""
    if _is_null(v) or isinstance(v, str):
        return None
    if isinstance(v, dict):
        primary = v.get("primary")
        if not (_is_null(primary) or isinstance(primary, str)):
            return "coverage[%r].primary must be a string or null, got %r" % (d, primary)
        contribs = v.get("contributors", [])
        if contribs is None:
            contribs = []
        if not isinstance(contribs, list):
            return "coverage[%r].contributors must be a list of strings, got %r" % (d, contribs)
        for c in contribs:
            if not isinstance(c, str):
                return "coverage[%r].contributors entry must be a string, got %r" % (d, c)
        return None
    return "coverage[%r] must be a string, null, or {primary,contributors}, got %r" % (d, v)


def _breadth_advisory(proposed, crew_names):
    """A minimal, honest proposal-breadth summary (never gates the exit). See the call site for why the
    tool deliberately does NOT try to measure a domain's file footprint itself."""
    dom_counts = {}
    for p in proposed:
        dom_counts[p["domain"]] = dom_counts.get(p["domain"], 0) + 1
    multi = {d: c for d, c in dom_counts.items() if c > 1}
    est = []
    for p in proposed:
        hint = {}
        for k in ("est_files", "est_loc"):
            if isinstance(p.get(k), int) and not isinstance(p.get(k), bool):
                hint[k] = p[k]
        if hint:
            hint["name"] = p["name"]
            est.append(hint)
    adv = {
        "proposed_count": len(proposed),
        "crew_size": len(crew_names),
        "domains_multiply_proposed": multi,
    }
    if est:
        adv["est_hints"] = est
    return adv


def cmd_validate_plan(repo, plan_path, json_out=False):
    try:
        with open(plan_path, "r", encoding="utf-8") as fh:
            plan = json.load(fh)
    except (OSError, ValueError) as e:
        sys.stderr.write("crew-probe: cannot read plan %s: %s\n" % (plan_path, e))
        return 2
    if not isinstance(plan, dict):
        sys.stderr.write("crew-probe: plan must be a JSON object\n")
        return 2

    domains = plan.get("domains", []) or []
    coverage = plan.get("coverage", {}) or {}
    proposed = plan.get("proposed", []) or []

    if not isinstance(domains, list) or not isinstance(coverage, dict) or not isinstance(proposed, list):
        sys.stderr.write("crew-probe: plan shape invalid (domains=list, coverage=object, proposed=list)\n")
        return 2

    # Element-type shape validation. The containers are known-good above, but a machine-authored plan
    # can still nest a list/dict where a string belongs (e.g. coverage:{"auth":["agent-1"]}). Those must
    # be a CLEAN refusal — exit 2 (bad-usage), per the 0/1/2 = clean/breach/bad-usage contract — NOT a raw
    # `TypeError: unhashable type` traceback with exit 1 (indistinguishable from a legitimate restraint
    # BREACH). Guard element types here so no set/dict op below can ever hit an unhashable value.
    for d in domains:
        if not isinstance(d, str):
            sys.stderr.write("crew-probe: plan shape invalid: a 'domains' entry is not a string: %r\n" % (d,))
            return 2
    for d, owner in coverage.items():
        cov_err = _coverage_shape_error(d, owner)
        if cov_err is not None:
            sys.stderr.write("crew-probe: plan shape invalid: %s\n" % cov_err)
            return 2
    for p in proposed:
        if not isinstance(p, dict):
            sys.stderr.write("crew-probe: plan shape invalid: a 'proposed' entry is not an object: %r\n" % (p,))
            return 2
        pname = p.get("name")
        pdom = p.get("domain")
        if not isinstance(pname, str) or pname.strip() == "":
            sys.stderr.write("crew-probe: plan shape invalid: a 'proposed' entry has no string 'name': %r\n" % (p,))
            return 2
        if not isinstance(pdom, str) or pdom.strip() == "":
            sys.stderr.write("crew-probe: plan shape invalid: a 'proposed' entry has no string 'domain': %r\n" % (p,))
            return 2

    # 'deferred' (OPTIONAL): uncovered domains the session DELIBERATELY declined. Shape-guard it like
    # the fields above — a non-list, or a non-object entry, is a CLEAN exit-2 bad-usage refusal (never
    # an unhashable-crash-as-exit-1). A plan with NO 'deferred' key skips this entirely (back-compat).
    deferred = plan.get("deferred", []) or []
    if not isinstance(deferred, list):
        sys.stderr.write("crew-probe: plan shape invalid: 'deferred' must be a list\n")
        return 2
    for e in deferred:
        if not isinstance(e, dict):
            sys.stderr.write("crew-probe: plan shape invalid: a 'deferred' entry is not an object: %r\n" % (e,))
            return 2

    agents, warnings = map_crew(repo)
    for w in warnings:
        sys.stderr.write("crew-probe: warning: %s\n" % w)
    crew_names = {a["name"] for a in agents}

    # UNCOVERED := a domain whose PRIMARY owner is null/absent/"". Contributors ALONE do NOT cover a
    # domain (a domain with contributors but no primary is still UNCOVERED). _coverage_primary always
    # returns a str-or-None (hashable), so a dict coverage value can never hit this set op.
    uncovered = {d for d in domains if _is_null(_coverage_primary(coverage.get(d)))}

    # breaches: list of (rule, message). The message ALSO carries the human 'rule (x)' prefix (kept for the
    # stderr contract); the rule letter is surfaced structurally in the --json report. 'coverage' tags the
    # honesty breach (no rule letter, but a real breach). Nothing here changes the exit-code contract.
    breaches = []

    # coverage honesty: a claimed owner (PRIMARY or any CONTRIBUTOR) must actually be in the real crew
    for d, val in coverage.items():
        primary = _coverage_primary(val)
        if not _is_null(primary) and primary not in crew_names:
            breaches.append(("coverage",
                "coverage claims agent '%s' owns domain '%s', but no such agent exists in the crew" % (primary, d)))
        for c in _coverage_contributors(val):
            if isinstance(c, str) and c.strip() and c not in crew_names:
                breaches.append(("coverage",
                    "coverage lists contributor '%s' on domain '%s', but no such agent exists in the crew" % (c, d)))

    proposed_names = []
    for p in proposed:
        # p is a dict with non-empty string name/domain (validated in the shape pass above)
        pname = p["name"]
        pdom = p["domain"]
        proposed_names.append(pname)
        # (a) never propose for an already-owned (or unknown) domain
        if pdom not in uncovered:
            breaches.append(("a",
                "rule (a) OVER-PROPOSE: proposed agent '%s' targets domain '%s' which is NOT uncovered "
                "(uncovered=%s) — never propose for an already-owned domain" % (pname, pdom, sorted(uncovered))))
        # (c) no collision with an existing crew name
        if pname in crew_names:
            breaches.append(("c",
                "rule (c) COLLISION: proposed agent name '%s' already exists in the crew" % pname))

    # (b) the ZERO-new thesis: a fully-covered crew gets NOTHING
    if not uncovered and proposed:
        breaches.append(("b",
            "rule (b) ZERO-NEW: crew fully covers every domain (uncovered=∅) but the plan proposes "
            "%d new agent(s) — a covered crew must get nothing" % len(proposed)))

    # (d) never impose the abstract {planner,builder,reviewer} trio on a non-empty crew
    if crew_names and TRIO.issubset({n for n in proposed_names if n}):
        breaches.append(("d",
            "rule (d) IMPOSE-SHAPE: the plan proposes the abstract {planner,builder,reviewer} trio onto a "
            "crew that already has %d agent(s) — that is imposing our default shape, not meshing" % len(crew_names)))

    # (e/f/g) the DEFERRED restraint signal: an uncovered domain the session chose NOT to fill, captured
    # with a reason. ddom is checked isinstance-first so a non-string can never hit an unhashable set op.
    proposed_domains = {p["domain"] for p in proposed}      # p validated dict w/ string domain above
    for e in deferred:
        ddom = e.get("domain")
        dreason = e.get("reason")
        # (e) you can only DEFER a domain that is genuinely uncovered (no agent owns it)
        if not isinstance(ddom, str) or ddom.strip() == "" or ddom not in uncovered:
            breaches.append(("e",
                "rule (e) DEFER-UNCOVERED: deferred domain %r is not an UNCOVERED domain (uncovered=%s) — "
                "you can only decline a domain no agent owns" % (ddom, sorted(uncovered))))
            continue
        # (f) the restraint judgment must be RECORDED — a non-empty reason
        if not isinstance(dreason, str) or dreason.strip() == "":
            breaches.append(("f",
                "rule (f) DEFER-REASON: deferred domain '%s' has no non-empty 'reason' — the restraint "
                "decision must be recorded, not left blank" % ddom))
        # (g) a domain cannot be BOTH proposed and deferred — fill it or decline it, never both
        if ddom in proposed_domains:
            breaches.append(("g",
                "rule (g) DEFER-CONFLICT: domain '%s' appears in BOTH proposed and deferred — decide to "
                "fill it or decline it, never both" % ddom))

    # ── proposal-breadth ADVISORY (#6): a LIGHT, HONEST signal only. The tool CANNOT measure a free-form
    #    domain's true file footprint (that would need an invented file→domain scan — the exact "impose our
    #    vocabulary" failure), so it does NOT try. It surfaces only what it can see WITHOUT inventing meaning:
    #    the proposed count, the crew size, any domain targeted by >1 proposal (a possible over-split), and any
    #    optional est_files/est_loc hint the plan itself carried. This is ADVISORY — it NEVER affects the exit
    #    code (an advisory signal must not flip a clean 0 to a breach 1).
    advisory = _breadth_advisory(proposed, crew_names)

    exit_code = 1 if breaches else 0

    if breaches:
        for _rule, b in breaches:
            sys.stderr.write("crew-probe: BREACH: %s\n" % b)
    # a same-domain over-split is worth a NON-gating stderr note even without --json
    if advisory["domains_multiply_proposed"]:
        sys.stderr.write("crew-probe: ADVISORY: %d domain(s) targeted by >1 proposed agent (possible "
                         "over-split) — %s\n" % (len(advisory["domains_multiply_proposed"]),
                                                 sorted(advisory["domains_multiply_proposed"])))

    if json_out:
        result = {
            "ok": not breaches,
            "exit": exit_code,
            "breaches": [{"rule": r, "message": m} for r, m in breaches],
            "uncovered": sorted(uncovered),
            "advisory": advisory,
        }
        json.dump(result, sys.stdout, indent=2)
        sys.stdout.write("\n")

    return exit_code


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: crew-probe.py {map|coverage-sources|validate-plan|brains-verdict}"
                         " --repo <dir> [--plan <plan.json>] [--json]\n")
        return 2
    verb = argv[1]
    args = argv[2:]

    repo = None
    plan = None
    json_out = False
    i = 0
    while i < len(args):
        if args[i] == "--repo" and i + 1 < len(args):
            repo = args[i + 1]; i += 2
        elif args[i] == "--plan" and i + 1 < len(args):
            plan = args[i + 1]; i += 2
        elif args[i] == "--json":
            json_out = True; i += 1
        else:
            sys.stderr.write("crew-probe: unknown/incomplete arg: %s\n" % args[i])
            return 2

    if verb == "map":
        if not repo:
            sys.stderr.write("crew-probe: map requires --repo <dir>\n")
            return 2
        return cmd_map(repo)
    if verb == "coverage-sources":
        if not repo:
            sys.stderr.write("crew-probe: coverage-sources requires --repo <dir>\n")
            return 2
        return cmd_coverage_sources(repo)
    if verb == "validate-plan":
        if not repo or not plan:
            sys.stderr.write("crew-probe: validate-plan requires --repo <dir> --plan <plan.json>\n")
            return 2
        return cmd_validate_plan(repo, plan, json_out=json_out)
    if verb == "brains-verdict":
        if not repo:
            sys.stderr.write("crew-probe: brains-verdict requires --repo <dir>\n")
            return 2
        return cmd_brains_verdict(repo, json_out=json_out)

    sys.stderr.write("crew-probe: unknown verb '%s' "
                     "(want map|coverage-sources|validate-plan|brains-verdict)\n" % verb)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
