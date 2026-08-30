#!/bin/sh
# install.sh — the one-command installer for kickoff  (v0.7: "get in with one command").
#
#   curl -fsSL https://raw.githubusercontent.com/vinceferro/kickoff/core-v0.23/install.sh | sh
#   (the canonical, tag-pinned URL — /main/ is the moving alias; see docs/release-checklist.md §4)
#
# WHAT IT DOES (machine-level only — no repo is touched, no file of yours is edited)
#   1. clones a READ-ONLY engine core at ~/kickoff-core and PINS it at the latest STABLE core-v*
#      tag (or an explicit KICKOFF_TAG=core-vX.Y),
#   2. links ~/.local/bin/kickoff → the core clone's scripts/kickoff (the front door),
#   3. prints the exact two-path footprint + the one-line uninstall, and exactly ONE next step:
#      `kickoff adopt --dry-run --dir .` (read-only) — self-adapting to the explicit front-door path
#      when ~/.local/bin isn't on PATH (the PATH one-liner is an optional aside, never a second step).
#
# RE-RUN = VERIFY-AND-REPAIR — the installer NEVER upgrades; `kickoff pull` owns every upgrade
# (including cycling a running worker). A re-run re-checks the clone's origin + pin coherence,
# repairs a broken/missing bin link, and re-prints tag@commit + the same one next step. It NEVER
# moves an existing pin — safe to re-run blindly, even on a multi-adopter box.
#
# HOW THE PIN WORKS — this installer does NOT reinvent it. The tag-resolve + detach + clean-
# verify is delegated to `kickoff pull` itself (run from the freshly-cloned core in ENGINE-PREP
# mode, which pins the core clone; on a fresh install it writes nothing outside the clone). One
# source of truth for "pin a core"; if pull's resolution ever changes, this installer inherits it.
#
# POSIX sh ON PURPOSE: this is the ONE script that runs via `curl | sh` BEFORE any kickoff/bash
# tool exists, so it stays /bin/sh-clean (no bashisms, no arrays, no pipefail). The pin it
# delegates to (`kickoff pull`) is bash — hence the bash preflight check below.
#
# TRUNCATION ARMOR: the entire body lives in main(), invoked on the LAST line — a partially
# downloaded file (a `curl | sh` cut mid-transfer) defines functions but executes NOTHING.
#
# Env overrides (all default to the real public install; the selftest overrides them to stay hermetic):
#   KICKOFF_TAG           pin this exact core-v* release tag instead of the latest stable
#                         (anything not matching core-v* is refused before any write)
#   KICKOFF_CORE_REMOTE   git URL of the core to clone       (default: the public kickoff repo)
#   KICKOFF_CORE_DIR      where the read-only core clone lives (default: ~/kickoff-core)
#   KICKOFF_BIN_DIR       where the `kickoff` link is placed   (default: ~/.local/bin)
set -eu

