unit vdrx_http;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, Sockets, Process, vdrx_core, vdrx_socketlistener,
  vdrx_transport, vdrx_config, vdrx_templates, vdrx_procutil, Generics.Collections;

type
  // One configured reverse-proxy target - see vdrx_daemon.conf's
  // "proxy_bridges" and vdrx_daemon.lpr's SetupProxyBridges. Prefix match is
  // longest-prefix-wins (like nginx location blocks), so overlapping
  // prefixes (e.g. "/app/" and "/app/admin/") behave predictably.
  TVDRX_ProxyRoute = record
    Prefix: string;
    Host: string;
    Port: Word;
  end;
  TVDRX_ProxyRoutes = array of TVDRX_ProxyRoute;

  // A one-shot-per-request PHP (or anything else) invocation, as opposed to
  // TVDRX_ProxyRoute's persistent Bridge-managed backend. No Registry/Bridge
  // involved at all - just this route table, consulted per request; the
  // process is spawned, run, and freed entirely within RunCLIScript below.
  TVDRX_CLIRoute = record
    Prefix: string;
    Command: string;
    ScriptDir: string;
    TimeoutMs: Integer;
    ContentType: string;
  end;
  TVDRX_CLIRoutes = array of TVDRX_CLIRoute;

  TVDRX_HTTPExecutive = class(TVDRX_SocketListenerExecutive)
  private
    FConfig: TVDRX_Config;
    FTemplates: TVDRX_TemplateStore;
    FStaticDir: string;
    FProxyRoutes: TVDRX_ProxyRoutes;
    FCLIRoutes: TVDRX_CLIRoutes;
  protected
    procedure HandleConnection(ATransport: TVDRX_Transport); override;
  public
    constructor Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config;
      ATemplates: TVDRX_TemplateStore;
      const AStaticDir: string; const AProxyRoutes: TVDRX_ProxyRoutes;
      const ACLIRoutes: TVDRX_CLIRoutes); reintroduce;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    procedure ApplyConfig; override;
    class function BuildResponse(const ARequest: string;
      ATemplates: TVDRX_TemplateStore; AConfig: TVDRX_Config; const AStaticDir: string;
      const AProxyRoutes: TVDRX_ProxyRoutes; const ACLIRoutes: TVDRX_CLIRoutes;
      ABus: TVDRX_MessageQueue; const ASourceID: string): string;
  end;

implementation

const
  MAX_HEADER_SIZE = 16384;
  MAX_BODY_SIZE = 10 * 1024 * 1024; // generous for dev/test form posts - not meant for large uploads

type
  // Bounds RunCLIScript's wall-clock time WITHOUT blocking the read loop that
  // drains the child's stdout - see RunCLIScript's comment for why those two
  // things have to happen concurrently, not one after the other.
  TCLIWatchdog = class
  private
    FProc: TProcess;
    FTimeoutMs: Integer;
    FCancelled: Boolean;
    FFired: Boolean;
  public
    constructor Create(AProc: TProcess; ATimeoutMs: Integer);
    procedure Run;
    procedure Cancel;
    property Fired: Boolean read FFired;
  end;

constructor TCLIWatchdog.Create(AProc: TProcess; ATimeoutMs: Integer);
begin
  inherited Create;
  FProc := AProc;
  FTimeoutMs := ATimeoutMs;
end;

procedure TCLIWatchdog.Cancel;
begin
  FCancelled := True;
end;

procedure TCLIWatchdog.Run;
var
  Waited: Integer;
begin
  Waited := 0;
  while (not FCancelled) and (Waited < FTimeoutMs) do
  begin
    Sleep(50);
    Inc(Waited, 50);
  end;
  if (not FCancelled) and FProc.Running then
  begin
    FFired := True;
    ForceKillProcess(FProc);
  end;
end;

function PlainResponse(const AStatus, AContentType, ABody: string): string;
begin
  Result := 'HTTP/1.1 ' + AStatus + #13#10 +
            'Content-Type: ' + AContentType + #13#10 +
            'Content-Length: ' + IntToStr(Length(ABody)) + #13#10#13#10 + ABody;
end;

function StatusOf(const AResponse: string): string;
var
  LineEnd, SpacePos: Integer;
