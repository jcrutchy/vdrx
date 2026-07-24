unit vdrx_websocket;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Sockets, SyncObjs, base64, sha1, fpjson, jsonparser,
  vdrx_core, vdrx_socketlistener, vdrx_transport, vdrx_config;

const
  WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

type
  TVDRX_WebSocketExecutive = class;

  // One instance per live browser connection. Registers itself into the Registry
  // once auth succeeds, and can hold any number of active filters at once (each
  // 'subscribe' RPC adds one, 'unsubscribe'/'unsubscribe_all' drop one or all) -
  // this is what lets the Dispatcher's ordinary routing deliver bus messages
  // straight to the socket, with no separate broadcast path anywhere in the kernel.
  // Deregisters itself on disconnect. Talks to FTransport rather than a raw socket,
  // so it works identically whether the browser connected plain (ws://) or TLS
  // (wss://) - see TVDRX_SocketListenerExecutive/vdrx_transport.pas.
  TVDRX_WSConnection = class(TVDRX_Executive)
  private
    FListener: TVDRX_WebSocketExecutive;
    FTransport: TVDRX_Transport;
    FThread: TThread;
    FAuthenticated: Boolean;
    FSendLock: TCriticalSection;
    FPendingRequest: string; // set via AdoptConnection when the handshake bytes were already read elsewhere
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
    procedure RunLoop; // public: called from TWSConnThread below
    // Used by the combined HTTP/WS listener to decide, from bytes it already read,
    // whether a connection should be routed here instead of to plain HTTP.
    class function IsUpgradeRequest(const ARequest: string): Boolean;
  end;

  TVDRX_WebSocketExecutive = class(TVDRX_SocketListenerExecutive)
  private
    FConfig: TVDRX_Config;
    FRegistry: TVDRX_Registry;
    FConnCounter: Integer;
  protected
    procedure HandleConnection(ATransport: TVDRX_Transport); override;
  public
    constructor Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config; ARegistry: TVDRX_Registry); reintroduce;
    property Registry: TVDRX_Registry read FRegistry;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    procedure ApplyConfig; override;
    function NextConnID: string;
    // Constructs, registers, and launches a connection for a transport someone else
    // already accepted (and, if TLS, already handshook). AInitialRequest carries any
    // bytes already read off the wire (pass '' if none were - the connection will do
    // its own Read for the handshake). Used by our own HandleConnection and,
    // optionally, by a combined HTTP/WS listener sharing one port.
    procedure AdoptConnection(ATransport: TVDRX_Transport; const AInitialRequest: string);
  end;

implementation

function JEsc(const S: string): string;
begin
  Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
  Result := '"' + Result + '"';
