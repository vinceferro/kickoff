#!/usr/bin/env bash
# parity-report.sh — the ENGINE-PARITY probe: enumerate every capability per engine by PROBING the
# actual wiring, then hold the findings against docs/PARITY.md. Unrecorded drift EXITS NON-ZERO.
#
#   bash scripts/parity-report.sh                    # probe THIS repo
#   bash scripts/parity-report.sh --root <dir>       # probe another tree (a fixture, an adopter's
#                                                    #   checkout, or the pinned core clone)
#
# ── WHY THIS EXISTS (the chartered principle, CLAUDE.md) ────────────────────────────────────────
#   The engine is abstracted; the system must work equally well on every supported engine. Where a
#   gap exists it is RECORDED (docs/PARITY.md), enforced by the release gate, and explained to
#   adopters in plain language. A ledger nobody re-checks rots — so this script is the re-check:
#   it derives each engine's capabilities from the TREE (files present, hooks configured — probe,
#   never a hardcoded verdict), compares them to what the ledger claims, and fails loud on any
#   divergence in EITHER direction:
#     · a gap exists that the ledger does not record  → the adopter was lied to by omission
#     · the ledger records a gap that no longer exists → the adopter was told "missing" about
#       something that works (an under-claim is still a false statement)
#
# ── THE MACHINE CONTRACT (docs/PARITY.md) ───────────────────────────────────────────────────────
#   One section per capability, headed `### cap:<slug>`, carrying a `Status:` line whose value is
#   the capability's parity verdict, spelled exactly as this script spells them:
#     both | claude-only | opencode-only | none
#   Everything else in the section is adopter-facing prose (what works where / why the gap / the
#   recommendation). When the probes and the ledger agree, exit 0 — RECORDED drift passes; the
#   point is recording, not perfection. When they diverge, exit 1 naming the capability and BOTH
#   sides of the divergence. A `### cap:` slug this script has no probe for is also a failure —
#   a ledger naming capabilities nothing can verify is rot in the other direction.
#
# ── PROBE DISCIPLINE ────────────────────────────────────────────────────────────────────────────
#   A capability counts as "wired" on an engine only when its WIRING is present: the hook/config
#   that invokes the capability AND the file it invokes. A file with no consumer is the classic
#   false green (verify the READ, not just the write); a config naming an absent file is the
#   mirror image. Probes read only $ROOT-relative paths, so the same run works on the dev
#   checkout, a release worktree, or an adopter's box.
set -u

ROOT=""
usage() {
  cat <<'EOF'
usage: parity-report.sh [--root <dir>] [-h|--help]
  --root <dir>   The kickoff tree to probe. Default: the repo this script lives in.
Exit: 0 = every probe matches the ledger (drift, where it exists, is recorded)
      1 = unrecorded drift / ledger rot (named in the output)
      2 = environment error (bad --root, unreadable tree)
EOF
}
while [ $# -gt 0 ]; do
  case "$1" in
    --root)  ROOT="${2:?--root needs a value}"; shift 2 ;;
    --root=*) ROOT="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'parity-report: unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$ROOT" ] || ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -d "$ROOT" ] || { printf 'parity-report: --root %s is not a directory\n' "$ROOT" >&2; exit 2; }

LEDGER="$ROOT/docs/PARITY.md"

# ── the capability registry ─────────────────────────────────────────────────────────────────────
# One slug per row; probe_claude_<slug> / probe_opencode_<slug> define what "wired" means per
# engine. Adding a capability = one slug here + two probe functions + a ledger section. The slug
# list drives the table order; it is NOT a verdict — never hardcode a verdict here.
CAPS=(
  per-prompt-memory-recall
  per-prompt-mail-check
  beat-length-guard
  beat-nudge
  context-handoff-nudge
  mc-spine
  canon-charter-wiring
  reground-boot-prompt
  model-pin
  effort-tier
  verified-workflows
  skills-surface
  orphaned-work-transcripts
  plain-report-output-style
  engine-credit-attribution
)

