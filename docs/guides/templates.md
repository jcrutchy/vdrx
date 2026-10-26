# Templates: render HTML from data

Handlers answer with *data*; vdrx renders the HTML. Example: [`examples/templates`](../../examples/templates).

```json
{
  "settings": { "site_title": "vdrx templates demo" },
  "http_sites": [ { "id": "web", "port": 8080, "template_dir": "templates" } ],
  "http_routes": [ { "id": "greeter", "prefix": "/greeting", "allow": "GET" } ],
  "processes": [ { "id": "greeter", "command": "{PYTHON_BIN} greeter.py",
                   "subscribe": ["greeter.in"], "publish_allow": ["http.reply.*"] } ]
}
```

Run vdrx from the example folder and open <http://localhost:8080/greeting?name=Jared>.

## The handler

`greeter.py` is a persistent script supervised by vdrx. Each line on its stdin is one bus message whose `payload`
is the HTTP request (`method`, `path`, `query`, `headers`, `body`, `reply_to`, ...). It answers by publishing to
`reply_to`:

```python
reply = {
  "status": 200,
  "template": "greeting",                                    # templates/greeting.tpl
  "params": {"name": "Jared"},                               # -> %%name%%
  "rows":   {"messages": [{"from": "a", "text": "hi"}]},     # -> ##loop:messages##
}
print(json.dumps({"topic": req["reply_to"], "payload": json.dumps(reply)}), flush=True)
```

The `publish_allow: ["http.reply.*"]` is what lets the script publish to its per-request reply topic
(reply topics are always `http.reply.<n>`). The script contains no HTML.

## The template language

Files are `<name>.tpl` directly under `template_dir`, loaded on first use and cached. Five placeholder kinds:

| Syntax | Replaced by |
|---|---|
| `$$key$$` | `settings.key` from the config (here `site_title`) |
| `??NAME??` | a constant registered by the application |
| `@@child@@` | another template (`child.tpl`), recursively - for headers, footers, layouts |
| `##loop:name##...##endloop:name##` | the body repeated once per row of `rows.name`; a row's fields (`%%from%%`, `%%text%%`) are visible inside |
| `%%var%%` | a value from `params`, substituted last over the finished page |

An unknown loop name renders zero rows. `examples/templates/templates/greeting.tpl` uses `$$`, `%%`, a loop and an
`@@footer@@` partial.

## Where templates are looked up

A reply with `"template"` is rendered by default against the `template_dir` of the HTTP site that received the
request. If several sites share a route, or the handler isn't an HTTP reply at all, add a **template executive**
and name it in the reply:

```json
"templates": [ { "id": "page_templates", "dir": "templates", "subscribe": "template.render" } ]
```

```json
{ "status": 200, "template": "greeting", "template_topic": "template.render", "params": {...} }
```

Now rendering is explicit and independent of which site answered. Anything on the bus can ask it to render:
publish `{"template":"greeting","params":{...},"reply_to":"x"}` to `template.render` and `{"body":"<html>..."}`
arrives on `x`.

## Variations

- The handler can be a one-shot [runner](cli-api.md) program too - it only needs to print a reply envelope; see the
  old "bus" protocol demo in [`examples/legacy-cli-bridges/template_demo.php`](../../examples/legacy-cli-bridges/template_demo.php).
- Handlers in any language work the same way: read JSON lines on stdin, write JSON lines on stdout.
