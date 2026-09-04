import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import glon
import glroute/errors.{type GlrouteError, ProviderError}
import glroute/http
import glroute/internal/gemini_api
import glroute/internal/openai_api
import glroute/provider.{type Model}
import glroute/usage.{type RunResult, RunResult, Usage}

pub opaque type Agent(deps, output) {
  Agent(config: Config(deps, output))
}

pub type Config(deps, output) {
  Config(
    model: Model,
    instructions: Option(String),
    temperature: Option(Float),
    max_tokens: Option(Int),
    retries: Int,
    http_client: Option(http.HttpClient),
    decoder: fn(String) -> Result(output, GlrouteError),
  )
}

pub fn new(model: Model) -> Agent(deps, String) {
  Agent(
    Config(
      model: model,
      instructions: None,
      temperature: None,
      max_tokens: None,
      retries: 2,
      http_client: None,
      decoder: fn(s: String) { Ok(s) },
    ),
  )
}

pub fn with_instructions(
  agent: Agent(deps, output),
  instructions: String,
) -> Agent(deps, output) {
  Agent(Config(..agent.config, instructions: Some(instructions)))
}

pub fn with_glon(
  agent: Agent(deps, a),
  schema: glon.JsonSchema(output),
) -> Agent(deps, output) {
  let new_config =
    Config(
      model: agent.config.model,
      instructions: agent.config.instructions,
      temperature: agent.config.temperature,
      max_tokens: agent.config.max_tokens,
      retries: agent.config.retries,
      http_client: agent.config.http_client,
      decoder: fn(raw: String) {
        case glon.decode(schema, raw) {
          Ok(v) -> Ok(v)
          Error(e) ->
            Error(errors.DecodeError(
              "Failed to decode schema output: " <> string_inspect(e),
            ))
        }
      },
    )
  Agent(new_config)
}

pub fn with_temperature(
  agent: Agent(deps, output),
  temp: Float,
) -> Agent(deps, output) {
  Agent(Config(..agent.config, temperature: Some(temp)))
}

pub fn with_max_tokens(
  agent: Agent(deps, output),
  max: Int,
) -> Agent(deps, output) {
  Agent(Config(..agent.config, max_tokens: Some(max)))
}

pub fn with_retries(
  agent: Agent(deps, output),
  retries: Int,
) -> Agent(deps, output) {
  Agent(Config(..agent.config, retries: retries))
}

pub fn with_http_client(
  agent: Agent(deps, output),
  client: http.HttpClient,
) -> Agent(deps, output) {
  Agent(Config(..agent.config, http_client: Some(client)))
}

pub fn get_model(agent: Agent(deps, output)) -> Model {
  agent.config.model
}

pub fn run(
  agent: Agent(deps, output),
  prompt: String,
  deps: deps,
) -> Result(RunResult(output), GlrouteError) {
  let _ = deps
  let messages = case agent.config.instructions {
    Some(sys) -> [#("system", sys), #("user", prompt)]
    None -> [#("user", prompt)]
  }

  case agent.config.model.provider {
    provider.Gemini(..) -> run_gemini(agent, messages)
    _ -> run_openai(agent, messages)
  }
}

fn run_openai(
  agent: Agent(deps, output),
  messages: List(#(String, String)),
) -> Result(RunResult(output), GlrouteError) {
  let model_name = agent.config.model.model_name
  let prov = agent.config.model.provider

  let chat_req =
    openai_api.ChatRequest(
      model: model_name,
      messages: messages,
      temperature: agent.config.temperature,
      max_tokens: agent.config.max_tokens,
    )

  let body = openai_api.build_request_json(chat_req) |> json.to_string
  let url = provider.chat_completions_url(prov)
  let headers = [provider.auth_header(prov)]

  do_request_with_retries(agent, url, headers, body, fn(raw) {
    case openai_api.parse_response(raw) {
      Error(e) -> Error(ProviderError(e))
      Ok(resp) -> {
        case openai_api.extract_output(resp) {
          Error(e) -> Error(ProviderError(e))
          Ok(output_str) -> {
            let u = case resp.usage {
              Some(raw_u) ->
                Usage(
                  input_tokens: raw_u.prompt_tokens,
                  output_tokens: raw_u.completion_tokens,
                  total_tokens: raw_u.total_tokens,
                  requests: 1,
                )
              None -> usage.zero()
            }
            case agent.config.decoder(output_str) {
              Ok(typed) ->
                Ok(RunResult(output: typed, usage: u, raw_response: raw))
              Error(e) -> Error(e)
            }
          }
        }
      }
    }
  })
}

fn run_gemini(
  agent: Agent(deps, output),
  messages: List(#(String, String)),
) -> Result(RunResult(output), GlrouteError) {
  let prov = agent.config.model.provider
  let model_name = agent.config.model.model_name

  let gem_req =
    gemini_api.GeminiRequest(
      model: model_name,
      messages: messages,
      temperature: agent.config.temperature,
      max_tokens: agent.config.max_tokens,
    )

  let body = gemini_api.build_request_json(gem_req) |> json.to_string
  let base_url = provider.gemini_generate_url(prov, model_name)
  let url = case prov {
    provider.Gemini(key) -> base_url <> "?key=" <> key
    _ -> base_url
  }
  let headers = case prov {
    provider.Gemini(..) -> []
    _ -> [provider.auth_header(prov)]
  }

  do_request_with_retries(agent, url, headers, body, fn(raw) {
    case gemini_api.parse_response(raw) {
      Error(e) -> Error(ProviderError(e))
      Ok(resp) -> {
        case gemini_api.extract_output(resp) {
          Error(e) -> Error(ProviderError(e))
          Ok(output_str) -> {
            let u = case resp.usage {
              Some(g) ->
                Usage(
                  input_tokens: g.prompt_tokens,
                  output_tokens: g.candidates_tokens,
                  total_tokens: g.total_tokens,
                  requests: 1,
                )
              None -> usage.zero()
            }
            case agent.config.decoder(output_str) {
              Ok(typed) ->
                Ok(RunResult(output: typed, usage: u, raw_response: raw))
              Error(e) -> Error(e)
            }
          }
        }
      }
    }
  })
}

fn do_request_with_retries(
  agent: Agent(deps, output),
  url: String,
  headers: List(#(String, String)),
  body: String,
  handler: fn(String) -> Result(RunResult(output), GlrouteError),
) -> Result(RunResult(output), GlrouteError) {
  do_retry(agent, url, headers, body, handler, 0)
}

fn do_retry(
  agent: Agent(deps, output),
  url: String,
  headers: List(#(String, String)),
  body: String,
  handler: fn(String) -> Result(RunResult(output), GlrouteError),
  attempt: Int,
) -> Result(RunResult(output), GlrouteError) {
  let client = case agent.config.http_client {
    Some(c) -> c
    None -> http.default_client
  }

  let result = {
    use req <- result.try(http.post_json(url, headers, body))
    use resp <- result.try(client(req))
    use resp <- result.try(http.expect_success(resp))
    Ok(resp.body)
  }

  case result {
    Error(e) -> {
      case attempt < agent.config.retries {
        True -> do_retry(agent, url, headers, body, handler, attempt + 1)
        False -> Error(e)
      }
    }
    Ok(raw) -> {
      case handler(raw) {
        Ok(v) -> Ok(v)
        Error(e) ->
          case attempt < agent.config.retries {
            True -> do_retry(agent, url, headers, body, handler, attempt + 1)
            False -> Error(e)
          }
      }
    }
  }
}

fn string_inspect(_v: a) -> String {
  "inspect_error"
}
