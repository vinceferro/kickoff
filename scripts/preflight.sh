#!/usr/bin/env bash
# preflight.sh — the fail-closed instance preflight (claude-kickoff)  [R2]
#
# ── THE CONTRACT ─────────────────────────────────────────────────────────────
# kickoff is adopted by OTHER repos. R1 made the core parameter-clean: each
# instance supplies ONE gitignored .kickoff/instance.env (copied from
# scripts/instance.env.example) that the launcher sources; the env lines are
# self-exporting (`export VAR="${VAR:-default}"`). That made the DOCS say "these
# must be distinct per instance" — but nothing ENFORCED it. R2 is the enforcement:
# it turns the adopt-time WARNINGS into ASSERTIONS that run before a session starts.
#
# This is a SAFETY CONTRACT, so it is FAIL-CLOSED by construction:
#   - a preflight that FALSE-PASSES is worse than none — it green-lights a broken
#     instance (e.g. two getUpdates pollers fighting over one bot token: the
#     "double-poller" footgun), so every ambiguous case leans FAIL.
#   - it runs ALL checks (NO `set -e` on the checks) and AGGREGATES into fails/warns,
#     so the operator sees every problem in ONE pass, then exits non-zero if ANY
#     hard assertion failed.
#
# ── WHERE IT RUNS ────────────────────────────────────────────────────────────
#   1. STANDALONE, at adoption-finalize:   bash scripts/preflight.sh
#      (an adopter proves .kickoff/instance.env is coherent before launching a worker).
#   2. From supervisor.sh, on EVERY supervisor start, BEFORE it acquires its own
#      lock — so the single-supervisor check (#4) sees only OTHER live supervisors,
#      and a mis-configured instance can never start a session.
#
# ── OVERRIDES (for the supervisor wiring + tests) ────────────────────────────
#   REPO_DIR=  INSTANCE_ENV=  LOCKFILE=   — resolved exactly as supervisor.sh does.
#   KICKOFF_CORE_DIR=  — the pinned core clone (base for the core.lock paths, check #6).
#                        Falls back to the tree this script actually RUNS from.
#
# instance.env is UNTRUSTED-shaped CONFIG (gitignored, invisible in review), so it is
# NOT sourced into this shell. A subshell sources it and imports back ONLY a fixed
# whitelist of config var NAMES — an `exit 0`, a redefined fail()/warn(), or a forged
# launch-control var in the file cannot neuter a check or cross into the preflight
# (see _import_instance_env, #13).
#
# EXIT: 0 = all HARD checks passed (warnings allowed);  1 = >=1 hard failure.

# Intentionally NOT `set -e`: a failing check must not abort the run — we surface
# every problem in one pass. `-u` (catches our OWN typos; an unset ref only ever
# ABORTS = non-zero = still fail-closed) and pipefail stay on.
set -uo pipefail

# ── path resolution (same shape as supervisor.sh) ────────────────────────────
REPO_DIR="${REPO_DIR:-$(pwd)}"
if ! REPO_DIR="$(cd "$REPO_DIR" 2>/dev/null && pwd)"; then
  printf '[preflight] FATAL: REPO_DIR does not exist or is not accessible\n' >&2
  exit 1
fi
# The core tree that is ACTUALLY EXECUTING (this script + its siblings supervisor.sh /
# session-run.sh). Derived from THIS script's own location, exactly as supervisor.sh
# derives SCRIPT_DIR — a pull adopter runs the core from ~/kickoff-core while REPO_DIR
# is their OWN repo. Used to (a) detect a pull adopter (#1b) and (b) checksum core.lock
# against the tree that RUNS, not a pristine clone a patched copy could hide behind (#14).
RUNNING_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd || true)"
KICKOFF_DIR="$REPO_DIR/.kickoff"
INSTANCE_ENV="${INSTANCE_ENV:-$KICKOFF_DIR/instance.env}"
LOCKFILE="${LOCKFILE:-$KICKOFF_DIR/supervisor.lock}"      # the supervisor's single-instance lock
CORE_LOCK="$KICKOFF_DIR/core.lock"                        # optional R3 core-integrity manifest

# ── aggregation + reporting helpers ──────────────────────────────────────────
# fail/warn → stderr (problems); ok → stdout (the passing trace). fails drives the exit.
fails=0
warns=0
# PREFLIGHT_SCOPE — set ONLY from argv (the `--pin` flag), never from the environment, so it can
# NEVER be inherited ambiently or smuggled via instance.env. A caller gets pin scope ONLY by passing
# `--pin` on THIS invocation; every other caller — supervisor.sh's worker-start gate, a manual
# `kickoff preflight` — passes no flag and gets FULL scope by construction (the fail-closed default).
#   full (default) = every check, byte-behaviour-identical to today.
#   pin (`--pin`)  = ONLY the pin-integrity checks (#6 core.lock + #8 seam/plugin-cache); the
#     session-readiness checks (#1,#1b-assertions,#2,#3,#4,#5) and the soft #7 are skipped. Used by
#     `kickoff pull`, whose false-fail was #4 firing on the adopter's OWN live worker lock.
PREFLIGHT_SCOPE=full
for _pf_arg in "$@"; do case "$_pf_arg" in --pin) PREFLIGHT_SCOPE=pin ;; esac; done   # unknown args ignored (preserves the `kickoff preflight "$@"` passthrough)
fail() { printf '  [FAIL] %s\n' "$*" >&2; fails=$((fails + 1)); }
warn() { printf '  [warn] %s\n' "$*" >&2; warns=$((warns + 1)); }
ok()   { printf '  [ ok ] %s\n' "$*"; }

# ── canonicalization + config-import helpers ─────────────────────────────────
# _canon: normalise a path WITHOUT requiring it to exist (-m) and resolve symlinks,
# so a trailing slash / `.` / symlink can't disguise two equal paths as distinct
# (checks #2, #1b, #6). Fallback chain keeps working on a box missing one tool; the
# last resort is the raw string (a canonicalisation we can't do must not crash the run).
_canon() {
  local p="${1-}" out
  [ -z "$p" ] && { printf ''; return 0; }
  if out="$(realpath -m -- "$p" 2>/dev/null)"; then printf '%s' "$out"; return 0; fi
  if out="$(readlink -m -- "$p" 2>/dev/null)"; then printf '%s' "$out"; return 0; fi
  printf '%s' "$p"
}

# Canonicalise the two identity paths ONCE, now that _canon exists, so every downstream
# containment/equality test (#1b pull-adopter detection, #6/#14 running-vs-pinned core,
# _resolve_in_repo) compares like-for-like. Without this, a symlinked $HOME / clone path
# makes core_base (realpath -m) differ from RUNNING_CORE_DIR (logical `pwd`) and the RUNNING
# core spuriously reads as "outside the repo" / "not the pinned clone" — a fail-closed but
# WRONG hard-stop of a legitimate worker after a routine pull (F1). File access is
# symlink-transparent, so the already-built KICKOFF_DIR/INSTANCE_ENV/… paths are unaffected.
REPO_DIR="$(_canon "$REPO_DIR")"
RUNNING_CORE_DIR="$(_canon "$RUNNING_CORE_DIR")"

