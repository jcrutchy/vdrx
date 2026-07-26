unit vdrx_weblistener;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Sockets, vdrx_core, vdrx_socketlistener, vdrx_transport,
  vdrx_http, vdrx_websocket, vdrx_whiteboard, vdrx_config, vdrx_templates;

type
  TVDRX_WebListenerExecutive = class(TVDRX_SocketListenerExecutive)
  private
    FWhiteboard: TVDRX_WhiteboardExecutive;
    FWebSocket: TVDRX_WebSocketExecutive;
    FTemplates: TVDRX_TemplateStore;
    FConfig: TVDRX_Config;
    FStaticDir: string;
    FProxyRoutes: TVDRX_ProxyRoutes;
  protected
    procedure HandleConnection(ATransport: TVDRX_Transport); override;
  public
    constructor Create(ABus: TVDRX_MessageQueue; AWhiteboard: TVDRX_WhiteboardExecutive;
      AWebSocket: TVDRX_WebSocketExecutive; ATemplates: TVDRX_TemplateStore;
      AConfig: TVDRX_Config; const AStaticDir: string; const AProxyRoutes: TVDRX_ProxyRoutes); reintroduce;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
  end;

implementation

constructor TVDRX_WebListenerExecutive.Create(ABus: TVDRX_MessageQueue;
  AWhiteboard: TVDRX_WhiteboardExecutive; AWebSocket: TVDRX_WebSocketExecutive;
  ATemplates: TVDRX_TemplateStore; AConfig: TVDRX_Config; const AStaticDir: string;
  const AProxyRoutes: TVDRX_ProxyRoutes);
begin
  inherited Create(ABus);
  FWhiteboard := AWhiteboard;
  FWebSocket := AWebSocket;
  FTemplates := ATemplates;
  FConfig := AConfig;
  FStaticDir := AStaticDir;
  FProxyRoutes := AProxyRoutes;
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
    FWebSocket.AdoptConnection(ATransport, Request)
  else
  begin
    Response := TVDRX_HTTPExecutive.BuildResponse(Request, FWhiteboard, FTemplates, FConfig, FStaticDir, FProxyRoutes, Bus, ID);
    ATransport.Write(Response[1], Length(Response));
    ATransport.Close;
    ATransport.Free;
  end;
end;

procedure TVDRX_WebListenerExecutive.HandlePacket(const AMsg: TVDRX_Message);
begin
  // Request/response + hand-off only.
end;

end.
