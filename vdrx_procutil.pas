unit vdrx_procutil;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Process
  {$IFDEF UNIX}, BaseUnix{$ENDIF}
  {$IFDEF WINDOWS}, Windows{$ENDIF};

// Polls AThread.Finished instead of a blocking WaitFor, so callers can give a
// thread a bounded grace period to exit on its own before escalating to a
// forced close/kill. Returns True if the thread finished within the window.
function WaitThreadOrTimeout(AThread: TThread; ATimeoutMs: Integer): Boolean;

type
  TVDRX_RunResult = (rrExited, rrStartFailed, rrTimedOut);

// Runs ACommandLine (program + space-separated args, FPC TProcess quoting
// rules) to completion: AStdin is written to the program's stdin and closed,
// stdout and stderr are collected SEPARATELY (both byte-exact - binary safe),
// and AExitCode is its exit code. AWorkDir '' = the daemon's own directory.
// Never waits longer than ATimeoutMs (<= 0 = no limit): on expiry the program is
// force-killed and rrTimedOut returned. rrStartFailed puts the reason in AError.
// Blocking - call it from a worker/connection thread, never from HandlePacket.
function RunProgramCapture(const ACommandLine, AWorkDir, AStdin: string;
  ATimeoutMs: Integer; out AExitCode: Integer;
  out AStdout, AStderr, AError: string): TVDRX_RunResult;

// Same, but with the program and its arguments already separated - no string
// splitting or quoting rules involved, so argument values can contain anything
// (spaces, quotes) and are never re-interpreted. Prefer this whenever any part
// of the argument list comes from outside the config file.
function RunProgramCaptureArgs(const AExe: string; AArgs: TStrings;
  const AWorkDir, AStdin: string; ATimeoutMs: Integer; out AExitCode: Integer;
  out AStdout, AStderr, AError: string): TVDRX_RunResult;

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

// True once Ctrl+C (SIGINT), Ctrl+Break, a window-close, or SIGTERM has been
// caught by InstallShutdownSignalHandler below - vdrx.lpr's main polls this
// (see TShutdownWatcherThread there) and calls Kernel.Terminate from
// ordinary thread context when it flips, rather than doing any of that work
// IN the handler itself. Deliberately just a plain global boolean: a signal
// handler (Unix) or console control handler (Windows) both run in a
// restricted context where allocating memory, taking a lock, or touching the
// FPC heap manager isn't guaranteed safe - Kernel.Terminate does all three
// (it Publishes a message, which takes a lock). A single aligned boolean
// write has no such hazard on any platform this targets, so that's ALL
// either handler below ever does.
var
  GShutdownRequested: Boolean;

// Installs a Ctrl+C/SIGINT (and SIGTERM, and on Windows also Ctrl+Break/
// close/logoff/shutdown) handler that sets GShutdownRequested. Call once,
// early in program startup, before the kernel thread and its watcher start.
// Without this, the OS's own default SIGINT/Ctrl+C behavior applies instead
// - immediate termination, with none of VDRX's own shutdown code (Bridge's
// TryGracefulTerminate-then-wait-then-ForceKillProcess for every supervised
// child, sockets closed, buckets flushed) ever running at all. What actually
// happens to child processes in THAT case is platform- and console-session-
// dependent rather than something VDRX controls - Windows delivers the same
// CTRL_C_EVENT to every process still attached to the same console (so
// children often die too, but "often" is doing a lot of work in that
// sentence - a child that's detached its own console, or is on Unix in a
// different process group, won't), and Unix's terminal driver typically
// signals the whole foreground process group, not specifically vdrx's own
// children - either way, it's the terminal doing it by accident, not VDRX
// doing it on purpose, and there's no per-child grace period at all.
procedure InstallShutdownSignalHandler;

implementation

function RunProgramCaptureArgs(const AExe: string; AArgs: TStrings;
  const AWorkDir, AStdin: string; ATimeoutMs: Integer; out AExitCode: Integer;
  out AStdout, AStderr, AError: string): TVDRX_RunResult;
var
  Proc: TProcess;
  i: Integer;
  Buf: array[0..8191] of Byte;
  N, Got: Integer;
  WasRunning: Boolean;
  Started: QWord;
  Found: string;
