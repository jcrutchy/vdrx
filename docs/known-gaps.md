# 9. Known gaps

- **No WebSocket upgrade on the HTTP port.** The WebSocket server only listens
  on its own port (`executives.ws.port`); an HTTP site that receives
  `Upgrade: websocket` answers it as an ordinary request. The hook for handing a
  connection over exists (`TVDRX_WebSocketExecutive.AdoptConnection` takes the
  already-read request), but the HTTP side doesn't call it yet. Use two ports
  for now ([guides/web-and-websocket.md](guides/web-and-websocket.md)).
- **One config path.** vdrx always reads `vdrx.conf` from the current
  directory; there is no `--config` option.
- HTTP is one request per connection (`Connection: close`): no keep-alive, no
  chunked *request* bodies, no `Expect: 100-continue`, no Range/ETag/caching
  headers on static files, no compression. Fine behind a real proxy or for
  tools; not yet a front-line web server.
- The route/rewrite tables, `cgi` entries and runners are read at startup;
  `reload` only re-applies `http_sites` settings.
- The logger records every bus message at INFO - which now includes whole HTTP
  request envelopes (POST bodies, cookies). Don't point it at anything
  sensitive without lowering `log_max_payload_bytes` or filtering `http.reply.*`
  and `<id>.in` topics.
- A TLS client that stalls mid-handshake blocks the TLS accept loop (the
  handshake runs on the accept thread).
- The reverse proxy adds no `X-Forwarded-*` headers.
- CGI output is buffered whole (no streaming), and has no size cap.

- The `sys.*` admin surface is only protected on WebSocket when `ws_profiles`
  are defined (§5a); without them `sys.auth` accepts any non-empty token and
  that client can publish `sys.quit`. Tokens are compared in plain text and
  there is no per-token expiry - fine for a single-operator
  dev box, not yet for anything multi-tenant. This matters more now that
  §2-§4d mean more things than before are reachable purely by knowing a
  topic name - there's no per-topic access control yet, only "can you
  reach the bus at all."
- Per-connection HTTP/WS threads are fire-and-forget, not individually
  tracked/joined on shutdown.
- §4 (static files, reverse-proxy routes) still dispatches in-process on
  the connection thread rather than through the bus - only `cli_bridges`
  and template rendering go through `PublishAndWait`/`TVDRX_OneShotWaiter`
  so far. Extending the same correlation-ID pattern to static/proxy
  serving (topic-encoded routing, per the original design discussion)
  would finish the "everything only talks via the bus" picture, but adds a
  bus round trip to every request including the highest-volume ones
  (images, CSS, JS), so it's a deliberate scope boundary, not an oversight.
- `TVDRX_Message` has no native `ReplyTo`/`CorrelationID` fields yet -
  request/reply (§4b/§4d) works today only via `TVDRX_OneShotWaiter`
  minting a throwaway reply topic per call. Promoting that to fields on
  the message itself would let a supervised `processes` script implement
  request/reply against an arbitrary caller without either side needing to
  invent topic-naming conventions - queued as the next bus-level change,
  not yet started.
- No inbound raw-TCP/TLS listener (`socket_clients` is outbound-only) -
  a `socket_servers` config section mirroring `socket_clients` but
  accepting connections would slot into the existing
  `TVDRX_SocketListenerExecutive` base class (already generic over
  plain/TLS accept loops; `TVDRX_HTTPExecutive`/
  `TVDRX_WebSocketExecutive` are all descendants of it) the same way
  `TVDRX_SocketClientExecutive` reuses the transport/framing code - not yet
  built.

---
*Section numbers (§N) are shared across all vdrx docs - see the [section map](README.md#section-map).*
