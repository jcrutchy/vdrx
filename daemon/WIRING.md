# Wiring these into vdrx_daemon.dpr

IRCD, HTTP, and WebSocket all now inherit their accept-loop/socket lifecycle from
`TVRDX_SocketListenerExecutive` (`vrdx_socketlistener.pas`) instead of each
duplicating it. Usage from the `.lpr` is unchanged either way - `Port`, `Initialize`,
`Shutdown` are all still there, just inherited.

## Option A: separate ports (default, unchanged in spirit)

```pascal
uses
  ..., vrdx_core, vrdx_socketlistener, vrdx_config, vrdx_admin, vrdx_logger,
  vrdx_bridge, vrdx_whiteboard, vrdx_irc, vrdx_websocket, vrdx_http;

var
  Kernel: TVRDX_Kernel;
  Config: TVRDX_Config;
  Admin: TVRDX_AdminExecutive;
  Logger: TVRDX_LoggerExecutive;
  Whiteboard: TVRDX_WhiteboardExecutive;
  IRCD: TVRDX_IRCDExecutive;
  WS: TVRDX_WebSocketExecutive;
  HTTP: TVRDX_HTTPExecutive;
  // Bridge: TVRDX_BridgeExecutive;  -- only if you have an external process to run tonight

begin
  Kernel := TVRDX_Kernel.Create;

  Config := TVRDX_Config.Create('vrdx_daemon.conf');

  Logger := TVRDX_LoggerExecutive.Create(Kernel.Queue, 'vrdx_daemon.log', lvlINFO);
  Kernel.Registry.Register(Logger, 'logger', 'log.>');

  Admin := TVRDX_AdminExecutive.Create(Kernel.Queue, Config, Kernel.Registry);
  Kernel.Registry.Register(Admin, 'admin', 'sys.reload');

  Whiteboard := TVRDX_WhiteboardExecutive.Create(Kernel.Queue);
  Kernel.Registry.Register(Whiteboard, 'whiteboard', 'wb.>');

  IRCD := TVRDX_IRCDExecutive.Create(Kernel.Queue, Config);
  Kernel.Registry.Register(IRCD, 'ircd', 'sys.none'); // doesn't consume bus messages tonight

  WS := TVRDX_WebSocketExecutive.Create(Kernel.Queue, Kernel.Registry);
  Kernel.Registry.Register(WS, 'websocket', 'sys.none');   // binds its OWN port (8082)

  HTTP := TVRDX_HTTPExecutive.Create(Kernel.Queue, Whiteboard);
  Kernel.Registry.Register(HTTP, 'http', 'sys.none');      // binds its OWN port (8081)

  Kernel.Start;      // Execute() calls Registry.InitializeAll - this is what actually
                      // binds the listening sockets and starts their threads
  WriteLn('Kernel running. Press ENTER to stop...');
  ReadLn;
  Kernel.Terminate;
  Kernel.WaitFor;
  Kernel.Free;
  Config.Free;
end.
```

## Option B: HTTP + WebSocket sharing one port (e.g. 80)

Use `TVRDX_WebListenerExecutive` (`vrdx_weblistener.pas`) instead of registering `HTTP`
and `WS` as their own listeners. `WS` still needs to exist - `TVRDX_WSConnection`
objects it creates still get registered into `Kernel.Registry` the normal way, and it
still needs `Bus`/`Registry` - it just must NOT be registered/initialized as its own
socket listener, or you'll get two listeners fighting over ports.

```pascal
uses
  ..., vrdx_weblistener;

var
  Web: TVRDX_WebListenerExecutive;

begin
  Kernel := TVRDX_Kernel.Create;
  Config := TVRDX_Config.Create('vrdx_daemon.conf');

  Logger := TVRDX_LoggerExecutive.Create(Kernel.Queue, 'vrdx_daemon.log', lvlINFO);
  Kernel.Registry.Register(Logger, 'logger', 'log.>');

  Admin := TVRDX_AdminExecutive.Create(Kernel.Queue, Config, Kernel.Registry);
  Kernel.Registry.Register(Admin, 'admin', 'sys.reload');

  Whiteboard := TVRDX_WhiteboardExecutive.Create(Kernel.Queue);
  Kernel.Registry.Register(Whiteboard, 'whiteboard', 'wb.>');

  IRCD := TVRDX_IRCDExecutive.Create(Kernel.Queue, Config);
  Kernel.Registry.Register(IRCD, 'ircd', 'sys.none');

  // WS constructed but deliberately NOT registered as a listener - it's only here
  // to give TVRDX_WebListenerExecutive somewhere to hand upgraded connections off
  // to (AdoptConnection), and to give TVRDX_WSConnection instances Bus/Registry.
  WS := TVRDX_WebSocketExecutive.Create(Kernel.Queue, Kernel.Registry);

  Web := TVRDX_WebListenerExecutive.Create(Kernel.Queue, Whiteboard, WS);
  Web.Port := 80;
  Kernel.Registry.Register(Web, 'weblistener', 'sys.none');

  Kernel.Start;
  WriteLn('Kernel running. Press ENTER to stop...');
  ReadLn;
  Kernel.Terminate;
  Kernel.WaitFor;
  Kernel.Free;
  WS.Free;      // not owned by Registry (never registered) - free it yourself
  Config.Free;
end.
```

`'sys.none'` for the listener executives is a deliberate no-op filter (it'll never
match a real topic) - they don't consume bus messages themselves tonight, only their
dynamically-registered children (`TVRDX_WSConnection`) or their reader threads
(IRCD's per-client threads) actually move data.

**Wiring order note:** `Whiteboard` must exist before `HTTP` (or `Web`) is created -
both hold a direct reference to it for the synchronous snapshot read. `Config` must
exist before `Admin` and `IRCD`. In Option B, `WS` must exist before `Web` is created.

**Test path:** HexChat -> `localhost:6667`, join any channel, `PRIVMSG` a JSON delta
as the message text (or extend `vrdx_irc`'s `PRIVMSG` handler to translate a `!wb`
command into a delta payload, as sketched earlier) -> Whiteboard applies + republishes
-> any WS connections subscribed to `wb.board1.>` receive it live. `GET
localhost:8081/board/board1` (Option A) or `GET localhost/board/board1` (Option B)
gives a synchronous snapshot for a fresh page load.

**Config reload path:** publish `sys.reload` onto the bus and `Admin` reloads
`vrdx_daemon.conf` and re-applies it to every registered executive via their
`ApplyConfig` hook.

**Not included tonight, flagged as deferred (matches earlier session notes):**
- BucketStore/persistence for Whiteboard
- Real `sys.auth` token verification in the WS executive
- RBAC on `sys.*`/`admin.*`
- Per-connection thread tracking in `TVRDX_SocketListenerExecutive.Shutdown`
  (currently only the accept-loop thread is joined; live per-connection threads
  unblock via socket close but aren't explicitly waited on)
- Decoupling `TVRDX_WSConnection.HandlePacket` from the Kernel's dispatch thread via
  a per-connection mailbox/event, so one slow client's `fpSend` can't stall delivery
  to every other subscriber of a topic - noted as a real but separate upgrade from
  everything in this document, not yet implemented
