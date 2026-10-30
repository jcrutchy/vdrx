import sys, hashlib
data = sys.stdin.buffer.read()
print("Content-Type: text/plain"); print()
print("len=%d sha256=%s" % (len(data), hashlib.sha256(data).hexdigest()))
