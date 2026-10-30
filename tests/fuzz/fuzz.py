#!/usr/bin/env python3
"""Seeded, mutation-based fuzzer for the HTTP and WebSocket front ends of a RUNNING vdrx
(start it in this directory: tests/fuzz/vdrx.conf).

    python3 fuzz.py [--seed N] [--seconds S] [--threads T] [--target http|ws|all]

The same seed generates the same inputs, so a finding can be replayed. What it checks - not just
"is it still answering", which would have missed the thread leak and the connection-cap bug:
  * the daemon process is alive after every batch, and a canary HTTP request and a canary
    WebSocket login still work
  * threads and memory do not drift (a quiesced daemon returns to its baseline)
  * every HTTP response is well-formed, its Content-Length is honest, and it does not leak
    internals (stack traces, 'Exception', server paths)
  * one connection never yields two responses (request smuggling / pipelining)
  * a WebSocket client that has not authenticated never receives data, and a viewer never receives
    a topic outside demo.>; frames the server sends are valid (FIN, unmasked, JSON text)
  * the daemon log holds no unhandled exception
Exit status 0 = nothing found. Findings are printed and appended to fuzz_findings.jsonl."""
import os, sys, re, time, json, random, socket, struct, base64, argparse, threading, hashlib

HTTP = ("127.0.0.1", 18080)
WSOWN = ("127.0.0.1", 18082)
LEAK_RE = re.compile(rb"Exception|Access violation|Runtime error|EAccess|Traceback|/home/|/tmp/|\\Users\\|SIGSEGV", re.I)
LOG_BAD_RE = re.compile(r"exception|access violation|segmentation|runtime error|sigsegv|unhandled exception", re.I)

findings, flock = [], threading.Lock()
def finding(kind, detail, data=b"", seed=None):
    with flock:
        rec = {"kind": kind, "detail": str(detail)[:300], "seed": seed, "input_hex": data[:4000].hex()}
        findings.append(rec)
        with open("fuzz_findings.jsonl", "a") as f: f.write(json.dumps(rec) + "\n")
        print("FINDING [%s] %s" % (kind, rec["detail"]))

# ---------------------------------------------------------------- daemon stats
def daemon_pid():
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            if open(f"/proc/{pid}/cmdline", "rb").read().split(b"\0")[0].endswith(b"bin/vdrx"): return int(pid)
        except OSError: pass
def stats(pid):
    d = {}
    for l in open(f"/proc/{pid}/status"):
        k, _, v = l.partition(":"); d[k] = v.strip()
    return {"threads": int(d["Threads"]), "rss": int(d["VmRSS"].split()[0]) / 1024.0}

# ---------------------------------------------------------------- HTTP generation
METHODS = ["GET"] * 8 + ["POST"] * 4 + ["HEAD", "OPTIONS", "PUT", "DELETE", "TRACE", "CONNECT", "PATCH", "get", "G ET", "GET\t", "", "A" * 300, "GET/", "\x00GET"]
TARGETS = ["/", "/ok.html", "/index.html", "/nope", "/cgi/trace.py", "/cgi/quick.py", "/cgi/trace.py?a=1&b=%00", "/ws", "/ws?x=1", "/api/sort", "/api/head?n=3",
           "/api/head?n=-5", "/api/head?n=%0a", "/api/grep?pattern=abc", "/api/grep?pattern=-f/etc/passwd", "/api/grep?pattern=%2d%66x", "*", "", " ", "http://x/", "http://x:80/ok.html",
           "//", "/./ok.html", "/%2e%2e/ok.html", "/..%2fok.html", "/%252e%252e/", "/ok.html%00.php", "/ok.html/", "/ok.html/../index.html", "/%c0%af", "/\xff\xfe", "/a" * 600,
           "/" + "A" * 70000, "/?" + "a=b&" * 5000, "/#frag", "/ok.html?x=" + "%41" * 3000, "/cgi/../../etc/passwd", "/vdrx.conf", "/.git/config", "/ok.html:stream", "/ok.html. ", "/\\ok.html",
           "/sub", "/sub?q=1", "/sub%0d%0aX-Injected:%20yes", "/sub\r\nX-Injected: yes", "/%0d%0aX-Injected:%20yes", "/ok.html%0d%0aX-Injected:%20yes",
           "/cgi/trace.py?x=%0d%0aX-Injected:%20yes", "//x.example/%2e%2e", "/sub//", "/sub/.", "/sub/%00"]
