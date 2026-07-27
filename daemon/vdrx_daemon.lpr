program vdrx_daemon;

{
  todo list:
    1. serve http requests using templates
    2. flesh out the whiteboard features and get it working properly
    3. build a web page that makes ajax requests, has a websocket connection, and an irc connection, all via a single port to the daemon
         (why? probably no practical reason, but will demonstrate features and flexibility of the daemon)
    4. some more ircd features (built-in nickserv & chanserv)
    5. simple multiplayer web-based plague inc game
    6. web-based mud game
}

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  StrUtils,
  SysUtils,
  Process,
  vdrx_core,
  vdrx_config,
  vdrx_admin,
  vdrx_logger,
  vdrx_stdin,
  vdrx_irc,
  vdrx_bridge,
  vdrx_websocket,
  vdrx_whiteboard,
  vdrx_http,
  vdrx_socketlistener,
  vdrx_weblistener,
  vdrx_templates;

var
  Kernel: TVDRX_Kernel;
  Config: TVDRX_Config;
  Admin: TVDRX_AdminExecutive;
  Logger: TVDRX_LoggerExecutive;
  Stdin: TVDRX_StdinExecutive;
  IRCD: TVDRX_IRCDExecutive;
  Whiteboard: TVDRX_WhiteboardExecutive;
  WS: TVDRX_WebSocketExecutive;
  HTTP: TVDRX_HTTPExecutive;
  Templates: TVDRX_TemplateStore;
  ProxyRoutes: TVDRX_ProxyRoutes;
  ShutdownGraceMs: Integer;
  DoRestart: Boolean;
  NewProc: TProcess;
  i: Integer;

procedure ConfigureListenerTLS(AListener: TVDRX_SocketListenerExecutive; const AKeyPrefix: string);
begin
  AListener.ConfigureTLS(
    Config.GetInteger(AKeyPrefix + '.tls_port', 0),
    Config.GetString(AKeyPrefix + '.tls_cert', ''),
    Config.GetString(AKeyPrefix + '.tls_key', ''));
end;

procedure ReportListener(AListener: TVDRX_SocketListenerExecutive; const AName: string);
begin
  WriteLn('  ', AName, ' listening on port ', AListener.Port, '.');
  if AListener.TLSActive then
    WriteLn('  ', AName, ' also listening TLS on port ', AListener.TLSPort, '.')
  else if AListener.TLSPort <> 0 then
    WriteLn('  ', AName, ' TLS was configured (port ', AListener.TLSPort,
      ') but failed to come up - check tls_cert/tls_key and that libssl is loadable.');
end;

procedure SetupProxyBridges(AConfig: TVDRX_Config; ARegistry: TVDRX_Registry;
  AGracefulMs: Integer; out ARoutes: TVDRX_ProxyRoutes);
var
  Rows: TVDRX_ConfigRows;
  Row: TStringList;
  Bridge: TVDRX_BridgeExecutive;
  n, BridgeGraceMs: Integer;
begin
  SetLength(ARoutes, 0);
  Rows := AConfig.GetObjectArray('proxy_bridges');
  try
    for Row in Rows do
    begin
      if (Row.Values['id'] = '') or (Row.Values['command'] = '') or (Row.Values['prefix'] = '') then
      begin
        WriteLn('  Skipping proxy_bridges entry - needs id, prefix, and command.');
        Continue;
      end;
      Bridge := TVDRX_BridgeExecutive.Create(Kernel.Queue);
      Bridge.Command := Row.Values['command'];
      // Most simple dev web servers (php -S included) don't respond to a
      // graceful-shutdown hint at all - SIGTERM does work on Unix, but
      // there's genuinely no equivalent on Windows (see vdrx_procutil.pas's
      // TryGracefulTerminate). Waiting the full shutdown_grace_ms on every
      // quit/restart just to then force-kill it anyway wastes real time -
      // override per-bridge via "graceful_timeout_ms" in its proxy_bridges
      // entry; falls back to the daemon-wide default if not set.
      BridgeGraceMs := StrToIntDef(Row.Values['graceful_timeout_ms'], AGracefulMs);
      Bridge.GracefulTimeoutMs := BridgeGraceMs;
      ARegistry.Register(Bridge, Row.Values['id'], 'sys.none');

      n := Length(ARoutes);
      SetLength(ARoutes, n + 1);
      ARoutes[n].Prefix := Row.Values['prefix'];
      ARoutes[n].Host := IfThen(Row.Values['host'] <> '', Row.Values['host'], '127.0.0.1');
      ARoutes[n].Port := StrToIntDef(Row.Values['port'], 0);
      WriteLn('  Proxy bridge "', Row.Values['id'], '": ', ARoutes[n].Prefix, ' -> ',
        ARoutes[n].Host, ':', ARoutes[n].Port, ' (', Row.Values['command'],
        ', graceful_timeout_ms=', BridgeGraceMs, ')');
    end;
  finally
    Rows.Free;
  end;
