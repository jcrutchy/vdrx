#!/usr/bin/env python3
"""The HTTP edge: client-supplied X-Forwarded-For & co. are deleted (unless the peer is a trusted proxy), the
upstream is told the real client, and default security headers are added. Run by tests/integration/run.sh
(section edge-policy) against the fixture in this folder."""
import socket, sys, time, os

HERE = os.path.dirname(os.path.abspath(__file__))
passed = failed = 0
def check(cond, name, extra=""):
    global passed, failed
    if cond: passed += 1; print("  ok    " + name)
    else:    failed += 1; print("  FAIL  " + name + ("  (" + str(extra)[:200] + ")" if extra else ""))

def talk(port, raw, src="127.0.0.1", wait=1.5):
    s = socket.socket(); s.settimeout(0.4); s.bind((src, 0)); s.connect(("127.0.0.1", port)); s.sendall(raw)
    out = b""; end = time.time() + wait
    while time.time() < end:
        try:
            d = s.recv(65536)
            if not d: break
            out += d
        except socket.timeout: pass
    s.close(); return out

def head(r): return r.split(b"\r\n\r\n")[0].decode("latin1")
def hdrs(r): return {l.split(":", 1)[0].lower(): l.split(":", 1)[1].strip() for l in head(r).split("\r\n")[1:] if ":" in l}
def upstream_log():
    p = os.path.join(HERE, "received18101.log"); return open(p, "rb").read().decode("latin1") if os.path.exists(p) else ""
def reset(): open(os.path.join(HERE, "received18101.log"), "wb").close()

FORGED = (b"GET /app/x HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: 6.6.6.6\r\nX-Real-IP: 7.7.7.7\r\nForwarded: for=8.8.8.8\r\n"
          b"X_Forwarded_Host: evil.example\r\nCF-Connecting-IP: 9.9.9.9\r\nX-Forwarded-Proto: https\r\n\r\n")

for _ in range(40):                                   # wait for the upstream process
    if b" 200 " in talk(18099, b"GET /app/ready HTTP/1.1\r\nHost: x\r\n\r\n", wait=1): break
    time.sleep(.5)

print("-- default security headers")
h = hdrs(talk(18099, b"GET / HTTP/1.1\r\nHost: x\r\n\r\n"))
check(h.get("x-content-type-options") == "nosniff", "X-Content-Type-Options: nosniff is sent", h)
check(h.get("referrer-policy") == "strict-origin-when-cross-origin", "Referrer-Policy is sent", h)
check(h.get("x-frame-options") == "DENY", "a header in the site's own \"headers\" overrides the default", h)
check("strict-transport-security" not in h, "no HSTS over plain HTTP", h)
h = hdrs(talk(18100, b"GET / HTTP/1.1\r\nHost: x\r\n\r\n"))
check(h.get("x-frame-options") == "SAMEORIGIN", "X-Frame-Options defaults to SAMEORIGIN", h)
h = hdrs(talk(18102, b"GET / HTTP/1.1\r\nHost: x\r\n\r\n"))
check(not any(k in h for k in ("x-content-type-options", "x-frame-options", "referrer-policy")), "security_headers: false turns them off", h)
h = hdrs(talk(18099, b"GET /nonexistent-page HTTP/1.1\r\nHost: x\r\n\r\n"))
check(h.get("x-content-type-options") == "nosniff", "they are on error pages too", h)
r = talk(18099, b"GET /app/x HTTP/1.1\r\nHost: x\r\n\r\n")
check(hdrs(r).get("x-content-type-options") == "nosniff" or b"upstream saw" in r, "a proxied response still arrives intact", head(r))

print("-- an untrusted client cannot forge who it is")
reset(); r = talk(18099, FORGED)
log = upstream_log()
check(b"upstream saw: /app/x" in r, "the request is still served", head(r))
for forged in ("6.6.6.6", "7.7.7.7", "8.8.8.8", "9.9.9.9", "evil.example"):
    check(forged not in log, "the upstream never sees the forged value %s" % forged, log[:300])
check("X-Forwarded-For: 127.0.0.1\r\n" in log, "the upstream is told the real client address", log[:400])
check("X-Forwarded-Proto: http\r\n" in log and "X-Forwarded-Proto: https" not in log, "...and the real scheme (the forged https is gone)", log[:400])
r = talk(18099, FORGED, src="127.0.0.2"); log2 = upstream_log()
check("X-Forwarded-For: 127.0.0.2\r\n" in log2, "a different client address is reported as that address", log2[-300:])

print("-- a trusted proxy is believed, and its chain is extended")
reset(); r = talk(18100, FORGED)
log = upstream_log()
check("X-Forwarded-For: 6.6.6.6, 127.0.0.1\r\n" in log, "the chain keeps the proxy's claim and adds the peer", log[:400])
check("X-Real-IP: 7.7.7.7" in log, "other client-address headers pass through from a trusted peer", log[:400])
check("X-Forwarded-Proto: https" in log, "the trusted proxy's scheme is kept", log[:400])

print("\n%d passed, %d failed" % (passed, failed))
print("all passed" if failed == 0 else "SOME FAILED")
sys.exit(1 if failed else 0)
