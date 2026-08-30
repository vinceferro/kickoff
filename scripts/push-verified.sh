#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# push-verified.sh — `git push`, then READ THE REMOTE BACK before calling it delivered.
#
#   bash scripts/push-verified.sh [<push-flags>] [<remote> [<refspec>...]]
#
# THE FAILURE THIS EXISTS TO PREVENT (two live incidents, memory: a-checkpoint-
# is-not-done-until-the-remote-moved + verify-the-ref-you-push-from):
#   · 2026-08-27 — a batch was built, reviewed, committed, and written into
#     TRACKER.md as "pushed to origin/brownfield-devex". The push had never
#     run. A `git push` leaves no local-branch reflog entry, so every local
#     witness looks identical whether you pushed or not — the REMOTE is the
#     only authority, and nothing asked it.
#   · 2026-07-26 — the push DID run, from a stale local ref, and rolled the
#     public front door back 14 versions. The payload was checked six ways;
#     the SOURCE REF was assumed.
#
# So this wrapper does the two things both incidents lacked:
#   1. BEFORE pushing, it resolves BOTH ENDS out loud — what the remote holds
#      now, what the source refspec resolves to — and REFUSES a push that
#      would move the remote BACKWARDS (a stale-local-ref force push) unless
#      you set PUSH_VERIFIED_ALLOW_BACKWARDS=1 with your eyes open.
#   2. AFTER pushing, it reads the remote back with `git ls-remote` for every
#      ref pushed and compares the remote's SHA against the SHA that was
#      resolved from the SOURCE REFSPEC (not "HEAD after the fact" — a
#      detached-HEAD or stale-branch push verifies what was PUSHED).
#      Only a matching read-back prints PUSH-VERIFIED.
#
# Honesty rules (the point of the script):
#   · push failed            → exit 1, per-ref landing state reported.
#   · remote SHA ≠ local SHA → exit 1, both SHAs shown. NEVER "verified".
#   · push reported success but the READ-BACK could not reach the remote
#                            → exit 2 "UNVERIFIED" — the push probably landed,
#      but that is a claim, not a verification. Do not write "pushed" in the
#      tracker until a read-back succeeds.
#
# Exit codes: 0 every ref verified on the remote · 1 refused/push-failed/mismatch
#             · 2 push ran, remote unreadable (UNVERIFIED).
#
# Relation to scripts/push-guard.sh: that is a pre-push POLICY guard (allow-list
# + private-lineage sentinel) and stays in place; this is the DELIVERY verifier
# that runs after. They compose, they don't replace each other.
#
# Deliberately NOT supported (the read-back must enumerate exactly what was
# pushed — a flag that pushes unenumerable refs would make the check blind):
#   --all --branches --mirror --tags --follow-tags --dry-run
# Flags that take a SEPARATE value (--repo, --exec, -o, --push-option, bare
# --recurse-submodules): use the =<value> form instead.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

die() { printf '✗ push-verified: %s\n' "$*" >&2; exit 1; }
say() { printf '  %s\n' "$*"; }

FLAGS=()
REMOTE=""
REFSPECS=()
DELETE=0
for a in "$@"; do
  case "$a" in
    --all|--branches|--mirror|--tags|--follow-tags)
      die "'$a' pushes refs this script cannot enumerate, so the read-back would be blind.
    Pass explicit refspecs (<src>:<dst>) — a verification that does not know what to
    read back is exactly the unchecked assumption this script exists to remove." ;;
    --dry-run)
      die "--dry-run cannot verify anything — nothing lands. Run the real push; this
    script exists to make that safe." ;;
    --repo|--exec|-o|--push-option|--recurse-submodules)
      die "flag '$a' takes a separate value, which this parser cannot carry — use the
    '$a=<value>' form." ;;
    -d|--delete) DELETE=1; FLAGS+=("$a") ;;
    -*)          FLAGS+=("$a") ;;
    *) if [ -z "$REMOTE" ]; then REMOTE="$a"; else REFSPECS+=("$a"); fi ;;
  esac
done

[ -n "$REMOTE" ] || REMOTE=""     # may still be derived from upstream below

