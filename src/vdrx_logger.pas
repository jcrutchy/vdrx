unit vdrx_logger;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, vdrx_core, vdrx_redact;

// ANSI Color Constants
const
  CLR_RESET  = #27'[0m';
  CLR_INFO   = #27'[32m'; // Green
  CLR_WARN   = #27'[33m'; // Yellow
  CLR_ERROR  = #27'[31m'; // Red

type
  TLogLevel = (lvlINFO, lvlWARN, lvlERROR);

  // Logs every message on the bus ('>' subscription) to the console and to a
  // file. HandlePacket only FORMATS the line and queues it: all disk and
  // console I/O (including the fsync after each batch) happens on the
  // logger's own writer thread, so a slow disk or a big burst of traffic can
  // never stall the bus's single dispatch thread (see the "must not block"
  // contract on TVDRX_Executive.HandlePacket). Payloads longer than
  // MaxPayload are cut with a "...[N bytes total, truncated]" marker, so a
  // multi-megabyte message (an HTTP body published to a runner, say) costs
  // one short log line rather than megabytes of console and disk traffic.
  TVDRX_LoggerExecutive = class(TVDRX_Executive)
  private
    FFileStream: TFileStream;
    FThreshold: TLogLevel;
    FMaxPayload: Integer;
    FRedactor: TVDRX_Redactor;     // nil = redaction off
    FRedactLock: TCriticalSection;
    FLock: TCriticalSection;
    FSignal: TEvent;
    FFileLines: string;     // pending, guarded by FLock
    FConsoleLines: string;  // pending, guarded by FLock
    FWriter: TThread;
    FStopping: Boolean;     // guarded by FLock
    FConsoleExclude: TStringList; // topic filters kept off the console (set before the kernel starts)
    FFileExclude: TStringList;    // topic filters kept out of the log file
    function IsExcluded(AList: TStringList; const ATopic: string): Boolean;
    function LevelOf(const ATopic: string): TLogLevel;
    function LevelName(ALevel: TLogLevel): string;
    function LevelColor(ALevel: TLogLevel): string;
    function ClipPayload(const APayload: string): string;
    procedure FlushPending;
    procedure WriterLoop;
  public
    constructor Create(ABus: TVDRX_MessageQueue; const APath: string;
      ALevel: TLogLevel; AMaxPayload: Integer = 4096); reintroduce;
    destructor Destroy; override;
    procedure Shutdown; override;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    // Topic filters ('*' / '>' wildcards, same as a subscription) whose messages
    // are NOT printed to the console / NOT written to the log file. Everything
    // else is logged as before. Call before the kernel starts. Typical use: a
    // chatty family of topics that has a better home elsewhere (job output goes
    // to the job console and a rotating bucket - see docs/jobs.md).
    // Credential masking (see vdrx_redact.pas). ON by default, bodies included:
    // an HTTP request envelope otherwise puts cookies, Authorization headers,
    // POSTed passwords and the WebSocket login token into the log file and
    // onto the console. Call before the kernel starts.
    procedure ConfigureRedaction(AEnabled, ARedactBodies: Boolean);
    procedure ExcludeFromConsole(const AFilter: string);
    procedure ExcludeFromFile(const AFilter: string);
  end;

// Writes S to the console and flushes it, holding a process-wide lock. Every
// background thread that prints (the logger, the job console) goes through
// this: two threads writing to the same text file unsynchronised splice their
// lines into each other mid-line.
procedure ConsoleWrite(const S: string);

implementation

var
  GConsoleLock: TCriticalSection;

procedure ConsoleWrite(const S: string);
begin
  if S = '' then Exit;
  GConsoleLock.Enter;
  try
    Write(S);
    Flush(Output);
  finally
    GConsoleLock.Leave;
  end;
end;

constructor TVDRX_LoggerExecutive.Create(ABus: TVDRX_MessageQueue;
  const APath: string; ALevel: TLogLevel; AMaxPayload: Integer);
begin
  inherited Create(ABus);
  FThreshold := ALevel;
  FMaxPayload := AMaxPayload;
  FRedactLock := TCriticalSection.Create;
  FRedactor := TVDRX_Redactor.Create(True);
  FLock := TCriticalSection.Create;
  FSignal := TEvent.Create(nil, False, False, '');
  FConsoleExclude := TStringList.Create;
  FFileExclude := TStringList.Create;
  // Append if the log already exists, otherwise create fresh - fmCreate always
  // truncates, so it's only used the first time.
  if FileExists(APath) then
    FFileStream := TFileStream.Create(APath, fmOpenReadWrite or fmShareDenyWrite)
  else
    FFileStream := TFileStream.Create(APath, fmCreate or fmShareDenyWrite);
  FFileStream.Seek(0, soEnd);
  FWriter := TVDRX_WorkerThread.Create(@WriterLoop);
  FWriter.Start;
end;

destructor TVDRX_LoggerExecutive.Destroy;
begin
  Shutdown;
  FWriter.Free;
  FFileStream.Free;
  FFileExclude.Free;
  FConsoleExclude.Free;
  FSignal.Free;
  FLock.Free;
  FRedactor.Free;
  FRedactLock.Free;
  inherited;
end;

procedure TVDRX_LoggerExecutive.ConfigureRedaction(AEnabled, ARedactBodies: Boolean);
begin
  FRedactLock.Acquire;
  try
    if AEnabled then
    begin
      if FRedactor = nil then FRedactor := TVDRX_Redactor.Create(ARedactBodies);
      FRedactor.RedactBodies := ARedactBodies;
    end
    else
      FreeAndNil(FRedactor);
  finally
    FRedactLock.Release;
  end;
end;

