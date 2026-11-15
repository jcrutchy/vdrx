# 4. HTTP - `http_sites` and `cli_bridges`

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

**Network exposure.** A listener binds to **`127.0.0.1` (loopback only) unless told otherwise**,
so a fresh config is not reachable from other machines. To serve other hosts, set `bind` to the
address of the interface they reach you on, or to `"0.0.0.0"` for every interface (vdrx prints a
warning at startup when you do). An address that doesn't parse is refused rather than falling
back to all interfaces. `max_connections` (default `256`, `0` = unlimited) is how many
connections the listener serves at once; further ones are closed immediately and counted in a
rate-limited `log.warn`. Both apply to the plain and the TLS port.

```json
{ "id": "intranet", "port": 8081, "bind": "10.1.2.3", "max_connections": 256 }
```

**Per-address limits.** `max_connections` alone lets one client fill every slot, so each listener also
limits what a single client address may do (all default to values that suit ordinary browsers; tune them for
your traffic, and remember that many users behind one NAT or proxy share an address):

| key | default | meaning |
|---|---|---|
| `max_connections_per_ip` | `64` | connections one address may have open at once; `0` = no limit |
| `connection_rate_per_ip` | `20` | sustained new connections per second from one address (token bucket); `0` = no limit |
| `connection_burst_per_ip` | `100` | bucket size: how many new connections an address may open at once before the rate applies |
| `limit_exempt` | none | comma-separated IPv4 addresses or `a.b.c.d/n` ranges that are never limited (monitoring, a trusted proxy). Anything that does not parse is reported at startup and ignored, so that address stays limited |

A refused connection is closed immediately without reading anything, and is counted in the same
rate-limited `log.warn` as `max_connections` (which names the limit that was hit and the most recent address).
The checks happen when the connection is *accepted*, in this order: `max_connections`, then the per-address
limits, so a connection refused by the global cap never spends a token. The table of tracked addresses is
bounded (65,536); when an attacker fills it with distinct addresses, new addresses are let through to the
global cap rather than refused, so that exhausting the table cannot lock everybody out. Addresses are IPv4 only
for now.

**Who is the client? (forwarded headers).** vdrx is normally the first server a client reaches, so a request's
`X-Forwarded-For`, `Forwarded`, `X-Real-IP`, `X-Client-IP`, `True-Client-IP`, `CF-Connecting-IP` and
`X-Forwarded-*` headers (and their underscore spellings) were written by the client. Scripts and services behind
vdrx often believe them (for rate limits, audit logs, "is this an internal address" checks), so vdrx **deletes
them from every request** before routing: CGI never sees `HTTP_X_FORWARDED_FOR`, bus messages don't carry them,
and a reverse-proxied upstream doesn't get them. For a reverse-proxy route vdrx instead tells the upstream the
truth: `X-Forwarded-For: <the connecting address>` and `X-Forwarded-Proto: http|https`. CGI's `REMOTE_ADDR` was
always the real peer.

If vdrx sits behind a proxy or load balancer you do control, list it in **`trusted_proxies`** (comma-separated
IPv4 addresses or `a.b.c.d/n` ranges, e.g. `"10.0.0.5, 10.1.0.0/16"`). Headers from those peers are believed and
passed on, and a proxied request extends `X-Forwarded-For` with the peer's address. Note that vdrx's *own* idea of
the client (per-address limits, the WebSocket login lockout, `REMOTE_ADDR`) is still the connecting address,
which behind a proxy is the proxy: run vdrx directly on the internet if those must see real clients.

**Security headers.** Every response from a site carries `X-Content-Type-Options: nosniff`,
`X-Frame-Options: SAMEORIGIN` and `Referrer-Policy: strict-origin-when-cross-origin`. A header of the same name in
the site's `headers` replaces the default (use that for `Content-Security-Policy`, `Permissions-Policy` or
`X-Frame-Options: DENY`); `"security_headers": false` removes the defaults. **`hsts_max_age`** (seconds, default
`0` = off) adds `Strict-Transport-Security` to responses sent over TLS only. Browsers remember HSTS, so turn it on
once every name the site answers to works over https (start with a small value). `security_headers` and
`hsts_max_age` are re-read by `sys.reload`; `trusted_proxies` is read at startup only.

**TLS policy.** A site with a `tls_port` also takes these keys (the same four exist under `executives.ws`):

| key | default | meaning |
|---|---|---|
| `tls_min_version` | `"1.2"` | `"1.2"` or `"1.3"`. Anything else (including `"1.0"`, `"1.1"`) is refused |
| `tls_ciphers` | ECDHE with AES-GCM or ChaCha20-Poly1305 | TLS 1.2 cipher list in OpenSSL syntax. The server's order wins |
| `tls_ciphersuites` | OpenSSL's TLS 1.3 default | TLS 1.3 suites, colon separated |
| `tls_session_tickets` | `false` | OpenSSL never rotates ticket keys by itself, so tickets would undo forward secrecy for as long as the daemon runs; resumption still works through the server-side session cache |

