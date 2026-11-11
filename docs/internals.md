# 7. Unit map

All Pascal source lives in `src/`.

| Unit | What's in it |
|---|---|
| `vdrx_core.pas` | `TVDRX_Kernel`, `TVDRX_MessageQueue`, `TVDRX_Registry`, `TVDRX_Executive` - the bus itself, zero protocol knowledge |
| `jsonconf.pas` | Generic, dependency-free JSON config loader: recursive `includes`, `{VARIABLES}`, environment expansion, safe reload (§6). Reusable by any project |
| `vdrx_config.pas` | Thin `TVDRX_Config` subclass of `TJsonConf` that adds the `VDRX_*` reserved variables |
| `vdrx_admin.pas` | `sys.>` admin commands (`sys.reload`/`sys.quit`/`sys.kill`/...) |
| `vdrx_stdin.pas` | Console command reader, feeds `vdrx_admin` (a console line is capped at 4096 bytes) |
| `vdrx_linebuf.pas` | `TVDRX_LineBuffer` - splits a byte stream into lines with a hard limit on the unfinished line; used by `socket_clients`, supervised-process stdout and the stdin console (`max_line_bytes`) |
| `vdrx_logger.pas` | Everything on the bus → colored console + `vdrx_daemon.log`, written from its own thread; long payloads are clipped (`log_max_payload_bytes`, default 4096) and then credential-masked (`vdrx_redact.pas`, `log_redact`); `log_console_exclude` / `log_file_exclude` topic filters; `ConsoleWrite`, the locked console writer shared with the job console |
| `vdrx_procutil.pas` | Cross-platform process wait/terminate/kill helpers |
| `vdrx_bridge.pas` | `TVDRX_BridgeExecutive` - supervised external processes (§2) |
| `vdrx_bucket.pas` | Append-only JSONL topic recorder (§6) |
| `vdrx_templates.pas` | Template engine (`$$setting$$`/`??const??`/`%%var%%`/`##loop##`/`@@child@@`) and `TVDRX_TemplateExecutive`, the bus-reachable wrapper around it (§4d) |
| `vdrx_transport.pas` | `TVDRX_Transport` / plain / TLS transports and TLS contexts, outbound `ConnectTCP*`, socket options, OpenSSL discovery |
| `vdrx_httpparse.pas` | HTTP request parsing and path safety (request line, headers, URL paths, `ReadFullRequest`), route / rewrite records and matching, static-file deny policy, HTTP timeouts - no daemon state, the main target for fuzzing and review |
| `vdrx_connection.pas` | Base classes for socket-owning executives: `TVDRX_ConnectionExecutive` (send queue) and `TVDRX_SocketListenerExecutive` (accept loop, connection limit) |
| `vdrx_websocket.pas` | `TVDRX_WebSocketExecutive` + `TVDRX_WSConnection`/`TVDRX_WSProtocolExecutive` (§5): RFC 6455 framing, ws_profiles auth and topic rules (`TopicFilterCovers`), failed-login lockout |
| `vdrx_httproute.pas` | HTTP request handling above the parser: static files, reverse proxy, CGI/bus route resolution, request envelopes, `TVDRX_OneShotWaiter`/`PublishAndWait` (the bus-daemon/template-topic reply-correlation primitive), `GVDRXEdgeToken` |
| `vdrx_http.pas` | `TVDRX_HTTPExecutive` + `TVDRX_HTTPConnection` (§4); hands WebSocket upgrades on a shared port to `vdrx_websocket` |
| `vdrx_socketclient.pas` | `TVDRX_SocketClientExecutive` (§3): outbound dialer, optional TLS, line splitting under `max_line_bytes`, reconnect backoff |
| `vdrx_runner.pas` | `TVDRX_RunnerExecutive`: runs a CLI program per bus message, publishes the output (§4e); also the worker-pool base class of the CGI executive, and (envelope mode) the legacy `bus` cli_bridge |
| `vdrx_jobs.pas` | `TVDRX_JobTable` (definitions + run state), `TVDRX_SchedulerExecutive` (publishes `sched.<id>`), `TVDRX_JobRunnerExecutive` + `TVDRX_JobRun` (one thread per run, line-by-line output onto the bus), `TVDRX_JobConsoleExecutive` (coloured `job.>` console) (§11) |
| `vdrx_cgi.pas` | `TVDRX_CGIExecutive`: RFC 3875 adaptor - request envelope in, CGI program run, reply envelope out (§4a) |
| `vdrx.lpr` (+ `vdrx.lpi`) | Entry point - reads `vdrx.conf`, wires every executive above up from it |

---
*Section numbers (§N) are shared across all vdrx docs - see the [section map](README.md#section-map).*

## Executive lifetime (read before adding or changing an executive)

An executive is shared between threads: the kernel's dispatcher takes a snapshot of the matching subscribers for every
message and calls each one's `HandlePacket`, while the executive's own threads may be unregistering it at the same moment.
So executives are **reference counted** (`AddRef` / `Release` / `RetireRegistryRef` in `vdrx_core.pas`):

- The registry holds one reference. The dispatcher adds one per subscriber in its snapshot and releases it after delivery.
- Anything that removes an executive from the registry must take it out of the tables first and then call
  `RetireRegistryRef`; only when that returns true (nobody else holds a reference) does the caller `Free` it. Both
  `Registry.Unregister` and `Registry.UnregisterSelf` follow this. Never free an executive straight out of the registry's
  owning map (`FMasterMap.Remove` would): the dispatcher may still be about to call into it.
- A thread that finishes an executive's life (a connection thread calling `UnregisterSelf` as its last act) must not touch the
  object afterwards, because the dispatcher may free it a moment later.
