"""Programs started for web requests, and what the static server will hand out.
usage: python3 spawn_test.py default | open      (run it against the matching daemon)
The daemon must have been started with VDRX_TEST_SECRET and VDRX_TEST_OTHER in ITS environment."""
import os, sys, socket, time, hashlib, http.client, tempfile, shutil
mode = sys.argv[1] if len(sys.argv) > 1 else "default"
HERE = os.path.dirname(os.path.abspath(__file__))
STATIC = os.path.join(HERE, "static")
if mode == "open": STATIC = os.path.join(HERE, "..", "spawn", "static")
fails = 0
def check(name, cond, extra=""):
    global fails; print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(extra))); fails += not cond

def request(method, path, body=None, headers=None, timeout=10):
    c = http.client.HTTPConnection("127.0.0.1", 18080, timeout=timeout)
    t = time.time()
    try:
        c.request(method, path, body=body, headers=headers or {}); r = c.getresponse(); data = r.read()
        return r.status, data, time.time() - t
    except Exception as e:
        return 0, repr(e).encode(), time.time() - t
    finally: c.close()

def raw_get(path, header_lines):
    s = socket.create_connection(("127.0.0.1", 18080), timeout=10)
    s.sendall((f"GET {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n" + "".join(l + "\r\n" for l in header_lines) + "\r\n").encode())
    d = b""
    while True:
        b = s.recv(65536)
        if not b: break
        d += b
    s.close(); return d.partition(b"\r\n\r\n")[2].decode("utf-8", "replace")

def envdict(text): return dict(l.split("=", 1) for l in text.splitlines() if "=" in l)
def procs_matching(script):
    """Running interpreters whose argument is this script (not any process that merely mentions its name)."""
    n = 0
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            args = open(f"/proc/{pid}/cmdline", "rb").read().split(b"\0")
            if b"python" in os.path.basename(args[0]) and any(a.endswith(script.encode()) for a in args[1:]): n += 1
        except OSError: pass
    return n
def vdrx_rss_mb():
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            if open(f"/proc/{pid}/cmdline", "rb").read().split(b"\0")[0].endswith(b"bin/vdrx"):
                for l in open(f"/proc/{pid}/status"):
                    if l.startswith("VmRSS"): return int(l.split()[1]) / 1024.0
        except OSError: pass

# links are created here, not stored in git (Windows checkouts do not keep symlinks)
outside = tempfile.mkdtemp(prefix="vdrx_outside_")
open(os.path.join(outside, "secret.html"), "w").write("<p>outside the site root</p>")
for name, target in (("link.html", os.path.join(outside, "secret.html")), ("linkdir", outside)):
    p = os.path.join(STATIC, name)
    if os.path.lexists(p): os.remove(p)
    try: os.symlink(target, p)
    except OSError as e: print("skip  symlinks cannot be created here:", e)

