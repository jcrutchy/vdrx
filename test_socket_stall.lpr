program test_socket_stall;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils, Classes, vdrx_core, vdrx_network, vdrx_logger, vdrx_procutil;

var
  Kernel: TVDRX_Kernel;
  SC: TVDRX_SocketClientExecutive;
  Logger: TVDRX_LoggerExecutive;
  i: Integer;
begin
  InstallShutdownSignalHandler;
  Kernel := TVDRX_Kernel.Create;

  Logger := TVDRX_LoggerExecutive.Create(Kernel.Queue, 'test_socket_stall.log', lvlINFO);
  Kernel.Registry.Register(Logger, 'logger', 'log.>');

  SC := TVDRX_SocketClientExecutive.Create(Kernel.Queue);
  SC.Host := '127.0.0.1';
  SC.Port := 19191;
  SC.WriteTimeoutMs := 1000; // shortened from the 5000ms default for a fast test
  SC.ReconnectDelayMs := 500;
  Kernel.Registry.Register(SC, 'sock_test', 'sock_test.in');

  Kernel.Start;
  Sleep(800); // let DoConnect complete

  WriteLn('--- Flooding sock_test.in to fill the socket buffer against a peer that never reads ---');
  for i := 1 to 200000 do
    Kernel.Queue.Publish('sock_test.in', StringOfChar('y', 500), 'test');

  WriteLn('--- Queued 200000 lines (~100MB). Waiting to observe write-timeout + reconnect ---');
  Sleep(8000);

  WriteLn('--- Requesting shutdown ---');
  Kernel.Queue.Publish('kernel.shutdown', '', 'test');
  Kernel.WaitFor;
  Kernel.Free;
  WriteLn('--- Done. See test_socket_stall.log for the full timeline. ---');
end.

