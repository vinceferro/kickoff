#!/usr/bin/env python3
"""
adopt-manifest.py — the writer + verifier for .kickoff/adopt-manifest.json.

THE KEYSTONE (brownfield-devex design §2.1). Every touch `kickoff adopt` makes to an
adopter's repo is recorded here — one file that is simultaneously the EJECT spine (how
every change is reversed exactly), the UPGRADE-safety record (preflight #8 hashes seams
against this), and the audit answer to "what did kickoff do to my repo?". Eject, preflight,
and the shims all inherit their correctness from this file's discipline, so it is strict by
construction.

Delegated to from the bash `kickoff` CLI, the same idiom as mission-control/mc-update.py:
bash does the mechanical wiring, this Python owns the JSON + sha256 + the credential rule.

── THE SCHEMA (design §2.1; schema_version 2 adds machine_entries — §5 THE PLUGIN) ────
  { "schema_version": 2,
    "entries": [ { "path": "<repo-relative>",
                   "action": "created | modified | block-appended | json-merged | hook-installed",
                   "class":  "seam | seeded-instance | live-config",  # live-config: a file kickoff CREATED
                                                                      #   that the live system legitimately
                                                                      #   mutates (an accepted permission
                                                                      #   prompt rewrites .claude/settings.json)
                                                                      #   — reversed like `created`, NOT
                                                                      #   whole-file-hashed by preflight #8,
                                                                      #   NOT kept-by-default, NOT seam-synced.
                   "source": "core-v0.2 | authored-for-repo",
                   "sha256_before_edit": "<hash of the file BEFORE kickoff touched it>",
                   "sha256_at_write":    "<hash of the file as kickoff LEFT it>",
                   "original_encoding":  "base64",
                   "original": "<verbatim pre-edit bytes, base64>",
                   "jq_paths": [ "<JSON path touched>", ... ] } ],
    "machine_entries": [ { "kind": "plugin",              # v2, LOCKED decision #2 — a PARALLEL array,
                           "marketplace": "kickoff-local", #   NOT a new entries[] action/path (keeps the
                           "plugin": "kickoff",            #   repo-relative escape guards intact).
                           "scope": "project",            #   The user-global marketplace+enable touch;
                           "marketplace_source": "<machine clone-path>",  # a MACHINE path (outside the repo)
                           "source": "core-v0.2" } ] }    #   Carries NO bytes/secret. Reversed by bash eject.

── THE FIVE ACTIONS × their reversal discipline (Fix 2) ──────────────────────────────
  created         no `original` (reversed by DELETE); records sha256_at_write only.
  modified        ┐ the general in-place edit + its two structured specializations. ALL
  block-appended  ┼ THREE store the verbatim pre-edit bytes in `original` so eject can
  json-merged     ┘ BYTE-restore the file EXACTLY (never a re-derived reconstruction);
                    each records BOTH sha256_before_edit and sha256_at_write.
  hook-installed  the settings.local.json case — that file carries LIVE SECRETS (Telegram
                  bot token, PostHog key; design §2.1 credential note + Fix 1). So this
                  action stores NO `original` bytes and NO hash — ONLY the jq-paths touched
                  (reversed by a surgical jq-path removal at eject, never a byte-restore).
                  The secret bytes MUST NEVER enter the manifest; this code REFUSES to store
                  `original` for hook-installed and never even opens the target file.

── USAGE ──────────────────────────────────────────────────────────────────────────────
  adopt-manifest.py record --path .kickoff/bin/mc         --action created        --class seam --source core-v0.2
  adopt-manifest.py record --path CLAUDE.md               --action block-appended --class seam --source core-v0.2 --original-from <pre-edit-copy>
  adopt-manifest.py record --path .claude/settings.json   --action json-merged    --class seam --source core-v0.2 --original-from <pre-edit-copy>
  adopt-manifest.py record --path README.md               --action modified       --class seam --source core-v0.2 --original-from <pre-edit-copy>
  adopt-manifest.py record --path .claude/settings.local.json --action hook-installed --class seam --source core-v0.2 --jq-path '.hooks.UserPromptSubmit[2]'
  adopt-manifest.py verify           # recompute every recorded hash; non-zero exit on ANY mismatch/missing
  adopt-manifest.py show             # render the manifest (metadata only — NEVER echoes stored bytes)

REPO RESOLUTION: --repo <dir> wins, else $REPO_DIR (the engine's universal convention —
preflight.sh / kickoff resolve it identically), else the repo THIS script lives in. The
manifest is always <repo>/.kickoff/adopt-manifest.json.
"""

import argparse
import base64
import contextlib
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

SCHEMA_VERSION = 2

ACTIONS = ("created", "modified", "block-appended", "json-merged", "hook-installed")
CLASSES = ("seam", "seeded-instance", "live-config")

# ── MACHINE ENTRIES (schema v2 — §5 THE PLUGIN, LOCKED decision #2) ───────────────────
# A PARALLEL top-level `machine_entries[]` array records the USER-GLOBAL / machine-level touch the
# plugin flow makes — deliberately NOT a new `entries[]` action and NOT a repo-relative path, so it
# never goes through (or weakens) the adversarially-hardened repo-relative escape guards that
# entries[]/preflight-#8 depend on. `cmd_reverse` (Python) stays over entries[] ONLY; machine-level
# reversal lives in the bash `cmd_eject` (design reconciliation #4). Each entry carries ONLY
# metadata — marketplace / plugin / scope / the machine clone-path / a provenance tag — and NEVER
# any file bytes or secret (the credential invariant extends here: a machine entry stores no bytes).
MACHINE_SCOPES = ("project", "user", "local")

# Secret-bearing files may ONLY be recorded as `hook-installed` (jq-paths, never stored bytes). This
# PATH-based backstop to the per-action credential rule in cmd_record guarantees no secret from a
# DESIGNATED secret-bearing basename can reach the manifest (design §2.1 + Fix 1). SCOPE (honest —
# corrected after the §5 adversarial review): the guarantee is exactly that — no secret from these
# DESIGNATED basenames. It is NOT the absolute "a secret cannot reach the manifest by ANY code path".
# `.claude/settings.json` is deemed non-secret BY DESIGN (LOCKED decision #3 — Claude Code steers
# secrets to settings.local.json / apiKeyHelper) and is recorded `json-merged`, which base64-stores
# the WHOLE file (byte-restore needs the bytes, so storing only a jq-subtree is not a free fix). If an
# operator DOES place a secret in settings.json (an `env` block, an inline MCP token), it is therefore
# stored AT-REST in this manifest. Mitigations keep that at LOW: (i) NO live leak — `show`/`verify`
# print byte-COUNTS only, never bytes, so nothing travels to a log/Telegram/the mesh; (ii) the
# manifest is chmod 0600; (iii) settings.json is itself co-equally un-gitignored (only settings.local
# .json is), so a secret there already sits in an equally-exposed same-box file. NOTE: adopt now
# scaffolds `.kickoff/.gitignore` (a created/seam, from scripts/templates/kickoff.gitignore — see
# gen-gitignore) which ignores `adopt-manifest.json`, so the manifest never reaches origin (design §G).
SECRET_BEARING_BASENAMES = ("settings.local.json",)

# The three actions whose reversal is a byte-restore → MUST carry stored `original` bytes.
ORIGINAL_ACTIONS = ("modified", "block-appended", "json-merged")

# ── SEAM SHIMS (design §1.4) ─────────────────────────────────────────────────────────
# A shim is a generated SEAM file: a thin, repo-relative, MACHINE-PATH-FREE wrapper that
# sources .kickoff/instance.env (which carries KICKOFF_CORE_DIR — the machine path stays
# there, gitignored) and execs the PINNED engine code. Because the content embeds NO machine
# path, every adopter's shim is byte-identical → a stable hash the manifest pins and preflight
# #8 checks. `gen-shim` writes + records it; `sync-seams` regenerates it from the new tag on
# pull. A MISSING engine yields a CLEAR message + non-zero exit, never a raw bash error.
SHIM_DIR = ".kickoff/bin"

_MC_SHIM = '''#!/usr/bin/env bash
# kickoff SEAM shim: mc → mission-control/mc-update.py  (GENERATED — DO NOT EDIT).
# Regenerated from the pinned tag on `kickoff pull`; hand-edits are REFUSED by seam-sync and
# flagged by preflight #8. Machine-path-free (KICKOFF_CORE_DIR comes from .kickoff/instance.env)
# so every adopter's copy is byte-identical. See .kickoff/README.
_here="$(cd "$(dirname "$0")" && pwd)"
# G10c — pin REPO_DIR to THIS shim's OWN repo BEFORE sourcing instance.env, so the env's
# ${REPO_DIR:-$PWD}-anchored data-path defaults resolve into THIS repo — never an ambient
# REPO_DIR=<other repo> or a foreign $PWD. Explicit per-var overrides in instance.env still win.
export REPO_DIR="$(cd "$_here/../.." && pwd)"
[ -f "$_here/../instance.env" ] && . "$_here/../instance.env"
_engine="${KICKOFF_CORE_DIR:-}/mission-control/mc-update.py"
if [ ! -f "$_engine" ]; then
  printf 'kickoff engine not present — see .kickoff/README\\n' >&2
  exit 1
fi
exec python3 "$_engine" "$@"
'''

_SCAN_SECRETS_SHIM = '''#!/usr/bin/env bash
# kickoff SEAM shim: scan-secrets → scripts/scan-secrets.sh  (GENERATED — DO NOT EDIT).
# Regenerated from the pinned tag on `kickoff pull`; hand-edits are REFUSED by seam-sync and
# flagged by preflight #8. Machine-path-free (KICKOFF_CORE_DIR comes from .kickoff/instance.env)
# so every adopter's copy is byte-identical. See .kickoff/README.
_here="$(cd "$(dirname "$0")" && pwd)"
# G10c — pin REPO_DIR to THIS shim's OWN repo BEFORE sourcing instance.env, so the env's
# ${REPO_DIR:-$PWD}-anchored data-path defaults resolve into THIS repo — never an ambient
# REPO_DIR=<other repo> or a foreign $PWD. Explicit per-var overrides in instance.env still win.
export REPO_DIR="$(cd "$_here/../.." && pwd)"
[ -f "$_here/../instance.env" ] && . "$_here/../instance.env"
_engine="${KICKOFF_CORE_DIR:-}/scripts/scan-secrets.sh"
if [ ! -f "$_engine" ]; then
  printf 'kickoff engine not present — run `kickoff pull` (see .kickoff/README)\\n' >&2
  exit 1
fi
exec "$_engine" "$@"
'''

_SCAN_STRUCTURE_SHIM = '''#!/usr/bin/env bash
# kickoff SEAM shim: scan-structure → scripts/scan-structure.sh  (GENERATED — DO NOT EDIT).
# Regenerated from the pinned tag on `kickoff pull`; hand-edits are REFUSED by seam-sync and
# flagged by preflight #8. Machine-path-free (KICKOFF_CORE_DIR comes from .kickoff/instance.env)
# so every adopter's copy is byte-identical. See .kickoff/README.
_here="$(cd "$(dirname "$0")" && pwd)"
# G10c — pin REPO_DIR to THIS shim's OWN repo BEFORE sourcing instance.env, so the env's
# ${REPO_DIR:-$PWD}-anchored data-path defaults resolve into THIS repo — never an ambient
# REPO_DIR=<other repo> or a foreign $PWD. Explicit per-var overrides in instance.env still win.
export REPO_DIR="$(cd "$_here/../.." && pwd)"
[ -f "$_here/../instance.env" ] && . "$_here/../instance.env"
_engine="${KICKOFF_CORE_DIR:-}/scripts/scan-structure.sh"
if [ ! -f "$_engine" ]; then
  printf 'kickoff engine not present — run `kickoff pull` (see .kickoff/README)\\n' >&2
  exit 1
fi
exec "$_engine" "$@"
'''

# name → canonical content. The registry both `gen-shim` (write one) and `sync-seams`
# (regenerate on pull) read, so a shim is defined in exactly ONE place.
SHIM_TEMPLATES = {
    "mc": _MC_SHIM,
    "scan-secrets": _SCAN_SECRETS_SHIM,
    "scan-structure": _SCAN_STRUCTURE_SHIM,
}

# ── FILE SEAMS (design §2.3 Fix 5 — the split-charter regen) ──────────────────────────
# A FILE seam is a generated SEAM whose canonical bytes live in a TEMPLATE FILE beside this
# script (scripts/templates/<name>), NOT a Python string — so it TRAVELS + PINS via
# core-manifest.txt and each pinned tag defines its OWN version of the template. `sync-seams`
# regenerates it on pull exactly like a shim; preflight #8 hashes it (it is created/seam). The
# split-charter pattern: `.kickoff/KICKOFF.md` is the pulled coordinator charter (a seam), and it
# `@import`s the adopter-owned `.kickoff/KICKOFF.local.md` (a seeded-instance, never regenerated).
# path (repo-relative) → template filename under scripts/templates/.
FILE_SEAM_TEMPLATES = {
    ".kickoff/KICKOFF.md": "KICKOFF.md",
    ".kickoff/.gitignore": "kickoff.gitignore",
    ".kickoff/README": "kickoff-README.md",
}
_TEMPLATE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "templates")

# The KICKOFF.local.md stub gen-charter seeds ONCE (seeded-instance, adopter-owned). It is
# intentionally an inline stub, NOT a pinned template: it is never regenerated on pull and is
# kept on eject, so it must not evolve per-tag — the adopter fills it in for THEIR repo.
_KICKOFF_LOCAL_STUB = '''# KICKOFF.local — this repo's coordinator overrides (adopter-owned)

This file is YOURS. `kickoff pull` NEVER regenerates it (it is a seeded-instance, not a seam),
and eject keeps it by default. Put everything specific to THIS repo here; the pulled
`.kickoff/KICKOFF.md` coordinator charter `@import`s it.

## This repo
- **What it is:** <one line — what this product/repo does>
- **Domains + their specialists:** <e.g. api → api-agent, web → web-agent> (author via `/adopt`)
- **The operator:** <working style — ask-only-taste vs. confirm-each; tone; batch vs. stream>

## Conventions that override the pulled charter
- <a repo-specific rule the coordinator must follow>

## Guardrails specific to this repo
- <e.g. "never touch the billing tables"; "prod deploys are human-scheduled only">
'''


def seam_path_for_shim(name):
    """The repo-relative path a shim lands at: .kickoff/bin/<name>."""
    return SHIM_DIR + "/" + name


def _read_file_seam_template(fname):
    """Read a file-seam template from scripts/templates/<fname> (relative to __file__). FATAL if
    absent — a pinned tag missing its own template is a broken core, not a silent skip."""
    p = os.path.join(_TEMPLATE_DIR, fname)
    try:
        with open(p, "r", encoding="utf-8") as f:
            return f.read()
    except OSError as e:
        die("FATAL — file-seam template missing: %s (%s) — is this a complete core checkout?" % (p, e))


def seam_template_for(path):
    """The canonical bytes a manifest-listed SEAM path regenerates from, or None if that path has
    no whole-file template here (e.g. a block-appended seam, regenerated block-wise elsewhere).
    Two kinds are whole-file-regenerable: .kickoff/bin/<name> SHIMS (inline strings) and FILE
    SEAMS whose bytes live in scripts/templates/<name> (e.g. .kickoff/KICKOFF.md)."""
    norm = path.replace("\\", "/")
    prefix = SHIM_DIR + "/"
    if norm.startswith(prefix):
        name = norm[len(prefix):]
        if "/" not in name and name in SHIM_TEMPLATES:
            return SHIM_TEMPLATES[name]
    if norm in FILE_SEAM_TEMPLATES:
        return _read_file_seam_template(FILE_SEAM_TEMPLATES[norm])
    return None


def die(msg, code=2):
    sys.stderr.write("adopt-manifest: %s\n" % msg)
    sys.exit(code)


