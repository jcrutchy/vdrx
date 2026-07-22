unit vrdx_weblistener;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Sockets, vrdx_core, vrdx_socketlistener, vrdx_http,
  vrdx_websocket, vrdx_whiteboard;

type
  // Optional: binds ONE port and routes each connection to plain HTTP handling or a
  // WebSocket upgrade, based on peeking the initial request for an
  // 'Upgrade: websocket' header. Entirely optional - TVRDX_HTTPExecutive and
  // TVRDX_WebSocketExecutive remain independently usable on their own ports if you'd
  // rather keep them split (see WIRING.md). This is for the case where you want both
  // reachable on a single port, e.g. 80.
  //
  // Doesn't reimplement either protocol: HTTP responses come from
  // TVRDX_HTTPExecutive.BuildResponse (a class function, no listener needed), and a
  // WebSocket upgrade is handed off via AWebSocket.AdoptConnection, passing along the
  // bytes already read here so the connection doesn't do a second fpRecv.
  TVRDX_WebListenerExecutive = class(TVRDX_SocketListenerExecutive)
  private
    FWhiteboard: TVRDX_WhiteboardExecutive;
    FWebSocket: TVRDX_WebSocketExecutive;
  protected
    procedure HandleConnection(ASock: TSocket); override;
  public
    constructor Create(ABus: TVRDX_MessageQueue; AWhiteboard: TVRDX_WhiteboardExecutive;
      AWebSocket: TVRDX_WebSocketExecutive); reintroduce;
    procedure HandlePacket(const AMsg: TVRDX_Message); override;
  end;

implementation

constructor TVRDX_WebListenerExecutive.Create(ABus: TVRDX_MessageQueue;
  AWhiteboard: TVRDX_WhiteboardExecutive; AWebSocket: TVRDX_WebSocketExecutive);
begin
  inherited Create(ABus);
  FWhiteboard := AWhiteboard;
  FWebSocket := AWebSocket;
  Port := 80;
end;

procedure TVRDX_WebListenerExecutive.HandleConnection(ASock: TSocket);
var
  Buf: array[0..2047] of Byte;
  Received: Integer;
  Request, Response: string;
begin
  Received := fpRecv(ASock, @Buf[0], SizeOf(Buf), 0);
  if Received <= 0 then
  begin
    CloseSocket(ASock);
    Exit;
  end;
  SetString(Request, PAnsiChar(@Buf[0]), Received);

  if TVRDX_WSConnection.IsUpgradeRequest(Request) then
    // FWebSocket.AdoptConnection takes ownership of ASock from here - including
    // eventually closing it - via a registered TVRDX_WSConnection.
    FWebSocket.AdoptConnection(ASock, Request)
  else
  begin
    Response := TVRDX_HTTPExecutive.BuildResponse(Request, FWhiteboard);
    fpSend(ASock, @Response[1], Length(Response), 0);
    CloseSocket(ASock);
  end;
end;

procedure TVRDX_WebListenerExecutive.HandlePacket(const AMsg: TVRDX_Message);
begin
  // Request/response + hand-off only - nothing to do on the bus-message path.
end;

end.
