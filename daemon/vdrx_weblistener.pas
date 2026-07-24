unit vdrx_weblistener;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Sockets, vdrx_core, vdrx_socketlistener, vdrx_transport,
  vdrx_http, vdrx_websocket, vdrx_whiteboard;

type
  // Optional: binds ONE port (plus optionally one TLS port) and routes each
  // connection to plain HTTP handling or a WebSocket upgrade, based on peeking the
  // initial request for an 'Upgrade: websocket' header. Entirely optional -
  // TVDRX_HTTPExecutive and TVDRX_WebSocketExecutive remain independently usable on
  // their own ports if you'd rather keep them split (see WIRING.md). This is for
  // the case where you want both reachable on a single port, e.g. 80/443.
  //
  // Doesn't reimplement either protocol: HTTP responses come from
  // TVDRX_HTTPExecutive.BuildResponse (a class function, no listener needed), and a
  // WebSocket upgrade is handed off via AWebSocket.AdoptConnection, passing along
  // the transport and bytes already read here so the connection doesn't do a second
  // Read.
  TVDRX_WebListenerExecutive = class(TVDRX_SocketListenerExecutive)
  private
    FWhiteboard: TVDRX_WhiteboardExecutive;
    FWebSocket: TVDRX_WebSocketExecutive;
  protected
    procedure HandleConnection(ATransport: TVDRX_Transport); override;
  public
    constructor Create(ABus: TVDRX_MessageQueue; AWhiteboard: TVDRX_WhiteboardExecutive;
      AWebSocket: TVDRX_WebSocketExecutive); reintroduce;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
  end;

implementation

constructor TVDRX_WebListenerExecutive.Create(ABus: TVDRX_MessageQueue;
  AWhiteboard: TVDRX_WhiteboardExecutive; AWebSocket: TVDRX_WebSocketExecutive);
begin
  inherited Create(ABus);
  FWhiteboard := AWhiteboard;
  FWebSocket := AWebSocket;
  Port := 80;
end;

procedure TVDRX_WebListenerExecutive.HandleConnection(ATransport: TVDRX_Transport);
var
  Buf: array[0..2047] of Byte;
  Received: Integer;
  Request, Response: string;
begin
  Received := ATransport.Read(Buf[0], SizeOf(Buf));
  if Received <= 0 then
  begin
    ATransport.Close;
    ATransport.Free;
    Exit;
  end;
  SetString(Request, PAnsiChar(@Buf[0]), Received);

  if TVDRX_WSConnection.IsUpgradeRequest(Request) then
    // FWebSocket.AdoptConnection takes ownership of ATransport from here -
    // including eventually closing it - via a registered TVDRX_WSConnection.
    FWebSocket.AdoptConnection(ATransport, Request)
  else
  begin
    Response := TVDRX_HTTPExecutive.BuildResponse(Request, FWhiteboard);
    ATransport.Write(Response[1], Length(Response));
    ATransport.Close;
    ATransport.Free;
  end;
end;

procedure TVDRX_WebListenerExecutive.HandlePacket(const AMsg: TVDRX_Message);
begin
  // Request/response + hand-off only - nothing to do on the bus-message path.
end;

end.