# tiny probe helpers — every path is $ROOT-relative
_r="$ROOT"
f_exists() { [ -f "$_r/$1" ]; }
grepq()    { grep -qE -- "$2" "$_r/$1" 2>/dev/null; }
grepqi_file() { grep -qiE -- "$2" "$_r/$1" 2>/dev/null; }
# the opencode engine branch of session-run.sh: from the WORKER_ENGINE dispatch to the exec.
# Probing INSIDE the branch is the point — a capability the opencode path never touches is not
# wired there, however many times it appears in the claude-only half of the file.
oc_branch() { sed -n '/WORKER_ENGINE" != "claude"/,/exec opencode-telegram/p' "$_r/scripts/session-run.sh" 2>/dev/null; }
oc_grep()   { oc_branch | grep -qE -- "$1"; }
# claude plugin hooks config + its hook files
HOOKS_JSON="plugin/hooks/hooks.json"
claude_hook() { f_exists "$HOOKS_JSON" && grepq "$HOOKS_JSON" "$1" && f_exists "$2"; }
# an opencode plugin providing a capability (top-level .opencode/plugins/*.js only — never
# node_modules; those are the vendored plugin SDK, not this repo's wiring)
oc_plugin() {
  local hit=""
  for hit in "$_r"/.opencode/plugins/*.js; do
    [ -f "$hit" ] || continue
    grep -qiE -- "$1" "$hit" 2>/dev/null && return 0
  done
  return 1
}

# ── per-capability probes. 0 = wired, 1 = not wired on that engine. ─────────────────────────────
probe_claude_per-prompt-memory-recall() {
  claude_hook 'memory-hook\.sh' "plugin/hooks/memory-hook.sh" && return 0
  f_exists ".claude/settings.json" && grepq ".claude/settings.json" "memory-retrieval/hook\.mjs" \
    && f_exists "memory-retrieval/hook.mjs"
}
probe_opencode_per-prompt-memory-recall() { f_exists ".opencode/plugins/memory-search.js"; }

probe_claude_per-prompt-mail-check()      { claude_hook 'agent-mail-hook\.sh' "plugin/hooks/agent-mail-hook.sh"; }
probe_opencode_per-prompt-mail-check()    { oc_plugin 'agent[-_]mail'; }

probe_claude_beat-length-guard()          { claude_hook 'beat-length-guard\.py' "plugin/hooks/beat-length-guard.py"; }
probe_opencode_beat-length-guard()        { oc_plugin 'beat[-_]length'; }

probe_claude_beat-nudge()                 { claude_hook 'beat-nudge\.py' "plugin/hooks/beat-nudge.py"; }
probe_opencode_beat-nudge()               { oc_plugin 'beat[-_]nudge'; }

probe_claude_context-handoff-nudge()      { claude_hook 'context-handoff-nudge\.py' "plugin/hooks/context-handoff-nudge.py"; }
probe_opencode_context-handoff-nudge()    { oc_plugin 'handoff'; }

probe_claude_mc-spine() {
  # BOTH lifecycle events must route to mc-hook.sh, and the hook must exist — one leg is a
  # half-wired spine (agents would be reported as started-but-never-finished or vice versa).
  f_exists "$HOOKS_JSON" && grepq "$HOOKS_JSON" '"SubagentStart"' && grepq "$HOOKS_JSON" '"SubagentStop"' \
    && [ "$(grep -c 'mc-hook\.sh' "$_r/$HOOKS_JSON" 2>/dev/null)" -ge 2 ] \
    && f_exists "plugin/hooks/mc-hook.sh"
}
probe_opencode_mc-spine()                 { oc_plugin 'mc-hook|mission[.-]control'; }

probe_claude_canon-charter-wiring() {
  # the LIVE wiring: the function-agent charters carry the canon sections the wire-* scripts install
  f_exists ".claude/agents/builder.md"  && grepq ".claude/agents/builder.md"  '^## Canon' \
    && f_exists ".claude/agents/reviewer.md" && grepq ".claude/agents/reviewer.md" '^## Canon'
}
probe_opencode_canon-charter-wiring() {
  f_exists ".opencode/agent/builder.md"  && grepq ".opencode/agent/builder.md"  '^## Canon' \
    && f_exists ".opencode/agent/reviewer.md" && grepq ".opencode/agent/reviewer.md" '^## Canon'
}

probe_claude_reground-boot-prompt() {
  f_exists "scripts/session-run.sh" && grepq "scripts/session-run.sh" 'REGROUND_PROMPT=' \
    && grepq "scripts/session-run.sh" -- '--append-system-prompt'
}
probe_opencode_reground-boot-prompt()     { oc_grep 'REGROUND_PROMPT'; }

probe_claude_model-pin() {
  f_exists "scripts/session-run.sh" && grepq "scripts/session-run.sh" 'MODEL_ARGS' \
    && grepq "scripts/session-run.sh" -- '--model'
}
probe_opencode_model-pin()                { oc_grep 'OPENCODE_MODEL_PROVIDER' && oc_grep 'OPENCODE_MODEL_ID'; }

probe_claude_effort-tier()                { f_exists "scripts/session-run.sh" && grepq "scripts/session-run.sh" -- '--effort'; }
probe_opencode_effort-tier()              { oc_grep 'EFFORT'; }

probe_claude_verified-workflows() {
  local n=0
  for _f in "$_r"/.claude/workflows/*.js; do [ -f "$_f" ] && n=$((n+1)); done
  [ "$n" -gt 0 ]
}
probe_opencode_verified-workflows() {
  local f
  for f in "$_r"/.opencode/plugins/*.js; do
    [ -f "$f" ] || continue
    grep -qiE 'workflow' "$f" 2>/dev/null && return 0
  done
  [ -d "$_r/.opencode/workflows" ]
}

probe_claude_skills-surface() {
  [ -d "$_r/.claude/skills" ] || return 1
  local f
  for f in "$_r"/.claude/skills/*/SKILL.md; do [ -f "$f" ] && return 0; done
  return 1
}
probe_opencode_skills-surface() {
  [ -d "$_r/.opencode/skill" ] || [ -d "$_r/.opencode/skills" ] || return 1
  local f
  for f in "$_r"/.opencode/skill/*/SKILL.md "$_r"/.opencode/skills/*/SKILL.md; do
    [ -f "$f" ] && return 0
  done
  return 1
}

