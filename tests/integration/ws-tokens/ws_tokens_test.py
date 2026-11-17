#!/usr/bin/env python3
"""WebSocket profile credentials: token_hash, token_expires, and what happens when a credential is broken.
Spawns the daemon itself so it can read the console. Run by tests/integration/run.sh (section ws-tokens)."""
import hashlib, os, re, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
from wsclient import connect, send, frames

BIN = os.path.abspath(os.path.join(HERE, "..", "..", "..", "bin", "vdrx"))
passed = failed = 0
def check(cond, name, extra=""):
    global passed, failed
    if cond: passed += 1; print("  ok    " + name)
    else:    failed += 1; print("  FAIL  " + name + ("  (" + str(extra)[:300] + ")" if extra else ""))
def ev(fr, e): return [f for f in fr if f.get("event") == e]

def auth(**kw):
    s = connect(port=18110)
    send(s, dict({"method": "sys.auth"}, **kw))
    r = frames(s, 0.5); s.s.close(); return r
def ok(r): return bool(ev(r, "auth.ok"))

print("-- command line helpers")
r = subprocess.run([BIN, "--hash-token"], input=b"hashed-token-1\n", capture_output=True, timeout=10)
check(r.returncode == 0 and r.stdout.decode().strip() == "sha256:" + hashlib.sha256(b"hashed-token-1").hexdigest(), "--hash-token prints sha256:<hex> of the token on stdin", r.stdout)
r = subprocess.run([BIN, "--hash-token"], input=b"", capture_output=True, timeout=10)
check(r.returncode == 2, "--hash-token with nothing on stdin is an error", r.returncode)
r1 = subprocess.run([BIN, "--new-token"], capture_output=True, timeout=10).stdout.decode()
r2 = subprocess.run([BIN, "--new-token"], capture_output=True, timeout=10).stdout.decode()
t1 = re.search(r"token:\s+([0-9a-f]{64})\b", r1); t2 = re.search(r"token:\s+([0-9a-f]{64})\b", r2)
check(bool(t1 and t2) and t1.group(1) != t2.group(1), "--new-token makes a fresh 256-bit token each time")
check(bool(t1) and ("sha256:" + hashlib.sha256(t1.group(1).encode()).hexdigest()) in r1, "...and prints the matching token_hash")

out = open(os.path.join(HERE, "console.out"), "wb")
p = subprocess.Popen([BIN, "--config", "vdrx.conf"], cwd=HERE, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT)
time.sleep(2.5)
try:
    print("-- hashed tokens")
    r = auth(token="hashed-token-1"); check(ok(r) and ev(r, "auth.ok")[0].get("profile") == "hashed", "the right token for a token_hash profile logs in (by token)", r)
    check(ok(auth(token="hashed-token-1", profile="hashed")), "...and by profile name")
    check(not ok(auth(token="not-the-token", profile="hashed")), "a wrong token is refused")
    check(not ok(auth(token="sha256:" + hashlib.sha256(b"hashed-token-1").hexdigest(), profile="hashed")), "the HASH itself is not a valid token")
    check(ok(auth(token="plain-token")), "a plain-text token profile still works (backwards compatible)")

    print("-- expiry")
    check(ok(auth(token="future-token")), "a token that expires in 2999 works")
    check(not ok(auth(token="expired-token")), "an expired token is refused (by token)")
    check(not ok(auth(token="expired-token", profile="expired")), "an expired token is refused (by profile name)")

    print("-- broken credentials never become 'open'")
    check(not ok(auth(profile="badhash")), "token_hash that is not a hash: the named profile cannot be used with no token")
    check(not ok(auth(profile="badhash", token="anything")), "...nor with any token")
    check(not ok(auth(profile="both", token="bad-token")), "token and token_hash both set: unusable even with the right token")
    check(not ok(auth(profile="badexp", token="bad-token")), "unparsable token_expires: unusable")
    check(ok(auth(profile="open")), "a profile with no credential is still open by name (control)")
finally:
    p.terminate()
    try: p.wait(8)
    except subprocess.TimeoutExpired: p.kill()
    out.close()

con = open(os.path.join(HERE, "console.out"), errors="replace").read()
lg = open(os.path.join(HERE, "vdrx_daemon.log"), errors="replace").read()
print("-- what the operator is told")
check(con.count("UNUSABLE") >= 3, "startup names the unusable profiles (%d warnings)" % con.count("UNUSABLE"), con[-600:])
check('"badhash"' in con and '"both"' in con and '"badexp"' in con, "each broken profile is named")
check("already in the past" in con, "an already-expired token is called out at startup")
check("stored in plain text" in con, "a plain-text token gets a note recommending token_hash")
check("has expired" in lg, "an attempt on an expired token is logged as expired, not as a bad guess")

print("\n%d passed, %d failed" % (passed, failed))
print("all passed" if failed == 0 else "SOME FAILED")
sys.exit(1 if failed else 0)
