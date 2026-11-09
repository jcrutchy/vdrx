# Security

## Intended deployment

VDRX is designed for **trusted internal networks**. It is not hardened for direct
internet exposure. Put a hardened reverse proxy in front of it if you ever need that.

## Reporting a vulnerability

Please open a private security advisory on the GitHub repository
(Security tab -> "Report a vulnerability") rather than a public issue.
Include the version/commit, your configuration (with secrets removed) and steps to reproduce.

## Known limitations

The assets, actors, controls and review status are laid out in [docs/threat-model.md](docs/threat-model.md); the list of
known weaknesses is [docs/known-gaps.md](docs/known-gaps.md). Security-relevant items there include
WebSocket authentication defaults, plain-text token comparison, logging of request
bodies, and the absence of per-topic access control beyond `ws_profiles`.

## Operating guidance

- Define `ws_profiles` with long random tokens, and give every profile a token. With no profiles the
  WebSocket rejects all logins (`allow_open_access` exists for throwaway dev setups only).
- Template names are plain file names and `reply_to` values in `sys.>` / `kernel.>` are refused, so a client that may publish
  to a template or runner topic cannot read files outside the template directory or reach `sys.quit` / `sys.kill*` through them,
  and a profile's `reply_to` is limited to topics its own `publish_allow` matches.
- URL paths are split segment by segment and refused if they contain `..`, NUL, `\`, `:`, dot-files, their Windows 8.3 aliases
  (`GIT~1`), device names (`con`, `nul`, `com1`...) or a trailing dot/space; every CGI environment value has CR, LF and NUL
  stripped, and a `Proxy` header never becomes `HTTP_PROXY`.
  A WebSocket client that re-sends `sys.auth` loses its previous session and subscriptions before the new token is judged.
- Clients that stop *reading* are cut off too (`http_write_timeout_ms`, WebSocket `write_timeout_ms`), and
  large static files are streamed rather than loaded into memory.
- Slow clients are cut off (`http_read_timeout_ms`, `http_request_timeout_ms`, WebSocket `frame_timeout_ms`) and
  WebSocket frames are capped (`max_frame_bytes`, 1 MiB). Keep `max_connections` at what you actually expect.
- WebSocket handshakes from a browser must come from the same host as the request (or an entry in
  `executives.ws.allowed_origins`); `max_connections` caps live WebSocket connections. Pages and WebSocket can
  share one port with an HTTP site's `websocket_path`.
- Outbound TLS (`socket_clients`) checks that the server's certificate is valid for the host it dialled, not just that it chains
  to a trusted CA; keep `tls_verify` on. Everything written to the log has line breaks and control characters escaped, so a
  client cannot forge log entries or drive the operator's terminal.
- Failed WebSocket logins are rate-limited per address (8 per minute, then a one-minute lockout).
- Listeners bind to `127.0.0.1` by default. Set `bind` to the one interface that needs to be
  reachable (avoid `0.0.0.0`) and firewall the port to the hosts that need it.
- Keep `max_connections` at a sensible figure for the expected number of clients (default 256 per listener).
- Run vdrx as an unprivileged account that can only read what it serves.
- Treat `vdrx.conf` as sensitive; keep tokens in environment variables (`{ENV:NAME}`). CGI and `cli_bridges`
  programs get a clean environment, so those variables do not reach them unless you list them in
  `child_env_passthrough`.
- Run vdrx as an unprivileged account (it warns at startup if it is root). The static server refuses
  configuration, log, key, backup and script-source files by extension and does not follow symbolic
  links by default (`static_deny_extensions`, `static_allow_extensions`, `static_follow_symlinks`).
- Keep `log_redact` and `log_redact_bodies` on (the defaults). They mask cookies, Authorization headers, tokens,
  passwords and request bodies in the log and console; buckets are not masked, so don't record credential-bearing topics.
- Treat `vdrx_daemon.log` as sensitive anyway (restrictive file permissions, rotation, no world-readable share).
