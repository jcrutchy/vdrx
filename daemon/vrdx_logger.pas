unit vrdx_logger;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, vrdx_core;

// ANSI Color Constants
const
  CLR_RESET  = #27'[0m';
  CLR_INFO   = #27'[32m'; // Green
  CLR_WARN   = #27'[33m'; // Yellow
  CLR_ERROR  = #27'[31m'; // Red

type
  TLogLevel = (lvlINFO, lvlWARN, lvlERROR);

  TVRDX_LoggerExecutive = class(TVRDX_Executive)
  private
    FFileStream: TFileStream;
    FThreshold: TLogLevel;
    function LevelOf(const ATopic: string): TLogLevel;
    function LevelName(ALevel: TLogLevel): string;
    function LevelColor(ALevel: TLogLevel): string;
  public
    constructor Create(ABus: TVRDX_MessageQueue; const APath: string;
      ALevel: TLogLevel); reintroduce;
    destructor Destroy; override;
    procedure HandlePacket(const AMsg: TVRDX_Message); override;
  end;

implementation

constructor TVRDX_LoggerExecutive.Create(ABus: TVRDX_MessageQueue;
  const APath: string; ALevel: TLogLevel);
begin
  inherited Create(ABus);
  FThreshold := ALevel;
  // Append if the log already exists, otherwise create fresh - fmCreate always
  // truncates, so it's only used the first time.
  if FileExists(APath) then
    FFileStream := TFileStream.Create(APath, fmOpenReadWrite or fmShareDenyWrite)
  else
    FFileStream := TFileStream.Create(APath, fmCreate or fmShareDenyWrite);
  FFileStream.Seek(0, soEnd);
end;

destructor TVRDX_LoggerExecutive.Destroy;
begin
  FFileStream.Free;
  inherited;
end;

function TVRDX_LoggerExecutive.LevelOf(const ATopic: string): TLogLevel;
begin
  if ATopic = 'log.error' then
    Result := lvlERROR
  else if ATopic = 'log.warn' then
    Result := lvlWARN
  else
    Result := lvlINFO;
end;

function TVRDX_LoggerExecutive.LevelName(ALevel: TLogLevel): string;
begin
  case ALevel of
    lvlERROR: Result := 'ERROR';
    lvlWARN:  Result := 'WARN ';
  else
    Result := 'INFO ';
  end;
end;

function TVRDX_LoggerExecutive.LevelColor(ALevel: TLogLevel): string;
begin
  case ALevel of
    lvlERROR: Result := CLR_ERROR;
    lvlWARN:  Result := CLR_WARN;
  else
    Result := CLR_INFO;
  end;
end;

procedure TVRDX_LoggerExecutive.HandlePacket(const AMsg: TVRDX_Message);
var
  Level: TLogLevel;
  Stamp, FileLine, ConsoleLine: string;
begin
  Level := LevelOf(AMsg.Topic);
  if Level < FThreshold then
    Exit;

  Stamp := DateTimeToStr(Now);

  // Plain file line - no ANSI escapes.
  FileLine := Format('[%s] [%s] [%s] %s%s',
    [Stamp, LevelName(Level), AMsg.Topic, AMsg.Payload, LineEnding]);
  FFileStream.WriteBuffer(FileLine[1], Length(FileLine));
  FileFlush(FFileStream.Handle); // fsync - ensures data hits disk even on an abrupt shutdown

  // Colored console line.
  ConsoleLine := Format('%s[%s] [%s] [%s] %s%s%s',
    [LevelColor(Level), Stamp, LevelName(Level), AMsg.Topic, AMsg.Payload,
     CLR_RESET, LineEnding]);
  Write(ConsoleLine);
end;

end.
