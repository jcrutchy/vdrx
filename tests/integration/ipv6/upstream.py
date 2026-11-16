"""Fake HTTP upstream for proxy_test.py. Records every raw chunk it receives to received<port>.log, answers each request
it can parse (a pipelined second request would be answered too, if its bytes ever arrived), and honours Connection: close.
  /app/huge streams 70 MiB (more than vdrx's 64 MiB cap).  /app/silent never answers."""
import socket, threading, os, sys, time
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18091
LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "received%d.log" % PORT)
def handle(c):
    buf = b""; c.settimeout(3)
    try:
        while True:
            try: d = c.recv(65536)
            except socket.timeout: break
            if not d: break
            buf += d
            with open(LOG, "ab") as f: f.write(d + b"\n--END-CHUNK--\n")
            while b"\r\n\r\n" in buf:
                head, _, buf = buf.partition(b"\r\n\r\n")
                parts = head.split(b" ")
                path = parts[1].decode("latin1") if len(parts) > 1 else "?"
                close = b"connection: close" in head.lower()
                clm = [l for l in head.split(b"\r\n") if l.lower().startswith(b"content-length:")]
                n = int(clm[0].split(b":")[1]) if clm else 0
                while len(buf) < n:
                    more = c.recv(65536)
                    if not more: break
                    buf += more
                body_in, buf = buf[:n], buf[n:]
                if path.endswith("/huge"):
                    c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 73400320\r\n\r\n")
                    chunk = b"x" * 1048576
                    for _ in range(70):
                        c.sendall(chunk)
                    return
                if path.endswith("/silent"):
                    time.sleep(60); return
                body = ("upstream saw: %s body=%s" % (path, body_in.decode("latin1"))).encode()
                c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(body) + body)
                if close: return
    except (BrokenPipeError, ConnectionResetError): pass
    finally: c.close()
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", PORT)); s.listen(20)
while True:
    c, _ = s.accept(); threading.Thread(target=handle, args=(c,), daemon=True).start()