begin
  LineEnd := Pos(#13#10, AResponse);
  if LineEnd = 0 then LineEnd := Length(AResponse) + 1;
  SpacePos := Pos(' ', AResponse);
  if (SpacePos = 0) or (SpacePos >= LineEnd) then Exit('?');
  Result := Copy(AResponse, SpacePos + 1, LineEnd - SpacePos - 1);
end;

procedure ParseRequestLine(const ARequest: string; out AMethod, APath: string);
var
  LineEnd, Sp1, Sp2: Integer;
  Line: string;
begin
  AMethod := '';
  APath := '';
  LineEnd := Pos(#13#10, ARequest);
  if LineEnd = 0 then LineEnd := Pos(#10, ARequest);
  if LineEnd = 0 then Line := ARequest else Line := Copy(ARequest, 1, LineEnd - 1);
  Sp1 := Pos(' ', Line);
  if Sp1 = 0 then Exit;
  AMethod := Copy(Line, 1, Sp1 - 1);
  Sp2 := PosEx(' ', Line, Sp1 + 1);
  if Sp2 = 0 then Sp2 := Length(Line) + 1;
  APath := Copy(Line, Sp1 + 1, Sp2 - Sp1 - 1);
  Sp1 := Pos('?', APath);
  if Sp1 > 0 then APath := Copy(APath, 1, Sp1 - 1);
end;

function ExtractQueryString(const ARequest: string): string;
var
  LineEnd, Sp1, Sp2, QPos: Integer;
  Line, RawPath: string;
begin
  Result := '';
  LineEnd := Pos(#13#10, ARequest);
  if LineEnd = 0 then LineEnd := Length(ARequest) + 1;
  Line := Copy(ARequest, 1, LineEnd - 1);
  Sp1 := Pos(' ', Line);
  if Sp1 = 0 then Exit;
  Sp2 := PosEx(' ', Line, Sp1 + 1);
  if Sp2 = 0 then Sp2 := Length(Line) + 1;
  RawPath := Copy(Line, Sp1 + 1, Sp2 - Sp1 - 1);
  QPos := Pos('?', RawPath);
  if QPos > 0 then
    Result := Copy(RawPath, QPos + 1, MaxInt);
end;

function ExtractHeaderValue(const AHeaderBlock, AName: string): string;
var
  SL: TStringList;
  i, Colon: Integer;
begin
  Result := '';
  SL := TStringList.Create;
  try
    SL.Text := AHeaderBlock;
    for i := 1 to SL.Count - 1 do // line 0 is the request line, not a header
    begin
      Colon := Pos(':', SL[i]);
      if (Colon > 0) and SameText(Trim(Copy(SL[i], 1, Colon - 1)), AName) then
        Exit(Trim(Copy(SL[i], Colon + 1, MaxInt)));
    end;
  finally
    SL.Free;
  end;
end;

// Reads a full request off the wire: headers (up to the blank line), then -
// if a Content-Length header is present - exactly that many more body bytes.
// Needed for the proxy path (a PHP app expects to see the whole POST body,
// not the first ~1KB a single Read happened to return) but applies to every
// request now, board/static included, since it's strictly more correct.
function ReadFullRequest(ATransport: TVDRX_Transport): string;
var
  Buf: array[0..4095] of Byte;
  Received, HeaderEnd, ContentLength, BodySoFar, ToRead: Integer;
  HeaderBlock, CLStr: string;
begin
  Result := '';
  HeaderEnd := 0;
  while (HeaderEnd = 0) and (Length(Result) < MAX_HEADER_SIZE) do
  begin
    Received := ATransport.Read(Buf[0], SizeOf(Buf));
    if Received <= 0 then Exit(Result); // closed before headers finished - hand back whatever we have
    SetLength(Result, Length(Result) + Received);
    Move(Buf[0], Result[Length(Result) - Received + 1], Received);
    HeaderEnd := Pos(#13#10#13#10, Result);
  end;
  if HeaderEnd = 0 then Exit; // headers too large or never terminated - drop rather than hang

  HeaderBlock := Copy(Result, 1, HeaderEnd - 1);
  CLStr := ExtractHeaderValue(HeaderBlock, 'Content-Length');
  ContentLength := 0;
  if CLStr <> '' then
    ContentLength := StrToIntDef(Trim(CLStr), 0);
  if ContentLength > MAX_BODY_SIZE then ContentLength := MAX_BODY_SIZE; // clamp rather than reject

  BodySoFar := Length(Result) - (HeaderEnd + 3);
  while BodySoFar < ContentLength do
  begin
    ToRead := ContentLength - BodySoFar;
    if ToRead > SizeOf(Buf) then ToRead := SizeOf(Buf);
    Received := ATransport.Read(Buf[0], ToRead);
    if Received <= 0 then Break; // client stopped sending early - forward whatever we actually got
    SetLength(Result, Length(Result) + Received);
    Move(Buf[0], Result[Length(Result) - Received + 1], Received);
    Inc(BodySoFar, Received);
  end;
end;

function IsValidBoardName(const AName: string): Boolean;
var
  i: Integer;
begin
  Result := (Length(AName) > 0) and (Length(AName) <= 64);
  if not Result then Exit;
  for i := 1 to Length(AName) do
    if not (AName[i] in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-']) then
      Exit(False);
end;

function GuessContentType(const APath: string): string;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(APath));
  if Ext = '.js' then Result := 'application/javascript'
  else if Ext = '.css' then Result := 'text/css'
  else if Ext = '.html' then Result := 'text/html'
  else if Ext = '.json' then Result := 'application/json'
  else if Ext = '.svg' then Result := 'image/svg+xml'
  else Result := 'application/octet-stream';
end;

function ServeStaticFile(const APath, AStaticDir: string; ABus: TVDRX_MessageQueue; const ASourceID: string): string;
var
  FilePath, Body: string;
  FS: TFileStream;
begin
  if (AStaticDir = '') or (Pos('..', APath) > 0) or (APath = '') or (APath[1] <> '/') then
  begin
    ABus.Publish('log.warn', 'http: rejected static path "' + APath + '"', ASourceID);
    Exit(PlainResponse('404 Not Found', 'text/plain', 'Not found'));
  end;
  FilePath := IncludeTrailingPathDelimiter(AStaticDir) + Copy(APath, 2, MaxInt);
  if (not FileExists(FilePath)) or DirectoryExists(FilePath) then
  begin
    ABus.Publish('log.warn', 'http: static file not found: ' + FilePath, ASourceID);
    Exit(PlainResponse('404 Not Found', 'text/plain', 'Not found'));
  end;
  FS := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Body, FS.Size);
    if FS.Size > 0 then
      FS.ReadBuffer(Body[1], FS.Size);
  finally
    FS.Free;
  end;
  ABus.Publish('log.info', Format('http: served static %s (%d bytes)', [FilePath, Length(Body)]), ASourceID);
  Result := PlainResponse('200 OK', GuessContentType(APath), Body);
end;

// Unlike RenderBoardPage there's no board_name/board list - one game, one
// page. plague_map_image comes from settings (vdrx_daemon.conf ->
// "settings":{"plague_map_image": "plague_map.png"}) via the templates
// engine's existing $$setting$$ resolution, same as site_title - the client
// JS fetches /plague/state and /plague/countries itself rather than having
// them inlined here, so a page refresh mid-game doesn't need the template
// re-filled with a fresh snapshot on every request.
function RenderPlaguePage(ATemplates: TVDRX_TemplateStore; AConfig: TVDRX_Config;
  ABus: TVDRX_MessageQueue; const ASourceID: string): string;
var
  Body: string;
  Params: TStringList;
begin
  Params := TStringList.Create;
  try
    Params.Values['ws_port'] := IntToStr(AConfig.GetInteger('executives.ws.port', 8082));
    Params.Values['ws_host_json'] := '""';
    Params.Values['ws_tls_json'] := IfThen(AConfig.GetInteger('executives.ws.tls_port', 0) <> 0, 'true', 'false');
    Body := ATemplates.Fill('plague', Params, nil);
  finally
    Params.Free;
  end;

  if Body = '' then
  begin
    ABus.Publish('log.error', 'http: plague.tpl produced no output - check template_dir', ASourceID);
    Exit(PlainResponse('500 Internal Server Error', 'text/plain',
      'Missing template: plague.tpl (check template_dir in vdrx_daemon.conf)'));
  end;
  Result := PlainResponse('200 OK', 'text/html', Body);
end;

function MatchProxyRoute(const APath: string; const ARoutes: TVDRX_ProxyRoutes; out AMatch: TVDRX_ProxyRoute): Boolean;
var
  i, bestLen: Integer;
begin
  Result := False;
  bestLen := -1;
  for i := 0 to High(ARoutes) do
    if (Copy(APath, 1, Length(ARoutes[i].Prefix)) = ARoutes[i].Prefix) and (Length(ARoutes[i].Prefix) > bestLen) then
    begin
      AMatch := ARoutes[i];
      bestLen := Length(ARoutes[i].Prefix);
      Result := True;
    end;
end;

// Strips any existing Connection header and forces 'Connection: close' -
// without this, a keep-alive-capable backend (php -S included) would hold
// the socket open waiting for a second request over the same connection,
// and the "read until the backend closes" loop in ProxyRequest below would
// then block forever on every single proxied request. Same shape of bug as
// the WebSocket self-join deadlock from earlier in this project: a blocking
// read with no other signal for "the response is actually done."
function ForceConnectionClose(const ARequest: string): string;
var
  HeaderEnd, i: Integer;
  OutLines: TStringList;
begin
  HeaderEnd := Pos(#13#10#13#10, ARequest);
  if HeaderEnd = 0 then Exit(ARequest); // malformed - forward as-is rather than guess
  OutLines := TStringList.Create;
  try
    OutLines.Text := Copy(ARequest, 1, HeaderEnd - 1);
    for i := OutLines.Count - 1 downto 0 do
      if Pos('connection:', LowerCase(OutLines[i])) = 1 then
        OutLines.Delete(i);
    OutLines.Add('Connection: close');
    Result := OutLines.Text + #13#10 + Copy(ARequest, HeaderEnd + 4, MaxInt);
  finally
    OutLines.Free;
  end;
end;

function ProxyRequest(const ARequest: string; const ARoute: TVDRX_ProxyRoute;
  ABus: TVDRX_MessageQueue; const ASourceID: string): string;
const
  MAX_CONNECT_ATTEMPTS = 5;
  RETRY_DELAY_MS = 150;
var
  Transport: TVDRX_Transport;
  Buf: array[0..8191] of Byte;
  Received, Attempt: Integer;
  Outgoing: string;
begin
  Transport := nil;
  for Attempt := 1 to MAX_CONNECT_ATTEMPTS do
  begin
    Transport := ConnectTCP(ARoute.Host, ARoute.Port);
    if Assigned(Transport) then Break;
    // The backend can take a moment to finish starting and bind its port
    // after Bridge spawns it - a request landing in that window (most
    // likely right after the daemon itself just started, or right after
    // 'sys.restart') would otherwise get a spurious 502 on an
    // otherwise-healthy setup. A few short retries covers that startup
    // race without masking a genuinely-down backend for long.
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
    Transport.Write(Outgoing[1], Length(Outgoing));
    Result := '';
    repeat
      Received := Transport.Read(Buf[0], SizeOf(Buf));
      if Received > 0 then
      begin
        SetLength(Result, Length(Result) + Received);
        Move(Buf[0], Result[Length(Result) - Received + 1], Received);
      end;
    until Received <= 0;
  finally
    Transport.Close;
    Transport.Free;
  end;

  if Result = '' then
  begin
    ABus.Publish('log.warn', Format('http proxy: empty response from %s:%d', [ARoute.Host, ARoute.Port]), ASourceID);
    Exit(PlainResponse('502 Bad Gateway', 'text/plain', 'Empty response from upstream'));
  end;
  ABus.Publish('log.info', Format('http proxy: %s:%d -> %d bytes', [ARoute.Host, ARoute.Port, Length(Result)]), ASourceID);
end;

function MatchCLIRoute(const APath: string; const ARoutes: TVDRX_CLIRoutes; out AMatch: TVDRX_CLIRoute): Boolean;
var
  i, bestLen: Integer;
begin
  Result := False;
  bestLen := -1;
  for i := 0 to High(ARoutes) do
    if (Copy(APath, 1, Length(ARoutes[i].Prefix)) = ARoutes[i].Prefix) and (Length(ARoutes[i].Prefix) > bestLen) then
    begin
      AMatch := ARoutes[i];
      bestLen := Length(ARoutes[i].Prefix);
      Result := True;
    end;
end;

// Same '..'-rejection posture as ServeStaticFile - a literal-substring check,
// not full canonicalization. Consistent risk level to what's already
// accepted for static files in this codebase; fine for the "not secure yet"
// bar everything else here is at.
function ResolveScriptPath(const APath, APrefix, AScriptDir: string; out AScriptPath: string): Boolean;
var
  Rel: string;
begin
  Result := False;
  Rel := Copy(APath, Length(APrefix) + 1, MaxInt);
  if (Rel = '') or (Pos('..', Rel) > 0) then Exit;
  AScriptPath := IncludeTrailingPathDelimiter(AScriptDir) + Rel;
  Result := FileExists(AScriptPath);
end;

// Spawns ARoute.Command ScriptPath fresh, feeds it a handful of CGI-ish env
// vars (works whether ARoute.Command is plain 'php' - readable via
// getenv()/$_SERVER - or 'php-cgi', which auto-populates $_GET/$_POST from
// them like a real CGI SAPI would), and returns its stdout verbatim as the
// response body. The read loop and TCLIWatchdog run CONCURRENTLY - see the
// type's comment above for why draining stdout can't wait until after the
// process exits.
function RunCLIScript(const ARequest: string; const ARoute: TVDRX_CLIRoute;
  ABus: TVDRX_MessageQueue; const ASourceID: string): string;
var
  Method, Path, ScriptPath, QueryString, HeaderBlock: string;
  Proc: TProcess;
  Watchdog: TCLIWatchdog;
  WatchdogThread: TThread;
  Buf: array[0..4095] of Byte;
  Received, HdrEnd: Integer;
  Output: string;
begin
  ParseRequestLine(ARequest, Method, Path);
  if not ResolveScriptPath(Path, ARoute.Prefix, ARoute.ScriptDir, ScriptPath) then
  begin
    ABus.Publish('log.warn', 'http cli: no script found for "' + Path + '" under ' + ARoute.ScriptDir, ASourceID);
    Exit(PlainResponse('404 Not Found', 'text/plain', 'Not found'));
  end;

  QueryString := ExtractQueryString(ARequest);
  HdrEnd := Pos(#13#10#13#10, ARequest);
  if HdrEnd > 0 then HeaderBlock := Copy(ARequest, 1, HdrEnd - 1) else HeaderBlock := ARequest;

  Proc := TProcess.Create(nil);
  try
    Proc.Executable := ARoute.Command;
    Proc.Parameters.Add(ScriptPath);
    Proc.Environment.Add('REQUEST_METHOD=' + Method);
    Proc.Environment.Add('QUERY_STRING=' + QueryString);
    Proc.Environment.Add('REQUEST_URI=' + Path + IfThen(QueryString <> '', '?' + QueryString, ''));
    Proc.Environment.Add('CONTENT_TYPE=' + ExtractHeaderValue(HeaderBlock, 'Content-Type'));
    Proc.Environment.Add('CONTENT_LENGTH=' + ExtractHeaderValue(HeaderBlock, 'Content-Length'));
    Proc.Options := [poUsePipes, poStderrToOutPut];
    Proc.CurrentDirectory := ARoute.ScriptDir;
    Proc.Execute;

    Watchdog := TCLIWatchdog.Create(Proc, ARoute.TimeoutMs);
    WatchdogThread := TVDRX_WorkerThread.Create(@Watchdog.Run);
    WatchdogThread.FreeOnTerminate := False;
    WatchdogThread.Start;
    try
      Output := '';
      repeat
        Received := Proc.Output.Read(Buf[0], SizeOf(Buf));
        if Received > 0 then
        begin
          SetLength(Output, Length(Output) + Received);
          Move(Buf[0], Output[Length(Output) - Received + 1], Received);
        end;
      until Received <= 0;

      Watchdog.Cancel;
      WaitThreadOrTimeout(WatchdogThread, 500); // polls every 50ms internally - should return almost immediately

      if Watchdog.Fired then
      begin
        ABus.Publish('log.error', Format('http cli: %s exceeded %dms, killed it', [ScriptPath, ARoute.TimeoutMs]), ASourceID);
        Exit(PlainResponse('504 Gateway Timeout', 'text/plain', 'Script timed out'));
      end;
    finally
      WatchdogThread.Free;
      Watchdog.Free;
    end;
  finally
    Proc.Free;
  end;

  ABus.Publish('log.info', Format('http cli: %s -> %d bytes', [ScriptPath, Length(Output)]), ASourceID);
  Result := PlainResponse('200 OK', ARoute.ContentType, Output);
end;

constructor TVDRX_HTTPExecutive.Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config; ATemplates: TVDRX_TemplateStore;
  const AStaticDir: string; const AProxyRoutes: TVDRX_ProxyRoutes; const ACLIRoutes: TVDRX_CLIRoutes);
begin
  inherited Create(ABus);
  FConfig := AConfig;
  FTemplates := ATemplates;
  FStaticDir := AStaticDir;
  FProxyRoutes := AProxyRoutes;
  FCLIRoutes := ACLIRoutes;
  Port := 8081;
end;

class function TVDRX_HTTPExecutive.BuildResponse(const ARequest: string;
  ATemplates: TVDRX_TemplateStore; AConfig: TVDRX_Config; const AStaticDir: string;
  const AProxyRoutes: TVDRX_ProxyRoutes; const ACLIRoutes: TVDRX_CLIRoutes;
  ABus: TVDRX_MessageQueue; const ASourceID: string): string;
var
  Method, Path, BoardName: string;
  Route: TVDRX_ProxyRoute;
  CLIRoute: TVDRX_CLIRoute;
begin
  ParseRequestLine(ARequest, Method, Path);

  if MatchProxyRoute(Path, AProxyRoutes, Route) then
  begin
    ABus.Publish('log.info', Format('http: %s %s -> proxy %s:%d', [Method, Path, Route.Host, Route.Port]), ASourceID);
    Exit(ProxyRequest(ARequest, Route, ABus, ASourceID));
  end;

  if MatchCLIRoute(Path, ACLIRoutes, CLIRoute) then
  begin
    ABus.Publish('log.info', Format('http: %s %s -> cli %s', [Method, Path, CLIRoute.Command]), ASourceID);
    Exit(RunCLIScript(ARequest, CLIRoute, ABus, ASourceID));
  end;

  if Method = 'GET' then
    Result := ServeStaticFile(Path, AStaticDir, ABus, ASourceID)
  else
  begin
    ABus.Publish('log.warn', 'http: unhandled method "' + Method + '" for ' + Path, ASourceID);
    Result := PlainResponse('404 Not Found', 'text/plain', 'Not found');
  end;
end;

procedure TVDRX_HTTPExecutive.HandleConnection(ATransport: TVDRX_Transport);
var
  Request, Response, Method, Path: string;
begin
  Request := ReadFullRequest(ATransport);
  if Request <> '' then
  begin
    ParseRequestLine(Request, Method, Path);
    Response := BuildResponse(Request, FTemplates, FConfig, FStaticDir, FProxyRoutes, FCLIRoutes, Bus, ID);
    Bus.Publish('log.info', Format('http: %s %s -> %s', [Method, Path, StatusOf(Response)]), ID);
    ATransport.Write(Response[1], Length(Response));
  end
  else
    Bus.Publish('log.warn', 'http: connection closed before a request arrived', ID);
  ATransport.Close;
  ATransport.Free;
end;

procedure TVDRX_HTTPExecutive.HandlePacket(const AMsg: TVDRX_Message);
begin
  // HTTP is request/response, not bus-driven - nothing to do here.
end;

procedure TVDRX_HTTPExecutive.ApplyConfig;
var
  NewPort, NewTLSPort: Integer;
  CertFile, KeyFile: string;
begin
  FStaticDir := FConfig.GetString('static_dir', FStaticDir);
  NewPort := FConfig.GetInteger('executives.http.port', 8081);
  NewTLSPort := FConfig.GetInteger('executives.http.tls_port', 0);
  CertFile := FConfig.GetString('executives.http.tls_cert', '');
  KeyFile := FConfig.GetString('executives.http.tls_key', '');
  if (NewPort <> Port) or (NewTLSPort <> TLSPort) then
  begin
    Shutdown;
    Port := NewPort;
    ConfigureTLS(NewTLSPort, CertFile, KeyFile);
    Initialize;
  end;
  // NB: FProxyRoutes is NOT rebuilt here yet - proxy_bridges is only read at
  // startup (see vdrx_daemon.lpr's SetupProxyBridges). A 'sys.reload' picks
  // up template/board-nav/port changes live but not new/changed proxy
  // routes - restart the daemon (or 'sys.restart') for those.
end;

end.
