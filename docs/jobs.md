# 11. Scheduled jobs - `jobs`

Run ordinary programs on a schedule - several at once, with their output
streamed onto the bus line by line while they run. Nothing in the program needs
to know about VDRX: it just prints.

```json
{
  "executives": { "jobs": { "max_concurrent": 4 } },
  "jobs": [
    { "id": "report", "command": "{PHP_BIN}", "args": ["{APP}/index.php", "report"], "interval_sec": 360 },
    { "id": "sync",   "command": "{PHP_BIN}", "args": ["{APP}/index.php", "sync"], "interval_sec": 30, "overlap": "skip", "timeout_sec": 120 }
  ]
}
```

```
 scheduler ──sched.<id>──►  job runner ──► child process (own thread, stdout + stderr read as they arrive)
 (a clock)   jobs.run  ──►      │
             jobs.kill ──►      ├──► job.<id>.start / .out / .err / .exit / .skip / .queued ...  ──►  the bus
                                                                                                        │
                      job console · logger · buckets · a browser over a WebSocket · another process ◄──┘
```

Three executives share one job table: the **scheduler** only publishes
`sched.<id>` when a job is due, the **runner** starts programs, and an optional
**console** prints `job.>` as coloured lines. Because they only talk through
topics, anything else can start a job too - a browser button, a script, another
job: publish `jobs.run` (or `sched.<id>`).

## 11a. Config

`jobs` is an array; settings shared by all jobs live under `executives.jobs`.

| `executives.jobs` key | Default | Meaning |
|---|---|---|
| `state_file` | `jobs_state.json` | Remembers when each scheduled job last ticked, so a restart doesn't run everything again (an overdue job runs at once). `""` = don't remember. |
| `max_concurrent` | `0` | Jobs allowed to run at the same moment; `0` = no limit. Extra ticks wait in a FIFO queue (`job.<id>.queued`). |
| `console` | `true` | Print `job.>` as coloured console lines (see 11d). Also keeps `job.>` and `sched.>` off the logger's console so lines aren't doubled. |
| `console_color` | `true` | ANSI colours in that output. Turn off under systemd/journald. |

| `jobs[]` key | Default | Meaning |
|---|---|---|
| `id` | required | Letters, digits, `_` and `-` only (never `.`): it is a topic segment, so `job.report.>` and `job.*.exit` work. |
| `command` | required | The program, plus any fixed leading arguments (split on spaces, FPC quoting rules). |
| `args` | `[]` | More arguments, passed exactly as written - no shell, no re-splitting. Prefer this for paths that may contain spaces. |
| `work_dir` | VDRX's own | Working directory of the program. |
| `env` | `{}` | Extra environment variables. The daemon's own environment is inherited (jobs are written by the administrator and not reachable from a web request, unlike CGI programs, which get a clean environment - see `child_env_inherit`). |
| `interval_sec` | `0` | Seconds between runs (`interval` also accepted). `0` = never scheduled; only `jobs.run` / `sched.<id>` start it. |
| `enabled` | `true` | `false` = not scheduled. A disabled job can still be run by hand (`jobs.run`). |
| `run_on_start` | `true` | A job that has never run is due immediately. `false` = its first run is one interval after it first sees the job. |
| `overlap` | `skip` | What a tick does while the previous run is still going: `skip` (ignore it), `queue` (run once more afterwards - at most one is remembered), `kill` (stop the old run, start a new one). |
| `timeout_sec` | `0` | Stop a run after this long. `0` = no limit. |
| `kill_grace_ms` | `3000` | A stop is polite first (SIGTERM), then a force-kill after this long. On Windows there is no polite signal, so it is the force-kill. |
| `strip_ansi` | `true` | Remove colour/cursor escape codes from output lines before publishing. |

The `jobs` array is read at startup; `reload` does not re-read it (same as `runners`).

## 11b. Topics

