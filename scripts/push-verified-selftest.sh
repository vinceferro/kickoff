#!/usr/bin/env bash
# push-verified-selftest.sh — prove the read-back can FAIL, or it verifies nothing.
#
#   bash scripts/push-verified-selftest.sh
#
# Every green lane here asserts on the REMOTE'S OWN STATE (git --git-dir rev-parse
# against the bare repo), never on the script's printed words — the script's whole
# thesis is that a claimant's output is not evidence, and a suite that trusted the
# script's "PUSH-VERIFIED" line would just re-create the failure the script exists
# to close (assert on what the SYSTEM consumes, not the claimant's report).
#
# RED-first lanes mirror the two live incidents:
#   · lane 3 — the push NEVER RAN (a-checkpoint-is-not-done-until-the-remote-moved,
#     2026-08-27: TRACKER said "pushed", origin was 3 commits behind). Proven with a
#     mutant of the real script whose `git push` is disabled — the read-back must
#     turn that into a MISMATCH, not a verified.
#   · lane 4 — push from a STALE REF (verify-the-ref-you-push-from, 2026-07-26: a
#     force-push of a stale local main rolled the public front door back 14
#     versions). The pre-push both-ends resolve must REFUSE.
#
# The last lane is the suite's own negative control: an always-verify stub must be
# caught by the independent remote assertion — a suite that has never seen itself
# go red is measuring nothing.
#
# Hermetic: local bare repos as remotes, no network.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PV="$HERE/push-verified.sh"
PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }

