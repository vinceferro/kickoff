#!/usr/bin/env bash
# adopt-migrate.sh — move ONE pull-adopter from the old core origin to the new public-line repo.
#
#   bash scripts/adopt-migrate.sh --repo /path/to/adopter \
#        [--remote git@github.com:vinceferro/kickoff.git] [--tag core-v1.0.0-alpha] [--dry-run]
#
# WHAT THIS DOES (one turnkey, fail-closed at every step, idempotent to re-run):
#   1. DETECT the adopter's current pin — .kickoff/instance.env (KICKOFF_CORE_DIR +
#      KICKOFF_CORE_REMOTE, read in a SUBSHELL like cmd_pull does), .kickoff/core.lock
#      (format 2: tag + commit), and the adopters-registry row (repo → tag → version_dir).
#   2. VERIFY the new origin — reachable (git ls-remote), the target tag EXISTS there, and
#      the tag's tree passes the EXISTENCE CONTRACT (every path in its scripts/core-manifest.txt
#      is present in the checkout) — all BEFORE a single byte is written into the adopter.
#   3. PREPARE a FRESH core clone at $KICKOFF_VERSIONS_DIR/<tag> (default ~/kickoff-versions/<tag>)
#      — the same place `kickoff pull` parks a per-tag worktree — detached at the tag, clean-tree
#      verified. The OLD core dir is NEVER touched, moved, or deleted (it is the rollback path).
#   4. RE-POINT, through the machinery itself — instance.env is surgically edited (the
#      _persist_env_var_to_instance_env idiom: line-replace, append-if-absent, atomic mv, never a
#      wholesale rewrite), then the NEW core's own `kickoff pull <tag>` runs with the new values
#      EXPLICITLY pinned in the child env (the fossil-env lesson: an ambient KICKOFF_CORE_DIR
#      held by a long-lived caller must never beat the freshly-written file). The pull writes
#      core.lock, seam-syncs, plugin-resyncs and RE-REGISTERS the registry row — the turnkey
#      never hand-edits state the machinery owns.
#   5. RUN THE SAME GATE the target would run (hop-gate-parity): the NEW core's preflight, pin
#      scope first (exactly what the pull ran), then FULL scope when no worker is live (that is
#      the supervisor's own startup gate; a live worker false-fails #4, so there we defer to the
#      hop — the supervisor re-resolves KICKOFF_CORE_DIR from instance.env at hop time).
#   6. PRINT a P1–P4 verdict readable from a phone: what changed, what now verifies (read back
#      from the ADOPTER'S OWN FILES — consumed state, not exit codes), and the exact rollback.
#
# ROLLBACK (one block, nothing deleted): the old core dir is still on disk; restore the two
# instance.env lines and re-pin. The pre-migration instance.env + core.lock are backed up
# beside them with a timestamp; the verdict prints the literal lines.
#
# WHY A TURNKEY AT ALL — the seams a naive "just edit the remote" hits (all verified in code):
#   · the core-clone ORIGIN GUARD (scripts/kickoff, cmd_pull step 1) dies when the clone at
#     KICKOFF_CORE_DIR tracks a different origin than KICKOFF_CORE_REMOTE — both must move together;
#   · a BARE `kickoff pull` auto-selects only `^core-v[0-9]+(\.[0-9]+)+$` — a pre-release tag like
#     core-v1.0.0-alpha is deliberately NOT auto-selected, so the migration must name the tag;
#   · preflight #6 resolves the pinned tag INSIDE the clone at KICKOFF_CORE_DIR — a lock naming a
#     tag that exists only in the OLD repo fail-closes on the next start;
#   · the adopters registry's version_dir must follow the new clone or the sibling logic parks
#     worktrees against a stale path.
#
# Env seams (all optional; the selftest uses them for hermetic fixtures):
#   KICKOFF_VERSIONS_DIR       where the fresh clone lands        (default ~/kickoff-versions)
#   KICKOFF_ADOPTERS_REGISTRY  the registry file adopt-manifest.py reads
#                              (default ~/.kickoff/adopters.json)
#
# Exit: 0 migrated (or already migrated — idempotent), 1 refusal/failure. Writes into the
# adopter repo ONLY between steps 4 and 5; every earlier failure leaves it byte-untouched.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

