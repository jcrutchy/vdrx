#!/bin/sh
# Integration tests: start the real daemon on real configs (the examples/ folders
# and the fixtures in tests/integration/) and check what comes back over the wire.
#
#   tests/integration/run.sh              run everything this machine can run
#   tests/integration/run.sh php-cgi ws   run only the named sections
#
# Sections: static-site php-cgi python-cgi cli-api templates websocket-only
#           web-and-websocket legacy-cli-bridges cgi ws ws-open ws-lockout log-redaction limits ws-shared spawn jobs
# Needs: bin/vdrx (./build.sh), curl, python3. php-cgi / php / sort,tr,wc,head,grep
# are only needed by the sections that use them; those sections skip if missing.
# Uses ports 8080, 8082, 18080, 18082 - it refuses to run if one is already taken,
# and only ever stops the daemon it started itself.
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd); BIN="$ROOT/bin/vdrx"; [ -x "$BIN" ] || BIN="$ROOT/bin/vdrx.exe"; PIDFILE=/tmp/vdrx_it.pid; OUT=/tmp/vdrx_it.out
[ -x "$BIN" ] || { echo "bin/vdrx not found - run ./build.sh first"; exit 2; }
SETSID=""; command -v setsid >/dev/null 2>&1 && SETSID=setsid
command -v curl >/dev/null || { echo "curl is required"; exit 2; }
PASS=0; FAIL=0; SKIP=0

