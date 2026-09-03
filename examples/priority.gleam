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

  // Priority fallback: tries in order, like OmniRoute combos
  let agents = [
    agent.new(provider.openai("gpt-4o", "sk-...")) |> agent.with_glon(schema),
    agent.new(provider.gemini("gemini-2.5-flash", "AIza..."))
      |> agent.with_glon(schema),
    agent.new(provider.openai_compatible(
      "llama3",
      "http://localhost:11434/v1",
      "ollama",
    ))
      |> agent.with_glon(schema),
  ]

  case glroute.route_priority(agents, "Which country is Paris in?", Nil) {
    Ok(result) -> {
      echo "Success: " <> result.output.city <> ", " <> result.output.country
      echo result.usage
    }
    Error(e) -> echo e
  }
}
