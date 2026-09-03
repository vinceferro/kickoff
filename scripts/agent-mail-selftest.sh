#!/usr/bin/env bash
# agent-mail-selftest.sh — prove the mailbox is READ, not merely written.
#
#   bash scripts/agent-mail-selftest.sh
#
# The failure this suite exists to prevent is one this box has already paid for once: a channel
# that passed 26 checks — written, 0600, never echoed, never logged, fails-closed on a typo — and
# still did not work, because NOTHING READ THE FILE. Every property was asserted except "does the
# consumer see this". A mailbox is the same trap with a friendlier shape: `send` returning 0 proves
# a file exists, and proves nothing about delivery.
#
# So the load-bearing assertions here are all run FROM THE RECIPIENT'S CONTEXT — a separate org
# identity, resolved the way a real worker resolves it — and they assert on the exact command the
# re-ground boot check runs. RED-first: every guard is watched failing on the input it exists to
# catch, because a guard nobody has seen go red is not a guard.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MAIL="$HERE/agent-mail.py"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "▶ agent-mail self-test (a mailbox nobody opens is worse than no mailbox)"
echo

F="$(mktemp -d)"; trap 'rm -rf "$F"' EXIT
export AGENT_MAIL_DIR="$F/mail"

# Two orgs, as real checkouts — the sender resolves its own identity from the repo it stands in,
# so the fixture must be two directories with .git, never one directory with an env override.
# A fixture that matches your own box goes green while the bug is live.
mkdir -p "$F/senderco/.git" "$F/receiverco/.git"
say() { printf '# Field notes\n\nThe gate was green and measured nothing.\n' > "$1"; }
say "$F/note.md"

send_as()  { ( cd "$F/senderco"   && python3 "$MAIL" "$@" ); }
recv_as()  { ( cd "$F/receiverco" && python3 "$MAIL" "$@" ); }

# ── identity is DERIVED, not configured ──────────────────────────────────────────
chk "sender resolves its org from the repo dir name"   "[ \"\$(send_as whoami)\" = senderco ]"
chk "receiver resolves its own, independently"         "[ \"\$(recv_as whoami)\" = receiverco ]"

# ── the boot-check contract: SILENT on a clean box ───────────────────────────────
# This is what makes it safe to wire into every adopter's re-ground. Asserted BEFORE anything is
# sent, so the emptiness is real and not a side effect of a later step.
chk "check prints NOTHING when the inbox is empty"     "[ -z \"\$(recv_as check)\" ]"
chk "check exits 0 on an empty inbox"                  "recv_as check"

# ── deliver ──────────────────────────────────────────────────────────────────────
send_as send --to receiverco --subject "Green that means nothing" --file "$F/note.md" >/dev/null 2>&1
chk "send lands a file in the RECIPIENT's inbox" \
  "ls '$F/mail/receiverco/inbox/'*.md >/dev/null 2>&1"

# THE ASSERTION THIS SUITE IS FOR: the consumer — the recipient's own boot check — sees it.
# Not "a file exists"; the command a real worker runs at re-ground, from the recipient's context.
out="$(recv_as check)"
chk "★ the RECIPIENT's boot check reports the message (the consumer, not the artifact)" \
  "printf '%s' \"\$out\" | grep -q 'Green that means nothing'"
chk "★ …and names the sender, so the reader knows who to answer" \
  "printf '%s' \"\$out\" | grep -q 'from senderco'"
chk "…and prints a runnable read command"               "printf '%s' \"\$out\" | grep -q 'agent-mail.py read'"

# NEGATIVE CONTROL for the check itself: a THIRD org, same box, same store, must stay silent.
# Without this, "check prints the message" could be true of any org — including one nobody wrote to.
mkdir -p "$F/bystanderco/.git"
chk "★ an uninvolved org's check stays silent (the check is scoped, not global)" \
  "[ -z \"\$( cd '$F/bystanderco' && python3 '$MAIL' check )\" ]"

# ── the body survives the trip ───────────────────────────────────────────────────
body="$(recv_as read --keep --all)"
chk "the delivered body is the file that was sent"      "printf '%s' \"\$body\" | grep -q 'measured nothing'"
chk "frontmatter carries from/to/subject/id"            "printf '%s' \"\$body\" | grep -q '^from: senderco' && printf '%s' \"\$body\" | grep -q '^to: receiverco'"
chk "--keep leaves it unread (a print is not a receipt)" "[ -n \"\$(recv_as check)\" ]"

# ── read moves it out of the inbox, exactly once ─────────────────────────────────
recv_as read --all >/dev/null 2>&1
chk "★ after read, the boot check is silent again"      "[ -z \"\$(recv_as check)\" ]"
chk "the message is retained in read/, not destroyed"   "ls '$F/mail/receiverco/read/'*.md >/dev/null 2>&1"
chk "reading an empty inbox is a non-zero no-op"        "! recv_as read --all"

