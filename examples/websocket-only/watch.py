"""Command-line WebSocket client (standard library only): prints every message on clock.>.
   python3 watch.py [host] [port] [seconds]     (default: localhost 8082, run until Ctrl-C)"""
import base64, json, os, socket, struct, sys, time

host = sys.argv[1] if len(sys.argv) > 1 else "localhost"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 8082
limit = float(sys.argv[3]) if len(sys.argv) > 3 else None

s = socket.create_connection((host, port))
s.sendall(("GET / HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n"
           % (host, base64.b64encode(os.urandom(16)).decode())).encode())
buf = b""
while b"\r\n\r\n" not in buf:
    buf += s.recv(4096)
buf = buf.split(b"\r\n\r\n", 1)[1]

def send(obj):
    p, m = json.dumps(obj).encode(), os.urandom(4)
    head = bytes([0x81]) + (bytes([0x80 | len(p)]) if len(p) < 126 else bytes([0xFE]) + struct.pack(">H", len(p)))
    s.sendall(head + m + bytes(b ^ m[i % 4] for i, b in enumerate(p)))

def take(n):
    global buf
    while len(buf) < n:
        chunk = s.recv(65536)
        if not chunk:
            raise EOFError
        buf += chunk
    out, buf = buf[:n], buf[n:]
    return out

send({"method": "sys.auth", "profile": "viewer"})
end = time.time() + limit if limit else None
s.settimeout(1.0)
try:
    while end is None or time.time() < end:
        try:
            b0, b1 = take(2)
            n = b1 & 0x7F
            if n == 126: n = struct.unpack(">H", take(2))[0]
            elif n == 127: n = struct.unpack(">Q", take(8))[0]
            data = take(n)
            if b0 & 0xF == 1:
                f = json.loads(data)
                print(f.get("topic") or f.get("event"), json.dumps(f.get("payload", "")), flush=True)
        except socket.timeout:
            pass
except (KeyboardInterrupt, EOFError):
    pass
