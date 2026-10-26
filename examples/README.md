# Examples

Each folder is a complete, runnable setup: a `vdrx.conf` plus whatever it serves. vdrx reads `vdrx.conf` from the
**current directory**, so run it from inside the folder:

```bash
cd examples/php-cgi
../../bin/vdrx          # Windows: ..\..\bin\vdrx.exe      (build first: ./build.sh or build.bat)
```

All the web examples use <http://localhost:8080/> (WebSocket: `ws://localhost:8082`), so run one at a time.
`tests/integration/run.sh` starts each of them in turn and checks it answers as its guide says.

| Folder | Shows | Needs | Guide |
|---|---|---|---|
| `static-site` | plain static files | - | [guide](../docs/guides/static-web-server.md) |
| `php-cgi` | PHP via php-cgi, rewrites, front controller | `php-cgi` | [guide](../docs/guides/php-cgi-web-server.md) |
| `python-cgi` | Python scripts as CGI | `python3` | [guide](../docs/guides/python-cgi-web-server.md) |
| `web-and-websocket` | static page + WebSocket chat | - | [guide](../docs/guides/web-and-websocket.md) |
| `websocket-only` | a WebSocket server and a ticking producer | `python3` | [guide](../docs/guides/websocket-only.md) |
| `cli-api` | `sort`, `tr`, `wc`, `head`, `grep` as HTTP APIs | those tools | [guide](../docs/guides/cli-api.md) |
| `templates` | server-side HTML templates | `python3` | [guide](../docs/guides/templates.md) |
| `jobs` | programs run on a timer, in parallel, output streamed to the console and a WebSocket | - | [jobs.md](../docs/jobs.md) |
| `legacy-cli-bridges` | the old `cli_bridges` forms | `php` | [legacy docs](../docs/legacy-cli-bridges.md) |
| `fem3d` | the author's own FEM web API setup (reference only, needs the fem3d binaries) | - | - |

The default Windows locations in a few confs (`c:/php/php-cgi.exe`) are set through `{PLATFORM}`-based variables
at the top of each file - edit them there.
