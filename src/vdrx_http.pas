unit vdrx_http;

{$mode ObjFPC}{$H+}

// The HTTP server executive and per-connection handler; hands WebSocket upgrades on a shared port to 
// vdrx_websocket.

interface

uses
  Classes, SysUtils, StrUtils, openssl, {$IFDEF UNIX}BaseUnix, {$ENDIF} dynlibs, fpjson, jsonparser, vdrx_core, vdrx_config, vdrx_templates, vdrx_transport, vdrx_iplimit, vdrx_httpparse, vdrx_connection, vdrx_websocket, vdrx_httproute;

type

  TVDRX_HTTPExecutive = class(TVDRX_SocketListenerExecutive)
  private
    FConfig: TVDRX_Config;
    FTemplates: TVDRX_TemplateStore;
    FStaticDir: string;
    FRoutes: TVDRX_RouteTable;
    FRegistry: TVDRX_Registry;
    FCustomHeaders: TStringList;
    FWebSocket: TVDRX_WebSocketExecutive;
    FWebSocketPath: string;
    FSecurityHeaders: Boolean;
    FHSTSMaxAge: Integer;
    FTrustedProxies: TVDRX_IPMatcher;
    procedure BuildEffectiveHeaders(AList: TStringList; ASecure: Boolean);
  protected
    procedure HandleConnection(ATransport: TVDRX_Transport); override;
  public
    constructor Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config;
      ATemplates: TVDRX_TemplateStore;
      const AStaticDir: string; const ARoutes: TVDRX_RouteTable;
      ARegistry: TVDRX_Registry); reintroduce;
    destructor Destroy; override;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    procedure ApplyConfig; override;
    property CustomHeaders: TStringList read FCustomHeaders;
    // Default response headers that cost nothing and close common browser-side holes: X-Content-Type-Options:
    // nosniff, X-Frame-Options: SAMEORIGIN, Referrer-Policy. A header of the same name in "headers" wins.
    property SecurityHeaders: Boolean read FSecurityHeaders write FSecurityHeaders;
    // Seconds for Strict-Transport-Security on responses sent over TLS; 0 = not sent. Browsers remember it,
    // so turn it on only once every name that site serves works over https.
    property HSTSMaxAge: Integer read FHSTSMaxAge write FHSTSMaxAge;
    // Peers whose X-Forwarded-For / Forwarded / X-Real-IP headers are believed and passed on (and extended with
    // the peer's own address when proxying). For every other client those headers are deleted.
    property TrustedProxies: TVDRX_IPMatcher read FTrustedProxies;
    // Shared port: a WebSocket upgrade request for exactly WebSocketPath on this site is handed to
    // WebSocket (same profiles, lockout, limits and Origin check as the WS port). nil / '' = off.
    property WebSocket: TVDRX_WebSocketExecutive read FWebSocket write FWebSocket;
    property WebSocketPath: string read FWebSocketPath write FWebSocketPath;
    class function BuildResponse(const ARequest: string;
      ATemplates: TVDRX_TemplateStore; AConfig: TVDRX_Config; const AStaticDir: string;
      const ARoutes: TVDRX_RouteTable; const AConn: TVDRX_ConnInfo;
      ABus: TVDRX_MessageQueue; ARegistry: TVDRX_Registry; const ASourceID: string;
      var AStreamFile: string; var AStreamSize: Int64;
      ACustomHeaders: TStringList = nil): string;
  end;

  TVDRX_HTTPConnection = class(TVDRX_ConnectionExecutive)
  private
    FTemplates: TVDRX_TemplateStore;
    FConfig: TVDRX_Config;
    FStaticDir: string;
    FRoutes: TVDRX_RouteTable;
    FConn: TVDRX_ConnInfo;
    FRegistry: TVDRX_Registry;
    FSourceID: string;
    FCustomHeaders: TStringList;
    FWebSocket: TVDRX_WebSocketExecutive;
    FWebSocketPath: string;
    FTrustForwarded: Boolean;
  public
    property WebSocket: TVDRX_WebSocketExecutive read FWebSocket write FWebSocket;
    property WebSocketPath: string read FWebSocketPath write FWebSocketPath;
    // False (the default): client-supplied X-Forwarded-For & co. are removed before anything sees the request.
    property TrustForwarded: Boolean read FTrustForwarded write FTrustForwarded;
    constructor Create(ABus: TVDRX_MessageQueue; ATransport: TVDRX_Transport;
      ATemplates: TVDRX_TemplateStore; AConfig: TVDRX_Config; const AStaticDir: string;
      const ARoutes: TVDRX_RouteTable; const AConn: TVDRX_ConnInfo;
      ARegistry: TVDRX_Registry; const ASourceID: string;
      ACustomHeaders: TStringList = nil); reintroduce;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    procedure Run(const ARequest: string = '');
  end;

