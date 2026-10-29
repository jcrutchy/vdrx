import time
time.sleep(30)      # never reads stdin, outlives the timeout
print("Content-Type: text/plain"); print(); print("done")
