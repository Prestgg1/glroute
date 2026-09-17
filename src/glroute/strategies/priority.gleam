import gleam/list
import gleam/option.{None}
import glroute/agent.{type Agent}
import glroute/chat.{
  type ChatRequest, type Completion, type Message, ChatRequest,
}
import glroute/errors.{type GlrouteError, ProviderError}
import glroute/route
import glroute/usage.{type RunResult}

// ---------------------------------------------------------------------------
// Priority routing - sequential fallback (like OmniRoute combos)
// Tries agents in order, returns first Ok. If all fail, returns last error.
// ---------------------------------------------------------------------------

pub fn route_priority(
  agents: List(Agent(deps, output)),
  prompt: String,
  deps: deps,
) -> Result(RunResult(output), GlrouteError) {
  case agents {
    [] ->
      Error(ProviderError("glroute: no agents provided for priority routing"))
    _ -> do_priority(agents, prompt, deps, 0, [])
  }
}

fn do_priority(
  agents: List(Agent(deps, output)),
  prompt: String,
  deps: deps,
  index: Int,
  tried: List(String),
) -> Result(RunResult(output), GlrouteError) {
  case agents {
    [] ->
      Error(ProviderError(
        "glroute: all agents failed (tried: " <> tried_to_string(tried) <> ")",
      ))
    [head, ..tail] -> {
      let model_name = route.agent_model_name(head)
      case agent.run(head, prompt, deps) {
        Ok(result) -> Ok(result)
        Error(e) -> {
          case tail {
            [] -> Error(e)
            _ ->
              do_priority(tail, prompt, deps, index + 1, [model_name, ..tried])
          }
        }
      }
    }
  }
}

fn tried_to_string(tried: List(String)) -> String {
  case tried {
    [] -> "none"
    _ -> list_join(list.reverse(tried), ", ")
  }
}

pub fn route_chat(
  agents: List(Agent(deps, output)),
  request: ChatRequest,
) -> Result(Completion, GlrouteError) {
  case agents {
    [] -> Error(ProviderError("glroute: no agents provided"))
    _ -> do_route_chat(agents, request, [])
  }
}

fn do_route_chat(
  agents: List(Agent(deps, output)),
  request: ChatRequest,
  tried: List(String),
) -> Result(Completion, GlrouteError) {
  case agents {
    [] ->
      Error(ProviderError(
        "glroute: all agents failed (tried: " <> tried_to_string(tried) <> ")",
      ))
    [head, ..tail] -> {
      let model_name = route.agent_model_name(head)
      case agent.complete(head, request) {
        Ok(completion) -> Ok(completion)
        Error(e) -> {
          case tail {
            [] -> Error(e)
            _ -> do_route_chat(tail, request, [model_name, ..tried])
          }
        }
      }
    }
  }
}

pub fn route_messages(
  agents: List(Agent(deps, output)),
  messages: List(Message),
) -> Result(Completion, GlrouteError) {
  let request =
    ChatRequest(
      model: "default",
      messages: messages,
      tools: [],
      temperature: None,
      max_tokens: None,
      stream: False,
    )
  route_chat(agents, request)
}

fn list_join(items: List(String), sep: String) -> String {
  case items {
    [] -> ""
    [first, ..rest] -> list_join_loop(rest, first, sep)
  }
}

fn list_join_loop(items: List(String), acc: String, sep: String) -> String {
  case items {
    [] -> acc
    [head, ..tail] -> list_join_loop(tail, acc <> sep <> head, sep)
  }
}