VERSIONS = ["HTTP/1.1"] * 8 + ["HTTP/1.0", "HTTP/0.9", "HTTP/2.0", "HTTP/1.2", "HTTP/9.9", "http/1.1", "HTTP/1.1 ", "HTTP/1", "", "HTTPS/1.1", "HTTP/1.1\x00"]
HOSTS = ["Host: x", "Host: 127.0.0.1:18080", "Host: [::1]:80", "Host:", "Host: " + "h" * 5000, "Host: a\x00b", "Host: x\r\nHost: y", "host: x", "HOST : x", "Host: a b"]
SPICE = ["Content-Length: 5", "Content-Length: 0", "Content-Length: -1", "Content-Length: +5", "Content-Length: 0x10", "Content-Length: 1e3", "Content-Length: 99999999999999999999",
         "Content-Length:  5 ", "Content-Length: 5\r\nContent-Length: 6", "Content-Length: 5, 5", "Content-Length: 3\r\nTransfer-Encoding: chunked",
         "Transfer-Encoding: chunked", "Transfer-Encoding: chunked, gzip", "Transfer-Encoding: xchunked", "Transfer-Encoding : chunked", "Expect: 100-continue",
         "Connection: keep-alive", "Connection: close", "Connection: upgrade", "Upgrade: websocket", "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
         "Upgrade: WebSocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: x", "Sec-WebSocket-Key: " + "A" * 4000, "Origin: http://evil.example", "Origin: null",
         "Cookie: " + "a=b; " * 3000, "Authorization: Bearer " + "x" * 3000, "Range: bytes=0-", "Range: bytes=5-1", "Range: bytes=" + "9" * 40 + "-", "If-None-Match: *", "X-Forwarded-For: 1.1.1.1",
         "X_Forwarded_For: 6.6.6.6", "Proxy: http://evil/", "X-Very-Long: " + "v" * 20000, "A" * 300 + ": b", ": empty-name", "NoColonHere", " leading-space: x", "\tfold: x", "X: a\r\n b", "X: a\n b",
         "X-Ctl: a\x01\x02\x7f", "X-Inj: a\r\nX-Injected: yes", "Cookie: a=b\r\nX-Injected: yes", "Host: x\r\nX-Injected: yes", "X-Utf8: \xc3\xa9\xff", "Accept-Encoding: gzip, deflate, br", "Content-Type: multipart/form-data; boundary=" + "-" * 500, "Content-Type: application/json"]
BODIES = [b"", b"hello", b"line1\nline2\n" * 50, bytes(range(256)) * 8, b"\x00" * 3000, os.urandom(2000), b"a=b&c=d", b'{"a":' * 100, b"5\r\nhello\r\n0\r\n\r\n", b"0\r\n\r\n", b"zz\r\nhello\r\n0\r\n\r\n", b"G" * 70000]

def rand_value(rng):
    pool = ["", "1", "-1", "-5", "0", "999999999999", "abc", "-f/etc/passwd", "--help", "-", "--", "a b", "a%20b", "%00", "%0a", "%", "%zz", "%c0%af", "\xff", "é" * 30,
            "A" * rng.choice([100, 5000, 70000]), "$(id)", "`id`", ";id", "|id", "&&id", "\"quoted\"", "'", "\\", "*", "?", "[", "(", "^", "!", "{}", "\n", "\t", "x" * 1 + "\x00"]
    v = rng.choice(pool)
    return "".join(c if c.isalnum() or c in "-._~" else "%%%02X" % ord(c) for c in v.encode("latin-1", "replace").decode("latin-1")) if rng.random() < 0.7 else v

