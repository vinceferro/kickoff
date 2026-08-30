#!/usr/bin/env bash
# share-selftest.sh — prove the SHARE flow (Tailscale Funnel, zero-spend public links) WITHOUT ever
# touching real tailscale. It runs share-enable.sh against a FAKE `tailscale` on PATH (a controllable
# stub) and asserts BOTH primary branches + every precondition gate + the exit-code contract.
#
#   bash scripts/share-selftest.sh
#
# HERMETIC + LIVE-SAFE by construction:
#   • the ONLY `tailscale` reachable is the stub in $FIXBIN, prepended to PATH — a real tailscale
#     is never invoked (this box runs a LIVE box-ingress funnel on :443; this suite must not go near it).
#   • the stub RECORDS any mutating subcommand (funnel start/reset/off, set, up, down, …) into a
#     `mutations` file and exits a poison code — so a single non-empty mutations file FAILS the suite.
#     share-enable is read-only (status probes only); this is the proof.
#   • every scenario runs against its OWN mktemp control dir; ONE EXIT trap removes only our OWN dirs.
#
# WHAT IT PROVES (the two branches the plan names + the guardrails):
#   ENABLED      → exit 0, the PUBLIC funnel URL base is surfaced, the reversible teardown line is shown.
#   NOT-ENABLED  → exit 2, the one-command consent turnkey is RELAYED ON STDOUT (never a silent warn).
#   preconditions→ not-installed(4) / not-up(5) / operator-permission(3) / MagicDNS-off(6) / bad-port(1).
#   invariants   → version-robust cap detection (CapMap AND Capabilities), idempotent re-run, and the
#                  hard one: share-enable NEVER mutates tailscale (runtime mutations-file + static grep).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SHARE_SH="$REPO/scripts/share-enable.sh"

# Scrub anything ambient that could steer share-enable off the stub.
unset TS_BIN SHARE_FUNNEL_PORT SHARE_STUB_CTL 2>/dev/null || true

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

# ── the fake `tailscale` (controllable stub) ──────────────────────────────────────────────────────
# Behaviour is driven by files under $SHARE_STUB_CTL:
#   status.json / status.rc / status.err   → what `tailscale status --json` prints / exits / stderrs
#   funnel_status.out / funnel_status.rc   → what `tailscale funnel status` prints / exits
#   calls        (appended: every invocation's argv — the read-only trace)
#   mutations    (appended: ANY mutating subcommand — MUST stay empty; a hit poisons the run)
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
# Prepend the stub to PATH for the WHOLE suite — any default `tailscale` resolution hits the stub,
# never a real one (live-safety belt-and-suspenders on top of the explicit TS_BIN in each run).
export PATH="$FIXBIN:$PATH"

# A fresh control dir seeded with sane defaults (rc 0, empty mutations/err).
mk_ctl() {
  local d; d="$(mk)"
  : > "$d/mutations"; : > "$d/calls"; : > "$d/status.err"
  echo 0 > "$d/status.rc"; echo 0 > "$d/funnel_status.rc"
  : > "$d/funnel_status.out"
  printf '%s' "$d"
}
# JSON fixtures (a fake tailnet host — never a real node).
DNS="share-testbox.tailtest.ts.net"
# REAL-SHAPE fixtures: verified against this box's live `tailscale status --json` (2026-07-10) — the
# funnel cap surfaces as the bare "funnel" AND a URL-form ".../cap/funnel-ports?ports=443,8443,10000",
# NOT the exact ".../cap/funnel" the docs imply. Modeling the REAL shape is what makes this test catch
# a detector that only matched the exact docs string (it would false-negate a genuinely-enabled node).
JSON_ENABLED_CAPMAP="{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"$DNS.\",\"Online\":true,\"CapMap\":{\"funnel\":null,\"https://tailscale.com/cap/funnel-ports?ports=443,8443,10000\":null}}}"
JSON_ENABLED_ARRAY="{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"$DNS.\",\"Online\":true,\"Capabilities\":[\"funnel\",\"https://tailscale.com/cap/funnel-ports?ports=443,8443,10000\"]}}"
JSON_ENABLED_EXACT="{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"$DNS.\",\"Online\":true,\"CapMap\":{\"https://tailscale.com/cap/funnel\":null}}}"
JSON_NOTENABLED="{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"$DNS.\",\"Online\":true,\"CapMap\":{}}}"
JSON_NEEDSLOGIN="{\"BackendState\":\"NeedsLogin\",\"Self\":{}}"
JSON_NOMAGICDNS="{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"\",\"CapMap\":{\"funnel\":null}}}"