def resolve_repo_dir(args):
    """The adopter repo whose .kickoff/adopt-manifest.json we read/write. --repo wins, then
    $REPO_DIR (engine convention), then the tree this script lives in (parent of scripts/).
    An explicit override lets the selftest point it at a mktemp fixture."""
    rd = getattr(args, "repo", None) or os.environ.get("REPO_DIR")
    if not rd:
        rd = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    rd = os.path.abspath(rd)
    if not os.path.isdir(rd):
        die("FATAL — repo dir does not exist: %s (set --repo or $REPO_DIR)" % rd)
    return rd


def manifest_path(repo):
    return os.path.join(repo, ".kickoff", "adopt-manifest.json")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def repo_relative(path):
    """Reject an absolute or ../-escaping --path (mirrors preflight #6's escape guard): the
    manifest is a repo-scoped receipt — it must never reference a file OUTSIDE the repo.
    Returns the NORMALIZED path (LOW-a): validating norm but storing the RAW spelling let a
    recorded `.kickoff/../TRACKER.md` read as under-.kickoff/ downstream (eject step 6b would
    "relocate" TRACKER.md out of the repo) — the manifest must carry one canonical spelling."""
    if os.path.isabs(path):
        die("--path must be repo-relative, not absolute: %s" % path)
    norm = os.path.normpath(path)
    if norm == ".." or norm.startswith(".." + os.sep) or norm.startswith("../"):
        die("--path escapes the repo (../): %s" % path)
    return norm


def load_manifest(mpath):
    """A missing manifest is a fresh, empty receipt. A PRESENT-but-malformed one is FATAL —
    never silently skeleton over it (the same fail-loud posture mc-update.py takes on a bad
    state file), because that would erase the eject spine."""
    if not os.path.exists(mpath):
        return {"schema_version": SCHEMA_VERSION, "entries": []}
    try:
        with open(mpath, "r", encoding="utf-8") as f:
            m = json.load(f)
    except (OSError, ValueError) as e:
        die("FATAL — cannot read manifest %s: %s" % (mpath, e))
    if not isinstance(m, dict) or not isinstance(m.get("entries"), list):
        die("FATAL — malformed manifest (no entries[] array): %s" % mpath)
    # v2 machine_entries[] (§5 THE PLUGIN): a v1 manifest has none → migrate FREE by defaulting it
    # to []; a PRESENT-but-non-list machine_entries is malformed (fail-loud, never skeleton over it).
    if "machine_entries" in m and not isinstance(m["machine_entries"], list):
        die("FATAL — malformed manifest (machine_entries is not an array): %s" % mpath)
    m.setdefault("machine_entries", [])
    m.setdefault("schema_version", SCHEMA_VERSION)
    return m


def _open_secure_tmp(abs_path, suffix=".kickoff-eject.tmp"):
    """Create a temp file beside abs_path for an atomic write — SYMLINK-SAFE (the re-review's Fix-B
    bypass). tempfile.mkstemp gives a RANDOM name opened O_CREAT|O_EXCL at mode 0600 — O_EXCL fails
    on ANY pre-existing dirent (a planted symlink included, so it is never followed) and the random
    name is unpredictable, so an attacker cannot pre-create or pre-symlink a PREDICTABLE
    `<file>.kickoff-eject.tmp` sibling to
    redirect the write OUT of the repo (the old `abs_path + '.tmp'` + plain os.open followed such a
    symlink and exfiltrated the neighbouring secrets). dir = abs_path's parent, which every caller
    _real_within-contains first; mkstemp itself never follows a symlink. Returns (fd, tmp_path). The
    default `.kickoff-eject.tmp` suffix keeps eject tmps inside --verify's residue scan + the
    crash-safety unlink."""
    d = os.path.dirname(abs_path) or "."
    return tempfile.mkstemp(prefix=os.path.basename(abs_path) + ".", suffix=suffix, dir=d)


def save_manifest(mpath, manifest):
    """Atomic tmp + os.replace under 0600, exactly as mc-update.py's save() — a crash mid-write
    can never leave a half-written manifest (a corrupt eject spine)."""
    os.makedirs(os.path.dirname(mpath), exist_ok=True)
    fd, tmp = _open_secure_tmp(mpath, suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, mpath)
    os.chmod(mpath, 0o600)


def cmd_record(args):
    repo = resolve_repo_dir(args)
    mpath = manifest_path(repo)

    action, klass = args.action, args.klass
    if action not in ACTIONS:
        die("unknown action '%s' — must be one of: %s" % (action, ", ".join(ACTIONS)))
    if klass not in CLASSES:
        die("unknown class '%s' — must be one of: %s" % (klass, ", ".join(CLASSES)))
    if not args.source:
        die("--source is required (e.g. core-v0.2 or authored-for-repo)")

    path = repo_relative(args.path)
    abs_path = os.path.join(repo, path)

    # ── PATH-BASED CREDENTIAL BACKSTOP (defense-in-depth over the per-action rule below) ──
    # A secret-bearing file may ONLY be recorded as `hook-installed` (jq-paths, no bytes). Refuse
    # here — BEFORE the byte-restore branch could base64 its live-credential bytes — so a caller
    # that picks the "natural" json-merged/modified action for settings.local.json cannot leak.
    # normpath first (LOW-b, the reassert-file posture): a crafted '.claude/settings.local.json/.'
    # (or trailing slash) has raw basename ''/'.' and would slip a bare-basename check.
    if os.path.basename(os.path.normpath(path)) in SECRET_BEARING_BASENAMES and action != "hook-installed":
        die("REFUSING — '%s' is secret-bearing; record it ONLY as action 'hook-installed' "
            "(jq-paths, no stored bytes), never '%s' (which would base64 its live-credential "
            "bytes into the manifest). Credential rule: design §2.1 + Fix 1." % (path, action))

    entry = {"path": path, "action": action, "class": klass, "source": args.source}

    if action == "hook-installed":
        # ── THE CREDENTIAL RULE (design §2.1 + Fix 1) — the whole point of the keystone ──
        # The target is settings.local.json, which carries LIVE SECRETS. Store ONLY the
        # jq-paths touched: NO original bytes, NO hash, and we never even OPEN the file, so
        # a secret cannot leak into the manifest by any code path here. REFUSE outright if a
        # caller passes --original-from for this action.
        if args.original_from is not None:
            die("REFUSING — action 'hook-installed' must NOT store original bytes: its target "
                "carries live credentials (design §2.1). Record --jq-path only, drop --original-from.")
        if not args.jq_path:
            die("action 'hook-installed' requires at least one --jq-path (the exact JSON path(s) "
                "touched, so eject can surgically jq-remove them)")
        # Fix A — a CONTENT HASH per hook, aligned 1:1 with --jq-path. eject identifies the hook to
        # remove by this hash (never a substring or a bare index), so a reorder / a non-"kickoff"
        # command / an operator's own colliding hook are all handled correctly. The hash is of the
        # CANONICAL json (`jq -S -c '<jq_path>' file | sha256sum`) of the exact hook entry, computed
        # by the CALLER — record still NEVER opens settings.local.json (a hash is not bytes, so the
        # credential rule is preserved). The 1:1 count is mandatory: a positional-only fallback is
        # exactly what review defeated.
        hook_shas = list(args.hook_sha256 or [])
        if len(hook_shas) != len(args.jq_path):
            die("action 'hook-installed' requires one --hook-sha256 per --jq-path (got %d jq-path(s) "
                "and %d hook-sha256(s)). Each is the sha256 of `jq -S -c '<jq_path>' <settings.local.json>` "
                "— the canonical json of the exact hook entry, hashed by the caller (never the file's "
                "bytes)." % (len(args.jq_path), len(hook_shas)))
        entry["jq_paths"] = list(args.jq_path)
        entry["hook_sha256s"] = hook_shas

    elif action == "created":
        # Reversed by deletion → no original bytes; record only the hash of what we created.
        if args.original_from is not None:
            die("action 'created' must NOT carry original bytes (reversed by delete) — drop --original-from")
        if args.jq_path:
            die("action 'created' does not take --jq-path")
        if args.hook_sha256:
            die("action 'created' does not take --hook-sha256 (that is the hook-installed case)")
        if not os.path.isfile(abs_path):
            die("created file not found at %s — record AFTER creating it" % abs_path)
        entry["sha256_at_write"] = sha256_file(abs_path)

    else:  # modified / block-appended / json-merged
        # Byte-restore reversal → the verbatim pre-edit bytes are MANDATORY. The caller saved
        # them to a file BEFORE editing; we base64 them (safe for arbitrary/binary/CRLF bytes)
        # so eject writes them back EXACTLY, and record both the before- and after-edit hashes.
        if args.jq_path:
            die("action '%s' does not take --jq-path (that is the hook-installed case)" % action)
        if args.hook_sha256:
            die("action '%s' does not take --hook-sha256 (that is the hook-installed case)" % action)
        if args.original_from is None:
            die("action '%s' REQUIRES --original-from <pre-edit-copy> — the verbatim pre-edit "
                "bytes eject byte-restores. Save the file's bytes BEFORE editing, then record." % action)
        if not os.path.isfile(args.original_from):
            die("--original-from not found: %s" % args.original_from)
        if not os.path.isfile(abs_path):
            die("target file not found at %s — edit it, THEN record (sha256_at_write is the post-edit hash)" % abs_path)
        with open(args.original_from, "rb") as f:
            original = f.read()
        entry["sha256_before_edit"] = sha256_bytes(original)
        entry["sha256_at_write"] = sha256_file(abs_path)
        entry["original_encoding"] = "base64"
        entry["original"] = base64.b64encode(original).decode("ascii")

    manifest = load_manifest(mpath)
    manifest["entries"].append(entry)
    save_manifest(mpath, manifest)
    print("recorded: %-14s %-14s %s  [%s]  → %s"
          % (action, klass, path, args.source, mpath))
    return 0


def _upsert_entry(manifest, entry):
    """Replace the existing entry for this path in place, else append. Keeps the manifest a
    SET over generated-seam paths: gen-shim (re-gen) and sync-seams (regenerate-on-pull) both
    REWRITE the row rather than accumulating stale duplicate receipts. `record` keeps its
    append-only semantics untouched (the keystone's audited contract)."""
    path = entry["path"]
    for i, e in enumerate(manifest["entries"]):
        if e.get("path") == path:
            manifest["entries"][i] = entry
            return
    manifest["entries"].append(entry)


def _upsert_machine_entry(manifest, entry):
    """Replace the existing machine entry for this (marketplace, plugin) in place, else append.
    Keeps machine_entries[] a SET keyed on (marketplace, plugin): a re-adopt / re-record REWRITES
    the row rather than accumulating stale duplicates (mirrors _upsert_entry's discipline for
    entries[]). Never opens a file — a machine entry is pure metadata (no bytes, credential-safe)."""
    key = (entry["marketplace"], entry["plugin"])
    lst = manifest.setdefault("machine_entries", [])
    for i, e in enumerate(lst):
        if (e.get("marketplace"), e.get("plugin")) == key:
            lst[i] = entry
            return
    lst.append(entry)


def cmd_plugin_record(args):
    """Record ONE machine-level plugin entry into machine_entries[] (schema v2, §5 THE PLUGIN).
    The USER-GLOBAL touch `kickoff adopt` makes when it registers the local-path marketplace + enables
    the plugin: the marketplace name, the plugin name, the scope, the machine clone-path the
    marketplace was added from, and a provenance tag. Upsert by (marketplace, plugin) → idempotent.
    Stores NO file bytes and NEVER opens a file — a machine entry is pure metadata (the credential
    invariant: machine entries carry no bytes/secrets). The bash cmd_eject reverses it, not
    cmd_reverse (design reconciliation #4)."""
    repo = resolve_repo_dir(args)
    mpath = manifest_path(repo)
    scope = args.scope
    if scope not in MACHINE_SCOPES:
        die("unknown scope '%s' — must be one of: %s" % (scope, ", ".join(MACHINE_SCOPES)))
    for name, val in (("--marketplace", args.marketplace), ("--plugin", args.plugin),
                      ("--marketplace-source", args.marketplace_source), ("--source", args.source)):
        if not val:
            die("plugin-record requires %s" % name)
    # NOTE: marketplace_source is intentionally a MACHINE path (the pinned clone, e.g.
    # ~/kickoff-core/plugin) — OUTSIDE the repo BY DESIGN — so it does NOT (and must not) go through
    # repo_relative()/_real_within(). That is exactly why this is machine_entries[], not entries[].
    entry = {
        "kind": "plugin",
        "marketplace": args.marketplace,
        "plugin": args.plugin,
        "scope": scope,
        "marketplace_source": args.marketplace_source,
        "source": args.source,
    }
    manifest = load_manifest(mpath)
    manifest["schema_version"] = SCHEMA_VERSION      # recording a machine entry IS a v2 manifest
    _upsert_machine_entry(manifest, entry)
    save_manifest(mpath, manifest)
    print("plugin-record: %s@%s  scope=%s  source=%s  [%s]  → %s"
          % (args.plugin, args.marketplace, scope, args.source, args.marketplace_source, mpath))
    return 0


def cmd_plugin_list(args):
    """Print machine_entries[] as a TAB-SEPARATED table for the bash callers to consume, one row
    per entry: `kind<TAB>marketplace<TAB>plugin<TAB>scope<TAB>marketplace_source` (the same
    shape preflight consumes the seam TSV). EMPTY output ⇒ no machine plugin entry → the caller
    (cmd_pull step 4c / cmd_eject) SKIPS the whole plugin step, so kickoff-itself + headless-only
    adopters — which have no machine entry — call `claude` ZERO times (the dogfood-safety gate)."""
    repo = resolve_repo_dir(args)
    mpath = manifest_path(repo)
    if not os.path.exists(mpath):
        return 0                                     # no manifest → no machine entries → empty (skip)
    manifest = load_manifest(mpath)
    for e in manifest.get("machine_entries", []):
        # A tab in a value would corrupt the TSV; a marketplace/plugin/scope/path never contains one,
        # but strip defensively so a crafted value can't inject an extra column for the bash reader.
        cols = [str(e.get(k, "")).replace("\t", " ").replace("\n", " ")
                for k in ("kind", "marketplace", "plugin", "scope", "marketplace_source")]
        print("\t".join(cols))
    return 0


# ── PLUGIN CACHE VERIFY (schema v2 — §5 THE PLUGIN, Slice 5) ──────────────────────────
# Preflight #6 pins the CLONE (whole-tree lock); but the INTERACTIVE session runs the plugin from the
# USER-GLOBAL cache snapshot (~/.claude/plugins/cache/<mkt>/<plugin>/<version>/), which the clone hash
# cannot see. `plugin-cache-verify` closes that blind spot: per machine plugin entry, it byte-compares
# the pinned plugin's cache snapshot against the pinned $core/plugin/ (a file-set hash of both trees).
# READ + HASH ONLY — it invokes NO `claude`, stores/prints NO file bytes (the credential invariant
# extends here). SYMLINK-SAFE: a cache/core tree is a byte-copy with NO symlinks, so a symlink is both
# anomalous AND a potential out-of-tree read → REFUSE it (fail-closed), the same posture pull's
# _print_seam_diff took. HONEST CAVEAT (kept, like #6/#8): both trees are UNSIGNED — this catches
# accidental DRIFT / a stale cache, NOT a malicious edit that rewrites both the cache and the core.
class _CacheHashError(Exception):
    """Raised on ANY symlink / out-of-tree entry while hashing a plugin tree — fail-closed."""


