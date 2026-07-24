unit vdrx_bridge;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Process, fpjson, vdrx_core;

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

procedure TVDRX_BridgeExecutive.StopProcess;
begin
  FProcessLock.Enter;
  try
    if Assigned(FProcess) then
    begin
      try
        if FProcess.Running then
          FProcess.Terminate(0); // unblocks the reader thread's blocking read via EOF
      except
      end;
      FProcess.Free;
      FProcess := nil;
    end;
  finally
    FProcessLock.Leave;
  end;
  if Assigned(FReaderThread) then
  begin
    FReaderThread.WaitFor;
    FReaderThread.Free;
    FReaderThread := nil;
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
    FMonitorThread.WaitFor;
    FMonitorThread.Free;
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