probe_claude_orphaned-work-transcripts()  { f_exists "scripts/orphaned-work.py" && grepq "scripts/orphaned-work.py" 'claude/projects'; }
probe_opencode_orphaned-work-transcripts(){ f_exists "scripts/orphaned-work.py" && grepqi_file "scripts/orphaned-work.py" 'opencode'; }

probe_claude_plain-report-output-style() {
  f_exists ".claude/settings.json" && grepq ".claude/settings.json" '"outputStyle"' \
    && f_exists ".claude/output-styles/plain-report.md"
}
probe_opencode_plain-report-output-style(){ oc_plugin 'plain-report|output[-_]?style'; }

# Attribution: opencode owns it via .opencode/plugins/engine-credit.js (a git Co-authored-by
# trailer naming the live model). The CLAUDE probe asks whether an equivalent attribution wiring
# exists on the claude side (its plugin hooks or project settings) — today it does not, so this
# probes as opencode-only; if someone wires the claude equivalent, the probe flips on its own.
probe_claude_engine-credit-attribution() {
  grepq "$HOOKS_JSON" 'engine[-_]credit|[Cc]o-[Aa]uthored' && return 0
  grepq ".claude/settings.json" 'engine[-_]credit|[Cc]o-[Aa]uthored' && return 0
  return 1
}
probe_opencode_engine-credit-attribution(){ f_exists ".opencode/plugins/engine-credit.js"; }

# ── probe runner + verdict ──────────────────────────────────────────────────────────────────────
probe() {  # probe <engine> <slug> → 0 if wired
  local engine="$1" slug="$2" fn
  fn="probe_${engine}_${slug}"
  [ -n "$(declare -f "$fn")" ] || { printf 'parity-report: INTERNAL: no probe %s\n' "$fn" >&2; exit 2; }
  "$fn"
}
verdict_for() {  # verdict_for <slug> → both | claude-only | opencode-only | none
  local slug="$1" c=0 o=0
  probe claude "$slug"   && c=1
  probe opencode "$slug" && o=1
  if [ "$c" -eq 1 ] && [ "$o" -eq 1 ]; then printf 'both'
  elif [ "$c" -eq 1 ]; then printf 'claude-only'
  elif [ "$o" -eq 1 ]; then printf 'opencode-only'
  else printf 'none'; fi
}

# ── ledger parse: slug<TAB>status ───────────────────────────────────────────────────────────────
# Section-scoped: a `### cap:<slug>` heading opens a section; the FIRST `Status:` line inside it
# is that capability's recorded verdict. Prose is free-form; this contract is two lines.
parse_ledger() {
  awk '
    /^### cap:/ {
      slug=$2; sub(/^cap:/, "", slug); gsub(/\r/, "", slug)
      inslug=slug; next
    }
    inslug != "" && $1 == "Status:" {
      st=$2; gsub(/\r/, "", st)
      print inslug "\t" st
      inslug=""
    }
  ' "$LEDGER"
}

# ── run ─────────────────────────────────────────────────────────────────────────────────────────
printf 'parity-report: root=%s\nparity-report: ledger=%s\n' "$ROOT" "$LEDGER"