begin
  AExitCode := 0;
  AStdout := '';
  AStderr := '';
  AError := '';
  Result := rrExited;
  Proc := TProcess.Create(nil);
  try
    Proc.Executable := AExe;
    if Assigned(AArgs) then
      for i := 0 to AArgs.Count - 1 do
        Proc.Parameters.Add(AArgs[i]);
    if AWorkDir <> '' then Proc.CurrentDirectory := ExpandFileName(AWorkDir);
    if not FileExists(Proc.Executable) then
    begin
      Found := ExeSearch(Proc.Executable, SysUtils.GetEnvironmentVariable('PATH'));
      if Found <> '' then Proc.Executable := Found;
    end;
    Proc.Options := [poUsePipes]; // stdout and stderr stay separate
    try
      Proc.Execute;
    except
      on E: Exception do
      begin
        AError := E.Message;
        Result := rrStartFailed;
        Exit;
      end;
    end;

    try
      if AStdin <> '' then Proc.Input.Write(AStdin[1], Length(AStdin));
    except
      // program closed stdin early - its exit code / stderr will explain
    end;
    try Proc.CloseInput; except end;

    Started := GetTickCount64;
    repeat
      // Sample "running" BEFORE draining: if it had already exited and the
      // drain finds nothing, every byte it wrote has been collected.
      WasRunning := Proc.Running;
      Got := 0;
      while Proc.Output.NumBytesAvailable > 0 do
      begin
        N := Proc.Output.Read(Buf[0], SizeOf(Buf));
        if N <= 0 then Break;
        SetLength(AStdout, Length(AStdout) + N);
        Move(Buf[0], AStdout[Length(AStdout) - N + 1], N);
        Inc(Got, N);
      end;
      while Proc.Stderr.NumBytesAvailable > 0 do
      begin
        N := Proc.Stderr.Read(Buf[0], SizeOf(Buf));
        if N <= 0 then Break;
        SetLength(AStderr, Length(AStderr) + N);
        Move(Buf[0], AStderr[Length(AStderr) - N + 1], N);
        Inc(Got, N);
      end;
      if (Got = 0) and WasRunning then
      begin
        if (ATimeoutMs > 0) and (GetTickCount64 - Started > QWord(ATimeoutMs)) then
        begin
          ForceKillProcess(Proc);
          Result := rrTimedOut;
          Exit;
        end;
        Sleep(2);
      end;
    until (not WasRunning) and (Got = 0);

    AExitCode := Proc.ExitStatus;
    {$IFDEF UNIX}
    // FPC 3.2 returns the raw wait() status (exit code 1 arrives as 256);
    // newer versions return the plain code. Handle both.
    if (AExitCode >= 256) and ((AExitCode and $FF) = 0) then AExitCode := AExitCode shr 8;
    {$ENDIF}
  finally
    Proc.Free;
  end;
end;

function RunProgramCapture(const ACommandLine, AWorkDir, AStdin: string;
  ATimeoutMs: Integer; out AExitCode: Integer;
  out AStdout, AStderr, AError: string): TVDRX_RunResult;
var
  Parts: TStringList;
  Args: TStringList;
  i: Integer;
begin
  Parts := TStringList.Create;
  Args := TStringList.Create;
  try
    CommandToList(ACommandLine, Parts);
    if Parts.Count = 0 then
    begin
      AExitCode := 0;
      AStdout := '';
      AStderr := '';
      AError := 'empty command line';
      Exit(rrStartFailed);
    end;
    for i := 1 to Parts.Count - 1 do
      Args.Add(Parts[i]);
    Result := RunProgramCaptureArgs(Parts[0], Args, AWorkDir, AStdin, ATimeoutMs,
      AExitCode, AStdout, AStderr, AError);
  finally
    Args.Free;
    Parts.Free;
  end;
end;

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

{$IFDEF UNIX}
procedure UnixShutdownSignalHandler(Sig: LongInt); cdecl;
begin
  // See GShutdownRequested's comment - this is the ENTIRE handler,
  // deliberately. No WriteLn (does I/O + its own locking), no Bus.Publish,
  // nothing else - a plain boolean write is the one thing guaranteed safe
  // to do from here.
  GShutdownRequested := True;
end;
{$ENDIF}

{$IFDEF WINDOWS}
function WindowsShutdownCtrlHandler(dwCtrlType: DWORD): BOOL; stdcall;
begin
  case dwCtrlType of
    CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT, CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT:
      begin
        GShutdownRequested := True;
        Result := True; // handled - suppresses Windows' own default terminate
        // CTRL_CLOSE_EVENT/CTRL_LOGOFF_EVENT/CTRL_SHUTDOWN_EVENT only grant a
        // short window (a few seconds, platform-controlled, not something
        // this process can extend) before Windows force-kills it regardless
        // of what this handler returns - unlike CTRL_C_EVENT, graceful
        // shutdown on those paths has a hard, non-negotiable deadline.
      end;
  else
    Result := False;
  end;
end;
{$ENDIF}

procedure InstallShutdownSignalHandler;
begin
  GShutdownRequested := False;
  {$IFDEF UNIX}
  FpSignal(SIGINT, signalhandler(@UnixShutdownSignalHandler));
  FpSignal(SIGTERM, signalhandler(@UnixShutdownSignalHandler));
  // A write() to a pipe/socket whose other end is gone raises SIGPIPE,
  // which defaults to killing the whole process - before any Pascal
  // try/except ever runs, since it's a signal, not a language-level
  // exception. Every "a write can fail, catch it and treat the connection
  // as dead" pattern in this codebase (TVDRX_BridgeExecutive.SendLoop,
  // TVDRX_SocketClientExecutive.SendLoop, and anything that came before
  // them) silently depends on this being masked. Ignoring it here makes a
  // failed write surface as a normal EPIPE/error return instead.
  FpSignal(SIGPIPE, signalhandler(SIG_IGN));
  {$ENDIF}
  {$IFDEF WINDOWS}
  SetConsoleCtrlHandler(@WindowsShutdownCtrlHandler, True);
  {$ENDIF}
end;

end.