def _fileset_manifest(base):
    """Sorted [(relpath, sha256hex), …] for every REGULAR file under `base` (a directory). Raises
    _CacheHashError on ANY symlink or out-of-tree resolution: a plugin cache/source tree is a
    byte-copy with no symlinks, so a symlink is anomalous AND a potential out-of-bounds read (a
    planted `cache/…/x → /etc/shadow` would otherwise be hashed) — refuse it. `base` is realpath'd so
    the _real_within containment compares like-for-like."""
    base_real = os.path.realpath(base)
    out = []

    def walk(d, rel):
        try:
            with os.scandir(d) as it:
                entries = sorted(it, key=lambda x: x.name)
        except OSError as e:
            raise _CacheHashError("cannot read '%s' (%s)" % (rel or ".", e))
        for e in entries:
            r = (rel + "/" + e.name) if rel else e.name
            if e.is_symlink():
                raise _CacheHashError("symlink entry refused (not a regular file — possible out-of-tree read): %s" % r)
            if e.is_dir(follow_symlinks=False):
                walk(e.path, r)
            elif e.is_file(follow_symlinks=False):
                # defense-in-depth over is_symlink() above: the REAL path must still sit within base.
                if not _real_within(base_real, e.path):
                    raise _CacheHashError("entry resolves OUTSIDE the tree: %s" % r)
                out.append((r, sha256_file(e.path)))
            # other types (fifo/socket/device) are ignored — a plugin tree never contains them
    walk(base_real, "")
    out.sort()
    return out


def _fileset_hash(manifest):
    """A single digest over a sorted file-set manifest — the value #8 compares cache-vs-core. Hashes
    only (relpath, per-file-sha256) pairs; never a file's raw bytes."""
    h = hashlib.sha256()
    for rel, sha in manifest:
        h.update(rel.encode("utf-8"))
        h.update(b"\0")
        h.update(sha.encode("ascii"))
        h.update(b"\n")
    return h.hexdigest()


def _fileset_diff(core, cache):
    """A short, BYTES-FREE summary of how the core-vs-cache file-sets differ (relpaths + which side),
    for a drift message. NEVER prints file CONTENTS — only relpaths + a changed/added/removed tag."""
    dc, dk = dict(core), dict(cache)
    only_core = sorted(set(dc) - set(dk))
    only_cache = sorted(set(dk) - set(dc))
    changed = sorted(p for p in (set(dc) & set(dk)) if dc[p] != dk[p])
    parts = []
    if changed:
        parts.append("%d changed: %s" % (len(changed), ", ".join(changed[:4])))
    if only_core:
        parts.append("%d only in core: %s" % (len(only_core), ", ".join(only_core[:4])))
    if only_cache:
        parts.append("%d only in cache: %s" % (len(only_cache), ", ".join(only_cache[:4])))
    return "; ".join(parts) or "file-set hashes differ"


def cmd_plugin_cache_verify(args):
    """Verify each recorded plugin's USER-GLOBAL CACHE snapshot byte-matches the pinned $core/plugin/
    (§5 THE PLUGIN, Slice 5 — preflight #8's cache half). Per machine entry: read the pinned version
    from <core-dir>/plugin/.claude-plugin/plugin.json, locate <config-dir>/plugins/cache/<mkt>/<plugin>/
    <version>/, and compare file-set hashes. Missing dir / mismatch / anomalous tree → non-zero
    (fail-closed, matching preflight #6/#8). No machine entries (kickoff-itself, a headless-only
    adopter) → nothing to verify → exit 0 (the inert/dogfood-safe skip). Invokes NO `claude`."""
    repo = resolve_repo_dir(args)
    mpath = manifest_path(repo)
    core_dir = os.path.abspath(args.core_dir)
    cfg = os.path.abspath(args.config_dir)
    plugin_base = os.path.join(core_dir, "plugin")
    cache_root_real = os.path.realpath(os.path.join(cfg, "plugins", "cache"))

    if not os.path.exists(mpath):
        print("plugin-cache-verify: no manifest at %s — no machine entries to verify (skip)" % mpath)
        return 0
    manifest = load_manifest(mpath)
    machine = manifest.get("machine_entries", [])
    if not machine:
        print("plugin-cache-verify: no machine plugin entries — nothing to verify (skip)")
        return 0

    print("plugin-cache-verify — repo=%s  core=%s  cfg=%s" % (repo, core_dir, cfg))

    # The pinned version + the CORE reference file-set — read ONCE from the pinned core plugin (a core
    # carries ONE plugin dir). Read from the CORE plugin.json (whole-tree-pinned), NEVER the recorded
    # marketplace_source (a machine path that can go stale). Any failure here → every entry FAILs
    # (fail-closed: we cannot establish the reference to compare the cache against).
    pinned_ver = None
    core_manifest = None
    core_err = None
    if not os.path.isdir(plugin_base):
        core_err = "the pinned core has NO plugin dir at %s" % plugin_base
    else:
        try:
            with open(os.path.join(plugin_base, ".claude-plugin", "plugin.json"), "r", encoding="utf-8") as f:
                pv = json.load(f).get("version")
            pinned_ver = str(pv) if pv else None
            if not pinned_ver:
                core_err = "the pinned core plugin.json carries no version"
        except (OSError, ValueError) as e:
            core_err = "cannot read the pinned core plugin.json (%s)" % e
        if core_err is None:
            try:
                core_manifest = _fileset_manifest(plugin_base)
            except _CacheHashError as e:
                core_err = "the pinned core plugin tree is anomalous: %s" % e

    ok = failed = 0
    for e in machine:
        mkt = str(e.get("marketplace") or "")
        plugin = str(e.get("plugin") or "")
        label = "%s@%s" % (plugin or "?", mkt or "?")
        if e.get("kind") != "plugin":
            print("  [ skip ] %-24s (machine kind '%s' — not a plugin cache)" % (label, e.get("kind")))
            continue
        if core_err is not None:
            print("  [ FAIL ] %-24s %s — cannot verify the cache (fail-closed)" % (label, core_err))
            failed += 1
            continue
        if not mkt or not plugin:
            print("  [ FAIL ] %-24s machine entry missing marketplace/plugin — cannot locate a cache dir" % label)
            failed += 1
            continue
        # locate the cache version dir; GUARD mkt/plugin/version against a path escape (a crafted
        # machine entry `marketplace: "../.."` must never make us hash/refuse OUTSIDE the cache root).
        cache_dir = os.path.join(cfg, "plugins", "cache", mkt, plugin, pinned_ver)
        cache_dir_real = os.path.realpath(cache_dir)
        try:
            contained = os.path.commonpath([cache_dir_real, cache_root_real]) == cache_root_real
        except ValueError:
            contained = False
        if not contained:
            print("  [ FAIL ] %-24s cache path escapes %s (crafted mkt/plugin/version?) — refusing" % (label, cache_root_real))
            failed += 1
            continue
        if not os.path.isdir(cache_dir):
            print("  [ FAIL ] %-24s cache MISSING at cache/%s/%s/%s — re-sync via `kickoff pull`"
                  % (label, mkt, plugin, pinned_ver))
            failed += 1
            continue
        try:
            cache_manifest = _fileset_manifest(cache_dir)
        except _CacheHashError as ce:
            print("  [ FAIL ] %-24s cache tree anomalous: %s — refusing" % (label, ce))
            failed += 1
            continue
        core_h = _fileset_hash(core_manifest)
        cache_h = _fileset_hash(cache_manifest)
        if core_h == cache_h:
            print("  [ ok  ] %-24s cache @ %s matches the pinned $core/plugin/ (%d files, %s…)"
                  % (label, pinned_ver, len(core_manifest), core_h[:12]))
            ok += 1
        else:
            print("  [ FAIL ] %-24s cache @ %s DRIFTED from the pinned $core/plugin/ (%s) — re-sync via `kickoff pull`"
                  % (label, pinned_ver, _fileset_diff(core_manifest, cache_manifest)))
            failed += 1

    print("── %d ok, %d FAILED (of %d machine entr%s)"
          % (ok, failed, len(machine), "y" if len(machine) == 1 else "ies"))
    if failed:
        sys.stderr.write("adopt-manifest plugin-cache-verify: %d plugin cache(s) drifted/missing — FAIL\n" % failed)
        return 1
    return 0


def cmd_plugin_consumers_others(args):
    """Print one line for every OTHER consumer row of <plugin>@<marketplace> in <config-dir>/plugins/
    installed_plugins.json (§5 THE PLUGIN, #8 — the G7 sibling gate's REAL invariant). The machine
    adopters registry answers "who adopted the core on this box"; the safety question for a cache
    uninstall/reinstall sweep is "who CONSUMES the shared interactive cache" — and a consumer of THIS
    cache is BY CONSTRUCTION a row in THIS installed_plugins.json (same config dir), so this query
    cannot miss one (registry rows are best-effort and CAN). EMPTY output + rc0 ⇒ this repo is
    POSITIVELY the sole interactive consumer → a scoped uninstall/reinstall sweeps only its own cache.
    Row semantics (fail-closed, verified against real claude 2.1.207: a project-scope install records
    projectPath = the consuming project's path; user-scope rows carry NO projectPath):
      • missing installed_plugins.json → rc0 + empty (no consumers at all — and mechanism B is
        unreachable then anyway: the scope-matched installed version reads "");
      • unreadable/corrupt JSON or a non-dict/non-list shape → FATAL (rc2) — NEVER provably sole;
      • a project-scope row whose realpath(projectPath) == realpath(--repo) → SELF (skipped);
      • a project-scope row with a DIFFERENT projectPath → an other consumer (prints its realpath);
      • a project-scope row MISSING/blank projectPath (an older claude wrote it) → an UNKNOWN other
        consumer (prints a placeholder) — it cannot be proven self, so it blocks;
      • any non-project-scope row (user/local) → an other consumer (the user-global cache dir is
        keyed <mkt>/<plugin>/<version> and shared across scopes; prints a placeholder).
    PREMISE (restated so a vendor change re-triggers review): a HEADLESS-ONLY sibling has NO install
    row — its worker execs source via --plugin-dir and never reads this cache — so it no longer
    blocks a safe convergence; if a future claude ever reads the cache WITHOUT an install row, this
    predicate must be revisited. READ-ONLY: never writes, never invokes `claude`."""
    repo = os.path.realpath(resolve_repo_dir(args))
    ipath = os.path.join(os.path.abspath(args.config_dir), "plugins", "installed_plugins.json")
    key = "%s@%s" % (args.plugin, args.marketplace)
    if not os.path.exists(ipath):
        return 0
    try:
        with open(ipath, "r", encoding="utf-8") as f:
            data = json.load(f)
        plugins = data.get("plugins", {}) if isinstance(data, dict) else None
        if not isinstance(plugins, dict):
            raise ValueError("'plugins' is not an object")
        rows = plugins.get(key, [])
        if not isinstance(rows, list):
            raise ValueError("plugins[%r] is not a list" % key)
    except Exception as e:
        die("plugin-consumers-others: cannot read %s (%s) — NOT provably sole (fail-closed)"
            % (ipath, e))
    seen = []
    for r in rows:
        if not isinstance(r, dict):
            line = "(malformed install row — unknown consumer)"
        elif r.get("scope") == "project":
            pp = r.get("projectPath")
            pp = pp.strip() if isinstance(pp, str) else ""
            if pp:                                   # NEVER realpath('') (→ CWD): blank ⇒ unknown below
                rp = os.path.realpath(pp)
                if rp == repo:
                    continue                         # SELF — the one row a sole consumer owns
                line = rp
            else:
                line = "(project-scope install row with NO projectPath — unknown consumer)"
        else:
            line = "(scope=%s install row — consumes the same shared cache)" % (r.get("scope") or "?")
        if line not in seen:
            seen.append(line)
    for line in seen:
        print(line)
    return 0


def _seam_mode(rel_path):
    """The mode a regenerated seam lands at: .kickoff/bin/<name> shims are executable (0755);
    file seams (e.g. .kickoff/KICKOFF.md) are plain 0644."""
    norm = rel_path.replace("\\", "/")
    return 0o755 if norm.startswith(SHIM_DIR + "/") else 0o644


