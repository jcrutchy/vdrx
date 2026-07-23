unit vrdx_whiteboard;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, fpjson, jsonparser, vrdx_core;

type
  // Subscribes 'wb.>'. HandlePacket applies a delta, persists the board to disk,
  // then republishes '<board>.synced'. FLock exists even though HandlePacket alone
  // (Dispatcher-thread only) wouldn't strictly need it - GetBoardSnapshot is a
  // synchronous accessor meant to be called from the HTTP executive's own
  // request-handling thread, so board state genuinely is touched from more than
  // one thread.
  //
  // Persistence added this session: one JSON file per board under ADataDir,
  // rewritten in full after every applied delta and read back in on first access
  // after a restart (cold-start hydration) - deliberately simple (no incremental
  // append-log, no compaction) since board sizes here are small; revisit if that
  // stops being true.
  TVRDX_WhiteboardExecutive = class(TVRDX_Executive)
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
    constructor Create(ABus: TVRDX_MessageQueue; const ADataDir: string); reintroduce;
    destructor Destroy; override;
    procedure HandlePacket(const AMsg: TVRDX_Message); override;
    function GetBoardSnapshot(const ABoardName: string): string; // thread-safe synchronous read, for TVRDX_HTTPExecutive
  end;

implementation

constructor TVRDX_WhiteboardExecutive.Create(ABus: TVRDX_MessageQueue; const ADataDir: string);
begin
  inherited Create(ABus);
  FLock := TCriticalSection.Create;
  FBoards := TStringList.Create;
  FBoards.OwnsObjects := True;
  if ADataDir <> '' then
    FDataDir := ADataDir
  else
    FDataDir := 'vrdx_data' + PathDelim + 'whiteboard';
  ForceDirectories(FDataDir);
end;

destructor TVRDX_WhiteboardExecutive.Destroy;
begin
  FBoards.Free;
  FLock.Free;
  inherited Destroy;
end;

function TVRDX_WhiteboardExecutive.BoardFilePath(const ABoardName: string): string;
begin
  // Board names come from the topic ('wb.<board>.delta'), not arbitrary user input
  // over the wire, so no path-traversal sanitising here - revisit if that stops
  // being true (e.g. board names ever come straight from an HTTP path segment).
  Result := IncludeTrailingPathDelimiter(FDataDir) + ABoardName + '.json';
end;

procedure TVRDX_WhiteboardExecutive.SaveBoardToDisk(const ABoardName: string; ABoard: TJSONObject);
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

function TVRDX_WhiteboardExecutive.LoadBoardFromDisk(const ABoardName: string): TJSONObject;
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

function TVRDX_WhiteboardExecutive.GetBoard(const ABoardName: string): TJSONObject;
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
  // Persist before announcing - a '.synced' subscriber that immediately re-fetches
  // via GetBoardSnapshot (or restarts the process right after) should never see
  // state older than what was just broadcast.
  SaveBoardToDisk(ABoardName, Board);
end;

procedure TVRDX_WhiteboardExecutive.HandlePacket(const AMsg: TVRDX_Message);
var
  Parts: TStringArray;
  BoardName: string;
  J: TJSONData;
begin
  // Topic shape: wb.<board>.delta - the '.synced' announcement HandlePacket itself
  // publishes below also matches a broad 'wb.>' subscription, so this check is load
  // bearing, not decorative: without it, Whiteboard re-delivers its own '.synced' to
  // itself as if it were a fresh delta, applies it again, re-announces, and loops
  // forever. (Found by actually wiring Whiteboard into a running daemon for the
  // first time this session - it was latent and untriggered before that.)
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
