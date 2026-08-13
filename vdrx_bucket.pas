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
  public
    constructor Create(ABus: TVDRX_MessageQueue; const AFilePath: string); reintroduce;
    destructor Destroy; override;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    property FilePath: string read FFilePath;
  end;

implementation

constructor TVDRX_BucketExecutive.Create(ABus: TVDRX_MessageQueue; const AFilePath: string);
begin
  inherited Create(ABus);
  FFilePath := AFilePath;
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
  FFileStream.WriteBuffer(Line[1], Length(Line));
  FileFlush(FFileStream.Handle); // fsync - same durability guarantee as Logger;
                                  // matters even more here given force-kill on
                                  // Windows is a real, observed occurrence
end;

end.
