unit vdrx_bridge;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Process, fpjson, jsonparser, DateUtils, vdrx_core, vdrx_procutil;


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

    // Outbound lines to the child's stdin are queued here and written by
    // FSendThread (see SendLoop), never directly from HandlePacket. A pipe
    // has no OS-level send timeout the way a socket does, so a wedged child
    // (alive, not crashed, just not reading its stdin) can't be caught by a
    // bounded Write the way TVDRX_SocketClientExecutive now is - instead
    // MonitorLoop watches how long the oldest queued line has been waiting
    // (FOldestPendingAt/FOldestPendingSet) and treats "still pending after
    // FSendStallMs" as a hang, same class of symptom as a crashed process.
    FSendLock: TCriticalSection;
    FSendEvent: TEvent;
    FSendQueue: TStringList;
    FSendThread: TThread;
    FOldestPendingAt: TDateTime;
    FOldestPendingSet: Boolean;
    FSendStallMs: Integer;

    function IsPublishAllowed(const ATopic: string): Boolean;
    function TryParseStructuredLine(const ALine: string; out ATopic, APayload: string): Boolean;
    procedure StartProcess;
    procedure StopProcess;
    procedure ReaderLoop;
    procedure MonitorLoop;
    procedure SendLoop;
    procedure EnqueueLine(const ALine: string);
    function SendQueueStalled: Boolean;
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
    // How long a line may sit at the front of the outbound queue,
    // unconsumed by the child, before MonitorLoop treats the process as
    // hung and force-restarts it via KillCurrentProcess. Defaults to
    // 5000ms; set from vdrx.conf's per-process "send_stall_ms" if a
    // particular child is expected to go quiet longer than that.
    property SendStallMs: Integer read FSendStallMs write FSendStallMs;
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
  FSendLock := TCriticalSection.Create;
  FSendEvent := TEvent.Create(nil, False, False, '');
  FSendQueue := TStringList.Create;
  FOldestPendingSet := False;
  FRestartDelayMs := 500;
  FMaxRestartDelayMs := 30000;
  FGracefulTimeoutMs := 5000;
  FSendStallMs := 5000;
  FStopping := False;
  FRestartPolicy := 'always';
  FPublishPatterns := '';
end;

destructor TVDRX_BridgeExecutive.Destroy;
begin
  FSendQueue.Free;
  FSendEvent.Free;
  FSendLock.Free;
  FProcessLock.Free;
  inherited Destroy;
end;

procedure TVDRX_BridgeExecutive.StartProcess;
var
  Parts: TStringList;
  i: Integer;
begin
  Parts := TStringList.Create;
  try
    CommandToList(FCommand, Parts);
    if Parts.Count = 0 then
      raise Exception.CreateFmt('bridge "%s": empty command', [ID]);
    FProcessLock.Enter;
    try
      FProcess := TProcess.Create(nil);
      FProcess.Executable := Parts[0];
      for i := 1 to Parts.Count - 1 do
        FProcess.Parameters.Add(Parts[i]);
      FProcess.Options := [poUsePipes, poStderrToOutPut];
      try
        FProcess.Execute;
      except
        on E: Exception do
        begin
          FProcess.Free;
          FProcess := nil;
          raise Exception.CreateFmt('bridge "%s": failed to start command "%s" - %s',
            [ID, FCommand, E.Message]);
        end;
      end;
    finally
      FProcessLock.Leave;
    end;
  finally
    Parts.Free;
  end;
  FReaderThread := TVDRX_WorkerThread.Create(@ReaderLoop);
  FReaderThread.FreeOnTerminate := False;
  FReaderThread.Start;
  FSendThread := TVDRX_WorkerThread.Create(@SendLoop);
  FSendThread.FreeOnTerminate := False;
  FSendThread.Start;
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
  ReaderThread, SendThread: TThread;
  ReaderOK, SendOK: Boolean;
