unit vdrx_templates;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, SyncObjs, vdrx_config;

type
  // Recursive template engine, modeled on webdb's PHP one (see Jared's webdb repo)
  // but reimplemented here in Pascal so vdrx_http.pas (or anything else) can use it
  // without a PHP dependency.
  //
  // Four placeholder kinds, resolved in this order for every template's raw text:
  //   $$SETTING$$   -> TVDRX_Config, looked up as 'settings.<name>'
  //   ??CONST??     -> app-registered constants (SetConstant), not config-reloadable
  //   @@child@@     -> another template's filled content, recursive
  //   %%var%%       -> caller-supplied per-call values (the Fill AParams argument) -
  //                    substituted exactly once, over the fully-assembled result,
  //                    after every level of child recursion has already resolved -
  //                    matching the "$params argument" behavior in the spec this
  //                    was modeled on.
  //
  // Cycle prevention is per-branch, not global: FillRecursive tracks the chain of
  // ancestor template names for the current recursion path and refuses to expand a
  // child that's already an ancestor of itself (left as an unexpanded @@name@@
  // rather than silently dropped, so a cycle is visible in the output instead of
  // just vanishing). The same template name can still appear multiple times at one
  // level, or independently in sibling branches - only actual self-inclusion is
  // blocked.
  TVDRX_TemplateStore = class
  private
    FLock: TCriticalSection;
    FTemplates: TStringList; // Name=Content, loaded from FDir
    FConstants: TStringList; // Name=Value, set via SetConstant
    FConfig: TVDRX_Config;
    FDir: string;
    function LookupSetting(const AName: string): string;
    function LookupConstant(const AName: string): string;
    function ReplaceChildren(const S: string; AChain: TStringList): string;
    function ReplaceParams(const S: string; AParams: TStringList): string;
    function FillRecursive(const AName: string; AChain: TStringList): string;
  public
    constructor Create(AConfig: TVDRX_Config; const ATemplateDir: string);
    destructor Destroy; override;
    // (Re)loads every file directly under ATemplateDir - not recursive into
    // subdirectories, matching "stored in the templates subdirectory" as a flat
    // layout. Template name = filename without extension.
    procedure Reload;
    procedure SetConstant(const AName, AValue: string);
    // AParams is an optional Name=Value TStringList (TStringList.Values[] shape),
    // matching the $params argument this was modeled on. Caller keeps ownership.
    function Fill(const ATemplateName: string; AParams: TStringList = nil): string;
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
  Reload;
end;

destructor TVDRX_TemplateStore.Destroy;
begin
  FTemplates.Free;
  FConstants.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TVDRX_TemplateStore.Reload;
var
  SR: TSearchRec;
  SL: TStringList;
  Name: string;
begin
  FLock.Enter;
  try
    FTemplates.Clear;
    if not DirectoryExists(FDir) then Exit;
    if FindFirst(IncludeTrailingPathDelimiter(FDir) + '*', faAnyFile, SR) = 0 then
    begin
      try
        repeat
          if (SR.Attr and faDirectory) <> 0 then Continue;
          Name := ChangeFileExt(SR.Name, '');
          SL := TStringList.Create;
          try
            SL.LoadFromFile(IncludeTrailingPathDelimiter(FDir) + SR.Name);
            FTemplates.Values[Name] := SL.Text;
          finally
            SL.Free;
          end;
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
    end;
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

function TVDRX_TemplateStore.ReplaceChildren(const S: string; AChain: TStringList): string;
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
    else if FTemplates.IndexOfName(ChildName) >= 0 then
      Result := Result + FillRecursive(ChildName, AChain)
    // else: unknown template name - drop silently, consistent with settings/constants misses
    ;
    SearchFrom := Pos2 + 2;
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

function TVDRX_TemplateStore.FillRecursive(const AName: string; AChain: TStringList): string;
var
  Raw: string;
  NewChain: TStringList;
begin
  Raw := FTemplates.Values[AName];
  Raw := ReplaceTags(Raw, '$$', '$$', @LookupSetting);
  Raw := ReplaceTags(Raw, '??', '??', @LookupConstant);
  NewChain := TStringList.Create;
  try
    NewChain.Assign(AChain);
    NewChain.Add(AName);
    Result := ReplaceChildren(Raw, NewChain);
  finally
    NewChain.Free;
  end;
end;

function TVDRX_TemplateStore.Fill(const ATemplateName: string; AParams: TStringList): string;
var
  Chain: TStringList;
begin
  FLock.Enter;
  try
    if FTemplates.IndexOfName(ATemplateName) < 0 then Exit('');
    Chain := TStringList.Create;
    try
      Result := FillRecursive(ATemplateName, Chain);
    finally
      Chain.Free;
    end;
  finally
    FLock.Leave;
  end;
  Result := ReplaceParams(Result, AParams); // outside FLock - doesn't touch shared state
end;

end.