say()  { printf '  %s\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$1"; }
die()  { printf '\n\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }
# Display helper: abbreviate a $HOME-prefixed path to ~/… — the footprint reads the way the user
# reads paths, and the printed commands still work (the shell re-expands a leading ~).
homely() { case "$1" in "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }

main() {
  # $HOME feeds the default core/bin dirs + the ~ display; under `set -u` a bare $HOME aborts
  # cryptically when it's unset (cron/CI/minimal containers — same class as the $SHELL guard below).
  [ -n "${HOME:-}" ] || die "\$HOME is not set — set HOME (or KICKOFF_CORE_DIR + KICKOFF_BIN_DIR), then re-run."

  KICKOFF_CORE_REMOTE="${KICKOFF_CORE_REMOTE:-https://github.com/vinceferro/kickoff.git}"
  KICKOFF_CORE_DIR="${KICKOFF_CORE_DIR:-$HOME/kickoff-core}"
  KICKOFF_BIN_DIR="${KICKOFF_BIN_DIR:-$HOME/.local/bin}"
  want_tag="${KICKOFF_TAG:-}"

  printf '\n\033[1mkickoff installer\033[0m — get in with one command\n\n'

  # ── 0. preflight: the tools we (and the pin we delegate to) need ────────────────
  command -v git     >/dev/null 2>&1 || die "git is required to clone the core — install git, then re-run."
  command -v bash    >/dev/null 2>&1 || die "bash is required to run kickoff — install bash, then re-run."
  command -v python3 >/dev/null 2>&1 || die "python3 is required by kickoff — install python3, then re-run."

  # ── 0b. KICKOFF_TAG must name a reviewed core-v* release — refused BEFORE any write ──
  if [ -n "$want_tag" ]; then
    case "$want_tag" in
      core-v*) : ;;
      *) die "KICKOFF_TAG='$want_tag' is not a core-v* release tag — the installer pins ONLY reviewed core-v* releases (e.g. KICKOFF_TAG=core-v0.7). Nothing was installed." ;;
    esac
  fi

  # ── 1. clone the core (first run) or verify an existing clone (re-run) ───────────
  # Mirror `kickoff pull`'s origin-verify: an existing clone MUST track the resolved remote, else a
  # stray repo at this path would get ITS tags pinned as "the core". Fail loud naming both URLs.
  fresh=0 cur_tag=""
  if git -C "$KICKOFF_CORE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    existing="$(git -C "$KICKOFF_CORE_DIR" remote get-url origin 2>/dev/null || true)"
    if [ "$existing" != "$KICKOFF_CORE_REMOTE" ]; then
      die "a clone already exists at $KICKOFF_CORE_DIR but tracks origin '${existing:-(none)}', not '$KICKOFF_CORE_REMOTE'.
    That is not a clone of this core. Move it aside (or set KICKOFF_CORE_DIR / KICKOFF_CORE_REMOTE), then re-run."
    fi
    # Pin coherence: an existing pin = DETACHED HEAD exactly at a core-v* tag. A real pin is NEVER
    # moved — not to a newer release, not to a requested KICKOFF_TAG; `kickoff pull` owns upgrades.
    # A clone parked on a branch (a manual `git clone`) has no pin yet, so it gets one below.
    if ! git -C "$KICKOFF_CORE_DIR" symbolic-ref -q HEAD >/dev/null 2>&1; then
      cur_tag="$(git -C "$KICKOFF_CORE_DIR" describe --tags --exact-match 2>/dev/null || true)"
      case "$cur_tag" in core-v*) : ;; *) cur_tag="" ;; esac
    fi
    if [ -n "$cur_tag" ]; then
      if [ -n "$want_tag" ] && [ "$want_tag" != "$cur_tag" ]; then
        die "the core at $KICKOFF_CORE_DIR is already pinned at $cur_tag — the installer never moves an existing pin. To change versions, run:  kickoff pull $want_tag"
      fi
      say "core clone present at $KICKOFF_CORE_DIR — verifying (a re-run never moves the pin)…"
      # SAY that we are not upgrading. "Re-run the installer to upgrade" is what any normal person
      # assumes, and this installer deliberately refuses — so silence here reads as success while
      # leaving them on the old engine. That is not hypothetical: the operator fetched the v0.12
      # installer to get a v0.12 fix, this path kept his v0.11 pin without comment, his next command
      # ran the OLD engine, and the fix he came for simply did not happen (2026-07-16). The explicit
      # -KICKOFF_TAG path above already dies with the right advice; the bare re-run said nothing.
      # Name the upgrade route unconditionally — being told "I did not upgrade you, here's how" is
      # never worse than finding out three commands later.
      warn "NOT upgrading: this box is pinned at $cur_tag and the installer NEVER moves a pin."
      say  "  If you came here for a NEWER release, the installer cannot give it to you:"
      say  "      kickoff pull <core-vX.Y>        ← the upgrade path (pull owns every upgrade)"
      say  "  Continuing to verify + repair the $cur_tag install."
    else
      say "core clone present at $KICKOFF_CORE_DIR but not pinned at a core-v* tag yet — pinning…"
    fi
  elif [ -e "$KICKOFF_CORE_DIR" ]; then
    die "$KICKOFF_CORE_DIR exists but is not a git clone. Move it aside (or set KICKOFF_CORE_DIR), then re-run."
  else
    say "cloning the engine core → $KICKOFF_CORE_DIR (one-time)…"
    git clone --quiet "$KICKOFF_CORE_REMOTE" "$KICKOFF_CORE_DIR" \
      || die "git clone failed ($KICKOFF_CORE_REMOTE → $KICKOFF_CORE_DIR)."
    fresh=1
  fi

  FRONT="$KICKOFF_CORE_DIR/scripts/kickoff"
  [ -f "$FRONT" ] || die "the clone at $KICKOFF_CORE_DIR has no scripts/kickoff — is $KICKOFF_CORE_REMOTE a kickoff core?"

  # ── 2. PIN — only when there is NO existing pin — REUSE `kickoff pull` (do not reinvent) ──
  # Run the freshly-cloned front door's own `pull` with REPO_DIR pointed AT the core clone: that is
  # ENGINE-PREP mode (no adopt-manifest present) — it fetches, resolves the tag (the latest STABLE
  # core-v*, or the explicit KICKOFF_TAG passed through as pull's <tag> argument), checks it out
  # detached, clean-verifies + runs the existence guard, then STOPS, writing nothing into the
  # clone beyond the detach. An already-pinned clone SKIPS this entirely (verify-and-repair).
  if [ -z "$cur_tag" ]; then
    if [ -n "$want_tag" ]; then
      say "pinning $want_tag (via kickoff pull)…"
    else
      say "pinning the latest core-v* tag (via kickoff pull)…"
    fi
    # Pull's ENGINE-PREP log (fetch/tag-resolve/changelog delta — ~75 lines of engine internals,
    # plus its OWN 'next:' epilogue) belongs to a standalone `kickoff pull`, not the §1 install
    # transcript ("exactly one next step"). Capture it; replay it ONLY when the pull fails — that
    # is when the diagnostics matter.
    pull_log="${TMPDIR:-/tmp}/kickoff-install-pull.$$.log"
    if REPO_DIR="$KICKOFF_CORE_DIR" \
       KICKOFF_CORE_DIR="$KICKOFF_CORE_DIR" \
       KICKOFF_CORE_REMOTE="$KICKOFF_CORE_REMOTE" \
         bash "$FRONT" pull ${want_tag:+"$want_tag"} >"$pull_log" 2>&1; then
      rm -f "$pull_log"
    else
      cat "$pull_log" >&2 2>/dev/null || true
      rm -f "$pull_log"
      die "kickoff pull failed — the core was not pinned (see the pull output above)."
    fi
  fi

  TAG="$(git -C "$KICKOFF_CORE_DIR" describe --tags --exact-match 2>/dev/null || echo '?')"
  SHA="$(git -C "$KICKOFF_CORE_DIR" rev-parse --short=8 HEAD 2>/dev/null || echo '?')"
  # NEVER report success on an unpinned engine — a pin is DETACHED HEAD exactly at a core-v* tag
  # (the same definition the pin-coherence check above uses; the §2 integrity story: tag@commit,
  # auditable). The known way to land here: the adopters registry lists a project pinned at a
  # DIFFERENT tag, so `kickoff pull` protects that sibling — it parks the requested tag in a
  # separate worktree (~/kickoff-versions/<tag>) and deliberately leaves this shared root clone
  # on its BRANCH. `rm -rf ~/kickoff-core` never removes the registry, so uninstall→reinstall on a
  # multi-adopter box lands exactly here. Printing '✓ pinned ? @ <sha>' (or a tag the branch tip
  # merely happens to carry) and linking a branch-tip engine would be a lie — fail LOUD, link nothing.
  pinned_ok=1
  git -C "$KICKOFF_CORE_DIR" symbolic-ref -q HEAD >/dev/null 2>&1 && pinned_ok=0   # on a branch ⇒ NOT pinned
  case "$TAG" in core-v*) : ;; *) pinned_ok=0 ;; esac
  case "$pinned_ok" in
    1) : ;;
    *)
      parked="$(git -C "$KICKOFF_CORE_DIR" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | grep -Fvx "$KICKOFF_CORE_DIR" | head -n 1 || true)"
      # ADOPT THE PARKED PIN. `kickoff pull` did the RIGHT thing here: this box already runs kickoff
      # projects pinned at other tags, so it refused to yank the shared clone out from under them and
      # parked the requested tag in its OWN worktree. That worktree IS a proper detached core-v* pin —
      # so linking it is not the lie the invariant guards against; it is the truth, and the engine the
      # user asked for. Refusing here made "one command to get in" WORK ONLY ON A CLEAN BOX: the
      # installer named the parked dir in its own error and then declined to use it, while both of its
      # suggested remedies were dead ends (keep the clone → no front door at all; delete the registry →
      # break the live projects it exists to protect). Found 2026-07-16 by the operator running the
      # stock one-liner on his own multi-adopter box — nobody had ever installed onto one before.
      # The invariant is unchanged and re-checked below: never link an engine that is not pinned.
      parked_ok=0
      if [ -n "${parked:-}" ] && [ -d "$parked" ] && [ -x "$parked/scripts/kickoff" ]; then
        P_TAG="$(git -C "$parked" describe --tags --exact-match 2>/dev/null || echo '?')"
        parked_ok=1
        git -C "$parked" symbolic-ref -q HEAD >/dev/null 2>&1 && parked_ok=0   # on a branch ⇒ NOT pinned
        case "$P_TAG" in core-v*) : ;; *) parked_ok=0 ;; esac
        # If a tag was explicitly requested, the parked pin must BE that tag — never silently link another.
        if [ -n "${want_tag:-}" ] && [ "$P_TAG" != "$want_tag" ]; then parked_ok=0; fi
      fi
      if [ "$parked_ok" = 1 ]; then
        say "this box already runs kickoff projects pinned at other tags — \`kickoff pull\` protected them"
        say "and parked $P_TAG in its own engine dir. Linking that pin (the shared clone stays untouched)."
        KICKOFF_CORE_DIR="$parked"
        # FRONT was derived from the ORIGINAL core dir far above (before pull ran), so it must be
        # recomputed here or the link silently points back at the shared, UNPINNED clone — i.e. the
        # exact lie this whole block exists to prevent, dressed as a success. Caught by case 13's
        # invariant assertion; the link target is the one thing that actually matters here.
        FRONT="$KICKOFF_CORE_DIR/scripts/kickoff"
        TAG="$P_TAG"
        SHA="$(git -C "$KICKOFF_CORE_DIR" rev-parse --short=8 HEAD 2>/dev/null || echo '?')"
      else
        die "the core clone at $KICKOFF_CORE_DIR did NOT end pinned at a core-v* release tag (HEAD: $TAG @ $SHA — not a detached core-v* pin) — refusing to link an unpinned engine.
    Likely cause: the adopters registry (${KICKOFF_ADOPTERS_REGISTRY:-~/.kickoff/adopters.json}) lists a project pinned at a DIFFERENT tag, so
    'kickoff pull' protected that sibling: the new tag was parked in a separate worktree${parked:+ ($parked)} and this shared clone was left untouched.
    That parked worktree is normally linked automatically — it is not usable here (missing, on a branch, or not the requested tag).
      · the registry entries are REAL (this box runs kickoff projects) → point at the pin you want directly:
          KICKOFF_CORE_DIR=<the parked engine dir> sh install.sh
      · the registry is STALE (left behind by an uninstall — 'rm -rf' never removes it) → delete the registry file, then re-run this installer.
    Nothing was linked."
      fi
      ;;
  esac
  ok "pinned $TAG @ $SHA"

  # ── 3. link the front door — create, or REPAIR a missing/broken link; NEVER clobber a foreign one ──
  mkdir -p "$KICKOFF_BIN_DIR" || die "could not create $KICKOFF_BIN_DIR."
  LINK="$KICKOFF_BIN_DIR/kickoff"
  if [ -e "$LINK" ] || [ -L "$LINK" ]; then
    tgt="$(readlink "$LINK" 2>/dev/null || true)"
    if [ "$tgt" = "$FRONT" ]; then
      :   # already ours — re-pointed below (idempotent)
    elif [ -L "$LINK" ] && [ ! -e "$LINK" ]; then
      # a DANGLING symlink points at nothing — repairing it destroys nothing.
      say "front-door link at $LINK is broken (→ ${tgt:-?}) — repairing…"
    else
      # a real file, or a live symlink to something else: a stranger's OWN `kickoff`
      # (the Wayland launcher, a personal script). Never silently clobber it.
      die "a different 'kickoff' already exists at $LINK — move it aside (or set KICKOFF_BIN_DIR), then re-run."
    fi
  fi
  # rm + ln (not `ln -sfn`, whose -n is non-POSIX): (re)point at the current front door → idempotent.
  rm -f "$LINK"
  ln -s "$FRONT" "$LINK" || die "could not link $LINK → $FRONT."
  ok "linked $LINK → $FRONT"

  printf '\n'
  if [ "$fresh" = 1 ]; then
    ok "installed kickoff $TAG"
  elif [ -z "$cur_tag" ]; then
    ok "already installed — pinned kickoff $TAG"
  else
    ok "already installed — verified kickoff $TAG (pin untouched; 'kickoff pull' owns upgrades)"
  fi

  # ── 4. the footprint + the one-line uninstall — the trust story, printed every run ──
  core_disp="$(homely "$KICKOFF_CORE_DIR")"
  link_disp="$(homely "$LINK")"
  printf '\n'
  say "Installed exactly two things — no repo touched, no file of yours edited:"
  printf '    %-22s  %s\n' "$core_disp" "the engine (a read-only pinned git clone)"
  printf '    %-22s  %s\n' "$link_disp" "one symlink to its front door"
  say "Undo completely:  rm -rf $core_disp $link_disp"

  # ── 5. exactly ONE next step — self-adapting so it always works as printed ──
  # `--dir .` is LOAD-BEARING: the front door resolves itself into the pinned core clone, so a bare
  # `kickoff adopt` auto-targets the clone and the pure-pull guard refuses (correctly). The explicit
  # `--dir .` targets the repo the user just cd'd into — the printed step must work verbatim.
  case ":${PATH}:" in
    *":${KICKOFF_BIN_DIR}:"*) on_path=1 ;;
    *)                        on_path=0 ;;
  esac
  printf '\n'
  if [ "$on_path" = 1 ]; then
    say "Next:  cd /path/to/your/repo && kickoff adopt --dry-run --dir .    (read-only — prints the plan, writes nothing)"
  else
    front_disp="$(homely "$FRONT")"
    say "Next:  cd /path/to/your/repo && $front_disp adopt --dry-run --dir .    (read-only — prints the plan, writes nothing)"
    # The optional aside — the user's own paste, never an rc-file edit, never a second required
    # step. Default $SHELL first: under `set -u` a bare ${SHELL##*/} aborts when SHELL is unset
    # (the norm for `curl | sh` from cron/CI/containers).
    login_shell="${SHELL:-}"; login_shell="${login_shell##*/}"
    printf '\n'
    if [ "$login_shell" = "fish" ]; then
      say "Optional — for the short 'kickoff' command, put $KICKOFF_BIN_DIR on your PATH:  fish_add_path $KICKOFF_BIN_DIR"
    else
      say "Optional — for the short 'kickoff' command, put $KICKOFF_BIN_DIR on your PATH:  export PATH=\"$KICKOFF_BIN_DIR:\$PATH\""
    fi
  fi
  printf '\n'
}

main "$@"
