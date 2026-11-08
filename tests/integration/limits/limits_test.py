"""Slow-client and oversize-input defences. Needs a daemon started on this directory's conf
(short timeouts: http read 1.5 s / request 3 s, ws frame 1.5 s / max 4096 bytes).
Every check is something a hostile or broken client can do from the network."""
import os, sys, socket, ssl, struct, time, json, base64, urllib.request, http.client
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from wsclient import connect, send, frames

fails = 0
def check(name, cond, extra=""):
    global fails; print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(extra))); fails += not cond

def raw(port=18080):
    s = socket.create_connection(("127.0.0.1", port)); s.settimeout(0.4); return s

def closed_within(s, secs):
    """True (and what was read) if the server closes the connection within secs."""
    end, got = time.time() + secs, b""
    while time.time() < end:
        try:
            d = s.recv(4096)
            if d == b"": return True, got
            got += d
        except socket.timeout: continue
        except (ConnectionResetError, BrokenPipeError): return True, got
    return False, got

def vdrx_stat(key):
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            if open(f"/proc/{pid}/cmdline", "rb").read().split(b"\0")[0].endswith(b"bin/vdrx"):
                if key == "Threads": return len(os.listdir(f"/proc/{pid}/task"))
                for l in open(f"/proc/{pid}/status"):
                    if l.startswith(key): return int(l.split()[1]) / 1024.0
        except OSError: pass
    return None

def vdrx_vsize_mb():
    """Virtual size (address space reserved) of the daemon. Resident memory would not show a large
    allocation that is never touched, but reserved/committed memory is what a strict-overcommit Linux
    box or Windows counts against the machine."""
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            if open(f"/proc/{pid}/cmdline", "rb").read().split(b"\0")[0].endswith(b"bin/vdrx"):
                for l in open(f"/proc/{pid}/status"):
                    if l.startswith("VmSize"): return int(l.split()[1]) / 1024.0
        except OSError: pass
    return None

def mask_frame(payload, opcode=1, masked=True, declared_len=None):
    n = len(payload) if declared_len is None else declared_len
    b1 = 0x80 if masked else 0
    if n < 126: h = bytes([0x80 | opcode, b1 | n])
    elif n < 65536: h = bytes([0x80 | opcode, b1 | 126]) + struct.pack(">H", n)
    else: h = bytes([0x80 | opcode, b1 | 127]) + struct.pack(">Q", n)
    if not masked: return h + payload
    m = os.urandom(4); return h + m + bytes(b ^ m[i % 4] for i, b in enumerate(payload))

def ws_auth_ok(c):
    send(c, {"method": "sys.auth", "token": "vt"})
    return any(f.get("event") == "auth.ok" for f in frames(c, .6))


def tls_listener_up():
    """True if the TLS port accepts connections. If not, say WHY (the daemon logs the reason) and let the caller skip."""
    try: socket.create_connection(("127.0.0.1", 18443), timeout=3).close(); return True
    except OSError:
        why = ""
        try:
            why = [l for l in open("vdrx_daemon.log", errors="replace") if "NOT started" in l][-1].strip()[-260:]
        except Exception: pass
        print("skip  TLS tests: the TLS listener did not start. " + (why or "See vdrx_daemon.log.") +
              "  (Needs the OpenSSL runtime: libssl.so.3 or libssl.so.1.1.)")
        return False

print("-- HTTP: slow and idle clients")
t = time.time(); s = raw(); ok, _ = closed_within(s, 5)
check("an idle connection (sends nothing) is closed by the server (<5 s)", ok, f"still open after {time.time()-t:.1f} s")

s = raw(); s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n"); t = time.time(); closed = False
while time.time() - t < 7 and not closed:       # one byte every 0.4 s: never idle, never finishing
    try: s.sendall(b"X-a: b\r\n"[int((time.time() - t) / .4) % 8:][:1] or b"x")
    except OSError: closed = True; break
    closed = closed_within(s, .4)[0]
check("a client dribbling a request forever is cut off by the total request timeout (<7 s)", closed, f"{time.time()-t:.1f} s")

