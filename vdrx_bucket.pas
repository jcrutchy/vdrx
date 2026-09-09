unit vdrx_bucket;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, fpjson, vdrx_core;

type
  // Generic append-only history recorder. One instance per declared bucket -
  // subscribes to whatever topic filter(s) it's registered under (same
  // multi-filter Registry.Register mechanism as anything else) and appends
  // every matching message as one JSON line to its own file. Unlike Logger
  // (one fixed instance covering log.> specifically), any number of these
  // get created from the "buckets" config array in vdrx_daemon.lpr - the
  // same shape as "processes" spinning up N TVDRX_BridgeExecutive instances.
  //
  // Deliberately full history, not "latest value per topic": every message
  // is appended, nothing is overwritten or summarized. Retrieval is the
  // "history" admin command (see vdrx_admin.pas / vdrx_admincmd.pas), not
  // automatic replay onto the bus at startup - replaying an entire history
  // would re-fire whatever every current subscriber does in response to
  // each message, which for something like an old sys.kill would be
  // actively dangerous rather than merely pointless.
  TVDRX_BucketExecutive = class(TVDRX_Executive)
  private
    FFileStream: TFileStream;
    FFilePath: string;
    FMaxSizeBytes: Int64;
    FMaxFiles: Integer;
    procedure RotateIfNeeded(AIncomingBytes: Int64);
    procedure ShiftRotatedFiles;
  public
    // AMaxSizeMB = 0 (the default) disables rotation entirely, preserving
    // the original unbounded-append behaviour for any bucket that doesn't
    // ask for it. When AMaxSizeMB > 0, once appending the next line would
    // push the file past that size, the current file is renamed to
    // "<path>.1" (any existing "<path>.1".."<path>.N-1" shift up by one
    // first, and whatever was already at "<path>.N" is discarded) and a
    // fresh file is started at FilePath. AMaxFiles <= 0 defaults to 5
    // rotated files kept alongside the live one.
    constructor Create(ABus: TVDRX_MessageQueue; const AFilePath: string;
      AMaxSizeMB: Integer = 0; AMaxFiles: Integer = 0); reintroduce;
    destructor Destroy; override;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    property FilePath: string read FFilePath;
  end;

implementation

constructor TVDRX_BucketExecutive.Create(ABus: TVDRX_MessageQueue; const AFilePath: string;
  AMaxSizeMB: Integer; AMaxFiles: Integer);
begin
  inherited Create(ABus);
  FFilePath := AFilePath;
  FMaxSizeBytes := Int64(AMaxSizeMB) * 1024 * 1024;
  if AMaxFiles > 0 then
    FMaxFiles := AMaxFiles
  else
    FMaxFiles := 5;
  // Append if the file already exists, otherwise create fresh - same
  // open-or-create pattern as vdrx_logger.pas, for the same reason: a
  // restart shouldn't truncate history that was already there.
  if FileExists(AFilePath) then
    FFileStream := TFileStream.Create(AFilePath, fmOpenReadWrite or fmShareDenyWrite)
  else
    FFileStream := TFileStream.Create(AFilePath, fmCreate or fmShareDenyWrite);
  FFileStream.Seek(0, soEnd);
end;

destructor TVDRX_BucketExecutive.Destroy;
begin
  FFileStream.Free;
  inherited;
end;

// Shifts FilePath.1..FilePath.(FMaxFiles-1) up to .2..FMaxFiles (discarding
// whatever was already at .FMaxFiles), then renames the still-open-elsewhere
// current file to FilePath.1. Caller is responsible for having already
// closed FFileStream before calling this, and for reopening a fresh stream
// at FilePath afterwards - kept as a separate step rather than folded into
// RotateIfNeeded so the file-handle lifetime stays obvious at each call site.
procedure TVDRX_BucketExecutive.ShiftRotatedFiles;
var
  i: Integer;
  SrcPath, DstPath: string;
begin
  DstPath := FFilePath + '.' + IntToStr(FMaxFiles);
  if FileExists(DstPath) then
    DeleteFile(DstPath);
  for i := FMaxFiles - 1 downto 1 do
  begin
    SrcPath := FFilePath + '.' + IntToStr(i);
    DstPath := FFilePath + '.' + IntToStr(i + 1);
    if FileExists(SrcPath) then
      RenameFile(SrcPath, DstPath);
  end;
  if FileExists(FFilePath) then
    RenameFile(FFilePath, FFilePath + '.1');
end;

procedure TVDRX_BucketExecutive.RotateIfNeeded(AIncomingBytes: Int64);
begin
  if FMaxSizeBytes <= 0 then Exit; // rotation disabled for this bucket
  if FFileStream.Size + AIncomingBytes <= FMaxSizeBytes then Exit;
  FFileStream.Free;
  FFileStream := nil;
  ShiftRotatedFiles;
  FFileStream := TFileStream.Create(FFilePath, fmCreate or fmShareDenyWrite);
end;

procedure TVDRX_BucketExecutive.HandlePacket(const AMsg: TVDRX_Message);
var
  Entry: TJSONObject;
  Line: string;
begin
  Entry := TJSONObject.Create;
  try
    Entry.Add('ts', DateTimeToStr(AMsg.Timestamp));
    Entry.Add('seq', AMsg.Seq);
    Entry.Add('topic', AMsg.Topic);
    Entry.Add('source', AMsg.SourceID);
    Entry.Add('payload', AMsg.Payload);
    Line := Entry.AsJSON + LineEnding;
  finally
    Entry.Free;
  end;
  RotateIfNeeded(Length(Line));
  FFileStream.WriteBuffer(Line[1], Length(Line));
  FileFlush(FFileStream.Handle); // fsync - same durability guarantee as Logger;
                                  // matters even more here given force-kill on
                                  // Windows is a real, observed occurrence
end;

end.
