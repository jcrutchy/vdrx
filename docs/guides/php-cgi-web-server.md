# PHP web server (php-cgi)

Run PHP the way Apache or nginx+php-cgi does. Example: [`examples/php-cgi`](../../examples/php-cgi).

```json
{
  "variables": {
    "PHP_CGI_BIN_FILENAME_windows": "c:/php/php-cgi.exe",
    "PHP_CGI_BIN_FILENAME_linux": "php-cgi",
    "PHP_CGI_BIN_FILENAME": "{PHP_CGI_BIN_FILENAME_{PLATFORM}}"
  },
  "http_sites": [ { "id": "web", "port": 8080 } ],
  "rewrites":   [ { "match": "^/blog/([0-9]+)/?$", "to": "/post.php?id=$1" } ],
  "cgi": [ {
    "id": "php", "prefix": "/", "doc_root": "www",
    "command": "{PHP_CGI_BIN_FILENAME}",
    "extensions": [".php"], "index": ["index.php", "index.html"],
    "fallback": "/index.php", "timeout_ms": 30000, "workers": 4
  } ]
}
```

Install PHP's CGI binary (`apt install php-cgi`, or the Windows zip from php.net, which includes
`php-cgi.exe`), edit the path variable if it isn't on `PATH`, run vdrx from the example folder and open
<http://localhost:8080/>.

## How a request is handled

A `cgi` entry is a small executive plus the HTTP route that feeds it. For a URL under `prefix`:

1. **Rewrites** run first (`/blog/42` -> `/post.php?id=42`). `REQUEST_URI` still holds what the browser asked for.
2. The path is resolved under `doc_root`, in this order: an existing **script** (anything after it is
   `PATH_INFO`, so `/info.php/extra` runs `info.php`) -> an existing **plain file** (served as-is) ->
   a directory's **index** file -> the **fallback** script (the front controller used by frameworks and pretty
   URLs) -> 404. `/dir` without a slash redirects to `/dir/`.
3. The request becomes a bus message; the executive runs `php-cgi <script>` (an argument list, never a shell)
   with the RFC 3875 environment: `REQUEST_METHOD`, `QUERY_STRING`, `SCRIPT_NAME`, `SCRIPT_FILENAME`,
   `PATH_INFO`, `DOCUMENT_ROOT`, `SERVER_NAME/PORT`, `REMOTE_ADDR`, `CONTENT_TYPE/LENGTH`, `HTTPS` (TLS only),
   `REDIRECT_STATUS`, and `HTTP_*` for every request header (never `HTTP_PROXY`). The request body is the
   program's stdin and its working directory is the script's folder.
4. php-cgi's output is parsed as a CGI response: `Status:`, `Content-Type:`, `Location:` and repeated
   `Set-Cookie:` headers, a blank line, the body. That is why `header()`, `setcookie()` and
   `http_response_code()` just work.

`$_GET`, `$_POST`, `$_COOKIE`, `$_FILES` and `$_SERVER` are filled in by php-cgi itself from that environment.
Binary uploads and binary responses are carried intact.

## Options worth knowing

| Key | Meaning |
|---|---|
| `workers` / `max_queue` | PHP processes running at once (default 4) / requests allowed to wait (64); beyond that: 503 |
| `timeout_ms` | a script running longer is killed and the client gets 504 (default 30000) |
| `env` | extra environment variables: `"env": { "APP_ENV": "dev" }` |
| `args` | arguments to php-cgi; default `["%%script%%"]`. e.g. `["-d", "memory_limit=256M", "%%script%%"]` |
| `static` | `false` = don't serve non-script files from `doc_root` |
| `allow` | restrict methods, e.g. `"GET,POST"` |
| `prefix` | mount the app below a path: `"prefix": "/app/"` (the URL minus the prefix maps onto `doc_root`) |

## Things to know

- **A new php-cgi process per request.** Fine for development and small sites; a busy site wants a
  persistent PHP (php-fpm, or `php -S` run under `processes` with a reverse-proxy `prefix` - see
  [../processes-and-sockets.md](../processes-and-sockets.md)).
- **Non-script files are served as plain text.** Keep includes, `.sql`, backups and secrets outside
  `doc_root` (dot-files are always refused).
- **Limits come from php.ini** (`upload_max_filesize`, `post_max_size`, `memory_limit`). vdrx buffers the
  whole request and response in memory and does not support chunked request bodies.
- **Logging.** Every request envelope passes over the bus and the logger records it, POST bodies included.
  Lower `log_max_payload_bytes` ([../configuration.md](../configuration.md)) if that matters.
- Several PHP sites: add more `cgi` entries with different `prefix`/`doc_root`/`id`.
