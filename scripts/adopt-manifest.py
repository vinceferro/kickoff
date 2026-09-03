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
import shlex
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
# pull. A MISSING engine yields a CLEAR message + non-zero exit, never a raw bash error — and
# the message DISTINGUISHES the two failures: a missing/pinned-core-dir (pull fixes it) from a
# resolving core that does not carry the component (the ratified public release line omits
# mission-control/ entirely — permanent, so the message names it and never suggests a pull).
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
# …and scrub the ambient data-path vars too: instance.env sets these as ${VAR:-default}, so a
# parent shell's exported value would WIN and silently route reads/writes into ANOTHER repo's
# board/tracker (reproduced live: one adopter's `mc render-tracker` rewrote a different repo's
# TRACKER.md). Explicit values written IN instance.env still win.
unset MC_STATE_FILE MC_TRACKER_FILE MEMORY_DB MEMORY_HOOK_LOG MEMORY_INDEX GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
[ -f "$_here/../instance.env" ] && . "$_here/../instance.env"
_engine_dir="${KICKOFF_CORE_DIR:-}"
_engine="$_engine_dir/mission-control/mc-update.py"
if [ ! -f "$_engine" ]; then
  if [ -n "$_engine_dir" ] && [ -d "$_engine_dir" ]; then
    # The pinned core RESOLVES but does not carry this component: the ratified public release
    # line ships WITHOUT mission-control/, so `kickoff pull` can NEVER fix this. Name the real
    # state; never point the reader at a fix that cannot work. Still fails closed (rc 1).
    printf 'this pinned core does not ship Mission Control (the public release line omits it) — MC status writes are unavailable through this shim; see .kickoff/README\\n' >&2
  else
    printf 'kickoff engine not present — see .kickoff/README\\n' >&2
  fi
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
# …and scrub the ambient data-path vars too: instance.env sets these as ${VAR:-default}, so a
# parent shell's exported value would WIN and silently route reads/writes into ANOTHER repo's
# board/tracker (reproduced live: one adopter's `mc render-tracker` rewrote a different repo's
# TRACKER.md). Explicit values written IN instance.env still win.
unset MC_STATE_FILE MC_TRACKER_FILE MEMORY_DB MEMORY_HOOK_LOG MEMORY_INDEX GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
[ -f "$_here/../instance.env" ] && . "$_here/../instance.env"
_engine_dir="${KICKOFF_CORE_DIR:-}"
_engine="$_engine_dir/scripts/scan-secrets.sh"
if [ ! -f "$_engine" ]; then
  if [ -n "$_engine_dir" ] && [ -d "$_engine_dir" ]; then
    # Unlike mission-control/, the scanners travel on the public release line — so a resolving
    # core that lacks this component is an INCOMPLETE clone, and `kickoff pull` genuinely fixes
    # it. Name the state precisely either way (dir missing vs component missing).
    printf 'pinned core present but missing scripts/scan-secrets.sh — run `kickoff pull` (see .kickoff/README)\\n' >&2
  else
    printf 'kickoff engine not present — run `kickoff pull` (see .kickoff/README)\\n' >&2
  fi
  exit 1
