> **Legacy.** Everything on this page still works, but new setups should use the `cgi`, `runners` + `http_routes` and `processes` entries (see [http.md](http.md)). A runnable demo of each form is in [`examples/legacy-cli-bridges/`](../examples/legacy-cli-bridges/).

## 4a-legacy. The old CGI-style `cli_bridges` route (`protocol` omitted or `"cgi"`)

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

`GET /cli/index.php` runs `phpcli/index.php` (see `examples/legacy-cli-bridges/phpcli/index.php` for a working
example reading the env vars directly with `getenv()` - since `command` is
plain `php`, not `php-cgi`, `$_GET`/`$_SERVER` are **not** auto-populated).

## 4b. Bus routes (`protocol: "bus"`) - legacy spelling of a runner in envelope mode

The other shape, and the more interesting one: instead of a per-path file
lookup, `command` is one fixed script/executable that handles *everything*
under `prefix`. VDRX doesn't parse anything past `prefix` as a filesystem
path at all - the URL path suffix and the query string are just handed to
the script as data. This is what makes it language-agnostic: PHP, Python,
a compiled binary, or - as a deliberately extreme example - a Windows
batch file (`hello_bus.bat`) can all answer the exact same
contract, because it's just "read one JSON line, write one JSON line":

```json
{
  "id": "hello-bus-php",
  "prefix": "/hello",
  "protocol": "bus",
  "command": "php hello_bus.php",
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
connection this is. See `template_demo.php` and
`templates/greeting.tpl` for a complete working pair using the explicit form.

`prefix` behaves like a URL-rewrite base, not a directory: `sub_path` is
whatever's left of the path after it, and `query` is the raw query string
- parse either however your script likes (`parse_str` in PHP, `urllib` in
Python, whatever).

**Two gotchas worth knowing before you hit them:**

- **File paths are relative to wherever VDRX's own working directory is**
  (typically wherever you launch the daemon from), not to the repo or to
  `cli_bridges`' entry itself. `"command": "php hello_bus.php"`
  means `<cwd>/hello_bus.php` - if that file isn't actually there,
  you'll get a "malformed response" error (VDRX correctly detected the
  script's stdout wasn't valid JSON - because it was actually PHP's "file
  not found" message), which looks like a VDRX bug but almost always means
  a path problem. Keep the folder layout (`templates/`,
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
convention `irc_client.php` already follows for its bus-subscriber
side.

## 4c. Bus-daemon routes (`protocol: "bus-daemon"`) - legacy spelling of an `http_routes` entry

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
{ "id": "echo_daemon", "command": "php echo_daemon.php", "restart": "always",
  "subscribe": ["echo.daemon.in"], "publish_allow": ["http.reply.*"], "enabled": true }
```

See `echo_daemon.php` for a working pair with the config above.
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

---
*Section numbers (§N) are shared across all vdrx docs - see the [section map](README.md#section-map).*
