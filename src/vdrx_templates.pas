unit vdrx_templates;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, SyncObjs, Generics.Collections, fpjson, jsonparser, vdrx_core, vdrx_config;

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
  //
  // ATemplateDir is resolved to an ABSOLUTE path once, at Create time (via
  // ExpandFileName against the process's CWD at that moment), and FDir keeps
  // that absolute form from then on - not because relative paths don't work
  // (they do, resolved the same way any other relative config path is), but
  // so every diagnostic this unit ever logs can name the exact, unambiguous
  // file it looked for. In a setup with several independently-configured
  // scripts and sites, "templates/greeting.tpl not found" leaves you
  // guessing which of several plausible working directories that was
  // relative to; "C:\dev\vdrx\templates\greeting.tpl not found" doesn't -
  // see the public Dir property, used by RunBusCLIScript's own error
  // messages in vdrx_network.pas for the same reason.
  TVDRX_TemplateStore = class
  private
    FLock: TCriticalSection;
    FTemplates: TStringList; // Name=Value cache; Value = raw file content (or '' if the file didn't exist - cached too, so a bad name doesn't re-stat every request)
    FConstants: TStringList; // Name=Value, set via SetConstant
    FConfig: TVDRX_Config;
    FDir: string; // always absolute - see unit comment above
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
    // The absolute directory this store loads '<name>.tpl' files from - for
    // callers (RunBusCLIScript's diagnostics, an admin/debug page, etc.)
    // that want to report exactly where a template was or wasn't found,
    // rather than just the bare name that failed.
    property Dir: string read FDir;
  end;

// Flattens a JSON object's scalar members into a Name=Value TStringList -
// the shape Fill's AParams expects. Shared (declared once here, used by both
// vdrx_templates.pas's own TVDRX_TemplateExecutive and vdrx_network.pas's
// BuildBusCLIResponse) so the "which JSON value types count as a usable
// param" rule can't drift between the two call sites. Non-scalar members
// (nested objects/arrays) are skipped; AParamsObj may be nil (empty
// result). Caller owns and frees the result.
function JSONParamsToStringList(AParamsObj: TJSONObject): TStringList;

// Converts a JSON "rows" object - {"loopName": [{...row fields...}, ...],
// ...} - into the TVDRX_TemplateNamedRows shape Fill's ARows expects for
// ##loop:loopName##...##endloop## blocks. Only scalar fields within each
// row object are kept. Non-array values under a loop name, or non-object
// entries within one, are silently skipped rather than raising - a
// malformed "rows" value from a buggy caller should render that loop as
// empty, not fail the whole response. ARowsObj may be nil (empty result).
// Caller owns and frees the result (it owns its TVDRX_TemplateRows values
// too, via doOwnsValues).
function JSONRowsToTemplateRows(ARowsObj: TJSONObject): TVDRX_TemplateNamedRows;

type
  // Makes a TVDRX_TemplateStore reachable purely over the bus - the
  // "protocol executive" half of the connectivity/protocol split described
  // in the readme's §2: an HTTP site's own template_dir is still perfectly
  // fine for simple cases (a bus-CLI reply's plain "template" field renders
  // in-process, no bus round trip - see BuildBusCLIResponse in
  // vdrx_network.pas), but anything that wants to name a SPECIFIC template
  // set explicitly, regardless of which HTTP site's connection happens to
  // be asking, publishes a render request to this executive's own
  // subscribed topic instead (a bus-CLI reply's "template_topic" field -
  // same file, same function).
  //
  // Wire format, matching every other bus-mediated request/reply pair in
  // this codebase (RunBusCLIScript's envelope, TVDRX_OneShotWaiter's
  // contract):
  //   in:  {"template":"name","params":{...},"rows":{...},"reply_to":"..."}
  //   out (published to "reply_to"): {"body":"<rendered text>"}
  // A missing/unresolvable "template" name still replies (with an empty
  // "body") rather than staying silent - see HandlePacket - since a silent
  // non-reply is indistinguishable from "this executive isn't running at
  // all" to whatever's waiting on PublishAndWait's timeout, and the
  // distinction (misconfigured template name vs. nothing subscribed at all)
  // is worth being able to tell apart from the caller's own log line.
  TVDRX_TemplateExecutive = class(TVDRX_Executive)
  private
    FStore: TVDRX_TemplateStore;
  public
    constructor Create(ABus: TVDRX_MessageQueue; AStore: TVDRX_TemplateStore); reintroduce;
    destructor Destroy; override;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    property Store: TVDRX_TemplateStore read FStore;
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
  FDir := ExpandFileName(ATemplateDir); // absolute from here on - see unit comment
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

