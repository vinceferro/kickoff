/**
 * spec-to-green — the thin slice of the agent-graph model.
 *
 * Five nodes: plan → stress → build ⇄ verify → gate. It is the smallest graph that
 * contains every structural feature the model rests on — a sequential edge, a fan-out
 * with a barrier (borrowed whole from `spec-adversarial-review`), a bounded loop, and a
 * human gate that ends the run cleanly instead of pausing inside it.
 *
 *   Workflow({ name: "spec-to-green", args: { task: "...", repo: "/abs/path" } })
 *
 * args:
 *   task        (required) the brief, in one or two sentences
 *   repo        (required) absolute path the agents work in — never inferred from cwd
 *   stress      default true; false skips the adversarial pass on the plan
 *   maxRounds   default 2  — build⇄verify rounds before the stuck-gate
 *   maxPlans    default 1  — re-plans allowed when the stress verdict is revise-first
 *   maxCalls    default 12 — hard ceiling on agent() calls for the whole run
 *   neverGreen  default false — THE NEGATIVE CONTROL. Makes the exit predicate
 *               unsatisfiable, so the loop must hit maxRounds and raise the stuck-gate.
 *               A graph that spins here is not safe to leave running unattended.
 *
 * TWO THINGS THE DESIGN DOC GOT WRONG, found by writing this file (see §3.1 and §6 of
 * docs/design/agent-graph-model.md):
 *
 *   1. THE SCRIPT CANNOT RUN THE PROOF ITSELF. A workflow script has no filesystem and no
 *      shell. The proof command is run by the `reviewer` agent, which returns the exit code
 *      it observed. The property the doc wanted — "a reviewer that died cannot look like a
 *      reviewer that approved" — survives anyway, because `agent()` returns null when a
 *      subagent dies, and null is read as RED here, never as absence of objection.
 *
 *   2. THE SCRIPT CANNOT WRITE TO MISSION CONTROL either, for the same reason. Node-level
 *      rows are written by the agents themselves (their charters already require it) and
 *      the graph-level lines are written by the coordinator around the run.
 */
export const meta = {
  name: 'spec-to-green',
  description: 'Plan → adversarial stress → build ⇄ verify (bounded) → human gate. The thin slice of the agent-graph model.',
  whenToUse: 'One well-scoped change you want taken from brief to a green runnable proof, with the loop bounded and the ship left to a human. Pass args.task and args.repo.',
  phases: [
    { title: 'Plan', detail: 'planner turns the brief into a plan with a runnable proof' },
    { title: 'Stress', detail: 'adversarial lenses verify the plan against live code' },
    { title: 'Judge', detail: 'after a rejection: re-plan, repair the brief, or ask the human' },
    { title: 'Build', detail: 'builder implements the first slice' },
    { title: 'Verify', detail: 'reviewer re-runs the proof and reports the exit code' },
    { title: 'Gate', detail: 'the run ends at a human decision, it does not pause inside one' },
  ],
}

// ---------------------------------------------------------------- args, pinned hard
// A brief that renders `undefined` into an agent prompt is the failure recorded in
// memory/workflow-brief-must-pin-the-artifact.md: 37 agents reviewed the wrong tree and
// every one of them reported confidently. Abort loudly instead.
const A = args || {}
const TASK = typeof A === 'string' ? A : A.task
const REPO = A.repo
if (!TASK || !REPO) {
  log('REFUSING: spec-to-green needs both args.task and args.repo (absolute).')
  return {
    error: 'missing args',
    usage: 'Workflow({ name: "spec-to-green", args: { task: "...", repo: "/abs/path" } })',
    got: { task: TASK ?? null, repo: REPO ?? null },
  }
}

const STRESS = A.stress !== false
const MAX_ROUNDS = Number.isInteger(A.maxRounds) ? A.maxRounds : 2
const MAX_PLANS = Number.isInteger(A.maxPlans) ? A.maxPlans : 1
const MAX_CALLS = Number.isInteger(A.maxCalls) ? A.maxCalls : 12
const NEVER_GREEN = A.neverGreen === true

