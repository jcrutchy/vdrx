"""Black-box test of ws_profiles. Start vdrx in this directory first
(conf: ws on port 18082), then:  python3 ws_test.py"""
import os, sys, json, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from wsclient import *

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
# --- confserver (needs php): the conf viewer reads config files through the bus
import shutil
if shutil.which("php"):
    send(v, {"method": "subscribe", "filter": "viewer.reply.*"}); frames(v, .3)
    def ask(path):
        send(v, {"method": "publish", "topic": "confserver.in", "payload": {"reply_to": "viewer.reply.t1", "params": {"file": path}}})
        r = [f for f in frames(v, 2.0) if f.get("topic") == "viewer.reply.t1"]
        return r[0]["payload"] if r else {}
    good = ask(os.path.abspath("inc/extra.conf"))
    check("confserver returns a conf under the allowed roots", good.get("status") == 200 and 'processes' in str(good.get("body")), good)
    check("confserver refuses a path outside the roots", ask("/etc/passwd").get("status") in (403, 404))
    check("confserver refuses a non-conf extension", ask(os.path.abspath("ws_test.py")).get("status") in (403, 404))
else:
    print("skip confserver checks (php not on PATH)")
print("FAILED" if fails else "all passed"); sys.exit(1 if fails else 0)
