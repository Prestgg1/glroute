import gdantic_ai/agent
import gdantic_ai/provider
import glon
import glroute

pub type City {
  City(city: String, country: String)
}

pub fn main() {
  let schema = {
    use city <- glon.field("city", glon.string())
    use country <- glon.field("country", glon.string())
    glon.success(City(city:, country:))
  }

  // Parallel fan-out: all agents run concurrently (true parallelism via Erlang)
  // This is what OmniRoute does NOT support (it is sequential)
  let agents = [
    agent.new(provider.openai("gpt-4o", "sk-...")) |> agent.with_glon(schema),
    agent.new(provider.openai("gpt-4o-mini", "sk-..."))
      |> agent.with_glon(schema),
    agent.new(provider.gemini("gemini-2.5-flash", "AIza..."))
      |> agent.with_glon(schema),
  ]

  let result = glroute.route_parallel(agents, "Which country is Tokyo in?", Nil)

  echo "Ok: "
  echo result.ok_count
  echo "Errors: "
  echo result.error_count

  // Results are sorted by priority index (original order)
  case result.results {
    [first, second, third] -> {
      echo "Agent 0 (gpt-4o):"
      echo first.result
      echo "Agent 1 (gpt-4o-mini):"
      echo second.result
      echo "Agent 2 (gemini):"
      echo third.result
    }
    _ -> echo "Unexpected count"
  }

  // With timeout
  let result2 =
    glroute.route_parallel_with_timeout(
      agents,
      "Which country is Berlin in?",
      Nil,
      10_000,
    )
  echo result2
}
