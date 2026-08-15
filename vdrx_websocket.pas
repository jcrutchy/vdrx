unit vdrx_websocket;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Sockets, SyncObjs, base64, sha1, fpjson, jsonparser,
  vdrx_core, vdrx_socketlistener, vdrx_transport, vdrx_config, vdrx_procutil, DateUtils;

const
  WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

type
  TVDRX_WebSocketExecutive = class;

  TVDRX_WSConnection = class(TVDRX_Executive)
  private
    FListener: TVDRX_WebSocketExecutive;
    FTransport: TVDRX_Transport;
    FThread: TThread;
    FAuthenticated: Boolean;
    FSendLock: TCriticalSection;
    FPendingRequest: string;

    FPingThread: TThread;
    FStopping: Boolean;
    FLastPong: TDateTime;
    procedure PingLoop;

    function DoHandshake: Boolean;
    function ReadFrame(out APayload: string; out AOpcode: Byte): Boolean;
    procedure SendFrame(const APayload: string; AOpcode: Byte = 1);
    procedure HandleRPC(const ALine: string);
  public
    constructor Create(ABus: TVDRX_MessageQueue; AListener: TVDRX_WebSocketExecutive; ATransport: TVDRX_Transport);
    destructor Destroy; override;
    property PendingRequest: string read FPendingRequest write FPendingRequest;
    procedure Initialize; override;
    procedure Shutdown; override;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    procedure RunLoop;
    class function IsUpgradeRequest(const ARequest: string): Boolean;
  end;

  TVDRX_WebSocketExecutive = class(TVDRX_SocketListenerExecutive)
  private
    FConfig: TVDRX_Config;
    FRegistry: TVDRX_Registry;
    FConnCounter: Integer;
    FPingIntervalMs, FPongTimeoutMs: Integer;
  protected
    procedure HandleConnection(ATransport: TVDRX_Transport); override;
  public
    constructor Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config; ARegistry: TVDRX_Registry); reintroduce;
    property Registry: TVDRX_Registry read FRegistry;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    procedure ApplyConfig; override;
    function NextConnID: string;
    procedure AdoptConnection(ATransport: TVDRX_Transport; const AInitialRequest: string);
    property PingIntervalMs: Integer read FPingIntervalMs write FPingIntervalMs;
    property PongTimeoutMs: Integer read FPongTimeoutMs write FPongTimeoutMs;
  end;

implementation

function ComputeAcceptKey(const AClientKey: string): string;
var
  Digest: TSHA1Digest;
  RawStr: string;
begin
  Digest := SHA1String(AClientKey + WS_GUID);
  SetString(RawStr, PAnsiChar(@Digest[0]), SizeOf(Digest));
  Result := EncodeStringBase64(RawStr);
end;

type
  TWSConnThread = class(TThread)
  private
    FConn: TVDRX_WSConnection;
  protected
    procedure Execute; override;
  public
    constructor Create(AConn: TVDRX_WSConnection);
  end;

constructor TWSConnThread.Create(AConn: TVDRX_WSConnection);
begin
  inherited Create(True);
  FConn := AConn;
  FreeOnTerminate := False;
end;

procedure TWSConnThread.Execute;
begin
  FConn.RunLoop;
end;

{ TVDRX_WSConnection }

constructor TVDRX_WSConnection.Create(ABus: TVDRX_MessageQueue; AListener: TVDRX_WebSocketExecutive; ATransport: TVDRX_Transport);
begin
  inherited Create(ABus);
  FListener := AListener;
  FTransport := ATransport;
  FSendLock := TCriticalSection.Create;
  FAuthenticated := False;
end;

destructor TVDRX_WSConnection.Destroy;
begin
  FTransport.Free;
  FSendLock.Free;
  inherited Destroy;
end;

class function TVDRX_WSConnection.IsUpgradeRequest(const ARequest: string): Boolean;
begin
  Result := (Pos('Upgrade:', ARequest) > 0) and (Pos('websocket', LowerCase(ARequest)) > 0);
end;

function TVDRX_WSConnection.DoHandshake: Boolean;
var
  Buf: array[0..2047] of Byte;
  Received, i, tailLen: Integer;
  Request, Key, AcceptKey, Header: string;
