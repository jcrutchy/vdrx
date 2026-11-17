# 12. Threat model

This page is for whoever has to decide whether vdrx is safe to run: a security reviewer, a red/blue team,
corporate IT. It says what vdrx is meant to defend, against whom, where it does that, how each control is
tested, and - just as important - what it does **not** defend and what has **not yet been looked at**.

It describes the code at the commit it ships with. It is a design review backed by tests, not a penetration
test report, and it is not a guarantee. Operating advice is in [SECURITY.md](../SECURITY.md); the list of
known weaknesses is [known-gaps.md](known-gaps.md).

## 1. What vdrx is, in security terms

vdrx is one daemon that does several jobs at once: an in-process publish/subscribe **bus**; **listeners**
(HTTP, HTTPS, WebSocket, optionally sharing a port) that turn network traffic into bus messages; **executives**
(template renderer, runner, CGI adaptor, bridges, scheduler for jobs) that react to bus messages; and a
**supervisor** that starts and watches child programs. Anything a client can do, it does by causing messages on
the bus, so the bus's rules (who may publish and subscribe to which topic) are the core security boundary.

```
                      untrusted                       |            trusted (operator-configured)
  browser / script ---HTTP/HTTPS/WS--> [ listeners ]--+--> [ bus ] --> [ executives ] --> [ child programs ]
   (network client)     (B1)           ws_profiles    |   (B2)          template, runner,    CGI, cli_bridges,
                                       gate (B2)      |                 cgi, bridge, jobs    jobs, processes (B3)
                                                      |
   vdrx.conf, doc roots, templates, logs  ------------+------ read at start-up from the file system (B4)
   outbound peers (socket_clients, reverse-proxy backends) -------------------------------------- (B5)
```

## 2. Assumptions (if one of these is false, so is the rest of this page)

1. **Internal network only.** Not exposed to the internet. A hardened reverse proxy goes in front if it ever must be.
2. **The operator is trusted.** Whoever writes `vdrx.conf`, the scripts it runs, the templates and the doc roots
   is not an adversary. vdrx protects the operator's setup from *clients*, not from the operator.
3. **Runs as an unprivileged account** that can read only what it serves (it warns when started as root).
4. **The host is not already compromised.** An attacker with the daemon's OS account, or with root, wins; vdrx does
   not try to stop that.
5. **Every `ws_profiles` entry that matters has a long random token.** A profile without one is open to anyone who names it.

## 3. Assets

| Asset | Why it matters |
|---|---|
| The daemon's availability | Other services (IRC bridge, dashboards, jobs) ride on the bus. |
| Control of the bus | Whoever can publish to `sys.>` can stop or kill things; whoever can publish to a request topic acts through that executive. |
| Data on the bus | Topics can carry request bodies, session cookies, job output, anything a profile subscribes to. |
| Files on the host | Config (tokens), keys, logs, source of served scripts, anything the daemon's account can read. |
| The ability to run programs | Child programs run with the daemon's own rights (they are **not** sandboxed). |
| The log | Can contain credentials if redaction misses a pattern. |

## 3a. Who attacks, and with what

| Actor | Starts with | Realistic goals |
|---|---|---|
| Unauthenticated network client | Can reach a listener | Crash or stall the daemon; read files; run something; reach `sys.>` |
| WebSocket client with a low-privilege profile (e.g. a read-only dashboard) | A valid token for a weak profile | Read topics it should not see; publish where it should not; escalate to a stronger profile or to admin control |
| A script/page in a victim's browser | Victim is on the internal network | Use the victim's reach to talk to vdrx (cross-site WebSocket, DNS rebinding) |
| A buggy or compromised child program | Its stdout/stderr, its own files | Flood the bus, wedge the dispatcher, forge messages |
| A hostile or broken remote peer | An IRC server or a proxied backend | Send huge, malformed or non-UTF-8 data |
| A local, non-admin OS user | Shell on the same machine | Read config, tokens, logs |

## 4. Threats, controls and what is left

