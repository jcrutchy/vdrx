# Tests

```bash
tests/run.sh          # build everything, run the unit test, then the integration tests
```

| Folder | What | How to run |
|---|---|---|
| `unit/` | `test_jsonconf` - the JSON config loader (includes, variables, reload); `test_redact` - log credential masking; `test_spawn` - child environment, NUL handling, batch-file rule, static deny list; `test_registry` - subscription table cleanup and cost | `bin/test_jsonconf`, `bin/test_redact` (built by `./build.sh tests`) |
| `integration/` | starts the real daemon on each `examples/` folder and on the fixtures `integration/cgi` and `integration/ws`, then checks responses over HTTP/WebSocket | `tests/integration/run.sh [section ...]` |
| `fuzz/` | a seeded, mutation-based fuzzer for the HTTP and WebSocket front ends (`fuzz.py`) with resource oracles - process alive, canary still works, threads and memory do not drift, responses well-formed, no pipelined/smuggled second response, no data before login, no header injection, no exception in the log - plus `leakcheck.py` (memory growth per request) and `leakhunt.py` (which traffic class leaks). Needs a running daemon started in `tests/fuzz` | `tests/integration/run.sh fuzz` (20 s smoke, `FUZZ_SECONDS=600` for longer); by hand: `cd tests/fuzz && ../../bin/vdrx &` then `python3 fuzz.py --seed 5 --seconds 300` |
| `stress/` | load/soak driver for HTTP, WebSocket and process churn (`vdrx_stress`) | build with `./build.sh tests`, copy `vdrx_stress.conf.example` and edit, run `bin/vdrx_stress` |
| `manual/` | `test_stall`, `test_socket_stall`: timeline demos for hung child processes / non-reading peers (they write a `.log` to read, no pass/fail) | `bin/test_stall`, `bin/test_socket_stall` |

**Integration tests** need `curl` and `python3`; sections that need `php-cgi`, `php` or Unix tools skip themselves
if those aren't on `PATH`. They use ports 8080, 8082, 18080, 18082 and refuse to start if one is taken. They only
ever stop the daemon they started.

Windows: the scripts are plain `sh`; they should work from Git Bash if `curl` and `python3` are on `PATH` (they look for
`bin/vdrx.exe` too), but only Linux has been tried - WSL is the safe choice.
