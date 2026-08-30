#!/usr/bin/env bash
# channel-offer-selftest.sh — the one-command channel setup must be safe with a SECRET.
#
#   bash scripts/channel-offer-selftest.sh
#
# `kickoff adopt` ends by offering to write this project's bot token. That is the one setup step no
# agent may perform (memory/credential-guard-blocks-channel-relay.md) and the one input that must
# never leak — so every property here is a security property, not a nicety:
#
#   · a piped/CI run must NOT hang and must NOT write (silence is never consent — the [ -t 0 ] rule)
#   · an empty or malformed token must fail CLOSED (a typo written as real = a 401 far from the cause)
#   · an existing token must never be re-prompted, re-read, or printed
#   · the token must never reach stdout, a log, or shell history; the file must be 0600
#   · the channel dir must come from the TARGET's instance.env, never the caller's env (the leak that
#     once registered an adoptee on the dev worker's channel)
#
# Hermetic: sources the function out of scripts/kickoff, mktemp dirs, no live channel touched.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
KO="$HERE/kickoff"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -r "$KO" ] || { printf '  ❌ scripts/kickoff not readable\n'; exit 1; }
grep -q '^_offer_channel_setup()' "$KO" || { printf '  ❌ _offer_channel_setup() is gone from scripts/kickoff\n'; exit 1; }
ok "located _offer_channel_setup() in scripts/kickoff"

# Extract the function AND EVERY KICKOFF FUNCTION IT CALLS, so we exercise the REAL source.
# _offer_channel_setup delegates the owner prompt to _offer_channel_owner; extracting only the
# former left that call undefined, so the pairing lanes went RED against correct code — a harness
# that doesn't match the real shape, which is the same mistake that keeps biting today. Assert the
# dependency is present rather than trusting the awk.
FN="$(mktemp)"; trap 'rm -f "$FN"' EXIT
{
  printf 'log()     { printf "[kickoff] %%s\\n" "$*"; }\n'
  printf 'mark_ok() { printf "  ok %%s\\n" "$*"; }\n'
  printf 'mark_no() { printf "  no %%s\\n" "$*"; }\n'
  awk '/^_offer_channel_owner\(\) \{/,/^\}/' "$KO"
  awk '/^_offer_channel_setup\(\) \{/,/^\}/' "$KO"
} > "$FN"
bash -n "$FN" || { bad "the extracted function is not valid bash"; }
# every kickoff helper the extracted body calls must BE in the extract, or a lane fails for a
# harness reason and reads as a real defect.
for _dep in $(awk '/^_offer_channel_setup\(\) \{/,/^\}/' "$KO" | grep -oE '_offer_[a-z_]+' | sort -u); do
  grep -q "^${_dep}() {" "$FN" \
    || bad "harness gap: _offer_channel_setup calls ${_dep}(), which is NOT in the extract"
done

run() { # run <stdin-content> <state-dir> [tty?] → output; never a tty here (pipes = the CI shape)
  printf '%s' "$1" | bash -c ". '$FN'; _offer_channel_setup '$2'" 2>&1
}

# ── 1. piped stdin: must NOT hang, must NOT write, must SAY how to do it ─────────────────────────
SD="$(mktemp -d)/chan"
out="$(timeout 20 bash -c "printf 'y\n123456:ABCdefGHI\n' | bash -c \". '$FN'; _offer_channel_setup '$SD'\"" 2>&1)"
rc=$?
[ "$rc" -ne 124 ] && ok "piped run does not hang (the prompt never blocks CI)" \
                  || bad "piped run HUNG — a prompt on a pipe blocks forever"
[ -e "$SD/secret.env" ] && bad "piped run WROTE a token — silence/pipe was taken as consent" \
                        || ok "piped run wrote nothing (silence is never consent)"
case "$out" in *"secret.env"*) ok "piped run tells the operator where to put the token themselves" ;;
  *) bad "piped run gave no instructions — a CI user is left stuck" ;; esac
rm -rf "$(dirname "$SD")"

