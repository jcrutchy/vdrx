# 2. Supervised processes - `processes`

Every entry in `processes` gets a `TVDRX_BridgeExecutive`: VDRX spawns the
command, restarts it if it dies (policy-dependent), and bridges its
stdin/stdout to the bus. The child process doesn't need to know anything
about VDRX - it just reads and writes JSON lines:

- **stdin**: every bus message matching the entry's `subscribe` filters
  arrives as one line: `{"topic":"...","payload":"...","source":"..."}`
- **stdout**: every line the process writes is republished onto the bus as
  `<id>.out` by default - or, if the line itself is
  `{"topic":"some.topic","payload":"..."}` and `some.topic` matches the
  entry's `publish_allow` patterns, it's published to *that* topic instead. This
  is how a script can talk on more than one topic without VDRX needing to
  know anything about its protocol.

```json
{
  "id": "irc_bot",
  "command": "c:/php/php C:/dev/vdrx/scripts/irc_client.php --nick=vdrxbot --channel=#vdrx",
  "restart": "always",
  "subscribe": ["freenode.out"],
  "publish_allow": ["irc_bot.in"],
  "enabled": true
}
```

`restart`: `"always"` (default) | `"on-failure"` (only restart on nonzero
exit) | `"never"` (one-shot). `graceful_timeout_ms` overrides the global
`shutdown_grace_ms` for children that don't respond to a graceful hint at
all. `enabled: false` skips the entry entirely without deleting it from
config - handy for keeping a handful of alternates around (see the
`socket_clients` example below, which does exactly this for
soylentnews vs. libera).

**Queue groups - `queue_group`**: give two or more `processes` entries
(each still needs its own `id`) the same `queue_group` name and a matching
`subscribe` filter, and each published message goes to exactly one member
of the group (picked round-robin) instead of every member. This is how a
handful of identical worker scripts share one queue of jobs:

```json
[
  { "id": "worker1", "command": "php worker.php", "subscribe": ["jobs.in"], "queue_group": "workers" },
  { "id": "worker2", "command": "php worker.php", "subscribe": ["jobs.in"], "queue_group": "workers" },
  { "id": "worker3", "command": "php worker.php", "subscribe": ["jobs.in"], "queue_group": "workers" }
]
```

Omit `queue_group` (the default) for the ordinary fan-out behaviour where
every subscriber gets every message - existing configs are unaffected.

**Reverse-proxy variant**: add `prefix`/`host`/`port` to a `processes`
entry and VDRX also registers an HTTP route that reverse-proxies matching
requests to that address - for an app that already speaks HTTP itself
(`php -S 127.0.0.1:9101 -t phpapp`, a Node dev server, etc.) rather than
one you want driven over the bus.

---

# 3. Outbound TCP/TLS - `socket_clients`

A generic outbound socket client, the dialer counterpart to an HTTP site's
listener. Used for exactly one thing today: an IRC connection.

```json
{
  "id": "freenode",
  "host": "irc.libera.chat",
  "port": "6697",
  "tls": "true",
  "tls_verify": "true",
  "tls_ca_file": "C:/dev/crt/hexchat_cert.pem",
  "subscribe": ["irc_bot.in"],
  "enabled": true
}
```

Raw bytes in become `<id>.out` on the bus (line-delimited by default -
`delimiter`/`framing`/`chunk_size` are configurable); anything published
matching `subscribe` gets written to the socket. `reconnect`: `"auto"`
(default, with `reconnect_delay_ms`/`max_reconnect_delay_ms` backoff) |
`"never"`.

This is deliberately dumb - it doesn't know IRC exists. All the NICK/USER/
PING-PONG/JOIN protocol logic lives entirely in the `irc_bot` process
above, talking to this socket purely via `irc_bot.in`/`freenode.out`. If
you want to point the bot at a different network, you flip `enabled` on
the socket_clients entry (and adjust the `processes` entry's `subscribe`)
rather than changing any protocol code - that's the actual difference
between the `soylent`/`freenode` entries already in `vdrx.conf`.

**Gotcha**: some IRC networks are picky about TLS
verification, cert chains, or just flaky from a given host - if a
connection silently won't come up, try `tls_verify: "false"` temporarily
to isolate whether it's a TLS-handshake problem versus a protocol-level
one, and try a different network entirely before
assuming the bug is in your Pascal or PHP.

---
*Section numbers (§N) are shared across all vdrx docs - see the [section map](README.md#section-map).*
