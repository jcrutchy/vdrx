unit vdrx_whiteboard;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, fpjson, jsonparser, vdrx_core;

type
  TVDRX_WhiteboardExecutive = class(TVDRX_Executive)
  private
    FLock: TCriticalSection;
    FBoards: TStringList; // board name -> TJSONObject, owned
    FDataDir: string;
    function BoardFilePath(const ABoardName: string): string;
    procedure SaveBoardToDisk(const ABoardName: string; ABoard: TJSONObject);
    function LoadBoardFromDisk(const ABoardName: string): TJSONObject; // nil if missing/corrupt
    function GetBoard(const ABoardName: string): TJSONObject;
    procedure ApplyDelta(const ABoardName: string; ADelta: TJSONObject);
  public
    constructor Create(ABus: TVDRX_MessageQueue; const ADataDir: string); reintroduce;
    destructor Destroy; override;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    function GetBoardSnapshot(const ABoardName: string): string; // thread-safe synchronous read, for TVDRX_HTTPExecutive
    // Board names with a persisted file on disk - used by the dashboard's nav
    // template to list known boards. A board that exists only in memory (has
    // had no delta applied yet since this process started, so was never
    // saved) won't show up until its first delta - same "cold" state a fresh
    // GetBoardSnapshot would hand back for it anyway.
    function ListBoardNames: TStringArray;
  end;

implementation

constructor TVDRX_WhiteboardExecutive.Create(ABus: TVDRX_MessageQueue; const ADataDir: string);
begin
  inherited Create(ABus);
  FLock := TCriticalSection.Create;
  FBoards := TStringList.Create;
  FBoards.OwnsObjects := True;
  if ADataDir <> '' then
    FDataDir := ADataDir
  else
    FDataDir := 'vdrx_data' + PathDelim + 'whiteboard';
  ForceDirectories(FDataDir);
end;

destructor TVDRX_WhiteboardExecutive.Destroy;
begin
  FBoards.Free;
  FLock.Free;
  inherited Destroy;
end;

function TVDRX_WhiteboardExecutive.BoardFilePath(const ABoardName: string): string;
begin
  // Board names now also come straight from an HTTP path segment
  // (GET /board/<name>) as of this session - vdrx_http.pas is what sanitises
  // them (alnum/underscore/hyphen only) before ever calling in here or
  // GetBoardSnapshot, so this stays a trusted-input assumption rather than
  // duplicating that check on every call.
  Result := IncludeTrailingPathDelimiter(FDataDir) + ABoardName + '.json';
end;

procedure TVDRX_WhiteboardExecutive.SaveBoardToDisk(const ABoardName: string; ABoard: TJSONObject);
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.Text := ABoard.AsJSON;
    SL.SaveToFile(BoardFilePath(ABoardName));
  finally
    SL.Free;
  end;
end;

function TVDRX_WhiteboardExecutive.LoadBoardFromDisk(const ABoardName: string): TJSONObject;
var
  SL: TStringList;
  J: TJSONData;
  Path: string;
begin
  Result := nil;
  Path := BoardFilePath(ABoardName);
  if not FileExists(Path) then Exit;
  SL := TStringList.Create;
  try
    try
      SL.LoadFromFile(Path);
      J := GetJSON(SL.Text);
      if J is TJSONObject then
        Result := TJSONObject(J)
      else
        J.Free; // unexpected shape - fall back to a fresh board rather than trust it
    except
      Result := nil; // corrupt/partial file (e.g. crash mid-write) - same fallback
    end;
  finally
    SL.Free;
  end;
end;

function TVDRX_WhiteboardExecutive.GetBoard(const ABoardName: string): TJSONObject;
var
  idx: Integer;
begin
  idx := FBoards.IndexOf(ABoardName);
  if idx >= 0 then
    Exit(TJSONObject(FBoards.Objects[idx]));

  Result := LoadBoardFromDisk(ABoardName); // cold-start hydration
  if not Assigned(Result) then
  begin
    Result := TJSONObject.Create;
    Result.Add('widgets', TJSONArray.Create);
    Result.Add('links', TJSONArray.Create);
  end;
  FBoards.AddObject(ABoardName, Result);
