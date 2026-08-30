#!/usr/bin/env bash
# share-occupancy-selftest.sh — prove the funnel-port OCCUPANCY gate in share-enable.sh, WITHOUT ever
# touching real tailscale (same stubbed-`tailscale` harness as share-selftest.sh).
#
# THE BUG THIS PINS (adopter stress-test, HIGH #5 / Fix 3B). A box has only 3 funnel ports
# (443/8443/10000) and `tailscale serve/funnel` is SET-not-APPEND: re-pointing a mapped port silently
# REPLACES the existing handler — no error, no warning. share-enable.sh hard-defaulted
# SHARE_FUNNEL_PORT=8443 and validated only LEGALITY (443|8443|10000), never OCCUPANCY — so the
# preview skill's share step, green-lit by exit 0, would start a funnel on :8443 and silently darken
# whatever live app already owned it.
#
# THE CONTRACT (post-fix): with the intended upstream declared (SHARE_UPSTREAM=http://127.0.0.1:<p>),
# an occupied target port owned by a DIFFERENT upstream is a HARD-STOP (exit 7) that NAMES the owner
# and steers to a free funnel port — or to box-ingress path-routing when every safe funnel port is
# taken. Same-upstream (our own share already live) and free-port stay exit 0. With NO declared
# upstream, behavior stays exit 0 (share-selftest.sh (a3) compat) but the owner + SET-not-APPEND
# clobber caution is surfaced. All of it read-only — zero mutating tailscale calls.
#
#   bash scripts/share-occupancy-selftest.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SHARE_SH="$REPO/scripts/share-enable.sh"

# Scrub anything ambient that could steer share-enable off the stub.
unset TS_BIN SHARE_FUNNEL_PORT SHARE_STUB_CTL SHARE_UPSTREAM 2>/dev/null || true

command -v jq >/dev/null 2>&1 || { echo "  ❌ jq not found"; exit 1; }

PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

# ONE EXIT trap: clean our OWN mktemp dirs (never a wildcard sweep).
CLEANUP_LIST="$(mktemp)"
mk() { local d; d="$(mktemp -d)"; printf '%s\n' "$d" >> "$CLEANUP_LIST"; printf '%s' "$d"; }
cleanup() { while IFS= read -r _d; do [ -n "$_d" ] && rm -rf "$_d"; done < "$CLEANUP_LIST"; rm -f "$CLEANUP_LIST"; }
trap cleanup EXIT

# ── the fake `tailscale` (same controllable stub as share-selftest.sh) ────────────────────────────
FIXBIN="$(mk)/bin"; mkdir -p "$FIXBIN"
cat > "$FIXBIN/tailscale" <<'STUB'
#!/usr/bin/env bash
ctl="${SHARE_STUB_CTL:?share stub: SHARE_STUB_CTL unset}"
printf '%s\n' "$*" >> "$ctl/calls"
cmd="${1:-}"; shift 2>/dev/null || true
case "$cmd" in
  status)
    [ -s "$ctl/status.err" ] && cat "$ctl/status.err" >&2
    cat "$ctl/status.json" 2>/dev/null
    exit "$(cat "$ctl/status.rc" 2>/dev/null || echo 0)" ;;
  funnel)
    if [ "${1:-}" = "status" ]; then
      cat "$ctl/funnel_status.out" 2>/dev/null
      exit "$(cat "$ctl/funnel_status.rc" 2>/dev/null || echo 0)"
    fi
    printf 'funnel %s\n' "$*" >> "$ctl/mutations"
    echo "STUB-REFUSED mutating: tailscale funnel $*" >&2; exit 97 ;;
  set|up|down|login|logout|serve|reset)
    printf '%s %s\n' "$cmd" "$*" >> "$ctl/mutations"
    echo "STUB-REFUSED mutating: tailscale $cmd $*" >&2; exit 97 ;;
  *)
    echo "STUB unhandled: tailscale $cmd $*" >&2; exit 90 ;;
esac
STUB
chmod +x "$FIXBIN/tailscale"
export PATH="$FIXBIN:$PATH"

mk_ctl() {
  local d; d="$(mk)"
  : > "$d/mutations"; : > "$d/calls"; : > "$d/status.err"
  echo 0 > "$d/status.rc"; echo 0 > "$d/funnel_status.rc"
  : > "$d/funnel_status.out"
  printf '%s' "$d"
}
DNS="share-testbox.tailtest.ts.net"
JSON_ENABLED="{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"$DNS.\",\"Online\":true,\"CapMap\":{\"funnel\":null,\"https://tailscale.com/cap/funnel-ports?ports=443,8443,10000\":null}}}"

