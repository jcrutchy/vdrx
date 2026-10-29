## 4f. Config conventions - what `id`, `subscribe` and `publish` mean

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

# 6. Everything else in `vdrx.conf`

- **`log_max_payload_bytes`** (default 4096) - the logger clips each bus payload to this many bytes.
- **`http_read_timeout_ms`** (default `10000`) and **`http_request_timeout_ms`** (default `30000`) - how long an HTTP client may be silent between two reads, and how long it may take to send a whole request (headers and body). A client that exceeds them is dropped (a `408` if it had sent something), so idle or dribbling connections cannot hold a `max_connections` slot. `0` turns a limit off.
- **`child_env_inherit`** (default `false`), **`child_env_passthrough`** (default `[]`), **`max_child_output_bytes`** (default `33554432`) - programs started *for a web request* (CGI programs and `cli_bridges` commands) get a clean environment: the request variables, `PATH`, `LANG`/`LC_*`, `TZ`, temp-dir variables and what Windows programs need to start, but not the daemon's own environment. Name extra variables in `child_env_passthrough` (e.g. `["DB_HOST"]`); `child_env_inherit: true` hands over everything and prints a startup warning. Each of a program's stdout and stderr is capped at `max_child_output_bytes` (`0` = unlimited): a program that writes more is killed and the request answered `502`. Jobs and `processes` are administrator-defined and still inherit.
- **`static_deny_extensions`** (default `[]`), **`static_allow_extensions`** (default `[]`), **`static_follow_symlinks`** (default `false`) - the static file server answers `404` for files whose extension is on a built-in deny list: `conf log pem key env bak sql sqlite sqlite3 db inc php phtml py pl cgi sh bat cmd ps1` (configuration, logs, keys, backups, databases, and script source that no CGI route runs). `static_deny_extensions` adds to it, `static_allow_extensions` takes entries out (e.g. `["php"]` for a site that really serves PHP source as text). A path that goes through a symbolic link is refused unless `static_follow_symlinks` is `true`, so a link inside the directory cannot lead out of it. The site's own directory may itself be a link.
- **`log_redact`** (default `true`) - mask credentials before anything is written to `vdrx_daemon.log` or the console: JSON members named `Authorization`, `Cookie`, `Set-Cookie`, `token`, `_edge_token`, `password`, `api_key`, `secret` and similar; `api_key=` / `token=` / `password=` / `session=` / `sig=` style parameters in query strings and forms; and `Bearer` / `Basic` credentials. The member name stays, the value becomes `[REDACTED]`. It is a safety net, not a guarantee - a secret in a member with some other name is not recognised, so keep secrets out of topics you log. Setting it to `false` prints a startup warning.
- **`log_redact_bodies`** (default `true`) - also replace the `body` / `body_b64` of HTTP request and reply envelopes with `[body redacted]`. Turn it off only when you need to debug payloads, and not on a shared machine.

  Bus messages are clipped to `log_max_payload_bytes` *before* masking, so a secret beyond the clip point is never even seen. The JSONL buckets (`buckets`) record exactly the topics you configure and are **not** masked - don't bucket topics that carry credentials.
- **`log_console_exclude`**, **`log_file_exclude`** (arrays of topic filters, default none) - messages matching a filter (`*` = one segment, `>` = the rest) are not printed to the console / not written to `vdrx_daemon.log`. Use them to keep a chatty topic family, such as job output (§11), out of the daemon log.
- **`jobs`** and **`executives.jobs`** - scheduled programs whose output streams onto the bus: see [jobs.md](jobs.md) (§11).

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
*Section numbers (§N) are shared across all vdrx docs - see the [section map](README.md#section-map).*
