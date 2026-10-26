# WebSocket server on its own port

Only a WebSocket server - no HTTP site at all. Example: [`examples/websocket-only`](../../examples/websocket-only):
a supervised script publishes a tick every second and any allowed client can listen.

```json
{
  "executives": { "ws": { "enabled": true, "port": 8082 } },
  "ws_profiles": [
    { "id": "viewer", "subscribe_allow": ["clock.>"], "publish_allow": [], "default_subscribe": "clock.>" }
  ],
  "processes": [
    { "id": "ticker", "command": "{PYTHON_BIN} ticker.py", "restart": "always", "publish_allow": ["clock.tick"] }
  ]
}
```

Run vdrx from the example folder, then open `client.html` straight from disk in a browser (a file page may open a
WebSocket, no web server needed) or run `python3 watch.py` for a command-line client (standard library only).

## The protocol

JSON text frames. A client sends:

| Message | Meaning |
|---|---|
| `{"method":"sys.auth","profile":"viewer"}` | choose a profile (add `"token":"..."` when the profile has one, or send just a token to be matched to its profile) |
| `{"method":"subscribe","filter":"clock.>"}` | start receiving matching topics (`*` = one segment, `>` = the rest) |
| `{"method":"unsubscribe","filter":"clock.>"}` / `{"method":"unsubscribe_all"}` | stop |
| `{"method":"publish","topic":"x.y","payload":...}` | publish (a string payload is sent as text, anything else as JSON) |

and receives `{"event":"auth.ok","profile":"viewer"}` (or `auth.fail`), `{"event":"denied",...}` for a refused
call, `{"event":"dropped","count":N}` if it fell behind, and for every matching bus message
`{"topic":"clock.tick","payload":{...},"source":"ticker","seq":17}`. Payloads are always valid JSON: a bus payload
that isn't JSON arrives as a JSON string. The server pings every `ping_interval_ms` and closes connections that
don't answer within `pong_timeout_ms`.

A client must `sys.auth` first; everything before that is ignored. With `default_subscribe` set on the profile, its
filters are subscribed automatically right after authentication.

## The producer side

`ticker.py` is an ordinary program - it knows nothing about WebSockets. vdrx supervises it (restarting it if it
dies, per `restart`) and turns each stdout line into a bus message: a line that is JSON with a `topic` and
`payload` is published to that topic provided it matches the process's `publish_allow`; a plain text line goes to
`<id>.out`. Whatever a process reads on stdin are bus messages for its `subscribe` filters (default `<id>.in`),
one JSON object per line. More in [../processes-and-sockets.md](../processes-and-sockets.md).

Browsers can also publish (give the profile a `publish_allow`), which makes this a general push/pull channel
between pages, scripts and anything else on the bus.

## Notes

- `tls_port`/`tls_cert`/`tls_key` under `executives.ws` add `wss://`.
- Pages hosted elsewhere need no CORS settings - WebSocket connections aren't subject to it - but the
  profile is your only access control, so add a `token` before exposing the port.
- To watch all of this live, open `tools/conf_viewer.html` ([../config-viewer.md](../config-viewer.md)).
