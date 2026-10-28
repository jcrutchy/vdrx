#!/usr/bin/env python3
"""Minimal WebSocket client helpers (standard library only) shared by the integration tests."""
import socket, base64, os, struct, json, time, sys

class C:
    def __init__(self, s, rest): self.s, self.rest = s, rest
    def sendall(self, b): self.s.sendall(b)
    def recv(self, n): return self.s.recv(n)

def open_ws(host="127.0.0.1", port=18082, path="/", headers=None, version="13", key=True, sock=None):
    """Send a WebSocket upgrade request and return (socket, response_head_bytes, bytes_after_head).
    Does not insist on 101, so tests can look at refusals (403 / 426 / 503 / plain HTTP)."""
    s = sock or socket.create_connection((host, port)); s.settimeout(1.0)
    h = {"Host": "x", "Upgrade": "websocket", "Connection": "Upgrade", "Sec-WebSocket-Version": version}
    if key: h["Sec-WebSocket-Key"] = base64.b64encode(os.urandom(16)).decode()
    for k, v in (headers or {}).items():
        for existing in [e for e in h if e.lower() == k.lower()]: del h[existing]
        if v is not None: h[k] = v
    req = f"GET {path} HTTP/1.1\r\n" + "".join(f"{k}: {v}\r\n" for k, v in h.items()) + "\r\n"
    s.sendall(req.encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        d = s.recv(4096)
        if not d: break
        buf += d
    head, _, rest = buf.partition(b"\r\n\r\n")
    return s, head, rest

def connect(host="127.0.0.1", port=18082, path="/", headers=None):
    s, head, rest = open_ws(host, port, path, headers)
    assert b" 101 " in head.split(b"\r\n")[0], head
    return C(s, rest)

def send(s, obj):
    p = json.dumps(obj).encode(); m = os.urandom(4)
    h = bytes([0x81]) + (bytes([0x80 | len(p)]) if len(p) < 126 else bytes([0x80 | 126]) + struct.pack(">H", len(p)))
    s.sendall(h + m + bytes(b ^ m[i % 4] for i, b in enumerate(p)))

def pong(s, payload=b""):
    # A real client answers the server's pings; the daemon closes a connection that has not
    # sent a pong for ping_interval + pong_timeout (15 s + 10 s by default).
    m = os.urandom(4)
    s.sendall(bytes([0x8A, 0x80 | len(payload)]) + m + bytes(b ^ m[i % 4] for i, b in enumerate(payload)))

def need(s, n):
    while len(s.rest) < n: s.rest += s.recv(65536)
    d, s.rest = s.rest[:n], s.rest[n:]; return d

def frames(s, wait=0.6):
    out, end = [], time.time() + wait
    while time.time() < end:
        try:
            b0, b1 = need(s, 2); ln = b1 & 0x7F
            if ln == 126: ln = struct.unpack(">H", need(s, 2))[0]
            elif ln == 127: ln = struct.unpack(">Q", need(s, 8))[0]
            p = need(s, ln)
            if b0 & 0xF == 9: pong(s, p)                      # ping -> pong (keeps the connection alive)
            elif b0 & 0xF == 1: out.append(json.loads(p))     # must be valid JSON
        except socket.timeout: pass
    return out

