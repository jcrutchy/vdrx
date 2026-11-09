"""Reverse proxy and HTTP front end: what vdrx forwards must be exactly the request it validated and routed.
Each rejected case below was accepted before (the malformed bytes reached the upstream)."""
import socket, time, os, sys
fails = 0
def check(name, cond, extra=""):
    global fails; print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(extra))); fails += not cond
HERE = os.path.dirname(os.path.abspath(__file__))
def log(port=18091): 
    p = os.path.join(HERE, "received%d.log" % port); return open(p, "rb").read() if os.path.exists(p) else b""
def reset():
    for p in (18091, 18092): open(os.path.join(HERE, "received%d.log" % p), "wb").close()
def talk(raw, wait=2.5):
    s = socket.create_connection(("127.0.0.1", 18090)); s.settimeout(0.4); s.sendall(raw); out = b""; end = time.time() + wait
    while time.time() < end:
        try:
            d = s.recv(65536)
            if not d: break
            out += d
        except socket.timeout: pass
    s.close(); return out
def status(r): return r.split(b"\r\n", 1)[0].decode("latin1")

for _ in range(40):                                  # wait for the upstream processes to be up
    if b"200" in talk(b"GET /app/ready HTTP/1.1\r\nHost: x\r\n\r\n", 1) and b"200" in talk(b"GET /api/ready HTTP/1.1\r\nHost: x\r\n\r\n", 1): break
    time.sleep(.5)

print("-- a normal request is forwarded unchanged, with Connection: close and CRLF line endings")
reset(); r = talk(b"POST /app/post HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nConnection: keep-alive\r\n\r\nhello")
check("the reply comes back", b"upstream saw: /app/post body=hello" in r, r[:200])
got = log(); head = got.split(b"\r\n\r\n")[0]
check("the upstream got Connection: close, not keep-alive", b"Connection: close" in head and b"keep-alive" not in head.lower(), head)
check("every line of the forwarded head ends in CRLF (no bare LF)", b"\n" not in head.replace(b"\r\n", b""), head)

print("-- bytes beyond the declared body are never forwarded (request smuggling)")
reset(); talk(b"GET /app/ok HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\nGET /admin/secret HTTP/1.1\r\nHost: x\r\n\r\n")
check("a pipelined second request does not reach the upstream", b"/admin/secret" not in log() and b"/app/ok" in log(), log())
reset(); talk(b"POST /app/p HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabcGET /admin/secret HTTP/1.1\r\nHost: x\r\n\r\n")
check("nor does data after the body", b"/admin/secret" not in log() and b"abc" in log(), log())

print("-- ambiguous or malformed framing is refused, and nothing reaches the upstream")
cases = [
  ("Content-Length: 0x10",              b"POST /app/x HTTP/1.1\r\nHost: x\r\nContent-Length: 0x10\r\n\r\n", "400"),
  ("Content-Length: $10",               b"POST /app/x HTTP/1.1\r\nHost: x\r\nContent-Length: $10\r\n\r\n", "400"),
  ("Content-Length: -1",                b"POST /app/x HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n", "400"),
  ("Content-Length: 5, 5",              b"POST /app/x HTTP/1.1\r\nHost: x\r\nContent-Length: 5, 5\r\n\r\nhello", "400"),
  ("two Content-Length headers",        b"POST /app/x HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello", "400"),
  ("whitespace before the colon",       b"POST /app/x HTTP/1.1\r\nHost: x\r\nContent-Length : 5\r\n\r\nhello", "400"),
  ("Transfer-Encoding: chunked",        b"POST /app/x HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n", "501"),
  ("Transfer-Encoding with Content-Length", b"POST /app/x HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n", "501"),
  ("bare LF inside the head",           b"GET /app/x HTTP/1.1\r\nHost: x\nX-A: 1\r\n\r\n", "400"),
  ("bare CR inside the head",           b"GET /app/x HTTP/1.1\r\nHost: x\rX-A: 1\r\n\r\n", "400"),
  ("obsolete line folding",             b"GET /app/x HTTP/1.1\r\nHost: x\r\n  folded\r\n\r\n", "400"),
  ("header name with a space",          b"GET /app/x HTTP/1.1\r\nHo st: x\r\n\r\n", "400"),
  ("a control character in a value",    b"GET /app/x HTTP/1.1\r\nHost: x\r\nX-A: a\x01b\r\n\r\n", "400"),
]
for name, raw, want in cases:
    reset(); r = talk(raw, 1.2)
    check("%s -> %s, not forwarded" % (name, want), status(r).split(" ")[1:2] == [want] and log() == b"", (status(r), log()[:120]))
reset(); r = talk(b"GET /app/x HTTP/1.1\r\nHost: x\r\nX-Pad: " + b"a" * 20000 + b"\r\n\r\n", 1.5)
check("a request head over 16 KiB -> 431 (not processed as a partial request)", status(r).split(" ")[1:2] == ["431"] and log() == b"", (status(r), len(log())))

print("-- a prefix without a trailing slash covers only its own path, not look-alike names")
reset()
for path, expect in (("/api", True), ("/api/x", True), ("/api?q=1", True), ("/application", False), ("/api-admin", False), ("/apix/y", False)):
    reset(); r = talk(("GET %s HTTP/1.1\r\nHost: x\r\n\r\n" % path).encode(), 1.2)
    reached = b"upstream saw" in r
    check("%s %s the /api route" % (path, "reaches" if expect else "does NOT reach"), reached == expect, (status(r), r[:100]))

print("-- the upstream's response is bounded")
t0 = time.time(); r = talk(b"GET /app/huge HTTP/1.1\r\nHost: x\r\n\r\n", 20)
check("a 70 MiB response is dropped with 502 instead of being buffered", status(r).split(" ")[1:2] == ["502"], (status(r), len(r)))
check("and vdrx is still serving afterwards", b"upstream saw: /app/after" in talk(b"GET /app/after HTTP/1.1\r\nHost: x\r\n\r\n"))

print("all passed" if not fails else "%d FAILED" % fails)
sys.exit(1 if fails else 0)
