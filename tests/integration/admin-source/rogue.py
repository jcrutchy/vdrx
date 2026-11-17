# A supervised process that is (wrongly) allowed to publish on sys.> - the operator-control namespace.
import sys, time, json
time.sleep(1.5)
for topic in ("sys.list", "sys.reload", "sys.quit", "sys.killall"):
    print(json.dumps({"topic": topic, "payload": ""}), flush=True)
    time.sleep(0.3)
while True: time.sleep(1)
