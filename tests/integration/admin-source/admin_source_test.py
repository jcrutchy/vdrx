#!/usr/bin/env python3
"""Who may drive the operator-control topics (sys.quit, sys.reload, sys.kill, ...). Spawns the daemon itself (twice) so it
can feed the stdin console. Run by tests/integration/run.sh (section admin-source)."""
import os, subprocess, sys, time, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.abspath(os.path.join(HERE, "..", "..", "..", "bin", "vdrx"))
passed = failed = 0
def check(cond, name, extra=""):
    global passed, failed
    if cond: passed += 1; print("  ok    " + name)
    else:    failed += 1; print("  FAIL  " + name + ("  (" + str(extra)[:300] + ")" if extra else ""))

def start(conf):
    shutil.copy(os.path.join(HERE, conf), os.path.join(HERE, "vdrx.conf.active"))
    out = open(os.path.join(HERE, "console.out"), "wb")
    p = subprocess.Popen([BIN, "--config", "vdrx.conf.active"], cwd=HERE, stdin=subprocess.PIPE, stdout=out, stderr=subprocess.STDOUT)
    return p, out
def console(): return open(os.path.join(HERE, "console.out"), errors="replace").read()
def wait_exit(p, secs):
    try: p.wait(secs); return True
    except subprocess.TimeoutExpired: return False
def stop(p):
    if p.poll() is None:
        try: p.stdin.write(b"quit\n"); p.stdin.flush()
        except Exception: pass
        if not wait_exit(p, 6): p.kill()

print("-- default: only the stdin console may drive sys.>")
p, out = start("vdrx.conf")
time.sleep(5)                                              # the rogue process fires at ~1.5-2.7 s
check(p.poll() is None, "a process allowed to publish sys.quit does NOT stop the daemon", "exit code %s" % p.poll())
c = console()
check('refused sys.' in c and 'from source "rogue"' in c, "a refusal is logged naming the offending source (one line per 5 s, not one per message)", c[-400:])
check("Configuration reloaded" not in c, "the refused sys.reload did not happen")
check("killall matched" not in c, "the refused sys.killall did not happen")
check("admin_sources" in c, "the log says how to allow a source")
p.stdin.write(b"list\n"); p.stdin.flush(); time.sleep(1.5)
check("rogue" in console().split("refused sys.quit", 1)[-1] and "bridge" in console().lower(), "the stdin console still works (list)", console()[-300:])
p.stdin.write(b"quit\n"); p.stdin.flush()
check(wait_exit(p, 8), "and 'quit' typed on the console still stops the daemon")
out.close()

print("-- admin_sources names an extra trusted source")
p, out = start("vdrx.trusted.conf")
check(wait_exit(p, 10), "with admin_sources [stdin, rogue] the same process CAN stop the daemon", "still running")
stop(p); out.close()

print("\n%d passed, %d failed" % (passed, failed))
print("all passed" if failed == 0 else "SOME FAILED")
sys.exit(1 if failed else 0)
