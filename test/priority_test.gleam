import gdantic_ai/agent
import gdantic_ai/errors
import gdantic_ai/provider
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
  Ok(response.new(500) |> response.set_body("internal error"))
}

fn mock_text_success(text: String) {
  fn(_req) {
    let body =
      "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\""
      <> text
      <> "\"}}]}"
    Ok(response.new(200) |> response.set_body(body))
  }
}

// ---------------------------------------------------------------------------
// Priority tests - sequential fallback
// ---------------------------------------------------------------------------

pub fn priority_first_success_test() {
  let schema = city_schema()
  let a1 =
    agent.new(provider.openai("gpt-4o", "sk-test"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_success("Paris", "France"))
  let a2 =
    agent.new(provider.openai("gpt-4o", "sk-test2"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_success("Berlin", "Germany"))

  let result = glroute.route_priority([a1, a2], "test", Nil)
  should.be_ok(result)
  let assert Ok(res) = result
  should.equal(res.output, City("Paris", "France"))
}

pub fn priority_fallback_on_failure_test() {
  let schema = city_schema()
  let a1 =
    agent.new(provider.openai("gpt-4o", "sk-test"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_failure)
    |> agent.with_retries(0)
  let a2 =
    agent.new(provider.openai("gpt-4o", "sk-test2"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_success("Tokyo", "Japan"))

  let result = glroute.route_priority([a1, a2], "test", Nil)
  should.be_ok(result)
  let assert Ok(res) = result
  should.equal(res.output, City("Tokyo", "Japan"))
}

pub fn priority_all_fail_test() {
  let schema = city_schema()
  let a1 =
    agent.new(provider.openai("gpt-4o", "sk-test"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_failure)
    |> agent.with_retries(0)
  let a2 =
    agent.new(provider.openai("gpt-4o", "sk-test2"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_failure)
    |> agent.with_retries(0)

  let result = glroute.route_priority([a1, a2], "test", Nil)
  should.be_error(result)
}

pub fn priority_empty_list_test() {
  let result = glroute.route_priority([], "test", Nil)
  should.be_error(result)
}

pub fn priority_text_agents_test() {
  let a1 =
    agent.new(provider.openai("gpt-4o", "sk-test"))
    |> agent.with_http_client(mock_failure)
    |> agent.with_retries(0)
  let a2 =
    agent.new(provider.openai("gpt-4o", "sk-test2"))
    |> agent.with_http_client(mock_text_success("Hello"))

  let result = glroute.route_priority([a1, a2], "Say hello", Nil)
  should.be_ok(result)
  let assert Ok(res) = result
  should.equal(res.output, "Hello")
}

pub fn priority_preserves_order_test() {
  // Third agent should never be called if first succeeds
  let schema = city_schema()
  let a1 =
    agent.new(provider.openai("gpt-4o", "sk-test"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_success("Paris", "France"))
  let a2 =
    agent.new(provider.openai("gpt-4o", "sk-test2"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_failure)
    |> agent.with_retries(0)
  let a3 =
    agent.new(provider.openai("gpt-4o", "sk-test3"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_success("Berlin", "Germany"))

  let result = glroute.route_priority([a1, a2, a3], "test", Nil)
  should.be_ok(result)
  let assert Ok(res) = result
  should.equal(res.output, City("Paris", "France"))
}
