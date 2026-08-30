#!/usr/bin/env bash
# check-bot-imports-selftest.sh — catch "called but never imported" crashes in the vendored
# telegram-bot patches before they ship to live bots.
#
#   bash scripts/check-bot-imports-selftest.sh
#
# The bug class (v6.2, bit 4 live orgs 2026-08-25): event-subscription-service.js called
# getAllUserSessions() (settings-store export) WITHOUT importing it. Every file-change event
# under compact-progress mode threw ReferenceError, swallowed by the generic event dispatcher
# as "[Events] Callback failed" — so pinnedMessageManager.addFileChange never ran and the
# pinned live-progress message silently froze. Byte-drift guards (check-bot-patch-drift.sh)
# can't see this: the file was internally consistent, just broken.
#
# What it checks, per file in PATCHED_FILES (mirrors check-bot-patch-drift.sh):
#   every identifier that (a) is exported by app/stores/settings-store.js (the SNAPSHOT copy)
#   and (b) appears as a CALL SITE `name(` in the file, must be in scope there — i.e. present
#   in some import binding or declared locally. Deliberately NOT "must come from a
#   settings-store import": getCurrentSession is legitimately imported from session-service.js
#   (a real cross-module name collision), and what crashes at runtime is absence from scope,
#   not absence from one specific module.
# False-positive guards baked in and pinned by lanes below: only CALLS count (not mentions in
# comments/strings), member access `obj.name(` is not a module-function call, multi-name
# import braces parse (incl. `A as B`), and `import * as ns` does NOT satisfy a bare name.
#
# Dependency-free bash+node. RED-first proven: ran against the buggy snapshot and watched it
# fail on exactly `getAllUserSessions @ bot/services/event-subscription-service.js:1022`
# before the one-line import fix landed. In-suite negative controls keep that proof alive
# post-commit (the convention pin-verify-selftest uses for RED-on-old once HEAD carries the
# fix): a COPY of the real file is re-broken and must flag again.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SNAPSHOT="${BOT_PATCH_SNAPSHOT:-$HERE/../patches/opencode-telegram-bot-v6}"
STORE_REL="app/stores/settings-store.js"

# Absence-skip (registered in lefthook pre-push): without the vendored snapshot this suite
# has no subject — SKIP loudly rather than red every push on a checkout that never carried
# the bot patches. A HOLE inside a PRESENT snapshot stays a RED (checked below).
[[ -d "$SNAPSHOT" ]] || { echo "⏭️  SKIP check-bot-imports self-test — vendored bot snapshot absent at $SNAPSHOT (patches/opencode-telegram-bot-v6/ not on this checkout); nothing to scan"; exit 0; }

PATCHED_FILES=(
  "config.js"
  "app/stores/settings-store.js"
  "app/stores/user-scope.js"
  "bot/middleware/auth.js"
  "bot/services/event-subscription-service.js"
  "bot/services/attach-presentation.js"
)

PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

cat > "$W/scan.mjs" <<'NODE'
import fs from "node:fs";

