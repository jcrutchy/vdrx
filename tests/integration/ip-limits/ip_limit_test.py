#!/usr/bin/env python3
"""Per-address connection limits, end to end. Run by tests/integration/run.sh (section ip-limits) against the
fixture in this folder. 127.0.0.2 is a second client address: on Linux every 127.x.y.z is loopback."""
import socket, sys, time
sys.path.insert(0, "..")
from wsclient import open_ws

passed = failed = 0
def check(cond, name, extra=""):
    global passed, failed
    if cond: passed += 1; print("  ok    " + name)
    else:    failed += 1; print("  FAIL  " + name + ("  (" + extra + ")" if extra else ""))

def dial(port, src="127.0.0.1"):
    s = socket.socket(); s.settimeout(2)
    s.bind((src, 0)); s.connect(("127.0.0.1", port)); return s

def served(port, src="127.0.0.1"):
    """One GET. True = a 200 came back, False = the server closed on us without answering."""
    try:
        s = dial(port, src)
        s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        d = b""
        while True:
            c = s.recv(4096)
            if not c: break
            d += c
        s.close()
        return d.startswith(b"HTTP/1.1 200")
    except (ConnectionError, socket.timeout, OSError):
        return False

def closed_by_server(s):
    """True if the peer closes without sending anything (how a refused connection looks)."""
    try:
        s.settimeout(1.5); return s.recv(1) == b""
    except socket.timeout: return False
    except ConnectionError: return True

print("-- concurrent connections per address (limit 3)")
held = [dial(18091) for _ in range(3)]          # idle connections: they occupy their slots
time.sleep(0.3)
extra = dial(18091)
check(closed_by_server(extra), "the 4th concurrent connection from one address is closed at once")
check(served(18091, "127.0.0.2"), "a different address is still served while the first is at its limit")
held.pop().close()
time.sleep(0.5)
check(served(18091), "closing one connection frees a slot")
for s in held: s.close()
time.sleep(0.3)

print("-- rate of new connections per address (2/s, burst 3)")
res = [served(18093) for _ in range(12)]
n = sum(res)
check(3 <= n <= 5, "a burst of 12 requests gets about Burst (3) through, got %d" % n, str(res))
time.sleep(2.5)
check(served(18093), "after a pause the address is served again")
check(served(18093, "127.0.0.2"), "another address has its own bucket")

print("-- exempt address (limit 1, 127.0.0.1 exempt)")
many = [dial(18094) for _ in range(5)]
time.sleep(0.3)
check(not closed_by_server(many[-1]), "exempt address may hold more than the limit")
for s in many: s.close()
a = dial(18094, "127.0.0.2"); time.sleep(0.2)
b = dial(18094, "127.0.0.2")
check(closed_by_server(b), "a non-exempt address is still limited")
a.close(); b.close()

print("-- live WebSocket connections per address (limit 2)")
w1, h1, _ = open_ws(port=18092)
w2, h2, _ = open_ws(port=18092)
w3, h3, _ = open_ws(port=18092)
st = [h.split(b"\r\n")[0] for h in (h1, h2, h3)]
check(b" 101 " in st[0] and b" 101 " in st[1], "the first two upgrade")
check(b" 503 " in st[2] or h3 == b"", "the third is refused", repr(st[2]))
w1.close(); time.sleep(0.8)
w4, h4, _ = open_ws(port=18092)
check(b" 101 " in h4.split(b"\r\n")[0], "closing one frees a live slot")
other, ho, _ = open_ws(port=18092, sock=(lambda s: (s.bind(("127.0.0.2", 0)), s.connect(("127.0.0.1", 18092)), s)[2])(socket.socket()))
check(b" 101 " in ho.split(b"\r\n")[0], "a different address can upgrade")
for s in (w2, w3, w4, other): s.close()

print("-- the refusals are logged")
time.sleep(0.5)
log = open("vdrx_daemon.log", errors="replace").read()
check("refused connections" in log, "a 'refused connections' warning is in the log")

print("\n%d passed, %d failed" % (passed, failed))
print("all passed" if failed == 0 else "SOME FAILED")
sys.exit(1 if failed else 0)
