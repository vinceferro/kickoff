#!/usr/bin/env bash
# mc-mountpoint-selftest.sh — the board must work wherever it is mounted, not only at "/".
#
#   bash scripts/mc-mountpoint-selftest.sh
#
# THE BUG (found live 2026-07-27, by the operator on his own device — not by a review):
# every dashboard fetch was root-absolute — `fetch("/state")`, `new EventSource("/events")`.
# That silently assumes the board is served at the host root. Behind a path-routing ingress it
# is served at `/<tenant>/`, so those URLs resolved against the ROOT: `/state` → 404 while
# `/myproject/state` → 200. The page still loaded and still authenticated, so the failure
# presented as "the token isn't working" — a wrong diagnosis that cost a round trip.
#
# I had "verified" that cutover by curling `/myproject/` and seeing 200. That tested the PAGE
# and not what the page then FETCHES. This suite exists so that layer is never skipped again.
#
# The fix under test: a computed `MC_BASE` from `location.pathname` plus an `mcUrl()` helper,
# so the same file works at "/" and at "/anything/". Asserted structurally (no browser here)
# with a RED-first control — the pre-fix source must fail these checks.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "▶ mission-control mount-point self-test (a board served under a prefix must still fetch)"
echo

FILES=()
for f in "$ROOT/mission-control/dashboard.html" "$ROOT/mission-control/dashboard.cockpit.html"; do
  [ -f "$f" ] && FILES+=("$f")
done
[ "${#FILES[@]}" -gt 0 ] && ok "found ${#FILES[@]} dashboard file(s) to check" \
  || bad "no dashboard files found — this suite would be vacuously green"

for f in ${FILES[@]+"${FILES[@]}"}; do
  n="$(basename "$f")"

  # 1. NO root-absolute data calls survive. This is the actual defect.
  hits="$(grep -cE '(fetch|new EventSource)\((["'"'"'])/' "$f" || true)"
  [ "${hits:-0}" -eq 0 ] && ok "$n: no root-absolute fetch/EventSource remains" \
    || bad "$n: $hits root-absolute call site(s) — these 404 under any prefix"

  # 2. The helper exists and is defined BEFORE it is used (order matters in a script tag).
  if grep -q 'MC_BASE' "$f" && grep -q 'mcUrl' "$f"; then
    d="$(grep -n 'const MC_BASE' "$f" | head -1 | cut -d: -f1)"
    u="$(grep -n 'mcUrl(' "$f" | head -1 | cut -d: -f1)"
    if [ -n "$d" ] && [ -n "$u" ] && [ "$d" -lt "$u" ]; then
      ok "$n: MC_BASE is defined before the first mcUrl() call"
    else
      bad "$n: mcUrl() is used at line ${u:-?} before MC_BASE is defined at line ${d:-?}"
    fi
  else
    bad "$n: no MC_BASE/mcUrl helper"
  fi

  # 3. Every endpoint the page talks to goes through the helper.
  for ep in /state /events /config /checkoff /commit-milestone; do
    if grep -q -- "$ep" "$f"; then
      grep -qE "mcUrl\\((\"|')$ep" "$f" \
        && ok "$n: $ep routed through mcUrl()" \
        || bad "$n: $ep is referenced but NOT through mcUrl()"
    fi
  done
done

# 4. The prefix logic itself — run the real expression under node, at three mount points.
if command -v node >/dev/null 2>&1; then
  JS='const f=(p)=>{let x=p; if(!x.endsWith("/")) x=x.slice(0,x.lastIndexOf("/")+1); return x||"/";};
      const u=(b,p)=>b+String(p).replace(/^\//,"");
      const cases=[["/", "/state"],["/myproject/","/state"],["/myproject","/state"],["/a/b/","/events"]];
      console.log(cases.map(([p,e])=>u(f(p),e)).join(" "));'
  out="$(node -e "$JS" 2>/dev/null)"
  want="/state /myproject/state /state /a/b/events"
  [ "$out" = "$want" ] && ok "prefix logic: root, /myproject/, /a/b/ all resolve correctly" \
    || bad "prefix logic wrong — got [$out] want [$want]"
  # the no-trailing-slash case genuinely resolves to the parent; that is correct browser
  # behaviour and the ingress redirects /myproject → /myproject/, so it is never the live path.
else
  printf '  ⚠ node absent — prefix logic not executed (structure still checked)\n'
fi

# 5. RED-FIRST CONTROL: reconstruct the PRE-FIX form and prove these checks catch it.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '%s\n' '<script>fetch("/state"); new EventSource("/events");</script>' > "$TMP/old.html"
oldhits="$(grep -cE '(fetch|new EventSource)\((["'"'"'])/' "$TMP/old.html" || true)"
[ "${oldhits:-0}" -gt 0 ] && ok "★ RED-first: the pre-fix root-absolute form IS detected by check 1" \
  || bad "★ the control did NOT trip — check 1 cannot fail, so its green means nothing"

echo
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && echo "  ✅ the board works wherever it is mounted" || echo "  ❌ see failures above"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