end;

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
  // Same rationale as TVDRX_ListenerConnThread in vdrx_socketlistener.pas: a plain
  // TThread wrapper rather than an anonymous closure over a loop-local connection
  // value.
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
  // Cheap header sniff, not a full parse - good enough to route on before either
  // handler takes over the connection for real.
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
    Request := FPendingRequest // handed to us already-read by AdoptConnection
  else
  begin
    Received := FTransport.Read(Buf[0], SizeOf(Buf));
    if Received <= 0 then Exit;
    SetString(Request, PAnsiChar(@Buf[0]), Received);
  end;
  i := Pos('Sec-WebSocket-Key:', Request);
  if i = 0 then Exit;
  tailLen := Pos(#13, Copy(Request, i, Length(Request))) - 20; // 'Sec-WebSocket-Key: ' is 20 chars
  if tailLen < 1 then Exit;
  Key := Trim(Copy(Request, i + 19, tailLen));
  AcceptKey := ComputeAcceptKey(Key);
  Header := 'HTTP/1.1 101 Switching Protocols'#13#10 +
            'Upgrade: websocket'#13#10 +
            'Connection: Upgrade'#13#10 +
            'Sec-WebSocket-Accept: ' + AcceptKey + #13#10#13#10;
  FTransport.Write(Header[1], Length(Header));
  Result := True;
end;

// Unfragmented text frames only, up to 64KB payload - sufficient for the short
// JSON-RPC control messages this bridge exchanges.
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
  if AOpcode = 8 then Exit; // close frame
  LenByte := Hdr[1] and $7F;
  Len := LenByte;
  if LenByte = 126 then
  begin
    FTransport.Read(Ext[0], 2);
    Len := (Ext[0] shl 8) or Ext[1];
  end
  else if LenByte = 127 then
    Exit; // 64-bit lengths not needed for control-plane traffic
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
    Buf := Buf + APayload; // server->client frames sent unmasked, per spec
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
    Exit; // malformed JSON dropped, connection stays alive
  end;
  try
    if not (J is TJSONObject) then Exit;
    Obj := TJSONObject(J);
    Method := Obj.Get('method', '');

    if Method = 'sys.auth' then
    begin
      Token := Obj.Get('token', '');
      Src := Obj.Get('source', ID);
      FAuthenticated := Token <> ''; // stub - wire to real verification before this is untrusted-facing
      SendFrame(Format('{"event":"auth.ok","source":%s}', [JEsc(Src)]));
      Exit;
    end;

    if not FAuthenticated then Exit; // bus-level actions gated until sys.auth succeeds

    if Method = 'subscribe' then
    begin
      // Adds one more filter to this connection's set - repeat 'subscribe' calls
      // accumulate rather than replace, so a client can listen to several topics
      // at once (e.g. 'wb.board1.>' and 'irc.#general.>' concurrently).
      Topic := Obj.Get('filter', '');
      FListener.Registry.Register(Self, ID, Topic);
    end
    else if Method = 'unsubscribe' then
    begin
      // Drops just this one filter, leaving any other active subscriptions alone.
      Topic := Obj.Get('filter', '');
      FListener.Registry.UnregisterFilter(ID, Topic);
    end
    else if Method = 'unsubscribe_all' then
      // Drops every filter this connection currently holds, without destroying the
      // connection itself - use before a fresh batch of 'subscribe' calls.
      FListener.Registry.ClearFilters(ID)
    else if Method = 'publish' then
    begin
      Topic := Obj.Get('topic', '');
      Payload := Obj.Get('payload', '{}');
      Bus.Publish(Topic, Payload, ID);
    end;
  finally
    J.Free;
  end;
end;

procedure TVDRX_WSConnection.RunLoop;
var
  Payload: string;
  Opcode: Byte;
begin
  if not DoHandshake then Exit;
  while True do
  begin
    if not ReadFrame(Payload, Opcode) then Break;
    if Opcode = 1 then HandleRPC(Payload);
  end;
  FListener.Registry.Unregister(ID); // clean up on disconnect
end;

procedure TVDRX_WSConnection.Initialize;
begin
  FThread := TWSConnThread.Create(Self);
  FThread.Start;
end;

procedure TVDRX_WSConnection.Shutdown;
begin
  FTransport.Close; // unblocks the blocking Read in RunLoop
  if Assigned(FThread) then
  begin
    FThread.WaitFor;
    FThread.Free;
    FThread := nil;
  end;
end;

procedure TVDRX_WSConnection.HandlePacket(const AMsg: TVDRX_Message);
begin
  SendFrame(Format('{"topic":%s,"payload":%s,"source":%s,"seq":%d}',
    [JEsc(AMsg.Topic), AMsg.Payload, JEsc(AMsg.SourceID), AMsg.Seq]));
end;

{ TVDRX_WebSocketExecutive }

constructor TVDRX_WebSocketExecutive.Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config; ARegistry: TVDRX_Registry);
begin
  inherited Create(ABus);
  FConfig := AConfig;
  FRegistry := ARegistry;
  Port := 8082;
  FConnCounter := 0;
end;

function TVDRX_WebSocketExecutive.NextConnID: string;
begin
  Inc(FConnCounter);
  Result := 'ws.conn.' + IntToStr(FConnCounter);
end;

procedure TVDRX_WebSocketExecutive.AdoptConnection(ATransport: TVDRX_Transport; const AInitialRequest: string);
var
  Conn: TVDRX_WSConnection;
begin
  Conn := TVDRX_WSConnection.Create(Bus, Self, ATransport);
  Conn.PendingRequest := AInitialRequest;
  // Registered with a non-matching placeholder filter until the client's own
  // 'subscribe' RPC re-registers it with something real.
  FRegistry.Register(Conn, NextConnID, 'sys.none');
  Conn.Initialize;
end;

procedure TVDRX_WebSocketExecutive.HandleConnection(ATransport: TVDRX_Transport);
begin
  AdoptConnection(ATransport, ''); // no bytes pre-read - the connection does its own Read
end;

procedure TVDRX_WebSocketExecutive.HandlePacket(const AMsg: TVDRX_Message);
begin
  // The listener itself isn't a message recipient - each TVDRX_WSConnection is.
end;

// Same restart-on-change pattern as TVDRX_IRCDExecutive.ApplyConfig.
procedure TVDRX_WebSocketExecutive.ApplyConfig;
var
  NewPort, NewTLSPort: Integer;
  CertFile, KeyFile: string;
begin
  NewPort := FConfig.GetInteger('executives.ws.port', 8082);
  NewTLSPort := FConfig.GetInteger('executives.ws.tls_port', 0);
  CertFile := FConfig.GetString('executives.ws.tls_cert', '');
  KeyFile := FConfig.GetString('executives.ws.tls_key', '');
  if (NewPort <> Port) or (NewTLSPort <> TLSPort) then
  begin
    Shutdown;
    Port := NewPort;
    ConfigureTLS(NewTLSPort, CertFile, KeyFile);
    Initialize;
  end;
end;

end.
