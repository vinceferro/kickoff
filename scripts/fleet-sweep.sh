#!/usr/bin/env bash
# fleet-sweep.sh — read-only TUI health sweep of every kickoff org on this box.
#
#   bash scripts/fleet-sweep.sh [expected-tag] [expected-commit]
#
# Per org (every dir with .kickoff/core.lock under ~/Projects and ~):
#   PIN      core.lock tag + commit == expected (default core-v1.0.0-alpha @ 7e25651e…)
#   ENGINE   KICKOFF_CORE_DIR resolves, HEAD == pinned commit, tree clean
#   SEAMS    .kickoff/bin/* executable; scan-secrets --help rc; mc show rc + first line
#            (mc legitimately fails on a public-line core — recorded, not failed)
#   MEMORY   MEMORY_INDEX non-trivial; MEMORY_DB present; recall probe through the org's
#            OWN pinned core (run.sh retrieve) capturing the REAL/STUB vector-arm line
#   CREW     charter count; enabledPlugins; opencode.json parse (+ reason on failure)
#   GIT      dirty-file count + origin URL
#   MAIL     ~/.claude/agent-mail/<org> mailbox exists
#
# NO channel/bot checks by design (operator: TUI-only sweeps).
# Hygiene: children run with THIS session's KICKOFF_CORE_DIR/MEMORY_*/MC_*/TELEGRAM_* UNSET
# and REPO_DIR pinned to the org ([[your-session-env-leaks-into-another-repos-checks]]).
# rc is captured with PIPESTATUS — a pipe to head takes HEAD's status, not the command's
# ([[test-pipeline-exit-status-masks-failure]]).
set -u
EXPECTED_TAG="${1:-core-v1.0.0-alpha}"
EXPECTED_COMMIT="${2:-7e25651ec52ee52cccc1517bfcfbd06a002762b5}"

SCRUB=(-u KICKOFF_CORE_DIR -u MEMORY_DIR -u MEMORY_DB -u MEMORY_INDEX -u MEMORY_HOOK_LOG
       -u MC_STATE_FILE -u MC_TRACKER_FILE -u TELEGRAM_STATE_DIR -u TELEGRAM_BOT_TOKEN
       -u KICKOFF_CORE_REMOTE -u OPENCODE_BRIDGE_PORT)

instance_val() { # instance_val <org> <VAR> — resolve org's instance.env value incl. "${VAR:-default}"
  local org="$1" var="$2"
  python3 - "$org/.kickoff/instance.env" "$var" <<'PYEOF'
import re, sys
path, var = sys.argv[1], sys.argv[2]
val = None
try:
    for line in open(path):
        m = re.match(r'^export (\w+)=(.*)$', line.strip())
        if m and m.group(1) == var:
            val = m.group(2).strip()
except FileNotFoundError:
    sys.exit(1)
if val is None:
    sys.exit(1)
inner = (re.match(r'^"\$\{' + re.escape(var) + r':-(.*)\}"$', val)
         or re.match(r'^\$\{' + re.escape(var) + r':-(.*)\}$', val)
         or re.match(r'^"(.*)"$', val))
print(inner.group(1) if inner else val)
PYEOF
}

expand_env() { # expand_env <org> <value> — resolve ${REPO_DIR:-$PWD} anchors + $HOME
  local org="$1" v="$2"
  v="${v//\$\{REPO_DIR:-\$PWD\}/$org}"
  v="${v//\$\{REPO_DIR\}/$org}"
  v="${v//\$HOME/$HOME}"
  printf '%s' "$v"
}

orgs="$(find "$HOME/Projects" "$HOME" -maxdepth 3 -name core.lock -path '*/.kickoff/*' 2>/dev/null \
        | sed 's|/.kickoff/core.lock$||' | sort -u)"
printf 'FLEET SWEEP %s — expected %s @ %s\n' "$(date -u +%FT%TZ)" "$EXPECTED_TAG" "${EXPECTED_COMMIT:0:8}"

