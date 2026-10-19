# 5. WebSocket - `executives.ws`

A single JSON-RPC bridge from the browser straight onto the bus - no
protocol-specific server code needed on VDRX's side for whatever you build
on top:

```json
{ "enabled": true, "port": 8082, "ping_interval_ms": 15000, "pong_timeout_ms": 10000 }
```

From JS: connect, then send `{"method":"sys.auth","token":"..."}` (any
non-empty token passes today - see §9), then
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
