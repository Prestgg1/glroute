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

// ---------------------------------------------------------------------------
// Server tests - verify BEAM parallel handling of incoming requests
// Parallel here = many clients calling concurrently, each in its own BEAM process
// This is what the server (mist) does: each POST /v1/chat/completions runs
// in its own Erlang process, so parallel requests don't block each other.
// We simulate this by spawning multiple processes that each call route_priority
// concurrently — just like mist would for real HTTP requests.
// ---------------------------------------------------------------------------

pub fn concurrent_requests_via_beam_test() {
  // Simulate what the server does: many parallel incoming requests
  // Each request calls route_priority in its own process — BEAM handles concurrently
  let schema = city_schema()
  let agents = [
    agent.new(provider.openai("gpt-4o", "sk-test"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_success("Paris", "France")),
  ]

  // Spawn 5 concurrent “requests” (like 5 clients POSTing at once)
  let subject = process.new_subject()
  let count = 5

  list_each_range(count, fn(i) {
    let _ =
      process.spawn_unlinked(fn() {
        // Each simulates a separate HTTP request handled in its own BEAM process
        let result =
          glroute.route_priority(
            agents,
            "test prompt " <> int_to_string(i),
            Nil,
          )
        process.send(subject, result)
      })
    Nil
  })

  // Collect all 5 results — all should succeed
  let results = collect(subject, count, 5000, [])
  should.equal(list_length(results), 5)
  // All should be Ok
  let ok_count = count_ok(results)
  should.equal(ok_count, 5)
}

pub fn concurrent_with_fallback_test() {
  // Priority fallback also works under concurrent load
  let schema = city_schema()
  let failing =
    agent.new(provider.openai("gpt-4o", "sk-fail"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_failure)
    |> agent.with_retries(0)
  let succeeding =
    agent.new(provider.openai("gpt-4o-mini", "sk-ok"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_success("Berlin", "Germany"))

  let agents = [failing, succeeding]

  // 3 parallel requests, each should fallback from failing to succeeding
  let subject = process.new_subject()
  list_each_range(3, fn(_i) {
    let _ =
      process.spawn_unlinked(fn() {
        let result = glroute.route_priority(agents, "test", Nil)
        process.send(subject, result)
      })
    Nil
  })

  let results = collect(subject, 3, 5000, [])
  should.equal(list_length(results), 3)
  should.equal(count_ok(results), 3)
}

pub fn server_priority_logic_test() {
  // Verify priority works for server's per-request routing
  let schema = city_schema()
  let a1 =
    agent.new(provider.openai("gpt-4o", "sk-1"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_failure)
    |> agent.with_retries(0)
  let a2 =
    agent.new(provider.openai("gpt-4o-mini", "sk-2"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_success("Tokyo", "Japan"))

  // Simulate what server does per request: route_priority
  let result = glroute.route_priority([a1, a2], "test", Nil)
  should.be_ok(result)
  let assert Ok(res) = result
  should.equal(res.output, City("Tokyo", "Japan"))
}

pub fn server_handles_many_parallel_clients_test() {
  // Stress test: 10 concurrent clients — BEAM should handle all
  let schema = city_schema()
  let agents = [
    agent.new(provider.openai("gpt-4o", "sk-test"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_success("Paris", "France")),
  ]

  let subject = process.new_subject()
  let count = 10
  list_each_range(count, fn(_i) {
    let _ =
      process.spawn_unlinked(fn() {
        let result = glroute.route_priority(agents, "test", Nil)
        process.send(subject, result)
      })
    Nil
  })

  let results = collect(subject, count, 5000, [])
  should.equal(list_length(results), 10)
  should.equal(count_ok(results), 10)
}

// Helpers

import gleam/list

fn list_each_range(count: Int, fun: fn(Int) -> Nil) -> Nil {
  do_range(0, count, fun)
}

fn do_range(current: Int, max: Int, fun: fn(Int) -> Nil) -> Nil {
  case current < max {
    True -> {
      fun(current)
      do_range(current + 1, max, fun)
    }
    False -> Nil
  }
}

fn collect(
  subject: process.Subject(Result(a, errors.GdanticError)),
  remaining: Int,
  timeout: Int,
  acc: List(Result(a, errors.GdanticError)),
) -> List(Result(a, errors.GdanticError)) {
  case remaining <= 0 {
    True -> acc
    False -> {
      case process.receive(subject, timeout) {
        Ok(v) -> collect(subject, remaining - 1, timeout, [v, ..acc])
        Error(_) -> acc
      }
    }
  }
}

fn count_ok(results: List(Result(a, e))) -> Int {
  case results {
    [] -> 0
    [Ok(_), ..tail] -> 1 + count_ok(tail)
    [Error(_), ..tail] -> count_ok(tail)
  }
}

fn list_length(l: List(a)) -> Int {
  list.length(l)
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