# ── 1b. THE v0.12 BOX: a token in the DEAD file only must NOT count as configured ────────────────
# The sentinel bug. "Is the token configured?" was answered by secret.env — the file core-v0.12
# wrote and NOTHING reads. So every box that ran v0.12 was PERMANENTLY unfixable: adopt saw
# secret.env, reported "already in place", skipped the prompt, and the two real files stayed
# missing. Re-running adopt — the documented repair — could never heal it. The operator diagnosed it
# from the outside: "it won't ask the token, I think it has it somewhere and it skips it."
# A sentinel must be a file the SYSTEM depends on, or it reports on a world nobody lives in.
if command -v script >/dev/null 2>&1; then
  SDV="$(mktemp -d)/chan"; RV="$(mktemp -d)/repo"; mkdir -p "$SDV" "$RV/.claude"
  printf 'export TELEGRAM_BOT_TOKEN=999:OLDDEADTOKEN\n' > "$SDV/secret.env"   # exactly the v0.12 state
  FNV="$(mktemp)"
  {
    printf 'log()     { printf "[k] %%s\\n" "$*"; }\n'
    printf 'mark_ok() { printf "  ok %%s\\n" "$*"; }\n'
    printf 'mark_no() { printf "  no %%s\\n" "$*"; }\n'
    printf 'REPO_DIR=%s\n' "$RV"
    awk '/^_write_token_into_settings_local\(\) \{/,/^\}/' "$KO"
    awk '/^_offer_channel_owner\(\) \{/,/^\}/' "$KO"
    awk '/^_offer_channel_setup\(\) \{/,/^\}/' "$KO"
  } > "$FNV"
  outv="$(printf 'y\n123456789:AAEhNEWTOKEN\n555000\n' \
    | timeout 25 script -qec "bash -c \". '$FNV'; _offer_channel_setup '$SDV'\"" /dev/null 2>&1)"
  case "$outv" in
    *"already in place"*|*"already wired"*)
      bad "SENTINEL: a token in the DEAD file counted as configured — a v0.12 box can NEVER be repaired by re-running adopt" ;;
    *) ok "SENTINEL: a token in secret.env alone does NOT count as configured (it re-asks)" ;;
  esac
  [ -s "$SDV/.env" ] && grep -q 'AAEhNEWTOKEN' "$SDV/.env" \
    && ok "SENTINEL: re-asking repairs the v0.12 box — the NEW token reaches the real read path" \
    || bad "SENTINEL: the v0.12 box was not repaired — .env still missing/stale"
  grep -q 'OLDDEAD' "$SDV/.env" 2>/dev/null \
    && bad "the OLD dead token was reused — a credential must never be read back and reshaped" \
    || ok "the old dead token is never read back or reused (the operator re-enters it)"
  rm -rf "$(dirname "$SDV")" "$(dirname "$RV")" "$FNV"
fi

