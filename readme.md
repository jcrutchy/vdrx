# VDRX — Visual Data Relay Executive

VDRX is a modular, event-driven message-routing daemon written in Object
Pascal / Free Pascal. At its core it's a small in-process pub/sub bus (the
"executive bus") that anything running inside the daemon — an IRC server, a
WebSocket bridge, an external process, a config-reload handler — can publish
to and subscribe from, using the same handful of primitives no matter what
the thing on the other end actually is.

The name comes from the founding idea: **executives** are independent units
of work (an IRC connection, a listener, a spawned child process) that relay
**visual/structured data** to each other and to clients through one shared
**data relay**.

No external Pascal dependencies — everything here is vanilla Free Pascal
plus the OS's own OpenSSL library for TLS. That's a deliberate project
choice, not an oversight.

## The core idea, in one picture

```
                    ┌─────────────────────────────┐
                    │         TVRDX_Kernel          │
                    │  (owns the queue + registry,  │
                    │   runs the dispatch loop)      │
                    └───────────┬─────────────────┘
                                │
              ┌─────────────────┼─────────────────┐
              │                 │                 │
      TVRDX_MessageQueue   TVRDX_Registry     (dispatch thread)
       (the bus: topic +    (who's subscribed
        payload + source,    to which filters)
        FIFO, thread-safe)
              │                 │
              └────────┬────────┘
                       │  for every message: find subscribers
                       │  whose filter matches the topic,
                       │  call Exec.HandlePacket(msg) on each
                       ▼
        ┌───────────────────────────────────────────┐
        │  every TVRDX_Executive descendant:          │
        │  Logger · Admin · IRCD (+ per-connection)   │
        │  WebSocket (+ per-connection) · HTTP         │
        │  Whiteboard · Bridge (external process)      │
        └───────────────────────────────────────────┘
```

Everything is an **executive** — a small class with an `ID`, a reference to
the bus, and a `HandlePacket(AMsg)` method. Executives don't call each other
directly; they publish onto a topic and let the Registry figure out who's
listening. That's the whole trick, and it's why wildly different things
(a spawned `bash` script, a browser's WebSocket, an IRC channel, a config
reload) can all interoperate without knowing about each other.

## Key concepts

### Topics and filters

Topics are dot-delimited strings (`irc.#general.event`, `log.warn`,
`wb.board1.delta`). Filters use the same shape with two wildcards:

- `*` matches exactly one segment
- `>` matches the rest of the topic, however many segments remain

So `log.>` catches `log.info`, `log.warn`, `log.error`, ...; `irc.>` catches
every channel's events; `irc.#general.event` (no wildcard) matches that one
topic literally.

### Subscriptions are multi-filter

One executive can hold any number of active filters at once — call
`Registry.Register(Exec, ID, Filter)` again with the same `ID` to add
another filter rather than replacing the existing one. The first `Register`
call for a given `ID` also transfers ownership of the executive into the
Registry's master map (it'll be freed on `Unregister`); subsequent calls
just add routing entries. `UnregisterFilter` drops one filter without
touching the others; `ClearFilters` drops all of them without destroying the
executive; `Unregister` does both — drops everything and frees it.

This is the mechanism behind, for example, an IRC connection subscribing to
several channels at once, or pointing the `Logger` at a second firehose
(`irc.>`) just to eavesdrop on something while testing — see "Extending"
below.

### The registry doubles as the executive lifecycle manager

`InitializeAll` / `ShutdownAll` / `ApplyAllConfigs` walk every registered
executive and call its `Initialize` / `Shutdown` / `ApplyConfig`. Most
executives (Logger, Whiteboard, Admin) leave these as no-ops; anything that
owns a socket or an external process overrides them to actually bind/spawn
on `Initialize` and tear down cleanly on `Shutdown`.

### Transport is separate from protocol

Every socket-owning executive descends from `TVRDX_SocketListenerExecutive`,
which owns the accept loop(s), thread-per-connection dispatch, and — as of
this session — **plain TCP and TLS at the same time**, on two independently
configurable ports. Protocol code (HTTP, WebSocket, IRCD) talks to a
`TVRDX_Transport` abstraction (`Read`/`Write`/`Close`) instead of a raw
socket, so none of it knows or cares whether the client connected encrypted
or not.

## The executives

| Unit | What it is |
|---|---|
| `vrdx_core.pas` | `TVRDX_Executive`, `TVRDX_MessageQueue`, `TVRDX_Registry`, `TVRDX_Kernel` — the bus itself, no protocol knowledge |
| `vrdx_config.pas` | JSON config file wrapper (`GetString`/`GetInteger`/`GetStringArray`/`Reload`) |
| `vrdx_admin.pas` | Listens on `sys.reload`; reloads the config file and calls `ApplyAllConfigs` on everything |
| `vrdx_logger.pas` | Listens on `log.>`; colored console output + plain file (`vrdx_daemon.log`) |
| `vrdx_transport.pas` | `TVRDX_Transport` / `TVRDX_PlainTransport` / `TVRDX_TLSTransport` / `TVRDX_TLSContext` — the plaintext-vs-TLS abstraction everything else builds on |
| `vrdx_socketlistener.pas` | `TVRDX_SocketListenerExecutive` — shared accept-loop/threading/dual-transport base class |
| `vrdx_irc.pas` | A real (if minimal) IRCD: registration handshake, MOTD, multi-channel JOIN/PART/TOPIC/NAMES, cross-client chat relay over the bus. Each connection is its own registered executive |
| `vrdx_websocket.pas` | Browser-facing WS bridge: JSON-RPC (`subscribe`/`unsubscribe`/`unsubscribe_all`/`publish`) over a WebSocket, each connection a registered executive |
| `vrdx_http.pas` | Minimal request/response HTTP server, currently serving one whiteboard snapshot route |
| `vrdx_weblistener.pas` | Optional: HTTP + WS multiplexed on one port (sniffs the `Upgrade` header) |
| `vrdx_whiteboard.pas` | In-memory collaborative-board state (`wb.<board>.delta` in, `.synced` out); no persistence yet |
| `vrdx_bridge.pas` | Spawns and supervises one external process, feeds it bus messages as JSON lines on stdin, republishes its stdout lines back onto the bus |

