program vdrx_daemon;

{$mode ObjFPC}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils,
  vrdx_core,
  vrdx_irc;

var
  Kernel: TVRDX_Kernel;
begin
  Kernel := TVRDX_Kernel.Create;
  Kernel.Start;

  // Do other things (like load config, wait for user input, listen to signals)
  WriteLn('Kernel running. Press ENTER to stop...');
  ReadLn;

  WriteLn('Shutting down...');
  Kernel.Terminate;
  Kernel.WaitFor;
  Kernel.Free;
  WriteLn('Exited cleanly.');
end.
