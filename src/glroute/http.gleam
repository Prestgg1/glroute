import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/list
import gleam/result
import gleam/uri
import glroute/errors.{type GlrouteError, HttpError}

pub type HttpClient =
  fn(request.Request(String)) -> Result(response.Response(String), GlrouteError)

pub fn default_client(
  req: request.Request(String),
) -> Result(response.Response(String), GlrouteError) {
  case httpc.send(req) {
    Ok(resp) -> Ok(resp)
    Error(e) -> Error(HttpError("HTTP request failed: " <> string_inspect(e)))
  }
}

pub fn post_json(
  url_string: String,
  headers: List(#(String, String)),
  body: String,
) -> Result(request.Request(String), GlrouteError) {
  use parsed <- result.try(
    uri.parse(url_string)
    |> result.map_error(fn(_) { HttpError("Invalid URL: " <> url_string) }),
  )
  use req <- result.try(
    request.from_uri(parsed)
    |> result.map_error(fn(_) { HttpError("Failed to create request from URI") }),
  )

  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body)

  let req =
    list.fold(headers, req, fn(acc, h) { request.set_header(acc, h.0, h.1) })

  Ok(req)
}

pub fn expect_success(
  resp: response.Response(String),
) -> Result(response.Response(String), GlrouteError) {
  case resp.status >= 200 && resp.status < 300 {
    True -> Ok(resp)
    False ->
      Error(HttpError(
        "HTTP " <> int_to_string(resp.status) <> ": " <> resp.body,
      ))
  }
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

fn string_inspect(_v: a) -> String {
  "error"
}
