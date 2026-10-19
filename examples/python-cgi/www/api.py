import json, os, sys
n = int(os.environ.get("CONTENT_LENGTH") or 0)
body = sys.stdin.read(n) if n else ""
# A CGI program answers with header lines, a blank line, then the body.
# "Status:" sets the HTTP status; repeated Set-Cookie lines all reach the browser.
print("Status: 201 Created" if os.environ.get("REQUEST_METHOD") == "POST" else "Status: 200 OK")
print("Content-Type: application/json")
print("Set-Cookie: seen=1; Path=/")
print("Set-Cookie: lang=en; Path=/")
print()
print(json.dumps({"method": os.environ.get("REQUEST_METHOD"), "query": os.environ.get("QUERY_STRING"),
                  "body": body, "python": sys.version.split()[0]}))