end;

procedure SetupCLIBridges(AConfig: TVDRX_Config; out ARoutes: TVDRX_CLIRoutes);
var
  Rows: TVDRX_ConfigRows;
  Row: TStringList;
  n: Integer;
begin
  SetLength(ARoutes, 0);
  Rows := AConfig.GetObjectArray('cli_bridges');
  try
    for Row in Rows do
    begin
      if (Row.Values['id'] = '') or (Row.Values['command'] = '') or (Row.Values['prefix'] = '') or (Row.Values['script_dir'] = '') then
      begin
        WriteLn('  Skipping cli_bridges entry - needs id, prefix, command, and script_dir.');
        Continue;
      end;
      n := Length(ARoutes);
      SetLength(ARoutes, n + 1);
      ARoutes[n].Prefix := Row.Values['prefix'];
      ARoutes[n].Command := Row.Values['command'];
      ARoutes[n].ScriptDir := Row.Values['script_dir'];
      ARoutes[n].TimeoutMs := StrToIntDef(Row.Values['timeout_ms'], 5000);
      ARoutes[n].ContentType := IfThen(Row.Values['content_type'] <> '', Row.Values['content_type'], 'text/html');
      WriteLn('  CLI bridge "', Row.Values['id'], '": ', ARoutes[n].Prefix, ' -> ',
        ARoutes[n].Command, ' ', ARoutes[n].ScriptDir, '/* (timeout_ms=', ARoutes[n].TimeoutMs, ')');
    end;
  finally
    Rows.Free;
  end;
end;

