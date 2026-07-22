unit vrdx_websocket;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Sockets, SyncObjs, base64, sha1, fpjson, jsonparser,
  vrdx_core, vrdx_socketlistener;

const
  WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

type
  TVRDX_WebSocketExecutive = class;

  // One instance per live browser connection. Registers itself into the Registry
  // once auth succeeds, with whatever filter the client last subscribed to - this is
  // what lets the Dispatcher's ordinary routing deliver bus messages straight to the
  // socket, with no separate broadcast path anywhere in the kernel. Deregisters
  // itself on disconnect.
  TVRDX_WSConnection = class(TVRDX_Executive)
  private
    FListener: TVRDX_WebSocketExecutive;
    FSocket: TSocket;
    FThread: TThread;
    FAuthenticated: Boolean;
    FSendLock: TCriticalSection;
    FPendingRequest: string; // set via AdoptConnection when the handshake bytes were already read elsewhere
    function DoHandshake: Boolean;
    function ReadFrame(out APayload: string; out AOpcode: Byte): Boolean;
    procedure SendFrame(const APayload: string; AOpcode: Byte = 1);
    procedure HandleRPC(const ALine: string);
  public
    constructor Create(ABus: TVRDX_MessageQueue; AListener: TVRDX_WebSocketExecutive; ASocket: TSocket);
    destructor Destroy; override;
    property PendingRequest: string read FPendingRequest write FPendingRequest;
    procedure Initialize; override;
    procedure Shutdown; override;
    procedure HandlePacket(const AMsg: TVRDX_Message); override;
    procedure RunLoop; // public: called from TWSConnThread below
    // Used by the combined HTTP/WS listener to decide, from bytes it already read,
    // whether a connection should be routed here instead of to plain HTTP.
    class function IsUpgradeRequest(const ARequest: string): Boolean;
  end;

  TVRDX_WebSocketExecutive = class(TVRDX_SocketListenerExecutive)
  private
    FRegistry: TVRDX_Registry;
    FConnCounter: Integer;
  protected
    procedure HandleConnection(ASock: TSocket); override;
  public
    constructor Create(ABus: TVRDX_MessageQueue; ARegistry: TVRDX_Registry); reintroduce;
    property Registry: TVRDX_Registry read FRegistry;
    procedure HandlePacket(const AMsg: TVRDX_Message); override;
    function NextConnID: string;
    // Constructs, registers, and launches a connection for a socket someone else
    // already accepted. AInitialRequest carries any bytes already read off the wire
    // (pass '' if none were - the connection will do its own fpRecv for the
    // handshake). Used by our own HandleConnection and, optionally, by a combined
    // HTTP/WS listener sharing one port.
    procedure AdoptConnection(ASock: TSocket; const AInitialRequest: string);
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
  // Same rationale as TVRDX_ListenerConnThread in vrdx_socketlistener.pas: a plain
  // TThread wrapper rather than an anonymous closure over a loop-local connection
  // value.
  TWSConnThread = class(TThread)
  private
    FConn: TVRDX_WSConnection;
  protected
    procedure Execute; override;
  public
    constructor Create(AConn: TVRDX_WSConnection);
  end;

constructor TWSConnThread.Create(AConn: TVRDX_WSConnection);
begin
  inherited Create(True);
  FConn := AConn;
  FreeOnTerminate := False;
end;

procedure TWSConnThread.Execute;
begin
  FConn.RunLoop;
end;

{ TVRDX_WSConnection }

constructor TVRDX_WSConnection.Create(ABus: TVRDX_MessageQueue; AListener: TVRDX_WebSocketExecutive; ASocket: TSocket);
begin
  inherited Create(ABus);
  FListener := AListener;
  FSocket := ASocket;
  FSendLock := TCriticalSection.Create;
  FAuthenticated := False;
end;

destructor TVRDX_WSConnection.Destroy;
begin
  FSendLock.Free;
  inherited Destroy;
end;

class function TVRDX_WSConnection.IsUpgradeRequest(const ARequest: string): Boolean;
begin
  // Cheap header sniff, not a full parse - good enough to route on before either
  // handler takes over the socket for real.
  Result := (Pos('Upgrade:', ARequest) > 0) and (Pos('websocket', LowerCase(ARequest)) > 0);
end;