# ── the sender can tell delivery from receipt ────────────────────────────────────
chk "★ sent reports the message as READ once the recipient read it" \
  "send_as sent | grep -q 'read by receiverco'"
send_as send --to receiverco --subject "Second" --file "$F/note.md" >/dev/null 2>&1
chk "★ sent reports an UNREAD message as unread (the state actually tracks)" \
  "send_as sent | grep -q 'UNREAD in receiverco'"

# ── refusals: the cheap mistakes that would rot silently ─────────────────────────
chk "refuses an empty body"                             "! printf '' | send_as send --to receiverco --subject x"
chk "refuses to mail itself"                            "! send_as send --to senderco --subject x --file '$F/note.md'"
chk "refuses a nonexistent --file"                      "! send_as send --to receiverco --subject x --file '$F/nope.md'"
chk "warns when the recipient has no checkout on the box" \
  "send_as send --to typoco --subject x --file '$F/note.md' | grep -q 'typo'"

# ── the checkout probe must find checkouts WHERE THEY LIVE ──────────────────────
# Every checkout on this box is ~/Projects/<org>, never ~/org. The old probe looked only at
# ~/<org>, so correctly addressed mail to a real org drew the "nothing will ever read it"
# warning — a false alarm that trains the reader to ignore the warning that matters. The
# fixture org's checkout sits under $F/Projects with HOME=$F (the probe resolves HOME per
# invocation, the same way MAIL_DIR resolves AGENT_MAIL_DIR), and there is deliberately NO
# $F/herdr-tg — so the OLD probe misfires on exactly the case it exists for.
mkdir -p "$F/Projects/herdr-tg/.git"
proj_out="$( ( cd "$F/senderco" && HOME="$F" python3 "$MAIL" send --to herdr-tg --subject "Real org" --file "$F/note.md" ) 2>&1 )"
chk "★ a REAL org whose checkout lives under ~/Projects gets NO 'nothing will ever read it' warning" \
  "! grep -q 'nothing will ever read it' <<< \"\$proj_out\""
chk "…and delivery still happened (the probe governs the warning, never the send)" \
  "ls '$F/mail/herdr-tg/inbox/'*.md >/dev/null 2>&1"

# An org with a MAILBOX but no checkout anywhere under HOME (legitimately new, or checked out
# on another box): the ⚠ must downgrade to a plain note — a mailbox that already exists is
# plausibly polled, so "nothing will ever read it" would be a lie. The FIRST send creates the
# mailbox; the SECOND must see it and soften.
( cd "$F/senderco" && HOME="$F" python3 "$MAIL" send --to mailboxonlyco --subject "First" --file "$F/note.md" ) >/dev/null 2>&1
note_out="$( ( cd "$F/senderco" && HOME="$F" python3 "$MAIL" send --to mailboxonlyco --subject "Second" --file "$F/note.md" ) 2>&1 )"
chk "an existing mailbox downgrades the no-checkout ⚠ to a plain note" \
  "grep -q 'note:' <<< \"\$note_out\" && ! grep -q 'nothing will ever read it' <<< \"\$note_out\""

# ── stdin path (how an agent pipes a report it just generated) ───────────────────
printf 'piped body\n' | send_as send --to receiverco --subject "From stdin" >/dev/null 2>&1
chk "a piped body is delivered and readable"            "recv_as read 'from-stdin' | grep -q 'piped body'"

# ── atomicity: a half-written message must never be visible to a reader ──────────
# The reader is another agent's check, which can fire at any instant — including mid-write.
chk "no .tmp file is left behind in any inbox"          "! ls '$F/mail/'*/inbox/*.tmp >/dev/null 2>&1"

# ── a broken header must not swallow the message ─────────────────────────────────
printf 'no frontmatter at all, just prose\n' > "$F/mail/receiverco/inbox/20260101T000000Z-raw-hand-dropped.md"
chk "★ a hand-dropped file with no frontmatter is still reported, not skipped" \
  "recv_as check | grep -q 'hand-dropped'"

# ── the printed read-command is a COMMAND, and the id comes from a filename ──────
# `check` renders "read <id>" for the agent to run, and a filename is chosen by whoever sent the
# message. `--help.md` rendered as "read --help": the same option injection the per-turn hook
# spent two review passes eliminating, handed to the reader as an instruction to run.
mkdir -p "$F/mail/receiverco/inbox"
printf -- '---\nfrom: x\nsubject: hostile-name\n---\n\nb\n' > "$F/mail/receiverco/inbox/--help.md"
OPTOUT="$(recv_as check 2>&1)"
chk "check's printed read-command ends option parsing with --" \
  "grep -q 'read -- --help' <<< \"\$OPTOUT\""
chk "and that command READS the message rather than printing argparse help" \
  "recv_as read -- --help 2>&1 | grep -q 'hostile-name'"

echo
printf '  %s  %d passed, %d failed\n' "$( [ "$FAIL" -eq 0 ] && echo '✅' || echo '❌' )" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