# ── no refspecs? derive the upstream pair, git's push.default=upstream way ───
if [ "${#REFSPECS[@]}" -eq 0 ]; then
  branch_full="$(git symbolic-ref -q HEAD)" \
    || die "no refspecs given and HEAD is detached — pass an explicit <src>:<dst>.
    The read-back must know exactly what to verify; 'what HEAD is on' is the
    assumption the 2026-07-26 stale-ref incident was built on."
  b="${branch_full#refs/heads/}"
  up_remote="$(git config --get "branch.$b.remote" 2>/dev/null)" || true
  up_merge="$(git config --get "branch.$b.merge" 2>/dev/null)" || true
  if [ -z "$up_remote" ] || [ -z "$up_merge" ]; then
    die "no refspecs given and branch '$b' has no upstream — pass '<remote> <src>:<dst>'."
  fi
  if [ -n "$REMOTE" ] && [ "$REMOTE" != "$up_remote" ]; then
    die "remote '$REMOTE' given, but '$b' tracks '$up_remote' — pushing a different
    remote needs an explicit refspec so the read-back verifies the real target."
  fi
  REMOTE="$up_remote"
  REFSPECS=("${branch_full}:${up_merge}")
fi
[ -n "$REMOTE" ] || die "no remote given (usage: bash $0 [<flags>] <remote> <refspec>...)"

git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository."