implementation

constructor TVDRX_HTTPExecutive.Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config; ATemplates: TVDRX_TemplateStore;
  const AStaticDir: string; const ARoutes: TVDRX_RouteTable;
  ARegistry: TVDRX_Registry);
begin
  inherited Create(ABus);
  FConfig := AConfig;
  FTemplates := ATemplates;
  FStaticDir := AStaticDir;
  FRoutes := ARoutes;
  FRegistry := ARegistry;
  FCustomHeaders := TStringList.Create;
  FSecurityHeaders := True;
  FTrustedProxies := TVDRX_IPMatcher.Create;
  Port := 8081;
end;

destructor TVDRX_HTTPExecutive.Destroy;
begin
  FCustomHeaders.Free;
  FTrustedProxies.Free;
  inherited Destroy;
end;

// Headers for ONE connection: the defaults, HSTS on TLS, then the site's own "headers" (which win).
// A private list per connection, so a sys.reload that rebuilds the shared one cannot change it mid-response.
procedure TVDRX_HTTPExecutive.BuildEffectiveHeaders(AList: TStringList; ASecure: Boolean);
var
  i: Integer;
begin
  if FSecurityHeaders then
  begin
    AList.Values['X-Content-Type-Options'] := 'nosniff';
    AList.Values['X-Frame-Options'] := 'SAMEORIGIN';
    AList.Values['Referrer-Policy'] := 'strict-origin-when-cross-origin';
  end;
  if ASecure and (FHSTSMaxAge > 0) then
    AList.Values['Strict-Transport-Security'] := 'max-age=' + IntToStr(FHSTSMaxAge);
  for i := 0 to FCustomHeaders.Count - 1 do
    if FCustomHeaders.Names[i] <> '' then
      AList.Values[FCustomHeaders.Names[i]] := FCustomHeaders.ValueFromIndex[i]
    else if Trim(FCustomHeaders[i]) <> '' then
      AList.Add(FCustomHeaders[i]);
end;

class function TVDRX_HTTPExecutive.BuildResponse(const ARequest: string;
  ATemplates: TVDRX_TemplateStore; AConfig: TVDRX_Config; const AStaticDir: string;
  const ARoutes: TVDRX_RouteTable; const AConn: TVDRX_ConnInfo;
  ABus: TVDRX_MessageQueue; ARegistry: TVDRX_Registry; const ASourceID: string;
  var AStreamFile: string; var AStreamSize: Int64;
  ACustomHeaders: TStringList): string;
var
  Method, Path, OrigTarget, Request, Location: string;
  ScriptName, ScriptFile, PathInfo, StaticPath: string;
  Query: string;
  RedirectStatus: Integer;
  Route: TVDRX_ProxyRoute;
  BusRoute: TVDRX_BusRoute;
