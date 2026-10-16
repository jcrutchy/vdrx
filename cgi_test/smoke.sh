#!/bin/sh
# Smoke test for the CGI executive. Run from cgi_test/ with vdrx already
# started there (needs php-cgi on PATH and curl).   ./smoke.sh
B=http://127.0.0.1:18080; fail=0
chk(){ if echo "$2" | grep -q "$3"; then echo "ok   $1"; else echo "FAIL $1 (wanted: $3)"; fail=1; fi; }
chk "env + PATH_INFO"   "$(curl -s "$B/env.php/a/b?x=1" -d p=q)" "PATH_INFO=/a/b"
chk "POST body"         "$(curl -s "$B/env.php" -d p=q)"            'POST={"p":"q"}'
chk "rewrite"           "$(curl -s $B/blog/42)"                     "POST id=42 uri=/blog/42"
chk "front controller"  "$(curl -s $B/no/such/page)"                "FRONT uri=/no/such/page"
chk "multi Set-Cookie"  "$(curl -si $B/cookies.php | grep -c '^Set-Cookie')" "2"
chk "status passthru"   "$(curl -si $B/status.php | head -1)"       "418"
chk "dir redirect"      "$(curl -si $B/sub | head -1)"              "301"
chk "dotfile refused"   "$(curl -si $B/.env | head -1)"             "403"
chk "traversal refused" "$(curl -si "$B/%2e%2e/vdrx.conf" | head -1)" "403"
chk "timeout -> 504"    "$(curl -si $B/slow.php | head -1)"         "504"
exit $fail
