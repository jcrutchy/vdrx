# VDRX

VDRX is a small, boring, Unix-philosophy daemon written in Object Pascal /
Free Pascal. Its whole job is two things: an in-process pub/sub message bus
that anything running inside it can publish to and subscribe from, and
supervision of external processes (spawn, restart-on-crash, graceful-then-
forced shutdown). Everything else — HTTP, WebSocket, whatever gets built on
top of it later — is a consumer of those two things, not part of the core.

No external Pascal dependencies — everything here is vanilla Free Pascal
plus the OS's own OpenSSL library for TLS. That's a deliberate project
choice, not an oversight.

## The core idea, in one picture

```
                    ┌─────────────────────────────┐
                    │         TVDRX_Kernel          │
                    │  (owns the queue + registry,  │
                    │   runs the dispatch loop)      │
                    └───────────┬─────────────────┘
                                │
              ┌─────────────────┼─────────────────┐
              │                 │                 │
      TVDRX_MessageQueue   TVDRX_Registry     (dispatch thread)
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
        │  every TVDRX_Executive descendant:          │
        │  Logger · Admin · Stdin · WebSocket          │
        │  HTTP · Bridge (any external process)        │
        └───────────────────────────────────────────┘
```

Everything is an **executive** — a small class with an `ID`, a reference to
the bus, and a `HandlePacket(AMsg)` method. Executives don't call each other
directly; they publish onto a topic and let the Registry figure out who's
listening. That's the whole trick, and it's why wildly different things (a
spawned process, a browser's WebSocket, a config reload, a future SOMA
worker) can all interoperate without knowing about each other.

## Key concepts

### Topics and filters

Topics are dot-delimited strings (`log.warn`, `<bridge-id>.out`,
`sys.reload`). Filters use the same shape with two wildcards:

- `*` matches exactly one segment
- `>` matches the rest of the topic, however many segments remain

So `log.>` catches `log.info`, `log.warn`, `log.error`, ...; `sys.>` catches
every admin command; a literal topic with no wildcard matches only itself.

### Subscriptions are multi-filter

One executive can hold any number of active filters at once — call
`Registry.Register(Exec, ID, Filter)` again with the same `ID` to add
another filter rather than replacing the existing one. The first `Register`
call for a given `ID` also transfers ownership of the executive into the
Registry's master map (it'll be freed on `Unregister`); subsequent calls
just add routing entries. `UnregisterFilter` drops one filter without
touching the others; `ClearFilters` drops all of them without destroying the
executive; `Unregister` does both — drops everything and frees it.

### The registry doubles as the executive lifecycle manager

`InitializeAll` / `ShutdownAll` / `ApplyAllConfigs` walk every registered
executive and call its `Initialize` / `Shutdown` / `ApplyConfig`. Most
executives (Logger, Admin) leave these as no-ops; anything that owns a
socket or an external process overrides them to actually bind/spawn on
`Initialize` and tear down cleanly on `Shutdown`.

### Transport is separate from protocol

Every socket-owning executive descends from `TVDRX_SocketListenerExecutive`,
which owns the accept loop(s), thread-per-connection dispatch, and plain TCP
and TLS at the same time, on two independently configurable ports. Protocol
code (HTTP, WebSocket) talks to a `TVDRX_Transport` abstraction
(`Read`/`Write`/`Close`) instead of a raw socket, so none of it knows or
cares whether the client connected encrypted or not.

### Process supervision (Bridge)

`TVDRX_BridgeExecutive` is a generic external-process supervisor — spawn,
monitor, restart-on-crash with exponential backoff, graceful-then-forced
shutdown. It's an executive like any other: the Registry manages it exactly
the same way, with no special-casing. Every line the child process writes to
stdout is republished onto the bus as `<id>.out`; every bus message matching
its subscription is written to the child's stdin as a JSON line
(`{"topic":...,"payload":...,"source":...}`). A child process doesn't need
to know anything about VDRX's bus API — it just reads/writes JSON lines.

This is the "systemd-lite" layer: the `processes` config array (see below)
turns any command into a supervised entry with zero new Pascal per program
you want VDRX to babysit.

## The executives

| Unit | What it is |
|---|---|
| `vdrx_core.pas` | `TVDRX_Executive`, `TVDRX_MessageQueue`, `TVDRX_Registry`, `TVDRX_Kernel` — the bus itself, no protocol knowledge |
| `vdrx_config.pas` | JSON config file wrapper (`GetString`/`GetInteger`/`GetBoolean`/`GetStringArray`/`GetObjectArray`/`Reload`) |
| `vdrx_admin.pas` | Listens on `sys.>` — `sys.reload`/`sys.quit`/`sys.restart`/`sys.kill`/`sys.killall`. The daemon's whole operator-control surface |
| `vdrx_admincmd.pas` | Shared line-command parser (`quit`/`restart`/`reload`/`kill <target>`/`killall [type]`) that turns typed text into `sys.*` bus messages — used by Stdin today, reusable by any future text-command source |
| `vdrx_stdin.pas` | Reads admin commands one per line from the console, on its own thread |
| `vdrx_logger.pas` | Listens on `log.>` (registered on `>` in `main`, i.e. everything); colored console output + plain file (`vdrx_daemon.log`) |
| `vdrx_procutil.pas` | Cross-platform process helpers: bounded thread/process wait, graceful terminate (SIGTERM on Unix), force-kill (SIGKILL / `taskkill /T /F`) |
| `vdrx_bridge.pas` | `TVDRX_BridgeExecutive` — spawns and supervises one external process (see "Process supervision" above) |
| `vdrx_transport.pas` | `TVDRX_Transport` / `TVDRX_PlainTransport` / `TVDRX_TLSTransport` / `TVDRX_TLSContext` — the plaintext-vs-TLS abstraction everything else builds on |
| `vdrx_socketlistener.pas` | `TVDRX_SocketListenerExecutive` — shared accept-loop/threading/dual-transport base class |
| `vdrx_websocket.pas` | Browser-facing WS bridge: JSON-RPC (`subscribe`/`unsubscribe`/`unsubscribe_all`/`publish`) over a WebSocket, each connection a registered executive |
| `vdrx_http.pas` | Request/response HTTP server: static file serving, reverse-proxy routing to `processes` entries that declare a `prefix`, and CLI-bridge routing (see below) |
| `vdrx_weblistener.pas` | Optional: HTTP + WS multiplexed on one port (sniffs the `Upgrade` header) |
| `vdrx_templates.pas` | Recursive placeholder template engine (`$$setting$$` / `??const??` / `%%var%%` / `@@loop@@`) used by HTTP's rendered pages |

