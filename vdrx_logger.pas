unit vdrx_logger;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, vdrx_core;

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
    FLock: TCriticalSection;
    FSignal: TEvent;
    FFileLines: string;     // pending, guarded by FLock
    FConsoleLines: string;  // pending, guarded by FLock
    FWriter: TThread;
    FStopping: Boolean;     // guarded by FLock
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
  end;

implementation

constructor TVDRX_LoggerExecutive.Create(ABus: TVDRX_MessageQueue;
  const APath: string; ALevel: TLogLevel; AMaxPayload: Integer);
begin
  inherited Create(ABus);
  FThreshold := ALevel;
  FMaxPayload := AMaxPayload;
  FLock := TCriticalSection.Create;
  FSignal := TEvent.Create(nil, False, False, '');
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
  FSignal.Free;
  FLock.Free;
  inherited;
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
    Write(ConsoleBatch);
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

function TVDRX_LoggerExecutive.ClipPayload(const APayload: string): string;
begin
  if (FMaxPayload > 0) and (Length(APayload) > FMaxPayload) then
    Result := Copy(APayload, 1, FMaxPayload) + ' ...[' + IntToStr(Length(APayload)) + ' bytes total, truncated]'
  else
    Result := APayload;
end;

procedure TVDRX_LoggerExecutive.HandlePacket(const AMsg: TVDRX_Message);
var
  Level: TLogLevel;
  Stamp, Payload, FileLine, ConsoleLine: string;
begin
  Level := LevelOf(AMsg.Topic);
  if Level < FThreshold then
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
    FFileLines := FFileLines + FileLine;
    FConsoleLines := FConsoleLines + ConsoleLine;
  finally
    FLock.Leave;
  end;
  FSignal.SetEvent;
end;

end.
