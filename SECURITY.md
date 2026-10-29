# Security

## Intended deployment

VDRX is designed for **trusted internal networks**. It is not hardened for direct
internet exposure. Put a hardened reverse proxy in front of it if you ever need that.

## Reporting a vulnerability

Please open a private security advisory on the GitHub repository
(Security tab -> "Report a vulnerability") rather than a public issue.
Include the version/commit, your configuration (with secrets removed) and steps to reproduce.

## Known limitations

See [docs/known-gaps.md](docs/known-gaps.md). Security-relevant items there include
WebSocket authentication defaults, plain-text token comparison, logging of request
bodies, and the absence of per-topic access control beyond `ws_profiles`.

## Operating guidance

- Define `ws_profiles` with long random tokens, and give every profile a token. With no profiles the
  WebSocket rejects all logins (`allow_open_access` exists for throwaway dev setups only).
- Slow clients are cut off (`http_read_timeout_ms`, `http_request_timeout_ms`, WebSocket `frame_timeout_ms`) and
  WebSocket frames are capped (`max_frame_bytes`, 1 MiB). Keep `max_connections` at what you actually expect.
- WebSocket handshakes from a browser must come from the same host as the request (or an entry in
  `executives.ws.allowed_origins`); `max_connections` caps live WebSocket connections. Pages and WebSocket can
  share one port with an HTTP site's `websocket_path`.
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