# _resolve_in_repo: given a config VALUE (absolute or REPO_DIR-relative), print its
# canonical path and return 0 iff it resolves INSIDE REPO_DIR (== or under it). The
# `case "$p/"` form rejects a sibling like "<repo>-evil" that merely shares the prefix.
_resolve_in_repo() {
  local v="${1-}" p
  case "$v" in
    /*) p="$v" ;;
    *)  p="$REPO_DIR/$v" ;;
  esac
  p="$(_canon "$p")"
  printf '%s' "$p"
  case "$p/" in "$REPO_DIR/"*) return 0 ;; esac
  return 1
}

# The ONLY config var NAMES the preflight accepts FROM instance.env. instance.env is
# untrusted-shaped config, so it is sourced in a SUBSHELL that echoes back only these
# names as NUL-delimited NAME=VALUE pairs — a redefined fail()/warn(), an `exit 0`, or
# any non-whitelisted / launch-control var (PREFLIGHT_SKIP, DRY_RUN, …) set inside the
# file dies with the subshell and never reaches the checks. (REPO_DIR is intentionally
# NOT re-imported: it is the instance identity, resolved authoritatively above; config
# does not redefine it. PERMISSION_MODE is intentionally NOT imported either — v0.7 G1
# §2.3: the autonomy grant flows argv / terminal env ONLY, never a gitignored file.)
# AUTO_PICKUP IS imported: unlike PERMISSION_MODE it is durable per-adopter policy on the
# same footing as MODEL/EFFORT (the bounded-grant half — it still stops at every gate), not
# the argv-only grant.
INSTANCE_ENV_WHITELIST=(
  KICKOFF_CORE_DIR
  MC_STATE_FILE MC_TRACKER_FILE
  MEMORY_DB MEMORY_HOOK_LOG MEMORY_DIR MEMORY_INDEX
  TELEGRAM_STATE_DIR CHANNEL_SPEC
  REGROUND_PROMPT
  MODEL EFFORT MAX_CONCURRENT_AGENTS
  DEPLOY_BRANCH CADENCE AUTO_PICKUP
  WORKER_ENGINE OPENCODE_MODEL_PROVIDER OPENCODE_MODEL_ID
)
# A whitelisted var ALREADY set in the environment is a PRE-SET value from the TRUSTED launcher
# (env/argv), and it WINS over the gitignored instance.env — exactly the contract the front door's
# load_instance_env documents ("a pre-set env / argv value wins"). This is load-bearing for the
# parked-worktree case: `kickoff pull` passes KICKOFF_CORE_DIR=<the worktree it pinned>, but the
# adopter's instance.env still names the ROOT clone; without honoring the pre-set value, #6's
# running-vs-pinned assertion (#14) would false-fail a legitimate worktree pull. Captured BEFORE
# the #1 import overwrites anything. (No security loss: the environment is set by the trusted
# launcher, not the untrusted instance.env; #6 stays fail-closed regardless.)
# TELEGRAM_STATE_DIR is the ONE whitelisted name EXEMPT from pre-set-wins — it is the READER half
# of the core-v0.27 cross-wire (whose WRITER half was cmd_pull/cmd_adopt stamping the caller's
# channel onto the adoptee's row). The pre-set-wins premise is "the environment was set by the
# trusted launcher FOR THIS REPO"; that premise holds for KICKOFF_CORE_DIR (the parked-worktree
# case it was written for) and FAILS for the channel: a `kickoff pull`/preflight for repo B run
# from INSIDE repo A's worker session carries A's channel ambiently, and honoring it makes #2
# evaluate A's channel as if it were B's — reporting A's dir as B's worker channel and then
# FAILING "channel clash" against A itself. A phantom clash, and fail-closed, so it blocks B's
# pull and A's engine hop on a box where no clash exists. The repo's OWN instance.env is the only
# authority on the repo's OWN channel — the same pinning `_channel_of_repo` (kickoff:294) applies
# on the writer side. When instance.env does NOT define a channel, nothing is emitted and the
# ambient value still stands: that is the best available answer, not a leak.
_PREFLIGHT_PRESET_EXEMPT=(TELEGRAM_STATE_DIR)
# space-delimited mirror of the array, for a `case` membership test (this file's idiom) that
# cannot fall through to a non-zero status the way a nested loop's last failed `[ ]` would.
printf -v _PRESET_EXEMPT_SET ' %s ' "${_PREFLIGHT_PRESET_EXEMPT[@]}"
declare -A _PREFLIGHT_PRESET=()
for _pn in "${INSTANCE_ENV_WHITELIST[@]}"; do
  case "$_PRESET_EXEMPT_SET" in *" $_pn "*) continue ;; esac
  [ -n "${!_pn+x}" ] && _PREFLIGHT_PRESET["$_pn"]=1
done
_import_instance_env() {
  # $1 = instance.env path. Runs in a SUBSHELL; cd REPO_DIR first so a `$PWD/…` default
  # in the config resolves into the ADOPTER's repo, not wherever the preflight was run.
  (
    cd "$REPO_DIR" 2>/dev/null || true
    # Exempting TELEGRAM_STATE_DIR from pre-set-wins (above) is only HALF the fix: adopters ship the
    # self-defaulting `export TELEGRAM_STATE_DIR="${TELEGRAM_STATE_DIR:-…}"` form that
    # instance.env.example seeds, so an ambient value survives a plain source and the repo's own
    # default never fires. Unset it here so the `:-` default resolves to THIS repo's channel —
    # the same reason the unset is load-bearing inside `_channel_of_repo`.
    unset "${_PREFLIGHT_PRESET_EXEMPT[@]}"
    set +u
    # shellcheck disable=SC1090
    . "$1" >/dev/null 2>&1
    for _n in "${INSTANCE_ENV_WHITELIST[@]}"; do
      # emit only names the (sourced) config actually SET — unset stay unset in the parent
      [ -n "${!_n+x}" ] && printf '%s=%s\0' "$_n" "${!_n}"
    done
  )
}

# _covers_bare_git_push: does ONE Claude permission-rule string actually DENY a bare
# `git push`? (check #5). A Bash(...) rule blocks it iff its command prefix is a prefix
# of the tokens [git, push]:  Bash(git push) / Bash(git push:*) / Bash(git:*).  A rule
# with EXTRA required args (Bash(git push origin main:*)) does NOT block a plain push,
# and a non-Bash tool never does — both are rejected. This anchors what the old
# substring regex left unanchored (the deploy-fence false-pass, #3).
_covers_bare_git_push() {
  local rule="$1" inner cmd wild=0
  case "$rule" in
    Bash\(*\)) inner="${rule#Bash(}"; inner="${inner%)}" ;;
    *) return 1 ;;
  esac
  case "$inner" in
    *:\*) wild=1; cmd="${inner%:\*}" ;;
    *)    wild=0; cmd="$inner" ;;
  esac
  local -a toks=()
  read -ra toks <<< "$cmd"
  local n=${#toks[@]}
  if [ "$wild" = "1" ]; then
    # prefix rule: tokens must be a prefix of [git, push]  → Bash(git:*) or Bash(git push:*)
    { [ "$n" -eq 1 ] && [ "${toks[0]}" = "git" ]; } && return 0
    { [ "$n" -eq 2 ] && [ "${toks[0]}" = "git" ] && [ "${toks[1]}" = "push" ]; } && return 0
    return 1
  fi
  # exact rule: must be exactly `git push`  → Bash(git push)
  { [ "$n" -eq 2 ] && [ "${toks[0]}" = "git" ] && [ "${toks[1]}" = "push" ]; } && return 0
  return 1
}

printf '[preflight] fail-closed instance preflight — repo=%s\n' "$REPO_DIR"
# ⚠ DETECTION CONTRACT — DO NOT reword/remove the literal token `scope=pin` in the banner below:
# `kickoff pull` greps this preflight's SOURCE for `scope=pin` to detect whether a pulled tag SUPPORTS
# pin scope (its rollback-honesty summary keys off that). Change it and cmd_pull's grep together.
if [ "$PREFLIGHT_SCOPE" = pin ]; then
  printf '[preflight] scope=pin — verifying the core PIN only (#6 core.lock + #8 seam/plugin); session-readiness (channel, supervisor, memory, deploy-fence) is deferred to `kickoff preflight` before the worker next starts.\n'
fi

# ── 1. instance.env present (imported via a whitelist subshell, #13) ─────────
# HARD: the whole parameter-clean model rests on this file existing. It is imported
# through _import_instance_env (a subshell that returns only whitelisted var names),
# NOT sourced into this shell — so it can neither neuter the checks nor forge control.
if [ "$PREFLIGHT_SCOPE" = full ]; then
if [ -f "$INSTANCE_ENV" ]; then
  _imported=0
  while IFS= read -r -d '' _pair; do
    _name="${_pair%%=*}"
    # only ever a whitelisted identifier (emit side is fixed) — guard printf -v anyway
    [[ "$_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    # a PRE-SET env/launcher value WINS over the untrusted instance.env (see _PREFLIGHT_PRESET).
    [ -n "${_PREFLIGHT_PRESET[$_name]:-}" ] && continue
    printf -v "$_name" '%s' "${_pair#*=}"
    _imported=$((_imported + 1))
  done < <(_import_instance_env "$INSTANCE_ENV")
  if [ "$_imported" -gt 0 ]; then
    ok "instance.env present and imported ($INSTANCE_ENV; $_imported whitelisted var(s) — untrusted file read in a subshell)"
  else
    warn "instance.env present ($INSTANCE_ENV) but set NO recognized config vars (an \`exit 0\` at the top, or every line commented?) — downstream checks will fail-closed on the missing values"
  fi
else
  fail "instance.env MISSING ($INSTANCE_ENV) — copy scripts/instance.env.example to it"
fi
fi

# ── 1b. pull-adopter data-path isolation (#1/#9) ─────────────────────────────
# A pull adopter runs the UNCHANGED core from OUTSIDE its own repo. mc-update.py + the
# memory-retrieval libs DEFAULT their data paths relative to the CODE's location, so if
# MC_STATE_FILE / MEMORY_DB / MEMORY_HOOK_LOG are left unset this instance's board +
# memory index get written INTO the shared core clone (cross-instance leak; a blank
# board on the operator's phone). HARD-REQUIRE them SET and resolving INSIDE this repo.
# Fires when: core.lock present (⇒ `kickoff pull` ran ⇒ definitive pull adopter) OR the
# RUNNING core is OUTSIDE REPO_DIR (the code isn't in this repo — a manual clone). This
# generalises the finding's "KICKOFF_CORE_DIR resolves outside REPO_DIR" to the ground
# truth (where the code ACTUALLY runs), so it can never mis-fire on kickoff itself:
# kickoff / greenfield has NO core.lock AND runs its core from INSIDE REPO_DIR ⇒ skipped
# (it keeps the repo-relative BASE_DIR defaults, per the frozen cross-file contract).
core_inside_repo=1
if [ -n "$RUNNING_CORE_DIR" ]; then
  case "$RUNNING_CORE_DIR/" in
    "$REPO_DIR/"*) core_inside_repo=1 ;;
    *) core_inside_repo=0 ;;
  esac
fi
if [ "$PREFLIGHT_SCOPE" = full ]; then
if [ -f "$CORE_LOCK" ] || [ "$core_inside_repo" -eq 0 ]; then
  for _dv in MC_STATE_FILE MEMORY_DB MEMORY_HOOK_LOG; do
    _raw="${!_dv-}"
    _trim="$(printf '%s' "$_raw" | tr -d '[:space:]')"
    if [ -z "$_trim" ]; then
      fail "$_dv unset/blank but this is a PULL ADOPTER (core runs from outside $REPO_DIR) — set it in instance.env to a path INSIDE your repo (the defaults live under .kickoff/state/ + .kickoff/memory/, scaffolded by \`kickoff adopt\`/\`init\`), or this instance's data lands in the shared core clone"
      continue
    fi
    if _rp="$(_resolve_in_repo "$_raw")"; then
      ok "$_dv resolves inside the repo ($_rp)"
    else
      fail "$_dv ($_raw → $_rp) resolves OUTSIDE the repo ($REPO_DIR) — a pull adopter MUST keep board/memory data in its OWN repo, not the shared core clone"
    fi
  done
else
  ok "not a pull adopter (no core.lock; core runs from inside the repo) — data-path isolation check skipped"
fi
fi

# ── 2. worker channel valid (the double-poller guard) ────────────────────────
# HARD: unset OR the example placeholder → the worker would collide on a shared
# channel (one bot token = one getUpdates consumer).
# Trim whitespace for the empty-check so a blank " " channel can't slip through [ -z ].
if [ "$PREFLIGHT_SCOPE" = full ]; then
tsd_trimmed="$(printf '%s' "${TELEGRAM_STATE_DIR:-}" | tr -d '[:space:]')"
if [ -z "$tsd_trimmed" ]; then
  fail "TELEGRAM_STATE_DIR unset or blank — a DEDICATED channel dir is REQUIRED to run the worker; set it in $INSTANCE_ENV (no default on purpose: inheriting a channel is the double-poller footgun). NO bot token is needed to pass THIS check — the bot is wired later via \`kickoff setup\` + \`/setup\`"
else
  # Case-insensitive placeholder match (catches YOUR-WORKER / your-worker alike).
  case "${TELEGRAM_STATE_DIR,,}" in
    *your-worker*)
      fail "TELEGRAM_STATE_DIR still holds the example placeholder ($TELEGRAM_STATE_DIR) — a DEDICATED channel dir is REQUIRED to run the worker; set a REAL one. NO bot token is needed to pass THIS check — the bot is wired later via \`kickoff setup\` + \`/setup\`" ;;
    *)
      ok "worker channel set (TELEGRAM_STATE_DIR=$TELEGRAM_STATE_DIR)" ;;
  esac
fi
# Sibling-channel guards: canonicalize BOTH sides (realpath -m) so a trailing slash, a `.`,
# or a symlink can't disguise a SHARED channel dir as distinct. Two guards run here:
if [ -n "${TELEGRAM_STATE_DIR:-}" ]; then
  tsd_canon="$(_canon "$TELEGRAM_STATE_DIR")"
  # (a) env-var guard — a HARMLESS belt: ORIGIN_STATE_DIR/OPERATOR_STATE_DIR would name a sibling
  #     channel via the environment, but nothing in the stack actually EXPORTS them, so this is
  #     near-dead-code kept only for a caller that does set them. It is NOT the load-bearing check.
  if [ -n "${ORIGIN_STATE_DIR:-}" ] && [ "$(_canon "$ORIGIN_STATE_DIR")" = "$tsd_canon" ]; then
    fail "TELEGRAM_STATE_DIR == ORIGIN_STATE_DIR (canonically $tsd_canon) — worker points at ORIGIN's channel (the pollers will fight)"
  fi
  if [ -n "${OPERATOR_STATE_DIR:-}" ] && [ "$(_canon "$OPERATOR_STATE_DIR")" = "$tsd_canon" ]; then
    fail "TELEGRAM_STATE_DIR == OPERATOR_STATE_DIR (canonically $tsd_canon) — worker shares the OPERATOR's interactive channel (the pollers will fight)"
  fi
  # (b) registry-backed guard (G10b) — the REAL two-adopter check. The genuine footgun is two
  #     SEPARATE repos on this box, each with its OWN dedicated channel in its OWN instance.env:
  #     invisible to each other via env, but BOTH recorded (canonically) in the machine adopters
  #     registry. Ask it — does any OTHER registered adopter share MY canonical channel? Positive
  #     clash ⇒ FAIL (one bot token = one getUpdates consumer). Pass MY FRESH instance.env channel
  #     as authority; empty output / no tool / registry-absent ⇒ skip (no clash to report).
  _am_clash_tool="$RUNNING_CORE_DIR/scripts/adopt-manifest.py"
  if [ -f "$_am_clash_tool" ]; then
    _chan_clash="$(REPO_DIR="$REPO_DIR" python3 "$_am_clash_tool" adopters-channel-clash --repo "$REPO_DIR" --channel "$TELEGRAM_STATE_DIR" 2>/dev/null || true)"
    if [ -n "$_chan_clash" ]; then
      fail "channel clash — another registered adopter on this box shares this repo's canonical Telegram channel ($tsd_canon); one bot token = one getUpdates consumer, so the workers' pollers will fight: $(printf '%s' "$_chan_clash" | tr '\n' ' ')"
    else
      ok "no registry channel clash (no OTHER registered adopter shares this repo's channel)"
    fi
  fi
fi
fi

# ── 2b. worker engine (the opencode seam — only when WORKER_ENGINE names one) ─
# Fail-closed BEFORE boot, not mid-launch: an unknown engine name or a missing
# binary must stop the supervisor HERE. A config fatal inside session-run.sh instead
# becomes a supervisor restart loop — exactly the crash-loop the guards exist to prevent.
_we_engine="${WORKER_ENGINE:-}"
case "$_we_engine" in
  ""|claude) : ;;   # default path — nothing to verify
  opencode)
    if ! command -v opencode >/dev/null 2>&1; then
      fail "WORKER_ENGINE=opencode but no 'opencode' binary on PATH — install it or unset WORKER_ENGINE in $INSTANCE_ENV"
    fi
    if ! command -v opencode-telegram >/dev/null 2>&1; then
      fail "WORKER_ENGINE=opencode but 'opencode-telegram' is not installed — npm install -g --prefix ~/.local @grinev/opencode-telegram-bot"
    fi
    ;;
  *)
    fail "WORKER_ENGINE='$_we_engine' is not a supported engine (claude|opencode) — fix it in $INSTANCE_ENV" ;;
esac

# ── 3. memory index resolves ─────────────────────────────────────────────────
# HARD: the re-ground prompt points the worker here first; a dangling index means
# a worker that can't re-ground. Resolution CHAIN (§D): an explicit MEMORY_INDEX wins;
# else the adopter corpus `.kickoff/memory/MEMORY.md` when present; else the repo-root
# `memory/MEMORY.md` (keeps kickoff-itself + repo-root adopters green — they carry their corpus at
# repo-root memory/ via their own instance.env/defaults). Resolve relative to REPO_DIR
# when not absolute.
if [ "$PREFLIGHT_SCOPE" = full ]; then
if [ -n "${MEMORY_INDEX:-}" ]; then
  mem="$MEMORY_INDEX"
elif [ -f "$KICKOFF_DIR/memory/MEMORY.md" ]; then
  mem=".kickoff/memory/MEMORY.md"
else
  mem="memory/MEMORY.md"
fi
case "$mem" in
  /*) mem_path="$mem" ;;
  *)  mem_path="$REPO_DIR/$mem" ;;
esac
if [ -f "$mem_path" ] && [ -r "$mem_path" ]; then
  ok "memory index resolves and is readable ($mem_path)"
else
  fail "memory index is not a readable file: $mem_path  (MEMORY_INDEX=${MEMORY_INDEX:-<unset>}) — \`kickoff init\`/\`adopt\` seeds the .kickoff/memory/MEMORY.md stub"
fi
fi

# ── 3b. memory RETRIEVAL index built (SOFT — warn only, never fail) ──────────
# #3 checks the human-curated MEMORY.md index; the proactive recall hook additionally reads a
# DERIVED SQLite index (MEMORY_DB) built from the corpus (MEMORY_DIR). `kickoff adopt` now builds
# it once, but an adopt that ran node-less (or on an older core) leaves the corpus present and the
# DB absent — and recall then silently no-ops FOREVER (the first-adopter shape: wired, never fired).
# LOUD warn, NEVER a fail: keyword-grep over the .md files still works, and a legit node-less
# adopt must not brick `kickoff up` (this runs at every supervisor start). Skipped when either
# path is unset (kickoff-origin / a pre-corpus instance — nothing coherent to assert).
if [ "$PREFLIGHT_SCOPE" = full ]; then
if [ -n "${MEMORY_DIR:-}" ] && [ -n "${MEMORY_DB:-}" ]; then
  case "$MEMORY_DIR" in /*) _ri_dir="$MEMORY_DIR" ;; *) _ri_dir="$REPO_DIR/$MEMORY_DIR" ;; esac
  case "$MEMORY_DB"  in /*) _ri_db="$MEMORY_DB"  ;; *) _ri_db="$REPO_DIR/$MEMORY_DB"  ;; esac
  _ri_has_md=0
  if [ -d "$_ri_dir" ]; then
    for _ri_f in "$_ri_dir"/*.md; do [ -e "$_ri_f" ] && { _ri_has_md=1; break; }; done
  fi
  if [ "$_ri_has_md" = 1 ] && [ ! -f "$_ri_db" ]; then
    warn "memory corpus present ($_ri_dir has .md facts) but NEVER indexed ($_ri_db absent) — proactive recall is INERT; re-run \`kickoff adopt\` (it builds the index) or by hand: MEMORY_DIR=$_ri_dir MEMORY_DB=$_ri_db node --experimental-sqlite \$KICKOFF_CORE_DIR/memory-retrieval/index.mjs → run \`kickoff doctor\` to back-fill."
  elif [ "$_ri_has_md" = 1 ]; then
    ok "memory retrieval index present ($_ri_db) — proactive recall has an index to read"
  else
    ok "no memory corpus .md files yet ($_ri_dir) — retrieval-index check skipped"
  fi
else
  ok "MEMORY_DIR/MEMORY_DB not both configured — retrieval-index check skipped (origin / pre-corpus instance)"
fi
fi

# ── 4. single supervisor ─────────────────────────────────────────────────────
# HARD: another LIVE supervisor (lock PID that is alive AND is not us) would fight
# over the managed session. Called BEFORE supervisor.sh acquires its own lock, so
# any live lock at this point is a genuine OTHER supervisor. Stale/absent → ok.
if [ "$PREFLIGHT_SCOPE" = full ]; then
if [ -f "$LOCKFILE" ]; then
  other="$(cat "$LOCKFILE" 2>/dev/null || echo "")"
  # Require a real positive PID before kill -0: a corrupt lock of "0"/"-1" would make
  # kill -0 succeed (it signals the whole group / every proc) → a false "live supervisor"
  # → a false refusal to start. A non-PID value is treated as a stale/reclaimable lock.
  if [ -n "$other" ] && [[ "$other" =~ ^[1-9][0-9]*$ ]] && kill -0 "$other" 2>/dev/null; then
    if [ "$other" = "$$" ] || [ "$other" = "$PPID" ]; then
      ok "supervisor lock is our own (pid=$other) — not a competing supervisor"
    else
      fail "another supervisor is LIVE (pid=$other, lock=$LOCKFILE) — refusing (it would fight over the managed session)"
    fi
  else
    ok "supervisor lock is stale/empty (pid='$other') — reclaimable, no live supervisor"
  fi
else
  ok "no supervisor lock present — no competing supervisor"
fi
fi

# ── 5. deploy-fence (conditional — only when DEPLOY_BRANCH is declared) ───────
# HARD: if this instance declares a push=deploy branch, there MUST be a git-push
# DENY in the Claude settings — a push=deploy branch with no fence means an
# accidental `git push` IS a deploy. Unset (kickoff) → skip.
if [ "$PREFLIGHT_SCOPE" = full ]; then
if [ -n "${DEPLOY_BRANCH:-}" ]; then
  # STRUCTURALLY validate the rule shape (#3), not a coarse substring: extract each
  # deny entry from the deny array and require ONE that actually blocks a bare
  # `git push` (Bash(git push) / Bash(git push:*) / Bash(git:*)). A substring match
  # false-passes on a deny that adds required args (Bash(git push origin main:*)) or
  # lives in an allow rule / a non-Bash tool — the exact push=deploy hole. jq is a
  # system dep here (session-run.sh uses it); absent → we cannot verify → fail-closed.
  if command -v jq >/dev/null 2>&1; then
    deny_found=0
    for sf in "$REPO_DIR/.claude/settings.local.json" "$REPO_DIR/.claude/settings.json"; do
      [ -f "$sf" ] || continue
      while IFS= read -r rule; do
        [ -n "$rule" ] || continue
        if _covers_bare_git_push "$rule"; then deny_found=1; break; fi
      done < <(jq -r '(.permissions.deny // [])[]? | select(type=="string")' "$sf" 2>/dev/null)
      [ "$deny_found" = "1" ] && break
    done
    if [ "$deny_found" = "1" ]; then
      ok "deploy-fence present (DEPLOY_BRANCH=$DEPLOY_BRANCH; a permissions.deny rule actually blocks a bare 'git push')"
    else
      fail "DEPLOY_BRANCH=$DEPLOY_BRANCH declared but NO permissions.deny rule in .claude/settings*.json blocks a bare 'git push' — need e.g. Bash(git push:*) or Bash(git push); a deny with extra required args (Bash(git push origin main:*)) or a non-Bash tool does NOT fence a plain push, and an accidental push is a deploy"
    fi
  else
    fail "DEPLOY_BRANCH=$DEPLOY_BRANCH declared but jq unavailable — cannot verify the git-push deploy-fence (fail-closed)"
  fi
else
  ok "no DEPLOY_BRANCH declared — deploy-fence check skipped"
fi
fi

# ── 6. core.lock integrity (conditional — only when core.lock exists) ─────────
# HARD: if a core-integrity artifact exists (a `kickoff pull` product), the pinned core must
# match it — a mismatch means a core file was hand-edited (copied-and-patched), the exact
# copy-fragmentation R1 set out to kill. TWO lock formats are accepted for the migration window:
#   NEW (format 2): a WHOLE-TREE pin — `format 2` / `tag <t>` / `commit <sha>`. The core IS the
#     git checkout at the base; #6 asserts HEAD==commit, tag^{commit}==commit, and a CLEAN tree
#     (scoped to the clone dir). O(1), and it pins the WHOLE tree, not just manifest files.
#   OLD (per-file): `<sha256>  <path>` GNU sha256sum lines, verified with `sha256sum -c --strict`.
# Absent → skip. NOTE: core.lock is unsigned — a drift/copied-and-patched check, NOT anti-tamper
# (someone who can rewrite core files can regenerate the lock).
if [ -f "$CORE_LOCK" ]; then
  # base = the DECLARED pinned clone when set (KICKOFF_CORE_DIR, passed by `kickoff pull` / the
  # supervisor), else the tree that actually RUNS. Verifying against the RUNNING tree (plus the
  # #14 assertion below) closes the hole where a patched running copy hides behind a pristine
  # declared clone.
  if [ -n "${KICKOFF_CORE_DIR:-}" ]; then
    core_base="$(_canon "$KICKOFF_CORE_DIR")"
  else
    core_base="$RUNNING_CORE_DIR"
  fi

  # DETECT the lock format from the FIRST non-comment line (the migration window accepts BOTH):
  #   NEW whole-tree pin: `format 2` then `tag <t>` / `commit <sha>` keys (§7 step 4d, Fix 6)
  #   OLD per-file lock:  `<64hex>  <path>` GNU sha256sum lines
  lock_first=""
  while IFS= read -r cl_line || [ -n "$cl_line" ]; do
    [ -z "$cl_line" ] && continue
    case "$cl_line" in \#*) continue ;; esac
    lock_first="$cl_line"; break
  done < "$CORE_LOCK"
  lock_is_new=0
  case "$lock_first" in "format "*) lock_is_new=1 ;; esac

  if [ -z "$core_base" ]; then
    fail "core.lock present but the checksum base could not be resolved (KICKOFF_CORE_DIR / running-core dir empty) — cannot verify core integrity (fail-closed)"
  # (#14) The core that ACTUALLY RUNS must be the pinned clone we verify — enforced on BOTH lock
  # formats, so a patched running copy can never hide behind a pristine declared KICKOFF_CORE_DIR.
  elif [ -n "${KICKOFF_CORE_DIR:-}" ] && [ -n "$RUNNING_CORE_DIR" ] && [ "$core_base" != "$RUNNING_CORE_DIR" ]; then
    fail "the core that is RUNNING ($RUNNING_CORE_DIR) is NOT the pinned KICKOFF_CORE_DIR ($core_base) — a patched running copy would go unverified; launch the supervisor FROM the pinned clone, or fix KICKOFF_CORE_DIR"
  elif [ "$lock_is_new" = "1" ]; then
    # ── NEW whole-tree pin (format 2) — the pin IS: HEAD==commit, tag^{commit}==commit, clean tree ──
    lock_tag=""; lock_commit=""
    while IFS= read -r cl_line || [ -n "$cl_line" ]; do
      case "$cl_line" in
        "tag "*)    lock_tag="${cl_line#tag }" ;;
        "commit "*) lock_commit="${cl_line#commit }" ;;
      esac
    done < "$CORE_LOCK"
    # PARITY WITH _eitp (scripts/kickoff), which has done both of these since v0.26. This site had
    # neither, and the sibling drift is exactly what this release is about.
    #  · TRIM — a lock written on a CRLF machine, or hand-edited with a trailing space, carries the
    #    whitespace into the value; `refs/tags/core-v0.30\r` resolves to nothing, so a REAL pin
    #    would read as an absent tag and fail closed on a healthy adopter.
    #  · RENDER SAFE for printing — these values come from a file this engine did not write and are
    #    interpolated straight into operator-facing check lines. ESC sequences can repaint the line,
    #    and a lock carrying `✓ the pin HOLDS` forges a tick inside a refusal. The lookup keeps the
    #    real (trimmed) value; only what is PRINTED is reduced.
    while [ "$lock_tag" != "${lock_tag%[[:space:]]}" ]; do lock_tag="${lock_tag%[[:space:]]}"; done
    while [ "$lock_commit" != "${lock_commit%[[:space:]]}" ]; do lock_commit="${lock_commit%[[:space:]]}"; done
    _pin_safe() {   # mirrors _eitp_safe: cap, reduce to a real tag/sha charset, never lead with `-`
      local _s="${1:-}"
      _s="${_s:0:80}"
      _s="${_s//[![:alnum:]._\/+-]/?}"
      case "$_s" in -*) _s="?${_s#?}" ;; esac
      printf '%s' "$_s"
    }
    lock_tag_s="$(_pin_safe "$lock_tag")"
    lock_commit_s="$(_pin_safe "$lock_commit")"
    if ! command -v git >/dev/null 2>&1; then
      fail "core.lock (format 2) present but git unavailable — cannot verify the whole-tree core pin (fail-closed)"
    elif [ -z "$lock_commit" ] || [ -z "$lock_tag" ]; then
      fail "core.lock (format 2) is missing its tag/commit keys — cannot verify the core pin (fail-closed); re-run \`kickoff pull\`"
    elif ! head_commit="$(git -C "$core_base" rev-parse HEAD 2>/dev/null)"; then
      fail "core.lock (format 2) present but $core_base is not a git checkout — cannot verify the whole-tree pin (set KICKOFF_CORE_DIR to your ~/kickoff-core clone, or run \`kickoff pull\`)"
    else
      pin_ok=1
      if [ "$head_commit" != "$lock_commit" ]; then
        pin_ok=0
        fail "core pin MISMATCH — the checkout at $core_base is commit ${head_commit:0:12}… but core.lock pins ${lock_commit_s:0:12}… (tag $lock_tag_s). Run \`kickoff pull $lock_tag_s\` to re-pin, or check out the pinned commit."
      fi
      # `-q --verify` and the refs/tags/ scope are load-bearing, not style — this is the SAME pair
      # the engine-identity predicate already carries (scripts/kickoff, _eitp), and this site is
      # where it was missing. Two distinct defects, both observed:
      #   · a PLAIN `git rev-parse <unknown>^{commit}` ECHOES ITS ARGUMENT on stdout and exits
      #     non-zero, so with `2>/dev/null || true` an ABSENT tag captures the literal
      #     "core-vX^{commit}" — non-empty, so it SAILS PAST the emptiness arm below and lands in
      #     the "tag MOVED" arm: a definite-sounding wrong diagnosis ("a re-tagged release") whose
      #     remediation cannot work, because the tag it says to re-pull does not exist. Fired live
      #     2026-08-12 on a pin written ahead of its release.
      #   · a bare `<value>^{commit}` resolves ANY revision, not a tag — so `tag HEAD`,
      #     `tag <the pinned sha>` and `tag <a branch>` each RESOLVE and tick a clause that then
      #     certifies nothing (HEAD^{commit} == HEAD by definition, a sha resolves to itself), while
      #     telling the operator a tag was checked. Only refs/tags/ makes the clause mean what it says.
      tag_commit="$(git -C "$core_base" rev-parse -q --verify "refs/tags/$lock_tag^{commit}" 2>/dev/null || true)"
      if [ -z "$tag_commit" ]; then
        pin_ok=0
        fail "core.lock pins tag $lock_tag_s but no such TAG resolves in $core_base — only refs/tags/ is consulted, so an absent/never-created tag (or a branch name, HEAD, or a raw commit id in that line) lands here; re-run \`kickoff pull\`"
      elif [ "$tag_commit" != "$lock_commit" ]; then
        pin_ok=0
        fail "core.lock tag $lock_tag_s now resolves to ${tag_commit:0:12}… but the lock pins ${lock_commit_s:0:12}… — the tag MOVED since the pull (a re-tagged release); re-run \`kickoff pull $lock_tag_s\` after reviewing the change."
      fi
      # CLEAN tree — SCOPED to the clone dir only (git -C the clone; a parked worktree lives OUTSIDE
      # it, so it is never conflated in). A dirty tree is a copied-and-patched core → fail.
      if pin_dirt="$(git -C "$core_base" status --porcelain 2>&1)"; then
        if [ -n "$pin_dirt" ]; then
          pin_ok=0
          fail "core checkout $core_base is DIRTY — a hand-edited (copied-and-patched) core; the whole-tree pin requires a clean tree. Restore:  git -C \"$core_base\" reset --hard $lock_tag && git -C \"$core_base\" clean -fdx"
        fi
      else
        pin_ok=0
        fail "cannot verify the core checkout $core_base is clean ($pin_dirt) — fail-closed"
      fi
      [ "$pin_ok" = "1" ] && ok "core.lock verified — whole-tree pin holds (base=$core_base @ $lock_tag ${lock_commit:0:12}…, clean tree). NOTE: unsigned — a drift/copied-and-patched guard, NOT anti-tamper."
    fi
  else
    # ── OLD per-file lock (unchanged migration-window path) ──
    if ! command -v sha256sum >/dev/null 2>&1; then
      # A tamper-check that cannot run is a FAILED tamper-check → fail-closed.
      fail "core.lock present but sha256sum unavailable — cannot verify core integrity (fail-closed)"
    else
      # Parse the manifest ONCE (#14/#19): REJECT any ABSOLUTE or ../-escaping path BEFORE
      # sha256sum -c (such a path would checksum a file OUTSIDE the core tree), and record
      # whether ANY listed file exists under the base (a wrong base #19 vs a real drift).
      lock_escapes=""
      lock_total=0
      lock_present=0
      while IFS= read -r cl_line || [ -n "$cl_line" ]; do
        [ -z "$cl_line" ] && continue
        case "$cl_line" in \#*) continue ;; esac
        # GNU sha256sum line:  <64 hex><space><space|*><path>
        if [[ "$cl_line" =~ ^[0-9a-fA-F]{64}[[:space:]][[:space:]*](.+)$ ]]; then
          cl_path="${BASH_REMATCH[1]}"
        else
          cl_path="$cl_line"   # malformed — --strict will fail it; still escape-check it
        fi
        lock_total=$((lock_total + 1))
        case "$cl_path" in
          /*|..|../*|*/../*|*/..) lock_escapes="${lock_escapes:+$lock_escapes; }$cl_path" ;;
        esac
        [ -e "$core_base/$cl_path" ] && lock_present=1
      done < "$CORE_LOCK"

      if [ -n "$lock_escapes" ]; then
        fail "core.lock lists path(s) that ESCAPE the core tree (absolute or ../): $lock_escapes — refusing to sha256sum outside the base ($core_base)"
      elif [ "$lock_total" -eq 0 ]; then
        fail "core.lock present but lists no core files — cannot verify integrity (fail-closed)"
      elif [ "$lock_present" -eq 0 ]; then
        # (#19) NONE of the pinned files exist under the base → the base is WRONG, a misconfig,
        # NOT a hand-edit. Point at the real fix instead of a tamper message.
        fail "core.lock present but NONE of its pinned files exist under $core_base — KICKOFF_CORE_DIR does not contain the pinned core (set KICKOFF_CORE_DIR to your ~/kickoff-core clone, or run \`kickoff pull\` to (re)create it)"
      else
        # --strict: a malformed manifest LINE also fails (without it, sha256sum warns but
        # exits 0 if any valid line matched, silently leaving a corrupted line unverified).
        check_out="$( { cd "$core_base" && sha256sum -c --strict "$CORE_LOCK"; } 2>&1 )"
        check_rc=$?
        if [ "$check_rc" -eq 0 ]; then
          ok "core.lock verified — all recorded core files match (base=$core_base)"
        else
          bad="$(printf '%s\n' "$check_out" | grep -v ': OK$' | tr '\n' ';' || true)"
          fail "core.lock checksum MISMATCH — a core file was hand-edited (copied-and-patched); base=$core_base; offending: ${bad:-<see sha256sum>}"
        fi
      fi
    fi
  fi