function TVRDX_WSConnection.DoHandshake: Boolean;
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
    Received := fpRecv(FSocket, @Buf[0], SizeOf(Buf), 0);
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
  fpSend(FSocket, @Header[1], Length(Header), 0);
  Result := True;
end;

// Unfragmented text frames only, up to 64KB payload - sufficient for the short
// JSON-RPC control messages this bridge exchanges.
function TVRDX_WSConnection.ReadFrame(out APayload: string; out AOpcode: Byte): Boolean;
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
  if fpRecv(FSocket, @Hdr[0], 2, 0) <> 2 then Exit;
  AOpcode := Hdr[0] and $0F;
  if AOpcode = 8 then Exit; // close frame
  LenByte := Hdr[1] and $7F;
  Len := LenByte;
  if LenByte = 126 then
  begin
    fpRecv(FSocket, @Ext[0], 2, 0);
    Len := (Ext[0] shl 8) or Ext[1];
  end
  else if LenByte = 127 then
    Exit; // 64-bit lengths not needed for control-plane traffic
  if (Hdr[1] and $80) <> 0 then
    fpRecv(FSocket, @Mask[0], 4, 0)
  else
    FillChar(Mask, SizeOf(Mask), 0);
  SetLength(Data, Len);
  Received := 0;
  while Received < Len do
    Inc(Received, fpRecv(FSocket, @Data[Received], Len - Received, 0));
  for i := 0 to Len - 1 do
    Data[i] := Data[i] xor Mask[i mod 4];
  SetString(APayload, PAnsiChar(@Data[0]), Len);
  Result := True;
end;

procedure TVRDX_WSConnection.SendFrame(const APayload: string; AOpcode: Byte);
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
    fpSend(FSocket, @Buf[1], Length(Buf), 0);
  finally
    FSendLock.Leave;
  end;
end;

procedure TVRDX_WSConnection.HandleRPC(const ALine: string);
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
      Topic := Obj.Get('filter', '');
      // Single-filter simplification (flagged in session notes): re-registering
      // replaces this connection's one active filter rather than adding to a set.
      FListener.Registry.Unregister(ID);
      FListener.Registry.Register(Self, ID, Topic);
    end
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

procedure TVRDX_WSConnection.RunLoop;
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

procedure TVRDX_WSConnection.Initialize;
begin
  FThread := TWSConnThread.Create(Self);
  FThread.Start;
end;

procedure TVRDX_WSConnection.Shutdown;
begin
  CloseSocket(FSocket); // unblocks the blocking recv in RunLoop
  if Assigned(FThread) then
  begin
    FThread.WaitFor;
    FThread.Free;
    FThread := nil;
  end;
end;

procedure TVRDX_WSConnection.HandlePacket(const AMsg: TVRDX_Message);
begin
  SendFrame(Format('{"topic":%s,"payload":%s,"source":%s,"seq":%d}',
    [JEsc(AMsg.Topic), AMsg.Payload, JEsc(AMsg.SourceID), AMsg.Seq]));
end;

{ TVRDX_WebSocketExecutive }

constructor TVRDX_WebSocketExecutive.Create(ABus: TVRDX_MessageQueue; ARegistry: TVRDX_Registry);
begin
  inherited Create(ABus);
  FRegistry := ARegistry;
  Port := 8082;
  FConnCounter := 0;
end;

function TVRDX_WebSocketExecutive.NextConnID: string;
begin
  Inc(FConnCounter);
  Result := 'ws.conn.' + IntToStr(FConnCounter);
end;

procedure TVRDX_WebSocketExecutive.AdoptConnection(ASock: TSocket; const AInitialRequest: string);
var
  Conn: TVRDX_WSConnection;
begin
  Conn := TVRDX_WSConnection.Create(Bus, Self, ASock);
  Conn.PendingRequest := AInitialRequest;
  // Registered with a non-matching placeholder filter until the client's own
  // 'subscribe' RPC re-registers it with something real.
  FRegistry.Register(Conn, NextConnID, 'sys.none');
  Conn.Initialize;
end;

procedure TVRDX_WebSocketExecutive.HandleConnection(ASock: TSocket);
begin
  AdoptConnection(ASock, ''); // no bytes pre-read - the connection does its own recv
end;

procedure TVRDX_WebSocketExecutive.HandlePacket(const AMsg: TVRDX_Message);
begin
  // The listener itself isn't a message recipient - each TVRDX_WSConnection is.
end;

end.
