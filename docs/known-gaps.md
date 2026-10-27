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
- The logger masks credentials by pattern (`log_redact`, on by default, bodies
  included). That is a safety net: a secret carried in a member the patterns do
  not know, or in a job's own output, is logged as-is. Buckets are never masked.
- A TLS client that stalls mid-handshake blocks the TLS accept loop (the
  handshake runs on the accept thread).
- The reverse proxy adds no `X-Forwarded-*` headers.
- CGI output is buffered whole (no streaming), and has no size cap.

- **WebSocket authentication.** With no `ws_profiles`, every `sys.auth` is
  rejected unless `executives.ws.allow_open_access` is set (dev only: any
  non-empty token is then accepted and may subscribe to everything, including
  `http.reply.*` request/response envelopes; publishing to `sys.>` is still
  denied). With profiles, a profile that has no `token` is open to anyone who
  names it - give every profile that matters a long random token. Tokens are
  held and compared in plain text (compared in constant time) and have no
  expiry. Eight failed `sys.auth` attempts from one address within a minute
  lock that address out for a minute; behind a reverse proxy every client
  shares the proxy's address. There is no per-topic access control beyond
  `ws_profiles`, so more things than before are reachable purely by knowing a
  topic name.
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
- **Jobs (§11):** stopping a job signals the process VDRX started, not its
  children (a shell that forks, say); intervals only, no cron expressions; the
  `jobs` array is read at startup and `reload` doesn't re-read it; job output is
  published line by line with no rate limit.
- Stopping the daemon is slow whenever a listener is enabled: the HTTP and the
  WebSocket listener each wait out a full `shutdown_grace_ms` (their accept
  threads only give up when the grace period runs out). Measured with both
  listeners and nothing else running: stop time = about 2 x `shutdown_grace_ms`
  + 3 s (7 s at 2000, 13 s at 5000, 19 s at 8000), against 0.2 s with neither.
  Keep `shutdown_grace_ms` small (3000 is plenty for jobs) and give a service
  manager's stop timeout room for it.

---
*Section numbers (§N) are shared across all vdrx docs - see the [section map](README.md#section-map).*