fi
# scan THIS repo, not the caller's cwd — the engine lists files via `git ls-files` from CWD,
# so without the cd the shim scanned whatever directory it happened to be called from.
#
# WORKSPACE MEMBER: when kickoff is mounted on a workspace ROOT (N sibling checkouts adopted as one
# org), a member's git hook calls this shim from inside that member. cd-ing to the root there fans
# the scan across every sibling AND scores THIS member's commit on other repos' staged files — a
# member could not commit because a neighbour had a secret staged. So in that topology only, scan
# the CALLER's repo.
# TWO SPELLINGS OF "THIS IS A WORKSPACE ROOT", because a root may now be a git repo AND a workspace:
# the root is not itself a repo (the original shape), OR it carries the explicit `.kickoff/workspace`
# marker. Without the marker a git root reads as single-repo, which is exactly what would send a
# member's pre-commit to scan the ROOT's index instead of its own — a silent false green on every
# member commit. A single-repo adopt CANNOT take this branch: its REPO_DIR is a git repo's root and
# has no marker, so the guard below is false and the cd is byte-for-byte the old behaviour.
_ws_target="$REPO_DIR"
_root_top="$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$_root_top" ] && _root_top="$(cd "$_root_top" 2>/dev/null && pwd -P || printf '%s' "$_root_top")"
_root_p="$(cd "$REPO_DIR" 2>/dev/null && pwd -P || printf '%s' "$REPO_DIR")"
if [ "$_root_top" != "$_root_p" ] || [ -f "$_root_p/.kickoff/workspace" ]; then
  # `pwd -P` on BOTH sides: --show-toplevel is physical while REPO_DIR is logical, and a symlinked
  # workspace would otherwise miss the prefix and silently fall back to the root fan-out.
  _caller_top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$_caller_top" ] && _caller_top="$(cd "$_caller_top" 2>/dev/null && pwd -P || printf '%s' "$_caller_top")"
  case "$_caller_top" in
    "$_root_p"/*) _ws_target="$_caller_top" ;;
  esac
fi
cd "$_ws_target"
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
# …and scrub the ambient data-path vars too: instance.env sets these as ${VAR:-default}, so a
# parent shell's exported value would WIN and silently route reads/writes into ANOTHER repo's
# board/tracker (reproduced live: one adopter's `mc render-tracker` rewrote a different repo's
# TRACKER.md). Explicit values written IN instance.env still win.
unset MC_STATE_FILE MC_TRACKER_FILE MEMORY_DB MEMORY_HOOK_LOG MEMORY_INDEX GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
[ -f "$_here/../instance.env" ] && . "$_here/../instance.env"
_engine_dir="${KICKOFF_CORE_DIR:-}"
_engine="$_engine_dir/scripts/scan-structure.sh"
if [ ! -f "$_engine" ]; then
  if [ -n "$_engine_dir" ] && [ -d "$_engine_dir" ]; then
    # Unlike mission-control/, the scanners travel on the public release line — so a resolving
    # core that lacks this component is an INCOMPLETE clone, and `kickoff pull` genuinely fixes
    # it. Name the state precisely either way (dir missing vs component missing).
    printf 'pinned core present but missing scripts/scan-structure.sh — run `kickoff pull` (see .kickoff/README)\\n' >&2
  else
    printf 'kickoff engine not present — run `kickoff pull` (see .kickoff/README)\\n' >&2
  fi
  exit 1
fi
# scan THIS repo, not the caller's cwd — the engine lists files via `git ls-files` from CWD,
# so without the cd the shim scanned whatever directory it happened to be called from.
#
# WORKSPACE MEMBER: when kickoff is mounted on a workspace ROOT (N sibling checkouts adopted as one
# org), a member's git hook calls this shim from inside that member. cd-ing to the root there fans
# the scan across every sibling AND scores THIS member's push on other repos' files. So in that
# topology only, scan the CALLER's repo.
# TWO SPELLINGS OF "THIS IS A WORKSPACE ROOT", because a root may now be a git repo AND a workspace:
# the root is not itself a repo (the original shape), OR it carries the explicit `.kickoff/workspace`
# marker. A single-repo adopt CANNOT take this branch: its REPO_DIR is a git repo's root and has no
# marker, so the guard below is false and the cd is byte-for-byte the old behaviour.
_ws_target="$REPO_DIR"
_root_top="$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$_root_top" ] && _root_top="$(cd "$_root_top" 2>/dev/null && pwd -P || printf '%s' "$_root_top")"
_root_p="$(cd "$REPO_DIR" 2>/dev/null && pwd -P || printf '%s' "$REPO_DIR")"
if [ "$_root_top" != "$_root_p" ] || [ -f "$_root_p/.kickoff/workspace" ]; then
  # `pwd -P` on BOTH sides: --show-toplevel is physical while REPO_DIR is logical, and a symlinked
  # workspace would otherwise miss the prefix and silently fall back to the root fan-out.
  _caller_top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$_caller_top" ] && _caller_top="$(cd "$_caller_top" 2>/dev/null && pwd -P || printf '%s' "$_caller_top")"
  case "$_caller_top" in
    "$_root_p"/*) _ws_target="$_caller_top" ;;
  esac
fi
cd "$_ws_target"
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
    # the ADOPTER's opencode config — deliberately NOT the origin's own opencode.json, which pins
    # a model + provider (a provider that silently wedges sessions on boxes without its
    # credentials). The adopter template is pin-free: interactive sessions inherit the global
    # config; headless workers get OPENCODE_MODEL_* from instance.env (README-opencode.md).
    "opencode.json": "opencode.json",
}
_TEMPLATE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "templates")

# The charter TEMPLATE gen-agent renders a gap-filler from — lives at the CORE repo root
# (.claude/agent-charter-template.md), NOT under scripts/templates/. It is the SAME file the
# coordinator authors a new specialist from by hand; gen-agent mechanizes that so a gap-filler is
# correct-by-construction (least-privilege tools, a Report-to-MC section, the CANON block) every time.
_CORE_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_AGENT_CHARTER_TEMPLATE = os.path.join(_CORE_ROOT, ".claude", "agent-charter-template.md")

# The MAIN-CONVERSATION reporting canon (an output style reaches ONLY the main conversation —
# a subagent runs its own system prompt and never sees it; the subagent half of the same canon
# travels instead via the CANON block in .claude/agent-charter-template.md above, rendered
# verbatim into every gen-agent charter — see _render_agent_charter). Read directly from the
# CORE repo root (same idiom as _AGENT_CHARTER_TEMPLATE, not scripts/templates/), so ONE file
# is the source of truth for both the origin's own settings.json and every adopter's copy.
_OUTPUT_STYLE_PATH = ".claude/output-styles/plain-report.md"
_OUTPUT_STYLE_SRC = os.path.join(_CORE_ROOT, *_OUTPUT_STYLE_PATH.split("/"))

# ── the OPENCODE ENGINE-PARITY seam set (2026-08-28) ─────────────────────────────────────
# The origin runs BOTH engines (claude AND opencode — engine parity is a release gate), but
# adopt/pull wired only the claude half: an adopter's .opencode/ was hand-placed folklore no
# pull ever updated. These are the core-root sources (same `_read_core_root_file` idiom as the
# output style — ONE source of truth, the origin's own files), delivered verbatim EXCEPT the
# MODEL STANCE: a coordinator charter's `model:` pin wedges sessions SILENTLY on boxes without
# that provider's credentials, so it is STRIPPED at delivery for ADOPTERS ONLY (the origin's own
# files stay as-is). The regex mirrors the selftest fixture's own strip, byte-for-byte.
_OPENCODE_AGENTS = ("builder", "coordinator", "deployer", "planner", "reviewer")
_OPENCODE_PLUGINS = ("memory-search.js", "engine-credit.js")
_OPENCODE_AGENT_DIR = os.path.join(_CORE_ROOT, ".opencode", "agent")
_OPENCODE_PLUGIN_DIR = os.path.join(_CORE_ROOT, ".opencode", "plugins")
_MODEL_PIN_LINE_RE = re.compile(r"(?m)^\s*model\s*:.*\n")

# Every repo-relative path the set delivers — the manifest/reconcile/sync enumeration.
_OPENCODE_SEAM_PATHS = tuple(
    [".opencode/agent/%s.md" % n for n in sorted(_OPENCODE_AGENTS)]
    + [".opencode/plugins/%s" % p for p in sorted(_OPENCODE_PLUGINS)]
    + ["opencode.json"]
)


def opencode_set_present():
    """Does THIS core carry the opencode engine-parity set? A core predating the set (or a
    stripped fixture core) delivers nothing — callers SKIP the way the plugin arm skips an
    absent plugin/, they never die on a world where the feature does not exist yet."""
    return os.path.isfile(os.path.join(_OPENCODE_AGENT_DIR, "coordinator.md")) and all(
        os.path.isfile(os.path.join(_OPENCODE_PLUGIN_DIR, p)) for p in _OPENCODE_PLUGINS)


def _strip_model_pin(text):
    """The adopter delivery stance: drop any YAML `model:` pin line. The origin keeps its own."""
    return _MODEL_PIN_LINE_RE.sub("", text)


def _opencode_agent_template(name):
    """The canonical ADOPTER bytes for one crew charter: the core-root file, model-pin-stripped."""
    if name not in _OPENCODE_AGENTS:
        die("unknown opencode agent '%s' — known: %s" % (name, ", ".join(sorted(_OPENCODE_AGENTS))))
    return _strip_model_pin(_read_core_root_file(os.path.join(_OPENCODE_AGENT_DIR, name + ".md")))

# A gap-filler name is BOTH a Mission-Control lane key AND a path component (.claude/agents/<name>.md):
# validate it hard (kebab-case, no metachars) so it can never traverse out of .claude/agents/.
_AGENT_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")

# --description / --domain are FREE TEXT, but they land in the YAML frontmatter of the emitted charter
# (verbatim, as `description: <val>` — and --domain feeds the default description). A NEWLINE or other
# control char in either would let an injected line (`\ntools: *\n---`) close the frontmatter EARLY and
# smuggle in a wildcard `tools:` BEFORE the template's least-privilege placeholder — defeating the exact
# correct-by-construction non-wildcard guarantee this generator exists to deliver. --name is hard-validated
# (:_AGENT_NAME_RE) for the same reason (it lands in structured output); these must be too. REJECT, never
# sanitize: a single-line value can't break out of its frontmatter line, so we forbid any control char
# (newline/CR/tab/etc). A colon or `---` WITHIN one line stays a scalar value and is fine.
_FRONTMATTER_CTRL_RE = re.compile(r"[\x00-\x1f\x7f]")


def _reject_frontmatter_ctrl(value, flag):
    """Die if a frontmatter-bound free-text value carries a control char (newline/CR/…) — the
    frontmatter-injection guard for gen-agent's --description/--domain. See _FRONTMATTER_CTRL_RE."""
    m = _FRONTMATTER_CTRL_RE.search(value)
    if m:
        die("%s must be a single line of text (no newlines/control chars) — it lands verbatim in the "
            "charter's YAML frontmatter, and an injected line could smuggle a wildcard `tools:` past the "
            "least-privilege guarantee. Got a control char (0x%02x) at offset %d."
            % (flag, ord(m.group()), m.start()))

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
    if norm == _OUTPUT_STYLE_PATH:
        return _read_core_root_file(_OUTPUT_STYLE_SRC)
    # the opencode engine-parity set (gen-opencode's sources, mirrored EXACTLY — reconcile's
    # byte-match must compare against the bytes gen-opencode actually delivers): crew charters
    # ship model-pin-stripped (the canonical ADOPTER bytes; the origin's own charters pin the
    # model), plugins verbatim from the core root. Without these, reconcile's `known` loop
    # hit the belt-and-braces `tmpl is None: continue` and silently recorded NOTHING for the
    # set (adopt-selftest lane 12f, 2026-08-28).
    if norm.startswith(".opencode/agent/") and norm.endswith(".md"):
        name = norm[len(".opencode/agent/"):-len(".md")]
        if name in _OPENCODE_AGENTS:
            return _opencode_agent_template(name)
    if norm.startswith(".opencode/plugins/"):
        pname = norm[len(".opencode/plugins/"):]
        if pname in _OPENCODE_PLUGINS:
            return _read_core_root_file(os.path.join(_OPENCODE_PLUGIN_DIR, pname))
    if norm.startswith(".opencode/agent/") and norm.endswith(".md"):
        name = norm[len(".opencode/agent/"):-len(".md")]
        if "/" not in name and name in _OPENCODE_AGENTS:
            return _opencode_agent_template(name)
    if norm.startswith(".opencode/plugins/") and norm.endswith(".js"):
        name = norm[len(".opencode/plugins/"):-len(".js")]
        if "/" not in name and name + ".js" in _OPENCODE_PLUGINS:
            return _read_core_root_file(os.path.join(_OPENCODE_PLUGIN_DIR, name + ".js"))
    return None


def _read_core_root_file(path):
    """Read a whole-file seam template that lives directly under the CORE repo root (not
    scripts/templates/) — the _AGENT_CHARTER_TEMPLATE / _OUTPUT_STYLE_SRC idiom. FATAL if
    absent — a pinned tag missing its own template is a broken core, not a silent skip."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except OSError as e:
        die("FATAL — core-root seam template missing: %s (%s) — is this a complete core checkout?" % (path, e))


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


# Vendor BOOKKEEPING the CLI writes INTO a cache version dir — not plugin content, and never present
# in the pinned $core/plugin/ tree it is compared against. Excluded on the CACHE side only (see the
# call site), because otherwise the drift check reports the vendor's own housekeeping as tampering.
#
# `.orphaned_at` (a millisecond epoch) is stamped when a cached version stops being referenced by a
# user-scope marketplace. kickoff's marketplace is registered PER-ADOPTER at project scope, so the
# box has no user-scope reference and the CLI orphans every cached kickoff version as a matter of
# course. Measured 2026-08-12: this single extra file put ALL SIX other orgs on this machine into a
# hard preflight failure at once — and preflight is fail-closed on supervisor start AND on every
# engine hop, so the next restart or the next `kickoff pull` would have taken each of them dark.
# Excluding it costs nothing a drift check was ever buying: it is CLI-authored, its content is a
# timestamp, and no plugin payload can hide in a name the core tree can never contain.
_CACHE_VENDOR_BOOKKEEPING = frozenset({".orphaned_at"})


def _fileset_manifest(base, ignore_top=frozenset()):
    """Sorted [(relpath, sha256hex), …] for every REGULAR file under `base` (a directory). Raises
    _CacheHashError on ANY symlink or out-of-tree resolution: a plugin cache/source tree is a
    byte-copy with no symlinks, so a symlink is anomalous AND a potential out-of-bounds read (a
    planted `cache/…/x → /etc/shadow` would otherwise be hashed) — refuse it. `base` is realpath'd so
    the _real_within containment compares like-for-like.

    `ignore_top` skips exact TOP-LEVEL names (never a glob, never nested): the exclusion is for known
    vendor bookkeeping and must not become a hiding place one directory down."""
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
            if rel == "" and e.name in ignore_top and e.is_file(follow_symlinks=False):
                continue
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
            # CACHE side only. The core tree above is hashed with NO exclusions — so a file the CLI
            # writes into its cache can be ignored, while the same name appearing in the pinned core
            # would still be seen and would still count as drift.
            cache_manifest = _fileset_manifest(cache_dir, ignore_top=_CACHE_VENDOR_BOOKKEEPING)
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


def cmd_gen_output_style(args):
    """Generate .claude/output-styles/plain-report.md into the adopter repo + record it
    created/seam. Copies the CORE's OWN reporting-canon output style verbatim (byte-identical —
    ONE source of truth, see _OUTPUT_STYLE_SRC), so `sync-seams` regenerates it on pull and
    preflight #8 whole-file-hashes it exactly like any other FILE seam. Mirrors
    cmd_gen_gitignore/cmd_gen_readme: symlink-safe write, upsert the receipt (idempotent — a
    re-run rewrites the seam + row rather than duplicating). 0644 (non-bin seam).

    An output style reaches the MAIN CONVERSATION ONLY (a subagent never sees it) — this call
    is HALF the wiring. The other half is the `.claude/settings.json` `outputStyle` key merge
    (see `_adopt_wire_output_style` in the `kickoff` CLI, which calls this generator then merges
    the key) and the CANON block already baked into every gen-agent-rendered charter."""
    repo = resolve_repo_dir(args)
    if not args.source:
        die("--source is required (e.g. core-v0.2) — it stamps the seam's provenance in the manifest")

    rel = _OUTPUT_STYLE_PATH
    abs_path = os.path.join(repo, *rel.split("/"))
    tmpl = _read_core_root_file(_OUTPUT_STYLE_SRC)

    mpath = manifest_path(repo)
    manifest = load_manifest(mpath)

    # ── NEVER clobber an adopter-owned file at this path ────────────────────────────────
    # This is the FIRST file seam we place inside the adopter's own `.claude/` namespace;
    # every earlier seam lived under `.kickoff/`, where pre-existence cannot happen, so no
    # guard existed. An adversarial fixture caught the consequence: an adopter who had
    # authored their own `plain-report.md` had it overwritten and recorded action=created,
    # so `eject` DELETED their file and left their tree dirty — while the console reported
    # a clean create. That is an undisclosed, irreversible write into a repo we do not own.
    # sync-seams' receipt-based hand-edit refusal cannot cover this: at first adopt there is
    # no receipt yet. Same shape as the KICKOFF.local.md no-clobber guard above.
    if os.path.lexists(abs_path):
        if not _real_within(repo, abs_path):
            die("refusing to touch an output style that resolves OUTSIDE the repo (symlink escape): %s" % abs_path)
        existing = None
        try:
            with open(abs_path, "rb") as f:
                existing = f.read()
        except OSError as exc:
            die("cannot read the existing output style at %s: %s" % (rel, exc))
        ours = tmpl.encode() if isinstance(tmpl, str) else tmpl
        if existing != ours:
            # Theirs, not ours (or ours, hand-edited). Leave it exactly as it is, record
            # nothing to reverse, and SAY SO at the moment it happens — disclosure is the
            # requirement, not a doc footnote.
            print("gen-output-style: LEFT AS-IS — %s already exists and is not ours; "
                  "your file is untouched and kickoff will not manage it. "
                  "To adopt the core style, move your file aside and re-run." % rel)
            # rc 3 = "left as-is, nothing written, nothing recorded". A DISTINCT code, not a
            # string the caller greps: the caller must be able to disclose what actually
            # happened even if this message is later reworded. rc 0 stays "wrote it",
            # non-zero-non-3 stays "failed".
            return 3
        # Byte-identical to the template: our own prior write. Fall through and re-record
        # (idempotent re-adopt), which is what the receipt upsert below is for.

    _write_seam(repo, abs_path, tmpl, mode=0o644)
    _upsert_entry(manifest, {"path": rel, "action": "created", "class": "seam",
                             "source": args.source, "sha256_at_write": sha256_file(abs_path)})
    save_manifest(mpath, manifest)
    print("gen-output-style: wrote %s (0644) + recorded created/seam [%s]  → %s" % (rel, args.source, mpath))
    return 0


def cmd_gen_opencode(args):
    """Generate the OPENCODE ENGINE-PARITY seam set into the adopter repo + record each file
    created/seam (2026-08-28). Delivers, from THIS core (same source as every other seam):
      • .opencode/agent/{builder,coordinator,deployer,planner,reviewer}.md — the crew charters,
        VERBATIM except the MODEL STANCE: any `model:` pin line is STRIPPED at delivery (the
        origin's own charters keep their pins; a pinned model silently wedges adopter sessions
        on boxes without that provider's credentials);
      • .opencode/plugins/{memory-search,engine-credit}.js — the two plugins, verbatim;
      • opencode.json — the ADOPTER template (scripts/templates/opencode.json), pin-free by
        design: the origin's own config pins a provider that wedges adopters; interactive
        sessions inherit the global config, headless workers get instance.env OPENCODE_MODEL_*;
      • AGENTS.md → CLAUDE.md — the pointer opencode.json's `instructions` reference (the
        origin's own shape). Recorded as a created/seam row carrying `symlink_target` and NO
        byte hash — a symlink's identity IS its target string — so verify + preflight #8 skip
        it (they hash bytes, and hashing THROUGH the link would false-drift on every CLAUDE.md
        edit) while eject reverses it by readlink-match.
    Mirrors cmd_gen_output_style's NEVER-CLOBBER idiom per file: a pre-existing file whose bytes
    differ is LEFT AS-IS, disclosed, and NOT recorded (an adopter's own .opencode/ is theirs —
    the "boxe folklore" shape); byte-identical pre-existence falls through and re-records
    (idempotent upsert, never duplicate rows). `kickoff adopt`/`doctor`/`pull` call this; after
    recording, `sync-seams` regenerates + preflight #8 hashes each file like any other seam."""
    repo = resolve_repo_dir(args)
    if not args.source:
        die("--source is required (e.g. core-v0.2) — it stamps the seam's provenance in the manifest")

    targets = [(".opencode/agent/%s.md" % n, _opencode_agent_template(n)) for n in _OPENCODE_AGENTS]
    targets += [(".opencode/plugins/%s" % p,
                 _read_core_root_file(os.path.join(_OPENCODE_PLUGIN_DIR, p))) for p in _OPENCODE_PLUGINS]
    targets += [("opencode.json", _read_file_seam_template(FILE_SEAM_TEMPLATES["opencode.json"]))]

    mpath = manifest_path(repo)
    manifest = load_manifest(mpath)

    wrote = kept = 0
    for rel, tmpl in targets:
        abs_path = os.path.join(repo, *rel.split("/"))
        ours = tmpl.encode("utf-8")
        if os.path.lexists(abs_path):
            if not _real_within(repo, abs_path):
                die("refusing to touch %s — it resolves OUTSIDE the repo (symlink escape): %s" % (rel, abs_path))
            if os.path.isdir(abs_path) and not os.path.islink(abs_path):
                print("gen-opencode: LEFT AS-IS — %s is a directory; kickoff will not manage it "
                      "(kept: not ours — move it aside and re-run to adopt the core set)" % rel)
                kept += 1
                continue
            try:
                with open(abs_path, "rb") as f:
                    existing = f.read()
            except OSError as exc:
                die("cannot read the existing file at %s: %s" % (rel, exc))
            if existing != ours:
                # Theirs, not ours (or ours, hand-edited). Leave it exactly as it is, record
                # nothing, and SAY SO — disclosure is the requirement, not a footnote.
                print("gen-opencode: LEFT AS-IS — %s already exists and is not ours; your file is "
                      "untouched and kickoff will not manage it (kept: not ours). To adopt the "
                      "core version, move your file aside and re-run." % rel)
                kept += 1
                continue
        _write_seam(repo, abs_path, tmpl, mode=0o644)
        _upsert_entry(manifest, {"path": rel, "action": "created", "class": "seam",
                                 "source": args.source, "sha256_at_write": sha256_file(abs_path)})
        wrote += 1

    # ── the AGENTS.md pointer (created ONLY when it can dangle-proof itself: CLAUDE.md present,
    #    link absent; a pre-existing AGENTS.md of any shape is NEVER touched) ──────────────────
    linked = 0
    link_abs = os.path.join(repo, "AGENTS.md")
    if os.path.lexists(link_abs):
        pass  # theirs (or ours, intact) — never clobber a root-level operator file
    elif os.path.isfile(os.path.join(repo, "CLAUDE.md")):
        if not _real_within(repo, link_abs):
            die("refusing to create AGENTS.md — it resolves OUTSIDE the repo (symlink escape)")
        os.symlink("CLAUDE.md", link_abs)
        _upsert_entry(manifest, {"path": "AGENTS.md", "action": "created", "class": "seam",
                                 "source": args.source, "symlink_target": "CLAUDE.md"})
        linked = 1
    else:
        print("gen-opencode: AGENTS.md pointer SKIPPED — no CLAUDE.md in this repo to point at "
              "(opencode.json's instructions reference it; create CLAUDE.md and re-run)")

    save_manifest(mpath, manifest)
    print("gen-opencode: %d file(s) written + recorded, %d kept (adopter-owned, left as-is), "
          "%d symlink row(s) [%s]  → %s"
          % (wrote, kept, linked, args.source, mpath))
    return 0


def _render_agent_charter(template_text, name, description):
    """Render a gap-filler charter from .claude/agent-charter-template.md — correct-by-construction.
    The template is: an intro prose block, then the actual charter inside a ``` fence (frontmatter +
    role + `## Report to Mission Control` + `## Boundaries` + `## Honest-stage`), then a
    `<!-- CANON:START … -->`/`<!-- CANON:END -->` block OUTSIDE the fence. We emit the fenced charter
    body (name/description filled, `<name>` placeholders substituted) followed by the CANON block —
    dropping ONLY the template's author-facing intro + fence markers. Preserving the template's own
    `tools:` line means the emitted charter is NON-WILDCARD by construction (the session narrows it
    per domain later); the Report-to-MC section + CANON block travel verbatim, so a rendered gap-filler
    can never ship missing its lane-streaming or its inherited quality bar."""
    lines = template_text.splitlines()

    # 1) the CANON block (from CANON:START through CANON:END, inclusive) — lives OUTSIDE the fence.
    canon_start = canon_end = None
    for i, ln in enumerate(lines):
        if "CANON:START" in ln:
            canon_start = i
        if "CANON:END" in ln:
            canon_end = i
            break
    if canon_start is None or canon_end is None or canon_end < canon_start:
        die("FATAL — agent charter template is missing its CANON block: %s" % _AGENT_CHARTER_TEMPLATE)
    canon_block = "\n".join(lines[canon_start:canon_end + 1])

    # 2) the fenced charter body: between the FIRST ``` line and the NEXT ``` line.
    fence_idxs = [i for i, ln in enumerate(lines) if ln.strip() == "```"]
    if len(fence_idxs) < 2:
        die("FATAL — agent charter template is missing its fenced charter body: %s" % _AGENT_CHARTER_TEMPLATE)
    body = lines[fence_idxs[0] + 1:fence_idxs[1]]

    # 3) fill the frontmatter name/description; substitute the remaining <name> placeholders (role +
    #    the Report-to-MC lane commands) so the emitted lane commands are runnable as-is.
    out = []
    did_name = did_desc = False
    for ln in body:
        if not did_name and ln.startswith("name:"):
            out.append("name: %s" % name); did_name = True; continue
        if not did_desc and ln.startswith("description:"):
            out.append("description: %s" % description); did_desc = True; continue
        out.append(ln)
    if not (did_name and did_desc):
        die("FATAL — agent charter template frontmatter lost its name:/description: line: %s"
            % _AGENT_CHARTER_TEMPLATE)
    body_text = "\n".join(out).replace("<name>", name)

    return body_text.rstrip("\n") + "\n\n" + canon_block.rstrip("\n") + "\n"


def cmd_gen_agent(args):
    """Generate a NEW gap-filler specialist charter into the adopter repo + record it as
    created/seeded-instance (adopter-owned: KEPT on a plain eject, PURGED on `eject --purge`).
    Slice 1's crew-probe.py VALIDATES which domains are uncoverd + what may be proposed; this is the
    GENERATOR the coordinator runs once the human approves a gap-filler for an uncovered domain.

    Correct-by-construction (rendered from .claude/agent-charter-template.md): the emitted `tools:`
    line is NON-WILDCARD (least-privilege — the session narrows it per domain), and the
    `## Report to Mission Control` section + the CANON quality-bar block are always present.

    NEVER CLOBBERS: if `.claude/agents/<name>.md` already exists, REFUSE (die). Unlike gen-shim (which
    upserts a SEAM it owns), a gap-filler charter — once written — is the ADOPTER's; overwriting it
    would break the 'mesh via hook, never edit their charters' invariant. Mirrors cmd_gen_charter's
    seeded-instance record + symlink-safe write."""
    repo = resolve_repo_dir(args)
    name = args.name
    if not _AGENT_NAME_RE.match(name):
        die("--name must be kebab-case (^[a-z0-9][a-z0-9-]{0,63}$), got: %r — it names a "
            "Mission-Control lane AND a file under .claude/agents/, so it is validated hard" % name)
    if not args.domain:
        die("--domain is required — the uncovered domain this gap-filler owns (from crew-probe.py)")
    if not args.source:
        die("--source is required (e.g. core-v0.9) — it stamps the charter's provenance in the manifest")
    # Frontmatter-injection guard: --domain + --description are free text but land in the emitted YAML
    # frontmatter (verbatim). Reject a newline/control char so an injected line can't close the
    # frontmatter early and smuggle a wildcard `tools:` past the least-privilege guarantee. (--name is
    # already hard-validated above for the same structural-output reason.)
    _reject_frontmatter_ctrl(args.domain, "--domain")
    if args.description is not None:
        _reject_frontmatter_ctrl(args.description, "--description")

    rel = ".claude/agents/%s.md" % name
    abs_path = os.path.join(repo, ".claude", "agents", "%s.md" % name)

    # HARD refuse-on-clobber (lexists → catches a dangling symlink too): gen-agent only CREATES new
    # gap-fillers. Editing an existing charter is out of scope — that is the adopter's file.
    if os.path.lexists(abs_path):
        die("REFUSING to clobber an existing charter: %s — gen-agent only CREATES new gap-fillers; "
            "editing/overwriting an existing agent's charter would break the 'mesh via hook, never "
            "edit their charters' invariant. Remove it first if you truly mean to regenerate." % rel)

    description = args.description or (
        "The %s specialist — owns %s for this repo (gap-filler; fill in scope before dispatch)."
        % (args.domain, args.domain))

    try:
        with open(_AGENT_CHARTER_TEMPLATE, "r", encoding="utf-8") as f:
            template_text = f.read()
    except OSError as e:
        die("FATAL — agent charter template missing: %s (%s) — is this a complete core checkout?"
            % (_AGENT_CHARTER_TEMPLATE, e))

    content = _render_agent_charter(template_text, name, description)
    _write_seam(repo, abs_path, content, mode=0o644)

    mpath = manifest_path(repo)
    manifest = load_manifest(mpath)
    _upsert_entry(manifest, {"path": rel, "action": "created", "class": "seeded-instance",
                             "source": args.source, "sha256_at_write": sha256_file(abs_path)})
    save_manifest(mpath, manifest)
    print("gen-agent: wrote %s (0644, seeded-instance for domain '%s') + recorded [%s]  → %s"
          % (rel, args.domain, args.source, mpath))
    return 0


# ── gen-upgrade-turnkey (v0.9 slice 2) ──────────────────────────────────────────────────────────
# THE INVARIANT: the emitted turnkey is POLICY-NEUTRAL. An upgrade changes the VERSION, never the
# model policy. The 2026-07-13 miss (memory/retarget-preserves-stale-policy-defaults.md): a
# HAND-retargeted turnkey carried `WORKER_MODEL="${UPG_MODEL:-fable}"` and clobbered an adopter's
# own MODEL=opus pin, pointing a LIVE worker at an exhausted model. The fix is structural, on three
# levels: (1) this generator has NO --model/--effort knob, so there is nothing to bake; (2) the
# template resolves the pin at RUN time from the adopter's OWN instance.env; (3) _assert_policy_
# neutral() re-reads the RENDERED text and REFUSES to emit if a model family was ever bound as the
# UPG_MODEL/UPG_EFFORT default — so even a hand-edit of the template cannot ship a clobbering turnkey.
_TURNKEY_TEMPLATE = "upgrade-turnkey.sh.tmpl"

# Fail-closed validation (REJECT, never sanitize) — this generator EMITS BASH the operator runs as
# himself, so every interpolated value is untrusted. shlex.quote ALONE is insufficient (a newline
# survives it); a regex ALONE is insufficient (a quote-safe value can still be nonsense). Do both.
# `\A…\Z`, never `^…$`: in python `$` ALSO matches just before a trailing newline, so `^core-v0\.23$`
# happily accepts "core-v0.23\n" — and that newline is the whole attack. A rendered header line is
# `# ship-@@VER@@.sh — publish @@TAG@@`; a version carrying a newline splits it and the remainder
# lands in EXECUTABLE position (observed: `line 4: .sh: command not found` from a rendered turnkey).
# Every value validator below is anchored with \Z for exactly that reason.
_TK_NAME_RE = re.compile(r"\A[a-z0-9][a-z0-9._-]{0,63}\Z")   # also an `ls` GLOB prefix → no metachars
_TK_VER_RE = re.compile(r"\Acore-v[0-9]+(\.[0-9]+){1,2}\Z")  # a release tag, never an arbitrary ref
_TK_ORG_RE = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}\Z")

# The lines that MUST survive rendering verbatim — the runtime read of the adopter's own pin AND
# the mirror-the-engine defaults. The MODEL default chain has NO baked family (empty ⇒ inherit the
# box, exactly as session-run.sh does); the EFFORT default is 'high' (session-run.sh's own default),
# NEVER 'xhigh'. Pinning these EXACT lines means a hand-edit back to the buggy `${_cur_model:-opus}`
# / `${_cur_effort:-xhigh}` form fails this presence check outright.
_TK_REQUIRED_LINES = (
    '_cur_model="$(read_env_var MODEL)"',
    '_cur_effort="$(read_env_var EFFORT)"',
    'WORKER_MODEL="${UPG_MODEL:-$_cur_model}"',
    'WORKER_EFFORT="${UPG_EFFORT:-${_cur_effort:-high}}"',
)
# Any model FAMILY, or any effort tier OTHER than the engine default 'high', bound as a `${…:-DEFAULT}`
# value ANYWHERE in the resolution chain is a BAKED policy — refuse to emit. This is the fix for the
# 2026-07-14 miss: the OLD guard `\$\{UPG_(?:MODEL|EFFORT):-(?!\$\{_cur_)` only rejected a family bound
# DIRECTLY as the UPG_* default, so the NESTED innermost form `${UPG_MODEL:-${_cur_model:-opus}}` — a
# family one level deeper — sailed through and imposed opus/xhigh on a DEFAULT (no-pin) adopter that
# the engine would run at inherit-box/high. 'high' is the ONE legal literal default (it is
# session-run.sh's own `--effort "${EFFORT:-high}"`); MODEL has NO legal literal default (an unset
# MODEL must inherit the box, so no family may ever appear after a `:-`).
_TK_MODEL_FAMILIES = ("opus", "sonnet", "haiku", "fable")
_TK_NONDEFAULT_EFFORTS = ("xhigh", "max", "low", "medium")   # 'high' is the ONE legal engine default
_TK_BAKED_POLICY_RE = re.compile(
    r":-\s*\$?\{?\s*(?:" + "|".join(_TK_MODEL_FAMILIES + _TK_NONDEFAULT_EFFORTS) + r")\b")


# ── shared turnkey-render guards (BOTH generators) ──────────────────────────────────────────────
# Every turnkey template opens with a HEADER of `#` comments above `set -uo pipefail` — the prose
# the operator actually reads. Interpolated values land IN it (@@SELF@@, @@PROV@@, @@VERDICT@@), so
# the header is not decoration: a value carrying a NEWLINE breaks out of its comment and the next
# line is EXECUTABLE. Not theory — `--out "$W/out/pwn"$'\n'"touch SYNTH-RCE"$'\n'"#.sh"` put a bare
# `touch SYNTH-RCE` at line 11 of a rendered ship turnkey, and running it with NO --push (a PREVIEW,
# the run the operator makes precisely BECAUSE it is safe) created the file. The value regexes are
# the first line; this assertion is the structural second one: whatever a validator ever lets
# through, nothing above `set -uo pipefail` may be anything but blank, the shebang, or a comment.
_TURNKEY_SET_LINE = "set -uo pipefail"


def _assert_header_inert(text, what):
    """Every line above `set -uo pipefail` must be INERT — blank, the shebang, or a `#` comment.
    Returns the index of that line: the header/code boundary both generators' guards split on."""
    lines = text.splitlines()
    try:
        hdr_end = lines.index(_TURNKEY_SET_LINE)
    except ValueError:
        die("REFUSING to emit a %s with no `%s` line — it is the boundary that tells the HEADER "
            "(the prose the operator reads) from the CODE, and an unset-tolerant turnkey acts "
            "silently on an empty variable." % (what, _TURNKEY_SET_LINE))
    for i, ln in enumerate(lines[:hdr_end]):
        s = ln.strip()
        if not s or s.startswith("#"):
            continue
        die("REFUSING to emit a %s whose HEADER carries an EXECUTABLE line at line %d:\n"
            "    %s\n"
            "  Everything above `%s` must be blank, the shebang, or a `#` comment. A line that is "
            "none of those is there because an interpolated value carried a NEWLINE and broke out "
            "of its comment — i.e. arbitrary code in a file the operator runs as himself, reached "
            "by a PREVIEW run that pushes nothing and is therefore trusted."
            % (what, i + 1, s[:100], _TURNKEY_SET_LINE))
    return hdr_end


# --out is the one interpolated value that is a PATH, and it lands in the header (@@SELF@@). Same
# posture as every other value: REJECT, never sanitize. Absolute (both generators abspath it first,
# so a relative arg is normalised before this sees it), no newline, no shell metacharacter, and it
# must end `.sh` — a turnkey is a script, and the extension is what the operator types.
_OUT_PATH_RE = re.compile(r"\A/[A-Za-z0-9._@+/-]{0,255}\.sh\Z")


def _validated_out_path(raw):
    """Normalise an --out to an absolute path and REFUSE anything that is not a plain script path."""
    out = os.path.abspath(os.path.expanduser(raw))
    if not _OUT_PATH_RE.match(out):
        die("--out %r is not a safe script path (absolute, ending '.sh', characters "
            "[A-Za-z0-9._@+/-] only — no newline, no shell metacharacter). It is interpolated into "
            "the emitted script's HEADER, so a newline there is not a bad filename: it is a line of "
            "CODE in a file the operator runs as himself, executed even on a --push-less PREVIEW. "
            "REFUSED, not escaped." % (out,))
    return out


def _assert_policy_neutral(text):
    """The structural guarantee, checked on the RENDERED bytes right before they are written: this
    generator physically cannot emit a turnkey that imposes a model policy on an adopter.
      • the runtime read of THEIR instance.env is present verbatim (and below read_env_var, whose
        subshell SOURCE is the engine's real parse — a sed/grep regex returns the LITERAL
        '${MODEL:-opus}' on the self-ref form scripts/instance.env.example ships);
      • nothing is bound as the ${UPG_MODEL:-…}/${UPG_EFFORT:-…} default except that runtime read;
      • PERMISSION_MODE is never persisted into instance.env (v0.7 G1 §2.3 — it is deliberately OFF
        the engine's _INSTANCE_ENV_WHITELIST: the autonomy grant flows argv/terminal-env ONLY, so a
        line there is a no-op that LOOKS like it works and arms autonomy the day the list widens).
      • the HEADER is INERT — every line above `set -uo pipefail` is blank, the shebang, or a `#`
        comment. @@SELF@@/@@PROV@@ land there, and a value carrying a newline puts a bare command
        in executable position (the --out hole, closed here for the whole CLASS rather than the one
        instance: this assertion holds even if a future value regex is loosened).
    HARD, not advisory: a turnkey that clobbers an adopter's pin bricks a live worker."""
    _assert_header_inert(text, "upgrade turnkey")
    for want in _TK_REQUIRED_LINES:
        if want not in text:
            die("REFUSING to emit a turnkey that lost the runtime policy read (missing: %s) — the "
                "template must resolve MODEL/EFFORT from the ADOPTER's instance.env at run time, "
                "never bake one. An upgrade changes the VERSION, never the model policy." % want)
    # Scan CODE lines only — a `#` comment cannot execute, and the template's own header legitimately
    # explains the bug shape. The danger is an ASSIGNMENT, which is never on a comment line.
    for i, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        if _TK_BAKED_POLICY_RE.search(line):
            die("REFUSING to emit a turnkey with a BAKED model/effort policy at line %d: %s\n"
                "  A model FAMILY, or an effort tier other than 'high', is bound as a ${…:-DEFAULT} "
                "ANYWHERE in the resolution chain (including the nested innermost `${_cur_*:-opus}` / "
                "`${_cur_*:-xhigh}` form). That imposes a durable policy: the 07-13 miss clobbered an "
                "adopter's MODEL=opus pin; its mirror image imposes opus/xhigh on a DEFAULT (no-pin) "
                "adopter the engine would run at inherit-box model / effort 'high'. The only legal "
                "MODEL default is the adopter's OWN pin (empty ⇒ inherit the box); the only legal "
                "EFFORT literal default is 'high' (session-run.sh's own)." % (i, line.strip()))
    if "persist_env_var PERMISSION_MODE" in text:
        die("REFUSING to emit a turnkey that persists PERMISSION_MODE into instance.env — it is "
            "deliberately OFF the engine's _INSTANCE_ENV_WHITELIST (v0.7 G1 §2.3). The autonomy "
            "grant flows argv / terminal env ONLY.")

    # the ordering the whole fix rests on: the policy read must live BELOW read_env_var's definition
    if text.index("read_env_var(){") > text.index('_cur_model="$(read_env_var MODEL)"'):
        die("REFUSING to emit a turnkey whose policy read precedes read_env_var()'s definition — "
            "that ordering accident is exactly what forced the broken sed read in the hand-written "
            "turnkeys.")


def _write_turnkey(abs_path, content, force, repo):
    """Write the turnkey to an ARBITRARY absolute path (default $HOME) — atomically, 0755.

    DELIBERATELY NOT _write_seam(): every sibling gen-* verb writes a seam INSIDE the adopter repo
    and records a manifest receipt, and _write_seam hard-refuses any path outside the repo. This
    turnkey is the OPPOSITE by design — it is an OPERATOR artifact that lands in $HOME, never in the
    adopter's tree, so it is NOT a seam, gets NO manifest entry, is NOT in FILE_SEAM_TEMPLATES, and
    `sync-seams`/preflight #8 must never see it. (Registering it as a file seam would make preflight
    hash a repo file that never exists → a fail-closed brick on EVERY adopter.) If you came here to
    "fix" the missing receipt: don't — the asymmetry is the point.

    That asymmetry is ENFORCED here, not merely documented: a --out inside `repo` would drop an
    untracked 0755 script into the tree the manifest is the ledger for — a file with no receipt, in
    the one place every seam/preflight check assumes has one. It used to be accepted (rc 0)."""
    rp = os.path.realpath(repo)
    op = os.path.realpath(os.path.dirname(abs_path) or ".")
    if op == rp or op.startswith(rp + os.sep):
        die("REFUSING to write a turnkey INSIDE the repo: %s is under %s.\n"
            "  A turnkey is an OPERATOR artifact: it lands outside the tree, carries NO manifest "
            "receipt, and is deliberately absent from FILE_SEAM_TEMPLATES. Writing one into the "
            "repo drops an untracked 0755 script where every seam check assumes a receipt exists. "
            "Pass an --out outside the repository." % (abs_path, rp))
    if os.path.lexists(abs_path) and not force:
        die("refusing to overwrite an existing turnkey: %s (pass --force). The operator's real, "
            "already-run turnkeys live at exactly this default path — clobbering one is not "
            "reversible for them." % abs_path)
    parent = os.path.dirname(abs_path)
    if not os.path.isdir(parent):
        die("--out parent directory does not exist: %s" % parent)
    fd, tmp = _open_secure_tmp(abs_path, suffix=".turnkey.tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
        os.chmod(tmp, 0o755)
        os.replace(tmp, abs_path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def cmd_gen_upgrade_turnkey(args):
    """Generate the operator's one-tap adopter upgrade script (v0.9 slice 2).

      adopt-manifest.py gen-upgrade-turnkey --repo <adopter> --name <slug> --version core-vX.Y[.Z]

    Emits `~/upgrade-<name>-to-<X.Y[.Z]>.sh` — the fail-closed, backup-taking, conjunctively-
    adjudicated, --rollback-able hop the v0.8.1 turnkeys proved, plus a READ-ONLY --dry-run.

    POLICY-NEUTRAL BY CONSTRUCTION (the whole point — see _assert_policy_neutral): there is no
    --model/--effort flag to bake, the emitted script reads the ADOPTER's own MODEL/EFFORT from
    THEIR .kickoff/instance.env at RUN time (defaulting only when genuinely unset), and the render
    is re-checked before it is written. The autonomy grant rides argv (`kickoff up --auto`), never
    instance.env.

    Everything derivable is DERIVED at run time by the emitted script — engine dir, current tag,
    commit, remote + its local-vs-network class (a baked class would LIE the moment the remote is
    re-pointed), MODEL/EFFORT. Args carry only the genuinely un-derivable: which adopter, what slug,
    which target tag. --repo must be a REGISTERED adopter (a turnkey aimed at a non-adopter would
    pull an engine into a random dir — a brick).

    Writes NOTHING into the adopter repo and records NO manifest receipt (see _write_turnkey)."""
    repo = resolve_repo_dir(args)
    repo = os.path.realpath(repo)

    name = args.name
    if not _TK_NAME_RE.match(name or ""):
        die("--name %r is not a safe slug (^[a-z0-9][a-z0-9._-]{0,63}$). It is interpolated into a "
            "BASH script AND used as an `ls` glob prefix, so shell metacharacters and globs are "
            "REFUSED, not escaped." % (name,))
    tag = args.version
    if not _TK_VER_RE.match(tag or ""):
        die("--version %r is not a core release tag (^core-v[0-9]+(\\.[0-9]+){1,2}$ — e.g. "
            "core-v0.8.1). An arbitrary git ref is refused: the turnkey adjudicates the pull on "
            "core.lock naming exactly this tag." % (tag,))
    org = args.org if args.org else name
    if not _TK_ORG_RE.match(org):
        die("--org %r is not a safe display name (^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$). It lands in "
            "a bash string; a `$(…)` there would RUN in the operator's shell." % (org,))

    if not os.path.isdir(repo):
        die("--repo is not a directory: %s" % repo)

    # The registry is the house key: only a REGISTERED adopter gets a turnkey.
    rpath = _registry_path(args)
    registry = _load_registry(rpath)
    row = None
    for a in registry.get("adopters", []):
        if _canon_repo(a.get("repo")) == repo:
            row = a
            break
    if row is None:
        die("--repo %s is NOT a registered adopter (%s). A turnkey aimed at a non-adopter would "
            "pull an engine into a random directory. Register it first (adopters-register) or "
            "point --registry at the right ledger." % (repo, rpath))

    # Provenance is COMMENT-ONLY. Reading the adopter's live MODEL here and baking it as a default
    # would re-create the exact stale-snapshot bug class — the emitted script reads it at RUN time.
    cur = row.get("tag")
    cur = cur if isinstance(cur, str) and _TK_VER_RE.match(cur) else "<unpinned>"
    prov = "generated %s · adopter pinned at %s · target %s (MODEL/EFFORT are read at RUN time)" % (
        time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), cur, tag)

    ver = tag[len("core-"):]                      # core-v0.8.1 → v0.8.1
    out = _validated_out_path(
        args.out or os.path.join(os.path.expanduser("~"), "upgrade-%s-to-%s.sh" % (name, ver)))

    bkp = "%s-upgrade-backup" % name
    pm = args.permission_mode
    up_args = "up --auto --detach" if pm == "auto" else "up --detach"
    grant_env = "PERMISSION_MODE=auto" if pm == "auto" else ""

    # Substitute with OPAQUE tokens + str.replace — never .format()/%/string.Template: bash is
    # saturated with `{`, `}`, `$` and `%`. *_Q tokens carry a shlex.quote'd value and are expanded
    # into their OWN `_DEF_*` var, never into a nested `${VAR:-word}` default (where `word` is STILL
    # EXPANDED — the concrete command-execution hole).
    text = _read_file_seam_template(_TURNKEY_TEMPLATE)
    for token, value in (
        ("@@ORG_Q@@", shlex.quote(org)),
        ("@@REPO_Q@@", shlex.quote(repo)),
        ("@@TAG_Q@@", shlex.quote(tag)),
        ("@@BKP_Q@@", shlex.quote(bkp)),
        ("@@GRANT_ENV@@", grant_env),
        ("@@UP_ARGS@@", up_args),
        ("@@PM@@", pm),
        ("@@NAME@@", name),
        ("@@VER@@", ver),
        ("@@TAG@@", tag),
        ("@@ORG@@", org),
        ("@@SELF@@", out),
        ("@@PROV@@", prov),
    ):
        text = text.replace(token, value)
    left = re.search(r"@@[A-Z_]+@@", text)
    if left:
        die("internal: unsubstituted template token %s — refusing to emit" % left.group(0))

    _assert_policy_neutral(text)

    # A syntax-broken one-tap run against a LIVE worker is a bricking path. No shellcheck on the
    # box; `bash -n` is the available validator — run it on the rendered text BEFORE writing.
    chk = subprocess.run(["bash", "-n"], input=text.encode("utf-8"),
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if chk.returncode != 0:
        die("REFUSING to write a turnkey that fails `bash -n`:\n%s"
            % chk.stderr.decode("utf-8", "replace").strip())

    _write_turnkey(out, text, args.force, repo)
    print("gen-upgrade-turnkey: wrote %s (0755)\n"
          "  adopter:  %s (registered, pinned at %s)\n"
          "  target:   %s\n"
          "  policy:   NEUTRAL — MODEL/EFFORT read from %s/.kickoff/instance.env at RUN time\n"
          "  autonomy: %s (argv only — never persisted into instance.env)\n"
          "  rehearse: bash %s --dry-run   (read-only)"
          % (out, repo, cur, tag, repo, up_args, out))
    return 0


# ── gen-ship-turnkey (v0.23) ────────────────────────────────────────────────────────────────────
# THE INVARIANT: a release turnkey states the REAL gate verdict beside the SHA it was MEASURED ON,
# and REFUSES to push a branch that is not that SHA.
#
# THE MISS THIS CLOSES (2026-07-25, release/core-v0.20): the ship turnkey's three preconditions —
# the branch still fast-forwards the remote's main, the tag does not exist, the plugin-version
# invariant holds — ALL PASS ON A STALE BRANCH. So a staged release sat for a full day carrying the
# very blocker its release was being held for, while the turnkey's own header advertised a gate run
# from a DIFFERENT commit. Three green checks and a confident header, and the thing on offer was not
# the thing that was tested. The verdict was true when it was written; it was a rumour by the time
# the operator read it.
#
# The fix is three things, and each one is asserted on the RENDERED bytes before they are written
# (_assert_ship_guards — the "correct by construction" pattern _assert_policy_neutral established):
#   1. GATED_AT — the SHA the gate certified is PINNED into the emitted script, and the script
#      REFUSES if the branch tip differs. It is verified AT GENERATION TIME too: a --gated-at that
#      does not resolve, or that is not the current tip of the release branch, DIES here. A turnkey
#      stamped with a SHA that was never the tip is the copied-claim bug in its birth form.
#   2. The header carries the verdict AND the gated SHA side by side, and the guard asserts the
#      header's SHA is the SAME one the pin refuses on — a header that can disagree with the pin is
#      exactly the artifact that shipped.
#   3. `--no-verify` on the two release pushes, with its justification comment. The repo's pre-push
#      runs the full declared battery; the release gate already ran those suites on a detached
#      worktree of the exact commit being pushed, so re-running costs a full pass per push AND runs
#      them against the DEV tree, which is not the thing being shipped. That is safe for ONE reason:
#      the freshness guard proved the tip is what the gate certified. The justification comment is
#      LOAD-BEARING, not decoration — it is the only thing that stops a future reader copying
#      `--no-verify` onto an ungated push — so the guard refuses any `--no-verify` push that is not
#      preceded by it, and refuses any `--no-verify` at all above the freshness refusal.
_SHIP_TEMPLATE = "ship-turnkey.sh.tmpl"

# Fail-closed validation (REJECT, never sanitize) — same posture as _TK_*: this generator EMITS BASH
# the operator runs as himself, so shlex.quote ALONE is insufficient (a newline survives it) and a
# regex ALONE is insufficient (a quote-safe value can still be nonsense). Do both, on every value.
# `\A…\Z` throughout — python's `$` also matches before a TRAILING NEWLINE, so `^…$` accepts
# "core-v0.23\n" and that newline breaks the rendered header line into executable position.
_SHIP_SHA_RE = re.compile(r"\A[0-9a-f]{40}\Z")           # a FULL sha — an abbrev can become ambiguous
_SHIP_BRANCH_RE = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._/-]{0,79}\Z")
# The verdict lands in a bash string AND in a `#` header line. Constrained to a printable one-liner
# with NO shell metacharacter, NO backtick, NO `$`, NO quote, NO `@` (which could forge a @@TOKEN@@)
# and NO newline (which would break the header out of its comment and into executable position).
_SHIP_VERDICT_RE = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9 ,.:;()\[\]/%+=-]{0,159}\Z")

# The lines that MUST survive rendering verbatim. Pinning the EXACT refusal condition means a
# hand-edit that softens it (`=` for `!=`, a `||` short-circuit, a `warn` instead of an exit) fails
# this presence check outright rather than silently shipping a turnkey that no longer refuses.
_SHIP_REFUSAL_LINE = 'if [ "$BRC" != "$GATED_AT" ]; then'
_SHIP_PREVIEW_GATE = 'if [ "$PUSH" -eq 0 ]; then'
_SHIP_JUSTIFY_ANCHOR = "# ── why these pushes skip the pre-push hook ──"
_SHIP_JUSTIFY_RULE = "Never `--no-verify` a push that was not gated."
# Phrases the justification must actually CONTAIN — so gutting the body while keeping the anchor
# (the shape a hurried edit takes) is refused too. Matched against the block with its comment
# markers stripped and its wrapping collapsed, so re-flowing the paragraph is fine; deleting the
# reasoning is not.
_SHIP_JUSTIFY_PHRASES = ("The release gate ALREADY ran", "the freshness guard proved")
_SHIP_GATED_AT_RE = re.compile(r'^GATED_AT="([0-9a-f]{40})"$', re.M)
# `[ \t]`, never `\s` — `\s` MATCHES A NEWLINE, so `^#\s+verdict:\s+(\S.*)$` happily spans two lines
# and reads the NEXT header line as the verdict. Caught by the 'header-verdict-blank' mutation lane:
# a header whose verdict had been emptied still "matched", on the `gated at:` line below it. A guard
# that can satisfy itself from the wrong line is not a guard.
_SHIP_HDR_VERDICT_RE = re.compile(r"^#[ \t]+verdict:[ \t]+(\S[^\n]*?)[ \t]*$", re.M)
_SHIP_HDR_SHA_RE = re.compile(r"^#[ \t]+gated at:[ \t]+([0-9a-f]{40})[ \t]*$", re.M)

# Detecting an irreversible command by `line.startswith("git push")` is one rename away from blind:
# `eval "git push …"`, `git -C . push` and `$GIT push` ALL sail past it, and all three are real ways
# to put a push above the --push gate. Match on the line's EXECUTABLE text instead — quoted literals
# blanked out, trailing comment dropped — so the PREVIEW block's `echo "  1. git push …"` reads as
# the prose it is, while `eval "git push …"` reads as the command it is.
_SHIP_QUOTED_RE = re.compile(r"'[^']*'|\"[^\"]*\"")
# `(?<![-\w])` and not plain `\b`: the argv parser's own `--push)` case arm and `--tags` flags are
# not commands, and a rule that trips on them would be tuned back off within a week.
_SHIP_PUSH_RE = re.compile(r"(?<![-\w])push\b")
_SHIP_TAG_RE = re.compile(r"(?<![-\w])tag\b")
_SHIP_GIT_RE = re.compile(r"\bgit\b")
_SHIP_EVAL_RE = re.compile(r"\beval\b")


def _ship_exec_text(line):
    """The part of a line that can EXECUTE: quoted literals blanked out (BLANKED, not deleted — two
    words must not fuse across the gap into a token neither of them was), then the trailing `#`
    comment dropped. A whole-line comment yields "", which is precisely MED-3: an `exit 1` inside a
    comment satisfied the old "the refusal must EXIT" scan, so a refusal that printed and fell
    through to the push was accepted."""
    s = _SHIP_QUOTED_RE.sub(lambda mo: " " * len(mo.group(0)), line)
    # bash's own rule: `#` opens a comment only at the START OF A WORD. A blind `s.find("#")` would
    # truncate at the `#` in `${x#y}` and drop everything after it — including a `push` — which is
    # fail-OPEN in a scan whose whole job is to notice one.
    h = next((k for k, c in enumerate(s) if c == "#" and (k == 0 or s[k - 1].isspace())), -1)
    return s if h < 0 else s[:h]


# Control operators that end one simple command and begin the next. A scan that looks at a whole
# LINE cannot tell `echo "git push …"` (prose) from `echo hi && git push` (a push); splitting into
# simple commands first is what makes the command WORD meaningful.
def _ship_drop_comment(line):
    """The line with its trailing `#` comment removed but its QUOTES INTACT (unlike
    `_ship_exec_text`, which blanks quoted spans). A `#` opens a comment only at the start of a
    word AND outside quotes — `git push "a#b"` has no comment, and `${x#y}` is not one either."""
    spans = [(mo.start(), mo.end()) for mo in _SHIP_QUOTED_RE.finditer(line)]
    for k, c in enumerate(line):
        if c != "#" or not (k == 0 or line[k - 1].isspace()):
            continue
        if any(a <= k < b for a, b in spans):
            continue
        return line[:k]
    return line






def _assert_executes_unconditionally(lines, idx, what):
    """Prove the line at `idx` RUNS — at top level, on every path — rather than merely being present.

    THIS IS BLOCKER 1. The old guard checked the refusal's TEXT (`lines.index(_SHIP_REFUSAL_LINE)`
    plus a substring scan for `exit 1`). Wrapping the whole block in
    `if [ "${SHIP_SKIP_FRESHNESS:-0}" = 0 ]; then … fi` left every literal byte IDENTICAL: the
    generator exited 0, the suite stayed 76 passed / 0 failed, and the emitted turnkey then printed
    "gated tree : 9513c01 matches the branch tip ✓" while the tip was 868a725 — and pushed an
    ungated commit and tag. A guard that reads bytes cannot see a predicate wrapped around them.

    Two independent facts, both structural:
      • ZERO INDENTATION — an indented line is inside something, full stop;
      • EVERY BLOCK OPENED ABOVE IT IS CLOSED — proven by BASH ITSELF. Feed bash the prefix ending
        just before this line and require it to parse. Anything still open (if / while / until /
        for / case / select / function / `{` / `(` / a heredoc) leaves that prefix syntactically
        INCOMPLETE and `bash -n` says so. A keyword table of ours can be out-argued by a shape we
        did not think of; bash's own parser cannot."""
    if lines[idx] != lines[idx].lstrip():
        die("REFUSING to emit a ship turnkey whose %s is INDENTED at line %d (%r). Indentation "
            "means it sits inside a block — i.e. it runs only when that block's condition holds. "
            "This line must execute on EVERY path, so it lives at column 0."
            % (what, idx + 1, lines[idx][:80]))
    prefix = "\n".join(lines[:idx]) + "\n"
    chk = subprocess.run(["bash", "-n"], input=prefix.encode("utf-8"),
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if chk.returncode != 0:
        die("REFUSING to emit a ship turnkey whose %s at line %d is NOT at top level — some block "
            "opened above it is still OPEN there, so it is CONDITIONAL:\n"
            "    %s\n"
            "  (proof: bash cannot parse the script truncated just above that line). A refusal "
            "wrapped in `if [ \"${SOME_VAR:-0}\" = 0 ]; then … fi` is byte-identical to a real one "
            "and ships an ungated push. Un-nest it."
            % (what, idx + 1, chk.stderr.decode("utf-8", "replace").strip()[:200]))


def _ship_line_index(lines, needle, what):
    """The index of the line that IS `needle` — allowing surrounding whitespace so an indented copy
    is caught by _assert_executes_unconditionally with a written message, rather than crashing out
    of `list.index` with a traceback. The prose is the product; a traceback is not."""
    i = next((k for k, ln in enumerate(lines) if ln.strip() == needle), None)
    if i is None:
        die("REFUSING to emit a ship turnkey in which %s (%s) does not appear as its own line. It "
            "is present in the text only as part of a longer line — inside a string, a comment, or "
            "an `eval` — which is not a guard, it is a mention of one." % (what, needle))
    return i


def _assert_ship_guards(text):
    """The structural guarantee, checked on the RENDERED bytes right before they are written: this
    generator physically cannot emit a ship turnkey that (a) would push a branch the gate never saw,
    (b) advertises a verdict measured somewhere else, or (c) carries `--no-verify` without the one
    argument that makes it legal. HARD, not advisory — the artifact this guards performs the single
    irreversible act in the release, and it is read once, at speed, by someone about to publish."""
    lines = text.splitlines()

    # ── 0. the render must be complete and syntactically real ────────────────────────────────────
    left = re.search(r"@@[A-Z_]+@@", text)
    if left:
        die("REFUSING to emit a ship turnkey with an unsubstituted template token (%s) — a literal "
            "'@@TOKEN@@' in a release script is a value the generator failed to supply, and bash "
            "would treat it as a bare word rather than fail." % left.group(0))
    # The header/code split — AND the assertion that the header is INERT. The split alone never
    # checked that: --out was interpolated into header lines 10-11 with no regex and no shlex.quote,
    # so a newline in it emitted a bare `touch SYNTH-RCE` at line 11 and a PREVIEW run executed it.
    hdr_end = _assert_header_inert(text, "ship turnkey")
    header = "\n".join(lines[:hdr_end])
    # It must PARSE — no shellcheck on the box; `bash -n` is the available validator. This runs
    # FIRST (it used to be last) because the top-level assertions below prove un-nestedness by
    # parsing PREFIXES of this text: on a file that does not parse at all, a prefix failure would be
    # blamed on nesting. A syntax error found mid-release strands a staged branch and no script.
    chk = subprocess.run(["bash", "-n"], input=text.encode("utf-8"),
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if chk.returncode != 0:
        die("REFUSING to write a ship turnkey that fails `bash -n`:\n%s\n"
            "  A syntax error here is discovered by the operator mid-release, with a staged branch "
            "and no script that ships it." % chk.stderr.decode("utf-8", "replace").strip())

    # ── 1. the GATED_AT pin and its refusal branch ───────────────────────────────────────────────
    m = _SHIP_GATED_AT_RE.search(text)
    if not m:
        die("REFUSING to emit a ship turnkey with no GATED_AT pin (a bare `GATED_AT=\"<40-hex>\"` "
            "line). Without the pin the three ordinary preconditions — fast-forwards main, tag is "
            "new, plugin invariant — ALL PASS ON A STALE BRANCH, which is how a release sat for a "
            "day carrying the very blocker it was held for.")
    pinned = m.group(1)
    if _SHIP_REFUSAL_LINE not in text:
        die("REFUSING to emit a ship turnkey that pins GATED_AT but never REFUSES on it (missing: "
            "%s). A recorded SHA that nothing compares against is a comment, not a guard — and it "
            "reads exactly like one that works." % _SHIP_REFUSAL_LINE)
    refusal_i = _ship_line_index(lines, _SHIP_REFUSAL_LINE, "the freshness refusal")
    _assert_executes_unconditionally(lines, refusal_i, "freshness refusal")
    # `_ship_exec_text`, not `in ln` — an `exit 1` inside a COMMENT is not an exit, and the old
    # substring scan happily accepted `  # note: we used to exit 1 here`.
    # Scoped to the refusal's OWN `if … fi`, not a 12-line window. A proximity scan accepted a
    # refusal whose real `exit 1` had been deleted and replaced by `[ -f /nonexistent ] && exit 1`
    # AFTER the `fi`: the window saw an `exit 1`, the branch printed and fell through, and the
    # turnkey pushed. The exit has to be on a path the refusal itself takes.
    fi_i = next((k for k in range(refusal_i + 1, len(lines))
                 if lines[k].strip() == "fi" and not lines[k][:1].isspace()), None)
    if fi_i is None:
        die("REFUSING to emit a ship turnkey whose freshness refusal at line %d never closes with a "
            "top-level `fi`. If the branch has no visible end, nothing can be proven about what "
            "runs inside it." % (refusal_i + 1))
    if not any("exit 1" in _ship_exec_text(ln) for ln in lines[refusal_i:fi_i]):
        die("REFUSING to emit a ship turnkey whose freshness refusal does not EXIT (no executable "
            "`exit 1` INSIDE its own branch, lines %d-%d — a mention in a comment, in a string, or "
            "after the `fi` does not count). A guard that prints and falls through to the push is "
            "worse than none: it produces a warning nobody reads and ships anyway."
            % (refusal_i + 1, fi_i + 1))

    # The refusal compares BRC against GATED_AT — so anything that REASSIGNS either between the pin
    # and the comparison silently makes the comparison true. Four confirmed variants shipped an
    # ungated tag with every gate green, e.g. `[ -f "$REPO/.ship-anyway" ] && BRC="$GATED_AT"` at
    # column 0 (invisible to the nesting proof) or a hatch keyed on a file rather than an env var
    # (invisible to the hostile-env lane). One assignment each, or the comparison means nothing.
    # Anywhere the assignment would START A SIMPLE COMMAND — not just column 0. The first version of
    # this rule anchored at `\A\s*` and every confirmed bypass walked straight through it, because
    # they all hang the assignment off a control operator: `[ -f "$REPO/.ship-anyway" ] && BRC=…`.
    for var in ("BRC", "GATED_AT"):
        pat = re.compile(r"(?:\A|[;&|(]|\bthen\b|\bdo\b|\belse\b|\{)\s*%s=" % var)
        assigns = [i for i, ln in enumerate(lines) if pat.search(_ship_exec_text(ln))]
        if len(assigns) != 1:
            die("REFUSING to emit a ship turnkey that assigns %s %d times (lines %s). The freshness "
                "refusal compares these two values, so a SECOND assignment anywhere is an override: "
                "`%s=\"$GATED_AT\"` makes the comparison pass on a branch that moved, and the "
                "operator-facing output is byte-identical to a real check passing."
                % (var, len(assigns), ", ".join(str(i + 1) for i in assigns) or "none", var))

    # A refusal that runs, exits, and is still defeated: redefining `exit` (or the commands the
    # refusal uses) turns the whole branch into a no-op that PRINTS THE FULL REFUSAL and then
    # pushes. Confirmed. Nothing in a ship turnkey has any business shadowing these.
    defs = {}
    for i, ln in enumerate(lines):
        fn = re.match(r"\A\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)", _ship_exec_text(ln))
        if not fn:
            continue
        name = fn.group(1)
        # Shadowing what the proof itself rests on. The turnkey legitimately defines its OWN helpers
        # (`die`, `say`) — but nothing may redefine the shell's exit, git, or test.
        if name in ("exit", "git", "return", "test", "["):
            die("REFUSING to emit a ship turnkey that redefines `%s` at line %d. Shadowing it makes "
                "every guard below decorative — a refusal can print in full and still fall through "
                "to the push, which is the one output an operator has no way to distrust."
                % (name, i + 1))
        if name in defs:
            die("REFUSING to emit a ship turnkey that defines `%s` twice (lines %d and %d). The "
                "second definition wins at run time, so a helper the guards rely on can be replaced "
                "with a no-op far from where it is used — the same override shape as a second "
                "assignment to GATED_AT." % (name, defs[name] + 1, i + 1))
        defs[name] = i

    # ── 2. the header states the REAL verdict and the SHA it was MEASURED ON ─────────────────────
    hv = _SHIP_HDR_VERDICT_RE.search(header)
    if not hv:
        die("REFUSING to emit a ship turnkey whose header carries no `verdict:` line. The operator "
            "reads the header, once, immediately before publishing — a turnkey that does not state "
            "what the gate actually said invites the reader to assume it said yes.")
    hs = _SHIP_HDR_SHA_RE.search(header)
    if not hs:
        die("REFUSING to emit a ship turnkey whose header states a verdict with no `gated at:` SHA "
            "beside it. A verdict without the commit it was measured on is a rumour — that is "
            "literally the artifact that advertised a gate run from a DIFFERENT commit for a day.")
    if hs.group(1) != pinned:
        die("REFUSING to emit a ship turnkey whose header SHA (%s) is NOT the SHA it refuses on "
            "(%s). This is the copied-claim bug exactly: the header says one commit was gated while "
            "the guard admits another. They must be the same string or the header is decoration."
            % (hs.group(1)[:12], pinned[:12]))

    # ── 3. --no-verify: never above the refusal, never without its justification ─────────────────
    # Quote-stripped, not a raw substring: the spelling `--no-""verify` contains no literal
    # `--no-verify` ANYWHERE in the source, yet bash runs one. Reading the raw substring meant the
    # justification requirement could be skipped entirely while the flag still reached git.
    def _mentions_nv(ln):
        """`--no-verify` as bash would see it. The spelling `--no-""verify` contains no literal
        `--no-verify` anywhere in the source, yet bash runs one — quote removal is the whole trick,
        so strip the quote characters and look again."""
        # The RAW line, comments included — a mention above the refusal is refused even in prose.
        return "--no-verify" in ln or "--no-verify" in ln.replace('"', "").replace("'", "")

    first_nv = next((i for i, ln in enumerate(lines) if _mentions_nv(ln)), None)
    if first_nv is not None and first_nv < refusal_i:
        die("REFUSING to emit a ship turnkey that mentions `--no-verify` at line %d, ABOVE the "
            "freshness refusal at line %d. The gate-skip is only defensible downstream of the proof "
            "that the tip is what the gate certified; anything above that line is an ungated push "
            "wearing a gated push's flag." % (first_nv + 1, refusal_i + 1))
    def _is_nv_push(ln):
        """A line that EXECUTES a `--no-verify` push. The flag is read off the RAW line (it may be
        inside the string an `eval` runs); the push is read off the EXECUTABLE text (so the PREVIEW
        block's `echo "  1. git push --no-verify …"` is prose, not a push)."""
        if not _mentions_nv(ln):
            return False
        ex = _ship_exec_text(ln)
        return bool(_SHIP_PUSH_RE.search(ex) or _SHIP_EVAL_RE.search(ex))

    nv_pushes = [i for i, ln in enumerate(lines) if _is_nv_push(ln)]
    # Gated on the FLAG, not on our ability to recognise the push that carries it. The old form
    # (`if nv_pushes:`, populated by startswith("git push")) meant an `eval "git push --no-verify"`
    # skipped the justification requirement ENTIRELY — the detector's blind spot silently disarmed
    # the check that the detector was there to trigger.
    if "--no-verify" in text or first_nv is not None:
        if _SHIP_JUSTIFY_ANCHOR not in text:
            die("REFUSING to emit a ship turnkey with a `--no-verify` push (line %d) and no "
                "justification block ('%s'). The comment is LOAD-BEARING, not decoration: it is the "
                "only thing standing between a future reader and copying this flag onto a push that "
                "nothing gated."
                % ((nv_pushes[0] if nv_pushes else first_nv) + 1, _SHIP_JUSTIFY_ANCHOR))
        anchor_i = next((i for i, ln in enumerate(lines)
                         if ln.startswith(_SHIP_JUSTIFY_ANCHOR)), None)
        if anchor_i is None:
            die("REFUSING to emit a ship turnkey whose `--no-verify` justification anchor ('%s') is "
                "not at the start of its own line — it is indented, or quoted inside something. An "
                "argument a reader has to go looking for is not an argument."
                % _SHIP_JUSTIFY_ANCHOR)
        block = []
        for ln in lines[anchor_i:]:
            if not ln.lstrip().startswith("#"):
                break
            block.append(ln.lstrip().lstrip("#").strip())
        block_text = " ".join(block)
        for want in _SHIP_JUSTIFY_PHRASES + (_SHIP_JUSTIFY_RULE,):
            if want not in block_text:
                die("REFUSING to emit a ship turnkey whose `--no-verify` justification lost its "
                    "reasoning (missing from the block: %r). A gutted comment that still opens with "
                    "the right heading is the worst version of this file: it LOOKS argued. The block "
                    "must say what the gate already ran, why re-running it would test the wrong tree, "
                    "and end on the flat rule '%s'" % (want, _SHIP_JUSTIFY_RULE))
        if nv_pushes and anchor_i > nv_pushes[0]:
            die("REFUSING to emit a ship turnkey whose `--no-verify` justification (line %d) comes "
                "AFTER the push it justifies (line %d). A reader scanning downward hits the flag "
                "first and the argument never." % (anchor_i + 1, nv_pushes[0] + 1))

    # ── 4. PREVIEW by default: no push command may sit above the --push gate ─────────────────────
    if _SHIP_PREVIEW_GATE not in text:
        die("REFUSING to emit a ship turnkey with no PREVIEW gate (missing: %s). Preview-by-default "
            "is what makes this file safe to run to find out what it does — without it the first "
            "run IS the irreversible one." % _SHIP_PREVIEW_GATE)
    gate_i = _ship_line_index(lines, _SHIP_PREVIEW_GATE, "the PREVIEW gate")
    # The gate shares the refusal's weakness exactly: a gate nested inside a condition is a gate
    # with a way around it. Same proof — column 0, and nothing open above it.
    _assert_executes_unconditionally(lines, gate_i, "PREVIEW gate")
    # Scan the EXECUTABLE text, not `startswith("git push")`: `eval "git push …"`, `git -C . push`
    # and `$GIT push` were all ACCEPTED above the gate by the old prefix match (plain `git push` was
    # the one form it caught — the positive control that made it look like it worked). Above the
    # gate nothing legitimately pushes, tags, or evals, so the rule up here is flat and total.
    # Scanned on the executable text AND on the same text with quote CHARACTERS removed — bash's own
    # quote removal keeps the word, so `git "push" …` really does push while blanking quoted spans
    # made it read as a bare `git`. That gap let a PREVIEW run (no `--push`) push to origin.
    #
    # DELIBERATELY NOT a bash-faithful tokeniser. This scan is a DRIFT detector — its job is to catch
    # a future edit that moves a push above the gate, not to out-argue someone hand-crafting an
    # evasion in a file they can already edit freely (anyone who can rewrite this template can also
    # delete this guard). The semantic proof lives where it belongs: the suite RUNS the emitted
    # artifact with no `--push` against a fixture remote and asserts the remote SHA is unchanged.
    # A text scan approximating bash will always have both false positives and false negatives; the
    # behavioural lane has neither.
    for i, ln in enumerate(lines[:gate_i]):
        ex = _ship_exec_text(ln)
        why = ("a push" if _SHIP_PUSH_RE.search(ex)
               else "an `eval` (which can push anything, opaquely)" if _SHIP_EVAL_RE.search(ex)
               else "a tag" if (_SHIP_GIT_RE.search(ex) and _SHIP_TAG_RE.search(ex))
               else None)
        if why:
            die("REFUSING to emit a ship turnkey that runs %s at line %d, ABOVE the --push gate at "
                "line %d:\n    %s\n  A preview that pushes is not a preview — and the preview run "
                "is the one the operator makes precisely because he believes it cannot do anything."
                % (why, i + 1, gate_i + 1, ln.strip()[:100]))


def cmd_gen_ship_turnkey(args):
    """Generate the operator's one-tap RELEASE script — the gated, freshness-pinned publish.

      adopt-manifest.py gen-ship-turnkey --branch release/core-vX.Y --version core-vX.Y \\
          --prev-version core-vX.Z --gated-at <40-hex> --verdict '<what the gate actually said>'

    Emits `~/.kickoff/ship-<vX.Y>.sh`: PREVIEW by default (pushes nothing), `--push` to
    fast-forward the remote's main, tag, and push the tag.

    REQUIRED args are only the genuinely un-derivable — which branch, which tag, which previous tag,
    which commit the gate certified, and what it said. Everything else is DERIVED: the repo, the
    remote, the public installer URL (from the remote at RUN time — a baked owner/repo slug lies the
    moment the remote is re-pointed), the installer sha, the plugin-version invariant.

    --gated-at is VERIFIED HERE, not trusted: it must be a full 40-hex SHA that RESOLVES in the repo
    AND equals the current tip of --branch. A turnkey stamped with a SHA that was never the tip is
    the copied-claim bug in its birth form — it would refuse forever, or worse, be 'fixed' by
    re-stamping it with whatever the tip happens to be, which is the original miss wearing a patch.

    Writes OUTSIDE the repo, records NO manifest receipt (see _write_turnkey)."""
    repo = os.path.realpath(resolve_repo_dir(args))
    if not os.path.isdir(os.path.join(repo, ".git")) and not os.path.isfile(os.path.join(repo, ".git")):
        die("--repo %s is not a git repository — the ship turnkey is generated FROM the release "
            "repo, because --gated-at is verified against that repo's branch tip." % repo)

    branch = args.branch
    if not _SHIP_BRANCH_RE.match(branch or "") or ".." in branch or branch.endswith(".lock") \
            or branch.startswith("/") or branch.endswith("/") or "//" in branch:
        die("--branch %r is not a safe ref name (^[A-Za-z0-9][A-Za-z0-9._/-]{0,79}$, no '..', no "
            "'.lock' suffix, no leading/trailing/doubled '/'). It is interpolated into a BASH script "
            "AND passed to git as a ref, so it is REFUSED, not escaped." % (branch,))
    tag = args.version
    if not _TK_VER_RE.match(tag or ""):
        die("--version %r is not a core release tag (^core-v[0-9]+(\\.[0-9]+){1,2}$ — e.g. "
            "core-v0.23). The tag this pushes is public and IRREVERSIBLE; an arbitrary ref is "
            "refused." % (tag,))
    prev = args.prev_version
    if not _TK_VER_RE.match(prev or ""):
        die("--prev-version %r is not a core release tag (^core-v[0-9]+(\\.[0-9]+){1,2}$). The "
            "emitted script diffs plugin/ against it to adjudicate the version invariant — a bad "
            "ref there makes that check pass VACUOUSLY." % (prev,))
    if prev == tag:
        die("--prev-version equals --version (%s). The plugin invariant would diff the tag against "
            "itself and always hold — a check that cannot fail." % tag)
    gated = args.gated_at
    if not _SHIP_SHA_RE.match(gated or ""):
        die("--gated-at %r is not a full 40-hex commit SHA. An abbreviation is refused on purpose: "
            "the pin is compared as a STRING against `git rev-parse <branch>`, so a short form would "
            "never match and the turnkey would refuse forever." % (gated,))
    verdict = args.verdict
    if not _SHIP_VERDICT_RE.match(verdict or ""):
        die("--verdict %r is not a constrained one-line verdict (^[A-Za-z0-9][A-Za-z0-9 ,.:;()[]"
            "/%%+=-]{0,159}$). It lands in a bash string AND in a `#` header line: a newline would "
            "break it out of the comment into executable position, and a backtick or `$(…)` would "
            "run in the operator's shell at the moment he is publishing a tag." % (verdict,))

    def _git(*a):
        p = subprocess.run(["git", "-C", repo] + list(a),
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return p.returncode, p.stdout.decode("utf-8", "replace").strip()

    rc, tip = _git("rev-parse", "--verify", "%s^{commit}" % branch)
    if rc != 0 or not tip:
        die("--branch %s does not resolve in %s — there is nothing staged to ship. (Stage the "
            "release branch first, then run the gate on it, then generate this turnkey.)"
            % (branch, repo))
    rc, _ = _git("cat-file", "-e", "%s^{commit}" % gated)
    if rc != 0:
        die("--gated-at %s does not RESOLVE in %s. A SHA that is not in this repository cannot have "
            "been gated in it — this is a copied or mistyped verdict, which is the exact failure "
            "this flag exists to make impossible." % (gated[:12], repo))
    if tip != gated:
        die("--gated-at %s is NOT the current tip of %s (tip is %s).\n"
            "  Generating this turnkey would stamp a verdict onto a commit that is not the one on "
            "offer — the copied-claim bug in its birth form. Either re-run the release gate on %s "
            "and pass THAT sha, or re-stage the branch. Never re-stamp the pin to match the tip: "
            "that 'fixes' the refusal by deleting the only thing that was checking."
            % (gated[:12], branch, tip[:12], tip[:12]))
    rc, _ = _git("rev-parse", "--verify", "refs/tags/%s^{commit}" % prev)
    if rc != 0:
        die("--prev-version %s is not a tag in %s. The emitted script diffs plugin/ against it; an "
            "absent ref would make `git diff --quiet` fail open and the version invariant would be "
            "adjudicated on nothing." % (prev, repo))

    ver = tag[len("core-"):]                      # core-v0.23 → v0.23
    # Default `~/.kickoff/ship-<ver>.sh` — where the operator's real turnkeys actually live, next to
    # the rest of the instance state, rather than loose in $HOME. _write_turnkey still refuses to
    # clobber one without --force, which is the protection that matters at that path.
    out = _validated_out_path(
        args.out or os.path.join(os.path.expanduser("~"), ".kickoff", "ship-%s.sh" % ver))

    prov = ("generated %s · verdict MEASURED ON %s (the branch tip at generation time) · target %s"
            % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), gated[:12], tag))

    # Substitute with OPAQUE tokens + str.replace — never .format()/%/string.Template: bash is
    # saturated with `{`, `}`, `$` and `%`. *_Q tokens carry a shlex.quote'd value and are expanded
    # into their OWN `_DEF_*` var, never into a nested `${VAR:-word}` default (where `word` is STILL
    # EXPANDED — the concrete command-execution hole).
    text = _read_file_seam_template(_SHIP_TEMPLATE)
    for token, value in (
        ("@@REPO_Q@@", shlex.quote(repo)),
        ("@@BR_Q@@", shlex.quote(branch)),
        ("@@TAG_Q@@", shlex.quote(tag)),
        ("@@PREV_TAG_Q@@", shlex.quote(prev)),
        ("@@VERDICT_Q@@", shlex.quote(verdict)),
        ("@@GATED_AT@@", gated),
        ("@@VERDICT@@", verdict),
        ("@@PREV_TAG@@", prev),
        ("@@BR@@", branch),
        ("@@TAG@@", tag),
        ("@@VER@@", ver),
        ("@@SELF@@", out),
        ("@@PROV@@", prov),
    ):
        text = text.replace(token, value)

    _assert_ship_guards(text)

    _write_turnkey(out, text, args.force, repo)
    print("gen-ship-turnkey: wrote %s (0755)\n"
          "  branch:   %s @ %s (VERIFIED as the tip at generation time)\n"
          "  target:   %s   (previous: %s)\n"
          "  verdict:  %s\n"
          "  posture:  PREVIEW by default — pushes NOTHING without --push\n"
          "  rehearse: bash %s          (read-only preview)\n"
          "  ship:     bash %s --push   (the irreversible step)"
          % (out, branch, gated[:12], tag, prev, verdict, out, out))
    return 0


def cmd_reconcile(args):
    """G9 — generate .kickoff/adopt-manifest.json for an ALREADY-adopted repo WITHOUT re-wiring
    anything (the legacy-adopter shape: core.lock present, manifest absent → preflight #8 fail-closed, and
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
    known = ([seam_path_for_shim(n) for n in sorted(SHIM_TEMPLATES)] + sorted(FILE_SEAM_TEMPLATES)
             + list(_OPENCODE_SEAM_PATHS))
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


def cmd_resync(args):
    """Post-delivery re-source: after `kickoff pull <tag>` delivers new seam bytes, the manifest's
    seam rows still cite their ORIGINAL source tags — so any all-sources==target consistency check
    fails forever on long-adopted repos, and a fleet sweep must refuse to cycle them.

    For each class=seam entry whose source != --source: if the file ON DISK byte-matches the
    CURRENT engine template for that path (templates are the delivery contract; verified
    identical to the tagged core before use), re-source the row to --tag and refresh its
    sha256_at_write. Bytes that DON'T match are GENUINE DRIFT — reported loudly, never touched,
    exit non-zero. Non-seam entries and machine_entries: never touched. Idempotent: rows already
    at --source are skipped, so a second run is a no-op. The ONLY write is the manifest."""
    repo = resolve_repo_dir(args)
    mpath = manifest_path(repo)
    if not os.path.lexists(mpath):
        die("no manifest at %s — resync re-sources EXISTING manifests only (manifest-less repos "
            "want `reconcile`; not-yet-adopted repos want `adopt`)." % mpath)
    if not args.source:
        die("--source is required (e.g. core-v0.39) — it is the tag the rows will be re-sourced to")
    manifest = load_manifest(mpath)
    resourced, skipped, drift = [], [], []
    for e in manifest.get("entries", []):
        if e.get("class") != "seam":
            continue                          # non-seam rows: never touched
        if e.get("source") == args.source:
            skipped.append(e.get("path", "?"))
            continue
        rel = e.get("path", "")
        abs_path = os.path.join(repo, rel)
        if not os.path.isfile(abs_path) or os.path.islink(abs_path) or not _real_within(repo, abs_path):
            drift.append("%s — missing/symlink/out-of-repo on disk (NOT re-sourced)" % rel)
            continue
        tmpl = seam_template_for(rel)
        if tmpl is None:
            # No template in THIS engine for that path (e.g. root CLAUDE.md charter block,
            # root .gitignore — operator-owned hybrids generated with per-repo content).
            # Not provable, not drift: leave the row exactly as-is, note it, keep going.
            skipped.append("%s (no template in this engine — left as-is)" % rel)
            continue
        try:
            with open(abs_path, "rb") as f:
                got = f.read()
        except OSError as ex:
            drift.append("%s — unreadable (%s) (NOT re-sourced)" % (rel, ex))
            continue
        if got != tmpl.encode("utf-8"):
            drift.append("%s — disk bytes differ from the %s template (genuine drift: hand-edited "
                         "or foreign content). NOT re-sourced — inspect before forcing." % (rel, args.source))
            continue
        e["source"] = args.source
        e["sha256_at_write"] = sha256_bytes(got)
        resourced.append(rel)

    print("resync — repo=%s  (target source=%s)" % (repo, args.source))
    print("  RE-SOURCED (%d):" % len(resourced))
    for line in resourced:
        print("    ~ %s" % line)
    if not resourced:
        print("    (none needed — already consistent)")
    print("  SKIPPED already-at-target (%d):" % len(skipped))
    for line in skipped:
        print("    = %s" % line)
    if not skipped:
        print("    (none)")
    if drift:
        print("  GENUINE DRIFT (%d — NOT re-sourced; resolve by hand or re-pull):" % len(drift))
        for line in drift:
            print("    ! %s" % line)
        return 1
    save_manifest(mpath, manifest)
    print("  manifest updated -> %s" % mpath)
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
    seam_entries = [e for e in manifest["entries"]
                    if e.get("class") == "seam"]    # INSTANCE-class is NEVER regenerated
    # ── RESOLVE EVERY TEMPLATE BEFORE WRITING ANY SEAM (all-or-nothing on the read side) ──
    # seam_template_for can die FATAL (a whole-file template absent from this checkout — a
    # broken/incomplete core). Resolved lazily inside the write loop, that FATAL used to strike
    # MID-WALK: earlier seams already regenerated on disk while save_manifest below was never
    # reached — stranding the adopter with file != recorded sha256_at_write, so preflight #8
    # reds and eject mis-reads kickoff's OWN write as an operator hand-edit. Hoisting the
    # resolution keeps the FATAL (the correct broken-core backstop) but moves it BEFORE the
    # first write: a failed resolution aborts with ZERO seams touched and the manifest intact.
    templates = {}
    for e in seam_entries:
        p = e.get("path", "")
        if p not in templates:
            templates[p] = seam_template_for(p)
    for e in seam_entries:
        path = e.get("path", "")
        tmpl = templates[path]
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


def cmd_reclass_live_config(args):
    """Reclass ORG-EVOLVED seams (class="seam" whose on-disk bytes no longer match the recorded
    sha256_at_write — or that carry NO recorded hash at all) to live-config, so a pull can
    proceed WITHOUT destroying the org's content. Hit live 2026-08-31: three orgs'
    pulls blocked by evolved seams, each repaired BY HAND with exactly this manifest edit; this
    verb makes the repair first-class, dry-runnable, and auditable.

    GOVERNANCE ONLY, by construction:
      • The FILE is hashed, never written — the divergence (the operator's live evolution) is
        precisely what must survive. The only bytes this verb writes are the manifest's + the
        backup's.
      • The ENTRY loses nothing but its class: action/source/sha256_at_write/original stay as
        recorded, so eject reverses the touch exactly as before (live-config is "reversed like
        created, NOT whole-file-hashed by preflight #8, NOT kept-by-default, NOT seam-synced" —
        the schema's own semantics, header §THE SCHEMA).
      • The candidate PREDICATE (bytes != recorded, or no record) is a superset of sync-seams'
        refusal set, NOT an exact match: a drifted shape sync-seams merely regenerates/[ok]s can
        appear too. Over-capture is benign-to-desirable — reclass only stands seam-sync down,
        file bytes are never touched — and every candidate is PRINTED for review before --accept.
      • DEFAULT (no --accept) is a DRY-RUN: print the candidates (recorded vs actual hash) and
        change NOTHING.
      • --accept writes a timestamped manifest backup FIRST (never clobbers an existing backup —
        a same-second re-run gets a -N suffix) and prints its path, the audit trail the pull
        surfaces.

    PURELY ADDITIVE sibling of cmd_sync_seams — it reads the same helpers and mutates no other
    verb's code (the pull surface's frozen digest must not move)."""
    repo = resolve_repo_dir(args)
    mpath = manifest_path(repo)
    if not os.path.exists(mpath):
        die("reclass-live-config: no manifest at %s — nothing to reclass" % mpath)
    manifest = load_manifest(mpath)
    only_paths = [repo_relative(p) for p in args.path] if args.path else None

    candidates, outside = [], []
    for e in manifest["entries"]:
        if e.get("class") != "seam":
            continue
        path = e.get("path", "")
        if only_paths is not None and path not in only_paths:
            continue
        recorded = e.get("sha256_at_write")
        abs_path = os.path.join(repo, path)
        # containment (the sync-seams Fix-A posture): a symlink / out-of-repo seam is a DIFFERENT
        # refusal (sync-seams' own containment guard) — never silently absorbed here as "evolved".
        if os.path.islink(abs_path) or not _real_within(repo, abs_path):
            outside.append(path)
            continue
        if not os.path.isfile(abs_path):
            continue            # missing file → sync-seams REGENERATES it; no refusal to heal
        cur = sha256_file(abs_path)
        # recorded is None counts TOO (a legacy / hand-mutated manifest entry): sync-seams still
        # REFUSES it (the modified-since-generation arm can never match a missing record), so the
        # old skip dead-ended the operator — refused on every pull, invisible to the escape
        # hatch. No hash to preserve → reclass to live-config is exactly right.
        if recorded is None or cur != recorded:
            candidates.append((e, cur))

    if outside:
        for path in outside:
            print("  [ skip ] %s  (symlink / resolves OUTSIDE the repo — sync-seams' containment "
                  "refusal owns it, not this verb)" % path)
    if not candidates:
        print("reclass-live-config: no org-evolved seams found (nothing in sync-seams' refusal set)%s"
              % (" — the --path filter matched none" if only_paths else ""))
        return 0

    print("reclass-live-config — repo=%s  [%s]" % (repo, "--accept" if args.accept else "DRY-RUN"))
    for e, cur in candidates:
        if e.get("sha256_at_write") is None:
            print("  candidate: %s  (no recorded hash — legacy/hand-mutated entry; actual %s…)"
                  % (e.get("path"), cur[:12]))
        else:
            print("  candidate: %s  (recorded %s… now %s…)"
                  % (e.get("path"), (e.get("sha256_at_write") or "--------")[:12], cur[:12]))
        print("    reclass seam → live-config: GOVERNANCE ONLY — file bytes untouched; seam-sync stops "
              "regenerating it; preflight #8 stops whole-file-hashing it; eject still reverses it like `created`.")
    if not args.accept:
        print("── %d candidate(s); DRY-RUN changed nothing. Re-run with --accept to apply "
              "(a timestamped manifest backup is written first)." % len(candidates))
        return 0

    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    backup = os.path.join(repo, ".kickoff", "adopt-manifest.json.pre-reclass-%s" % stamp)
    n = 0
    while os.path.lexists(backup):     # NEVER clobber a backup — a same-second re-run gets -1, -2, …
        n += 1
        backup = os.path.join(repo, ".kickoff", "adopt-manifest.json.pre-reclass-%s-%d" % (stamp, n))
    shutil.copy2(mpath, backup)
    for e, _cur in candidates:
        e["class"] = "live-config"     # the ONLY field touched — every other entry field is preserved
    save_manifest(mpath, manifest)
    print("── %d seam entry(ies) reclassed to live-config; manifest backup (pre-reclass): %s"
          % (len(candidates), backup))
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
    link_target = entry.get("symlink_target")
    if not _real_within(repo, abs_path):
        print("  [ FAIL ] created        %s  (resolves OUTSIDE the repo via a symlink — refusing "
              "to delete out-of-repo)" % path)
        return "failed"
    if link_target:
        # A created SYMLINK row (e.g. the AGENTS.md → CLAUDE.md pointer): a link's identity is
        # its target STRING, not file bytes — it is recorded with symlink_target and NO sha256
        # (verify + preflight #8 skip it, exactly like a hook-installed row) and reversed by
        # readlink-match. A retargeted or replaced link is DIVERGED — kept, never silent-deleted.
        if not os.path.islink(abs_path):
            print("  [ keep ] created        %s  (recorded as a symlink → %s, but it is no longer "
                  "a symlink — kept, not deleted)" % (path, link_target))
            return "kept"
        got_target = os.readlink(abs_path)
        if got_target == link_target:
            if dry:
                print("  [ del? ] created        %s  WOULD delete (symlink → %s matches the record)" % (path, link_target))
            else:
                os.remove(abs_path)
                print("  [ del  ] created        %s  symlink deleted (→ %s)" % (path, link_target))
            return "deleted"
        if on_div == "delete":
            if dry:
                print("  [ del? ] created        %s  WOULD delete (--on-divergence delete, retargeted)" % path)
            else:
                os.remove(abs_path)
                print("  [ del  ] created        %s  symlink deleted (--on-divergence delete, retargeted)" % path)
            return "deleted"
        print("  [ keep ] created        %s  DIVERGED (recorded symlink → %s, now → %s) — kept, "
              "not deleted" % (path, link_target, got_target))
        return "kept"
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
        # EXCEPTION — an adopt-CREATED root lefthook.yml is pure kickoff gate-WIRING, not an
        # operator-content deliverable (the gate content lives in .kickoff/lefthook-kickoff.yml):
        # keeping it would leave its `extends:` DANGLING at a .kickoff/ file eject removes. It
        # takes the normal created path below — delete-if-unchanged, keep-if-diverged — so an
        # operator who edited it after adopt still keeps their file (never clobbered).
        # WORKSPACE MEMBERS take the SAME exception, for the same reason and no other. A member's
        # `<m>/lefthook.yml` and its `<m>/.git/hooks/*` are kickoff gate WIRING dropped into a repo
        # that is not the adopted root — usually somebody's shared checkout. Keeping them leaves
        # `extends: ../.kickoff/lefthook-member.yml` dangling at a file eject just removed, and
        # leaves an untracked `lefthook.yml` in every member. SCOPED TIGHTLY to member paths:
        # `.git/hooks/pre-commit` with NO prefix (the single-repo case) does not match and is still
        # kept exactly as before.
        _member_gate_wiring = (
            action == "created" and "/" in path
            and not path.split("/")[0].startswith(".")   # `.git/hooks/pre-commit` = single-repo
            and (path.endswith("/lefthook.yml")
                 or os.path.basename(path) in ("_kickoff-hook-runner", "pre-commit", "pre-push")))
        if klass == "seeded-instance" and not purge_seeded:
            if path == "lefthook.yml" and action == "created":
                print("  [ note ] created        lefthook.yml  (adopt-created gate wiring — its "
                      "extends target is removed with .kickoff/, so it is reversed, not kept)")
            elif _member_gate_wiring:
                print("  [ note ] %-14s %s  (workspace-member gate wiring — its extends target is "
                      "removed with .kickoff/, so it is reversed, not kept)" % (action, path))
            else:
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
    FOLLOW-UP write to a path that ALREADY carries a manifest entry (Phase-2 G6/G7 — the
    [[reversal-must-be-the-final-write]] fix for the PULL path; reused by adopt-time
    brownfield-devex for the SAME reason — see _adopt_wire_output_style).

    WHY: two kickoff-driven writes can legitimately land on .claude/settings.json — cmd_pull's
    marketplace re-point (G6, the extraKnownMarketplaces source following the pinned work dir) and
    `kickoff adopt`'s outputStyle-key merge landing on top of the plugin step's own settings.json
    touch. Both are INTENDED changes to the SAME logical touch, not a second independent edit —
    reasserting the old bytes would undo the fix, but recording a SECOND manifest entry would leave
    the FIRST entry's sha256_at_write permanently stale (cmd_verify hash-checks every entry against
    the current file, so a second edit makes the first look "EDITED by the operator" forever) and
    `_reverse_original` would SKIP that entry's byte-restore, stranding the earlier keys in the
    repo. Re-recording sha256_at_write on the EXISTING entry keeps the gate TRUE: eject still
    byte-restores the pre-adopt `original` exactly, reversing BOTH writes in one shot.

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
            "own legitimate FOLLOW-UP settings.json writes (the pull-time marketplace re-point, "
            "and adopt-time's outputStyle-key merge over the plugin step's touch); any other "
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
    """Remove THIS adopter's row (keyed by realpath(repo)). A missing registry / row = idempotent.

    A DELETED repo dir is removable here, deliberately — this is the one command where the target
    not existing is the normal case rather than an error. resolve_repo_dir() dies on a missing dir,
    which is right for every command that then reads that repo's manifest, and exactly wrong for
    this one: it made the registry rows most likely to be garbage (a fixture whose mktemp tree is
    long gone) the only rows the remover structurally could not collect. Found 2026-08-10 pruning
    45 fixture rows: 41 removed, and the 4 whose directories had been deleted survived every attempt.
    Canonicalize the same way _canon_repo does so the comparison stays apples-to-apples, but do not
    require existence.
    """
    _rd = getattr(args, "repo", None) or os.environ.get("REPO_DIR")
    if not _rd:
        _rd = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    repo = _canon_repo(_rd)
    if not repo:
        die("FATAL — adopters-remove needs a repo path (set --repo or $REPO_DIR)")
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

    go = sub.add_parser("gen-output-style", parents=[common],
                        help="generate .claude/output-styles/plain-report.md (seam) from the core's own "
                             "copy + record it created/seam. Half of the reporting-canon wiring — the "
                             "other half merges .claude/settings.json's outputStyle key (see `kickoff adopt`).")
    go.add_argument("--source", required=True, help="e.g. core-v0.2 — stamps the seam's provenance")
    go.set_defaults(func=cmd_gen_output_style)

    goc = sub.add_parser("gen-opencode", parents=[common],
                         help="generate the OPENCODE ENGINE-PARITY seam set (5 crew charters — "
                              "model-pin-stripped for adopters — + 2 plugins + the pin-free adopter "
                              "opencode.json + the AGENTS.md→CLAUDE.md pointer) + record each "
                              "created/seam. Never clobbers: a pre-existing differing file is left "
                              "as-is, disclosed, and NOT recorded.")
    goc.add_argument("--source", required=True, help="e.g. core-v0.2 — stamps the seam's provenance")
    goc.set_defaults(func=cmd_gen_opencode)

    ga = sub.add_parser("gen-agent", parents=[common],
                        help="generate a NEW gap-filler specialist charter into .claude/agents/<name>.md "
                             "from the charter template (correct-by-construction: least-privilege tools, "
                             "a Report-to-MC section, the CANON block) + record it created/seeded-instance "
                             "(adopter-owned: kept on eject, purged on eject --purge). REFUSES to clobber "
                             "an existing charter.")
    ga.add_argument("--name", required=True,
                    help="kebab-case agent name (^[a-z0-9][a-z0-9-]{0,63}$) — names the file AND its MC lane")
    ga.add_argument("--domain", required=True,
                    help="the uncovered domain this gap-filler owns (from crew-probe.py's restraint check)")
    ga.add_argument("--source", required=True, help="e.g. core-v0.9 — stamps the charter's provenance")
    ga.add_argument("--description", default=None,
                    help="frontmatter description (default: a domain-derived placeholder)")
    ga.set_defaults(func=cmd_gen_agent)

    gu = sub.add_parser("gen-upgrade-turnkey", parents=[common],
                        help="generate the operator's one-tap adopter upgrade script "
                             "(~/upgrade-<name>-to-<ver>.sh). POLICY-NEUTRAL by construction: it "
                             "reads the adopter's OWN MODEL/EFFORT at run time — there is "
                             "deliberately no --model/--effort flag to bake. Writes OUTSIDE the "
                             "repo and records NO manifest receipt (it is an operator artifact, "
                             "not a seam).")
    gu.add_argument("--name", required=True,
                    help="adopter slug (^[a-z0-9][a-z0-9._-]{0,63}$) — names the file and the "
                         "backup prefix; also used as an `ls` glob prefix, so it is validated hard")
    gu.add_argument("--version", required=True,
                    help="target core release tag, e.g. core-v0.8.1 (^core-v[0-9]+(\\.[0-9]+){1,2}$)")
    gu.add_argument("--org", default=None, help="display name in the banner (default: --name)")
    gu.add_argument("--out", default=None,
                    help="where to write (default: ~/upgrade-<name>-to-<ver>.sh). Refuses to "
                         "clobber an existing file without --force")
    gu.add_argument("--permission-mode", dest="permission_mode", default="auto",
                    choices=["auto", "default"],
                    help="autonomy posture for the restarted worker — rides ARGV (`kickoff up "
                         "--auto`), NEVER instance.env (PERMISSION_MODE is deliberately off the "
                         "engine's instance.env whitelist). default: auto")
    gu.add_argument("--registry", default=None,
                    help="adopters registry (default $KICKOFF_ADOPTERS_REGISTRY or "
                         "~/.kickoff/adopters.json) — --repo MUST be a registered adopter")
    gu.add_argument("--force", action="store_true", help="overwrite an existing --out")
    gu.set_defaults(func=cmd_gen_upgrade_turnkey)

    gs = sub.add_parser("gen-ship-turnkey", parents=[common],
                        help="generate the operator's one-tap RELEASE script "
                             "(~/.kickoff/ship-<ver>.sh) — "
                             "PREVIEW by default, --push to fast-forward main + push the tag. "
                             "FRESHNESS-PINNED by construction: --gated-at is verified to be the "
                             "current tip of --branch AT GENERATION TIME, pinned into the emitted "
                             "script, and re-asserted there before any push. Writes OUTSIDE the "
                             "repo and records NO manifest receipt (an operator artifact, not a seam).")
    gs.add_argument("--branch", required=True,
                    help="the staged release branch, e.g. release/core-v0.23 (a safe ref name; "
                         "REFUSED, not escaped, if it is not)")
    gs.add_argument("--version", required=True,
                    help="the tag to publish, e.g. core-v0.23 (^core-v[0-9]+(\\.[0-9]+){1,2}$)")
    gs.add_argument("--prev-version", dest="prev_version", required=True,
                    help="the previous release tag, e.g. core-v0.22 — the emitted script diffs "
                         "plugin/ against it to adjudicate the version invariant")
    gs.add_argument("--gated-at", dest="gated_at", required=True,
                    help="the FULL 40-hex commit the release gate actually certified. VERIFIED "
                         "here: it must resolve in the repo AND be the current tip of --branch. A "
                         "turnkey stamped with a SHA that was never the tip is the copied-claim bug.")
    gs.add_argument("--verdict", required=True,
                    help="what the gate ACTUALLY said, as one constrained printable line (e.g. "
                         "'7/7 checks, 0 hard failures, 0 advisories, 38/38 declared suites GREEN') "
                         "— it is printed in the header beside the SHA it was measured on")
    gs.add_argument("--out", default=None,
                    help="where to write (default: ~/.kickoff/ship-<ver>.sh — where the operator's "
                         "real turnkeys live). An absolute path ending '.sh', with no newline and "
                         "no shell metacharacter: it is interpolated into the emitted script's "
                         "header. Refuses to clobber an existing file without --force")
    gs.add_argument("--force", action="store_true", help="overwrite an existing --out")
    gs.set_defaults(func=cmd_gen_ship_turnkey)

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

    rsy = sub.add_parser("resync", parents=[common],
                         help="post-delivery re-source: after a pull delivers new seam bytes, "
                              "re-source manifest seam rows whose disk bytes match the current "
                              "engine template up to --source; genuine drift is reported and "
                              "exit non-zero; idempotent; writes NOTHING but the manifest")
    rsy.add_argument("--source", required=True,
                     help="e.g. core-v0.39 — the delivering tag the matching rows are re-sourced to")
    rsy.set_defaults(func=cmd_resync)
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
                             "(.claude/settings.json) after kickoff's own legitimate FOLLOW-UP "
                             "write to an ALREADY-recorded entry — the pull-time marketplace "
                             "re-point (G6) or adopt-time's outputStyle-key merge — so eject's hash "
                             "gate stays TRUE; never touches original/sha256_before_edit, never any other path")
    rh.add_argument("--path", required=True,
                    help="repo-relative path to re-hash (allowlisted: %s)" % ", ".join(REHASH_ALLOWED_PATHS))
    rh.set_defaults(func=cmd_rehash_path)

    rlc = sub.add_parser("reclass-live-config", parents=[common],
                         help="reclass ORG-EVOLVED seams (on-disk bytes no longer matching the "
                              "recorded sha256_at_write — or carrying no recorded hash; a "
                              "superset of sync-seams' refusal set, every candidate printed) to "
                              "live-config: GOVERNANCE ONLY, file bytes untouched, backup "
                              "written. The sanctioned alternative to --force-regenerate "
                              "(which DISCARDS).")
    rlc.add_argument("--accept", dest="accept", action="store_true",
                     help="apply the reclass (DEFAULT is a dry-run: list candidates, change nothing)")
    rlc.add_argument("--path", dest="path", action="append", default=None, metavar="P",
                     help="only consider this repo-relative path (repeatable; default: all candidates)")
    rlc.set_defaults(func=cmd_reclass_live_config)

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
