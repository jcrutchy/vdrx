"""Outbound TLS (socket_clients): the server's certificate must be valid for the host that was dialled.

Both servers use a self-signed certificate that is ALSO the trusted CA, so the chain always verifies:
  good.pem - issued for IP 127.0.0.1      (what the client dials)
  bad.pem  - issued for other.example.com (a perfectly valid certificate - for somebody else)
Before the fix, vdrx accepted bad.pem for 127.0.0.1 because it only checked the chain."""
import os, ssl, sys, time, socket, threading

fails = 0
def check(name, cond, extra=""):
    global fails; print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(extra))); fails += not cond

def serve(port, cert, key, counter):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(cert, key)
    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); srv.bind(("127.0.0.1", port)); srv.listen(20)
    def handle(c):
        try:
            s = ctx.wrap_socket(c, server_side=True); counter.append(1)
            s.settimeout(30)
            try: s.recv(1)
            except Exception: pass
        except Exception: pass
    def loop():
        while True:
            try: c, _ = srv.accept()
            except OSError: return
            threading.Thread(target=handle, args=(c,), daemon=True).start()
    threading.Thread(target=loop, daemon=True).start()

good, bad = [], []
serve(18601, "good.pem", "good.key", good)
serve(18602, "bad.pem", "bad.key", bad)
time.sleep(6)                                            # several reconnect cycles
log = open("vdrx_daemon.log", "rb").read().decode("utf-8", "replace")
def has(s): return s in log

check("a certificate issued for the dialled address is accepted", has("tlsgood: connected to 127.0.0.1:18601 (TLS)"), log[-600:])
check("a valid certificate issued for ANOTHER name is refused", not has("tlsbad: connected"), log[-600:])
check("...and the refusal says why", has("tlsbad: TLS certificate presented by 127.0.0.1:18602 is not valid for the name"))
check("tls_peer_name makes the other name the one that must match", has("tlsname: connected to 127.0.0.1:18602 (TLS)"))
check("tls_verify false still skips every check (opt-in, as documented)", has("tlsoff: connected to 127.0.0.1:18602 (TLS)"))
print("all passed" if not fails else "%d FAILED" % fails)
sys.exit(1 if fails else 0)