# REAL-SHAPE serve tables (`tailscale funnel status` prints the FULL serve table — funnel AND
# tailnet-only blocks; a portless block header is :443). The :443 root block below is deliberate:
# the parser must NOT misattribute the front door's owner to :8443.
TABLE_8443_TAKEN="# Funnel on:
#     - https://$DNS:8443

https://$DNS (Funnel on)
|-- / proxy http://127.0.0.1:3000

https://$DNS:8443 (Funnel on)
|-- / proxy http://127.0.0.1:5173"
TABLE_ALL_TAKEN="$TABLE_8443_TAKEN

https://$DNS:10000 (tailnet only)
|-- / proxy http://127.0.0.1:6000"
TABLE_ROOT_ONLY="https://$DNS (Funnel on)
|-- / proxy http://127.0.0.1:3000"
TABLE_8443_OURS="https://$DNS:8443 (Funnel on)
|-- / proxy http://127.0.0.1:4000"

run_share() {  # $1=CTL  [extra env as "K=V" ...]
  local ctl="$1"; shift
  local errf="$ctl/_stderr"
  OUT="$(env "$@" SHARE_STUB_CTL="$ctl" TS_BIN="$FIXBIN/tailscale" bash "$SHARE_SH" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"
  ALL="$OUT
$ERR"
}
no_mutations() { [ ! -s "$1/mutations" ]; }

