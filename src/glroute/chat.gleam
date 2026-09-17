import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

// ---------------------------------------------------------------------------
// ChatRequest - Full OpenAI-compatible request model
// ---------------------------------------------------------------------------

pub type Tool {
  Tool(
    name: String,
    description: String,
    parameters: json.Json,
  )
}

pub type ContentPart {
  Text(text: String)
  Image(image_url: String, detail: String)
  ToolUse(id: String, name: String, input: json.Json)
  ToolResult(id: String, content: String)
}

pub type Message {
  Message(role: String, content: json.Json)
}

pub type Completion {
  Completion(
    body: String,
    model: String,
    served_by: String,
  )
}

// ---------------------------------------------------------------------------
// Parse incoming OpenAI-compatible chat request
// ---------------------------------------------------------------------------

fn message_decoder() -> decode.Decoder(Message) {
  use role <- decode.field("role", decode.string)
  use content <- decode.field("content", decode.json)
  decode.success(Message(role, content))
}

pub fn parse_request(body: String) -> Result(ChatRequest, String) {
  let tool_decoder = {
    use name <- decode.field("name", decode.string)
    use description <- decode.optional_field("description", "", decode.string)
    use parameters <- decode.optional_field("parameters", json.object([]), decode.json)
    decode.success(Tool(name, description, parameters))
  }

  let request_decoder = {
    use model <- decode.optional_field("model", "default", decode.string)
    use messages <- decode.field("messages", decode.list(message_decoder()))
    use tools <- decode.optional_field("tools", [], decode.list(tool_decoder))
    use temperature <- decode.optional_field("temperature", None, decode.float)
    use max_tokens <- decode.optional_field("max_tokens", None, decode.int)
    use stream <- decode.optional_field("stream", False, decode.bool)
    decode.success(ChatRequest(
      model: model,
      messages: messages,
      tools: tools,
      temperature: temperature,
      max_tokens: max_tokens,
      stream: stream,
    ))
  }

  case json.parse(from: body, using: request_decoder) {
    Ok(req) -> Ok(req)
    Error(e) -> Error("invalid JSON: " <> string_inspect(e))
  }
}

// ---------------------------------------------------------------------------
// Build request body for a provider
// ---------------------------------------------------------------------------

pub fn build_body(
  request: ChatRequest,
  model_name: String,
  instructions: Option(String),
  temperature: Option(Float),
  max_tokens: Option(Int),
) -> String {
  let sys_messages = case instructions {
    Some(sys) -> [
      Message(role: "system", content: json.string(sys))
    ]
    None -> []
  }

  let all_messages = sys_messages <> request.messages

  let messages_json = list.map(all_messages, fn(msg) {
    json.object([
      #("role", json.string(msg.role)),
      #("content", msg.content),
    ])
  })

  let tools_json = case request.tools {
    [] -> None
    ts -> Some(list.map(ts, fn(t) {
      json.object([
        #("type", json.string("function")),
        #("function", json.object([
          #("name", json.string(t.name)),
          #("description", json.string(t.description)),
          #("parameters", t.parameters),
        ])),
      ])
    }))
  }

  let fields = list.append(
    [#("model", json.string(model_name)), #("messages", json.preprocessed_array(messages_json))],
    case tools_json {
      Some(t) -> [#("tools", json.preprocessed_array(t))]
      None -> []
    },
  )

  let fields = case temperature {
    Some(t) -> list.append(fields, [#("temperature", json.float(t))])
    None -> fields
  }

  let fields = case max_tokens {
    Some(m) -> list.append(fields, [#("max_tokens", json.int(m))])
    None -> fields
  }

  json.object(fields) |> json.to_string
}

pub fn validate_response(raw: String) -> Result(String, String) {
  let decoder = {
    use choices <- decode.field("choices", decode.list({
      use content <- decode.optional_field("message", None, decode.object([
        #("content", decode.optional(decode.string)),
      ]))
      use tool_calls <- decode.optional_field("tool_calls", None, decode.list({
        use id <- decode.field("id", decode.string)
        use name <- decode.field("name", decode.string)
        use args <- decode.field("arguments", decode.string)
        decode.success(#(id, name, args))
      }))
      decode.success(#(content, tool_calls))
    }))
    use model <- decode.optional_field("model", None, decode.string)
    decode.success(#(choices, model))
  }

  case json.parse(from: raw, using: decoder) {
    Ok(#(choices, model)) -> {
      case choices {
        [] -> Error("No choices in response")
        [#(Some(content), _), ..] -> Ok(content)
        [#(None, Some(tool_calls)), ..] if tool_calls != [] ->
          Ok(tool_calls |> list.first |> result.unwrap("", fn(tc) { tc.2 }))
        [#(None, _), ..] ->
          case model {
            Some(m) -> Ok(m)
            None -> Error("Empty response")
          }
        _ -> Error("Unexpected response format")
      }
    }
    Error(e) -> Error("Failed to parse response: " <> string_inspect(e))
  }
}

fn string_inspect(_v: a) -> String {
  "error"
}