Status: **Mitigated** (a control exists and a test exercises it), **Partly** (a control exists, a gap is named), **Open** (accepted or not yet addressed).
"Test" names the suite in `tests/`.

### 4.1 Availability - exhausting the daemon

| Threat | Control | Status | Test |
|---|---|---|---|
| Many connections | `max_connections` per listener (default 256); WebSocket cap shared across ports | Partly: a client that keeps reconnecting can still hold every slot (see known-gaps) | `limits`, `ws-shared` |
| Slow-reading request (slowloris) | `http_read_timeout_ms`, `http_request_timeout_ms`; headers capped at 16 KiB, body at 10 MiB (413) | Mitigated | `limits` |
| Client that **stops reading** a response | `http_write_timeout_ms`, `http_response_timeout_ms`; static files over 1 MiB are streamed in 64 KiB chunks, so a stalled client costs one chunk, not the file | Mitigated | `limits` (12 MB file, 30 non-readers, memory bounded) |
| WebSocket client that stops reading, or floods | `write_timeout_ms` evicts it; bounded per-connection queue (`max_queue`, oldest dropped); `max_frame_bytes` (1 MiB); `frame_timeout_ms` | Mitigated | `limits`, `ws` |
| TLS handshake that never finishes | Handshake timeout; stalled handshakes do not delay real clients | Mitigated | `limits` |
| A wedged child or socket peer blocks the whole bus | Bridge and socket-client writes go through their own send thread, never the dispatcher; a stalled send queue force-restarts the child; write timeouts and keep-alive on sockets; the dispatcher logs any handler slower than 250 ms | Mitigated | `tests/manual/test_stall`, `test_socket_stall` (**not** run automatically) |
| A write to a closed pipe/socket kills the process | `SIGPIPE` is ignored | Mitigated | `test_socket_stall` |
| Runaway program output | `max_child_output_bytes` (default 32 MiB): the program is killed and the request answered 502 | Mitigated | `spawn` |
| Memory growth from leaks | Leak check in the fuzz suite | Partly | `fuzz` |
| Crash from a use-after-free when connections end while messages are in flight | Executives are reference counted; a connection leaving the registry waits for the dispatcher to finish with it (`UnregisterSelf` and `Unregister` follow the same rule - see [internals.md](internals.md)) | Mitigated *(a real crash, found and fixed in hardening 9)* | `limits` (repeated runs before and after the fix) |
| Slow shutdown | Documented | Open | - |

### 4.1a HTTP framing and the reverse proxy

| Threat | Control | Status | Test |
|---|---|---|---|
| **Request smuggling to an upstream:** a second request pipelined behind a legitimate one reaches a backend vdrx never meant to expose | The buffer is cut to `head + Content-Length`; everything after is discarded; every connection serves one request and closes *(found and fixed in hardening 9: the extra bytes were forwarded)* | Mitigated | `proxy` |
| vdrx and a backend (or a proxy in front) disagreeing on where a request ends | Heads with bare CR/LF, control characters, obsolete line folding, whitespace before the colon, non-token header names, repeated or non-decimal `Content-Length` (FPC would read `$10` and `0x10` as 16) or any `Transfer-Encoding` are refused 400/501 *(hardening 9)* | Mitigated | `proxy`, `limits` |
| A malformed request forwarded on Linux | The forwarded head is rebuilt with explicit CRLF *(the old code used the platform line ending, so on Linux every proxied request had bare LFs, which strict upstreams refuse and lenient ones parse differently)* | Mitigated | `proxy` |
| A route prefix capturing look-alike paths (`/api` also taking `/api-admin`) | A prefix without a trailing slash matches only itself, `/x` and `?x` | Mitigated | `proxy` |
| A hostile or broken upstream: endless or huge response, or going silent | Response capped at 64 MiB (502) and by `http_response_timeout_ms` (504); a 30 s idle read limit; the buffer grows geometrically *(it was quadratic: a 60 MB reply took minutes)* | Mitigated | `proxy` |
| Client-supplied `X-Forwarded-For` / `X-Real-IP` believed by an upstream | Passed through unchanged; vdrx adds none | Open: the upstream must not trust them (see known-gaps) | - |
| Upstream traffic read or altered on the wire | Plain TCP to the upstream | Open by design: keep upstreams on `127.0.0.1` or a trusted segment | - |

