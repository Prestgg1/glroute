import gdantic_ai/agent
import gdantic_ai/errors
import gdantic_ai/provider
import gleam/erlang/process
import gleam/http/response
import gleeunit/should
import glon
import glroute

pub type City {
  City(city: String, country: String)
}

fn city_schema() -> glon.JsonSchema(City) {
  use city <- glon.field("city", glon.string())
  use country <- glon.field("country", glon.string())
  glon.success(City(city:, country:))
}

fn mock_success(city: String, country: String) {
  fn(_req) {
    let body =
      "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"call_123\",\"type\":\"function\",\"function\":{\"name\":\"output\",\"arguments\":\"{\\\"city\\\":\\\""
      <> city
      <> "\\\",\\\"country\\\":\\\""
      <> country
      <> "\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":20,\"total_tokens\":30}}"
    Ok(response.new(200) |> response.set_body(body))
  }
}

fn mock_failure(_req) -> Result(response.Response(String), errors.GdanticError) {
  Ok(response.new(500) |> response.set_body("error"))
}

fn mock_delayed_success(city: String, country: String, delay_ms: Int) {
  fn(_req) {
    process.sleep(delay_ms)
    let body =
      "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"call_123\",\"type\":\"function\",\"function\":{\"name\":\"output\",\"arguments\":\"{\\\"city\\\":\\\""
      <> city
      <> "\\\",\\\"country\\\":\\\""
      <> country
      <> "\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":20,\"total_tokens\":30}}"
    Ok(response.new(200) |> response.set_body(body))
  }
}

// ---------------------------------------------------------------------------
// Parallel tests - true concurrent fan-out
// ---------------------------------------------------------------------------

pub fn parallel_all_success_test() {
  let schema = city_schema()
  let a1 =
    agent.new(provider.openai("gpt-4o", "sk-1"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_success("Paris", "France"))
  let a2 =
    agent.new(provider.openai("gpt-4o", "sk-2"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_success("Berlin", "Germany"))
  let a3 =
    agent.new(provider.openai("gpt-4o", "sk-3"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_success("Tokyo", "Japan"))

  let result = glroute.route_parallel([a1, a2, a3], "test", Nil)
  should.equal(result.ok_count, 3)
  should.equal(result.error_count, 0)
  should.equal(list_length(result.results), 3)
}

pub fn parallel_mixed_results_test() {
  let schema = city_schema()
  let a1 =
    agent.new(provider.openai("gpt-4o", "sk-1"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_success("Paris", "France"))
  let a2 =
    agent.new(provider.openai("gpt-4o", "sk-2"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_failure)
    |> agent.with_retries(0)
  let a3 =
    agent.new(provider.openai("gpt-4o", "sk-3"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_success("Tokyo", "Japan"))

  let result = glroute.route_parallel([a1, a2, a3], "test", Nil)
  should.equal(result.ok_count, 2)
  should.equal(result.error_count, 1)
}

pub fn parallel_all_fail_test() {
  let schema = city_schema()
  let a1 =
    agent.new(provider.openai("gpt-4o", "sk-1"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_failure)
    |> agent.with_retries(0)
  let a2 =
    agent.new(provider.openai("gpt-4o", "sk-2"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_failure)
    |> agent.with_retries(0)

  let result = glroute.route_parallel([a1, a2], "test", Nil)
  should.equal(result.ok_count, 0)
  should.equal(result.error_count, 2)
}

pub fn parallel_empty_test() {
  let result = glroute.route_parallel([], "test", Nil)
  should.equal(result.ok_count, 0)
  should.equal(result.error_count, 0)
  should.equal(result.results, [])
}

pub fn parallel_preserves_order_test() {
  let schema = city_schema()
  let a1 =
    agent.new(provider.openai("gpt-4o", "sk-1"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_success("Paris", "France"))
  let a2 =
    agent.new(provider.openai("gpt-4o", "sk-2"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_success("Berlin", "Germany"))
  let a3 =
    agent.new(provider.openai("gpt-4o", "sk-3"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_success("Tokyo", "Japan"))

  let result = glroute.route_parallel([a1, a2, a3], "test", Nil)
  // Results should be sorted by index (priority order)
  let assert [r1, r2, r3] = result.results
  should.equal(r1.index, 0)
  should.equal(r2.index, 1)
  should.equal(r3.index, 2)
}

pub fn parallel_is_actually_parallel_test() {
  // Each mock sleeps 100ms. If sequential, 3*100=300ms.
  // If parallel, ~100-150ms. We test that parallel completes quickly.
  let schema = city_schema()
  let a1 =
    agent.new(provider.openai("gpt-4o", "sk-1"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_delayed_success("Paris", "France", 100))
  let a2 =
    agent.new(provider.openai("gpt-4o", "sk-2"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_delayed_success("Berlin", "Germany", 100))
  let a3 =
    agent.new(provider.openai("gpt-4o", "sk-3"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_delayed_success("Tokyo", "Japan", 100))

  let start = monotonic_ms()
  let result = glroute.route_parallel([a1, a2, a3], "test", Nil)
  let elapsed = monotonic_ms() - start

  should.equal(result.ok_count, 3)
  // Parallel should be significantly faster than sequential (300ms)
  // Allow generous margin for CI: must be < 250ms
  should.be_true(elapsed < 250)
}

pub fn parallel_timeout_test() {
  let schema = city_schema()
  let a1 =
    agent.new(provider.openai("gpt-4o", "sk-1"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_delayed_success("Paris", "France", 200))

  // Very short timeout — should timeout
  let result = glroute.route_parallel_with_timeout([a1], "test", Nil, 50)
  should.equal(result.ok_count, 0)
  should.equal(result.error_count, 1)
}

pub fn parallel_openai_compatible_test() {
  let schema = city_schema()
  let ollama =
    agent.new(provider.openai_compatible(
      "llama3",
      "http://localhost:11434/v1",
      "ollama",
    ))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_success("Paris", "France"))
  let openai =
    agent.new(provider.openai("gpt-4o", "sk-1"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_success("Berlin", "Germany"))

  let result = glroute.route_parallel([ollama, openai], "test", Nil)
  should.equal(result.ok_count, 2)
}

import gleam/list

fn list_length(l: List(a)) -> Int {
  list.length(l)
}

import gleam/erlang/atom

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: atom.Atom) -> Int

fn monotonic_ms() -> Int {
  monotonic_time(atom.create("millisecond"))
}
