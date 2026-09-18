import gleam/list
import glroute/agent.{type Agent}
import glroute/chat.{type ChatRequest, type Completion}
import glroute/errors.{type GlrouteError, ProviderError}
import glroute/route
import glroute/strategies/fusion
import glroute/strategies/priority
import glroute/usage.{type RunResult}

// ---------------------------------------------------------------------------
// Combos - named groups of agents with an assigned routing strategy
// Allows configuring multiple named lists (e.g. "fast", "smart", "fusion", "default")
// Supported strategies:
//   - Priority: tries agents in order, falling back on error
//   - Fusion: races all agents concurrently in parallel, fastest response wins
// ---------------------------------------------------------------------------

pub type Strategy {
  Priority
  Fusion
}

pub type Combo(deps, output) {
  Combo(name: String, strategy: Strategy, agents: List(Agent(deps, output)))
}

/// Create a new Combo with a specified name, strategy, and agent list.
pub fn new(
  name: String,
  strategy: Strategy,
  agents: List(Agent(deps, output)),
) -> Combo(deps, output) {
  Combo(name: name, strategy: strategy, agents: agents)
}

/// Create a priority fallback combo. Agents are tried sequentially in order.
pub fn priority(
  name: String,
  agents: List(Agent(deps, output)),
) -> Combo(deps, output) {
  Combo(name: name, strategy: Priority, agents: agents)
}

/// Create a fusion racing combo. All agents are called in parallel; fastest success wins.
pub fn fusion(
  name: String,
  agents: List(Agent(deps, output)),
) -> Combo(deps, output) {
  Combo(name: name, strategy: Fusion, agents: agents)
}

/// Route a prompt through a single combo using its configured strategy.
pub fn route(
  combo: Combo(deps, output),
  prompt: String,
  deps: deps,
) -> Result(RunResult(output), GlrouteError) {
  case combo.strategy {
    Priority -> priority.route_priority(combo.agents, prompt, deps)
    Fusion -> fusion.route_fusion(combo.agents, prompt, deps)
  }
}

/// Route a full chat completion request through a single combo using its strategy.
pub fn route_chat(
  combo: Combo(deps, output),
  request: ChatRequest,
) -> Result(Completion, GlrouteError) {
  case combo.strategy {
    Priority -> priority.route_chat(combo.agents, request)
    Fusion -> fusion.route_chat(combo.agents, request)
  }
}

/// Find a matching combo from a list of combos:
/// 1. Exact match by combo name
/// 2. If name is "default", "auto", or empty: returns combo named "default", or the first combo
/// 3. If name matches an individual agent's model_name in any combo: returns that combo
/// 4. Fallback: returns "default" combo, or the first configured combo
pub fn find_combo(
  combos: List(Combo(deps, output)),
  name: String,
) -> Result(Combo(deps, output), GlrouteError) {
  case combos {
    [] -> Error(ProviderError("glroute: no combos configured"))
    [first, ..] -> {
      case list.find(combos, fn(c) { c.name == name }) {
        Ok(found) -> Ok(found)
        Error(Nil) -> {
          case name == "default" || name == "auto" || name == "" {
            True -> Ok(default_or_first(combos, first))
            False -> {
              case find_by_agent_model(combos, name) {
                Ok(c) -> Ok(c)
                Error(Nil) -> Ok(default_or_first(combos, first))
              }
            }
          }
        }
      }
    }
  }
}

fn default_or_first(
  combos: List(Combo(deps, output)),
  first: Combo(deps, output),
) -> Combo(deps, output) {
  case list.find(combos, fn(c) { c.name == "default" }) {
    Ok(def) -> def
    Error(Nil) -> first
  }
}

fn find_by_agent_model(
  combos: List(Combo(deps, output)),
  model_name: String,
) -> Result(Combo(deps, output), Nil) {
  list.find(combos, fn(c) {
    list.any(c.agents, fn(ag) { route.agent_model_name(ag) == model_name })
  })
}

/// Route a prompt through a specific combo found by name from a list of combos.
pub fn route_from_combos(
  combos: List(Combo(deps, output)),
  combo_name: String,
  prompt: String,
  deps: deps,
) -> Result(RunResult(output), GlrouteError) {
  case find_combo(combos, combo_name) {
    Ok(target_combo) -> route(target_combo, prompt, deps)
    Error(e) -> Error(e)
  }
}

/// Route a chat request across multiple combos.
/// Matches the request's requested model against the combo names.
pub fn route_chat_from_combos(
  combos: List(Combo(deps, output)),
  request: ChatRequest,
) -> Result(Completion, GlrouteError) {
  let requested = chat.requested_model(request)
  case find_combo(combos, requested) {
    Ok(target_combo) -> route_chat(target_combo, request)
    Error(e) -> Error(e)
  }
}

/// Get the list of all combo names.
pub fn combo_names(combos: List(Combo(deps, output))) -> List(String) {
  list.map(combos, fn(c) { c.name })
}

/// Get all unique agent model names across all combos.
pub fn all_agent_model_names(
  combos: List(Combo(deps, output)),
) -> List(String) {
  combos
  |> list.flat_map(fn(c) { list.map(c.agents, route.agent_model_name) })
  |> list.unique
}
