#!/usr/bin/env bash
# check-bot-patch-drift.sh — guard the vendored telegram-bot patches against silent wipes.
#
# Any `npm install -g @grinev/opencode-telegram-bot` (update/reinstall) REPLACES dist/
# and silently destroys every oxalpha patch (v5/v6/v6.1/v6.2). This compares the
# installed dist against the canonical snapshot in patches/opencode-telegram-bot-v6/
# and fails loudly on drift. --restore re-copies the snapshot over dist (then bounce
# the affected bots).
#
# PRIVATE OVERLAY: a git-ignored per-org layer at patches/private/opencode-telegram-bot-v6/
# wins over the public snapshot per-file — when patches/private/<relpath> exists it is the
# comparison source (and the restore source) for that file, so local-only patches (e.g.
# per-org-only local features) survive an npm reinstall WITHOUT living in the repo.
#
# Usage:
#   bash scripts/check-bot-patch-drift.sh             # check (exit 0 clean / 2 drift)
#   bash scripts/check-bot-patch-drift.sh --restore   # restore snapshot/overlay → dist
#   BOT_DIST_DIR=/tmp/sometree bash ...               # test against an alternate tree
# Set -e is deliberately NOT used: we aggregate failures and report once.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT="$SCRIPT_DIR/../patches/opencode-telegram-bot-v6"
OVERLAY="$SCRIPT_DIR/../patches/private/opencode-telegram-bot-v6"
DIST="${BOT_DIST_DIR:-$HOME/.local/lib/node_modules/@grinev/opencode-telegram-bot/dist}"
EXPECTED_VERSION="0.24.0"

PATCHED_FILES=(
  "config.js"
  "app/stores/settings-store.js"
  "app/stores/user-scope.js"
  "bot/middleware/auth.js"
  "bot/services/event-subscription-service.js"
  "bot/services/attach-presentation.js"
)

mode="check"; [[ "${1:-}" == "--restore" ]] && mode="restore"

fail=0
[[ -d "$DIST" ]] || { echo "✗ bot dist NOT FOUND at $DIST (installed?)"; exit 2; }
inst_ver="$(node -p "require('$DIST/../package.json').version" 2>/dev/null || echo unknown)"
if [[ "$inst_ver" != "$EXPECTED_VERSION" ]]; then
  echo "✗ VERSION DRIFT: installed $inst_ver != pinned $EXPECTED_VERSION — patches were NOT written for this version"
  fail=1
fi

overlay_count=0
for f in "${PATCHED_FILES[@]}"; do
  # The private overlay wins when present: it is the canonical source for this file.
  src="$SNAPSHOT/$f"; src_name="canonical snapshot"
  if [[ -f "$OVERLAY/$f" ]]; then
    src="$OVERLAY/$f"; src_name="private overlay"; ((overlay_count++))
  fi
  if [[ ! -f "$src" ]]; then
    echo "✗ SNAPSHOT HOLE: $f missing from $src_name (canonical-source rot)"; fail=1; continue
  fi
  if [[ ! -f "$DIST/$f" ]]; then
    echo "✗ MISSING: $f absent from installed dist — patch lost"; fail=1
    [[ $mode == restore ]] && cp "$src" "$DIST/$f" && echo "  ↳ restored from $src_name"
    continue
  fi
  if ! cmp -s "$src" "$DIST/$f"; then
    echo "✗ DRIFT: $f differs from $src_name — patch overwritten or edited out-of-band"
    fail=1
    [[ $mode == restore ]] && cp "$src" "$DIST/$f" && echo "  ↳ restored from $src_name"
  fi
done

if [[ $fail -eq 0 ]]; then
  via=""; [[ $overlay_count -gt 0 ]] && via=", $overlay_count via private overlay"
  echo "✓ bot-patch integrity OK ($inst_ver, ${#PATCHED_FILES[@]} files match${via})"
else
  echo "✗ bot-patch INTEGRITY FAILED (restore mode: restored where possible). After any restore: bounce affected bots (kill pid, relaunch opencode-telegram start with captured env)."
fi
exit $(( fail > 0 ? 2 : 0 ))
