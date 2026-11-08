"""Regression tests for the hardening findings (each was a working exploit before its fix)."""
import os, sys, time, json, functools, socket
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import wsclient
wsclient.json.loads = functools.partial(json.loads, strict=False)   # a reply body may contain a raw newline
from wsclient import connect, send, frames

fails = 0
def check(name, cond, extra=""):
    global fails; print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(extra))); fails += not cond

def login(token):
    c = connect(port=18082); send(c, {"method": "sys.auth", "token": token}); frames(c, .3); return c
def bodies(c, secs=1.0):
    return [f["payload"].get("body") for f in frames(c, secs) if isinstance(f.get("payload"), dict) and "body" in f["payload"]]
def render(c, template, reply):
    send(c, {"method": "publish", "topic": "tpl.in", "payload": {"template": template, "params": {"name": "x"}, "reply_to": reply}})
    return bodies(c)
def alive():
    try: socket.create_connection(("127.0.0.1", 18082), timeout=1).close(); return True
    except OSError: return False

print("-- 002: template names cannot leave the template directory")
c = login("dt"); send(c, {"method": "subscribe", "filter": "reply.>"}); frames(c, .2)
check("a legitimate template renders", render(c, "greeting", "reply.1") == ["<h1>Hello x</h1>\n"])
for bad in ("../secret", "..\\secret", "/etc/passwd", "sub/../../secret", "C:/secret", "..", ".hidden", "a\x00b", ""):
    got = render(c, bad, "reply.2")
    check("template %r is refused (empty body, nothing leaked)" % bad, got == [""] or got == [], got)

print("-- 001: a request cannot make an executive publish into sys.> / kernel.>")
send(c, {"method": "publish", "topic": "sys.quit", "payload": ""}); ev = [f.get("event") for f in frames(c, .4)]
check("the profile itself may not publish to sys.quit", "denied" in ev, ev)
for target in ("sys.quit", "SYS.QUIT", "sys.killall", "kernel.shutdown"):
    render(c, "greeting", target); time.sleep(.4)
    check("reply_to %r is refused and the daemon keeps running" % target, alive())
check("normal replies still work afterwards", render(c, "greeting", "reply.3") == ["<h1>Hello x</h1>\n"])
c.s.close()

print("-- 004: a second sys.auth never leaves the old profile's subscriptions active")
def feeder_publish(topic, text):
    f = login("ft"); send(f, {"method": "publish", "topic": topic, "payload": text}); frames(f, .2); f.s.close()
def got(c): return [x["payload"] for x in frames(c, .6) if "topic" in x and "event" not in x]
for scenario, second, want_event in (("re-auth as the weaker viewer profile", {"method": "sys.auth", "token": "vt"}, "auth.ok"),
                                     ("a failing sys.auth", {"method": "sys.auth", "token": "wrong"}, "auth.fail")):
    c = login("at"); send(c, {"method": "subscribe", "filter": "secret.>"}); frames(c, .2)
    feeder_publish("secret.a", "one"); check("[%s] admin receives secret.a first" % scenario, got(c) == ["one"])
    send(c, second); ev = [f.get("event") for f in frames(c, .4)]
    check("[%s] the second sys.auth is answered (%s)" % (scenario, want_event), want_event in ev, ev)
    feeder_publish("secret.b", "two"); r = got(c)
    check("[%s] secret.b is NOT delivered afterwards" % scenario, r == [], r)
    c.s.close()
c = login("vt"); send(c, {"method": "subscribe", "filter": "demo.>"}); frames(c, .2)
send(c, {"method": "unsubscribe_all"}); frames(c, .3)
send(c, {"method": "sys.auth", "token": "vt"}); ev = [f.get("event") for f in frames(c, .4)]
check("unsubscribe_all does not cut the connection's own reply channel", "auth.ok" in ev, ev)

print("all passed" if not fails else "%d FAILED" % fails)
sys.exit(1 if fails else 0)
