# Guides

Task-oriented walkthroughs. Each one has a runnable folder under [`examples/`](../../examples/) -
**run vdrx from inside that folder** (it reads `vdrx.conf` from the current directory):

```bash
./build.sh                      # once, from the repo root -> bin/vdrx
cd examples/php-cgi
../../bin/vdrx                  # Windows: ..\..\bin\vdrx.exe
```

| I want to... | Guide | Example |
|---|---|---|
| serve static files | [static-web-server.md](static-web-server.md) | `examples/static-site` |
| run PHP like Apache + mod_php/php-cgi | [php-cgi-web-server.md](php-cgi-web-server.md) | `examples/php-cgi` |
| run Python (or Perl, shell, any CGI program) | [python-cgi-web-server.md](python-cgi-web-server.md) | `examples/python-cgi` |
| serve web pages and WebSocket together | [web-and-websocket.md](web-and-websocket.md) | `examples/web-and-websocket` |
| run a WebSocket server on its own port | [websocket-only.md](websocket-only.md) | `examples/websocket-only` |
| expose command-line programs as HTTP APIs | [cli-api.md](cli-api.md) | `examples/cli-api` |
| render HTML from data with templates | [templates.md](templates.md) | `examples/templates` |

Every example is exercised by `tests/integration/run.sh`, so these pages describe what the code
actually does. For the full list of options see [../configuration.md](../configuration.md) and
[../reference.vdrx.conf](../reference.vdrx.conf).
