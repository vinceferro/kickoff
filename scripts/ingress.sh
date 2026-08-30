#!/usr/bin/env bash
# ingress.sh — ONE Caddy as the single public front door for every app on this box,
# fronted by ONE Tailscale Funnel port (NAT-friendly public HTTPS, no port-forward, no domain).
#
# PROMOTED from ~/box-ingress/ingress.sh into the pinned kickoff core (design §4 / §7.6). This is
# packaging, not building: the machinery is proven live. The promotion lands three hardening fixes
# the design calls out (Fix 8a auth-field, 8b gen()-side port guard, 8c loopback-bind + health) so
# the tailnet-private preview boundary is genuinely private and reproducible from the registry.
#
# Model (converged): one Funnel port → one Caddy → everything namespaced by PATH as
# /<project>/<app>. Infinite apps; scale is bounded by box resources, not Funnel's 3-port limit.
# Each app must OWN its base path (/<project>/<app>) via env — no hardcoded "/". Caddy shapes the
# ingress; the app honours the path. Single owner of the tailscale config → no "caddies fighting".
#
#   Funnel :443 → Caddy 127.0.0.1:9000 →  /bliz/api  /bliz/app  /bliz/pay   (reverse_proxy)
#                                         /beauty/web                        (static web export)
#   Public: https://<host>.ts.net/<project>/<app>
#
# Usage:
#   ingress.sh gen                          # registry.json -> Caddyfile
#   ingress.sh up                           # generate + start (or hot-reload) Caddy
#   ingress.sh down                         # stop Caddy
#   ingress.sh add-app <project> <app> <static|proxy> <target> [strip=true|false]
#   ingress.sh rm-app  <project> <app>
#   ingress.sh remove  <project>            # delete a whole project (all its apps) + regen  [eject calls this]
#   ingress.sh health                       # curl every proxy upstream + check every static root; nonzero if any down
#   ingress.sh urls                         # print every app's public URL
#   ingress.sh funnel                       # apply the single tailscale funnel mapping (needs Funnel enabled)
#   ingress.sh funnel-reset
#   ingress.sh status
#
# Env overrides:
#   INGRESS_DIR            (~/box-ingress)   — machine-level singleton state dir (registry + Caddyfile)
#   CADDY_BIN             (caddy)           — caddy binary
#   TS_BIN                (tailscale)       — tailscale binary
#   INGRESS_ADMIN         (localhost:2019)  — Caddy admin endpoint emitted into the Caddyfile
#   INGRESS_RESERVED_PORTS ("9100 9101 9200") — private-serve ports that must NEVER reach the public funnel
set -uo pipefail

INGRESS_DIR="${INGRESS_DIR:-$HOME/box-ingress}"
REGISTRY="$INGRESS_DIR/registry.json"
CADDYFILE="$INGRESS_DIR/Caddyfile"
CADDY_BIN="${CADDY_BIN:-$(command -v caddy || echo "$HOME/.local/bin/caddy")}"
TS_BIN="${TS_BIN:-$(command -v tailscale || echo tailscale)}"
PIDFILE="$INGRESS_DIR/caddy.pid"
INGRESS_ADMIN="${INGRESS_ADMIN:-localhost:2019}"

# Reserved private-serve ports that must NEVER be wired onto the PUBLIC funnel. Mission Control
# (private, tailnet-only) lives on these — registering one as a Caddy proxy target would expose
# internal/business state to the open internet. Env-overridable so a box whose MC serve port differs
# can widen the guard. The default covers every port a kickoff Mission Control is known to serve on —
# MC is NEVER a legitimate PUBLIC app, so widening the denylist is pure defense-in-depth:
#   9200 = kickoff Mission Control board (this box: `python3 server.py 9200`)
#   9100 = stock mission-control/server.py default
#   9101 = MC secondary
INGRESS_RESERVED_PORTS="${INGRESS_RESERVED_PORTS:-9100 9101 9200}"

ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn(){ printf '  \033[33m⚠\033[0m %s\n' "$1"; }
die(){ printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

# Extract the port from a proxy target: bare ':PORT', 'host:PORT', or '127.0.0.1:PORT[/path]'.
_port_of() {
  local target="$1" tport=""
  case "$target" in
    *:*) tport="${target##*:}";;   # everything after the last colon
    :*)  tport="${target#:}";;
  esac
  tport="${tport%%/*}"             # strip any trailing path (127.0.0.1:9100/foo -> 9100)
  printf '%s' "$tport"
}

