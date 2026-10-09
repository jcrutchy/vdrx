unit jsonconf;

{$mode ObjFPC}{$H+}

// jsonconf - generic, self-contained JSON configuration loader.
//
// Depends on nothing but the FPC RTL/FCL (fpjson, jsonparser, Generics.Collections),
// so it can be dropped into any project (vdrx, fem3d, soma, ...) as a single file.
//
// Features
//   1. Recursive "includes": a config file may name other config files in a
//      top-level "includes" array; they're merged underneath the including file
//      (arrays accumulate, the including file's scalars win). Include paths are
//      resolved relative to the file that names them.
//   2. Variables: a top-level "variables" object declares user variables, and
//      {NAME} references to them (or to automatic/reserved variables, or to
//      environment variables as {ENV:NAME}) are expanded in EVERY string key
//      and string value in the merged config - including inside include paths,
//      inside other variables' names, and inside other variables' values.
//   3. Safe reload: Reload builds the whole new config on the side. If anything
//      is wrong (parse error, undefined variable, circular reference, ...) the
//      previously loaded config stays in force and the problems are available
//      from LastErrors.
//
// Reference syntax (single braces, case-sensitive names)
//   {NAME}              user-declared or reserved variable
//   {ENV:NAME}          environment variable (error if unset/empty)
//   {ENV:NAME:-text}    environment variable, or "text" if unset/empty
//   {PREFIX_{WHICH}}    references nest - inner ones are expanded first
//   {LBRACE} {RBRACE}   a literal "{" / "}" (the escape mechanism)
// A brace pair whose contents are NOT a valid reference (for example JSON text
// such as {"a":1}, or {status,body}) is left alone as literal text. A brace pair
// that IS shaped like a reference but names nothing that exists is an ERROR (so
// typos can't silently survive into a path or command line).
//
// Reserved variables (override RegisterReservedVariables to add your own)
//   PLATFORM            windows | linux | darwin | freebsd | unix | unknown
//   ARCHITECTURE        x86_64 | i386 | aarch64 | arm | ppc64 | unknown
//   PATH_SEPARATOR      directory separator: \ on Windows, / elsewhere
//   PATH_LIST_SEPARATOR separator used inside PATH-style lists: ; or :
//   EXE_EXT             .exe on Windows, empty elsewhere
//   APP_ROOT_PATH       directory containing the running executable
//   APP_BIN_FILENAME    file name of the running executable (with extension)
//   APP_BIN_PATH        full path of the running executable
//   MAIN_CONF_DIR       directory of the top-level config file
//   CONF_DIR            directory of the config file the reference is written in
//   CONF_FILE           file name of the config file the reference is written in
//   LBRACE, RBRACE      literal { and }
// (CONF_DIR/CONF_FILE are substituted per file at load time, so an included
// file's {CONF_DIR} is that included file's own directory.)
//
// "description" keys and any key ending in "_description" are treated as
// documentation: their text is never expanded, so they can freely contain
// examples such as {PHP_BIN_FILENAME}.

interface

uses
  Classes, SysUtils, fpjson, jsonparser, SyncObjs, Generics.Collections;

type
  // One TStringList (Name=Value, scalar fields only; an array of scalars is
  // comma-joined and ALSO kept exactly as JSON text under "<name>#json"; a nested
  // object is stored as its JSON text) per object in a config array. Caller owns
  // the list and its rows.
  TJsonConfRows = specialize TObjectList<TStringList>;
  TJsonConfReserved = specialize TDictionary<string, string>;

  TJsonConf = class
  private
    FData: TJSONObject;
    FLock: TCriticalSection;       // guards FData / FLastErrors
    FReloadLock: TCriticalSection; // serialises Reload calls
    FFilePath: string;
    FReserved: TJsonConfReserved;
    FLastErrors: string;
    function GetLoaded: Boolean;
    function GetLastErrors: string;
    function LoadFile(const AFilePath: string; AVisited: TStringList;
      AInherited: TObject; AErrors: TStringList; AIsTop: Boolean): TJSONObject;
    function ResolveMerged(AMerged: TJSONObject; AErrors: TStringList): TJSONObject;
  protected
    // Called at the start of every Reload (the reserved table is rebuilt each
    // time). Override, call inherited, then SetReservedVariable for your own.
    procedure RegisterReservedVariables; virtual;
    procedure SetReservedVariable(const AName, AValue: string);
  public
    constructor Create(const AFilePath: string);
    destructor Destroy; override;
    function GetString(APath: string; ADefault: string): string;
    function GetInteger(APath: string; ADefault: Integer): Integer;
    function GetBoolean(APath: string; ADefault: Boolean): Boolean;
    function GetStringArray(APath: string): TStringArray;
    function GetObjectArray(APath: string): TJsonConfRows;
    // Re-reads everything. True = the new config is now in force. False = it
    // was rejected (see LastErrors) and the previous config, if any, is still
    // in force.
    function Reload: Boolean;
    property FilePath: string read FFilePath;
    // True once any config has loaded successfully.
    property Loaded: Boolean read GetLoaded;
    // Newline-separated problems from the most recent Reload; '' if it succeeded.
    property LastErrors: string read GetLastErrors;
  end;