have() { command -v "$1" >/dev/null 2>&1; }
want() { [ $# -eq 1 ] && return 0; n=$1; shift; for a in "$@"; do [ "$a" = "$n" ] && return 0; done; return 1; }
up()   { curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$1/"; [ $? -ne 7 ]; }   # 7 = connection refused
stop() {
  [ -f "$PIDFILE" ] || return 0
  pid=$(cat "$PIDFILE"); kill "$pid" 2>/dev/null; n=0
  while kill -0 "$pid" 2>/dev/null && [ $n -lt 40 ]; do sleep .2; n=$((n+1)); done
  kill -9 "$pid" 2>/dev/null; rm -f "$PIDFILE"
}
trap 'stop' EXIT INT TERM
start() {   # start <dir> <port>...   (the daemon reads vdrx.conf from its working directory)
  dir=$1; shift; stop
  for p in "$@"; do up "$p" && { echo "port $p is already in use - stop that program first"; exit 2; }; done
  ( cd "$dir" && rm -f vdrx_daemon.log && $SETSID nohup "$BIN" >"$OUT" 2>&1 </dev/null & echo $! >"$PIDFILE" )
  for p in "$@"; do
    n=0; until up "$p"; do n=$((n+1)); [ $n -gt 50 ] && { echo "  daemon did not open port $p:"; head -5 "$OUT"; return 1; }; sleep .2; done
  done
}
ok()   { PASS=$((PASS+1)); echo "  ok    $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1  ($2)"; }
skip() { SKIP=$((SKIP+1)); echo "  skip  $1"; }
section() { echo; echo "== $1"; }
expect() { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "wanted '$3', got '$(printf %s "$2" | head -c 100 | tr '\n' ' ')'";; esac; }
equals() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$3', got '$2'"; fi; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }
get()  { curl -s --max-time 10 "$@"; }
need() { for t in "$@"; do have "$t" || { skip "needs $t on PATH"; return 1; }; done; return 0; }

# ---------------------------------------------------------------- examples
if want static-site "$@"; then section "examples/static-site"
  start examples/static-site 8080 &&
  { expect "/ serves index.html" "$(get http://127.0.0.1:8080/)" "It works"
    equals "/about/ serves the directory index" "$(code http://127.0.0.1:8080/about/)" 200
    equals "/about redirects to /about/" "$(code http://127.0.0.1:8080/about)" 301
    expect "css content type" "$(curl -sI http://127.0.0.1:8080/style.css)" "text/css"
    equals "missing file is 404" "$(code http://127.0.0.1:8080/missing.html)" 404
    equals "path traversal is refused" "$(code --path-as-is 'http://127.0.0.1:8080/%2e%2e/vdrx.conf')" 404; }
fi

if want php-cgi "$@"; then section "examples/php-cgi"
  if need php-cgi && start examples/php-cgi 8080; then
    expect "home page" "$(get http://127.0.0.1:8080/)" "vdrx + php-cgi"
    expect "rewrite /blog/42 -> post.php?id=42" "$(get http://127.0.0.1:8080/blog/42)" "post id: 42"
    expect "REQUEST_URI keeps the original URL" "$(get http://127.0.0.1:8080/blog/42)" "/blog/42"
    expect "front controller catches unknown URLs" "$(get http://127.0.0.1:8080/nope/page)" "Front controller"
    expect "PATH_INFO" "$(get http://127.0.0.1:8080/info.php/extra/path)" "/extra/path"
    expect "POST + cookie" "$(curl -si -d name=Jared http://127.0.0.1:8080/form.php)" "Set-Cookie: last_name=Jared"
    equals "dot-files are refused" "$(code http://127.0.0.1:8080/.env)" 403
  fi
fi

if want python-cgi "$@"; then section "examples/python-cgi"
  if need python3 && start examples/python-cgi 8080; then
    expect "home page" "$(get http://127.0.0.1:8080/)" "vdrx + Python CGI"
    expect "query string reaches the script" "$(get 'http://127.0.0.1:8080/env.py?name=Jared')" "Hello, Jared!"
    equals "two Set-Cookie headers survive" "$(curl -si http://127.0.0.1:8080/api.py | grep -ci '^set-cookie')" 2
    equals "POST -> Status: 201" "$(code -d '{"a":1}' http://127.0.0.1:8080/api.py)" 201
    expect "request body reaches stdin" "$(get -d '{"a":1}' http://127.0.0.1:8080/api.py)" '"body": "{\"a\":1}"'
    equals "static file next to scripts" "$(code http://127.0.0.1:8080/style.css)" 200
  fi
fi

if want cli-api "$@"; then section "examples/cli-api"
  if need sort tr wc head grep && start examples/cli-api 8080; then
    equals "sort" "$(printf 'pear\napple\nfig\n' | get --data-binary @- http://127.0.0.1:8080/api/sort)" "$(printf 'apple\nfig\npear')"
    equals "tr (upper-case)" "$(get -d 'hello vdrx' http://127.0.0.1:8080/api/upper)" "HELLO VDRX"
    expect "wc -w" "$(get -d 'one two three' http://127.0.0.1:8080/api/words)" "3"
    expect "response json: exit_code as data" "$(get -d 'one two' http://127.0.0.1:8080/api/words.json)" '"exit_code"'
    equals "head -n %%n%% from the query string" "$(printf 'a\nb\nc\n' | get --data-binary @- 'http://127.0.0.1:8080/api/head?n=2')" "$(printf 'a\nb')"
    expect "grep hit" "$(printf 'pear\napple\n' | get --data-binary @- 'http://127.0.0.1:8080/api/grep?pattern=APP')" "apple"
    equals "grep miss: exit 1 -> 404" "$(printf 'pear\n' | code --data-binary @- 'http://127.0.0.1:8080/api/grep?pattern=zzz')" 404
    equals "GET on a POST route -> 405" "$(code http://127.0.0.1:8080/api/sort)" 405
  fi
fi

if want templates "$@"; then section "examples/templates"
  if need python3 && start examples/templates 8080; then
    page=$(get 'http://127.0.0.1:8080/greeting?name=Jared')
    expect "%%name%% param" "$page" "Hello, Jared!"
    expect "\$\$site_title\$\$ setting" "$page" "vdrx templates demo - greeting"
    expect "##loop## rows" "$page" "I only sent data"
    expect "@@footer@@ partial" "$page" "rendered by vdrx for vdrx templates demo"
  fi
fi

if want websocket-only "$@"; then section "examples/websocket-only"
  if need python3 && start examples/websocket-only 8082; then
    seen=$(python3 examples/websocket-only/watch.py 127.0.0.1 8082 4)
    expect "ticks arrive over the WebSocket" "$seen" "clock.tick"
    n=$(printf '%s\n' "$seen" | grep -c clock.tick); [ "$n" -ge 2 ] && ok "at least two ticks in 4s ($n)" || bad "tick count" "$n"
  fi
fi

if want web-and-websocket "$@"; then section "examples/web-and-websocket"
  if need python3 && start examples/web-and-websocket 8080 8082; then
    expect "chat page is served" "$(get http://127.0.0.1:8080/)" "vdrx chat"
    python3 - <<'PY' && ok "chat round trip over the WebSocket port" || bad "chat round trip" "see output above"
import sys; sys.path.insert(0, "tests/integration")
from wsclient import *
a, b = connect("127.0.0.1", 8082), connect("127.0.0.1", 8082)
for c in (a, b): send(c, {"method": "sys.auth", "profile": "browser"})
assert any(f.get("event") == "auth.ok" for f in frames(a, .5)), "auth"
frames(b, .3)
send(b, {"method": "subscribe", "filter": "chat.room"}); frames(b, .3)
send(a, {"method": "publish", "topic": "chat.room", "payload": {"user": "t", "text": "hi"}})
got = [f for f in frames(b, .8) if f.get("topic") == "chat.room"]
assert got and got[0]["payload"]["text"] == "hi", got
send(b, {"method": "subscribe", "filter": "sys.>"})
assert any(f.get("event") == "denied" for f in frames(b, .5)), "sys.> must be denied"
PY
    # The page uses the HTTP port: websocket_path hands the upgrade to the WebSocket server.
    python3 - <<'PY' && ok "chat round trip over the SHARED port (ws on 8080, path /ws)" || bad "shared-port chat" "see output above"
import sys; sys.path.insert(0, "tests/integration")
from wsclient import *
a, b = connect("127.0.0.1", 8080, "/ws"), connect("127.0.0.1", 8080, "/ws")
for c in (a, b): send(c, {"method": "sys.auth", "profile": "browser"})
assert any(f.get("event") == "auth.ok" for f in frames(a, .5)), "auth over the shared port"
frames(b, .3)
send(b, {"method": "subscribe", "filter": "chat.room"}); frames(b, .3)
send(a, {"method": "publish", "topic": "chat.room", "payload": {"user": "t", "text": "shared"}})
got = [f for f in frames(b, .8) if f.get("topic") == "chat.room"]
assert got and got[0]["payload"]["text"] == "shared", got
PY
  fi
fi

if want legacy-cli-bridges "$@"; then section "examples/legacy-cli-bridges"
  if need php && start examples/legacy-cli-bridges 8080; then
    expect "cgi bridge" "$(get http://127.0.0.1:8080/cli/index.php)" "<"
    expect "bus bridge" "$(get http://127.0.0.1:8080/hello/x)" "hello"
    expect "bus bridge with a template reply" "$(get 'http://127.0.0.1:8080/template-demo?name=Jared')" "Hello, Jared!"
    expect "bus-daemon route" "$(get http://127.0.0.1:8080/echo-daemon)" "echo_daemon"
  fi
fi

# ---------------------------------------------------------------- fixtures
if want cgi "$@"; then section "tests/integration/cgi (CGI executive)"
  if need php-cgi && start tests/integration/cgi 18080; then
    out=$(cd tests/integration/cgi && ./smoke.sh 2>&1); rc=$?; echo "$out" | sed 's/^/  /'
    [ $rc -eq 0 ] && ok "cgi smoke suite" || bad "cgi smoke suite" "see output above"
  fi
fi

if want ws "$@"; then section "tests/integration/ws (ws_profiles)"
  if need python3 && start tests/integration/ws 18082; then
    out=$(cd tests/integration/ws && python3 ws_test.py 2>&1); echo "$out" | sed 's/^/  /'
    case "$out" in *"all passed"*) ok "ws_profiles suite";; *) bad "ws_profiles suite" "see output above";; esac
  fi
fi

if want ws-open "$@"; then section "tests/integration/ws-open (no ws_profiles: closed by default)"
  if need python3 && start tests/integration/ws-open 18082; then
    out=$(cd tests/integration/ws-open && python3 ws_open_test.py reject 2>&1); echo "$out" | sed 's/^/  /'
    case "$out" in *"all passed"*) ok "no ws_profiles -> every sys.auth rejected";; *) bad "ws closed by default" "see output above";; esac
  fi
  if need python3 && start tests/integration/ws-open-allowed 18082; then
    out=$(cd tests/integration/ws-open && python3 ws_open_test.py allow 2>&1); echo "$out" | sed 's/^/  /'
    case "$out" in *"all passed"*) ok "allow_open_access opt-in behaves as documented";; *) bad "allow_open_access" "see output above";; esac
  fi
