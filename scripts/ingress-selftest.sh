#!/usr/bin/env bash
# ingress-selftest.sh — prove the promoted local-serving slice (design §4 / §7.6): box-ingress lifted
# into the pinned engine as a machine-level Caddy singleton, hardened with Fix 8a (auth field), 8b
# (gen()-side reserved-port guard), 8c-bind (loopback listener) + 8c-health (upstream health gate),
# a `remove <project>` teardown, and wired into `kickoff eject`.
#
#   bash scripts/ingress-selftest.sh
#
# Mirrors plugin/pull/eject-selftest.sh (mktemp fixtures + ok/bad/chk, ONE EXIT trap cleaning only our
# OWN named dirs — NEVER a /tmp/tmp.* wildcard sweep). It runs ENTIRELY against SCRATCH INGRESS_DIRs,
# scratch listen ports (19000), and fixture upstreams (python3 http.server on 18081). It NEVER touches
# the live ~/box-ingress (registry/Caddyfile/pitch-deck), NEVER binds :9000/:443/:2019, and NEVER
# starts/reloads/stops the live caddy. A LIVE-SAFETY CANARY (h) proves the live front door is untouched.
#
# It proves, per the design's hardening list:
#   (a) 8a       — an app with an `auth` field → gen emits a basic_auth block with the exact users/hashes.
#   (b) 8b       — a proxy app on a reserved private port → gen REFUSES (nonzero, no Caddyfile written).
#   (c) 8c-bind  — the generated listener is 127.0.0.1:<listen>, never a bare/wildcard :<listen>.
#   (d) 8c-health— a down upstream → health nonzero; all upstreams up → health exit 0.
#   (e) remove   — removes ALL of a project's apps + regens without them; missing project no-ops exit 0.
#   (f) eject    — `kickoff eject --dry-run` (scratch INGRESS_DIR) logs the ingress remove.
#   (g) PRE-FIX  — 8a/8b/8c-bind run against the ORIGINAL ~/box-ingress/ingress.sh copied to scratch and
#                  FAIL there (auth dropped, reserved port emitted, wildcard bind) — the tests catch the bug.
#   (h) CANARY   — the live ~/box-ingress registry+Caddyfile are byte-identical before/after + the live
#                  box-ingress caddy is still alive. Fail loud otherwise.
# Deps: python3 + jq + curl + coreutils (+ caddy for the optional adapt sanity check).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
INGRESS_SH="$REPO/scripts/ingress.sh"
KICKOFF="$REPO/scripts/kickoff"
ORIG_INGRESS="${INGRESS_ORIG_SH:-$HOME/box-ingress/ingress.sh}"   # read-only base, for the pre-fix proof
LIVE_DIR="${INGRESS_LIVE_DIR:-$HOME/box-ingress}"                 # the live singleton, for the canary
UP_PORT="${INGRESS_TEST_UP_PORT:-18081}"                          # fixture upstream port (scratch)
LISTEN="${INGRESS_TEST_LISTEN:-19000}"                            # scratch caddy listen port (never 9000)

# ── self-scrub the ambient instance.env whitelist (robust push-gate) ────────────────────────────────
# This suite builds its OWN hermetic mktemp fixtures — but when it runs INSIDE a kickoff-managed session
# (notably the lefthook pre-push gate), the ambient environment legitimately exports the LIVE repo's
# instance.env whitelist vars (TELEGRAM_STATE_DIR, MEMORY_INDEX, MC_STATE_FILE, …). A preset env var WINS
# over a fixture's instance.env by design, so an unscrubbed run leaks those live channel/data paths into
# the fixtures' preflight/engine calls and false-fails a gate that must pass regardless of the caller's
# env. Unset the whole whitelist (+ its channel/lock siblings) ONCE here — the SAME set reconcile-selftest
# .sh scrubs — BEFORE any fixture setup; the per-fixture env prefixes below intentionally set their own
# values AFTER this and are preserved. (This suite's preflight #2 case already `env -u`'d the channel
# vars inline; the whitelist-unset makes the WHOLE suite robust, not just that one call.)
unset REPO_DIR KICKOFF_CORE_DIR KICKOFF_CORE_REMOTE MC_STATE_FILE MC_TRACKER_FILE \
      MEMORY_DB MEMORY_HOOK_LOG MEMORY_DIR MEMORY_INDEX TELEGRAM_STATE_DIR CHANNEL_SPEC \
      REGROUND_PROMPT PERMISSION_MODE EFFORT MODEL MAX_CONCURRENT_AGENTS DEPLOY_BRANCH \
      CADENCE INSTANCE_ENV LOCKFILE ORIGIN_STATE_DIR OPERATOR_STATE_DIR 2>/dev/null || true

PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "  ❌ python3 not found"; exit 1; }
command -v jq      >/dev/null 2>&1 || { echo "  ❌ jq not found";      exit 1; }
command -v curl    >/dev/null 2>&1 || { echo "  ❌ curl not found";    exit 1; }

# ONE EXIT trap: clean our OWN mktemp dirs (never a wildcard sweep) + kill our fixture upstream.
CLEANUP_LIST="$(mktemp)"
UPSTREAM_PID=""
mk() { local d; d="$(mktemp -d)"; printf '%s\n' "$d" >> "$CLEANUP_LIST"; printf '%s' "$d"; }
cleanup() {
  [ -n "$UPSTREAM_PID" ] && kill "$UPSTREAM_PID" 2>/dev/null
  while IFS= read -r _d; do [ -n "$_d" ] && rm -rf "$_d"; done < "$CLEANUP_LIST"
  rm -f "$CLEANUP_LIST"
}
trap cleanup EXIT

# A FIXTURE bcrypt-shaped hash (never a real credential) — proves gen reproduces it verbatim.
AUTHUSER="deckguest"
AUTHHASH='$2a$14$FIXTUREfixtureFIXTUREfiOe/FIXTUREfixtureFIXTUREfixtureFI'

echo "▶ local-serving self-test (design §4 / §7.6) — Fix 8a/8b/8c + remove + eject"
echo

# ── (h) CANARY — snapshot the LIVE front door BEFORE the suite ─────────────────────────────────────
LIVE_REG="$LIVE_DIR/registry.json"; LIVE_CF="$LIVE_DIR/Caddyfile"
canary_hash() { [ -f "$1" ] && sha256sum "$1" | awk '{print $1}' || printf 'ABSENT'; }
LIVE_REG_BEFORE="$(canary_hash "$LIVE_REG")"
LIVE_CF_BEFORE="$(canary_hash "$LIVE_CF")"
# the live box-ingress caddy pid(s): whatever caddy is serving the live Caddyfile (generic — not a
# hardcoded pid), optionally an explicit INGRESS_CANARY_PID (this box: 141846).
live_caddy_pids() { { pgrep -f "$LIVE_CF" 2>/dev/null; [ -n "${INGRESS_CANARY_PID:-}" ] && echo "$INGRESS_CANARY_PID"; } | sort -u | tr '\n' ' '; }
LIVE_PIDS_BEFORE="$(live_caddy_pids)"

