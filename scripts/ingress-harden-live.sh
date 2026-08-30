#!/usr/bin/env bash
# ingress-harden-live.sh — OPERATOR TURNKEY: make a LIVE, hand-managed box-ingress
# loopback-private + reboot-persistent with the SMALLEST reversible change, WITHOUT
# disrupting any existing route (especially a hand-edited auth-gated one, e.g. the
# investor @pitch deck).
#
# WHY THIS EXISTS (and why it is NOT `ingress.sh up`):
#   The live box runs an OLDER hand-managed ingress.sh + a HAND-EDITED Caddyfile — a
#   bare `:<listen> {` wildcard bind (LAN-reachable) plus a hand-added, auth-gated route
#   (@pitch) that lives ONLY in the Caddyfile, not the registry. A full regen (`ingress.sh
#   up`) would DROP that hand-edited route. So this turnkey does NOT regenerate, does NOT
#   install the hardened engine ingress.sh, does NOT migrate anything into the registry,
#   and does NOT add the drop-guard — it makes TWO minimal, targeted, reversible edits:
#     1. Caddyfile: rewrite ONLY the listener line  `:<listen> {`  ->  `127.0.0.1:<listen> {`
#        (every route block — including the @pitch basic_auth block — stays BYTE-IDENTICAL).
#     2. ingress.sh gen: patch just the bind prefix so FUTURE regens emit loopback too.
#   Then (opt-in) it installs a systemd user unit so Caddy survives reboot.
#
# SAFE BY DEFAULT — DRY-RUN. It NEVER touches the live Caddy (no reload/restart) and NEVER
# writes the ingress files unless you pass --apply. A dry run only reads + prints a diff.
#
#   bash scripts/ingress-harden-live.sh            # DRY-RUN: show the diff, change nothing
#   bash scripts/ingress-harden-live.sh --apply    # back up, edit, validate, hot-reload, persist
#   bash scripts/ingress-harden-live.sh --persist  # also install the reboot-persistence unit
#   bash scripts/ingress-harden-live.sh --rollback # restore the most recent backup + reload
#
# Env overrides:
#   INGRESS_DIR        (~/box-ingress)   — the live state dir (registry + Caddyfile + ingress.sh)
#   CADDY_BIN          (caddy)           — caddy binary (same resolution ingress.sh uses)
#   SYSTEMD_USER_DIR   (~/.config/systemd/user) — where the persistence unit is written
#   INGRESS_INSTALL_SH (sibling ingress-install.sh) — the systemd-unit installer this delegates to
set -uo pipefail

INGRESS_DIR="${INGRESS_DIR:-$HOME/box-ingress}"
REGISTRY="$INGRESS_DIR/registry.json"
CADDYFILE="$INGRESS_DIR/Caddyfile"
INGRESS_SH="$INGRESS_DIR/ingress.sh"
PIDFILE="$INGRESS_DIR/caddy.pid"
CADDY_BIN="${CADDY_BIN:-$(command -v caddy || echo "$HOME/.local/bin/caddy")}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INGRESS_INSTALL_SH="${INGRESS_INSTALL_SH:-$SCRIPT_DIR/ingress-install.sh}"
SYSTEMD_USER_DIR="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
UNIT_PATH="$SYSTEMD_USER_DIR/box-ingress.service"

ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn(){ printf '  \033[33m⚠\033[0m %s\n' "$1"; }
die(){  printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
info(){ printf '  \033[36m·\033[0m %s\n' "$1"; }

APPLY=0; PERSIST=0; ROLLBACK=0
for arg in "$@"; do
  case "$arg" in
    --apply)    APPLY=1 ;;
    --persist)  PERSIST=1 ;;
    --rollback) ROLLBACK=1 ;;
    -h|--help)  sed -n '2,33p' "$0"; exit 0 ;;
    *) die "unknown flag: $arg (use --apply | --persist | --rollback | --help)" ;;
  esac
done

# ── preflight ────────────────────────────────────────────────────────────────────────────
command -v jq >/dev/null || die "jq required"
[ -f "$REGISTRY" ]   || die "no registry at $REGISTRY (set INGRESS_DIR)"
[ -f "$CADDYFILE" ]  || die "no Caddyfile at $CADDYFILE (set INGRESS_DIR)"
[ -f "$INGRESS_SH" ] || die "no ingress.sh at $INGRESS_SH (set INGRESS_DIR)"

listen="$(jq -r '.listen' "$REGISTRY")"
[ -n "$listen" ] && [ "$listen" != "null" ] || die "registry has no .listen port"