// Blank out comments and string-literal CONTENTS (spaces, so offsets/newlines survive) while
// PRESERVING the delimiters themselves (' " ` ${ }) — the import parser needs the quotes.
// Code inside a template literal's ${...} interpolation survives untouched: it is real code.
// Needed in BOTH directions: a commented-out import must not satisfy, a mentioned-in-a-string
// name must not flag, and a call inside `${...}` MUST flag. Line comments terminate at \n —
// a missing reset there once swallowed every file after its first trailing comment and made
// half this suite green vacuously.
function blank(src) {
  let out = "", i = 0;
  const n = src.length;
  let mode = "code";            // code | line | block | sq | dq | tpl (+ i* variants inside ${})
  let brace = 0;                // brace depth inside a ${ } interpolation
  const stack = [];             // outer brace depths saved when entering interpolations
  const emitN = (k) => { out += " ".repeat(k); };
  while (i < n) {
    const c = src[i], d = src[i + 1];
    if (c === "\n") { if (mode === "line") mode = "code"; if (mode === "iline") mode = "interp"; out += "\n"; i++; continue; }
    if (mode === "code") {
      if (c === "/" && d === "/") { mode = "line"; i += 2; emitN(2); continue; }
      if (c === "/" && d === "*") { mode = "block"; i += 2; emitN(2); continue; }
      if (c === "'") { mode = "sq"; out += c; i++; continue; }
      if (c === '"') { mode = "dq"; out += c; i++; continue; }
      if (c === "`") { mode = "tpl"; out += c; i++; continue; }
      out += c; i++; continue;
    }
    if (mode === "line") { emitN(1); i++; continue; }
    if (mode === "block") { if (c === "*" && d === "/") { mode = "code"; emitN(2); i += 2; } else { emitN(1); i++; } continue; }
    if (mode === "sq") { if (c === "\\") { emitN(2); i += 2; continue; } if (c === "'") { mode = "code"; out += c; i++; continue; } emitN(1); i++; continue; }
    if (mode === "dq") { if (c === "\\") { emitN(2); i += 2; continue; } if (c === '"') { mode = "code"; out += c; i++; continue; } emitN(1); i++; continue; }
    if (mode === "tpl") {
      if (c === "\\") { emitN(2); i += 2; continue; }
      if (c === "`") { mode = "code"; out += c; i++; continue; }
      if (c === "$" && d === "{") { stack.push(brace); brace = 0; mode = "interp"; out += "${"; i += 2; continue; }
      emitN(1); i++; continue;
    }
    if (mode === "interp") {                                   // back in code, but scoped
      if (c === "/" && d === "/") { mode = "iline"; i += 2; emitN(2); continue; }
      if (c === "/" && d === "*") { mode = "iblock"; i += 2; emitN(2); continue; }
      if (c === "'") { mode = "isq"; out += c; i++; continue; }
      if (c === '"') { mode = "idq"; out += c; i++; continue; }
      if (c === "`") { mode = "itpl"; out += c; i++; continue; }
      if (c === "}") { out += c; i++; if (brace === 0) { brace = stack.pop() ?? 0; mode = "tpl"; } else { brace--; } continue; }
      out += c; i++; continue;
    }
    if (mode === "iline") { emitN(1); i++; continue; }
    if (mode === "iblock") { if (c === "*" && d === "/") { mode = "interp"; emitN(2); i += 2; } else { emitN(1); i++; } continue; }
    if (mode === "isq") { if (c === "\\") { emitN(2); i += 2; continue; } if (c === "'") { mode = "interp"; out += c; i++; continue; } emitN(1); i++; continue; }
    if (mode === "idq") { if (c === "\\") { emitN(2); i += 2; continue; } if (c === '"') { mode = "interp"; out += c; i++; continue; } emitN(1); i++; continue; }
    if (mode === "itpl") { if (c === "\\") { emitN(2); i += 2; continue; } if (c === "`") { mode = "interp"; out += c; i++; continue; } emitN(1); i++; continue; }
  }
  return out;
}

const lineOf = (src, idx) => src.slice(0, idx).split("\n").length;

function exportsOf(storePath) {
  const src = blank(fs.readFileSync(storePath, "utf8"));
  const names = new Set();
  for (const m of src.matchAll(/export\s+(?:async\s+)?function\s+(\w+)/g)) names.add(m[1]);
  for (const m of src.matchAll(/export\s+(?:const|let|var)\s+(\w+)/g)) names.add(m[1]);
  for (const m of src.matchAll(/export\s*\{([^}]*)\}/g))
    for (const raw of m[1].split(",")) {
      const nm = raw.trim().split(/\s+as\s+/)[0].trim();
      if (nm) names.add(nm);
    }
  return names;
}

// Scan one file; print `FINDING\t<path>\t<line>\t<name>` per out-of-scope call site.
function scanFile(path, exportNames) {
  const src = blank(fs.readFileSync(path, "utf8"));
  const bound = new Set();       // names bound by ANY named import (cross-module collisions exist)
  for (const m of src.matchAll(/import\s*\{([^}]*)\}\s*from\s*["'][^"']+["']/g))
    for (const rawName of m[1].split(",")) {
      const nm = rawName.trim().split(/\s+as\s+/).pop().trim();
      if (nm) bound.add(nm);
    }
  const local = new Set();
  for (const m of src.matchAll(/(?:function|class)\s+(\w+)/g)) local.add(m[1]);
  for (const m of src.matchAll(/(?:const|let|var)\s+(\w+)\s*=/g)) local.add(m[1]);
  for (const name of exportNames) {
    const callRe = new RegExp(String.raw`(?<![\w$.])${name}\s*\(`, "g");
    for (const m of src.matchAll(callRe)) {
      if (!bound.has(name) && !local.has(name))
        console.log(`FINDING\t${path}\t${lineOf(src, m.index)}\t${name}`);
    }
  }
}

const args = process.argv.slice(2);
if (args[0] === "--list-exports") {
  console.log([...exportsOf(args[1])].sort().join("\n"));
  process.exit(0);
}
const [storePath, ...files] = args;
const exportNames = exportsOf(storePath);
for (const f of files) scanFile(f, exportNames);
NODE

scan() { # $1 = snapshot-style tree dir; remaining = repo-relative file paths
  local tree="$1"; shift
  local abs=()
  for f in "$@"; do abs+=("$tree/$f"); done
  node "$W/scan.mjs" "$tree/$STORE_REL" "${abs[@]}" 2>&1
}

