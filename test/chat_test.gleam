import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import glroute
import glroute/agent
import glroute/chat
import glroute/errors
import glroute/provider

// ---------------------------------------------------------------------------
// OpenAI-compatible proxy tests - full history, tools, streaming, fallback
// ---------------------------------------------------------------------------

const agent_request = "{\"model\":\"auto\",\"stream\":false,\"messages\":[{\"role\":\"system\",\"content\":\"You are an agent.\"},{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Weather in Baku?\"}]},{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"Baku\\\"}\"}}]},{\"role\":\"tool\",\"tool_call_id\":\"call_1\",\"content\":\"sunny\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"parameters\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}}}}}]}"

const text_completion = "{\"id\":\"chatcmpl-1\",\"object\":\"chat.completion\",\"created\":1,\"model\":\"upstream-model\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"It is sunny.\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":3,\"total_tokens\":8}}"

const tool_completion = "{\"id\":\"chatcmpl-2\",\"object\":\"chat.completion\",\"created\":1,\"model\":\"upstream-model\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"call_9\",\"type\":\"function\",\"extra_content\":{\"google\":{\"thought_signature\":\"sig\"}},\"function\":{\"name\":\"get_weather\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}"

fn respond(status: Int, body: String) {
  fn(_req: request.Request(String)) {
    Ok(response.new(status) |> response.set_body(body))
  }
}

fn upstream_field(
  body: String,
  field: String,
  decoder: decode.Decoder(a),
) -> a {
  let assert Ok(value) = json.parse(body, decode.at([field], decoder))
  value
}

pub fn parse_request_rejects_invalid_json_test() {
  chat.parse_request("not json") |> should.be_error
}

pub fn parse_request_rejects_missing_messages_test() {
  chat.parse_request("{\"model\":\"x\"}") |> should.be_error
  chat.parse_request("{\"messages\":[]}") |> should.be_error
}

pub fn parse_request_reads_stream_flags_test() {
  let assert Ok(req) =
    chat.parse_request(
      "{\"model\":\"m\",\"stream\":true,\"stream_options\":{\"include_usage\":true},\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}",
    )
  chat.is_stream(req) |> should.be_true
  chat.requested_model(req) |> should.equal("m")
}

pub fn build_body_forwards_history_and_tools_test() {
  let assert Ok(req) = chat.parse_request(agent_request)
  let body = chat.build_body(req, "gpt-4o", None, None, None)

  upstream_field(body, "model", decode.string) |> should.equal("gpt-4o")
  upstream_field(body, "stream", decode.bool) |> should.be_false
  upstream_field(body, "messages", decode.list(decode.dynamic))
  |> list.length
  |> should.equal(4)
  upstream_field(body, "tools", decode.list(decode.dynamic))
  |> list.length
  |> should.equal(1)
  string.contains(body, "\"tool_call_id\":\"call_1\"") |> should.be_true
}

pub fn instructions_are_prepended_as_system_message_test() {
  let assert Ok(req) =
    chat.parse_request(
      "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}",
    )
  let body = chat.build_body(req, "m", option.Some("Be terse."), None, None)
  let assert Ok(first_role) =
    json.parse(
      body,
      decode.at(["messages"], decode.list(decode.at(["role"], decode.string))),
    )
  first_role |> should.equal(["system", "user"])
}

pub fn complete_uses_gemini_openai_endpoint_test() {
  let assert Ok(req) = chat.parse_request(agent_request)
  let client = fn(r: request.Request(String)) {
    should.equal(r.path, "/v1beta/openai/chat/completions")
    should.equal(request.get_header(r, "authorization"), Ok("Bearer AIza-test"))
    Ok(response.new(200) |> response.set_body(text_completion))
  }
  let a =
    agent.new(provider.gemini("gemini-2.5-flash", "AIza-test"))
    |> agent.with_http_client(client)

  let assert Ok(completion) = agent.complete(a, req)
  completion.served_by |> should.equal("gemini-2.5-flash")
  completion.model |> should.equal("upstream-model")
}

pub fn route_chat_falls_back_on_failure_test() {
  let assert Ok(req) = chat.parse_request(agent_request)
  let failing =
    agent.new(provider.openai("primary", "sk-1"))
    |> agent.with_http_client(respond(500, "boom"))
    |> agent.with_retries(0)
  let succeeding =
    agent.new(provider.openai_compatible("backup", "http://x/v1", "k"))
    |> agent.with_http_client(respond(200, tool_completion))

  let assert Ok(completion) = glroute.route_chat([failing, succeeding], req)
  completion.served_by |> should.equal("backup")
  completion.body |> should.equal(tool_completion)
}

