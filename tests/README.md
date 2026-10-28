# Tests

```bash
tests/run.sh          # build everything, run the unit test, then the integration tests
```

| Folder | What | How to run |
|---|---|---|
| `unit/` | `test_jsonconf` - the JSON config loader (includes, variables, reload); `test_redact` - log credential masking | `bin/test_jsonconf`, `bin/test_redact` (built by `./build.sh tests`) |
| `integration/` | starts the real daemon on each `examples/` folder and on the fixtures `integration/cgi` and `integration/ws`, then checks responses over HTTP/WebSocket | `tests/integration/run.sh [section ...]` |
| `stress/` | load/soak driver for HTTP, WebSocket and process churn (`vdrx_stress`) | build with `./build.sh tests`, copy `vdrx_stress.conf.example` and edit, run `bin/vdrx_stress` |
| `manual/` | `test_stall`, `test_socket_stall`: timeline demos for hung child processes / non-reading peers (they write a `.log` to read, no pass/fail) | `bin/test_stall`, `bin/test_socket_stall` |

**Integration tests** need `curl` and `python3`; sections that need `php-cgi`, `php` or Unix tools skip themselves
if those aren't on `PATH`. They use ports 8080, 8082, 18080, 18082 and refuse to start if one is taken. They only
ever stop the daemon they started.

Windows: the scripts are plain `sh`; they should work from Git Bash if `curl` and `python3` are on `PATH` (they look for
`bin/vdrx.exe` too), but only Linux has been tried - WSL is the safe choice.
