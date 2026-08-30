#!/usr/bin/env bash
# share-enable.sh — the zero-spend turnkey for SHARING a public link (Tailscale Funnel).
#
# THE GAP THIS CLOSES. `tailscale serve` (the preview skill's default) hands you a link only YOUR
# OWN devices — the ones on your tailnet — can open. To share a link a FRIEND who is NOT on your
# tailnet can open in any browser, you need Tailscale FUNNEL (public HTTPS). Funnel is free on every
# plan (incl. Personal) — ZERO spend — but a node must be ENABLED for it once, and that one-time step
# is a human tap on a consent link (Tailscale then auto-provisions the HTTPS cert + adds the `funnel`
# nodeAttr). Neither a script nor an agent can approve that tap — only the human, in a browser.
#
# WHAT THIS SCRIPT DOES (idempotent, READ-ONLY — it NEVER mutates tailscale). It is a diagnostic +
# turnkey: it checks the preconditions and reports EXACTLY what (if anything) the human must do.
#   • tailscale installed + up + logged in?          (else: the one install / `tailscale up` line)
#   • MagicDNS on (a <host>.ts.net name exists)?      (Funnel needs MagicDNS+HTTPS for its cert)
#   • operator rights (Linux non-root)?               (else: the `sudo tailscale set --operator` line)
#   • is Funnel ENABLED for this node?
#        ENABLED     → say so + surface the PUBLIC url base (where friend-openable links will live)
#                      + the reversible teardown line. exit 0.
#        NOT enabled → relay the ONE-COMMAND consent turnkey (a human taps once). NEVER a silent
#                      warn — a prominent block on stdout + a distinct exit code. exit 2.
# It does NOT start a funnel (that is the `preview` skill's human-gated `share` step) and it NEVER
# runs `tailscale funnel <port>` / `funnel reset` / `tailscale set` — only read-only `status` probes.
#
#   bash scripts/share-enable.sh              # check + report (default funnel port 8443)
#   SHARE_FUNNEL_PORT=10000 bash scripts/share-enable.sh
#   SHARE_FUNNEL_PORT=8443 SHARE_UPSTREAM=http://127.0.0.1:5173 bash scripts/share-enable.sh
#                                             # pre-start OCCUPANCY gate (the preview `share` step)
#
# Env overrides:
#   TS_BIN             (tailscale)   — tailscale binary (selftest points this at a stub)
#   SHARE_FUNNEL_PORT  (8443)        — the public funnel port for the surfaced URL + teardown line.
#                                      Funnel allows ONLY 443 / 8443 / 10000. 443 is usually the box's
#                                      primary front door (an ingress/serve already owns it) — 8443 or
#                                      10000 are the safe picks for a friend-link.
#   SHARE_UPSTREAM     (unset)       — the local upstream you intend to funnel (http://127.0.0.1:<p>).
#                                      When set, the ENABLED branch checks port OCCUPANCY: tailscale
#                                      serve/funnel is SET-not-APPEND (re-pointing a mapped port
#                                      silently REPLACES its handler), so a target port owned by a
#                                      DIFFERENT upstream is a HARD-STOP (exit 7) naming the owner —
#                                      never a green light onto someone else's live app.
#
# Exit codes (consumed by the preview `share` step + share-selftest.sh + share-occupancy-selftest.sh):
#   0  Funnel ENABLED — ready to share; the public URL base is surfaced
#   2  Funnel NOT enabled — the one-time consent turnkey is relayed (human taps once)
#   3  operator/permission gap — the `sudo tailscale set --operator=$USER` one-liner is surfaced
#   4  tailscale not installed — install guidance surfaced
#   5  tailscale not up / not logged in — `tailscale up` guidance surfaced
#   6  MagicDNS precondition unmet (no <host>.ts.net name) — enable guidance surfaced
#   7  target funnel port OCCUPIED by a different upstream — refused; owner named, free-port or
#      box-ingress steer surfaced (requires SHARE_UPSTREAM to prove the owner is not us)
#   1  usage / unexpected
set -uo pipefail

TS_BIN="${TS_BIN:-$(command -v tailscale || echo tailscale)}"
SHARE_FUNNEL_PORT="${SHARE_FUNNEL_PORT:-8443}"

# The node capability CONSENT grants — its presence is the ground truth for "Funnel enabled for this
# node". Real `tailscale status --json` exposes it as the bare cap "funnel" AND/OR a URL-form key that
# STARTS WITH https://tailscale.com/cap/funnel (e.g. .../cap/funnel-ports?ports=443,8443,10000), under
# .Self.CapMap (object keys, modern) and/or .Self.Capabilities (array, older). We match "funnel" OR any
# https://tailscale.com/cap/funnel* across BOTH, so the probe is shape/version-robust (the exact
# .../cap/funnel string alone is NOT what real tailscale emits — see share-selftest's real-shape fixtures).

ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn(){ printf '  \033[33m⚠\033[0m %s\n' "$1"; }
info(){ printf '    %s\n' "$1"; }
die(){  printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq required"

# Funnel only listens on 443 / 8443 / 10000 (Tailscale hard limit). Guard the surfaced port so we
# never print an unreachable URL / teardown line. Non-fatal caution on 443 (usually already taken).
case "$SHARE_FUNNEL_PORT" in
  443)          die "funnel port 443 is the box's primary front door (an ingress/serve usually owns it) — use 8443 or 10000 for a friend-link, never 443" ;;
  8443|10000)   : ;;
  *)            die "SHARE_FUNNEL_PORT=$SHARE_FUNNEL_PORT is not a valid Funnel port — Tailscale allows ONLY 443, 8443, or 10000" ;;
