import json, sys, urllib.parse

# Every line on stdin is a bus message: {"topic":..., "payload": <the HTTP request>, "source":...}
for line in sys.stdin:
    try:
        req = json.loads(line)["payload"]
        reply_to = req["reply_to"]
    except (ValueError, KeyError, TypeError):
        continue
    query = urllib.parse.parse_qs(req.get("query", ""))
    reply = {
        "status": 200,
        "template": "greeting",                       # templates/greeting.tpl
        "params": {"name": query.get("name", ["World"])[0], "path": req.get("path", "")},   # -> %%name%%, %%path%%
        "rows": {"messages": [                        # -> ##loop:messages## ... ##endloop:messages##
            {"from": "greeter.py", "text": "I only sent data; vdrx rendered the HTML."},
            {"from": "greeter.py", "text": "Add a row here and reload."},
        ]},
    }
    # answer on the request's own reply topic (allowed by publish_allow: http.reply.*)
    print(json.dumps({"topic": reply_to, "payload": json.dumps(reply)}), flush=True)