else
  ok "no core.lock (R3 core-integrity artifact absent) — core-integrity check skipped"
fi

# ── 7. load headroom (SOFT — warn only, never fail) ──────────────────────────
# Advisory: fanning out on a saturated box is the real ceiling, but it is not a
# reason to refuse to start. warn() only.
if [ "$PREFLIGHT_SCOPE" = full ]; then
load1=""
if [ -r /proc/loadavg ]; then
  read -r load1 _ < /proc/loadavg || load1=""
fi
ncpu="$(nproc 2>/dev/null || echo 1)"
if [ -n "$load1" ] && awk -v l="$load1" -v n="$ncpu" 'BEGIN{ exit !((l + 0) > (n + 0)) }'; then
  warn "load headroom: 1-min load $load1 > nproc $ncpu — box is saturated (soft: keep fan-out low)"
else
  ok "load headroom ok (1-min load ${load1:-n/a} <= nproc $ncpu)"
fi
fi

# ── 8. adopt-manifest seam integrity (conditional — ADOPTER only; Fix 9) ──────
# Extends the core.lock guarantee (#6) to the half of the engine that lives INSIDE the repo:
# the manifest-listed SEAM files (generated shims, §1.4). Gated on the SAME adopter predicate
# #1b uses — core.lock present OR the running core is OUTSIDE the repo — NOT the literal
# ".kickoff/ exists" (which would self-DoS kickoff-itself + a fresh greenfield clone). Fix 9
# fail-closed ABSENCE: once this IS an adopter, a MISSING adopt-manifest.json is a FAIL —
# deleting it would silently disable seam verification AND remove eject's spine (a fail-open
# hole); recover with `kickoff adopt`.
# CAVEAT (kept honest): the manifest is UNSIGNED — #8 catches accidental DRIFT / a stale seam,
# NOT a malicious edit that rewrites both a seam and its recorded hash. Right scope for the
# solo-builder trust model. (core_inside_repo + CORE_LOCK were resolved in #1b/#top.)
MANIFEST="$KICKOFF_DIR/adopt-manifest.json"
if [ -f "$CORE_LOCK" ] || [ "$core_inside_repo" -eq 0 ]; then
  if [ ! -f "$MANIFEST" ]; then
    fail "adopt-manifest.json MISSING ($MANIFEST) but this is an ADOPTER (core.lock present, or the core runs outside the repo) — seam integrity cannot be verified and eject has no spine. ALREADY adopted/wired but manifest-less (a legacy adopter pulling this core): run \`kickoff adopt --reconcile\` — it GENERATES the manifest from provably-kickoff artifacts and re-wires NOTHING. Never actually wired: \`kickoff adopt\`. If instead this is a kickoff source/greenfield checkout that accidentally pulled: \`rm .kickoff/core.lock\` and upgrade via \`git pull\`"
  elif ! command -v jq >/dev/null 2>&1; then
    fail "adopt-manifest.json present but jq unavailable — cannot verify seam integrity (fail-closed, like #5/#6)"
  elif ! command -v sha256sum >/dev/null 2>&1; then
    fail "adopt-manifest.json present but sha256sum unavailable — cannot verify seam integrity (fail-closed, like #6)"
  else
    # Whole-file-hash ONLY class:seam entries with action=created — i.e. byte-stable generated
    # files (the .kickoff/bin shims). A block-appended/json-merged/modified seam lives in an
    # OPERATOR-OWNED file (e.g. a CLAUDE.md @import block), so a whole-file hash would false-fail
    # on the operator's own edits and fail-close the worker; those need BLOCK-level verification,
    # which the mesh/eject slice MUST add before it records any such seam. hook-installed has no
    # hash; seeded-instance is adopter-owned. The `class=="seam"` filter also DELIBERATELY excludes
    # the `live-config` class (§B: a kickoff-created file the live system legitimately mutates, e.g.
    # an accepted permission prompt rewriting .claude/settings.json) — whole-file-hashing it would
    # false-fail on that legitimate mutation, so it is intentionally NOT hashed (no logic change). jq
    # PARSE failure = fail-closed.
    seam_tsv="$(jq -r '.entries[]? | select(.class=="seam") | select(.action=="created") | select(.sha256_at_write != null) | [.path, .sha256_at_write] | @tsv' "$MANIFEST" 2>/dev/null)"
    jq_rc=$?
    if [ "$jq_rc" -ne 0 ]; then
      fail "adopt-manifest.json present but jq could not parse it (malformed JSON?) — cannot verify seam integrity (fail-closed)"
    else
      seam_fail=0; seam_ok=0
      while IFS=$'\t' read -r s_path s_hash; do
        [ -n "$s_path" ] || continue
        # reject an absolute / ../-escaping seam path BEFORE touching the FS (mirrors #6's guard)
        case "$s_path" in
          /*|..|../*|*/../*|*/..) fail "adopt-manifest lists a seam path that ESCAPES the repo: $s_path — refusing to hash outside $REPO_DIR"; seam_fail=$((seam_fail + 1)); continue ;;
        esac
        abs="$REPO_DIR/$s_path"
        if [ ! -f "$abs" ]; then
          fail "adopt-manifest seam MISSING on disk: $s_path — recorded but absent; regenerate via \`kickoff pull\` or \`kickoff adopt\`"
          seam_fail=$((seam_fail + 1)); continue
        fi
        got="$(sha256sum "$abs" | awk '{print $1}')"
        if [ "$got" = "$s_hash" ]; then
          seam_ok=$((seam_ok + 1))
        else
          fail "adopt-manifest seam DRIFT: $s_path no longer matches the pinned tag (recorded ${s_hash:0:12}… now ${got:0:12}…) — a seam is engine-generated + regenerated on pull, so this is stale/hand-edited drift; restore via \`kickoff pull --force-regenerate\` (plain \`kickoff pull\` REFUSES a hand-edited seam) or re-run \`kickoff adopt\`. NOTE: this is a DRIFT check, NOT anti-tamper (the manifest is UNSIGNED)."
          seam_fail=$((seam_fail + 1))
        fi
      done <<< "$seam_tsv"
      if [ "$seam_fail" -eq 0 ]; then
        ok "adopt-manifest seam integrity verified — $seam_ok seam file(s) match the pinned tag (drift check; the manifest is UNSIGNED, so this is NOT anti-tamper)"
      fi
    fi

    # ── §5 THE PLUGIN — additionally hash the user-global plugin CACHE against the pinned tag (Slice 5) ──
    # #6 pins the CLONE, but the INTERACTIVE session runs the plugin from the user-global cache
    # (~/.claude/plugins/cache/…), which the clone hash is blind to. So when this adopter has a plugin
    # MACHINE ENTRY, byte-verify each pinned plugin's CACHE snapshot against <core>/plugin/. GATED on
    # machine-entries present (a jq count — python3-free), so a headless-only / no-plugin adopter never
    # runs it, and — via the #8 adopter predicate above — kickoff-itself never even reaches this block
    # (0 work, fully inert: the plugin-cache-verify tool also invokes NO `claude`). Fail-CLOSED:
    # missing/mismatch/unverifiable → FAIL (same posture as the seam + #6 checks). Same honest caveat:
    # a DRIFT check, NOT anti-tamper (the cache + core are unsigned). Only reached when jq + $MANIFEST
    # are present (the outer branch already fail-closed otherwise).
    _pcv_count="$(jq -r '(.machine_entries // []) | length' "$MANIFEST" 2>/dev/null || echo 0)"
    case "$_pcv_count" in ''|*[!0-9]*) _pcv_count=0 ;; esac
    if [ "$_pcv_count" -gt 0 ]; then
      # Resolve the pinned core base independently of #6 (which only sets core_base when core.lock
      # exists): KICKOFF_CORE_DIR when set, else the running core. The plugin lives at <base>/plugin/.
      if [ -n "${KICKOFF_CORE_DIR:-}" ]; then
        _pcv_core_base="$(_canon "$KICKOFF_CORE_DIR")"
      else
        _pcv_core_base="$RUNNING_CORE_DIR"
      fi
      _pcv_tool="$RUNNING_CORE_DIR/scripts/adopt-manifest.py"
      _pcv_cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
      if ! command -v python3 >/dev/null 2>&1; then
        fail "plugin machine entries present but python3 unavailable — cannot verify the plugin cache (fail-closed, like #5/#6/seam)"
      elif [ ! -f "$_pcv_tool" ]; then
        fail "plugin machine entries present but the cache-verify tool is missing ($_pcv_tool) — cannot verify the plugin cache (fail-closed)"
      else
        _pcv_out=""; _pcv_rc=0
        _pcv_out="$(python3 "$_pcv_tool" plugin-cache-verify --repo "$REPO_DIR" --core-dir "$_pcv_core_base" --config-dir "$_pcv_cfg" 2>&1)" || _pcv_rc=$?
        if [ "$_pcv_rc" -eq 0 ]; then
          ok "plugin cache integrity verified — each pinned plugin's user-global cache snapshot matches <core>/plugin/ (drift check; UNSIGNED, so NOT anti-tamper)"
        else
          # ── Phase-2 #8 resolution — the SIBLING-AWARE demotion (design fork, RESOLVED) ──
          # The vendor CLI holds ONE installed interactive plugin per box, so after adopter A pulls
          # a different tag, adopter B's cache-verify fails even though B is CORRECT everywhere it
          # matters (the headless worker execs source via --plugin-dir and never reads the cache).
          # Demote EXACTLY that mismatch to WARN — and ONLY on positive proof: EVERY machine plugin
          # entry's INSTALLED version (installed_plugins.json, the row at the RECORDED scope ONLY —
          # F4: no any-scope fallback; a wrong-scope row must not vouch for this adopter's resync
          # path) must (a) DIFFER from this adopter's pinned version (same-version content drift
          # stays FAIL — that is real corruption, not a sibling), (b) EQUAL the pinned plugin
          # version of ANOTHER registered adopter (read from the registry rows' version_dir
          # plugin.json — provable, not guessed), AND (c) actually EXIST in the cache — F4: the
          # installed-version POINTER alone is not a plugin; a WIPED cache dir means an interactive
          # session has NOTHING to load, which is a real missing-cache failure, not the launchable
          # sibling shape → keep the FAIL. Any unreadable input / missing registry / unproven
          # entry → the original FAIL (fail-closed).
          _pcv_reg="${KICKOFF_ADOPTERS_REGISTRY:-$HOME/.kickoff/adopters.json}"
          _pcv_sib=""
          _pcv_sib="$(python3 - "$MANIFEST" "$_pcv_cfg/plugins/installed_plugins.json" "$_pcv_reg" "$REPO_DIR" "$_pcv_core_base" "$_pcv_cfg" 2>/dev/null <<'PYEOF'
