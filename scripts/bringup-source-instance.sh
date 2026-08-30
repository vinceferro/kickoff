#!/usr/bin/env bash
# bringup-source-instance.sh — wire a fresh ENGINE-SOURCE clone as a working kickoff instance.
#
#   bash scripts/bringup-source-instance.sh
#
# THE PATH THIS WIRES (see RUNNING.md, "engine-development mode"): a second machine clones the
# kickoff repo itself and wants the harness — memory recall, boot checks — WORKING there, without
# adopting a pinned core (this tree IS the core). Until now that mode was undocumented and
# hand-wired: interactive sessions had no KICKOFF_CORE_DIR, no index was ever built, and the
# env-less indexer died as a bare ENOENT (the 2026-08-26 second-machine incident). This turnkey
# does the whole bring-up in one command; it is idempotent (safe to re-run — each step is
# absent-only or a deliberate rebuild).
#
# WHAT IT DOES
#   a. `kickoff init`                     — only if .kickoff/instance.env is absent (never clobbers)
#   b. patch instance.env to source mode  — idempotent; a value you hand-set is left alone
#   c. FIRST INDEX BUILD from scratch     — an existing memory-index.db is moved aside
#                                           (a manually-built db on this box is untrusted)
#   d. VERIFY by consumed state           — a real retrieval must answer, not just exit 0
#   e. NEXT ACTIONS                       — the acceptance proofs for a human
#
# NOT here on purpose: live Telegram wiring (needs the operator's own bot token — separate,
# optional; see RUNNING.md) and any upgrade machinery (`kickoff pull` / the upgrade turnkeys
# REFUSE engine-source trees by design — this repo upgrades via git pull).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/.kickoff/instance.env"
DB="$ROOT/memory-retrieval/memory-index.db"

log() { printf 'bringup: %s\n' "$*"; }
die() { printf 'bringup: FAILED — %s\n' "$*" >&2; exit 1; }

