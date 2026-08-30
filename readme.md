# VDRX

VDRX is a small daemon that does two things and stays out of the way of
everything else: it runs a **pub/sub message bus** that anything inside it
can publish to or subscribe from, and it **supervises external processes**
(spawn, restart-on-crash, graceful shutdown). Everything else you can build
with it - HTTP, WebSocket, an IRC bridge, a game server - is just something
talking to that bus, not a special case baked into the core.

No external Pascal dependencies - vanilla Free Pascal plus the OS's own
OpenSSL for TLS. Single daemon binary, JSON config file, hot-reloadable.

This document is about **understanding how it fits together and using it**.
If you're changing VDRX's own Pascal source, the comments in each unit are
the source of truth - this is the map for building things *on top of* it.

---

## 1. The mental model

Everything that does anything in VDRX is an **executive** - a small object
with an ID and a `HandlePacket` method. Executives never call each other
directly. They publish a message onto a **topic**, and VDRX's registry
figures out who's subscribed and delivers it. That's the entire mechanism -
logging, admin commands, HTTP requests reaching a backend, an IRC line
arriving, a WebSocket client asking for updates, all of it is "publish a
message, something subscribed picks it up."

```
   spawned process  ──stdin/stdout──►  Bridge executive  ──┐
   browser (WS)     ──JSON-RPC─────►  WS connection      ──┤
   HTTP request      ─(bus route)──►  HTTP executive     ──┼──►  the bus  ──►  whoever's
   TCP/TLS peer      ──raw bytes───►  Socket client      ──┘   (topic +      subscribed to
                                                                 payload)     that topic
```

Because nothing talks to anything else directly, wildly different things -
a PHP script, a browser tab, a remote IRC server, a batch file - can all
cooperate through the same bus without knowing about each other at all.

### Topics and filters

Topics are dot-delimited strings: `log.warn`, `irc_bot.out`, `sys.reload`,
`ws.conn.7.send`. Subscriptions are **filters** over that same shape, with
two wildcards:

- `*` matches exactly one segment
- `>` matches everything from that point on, however many segments

`log.>` catches every log line; `irc_bot.*` catches `irc_bot.in` and
`irc_bot.out` but not `irc_bot.deep.thing`; a literal topic with no
wildcard matches only itself.

### The four ways to get code running against the bus

This is really the whole practical question when you're building something:
**how does my code talk to VDRX?** There are six answers, and they compose:

| Mechanism | Lifetime | Use it for |
|---|---|---|
| **Supervised process** (`processes`) | Long-running, restart-on-crash | A daemon that needs to react to bus events continuously - an IRC protocol handler, a game tick loop, a worker |
| **Reverse-proxy route** (`processes` + `prefix`/`host`/`port`) | Long-running, has its own HTTP server | An existing web app/framework you don't want to rewrite - `php -S`, a Node server, anything that speaks HTTP itself |
| **CGI-style CLI route** (`cli_bridges`, `protocol: "cgi"`) | Spawned fresh per HTTP request | A classic "one script = one URL" site, PHP/Python/whatever, using ordinary CGI env vars |
| **Bus CLI route** (`cli_bridges`, `protocol: "bus"`) | Spawned fresh per HTTP request | An HTTP endpoint whose backend logic you want expressed as "read one JSON request, write one JSON reply" - language-agnostic |
| **Bus-daemon route** (`cli_bridges`, `protocol: "bus-daemon"`) | Long-running, shared across every request | The same request/reply shape as above, but answered by an already-running `processes` subscriber instead of a fresh spawn each time - no per-request process-start cost |
| **Template executive** (`templates`) | Long-running | Rendering a named template set (`.tpl` files + `%%params%%`/`##rows##`) reachable by topic name from anywhere - a bus-CLI reply, a persistent daemon, anything - rather than tied to one HTTP site's connection |

The rest of this doc walks through each one with a real example.

---

## 2. Supervised processes - `processes`