import json, os, sys
man, ipath, rpath, repo, corebase, cfg = sys.argv[1:7]
def load(p):
    with open(p) as f:
        return json.load(f)
try:
    machine = [e for e in load(man).get("machine_entries", []) if e.get("kind") == "plugin"]
    pinned = str(load(os.path.join(corebase, "plugin", ".claude-plugin", "plugin.json")).get("version") or "")
    ip = load(ipath).get("plugins", {})
    reg = load(rpath).get("adopters", [])
except Exception:
    sys.exit(1)
if not machine or not pinned or not isinstance(reg, list):
    sys.exit(1)
repo_real = os.path.realpath(repo)
proof = None
for e in machine:
    mkt = str(e.get("marketplace") or "")
    plg = str(e.get("plugin") or "")
    spec = "%s@%s" % (plg, mkt)
    # F4: the RECORDED scope's row ONLY — never fall back to an any-scope row (a user-scope
    # install from some other source must not vouch for this project-scope adopter).
    rows = [r for r in ip.get(spec, []) if r.get("scope") == (e.get("scope") or "project")]
    inst = str(rows[0].get("version") or "") if rows else ""
    if not inst or inst == pinned:
        sys.exit(1)                     # unreadable, or same-version drift → NOT the sibling shape
    # F4: the pointer must be BACKED by a real cache dir — a wiped cache is a real failure
    # (nothing for an interactive session to load), not the launchable sibling shape.
    if not (mkt and plg and os.path.isdir(os.path.join(cfg, "plugins", "cache", mkt, plg, inst))):
        sys.exit(1)
    matched = None
    for a in reg:
        arepo = os.path.realpath(a.get("repo", "") or "")
        if not arepo or arepo == repo_real:
            continue
        try:
            over = str(load(os.path.join(a.get("version_dir") or "", "plugin", ".claude-plugin",
                                         "plugin.json")).get("version") or "")
        except Exception:
            continue
        if over == inst:
            matched = (a.get("repo"), a.get("tag") or "?", inst)
            break
    if matched is None:
        sys.exit(1)                     # ANY unproven entry keeps the whole check FAIL
    proof = proof or matched