fi

if want ws-lockout "$@"; then section "tests/integration/ws (failed-login lockout)"
  if need python3 && start tests/integration/ws 18082; then
    out=$(cd tests/integration/ws && python3 ws_lockout_test.py 2>&1); echo "$out" | sed 's/^/  /'
    case "$out" in *"all passed"*) ok "lockout suite";; *) bad "lockout suite" "see output above";; esac
  fi
fi

# Sends one request carrying credentials in every place a client can put them, plus a good and a bad
# WebSocket login, then waits for the logger's writer thread to flush.
redact_probe() {
  curl -s -o /dev/null --max-time 10 -X POST "http://127.0.0.1:18080/echo.py?api_key=URLQUERYSECRET" \
    -H 'Authorization: Bearer SUPERSECRETBEARER' -H 'Cookie: session=SESSIONCOOKIE123' \
    --data 'username=bob&password=HUNTER2PASSWORD'
  python3 -c '
import sys; sys.path.insert(0, "tests/integration")
from wsclient import *
c = connect(); send(c, {"method": "sys.auth", "token": "WSSECRETTOKEN999"}); frames(c, .5)
x = connect(); send(x, {"method": "sys.auth", "token": "WRONGGUESSTOKEN777"}); frames(x, .5)'
  sleep 2
}
redact_count() { # <secret> <dir>  -> total occurrences in the log file + console output
  a=$(grep -c "$1" "$2/vdrx_daemon.log" 2>/dev/null); b=$(grep -c "$1" "$OUT" 2>/dev/null); echo $((a + b))
}

