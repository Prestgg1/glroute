import gdantic_ai/agent.{type Agent}
import gdantic_ai/errors.{type GdanticError}
import gdantic_ai/usage.{type RunResult}

// ---------------------------------------------------------------------------
// Strategy - for now only Priority (sequential fallback)
// Further strategies (Race, Quorum) can be added later
// ---------------------------------------------------------------------------

pub type Strategy {
  /// Priority: try agents in order, return first success.
  /// If one fails, try the next. Like OmniRoute combo fallback.
  Priority
}

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

pub type TargetResult(output) {
  TargetResult(
    index: Int,
    model: String,
    result: Result(RunResult(output), GdanticError),
  )
}

pub type ParallelResult(output) {
  ParallelResult(
    results: List(TargetResult(output)),
    ok_count: Int,
    error_count: Int,
  )
}

pub type PriorityResult(output) {
  PriorityResult(
    result: RunResult(output),
    attempts: Int,
    tried_models: List(String),
  )
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

pub fn agent_model_name(agent: Agent(deps, output)) -> String {
  let model = agent.get_model(agent)
  model.model_name
}

pub fn target_ok_count(results: List(TargetResult(a))) -> Int {
  count_ok(results, 0)
}

fn count_ok(results: List(TargetResult(a)), acc: Int) -> Int {
  case results {
    [] -> acc
    [head, ..tail] ->
      case head.result {
        Ok(_) -> count_ok(tail, acc + 1)
        Error(_) -> count_ok(tail, acc)
      }
  }
}

pub fn target_error_count(results: List(TargetResult(a))) -> Int {
  count_error(results, 0)
}

fn count_error(results: List(TargetResult(a)), acc: Int) -> Int {
  case results {
    [] -> acc
    [head, ..tail] ->
      case head.result {
        Error(_) -> count_error(tail, acc + 1)
        Ok(_) -> count_error(tail, acc)
      }
  }
}
