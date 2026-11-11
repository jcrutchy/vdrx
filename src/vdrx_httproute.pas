unit vdrx_httproute;

{$mode ObjFPC}{$H+}

// HTTP request handling above the parser: static file serving, reverse proxy, CGI/bus route 
// resolution, request envelopes and reply building.

interface

uses
  Classes, SysUtils, StrUtils, SyncObjs, openssl, {$IFDEF UNIX}BaseUnix, {$ENDIF} dynlibs, base64, fpjson, jsonparser, vdrx_core, vdrx_templates, vdrx_procutil, vdrx_transport, vdrx_httpparse, vdrx_connection;

type

  TCGIResolve = (crNotFound, crScript, crStatic, crRedirectSlash, crForbidden);

  TVDRX_OneShotWaiter = class(TVDRX_Executive)
  private
    FEvent: TEvent;
    FReplyPayload: string;
    FGotReply: Boolean;
  public
    constructor Create(ABus: TVDRX_MessageQueue); reintroduce;
    destructor Destroy; override;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    function WaitForReply(ATimeoutMs: Integer; out APayload: string): Boolean;
  end;

var
  // Random per-process secret, generated once in vdrx.lpr at startup and
  // stamped into every envelope BuildEnvelope() produces. A CGI/runner
  // executive wired to an HTTP route (see vdrx_runner.pas's RequireEdgeToken)
  // refuses any request whose "_edge_token" doesn't match this value, which
  // is never exposed to WebSocket/admin clients. Without this, anything able
  // to publish onto a cgi/runner "<id>.in" topic - e.g. an unauthenticated
  // WebSocket client, see docs/known-gaps.md - could forge a "script_filename"
  // and get the CGI executive to run an arbitrary file: a real RCE path, not
  // just a bus-hygiene issue. Empty = no token configured (edge check is a
  // no-op); vdrx.lpr always sets this before SetupCGI/SetupLegacyCLIBridges run.
  GVDRXEdgeToken: string = '';

function ProxyRequest(const ARequest: string; const ARoute: TVDRX_ProxyRoute;
  ABus: TVDRX_MessageQueue; const ASourceID: string): string;

function ServeStaticFile(const APath, AStaticDir: string; ABus: TVDRX_MessageQueue;
  const ASourceID: string; var AStreamFile: string; var AStreamSize: Int64;
  ACustomHeaders: TStringList = nil): string;

// Sends AFilePath's first ASize bytes in chunks. Stops at the first failed or timed-out write (each
// write is bounded by the socket's send timeout) or when ADeadline (a GetTickCount64 value, 0 = none)
// passes. Returns the number of bytes sent.
function StreamFileBody(ATransport: TVDRX_Transport; const AFilePath: string; ASize: Int64; ADeadline: QWord): Int64;

// "cgi" routes: decides what a request path means under the route's doc_root.
//   crScript         AScriptFile / AScriptName / APathInfo are set (CGI meta-variables)
//   crStatic         AStaticPath is the path (relative to the prefix) of a plain file
//   crRedirectSlash  a directory requested without its trailing '/'
//   crForbidden      the path tried something SplitURLPath refuses
//   crNotFound
// Order, like a conventional web server: existing script (anything after it is
// PATH_INFO) -> existing plain file -> directory index file -> fallback script
// (front controller, e.g. "/index.php") -> 404.
function ResolveCGITarget(const APath: string; const ARoute: TVDRX_BusRoute;
  out AScriptName, AScriptFile, APathInfo, AStaticPath: string): TCGIResolve;

// The ONE way an HTTP request reaches code behind the bus: publish the request
// envelope to the route's in_topic, wait for a reply on a freshly minted
// reply_to topic, turn the reply back into an HTTP response. Whatever
// subscribes - a runner, a cgi executive, a supervised daemon, a WebSocket
// client - is just a consumer.
function RunBusRoute(const ARequest, AOrigTarget: string; const ARoute: TVDRX_BusRoute;
  const AConn: TVDRX_ConnInfo; const AScriptName, AScriptFile, APathInfo: string;
  ATemplates: TVDRX_TemplateStore; ABus: TVDRX_MessageQueue; ARegistry: TVDRX_Registry;
  const ASourceID: string): string;

// Adds a site's custom response headers (CORS etc., from "cors"/"headers" in
// http_sites) to a response some other code already built - used for the
// bus/cgi routes, whose responses are assembled by BuildReplyResponse
// rather than by PlainResponse. Headers the response
// already carries (matched case-insensitively) are left alone, so a script can
// still override a site default. Without this a browser would pass the CORS
// preflight but then refuse to hand the actual response to the calling page.
function InjectCustomHeaders(const AResponse: string; ACustomHeaders: TStringList): string;

function RedirectResponse(ACode: Integer; const ALocation: string; ACustomHeaders: TStringList): string;

implementation

