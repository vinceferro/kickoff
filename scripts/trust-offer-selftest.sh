#!/usr/bin/env bash
# trust-offer-selftest.sh — adopt may OFFER to trust the folder; it must never forge the answer,
# and it must never damage the live Claude Code config.
#
#   bash scripts/trust-offer-selftest.sh
#
# Why this exists (2026-07-16, a live adoption): Claude Code blocks on a "trust this folder?"
# dialog the first time it opens a repo. `kickoff up` spawns the worker with stdin bound to a
# `tail -f /dev/null` keepalive and detached via setsid, so that dialog is UNANSWERABLE there — by
# anyone, including a human at that terminal. The operator hit it and diagnosed it before I did:
# "I just can't accept as my input doesn't reach Claude Code." A freshly adopted repo is never
# pre-trusted, so the first `kickoff up` was an unpassable wall.
#
# `adopt` is the only moment with a real tty, so that is where the offer lives. Every case below is
# a safety property: this writes to ~/.claude.json, which every worker on the box depends on.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
KO="$HERE/kickoff"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
[ -r "$KO" ] || { printf '  ❌ scripts/kickoff not readable\n'; exit 1; }
grep -q '^_offer_trust_folder()' "$KO" || { printf '  ❌ _offer_trust_folder() missing\n'; exit 1; }
ok "located _offer_trust_folder() in scripts/kickoff"

FN="$(mktemp)"; trap 'rm -f "$FN"' EXIT
{
  printf 'log()     { printf "[k] %%s\\n" "$*"; }\n'
  printf 'mark_ok() { printf "  ok %%s\\n" "$*"; }\n'
  printf 'mark_no() { printf "  no %%s\\n" "$*"; }\n'
  awk '/^_offer_trust_folder\(\) \{/,/^\}/' "$KO"
} > "$FN"
bash -n "$FN" || bad "the extracted function is not valid bash"

trust_of() { python3 -c "
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print('ERR'); sys.exit()
print((d.get('projects',{}).get(sys.argv[2],{}) or {}).get('hasTrustDialogAccepted'))" "$1" "$2" 2>/dev/null; }

# ── 1. piped/CI: must NOT hang and must NOT forge the answer ─────────────────────────────────────
T="$(mktemp -d)"; CFG="$T/.claude.json"; R="$T/repo"; mkdir -p "$R"
printf '{"projects":{}}\n' > "$CFG"
out="$(timeout 20 bash -c "printf 'y\n' | CLAUDE_CONFIG_DIR='$T' bash -c \". '$FN'; _offer_trust_folder '$R'\"" 2>&1)"; rc=$?
[ "$rc" -ne 124 ] && ok "piped run does not hang" || bad "piped run HUNG"
[ "$(trust_of "$CFG" "$R")" = "None" ] && ok "piped run does NOT write trust (never forges a security answer)" \
  || bad "piped run WROTE trust — a pipe was taken as the user's consent to a security dialog"
case "$out" in *"claude"*) ok "piped run tells the user how to grant it themselves" ;;
  *) bad "piped run gave no route forward" ;; esac
rm -rf "$T"

# ── 2. declining must write nothing ──────────────────────────────────────────────────────────────
T="$(mktemp -d)"; CFG="$T/.claude.json"; R="$T/repo"; mkdir -p "$R"
printf '{"projects":{}}\n' > "$CFG"
printf 'n\n' | timeout 25 script -qec "CLAUDE_CONFIG_DIR='$T' bash -c \". '$FN'; _offer_trust_folder '$R'\"" /dev/null >/dev/null 2>&1
[ "$(trust_of "$CFG" "$R")" = "None" ] && ok "declining writes nothing (no is honoured)" \
  || bad "declining still wrote trust — the prompt is theatre"
rm -rf "$T"

# ── 3. POSITIVE CONTROL — accepting at a real tty DOES grant it ──────────────────────────────────
# Without this, every "does not write" above passes on a function that can never write at all.
if command -v script >/dev/null 2>&1; then
  T="$(mktemp -d)"; CFG="$T/.claude.json"; R="$T/repo"; mkdir -p "$R"
  printf '{"projects":{"/other/repo":{"hasTrustDialogAccepted":true,"allowedTools":["Read"]}}}\n' > "$CFG"
  printf 'y\n' | timeout 25 script -qec "CLAUDE_CONFIG_DIR='$T' bash -c \". '$FN'; _offer_trust_folder '$R'\"" /dev/null >/dev/null 2>&1
  [ "$(trust_of "$CFG" "$R")" = "True" ] \
    && ok "POSITIVE CONTROL: accepting at a tty grants trust (the offer is not a no-op)" \
    || bad "POSITIVE CONTROL FAILED: accepting wrote nothing — every 'does not write' pass is vacuous"
  # and it must not damage what was already there
  [ "$(trust_of "$CFG" "/other/repo")" = "True" ] \
    && ok "an existing project's trust survives (no clobber of the live config)" \
    || bad "an existing project's trust was DESTROYED — this config runs every worker on the box"
  python3 -c "
import json,sys
d=json.load(open('$CFG'))
sys.exit(0 if d['projects']['/other/repo'].get('allowedTools')==['Read'] else 1)" 2>/dev/null \
    && ok "sibling keys (allowedTools, mcpServers…) survive the write" \
    || bad "sibling keys were dropped — the write is lossy"
  rm -rf "$T"
else
  printf '  … skipped the tty positive control (script(1) unavailable) — the offer is UNPROVEN here\n'
fi

# ── 4. already trusted → silent no-op, no rewrite ────────────────────────────────────────────────
T="$(mktemp -d)"; CFG="$T/.claude.json"; R="$T/repo"; mkdir -p "$R"
printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' "$R" > "$CFG"
before="$(cat "$CFG")"
out="$(CLAUDE_CONFIG_DIR="$T" timeout 20 bash -c ". '$FN'; _offer_trust_folder '$R'" </dev/null 2>&1)"
[ "$(cat "$CFG")" = "$before" ] && ok "an already-trusted repo is left byte-identical (no needless rewrite)" \
  || bad "an already-trusted repo's config was rewritten"
[ -z "$out" ] && ok "an already-trusted repo prompts nothing and says nothing" \
  || bad "an already-trusted repo still produced output: $out"
rm -rf "$T"

# ── 5. a MALFORMED config must never be clobbered ────────────────────────────────────────────────
T="$(mktemp -d)"; CFG="$T/.claude.json"; R="$T/repo"; mkdir -p "$R"
printf 'not json at all {{{\n' > "$CFG"
before="$(cat "$CFG")"
printf 'y\n' | timeout 25 script -qec "CLAUDE_CONFIG_DIR='$T' bash -c \". '$FN'; _offer_trust_folder '$R'\"" /dev/null >/dev/null 2>&1
[ "$(cat "$CFG")" = "$before" ] && ok "a malformed config is NEVER clobbered (fail closed, report)" \
  || bad "a malformed config was OVERWRITTEN — unparseable is not empty"
rm -rf "$T"

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && printf '  ✅ trust is offered, never forged; the live config is never damaged\n'
[ "$FAIL" -eq 0 ]
