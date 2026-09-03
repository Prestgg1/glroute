import gdantic_ai/agent.{type Agent}
import gdantic_ai/errors.{type GdanticError, ProviderError}
import gdantic_ai/usage.{type RunResult}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/order
import glroute/route.{
  type ParallelResult, type TargetResult, ParallelResult, TargetResult,
}

// ---------------------------------------------------------------------------
// Priority (sequential fallback) - like OmniRoute combo but using gdantic_ai Agents
// Tries agents in order, returns first Ok. If all fail, returns last error.
// ---------------------------------------------------------------------------

pub fn route_priority(
  agents: List(Agent(deps, output)),
  prompt: String,
  deps: deps,
) -> Result(RunResult(output), GdanticError) {
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
) -> Result(RunResult(output), GdanticError) {
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

// ---------------------------------------------------------------------------
// Parallel fan-out - runs all agents concurrently, collects all results
// This is the key difference from OmniRoute: true parallel execution
// Uses Erlang processes + Subject for concurrent collection
// ---------------------------------------------------------------------------

pub fn route_parallel(
  agents: List(Agent(deps, output)),
  prompt: String,
  deps: deps,
) -> ParallelResult(output) {
  route_parallel_with_timeout(agents, prompt, deps, 30_000)
}

/// Parallel with per-target timeout (ms).
pub fn route_parallel_with_timeout(
  agents: List(Agent(deps, output)),
  prompt: String,
  deps: deps,
  timeout_ms: Int,
) -> ParallelResult(output) {
  case agents {
    [] -> ParallelResult(results: [], ok_count: 0, error_count: 0)
    _ -> {
      let subject: Subject(TargetResult(output)) = process.new_subject()
      let indexed = list.index_map(agents, fn(agent, idx) { #(idx, agent) })

      // Spawn one process per agent
      list.each(indexed, fn(pair) {
        let #(idx, ag) = pair
        let _pid =
          process.spawn_unlinked(fn() {
            let result = agent.run(ag, prompt, deps)
            let model_name = route.agent_model_name(ag)
            let target =
              TargetResult(index: idx, model: model_name, result: result)
            process.send(subject, target)
          })
        Nil
      })

      // Collect results
      let results =
        collect_with_subject(subject, list.length(agents), timeout_ms, [])
      let sorted =
        list.sort(results, fn(a, b) {
          case a.index < b.index {
            True -> order.Lt
            False if a.index > b.index -> order.Gt
            False -> order.Eq
          }
        })
      let ok_count = route.target_ok_count(sorted)
      let error_count = route.target_error_count(sorted)
      ParallelResult(results: sorted, ok_count:, error_count:)
    }
  }
}

fn collect_with_subject(
  subject: Subject(TargetResult(a)),
  remaining: Int,
  timeout_ms: Int,
  acc: List(TargetResult(a)),
) -> List(TargetResult(a)) {
  case remaining <= 0 {
    True -> acc
    False -> {
      case process.receive(subject, timeout_ms) {
        Ok(target) ->
          collect_with_subject(subject, remaining - 1, timeout_ms, [
            target,
            ..acc
          ])
        Error(_) -> {
          // Timeout — mark remaining as timed out and return
          let missing = make_timeout_results(remaining, acc)
          list.append(acc, missing)
        }
      }
    }
  }
}

fn make_timeout_results(
  count: Int,
  existing: List(TargetResult(a)),
) -> List(TargetResult(a)) {
  let _ = existing
  case count <= 0 {
    True -> []
    False -> {
      let timeout_result =
        TargetResult(
          index: 9000 + count,
          model: "timeout",
          result: Error(ProviderError(
            "glroute: timeout after " <> int_to_string(count) <> " remaining",
          )),
        )
      [timeout_result, ..make_timeout_results(count - 1, existing)]
    }
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
