"""Drives tools/jobs_terminal.html in headless Chromium against the jobs fixture daemon
(it starts and stops its own daemon on port 18082 - stop any other one first).
Needs:  pip install playwright && playwright install chromium
Run from this folder:  python3 terminal_test.py      (VDRX_SHOT=file.png saves a screenshot)"""
import subprocess, time, os, signal, sys
from playwright.sync_api import sync_playwright
HERE=os.path.dirname(os.path.abspath(__file__)); ROOT=os.path.abspath(os.path.join(HERE,"..","..","..")); FIX=HERE
BIN=ROOT+"/bin/vdrx"
if not os.path.exists(BIN): BIN+=".exe"
page_url="file://"+ROOT+"/tools/jobs_terminal.html?url=ws://127.0.0.1:18082&profile=operator"
fails=0
def check(n,c,x=""):
    global fails; print(("ok   " if c else "FAIL ")+n+("" if c else "  "+str(x))); fails+=not c
def start():
    for f in ("jobs_state.json",): 
        try: os.remove(FIX+"/"+f)
        except: pass
    p=subprocess.Popen([BIN],cwd=FIX,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,stdin=subprocess.DEVNULL,start_new_session=True)
    for _ in range(50):
        import socket
        try: socket.create_connection(("127.0.0.1",18082),.2).close(); break
        except: time.sleep(.2)
    return p
def stop(p):
    p.terminate()
    try: p.wait(10)
    except: p.kill()