### 4.2 Authentication and the privilege boundary on the bus

| Threat | Control | Status | Test |
|---|---|---|---|
| Guessing a token | 8 failed `sys.auth` per address per minute, then a one-minute lockout; constant-time comparison; with no profiles all logins are refused unless `allow_open_access` is set | Mitigated for the config file (tokens can be stored as `token_hash`, and can expire); still partly open: a long random token is the only credential, there are no per-client credentials, and behind a proxy all clients share one address | `ws`, `ws-open`, `ws-lockout`, `ws-tokens` |
| A weaker profile keeps a stronger profile's access after re-authenticating, or after a failed attempt | A second `sys.auth` first drops the session and **all** subscriptions, then judges the new token (fail-closed) | Mitigated *(found and fixed in hardening 9)* | `regress` |
| A client names a profile that has no token | Anyone may use it - by design | Open: give every profile that matters a token | - |
| Publishing to topics a profile should not reach | `publish_allow` (deny by default) and `subscribe_allow` per profile; `sys.>` publishes are denied to clients | Mitigated | `ws` |
| **Confused deputy:** a client makes a privileged executive publish for it (`reply_to: "sys.quit"` on a template request) | A request's `reply_to` is refused for `sys.>` / `kernel.>`, and, for a profile client, must match its own `publish_allow` (template, runner and CGI executives) | Mitigated for WebSocket requesters *(found and fixed in hardening 9)* | `regress` |
| The same trick through an executive that is not yet checked | Only the template, runner and CGI executives take a caller-supplied reply topic today. **Any new executive that does must call `VDRX_ReplyAllowed`** | Partly (a rule for developers, not enforced by the compiler) | - |
| A message on `sys.>` from something that should not control the daemon (a process or socket peer granted `sys.>` publish rights, a future executive that forgets `VDRX_ReplyAllowed`) | The admin executive obeys quit/restart/reload/kill/killall/list/history only from `admin_sources` (default: the stdin console); anything else is dropped and logged. Clients still cannot publish there and executives still refuse it as a reply target | Mitigated | `admin-source` |
| Cross-site WebSocket from a victim's browser | `Origin` must match `Host` (or be in `allowed_origins`) | Partly: **not** a defence against DNS rebinding - tokens are | `ws-shared` |
| Subscribing to everything in dev mode | `allow_open_access` (dev only, off by default) | Open by design | `ws-open` |

### 4.3 Reading files that should not be served

| Threat | Control | Status | Test |
|---|---|---|---|
| `..`, encoded `..`, backslashes, NUL, `:` (NTFS alternate data streams) in a URL path | Path is percent-decoded once and split segment by segment; any of these refuses the whole request (403) | Mitigated | `spawn`, unit |
| Dot-files (`.git`, `.env`) and, on Windows, their **8.3 aliases** (`GIT~1`) | Refused (`.well-known` allowed); aliases refused outright *(hardening 9)* | Mitigated | unit |
| Windows device names (`con`, `nul`, `com1`...) | Refused on every platform *(hardening 9)* | Mitigated | unit |
| Trailing dot/space (`x.php.` serving script source on Windows) | Refused | Mitigated | unit |
| Config, key, log, backup and script-source files in a served folder | Static server refuses them by extension (`static_deny_extensions`) | Mitigated | `spawn` |
| Symbolic links out of the doc root | Static files: not followed by default. **CGI scripts: followed** | Partly (see known-gaps) | `spawn` |
| Template names that leave the template directory (`../secret`) | A name must be a plain file name: letters, digits, `_ - .`, no leading dot, no `..`, no separators, 128 chars at most *(found and fixed in hardening 9)* | Mitigated | `regress` |

### 4.4 Running things on a client's behalf (injection)