def gen_runner_request(rng):
    route = rng.choice(["/api/head?n=", "/api/grep?pattern=", "/api/sort?x=", "/api/head?n=3&n=", "/api/grep?pattern=a&pattern="])
    body = rng.choice([b"", b"b\na\nc\n", os.urandom(300), b"line\n" * 2000, b"\x00\x00", "é\n".encode()])
    return ("POST %s%s HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n" % (route, rand_value(rng), len(body))).encode("latin-1", "replace") + body

def gen_request(rng):
    if rng.random() < 0.15: return gen_runner_request(rng)
    eol = rng.choice(["\r\n"] * 12 + ["\n", "\r", "\r\n\r\n"])
    line = "%s%s%s%s%s" % (rng.choice(METHODS), rng.choice([" "] * 12 + ["  ", "\t", ""]), rng.choice(TARGETS), rng.choice([" "] * 12 + ["  ", "\t"]), rng.choice(VERSIONS))
    hdrs = [rng.choice(HOSTS)] if rng.random() < 0.9 else []
    for _ in range(rng.choice([0, 1, 2, 3, 5, 8])): hdrs.append(rng.choice(SPICE))
    if rng.random() < 0.05: hdrs = hdrs * rng.choice([10, 100])
    body = rng.choice(BODIES) if rng.random() < 0.5 else b""
    req = (line + eol + eol.join(hdrs) + (eol if hdrs else "") + eol).encode("latin-1", "replace") + body
    if rng.random() < 0.08:                    # pipelined / smuggled second request
        req += b"GET /ok.html?smuggled=1 HTTP/1.1\r\nHost: x\r\n\r\n"
    return req

def mutate(rng, data):
    d = bytearray(data)
    for _ in range(rng.choice([1, 1, 2, 4, 8, 20])):
        if not d: d = bytearray(b"A"); continue
        op, i = rng.randrange(7), rng.randrange(len(d))
        if op == 0: d[i] = rng.randrange(256)
        elif op == 1: del d[i:i + rng.choice([1, 2, 10, 100])]
        elif op == 2: d[i:i] = bytes(rng.randrange(256) for _ in range(rng.choice([1, 4, 32])))
        elif op == 3: d[i:i] = d[max(0, i - 50):i] * rng.choice([2, 10, 100])
        elif op == 4: d = d[:i]
        elif op == 5: d[i:i] = rng.choice([b"\r\n", b"\n", b"\x00", b"%00", b"..", b"\xff\xfe", b"\r\n\r\n"])
        else: d[i] ^= 1 << rng.randrange(8)
    return bytes(d)

def deliver(rng, payload, addr=HTTP):
    """Send payload one of several ways; return what the server answered (bytes), or None on connect failure."""
    try: s = socket.create_connection(addr, timeout=3)
    except OSError: return None
    mode = rng.choice(["once"] * 5 + ["half"] * 5 + ["split", "split", "reset", "dribble"])
    got = b""
    try:
        s.settimeout(1.0)
        if mode in ("once", "half", "reset"): s.sendall(payload)
        elif mode == "split":
            cuts = sorted(rng.sample(range(1, max(2, len(payload))), min(3, max(1, len(payload) - 1))))
            prev = 0
            for c in cuts + [len(payload)]: s.sendall(payload[prev:c]); prev = c; time.sleep(0.01)
        else:
            for b in payload[:200]: s.sendall(bytes([b])); time.sleep(0.002)
        if mode == "reset":
            s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0)); s.close(); return b""
        if mode in ("half", "split"): s.shutdown(socket.SHUT_WR)
        end = time.time() + (2.5 if mode in ("once", "dribble") else 3.5)
        while time.time() < end and len(got) < 300000:
            try:
                d = s.recv(65536)
                if not d: break
                got += d
            except socket.timeout:
                if mode in ("once", "dribble"): break
    except OSError: pass
    finally:
        try: s.close()
        except OSError: pass
    return got

