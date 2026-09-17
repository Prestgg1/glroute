import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option}

// ---------------------------------------------------------------------------
// OpenAI-compatible proxy types
// The request is kept as generic JSON so full chat history, system prompts,
// content parts, tools and tool calls are forwarded to providers unchanged.
// Only `model` is rewritten per agent, and `stream` is forced off upstream so
// priority fallback still works; streaming clients get SSE via `to_sse`.
// ---------------------------------------------------------------------------

/// Constructed by `parse_request`.
pub type ChatRequest {
  ChatRequest(
    /// Decoded request JSON, forwarded upstream as-is apart from `model`/`stream`.
    raw: Dynamic,
    model: String,
    stream: Bool,
    include_usage: Bool,
  )
}

pub type Completion {
  Completion(
    /// Raw OpenAI chat.completion JSON returned by the provider.
    body: String,
    /// Model reported by the provider (falls back to the agent model name).
    model: String,
    /// Model name of the agent that served the request.
    served_by: String,
  )
}

/// Parse an incoming `/v1/chat/completions` body.
@external(erlang, "glroute_chat_ffi", "parse_request")
pub fn parse_request(body: String) -> Result(ChatRequest, String)

/// Model name the client asked for.
pub fn requested_model(request: ChatRequest) -> String {
  request.model
}

/// Whether the client asked for a streaming (SSE) response.
pub fn is_stream(request: ChatRequest) -> Bool {
  request.stream
}

/// Build the upstream request body for one agent.
pub fn build_body(
  request: ChatRequest,
  model: String,
  instructions: Option(String),
  temperature: Option(Float),
  max_tokens: Option(Int),
) -> String {
  do_build_body(request.raw, model, instructions, temperature, max_tokens)
}

@external(erlang, "glroute_chat_ffi", "build_body")
fn do_build_body(
  raw: Dynamic,
  model: String,
  instructions: Option(String),
  temperature: Option(Float),
  max_tokens: Option(Int),
) -> String

/// Check a provider response is a usable completion; returns its model name.
@external(erlang, "glroute_chat_ffi", "validate_response")
pub fn validate_response(body: String) -> Result(String, String)

/// Render a completion as an OpenAI server-sent-events stream.
pub fn to_sse(completion: Completion, request: ChatRequest) -> String {
  do_to_sse(completion.body, request.include_usage)
}

@external(erlang, "glroute_chat_ffi", "to_sse")
fn do_to_sse(body: String, include_usage: Bool) -> String