for org in $orgs; do
  name="$(basename "$org")"
  [ "$name" = "claude-kickoff" ] && { printf '\n== %s (SELF/dev — skipped, source checkout)\n' "$name"; continue; }
  echo; echo "== $name ($org) =="
  # --- PIN
  lock="$org/.kickoff/core.lock"
  tag="$(grep -oE 'core-v[0-9A-Za-z._-]+' "$lock" | head -1)"
  commit="$(grep -oE '[0-9a-f]{40}' "$lock" | head -1)"
  if [ "$tag" = "$EXPECTED_TAG" ] && [ "$commit" = "$EXPECTED_COMMIT" ]; then
    echo "  PIN      OK  $tag @ ${commit:0:8}"
  else
    echo "  PIN      DRIFT  got: ${tag:-none} @ ${commit:0:8}"
  fi
  # --- ENGINE
  core_dir="$(expand_env "$org" "$(instance_val "$org" KICKOFF_CORE_DIR || true)")"
  if [ -n "$core_dir" ] && [ -d "$core_dir" ]; then
    ehead="$(git -C "$core_dir" rev-parse HEAD 2>/dev/null)"
    edirty="$(git -C "$core_dir" status --porcelain 2>/dev/null | wc -l)"
    if [ "$ehead" = "$commit" ] && [ "$edirty" = "0" ]; then
      echo "  ENGINE   OK  $core_dir (HEAD==pin, clean)"
    else
      echo "  ENGINE   ??  $core_dir (HEAD ${ehead:0:8} vs pin ${commit:0:8}, dirty=$edirty)"
    fi
  else
    echo "  ENGINE   MISSING  KICKOFF_CORE_DIR unresolved: '$core_dir'"
  fi
  # --- SEAMS
  for shim in "$org"/.kickoff/bin/*; do
    [ -e "$shim" ] || continue
    [ -x "$shim" ] || echo "  SEAM     NOT-EXEC: ${shim##*/}"
  done
  ss_rc="$(cd "$org" && env "${SCRUB[@]}" REPO_DIR="$org" timeout 20 bash .kickoff/bin/scan-secrets --help >/dev/null 2>&1; echo $?)"
  echo "  SEAM     scan-secrets --help rc=$ss_rc"
  mc_out="$(cd "$org" && env "${SCRUB[@]}" REPO_DIR="$org" timeout 20 bash .kickoff/bin/mc show 2>&1)"
  mc_rc=$?
  echo "  SEAM     mc show rc=${mc_rc} :: $(printf '%s' "$mc_out" | head -1 | cut -c1-110)"
  # --- MEMORY
  midx="$(expand_env "$org" "$(instance_val "$org" MEMORY_INDEX || true)")"
  case "$midx" in /*) ;; *) midx="$org/$midx" ;; esac
  if [ -s "$midx" ]; then
    echo "  MEMORY   index OK ($(wc -l < "$midx") lines)"
  else
    echo "  MEMORY   INDEX MISSING/EMPTY: $midx"
  fi
  mdb="$(expand_env "$org" "$(instance_val "$org" MEMORY_DB || true)")"
  if [ -s "$mdb" ]; then
    echo "  MEMORY   db OK ($(du -h "$mdb" | cut -f1))"
  else
    echo "  MEMORY   DB MISSING/EMPTY: $mdb"
  fi
  if [ -n "$core_dir" ] && [ -d "$core_dir/memory-retrieval" ] && [ -s "$mdb" ]; then
    probe="$( cd "$core_dir/memory-retrieval" && env "${SCRUB[@]}" \
              MEMORY_DB="$mdb" \
              MEMORY_DIR="$(expand_env "$org" "$(instance_val "$org" MEMORY_DIR || echo "$org/.kickoff/memory")")" \
              timeout 90 ./run.sh retrieve 'read the operator early' 2>&1 | grep -m1 -E "Hybrid:|no hits|error|Error" )"
    echo "  MEMORY   recall: ${probe:-<no output>}"
  else
    echo "  MEMORY   recall: SKIPPED (no pinned core or no db)"
  fi
  # --- CREW
  charters="$(find "$org/.claude/agents" -name '*.md' 2>/dev/null | wc -l)"
  settings="$org/.claude/settings.json"
  plugins="?"
  if [ -f "$settings" ]; then
    plugins="$(python3 -c "import json;print(len(json.load(open('$settings')).get('enabledPlugins',{})))" 2>/dev/null || echo '?')"
  fi
  oparse="no opencode.json"; oerr=""
  if [ -f "$org/opencode.json" ]; then
    oerr="$(python3 -c "import json;json.load(open('$org/opencode.json'))" 2>&1 >/dev/null)"
    if [ -z "$oerr" ]; then
      oparse="yes"
      oagent="$(python3 -c "import json;print(json.load(open('$org/opencode.json')).get('default_agent','-'))" 2>/dev/null || echo '-')"
      oparse="yes default_agent=$oagent"
    else
      oparse="NO: $(printf '%s' "$oerr" | tail -1 | cut -c1-80)"
    fi
  fi
  echo "  CREW     charters=$charters enabledPlugins=$plugins opencode.json $oparse"
  # --- GIT + MAIL
  dirty="$(git -C "$org" status --porcelain 2>/dev/null | wc -l)"
  origin="$(git -C "$org" remote get-url origin 2>/dev/null || echo 'none')"
  echo "  GIT      dirty=$dirty origin=$origin"
  [ -d "$HOME/.claude/agent-mail/$name" ] && echo "  MAIL     box present" || echo "  MAIL     no box"
done
echo; echo "SWEEP DONE"