begin
  FProcessLock.Enter;
  try
    Proc := FProcess;
    FProcess := nil; // detach immediately - a concurrent StopProcess call (e.g.
                      // MonitorLoop racing an admin sys.kill by PID) then sees
                      // nil and exits below without double-freeing anything
    ReaderThread := FReaderThread;
    FReaderThread := nil;
    SendThread := FSendThread;
    FSendThread := nil;
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

  // Both the reader thread's blocking Read and the send thread's blocking
  // Write should unblock once the process (and its pipes) are actually
  // gone. Give each one the same short window before deciding it's
  // genuinely stuck. Proc is only freed once BOTH have confirmed exit -
  // either one could still be touching Proc.Output/Proc.Input otherwise.
  ReaderOK := WaitThreadOrTimeout(ReaderThread, FGracefulTimeoutMs);
  SendOK := WaitThreadOrTimeout(SendThread, FGracefulTimeoutMs);

  if ReaderOK then
  begin
    if Assigned(ReaderThread) then ReaderThread.Free;
  end
  else
    Bus.Publish('log.warn', Format('bridge %s: reader thread did not exit - abandoning it to avoid a crash', [ID]), ID);

  if SendOK then
  begin
    if Assigned(SendThread) then SendThread.Free;
  end
  else
    Bus.Publish('log.warn', Format('bridge %s: send thread did not exit - abandoning it to avoid a crash', [ID]), ID);

  if ReaderOK and SendOK then
    Proc.Free;
  // else: leaks this one Proc instance rather than risk freeing it while a
  // still-live, abandoned thread might touch it - same trade-off the
  // reader-thread-only version of this code made, just extended to cover
  // the send thread too.

  // Anything still queued was addressed to the process that just died - a
  // restart is a new child, not a continuation, so drop it rather than
  // replaying stale traffic into whatever comes back.
  FSendLock.Enter;
  try
    FSendQueue.Clear;
    FOldestPendingSet := False;
  finally
    FSendLock.Leave;
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
const
  BufSize = 4096;
var
  Buf: array[0..BufSize - 1] of Byte;
  Received, p, SegStart: Integer;
  Line, LineBuf, StructTopic, StructPayload, ChunkStr, Segment: string;
  Proc: TProcess;