Compression and client-initiated renegotiation are always off. vdrx checks that the key belongs to the
certificate and warns at startup if the key file is readable by anyone but its owner. The policy is applied
and read back when the TLS port starts; if OpenSSL cannot honour it (an unknown cipher list, an
old library), the TLS port is **not started** and the reason is logged as an error, while the plain port of
the same site keeps running. A started port logs one `TLS policy: ...` line describing what is enforced.
These keys are read at startup, not on `sys.reload`.

**`websocket_path`** (e.g. `"/ws"`) serves WebSocket upgrades for that exact path on this site's port,
so pages and WebSocket share one port - see [websocket.md](websocket.md). It needs `executives.ws.enabled`.

Requests are handled in this order:

1. **`rewrites`** - regex path rewrites / redirects (§4g).
2. **Reverse-proxy routes** (from `processes` entries with `prefix`).
3. **Bus routes** - `cgi` entries (§4a) and `http_routes` entries (§4e); the
   longest matching prefix wins.
4. **Static files** under the site's `static_dir`.

The rewrite and route tables are *global*, shared across every site - only
`static_dir`/`template_dir` are per-site.

**One mechanism underneath.** Every bus route does the same thing: the HTTP
edge publishes a JSON *request envelope* to the route's topic, waits for a
reply on a freshly minted `reply_to` topic, and turns the *reply envelope*
back into an HTTP response. A `cgi` executive, a runner, a supervised daemon
or a WebSocket client are all just subscribers to that topic. (`cli_bridges`
below is the old spelling of the same thing and is translated to it at
startup.)

