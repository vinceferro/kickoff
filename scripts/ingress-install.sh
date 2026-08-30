#!/usr/bin/env bash
# ingress-install.sh — install a user-systemd unit so the box-ingress Caddy survives reboot.
#
# WHY: today the ingress caddy is started with `caddy start` (a userland background process that dies
# on reboot / logout — the README's standing TODO). A `systemctl --user` unit runs `caddy run` in the
# FOREGROUND as a supervised daemon: it restarts on crash and (with linger) comes back after reboot.
#
# TURNKEY, OPERATOR-RUN. This script only WRITES the unit file and prints the next action. It does NOT
# enable, start, or reload anything — spinning up / swapping the live front door is a deliberate step
# the operator takes, not a side effect of installing. Idempotent: safe to re-run.
#
#   bash scripts/ingress-install.sh
#
# Env overrides: INGRESS_DIR (~/box-ingress) · CADDY_BIN (caddy) · SYSTEMD_USER_DIR (~/.config/systemd/user)
set -uo pipefail

INGRESS_DIR="${INGRESS_DIR:-$HOME/box-ingress}"
CADDY_BIN="${CADDY_BIN:-$(command -v caddy || echo "$HOME/.local/bin/caddy")}"
CADDYFILE="$INGRESS_DIR/Caddyfile"
SYSTEMD_USER_DIR="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
UNIT="box-ingress.service"
UNIT_PATH="$SYSTEMD_USER_DIR/$UNIT"

ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn(){ printf '  \033[33m⚠\033[0m %s\n' "$1"; }
die(){  printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

command -v systemctl >/dev/null 2>&1 || die "systemctl not found — this box has no systemd user session; keep using \`ingress.sh up\`."
[ -x "$CADDY_BIN" ] || die "caddy not found/executable at $CADDY_BIN (set CADDY_BIN)."

mkdir -p "$SYSTEMD_USER_DIR" || die "could not create $SYSTEMD_USER_DIR"

# Write the unit (idempotent — a byte-identical re-run is a no-op message).
NEW_UNIT="$(cat <<EOF
[Unit]
Description=box-ingress — single-front-door Caddy for all apps on this box (kickoff)
Documentation=https://github.com/ (kickoff scripts/ingress.sh)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# caddy run stays in the FOREGROUND — systemd is the supervisor (not \`caddy start\`).
ExecStart=$CADDY_BIN run --config $CADDYFILE --adapter caddyfile
# reload on \`systemctl --user reload box-ingress\` = zero-downtime config swap.
ExecReload=$CADDY_BIN reload --config $CADDYFILE --adapter caddyfile --force
Restart=on-failure
RestartSec=3
# Caddy binds only 127.0.0.1:<listen> (Fix 8c) — Funnel/tailscale serve front it.

[Install]
WantedBy=default.target
EOF
)"

if [ -f "$UNIT_PATH" ] && [ "$(cat "$UNIT_PATH")" = "$NEW_UNIT" ]; then
  ok "unit already present + up to date: $UNIT_PATH (no change)"
else
  printf '%s\n' "$NEW_UNIT" > "$UNIT_PATH" || die "could not write $UNIT_PATH"
  ok "wrote $UNIT_PATH"
fi

echo
echo "  NEXT — run these YOURSELF (this installer never starts the live front door):"
echo
echo "    # 1. let systemd see the new unit"
echo "    systemctl --user daemon-reload"
echo
echo "    # 2. keep it running after logout/reboot (one-time; may prompt for your password)"
echo "    loginctl enable-linger \"\$USER\""
echo
echo "    # 3. stop the current userland caddy FIRST (avoid two caddies fighting for the port):"
echo "    #    (only when you are ready to cut over — this briefly drops the front door)"
echo "    $CADDY_BIN stop 2>/dev/null || true"
echo
echo "    # 4. enable + start the supervised daemon"
echo "    systemctl --user enable --now $UNIT"
echo
echo "    # verify:"
echo "    systemctl --user status $UNIT --no-pager"
echo
ok "installer done — unit written, nothing started. Cut over when you're ready (steps above)."
