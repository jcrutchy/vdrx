# 7. Unit map

All Pascal source lives in `src/`.

| Unit | What's in it |
|---|---|
| `vdrx_core.pas` | `TVDRX_Kernel`, `TVDRX_MessageQueue`, `TVDRX_Registry`, `TVDRX_Executive` - the bus itself, zero protocol knowledge |
| `jsonconf.pas` | Generic, dependency-free JSON config loader: recursive `includes`, `{VARIABLES}`, environment expansion, safe reload (§6). Reusable by any project |
| `vdrx_config.pas` | Thin `TVDRX_Config` subclass of `TJsonConf` that adds the `VDRX_*` reserved variables |
| `vdrx_admin.pas` | `sys.>` admin commands (`sys.reload`/`sys.quit`/`sys.kill`/...) |
| `vdrx_stdin.pas` | Console command reader, feeds `vdrx_admin` |
| `vdrx_logger.pas` | Everything on the bus → colored console + `vdrx_daemon.log`, written from its own thread; long payloads are clipped (`log_max_payload_bytes`, default 4096) |
| `vdrx_procutil.pas` | Cross-platform process wait/terminate/kill helpers |
| `vdrx_bridge.pas` | `TVDRX_BridgeExecutive` - supervised external processes (§2) |
| `vdrx_bucket.pas` | Append-only JSONL topic recorder (§6) |
| `vdrx_templates.pas` | Template engine (`$$setting$$`/`??const??`/`%%var%%`/`##loop##`/`@@child@@`) and `TVDRX_TemplateExecutive`, the bus-reachable wrapper around it (§4d) |
| `vdrx_network.pas` | Everything socket-facing: TLS/plain transport, the listener base class, `TVDRX_HTTPExecutive` (§4) including `TVDRX_OneShotWaiter`/`PublishAndWait` (the bus-daemon/template-topic reply-correlation primitive), `TVDRX_WebSocketExecutive` + `TVDRX_WSConnection`/`TVDRX_WSProtocolExecutive` (§5), `TVDRX_SocketClientExecutive` (§3) |
| `vdrx_runner.pas` | `TVDRX_RunnerExecutive`: runs a CLI program per bus message, publishes the output (§4e); also the worker-pool base class of the CGI executive, and (envelope mode) the legacy `bus` cli_bridge |
| `vdrx_cgi.pas` | `TVDRX_CGIExecutive`: RFC 3875 adaptor - request envelope in, CGI program run, reply envelope out (§4a) |
| `vdrx.lpr` (+ `vdrx.lpi`) | Entry point - reads `vdrx.conf`, wires every executive above up from it |

---
*Section numbers (§N) are shared across all vdrx docs - see the [section map](README.md#section-map).*