try:
    print("-- environment of a CGI program")
    st, body, _ = request("GET", "/cgi/env.py?a=1&b=2")
    env = envdict(body.decode())
    if mode == "default":
        check("the daemon's own secrets are NOT in the program's environment",
              "VDRX_TEST_SECRET" not in env and "VDRX_TEST_OTHER" not in env, [k for k in env if k.startswith("VDRX_TEST")])
    else:
        check("child_env_passthrough passes exactly the variable it names", env.get("VDRX_TEST_SECRET") == "zz-secret-1", env.get("VDRX_TEST_SECRET"))
        check("... and still not the other one", "VDRX_TEST_OTHER" not in env)
    check("PATH is passed (programs can find their tools)", "PATH" in env)
    check("the CGI variables are there", env.get("REQUEST_METHOD") == "GET" and env.get("QUERY_STRING") == "a=1&b=2" and "SCRIPT_FILENAME" in env, sorted(env)[:6])
    check("no HOME / USER / SHELL leak either", not any(k in env for k in ("HOME", "USER", "SHELL", "LOGNAME")), [k for k in ("HOME", "USER", "SHELL") if k in env])

    if mode == "default":
        print("-- request headers become HTTP_* variables")
        env = envdict(raw_get("/cgi/env.py", ["X_Forwarded_For: 6.6.6.6", "X-Forwarded-For: 1.1.1.1", "x-forwarded-for: 2.2.2.2",
                                               "x.weird: dotted", "Proxy: http://evil.example:8888", "X-Real: ok"]))
        check("X-Forwarded-For: the first spelling wins, the underscore and lowercase copies are ignored", env.get("HTTP_X_FORWARDED_FOR") == "1.1.1.1", env.get("HTTP_X_FORWARDED_FOR"))
        check("a header with a '.' in its name does not become a variable", not any("WEIRD" in k for k in env), [k for k in env if "WEIRD" in k])
        check("'Proxy:' never becomes HTTP_PROXY (httpoxy)", "HTTP_PROXY" not in env)
        check("an ordinary header still does", env.get("HTTP_X_REAL") == "ok")

        print("-- a program that writes without end")
        before = vdrx_rss_mb()
        st, body, took = request("GET", "/cgi/flood.py", timeout=20)
        check("it is killed at the output cap and answered 502 quickly (%.1f s)" % took, st == 502 and took < 4 and b"too much output" in body, (st, took, body[:60]))
        after = vdrx_rss_mb()
        if before is not None: check("the daemon did not balloon (%.0f -> %.0f MB)" % (before, after), after - before < 80)

        print("-- a program that never reads its stdin")
        body1m = b"A" * 1_000_000
        st, body, took = request("POST", "/cgi/slow.py", body=body1m, timeout=30)
        check("1 MB body + sleeping program: timeout honoured, 504 after %.1f s (timeout 2 s)" % took, st == 504 and took < 5, (st, took))
        time.sleep(1.5)
        check("the timed-out program is gone, not left running", procs_matching("slow.py") == 0, procs_matching("slow.py"))
        st, body, took = request("POST", "/cgi/quick.py", body=body1m, timeout=10)
        check("1 MB body to a program that exits at once: answered 200 in %.2f s" % took, st == 200 and took < 2.5, (st, took))

        print("-- binary and NUL-containing request bodies arrive intact")
        cases = {"10000 NUL bytes": b"\0" * 10000, "200000 NUL bytes": b"\0" * 200000, "abc NUL def NUL NUL end": b"abc\0def\0\0end",
                 "100000 random bytes": os.urandom(100000), "text with control chars": bytes(range(1, 32)) * 50}
        for label, data in cases.items():
            st, body, took = request("POST", "/cgi/trace.py", body=data, timeout=10)
            want = "len=%d sha256=%s" % (len(data), hashlib.sha256(data).hexdigest())
            check(f"{label}", body.decode().strip() == want, (st, body[:80]))

    print("-- static files")
    def code(p): return request("GET", p)[0]
    check("a normal page is served", code("/ok.html") == 200 and code("/sub/page.html") == 200)
    check("vdrx.conf (tokens) is not served", code("/vdrx.conf") == 404)
    check("the daemon log is not served", code("/vdrx_daemon.log") == 404)
    check("a database dump (.sql) is not served", code("/data.sql") == 404)
    if mode == "default":
        check("PHP source is not served as text", code("/page.php") == 404)
        check("a plain .txt file is served", code("/notes.txt") == 200)
        check("a symlink to a file outside the site is refused", code("/link.html") == 404)
        check("a symlink to a directory outside the site is refused", code("/linkdir/secret.html") == 404)
    else:
        check("static_allow_extensions: [php] lets .php through", code("/page.php") == 200)
        check("static_deny_extensions: [txt] blocks .txt", code("/notes.txt") == 404)
        check("static_follow_symlinks: true follows a file link", code("/link.html") == 200)
        check("static_follow_symlinks: true follows a directory link", code("/linkdir/secret.html") == 200)
finally:
    for name in ("link.html", "linkdir"):
        p = os.path.join(STATIC, name)
        if os.path.islink(p): os.remove(p)
    shutil.rmtree(outside, ignore_errors=True)

print("all passed" if not fails else f"{fails} FAILED"); sys.exit(1 if fails else 0)