s = raw(); s.sendall(b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 9000000\r\n\r\n")
check("a declared 9 MB body that never arrives is abandoned (<5 s)", closed_within(s, 5)[0])

def vsize_cost(request):
    """Virtual size added by 30 simultaneous connections that each send `request` and then wait."""
    time.sleep(2.2)                       # let earlier connections time out and their threads exit
    before = vdrx_vsize_mb(); socks = []
    for i in range(30):
        c = raw(); c.sendall(request); socks.append(c)
    time.sleep(.8); after = vdrx_vsize_mb()
    for c in socks: c.close()
    return None if before is None or after is None else after - before

# Every connection costs a thread (and its stack), so compare against a CONTROL: connections that
# only send a header, vs. connections that also DECLARE a 9 MB body. The difference is what the
# declaration reserved - ~270 MB for 30 connections if the body is allocated up front.
plain = vsize_cost(b"GET / HTTP/1.1\r\nHost: x\r\n")
big = vsize_cost(b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 9000000\r\n\r\n")
if plain is not None and big is not None:
    check("30 connections declaring a 9 MB body reserve no more than 30 that do not (%.0f vs %.0f MB; allowed difference 60)" % (big, plain),
          big - plain < 60, f"{plain:.0f} MB vs {big:.0f} MB")

idle = [raw() for _ in range(50)]
t = time.time(); r = urllib.request.urlopen("http://127.0.0.1:18080/", timeout=4)
check("a normal request is still served in <2 s while 50 idle connections are open", r.status == 200 and time.time() - t < 2, f"{time.time()-t:.1f}s")
for c in idle: c.close()

s = raw(); s.sendall(b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 20000000\r\n\r\n")
check("a body over the 10 MB limit still gets 413", b" 413 " in closed_within(s, 3)[1].split(b"\r\n")[0])

print("-- WebSocket: frames")
c = connect(); c.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
fr = mask_frame(json.dumps({"method": "sys.auth", "token": "vt"}).encode())
try:
    for i in range(len(fr)): c.s.sendall(fr[i:i + 1]); time.sleep(.04)
    got = any(f.get("event") == "auth.ok" for f in frames(c, .8))
except OSError as e: got = f"connection dropped mid-frame: {e}"
check("a frame delivered one byte at a time is still understood (short reads are normal TCP)", got is True, got)

c = connect(); ws_auth_ok(c)
c.s.sendall(mask_frame(b"", declared_len=50 * 1024 * 1024))
check("a header declaring a 50 MB frame is refused at once (limit 4096)", closed_within(c.s, 3)[0])

c = connect(); ws_auth_ok(c)
c.s.sendall(mask_frame(b"x" * 8192))
check("a real 8 KB frame (over the 4096 limit) closes the connection", closed_within(c.s, 3)[0])

c = connect(); ws_auth_ok(c)
c.s.sendall(mask_frame(b"y" * 100, declared_len=100)[:6 + 10])    # header + mask + 10 of 100 bytes, then silence
t = time.time(); ok = closed_within(c.s, 5)[0]
check("a frame that stalls half-way is dropped after the frame timeout (<5 s)", ok, f"{time.time()-t:.1f} s")

c = connect(); ws_auth_ok(c)
c.s.sendall(mask_frame(b'{"method":"x"}', masked=False))
check("an unmasked client frame is refused (RFC 6455 5.1)", closed_within(c.s, 3)[0])

c = connect(); ws_auth_ok(c)
c.s.sendall(mask_frame(b"p" * 200, opcode=9))
check("a ping with a 200-byte payload (control frames are max 125) closes the connection", closed_within(c.s, 3)[0])

c = connect(); check("the daemon still accepts and authenticates new WebSocket clients afterwards", ws_auth_ok(c))

print("-- clients that stop reading (the response must not pin a thread or the file's size in memory)")
BIG = os.path.join("www", "big_test.txt")
import hashlib
blob = b"".join(hashlib.sha256(str(i).encode()).digest() for i in range(12 * 1024 * 1024 // 32))     # 12 MB, not repetitive
open(BIG, "wb").write(blob)
try:
    r = urllib.request.urlopen("http://127.0.0.1:18080/big_test.txt", timeout=20); got = r.read()
    check("a 12 MB file (streamed from disk) arrives intact: Content-Length and SHA-256 match",
          r.headers.get("Content-Length") == str(len(blob)) and hashlib.sha256(got).digest() == hashlib.sha256(blob).digest(), (r.headers.get("Content-Length"), len(got)))
    c = http.client.HTTPConnection("127.0.0.1", 18080, timeout=5); c.request("HEAD", "/big_test.txt"); h = c.getresponse(); hb = h.read(); c.close()
    check("HEAD on it returns the right Content-Length and no body", h.status == 200 and h.getheader("Content-Length") == str(len(blob)) and hb == b"", (h.status, len(hb)))
    base_threads, base_rss = vdrx_stat("Threads"), vdrx_stat("VmRSS")
    stuck = []
    for i in range(30):
        s = socket.create_connection(("127.0.0.1", 18080), timeout=3); s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        s.sendall(b"GET /big_test.txt HTTP/1.1\r\nHost: x\r\n\r\n"); stuck.append(s)             # and never read
    time.sleep(1.0)
    grown = vdrx_stat("VmRSS") - base_rss
    check("30 clients that request a 12 MB file and never read it cost %.0f MB of memory (was ~12 MB each = 360 MB; limit 120)" % grown, grown < 120, grown)
    t = time.time(); r = urllib.request.urlopen("http://127.0.0.1:18080/ok.html" if os.path.exists("www/ok.html") else "http://127.0.0.1:18080/index.html", timeout=5)
    check("a normal request is still served while they hold their connections (%.2f s)" % (time.time() - t), r.status == 200 and time.time() - t < 2)
    end = time.time() + 8
    while time.time() < end and vdrx_stat("Threads") > base_threads + 4: time.sleep(0.25)
    check("they are dropped by the write timeout (2 s) although still connected: threads %d -> %d" % (base_threads, vdrx_stat("Threads")), vdrx_stat("Threads") <= base_threads + 4, vdrx_stat("Threads"))
    for s in stuck: s.close()
finally:
    os.remove(BIG)

print("-- WebSocket subscribers that stop reading are dropped, not kept for ever")
import base64
base_threads = vdrx_stat("Threads"); slow = []
for i in range(5):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 2048); s.connect(("127.0.0.1", 18082)); s.settimeout(2)
    s.sendall(("GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: %s\r\n\r\n" % base64.b64encode(os.urandom(16)).decode()).encode())
    s.recv(4096); from wsclient import C; cc = C(s, b""); send(cc, {"method": "sys.auth", "token": "vt"}); send(cc, {"method": "subscribe", "filter": "demo.>"}); time.sleep(.15); slow.append(s)
feeder = connect(port=18082); send(feeder, {"method": "sys.auth", "token": "ft"}); frames(feeder, .3)
# enough data to fill the kernel socket buffers (they grow on loopback): a client that is merely slow is not
# evicted, only one whose writes actually stall
feeder.s.settimeout(0.02)                      # frames() blocks for the socket timeout when nothing arrives: keep it short
for i in range(9000):
    send(feeder, {"method": "publish", "topic": "demo.flood", "payload": "x" * 3800})
    if i % 500 == 0: frames(feeder, .02)       # a long send must still answer the server's pings, or the feeder is evicted too
time.sleep(4)                                  # > write_timeout_ms (2 s): reading a socket un-stalls it, so give the server time to evict them all BEFORE we start reading any
closed = 0
for s in slow:
    s.settimeout(2); end = time.time() + 14
    try:
        while time.time() < end:
            if s.recv(65536) == b"": closed += 1; break
    except Exception: pass
check("all 5 non-reading subscribers were closed by the server within the write timeout (%d of 5)" % closed, closed == 5, closed)
feeder.s.close(); time.sleep(1.5)
check("and their threads are gone: %d -> %d" % (base_threads, vdrx_stat("Threads")), vdrx_stat("Threads") <= base_threads + 3, vdrx_stat("Threads"))
c = connect(port=18082); send(c, {"method": "sys.auth", "token": "vt"})
check("a new client is served normally afterwards", any(f.get("event") == "auth.ok" for f in frames(c, .6)))

print("-- TLS: handshake stalls")
if os.path.exists("cert.pem") and tls_listener_up():
    stalled = [socket.create_connection(("127.0.0.1", 18443)) for _ in range(6)]
    ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
    t = time.time(); got = None
    try:
        with socket.create_connection(("127.0.0.1", 18443), timeout=12) as raw_s, ctx.wrap_socket(raw_s, server_hostname="localhost") as ts:
            ts.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"); got = ts.recv(200)
    except Exception as e: got = repr(e).encode()
    took = time.time() - t
    check("6 stalled TLS handshakes do not delay a real TLS client (%.1f s, limit 2.5)" % took, got and b" 200 " in got and took < 2.5, got)
    for c in stalled: c.close()
else:
    print("skip  TLS (no cert.pem - openssl was not available)")

print("all passed" if not fails else f"{fails} FAILED"); sys.exit(1 if fails else 0)
