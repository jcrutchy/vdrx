unit vdrx_templates;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, SyncObjs, Generics.Collections, vdrx_config;

type
  // One loop iteration's params (Name=Value, same shape as Fill's AParams).
  TVDRX_TemplateRows = specialize TObjectList<TStringList>; // owns its rows
  // Loop name -> its rows, passed into Fill alongside AParams.
  TVDRX_TemplateNamedRows = specialize TObjectDictionary<string, TVDRX_TemplateRows>; // owns its TVDRX_TemplateRows

  // Recursive template engine, modeled on webdb's PHP one but reimplemented in
  // Pascal. Five placeholder kinds, resolved in this order for every
  // template's raw text:
  //   $$SETTING$$              -> TVDRX_Config, looked up as 'settings.<name>'
  //   ??CONST??                -> app-registered constants (SetConstant)
  //   @@child@@                -> another template's filled content, recursive
  //   ##loop:name##...##endloop:name##
  //                             -> repeats its body once per row in
  //                                ARows['name'] (see Fill), with that row's
  //                                Name=Value params merged OVER the caller's
  //                                AParams (row wins on collision) and
  //                                substituted into the body immediately -
  //                                this has to happen before the final %%
  //                                pass below, since two rows using the same
  //                                %%field%% name need different values.
  //                                Unknown/absent loop names render zero rows.
  //   %%var%%                  -> caller-supplied per-call values (AParams),
  //                                substituted exactly once, over the fully
  //                                assembled result, after every level of
  //                                child/loop recursion has resolved - the
  //                                same "$params argument" behavior this was
  //                                modeled on.
  //
  // Cycle prevention on @@children@@ is per-branch, not global - see
  // ReplaceChildren. Loops don't recurse into themselves (a loop body isn't a
  // named template), so they don't need the same guard.
  //
  // Templates are loaded from disk ON DEMAND and cached in memory from then
  // on - Create/Reload never scan or read the whole directory up front, only
  // Fill()'ing a given name for the first time touches disk for it. Template
  // files are named '<name>.tpl' under ATemplateDir (flat, not recursive into
  // subdirectories).
  TVDRX_TemplateStore = class
  private
    FLock: TCriticalSection;
    FTemplates: TStringList; // Name=Value cache; Value = raw file content (or '' if the file didn't exist - cached too, so a bad name doesn't re-stat every request)
    FConstants: TStringList; // Name=Value, set via SetConstant
    FConfig: TVDRX_Config;
    FDir: string;
    function LookupSetting(const AName: string): string;
    function LookupConstant(const AName: string): string;
    function LoadTemplateCached(const AName: string): string;
    function ReplaceChildren(const S: string; AChain: TStringList; AParams: TStringList; ARows: TVDRX_TemplateNamedRows): string;
    function ReplaceLoops(const S: string; AParams: TStringList; ARows: TVDRX_TemplateNamedRows): string;
    function ReplaceParams(const S: string; AParams: TStringList): string;
    function FillRecursive(const AName: string; AChain: TStringList; AParams: TStringList; ARows: TVDRX_TemplateNamedRows): string;
  public
    constructor Create(AConfig: TVDRX_Config; const ATemplateDir: string);
    destructor Destroy; override;
    // Drops the whole in-memory cache - the next Fill() for any template name
    // reloads it from disk on demand, picking up on-disk edits. This is what
    // 'sys.reload' triggers (see vdrx_admin.pas) - it does NOT eagerly reload
    // everything, just makes the next access per-name fresh again.
    procedure Reload;
    procedure SetConstant(const AName, AValue: string);
    // AParams is an optional Name=Value TStringList, matching the $params
    // argument this was modeled on. ARows is an optional loop-name -> rows
    // map for any ##loop:name## blocks anywhere in the template or its
    // children. Caller keeps ownership of both.
    function Fill(const ATemplateName: string; AParams: TStringList = nil; ARows: TVDRX_TemplateNamedRows = nil): string;
  end;

implementation

type
  TTemplateLookupFunc = function(const AName: string): string of object;

// Scans S for OpenTag<name>CloseTag placeholders, replacing each with whatever
// ALookup returns for that name. An unclosed tag (no matching CloseTag found) is
// left as-is for the remainder of the string, rather than eating everything after
// it - a stray '$$' in ordinary content shouldn't corrupt otherwise-valid output.
function ReplaceTags(const S, OpenTag, CloseTag: string; ALookup: TTemplateLookupFunc): string;
var
  Pos1, Pos2, SearchFrom: Integer;
  Name: string;
