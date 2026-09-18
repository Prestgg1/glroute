import gleam/erlang/process
import gleam/http/response
import gleeunit/should
import glon
import glroute
import glroute/agent
import glroute/chat
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

fn mock_delayed_text(delay_ms: Int, text: String) {
  fn(_req) {
    process.sleep(delay_ms)
    let body =
      "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\""
      <> text
      <> "\"}}]}"
    Ok(response.new(200) |> response.set_body(body))
  }
}

// ---------------------------------------------------------------------------
// Combo tests - multiple lists with Priority or Fusion strategies
// ---------------------------------------------------------------------------

pub fn priority_combo_executes_sequentially_test() {
  let schema = city_schema()
  let a1 =
    agent.new(provider.openai("gpt-4o", "sk-1"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_success("London", "UK"))
  let a2 =
    agent.new(provider.openai("gpt-4o-mini", "sk-2"))
    |> agent.with_glon(schema)
    |> agent.with_http_client(mock_success("Paris", "France"))

  let my_combo = glroute.priority_combo("smart-priority", [a1, a2])

  let result = glroute.route_combo(my_combo, "prompt", Nil)
  should.be_ok(result)
  let assert Ok(res) = result
  should.equal(res.output, City("London", "UK"))
}

pub fn fusion_combo_executes_in_parallel_test() {
  let a1 =
    agent.new(provider.openai("slow-agent", "sk-1"))
    |> agent.with_http_client(mock_delayed_text(150, "slow answer"))
  let a2 =
    agent.new(provider.openai("fast-agent", "sk-2"))
    |> agent.with_http_client(mock_delayed_text(10, "fast answer"))

  let my_combo = glroute.fusion_combo("fast-fusion", [a1, a2])

  let result = glroute.route_combo(my_combo, "prompt", Nil)
  should.be_ok(result)
  let assert Ok(res) = result
  should.equal(res.output, "fast answer")
}

pub fn multiple_combos_route_by_name_test() {
  let a1 =
    agent.new(provider.openai("agent-1", "sk-1"))
    |> agent.with_http_client(mock_delayed_text(0, "from combo 1"))
  let a2 =
    agent.new(provider.openai("agent-2", "sk-2"))
    |> agent.with_http_client(mock_delayed_text(0, "from combo 2"))

  let combo1 = glroute.priority_combo("group-a", [a1])
  let combo2 = glroute.priority_combo("group-b", [a2])

  let combos = [combo1, combo2]

  let res1 = glroute.route_combos(combos, "group-a", "test", Nil)
  should.be_ok(res1)
  let assert Ok(r1) = res1
  should.equal(r1.output, "from combo 1")

  let res2 = glroute.route_combos(combos, "group-b", "test", Nil)
  should.be_ok(res2)
  let assert Ok(r2) = res2
  should.equal(r2.output, "from combo 2")
}

pub fn multiple_combos_chat_routing_test() {
  let resp_a =
    "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"combo-a win\"}}]}"
  let resp_b =
    "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"combo-b win\"}}]}"

  let a1 =
    agent.new(provider.openai("model-a", "sk-1"))
    |> agent.with_http_client(fn(_req) {
      Ok(response.new(200) |> response.set_body(resp_a))
    })

  let a2 =
    agent.new(provider.openai("model-b", "sk-2"))
    |> agent.with_http_client(fn(_req) {
      Ok(response.new(200) |> response.set_body(resp_b))
    })

  let combo_a = glroute.priority_combo("fast-combo", [a1])
  let combo_b = glroute.fusion_combo("smart-combo", [a2])
  let combos = [combo_a, combo_b]

  // Request explicitly targeting "smart-combo"
  let assert Ok(req_smart) =
    chat.parse_request(
      "{\"model\":\"smart-combo\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}",
    )
  let assert Ok(compl_smart) = glroute.route_chat_combos(combos, req_smart)
  compl_smart.served_by |> should.equal("model-b")
  compl_smart.body |> should.equal(resp_b)

  // Request targeting "auto" falls back to first combo ("fast-combo")
  let assert Ok(req_auto) =
    chat.parse_request(
      "{\"model\":\"auto\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}",
    )
  let assert Ok(compl_auto) = glroute.route_chat_combos(combos, req_auto)
  compl_auto.served_by |> should.equal("model-a")
  compl_auto.body |> should.equal(resp_a)
}
