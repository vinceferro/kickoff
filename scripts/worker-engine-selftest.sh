#!/usr/bin/env bash
# worker-engine-selftest.sh — hermetic proof of the WORKER_ENGINE seam in session-run.sh:
#
#     argv/pre-set env  >  instance.env  >  default claude
#     — and the claude path stays BYTE-INTACT when the field is absent.
#
# What it proves, through a REAL session-run.sh spawn (pty-wrapped, exactly as the
# supervisor launches it):
#
#   (a) WORKER_ENGINE=opencode boots the TWO-PROCESS bridge topology: `opencode serve`
#       (with an explicit --port) AND the grinev opencode-telegram bot, carrying the
#       SAME adopter credentials the claude path reads — token from
#       .claude/settings.local.json (.env block), operator id from
#       $TELEGRAM_STATE_DIR/access.json (allowFrom[0]) — plus an OPENCODE_API_URL that
#       points at THE PORT serve was actually given. The claude stub NEVER runs.
#       [RED on pre-slice: the old wrapper had no such field and exec'd claude regardless]
#   (b) unset everywhere → the claude path is BYTE-INTACT: argv carries --channels,
#       --permission-mode and --append-system-prompt, and no opencode process runs
#       ("unset must never change today's behaviour" — the origin IS a live engine)
#   (c) WORKER_ENGINE=<unknown> fails LOUD before any engine spawns (closed set; the
#       value can arrive from a gitignored file)
#   (d) PRESET-WINS: a pre-set env WORKER_ENGINE=claude beats an instance.env line
#       saying opencode (v0.7 G1 §2.3, every seam, same rule)
#   (e) FAIL-CLOSED credentials: an adopter repo whose settings.local.json lacks the
#       token gets NO serve and NO bot — a loud fatal instead of a silently-deaf boot
#   (f) structural: the importer whitelist in session-run.sh carries WORKER_ENGINE
#   (g) MODEL PIN: OPENCODE_MODEL_PROVIDER/ID flow from instance.env to the bot's env,
#       and pre-set env beats the file line (same precedence rule as everything else)
#
# HOW IT STAYS HERMETIC (mirrors config-precedence-selftest.sh / ptywrap-selftest.sh):
#   - Runs the REAL scripts/session-run.sh directly (the launcher's env-hygiene boundary
#     is proven elsewhere; WORKER_ENGINE rides the SAME whitelisted importer).
#     REPO_DIR is always the fixture; ambient env is scrubbed by `env -i`.
#   - Stub engines: `opencode` handles BOTH modes (positional project = TUI-era arg;
#     `serve` = stays alive ~12s so the health gate passes, then dies bounded — no
#     immortal orphans); `opencode-telegram` dumps argv + the bridge env into its probe;
#     `claude` dumps argv. Stub `curl` is inert (health answers instantly; announce
#     never reaches a network); jq is REAL so credential extraction is exercised
#     against actual JSON, not a mock of it.
#   - The pty wrap runs FOR REAL via /usr/bin/script (stdin /dev/null → wrap → inner
#     tty), so the dispatch is exercised on the wrapped pass — the pass a live engine sees.
#
# RED-ON-OLD: scenario (a) is re-run against HEAD's session-run.sh (`git show`) and must
# FAIL there (old code exec'd claude regardless of WORKER_ENGINE). When the working tree
# is byte-identical to HEAD (normal post-commit state) the proof auto-SKIPS.
#
# Usage:  bash scripts/worker-engine-selftest.sh
# Exit non-zero on any failed assertion (or if RED-on-old is required but not proven).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SR_NEW="$SCRIPT_DIR/session-run.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/worker-engine-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home" "$WORK/chan"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %s\n' "$1"; }

# ── stub bin dir ─────────────────────────────────────────────────────────────
STUBDIR="$WORK/stubbin"
mkdir -p "$STUBDIR"

probe_body='
out="${ENGINE_PROBE_FILE:-}"
[ -n "$out" ] || exit 0
{
  printf "ENGINE %s\n" "${ENGINE_NAME-unknown}"
  for a in "$@"; do printf "ARG %s\n" "$a"; done
} > "$out"
exit 0
'
printf '#!/usr/bin/env bash\nENGINE_NAME=claude\nENGINE_PROBE_FILE="${CLAUDE_PROBE_FILE:-}"\n%b' "$probe_body" > "$STUBDIR/claude"
printf '#!/usr/bin/env bash\nENGINE_NAME=opencode\nENGINE_PROBE_FILE="${OPENCODE_TUI_PROBE_FILE:-}"\n%b' "$probe_body" > "$STUBDIR/opencode-tui-probe"