# True (rc0) if $1 is a reserved private-serve port.
_is_reserved_port() {
  local p="$1" rp
  for rp in $INGRESS_RESERVED_PORTS; do [ "$p" = "$rp" ] && return 0; done
  return 1
}

# _canon_repo: physical realpath of a repo path, existence-tolerant — how add_app stamps a project's
# `repo` field and `remove --if-repo` compares it (G10a). An existing dir → `pwd -P` (resolves
# symlinks); else `realpath -m` (normalize a non-existent tail); else the raw string. Runs the `cd`
# in a subshell, so it never changes the caller's cwd.
_canon_repo() {
  local p="${1:-}" out
  [ -z "$p" ] && { printf ''; return 0; }
  if out="$(cd "$p" 2>/dev/null && pwd -P)"; then printf '%s' "$out"; return 0; fi
  realpath -m -- "$p" 2>/dev/null || printf '%s' "$p"
}

[ -f "$REGISTRY" ] || die "no registry at $REGISTRY"
command -v jq >/dev/null || die "jq required"

# ── Fix 2 — helpers for the fail-closed DROP-GUARD (below) ────────────────────────────────────────
# A Caddyfile "matcher DEFINITION" is a line that STARTS (after indent) with `@<name> path …` or
# `@<name> {` — the route-defining lines gen emits. NOT `handle @m {` / `redir @m …` / `header @m …`
# (those REFERENCE a matcher; they don't define one — anchoring on a leading `@` excludes them).
# _matcher_names prints the sorted-unique defined-matcher names in a file; _matcher_lines prints
# `name<TAB>firstpath` (firstpath empty for a `{`-block matcher) so the guard can tell a registry-
# removed app (a self-consistent @<proj>_<app> whose name == its /<proj>/<app> path) from a genuinely
# HAND-EDITED route (e.g. the live `@pitch path /pitch-a9dc8f46`, whose name ≠ its path).
_matcher_names() {
  awk '/^[[:space:]]*@[^[:space:]]+[[:space:]]+(path|\{)/ { n=$1; sub(/^@/,"",n); print n }' "$1" | sort -u
}
_matcher_lines() {
  awk '
    /^[[:space:]]*@[^[:space:]]+[[:space:]]+path[[:space:]]/ { n=$1; sub(/^@/,"",n); print n "\t" $3 }
    /^[[:space:]]*@[^[:space:]]+[[:space:]]+\{/               { n=$1; sub(/^@/,"",n); print n "\t"  }
  ' "$1"
}

# _drop_guard <new-caddyfile> <existing-caddyfile>
# Prints (space-joined, @-prefixed) the HAND-EDITED matchers the NEW generation would DROP, and
# returns 1 if any exist, else 0. A matcher in the EXISTING file is a hand-edit iff the new generation
# does NOT re-emit it, it is not a fixed tool matcher (@dynamic / @root_only), and it is not a
# self-consistent registry app-matcher (@<proj>_<app> whose name == its /<proj>/<app> path — i.e. an
# app legitimately removed from the registry, as `remove` does). No-op (returns 0) on first gen (no
# existing file) or when INGRESS_ALLOW_DROP=1. Read-only: it prints, never writes.
_drop_guard() {
  local newfile="$1" oldfile="$2"
  [ -f "$oldfile" ] || return 0                                        # first gen — nothing to drop
  [ "${INGRESS_ALLOW_DROP:-0}" = "1" ] && return 0                     # explicit override
  local new_names; new_names="$(_matcher_names "$newfile")"
  local dropped="" name firstpath derived
  while IFS=$'\t' read -r name firstpath; do
    [ -n "$name" ] || continue
    printf '%s\n' "$new_names" | grep -qxF "$name" && continue         # still emitted by the new gen
    case "$name" in dynamic|root_only) continue ;; esac                # fixed tool matcher
    if [ -n "$firstpath" ]; then
      derived="${firstpath#/}"; derived="${derived//\//_}"             # /demo/web -> demo_web
      [ "$name" = "$derived" ] && continue                             # registry-removed app (tool-owned)
    fi
    dropped="$dropped @$name"
  done < <(_matcher_lines "$oldfile")
  [ -z "$dropped" ] && return 0
  printf '%s' "${dropped# }"
  return 1
}

