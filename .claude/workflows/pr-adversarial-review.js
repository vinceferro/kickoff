/**
 * Pre-merge adversarial review gate (opt-in).
 *
 * Fans out independent dimension reviewers over a PR diff, then adversarially
 * verifies every finding (refute-by-default) before reporting, so plausible-but-
 * wrong findings don't survive. Catches the class of bug a single self-review
 * pass misses — the value is INDEPENDENCE (fresh reviewers that didn't write the
 * code) + ADVERSARIAL framing + MULTIPLE perspectives.
 *
 * Run it via the Workflow tool:
 *   Workflow({ name: "pr-adversarial-review", args: { pr: 131 } })
 *
 * WHEN to run: substantial or security-sensitive PRs, before merge.
 * WHEN NOT to run: trivial / mechanical changes — a quick self-review suffices.
 * It is token-intensive (a couple dozen agents) — hence opt-in, never automatic.
 *
 * After it returns: verify each confirmed finding against the code yourself, fix,
 * then run a LIGHT targeted re-review on just the fix diff (a fix can introduce
 * its own edge). Converge — don't spiral into endless rounds once a fix is a
 * direct port of already-proven code.
 */
export const meta = {
  name: 'pr-adversarial-review',
  description: 'Opt-in pre-merge adversarial review of a PR diff — fan out dimension reviewers, adversarially verify each finding, synthesize confirmed bugs',
  whenToUse: 'Before merging a substantial or security-sensitive PR. Pass the PR number as args.pr. Token-intensive — skip for trivial changes.',
  phases: [
    { title: 'Review', detail: 'independent dimension reviewers hunt bugs in the PR diff' },
    { title: 'Verify', detail: 'refute-by-default skeptics adversarially verify each finding' },
  ],
}

const PR = args && (args.pr ?? args.PR ?? args)
if (!PR || (typeof PR !== 'number' && typeof PR !== 'string')) {
  log('No PR number provided. Invoke with args: { pr: <number> }.')
  return { error: 'missing args.pr', usage: 'Workflow({ name: "pr-adversarial-review", args: { pr: 131 } })' }
}

const FINDINGS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          title: { type: 'string' },
          file: { type: 'string' },
          line: { type: 'string' },
          severity: { type: 'string', enum: ['P1', 'P2', 'P3'] },
          description: { type: 'string', description: 'The bug + the concrete scenario that triggers it' },
          why_real: { type: 'string', description: 'Why this is a genuine defect, not a false positive' },
        },
        required: ['title', 'file', 'line', 'severity', 'description', 'why_real'],
      },
    },
  },
  required: ['findings'],
}

const VERDICT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    real: { type: 'boolean', description: 'true only if a genuine defect that can actually occur in the shipped code' },
    severity: { type: 'string', enum: ['P1', 'P2', 'P3', 'not-a-bug'] },
    reasoning: { type: 'string' },
  },
  required: ['real', 'severity', 'reasoning'],
}

const CONTEXT = `
Adversarial pre-merge review of PR #${PR}. cwd is the repo root.

Get the exact diff and the changed-file list:
  gh pr diff ${PR}
  gh pr diff ${PR} --name-only
Read the FULL changed files for context (not just the diff hunks) — a bug often
lives in the interaction between the changed lines and the surrounding code.

You are an adversarial reviewer hunting REAL, shippable bugs. Be specific about
the exact scenario that triggers each one. Do NOT pad with style nits or
speculative "could maybe". If your dimension surfaces nothing real, return an
empty findings array — that is a valid and valuable answer.
`

const DIMENSIONS = [
  { key: 'correctness-logic', prompt: `Dimension: CORRECTNESS & LOGIC. Hunt: null/undefined dereferences, off-by-one, inverted/short-circuited conditions, wrong operator, mishandled error paths, swallowed errors that hide failures, unhandled edge cases (empty/zero/missing/duplicate), incorrect defaults, type-unsafe casts that mask a real type bug.` },
  { key: 'security-privacy', prompt: `Dimension: SECURITY & PRIVACY. Hunt: secrets/credentials/PII leaking to logs, analytics, URLs, or responses; authz/authn gaps or scope confusion; missing input validation / injection; fail-OPEN where it should fail-closed (or vice-versa); screening/fraud verdicts exposed to the subject; tokens or signatures mishandled. Be concrete about what leaks or what an attacker does.` },
  { key: 'concurrency-state-effects', prompt: `Dimension: CONCURRENCY, STATE & EFFECTS. Hunt: races between async operations, effect-ordering bugs, stale closures, missing/over-broad dependency arrays, missing cleanup/cancellation, double-fire, SSR-vs-CSR divergence, state churn/loss, ordering assumptions that don't hold, queue/drain ordering bugs.` },
  { key: 'api-contract-wiring', prompt: `Dimension: API / CONTRACT / WIRING. Hunt: request/response or DTO field mismatches, wrong/missing properties, event or handler wired to the wrong thing, calls that double-fire or never fire, off-by-one in pagination/limits, generated-client vs spec drift, a caller and callee that disagree on shape or nullability.` },
  { key: 'regressions-integration', prompt: `Dimension: REGRESSIONS & INTEGRATION. Hunt: ways this diff breaks previously-correct behavior, backwards-incompat changes, integration points that now mismatch, migrations/data assumptions, build/SSR hazards, a "fix" that introduces a new edge in the area it touches.` },
]

phase('Review')
const results = await pipeline(
  DIMENSIONS,
  (d) => agent(`${CONTEXT}\n\n${d.prompt}`, { label: `review:${d.key}`, phase: 'Review', schema: FINDINGS_SCHEMA }),
  (review, d) => {
    const findings = (review && review.findings) || []
    if (!findings.length) return []
    return parallel(findings.map((f) => () =>
      parallel([0, 1].map((i) => () =>
        agent(
          `You are an adversarial verifier. DEFAULT to real:false unless you can PROVE the bug is genuine by reading the actual code.\n\n${CONTEXT}\n\nClaimed bug (dimension ${d.key}):\n- title: ${f.title}\n- file: ${f.file}:${f.line}\n- severity: ${f.severity}\n- description: ${f.description}\n- author's why_real: ${f.why_real}\n\nRead the real code at ${f.file} (and the diff via 'gh pr diff ${PR}'). Decide: is this a REAL, shippable defect that can actually occur, or a false positive / already-handled / not-in-this-diff? Verifier instance ${i}.`,
          { label: `verify:${d.key}:${String(f.file).split('/').pop()}`, phase: 'Verify', schema: VERDICT_SCHEMA }
        )
      )).then((verdicts) => {
        const v = verdicts.filter(Boolean)
        const realVotes = v.filter((x) => x.real).length
        return { ...f, verifier_votes: `${realVotes}/${v.length}`, confirmed: realVotes >= 1 }
      })
    ))
  }
)

const all = results.flat().filter(Boolean)
const confirmed = all.filter((f) => f.confirmed)
const dismissed = all.filter((f) => !f.confirmed)
log(`PR #${PR} review: ${confirmed.length} confirmed finding(s), ${dismissed.length} dismissed as false-positive`)
return {
  pr: PR,
  verdict: confirmed.length === 0 ? 'CLEAN — no confirmed findings' : `${confirmed.length} finding(s) to address`,
  confirmed: confirmed
    .sort((a, b) => a.severity.localeCompare(b.severity))
    .map((f) => ({ severity: f.severity, title: f.title, file: `${f.file}:${f.line}`, votes: f.verifier_votes, description: f.description })),
  dismissed: dismissed.map((f) => ({ title: f.title, file: `${f.file}:${f.line}`, votes: f.verifier_votes })),
}
