"""WebSocket on the HTTP port (websocket_path) and everything that must hold on BOTH ports:
Origin check, live-connection cap, no leak from failed handshakes, shared lockout, frame limits, wss."""
import os, sys, socket, ssl, time, struct, base64
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from wsclient import connect, open_ws, send, frames

fails = 0
SHARED, OWN, TLS = 18080, 18082, 18443
def check(name, cond, extra=""):
    global fails; print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(extra))); fails += not cond
def status(head): return head.split(b"\r\n")[0].decode("latin1")
def ev(fr, e): return [f for f in fr if f.get("event") == e]
def auth(c, tok): send(c, {"method": "sys.auth", "token": tok}); return ev(frames(c, .5), "auth.ok")
def closed_within(s, secs):
    end = time.time() + secs
    while time.time() < end:
        try:
            if s.recv(4096) == b"": return True
        except socket.timeout: continue
        except (ConnectionResetError, BrokenPipeError): return True
    return False
def vdrx_threads():
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            if open(f"/proc/{pid}/cmdline", "rb").read().split(b"\0")[0].endswith(b"bin/vdrx"):
                for l in open(f"/proc/{pid}/status"):
                    if l.startswith("Threads"): return int(l.split()[1])
        except OSError: pass


def tls_listener_up():
    """True if the TLS port accepts connections. If not, say WHY (the daemon logs the reason) and let the caller skip."""
    try: socket.create_connection(("127.0.0.1", TLS), timeout=3).close(); return True
    except OSError:
        why = ""
        try:
            why = [l for l in open("vdrx_daemon.log", errors="replace") if "NOT started" in l][-1].strip()[-260:]
        except Exception: pass
        print("skip  TLS tests: the TLS listener did not start. " + (why or "See vdrx_daemon.log.") +
              "  (Needs the OpenSSL runtime: libssl.so.3 or libssl.so.1.1.)")
        return False

print("-- shared port: the upgrade is served on the HTTP port")
v = connect(port=SHARED, path="/ws"); f = connect(port=SHARED, path="/ws")
check("a WebSocket upgrade on the HTTP port at /ws gets 101 and a working socket", auth(v, "vt") and auth(f, "ft"))
send(v, {"method": "subscribe", "filter": "demo.>"}); frames(v, .3)
send(f, {"method": "publish", "topic": "demo.x", "payload": "hello over the shared port"})
check("publish -> subscribe round trip over the shared port", [m for m in frames(v, .6) if m.get("topic") == "demo.x"])
v.s.close(); f.s.close()

s, head, _ = open_ws(port=SHARED, path="/other"); s.close()
check("an upgrade for a DIFFERENT path is not a WebSocket (normal HTTP answer)", b" 101 " not in head.split(b"\r\n")[0], status(head))
s, head, _ = open_ws(port=SHARED, path="/ws?x=1"); s.close()
check("the query string does not defeat the path match (/ws?x=1 upgrades)", b" 101 " in head.split(b"\r\n")[0], status(head))
s, head, _ = open_ws(port=SHARED, path="/ws/", headers={"Upgrade": None, "Connection": "close"}); s.close()
check("a plain GET on the path (no Upgrade header) is ordinary HTTP, not 426/101", b" 101 " not in status(head).encode() and b" 426 " not in status(head).encode(), status(head))
s, head, _ = open_ws(port=SHARED, path="/ws", key=False); s.close()
check("an upgrade without Sec-WebSocket-Key is refused with 426", b" 426 " in status(head).encode(), status(head))
s, head, _ = open_ws(port=SHARED, path="/ws", version="8"); s.close()
check("an unsupported Sec-WebSocket-Version is refused with 426", b" 426 " in status(head).encode() and b"Sec-WebSocket-Version: 13" in head, status(head))
s, head, _ = open_ws(port=SHARED, path="/ws", headers={"Connection": "close"}); s.close()
check("Upgrade header without 'Connection: Upgrade' is refused with 426", b" 426 " in status(head).encode(), status(head))