# ── 2. a WIRED channel is never re-prompted, never read, never printed ───────────────────────────
# The fixture must be a channel that is ACTUALLY wired — .env + settings.local.json, the files that
# are read. It used to seed only secret.env, which encoded the sentinel bug into the suite itself:
# it asserted that the dead file counted as configured, so the suite would have DEFENDED the bug that
# left a v0.12 box permanently unrepairable. A fixture built from the wrong file proves the wrong thing.
SD="$(mktemp -d)/chan"; RW="$(mktemp -d)/repo"; mkdir -p "$SD" "$RW/.claude"
printf 'export TELEGRAM_BOT_TOKEN=999:SUPERSECRETCANARY\n' > "$SD/secret.env"
printf 'TELEGRAM_BOT_TOKEN=999:SUPERSECRETCANARY\n' > "$SD/.env"
# 999:SUPERSECRETCANARY is an invented canary, not a credential. It must LOOK like a token for case 2
# to mean anything (the assertion is that it never reaches stdout); the JSON form is what
# settings.local.json actually holds, and that shape is what scan-secrets flags HIGH.
printf '{"env":{"TELEGRAM_BOT_TOKEN":"999:SUPERSECRETCANARY","TELEGRAM_STATE_DIR":"%s"}}\n' "$SD" > "$RW/.claude/settings.local.json"  # pragma: allowlist secret
before="$(cat "$SD/secret.env")"
FNW2="$(mktemp)"
{
  printf 'log()     { printf "[kickoff] %%s\\n" "$*"; }\n'
  printf 'mark_ok() { printf "  ok %%s\\n" "$*"; }\n'
  printf 'mark_no() { printf "  no %%s\\n" "$*"; }\n'
  printf 'REPO_DIR=%s\n' "$RW"
  awk '/^_write_token_into_settings_local\(\) \{/,/^\}/' "$KO"
  awk '/^_offer_channel_owner\(\) \{/,/^\}/' "$KO"
  awk '/^_offer_channel_setup\(\) \{/,/^\}/' "$KO"
} > "$FNW2"
out="$(timeout 20 bash -c "bash -c \". '$FNW2'; _offer_channel_setup '$SD'\" </dev/null" 2>&1)"
case "$out" in *SUPERSECRETCANARY*) bad "THE EXISTING TOKEN WAS PRINTED — a secret reached stdout" ;;
  *) ok "an existing token is never printed (no secret on stdout)" ;; esac
case "$out" in *"already wired"*) ok "a WIRED channel short-circuits the offer (no re-prompt)" ;;
  *) bad "a wired channel did not short-circuit — it would re-prompt or overwrite a working token" ;; esac
[ "$(cat "$SD/secret.env")" = "$before" ] && ok "an existing token file is left byte-identical" \
                                          || bad "an existing token file was MODIFIED"
# THE RESUME CASE — token wired, allowlist ABSENT. Not hypothetical: the first version of this flow
# wrote the token and stopped, so early adopters sit in exactly this state with a mute bot. If the
# token-wired path just returns, "re-run adopt" (the obvious remedy) fixes NOTHING and the channel
# stays silent forever. It must finish the job.
case "$out" in
  *"no OWNER"*|*"NO OWNER"*|*"telegram user id"*|*"/telegram:access"*)
    ok "RESUME: a wired token WITHOUT an allowlist still offers the owner step (re-running adopt repairs it)" ;;
  *) bad "RESUME BROKEN: token-wired + allowlist-absent short-circuits — a mute bot that re-running adopt cannot fix" ;;
esac
rm -rf "$(dirname "$SD")" "$(dirname "$RW")" "$FNW2"

# ── 3. structural: the token must never be echoed or logged ──────────────────────────────────────
body="$(awk '/^_offer_channel_setup\(\) \{/,/^\}/' "$KO")"
case "$body" in *"stty -echo"*) ok "input is hidden while typing (stty -echo)" ;;
  *) bad "no stty -echo — the token would be visible on screen" ;; esac
if printf '%s' "$body" | grep -qE '(log|mark_ok|mark_no|printf|echo)[^\n]*\$_tok'; then
  bad "the token variable is interpolated into an output call — it could reach a log"
else
  ok "the token variable is never interpolated into log/print output"
fi
case "$body" in *'umask 077'*) ok "the secret is created under umask 077 (never world-readable, even briefly)" ;;
  *) bad "no umask 077 — the file could exist world-readable before chmod lands" ;; esac
case "$body" in *'chmod 600'*) ok "the secret file is chmod 600" ;;
  *) bad "no chmod 600 on the secret file" ;; esac

