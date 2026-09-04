import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import glroute/agent.{type Agent}
import glroute/errors as glroute_errors
import glroute/strategies/priority
import glroute/usage.{type RunResult}
import mist

// ---------------------------------------------------------------------------
// Server - OpenAI-compatible address with CORS & API key security
// ---------------------------------------------------------------------------

pub type ServerConfig {
  ServerConfig(
    port: Int,
    host: String,
    api_key: Option(String),
    allowed_origin: Option(String),
  )
}

pub fn default_config(port: Int) -> ServerConfig {
  ServerConfig(
    port: port,
    host: "0.0.0.0",
    api_key: None,
    allowed_origin: Some("*"),
  )
}

pub fn with_api_key(config: ServerConfig, api_key: String) -> ServerConfig {
  ServerConfig(..config, api_key: Some(api_key))
}

pub fn with_allowed_origin(config: ServerConfig, origin: String) -> ServerConfig {
  ServerConfig(..config, allowed_origin: Some(origin))
}

pub fn serve(agents: List(Agent(Nil, String)), port: Int) -> Result(Nil, String) {
  serve_with_config(agents, default_config(port))
}

pub fn serve_with_config(
  agents: List(Agent(Nil, String)),
  config: ServerConfig,
) -> Result(Nil, String) {
  let handler = make_handler(agents, config)

  case
    mist.new(handler)
    |> mist.port(config.port)
    |> mist.bind(config.host)
    |> mist.start()
  {
    Ok(_) -> Ok(Nil)
    Error(e) ->
      Error(
        "glroute: failed to start server on port "
        <> int_to_string(config.port)
        <> ": "
        <> string_inspect(e),
      )
  }
}

fn make_handler(
  agents: List(Agent(Nil, String)),
  config: ServerConfig,
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  fn(req: request.Request(mist.Connection)) {
    case req.method {
      http.Options -> options_response(config)
      _ -> {
        let resp = case req.method, request.path_segments(req) {
          _, ["health"] -> health_response()
          _, ["v1", "models"] -> models_response(req, agents, config)
          _, ["v1", "chat", "completions"] ->
            handle_chat_completions(req, agents, config)
          _, ["chat", "completions"] ->
            handle_chat_completions(req, agents, config)
          _, _ -> not_found_response()
        }
        with_cors(resp, config)
      }
    }
  }
}

fn options_response(
  config: ServerConfig,
) -> response.Response(mist.ResponseData) {
  let origin = option.unwrap(config.allowed_origin, "*")
  response.new(204)
  |> response.set_header("access-control-allow-origin", origin)
  |> response.set_header("access-control-allow-methods", "GET, POST, OPTIONS")
  |> response.set_header(
    "access-control-allow-headers",
    "Authorization, Content-Type",
  )
  |> response.set_body(mist.Bytes(bytes_tree.new()))
}

fn with_cors(
  resp: response.Response(mist.ResponseData),
  config: ServerConfig,
) -> response.Response(mist.ResponseData) {
  let origin = option.unwrap(config.allowed_origin, "*")
  resp
  |> response.set_header("access-control-allow-origin", origin)
  |> response.set_header("access-control-allow-methods", "GET, POST, OPTIONS")
  |> response.set_header(
    "access-control-allow-headers",
    "Authorization, Content-Type",
  )
}

fn verify_api_key(
  req: request.Request(mist.Connection),
  config: ServerConfig,
) -> Result(Nil, String) {
  case config.api_key {
    None -> Ok(Nil)
    Some(expected) -> {
      case request.get_header(req, "authorization") {
        Ok("Bearer " <> key) if key == expected -> Ok(Nil)
        Ok(key) if key == expected -> Ok(Nil)
        _ -> Error("Invalid or missing API key")
      }
    }
  }
}

