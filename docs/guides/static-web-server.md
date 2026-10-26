# Static web server

Serve a folder of files over HTTP. Example: [`examples/static-site`](../../examples/static-site).

```json
{
  "http_sites": [
    { "id": "web", "port": 8080, "static_dir": "public" }
  ]
}
```

Run `../../bin/vdrx` from the example folder and open <http://localhost:8080/>.

## What it does

- Files under `static_dir` are served as-is; the content type comes from the file extension
  (html, css, js, json, images, fonts, wasm, pdf, txt, ...; anything else is `application/octet-stream`).
- `/docs/` serves `docs/index.html`; `/docs` (no slash) redirects with a 301 so relative links in the
  page resolve correctly.
- Percent-encoded names work (`/my%20file.txt`). `..`, backslashes, `:` and dot-files (`.git`, `.env`;
  `.well-known` is allowed) are refused with 404, so a request can't leave `static_dir`.
- `HEAD` returns the headers only. Other methods on a static path are 404.
- `static_dir` is relative to the directory you start vdrx in (or absolute).

## Several sites / HTTPS / CORS

Each `http_sites` entry is an independent listener with its own port, folder and TLS settings:

```json
"http_sites": [
  { "id": "public", "port": 8080, "static_dir": "public" },
  { "id": "docs",   "port": 8081, "static_dir": "docs",
    "tls_port": 8443, "tls_cert": "cert.pem", "tls_key": "key.pem" }
]
```

HTTPS uses the system OpenSSL (`libssl-dev` on Debian/Ubuntu; on Windows point `tls_ssl_dll` /
`tls_crypto_dll` at the DLLs - see [../reference.vdrx.conf](../reference.vdrx.conf)). `"cors": true` on a site
adds permissive CORS headers to every response, for pages served from another origin.

## Not (yet) included

No gzip, no `Range` requests, no `ETag`/`Last-Modified` caching headers, one request per connection
(no keep-alive), whole files are read into memory. Put a CDN/reverse proxy in front for heavy
traffic. See [../known-gaps.md](../known-gaps.md).

To add dynamic pages on the same site, use [php-cgi](php-cgi-web-server.md) or
[python-cgi](python-cgi-web-server.md): a `cgi` entry serves static files *and* scripts from one folder.
