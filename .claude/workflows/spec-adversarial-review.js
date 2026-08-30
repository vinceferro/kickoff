/**
 * Pre-build adversarial spec review (opt-in).
 *
 * The shift-left sibling of `pr-adversarial-review`: stress-tests a PRODUCT SPEC
 * or build PLAN *before* it becomes code — the cheapest place to catch a flawed
 * assumption, a missed scenario, or wrong sequencing. Fans out spec-lens
 * reviewers that VERIFY the plan's claims against the live code/docs (a plan
 * that asserts "field X is already available" is worthless if X doesn't exist),
 * then a synthesis agent adjudicates a build/refine verdict.
 *
 * Run it via the Workflow tool:
 *   Workflow({ name: "spec-adversarial-review", args: { doc: "/abs/path/to/plan.md" } })
 *   // optional: args.context = "extra grounding for the reviewers"
 *
 * WHEN: before committing eng to a substantial spec/plan (a multi-day build,
 * a new product surface, anything with non-trivial assumptions). Lighter than
 * the code gate (no per-finding adversarial-verify round — a synthesis agent
 * adjudicates instead), but still opt-in, not automatic.
 *
 * After it returns: if verdict is `revise-first`, send the findings back to the
 * spec's author to re-cut the slices, then re-read before building. Spot-check
 * the decisive claims yourself (agent findings get the same scrutiny as code).
 */
export const meta = {
  name: 'spec-adversarial-review',
  description: 'Opt-in pre-build review of a product spec/plan — spec-lens reviewers verify claims vs live code, synthesis adjudicates a build/refine verdict',
  whenToUse: 'Before committing eng to a substantial spec or build plan. Pass the doc path as args.doc.',
  phases: [
    { title: 'Review', detail: 'spec-lens reviewers stress-test the plan vs live code' },
    { title: 'Synthesize', detail: 'adjudicate findings into a build/refine verdict' },
  ],
}

const DOC = args && (args.doc ?? args.spec ?? args.path ?? (typeof args === 'string' ? args : undefined))
if (!DOC) {
  log('No spec path provided. Invoke with args: { doc: "/abs/path/to/plan.md" }.')
  return { error: 'missing args.doc', usage: 'Workflow({ name: "spec-adversarial-review", args: { doc: "/abs/path/plan.md" } })' }
}
const EXTRA = (args && args.context) ? `\n\nExtra grounding:\n${args.context}` : ''

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
          kind: { type: 'string', enum: ['wrong-assumption', 'gap', 'sequencing', 'value', 'risk', 'scope'] },
          severity: { type: 'string', enum: ['blocker', 'should-fix', 'nice-to-have'] },
          detail: { type: 'string', description: 'The concern + concrete evidence (file/line or doc quote)' },
          recommendation: { type: 'string' },
        },
        required: ['title', 'kind', 'severity', 'detail', 'recommendation'],
      },
    },
  },
  required: ['findings'],
}

const VERDICT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    verdict: { type: 'string', enum: ['build-as-is', 'build-with-tweaks', 'revise-first'] },
    summary: { type: 'string' },
    blockers: { type: 'array', items: { type: 'string' } },
    should_fix: { type: 'array', items: { type: 'string' } },
    first_slice_assessment: { type: 'string', description: 'Is the recommended first slice the right first move, and is its done-test sufficient?' },
  },
  required: ['verdict', 'summary', 'blockers', 'should_fix', 'first_slice_assessment'],
}

const CONTEXT = `
Adversarial review of a PRODUCT SPEC / build PLAN (not code): "${DOC}".
Read the full doc first. Then VERIFY its claims against the live code/docs — do NOT take the plan's
word for it. A plan that asserts data/behavior already exists is worthless if it doesn't; that class
of wrong-assumption is the highest-value thing to catch. Use rg/Read across the repo, and read any
referenced vault docs.

Be adversarial but specific — cite file:line or a doc quote for each finding. An empty findings
array is a valid, valuable answer. cwd is the repo root.${EXTRA}
`

const LENSES = [
  { key: 'assumptions-evidence', prompt: `Lens: ASSUMPTIONS & EVIDENCE. Verify the plan's factual claims against the actual code/data model. Does the data the plan relies on actually exist where it says (DTO fields, columns, context/providers, existing dependencies)? Is anything the plan calls "already done" / "trivial" / "no migration needed" actually true? A wrong premise invalidates the slice — RESOLVE the plan's stated assumptions, don't restate them.` },
  { key: 'completeness-gaps', prompt: `Lens: COMPLETENESS & GAPS. What real-world scenarios / states / edge cases does the plan MISS? Consider the unhappy paths, the "other" jurisdictions/currencies/roles/tenants, empty/null/absent data, and whether the slice leaves a visible correctness gap that undermines the very claim it makes.` },
  { key: 'value-sequencing', prompt: `Lens: VALUE & SEQUENCING. Is the recommended first move genuinely the highest-value, lowest-risk, end-to-end-verifiable slice — or is there a cheaper/more-valuable one? Would a REAL user actually care about this slice first, or is it polish? Is the done-test sufficient to truly call it done (does it test the customer outcome, not just "code runs")? Are the estimates realistic?` },
  { key: 'risk-crossfunction', prompt: `Lens: RISK & CROSS-FUNCTION. Legal/compliance/financial-representation risk (are we claiming or displaying something that needs human/legal sign-off)? Security/privacy/data-scope risk? Eng-feasibility risk (hidden coupling, regen/migration cost the plan ignores)? Does the slice align with the product thesis, or drift?` },
]

phase('Review')
const reviews = await parallel(LENSES.map((l) => () =>
  agent(`${CONTEXT}\n\n${l.prompt}`, { label: `spec-lens:${l.key}`, phase: 'Review', schema: FINDINGS_SCHEMA })
))

const allFindings = reviews.filter(Boolean).flatMap((r) => r.findings || [])
log(`Spec review of ${DOC}: ${allFindings.length} raw finding(s) across ${LENSES.length} lenses; synthesizing`)

phase('Synthesize')
const synthesis = await agent(
  `${CONTEXT}\n\nThe four spec-lens reviewers returned these findings (deduplicate, drop nitpicks, weigh severity, resolve contradictions by reading the code yourself):\n\n${JSON.stringify(allFindings, null, 2)}\n\nProduce one adjudicated verdict: is the plan sound to build as-is, build with tweaks, or revise first? List the true blockers + should-fixes, and assess whether the recommended first slice is the right first move with a sufficient done-test. Be decisive.`,
  { label: 'synthesize-verdict', phase: 'Synthesize', schema: VERDICT_SCHEMA }
)

return {
  doc: DOC,
  verdict: synthesis ? synthesis.verdict : 'unknown',
  synthesis,
  raw_finding_count: allFindings.length,
}