# ── preconditions ─────────────────────────────────────────────────────────────
[ -f "$ROOT/scripts/core-manifest.txt" ] \
  || die "not an engine-source checkout ($ROOT has no scripts/core-manifest.txt). For adopting \
kickoff into a normal repo, see ADOPT.md."
[ -z "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ] \
  || die "git tree is dirty — commit or stash first. (This turnkey rebuilds derived state; it \
must never interleave with uncommitted work.)"
command -v node >/dev/null 2>&1 || die "node not found on PATH (the retrieval engine needs it)."

# ── (a) init — absent-only, never clobbers ────────────────────────────────────
if [ ! -f "$ENV_FILE" ]; then
  log "(a) no .kickoff/instance.env — running \`kickoff init\` (source-checkout mode)"
  # REPO_DIR: kickoff's front-door guard refuses a detached-HEAD checkout (tag/SHA clone)
  # with no instance.env — REPO_DIR is that guard's own documented escape (scripts/kickoff:196-223).
  REPO_DIR="$ROOT" bash "$ROOT/scripts/kickoff" init
else
  log "(a) .kickoff/instance.env already exists — init skipped (never clobbered)"
fi
[ -f "$ENV_FILE" ] || die "init did not produce $ENV_FILE"

# ── (b) patch instance.env to source mode — idempotent, hand-set values win ───
# Rule per var: absent → append; already the source-mode line → no-op; still the untouched
# SCAFFOLD placeholder (byte-equal to instance.env.example's line) → replace; anything else →
# a value the operator hand-set → leave it, say so. The ${VAR:-…} form keeps an explicit
# caller env winning over the file, matching the file's own convention.
set_var() {   # set_var <name> <source-mode line>
  local name="$1" newline="$2" cur ex
  cur="$(grep -E "^export ${name}=" "$ENV_FILE" | head -1 || true)"
  ex="$(grep -E "^export ${name}=" "$ROOT/scripts/instance.env.example" | head -1 || true)"
  if [ -z "$cur" ]; then
    printf '\n%s\n' "$newline" >> "$ENV_FILE"
    log "(b) $name: appended (was absent)"
  elif [ "$cur" = "$newline" ]; then
    :
  elif [ "$cur" = "$ex" ]; then
    awk -v repl="$newline" -v key="^export ${name}=" '
      $0 ~ key && !done { print repl; done = 1; next } { print }
    ' "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
    log "(b) $name: scaffold placeholder → source-mode value"
  else
    log "(b) $name: hand-set value present — LEFT ALONE ($cur)"
  fi
}

log "(b) patching $ENV_FILE for engine-development mode (self-pinned — see RUNNING.md)"
if ! grep -q "source-checkout mode (scripts/bringup-source-instance.sh)" "$ENV_FILE"; then
cat >> "$ENV_FILE" <<'NOTE'

# ── source-checkout mode (scripts/bringup-source-instance.sh) ──────────────────
# This repo IS the engine source: KICKOFF_CORE_DIR self-pins to THIS tree so the memory
# plugin/hook seam runs the checkout you are developing, not a pulled core clone. Do NOT
# `kickoff pull` here — an engine-source tree upgrades via git pull (by design).
NOTE
fi
set_var KICKOFF_CORE_DIR  "export KICKOFF_CORE_DIR=\"\${KICKOFF_CORE_DIR:-$ROOT}\""
set_var MEMORY_DIR        "export MEMORY_DIR=\"\${MEMORY_DIR:-$ROOT/memory}\""
set_var MEMORY_DB         "export MEMORY_DB=\"\${MEMORY_DB:-$ROOT/memory-retrieval/memory-index.db}\""
set_var MEMORY_HOOK_LOG   "export MEMORY_HOOK_LOG=\"\${MEMORY_HOOK_LOG:-$ROOT/memory-retrieval/retrieval-log.jsonl}\""
set_var MEMORY_INDEX      "export MEMORY_INDEX=\"\${MEMORY_INDEX:-memory/MEMORY.md}\""
set_var TELEGRAM_STATE_DIR "export TELEGRAM_STATE_DIR=\"\${TELEGRAM_STATE_DIR:-\$HOME/.claude/channels/telegram-$(basename "$ROOT")}\""
log "(b) source-mode values: KICKOFF_CORE_DIR=$ROOT · MEMORY_DIR=$ROOT/memory · db+log in memory-retrieval/"

# ── (b2) SEMANTIC EMBEDDER — the recall hook's floors are calibrated for it ────
# The hook's strength gate surfaces a turn only if SOME hit clears a bar on the keyword
# arm OR the vector arm. On a 'hashing-stub' index meta.semantic is false, so the vector
# arm is out of play — and .claude/settings.json runs the hook at BM25 floor -8.0, a
# STRICTER bar than this corpus's best keyword score (measured: bm25=-5.33). Net: a stub
# index makes the hook surface NOTHING on every turn while retrieve.mjs still answers
# perfectly well. A fresh clone hits this by default: memory-retrieval/node_modules is
# gitignored, so @xenova/transformers is absent and the indexer silently picks the stub.
#
# NODE VERSION IS AN INPUT HERE. @xenova/transformers hard-depends on sharp (a regular
# dependency, not optional — it cannot be skipped), and sharp falls back to a node-gyp
# build when no prebuilt binary matches. A PRE-RELEASE node has no published headers, so
# that build 404s and the whole install dies. Second-machine report, 2026-08-27: a box
# whose `mise latest` resolved to node 26.8.0-alpha failed here. The alpha breaks only the
# BUILD — N-API addons load fine under it at runtime — so the fix is to run the install
# ONCE under a stable node, not to pin the box or change its default.
NODE_V="$( node -p 'process.version' 2>/dev/null || echo unknown )"
case "$NODE_V" in
  *-alpha*|*-beta*|*-rc*|*-nightly*|*-pre*)
    log "(b2) NOTE: node is a PRE-RELEASE ($NODE_V). Native builds 404 on unpublished headers."
    log "(b2)       If the install below fails, run it once under a stable node — see the hint." ;;
