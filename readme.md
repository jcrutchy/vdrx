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
  "subscribe": ["echo.daemon.in"], "publish_allow": ["http.reply.*"], "enabled": true }
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

### 4e. Exposing an ordinary CLI program - `runners` + `http_routes`

A normal command-line tool doesn't speak the bus, so two small pieces put it
there - and because both sides are just bus participants, **anything** on the
bus can use the tool, not only a browser:

```
browser ──► http_routes entry ──publish──► femsection.in ──► runners entry ──► program
   ▲                                                                              │
   └──────── HTTP response ◄──── reply on a per-request topic ◄───── publish ◄────┘
```

- A **`runners`** entry subscribes to a topic, runs the program once per
  message, and publishes a reply envelope. It is an ordinary executive:
  a WebSocket client, a `processes` script or an IRC bridge can publish to its
  topic exactly as an HTTP route does.
- An **`http_routes`** entry maps a URL prefix to a topic: it publishes the
  request there (with a per-request `reply_to`) and returns whatever reply comes
  back.

```json
"http_routes": [
  { "id": "femsection", "prefix": "/fem3d/section", "allow": "POST", "timeout_ms": 12000 }
],
"runners": [
  { "id": "femsection",
    "command": "{FEM3D_BIN}/femsection{EXE_EXT}",
    "args": ["-"],
    "exit_status": { "1": 422, "3": 400 },
    "timeout_ms": 8000 }
]
```

A route and a runner with the same `id` are wired together by default
(`<id>.in`); set `in_topic` / `subscribe` to wire them differently or to put
several routes in front of one runner.

**`http_routes`** fields: `id`, `prefix` (required) · `in_topic` (default
`<id>.in`) · `allow` (methods accepted, default `POST`; others get 405) ·
`timeout_ms` (default 10000; no reply in time -> 504) · `content_type` (of a
successful reply, default `text/plain`) · `response`: `"raw"` (default - the
reply's own `status`, `body` and `content_type`) or `"json"` (the whole reply
envelope returned as `application/json`, so a page gets `status`, `exit_code`
and `stderr` as data, not just text).

**`runners`** fields:

| Field | Meaning |
|---|---|
| `id`, `command` | Required. `command` is the program plus any fixed leading arguments. |
| `subscribe` | Topic(s) it listens on; default `<id>.in`. |
| `publish` | Topic the reply goes to when the message has **no** `reply_to`; default `<id>.out`. |
| `args` | Further arguments, as a JSON array. `%%name%%` is filled from the message's `params` / `query`; `%%name?%%` is optional (a token containing a missing optional value is dropped - write a flag and its value as one token, `"--units=%%units?%%"`). Only placeholders named here can ever be filled. |
| `stdin` | `"body"` (default: the message's `body` is the program's stdin) or `"none"`. |
| `exit_status` | Exit code -> reply status, `{"1": 422}`; other non-zero exits are 500. |
| `timeout_ms` | Default 10000; the program is force-killed and the reply status is 504. |
| `workers` / `max_queue` | Programs that may run at once (default 2) / messages allowed to wait (default 64); beyond that the reply status is 503. |
| `content_type` | Of a successful reply; default `text/plain`. |
| `script_dir` | Working directory for the program. |

**Message in** - plain text (taken as the `body`), or JSON:
`{"body": "...", "params": {"units": "mm"}, "query": "units=mm", "reply_to": "some.topic"}`
(an HTTP route sends `query` and `body` itself; `params` is for bus clients).
**Reply out** - `{"status": 200, "content_type": "text/plain", "body": "...", "exit_code": 0}`,
plus `"stderr"` when the program wrote any. The program is started with an
argument **vector**, never through a shell and never split on spaces, so a
parameter value can't change the command; values are also limited to 1024
characters with no control characters, and a token that is *only* a
placeholder can't start with `-` (so a caller can't inject an option flag).

Notes: output is carried as a JSON string, so it should be text (invalid UTF-8
is replaced with `?`). For a browser page on another origin, set `"cors": true`
on the `http_sites` entry; those headers are added to every route response.

---

### 4f. Config conventions - what `id`, `subscribe` and `publish` mean

Every bus-facing config entry follows the same three rules, so a config reads
the same wherever you look:

- **`id`** names the executive (it is also what `sys.kill` and the logs call it).
- **`subscribe`** is the topic filter(s) it listens on (a string, or an array).
  Where it's omitted the default is `<id>.in` - and the startup banner prints the
  resolved topics for every entry, so nothing is hidden.
- **`publish`** is the topic it writes its output to (default `<id>.out`) - it
  always names a *topic*. On `processes`, the list of topic patterns the child
  may publish to is called **`publish_allow`** instead (the old `publish`
  spelling there still works, with a warning).

