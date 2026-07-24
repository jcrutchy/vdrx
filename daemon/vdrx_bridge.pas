unit vdrx_bridge;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Process, fpjson, vdrx_core, vdrx_procutil;

type

  // External-process manager. One instance per external process. Descends from
  // TVDRX_Executive directly - not a special base class, just an executive that does
  // more work in its lifecycle hooks than most. Registry manages it exactly like any
  // other executive (register/unregister/Initialize/Shutdown), with no special-casing.
  TVDRX_BridgeExecutive = class(TVDRX_Executive)
  private
    FCommand: string;
    FProcess: TProcess;
    FProcessLock: TCriticalSection; // guards FProcess against Handle/restart races
    FReaderThread: TThread;
    FMonitorThread: TThread;
    FRestartDelayMs: Integer;
    FMaxRestartDelayMs: Integer;
    FGracefulTimeoutMs: Integer; // how long StopProcess waits for a clean exit
                                  // before escalating to a forced kill
    FStopping: Boolean;
    FIRCChannel: string;  // '' = disabled (default) - relay-out target channel, e.g. '#general'
    FIRCFromName: string; // display nick/user for relayed lines
    procedure StartProcess;
    procedure StopProcess;
    procedure ReaderLoop;
    procedure MonitorLoop;
  public
    constructor Create(ABus: TVDRX_MessageQueue); override;
    destructor Destroy; override;
    property Command: string read FCommand write FCommand;
    // Optional: set both to have every line the child process prints also show up
    // as a PRIVMSG in this IRC channel (in addition to the existing <ID>.out bus
    // publish, which still happens either way). Leave IRCChannel '' to disable -
    // that's the default, so existing non-IRC uses of Bridge are unaffected.
    property IRCChannel: string read FIRCChannel write FIRCChannel;
    property IRCFromName: string read FIRCFromName write FIRCFromName;
    // How long to wait for the child to exit cleanly (after CloseInput + SIGTERM
    // on Unix) before force-killing it. Defaults to 5000ms; set from
    // vdrx_daemon.conf's top-level "shutdown_grace_ms" in vdrx_daemon.lpr.
    property GracefulTimeoutMs: Integer read FGracefulTimeoutMs write FGracefulTimeoutMs;
    // Current child PID, or 0 if no process is currently running - used by
    // vdrx_admin.pas's 'sys.kill' to find "which bridge owns this PID".
    function CurrentPID: Integer;
    // Force a graceful-then-kill of just the current child process. The Bridge
    // executive itself is untouched, so MonitorLoop notices within ~1s and
    // restarts it (normal crash-recovery path) - this is a "restart this one
    // stuck process" operation, not a "remove this Bridge" operation (use
    // sys.kill with this executive's ID, or sys.killall, for that instead).
    procedure KillCurrentProcess;
    procedure Initialize; override;
    procedure Shutdown; override;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
  end;

implementation

{ TVDRX_BridgeExecutive }

constructor TVDRX_BridgeExecutive.Create(ABus: TVDRX_MessageQueue);
begin
  inherited Create(ABus);
  FProcessLock := TCriticalSection.Create;
  FRestartDelayMs := 500;
  FMaxRestartDelayMs := 30000;
  FGracefulTimeoutMs := 5000;
  FStopping := False;
  FIRCFromName := 'bridge';
end;

destructor TVDRX_BridgeExecutive.Destroy;
begin
  FProcessLock.Free;
  inherited Destroy;
end;

procedure TVDRX_BridgeExecutive.StartProcess;
begin
  FProcessLock.Enter;
  try
    FProcess := TProcess.Create(nil);
    FProcess.CommandLine := FCommand;
    FProcess.Options := [poUsePipes, poStderrToOutPut];
    FProcess.Execute;
  finally
    FProcessLock.Leave;
  end;
  FReaderThread := TVDRX_WorkerThread.Create(@ReaderLoop);
  FReaderThread.FreeOnTerminate := False;
  FReaderThread.Start;
end;

// Graceful-then-kill: closes stdin (an EOF hint some children, especially on
// Windows, exit on by themselves), sends SIGTERM on Unix, waits up to
// FGracefulTimeoutMs for the process to actually exit, and only then
// force-kills it (SIGKILL on Unix, 'taskkill /T /F' on Windows - see
// vdrx_procutil.pas). The reader thread is given the same grace window to
// notice EOF and exit on its own before being abandoned (never freed while
// possibly still touching a live handle - see comment below).
procedure TVDRX_BridgeExecutive.StopProcess;
var
  Proc: TProcess;
  ReaderThread: TThread;
