unit vdrx_websocket;

{$mode ObjFPC}{$H+}

// WebSocket server: RFC 6455 framing, the bus <-> WebSocket protocol, ws_profiles authentication and 
// topic access rules, and the failed-login lockout.

interface

uses
  Classes, SysUtils, StrUtils, SyncObjs, Generics.Collections, openssl, {$IFDEF UNIX}BaseUnix, {$ENDIF} dynlibs, base64, sha1, fpjson, jsonparser, DateUtils, Types, vdrx_core, vdrx_config, vdrx_procutil, vdrx_transport, vdrx_connection, vdrx_httpparse;

type

  TVDRX_WebSocketExecutive = class;

  // One "ws_profiles" entry. A WebSocket client picks a profile with sys.auth and
  // from then on may only subscribe to filters covered by SubscribeAllow and
  // publish to topics matching PublishAllow (comma-separated topic patterns,
  // deny-by-default - the same semantics as a process's publish_allow).
  TVDRX_WSProfile = record
    ID: string;
    Token: string;            // '' = anyone who names the profile may use it
    SubscribeAllow: string;
    PublishAllow: string;
    DefaultSubscribe: string; // subscribed right after a successful sys.auth
    MaxQueue: Integer;        // outbound frames queued before the oldest are dropped
  end;

  TVDRX_WSProfiles = array of TVDRX_WSProfile;

  TVDRX_WSConnection = class(TVDRX_ConnectionExecutive)
  private
    FListener: TVDRX_WebSocketExecutive;
    FPeerAddr: string;    // kept for giving back the per-IP live slot after the transport is gone
    FThread: TThread;
    FSendThread: TThread;
    FSendLock: TCriticalSection;
    FSendEvent: TEvent;
    FSendQueue: TStringList;
    FControlQueue: TStringList;
    FPendingRequest: string;
    FPingThread: TThread;
    FStopping: Boolean;
    FLastPong: TDateTime;
    FMaxQueue: Integer;   // 0 = unbounded
    FDropped: Integer;    // data frames dropped since the client was last told
    procedure PingLoop;
    procedure SendLoop;
    procedure EnqueueFrame(const APayload: string; AOpcode: Byte);
    function WriteAll(const ABuf: string): Boolean;
    function DoHandshake: Boolean;
    function ReadFrame(out APayload: string; out AOpcode: Byte): Boolean;
  public
    constructor Create(ABus: TVDRX_MessageQueue; AListener: TVDRX_WebSocketExecutive; ATransport: TVDRX_Transport); reintroduce;
    destructor Destroy; override;
    property PendingRequest: string read FPendingRequest write FPendingRequest;
    property MaxQueue: Integer read FMaxQueue write FMaxQueue;
    procedure SendFrame(const APayload: string; AOpcode: Byte = 1);
    procedure Initialize; override;
    procedure Shutdown; override;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    procedure RunLoop;
    class function IsUpgradeRequest(const ARequest: string): Boolean;
  end;

  TVDRX_WSProtocolExecutive = class(TVDRX_Executive)
  private
    FListener: TVDRX_WebSocketExecutive;
    FConn: TVDRX_WSConnection;
    FAuthenticated: Boolean;
    FProfile: TVDRX_WSProfile;   // only meaningful when the listener has ws_profiles
    procedure Deny(const AMethod, ATopic: string);
    procedure ApplyDefaultSubscribe;
  public
    constructor Create(ABus: TVDRX_MessageQueue; AListener: TVDRX_WebSocketExecutive; AConn: TVDRX_WSConnection); reintroduce;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
  end;

  // Failed sys.auth bookkeeping for one client address (see AuthLocked).
  TVDRX_AuthTrack = record
    Fails: Integer;
    WindowStart: QWord;
    LockedUntil: QWord;
  end;

  TVDRX_WebSocketExecutive = class(TVDRX_SocketListenerExecutive)
  private
    FAllowOpenAccess: Boolean;
    FLiveConns: LongInt;
    FAllowedOrigins: TStringList;
    FMaxFrameBytes: Integer;
    FFrameTimeoutMs: Integer;
    FWriteTimeoutMs: Integer;
    FAuthLock: TCriticalSection;
    FAuthTrack: specialize TDictionary<string, TVDRX_AuthTrack>;
    FConfig: TVDRX_Config;
    FRegistry: TVDRX_Registry;
    FConnCounter: Integer;
    FPingIntervalMs, FPongTimeoutMs: Integer;
    FDefaultSubscribe: string;
    FProfiles: TVDRX_WSProfiles;
  protected
    procedure HandleConnection(ATransport: TVDRX_Transport); override;
  public
    constructor Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config; ARegistry: TVDRX_Registry); reintroduce;
    destructor Destroy; override;
    property Registry: TVDRX_Registry read FRegistry;
    // Only matters when there are no ws_profiles. False (the default): every
    // sys.auth is rejected. True: the old open behaviour (any non-empty token
    // passes, then the client may subscribe to anything and publish outside
    // sys.>) - for a throwaway dev setup only.
    property AllowOpenAccess: Boolean read FAllowOpenAccess write FAllowOpenAccess;
    // Browsers always send an Origin header on a WebSocket handshake, and any web page the user
    // visits can ask their browser to connect to an internal address. A handshake whose Origin is
    // neither the same host as the Host header nor listed here is refused (403). Clients that send
    // no Origin (scripts, other servers) are not affected. Entries are full origins, e.g.
    // "https://dash.corp.example".
    property AllowedOrigins: TStringList read FAllowedOrigins;
    function OriginAllowed(const ARequest: string): Boolean;
    // Called by a WS connection when it has fully ended (frees its slot in the live count).
    procedure ConnectionEnded(const APeerAddr: string);
    // Largest WebSocket frame a client may send (default 1 MiB). Bigger -> the connection is closed.
    property MaxFrameBytes: Integer read FMaxFrameBytes write FMaxFrameBytes;
    // Once a frame has started, how long each further read may take (default 15 s).
    property FrameTimeoutMs: Integer read FFrameTimeoutMs write FFrameTimeoutMs;
    // A frame that cannot be written for this long means the client stopped reading: the connection
    // is dropped (default 15 s, 0 = no limit).
    property WriteTimeoutMs: Integer read FWriteTimeoutMs write FWriteTimeoutMs;
    // Failed-login lockout, per client address: AUTH_MAX_FAILURES failures
    // inside AUTH_WINDOW_MS locks that address out of sys.auth for AUTH_LOCKOUT_MS.
    function AuthLocked(const AIP: string): Boolean;
    function NoteAuthFailure(const AIP: string): Boolean;   // True = this failure triggered a lockout
    procedure NoteAuthSuccess(const AIP: string);
    // ws_profiles
    property Profiles: TVDRX_WSProfiles read FProfiles write FProfiles;
    function ProfileMode: Boolean;
    function ResolveProfile(const AName, AToken: string; out AProfile: TVDRX_WSProfile): Boolean;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    procedure ApplyConfig; override;
    function NextConnID: string;
    // Takes over an accepted connection (from the WS port, or handed over by an HTTP site on a
    // shared port). The transport is ALWAYS consumed: closed and freed here if the connection is
    // refused, owned by the new WS connection otherwise. AInitialRequest = the HTTP upgrade
    // request when it has already been read. False = refused (connection cap).
    function AdoptConnection(ATransport: TVDRX_Transport; const AInitialRequest: string): Boolean;
    property PingIntervalMs: Integer read FPingIntervalMs write FPingIntervalMs;
    property PongTimeoutMs: Integer read FPongTimeoutMs write FPongTimeoutMs;
    property DefaultSubscribe: string read FDefaultSubscribe write FDefaultSubscribe;
  end;