## What's actually running right now

`vdrx_daemon.lpr` wires up **Logger, Admin, and Stdin** unconditionally.
WebSocket and HTTP are wired up if enabled in config (`executives.ws.enabled`
/ `executives.http.enabled`). Any entry in the `processes` config array gets
a supervised Bridge; any entry in `cli_bridges` gets a routed CLI script
(no persistent process). See `WIRING.md` for the session-by-session design
log.

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
fpc -Mobjfpc -Sh -Fu/usr/lib/x86_64-linux-gnu/fpc/<ver>/units/x86_64-linux/openssl vdrx_daemon.lpr
```

## Running

```bash
cd daemon
./vdrx_daemon
```

Reads `vdrx_daemon.conf` from the working directory and writes to
`vdrx_daemon.log`. Type `quit`, `restart`, `reload`, `kill <pid-or-id>`, or
`killall [type]` at the console and press Enter — see `vdrx_admincmd.pas`.

## Config file (`vdrx_daemon.conf`)

```json
{
  "shutdown_grace_ms": 5000,
  "stdin_admin_enabled": true,
  "template_dir": "templates",
  "static_dir": "static",
  "settings": { "site_title": "VDRX" },
  "processes": [
    {
      "id": "phpapp1",
      "command": "c:/php/php -S 127.0.0.1:9101 -t phpapp",
      "graceful_timeout_ms": 300,
      "prefix": "/app/",
      "host": "127.0.0.1",
      "port": 9101
    },
    {
      "id": "somaworker",
      "command": "./soma_worker"
    }
  ],
  "cli_bridges": [
    {
      "id": "phpcli1",
      "prefix": "/cli/",
      "command": "c:/php/php",
      "script_dir": "phpcli",
      "timeout_ms": 5000,
      "content_type": "text/html"
    }
  ],
  "executives": {
    "http": { "enabled": false, "port": 8081, "tls_port": 0, "tls_cert": "", "tls_key": "" },
    "ws":   { "enabled": false, "port": 8082, "tls_port": 0, "tls_cert": "", "tls_key": "" }
  }
}
```

**`processes`** — every entry gets a supervised `TVDRX_BridgeExecutive`.
Only `id` and `command` are required. Add `prefix`/`host`/`port` and it also
gets an HTTP reverse-proxy route (needs `executives.http.enabled: true`);
omit them for a bare supervised background process with no HTTP surface —
e.g. a SOMA worker or anything else you just want VDRX to keep alive.

**`cli_bridges`** — a genuinely different mechanism: each request to
`prefix` invokes `command` fresh against a script under `script_dir` and
returns its output, rather than talking to a long-running process. No
Bridge executive involved.

`tls_port: 0` means "TLS disabled for this executive." `tls_cert`/`tls_key`
should be absolute paths to PEM files.

Publishing `sys.reload` on the bus (or typing `reload` at the console)
re-reads this file and re-applies it to every registered executive live,
including rebinding ports if they changed.

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
Kernel.Registry.Register(Logger, 'logger', 'some.new.topic.>');
```

A real consumer would `Register` the same way, then in `HandlePacket` parse
the topic/JSON payload and act on it.

## Known gaps (deliberately deferred, not forgotten)

- **WebSocket**: `sys.auth` is a stub — any non-empty token is accepted
- **Shutdown**: per-connection threads are fire-and-forget
  (`FreeOnTerminate`), not individually tracked/joined — fine for a dev
  daemon, not yet a clean production shutdown
- **No authentication** anywhere on the `sys.*` admin surface — anything
  that can reach stdin (or, later, any other admin-command source) can
  quit/restart/kill the daemon. Deliberate for now; revisit if this ever
  runs somewhere multi-tenant
- **Buckets**: no namespace/persistence-policy layer above raw topics yet —
  under consideration for grouping related topics (logs vs. world-state vs.
  control) and deciding what gets written to disk
- **IRC**: no longer part of this repo — see the standalone IRCD project
  (`hogircd`), which can be wired in as a `processes` entry like anything
  else once it's ready to be supervised that way

## Further reading

`WIRING.md` has the session-by-session design log: why each piece is shaped
the way it is, worked examples, and notes on things that were tried,
verified, or fixed along the way (including the TLS binding story above, in
more detail).