# ── 3b. POSITIVE CONTROL — it must actually WRITE at a real terminal ─────────────────────────────
# Without this, every assertion above passes on a function that writes NOTHING, EVER. Needs a real
# pty ([ -t 0 ]), so drive it through script(1) with the answers piped IN.
#
# NB we deliberately do NOT assert the token is absent from the pty transcript: piping dumps both
# lines at once, so the tty echoes the token at the [y/N] read (where echo is correctly still on)
# before `stty -echo` runs. A human types it only after the hidden prompt renders — verified by hand:
# the `token (hidden):` line is followed by nothing. The echo property is covered structurally above.
if command -v script >/dev/null 2>&1; then
  SD="$(mktemp -d)/chan"
  printf 'y\n123456789:AAEhTESTONLYTOKEN\n' \
    | timeout 25 script -qec "bash -c \". '$FN'; _offer_channel_setup '$SD'\"" /dev/null >/dev/null 2>&1
  if [ -s "$SD/secret.env" ]; then
    ok "POSITIVE CONTROL: a valid token at a real tty IS written (the offer is not a no-op)"
    [ "$(stat -c %a "$SD/secret.env" 2>/dev/null)" = "600" ] \
      && ok "the written secret is mode 600 on disk (not just in the source)" \
      || bad "the written secret is NOT 600 on disk — mode $(stat -c %a "$SD/secret.env" 2>/dev/null)"
    grep -q 'TELEGRAM_BOT_TOKEN=123456789:AAEhTESTONLYTOKEN' "$SD/secret.env" \
      && ok "the token is stored verbatim under TELEGRAM_BOT_TOKEN" \
      || bad "the stored token is mangled — the bridge would 401"

    # THE LANE THAT WAS MISSING — and it is the whole point. The first version wrote ONLY secret.env,
    # a file NOTHING reads, and passed every check here: written, 0600, not echoed, not logged, fails
    # closed. Every property except DOES THIS DO ANYTHING. The operator's bot sat mute for an hour.
    # Verified against the plugin source + a working adopter, not by plausibility:
    #   · the BRIDGE reads   $TELEGRAM_STATE_DIR/.env       (plugin: ENV_FILE = join(STATE_DIR,'.env'))
    #   · the ANNOUNCE reads $REPO_DIR/.claude/settings.local.json → .env.TELEGRAM_BOT_TOKEN
    # A token in a file nobody reads is not a configured channel; it is a silent no-op.
    [ -s "$SD/.env" ] && grep -q '^TELEGRAM_BOT_TOKEN=123456789:AAEhTESTONLYTOKEN$' "$SD/.env" \
      && ok "READ-PATH: the token reaches <state-dir>/.env — the file the BRIDGE actually reads" \
      || bad "READ-PATH: <state-dir>/.env missing/wrong — the bridge cannot authenticate; the channel is mute"
    [ "$(stat -c %a "$SD/.env" 2>/dev/null)" = "600" ] \
      && ok "<state-dir>/.env is 0600" || bad "<state-dir>/.env is not 0600"

    # A TOKEN IS NOT A CHANNEL. With a token but no access.json the bot has no OWNER: the startup
    # announce reads the chat id from `.allowFrom[0]` and, finding no file, skips — so the worker
    # runs in TOTAL SILENCE. That is exactly what shipped this morning and what the operator hit
    # the same day (announce.count=3, announce.last=absent, zero pings). Saying "token written"
    # and stopping IMPLIES the channel works. It does not.
    SDP="$(mktemp -d)/chan"     # a FRESH dir: no secret.env, no access.json — the real first-run shape
    out_tok="$(printf 'y\n123456789:AAEhTESTONLYTOKEN\n' \
      | timeout 25 script -qec "bash -c \". '$FN'; _offer_channel_setup '$SDP'\"" /dev/null 2>&1)"
    case "$out_tok" in
      *"/telegram:access"*) ok "a token WITHOUT an allowlist surfaces the pairing step (not 'done')" ;;
      *) bad "a token with no access.json reported success and stopped — the worker would start SILENT" ;;
    esac
    # Match the MEANING, not one casing: the tty path says "no OWNER … starts SILENT", the piped
    # path says "NO OWNER". Both must explain WHY silence happens, or the user is left guessing —
    # which is exactly the experience this whole lane exists to prevent.
    if printf '%s' "$out_tok" | grep -qiE 'no (owner|pings)|accepts nobody|start (and say )?NOTHING|starts SILENT'; then
      ok "it says WHY (the bot has no owner → silence), not just what to type"
    else
      bad "the pairing step is unexplained — the user cannot tell why silence happened"
    fi
    # …and with an allowlist ALREADY present it must NOT nag about pairing.
    SDA="$(mktemp -d)/chan"; mkdir -p "$SDA"
    printf '{"dmPolicy":"allowlist","allowFrom":[123]}\n' > "$SDA/access.json"
    out_pair="$(printf 'y\n123456789:AAEhTESTONLYTOKEN\n' \
      | timeout 25 script -qec "bash -c \". '$FN'; _offer_channel_setup '$SDA'\"" /dev/null 2>&1)"
    case "$out_pair" in
      *"NO OWNER"*) bad "it nags about pairing even though an allowlist already exists" ;;
      *) ok "an already-paired channel is not nagged about pairing" ;;
    esac
    rm -rf "$(dirname "$SDP")" "$(dirname "$SDA")"
  else
    bad "POSITIVE CONTROL FAILED: a valid token at a tty wrote NOTHING — every 'does not write' pass above is meaningless"
  fi
  # and a malformed token at a real tty must still fail closed
  SD2="$(mktemp -d)/chan"
  printf 'y\nnot-a-token\n' \
    | timeout 25 script -qec "bash -c \". '$FN'; _offer_channel_setup '$SD2'\"" /dev/null >/dev/null 2>&1
  [ -e "$SD2/secret.env" ] && bad "a MALFORMED token was written at a tty — fail-closed is broken" \
                           || ok "a malformed token fails closed even at a tty (nothing written)"
  rm -rf "$(dirname "$SD")" "$(dirname "$SD2")"