begin
  OrigTarget := RequestTarget(ARequest);
  ParseRequestLine(ARequest, Method, Path);

  // Fast-path CORS preflight probe
  if Method = 'OPTIONS' then
  begin
    ABus.Publish('log.info', Format('http: %s %s -> 204 No Content (preflight)', [Method, Path]), ASourceID);
    Exit(PlainResponse('204 No Content', 'text/plain', '', ACustomHeaders));
  end;

  // 1. rewrites - from here on the (possibly rewritten) request is what gets routed;
  //    the envelope still carries the client's original URI as request_uri.
  Request := ARequest;
  if Length(ARoutes.Rewrites) > 0 then
  begin
    if ApplyRewrites(ARequest, ARoutes.Rewrites, Request, Location, RedirectStatus) then
    begin
      ABus.Publish('log.info', Format('http: %s %s -> %d redirect to %s', [Method, Path, RedirectStatus, Location]), ASourceID);
      Exit(RedirectResponse(RedirectStatus, Location, ACustomHeaders));
    end;
    if Request <> ARequest then
    begin
      ParseRequestLine(Request, Method, Path);
      ABus.Publish('log.info', Format('http: rewrote %s -> %s', [OrigTarget, RequestTarget(Request)]), ASourceID);
    end;
  end;

  // 2. reverse-proxy routes (processes with a prefix)
  if MatchProxyRoute(Path, ARoutes.Proxy, Route) then
  begin
    ABus.Publish('log.info', Format('http: %s %s -> proxy %s:%d', [Method, Path, Route.Host, Route.Port]), ASourceID);
    Exit(ProxyRequest(Request, Route, ABus, ASourceID, AConn.RemoteAddr, AConn.Secure));
  end;

  // 3. bus routes: http_routes and cgi entries
  if MatchBusRoute(Path, ARoutes.Bus, BusRoute) then
  begin
    ScriptName := '';
    ScriptFile := '';
    PathInfo := '';
    if SameText(BusRoute.Kind, 'cgi') then
    begin
      case ResolveCGITarget(Path, BusRoute, ScriptName, ScriptFile, PathInfo, StaticPath) of
        crScript: ;   // fall through to RunBusRoute below
        crStatic:
          begin
            if (Method <> 'GET') and (Method <> 'HEAD') then
              Exit(PlainResponse('405 Method Not Allowed', 'text/plain', 'Method not allowed', ACustomHeaders));
            Exit(ServeStaticFile(StaticPath, BusRoute.DocRoot, ABus, ASourceID, AStreamFile, AStreamSize, ACustomHeaders));
          end;
        crRedirectSlash:
          begin
            Query := ExtractQueryString(Request);
            Exit(RedirectResponse(301, Path + '/' + IfThen(Query <> '', '?' + Query, ''), ACustomHeaders));
          end;
        crForbidden:
          begin
            ABus.Publish('log.warn', Format('http: %s %s -> 403 (path refused under %s)', [Method, Path, BusRoute.DocRoot]), ASourceID);
            Exit(PlainResponse('403 Forbidden', 'text/plain', 'Forbidden', ACustomHeaders));
          end;
      else
        ABus.Publish('log.warn', Format('http: %s %s -> 404 (nothing under %s)', [Method, Path, BusRoute.DocRoot]), ASourceID);
        Exit(PlainResponse('404 Not Found', 'text/plain', 'Not found', ACustomHeaders));
      end;
    end;
    ABus.Publish('log.info', Format('http: %s %s -> route "%s" (%s) -> %s', [Method, Path, BusRoute.ID, BusRoute.Kind, BusRoute.InTopic]), ASourceID);
    Exit(InjectCustomHeaders(RunBusRoute(Request, OrigTarget, BusRoute, AConn, ScriptName, ScriptFile, PathInfo,
      ATemplates, ABus, ARegistry, ASourceID), ACustomHeaders));
  end;

  // 4. the site's own static_dir
  if (Method = 'GET') or (Method = 'HEAD') then
    Result := ServeStaticFile(Path, AStaticDir, ABus, ASourceID, AStreamFile, AStreamSize, ACustomHeaders)
  else
  begin
    ABus.Publish('log.warn', 'http: unhandled method "' + Method + '" for ' + Path, ASourceID);
    Result := PlainResponse('404 Not Found', 'text/plain', 'Not found', ACustomHeaders);
  end;