print("%s\t%s\t%s" % proof)
sys.exit(0)
PYEOF
)" || _pcv_sib=""
          if [ -n "$_pcv_sib" ]; then
            _pcv_sib_repo="$(printf '%s' "$_pcv_sib" | cut -f1)"
            _pcv_sib_tag="$(printf '%s' "$_pcv_sib" | cut -f2)"
            _pcv_sib_ver="$(printf '%s' "$_pcv_sib" | cut -f3)"
            warn "plugin cache serves a SIBLING adopter's tag — the interactive plugin is at $_pcv_sib_ver, pinned by $_pcv_sib_repo ($_pcv_sib_tag); this adopter's pinned version is stale/missing in the cache. The HEADLESS worker is UNAFFECTED (it execs source via --plugin-dir, never the cache); only an interactive session here would load the sibling's plugin. Converge the two adopters to one core tag (\`kickoff pull\` in the older one) to clear this."
          else
            fail "plugin cache DRIFT/MISSING — the interactive plugin cache does not match the pinned tag; $(printf '%s' "$_pcv_out" | grep -E '^\s*\[ FAIL \]' | head -3 | tr '\n' ';') — re-sync via \`kickoff pull\` (mechanism A/B). NOTE: a DRIFT check, NOT anti-tamper."
          fi
        fi
      fi
    fi
  fi
