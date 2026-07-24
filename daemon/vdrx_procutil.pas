unit vdrx_procutil;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Process
  {$IFDEF UNIX}, BaseUnix{$ENDIF};

// Polls AThread.Finished instead of a blocking WaitFor, so callers can give a
// thread a bounded grace period to exit on its own before escalating to a
// forced close/kill. Returns True if the thread finished within the window.
function WaitThreadOrTimeout(AThread: TThread; ATimeoutMs: Integer): Boolean;

// Same idea for an external process - polls Running instead of blocking.
function WaitProcessOrTimeout(AProcess: TProcess; ATimeoutMs: Integer): Boolean;

// Best-effort "please exit" signal. SIGTERM on Unix; on Windows there's no
// portable equivalent for an arbitrary console child without attaching a
// console (out of scope for a dependency-free daemon), so this is a no-op
// there - closing the process's stdin (see vdrx_bridge.pas) is the only
// "polite" hint Windows children get before the hard kill below.
procedure TryGracefulTerminate(AProcess: TProcess);

// Unconditional kill of the process. Unix: SIGKILL. Windows:
// 'taskkill /PID <n> /T /F', which kills the whole process tree in one shot
// (Unix doesn't get the same tree-kill here - see WIRING.md note if that
// ever matters; most Bridge commands are single processes today).
procedure ForceKillProcess(AProcess: TProcess);

implementation

function WaitThreadOrTimeout(AThread: TThread; ATimeoutMs: Integer): Boolean;
var
  Waited: Integer;
begin
  if not Assigned(AThread) then Exit(True);
  Waited := 0;
  while (not AThread.Finished) and (Waited < ATimeoutMs) do
  begin
    Sleep(50);
    Inc(Waited, 50);
  end;
  Result := AThread.Finished;
end;

function WaitProcessOrTimeout(AProcess: TProcess; ATimeoutMs: Integer): Boolean;
var
  Waited: Integer;
begin
  if not Assigned(AProcess) then Exit(True);
  Waited := 0;
  while AProcess.Running and (Waited < ATimeoutMs) do
  begin
    Sleep(50);
    Inc(Waited, 50);
  end;
  Result := not AProcess.Running;
end;

procedure TryGracefulTerminate(AProcess: TProcess);
begin
  if not Assigned(AProcess) or not AProcess.Running then Exit;
  {$IFDEF UNIX}
  try
    FpKill(AProcess.ProcessID, SIGTERM);
  except
  end;
  {$ENDIF}
  // Windows: nothing to do here - see unit comment above.
end;

procedure ForceKillProcess(AProcess: TProcess);
{$IFDEF WINDOWS}
var
  Dummy: string;
{$ENDIF}
begin
  if not Assigned(AProcess) then Exit;
  {$IFDEF UNIX}
  try
    if AProcess.Running then
      FpKill(AProcess.ProcessID, SIGKILL);
  except
  end;
  {$ENDIF}
  {$IFDEF WINDOWS}
  try
    if AProcess.Running then
      RunCommand('taskkill', ['/PID', IntToStr(AProcess.ProcessID), '/T', '/F'], Dummy);
  except
  end;
  {$ENDIF}
  try
    if AProcess.Running then
      AProcess.Terminate(0); // belt-and-braces, also asks TProcess/the OS directly
  except
  end;
end;

end.