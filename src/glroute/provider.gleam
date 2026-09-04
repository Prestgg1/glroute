pub type Provider {
  OpenAI(api_key: String)
  Gemini(api_key: String)
  OpenAICompatible(base_url: String, api_key: String)
}

pub type Model {
  Model(provider: Provider, model_name: String)
}

pub fn openai(model: String, api_key: String) -> Model {
  Model(provider: OpenAI(api_key), model_name: model)
}

pub fn gemini(model: String, api_key: String) -> Model {
  Model(provider: Gemini(api_key), model_name: model)
}

pub fn openai_compatible(
  model: String,
  base_url: String,
  api_key: String,
) -> Model {
  Model(provider: OpenAICompatible(base_url:, api_key:), model_name: model)
}

pub fn base_url(provider: Provider) -> String {
  case provider {
    OpenAI(..) -> "https://api.openai.com/v1"
    Gemini(..) -> "https://generativelanguage.googleapis.com/v1beta"
    OpenAICompatible(base_url: url, ..) -> url
  }
}

pub fn chat_completions_url(provider: Provider) -> String {
  base_url(provider) <> "/chat/completions"
}

pub fn gemini_generate_url(provider: Provider, model: String) -> String {
  base_url(provider) <> "/models/" <> model <> ":generateContent"
}

pub fn auth_header(provider: Provider) -> #(String, String) {
  case provider {
    OpenAI(key) -> #("authorization", "Bearer " <> key)
    Gemini(key) -> #("x-goog-api-key", key)
    OpenAICompatible(api_key: key, ..) -> #("authorization", "Bearer " <> key)
  }
}