print("-- Origin check (browsers only), on both ports")
for port, path, label in ((SHARED, "/ws", "shared"), (OWN, "/", "own")):
    s, head, _ = open_ws(port=port, path=path, headers={"Origin": "http://evil.example"}); s.close()
    check(f"[{label}] a page from another site (Origin evil.example) is refused with 403", b" 403 " in status(head).encode(), status(head))
    s, head, _ = open_ws(port=port, path=path, headers={"origin": "http://evil.example"}); s.close()
    check(f"[{label}] header name case does not matter (lowercase 'origin:')", b" 403 " in status(head).encode(), status(head))
    s, head, _ = open_ws(port=port, path=path, headers={"Origin": "null"}); s.close()
    check(f"[{label}] Origin 'null' (sandboxed/file page) is refused", b" 403 " in status(head).encode(), status(head))
    s, head, _ = open_ws(port=port, path=path, headers={"Origin": "http://x:8081"}); s.close()
    check(f"[{label}] a page from the same HOST on another port is accepted (Host: x, Origin x:8081)", b" 101 " in status(head).encode(), status(head))
    s, head, _ = open_ws(port=port, path=path, headers={"Origin": "https://dash.corp.example"}); s.close()
    check(f"[{label}] an origin listed in allowed_origins is accepted", b" 101 " in status(head).encode(), status(head))
    c = connect(port=port, path=path); check(f"[{label}] a client with no Origin header (not a browser) is accepted", auth(c, "vt")); c.s.close()

print("-- failed handshakes do not leak (one thread each, before the fix)")
time.sleep(1); base = vdrx_threads()
for i in range(100):
    s = socket.create_connection(("127.0.0.1", OWN)); s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n"); s.close()
for i in range(60):
    s, head, _ = open_ws(port=SHARED, path="/ws", headers={"Origin": "http://evil.example"}); s.close()
for i in range(60):
    s, head, rest = open_ws(port=SHARED, path="/ws"); s.close()          # a good upgrade, dropped at once
time.sleep(2.5); after = vdrx_threads()
if base is not None:
    check("220 junk / refused / dropped connections leave the thread count flat (%d -> %d)" % (base, after), after - base <= 6, f"{base} -> {after}")

print("-- connection cap (max_connections = 4) counts LIVE WebSocket connections on both ports")
live = []
for port, path in ((SHARED, "/ws"), (OWN, "/"), (SHARED, "/ws"), (OWN, "/")):
    c = connect(port=port, path=path); live.append(c); auth(c, "vt")
s, head, _ = open_ws(port=SHARED, path="/ws"); s.close()
check("the 5th connection (shared port) is refused with 503", b" 503 " in status(head).encode(), status(head))
s, head, _ = open_ws(port=OWN, path="/"); s.close()
check("the 6th connection (own port) is refused too: one cap across both ports", b" 503 " in status(head).encode(), status(head))
live[0].s.close(); time.sleep(1.2)
c = connect(port=SHARED, path="/ws"); check("closing one frees a slot", auth(c, "vt")); live.append(c)
for c in live: c.s.close()
time.sleep(1.2)

print("-- frame limits apply on the shared port")
c = connect(port=SHARED, path="/ws"); auth(c, "vt")
m = os.urandom(4); body = b"x" * 8192
c.s.sendall(bytes([0x81, 0x80 | 126]) + struct.pack(">H", len(body)) + m + bytes(b ^ m[i % 4] for i, b in enumerate(body)))
check("an 8 KB frame (limit 4096) closes the connection", closed_within(c.s, 3))

print("-- wss: the same upgrade over TLS on the HTTP site")
if os.path.exists("cert.pem") and tls_listener_up():
    ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
    raw = socket.create_connection(("127.0.0.1", TLS), timeout=5)
    ts = ctx.wrap_socket(raw, server_hostname="localhost")
    ts, head, rest = open_ws(sock=ts, path="/ws")
    check("wss: the upgrade on the TLS port gets 101", b" 101 " in status(head).encode(), status(head))
    p = b'{"method":"sys.auth","token":"vt"}'; m = os.urandom(4)
    ts.sendall(bytes([0x81, 0x80 | len(p)]) + m + bytes(b ^ m[i % 4] for i, b in enumerate(p)))
    data = rest; end = time.time() + 2
    while b"auth.ok" not in data and time.time() < end:
        try: data += ts.recv(4096)
        except socket.timeout: pass
    check("wss: sys.auth works over the TLS connection", b"auth.ok" in data, data[:80])
    ts.close()
else:
    print("skip  wss (no cert.pem - openssl was not available)")

print("-- lockout is shared by both ports (it belongs to the WebSocket executive)")
for i in range(8):
    c = connect(port=SHARED, path="/ws"); auth(c, "wrong%d" % i); c.s.close()
c = connect(port=OWN, path="/"); r = auth(c, "vt")
check("8 failed logins over the shared port lock out the address on the own port too", not r)

print("all passed" if not fails else f"{fails} FAILED"); sys.exit(1 if fails else 0)