echo "▶ share occupancy self-test — SET-not-APPEND clobber gate (Fix 3B, STUBBED tailscale)"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(a) THE CLOBBER: :8443 owned by ANOTHER upstream + our upstream declared ⇒ HARD-STOP exit 7"
# ══════════════════════════════════════════════════════════════════════════════════════
A="$(mk_ctl)"; printf '%s' "$JSON_ENABLED" > "$A/status.json"
printf '%s\n' "$TABLE_8443_TAKEN" > "$A/funnel_status.out"
run_share "$A" SHARE_UPSTREAM=http://127.0.0.1:4000
chk "occupied-by-other: exits 7 (HARD-STOP — never a green-lit clobber)" "[ $RC -eq 7 ]"
chk "occupied-by-other: NAMES the current owner (http://127.0.0.1:5173)" "printf '%s' \"\$ALL\" | grep -qF 'http://127.0.0.1:5173'"
chk "occupied-by-other: explains SET-not-APPEND / silent REPLACE" "printf '%s' \"\$ALL\" | grep -qiE 'replace|set-not-append'"
chk "occupied-by-other: steers to the FREE funnel port (SHARE_FUNNEL_PORT=10000)" "printf '%s' \"\$ALL\" | grep -qF 'SHARE_FUNNEL_PORT=10000'"
chk "occupied-by-other: read-only — no mutating tailscale call" "no_mutations \"$A\""
# (a2) PREFIX-COLLISION: :5173 is a string-PREFIX of an occupant :51730 — a substring compare
# (grep -F :5173) would misread the port as "ours" and green-light the exact SET-not-APPEND clobber
# the gate exists to refuse. Must HARD-STOP 7.
A2="$(mk_ctl)"; printf '%s' "$JSON_ENABLED" > "$A2/status.json"
printf '%s\n' "https://$DNS:8443 (Funnel on)
|-- / proxy http://127.0.0.1:51730" > "$A2/funnel_status.out"
run_share "$A2" SHARE_UPSTREAM=http://127.0.0.1:5173
chk "prefix-collision: exits 7 (owner :51730 is NOT our :5173, despite the prefix)" "[ $RC -eq 7 ]"
chk "prefix-collision: NAMES the true owner (:51730)" "printf '%s' \"\$ALL\" | grep -qF 'http://127.0.0.1:51730'"
chk "prefix-collision: read-only — no mutating tailscale call" "no_mutations \"$A2\""
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(b) ALL safe funnel ports taken ⇒ HARD-STOP steers to box-ingress path-routing, not a clobber"
# ══════════════════════════════════════════════════════════════════════════════════════
B="$(mk_ctl)"; printf '%s' "$JSON_ENABLED" > "$B/status.json"
printf '%s\n' "$TABLE_ALL_TAKEN" > "$B/funnel_status.out"
run_share "$B" SHARE_UPSTREAM=http://127.0.0.1:4000
chk "all-taken: exits 7" "[ $RC -eq 7 ]"
chk "all-taken: steers to box-ingress path-routing (ingress.sh / Tier 2), NOT a free port" "printf '%s' \"\$ALL\" | grep -qiE 'ingress'"
chk "all-taken: does NOT suggest SHARE_FUNNEL_PORT=10000 (it is taken too)" "! printf '%s' \"\$ALL\" | grep -qF 'SHARE_FUNNEL_PORT=10000'"
chk "all-taken: read-only — no mutation" "no_mutations \"$B\""
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(c) SAME upstream already live on the port ⇒ exit 0 (re-checking our own share is not a stop)"
# ══════════════════════════════════════════════════════════════════════════════════════
C="$(mk_ctl)"; printf '%s' "$JSON_ENABLED" > "$C/status.json"
printf '%s\n' "$TABLE_8443_OURS" > "$C/funnel_status.out"
run_share "$C" SHARE_UPSTREAM=http://127.0.0.1:4000
chk "same-upstream: exits 0 (our own live share, idempotent re-check)" "[ $RC -eq 0 ]"
chk "same-upstream: surfaces the LIVE url" "printf '%s' \"\$OUT\" | grep -qiE 'LIVE at: https://$DNS:8443'"
chk "same-upstream: read-only — no mutation" "no_mutations \"$C\""
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(d) target port FREE (only :443 root is mapped) ⇒ exit 0 — the 443 owner is not misattributed"
# ══════════════════════════════════════════════════════════════════════════════════════
D="$(mk_ctl)"; printf '%s' "$JSON_ENABLED" > "$D/status.json"
printf '%s\n' "$TABLE_ROOT_ONLY" > "$D/funnel_status.out"
run_share "$D" SHARE_UPSTREAM=http://127.0.0.1:4000
chk "free-port: exits 0 (:8443 unowned; the :443 block does not shadow it)" "[ $RC -eq 0 ]"
chk "free-port: surfaces the PUBLIC url base" "printf '%s' \"\$OUT\" | grep -qF 'https://$DNS:8443'"
chk "free-port: read-only — no mutation" "no_mutations \"$D\""
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(e) occupied but NO upstream declared ⇒ exit 0 (capability-check compat) + owner CAUTION surfaced"
# ══════════════════════════════════════════════════════════════════════════════════════
E="$(mk_ctl)"; printf '%s' "$JSON_ENABLED" > "$E/status.json"
printf '%s\n' "$TABLE_8443_TAKEN" > "$E/funnel_status.out"
run_share "$E"
chk "no-intent: exits 0 (a pure capability check must not hard-stop on someone else's live share)" "[ $RC -eq 0 ]"
chk "no-intent: still NAMES the port's current owner as a caution" "printf '%s' \"\$ALL\" | grep -qF 'http://127.0.0.1:5173'"
chk "no-intent: warns a new share there REPLACES it (SET-not-APPEND)" "printf '%s' \"\$ALL\" | grep -qiE 'replace'"
chk "no-intent: read-only — no mutation" "no_mutations \"$E\""
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(f) STATIC (Fix 3A) — the preview skill teaches pre-check → explicit-free-port → confirm,"
echo "    NEVER the bare root-mapping serve (which maps :443, the shared box's front door)"
# ══════════════════════════════════════════════════════════════════════════════════════
for SK in "$REPO/.claude/skills/preview/SKILL.md" "$REPO/plugin/skills/preview/SKILL.md"; do
  short="${SK#"$REPO"/}"
  chk "$short: Tier-1 serve is the EXPLICIT free-port form (--https=<free-tailnet-port>)" \
    "grep -qF -- '--https=<free-tailnet-port>' '$SK'"
  chk "$short: mandates the serve-status PRE-CHECK (every listed port is TAKEN — pick one that is NOT)" \
    "grep -qiE 'serve status.*pre-check' '$SK'"
  chk "$short: mandates the post-map CONFIRM (your mapping exists)" \
    "grep -qiE 'confirm YOUR mapping' '$SK'"
  chk "$short: names set-not-append / silent-replace as the reason (mirrors mission-control's wording)" \
    "grep -qi 'set-not-append' '$SK'"
  chk "$short: bare root-mapping form appears ONLY as the named footgun, never as the instruction" \
    "! grep -E 'tailscale serve --bg <port>' '$SK' | grep -viE 'root|darkens|bare' | grep -q ."
  chk "$short: the share step declares intent (SHARE_UPSTREAM=) so the occupancy gate can fire" \
    "grep -qF 'SHARE_UPSTREAM=' '$SK'"
done
chk "preview SKILL copies are BYTE-IDENTICAL (plugin/ vs .claude/ — adopters run the plugin copy)" \
  "cmp -s '$REPO/.claude/skills/preview/SKILL.md' '$REPO/plugin/skills/preview/SKILL.md'"
echo

echo "──────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "  ✅ occupancy gate holds (clobber refused + owner named, stubbed — zero real tailscale)"; exit 0; } || { echo "  ❌ see failures above"; exit 1; }