fn health_response() -> response.Response(mist.ResponseData) {
  let body = json.object([#("status", json.string("ok"))]) |> json.to_string
  response.new(200)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn models_response(
  req: request.Request(mist.Connection),
  agents: List(Agent(Nil, String)),
  config: ServerConfig,
) -> response.Response(mist.ResponseData) {
  case verify_api_key(req, config) {
    Error(msg) -> error_response(401, msg)
    Ok(Nil) -> {
      let models =
        agents
        |> list.index_map(fn(ag, idx) {
          let name = get_model_name(ag)
          json.object([
            #("id", json.string(name)),
            #("object", json.string("model")),
            #("created", json.int(0)),
            #("owned_by", json.string("glroute")),
            #("index", json.int(idx)),
          ])
        })

      let body =
        json.object([
          #("object", json.string("list")),
          #("data", json.preprocessed_array(models)),
        ])
        |> json.to_string

      response.new(200)
      |> response.set_header("content-type", "application/json")
      |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
    }
  }
}

fn not_found_response() -> response.Response(mist.ResponseData) {
  let body =
    json.object([#("error", json.string("not found"))]) |> json.to_string
  response.new(404)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn handle_chat_completions(
  req: request.Request(mist.Connection),
  agents: List(Agent(Nil, String)),
  config: ServerConfig,
) -> response.Response(mist.ResponseData) {
  case verify_api_key(req, config) {
    Error(msg) -> error_response(401, msg)
    Ok(Nil) -> {
      case req.method {
        http.Post -> handle_chat_post(req, agents)
        _ ->
          response.new(405)
          |> response.set_header("content-type", "application/json")
          |> response.set_body(
            mist.Bytes(bytes_tree.from_string(
              json.object([#("error", json.string("method not allowed"))])
              |> json.to_string,
            )),
          )
      }
    }
  }
}

fn handle_chat_post(
  req: request.Request(mist.Connection),
  agents: List(Agent(Nil, String)),
) -> response.Response(mist.ResponseData) {
  case mist.read_body(req, 1_000_000) {
    Error(_) -> error_response(400, "invalid request body")
    Ok(req_with_body) -> {
      let body_string = bit_array.to_string(req_with_body.body)
      case body_string {
        Ok(body_str) -> handle_chat_body(body_str, agents)
        Error(_) -> error_response(400, "invalid body encoding")
      }
    }
  }
}

fn handle_chat_body(
  body_str: String,
  agents: List(Agent(Nil, String)),
) -> response.Response(mist.ResponseData) {
  case parse_chat_request(body_str) {
    Error(msg) -> error_response(400, msg)
    Ok(chat_req) -> {
      case priority.route_priority(agents, chat_req.prompt, Nil) {
        Ok(result) -> success_chat_response(result, chat_req.model)
        Error(e) ->
          error_response(500, "all providers failed: " <> errors_to_string(e))
      }
    }
  }
}

type ChatRequest {
  ChatRequest(model: String, prompt: String)
}

fn parse_chat_request(body: String) -> Result(ChatRequest, String) {
  let message_decoder = {
    use role <- decode.field("role", decode.string)
    use content <- decode.field("content", decode.string)
    decode.success(#(role, content))
  }

  let decoder = {
    use model <- decode.optional_field("model", "default", decode.string)
    use messages <- decode.field("messages", decode.list(message_decoder))
    decode.success(#(model, messages))
  }

  case json.parse(from: body, using: decoder) {
    Error(_) -> Error("invalid JSON or missing messages")
    Ok(#(model, messages)) -> {
      let prompt = find_last_user_message(messages)
      case prompt {
        Some(p) -> Ok(ChatRequest(model: model, prompt: p))
        None -> Error("no user message found")
      }
    }
  }
}

fn find_last_user_message(messages: List(#(String, String))) -> Option(String) {
  messages
  |> list.filter(fn(pair) { pair.0 == "user" })
  |> list.last
  |> result.map(fn(pair) { pair.1 })
  |> option.from_result
}

fn success_chat_response(
  result: RunResult(String),
  model: String,
) -> response.Response(mist.ResponseData) {
  let body =
    json.object([
      #("id", json.string("chatcmpl-glroute")),
      #("object", json.string("chat.completion")),
      #("created", json.int(0)),
      #("model", json.string(model)),
      #(
        "choices",
        json.preprocessed_array([
          json.object([
            #("index", json.int(0)),
            #(
              "message",
              json.object([
                #("role", json.string("assistant")),
                #("content", json.string(result.output)),
              ]),
            ),
            #("finish_reason", json.string("stop")),
          ]),
        ]),
      ),
      #(
        "usage",
        json.object([
          #("prompt_tokens", json.int(result.usage.input_tokens)),
          #("completion_tokens", json.int(result.usage.output_tokens)),
          #("total_tokens", json.int(result.usage.total_tokens)),
        ]),
      ),
    ])
    |> json.to_string

  response.new(200)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn error_response(
  status: Int,
  message: String,
) -> response.Response(mist.ResponseData) {
  let body =
    json.object([
      #(
        "error",
        json.object([
          #("message", json.string(message)),
          #("type", json.string("server_error")),
        ]),
      ),
    ])
    |> json.to_string

  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn get_model_name(agent: Agent(Nil, String)) -> String {
  let model = agent.get_model(agent)
  model.model_name
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

fn string_inspect(v: a) -> String {
  let _ = v
  "error"
}

fn errors_to_string(e: glroute_errors.GlrouteError) -> String {
  glroute_errors.to_string(e)
}
