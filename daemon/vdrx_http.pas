unit vdrx_http;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, Sockets, vdrx_core, vdrx_socketlistener, vdrx_transport,
  vdrx_whiteboard, vdrx_config, vdrx_templates, Generics.Collections;

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

  TVDRX_HTTPExecutive = class(TVDRX_SocketListenerExecutive)
  private
    FConfig: TVDRX_Config;
    FWhiteboard: TVDRX_WhiteboardExecutive;
    FTemplates: TVDRX_TemplateStore;
    FStaticDir: string;
    FProxyRoutes: TVDRX_ProxyRoutes;
  protected
    procedure HandleConnection(ATransport: TVDRX_Transport); override;
  public
    constructor Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config;
      AWhiteboard: TVDRX_WhiteboardExecutive; ATemplates: TVDRX_TemplateStore;
      const AStaticDir: string; const AProxyRoutes: TVDRX_ProxyRoutes); reintroduce;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    procedure ApplyConfig; override;
    class function BuildResponse(const ARequest: string; AWhiteboard: TVDRX_WhiteboardExecutive;
      ATemplates: TVDRX_TemplateStore; AConfig: TVDRX_Config; const AStaticDir: string;
      const AProxyRoutes: TVDRX_ProxyRoutes; ABus: TVDRX_MessageQueue; const ASourceID: string): string;
  end;

implementation

const
  MAX_HEADER_SIZE = 16384;
  MAX_BODY_SIZE = 10 * 1024 * 1024; // generous for dev/test form posts - not meant for large uploads

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

function RenderBoardPage(const ABoardName: string; AWhiteboard: TVDRX_WhiteboardExecutive;
  ATemplates: TVDRX_TemplateStore; AConfig: TVDRX_Config; ABus: TVDRX_MessageQueue; const ASourceID: string): string;
var
  BoardJSON, Body: string;
  Params: TStringList;
  Rows: TVDRX_TemplateNamedRows;
  BoardRows: TVDRX_TemplateRows;
  Names: TStringArray;
  i: Integer;
  Row: TStringList;
begin
  BoardJSON := AWhiteboard.GetBoardSnapshot(ABoardName);
  ABus.Publish('log.info', Format('http: board "%s" snapshot is %d bytes', [ABoardName, Length(BoardJSON)]), ASourceID);

  Params := TStringList.Create;
  try
    Params.Values['board_name'] := ABoardName;
    Params.Values['board_json'] := BoardJSON;
    Params.Values['ws_port'] := IntToStr(AConfig.GetInteger('executives.ws.port', 8082));
    Params.Values['ws_host_json'] := '""';
    Params.Values['ws_tls_json'] := IfThen(AConfig.GetInteger('executives.ws.tls_port', 0) <> 0, 'true', 'false');

    Rows := TVDRX_TemplateNamedRows.Create([doOwnsValues]);
    try
      BoardRows := TVDRX_TemplateRows.Create;
      Names := AWhiteboard.ListBoardNames;
      for i := 0 to High(Names) do
      begin
        Row := TStringList.Create;
        Row.Values['name'] := Names[i];
        Row.Values['active_class'] := IfThen(Names[i] = ABoardName, 'active', '');
        BoardRows.Add(Row);
      end;
      Rows.Add('boards', BoardRows);

      Body := ATemplates.Fill('dashboard', Params, Rows);
    finally
      Rows.Free;
    end;
  finally
    Params.Free;
  end;

  if Body = '' then
  begin
    ABus.Publish('log.error', 'http: dashboard.tpl produced no output - check template_dir', ASourceID);
    Exit(PlainResponse('500 Internal Server Error', 'text/plain',
      'Missing template: dashboard.tpl (check template_dir in vdrx_daemon.conf)'));
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
var
  Transport: TVDRX_Transport;
  Buf: array[0..8191] of Byte;
  Received: Integer;
  Outgoing: string;
begin
  Transport := ConnectTCP(ARoute.Host, ARoute.Port);
  if not Assigned(Transport) then
  begin
    ABus.Publish('log.error', Format('http proxy: could not connect to %s:%d - is the bridge process up? (check its own log lines above, and "kill <bridge-id>" / restart if it looks wedged)', [ARoute.Host, ARoute.Port]), ASourceID);
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

constructor TVDRX_HTTPExecutive.Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config;
  AWhiteboard: TVDRX_WhiteboardExecutive; ATemplates: TVDRX_TemplateStore;
  const AStaticDir: string; const AProxyRoutes: TVDRX_ProxyRoutes);
begin
  inherited Create(ABus);
  FConfig := AConfig;
  FWhiteboard := AWhiteboard;
  FTemplates := ATemplates;
  FStaticDir := AStaticDir;
  FProxyRoutes := AProxyRoutes;
  Port := 8081;
end;

class function TVDRX_HTTPExecutive.BuildResponse(const ARequest: string; AWhiteboard: TVDRX_WhiteboardExecutive;
  ATemplates: TVDRX_TemplateStore; AConfig: TVDRX_Config; const AStaticDir: string;
  const AProxyRoutes: TVDRX_ProxyRoutes; ABus: TVDRX_MessageQueue; const ASourceID: string): string;
var
  Method, Path, BoardName: string;
  Route: TVDRX_ProxyRoute;
begin
  ParseRequestLine(ARequest, Method, Path);

  if MatchProxyRoute(Path, AProxyRoutes, Route) then
  begin
    ABus.Publish('log.info', Format('http: %s %s -> proxy %s:%d', [Method, Path, Route.Host, Route.Port]), ASourceID);
    Exit(ProxyRequest(ARequest, Route, ABus, ASourceID));
  end;

  if (Method = 'GET') and (Copy(Path, 1, 7) = '/board/') then
  begin
    BoardName := Copy(Path, 8, MaxInt);
    if not IsValidBoardName(BoardName) then
    begin
      ABus.Publish('log.warn', 'http: rejected invalid board name "' + BoardName + '"', ASourceID);
      Exit(PlainResponse('400 Bad Request', 'text/plain', 'Invalid board name'));
    end;
    Result := RenderBoardPage(BoardName, AWhiteboard, ATemplates, AConfig, ABus, ASourceID);
  end
  else if Method = 'GET' then
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
    Response := BuildResponse(Request, FWhiteboard, FTemplates, FConfig, FStaticDir, FProxyRoutes, Bus, ID);
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