if want log-redaction "$@"; then section "log redaction (credentials must not reach the log or console)"
  if need python3 && start tests/integration/log-redaction 18080 18082; then
    redact_probe
    d=tests/integration/log-redaction
    for s in SUPERSECRETBEARER SESSIONCOOKIE123 HUNTER2PASSWORD URLQUERYSECRET WSSECRETTOKEN999 WRONGGUESSTOKEN777; do
      equals "redaction on: $s is not in the log or console" "$(redact_count $s $d)" 0
    done
    equals "redaction on: the per-process _edge_token is not logged" "$(grep -c '_edge_token" : "[0-9A-F]' $d/vdrx_daemon.log)" 0
    expect "redaction on: the request is still logged (method and path)" "$(cat $d/vdrx_daemon.log)" '"path" : "/echo.py"'
    expect "redaction on: the masking is visible in the log" "$(cat $d/vdrx_daemon.log)" "[REDACTED]"
  fi
  if need python3 && start tests/integration/log-redaction-off 18080 18082; then
    redact_probe
    d=tests/integration/log-redaction-off
    for s in SUPERSECRETBEARER SESSIONCOOKIE123 WSSECRETTOKEN999; do
      expect "log_redact=false: $s does show up (so the checks above are meaningful)" "$(cat $d/vdrx_daemon.log)" $s
    done
  fi
