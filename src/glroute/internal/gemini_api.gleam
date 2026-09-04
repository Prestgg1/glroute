import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

pub type GeminiRequest {
  GeminiRequest(
    model: String,
    messages: List(#(String, String)),
    temperature: Option(Float),
    max_tokens: Option(Int),
  )
}

pub fn build_request_json(req: GeminiRequest) -> json.Json {
  let contents =
    list.map(req.messages, fn(msg) {
      let role = case msg.0 {
        "user" -> "user"
        "assistant" -> "model"
        _ -> "user"
      }
      json.object([
        #("role", json.string(role)),
        #(
          "parts",
          json.preprocessed_array([
            json.object([#("text", json.string(msg.1))]),
          ]),
        ),
      ])
    })

  let base_fields = [#("contents", json.preprocessed_array(contents))]

  let config_fields = []
  let config_fields = case req.temperature {
    Some(t) -> list.append(config_fields, [#("temperature", json.float(t))])
    None -> config_fields
  }
  let config_fields = case req.max_tokens {
    Some(m) -> list.append(config_fields, [#("maxOutputTokens", json.int(m))])
    None -> config_fields
  }

  case config_fields {
    [] -> json.object(base_fields)
    _ ->
      json.object(
        list.append(base_fields, [
          #("generationConfig", json.object(config_fields)),
        ]),
      )
  }
}

pub type GeminiResponse {
  GeminiResponse(
    content: Option(String),
    usage: Option(GeminiUsage),
    raw: String,
  )
}

pub type GeminiUsage {
  GeminiUsage(prompt_tokens: Int, candidates_tokens: Int, total_tokens: Int)
}

fn usage_decoder() -> decode.Decoder(GeminiUsage) {
  use prompt_tokens <- decode.optional_field("promptTokenCount", 0, decode.int)
  use candidates_tokens <- decode.optional_field(
    "candidatesTokenCount",
    0,
    decode.int,
  )
  use total_tokens <- decode.optional_field("totalTokenCount", 0, decode.int)
  decode.success(GeminiUsage(prompt_tokens:, candidates_tokens:, total_tokens:))
}

fn candidate_decoder() -> decode.Decoder(String) {
  use content <- decode.field("content", {
    use parts <- decode.field(
      "parts",
      decode.list({
        use text <- decode.field("text", decode.string)
        decode.success(text)
      }),
    )
    decode.success(parts)
  })
  case content {
    [text, ..] -> decode.success(text)
    [] -> decode.failure("", "non-empty parts list")
  }
}

pub fn parse_response(raw: String) -> Result(GeminiResponse, String) {
  let decoder = {
    use candidates <- decode.optional_field(
      "candidates",
      [],
      decode.list(candidate_decoder()),
    )
    use usage <- decode.optional_field(
      "usageMetadata",
      None,
      decode.optional(usage_decoder()),
    )
    decode.success(#(candidates, usage))
  }

  case json.parse(from: raw, using: decoder) {
    Ok(#(candidates, usage)) -> {
      let content = case candidates {
        [text, ..] -> Some(text)
        [] -> None
      }
      Ok(GeminiResponse(content:, usage:, raw:))
    }
    Error(e) -> Error("Failed to parse Gemini response: " <> string_inspect(e))
  }
}

pub fn extract_output(resp: GeminiResponse) -> Result(String, String) {
  case resp.content {
    Some(c) -> Ok(c)
    None -> Error("No content in Gemini response")
  }
}

fn string_inspect(_v: a) -> String {
  "decode_error"
}