pub fn route_chat_falls_back_on_empty_choices_test() {
  let assert Ok(req) = chat.parse_request(agent_request)
  let empty =
    agent.new(provider.openai("primary", "sk-1"))
    |> agent.with_http_client(respond(200, "{\"choices\":[]}"))
    |> agent.with_retries(0)
  let good =
    agent.new(provider.openai("backup", "sk-2"))
    |> agent.with_http_client(respond(200, text_completion))

  let assert Ok(completion) = glroute.route_chat([empty, good], req)
  completion.served_by |> should.equal("backup")
}

pub fn route_chat_reports_every_failure_test() {
  let assert Ok(req) = chat.parse_request(agent_request)
  let a1 =
    agent.new(provider.openai("one", "sk-1"))
    |> agent.with_http_client(respond(401, "bad key"))
    |> agent.with_retries(0)
  let a2 =
    agent.new(provider.openai("two", "sk-2"))
    |> agent.with_http_client(respond(503, "down"))
    |> agent.with_retries(0)

  let assert Error(errors.ProviderError(msg)) =
    glroute.route_chat([a1, a2], req)
  string.contains(msg, "one: ") |> should.be_true
  string.contains(msg, "two: ") |> should.be_true
}

pub fn to_sse_streams_tool_calls_test() {
  let assert Ok(req) =
    chat.parse_request(
      "{\"stream\":true,\"stream_options\":{\"include_usage\":true},\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}",
    )
  let completion =
    chat.Completion(body: tool_completion, model: "m", served_by: "m")
  let sse = chat.to_sse(completion, req)

  string.contains(sse, "\"object\":\"chat.completion.chunk\"") |> should.be_true
  string.contains(sse, "\"index\":0") |> should.be_true
  string.contains(sse, "\"thought_signature\":\"sig\"") |> should.be_true
  string.contains(sse, "\"finish_reason\":\"tool_calls\"") |> should.be_true
  string.ends_with(sse, "data: [DONE]\n\n") |> should.be_true
}

pub fn to_sse_includes_usage_only_when_requested_test() {
  let completion =
    chat.Completion(body: text_completion, model: "m", served_by: "m")
  let assert Ok(with_usage) =
    chat.parse_request(
      "{\"stream\":true,\"stream_options\":{\"include_usage\":true},\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}",
    )
  let assert Ok(without_usage) =
    chat.parse_request(
      "{\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}",
    )

  string.contains(chat.to_sse(completion, with_usage), "\"total_tokens\":8")
  |> should.be_true
  string.contains(chat.to_sse(completion, without_usage), "\"usage\"")
  |> should.be_false
}

// End-to-end through the real mist server: history + tools in, SSE out.
pub fn server_proxies_agent_request_test() {
  let upstream =
    agent.new(provider.openai("served-model", "sk"))
    |> agent.with_http_client(fn(r: request.Request(String)) {
      case string.contains(r.body, "\"tool_call_id\":\"call_1\"") {
        True -> Ok(response.new(200) |> response.set_body(tool_completion))
        False -> Ok(response.new(400) |> response.set_body("history lost"))
      }
    })
  let port = 38_417
  let config =
    glroute.default_server_config(port)
    |> glroute.with_api_key("secret")
  let assert Ok(_) = glroute.serve_with_config([upstream], config)
  process.sleep(200)

  let streaming_body =
    string.replace(agent_request, "\"stream\":false", "\"stream\":true")
  let assert Ok(base) =
    request.to(
      "http://127.0.0.1:" <> int_to_string(port) <> "/v1/chat/completions",
    )
  let req =
    base
    |> request.set_method(http.Post)
    |> request.set_header("authorization", "Bearer secret")
    |> request.set_header("content-type", "application/json")
    |> request.set_body(streaming_body)

  let assert Ok(resp) = httpc.send(req)
  resp.status |> should.equal(200)
  response.get_header(resp, "x-glroute-model")
  |> should.equal(Ok("served-model"))
  response.get_header(resp, "content-type")
  |> should.equal(Ok("text/event-stream"))
  string.contains(resp.body, "get_weather") |> should.be_true
}

fn int_to_string(n: Int) -> String {
  json.int(n) |> json.to_string
}