| Section | Subscribes (`subscribe`) | Publishes |
|---|---|---|
| `processes` | default `<id>.in` | stdout lines to `<id>.out`, or to any topic in `publish_allow` |
| `socket_clients` | default `<id>.in` | received data to `publish` (default `<id>.out`) |
| `runners` | default `<id>.in` | replies to `reply_to`, else `publish` (default `<id>.out`) |
| `templates` | default `<id>.in` | the render reply, to the request's `reply_to` |
| `buckets` | required (formerly `topics`) | nothing - records to a file |
| `http_routes` | - (the HTTP side waits for one reply) | the request to `in_topic` |

`buckets` entries are now `id` + `subscribe` (the old `name` / `topics` still
work, with a warning). The older `cli_bridges` protocols (`cgi`, `bus`,
`bus-daemon`) are still supported; new work should use `http_routes` and
`runners`, which go through the bus the same way everything else does.

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

**Environment variable expansion** - any string value anywhere in
`vdrx.conf` or an included file can reference `${VAR_NAME}` or
`${VAR_NAME:-default}`; expansion happens once, on the raw file text,
before it's parsed as JSON, and before `includes` merging. Handy for
secrets/hosts that shouldn't be committed, or for one `vdrx.conf` used
across a couple of machines:

```json
{ "host": "${IRC_HOST:-irc.libera.chat}", "port": "${IRC_PORT:-6697}" }
```

An unset variable with no `:-default` expands to an empty string rather
than being left as literal `${...}` text.

**Variables** - a top-level `"variables"` object declares your own
`{NAME}` variables, and VDRX also provides automatic (reserved) ones and
`{ENV:NAME}` for environment variables. A reference can be used in any
string **key or value** anywhere in `vdrx.conf` *and* in every file it
(recursively) includes - including inside `includes` paths, and inside
other variables' names and values:

```json
{
  "includes": ["{KYZU_DIR}/kyzu.vdrx.conf"],
  "variables": {
    "KYZU_DIR": "C:/dev/kyzu",
    "PHP_DIR": "c:/php",
    "PHP_BIN_FILENAME": "{PHP_DIR}/php{EXE_EXT}",
    "ADMIN_EMAIL_ADDRESS": "admin@example.com"
  },
  "cli_bridges": [
    { "id": "demo", "prefix": "/demo", "protocol": "bus",
      "command": "{PHP_BIN_FILENAME} {CONF_DIR}{PATH_SEPARATOR}scripts{PATH_SEPARATOR}hello_bus.php" }
  ]
}
```

