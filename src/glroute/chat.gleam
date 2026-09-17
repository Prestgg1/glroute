import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

// ---------------------------------------------------------------------------
// ChatRequest - Full OpenAI-compatible request model
// ---------------------------------------------------------------------------

pub type Tool {
  Tool(name: String, description: String, parameters: json.Json)
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

pub fn message_role(msg: Message) -> String {
  msg.role
}

pub fn message_content(msg: Message) -> json.Json {
  msg.content
}

pub type ChatRequest {
  ChatRequest(
    model: String,
    messages: List(Message),
    tools: List(Tool),
    temperature: Option(Float),
    max_tokens: Option(Int),
    stream: Bool,
  )
}

pub type Completion {
  Completion(body: String, model: String, served_by: String)
}

// ---------------------------------------------------------------------------
// Parse incoming OpenAI-compatible chat request
// ---------------------------------------------------------------------------

pub fn parse_request(body: String) -> Result(ChatRequest, String) {
  let tool_decoder = {
    use name <- decode.field("name", decode.string)
    use description <- decode.optional_field("description", "", decode.string)
    decode.success(Tool(name, description, json.object([])))
  }

  let request_decoder = {
    use model <- decode.optional_field("model", "default", decode.string)
    use messages <- decode.field(
      "messages",
      decode.list({
        use role <- decode.field("role", decode.string)
        use content <- decode.field("content", decode.string)
        decode.success(Message(role, json.string(content)))
      }),
    )
    use tools <- decode.optional_field("tools", [], decode.list(tool_decoder))
    use temperature <- decode.optional_field(
      "temperature",
      None,
      decode.optional(decode.float),
    )
    use max_tokens <- decode.optional_field(
      "max_tokens",
      None,
      decode.optional(decode.int),
    )
    use stream <- decode.optional_field("stream", False, decode.bool)
    decode.success(ChatRequest(
      model,
      messages,
      tools,
      temperature,
      max_tokens,
      stream,
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
    Some(sys) -> [Message("system", json.string(sys))]
    None -> []
  }

  let all_messages = list.append(sys_messages, request.messages)

  let messages_json =
    list.map(all_messages, fn(msg) {
      json.object([
        #("role", json.string(message_role(msg))),
        #("content", message_content(msg)),
      ])
    })

  let tools_json = case request.tools {
    [] -> None
    ts ->
      Some(
        list.map(ts, fn(t) {
          json.object([
            #("type", json.string("function")),
            #(
              "function",
              json.object([
                #("name", json.string(t.name)),
                #("description", json.string(t.description)),
                #("parameters", t.parameters),
              ]),
            ),
          ])
        }),
      )
  }

  let fields =
    list.append(
      [
        #("model", json.string(model_name)),
        #("messages", json.preprocessed_array(messages_json)),
      ],
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
    use choices <- decode.field(
      "choices",
      decode.list({
        use message <- decode.optional_field(
          "message",
          None,
          decode.optional({
            use content <- decode.optional_field(
              "content",
              None,
              decode.optional(decode.string),
            )
            decode.success(content)
          }),
        )
        use tool_calls <- decode.optional_field(
          "tool_calls",
          [],
          decode.list({
            use id <- decode.field("id", decode.string)
            use function <- decode.field("function", {
              use name <- decode.field("name", decode.string)
              use arguments <- decode.field("arguments", decode.string)
              decode.success(#(name, arguments))
            })
            let #(name, arguments) = function
            decode.success(#(id, name, arguments))
          }),
        )
        decode.success(#(message, tool_calls))
      }),
    )
    use model <- decode.optional_field(
      "model",
      None,
      decode.optional(decode.string),
    )
    decode.success(#(choices, model))
  }

  case json.parse(from: raw, using: decoder) {
    Ok(result) -> {
      let #(choices, model) = result
      case choices {
        [] -> Error("No choices in response")
        [#(Some(content), _), ..] ->
          case content {
            Some(c) if c != "" -> Ok(c)
            _ -> Error("Empty content")
          }
        [#(None, tool_calls), ..] if tool_calls != [] ->
          case tool_calls {
            [#(_id, _name, args), ..] -> Ok(args)
            _ -> Error("No tool calls")
          }
        [#(None, _), ..] ->
          case model {
            Some(m) -> Ok(m)
            None -> Error("Empty response")
          }
      }
    }
    Error(e) -> Error("Failed to parse response: " <> string_inspect(e))
  }
}

fn string_inspect(_v: a) -> String {
  "error"
}
