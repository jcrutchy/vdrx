# Wiring vdrx_plague.pas into vdrx_daemon.lpr

Compiled clean against your actual vdrx_core.pas/vdrx_config.pas (FPC 3.2.2,
`fpc -Mobjfpc -Fu. -FUunits vdrx_plague.pas`), zero warnings on the unit
itself. Not run live against your daemon yet - only compile-checked.

```pascal
uses
  ..., vdrx_plague;

var
  Plague: TVDRX_PlagueExecutive;

begin
  ...
  Plague := TVDRX_PlagueExecutive.Create(Kernel.Queue, 'vdrx_data/plague', Config);
  Kernel.Registry.Register(Plague, 'plague', 'plague.action');
  ...
  Kernel.Start;
```

Config additions (`vdrx_daemon.conf`, under `executives`):

```json
"plague": {
  "tick_ms": 3000,
  "countries_file": "plague_countries.json"
}
```

## Bus protocol

**In** - `plague.action`, payload JSON, always needs `type` and `player_id`
(except `start_game`):

| type | args | who |
|---|---|---|
| `join` | `role` (infector/defender), `name` | anyone |
| `seed_pathogen` | `country_id`, `name` | infector, once |
| `evolve_trait` | `trait` (infectivity/lethality) | infector, owns the pathogen |
| `invest_cure` | `pathogen_id`, `amount` | defender |
| `quarantine` | `country_id`, `level` (0-100) | defender |
| `close_border` / `open_border` | `from_id`, `to_id` | defender |
| `start_game` | - | anyone, once a pathogen exists |

**Out** - `plague.delta`, full state JSON, published after every action and
every tick (see note in `PublishDeltaLocked` - it's a full broadcast, not a
diff; fine at this scale, flagged as a future optimization not a bug).

**HTTP** - wire the same way `board/<name>` works in vdrx_http.pas:
`GET /plague/state` -> `Plague.GetSnapshot`, `GET /plague/countries` ->
`FCountries.AsJSON` (needs a getter added - didn't add one yet since it's a
two-line addition once you've decided the route shape). Client subscribes to
`plague.delta` over the existing WebSocket executive for live updates and
hits `/plague/state` once on page load, same pattern as the whiteboard.

## What's simulated, what isn't

Two traits (infectivity, lethality) driving three effects: internal spread,
deaths, cross-border seeding - see the `Base*` constants at the top of
`vdrx_plague.pas`, all one place to tune. No severity/detection trait, no
symptom system, no per-defender point budget (any defender can spend on any
pathogen's cure - trust-based, matches the rest of this codebase's current
admin/RBAC posture). All flagged in code comments as deliberate cuts for
"basic game," not oversights.

## Untested / next steps

- Never run against a live kernel - only compiled. Worth a smoke test:
  register it, `join`+`seed_pathogen`+`start_game` over stdin/IRC admin the
  way you've been testing whiteboard, watch `plague.delta` land on a WS
  client.
- No client yet. Once you've got country polygons from your map image, the
  natural next piece is a canvas overlay (color countries by
  infected-fraction per pathogen, blend if >1 pathogen present) plus a
  small action panel - happy to build that next once you've got a
  `plague_countries.json` derived from the real map.
- `FWinFraction` is a compiled-in 0.85 - `vdrx_config.pas` has no
  `GetFloat`, only `GetInteger`/`GetString`/`GetBoolean`/`GetStringArray`/
  `GetObjectArray`. Two-line addition to vdrx_config.pas if you want this
  tunable without a recompile; left alone rather than touching a file
  outside this unit's scope unasked.
