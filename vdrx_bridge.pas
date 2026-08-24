unit vdrx_bridge;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Process, fpjson, jsonparser, vdrx_core, vdrx_procutil;


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
    FRestartPolicy: string; // 'always' (default) | 'on-failure' | 'never'
    FPublishPatterns: string; // comma-joined topic filters, '' = structured
                               // publish disabled entirely (deny by default)
    function IsPublishAllowed(const ATopic: string): Boolean;
    function TryParseStructuredLine(const ALine: string; out ATopic, APayload: string): Boolean;
    procedure StartProcess;
    procedure StopProcess;
    procedure ReaderLoop;
    procedure MonitorLoop;
  public
    constructor Create(ABus: TVDRX_MessageQueue); override;
    destructor Destroy; override;
    property Command: string read FCommand write FCommand;
    // "always"     - restart no matter how the process exited (the original,
    //                only-ever behaviour). Default, so existing callers that
    //                never set this are unaffected.
    // "on-failure" - restart only if it exited with a nonzero code; a clean
    //                (0) exit is treated as done-on-purpose and left stopped.
    // "never"      - one-shot: never restart it, regardless of exit code.
    property RestartPolicy: string read FRestartPolicy write FRestartPolicy;
    // Comma-joined list of topic filters (same wildcard syntax as any bus
    // subscription - see TopicMatches in vdrx_core.pas) this process is
    // allowed to publish on directly. '' (the default) means "not allowed at
    // all" - every stdout line, however it's formatted, publishes as plain
    // text to <id>.out. Set this and a line that parses as
    // {"topic":"...","payload":"..."} publishes on that topic INSTEAD of
    // <id>.out, but only if the topic matches one of these patterns; a line
    // that doesn't parse as JSON, or whose topic isn't covered, still falls
    // back to the plain <id>.out publish (with a log.warn in the "declared
    // but didn't match" case) - so a child that only ever prints plain text
    // is completely unaffected by this property either way.
    property PublishPatterns: string read FPublishPatterns write FPublishPatterns;
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
  FRestartPolicy := 'always';
  FPublishPatterns := '';
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
    try
      FProcess.Execute;
    except
      on E: Exception do
      begin
        FProcess.Free;
        FProcess := nil;
        raise Exception.CreateFmt('bridge "%s": failed to start command "%s" - %s',
          [ID, FCommand, E.Message]);  // debug: doesn't seem to get to if exe file doesn't exist
      end;
    end;
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
function TVDRX_BridgeExecutive.IsPublishAllowed(const ATopic: string): Boolean;
var
  Patterns: TStringList;
  i: Integer;
begin
  Result := False;
  if FPublishPatterns = '' then
    Exit; // deny by default - nothing declared, nothing overrides <id>.out
  Patterns := TStringList.Create;
  try
    Patterns.Delimiter := ',';
    Patterns.StrictDelimiter := True;
    Patterns.DelimitedText := FPublishPatterns;
    for i := 0 to Patterns.Count - 1 do
      if TopicMatches(Trim(Patterns[i]), ATopic) then
        Exit(True);
  finally
    Patterns.Free;
  end;
end;

// A structured line is a JSON object with a string "topic" field; "payload"
// is optional (defaults to ''). Anything else - malformed JSON, a JSON value
// that isn't an object, a missing/non-string "topic" - is treated as plain
// text, exactly like every line was before this existed. This is a parse
// attempt, not a protocol a child MUST speak: a process that just prints
// plain lines is completely unaffected.
function TVDRX_BridgeExecutive.TryParseStructuredLine(const ALine: string; out ATopic, APayload: string): Boolean;
var
  Data: TJSONData;
begin
  Result := False;
  ATopic := '';
  APayload := '';
  if (ALine = '') or (ALine[1] <> '{') then
    Exit; // cheap check before bothering the parser - stdout is plain text
          // the overwhelming majority of the time
  try
    Data := GetJSON(ALine);
  except
    Exit; // not valid JSON - treat as plain text, same as always
  end;
  try
    if (Data.JSONType = jtObject) and (TJSONObject(Data).Find('topic') <> nil)
      and (TJSONObject(Data).Find('topic').JSONType = jtString) then
    begin
      ATopic := TJSONObject(Data).Strings['topic'];
      if (TJSONObject(Data).Find('payload') <> nil) and (TJSONObject(Data).Find('payload').JSONType = jtString) then
        APayload := TJSONObject(Data).Strings['payload'];
      Result := ATopic <> '';
    end;
  finally
    Data.Free;
  end;
end;

procedure TVDRX_BridgeExecutive.ReaderLoop;
var
  Line, Buf, StructTopic, StructPayload: string;
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
          if TryParseStructuredLine(Line, StructTopic, StructPayload) then
          begin
            if IsPublishAllowed(StructTopic) then
              Bus.Publish(StructTopic, StructPayload, ID)
            else
            begin
              Bus.Publish('log.warn', Format(
                'bridge %s: rejected publish to "%s" - not covered by its publish patterns, falling back to %s.out',
                [ID, StructTopic, ID]), ID);
              Bus.Publish(ID + '.out', Line, ID);
            end;
          end
          else
            Bus.Publish(ID + '.out', Line, ID); // plain text - process output re-enters the bus, namespaced by this executive's ID
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
  ProcAssigned, StillRunning, DoRestart: Boolean;
  ExitCode: Integer;
begin
  while not FStopping do
  begin
    Sleep(1000);
    if FStopping then
      Break;
    FProcessLock.Enter;
    ProcAssigned := Assigned(FProcess);
    StillRunning := ProcAssigned and FProcess.Running;
    if ProcAssigned and (not StillRunning) then
      ExitCode := FProcess.ExitStatus // grab this now, inside the lock, while
                                       // FProcess is still assigned - StopProcess
                                       // below nils (and eventually frees) it
    else
      ExitCode := 0;
    FProcessLock.Leave;

    if (not StillRunning) and (not FStopping) then
    begin
      if ProcAssigned then
        // Died on its own - apply the configured policy against how it exited.
        case FRestartPolicy of
          'never':      DoRestart := False;
          'on-failure': DoRestart := (ExitCode <> 0);
        else
          DoRestart := True; // 'always', or an unrecognized value - fail open
        end
      else
        // FProcess was already nil - something else (KillCurrentProcess, i.e.
        // an operator's sys.kill) called StopProcess before we got here. That's
        // an explicit "bounce it" action, not a policy-governed exit, so it
        // always restarts regardless of RestartPolicy.
        DoRestart := True;

      StopProcess;

      if not DoRestart then
      begin
        Bus.Publish('log.info', Format(
          'bridge %s: exited (code %d), restart policy "%s" - leaving it stopped',
          [ID, ExitCode, FRestartPolicy]), ID);
        Exit; // done for good - let this thread terminate now rather than
              // looping indefinitely with nothing left to supervise
      end;

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
  Bus.Publish('log.info', Format('bridge %s: HandlePacket got "%s" (process running: %s)',
    [ID, AMsg.Topic, BoolToStr(Assigned(FProcess) and FProcess.Running, True)]), ID);
  FProcessLock.Enter;
  try
    if Assigned(FProcess) and FProcess.Running then
    begin
      Line := Format('{"topic":%s,"payload":%s,"source":%s}',
        [JSONString(AMsg.Topic), AMsg.Payload, JSONString(AMsg.SourceID)])
        + LineEnding;
      FProcess.Input.Write(Line[1], Length(Line));
    end;
  finally
    FProcessLock.Leave;
  end;
end;

end.