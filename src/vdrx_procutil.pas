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
  TVDRX_RunResult = (rrExited, rrStartFailed, rrTimedOut, rrOutputTooLarge);

var
  // Policy for programs started on behalf of a request (CGI, cli_bridges):
  //  * the child gets a CLEAN environment: the CGI/config variables plus a short list of harmless
  //    ones (PATH, LANG, LC_*, TZ, temp dirs, and what Windows programs need to start). The
  //    daemon's own environment - which may hold tokens, passwords or cloud keys - is NOT handed
  //    to code that web requests can reach. VDRX_ChildEnvInherit = True restores the old
  //    "inherit everything"; VDRX_ChildEnvPassthrough names extra variables to pass on.
  //  * each of stdout and stderr is capped at VDRX_MaxChildOutputBytes (0 = unlimited): a program
  //    that writes without end is killed and answered with rrOutputTooLarge instead of eating memory.
  VDRX_ChildEnvInherit: Boolean = False;
  VDRX_ChildEnvPassthrough: TStringList = nil;
  VDRX_MaxChildOutputBytes: Int64 = 32 * 1024 * 1024;

procedure VDRX_ConfigureChildPolicy(AInheritEnv: Boolean; const APassthrough: array of string;
  AMaxOutputBytes: Int64);

// The environment a request-driven child receives. ADaemonEnv = the daemon's own "NAME=value" lines
// (the real ones come from GetEnvironmentString; tests pass their own), AEnv = lines to add or
// override. Never returns an empty list (an empty list would mean "inherit everything").
procedure BuildChildEnvironment(ADaemonEnv, AEnv: TStrings; AInherit: Boolean;
  APassthrough, ADest: TStrings);

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
//
// AEnv (optional): "NAME=value" lines for the child's environment, added to the
// clean base environment described at VDRX_ChildEnvInherit above (an entry with
// the same name replaces the base one). Used by the CGI executive (vdrx_cgi.pas).
// The request body (AStdin) is written from a helper thread, so a program that
// does not read its stdin cannot stall the timeout.
function RunProgramCaptureArgs(const AExe: string; AArgs: TStrings;
  const AWorkDir, AStdin: string; ATimeoutMs: Integer; out AExitCode: Integer;
  out AStdout, AStderr, AError: string; AEnv: TStrings = nil): TVDRX_RunResult;

// Text helpers shared by anything that carries program/HTTP bytes inside JSON
// (JSON strings must be valid UTF-8; arbitrary bytes are not).
// IsValidUTF8: True if S is well-formed UTF-8 (so it can ride in a JSON string
// as-is). CleanUTF8: S with every invalid byte replaced by '?'. Binary data
// that has to survive intact is carried base64-encoded (\"body_b64\") instead.
function IsValidUTF8(const S: string): Boolean;
function CleanUTF8(const S: string): string;
// Percent-decoding ("%41" -> "A"). APlusIsSpace: True for query strings/forms,
// False for URL paths (where "+" is a literal plus).
function URLDecode(const S: string; APlusIsSpace: Boolean = True): string;

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

const
  // What a request-driven child may inherit from the daemon (besides LC_*): nothing secret, but
  // enough for programs to find their tools and, on Windows, to start at all.
  BASE_ENV_NAMES: array[0..15] of string = ('PATH', 'LANG', 'LANGUAGE', 'LC_ALL', 'TZ', 'TMPDIR',
    'TEMP', 'TMP', 'SYSTEMROOT', 'SYSTEMDRIVE', 'WINDIR', 'COMSPEC', 'PATHEXT', 'OS',
    'NUMBER_OF_PROCESSORS', 'PROCESSOR_ARCHITECTURE');

procedure VDRX_ConfigureChildPolicy(AInheritEnv: Boolean; const APassthrough: array of string;
  AMaxOutputBytes: Int64);
var
  i: Integer;
begin
  VDRX_ChildEnvInherit := AInheritEnv;
  VDRX_MaxChildOutputBytes := AMaxOutputBytes;
  if VDRX_ChildEnvPassthrough = nil then VDRX_ChildEnvPassthrough := TStringList.Create;
  VDRX_ChildEnvPassthrough.Clear;
  for i := Low(APassthrough) to High(APassthrough) do
    if Trim(APassthrough[i]) <> '' then VDRX_ChildEnvPassthrough.Add(Trim(APassthrough[i]));
end;

function EnvLineName(const ALine: string): string;
var
  p: Integer;
begin
  p := Pos('=', ALine);
  if p < 2 then Result := '' else Result := Copy(ALine, 1, p - 1);   // Windows has "=C:=..." lines: no name
end;

procedure BuildChildEnvironment(ADaemonEnv, AEnv: TStrings; AInherit: Boolean;
  APassthrough, ADest: TStrings);
var
  i, j, k: Integer;
  N, U: string;
  Allowed: Boolean;