say() { printf '[migrate %s] %s\n' "$(date -u +%H:%M:%S 2>/dev/null || echo now)" "$*"; }
die() { printf '[migrate] ERROR: %s\n' "$*" >&2; exit 1; }

NEW_REMOTE_DEFAULT="git@github.com:vinceferro/kickoff.git"
NEW_TAG_DEFAULT="core-v1.0.0-alpha"

REPO=""  REMOTE="$NEW_REMOTE_DEFAULT"  TAG="$NEW_TAG_DEFAULT"  DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)    shift; [ $# -gt 0 ] || die "--repo needs a path"; REPO="$1"; shift ;;
    --repo=*)  REPO="${1#--repo=}"; shift ;;
    --remote)  shift; [ $# -gt 0 ] || die "--remote needs a URL"; REMOTE="$1"; shift ;;
    --remote=*) REMOTE="${1#--remote=}"; shift ;;
    --tag)     shift; [ $# -gt 0 ] || die "--tag needs a tag name"; TAG="$1"; shift ;;
    --tag=*)   TAG="${1#--tag=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument '$1' (usage: adopt-migrate.sh --repo <path> [--remote <url>] [--tag <tag>] [--dry-run])" ;;
  esac
done
[ -n "$REPO" ] || die "--repo is required (the adopter repo to migrate)"
REPO="$(cd "$REPO" 2>/dev/null && pwd -P)" || die "--repo does not exist or is not accessible: $REPO"
case "$TAG" in
  core-v*) : ;;
  *) die "refusing tag '$TAG' — migration pins only core-v* release tags (the same shape `kickoff pull` accepts)" ;;
esac

VERSIONS_ROOT="${KICKOFF_VERSIONS_DIR:-$HOME/kickoff-versions}"
REGISTRY="${KICKOFF_ADOPTERS_REGISTRY:-$HOME/.kickoff/adopters.json}"
KICKOFF_DIR="$REPO/.kickoff"
IENV="$KICKOFF_DIR/instance.env"
LOCK="$KICKOFF_DIR/core.lock"

# ── surgical instance.env edit — the _persist_env_var_to_instance_env idiom (scripts/kickoff):
#    replace the NAME= line (bare or `export `), append if absent, preserve every other line
#    byte-for-byte, atomic random-tmp + mv. instance.env is adopter-owned config.
persist_env_var() {   # $1=file $2=name $3=value
  local file="$1" name="$2" value="$3" dir tmp line replaced=0
  [ -f "$file" ] || return 1
  dir="$(dirname "$file")"
  tmp="$(mktemp "$dir/.instance.env.XXXXXX")" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$name="*|"export $name="*)
        printf 'export %s="%s"\n' "$name" "$value"; replaced=1 ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$file" > "$tmp"
  [ "$replaced" = "1" ] || printf 'export %s="%s"\n' "$name" "$value" >> "$tmp"
  mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  return 0
}

# read ONE var out of the adopter's instance.env — SUBSHELL source (never into THIS shell; the
# file is untrusted-shaped config), print its value or nothing.
read_env_var() {   # $1=file $2=name
  local file="$1" name="$2"
  [ -f "$file" ] || return 0
  ( set +u; cd /; REPO_DIR=""; . "$file" >/dev/null 2>&1 || true; printf '%s' "${!name:-}" ) 2>/dev/null || true
}

lock_field() {   # $1=field-name — print that `format 2` core.lock field (tag/commit)
  [ -f "$LOCK" ] || return 0
  sed -n "s/^$1 //p" "$LOCK" | head -1
}

# ══ 1. DETECT the current pin ═══════════════════════════════════════════════════════════════
say "adopter:      $REPO"
[ -f "$IENV" ] || die "no .kickoff/instance.env at $REPO — this is not a kickoff adopter (or not the repo you meant)"
[ -f "$LOCK" ] || die "no .kickoff/core.lock at $REPO — migration targets PULL adopters only (a source checkout upgrades via git pull)"