echo "▶ check-bot-imports self-test (called-but-not-imported crash class in vendored bot patches)"
echo

[[ -f "$SNAPSHOT/$STORE_REL" ]] || { echo "  ❌ snapshot settings-store missing at $SNAPSHOT/$STORE_REL"; exit 1; }

echo "── the scanner itself: extraction and precision ──"

EXPORTS="$(node "$W/scan.mjs" --list-exports "$SNAPSHOT/$STORE_REL")"
if printf '%s' "$EXPORTS" | grep -qx 'getAllUserSessions' && printf '%s' "$EXPORTS" | grep -qx 'loadSettings'; then
  ok "export extraction finds plain AND async function exports ($(printf '%s\n' "$EXPORTS" | wc -l | tr -d ' ') exports incl. getAllUserSessions, loadSettings)"
else
  bad "export extraction incomplete — got: $(printf '%s' "$EXPORTS" | tr '\n' ' ' | cut -c1-200)"
fi

mkfix() { # $1=dir  stdin = svc.js body; writes a minimal store + svc fixture
  mkdir -p "$1/app/stores"
  cat > "$1/app/stores/settings-store.js" <<'EOF'
export function getRawCurrentSession() { return null; }
export function getAllUserSessions() { return {}; }
EOF
  cat > "$1/svc.js"
}

# THE BUG, minimally reproduced: a call site with no import anywhere.
FX="$W/fx-bites"
mkfix "$FX" <<'EOF'
import { getRawCurrentSession } from "./app/stores/settings-store.js";
export function handler(change) {
    const ids = Object.values(getAllUserSessions()).map(s => s?.id);
    void change;
}
EOF
HITS="$(scan "$FX" svc.js)"
# FINDING rows are `<abs-path>\t<line>\t<name>` — assert on fields, not one fragile mega-grep.
if printf '%s' "$HITS" | awk -F'\t' '$2 ~ /\/svc\.js$/ && $3 ~ /^[0-9]+$/ && $4 == "getAllUserSessions" { f=1 } END { exit f ? 0 : 1 }'; then
  ok "bites: an unimported call beside a VALID other import is flagged (svc.js line $(printf '%s' "$HITS" | awk -F'\t' '{print $3; exit}'))"
else
  bad "scanner MISSED the minimal bug — got: ${HITS:-<nothing>}"
fi

# Precision, NON-VACUOUS: the fixture carries a proper multi-name import AND real calls AND
# every kind of mention noise. Clean here means "the noise did not flag", not "nothing ran".
FX="$W/fx-mentions"
mkfix "$FX" <<'EOF'
import { getAllUserSessions, getRawCurrentSession as rawSession } from "./app/stores/settings-store.js";
// getAllUserSessions( unimported would crash — but this line is a COMMENT.
const label = 'getAllUserSessions( in a string is not a call';
const obj = { getAllUserSessions: () => ({}) };
function shim() { return obj.getAllUserSessions(); }   // member access, not the module fn
export function handler() {
    const a = getAllUserSessions();
    const b = rawSession();                            // imported under an alias
    void label; void shim; void a; void b;
}
EOF
if [[ -z "$(scan "$FX" svc.js)" ]]; then
  ok "precise: multi-name braces + aliases satisfy; comment/string/member-access do NOT flag"
else
  bad "false positives on properly-imported calls or mere mentions — got: $(scan "$FX" svc.js | tr '\n' ';')"
fi

# A call that exists ONLY inside a comment must stay invisible — proven sharply: the SAME tree
# carries an unimported call in a second file, which MUST flag while the comment file stays clean.
FX="$W/fx-comment"
mkfix "$FX" <<'EOF'
// const x = getAllUserSessions();   — commented out entirely, no live occurrence
export function handler() { return 1; }
EOF
mkdir -p "$FX/bot/services"
printf 'export function live() { return getAllUserSessions(); }\n' > "$FX/bot/services/live.js"
CMT="$(scan "$FX" svc.js)"; LIVE="$(scan "$FX" bot/services/live.js)"
if [[ -z "$CMT" ]] && printf '%s' "$LIVE" | grep -q 'live\.js.*getAllUserSessions'; then
  ok "a commented-out call is invisible while a live one in the same tree still flags"
else
  bad "comment lane wrong — commented file: ${CMT:-clean}; live file: ${LIVE:-NOT flagged}"
fi

# Cross-module collision tolerance: the real tree imports getCurrentSession from session-service,
# not settings-store. Scope is what matters, not which module supplied it.
FX="$W/fx-collision"
mkdir -p "$FX/app/stores" "$FX/app/services"
printf 'export function getCurrentSession() { return null; }\n' > "$FX/app/stores/settings-store.js"
printf 'export function getCurrentSession() { return {}; }\n' > "$FX/app/services/session-service.js"
cat > "$FX/svc.js" <<'EOF'
import { getCurrentSession } from "./app/services/session-service.js";
export function handler() { return getCurrentSession()?.id; }
EOF
if [[ -z "$(scan "$FX" svc.js)" ]]; then
  ok "a name imported from ANOTHER module (getCurrentSession ← session-service) is in scope: clean"