| Threat | Control | Status | Test |
|---|---|---|---|
| Shell injection | Programs start from an executable plus an argument **vector**; no shell is ever involved | Mitigated | code review, `spawn` |
| A request value turning into extra arguments or an option flag | Placeholders expand in a single pass (no re-expansion); a whole-token placeholder may not start with `-`; length cap; control characters refused | Mitigated | `spawn`, unit |
| `cmd.exe` re-parsing a `.bat`/`.cmd` command line | Values containing `& \| < > ^ % " ( ) !` or a line break are refused for batch programs | Partly: unit-tested, **never run on Windows**; prefer a real executable | unit |
| CGI environment injection (a NUL, CR or LF in a header, query, path or port starting another variable) | Every value is flattened; header names are validated, not silently mangled *(ports added in hardening 9)* | Mitigated | unit |
| `httpoxy` | A `Proxy` request header never becomes `HTTP_PROXY` | Mitigated | unit |
| Daemon secrets leaking into child programs | Children get a clean environment; names must be listed in `child_env_passthrough` | Mitigated | `spawn` |
| A client chooses what a job runs | `jobs.run` / `jobs.kill` take only a job **name**; the program and its arguments come from `vdrx.conf`. An unknown name is ignored and logged (escaped). Who may send them is `publish_allow` | Mitigated | `jobs` |
| A configured program doing damage | Programs are **not sandboxed**: they run with the daemon's rights. A timeout kills the process, not what it spawned | Open (accepted: the operator chose the program) | - |

### 4.5 Confidentiality of data

| Threat | Control | Status |
|---|---|---|
| Credentials in the log | `log_redact` and `log_redact_bodies` (on by default) mask cookies, `Authorization`, tokens, passwords and bodies by pattern | Partly: pattern based; a secret in an unknown field or a job's own output is logged. Buckets are never masked |
| Reading another profile's topics | `subscribe_allow` per profile | Mitigated |
| Impersonating a server vdrx dials out to (`socket_clients` over TLS) | The certificate must chain to a trusted CA **and** be valid for the dialled host name or `tls_peer_name`; refused otherwise, and refused if libcrypto cannot check names *(a real hole - any certificate from the same CA was accepted - found and fixed in hardening 9)* | Mitigated | `tls-client` |
| A client forges log lines or drives the operator's terminal through a logged value | CR, LF, ESC and other control characters are escaped in every logged topic and payload, after redaction *(found and fixed in hardening 9)* | Mitigated | unit, `regress` |
| Traffic sniffing / downgrade | TLS on HTTP and WebSocket with an explicit policy: TLS 1.2+ (configurable to 1.3), ECDHE + AEAD ciphers only, compression, renegotiation and session tickets off; a TLS port whose policy cannot be enforced does not start | Mitigated on Linux/OpenSSL 3 (`tls-policy`); TLS on Windows is untested |
| Another local user reading config/logs | Not enforced by vdrx | Open: file permissions are the operator's job |

### 4.6 Script injection in the browser tools

| Threat | Control | Status | Test |
|---|---|---|---|
| Topic names, payloads or job output rendered as markup in `conf_viewer.html` / `jobs_terminal.html` | Live data is written with `textContent` or escaped (`& < > " '`) before it reaches `innerHTML`; attributes only ever receive numbers and computed colours | Mitigated (code review of every `innerHTML` use) | `jobs` (browser test: job output "shown as text, never as HTML"); the config viewer has **no** automated test |

### 4.7 Supply chain and the "CVE scanner" question

vdrx has **no third-party code**: no framework, no package manager, no vendored libraries. It is Free Pascal's
standard run-time plus the project's own units. At run time the only external component is **OpenSSL**, loaded
dynamically when TLS is configured. So a vulnerability scan of the repo finds little to report; what a scanner
*will* look at is the OpenSSL build you ship or install, the Free Pascal compiler/RTL used to build the binary,
and the interpreters (PHP, Python...) that CGI routes launch. Those are patched by you, not by vdrx.