// ---------------------------------------------------------------- the call ceiling
// Two ceilings, because they fail differently. `calls` is this graph's own budget and is
// always present. budget.remaining() is the turn-wide token target and may be Infinity —
// guard on budget.total before trusting it, or an unset target reads as "spend forever".
let calls = 0
const RESERVE = 40_000
function ceilingHit() {
  if (calls >= MAX_CALLS) return `call ceiling: ${calls}/${MAX_CALLS} agent calls`
  // `budget` is a harness global; guard its existence so a runtime without it cannot
  // turn the ceiling check itself into the thing that kills the run.
  const b = typeof budget !== 'undefined' ? budget : null
  if (b && b.total && b.remaining() < RESERVE) {
    return `token ceiling: ${Math.round(b.remaining() / 1000)}k left of the turn's target`
  }
  return null
}
async function node(prompt, opts) {
  const stop = ceilingHit()
  if (stop) throw new Error(`STOP — ${stop}`)
  calls += 1
  return agent(prompt, opts)
}

// ---------------------------------------------------------------- schemas
// Edges branch on these fields and on nothing else. An agent's prose is never a branch
// condition; a schema-validated enum or boolean is.
const PLAN_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    plan_path: { type: 'string', description: 'absolute path to the plan file this agent wrote' },
    first_slice: { type: 'string', description: 'the smallest slice that goes green on its own' },
    proof_cmd: { type: 'string', description: 'the exact shell command that proves the slice, runnable in args.repo' },
    negative_control: { type: 'string', description: 'the exact edit that must make proof_cmd fail — a proof never watched go red proves nothing' },
    files: { type: 'array', items: { type: 'string' } },
  },
  required: ['plan_path', 'first_slice', 'proof_cmd', 'negative_control', 'files'],
}

const BUILD_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    implemented: { type: 'boolean' },
    files_changed: { type: 'array', items: { type: 'string' } },
    proof_cmd_run: { type: 'string' },
    exit_code: { type: 'integer', description: 'the REAL exit code observed, never assumed' },
    output_tail: { type: 'string' },
    notes: { type: 'string' },
  },
  required: ['implemented', 'files_changed', 'proof_cmd_run', 'exit_code', 'output_tail', 'notes'],
}

const VERIFY_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    green: { type: 'boolean', description: 'true only if YOU ran the proof and it passed' },
    exit_code: { type: 'integer' },
    negative_control_ran: { type: 'boolean', description: 'did you make the proof fail on purpose and watch it go red?' },
    output_tail: { type: 'string' },
    blockers: { type: 'array', items: { type: 'string' } },
  },
  required: ['green', 'exit_code', 'negative_control_ran', 'output_tail', 'blockers'],
}

// The one place a JUDGE replaced a COUNTER. When adversarial review rejects a plan, something
// must decide what happens next. A number cannot tell "the plan is fixable" from "the BRIEF is
// missing context" — and that distinction cost three runs and three hours on 2026-08-19, where a
// counter re-planned blindly twice while the real defect was a brief that never mentioned code
// the repo already shipped. The model decides; the counter only bounds it.
const JUDGE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    action: { type: 'string', enum: ['replan', 'repair-brief', 'ask-human'] },
    why: { type: 'string', description: 'one or two sentences, naming the evidence' },
    brief_patch: { type: 'string', description: 'for repair-brief: the exact text to ADD to the task brief. Empty otherwise.' },
    question: { type: 'string', description: 'for ask-human: the single question, answerable in a word or a line. Empty otherwise.' },
  },
  required: ['action', 'why', 'brief_patch', 'question'],
}

const GROUND = `
Work in the repository at ${REPO}. Every path you cite must be real and read this session —
never a plausible-looking one. The task:

${TASK}
`

// ---------------------------------------------------------------- 1 + 2. plan, stressed
phase('Plan')
let plan = null
let stress = null
let plans = 0