A run publishes these. Every payload is one JSON object with `job` and `ts`
(UTC, ISO 8601); run events add `run` (a counter) and `pid`.

| Topic | Extra fields | Meaning |
|---|---|---|
| `job.<id>.start` | `trigger` (`schedule` / `manual` / `rerun` / `queued`) | The process started. |
| `job.<id>.out` | `stream:"out"`, `line` | One line of stdout. |
| `job.<id>.err` | `stream:"err"`, `line` | One line of stderr. |
| `job.<id>.exit` | `status`, `code`, `duration_ms`, `stop`?, `error`? | `status`: `ok` · `failed` (non-zero) · `timeout` · `killed` · `start_failed`. `stop` says why a run was stopped: `timeout`, `killed` (jobs.kill), `restart` (overlap kill), `shutdown`. |
| `job.<id>.skip` | `reason`, `trigger` | A tick was ignored (previous run still active, rerun already queued, ...). |
| `job.<id>.queued` | `reason`, `trigger` | Waiting for the previous run to end, or for a free `max_concurrent` slot. |
| `job.<id>.restart` | `reason`, `trigger` | Overlap `kill`: the old run is being stopped to make room. |
| `job.<id>.error` | `reason`, `trigger` | The run could not be started at all (thread creation failed). |

Lines are published as they arrive, not at the end. A final line with no trailing
newline is still published; a line longer than 16 KB is published in pieces; bytes
that are not valid UTF-8 become `?` so the payload is always valid JSON. Empty
lines are published too (the console skips them).

**Control** - publish to these (a WebSocket profile needs them in `publish_allow`):

| Topic | Payload | Effect |
|---|---|---|
| `jobs.run` | `report` or `{"job":"report"}` | Run now, subject to `overlap` and `max_concurrent`. |
| `jobs.kill` | `report` or `{"job":"report"}` | Stop the running job (and cancel a queued rerun or a place in the wait queue). |
| `jobs.list` | anything | Answered on `jobs.state`: `{max_concurrent, active, waiting[], jobs:[{job, enabled, interval_sec, overlap, running, pid?, runs, last_status?, last_code?, last_started?, last_ended?, last_duration_ms?, next_in_sec?}]}`. |
| `sched.<id>` | anything | A tick, exactly as the scheduler sends it. |

Failures and timeouts also put a one-line `log.warn` in the daemon log, and a
program that cannot be started a `log.error` - so the log file stays useful even
if you keep job output out of it (11d).

## 11c. Scheduling semantics

- A job is **due** when it has never run (and `run_on_start` is on), or when
  `interval_sec` has passed since its last tick. The tick time is stamped when the
  tick is *published*, whether or not the runner then skips it - so a slow job never
  makes its own schedule drift, and a job that overruns its interval simply has
  some ticks skipped.
- There is **no catch-up**: after downtime longer than the interval a job runs once,
  not once per missed interval.
- A clock set backwards doesn't stall anything: a last-tick time in the future is
  pulled back to now.
- Intervals only for now - no cron expressions. (A cron-style `at` would be another
  publisher of `sched.<id>`; nothing in the runner would change.)

## 11d. Seeing the output

**Job console.** With `console: true` every line is printed as
`2026-10-23 14:02:11 [report:4182] > text` - timestamp and `[job:pid]` in a
black-on-yellow block, a yellow arrow, then the text (green for stdout, red for
stderr, grey for skipped/queued, and a coloured start / finished / failed line per
run).

**Logger.** The logger records every bus message, which would put every job line in
`vdrx_daemon.log`. Keep that file for the daemon's own events and give job output a
rotating bucket instead:

```json
"log_file_exclude": ["job.>", "sched.>"],
"buckets": [ { "id": "jobs_log", "subscribe": "job.>", "file": "jobs.jsonl", "max_size_mb": 20, "max_files": 5 } ]
```

`log_console_exclude` / `log_file_exclude` are arrays of topic filters
(`*` = one segment, `>` = the rest) and work for any topic family. With the job
console on, `job.>` is excluded from the logger's console automatically.

