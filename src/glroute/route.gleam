import gdantic_ai/agent.{type Agent}

// ---------------------------------------------------------------------------
// Routing - Priority (sequential fallback)
// Tries agents in order, returns first success. If one fails, tries next.
// Like OmniRoute combos but typed in Gleam.
// Parallelism is NOT a routing strategy here — parallel is handled by BEAM:
// the server (mist) runs each incoming HTTP request in its own Erlang process,
// so multiple clients can call the OpenAI-compatible address concurrently.
// ---------------------------------------------------------------------------

pub fn agent_model_name(agent: Agent(deps, output)) -> String {
  let model = agent.get_model(agent)
  model.model_name
}