is_running(){ [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }
unit_installed(){ [ -f "$UNIT_PATH" ]; }

# ── backup: copy the three live files into a timestamped dir; never proceed on failure ─────
BACKUP_ROOT="$INGRESS_DIR/.harden-backups"
make_backup() {
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local dir="$BACKUP_ROOT/$stamp"
  mkdir -p "$dir" || die "cannot create backup dir $dir — refusing to proceed"
  cp -p "$INGRESS_SH" "$dir/ingress.sh"   || die "backup of ingress.sh failed — refusing to proceed"
  cp -p "$CADDYFILE"  "$dir/Caddyfile"    || die "backup of Caddyfile failed — refusing to proceed"
  cp -p "$REGISTRY"   "$dir/registry.json"|| die "backup of registry.json failed — refusing to proceed"
  printf '%s' "$dir"
}
latest_backup() {
  [ -d "$BACKUP_ROOT" ] || return 1
  local d; d="$(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort | tail -1)"
  [ -n "$d" ] || return 1
  printf '%s' "${d%/}"
}

# ── loopback detection ─────────────────────────────────────────────────────────────────────
# bind = loopback  -> listener already `127.0.0.1:<listen> {`
# bind = wildcard  -> bare `:<listen> {` (LAN-reachable)
detect_bind() {
  if grep -Eq "^[[:space:]]*127\.0\.0\.1:$listen[[:space:]]*\{" "$CADDYFILE"; then
    printf 'loopback'
  elif grep -Eq "^[[:space:]]*:$listen[[:space:]]*\{" "$CADDYFILE"; then
    printf 'wildcard'
  else
    printf 'unknown'
  fi
}

# ── edit builders (write to a TEMP file; caller decides whether to install in place) ───────
# Caddyfile: substitute the leading `:` of ONLY the listener line, preserving everything else
# byte-for-byte (the `s` runs only on lines matching the bare-bind address).
build_new_caddyfile() {
  local out="$1"
  sed "/^[[:space:]]*:$listen[[:space:]]*{/ s|:$listen|127.0.0.1:$listen|" "$CADDYFILE" > "$out"
}
# ingress.sh: rewrite just the bind prefix in the gen() listener echo. If the exact pattern is
# absent (already patched / a different ingress.sh), copy unchanged and signal skip via rc1.
INGRESS_OLD_LINE='echo ":$listen {"'
INGRESS_NEW_LINE='echo "127.0.0.1:$listen {"'
build_new_ingress() {
  local out="$1"
  if grep -qF "$INGRESS_OLD_LINE" "$INGRESS_SH"; then
    sed 's|echo ":$listen {"|echo "127.0.0.1:$listen {"|' "$INGRESS_SH" > "$out"
    return 0
  fi
  cp "$INGRESS_SH" "$out"
  return 1
}

# ── serving check (loopback curl of a known route; any HTTP response = serving) ────────────
verify_serving() {
  curl -sS -o /dev/null --max-time 3 "http://127.0.0.1:$listen/" 2>/dev/null
}

# ── persistence: delegate to the systemd-unit installer (WRITES a unit, never auto-enables) ─
run_persistence() {
  [ -x "$INGRESS_INSTALL_SH" ] || { warn "installer not found/executable at $INGRESS_INSTALL_SH — skipping persistence"; return 0; }
  echo
  info "installing reboot-persistence (systemd user unit — writes the unit only; never enables it):"
  INGRESS_DIR="$INGRESS_DIR" CADDY_BIN="$CADDY_BIN" SYSTEMD_USER_DIR="$SYSTEMD_USER_DIR" \
    bash "$INGRESS_INSTALL_SH" || warn "installer returned nonzero — persistence unit may not be written"
}

# ── rollback mode ──────────────────────────────────────────────────────────────────────────
if [ "$ROLLBACK" = 1 ]; then
  b="$(latest_backup)" || die "no backup found under $BACKUP_ROOT — nothing to roll back to"
  ok "restoring most recent backup: $b"
  cp -p "$b/Caddyfile"  "$CADDYFILE"  || die "restore of Caddyfile failed"
  cp -p "$b/ingress.sh" "$INGRESS_SH" || die "restore of ingress.sh failed"
  ok "restored Caddyfile + ingress.sh from $b"
  if is_running; then
    if "$CADDY_BIN" reload --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
      ok "live Caddy hot-reloaded with the restored config"
    else
      warn "reload failed — the restored Caddyfile is on disk; run \`ingress.sh up\` to reload"
    fi
  else
    info "no running Caddy (pidfile absent/stale) — files restored on disk, nothing reloaded"
  fi
  exit 0
fi

# ── main harden flow ───────────────────────────────────────────────────────────────────────
bind="$(detect_bind)"
info "INGRESS_DIR = $INGRESS_DIR   listen = $listen   current bind = $bind"

if [ "$bind" = "loopback" ]; then
  # Loopback already done. Only persistence might remain.
  if unit_installed; then
    ok "already hardened — listener is 127.0.0.1:$listen and the persistence unit is installed. No-op."
    exit 0
  fi
  if [ "$APPLY" = 1 ] || [ "$PERSIST" = 1 ]; then
    ok "listener already loopback (127.0.0.1:$listen) — installing persistence only."
    run_persistence
    exit 0
  fi
  ok "already hardened — listener is 127.0.0.1:$listen (loopback). No-op."
  info "persistence unit not yet installed — re-run with --apply (or --persist) to install it."
  exit 0
fi

[ "$bind" = "wildcard" ] || die "could not find the listener line (:$listen { or 127.0.0.1:$listen {) in $CADDYFILE — refusing to edit blindly"

# Build the proposed edits into temp files (nothing on disk changes yet).
new_cf="$(mktemp)"; new_ing="$(mktemp)"
trap 'rm -f "$new_cf" "$new_ing"' EXIT
build_new_caddyfile "$new_cf"
ingress_patch_skipped=0
build_new_ingress "$new_ing" || ingress_patch_skipped=1

# VALIDATE the proposed Caddyfile BEFORE anything touches the live files.
if ! "$CADDY_BIN" validate --config "$new_cf" --adapter caddyfile >/dev/null 2>&1; then
  die "the loopback-edited Caddyfile FAILED \`caddy validate\` — aborting, no change made.
     inspect: $CADDY_BIN validate --config <edited> --adapter caddyfile"
fi
ok "edited Caddyfile passes \`caddy validate\`"

# Show the diffs (Caddyfile + the ingress.sh bind line).
echo
echo "  ── Caddyfile diff (only the listener line changes) ──"
diff -u "$CADDYFILE" "$new_cf" | sed 's/^/  /' || true
echo
echo "  ── ingress.sh gen() bind-line diff ──"
if [ "$ingress_patch_skipped" = 1 ]; then
  warn "ingress.sh: expected pattern [$INGRESS_OLD_LINE] not found — skipping the gen() patch (already patched / different ingress.sh)"
else
  diff -u "$INGRESS_SH" "$new_ing" | sed 's/^/  /' || true
fi

if [ "$APPLY" != 1 ]; then
  echo
  warn "DRY-RUN: no files changed, the live Caddy was NOT reloaded."
  echo "  DRY-RUN: would reload the live caddy; re-run with --apply to apply."
  if [ "$PERSIST" = 1 ]; then
    echo "  DRY-RUN: would also install the systemd persistence unit (writes a user unit; never auto-enables)."
  fi
  exit 0
fi

# ── APPLY ──────────────────────────────────────────────────────────────────────────────────
echo
# make_backup runs in a command substitution, so its internal `die` only exits the SUBSHELL — with
# `set -uo pipefail` (no `set -e`) the main shell would otherwise CONTINUE and overwrite the live
# Caddyfile with an empty $backup and no recoverable copy. The `|| die` propagates the failure to the
# MAIN shell so a backup failure fails CLOSED: nothing is edited or reloaded.
backup="$(make_backup)" || die "backup failed — refusing to edit or reload the live files (nothing was changed)"
[ -n "$backup" ] && [ -d "$backup" ] || die "backup did not produce a directory — refusing to proceed (nothing was changed)"
ok "backed up ingress.sh + Caddyfile + registry.json -> $backup"

cp -p "$new_cf" "$CADDYFILE" || die "failed to write the edited Caddyfile — backup is at $backup"
ok "installed loopback Caddyfile (listener now 127.0.0.1:$listen)"
if [ "$ingress_patch_skipped" = 1 ]; then
  warn "ingress.sh gen() patch skipped (pattern absent) — future regens keep their current bind"
else
  cp -p "$new_ing" "$INGRESS_SH" || warn "failed to write patched ingress.sh — Caddyfile edit stands; future regens keep the old bind"
  ok "patched ingress.sh gen() so future regens emit 127.0.0.1:$listen"
fi

# Re-validate the IN-PLACE file; on failure restore the backup Caddyfile.
if ! "$CADDY_BIN" validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
  cp -p "$backup/Caddyfile" "$CADDYFILE"
  is_running && "$CADDY_BIN" reload --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1
  die "in-place Caddyfile failed validation — RESTORED the backup Caddyfile and aborted."
fi

# Hot-reload the live Caddy (reload, not restart — no downtime), then verify it still serves.
if is_running; then
  if "$CADDY_BIN" reload --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
    ok "live Caddy hot-reloaded (no downtime)"
    if verify_serving; then
      ok "verified: Caddy still serving on 127.0.0.1:$listen"
    else
      warn "reload succeeded but the localhost health probe did not get a response — check \`ingress.sh status\`"
    fi
  else
    cp -p "$backup/Caddyfile" "$CADDYFILE"
    "$CADDY_BIN" reload --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1
    die "reload of the edited config FAILED — RESTORED + reloaded the backup Caddyfile, aborted."
  fi
else
  warn "no running Caddy (pidfile absent/stale) — files are hardened on disk; start with \`ingress.sh up\` or the persistence unit below"
fi

# Persistence (runs on --apply, or --persist). The installer only WRITES the unit + prints the
# operator's manual enable steps — it never enables a service on its own.
run_persistence

echo
ok "done. To undo: bash $0 --rollback"