STATUS_RE = re.compile(rb"^HTTP/1\.[01] (\d{3}) [^\r\n]*\r\n")
def check_response(req, resp, seed):
    if not resp: return
    if len(re.findall(rb"(?:^|\r\n)HTTP/1\.[01] \d{3} ", resp)) > 1 and not req.startswith(b"HEAD"):
        # a second status line is only legitimate inside a body (an echoed request); look at the header block only
        pass
    m = STATUS_RE.match(resp)
    if not m: finding("http-malformed-status-line", resp[:80], req, seed); return
    head, sep, body = resp.partition(b"\r\n\r\n")
    if not sep: finding("http-no-header-terminator", resp[:120], req, seed); return
    lines = head.split(b"\r\n")[1:]
    for l in lines:
        if b":" not in l or re.search(rb"[\x00-\x08\x0a-\x1f\x7f]", l): finding("http-bad-header-line", l[:100], req, seed); return
    if any(l.lower().startswith(b"x-injected") for l in lines): finding("http-response-header-injection", "an X-Injected header the request tried to plant is in the response", req, seed)
    cl = [l for l in lines if l.lower().startswith(b"content-length:")]
    if len(cl) > 1: finding("http-duplicate-content-length-in-response", cl, req, seed)
    if cl and not req.startswith(b"HEAD"):
        try:
            n = int(cl[0].split(b":", 1)[1])
            if n != len(body) and len(resp) < 299000: finding("http-content-length-mismatch", "declared %d, body %d" % (n, len(body)), req, seed)
        except ValueError: finding("http-bad-content-length-in-response", cl[0], req, seed)
    if m.group(1)[:1] in (b"4", b"5") and LEAK_RE.search(body[:2000]): finding("http-error-page-leaks-internals", body[:200], req, seed)
    # smuggling invariant: the server answers ONE request per connection
    if re.search(rb"smuggled=1", req) and len(re.findall(rb"\r\nHTTP/1\.[01] \d{3} ", resp)) >= 1 and b"smuggled=1" not in req.split(b"\r\n")[0]:
        # the pipelined 2nd request must not have been answered as its own response
        if resp.count(b"HTTP/1.1 200") + resp.count(b"HTTP/1.1 404") > 1: finding("http-pipelined-request-answered", resp[:200], req, seed)

# ---------------------------------------------------------------- WebSocket
def ws_frame(opcode, payload, fin=True, masked=True, rsv=0, declared=None):
    n = len(payload) if declared is None else declared
    b0 = (0x80 if fin else 0) | (rsv << 4) | (opcode & 0xF)
    b1 = 0x80 if masked else 0
    if n < 126: h = bytes([b0, b1 | n])
    elif n < 65536: h = bytes([b0, b1 | 126]) + struct.pack(">H", n)
    else: h = bytes([b0, b1 | 127]) + struct.pack(">Q", n)
    if not masked: return h + payload
    m = os.urandom(4); return h + m + bytes(b ^ m[i % 4] for i, b in enumerate(payload))

def rj(rng, depth=0):
    c = rng.randrange(9) if depth < 4 else rng.choice([0, 1, 2, 5])     # no more nesting past depth 4
    if c == 0: return rng.choice(["", "x", "demo.x", "demo.>", ">", "*", "sys.quit", "sys.>", "a..b", "\x00", "é" * 50, "A" * rng.choice([100, 5000, 70000])])
    if c == 1: return rng.choice([0, -1, 1, 2 ** 31, 2 ** 63, 1.5e300, 0.1])
    if c == 2: return rng.choice([True, False, None])
    if c == 3: return [rj(rng, depth + 1) for _ in range(rng.choice([0, 1, 3, 50]))]
    if c == 4: return {rng.choice(["method", "topic", "payload", "token", "filter", "profile", "x"]): rj(rng, depth + 1) for _ in range(rng.choice([0, 1, 3]))}
    return rng.choice(["vt", "ft", "demo.a", "demo.>", "sys.quit"])

