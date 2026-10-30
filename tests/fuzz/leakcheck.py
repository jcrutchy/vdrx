#!/usr/bin/env python3
"""A deterministic memory-growth check for a RUNNING vdrx (tests/fuzz fixture).
Sends the same sequential requests twice and requires the second pass to add almost nothing:
a warm-up cost shows in pass 1 only, a leak shows in both. Covers the two routes that go through the bus
request/reply path - a CGI program and a command-line runner. (Before the registry fix each request added
about 30-45 KB: 12 MB or more per pass here, against a limit of 5.)"""
import os, sys, time, socket
import fuzz

LIMIT_MB = 5.0
def get(path, body=None):
    s = socket.create_connection(fuzz.HTTP, timeout=5)
    if body is None: s.sendall(("GET %s HTTP/1.1\r\nHost: x\r\n\r\n" % path).encode())
    else: s.sendall(("POST %s HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n" % (path, len(body))).encode() + body)
    s.settimeout(5)
    while s.recv(65536): pass
    s.close()
def settle(pid): time.sleep(1.5); return fuzz.stats(pid)["rss"]

def main():
    pid = fuzz.daemon_pid()
    if not pid: print("no vdrx daemon running"); return 2
    bad = 0
    for label, fn in (("CGI program   ", lambda: get("/cgi/quick.py")), ("command runner", lambda: get("/api/sort", b"b\na\nc\n"))):
        for _ in range(80): fn()
        base = settle(pid); growth = []
        for p in (1, 2):
            for _ in range(400): fn()
            now = settle(pid); growth.append(now - base); base = now
        ok = growth[1] < LIMIT_MB
        print("%s 2 x 400 requests: pass 1 %+5.1f MB, pass 2 %+5.1f MB (limit %.0f)  %s" % (label, growth[0], growth[1], LIMIT_MB, "ok" if ok else "LEAK"))
        bad += not ok
    print("all passed" if not bad else "%d LEAKING" % bad); return 1 if bad else 0
if __name__ == "__main__": sys.exit(main())