begin
  ADest.Clear;
  if Assigned(ADaemonEnv) then
    for i := 0 to ADaemonEnv.Count - 1 do
    begin
      N := EnvLineName(ADaemonEnv[i]);
      if N = '' then Continue;
      Allowed := AInherit;
      if not Allowed then
      begin
        U := UpperCase(N);
        if Copy(U, 1, 3) = 'LC_' then Allowed := True;
        for k := Low(BASE_ENV_NAMES) to High(BASE_ENV_NAMES) do
          if U = BASE_ENV_NAMES[k] then Allowed := True;
        if (not Allowed) and Assigned(APassthrough) then
          for k := 0 to APassthrough.Count - 1 do
            if SameText(Trim(APassthrough[k]), N) then Allowed := True;
      end;
      if Allowed then ADest.Add(ADaemonEnv[i]);
    end;
  if Assigned(AEnv) then
    for i := 0 to AEnv.Count - 1 do
    begin
      N := EnvLineName(AEnv[i]);
      if N = '' then Continue;
      for j := ADest.Count - 1 downto 0 do
        if SameText(EnvLineName(ADest[j]), N) then ADest.Delete(j);
      ADest.Add(AEnv[i]);
    end;
  if ADest.Count = 0 then ADest.Add('VDRX_CLEAN_ENV=1');
end;

type
  // Feeds the request body to the child's stdin from its own thread. Writing it inline blocks as
  // soon as the pipe is full (about 64 KB), and a program that is busy and not reading would then
  // hold the worker for as long as it likes - the timeout loop below never even starts.
  TStdinWriter = class(TThread)
  private
    FProc: TProcess;
    FData: string;
  public
    OwnsProc: Boolean;       // set when the caller gave up waiting: the thread frees the process
    constructor Create(AProc: TProcess; const AData: string);
  protected
    procedure Execute; override;
  end;