def ws_payload(rng, authed_as):
    kind = rng.randrange(8)
    if kind == 0: o = {"method": "sys.auth", "token": rng.choice(["vt", "ft", "wrong", rj(rng)]), "profile": rng.choice([None, "viewer", "feeder", rj(rng)])}
    elif kind == 1: o = {"method": "subscribe", "filter": rng.choice(["demo.>", ">", "", "sys.>", "demo.*", rj(rng)])}
    elif kind == 2: o = {"method": "unsubscribe", "filter": rj(rng)}
    elif kind == 3: o = {"method": "publish", "topic": rng.choice(["demo.x", "sys.quit", "sys.reload", "jobs.run", "", ">", rj(rng)]), "payload": rj(rng)}
    elif kind == 4: o = rj(rng)
    elif kind == 5: return os.urandom(rng.choice([0, 1, 10, 200]))
    elif kind == 6: return bytes(json.dumps(rj(rng)), "utf-8", "replace") + rng.choice([b"", b"}", b"\x00", b"\xff"])
    else: o = {"method": rng.choice(["sys.auth", "subscribe", "publish", "ping", "sys.quit", "", None, 5]), **({"topic": "demo.x"} if rng.random() < .5 else {})}
    try: return json.dumps(o).encode("utf-8", "replace")
    except Exception: return b"{}"

def parse_server_frames(buf, seed, sent):
    """Validate the frames the server sent; return list of decoded JSON objects."""
    out, i = [], 0
    while i + 2 <= len(buf):
        b0, b1 = buf[i], buf[i + 1]; op, n, j = b0 & 0xF, b1 & 0x7F, i + 2
        if b1 & 0x80: finding("ws-server-frame-masked", buf[i:i + 20].hex(), sent, seed); return out
        if b0 & 0x70: finding("ws-server-frame-rsv-bits", hex(b0), sent, seed)
        if n == 126:
            if j + 2 > len(buf): break
            n = struct.unpack(">H", buf[j:j + 2])[0]; j += 2
        elif n == 127:
            if j + 8 > len(buf): break
            n = struct.unpack(">Q", buf[j:j + 8])[0]; j += 8
        if j + n > len(buf): break
        p = buf[j:j + n]; i = j + n
        if op == 1:
            if not (b0 & 0x80): finding("ws-server-fragmented-text", "", sent, seed)
            try: out.append(json.loads(p.decode("utf-8")))
            except Exception: finding("ws-server-text-not-json", p[:100], sent, seed)
        elif op not in (8, 9, 10): finding("ws-server-odd-opcode", op, sent, seed)
    return out

def junk_handshake(rng, seed):
    """A WebSocket handshake that is wrong in some way (or no handshake at all), sent to the WS port
    or to the shared /ws path. A failed handshake used to leave a thread behind for every attempt."""
    key = base64.b64encode(os.urandom(16)).decode()
    good = ("GET %s HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: %s\r\n\r\n"
            % (rng.choice(["/", "/ws"]), key)).encode()
    kind = rng.randrange(6)
    if kind == 0: req = mutate(rng, good)
    elif kind == 1: req = gen_request(rng)
    elif kind == 2: req = good.replace(b"Sec-WebSocket-Key", rng.choice([b"X-Key", b"sec-websocket-key ", b"Sec-WebSocket-Key:"]))
    elif kind == 3: req = good.replace(b"Upgrade", rng.choice([b"Upgrad", b"Uprade", b"X"]))
    elif kind == 4: req = os.urandom(rng.choice([1, 20, 300, 3000]))
    else: req = good[:rng.randrange(1, len(good))]
    addr = rng.choice([WSOWN, WSOWN, HTTP])
    resp = deliver(rng, req, addr)
    if resp: check_response(req, resp, seed)