implementation

const
  MAX_ERRORS = 50;

// ---------------------------------------------------------------------------
// small helpers
// ---------------------------------------------------------------------------

function IsAbsolutePath(const APath: string): Boolean;
begin
  Result := (Length(APath) > 0) and (APath[1] in ['/', '\'])
    or ((Length(APath) >= 2) and (APath[2] = ':') and (UpCase(APath[1]) in ['A'..'Z']));
end;

function IsDocumentaryKey(const AName: string): Boolean;
begin
  Result := (AName = 'description')
    or ((Length(AName) >= 12) and (Copy(AName, Length(AName) - 11, 12) = '_description'));
end;

function IsValidVarName(const S: string): Boolean;
var
  i: Integer;
begin
  Result := (S <> '') and (S[1] in ['A'..'Z', 'a'..'z', '_']);
  if not Result then Exit;
  for i := 2 to Length(S) do
    if not (S[i] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '.', '-']) then
    begin
      Result := False;
      Exit;
    end;
end;

function IsValidEnvName(const S: string): Boolean;
var
  i: Integer;
begin
  Result := S <> '';
  for i := 1 to Length(S) do
    if S[i] in ['{', '}', '=', ' ', #9, #10, #13, ':'] then
    begin
      Result := False;
      Exit;
    end;
end;

procedure AddUnique(AList: TStringList; const AMsg: string);
begin
  if AList.IndexOf(AMsg) >= 0 then Exit;
  if AList.Count = MAX_ERRORS then
    AList.Add('(further errors not shown)')
  else if AList.Count < MAX_ERRORS then
    AList.Add(AMsg);
end;

// Legacy ${VAR} / ${VAR:-default} environment expansion, applied to a file's
// raw text before it is parsed (kept for backward compatibility - the newer
// {ENV:VAR} form is applied after parsing and so is safe for values such as
// Windows paths whose backslashes would otherwise break the JSON).
function ExpandLegacyEnvVars(const S: string): string;
var
  i, j, k, len, sepPos: Integer;
  VarName, DefaultVal, EnvVal: string;
begin
  Result := '';
  i := 1;
  len := Length(S);
  while i <= len do
  begin
    if (S[i] = '$') and (i < len) and (S[i + 1] = '{') then
    begin
      j := i + 2;
      k := j;
      while (k <= len) and (S[k] <> '}') do Inc(k);
      if k <= len then
      begin
        VarName := Copy(S, j, k - j);
        DefaultVal := '';
        sepPos := Pos(':-', VarName);
        if sepPos > 0 then
        begin
          DefaultVal := Copy(VarName, sepPos + 2, Length(VarName) - sepPos - 1);
          VarName := Copy(VarName, 1, sepPos - 1);
        end;
        EnvVal := GetEnvironmentVariable(VarName);
        if (EnvVal = '') and (sepPos > 0) then
          EnvVal := DefaultVal;
        Result := Result + EnvVal;
        i := k + 1;
        Continue;
      end;
    end;
    Result := Result + S[i];
    Inc(i);
  end;
end;

// Recursively merges ASource's keys into ATarget; ATarget wins every tiebreak.
//   object + object -> recurse
//   array  + array  -> concatenate (ATarget's elements first)
//   anything else   -> ATarget's value stays; ASource's is only used if
//                      ATarget has no such key
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
  end;
end;

// ---------------------------------------------------------------------------
// raw (unexpanded) variable declarations, passed down the include chain
// ---------------------------------------------------------------------------

type
  TRawVars = class
  public
    Names: TStringList;
    Values: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure Add(const AName, AValue: string); // first declaration wins
  end;

constructor TRawVars.Create;
begin
  Names := TStringList.Create;
  Names.CaseSensitive := True;
  Values := TStringList.Create;
end;

destructor TRawVars.Destroy;
begin
  Names.Free;
  Values.Free;
  inherited;
end;

procedure TRawVars.Add(const AName, AValue: string);
begin
  if Names.IndexOf(AName) >= 0 then Exit;
  Names.Add(AName);
  Values.Add(AValue);
end;

// Reads the "variables" object (if any) out of AObj into AList.
procedure CollectVariables(AObj: TJSONObject; const AWhere: string;
  AList: TRawVars; AErrors: TStringList);
var
  Node: TJSONData;
  VarsObj: TJSONObject;
  i: Integer;
begin
  Node := AObj.Find('variables');
  if Node = nil then Exit;
  if not (Node is TJSONObject) then
  begin
    AddUnique(AErrors, AWhere + ': "variables" must be a JSON object');
    Exit;
  end;
  VarsObj := TJSONObject(Node);
  for i := 0 to VarsObj.Count - 1 do
    if VarsObj.Items[i].JSONType in [jtString, jtNumber, jtBoolean] then
      AList.Add(VarsObj.Names[i], VarsObj.Items[i].AsString)
    else
      AddUnique(AErrors, AWhere + ': variables.' + VarsObj.Names[i]
        + ' must be a string, number or boolean');
end;

// ---------------------------------------------------------------------------
// tree rewriting (expands every string key and value)
// ---------------------------------------------------------------------------

type
  TStringRewriter = class
  protected
    FErrors: TStringList; // not owned
  public
    constructor Create(AErrors: TStringList);
    procedure AddError(const AWhere, AMsg: string);
    function Rewrite(const S, APath: string): string; virtual; abstract;
  end;

constructor TStringRewriter.Create(AErrors: TStringList);
begin
  inherited Create;
  FErrors := AErrors;
end;

procedure TStringRewriter.AddError(const AWhere, AMsg: string);
begin
  if AWhere <> '' then
    AddUnique(FErrors, AWhere + ': ' + AMsg)
  else
    AddUnique(FErrors, AMsg);
end;

// Returns a NEW tree (ANode is untouched). ASkipRootKey, if non-empty, drops
// that key from the root object. Documentation keys are copied verbatim.
function RewriteTree(ANode: TJSONData; ARw: TStringRewriter; const APath: string;
  const ASkipRootKey: string = ''): TJSONData;
var
  i: Integer;
  Obj: TJSONObject;
  Arr: TJSONArray;
  OldKey, NewKey, ChildPath: string;
begin
  case ANode.JSONType of
    jtString:
      Result := TJSONString.Create(ARw.Rewrite(ANode.AsString, APath));
    jtObject:
      begin
        Obj := TJSONObject.Create;
        Result := Obj;
        for i := 0 to TJSONObject(ANode).Count - 1 do
        begin
          OldKey := TJSONObject(ANode).Names[i];
          if (APath = '') and (ASkipRootKey <> '') and (OldKey = ASkipRootKey) then Continue;
          if APath = '' then ChildPath := OldKey else ChildPath := APath + '.' + OldKey;
          if IsDocumentaryKey(OldKey) then
            Obj.Add(OldKey, TJSONObject(ANode).Items[i].Clone)
          else
          begin
            NewKey := ARw.Rewrite(OldKey, ChildPath + ' (key)');
            if Obj.IndexOfName(NewKey) >= 0 then
            begin
              ARw.AddError(ChildPath, 'key expands to "' + NewKey + '", which duplicates another key in the same object');
              Continue;
            end;
            Obj.Add(NewKey, RewriteTree(TJSONObject(ANode).Items[i], ARw, ChildPath));
          end;
        end;
      end;
    jtArray:
      begin
        Arr := TJSONArray.Create;
        Result := Arr;
        for i := 0 to TJSONArray(ANode).Count - 1 do
          Arr.Add(RewriteTree(TJSONArray(ANode).Items[i], ARw, APath + '[' + IntToStr(i) + ']'));
      end;
  else
    Result := ANode.Clone;
  end;
end;

// Stage 1, applied to each file as it is loaded: substitutes only the
// per-file variables CONF_DIR / CONF_FILE.
type
  TFileLocalRewriter = class(TStringRewriter)
  private
    FDir, FFile: string;
  public
    constructor Create(AErrors: TStringList; const ADir, AFile: string);
    function Rewrite(const S, APath: string): string; override;
  end;

constructor TFileLocalRewriter.Create(AErrors: TStringList; const ADir, AFile: string);
begin
  inherited Create(AErrors);
  FDir := ADir;
  FFile := AFile;
end;

function TFileLocalRewriter.Rewrite(const S, APath: string): string;
begin
  Result := S;
  if Pos('{CONF_', Result) = 0 then Exit;
  Result := StringReplace(Result, '{CONF_DIR}', FDir, [rfReplaceAll]);
  Result := StringReplace(Result, '{CONF_FILE}', FFile, [rfReplaceAll]);
end;

// ---------------------------------------------------------------------------
// the variable resolver
// ---------------------------------------------------------------------------

type
  TVarEntry = record
    RawName, RawValue: string;
    Name, Value: string;
    NameState: Byte;  // 0 = unresolved, 1 = resolving, 2 = done, 3 = failed
    ValueState: Byte; // 0 = unresolved, 1 = resolving, 2 = done
  end;

  TVarResolver = class(TStringRewriter)
  private
    FReserved: TJsonConfReserved; // not owned
    FVars: array of TVarEntry;
    FStack: TStringList;          // names of variables whose VALUE is being resolved
    FCtx: string;
    function GetCount: Integer;
    function GetName(AIndex: Integer): string;
    function GetValue(AIndex: Integer): string;
    function IsReference(const ABody: string): Boolean;
    function ResolveReference(const ABody: string; out AValue: string): Boolean;
    function ResolveEnv(const ABody: string; out AValue: string): Boolean;
    function LookupVar(const AName: string; out AValue: string): Boolean;
    procedure ResolveName(AIndex: Integer);
    function ResolveValue(AIndex: Integer): string;
    function Expand(const S: string): string;
    function NameTaken(const AName: string; AExceptIndex: Integer): Boolean;
  public
    constructor Create(AReserved: TJsonConfReserved; AErrors: TStringList);
    destructor Destroy; override;
    procedure AddVar(const ARawName, ARawValue: string);
    procedure ResolveAll;
    function Rewrite(const S, APath: string): string; override;
    property Count: Integer read GetCount;
    property Names[AIndex: Integer]: string read GetName;
    property Values[AIndex: Integer]: string read GetValue;
  end;

constructor TVarResolver.Create(AReserved: TJsonConfReserved; AErrors: TStringList);
begin
  inherited Create(AErrors);
  FReserved := AReserved;
  FStack := TStringList.Create;
end;

destructor TVarResolver.Destroy;
begin
  FStack.Free;
  inherited;
end;

function TVarResolver.GetCount: Integer;
begin
  Result := Length(FVars);
end;

function TVarResolver.GetName(AIndex: Integer): string;
begin
  Result := FVars[AIndex].Name;
end;

function TVarResolver.GetValue(AIndex: Integer): string;
begin
  Result := FVars[AIndex].Value;
end;

function TVarResolver.NameTaken(const AName: string; AExceptIndex: Integer): Boolean;
var
  i: Integer;
  Dummy: string;
begin
  Result := FReserved.TryGetValue(AName, Dummy);
  if Result then Exit;
  for i := 0 to High(FVars) do
    if (i <> AExceptIndex) and (FVars[i].NameState = 2) and (FVars[i].Name = AName) then
    begin
      Result := True;
      Exit;
    end;
end;

procedure TVarResolver.AddVar(const ARawName, ARawValue: string);
var
  n: Integer;
  Dummy: string;
begin
  n := Length(FVars);
  SetLength(FVars, n + 1);
  FVars[n].RawName := ARawName;
  FVars[n].RawValue := ARawValue;
  FVars[n].Name := '';
  FVars[n].Value := '';
  FVars[n].NameState := 0;
  FVars[n].ValueState := 0;
  if Pos('{', ARawName) = 0 then
  begin
    // a plain literal name - settled immediately
    if not IsValidVarName(ARawName) then
    begin
      FVars[n].NameState := 3;
      AddError('variables.' + ARawName, 'invalid variable name (use letters, digits, "_", "." and "-", starting with a letter or "_")');
    end
    else if FReserved.TryGetValue(ARawName, Dummy) then
    begin
      FVars[n].NameState := 3;
      AddError('variables.' + ARawName, 'this name is reserved and cannot be redeclared');
    end
    else
    begin
      FVars[n].Name := ARawName;
      FVars[n].NameState := 2;
    end;
  end;
end;

// A variable whose declared NAME contains references (e.g. "{PREFIX}_HOME").
procedure TVarResolver.ResolveName(AIndex: Integer);
var
  Saved, Nm: string;
begin
  if FVars[AIndex].NameState <> 0 then Exit;
  FVars[AIndex].NameState := 1;
  Saved := FCtx;
  FCtx := 'variables.' + FVars[AIndex].RawName + ' (name)';
  Nm := Expand(FVars[AIndex].RawName);
  if not IsValidVarName(Nm) then
  begin
    AddError(FCtx, 'name expands to "' + Nm + '", which is not a valid variable name');
    FVars[AIndex].NameState := 3;
  end
  else if NameTaken(Nm, AIndex) then
  begin
    AddError(FCtx, 'name expands to "' + Nm + '", which is already declared or reserved');
    FVars[AIndex].NameState := 3;
  end
  else
  begin
    FVars[AIndex].Name := Nm;
    FVars[AIndex].NameState := 2;
  end;
  FCtx := Saved;
end;

function TVarResolver.ResolveValue(AIndex: Integer): string;
var
  Saved, Chain: string;
  p, i: Integer;
begin
  case FVars[AIndex].ValueState of
    2: Result := FVars[AIndex].Value;
    1:
      begin
        // already being resolved further up the call chain -> circular
        p := FStack.IndexOf(FVars[AIndex].Name);
        Chain := '';
        for i := p to FStack.Count - 1 do
          Chain := Chain + FStack[i] + ' -> ';
        Chain := Chain + FVars[AIndex].Name;
        AddError('variables.' + FVars[AIndex].Name, 'circular variable reference: ' + Chain);
        Result := '';
      end;
  else
    begin
      FVars[AIndex].ValueState := 1;
      FStack.Add(FVars[AIndex].Name);
      Saved := FCtx;
      FCtx := 'variables.' + FVars[AIndex].Name;
      FVars[AIndex].Value := Expand(FVars[AIndex].RawValue);
      FCtx := Saved;
      FStack.Delete(FStack.Count - 1);
      FVars[AIndex].ValueState := 2;
      Result := FVars[AIndex].Value;
    end;
  end;
end;

procedure TVarResolver.ResolveAll;
var
  i: Integer;
begin
  for i := 0 to High(FVars) do ResolveName(i);
  for i := 0 to High(FVars) do
    if FVars[i].NameState = 2 then ResolveValue(i);
end;

function TVarResolver.LookupVar(const AName: string; out AValue: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  AValue := '';
  for i := 0 to High(FVars) do
    if (FVars[i].NameState = 2) and (FVars[i].Name = AName) then
    begin
      AValue := ResolveValue(i);
      Result := True;
      Exit;
    end;
  // not a plain-named variable: maybe one whose declared name is itself templated
  for i := 0 to High(FVars) do
    if FVars[i].NameState = 0 then
    begin
      ResolveName(i);
      if (FVars[i].NameState = 2) and (FVars[i].Name = AName) then
      begin
        AValue := ResolveValue(i);
        Result := True;
        Exit;
      end;
    end;
end;

function TVarResolver.IsReference(const ABody: string): Boolean;
var
  Rest: string;
  p: Integer;
begin
  if Copy(ABody, 1, 4) = 'ENV:' then
  begin
    Rest := Copy(ABody, 5, MaxInt);
    p := Pos(':-', Rest);
    if p > 0 then Rest := Copy(Rest, 1, p - 1);
    Result := IsValidEnvName(Rest);
  end
  else
    Result := IsValidVarName(ABody);
end;

function TVarResolver.ResolveEnv(const ABody: string; out AValue: string): Boolean;
var
  Rest, EnvName, DefaultVal: string;
  p: Integer;
  HasDefault: Boolean;
begin
  Rest := Copy(ABody, 5, MaxInt);
  p := Pos(':-', Rest);
  HasDefault := p > 0;
  if HasDefault then
  begin
    EnvName := Copy(Rest, 1, p - 1);
    DefaultVal := Copy(Rest, p + 2, MaxInt);
  end
  else
  begin
    EnvName := Rest;
    DefaultVal := '';
  end;
  AValue := GetEnvironmentVariable(EnvName);
  if AValue = '' then
  begin
    if HasDefault then
      AValue := DefaultVal
    else
    begin
      AddError(FCtx, 'environment variable "' + EnvName + '" is not set (write {ENV:' + EnvName + ':-default} to allow that)');
      Result := False;
      Exit;
    end;
  end;
  Result := True;
end;

function TVarResolver.ResolveReference(const ABody: string; out AValue: string): Boolean;
begin
  AValue := '';
  if Copy(ABody, 1, 4) = 'ENV:' then
    Result := ResolveEnv(ABody, AValue)
  else if FReserved.TryGetValue(ABody, AValue) then
    Result := True
  else if LookupVar(ABody, AValue) then
    Result := True
  else
  begin
    AddError(FCtx, 'undefined variable {' + ABody + '}');
    Result := False;
  end;
end;

// Expands every {reference} in S. Nested references are expanded inner-first.
// The expansion of a reference is inserted as-is (it is never re-scanned).
function TVarResolver.Expand(const S: string): string;
var
  i, j, depth, len: Integer;
  Body, Val: string;
begin
  Result := '';
  len := Length(S);
  i := 1;
  while i <= len do
  begin
    if S[i] = '{' then
    begin
      depth := 1;
      j := i + 1;
      while (j <= len) and (depth > 0) do
      begin
        if S[j] = '{' then Inc(depth)
        else if S[j] = '}' then Dec(depth);
        Inc(j);
      end;
      if depth = 0 then
      begin
        // S[i] is "{", S[j-1] is its matching "}"
        Body := Expand(Copy(S, i + 1, j - i - 2));
        if IsReference(Body) then
        begin
          if ResolveReference(Body, Val) then
            Result := Result + Val;
        end
        else
          Result := Result + '{' + Body + '}'; // not a reference - literal text
        i := j;
        Continue;
      end;
    end;
    Result := Result + S[i];
    Inc(i);
  end;
end;

function TVarResolver.Rewrite(const S, APath: string): string;
begin
  if Pos('{', S) = 0 then
  begin
    Result := S;
    Exit;
  end;
  FCtx := APath;
  Result := Expand(S);
end;

// ---------------------------------------------------------------------------
// TJsonConf
// ---------------------------------------------------------------------------

constructor TJsonConf.Create(const AFilePath: string);
begin
  inherited Create;
  FFilePath := AFilePath;
  FLock := TCriticalSection.Create;
  FReloadLock := TCriticalSection.Create;
  FReserved := TJsonConfReserved.Create;
  Reload;
end;

destructor TJsonConf.Destroy;
begin
  FData.Free;
  FReserved.Free;
  FReloadLock.Free;
  FLock.Free;
  inherited;
end;

procedure TJsonConf.SetReservedVariable(const AName, AValue: string);
begin
  FReserved.AddOrSetValue(AName, AValue);
end;

procedure TJsonConf.RegisterReservedVariables;
var
  ExePath: string;
begin
  ExePath := ExpandFileName(ParamStr(0));
  {$IFDEF MSWINDOWS}
  SetReservedVariable('PLATFORM', 'windows');
  SetReservedVariable('EXE_EXT', '.exe');
  {$ELSE}
    {$IFDEF LINUX}
    SetReservedVariable('PLATFORM', 'linux');
    {$ELSE}
      {$IFDEF DARWIN}
      SetReservedVariable('PLATFORM', 'darwin');
      {$ELSE}
        {$IFDEF FREEBSD}
        SetReservedVariable('PLATFORM', 'freebsd');
        {$ELSE}
          {$IFDEF UNIX}
          SetReservedVariable('PLATFORM', 'unix');
          {$ELSE}
          SetReservedVariable('PLATFORM', 'unknown');
          {$ENDIF}
        {$ENDIF}
      {$ENDIF}
    {$ENDIF}
  SetReservedVariable('EXE_EXT', '');
  {$ENDIF}
  {$IFDEF CPUX86_64}
  SetReservedVariable('ARCHITECTURE', 'x86_64');
  {$ELSE}
    {$IFDEF CPUI386}
    SetReservedVariable('ARCHITECTURE', 'i386');
    {$ELSE}
      {$IFDEF CPUAARCH64}
      SetReservedVariable('ARCHITECTURE', 'aarch64');
      {$ELSE}
        {$IFDEF CPUARM}
        SetReservedVariable('ARCHITECTURE', 'arm');
        {$ELSE}
          {$IFDEF CPUPOWERPC64}
          SetReservedVariable('ARCHITECTURE', 'ppc64');
          {$ELSE}
          SetReservedVariable('ARCHITECTURE', 'unknown');
          {$ENDIF}
        {$ENDIF}
      {$ENDIF}
    {$ENDIF}
  {$ENDIF}
  SetReservedVariable('PATH_SEPARATOR', DirectorySeparator);
  SetReservedVariable('PATH_LIST_SEPARATOR', PathSeparator);
  SetReservedVariable('APP_ROOT_PATH', ExtractFileDir(ExePath));
  SetReservedVariable('APP_BIN_FILENAME', ExtractFileName(ExePath));
  SetReservedVariable('APP_BIN_PATH', ExePath);
  SetReservedVariable('MAIN_CONF_DIR', ExtractFileDir(ExpandFileName(FFilePath)));
  SetReservedVariable('LBRACE', '{');
  SetReservedVariable('RBRACE', '}');
end;

// Loads one file (stage 1: parse + per-file CONF_DIR/CONF_FILE substitution),
// then recursively loads and merges its includes underneath it. AInherited is
// a TRawVars of the variables declared by the files above this one in the
// include chain (they win over this file's own, and are what include PATHS may
// reference - a path can't depend on a variable declared in a file that is
// itself only reached via that path).
function TJsonConf.LoadFile(const AFilePath: string; AVisited: TStringList;
  AInherited: TObject; AErrors: TStringList; AIsTop: Boolean): TJSONObject;
var
  AbsPath, Txt, IncludePath: string;
  Lines: TStringList;
  Parsed: TJSONData;
  Rebuilt: TJSONData;
  Rw: TFileLocalRewriter;
  IncludesNode: TJSONData;
  Ctx: TRawVars;
  Rv: TVarResolver;
  Child: TJSONObject;
  i, ErrCount: Integer;
begin
  Result := nil;
  AbsPath := ExpandFileName(AFilePath);
  if AVisited.IndexOf(AbsPath) >= 0 then
  begin
    WriteLn(StdErr, 'jsonconf: "', AbsPath, '" already loaded on this include chain - skipping repeat/cycle.');
    Exit;
  end;
  AVisited.Add(AbsPath);

  if not FileExists(AbsPath) then
  begin
    if AIsTop then
      AddUnique(AErrors, AbsPath + ': config file not found')
    else
      WriteLn(StdErr, 'jsonconf: included file not found: ', AbsPath);
    Exit;
  end;

  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(AbsPath);
    except
      on E: Exception do
      begin
        AddUnique(AErrors, AbsPath + ': cannot read file - ' + E.Message);
        Exit;
      end;
    end;
    Txt := Lines.Text;
  finally
    Lines.Free;
  end;
  if Copy(Txt, 1, 3) = #$EF#$BB#$BF then Delete(Txt, 1, 3);
  Txt := ExpandLegacyEnvVars(Txt);

  try
    Parsed := GetJSON(Txt);
  except
    on E: Exception do
    begin
      AddUnique(AErrors, AbsPath + ': JSON parse error - ' + E.Message);
      Exit;
    end;
  end;
  if not (Parsed is TJSONObject) then
  begin
    AddUnique(AErrors, AbsPath + ': top level must be a JSON object');
    Parsed.Free;
    Exit;
  end;

  Rw := TFileLocalRewriter.Create(AErrors, ExtractFileDir(AbsPath), ExtractFileName(AbsPath));
  try
    Rebuilt := RewriteTree(Parsed, Rw, '');
  finally
    Rw.Free;
    Parsed.Free;
  end;
  Result := TJSONObject(Rebuilt);

  IncludesNode := Result.Find('includes');
  if IncludesNode = nil then Exit;

  if IncludesNode is TJSONArray then
  begin
    Ctx := TRawVars.Create;
    try
      if Assigned(AInherited) then
        for i := 0 to TRawVars(AInherited).Names.Count - 1 do
          Ctx.Add(TRawVars(AInherited).Names[i], TRawVars(AInherited).Values[i]);
      CollectVariables(Result, AbsPath, Ctx, AErrors);

      Rv := TVarResolver.Create(FReserved, AErrors);
      try
        for i := 0 to Ctx.Names.Count - 1 do
          Rv.AddVar(Ctx.Names[i], Ctx.Values[i]);

        for i := 0 to TJSONArray(IncludesNode).Count - 1 do
        begin
          if not (TJSONArray(IncludesNode)[i].JSONType in [jtString, jtNumber, jtBoolean]) then Continue;
          IncludePath := TJSONArray(IncludesNode)[i].AsString;
          if IncludePath = '' then Continue;
          ErrCount := AErrors.Count;
          IncludePath := Rv.Rewrite(IncludePath, AbsPath + ': includes[' + IntToStr(i) + ']');
          if AErrors.Count > ErrCount then Continue; // couldn't expand the path - already reported
          if not IsAbsolutePath(IncludePath) then
            IncludePath := IncludeTrailingPathDelimiter(ExtractFileDir(AbsPath)) + IncludePath;
          Child := LoadFile(IncludePath, AVisited, Ctx, AErrors, False);
          if Assigned(Child) then
          begin
            try
              DeepMergeInto(Result, Child);
            finally
              Child.Free;
            end;
          end;
        end;
      finally
        Rv.Free;
      end;
    finally
      Ctx.Free;
    end;
  end;
  Result.Delete('includes');
end;

// Stage 2, on the fully merged tree: resolve every declared variable (finding
// circular references), then expand every remaining string key/value. Returns
// a new tree, or nil if anything was reported to AErrors.
function TJsonConf.ResolveMerged(AMerged: TJSONObject; AErrors: TStringList): TJSONObject;
var
  Raw: TRawVars;
  Rv: TVarResolver;
  Expanded: TJSONData;
  VarsOut: TJSONObject;
  HadVars: Boolean;
  i, StartErrors: Integer;
begin
  Result := nil;
  StartErrors := AErrors.Count;
  Raw := TRawVars.Create;
  Rv := TVarResolver.Create(FReserved, AErrors);
  try
    CollectVariables(AMerged, 'variables', Raw, AErrors);
    HadVars := AMerged.Find('variables') <> nil;
    for i := 0 to Raw.Names.Count - 1 do
      Rv.AddVar(Raw.Names[i], Raw.Values[i]);
    Rv.ResolveAll;

    Expanded := RewriteTree(AMerged, Rv, '', 'variables');
    if AErrors.Count > StartErrors then
    begin
      Expanded.Free;
      Exit;
    end;
    Result := TJSONObject(Expanded);

    if HadVars then
    begin
      // expose the resolved variables as config values too, e.g.
      // GetString('variables.ADMIN_EMAIL_ADDRESS', '')
      VarsOut := TJSONObject.Create;
      for i := 0 to Rv.Count - 1 do
        if Rv.Names[i] <> '' then
          VarsOut.Add(Rv.Names[i], TJSONString.Create(Rv.Values[i]));
      Result.Add('variables', VarsOut);
    end;
  finally
    Rv.Free;
    Raw.Free;
  end;
end;

function TJsonConf.Reload: Boolean;
var
  Errors, Visited: TStringList;
  Merged, Final: TJSONObject;
begin
  Result := False;
  FReloadLock.Enter;
  try
    Errors := TStringList.Create;
    Visited := TStringList.Create;
    try
      Visited.Sorted := True;
      Visited.Duplicates := dupIgnore;
      FReserved.Clear;
      RegisterReservedVariables;

      Final := nil;
      Merged := LoadFile(FFilePath, Visited, nil, Errors, True);
      try
        if Assigned(Merged) and (Errors.Count = 0) then
          Final := ResolveMerged(Merged, Errors);
      finally
        Merged.Free;
      end;

      if (Errors.Count = 0) and Assigned(Final) then
      begin
        FLock.Enter;
        try
          FData.Free;
          FData := Final;
          FLastErrors := '';
        finally
          FLock.Leave;
        end;
        Result := True;
      end
      else
      begin
        Final.Free;
        if Errors.Count = 0 then Errors.Add(FFilePath + ': could not be loaded');
        FLock.Enter;
        try
          FLastErrors := Trim(Errors.Text);
        finally
          FLock.Leave;
        end;
      end;
    finally
      Visited.Free;
      Errors.Free;
    end;
  finally
    FReloadLock.Leave;
  end;
end;

function TJsonConf.GetLoaded: Boolean;
begin
  FLock.Enter;
  try
    Result := Assigned(FData);
  finally
    FLock.Leave;
  end;
end;

function TJsonConf.GetLastErrors: string;
begin
  FLock.Enter;
  try
    Result := FLastErrors;
  finally
    FLock.Leave;
  end;
end;

function TJsonConf.GetString(APath: string; ADefault: string): string;
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

function TJsonConf.GetInteger(APath: string; ADefault: Integer): Integer;
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

function TJsonConf.GetBoolean(APath: string; ADefault: Boolean): Boolean;
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

function TJsonConf.GetStringArray(APath: string): TStringArray;
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
// "a.>,b.*". Non-scalar elements are skipped.
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

// Builds the whole result INSIDE the lock and returns caller-owned copies, so a
// concurrent Reload can never free what the caller is iterating.
function TJsonConf.GetObjectArray(APath: string): TJsonConfRows;
var
  Node: TJSONData;
  Arr: TJSONArray;
  i, j: Integer;
  Obj: TJSONObject;
  Row: TStringList;
begin
  Result := TJsonConfRows.Create;
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
          begin
            Row.Values[Obj.Names[j]] := JoinJSONStringArray(TJSONArray(Obj.Items[j]));
            // the comma-joined form loses element boundaries (an argument that
            // contains a comma, say), so the exact JSON is kept alongside it
            Row.Values[Obj.Names[j] + '#json'] := Obj.Items[j].AsJSON;
          end
          else if Obj.Items[j].JSONType = jtObject then
            Row.Values[Obj.Names[j]] := Obj.Items[j].AsJSON;
        Result.Add(Row);
      end;
  finally
    FLock.Leave;
  end;
end;

end.
