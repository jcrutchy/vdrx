# VDRX documentation

**New here?** Start with [concepts.md](concepts.md) (ten minutes: what the bus, executives and topics are), then
pick a task from the [guides](guides/README.md). Each guide has a runnable example under [`../examples/`](../examples/).

## Reference

| Page | Covers |
|---|---|
| [concepts.md](concepts.md) | the mental model: executives, topics and filters, the ways to reach a program |
| [processes-and-sockets.md](processes-and-sockets.md) | supervised processes (`processes`), outbound TCP/TLS (`socket_clients`) |
| [http.md](http.md) | `http_sites`, the CGI executive (`cgi`), `runners` + `http_routes`, templates, `rewrites` |
| [websocket.md](websocket.md) | the WebSocket server and `ws_profiles` |
| [configuration.md](configuration.md) | config conventions (`id`/`subscribe`/`publish`), variables, includes, every other key |
| [reference.vdrx.conf](reference.vdrx.conf) | one config showing *every* option with a `_description` for each |
| [legacy-cli-bridges.md](legacy-cli-bridges.md) | the older `cli_bridges` spellings (still supported) |
| [config-viewer.md](config-viewer.md) | `tools/conf_viewer.html`: draw a conf as a bus diagram, watch it live |
| [building.md](building.md) · [internals.md](internals.md) · [known-gaps.md](known-gaps.md) | building and running · the Pascal unit map · what isn't done yet |
| [design/](design/) | design notes and ideas (not documentation of current behaviour) |

## Section map

The reference pages keep one numbering (`§N`) so cross-references stay short:

| § | Topic | Page |
|---|---|---|
| 1 | Mental model | [concepts.md](concepts.md) |
| 2, 3 | Processes, socket clients | [processes-and-sockets.md](processes-and-sockets.md) |
| 4, 4a, 4d, 4e, 4g | HTTP sites, CGI executive, templates, runners + http_routes, rewrites | [http.md](http.md) |
| 4a-legacy, 4b, 4c | `cli_bridges` forms | [legacy-cli-bridges.md](legacy-cli-bridges.md) |
| 4f, 6 | Config conventions, everything else in `vdrx.conf` | [configuration.md](configuration.md) |
| 5, 5a | WebSocket, `ws_profiles` | [websocket.md](websocket.md) |
| 7 | Unit map | [internals.md](internals.md) |
| 8 | Building and running | [building.md](building.md) |
| 9 | Known gaps | [known-gaps.md](known-gaps.md) |
| 10 | Config viewer | [config-viewer.md](config-viewer.md) |