esac
log "(b2) ensuring the semantic embedder (a stub index leaves the recall hook silent) …"
if ( cd "$ROOT/memory-retrieval" && node install-model.mjs --if-needed ); then
  log "(b2) semantic embedder ready"
else
  log "(b2) WARN: the semantic model did NOT install (node $NODE_V). Continuing — step (d)"
  log "(b2)       checks the real consumer and fails loudly if recall is dead. Likely causes:"
  log "(b2)       • no network (the model is fetched once, then durable in ~/.cache/kickoff-models)"
  log "(b2)       • a PRE-RELEASE node: the sharp node-gyp build 404s on headers that were never"
  log "(b2)         published. Runtime is fine under it — only the BUILD needs a stable node:"
  log "(b2)             mise exec node@22 -- node memory-retrieval/install-model.mjs"
  log "(b2)             (nvm: nvm exec 22 node …   volta: volta run --node 22 node …)"
  log "(b2)         then re-run this script. Do NOT pin the repo or change the box default."
fi

# ── (c) FIRST INDEX BUILD — deliberately from scratch ─────────────────────────
# A db already on disk was built by hand under whatever env was live at the time — untrusted.
# Move it aside (gitignored: memory-index.db-*) and rebuild from the tracked corpus.
# -e (not -f): a directory at the db path is equally untrusted — move it aside too,
# don't die behind an opaque sqlite error on the rebuild.
if [ -e "$DB" ]; then
  bak="$DB.bak-$(date +%Y%m%d-%H%M%S)"
  mv "$DB" "$bak"
  log "(c) existing index moved aside (untrusted manual build): ${bak##*/}"
fi
log "(c) building the retrieval index from $ROOT/memory …"
( cd "$ROOT" && MEMORY_DIR="$ROOT/memory" REPO_DIR="$ROOT" MEMORY_DB="$DB" \
  node --experimental-sqlite memory-retrieval/index.mjs ) || die "index build failed (see output above)"

# ── (d) VERIFY by consumed state, not exit codes ──────────────────────────────
# An exit 0 proves the command ran; a RETRIEVAL HIT proves the machinery a session will
# actually use. (Repo lesson: a check must assert on what the system consumes.)
[ -s "$DB" ] || die "verification: no non-trivial index db at $DB"
VOUT="$( cd "$ROOT" && MEMORY_DIR="$ROOT/memory" REPO_DIR="$ROOT" MEMORY_DB="$DB" \
  node --experimental-sqlite memory-retrieval/retrieve.mjs "read the operator early" --json )" \
  || die "verification: retrieval query failed"
printf '%s' "$VOUT" | grep -q "read-the-operator-early" \
  || die "verification: retrieval answered but did not surface memory/read-the-operator-early.md"
log "(d) retrieval verified: 'read the operator early' → memory/read-the-operator-early.md"

# The query engine is NOT the consumer. A session recalls through the UserPromptSubmit
# hook, which adds a relevance cutoff whose floors live in .claude/settings.json — so a
# stub index passes the retrieve check above and still surfaces nothing on a real turn.
# Run the hook command VERBATIM out of settings.json, exactly as the session runs it.
HOOK_CMD="$( node -e '
const fs = require("fs");
try {
  const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  for (const g of ((s.hooks || {}).UserPromptSubmit) || [])
    for (const h of (g.hooks || []))
      if (h.command && /memory/i.test(h.command)) { console.log(h.command); process.exit(0); }
} catch (e) {}
process.exit(1);' "$ROOT/.claude/settings.json" 2>/dev/null )" || HOOK_CMD=""
if [ -z "$HOOK_CMD" ]; then
  log "(d) WARN: no memory hook found in .claude/settings.json — consumer check SKIPPED (not a pass)"