begin
  Result := False;
  if FPendingRequest <> '' then
    Request := FPendingRequest
  else
  begin
    Received := FTransport.Read(Buf[0], SizeOf(Buf));
    if Received <= 0 then
    begin
      Bus.Publish('log.warn', 'ws ' + ID + ': no bytes received for handshake', ID);
      Exit;
    end;
    SetString(Request, PAnsiChar(@Buf[0]), Received);
  end;
  i := Pos('Sec-WebSocket-Key:', Request);
  if i = 0 then
  begin
    Bus.Publish('log.warn', 'ws ' + ID + ': handshake request had no Sec-WebSocket-Key header', ID);
    Exit;
  end;
  tailLen := Pos(#13, Copy(Request, i, Length(Request))) - 20;
  if tailLen < 1 then Exit;
  Key := Trim(Copy(Request, i + 19, tailLen));
  AcceptKey := ComputeAcceptKey(Key);
  Header := 'HTTP/1.1 101 Switching Protocols'#13#10 +
            'Upgrade: websocket'#13#10 +
            'Connection: Upgrade'#13#10 +
            'Sec-WebSocket-Accept: ' + AcceptKey + #13#10#13#10;
  FTransport.Write(Header[1], Length(Header));
  Bus.Publish('log.info', 'ws ' + ID + ': handshake OK', ID);
  Result := True;
end;

function TVDRX_WSConnection.ReadFrame(out APayload: string; out AOpcode: Byte): Boolean;
var
  Hdr: array[0..1] of Byte;
  Ext: array[0..1] of Byte;
  Len: Integer;
  Mask: array[0..3] of Byte;
  Data: array of Byte;
  Received, i: Integer;
  LenByte: Byte;
begin
  Result := False;
  if FTransport.Read(Hdr[0], 2) <> 2 then Exit;
  AOpcode := Hdr[0] and $0F;
  if AOpcode = 8 then Exit;
  LenByte := Hdr[1] and $7F;
  Len := LenByte;
  if LenByte = 126 then
  begin
    FTransport.Read(Ext[0], 2);
    Len := (Ext[0] shl 8) or Ext[1];
  end
  else if LenByte = 127 then
    Exit;
  if (Hdr[1] and $80) <> 0 then
    FTransport.Read(Mask[0], 4)
  else
    FillChar(Mask, SizeOf(Mask), 0);
  SetLength(Data, Len);
  Received := 0;
  while Received < Len do
    Inc(Received, FTransport.Read(Data[Received], Len - Received));
  for i := 0 to Len - 1 do
    Data[i] := Data[i] xor Mask[i mod 4];
  SetString(APayload, PAnsiChar(@Data[0]), Len);
  Result := True;
end;

procedure TVDRX_WSConnection.SendFrame(const APayload: string; AOpcode: Byte);
var
  Hdr: array[0..3] of Byte;
  HdrLen: Integer;
  Buf: string;
begin
  FSendLock.Enter;
  try
    Hdr[0] := $80 or AOpcode;
    if Length(APayload) < 126 then
    begin
      Hdr[1] := Length(APayload);
      HdrLen := 2;
    end
    else
    begin
      Hdr[1] := 126;
      Hdr[2] := (Length(APayload) shr 8) and $FF;
      Hdr[3] := Length(APayload) and $FF;
      HdrLen := 4;
    end;
    SetString(Buf, PAnsiChar(@Hdr[0]), HdrLen);
    Buf := Buf + APayload;
    FTransport.Write(Buf[1], Length(Buf));
  finally
    FSendLock.Leave;
  end;
end;

procedure TVDRX_WSConnection.HandleRPC(const ALine: string);
var
  J: TJSONData;
  Obj: TJSONObject;
  Method, Topic, Payload, Token, Src: string;
begin
  try
    J := GetJSON(ALine);
  except
    Bus.Publish('log.warn', 'ws ' + ID + ': dropped malformed JSON RPC: ' + ALine, ID);
    Exit;
  end;
  try
    if not (J is TJSONObject) then Exit;
    Obj := TJSONObject(J);
    Method := Obj.Get('method', '');

    if Method = 'sys.auth' then
    begin
      Token := Obj.Get('token', '');
      Src := Obj.Get('source', ID);
      FAuthenticated := Token <> '';
      if FAuthenticated then
        Bus.Publish('log.info', 'ws ' + ID + ': authenticated (stub - any nonempty token passes)', ID)
      else
        Bus.Publish('log.warn', 'ws ' + ID + ': sys.auth sent with an empty token, rejected', ID);
      SendFrame(Format('{"event":"auth.ok","source":%s}', [JSONString(Src)]));
      Exit;
    end;

    if not FAuthenticated then
    begin
      Bus.Publish('log.warn', 'ws ' + ID + ': "' + Method + '" ignored - not authenticated yet', ID);
      Exit;
    end;

    if Method = 'subscribe' then
    begin
      Topic := Obj.Get('filter', '');
      Bus.Publish('log.info', 'ws ' + ID + ': subscribe "' + Topic + '"', ID);
      FListener.Registry.Register(Self, ID, Topic);
    end
    else if Method = 'unsubscribe' then
    begin
      Topic := Obj.Get('filter', '');
      Bus.Publish('log.info', 'ws ' + ID + ': unsubscribe "' + Topic + '"', ID);
      FListener.Registry.UnregisterFilter(ID, Topic);
    end
    else if Method = 'unsubscribe_all' then
    begin
      Bus.Publish('log.info', 'ws ' + ID + ': unsubscribe_all', ID);
      FListener.Registry.ClearFilters(ID);
    end
    else if Method = 'publish' then
    begin
      Topic := Obj.Get('topic', '');
      Payload := Obj.Get('payload', '{}');
      Bus.Publish('log.info', 'ws ' + ID + ': publish "' + Topic + '" ' + Payload, ID);
      Bus.Publish(Topic, Payload, ID);
    end
    else
      Bus.Publish('log.warn', 'ws ' + ID + ': unrecognised RPC method "' + Method + '"', ID);
  finally
    J.Free;
  end;
end;

procedure TVDRX_WSConnection.RunLoop;
var
  Payload: string;
  Opcode: Byte;
begin
  if not DoHandshake then
  begin
    Bus.Publish('log.warn', 'ws ' + ID + ': handshake failed, dropping connection', ID);
    Exit;
  end;

  // Only safe to start pinging after the handshake completes - anything sent
  // before that would corrupt the raw HTTP upgrade exchange.
  FLastPong := Now;
  FPingThread := TVDRX_WorkerThread.Create(@PingLoop);
  FPingThread.Start;

  while True do
  begin
    if not ReadFrame(Payload, Opcode) then Break;
    case Opcode of
      1: HandleRPC(Payload);
      9: SendFrame(Payload, 10); // client ping - echo back as pong, per spec
      10: FLastPong := Now;      // reply to OUR ping - see PingLoop
    end;
  end;

  Bus.Publish('log.info', 'ws ' + ID + ': disconnected', ID);
  Bus.Publish('sys.ws.disconnected', Format('{"id":%s}', [JSONString(ID)]), ID);
  FListener.Registry.UnregisterSelf(ID); // NOT Unregister - this is our own thread, see vdrx_core.pas's UnregisterSelf comment
end;

// Sends a ping every PingIntervalMs and force-closes the transport if no
// pong (ours or a stray client one - either counts as "link is alive") has
// been seen within PingIntervalMs + PongTimeoutMs. Closing FTransport here
// unblocks RunLoop's blocking ReadFrame on another thread - the same
// close-to-unblock idiom Shutdown already relies on (see
// TVDRX_ListenerConnThread.Transport's comment) - so the normal disconnect/
// unregister path in RunLoop runs exactly as it would for a real close,
// no special-casing needed there.
// FLastPong is read/written across threads without a lock - a one-cycle
// stale read just delays detection by ~PingIntervalMs, never causes a false
// disconnect, so it isn't worth a CriticalSection for a heartbeat check.
procedure TVDRX_WSConnection.PingLoop;
var
  Waited: Integer;
begin
  while not FStopping do
  begin
    Waited := 0;
    while (not FStopping) and (Waited < FListener.PingIntervalMs) do
    begin
      Sleep(200);
      Inc(Waited, 200);
    end;
    if FStopping then Break;

    if MilliSecondsBetween(Now, FLastPong) > (FListener.PingIntervalMs + FListener.PongTimeoutMs) then
    begin
      Bus.Publish('log.warn', 'ws ' + ID + ': no pong within timeout, closing stale connection', ID);
      FTransport.Close;
      Break;
    end;

    try
      SendFrame('', 9); // opcode 9 = ping
    except
      Break; // transport already gone - natural disconnect raced us here, RunLoop will handle cleanup
    end;
  end;
end;

procedure TVDRX_WSConnection.Initialize;
begin
  FThread := TWSConnThread.Create(Self);
  FThread.Start;
end;

procedure TVDRX_WSConnection.Shutdown;
begin
  FStopping := True;
  FTransport.Close;
  if Assigned(FThread) then
  begin
    if WaitThreadOrTimeout(FThread, FListener.GracefulTimeoutMs) then
    begin
      FThread.Free;
      FThread := nil;
    end
    else
      Bus.Publish('log.warn', 'ws ' + ID + ': connection thread did not exit in time - abandoning it', ID);
  end;
  if Assigned(FPingThread) then
  begin
    if WaitThreadOrTimeout(FPingThread, FListener.GracefulTimeoutMs) then
    begin
      FPingThread.Free;
      FPingThread := nil;
    end
    else
      Bus.Publish('log.warn', 'ws ' + ID + ': ping thread did not exit in time - abandoning it', ID);
  end;
end;

procedure TVDRX_WSConnection.HandlePacket(const AMsg: TVDRX_Message);
begin
  Bus.Publish('log.info', 'ws ' + ID + ': -> "' + AMsg.Topic + '" ' + AMsg.Payload, ID);
  SendFrame(Format('{"topic":%s,"payload":%s,"source":%s,"seq":%d}',
    [JSONString(AMsg.Topic), AMsg.Payload, JSONString(AMsg.SourceID), AMsg.Seq]));
end;

{ TVDRX_WebSocketExecutive }

constructor TVDRX_WebSocketExecutive.Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config; ARegistry: TVDRX_Registry);
begin
  inherited Create(ABus);
  FConfig := AConfig;
  FRegistry := ARegistry;
  Port := 8082;
  FConnCounter := 0;
  FPingIntervalMs := 15000;
  FPongTimeoutMs := 10000;
