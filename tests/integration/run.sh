#!/bin/sh
# Integration tests: start the real daemon on real configs (the examples/ folders
# and the fixtures in tests/integration/) and check what comes back over the wire.
#
#   tests/integration/run.sh              run everything this machine can run
#   tests/integration/run.sh php-cgi ws   run only the named sections
#
# Sections: static-site php-cgi python-cgi cli-api templates websocket-only
#           web-and-websocket legacy-cli-bridges cgi ws
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
    # Known gap, reported but not a failure: HTTP connections don't hand a WebSocket upgrade to the WS server.
    up=$(printf 'GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n' | python3 -c "
import socket,sys; s=socket.create_connection(('127.0.0.1',8080)); s.settimeout(2); s.sendall(sys.stdin.buffer.read())
try: print(s.recv(200).split(b'\r\n')[0].decode())
except Exception as e: print('no answer')")
    case "$up" in *101*) echo "  note  WebSocket upgrade on the HTTP port works";; *) echo "  note  known gap: a WebSocket upgrade on the HTTP port is not supported yet (got: $up) - use the separate WebSocket port";; esac
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

stop
echo; echo "integration: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