Request envelope: `method, path, prefix, sub_path, query, request_uri` (the
client's original URI, pre-rewrite)`, protocol, headers{}, body` (or
`body_b64` when the body isn't valid UTF-8, e.g. an upload)`, remote_addr,
remote_port, server_name, server_port, https, reply_to`; `cgi` routes add
`script_name, script_filename, path_info, doc_root`.

Reply envelope: `status, content_type, headers{}` (a value may be an array -
several `Set-Cookie`)`, body` or `body_b64`, or `template/params/rows` to have
a template rendered. `Content-Length`, `Transfer-Encoding` and `Connection`
can't be set by a reply - the edge owns framing.

## 4a. CGI executive - `cgi`

VDRX as a basic web server. A `cgi` entry is an executive (`vdrx_cgi.pas`)
*and* the route that feeds it:

```json
{
  "id": "php",
  "prefix": "/",
  "doc_root": "C:/www/mysite",
  "command": "{PHP_CGI_BIN_FILENAME}",
  "args": ["%%script%%"],
  "extensions": [".php"],
  "index": ["index.php", "index.html"],
  "fallback": "/index.php",
  "env": { "APP_ENV": "dev" },
  "timeout_ms": 30000,
  "workers": 4
}
```

(`PHP_CGI_BIN_FILENAME` is a variable in `vdrx.conf`: `{PHP_DIR}/php-cgi{EXE_EXT}`.)

How a URL under `prefix` is resolved against `doc_root`, in order:
an existing script (`/app/index.php/more/path` -> script plus
`PATH_INFO=/more/path`) -> an existing plain file (served static) -> a
directory's `index` file (`/sub` without the slash gets a 301 to `/sub/`)
-> the `fallback` front controller (frameworks, pretty URLs; `REQUEST_URI`
still holds what the client asked for) -> 404. Paths containing `..`, `:`,
backslashes, dot-files (`.git`, `.env`; `.well-known` is allowed), Windows 8.3
short-name aliases (`GIT~1`, `PROGRA~1.TXT` - NTFS's names for `.git` and
`Program Files`), Windows device names (`con`, `nul`, `aux`, `com1`..`lpt9`, with
any extension, on every platform) or segments ending in `.`/space are refused
with 403.

**What the HTTP front end accepts.** Every request head is checked before anything else sees it, because vdrx and
whatever is behind it (a proxied upstream, a CGI program) must agree on where a request ends and what it says.
A request is refused - `400`, or `501` for `Transfer-Encoding` - if it has: a bare CR or LF or any other control
character in the head; a header line starting with space/tab (obsolete line folding) or with whitespace before the colon;
a header name that is not a plain token; more than one `Content-Length`, or one that is not plain decimal digits; or any
`Transfer-Encoding` (chunked request bodies are not supported, so a client that streams an upload must send a
`Content-Length`). A head over 16 KiB gets `431`. Bytes that arrive beyond the declared body (a pipelined second request)
are discarded, never forwarded: every connection answers one request and closes.

The program is started from an argument vector (never a shell):
`command` + `args`, with `%%script%%` replaced by the absolute script path -
so the example above runs `php-cgi /www/mysite/index.php`. With `command` ""
the script file is itself the executable (classic `cgi-bin`). Python is just
`"command": "python3", "extensions": [".py"]`.

It gets the full RFC 3875 environment - `GATEWAY_INTERFACE, SERVER_SOFTWARE,
SERVER_PROTOCOL, SERVER_NAME, SERVER_PORT, REQUEST_METHOD, REQUEST_URI,
SCRIPT_NAME, SCRIPT_FILENAME, DOCUMENT_ROOT, PATH_INFO, PATH_TRANSLATED,
QUERY_STRING, REMOTE_ADDR, REMOTE_HOST, REMOTE_PORT, CONTENT_TYPE,
CONTENT_LENGTH, HTTPS` (TLS only), `REDIRECT_STATUS`, `HTTP_*` for each
request header (never `HTTP_PROXY` - httpoxy), plus `env` from the config -
the body on stdin, and the script's directory as cwd.

**What the program does *not* get.** Its environment is *clean*: the variables above plus `PATH`,
`LANG`/`LC_*`, `TZ`, the temp-dir variables and (Windows) what a program needs to start - **not** the
daemon's own environment, which may hold tokens, passwords or cloud keys. If a script legitimately needs
one of them, name it: `"child_env_passthrough": ["DB_HOST", "HTTPS_PROXY"]` (top level of `vdrx.conf`);
`"child_env_inherit": true` restores the old "everything" behaviour and prints a warning at startup.
A request header becomes `HTTP_*` only if its name is plain (letters, digits, `-`): `X_Forwarded_For`
and `X.Foo` are dropped, and when two spellings of one name arrive the first wins - otherwise a client
could impersonate a header your reverse proxy sets. Output is capped at `max_child_output_bytes`
(default 32 MiB per stream; the program is killed and the client gets `502`), the request body is
written from a helper thread so a program that ignores stdin cannot stall the timeout (`504`), and
a body that is not valid text - including any NUL byte - reaches the program as exact bytes. Because it is real CGI,
`php-cgi` populates `$_GET`, `$_POST`, `$_COOKIE`, `$_FILES` and `$_SERVER`
itself.

Its stdout is parsed as a CGI response: header lines (`Status:`,
`Content-Type:`, `Location:`, repeated `Set-Cookie:` ...), a blank line, the
body. A `Location` without `Status` is a 302. No header block at all ->
502. `"output": "raw"` skips the parsing (stdout is the body, status 200).
A program over `timeout_ms` is killed -> 504; a full queue (`max_queue`) -> 503.

> The old `cli_bridges` `protocol: "cgi"` is the same thing in its simplest
> form and is now translated into a `cgi` entry with `output: "raw"`.

## 4d. Templates as their own executive - `templates`

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

A template name is a plain file name (letters, digits, `_`, `-`, `.`; no leading `.`, no `..`, no path separators, at most 128
characters); anything else renders nothing, so a request cannot read a `.tpl` file outside the template directory. A `reply_to`
is honoured only if the requester could publish there itself: the `sys.` and `kernel.` namespaces are always refused (and
logged), and a WebSocket client in profile mode may only name topics its profile's `publish_allow` matches. So a render
request cannot be used to publish into operator-control topics, or onto any topic the client is not allowed to write to - the
same applies to the runner executive's `reply_to`. A profile that asks for replies on `reply.>` therefore needs `reply.>` in
its `publish_allow` as well as in `subscribe_allow`.

This is what §4b's `template_topic` field actually talks to - see that
section for why you'd choose it over an HTTP site's own implicit
`template_dir`: mainly, when the same `cli_bridges` route is reachable on
more than one site's port (routes are global, §4 above), rendering against
"whichever site happened to answer" stops being well-defined, and this
makes the choice explicit instead.

## 4e. Exposing an ordinary CLI program - `runners` + `http_routes`

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

## 4g. Rewrites - `rewrites`

```json
"rewrites": [
  { "match": "^/blog/([0-9]+)/?$", "to": "/post.php?id=$1" },
  { "match": "^/old-docs/(.*)$",   "to": "/docs/$1", "flag": "permanent" }
]
```

`match` is a regular expression against the request path (no query); `to`
replaces the whole target (`$1`, `$2` are the groups). A `?query` in `to`
replaces the query string, otherwise the client's is kept. `flag`: `last`
(default - first matching rule wins), `continue` (keep applying later rules),
`redirect` (302), `permanent` (301). Rewrites run before every kind of route.
A bad pattern is reported and skipped at startup.

---
*Section numbers (§N) are shared across all vdrx docs - see the [section map](README.md#section-map).*