end;

procedure TVDRX_WhiteboardExecutive.ApplyDelta(const ABoardName: string; ADelta: TJSONObject);
var
  Board: TJSONObject;
  Op, WidgetID: string;
  Arr: TJSONArray;
  i: Integer;
  Found: Boolean;
begin
  Board := GetBoard(ABoardName);
  Op := ADelta.Get('op', '');
  if Op = 'add' then
    Board.Arrays['widgets'].Add(TJSONObject(ADelta.Objects['widget'].Clone))
  else if Op = 'move' then
  begin
    // CHANGED this session: updates the matching widget's x/y in place (by
    // id) instead of appending the raw delta as a differently-shaped record
    // into 'widgets' - that would've made 'widgets' an event log a client
    // has to replay/reduce rather than a "current state" list it can render
    // directly on a fresh page load. Delta shape:
    // {"op":"move","id":"<widget id>","x":<num>,"y":<num>}. This path was
    // unused before (dashboard.js didn't exist), so no wire-format migration
    // needed - but delete any board*.json on disk from earlier manual
    // testing with the old shape, since it may contain stray delta-shaped
    // entries mixed into 'widgets'.
    WidgetID := ADelta.Get('id', '');
    Arr := Board.Arrays['widgets'];
    Found := False;
    for i := 0 to Arr.Count - 1 do
      if (Arr[i] is TJSONObject) and (TJSONObject(Arr[i]).Get('id', '') = WidgetID) then
      begin
        TJSONObject(Arr[i]).Floats['x'] := ADelta.Get('x', 0.0);
        TJSONObject(Arr[i]).Floats['y'] := ADelta.Get('y', 0.0);
        Found := True;
        Break;
      end;
    if not Found then
      Bus.Publish('log.warn', 'whiteboard: move delta for unknown widget id "' + WidgetID + '" on board ' + ABoardName, ID);
  end
  else if Op = 'link' then
    Board.Arrays['links'].Add(TJSONObject(ADelta.Objects['link'].Clone));
  // Persist before announcing - a '.synced' subscriber that immediately re-fetches
  // via GetBoardSnapshot (or restarts the process right after) should never see
  // state older than what was just broadcast.
  SaveBoardToDisk(ABoardName, Board);
end;

procedure TVDRX_WhiteboardExecutive.HandlePacket(const AMsg: TVDRX_Message);
var
  Parts: TStringArray;
  BoardName: string;
  J: TJSONData;
begin
  // Topic shape: wb.<board>.delta - the '.synced' announcement HandlePacket itself
  // publishes below also matches a broad 'wb.>' subscription, so this check is load
  // bearing, not decorative: without it, Whiteboard re-delivers its own '.synced' to
  // itself as if it were a fresh delta, applies it again, re-announces, and loops
  // forever.
  Parts := AMsg.Topic.Split(['.']);
  if (Length(Parts) < 3) or (Parts[High(Parts)] <> 'delta') then
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

function TVDRX_WhiteboardExecutive.GetBoardSnapshot(const ABoardName: string): string;
begin
  FLock.Enter;
  try
    Result := GetBoard(ABoardName).AsJSON;
  finally
    FLock.Leave;
  end;
end;

function TVDRX_WhiteboardExecutive.ListBoardNames: TStringArray;
var
  SR: TSearchRec;
  n: Integer;
begin
  SetLength(Result, 0);
  if FindFirst(IncludeTrailingPathDelimiter(FDataDir) + '*.json', faAnyFile, SR) = 0 then
  begin
    try
      repeat
        if (SR.Attr and faDirectory) = 0 then
        begin
          n := Length(Result);
          SetLength(Result, n + 1);
          Result[n] := ChangeFileExt(SR.Name, '');
        end;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;
end;

end.