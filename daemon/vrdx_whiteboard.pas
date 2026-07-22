unit vrdx_whiteboard;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, fpjson, jsonparser, vrdx_core;

type
  // Trimmed hello-world version: in-memory only, no BucketStore yet (deliberately -
  // see session notes). Subscribes 'wb.>'. HandlePacket applies a delta, republishes
  // '<board>.synced'. FLock exists even though HandlePacket alone (Dispatcher-thread
  // only) wouldn't strictly need it - GetBoardSnapshot is a synchronous accessor
  // meant to be called from the HTTP executive's own request-handling thread, so
  // board state genuinely is touched from more than one thread.
  TVRDX_WhiteboardExecutive = class(TVRDX_Executive)
  private
    FLock: TCriticalSection;
    FBoards: TStringList; // board name -> TJSONObject, owned
    function GetBoard(const ABoardName: string): TJSONObject;
    procedure ApplyDelta(const ABoardName: string; ADelta: TJSONObject);
  public
    constructor Create(ABus: TVRDX_MessageQueue); override;
    destructor Destroy; override;
    procedure HandlePacket(const AMsg: TVRDX_Message); override;
    function GetBoardSnapshot(const ABoardName: string): string; // thread-safe synchronous read, for TVRDX_HTTPExecutive
  end;

implementation

constructor TVRDX_WhiteboardExecutive.Create(ABus: TVRDX_MessageQueue);
begin
  inherited Create(ABus);
  FLock := TCriticalSection.Create;
  FBoards := TStringList.Create;
  FBoards.OwnsObjects := True;
end;

destructor TVRDX_WhiteboardExecutive.Destroy;
begin
  FBoards.Free;
  FLock.Free;
  inherited Destroy;
end;

function TVRDX_WhiteboardExecutive.GetBoard(const ABoardName: string): TJSONObject;
var
  idx: Integer;
begin
  idx := FBoards.IndexOf(ABoardName);
  if idx >= 0 then
    Exit(TJSONObject(FBoards.Objects[idx]));
  Result := TJSONObject.Create;
  Result.Add('widgets', TJSONArray.Create);
  Result.Add('links', TJSONArray.Create);
  FBoards.AddObject(ABoardName, Result);
  // When BucketStore is added: load from disk here (cold-start hydration) instead of
  // always starting empty, and call FStore.SaveBucket at the end of ApplyDelta,
  // before HandlePacket publishes '.synced' - update state, persist, THEN announce.
end;

procedure TVRDX_WhiteboardExecutive.ApplyDelta(const ABoardName: string; ADelta: TJSONObject);
var
  Board: TJSONObject;
  Op: string;
begin
  Board := GetBoard(ABoardName);
  Op := ADelta.Get('op', '');
  if Op = 'add' then
    Board.Arrays['widgets'].Add(TJSONObject(ADelta.Objects['widget'].Clone))
  else if Op = 'move' then
    // Widget identity / last-write-wins resolution happens client-side; server just
    // appends the delta to history.
    Board.Arrays['widgets'].Add(TJSONObject(ADelta.Clone))
  else if Op = 'link' then
    Board.Arrays['links'].Add(TJSONObject(ADelta.Objects['link'].Clone));
end;

procedure TVRDX_WhiteboardExecutive.HandlePacket(const AMsg: TVRDX_Message);
var
  Parts: TStringArray;
  BoardName: string;
  J: TJSONData;
begin
  // Topic shape: wb.<board>.delta
  Parts := AMsg.Topic.Split(['.']);
  if Length(Parts) < 3 then
    Exit;
  BoardName := Parts[1];
  FLock.Enter;
  try
    try
      J := GetJSON(AMsg.Payload);
      try
        if J is TJSONObject then
        begin
          ApplyDelta(BoardName, TJSONObject(J));
          Bus.Publish('wb.' + BoardName + '.synced', AMsg.Payload, ID);
        end;
      finally
        J.Free;
      end;
    except
      // malformed delta - drop rather than corrupt board state
    end;
  finally
    FLock.Leave;
  end;
end;

function TVRDX_WhiteboardExecutive.GetBoardSnapshot(const ABoardName: string): string;
begin
  FLock.Enter;
  try
    Result := GetBoard(ABoardName).AsJSON;
  finally
    FLock.Leave;
  end;
end;

end.
