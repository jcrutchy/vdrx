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
- Failed WebSocket logins are rate-limited per address (8 per minute, then a one-minute lockout).
- Listeners bind to `127.0.0.1` by default. Set `bind` to the one interface that needs to be
  reachable (avoid `0.0.0.0`) and firewall the port to the hosts that need it.
- Keep `max_connections` at a sensible figure for the expected number of clients (default 256 per listener).
- Run vdrx as an unprivileged account that can only read what it serves.
- Treat `vdrx.conf` as sensitive; keep tokens in environment variables (`{ENV:NAME}`).
- Lower `log_max_payload_bytes` or filter `http.reply.*` topics if request bodies are sensitive.
