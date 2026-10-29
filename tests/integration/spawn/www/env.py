import os
print("Content-Type: text/plain"); print()
for k in sorted(os.environ): print("%s=%s" % (k, os.environ[k]))
