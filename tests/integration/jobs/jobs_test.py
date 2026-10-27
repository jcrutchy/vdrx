"""Black-box test of the jobs scheduler / runner. Start vdrx in this directory first
(conf: ws on port 18082, the jobs in vdrx.conf; delete jobs_state.json beforehand so
the scheduled jobs start from scratch), then:  python3 jobs_test.py

Everything is observed the way a web terminal would observe it: over the WebSocket,
as job.<id>.start / out / err / exit / skip / queued / restart messages."""
import os, sys, json, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from wsclient import *

fails = 0
def check(name, cond, extra=""):
    global fails; print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(extra))); fails += not cond

ALL = []                                   # every frame seen so far, in order
def pump(s, secs=.3):
    fr = frames(s, secs); ALL.extend(fr); return fr
def of(topic):                             # payload dicts seen on a topic
    return [f["payload"] for f in ALL if f.get("topic") == topic and isinstance(f.get("payload"), dict)]
def lines(job, stream="out"):
    return [p["line"] for p in of("job.%s.%s" % (job, stream))]
def wait_for(s, pred, timeout=10):
    end = time.time() + timeout
    while time.time() < end:
        if pred(): return True
        pump(s, .25)
    return pred()
def run(s, job):  send(s, {"method": "publish", "topic": "jobs.run",  "payload": job})
def kill(s, job): send(s, {"method": "publish", "topic": "jobs.kill", "payload": job})
def state(s, timeout=4):
    n = len(of("jobs.state")); send(s, {"method": "publish", "topic": "jobs.list", "payload": ""})
    wait_for(s, lambda: len(of("jobs.state")) > n, timeout)
    st = of("jobs.state"); return st[-1] if len(st) > n else None
def exits(job): return of("job.%s.exit" % job)

s = connect()
send(s, {"method": "sys.auth", "token": "ot"})
r = pump(s, .5)
check("operator auth", [f for f in r if f.get("event") == "auth.ok"], r)
send(s, {"method": "subscribe", "filter": "jobs.>"}); pump(s, .3)

# --- scheduled jobs --------------------------------------------------------------
check("scheduled job runs by itself (tick, every 2s)", wait_for(s, lambda: len(exits("tick")) >= 1, 8), ALL[-5:])
e = exits("tick")[0]
check("exit event: status ok, code 0, pid, duration, UTC timestamp",
      e["status"] == "ok" and e["code"] == 0 and e["pid"] > 0 and e["duration_ms"] >= 0 and e["ts"].endswith("Z") and e["job"] == "tick", e)
check("stdout lines are published one by one (and a final line with no newline too)",
      "out1" in lines("tick") and "no newline" in lines("tick"), lines("tick"))
check("stderr goes to .err", "err1" in lines("tick", "err"), lines("tick", "err"))
check("every line carries job, run and pid", all(p["job"] == "tick" and p["run"] >= 1 and p["pid"] > 0 for p in of("job.tick.out")))
check("start event says what triggered it", of("job.tick.start") and of("job.tick.start")[0]["trigger"] in ("schedule", "manual"), of("job.tick.start"))
check("a second scheduled run follows (new run id)", wait_for(s, lambda: len({p["run"] for p in exits("tick")}) >= 2, 8), exits("tick"))

check("overlap skip: a tick during a running job is skipped (slow)", wait_for(s, lambda: of("job.slow.skip"), 8), ALL[-5:])
check("skip says why", "still active" in of("job.slow.skip")[0]["reason"], of("job.slow.skip"))
st = state(s)
check("a disabled job is never scheduled", st and not [j for j in st["jobs"] if j["job"] == "idle"][0]["enabled"] and not of("job.idle.start"), st)

# --- manual run, exit codes ------------------------------------------------------
run(s, "fail")
check("jobs.run starts a job; non-zero exit -> failed + code", wait_for(s, lambda: exits("fail")), None)
e = exits("fail")[0]; check("failed, code 3", e["status"] == "failed" and e["code"] == 3, e)
check("its output was still captured", "about to fail" in lines("fail"), lines("fail"))
check("start event says manual", of("job.fail.start")[0]["trigger"] == "manual", of("job.fail.start"))
run(s, "nostart")
check("a program that cannot be started -> start_failed + error text", wait_for(s, lambda: exits("nostart")), None)
e = exits("nostart")[0]; check("start_failed with error", e["status"] == "start_failed" and e.get("error"), e)
run(s, '{"job": "fail"}'); n = len(exits("fail"))
check("jobs.run also accepts {\"job\": \"id\"}", wait_for(s, lambda: len(exits("fail")) > n), None)

# --- timeout / kill --------------------------------------------------------------
run(s, "hang")
check("timeout_sec stops a runaway job", wait_for(s, lambda: exits("hang"), 8), None)
e = exits("hang")[0]; check("status timeout, stop=timeout, took about 1s", e["status"] == "timeout" and e.get("stop") == "timeout" and 800 <= e["duration_ms"] <= 4000, e)

def slow_running():
    st = state(s, 2); return st and [j for j in st["jobs"] if j["job"] == "slow"][0]["running"]
