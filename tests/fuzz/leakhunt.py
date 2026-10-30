#!/usr/bin/env python3
"""Which kind of traffic makes the daemon's memory grow? Runs one traffic class at a time against a
RUNNING vdrx (tests/fuzz fixture), twice, and reports resident memory per operation. A class that grows by
about the same amount in BOTH passes is leaking; growth only in the first pass is warm-up."""
import os, sys, time, random, socket, base64
import fuzz
from fuzz import *
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "integration"))
from wsclient import connect, send, frames

def rss(pid): time.sleep(1.5); return stats(pid)["rss"]
def http_get(path):
    s = socket.create_connection(HTTP, timeout=3); s.sendall(("GET %s HTTP/1.1\r\nHost: x\r\n\r\n" % path).encode()); s.settimeout(3)
    while s.recv(65536): pass
    s.close()
def c_static(rng): http_get("/ok.html")
def c_404(rng): http_get("/nope")
def c_cgi(rng): http_get("/cgi/quick.py")
def c_fuzz_http(rng): deliver(rng, mutate(rng, gen_request(rng)) if rng.random() < .5 else gen_request(rng))
def c_runner(rng): deliver(rng, gen_runner_request(rng))
def c_ws_good(rng):
    c = connect(port=18082); send(c, {"method": "sys.auth", "token": "vt"}); c.s.close()
def c_ws_shared(rng):
    c = connect(port=18080, path="/ws"); send(c, {"method": "sys.auth", "token": "vt"}); c.s.close()
def c_ws_junk(rng):
    """connect, send a bad handshake, hang up at once (the pattern that used to leak a thread per attempt)"""
    s = socket.create_connection(rng.choice([WSOWN, WSOWN, HTTP]), timeout=3)
    s.sendall(rng.choice([b"GET / HTTP/1.1\r\nHost: x\r\n\r\n", os.urandom(40), b"GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"]))
    s.close()
def c_ws_fuzz(rng): ws_session(rng, 0)
def c_tls(rng): tls_junk(rng)
def c_idle(rng):
    s = socket.create_connection(HTTP, timeout=3); s.close()
CLASSES = {"static": (c_static, 1500), "404": (c_404, 1500), "cgi": (c_cgi, 300), "http-fuzz": (c_fuzz_http, 1200), "runner": (c_runner, 700),
           "ws-good": (c_ws_good, 800), "ws-shared": (c_ws_shared, 800), "ws-junk": (c_ws_junk, 1500), "ws-fuzz": (c_ws_fuzz, 500), "tls-junk": (c_tls, 300), "connect-close": (c_idle, 2000)}
def main():
    pid = daemon_pid(); rng = random.Random(7)
    only = sys.argv[1:] or list(CLASSES)
    print("%-14s %6s   %10s %10s   %s" % ("class", "ops", "pass 1", "pass 2", "KB per op (pass 2)"))
    for name in only:
        fn, n = CLASSES[name]
        for _ in range(60):
            try: fn(rng)
            except Exception: pass
        base = rss(pid); res = []
        for p in (1, 2):
            for _ in range(n):
                try: fn(rng)
                except Exception: pass
            now = rss(pid); res.append(now - base); base = now
        print("%-14s %6d   %+8.1f MB %+8.1f MB   %6.1f" % (name, n, res[0], res[1], res[1] * 1024 / n))
main()