# run share-enable against a control dir; sets OUT (stdout+stderr) / ERR (stderr only) / RC.
run_share() {  # $1=CTL  [extra env as "K=V" ...]
  local ctl="$1"; shift
  local errf="$ctl/_stderr"
  OUT="$(env "$@" SHARE_STUB_CTL="$ctl" TS_BIN="$FIXBIN/tailscale" bash "$SHARE_SH" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"
  # a combined view for greps that don't care about the stream
  ALL="$OUT
$ERR"
}
no_mutations() { [ ! -s "$1/mutations" ]; }

echo "▶ share flow self-test — Tailscale Funnel public-link turnkey (G3, zero-spend, STUBBED tailscale)"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(a) ENABLED — funnel cap present ⇒ exit 0, the PUBLIC url is surfaced + teardown shown"
# ══════════════════════════════════════════════════════════════════════════════════════
A="$(mk_ctl)"; printf '%s' "$JSON_ENABLED_CAPMAP" > "$A/status.json"
run_share "$A"
chk "ENABLED: exits 0 (ready to share)" "[ $RC -eq 0 ]"
chk "ENABLED: says ENABLED" "printf '%s' \"\$OUT\" | grep -q 'ENABLED'"
chk "ENABLED: surfaces the PUBLIC funnel url (https://$DNS:8443)" "printf '%s' \"\$OUT\" | grep -qF 'https://$DNS:8443'"
chk "ENABLED: names it PUBLIC / no-tailnet-needed" "printf '%s' \"\$OUT\" | grep -qiE 'public|no tailnet'"
chk "ENABLED: shows the reversible teardown (tailscale funnel --https=8443 off)" "printf '%s' \"\$OUT\" | grep -qF 'tailscale funnel --https=8443 off'"
chk "ENABLED: read-only — NO mutating tailscale call was made" "no_mutations \"$A\""
chk "ENABLED: it DID probe status (the stub was actually exercised)" "grep -q 'status' \"$A/calls\""
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(a2) ENABLED via the OLDER .Self.Capabilities array shape (version-robust detection)"
# ══════════════════════════════════════════════════════════════════════════════════════
A2="$(mk_ctl)"; printf '%s' "$JSON_ENABLED_ARRAY" > "$A2/status.json"
run_share "$A2"
chk "ENABLED(array): exits 0 (Capabilities[] shape also detected)" "[ $RC -eq 0 ]"
chk "ENABLED(array): surfaces the PUBLIC url" "printf '%s' \"\$OUT\" | grep -qF 'https://$DNS:8443'"
chk "ENABLED(array): read-only — no mutation" "no_mutations \"$A2\""
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(a3) ENABLED + a LIVE funnel already running ⇒ its actual URL is surfaced too"
# ══════════════════════════════════════════════════════════════════════════════════════
A3="$(mk_ctl)"; printf '%s' "$JSON_ENABLED_CAPMAP" > "$A3/status.json"
printf '# Funnel on:\nhttps://%s:8443/  (Funnel on)\n|-- proxy http://127.0.0.1:5173\n' "$DNS" > "$A3/funnel_status.out"
run_share "$A3"
chk "ENABLED(live): exits 0" "[ $RC -eq 0 ]"
chk "ENABLED(live): surfaces the currently-LIVE funnel url" "printf '%s' \"\$OUT\" | grep -qiE 'LIVE at: https://$DNS:8443'"
chk "ENABLED(live): read-only — no mutation" "no_mutations \"$A3\""
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(a4) ENABLED with SHARE_FUNNEL_PORT=10000 ⇒ url + teardown reflect the chosen port"
# ══════════════════════════════════════════════════════════════════════════════════════
A4="$(mk_ctl)"; printf '%s' "$JSON_ENABLED_CAPMAP" > "$A4/status.json"
run_share "$A4" SHARE_FUNNEL_PORT=10000
chk "ENABLED(:10000): exits 0" "[ $RC -eq 0 ]"
chk "ENABLED(:10000): url uses port 10000" "printf '%s' \"\$OUT\" | grep -qF 'https://$DNS:10000'"
chk "ENABLED(:10000): teardown uses --https=10000" "printf '%s' \"\$OUT\" | grep -qF 'tailscale funnel --https=10000 off'"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(a5) ENABLED via the exact docs cap-form (…/cap/funnel) ⇒ robust matcher still detects it"
# ══════════════════════════════════════════════════════════════════════════════════════
A5="$(mk_ctl)"; printf '%s' "$JSON_ENABLED_EXACT" > "$A5/status.json"
run_share "$A5"
chk "ENABLED(exact-cap): exits 0 (the startswith matcher covers the docs form too)" "[ $RC -eq 0 ]"
chk "ENABLED(exact-cap): read-only — no mutation" "no_mutations \"$A5\""
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(b) NOT-ENABLED — no funnel cap ⇒ exit 2, the consent turnkey is RELAYED ON STDOUT (not a silent warn)"
# ══════════════════════════════════════════════════════════════════════════════════════
B="$(mk_ctl)"; printf '%s' "$JSON_NOTENABLED" > "$B/status.json"
run_share "$B"
chk "NOT-ENABLED: exits 2 (consent pending — a distinct code, not 0)" "[ $RC -eq 2 ]"
chk "NOT-ENABLED: relays the one-command to enable (tailscale funnel 8443) ON STDOUT" "printf '%s' \"\$OUT\" | grep -qF 'tailscale funnel 8443'"
chk "NOT-ENABLED: explains the CONSENT LINK + human tap" "printf '%s' \"\$OUT\" | grep -qiE 'consent link'"
chk "NOT-ENABLED: points at the tailscale login/consent host" "printf '%s' \"\$OUT\" | grep -qF 'login.tailscale.com'"
chk "NOT-ENABLED: says only the HUMAN can approve (no script/agent, no ACL edit)" "printf '%s' \"\$OUT\" | grep -qiE 'only you|no script|edits no acl'"
chk "NOT-ENABLED: the guidance is on STDOUT, not buried in stderr (never a silent warn)" "printf '%s' \"\$OUT\" | grep -qi 'enable funnel'"
chk "NOT-ENABLED: read-only — it did NOT try to enable funnel itself" "no_mutations \"$B\""
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(c) preconditions — each gate gives the RIGHT next step + its own exit code"
# ══════════════════════════════════════════════════════════════════════════════════════
# not installed: TS_BIN points at a path that does not exist (bypasses the on-PATH stub too)
C1="$(mk_ctl)"
OUT="$(SHARE_STUB_CTL="$C1" TS_BIN="$C1/no-such-tailscale" bash "$SHARE_SH" 2>&1)"; RC=$?
chk "not-installed: exits 4" "[ $RC -eq 4 ]"
chk "not-installed: says how to install + up" "printf '%s' \"\$OUT\" | grep -qiE 'install|tailscale up'"
chk "not-installed: made no stub call at all" "[ ! -s \"$C1/calls\" ]"
# not up (NeedsLogin)
C2="$(mk_ctl)"; printf '%s' "$JSON_NEEDSLOGIN" > "$C2/status.json"
run_share "$C2"
chk "not-up: exits 5" "[ $RC -eq 5 ]"
chk "not-up: tells them to run 'tailscale up'" "printf '%s' \"\$OUT\" | grep -qF 'tailscale up'"
chk "not-up: read-only — no mutation" "no_mutations \"$C2\""
# operator/permission: status --json exits nonzero with an operator error
C3="$(mk_ctl)"; printf '%s' "$JSON_ENABLED_CAPMAP" > "$C3/status.json"
echo 1 > "$C3/status.rc"; printf 'Access denied: this operation requires operator access.\n' > "$C3/status.err"
run_share "$C3"
chk "operator: exits 3" "[ $RC -eq 3 ]"
chk "operator: surfaces the exact one-liner (sudo tailscale set --operator=\$USER)" "printf '%s' \"\$OUT\" | grep -qF 'sudo tailscale set --operator=\$USER'"
chk "operator: did NOT run 'tailscale set' itself (surfaced as guidance only)" "no_mutations \"$C3\""
# MagicDNS off (running + cap present, but no DNSName)
C4="$(mk_ctl)"; printf '%s' "$JSON_NOMAGICDNS" > "$C4/status.json"
run_share "$C4"
chk "magicdns-off: exits 6" "[ $RC -eq 6 ]"
chk "magicdns-off: names MagicDNS (+ HTTPS) as the missing precondition" "printf '%s' \"\$OUT\" | grep -qiE 'magicdns'"
chk "magicdns-off: read-only — no mutation" "no_mutations \"$C4\""
# bad funnel port (guards against printing an unreachable URL) — dies before touching tailscale
C5="$(mk_ctl)"; printf '%s' "$JSON_ENABLED_CAPMAP" > "$C5/status.json"
run_share "$C5" SHARE_FUNNEL_PORT=9999
chk "bad-port: exits 1 (rejected before any URL is surfaced)" "[ $RC -eq 1 ]"
chk "bad-port: names the only valid funnel ports (443/8443/10000)" "printf '%s' \"\$ALL\" | grep -qE '443.*8443.*10000|only .*443'"
# 443 is REFUSED (box-ingress footgun): share-enable must die on it, never warn-and-continue onto a
# 443-targeted funnel teardown/enable command (which would drop the box's live public front door).
C6="$(mk_ctl)"; printf '%s' "$JSON_ENABLED_CAPMAP" > "$C6/status.json"
run_share "$C6" SHARE_FUNNEL_PORT=443
chk "443: REFUSED (die, exit 1) — never warns-and-continues onto 443" "[ $RC -eq 1 ]"
chk "443: steers to the safe ports (8443/10000)" "printf '%s' \"\$ALL\" | grep -qE '8443|10000'"
chk "443: emitted NO 443-targeted funnel command (teardown/enable)" "! printf '%s' \"\$ALL\" | grep -qE 'tailscale funnel (--https=443|443)'"
chk "443: read-only — no mutation (died before any tailscale call)" "no_mutations \"$C6\""
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(d) idempotent — re-running the ENABLED check is stable (same exit, still read-only)"
# ══════════════════════════════════════════════════════════════════════════════════════
D="$(mk_ctl)"; printf '%s' "$JSON_ENABLED_CAPMAP" > "$D/status.json"
run_share "$D"; D_RC1=$RC
run_share "$D"; D_RC2=$RC
chk "idempotent: first run exit 0" "[ $D_RC1 -eq 0 ]"
chk "idempotent: second run exit 0 (no state changed between runs)" "[ $D_RC2 -eq 0 ]"
chk "idempotent: still zero mutations after two runs" "no_mutations \"$D\""
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(e) default on-PATH resolution — with NO TS_BIN set, share-enable finds the stub on PATH"
# ══════════════════════════════════════════════════════════════════════════════════════
# (proves the real-world default `TS_BIN=\$(command -v tailscale)` path, using the stub we put on PATH)
E="$(mk_ctl)"; printf '%s' "$JSON_ENABLED_CAPMAP" > "$E/status.json"
OUT="$(SHARE_STUB_CTL="$E" bash "$SHARE_SH" 2>&1)"; RC=$?
chk "on-PATH: resolves tailscale from PATH (no TS_BIN) ⇒ exit 0" "[ $RC -eq 0 ]"
chk "on-PATH: surfaces the PUBLIC url via the on-PATH stub" "printf '%s' \"\$OUT\" | grep -qF 'https://$DNS:8443'"
chk "on-PATH: read-only — no mutation" "no_mutations \"$E\""
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(f) STATIC live-safety guard — share-enable executes tailscale ONLY via read-only status probes"
# ══════════════════════════════════════════════════════════════════════════════════════
# Every EXECUTION of \$TS_BIN in the source must be a `status` probe. (The teardown/consent commands
# in the output are literal 'tailscale …' strings printed as guidance — NOT \$TS_BIN executions.)
TS_EXEC_TOTAL="$(grep -cE '\$\("\$TS_BIN" ' "$SHARE_SH")"
TS_EXEC_STATUS="$(grep -E '\$\("\$TS_BIN" ' "$SHARE_SH" | grep -c 'status')"
chk "static: >=1 tailscale execution exists (the probe is real)" "[ ${TS_EXEC_TOTAL:-0} -ge 1 ]"
chk "static: EVERY tailscale execution is a read-only 'status' probe ($TS_EXEC_STATUS/$TS_EXEC_TOTAL)" "[ \"$TS_EXEC_TOTAL\" = \"$TS_EXEC_STATUS\" ]"
chk "static: source contains NO executed funnel-start/reset/set (only status)" \
  "! grep -nE '\$\(\"\\\$TS_BIN\" (funnel (--|[0-9]|reset|on|off)|set|up|down|reset)' \"$SHARE_SH\""
echo

echo "──────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "  ✅ share flow holds (both branches + every gate, stubbed — zero real tailscale)"; exit 0; } || { echo "  ❌ see failures above"; exit 1; }
