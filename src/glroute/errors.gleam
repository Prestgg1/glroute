pub type GlrouteError {
  ProviderError(String)
  DecodeError(String)
  HttpError(String)
}

pub fn to_string(err: GlrouteError) -> String {
  case err {
    ProviderError(msg) -> "ProviderError(" <> msg <> ")"
    DecodeError(msg) -> "DecodeError(" <> msg <> ")"
    HttpError(msg) -> "HttpError(" <> msg <> ")"
  }
}
