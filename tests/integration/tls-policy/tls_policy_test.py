#!/usr/bin/env python3
"""TLS policy of the listeners (tls_min_version, tls_ciphers): what a client can and cannot negotiate.
Run by tests/integration/run.sh (section tls-policy) against the fixture in this folder."""
import socket, ssl, sys, urllib.request

passed = failed = skipped = 0
def check(cond, name, extra=""):
    global passed, failed
    if cond: passed += 1; print("  ok    " + name)
    else:    failed += 1; print("  FAIL  " + name + ("  (" + extra + ")" if extra else ""))
def skip(name):
    global skipped
    skipped += 1; print("  skip  " + name)

def client_ctx(minv=None, maxv=None, ciphers=None):
    c = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    c.check_hostname = False; c.verify_mode = ssl.CERT_NONE
    if ciphers: c.set_ciphers(ciphers)
    if minv is not None: c.minimum_version = minv
    if maxv is not None: c.maximum_version = maxv
    return c

def handshake(port, ctx):
    """('ok', version, cipher, compression) or ('fail', reason)."""
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=4) as s:
            with ctx.wrap_socket(s, server_hostname="localhost") as t:
                t.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                head = t.recv(64)
                return ("ok", t.version(), t.cipher()[0], t.compression(), head[:15])
    except (ssl.SSLError, ConnectionError, socket.timeout, OSError) as e:
        return ("fail", type(e).__name__ + ": " + str(e)[:80])

TLS12, TLS13 = ssl.TLSVersion.TLSv1_2, ssl.TLSVersion.TLSv1_3

print("-- default policy (minimum TLS 1.2)")
r = handshake(18445, client_ctx())
check(r[0] == "ok" and r[1] == "TLSv1.3", "a modern client negotiates TLS 1.3 and gets a page", str(r))
check(r[0] == "ok" and r[4].startswith(b"HTTP/1.1 200"), "...and the response is served over it", str(r))
r = handshake(18445, client_ctx(maxv=TLS12))
check(r[0] == "ok" and r[1] == "TLSv1.2", "a TLS 1.2-only client is accepted", str(r))
check(r[0] == "ok" and "GCM" in r[2] or "CHACHA" in r[2], "...with an AEAD cipher (got %s)" % (r[2] if r[0] == "ok" else r[1]))
check(r[0] == "ok" and r[3] is None, "TLS compression is off", str(r))
r = handshake(18445, client_ctx(maxv=TLS12, ciphers="ECDHE-RSA-AES128-SHA:AES128-SHA:@SECLEVEL=0"))
check(r[0] == "fail", "a client offering only CBC / static-RSA ciphers is refused", str(r))
try:
    old = client_ctx(minv=ssl.TLSVersion.TLSv1, maxv=ssl.TLSVersion.TLSv1_1, ciphers="ALL:@SECLEVEL=0")
    r = handshake(18445, old)
    check(r[0] == "fail", "a TLS 1.0/1.1 client is refused", str(r))
except (ssl.SSLError, ValueError) as e:
    skip("TLS 1.0/1.1 client cannot be built with this Python/OpenSSL (%s)" % e)

print("-- HSTS (hsts_max_age 31536000 on this site)")
def https_headers(port):
    ctx = client_ctx()
    with socket.create_connection(("127.0.0.1", port), timeout=4) as s:
        with ctx.wrap_socket(s, server_hostname="localhost") as t:
            t.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
            d = b""
            while True:
                c = t.recv(4096)
                if not c: break
                d += c
    return d.split(b"\r\n\r\n")[0].decode("latin1").lower()
check("strict-transport-security: max-age=31536000" in https_headers(18445), "HSTS is sent over TLS")
with urllib.request.urlopen("http://127.0.0.1:18095/", timeout=4) as resp:
    check("Strict-Transport-Security" not in resp.headers, "HSTS is NOT sent over plain HTTP (browsers ignore it there, and it would mislead)")

print("-- tls_min_version 1.3")
r = handshake(18446, client_ctx())
check(r[0] == "ok" and r[1] == "TLSv1.3", "a TLS 1.3 client is accepted", str(r))
r = handshake(18446, client_ctx(maxv=TLS12))
check(r[0] == "fail", "a TLS 1.2-only client is refused", str(r))

print("-- a policy that cannot be applied must not start TLS")
for port, why in ((18447, 'tls_min_version "1.0"'), (18448, "an unknown cipher list")):
    r = handshake(port, client_ctx())
    check(r[0] == "fail", "%s: the TLS port is not served" % why, str(r))
for port in (18097, 18098):
    try:
        d = urllib.request.urlopen("http://127.0.0.1:%d/" % port, timeout=4).read()
        check(b"hello" in d, "the plain port of the same site still works (%d)" % port)
    except Exception as e:
        check(False, "the plain port of the same site still works (%d)" % port, str(e))

print("-- the log says what is enforced and what was refused")
log = open("vdrx_daemon.log", errors="replace").read()
check("minimum TLS 1.2" in log, "the applied policy is logged")
check("minimum TLS 1.3" in log, "the 1.3 policy is logged")
check("NOT started" in log and "not allowed" in log, "a refused minimum version is logged with the reason")
check("matched no cipher" in log, "an unusable cipher list is logged with the reason")

print("\n%d passed, %d failed, %d skipped" % (passed, failed, skipped))
print("all passed" if failed == 0 else "SOME FAILED")
sys.exit(1 if failed else 0)