begin
  Result := '';
  SearchFrom := 1;
  while True do
  begin
    Pos1 := PosEx(OpenTag, S, SearchFrom);
    if Pos1 = 0 then
    begin
      Result := Result + Copy(S, SearchFrom, Length(S));
      Break;
    end;
    Pos2 := PosEx(CloseTag, S, Pos1 + Length(OpenTag));
    if Pos2 = 0 then
    begin
      Result := Result + Copy(S, SearchFrom, Length(S));
      Break;
    end;
    Name := Copy(S, Pos1 + Length(OpenTag), Pos2 - (Pos1 + Length(OpenTag)));
    Result := Result + Copy(S, SearchFrom, Pos1 - SearchFrom) + ALookup(Name);
    SearchFrom := Pos2 + Length(CloseTag);
  end;
end;

{ TVDRX_TemplateStore }

constructor TVDRX_TemplateStore.Create(AConfig: TVDRX_Config; const ATemplateDir: string);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FTemplates := TStringList.Create;
  FConstants := TStringList.Create;
  FConfig := AConfig;
  FDir := ATemplateDir;
  // Deliberately no directory scan/eager load here - see unit comment.
end;

destructor TVDRX_TemplateStore.Destroy;
begin
  FTemplates.Free;
  FConstants.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TVDRX_TemplateStore.Reload;
begin
  FLock.Enter;
  try
    FTemplates.Clear;
  finally
    FLock.Leave;
  end;
end;

procedure TVDRX_TemplateStore.SetConstant(const AName, AValue: string);
begin
  FLock.Enter;
  try
    FConstants.Values[AName] := AValue;
  finally
    FLock.Leave;
  end;
end;

function TVDRX_TemplateStore.LookupSetting(const AName: string): string;
begin
  Result := FConfig.GetString('settings.' + AName, '');
end;

function TVDRX_TemplateStore.LookupConstant(const AName: string): string;
begin
  Result := FConstants.Values[AName];
end;

function TVDRX_TemplateStore.LoadTemplateCached(const AName: string): string;
var
  SL: TStringList;
  Path: string;
  Idx: Integer;
begin
  FLock.Enter;
  try
    Idx := FTemplates.IndexOfName(AName);
    if Idx >= 0 then
      Exit(FTemplates.ValueFromIndex[Idx]); // already cached - served from memory, no disk touch
  finally
    FLock.Leave;
  end;

  // Not cached yet - read from disk now, outside the lock (file IO shouldn't
  // block other requests' cache lookups), then cache it for next time.
  Path := IncludeTrailingPathDelimiter(FDir) + AName + '.tpl';
  Result := '';
  if FileExists(Path) then
  begin
    SL := TStringList.Create;
    try
      SL.LoadFromFile(Path);
      Result := SL.Text;
    finally
      SL.Free;
    end;
  end;

  FLock.Enter;
  try
    Idx := FTemplates.IndexOfName(AName);
    if Idx >= 0 then
      Result := FTemplates.ValueFromIndex[Idx] // lost a race with another thread loading the same name - use theirs
    else
      FTemplates.Add(AName + '=' + Result); // Add() rather than Values[]'s setter - avoids that
                                             // property's ini-style "empty value deletes/omits
                                             // the entry" ambiguity, which would defeat caching
                                             // a miss (empty Result for a nonexistent file)
  finally
    FLock.Leave;
  end;
end;

function TVDRX_TemplateStore.ReplaceChildren(const S: string; AChain: TStringList; AParams: TStringList; ARows: TVDRX_TemplateNamedRows): string;
var
  Pos1, Pos2, SearchFrom: Integer;
  ChildName: string;
begin
  Result := '';
  SearchFrom := 1;
  while True do
  begin
    Pos1 := PosEx('@@', S, SearchFrom);
    if Pos1 = 0 then
    begin
      Result := Result + Copy(S, SearchFrom, Length(S));
      Break;
    end;
    Pos2 := PosEx('@@', S, Pos1 + 2);
    if Pos2 = 0 then
    begin
      Result := Result + Copy(S, SearchFrom, Length(S));
      Break;
    end;
    ChildName := Copy(S, Pos1 + 2, Pos2 - (Pos1 + 2));
    Result := Result + Copy(S, SearchFrom, Pos1 - SearchFrom);
    if AChain.IndexOf(ChildName) >= 0 then
      Result := Result + '@@' + ChildName + '@@' // cycle - leave visible rather than recurse forever or vanish silently
    else if LoadTemplateCached(ChildName) <> '' then
      Result := Result + FillRecursive(ChildName, AChain, AParams, ARows)
    // else: unknown template name - drop silently, consistent with settings/constants misses
    ;
    SearchFrom := Pos2 + 2;
  end;
end;