end;

function TVDRX_WebSocketExecutive.NextConnID: string;
begin
  Inc(FConnCounter);
  Result := 'ws.conn.' + IntToStr(FConnCounter);
end;

procedure TVDRX_WebSocketExecutive.AdoptConnection(ATransport: TVDRX_Transport; const AInitialRequest: string);
var
  Conn: TVDRX_WSConnection;
  NewID: string;
begin
  Conn := TVDRX_WSConnection.Create(Bus, Self, ATransport);
  Conn.PendingRequest := AInitialRequest;
  NewID := NextConnID;
  Bus.Publish('sys.ws.connected', Format('{"id":%s}', [JSONString(NewID)]), ID);
  Bus.Publish('log.info', 'ws: new connection ' + NewID, ID);
  FRegistry.Register(Conn, NewID, 'sys.none');
  Conn.Initialize;
end;

procedure TVDRX_WebSocketExecutive.HandleConnection(ATransport: TVDRX_Transport);
begin
  AdoptConnection(ATransport, '');
end;

procedure TVDRX_WebSocketExecutive.HandlePacket(const AMsg: TVDRX_Message);
begin
  // The listener itself isn't a message recipient - each TVDRX_WSConnection is.
end;

procedure TVDRX_WebSocketExecutive.ApplyConfig;
var
  NewPort, NewTLSPort: Integer;
  CertFile, KeyFile: string;
begin
  NewPort := FConfig.GetInteger('executives.ws.port', 8082);
  NewTLSPort := FConfig.GetInteger('executives.ws.tls_port', 0);
  CertFile := FConfig.GetString('executives.ws.tls_cert', '');
  KeyFile := FConfig.GetString('executives.ws.tls_key', '');
  FPingIntervalMs := FConfig.GetInteger('executives.ws.ping_interval_ms', 15000);
  FPongTimeoutMs := FConfig.GetInteger('executives.ws.pong_timeout_ms', 10000);
  if (NewPort <> Port) or (NewTLSPort <> TLSPort) then
  begin
    Shutdown;
    Port := NewPort;
    ConfigureTLS(NewTLSPort, CertFile, KeyFile);
    Initialize;
  end;
end;

end.