| Reserved variable | Value |
|---|---|
| `{PLATFORM}` | `windows`, `linux`, `darwin`, `freebsd`, `unix` or `unknown` |
| `{ARCHITECTURE}` | `x86_64`, `i386`, `aarch64`, `arm`, `ppc64` or `unknown` |
| `{PATH_SEPARATOR}` / `{PATH_LIST_SEPARATOR}` | directory separator (`\` or `/`) / PATH-list separator (`;` or `:`) |
| `{EXE_EXT}` | `.exe` on Windows, empty elsewhere |
| `{VDRX_ROOT_PATH}` | directory containing the running vdrx executable |
| `{VDRX_BIN_FILENAME}` / `{VDRX_BIN_PATH}` | the executable's file name / full path |
| `{APP_ROOT_PATH}` / `{APP_BIN_FILENAME}` / `{APP_BIN_PATH}` | the same three under their generic names (what `jsonconf.pas` itself provides) |
| `{MAIN_CONF_DIR}` | directory of the top-level `vdrx.conf` |
| `{CONF_DIR}` / `{CONF_FILE}` | directory / name of the file the reference is *written in* - so inside an included `kyzu.vdrx.conf`, `{CONF_DIR}` is the kyzu directory |
| `{LBRACE}` / `{RBRACE}` | a literal `{` / `}` |
| `{ENV:NAME}` | environment variable (error if unset or empty) |
| `{ENV:NAME:-fallback}` | environment variable, or `fallback` if unset/empty |

Rules worth knowing:

- **Recursion and nesting.** Variables may use other variables (in names
  and values) in any order, and references nest: `{VAR_{WHICH}}`.
- **Circular references are errors.** `A` → `B` → `A` is reported with the
  chain (`circular variable reference: A -> B -> A`). At startup the
  daemon refuses to run and prints the problems; on `reload` the
  **existing configuration stays in force** and the problems are written
  to the log as errors. The same applies to a JSON syntax error, an
  undefined variable, an unset `{ENV:NAME}` without a fallback, or a bad
  include.
- **Includes.** An included file can use variables declared by the file
  that includes it. If two files declare the same variable, the
  including file wins - so an application's own conf can ship a default
  and `vdrx.conf` can override it. An `includes` path may use variables
  declared in the including files above it (not in itself or its
  siblings).
- **Strict about typos, relaxed about everything else.** Something shaped
  like a reference (`{print}`) that names nothing is an error; braces
  that aren't shaped like one (`{"a":1}`, `{status,body}`, `{ }`) are
  left alone. Write `{LBRACE}print{RBRACE}` for a literal `{print}`.
- **Documentation is exempt.** A `description` key, or any key ending in
  `_description`, is never expanded.
- **Not just strings.** A variable can only be substituted into a JSON
  string, so write numbers and booleans as strings (`"port": "{WEB_PORT}"`)
  - `GetInteger`/`GetBoolean` read those fine.
- The resolved variables are also readable from code as config values:
  `Config.GetString('variables.ADMIN_EMAIL_ADDRESS', '')`.
- `{ENV:NAME}` is applied *after* the file is parsed, so unlike the older
  `${NAME}` form it's safe for values containing backslashes (Windows
  paths).

All of this - includes, variables, environment expansion, safe reload - lives
in **`jsonconf.pas`**, which depends on nothing but FPC's own `fpjson`
and `jsonparser`, so any other project (fem3d, soma, ...) can copy that one
file and use it. Subclass `TJsonConf`, override `RegisterReservedVariables`
and call `SetReservedVariable` to add your own reserved names (see
`vdrx_config.pas`, which adds the `VDRX_*` ones). `test_jsonconf.lpr` is its
self-contained test suite.

**`buckets`** - append-only JSONL recording of bus traffic, if you want a
durable log of a set of topics rather than just watching them go by:

```json
{ "id": "chatlog", "subscribe": ["irc_bot.out", "irc_bot.in"], "file": "chatlog.jsonl" }
```

Add `max_size_mb` to cap a bucket file's size - once appending the next
entry would push it over that size, the file rotates to `chatlog.jsonl.1`
(shifting any older `.1`../`.N-1` up by one) and a fresh file starts.
`max_files` caps how many rotated files are kept (default 5) before the
oldest is discarded:

```json
{ "id": "chatlog", "subscribe": ["irc_bot.out", "irc_bot.in"], "file": "chatlog.jsonl", "max_size_mb": 50, "max_files": 10 }
```

Omitting `max_size_mb` (the default) keeps a bucket's original unbounded
append-forever behaviour. `sys.history`/`history <bucket>` only reads the
live file, not rotated ones.

---

## 7. Unit map

| Unit | What's in it |
|---|---|
| `vdrx_core.pas` | `TVDRX_Kernel`, `TVDRX_MessageQueue`, `TVDRX_Registry`, `TVDRX_Executive` - the bus itself, zero protocol knowledge |
| `jsonconf.pas` | Generic, dependency-free JSON config loader: recursive `includes`, `{VARIABLES}`, environment expansion, safe reload (§6). Reusable by any project |
| `vdrx_config.pas` | Thin `TVDRX_Config` subclass of `TJsonConf` that adds the `VDRX_*` reserved variables |
| `vdrx_admin.pas` | `sys.>` admin commands (`sys.reload`/`sys.quit`/`sys.kill`/...) |
| `vdrx_stdin.pas` | Console command reader, feeds `vdrx_admin` |
| `vdrx_logger.pas` | Everything on the bus → colored console + `vdrx_daemon.log`, written from its own thread; long payloads are clipped (`log_max_payload_bytes`, default 4096) |
| `vdrx_procutil.pas` | Cross-platform process wait/terminate/kill helpers |
| `vdrx_bridge.pas` | `TVDRX_BridgeExecutive` - supervised external processes (§2) |
| `vdrx_bucket.pas` | Append-only JSONL topic recorder (§6) |
| `vdrx_templates.pas` | Template engine (`$$setting$$`/`??const??`/`%%var%%`/`##loop##`/`@@child@@`) and `TVDRX_TemplateExecutive`, the bus-reachable wrapper around it (§4d) |
| `vdrx_network.pas` | Everything socket-facing: TLS/plain transport, the listener base class, `TVDRX_HTTPExecutive` (§4) including `TVDRX_OneShotWaiter`/`PublishAndWait` (the bus-daemon/template-topic reply-correlation primitive), `TVDRX_WebSocketExecutive` + `TVDRX_WSConnection`/`TVDRX_WSProtocolExecutive` (§5), `TVDRX_SocketClientExecutive` (§3) |
| `vdrx_runner.pas` | `TVDRX_RunnerExecutive`: runs a CLI program per bus message, publishes the output (§4e) |
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
  plain/TLS accept loops; `TVDRX_WebListenerExecutive`/`TVDRX_HTTPExecutive`/
  `TVDRX_WebSocketExecutive` are all descendants of it) the same way
  `TVDRX_SocketClientExecutive` reuses the transport/framing code - not yet
  built.