fi

if want limits "$@"; then section "limits (slow clients, oversize frames, TLS handshake stalls)"
  d=tests/integration/limits
  if command -v openssl >/dev/null 2>&1 && [ ! -f $d/cert.pem ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -keyout $d/key.pem -out $d/cert.pem -subj /CN=localhost -days 2 >/dev/null 2>&1
  fi
  if need python3 && start $d 18080 18082; then
    out=$(cd $d && python3 limits_test.py 2>&1); echo "$out" | sed 's/^/  /'
    case "$out" in *"all passed"*) ok "limits suite";; *) bad "limits suite" "see output above";; esac
  fi
fi

if want ws-shared "$@"; then section "ws-shared (WebSocket on the HTTP port, Origin check, connection cap, no handshake leak)"
  d=tests/integration/ws-shared
  if command -v openssl >/dev/null 2>&1 && [ ! -f $d/cert.pem ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -keyout $d/key.pem -out $d/cert.pem -subj /CN=localhost -days 2 >/dev/null 2>&1
  fi
  if need python3 && start $d 18080 18082; then
    out=$(cd $d && python3 ws_shared_test.py 2>&1); echo "$out" | sed 's/^/  /'
    case "$out" in *"all passed"*) ok "ws-shared suite";; *) bad "ws-shared suite" "see output above";; esac
  fi
fi

if want spawn "$@"; then section "spawn (clean child environment, output cap, stdin, static file policy)"
  export VDRX_TEST_SECRET=zz-secret-1 VDRX_TEST_OTHER=zz-secret-2
  if need python3 && start tests/integration/spawn 18080; then
    out=$(cd tests/integration/spawn && python3 spawn_test.py default 2>&1); echo "$out" | sed 's/^/  /'
    case "$out" in *"all passed"*) ok "spawn suite";; *) bad "spawn suite" "see output above";; esac
  fi
  if need python3 && start tests/integration/spawn-open 18080; then
    out=$(cd tests/integration/spawn && python3 spawn_test.py open 2>&1); echo "$out" | sed 's/^/  /'
    case "$out" in *"all passed"*) ok "spawn opt-outs work";; *) bad "spawn opt-outs" "see output above";; esac
  fi
  unset VDRX_TEST_SECRET VDRX_TEST_OTHER
fi

if want jobs "$@"; then section "tests/integration/jobs (scheduler + job runner)"
  rm -f tests/integration/jobs/jobs_state.json tests/integration/jobs/jobs_test.jsonl*
  if need python3 && start tests/integration/jobs 18082; then
    out=$(cd tests/integration/jobs && python3 jobs_test.py 2>&1); echo "$out" | sed 's/^/  /'
    case "$out" in *"all passed"*) ok "jobs suite";; *) bad "jobs suite" "see output above";; esac
    grep -aq '\[tick:[0-9]*\] > out1' "$OUT" && ok "job output is printed on the console as [job:pid] lines" || bad "job console lines" "see $OUT"
    stop; sleep .3
    pgrep -fx "sleep 61" >/dev/null && bad "shutdown left a job process running" "sleep 61 still alive" || ok "shutdown stops running job processes"
    # the browser page, in headless Chromium (spawns its own daemon on 18082)
    if python3 -c "import playwright" 2>/dev/null; then
      out=$(cd tests/integration/jobs && timeout 240 python3 terminal_test.py 2>&1); echo "$out" | sed 's/^/  /'
      case "$out" in *"all passed"*) ok "tools/jobs_terminal.html in a browser";; *) bad "jobs terminal page" "see output above";; esac
    else
      skip "tools/jobs_terminal.html browser test (needs: pip install playwright && playwright install chromium)"
    fi
  fi
fi

stop
echo; echo "integration: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
