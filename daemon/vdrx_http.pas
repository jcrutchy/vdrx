unit vdrx_http;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Sockets, vdrx_core, vdrx_socketlistener, vdrx_transport,
  vdrx_whiteboard, vdrx_config;

type
  // Request/response, synchronous - deliberately does NOT round-trip through the
  // bus. Reads board state directly via TVDRX_WhiteboardExecutive.GetBoardSnapshot,
  // so the client gets a full initial render with no flash-of-empty-board before its
  // WebSocket connection's live deltas start arriving. Accept loop, per-connection
  // threading, and plain-vs-TLS transport selection all come from
  // TVDRX_SocketListenerExecutive.
  TVDRX_HTTPExecutive = class(TVDRX_SocketListenerExecutive)
  private
    FConfig: TVDRX_Config;
    FWhiteboard: TVDRX_WhiteboardExecutive;
  protected
    procedure HandleConnection(ATransport: TVDRX_Transport); override;
  public
    constructor Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config;
      AWhiteboard: TVDRX_WhiteboardExecutive); reintroduce;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    procedure ApplyConfig; override;
    // Pure request -> response logic, reusable by anything that's already read the
    // initial bytes off the wire (e.g. the combined HTTP/WS listener) and doesn't
    // want a second Read on the same connection.
    class function BuildResponse(const ARequest: string; AWhiteboard: TVDRX_WhiteboardExecutive): string;
  end;

implementation

constructor TVDRX_HTTPExecutive.Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config;
  AWhiteboard: TVDRX_WhiteboardExecutive);
begin
  inherited Create(ABus);
  FConfig := AConfig;
  FWhiteboard := AWhiteboard;
  Port := 8081;
end;

class function TVDRX_HTTPExecutive.BuildResponse(const ARequest: string; AWhiteboard: TVDRX_WhiteboardExecutive): string;
var
  Body, BoardJSON: string;
begin
  if Pos('GET /board/board1', ARequest) = 1 then
  begin
    BoardJSON := AWhiteboard.GetBoardSnapshot('board1'); // one synchronous call, no bus round-trip
    Body := '<!doctype html><html><body>' +
            '<script>window.__INITIAL_BOARD__=' + BoardJSON + ';</script>' +
            '<div id="board"></div>' +
            '<script src="/dashboard.js"></script></body></html>';
    Result := 'HTTP/1.1 200 OK'#13#10 +
              'Content-Type: text/html'#13#10 +
              'Content-Length: ' + IntToStr(Length(Body)) + #13#10#13#10 + Body;
  end
  else
    Result := 'HTTP/1.1 404 Not Found'#13#10#13#10;
end;

procedure TVDRX_HTTPExecutive.HandleConnection(ATransport: TVDRX_Transport);
var
  Buf: array[0..1023] of Byte;
  Received: Integer;
  Request, Response: string;
begin
  Received := ATransport.Read(Buf[0], SizeOf(Buf));
  if Received > 0 then
  begin
    SetString(Request, PAnsiChar(@Buf[0]), Received);
    Response := BuildResponse(Request, FWhiteboard);
    ATransport.Write(Response[1], Length(Response));
  end;
  ATransport.Close;
  ATransport.Free;
end;

procedure TVDRX_HTTPExecutive.HandlePacket(const AMsg: TVDRX_Message);
begin
  // HTTP is request/response, not bus-driven - nothing to do here.
end;

// Same restart-on-change pattern as TVDRX_IRCDExecutive.ApplyConfig - Shutdown then
// Initialize (inherited from TVDRX_SocketListenerExecutive) already handles tearing
// down and rebinding both the plain and TLS listeners cleanly, so reuse that rather
// than duplicating socket-lifecycle logic here.
procedure TVDRX_HTTPExecutive.ApplyConfig;
var
  NewPort, NewTLSPort: Integer;
  CertFile, KeyFile: string;
begin
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