else
  ok "not an adopter (no core.lock; core runs from inside the repo) — adopt-manifest seam check skipped"
fi

# ── 9. adopt-completeness (SOFT — a LOUD warn, NEVER a fail) ─────────────────
# The a real adopter shape: mechanical seams present, the /adopt session never ran, gates WHOLLY
# unwired — and commits land unscanned while everything still reports green. Distinguish it from
# a LEGIT fresh adopt (a valid, startup-safe state — nothing is flowing through the repo yet) by
# the ACTIVITY signals: commits STRICTLY newer than the adopt manifest (second-resolution %ct
# compare, so a same-second adopt-after-baseline never false-fires) or board activity entries.
# (A live supervisor is NOT probed here — preflight runs BEFORE the supervisor takes its lock;
# a genuinely competing one is #4's hard business.) warn() ONLY, by design: this runs at EVERY
# supervisor start, and a fresh mechanical adopt MUST boot — the flag is loud, never a refusal.
if [ "$PREFLIGHT_SCOPE" = full ] && [ -f "$MANIFEST" ]; then
  _ai_gate="$KICKOFF_DIR/lefthook-kickoff.yml"
  _ai_root="$REPO_DIR/lefthook.yml"
  _ai_unwired=0
  if [ ! -f "$_ai_gate" ] && ! { [ -f "$_ai_root" ] && grep -qE 'lefthook-kickoff\.yml|kickoff' "$_ai_root" 2>/dev/null; }; then
    _ai_unwired=1
  fi
  if [ "$_ai_unwired" = 1 ]; then
    _ai_why=""
    if command -v git >/dev/null 2>&1 && git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
      _ai_mts="$(stat -c %Y "$MANIFEST" 2>/dev/null || stat -f %m "$MANIFEST" 2>/dev/null || printf '')"
      if [ -n "$_ai_mts" ]; then
        _ai_n="$(git -C "$REPO_DIR" log --format=%ct 2>/dev/null | awk -v t="$_ai_mts" '$1 > t' | wc -l | tr -d ' ')"
        case "$_ai_n" in ''|*[!0-9]*) _ai_n=0 ;; esac
        [ "$_ai_n" -gt 0 ] && _ai_why="$_ai_n commit(s) landed after adopt"
      fi
    fi
    _ai_ms="${MC_STATE_FILE:-$KICKOFF_DIR/state/mission-control/mission-state.json}"
    case "$_ai_ms" in /*) : ;; *) _ai_ms="$REPO_DIR/$_ai_ms" ;; esac
    _ai_actn="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("activity") or []))' "$_ai_ms" 2>/dev/null || printf 0)"
    case "$_ai_actn" in ''|*[!0-9]*) _ai_actn=0 ;; esac
    [ "$_ai_actn" -gt 0 ] && _ai_why="${_ai_why:+$_ai_why; }$_ai_actn board activity entries"
    _ai_tr=""
    [ -f "$REPO_DIR/TRACKER.md" ] || _ai_tr=" — and TRACKER.md is missing (the /adopt session never ran)"
    if [ -n "$_ai_why" ]; then
      warn "ADOPT INCOMPLETE — this repo is ACTIVE ($_ai_why) but the kickoff quality gates are WHOLLY UNWIRED (no .kickoff/lefthook-kickoff.yml, no root lefthook extends)$_ai_tr. Commits are landing with NO secret/structure scan. Fix: re-run \`kickoff adopt\` (wires the generic gates), then \`/adopt\` in a Claude Code session (stack gates + TRACKER). Advisory: startup is NOT blocked. → run \`kickoff doctor\` to back-fill."
    else
      ok "gates unwired but the repo shows no activity yet — a legit fresh adopt (finish with \`kickoff adopt\` + \`/adopt\`); not escalated"
    fi
  else
    ok "adopt-completeness: the kickoff gate wiring is present — no incomplete-adopt escalation"
  fi

  # ── 9b. BRAINS-completeness — an INDEPENDENT predicate (SOFT — a LOUD warn, NEVER a fail) ───
  # Check #9 above asks ONE question ("are the gates wired?") and `kickoff adopt` now always
  # answers it yes (`_ensure_kickoff_gates`, authored-by-adopt). So the whole escalation is
  # unreachable for every modern adoption — measured 2026-08-06: all six live adopters carry the
  # gate file, so not one of them could ever trip it, no matter how brainless.
  #
  # The gates and the brains are different questions with different fixes, and the second one is
  # the one that decides whether the org can ACT at all: one live adopter ran 35 memory-writing sessions
  # with no .claude/agents/ and a 76-byte CLAUDE.md. It is asked here, OUTSIDE the `_ai_unwired`
  # branch, so a gates-wired repo can still report a brains gap.
  #
  # ONE implementation of the predicate, shared with `kickoff adopt` and `kickoff verify` —
  # crew-probe.py, resolved from the core tree that is actually RUNNING (a pull adopter's cwd is
  # their own repo and has no scripts/). warn() only, by design: this runs at EVERY supervisor
  # start, and a brainless org MUST boot — the worker it boots is exactly what closes the gap.
  _bp_probe="$RUNNING_CORE_DIR/scripts/crew-probe.py"
  if [ -f "$_bp_probe" ]; then
    _bp_rc=0
    _bp_out="$(python3 "$_bp_probe" brains-verdict --repo "$REPO_DIR" 2>/dev/null)" || _bp_rc=$?
    if [ "$_bp_rc" = 1 ] && [ -n "$_bp_out" ]; then
      _bp_mark=""
      [ -f "$KICKOFF_DIR/adopt-brains-pending" ] && _bp_mark=" (marked: .kickoff/adopt-brains-pending)"
      warn "BRAINS INCOMPLETE — the plumbing is wired but this org has no MIND$_bp_mark. $_bp_out. It can be steered and cannot ACT: no specialist owns any domain, and the charter says nothing about this repo. The worker's re-ground authors the crew + charter at boot and announces the draft for your approval; or run \`/adopt\` in a Claude Code session here. Advisory: startup is NOT blocked."
    elif [ "$_bp_rc" = 0 ] && [ -n "$_bp_out" ]; then
      ok "brains-completeness: $_bp_out"
    else
      warn "brains-completeness: could not read the crew/charter verdict (crew-probe.py unrunnable) — SKIPPED, not passed"
    fi
  else
    warn "brains-completeness: crew-probe.py not found in the running core ($RUNNING_CORE_DIR/scripts) — SKIPPED, not passed"
  fi
fi

# ── summary + fail-closed exit ───────────────────────────────────────────────
if [ "$fails" -gt 0 ]; then
  printf '[preflight] SUMMARY: %d hard failure(s), %d warning(s) — FAIL-CLOSED: refusing to proceed.\n' "$fails" "$warns" >&2
  exit 1
fi
printf '[preflight] SUMMARY: all hard checks passed (%d warning(s)). OK to proceed.\n' "$warns"
exit 0