else
  bad "collision false positive: flagged a properly imported name — got: $(scan "$FX" svc.js | tr '\n' ';')"
fi

# `import * as ns` does NOT bring bare names into scope — a bare call must still flag.
FX="$W/fx-ns"
mkfix "$FX" <<'EOF'
import * as settingsStore from "./app/stores/settings-store.js";
export function handler() { return getAllUserSessions(); }
EOF
if printf '%s' "$(scan "$FX" svc.js)" | grep -q 'getAllUserSessions'; then
  ok "namespace import does NOT satisfy a bare call (still flags — it would still crash)"
else
  bad "namespace-import lane went soft — a bare call beside \`import * as\` must flag"
fi

# Code inside a template-literal ${...} interpolation is real code.
FX="$W/fx-tpl"
mkfix "$FX" <<'EOF'
export function render() {
    return `sessions: ${JSON.stringify(getAllUserSessions())}`;
}
EOF
if printf '%s' "$(scan "$FX" svc.js)" | grep -q 'getAllUserSessions'; then
  ok 'calls inside template-literal ${…} interpolations are seen and flagged'
else
  bad "interpolation call missed — the string-blanker ate real code"
fi

echo
echo "── negative control: the scanner bites the REAL artifact ──"
# Post-commit, the snapshot is fixed and the main lane below cannot go red again. This lane
# re-breaks a COPY of the real file (strips getAllUserSessions from its settings-store import
# lines only — never touching the call site) and demands the scanner flag it. A suite that can
# no longer fail is measuring nothing.
REAL="$SNAPSHOT/bot/services/event-subscription-service.js"
MUT="$W/mutated/bot/services"; mkdir -p "$MUT"
sed '/from ".*settings-store\.js"/ s/getAllUserSessions,\?//g' "$REAL" > "$MUT/event-subscription-service.js"
if grep -q 'getAllUserSessions()' "$MUT/event-subscription-service.js" \
   && ! grep -q 'getAllUserSessions' <(grep 'from ".*settings-store\.js"' "$MUT/event-subscription-service.js"); then
  ok "fixture is SHARP: mutated copy still calls getAllUserSessions() but no longer imports it"
else
  bad "mutation failed — cannot construct the RED control (import shape drifted?)"
fi
mkdir -p "$W/mut-tree/app/stores" "$W/mut-tree/bot/services"
cp "$SNAPSHOT/$STORE_REL" "$W/mut-tree/$STORE_REL"
cp "$MUT/event-subscription-service.js" "$W/mut-tree/bot/services/event-subscription-service.js"
HITS="$(scan "$W/mut-tree" bot/services/event-subscription-service.js)"
if printf '%s' "$HITS" | grep -q 'getAllUserSessions'; then
  ok "RED-on-mutant: scanner flags the re-broken real file (line $(printf '%s' "$HITS" | head -1 | cut -f3))"
else
  bad "scanner did NOT flag the re-broken real file — the suite cannot prove itself red"
fi

echo
echo "── the real thing: every patched file must be clean ──"
missing=0
for f in "${PATCHED_FILES[@]}"; do
  [[ -f "$SNAPSHOT/$f" ]] || { echo "  ❌ SNAPSHOT HOLE: $f missing (canonical-source rot)"; missing=1; }
done
if [[ $missing -eq 1 ]]; then bad "snapshot tree incomplete against PATCHED_FILES"; fi

FINDINGS="$(scan "$SNAPSHOT" "${PATCHED_FILES[@]}")"
if [[ -z "$FINDINGS" && $missing -eq 0 ]]; then
  ok "all ${#PATCHED_FILES[@]} patched files: every settings-store export called is imported (clean)"
else
  bad "called-but-not-imported findings in the snapshot:"
  printf '%s\n' "$FINDINGS" | while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    f="$(printf '%s' "$line" | cut -f2)"; l="$(printf '%s' "$line" | cut -f3)"; nm="$(printf '%s' "$line" | cut -f4)"
    printf '       ✗ %s:%s calls `%s()` with no import binding in scope\n' "${f#"$SNAPSHOT"/}" "$l" "$nm"
  done
fi

echo
echo "──────────────────────────────"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && echo "  ✅ no settings-store export is called without an import in any patched file" \
                  || echo "  ❌ import-integrity FAILED — ReferenceError-at-runtime class present"
exit $(( FAIL > 0 ? 1 : 0 ))