procedure TVDRX_LoggerExecutive.ExcludeFromConsole(const AFilter: string);
begin
  if (AFilter <> '') and (FConsoleExclude.IndexOf(AFilter) < 0) then
    FConsoleExclude.Add(AFilter);
end;

procedure TVDRX_LoggerExecutive.ExcludeFromFile(const AFilter: string);
begin
  if (AFilter <> '') and (FFileExclude.IndexOf(AFilter) < 0) then
    FFileExclude.Add(AFilter);
end;

function TVDRX_LoggerExecutive.IsExcluded(AList: TStringList; const ATopic: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to AList.Count - 1 do
    if TopicMatches(AList[i], ATopic) then Exit(True);
  Result := False;
end;

// Idempotent: stops the writer thread after it has written everything queued.
procedure TVDRX_LoggerExecutive.Shutdown;
begin
  FLock.Enter;
  try
    if FStopping then Exit;
    FStopping := True;
  finally
    FLock.Leave;
  end;
  FSignal.SetEvent;
  FWriter.WaitFor;
  FlushPending; // anything published after the writer's final pass
end;

// Swaps out whatever is pending and writes it: one file write + one fsync +
// one console write per batch, however many lines were queued.
procedure TVDRX_LoggerExecutive.FlushPending;
var
  FileBatch, ConsoleBatch: string;
begin
  FLock.Enter;
  try
    FileBatch := FFileLines;
    ConsoleBatch := FConsoleLines;
    FFileLines := '';
    FConsoleLines := '';
  finally
    FLock.Leave;
  end;
  if FileBatch <> '' then
  begin
    try
      FFileStream.WriteBuffer(FileBatch[1], Length(FileBatch));
      FileFlush(FFileStream.Handle); // fsync - data reaches disk even on an abrupt shutdown
    except
      // a full disk must not take the daemon down with it
    end;
  end;
  if ConsoleBatch <> '' then
    ConsoleWrite(ConsoleBatch);
end;

procedure TVDRX_LoggerExecutive.WriterLoop;
var
  Stopping: Boolean;
begin
  repeat
    FSignal.WaitFor(500);
    FLock.Enter;
    try
      Stopping := FStopping;
    finally
      FLock.Leave;
    end;
    FlushPending;
  until Stopping;
end;

function TVDRX_LoggerExecutive.LevelOf(const ATopic: string): TLogLevel;
begin
  if ATopic = 'log.error' then
    Result := lvlERROR
  else if ATopic = 'log.warn' then
    Result := lvlWARN
  else
    Result := lvlINFO;
end;

function TVDRX_LoggerExecutive.LevelName(ALevel: TLogLevel): string;
begin
  case ALevel of
    lvlERROR: Result := 'ERROR';
    lvlWARN:  Result := 'WARN ';
  else
    Result := 'INFO ';
  end;
end;

function TVDRX_LoggerExecutive.LevelColor(ALevel: TLogLevel): string;
begin
  case ALevel of
    lvlERROR: Result := CLR_ERROR;
    lvlWARN:  Result := CLR_WARN;
  else
    Result := CLR_INFO;
  end;
end;

// Clip first, then mask: the regexes only ever see a bounded string (the
// dispatch thread must not stall on a multi-megabyte body), and whatever the
// clip cut off can't leak. With masking on, "unlimited" is capped at 1 MB for
// the same reason.
function TVDRX_LoggerExecutive.ClipPayload(const APayload: string): string;
const
  REDACT_SCAN_CAP = 1048576;
var
  Limit: Integer;
  Text: string;
  Clipped: Boolean;
begin
  FRedactLock.Acquire;
  try
    Limit := FMaxPayload;
    if (Limit <= 0) and (FRedactor <> nil) then Limit := REDACT_SCAN_CAP;
    Clipped := (Limit > 0) and (Length(APayload) > Limit);
    if Clipped then Text := Copy(APayload, 1, Limit) else Text := APayload;
    if FRedactor <> nil then Text := FRedactor.Redact(Text);
  finally
    FRedactLock.Release;
  end;
  if Clipped then
    Result := Text + ' ...[' + IntToStr(Length(APayload)) + ' bytes total, truncated]'
  else
    Result := Text;
end;

procedure TVDRX_LoggerExecutive.HandlePacket(const AMsg: TVDRX_Message);
var
  Level: TLogLevel;
  Stamp, Payload, FileLine, ConsoleLine: string;
  ToConsole, ToFile: Boolean;
begin
  Level := LevelOf(AMsg.Topic);
  if Level < FThreshold then
    Exit;
  ToConsole := not IsExcluded(FConsoleExclude, AMsg.Topic);
  ToFile := not IsExcluded(FFileExclude, AMsg.Topic);
  if (not ToConsole) and (not ToFile) then
    Exit;

  Stamp := DateTimeToStr(Now);
  Payload := ClipPayload(AMsg.Payload);

  // Plain file line - no ANSI escapes.
  FileLine := Format('[%s] [%s] [%s] %s%s',
    [Stamp, LevelName(Level), AMsg.Topic, Payload, LineEnding]);
  // Colored console line.
  ConsoleLine := Format('%s[%s] [%s] [%s] %s%s%s',
    [LevelColor(Level), Stamp, LevelName(Level), AMsg.Topic, Payload,
     CLR_RESET, LineEnding]);

  FLock.Enter;
  try
    if ToFile then FFileLines := FFileLines + FileLine;
    if ToConsole then FConsoleLines := FConsoleLines + ConsoleLine;
  finally
    FLock.Leave;
  end;
  FSignal.SetEvent;
end;

initialization
  GConsoleLock := TCriticalSection.Create;

finalization
  GConsoleLock.Free;

end.
