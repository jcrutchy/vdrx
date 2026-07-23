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

  IRCD := TVRDX_IRCDExecutive.Create(Kernel.Queue, Config, Kernel.Registry);
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

  IRCD := TVRDX_IRCDExecutive.Create(Kernel.Queue, Config, Kernel.Registry);
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

## Transport layer (plain TCP + TLS), added this session

`vrdx_socketlistener.pas`'s `HandleConnection` now takes a `TVRDX_Transport`
(see new unit `vrdx_transport.pas`) instead of a raw `TSocket`. Every protocol
executive (`vrdx_http.pas`, `vrdx_websocket.pas`, `vrdx_irc.pas`,
`vrdx_weblistener.pas`) reads/writes through `ATransport.Read`/`.Write`/`.Close`
instead of `fpRecv`/`fpSend`/`CloseSocket` directly, so none of them know or care
whether a connection is plaintext or TLS.

`TVRDX_SocketListenerExecutive` can now bind a plain port and a TLS port at the
same time (`Port` and `ConfigureTLS(TLSPort, CertFile, KeyFile)`) - two accept
loops, one per transport, both feeding the same `HandleConnection`. That's what
lets a client choose encrypted or not: e.g. IRCD on 6667 plain + 6697 TLS
simultaneously. If the cert/key fail to load, the TLS side just doesn't come up -
the plain side (if configured) is unaffected.

Config keys per socket-listener executive (see `vrdx_daemon.conf`):
`port`, `tls_port` (0 = disabled), `tls_cert`, `tls_key` (absolute paths). IRCD is
wired up in `vrdx_daemon.lpr`; HTTP/WS classes support the same keys
(`executives.http.*` / `executives.ws.*`) and their own `ApplyConfig`, but aren't
instantiated in `vrdx_daemon.lpr` yet - marked `"enabled": false` in the conf as a
placeholder until they're wired in.

Verified by compiling and a live TLS 1.3 handshake this session (see below) - the
`SSLv23_server_method` guess from the first pass was wrong and has been replaced.

**Two real things found by actually compiling/running this, not just reading the code:**

1. FPC's bundled `openssl` unit (`/usr/share/fpcsrc/<ver>/packages/openssl/src/openssl.pas`)
   is a dynamically-loaded (dlopen-style) binding with Pascal-cased names -
   `SslNew`, `SslCtxNew`, `SslAccept`, `SslRead`/`SslWrite`, `SslShutdown`,
   `SslCtxUseCertificateFile`, `SslCtxUsePrivateKeyFile`, `SslCtxFree` - NOT the
   raw C API names (`SSL_new` etc). It also has no separate server/client method
   functions; use `SslTLSMethod` (loads the modern `TLS_method` symbol) for
   `SslCtxNew`. `SslMethodV23` (`SSLv23_method`) is explicitly unavailable on
   OpenSSL 1.1+/3.x - the unit itself flags it as "method not supported by lib".
   `vrdx_transport.pas` now uses the correct names throughout.

2. On Debian/Ubuntu, that unit `dlopen`s the bare filenames `libssl`/`libcrypto`
   (no version suffix). The runtime package (`libssl3`) only ships the versioned
   `libssl.so.3` - the unversioned `libssl.so` symlink it's actually looking for
   only exists once **`libssl-dev` is installed**. Without it, `InitSSLInterface`
   silently returns `False`, `SslCtxNew` returns `nil`, and the TLS listener just
   never binds - no exception, no error on stdout, `ConfigureTLS`'s cert/key load
   just quietly fails and only the plain port comes up. **Install `libssl-dev`
   (or your distro's dev/headers package for OpenSSL) on the box actually running
   the daemon, not just at compile time - it's a runtime dependency here, because
   of the dlopen approach.**

`TVRDX_SocketListenerExecutive.TLSActive` reflects real go-live status now (TLS
port configured AND cert/key loaded AND accept loop started), separate from
`TLSPort` which just reflects what was asked for - `vrdx_daemon.lpr`'s startup
banner uses this to tell "TLS is up" apart from "TLS was requested but failed",
which is exactly the distinction that was missing when this bit us.
