import gleam/io
import glon
import glroute
import glroute/agent
import glroute/provider

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
      io.println(
        "Success: " <> result.output.city <> ", " <> result.output.country,
      )
    }
    Error(e) -> io.println("Error")
  }
}
