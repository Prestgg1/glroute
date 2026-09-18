import gleam/io
import glroute
import glroute/agent
import glroute/provider

pub fn main() {
  // Fusion racing: requests are sent to all models simultaneously in parallel.
  // The fastest valid response wins and is returned immediately; all other
  // pending requests are cancelled. If a model fails, the race continues.
  let agents = [
    agent.new(provider.gemini("gemini-2.5-flash", "AIza...")),
    agent.new(provider.openai_compatible(
      "agnes-2.5-flash",
      "https://apihub.agnes-ai.com/v1",
      "sk-...",
    )),
    agent.new(provider.openai("gpt-4o-mini", "sk-...")),
  ]

  case glroute.route_fusion(agents, "Explain quantum entanglement in one sentence", Nil) {
    Ok(result) -> io.println("Fastest response: " <> result.output)
    Error(e) -> io.println("All models failed")
  }
}