## What's actually running right now

`vrdx_daemon.lpr` wires up **Logger, Admin, and IRCD** by default. HTTP, WS,
Whiteboard, Bridge, and the combined WebListener are fully implemented and
compiled in, but not yet instantiated in `main` — they're ready to wire up
when you need them (see `WIRING.md` for worked examples of each).

## Building

Requires Free Pascal (`fp-compiler`) plus the network/openssl unit packages:

```bash
apt-get install fp-compiler fp-units-fcl fp-units-net libssl-dev
```

`libssl-dev` matters even though this only runs the daemon, not builds
against OpenSSL headers — FPC's `openssl` unit `dlopen`s the OpenSSL shared
library by its **unversioned** name at runtime, and on Debian/Ubuntu that
symlink only exists once `libssl-dev` is installed (the runtime-only
`libssl3` package ships just the versioned `.so.3`). Without it, TLS quietly
never comes up — no crash, just a plain-only listener. See `WIRING.md` for
the full story.

The `openssl` unit itself typically isn't on FPC's default search path;
point the compiler (or your `.lpi`'s search paths) at wherever your
distro installed it, e.g.:

```bash
fpc -Mobjfpc -Sh -Fu/usr/lib/x86_64-linux-gnu/fpc/<ver>/units/x86_64-linux/openssl vrdx_daemon.lpr
```

## Running

```bash
cd daemon
./vrdx_daemon
```

Reads `vrdx_daemon.conf` from the working directory, binds IRCD's plain port
(and TLS port, if configured), and writes to `vrdx_daemon.log`. Press ENTER
to stop cleanly.

### Testing with an IRC client

Point HexChat (or any IRC client) at `<host>:6667` — no auth required.
Multi-channel JOIN, NAMES, TOPIC, and cross-client chat all work; open two
clients and JOIN the same channel to see them talk to each other.

## Config file (`vrdx_daemon.conf`)

```json
{
  "executives": {
    "ircd": {
      "enabled": true,
      "port": 6667,
      "tls_port": 0,
      "tls_cert": "",
      "tls_key": "",
      "servername": "vrdx",
      "network": "VDRX",
      "motd": ["one line per MOTD entry"]
    },
    "http": { "enabled": false, "port": 8081, "tls_port": 0, "tls_cert": "", "tls_key": "" },
    "ws":   { "enabled": false, "port": 8082, "tls_port": 0, "tls_cert": "", "tls_key": "" }
  }
}
```

`tls_port: 0` means "TLS disabled for this executive." `tls_cert`/`tls_key`
should be absolute paths to PEM files. `http`/`ws` support the same keys and
already have working `ApplyConfig` methods — they're just not instantiated
in `vrdx_daemon.lpr` yet.

Publishing `sys.reload` on the bus (once something exists to trigger it —
nothing does yet, by design) re-reads this file and re-applies it to every
registered executive live, including rebinding ports if they changed.

### Testing TLS

```bash
openssl req -x509 -newkey rsa:2048 -keyout test.key -out test.crt -days 1 -nodes -subj "/CN=localhost"
```

Set `tls_port`/`tls_cert`/`tls_key` accordingly and check the startup
banner — it distinguishes "TLS came up" from "TLS was configured but
failed" (bad path, unloadable libssl, etc.), so a silent failure won't look
like success.

## Extending: subscribing to something new

No special registration process — any executive already in the daemon can
pick up an additional filter with one more `Register` call:

```pascal
Kernel.Registry.Register(Logger, 'logger', 'irc.>');
```

That alone makes every IRC channel event show up in the log — a fast way to
confirm wiring before writing a purpose-built consumer. A real consumer
would `Register` the same way, then in `HandlePacket` parse the topic/JSON
payload and act on it — see `vrdx_irc.pas`'s own `HandlePacket` for the
pattern (check the payload's `"kind"` field; IRC events all share one topic
per channel, `irc.<channel>.event`, distinguished only by payload shape).

## Known gaps (deliberately deferred, not forgotten)

- **IRC**: no per-nick `PRIVMSG` routing (channel messages only), no
  WHO/WHOIS/LIST, no persistent nick registration/auth
- **WebSocket**: `sys.auth` is a stub — any non-empty token is accepted
- **Whiteboard**: in-memory only, no disk persistence (`BucketStore`) yet
- **Bridge → IRC**: nothing currently relays a Bridge process's stdout back
  into an IRC channel automatically — you'd wire a small adapter for that
- **Shutdown**: per-connection threads are fire-and-forget
  (`FreeOnTerminate`), not individually tracked/joined — fine for a dev
  daemon, not yet a clean production shutdown
- **HTTP/WS/Whiteboard/Bridge/WebListener**: implemented, not yet wired into
  `vrdx_daemon.lpr`'s `main`

## Further reading

`daemon/WIRING.md` has the session-by-session design log: why each piece is
shaped the way it is, worked examples for wiring up the not-yet-instantiated
executives, and notes on things that were tried, verified, or fixed along
the way (including the TLS binding story above, in more detail).
