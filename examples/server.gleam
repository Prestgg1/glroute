import gdantic_ai/agent
import gdantic_ai/provider
import gleam/erlang/process
import glroute

pub fn main() {
  // Server with custom OpenAI-compatible address
  // Handles parallel incoming requests via BEAM (each request in its own process)
  let agents = [
    agent.new(provider.openai("gpt-4o", "sk-...")),
    agent.new(provider.openai("gpt-4o-mini", "sk-...")),
    // Fallback to local Ollama
    agent.new(provider.openai_compatible(
      "llama3",
      "http://localhost:11434/v1",
      "ollama",
    )),
  ]

  let assert Ok(_) = glroute.serve(agents, 3000)
  // Server now listening at:
  //   POST http://localhost:3000/v1/chat/completions
  //   GET  http://localhost:3000/v1/models
  //   GET  http://localhost:3000/health
  //
  // Clients can set:
  //   base_url = "http://localhost:3000/v1"
  // e.g., with OpenAI SDK:
  //   new OpenAI({ baseURL: "http://localhost:3000/v1", apiKey: "sk-..." })
  //
  // Parallel requests from many clients are handled concurrently:
  //   Client A POST ─┐
  //   Client B POST ─┼─► BEAM (each in own process) ─► priority fallback per request
  //   Client C POST ─┘
  // No blocking, production-ready small router.

  process.sleep_forever()
}
