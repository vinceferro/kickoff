#!/usr/bin/env bash
# push-guard.sh — a pre-push allow-list + private-lineage sentinel. Blocks a push that would leak a
# private branch to a public remote (the exact class that put brownfield-devex on origin, 2026-07).
#
# Reads git's pre-push stdin (one line per ref: "<local_ref> <local_sha> <remote_ref> <remote_sha>")
# and REFUSES the whole push (exit 1) if any update is not on the allow-list, or carries the private
# lineage. By construction this kills `git push --all` / `--mirror` (they enumerate every ref, so the
# private ones fail the allow-list) and any `push -u` of a private branch.
#
# Placement matters: it is invoked at the TOP of .git/hooks/pre-push, BEFORE the kickoff hook-runner,
# with its OWN bypass var — never behind LEFTHOOK, whose =0 escape hatch is used for routine skips and
# would otherwise disable this guard too.
#   Bypass (deliberate, rare):  KICKOFF_PUSH_GUARD=0 git push ...
set -u

[ "${KICKOFF_PUSH_GUARD:-1}" = "0" ] && exit 0

# Allow-listed remote refs (extend deliberately). These are the ONLY refs that may reach a public remote.
allowed_ref() {
  case "$1" in
    refs/heads/main) return 0 ;;
    refs/heads/release/core-v*) return 0 ;;
    refs/tags/core-v*) return 0 ;;
    *) return 1 ;;
  esac
}

# The private-lineage sentinel: brownfield-devex's leaked tip. ANY commit that descends from it carries
# the private history and must never be pushed. Skipped when the sentinel object isn't present (a fresh
# clone / an adopter that never had it) — there, the allow-list alone governs.
SENTINEL="6882e27dc89fff0fc9e9a0dae3d3abc0760bb7b2"

ZERO_RE='^0\{40,\}$'
rc=0
seen=0
while read -r local_ref local_sha remote_ref remote_sha; do
  [ -z "${remote_ref:-}" ] && continue
  seen=1
  # A deletion (local_sha all-zeros) is always allowed — it removes, never leaks.
  if printf '%s' "$local_sha" | grep -q "$ZERO_RE"; then continue; fi
  if ! allowed_ref "$remote_ref"; then
    printf '  ✗ push-guard: refusing to push %s — not on the public allow-list (main · release/core-v* · tags core-v*).\n' "$remote_ref" >&2
    printf '    This is the guard that stops a private branch reaching a public remote. Deliberate override: KICKOFF_PUSH_GUARD=0 git push …\n' >&2
    rc=1; continue
  fi
  if git cat-file -e "$SENTINEL" 2>/dev/null && git merge-base --is-ancestor "$SENTINEL" "$local_sha" 2>/dev/null; then
    printf '  ✗ push-guard: refusing to push %s — its commit %.12s descends from the private lineage (%.12s).\n' "$remote_ref" "$local_sha" "$SENTINEL" >&2
    rc=1; continue
  fi
done

exit $rc
