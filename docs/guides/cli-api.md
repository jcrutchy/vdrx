# Command-line programs as HTTP APIs (stdin/stdout)

Any program that reads stdin and writes stdout becomes an HTTP endpoint - no CGI knowledge needed in the
program. Example: [`examples/cli-api`](../../examples/cli-api) wraps `sort`, `tr`, `wc`, `head` and `grep`.

Two config entries per endpoint - a **runner** (what to run) and an **`http_route`** (which URL feeds it):

```json
"http_routes": [ { "id": "sort", "prefix": "/api/sort", "allow": "POST" } ],
"runners":     [ { "id": "sort", "command": "sort" } ]
```

The same `id` wires them together (topic `sort.in`). Run vdrx from the example folder, then:

```bash
printf 'pear\napple\nfig\n' | curl --data-binary @- http://localhost:8080/api/sort      # apple fig pear
curl -d 'hello vdrx'        http://localhost:8080/api/upper                              # HELLO VDRX
curl -d 'one two three'     http://localhost:8080/api/words                              # 3
printf 'a\nb\nc\n' | curl --data-binary @- 'http://localhost:8080/api/head?n=2'          # a b
printf 'pear\napple\n' | curl --data-binary @- 'http://localhost:8080/api/grep?pattern=app'
curl -d 'one two'           http://localhost:8080/api/words.json    # status/exit_code/stderr as JSON
```

## How it behaves

- The request **body is the program's stdin** (`"stdin": "none"` to send nothing); its **stdout is the response body**.
- **Arguments** come from the `args` array. `%%name%%` is filled from the URL's query string (`?n=2`) or from a bus
  message's `params`; `%%name?%%` is optional (a token containing a missing optional value is dropped). Fixed
  words go in `command` (`"tr a-z A-Z"`) or as literal `args` tokens.
- The program is started from an **argument list, never through a shell**, so a parameter can't inject commands.
  Values are limited to 1024 characters with no control characters, and a token that is *only* a placeholder can't
  start with `-` (a caller can't smuggle in an option flag).
- **Exit codes** map to HTTP status with `exit_status`: `{ "1": 404 }` turns grep's "no match" into 404; any other
  non-zero exit is 500 (the `stderr` text is included with `"response": "json"` or in the log).
- `timeout_ms` (default 10000): the program is killed and the client gets 504. `workers` (2) and `max_queue` (64)
  bound concurrency; beyond that: 503.
- `allow` on the route restricts methods (default `POST`; others get 405). `"response": "json"` returns the whole
  reply envelope - `{"status":200,"body":"...","exit_code":0,"stderr":"..."}` - so a web page gets success/failure
  as data. `content_type` sets the type of a successful reply (default `text/plain`).
- Output is carried as text: invalid UTF-8 is replaced with `?`. For binary output (images, archives) use a
  [CGI program](python-cgi-web-server.md) instead.

## On Windows

The example needs Unix tools. On Windows point `command` at your own executables, e.g.
`"command": "{TOOLS}/mytool.exe"` with `"variables": { "TOOLS": "c:/tools" }`; the mechanism is identical.

## Beyond HTTP

A runner is an ordinary bus participant that listens on `<id>.in`: a WebSocket client, a supervised script, or an
IRC bridge can publish a request to it and get the reply on the topic it names as `reply_to` - the HTTP route is
just one way to publish. A message is either plain text (taken as the body) or JSON:
`{"body": "...", "params": {"n": "3"}, "reply_to": "my.reply.topic"}`. The full option table is in
[../http.md](../http.md#4e-exposing-an-ordinary-cli-program---runners--http_routes).

## Several routes, one program

`words` and `words_json` in the example both reach the same runner: `words_json` sets `"in_topic": "words.in"`
and `"response": "json"`. Route and runner ids only have to match, or be connected with `in_topic` / `subscribe`.