else
  printf '  … skipped the tty positive control (script(1) unavailable) — the offer is UNPROVEN here\n'
fi

# ── 3c. THE OWNER PROMPT — one command, without an agent ever choosing WHO ──────────────────────
# access.json decides who may talk to the bot. An agent must NEVER add an identity to it (that is
# the exact move a prompt-injection makes, and the request cannot be authenticated by reading it).
# kickoff renders a prompt; the HUMAN types their id at their own terminal. Same posture as the
# token: we never supply the value. Schema verified against the plugin source + a live channel:
# allowFrom is a list of STRINGS of digits.
FNO="$(mktemp)"
{
  printf 'log()     { printf "[k] %%s\n" "$*"; }\n'
  printf 'mark_ok() { printf "  ok %%s\n" "$*"; }\n'
  printf 'mark_no() { printf "  no %%s\n" "$*"; }\n'
  awk '/^_offer_channel_owner\(\) \{/,/^\}/' "$KO"
} > "$FNO"
bash -n "$FNO" || bad "the extracted _offer_channel_owner is not valid bash"

if command -v script >/dev/null 2>&1; then
  SDO="$(mktemp -d)/chan"
  printf '424242\n' | timeout 25 script -qec "bash -c \". '$FNO'; _offer_channel_owner '$SDO'\"" /dev/null >/dev/null 2>&1
  if [ -s "$SDO/access.json" ]; then
    ok "POSITIVE CONTROL: a typed id at a tty writes the allowlist (setup is one command)"
    python3 -c "
