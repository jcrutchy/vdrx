unit vrdx_config;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser, SyncObjs;

type
  TVRDX_Config = class
  private
    FData: TJSONObject;
    FLock: TCriticalSection;
    FFilePath: string;
  public
    constructor Create(const AFilePath: string);
    destructor Destroy; override;
    function GetString(APath: string; ADefault: string): string;
    function GetInteger(APath: string; ADefault: Integer): Integer;
    procedure Reload;
  end;

implementation

constructor TVRDX_Config.Create(const AFilePath: string);
begin
  FFilePath := AFilePath;
  FLock := TCriticalSection.Create;
  Reload;
end;

destructor TVRDX_Config.Destroy;
begin
  FData.Free;
  FLock.Free;
  inherited;
end;

function TVRDX_Config.GetString(APath: string; ADefault: string): string;
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

function TVRDX_Config.GetInteger(APath: string; ADefault: Integer): Integer;
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

procedure TVRDX_Config.Reload;
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