constructor TStdinWriter.Create(AProc: TProcess; const AData: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FProc := AProc;
  FData := AData;
end;

procedure TStdinWriter.Execute;
var
  P, N, W: Integer;
begin
  P := 1;
  try
    while (P <= Length(FData)) and (not Terminated) do
    begin
      N := Length(FData) - P + 1;
      if N > 8192 then N := 8192;
      W := FProc.Input.Write(FData[P], N);
      if W <= 0 then Break;
      Inc(P, W);
    end;
  except
    // the program closed stdin early - its exit code / stderr will explain
  end;
  try FProc.CloseInput; except end;
  if OwnsProc then FProc.Free;
end;

// Appends N bytes to S (S doubles in size as needed, so collecting megabytes is not quadratic).
procedure AppendBytes(var S: string; var Used, Cap: Integer; const Buf; N: Integer);
begin
  if Used + N > Cap then
  begin
    Cap := (Used + N) * 2;
    if Cap < 65536 then Cap := 65536;
    SetLength(S, Cap);
  end;
  Move(Buf, S[Used + 1], N);
  Inc(Used, N);
end;

function RunProgramCaptureArgs(const AExe: string; AArgs: TStrings;
  const AWorkDir, AStdin: string; ATimeoutMs: Integer; out AExitCode: Integer;
  out AStdout, AStderr, AError: string; AEnv: TStrings = nil): TVDRX_RunResult;
var
  Proc: TProcess;
  Writer: TStdinWriter;
  KeepProc: Boolean;
  DaemonEnv, ChildEnv: TStringList;
  i: Integer;
  Buf: array[0..8191] of Byte;
  N, Got, OutUsed, OutCap, ErrUsed, ErrCap: Integer;
  WasRunning: Boolean;
  Started: QWord;
  Found: string;
begin
  AExitCode := 0;
  AStdout := '';
  AStderr := '';
  AError := '';
  Result := rrExited;
  OutUsed := 0; OutCap := 0; ErrUsed := 0; ErrCap := 0;
  Writer := nil;
  KeepProc := False;
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

    // Always set explicitly: an empty Environment would make the child inherit everything.
    DaemonEnv := TStringList.Create;
    ChildEnv := TStringList.Create;
    try
      for i := 1 to GetEnvironmentVariableCount do
        DaemonEnv.Add(GetEnvironmentString(i));
      BuildChildEnvironment(DaemonEnv, AEnv, VDRX_ChildEnvInherit, VDRX_ChildEnvPassthrough, ChildEnv);
      Proc.Environment.Assign(ChildEnv);
    finally
      ChildEnv.Free;
      DaemonEnv.Free;
    end;

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

    if AStdin <> '' then
    begin
      Writer := TStdinWriter.Create(Proc, AStdin);
      Writer.Start;
    end
    else
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
        AppendBytes(AStdout, OutUsed, OutCap, Buf[0], N);
        Inc(Got, N);
        if (VDRX_MaxChildOutputBytes > 0) and (OutUsed > VDRX_MaxChildOutputBytes) then Break;
      end;
      while Proc.Stderr.NumBytesAvailable > 0 do
      begin
        N := Proc.Stderr.Read(Buf[0], SizeOf(Buf));
        if N <= 0 then Break;
        AppendBytes(AStderr, ErrUsed, ErrCap, Buf[0], N);
        Inc(Got, N);
        if (VDRX_MaxChildOutputBytes > 0) and (ErrUsed > VDRX_MaxChildOutputBytes) then Break;
      end;
      if (VDRX_MaxChildOutputBytes > 0) and
         ((OutUsed > VDRX_MaxChildOutputBytes) or (ErrUsed > VDRX_MaxChildOutputBytes)) then
      begin
        ForceKillProcess(Proc);
        AStdout := '';
        AStderr := '';
        Result := rrOutputTooLarge;
        Exit;
      end;
      // Checked on EVERY pass: a program that never stops writing must not be able to starve it.
      if WasRunning and (ATimeoutMs > 0) and (GetTickCount64 - Started > QWord(ATimeoutMs)) then
      begin
        ForceKillProcess(Proc);
        Result := rrTimedOut;
        Exit;
      end;
      if (Got = 0) and WasRunning then Sleep(2);
    until (not WasRunning) and (Got = 0);

    AExitCode := Proc.ExitStatus;
    {$IFDEF UNIX}
    // FPC 3.2 returns the raw wait() status (exit code 1 arrives as 256);
    // newer versions return the plain code. Handle both.
    if (AExitCode >= 256) and ((AExitCode and $FF) = 0) then AExitCode := AExitCode shr 8;
    {$ENDIF}
  finally
    SetLength(AStdout, OutUsed);
    SetLength(AStderr, ErrUsed);
    if Assigned(Writer) then
    begin
      // The child is gone (or killed), so a blocked write fails and the thread ends at once.
      Writer.Terminate;
      if WaitThreadOrTimeout(Writer, 2000) then
        Writer.Free
      else
      begin
        // Something else still holds the pipe open (a grandchild). Do not free what the thread
        // is using: it frees the process itself when its write finally returns.
        Writer.OwnsProc := True;
        Writer.FreeOnTerminate := True;
        KeepProc := True;
      end;
    end;
    if not KeepProc then Proc.Free;
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

// Length of the well-formed UTF-8 sequence starting at S[I], or 0 if invalid.
function UTF8SeqLen(const S: string; I: Integer): Integer;
var
  c: Byte;
  need, j: Integer;
begin
  Result := 0;
  c := Byte(S[I]);
  if c < $80 then Exit(1);
  if (c >= $C2) and (c <= $DF) then need := 1
  else if (c >= $E0) and (c <= $EF) then need := 2
  else if (c >= $F0) and (c <= $F4) then need := 3
  else Exit(0);
  if I + need > Length(S) then Exit(0);
  for j := 1 to need do
    if (Byte(S[I + j]) and $C0) <> $80 then Exit(0);
  Result := need + 1;
end;

// A NUL byte is well-formed UTF-8 but cannot ride in a JSON string intact (the string handling
// downstream treats it as a terminator: a body of NULs arrived as 0 bytes, and a long run of
// them never got an answer at all), so it counts as "not text" and the caller base64-encodes.
function IsValidUTF8(const S: string): Boolean;
var
  i, n: Integer;
begin
  Result := True;
  i := 1;
  while i <= Length(S) do
  begin
    if S[i] = #0 then Exit(False);
    n := UTF8SeqLen(S, i);
    if n = 0 then Exit(False);
    Inc(i, n);
  end;
end;

function CleanUTF8(const S: string): string;
var
  i, n: Integer;
begin
  if IsValidUTF8(S) then Exit(S);
  Result := '';
  i := 1;
  while i <= Length(S) do
  begin
    if S[i] = #0 then n := 0 else n := UTF8SeqLen(S, i);
    if n = 0 then
    begin
      Result := Result + '?';
      Inc(i);
    end
    else
    begin
      Result := Result + Copy(S, i, n);
      Inc(i, n);
    end;
  end;
end;

function HexVal(C: Char): Integer;
begin
  case C of
    '0'..'9': Result := Ord(C) - 48;
    'a'..'f': Result := Ord(C) - 87;
    'A'..'F': Result := Ord(C) - 55;
  else
    Result := -1;
  end;
end;

function URLDecode(const S: string; APlusIsSpace: Boolean = True): string;
var
  i, H, L: Integer;
begin
  Result := '';
  i := 1;
  while i <= Length(S) do
  begin
    if (S[i] = '%') and (i + 2 <= Length(S)) then
    begin
      H := HexVal(S[i + 1]);
      L := HexVal(S[i + 2]);
      if (H >= 0) and (L >= 0) then
      begin
        Result := Result + Chr(H * 16 + L);
        Inc(i, 3);
        Continue;
      end;
    end;
    if APlusIsSpace and (S[i] = '+') then Result := Result + ' ' else Result := Result + S[i];
    Inc(i);
  end;
end;

// "a=1&b=two%20words" -> params (later duplicates win)
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