// Expands ##loop:name##body##endloop:name## blocks. Body is rendered once per
// row in ARows[name], with that row's Name=Value params merged over AParams
// (row wins) and substituted immediately via ReplaceParams - deliberately NOT
// deferred to the final Fill-level %% pass, since different rows need
// different values for the same %%field%% name. Text outside any loop block
// is passed through untouched, so its own %%vars%% still resolve at the end
// exactly as before.
function TVDRX_TemplateStore.ReplaceLoops(const S: string; AParams: TStringList; ARows: TVDRX_TemplateNamedRows): string;
var
  Pos1, Pos2, EndTagPos, SearchFrom, i: Integer;
  LoopName, Body, EndTag: string;
  Rows: TVDRX_TemplateRows;
  Row, Merged: TStringList;
begin
  Result := '';
  SearchFrom := 1;
  while True do
  begin
    Pos1 := PosEx('##loop:', S, SearchFrom);
    if Pos1 = 0 then
    begin
      Result := Result + Copy(S, SearchFrom, Length(S));
      Break;
    end;
    Pos2 := PosEx('##', S, Pos1 + 7); // closes the opening "##loop:NAME##" tag
    if Pos2 = 0 then
    begin
      Result := Result + Copy(S, SearchFrom, Length(S));
      Break;
    end;
    LoopName := Copy(S, Pos1 + 7, Pos2 - (Pos1 + 7));
    EndTag := '##endloop:' + LoopName + '##';
    EndTagPos := PosEx(EndTag, S, Pos2 + 2);
    if EndTagPos = 0 then
    begin
      Result := Result + Copy(S, SearchFrom, Length(S)); // unclosed - leave the rest untouched
      Break;
    end;
    Body := Copy(S, Pos2 + 2, EndTagPos - (Pos2 + 2));
    Result := Result + Copy(S, SearchFrom, Pos1 - SearchFrom);

    if Assigned(ARows) and ARows.TryGetValue(LoopName, Rows) then
      for Row in Rows do
      begin
        Merged := TStringList.Create;
        try
          if Assigned(AParams) then Merged.Assign(AParams);
          for i := 0 to Row.Count - 1 do
            Merged.Values[Row.Names[i]] := Row.ValueFromIndex[i];
          Result := Result + ReplaceParams(Body, Merged);
        finally
          Merged.Free;
        end;
      end;

    SearchFrom := EndTagPos + Length(EndTag);
  end;
end;

function TVDRX_TemplateStore.ReplaceParams(const S: string; AParams: TStringList): string;
var
  Pos1, Pos2, SearchFrom, idx: Integer;
  VarName: string;
begin
  if not Assigned(AParams) then Exit(S);
  Result := '';
  SearchFrom := 1;
  while True do
  begin
    Pos1 := PosEx('%%', S, SearchFrom);
    if Pos1 = 0 then
    begin
      Result := Result + Copy(S, SearchFrom, Length(S));
      Break;
    end;
    Pos2 := PosEx('%%', S, Pos1 + 2);
    if Pos2 = 0 then
    begin
      Result := Result + Copy(S, SearchFrom, Length(S));
      Break;
    end;
    VarName := Copy(S, Pos1 + 2, Pos2 - (Pos1 + 2));
    Result := Result + Copy(S, SearchFrom, Pos1 - SearchFrom);
    idx := AParams.IndexOfName(VarName);
    if idx >= 0 then
      Result := Result + AParams.ValueFromIndex[idx];
    SearchFrom := Pos2 + 2;
  end;
end;

function TVDRX_TemplateStore.FillRecursive(const AName: string; AChain: TStringList; AParams: TStringList; ARows: TVDRX_TemplateNamedRows): string;
var
  Raw: string;
  NewChain: TStringList;
begin
  Raw := LoadTemplateCached(AName);
  Raw := ReplaceTags(Raw, '$$', '$$', @LookupSetting);
  Raw := ReplaceTags(Raw, '??', '??', @LookupConstant);
  NewChain := TStringList.Create;
  try
    NewChain.Assign(AChain);
    NewChain.Add(AName);
    Result := ReplaceChildren(Raw, NewChain, AParams, ARows);
  finally
    NewChain.Free;
  end;
  Result := ReplaceLoops(Result, AParams, ARows); // after children, so a child's own loop blocks (brought in by @@) get expanded too
end;

function TVDRX_TemplateStore.Fill(const ATemplateName: string; AParams: TStringList; ARows: TVDRX_TemplateNamedRows): string;
var
  Chain: TStringList;
begin
  if LoadTemplateCached(ATemplateName) = '' then Exit('');
  Chain := TStringList.Create;
  try
    Result := FillRecursive(ATemplateName, Chain, AParams, ARows);
  finally
    Chain.Free;
  end;
  Result := ReplaceParams(Result, AParams); // final outer-level %% pass - anything already consumed inside a loop body no longer contains %% by this point
end;

end.