def ws_session(rng, seed):
    if rng.random() < 0.35: junk_handshake(rng, seed); return
    shared = rng.random() < 0.5
    addr, path = (HTTP, "/ws") if shared else (WSOWN, "/")
    try: s = socket.create_connection(addr, timeout=3)
    except OSError: return
    try:
        s.settimeout(0.6)
        hs = ("GET %s HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: %s\r\n%s\r\n" %
              (path, base64.b64encode(os.urandom(16)).decode(), rng.choice(["", "Origin: http://x\r\n", "Origin: http://evil.example\r\n", "Origin: null\r\n"]))).encode()
        s.sendall(hs); head = b""
        while b"\r\n\r\n" not in head and len(head) < 8192:
            d = s.recv(4096)
            if not d: return
            head += d
        head, _, rest = head.partition(b"\r\n\r\n")
        if b" 101 " not in head.split(b"\r\n")[0]: return
        sent, buf, authed = b"", rest, None
        for _ in range(rng.choice([1, 2, 4, 8, 16])):
            payload = ws_payload(rng, authed)
            op = rng.choice([1] * 12 + [0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15])
            kw = dict(fin=rng.random() < 0.85, masked=rng.random() < 0.93, rsv=rng.choice([0] * 20 + [1, 2, 4, 7]))
            if rng.random() < 0.05: kw["declared"] = rng.choice([0, len(payload) + 5, 2 ** 20, 70000])
            if rng.random() < 0.1 and payload:
                # fragmented message: first part FIN=0, continuation(s) after
                a = rng.randrange(len(payload)); frames = [ws_frame(1, payload[:a], fin=False), ws_frame(0, payload[a:], fin=True)]
                if rng.random() < .3: frames.insert(1, ws_frame(9, b"mid", fin=True))
            else: frames = [ws_frame(op, payload, **kw)]
            for fr in frames:
                if b'"token": "vt"' in payload and op == 1: authed = "viewer"
                sent += fr
                try:
                    if rng.random() < 0.1:
                        for k in range(0, len(fr), 3): s.sendall(fr[k:k + 3]); time.sleep(0.001)
                    else: s.sendall(fr)
                except OSError: break
            try:
                while True:
                    d = s.recv(65536)
                    if not d: break
                    buf += d
            except (socket.timeout, OSError): pass
        objs = parse_server_frames(buf, seed, sent)
        for o in objs:
            if isinstance(o, dict) and "topic" in o and "event" not in o:      # "event" frames (denied, auth.*) are notices, not data
                if authed is None: finding("ws-data-before-auth", json.dumps(o)[:150], sent, seed)
                elif not str(o["topic"]).startswith("demo."): finding("ws-viewer-got-foreign-topic", o.get("topic"), sent, seed)
    except OSError: pass
    finally:
        try: s.close()
        except OSError: pass

# ---------------------------------------------------------------- canaries + main
def canary(pid):
    try:
        s = socket.create_connection(HTTP, timeout=3); s.sendall(b"GET /ok.html HTTP/1.1\r\nHost: x\r\n\r\n"); s.settimeout(3)
        d = b""
        while b"</p>" not in d:
            c = s.recv(4096)
            if not c: break
            d += c
        s.close()
        if b" 200 " not in d.split(b"\r\n")[0]: return "HTTP canary answered: " + d[:60].decode("latin1")
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "integration"))
        from wsclient import connect, send, frames
        c = connect(port=18082); send(c, {"method": "sys.auth", "token": "vt"})
        if not any(f.get("event") == "auth.ok" for f in frames(c, .6)): return "WS canary: login failed"
        c.s.close()
    except Exception as e: return "canary exception: %r" % (e,)
    return None

def tls_junk(rng):
    """Garbage and half-finished handshakes on the TLS port (only when the fixture has a cert)."""
    try: s = socket.create_connection(("127.0.0.1", 18443), timeout=2)
    except OSError: return
    try:
        s.settimeout(0.5)
        hello = bytes.fromhex("1603010200010001fc0303") + os.urandom(32) + bytes.fromhex("00")
        kind = rng.randrange(6)
        if kind == 0: s.sendall(os.urandom(rng.choice([1, 5, 50, 800])))
        elif kind == 1: s.sendall(hello[:rng.randrange(1, len(hello))])
        elif kind == 2: s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")          # plain HTTP to a TLS port
        elif kind == 3: s.sendall(hello + os.urandom(600))
        elif kind == 4: s.sendall(bytes([0x16, 0x03, 0x01, 0xff, 0xff]) + os.urandom(200))   # record claiming 65 KB
        else: pass                                                                  # connect and say nothing
        try: s.recv(4096)
        except OSError: pass
    except OSError: pass
    finally: s.close()