begin
  Kernel := TVDRX_Kernel.Create;

  Config := TVDRX_Config.Create('vdrx_daemon.conf');
  ShutdownGraceMs := Config.GetInteger('shutdown_grace_ms', 5000);

  // Subscribes to everything under log.* - any executive's Bus.Publish of a
  // log.info/log.warn/log.error topic ends up here, colored on the console and
  // plain in vdrx_daemon.log.
  Logger := TVDRX_LoggerExecutive.Create(Kernel.Queue, 'vdrx_daemon.log', lvlINFO);
  //Kernel.Registry.Register(Logger, 'logger', 'log.>');
  //Kernel.Registry.Register(Logger, 'logger', 'irc.>');
  Kernel.Registry.Register(Logger, 'logger', '>');

  // Listens on 'sys.>' - reload/quit/restart/kill/killall. See vdrx_admin.pas
  // and vdrx_admincmd.pas for the full command set and who can trigger it
  // (stdin below, and IRC "!" commands in vdrx_irc.pas's DoPrivMsg).
  Admin := TVDRX_AdminExecutive.Create(Kernel.Queue, Config, Kernel.Registry, Kernel);
  Kernel.Registry.Register(Admin, 'admin', 'sys.>');

  // Reads quit/restart/reload/kill/killall commands typed at the console.
  // Replaces the old "press ENTER to stop" main-thread ReadLn.
  if Config.GetBoolean('stdin_admin_enabled', True) then
  begin
    Stdin := TVDRX_StdinExecutive.Create(Kernel.Queue);
    Kernel.Registry.Register(Stdin, 'stdin', 'sys.none'); // doesn't consume bus messages, only publishes
  end;

  if Config.GetBoolean('executives.ircd.enabled', True) then
  begin
    IRCD := TVDRX_IRCDExecutive.Create(Kernel.Queue, Config, Kernel.Registry);
    IRCD.Port := Config.GetInteger('executives.ircd.port', 6667);
    IRCD.GracefulTimeoutMs := ShutdownGraceMs;
    ConfigureListenerTLS(IRCD, 'executives.ircd');
    Kernel.Registry.Register(IRCD, 'ircd', 'sys.none'); // doesn't consume bus messages itself
  end;

  // In-memory board state (persisted under data_dir) - registered before HTTP/WS
  // since both reference it directly.
  Whiteboard := TVDRX_WhiteboardExecutive.Create(Kernel.Queue,
    Config.GetString('executives.whiteboard.data_dir', 'vdrx_data' + PathDelim + 'whiteboard'));
  Kernel.Registry.Register(Whiteboard, 'whiteboard', 'wb.*.delta');

  if Config.GetBoolean('executives.ws.enabled', False) then
  begin
    WS := TVDRX_WebSocketExecutive.Create(Kernel.Queue, Config, Kernel.Registry);
    WS.Port := Config.GetInteger('executives.ws.port', 8082);
    WS.GracefulTimeoutMs := ShutdownGraceMs;
    ConfigureListenerTLS(WS, 'executives.ws');
    Kernel.Registry.Register(WS, 'ws', 'sys.none'); // each connection registers itself
  end;

  SetupProxyBridges(Config, Kernel.Registry, ShutdownGraceMs, ProxyRoutes);
  SetupCLIBridges(Config, CLIRoutes);

  Templates := TVDRX_TemplateStore.Create(Config, Config.GetString('template_dir', 'templates'));
  if Config.GetBoolean('executives.http.enabled', False) then
  begin
    HTTP := TVDRX_HTTPExecutive.Create(Kernel.Queue, Config, Whiteboard, Templates,
      Config.GetString('static_dir', 'static'), ProxyRoutes, CLIRoutes);
    HTTP.Port := Config.GetInteger('executives.http.port', 8081);
    HTTP.GracefulTimeoutMs := ShutdownGraceMs;
    ConfigureListenerTLS(HTTP, 'executives.http');
    Kernel.Registry.Register(HTTP, 'http', 'sys.none');
  end;

  Kernel.Start; // Execute() calls Registry.InitializeAll - this is what actually
                // binds every listener's socket(s) and starts its accept thread(s)

  WriteLn('VDRX daemon running.');
  if Assigned(IRCD) then ReportListener(IRCD, 'IRCD');
  if Assigned(WS) then ReportListener(WS, 'WebSocket');
  if Assigned(HTTP) then ReportListener(HTTP, 'HTTP');
  WriteLn('  Whiteboard persisting to ', Config.GetString('executives.whiteboard.data_dir', 'vdrx_data' + PathDelim + 'whiteboard'), '.');
  WriteLn('  Logger writing to vdrx_daemon.log (console threshold: INFO).');
  if Assigned(Stdin) then
    WriteLn('  Type quit / restart / reload / kill <pid-or-id> / killall [type] and press Enter to control the daemon.');
  WriteLn('  Shutdown grace period: ', ShutdownGraceMs, 'ms before hung threads/processes are force-killed.');

  Kernel.WaitFor; // returns once sys.quit/sys.restart has driven Kernel.Terminate
                   // and ShutdownAll has finished tearing everything down cleanly
  DoRestart := Kernel.RestartRequested; // read before Free below
  Kernel.Free;
  Templates.Free;
  Config.Free;

  WriteLn('Daemon stopped.');

  if DoRestart then
  begin
    WriteLn('Respawning...');
    NewProc := TProcess.Create(nil);
    try
      NewProc.Executable := ParamStr(0);
      for i := 1 to ParamCount do
        NewProc.Parameters.Add(ParamStr(i));
      NewProc.CurrentDirectory := GetCurrentDir;
      NewProc.Options := []; // detached - don't wait, don't inherit our pipes;
                              // the new instance keeps running independently
                              // once Execute returns
      NewProc.Execute;
    finally
      NewProc.Free; // doesn't own/stop the spawned OS process
    end;
  end;
end.