check("(slow is running)", wait_for(s, slow_running, 10), None)
n = len(exits("slow"))
def kill_slow():
    # "slow" runs 4 s and is rescheduled every 1 s, so for up to a second per cycle nothing is
    # running and a kill finds nothing to stop (a slow machine makes the state check above stale).
    # jobs.kill on an idle job is a no-op, so just keep asking until a run is actually killed.
    kill(s, "slow")
    return [x for x in exits("slow")[n:] if x["status"] == "killed"]
check("jobs.kill stops a running job (status killed)", wait_for(s, kill_slow, 10), exits("slow")[n:])

# --- text handling / environment ---------------------------------------------------
run(s, "ansi"); run(s, "ansiraw"); run(s, "envjob")
wait_for(s, lambda: exits("ansi") and exits("ansiraw") and exits("envjob"), 6)
check("strip_ansi (default) removes colour codes", lines("ansi") == ["red text"], lines("ansi"))
check("strip_ansi false keeps them", lines("ansiraw") and "\x1b[91m" in lines("ansiraw")[0], lines("ansiraw"))
check("env and work_dir are applied", lines("envjob") == ["hello from /tmp"], lines("envjob"))

# --- overlap policies --------------------------------------------------------------
run(s, "q"); run(s, "q"); run(s, "q")   # back to back: one runs, one is queued, one is skipped
check("overlap queue: the second tick is remembered ('queued')", wait_for(s, lambda: of("job.q.queued"), 4), of("job.q.queued"))
check("overlap queue: it runs again afterwards (2 runs, not 3)", wait_for(s, lambda: len(exits("q")) >= 2, 8) and (pump(s, 1.5) or True) and len(exits("q")) == 2, exits("q"))
check("a third tick while one is already queued is skipped", of("job.q.skip"), of("job.q.skip"))

run(s, "repl"); wait_for(s, lambda: of("job.repl.start"), 4); run(s, "repl")
check("overlap kill: 'restart' announced", wait_for(s, lambda: of("job.repl.restart"), 4), None)
check("overlap kill: old run ends (killed, stop=restart) and a new one starts",
      wait_for(s, lambda: exits("repl") and len(of("job.repl.start")) >= 2, 6) and exits("repl")[0]["status"] == "killed" and exits("repl")[0].get("stop") == "restart", [exits("repl"), of("job.repl.start")])
kill(s, "repl"); check("then jobs.kill ends the new one too", wait_for(s, lambda: len(exits("repl")) >= 2, 6), exits("repl"))

# --- max_concurrent --------------------------------------------------------------
for j in ("cc1", "cc2", "cc3", "cc4"): run(s, j)
check("max_concurrent: surplus jobs wait for a free slot", wait_for(s, lambda: [p for j in ("cc1", "cc2", "cc3", "cc4") for p in of("job.%s.queued" % j) if "free slot" in p["reason"]], 4), None)
check("...and every one of them still runs to completion", wait_for(s, lambda: all(exits(j) for j in ("cc1", "cc2", "cc3", "cc4")), 14) and all(exits(j)[0]["status"] == "ok" for j in ("cc1", "cc2", "cc3", "cc4")), [exits(j) for j in ("cc1", "cc2", "cc3", "cc4")])

# --- jobs.list, robustness ---------------------------------------------------------
run(s, "nope"); kill(s, "nope"); send(s, {"method": "publish", "topic": "jobs.run", "payload": "{broken"}); pump(s, .5)
st = state(s)
check("jobs.list answers on jobs.state after bad input (daemon alive)", st and st["max_concurrent"] == 3, st)
byid = {j["job"]: j for j in st["jobs"]} if st else {}
check("state lists every job with its last result", len(byid) == 16 and byid["tick"]["runs"] >= 2 and byid["fail"]["last_status"] == "failed" and byid["fail"]["last_code"] == 3, byid.get("fail"))
check("state shows overlap + interval", byid["slow"]["overlap"] == "skip" and byid["tick"]["interval_sec"] == 2 and byid["q"]["overlap"] == "queue", byid.get("q"))

# --- long job left running for the shutdown test in run.sh ---------------------------
run(s, "long"); check("long job started (left running for the shutdown check)", wait_for(s, lambda: of("job.long.start"), 4), None)

# --- state file / bucket ---------------------------------------------------------------
time.sleep(.3)
try:
    sf = json.load(open("jobs_state.json")); check("state file remembers when scheduled jobs last ticked", "tick" in sf and "slow" in sf and "idle" not in sf and "fail" not in sf, sf)
except Exception as ex:
    check("state file is valid JSON", False, ex)
try:
    recs = [json.loads(l) for l in open("jobs_test.jsonl") if l.strip()]
    check("bucket recorded job.> messages", len(recs) > 50 and any(r["topic"] == "job.tick.out" for r in recs), len(recs))
except Exception as ex:
    check("bucket file is valid JSONL", False, ex)
print("FAILED" if fails else "all passed"); sys.exit(1 if fails else 0)
