// engine-credit v2 — harness attribution that REPORTS THE LIVE MODEL.
//
// Vince's doctrine: attribution is harness responsibility, not LLM memory — and it
// must describe reality, not a hardcoded persona. This marks every shell spawned
// inside an opencode session with a Co-authored-by credit naming the MODEL the
// org actually runs (resolved from config, cached 60s), e.g.:
//
//   OPENCODE_ENGINE_CREDIT="opencode-big-pickle <opencode-big-pickle@noreply.opencode.ai>"
//
// A git prepare-commit-msg hook (shipped alongside) appends that trailer to
// commits made inside sessions only — human commits outside are untouched.
// Falls back to bare "opencode" if the config API hiccups: degrade honestly,
// never invent an identifier.

const TTL_MS = 60000

export const EngineCreditPlugin = async ({ client }) => {
  let cache = { at: 0, value: null }

  async function currentCredit() {
    if (cache.value && Date.now() - cache.at < TTL_MS) return cache.value
    // Resolution order: explicit config pin → the session-runner's env pins
    // (OPENCODE_MODEL_PROVIDER/ID — what kickoff orgs actually set) → honest generic.
    let model = ""
    try {
      const res = await client.config.get()
      const m = res?.data?.model ?? res?.model
      if (typeof m === "string" && m.trim()) model = m.trim()
    } catch {
      // config unavailable — fall through to env / generic
    }
    if (!model && process.env.OPENCODE_MODEL_ID) {
      model = [process.env.OPENCODE_MODEL_PROVIDER || "opencode", process.env.OPENCODE_MODEL_ID]
        .join("/")
    }
    if (!model) model = "opencode"
    // Convention parity with Claude Code: NAME carries the model, EMAIL stays a
    // constant vendor address. `provider/model` renders as "opencode <model-id>".
    const display = String(model).includes("/")
      ? String(model).split("/").slice(1).join("-")
      : String(model)
    cache = {
      at: Date.now(),
      value: `opencode ${display} <noreply@opencode.ai>`,
    }
    return cache.value
  }

  return {
    "shell.env": async (input, output) => {
      output.env.OPENCODE_ENGINE_CREDIT = await currentCredit()
    },
  }
}
