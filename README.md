# VDRX

VDRX is a small daemon that does two things and stays out of the way of everything else: it runs a
**pub/sub message bus** that anything inside it can publish to or subscribe from, and it **supervises
external processes** (spawn, restart-on-crash, graceful shutdown). Everything else you can build with it -
a web server, PHP/Python CGI, WebSocket, command-line tools as APIs, an IRC bridge, a game server - is just
something talking to that bus, not a special case baked into the core.

No external Pascal dependencies - vanilla Free Pascal plus the OS's own OpenSSL for TLS. A single daemon
binary configured by one JSON file (`vdrx.conf`, with includes and variables).

## Quick start

```bash
./build.sh                       # Windows: build.bat, or open src/vdrx.lpi in Lazarus   -> bin/vdrx
cd examples/static-site          # every example is a folder with its own vdrx.conf
../../bin/vdrx                   # vdrx reads vdrx.conf from the CURRENT directory
# browse to http://localhost:8080/
```

## What can I do with it?

| | Guide | Run it |
|---|---|---|
| Static web server | [docs/guides/static-web-server.md](docs/guides/static-web-server.md) | `examples/static-site` |
| PHP web server (php-cgi, rewrites, front controller) | [docs/guides/php-cgi-web-server.md](docs/guides/php-cgi-web-server.md) | `examples/php-cgi` |
| Python / Perl / any CGI | [docs/guides/python-cgi-web-server.md](docs/guides/python-cgi-web-server.md) | `examples/python-cgi` |
| Web pages + WebSocket together | [docs/guides/web-and-websocket.md](docs/guides/web-and-websocket.md) | `examples/web-and-websocket` |
| WebSocket server on its own port | [docs/guides/websocket-only.md](docs/guides/websocket-only.md) | `examples/websocket-only` |
| Command-line programs as HTTP APIs | [docs/guides/cli-api.md](docs/guides/cli-api.md) | `examples/cli-api` |
| HTML templates rendered from data | [docs/guides/templates.md](docs/guides/templates.md) | `examples/templates` |

## Repository layout

```
src/        the daemon (Pascal): vdrx.lpr / vdrx.lpi and every unit
docs/       documentation - start at docs/README.md
examples/   one runnable folder per guide (+ legacy-cli-bridges, fem3d)
tests/      unit/ integration/ stress/ manual/   -> tests/README.md   (run all: tests/run.sh)
tools/      conf_viewer.html (live bus diagram), confserver.php, snapshot scripts
build.sh / build.bat      build bin/vdrx with fpc            (bin/ and build/ are git-ignored)
```

Documentation index and the full reference: [docs/README.md](docs/README.md).
