import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/map.{type Map}
import gleam/string
import glroute/chat.{type Message}
import glroute/errors.{type GlrouteError, ProviderError}

// ---------------------------------------------------------------------------
// In-memory session store for conversation history
// Keyed by client-provided session ID (e.g. "session_abc123")
// ---------------------------------------------------------------------------

type Session {
  Session(
    id: String,
    messages: List(Message),
    created_at: Int,
  )
}

pub type SessionStore {
  SessionStore(Map(String, Session))
}

pub fn new() -> SessionStore {
  SessionStore(map.from_list([]))
}

pub fn get(store: SessionStore, session_id: String) -> Option(Session) {
  map.get(store.0, session_id)
}

pub fn insert(store: SessionStore, session_id: String, messages: List(Message)) -> SessionStore {
  let now = 1700000000 // simplified timestamp
  let session = Session(id: session_id, messages: messages, created_at: now)
  SessionStore(map.insert(store.0, session_id, session))
}

pub fn append(store: SessionStore, session_id: String, msg: Message) -> SessionStore {
  case map.get(store.0, session_id) {
    Some(s) -> insert(store, session_id, s.messages <> [msg])
    None -> insert(store, session_id, [msg])
  }
}

pub fn clear(store: SessionStore, session_id: String) -> SessionStore {
  SessionStore(map.delete(store.0, session_id))
}

// ---------------------------------------------------------------------------
// Session ID from request header or body
// ---------------------------------------------------------------------------

pub fn extract_session_id(req_headers: List(#(String, String))) -> Option(String) {
  case list.find(fn(h) { h.0 == "x-session-id" || h.0 == "X-Session-Id" }, req_headers) {
    Some(#(_, id)) -> Some(id)
    None -> None
  }
}

pub fn parse_session_from_body(body: String) -> Option(String) {
  let decoder = {
    use sid <- decode.optional_field("session_id", None, decode.string)
    decode.success(sid)
  }
  case json.parse(from: body, using: decoder) {
    Ok(sid) -> sid
    Error(_) -> None
  }
}