end;

{ TVDRX_HTTPConnection }

constructor TVDRX_HTTPConnection.Create(ABus: TVDRX_MessageQueue; ATransport: TVDRX_Transport;
  ATemplates: TVDRX_TemplateStore; AConfig: TVDRX_Config; const AStaticDir: string;
  const ARoutes: TVDRX_RouteTable; const AConn: TVDRX_ConnInfo;
  ARegistry: TVDRX_Registry; const ASourceID: string; ACustomHeaders: TStringList);
begin
  inherited Create(ABus);
  FTransport := ATransport;
  FTemplates := ATemplates;
  FConfig := AConfig;
  FStaticDir := AStaticDir;
  FRoutes := ARoutes;
  FConn := AConn;
  FRegistry := ARegistry;
  FSourceID := ASourceID;
  FCustomHeaders := ACustomHeaders;
end;

procedure TVDRX_HTTPConnection.HandlePacket(const AMsg: TVDRX_Message);
begin
end;

procedure TVDRX_HTTPConnection.Run(const ARequest: string);
var
  Request, Response, Method, Path: string;
  HeadEnd, Sent, N, p: Integer;
  Head, PathOnly, StreamFile: string;
  StreamSize: Int64;
  Deadline: QWord;
  TooLarge, TimedOut: Boolean;
  BadStatus, BadWhy: string;
