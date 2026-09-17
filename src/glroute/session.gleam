import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import glroute/chat.{type Message}

// ---------------------------------------------------------------------------
// In-memory session store for conversation history
// Keyed by client-provided session ID (e.g. "session_abc123")
// ---------------------------------------------------------------------------

pub type Session {
  Session(id: String, messages: List(Message), created_at: Int)
}

pub type SessionStore {
  SessionStore(Dict(String, Session))
}

pub fn new() -> SessionStore {
  SessionStore(dict.from_list([]))
}

pub fn get(store: SessionStore, session_id: String) -> Option(Session) {
  let SessionStore(dict) = store
  case dict.get(dict, session_id) {
    Ok(session) -> Some(session)
    Error(_) -> None
  }
}

pub fn insert(
  store: SessionStore,
  session_id: String,
  messages: List(Message),
) -> SessionStore {
  let now = 1_700_000_000
  let SessionStore(dict) = store
  let session = Session(id: session_id, messages: messages, created_at: now)
  SessionStore(dict.insert(dict, session_id, session))
}

pub fn append(
  store: SessionStore,
  session_id: String,
  msg: Message,
) -> SessionStore {
  let SessionStore(dict) = store
  case dict.get(dict, session_id) {
    Ok(s) ->
      SessionStore(dict.insert(
        dict,
        session_id,
        Session(
          id: session_id,
          messages: list.append(s.messages, [msg]),
          created_at: s.created_at,
        ),
      ))
    Error(_) -> insert(store, session_id, [msg])
  }
}

pub fn clear(store: SessionStore, session_id: String) -> SessionStore {
  let SessionStore(dict) = store
  SessionStore(dict.delete(dict, session_id))
}

// ---------------------------------------------------------------------------
// Session ID from request header or body
// ---------------------------------------------------------------------------

pub fn extract_session_id(
  req_headers: List(#(String, String)),
) -> Option(String) {
  case
    list.find(in: req_headers, one_that: fn(h) {
      h.0 == "x-session-id" || h.0 == "X-Session-Id"
    })
  {
    Ok(#(_, id)) -> Some(id)
    Error(_) -> None
  }
}

pub fn parse_session_from_body(body: String) -> Option(String) {
  let decoder = {
    use sid <- decode.optional_field("session_id", "", decode.string)
    decode.success(case sid {
      "" -> None
      i -> Some(i)
    })
  }
  case json.parse(from: body, using: decoder) {
    Ok(sid) -> sid
    Error(_) -> None
  }
}
