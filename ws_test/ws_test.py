#!/usr/bin/env python3
"""Black-box test of ws_profiles. Start vdrx in this directory first
(conf: ws on port 18082), then:  python3 ws_test.py"""
import socket, base64, os, struct, json, time, sys

class C:
    def __init__(self, s, rest): self.s, self.rest = s, rest
    def sendall(self, b): self.s.sendall(b)
    def recv(self, n): return self.s.recv(n)

def connect():
    s = socket.create_connection(("127.0.0.1", 18082)); s.settimeout(1.0)
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
            if b0 & 0xF == 1: out.append(json.loads(p))      # must be valid JSON
        except socket.timeout: pass
    return out

fails = 0
def check(name, cond, extra=""):
    global fails; print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(extra))); fails += not cond
def ev(fr, e): return [f for f in fr if f.get("event") == e]
def on(fr, t): return [f for f in fr if f.get("topic") == t]

v, f, o, x = connect(), connect(), connect(), connect()
send(x, {"method": "subscribe", "filter": "demo.>"}); check("subscribe before auth is ignored", frames(x, .3) == [])
send(x, {"method": "sys.auth", "token": "wrong"}); check("bad token -> auth.fail", ev(frames(x, .4), "auth.fail"))
send(x, {"method": "sys.auth", "token": "vt", "profile": "feeder"}); check("wrong token for named profile -> auth.fail", ev(frames(x, .4), "auth.fail"))
send(v, {"method": "sys.auth", "token": "vt"}); r = frames(v, .4); check("viewer auth by token", ev(r, "auth.ok") and ev(r, "auth.ok")[0].get("profile") == "viewer", r)
send(f, {"method": "sys.auth", "token": "ft"}); check("feeder auth", ev(frames(f, .4), "auth.ok"))
send(o, {"method": "sys.auth", "profile": "open"}); check("open profile by name, no token", ev(frames(o, .4), "auth.ok"))

send(v, {"method": "subscribe", "filter": ">"}); check("viewer cannot subscribe to >", ev(frames(v, .4), "denied"))
send(v, {"method": "subscribe", "filter": "sys.>"}); check("viewer cannot subscribe to sys.>", ev(frames(v, .4), "denied"))
send(v, {"method": "subscribe", "filter": "demo.*"}); check("viewer may subscribe to demo.* (covered by demo.>)", not ev(frames(v, .4), "denied"))
send(v, {"method": "publish", "topic": "sys.quit", "payload": ""}); check("viewer cannot publish sys.quit", ev(frames(v, .4), "denied"))
send(f, {"method": "publish", "topic": "sys.quit", "payload": ""}); check("feeder cannot publish sys.quit", ev(frames(f, .4), "denied"))
send(f, {"method": "publish", "topic": "other.x", "payload": "1"}); check("feeder cannot publish outside demo.>", ev(frames(f, .4), "denied"))
send(f, {"method": "subscribe", "filter": "demo.>"}); check("feeder has no subscribe_allow", ev(frames(f, .4), "denied"))

send(f, {"method": "publish", "topic": "demo.text", "payload": "hello world"})
send(f, {"method": "publish", "topic": "demo.json", "payload": {"a": [1, 2]}})
r = frames(v, .8)
t = on(r, "demo.text"); j = on(r, "demo.json")
check("plain-text payload arrives as a JSON string", t and t[0]["payload"] == "hello world", r)
check("JSON payload arrives intact", j and j[0]["payload"] == {"a": [1, 2]}, r)
check("source is the publishing connection", t and t[0]["source"].startswith("ws.conn."), t)
send(o, {"method": "subscribe", "filter": "open.*"}); frames(o, .3)
send(o, {"method": "publish", "topic": "open.a", "payload": "{}"}); check("open profile round trip", on(frames(o, .6), "open.a"))
send(v, {"method": "sys.auth", "token": "vt"}); frames(v, .3)
check("daemon still alive after the sys.quit attempts", on((send(f, {"method": "publish", "topic": "demo.alive", "payload": "1"}), frames(v, .6))[1], "demo.alive"))
print("FAILED" if fails else "all passed"); sys.exit(1 if fails else 0)
