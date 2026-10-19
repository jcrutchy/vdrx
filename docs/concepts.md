# 1. The mental model

Everything that does anything in VDRX is an **executive** - a small object
with an ID and a `HandlePacket` method. Executives never call each other
directly. They publish a message onto a **topic**, and VDRX's registry
figures out who's subscribed and delivers it. That's the entire mechanism -
logging, admin commands, HTTP requests reaching a backend, an IRC line
arriving, a WebSocket client asking for updates, all of it is "publish a
message, something subscribed picks it up."

```
   spawned process  ──stdin/stdout──►  Bridge executive  ──┐
   browser (WS)     ──JSON-RPC─────►  WS connection      ──┤
   HTTP request      ─(bus route)──►  HTTP executive     ──┼──►  the bus  ──►  whoever's
   TCP/TLS peer      ──raw bytes───►  Socket client      ──┘   (topic +      subscribed to
                                                                 payload)     that topic
```

Because nothing talks to anything else directly, wildly different things -
a PHP script, a browser tab, a remote IRC server, a batch file - can all
cooperate through the same bus without knowing about each other at all.

## Topics and filters

Topics are dot-delimited strings: `log.warn`, `irc_bot.out`, `sys.reload`,
`ws.conn.7.send`. Subscriptions are **filters** over that same shape, with
two wildcards:

- `*` matches exactly one segment
- `>` matches everything from that point on, however many segments

`log.>` catches every log line; `irc_bot.*` catches `irc_bot.in` and
`irc_bot.out` but not `irc_bot.deep.thing`; a literal topic with no
wildcard matches only itself.

## The four ways to get code running against the bus

This is really the whole practical question when you're building something:
**how does my code talk to VDRX?** There are six answers, and they compose:

| Mechanism | Lifetime | Use it for |
|---|---|---|
| **Supervised process** (`processes`) | Long-running, restart-on-crash | A daemon that needs to react to bus events continuously - an IRC protocol handler, a game tick loop, a worker |
| **Reverse-proxy route** (`processes` + `prefix`/`host`/`port`) | Long-running, has its own HTTP server | An existing web app/framework you don't want to rewrite - `php -S`, a Node server, anything that speaks HTTP itself |
| **CGI executive** (`cgi`) | Spawned fresh per HTTP request | A web-server-style site: `php-cgi`, Python, Perl, compiled `.cgi` programs serving a `doc_root` with static files, index files, rewrites and a front controller. The program is just a consumer of bus messages |
| *(legacy)* CGI-style CLI route (`cli_bridges`, `protocol: "cgi"`) | Spawned fresh per HTTP request | A classic "one script = one URL" site, PHP/Python/whatever, using ordinary CGI env vars |
| **Bus CLI route** (`cli_bridges`, `protocol: "bus"`) | Spawned fresh per HTTP request | An HTTP endpoint whose backend logic you want expressed as "read one JSON request, write one JSON reply" - language-agnostic |
| **Bus-daemon route** (`cli_bridges`, `protocol: "bus-daemon"`) | Long-running, shared across every request | The same request/reply shape as above, but answered by an already-running `processes` subscriber instead of a fresh spawn each time - no per-request process-start cost |
| **Template executive** (`templates`) | Long-running | Rendering a named template set (`.tpl` files + `%%params%%`/`##rows##`) reachable by topic name from anywhere - a bus-CLI reply, a persistent daemon, anything - rather than tied to one HTTP site's connection |

The rest of this doc walks through each one with a real example.

---
*Section numbers (§N) are shared across all vdrx docs - see the [section map](README.md#section-map).*