else
  HOUT="$( printf '%s' '{"prompt":"read the operator early"}' \
    | ( cd "$ROOT" && CLAUDE_PROJECT_DIR="$ROOT" REPO_DIR="$ROOT" sh -c "$HOOK_CMD" ) 2>/dev/null )" || true
  case "$HOUT" in
    *retrieved-memory*)
      log "(d) recall HOOK verified: a real turn surfaces memory (settings.json floors, the true consumer)" ;;
    *)
      printf '%s\n' \
        "bringup: FAILED — the recall hook surfaced NOTHING on a real turn." \
        "  The index built and retrieve.mjs answers, but the hook's relevance cutoff rejects" \
        "  every hit. Near-certain cause: the index was built with the 'hashing-stub' embedder," \
        "  whose vector arm is inert, while .claude/settings.json runs the hook at a keyword" \
        "  floor the stub cannot clear. Recall would be DEAD in every session." \
        "  Fix (needs network, once):  ( cd memory-retrieval && node install-model.mjs )" \
        "  then re-run this script. Check which embedder the index used:" \
        "    grep -a 'embedder' <(node --experimental-sqlite -e \\" \
        "      \"const{DatabaseSync}=require('node:sqlite');const d=new DatabaseSync('$DB');\\" \
        "       console.log(JSON.stringify(d.prepare('select key,value from meta').all()))\")" >&2
      exit 1 ;;
  esac
fi
CR_OUT="$( cd "$ROOT" && bash scripts/crew-review-due.sh 2>&1 )" && CR_RC=0 || CR_RC=$?
case "$CR_OUT" in
  DUE*|NOT_DUE*) log "(d) crew-review-due verdict: $CR_OUT" ;;
  *) die "verification: crew-review-due printed an unexpected verdict (rc=$CR_RC): $CR_OUT" ;;
esac
[ "$CR_RC" -ne 2 ] || die "verification: crew-review-due exited 2 (not an instance) — init step failed"

# ── (e) NEXT ACTIONS — the acceptance proofs (P1–P4) ───────────────────────────
cat <<'NEXT'

bringup: DONE — this engine-source clone is a working kickoff instance.
Idempotent: re-run after `git pull` to re-patch + rebuild the index.

NEXT ACTIONS (acceptance proofs — a human walks these once):
  P1. fresh opencode session in this repo → the memory_search tool answers a query
      (e.g. "read the operator early") with real memory hits.
  P2. fresh claude session in this repo → the recall hook surfaces memory on a turn
      (and the hook's stderr stays quiet — no "first index build not done").
      Step (d) above already ran this hook verbatim and required a hit — walk it anyway:
      the origin is not the deployment.
  P3. add/remove a temp file under memory/ → the SAME TURN reindexes it (auto-reindex);
      remove the temp file afterwards.
  P4. bash scripts/crew-review-due.sh → prints DUE or NOT_DUE (never exit 2).
NEXT

# ── the Telegram footer is a SUGGESTION, and a suggestion must be silenceable ──────────────
# Reported by a second box 2026-08-27: that machine is deliberately local-only, and a turnkey
# that ends by proposing Telegram every single run is noise the operator has to re-decide each
# time. `.kickoff/local-only` is the marker; it is instance-local (`.kickoff/` is gitignored),
# changes no behaviour, and only silences this offer. Nothing else reads it — an instance that
# later wants a channel just deletes the file.
if [ -f "$ROOT/.kickoff/local-only" ]; then
  cat <<'LOCALONLY'
LOCAL-ONLY (.kickoff/local-only is present) — Telegram steering is deliberately not offered
  on this instance. Delete that file to get the setup hint back.
LOCALONLY
else
  cat <<'NEXT2'
OPTIONAL — live Telegram steering (needs YOUR bot token; nothing here wires it):
  create a bot with BotFather, then follow RUNNING.md ("Many instances in parallel") to
  point TELEGRAM_STATE_DIR's channel at it. Without this, the instance is fully local.
  Staying local on purpose?  touch .kickoff/local-only   — and this run stops suggesting it.
NEXT2
fi