def storm(rng):
    """Hold many connections open at once (more than the caps), then drop them all together."""
    socks = []
    for _ in range(rng.choice([150, 260, 400])):
        try: socks.append(socket.create_connection(rng.choice([HTTP, WSOWN]), timeout=1))
        except OSError: break
    time.sleep(0.5)
    for s in socks:
        try: s.close()
        except OSError: pass

def worker(deadline, seed, which, counters, lock):
    rng = random.Random(seed)
    while time.time() < deadline:
        if rng.random() < 0.04 and os.path.exists("cert.pem"): tls_junk(rng); continue
        if rng.random() < 0.004: storm(rng); continue
        if which == "ws" or (which == "all" and rng.random() < 0.3):
            ws_session(rng, seed);
            with lock: counters["ws"] += 1
        else:
            req = gen_request(rng)
            if rng.random() < 0.5: req = mutate(rng, req)
            resp = deliver(rng, req)
            if resp is None:
                with lock: counters["refused"] += 1
            else:
                check_response(req, resp, seed)
            with lock: counters["http"] += 1

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1); ap.add_argument("--seconds", type=int, default=30)
    ap.add_argument("--threads", type=int, default=6); ap.add_argument("--target", default="all", choices=["http", "ws", "all"])
    a = ap.parse_args()
    pid = daemon_pid()
    if not pid: print("no vdrx daemon running (start bin/vdrx in tests/fuzz)"); return 2
    err = canary(pid)
    if err: print("daemon not healthy before fuzzing:", err); return 2
    log_before = os.path.getsize("vdrx_daemon.log") if os.path.exists("vdrx_daemon.log") else 0
    time.sleep(1); base = stats(pid)
    print("seed=%d seconds=%d threads=%d target=%s  baseline: %d threads, %.0f MB" % (a.seed, a.seconds, a.threads, a.target, base["threads"], base["rss"]))
    counters, lock = {"http": 0, "ws": 0, "refused": 0}, threading.Lock()
    end = time.time() + a.seconds; round_no = 0
    while time.time() < end:
        round_no += 1
        slice_end = min(end, time.time() + 8)
        ts = [threading.Thread(target=worker, args=(slice_end, a.seed * 1000 + round_no * 50 + i, a.target, counters, lock)) for i in range(a.threads)]
        for t in ts: t.start()
        for t in ts: t.join()
        if daemon_pid() != pid: finding("daemon-died", "process %d is gone after round %d" % (pid, round_no), b"", a.seed); break
        time.sleep(2.5)                                    # quiesce: timeouts fire, connections wind down
        err = canary(pid)
        if err: finding("canary-failed", err, b"", a.seed)
        st = stats(pid)
        if st["threads"] > base["threads"] + 10: finding("thread-drift", "%d threads (baseline %d) after round %d" % (st["threads"], base["threads"], round_no), b"", a.seed)
        if st["rss"] > base["rss"] + 80: finding("memory-drift", "%.0f MB (baseline %.0f) after round %d" % (st["rss"], base["rss"], round_no), b"", a.seed)
        print("round %2d: %5d http, %4d ws sessions | daemon %d threads, %.0f MB" % (round_no, counters["http"], counters["ws"], st["threads"], st["rss"]))
    if os.path.exists("vdrx_daemon.log"):
        with open("vdrx_daemon.log", errors="replace") as f:
            f.seek(log_before); bad = [l for l in f if LOG_BAD_RE.search(l)]
        for l in bad[:5]: finding("daemon-log-exception", l.strip()[:250], b"", a.seed)
        if len(bad) > 5: print("... and %d more log lines like it" % (len(bad) - 5))
    print("done: %d findings" % len(findings)); return 1 if findings else 0
if __name__ == "__main__": sys.exit(main())