CUR_CORE="$(read_env_var "$IENV" KICKOFF_CORE_DIR)"
CUR_REMOTE="$(read_env_var "$IENV" KICKOFF_CORE_REMOTE)"
CUR_TAG="$(lock_field tag)"
CUR_COMMIT="$(lock_field commit)"
[ -n "$CUR_CORE" ]    || die "instance.env sets no KICKOFF_CORE_DIR — cannot find the current core clone"
[ -n "$CUR_REMOTE" ]  || die "instance.env sets no KICKOFF_CORE_REMOTE — cannot tell what origin we are migrating FROM"
[ -n "$CUR_TAG" ]     || die "core.lock is not format 2 (no `tag ` line) — re-pin with `kickoff pull` before migrating"
say "current pin:  $CUR_TAG @ ${CUR_COMMIT:-?} (core dir $CUR_CORE)"
say "current origin: $CUR_REMOTE"

# the registry row (best-effort READ; the pull re-writes it through the real tool)
reg_row() {   # prints "tag<TAB>version_dir" for this repo's row, or nothing
  python3 - "$REGISTRY" "$REPO" <<'PY' 2>/dev/null || true
import json, os, sys
try:
    reg = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
repo = os.path.realpath(sys.argv[2])
for a in reg.get("adopters", []):
    r = a.get("repo")
    if isinstance(r, str) and r.strip() and os.path.realpath(r) == repo:
        print("%s\t%s" % (a.get("tag", ""), a.get("version_dir", "")))
        break
PY
}
if [ -f "$REGISTRY" ]; then
  ROW="$(reg_row)" || ROW=""
  if [ -z "$ROW" ]; then
    die "no registry row for $REPO in $REGISTRY — register it first (a pull would; the sibling logic depends on it)"
  fi
  say "registry row:  $(printf '%s' "$ROW" | tr '\t' ' ')"
else
  die "no adopters registry at $REGISTRY — the sibling logic needs it; refusing to migrate blind"
fi

