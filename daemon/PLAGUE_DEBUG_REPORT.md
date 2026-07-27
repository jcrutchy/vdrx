# Plague integration - debugging report

Built a full local test rig (installed FPC, populated templates/static/config,
ran the actual daemon binary, drove it over real HTTP + WebSocket) rather than
reading code and guessing. Found four issues, three of them real bugs, one a
design correctness problem. All four fixed and verified by running the daemon
through several minutes of live gameplay - join, seed, start, ~12 ticks,
evolve/invest/quarantine actions - with no crash and sane numbers.

## 1. Compile error: vdrx_weblistener.pas referenced FPlague without having it

Your `vdrx_weblistener.pas` (the combined HTTP+WS single-port listener,
currently unused by the running daemon but still part of the build) calls
`TVDRX_HTTPExecutive.BuildResponse` with an `FPlague` argument that was never
added as a field on the class - only `vdrx_http.pas` itself got that field
when the plague routes went in. **Fixed**: added `FPlague`/`APlague` the same
way `vdrx_http.pas` has it.

## 2. Compile error: vdrx_daemon.lpr never actually wires up Plague

- `vdrx_plague` was missing from the `uses` clause.
- No `Plague: TVDRX_PlagueExecutive` variable, no `Create`, no
  `Kernel.Registry.Register`.
- The `HTTP := TVDRX_HTTPExecutive.Create(...)` call was still using the old
  parameter list (missing `Plague` and mismatched against the 8-argument
  constructor your `vdrx_http.pas` now has, which also added `CLIRoutes`
  independently since I last touched this file).
- `CLIRoutes` itself was referenced in that same `HTTP.Create` call but never
  declared as a variable - a second, unrelated compile error hiding behind
  the first.

**Fixed**: added the import, the two missing var declarations, the
`Plague := TVDRX_PlagueExecutive.Create(...)` + `Register` call (mirroring
how `Whiteboard` is set up just above it), and corrected the `HTTP.Create`
call to pass `Plague` in the right position.

With both of these fixed, `vdrx_daemon.lpr` compiles and links into a real
binary (`fpc -Mobjfpc vdrx_daemon.lpr`, 0 errors).

## 3. Runtime crash: one non-object entry in countries.json silently kills the game forever

This is the one that actually matches "game doesn't work" - it's not a
compile problem, it only shows up once the daemon is running.

**Root cause, two parts:**

- My own `plague_countries.json.example` had a `"_comment_points"` key
  whose value was a plain string (explanatory text), not a country object -
  valid JSON, but not a valid *country*.
- `vdrx_plague.pas` never validated that; `DoTick` and `CheckWinConditions`
  both hard-cast every entry in the countries data straight to
  `TJSONObject` with no type check. The moment the tick loop iterated over
  that string entry as if it were an object, it triggered an
  `EAccessViolation`.
- Separately, and worse: `TVDRX_WorkerThread.Execute` (`vdrx_core.pas`) has
  no exception handling at all. An unhandled exception in a worker thread's
  callback doesn't crash the process - it just silently ends that one
  thread. So the tick thread died on the very first tick after `start_game`,
  with **zero log output**, and the game just... stopped. No error, no
  crash, nothing - looked exactly like "the bugs are still there" with no
  clue why.

**Fixed, three parts:**

1. `LoadCountries` now filters out any non-object entry at load time,
   logging a warning per skipped key, instead of trusting the file blindly.
   This is the actual fix - it's the one place external data enters the
   process, so it's the right choke point to validate at, rather than
   defending every consumer.
2. Removed the offending `"_comment_points"` entry from
   `plague_countries.json.example` and moved that guidance into this doc
   instead of leaving it as a stray JSON field.
3. Wrapped the `DoTick` call in `TickLoop` in its own try/except that logs
   and skips a bad tick instead of letting it kill the thread silently.
   This is a permanent addition, not a leftover from debugging: it's a real
   gap in the framework (`TVDRX_WorkerThread` doesn't guard its callback),
   and without it any future bug in `DoTick` reproduces this exact
   "game silently freezes, no error anywhere" failure mode. Worth
   considering the same guard for other `TVDRX_WorkerThread` users if you
   hit something similar elsewhere - I only touched plague's own thread
   here rather than changing the shared base class unasked.

## 4. Design bug, not a crash: spread scaled off population, not off carriers

Found this while root-causing #3, but it's serious enough to flag
separately since it doesn't crash anything, it just makes the game
nonsensical: the original spread formula was

```
NewInfections := Susceptible * BaseSpreadRate * (Infectivity/100) * (1 - quarantine/100)
```

That's a fraction of the *entire population*, independent of how many
people are actually carrying the disease. With 1 case seeded in a
331-million-person country, tick one alone produced **~650,000 new
infections** - regardless of infectivity, regardless of anything a player
does. Every game would be over in 2-3 ticks no matter what.

**Fixed** to the standard epidemic shape (new infections driven by current
carrier count, scaled by exposure opportunity):

```
NewInfections := Infected * ContactsPerInfectedPerTick * (Infectivity/100)
                  * (Susceptible/Population) * (1 - quarantine/100)
```

Verified this produces a proper exponential curve: 1 → 2 → 4 → 9 → 22 → 54 →
134 → 334 → 834 over 9 ticks (1-second ticks, infectivity 10) - slow start,
accelerating spread, room for defenders to actually react. `ContactsPerInfectedPerTick`
(15, tune-able) is the new single knob for base contagiousness, same spot as
the old `BaseSpreadRate` was.

## What was NOT touched

`vdrx_http.pas` - already correct on your end (has `FPlague`, has the routes,
has your own `CLIRoutes` addition); no changes needed there this round, so
it's not included in this delivery to avoid you overwriting your current
work with a stale copy. Only `vdrx_plague.pas`, `vdrx_weblistener.pas`, and
`vdrx_daemon.lpr` changed.

## Verification performed

Actually ran the compiled daemon (not just compiled it): started it with a
real config, hit `/plague`, `/plague/state`, `/plague/countries` over HTTP,
then drove a full game over a real WebSocket connection - `join` x2,
`seed_pathogen`, `start_game`, 12 ticks, then `evolve_trait`, `invest_cure`,
`quarantine` - and confirmed state updates landed correctly in each
`plague.delta` broadcast with no crash and no silent thread death.