esac

# The public URL for a funnel on $SHARE_FUNNEL_PORT at MagicDNS name $1 (443 → no port suffix).
public_url(){
  if [ "$SHARE_FUNNEL_PORT" = "443" ]; then printf 'https://%s' "$1"; else printf 'https://%s:%s' "$1" "$SHARE_FUNNEL_PORT"; fi
}

# The upstream currently mapped at https://…:<port> in the live serve table ('' = port free).
# Reads $fn_out — `tailscale funnel status` prints the FULL serve table (funnel AND tailnet-only
# blocks; a `serve status` call would trip share-selftest's mutation stub, and is redundant anyway).
# Blocks look like `https://host[:port][/]  (Funnel on|tailnet only)` then `|-- …` handler lines;
# a portless block header is :443.
port_owner(){  # $1=funnel port
  printf '%s\n' "$fn_out" | awk -v port="$1" '
    /^https:\/\// { p = 443
      if (match($1, /:[0-9]+\/?$/)) { p = substr($1, RSTART + 1); sub(/\//, "", p) }
      inblk = (p == port); next }
    inblk && /^[[:space:]]*\|--/ { sub(/^[[:space:]]*\|-- */, ""); print; exit }
  '
}

# The operator one-liner (surfaced, NEVER run — a script must not change tailscale ownership).
operator_hint(){
  echo
  warn "on Linux, a non-root user often needs to be the tailscale 'operator' to drive Funnel."
  info "run this ONCE yourself (it is NOT run for you — a script must not change tailscale ownership):"
  info "    sudo tailscale set --operator=\$USER"
}

echo "▶ share-enable — can this box hand a friend a PUBLIC (funnel) link? (zero-spend)"
echo

# ── 1. installed? ───────────────────────────────────────────────────────────────────────────────
if ! command -v "$TS_BIN" >/dev/null 2>&1 && [ ! -x "$TS_BIN" ]; then
  warn "tailscale not found (looked for: $TS_BIN)"
  info "install it — macOS: \`brew install tailscale\` or the app;  Linux: https://tailscale.com/download"
  info "then \`tailscale up\` (a one-time browser login), and re-run this."
  exit 4
fi

# ── 2. up + logged in? (read-only status probe) ───────────────────────────────────────────────────
st_out="$("$TS_BIN" status --json 2>&1)"; st_rc=$?
if [ $st_rc -ne 0 ]; then
  # A permission/operator failure and a daemon-down failure look different — split them so the human
  # gets the RIGHT next step, never a generic "something's off".
  if printf '%s' "$st_out" | grep -qiE 'operator|access denied|permission denied|not the operator|--operator|needs? .*sudo'; then
    warn "tailscale refused the status probe with a permission error."
    operator_hint
    exit 3
  fi
  warn "tailscale is installed but not answering (daemon down or not logged in)."
  info "start + log in with:  tailscale up"
  exit 5
fi

# rc 0 → parse the JSON. Invalid JSON (a stub/old build) is tolerated field-by-field.
backend="$(printf '%s' "$st_out" | jq -r '.BackendState // ""' 2>/dev/null)"
case "$backend" in
  NeedsLogin|Stopped|NoState|Starting)
    warn "tailscale is not fully up (state: $backend)."
    info "finish with:  tailscale up"
    exit 5 ;;
esac

# ── 3. MagicDNS precondition — a <host>.ts.net name must exist (Funnel needs MagicDNS+HTTPS certs) ──
dns="$(printf '%s' "$st_out" | jq -r '.Self.DNSName // ""' 2>/dev/null | sed 's/\.$//')"
if [ -z "$dns" ]; then
  warn "no MagicDNS name for this node — Funnel needs MagicDNS + HTTPS to mint its public cert."
  info "enable BOTH in the Tailscale admin console (DNS → MagicDNS on; HTTPS Certificates on),"
  info "then re-run. (The Funnel consent step also provisions the cert, but MagicDNS must be on first.)"
  exit 6
fi

