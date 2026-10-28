# Web server + WebSocket server

Static pages (or PHP/Python, see the other guides) and a WebSocket server in one daemon. Example:
[`examples/web-and-websocket`](../../examples/web-and-websocket) - a chat room whose page is a static file and
whose **entire backend is the vdrx bus**.

```json
{
  "http_sites": [ { "id": "web", "port": 8080, "static_dir": "public", "websocket_path": "/ws" } ],
  "executives": { "ws": { "enabled": true, "port": 8082 } },
  "ws_profiles": [
    { "id": "browser", "subscribe_allow": ["chat.>"], "publish_allow": ["chat.>"] }
  ]
}
```

Run vdrx from the example folder and open <http://localhost:8080/> in two tabs.

> **One port or two.** The page connects to `/ws` on the port it was served from (8080): the
> `websocket_path` on the site hands that upgrade to the WebSocket server. The WebSocket server also
> keeps its own port (8082) here, so either works; set `"port": 0` to serve it on the shared port only.
> See [../websocket.md](../websocket.md).

## How the chat works

There is no chat code on the server. The browser does this (see `public/index.html`):

```js
const ws = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/ws');
ws.onopen = () => ws.send(JSON.stringify({method: 'sys.auth', profile: 'browser'}));   // pick a profile
// after {"event":"auth.ok"}:
ws.send(JSON.stringify({method: 'subscribe', filter: 'chat.room'}));
ws.send(JSON.stringify({method: 'publish', topic: 'chat.room', payload: {user: 'me', text: 'hi'}}));
// incoming messages: {"topic":"chat.room","payload":{...},"source":"ws.conn.3","seq":42}
```

Each WebSocket connection is a bus participant: whatever one tab publishes to `chat.room`, every tab
subscribed to `chat.room` receives. Anything else on the bus - a script, a runner, another site - can also
publish or subscribe to those topics, so server-side logic is just another subscriber (a moderation script
under `processes` that subscribes to `chat.room` and republishes to `chat.clean`, for instance).

## Profiles: what a browser may do

`ws_profiles` decide what a connected client is allowed to subscribe to and publish to. Deny-by-default:

- `subscribe_allow` - filters it may subscribe to (`chat.>` allows `chat.room` and `chat.*`, not `>`).
- `publish_allow` - topics it may publish to. `sys.*` (the admin surface) is unreachable unless listed.
- `token` - if set, `sys.auth` must present it: `{"method":"sys.auth","token":"..."}`.
  A profile with no token (as here) is available to anyone who names it - add tokens before exposing this.
- `max_queue` - frames kept for a slow client before the oldest are dropped (default 5000).

A refused call is answered with `{"event":"denied","method":...,"topic":...}`. Without any `ws_profiles` the old
behaviour applies (any non-empty token may do anything) and startup logs a warning. Details:
[../websocket.md](../websocket.md).

## HTTPS / WSS

Give the site `tls_port`/`tls_cert`/`tls_key`, and the same three keys under `executives.ws`. A page served over
https must connect with `wss://` to the TLS port.