# ── helper: write a scratch registry into an INGRESS_DIR ───────────────────────────────────────────
write_registry() { printf '%s\n' "$2" > "$1/registry.json"; }

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(a) Fix 8a — an \`auth\` field generates a basic_auth block (exact users/hashes)"
# ══════════════════════════════════════════════════════════════════════════════════════
A="$(mk)"
write_registry "$A" "{\"funnel_port\":443,\"listen\":$LISTEN,\"public_base\":\"https://s.ts.net\",\"projects\":{\"deck\":{\"apps\":{\"pitch\":{\"type\":\"proxy\",\"target\":\"127.0.0.1:$UP_PORT\",\"strip_prefix\":false,\"auth\":{\"$AUTHUSER\":\"$AUTHHASH\"}}}}}}"
INGRESS_DIR="$A" bash "$INGRESS_SH" gen >/dev/null 2>&1; A_RC=$?
chk "8a: gen succeeds on an auth app (rc0)" "[ $A_RC -eq 0 ]"
chk "8a: Caddyfile contains a basic_auth block" "grep -q 'basic_auth' \"$A/Caddyfile\""
chk "8a: the exact user is emitted" "grep -qF '$AUTHUSER' \"$A/Caddyfile\""
chk "8a: the exact bcrypt hash is emitted verbatim" "grep -qF '$AUTHHASH' \"$A/Caddyfile\""
# and an app WITHOUT auth emits no basic_auth (no spurious gating)
NA="$(mk)"
write_registry "$NA" "{\"funnel_port\":443,\"listen\":$LISTEN,\"public_base\":\"https://s.ts.net\",\"projects\":{\"deck\":{\"apps\":{\"open\":{\"type\":\"proxy\",\"target\":\"127.0.0.1:$UP_PORT\",\"strip_prefix\":false}}}}}"
INGRESS_DIR="$NA" bash "$INGRESS_SH" gen >/dev/null 2>&1
chk "8a: an app with NO auth field emits NO basic_auth (no spurious gate)" "! grep -q 'basic_auth' \"$NA/Caddyfile\""
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(b) Fix 8b — gen REFUSES a proxy target on a reserved private port (nonzero, no Caddyfile)"
# ══════════════════════════════════════════════════════════════════════════════════════
B="$(mk)"
write_registry "$B" "{\"funnel_port\":443,\"listen\":$LISTEN,\"public_base\":\"https://s.ts.net\",\"projects\":{\"mc\":{\"apps\":{\"leak\":{\"type\":\"proxy\",\"target\":\"127.0.0.1:9100\",\"strip_prefix\":false}}}}}"
rm -f "$B/Caddyfile"
INGRESS_DIR="$B" bash "$INGRESS_SH" gen >/dev/null 2>&1; B_RC=$?
chk "8b: gen exits NONZERO on a reserved-port (:9100) proxy target" "[ $B_RC -ne 0 ]"
chk "8b: NO Caddyfile was written (refused before write)" "[ ! -f \"$B/Caddyfile\" ]"
# Fix 1 — :9200 (this box's kickoff Mission Control board) is now in the DEFAULT reserved set, so a
# proxy target on it is refused with NO override needed (MC is never a legitimate public app).
B2="$(mk)"
write_registry "$B2" "{\"funnel_port\":443,\"listen\":$LISTEN,\"public_base\":\"https://s.ts.net\",\"projects\":{\"mc\":{\"apps\":{\"leak\":{\"type\":\"proxy\",\"target\":\"127.0.0.1:9200\",\"strip_prefix\":false}}}}}"
rm -f "$B2/Caddyfile"
INGRESS_DIR="$B2" bash "$INGRESS_SH" gen >/dev/null 2>&1; B2_RC=$?
chk "8b/Fix1: :9200 (kickoff MC board) is refused BY DEFAULT — no INGRESS_RESERVED_PORTS override" "[ $B2_RC -ne 0 ]"
chk "8b/Fix1: the :9200-refused gen wrote NO Caddyfile" "[ ! -f \"$B2/Caddyfile\" ]"
# the override STILL works — a DIFFERENT port (:9300) is NOT reserved by default (generates cleanly),
# but IS refused once it is named in INGRESS_RESERVED_PORTS.
B2B="$(mk)"
write_registry "$B2B" "{\"funnel_port\":443,\"listen\":$LISTEN,\"public_base\":\"https://s.ts.net\",\"projects\":{\"mc\":{\"apps\":{\"leak\":{\"type\":\"proxy\",\"target\":\"127.0.0.1:9300\",\"strip_prefix\":false}}}}}"
INGRESS_DIR="$B2B" bash "$INGRESS_SH" gen >/dev/null 2>&1; B2B_DEF_RC=$?
chk "8b/Fix1: :9300 is NOT reserved by default (generates cleanly)" "[ $B2B_DEF_RC -eq 0 ]"
rm -f "$B2B/Caddyfile"
INGRESS_DIR="$B2B" INGRESS_RESERVED_PORTS="9300" bash "$INGRESS_SH" gen >/dev/null 2>&1; B2B_RC=$?
chk "8b: INGRESS_RESERVED_PORTS override still works (:9300 refused only when listed)" "[ $B2B_RC -ne 0 ]"
# a clean registry (no reserved port) still generates fine
B3="$(mk)"
write_registry "$B3" "{\"funnel_port\":443,\"listen\":$LISTEN,\"public_base\":\"https://s.ts.net\",\"projects\":{\"app\":{\"apps\":{\"web\":{\"type\":\"proxy\",\"target\":\"127.0.0.1:$UP_PORT\",\"strip_prefix\":false}}}}}"
INGRESS_DIR="$B3" bash "$INGRESS_SH" gen >/dev/null 2>&1
chk "8b: a non-reserved target still generates cleanly" "[ -f \"$B3/Caddyfile\" ]"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(b2) Fix 2 — gen FAIL-CLOSED drop-guard: never silently drop a HAND-EDITED route"
# ══════════════════════════════════════════════════════════════════════════════════════
# (i) an EXISTING Caddyfile carrying a hand-added @custom route absent from the registry ⇒ gen REFUSES
#     (nonzero, existing Caddyfile BYTE-UNCHANGED, message names @custom). @custom is line-level added
#     (the guard scans matcher lines, not block nesting) with the pitch-deck shape: name ≠ its path.
DG="$(mk)"
write_registry "$DG" "{\"funnel_port\":443,\"listen\":$LISTEN,\"public_base\":\"https://s.ts.net\",\"projects\":{\"proj\":{\"apps\":{\"web\":{\"type\":\"proxy\",\"target\":\"127.0.0.1:$UP_PORT\",\"strip_prefix\":false}}}}}"
INGRESS_DIR="$DG" bash "$INGRESS_SH" gen >/dev/null 2>&1          # first gen — writes @proj_web
printf '    @custom path /custom-handedited\n    handle @custom {\n        respond "hi" 200\n    }\n' >> "$DG/Caddyfile"
DG_SHA_BEFORE="$(sha256sum "$DG/Caddyfile" | awk '{print $1}')"
DG_OUT="$(INGRESS_DIR="$DG" bash "$INGRESS_SH" gen 2>&1)"; DG_RC=$?
DG_SHA_AFTER="$(sha256sum "$DG/Caddyfile" | awk '{print $1}')"
chk "2/i: gen REFUSES when a hand-edited route (@custom) would be dropped (nonzero)" "[ $DG_RC -ne 0 ]"
chk "2/i: the refused gen NAMES the dropped matcher (@custom)" "printf '%s' \"\$DG_OUT\" | grep -qF '@custom'"
chk "2/i: the existing Caddyfile is left BYTE-UNCHANGED by the refused gen" "[ \"$DG_SHA_BEFORE\" = \"$DG_SHA_AFTER\" ]"
# (ii) INGRESS_ALLOW_DROP=1 ⇒ gen PROCEEDS and overwrites (the @custom hand-edit is dropped, as asked).
INGRESS_DIR="$DG" INGRESS_ALLOW_DROP=1 bash "$INGRESS_SH" gen >/dev/null 2>&1; DG2_RC=$?
chk "2/ii: INGRESS_ALLOW_DROP=1 overrides the guard (gen proceeds, rc0)" "[ $DG2_RC -eq 0 ]"
chk "2/ii: the overridden gen actually dropped @custom (back to a registry-only Caddyfile)" "! grep -qF '@custom' \"$DG/Caddyfile\""
# (iii-a) a clean RE-GEN of a registry-only Caddyfile (no hand-edits) is UNAFFECTED — zero drops.
DGN="$(mk)"
write_registry "$DGN" "{\"funnel_port\":443,\"listen\":$LISTEN,\"public_base\":\"https://s.ts.net\",\"projects\":{\"proj\":{\"apps\":{\"web\":{\"type\":\"proxy\",\"target\":\"127.0.0.1:$UP_PORT\",\"strip_prefix\":false},\"ui\":{\"type\":\"static\",\"target\":\"$DGN\",\"strip_prefix\":true}}}}}"
INGRESS_DIR="$DGN" bash "$INGRESS_SH" gen >/dev/null 2>&1             # first gen (writes the file)
INGRESS_DIR="$DGN" bash "$INGRESS_SH" gen >/dev/null 2>&1; DGN_RC=$?  # re-gen over the existing file
chk "2/iii: a clean re-gen of a registry-only Caddyfile is UNAFFECTED (rc0, NO false-fire)" "[ $DGN_RC -eq 0 ]"
# (iii-b) the FIRST gen (no existing Caddyfile) is a clean no-op for the guard.
DGF="$(mk)"
write_registry "$DGF" "{\"funnel_port\":443,\"listen\":$LISTEN,\"public_base\":\"https://s.ts.net\",\"projects\":{\"proj\":{\"apps\":{\"web\":{\"type\":\"proxy\",\"target\":\"127.0.0.1:$UP_PORT\",\"strip_prefix\":false}}}}}"
rm -f "$DGF/Caddyfile"
INGRESS_DIR="$DGF" bash "$INGRESS_SH" gen >/dev/null 2>&1; DGF_RC=$?
chk "2/iii: the FIRST gen (no existing Caddyfile) is a clean no-op (rc0, file written)" "[ $DGF_RC -eq 0 ] && [ -f \"$DGF/Caddyfile\" ]"
# (iv) remove <project> over a pre-existing (hand-edit-free) Caddyfile STILL succeeds — the removed
#      project's own @gone_web is a self-consistent app-matcher, so the guard does NOT false-fire on
#      it (proves the guard targets HAND-EDITS, not registry-driven removals).
DGR="$(mk)"
write_registry "$DGR" "{\"funnel_port\":443,\"listen\":$LISTEN,\"public_base\":\"https://s.ts.net\",\"projects\":{\"gone\":{\"apps\":{\"web\":{\"type\":\"proxy\",\"target\":\"127.0.0.1:$UP_PORT\",\"strip_prefix\":false}}},\"stay\":{\"apps\":{\"web\":{\"type\":\"static\",\"target\":\"$DGR\",\"strip_prefix\":true}}}}}"
INGRESS_DIR="$DGR" bash "$INGRESS_SH" gen >/dev/null 2>&1             # pre-existing Caddyfile (both projects)
INGRESS_DIR="$DGR" bash "$INGRESS_SH" remove gone >/dev/null 2>&1; DGR_RC=$?
chk "2/iv: remove over a pre-existing (hand-edit-free) Caddyfile succeeds — NO false-fire on the removed app" "[ $DGR_RC -eq 0 ]"
chk "2/iv: the removed project's route is gone; the sibling's remains" "! grep -q '/gone/' \"$DGR/Caddyfile\" && grep -q '/stay/web' \"$DGR/Caddyfile\""
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(c) Fix 8c-bind — the listener is 127.0.0.1:<listen>, never a wildcard/bare :<listen>"
# ══════════════════════════════════════════════════════════════════════════════════════
C="$(mk)"
write_registry "$C" "{\"funnel_port\":443,\"listen\":$LISTEN,\"public_base\":\"https://s.ts.net\",\"projects\":{\"app\":{\"apps\":{\"web\":{\"type\":\"static\",\"target\":\"$C\",\"strip_prefix\":true}}}}}"
INGRESS_DIR="$C" bash "$INGRESS_SH" gen >/dev/null 2>&1
chk "8c-bind: Caddyfile binds 127.0.0.1:$LISTEN (loopback)" "grep -q '127.0.0.1:$LISTEN' \"$C/Caddyfile\""
chk "8c-bind: NO wildcard/bare :$LISTEN site address" "! grep -qE '(^|[[:space:]]|\\*):$LISTEN' \"$C/Caddyfile\""
# optional: if caddy is present, the generated Caddyfile ADAPTS clean (no port binding by adapt)
if command -v caddy >/dev/null 2>&1; then
  chk "8c-bind: caddy adapt validates the generated Caddyfile (no bind)" \
    "caddy adapt --config \"$C/Caddyfile\" --adapter caddyfile"
fi
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(d) Fix 8c-health — down upstream ⇒ nonzero; all up ⇒ exit 0"
# ══════════════════════════════════════════════════════════════════════════════════════
# DOWN: a proxy target on a dead port + no listener.
D="$(mk)"
DEAD_PORT=65533
write_registry "$D" "{\"funnel_port\":443,\"listen\":$LISTEN,\"public_base\":\"https://s.ts.net\",\"projects\":{\"app\":{\"apps\":{\"api\":{\"type\":\"proxy\",\"target\":\"127.0.0.1:$DEAD_PORT\",\"strip_prefix\":true}}}}}"
D_OUT="$(INGRESS_DIR="$D" bash "$INGRESS_SH" health 2>&1)"; D_RC=$?
chk "8c-health: a down upstream ⇒ health exits NONZERO" "[ $D_RC -ne 0 ]"
chk "8c-health: the down app is named in the output" "printf '%s' \"\$D_OUT\" | grep -qi 'DOWN'"
# UP: start a fixture upstream + a static app whose root exists.
STATICROOT="$(mk)"; printf 'hi\n' > "$STATICROOT/index.html"
python3 -m http.server "$UP_PORT" --bind 127.0.0.1 --directory "$STATICROOT" >/dev/null 2>&1 &
UPSTREAM_PID=$!
# wait for the upstream to answer (bounded)
for _ in $(seq 1 30); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$UP_PORT/" && break; sleep 0.2; done
U="$(mk)"
write_registry "$U" "{\"funnel_port\":443,\"listen\":$LISTEN,\"public_base\":\"https://s.ts.net\",\"projects\":{\"app\":{\"apps\":{\"api\":{\"type\":\"proxy\",\"target\":\"127.0.0.1:$UP_PORT\",\"strip_prefix\":true},\"web\":{\"type\":\"static\",\"target\":\"$STATICROOT\",\"strip_prefix\":true}}}}}"
U_OUT="$(INGRESS_DIR="$U" bash "$INGRESS_SH" health 2>&1)"; U_RC=$?
chk "8c-health: all upstreams up (proxy answering + static root exists) ⇒ health exit 0" "[ $U_RC -eq 0 ]"
chk "8c-health: reports the healthy proxy up" "printf '%s' \"\$U_OUT\" | grep -qi 'up'"
kill "$UPSTREAM_PID" 2>/dev/null; UPSTREAM_PID=""
# Fix 3 — an EMPTY registry (zero apps) is NOT healthy: never hand a URL over for an empty registry.
EMP="$(mk)"
write_registry "$EMP" "{\"funnel_port\":443,\"listen\":$LISTEN,\"public_base\":\"https://s.ts.net\",\"projects\":{}}"
EMP_OUT="$(INGRESS_DIR="$EMP" bash "$INGRESS_SH" health 2>&1)"; EMP_RC=$?
chk "8c-health/Fix3: an EMPTY registry (zero apps) ⇒ health exits NONZERO" "[ $EMP_RC -ne 0 ]"
chk "8c-health/Fix3: the empty-registry health says 'no apps'" "printf '%s' \"\$EMP_OUT\" | grep -qi 'no apps'"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(e) remove <project> — drops all of a project's apps + regens; missing project no-ops exit 0"
# ══════════════════════════════════════════════════════════════════════════════════════
E="$(mk)"
write_registry "$E" "{\"funnel_port\":443,\"listen\":$LISTEN,\"public_base\":\"https://s.ts.net\",\"projects\":{\"demo\":{\"apps\":{\"api\":{\"type\":\"proxy\",\"target\":\"127.0.0.1:$UP_PORT\",\"strip_prefix\":true},\"web\":{\"type\":\"static\",\"target\":\"$E\",\"strip_prefix\":true}}},\"other\":{\"apps\":{\"site\":{\"type\":\"static\",\"target\":\"$E\",\"strip_prefix\":true}}}}}"
INGRESS_DIR="$E" bash "$INGRESS_SH" remove demo >/dev/null 2>&1; E_RC=$?
chk "remove: exits 0" "[ $E_RC -eq 0 ]"
chk "remove: project 'demo' is gone from the registry" "! jq -e '.projects.demo' \"$E/registry.json\" >/dev/null 2>&1"
chk "remove: sibling project 'other' is PRESERVED" "jq -e '.projects.other.apps.site' \"$E/registry.json\" >/dev/null"
chk "remove: regenerated Caddyfile has NO /demo/ routes" "! grep -q '/demo/' \"$E/Caddyfile\""
chk "remove: regenerated Caddyfile KEEPS the /other/ route" "grep -q '/other/site' \"$E/Caddyfile\""
# missing project → NOT-REGISTERED (rc3, distinct no-op — G10a), registry unchanged
E_SHA_BEFORE="$(sha256sum "$E/registry.json" | awk '{print $1}')"
INGRESS_DIR="$E" bash "$INGRESS_SH" remove nonesuch >/dev/null 2>&1; E2_RC=$?
E_SHA_AFTER="$(sha256sum "$E/registry.json" | awk '{print $1}')"
chk "remove: a non-existent project is NOT-REGISTERED (rc3, distinct no-op — G10a)" "[ $E2_RC -eq 3 ]"
chk "remove: a no-op leaves the registry byte-unchanged" "[ \"$E_SHA_BEFORE\" = \"$E_SHA_AFTER\" ]"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(f) eject — \`kickoff eject --dry-run\` (scratch INGRESS_DIR) logs the ingress remove"
# ══════════════════════════════════════════════════════════════════════════════════════
FADOPT="$(mk)/myproj"; FING="$(mk)"
mkdir -p "$FADOPT/.kickoff"
git -C "$FADOPT" init -q; git -C "$FADOPT" config user.email t@t.t; git -C "$FADOPT" config user.name t
printf '{"schema_version":2,"entries":[],"machine_entries":[]}\n' > "$FADOPT/.kickoff/adopt-manifest.json"
write_registry "$FING" "{\"funnel_port\":443,\"listen\":$LISTEN,\"public_base\":\"https://s.ts.net\",\"projects\":{\"myproj\":{\"apps\":{\"web\":{\"type\":\"proxy\",\"target\":\"127.0.0.1:$UP_PORT\",\"strip_prefix\":false}}}}}"
git -C "$FADOPT" add -A; git -C "$FADOPT" commit -qm base
F_OUT="$(INGRESS_DIR="$FING" KICKOFF_CORE_DIR="$(mk)/nocore" bash "$KICKOFF" eject --dir "$FADOPT" --dry-run 2>&1)"
chk "eject: dry-run logs the ingress remove for the project (basename=myproj)" \
  "printf '%s' \"\$F_OUT\" | grep -qE 'would run: ingress.sh remove myproj'"
chk "eject: dry-run names it machine-level / no repo footprint" \
  "printf '%s' \"\$F_OUT\" | grep -qi 'no repo footprint'"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(f2) Fix 2b — eject CONTINUES when \`ingress.sh remove\` fails-closed (drop-guard)"
# ══════════════════════════════════════════════════════════════════════════════════════
# A NON-dry-run eject whose ingress remove hits the Fix 2 drop-guard (a hand-edited Caddyfile route
# absent from the registry) must NOT abort — it logs the skip + how to finish it, and completes the
# rest of the teardown. ENTIRELY scratch: a scratch adopter repo + a scratch INGRESS_DIR.
F2ADOPT="$(mk)/dropproj"; F2ING="$(mk)"
mkdir -p "$F2ADOPT/.kickoff"
git -C "$F2ADOPT" init -q; git -C "$F2ADOPT" config user.email t@t.t; git -C "$F2ADOPT" config user.name t
printf '{"schema_version":2,"entries":[],"machine_entries":[]}\n' > "$F2ADOPT/.kickoff/adopt-manifest.json"
git -C "$F2ADOPT" add -A; git -C "$F2ADOPT" commit -qm base
F2ADOPT_REAL="$(cd "$F2ADOPT" && pwd -P)"
# registry names the project (basename=dropproj) WITH a repo field == this adopter (G10a) so eject's
# --if-repo identity guard PASSES and remove proceeds into the Fix-2 drop-guard; then gen writes its
# Caddyfile and we hand-edit a foreign @custom route in (the route regen would drop).
write_registry "$F2ING" "{\"funnel_port\":443,\"listen\":$LISTEN,\"public_base\":\"https://s.ts.net\",\"projects\":{\"dropproj\":{\"repo\":\"$F2ADOPT_REAL\",\"apps\":{\"web\":{\"type\":\"proxy\",\"target\":\"127.0.0.1:$UP_PORT\",\"strip_prefix\":false}}}}}"
INGRESS_DIR="$F2ING" bash "$INGRESS_SH" gen >/dev/null 2>&1
printf '    @custom path /custom-handedited\n    handle @custom {\n        respond "hi" 200\n    }\n' >> "$F2ING/Caddyfile"
F2_CF_BEFORE="$(sha256sum "$F2ING/Caddyfile" | awk '{print $1}')"
F2_OUT="$(INGRESS_DIR="$F2ING" KICKOFF_CORE_DIR="$(mk)/nocore" bash "$KICKOFF" eject --dir "$F2ADOPT" --no-archive 2>&1)"; F2_RC=$?
F2_CF_AFTER="$(sha256sum "$F2ING/Caddyfile" | awk '{print $1}')"
chk "eject 2b: a drop-guard failure in the ingress remove does NOT abort eject (exit 0)" "[ $F2_RC -eq 0 ]"
chk "eject 2b: eject logs the ingress de-integration SKIP + how to finish it (INGRESS_ALLOW_DROP)" "printf '%s' \"\$F2_OUT\" | grep -qi 'INGRESS_ALLOW_DROP'"
chk "eject 2b: the hand-edited @custom route is UNTOUCHED (refused gen left the Caddyfile byte-unchanged)" "[ \"$F2_CF_BEFORE\" = \"$F2_CF_AFTER\" ]"
chk "eject 2b: eject still completed its own teardown (.kickoff removed)" "[ ! -d \"$F2ADOPT/.kickoff\" ]"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(i) G10a — ingress teardown is IDENTITY-GUARDED: never delete a same-basename sibling's routes"
# ══════════════════════════════════════════════════════════════════════════════════════
# a minimal adopter repo (git + empty manifest) at $1 (basename is deliberately NOT an identity)
mk_adopter() {
  mkdir -p "$1/.kickoff"
  git -C "$1" init -q; git -C "$1" config user.email t@t.t; git -C "$1" config user.name t
  printf '{"schema_version":2,"entries":[],"machine_entries":[]}\n' > "$1/.kickoff/adopt-manifest.json"
  git -C "$1" add -A; git -C "$1" commit -qm base >/dev/null 2>&1
}
# add_app STAMPS a per-project repo field when $INGRESS_REPO is set; absent → legacy (no field).
IREPO="$(mk)/served"; mk_adopter "$IREPO"; IREPOr="$(cd "$IREPO" && pwd -P)"
IAD="$(mk)"; write_registry "$IAD" "{\"funnel_port\":443,\"listen\":$LISTEN,\"public_base\":\"https://s.ts.net\",\"projects\":{}}"
INGRESS_REPO="$IREPO" CADDY_BIN=true INGRESS_DIR="$IAD" bash "$INGRESS_SH" add-app served web static "$IAD" >/dev/null 2>&1
chk "add_app: \$INGRESS_REPO stamps the canonical per-project repo field" "[ \"\$(jq -r '.projects.served.repo' \"$IAD/registry.json\")\" = \"$IREPOr\" ]"
ILEG="$(mk)"; write_registry "$ILEG" "{\"funnel_port\":443,\"listen\":$LISTEN,\"public_base\":\"https://s.ts.net\",\"projects\":{}}"
CADDY_BIN=true INGRESS_DIR="$ILEG" bash "$INGRESS_SH" add-app served web static "$ILEG" >/dev/null 2>&1
chk "add_app: NO \$INGRESS_REPO → NO repo field (legacy-compatible)" "! jq -e '.projects.served.repo' \"$ILEG/registry.json\" >/dev/null 2>&1"

# two SAME-basename adopters: W (the ejector) and C (the OWNER of ingress project 'app')
WROOT="$(mk)/work";    mkdir -p "$WROOT"; GW="$WROOT/app"; mk_adopter "$GW"; GWr="$(cd "$GW" && pwd -P)"
CROOT="$(mk)/clients"; mkdir -p "$CROOT"; GC="$CROOT/app"; mk_adopter "$GC"; GCr="$(cd "$GC" && pwd -P)"
GING="$(mk)"; write_registry "$GING" "{\"funnel_port\":443,\"listen\":$LISTEN,\"public_base\":\"https://s.ts.net\",\"projects\":{\"app\":{\"repo\":\"$GCr\",\"apps\":{\"web\":{\"type\":\"proxy\",\"target\":\"127.0.0.1:$UP_PORT\",\"strip_prefix\":false}}}}}"
# eject W (basename app) must NOT touch C's /app routes
GOUT="$(INGRESS_DIR="$GING" KICKOFF_CORE_DIR="$(mk)/nocore" CADDY_BIN=true bash "$KICKOFF" eject --dir "$GW" --no-archive 2>&1)"; GRC=$?
chk "G10a: eject of the NON-owner PRESERVES the same-basename sibling's /app routes" "jq -e '.projects.app' \"$GING/registry.json\" >/dev/null"
chk "G10a: eject did NOT log a false 'removed project /app'" "! printf '%s' \"\$GOUT\" | grep -q 'removed project /app'"
chk "G10a: eject logged an HONEST mismatch/skip (a sibling owns it)" "printf '%s' \"\$GOUT\" | grep -qiE 'different repo|same-basename|NOT removing|leaving'"
chk "G10a: eject of the non-owner still completed (its .kickoff gone, rc0)" "[ $GRC -eq 0 ] && [ ! -d \"$GW/.kickoff\" ]"
# eject C (the true owner) DOES remove /app
GOUT2="$(INGRESS_DIR="$GING" KICKOFF_CORE_DIR="$(mk)/nocore" CADDY_BIN=true bash "$KICKOFF" eject --dir "$GC" --no-archive 2>&1)"
chk "G10a: eject of the OWNER removes /app (identity-proven)" "! jq -e '.projects.app' \"$GING/registry.json\" >/dev/null 2>&1"
chk "G10a: eject of the owner logs the identity-proven removal" "printf '%s' \"\$GOUT2\" | grep -qi 'removed project /app'"
# remove --if-repo exit-code contract: removed=0 / not-registered=3 / legacy=4 / mismatch=5
UING="$(mk)"; write_registry "$UING" "{\"funnel_port\":443,\"listen\":$LISTEN,\"public_base\":\"https://s.ts.net\",\"projects\":{\"app\":{\"repo\":\"$GCr\",\"apps\":{\"web\":{\"type\":\"proxy\",\"target\":\"127.0.0.1:$UP_PORT\",\"strip_prefix\":false}}}}}"
INGRESS_DIR="$UING" CADDY_BIN=true bash "$INGRESS_SH" remove app --if-repo "$GWr" >/dev/null 2>&1; MRC=$?
chk "remove --if-repo MISMATCH → rc5 + registry unchanged" "[ $MRC -eq 5 ] && jq -e '.projects.app' \"$UING/registry.json\" >/dev/null"
INGRESS_DIR="$UING" CADDY_BIN=true bash "$INGRESS_SH" remove nope --if-repo "$GWr" >/dev/null 2>&1; NRC=$?
chk "remove --if-repo NOT-REGISTERED → rc3" "[ $NRC -eq 3 ]"
LING="$(mk)"; write_registry "$LING" "{\"funnel_port\":443,\"listen\":$LISTEN,\"public_base\":\"https://s.ts.net\",\"projects\":{\"leg\":{\"apps\":{\"web\":{\"type\":\"proxy\",\"target\":\"127.0.0.1:$UP_PORT\",\"strip_prefix\":false}}}}}"
INGRESS_DIR="$LING" CADDY_BIN=true bash "$INGRESS_SH" remove leg --if-repo "$GWr" >/dev/null 2>&1; LRC=$?
chk "remove --if-repo LEGACY-no-repo → rc4 + registry unchanged (never guess-delete)" "[ $LRC -eq 4 ] && jq -e '.projects.leg' \"$LING/registry.json\" >/dev/null"
INGRESS_DIR="$UING" CADDY_BIN=true bash "$INGRESS_SH" remove app --if-repo "$GCr" >/dev/null 2>&1; OKRC=$?
chk "remove --if-repo MATCH → rc0 + project removed" "[ $OKRC -eq 0 ] && ! jq -e '.projects.app' \"$UING/registry.json\" >/dev/null 2>&1"
# PRE-FIX contrast: PLAIN remove (no --if-repo) still deletes unconditionally — the guard is what protects
PING="$(mk)"; write_registry "$PING" "{\"funnel_port\":443,\"listen\":$LISTEN,\"public_base\":\"https://s.ts.net\",\"projects\":{\"app\":{\"repo\":\"$GCr\",\"apps\":{\"web\":{\"type\":\"proxy\",\"target\":\"127.0.0.1:$UP_PORT\",\"strip_prefix\":false}}}}}"
INGRESS_DIR="$PING" CADDY_BIN=true bash "$INGRESS_SH" remove app >/dev/null 2>&1; PRC=$?
chk "PRE-FIX contrast: PLAIN remove (no --if-repo) deletes unconditionally (guard is opt-in via eject)" "[ $PRC -eq 0 ] && ! jq -e '.projects.app' \"$PING/registry.json\" >/dev/null 2>&1"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(j) G10b — channel-clash guard: registry-backed adopters-channel-clash + preflight #2 + MERGE"
# ══════════════════════════════════════════════════════════════════════════════════════
AM="$REPO/scripts/adopt-manifest.py"; PREF="$REPO/scripts/preflight.sh"
JW="$(mk)"; JA="$JW/a"; JB="$JW/b"; mkdir -p "$JA" "$JB"; JAr="$(cd "$JA" && pwd -P)"; JBr="$(cd "$JB" && pwd -P)"
JCH="$(mk)/chan"; mkdir -p "$JCH"; JCHr="$(cd "$JCH" && pwd -P)"
JOTH="$(mk)/other"; mkdir -p "$JOTH"
JREG="$JW/reg.json"
KICKOFF_ADOPTERS_REGISTRY="$JREG" python3 "$AM" adopters-register --repo "$JA" --tag core-vA --version-dir "$JA" --channel "$JCH"  >/dev/null 2>&1
KICKOFF_ADOPTERS_REGISTRY="$JREG" python3 "$AM" adopters-register --repo "$JB" --tag core-vB --version-dir "$JB" --channel "$JCH/" >/dev/null 2>&1
JCL="$(KICKOFF_ADOPTERS_REGISTRY="$JREG" python3 "$AM" adopters-channel-clash --repo "$JA" 2>/dev/null || true)"
chk "clash: two rows on the SAME canonical channel → prints the OTHER repo (B)" "printf '%s' \"\$JCL\" | grep -qxF \"$JBr\""
chk "clash: does NOT print self (A)" "! printf '%s' \"\$JCL\" | grep -qxF \"$JAr\""
# MERGE: re-register A WITHOUT --channel preserves the stored channel (+ updates the tag)
KICKOFF_ADOPTERS_REGISTRY="$JREG" python3 "$AM" adopters-register --repo "$JA" --tag core-vA2 --version-dir "$JA" >/dev/null 2>&1
chk "merge: re-register WITHOUT --channel PRESERVES the stored channel" "[ \"\$(python3 -c \"import json,os;print([x for x in json.load(open('$JREG'))['adopters'] if os.path.realpath(x['repo'])==os.path.realpath('$JA')][0].get('channel',''))\")\" = \"$JCHr\" ]"
# DIFFERENT channel → no clash
JREG2="$JW/reg2.json"
KICKOFF_ADOPTERS_REGISTRY="$JREG2" python3 "$AM" adopters-register --repo "$JA" --tag core-vA --version-dir "$JA" --channel "$JCH"  >/dev/null 2>&1
KICKOFF_ADOPTERS_REGISTRY="$JREG2" python3 "$AM" adopters-register --repo "$JB" --tag core-vB --version-dir "$JB" --channel "$JOTH" >/dev/null 2>&1
JCLD="$(KICKOFF_ADOPTERS_REGISTRY="$JREG2" python3 "$AM" adopters-channel-clash --repo "$JA" 2>/dev/null || true)"
chk "clash: DIFFERENT channels → empty output (no clash)" "[ -z \"$JCLD\" ]"
# preflight #2 FAILs on a positive registry clash; scrub the ambient live channel so the fixture's wins
JPA="$(mk)"; mkdir -p "$JPA/.kickoff/memory"
printf 'export TELEGRAM_STATE_DIR="%s"\n' "$JCHr" > "$JPA/.kickoff/instance.env"; printf '# m\n' > "$JPA/.kickoff/memory/MEMORY.md"
JREG3="$JW/reg3.json"
KICKOFF_ADOPTERS_REGISTRY="$JREG3" python3 "$AM" adopters-register --repo "$JB" --tag core-vSIB --version-dir "$JB" --channel "$JCH" >/dev/null 2>&1
JPFO="$(env -u TELEGRAM_STATE_DIR -u ORIGIN_STATE_DIR -u OPERATOR_STATE_DIR REPO_DIR="$JPA" KICKOFF_ADOPTERS_REGISTRY="$JREG3" bash "$PREF" 2>&1 || true)"
chk "preflight #2: a registry channel clash is a [FAIL]" "printf '%s' \"\$JPFO\" | grep -iE '\\[FAIL\\].*channel'"
KICKOFF_ADOPTERS_REGISTRY="$JREG3" python3 "$AM" adopters-register --repo "$JB" --tag core-vSIB --version-dir "$JB" --channel "$JOTH" >/dev/null 2>&1
JPFO2="$(env -u TELEGRAM_STATE_DIR -u ORIGIN_STATE_DIR -u OPERATOR_STATE_DIR REPO_DIR="$JPA" KICKOFF_ADOPTERS_REGISTRY="$JREG3" bash "$PREF" 2>&1 || true)"
chk "preflight #2: a DIFFERENT sibling channel → NO channel-clash FAIL" "! printf '%s' \"\$JPFO2\" | grep -iE '\\[FAIL\\].*(channel clash|shares this repo)'"

# ── READER HALF of the core-v0.27 channel cross-wire ────────────────────────────────────────
# Every lane ABOVE scrubs the ambient channel (`env -u TELEGRAM_STATE_DIR …`) "so the fixture's
# wins" — which is precisely the case the bug is NOT in. The live shape is the opposite: a
# `kickoff pull`/preflight for repo B run from INSIDE repo A's worker session (every fleet sweep)
# carries A's channel ambiently. preflight honored it (TELEGRAM_STATE_DIR was subject to
# pre-set-wins, and the adopter's self-defaulting `${TELEGRAM_STATE_DIR:-…}` form kept it even
# inside the import subshell), so #2 evaluated A's channel as if it were B's and FAILED a phantom
# "channel clash" against A itself — fail-closed, blocking B's pull and A's hop with no clash on
# the box. v0.27 fixed the WRITERS (cmd_pull/cmd_adopt); this is the reader.
JR="$(mk)"; JRB="$JR/repo-b"; JRA="$JR/repo-a"; JRCB="$JR/chan-b"; JRCA="$JR/chan-a"
mkdir -p "$JRB/.kickoff/memory" "$JRA" "$JRCB" "$JRCA"
JRCBr="$(cd "$JRCB" && pwd -P)"; JRCAr="$(cd "$JRCA" && pwd -P)"; JRAr="$(cd "$JRA" && pwd -P)"
printf '# m\n' > "$JRB/.kickoff/memory/MEMORY.md"
# the SELF-DEFAULTING form real adopters ship (instance.env.example seeds it) — an ambient value
# survives a plain source, which is what makes the unset inside the import subshell load-bearing
# rather than decoration.
printf 'export TELEGRAM_STATE_DIR="${TELEGRAM_STATE_DIR:-%s}"\n' "$JRCBr" > "$JRB/.kickoff/instance.env"
chk "reader fixture: the target's instance.env really uses the self-defaulting \${TELEGRAM_STATE_DIR:-…} form" \
  "grep -q 'export TELEGRAM_STATE_DIR=\"\${TELEGRAM_STATE_DIR:-' \"$JRB/.kickoff/instance.env\""
JRREG="$JR/reg.json"
KICKOFF_ADOPTERS_REGISTRY="$JRREG" python3 "$AM" adopters-register --repo "$JRA" --tag core-vA --version-dir "$JRA" --channel "$JRCAr" >/dev/null 2>&1
KICKOFF_ADOPTERS_REGISTRY="$JRREG" python3 "$AM" adopters-register --repo "$JRB" --tag core-vB --version-dir "$JRB" --channel "$JRCBr" >/dev/null 2>&1
# NOTE the arg order: `env` rejects -u AFTER an assignment, and an env that never launches
# preflight leaves the output EMPTY — every assertion below would then pass on a world nobody
# lives in. The gate-line guard immediately after is what makes this lane non-vacuous.
JRPF="$(env -u ORIGIN_STATE_DIR -u OPERATOR_STATE_DIR TELEGRAM_STATE_DIR="$JRCAr" \
        REPO_DIR="$JRB" KICKOFF_ADOPTERS_REGISTRY="$JRREG" bash "$PREF" 2>&1 || true)"
chk "reader lane is NON-VACUOUS: preflight actually ran (emitted gate lines)" \
  "printf '%s' \"\$JRPF\" | grep -qiE '\\[( ?ok ?|FAIL|WARN)\\]'"
chk "reader [RED pre-fix]: ambient CALLER channel → preflight reports the TARGET's OWN channel" \
  "printf '%s' \"\$JRPF\" | grep -qF 'TELEGRAM_STATE_DIR=$JRCBr'"
chk "reader [RED pre-fix]: the CALLER's channel is NOT reported as the target's" \
  "! printf '%s' \"\$JRPF\" | grep -qF 'TELEGRAM_STATE_DIR=$JRCAr'"
chk "reader [RED pre-fix]: NO phantom channel clash (the two repos hold DIFFERENT channels)" \
  "! printf '%s' \"\$JRPF\" | grep -iE '\\[FAIL\\].*(channel clash|shares this repo)'"
chk "reader [RED pre-fix]: the sibling repo is not named as a clash" \
  "! printf '%s' \"\$JRPF\" | grep -qF '$JRAr'"
# NEGATIVE CONTROL — the guard must not be merely disabled: with the target's OWN instance.env
# naming the sibling's channel, that IS a real double-poller and #2 must still FAIL, ambient or not.
printf 'export TELEGRAM_STATE_DIR="${TELEGRAM_STATE_DIR:-%s}"\n' "$JRCAr" > "$JRB/.kickoff/instance.env"
JRPFN="$(env -u ORIGIN_STATE_DIR -u OPERATOR_STATE_DIR TELEGRAM_STATE_DIR="$JRCAr" \
         REPO_DIR="$JRB" KICKOFF_ADOPTERS_REGISTRY="$JRREG" bash "$PREF" 2>&1 || true)"
chk "reader NEGATIVE CONTROL: a REAL clash (target's own env names the sibling's channel) still FAILs" \
  "printf '%s' \"\$JRPFN\" | grep -iE '\\[FAIL\\].*(channel clash|shares this repo)'"
# RED-on-old — prove the lane FAILS against the pre-fix preflight, so it is a real negative control
# and not four assertions that would pass on any build.
JROLD="$JR/preflight-head.sh"
if git -C "$REPO" show HEAD:scripts/preflight.sh > "$JROLD" 2>/dev/null && [ -s "$JROLD" ]; then
  printf 'export TELEGRAM_STATE_DIR="${TELEGRAM_STATE_DIR:-%s}"\n' "$JRCBr" > "$JRB/.kickoff/instance.env"
  JROUT="$(env -u ORIGIN_STATE_DIR -u OPERATOR_STATE_DIR TELEGRAM_STATE_DIR="$JRCAr" \
           REPO_DIR="$JRB" KICKOFF_ADOPTERS_REGISTRY="$JRREG" bash "$JROLD" 2>&1 || true)"
  if printf '%s' "$JROUT" | grep -qiE '\[( ?ok ?|FAIL|WARN)\]'; then
    if printf '%s' "$JROUT" | grep -qF "TELEGRAM_STATE_DIR=$JRCAr"; then
      ok "RED-on-old: HEAD:preflight.sh DOES report the caller's channel (the lane is a real negative control)"
    else
      echo "  skip RED-on-old n/a — HEAD:scripts/preflight.sh already carries the reader fix (post-commit state)"
    fi
  else
    echo "  skip RED-on-old n/a — HEAD:scripts/preflight.sh did not run standalone here"
  fi
else
  echo "  skip RED-on-old n/a — no git HEAD copy of scripts/preflight.sh available"
fi
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(k) G10c — a shim-run tool resolves REPO_DIR from the shim's OWN location (not ambient/foreign)"
# ══════════════════════════════════════════════════════════════════════════════════════
KAM="$REPO/scripts/adopt-manifest.py"
KSTUB="$(mk)/core"; mkdir -p "$KSTUB/mission-control"
printf '#!/usr/bin/env python3\nimport os\nprint(os.environ.get("MC_STATE_FILE",""))\n' > "$KSTUB/mission-control/mc-update.py"
KR="$(mk)/shimrepo"; KO="$(mk)/otherrepo"; KF="$(mk)/foreign"; mkdir -p "$KR/.kickoff" "$KO" "$KF"
python3 "$KAM" gen-shim --repo "$KR" --name mc --source core-vTEST >/dev/null 2>&1
printf 'export KICKOFF_CORE_DIR="${KICKOFF_CORE_DIR:-%s}"\nexport MC_STATE_FILE="${MC_STATE_FILE:-${REPO_DIR:-$PWD}/.kickoff/state/mission-control/mission-state.json}"\n' "$KSTUB" > "$KR/.kickoff/instance.env"
KOUT="$(cd "$KF" && env REPO_DIR="$KO" "$KR/.kickoff/bin/mc" x 2>/dev/null || true)"
chk "G10c: shim-run mc writes the shim's OWN repo state (/shimrepo/) despite ambient REPO_DIR=<other>" "printf '%s' \"\$KOUT\" | grep -q '/shimrepo/.kickoff/state/'"
chk "G10c: shim-run mc does NOT write the ambient <other> repo (/otherrepo/)" "! printf '%s' \"\$KOUT\" | grep -q '/otherrepo/'"
# PRE-FIX contrast: an UN-pinned (old-template) shim DOES leak into the ambient <other> repo
KOLDSHIM="$KR/.kickoff/bin/mc-old"
printf '#!/usr/bin/env bash\n_here="$(cd "$(dirname "$0")" && pwd)"\n[ -f "$_here/../instance.env" ] && . "$_here/../instance.env"\n_engine="${KICKOFF_CORE_DIR:-}/mission-control/mc-update.py"\nexec python3 "$_engine" "$@"\n' > "$KOLDSHIM"; chmod +x "$KOLDSHIM"
KOLD="$(cd "$KF" && env REPO_DIR="$KO" "$KOLDSHIM" x 2>/dev/null || true)"
chk "PRE-FIX contrast: an UN-pinned shim leaks into the ambient <other> repo (proves the anchor is real)" "printf '%s' \"\$KOLD\" | grep -q '/otherrepo/'"
# explicit per-var override STILL wins over the REPO_DIR anchor
KCUST="$(mk)/board.json"
printf 'export KICKOFF_CORE_DIR="${KICKOFF_CORE_DIR:-%s}"\nexport MC_STATE_FILE="${MC_STATE_FILE:-%s}"\n' "$KSTUB" "$KCUST" > "$KR/.kickoff/instance.env"
KOUT3="$(cd "$KF" && env REPO_DIR="$KO" "$KR/.kickoff/bin/mc" x 2>/dev/null || true)"
chk "G10c: an explicit absolute MC_STATE_FILE default STILL wins (override > anchor)" "[ \"$KOUT3\" = \"$KCUST\" ]"
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(g) PRE-FIX-FAILS — the SAME 8a/8b/8c-bind checks FAIL against the ORIGINAL box-ingress/ingress.sh"
# ══════════════════════════════════════════════════════════════════════════════════════
if [ -f "$ORIG_INGRESS" ]; then
  ORIG="$(mk)/ingress.sh"; cp "$ORIG_INGRESS" "$ORIG"   # read-only copy of the live original into scratch
  # 8a pre-fix: original has NO auth support → auth app → NO basic_auth emitted (our 8a assertion FAILS there)
  GA="$(mk)"
  write_registry "$GA" "{\"funnel_port\":443,\"listen\":$LISTEN,\"public_base\":\"https://s.ts.net\",\"projects\":{\"deck\":{\"apps\":{\"pitch\":{\"type\":\"proxy\",\"target\":\"127.0.0.1:$UP_PORT\",\"strip_prefix\":false,\"auth\":{\"$AUTHUSER\":\"$AUTHHASH\"}}}}}}"
  INGRESS_DIR="$GA" bash "$ORIG" gen >/dev/null 2>&1
  chk "8a PRE-FIX: original DROPS the auth block (no basic_auth) — the fix is real" \
    "! grep -q 'basic_auth' \"$GA/Caddyfile\""
  # 8b pre-fix: original gen has NO port guard → reserved-port proxy → gen SUCCEEDS + emits the route
  GB="$(mk)"
  write_registry "$GB" "{\"funnel_port\":443,\"listen\":$LISTEN,\"public_base\":\"https://s.ts.net\",\"projects\":{\"mc\":{\"apps\":{\"leak\":{\"type\":\"proxy\",\"target\":\"127.0.0.1:9100\",\"strip_prefix\":false}}}}}"
  rm -f "$GB/Caddyfile"
  INGRESS_DIR="$GB" bash "$ORIG" gen >/dev/null 2>&1; GB_RC=$?
  chk "8b PRE-FIX: original gen ACCEPTS the reserved :9100 target (rc0) — the fix is real" "[ $GB_RC -eq 0 ]"
  chk "8b PRE-FIX: original EMITS the reserved-port route into the Caddyfile" \
    "grep -q '127.0.0.1:9100' \"$GB/Caddyfile\""
  # 8c-bind pre-fix: original wildcard-binds :<listen> (no loopback)
  GC="$(mk)"
  write_registry "$GC" "{\"funnel_port\":443,\"listen\":$LISTEN,\"public_base\":\"https://s.ts.net\",\"projects\":{\"app\":{\"apps\":{\"web\":{\"type\":\"static\",\"target\":\"$GC\",\"strip_prefix\":true}}}}}"
  INGRESS_DIR="$GC" bash "$ORIG" gen >/dev/null 2>&1
  chk "8c-bind PRE-FIX: original emits a WILDCARD/bare :$LISTEN bind — the fix is real" \
    "grep -qE '(^|[[:space:]]):$LISTEN' \"$GC/Caddyfile\""
  chk "8c-bind PRE-FIX: original does NOT bind 127.0.0.1:$LISTEN" \
    "! grep -q '127.0.0.1:$LISTEN' \"$GC/Caddyfile\""
else
  bad "PRE-FIX proof SKIPPED — original not found at $ORIG_INGRESS (set INGRESS_ORIG_SH)"
fi
echo

# ══════════════════════════════════════════════════════════════════════════════════════
echo "(h) LIVE-SAFETY CANARY — the live ~/box-ingress front door is UNTOUCHED"
# ══════════════════════════════════════════════════════════════════════════════════════
LIVE_REG_AFTER="$(canary_hash "$LIVE_REG")"
LIVE_CF_AFTER="$(canary_hash "$LIVE_CF")"
LIVE_PIDS_AFTER="$(live_caddy_pids)"
chk "CANARY: live registry.json is byte-identical (before==after)" "[ \"$LIVE_REG_BEFORE\" = \"$LIVE_REG_AFTER\" ]"
chk "CANARY: live Caddyfile is byte-identical (before==after)" "[ \"$LIVE_CF_BEFORE\" = \"$LIVE_CF_AFTER\" ]"
if [ -n "$LIVE_PIDS_BEFORE" ]; then
  ALL_ALIVE=1
  for p in $LIVE_PIDS_BEFORE; do kill -0 "$p" 2>/dev/null || ALL_ALIVE=0; done
  chk "CANARY: the live box-ingress caddy pid(s) are still alive [$LIVE_PIDS_BEFORE]" "[ $ALL_ALIVE -eq 1 ]"
  chk "CANARY: the live caddy pid set is unchanged (none killed/spawned)" "[ \"$LIVE_PIDS_BEFORE\" = \"$LIVE_PIDS_AFTER\" ]"
else
  ok "CANARY: no live box-ingress caddy detected on this box (nothing to endanger)"
fi
echo

echo "──────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "  ✅ local-serving slice (Fix 8a/8b/8c + remove + eject) holds"; exit 0; } || { echo "  ❌ see failures above"; exit 1; }