const
  // Files up to this size are read into memory and sent in one piece; bigger ones are streamed from
  // disk in chunks. (Reading every file whole meant a client that asked for a large file and then
  // never read it cost the daemon the file's full size, for as long as it stayed connected.)
  STATIC_STREAM_THRESHOLD = 1024 * 1024;

function ServeStaticFile(const APath, AStaticDir: string; ABus: TVDRX_MessageQueue;
  const ASourceID: string; var AStreamFile: string; var AStreamSize: Int64;
  ACustomHeaders: TStringList = nil): string;
var
  FilePath, Body: string;
  FS: TFileStream;
  Segs: TStringList;
  i: Integer;
  Ok, Linked: Boolean;
  Redir: TStringList;
begin
  ABus.Publish('log.info', 'http: static path: "' + APath + '"', ASourceID);
  Linked := False;
  Ok := (AStaticDir <> '') and (APath <> '') and (APath[1] = '/');
  FilePath := '';
  if Ok then
  begin
    Segs := TStringList.Create;
    try
      Ok := SplitURLPath(APath, Segs);   // percent-decodes; refuses "..", dot-files, ':' etc.
      if Ok then
      begin
        FilePath := ExcludeTrailingPathDelimiter(ExpandFileName(AStaticDir));
        for i := 0 to Segs.Count - 1 do FilePath := FilePath + PathDelim + Segs[i];
        if (not StaticFollowSymlinks) and PathHasSymlink(ExpandFileName(AStaticDir), Segs) then Linked := True;
      end;
    finally
      Segs.Free;
    end;
  end;
  if not Ok then
  begin
    ABus.Publish('log.warn', 'http: rejected static path "' + APath + '"', ASourceID);
    Exit(PlainResponse('404 Not Found', 'text/plain', 'Not found', ACustomHeaders));
  end;
  if Linked then
  begin
    ABus.Publish('log.warn', 'http: refused static path "' + APath + '" - it goes through a symbolic link (static_follow_symlinks is off)', ASourceID);
    Exit(PlainResponse('404 Not Found', 'text/plain', 'Not found', ACustomHeaders));
  end;
  if VDRX_StaticDenied(FilePath) then
  begin
    ABus.Publish('log.warn', 'http: refused static file "' + APath + '" - its extension is on the deny list (static_deny_extensions)', ASourceID);
    Exit(PlainResponse('404 Not Found', 'text/plain', 'Not found', ACustomHeaders));
  end;
  if DirectoryExists(FilePath) then
  begin
    // "/docs" -> 301 to "/docs/" (so relative links in the page resolve); "/docs/" -> its index.html
    if APath[Length(APath)] <> '/' then
    begin
      Redir := TStringList.Create;
      try
        Redir.Add('Location=' + APath + '/');
        if Assigned(ACustomHeaders) then Redir.AddStrings(ACustomHeaders);
        Exit(PlainResponse('301 Moved Permanently', 'text/plain', 'Moved', Redir));
      finally
        Redir.Free;
      end;
    end;
    FilePath := IncludeTrailingPathDelimiter(FilePath) + 'index.html';
  end;
  if (not FileExists(FilePath)) or DirectoryExists(FilePath) then
  begin
    ABus.Publish('log.warn', 'http: static file not found: ' + FilePath, ASourceID);
    Exit(PlainResponse('404 Not Found', 'text/plain', 'Not found', ACustomHeaders));
  end;
  AStreamFile := '';
  AStreamSize := 0;
  FS := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyNone);
  try
    if FS.Size > STATIC_STREAM_THRESHOLD then
    begin
      AStreamFile := FilePath;
      AStreamSize := FS.Size;
    end
    else
    begin
      SetLength(Body, FS.Size);
      if FS.Size > 0 then
        FS.ReadBuffer(Body[1], FS.Size);
    end;
  finally
    FS.Free;
  end;
  if AStreamFile <> '' then
  begin
    ABus.Publish('log.info', Format('http: serving static %s (%d bytes, streamed)', [FilePath, AStreamSize]), ASourceID);
    Result := PlainResponseHead('200 OK', GuessContentType(FilePath), AStreamSize, ACustomHeaders);
    Exit;
  end;
  ABus.Publish('log.info', Format('http: served static %s (%d bytes)', [FilePath, Length(Body)]), ASourceID);
  Result := PlainResponse('200 OK', GuessContentType(FilePath), Body, ACustomHeaders);
end;

// Sends AFilePath's first ASize bytes in chunks. Stops at the first failed or timed-out write (each
// write is bounded by the socket's send timeout) or when ADeadline (a GetTickCount64 value, 0 = none)
// passes. Returns the number of bytes sent.
function StreamFileBody(ATransport: TVDRX_Transport; const AFilePath: string; ASize: Int64; ADeadline: QWord): Int64;
var
  FS: TFileStream;
  Buf: array[0..65535] of Byte;
  Left: Int64;
  N, Off, W, Want: Integer;
