# Python (and any other CGI program)

The same `cgi` entry as [php-cgi](php-cgi-web-server.md); only `command` and `extensions` change.
Example: [`examples/python-cgi`](../../examples/python-cgi).

```json
"cgi": [ {
  "id": "py", "prefix": "/", "doc_root": "www",
  "command": "{PYTHON_BIN}", "extensions": [".py"],
  "index": ["index.py", "index.html"], "timeout_ms": 15000
} ]
```

`PYTHON_BIN` is `python3` on Linux and `python` on Windows in the example (via the `{PLATFORM}` variable
trick - see the conf). Run vdrx from the example folder and open <http://localhost:8080/>.

## The contract with a CGI program

vdrx runs `python3 /abs/path/script.py` in the script's folder and gives it:

- the request in **environment variables** (`REQUEST_METHOD`, `QUERY_STRING`, `PATH_INFO`, `CONTENT_LENGTH`,
  `HTTP_*` ...; the full list is in the [php-cgi guide](php-cgi-web-server.md#how-a-request-is-handled)),
- the request body on **stdin** (read exactly `CONTENT_LENGTH` bytes),

and expects on **stdout** header lines, a blank line, then the body:

```python
print("Status: 201 Created")              # optional; default 200
print("Content-Type: application/json")
print("Set-Cookie: a=1; Path=/")           # repeat for several cookies
print("Set-Cookie: b=2; Path=/")
print()                                    # blank line ends the headers
print('{"ok": true}')
```

`Location:` without `Status:` is a 302. Output with no header block gets a 502. A script that runs past
`timeout_ms` is killed (504). Anything written to stderr goes to the log. See `examples/python-cgi/www/` for
a page, an environment dump and a JSON API with status and cookies.

(Python's own `cgi` module was removed in 3.13; read `os.environ` and `sys.stdin` as the examples do.)

## Other languages

- **Perl / Ruby / Node / ...:** same entry with `"command": "perl"`, `"extensions": [".pl"]`, etc.
- **Scripts or programs that are executable themselves (classic `cgi-bin`):** use `"command": ""` -
  the script file is run directly (needs the execute bit and a `#!` line on Linux):

```json
{ "id": "classic", "prefix": "/cgi-bin/", "doc_root": "cgi-bin", "command": "", "extensions": [".cgi"] }
```

- **Simple scripts that just print a page** and don't want to write headers: `"output": "raw"` makes stdout the
  body with status 200 (and `content_type` sets its type).

Everything else (rewrites, `fallback`, `workers`, `timeout_ms`, `env`, mounting under a `prefix`, the
caveats about per-request processes and logging) is identical to the PHP guide.
