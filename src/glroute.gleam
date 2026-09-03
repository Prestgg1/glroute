import gdantic_ai/agent.{type Agent}
import gdantic_ai/errors.{type GdanticError}
import gdantic_ai/usage.{type RunResult}
import glroute/parallel
import glroute/server

// ---------------------------------------------------------------------------
// glroute - lightweight parallel LLM router
//
// Parallel = BEAM concurrent request handling (not fan-out to all models)
// The OpenAI-compatible server handles each incoming HTTP request in its
// own Erlang process, so multiple clients can call concurrently.
// Per-request routing is Priority (sequential fallback).
// ---------------------------------------------------------------------------

pub fn main() {
  // See examples/
  Nil
}

// ---------------------------------------------------------------------------
// Priority routing - sequential fallback (like OmniRoute combos)
// ---------------------------------------------------------------------------

/// Try agents in priority order, return first success.
/// If all fail, return the last error.
pub fn route_priority(
  agents: List(Agent(deps, output)),
  prompt: String,
  deps: deps,
) -> Result(RunResult(output), GdanticError) {
  parallel.route_priority(agents, prompt, deps)
}

// ---------------------------------------------------------------------------
// Server - OpenAI-compatible address with parallel request handling
// ---------------------------------------------------------------------------

/// Start server on port with given agents.
/// Each incoming HTTP request is handled in its own BEAM process,
/// so parallel requests from multiple clients are served concurrently.
///
/// The server exposes:
/// - POST /v1/chat/completions (OpenAI-compatible)
/// - GET  /v1/models
/// - GET  /health
///
/// Example: `glroute.serve(agents, 3000)` → clients use
/// `base_url = "http://localhost:3000/v1"` as OpenAI compatible address.
pub fn serve(agents: List(Agent(Nil, String)), port: Int) -> Result(Nil, String) {
  server.serve(agents, port)
}

pub fn serve_with_config(
  agents: List(Agent(Nil, String)),
  config: ServerConfig,
) -> Result(Nil, String) {
  server.serve_with_config(agents, config)
}

pub type ServerConfig =
  server.ServerConfig