def _write_seam(repo, abs_path, content, mode=0o755):
    """Write a seam file atomically + SYMLINK-SAFE, CONTAINED to the repo (re-review carry-forward).
    Routes through the same realpath-containment (_real_within) + secure-mkstemp (_open_secure_tmp)
    path as the eject byte-restore, so a planted symlink at the seam path can NOT redirect the write
    OUT of the repo (the old direct `open(abs_path, "w")` followed such a symlink). Used by gen-shim
    (0755 shims), gen-charter (0644 file seams), and sync-seams (mode per _seam_mode)."""
    if not _real_within(repo, abs_path):
        raise ValueError("refusing to write a seam OUTSIDE the repo (symlink escape): %s" % abs_path)
    os.makedirs(os.path.dirname(abs_path), exist_ok=True)
    fd, tmp = _open_secure_tmp(abs_path)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
        os.chmod(tmp, mode)
        os.replace(tmp, abs_path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def cmd_gen_shim(args):
    """Generate one SEAM shim (§1.4) into the adopter repo + record it as created/seam.
    Content is machine-path-free (stable hash). Idempotent: re-running upserts the receipt
    rather than duplicating it. `kickoff adopt` calls this; `sync-seams` regenerates it."""
    repo = resolve_repo_dir(args)
    name = args.name
    if name not in SHIM_TEMPLATES:
        die("unknown shim '%s' — known shims: %s" % (name, ", ".join(sorted(SHIM_TEMPLATES))))
    if not args.source:
        die("--source is required (e.g. core-v0.2) — it stamps the seam's provenance in the manifest")

    rel = seam_path_for_shim(name)
    abs_path = os.path.join(repo, ".kickoff", "bin", name)
    _write_seam(repo, abs_path, SHIM_TEMPLATES[name], mode=0o755)

    mpath = manifest_path(repo)
    manifest = load_manifest(mpath)
    entry = {"path": rel, "action": "created", "class": "seam",
             "source": args.source, "sha256_at_write": sha256_file(abs_path)}
    _upsert_entry(manifest, entry)
    save_manifest(mpath, manifest)
    print("gen-shim: wrote %s (0755) + recorded created/seam [%s]  → %s" % (rel, args.source, mpath))
    return 0


def cmd_gen_charter(args):
    """Generate the SPLIT coordinator charter into the adopter repo (design §2.3 Fix 5):
      • .kickoff/KICKOFF.md        — the pulled charter SEAM (created/seam), regenerated on pull;
      • .kickoff/KICKOFF.local.md  — the adopter-owned stub (created/seeded-instance), seeded ONCE,
                                     NEVER regenerated + kept on eject. The seam `@import`s it.
    Mirrors cmd_gen_shim (upsert receipts, symlink-safe writes). Idempotent: the seam is always
    rewritten to the pinned template; the local stub is only written when ABSENT (never clobbers
    the adopter's edits). `sync-seams` on pull regenerates KICKOFF.md for free (it is a seam with a
    whole-file template) and SKIPS KICKOFF.local.md (class=seeded-instance); preflight #8 hashes
    KICKOFF.md automatically. This command wires the MECHANISM — the /adopt flow drives it."""
    repo = resolve_repo_dir(args)
    if not args.source:
        die("--source is required (e.g. core-v0.2) — it stamps the seam's provenance in the manifest")

    mpath = manifest_path(repo)
    manifest = load_manifest(mpath)

    # ── the SEAM: .kickoff/KICKOFF.md (always regenerated from the pinned template) ──
    seam_rel = ".kickoff/KICKOFF.md"
    seam_abs = os.path.join(repo, ".kickoff", "KICKOFF.md")
    seam_tmpl = _read_file_seam_template(FILE_SEAM_TEMPLATES[seam_rel])
    _write_seam(repo, seam_abs, seam_tmpl, mode=0o644)
    _upsert_entry(manifest, {"path": seam_rel, "action": "created", "class": "seam",
                             "source": args.source, "sha256_at_write": sha256_file(seam_abs)})

    # ── the STUB: .kickoff/KICKOFF.local.md (seeded ONCE, never clobbered/regenerated) ──
    local_rel = ".kickoff/KICKOFF.local.md"
    local_abs = os.path.join(repo, ".kickoff", "KICKOFF.local.md")
    seeded = False
    if not os.path.lexists(local_abs):
        _write_seam(repo, local_abs, _KICKOFF_LOCAL_STUB, mode=0o644)
        seeded = True
    else:
        # NEVER clobber an adopter-owned local charter; keep the receipt honest to what's on disk.
        if not _real_within(repo, local_abs):
            die("refusing to record a KICKOFF.local.md that resolves OUTSIDE the repo (symlink escape): %s" % local_abs)
    _upsert_entry(manifest, {"path": local_rel, "action": "created", "class": "seeded-instance",
                             "source": "authored-for-repo", "sha256_at_write": sha256_file(local_abs)})

    save_manifest(mpath, manifest)
    print("gen-charter: wrote %s (seam) + %s (%s) + recorded [%s]  → %s"
          % (seam_rel, local_rel, "seeded" if seeded else "kept — already present", args.source, mpath))
    return 0


def cmd_gen_gitignore(args):
    """Generate .kickoff/.gitignore into the adopter repo + record it created/seam (design §G).
    From the pinned FILE-SEAM template scripts/templates/kickoff.gitignore — so it TRAVELS + PINS
    via core-manifest.txt, `sync-seams` regenerates it on pull, and preflight #8 hashes it (a seam).
    The .gitignore selectively ignores the instance-PRIVATE bits of .kickoff/ (instance.env, the
    manifest, core.lock, derived state) while leaving the team-shareable seams TRACKED (KICKOFF.md,
    KICKOFF.local.md, bin/, memory/). Mirrors cmd_gen_shim: symlink-safe write, upsert the receipt
    (idempotent — re-running rewrites the seam + row rather than duplicating). 0644 (non-bin seam)."""
    repo = resolve_repo_dir(args)
    if not args.source:
        die("--source is required (e.g. core-v0.2) — it stamps the seam's provenance in the manifest")

    rel = ".kickoff/.gitignore"
    abs_path = os.path.join(repo, ".kickoff", ".gitignore")
    tmpl = _read_file_seam_template(FILE_SEAM_TEMPLATES[rel])
    _write_seam(repo, abs_path, tmpl, mode=0o644)

    mpath = manifest_path(repo)
    manifest = load_manifest(mpath)
    _upsert_entry(manifest, {"path": rel, "action": "created", "class": "seam",
                             "source": args.source, "sha256_at_write": sha256_file(abs_path)})
    save_manifest(mpath, manifest)
    print("gen-gitignore: wrote %s (0644) + recorded created/seam [%s]  → %s" % (rel, args.source, mpath))
    return 0


def cmd_gen_readme(args):
    """Generate .kickoff/README into the adopter repo + record it created/seam. From the pinned
    FILE-SEAM template scripts/templates/kickoff-README.md — so it TRAVELS + PINS via
    core-manifest.txt, `sync-seams` regenerates it on pull, and preflight #8 hashes it (a seam).
    It is the human-facing map of the .kickoff/ seam dir that the shims + charter point at with
    'see .kickoff/README' — a reference that was previously DANGLING (nothing created the file).
    Mirrors cmd_gen_gitignore exactly: symlink-safe write, upsert the receipt (idempotent — a
    re-run rewrites the seam + row rather than duplicating). 0644 (non-bin seam)."""
    repo = resolve_repo_dir(args)
    if not args.source:
        die("--source is required (e.g. core-v0.2) — it stamps the seam's provenance in the manifest")

    rel = ".kickoff/README"
    abs_path = os.path.join(repo, ".kickoff", "README")
    tmpl = _read_file_seam_template(FILE_SEAM_TEMPLATES[rel])
    _write_seam(repo, abs_path, tmpl, mode=0o644)

    mpath = manifest_path(repo)
    manifest = load_manifest(mpath)
    _upsert_entry(manifest, {"path": rel, "action": "created", "class": "seam",
                             "source": args.source, "sha256_at_write": sha256_file(abs_path)})
    save_manifest(mpath, manifest)
    print("gen-readme: wrote %s (0644) + recorded created/seam [%s]  → %s" % (rel, args.source, mpath))
    return 0


def cmd_reconcile(args):
    """G9 — generate .kickoff/adopt-manifest.json for an ALREADY-adopted repo WITHOUT re-wiring
    anything (the Bliz shape: core.lock present, manifest absent → preflight #8 fail-closed, and
    the only prior recovery — `kickoff adopt` — is a live-WIRING mutation, not a recovery).

    FROZEN CONTRACT (phase2-plan invariant 5 — record ONLY what is PROVABLE):
      • a KNOWN seam path (a SHIM_TEMPLATES / FILE_SEAM_TEMPLATES path) whose CURRENT bytes
        BYTE-MATCH the current template → created/seam (exactly the row gen-shim/gen-charter/
        gen-gitignore would have written);
      • .claude/settings.json carrying the pinned core plugin's marketplace+enable keys
        (extraKnownMarketplaces.<mkt> + enabledPlugins.<plugin>@<mkt>, names PROVEN from
        <core-dir>/plugin's own manifests) → a machine plugin row (pure metadata — the
        plugin-record upsert shape; the FILE itself is NOT recorded: no pre-edit bytes exist).
    EVERYTHING ELSE is REPORT-ONLY, never recorded:
      • a CLAUDE.md kickoff:begin block has no pre-edit bytes (nothing to --original-from), so
        recording it would arm eject to byte-'restore'/strip the OPERATOR's file = data loss;
      • a hand-edited seam (bytes ≠ template) is not provably kickoff's bytes.
    ZERO adopter-file writes — the ONLY write is the manifest itself (save_manifest: atomic,
    0600); ZERO data-path touches (any DB/state merge is a separate, operator-scheduled step).
    REFUSES an existing manifest: adopt is the idempotent re-wire; reconcile only fills absence."""
    repo = resolve_repo_dir(args)
    mpath = manifest_path(repo)
    if os.path.lexists(mpath):
        die("REFUSING — a manifest already exists at %s. adopt is idempotent: run `kickoff adopt` "
            "to (re)wire + re-record. reconcile exists ONLY for the already-adopted, manifest-less "
            "shape (core.lock present, no adopt-manifest.json)." % mpath)
    if not args.source:
        die("--source is required (e.g. core-v0.2) — it stamps each proven entry's provenance")

    # the skeleton (schema v2) — written even when NOTHING proves out: an empty manifest is the
    # honest receipt ("kickoff can prove none of its artifacts here") and gives preflight #8 its
    # spine back (fail-closed absence → verifiable presence).
    manifest = {"schema_version": SCHEMA_VERSION, "entries": [], "machine_entries": []}
    recorded, reported = [], []

    # ── (a) known seam paths — record ONLY a template-byte-match ────────────────────────
    known = [seam_path_for_shim(n) for n in sorted(SHIM_TEMPLATES)] + sorted(FILE_SEAM_TEMPLATES)
    for rel in known:
        abs_path = os.path.join(repo, rel)
        if not os.path.lexists(abs_path):
            continue                    # absent — nothing to prove, nothing to report
        if os.path.islink(abs_path) or not _real_within(repo, abs_path):
            reported.append("%s — a symlink / resolves OUTSIDE the repo; refusing to read it "
                            "(NOT recorded)" % rel)
            continue
        if not os.path.isfile(abs_path):
            reported.append("%s — not a regular file (NOT recorded)" % rel)
            continue
        tmpl = seam_template_for(rel)
        if tmpl is None:                # unreachable for the known list — belt-and-braces
            continue
        try:
            with open(abs_path, "rb") as f:
                got = f.read()
        except OSError as e:
            reported.append("%s — unreadable (%s) (NOT recorded)" % (rel, e))
            continue
        if got == tmpl.encode("utf-8"):
            _upsert_entry(manifest, {"path": rel, "action": "created", "class": "seam",
                                     "source": args.source, "sha256_at_write": sha256_bytes(got)})
            recorded.append("%s — byte-matches the current template → created/seam" % rel)
        else:
            reported.append("%s — present but its bytes DIFFER from the current core template "
                            "(hand-edited, or generated by another tag) — NOT recorded (not "
                            "provably kickoff's bytes); it stays YOURS. A full `kickoff adopt` "
                            "would REGENERATE it from the template (discarding the difference)." % rel)

    # ── report-only: a CLAUDE.md kickoff block with no pre-edit bytes ────────────────────
    cm = os.path.join(repo, "CLAUDE.md")
    if os.path.isfile(cm) and not os.path.islink(cm) and _real_within(repo, cm):
        try:
            with open(cm, "rb") as f:
                cm_bytes = f.read()
        except OSError:
            cm_bytes = b""
        if b"<!-- kickoff:begin" in cm_bytes:
            reported.append("CLAUDE.md — carries the kickoff @import block, but its PRE-EDIT bytes "
                            "are unknown (nothing to --original-from), so recording it would arm "
                            "eject to byte-'restore'/delete YOUR file on a hash match — data loss. "
                            "NOT recorded; on eject, strip the <!-- kickoff:begin/end --> block by hand.")

    # ── (b) .claude/settings.json plugin keys → machine row (metadata only) ─────────────
    core_dir = os.path.abspath(args.core_dir) if getattr(args, "core_dir", None) else None
    sp = os.path.join(repo, ".claude", "settings.json")
    if os.path.isfile(sp) and not os.path.islink(sp) and _real_within(repo, sp):
        sd = None
        try:
            with open(sp, "r", encoding="utf-8") as f:
                sd = json.load(f)
        except (OSError, ValueError) as e:
            reported.append(".claude/settings.json — present but unreadable/malformed (%s) — "
                            "NOT recorded" % e)
        if isinstance(sd, dict):
            # the PROOF of which marketplace/plugin names are kickoff's: the pinned core's own
            # plugin manifests (the exact source _adopt_enable_plugin reads at wiring time).
            mkt = plugin = None
            if core_dir:
                try:
                    with open(os.path.join(core_dir, "plugin", ".claude-plugin",
                                           "marketplace.json"), "r", encoding="utf-8") as f:
                        mkt = json.load(f).get("name") or None
                    with open(os.path.join(core_dir, "plugin", ".claude-plugin",
                                           "plugin.json"), "r", encoding="utf-8") as f:
                        plugin = json.load(f).get("name") or None
                except (OSError, ValueError):
                    mkt = plugin = None
            ekm = sd.get("extraKnownMarketplaces")
            epl = sd.get("enabledPlugins")
            ekm = ekm if isinstance(ekm, dict) else {}
            epl = epl if isinstance(epl, dict) else {}
            spec = "%s@%s" % (plugin, mkt) if (mkt and plugin) else None
            if spec and mkt in ekm and epl.get(spec):
                # marketplace_source: what the settings file itself RECORDS (the honest metadata),
                # falling back to the pinned <core-dir>/plugin.
                src_path = ""
                row = ekm.get(mkt)
                if isinstance(row, dict):
                    src = row.get("source")
                    if isinstance(src, dict):
                        src_path = str(src.get("path") or "")
                if not src_path:
                    src_path = os.path.join(core_dir, "plugin")
                _upsert_machine_entry(manifest, {
                    "kind": "plugin", "marketplace": mkt, "plugin": plugin, "scope": "project",
                    "marketplace_source": src_path, "source": args.source})
                recorded.append(".claude/settings.json — carries the kickoff plugin keys "
                                "(extraKnownMarketplaces.%s + enabledPlugins.%s) → machine plugin "
                                "row (METADATA ONLY; the file itself is NOT recorded — no pre-edit "
                                "bytes exist to make it reversible). On eject, remove these kickoff "
                                "plugin keys from .claude/settings.json BY HAND — being metadata-only "
                                "they are NOT auto-reversed, so they would otherwise linger as "
                                "dangling keys pointing at the removed marketplace (residue, not "
                                "data loss)." % (mkt, spec))
            elif spec and (mkt in ekm or epl.get(spec)):
                reported.append(".claude/settings.json — carries only HALF the kickoff plugin "
                                "wiring (the marketplace or the enable, not both) — NOT recorded "
                                "(not provably the full enablement); `kickoff adopt` (idempotent) "
                                "re-wires + records it")
            elif ekm and not spec:
                reported.append(".claude/settings.json — has extraKnownMarketplaces but the pinned "
                                "core has no readable plugin manifests (%s) to PROVE which is "
                                "kickoff's — NOT recorded; pull a plugin-carrying core, then "
                                "`kickoff adopt` (idempotent) records it"
                                % (os.path.join(core_dir, "plugin") if core_dir else "no --core-dir"))

    # ── the ONLY write: the manifest (atomic, 0600) ──────────────────────────────────────
    save_manifest(mpath, manifest)
    print("reconcile — repo=%s  (source=%s)" % (repo, args.source))
    print("  RECORDED (%d — provably kickoff's):" % len(recorded))
    for line in recorded:
        print("    + %s" % line)
    if not recorded:
        print("    (none — nothing byte-matched the current templates / no provable plugin keys)")
    print("  REPORT-ONLY (%d — NOT recorded: unprovable or operator-owned):" % len(reported))
    for line in reported:
        print("    - %s" % line)
    if not reported:
        print("    (none)")
    print("  manifest written -> %s  (entries=%d, machine_entries=%d; ZERO other files touched)"
          % (mpath, len(manifest["entries"]), len(manifest["machine_entries"])))
    return 0


def _print_seam_diff(repo, abs_path, tmpl, path):
    """A unified diff between the seam AS IT IS ON DISK (hand-edited) and the pinned template,
    so a refused pull SHOWS the operator exactly what would be overwritten (same posture as
    pull's dirty-clone refusal). DEFENSE-IN-DEPTH (Fix A): NEVER read + diff a seam that is a
    symlink or resolves OUTSIDE the repo — printing its unified diff would leak an out-of-repo
    file's contents (secrets) to the pull output. cmd_sync_seams already refuses such a seam
    BEFORE calling here; this is the belt-and-braces backstop if the guard is ever bypassed."""
    import difflib
    if os.path.islink(abs_path) or not _real_within(repo, abs_path):
        sys.stdout.write("      (refusing to diff a seam that resolves outside the repo)\n")
        return
    try:
        with open(abs_path, "r", encoding="utf-8", errors="replace") as f:
            cur = f.read().splitlines(keepends=True)
    except OSError:
        cur = []
    diff = difflib.unified_diff(cur, tmpl.splitlines(keepends=True),
                                fromfile="%s (on disk — hand-edited)" % path,
                                tofile="%s (pinned template)" % path)
    for line in diff:
        sys.stdout.write("      " + line)
        if not line.endswith("\n"):
            sys.stdout.write("\n")


def cmd_sync_seams(args):
    """UPGRADE seam-sync (design §2.3 item 2): regenerate each manifest-listed SEAM whose
    whole-file template lives here, but ONLY where the file is UNMODIFIED since generation
    (current hash == recorded sha256_at_write) → rewrite + update the recorded hash. A
    HAND-EDITED seam is REFUSED with a diff (the same fail-closed posture pull takes on a
    dirty clone), escapable via --force-regenerate. Instance-class entries are never in the
    regeneration set — the manifest's `class` field is the guarantee, not a convention."""
    repo = resolve_repo_dir(args)
    mpath = manifest_path(repo)
    if not os.path.exists(mpath):
        die("no manifest at %s (nothing to sync)" % mpath)
    manifest = load_manifest(mpath)
    src = args.source or "regenerated"
    force = bool(args.force_regenerate)

    regen = current = refused = skipped = 0
    print("adopt-manifest sync-seams — repo=%s  target=%s%s"
          % (repo, src, "  [--force-regenerate]" if force else ""))
    for e in manifest["entries"]:
        if e.get("class") != "seam":
            continue                                # INSTANCE-class is NEVER regenerated
        path = e.get("path", "")
        tmpl = seam_template_for(path)
        if tmpl is None:
            # a seam with no whole-file template here (e.g. a block-appended CLAUDE.md, which
            # is regenerated block-wise, not whole-file) — leave it untouched.
            print("  [ skip ] %s  (no whole-file template — not regenerated here)" % path)
            skipped += 1
            continue
        abs_path = os.path.join(repo, path)
        # ── SEAM CONTAINMENT (Fix A) — a manifest-listed seam MUST be a REGULAR IN-REPO file ──
        # A symlink (or a path that realpath-resolves OUTSIDE the repo) is anomalous: reading it to
        # hash (sha256_file below FOLLOWS the link), diffing it (_print_seam_diff would print an
        # out-of-repo file's contents — a secret leak into the pull output), or regenerating it would
        # all follow the link out of the repo. Refuse BEFORE the sha256_file() below — never open,
        # read, diff, or regenerate it. Hard [REFUSE]; a missing seam (no dirent) still regenerates.
        if os.path.islink(abs_path) or not _real_within(repo, abs_path):
            print("  [REFUSE] %s is a symlink / resolves OUTSIDE the repo — a seam must be a regular "
                  "in-repo file; refusing to read, diff, or regenerate it" % path)
            refused += 1
            continue
        tmpl_hash = sha256_bytes(tmpl.encode("utf-8"))
        recorded = e.get("sha256_at_write")
        cur = sha256_file(abs_path) if os.path.isfile(abs_path) else None

        if cur == tmpl_hash:
            # already byte-identical to the new template → nothing to write; keep the record honest.
            if recorded != tmpl_hash or e.get("source") != src:
                e["sha256_at_write"] = tmpl_hash
                e["source"] = src
            print("  [ ok  ] %s  already current" % path)
            current += 1
        elif cur is None or cur == recorded or force:
            # MISSING, or UNMODIFIED-since-generation, or FORCED → regenerate from the template.
            _write_seam(repo, abs_path, tmpl, mode=_seam_mode(path))
            e["sha256_at_write"] = tmpl_hash
            e["source"] = src
            why = ("regenerated (was missing)" if cur is None
                   else "force-regenerated over a hand-edit" if (force and cur != recorded)
                   else "regenerated (template changed)")
            print("  [regen] %s  (%s… → %s…)  %s" % (path, (recorded or "--------")[:8], tmpl_hash[:8], why))
            regen += 1
        else:
            # HAND-EDITED since generation → REFUSE (fail-closed). Show the diff + escape hatch.
            print("  [REFUSE] %s — HAND-EDITED since generation (recorded %s… now %s…); refusing to overwrite:"
                  % (path, (recorded or "--------")[:12], cur[:12]))
            _print_seam_diff(repo, abs_path, tmpl, path)
            print("           → re-run pull with --force-regenerate to DISCARD the hand-edit and restore the pinned template.")
            refused += 1

    if regen or current:
        save_manifest(mpath, manifest)
    print("── %d regenerated, %d already-current, %d refused, %d skipped" % (regen, current, refused, skipped))
    if refused:
        sys.stderr.write("adopt-manifest sync-seams: %d hand-edited seam(s) refused — pull blocked "
                         "(restore them, or re-run with --force-regenerate)\n" % refused)
        return 1
    return 0


def cmd_verify(args):
    repo = resolve_repo_dir(args)
    mpath = manifest_path(repo)
    if not os.path.exists(mpath):
        die("FATAL — no manifest at %s (nothing to verify)" % mpath)
    manifest = load_manifest(mpath)
    entries = manifest["entries"]

    ok = failed = skipped = 0
    print("adopt-manifest verify — repo=%s" % repo)
    for e in entries:
        action = e.get("action", "?")
        path = e.get("path", "?")
        want = e.get("sha256_at_write")
        if want is None:
            # hook-installed (or any no-hash entry): reversed structurally (jq-path removal),
            # NOT byte-hashed — settings.local.json is expected to mutate as the operator edits
            # secrets, so a hash-integrity check on it would false-positive. Skip, don't fail.
            print("  [ skip ] %-14s %s  (no sha256_at_write — reversed structurally, not hash-verified)"
                  % (action, path))
            skipped += 1
            continue
        # guard a crafted manifest with an absolute / ../-escaping entry path — record() and
        # preflight #8 both reject these; verify must too, or it would sha256 a file OUTSIDE the
        # repo. Treat an escaping path as a hard FAIL, never silently hash out-of-repo.
        _norm = os.path.normpath(path)
        if os.path.isabs(path) or _norm == ".." or _norm.startswith(".." + os.sep):
            print("  [ FAIL ] %-14s %s  (path ESCAPES the repo — refusing to hash outside %s)" % (action, path, repo))
            failed += 1
            continue
        abs_path = os.path.join(repo, path)
        # Fix B — the lexical guard above is defeated by a SYMLINK (`escape/x` where `escape` →
        # outside). REALPATH-contain the target too, or verify would sha256 a file OUTSIDE the repo.
        if not _real_within(repo, abs_path):
            print("  [ FAIL ] %-14s %s  (resolves OUTSIDE the repo via a symlink — refusing to hash "
                  "outside %s)" % (action, path, repo))
            failed += 1
            continue
        if not os.path.isfile(abs_path):
            print("  [ FAIL ] %-14s %s  (MISSING — recorded but not on disk)" % (action, path))
            failed += 1
            continue
        got = sha256_file(abs_path)
        if got == want:
            print("  [ ok  ] %-14s %s" % (action, path))
            ok += 1
        else:
            print("  [ FAIL ] %-14s %s  (hash mismatch: recorded %s… now %s…)"
                  % (action, path, want[:12], got[:12]))
            failed += 1

    print("── %d ok, %d FAILED, %d skipped (of %d entries)" % (ok, failed, skipped, len(entries)))
    if failed:
        sys.stderr.write("adopt-manifest verify: %d file(s) drifted from the manifest — FAIL\n" % failed)
        return 1
    return 0


def _action_summary(entries):
    counts = {}
    for e in entries:
        counts[e.get("action", "?")] = counts.get(e.get("action", "?"), 0) + 1
    return " · ".join("%d %s" % (counts[a], a) for a in ACTIONS if a in counts)


def cmd_show(args):
    repo = resolve_repo_dir(args)
    mpath = manifest_path(repo)
    if not os.path.exists(mpath):
        die("no manifest at %s" % mpath)
    manifest = load_manifest(mpath)
    entries = manifest["entries"]

    print("adopt-manifest (schema v%s) — %s"
          % (manifest.get("schema_version"), mpath))
    print("  %d entr%s: %s" % (len(entries), "y" if len(entries) == 1 else "ies",
                               _action_summary(entries) or "none"))
    print("")
    for e in entries:
        action = e.get("action", "")
        # Render METADATA ONLY — never echo the stored bytes or any file contents (the
        # credential discipline extends to the render: `original` prints as a size, never
        # its value; hook-installed prints its jq-paths, which carry no secret).
        line = "  %-14s %-14s %-34s [%s]" % (action, e.get("class", ""), e.get("path", ""), e.get("source", ""))
        if "original" in e:
            try:
                nbytes = len(base64.b64decode(e["original"]))
            except Exception:
                nbytes = -1
            line += "  · %d B original stored" % nbytes
        elif action == "hook-installed":
            line += "  · jq-paths: %s  (no bytes stored — credential-safe)" % ", ".join(e.get("jq_paths", []))
        elif e.get("sha256_at_write"):
            line += "  · at_write %s…" % e["sha256_at_write"][:12]
        print(line)

    # ── machine_entries[] (schema v2, §5 THE PLUGIN) — the user-global / machine-level touch ──
    # Metadata only (marketplace/plugin/scope/clone-path/source) — carries no bytes, so nothing
    # to redact. Reversed by the bash cmd_eject on the last sibling, NOT by cmd_reverse.
    machine = manifest.get("machine_entries", [])
    if machine:
        print("")
        print("  %d machine entr%s (user-global — reversed by eject on the last sibling):"
              % (len(machine), "y" if len(machine) == 1 else "ies"))
        for e in machine:
            print("  %-8s %s@%s  scope=%s  [%s]  · src=%s"
                  % (e.get("kind", ""), e.get("plugin", ""), e.get("marketplace", ""),
                     e.get("scope", ""), e.get("source", ""), e.get("marketplace_source", "")))
    return 0


# ── EJECT: the reversal engine (design §2.4) ─────────────────────────────────────────
# `reverse` inverts every recorded touch, driven ENTIRELY by the manifest `record` built — it
# is the eject spine. Its three inviolable rules, each proven in eject-selftest.sh:
#   1. CREDENTIAL SAFETY — a hook-installed entry (settings.local.json, LIVE SECRETS) is reversed
#      by a surgical jq-path del ONLY; its bytes are NEVER byte-restored, printed, logged, or
#      archived. A byte-restore action on a secret-bearing basename is UNREACHABLE (record()
#      refuses it) and hard-fails here if a crafted manifest ever reaches it.
#   2. NO CLOBBER on divergence — every "current hash ≠ recorded" branch PRESERVES the operator's
#      post-adopt edit and reports it; it never silently overwrites or deletes their work.
#   3. BYTE-RESTORE is primary — an UNTOUCHED modified/block-appended/json-merged file is restored
#      from the stored `original` bytes EXACTLY (why a 4-space settings.json round-trips clean); a
#      jq/marker surgical strip is only the fallback when the file was edited after adopt.

# The managed CLAUDE.md block adopt inserts (design §1.2): one blank line, then the marker-
# delimited region. The surgical fallback strips exactly that — begin..end plus the single
# preceding blank-line newline adopt added — when the file was edited after adopt (so a
# byte-restore would clobber the operator's edit). Byte-level so any file encoding round-trips.
#
# HARDENING (Fix D):
#   (a) CRLF tolerance — a block authored/saved with CRLF ends `<!-- kickoff:end -->\r\n`, so the
#       trailing newline is matched as `[ \t]*\r?\n` (the old `[ \t]*\n` never stripped a CRLF
#       block → silent residue on the surgical path).
#   (b) LINE-ANCHORED begin + LAST-begin/end pairing — a required leading `\n` anchors begin to a
#       line start, and the `(?:(?!<!-- kickoff:begin).)*?` guard forbids another `begin` inside
#       the span. So a STRAY operator `<!-- kickoff:begin …-->` BEFORE the real block can no longer
#       pull the non-greedy match to start early and silently delete the operator content between
#       the stray begin and the real end (the old `\n?…begin.*?end` did exactly that). The match now
#       pairs the LAST begin (the one with no begin between it and the end) with that end.
_KICKOFF_BLOCK_RE = re.compile(
    rb"\n<!-- kickoff:begin\b(?:(?!<!-- kickoff:begin).)*?<!-- kickoff:end -->[ \t]*\r?\n",
    re.DOTALL,
)
_KICKOFF_END_MARKER = b"<!-- kickoff:end -->"


def _real_within(repo, abs_path):
    """Fix B — REALPATH containment: the LEXICAL escape guard (normpath + isabs + '..'-prefix,
    in cmd_reverse/cmd_verify/repo_relative) is defeated by a SYMLINK. A crafted manifest entry
    `escape/victim.txt`, where `escape` is a symlink to an outside dir, is lexically clean yet
    resolves OUTSIDE the repo — so a byte-restore / delete / jq-rewrite following it would write
    or delete out-of-repo (invariant 4 break). Require the entry's REAL path to sit inside the
    repo's REAL path. For a to-be-created target (no dirent yet), realpath its PARENT dir, then
    re-attach the basename (never follow a final symlink we're about to replace). commonpath ==
    repo_real is the containment test; a cross-device / bad-input ValueError fails CLOSED."""
    repo_real = os.path.realpath(repo)
    if os.path.lexists(abs_path):
        real = os.path.realpath(abs_path)
    else:
        parent = os.path.dirname(abs_path) or "."
        real = os.path.join(os.path.realpath(parent), os.path.basename(abs_path))
    try:
        return os.path.commonpath([real, repo_real]) == repo_real
    except ValueError:
        return False


def _atomic_write_bytes(repo, abs_path, data):
    """Write bytes to abs_path atomically (tmp in the SAME dir + os.replace), preserving the
    file's current mode. Used by the byte-restore + the surgical block-strip. FAIL-CLOSED (Fix B)
    if the target resolves OUTSIDE the repo via a symlink — the tmp lands in the target's dir, so
    an unguarded write here would follow the symlink out of the repo before os.replace even runs."""
    if not _real_within(repo, abs_path):
        raise ValueError("refusing to write OUTSIDE the repo (symlink escape): %s" % abs_path)
    d = os.path.dirname(abs_path) or "."
    os.makedirs(d, exist_ok=True)
    try:
        mode = os.stat(abs_path).st_mode & 0o777
    except OSError:
        mode = 0o644
    fd, tmp = _open_secure_tmp(abs_path)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.chmod(tmp, mode)
        os.replace(tmp, abs_path)
    except BaseException:
        # crash-safety (same discipline as Fix C for the secret tmp): never leave a stray
        # *.kickoff-eject.tmp on ANY failure/interrupt between create and replace.
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _reverse_created(repo, entry, dry, on_div):
    """created → DELETE the file, gated on its hash matching the record. Absent = idempotent.
    Diverged (operator edited it) = NEVER silent-delete: keep by default, delete only under an
    explicit --on-divergence delete policy."""
    path = entry["path"]
    abs_path = os.path.join(repo, path)
    want = entry.get("sha256_at_write")
    if not _real_within(repo, abs_path):
        print("  [ FAIL ] created        %s  (resolves OUTSIDE the repo via a symlink — refusing "
              "to delete out-of-repo)" % path)
        return "failed"
    if not os.path.lexists(abs_path):
        print("  [ gone ] created        %s  (already absent — idempotent)" % path)
        return "skipped"
    got = sha256_file(abs_path) if os.path.isfile(abs_path) else None
    if want is not None and got == want:
        if dry:
            print("  [ del? ] created        %s  WOULD delete (matches recorded hash)" % path)
        else:
            os.remove(abs_path)
            print("  [ del  ] created        %s  deleted" % path)
        return "deleted"
    if on_div == "delete":
        if dry:
            print("  [ del? ] created        %s  WOULD delete (--on-divergence delete, drifted)" % path)
        else:
            os.remove(abs_path)
            print("  [ del  ] created        %s  deleted (--on-divergence delete despite drift)" % path)
        return "deleted"
    print("  [ keep ] created        %s  DIVERGED (recorded %s… now %s…) — kept, not deleted "
          "(--on-divergence keep)" % (path, (want or "--------")[:8], (got or "--------")[:8]))
    return "kept"


def _reverse_original_edited(repo, entry, dry, got, want):
    """The file was EDITED after adopt (current hash ≠ recorded) → a byte-restore would clobber
    the operator's work. Surgical, no-clobber fallback per action; honest about what it can't do."""
    action, path = entry["action"], entry["path"]
    abs_path = os.path.join(repo, path)
    short = "(recorded %s… now %s…)" % ((want or "--------")[:8], (got or "--------")[:8])
    if action == "block-appended":
        try:
            with open(abs_path, "rb") as f:
                data = f.read()
        except OSError as e:
            print("  [ FAIL ] block-appended %s  (cannot read: %s)" % (path, e))
            return "failed"
        # Fix D — AMBIGUITY REFUSAL (no-clobber): a single kickoff:end marker is the one block
        # adopt inserted. TWO OR MORE end markers means it is no longer unambiguous which block is
        # kickoff's (a second real block, or operator prose carrying the markers) → REFUSE to strip
        # rather than risk deleting the wrong span. The pre-adopt original is safe in the archive.
        if data.count(_KICKOFF_END_MARKER) >= 2:
            print("  [ keep ] block-appended %s  EDITED %s and carries MULTIPLE kickoff:end markers "
                  "— ambiguous which block is kickoff's; REFUSING to strip (no clobber). The pre-adopt "
                  "original is in the archive — reconcile manually" % (path, short))
            return "kept"
        new, n = _KICKOFF_BLOCK_RE.subn(b"", data, count=1)
        if n == 0:
            print("  [ keep ] block-appended %s  EDITED %s but no kickoff block found — left "
                  "as-is (the pre-adopt original is in the archive)" % (path, short))
            return "kept"
        if dry:
            print("  [ strp?] block-appended %s  WOULD strip the marked block (edited after "
                  "adopt; formatting may differ)" % path)
            return "restored"
        _atomic_write_bytes(repo, abs_path, new)
        print("  [ strip] block-appended %s  stripped the marked block (edited after adopt — "
              "formatting may differ from the pre-adopt file)" % path)
        return "restored"
    if action == "json-merged":
        # LOCKED D3: the schema records NO jq_paths for json-merged → we cannot surgically
        # un-merge without clobbering the operator's post-adopt edit. Honest limit, leave it.
        print("  [ keep ] json-merged    %s  EDITED after adopt %s — cannot surgically un-merge "
              "(no recorded jq paths); left as-is, the pre-adopt original is in the archive — "
              "reconcile manually" % (path, short))
        return "kept"
    # modified (generic): no markers, no recorded added-region → do NOT clobber.
    print("  [ keep ] modified       %s  EDITED after adopt %s — left as-is; the pre-adopt "
          "original is in the archive — reconcile manually" % (path, short))
    return "kept"


def _reverse_original(repo, entry, dry):
    """modified / block-appended / json-merged → BYTE-RESTORE the stored pre-edit bytes when the
    file is UNTOUCHED since adopt (primary), else the surgical no-clobber fallback."""
    action, path = entry["action"], entry["path"]
    abs_path = os.path.join(repo, path)
    # ESCAPE CONTAINMENT (Fix B) — refuse a symlink-escaping target before ANY read/write.
    if not _real_within(repo, abs_path):
        print("  [ FAIL ] %-14s %s  (resolves OUTSIDE the repo via a symlink — refusing to "
              "touch out-of-repo)" % (action, path))
        return "failed"
    # CREDENTIAL BACKSTOP — a secret-bearing file must NEVER be byte-restored (that would write
    # its live-credential bytes from the manifest). record() refuses to store one under these
    # actions, so this is UNREACHABLE; hard-fail if a crafted manifest ever gets here.
    # normpath first (LOW-b): this path comes FROM the manifest (the crafted case this guard
    # exists for) — a '.claude/settings.local.json/.' spelling must not slip a bare basename.
    if os.path.basename(os.path.normpath(path)) in SECRET_BEARING_BASENAMES:
        print("  [ FAIL ] %-14s %s  (secret-bearing file under a byte-restore action — "
              "UNREACHABLE via record(); refusing to write stored bytes back)" % (action, path))
        return "failed"
    original_b64 = entry.get("original")
    if original_b64 is None:
        print("  [ FAIL ] %-14s %s  (no stored original bytes — cannot byte-restore)" % (action, path))
        return "failed"
    want = entry.get("sha256_at_write")
    if not os.path.lexists(abs_path):
        # operator DELETED it after adopt → do NOT resurrect it.
        print("  [ skip ] %-14s %s  (file absent — operator deleted it; not restoring)" % (action, path))
        return "skipped"
    got = sha256_file(abs_path) if os.path.isfile(abs_path) else None
    if want is not None and got == want:
        try:
            data = base64.b64decode(original_b64)
        except Exception as e:
            print("  [ FAIL ] %-14s %s  (corrupt stored original: %s)" % (action, path, e))
            return "failed"
        if dry:
            print("  [ rest?] %-14s %s  WOULD byte-restore %d B (untouched since adopt)" % (action, path, len(data)))
            return "restored"
        _atomic_write_bytes(repo, abs_path, data)
        print("  [ rest ] %-14s %s  byte-restored %d B (exact pre-adopt bytes)" % (action, path, len(data)))
        return "restored"
    return _reverse_original_edited(repo, entry, dry, got, want)


_JQ_INDEX_RE = re.compile(r"^(?P<parent>.+)\[(?P<idx>\d+)\]$")


def _split_jq_index(jq_path):
    """`.hooks.UserPromptSubmit[0]` → ('.hooks.UserPromptSubmit', 0). A path with NO trailing [N]
    array index → (None, None): without the parent array there is nothing to content-search."""
    m = _JQ_INDEX_RE.match((jq_path or "").strip())
    if not m:
        return (None, None)
    return (m.group("parent"), int(m.group("idx")))


def _jq_raw(jq, abs_path, expr, sort):
    """Run `jq [-S] -c <expr> <file>` capturing stdout as RAW BYTES — never decoded for logging,
    never printed. stderr → DEVNULL so a secret-bearing file can never surface via a jq diagnostic.
    Returns (ok, stdout_bytes)."""
    argv = [jq] + (["-S"] if sort else []) + ["-c", expr, abs_path]
    try:
        out = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError:
        return (False, b"")
    if out.returncode != 0:
        return (False, b"")
    return (True, out.stdout)


def _jq_array_len(jq, abs_path, parent):
    """Length of the array at `parent` in the CURRENT file, or -1 if it is missing / not an array
    (operator removed or replaced it post-adopt). `try … catch -1` keeps a bad path from erroring."""
    expr = 'try ((%s) | if type=="array" then length else -1 end) catch -1' % parent
    ok, out = _jq_raw(jq, abs_path, expr, sort=False)
    if not ok:
        return -1
    try:
        return int(out.decode("ascii", "strict").strip())
    except ValueError:
        return -1


def _jq_elem_sha256(jq, abs_path, parent, i):
    """sha256 of the CANONICAL json (`jq -S -c`) of element `parent[i]` — computed byte-identically
    to the record-time `jq -S -c '<jq_path>' file | sha256sum`, so the recorded hook's hash matches
    it WHEREVER the element moved (reorder-safe) and WHATEVER its command text (content-agnostic).
    The element bytes are HASHED, never printed (credential rule — the parent array can neighbour
    secret-bearing keys). Returns the hex digest, or None on a jq error."""
    ok, out = _jq_raw(jq, abs_path, "%s[%d]" % (parent, i), sort=True)
    if not ok:
        return None
    return hashlib.sha256(out).hexdigest()


def _reverse_hook_installed(repo, entry, dry):
    """hook-installed (settings.local.json — LIVE SECRETS) → surgical jq-path del ONLY, never a
    byte-restore. The recorded hook is identified by a CONTENT HASH, never a substring or a bare
    positional index (Fix A). For each recorded (jq_path, hook_sha256): strip the trailing [N] to
    get the parent array, hash every element's canonical json, and del the ONE element whose hash
    equals the record — so a REORDERED hook is still found (wherever it moved), a NON-"kickoff"
    command is matched (content-agnostic, no false-negative residue), and an operator's OWN hook is
    NEVER clobbered (a hash mismatch is left untouched). ONE del() over all matched indices so jq
    evaluates them together and array indices don't shift mid-delete. Output goes to a 0600 temp in
    the SAME dir; the secret bytes NEVER hit stdout/stderr. jq absent → fail-CLOSED (we will not
    hand-parse a secret-bearing file as a fallback)."""
    path = entry["path"]
    abs_path = os.path.join(repo, path)
    jq_paths = entry.get("jq_paths") or []
    hook_shas = entry.get("hook_sha256s") or []
    # ESCAPE CONTAINMENT (Fix B) — refuse a symlink-escaping target before any read/write/jq.
    if not _real_within(repo, abs_path):
        print("  [ FAIL ] hook-installed %s  (resolves OUTSIDE the repo via a symlink — refusing "
              "to touch out-of-repo)" % path)
        return "failed"
    if not os.path.isfile(abs_path):
        print("  [ skip ] hook-installed %s  (absent — nothing to un-hook)" % path)
        return "skipped"
    jq = shutil.which("jq")
    if jq is None:
        print("  [ FAIL ] hook-installed %s  (jq NOT found — cannot reverse a hook-installed "
              "entry without jq; install jq and re-run eject)" % path)
        return "failed"
    if not jq_paths:
        print("  [ skip ] hook-installed %s  (no jq_paths recorded — nothing to remove)" % path)
        return "skipped"
    if len(hook_shas) != len(jq_paths):
        # No per-hook content hashes to match against → we will NOT fall back to a blind positional
        # delete or a substring probe (both defeated in review). Honest: leave it, point elsewhere.
        print("  [ keep ] hook-installed %s  (no per-hook content hashes recorded — jq_paths=%d, "
              "hook_sha256s=%d; cannot content-match, refusing a blind positional delete; left "
              "as-is)" % (path, len(jq_paths), len(hook_shas)))
        return "kept"

    # content-hash match → collect the CURRENT index of each recorded hook (or report it gone).
    del_paths = []
    claimed = {}     # parent → set(indices already claimed by an earlier recorded hook)
    for jp, want in zip(jq_paths, hook_shas):
        parent, _idx = _split_jq_index(jp)
        if parent is None:
            print("  [ skip ] hook-installed %s  %s has no array-index suffix — cannot content-"
                  "match; left as-is" % (path, jp))
            continue
        n = _jq_array_len(jq, abs_path, parent)
        taken = claimed.setdefault(parent, set())
        found = None
        for i in range(n if n > 0 else 0):
            if i in taken:
                continue
            if _jq_elem_sha256(jq, abs_path, parent, i) == want:
                found = i
                break
        if found is None:
            print("  [ skip ] hook-installed %s  recorded kickoff hook %s (sha %s…) not found "
                  "(removed or changed post-adopt) — left as-is" % (path, jp, (want or "--------")[:8]))
            continue
        taken.add(found)
        del_paths.append("%s[%d]" % (parent, found))

    if not del_paths:
        print("  [ keep ] hook-installed %s  (recorded kickoff hook not found (removed or changed "
              "post-adopt); left as-is)" % path)
        return "kept"
    if dry:
        print("  [ del? ] hook-installed %s  WOULD jq-del: %s" % (path, ", ".join(del_paths)))
        return "restored"

    del_expr = "del(" + ", ".join(del_paths) + ")"
    src_mode = None
    try:
        src_mode = os.stat(abs_path).st_mode & 0o777
    except OSError:
        pass
    # Fix C — CRASH-SAFETY: the tmp holds the secret-bearing file's bytes. It stays 0600 for its
    # ENTIRE life (never chmod'd up to a looser source mode before replace), and the try/finally
    # unlinks it on ANY exit that did not complete the replace — a jq non-zero, an os.replace
    # error, OR a KeyboardInterrupt — so a Ctrl-C can never strand a world-adjacent secret tmp that
    # would slip past .gitignore's exact-name rule and --verify's marker scan.
    fd, tmp = _open_secure_tmp(abs_path)
    ok = False
    try:
        try:
            # stderr → DEVNULL so a jq error can never surface a byte of the secret-bearing file.
            rc = subprocess.call([jq, del_expr, abs_path], stdout=fd, stderr=subprocess.DEVNULL)
        finally:
            os.close(fd)
        if rc == 0:
            os.replace(tmp, abs_path)
            ok = True
    finally:
        if not ok:
            try:
                os.unlink(tmp)
            except OSError:
                pass
    if not ok:
        print("  [ FAIL ] hook-installed %s  (jq del failed — file left untouched, no tmp left behind)" % path)
        return "failed"
    # Only AFTER a successful atomic replace, restore the secret file's original mode on the
    # DESTINATION (typ. 0600). The tmp was never widened, so the replace-fail path above can never
    # leave a world-readable secret.
    if src_mode is not None:
        try:
            os.chmod(abs_path, src_mode)
        except OSError:
            pass
    print("  [ del  ] hook-installed %s  jq-removed the recorded kickoff hook(s) by content hash "
          "(%s) — secrets untouched" % (path, ", ".join(del_paths)))
    return "restored"


def cmd_reverse(args):
    repo = resolve_repo_dir(args)
    mpath = manifest_path(repo)
    if not os.path.exists(mpath):
        die("FATAL — no manifest at %s (nothing to reverse)" % mpath)
    manifest = load_manifest(mpath)
    entries = manifest["entries"]
    dry = bool(args.dry_run)
    on_div = args.on_divergence
    purge_seeded = bool(args.purge_seeded)

    print("adopt-manifest reverse — repo=%s%s  (on-divergence=%s%s)"
          % (repo, "  [dry-run]" if dry else "", on_div,
             ", purge-seeded" if purge_seeded else ""))
    counts = {"restored": 0, "deleted": 0, "kept": 0, "skipped": 0, "failed": 0}

    # REVERSE insertion order: undo the last touch first (so a later edit layered on an earlier
    # file is unwound in the order it was applied).
    for e in reversed(entries):
        action = e.get("action", "?")
        path = e.get("path", "?")
        klass = e.get("class", "")
        # escape guard (as record() + verify + preflight #8 do): never touch a file OUTSIDE the repo.
        _norm = os.path.normpath(path)
        if os.path.isabs(path) or _norm == ".." or _norm.startswith(".." + os.sep):
            print("  [ FAIL ] %-14s %s  (path ESCAPES the repo — refusing to touch outside %s)"
                  % (action, path, repo))
            counts["failed"] += 1
            continue
        # seeded-instance crew (fork #3): a deliverable authored FOR the repo → KEPT by default;
        # reversed only under --purge-seeded, and even then via the same hash-gated, divergence-safe
        # action path (so a crew file edited after adopt is still never silent-deleted).
        if klass == "seeded-instance" and not purge_seeded:
            print("  [ keep ] %-14s %s  (seeded-instance crew — kept; adopter-owned deliverable)"
                  % (action, path))
            counts["kept"] += 1
            continue

        if action == "created":
            st = _reverse_created(repo, e, dry, on_div)
        elif action in ORIGINAL_ACTIONS:
            st = _reverse_original(repo, e, dry)
        elif action == "hook-installed":
            st = _reverse_hook_installed(repo, e, dry)
        else:
            print("  [ FAIL ] %-14s %s  (unknown action — cannot reverse)" % (action, path))
            st = "failed"
        counts[st] = counts.get(st, 0) + 1

    print("── %d restored, %d deleted, %d kept, %d skipped, %d failed (of %d entries)"
          % (counts["restored"], counts["deleted"], counts["kept"], counts["skipped"],
             counts["failed"], len(entries)))
    if counts["failed"]:
        sys.stderr.write("adopt-manifest reverse: %d entr%s FAILED to reverse — see the report above\n"
                         % (counts["failed"], "y" if counts["failed"] == 1 else "ies"))
        return 1
    return 0


def cmd_reassert_file(args):
    """Re-write a repo file to EXACT bytes from a snapshot, via the SAME hardened symlink-safe atomic
    write the eject byte-restore uses (_real_within + _atomic_write_bytes + the mkstemp/O_EXCL tmp).

    WHY (the eject round-trip bug): eject step-4 (`reverse`) byte-restores .claude/settings.json to its
    exact pre-adopt bytes — but step-5's machine-unwiring then calls `claude plugin uninstall --scope
    project` + `claude plugin marketplace remove`, and real `claude` RE-SERIALIZES the project
    settings.json as a side effect (re-canonicalizing it AND re-introducing a stray `enabledPlugins:
    {}`), clobbering the byte-restore AFTER it. cmd_eject snapshots settings.json immediately after the
    reversal and calls this immediately after the plugin-CLI loop to re-assert those exact bytes —
    undoing ONLY the plugin CLI's mangle. Correct in BOTH hash-gate cases: the snapshot is whatever
    step-4 produced (a byte-restored pristine file OR a preserved-diverged one), so a genuine
    post-adopt user edit is preserved, never clobbered.

    INVARIANTS (this is a credential/destruction path — the eject slice previously shipped a HIGH
    tmp-symlink exfil bug here, so every guard is deliberate):
      • CREDENTIAL-SAFE — REFUSES a secret-bearing basename (settings.local.json). That file is never
        re-serialized by the plugin CLI and carries LIVE secrets; a crafted call must never write it.
      • SYMLINK-SAFE — _real_within refuses a path resolving OUTSIDE the repo, and _atomic_write_bytes
        writes via a RANDOM mkstemp (never a predictable sibling a planted symlink could hijack).
      • IDEMPOTENT — if the on-disk file already equals the snapshot (the CLI did not touch it), it is
        a no-op: no needless re-write, current mode preserved."""
    repo = resolve_repo_dir(args)
    path = repo_relative(args.path)
    abs_path = os.path.join(repo, path)
    # CREDENTIAL BACKSTOP — defense-in-depth: the caller only ever passes settings.json, but a crafted
    # invocation must NEVER be able to re-write settings.local.json (live secrets) from a snapshot.
    # normpath first so a trailing slash / '.' component can't evade the basename check (e.g.
    # '.claude/settings.local.json/' → basename '' would slip the guard); _real_within still guards
    # the actual write target below.
    if os.path.basename(os.path.normpath(path)) in SECRET_BEARING_BASENAMES:
        die("REFUSING — '%s' is secret-bearing; reassert-file never targets it (it is not "
            "re-serialized by the plugin CLI and carries live secrets)." % path)
    if not args.from_file or not os.path.isfile(args.from_file):
        die("reassert-file REQUIRES --from <snapshot-file> (the exact bytes to re-assert)")
    # SYMLINK CONTAINMENT — refuse a target that resolves OUTSIDE the repo (the eject Fix-B posture),
    # BEFORE reading the snapshot / writing anything.
    if not _real_within(repo, abs_path):
        die("REFUSING to re-assert a path that resolves OUTSIDE the repo (symlink escape): %s" % abs_path)
    with open(args.from_file, "rb") as f:
        data = f.read()
    # idempotent: the plugin CLI may have left the file untouched (e.g. a scope-less remove that
    # changed nothing) — re-writing identical bytes is a needless churn, so short-circuit it.
    if os.path.isfile(abs_path) and not os.path.islink(abs_path):
        try:
            with open(abs_path, "rb") as f:
                if f.read() == data:
                    print("reassert-file: %s already matches the snapshot — no re-write needed" % path)
                    return 0
        except OSError:
            pass
    _atomic_write_bytes(repo, abs_path, data)
    print("reassert-file: re-asserted %s (%d B, exact pre-uninstall bytes)" % (path, len(data)))
    return 0


# The ONLY path rehash-path may touch. A hard allowlist, not a pattern: the verb exists for exactly
# one legitimate write (cmd_pull's G6 marketplace re-point rewriting .claude/settings.json) and a
# wider surface would let any caller launder an arbitrary edit past eject's hash gate.
REHASH_ALLOWED_PATHS = (".claude/settings.json",)


def cmd_rehash_path(args):
    """Re-record ONLY sha256_at_write for ONE allowlisted path after a LEGITIMATE kickoff-driven
    write (Phase-2 G6/G7 — the [[reversal-must-be-the-final-write]] fix for the PULL path).

    WHY: cmd_pull's marketplace re-point (G6) rewrites .claude/settings.json ON PURPOSE (the
    extraKnownMarketplaces source must follow the pinned work dir). That is an INTENDED change —
    reasserting the old bytes would undo the fix — but it leaves the file ≠ its recorded
    sha256_at_write, so a later eject's hash gate (_reverse_original) would read kickoff's own write
    as "EDITED by the operator" and SKIP the byte-restore, stranding the plugin keys in the repo.
    Re-recording sha256_at_write keeps the gate TRUE: eject still byte-restores the pre-adopt
    `original` exactly.

    INVARIANTS (narrow BY CONSTRUCTION — this verb must never become a general manifest editor):
      • PATH-RESTRICTED — hard allowlist (REHASH_ALLOWED_PATHS = .claude/settings.json only). The
        secret-bearing settings.local.json is unreachable (not allowlisted; SECRET_BEARING guard as
        defense-in-depth), and NO seam/crew/operator path can be laundered past its recorded hash.
      • UPDATES ONLY sha256_at_write — never `original`, never `sha256_before_edit` (the eject
        byte-restore payload is untouchable), never action/class/source.
      • SYMLINK-SAFE — refuses a symlinked or out-of-repo-resolving target (never hashes through a
        planted link — the reassert-file posture).
      • FAIL-LOUD — no entry for the path, or an entry without a sha256_at_write to update, is an
        error (rc≠0), never a silent upsert (that would fabricate a receipt record() never wrote).
      • IDEMPOTENT — hash already current → clean no-op."""
    repo = resolve_repo_dir(args)
    path = repo_relative(args.path)
    if path not in REHASH_ALLOWED_PATHS:
        die("REFUSING — rehash-path is restricted to %s (got '%s'). It exists ONLY for kickoff's "
            "own legitimate settings.json write (the pull-time marketplace re-point); any other "
            "path would launder an edit past eject's hash gate." % (", ".join(REHASH_ALLOWED_PATHS), path))
    # defense-in-depth (unreachable via the allowlist): the credential file is never rehashed.
    if os.path.basename(os.path.normpath(path)) in SECRET_BEARING_BASENAMES:
        die("REFUSING — '%s' is secret-bearing; rehash-path never targets it." % path)
    abs_path = os.path.join(repo, path)
    if not _real_within(repo, abs_path):
        die("REFUSING — %s resolves OUTSIDE the repo (symlink escape)" % path)
    if os.path.islink(abs_path):
        die("REFUSING — %s is a symlink; rehash-path only hashes a regular file (a planted link "
            "must never have its target's hash recorded as the repo file's)" % path)
    if not os.path.isfile(abs_path):
        die("rehash-path: %s does not exist — nothing to hash (the caller re-records AFTER its "
            "write, so an absent file is a caller bug)" % path)
    mpath = manifest_path(repo)
    if not os.path.exists(mpath):
        die("rehash-path: no manifest at %s — nothing to re-record" % mpath)
    manifest = load_manifest(mpath)
    for e in manifest["entries"]:
        if e.get("path") == path:
            if "sha256_at_write" not in e:
                die("rehash-path: the %s entry (action=%s) carries no sha256_at_write — refusing "
                    "to ADD one (this verb updates an existing hash, never fabricates a field)"
                    % (path, e.get("action")))
            new = sha256_file(abs_path)
            old = e["sha256_at_write"]
            if old == new:
                print("rehash-path: %s already matches its recorded sha256_at_write — no-op" % path)
                return 0
            e["sha256_at_write"] = new
            save_manifest(mpath, manifest)
            print("rehash-path: re-recorded sha256_at_write for %s (%s… → %s…) — original/"
                  "sha256_before_edit untouched" % (path, (old or "--------")[:8], new[:8]))
            return 0
    die("rehash-path: no manifest entry for %s — nothing to re-record (record() owns creation)" % path)


# ── ADOPTERS REGISTRY (design §2.3 item 5 / Fix 7) ───────────────────────────────────
# A machine-level ledger of every adopter this box pulls: ~/.kickoff/adopters.json, one row per
# adopter { repo, tag, version_dir }. `kickoff pull` upserts a row after the clean checkout; eject
# removes it. It is what lets ONE box host MULTIPLE adopters pinned at DIFFERENT core tags without
# them fighting over a single detached HEAD — a sibling on a different tag gets a parked worktree,
# and the registry records which version_dir each adopter actually uses. The registry lands BEFORE
# any prune, and there is NO auto-prune: ~/kickoff-core is never removed while a sibling needs it.
REGISTRY_SCHEMA_VERSION = 1


def _registry_path(args):
    """--registry wins, then $KICKOFF_ADOPTERS_REGISTRY, then ~/.kickoff/adopters.json. The env
    override lets the selftest point it at a mktemp dir (no real ~ pollution)."""
    p = getattr(args, "registry", None) or os.environ.get("KICKOFF_ADOPTERS_REGISTRY")
    if not p:
        p = os.path.join(os.path.expanduser("~"), ".kickoff", "adopters.json")
    return os.path.abspath(p)


def _load_registry(rpath):
    """A missing registry is a fresh, empty ledger. A present-but-malformed one is FATAL — never
    skeleton over it (the same fail-loud posture load_manifest takes)."""
    if not os.path.exists(rpath):
        return {"schema_version": REGISTRY_SCHEMA_VERSION, "adopters": []}
    try:
        with open(rpath, "r", encoding="utf-8") as f:
            r = json.load(f)
    except (OSError, ValueError) as e:
        die("FATAL — cannot read adopters registry %s: %s" % (rpath, e))
    if not isinstance(r, dict) or not isinstance(r.get("adopters"), list):
        die("FATAL — malformed adopters registry (no adopters[] array): %s" % rpath)
    r.setdefault("schema_version", REGISTRY_SCHEMA_VERSION)
    return r


def _save_registry(rpath, registry):
    """Atomic + SYMLINK-SAFE write: a RANDOM-name mkstemp (via _open_secure_tmp) then os.replace at
    0600. A machine-level file written through a PREDICTABLE `path + '.tmp'` + plain os.open carries
    the SAME symlink-exfil bug the eject re-review closed (a planted symlink at the predictable tmp
    redirects the write out-of-dir) — so every atomic write, repo-scoped or not, routes through the
    secure helper."""
    os.makedirs(os.path.dirname(rpath) or ".", exist_ok=True)
    fd, tmp = _open_secure_tmp(rpath, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(registry, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.replace(tmp, rpath)
        os.chmod(rpath, 0o600)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


@contextlib.contextmanager
def _registry_lock(rpath, timeout=None):
    """Serialize the registry READ-MODIFY-WRITE with an OS lock (Fix D — lost-update race).
    cmd_adopters_register/_remove do _load_registry → mutate → _save_registry with NO lock, so two
    concurrent `kickoff pull`s race: both read the same registry, each writes back its own +1 row,
    and one row is LOST (os.replace keeps the FILE valid, but the RMW window is unguarded). A dropped
    adopter row → a sibling is mis-detected → the shared clone moves out from under it. Hold an
    fcntl.flock across the WHOLE load→mutate→save window. The lock lives on a SIDECAR <registry>.lock
    (never the registry itself: _save_registry os.replaces the registry inode, so a lock held on that
    inode would not cover the successor file). Fail-CLOSED if the lock can't be acquired within
    `timeout` seconds (default 10, overridable via $KICKOFF_REGISTRY_LOCK_TIMEOUT for tests)."""
    if timeout is None:
        try:
            timeout = float(os.environ.get("KICKOFF_REGISTRY_LOCK_TIMEOUT", "10"))
        except ValueError:
            timeout = 10.0
    lock_file = rpath + ".lock"
    os.makedirs(os.path.dirname(lock_file) or ".", exist_ok=True)
    fd = os.open(lock_file, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    die("FATAL — could not acquire the adopters-registry lock (%s) within %.0fs — "
                        "another registry op is holding it; refusing the read-modify-write to avoid "
                        "a lost update (fail-closed)" % (lock_file, timeout))
                time.sleep(0.02)
        try:
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def cmd_adopters_register(args):
    """Upsert THIS adopter's row (keyed by realpath(repo)): { repo, tag, version_dir[, channel] }.
    G10b — the optional --channel (the adopter's canonical Telegram channel dir) is stored as a row
    field so a sibling's preflight can detect a SHARED channel (the double-poller footgun) it can't
    see via env. MERGE semantics: a re-register WITHOUT a (non-empty) --channel PRESERVES the row's
    existing channel — the whole-row replace below would otherwise silently drop it (e.g. a pull that
    doesn't re-pass the channel, or reconcile). The stored value is canonicalized (os.path.realpath)
    so the clash compare is apples-to-apples; empty ⇒ no channel key written (legacy-clean rows)."""
    repo = os.path.realpath(resolve_repo_dir(args))
    if not args.tag:
        die("adopters-register: --tag is required")
    version_dir = os.path.abspath(args.version_dir) if args.version_dir else repo
    # A non-empty --channel sets it (canonical); None/empty ⇒ MERGE (preserve whatever the row holds).
    new_channel = None
    _chan_arg = (getattr(args, "channel", None) or "").strip()
    if _chan_arg:
        new_channel = os.path.realpath(_chan_arg)
    rpath = _registry_path(args)
    with _registry_lock(rpath):                       # Fix D — serialize the RMW (no lost update)
        reg = _load_registry(rpath)
        existing_channel = ""
        for a in reg["adopters"]:
            if _canon_repo(a.get("repo")) == repo:   # blank/missing repo ⇒ '' ≠ repo → no phantom self-match
                existing_channel = (a.get("channel") or "")     # MERGE source
                break
        channel = new_channel if new_channel is not None else existing_channel
        row = {"repo": repo, "tag": args.tag, "version_dir": version_dir}
        if channel:
            row["channel"] = channel
        for i, a in enumerate(reg["adopters"]):
            if _canon_repo(a.get("repo")) == repo:   # blank/missing repo ⇒ '' ≠ repo → no phantom self-match
                reg["adopters"][i] = row
                break
        else:
            reg["adopters"].append(row)
        _save_registry(rpath, reg)
    print("adopters-register: %s → tag=%s version_dir=%s channel=%s  [%s]"
          % (repo, args.tag, version_dir, channel or "-", rpath))
    return 0


def cmd_adopters_remove(args):
    """Remove THIS adopter's row (keyed by realpath(repo)). A missing registry / row = idempotent."""
    repo = os.path.realpath(resolve_repo_dir(args))
    rpath = _registry_path(args)
    if not os.path.exists(rpath):
        print("adopters-remove: no registry at %s — nothing to remove (idempotent)" % rpath)
        return 0
    with _registry_lock(rpath):                       # Fix D — serialize the RMW (no lost update)
        reg = _load_registry(rpath)
        before = len(reg["adopters"])
        # NEVER realpath('') (→ CWD): blank/missing repo ⇒ '' ≠ repo → kept (never phantom-removed)
        reg["adopters"] = [a for a in reg["adopters"] if _canon_repo(a.get("repo")) != repo]
        removed = len(reg["adopters"]) != before
        if removed:
            _save_registry(rpath, reg)
    if removed:
        print("adopters-remove: removed %s  [%s]" % (repo, rpath))
    else:
        print("adopters-remove: %s not in the registry — nothing to remove (idempotent)" % repo)
    return 0


def cmd_adopters_siblings(args):
    """Print the tag of each OTHER adopter (repo != this) pinned at a DIFFERENT tag than --tag, one
    per line. EMPTY output ⇒ no sibling needs a different version → this adopter keeps the root
    clone. `kickoff pull` reads this to decide whether to park a per-tag worktree."""
    repo = os.path.realpath(resolve_repo_dir(args))
    if not args.tag:
        die("adopters-siblings: --tag is required")
    rpath = _registry_path(args)
    if not os.path.exists(rpath):
        return 0
    reg = _load_registry(rpath)
    seen = []
    for a in reg["adopters"]:
        if _canon_repo(a.get("repo")) == repo:   # blank/missing repo ⇒ '' ≠ repo → no phantom self-match
            continue
        t = a.get("tag")
        if t and t != args.tag and t not in seen:
            seen.append(t)
    for t in seen:
        print(t)
    return 0


def _canon_repo(r):
    """Canonicalize an adopter-row repo path for equality, mirroring _canon_channel. CRITICAL: NEVER
    os.path.realpath('') — it returns the CWD, so a corrupt row with a missing/empty/blank (or non-
    string) repo would PHANTOM-MATCH (the CWD, or even 'self' when the caller's CWD is this repo).
    Non-string/blank ⇒ '' so callers' existing `if not rp` / `== repo` guards correctly skip it."""
    if not isinstance(r, str):
        return ""
    r = r.strip()
    return os.path.realpath(r) if r else ""


def cmd_adopters_others(args):
    """Print the realpath of every OTHER adopter (repo != this) regardless of tag, one per line.
    EMPTY output ⇒ this repo is POSITIVELY the SOLE registered adopter → eject may remove the shared
    user-global plugin. This is the query eject's last-sibling gate needs, and it is DELIBERATELY NOT
    `adopters-siblings`: that filters to DIFFERENT-tag adopters (built for pull's worktree-parking
    decision, where same-tag siblings share the root clone and are intentionally hidden). But the
    user-global plugin CACHE is keyed by <mkt>/<plugin>/<version> and same-tag ⇒ same plugin.json
    version ⇒ the EXACT SAME cache dir — so a same-tag sibling MUST block removal. Counting ANY other
    adopter (any tag) is the only correct signal for 'is it safe to tear out the shared user-global
    plugin'. Missing registry ⇒ no other adopters recorded ⇒ empty (eject: sole)."""
    repo = os.path.realpath(resolve_repo_dir(args))
    rpath = _registry_path(args)
    if not os.path.exists(rpath):
        return 0
    reg = _load_registry(rpath)
    seen = []
    for a in reg["adopters"]:
        rp = _canon_repo(a.get("repo"))          # NEVER realpath('') (→ CWD): blank/missing repo ⇒ '' → skipped
        if not rp or rp == repo or rp in seen:
            continue
        seen.append(rp)
    for rp in seen:
        print(rp)
    return 0


def cmd_adopters_self(args):
    """Exit 0 IFF THIS repo (realpath) is PRESENT in the registry (and print its realpath); exit 1 if
    it is absent OR the registry file is missing. A present-but-MALFORMED registry stays FATAL (rc2,
    via _load_registry). This is eject's Fix-D safety signal: tear out the shared user-global cache
    ONLY if the ejecting adopter is provably in its OWN registry — because register-at-adopt is best-
    effort, an ejecting adopter absent from its own registry is proof the registration path is
    unhealthy, so eject conservatively LEAVES (any non-zero exit here ⇒ not-proven ⇒ LEAVE)."""
    repo = os.path.realpath(resolve_repo_dir(args))
    rpath = _registry_path(args)
    if not os.path.exists(rpath):
        return 1
    reg = _load_registry(rpath)
    for a in reg["adopters"]:
        if _canon_repo(a.get("repo")) == repo:   # blank/missing repo ⇒ '' ≠ repo → no phantom self-match
            print(repo)
            return 0
    return 1


def _canon_channel(c):
    """Canonicalize a channel-dir string for equality: strip, then os.path.realpath (resolves
    symlinks + trailing slash/./ ..), matching how repos are keyed. Empty/blank ⇒ '' (no channel)."""
    c = (c or "").strip()
    return os.path.realpath(c) if c else ""


def cmd_adopters_channel_clash(args):
    """Print the realpath of every OTHER adopter (repo != this) whose NON-EMPTY canonical channel
    equals MINE, one per line. EMPTY output ⇒ no clash. 'Mine' = an explicit --channel (the caller's
    FRESH instance.env value — what preflight passes) when given, else THIS repo's stored row channel.
    A missing registry / an empty 'mine' ⇒ empty (nothing to clash on). This backs preflight #2's
    registry-side sub-check: two SEPARATE repos on one box that each set a DEDICATED channel dir in
    their OWN instance.env are invisible to each other via env (ORIGIN/OPERATOR_STATE_DIR are never
    set), but BOTH are recorded here — a shared channel ⇒ two getUpdates pollers fighting one bot
    token (the double-poller footgun)."""
    repo = os.path.realpath(resolve_repo_dir(args))
    rpath = _registry_path(args)
    if not os.path.exists(rpath):
        return 0
    reg = _load_registry(rpath)
    mine = _canon_channel(getattr(args, "channel", None))
    if not mine:
        for a in reg["adopters"]:
            if _canon_repo(a.get("repo")) == repo:   # blank/missing repo ⇒ '' ≠ repo → no phantom self-match
                mine = _canon_channel(a.get("channel"))
                break
    if not mine:
        return 0
    seen = []
    for a in reg["adopters"]:
        rp = _canon_repo(a.get("repo"))          # NEVER realpath('') (→ CWD): blank/missing repo ⇒ '' → skipped
        if not rp or rp == repo or rp in seen:
            continue
        if _canon_channel(a.get("channel")) == mine:
            seen.append(rp)
    for rp in seen:
        print(rp)
    return 0


def build_parser():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--repo", default=None,
                        help="adopter repo dir (overrides $REPO_DIR; default = the repo this script lives in)")

    p = argparse.ArgumentParser(prog="adopt-manifest.py", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd")

    r = sub.add_parser("record", parents=[common], help="append one entry (a recorded touch)")
    r.add_argument("--path", required=True, help="repo-relative path that was touched")
    r.add_argument("--action", required=True, help="one of: %s" % ", ".join(ACTIONS))
    r.add_argument("--class", dest="klass", required=True, help="one of: %s" % ", ".join(CLASSES))
    r.add_argument("--source", required=True, help="e.g. core-v0.2 or authored-for-repo")
    r.add_argument("--original-from", dest="original_from", default=None,
                   help="path to the saved verbatim PRE-EDIT bytes "
                        "(required for modified/block-appended/json-merged; forbidden otherwise)")
    r.add_argument("--jq-path", dest="jq_path", action="append", default=None,
                   help="a JSON path touched (repeatable; hook-installed only)")
    r.add_argument("--hook-sha256", dest="hook_sha256", action="append", default=None,
                   help="sha256 of `jq -S -c '<jq_path>' <file>` for the hook at that jq-path "
                        "(repeatable; REQUIRED 1:1 with --jq-path for hook-installed). Never the "
                        "file's bytes — a content hash, so eject removes the hook by identity.")
    r.set_defaults(func=cmd_record)

    g = sub.add_parser("gen-shim", parents=[common], help="generate a SEAM shim (§1.4) + record it created/seam")
    g.add_argument("--name", required=True, help="shim to generate (known: %s)" % ", ".join(sorted(SHIM_TEMPLATES)))
    g.add_argument("--source", required=True, help="e.g. core-v0.2 — stamps the seam's provenance")
    g.set_defaults(func=cmd_gen_shim)

    gc = sub.add_parser("gen-charter", parents=[common],
                        help="generate the split coordinator charter: .kickoff/KICKOFF.md (seam) + "
                             ".kickoff/KICKOFF.local.md (seeded-instance, adopter-owned)")
    gc.add_argument("--source", required=True, help="e.g. core-v0.2 — stamps the seam's provenance")
    gc.set_defaults(func=cmd_gen_charter)

    gg = sub.add_parser("gen-gitignore", parents=[common],
                        help="generate .kickoff/.gitignore (seam) from the pinned template + record it created/seam")
    gg.add_argument("--source", required=True, help="e.g. core-v0.2 — stamps the seam's provenance")
    gg.set_defaults(func=cmd_gen_gitignore)

    gr = sub.add_parser("gen-readme", parents=[common],
                        help="generate .kickoff/README (seam) from the pinned template + record it created/seam")
    gr.add_argument("--source", required=True, help="e.g. core-v0.2 — stamps the seam's provenance")
    gr.set_defaults(func=cmd_gen_readme)

    rcn = sub.add_parser("reconcile", parents=[common],
                         help="G9: generate the manifest for an ALREADY-adopted, manifest-less repo "
                              "WITHOUT re-wiring — records ONLY provable artifacts (template-byte-"
                              "matching seams + the settings.json plugin metadata); everything else "
                              "is report-only; REFUSES an existing manifest; writes NOTHING but the "
                              "manifest itself")
    rcn.add_argument("--source", required=True,
                     help="e.g. core-v0.2 — stamps each proven entry's provenance (the tag whose "
                          "templates the byte-match proved against)")
    rcn.add_argument("--core-dir", dest="core_dir", default=None,
                     help="the pinned core clone — its plugin/.claude-plugin/ manifests PROVE which "
                          "marketplace/plugin names are kickoff's (absent → plugin keys stay report-only)")
    rcn.set_defaults(func=cmd_reconcile)

    pr = sub.add_parser("plugin-record", parents=[common],
                        help="record ONE machine-level plugin entry (schema v2, §5 THE PLUGIN) — "
                             "the user-global marketplace+enable touch; upsert by (marketplace, plugin)")
    pr.add_argument("--marketplace", required=True, help="the marketplace name (e.g. kickoff-local)")
    pr.add_argument("--plugin", required=True, help="the plugin name (e.g. kickoff)")
    pr.add_argument("--scope", required=True, help="enable scope: %s" % ", ".join(MACHINE_SCOPES))
    pr.add_argument("--marketplace-source", dest="marketplace_source", required=True,
                    help="the machine clone-path the marketplace was added from (e.g. ~/kickoff-core/plugin) "
                         "— a MACHINE path by design (outside the repo), stored as metadata only")
    pr.add_argument("--source", required=True, help="e.g. core-v0.2 — provenance stamp for the machine entry")
    pr.set_defaults(func=cmd_plugin_record)

    pl = sub.add_parser("plugin-list", parents=[common],
                        help="print machine_entries[] as TSV (kind<TAB>marketplace<TAB>plugin<TAB>"
                             "scope<TAB>marketplace_source) for the bash callers; EMPTY ⇒ skip the plugin step")
    pl.set_defaults(func=cmd_plugin_list)

    pcv = sub.add_parser("plugin-cache-verify", parents=[common],
                         help="verify each recorded plugin's USER-GLOBAL cache snapshot byte-matches the "
                              "pinned <core-dir>/plugin/ (§5, preflight #8); non-zero on drift/missing")
    pcv.add_argument("--core-dir", dest="core_dir", required=True,
                     help="the pinned core clone (the plugin lives at <core-dir>/plugin/)")
    pcv.add_argument("--config-dir", dest="config_dir", required=True,
                     help="the Claude config dir (the cache lives at <config-dir>/plugins/cache/<mkt>/<plugin>/<version>/)")
    pcv.set_defaults(func=cmd_plugin_cache_verify)

    pco = sub.add_parser("plugin-consumers-others", parents=[common],
                         help="print every OTHER consumer row of <plugin>@<marketplace> in "
                              "<config-dir>/plugins/installed_plugins.json (G7's install-row "
                              "sole-consumer gate); EMPTY+rc0 ⇒ this repo is the SOLE interactive "
                              "consumer → a scoped uninstall/reinstall sweeps only its own cache; "
                              "corrupt/unreadable file ⇒ FATAL (never provably sole)")
    pco.add_argument("--config-dir", dest="config_dir", required=True,
                     help="the Claude config dir (installed_plugins.json lives at <config-dir>/plugins/)")
    pco.add_argument("--marketplace", required=True, help="the marketplace name (e.g. kickoff-local)")
    pco.add_argument("--plugin", required=True, help="the plugin name (e.g. kickoff)")
    pco.set_defaults(func=cmd_plugin_consumers_others)

    ar = sub.add_parser("adopters-register", parents=[common],
                        help="upsert this adopter's row {repo, tag, version_dir} in the machine adopters registry")
    ar.add_argument("--tag", required=True, help="the core-v* tag this adopter is pinned at")
    ar.add_argument("--version-dir", dest="version_dir", default=None,
                    help="the core checkout this adopter uses (default: the repo dir)")
    ar.add_argument("--channel", default=None,
                    help="this adopter's Telegram channel dir (stored canonical; MERGE: omitting/empty "
                         "PRESERVES the row's existing channel). Backs the preflight #2 clash sub-check")
    ar.add_argument("--registry", default=None,
                    help="registry path (default: $KICKOFF_ADOPTERS_REGISTRY or ~/.kickoff/adopters.json)")
    ar.set_defaults(func=cmd_adopters_register)

    arm = sub.add_parser("adopters-remove", parents=[common],
                         help="remove this adopter's row from the adopters registry (eject)")
    arm.add_argument("--registry", default=None, help="registry path override")
    arm.set_defaults(func=cmd_adopters_remove)

    asib = sub.add_parser("adopters-siblings", parents=[common],
                          help="print tags of OTHER adopters pinned at a DIFFERENT tag than --tag")
    asib.add_argument("--tag", required=True, help="this adopter's target tag")
    asib.add_argument("--registry", default=None, help="registry path override")
    asib.set_defaults(func=cmd_adopters_siblings)

    aoth = sub.add_parser("adopters-others", parents=[common],
                          help="print the repo of every OTHER adopter (ANY tag); EMPTY ⇒ this repo is "
                               "the SOLE adopter → eject may remove the shared user-global plugin")
    aoth.add_argument("--registry", default=None, help="registry path override")
    aoth.set_defaults(func=cmd_adopters_others)

    aself = sub.add_parser("adopters-self", parents=[common],
                           help="exit 0 IFF THIS repo is present in the registry (eject Fix-D safety "
                                "gate: only tear out the shared cache if the ejecting adopter is "
                                "provably registered); absent or missing registry ⇒ exit 1")
    aself.add_argument("--registry", default=None, help="registry path override")
    aself.set_defaults(func=cmd_adopters_self)

    acc = sub.add_parser("adopters-channel-clash", parents=[common],
                         help="print OTHER adopters whose canonical Telegram channel == this repo's "
                              "(preflight #2 double-poller guard); EMPTY ⇒ no clash")
    acc.add_argument("--channel", default=None,
                     help="use THIS channel as 'mine' (preflight passes its fresh instance.env value); "
                          "default: this repo's stored row channel")
    acc.add_argument("--registry", default=None, help="registry path override")
    acc.set_defaults(func=cmd_adopters_channel_clash)

    y = sub.add_parser("sync-seams", parents=[common],
                       help="regenerate manifest-listed seams from templates (pull); refuse hand-edited ones")
    y.add_argument("--source", default=None, help="the new tag (stamps regenerated seams' provenance)")
    y.add_argument("--force-regenerate", dest="force_regenerate", action="store_true",
                   help="DISCARD hand-edits and restore the pinned template (the escape hatch pull names)")
    y.set_defaults(func=cmd_sync_seams)

    v = sub.add_parser("verify", parents=[common], help="recompute every recorded hash; non-zero exit on drift")
    v.set_defaults(func=cmd_verify)

    s = sub.add_parser("show", parents=[common], help="render the manifest (metadata only)")
    s.set_defaults(func=cmd_show)

    rv = sub.add_parser("reverse", parents=[common],
                        help="EJECT engine: reverse every recorded touch (created→delete, "
                             "modified/block/json→byte-restore or surgical strip, hook→jq-del)")
    rv.add_argument("--dry-run", dest="dry_run", action="store_true",
                    help="print what WOULD be reversed; change nothing")
    rv.add_argument("--on-divergence", dest="on_divergence", choices=("keep", "delete"),
                    default="keep",
                    help="a created file whose hash drifted from the record: keep (DEFAULT — "
                         "never silent-delete) or delete (explicit policy only)")
    rv.add_argument("--purge-seeded", dest="purge_seeded", action="store_true",
                    help="ALSO reverse seeded-instance crew entries (kept by default) — hash-"
                         "gated + divergence-safe; the `kickoff eject --purge` path")
    rv.set_defaults(func=cmd_reverse)

    rf = sub.add_parser("reassert-file", parents=[common],
                        help="re-write a repo file to EXACT snapshot bytes via the hardened symlink-"
                             "safe atomic write — eject uses it to undo the plugin CLI's settings.json "
                             "re-serialization AFTER the byte-restore (never targets settings.local.json)")
    rf.add_argument("--path", required=True,
                    help="repo-relative path to re-assert (e.g. .claude/settings.json)")
    rf.add_argument("--from", dest="from_file", required=True,
                    help="the snapshot file whose exact bytes to re-assert onto --path")
    rf.set_defaults(func=cmd_reassert_file)

    rh = sub.add_parser("rehash-path", parents=[common],
                        help="re-record ONLY sha256_at_write for an ALLOWLISTED path "
                             "(.claude/settings.json) after kickoff's own legitimate write — the "
                             "pull-time marketplace re-point (G6) — so eject's hash gate stays TRUE; "
                             "never touches original/sha256_before_edit, never any other path")
    rh.add_argument("--path", required=True,
                    help="repo-relative path to re-hash (allowlisted: %s)" % ", ".join(REHASH_ALLOWED_PATHS))
    rh.set_defaults(func=cmd_rehash_path)

    return p


def main():
    parser = build_parser()
    args = parser.parse_args()
    if not getattr(args, "func", None):
        parser.print_help(sys.stderr)
        sys.exit(2)
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
