import gleam/erlang/process
import gleam/http/response
import gleam/string
import gleeunit/should
import glon
import glroute
import glroute/agent
import glroute/chat
import glroute/errors
import glroute/provider

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

fn mock_delayed_success(delay_ms: Int, city: String, country: String) {
  let handler = mock_success(city, country)
  fn(req) {
    process.sleep(delay_ms)
    handler(req)
  }
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

fn mock_delayed_text(delay_ms: Int, text: String) {
  let handler = mock_text_success(text)
  fn(req) {
    process.sleep(delay_ms)
    handler(req)
  }
}

fn mock_failure(
  _req,
) -> Result(response.Response(String), errors.GlrouteError) {
  Ok(response.new(500) |> response.set_body("internal error"))
}

// ---------------------------------------------------------------------------
// Fusion tests - parallel racing (fastest valid response wins)
// ---------------------------------------------------------------------------

pub fn fusion_fastest_wins_test() {
  // Agent 1 is slow (150ms), Agent 2 is fast (10ms)
  // Even though Agent 1 is first in the list, Agent 2 MUST win the fusion race
  let a1 =
    agent.new(provider.openai("slow-model", "sk-1"))
    |> agent.with_http_client(mock_delayed_text(150, "Slow response"))
  let a2 =
    agent.new(provider.openai("fast-model", "sk-2"))
    |> agent.with_http_client(mock_delayed_text(10, "Fast response"))

  let result = glroute.route_fusion([a1, a2], "prompt", Nil)
  should.be_ok(result)
  let assert Ok(res) = result
  should.equal(res.output, "Fast response")
}

pub fn fusion_structured_fastest_wins_test() {
  let schema = city_schema()
  let a1 =
    agent.new(provider.openai("slow-model", "sk-1"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_delayed_success(150, "Rome", "Italy"))
  let a2 =
    agent.new(provider.openai("fast-model", "sk-2"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_delayed_success(10, "Tokyo", "Japan"))

  let result = glroute.route_fusion([a1, a2], "prompt", Nil)
  should.be_ok(result)
  let assert Ok(res) = result
  should.equal(res.output, City("Tokyo", "Japan"))
}

pub fn fusion_continues_if_one_fails_test() {
  // Agent 1 fails immediately, Agent 2 succeeds after a slight delay
  // Agent 2 should win despite Agent 1 failing
  let a1 =
    agent.new(provider.openai("failing-model", "sk-1"))
    |> agent.with_http_client(mock_failure)
    |> agent.with_retries(0)
  let a2 =
    agent.new(provider.openai("succeeding-model", "sk-2"))
    |> agent.with_http_client(mock_delayed_text(20, "Success from backup"))

  let result = glroute.route_fusion([a1, a2], "prompt", Nil)
  should.be_ok(result)
  let assert Ok(res) = result
  should.equal(res.output, "Success from backup")
}

pub fn fusion_all_fail_test() {
  let a1 =
    agent.new(provider.openai("model-1", "sk-1"))
    |> agent.with_http_client(mock_failure)
    |> agent.with_retries(0)
  let a2 =
    agent.new(provider.openai("model-2", "sk-2"))
    |> agent.with_http_client(mock_failure)
    |> agent.with_retries(0)

  let result = glroute.route_fusion([a1, a2], "prompt", Nil)
  should.be_error(result)
  let assert Error(errors.ProviderError(msg)) = result
  string.contains(msg, "all agents failed in fusion race") |> should.be_true
  string.contains(msg, "model-1:") |> should.be_true
  string.contains(msg, "model-2:") |> should.be_true
}

pub fn fusion_empty_list_test() {
  let result = glroute.route_fusion([], "prompt", Nil)
  should.be_error(result)
}

pub fn fusion_timeout_test() {
  // Agent takes 200ms, but timeout is 50ms
  let a1 =
    agent.new(provider.openai("very-slow-model", "sk-1"))
    |> agent.with_http_client(mock_delayed_text(200, "Too late"))

  let result = glroute.route_fusion_with_timeout([a1], "prompt", Nil, 50)
  should.be_error(result)
  let assert Error(errors.ProviderError(msg)) = result
  string.contains(msg, "timed out") |> should.be_true
}

pub fn fusion_chat_fastest_wins_test() {
  let assert Ok(req) =
    chat.parse_request(
      "{\"model\":\"auto\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}",
    )

  let slow_resp =
    "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"slow\"}}]}"
  let fast_resp =
    "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"fast\"}}]}"

  let a1 =
    agent.new(provider.openai("slow-agent", "sk-1"))
    |> agent.with_http_client(fn(_req) {
      process.sleep(150)
      Ok(response.new(200) |> response.set_body(slow_resp))
    })

  let a2 =
    agent.new(provider.openai("fast-agent", "sk-2"))
    |> agent.with_http_client(fn(_req) {
      process.sleep(10)
      Ok(response.new(200) |> response.set_body(fast_resp))
    })

  let result = glroute.route_chat_fusion([a1, a2], req)
  should.be_ok(result)
  let assert Ok(completion) = result
  completion.served_by |> should.equal("fast-agent")
  completion.body |> should.equal(fast_resp)
}