gen() {
  # ── Fix 8b — RESERVED-PORT GUARD runs at GENERATION over EVERY proxy target ─────────────────────
  # The original guard lived ONLY in add_app(); gen/up regenerate from the hand-editable registry.json
  # with NO check, so a single manual registry edit + `up` could publish Mission Control to the open
  # internet. Validate here, at the choke point every path routes through — refuse to generate (exit
  # nonzero, write NO Caddyfile) if any proxy target points at a reserved private-serve port.
  local _offending=""
  local _tgt _tp
  while IFS= read -r _tgt; do
    [ -n "$_tgt" ] || continue
    _tp="$(_port_of "$_tgt")"
    [ -n "$_tp" ] || continue
    if _is_reserved_port "$_tp"; then _offending="$_offending $_tgt(:$_tp)"; fi
  done < <(jq -r '(.projects // {}) | to_entries[] | (.value.apps // {}) | to_entries[]
                  | select(.value.type == "proxy") | .value.target' "$REGISTRY")
  if [ -n "$_offending" ]; then
    die "refusing to GENERATE — proxy target(s) point at reserved private-serve port(s):$_offending.
     Mission Control must stay tailnet-only; this would hand internal state to the public funnel.
     Caddyfile was NOT written. (reserved = '$INGRESS_RESERVED_PORTS'; override via INGRESS_RESERVED_PORTS)"
  fi

  local listen; listen="$(jq -r '.listen' "$REGISTRY")"
  # Fix 2 — generate to a TEMP file first, run the fail-closed drop-guard, and only then atomically
  # replace the live Caddyfile. A REFUSED gen (a hand-edited route would be dropped) therefore leaves
  # the existing Caddyfile BYTE-UNCHANGED. Temp lives beside the target so the mv is atomic (same fs).
  local _cf_dir _tmp_cf
  _cf_dir="$(dirname "$CADDYFILE")"
  _tmp_cf="$(mktemp "$_cf_dir/.Caddyfile.XXXXXX")" || die "cannot create a temp Caddyfile in $_cf_dir"
  {
    echo "# GENERATED from registry.json by ingress.sh — do not edit by hand."
    echo "{"
    echo "    admin $INGRESS_ADMIN"
    echo "    auto_https off   # TLS terminated by Tailscale Funnel; Caddy serves plain HTTP locally"
    echo "}"
    echo ""
    # Fix 8c-bind — bind LOOPBACK (127.0.0.1:<listen>), NOT a bare :<listen> wildcard. A wildcard
    # bind is LAN-reachable, so "tailnet-private" is a lie until the listener is loopback. Funnel and
    # `tailscale serve` proxy to 127.0.0.1:<listen> fine, so the public path is unaffected.
    echo "127.0.0.1:$listen {"
    echo "    encode gzip"
    echo "    # Kill stale HTML/bfcache on dev/demo serving, but KEEP the immutable"
    echo "    # _next/static + /static chunks cacheable — no-store on those breaks Next.js."
    echo "    @dynamic {"
    echo "        not path */_next/static/* */static/*"
    echo "    }"
    echo "    header @dynamic Cache-Control \"no-store\""
    jq -r '
      # Fix 8a — an optional per-app "auth": {"<user>":"<bcrypt-hash>", ...} → a basic_auth block
      # inside that app handle, so a hand-edited basic_auth (the live investor pitch-deck) is
      # REPRODUCED from the registry on regen instead of silently dropped.
      def authblock($a):
        if $a.auth then
          "\n        basic_auth {\n"
          + ($a.auth | to_entries | map("            \(.key) \(.value)") | join("\n"))
          + "\n        }"
        else "" end;
      (.projects // {}) | to_entries[] | .key as $proj | (.value.apps // {}) | to_entries[] |
      .key as $app | .value as $a | ("/" + $proj + "/" + $app) as $path | ($proj + "_" + $app) as $m |
      if ($a.type == "proxy" and (($a.strip_prefix // false) == false)) then
        # upstream owns its routing + trailing-slash (e.g. Next.js basePath) — match the exact
        # path AND the subtree, proxy as-is, NO no-slash→slash redirect (that would loop against
        # Next stripping the trailing slash).
        ("    @\($m) path \($path) \($path)/*",
         "    handle @\($m) {\(authblock($a))\n        reverse_proxy \($a.target)\n    }")
      else
        # static or strip-proxy — redirect no-slash→slash, then strip the prefix.
        ("    @\($m) path \($path)",
         "    redir @\($m) \($path)/",
         (if $a.type == "static" then
            "    handle_path \($path)/* {\(authblock($a))\n        root * \($a.target)\n        try_files {path} /index.html\n        file_server\n    }"
          else
            "    handle_path \($path)/* {\(authblock($a))\n        reverse_proxy \($a.target)\n    }"
          end))
      end
    ' "$REGISTRY"
    rr="$(jq -r '.root_redirect // empty' "$REGISTRY")"
    if [ -n "$rr" ]; then
      echo "    @root_only path /"
      echo "    redir @root_only $rr"
    fi
    echo "    handle {"
    echo "        respond \"box-ingress: no app at this path\" 404"
    echo "    }"
    echo "}"
  } > "$_tmp_cf"
  "$CADDY_BIN" fmt --overwrite "$_tmp_cf" >/dev/null 2>&1 || true
  # fail-closed drop-guard: refuse to clobber a HAND-EDITED route absent from the registry (e.g. the
  # live investor pitch-deck `@pitch`). A refused gen leaves the existing Caddyfile byte-unchanged.
  local _drops="" _dg_rc=0
  _drops="$(_drop_guard "$_tmp_cf" "$CADDYFILE")" || _dg_rc=$?
  if [ "$_dg_rc" -ne 0 ]; then
    rm -f "$_tmp_cf"
    die "gen would drop $(printf '%s' "$_drops" | wc -w | tr -d ' ') hand-edited route(s): $_drops
     migrate them into registry.json (e.g. as an app with an \"auth\" field), or re-run with
     INGRESS_ALLOW_DROP=1 to overwrite anyway. The existing Caddyfile was left BYTE-UNCHANGED."
  fi
  mv -f "$_tmp_cf" "$CADDYFILE" || { rm -f "$_tmp_cf"; die "failed to install the generated Caddyfile at $CADDYFILE"; }
  ok "generated $CADDYFILE"
}

is_running(){ [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

up() {
  gen
  "$CADDY_BIN" validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1 \
    || die "Caddyfile failed validation — run: $CADDY_BIN validate --config $CADDYFILE --adapter caddyfile"
  if is_running; then
    "$CADDY_BIN" reload --config "$CADDYFILE" --adapter caddyfile && ok "Caddy hot-reloaded (no downtime)"
  else
    "$CADDY_BIN" start --config "$CADDYFILE" --adapter caddyfile --pidfile "$PIDFILE" && ok "Caddy started (pid $(cat "$PIDFILE" 2>/dev/null))"
  fi
}

down(){ "$CADDY_BIN" stop 2>/dev/null; rm -f "$PIDFILE"; ok "Caddy stopped"; }

add_app() {
  local proj="$1" app="$2" type="$3" target="$4" strip="${5:-false}"
  [ -n "$proj" ] && [ -n "$app" ] && [ -n "$target" ] || die "usage: add-app <project> <app> <static|proxy> <target> [strip]"

  # Denylist at the ADD path (early UX — the gen() guard is the load-bearing backstop). Refuse
  # (loud error, NO write/reload) any proxy target that points at a reserved private-serve port.
  if [ "$type" = "proxy" ]; then
    local tport; tport="$(_port_of "$target")"
    if [ -n "$tport" ] && _is_reserved_port "$tport"; then
      die "refusing to register reserved private-serve port :$tport as a PUBLIC proxy target (target=$target). Mission Control must stay tailnet-only — registry NOT modified."
    fi
  fi

  [ "$type" = "static" ] && strip=true
  # G10a — stamp a per-PROJECT `repo` field (canonical realpath of $INGRESS_REPO) when provided, so
  # eject's `remove --if-repo` can PROVE these routes belong to a given repo (vs a same-basename
  # sibling's). Absent $INGRESS_REPO ⇒ NO repo field written (legacy-compatible; the project stays
  # repo-less and eject SKIPs its removal + instructs, rather than guess-deleting a sibling's routes).
  local repo_canon=""
  [ -n "${INGRESS_REPO:-}" ] && repo_canon="$(_canon_repo "$INGRESS_REPO")"
  local tmp; tmp="$(mktemp)"
  if [ -n "$repo_canon" ]; then
    jq --arg p "$proj" --arg a "$app" --arg t "$type" --arg tg "$target" --argjson s "$strip" --arg r "$repo_canon" '
      .projects[$p].repo = $r
      | .projects[$p].apps[$a] = {type:$t, target:$tg, strip_prefix:$s}
    ' "$REGISTRY" > "$tmp" && mv "$tmp" "$REGISTRY"
  else
    jq --arg p "$proj" --arg a "$app" --arg t "$type" --arg tg "$target" --argjson s "$strip" '
      .projects[$p].apps[$a] = {type:$t, target:$tg, strip_prefix:$s}
    ' "$REGISTRY" > "$tmp" && mv "$tmp" "$REGISTRY"
  fi
  ok "added /$proj/$app ($type $target)"; up
}

rm_app() {
  local proj="$1" app="$2"; local tmp; tmp="$(mktemp)"
  jq --arg p "$proj" --arg a "$app" 'del(.projects[$p].apps[$a])' "$REGISTRY" > "$tmp" && mv "$tmp" "$REGISTRY"
  ok "removed /$proj/$app"; up
}

# remove <project> [--if-repo <repo>] — delete a WHOLE project (all its apps) from the registry, then
# regen. This is what `kickoff eject` calls for machine-level de-integration (zero repo footprint).
# `--if-repo` (G10a) is the IDENTITY GUARD: remove ONLY when the project's recorded `repo` matches —
# so ejecting ~/work/app can never delete a same-basename ~/clients/x/app's LIVE routes. DISTINCT
# exit codes so eject logs HONESTLY (never a false "removed" on a no-op or a sibling's routes):
#   rc0  removed  (no --if-repo, OR --if-repo matched the recorded repo)
#   rc3  NOT-REGISTERED — the project isn't in the registry (a genuine no-op; NOT "removed")
#   rc4  LEGACY-no-repo — --if-repo given but the project has NO recorded repo → refuse (can't prove
#        identity; NEVER cross-repo-delete on a guess) — leave it in place for eject to instruct
#   rc5  MISMATCH — --if-repo given but the recorded repo is a DIFFERENT repo → refuse (a same-
#        basename sibling owns these routes) — leave them untouched
# Regenerates + hot-reloads ONLY if a caddy is already running (never STARTS one — teardown must not).
remove() {
  local proj="${1:-}"; [ "$#" -gt 0 ] && shift
  local if_repo="" has_if_repo=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --if-repo)   has_if_repo=1; shift; if_repo="${1:-}"; [ "$#" -gt 0 ] && shift ;;
      --if-repo=*) has_if_repo=1; if_repo="${1#--if-repo=}"; shift ;;
      *) die "remove: unknown arg '$1' (usage: remove <project> [--if-repo <repo>])" ;;
    esac
  done
  [ -n "$proj" ] || die "usage: remove <project> [--if-repo <repo>]"
  if [ "$(jq --arg p "$proj" '(.projects // {}) | has($p)' "$REGISTRY")" != "true" ]; then
    ok "project /$proj not registered — nothing to remove (no-op)"
    return 3
  fi
  # ── G10a IDENTITY GUARD — never delete another repo's same-basename routes on a guess ───────────
  if [ "$has_if_repo" = 1 ]; then
    local have_repo have_canon want_canon
    have_repo="$(jq -r --arg p "$proj" '(.projects[$p].repo // "")' "$REGISTRY")"
    if [ -z "$have_repo" ]; then
      warn "project /$proj has NO recorded repo (legacy) — refusing --if-repo removal (cannot prove these routes belong to $if_repo); leaving it in place"
      return 4
    fi
    have_canon="$(_canon_repo "$have_repo")"
    want_canon="$(_canon_repo "$if_repo")"
    if [ "$have_canon" != "$want_canon" ]; then
      warn "project /$proj is registered to a DIFFERENT repo ($have_repo) than --if-repo ($if_repo) — refusing removal (a same-basename sibling owns these routes; NOT removing)"
      return 5
    fi
  fi
  local tmp; tmp="$(mktemp)"
  jq --arg p "$proj" 'del(.projects[$p])' "$REGISTRY" > "$tmp" && mv "$tmp" "$REGISTRY"
  ok "removed project /$proj (all apps)"
  gen
  if is_running; then
    "$CADDY_BIN" reload --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1 \
      && ok "Caddy hot-reloaded (routes for /$proj gone)" || warn "reload failed — routes update on next \`up\`"
  fi
}

# health — curl every PROXY upstream and check every STATIC root dir exists. Prints up/down per app;
# exits nonzero if ANY app is down. (Fix 8c-health: the preview skill refuses to hand over a URL when
# an upstream is down — e.g. /bliz/dashboard 502s when its Next.js server isn't up.)
health() {
  local down=0 n=0
  while IFS=$'\t' read -r proj app type target; do
    [ -n "$app" ] || continue
    n=$((n+1))
    if [ "$type" = "proxy" ]; then
      if curl -s -o /dev/null --max-time 3 "http://$target/" 2>/dev/null; then
        ok "/$proj/$app  (proxy $target) — up"
      else
        warn "/$proj/$app  (proxy $target) — DOWN (upstream not answering)"; down=1
      fi
    else
      if [ -d "$target" ]; then
        ok "/$proj/$app  (static $target) — up"
      else
        warn "/$proj/$app  (static $target) — DOWN (root dir missing)"; down=1
      fi
    fi
  done < <(jq -r '(.projects // {}) | to_entries[] | .key as $p | (.value.apps // {}) | to_entries[]
                  | "\($p)\t\(.key)\t\(.value.type)\t\(.value.target)"' "$REGISTRY")
  # Fix 3 — an EMPTY/misregistered registry (ZERO apps) is NOT healthy. Exiting 0 here would let the
  # preview Tier-2 health gate hand over a URL for a registry with nothing behind it. Fail closed.
  [ "$n" -gt 0 ] || die "no apps registered — an empty/misregistered registry is NOT healthy (nothing to serve; refusing to report a live URL)"
  [ "$down" = 0 ] || die "one or more upstreams are DOWN — refusing to report a live URL"
  ok "all upstreams healthy"
}

urls() {
  local base; base="$(jq -r '.public_base' "$REGISTRY")"
  jq -r --arg b "$base" '.projects | to_entries[] | .key as $p | .value.apps | keys[] | "  \($b)/\($p)/\(.)"' "$REGISTRY"
}

funnel() {
  local fport listen; fport="$(jq -r '.funnel_port' "$REGISTRY")"; listen="$(jq -r '.listen' "$REGISTRY")"
  "$TS_BIN" funnel status >/dev/null 2>&1 || warn "tailscale Funnel may not be enabled for this node yet (admin console)"
  if "$TS_BIN" funnel --bg --https="$fport" "http://127.0.0.1:$listen" 2>/tmp/funnel.err; then
    ok "funnel :$fport -> 127.0.0.1:$listen"
  else
    warn "funnel failed — $(tail -1 /tmp/funnel.err 2>/dev/null)"
  fi
  "$TS_BIN" funnel status 2>/dev/null | sed 's/^/    /'
}

funnel_reset(){ "$TS_BIN" funnel reset 2>/dev/null && ok "funnel config cleared" || warn "nothing to reset"; }

status() {
  echo "== routes (funnel :$(jq -r .funnel_port "$REGISTRY") -> caddy 127.0.0.1:$(jq -r .listen "$REGISTRY")) =="
  urls
  echo "== caddy =="; is_running && ok "running (pid $(cat "$PIDFILE"))" || warn "not running"
  echo "== funnel =="; "$TS_BIN" funnel status 2>&1 | sed 's/^/  /' | head -14
}

case "${1:-}" in
  gen) gen;;
  up) up;;
  down) down;;
  add-app) shift; add_app "$@";;
  rm-app) shift; rm_app "$@";;
  remove) shift; remove "$@";;
  health) health;;
  urls) urls;;
  funnel) funnel;;
  funnel-reset) funnel_reset;;
  status) status;;
  *) sed -n '2,40p' "$0";;
esac
