unit vdrx_http;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, Sockets, vdrx_core, vdrx_socketlistener, vdrx_transport,
  vdrx_whiteboard, vdrx_config, vdrx_templates, Generics.Collections;

type
  TVDRX_HTTPExecutive = class(TVDRX_SocketListenerExecutive)
  private
    FConfig: TVDRX_Config;
    FWhiteboard: TVDRX_WhiteboardExecutive;
    FTemplates: TVDRX_TemplateStore;
    FStaticDir: string;
  protected
    procedure HandleConnection(ATransport: TVDRX_Transport); override;
  public
    constructor Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config;
      AWhiteboard: TVDRX_WhiteboardExecutive; ATemplates: TVDRX_TemplateStore;
      const AStaticDir: string); reintroduce;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    procedure ApplyConfig; override;
    class function BuildResponse(const ARequest: string; AWhiteboard: TVDRX_WhiteboardExecutive;
      ATemplates: TVDRX_TemplateStore; AConfig: TVDRX_Config; const AStaticDir: string;
      ABus: TVDRX_MessageQueue; const ASourceID: string): string;
  end;

implementation

function PlainResponse(const AStatus, AContentType, ABody: string): string;
begin
  Result := 'HTTP/1.1 ' + AStatus + #13#10 +
            'Content-Type: ' + AContentType + #13#10 +
            'Content-Length: ' + IntToStr(Length(ABody)) + #13#10#13#10 + ABody;
end;

// First line only, e.g. '200 OK' from 'HTTP/1.1 200 OK\r\n...' - just for logging.
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
      ABus.Publish('log.info', Format('http: nav shows %d known board(s)', [BoardRows.Count]), ASourceID);

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

constructor TVDRX_HTTPExecutive.Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config;
  AWhiteboard: TVDRX_WhiteboardExecutive; ATemplates: TVDRX_TemplateStore; const AStaticDir: string);
begin
  inherited Create(ABus);
  FConfig := AConfig;
  FWhiteboard := AWhiteboard;
  FTemplates := ATemplates;
  FStaticDir := AStaticDir;
  Port := 8081;
end;

class function TVDRX_HTTPExecutive.BuildResponse(const ARequest: string; AWhiteboard: TVDRX_WhiteboardExecutive;
  ATemplates: TVDRX_TemplateStore; AConfig: TVDRX_Config; const AStaticDir: string;
  ABus: TVDRX_MessageQueue; const ASourceID: string): string;
var
  Method, Path, BoardName: string;
begin
  ParseRequestLine(ARequest, Method, Path);

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
  Buf: array[0..1023] of Byte;
  Received: Integer;
  Request, Response, Method, Path: string;
begin
  Received := ATransport.Read(Buf[0], SizeOf(Buf));
  if Received > 0 then
  begin
    SetString(Request, PAnsiChar(@Buf[0]), Received);
    ParseRequestLine(Request, Method, Path);
    Response := BuildResponse(Request, FWhiteboard, FTemplates, FConfig, FStaticDir, Bus, ID);
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
end;

end.