begin
  FProcessLock.Enter;
  try
    Proc := FProcess;
    FProcess := nil; // detach immediately - a concurrent StopProcess call (e.g.
                      // MonitorLoop racing an admin sys.kill by PID) then sees
                      // nil and exits below without double-freeing anything
    ReaderThread := FReaderThread;
    FReaderThread := nil;
  finally
    FProcessLock.Leave;
  end;

  if not Assigned(Proc) then Exit;

  try
    if Proc.Running then
    begin
      try Proc.CloseInput; except end; // EOF hint - see unit comment
      TryGracefulTerminate(Proc);      // SIGTERM on Unix; no-op on Windows
      if not WaitProcessOrTimeout(Proc, FGracefulTimeoutMs) then
      begin
        Bus.Publish('log.warn', Format('bridge %s: process pid %d did not exit within %dms, force-killing',
          [ID, Proc.ProcessID, FGracefulTimeoutMs]), ID);
        ForceKillProcess(Proc);
      end;
    end;
  except
  end;

  // The reader thread's blocking Read should unblock once the process (and
  // its pipes) are actually gone. Give it one more short window before
  // deciding it's genuinely stuck.
  if WaitThreadOrTimeout(ReaderThread, FGracefulTimeoutMs) then
  begin
    if Assigned(ReaderThread) then ReaderThread.Free;
    Proc.Free;
  end
  else
  begin
    // Truly stuck (shouldn't happen once the process is confirmed dead) -
    // abandon both rather than risk freeing objects a live thread might
    // still be touching. Leaks this one instance; logged loudly so it's
    // visible rather than silently swallowed.
    Bus.Publish('log.warn', Format('bridge %s: reader thread did not exit - abandoning it to avoid a crash', [ID]), ID);
  end;
end;

// Blocking char-by-char read, buffered until newline. Deliberately not using
// NumBytesAvailable - not reliably present across FPC versions; a plain blocking
// Read is simpler and fully portable.
procedure TVDRX_BridgeExecutive.ReaderLoop;
var
  Line, Buf: string;
  Ch: Char;
  Proc: TProcess;
begin
  Buf := '';
  FProcessLock.Enter;
  Proc := FProcess;
  FProcessLock.Leave;
  while (not FStopping) and Assigned(Proc) and Proc.Running do
  begin
    if Proc.Output.Read(Ch, 1) = 1 then
    begin
      if Ch = #10 then
      begin
        Line := Trim(Buf);
        Buf := '';
        if Line <> '' then
        begin
          Bus.Publish(ID + '.out', Line, ID); // process output re-enters the bus, namespaced by this executive's ID
          if FIRCChannel <> '' then
            // Same 'irc.<channel>.event' shape TVDRX_IRCConnection.HandlePacket already
            // understands - this is what closes the "!run ..." -> reply-in-channel loop.
            Bus.Publish('irc.' + FIRCChannel + '.event',
              Format('{"kind":"privmsg","from":%s,"user":%s,"text":%s}',
                [StringToJSONString(FIRCFromName), StringToJSONString(FIRCFromName), StringToJSONString(Line)]),
              ID);
        end;
      end
      else if Ch <> #13 then
        Buf := Buf + Ch;
    end
    else
      Sleep(20);
  end;
end;

procedure TVDRX_BridgeExecutive.MonitorLoop;
var
  NeedsRestart: Boolean;
begin
  while not FStopping do
  begin
    Sleep(1000);
    if FStopping then
      Break;
    FProcessLock.Enter;
    NeedsRestart := (not Assigned(FProcess)) or (not FProcess.Running);
    FProcessLock.Leave;
    if NeedsRestart and (not FStopping) then
    begin
      StopProcess;
      Sleep(FRestartDelayMs);
      if FRestartDelayMs < FMaxRestartDelayMs then
        FRestartDelayMs := FRestartDelayMs * 2; // exponential backoff on a crash loop
      if not FStopping then
      begin
        StartProcess;
        FRestartDelayMs := 500; // reset after a clean (re)start
      end;
    end;
  end;
end;

function TVDRX_BridgeExecutive.CurrentPID: Integer;
begin
  FProcessLock.Enter;
  try
    if Assigned(FProcess) and FProcess.Running then
      Result := FProcess.ProcessID
    else
      Result := 0;
  finally
    FProcessLock.Leave;
  end;
end;

procedure TVDRX_BridgeExecutive.KillCurrentProcess;
begin
  StopProcess; // MonitorLoop notices FProcess is gone within ~1s and restarts it
end;

procedure TVDRX_BridgeExecutive.Initialize;
begin
  FStopping := False;
  StartProcess;
  FMonitorThread := TVDRX_WorkerThread.Create(@MonitorLoop);
  FMonitorThread.FreeOnTerminate := False;
  FMonitorThread.Start;
end;

procedure TVDRX_BridgeExecutive.Shutdown;
begin
  FStopping := True;
  StopProcess;
  if Assigned(FMonitorThread) then
  begin
    if WaitThreadOrTimeout(FMonitorThread, FGracefulTimeoutMs) then
      FMonitorThread.Free
    else
      Bus.Publish('log.warn', 'bridge ' + ID + ': monitor thread did not exit in time - abandoning it', ID);
    FMonitorThread := nil;
  end;
end;

procedure TVDRX_BridgeExecutive.HandlePacket(const AMsg: TVDRX_Message);
var
  Line: string;
begin
  FProcessLock.Enter;
  try
    if Assigned(FProcess) and FProcess.Running then
    begin
      Line := Format('{"topic":%s,"payload":%s,"source":%s}',
        [StringToJSONString(AMsg.Topic), AMsg.Payload, StringToJSONString(AMsg.SourceID)])
        + LineEnding;
      FProcess.Input.Write(Line[1], Length(Line));
    end;
  finally
    FProcessLock.Leave;
  end;
end;

end.