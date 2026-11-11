"""max_line_bytes: a peer or child that never sends a newline cannot make the daemon buffer without limit.

limsock: a socket_clients entry (limit 2048). A fake server sends a normal line, then ~40 MB with no newline.
         The client must log the problem, disconnect and reconnect, and the daemon's memory must not grow.
limproc: a supervised process (limit 2048) prints BEFORE-MARK, one 500 KB line, AFTER-MARK.
         The long line is dropped with a warning; both neighbours are delivered; the process is left running."""
import os, sys, time, socket, threading

fails = 0
def check(name, cond, extra=""):
    global fails; print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(extra))); fails += not cond

def rss_kb():
    pid = os.popen("pgrep -x vdrx | head -1").read().strip()
    try:
        for l in open("/proc/%s/status" % pid):
            if l.startswith("VmRSS:"): return int(l.split()[1])
    except Exception: pass
    return None

accepted = []
sent_bytes = [0]
def serve():
    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 18701)); srv.listen(5)
    while True:
        c, _ = srv.accept(); accepted.append(1)
        try:
            c.sendall(b"HELLO-SOCK\n")
            block = b"S" * 65536
            for _ in range(640):                         # ~40 MB, no newline
                c.sendall(block); sent_bytes[0] += len(block)
        except Exception:
            pass                                          # the daemon hung up on us - that is the point
        finally:
            try: c.close()
            except Exception: pass
threading.Thread(target=serve, daemon=True).start()

time.sleep(1)
base = rss_kb()
time.sleep(7)
peak = rss_kb()
log = open("vdrx_daemon.log", "rb").read().decode("utf-8", "replace")
bucket = open("bucket.jsonl", "rb").read().decode("utf-8", "replace") if os.path.exists("bucket.jsonl") else ""

check("socket client: the line before the flood was delivered", "HELLO-SOCK" in bucket, bucket[-300:])
check("socket client: the flood is reported and the peer disconnected",
      "socket client limsock: peer sent a line longer than max_line_bytes (2048) - disconnecting" in log, log[-600:])
check("socket client: it reconnected afterwards", len(accepted) >= 2, "connections: %d" % len(accepted))
check("socket client: none of the flood reached the bus", "SSSSSSSS" not in bucket)
if base and peak:
    check("daemon memory did not grow with the flood (%d kB -> %d kB)" % (base, peak), peak - base < 30000)
else:
    print("skip memory check (no /proc)")

check("process: the line before the long one was delivered", "BEFORE-MARK" in bucket, bucket[-300:])
check("process: the line after the long one was delivered", "AFTER-MARK" in bucket, bucket[-300:])
check("process: the long line was dropped with a warning",
      "bridge limproc: dropped an output line longer than max_line_bytes (2048)" in log, log[-600:])
check("process: none of the long line reached the bus", "XXXXXXXX" not in bucket)
check("process: it was left running (not killed or restarted)", "bridge limproc: exited" not in log and "force-killing" not in log, log[-400:])
print("all passed" if not fails else "%d FAILED" % fails)
sys.exit(1 if fails else 0)
