"""Failed-login lockout (8 failures / 60 s -> that address is locked out for 60 s).
Needs a FRESH daemon on this directory's conf (the lockout state lives in the daemon)."""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from wsclient import *
fails = 0
def check(name, cond, extra=""):
    global fails; print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(extra))); fails += not cond
def ev(fr, e): return [f for f in fr if f.get("event") == e]

c = connect()
for i in range(3): send(c, {"method": "sys.auth", "token": "bad%d" % i}); frames(c, .15)
send(c, {"method": "sys.auth", "token": "vt"}); check("3 failures are below the limit: the right token still works", ev(frames(c, .4), "auth.ok"))

b = connect()
for i in range(7): send(b, {"method": "sys.auth", "token": "nope%d" % i}); r = frames(b, .15)
send(b, {"method": "sys.auth", "token": "vt"}); check("a success resets the count (7 more failures + right token still works)", ev(frames(b, .4), "auth.ok"))

x = connect()
for i in range(8): send(x, {"method": "sys.auth", "token": "guess%d" % i}); frames(x, .15)
send(x, {"method": "sys.auth", "token": "vt"}); r = frames(x, .4)
check("after 8 failures even the RIGHT token is refused (locked out)", ev(r, "auth.fail") and not ev(r, "auth.ok"), r)
y = connect(); send(y, {"method": "sys.auth", "token": "vt"}); r = frames(y, .4)
check("the lockout covers new connections from the same address", ev(r, "auth.fail") and not ev(r, "auth.ok"), r)
send(y, {"method": "subscribe", "filter": "demo.>"}); check("and a locked-out client gets nothing else", frames(y, .3) == [])

print("all passed" if not fails else f"{fails} FAILED"); sys.exit(1 if fails else 0)
