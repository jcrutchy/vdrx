import os
print("Content-Type: text/html; charset=utf-8")
print()
print("""<!doctype html><meta charset="utf-8"><title>vdrx + python</title>
<h1>vdrx + Python CGI</h1>
<ul>
  <li><a href="/env.py?name=world">/env.py?name=world</a> - the CGI environment</li>
  <li><a href="/api.py">/api.py</a> - JSON, status codes and two cookies</li>
  <li><a href="/style.css">/style.css</a> - a plain file next to the scripts</li>
</ul>""")