**A browser - `tools/jobs_terminal.html`.** A single HTML file, no dependencies. Open
it, fill in the WebSocket URL, a profile id and its token, press *Connect*.

> **Opened from disk (`file://`)?** A browser sends `Origin: null` for such a page, and the WebSocket server
> refuses a browser handshake whose origin is not the same host as the request or listed in
> `executives.ws.allowed_origins`. Either serve the page from one of your HTTP sites (then it is the same
> host and just works), or add `"null"` to `allowed_origins`. `null` is also what a sandboxed iframe on any
> website sends, so only do it together with a profile that has a **token**.


- **Job list** (left): every job with a state dot (pulsing blue = running, green =
  last run ok, red = failed or timed out, amber = killed, hollow = disabled), its
  interval, the last result and a countdown to the next run. **▶** runs a job now
  (`jobs.run`), **■** stops it (`jobs.kill`); click a name to show only that job.
- **Terminal** (right): the live stream in the same layout as the server console
  (`time job:pid ► text`; green stdout, red stderr, cyan start/finish lines, grey
  skips). Filter by text, switch stdout / stderr / events on and off, UTC or local
  time, *follow* (it un-ticks itself when you scroll up), *Clear*, and *Save…* to
  download what is on screen as a log.
- It reconnects by itself (1s, 2s, 4s ... up to 15s) when the daemon restarts, and
  refreshes the job list every 5s. It shows lines published *after* it connected;
  history lives in the bucket.
- Output is always inserted as text, never as HTML, so a job that prints `<script>`
  is harmless. `?url=ws://host:8082&profile=operator` in the page address pre-fills
  the fields (never the token); add `&connect=1` to connect on load.

It needs a profile like this one (a read-only viewer can drop `publish_allow`; the
buttons then answer `denied` in the terminal):

```json
"executives": { "ws": { "enabled": true, "port": 8082 } },
"ws_profiles": [
  { "id": "operator", "token": "change-me",
    "subscribe_allow": ["job.>", "jobs.>"],
    "publish_allow": ["jobs.run", "jobs.kill", "jobs.list"],
    "default_subscribe": "job.>" }
]
```

The token travels in the clear over `ws://`; put the listener behind TLS (`wss://`)
or keep it on a trusted network. `tests/integration/jobs/terminal_test.py` drives the
page in headless Chromium (optional; needs Playwright).

## 11e. Running it headless (Linux, systemd)

vdrx reads `vdrx.conf` from its working directory. Set `"stdin_admin_enabled": false`
and `"executives": {"jobs": {"console_color": false}}` for a service, then:

```ini
[Unit]
Description=VDRX job runner
After=network.target

[Service]
WorkingDirectory=/opt/vdrx
ExecStart=/opt/vdrx/bin/vdrx
Restart=on-failure
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
```

On `systemctl stop` systemd sends SIGTERM; vdrx stops every running job (polite,
then forced after `kill_grace_ms`, capped by `shutdown_grace_ms`) and exits. systemd's
default `KillMode=control-group` also cleans up anything a job left behind.

## 11f. Limits

- **Stopping is per process, not per tree.** SIGTERM / the force-kill go to the
  program VDRX started. A job that runs `sh -c "..."` and lets the shell fork a
  child may leave that child running; use `exec` in the shell string, or run the
  program directly. (Windows: the force-kill is `taskkill /T`, which does take the tree.)
- A job's stdin is closed immediately (it reads end-of-file).
- A run's output is published line by line with no rate limit, so a program that
  prints hundreds of thousands of lines floods the bus and slow WebSocket clients
  start dropping the oldest frames (`{"event":"dropped"}`).
- Output is not merged: stdout and stderr are separate streams, so their relative
  order can differ slightly from a terminal's `2>&1`.

---
*Section numbers (§N) are shared across all vdrx docs - see the [section map](README.md#section-map).*
