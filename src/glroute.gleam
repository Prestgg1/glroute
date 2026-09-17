import glroute/agent.{type Agent}
import glroute/chat.{type ChatRequest, type Completion, type Message}
import glroute/errors.{type GlrouteError}
import glroute/session
import glroute/server
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

/// Route a full chat request with tool support.
pub fn route_chat(
  agents: List(Agent(deps, output)),
  request: ChatRequest,
) -> Result(Completion, GlrouteError) {
  priority.route_chat(agents, request)
}

/// Route a list of messages (for session replay).
pub fn route_messages(
  agents: List(Agent(deps, output)),
  messages: List(Message),
) -> Result(Completion, GlrouteError) {
  priority.route_messages(agents, messages)
}

// ---------------------------------------------------------------------------
// Server - OpenAI-compatible address with CORS & Security
// ---------------------------------------------------------------------------

/// Start server on port with given agents.
pub fn serve(agents: List(Agent(Nil, String)), port: Int) -> Result(Nil, String) {
  server.serve(agents, port)
}

pub fn serve_with_config(
  agents: List(Agent(Nil, String)),
  config: ServerConfig,
) -> Result(Nil, String) {
  server.serve_with_config(agents, config)
}

/// Start server with session history support.
pub fn serve_with_sessions(
  agents: List(Agent(Nil, String)),
  port: Int,
) -> Result(Nil, String) {
  server.serve_with_sessions(agents, port)
}

pub fn default_server_config(port: Int) -> ServerConfig {
  server.default_config(port)
}

pub fn with_api_key(config: ServerConfig, api_key: String) -> ServerConfig {
  server.with_api_key(config, api_key)
}

pub fn with_allowed_origin(config: ServerConfig, origin: String) -> ServerConfig {
  server.with_allowed_origin(config, origin)
}

pub type ServerConfig =
  server.ServerConfig

pub type SessionStore =
  session.SessionStore

pub fn new_session_store() -> SessionStore {
  session.new()
}