# ── 4. is Funnel ENABLED for this node? (the consent-granted capability is the ground truth) ───────
if printf '%s' "$st_out" | jq -e \
    '(((.Self.Capabilities // []) + ((.Self.CapMap // {}) | keys))
       | any(. == "funnel" or startswith("https://tailscale.com/cap/funnel")))' \
    >/dev/null 2>&1; then
  # ── ENABLED ──────────────────────────────────────────────────────────────────────────────────
  ok "Funnel is ENABLED for this node — you can share a PUBLIC link (free, zero-spend)."
  echo
  # OCCUPANCY gate (read-only; adopter clobber fix). Legality (443|8443|10000) is not enough:
  # serve/funnel is SET-not-APPEND, so starting a share on a port a DIFFERENT upstream already owns
  # would silently REPLACE that mapping and darken the live app behind it. With the intent declared
  # (SHARE_UPSTREAM), an occupied-by-other target port is a HARD-STOP, never a green light.
  fn_out="$("$TS_BIN" funnel status 2>/dev/null)"
  owner="$(port_owner "$SHARE_FUNNEL_PORT")"
  # Compare the occupant's ACTUAL upstream to ours by EXACT match, not substring: `grep -F :5173`
  # also matches an occupant on :51730 (prefix collision) and would green-light the very
  # SET-not-APPEND clobber this gate exists to refuse. Extract the http(s):// token from the owner
  # line and equality-test (one trailing slash normalized on each side). An owner whose upstream we
  # can't parse is treated as "not us" → hard-stop (fail-closed).
  owner_up="$(printf '%s\n' "$owner" | grep -oE 'https?://[^[:space:]]+' | head -1 | sed 's:/*$::')"
  want_up="$(printf '%s\n' "${SHARE_UPSTREAM:-}" | sed 's:/*$::')"
  if [ -n "$owner" ] && [ -n "${SHARE_UPSTREAM:-}" ] && [ "$owner_up" != "$want_up" ]; then
    warn "funnel port :$SHARE_FUNNEL_PORT is ALREADY TAKEN — current owner:  $owner"
    info "tailscale serve/funnel is SET-not-APPEND: starting your share here would silently REPLACE"
    info "that mapping and darken whatever is behind it. NOT proceeding."
    echo
    alt=""
    for p in 8443 10000; do   # 443 is never suggested — it is the box's primary front door
      [ "$p" = "$SHARE_FUNNEL_PORT" ] && continue
      [ -z "$(port_owner "$p")" ] && { alt="$p"; break; }
    done
    if [ -n "$alt" ]; then
      info "free funnel port: $alt — re-run with SHARE_FUNNEL_PORT=$alt and share there instead."
    else
      info "every safe funnel port (8443, 10000) is taken — and 443 is the box's front door. Do NOT"
      info "clobber one: route this app through the box-ingress instead (scripts/ingress.sh"
      info "path-routing — the preview skill's Tier 2 — it shares the existing :443 funnel)."
    fi
    exit 7
  fi
  echo "  Your friend-openable link will live under:"
  info "$(public_url "$dns")/…"
  info "(this is the PUBLIC funnel base — anyone with the link opens it, no tailnet needed.)"
  # Best-effort: if a funnel is ALREADY live, surface its actual URL too (read-only status).
  if live="$(printf '%s' "$fn_out" | grep -oE 'https://[a-zA-Z0-9._-]+\.ts\.net(:[0-9]+)?' | head -1)" && [ -n "$live" ]; then
    echo; ok "a funnel is currently LIVE at: $live"
    # No SHARE_UPSTREAM declared → we cannot prove the owner is (or is not) this share: caution only.
    if [ -n "$owner" ] && [ -z "${SHARE_UPSTREAM:-}" ]; then
      warn "note: :$SHARE_FUNNEL_PORT is currently owned by:  $owner"
      info "starting a NEW share there silently REPLACES it (SET-not-APPEND) — pick a free funnel"
      info "port unless that owner IS your app."
    fi
  fi
  echo
  info "reversible teardown (no data loss) when you're done sharing:"
  info "    tailscale funnel --https=$SHARE_FUNNEL_PORT off"
  echo
  info "to actually start a share, use the preview skill's human-gated \`share\` step"
  info "(it starts the funnel on a free port and hands you the public URL)."
  exit 0
fi

# ── NOT ENABLED → the one-time consent turnkey (prominent, on stdout — NEVER a silent warn) ───────
warn "Funnel is NOT yet enabled for this node — one free, one-time human step unlocks it."
echo
echo "  ┌─ enable Funnel (do this ONCE — it is free, zero-spend) ─────────────────────────────"
echo "  │  1. run this on the box (any free funnel port — 8443 or 10000):"
echo "  │"
echo "  │         tailscale funnel $SHARE_FUNNEL_PORT"
echo "  │"
echo "  │  2. it prints a CONSENT LINK (https://login.tailscale.com/…). Open it in a browser —"
echo "  │     you can forward that link to your phone and tap it there."
echo "  │  3. approve. Tailscale then auto-provisions the HTTPS cert + adds the 'funnel' nodeAttr."
echo "  │"
echo "  │  Only YOU can approve this (a browser tap) — no script or agent can, and it edits no ACL."
echo "  │  Re-run this script afterward to confirm: it will report ENABLED."
echo "  └──────────────────────────────────────────────────────────────────────────────────────"
operator_hint
echo
info "after enabling, the public share link will live at:  $(public_url "$dns")/…"
exit 2