Every entry in `processes` gets a `TVDRX_BridgeExecutive`: VDRX spawns the
command, restarts it if it dies (policy-dependent), and bridges its
stdin/stdout to the bus. The child process doesn't need to know anything
about VDRX - it just reads and writes JSON lines:

- **stdin**: every bus message matching the entry's `subscribe` filters
  arrives as one line: `{"topic":"...","payload":"...","source":"..."}`
- **stdout**: every line the process writes is republished onto the bus as
  `<id>.out` by default - or, if the line itself is
  `{"topic":"some.topic","payload":"..."}` and `some.topic` matches the
  entry's `publish` patterns, it's published to *that* topic instead. This
  is how a script can talk on more than one topic without VDRX needing to
  know anything about its protocol.

```json
{
  "id": "irc_bot",
  "command": "c:/php/php C:/dev/vdrx/scripts/irc_client.php --nick=vdrxbot --channel=#vdrx",
  "restart": "always",
  "subscribe": ["freenode.out"],
  "publish": ["irc_bot.in"],
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

**Reverse-proxy variant**: add `prefix`/`host`/`port` to a `processes`
entry and VDRX also registers an HTTP route that reverse-proxies matching
requests to that address - for an app that already speaks HTTP itself
(`php -S 127.0.0.1:9101 -t phpapp`, a Node dev server, etc.) rather than
one you want driven over the bus.

---

## 3. Outbound TCP/TLS - `socket_clients`

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

## 4. HTTP - `http_sites` and `cli_bridges`

Each entry in `http_sites` is an independent listener on its own port,
with its own static-file root and its own template store:

```json
{
  "id": "vdrx_admin",
  "port": 8081,
  "static_dir": "static",
  "template_dir": "templates"
}
```

Requests are handled in this order: reverse-proxy routes (from `processes`
entries with `prefix`), then `cli_bridges` routes, then static files under
`static_dir`. `cli_bridges` is a *global* route table shared across every
site - only `static_dir`/`template_dir` are per-site.

### 4a. CGI-style routes (`protocol` omitted or `"cgi"`)

The classic shape: the URL path beyond `prefix` is resolved to a script
file under `script_dir`, the interpreter (`command`) is run with that file
as its one argument, and a handful of CGI env vars
(`REQUEST_METHOD`/`QUERY_STRING`/`REQUEST_URI`/`CONTENT_TYPE`/
`CONTENT_LENGTH`) are set. The process's raw stdout becomes the response
body verbatim.

```json
{
  "id": "phpcli",
  "prefix": "/cli/",
  "command": "c:/php/php",
  "script_dir": "phpcli",
  "timeout_ms": 5000,
  "content_type": "text/html"
}
```

`GET /cli/index.php` runs `phpcli/index.php` (see that file for a working
example reading the env vars directly with `getenv()` - since `command` is
plain `php`, not `php-cgi`, `$_GET`/`$_SERVER` are **not** auto-populated).

### 4b. Bus routes (`protocol: "bus"`)

The other shape, and the more interesting one: instead of a per-path file
lookup, `command` is one fixed script/executable that handles *everything*
under `prefix`. VDRX doesn't parse anything past `prefix` as a filesystem
path at all - the URL path suffix and the query string are just handed to
the script as data. This is what makes it language-agnostic: PHP, Python,
a compiled binary, or - as a deliberately extreme example - a Windows
batch file (`scripts/hello_bus.bat`) can all answer the exact same
contract, because it's just "read one JSON line, write one JSON line":

```json
{
  "id": "hello-bus-php",
  "prefix": "/hello",
  "protocol": "bus",
  "command": "c:/php/php scripts/hello_bus.php",
  "timeout_ms": 5000,
  "content_type": "text/plain"
}
```

**stdin** (one line):
```json
{"method":"GET","path":"/hello/channel/%23vdrx","prefix":"/hello",
 "sub_path":"/channel/%23vdrx","query":"name=World","headers":{...},"body":""}
```

**stdout** (one line, either shape):
```json
{"status":200,"body":"plain response text"}
```
```json
{"status":200,"template":"greeting","params":{"name":"World"},
 "rows":{"messages":[{"from":"vdrx","text":"hi"}]}}