while (plans <= MAX_PLANS) {
  plans += 1
  const retry = stress && stress.verdict === 'revise-first'
    ? `\n\nA previous plan was rejected by adversarial review. Fix these before anything else:\n${JSON.stringify(stress.synthesis?.blockers ?? [], null, 2)}`
    : ''

  plan = await node(
    `${GROUND}${retry}

Write a build-ready plan and SAVE IT to a file under ${REPO}/docs/plans/ (create the directory if
needed). Return the absolute path you wrote, not the plan's text.

The plan must name a proof_cmd — one shell command, runnable in ${REPO}, that goes green only when
the slice actually works — and a negative_control: the exact edit that makes that command fail. If
you cannot name an edit that makes it fail, the command is not a proof and you must choose another.`,
    { label: `plan${plans > 1 ? `:retry-${plans - 1}` : ''}`, phase: 'Plan', agentType: 'planner', schema: PLAN_SCHEMA },
  )

  if (!plan) return endGate('stuck', 'the planner returned nothing — dispatch died or was skipped', {})

  if (!STRESS) break

  phase('Stress')
  // The child workflow spawns its own agents, and they do NOT pass through node(), so the
  // ceiling cannot see them. Charge its known fixed size (4 lenses + 1 synthesis) to this
  // graph's counter, or a nested call is a hole in the very budget it is meant to respect.
  const CHILD_CALLS = 5
  const preStress = ceilingHit()
  if (preStress) return endGate('stuck', `stopped before the stress pass — ${preStress}`, { plan })
  stress = await workflow('spec-adversarial-review', { doc: plan.plan_path, context: GROUND })
  calls += CHILD_CALLS
  log(`stress verdict: ${stress?.verdict ?? 'unknown'} (${stress?.raw_finding_count ?? 0} raw findings)`)

  if (stress?.verdict !== 'revise-first') break

  phase('Judge')
  const blockers = stress?.synthesis?.blockers ?? []
  const judge = await node(
    `A plan was rejected by adversarial review. Decide what happens next. You are not re-planning
and not re-reviewing — you are choosing between three moves, and choosing wrong is expensive in
both directions.

THE TASK BRIEF AS GIVEN:
${TASK}

THE PLAN: ${plan.plan_path}
ATTEMPT: ${plans} of a hard ceiling of ${MAX_PLANS + 1}.

THE BLOCKERS:
${JSON.stringify(blockers, null, 2)}

Read the plan and enough of the repo to judge the blockers yourself — do not take them on trust,
and do not re-litigate ones that are plainly right.

  replan       — the blockers are about THIS plan and a planner holding them can fix it. Choose
                 this only if the brief already contains everything needed to do so.
  repair-brief — the blockers reveal the BRIEF is missing something the planner could not have
                 known: a capability the repo ALREADY ships, a constraint never stated, a premise
                 that is false. This is the most commonly correct answer and the most commonly
                 missed. The tell: a blocker cites existing code, an existing script, or an
                 existing check that the brief never mentions. Return the exact text to ADD.
  ask-human    — the blockers expose a fork only the operator can settle: a values call, a
                 trade-off between real options, or work whose cost now looks unjustified against
                 what it buys. Return ONE question answerable in a word or a line.

Prefer repair-brief over replan whenever a blocker names something that already exists. A second
plan written from the same incomplete brief usually fails the same way.`,
    { label: `judge:after-plan-${plans}`, phase: 'Judge', schema: JUDGE_SCHEMA },
  )

  if (!judge) return endGate('stuck', 'the judge returned nothing after a rejected plan', { plan, stress })
  log(`judge: ${judge.action} — ${judge.why}`)

  if (judge.action === 'repair-brief') {
    return endGate('brief', `the brief is missing context the planner could not infer: ${judge.why}`, { plan, stress, brief_patch: judge.brief_patch })
  }
  if (judge.action === 'ask-human') {
    return endGate('ask', judge.question || judge.why, { plan, stress })
  }
  // replan — still bounded. The judge chooses; the ceiling is what stops a confident loop.
  if (plans > MAX_PLANS) {
    return endGate('stuck', `the judge asked to re-plan again, but the ceiling of ${MAX_PLANS + 1} plan(s) is reached — ${judge.why}`, { plan, stress })
  }
  log(`re-planning (${plans}/${MAX_PLANS + 1})`)
}