# normalize a remote for the same-repo/different-transport compare (the cmd_pull guard's
# _normalize_git_remote idiom, simplified for the forms that matter here): strip trailing
# slashes + one .git + the scheme, fold scp-like user@host:path → user@host/path. A LOCAL
# PATH remote (a fixture, a file:// clone source) has no colon before the first '/' and
# passes through untouched. Different repos stay different — the compare never false-matches.
canon_remote() {
  local u="${1:-}" auth rest
  while [ "${u%/}" != "$u" ]; do u="${u%/}"; done
  u="${u%.git}"
  while [ "${u%/}" != "$u" ]; do u="${u%/}"; done
  case "$u" in *://*) u="${u#*://}" ;; esac
  case "$u" in
    *:*)
      auth="${u%%:*}"; rest="${u#*:}"
      case "$rest" in
        /*) ;;                  # host:/abs/path — already slash-separated, keep as-is
        *) u="$auth/$rest" ;;   # git@github.com:org/repo → git@github.com/org/repo
      esac
      ;;
  esac
  printf '%s' "$u"
}

# already migrated? (idempotent re-run) — same remote + same tag pinned + the clone is really there
ALREADY=0
if [ "$(canon_remote "$CUR_REMOTE")" = "$(canon_remote "$REMOTE")" ] && [ "$CUR_TAG" = "$TAG" ] \
   && git -C "$CUR_CORE" rev-parse --git-dir >/dev/null 2>&1; then
  ALREADY=1
fi

# ══ 2. VERIFY the new origin — BEFORE any write ══════════════════════════════════════════════
say "new origin:   $REMOTE"
say "new tag:      $TAG"
if ! git ls-remote --heads "$REMOTE" >/dev/null 2>&1; then
  die "new origin UNREACHABLE ($REMOTE) — check the URL / your keys / network. Nothing was written."
fi
say "new origin reachable ✓"
TAG_SHA="$(git ls-remote --tags "$REMOTE" "refs/tags/$TAG" 2>/dev/null | awk -v t="refs/tags/$TAG" '$2==t {print $1}' | head -1)"
if [ -z "$TAG_SHA" ]; then
  # a peeled ^{} entry alone means the tag object exists but points nowhere we can pin — same refusal
  die "tag $TAG NOT FOUND at $REMOTE — the maintainer must tag + push it first (visible: $(git ls-remote --tags "$REMOTE" 2>/dev/null | awk '{print $2}' | tr '\n' ' ')). Nothing was written."
fi
say "tag exists at origin ✓ ($TAG_SHA)"

# ══ 3. PREPARE the fresh core clone (or reuse it, idempotently) ═══════════════════════════════
NEW_CORE="$VERSIONS_ROOT/$TAG"
mkdir -p "$VERSIONS_ROOT" 2>/dev/null || die "cannot create $VERSIONS_ROOT"
if git -C "$NEW_CORE" rev-parse --git-dir >/dev/null 2>&1; then
  EXISTING_ORIGIN="$(git -C "$NEW_CORE" remote get-url origin 2>/dev/null || true)"
  if [ "$(canon_remote "$EXISTING_ORIGIN")" != "$(canon_remote "$REMOTE")" ]; then
    die "a git checkout already lives at $NEW_CORE but tracks origin '${EXISTING_ORIGIN:-<none>}' (not $REMOTE) — refusing to touch a clone I cannot account for. Move it aside or point --remote at what it tracks."
  fi
  say "existing clone at $NEW_CORE — fetching…"
  git -C "$NEW_CORE" fetch --tags --prune --force origin >/dev/null 2>&1 \
    || die "git fetch failed in $NEW_CORE"
else
  [ ! -e "$NEW_CORE" ] && [ ! -L "$NEW_CORE" ] \
    || die "$NEW_CORE exists and is not a git checkout — refusing to clobber it. Inspect + move it aside, then re-run."
  say "cloning the new core (one-time): $REMOTE → $NEW_CORE"
  git clone -q "$REMOTE" "$NEW_CORE" || die "git clone failed ($REMOTE → $NEW_CORE)"
fi
git -C "$NEW_CORE" fetch --force origin "refs/tags/$TAG:refs/tags/$TAG" >/dev/null 2>&1 \
  || die "force-fetch of refs/tags/$TAG failed in $NEW_CORE"
git -C "$NEW_CORE" checkout -q --detach "$TAG" \
  || die "cannot check out $TAG in $NEW_CORE"
DIRT="$(git -C "$NEW_CORE" status --porcelain 2>&1)" \
  || die "cannot verify the new core checkout is clean ($NEW_CORE): $DIRT"
[ -z "$DIRT" ] || die "the new core checkout at $NEW_CORE is DIRTY — it must stay read-only. Inspect by hand: git -C \"$NEW_CORE\" status"
NEW_COMMIT="$(git -C "$NEW_CORE" rev-parse HEAD)" \
  || die "cannot resolve HEAD in $NEW_CORE"
say "fresh core ready ✓ ($NEW_CORE @ $TAG ${NEW_COMMIT:0:12}, clean tree)"

# ── the EXISTENCE CONTRACT — every core-manifest path present in the tag tree, BEFORE re-pointing
#    (the same guard `kickoff pull` runs before writing core.lock; catching it here keeps a
#    partial-core tag from ever reaching the adopter)
MANIFEST="$NEW_CORE/scripts/core-manifest.txt"
[ -f "$MANIFEST" ] || die "tag $TAG carries no scripts/core-manifest.txt — not a coherent core release"
MISSING_COUNT=0; MISSING_LIST=""
while IFS= read -r _mp || [ -n "$_mp" ]; do
  _mp="${_mp%$'\r'}"; [ -z "$_mp" ] && continue
  case "$_mp" in \#*) continue ;; esac
  if [ ! -e "$NEW_CORE/$_mp" ]; then MISSING_COUNT=$((MISSING_COUNT+1)); MISSING_LIST="$MISSING_LIST $_mp"; fi
done < "$MANIFEST"
[ "$MISSING_COUNT" -eq 0 ] \
  || die "EXISTENCE CONTRACT violated — tag $TAG is missing $MISSING_COUNT core-manifest path(s):$MISSING_LIST — refusing to migrate onto a partial core. Nothing was written."
# pin-scope support — the startup-gate verdict below must not mislabel a pre-scope preflight
grep -q 'scope=pin' "$NEW_CORE/scripts/preflight.sh" 2>/dev/null \
  || die "tag $TAG's preflight.sh predates pin scope (no 'scope=pin' token) — the post-migration gate could not run honestly. Refusing."
say "existence contract ✓ ($(grep -vc -e '^\s*$' -e '^#' "$MANIFEST" 2>/dev/null || echo '?') manifest paths present; preflight supports pin scope)"

# ── the pull's own front door must exist in the tag (the migration runs IT, not this script)
[ -f "$NEW_CORE/scripts/kickoff" ] || die "tag $TAG carries no scripts/kickoff — the pull step cannot run"

if [ "$DRY_RUN" = "1" ]; then
  say ""
  say "DRY-RUN OK — no bytes written. The plan:"
  say "  1. backup  $IENV + $LOCK → $KICKOFF_DIR/pre-migrate-<ts>/*"
  say "  2. edit    $IENV: KICKOFF_CORE_REMOTE=$REMOTE, KICKOFF_CORE_DIR=$NEW_CORE"
  say "  3. pull    bash $NEW_CORE/scripts/kickoff pull $TAG   (writes core.lock, seam-syncs, re-registers)"
  say "  4. gates   pin-scope preflight (+ full scope when no worker is live)"
  say "  5. verdict P1–P4 + rollback lines"
  say "apply: re-run without --dry-run"
  exit 0
fi

# ══ 4. RE-POINT — backup, surgical edit, then the machinery's own pull ════════════════════════
TS="$(date -u +%Y%m%dT%H%M%SZ)"
BK="$KICKOFF_DIR/pre-migrate-$TS"
if [ "$ALREADY" = "1" ]; then
  say "already migrated (remote + tag match) — verifying consumed state only (no writes)"
else
  mkdir -p "$BK" || die "cannot create backup dir $BK"
  cp -p "$IENV" "$BK/instance.env" || die "backup of instance.env failed — refusing to proceed without one"
  cp -p "$LOCK" "$BK/core.lock"   || die "backup of core.lock failed — refusing to proceed without one"
  say "backup ✓ $BK (pre-migration instance.env + core.lock)"
  persist_env_var "$IENV" KICKOFF_CORE_REMOTE "$REMOTE" || { cp -p "$BK/instance.env" "$IENV"; die "could not edit KICKOFF_CORE_REMOTE into $IENV — restored the backup"; }
  persist_env_var "$IENV" KICKOFF_CORE_DIR "$NEW_CORE"  || { cp -p "$BK/instance.env" "$IENV"; die "could not edit KICKOFF_CORE_DIR into $IENV — restored the backup"; }
  say "instance.env re-pointed ✓ (KICKOFF_CORE_REMOTE + KICKOFF_CORE_DIR → the new origin)"
fi

# THE PULL — the NEW core's own front door, with every identity var EXPLICITLY pinned in the
# child env (a fossil KICKOFF_CORE_DIR/REPO_DIR held by a long-lived caller must not beat the
# freshly-written instance.env — the hop-gate-parity lesson). Scrub the ambient channel/data
# vars the same way the pull selftest does, so only THIS adopter's file answers.
say "running the new core's own pull:  kickoff pull $TAG"
PULL_LOG="$(mktemp)"; PULL_RC=0
env -u REPO_DIR -u KICKOFF_CORE_DIR -u KICKOFF_CORE_REMOTE -u INSTANCE_ENV \
    -u TELEGRAM_STATE_DIR -u MEMORY_DB -u MEMORY_INDEX -u MC_STATE_FILE -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
    REPO_DIR="$REPO" KICKOFF_CORE_DIR="$NEW_CORE" KICKOFF_CORE_REMOTE="$REMOTE" \
    INSTANCE_ENV="$IENV" \
    timeout 600 bash "$NEW_CORE/scripts/kickoff" pull "$TAG" 2>&1 | tee "$PULL_LOG"
PULL_RC="${PIPESTATUS[0]}"
if [ "$PULL_RC" -ne 0 ] || ! grep -Eq '^\[kickoff [^]]*\] PULL OK' "$PULL_LOG"; then
  [ "$ALREADY" = "1" ] || { cp -p "$BK/instance.env" "$IENV"; say "instance.env restored from $BK (core.lock may still name $TAG — re-run this script after fixing the pull, or restore $BK/core.lock too)"; }
  die "the pull did NOT verify (rc=$PULL_RC, no 'PULL OK' line) — read the output above. A #6/#8 line = pin problem; fix + re-run (idempotent)."
fi
say "pull verified ✓ (PULL OK)"

# registry read-back — the pull re-registers through adopt-manifest.py; verify it LANDED
TAB=$'\t'
ROW_AFTER="$(reg_row)" || ROW_AFTER=""
ROW_TAG="${ROW_AFTER%%"$TAB"*}"
ROW_VD="${ROW_AFTER#*"$TAB"}"
if [ "$ROW_TAG" != "$TAG" ]; then
  # not fatal to the pin, but the sibling logic needs the row — repair it through the real tool
  say "registry row still at '${ROW_TAG:-<none>}' — re-registering through the pinned tag's own tool…"
  python3 "$NEW_CORE/scripts/adopt-manifest.py" adopters-register --repo "$REPO" --tag "$TAG" --version-dir "$NEW_CORE" \
    || die "could not update the adopters registry ($REGISTRY) — sibling detection will mis-read this org. Fix by hand: adopters-register --repo $REPO --tag $TAG --version-dir $NEW_CORE"
fi

# ══ 5. THE SAME GATE the target would run (hop-gate-parity) ═══════════════════════════════════
# pin scope — EXACTLY what the pull ran (the same script, the same env discipline), re-run
# independently so the verdict is our own read, not the pull's self-report.
say "startup gate (pin scope — #6 core.lock + #8 seam/plugin):"
PIN_RC=0
env -u REPO_DIR -u KICKOFF_CORE_DIR -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
    REPO_DIR="$REPO" KICKOFF_CORE_DIR="$NEW_CORE" \
    bash "$NEW_CORE/scripts/preflight.sh" --pin || PIN_RC=$?
[ "$PIN_RC" -eq 0 ] || die "pin-scope preflight FAILED (rc=$PIN_RC) — the pin is not coherent; do NOT restart the worker. See above."

# full scope when no live worker (the supervisor's own startup gate); a LIVE worker false-fails
# #4, and the pull already touched refresh-requested so the supervisor hops + re-resolves
# KICKOFF_CORE_DIR from instance.env at the hop (supervisor's engine-hop watch does this).
SUP_LOCK="$KICKOFF_DIR/supervisor.lock"
FULL_RC=""  FULL_NOTE=""
SUP_PID="$(cat "$SUP_LOCK" 2>/dev/null || true)"
if [ -n "$SUP_PID" ] && kill -0 "$SUP_PID" 2>/dev/null; then
  FULL_NOTE="worker live (pid $SUP_PID) — full gate deferred to the hop (the supervisor re-runs it at start)"
  say "$FULL_NOTE"
else
  say "no live worker — running the FULL startup gate (what the supervisor runs at start):"
  FULL_RC=0
  env -u REPO_DIR -u KICKOFF_CORE_DIR -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
      REPO_DIR="$REPO" KICKOFF_CORE_DIR="$NEW_CORE" \
      bash "$NEW_CORE/scripts/preflight.sh" || FULL_RC=$?
  [ "$FULL_RC" -eq 0 ] || die "FULL preflight FAILED (rc=$FULL_RC) — session-readiness is broken (channel/memory/…); the PIN itself verified. Read the [FAIL] lines above; the worker will fail-closed at next start until fixed."
fi

# ══ 6. P1–P4 verdict — consumed state, read back from the adopter's OWN files ════════════════
NEWLOCK_TAG="$(lock_field tag)"
NEWLOCK_COMMIT="$(lock_field commit)"
V_REMOTE="$(read_env_var "$IENV" KICKOFF_CORE_REMOTE)"
V_CORE="$(read_env_var "$IENV" KICKOFF_CORE_DIR)"
V_ORIGIN="$(git -C "$NEW_CORE" remote get-url origin 2>/dev/null || true)"
V_ENGTAG="$(git -C "$NEW_CORE" describe --tags --exact-match 2>/dev/null || true)"
V_HEAD="$(git -C "$NEW_CORE" rev-parse HEAD 2>/dev/null || true)"
leg() { if eval "$2" >/dev/null 2>&1; then say "  ✓ $1"; else say "  ✗ $1"; FAILS=$((FAILS+1)); fi; }
FAILS=0
say ""
say "══ MIGRATION VERDICT for $REPO ══"
say "P1 pin:      core.lock = $NEWLOCK_TAG @ ${NEWLOCK_COMMIT:0:12} (was $CUR_TAG @ ${CUR_COMMIT:0:12})"
leg "P1 core.lock pins $TAG"                                    "[ \"$NEWLOCK_TAG\" = \"$TAG\" ]"
leg "P1 lock commit == new core HEAD"                           "[ \"$NEWLOCK_COMMIT\" = \"$V_HEAD\" ]"
say "P2 origin:   instance.env → KICKOFF_CORE_DIR=$V_CORE"
say "             KICKOFF_CORE_REMOTE=$V_REMOTE"
leg "P2 instance.env remote is the new origin"                  "[ \"\$(canon_remote \"\$V_REMOTE\")\" = \"\$(canon_remote \"\$REMOTE\")\" ]"
leg "P2 instance.env core dir is the new clone"                 "[ \"\$V_CORE\" = \"\$NEW_CORE\" ]"
leg "P2 the clone's own origin is the new repo"                 "[ \"\$(canon_remote \"\$V_ORIGIN\")\" = \"\$(canon_remote \"\$REMOTE\")\" ]"
say "P3 pull+gate: the new core's pull said PULL OK; pin-scope preflight re-ran rc0${FULL_RC:+; full-scope gate rc$FULL_RC}${FULL_NOTE:+; $FULL_NOTE}"
leg "P3 the checkout IS detached at $TAG"                       "[ \"$V_ENGTAG\" = \"$TAG\" ]"
leg "P3 the pull log carries zero ERROR lines"                  "! grep -q '^\\[kickoff\\] ERROR:' \"$PULL_LOG\""
say "P4 registry: row → $(printf '%s' "$ROW_AFTER" | tr '\t' ' ')"
leg "P4 registry row tags $TAG + the new version_dir"           "[ \"\$ROW_TAG\" = \"$TAG\" ] && [ \"\$ROW_VD\" = \"\$NEW_CORE\" ]"
say ""
say "ROLLBACK (nothing was deleted — the old core stays at $CUR_CORE):"
say "  cp -p \"$BK/instance.env\" \"$IENV\""
say "  cp -p \"$BK/core.lock\"   \"$LOCK\""
say "  …then, with a worker stopped:  bash \"$CUR_CORE/scripts/kickoff\" pull \"$CUR_TAG\""
say "  (one file restore re-points both env vars; the pull re-verifies the old pin)"
say ""
if [ "$FAILS" -gt 0 ]; then
  die "$FAILS verdict leg(s) FAILED — the migration did not fully verify; read the ✗ lines above"
fi
say "MIGRATED ✓ $REPO → $TAG from $REMOTE — all P1–P4 legs green."