## 5. What vdrx does not defend (and says so)

- **Internet exposure.** Not designed or tested for it.
- **A malicious operator or a malicious configured program** (see assumptions 2 and 4).
- **DNS rebinding,** unless every important profile has a token.
- **Resource exhaustion by an authenticated client with a valid profile** beyond the per-connection queue, frame and rate limits listed above.
- **Per-topic access control beyond `ws_profiles`.** More things are reachable by knowing a topic name than in a system with ACLs.
- **Traffic analysis, timing side channels,** and anything below the application layer (kernel, NIC, hypervisor).

## 6. Review status - how far has this actually been looked at?

Reviewed so far (code read plus tests; findings in the "found and fixed" rows above):

- WebSocket listener, authentication, profiles, re-authentication, queues and write timeouts
- HTTP listener limits, static file serving, URL path handling
- Registry and dispatcher lifetime rules; the template executive; the runner (argument expansion, batch guard); the CGI adaptor (environment, script resolution)
- The jobs executive's client-facing side (what a client can influence); the logger; outbound TLS in `socket_clients`
- php-cgi option injection: when the CGI program is a PHP interpreter, a query string with no literal `=` that starts with `-`, `%2d` or contains a soft hyphen (`%AD` / `0xAD`) or `+-` is refused with 400 (CVE-2012-1823 / CVE-2024-4577 class; `CGIQueryLooksLikeOptions`). Still keep PHP current: this is a second layer, not a replacement for patching
- `ws_profiles` allow rules: `TopicFilterCovers` is checked exhaustively against the bus matcher over 24,025 pattern pairs (`tests/unit/test_topiccover.lpr`) and never grants more than the allow pattern; it over-denies a few shapes such as allow `a.>` for filter `a`, which is the safe direction
- Line-length bounds on every newline-delimited reader: `socket_clients` and supervised-process stdout (`max_line_bytes`, default 1 MiB; an over-long line is dropped, and a socket peer that sends one is disconnected) and the stdin admin console (4096 bytes); `jobs` already split long output lines. Tests: `tests/unit/test_linebuf.lpr`, integration section `line-limits`
- The HTTP request reader and the reverse-proxy routes (framing, forwarding, prefix matching, response bounds)
- `tools/conf_viewer.html` and `tools/jobs_terminal.html` (every `innerHTML` use)

**Not yet reviewed - treat as unassessed, not as safe:**

- The legacy `cli_bridges` protocols (`vdrx_bridge.pas`) and the way jobs spawn and stop their processes
- Whether `chunk` framing in `socket_clients` (bounded by `chunk_size`, but each chunk is published as one bus message) needs its own rate limit
- The bucket recorder (`vdrx_bucket.pas`): file path handling and rotation under failure
- Anything on Windows beyond unit tests (the TLS path and the batch-file guard in particular)
- The stress and manual stall suites on the latest code

## 7. Recommended next steps, in order

1. Finish the review list above, starting with the bucket recorder and the legacy `cli_bridges` protocols.
2. ~~Give the admin executive a source check~~ (done: `admin_sources`).
3. ~~Hash tokens at rest and add an optional expiry~~ (done: `token_hash`, `token_expires`); per-client credentials remain open.
4. ~~Set a minimum TLS version and cipher policy explicitly~~ (done); test TLS on Windows; warn before certificate expiry.
5. Offer an optional sandbox wrapper for child programs (a separate account, a job object on Windows, a container).
6. Run the regression suite in CI on every commit, with the stress and stall tests nightly.

## 8. How this is kept honest

Every row marked *Mitigated* has an automated test that fails if the control is removed, run by
`tests/run.sh`: unit tests (`tests/unit`), integration suites (`tests/integration`: `limits`, `ws`, `regress`,
`spawn`, `fuzz` and others), and `tests/integration/regress/regress_test.py`, which holds one test per
vulnerability found during review, so a fixed finding cannot silently return.

---
*Section numbers (§N) are shared across all vdrx docs - see the [section map](README.md#section-map).*