begin
  FillChar(Buf, SizeOf(Buf), 0);
  LineBuf := '';
  FProcessLock.Enter;
  Proc := FProcess;
  FProcessLock.Leave;
  // Reads in BufSize-byte chunks instead of one byte (one syscall) at a
  // time - under high-volume output (log-heavy or JSON-streaming child
  // processes) the old per-character Read was a real CPU cost. The loop no
  // longer keys off Proc.Running either: that let it exit the instant a
  // short-lived process finished, even if there was still unread output
  // sitting in the OS pipe buffer, silently dropping it. Now it keeps
  // reading - and processing whatever comes back - until a Read genuinely
  // comes back empty AND the process has exited, so buffered trailing
  // output is drained before the loop stops.
  while (not FStopping) and Assigned(Proc) do
  begin
    Received := Proc.Output.Read(Buf, SizeOf(Buf));
    if Received > 0 then
    begin
      // Scan the whole chunk for line breaks and append one segment per
      // line (minus any bare CRs) instead of growing LineBuf one character
      // at a time: under FPC's copy-on-write strings, per-character
      // concatenation makes assembling a single long line (a verbose tool's
      // one-line output, a stack trace) an O(n^2) cost in that line's
      // length. This is O(n) per chunk regardless of how few lines it
      // contains.
      SetString(ChunkStr, PAnsiChar(@Buf[0]), Received);
      SegStart := 1;
      for p := 1 to Length(ChunkStr) do
      begin
        if ChunkStr[p] = #10 then
        begin
          Segment := Copy(ChunkStr, SegStart, p - SegStart);
          if Pos(#13, Segment) > 0 then
            Segment := StringReplace(Segment, #13, '', [rfReplaceAll]);
          LineBuf := LineBuf + Segment;
          SegStart := p + 1;

          Line := Trim(LineBuf);
          LineBuf := '';
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
        end;
      end;
      if SegStart <= Length(ChunkStr) then
      begin
        Segment := Copy(ChunkStr, SegStart, Length(ChunkStr) - SegStart + 1);
        if Pos(#13, Segment) > 0 then
          Segment := StringReplace(Segment, #13, '', [rfReplaceAll]);
        LineBuf := LineBuf + Segment;
      end;
    end
    else if not Proc.Running then
      Break // no data waiting and the process is gone - genuinely done, not just quiet
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

    // Alive per the OS, but stdin hasn't drained in a while - a hang, not a
    // crash, so RestartPolicy (which governs how a process CHOSE to exit)
    // doesn't apply here; always bounce it, same as an operator's sys.kill.
    if StillRunning and (not FStopping) and SendQueueStalled then
    begin
      Bus.Publish('log.warn', Format(
        'bridge %s: outbound queue to stdin has been stuck for over %dms - process looks hung, restarting it',
        [ID, FSendStallMs]), ID);
      KillCurrentProcess; // -> StopProcess: graceful-then-kill, clears FProcess and the stale queue
      StillRunning := False;
      ProcAssigned := False; // route through the "always restart, not policy-governed" branch below
    end;

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

// True once the oldest still-unsent line has been waiting longer than
// FSendStallMs. FOldestPendingAt/FOldestPendingSet are maintained by
// EnqueueLine (set on the empty->non-empty transition) and SendLoop
// (cleared once the queue drains back to empty) under FSendLock.
function TVDRX_BridgeExecutive.SendQueueStalled: Boolean;
begin
  FSendLock.Enter;
  try
    Result := FOldestPendingSet and
      (MilliSecondsBetween(Now, FOldestPendingAt) > FSendStallMs);
  finally
    FSendLock.Leave;
  end;
end;

procedure TVDRX_BridgeExecutive.EnqueueLine(const ALine: string);
begin
  if FStopping then Exit;
  FSendLock.Enter;
  try
    if FStopping then Exit;
    if FSendQueue.Count = 0 then
    begin
      FOldestPendingAt := Now;
      FOldestPendingSet := True;
    end;
    FSendQueue.Add(ALine);
  finally
    FSendLock.Leave;
  end;
  FSendEvent.SetEvent;
end;

// Drains FSendQueue and performs the actual (blocking) FProcess.Input.Write
// here, off the dispatch thread - HandlePacket only ever calls EnqueueLine.
// A pipe write can still block this thread if the child truly never reads,
// but that no longer touches TVDRX_Kernel.Execute; MonitorLoop's
// SendQueueStalled check is what catches and restarts a child stuck this way.
// Bound to one process instance for its whole life, exactly like ReaderLoop
// - a fresh SendThread/SendLoop is created per StartProcess call and exits
// once THIS Proc stops running. Deliberately does NOT take FProcessLock
// around the write: StopProcess needs that lock only briefly to swap
// FProcess to nil and hand off to ForceKillProcess/SIGKILL, and must never
// be made to wait behind a write that's stuck because the child isn't
// reading its stdin - that would turn "kill the hung child" into itself
// hanging on the very lock guarding the field. Instead, StopProcess kills
// Proc directly (it has its own captured reference) while this thread may
// still be blocked inside Proc.Input.Write; that write is expected to
// unblock (with a broken-pipe error) once the kill actually lands, same as
// ReaderLoop's blocking Read is expected to unblock on EOF - see StopProcess's
// comment. MonitorLoop's SendQueueStalled check is what notices the hang and
// triggers that kill in the first place.
procedure TVDRX_BridgeExecutive.SendLoop;
var
  Line: string;
  HaveLine: Boolean;
  Proc: TProcess;
begin
  FProcessLock.Enter;
  Proc := FProcess;
  FProcessLock.Leave;

  while (not FStopping) and Assigned(Proc) and Proc.Running do
  begin
    if FSendEvent.WaitFor(200) <> wrSignaled then
      Continue;

    while (not FStopping) and Proc.Running do
    begin
      HaveLine := False;
      FSendLock.Enter;
      try
        if FSendQueue.Count > 0 then
        begin
          Line := FSendQueue[0];
          FSendQueue.Delete(0);
          HaveLine := True;
          if FSendQueue.Count = 0 then
            FOldestPendingSet := False
          else
            FOldestPendingAt := Now; // next line becomes "oldest" as of now
        end;
      finally
        FSendLock.Leave;
      end;
      if not HaveLine then Break;

      try
        Proc.Input.Write(Line[1], Length(Line));
      except
        // Broken pipe - the process is already gone or going.
        // MonitorLoop's Running check catches it within ~1s; nothing more
        // to do here except stop trying to write to it.
        Break;
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
  FSendThread := TVDRX_WorkerThread.Create(@SendLoop);
  FSendThread.FreeOnTerminate := False;
  FSendThread.Start;
end;

procedure TVDRX_BridgeExecutive.Shutdown;
begin
  FStopping := True;
  FSendEvent.SetEvent; // wake SendLoop so it notices FStopping promptly
  StopProcess; // tears down the process, reader thread, AND send thread together
  if Assigned(FMonitorThread) then
  begin
    if WaitThreadOrTimeout(FMonitorThread, FGracefulTimeoutMs) then
      FMonitorThread.Free
    else
      Bus.Publish('log.warn', 'bridge ' + ID + ': monitor thread did not exit in time - abandoning it', ID);
    FMonitorThread := nil;
  end;
end;

// Payload is supposed to already be a JSON-encoded value by the time it
// reaches here (see TVDRX_Message.Payload's producers - the WS RPC layer,
// admin commands, etc.), but not everything that publishes onto the bus
// (e.g. a plain-text CLI/bridge payload, or a raw line from
// TVDRX_SocketClientExecutive's "<id>.out") guarantees that. Splicing an
// unquoted, non-JSON payload straight into the "payload":%s slot below used
// to produce invalid JSON on the wire (e.g. {"topic":"x","payload":hello
// world,"source":"y"}), which every downstream JSON parser would choke on.
// Try to parse it as JSON first; only if that fails do we know it's raw
// text, and wrap it as a JSON string so the line is always valid JSON.
//
// GetJSON does NOT reliably raise an exception on invalid input - for a
// large class of malformed strings (notably anything starting with a raw
// ':', which covers most IRC protocol lines) it just returns nil with no
// exception at all. The previous version of this function only checked for
// an exception, so a nil result was wrongly treated as "successfully
// parsed, already valid JSON" and the raw unescaped text was spliced
// straight through - corrupting the wire format for exactly this kind of
// payload. Found via TVDRX_SocketClientExecutive's IRC traffic - a
// pre-existing bug in this function, just never exercised by a
// high-volume, non-JSON, colon-leading input before now. Checking
// Assigned(Parsed) explicitly (not just "no exception") fixes both this
// and the empty-string case (GetJSON('') also returns nil, silently).
function EnsureJSONPayload(const APayload: string): string;
var
  Parsed: TJSONData;
begin
  Parsed := nil;
  try
    Parsed := GetJSON(APayload);
  except
    Parsed := nil; // treat a parse exception the same as a nil result - see comment above
  end;
  if Assigned(Parsed) then
  begin
    Result := APayload; // genuinely parsed as valid JSON - pass through unchanged
    Parsed.Free;
  end
  else
    Result := JSONString(APayload); // not JSON at all - treat as raw text and quote/escape it
end;

procedure TVDRX_BridgeExecutive.HandlePacket(const AMsg: TVDRX_Message);
var
  Line: string;
begin
  Line := Format('{"topic":%s,"payload":%s,"source":%s}',
    [JSONString(AMsg.Topic), EnsureJSONPayload(AMsg.Payload), JSONString(AMsg.SourceID)])
    + LineEnding;
  EnqueueLine(Line); // SendLoop does the actual (potentially blocking) write - see its comment
end;

end.