// ---------------------------------------------------------------- 3 + 4. build ⇄ verify
let round = 0
let build = null
let verify = null
let lastRed = ''

while (round < MAX_ROUNDS) {
  round += 1
  const stop = ceilingHit()
  if (stop) return endGate('stuck', `stopped before round ${round} — ${stop}`, { plan, build, verify })

  phase('Build')
  const redo = lastRed ? `\n\nThe previous attempt was rejected. Fix exactly this and nothing else:\n${lastRed}` : ''
  build = await node(
    `${GROUND}${redo}

Implement ONLY the first slice of the plan at ${plan.plan_path}:

  ${plan.first_slice}

Then run the plan's own proof and report the REAL exit code you observed. Never report a code you
did not see. Do not commit. Do not push.

  proof_cmd: ${plan.proof_cmd}`,
    { label: `build:r${round}`, phase: 'Build', agentType: 'builder', schema: BUILD_SCHEMA },
  )

  phase('Verify')
  verify = await node(
    `${GROUND}

An independent check on someone else's work. Do not fix anything you find — report it.

1. Run this yourself, in ${REPO}: ${plan.proof_cmd}
2. Then run the plan's negative control — ${plan.negative_control} — and confirm the same command
   goes RED. Restore the file afterwards and say so. A proof you never watched fail proves nothing.
3. Read the diff for correctness, not just for a passing exit code.

The builder claims exit ${build?.exit_code ?? 'nothing — it returned no result'}. Verify that claim;
do not inherit it.`,
    { label: `verify:r${round}`, phase: 'Verify', agentType: 'reviewer', schema: VERIFY_SCHEMA },
  )

  // THE EXIT PREDICATE. A dead agent returns null, and null is RED — a reviewer that died
  // and a reviewer that found nothing produce the same silence, and silence is not consent.
  const green = !NEVER_GREEN
    && !!verify
    && verify.green === true
    && verify.exit_code === 0
    && verify.negative_control_ran === true

  if (green) {
    log(`green at round ${round}/${MAX_ROUNDS} after ${calls} agent call(s)`)
    return endGate('ship', 'built, proven, and independently verified — ship it?', { plan, build, verify, round })
  }

  lastRed = !verify
    ? 'the reviewer returned nothing — treat the build as unverified, not as approved'
    : (verify.blockers || []).join('\n') || `proof exited ${verify.exit_code}${verify.negative_control_ran ? '' : '; the negative control was never run'}`
  log(`round ${round}/${MAX_ROUNDS} red${NEVER_GREEN ? ' (neverGreen: the predicate cannot be satisfied by design)' : ''}`)
}

return endGate(
  'stuck',
  `${MAX_ROUNDS} round(s), still not green${NEVER_GREEN ? ' — EXPECTED: this was the negative control' : ''}`,
  { plan, build, verify, lastRed },
)

// ---------------------------------------------------------------- 5. the gate
// A gate calls no agent. It ends the run CLEANLY and hands the decision out through a file,
// because `resumeFromRunId` is same-session only and a human answer can outlive the session.
function endGate(kind, ask, artifacts) {
  log(`GATE (${kind}): ${ask}`)
  return {
    contract_version: 1,
    graph: 'spec-to-green',
    gated: true,
    verdict: kind === 'ship' ? 'green' : 'stuck',
    next_gate: { kind, ask },
    rounds: artifacts.round ?? null,
    agent_calls: calls,
    never_green: NEVER_GREEN,
    artifacts,
  }
}
