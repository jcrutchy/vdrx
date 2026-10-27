#!/usr/bin/env python3
"""Minimal WebSocket client helpers (standard library only) shared by the integration tests."""
import socket, base64, os, struct, json, time, sys

class C:
    def __init__(self, s, rest): self.s, self.rest = s, rest
    def sendall(self, b): self.s.sendall(b)
    def recv(self, n): return self.s.recv(n)

def connect(host="127.0.0.1", port=18082):
    s = socket.create_connection((host, port)); s.settimeout(1.0)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall(("GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    buf = b""
    while b"\r\n\r\n" not in buf: buf += s.recv(4096)
    assert b" 101 " in buf.split(b"\r\n")[0], buf
    return C(s, buf.split(b"\r\n\r\n", 1)[1])

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