d=start(); errs=[]
with sync_playwright() as pw:
    b=pw.chromium.launch(); pg=b.new_page(viewport={"width":1200,"height":720})
    pg.on("pageerror",lambda e:errs.append(str(e))); pg.on("console",lambda m: errs.append(m.text) if m.type=="error" and "WebSocket connection to" not in m.text else None)
    pg.goto(page_url)
    # wrong token first
    pg.fill("#wt","nope"); pg.click("#wc")
    pg.wait_for_function("document.querySelector('#st').textContent.includes('authentication failed')",timeout=5000)
    pg.wait_for_function("document.querySelector('#wc').textContent==='Connect'",timeout=3000); time.sleep(.5)
    check("wrong token -> 'authentication failed' stays on screen, button resets, no reconnect loop", "failed" in pg.inner_text("#st") and pg.inner_text("#wc")=="Connect", pg.inner_text("#st"))
    pg.fill("#wt","ot"); pg.click("#wc")
    pg.wait_for_function("document.querySelector('#st').textContent.startsWith('connected')",timeout=5000)
    check("connects and authenticates as the operator profile", "operator" in pg.inner_text("#st"), pg.inner_text("#st"))
    pg.wait_for_function("document.querySelectorAll('.jr').length>=17",timeout=6000)
    check("job list: 'All jobs' + all 16 jobs", pg.locator(".jr").count()==17, pg.locator(".jr").count())
    pg.wait_for_function("[...document.querySelectorAll('.k-out .tx')].some(e=>e.textContent.includes('out1'))",timeout=8000)
    time.sleep(4.5)
    outs=pg.locator(".k-out .tx",has_text="out1").count(); starts=pg.locator(".k-start",has_text="tick").count()
    check("stdout lines appear live, once each (no double delivery)", outs>=2 and 0<=starts-outs<=1, (outs,starts))
    check("stderr lines are red-classed", pg.locator(".k-err .tx",has_text="err1").count()>=1)
    check("scheduled job shows a countdown to its next run", pg.locator("[data-next]").count()>=1)
    row=lambda name: pg.locator(".jr",has=pg.locator(".nm",has_text=__import__('re').compile("^"+name+"$")))
    pg.evaluate("document.querySelector('#jobs').scrollTop=200"); time.sleep(5.6)
    check("job list keeps its scroll position across the 5s refresh", pg.evaluate("document.querySelector('#jobs').scrollTop")>=150, pg.evaluate("document.querySelector('#jobs').scrollTop"))
    check("'All jobs' row stays pinned at the top while the list is scrolled", pg.evaluate("(()=>{const a=document.querySelector('.jr.all').getBoundingClientRect(),b=document.querySelector('#jobs').getBoundingClientRect();return Math.abs(a.top-b.top)<2})()"))
    row("fail").locator("button",has_text="\u25B6").click()
    pg.wait_for_selector(".k-exit.bad >> text=exit code 3",timeout=5000)
    check("Run button: manual run, failure shown as a bad exit line", True)
    check("row shows last result", "failed (3)" in row("fail").inner_text(), row("fail").inner_text())
    row("fail").locator(".nm").click(); time.sleep(.3)
    lines=[e for e in pg.locator(".ln:not(.k-sys)").all_inner_texts()]
    check("click a job: only its lines remain", lines and all(" fail" in l or "fail:" in l for l in lines), lines[:4])
    pg.fill("#q","about"); time.sleep(.2)
    check("text filter narrows further", pg.locator(".ln").count()>=1 and all("about" in l for l in pg.locator(".ln").all_inner_texts()), pg.locator(".ln").all_inner_texts())
    pg.fill("#q",""); row("fail").locator(".nm").click(); time.sleep(.2)
    row("long").locator("button",has_text="\u25B6").click()
    pg.wait_for_function("[...document.querySelectorAll('.jr')].find(r=>r.querySelector('.nm').textContent==='long').querySelector('.dot').classList.contains('run')",timeout=5000)
    kb=row("long").locator("button",has_text="\u25A0"); check("running job: stop button enabled", kb.is_enabled())
    kb.click(); pg.wait_for_selector(".k-exit >> text=killed",timeout=6000)
    check("Stop button: job is killed", True)
    pg.uncheck("#cv"); time.sleep(.2)
    check("events checkbox hides start/exit lines", pg.locator(".k-exit,.k-start").count()==0)
    pg.check("#cv")
    if os.environ.get("VDRX_SHOT"): pg.screenshot(path=os.environ["VDRX_SHOT"])
    # reconnect after the daemon restarts
    stop(d); pg.wait_for_function("document.querySelector('#st').textContent.includes('retrying')",timeout=8000)
    check("daemon gone -> status says retrying", True)
    d=start(); pg.wait_for_function("document.querySelector('#st').textContent.startsWith('connected')",timeout=25000)
    check("daemon back -> reconnects by itself", True)
    pg.wait_for_function("document.querySelectorAll('.k-out').length>0 && document.querySelector('#st').textContent.startsWith('connected')")
    time.sleep(2.5)
    check("and lines flow again (seq reset handled)", pg.locator(".k-out .tx",has_text="out1").count()>=3, pg.locator(".k-out .tx",has_text="out1").count())
    # html in job output must not be interpreted
    pg.evaluate("onFrame({seq:99999999,topic:'job.tick.out',payload:{job:'tick',pid:1,ts:new Date().toISOString(),line:'<img src=x onerror=window.__x=1><b>hi</b>'}})"); time.sleep(.3)
    check("job output is shown as text, never as HTML", pg.evaluate("window.__x")is None and pg.locator(".tx",has_text="<b>hi</b>").count()==1)
    # a read-only profile: the buttons are there, the daemon refuses, the page says so
    pg.goto(page_url.replace("profile=operator","profile=viewer")); pg.fill("#wt","vt"); pg.click("#wc")
    pg.wait_for_function("document.querySelector('#st').textContent.includes('as viewer')",timeout=6000)
    pg.wait_for_function("document.querySelectorAll('.jr').length>=17",timeout=6000)
    pg.locator(".jr",has=pg.locator(".nm",has_text=__import__('re').compile("^fail$"))).locator("button",has_text="\u25B6").click()
    pg.wait_for_selector(".k-sys >> text=denied: publish jobs.run",timeout=4000)
    check("read-only profile: the job list works, a Run click is answered 'denied' in the terminal", True)
    check("no JavaScript errors", not errs, errs)
    b.close()
stop(d); print("FAILED" if fails else "all passed"); sys.exit(1 if fails else 0)