const
  // WebSocket sys.auth lockout (per client address)
  AUTH_MAX_FAILURES = 8;       // failed sys.auth attempts ...
  AUTH_WINDOW_MS    = 60000;   // ... within this long ...
  AUTH_LOCKOUT_MS   = 60000;   // ... lock that client address out for this long
  AUTH_TRACK_MAX    = 2048;    // addresses remembered at once (idle ones are dropped first)
  WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

// True when every topic that matches AFilter also matches the allow-pattern AAllow: the test a
// ws_profiles subscribe_allow/publish_allow entry has to pass. Exposed for tests/unit/test_topiccover.lpr.
function TopicFilterCovers(const AAllow, AFilter: string): Boolean;

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
  FreeOnTerminate := True;
end;

procedure TWSConnThread.Execute;
begin
  FConn.RunLoop;
end;

{ TVDRX_ConnectionExecutive }

constructor TVDRX_WSConnection.Create(ABus: TVDRX_MessageQueue; AListener: TVDRX_WebSocketExecutive; ATransport: TVDRX_Transport);
begin
  inherited Create(ABus);
  FListener := AListener;
  FTransport := ATransport;
  FPeerAddr := ATransport.PeerAddr;
  FSendLock := TCriticalSection.Create;
  FSendEvent := TEvent.Create(nil, False, False, '');
  FSendQueue := TStringList.Create;
  FControlQueue := TStringList.Create;
  FMaxQueue := 5000;
end;

destructor TVDRX_WSConnection.Destroy;
begin
  FStopping := True;
  if Assigned(FTransport) then
    FTransport.Close;
  if Assigned(FSendEvent) then
    FSendEvent.SetEvent;
  if Assigned(FPingThread) then
  begin
    WaitThreadOrTimeout(FPingThread, 500);
    FreeAndNil(FPingThread);
  end;
  if Assigned(FSendThread) then
  begin
    WaitThreadOrTimeout(FSendThread, 1000);
    if not FSendThread.Finished then
      Bus.Publish('log.warn', 'ws ' + ID + ': send thread did not exit in time - abandoning it', ID)
    else
      FreeAndNil(FSendThread);
  end;
  FSendEvent.Free;
  FSendLock.Free;
  FSendQueue.Free;
  FControlQueue.Free;
  inherited Destroy;
end;

class function TVDRX_WSConnection.IsUpgradeRequest(const ARequest: string): Boolean;
begin
  Result := (Pos('Upgrade:', ARequest) > 0) and (Pos('websocket', LowerCase(ARequest)) > 0);
end;

function TVDRX_WSConnection.DoHandshake: Boolean;
const
  ReadChunkSize = 2048;
  MaxHandshakeBytes = 16384; // generous headroom - real clients send more headers (Origin, Sec-WebSocket-Extensions, User-Agent, cookies) than fit in one packet
  HandshakeTimeoutMs = 5000;
  KeyHeaderName = 'Sec-WebSocket-Key:';
var
  Buf: array[0..ReadChunkSize - 1] of Byte;
  Received, i, tailLen: Integer;
  Request, Chunk, Key, AcceptKey, Header: string;