# stub `opencode`: dispatch on mode. TUI positional → record like any engine.
# `serve` → record argv, then stay alive ~12s (bounded) so the wrapper's health gate
# finds a live listener-side process; the bound keeps the fixture orphan-free.
cat > "$STUBDIR/opencode" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "serve" ]; then
  out="\${OPENCODE_SERVE_PROBE_FILE:-}"
  if [ -n "\$out" ]; then
    { printf 'ENGINE serve\n'; for a in "\$@"; do printf 'ARG %s\n' "\$a"; done; } > "\$out"
  fi
  for _ in \$(seq 1 12); do sleep 1; done
  exit 0
fi
exec "\$STUBDIR_DIRNAME/opencode-tui-probe" "\$@"
EOF
sed -i "s|\$STUBDIR_DIRNAME|$STUBDIR|" "$STUBDIR/opencode"

# stub bridge bot: record argv + the bridge env contract it was handed, then exit 0.
cat > "$STUBDIR/opencode-telegram" <<'EOF'
#!/usr/bin/env bash
out="${BRIDGE_PROBE_FILE:-}"
[ -n "$out" ] || exit 0
{
  for a in "$@"; do printf 'ARG %s\n' "$a"; done
  printf 'ENV TELEGRAM_BOT_TOKEN=%s\n' "${TELEGRAM_BOT_TOKEN-__unset__}"
  printf 'ENV TELEGRAM_ALLOWED_USER_ID=%s\n' "${TELEGRAM_ALLOWED_USER_ID-__unset__}"
  printf 'ENV OPENCODE_API_URL=%s\n' "${OPENCODE_API_URL-__unset__}"
  printf 'ENV OPENCODE_MODEL_PROVIDER=%s\n' "${OPENCODE_MODEL_PROVIDER-__unset__}"
  printf 'ENV OPENCODE_MODEL_ID=%s\n' "${OPENCODE_MODEL_ID-__unset__}"
} > "$out"
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBDIR/tail"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBDIR/curl"
chmod +x "$STUBDIR"/*

# shared operator allowlist (the ONE consumer-facing half of the credential pair)
printf '{"allowFrom": [4242]}\n' > "$WORK/chan/access.json"

make_repo() {  # $1=name, rest = extra instance.env lines ; prints the fixture repo path
  # Capture EVERYTHING derived from $1 BEFORE shifting — the token name and the repo
  # path both come from it, and losing either poisons every downstream lane at once.
  local fix="$WORK/$1"
  local token="TEST-TOKEN-$1"
  shift
  mkdir -p "$fix/.kickoff" "$fix/.claude"
  printf '{\n  "env": { "TELEGRAM_BOT_TOKEN": "%s" }\n}\n' "$token" > "$fix/.claude/settings.local.json"
  {
    printf 'TELEGRAM_STATE_DIR=%s\n' "$WORK/chan"
    local l; for l in "$@"; do printf '%s\n' "$l"; done
  } > "$fix/.kickoff/instance.env"
  printf '%s' "$fix"
}

# repo variant with the token deliberately ABSENT (fail-closed lane) — same shape as
# make_repo (extra args ARE the engine line; dropping them would silently test the
# wrong path, which is exactly the fixture-masks-the-bug failure this suite exists to kill)
make_repo_no_token() {
  local fix="$WORK/$1"; shift
  mkdir -p "$fix/.kickoff" "$fix/.claude"
  printf '{}\n' > "$fix/.claude/settings.local.json"
  {
    printf 'TELEGRAM_STATE_DIR=%s\n' "$WORK/chan"
    local l; for l in "$@"; do printf '%s\n' "$l"; done
  } > "$fix/.kickoff/instance.env"
  printf '%s' "$fix"
}

# run_sr SCRIPT FIXTURE CPROBE SERVEPROBE BOTPROBE LOG [K=V ...]
run_sr() {
  local sr="$1" fix="$2" cp_="$3" sp_="$4" bp_="$5" lg="$6"; shift 6
  rm -f "$cp_" "$sp_" "$bp_"
  ( cd "$fix" && timeout 40 env -i \
      PATH="$STUBDIR:/usr/bin:/bin" HOME="$WORK/home" TERM=dumb \
      CLAUDE_PROBE_FILE="$cp_" OPENCODE_SERVE_PROBE_FILE="$sp_" BRIDGE_PROBE_FILE="$bp_" \
      "$@" \
      bash "$sr" </dev/null >"$lg" 2>&1 )
}

probe_has_engine() { grep -q "^ENGINE $1\$" "$2" 2>/dev/null; }
probe_has_arg()    { grep -Fq "ARG $2" "$1" 2>/dev/null; }
probe_env()        { sed -n "s/^ENV $1=//p" "$2" 2>/dev/null | head -1; }

printf '== WORKER_ENGINE seam ==\n'

# (a) file value selects the engine — two-process bridge, correct credentials, matching ports
fix_a="$(make_repo repo-a WORKER_ENGINE=opencode)"
rc_a=0; run_sr "$SR_NEW" "$fix_a" "$WORK/a.claude" "$WORK/a.serve" "$WORK/a.bot" "$WORK/a.log" || rc_a=$?
if [ "$rc_a" -eq 0 ]; then ok "(a) session-run exits 0"; else bad "(a) exit=$rc_a — log: $(tail -3 "$WORK/a.log")"; fi
if probe_has_engine serve "$WORK/a.serve"; then ok "(a) opencode serve booted"; else bad "(a) no serve probe — log: $(tail -3 "$WORK/a.log")"; fi
if probe_has_arg "$WORK/a.serve" "--port"; then ok "(a) serve got an explicit --port"; else bad "(a) serve argv lacks --port"; fi
port_s="$(grep -A1 '^ARG --port$' "$WORK/a.serve" 2>/dev/null | tail -1 | sed 's/^ARG //')"
url="$(probe_env OPENCODE_API_URL "$WORK/a.bot")"
if [ -n "$port_s" ] && [ "$url" = "http://127.0.0.1:${port_s}" ]; then ok "(a) bot URL points at serve's actual port ($url)"; else bad "(a) port mismatch: serve=$port_s url=$url"; fi
tok="$(probe_env TELEGRAM_BOT_TOKEN "$WORK/a.bot")"
if [ "$tok" = "TEST-TOKEN-repo-a" ]; then ok "(a) token came from settings.local.json .env"; else bad "(a) token wrong/missing: '$tok'"; fi
uid="$(probe_env TELEGRAM_ALLOWED_USER_ID "$WORK/a.bot")"
if [ "$uid" = "4242" ]; then ok "(a) operator id came from access.json allowFrom[0]"; else bad "(a) user id wrong: '$uid'"; fi
if [ ! -s "$WORK/a.claude" ]; then ok "(a) claude NEVER ran on the opencode path"; else bad "(a) claude probe fired on opencode path"; fi
sticky="$(cat "$fix_a/.kickoff/opencode-bridge.port" 2>/dev/null)"
if [ "$sticky" = "$port_s" ]; then ok "(a) port persisted sticky in .kickoff"; else bad "(a) sticky port missing/mismatched: '$sticky' vs '$port_s'"; fi

# (b) unset everywhere → claude path byte-intact
fix_b="$(make_repo repo-b)"
rc_b=0; run_sr "$SR_NEW" "$fix_b" "$WORK/b.claude" "$WORK/b.serve" "$WORK/b.bot" "$WORK/b.log" || rc_b=$?
if [ "$rc_b" -eq 0 ] && probe_has_engine claude "$WORK/b.claude"; then ok "(b) default → claude exec'd"; else bad "(b) claude did not exec (rc=$rc_b) — log: $(tail -3 "$WORK/b.log")"; fi
for flag in "--channels" "--permission-mode" "--append-system-prompt"; do
  if probe_has_arg "$WORK/b.claude" "$flag"; then ok "(b) claude argv keeps $flag"; else bad "(b) claude argv LOST $flag"; fi
done
if [ ! -s "$WORK/b.bot" ] && [ ! -s "$WORK/b.serve" ]; then ok "(b) no opencode processes on the default path"; else bad "(b) opencode spawned on default path"; fi

# (c) unknown value fails LOUD before any engine spawns
fix_c="$(make_repo repo-c WORKER_ENGINE=netscape-navigator)"
rc_c=0; run_sr "$SR_NEW" "$fix_c" "$WORK/c.claude" "$WORK/c.serve" "$WORK/c.bot" "$WORK/c.log" || rc_c=$?
if [ "$rc_c" -ne 0 ]; then ok "(c) unknown engine exits non-zero (rc=$rc_c)"; else bad "(c) unknown engine exited 0"; fi
if grep -q "not a supported engine" "$WORK/c.log"; then ok "(c) stderr names the failure + the closed set"; else bad "(c) failure not named on stderr"; fi
if [ ! -s "$WORK/c.claude" ] && [ ! -s "$WORK/c.bot" ]; then ok "(c) NO engine spawned on a rejected config"; else bad "(c) an engine spawned despite the fatal config"; fi

# (d) preset-wins: env beats the gitignored file
fix_d="$(make_repo repo-d WORKER_ENGINE=opencode)"
rc_d=0; run_sr "$SR_NEW" "$fix_d" "$WORK/d.claude" "$WORK/d.serve" "$WORK/d.bot" "$WORK/d.log" WORKER_ENGINE=claude || rc_d=$?
if [ "$rc_d" -eq 0 ] && probe_has_engine claude "$WORK/d.claude"; then ok "(d) pre-set env WORKER_ENGINE beats the file line"; else bad "(d) precedence broken (rc=$rc_d) — log: $(tail -3 "$WORK/d.log")"; fi

# (e) fail-closed credentials: no token → loud fatal, nothing spawned
fix_e="$(make_repo_no_token repo-e WORKER_ENGINE=opencode)"
rc_e=0; run_sr "$SR_NEW" "$fix_e" "$WORK/e.claude" "$WORK/e.serve" "$WORK/e.bot" "$WORK/e.log" || rc_e=$?
if [ "$rc_e" -ne 0 ] && grep -q "refuses to boot deaf" "$WORK/e.log"; then ok "(e) missing token → loud fatal (rc=$rc_e)"; else bad "(e) missing token not caught loudly (rc=$rc_e)"; fi
if [ ! -s "$WORK/e.serve" ] && [ ! -s "$WORK/e.bot" ]; then ok "(e) nothing spawned without credentials"; else bad "(e) processes spawned despite missing token"; fi

# (f) structural: the importer whitelist carries the name
if grep -q "WORKER_ENGINE" "$SR_NEW"; then ok "(f) session-run.sh whitelist carries WORKER_ENGINE"; else bad "(f) WORKER_ENGINE missing from the importer whitelist"; fi

# (g) model pin: file value reaches the bot; env beats the file (preset-wins)
fix_g="$(make_repo repo-g WORKER_ENGINE=opencode OPENCODE_MODEL_PROVIDER=opencode OPENCODE_MODEL_ID=file-pin-model)"
rc_g=0; run_sr "$SR_NEW" "$fix_g" "$WORK/g.claude" "$WORK/g.serve" "$WORK/g.bot" "$WORK/g.log" || rc_g=$?
if [ "$rc_g" -eq 0 ] && [ "$(probe_env OPENCODE_MODEL_ID "$WORK/g.bot")" = "file-pin-model" ]; then ok "(g) instance.env model pin reached the bot"; else bad "(g) model pin lost (rc=$rc_g): '$(probe_env OPENCODE_MODEL_ID "$WORK/g.bot")' — log: $(tail -3 "$WORK/g.log")"; fi
prov="$(probe_env OPENCODE_MODEL_PROVIDER "$WORK/g.bot")"
if [ "$prov" = "opencode" ]; then ok "(g) provider pin reached the bot"; else bad "(g) provider wrong: '$prov'"; fi
rc_g2=0; run_sr "$SR_NEW" "$fix_g" "$WORK/g2.claude" "$WORK/g2.serve" "$WORK/g2.bot" "$WORK/g2.log" OPENCODE_MODEL_ID=env-wins-model || rc_g2=$?
if [ "$(probe_env OPENCODE_MODEL_ID "$WORK/g2.bot")" = "env-wins-model" ]; then ok "(g) pre-set env model beats the file line"; else bad "(g) model precedence broken: '$(probe_env OPENCODE_MODEL_ID "$WORK/g2.bot")'"; fi

# ── RED-on-old: scenario (a) must FAIL on HEAD's wrapper ────────────────────
OLD_SR="$WORK/session-run.HEAD.sh"
if git -C "$SCRIPT_DIR" show HEAD:scripts/session-run.sh > "$OLD_SR" 2>/dev/null; then
  if cmp -s "$OLD_SR" "$SR_NEW"; then
    skip "RED-on-old N/A — working tree byte-identical to HEAD (post-commit state)"
  else
    rc_old=0; run_sr "$OLD_SR" "$fix_a" "$WORK/old.claude" "$WORK/old.serve" "$WORK/old.bot" "$WORK/old.log" || rc_old=$?
    red=0
    if probe_has_engine claude "$WORK/old.claude" && [ ! -s "$WORK/old.bot" ]; then red=1; fi
    if [ "$red" -eq 1 ]; then ok "RED-on-old proven: HEAD ignored WORKER_ENGINE (claude fired instead)"; else bad "RED-on-old NOT proven — old wrapper behaved differently than spec'd (rc=$rc_old)"; fi
  fi
else
  skip "RED-on-old N/A — no git history available"
fi

printf '\n%d passed · %d failed · %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
