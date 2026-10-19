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
backslashes, dot-files (`.git`, `.env`; `.well-known` is allowed) or segments
ending in `.`/space are refused with 403.

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
the body on stdin, and the script's directory as cwd. Because it is real CGI,
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