```

The `template` form has two variants, chosen by whether `template_topic` is
present - see §4d below for why that matters and when to use which:

```json
{"status":200,"template":"greeting","params":{"name":"World"},
 "rows":{"messages":[{"from":"vdrx","text":"hi"}]}}
```
```json
{"status":200,"template":"greeting","template_topic":"template.admin.render",
 "params":{"name":"World"}, "rows":{"messages":[{"from":"vdrx","text":"hi"}]}}
```

Without `template_topic`, rendering happens in-process against whichever
HTTP site's own `template_dir` answered *this* connection - simple, no bus
round trip, but implicit: which store answers depends on which site's port
the request happened to arrive on. With `template_topic`, the render
request is instead published to that explicit topic and answered by a
`TVDRX_TemplateExecutive` (§4d) - unambiguous regardless of which site's
connection this is. See `scripts/template_demo.php` and
`templates/greeting.tpl` for a complete working pair using the explicit form.

`prefix` behaves like a URL-rewrite base, not a directory: `sub_path` is
whatever's left of the path after it, and `query` is the raw query string
- parse either however your script likes (`parse_str` in PHP, `urllib` in
Python, whatever).

**Two gotchas worth knowing before you hit them:**

- **File paths are relative to wherever VDRX's own working directory is**
  (typically wherever you launch the daemon from), not to the repo or to
  `cli_bridges`' entry itself. `"command": "c:/php/php scripts/hello_bus.php"`
  means `<cwd>/scripts/hello_bus.php` - if that file isn't actually there,
  you'll get a "malformed response" error (VDRX correctly detected the
  script's stdout wasn't valid JSON - because it was actually PHP's "file
  not found" message), which looks like a VDRX bug but almost always means
  a path problem. Keep the folder layout (`scripts/`, `templates/`,
  `phpcli/`) next to `vdrx.conf` matching what the config says, or update
  the config to match wherever things actually live. The startup banner and
  every relevant log line print the resolved absolute path VDRX actually
  used, specifically so this is diagnosable without guessing.
- **A literal `#` in a URL is a browser-side fragment delimiter** and gets
  stripped before the request ever reaches the server, unless it's
  percent-encoded as `%23`. This matters immediately for IRC channel names:
  a link built as `/irc/channel/#vdrx` never delivers `#vdrx` to your
  script; `/irc/channel/%23vdrx` does. Same for a query value like
  `?channel=#vdrx` → `?channel=%23vdrx`.

A bus-mode script should only ever write its one JSON reply line to
stdout - anything else (debug output, warnings) risks landing ahead of it
and corrupting the response. VDRX tries to be forgiving here (it skips a
UTF-8 BOM if the script file has one, and scans for the first line that
actually starts with `{` rather than blindly trusting line one), but a
script that wants to log its own activity should write to a file, the same
convention `scripts/irc_client.php` already follows for its bus-subscriber
side.

### 4c. Bus-daemon routes (`protocol: "bus-daemon"`)

The persistent-subscriber counterpart to §4b: same request/reply JSON
shape, but nothing is spawned per request. Instead, the request is
published to `in_topic` with a freshly-minted, per-request `reply_to`
added, and VDRX just waits (bounded by `timeout_ms`) for a reply there:

```json
{ "id": "echo-daemon-route", "prefix": "/echo-daemon", "protocol": "bus-daemon",
  "in_topic": "echo.daemon.in", "timeout_ms": 5000, "content_type": "text/plain" }
```

Whatever's subscribed to `in_topic` answers - typically an ordinary
`processes` entry (§2), already running, shared across every concurrent
request instead of paying spawn cost per request:

```json
{ "id": "echo_daemon", "command": "php scripts/echo_daemon.php", "restart": "always",
  "subscribe": ["echo.daemon.in"], "publish": ["http.reply.*"], "enabled": true }
```