# ── resolve every refspec into src-ref / dst-ref pairs BEFORE anything moves ──
# Pairs are collected VERBATIM (a leading + preserved, src empty = delete), so
# git receives exactly the refspec the caller wrote.
PAIRS=()
resolve_refspec() {
  local spec="$1" src="" dst=""
  if [ "$DELETE" = 1 ]; then
    if   git show-ref --verify --quiet "refs/heads/$spec" 2>/dev/null; then dst="refs/heads/$spec"
    elif git show-ref --verify --quiet "refs/tags/$spec"  2>/dev/null; then dst="refs/tags/$spec"
    elif git show-ref --verify --quiet "$spec"            2>/dev/null; then dst="$spec"
    elif [ "${spec#refs/}" != "$spec" ]; then dst="$spec"   # remote-only ref: the read-back decides
    else die "cannot resolve '$spec' to a ref to delete (tried refs/heads/$spec, refs/tags/$spec, $spec)."; fi
    PAIRS+=(":$dst"); return 0
  fi
  local plus=""
  case "$spec" in +*) plus="+"; spec="${spec#+}" ;; esac
  case "$spec" in
    *:*) src="${spec%%:*}"; dst="${spec#*:}" ;;
    *)   src="$spec" ;;
  esac
  # Empty src = delete (the ':<dst>' form). Qualify the dst; branches are the
  # common delete target, tags must be spelled refs/tags/<t>.
  if [ -z "$src" ]; then
    case "$dst" in
      refs/*) : ;;
      *) dst="refs/heads/$dst" ;;
    esac
    PAIRS+=(":$dst"); return 0
  fi
  [ -n "$dst" ] || die "no destination in refspec '$spec' — spell '<src>:<dst>' (or '$spec:$spec' \
to mirror git's dst=src default; this wrapper wants it explicit). A delete is ':<dst>'."
  # Expand shorthand src to a FULL local ref (branch, then tag) — always, not just
  # when the shorthand fails to resolve, so dst qualification below can follow the
  # src's NAMESPACE (a bare 'main' is a branch even though it doesn't spell
  # refs/heads/main).
  local src_full="$src"
  if   git show-ref --verify --quiet "refs/heads/$src" 2>/dev/null; then src_full="refs/heads/$src"
  elif git show-ref --verify --quiet "refs/tags/$src"  2>/dev/null; then src_full="refs/tags/$src"
  elif ! git rev-parse --verify -q "$src" >/dev/null 2>&1; then
    die "cannot resolve source '$src' — not a local ref and not a SHA. The read-back
    compares against this resolution; push a real ref or '<sha>:<dst>'."
  fi
  # Qualify dst the way git does (namespace follows the src ref's namespace). NB:
  # this and the tag checks below use `case` globs — a glob inside single-bracket
  # test is a literal string and NEVER matched (review HOLD H2, 2026-08-28).
  case "$dst" in
    refs/*) : ;;
    *)  case "$src_full" in
          refs/heads/*) dst="refs/heads/$dst" ;;
          refs/tags/*)  dst="refs/tags/$dst" ;;
          *) die "unqualified destination '$dst' for SHA source — push '<sha>:refs/heads/<name>'
    so the read-back knows the exact remote ref." ;;
        esac ;;
  esac
  # Cross-namespace tag→branch: git writes the TAG object to a branch ref and the
  # remote rejects it ("trying to write non-commit object to branch") — peel to
  # the COMMIT here, in the refspec itself, so what is pushed is exactly what the
  # read-back will compare.
  case "$dst" in
    refs/heads/*)
      if [ "$(git cat-file -t "$src_full" 2>/dev/null)" = "tag" ]; then
        src_full="$(git rev-parse --verify "${src_full}^{commit}")" \
          || die "cannot peel tag '$src' to a commit for branch dst '$dst'."
      fi ;;
  esac
  PAIRS+=("${plus}${src_full}:${dst}")
}
for s in "${REFSPECS[@]}"; do resolve_refspec "$s"; done

# ── pre-push: resolve BOTH ends and compare them out loud ────────────────────
# (the 2026-07-26 memory's own instruction: "resolve BOTH ends and compare them
# out loud ... If they are not in the relationship you expect, stop.")
printf '▶ push-verified: %s\n' "$REMOTE"
PRE_ERR="$(mktemp)"; PRE_OUT="$(mktemp)"; RB_ERR=""; RB_OUT=""
# die() paths must not leak the mktemp scratch files (review HOLD L3, 2026-08-28)
trap 'rm -f "$PRE_ERR" "$PRE_OUT" "$RB_ERR" "$RB_OUT" 2>/dev/null' EXIT
remote_state() {  # $1=ref → echoes SHA or empty; rc 0 readable, rc 1 unreadable
  if ! git ls-remote "$REMOTE" "$1" >"$PRE_OUT" 2>"$PRE_ERR"; then return 1; fi
  awk -v r="$1" '$2 == r { print $1; exit }' "$PRE_OUT"
}
PRE_READ_OK=1
SPEC_ARGS=()
declare -A WANT_BY_DST   # dst → the SHA the SOURCE resolved to BEFORE the push
for pair in "${PAIRS[@]}"; do
  bare="${pair#+}"; src="${bare%%:*}"; dst="${bare#*:}"
  if [ -z "$src" ]; then
    # --delete wants plain target ref NAMES; the ':'-form is only for no-flag deletes.
    if [ "$DELETE" = 1 ]; then SPEC_ARGS+=("$dst"); else SPEC_ARGS+=(":$dst"); fi
    say "delete          $dst"
    continue
  fi
  # The SHA the source resolves to NOW. Resolved ONCE, here, BEFORE the push —
  # the read-back compares against THIS resolution, never a post-push re-resolve
  # (verify what was PUSHED). Tag→branch pairs arrive here already peeled.
  want="$(git rev-parse --verify "$src")" || die "cannot resolve '$src' to a SHA."
  WANT_BY_DST["$dst"]="$want"
  SPEC_ARGS+=("$pair")
  # Does THIS push carry force? (per-ref '+' or a global force flag — with force,
  # "git will enforce fast-forward" is a lie: force disables exactly that check.)
  force_here=0
  case "$pair" in +*) force_here=1 ;; esac
  case " ${FLAGS[*]-} " in *" --force "*|*" -f "*|*" --force-with-lease"*) force_here=1 ;; esac
  # Bundled short flags (re-review HOLD HIGH-1, 2026-08-28): git accepts clusters
  # like -uf where the f hides inside — the token scan above can't see it. Any
  # short cluster carrying f counts; over-detection is fail-closed (the force
  # path fetches-or-refuses), under-detection launders rollbacks.
  for _ftok in ${FLAGS[*]-}; do
    case "$_ftok" in --*) ;; -?*f*) force_here=1 ;; esac
  done
  rsha="$(remote_state "$dst")" || { PRE_READ_OK=0; say "local           $src → ${want:0:12}"; say "remote          $dst → UNREADABLE (proceeding; the post-push read-back is the authority)"; continue; }
  say "local           $src → ${want:0:12}"
  if [ -z "$rsha" ]; then
    say "remote          $dst → (absent — new ref)"
    continue
  fi
  say "remote          $dst → ${rsha:0:12}"
  case "$dst" in
    refs/tags/*)
      if [ "$rsha" != "$want" ]; then
        die "tag $dst already exists on $REMOTE at ${rsha:0:12} — a published tag is not
    re-cut (ship-turnkey invariant). Resolve the tag name, don't replace it."
      fi ;;
  esac
  [ "$rsha" = "$want" ] && continue                       # up to date; read-back will confirm
  if ! git cat-file -e "$rsha^{commit}" >/dev/null 2>&1; then
    if [ "$force_here" = 1 ]; then
      # With force carried, deferring to git enforces NOTHING (review HOLD H1,
      # 2026-08-28): the force flag disables the fast-forward check, so a
      # stale-local rollback launders through and reads back "verified". Fail
      # closed — fetch the tip and classify it, or refuse naming the remedy.
      if git fetch -q "$REMOTE" "$dst" 2>/dev/null && git cat-file -e "$rsha^{commit}" >/dev/null 2>&1; then
        say "                remote tip ${rsha:0:12} fetched — classifying the relationship."
      else
        die "REFUSING: remote tip of $dst (${rsha:0:12}) is unknown locally AND the push
    carries force — git enforces NOTHING against an object you do not have, so a
    stale-local rollback would land and read back 'verified' (the 2026-07-26
    shape). Fetch both ends first (git fetch $REMOTE $dst) and re-run so the
    classify can run — or drop the force."
      fi
    else
      say "                remote tip ${rsha:0:12} unknown locally (no fetch, no force) —
    cannot classify; git itself will enforce fast-forward."
      continue
    fi
  fi
  if git merge-base --is-ancestor "$rsha" "$want" 2>/dev/null; then
    continue                                              # fast-forward: the normal safe case
  fi
  if git merge-base --is-ancestor "$want" "$rsha" 2>/dev/null; then
    # local is strictly BEHIND the remote — the verify-the-ref-you-push-from shape.
    if [ "${PUSH_VERIFIED_ALLOW_BACKWARDS:-0}" != "1" ]; then
      die "REFUSING: $src (${want:0:12}) is BEHIND $REMOTE/$dst (${rsha:0:12}) — this push
    would move the remote BACKWARDS. That is the exact shape of 2026-07-26: an
    exhaustively verified payload force-pushed from a stale local ref rolled the
    public front door back 14 versions. Resolve BOTH ends deliberately
    (git log $rsha..$want is empty — you have nothing new). Deliberate rollback:
    PUSH_VERIFIED_ALLOW_BACKWARDS=1 $0 ..."
    fi
    say "⚠ ALLOW_BACKWARDS: pushing ${want:0:12} over ${rsha:0:12} is a deliberate ROLLBACK."
    continue
  fi
  # Diverged: a genuine replacement (history rewrite). Needs force, and force
  # must be an argument, not an accident.
  case "$pair" in
    +*) say "⚠ REPLACEMENT: $dst diverged (remote ${rsha:0:12} / local ${want:0:12}); per-ref force." ;;
    *) case " ${FLAGS[*]-} " in
         *" --force "*|*" -f "*|*" --force-with-lease"*)
           say "⚠ REPLACEMENT: $dst diverged (remote ${rsha:0:12} / local ${want:0:12}); forcing." ;;
         *) die "$dst diverged from $REMOTE (remote ${rsha:0:12}, local ${want:0:12}) — this needs
    --force, and a force push is a decision. Re-check both ends, then add --force." ;;
       esac ;;
  esac
done
[ "$PRE_READ_OK" = 1 ] || { printf '  ⚠ remote unreadable BEFORE the push:\n'; sed 's/^/    /' "$PRE_ERR" >&2; }

# ── THE PUSH (the act — everything above and below is the proof around it) ───
PUSH_SPEC_ARGS=("${SPEC_ARGS[@]}")
printf '  running        git push %s\n' "${FLAGS[*]-} $REMOTE ${PUSH_SPEC_ARGS[*]}"
PUSH_RC=0
git push "${FLAGS[@]+"${FLAGS[@]}"}" "$REMOTE" "${PUSH_SPEC_ARGS[@]}" || PUSH_RC=$?

if [ "$PUSH_RC" != 0 ]; then
  printf '✗ push-verified: git push FAILED (rc=%s). NOTHING is verified. Per-ref landing state:\n' "$PUSH_RC"
fi

# ── the read-back: the remote's own answer, per ref ──────────────────────────
RB_ERR="$(mktemp)"; RB_OUT="$(mktemp)"
read_back() {  # $1=ref → echoes SHA or empty; rc 0 readable, rc 1 unreadable
  if ! git ls-remote "$REMOTE" "$1" >"$RB_OUT" 2>"$RB_ERR"; then return 1; fi
  awk -v r="$1" '$2 == r { print $1; exit }' "$RB_OUT"
}
VERIFIED=0; MISMATCH=0; UNREADABLE=0
for pair in "${PAIRS[@]}"; do
  bare="${pair#+}"; src="${bare%%:*}"; dst="${bare#*:}"
  if [ -z "$src" ]; then
    if ! got="$(read_back "$dst")"; then
      UNREADABLE=$((UNREADABLE+1)); printf '✗ UNVERIFIED %s (delete): remote unreadable — treat as NOT verified\n' "$dst"
      continue
    fi
    if [ -z "$got" ]; then
      VERIFIED=$((VERIFIED+1)); printf 'PUSH-VERIFIED %s %s (deleted)\n' "$REMOTE" "$dst"
    else
      MISMATCH=$((MISMATCH+1)); printf '✗ MISMATCH %s: delete did not land — remote still holds %s\n' "$dst" "${got:0:12}"
    fi
    continue
  fi
  want="${WANT_BY_DST[$dst]:-}"
  [ -n "$want" ] || die "internal: no pre-push resolution recorded for $dst"
  if ! got="$(read_back "$dst")"; then
    UNREADABLE=$((UNREADABLE+1))
    printf '✗ UNVERIFIED %s: push reported success but the read-back FAILED —\n' "$dst"
    sed 's/^/    /' "$RB_ERR"
    printf '    The push PROBABLY landed, but that is a claim, not a verification.\n'
    printf '    Do not write "pushed" in the tracker until this reads back:\n'
    printf '      git ls-remote %s %s   (expect %s)\n' "$REMOTE" "$dst" "${want:0:12}"
    continue
  fi
  if [ "$got" = "$want" ]; then
    VERIFIED=$((VERIFIED+1)); printf 'PUSH-VERIFIED %s %s %s\n' "$REMOTE" "$dst" "${want:0:7}"
  else
    MISMATCH=$((MISMATCH+1))
    printf '✗ MISMATCH %s: local resolved %s but remote shows %s\n' "$dst" "${want:0:12}" "${got:-<absent>}"
    printf '    The push did NOT land as intended — do not report it as pushed.\n'
    printf '    Fix: inspect both ends (git ls-remote %s %s), then re-push deliberately.\n' "$REMOTE" "$dst"
  fi
done

# ── verdict ──────────────────────────────────────────────────────────────────
if [ "$PUSH_RC" != 0 ]; then
  printf '✗ push-verified: PUSH FAILED — %d verified, %d mismatched, %d unreadable. Not delivered.\n' \
    "$VERIFIED" "$MISMATCH" "$UNREADABLE" >&2
  exit 1
fi
if [ "$MISMATCH" -gt 0 ]; then
  printf '✗ push-verified: %d ref(s) MISMATCHED the read-back — the remote does not hold\n    what the tracker would claim. Not verified.\n' "$MISMATCH" >&2
  exit 1
fi
if [ "$UNREADABLE" -gt 0 ]; then
  printf '✗ push-verified: push ran, but %d ref(s) could not be READ BACK — UNVERIFIED, exit 2.\n' "$UNREADABLE" >&2
  exit 2
fi
printf '✓ push-verified: %d ref(s) read back from %s and matching the resolved source SHAs.\n' "$VERIFIED" "$REMOTE"
exit 0