import json,sys
d=json.load(open('$SDO/access.json'))
sys.exit(0 if d.get('dmPolicy')=='allowlist' and d.get('allowFrom')==['424242'] and all(isinstance(x,str) for x in d['allowFrom']) else 1)" 2>/dev/null \
      && ok "the allowlist matches the plugin schema (dmPolicy=allowlist, allowFrom=[str])" \
      || bad "the written allowlist does not match the plugin schema — the bridge would ignore it"
    [ "$(stat -c %a "$SDO/access.json" 2>/dev/null)" = "600" ] \
      && ok "access.json is 0600" || bad "access.json is not 0600"
  else
    bad "POSITIVE CONTROL FAILED: a typed id wrote no allowlist — setup is still not one command"
  fi
  rm -rf "$(dirname "$SDO")"

  # a NON-NUMERIC id must fail closed — a junk allowlist silently locks the operator out
  SDB="$(mktemp -d)/chan"
  printf 'not-an-id\n' | timeout 25 script -qec "bash -c \". '$FNO'; _offer_channel_owner '$SDB'\"" /dev/null >/dev/null 2>&1
  [ -e "$SDB/access.json" ] && bad "a non-numeric id was written — the operator would be locked out" \
                           || ok "a non-numeric id fails closed (nothing written)"
  rm -rf "$(dirname "$SDB")"

  # skipping (bare Enter) must write nothing
  SDS="$(mktemp -d)/chan"
  printf '\n' | timeout 25 script -qec "bash -c \". '$FNO'; _offer_channel_owner '$SDS'\"" /dev/null >/dev/null 2>&1
  [ -e "$SDS/access.json" ] && bad "skipping still wrote an allowlist" \
                            || ok "skipping writes nothing (pairing by hand stays available)"
  rm -rf "$(dirname "$SDS")"
fi

# an EXISTING allowlist must never be touched — it may hold ids we did not add
SDE="$(mktemp -d)/chan"; mkdir -p "$SDE"
printf '{"dmPolicy":"allowlist","allowFrom":["111","222"],"groups":{},"pending":{},"ackReaction":"x"}\n' > "$SDE/access.json"
before_e="$(cat "$SDE/access.json")"
printf '999\n' | timeout 20 bash -c ". '$FNO'; _offer_channel_owner '$SDE'" >/dev/null 2>&1
[ "$(cat "$SDE/access.json")" = "$before_e" ] \
  && ok "an existing allowlist is left byte-identical (never rewritten, never appended to)" \
  || bad "an existing allowlist was MODIFIED — kickoff must not edit who can reach a bot"
rm -rf "$(dirname "$SDE")"
rm -f "$FNO"

# ── 3d. THE ANNOUNCE'S read path: settings.local.json, merged not clobbered ─────────────────────
# session-run.sh's startup announce reads $REPO_DIR/.claude/settings.local.json → .env.TELEGRAM_BOT_TOKEN.
# That file is THE secret-bearing one and legitimately holds OTHER people's keys (a live adopter here
# carries POSTHOG_PERSONAL_API_KEY beside the telegram token) plus a permissions block — so this must
# MERGE. Clobbering it would silently destroy unrelated credentials.
if command -v script >/dev/null 2>&1; then
  TR="$(mktemp -d)"; TRR="$TR/repo"; TRS="$TR/chan"; mkdir -p "$TRR/.claude"
  printf '{"env":{"OTHER_KEY":"keep-me"},"permissions":{"allow":["Read"]}}\n' > "$TRR/.claude/settings.local.json"
  FNW="$(mktemp)"
  {
    printf 'log()     { printf "[k] %%s\\n" "$*"; }\n'
    printf 'mark_ok() { printf "  ok %%s\\n" "$*"; }\n'
    printf 'mark_no() { printf "  no %%s\\n" "$*"; }\n'
    printf 'REPO_DIR=%s\n' "$TRR"
    awk '/^_write_token_into_settings_local\(\) \{/,/^\}/' "$KO"
    awk '/^_offer_channel_owner\(\) \{/,/^\}/' "$KO"
    awk '/^_offer_channel_setup\(\) \{/,/^\}/' "$KO"
  } > "$FNW"
  printf 'y\n123456789:AAEhTESTONLYTOKEN\n555000\n' \
    | timeout 25 script -qec "bash -c \". '$FNW'; _offer_channel_setup '$TRS'\"" /dev/null >/dev/null 2>&1
  python3 -c "
import json,sys
d=json.load(open('$TRR/.claude/settings.local.json'))
sys.exit(0 if d.get('env',{}).get('TELEGRAM_BOT_TOKEN')=='123456789:AAEhTESTONLYTOKEN' else 1)" 2>/dev/null \
    && ok "READ-PATH: the token reaches settings.local.json — the file the ANNOUNCE actually reads" \
    || bad "READ-PATH: settings.local.json has no token — the worker starts and announces NOTHING"
  python3 -c "
