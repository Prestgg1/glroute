import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

pub type ChatRequest {
  ChatRequest(
    model: String,
    messages: List(#(String, String)),
    temperature: Option(Float),
    max_tokens: Option(Int),
  )
}

pub fn build_request_json(req: ChatRequest) -> json.Json {
  let base_messages =
    list.map(req.messages, fn(msg) {
      json.object([
        #("role", json.string(msg.0)),
        #("content", json.string(msg.1)),
      ])
    })

  let base_fields = [
    #("model", json.string(req.model)),
    #("messages", json.preprocessed_array(base_messages)),
  ]

  let with_temp = case req.temperature {
    Some(t) -> list.append(base_fields, [#("temperature", json.float(t))])
    None -> base_fields
  }

  let with_max = case req.max_tokens {
    Some(m) -> list.append(with_temp, [#("max_tokens", json.int(m))])
    None -> with_temp
  }

  json.object(with_max)
}

pub type ChatResponse {
  ChatResponse(
    content: Option(String),
    tool_calls: List(ToolCall),
    usage: Option(UsageRaw),
    raw: String,
  )
}

pub type ToolCall {
  ToolCall(id: String, name: String, arguments: String)
}

pub type UsageRaw {
  UsageRaw(prompt_tokens: Int, completion_tokens: Int, total_tokens: Int)
}

fn tool_call_decoder() -> decode.Decoder(ToolCall) {
  use id <- decode.field("id", decode.string)
  use function <- decode.field("function", {
    use name <- decode.field("name", decode.string)
    use arguments <- decode.field("arguments", decode.string)
    decode.success(#(name, arguments))
  })
  let #(name, arguments) = function
  decode.success(ToolCall(id:, name:, arguments:))
}

fn usage_decoder() -> decode.Decoder(UsageRaw) {
  use prompt_tokens <- decode.field("prompt_tokens", decode.int)
  use completion_tokens <- decode.field("completion_tokens", decode.int)
  use total_tokens <- decode.field("total_tokens", decode.int)
  decode.success(UsageRaw(prompt_tokens:, completion_tokens:, total_tokens:))
}

fn chat_choice_decoder() -> decode.Decoder(#(Option(String), List(ToolCall))) {
  use message <- decode.field("message", {
    use content <- decode.optional_field(
      "content",
      None,
      decode.optional(decode.string),
    )
    use tool_calls <- decode.optional_field(
      "tool_calls",
      [],
      decode.list(tool_call_decoder()),
    )
    decode.success(#(content, tool_calls))
  })
  decode.success(message)
}

pub fn parse_response(raw: String) -> Result(ChatResponse, String) {
  let decoder = {
    use choices <- decode.field("choices", decode.list(chat_choice_decoder()))
    use usage <- decode.optional_field(
      "usage",
      None,
      decode.optional(usage_decoder()),
    )
    decode.success(#(choices, usage))
  }

  case json.parse(from: raw, using: decoder) {
    Ok(#(choices, usage)) -> {
      case choices {
        [] -> Error("No choices in response")
        [#(content, tool_calls), ..] ->
          Ok(ChatResponse(content:, tool_calls:, usage:, raw:))
      }
    }
    Error(e) -> Error("Failed to parse OpenAI response: " <> string_inspect(e))
  }
}

pub fn extract_output(resp: ChatResponse) -> Result(String, String) {
  case resp.content {
    Some(c) -> Ok(c)
    None -> {
      case resp.tool_calls {
        [tc, ..] -> Ok(tc.arguments)
        [] -> Error("No content or tool calls in response")
      }
    }
  }
}

fn string_inspect(_v: a) -> String {
  "decode_error"
}
