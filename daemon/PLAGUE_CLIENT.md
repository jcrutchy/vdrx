# Plague web client

Three new static files (`templates/plague.tpl`, `static/plague.css`,
`static/plague.js`) plus edits to `vdrx_http.pas` to serve them. The edits
are already applied to the copy of `vdrx_http.pas` in this delivery -
compiled clean against your real `vdrx_core`/`vdrx_config`/`vdrx_templates`/
`vdrx_socketlistener`/`vdrx_transport`/`vdrx_procutil`/`vdrx_whiteboard`/
`vdrx_plague` (`fpc -Mobjfpc -Fu. -FUunits vdrx_http.pas`, 0 errors, only
the same pre-existing warnings your own build already has). Diff it against
your working copy before overwriting - I don't have visibility into
whatever you've changed in `vdrx_http.pas` since the copy I pulled this
session.

## What changed in vdrx_http.pas

- New `vdrx_plague` import.
- `TVDRX_HTTPExecutive` now takes an `APlague: TVDRX_PlagueExecutive`
  constructor param (nil-safe - routes 404 cleanly if you don't wire one
  up), stored alongside `FWhiteboard`.
- `BuildResponse` (and its class-method signature) gained the same param,
  threaded through the same way as `AWhiteboard`.
- Three new routes: `GET /plague` (renders `plague.tpl`), `GET
  /plague/state` (raw `Plague.GetSnapshot` JSON), `GET /plague/countries`
  (raw `Plague.GetCountriesJSON` JSON).

## vdrx_daemon.lpr wiring

```pascal
uses
  ..., vdrx_plague;

var
  Plague: TVDRX_PlagueExecutive;

begin
  ...
  Plague := TVDRX_PlagueExecutive.Create(Kernel.Queue, 'vdrx_data/plague', Config);
  Kernel.Registry.Register(Plague, 'plague', 'plague.action');

  HTTP := TVDRX_HTTPExecutive.Create(Kernel.Queue, Config, Whiteboard, Plague, Templates,
    Config.GetString('static_dir', 'static'), ProxyRoutes);
  Kernel.Registry.Register(HTTP, 'http', 'sys.none');
  ...
```

(`HTTP`'s constructor call needs the extra `Plague` argument inserted
wherever you already build it - the exact surrounding code depends on
whatever else you've added to `vdrx_daemon.lpr` since WIRING.md, which I
haven't seen.)

## Config addition

```json
"settings": {
  "site_title": "VDRX",
  "plague_map_image": "plague_map.png"
}
```

Drop your high-res map into `static/plague_map.png` (or whatever filename
you set here) - `plague.tpl` references it as `/$$plague_map_image$$`. If
it's not there yet, the page still works: the `<img>` just 404s and
`plague.js` falls back to a plain ring layout for every country (see
`layoutFallback()`), so you can build and test the country list, actions,
and simulation before the image and polygon data exist.

## Country data format the client expects

Same file as before (`plague_countries.json`), with one addition: an
optional `"points"` array of `[x, y]` pixel coordinates (in the map
image's native resolution, not the browser's display size) per country,
tracing its polygon outline. Only the server-passthrough is required for
the sim to run - `points` is purely how `plague.js` draws that country on
the map.

```json
"usa": {
  "name": "United States",
  "population": 331000000,
  "neighbors": ["canada", "mexico"],
  "points": [[210, 340], [180, 300], [260, 260], [310, 330]]
}
```

A country with no `points` still fully participates in the simulation -
it just renders as a small circle on the fallback ring instead of a
polygon on the map, so you can add real polygon data country-by-country
rather than needing it all at once.

## Not built yet

- Country polygon coordinates - waiting on your list.
- Multi-pathogen visual blending: right now a country's fill color is
  whichever pathogen has the most active cases there, opacity scaled by
  local infected fraction (see `colorForCountry` in plague.js) - true
  blending (split fill, stacked mini-bars) is a nicer version of the same
  idea, deferred rather than half-built.
- Never run against a live kernel or a real browser - compiled the Pascal
  side, but the JS/CSS/template trio is untested beyond reading them back
  carefully. Worth an actual smoke test once you've got the map image and
  a country list in place: `join`, `seed_pathogen` (click a country),
  `start_game`, watch the tick loop move counts and `plague.delta` update
  the map live.
