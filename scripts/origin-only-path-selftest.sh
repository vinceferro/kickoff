#!/usr/bin/env bash
# origin-only-path-selftest.sh — an adopter-facing surface may not teach an ORIGIN-ONLY path.
#
#   bash scripts/origin-only-path-selftest.sh            # the gate + its RED controls
#   bash scripts/origin-only-path-selftest.sh --scan F…  # just scan the named files (findings → stderr)
#
# THE BUG CLASS (three shipped instances in one week, every one SILENT):
#   kickoff has two topologies. In the ORIGIN (this repo) the engine IS the repo, so `scripts/…` and
#   `mission-control/…` resolve. In an ADOPTER the engine is a SHARED PINNED CLONE at $KICKOFF_CORE_DIR
#   and the repo is elsewhere: `mission-control/mc-update.py` resolves to NOTHING (board stays empty,
#   no error), and a bare `mission-control/secrets-inbox/` resolves INTO THE SHARED CLONE — a
#   cross-project leak. Everything we ship to adopters (plugin/skills/**, the operator strings in
#   scripts/kickoff) is written and tested HERE, where the broken form works.
#     · e53096c — the mission-control SKILL taught `python3 mission-control/mc-update.py` ×10
#     · 02d5db9 — the same SKILL taught `node scripts/secret-decrypt.mjs mission-control/secrets-inbox/…`
#     · 44cc2a5 — scripts/kickoff told the operator to write the bot token to a file NOTHING reads
#   Each fix landed on ONE surface while a sibling surface kept teaching the same motion. Only a gate
#   scales; all three pre-fix texts are wired below as RED controls so it cannot silently stop catching them.
#
# THE RULE (deliberately narrow — precision beats recall; a gate that cries wolf gets switched off):
#   In an adopter-facing surface, a line that either
#     (a) INVOKES an engine artifact — `python3|node|bash|sh` + `mission-control/*.py` or
#         `scripts/*.{sh,mjs,py}` — bare, i.e. not via `$KICKOFF_CORE_DIR/` or `.kickoff/bin/`, or
#     (b) NAMES an instance-state path — `mission-control/{secrets-inbox,.mission-token,mission-state.json}`
#         — bare, i.e. not under `.kickoff/state/`
#   FAILS, unless its PASSAGE is topology-branched: the enclosing markdown section (for a doc) or a
#   ±10-line window (for a script) also gives the adopter form — `.kickoff/bin/…`, `$KICKOFF_CORE_DIR/…`,
#   `.kickoff/state/…`, or a `kickoff <verb>` front-door command.
#
#   A blanket "always use the shim" rule is WRONG and was rejected: it breaks the origin and every
#   greenfield bootstrap, where KICKOFF_CORE_DIR is UNSET by design. Both forms are correct — what is
#   not correct is teaching only the origin one.
#
# SCOPE (chosen, not accidental):
#   · plugin/skills/**/*.md          — everything the plugin ships to an adopter's agents
#   · scripts/kickoff, PROSE ONLY    — `log "` / `mark_ok "` / `mark_no "` / `mark_warn "` / `die "`,
#                                      i.e. what the operator READS. Instance 1's surface. Code lines are
#                                      excluded: the engine legitimately runs its own scripts by repo-
#                                      relative path, and flagging that is the false positive that would
#                                      get the gate bypassed.
#   NOT scanned: the rest of the repo. This IS the origin — most repo-relative paths here are correct.
#   Instance 1's own DEAD-FILE rule stays owned by scripts/channel-offer-selftest.sh (a different rule:
#   a path that resolves but nothing reads). This suite does not duplicate it — it EXTRACTS that guard
#   and runs it against the core-v0.16 text, so the delegation is proven, not assumed.
#
# Hermetic: read-only over the tree. Pure bash + awk + git.
#   The two doc RED controls read COMMITTED fixtures (scripts/testdata/origin-only-path/) rather than
#   `git show <sha>:`. The pre-fix texts live only in this repo's development history, which never
#   reaches the published tag — so a SHA-anchored fixture makes the suite RED for everyone who clones
#   the public repo, i.e. the gate against origin-only assumptions would itself have been origin-only.
#   The third control stays git-anchored on purpose: `core-v0.16` is a PUBLISHED TAG, present in every
#   clone. Fixtures are byte-copies of the real pre-fix files; see that directory's README for provenance.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }

# ─────────────────────────────────────────────────────────────────────────────────────────────────
# THE SCANNER. Prints one `path:line: [KIND] text` per finding on stdout; exit 1 when any found.
# _scan_file <path> [prose-only]
# ─────────────────────────────────────────────────────────────────────────────────────────────────
_scan_file() {
  awk -v FNAME="$1" -v PROSE="${2:-0}" '
    # ── collect ──────────────────────────────────────────────────────────────────────────────────
    { L[NR] = $0 }
    # markdown section id: a heading opens a new passage
    /^#{1,6} / { sec++ }
    { S[NR] = sec }
    END {
      # ── per-passage topology-branch markers ────────────────────────────────────────────────────
      for (i = 1; i <= NR; i++) {
        l = L[i]
        if (l ~ /\.kickoff\/bin\//)                                                   bin[S[i]]  = 1
        if (l ~ /KICKOFF_CORE_DIR/)                                                   core[S[i]] = 1
        if (l ~ /\.kickoff\/state\//)                                                 st[S[i]]   = 1
        if (l ~ /(^|[^[:alnum:]_-])kickoff[[:space:]]+(preflight|adopt|pull|up|status|verify|eject|setup|init|serve)([^[:alnum:]_-]|$)/) fd[S[i]] = 1
        # line-window markers, for files with no headings (scripts)
        wbin[i] = (l ~ /\.kickoff\/bin\//); wcore[i] = (l ~ /KICKOFF_CORE_DIR/); wst[i] = (l ~ /\.kickoff\/state\//)
      }
      hits = 0
      for (i = 1; i <= NR; i++) {
        raw = L[i]
        t = raw; sub(/^[[:space:]]+/, "", t)

        # scripts/kickoff: operator-facing PROSE only (the same narrowing channel-offer-selftest.sh
        # had to make — its first draft had 2 false positives until it was cut to log/mark_* lines).
        if (PROSE) {
          if (t !~ /^(log|mark_ok|mark_no|mark_warn|die)[[:space:]]+"/) continue
        } else {
          if (t ~ /^#{1,6} /) continue          # a markdown heading teaches nothing runnable
        }

        # ── neutralise the CORRECT forms before matching (no lookbehind in ERE): any whitespace-
        # delimited token routed through the seam or the pinned core is not a finding, and its
        # tail must not be re-matched (".kickoff/state/mission-control/.mission-token" contains
        # "mission-control/.mission-token" verbatim — the first draft flagged it).
        n = split(raw, tok, /[[:space:]]+/); san = ""
        for (k = 1; k <= n; k++) {
          if (tok[k] ~ /\.kickoff\// || tok[k] ~ /KICKOFF_CORE_DIR/) san = san " OK"
          else                                                       san = san " " tok[k]
        }

        kind = ""
        if (san ~ /(^|[^[:alnum:]_.\/-])(python3?|node|bash|sh)[[:space:]]+["'"'"']?(mission-control\/[[:alnum:]_.-]+\.py|scripts\/[[:alnum:]_.-]+\.(sh|mjs|py))/)
          kind = "ENGINE-INVOCATION"
        else if (san ~ /(^|[^[:alnum:]_.\/-])mission-control\/(secrets-inbox|\.mission-token|mission-state\.json)/)
          kind = "INSTANCE-STATE"
        if (kind == "") continue

        # ── topology-branched? the passage must also give the adopter a working form ──────────────
        branched = 0
        if (PROSE) {
          for (j = (i > 10 ? i - 10 : 1); j <= i + 10 && j <= NR; j++)
            if (wbin[j] || wcore[j] || wst[j]) branched = 1
        } else if (kind == "ENGINE-INVOCATION") {
          branched = (bin[S[i]] || core[S[i]] || fd[S[i]])
        } else {
          branched = st[S[i]]
        }
        if (branched) continue

        hits++
        printf "%s:%d: [%s] %s\n", FNAME, i, kind, substr(t, 1, 140)
      }
      exit (hits > 0 ? 1 : 0)
    }
  ' "$1"
}

# _scan_surfaces <root> — the live surface set. Echoes findings, returns 1 if any.
_scan_surfaces() {
  local root="$1" rc=0 f
  while IFS= read -r f; do
    _scan_file "$f" 0 || rc=1
  done < <(find "$root/plugin/skills" -name '*.md' -type f 2>/dev/null | sort)
  [ -f "$root/scripts/kickoff" ] && { _scan_file "$root/scripts/kickoff" 1 || rc=1; }
  return $rc
}

# ── --scan passthrough (used by the non-vacuity harness and by hand) ─────────────────────────────
if [ "${1:-}" = "--scan" ]; then
  shift; rc=0
  for f in "$@"; do
    case "$f" in */kickoff) _scan_file "$f" 1 || rc=1 ;; *) _scan_file "$f" 0 || rc=1 ;; esac
  done
  exit $rc
fi

printf '\n  origin-only path gate — an adopter-facing surface may not teach an origin-only path\n\n'

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ─────────────────────────────────────────────────────────────────────────────────────────────────
# 1. RED CONTROL — instance 2 (e53096c): the SKILL taught `python3 mission-control/mc-update.py` ×10
#    and never named `.kickoff/bin/mc`. On an adopter the board stayed EMPTY, with no error.
# ─────────────────────────────────────────────────────────────────────────────────────────────────
FX2="$ROOT/scripts/testdata/origin-only-path/mc-skill.pre-e53096c.md"
if [ -s "$FX2" ]; then
  out="$(_scan_file "$FX2" 0)"; rc=$?
  if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'mc-update\.py'; then
    ok "RED CONTROL e53096c (board-write loop): flagged $(printf '%s\n' "$out" | grep -c .) origin-only line(s)"
  else
    bad "RED CONTROL e53096c did NOT go red — the gate stopped catching the board-write bug"
  fi
else
  bad "harness gap: RED-control fixture missing — scripts/testdata/origin-only-path/mc-skill.pre-e53096c.md"
fi

# ─────────────────────────────────────────────────────────────────────────────────────────────────
# 2. RED CONTROL — instance 3 (02d5db9): `node scripts/secret-decrypt.mjs mission-control/secrets-inbox/…`
#    Both halves wrong on an adopter, and the bare inbox path resolves into the SHARED core clone —
#    a cross-project secret leak. BOTH kinds must fire, or half the bug is uncovered.
# ─────────────────────────────────────────────────────────────────────────────────────────────────
FX3="$ROOT/scripts/testdata/origin-only-path/mc-skill.pre-02d5db9.md"
if [ -s "$FX3" ]; then
  out="$(_scan_file "$FX3" 0)"; rc=$?
  if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'secret-decrypt\.mjs'; then
    ok "RED CONTROL 02d5db9 (decrypt command): flagged the bare \`node scripts/secret-decrypt.mjs\`"
  else
    bad "RED CONTROL 02d5db9 did NOT flag the engine invocation"
  fi
  if printf '%s' "$out" | grep -q 'INSTANCE-STATE'; then
    ok "RED CONTROL 02d5db9 (cross-project leak): flagged the bare \`mission-control/secrets-inbox/\`"
  else
    bad "RED CONTROL 02d5db9 did NOT flag the bare inbox path — the LEAK half is uncovered"
  fi
else
  bad "harness gap: RED-control fixture missing — scripts/testdata/origin-only-path/mc-skill.pre-02d5db9.md"
fi

# ─────────────────────────────────────────────────────────────────────────────────────────────────
# 3. RED CONTROL — instance 1 (44cc2a5), DELEGATED. Its rule is a different one (a path that resolves
#    but nothing READS), owned by scripts/channel-offer-selftest.sh §5. Re-implementing it here would
#    fork the rule, so instead: EXTRACT that guard's real loop and run it against the core-v0.16 text.
#    If the guard is deleted or renamed, extraction fails and this goes red — the delegation is proven.
# ─────────────────────────────────────────────────────────────────────────────────────────────────
COS="$ROOT/scripts/channel-offer-selftest.sh"
awk '/^_bad_instr=0$/,/^done < "\$KO"$/' "$COS" > "$TMP/deadfile-guard.sh" 2>/dev/null
if [ -s "$TMP/deadfile-guard.sh" ] && grep -q 'done < "\$KO"' "$TMP/deadfile-guard.sh"; then
  ok "delegation intact: extracted the dead-file guard from channel-offer-selftest.sh"
  if git -C "$ROOT" show 'core-v0.16:scripts/kickoff' > "$TMP/k016" 2>/dev/null; then
    n_old="$(KO="$TMP/k016" bash -c '. "'"$TMP"'/deadfile-guard.sh" >/dev/null 2>&1; printf "%s" "$_bad_instr"')"
    n_new="$(KO="$ROOT/scripts/kickoff" bash -c '. "'"$TMP"'/deadfile-guard.sh" >/dev/null 2>&1; printf "%s" "$_bad_instr"')"
    [ "${n_old:-0}" -ge 1 ] \
      && ok "RED CONTROL core-v0.16 (dead-file instructions): the guard flags $n_old operator-facing line(s)" \
      || bad "RED CONTROL core-v0.16 did NOT go red — the dead-file guard has stopped discriminating"
    [ "${n_new:-1}" -eq 0 ] \
      && ok "…and flags 0 on HEAD's scripts/kickoff (it discriminates, it does not just always fire)" \
      || bad "the dead-file guard flags $n_new line(s) on HEAD — a live instance-1 regression"
  else
    bad "harness gap: cannot git-show core-v0.16:scripts/kickoff"
  fi
else
  bad "delegation BROKEN: channel-offer-selftest.sh no longer has the extractable dead-file guard (\`_bad_instr\` … \`done < \"\$KO\"\`) — instance 1 is now uncovered by BOTH suites"
fi

# ─────────────────────────────────────────────────────────────────────────────────────────────────
# 4. GREEN CONTROLS — the topology-branched shape must be ACCEPTED. A gate that reds on the CORRECT
#    fix is a gate everyone bypasses, so the two shipped fixes (e53096c's mc seam, 02d5db9's secrets
#    block) and a synthetic minimal branch are asserted CLEAN. Scoped to the fixed motions by name,
#    not "the whole file has 0 findings" — that would silently couple this control to unrelated lines.
# ─────────────────────────────────────────────────────────────────────────────────────────────────
mc_out="$(_scan_file "$ROOT/plugin/skills/mission-control/SKILL.md" 0)"
if printf '%s' "$mc_out" | grep -qE 'mc-update\.py|secret-decrypt\.mjs|secrets-inbox|\.mission-token'; then
  bad "GREEN CONTROL: the SHIPPED fixes in mission-control/SKILL.md are being flagged — false positive on a correct branch"
else
  ok "GREEN CONTROL: the shipped mc-seam + secrets branches in mission-control/SKILL.md are accepted"
fi
if _scan_file "$ROOT/plugin/skills/mc-report/SKILL.md" 0 >/dev/null; then
  ok "GREEN CONTROL mc-report/SKILL.md: the topology-branched entrypoint is accepted (0 findings)"
else
  bad "GREEN CONTROL mc-report/SKILL.md went RED on the branched form — false positive on a correct fix"
fi
# synthetic: the minimal legitimate future doc — adopter form first, kickoff-native beside it.
cat > "$TMP/branched.md" <<'MD'
## Write to the board
- **Adopted repo:** `.kickoff/bin/mc set headline "x"`
- **kickoff-native project** (KICKOFF_CORE_DIR is unset there by design):
  `python3 mission-control/mc-update.py set headline "x"`
Read the inbox at `.kickoff/state/mission-control/secrets-inbox/` — a bare
`mission-control/secrets-inbox/` would resolve into the SHARED core clone.
MD
_scan_file "$TMP/branched.md" 0 >/dev/null \
  && ok "GREEN CONTROL synthetic: a minimal both-forms passage passes (branch detection, not luck)" \
  || bad "GREEN CONTROL synthetic: a correctly branched passage was flagged"

# ─────────────────────────────────────────────────────────────────────────────────────────────────
# 5. THE GATE ITSELF — every live adopter-facing surface.
# ─────────────────────────────────────────────────────────────────────────────────────────────────
gate_out="$(_scan_surfaces "$ROOT")"; gate_rc=$?
if [ $gate_rc -eq 0 ]; then
  ok "GATE: no adopter-facing surface teaches an origin-only path"
else
  bad "GATE: $(printf '%s\n' "$gate_out" | grep -c .) adopter-facing line(s) teach a path that does not resolve on an adopter"
  printf '%s\n' "$gate_out" | sed 's/^/     ↳ /'
  printf '     (fix: route via .kickoff/bin/<shim> or "$KICKOFF_CORE_DIR/scripts/…" / ".kickoff/state/…",\n'
  printf '      and give the kickoff-native form beside it — see plugin/skills/mission-control/SKILL.md)\n'
fi

# ─────────────────────────────────────────────────────────────────────────────────────────────────
# 6. NON-VACUITY — stub _scan_file out and the suite MUST notice. Without this every ✅ above could
#    be a scanner that finds nothing, ever, reporting a green world nobody lives in.
# ─────────────────────────────────────────────────────────────────────────────────────────────────
sed 's/^_scan_file() {$/_scan_file() { return 0;/' "$0" > "$TMP/stubbed.sh"
if [ "${_OOPS_MUTANT:-0}" = "1" ]; then
  :   # the mutant child does not re-mutate itself (that would recurse forever)
elif grep -q '_scan_file() { return 0;' "$TMP/stubbed.sh"; then
  if _OOPS_MUTANT=1 bash "$TMP/stubbed.sh" >/dev/null 2>&1; then
    bad "NON-VACUITY: the suite still passes with the scanner stubbed out — it proves nothing"
  else
    ok "NON-VACUITY: stubbing the scanner makes this suite FAIL (the ✅s above are load-bearing)"
  fi
else
  bad "NON-VACUITY: could not stub _scan_file — the mutation harness has drifted from the source"
fi

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && printf '  ✅ adopter-facing surfaces resolve on an adopter (origin-only paths gated)\n'
[ "$FAIL" -eq 0 ]
