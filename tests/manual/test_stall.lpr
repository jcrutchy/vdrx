program test_stall;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils, Classes, vdrx_core, vdrx_bridge, vdrx_logger, vdrx_procutil;

var
  Kernel: TVDRX_Kernel;
  Bridge: TVDRX_BridgeExecutive;
  Logger: TVDRX_LoggerExecutive;
  i: Integer;
begin
  InstallShutdownSignalHandler;
  Kernel := TVDRX_Kernel.Create;

  Logger := TVDRX_LoggerExecutive.Create(Kernel.Queue, 'test_stall.log', lvlINFO);
  Kernel.Registry.Register(Logger, 'logger', 'log.>');

  Bridge := TVDRX_BridgeExecutive.Create(Kernel.Queue);
  Bridge.Command := 'sleep 100'; // alive, never reads stdin -> pipe buffer fills, then wedges
  Bridge.SendStallMs := 2000;    // shortened from the 5000ms default so this test finishes quickly
  Bridge.GracefulTimeoutMs := 1000;
  Kernel.Registry.Register(Bridge, 'stall_test', 'stall_test.in');

  Kernel.Start;
  Sleep(500); // let StartProcess/reader/send/monitor threads spin up
  WriteLn('Initial child PID: ', Bridge.CurrentPID);

  WriteLn('--- Flooding stall_test.in to fill the pipe buffer and wedge the child ---');
  for i := 1 to 50000 do
    Kernel.Queue.Publish('stall_test.in', StringOfChar('x', 200), 'test');

  WriteLn('--- Queued 50000 lines. Polling CurrentPID to confirm the wedged child actually gets killed+restarted ---');
  for i := 1 to 8 do
  begin
    Sleep(1000);
    WriteLn('  t+', i, 's: child PID = ', Bridge.CurrentPID);
  end;

  WriteLn('--- Requesting shutdown ---');
  Kernel.Queue.Publish('kernel.shutdown', '', 'test');
  Kernel.WaitFor;
  Kernel.Free;
  WriteLn('--- Done. See test_stall.log for the full timeline. ---');
end.

