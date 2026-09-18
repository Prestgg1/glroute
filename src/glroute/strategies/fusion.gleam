import gleam/erlang/process
import gleam/list
import glroute/agent.{type Agent}
import glroute/chat.{type ChatRequest, type Completion}
import glroute/errors.{type GlrouteError, ProviderError}
import glroute/route
import glroute/usage.{type RunResult}

// ---------------------------------------------------------------------------
// Fusion routing - concurrent racing (fastest valid response wins)
// All agents receive requests simultaneously. The first one to return Ok
// wins the race and its response is returned. Other pending requests are killed.
// If an agent fails, the race continues until an agent succeeds or all fail.
// Matches Arivio's AI Fusion racing strategy.
// ---------------------------------------------------------------------------

const default_timeout_ms = 60_000

type FusionMessage(res) {
  FusionSuccess(agent_name: String, result: res)
  FusionFailure(agent_name: String, error: GlrouteError)
}

/// Run all agents in parallel with default 60s timeout. First success wins.
pub fn route_fusion(
  agents: List(Agent(deps, output)),
  prompt: String,
  deps: deps,
) -> Result(RunResult(output), GlrouteError) {
  route_fusion_with_timeout(agents, prompt, deps, default_timeout_ms)
}

/// Run all agents in parallel with custom timeout in milliseconds.
pub fn route_fusion_with_timeout(
  agents: List(Agent(deps, output)),
  prompt: String,
  deps: deps,
  timeout_ms: Int,
) -> Result(RunResult(output), GlrouteError) {
  case agents {
    [] -> Error(ProviderError("glroute: no agents provided for fusion routing"))
    _ -> {
      let subject = process.new_subject()
      let child_pids =
        list.map(agents, fn(ag) {
          let model_name = route.agent_model_name(ag)
          process.spawn_unlinked(fn() {
            case agent.run(ag, prompt, deps) {
              Ok(res) -> process.send(subject, FusionSuccess(model_name, res))
              Error(e) -> process.send(subject, FusionFailure(model_name, e))
            }
          })
        })

      let start = monotonic_time_ms()
      let deadline = start + timeout_ms
      await_winner(
        subject,
        child_pids,
        list.length(agents),
        [],
        timeout_ms,
        deadline,
      )
    }
  }
}

/// Forward a full chat request to all agents simultaneously.
/// The first agent to return a valid completion wins; all others are terminated.
pub fn route_chat(
  agents: List(Agent(deps, output)),
  request: ChatRequest,
) -> Result(Completion, GlrouteError) {
  route_chat_with_timeout(agents, request, default_timeout_ms)
}

/// Forward a full chat request with custom timeout in milliseconds.
pub fn route_chat_with_timeout(
  agents: List(Agent(deps, output)),
  request: ChatRequest,
  timeout_ms: Int,
) -> Result(Completion, GlrouteError) {
  case agents {
    [] -> Error(ProviderError("glroute: no agents provided for fusion routing"))
    _ -> {
      let subject = process.new_subject()
      let child_pids =
        list.map(agents, fn(ag) {
          let model_name = route.agent_model_name(ag)
          process.spawn_unlinked(fn() {
            case agent.complete(ag, request) {
              Ok(res) -> process.send(subject, FusionSuccess(model_name, res))
              Error(e) -> process.send(subject, FusionFailure(model_name, e))
            }
          })
        })

      let start = monotonic_time_ms()
      let deadline = start + timeout_ms
      await_winner(
        subject,
        child_pids,
        list.length(agents),
        [],
        timeout_ms,
        deadline,
      )
    }
  }
}

fn await_winner(
  subject: process.Subject(FusionMessage(res)),
  child_pids: List(process.Pid),
  remaining: Int,
  failures: List(String),
  timeout_ms: Int,
  deadline: Int,
) -> Result(res, GlrouteError) {
  let now = monotonic_time_ms()
  let remaining_timeout = deadline - now
  case remaining_timeout <= 0 {
    True -> {
      kill_all(child_pids)
      Error(ProviderError(
        "glroute: fusion routing timed out after "
        <> int_to_string(timeout_ms)
        <> "ms",
      ))
    }
    False -> {
      case process.receive(subject, remaining_timeout) {
        Error(_) -> {
          kill_all(child_pids)
          Error(ProviderError(
            "glroute: fusion routing timed out after "
            <> int_to_string(timeout_ms)
            <> "ms",
          ))
        }
        Ok(FusionSuccess(_name, result)) -> {
          kill_all(child_pids)
          Ok(result)
        }
        Ok(FusionFailure(name, err)) -> {
          let failures = [name <> ": " <> errors.to_string(err), ..failures]
          let next_remaining = remaining - 1
          case next_remaining <= 0 {
            True -> {
              kill_all(child_pids)
              Error(ProviderError(
                "glroute: all agents failed in fusion race: "
                <> list_join(list.reverse(failures), " | "),
              ))
            }
            False -> {
              await_winner(
                subject,
                child_pids,
                next_remaining,
                failures,
                timeout_ms,
                deadline,
              )
            }
          }
        }
      }
    }
  }
}

fn kill_all(pids: List(process.Pid)) -> Nil {
  list.each(pids, fn(pid) { process.kill(pid) })
}

@external(erlang, "glroute_chat_ffi", "monotonic_time_ms")
fn monotonic_time_ms() -> Int

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

fn int_to_string(n: Int) -> String {
  case n {
    0 -> "0"
    _ -> do_int_to_string(n, "")
  }
}

fn do_int_to_string(n: Int, acc: String) -> String {
  case n <= 0 {
    True if acc == "" -> "0"
    True -> acc
    False -> {
      let digit = n % 10
      let rest = n / 10
      let char = case digit {
        0 -> "0"
        1 -> "1"
        2 -> "2"
        3 -> "3"
        4 -> "4"
        5 -> "5"
        6 -> "6"
        7 -> "7"
        8 -> "8"
        _ -> "9"
      }
      do_int_to_string(rest, char <> acc)
    }
  }
}