begin
  Result := 0;
  try
    FS := TFileStream.Create(AFilePath, fmOpenRead or fmShareDenyNone);
  except
    Exit;
  end;
  try
    Left := ASize;
    while Left > 0 do
    begin
      Want := SizeOf(Buf);
      if Want > Left then Want := Integer(Left);
      N := FS.Read(Buf[0], Want);
      if N <= 0 then Exit;                       // the file got shorter than it was
      Off := 0;
      while Off < N do
      begin
        if (ADeadline > 0) and (GetTickCount64 > ADeadline) then Exit;
        W := ATransport.Write(Buf[Off], N - Off);
        if W <= 0 then Exit;
        Inc(Off, W);
        Inc(Result, W);
      end;
      Dec(Left, N);
    end;
  finally
    FS.Free;
  end;
end;

// Rebuilds the request head for the upstream with 'Connection: close' (one request per upstream connection).
// Line endings are written as CRLF explicitly: TStringList.Text joins with the PLATFORM line ending, which on
// Linux is a bare LF - a malformed request that strict upstreams refuse and lenient ones read differently.
function ForceConnectionClose(const ARequest: string): string;
var
  HeaderEnd, LineStart, k: Integer;
  Line: string;
begin
  HeaderEnd := Pos(#13#10#13#10, ARequest);
  if HeaderEnd = 0 then Exit(ARequest);
  Result := '';
  LineStart := 1;
  while LineStart <= HeaderEnd do
  begin
    k := PosEx(#13#10, ARequest, LineStart);
    if (k = 0) or (k > HeaderEnd) then k := HeaderEnd + 1;
    Line := Copy(ARequest, LineStart, k - LineStart);
    LineStart := k + 2;
    if (Result <> '') and (Pos('connection:', LowerCase(Line)) = 1) then Continue;   // never drop the request line
    Result := Result + Line + #13#10;
  end;
  Result := Result + 'Connection: close' + #13#10 + #13#10 + Copy(ARequest, HeaderEnd + 4, MaxInt);
end;

function ProxyRequest(const ARequest: string; const ARoute: TVDRX_ProxyRoute;
  ABus: TVDRX_MessageQueue; const ASourceID: string): string;
const
  MAX_CONNECT_ATTEMPTS = 5;
  RETRY_DELAY_MS = 150;
  MAX_PROXY_RESPONSE = 64 * 1024 * 1024;   // an upstream that never stops sending must not be able to fill our memory
  UPSTREAM_READ_MS = 30000;                // ...nor one that accepts the request and then goes silent hold a thread
var
  Transport: TVDRX_Transport;
  Buf: array[0..8191] of Byte;
  Received, Attempt, Used: Integer;
  Outgoing: string;
  Deadline: QWord;
  TooBig, TimedOut: Boolean;
begin
  Transport := nil;
  TooBig := False;
  TimedOut := False;
  for Attempt := 1 to MAX_CONNECT_ATTEMPTS do
  begin
    Transport := ConnectTCP(ARoute.Host, ARoute.Port);
    if Assigned(Transport) then Break;
    if Attempt < MAX_CONNECT_ATTEMPTS then
      Sleep(RETRY_DELAY_MS);
  end;
  if not Assigned(Transport) then
  begin
    ABus.Publish('log.error', Format('http proxy: could not connect to %s:%d after %d attempt(s) - is the bridge process up? (check its own log lines above, and "kill <bridge-id>" to bounce it if it looks wedged)', [ARoute.Host, ARoute.Port, MAX_CONNECT_ATTEMPTS]), ASourceID);
    Exit(PlainResponse('502 Bad Gateway', 'text/plain', 'Upstream unavailable'));
  end;

  try
    Outgoing := ForceConnectionClose(ARequest);
    Transport.SetReadTimeout(UPSTREAM_READ_MS);
    if HTTPResponseTimeoutMs > 0 then Deadline := GetTickCount64 + QWord(HTTPResponseTimeoutMs) else Deadline := 0;
    Transport.Write(Outgoing[1], Length(Outgoing));
    Result := '';
    Used := 0;
    repeat
      Received := Transport.Read(Buf[0], SizeOf(Buf));
      if Received > 0 then
      begin
        if Used + Received > MAX_PROXY_RESPONSE then begin TooBig := True; Break; end;
        // grow the buffer geometrically: SetLength on every 8 KiB chunk recopies the whole response each time,
        // which is quadratic - a 60 MB response would take minutes
        if Used + Received > Length(Result) then SetLength(Result, Used + Received + Used div 2 + 65536);
        Move(Buf[0], Result[Used + 1], Received);
        Inc(Used, Received);
        if (Deadline > 0) and (GetTickCount64 > Deadline) then begin TimedOut := True; Break; end;
      end;
    until Received <= 0;
    SetLength(Result, Used);
  finally
    Transport.Close;
    Transport.Free;
  end;

  if TooBig then
  begin
    ABus.Publish('log.error', Format('http proxy: response from %s:%d exceeds %d bytes - dropped', [ARoute.Host, ARoute.Port, MAX_PROXY_RESPONSE]), ASourceID);
    Exit(PlainResponse('502 Bad Gateway', 'text/plain', 'Upstream response too large'));
  end;
  if TimedOut then
  begin
    ABus.Publish('log.warn', Format('http proxy: response from %s:%d did not finish in time - dropped', [ARoute.Host, ARoute.Port]), ASourceID);
    Exit(PlainResponse('504 Gateway Timeout', 'text/plain', 'Upstream took too long'));
  end;

  if Result = '' then
  begin
    ABus.Publish('log.warn', Format('http proxy: empty response from %s:%d', [ARoute.Host, ARoute.Port]), ASourceID);
    Exit(PlainResponse('502 Bad Gateway', 'text/plain', 'Empty response from upstream'));
  end;
  ABus.Publish('log.info', Format('http proxy: %s:%d -> %d bytes', [ARoute.Host, ARoute.Port, Length(Result)]), ASourceID);
end;

function IsScriptExt(const ARoute: TVDRX_BusRoute; const AFileName: string): Boolean;
begin
  if ARoute.Extensions = '' then Exit(True);
  Result := Pos(',' + LowerCase(ExtractFileExt(AFileName)) + ',', ARoute.Extensions) > 0;
end;

// "cgi" routes: decides what a request path means under the route's doc_root.
//   crScript         AScriptFile / AScriptName / APathInfo are set (CGI meta-variables)
//   crStatic         AStaticPath is the path (relative to the prefix) of a plain file
//   crRedirectSlash  a directory requested without its trailing '/'
//   crForbidden      the path tried something SplitURLPath refuses
//   crNotFound
// Order, like a conventional web server: existing script (anything after it is
// PATH_INFO) -> existing plain file -> directory index file -> fallback script
// (front controller, e.g. "/index.php") -> 404.
function ResolveCGITarget(const APath: string; const ARoute: TVDRX_BusRoute;
  out AScriptName, AScriptFile, APathInfo, AStaticPath: string): TCGIResolve;
var
  Base, Rel, Cur, Next, Cand, Idx: string;
  Segs, Idxs, FSegs: TStringList;
  i: Integer;
  Missing: Boolean;

  function JoinSegs(AFrom, ATo: Integer): string;
  var
    k: Integer;
  begin
    Result := '';
    for k := AFrom to ATo do Result := Result + '/' + Segs[k];
  end;

begin
  Result := crNotFound;
  AScriptName := '';
  AScriptFile := '';
  APathInfo := '';
  AStaticPath := '';
  Base := ARoute.Prefix;
  while (Base <> '') and (Base[Length(Base)] = '/') do SetLength(Base, Length(Base) - 1);
  Rel := Copy(APath, Length(Base) + 1, MaxInt);
  if (Rel <> '') and (Rel[1] <> '/') then Exit;   // prefix "/app" also matched "/apple"
  if Rel = '' then Rel := '/';

  Segs := TStringList.Create;
  Idxs := TStringList.Create;
  FSegs := TStringList.Create;
  try
    if not SplitURLPath(Rel, Segs) then Exit(crForbidden);
    Cur := ExcludeTrailingPathDelimiter(ExpandFileName(ARoute.DocRoot));
    Missing := False;
    for i := 0 to Segs.Count - 1 do
    begin
      Next := Cur + PathDelim + Segs[i];
      if DirectoryExists(Next) then
      begin
        Cur := Next;
        Continue;
      end;
      if FileExists(Next) then
      begin
        if IsScriptExt(ARoute, Next) then
        begin
          AScriptFile := Next;
          AScriptName := Base + JoinSegs(0, i);
          if i < Segs.Count - 1 then APathInfo := JoinSegs(i + 1, Segs.Count - 1);
          Exit(crScript);
        end;
        if ARoute.Static and (i = Segs.Count - 1) then
        begin
          AStaticPath := Rel;
          Exit(crStatic);
        end;
      end;
      Missing := True;
      Break;
    end;

    if not Missing then
    begin
      // the whole path is a directory (or the root)
      if (Rel <> '/') and (Rel[Length(Rel)] <> '/') then Exit(crRedirectSlash);
      Idxs.CommaText := ARoute.IndexFiles;
      for i := 0 to Idxs.Count - 1 do
      begin
        Idx := Trim(Idxs[i]);
        if (Idx = '') or (Pos('/', Idx) > 0) or (Pos('\', Idx) > 0) or (Pos('..', Idx) > 0) then Continue;
        Cand := Cur + PathDelim + Idx;
        if not FileExists(Cand) then Continue;
        if IsScriptExt(ARoute, Cand) then
        begin
          AScriptFile := Cand;
          AScriptName := Base + JoinSegs(0, Segs.Count - 1) + '/' + Idx;
          Exit(crScript);
        end;
        if ARoute.Static then
        begin
          AStaticPath := Rel + Idx;
          Exit(crStatic);
        end;
      end;
    end;

    // front controller: everything that matched nothing goes to one script
    if ARoute.Fallback <> '' then
    begin
      Cand := ExcludeTrailingPathDelimiter(ExpandFileName(ARoute.DocRoot));
      if SplitURLPath(ARoute.Fallback, FSegs) and (FSegs.Count > 0) then
      begin
        Next := '';
        for i := 0 to FSegs.Count - 1 do
        begin
          Cand := Cand + PathDelim + FSegs[i];
          Next := Next + '/' + FSegs[i];
        end;
        if FileExists(Cand) then
        begin
          AScriptFile := Cand;
          AScriptName := Base + Next;
          APathInfo := '';
          Exit(crScript);
        end;
      end;
    end;
  finally
    FSegs.Free;
    Idxs.Free;
    Segs.Free;
  end;
end;

function FindJSONObject(AObj: TJSONObject; const AName: string): TJSONObject;
var
  D: TJSONData;
begin
  D := AObj.Find(AName);
  if Assigned(D) and (D is TJSONObject) then
    Result := TJSONObject(D)
  else
    Result := nil;
end;

{ TVDRX_OneShotWaiter }

constructor TVDRX_OneShotWaiter.Create(ABus: TVDRX_MessageQueue);
begin
  inherited Create(ABus);
  FEvent := TEvent.Create(nil, True, False, '');
  FGotReply := False;
end;

destructor TVDRX_OneShotWaiter.Destroy;
begin
  FEvent.Free;
  inherited;
end;

procedure TVDRX_OneShotWaiter.HandlePacket(const AMsg: TVDRX_Message);
begin
  FReplyPayload := AMsg.Payload;
  FGotReply := True;
  FEvent.SetEvent;
end;

function TVDRX_OneShotWaiter.WaitForReply(ATimeoutMs: Integer; out APayload: string): Boolean;
begin
  Result := (FEvent.WaitFor(ATimeoutMs) = wrSignaled) and FGotReply;
  if Result then APayload := FReplyPayload else APayload := '';
end;

var
  GReplyTopicCounter: Integer = 0;
  GReplyTopicLock: TCriticalSection;

function NextReplyTopic(const APrefix: string): string;
begin
  GReplyTopicLock.Enter;
  try
    Inc(GReplyTopicCounter);
    Result := APrefix + '.' + IntToStr(GReplyTopicCounter);
  finally
    GReplyTopicLock.Leave;
  end;
end;

function PublishAndWait(ARegistry: TVDRX_Registry; ABus: TVDRX_MessageQueue;
  const AInTopic, AReplyPrefix: string; AEnvelope: TJSONObject;
  ATimeoutMs: Integer; const ASourceID: string; out AReply: string): Boolean;
var
  ReplyTopic: string;
  Waiter: TVDRX_OneShotWaiter;
begin
  ReplyTopic := NextReplyTopic(AReplyPrefix);
  AEnvelope.Add('reply_to', ReplyTopic);

  Waiter := TVDRX_OneShotWaiter.Create(ABus);
  ARegistry.Register(Waiter, ReplyTopic, ReplyTopic);

  ABus.Publish(AInTopic, AEnvelope.AsJSON, ASourceID);
  Result := Waiter.WaitForReply(ATimeoutMs, AReply);

  ARegistry.Unregister(ReplyTopic);
  if not Result then
    ABus.Publish('log.warn', Format('bus wait: no reply on "%s" (published to "%s") within %dms', [ReplyTopic, AInTopic, ATimeoutMs]), ASourceID);
end;

// Turns a reply envelope into a complete HTTP response:
//   { "status": 200, "content_type": "...", "body" | "body_b64": "...",
//     "headers": { "Name": "value" | ["v1", "v2"] } }
// or, instead of a body, { "template", "params", "rows" [, "template_topic"] }
// to have the reply rendered by the template engine.
function BuildReplyResponse(const AReplyLine, ADefaultContentType: string;
  ATemplates: TVDRX_TemplateStore; ABus: TVDRX_MessageQueue; ARegistry: TVDRX_Registry; const ASourceID: string): string;
var
  J: TJSONData;
  Obj, ParamsObj, RowsObj, HeadersObj, RenderEnvelope, ReplyObj: TJSONObject;
  ReplyJSON: TJSONData;
  Status, ContentType, Body, TemplateName, TemplateTopic, ReplyRaw, Extra, HName: string;
  StatusCode, i, k: Integer;
  Params: TStringList;
  NamedRows: TVDRX_TemplateNamedRows;
begin
  if Trim(AReplyLine) = '' then
  begin
    ABus.Publish('log.warn', 'http bus cli: empty reply from script (nothing written to stdout before exit)', ASourceID);
    Exit(PlainResponse('502 Bad Gateway', 'text/plain', 'Empty response from script'));
  end;

  J := nil;
  try
    J := GetJSON(AReplyLine);
  except
    J := nil;
  end;
  if not Assigned(J) or not (J is TJSONObject) then
  begin
    ABus.Publish('log.warn', 'http bus cli: reply was not a JSON object: ' + AReplyLine, ASourceID);
    if Assigned(J) then J.Free;
    Exit(PlainResponse('502 Bad Gateway', 'text/plain', 'Malformed response from script'));
  end;

  Obj := TJSONObject(J);
  try
    StatusCode := Obj.Get('status', 200);
    Status := IntToStr(StatusCode) + ' ' + HTTPStatusText(StatusCode);
    ContentType := Obj.Get('content_type', ADefaultContentType);
    TemplateName := Obj.Get('template', '');
    TemplateTopic := Obj.Get('template_topic', '');

    if (TemplateName <> '') and (TemplateTopic <> '') then
    begin
      RenderEnvelope := TJSONObject.Create;
      try
        RenderEnvelope.Add('template', TemplateName);
        if Assigned(FindJSONObject(Obj, 'params')) then RenderEnvelope.Add('params', FindJSONObject(Obj, 'params').Clone);
        if Assigned(FindJSONObject(Obj, 'rows')) then RenderEnvelope.Add('rows', FindJSONObject(Obj, 'rows').Clone);

        if not PublishAndWait(ARegistry, ABus, TemplateTopic, 'template.reply', RenderEnvelope, 5000, ASourceID, ReplyRaw) then
        begin
          ABus.Publish('log.warn', Format('http bus cli: no template executive answered "%s" for template "%s"', [TemplateTopic, TemplateName]), ASourceID);
          Exit(PlainResponse('502 Bad Gateway', 'text/plain', 'Template executive did not respond'));
        end;
      finally
        RenderEnvelope.Free;
      end;

      Body := '';
      ReplyJSON := nil;
      try
        try ReplyJSON := GetJSON(ReplyRaw); except ReplyJSON := nil; end;
        if Assigned(ReplyJSON) and (ReplyJSON is TJSONObject) then
        begin
          ReplyObj := TJSONObject(ReplyJSON);
          Body := ReplyObj.Get('body', '');
        end;
      finally
        if Assigned(ReplyJSON) then ReplyJSON.Free;
      end;
      if Body = '' then
        ABus.Publish('log.warn', Format('http bus cli: template executive "%s" returned no body for template "%s"', [TemplateTopic, TemplateName]), ASourceID);
    end
    else if TemplateName <> '' then
    begin
      ParamsObj := FindJSONObject(Obj, 'params');
      Params := JSONParamsToStringList(ParamsObj);
      try
        RowsObj := FindJSONObject(Obj, 'rows');
        NamedRows := JSONRowsToTemplateRows(RowsObj);
        try
          Body := ATemplates.Fill(TemplateName, Params, NamedRows);
        finally
          NamedRows.Free;
        end;
      finally
        Params.Free;
      end;
      if Body = '' then
        ABus.Publish('log.warn', Format('http bus cli: template "%s" not found or rendered empty - looked for %s', [TemplateName, IncludeTrailingPathDelimiter(ATemplates.Dir) + TemplateName + '.tpl']), ASourceID);
    end
    else if Obj.Find('body_b64') is TJSONString then
    begin
      try
        Body := DecodeStringBase64(Obj.Get('body_b64', ''));
      except
        ABus.Publish('log.warn', 'http reply: body_b64 is not valid base64', ASourceID);
        Exit(PlainResponse('502 Bad Gateway', 'text/plain', 'Malformed response body'));
      end;
    end
    else
      Body := Obj.Get('body', '');

    // Extra headers. Several lines of one name (Set-Cookie) arrive as an array.
    // The edge owns framing, so a reply can't set Content-Length, Transfer-Encoding
    // or Connection; a Content-Type in "headers" overrides "content_type".
    Extra := '';
    HeadersObj := FindJSONObject(Obj, 'headers');
    if Assigned(HeadersObj) then
      for i := 0 to HeadersObj.Count - 1 do
      begin
        HName := HeadersObj.Names[i];
        if SameText(HName, 'Content-Length') or SameText(HName, 'Transfer-Encoding') or SameText(HName, 'Connection') then Continue;
        if (HName = '') or (Pos(':', HName) > 0) or (Pos(#13, HName) > 0) or (Pos(#10, HName) > 0) then Continue;
        if HeadersObj.Items[i].JSONType in [jtString, jtNumber, jtBoolean] then
        begin
          if SameText(HName, 'Content-Type') then
            ContentType := HeadersObj.Items[i].AsString
          else
            Extra := Extra + HName + ': ' + StringReplace(StringReplace(HeadersObj.Items[i].AsString, #13, ' ', [rfReplaceAll]), #10, ' ', [rfReplaceAll]) + #13#10;
        end
        else if HeadersObj.Items[i].JSONType = jtArray then
          for k := 0 to TJSONArray(HeadersObj.Items[i]).Count - 1 do
            Extra := Extra + HName + ': ' + StringReplace(StringReplace(TJSONArray(HeadersObj.Items[i]).Items[k].AsString, #13, ' ', [rfReplaceAll]), #10, ' ', [rfReplaceAll]) + #13#10;
      end;

    Result := 'HTTP/1.1 ' + Status + #13#10 + 'Content-Type: ' + ContentType + #13#10 + Extra +
      'Content-Length: ' + IntToStr(Length(Body)) + #13#10#13#10 + Body;
  finally
    Obj.Free;
  end;
end;

function RedirectResponse(ACode: Integer; const ALocation: string; ACustomHeaders: TStringList): string;
var
  H: TStringList;
begin
  H := TStringList.Create;
  try
    H.Add('Location=' + ALocation);
    if Assigned(ACustomHeaders) then H.AddStrings(ACustomHeaders);
    Result := PlainResponse(IntToStr(ACode) + ' ' + HTTPStatusText(ACode), 'text/plain', 'Redirecting to ' + ALocation, H);
  finally
    H.Free;
  end;
end;

// The request envelope every bus route publishes (documented in readme "HTTP").
function BuildEnvelope(const ARequest, AOrigTarget: string; const ARoute: TVDRX_BusRoute;
  const AConn: TVDRX_ConnInfo; const AScriptName, AScriptFile, APathInfo: string): TJSONObject;
var
  Method, Path, HeaderBlock, Body, Host, SubPath: string;
  HeaderEnd, p: Integer;
  HeadersObj: TJSONObject;
begin
  ParseRequestLine(ARequest, Method, Path);
  HeaderEnd := Pos(#13#10#13#10, ARequest);
  if HeaderEnd > 0 then HeaderBlock := Copy(ARequest, 1, HeaderEnd - 1) else HeaderBlock := ARequest;
  Body := ExtractBody(ARequest);
  if Length(Path) >= Length(ARoute.Prefix) then
    SubPath := Copy(Path, Length(ARoute.Prefix) + 1, MaxInt)
  else
    SubPath := '';

  // Host header without its port ("[::1]:8080" -> "[::1]", "a.com:80" -> "a.com")
  Host := ExtractHeaderValue(HeaderBlock, 'Host');
  if (Host <> '') and (Host[1] = '[') then
  begin
    p := Pos(']', Host);
    if p > 0 then Host := Copy(Host, 1, p);
  end
  else
  begin
    p := Pos(':', Host);
    if p > 0 then Host := Copy(Host, 1, p - 1);
  end;
  if Host = '' then Host := 'localhost';

  Result := TJSONObject.Create;
  Result.Add('method', Method);
  Result.Add('path', CleanUTF8(Path));
  Result.Add('prefix', ARoute.Prefix);
  Result.Add('sub_path', CleanUTF8(SubPath));
  Result.Add('query', CleanUTF8(ExtractQueryString(ARequest)));
  Result.Add('request_uri', CleanUTF8(AOrigTarget));
  Result.Add('protocol', RequestVersion(ARequest));
  HeadersObj := HeadersToJSON(HeaderBlock);
  Result.Add('headers', HeadersObj);
  // JSON strings must be UTF-8; a binary body (file upload ...) travels as base64
  if IsValidUTF8(Body) then
    Result.Add('body', Body)
  else
    Result.Add('body_b64', EncodeStringBase64(Body));
  Result.Add('remote_addr', AConn.RemoteAddr);
  Result.Add('remote_port', Integer(AConn.RemotePort));
  Result.Add('server_name', Host);
  Result.Add('server_port', Integer(AConn.ServerPort));
  Result.Add('https', AConn.Secure);
  if SameText(ARoute.Kind, 'cgi') then
  begin
    Result.Add('script_name', CleanUTF8(AScriptName));
    Result.Add('script_filename', AScriptFile);
    Result.Add('path_info', CleanUTF8(APathInfo));
    Result.Add('doc_root', ExcludeTrailingPathDelimiter(ExpandFileName(ARoute.DocRoot)));
  end;
  if GVDRXEdgeToken <> '' then
    Result.Add('_edge_token', GVDRXEdgeToken);
end;

// The ONE way an HTTP request reaches code behind the bus: publish the request
// envelope to the route's in_topic, wait for a reply on a freshly minted
// reply_to topic, turn the reply back into an HTTP response. Whatever
// subscribes - a runner, a cgi executive, a supervised daemon, a WebSocket
// client - is just a consumer.
function RunBusRoute(const ARequest, AOrigTarget: string; const ARoute: TVDRX_BusRoute;
  const AConn: TVDRX_ConnInfo; const AScriptName, AScriptFile, APathInfo: string;
  ATemplates: TVDRX_TemplateStore; ABus: TVDRX_MessageQueue; ARegistry: TVDRX_Registry;
  const ASourceID: string): string;
var
  Method, Path, ReplyRaw: string;
  Env: TJSONObject;
  AllowHdrs: TStringList;
  ReplyJ: TJSONData;
  RStatus, WaitMs: Integer;
begin
  ParseRequestLine(ARequest, Method, Path);
  if ARoute.Allow <> '' then
    if Pos(',' + UpperCase(Method) + ',', ',' + StringReplace(UpperCase(ARoute.Allow), ' ', '', [rfReplaceAll]) + ',') = 0 then
    begin
      AllowHdrs := TStringList.Create;
      try
        AllowHdrs.Add('Allow=' + ARoute.Allow);
        Exit(PlainResponse('405 Method Not Allowed', 'text/plain', 'Method not allowed - use ' + ARoute.Allow, AllowHdrs));
      finally
        AllowHdrs.Free;
      end;
    end;

  Env := BuildEnvelope(ARequest, AOrigTarget, ARoute, AConn, AScriptName, AScriptFile, APathInfo);
  try
    WaitMs := ARoute.TimeoutMs;
    // the cgi executive kills a runaway program at timeout_ms and answers 504
    // itself; give that reply time to arrive before the edge gives up
    if SameText(ARoute.Kind, 'cgi') then Inc(WaitMs, 5000);
    if not PublishAndWait(ARegistry, ABus, ARoute.InTopic, 'http.reply', Env, WaitMs, ASourceID, ReplyRaw) then
    begin
      ABus.Publish('log.error', Format('http route "%s": no subscriber on "%s" answered %s within %dms', [ARoute.ID, ARoute.InTopic, Path, WaitMs]), ASourceID);
      Exit(PlainResponse('504 Gateway Timeout', 'text/plain', 'No handler answered in time'));
    end;
  finally
    Env.Free;
  end;

  ABus.Publish('log.info', Format('http route "%s": %s %s (in_topic=%s) -> %d bytes', [ARoute.ID, Method, Path, ARoute.InTopic, Length(ReplyRaw)]), ASourceID);
  if SameText(ARoute.Response, 'json') then
  begin
    // hand the browser the whole reply envelope as JSON (status, body,
    // content_type, exit_code, stderr, ...) instead of unwrapping it
    RStatus := 200;
    try
      ReplyJ := GetJSON(ReplyRaw);
      try
        if ReplyJ is TJSONObject then RStatus := TJSONObject(ReplyJ).Get('status', 200);
      finally
        ReplyJ.Free;
      end;
    except
      ReplyRaw := '{"status":502,"body":"reply was not valid JSON"}';
      RStatus := 502;
    end;
    Exit(PlainResponse(IntToStr(RStatus) + ' ' + HTTPStatusText(RStatus), 'application/json', ReplyRaw));
  end;
  Result := BuildReplyResponse(ReplyRaw, ARoute.ContentType, ATemplates, ABus, ARegistry, ASourceID);
end;

// Adds a site's custom response headers (CORS etc., from "cors"/"headers" in
// http_sites) to a response some other code already built - used for the
// bus/cgi routes, whose responses are assembled by BuildReplyResponse
// rather than by PlainResponse. Headers the response
// already carries (matched case-insensitively) are left alone, so a script can
// still override a site default. Without this a browser would pass the CORS
// preflight but then refuse to hand the actual response to the calling page.
function InjectCustomHeaders(const AResponse: string; ACustomHeaders: TStringList): string;
var
  p, HdrEnd, i: Integer;
  Head, Extra, Name: string;
begin
  Result := AResponse;
  if (ACustomHeaders = nil) or (ACustomHeaders.Count = 0) then Exit;
  p := Pos(#13#10, AResponse);
  if p = 0 then Exit;
  HdrEnd := Pos(#13#10#13#10, AResponse);
  if HdrEnd = 0 then HdrEnd := Length(AResponse);
  Head := LowerCase(Copy(AResponse, 1, HdrEnd));
  Extra := '';
  for i := 0 to ACustomHeaders.Count - 1 do
  begin
    Name := ACustomHeaders.Names[i];
    if (Name <> '') and (Pos(#13#10 + LowerCase(Name) + ':', Head) = 0) then
      Extra := Extra + Name + ': ' + ACustomHeaders.ValueFromIndex[i] + #13#10;
  end;
  Insert(Extra, Result, p + 2);
end;

initialization
  GReplyTopicLock := TCriticalSection.Create;

finalization
  GReplyTopicLock.Free;

end.
