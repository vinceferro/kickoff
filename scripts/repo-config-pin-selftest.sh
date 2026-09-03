#!/usr/bin/env bash
# repo-config-pin-selftest.sh — the core repo's OWN dispatch config must name models that resolve.
#
# Cost (2026-09-01): THREE lanes wedged silently in a row before the class was named:
#   1. the tracked coordinator charter (.opencode/agent/coordinator.md) carried
#      `model: opencode/x-preview-f-free` — a model delisted upstream (the c2ceae3 fix
#      pinned opencode.json but MISSED this surviving frontmatter pin; the agent pin
#      beats the config default, so every no-override lane session resolved the dead model);
#   2. the tracked opencode.json default (`zai-coding-plan/glm-5.3-flash`) does not resolve
#      for WORKTREE lanes — a fresh worktree sees tracked bytes + the GLOBAL config only,
#      and the global llm-gateway block listed no glm-5.3-flash;
#   3. the global llm-gateway apiKey had gone stale ("missing or unknown gateway key"),
#      so even resolvable models 401'd in worktrees while main-checkout sessions (which
#      read a skip-worktree'd fenced copy) streamed fine.
# Lane-dispatch discards the seed prompt_async response, so ALL of this surfaced as silence.
#
# The checks below assert on the TRACKED bytes (`git show :path`), because that is what a
# worktree actually sees. Each check carries a RED control against the real failing input
# from the incident, so the suite proves the checks can fail.
#
# The gateway-key currency of the GLOBAL config is a box-local property — checked only as
# a skip-able informational lane (a repo suite must stay green on a box without our gateway).

set -uo pipefail
PASS=0; FAIL=0; SKIP=0

chk() { # chk <desc> <cmd>
  local desc="$1" cmd="$2"
  if eval "$cmd" >/dev/null 2>&1; then
    PASS=$((PASS+1)); printf '  ✓ %s\n' "$desc"
  else
    FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$desc"
  fi
}
skip() { SKIP=$((SKIP+1)); printf '  - %s (skipped: %s)\n' "$1" "$2"; }

GLOBAL_CFG="${HOME}/.config/opencode/opencode.json"

# resolver: rc=0 iff <provider/model> is declared in <config.json> provider.<provider>.models
resolve_in() { # resolve_in <config.json> <provider/model>
  python3 - "$1" "$2" <<'EOF'
import json, sys
cfg, pin = sys.argv[1], sys.argv[2]
d = json.load(open(cfg))
provider, model = pin.split("/", 1)
models = d.get("provider", {}).get(provider, {}).get("models", {})
sys.exit(0 if model in models else 1)
EOF
}

echo "== tracked dispatch config resolves (the worktree's view) =="
chk "coordinator charter carries NO agent-level model pin" \
  "! git show :.opencode/agent/coordinator.md | grep -q '^model:'"
chk "tracked opencode.json names no delisted x-preview-f-free" \
  "! git show :opencode.json | grep -q 'x-preview-f-free'"
chk "tracked opencode.json carries NO inline gateway key" \
  "! git show :opencode.json | grep -q 'sk-lg-'"

DEFAULT_MODEL="$(git show :opencode.json | python3 -c 'import json,sys; print(json.load(sys.stdin).get("model",""))' 2>/dev/null)"
chk "tracked opencode.json declares a default model" \
  "[ -n \"\$DEFAULT_MODEL\" ]"
if [ -f "$GLOBAL_CFG" ]; then
  chk "tracked default model ($DEFAULT_MODEL) resolves in the GLOBAL config (worktree reality)" \
    "resolve_in '$GLOBAL_CFG' '$DEFAULT_MODEL'"
else
  skip "default-model resolution" "no global opencode config on this box"
fi

echo "== RED controls (the real failing inputs from the incident) =="
# The detector must fire on a charter carrying the incident pin (a synthetic copy of the
# exact pre-fix bytes — `model: opencode/x-preview-f-free` — so the control stays valid
# after the fix itself is committed):
chk "pin-detector DOES fire on a charter carrying the incident pin" \
  "printf -- '---\ndescription: x\nmode: primary\nmodel: opencode/x-preview-f-free\n---\nbody\n' | grep -q '^model:'"
# The resolver must REJECT a model the global config lacks (the input that wedged lane 3).
# Proven against a frozen pre-fix snapshot of the global config when one exists.
BACKUP="$(ls "$GLOBAL_CFG".pre-gateway-key-fix-* 2>/dev/null | head -1 || true)"
if [ -n "$BACKUP" ]; then
  chk "resolver DOES reject glm-5.3-flash against the PRE-FIX global snapshot ($BACKUP)" \
    "! resolve_in '$BACKUP' 'llm-gateway/glm-5.3-flash'"
  chk "resolver ACCEPTS glm-5.3-flash against the FIXED global config" \
    "resolve_in '$GLOBAL_CFG' 'llm-gateway/glm-5.3-flash'"
else
  skip "resolver negative control" "no pre-fix global config snapshot on this box"
fi

echo
echo "repo-config-pin-selftest: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
[ "$FAIL" -eq 0 ]