See `scripts/echo_daemon.php` for a working pair with the config above.
One thing worth knowing if you write one of these: a `processes` entry's
stdin envelope wraps whatever was published as `{"topic":...,"payload":...,
"source":...}` - and if the *published* payload was itself valid JSON (as
an HTTP request envelope always is), it's embedded as a genuine nested
object, not double-encoded as a string. So `payload` in your script is
already the decoded request array/dict, not JSON text needing a second
decode pass - a real "Array to string conversion" trap in PHP if you decode
it twice, and the fix that let `echo_daemon.php` answer requests correctly.

Use §4b when each request is independent and simplicity matters more than
spawn cost; use this when request volume matters, or the daemon needs to
hold state across requests (a connection pool, an in-memory cache) that a
fresh process per request couldn't.

### 4d. Templates as their own executive - `templates`

A `templates` config entry gives a `TVDRX_TemplateStore` (§6's engine) its
own bus identity, independent of any `http_sites` entry:

```json
{ "id": "admin_templates", "dir": "templates", "subscribe": "template.admin.render" }
```

Anything - a bus-CLI reply's `template_topic` (§4b), a `bus-daemon`'s own
reply, a persistent process - can publish a render request to
`template.admin.render` and get back a rendered body, regardless of which
HTTP site (if any) is involved in the request at all:

```json
// published to the topic above:
{"template":"greeting","params":{"name":"World"},"rows":{...},"reply_to":"..."}
// its reply, to reply_to:
{"body":"<rendered html>"}
```

This is what §4b's `template_topic` field actually talks to - see that
section for why you'd choose it over an HTTP site's own implicit
`template_dir`: mainly, when the same `cli_bridges` route is reachable on
more than one site's port (routes are global, §4 above), rendering against
"whichever site happened to answer" stops being well-defined, and this
makes the choice explicit instead.

---

## 5. WebSocket - `executives.ws`

A single JSON-RPC bridge from the browser straight onto the bus - no
protocol-specific server code needed on VDRX's side for whatever you build
on top:

```json
{ "enabled": true, "port": 8082, "ping_interval_ms": 15000, "pong_timeout_ms": 10000 }
```

From JS: connect, then send `{"method":"sys.auth","token":"..."}` (any
non-empty token passes today - see §9), then
`{"method":"subscribe","filter":"irc_bot.out"}` /
`{"method":"publish","topic":"irc_bot.in","payload":"..."}` /
`{"method":"unsubscribe","filter":"..."}` / `{"method":"unsubscribe_all"}`.
Each connection is a first-class bus participant, so a browser tab talks to
everything else the same way a Bridge-managed process or a bus-CLI script
does. This is usually the right tool for anything that needs to *push*
updates to a browser continuously (chat, live state, notifications) -
prefer it over polling a bus-CLI route.

**Internally**, a connection is actually two cooperating executives, not
one - purely an implementation detail (the JSON-RPC surface above is
unchanged either way), but worth knowing if you're reading logs or
`vdrx_network.pas` itself:

- `TVDRX_WSConnection` - pure connectivity. Owns the socket, does the
  handshake, frames messages, keeps the ping/pong heartbeat alive, and
  relays bus traffic to/from the browser. It never parses a client's text
  frame - it just republishes the raw JSON onto that connection's own
  `<id>.rpc.in` topic.
- `TVDRX_WSProtocolExecutive` - everything else: `sys.auth`,
  `subscribe`/`unsubscribe`/`unsubscribe_all`/`publish`, all the actual
  interpretation of what a client said. It's a separate Registry entry
  (`<id>.rpc`), subscribed only to `<id>.rpc.in`, and replies by publishing
  to `<id>.rpc.out` - which the connectivity object relays to the socket
  verbatim, rather than wrapping in the usual bus-message envelope, since
  it's already a complete reply line (an `auth.ok` event, say).

Same split as everywhere else in VDRX (Bridge/socket_client): the thing
touching the wire never interprets what's on it, and the thing interpreting
it never touches the wire.

---

## 6. Everything else in `vdrx.conf`

```json
{
  "shutdown_grace_ms": 5000,
  "stdin_admin_enabled": true,
  "tls_ssl_dll": "C:/dev/openssl/libssl-1_1-x64.dll",
  "tls_crypto_dll": "C:/dev/openssl/libcrypto-1_1-x64.dll",
  "settings": { "site_title": "VDRX" }
}
```

- `shutdown_grace_ms` - default grace period before a hung child is
  force-killed; per-entry `graceful_timeout_ms` overrides it.
- `stdin_admin_enabled` - type `quit`/`restart`/`reload`/`kill <id>`/
  `killall [type]` at the console. `sys.reload` (or typing `reload`)
  re-reads `vdrx.conf` and re-applies it live, including rebinding ports.
- `tls_ssl_dll`/`tls_crypto_dll` - Windows-only override pointing FPC's
  `openssl` unit at specific DLLs, for when the system doesn't have an
  unversioned OpenSSL install FPC can `dlopen` by default.
- `settings.*` - anything here is available in templates as `$$name$$`.

**`buckets`** - append-only JSONL recording of bus traffic, if you want a
durable log of a set of topics rather than just watching them go by:

```json
{ "name": "chatlog", "topics": "irc_bot.out,irc_bot.in", "file": "chatlog.jsonl" }
```

---

## 7. Unit map

| Unit | What's in it |
|---|---|
| `vdrx_core.pas` | `TVDRX_Kernel`, `TVDRX_MessageQueue`, `TVDRX_Registry`, `TVDRX_Executive` - the bus itself, zero protocol knowledge |
| `vdrx_config.pas` | JSON config wrapper, hot-reloadable |
| `vdrx_admin.pas` | `sys.>` admin commands (`sys.reload`/`sys.quit`/`sys.kill`/...) |
| `vdrx_stdin.pas` | Console command reader, feeds `vdrx_admin` |
| `vdrx_logger.pas` | `log.>` → colored console + `vdrx_daemon.log` |
| `vdrx_procutil.pas` | Cross-platform process wait/terminate/kill helpers |
| `vdrx_bridge.pas` | `TVDRX_BridgeExecutive` - supervised external processes (§2) |
| `vdrx_bucket.pas` | Append-only JSONL topic recorder (§6) |
| `vdrx_templates.pas` | Template engine (`$$setting$$`/`??const??`/`%%var%%`/`##loop##`/`@@child@@`) and `TVDRX_TemplateExecutive`, the bus-reachable wrapper around it (§4d) |
| `vdrx_network.pas` | Everything socket-facing: TLS/plain transport, the listener base class, `TVDRX_HTTPExecutive` (§4) including `TVDRX_OneShotWaiter`/`PublishAndWait` (the bus-daemon/template-topic reply-correlation primitive), `TVDRX_WebSocketExecutive` + `TVDRX_WSConnection`/`TVDRX_WSProtocolExecutive` (§5), `TVDRX_SocketClientExecutive` (§3) |
| `vdrx.lpr` | Entry point - reads `vdrx.conf`, wires every executive above up from it |

---

## 8. Building and running

```bash
apt-get install fp-compiler fp-units-fcl fp-units-net libssl-dev
fpc -Mobjfpc -Sh -Fu/usr/lib/x86_64-linux-gnu/fpc/<ver>/units/x86_64-linux/openssl vdrx.lpr
./vdrx
```

(`libssl-dev` matters even though nothing here compiles against OpenSSL
headers - FPC's `openssl` unit `dlopen`s the shared library by its
unversioned name at runtime, and on Debian/Ubuntu that symlink only exists
once `libssl-dev` is installed.)

Reads `vdrx.conf` from the working directory, writes `vdrx_daemon.log`.
Relative paths in config (`static_dir`, `script_dir`, bus-route `command`
scripts) resolve against that same working directory - see the gotcha in
§4b if something that should exist can't be found.

---

## 9. Known gaps

- No authentication on the `sys.*` admin surface, or on WebSocket
  (`sys.auth` accepts any non-empty token) - fine for a single-operator
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