function JSONParamsToStringList(AParamsObj: TJSONObject): TStringList;
var
  i: Integer;
begin
  Result := TStringList.Create;
  if not Assigned(AParamsObj) then Exit;
  for i := 0 to AParamsObj.Count - 1 do
    if AParamsObj.Items[i].JSONType in [jtString, jtNumber, jtBoolean] then
      Result.Values[AParamsObj.Names[i]] := AParamsObj.Items[i].AsString;
end;

function JSONRowsToTemplateRows(ARowsObj: TJSONObject): TVDRX_TemplateNamedRows;
var
  i, j, k: Integer;
  Arr: TJSONArray;
  RowObj: TJSONObject;
  Rows: TVDRX_TemplateRows;
  Row: TStringList;
begin
  Result := TVDRX_TemplateNamedRows.Create([doOwnsValues]);
  if not Assigned(ARowsObj) then Exit;
  for i := 0 to ARowsObj.Count - 1 do
  begin
    if ARowsObj.Items[i].JSONType <> jtArray then Continue;
    Arr := TJSONArray(ARowsObj.Items[i]);
    Rows := TVDRX_TemplateRows.Create(True);
    for j := 0 to Arr.Count - 1 do
    begin
      if not (Arr[j] is TJSONObject) then Continue;
      RowObj := TJSONObject(Arr[j]);
      Row := TStringList.Create;
      for k := 0 to RowObj.Count - 1 do
        if RowObj.Items[k].JSONType in [jtString, jtNumber, jtBoolean] then
          Row.Values[RowObj.Names[k]] := RowObj.Items[k].AsString;
      Rows.Add(Row);
    end;
    Result.Add(ARowsObj.Names[i], Rows);
  end;
end;

{ TVDRX_TemplateExecutive }

constructor TVDRX_TemplateExecutive.Create(ABus: TVDRX_MessageQueue; AStore: TVDRX_TemplateStore);
begin
  inherited Create(ABus);
  FStore := AStore;
end;

destructor TVDRX_TemplateExecutive.Destroy;
begin
  FStore.Free; // this executive owns the store it was handed - see SetupTemplateExecutives in vdrx.lpr, which creates one store per config entry specifically to hand off here
  inherited;
end;

// See this class's declaration comment for the wire format. Always publishes
// SOME reply if "reply_to" was present, even on a bad/missing template name
// (an empty "body") - a caller waiting via PublishAndWait needs to be able
// to tell "this executive answered, but the name was wrong" apart from "no
// timeout, but also no reply because nothing's listening at all here".
procedure TVDRX_TemplateExecutive.HandlePacket(const AMsg: TVDRX_Message);
var
  J: TJSONData;
  Obj: TJSONObject;
  TemplateName, ReplyTo, Body: string;
  Params: TStringList;
  Rows: TVDRX_TemplateNamedRows;
begin
  J := nil;
  try
    try J := GetJSON(AMsg.Payload); except J := nil; end;
    if not Assigned(J) or not (J is TJSONObject) then
    begin
      Bus.Publish('log.warn', 'template ' + ID + ': dropped non-JSON-object render request: ' + AMsg.Payload, ID);
      Exit;
    end;
    Obj := TJSONObject(J);
    ReplyTo := Obj.Get('reply_to', '');
    if ReplyTo = '' then
    begin
      Bus.Publish('log.warn', 'template ' + ID + ': render request had no "reply_to" - dropped: ' + AMsg.Payload, ID);
      Exit;
    end;

    TemplateName := Obj.Get('template', '');
    if Assigned(Obj.Find('params')) and (Obj.Find('params') is TJSONObject) then
      Params := JSONParamsToStringList(TJSONObject(Obj.Find('params')))
    else
      Params := JSONParamsToStringList(nil);
    try
      if Assigned(Obj.Find('rows')) and (Obj.Find('rows') is TJSONObject) then
        Rows := JSONRowsToTemplateRows(TJSONObject(Obj.Find('rows')))
      else
        Rows := JSONRowsToTemplateRows(nil);
      try
        Body := FStore.Fill(TemplateName, Params, Rows);
      finally
        Rows.Free;
      end;
    finally
      Params.Free;
    end;

    if Body = '' then
      Bus.Publish('log.warn', Format('template %s: "%s" not found or rendered empty - looked for %s', [ID, TemplateName, IncludeTrailingPathDelimiter(FStore.Dir) + TemplateName + '.tpl']), ID);

    Bus.Publish(ReplyTo, Format('{"body":%s}', [JSONString(Body)]), ID);
  finally
    if Assigned(J) then J.Free;
  end;
end;

end.