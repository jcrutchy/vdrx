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
  // Backed by whatever JSON object AFilePath's file contains, MERGED with
  // every file its top-level "includes" array names (recursively - an
  // included file can itself have its own "includes"). This is what lets an
  // application's own executive definitions (its "processes"/"http_sites"/
  // "cli_bridges"/"socket_clients"/... entries, or a future "templates"
  // list) live and get version-controlled in that application's own repo,
  // with vdrx.conf itself just naming the file:
  //
  //   { "includes": ["../kyzu/kyzu.vdrx.conf"], "http_sites": [...] }
  //
  // Include paths are resolved relative to the file that names them, not to
  // the daemon's own working directory - so kyzu.vdrx.conf's own includes
  // (if it has any) work the same way regardless of where vdrx.exe is
  // actually launched from. See DeepMergeInto/LoadMerged (in the
  // implementation section) for the exact merge rules: array-valued keys
  // accumulate across every file involved; the top-level vdrx.conf's own
  // scalar settings always win over anything an include sets.

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
    // Absolute path of whichever file this config was actually loaded from
    // - always FFilePath itself, never an include (see LoadMerged) - so an
    // error message naming "the config" can say exactly which file, even
    // once includes are involved.
    property FilePath: string read FFilePath;
  end;

implementation

// SysUtils doesn't provide this (it's normally an LCL/FileUtil helper, not
// available to a plain fp-units-fcl build) - a minimal cross-platform check
// covering what actually shows up in an "includes" entry: a leading path
// delimiter (Unix root, or a Windows UNC share), or a Windows drive letter
// ("C:\..." / "C:/...").
function IsAbsolutePath(const APath: string): Boolean;
begin
  Result := (Length(APath) > 0) and (APath[1] in ['/', '\'])
    or ((Length(APath) >= 2) and (APath[2] = ':') and (UpCase(APath[1]) in ['A'..'Z']));
end;

// Recursively merges ASource's keys into ATarget (ATarget wins the tiebreak
// on every rule below, i.e. this is "layer ASource underneath what's already
// in ATarget", not the other way round):
//   - both sides have an OBJECT at the same key -> recurse (a nested
//     "settings" object from an include and one from the including file
//     both contribute their keys, rather than one replacing the other
//     wholesale)
//   - both sides have an ARRAY at the same key -> CONCATENATE, ATarget's
//     existing elements first, ASource's appended after. This is what makes
//     "includes" actually useful for VDRX's shape of config in particular:
//     "processes"/"http_sites"/"cli_bridges"/"socket_clients"/"buckets" (and
//     any future array-valued section - a "templates" list, say) all
//     accumulate across every included file plus the top-level one,
//     automatically, with no per-section-name special-casing needed here at
//     all - this function has no idea any of those keys exist.
//   - anything else (a scalar, or a type mismatch) -> ATarget's existing
//     value wins if it has one; only added from ASource if ATarget doesn't
//     already have that key. Combined with the include-processing order in
//     LoadMerged below (each included file merged in, in listed order,
//     BEFORE the file that did the including is itself merged on top), the
//     net effect is: the top-level vdrx.conf's own scalar settings always
//     win over anything an include sets, and an earlier include wins over a
//     later one for whatever neither the top-level file nor an earlier
//     include already decided.
procedure DeepMergeInto(ATarget, ASource: TJSONObject);
var
  i, j: Integer;
  Name: string;
  SrcVal, ExistingVal: TJSONData;
begin
  for i := 0 to ASource.Count - 1 do
  begin
    Name := ASource.Names[i];
    SrcVal := ASource.Items[i];
    ExistingVal := ATarget.Find(Name);
    if Assigned(ExistingVal) and (ExistingVal is TJSONObject) and (SrcVal is TJSONObject) then
      DeepMergeInto(TJSONObject(ExistingVal), TJSONObject(SrcVal))
    else if Assigned(ExistingVal) and (ExistingVal is TJSONArray) and (SrcVal is TJSONArray) then
      for j := 0 to TJSONArray(SrcVal).Count - 1 do
        TJSONArray(ExistingVal).Add(TJSONArray(SrcVal).Items[j].Clone)
    else if not Assigned(ExistingVal) then
      ATarget[Name] := SrcVal.Clone;
    // else: ATarget already has a non-mergeable value at this key - it wins, ASource's is dropped
  end;
end;

// Loads AFilePath, recursively resolves and merges any top-level "includes"
// array it names (paths resolved relative to AFilePath's OWN directory, so
// an included file's includes work the same way regardless of which
// directory the daemon itself was launched from - see the readme's path
// gotchas, this is deliberately NOT relative to the daemon's CWD), and
// returns the fully merged TJSONObject. AVisited is the set of absolute
// paths already loaded on this call chain, both to avoid infinite recursion
// on an accidental include cycle and to avoid pointlessly loading the same
// shared file twice if two different includes both name it - either case
// silently skips the repeat rather than raising, since a merge is
// idempotent-ish for arrays only in the sense that skipping is safer than
// either double-concatenating a shared processes/http_sites entry or
// killing the whole daemon's config load over what's likely a harmless
// diamond-shaped include graph, not a real error.
function LoadMerged(const AFilePath: string; AVisited: TStringList): TJSONObject;
var
  AbsPath: string;
  JSONText: TStringList;
  Parsed: TJSONData;
  IncludesNode: TJSONData;
  IncludePath: string;
  i: Integer;
  IncludedObj: TJSONObject;
  BaseDir: string;
begin
  Result := nil;
  AbsPath := ExpandFileName(AFilePath);
  if AVisited.IndexOf(AbsPath) >= 0 then
  begin
    WriteLn(StdErr, 'vdrx_config: "', AbsPath, '" already loaded on this include chain - skipping repeat/cycle.');
    Exit;
  end;
  AVisited.Add(AbsPath);

  if not FileExists(AbsPath) then
  begin
    WriteLn(StdErr, 'vdrx_config: included file not found: ', AbsPath);
    Exit;
  end;

  JSONText := TStringList.Create;
  try
    JSONText.LoadFromFile(AbsPath);
    try
      Parsed := GetJSON(JSONText.Text);
    except
      on E: Exception do
      begin
        WriteLn(StdErr, 'vdrx_config: failed to parse ', AbsPath, ' - ', E.Message);
        Exit;
      end;
    end;
  finally
    JSONText.Free;
  end;

  if not (Parsed is TJSONObject) then
  begin
    WriteLn(StdErr, 'vdrx_config: ', AbsPath, ' does not contain a JSON object at the top level - ignoring it.');
    Parsed.Free;
    Exit;
  end;

  Result := TJSONObject(Parsed);
  BaseDir := ExtractFileDir(AbsPath);

  // Resolve and merge every include BEFORE this file's own content, so
  // DeepMergeInto's "ATarget already has this key -> ATarget wins" rule
  // means this file's own settings always beat anything an include sets -
  // see DeepMergeInto's comment.
  IncludesNode := Result.Find('includes');
  if Assigned(IncludesNode) and (IncludesNode is TJSONArray) then
  begin
    for i := 0 to TJSONArray(IncludesNode).Count - 1 do
    begin
      IncludePath := TJSONArray(IncludesNode)[i].AsString;
      if IncludePath = '' then Continue;
      if not IsAbsolutePath(IncludePath) then
        IncludePath := IncludeTrailingPathDelimiter(BaseDir) + IncludePath;
      IncludedObj := LoadMerged(IncludePath, AVisited);
      if Assigned(IncludedObj) then
      begin
        try
          DeepMergeInto(Result, IncludedObj);
        finally
          IncludedObj.Free;
        end;
      end;
    end;
    Result.Delete('includes'); // it's done its job - don't leave it visible as a stray top-level array to anything reading the merged config
  end;
end;

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
  Visited: TStringList;
  NewData: TJSONObject;
begin
  FLock.Enter;
  try
    Visited := TStringList.Create;
    try
      Visited.Sorted := True;
      Visited.Duplicates := dupIgnore;
      // NewData comes back fully merged - top-level file plus every
      // "includes" entry it (recursively) names - see LoadMerged/
      // DeepMergeInto above. Same "parse into a local var first, only touch
      // FData once we know it succeeded" reasoning as before: an error
      // anywhere in that chain (missing file, bad JSON, a bad include path)
      // is logged by LoadMerged itself and leaves NewData nil here, so a
      // broken 'sys.reload' keeps the last-known-good FData rather than
      // leaving every GetString/GetInteger call across the daemon reading a
      // freed pointer.
      NewData := LoadMerged(FFilePath, Visited);
      if Assigned(NewData) then
      begin
        if Assigned(FData) then FData.Free;
        FData := NewData;
      end;
      // else: LoadMerged already logged why - FData is left untouched
    finally
      Visited.Free;
    end;
  finally
    FLock.Leave;
  end;
end;




end.