begin
  TooLarge := False;
  TimedOut := False;
  BadStatus := '';
  BadWhy := '';
  if ARequest <> '' then
    Request := ARequest
  else
    Request := ReadFullRequest(FTransport, TooLarge, TimedOut, BadStatus, BadWhy);
  // "Who is the client" headers are only believed from a configured trusted proxy (see TrustedProxies).
  if (Request <> '') and (BadStatus = '') and not FTrustForwarded then
    Request := StripForwardedHeaders(Request);

  if BadStatus <> '' then
  begin
    Bus.Publish('log.warn', 'http: rejected request - ' + BadStatus + ': ' + BadWhy, FSourceID);
    Response := PlainResponse(BadStatus, 'text/plain', BadStatus + #10);
    Sent := 0;
    while Sent < Length(Response) do
    begin
      N := FTransport.Write(Response[Sent + 1], Length(Response) - Sent);
      if N <= 0 then Break;
      Inc(Sent, N);
    end;
  end
  else if TooLarge then
  begin
    Bus.Publish('log.warn', 'http: request body exceeds the configured limit - 413', FSourceID);
    Response := PlainResponse('413 Payload Too Large', 'text/plain',
      'Request body exceeds the configured limit.');
    Sent := 0;
    while Sent < Length(Response) do
    begin
      N := FTransport.Write(Response[Sent + 1], Length(Response) - Sent);
      if N <= 0 then Break;
      Inc(Sent, N);
    end;
  end
  else if TimedOut then
  begin
    // The client started a request and then stalled (slow-loris) - say so and hang up.
    Bus.Publish('log.info', 'http: request not completed in time - 408', FSourceID);
    Response := PlainResponse('408 Request Timeout', 'text/plain', 'Request not completed in time.');
    Sent := 0;
    while Sent < Length(Response) do
    begin
      N := FTransport.Write(Response[Sent + 1], Length(Response) - Sent);
      if N <= 0 then Break;
      Inc(Sent, N);
    end;
  end
  else if Request <> '' then
  begin
    ParseRequestLine(Request, Method, Path);
    if (FWebSocket <> nil) and (FWebSocketPath <> '') and (Method = 'GET') then
    begin
      Head := Copy(Request, 1, Pos(#13#10#13#10, Request));
      PathOnly := Path;
      p := Pos('?', PathOnly);
      if p > 0 then SetLength(PathOnly, p - 1);
      if (PathOnly = FWebSocketPath) and ValueHasToken(ExtractHeaderValue(Head, 'Upgrade'), 'websocket') then
      begin
        if ValueHasToken(ExtractHeaderValue(Head, 'Connection'), 'upgrade') and
           (ExtractHeaderValue(Head, 'Sec-WebSocket-Key') <> '') and
           (ExtractHeaderValue(Head, 'Sec-WebSocket-Version') = '13') then
        begin
          // Hand the connection over. From here the WebSocket code owns the transport (it also
          // answers the handshake); this HTTP connection must neither close nor free it.
          Bus.Publish('log.info', 'http: ' + Path + ' -> WebSocket upgrade', FSourceID);
          FWebSocket.AdoptConnection(FTransport, Request);
          FTransport := nil;
          Exit;
        end;
        Response := 'HTTP/1.1 426 Upgrade Required'#13#10'Sec-WebSocket-Version: 13'#13#10 +
          'Connection: close'#13#10'Content-Length: 0'#13#10#13#10;
        FTransport.Write(Response[1], Length(Response));
        FTransport.Close;
        Exit;
      end;
    end;
    StreamFile := '';
    StreamSize := 0;
    Response := TVDRX_HTTPExecutive.BuildResponse(Request, FTemplates, FConfig, FStaticDir,
      FRoutes, FConn, Bus, FRegistry, FSourceID, StreamFile, StreamSize, FCustomHeaders);
    Bus.Publish('log.info', Format('http: %s %s -> %s', [Method, Path, StatusOf(Response)]), FSourceID);
    if Method = 'HEAD' then
    begin
      // headers only (Content-Length still describes the body a GET would return)
      HeadEnd := Pos(#13#10#13#10, Response);
      if HeadEnd > 0 then SetLength(Response, HeadEnd + 3);
      StreamFile := '';                      // HEAD: never the body
    end;
    // A client that stops reading must not hold this thread (and a connection slot) for ever: each
    // write may stall for at most http_write_timeout_ms, the whole response takes at most
    // http_response_timeout_ms.
    if HTTPWriteTimeoutMs > 0 then FTransport.SetWriteTimeout(HTTPWriteTimeoutMs);
    if HTTPResponseTimeoutMs > 0 then Deadline := GetTickCount64 + QWord(HTTPResponseTimeoutMs) else Deadline := 0;
    // send() may accept fewer bytes than offered (big bodies, send timeout)
    Sent := 0;
    while Sent < Length(Response) do
    begin
      if (Deadline > 0) and (GetTickCount64 > Deadline) then N := 0
      else N := FTransport.Write(Response[Sent + 1], Length(Response) - Sent);
      if N <= 0 then
      begin
        Bus.Publish('log.warn', Format('http: %s %s - client went away or stopped reading after %d of %d bytes', [Method, Path, Sent, Length(Response)]), FSourceID);
        StreamFile := '';
        Break;
      end;
      Inc(Sent, N);
    end;
    if StreamFile <> '' then
    begin
      N := Integer(StreamFileBody(FTransport, StreamFile, StreamSize, Deadline) = StreamSize);
      if N = 0 then
        Bus.Publish('log.warn', Format('http: %s %s - the %d-byte file was not fully sent (client stopped reading, went away, or the file changed)', [Method, Path, StreamSize]), FSourceID);
    end;
  end
  else
    Bus.Publish('log.warn', 'http: connection closed before a request arrived', FSourceID);
  FTransport.Close;
end;

procedure TVDRX_HTTPExecutive.HandleConnection(ATransport: TVDRX_Transport);
var
  Conn: TVDRX_HTTPConnection;
  Info: TVDRX_ConnInfo;
  Headers: TStringList;
begin
  Info.RemoteAddr := ATransport.PeerAddr;
  Info.RemotePort := ATransport.PeerPort;
  Info.Secure := ATransport.Secure;
  if Info.Secure then Info.ServerPort := TLSPort else Info.ServerPort := Port;
  Headers := TStringList.Create;
  BuildEffectiveHeaders(Headers, Info.Secure);
  Conn := TVDRX_HTTPConnection.Create(Bus, ATransport, FTemplates, FConfig, FStaticDir,
    FRoutes, Info, FRegistry, ID, Headers);
  Conn.WebSocket := FWebSocket;
  Conn.WebSocketPath := FWebSocketPath;
  Conn.TrustForwarded := FTrustedProxies.Matches(Info.RemoteAddr);
  try
    Conn.Run;
  finally
    Conn.Free;
    Headers.Free;
  end;
end;

procedure TVDRX_HTTPExecutive.HandlePacket(const AMsg: TVDRX_Message);
begin
end;

function FindConfigRowByID(AConfig: TVDRX_Config; const AArrayKey, AID: string;
  out ARow: TStringList): Boolean;
var
  Rows: TVDRX_ConfigRows;
  Row: TStringList;
begin
  Result := False;
  Rows := AConfig.GetObjectArray(AArrayKey);
  try
    for Row in Rows do
      if Row.Values['id'] = AID then
      begin
        ARow := TStringList.Create;
        ARow.Assign(Row);
        Exit(True);
      end;
  finally
    Rows.Free;
  end;
end;

procedure TVDRX_HTTPExecutive.ApplyConfig;
var
  NewPort, NewTLSPort, i: Integer;
  CertFile, KeyFile, RawHeaders: string;
  SiteRow: TStringList;
  HeadersJSON: TJSONData;
  HeadersObj: TJSONObject;
begin
  if not FindConfigRowByID(FConfig, 'http_sites', ID, SiteRow) then
  begin
    Bus.Publish('log.warn', 'http ' + ID + ': no matching http_sites entry found on reload - config for this site is unchanged', ID);
    Exit;
  end;
  try
    FStaticDir := ExpandFileName(IfThen(SiteRow.Values['static_dir'] <> '', SiteRow.Values['static_dir'], 'static'));
    NewPort := StrToIntDef(SiteRow.Values['port'], Port);
    NewTLSPort := StrToIntDef(SiteRow.Values['tls_port'], 0);
    CertFile := SiteRow.Values['tls_cert'];
    KeyFile := SiteRow.Values['tls_key'];

    FSecurityHeaders := not VDRX_IsFalseText(SiteRow.Values['security_headers']);
    FHSTSMaxAge := StrToIntDef(SiteRow.Values['hsts_max_age'], 0);
    FCustomHeaders.Clear;
    if (SiteRow.Values['cors'] = 'True') or (SiteRow.Values['cors'] = 'true') or (SiteRow.Values['cors'] = '1') then
    begin
      FCustomHeaders.Values['Access-Control-Allow-Origin'] := '*';
      FCustomHeaders.Values['Access-Control-Allow-Methods'] := 'GET, POST, OPTIONS';
      FCustomHeaders.Values['Access-Control-Allow-Headers'] := '*';
    end;

    RawHeaders := SiteRow.Values['headers'];
    if RawHeaders <> '' then
    begin
      try
        HeadersJSON := GetJSON(RawHeaders);
        try
          if HeadersJSON is TJSONObject then
          begin
            HeadersObj := TJSONObject(HeadersJSON);
            for i := 0 to HeadersObj.Count - 1 do
              FCustomHeaders.Values[HeadersObj.Names[i]] := HeadersObj.Items[i].AsString;
          end;
        finally
          HeadersJSON.Free;
        end;
      except
      end;
    end;
  finally
    SiteRow.Free;
  end;

  if (NewPort <> Port) or (NewTLSPort <> TLSPort) then
  begin
    Shutdown;
    Port := NewPort;
    ConfigureTLS(NewTLSPort, CertFile, KeyFile);
    Initialize;
  end;
end;

end.
