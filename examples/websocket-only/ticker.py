import json, sys, time
n = 0
while True:
    n += 1
    # one JSON object per line on stdout = one bus message
    print(json.dumps({"topic": "clock.tick", "payload": {"n": n, "time": time.strftime("%H:%M:%S")}}), flush=True)
    time.sleep(1)