[ -f "$LEDGER" ] || {
  printf '\nFAIL: no ledger at %s — the tree cannot certify its own engine parity.\n' "$LEDGER"
  printf '  FIX: write docs/PARITY.md (one `### cap:<slug>` section per capability, each with a\n'
  printf '       `Status:` line — see the capability list this script probes, or run it once to see\n'
  printf '       the verdicts it derives).\n'
  exit 1
}

declare -a T_CAP=() T_VERDICT=() T_LEDGER=()
drift=0; n_both=0; n_cl=0; n_oc=0; n_none=0
declare -a DRIFTS=()

printf '\n  %-30s %-7s %-9s %-14s %s\n' 'capability' 'claude' 'opencode' 'verdict' 'ledger'
printf '  %-30s %-7s %-9s %-14s %s\n' '------------------------------' '-------' '---------' '------------' '---------------'
# column widths are byte-aligned ASCII ('yes'/'.') on purpose — multi-byte table glyphs desync
# every printf column that counts bytes.

for slug in "${CAPS[@]}"; do
  v="$(verdict_for "$slug")"
  recorded="$(parse_ledger | awk -F'\t' -v s="$slug" '$1==s{print $2}')"
  case "$v" in
    both) n_both=$((n_both+1)); cw='yes'; ow='yes' ;;
    claude-only) n_cl=$((n_cl+1)); cw='yes'; ow='.' ;;
    opencode-only) n_oc=$((n_oc+1)); cw='.'; ow='yes' ;;
    none) n_none=$((n_none+1)); cw='.'; ow='.' ;;
  esac
  if [ -z "$recorded" ]; then
    printf '  %-30s %-7s %-9s %-14s %s\n' "$slug" "$cw" "$ow" "$v" 'MISSING ✗'
    drift=$((drift+1))
    DRIFTS+=("UNRECORDED DRIFT: capability '$slug' probes as '$v' but docs/PARITY.md has NO '### cap:$slug' section.
     FIX: add the section with a 'Status: $v' line (plus the adopter prose: what works where, why the gap, the recommendation).")
  elif [ "$recorded" != "$v" ]; then
    printf '  %-30s %-7s %-9s %-14s %s\n' "$slug" "$cw" "$ow" "$v" "$recorded ✗"
    drift=$((drift+1))
    DRIFTS+=("LEDGER MISMATCH: '$slug' — the tree probes as '$v' but the ledger records 'Status: $recorded'.
     FIX: either the wiring or the ledger is stale. If a gap closed, set 'Status: $v' (and say when it
     closed); if a capability broke, restore the wiring. An under-claim ('both' recorded as a gap) is
     as false to an adopter as an over-claim.")
  else
    printf '  %-30s %-7s %-9s %-14s %s\n' "$slug" "$cw" "$ow" "$v" "$recorded ✓"
  fi
done

# the mirror check: a ledger section this script has no probe for is rot in the other direction —
# a recorded verdict nothing can verify.
unknown=""
while IFS="$(printf '\t')" read -r lslug lst; do
  [ -n "$lslug" ] || continue
  known=0
  for slug in "${CAPS[@]}"; do [ "$slug" = "$lslug" ] && known=1 && break; done
  [ "$known" -eq 1 ] || unknown="${unknown}  - cap:${lslug} (Status: ${lst:-?})
"
done < <(parse_ledger)

echo
if [ -n "$unknown" ]; then
  drift=$((drift+1))
  DRIFTS+=("LEDGER ROT: docs/PARITY.md records capability section(s) this script has NO probe for:
${unknown}  FIX: add probe_claude_<slug>/probe_opencode_<slug> to scripts/parity-report.sh (and the slug to
  CAPS), or delete the section — a verdict nothing can verify is not a record, it is prose.")
fi

if [ "$drift" -gt 0 ]; then
  printf 'SUMMARY: %d capability probe(s): %d both · %d claude-only · %d opencode-only · %d none — %d DIVERGENCE(S) from docs/PARITY.md:\n\n' \
    "${#CAPS[@]}" "$n_both" "$n_cl" "$n_oc" "$n_none" "$drift"
  for _d in "${DRIFTS[@]}"; do printf '%s\n' "$_d"; done
  printf 'parity-report: RED — unrecorded engine drift (or ledger rot). Fix the named items; recorded drift passes.\n'
  exit 1
fi

printf 'SUMMARY: %d capability probe(s): %d both · %d claude-only · %d opencode-only · %d none — ledger MATCHES the probes.\n' \
  "${#CAPS[@]}" "$n_both" "$n_cl" "$n_oc" "$n_none"
printf 'parity-report: GREEN — every gap that exists is recorded in docs/PARITY.md with the right verdict.\n'
exit 0
