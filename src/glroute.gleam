import glroute/agent.{type Agent}
import glroute/chat.{type ChatRequest, type Completion}
import glroute/combo
import glroute/errors.{type GlrouteError}
import glroute/server
import glroute/strategies/fusion
import glroute/strategies/priority
import glroute/usage.{type RunResult}

// ---------------------------------------------------------------------------
// glroute - lightweight parallel LLM router
// ---------------------------------------------------------------------------

pub fn main() {
  // See examples/
  Nil
}

// ---------------------------------------------------------------------------
// Routing Strategies & Combos
// ---------------------------------------------------------------------------

pub type Strategy =
  combo.Strategy

pub type Combo(deps, output) =
  combo.Combo(deps, output)

/// Create a Combo with a specified name, strategy, and agent list.
pub fn combo(
  name: String,
  strategy: Strategy,
  agents: List(Agent(deps, output)),
) -> Combo(deps, output) {
  combo.new(name, strategy, agents)
}

/// Create a priority fallback combo. Agents are tried sequentially.
pub fn priority_combo(
  name: String,
  agents: List(Agent(deps, output)),
) -> Combo(deps, output) {
  combo.priority(name, agents)
}

/// Create a fusion racing combo. All agents are called in parallel; fastest response wins.
pub fn fusion_combo(
  name: String,
  agents: List(Agent(deps, output)),
) -> Combo(deps, output) {
  combo.fusion(name, agents)
}

/// Route a prompt through a single combo.
pub fn route_combo(
  combo: Combo(deps, output),
  prompt: String,
  deps: deps,
) -> Result(RunResult(output), GlrouteError) {
  combo.route(combo, prompt, deps)
}

/// Route a chat completion request through a single combo.
pub fn route_chat_combo(
  combo: Combo(deps, output),
  request: ChatRequest,
) -> Result(Completion, GlrouteError) {
  combo.route_chat(combo, request)
}

/// Route a prompt through multiple combos by combo name.
pub fn route_combos(
  combos: List(Combo(deps, output)),
  combo_name: String,
  prompt: String,
  deps: deps,
) -> Result(RunResult(output), GlrouteError) {
  combo.route_from_combos(combos, combo_name, prompt, deps)
}

/// Route a chat request across multiple combos based on the requested model name.
pub fn route_chat_combos(
  combos: List(Combo(deps, output)),
  request: ChatRequest,
) -> Result(Completion, GlrouteError) {
  combo.route_chat_from_combos(combos, request)
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
) -> Result(RunResult(output), GlrouteError) {
  priority.route_priority(agents, prompt, deps)
}

/// Forward a full OpenAI-compatible chat request through agents in priority order.
pub fn route_chat(
  agents: List(Agent(deps, output)),
  request: ChatRequest,
) -> Result(Completion, GlrouteError) {
  priority.route_chat(agents, request)
}

pub fn route_chat_priority(
  agents: List(Agent(deps, output)),
  request: ChatRequest,
) -> Result(Completion, GlrouteError) {
  priority.route_chat(agents, request)
}

// ---------------------------------------------------------------------------
// Fusion routing - concurrent racing (fastest valid response wins)
// ---------------------------------------------------------------------------

/// Call all agents concurrently in parallel. The fastest valid response wins;
/// other pending requests are terminated. Matches Arivio's AI Fusion strategy.
pub fn route_fusion(
  agents: List(Agent(deps, output)),
  prompt: String,
  deps: deps,
) -> Result(RunResult(output), GlrouteError) {
  fusion.route_fusion(agents, prompt, deps)
}

/// Call all agents concurrently with a custom timeout in milliseconds.
pub fn route_fusion_with_timeout(
  agents: List(Agent(deps, output)),
  prompt: String,
  deps: deps,
  timeout_ms: Int,
) -> Result(RunResult(output), GlrouteError) {
  fusion.route_fusion_with_timeout(agents, prompt, deps, timeout_ms)
}

/// Forward a full OpenAI-compatible chat request to all agents concurrently.
/// The fastest valid response wins; other pending requests are terminated.
pub fn route_chat_fusion(
  agents: List(Agent(deps, output)),
  request: ChatRequest,
) -> Result(Completion, GlrouteError) {
  fusion.route_chat(agents, request)
}

/// Forward a full chat request with a custom timeout in milliseconds.
pub fn route_chat_fusion_with_timeout(
  agents: List(Agent(deps, output)),
  request: ChatRequest,
  timeout_ms: Int,
) -> Result(Completion, GlrouteError) {
  fusion.route_chat_with_timeout(agents, request, timeout_ms)
}

// ---------------------------------------------------------------------------
// Server - OpenAI-compatible address with CORS & Security
// ---------------------------------------------------------------------------

/// Start server on port with given agents (uses a default Priority combo).
pub fn serve(
  agents: List(Agent(Nil, String)),
  port: Int,
) -> Result(Nil, String) {
  server.serve(agents, port)
}

pub fn serve_with_config(
  agents: List(Agent(Nil, String)),
  config: ServerConfig,
) -> Result(Nil, String) {
  server.serve_with_config(agents, config)
}

/// Start server on port with multiple named combos.
pub fn serve_combos(
  combos: List(Combo(Nil, String)),
  port: Int,
) -> Result(Nil, String) {
  server.serve_combos(combos, port)
}

/// Start server with multiple named combos and custom server configuration.
pub fn serve_combos_with_config(
  combos: List(Combo(Nil, String)),
  config: ServerConfig,
) -> Result(Nil, String) {
  server.serve_combos_with_config(combos, config)
}

pub fn default_server_config(port: Int) -> ServerConfig {
  server.default_config(port)
}

pub fn with_api_key(config: ServerConfig, api_key: String) -> ServerConfig {
  server.with_api_key(config, api_key)
}

pub fn with_allowed_origin(
  config: ServerConfig,
  origin: String,
) -> ServerConfig {
  server.with_allowed_origin(config, origin)
}

pub type ServerConfig =
  server.ServerConfig
