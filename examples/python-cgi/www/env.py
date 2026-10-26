import os, sys, urllib.parse
q = urllib.parse.parse_qs(os.environ.get("QUERY_STRING", ""))
print("Content-Type: text/plain; charset=utf-8")
print()
print("Hello, %s!" % q.get("name", ["stranger"])[0])
print()
for k in ("REQUEST_METHOD", "REQUEST_URI", "SCRIPT_NAME", "PATH_INFO", "QUERY_STRING",
          "SERVER_NAME", "SERVER_PORT", "REMOTE_ADDR", "CONTENT_TYPE", "CONTENT_LENGTH", "HTTP_USER_AGENT"):
    print("%-16s %s" % (k, os.environ.get(k, "(unset)")))
n = int(os.environ.get("CONTENT_LENGTH") or 0)
if n:
    print("\nrequest body (%d bytes): %s" % (n, sys.stdin.read(n)))
