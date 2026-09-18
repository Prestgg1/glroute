import gleam/erlang/process
import glroute
import glroute/agent
import glroute/provider

pub fn main() {
  // Define multiple named lists (combos) with different strategies:
  // 1. "fast" - races all agents in parallel (Fusion strategy)
  // 2. "reliable" - tries agents in priority fallback order (Priority strategy)
  let fast_combo =
    glroute.fusion_combo("fast", [
      agent.new(provider.gemini("gemini-2.5-flash", "AIza...")),
      agent.new(provider.openai_compatible(
        "agnes-2.5-flash",
        "https://apihub.agnes-ai.com/v1",
        "sk-...",
      )),
    ])

  let reliable_combo =
    glroute.priority_combo("reliable", [
      agent.new(provider.openai("gpt-4o", "sk-...")),
      agent.new(provider.openai("gpt-4o-mini", "sk-...")),
      agent.new(provider.openai_compatible(
        "llama3",
        "http://localhost:11434/v1",
        "ollama",
      )),
    ])

  let combos = [fast_combo, reliable_combo]

  let config =
    glroute.default_server_config(3000)
    |> glroute.with_api_key("secret_token")
    |> glroute.with_allowed_origin("*")

  // Server starts and exposes:
  //   POST /v1/chat/completions (clients can specify model: "fast" or model: "reliable")
  //   GET  /v1/models (lists both "fast" and "reliable" combos as well as individual models)
  //   GET  /health
  let assert Ok(_) = glroute.serve_combos_with_config(combos, config)

  process.sleep_forever()
}
