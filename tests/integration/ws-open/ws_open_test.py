"""WebSocket with no ws_profiles. Usage: python3 ws_open_test.py reject|allow
reject: allow_open_access is off (the default) -> nobody can authenticate.
allow : allow_open_access is on -> any NON-EMPTY token passes; sys.* still can't be published."""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from wsclient import *

mode = sys.argv[1] if len(sys.argv) > 1 else "reject"
fails = 0
def check(name, cond, extra=""):
    global fails; print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(extra))); fails += not cond
def ev(fr, e): return [f for f in fr if f.get("event") == e]

if mode == "reject":
    for tok in ("x", "admin", "vt", "a-long-random-looking-token-1234567890"):
        c = connect(); send(c, {"method": "sys.auth", "token": tok}); r = frames(c, .4)
        check(f"token {tok[:12]!r} is rejected with auth.fail, never auth.ok", ev(r, "auth.fail") and not ev(r, "auth.ok"), r)
    c = connect(); send(c, {"method": "sys.auth", "token": "x"}); frames(c, .3)
    send(c, {"method": "subscribe", "filter": ">"}); r = frames(c, .4)
    check("a rejected client gets nothing from subscribe", r == [], r)
    send(c, {"method": "publish", "topic": "sys.quit", "payload": ""}); frames(c, .3)
    c2 = connect(); send(c2, {"method": "sys.auth", "token": "y"}); check("daemon still up after attempted sys.quit", ev(frames(c2, .4), "auth.fail"))
else:
    c = connect(); send(c, {"method": "sys.auth", "token": "anything"}); check("non-empty token accepted (explicit opt-in)", ev(frames(c, .4), "auth.ok"))
    e = connect(); send(e, {"method": "sys.auth", "token": ""}); r = frames(e, .4)
    check("EMPTY token gets auth.fail, not auth.ok", ev(r, "auth.fail") and not ev(r, "auth.ok"), r)
    send(c, {"method": "publish", "topic": "sys.quit", "payload": ""}); check("sys.quit still denied in open mode", ev(frames(c, .4), "denied"))

print("all passed" if not fails else f"{fails} FAILED"); sys.exit(1 if fails else 0)
