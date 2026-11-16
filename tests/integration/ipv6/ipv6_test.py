#!/usr/bin/env python3
"""IPv6 and dual-stack listeners. Run by tests/integration/run.sh (section ipv6) against the fixture in this folder.
Hosts without IPv6 (some containers) can only run the first part: bad bind addresses are refused, a bind that cannot
be honoured fails closed, and nothing else is taken down with it. The rest is reported as skipped."""
import socket, sys, time, os

HERE = os.path.dirname(os.path.abspath(__file__))
passed = failed = skipped = 0
def check(cond, name, extra=""):
    global passed, failed
    if cond: passed += 1; print("  ok    " + name)
    else:    failed += 1; print("  FAIL  " + name + ("  (" + str(extra)[:200] + ")" if extra else ""))
def skip(name):
    global skipped
    skipped += 1; print("  skip  " + name)

def have_ipv6():
    try:
        s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM); s.bind(("::1", 0)); s.close(); return True
    except OSError: return False
V6 = have_ipv6()

def talk(host, port, raw=b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", wait=1.5):
    fam = socket.AF_INET6 if ":" in host else socket.AF_INET
    s = socket.socket(fam); s.settimeout(0.4)
    try: s.connect((host, port))
    except OSError as e: return None
    s.sendall(raw); out = b""; end = time.time() + wait
    while time.time() < end:
        try:
            d = s.recv(65536)
            if not d: break
            out += d
        except socket.timeout: pass
    s.close(); return out

def dial(host, port):
    s = socket.socket(socket.AF_INET6 if ":" in host else socket.AF_INET); s.settimeout(2); s.connect((host, port)); return s
def closed_by_server(s):
    try: s.settimeout(1.5); return s.recv(1) == b""
    except socket.timeout: return False
    except ConnectionError: return True

log = lambda: open(os.path.join(HERE, "vdrx_daemon.log"), errors="replace").read()

print("-- the IPv4 control site is unaffected by the others")
r = talk("127.0.0.1", 18103)
check(r is not None and b"hello" in r, "an IPv4 site serves while neighbouring IPv6 sites are broken or absent")

print("-- bad bind addresses are refused, loudly")
check(talk("127.0.0.1", 18104) is None, "bind \"::zz\": nothing listens on that port")
check(talk("127.0.0.1", 18105) is None, "bind \"::ffff:1.2.3.4\": nothing listens on that port")
time.sleep(0.5); lg = log()
check("invalid bind address" in lg and "::zz" in lg, "the invalid address is named in the log")
check("IPv4-mapped" in lg, "the mapped address is refused with an explanation")

if not V6:
    print("-- this host has no IPv6")
    check("cannot create an IPv6 socket" in lg or "fpBind failed" in lg, "bind \"::1\" without IPv6 fails closed with a clear error")
    check(talk("127.0.0.1", 18106) is None and talk("127.0.0.1", 18107) is None, "...and nothing answers on those ports")
    for n in ("IPv6 loopback site serves over ::1", "dual-stack site serves IPv4 and IPv6", "IPv4 clients of a dual-stack socket are reported and limited as plain IPv4",
              "an IPv6 /64 shares one connection limit", "limit_exempt works with IPv6 ranges"):
        skip(n)
else:
    print("-- IPv6 loopback")
    r = talk("::1", 18106)
    check(r is not None and b"hello" in r, "a site bound to ::1 serves over IPv6")
    check(talk("127.0.0.1", 18106) is None, "...and is not reachable over IPv4")

    print("-- dual stack (bind \"::\")")
    r6 = talk("::1", 18107); r4 = talk("127.0.0.1", 18107)
    check(r6 is not None and b"hello" in r6, "an IPv6 client is served")
    check(r4 is not None and b"hello" in r4, "an IPv4 client is served by the same socket")

    print("-- the IPv4 client of a dual-stack socket is an IPv4 client")
    held = [dial("127.0.0.1", 18107) for _ in range(2)]; time.sleep(0.3)
    third = dial("127.0.0.1", 18107)
    check(closed_by_server(third), "max_connections_per_ip applies to it (3rd concurrent from 127.0.0.1 closed)")
    for s in held: s.close()
    time.sleep(0.3)
    held6 = [dial("::1", 18107) for _ in range(2)]; time.sleep(0.3)
    third6 = dial("::1", 18107)
    check(closed_by_server(third6), "and to an IPv6 client (3rd concurrent from ::1 closed)")
    for s in held6: s.close()

    print("-- exempt ranges accept both families (limit 1, 127.0.0.1 and ::1 exempt)")
    a = [dial("127.0.0.1", 18109) for _ in range(4)]; time.sleep(0.3)
    check(not closed_by_server(a[-1]), "an exempt IPv4 client is never limited on a dual-stack socket")
    for s in a: s.close()
    b = [dial("::1", 18109) for _ in range(4)]; time.sleep(0.3)
    check(not closed_by_server(b[-1]), "an exempt IPv6 client is never limited")
    for s in b: s.close()

    print("-- what an upstream is told")
    for _ in range(40):
        if talk("127.0.0.1", 18107, b"GET /app/ready HTTP/1.1\r\nHost: x\r\n\r\n", 1): break
        time.sleep(.5)
    open(os.path.join(HERE, "received18108.log"), "wb").close()
    talk("127.0.0.1", 18109, b"GET /app/x HTTP/1.1\r\nHost: x\r\n\r\n")
    up = open(os.path.join(HERE, "received18108.log"), "rb").read().decode("latin1")
    check("X-Forwarded-For: 127.0.0.1\r\n" in up, "an IPv4 client arriving over the dual-stack socket is reported as 127.0.0.1, not ::ffff:127.0.0.1", up[:300])
    open(os.path.join(HERE, "received18108.log"), "wb").close()
    talk("::1", 18109, b"GET /app/x HTTP/1.1\r\nHost: x\r\n\r\n")
    up = open(os.path.join(HERE, "received18108.log"), "rb").read().decode("latin1")
    check("X-Forwarded-For: ::1\r\n" in up, "an IPv6 client is reported in IPv6 text", up[:300])
    skip("an IPv6 /64 shares one connection limit (needs a second address in the same /64; covered by the unit tests)")

print("\n%d passed, %d failed, %d skipped" % (passed, failed, skipped))
print("all passed" if failed == 0 else "SOME FAILED")
sys.exit(1 if failed else 0)
