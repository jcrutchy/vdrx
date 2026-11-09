# Documentation

Start with [concepts.md](concepts.md) for the mental model, then pick what you need. Task-oriented walkthroughs
with a runnable folder under [`examples/`](../examples/) are in [guides/](guides/README.md).

## Section map

Section numbers (§N) are used across all the pages, in this order:

| § | Page | What it covers |
|---|---|---|
| 1 | [concepts.md](concepts.md) | The mental model: bus, topics, executives, the four ways to run code |
| 2 | [processes-and-sockets.md](processes-and-sockets.md) | Supervised `processes` |
| 3 | [processes-and-sockets.md](processes-and-sockets.md#3-outbound-tcptls---socket_clients) | Outbound TCP/TLS: `socket_clients` |
| 4 | [http.md](http.md) | HTTP: `http_sites`, `cli_bridges`, CGI (§4a), templates (§4d) |
| 5 | [websocket.md](websocket.md) | WebSocket: `executives.ws`, `ws_profiles` (§5a) |
| 6 | [configuration.md](configuration.md) | Everything else in `vdrx.conf` |
| 7 | [internals.md](internals.md) | Unit map and executive lifetime rules |
| 8 | [building.md](building.md) | Building and running |
| 9 | [known-gaps.md](known-gaps.md) | Known gaps and limitations |
| 10 | [config-viewer.md](config-viewer.md) | The config viewer, `tools/conf_viewer.html` |
| 11 | [jobs.md](jobs.md) | Scheduled jobs |
| 12 | [threat-model.md](threat-model.md) | Threat model: assets, actors, controls, review status |

Also: [legacy-cli-bridges.md](legacy-cli-bridges.md) (the older `cli_bridges` protocols), the
[full option reference](reference.vdrx.conf), [design notes](design/README.md) (background thinking, not current
behaviour) and, in the repository root, [SECURITY.md](../SECURITY.md).