import json,sys
d=json.load(open('$TRR/.claude/settings.local.json'))
sys.exit(0 if d['env'].get('OTHER_KEY')=='keep-me' and d.get('permissions') else 1)" 2>/dev/null \
    && ok "settings.local.json is MERGED — other keys + permissions survive (it holds other secrets)" \
    || bad "settings.local.json was CLOBBERED — unrelated credentials destroyed"
  # a malformed secret-bearing file must never be overwritten
  printf 'not json {{{\n' > "$TRR/.claude/settings.local.json"
  bef="$(cat "$TRR/.claude/settings.local.json")"
  printf 'y\n123456789:AAEhTESTONLYTOKEN\n555000\n' \
    | timeout 25 script -qec "bash -c \". '$FNW'; _offer_channel_setup '$TRS'\"" /dev/null >/dev/null 2>&1
  [ "$(cat "$TRR/.claude/settings.local.json")" = "$bef" ] \
    && ok "a malformed settings.local.json is never clobbered (it may hold secrets)" \
    || bad "a malformed settings.local.json was OVERWRITTEN"
  rm -rf "$TR" "$FNW"
fi

# ── 4. the caller's env must NOT decide the adoptee's channel ────────────────────────────────────
# The real leak: instance.env is `export TELEGRAM_STATE_DIR="${TELEGRAM_STATE_DIR:-}"`, so sourcing
# it while the CALLER exports that var yields the CALLER's channel. adopt must unset before reading.
if grep -q 'unset TELEGRAM_STATE_DIR' "$KO"; then
  ok "adopt unsets TELEGRAM_STATE_DIR before reading the target's instance.env (no caller leak)"
else
  bad "adopt reads the target's instance.env WITHOUT unsetting first — the caller's channel leaks in"
fi

# ── 5. no user-facing instruction may send the operator to the DEAD file ─────────────────────────
# secret.env is written for back-compat but NOTHING reads it: the bridge reads <state>/.env and the
# startup announce reads <repo>/.claude/settings.local.json (session-run.sh's jq on
# .env.TELEGRAM_BOT_TOKEN). Through core-v0.15 two `log`/`mark_no` lines told the operator to "write
# TELEGRAM_BOT_TOKEN into secret.env yourself" — following that instruction reproduces the core-v0.12
# dead-file state exactly: token written, channel silently never works, and re-running adopt was the
# documented repair for precisely that. The CODE learned this lesson; the INSTRUCTIONS had not.
# So: any operator-facing line that names secret.env must also name .env, or it is sending them nowhere.
_bad_instr=0
while IFS= read -r _l; do
  _t="$(printf '%s' "$_l" | sed 's/^[[:space:]]*//')"
  case "$_t" in *secret.env*) ;; *) continue ;; esac
  # Operator-facing PROSE only: a `log "`/`mark_no "` line. Deliberately excludes the write itself
  # (a printf redirecting INTO secret.env is the back-compat write, not an instruction) and comments.
  case "$_t" in 'log "'*|'mark_no "'*) ;; *) continue ;; esac
  # Acceptable when it also names the file that IS read, or when it is warning that secret.env is
  # the wrong place rather than sending the operator there.
  case "$_t" in *'/.env'*|*NOTHING*|*'NOT in the files'*|*'not the live path'*) continue ;; esac
  _bad_instr=$((_bad_instr + 1))
  printf '     ↳ %s\n' "$(printf '%s' "$_t" | cut -c1-120)"
done < "$KO"
if [ "$_bad_instr" -eq 0 ]; then
  ok "no operator-facing instruction points at secret.env alone (the dead file — writing it configures NOTHING)"
else
  bad "$_bad_instr operator-facing line(s) send the operator to secret.env without naming the file that is actually READ"
fi

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && printf '  ✅ channel offer is secret-safe (no hang · no silent write · no leak · 0600 · no dead-file instructions)\n'
[ "$FAIL" -eq 0 ]
