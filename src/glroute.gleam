import gdantic_ai/agent.{type Agent}
import gdantic_ai/errors.{type GdanticError}
import gdantic_ai/usage.{type RunResult}
import glroute/parallel
import glroute/route

pub fn main() {
  // Placeholder - see examples/
  Nil
}

// ---------------------------------------------------------------------------
// Priority routing - sequential fallback (like OmniRoute combos)
// ---------------------------------------------------------------------------

/// Try agents in priority order, return first success.
/// If all fail, return the last error.
pub fn route_priority(
  agents: List(Agent(deps, output)),
  prompt: String,
  deps: deps,
) -> Result(RunResult(output), GdanticError) {
  parallel.route_priority(agents, prompt, deps)
}

// ---------------------------------------------------------------------------
// Parallel routing - true concurrent fan-out
// ---------------------------------------------------------------------------

/// Run all agents concurrently, collect all results.
/// Unlike OmniRoute (sequential), this fans out in parallel via Erlang processes.
pub fn route_parallel(
  agents: List(Agent(deps, output)),
  prompt: String,
  deps: deps,
) -> ParallelResult(output) {
  parallel.route_parallel(agents, prompt, deps)
}

/// Parallel with custom timeout per target (ms)
pub fn route_parallel_with_timeout(
  agents: List(Agent(deps, output)),
  prompt: String,
  deps: deps,
  timeout_ms: Int,
) -> ParallelResult(output) {
  parallel.route_parallel_with_timeout(agents, prompt, deps, timeout_ms)
}

// Re-exports
pub type ParallelResult(output) =
  route.ParallelResult(output)

pub type TargetResult(output) =
  route.TargetResult(output)

pub type Strategy =
  route.Strategy
