program vrdx_daemon;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,
  vrdx_core,
  vrdx_config,
  vrdx_admin,
  vrdx_logger,
  vrdx_irc,
  vrdx_bridge,
  vrdx_websocket,
  vrdx_whiteboard,
  vrdx_http,
  vrdx_socketlistener,
  vrdx_weblistener;

var
  Kernel: TVRDX_Kernel;
  Config: TVRDX_Config;
  Admin: TVRDX_AdminExecutive;
  Logger: TVRDX_LoggerExecutive;
  IRCD: TVRDX_IRCDExecutive;

begin
  Kernel := TVRDX_Kernel.Create;

  Config := TVRDX_Config.Create('vrdx_daemon.conf');

  // Subscribes to everything under log.* - any executive's Bus.Publish of a
  // log.info/log.warn/log.error topic ends up here, colored on the console and
  // plain in vrdx_daemon.log.
  Logger := TVRDX_LoggerExecutive.Create(Kernel.Queue, 'vrdx_daemon.log', lvlINFO);
  Kernel.Registry.Register(Logger, 'logger', 'log.>');

  // Listens for 'sys.reload' - reloads vrdx_daemon.conf and re-applies it to every
  // registered executive. Not required for the basic IRCD test, but cheap to have
  // wired up if you want to test config reload too (e.g. by publishing 'sys.reload'
  // from a future admin path).
  Admin := TVRDX_AdminExecutive.Create(Kernel.Queue, Config, Kernel.Registry);
  Kernel.Registry.Register(Admin, 'admin', 'sys.reload');

  IRCD := TVRDX_IRCDExecutive.Create(Kernel.Queue, Config);
  IRCD.Port := Config.GetInteger('executives.ircd.port', 6667);
  Kernel.Registry.Register(IRCD, 'ircd', 'sys.none'); // doesn't consume bus messages itself

  Kernel.Start; // Execute() calls Registry.InitializeAll - this is what actually
                // binds IRCD's listening socket and starts its accept thread

  WriteLn('VDRX daemon running.');
  WriteLn('  IRCD listening on port ', IRCD.Port, ' - connect with HexChat to test.');
  WriteLn('  Logger writing to vrdx_daemon.log (console threshold: INFO).');
  WriteLn('Press ENTER to stop...');
  ReadLn;

  Kernel.Terminate;
  Kernel.WaitFor;
  Kernel.Free;
  Config.Free;

  WriteLn('Daemon stopped.');
end.
