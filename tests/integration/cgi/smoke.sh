#!/bin/sh
# Smoke test for the CGI executive. Run from tests/integration/cgi/ with vdrx already
# started there (needs php-cgi on PATH and curl).   ./smoke.sh
B=http://127.0.0.1:18080; fail=0
chk(){ if echo "$2" | grep -q "$3"; then echo "ok   $1"; else echo "FAIL $1 (wanted: $3, got: $(echo "$2" | head -1 | cut -c1-100))"; fail=1; fi; }
chk "env + PATH_INFO"   "$(curl -s "$B/env.php/a/b?x=1" -d p=q)" "PATH_INFO=/a/b"
chk "POST body"         "$(curl -s "$B/env.php" -d p=q)"            'POST={"p":"q"}'
chk "rewrite"           "$(curl -s $B/blog/42)"                     "POST id=42 uri=/blog/42"
chk "front controller"  "$(curl -s $B/no/such/page)"                "FRONT uri=/no/such/page"
chk "multi Set-Cookie"  "$(curl -si $B/cookies.php | grep -c '^Set-Cookie')" "2"
chk "status passthru"   "$(curl -si $B/status.php | head -1)"       "418"
chk "dir redirect"      "$(curl -si $B/sub | head -1)"              "301"
chk "dotfile refused"   "$(curl -si $B/.env | head -1)"             "403"
# Traversal attempts are sent as RAW request lines: curl may normalise or decode "..", "%2e%2e" and
# friends on its own (and newer versions do more of it), which would stop this testing the server.
raw() { python3 - "$1" <<'PY'
import socket, sys
s = socket.create_connection(("127.0.0.1", 18080)); s.settimeout(5)
s.sendall(("GET %s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n" % sys.argv[1]).encode())
d = b""
try:
    while True:
        b = s.recv(4096)
        if not b: break
        d += b
except socket.timeout: pass
print(d.split(b"\r\n", 1)[0].decode("latin1"))
PY
}
for p in '/../vdrx.conf' '/%2e%2e/vdrx.conf' '/..%2fvdrx.conf' '/%2e%2e%2fvdrx.conf' '/sub/%2e%2e/%2e%2e/vdrx.conf' '/..%5cvdrx.conf'; do
  chk "traversal refused: $p (raw)" "$(raw "$p")" "403"
done
chk "timeout -> 504"    "$(curl -si $B/slow.php | head -1)"         "504"
chmod +x cgi-bin/hello.cgi 2>/dev/null
chk "classic cgi-bin (command \"\")" "$(curl -s "$B/cgi-bin/hello.cgi?q=1")" "classic cgi-bin: method=GET query=q=1"
exit $fail
