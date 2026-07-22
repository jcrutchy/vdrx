unit vrdx_http;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Sockets, vrdx_core, vrdx_socketlistener, vrdx_whiteboard;

type
  // Request/response, synchronous - deliberately does NOT round-trip through the
  // bus. Reads board state directly via TVRDX_WhiteboardExecutive.GetBoardSnapshot,
  // so the client gets a full initial render with no flash-of-empty-board before its
  // WebSocket connection's live deltas start arriving. Accept loop and
  // per-connection threading come from TVRDX_SocketListenerExecutive.
  TVRDX_HTTPExecutive = class(TVRDX_SocketListenerExecutive)
  private
    FWhiteboard: TVRDX_WhiteboardExecutive;
  protected
    procedure HandleConnection(ASock: TSocket); override;
  public
    constructor Create(ABus: TVRDX_MessageQueue; AWhiteboard: TVRDX_WhiteboardExecutive); reintroduce;
    procedure HandlePacket(const AMsg: TVRDX_Message); override;
    // Pure request -> response logic, reusable by anything that's already read the
    // initial bytes off the wire (e.g. the combined HTTP/WS listener) and doesn't
    // want a second fpRecv on the same socket.
    class function BuildResponse(const ARequest: string; AWhiteboard: TVRDX_WhiteboardExecutive): string;
  end;

implementation

constructor TVRDX_HTTPExecutive.Create(ABus: TVRDX_MessageQueue; AWhiteboard: TVRDX_WhiteboardExecutive);
begin
  inherited Create(ABus);
  FWhiteboard := AWhiteboard;
  Port := 8081;
end;

class function TVRDX_HTTPExecutive.BuildResponse(const ARequest: string; AWhiteboard: TVRDX_WhiteboardExecutive): string;
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

procedure TVRDX_HTTPExecutive.HandleConnection(ASock: TSocket);
var
  Buf: array[0..1023] of Byte;
  Received: Integer;
  Request, Response: string;
begin
  Received := fpRecv(ASock, @Buf[0], SizeOf(Buf), 0);
  if Received > 0 then
  begin
    SetString(Request, PAnsiChar(@Buf[0]), Received);
    Response := BuildResponse(Request, FWhiteboard);
    fpSend(ASock, @Response[1], Length(Response), 0);
  end;
  CloseSocket(ASock);
end;

procedure TVRDX_HTTPExecutive.HandlePacket(const AMsg: TVRDX_Message);
begin
  // HTTP is request/response, not bus-driven - nothing to do here.
end;

end.