begin
  Result := False;
  if FPendingRequest <> '' then
    Request := FPendingRequest
  else
  begin
    // A real client's handshake request can arrive split across more
    // than one TCP read - confirmed against Node's native WebSocket
    // client, which reliably does this even over loopback. The
    // previous single Read() call here silently dropped any connection
    // whose Sec-WebSocket-Key hadn't arrived yet in that first read -
    // no response was ever sent back, so the client just saw a
    // hung/failed connection with nothing server-side to explain why.
    // This loops until the blank-line header terminator shows up,
    // bounded by MaxHandshakeBytes and HandshakeTimeoutMs so a
    // connection that never completes its handshake can't tie up a
    // reader thread indefinitely (no read timeout was set here at all
    // before this fix, despite SetReadTimeout already existing on
    // TVDRX_Transport - a blocking Read() with no timeout means a
    // client that connects and never sends anything would have hung
    // this thread forever).
    FTransport.SetReadTimeout(HandshakeTimeoutMs);
    Request := '';
    while Pos(#13#10#13#10, Request) = 0 do
    begin
      if Length(Request) >= MaxHandshakeBytes then
      begin
        Bus.Publish('log.warn', 'ws ' + ID + ': handshake request exceeded ' + IntToStr(MaxHandshakeBytes) + ' bytes without completing, dropping', ID);
        Exit;
      end;
      Received := FTransport.Read(Buf[0], SizeOf(Buf));
      if Received <= 0 then
      begin
        Bus.Publish('log.warn', 'ws ' + ID + ': handshake read failed or timed out after ' + IntToStr(Length(Request)) + ' bytes', ID);
        Exit;
      end;
      SetString(Chunk, PAnsiChar(@Buf[0]), Received);
      Request := Request + Chunk;
    end;
  end;
  // HTTP header NAMES are case-insensitive per spec - Node's native
  // WebSocket client sends them fully lowercase ("sec-websocket-key:"),
  // which is entirely valid HTTP and is what actually broke every
  // non-browser client against this server (browsers' own WebSocket
  // implementations happen to send the mixed case this literal
  // previously required, which is almost certainly why this went
  // unnoticed - nothing but a browser had ever completed a handshake
  // here). Matched case-insensitively via UpperCase() on a copy so the
  // found position i lines up 1:1 with Request (same length/positions
  // for plain ASCII header text), while Key itself is extracted from
  // the ORIGINAL Request, not the uppercased copy - the base64 key
  // value is case-sensitive and must be preserved exactly as sent.
  if not FListener.OriginAllowed(Request) then
  begin
    Bus.Publish('log.warn', 'ws ' + ID + ': handshake refused - Origin "' +
      Copy(ExtractHeaderValue(Copy(Request, 1, Pos(#13#10#13#10, Request)), 'Origin'), 1, 100) +
      '" is not allowed (same host as the Host header, or listed in allowed_origins)', ID);
    Header := 'HTTP/1.1 403 Forbidden'#13#10'Connection: close'#13#10'Content-Length: 0'#13#10#13#10;
    FTransport.Write(Header[1], Length(Header));
    Exit;
  end;
  i := Pos(UpperCase(KeyHeaderName), UpperCase(Request));
  if i = 0 then
  begin
    Bus.Publish('log.warn', 'ws ' + ID + ': handshake request had no Sec-WebSocket-Key header', ID);
    Exit;
  end;
  tailLen := Pos(#13, Copy(Request, i, Length(Request))) - Length(KeyHeaderName) - 2;
  if tailLen < 1 then Exit;
  Key := Trim(Copy(Request, i + Length(KeyHeaderName) + 1, tailLen));
  AcceptKey := ComputeAcceptKey(Key);
  Header := 'HTTP/1.1 101 Switching Protocols'#13#10 +
            'Upgrade: websocket'#13#10 +
            'Connection: Upgrade'#13#10 +
            'Sec-WebSocket-Accept: ' + AcceptKey + #13#10#13#10;
  FTransport.Write(Header[1], Length(Header));
  // DoHandshake uses a short receive timeout only to prevent an incomplete
  // HTTP handshake from hanging a connection thread forever. That timeout
  // applies to the underlying socket, so it MUST be removed after the
  // handshake succeeds. Otherwise an otherwise-idle WebSocket will hit the
  // handshake timeout during its normal ReadFrame() loop and disconnect
  // after ~5 seconds. The ping thread is responsible for liveness after
  // upgrade and closes the socket itself when the pong deadline expires.
  FTransport.SetReadTimeout(0);
  if FListener.WriteTimeoutMs > 0 then FTransport.SetWriteTimeout(FListener.WriteTimeoutMs);
  Bus.Publish('log.info', 'ws ' + ID + ': handshake OK', ID);
  Result := True;
end;

const
  WS_MAX_FRAME_LEN = 64 * 1024 * 1024;

function TVDRX_WSConnection.ReadFrame(out APayload: string; out AOpcode: Byte): Boolean;
var
  Hdr: array[0..1] of Byte;
  Ext: array[0..1] of Byte;
  Ext8: array[0..7] of Byte;
  Len: Int64;
  Mask: array[0..3] of Byte;
  Data: array of Byte;
  Received, i, Chunk, MaxLen: Integer;
  LenByte: Byte;
  FrameStart: QWord;
begin
  Result := False;
  APayload := '';
  AOpcode := 0;
  Data := nil;
  // The first byte may take as long as the client likes - an idle connection is
  // fine, the ping/pong loop watches whether it is still alive. Once a frame
  // has BEGUN the rest of it has to follow promptly (a client that sends a
  // header and then goes quiet would otherwise hold this thread and a
  // connection slot forever).
  if FTransport.Read(Hdr[0], 1) <> 1 then Exit;
  FrameStart := GetTickCount64;
  FTransport.SetReadTimeout(FListener.FrameTimeoutMs);
  try
    // TCP may deliver a frame in pieces; every field is read in full.
    if not ReadExact(FTransport, Hdr[1], 1) then Exit;
    AOpcode := Hdr[0] and $0F;
    if AOpcode = 8 then Exit;
    // RFC 6455 5.1: a client MUST mask every frame it sends.
    if (Hdr[1] and $80) = 0 then Exit;
    LenByte := Hdr[1] and $7F;
    Len := LenByte;
    if LenByte = 126 then
    begin
      if not ReadExact(FTransport, Ext[0], 2) then Exit;
      Len := (Ext[0] shl 8) or Ext[1];
    end
    else if LenByte = 127 then
    begin
      if not ReadExact(FTransport, Ext8[0], 8) then Exit;
      Len := 0;
      for i := 0 to 7 do
        Len := (Len shl 8) or Ext8[i];
      if Len < 0 then Exit;
    end;
    MaxLen := FListener.MaxFrameBytes;
    if (MaxLen <= 0) or (MaxLen > WS_MAX_FRAME_LEN) then MaxLen := WS_MAX_FRAME_LEN;
    if Len > MaxLen then Exit;
    // Control frames (close/ping/pong): at most 125 bytes and never fragmented (RFC 6455 5.5).
    if (AOpcode >= 8) and ((Len > 125) or ((Hdr[0] and $80) = 0)) then Exit;
    if not ReadExact(FTransport, Mask[0], 4) then Exit;

    // The buffer grows as the bytes actually arrive; a header that merely
    // DECLARES a large frame reserves nothing.
    Received := 0;
    while Received < Len do
    begin
      if GetTickCount64 - FrameStart > QWord(FListener.FrameTimeoutMs) * 4 then Exit;   // dribbling
      Chunk := Integer(Len - Received);
      if Chunk > 65536 then Chunk := 65536;
      if Length(Data) < Received + Chunk then SetLength(Data, Received + Chunk);
      i := FTransport.Read(Data[Received], Chunk);
      if i <= 0 then Exit;
      Inc(Received, i);
    end;
    for i := 0 to Integer(Len) - 1 do
      Data[i] := Data[i] xor Mask[i mod 4];
    if Len > 0 then
      SetString(APayload, PAnsiChar(@Data[0]), Integer(Len))
    else
      APayload := '';
    Result := True;
  finally
    FTransport.SetReadTimeout(0);
  end;
end;

procedure TVDRX_WSConnection.SendFrame(const APayload: string; AOpcode: Byte);
begin
  EnqueueFrame(APayload, AOpcode);
end;

procedure TVDRX_WSConnection.EnqueueFrame(const APayload: string; AOpcode: Byte);
begin
  if FStopping then Exit;
  FSendLock.Enter;
  try
    if FStopping then Exit;
    // Control frames (ping/pong/close) must never sit behind a potentially
    // large data backlog. Otherwise the ping itself can be delayed until the
    // browser misses the pong deadline, causing the connection to flap.
    if AOpcode >= 8 then
      FControlQueue.Add(Char(AOpcode) + APayload)
    else
    begin
      // a client that can't keep up loses its OLDEST data frames rather than
      // growing the queue without limit; SendLoop tells it how many
      if (FMaxQueue > 0) and (FSendQueue.Count >= FMaxQueue) then
      begin
        FSendQueue.Delete(0);
        Inc(FDropped);
      end;
      FSendQueue.Add(Char(AOpcode) + APayload);
    end;
  finally
    FSendLock.Leave;
  end;
  FSendEvent.SetEvent;
end;

function TVDRX_WSConnection.WriteAll(const ABuf: string): Boolean;
var
  Sent, N: Integer;
begin
  Result := False;
  if FStopping or (Length(ABuf) = 0) then Exit;
  Sent := 0;
  while Sent < Length(ABuf) do
  begin
    try
      N := FTransport.Write(ABuf[Sent + 1], Length(ABuf) - Sent);
    except
      Exit;
    end;
    if N <= 0 then Exit;
    Inc(Sent, N);
  end;
  Result := True;
end;

procedure TVDRX_WSConnection.SendLoop;
var
  Frame: string;
  Opcode: Byte;
  Payload: string;
  Hdr: array[0..9] of Byte;
  HdrLen: Integer;
  Buf: string;
  PayloadLen: UInt64;
  i: Integer;
begin
  while not FStopping do
  begin
    if FSendEvent.WaitFor(500) <> wrSignaled then
      Continue;

    while not FStopping do
    begin
      Frame := '';
      FSendLock.Enter;
      try
        // once the backlog has drained a bit, say how much was dropped
        if (FDropped > 0) and (FSendQueue.Count <= FMaxQueue div 2) then
        begin
          FSendQueue.Insert(0, Char(1) + Format('{"event":"dropped","count":%d}', [FDropped]));
          FDropped := 0;
        end;
        if FControlQueue.Count > 0 then
        begin
          Frame := FControlQueue[0];
          FControlQueue.Delete(0);
        end
        else if FSendQueue.Count > 0 then
        begin
          Frame := FSendQueue[0];
          FSendQueue.Delete(0);
        end;
      finally
        FSendLock.Leave;
      end;

      if Frame = '' then Break;
      Opcode := Byte(Frame[1]);
      Payload := Copy(Frame, 2, MaxInt);
      PayloadLen := UInt64(Length(Payload));
      Hdr[0] := $80 or Opcode;
      if PayloadLen < 126 then
      begin
        Hdr[1] := Byte(PayloadLen);
        HdrLen := 2;
      end
      else if PayloadLen <= 65535 then
      begin
        Hdr[1] := 126;
        Hdr[2] := (PayloadLen shr 8) and $FF;
        Hdr[3] := PayloadLen and $FF;
        HdrLen := 4;
      end
      else
      begin
        Hdr[1] := 127;
        for i := 0 to 7 do
          Hdr[2 + i] := (PayloadLen shr ((7 - i) * 8)) and $FF;
        HdrLen := 10;
      end;
      SetString(Buf, PAnsiChar(@Hdr[0]), HdrLen);
      Buf := Buf + Payload;
      if Length(Buf) > 0 then
      begin
        if not WriteAll(Buf) then
        begin
          // The client stopped reading (or went away). Closing the socket wakes the thread that is
          // blocked reading it, so the whole connection is torn down instead of lingering.
          FStopping := True;
          try FTransport.Close; except end;
          Break;
        end;
      end;
    end;
  end;
end;

{ TVDRX_WSProtocolExecutive }

// Does the allow-pattern AAllow cover EVERY topic the filter AFilter could match?
// ("http.reply.*" covers "http.reply.1" and "http.reply.*"; "a.*" does not
// cover "a.>"; ">" covers everything.) This is what a subscribe must satisfy -
// a plain TopicMatches would let a client subscribe to ">" if "x" were allowed.
function TopicFilterCovers(const AAllow, AFilter: string): Boolean;
var
  A, F: TStringDynArray;
  i: Integer;
begin
  Result := False;
  if (AAllow = '') or (AFilter = '') then Exit;
  A := SplitString(AAllow, '.');
  F := SplitString(AFilter, '.');
  for i := 0 to High(A) do
  begin
    if A[i] = '>' then Exit(Length(F) > i);
    if i > High(F) then Exit(False);
    if F[i] = '>' then Exit(False);
    if A[i] = '*' then Continue;
    if (F[i] = '*') or (F[i] <> A[i]) then Exit(False);
  end;
  Result := Length(F) = Length(A);
end;

function AnyPatternCovers(const AList, AFilter: string): Boolean;
var
  P: string;
begin
  Result := False;
  for P in SplitString(AList, ',') do
    if TopicFilterCovers(Trim(P), AFilter) then Exit(True);
end;

function AnyPatternMatches(const AList, ATopic: string): Boolean;
var
  P: string;
begin
  Result := False;
  if ATopic = '' then Exit;
  for P in SplitString(AList, ',') do
    if (Trim(P) <> '') and TopicMatches(Trim(P), ATopic) then Exit(True);
end;

// A WebSocket frame carries the bus payload as JSON. Payloads that already are
// JSON go through unchanged; anything else (a plain-text log line, say) becomes
// a JSON string, so a frame is always valid JSON.
function PayloadAsJSON(const APayload: string): string;
var
  J: TJSONData;
begin
  Result := CleanUTF8(APayload);
  if Trim(Result) = '' then Exit('""');
  try
    J := GetJSON(Result);
    J.Free;
  except
    Result := JSONString(Result);
  end;
end;

constructor TVDRX_WSProtocolExecutive.Create(ABus: TVDRX_MessageQueue; AListener: TVDRX_WebSocketExecutive; AConn: TVDRX_WSConnection);
begin
  inherited Create(ABus);
  FListener := AListener;
  FConn := AConn;
  FAuthenticated := False;
end;

procedure TVDRX_WSProtocolExecutive.Deny(const AMethod, ATopic: string);
begin
  Bus.Publish('log.warn', 'ws ' + FConn.ID + ': profile "' + FProfile.ID + '" may not ' + AMethod + ' "' + ATopic + '"', ID);
  Bus.Publish(FConn.ID + '.rpc.out', Format('{"event":"denied","method":%s,"topic":%s}', [JSONString(AMethod), JSONString(CleanUTF8(ATopic))]), ID);
end;

procedure TVDRX_WSProtocolExecutive.ApplyDefaultSubscribe;
var
  F: string;
begin
  for F in SplitString(FProfile.DefaultSubscribe, ',') do
    if (Trim(F) <> '') and AnyPatternCovers(FProfile.SubscribeAllow, Trim(F)) then
      FListener.Registry.Register(FConn, FConn.ID, Trim(F))
    else if Trim(F) <> '' then
      Bus.Publish('log.warn', 'ws profile "' + FProfile.ID + '": default_subscribe "' + Trim(F) + '" is not covered by subscribe_allow - skipped', ID);
end;

procedure TVDRX_WSProtocolExecutive.HandlePacket(const AMsg: TVDRX_Message);
var
  J: TJSONData;
  Obj: TJSONObject;
  PayloadData: TJSONData;
  Method, Topic, Payload, Token, Src, ProfName, PeerIP: string;
begin
  try
    J := GetJSON(AMsg.Payload);
  except
    Bus.Publish('log.warn', 'ws ' + FConn.ID + ': dropped malformed JSON RPC: ' + AMsg.Payload, ID);
    Exit;
  end;
  try
    if not (J is TJSONObject) then Exit;
    Obj := TJSONObject(J);
    Method := Obj.Get('method', '');

    if Method = 'sys.auth' then
    begin
      Token := Obj.Get('token', '');
      ProfName := Obj.Get('profile', '');
      Src := Obj.Get('source', FConn.ID);
      PeerIP := FConn.FTransport.PeerAddr;
      // Fail closed. A sys.auth on a connection that already has a session ends that session FIRST:
      // authentication is dropped and every subscription made under the old profile is removed, so
      // neither a downgrade to a weaker profile nor a failed attempt can keep the old profile's
      // topics flowing. The outcome of this sys.auth then starts from nothing.
      if FAuthenticated then
      begin
        FAuthenticated := False;
        VDRX_ClearSourcePublishPolicy(FConn.ID);
        FListener.Registry.ClearFilters(FConn.ID);
        FListener.Registry.Register(FConn, FConn.ID, FConn.ID + '.rpc.out');   // the connection's own reply channel
        Bus.Publish('log.info', 'ws ' + FConn.ID + ': re-authentication - previous session and subscriptions dropped', ID);
      end;
      if FListener.AuthLocked(PeerIP) then
      begin
        // too many recent failures from this address: refuse without even checking the token
        FAuthenticated := False;
        Bus.Publish('log.warn', 'ws ' + FConn.ID + ': sys.auth refused - ' + PeerIP + ' is locked out after repeated failures', ID);
        Bus.Publish(FConn.ID + '.rpc.out', '{"event":"auth.fail"}', ID);
        Exit;
      end;
      if FListener.ProfileMode then
      begin
        // ws_profiles: the token (or the named profile) selects what this client may do
        FAuthenticated := FListener.ResolveProfile(ProfName, Token, FProfile);
        if FAuthenticated then
        begin
          FListener.NoteAuthSuccess(PeerIP);
          if FProfile.MaxQueue > 0 then FConn.MaxQueue := FProfile.MaxQueue;
          // executives that answer a request's reply_to may only publish where this profile could itself
          VDRX_SetSourcePublishPolicy(FConn.ID, FProfile.PublishAllow);
          Bus.Publish('log.info', 'ws ' + FConn.ID + ': authenticated as profile "' + FProfile.ID + '"', ID);
          Bus.Publish(FConn.ID + '.rpc.out', Format('{"event":"auth.ok","source":%s,"profile":%s}', [JSONString(Src), JSONString(FProfile.ID)]), ID);
          ApplyDefaultSubscribe;
        end
        else
        begin
          Bus.Publish('log.warn', 'ws ' + FConn.ID + ': sys.auth rejected (profile "' + ProfName + '")', ID);
          Bus.Publish(FConn.ID + '.rpc.out', '{"event":"auth.fail"}', ID);
          if FListener.NoteAuthFailure(PeerIP) then
            Bus.Publish('log.warn', 'ws: ' + PeerIP + ' locked out of sys.auth for ' + IntToStr(AUTH_LOCKOUT_MS div 1000) +
              ' s after ' + IntToStr(AUTH_MAX_FAILURES) + ' failed attempts', ID);
        end;
        Exit;
      end;
      // No ws_profiles. Closed unless the operator explicitly opted in.
      if not FListener.AllowOpenAccess then
      begin
        FAuthenticated := False;
        Bus.Publish('log.warn', 'ws ' + FConn.ID + ': sys.auth rejected - no ws_profiles are defined (define ws_profiles, or set executives.ws.allow_open_access for a throwaway dev setup)', ID);
        Bus.Publish(FConn.ID + '.rpc.out', '{"event":"auth.fail"}', ID);
        Exit;
      end;
      FAuthenticated := Token <> '';
      if FAuthenticated then
      begin
        Bus.Publish('log.info', 'ws ' + FConn.ID + ': authenticated (allow_open_access: any nonempty token passes)', ID);
        Bus.Publish(FConn.ID + '.rpc.out', Format('{"event":"auth.ok","source":%s}', [JSONString(Src)]), ID);
      end
      else
      begin
        Bus.Publish('log.warn', 'ws ' + FConn.ID + ': sys.auth sent with an empty token, rejected', ID);
        Bus.Publish(FConn.ID + '.rpc.out', '{"event":"auth.fail"}', ID);
      end;
      Exit;
    end;

    if not FAuthenticated then
    begin
      Bus.Publish('log.warn', 'ws ' + FConn.ID + ': "' + Method + '" ignored - not authenticated yet', ID);
      Exit;
    end;

    if Method = 'subscribe' then
    begin
      Topic := Obj.Get('filter', '');
      if FListener.ProfileMode and not AnyPatternCovers(FProfile.SubscribeAllow, Topic) then
      begin
        Deny('subscribe', Topic);
        Exit;
      end;
      Bus.Publish('log.info', 'ws ' + FConn.ID + ': subscribe "' + Topic + '"', ID);
      FListener.Registry.Register(FConn, FConn.ID, Topic);
    end
    else if Method = 'unsubscribe' then
    begin
      Topic := Obj.Get('filter', '');
      Bus.Publish('log.info', 'ws ' + FConn.ID + ': unsubscribe "' + Topic + '"', ID);
      FListener.Registry.UnregisterFilter(FConn.ID, Topic);
    end
    else if Method = 'unsubscribe_all' then
    begin
      Bus.Publish('log.info', 'ws ' + FConn.ID + ': unsubscribe_all', ID);
      FListener.Registry.ClearFilters(FConn.ID);
      FListener.Registry.Register(FConn, FConn.ID, FConn.ID + '.rpc.out');   // keep the connection's own reply channel
    end
    else if Method = 'publish' then
    begin
      Topic := Obj.Get('topic', '');
      if FListener.ProfileMode and not AnyPatternMatches(FProfile.PublishAllow, Topic) then
      begin
        Deny('publish', Topic);
        Exit;
      end;
      // Outside ws_profiles there is no per-client allow-list at all (any
      // non-empty sys.auth token gets in - see SetupWSProfiles's comment),
      // so without this, any WS client could publish to "sys.kill"/"sys.quit"/
      // "sys.killall" and tear down supervised processes or the daemon
      // itself. "sys.>" always needs an explicit ws_profiles publish_allow
      // entry, profiles or not.
      if (not FListener.ProfileMode) and TopicMatches('sys.>', Topic) then
      begin
        Deny('publish', Topic);
        Exit;
      end;
      PayloadData := Obj.Find('payload');
      if not Assigned(PayloadData) then
        Payload := '{}'
      else if PayloadData.JSONType = jtString then
        Payload := PayloadData.AsString
      else
        Payload := PayloadData.AsJSON;
      Bus.Publish('log.info', 'ws ' + FConn.ID + ': publish "' + Topic + '" ' + Payload, ID);
      Bus.Publish(Topic, Payload, FConn.ID);
    end
    else
      Bus.Publish('log.warn', 'ws ' + FConn.ID + ': unrecognised RPC method "' + Method + '"', ID);
  finally
    J.Free;
  end;
end;

procedure TVDRX_WSConnection.RunLoop;
var
  Payload: string;
  Opcode: Byte;
begin
  // The teardown below must run whether or not the handshake succeeds. It used to be skipped on a
  // failed handshake, which left this connection's send thread, protocol executive and registry
  // entries behind: one leaked thread per junk connection, a remote denial of service.
  if DoHandshake then
  begin
    FLastPong := Now;
    FPingThread := TVDRX_WorkerThread.Create(@PingLoop);
    FPingThread.Start;

    while True do
    begin
      if not ReadFrame(Payload, Opcode) then Break;
      case Opcode of
        1: Bus.Publish(ID + '.rpc.in', Payload, ID);
        9: SendFrame(Payload, 10);
        10: FLastPong := Now;
      end;
    end;
  end
  else
    Bus.Publish('log.warn', 'ws ' + ID + ': handshake failed, dropping connection', ID);

  FStopping := True;
  // The connection is over: give its slot back now, not after the chores below (joining the ping
  // thread can take a second). Must stay before UnregisterSelf, which can destroy this object.
  FListener.ConnectionEnded(FPeerAddr);
  if Assigned(FPingThread) then
  begin
    WaitThreadOrTimeout(FPingThread, 1000);
    FreeAndNil(FPingThread);
  end;

  Bus.Publish('log.info', 'ws ' + ID + ': disconnected', ID);
  Bus.Publish('sys.ws.disconnected', Format('{"id":%s}', [JSONString(ID)]), ID);
  FListener.Registry.Unregister(ID + '.rpc');
  VDRX_ClearSourcePublishPolicy(ID);
  FListener.Registry.UnregisterSelf(ID);
end;

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
      SendFrame('', 9);
    except
      Break;
    end;
  end;
end;

procedure TVDRX_WSConnection.Initialize;
begin
  FSendThread := TVDRX_WorkerThread.Create(@SendLoop);
  FSendThread.Start;
  FThread := TWSConnThread.Create(Self);
  FThread.Start;
end;

procedure TVDRX_WSConnection.Shutdown;
begin
  FStopping := True;
  if Assigned(FSendEvent) then FSendEvent.SetEvent;
  FTransport.Close;
  if Assigned(FThread) then
  begin
    WaitThreadOrTimeout(FThread, FListener.GracefulTimeoutMs);
    FThread := nil;
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
  if Assigned(FSendThread) then
  begin
    if WaitThreadOrTimeout(FSendThread, FListener.GracefulTimeoutMs) then
    begin
      FSendThread.Free;
      FSendThread := nil;
    end
    else
      Bus.Publish('log.warn', 'ws ' + ID + ': send thread did not exit in time - abandoning it', ID);
  end;
end;

procedure TVDRX_WSConnection.HandlePacket(const AMsg: TVDRX_Message);
begin
  if AMsg.Topic = ID + '.rpc.out' then
  begin
    SendFrame(AMsg.Payload);
    Exit;
  end;
  SendFrame(Format('{"topic":%s,"payload":%s,"source":%s,"seq":%d}',
    [JSONString(CleanUTF8(AMsg.Topic)), PayloadAsJSON(AMsg.Payload), JSONString(CleanUTF8(AMsg.SourceID)), AMsg.Seq]));
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
  FAllowOpenAccess := False;
  FLiveConns := 0;
  FAllowedOrigins := TStringList.Create;
  FAllowedOrigins.CaseSensitive := False;
  FMaxFrameBytes := 1024 * 1024;
  FFrameTimeoutMs := 15000;
  FWriteTimeoutMs := 15000;
  FAuthLock := TCriticalSection.Create;
  FAuthTrack := specialize TDictionary<string, TVDRX_AuthTrack>.Create;
end;

destructor TVDRX_WebSocketExecutive.Destroy;
begin
  FAuthTrack.Free;
  FAuthLock.Free;
  FAllowedOrigins.Free;
  inherited Destroy;
end;

function TVDRX_WebSocketExecutive.ProfileMode: Boolean;
begin
  Result := Length(FProfiles) > 0;
end;

function TVDRX_WebSocketExecutive.AuthLocked(const AIP: string): Boolean;
var
  T: TVDRX_AuthTrack;
begin
  Result := False;
  FAuthLock.Acquire;
  try
    if FAuthTrack.TryGetValue(AIP, T) then
      Result := T.LockedUntil > GetTickCount64;
  finally
    FAuthLock.Release;
  end;
end;

function TVDRX_WebSocketExecutive.NoteAuthFailure(const AIP: string): Boolean;
var
  T: TVDRX_AuthTrack;
  Now: QWord;
  Key: string;
  Stale: TStringList;
begin
  Result := False;
  Now := GetTickCount64;
  FAuthLock.Acquire;
  try
    if not FAuthTrack.TryGetValue(AIP, T) then
    begin
      T.Fails := 0; T.WindowStart := Now; T.LockedUntil := 0;
      if FAuthTrack.Count >= AUTH_TRACK_MAX then
      begin
        // make room: forget addresses whose window and lockout have both expired
        Stale := TStringList.Create;
        try
          for Key in FAuthTrack.Keys do
            if (Now - FAuthTrack[Key].WindowStart > AUTH_WINDOW_MS) and (FAuthTrack[Key].LockedUntil <= Now) then
              Stale.Add(Key);
          for Key in Stale do FAuthTrack.Remove(Key);
        finally
          Stale.Free;
        end;
      end;
    end;
    if Now - T.WindowStart > AUTH_WINDOW_MS then
    begin
      T.Fails := 0;
      T.WindowStart := Now;
    end;
    Inc(T.Fails);
    if T.Fails >= AUTH_MAX_FAILURES then
    begin
      T.LockedUntil := Now + AUTH_LOCKOUT_MS;
      T.Fails := 0;
      T.WindowStart := Now;
      Result := True;
    end;
    FAuthTrack.AddOrSetValue(AIP, T);
  finally
    FAuthLock.Release;
  end;
end;

procedure TVDRX_WebSocketExecutive.NoteAuthSuccess(const AIP: string);
begin
  FAuthLock.Acquire;
  try
    FAuthTrack.Remove(AIP);
  finally
    FAuthLock.Release;
  end;
end;

// Compares two secrets without stopping at the first differing byte, so the
// time taken does not reveal how much of a guess was right. The loop always
// runs over the longer of the two strings and the lengths are folded into
// the result.
function VDRX_TokensEqual(const A, B: string): Boolean;
var
  i, n: Integer;
  Diff, CA, CB: Cardinal;
begin
  Diff := Cardinal(Length(A)) xor Cardinal(Length(B));
  n := Length(A);
  if Length(B) > n then n := Length(B);
  for i := 1 to n do
  begin
    if i <= Length(A) then CA := Ord(A[i]) else CA := 0;
    if i <= Length(B) then CB := Ord(B[i]) else CB := 0;
    Diff := Diff or (CA xor CB);
  end;
  Result := Diff = 0;
end;

// ResolveProfile: by name ("profile" in sys.auth): that profile, if its token
// is empty or matches. Without a name: the first profile whose (non-empty)
// token matches.
function TVDRX_WebSocketExecutive.ResolveProfile(const AName, AToken: string; out AProfile: TVDRX_WSProfile): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(FProfiles) do
    if AName <> '' then
    begin
      if FProfiles[i].ID <> AName then Continue;
      if (FProfiles[i].Token = '') or VDRX_TokensEqual(FProfiles[i].Token, AToken) then
      begin
        AProfile := FProfiles[i];
        Exit(True);
      end;
      Exit(False);
    end
    else if (FProfiles[i].Token <> '') and VDRX_TokensEqual(FProfiles[i].Token, AToken) then
    begin
      AProfile := FProfiles[i];
      Exit(True);
    end;
end;

function TVDRX_WebSocketExecutive.NextConnID: string;
begin
  Inc(FConnCounter);
  Result := 'ws.conn.' + IntToStr(FConnCounter);
end;

function TVDRX_WebSocketExecutive.AdoptConnection(ATransport: TVDRX_Transport; const AInitialRequest: string): Boolean;
const
  REFUSED = 'HTTP/1.1 503 Service Unavailable'#13#10'Connection: close'#13#10'Content-Length: 0'#13#10#13#10;
var
  Conn: TVDRX_WSConnection;
  Protocol: TVDRX_WSProtocolExecutive;
  NewID: string;
  Filter: string;
begin
  // max_connections counts LIVE WebSocket connections. (The accept loop's own count only covers
  // the moment of accepting: a WS connection runs on its own threads and leaves that list at once.)
  Result := False;
  if (FMaxConnections > 0) and (InterlockedIncrement(FLiveConns) > FMaxConnections) then
  begin
    InterlockedDecrement(FLiveConns);
    try ATransport.Write(REFUSED[1], Length(REFUSED)); except end;
    ATransport.Free;
    NoteRejected(0, '');
    Exit;
  end;
  if FMaxConnections <= 0 then InterlockedIncrement(FLiveConns);
  // per-address cap on LIVE connections (the accept-time per-IP count is gone once this thread returns)
  if not Limiter.TryAcquireLive(ATransport.PeerAddr) then
  begin
    InterlockedDecrement(FLiveConns);
    try ATransport.Write(REFUSED[1], Length(REFUSED)); except end;
    NoteRejected(1, ATransport.PeerAddr);
    ATransport.Free;
    Exit;
  end;
  Result := True;
  Conn := TVDRX_WSConnection.Create(Bus, Self, ATransport);
  Conn.PendingRequest := AInitialRequest;
  NewID := NextConnID;
  Bus.Publish('sys.ws.connected', Format('{"id":%s}', [JSONString(NewID)]), ID);
  Bus.Publish('log.info', 'ws: new connection ' + NewID, ID);
  FRegistry.Register(Conn, NewID, NewID + '.rpc.out');
  // with ws_profiles, nothing is subscribed until sys.auth picks a profile
  if (FDefaultSubscribe <> '') and not ProfileMode then
    for Filter in SplitString(FDefaultSubscribe, ',') do
      FRegistry.Register(Conn, NewID, Trim(Filter));
  Protocol := TVDRX_WSProtocolExecutive.Create(Bus, Self, Conn);
  FRegistry.Register(Protocol, NewID + '.rpc', NewID + '.rpc.in');
  Conn.Initialize;
end;

procedure TVDRX_WebSocketExecutive.ConnectionEnded(const APeerAddr: string);
begin
  Limiter.ReleaseLive(APeerAddr);
  InterlockedDecrement(FLiveConns);
end;

function TVDRX_WebSocketExecutive.OriginAllowed(const ARequest: string): Boolean;
var
  HeadBlock, Origin, HostHdr: string;
  p: Integer;
begin
  p := Pos(#13#10#13#10, ARequest);
  if p > 0 then HeadBlock := Copy(ARequest, 1, p - 1) else HeadBlock := ARequest;
  Origin := ExtractHeaderValue(HeadBlock, 'Origin');
  if Origin = '' then Exit(True);                       // not a browser
  if FAllowedOrigins.IndexOf(Origin) >= 0 then Exit(True);
  HostHdr := ExtractHeaderValue(HeadBlock, 'Host');
  Result := (HostHdr <> '') and (HostNameOf(Origin) = HostNameOf(HostHdr));
end;

procedure TVDRX_WebSocketExecutive.HandleConnection(ATransport: TVDRX_Transport);
begin
  AdoptConnection(ATransport, '');
end;

procedure TVDRX_WebSocketExecutive.HandlePacket(const AMsg: TVDRX_Message);
begin
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

{ TVDRX_SocketClientExecutive }

end.
