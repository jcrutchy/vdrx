unit vdrx_config;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser, SyncObjs;

type
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

procedure TVDRX_Config.Reload;
var
  JSONString: TStringList;
begin
  FLock.Enter;
  try
    if FileExists(FFilePath) then begin
      JSONString := TStringList.Create;
      try
        JSONString.LoadFromFile(FFilePath);
        if Assigned(FData) then FData.Free;
        FData := TJSONObject(GetJSON(JSONString.Text));
      finally
        JSONString.Free;
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

end.
