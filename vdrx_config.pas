unit vdrx_config;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser, SyncObjs, Generics.Collections;

type
  // One TStringList (Name=Value, scalar fields only - a nested object/array
  // inside an entry is skipped) per object in a config array - same row
  // shape as TVDRX_TemplateRows in vdrx_templates.pas, reused here for the
  // same reason: it's a simple, generic "flat record" shape that's easy for
  // any caller to consume without needing to know fpjson at all.
  TVDRX_ConfigRows = specialize TObjectList<TStringList>; // owns its rows

  TVDRX_Config = class
  private
    FData: TJSONObject;
    FLock: TCriticalSection;
    FFilePath: string;
  public
    constructor Create(const AFilePath: string);
    destructor Destroy; override;
    function GetString(APath: string; ADefault: string): string;
    function GetInteger(APath: string; ADefault: Integer): Integer;
    function GetBoolean(APath: string; ADefault: Boolean): Boolean;
    function GetStringArray(APath: string): TStringArray;
    // Parses every object in the JSON array at APath into its own row.
    // Deliberately builds the whole result INSIDE the lock and returns
    // caller-owned copies (TStringLists), rather than handing back a raw
    // TJSONArray reference - a reference into FData would dangle the moment
    // a concurrent Reload() (triggered by 'sys.reload', on a different
    // thread) frees and replaces it mid-iteration. Caller owns and frees
    // the result.
    function GetObjectArray(APath: string): TVDRX_ConfigRows;
    procedure Reload;
  end;

implementation

constructor TVDRX_Config.Create(const AFilePath: string);
begin
  FFilePath := AFilePath;
  FLock := TCriticalSection.Create;
  Reload;
end;

destructor TVDRX_Config.Destroy;
begin
  FData.Free;
  FLock.Free;
  inherited;
end;

function TVDRX_Config.GetString(APath: string; ADefault: string): string;
begin
  FLock.Enter;
  try
    if Assigned(FData) and (FData.FindPath(APath) <> nil) then
      Result := FData.GetPath(APath).AsString
    else
      Result := ADefault;
  finally
    FLock.Leave;
  end;
end;

function TVDRX_Config.GetInteger(APath: string; ADefault: Integer): Integer;
begin
  FLock.Enter;
  try
    if Assigned(FData) and (FData.FindPath(APath) <> nil) then
      Result := FData.GetPath(APath).AsInteger
    else
      Result := ADefault;
  finally
    FLock.Leave;
  end;
end;

function TVDRX_Config.GetBoolean(APath: string; ADefault: Boolean): Boolean;
begin
  FLock.Enter;
  try
    if Assigned(FData) and (FData.FindPath(APath) <> nil) then
      Result := FData.GetPath(APath).AsBoolean
    else
      Result := ADefault;
  finally
    FLock.Leave;
  end;
end;

function TVDRX_Config.GetStringArray(APath: string): TStringArray;
var
  Node: TJSONData;
  Arr: TJSONArray;
  i: Integer;
begin
  SetLength(Result, 0);
  FLock.Enter;
  try
    if not Assigned(FData) then Exit;
    Node := FData.FindPath(APath);
    if not Assigned(Node) or not (Node is TJSONArray) then Exit;
    Arr := TJSONArray(Node);
    SetLength(Result, Arr.Count);
    for i := 0 to Arr.Count - 1 do
      Result[i] := Arr.Strings[i];
  finally
    FLock.Leave;
  end;
end;

// Comma-joins a JSON array of scalars into one string, e.g. ["a.>","b.*"] ->
// "a.>,b.*". Topic filters never contain commas, so this is a safe, simple
// encoding that lets GetObjectArray keep its "everything is a flat
// TStringList row" contract without needing a second, array-aware accessor.
// Non-scalar elements (nested objects/arrays) are skipped.
function JoinJSONStringArray(AArr: TJSONArray): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to AArr.Count - 1 do
    if AArr[i].JSONType in [jtString, jtNumber, jtBoolean] then
    begin
      if Result <> '' then Result := Result + ',';
      Result := Result + AArr[i].AsString;
    end;
end;

function TVDRX_Config.GetObjectArray(APath: string): TVDRX_ConfigRows;
var
  Node: TJSONData;
  Arr: TJSONArray;
  i, j: Integer;
  Obj: TJSONObject;
  Row: TStringList;
begin
  Result := TVDRX_ConfigRows.Create;
  FLock.Enter;
  try
    if not Assigned(FData) then Exit;
    Node := FData.FindPath(APath);
    if not Assigned(Node) or not (Node is TJSONArray) then Exit;
    Arr := TJSONArray(Node);
    for i := 0 to Arr.Count - 1 do
      if Arr[i] is TJSONObject then
      begin
        Obj := TJSONObject(Arr[i]);
        Row := TStringList.Create;
        for j := 0 to Obj.Count - 1 do
          if Obj.Items[j].JSONType in [jtString, jtNumber, jtBoolean] then
            Row.Values[Obj.Names[j]] := Obj.Items[j].AsString
          else if Obj.Items[j].JSONType = jtArray then
            Row.Values[Obj.Names[j]] := JoinJSONStringArray(TJSONArray(Obj.Items[j]));
        Result.Add(Row);
      end;
  finally
    FLock.Leave;
  end;
end;

procedure TVDRX_Config.Reload;
var
  JSONString: TStringList;
  NewData: TJSONData;
begin
  FLock.Enter;
  try
    if FileExists(FFilePath) then begin
      JSONString := TStringList.Create;
      try
        JSONString.LoadFromFile(FFilePath);
        if Assigned(FData) then FData.Free;
        NewData := GetJSON(JSONString.Text);
        if NewData is TJSONObject then
        begin
          if Assigned(FData) then FData.Free;
          FData := TJSONObject(NewData);
        end
        else
          NewData.Free;
      finally
        JSONString.Free;
      end;
    end;
  finally
    FLock.Leave;
  end;
end;




end.
