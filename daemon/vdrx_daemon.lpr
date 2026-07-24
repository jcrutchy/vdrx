program vdrx_daemon;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,
  vdrx_core,
  vdrx_config,
  vdrx_admin,
  vdrx_logger,
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
  IRCD: TVDRX_IRCDExecutive;
  Whiteboard: TVDRX_WhiteboardExecutive;
  WS: TVDRX_WebSocketExecutive;
  HTTP: TVDRX_HTTPExecutive;

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

begin
  Kernel := TVDRX_Kernel.Create;

  Config := TVDRX_Config.Create('vdrx_daemon.conf');

  // Subscribes to everything under log.* - any executive's Bus.Publish of a
  // log.info/log.warn/log.error topic ends up here, colored on the console and
  // plain in vdrx_daemon.log.
  Logger := TVDRX_LoggerExecutive.Create(Kernel.Queue, 'vdrx_daemon.log', lvlINFO);
  Kernel.Registry.Register(Logger, 'logger', 'log.>');
  Kernel.Registry.Register(Logger, 'logger', 'irc.>');

  // Listens for 'sys.reload' - reloads vdrx_daemon.conf and re-applies it to every
  // registered executive.
  Admin := TVDRX_AdminExecutive.Create(Kernel.Queue, Config, Kernel.Registry);
  Kernel.Registry.Register(Admin, 'admin', 'sys.reload');

  if Config.GetBoolean('executives.ircd.enabled', True) then
  begin
    IRCD := TVDRX_IRCDExecutive.Create(Kernel.Queue, Config, Kernel.Registry);
    IRCD.Port := Config.GetInteger('executives.ircd.port', 6667);
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
    ConfigureListenerTLS(WS, 'executives.ws');
    Kernel.Registry.Register(WS, 'ws', 'sys.none'); // each connection registers itself
  end;

  if Config.GetBoolean('executives.http.enabled', False) then
  begin
    HTTP := TVDRX_HTTPExecutive.Create(Kernel.Queue, Config, Whiteboard);
    HTTP.Port := Config.GetInteger('executives.http.port', 8081);
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
  WriteLn('Press ENTER to stop...');
  ReadLn;

  Kernel.Terminate;
  Kernel.WaitFor;
  Kernel.Free;
  Config.Free;

  WriteLn('Daemon stopped.');
end.