# fixture: a work repo ($1/src) with one commit, wired to a bare remote ($1/remote.git)
mkfixture() {
  mkdir -p "$1/src"
  git init -q -b main "$1/src"
  git -C "$1/src" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "c1"
  git init -q --bare "$1/remote.git"
  git -C "$1/src" remote add origin "$1/remote.git"
}
commit_more() { git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$2"; }
remote_sha()  { git --git-dir="$1/remote.git" rev-parse --verify "$2" 2>/dev/null; }

echo "▶ push-verified self-test (push, then read the remote back)"

# ── 1. GREEN: a real push to a temp bare repo verifies ─────────────────────────
S=$(mktemp -d); mkfixture "$S"
want="$(git -C "$S/src" rev-parse main)"
out="$(cd "$S/src" && bash "$PV" origin main:refs/heads/main 2>&1)"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "PUSH-VERIFIED origin refs/heads/main ${want:0:7}"; then
  ok "real push verifies: PUSH-VERIFIED names the remote, ref, and ${want:0:7}"
else
  bad "expected 'PUSH-VERIFIED origin refs/heads/main ${want:0:7}' rc=0, got rc=$rc: $out"
fi
# INDEPENDENT: the remote's own answer, not the script's words.
[ "$(remote_sha "$S" refs/heads/main)" = "$want" ] \
  && ok "independent read: the bare remote really holds ${want:0:7}" \
  || bad "INDEPENDENT READ DISAGREES — remote has '$(remote_sha "$S" refs/heads/main)', wanted $want"
rm -rf "$S"

# ── 2. multiple refspecs in one invocation ─────────────────────────────────────
S=$(mktemp -d); mkfixture "$S"
(cd "$S/src" && git branch feature && git tag v0.1) || true
w_main="$(git -C "$S/src" rev-parse main)"; w_feat="$(git -C "$S/src" rev-parse feature)"; w_tag="$(git -C "$S/src" rev-parse v0.1)"
out="$(cd "$S/src" && bash "$PV" origin main:refs/heads/main feature:refs/heads/feature v0.1:refs/tags/v0.1 2>&1)"; rc=$?
n=$(printf '%s' "$out" | grep -c '^PUSH-VERIFIED')
if [ $rc -eq 0 ] && [ "$n" -eq 3 ]; then ok "three refspecs pushed, three PUSH-VERIFIED lines"
else bad "expected rc=0 with 3 PUSH-VERIFIED lines, got rc=$rc with $n: $out"; fi
[ "$(remote_sha "$S" refs/heads/feature)" = "$w_feat" ] && [ "$(remote_sha "$S" refs/tags/v0.1)" = "$w_tag" ] \
  && ok "independent read: both extra refs landed at their resolved SHAs" \
  || bad "independent read disagrees on feature/tag ($w_feat / $w_tag)"
rm -rf "$S"

# ── 3. RED-first (incident 2026-08-27): the push NEVER RAN → must FAIL ─────────
# A mutant of the real script with `git push` no-op'd — the tracker-said-pushed
# shape. The read-back must turn it into a MISMATCH; a green here means the whole
# script is bookkeeping.
S=$(mktemp -d); mkfixture "$S"
MUT="$S/pv-mutant.sh"; sed 's|^git push |true # mutated: |' "$PV" > "$MUT"
out="$(cd "$S/src" && bash "$MUT" origin main:refs/heads/main 2>&1)"; rc=$?
if [ $rc -ne 0 ] && ! printf '%s' "$out" | grep -q '^PUSH-VERIFIED'; then
  if printf '%s' "$out" | grep -q 'MISMATCH'; then
    ok "RED: push-never-ran mutant FAILS with a named MISMATCH (rc=$rc)"
  else
    bad "mutant failed (rc=$rc) but without a named MISMATCH: $out"
  fi
else
  bad "FAIL-OPEN: the push never ran yet the script reported success (rc=$rc): $out"
fi
[ -z "$(remote_sha "$S" refs/heads/main)" ] && ok "independent read: remote ref absent, as the incident" \
  || bad "remote unexpectedly holds the ref"
rm -rf "$S"

# ── 4. RED-first (incident 2026-07-26): push from a STALE ref must be REFUSED ──
S=$(mktemp -d); mkfixture "$S"
(cd "$S/src" && bash "$PV" origin main:refs/heads/main >/dev/null 2>&1)   # remote at c1
commit_more "$S/src" "c2"; commit_more "$S/src" "c3"
git -C "$S/src" push -q origin main:refs/heads/main                       # raw git: arrange remote at c3
c3="$(git --git-dir="$S/remote.git" rev-parse refs/heads/main)"
c1="$(git -C "$S/src" rev-parse main~2)"
git -C "$S/src" update-ref refs/heads/main "$c1"                          # STALE local: back at c1
out="$(cd "$S/src" && bash "$PV" --force origin main:refs/heads/main 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'BEHIND'; then
  ok "RED: stale-local-ref force push REFUSED with the BEHIND relationship named (rc=$rc)"
else
  bad "stale-ref force push not refused (rc=$rc): $out"
fi
[ "$(remote_sha "$S" refs/heads/main)" = "$c3" ] \
  && ok "independent read: the remote was NOT rolled back (still $c3)" \
  || bad "THE 2026-07-26 INCIDENT REPRODUCED — remote rolled back to $(remote_sha "$S" refs/heads/main)"
# the override is a deliberate decision, and once made, verifies honestly
out="$(cd "$S/src" && PUSH_VERIFIED_ALLOW_BACKWARDS=1 bash "$PV" --force origin main:refs/heads/main 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ "$(remote_sha "$S" refs/heads/main)" = "$c1" ] \
  && ok "ALLOW_BACKWARDS=1 --force proceeds and verifies the deliberate rollback" \
  || bad "override path broken (rc=$rc): $out"
rm -rf "$S"

# ── 5. detached HEAD: verify WHAT WAS PUSHED, not where a branch points ────────
S=$(mktemp -d); mkfixture "$S"
commit_more "$S/src" "c2"; commit_more "$S/src" "c3"
c2="$(git -C "$S/src" rev-parse main~1)"
git -C "$S/src" checkout -q --detach "$c2"
out="$(cd "$S/src" && bash "$PV" origin HEAD:refs/heads/det 2>&1)"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "PUSH-VERIFIED origin refs/heads/det ${c2:0:7}"; then
  ok "detached-HEAD push verifies the PUSHED sha ${c2:0:7} (not the branch tip)"
else
  bad "detached push should verify ${c2:0:7}, got rc=$rc: $out"
fi
[ "$(remote_sha "$S" refs/heads/det)" = "$c2" ] && ok "independent read: remote det == detached sha" \
  || bad "remote det is '$(remote_sha "$S" refs/heads/det)', wanted $c2"
# explicit SHA source (the memory's recommended form: push a SHA you verified)
c1="$(git -C "$S/src" rev-parse main~2)"
out="$(cd "$S/src" && bash "$PV" origin "$c1":refs/heads/bysha 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ "$(remote_sha "$S" refs/heads/bysha)" = "$c1" ] \
  && ok "explicit '<sha>:<dst>' push verifies at the pinned SHA" \
  || bad "sha push failed (rc=$rc): $out"
rm -rf "$S"

# ── 6. push landed but read-back UNREADABLE → exit 2 UNVERIFIED, never verified ─
# A git shim on PATH fails every `ls-remote` and passes everything else through,
# so the push is REAL while the read-back cannot see the remote — the honest
# distinction "push probably landed, but that is a claim" must be made.
S=$(mktemp -d); mkfixture "$S"
mkdir -p "$S/bin"
REAL_GIT="$(command -v git)"
printf '#!/usr/bin/env bash\nif [ "$1" = "ls-remote" ]; then echo "fatal: simulated network failure" >&2; exit 128; fi\nexec %q "$@"\n' "$REAL_GIT" > "$S/bin/git"
chmod +x "$S/bin/git"
out="$(cd "$S/src" && PATH="$S/bin:$PATH" bash "$PV" origin main:refs/heads/main 2>&1)"; rc=$?
if [ $rc -eq 2 ] && ! printf '%s' "$out" | grep -q '^PUSH-VERIFIED' && printf '%s' "$out" | grep -q 'UNVERIFIED'; then
  ok "unreadable read-back → exit 2 UNVERIFIED (distinct from push-failed and from verified)"
else
  bad "expected rc=2/UNVERIFIED and no PUSH-VERIFIED, got rc=$rc: $out"
fi
printf '%s' "$out" | grep -q 'PROBABLY landed' \
  && ok "the message distinguishes 'landed, unread' from 'did not land'" \
  || bad "missing the honest landed-but-unverified framing: $out"
want="$(git -C "$S/src" rev-parse main)"
[ "$(remote_sha "$S" refs/heads/main)" = "$want" ] \
  && ok "independent read: the push DID land (the exit-2 is honesty, not a false failure)" \
  || bad "the push did not actually land — lane's premise broken"
rm -rf "$S"

# ── 7. a genuinely failed push (dead remote) → PUSH FAILED, exit 1 ─────────────
S=$(mktemp -d); mkfixture "$S"
out="$(cd "$S/src" && bash "$PV" "$S/no-such-remote.git" main:refs/heads/main 2>&1)"; rc=$?
if [ $rc -eq 1 ] && ! printf '%s' "$out" | grep -q '^PUSH-VERIFIED' && printf '%s' "$out" | grep -qi 'FAILED'; then
  ok "dead remote → PUSH FAILED, exit 1, nothing verified"
else
  bad "dead remote should be exit 1/PUSH FAILED, got rc=$rc: $out"
fi
rm -rf "$S"

# ── 8. no refspecs: upstream derivation (the plain `git push` habit) ───────────
S=$(mktemp -d); mkfixture "$S"
(cd "$S/src" && bash "$PV" origin main:refs/heads/main >/dev/null 2>&1)
git -C "$S/src" config branch.main.remote origin
git -C "$S/src" config branch.main.merge refs/heads/main
out="$(cd "$S/src" && bash "$PV" 2>&1)"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q '^PUSH-VERIFIED'; then
  ok "no-args run derives the upstream pair and verifies the up-to-date ref"
else
  bad "no-args upstream derivation failed (rc=$rc): $out"
fi
# detached + no refspec must refuse (the blind default the 2026-07-26 memory bans)
git -C "$S/src" checkout -q --detach HEAD
out="$(cd "$S/src" && bash "$PV" 2>&1)"; rc=$?
[ $rc -ne 0 ] && printf '%s' "$out" | grep -qi 'detached' \
  && ok "detached HEAD with no refspec refuses and names the fix" \
  || bad "detached no-refspec should refuse loudly, got rc=$rc: $out"
rm -rf "$S"

# ── 9. deletes verify as absent ────────────────────────────────────────────────
# (a feature branch, not the remote's HEAD — bare repos refuse deleting HEAD.)
S=$(mktemp -d); mkfixture "$S"
(cd "$S/src" && git branch feature && bash "$PV" origin feature:refs/heads/feature >/dev/null 2>&1)
out="$(cd "$S/src" && bash "$PV" --delete origin feature 2>&1)"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q '^PUSH-VERIFIED origin refs/heads/feature (deleted)'; then
  ok "--delete push verifies as absent-on-remote"
else
  bad "--delete should verify '(deleted)', got rc=$rc: $out"
fi
# the classic ':'-colon form, no flag
(cd "$S/src" && git branch feature2 && git -C "$S/src" push -q origin feature2:refs/heads/feature2)
out="$(cd "$S/src" && bash "$PV" origin :refs/heads/feature2 2>&1)"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q '^PUSH-VERIFIED origin refs/heads/feature2 (deleted)'; then
  ok "':<ref>' colon-form delete verifies too"
else
  bad "colon-form delete should verify '(deleted)', got rc=$rc: $out"
fi
[ -z "$(remote_sha "$S" refs/heads/feature)" ] && [ -z "$(remote_sha "$S" refs/heads/feature2)" ] \
  && ok "independent read: both refs gone from the remote" \
  || bad "remote still holds a deleted ref"
rm -rf "$S"

# ── 10. unenumerable/deceptive flags are refused, not waved through ────────────
S=$(mktemp -d); mkfixture "$S"
for fl in --all --mirror --tags --dry-run; do
  out="$(cd "$S/src" && bash "$PV" "$fl" origin 2>&1)"; rc=$?
  if [ $rc -ne 0 ] && ! printf '%s' "$out" | grep -q '^PUSH-VERIFIED'; then
    ok "refused: $fl (the read-back must enumerate what it verifies)"
  else
    bad "$fl must be refused — a blind read-back is fake verification (rc=$rc)"
  fi
done
rm -rf "$S"

# ── 11. RED-first (review HOLD H1, 2026-08-28): force over an UNKNOWN tip ────
# The 2026-07-26 shape with the object store blind: cloneA sits at c1, a second
# clone advances the remote to c3, cloneA never fetches — c3 is not in its object
# store, so "git itself will enforce fast-forward" fired while the push carried
# --force, which DISABLES exactly that enforcement: the rollback c3→c1 landed AND
# printed PUSH-VERIFIED. Must be refused; the remote must not move.
S=$(mktemp -d); mkfixture "$S"
(cd "$S/src" && git push -q origin main:refs/heads/main)            # remote at c1
git clone -q "$S/remote.git" "$S/other"
commit_more "$S/other" "c2"; commit_more "$S/other" "c3"
git -C "$S/other" push -q origin main:refs/heads/main               # remote now at c3
c3="$(git --git-dir="$S/remote.git" rev-parse refs/heads/main)"
if git -C "$S/src" cat-file -e "$c3" 2>/dev/null; then
  bad "fixture broken: src already holds c3 — the lane would prove nothing"
else
  out="$(cd "$S/src" && bash "$PV" --force origin main:refs/heads/main 2>&1)"; rc=$?
  if [ $rc -ne 0 ] && ! printf '%s' "$out" | grep -q '^PUSH-VERIFIED' && printf '%s' "$out" | grep -q 'BEHIND'; then
    ok "RED: force over a locally-UNKNOWN remote tip fails closed — tip fetched and classified (rc=$rc)"
  else
    bad "FORCE LAUNDERS THROUGH: unknown-tip force push not refused-and-classified (rc=$rc): $out"
  fi
  [ "$(remote_sha "$S" refs/heads/main)" = "$c3" ] \
    && ok "independent read: the remote was NOT rolled back c3→c1" \
    || bad "THE ROLLBACK LANDED — remote at $(remote_sha "$S" refs/heads/main), was $c3"
fi
rm -rf "$S"

# ── 12. RED-first (review HOLD H2): a published tag is never re-cut ──────────
# The tag-refusal guard was `[ "$dst" = refs/tags/* ]` — single-bracket test, no
# glob, ALWAYS false: the refusal never fired and git's own non-FF rejection was
# the only thing standing (with no refusal message, no fail-closed posture).
S=$(mktemp -d); mkfixture "$S"
commit_more "$S/src" "c2"
git -C "$S/src" -c user.email=t@t -c user.name=t tag -a v1 -m v1 main~1
(cd "$S/src" && bash "$PV" origin v1:refs/tags/v1 >/dev/null 2>&1)  # tag published at c1
old="$(git --git-dir="$S/remote.git" rev-parse refs/tags/v1)"
git -C "$S/src" -c user.email=t@t -c user.name=t tag -f -a v1 -m v1b main                            # re-cut locally at c2
out="$(cd "$S/src" && bash "$PV" origin v1:refs/tags/v1 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'published tag'; then
  ok "RED: re-cutting a published tag is REFUSED by name, not left to git (rc=$rc)"
else
  bad "tag re-cut refusal did not fire as such (rc=$rc): $out"
fi
[ "$(remote_sha "$S" refs/tags/v1)" = "$old" ] \
  && ok "independent read: the published tag still points at the ORIGINAL object" \
  || bad "the published tag moved ($(remote_sha "$S" refs/tags/v1) ≠ $old)"
rm -rf "$S"

# ── 13. RED-first (review HOLD H2): tag→branch push peels to the commit ──────
# The peel guard had the same dead-glob bug, so the read-back compared the remote
# branch against the TAG object SHA → every honest tag→branch push MISMATCHed.
S=$(mktemp -d); mkfixture "$S"
commit_more "$S/src" "c2"
git -C "$S/src" -c user.email=t@t -c user.name=t tag -a v0.9 -m v09 main
peeled="$(git -C "$S/src" rev-parse 'v0.9^{commit}')"
tagobj="$(git -C "$S/src" rev-parse v0.9)"
if [ "$peeled" = "$tagobj" ]; then
  bad "fixture broken: v0.9 is not annotated (tag object == commit) — peel unprovable"
else
  out="$(cd "$S/src" && bash "$PV" origin v0.9:refs/heads/fromtag 2>&1)"; rc=$?
  if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "PUSH-VERIFIED origin refs/heads/fromtag ${peeled:0:7}"; then
    ok "tag→branch push verifies the PEELED commit ${peeled:0:7}, not the tag object"
  else
    bad "tag→branch should verify the peeled commit, got rc=$rc: $out"
  fi
  [ "$(remote_sha "$S" refs/heads/fromtag)" = "$peeled" ] \
    && ok "independent read: the remote branch holds the commit, not the tag object" \
    || bad "remote fromtag is '$(remote_sha "$S" refs/heads/fromtag)', wanted $peeled"
fi
rm -rf "$S"

# ── 14. RED-first (review HOLD H2): dst qualification per src namespace ──────
# The qualify step had the same dead glob, so 'main:main' (a BRANCH src) hit the
# SHA-source error — the wrong message — instead of qualifying to refs/heads/.
S=$(mktemp -d); mkfixture "$S"
want="$(git -C "$S/src" rev-parse refs/heads/main)"
out="$(cd "$S/src" && bash "$PV" origin main:main 2>&1)"; rc=$?
if [ $rc -eq 0 ] && [ "$(remote_sha "$S" refs/heads/main)" = "$want" ]; then
  ok "unqualified dst after a BRANCH src qualifies to refs/heads/ and verifies"
else
  bad "branch-src unqualified dst should qualify to refs/heads/main (rc=$rc): $out"
fi
out="$(cd "$S/src" && bash "$PV" origin "$want":bysha 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q "unqualified destination 'bysha' for SHA source"; then
  ok "unqualified dst after a SHA src still fails with the CORRECT qualification error"
else
  bad "SHA-src unqualified dst must fail naming the refs/heads/ form (rc=$rc): $out"
fi
rm -rf "$S"

# ── 15. negative control: an always-verify stub must be caught ─────────────────
# The stub does no push and no read-back, just prints the magic line and exits 0.
# The suite must catch it via the INDEPENDENT remote assertion — this is the proof
# that the greens above assert on the system, not on the tool's own words.
S=$(mktemp -d); mkfixture "$S"
STUB="$S/stub.sh"; printf '#!/usr/bin/env bash\necho "PUSH-VERIFIED origin refs/heads/main abc1234"\nexit 0\n' > "$STUB"
out="$(cd "$S/src" && bash "$STUB" 2>&1)"; rc=$?
if [ $rc -eq 0 ] && [ -z "$(remote_sha "$S" refs/heads/main)" ]; then
  ok "always-verify stub caught: prints PUSH-VERIFIED, remote has NOTHING (assert-on-system works)"
else
  bad "negative control broken: stub rc=$rc or remote unexpectedly populated"
fi
rm -rf "$S"

# ── 16. RED-first (re-review HOLD HIGH-1, 2026-08-28): BUNDLED short force ────
# git accepts flag clusters: `-uf` carries force where the token scan for ' -f '
# can't see it — same unknown-tip rollback shape as lane 11, flag hidden in a
# cluster. Over-detection must be fail-closed, so the refusal is the pass.
S=$(mktemp -d); mkfixture "$S"
(cd "$S/src" && git push -q origin main:refs/heads/main)
git clone -q "$S/remote.git" "$S/other"
commit_more "$S/other" "c2"; commit_more "$S/other" "c3"
git -C "$S/other" push -q origin main:refs/heads/main
c3="$(git --git-dir="$S/remote.git" rev-parse refs/heads/main)"
if git -C "$S/src" cat-file -e "$c3" 2>/dev/null; then
  bad "fixture broken: src already holds c3 — the lane would prove nothing"
else
  out="$(cd "$S/src" && bash "$PV" -uf origin main:refs/heads/main 2>&1)"; rc=$?
  if [ $rc -ne 0 ] && ! printf '%s' "$out" | grep -q '^PUSH-VERIFIED' && printf '%s' "$out" | grep -q 'BEHIND'; then
    ok "RED: bundled -uf force over a locally-UNKNOWN tip fails closed like --force (rc=$rc)"
  else
    bad "BUNDLED FORCE LAUNDERS: -uf unknown-tip push not refused-and-classified (rc=$rc): $out"
  fi
  [ "$(remote_sha "$S" refs/heads/main)" = "$c3" ] \
    && ok "independent read: the remote was NOT rolled back c3→c1 under -uf" \
    || bad "THE ROLLBACK LANDED via -uf — remote at $(remote_sha "$S" refs/heads/main), was $c3"
fi
rm -rf "$S"

# ── 17. LOW-1 (re-review): die paths leave no mktemp scratch ─────────────────
# The EXIT traps are real but were unpinned — a regression here shipped green.
# Die via the tag re-cut refusal (a path that creates its pre-read mktemps first)
# under a private TMPDIR and assert nothing survives.
S=$(mktemp -d); mkfixture "$S"
commit_more "$S/src" "c2"
git -C "$S/src" -c user.email=t@t -c user.name=t tag -a v1 -m v1 main~1
(cd "$S/src" && bash "$PV" origin v1:refs/tags/v1 >/dev/null 2>&1)   # publish at c1
git -C "$S/src" -c user.email=t@t -c user.name=t tag -f -a v1 -m v1b main  # re-cut locally
mkdir -p "$S/tmp"
out="$(cd "$S/src" && TMPDIR="$S/tmp" bash "$PV" origin v1:refs/tags/v1 2>&1)"; rc=$?
leftovers="$(ls -A "$S/tmp" 2>/dev/null | wc -l)"
if [ $rc -ne 0 ] && [ "$leftovers" -eq 0 ]; then
  ok "die path leaves ZERO mktemp scratch under a private TMPDIR (trap pinned)"
else
  bad "tmp hygiene broken: rc=$rc, $leftovers leftover file(s): $(ls -A "$S/tmp" 2>/dev/null | tr '\n' ' ')"
fi
rm -rf "$S"

# ── 18. LOW-2 (re-review): bare-src dies with the CORRECT remedy ─────────────
# 'origin main' (no dst) used to die claiming "empty destination … a delete is
# ':<dst>'" — the delete remedy, wrong for a bare src. It must name the
# dst-default shape instead.
S=$(mktemp -d); mkfixture "$S"
out="$(cd "$S/src" && bash "$PV" origin main 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q "no destination in refspec 'main'" && ! printf '%s' "$out" | grep -q 'empty destination'; then
  ok "bare-src refusal names the dst-default remedy, not the delete remedy"
else
  bad "bare-src message wrong or missing (rc=$rc): $out"
fi
rm -rf "$S"

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && printf '  ✅ push-verified enforced (RED on push-never-ran · stale-ref · unreadable-remote; GREEN only on a matching read-back)\n'
[ "$FAIL" -eq 0 ]
