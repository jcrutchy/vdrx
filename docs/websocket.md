# 5. WebSocket - `executives.ws`

A single JSON-RPC bridge from the browser straight onto the bus - no
protocol-specific server code needed on VDRX's side for whatever you build
on top:

```json
{ "enabled": true, "port": 8082, "ping_interval_ms": 15000, "pong_timeout_ms": 10000 }
```

`bind` works exactly as for `http_sites` (§4): loopback only by default.

**`max_connections`** (default `256`) is the number of *live* WebSocket connections, counted across the
WebSocket port and any HTTP site's shared port (below). A new connection over the limit is answered
`503` and closed. Size it for the number of browser tabs you expect.

## One port for pages and WebSocket

Set `websocket_path` on an HTTP site and an `Upgrade: websocket` request for exactly that path is handed
to the WebSocket server - same profiles, same login lockout, same frame limits, same Origin check, and
over TLS (`wss://`) when the site has a `tls_port`:

```json
{
  "http_sites": [ { "id": "web", "port": 8080, "static_dir": "public", "websocket_path": "/ws" } ],
  "executives": { "ws": { "enabled": true, "port": 0 } }
}
```

A page then opens `new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/ws')`.
`"port": 0` means the WebSocket server has no listener of its own and is reachable only through sites
that set `websocket_path`; leave a real port there to keep both. Only the exact path matches (a query
string is ignored); anything else on that site is ordinary HTTP. An upgrade request that is malformed
(no `Sec-WebSocket-Key`, a version other than 13, no `Connection: Upgrade`) gets `426`.

**Origin check.** A browser handshake whose `Origin` is not the same host as the request's `Host` header
(any port) and is not listed in `executives.ws.allowed_origins` is refused with `403`, because any web
page a user visits can ask their browser to connect to an address on your network. List full origins,
e.g. `"allowed_origins": ["https://dash.corp.example"]`. Clients that send no `Origin` (scripts, other
servers) are not affected. A page opened from disk (`file://`) sends `Origin: null`; allow it with
`"allowed_origins": ["null"]` only together with a profile that has a token (a sandboxed iframe on any
website sends `null` too). It does not stop DNS rebinding - see [known-gaps.md](known-gaps.md).

**Frame limits.** A client frame larger than `max_frame_bytes` (default `1048576`, 1 MiB) closes the
connection; so does an unmasked frame (RFC 6455 requires clients to mask), a control frame over 125
bytes, or a frame that stalls part-way: once a frame has started, each further read may take at most
`frame_timeout_ms` (default `15000`). An idle connection between frames is fine - the ping/pong
heartbeat watches whether it is still alive. Both options go under `executives.ws`.

**Authentication is required, and closed by default.** A client must `sys.auth` before anything
else. Without `ws_profiles` **every `sys.auth` is rejected** - define profiles (below). For a
throwaway local setup only, `"allow_open_access": true` on `executives.ws` restores the old
behaviour (any non-empty token passes; `sys.*` still can't be published).

Eight failed `sys.auth` attempts from one client address within 60 seconds lock that address out
of `sys.auth` for 60 seconds - even the correct token is refused until it expires. Failures and
lockouts are logged as `log.warn`.

From JS: connect, then send `{"method":"sys.auth","token":"..."}` (with a token from a `ws_profiles` entry - see §9), then
`{"method":"subscribe","filter":"irc_bot.out"}` /
`{"method":"publish","topic":"irc_bot.in","payload":"..."}` /
`{"method":"unsubscribe","filter":"..."}` / `{"method":"unsubscribe_all"}`.
Each connection is a first-class bus participant, so a browser tab talks to
everything else the same way a Bridge-managed process or a bus-CLI script
does. This is usually the right tool for anything that needs to *push*
updates to a browser continuously (chat, live state, notifications) -
prefer it over polling a bus-CLI route.

## 5a. What a client may do - `ws_profiles`

Still one listener, but you can define *profiles* that decide what a
client is allowed to subscribe to and publish:

```json
"ws_profiles": [
  { "id": "viewer", "token": "vt", "subscribe_allow": ["demo.>", "http.reply.*"],
    "publish_allow": [], "default_subscribe": "demo.>", "max_queue": 2000 },
  { "id": "feeder", "token": "ft", "publish_allow": ["demo.>"] }
]
```

`sys.auth` picks the profile: `{"method":"sys.auth","token":"vt"}` selects
the profile whose token matches, `{"method":"sys.auth","profile":"viewer","token":"vt"}`
names it (a profile with no `token` is open to anyone who names it - real
per-profile auth is a later step). A bad token gets `{"event":"auth.fail"}`;
`auth.ok` now carries the `profile`. After that:

- **subscribe** must be *covered* by `subscribe_allow`: `demo.>` allows
  `demo.x` and `demo.*` but not `>`; `demo.*` does not allow `demo.>`.
- **publish** must match `publish_allow` (deny-by-default, same semantics as a
  process's `publish_allow`). `sys.*` - the admin surface - is therefore
  unreachable unless a profile lists it.
- A refused call is answered with `{"event":"denied","method":...,"topic":...}`.
- `default_subscribe` is applied right after a successful `sys.auth`
  (filters outside `subscribe_allow` are skipped with a warning).
- `max_queue` (default 5000, also the default without profiles) bounds the
  frames held for a slow client; beyond it the *oldest* are dropped and the
  client later receives `{"event":"dropped","count":N}`.

With **no** `ws_profiles` the old rules stand (any non-empty token, then
anything - startup logs a warning), and `executives.ws.default_subscribe`
keeps working; once profiles exist it is ignored.

Frames sent to a client are always valid JSON: a payload that already is
JSON is embedded as-is, anything else (e.g. a plain-text log line) is sent as
a JSON string. `tests/integration/ws/` has a black-box test (`ws_test.py`).

**Internally**, a connection is actually two cooperating executives, not
one - purely an implementation detail (the JSON-RPC surface above is
unchanged either way), but worth knowing if you're reading logs or
`vdrx_network.pas` itself:

- `TVDRX_WSConnection` - pure connectivity. Owns the socket, does the
  handshake, frames messages, keeps the ping/pong heartbeat alive, and
  relays bus traffic to/from the browser. It never parses a client's text
  frame - it just republishes the raw JSON onto that connection's own
  `<id>.rpc.in` topic.
- `TVDRX_WSProtocolExecutive` - everything else: `sys.auth`,
  `subscribe`/`unsubscribe`/`unsubscribe_all`/`publish`, all the actual
  interpretation of what a client said. It's a separate Registry entry
  (`<id>.rpc`), subscribed only to `<id>.rpc.in`, and replies by publishing
  to `<id>.rpc.out` - which the connectivity object relays to the socket
  verbatim, rather than wrapping in the usual bus-message envelope, since
  it's already a complete reply line (an `auth.ok` event, say).

Same split as everywhere else in VDRX (Bridge/socket_client): the thing
touching the wire never interprets what's on it, and the thing interpreting
it never touches the wire.

---
*Section numbers (§N) are shared across all vdrx docs - see the [section map](README.md#section-map).*
