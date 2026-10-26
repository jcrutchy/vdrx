unit vdrx_network;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, Sockets, SyncObjs, Process, vdrx_core,
  vdrx_config, vdrx_templates, vdrx_procutil, Generics.Collections,
  openssl, resolve, {$IFDEF UNIX}BaseUnix,{$ENDIF} base64, sha1, fpjson, jsonparser, DateUtils, RegExpr, Types;

type

  TVDRX_SocketListenerExecutive = class;
  TVDRX_WebSocketExecutive = class;

  TVDRX_ProxyRoute = record
    Prefix: string;
    Host: string;
    Port: Word;
  end;
  TVDRX_ProxyRoutes = array of TVDRX_ProxyRoute;

  // One HTTP route onto the bus: requests under Prefix are published as a JSON
  // envelope to InTopic and the reply that comes back becomes the HTTP response.
  // Kind 'bus'  : publish straight away (http_routes; legacy bus-daemon routes).
  // Kind 'cgi'  : first map the URL onto a script under DocRoot (index files,
  //               PATH_INFO, front-controller Fallback, static files), then publish
  //               with script_name/script_filename/path_info filled in (cgi entries).
  TVDRX_BusRoute = record
    ID: string;
    Kind: string;
    Prefix: string;
    InTopic: string;
    Allow: string;        // comma-separated HTTP methods accepted; '' = any
    TimeoutMs: Integer;
    ContentType: string;  // default for a reply that doesn't say
    Response: string;     // 'raw' (default): use the reply's status/headers/body; 'json': hand back the whole envelope as application/json
    // kind 'cgi' only
    DocRoot: string;
    Extensions: string;   // lower-case, wrapped in commas (',.php,.cgi,'); '' = every file is a script
    IndexFiles: string;   // comma-separated, tried in order for a directory URL
    Fallback: string;     // URL path (under Prefix) of a front-controller script, '' = none
    Static: Boolean;      // serve non-script files from DocRoot directly
  end;
  TVDRX_BusRoutes = array of TVDRX_BusRoute;

  // "rewrites": regex on the request path -> new target (may carry ?query).
  // Flag: 'last' (default, first match wins) | 'continue' | 'redirect' (302) | 'permanent' (301)
  TVDRX_RewriteRule = record
    Pattern: string;
    Target: string;
    Flag: string;
  end;
  TVDRX_RewriteRules = array of TVDRX_RewriteRule;

  // Everything the HTTP edge consults, in the order it consults it.
  TVDRX_RouteTable = record
    Rewrites: TVDRX_RewriteRules;
    Proxy: TVDRX_ProxyRoutes;
    Bus: TVDRX_BusRoutes;
  end;

  // Facts about the connection a request arrived on (CGI wants REMOTE_ADDR etc.)
  TVDRX_ConnInfo = record
    RemoteAddr: string;
    RemotePort: Word;
    ServerPort: Word;
    Secure: Boolean;
  end;

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

  TVDRX_Transport = class
  public
    PeerAddr: string;   // set by the accept loops (dotted IPv4)
    PeerPort: Word;
    Secure: Boolean;    // True for a TLS connection
    function Read(var ABuf; ALen: Integer): Integer; virtual; abstract;
    function Write(const ABuf; ALen: Integer): Integer; virtual; abstract;
    procedure Close; virtual; abstract;
    procedure SetReadTimeout(ATimeoutMs: Integer); virtual; abstract;
    // Bounds a single underlying send() so a stalled/half-open peer (send
    // buffer full, no ACKs coming back) fails a Write within ATimeoutMs
    // instead of blocking for the OS's TCP retransmit ceiling (which can be
    // 15-30 minutes). Without this, any HandlePacket that writes straight to
    // a transport - e.g. TVDRX_SocketClientExecutive - can wedge whatever
    // thread calls it for that entire window. Pass 0 to wait indefinitely
    // (the old, unbounded default).
    procedure SetWriteTimeout(ATimeoutMs: Integer); virtual; abstract;
  end;

  TVDRX_PlainTransport = class(TVDRX_Transport)
  private
    FSocket: TSocket;
  public
    constructor Create(ASocket: TSocket);
    function Read(var ABuf; ALen: Integer): Integer; override;
    function Write(const ABuf; ALen: Integer): Integer; override;
    procedure Close; override;
    procedure SetReadTimeout(ATimeoutMs: Integer); override;
    procedure SetWriteTimeout(ATimeoutMs: Integer); override;
  end;

  TVDRX_TLSTransport = class(TVDRX_Transport)
  private
    FSocket: TSocket;
    FSSL: PSSL;
    FOK: Boolean;
  public
    constructor Create(ASocket: TSocket; ACtx: PSSL_CTX); overload;
    constructor Create(ASocket: TSocket; ACtx: PSSL_CTX; const AHostname: string); overload;
    destructor Destroy; override;
    property Handshook: Boolean read FOK;
    function Read(var ABuf; ALen: Integer): Integer; override;
    function Write(const ABuf; ALen: Integer): Integer; override;
    procedure Close; override;
    procedure SetReadTimeout(ATimeoutMs: Integer); override;
    procedure SetWriteTimeout(ATimeoutMs: Integer); override;
  end;

  TVDRX_TLSContext = class
  private
    FCtx: PSSL_CTX;
    FOK: Boolean;
  public
    constructor Create(const ACertFile, AKeyFile: string);
    destructor Destroy; override;
    property OK: Boolean read FOK;
    property Ctx: PSSL_CTX read FCtx;
  end;

  TVDRX_TLSClientContext = class
  private
    FCtx: PSSL_CTX;
    FOK: Boolean;
  public
    constructor Create(const ACAFile: string; AVerifyPeer: Boolean);
    destructor Destroy; override;
    property OK: Boolean read FOK;
    property Ctx: PSSL_CTX read FCtx;
  end;

  TVDRX_ListenerConnThread = class(TThread)
  private
    FOwner: TVDRX_SocketListenerExecutive;
    FTransport: TVDRX_Transport;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TVDRX_SocketListenerExecutive; ATransport: TVDRX_Transport);
    property Transport: TVDRX_Transport read FTransport;
  end;

  TVDRX_SocketListenerExecutive = class(TVDRX_Executive)
  private
    FPort: Word;
    FTLSPort: Word;
    FTLSCertFile: string;
    FTLSKeyFile: string;
    FTLSContext: TVDRX_TLSContext;
    FBacklog: Integer;
    FPlainSocket: TSocket;
    FTLSSocket: TSocket;
    FPlainThread: TThread;
    FTLSThread: TThread;
    FStopping: Boolean;
    FGracefulTimeoutMs: Integer;
    FCriticalSection: TCriticalSection;
    FActiveConnections: TList;
    FBindAddress: string;
    FMaxConnections: Integer;
    FLastRejectLog: QWord;
    FRejectedSinceLog: Integer;

    function BindListenSocket(APort: Word): TSocket;
    function ConnectionLimitReached: Boolean;
    procedure NoteRejected;
    procedure AcceptLoopPlain;
    procedure AcceptLoopTLS;
    function WaitConnGone(AThread: TVDRX_ListenerConnThread; ATimeoutMs: Integer): Boolean;
  protected
    procedure HandleConnection(ATransport: TVDRX_Transport); virtual; abstract;
    procedure RegisterConnection(AThread: TVDRX_ListenerConnThread);
    procedure UnregisterConnection(AThread: TVDRX_ListenerConnThread);
  public
    constructor Create(ABus: TVDRX_MessageQueue); override;
    destructor Destroy; override;
    property Port: Word read FPort write FPort;
    property TLSPort: Word read FTLSPort;
    function TLSActive: Boolean;
    procedure ConfigureTLS(ATLSPort: Word; const ACertFile, AKeyFile: string);
    property Backlog: Integer read FBacklog write FBacklog;
    // Interface the listener binds to. Default 127.0.0.1 (loopback only);
    // '0.0.0.0' = every interface, or the address of one specific interface.
    property BindAddress: string read FBindAddress write FBindAddress;
    // Concurrent connections this listener will serve; more are closed at
    // once. 0 = unlimited (not recommended).
    property MaxConnections: Integer read FMaxConnections write FMaxConnections;
    property Stopping: Boolean read FStopping;
    property GracefulTimeoutMs: Integer read FGracefulTimeoutMs write FGracefulTimeoutMs;
    procedure Initialize; override;
    procedure Shutdown; override;
  end;

  TVDRX_OneShotWaiter = class(TVDRX_Executive)
  private
    FEvent: TEvent;
    FReplyPayload: string;
    FGotReply: Boolean;
  public
    constructor Create(ABus: TVDRX_MessageQueue); reintroduce;
    destructor Destroy; override;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    function WaitForReply(ATimeoutMs: Integer; out APayload: string): Boolean;
  end;

  TVDRX_HTTPExecutive = class(TVDRX_SocketListenerExecutive)
  private
    FConfig: TVDRX_Config;
    FTemplates: TVDRX_TemplateStore;
    FStaticDir: string;
    FRoutes: TVDRX_RouteTable;
    FRegistry: TVDRX_Registry;
    FCustomHeaders: TStringList;
  protected
    procedure HandleConnection(ATransport: TVDRX_Transport); override;
  public
    constructor Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config;
      ATemplates: TVDRX_TemplateStore;
      const AStaticDir: string; const ARoutes: TVDRX_RouteTable;
      ARegistry: TVDRX_Registry); reintroduce;
    destructor Destroy; override;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    procedure ApplyConfig; override;
    property CustomHeaders: TStringList read FCustomHeaders;
    class function BuildResponse(const ARequest: string;
      ATemplates: TVDRX_TemplateStore; AConfig: TVDRX_Config; const AStaticDir: string;
      const ARoutes: TVDRX_RouteTable; const AConn: TVDRX_ConnInfo;
      ABus: TVDRX_MessageQueue; ARegistry: TVDRX_Registry; const ASourceID: string;
      ACustomHeaders: TStringList = nil): string;
  end;

  TVDRX_ConnectionExecutive = class(TVDRX_Executive)
  protected
    FTransport: TVDRX_Transport;
  public
    destructor Destroy; override;
  end;

  TVDRX_HTTPConnection = class(TVDRX_ConnectionExecutive)
  private
    FTemplates: TVDRX_TemplateStore;
    FConfig: TVDRX_Config;
    FStaticDir: string;
    FRoutes: TVDRX_RouteTable;
    FConn: TVDRX_ConnInfo;
    FRegistry: TVDRX_Registry;
    FSourceID: string;
    FCustomHeaders: TStringList;
  public
    constructor Create(ABus: TVDRX_MessageQueue; ATransport: TVDRX_Transport;
      ATemplates: TVDRX_TemplateStore; AConfig: TVDRX_Config; const AStaticDir: string;
      const ARoutes: TVDRX_RouteTable; const AConn: TVDRX_ConnInfo;
      ARegistry: TVDRX_Registry; const ASourceID: string;
      ACustomHeaders: TStringList = nil); reintroduce;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    procedure Run(const ARequest: string = '');
  end;

  TVDRX_WSConnection = class(TVDRX_ConnectionExecutive)
  private
    FListener: TVDRX_WebSocketExecutive;
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
    procedure AdoptConnection(ATransport: TVDRX_Transport; const AInitialRequest: string);
    property PingIntervalMs: Integer read FPingIntervalMs write FPingIntervalMs;
    property PongTimeoutMs: Integer read FPongTimeoutMs write FPongTimeoutMs;
    property DefaultSubscribe: string read FDefaultSubscribe write FDefaultSubscribe;
  end;

  TVDRX_SocketClientExecutive = class(TVDRX_ConnectionExecutive)
  private
    FHost: string;
    FPort: Word;
    FTLS: Boolean;
    FTLSVerify: Boolean;
    FTLSCAFile: string;
    FTLSPeerName: string;
    FFraming: string;
    FDelimiter: string;
    FChunkSize: Integer;
    FReconnectPolicy: string;
    FReconnectDelayMs, FMaxReconnectDelayMs: Integer;
    FGracefulTimeoutMs: Integer;
    FPublishTopic: string;

    FTransportLock: TCriticalSection;
    FConnected: Boolean;
    FReaderThread: TThread;
    FMonitorThread: TThread;
    FStopping: Boolean;

    // Outbound writes are queued here and drained by FSendThread instead of
    // being written straight from HandlePacket - see SendLoop. This is the
    // same shape as TVDRX_WSConnection's FSendQueue/FSendEvent/SendLoop;
    // kept as a separate copy rather than a shared base class for now (see
    // vdrx_core.pas's TVDRX_Executive comment on not extracting a base class
    // until there are three near-identical examples).
    FSendLock: TCriticalSection;
    FSendEvent: TEvent;
    FSendQueue: TStringList;
    FSendThread: TThread;
    FWriteTimeoutMs: Integer;

    procedure DoConnect;
    procedure DoDisconnect;
    procedure ReaderLoop;
    procedure MonitorLoop;
    procedure SendLoop;
    procedure EnqueueLine(const ALine: string);
  public
    constructor Create(ABus: TVDRX_MessageQueue); override;
    destructor Destroy; override;
    property Host: string read FHost write FHost;
    property Port: Word read FPort write FPort;
    property TLS: Boolean read FTLS write FTLS;
    property TLSVerify: Boolean read FTLSVerify write FTLSVerify;
    property TLSCAFile: string read FTLSCAFile write FTLSCAFile;
    property TLSPeerName: string read FTLSPeerName write FTLSPeerName;
    property Framing: string read FFraming write FFraming;
    property Delimiter: string read FDelimiter write FDelimiter;
    property ChunkSize: Integer read FChunkSize write FChunkSize;
    property ReconnectPolicy: string read FReconnectPolicy write FReconnectPolicy;
    property PublishTopic: string read FPublishTopic write FPublishTopic;
    property ReconnectDelayMs: Integer read FReconnectDelayMs write FReconnectDelayMs;
    property MaxReconnectDelayMs: Integer read FMaxReconnectDelayMs write FMaxReconnectDelayMs;
    property GracefulTimeoutMs: Integer read FGracefulTimeoutMs write FGracefulTimeoutMs;
    // How long a single Write to the remote peer may block before it's
    // treated as failed (see TVDRX_Transport.SetWriteTimeout). Defaults to
    // 5000ms - set from vdrx.conf per socket_clients entry if you need a
    // different bound for a particular slow/flaky peer.
    property WriteTimeoutMs: Integer read FWriteTimeoutMs write FWriteTimeoutMs;
    procedure Initialize; override;
    procedure Shutdown; override;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
  end;

const
  MAX_HEADER_SIZE = 16384;
  // WebSocket sys.auth lockout (per client address)
  AUTH_MAX_FAILURES = 8;       // failed sys.auth attempts ...
  AUTH_WINDOW_MS    = 60000;   // ... within this long ...
  AUTH_LOCKOUT_MS   = 60000;   // ... lock that client address out for this long
  AUTH_TRACK_MAX    = 2048;    // addresses remembered at once (idle ones are dropped first)
  MAX_BODY_SIZE = 10 * 1024 * 1024;
  WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

var
  // Random per-process secret, generated once in vdrx.lpr at startup and
  // stamped into every envelope BuildEnvelope() produces. A CGI/runner
  // executive wired to an HTTP route (see vdrx_runner.pas's RequireEdgeToken)
  // refuses any request whose "_edge_token" doesn't match this value, which
  // is never exposed to WebSocket/admin clients. Without this, anything able
  // to publish onto a cgi/runner "<id>.in" topic - e.g. an unauthenticated
  // WebSocket client, see docs/known-gaps.md - could forge a "script_filename"
  // and get the CGI executive to run an arbitrary file: a real RCE path, not
  // just a bus-hygiene issue. Empty = no token configured (edge check is a
  // no-op); vdrx.lpr always sets this before SetupCGI/SetupLegacyCLIBridges run.
  GVDRXEdgeToken: string = '';

function ConnectTCP(const AHost: string; APort: Word): TVDRX_Transport;
function ConnectTCPHost(const AHost: string; APort: Word): TVDRX_Transport;
procedure ApplyOpenSSLDLLOverrides(AConfig: TVDRX_Config);

implementation

function ReadFullRequest(ATransport: TVDRX_Transport; out ATooLarge: Boolean): string; forward;

function ParseIPv4(const AHost: string; out AAddr: Cardinal): Boolean;
var
  Parts: TStringArray;
  i, b: Integer;
  Bytes: array[0..3] of Byte;
begin
  Result := False;
  Parts := AHost.Split(['.']);
  if Length(Parts) <> 4 then Exit;
  for i := 0 to 3 do
  begin
    if not TryStrToInt(Parts[i], b) then Exit;
    if (b < 0) or (b > 255) then Exit;
    Bytes[i] := Byte(b);
  end;
  Move(Bytes[0], AAddr, 4);
  Result := True;
end;

function ConnectTCP(const AHost: string; APort: Word): TVDRX_Transport;
var
  Sock: TSocket;
  Addr: TInetSockAddr;
  IPBytes: Cardinal;
begin
  Result := nil;
  if not ParseIPv4(AHost, IPBytes) then Exit;
  Sock := fpSocket(AF_INET, SOCK_STREAM, 0);
  if Sock < 0 then Exit;
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(APort);
  Move(IPBytes, Addr.sin_addr, SizeOf(Addr.sin_addr));
  if fpConnect(Sock, @Addr, SizeOf(Addr)) <> 0 then
  begin
    CloseSocket(Sock);
    Exit;
  end;
  Result := TVDRX_PlainTransport.Create(Sock);
end;

function ConnectRawSocket(const AHost: string; APort: Word; out ASocket: TSocket): Boolean;
var
  Addr: TInetSockAddr;
  IPBytes: Cardinal;
  Resolver: THostResolver;
  NetAddr: THostAddr;
begin
  Result := False;
  ASocket := -1;
  if not ParseIPv4(AHost, IPBytes) then
  begin
    Resolver := THostResolver.Create(nil);
    try
      if not Resolver.NameLookup(AHost) then Exit;
      NetAddr := Resolver.NetHostAddress;
      Move(NetAddr, IPBytes, SizeOf(IPBytes));
    finally
      Resolver.Free;
    end;
  end;
  ASocket := fpSocket(AF_INET, SOCK_STREAM, 0);
  if ASocket < 0 then Exit;
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(APort);
  Move(IPBytes, Addr.sin_addr, SizeOf(Addr.sin_addr));
  if fpConnect(ASocket, @Addr, SizeOf(Addr)) <> 0 then
  begin
    CloseSocket(ASocket);
    ASocket := -1;
    Exit;
  end;
  Result := True;
end;

function ConnectTCPHost(const AHost: string; APort: Word): TVDRX_Transport;
var
  Sock: TSocket;
begin
  Result := nil;
  if not ConnectRawSocket(AHost, APort, Sock) then Exit;
  Result := TVDRX_PlainTransport.Create(Sock);
end;

// Turns on TCP keepalive probes so a half-open peer (network dropped, box
// power-cycled, NAT table entry expired - anything that leaves the other
// side gone without a clean FIN) gets detected by the OS within a bounded
// time even if VDRX never tries to write to it. Uses the OS's default probe
// interval/count (usually ~2 hours idle then a handful of retries a few
// seconds apart on Linux) - good enough to eventually notice a dead peer
// without pulling in platform-specific tuning knobs FPC doesn't expose
// uniformly across Unix/Windows. Best-effort: failure here isn't fatal to
// the connection, just leaves keepalive off.
procedure SetSocketKeepAlive(ASocket: TSocket);
var
  Enable: LongInt;
begin
  Enable := 1;
  try
    fpSetsockopt(ASocket, SOL_SOCKET, SO_KEEPALIVE, @Enable, SizeOf(Enable));
  except
  end;
end;

procedure ApplyOpenSSLDLLOverrides(AConfig: TVDRX_Config);
{$IFDEF WINDOWS}
var
  SSLDll, CryptoDll: string;
{$ENDIF}
begin
  {$IFDEF WINDOWS}
  SSLDll := AConfig.GetString('tls_ssl_dll', '');
  CryptoDll := AConfig.GetString('tls_crypto_dll', '');
  if SSLDll <> '' then DLLSSLName := SSLDll;
  if CryptoDll <> '' then DLLUtilName := CryptoDll;
  {$ENDIF}
end;

{ TVDRX_PlainTransport }

constructor TVDRX_PlainTransport.Create(ASocket: TSocket);
begin
  inherited Create;
  FSocket := ASocket;
end;

function TVDRX_PlainTransport.Read(var ABuf; ALen: Integer): Integer;
begin
  Result := fpRecv(FSocket, @ABuf, ALen, 0);
end;

function TVDRX_PlainTransport.Write(const ABuf; ALen: Integer): Integer;
begin
  Result := fpSend(FSocket, @ABuf, ALen, 0);
end;

procedure TVDRX_PlainTransport.Close;
begin
  CloseSocket(FSocket);
end;

const
  TLS_HANDSHAKE_TIMEOUT_MS = 5000;

// Same socket option TVDRX_PlainTransport.SetReadTimeout sets, but usable on
// a raw accepted socket BEFORE a TVDRX_TLSTransport exists to call it on -
// TVDRX_TLSTransport.Create performs the actual SSL handshake (SSL_accept)
// synchronously inside the constructor, on the one accept-loop thread for
// this port. Without a timeout on the underlying socket first, a client that
// opens the TCP connection and then sends nothing (or an incomplete
// handshake) blocks that thread, and therefore every other TLS client
// waiting to be accepted on this port, for as long as it holds the socket
// open - a trivial single-connection DoS. AcceptLoopTLS calls this right
// before TVDRX_TLSTransport.Create and restores an unlimited timeout (via
// the transport's own SetReadTimeout(0)) once the handshake succeeds, so
// normal request handling afterwards is unaffected.
procedure SetRawSocketReadTimeout(ASocket: TSocket; ATimeoutMs: Integer);
{$IFDEF UNIX}
var
  TV: TimeVal;
begin
  TV.tv_sec := ATimeoutMs div 1000;
  TV.tv_usec := (ATimeoutMs mod 1000) * 1000;
  fpSetsockopt(ASocket, SOL_SOCKET, SO_RCVTIMEO, @TV, SizeOf(TV));
end;
{$ENDIF}
{$IFDEF WINDOWS}
var
  Timeout: DWORD;
begin
  Timeout := ATimeoutMs;
  fpSetsockopt(ASocket, SOL_SOCKET, SO_RCVTIMEO, @Timeout, SizeOf(Timeout));
end;
{$ENDIF}

procedure TVDRX_PlainTransport.SetReadTimeout(ATimeoutMs: Integer);
{$IFDEF UNIX}
var
  TV: TimeVal;
begin
  TV.tv_sec := ATimeoutMs div 1000;
  TV.tv_usec := (ATimeoutMs mod 1000) * 1000;
  fpSetsockopt(FSocket, SOL_SOCKET, SO_RCVTIMEO, @TV, SizeOf(TV));
end;
{$ENDIF}
{$IFDEF WINDOWS}
var
  Timeout: DWORD;
begin
  Timeout := ATimeoutMs;
  fpSetsockopt(FSocket, SOL_SOCKET, SO_RCVTIMEO, @Timeout, SizeOf(Timeout));
end;
{$ENDIF}

procedure TVDRX_PlainTransport.SetWriteTimeout(ATimeoutMs: Integer);
{$IFDEF UNIX}
var
  TV: TimeVal;
begin
  TV.tv_sec := ATimeoutMs div 1000;
  TV.tv_usec := (ATimeoutMs mod 1000) * 1000;
  fpSetsockopt(FSocket, SOL_SOCKET, SO_SNDTIMEO, @TV, SizeOf(TV));
end;
{$ENDIF}
{$IFDEF WINDOWS}
var
  Timeout: DWORD;
begin
  Timeout := ATimeoutMs;
  fpSetsockopt(FSocket, SOL_SOCKET, SO_SNDTIMEO, @Timeout, SizeOf(Timeout));
end;
{$ENDIF}

{ TVDRX_TLSTransport }

constructor TVDRX_TLSTransport.Create(ASocket: TSocket; ACtx: PSSL_CTX);
begin
  inherited Create;
  FSocket := ASocket;
  FSSL := SslNew(ACtx);
  SslSetFd(FSSL, FSocket);
  FOK := Assigned(FSSL) and (SslAccept(FSSL) = 1);
end;

constructor TVDRX_TLSTransport.Create(ASocket: TSocket; ACtx: PSSL_CTX; const AHostname: string);
begin
  inherited Create;
  FSocket := ASocket;
  if not Assigned(ACtx) then Exit;
  FSSL := SslNew(ACtx);
  if not Assigned(FSSL) then Exit;
  SslSetFd(FSSL, FSocket);
  if AHostname <> '' then
    SslCtrl(FSSL, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, PChar(AHostname));
  FOK := (SslConnect(FSSL) = 1);
end;

destructor TVDRX_TLSTransport.Destroy;
begin
  if Assigned(FSSL) then
    SslFree(FSSL);
  inherited Destroy;
end;

function TVDRX_TLSTransport.Read(var ABuf; ALen: Integer): Integer;
begin
  if not FOK then Exit(-1);
  Result := SslRead(FSSL, @ABuf, ALen);
end;

function TVDRX_TLSTransport.Write(const ABuf; ALen: Integer): Integer;
begin
  if not FOK then Exit(-1);
  Result := SslWrite(FSSL, @ABuf, ALen);
end;

procedure TVDRX_TLSTransport.Close;
begin
  if Assigned(FSSL) then
    SslShutdown(FSSL);
  FOK := False;
  CloseSocket(FSocket);
end;

procedure TVDRX_TLSTransport.SetReadTimeout(ATimeoutMs: Integer);
var
  PlainTemp: TVDRX_PlainTransport;
begin
  PlainTemp := TVDRX_PlainTransport.Create(FSocket);
  try
    PlainTemp.SetReadTimeout(ATimeoutMs);
  finally
    PlainTemp.Free;
  end;
end;

// SSL_write ultimately calls send() on this same fd, so SO_SNDTIMEO still
// bounds the underlying syscall even though OpenSSL sits in between. Not
// airtight - a sufficiently large OpenSSL-side write buffer could in theory
// absorb small writes without ever calling send() - but for VDRX's line-at-a-
// time payloads this is a solid practical bound, and vastly better than the
// previous "never times out" behaviour.
procedure TVDRX_TLSTransport.SetWriteTimeout(ATimeoutMs: Integer);
var
  PlainTemp: TVDRX_PlainTransport;
begin
  PlainTemp := TVDRX_PlainTransport.Create(FSocket);
  try
    PlainTemp.SetWriteTimeout(ATimeoutMs);
  finally
    PlainTemp.Free;
  end;
end;

{ TVDRX_TLSContext }

constructor TVDRX_TLSContext.Create(const ACertFile, AKeyFile: string);
begin
  inherited Create;
  FCtx := SslCtxNew(SslTLSMethod);
  FOK := Assigned(FCtx)
    and (SslCtxUseCertificateFile(FCtx, ACertFile, SSL_FILETYPE_PEM) = 1)
    and (SslCtxUsePrivateKeyFile(FCtx, AKeyFile, SSL_FILETYPE_PEM) = 1);
end;

destructor TVDRX_TLSContext.Destroy;
begin
  if Assigned(FCtx) then
    SslCtxFree(FCtx);
  inherited Destroy;
end;

{ TVDRX_TLSClientContext }

constructor TVDRX_TLSClientContext.Create(const ACAFile: string; AVerifyPeer: Boolean);
begin
  inherited Create;
  FCtx := SslCtxNew(SslTLSMethod);
  FOK := Assigned(FCtx);
  if not FOK then Exit;
  if AVerifyPeer then
  begin
    SslCtxSetVerify(FCtx, SSL_VERIFY_PEER, nil);
    if ACAFile <> '' then
      FOK := (SslCtxLoadVerifyLocations(FCtx, ACAFile, '') = 1)
    {$IFDEF UNIX}
    else if FileExists('/etc/ssl/certs/ca-certificates.crt') then
      FOK := (SslCtxLoadVerifyLocations(FCtx, '/etc/ssl/certs/ca-certificates.crt', '') = 1)
    {$ENDIF}
    ;
  end
  else
    SslCtxSetVerify(FCtx, SSL_VERIFY_NONE, nil);
end;

destructor TVDRX_TLSClientContext.Destroy;
begin
  if Assigned(FCtx) then
    SslCtxFree(FCtx);
  inherited Destroy;
end;

constructor TVDRX_ListenerConnThread.Create(AOwner: TVDRX_SocketListenerExecutive; ATransport: TVDRX_Transport);
begin
  inherited Create(True);
  FOwner := AOwner;
  FTransport := ATransport;
  FreeOnTerminate := False;
end;

procedure TVDRX_ListenerConnThread.Execute;
begin
  FOwner.RegisterConnection(Self);
  try
    try
      FOwner.HandleConnection(FTransport);
    except
    end;
  finally
    FOwner.UnregisterConnection(Self);
    FreeOnTerminate := True;
  end;
end;

{ TVDRX_SocketListenerExecutive }

constructor TVDRX_SocketListenerExecutive.Create(ABus: TVDRX_MessageQueue);
begin
  inherited Create(ABus);
  // Was 16, fixed, with no way to raise it. A burst of connections arriving
  // faster than the accept loop drains them - even an ordinary browser
  // opening several at once, since this server doesn't keep-alive - could
  // start dropping SYNs well before anything resembling an attack. 128 is a
  // conservative, widely-used default (same ballpark as nginx's); "backlog"
  // in http_sites/executives.ws (see vdrx.lpr) can still override it per listener.
  FBacklog := 128;
  FGracefulTimeoutMs := 5000;
  FBindAddress := '127.0.0.1';
  FMaxConnections := 256;
  FCriticalSection := TCriticalSection.Create;
  FActiveConnections := TList.Create;
end;

destructor TVDRX_SocketListenerExecutive.Destroy;
begin
  FActiveConnections.Free;
  FCriticalSection.Free;
  FTLSContext.Free;
  inherited Destroy;
end;

procedure TVDRX_SocketListenerExecutive.RegisterConnection(AThread: TVDRX_ListenerConnThread);
begin
  FCriticalSection.Acquire;
  try
    if not FStopping then
      FActiveConnections.Add(AThread);
  finally
    FCriticalSection.Release;
  end;
end;

procedure TVDRX_SocketListenerExecutive.UnregisterConnection(AThread: TVDRX_ListenerConnThread);
begin
  FCriticalSection.Acquire;
  try
    FActiveConnections.Remove(AThread);
  finally
    FCriticalSection.Release;
  end;
end;

procedure TVDRX_SocketListenerExecutive.ConfigureTLS(ATLSPort: Word; const ACertFile, AKeyFile: string);
begin
  FTLSPort := ATLSPort;
  FTLSCertFile := ACertFile;
  FTLSKeyFile := AKeyFile;
end;

function TVDRX_SocketListenerExecutive.BindListenSocket(APort: Word): TSocket;
var
  Addr: TInetSockAddr;
  OptVal: LongInt;
  BindStr: string;
  NetAddr: in_addr;
begin
  // StrToNetAddr answers 0.0.0.0 for text it cannot parse, which would turn a
  // typo into "listen on every interface". So 0.0.0.0 has to be asked for
  // by name and anything else that parses to 0 is refused.
  BindStr := Trim(FBindAddress);
  if SameText(BindStr, 'localhost') then BindStr := '127.0.0.1';
  NetAddr := StrToNetAddr(BindStr);
  if (NetAddr.s_addr = 0) and (BindStr <> '0.0.0.0') then
  begin
    Bus.Publish('log.error', ID + ': invalid bind address "' + FBindAddress +
      '" (use an IPv4 address, "localhost" or "0.0.0.0") - not listening on port ' + IntToStr(APort), ID);
    Exit(-1);
  end;
  Result := fpSocket(AF_INET, SOCK_STREAM, 0);
  OptVal := 1;
  fpSetSockOpt(Result, SOL_SOCKET, SO_REUSEADDR, @OptVal, SizeOf(OptVal));
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(APort);
  Addr.sin_addr := NetAddr;
  if fpBind(Result, @Addr, SizeOf(Addr)) <> 0 then
  begin
    Bus.Publish('log.error', ID + ': fpBind failed on ' + BindStr + ':' + IntToStr(APort) +
      ' (errno ' + IntToStr(socketerror) + ') - port likely already in use', ID);
    CloseSocket(Result);
    Exit(-1);
  end;
  if fpListen(Result, FBacklog) <> 0 then
  begin
    Bus.Publish('log.error', ID + ': fpListen failed on port ' + IntToStr(APort) +
      ' (errno ' + IntToStr(socketerror) + ')', ID);
    CloseSocket(Result);
    Exit(-1);
  end;
end;

function TVDRX_SocketListenerExecutive.ConnectionLimitReached: Boolean;
begin
  if FMaxConnections <= 0 then Exit(False);
  FCriticalSection.Acquire;
  try
    Result := FActiveConnections.Count >= FMaxConnections;
  finally
    FCriticalSection.Release;
  end;
end;

// Logs at most once every 10 s (with a count) so a flood of refused
// connections cannot also flood the log.
procedure TVDRX_SocketListenerExecutive.NoteRejected;
var
  Now: QWord;
begin
  Inc(FRejectedSinceLog);
  Now := GetTickCount64;
  if (FLastRejectLog = 0) or (Now - FLastRejectLog >= 10000) then
  begin
    Bus.Publish('log.warn', ID + ': connection limit (' + IntToStr(FMaxConnections) +
      ') reached - closed ' + IntToStr(FRejectedSinceLog) + ' new connection(s)', ID);
    FLastRejectLog := Now;
    FRejectedSinceLog := 0;
  end;
end;

procedure TVDRX_SocketListenerExecutive.AcceptLoopPlain;
var
  ClientAddr: TInetSockAddr;
  AddrLen: TSockLen;
  ClientSock: TSocket;
  ConnThread: TVDRX_ListenerConnThread;
  PlainT: TVDRX_PlainTransport;
begin
  FPlainSocket := BindListenSocket(FPort);
  if FPlainSocket = -1 then
  begin
    FPlainSocket := 0;
    Exit;
  end;
  while not FStopping do
  begin
    AddrLen := SizeOf(ClientAddr);
    ClientSock := fpAccept(FPlainSocket, @ClientAddr, @AddrLen);
    if ClientSock = -1 then
    begin
      if not FStopping then
        Sleep(10);
      Continue;
    end;

    if ConnectionLimitReached then
    begin
      CloseSocket(ClientSock);
      NoteRejected;
      Continue;
    end;

    FCriticalSection.Acquire;
    try
      if FStopping then
      begin
        CloseSocket(ClientSock);
        Break;
      end;
      PlainT := TVDRX_PlainTransport.Create(ClientSock);
      PlainT.PeerAddr := NetAddrToStr(ClientAddr.sin_addr);
      PlainT.PeerPort := ntohs(ClientAddr.sin_port);
      ConnThread := TVDRX_ListenerConnThread.Create(Self, PlainT);
    finally
      FCriticalSection.Release;
    end;
    ConnThread.Start;
  end;
  if FPlainSocket <> 0 then
  begin
    CloseSocket(FPlainSocket);
    FPlainSocket := 0;
  end;
end;

procedure TVDRX_SocketListenerExecutive.AcceptLoopTLS;
var
  ClientAddr: TInetSockAddr;
  AddrLen: TSockLen;
  ClientSock: TSocket;
  Transport: TVDRX_TLSTransport;
  ConnThread: TVDRX_ListenerConnThread;
begin
  FTLSSocket := BindListenSocket(FTLSPort);
  if FTLSSocket = -1 then
  begin
    FTLSSocket := 0;
    Exit;
  end;
  while not FStopping do
  begin
    AddrLen := SizeOf(ClientAddr);
    ClientSock := fpAccept(FTLSSocket, @ClientAddr, @AddrLen);
    if ClientSock = -1 then
    begin
      if not FStopping then
        Sleep(10);
      Continue;
    end;

    if ConnectionLimitReached then
    begin
      CloseSocket(ClientSock);
      NoteRejected;
      Continue;
    end;

    // Bound the handshake itself (see SetRawSocketReadTimeout's comment);
    // restored to unlimited below once it has actually completed.
    SetRawSocketReadTimeout(ClientSock, TLS_HANDSHAKE_TIMEOUT_MS);
    Transport := TVDRX_TLSTransport.Create(ClientSock, FTLSContext.Ctx);
    if not Transport.Handshook then
    begin
      Transport.Free;
      Continue;
    end;
    Transport.SetReadTimeout(0);

    Transport.PeerAddr := NetAddrToStr(ClientAddr.sin_addr);
    Transport.PeerPort := ntohs(ClientAddr.sin_port);
    Transport.Secure := True;

    FCriticalSection.Acquire;
    try
      if FStopping then
      begin
        Transport.Free;
        Break;
      end;
      ConnThread := TVDRX_ListenerConnThread.Create(Self, Transport);
    finally
      FCriticalSection.Release;
    end;
    ConnThread.Start;
  end;
  if FTLSSocket <> 0 then
  begin
    CloseSocket(FTLSSocket);
    FTLSSocket := 0;
  end;
end;

function TVDRX_SocketListenerExecutive.TLSActive: Boolean;
begin
  Result := Assigned(FTLSThread);
end;

procedure TVDRX_SocketListenerExecutive.Initialize;
begin
  FStopping := False;
  if FPort <> 0 then
  begin
    FPlainThread := TVDRX_WorkerThread.Create(@AcceptLoopPlain);
    FPlainThread.FreeOnTerminate := False;
    FPlainThread.Start;
  end;
  if FTLSPort <> 0 then
  begin
    FTLSContext := TVDRX_TLSContext.Create(FTLSCertFile, FTLSKeyFile);
    if not FTLSContext.OK then
    begin
      FTLSContext.Free;
      FTLSContext := nil;
    end
    else
    begin
      FTLSThread := TVDRX_WorkerThread.Create(@AcceptLoopTLS);
      FTLSThread.FreeOnTerminate := False;
      FTLSThread.Start;
    end;
  end;
end;

function TVDRX_SocketListenerExecutive.WaitConnGone(AThread: TVDRX_ListenerConnThread; ATimeoutMs: Integer): Boolean;
var
  Waited: Integer;

  function StillActive: Boolean;
  begin
    FCriticalSection.Acquire;
    try
      Result := FActiveConnections.IndexOf(AThread) >= 0;
    finally
      FCriticalSection.Release;
    end;
  end;

begin
  Waited := 0;
  while StillActive and (Waited < ATimeoutMs) do
  begin
    Sleep(50);
    Inc(Waited, 50);
  end;
  Result := not StillActive;
end;

procedure TVDRX_SocketListenerExecutive.Shutdown;
var
  I: Integer;
  ConnThread: TVDRX_ListenerConnThread;
  CopyList: TList;
begin
  FStopping := True;

  if FPlainSocket <> 0 then
  begin
    CloseSocket(FPlainSocket);
    FPlainSocket := 0;
  end;
  if FTLSSocket <> 0 then
  begin
    CloseSocket(FTLSSocket);
    FTLSSocket := 0;
  end;

  if Assigned(FPlainThread) then
  begin
    if WaitThreadOrTimeout(FPlainThread, FGracefulTimeoutMs) then
      FPlainThread.Free
    else
      Bus.Publish('log.warn', ID + ': plain accept thread did not exit in time - abandoning it', ID);
    FPlainThread := nil;
  end;
  if Assigned(FTLSThread) then
  begin
    if WaitThreadOrTimeout(FTLSThread, FGracefulTimeoutMs) then
      FTLSThread.Free
    else
      Bus.Publish('log.warn', ID + ': TLS accept thread did not exit in time - abandoning it', ID);
    FTLSThread := nil;
  end;

  FCriticalSection.Acquire;
  try
    CopyList := TList.Create;
    CopyList.Assign(FActiveConnections);
  finally
    FCriticalSection.Release;
  end;

  try
    for I := 0 to CopyList.Count - 1 do
    begin
      ConnThread := TVDRX_ListenerConnThread(CopyList[I]);
      if not WaitConnGone(ConnThread, FGracefulTimeoutMs) then
      begin
        Bus.Publish('log.warn', ID + ': connection thread did not exit in time - forcing its socket closed', ID);
        try ConnThread.Transport.Close; except end;
        if not WaitConnGone(ConnThread, FGracefulTimeoutMs) then
          Bus.Publish('log.warn', ID + ': connection thread still stuck after forcing its socket closed - abandoning it', ID);
      end;
    end;
  finally
    CopyList.Free;
  end;

  FTLSContext.Free;
  FTLSContext := nil;
end;

function PlainResponse(const AStatus, AContentType, ABody: string; ACustomHeaders: TStringList = nil): string;
var
  i: Integer;
  ExtraHeaders: string;
begin
  ExtraHeaders := '';
  if Assigned(ACustomHeaders) then
  begin
    for i := 0 to ACustomHeaders.Count - 1 do
    begin
      if ACustomHeaders.Names[i] <> '' then
        ExtraHeaders := ExtraHeaders + ACustomHeaders.Names[i] + ': ' + ACustomHeaders.ValueFromIndex[i] + #13#10
      else if Trim(ACustomHeaders[i]) <> '' then
        ExtraHeaders := ExtraHeaders + Trim(ACustomHeaders[i]) + #13#10;
    end;
  end;

  Result := 'HTTP/1.1 ' + AStatus + #13#10 +
            'Content-Type: ' + AContentType + #13#10 +
            'Content-Length: ' + IntToStr(Length(ABody)) + #13#10 +
            ExtraHeaders + #13#10 + ABody;
end;

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

function ExtractQueryString(const ARequest: string): string;
var
  LineEnd, Sp1, Sp2, QPos: Integer;
  Line, RawPath: string;
begin
  Result := '';
  LineEnd := Pos(#13#10, ARequest);
  if LineEnd = 0 then LineEnd := Length(ARequest) + 1;
  Line := Copy(ARequest, 1, LineEnd - 1);
  Sp1 := Pos(' ', Line);
  if Sp1 = 0 then Exit;
  Sp2 := PosEx(' ', Line, Sp1 + 1);
  if Sp2 = 0 then Sp2 := Length(Line) + 1;
  RawPath := Copy(Line, Sp1 + 1, Sp2 - Sp1 - 1);
  QPos := Pos('?', RawPath);
  if QPos > 0 then
    Result := Copy(RawPath, QPos + 1, MaxInt);
end;

function ExtractHeaderValue(const AHeaderBlock, AName: string): string;
var
  SL: TStringList;
  i, Colon: Integer;
begin
  Result := '';
  SL := TStringList.Create;
  try
    SL.Text := AHeaderBlock;
    for i := 1 to SL.Count - 1 do
    begin
      Colon := Pos(':', SL[i]);
      if (Colon > 0) and SameText(Trim(Copy(SL[i], 1, Colon - 1)), AName) then
        Exit(Trim(Copy(SL[i], Colon + 1, MaxInt)));
    end;
  finally
    SL.Free;
  end;
end;

function ReadFullRequest(ATransport: TVDRX_Transport; out ATooLarge: Boolean): string;
var
  Buf: array[0..4095] of Byte;
  Received, HeaderEnd, ContentLength, BodySoFar, ToRead, TotalLen: Integer;
  HeaderBlock, CLStr: string;
begin
  Result := '';
  ATooLarge := False;
  HeaderEnd := 0;
  while (HeaderEnd = 0) and (Length(Result) < MAX_HEADER_SIZE) do
  begin
    Received := ATransport.Read(Buf[0], SizeOf(Buf));
    if Received <= 0 then Exit(Result);
    SetLength(Result, Length(Result) + Received);
    Move(Buf[0], Result[Length(Result) - Received + 1], Received);
    HeaderEnd := Pos(#13#10#13#10, Result);
  end;
  if HeaderEnd = 0 then Exit;

  HeaderBlock := Copy(Result, 1, HeaderEnd - 1);
  CLStr := ExtractHeaderValue(HeaderBlock, 'Content-Length');
  ContentLength := 0;
  if CLStr <> '' then
    ContentLength := StrToIntDef(Trim(CLStr), 0);
  if ContentLength > MAX_BODY_SIZE then
  begin
    // Previously this just clamped ContentLength and kept reading: the
    // client still sends the bytes beyond the clamp, which were never
    // consumed, so the next request parsed off this connection (if the
    // caller ever reused it) would desync on that leftover body data.
    // Every connection here is answered once and closed (see
    // TVDRX_HTTPConnection.Run), so today that's latent rather than
    // exploitable - but it is a real request-smuggling trap if keep-alive
    // is ever added, and a declared-too-large body deserves an honest 413
    // rather than a silently truncated 200 anyway. The caller closes the
    // connection either way.
    ATooLarge := True;
    Exit;
  end;

  BodySoFar := Length(Result) - (HeaderEnd + 3);
  if ContentLength > BodySoFar then
  begin
    TotalLen := Length(Result) + (ContentLength - BodySoFar);
    SetLength(Result, TotalLen);
  end;
  while BodySoFar < ContentLength do
  begin
    ToRead := ContentLength - BodySoFar;
    if ToRead > SizeOf(Buf) then ToRead := SizeOf(Buf);
    Received := ATransport.Read(Buf[0], ToRead);
    if Received <= 0 then
    begin
      SetLength(Result, HeaderEnd + 3 + BodySoFar);
      Break;
    end;
    Move(Buf[0], Result[HeaderEnd + 3 + BodySoFar + 1], Received);
    Inc(BodySoFar, Received);
  end;
end;

// Maps a URL path (e.g. '/app/index.php') onto a directory, segment by segment.
// Returns False for anything that could escape or hide something: "..", NUL,
// backslashes, ':' (NTFS alternate data streams), dot-files (.git, .env ...;
// ".well-known" is allowed) and segments ending in '.' or ' ' (Windows ignores
// those, so "x.php." would serve a script's source as plain text).
function SplitURLPath(const ARawPath: string; ASegs: TStrings): Boolean;
var
  Decoded, Seg: string;
  p, q: Integer;
begin
  Result := False;
  ASegs.Clear;
  Decoded := URLDecode(ARawPath, False);
  if (Pos(#0, Decoded) > 0) or (Pos('\', Decoded) > 0) or (Pos(':', Decoded) > 0) then Exit;
  p := 1;
  while p <= Length(Decoded) + 1 do
  begin
    q := PosEx('/', Decoded, p);
    if q = 0 then q := Length(Decoded) + 1;
    Seg := Copy(Decoded, p, q - p);
    p := q + 1;
    if (Seg = '') or (Seg = '.') then Continue;
    if Seg = '..' then Exit;
    if (Seg[1] = '.') and (Seg <> '.well-known') then Exit;
    if Seg[Length(Seg)] in ['.', ' '] then Exit;
    ASegs.Add(Seg);
  end;
  Result := True;
end;

function GuessContentType(const APath: string): string;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(APath));
  if Ext = '.png' then Result := 'image/png'
  else if (Ext = '.jpg') or (Ext = '.jpeg') then Result := 'image/jpeg'
  else if Ext = '.webp' then Result := 'image/webp'
  else if Ext = '.gif' then Result := 'image/gif'
  else if Ext = '.ico' then Result := 'image/x-icon'
  else if Ext = '.js' then Result := 'application/javascript'
  else if Ext = '.css' then Result := 'text/css'
  else if Ext = '.html' then Result := 'text/html'
  else if Ext = '.json' then Result := 'application/json'
  else if Ext = '.svg' then Result := 'image/svg+xml'
  else if Ext = '.wasm' then Result := 'application/wasm'
  else if (Ext = '.txt') or (Ext = '.log') or (Ext = '.md') then Result := 'text/plain; charset=utf-8'
  else if Ext = '.xml' then Result := 'application/xml'
  else if Ext = '.pdf' then Result := 'application/pdf'
  else if Ext = '.woff2' then Result := 'font/woff2'
  else if Ext = '.woff' then Result := 'font/woff'
  else if Ext = '.map' then Result := 'application/json'
  else if (Ext = '.mp4') or (Ext = '.m4v') then Result := 'video/mp4'
  else if Ext = '.csv' then Result := 'text/csv'
  else Result := 'application/octet-stream';
end;

function ServeStaticFile(const APath, AStaticDir: string; ABus: TVDRX_MessageQueue;
  const ASourceID: string; ACustomHeaders: TStringList = nil): string;
var
  FilePath, Body: string;
  FS: TFileStream;
  Segs: TStringList;
  i: Integer;
  Ok: Boolean;
  Redir: TStringList;
begin
  ABus.Publish('log.info', 'http: static path: "' + APath + '"', ASourceID);
  Ok := (AStaticDir <> '') and (APath <> '') and (APath[1] = '/');
  FilePath := '';
  if Ok then
  begin
    Segs := TStringList.Create;
    try
      Ok := SplitURLPath(APath, Segs);   // percent-decodes; refuses "..", dot-files, ':' etc.
      if Ok then
      begin
        FilePath := ExcludeTrailingPathDelimiter(ExpandFileName(AStaticDir));
        for i := 0 to Segs.Count - 1 do FilePath := FilePath + PathDelim + Segs[i];
      end;
    finally
      Segs.Free;
    end;
  end;
  if not Ok then
  begin
    ABus.Publish('log.warn', 'http: rejected static path "' + APath + '"', ASourceID);
    Exit(PlainResponse('404 Not Found', 'text/plain', 'Not found', ACustomHeaders));
  end;
  if DirectoryExists(FilePath) then
  begin
    // "/docs" -> 301 to "/docs/" (so relative links in the page resolve); "/docs/" -> its index.html
    if APath[Length(APath)] <> '/' then
    begin
      Redir := TStringList.Create;
      try
        Redir.Add('Location=' + APath + '/');
        if Assigned(ACustomHeaders) then Redir.AddStrings(ACustomHeaders);
        Exit(PlainResponse('301 Moved Permanently', 'text/plain', 'Moved', Redir));
      finally
        Redir.Free;
      end;
    end;
    FilePath := IncludeTrailingPathDelimiter(FilePath) + 'index.html';
  end;
  if (not FileExists(FilePath)) or DirectoryExists(FilePath) then
  begin
    ABus.Publish('log.warn', 'http: static file not found: ' + FilePath, ASourceID);
    Exit(PlainResponse('404 Not Found', 'text/plain', 'Not found', ACustomHeaders));
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
  Result := PlainResponse('200 OK', GuessContentType(FilePath), Body, ACustomHeaders);
end;

function MatchProxyRoute(const APath: string; const ARoutes: TVDRX_ProxyRoutes; out AMatch: TVDRX_ProxyRoute): Boolean;
var
  i, bestLen: Integer;
begin
  Result := False;
  bestLen := -1;
  for i := 0 to High(ARoutes) do
    if (Copy(APath, 1, Length(ARoutes[i].Prefix)) = ARoutes[i].Prefix) and (Length(ARoutes[i].Prefix) > bestLen) then
    begin
      AMatch := ARoutes[i];
      bestLen := Length(ARoutes[i].Prefix);
      Result := True;
    end;
end;

function ForceConnectionClose(const ARequest: string): string;
var
  HeaderEnd, i: Integer;
  OutLines: TStringList;
begin
  HeaderEnd := Pos(#13#10#13#10, ARequest);
  if HeaderEnd = 0 then Exit(ARequest);
  OutLines := TStringList.Create;
  try
    OutLines.Text := Copy(ARequest, 1, HeaderEnd - 1);
    for i := OutLines.Count - 1 downto 0 do
      if Pos('connection:', LowerCase(OutLines[i])) = 1 then
        OutLines.Delete(i);
    OutLines.Add('Connection: close');
    Result := OutLines.Text + #13#10 + Copy(ARequest, HeaderEnd + 4, MaxInt);
  finally
    OutLines.Free;
  end;
end;

function ProxyRequest(const ARequest: string; const ARoute: TVDRX_ProxyRoute;
  ABus: TVDRX_MessageQueue; const ASourceID: string): string;
const
  MAX_CONNECT_ATTEMPTS = 5;
  RETRY_DELAY_MS = 150;
var
  Transport: TVDRX_Transport;
  Buf: array[0..8191] of Byte;
  Received, Attempt: Integer;
  Outgoing: string;
begin
  Transport := nil;
  for Attempt := 1 to MAX_CONNECT_ATTEMPTS do
  begin
    Transport := ConnectTCP(ARoute.Host, ARoute.Port);
    if Assigned(Transport) then Break;
    if Attempt < MAX_CONNECT_ATTEMPTS then
      Sleep(RETRY_DELAY_MS);
  end;
  if not Assigned(Transport) then
  begin
    ABus.Publish('log.error', Format('http proxy: could not connect to %s:%d after %d attempt(s) - is the bridge process up? (check its own log lines above, and "kill <bridge-id>" to bounce it if it looks wedged)', [ARoute.Host, ARoute.Port, MAX_CONNECT_ATTEMPTS]), ASourceID);
    Exit(PlainResponse('502 Bad Gateway', 'text/plain', 'Upstream unavailable'));
  end;

  try
    Outgoing := ForceConnectionClose(ARequest);
    Transport.Write(Outgoing[1], Length(Outgoing));
    Result := '';
    repeat
      Received := Transport.Read(Buf[0], SizeOf(Buf));
      if Received > 0 then
      begin
        SetLength(Result, Length(Result) + Received);
        Move(Buf[0], Result[Length(Result) - Received + 1], Received);
      end;
    until Received <= 0;
  finally
    Transport.Close;
    Transport.Free;
  end;

  if Result = '' then
  begin
    ABus.Publish('log.warn', Format('http proxy: empty response from %s:%d', [ARoute.Host, ARoute.Port]), ASourceID);
    Exit(PlainResponse('502 Bad Gateway', 'text/plain', 'Empty response from upstream'));
  end;
  ABus.Publish('log.info', Format('http proxy: %s:%d -> %d bytes', [ARoute.Host, ARoute.Port, Length(Result)]), ASourceID);
end;

function MatchBusRoute(const APath: string; const ARoutes: TVDRX_BusRoutes; out AMatch: TVDRX_BusRoute): Boolean;
var
  i, bestLen: Integer;
begin
  Result := False;
  bestLen := -1;
  for i := 0 to High(ARoutes) do
    if (Copy(APath, 1, Length(ARoutes[i].Prefix)) = ARoutes[i].Prefix) and (Length(ARoutes[i].Prefix) > bestLen) then
    begin
      AMatch := ARoutes[i];
      bestLen := Length(ARoutes[i].Prefix);
      Result := True;
    end;
end;

{ ---- request-line helpers + rewrites --------------------------------------- }

// "HTTP/1.1" from "GET /x HTTP/1.1"
function RequestVersion(const ARequest: string): string;
var
  LineEnd, Sp1, Sp2: Integer;
  Line: string;
begin
  Result := 'HTTP/1.1';
  LineEnd := Pos(#13#10, ARequest);
  if LineEnd = 0 then Exit;
  Line := Copy(ARequest, 1, LineEnd - 1);
  Sp1 := Pos(' ', Line);
  if Sp1 = 0 then Exit;
  Sp2 := PosEx(' ', Line, Sp1 + 1);
  if Sp2 > 0 then Result := Trim(Copy(Line, Sp2 + 1, MaxInt));
end;

// "/path?query" exactly as the client sent it
function RequestTarget(const ARequest: string): string;
var
  LineEnd, Sp1, Sp2: Integer;
  Line: string;
begin
  Result := '';
  LineEnd := Pos(#13#10, ARequest);
  if LineEnd = 0 then LineEnd := Length(ARequest) + 1;
  Line := Copy(ARequest, 1, LineEnd - 1);
  Sp1 := Pos(' ', Line);
  if Sp1 = 0 then Exit;
  Sp2 := PosEx(' ', Line, Sp1 + 1);
  if Sp2 = 0 then Sp2 := Length(Line) + 1;
  Result := Copy(Line, Sp1 + 1, Sp2 - Sp1 - 1);
end;

function ReplaceRequestTarget(const ARequest, ANewTarget: string): string;
var
  LineEnd, Sp1: Integer;
  Line: string;
begin
  LineEnd := Pos(#13#10, ARequest);
  if LineEnd = 0 then Exit(ARequest);
  Line := Copy(ARequest, 1, LineEnd - 1);
  Sp1 := Pos(' ', Line);
  if Sp1 = 0 then Exit(ARequest);
  Result := Copy(Line, 1, Sp1) + ANewTarget + ' ' + RequestVersion(ARequest) + Copy(ARequest, LineEnd, MaxInt);
end;

// Runs the rewrite rules, in order, against the request path. A matching rule
// replaces the whole target with its "to" (regex groups as $1, $2, ... - see
// TRegExpr.Substitute); a "?query" in "to" replaces the query string, otherwise
// the client's own query is kept. Returns True for a redirect rule (ALocation +
// ARedirectStatus set); otherwise ANewRequest is the request to route (the
// original one if nothing matched).
function ApplyRewrites(const ARequest: string; const ARules: TVDRX_RewriteRules;
  out ANewRequest, ALocation: string; out ARedirectStatus: Integer): Boolean;
var
  Method, Path, Query, NewTarget, Flag: string;
  i, q: Integer;
  Re: TRegExpr;
  Matched, Changed: Boolean;
begin
  Result := False;
  ANewRequest := ARequest;
  ALocation := '';
  ARedirectStatus := 0;
  if Length(ARules) = 0 then Exit;
  ParseRequestLine(ARequest, Method, Path);
  Query := ExtractQueryString(ARequest);
  Changed := False;
  Re := TRegExpr.Create;
  try
    for i := 0 to High(ARules) do
    begin
      Matched := False;
      NewTarget := '';
      try
        Re.Expression := ARules[i].Pattern;
        if Re.Exec(Path) then
        begin
          NewTarget := Re.Substitute(ARules[i].Target);
          Matched := True;
        end;
      except
        // a bad pattern is reported once at startup (vdrx.lpr); skip it here
      end;
      if not Matched then Continue;
      Changed := True;
      q := Pos('?', NewTarget);
      if q > 0 then
      begin
        Path := Copy(NewTarget, 1, q - 1);
        Query := Copy(NewTarget, q + 1, MaxInt);
      end
      else
        Path := NewTarget;
      Flag := LowerCase(ARules[i].Flag);
      if (Flag = 'redirect') or (Flag = 'permanent') then
      begin
        ALocation := Path + IfThen(Query <> '', '?' + Query, '');
        if Flag = 'permanent' then ARedirectStatus := 301 else ARedirectStatus := 302;
        Exit(True);
      end;
      if Flag <> 'continue' then Break;   // 'last' (default): first match wins
    end;
  finally
    Re.Free;
  end;
  if Changed then
    ANewRequest := ReplaceRequestTarget(ARequest, Path + IfThen(Query <> '', '?' + Query, ''));
end;

{ ---- mapping a URL onto a script under doc_root ----------------------------- }

type
  TCGIResolve = (crNotFound, crScript, crStatic, crRedirectSlash, crForbidden);

function IsScriptExt(const ARoute: TVDRX_BusRoute; const AFileName: string): Boolean;
begin
  if ARoute.Extensions = '' then Exit(True);
  Result := Pos(',' + LowerCase(ExtractFileExt(AFileName)) + ',', ARoute.Extensions) > 0;
end;

// "cgi" routes: decides what a request path means under the route's doc_root.
//   crScript         AScriptFile / AScriptName / APathInfo are set (CGI meta-variables)
//   crStatic         AStaticPath is the path (relative to the prefix) of a plain file
//   crRedirectSlash  a directory requested without its trailing '/'
//   crForbidden      the path tried something SplitURLPath refuses
//   crNotFound
// Order, like a conventional web server: existing script (anything after it is
// PATH_INFO) -> existing plain file -> directory index file -> fallback script
// (front controller, e.g. "/index.php") -> 404.
function ResolveCGITarget(const APath: string; const ARoute: TVDRX_BusRoute;
  out AScriptName, AScriptFile, APathInfo, AStaticPath: string): TCGIResolve;
var
  Base, Rel, Cur, Next, Cand, Idx: string;
  Segs, Idxs, FSegs: TStringList;
  i: Integer;
  Missing: Boolean;

  function JoinSegs(AFrom, ATo: Integer): string;
  var
    k: Integer;
  begin
    Result := '';
    for k := AFrom to ATo do Result := Result + '/' + Segs[k];
  end;

begin
  Result := crNotFound;
  AScriptName := '';
  AScriptFile := '';
  APathInfo := '';
  AStaticPath := '';
  Base := ARoute.Prefix;
  while (Base <> '') and (Base[Length(Base)] = '/') do SetLength(Base, Length(Base) - 1);
  Rel := Copy(APath, Length(Base) + 1, MaxInt);
  if (Rel <> '') and (Rel[1] <> '/') then Exit;   // prefix "/app" also matched "/apple"
  if Rel = '' then Rel := '/';

  Segs := TStringList.Create;
  Idxs := TStringList.Create;
  FSegs := TStringList.Create;
  try
    if not SplitURLPath(Rel, Segs) then Exit(crForbidden);
    Cur := ExcludeTrailingPathDelimiter(ExpandFileName(ARoute.DocRoot));
    Missing := False;
    for i := 0 to Segs.Count - 1 do
    begin
      Next := Cur + PathDelim + Segs[i];
      if DirectoryExists(Next) then
      begin
        Cur := Next;
        Continue;
      end;
      if FileExists(Next) then
      begin
        if IsScriptExt(ARoute, Next) then
        begin
          AScriptFile := Next;
          AScriptName := Base + JoinSegs(0, i);
          if i < Segs.Count - 1 then APathInfo := JoinSegs(i + 1, Segs.Count - 1);
          Exit(crScript);
        end;
        if ARoute.Static and (i = Segs.Count - 1) then
        begin
          AStaticPath := Rel;
          Exit(crStatic);
        end;
      end;
      Missing := True;
      Break;
    end;

    if not Missing then
    begin
      // the whole path is a directory (or the root)
      if (Rel <> '/') and (Rel[Length(Rel)] <> '/') then Exit(crRedirectSlash);
      Idxs.CommaText := ARoute.IndexFiles;
      for i := 0 to Idxs.Count - 1 do
      begin
        Idx := Trim(Idxs[i]);
        if (Idx = '') or (Pos('/', Idx) > 0) or (Pos('\', Idx) > 0) or (Pos('..', Idx) > 0) then Continue;
        Cand := Cur + PathDelim + Idx;
        if not FileExists(Cand) then Continue;
        if IsScriptExt(ARoute, Cand) then
        begin
          AScriptFile := Cand;
          AScriptName := Base + JoinSegs(0, Segs.Count - 1) + '/' + Idx;
          Exit(crScript);
        end;
        if ARoute.Static then
        begin
          AStaticPath := Rel + Idx;
          Exit(crStatic);
        end;
      end;
    end;

    // front controller: everything that matched nothing goes to one script
    if ARoute.Fallback <> '' then
    begin
      Cand := ExcludeTrailingPathDelimiter(ExpandFileName(ARoute.DocRoot));
      if SplitURLPath(ARoute.Fallback, FSegs) and (FSegs.Count > 0) then
      begin
        Next := '';
        for i := 0 to FSegs.Count - 1 do
        begin
          Cand := Cand + PathDelim + FSegs[i];
          Next := Next + '/' + FSegs[i];
        end;
        if FileExists(Cand) then
        begin
          AScriptFile := Cand;
          AScriptName := Base + Next;
          APathInfo := '';
          Exit(crScript);
        end;
      end;
    end;
  finally
    FSegs.Free;
    Idxs.Free;
    Segs.Free;
  end;
end;

function HTTPStatusText(ACode: Integer): string;
begin
  case ACode of
    200: Result := 'OK';
    201: Result := 'Created';
    204: Result := 'No Content';
    301: Result := 'Moved Permanently';
    302: Result := 'Found';
    303: Result := 'See Other';
    304: Result := 'Not Modified';
    307: Result := 'Temporary Redirect';
    308: Result := 'Permanent Redirect';
    400: Result := 'Bad Request';
    401: Result := 'Unauthorized';
    403: Result := 'Forbidden';
    404: Result := 'Not Found';
    405: Result := 'Method Not Allowed';
    409: Result := 'Conflict';
    410: Result := 'Gone';
    413: Result := 'Payload Too Large';
    415: Result := 'Unsupported Media Type';
    422: Result := 'Unprocessable Content';
    429: Result := 'Too Many Requests';
    500: Result := 'Internal Server Error';
    501: Result := 'Not Implemented';
    502: Result := 'Bad Gateway';
    503: Result := 'Service Unavailable';
    504: Result := 'Gateway Timeout';
  else
    if (ACode >= 200) and (ACode < 300) then Result := 'OK'
    else if (ACode >= 400) and (ACode < 500) then Result := 'Error'
    else if ACode >= 500 then Result := 'Server Error'
    else Result := 'Unknown';
  end;
end;

function ExtractBody(const ARequest: string): string;
var
  HeaderEnd: Integer;
begin
  HeaderEnd := Pos(#13#10#13#10, ARequest);
  if HeaderEnd = 0 then Exit('');
  Result := Copy(ARequest, HeaderEnd + 4, MaxInt);
end;

function HeadersToJSON(const AHeaderBlock: string): TJSONObject;
var
  SL: TStringList;
  i, Colon: Integer;
  Name, Value: string;
begin
  Result := TJSONObject.Create;
  SL := TStringList.Create;
  try
    SL.Text := AHeaderBlock;
    for i := 1 to SL.Count - 1 do
    begin
      Colon := Pos(':', SL[i]);
      if Colon > 0 then
      begin
        Name := Trim(Copy(SL[i], 1, Colon - 1));
        Value := Trim(Copy(SL[i], Colon + 1, MaxInt));
        if Name <> '' then
        begin
          // a repeated header is folded into one comma-separated value
          // (RFC 9110 5.3; Cookie uses "; ")
          if Assigned(Result.Find(Name)) then
            Result.Strings[Name] := Result.Strings[Name] + IfThen(SameText(Name, 'Cookie'), '; ', ', ') + CleanUTF8(Value)
          else
            Result.Strings[Name] := CleanUTF8(Value);
        end;
      end;
    end;
  finally
    SL.Free;
  end;
end;

function FindJSONObject(AObj: TJSONObject; const AName: string): TJSONObject;
var
  D: TJSONData;
begin
  D := AObj.Find(AName);
  if Assigned(D) and (D is TJSONObject) then
    Result := TJSONObject(D)
  else
    Result := nil;
end;

{ TVDRX_OneShotWaiter }

constructor TVDRX_OneShotWaiter.Create(ABus: TVDRX_MessageQueue);
begin
  inherited Create(ABus);
  FEvent := TEvent.Create(nil, True, False, '');
  FGotReply := False;
end;

destructor TVDRX_OneShotWaiter.Destroy;
begin
  FEvent.Free;
  inherited;
end;

procedure TVDRX_OneShotWaiter.HandlePacket(const AMsg: TVDRX_Message);
begin
  FReplyPayload := AMsg.Payload;
  FGotReply := True;
  FEvent.SetEvent;
end;

function TVDRX_OneShotWaiter.WaitForReply(ATimeoutMs: Integer; out APayload: string): Boolean;
begin
  Result := (FEvent.WaitFor(ATimeoutMs) = wrSignaled) and FGotReply;
  if Result then APayload := FReplyPayload else APayload := '';
end;

var
  GReplyTopicCounter: Integer = 0;
  GReplyTopicLock: TCriticalSection;

function NextReplyTopic(const APrefix: string): string;
begin
  GReplyTopicLock.Enter;
  try
    Inc(GReplyTopicCounter);
    Result := APrefix + '.' + IntToStr(GReplyTopicCounter);
  finally
    GReplyTopicLock.Leave;
  end;
end;

function PublishAndWait(ARegistry: TVDRX_Registry; ABus: TVDRX_MessageQueue;
  const AInTopic, AReplyPrefix: string; AEnvelope: TJSONObject;
  ATimeoutMs: Integer; const ASourceID: string; out AReply: string): Boolean;
var
  ReplyTopic: string;
  Waiter: TVDRX_OneShotWaiter;
begin
  ReplyTopic := NextReplyTopic(AReplyPrefix);
  AEnvelope.Add('reply_to', ReplyTopic);

  Waiter := TVDRX_OneShotWaiter.Create(ABus);
  ARegistry.Register(Waiter, ReplyTopic, ReplyTopic);

  ABus.Publish(AInTopic, AEnvelope.AsJSON, ASourceID);
  Result := Waiter.WaitForReply(ATimeoutMs, AReply);

  ARegistry.Unregister(ReplyTopic);
  if not Result then
    ABus.Publish('log.warn', Format('bus wait: no reply on "%s" (published to "%s") within %dms', [ReplyTopic, AInTopic, ATimeoutMs]), ASourceID);
end;

// Turns a reply envelope into a complete HTTP response:
//   { "status": 200, "content_type": "...", "body" | "body_b64": "...",
//     "headers": { "Name": "value" | ["v1", "v2"] } }
// or, instead of a body, { "template", "params", "rows" [, "template_topic"] }
// to have the reply rendered by the template engine.
function BuildReplyResponse(const AReplyLine, ADefaultContentType: string;
  ATemplates: TVDRX_TemplateStore; ABus: TVDRX_MessageQueue; ARegistry: TVDRX_Registry; const ASourceID: string): string;
var
  J: TJSONData;
  Obj, ParamsObj, RowsObj, HeadersObj, RenderEnvelope, ReplyObj: TJSONObject;
  ReplyJSON: TJSONData;
  Status, ContentType, Body, TemplateName, TemplateTopic, ReplyRaw, Extra, HName: string;
  StatusCode, i, k: Integer;
  Params: TStringList;
  NamedRows: TVDRX_TemplateNamedRows;
begin
  if Trim(AReplyLine) = '' then
  begin
    ABus.Publish('log.warn', 'http bus cli: empty reply from script (nothing written to stdout before exit)', ASourceID);
    Exit(PlainResponse('502 Bad Gateway', 'text/plain', 'Empty response from script'));
  end;

  J := nil;
  try
    J := GetJSON(AReplyLine);
  except
    J := nil;
  end;
  if not Assigned(J) or not (J is TJSONObject) then
  begin
    ABus.Publish('log.warn', 'http bus cli: reply was not a JSON object: ' + AReplyLine, ASourceID);
    if Assigned(J) then J.Free;
    Exit(PlainResponse('502 Bad Gateway', 'text/plain', 'Malformed response from script'));
  end;

  Obj := TJSONObject(J);
  try
    StatusCode := Obj.Get('status', 200);
    Status := IntToStr(StatusCode) + ' ' + HTTPStatusText(StatusCode);
    ContentType := Obj.Get('content_type', ADefaultContentType);
    TemplateName := Obj.Get('template', '');
    TemplateTopic := Obj.Get('template_topic', '');

    if (TemplateName <> '') and (TemplateTopic <> '') then
    begin
      RenderEnvelope := TJSONObject.Create;
      try
        RenderEnvelope.Add('template', TemplateName);
        if Assigned(FindJSONObject(Obj, 'params')) then RenderEnvelope.Add('params', FindJSONObject(Obj, 'params').Clone);
        if Assigned(FindJSONObject(Obj, 'rows')) then RenderEnvelope.Add('rows', FindJSONObject(Obj, 'rows').Clone);

        if not PublishAndWait(ARegistry, ABus, TemplateTopic, 'template.reply', RenderEnvelope, 5000, ASourceID, ReplyRaw) then
        begin
          ABus.Publish('log.warn', Format('http bus cli: no template executive answered "%s" for template "%s"', [TemplateTopic, TemplateName]), ASourceID);
          Exit(PlainResponse('502 Bad Gateway', 'text/plain', 'Template executive did not respond'));
        end;
      finally
        RenderEnvelope.Free;
      end;

      Body := '';
      ReplyJSON := nil;
      try
        try ReplyJSON := GetJSON(ReplyRaw); except ReplyJSON := nil; end;
        if Assigned(ReplyJSON) and (ReplyJSON is TJSONObject) then
        begin
          ReplyObj := TJSONObject(ReplyJSON);
          Body := ReplyObj.Get('body', '');
        end;
      finally
        if Assigned(ReplyJSON) then ReplyJSON.Free;
      end;
      if Body = '' then
        ABus.Publish('log.warn', Format('http bus cli: template executive "%s" returned no body for template "%s"', [TemplateTopic, TemplateName]), ASourceID);
    end
    else if TemplateName <> '' then
    begin
      ParamsObj := FindJSONObject(Obj, 'params');
      Params := JSONParamsToStringList(ParamsObj);
      try
        RowsObj := FindJSONObject(Obj, 'rows');
        NamedRows := JSONRowsToTemplateRows(RowsObj);
        try
          Body := ATemplates.Fill(TemplateName, Params, NamedRows);
        finally
          NamedRows.Free;
        end;
      finally
        Params.Free;
      end;
      if Body = '' then
        ABus.Publish('log.warn', Format('http bus cli: template "%s" not found or rendered empty - looked for %s', [TemplateName, IncludeTrailingPathDelimiter(ATemplates.Dir) + TemplateName + '.tpl']), ASourceID);
    end
    else if Obj.Find('body_b64') is TJSONString then
    begin
      try
        Body := DecodeStringBase64(Obj.Get('body_b64', ''));
      except
        ABus.Publish('log.warn', 'http reply: body_b64 is not valid base64', ASourceID);
        Exit(PlainResponse('502 Bad Gateway', 'text/plain', 'Malformed response body'));
      end;
    end
    else
      Body := Obj.Get('body', '');

    // Extra headers. Several lines of one name (Set-Cookie) arrive as an array.
    // The edge owns framing, so a reply can't set Content-Length, Transfer-Encoding
    // or Connection; a Content-Type in "headers" overrides "content_type".
    Extra := '';
    HeadersObj := FindJSONObject(Obj, 'headers');
    if Assigned(HeadersObj) then
      for i := 0 to HeadersObj.Count - 1 do
      begin
        HName := HeadersObj.Names[i];
        if SameText(HName, 'Content-Length') or SameText(HName, 'Transfer-Encoding') or SameText(HName, 'Connection') then Continue;
        if (HName = '') or (Pos(':', HName) > 0) or (Pos(#13, HName) > 0) or (Pos(#10, HName) > 0) then Continue;
        if HeadersObj.Items[i].JSONType in [jtString, jtNumber, jtBoolean] then
        begin
          if SameText(HName, 'Content-Type') then
            ContentType := HeadersObj.Items[i].AsString
          else
            Extra := Extra + HName + ': ' + StringReplace(StringReplace(HeadersObj.Items[i].AsString, #13, ' ', [rfReplaceAll]), #10, ' ', [rfReplaceAll]) + #13#10;
        end
        else if HeadersObj.Items[i].JSONType = jtArray then
          for k := 0 to TJSONArray(HeadersObj.Items[i]).Count - 1 do
            Extra := Extra + HName + ': ' + StringReplace(StringReplace(TJSONArray(HeadersObj.Items[i]).Items[k].AsString, #13, ' ', [rfReplaceAll]), #10, ' ', [rfReplaceAll]) + #13#10;
      end;

    Result := 'HTTP/1.1 ' + Status + #13#10 + 'Content-Type: ' + ContentType + #13#10 + Extra +
      'Content-Length: ' + IntToStr(Length(Body)) + #13#10#13#10 + Body;
  finally
    Obj.Free;
  end;
end;

function RedirectResponse(ACode: Integer; const ALocation: string; ACustomHeaders: TStringList): string;
var
  H: TStringList;
begin
  H := TStringList.Create;
  try
    H.Add('Location=' + ALocation);
    if Assigned(ACustomHeaders) then H.AddStrings(ACustomHeaders);
    Result := PlainResponse(IntToStr(ACode) + ' ' + HTTPStatusText(ACode), 'text/plain', 'Redirecting to ' + ALocation, H);
  finally
    H.Free;
  end;
end;

// The request envelope every bus route publishes (documented in readme "HTTP").
function BuildEnvelope(const ARequest, AOrigTarget: string; const ARoute: TVDRX_BusRoute;
  const AConn: TVDRX_ConnInfo; const AScriptName, AScriptFile, APathInfo: string): TJSONObject;
var
  Method, Path, HeaderBlock, Body, Host, SubPath: string;
  HeaderEnd, p: Integer;
  HeadersObj: TJSONObject;
begin
  ParseRequestLine(ARequest, Method, Path);
  HeaderEnd := Pos(#13#10#13#10, ARequest);
  if HeaderEnd > 0 then HeaderBlock := Copy(ARequest, 1, HeaderEnd - 1) else HeaderBlock := ARequest;
  Body := ExtractBody(ARequest);
  if Length(Path) >= Length(ARoute.Prefix) then
    SubPath := Copy(Path, Length(ARoute.Prefix) + 1, MaxInt)
  else
    SubPath := '';

  // Host header without its port ("[::1]:8080" -> "[::1]", "a.com:80" -> "a.com")
  Host := ExtractHeaderValue(HeaderBlock, 'Host');
  if (Host <> '') and (Host[1] = '[') then
  begin
    p := Pos(']', Host);
    if p > 0 then Host := Copy(Host, 1, p);
  end
  else
  begin
    p := Pos(':', Host);
    if p > 0 then Host := Copy(Host, 1, p - 1);
  end;
  if Host = '' then Host := 'localhost';

  Result := TJSONObject.Create;
  Result.Add('method', Method);
  Result.Add('path', CleanUTF8(Path));
  Result.Add('prefix', ARoute.Prefix);
  Result.Add('sub_path', CleanUTF8(SubPath));
  Result.Add('query', CleanUTF8(ExtractQueryString(ARequest)));
  Result.Add('request_uri', CleanUTF8(AOrigTarget));
  Result.Add('protocol', RequestVersion(ARequest));
  HeadersObj := HeadersToJSON(HeaderBlock);
  Result.Add('headers', HeadersObj);
  // JSON strings must be UTF-8; a binary body (file upload ...) travels as base64
  if IsValidUTF8(Body) then
    Result.Add('body', Body)
  else
    Result.Add('body_b64', EncodeStringBase64(Body));
  Result.Add('remote_addr', AConn.RemoteAddr);
  Result.Add('remote_port', Integer(AConn.RemotePort));
  Result.Add('server_name', Host);
  Result.Add('server_port', Integer(AConn.ServerPort));
  Result.Add('https', AConn.Secure);
  if SameText(ARoute.Kind, 'cgi') then
  begin
    Result.Add('script_name', CleanUTF8(AScriptName));
    Result.Add('script_filename', AScriptFile);
    Result.Add('path_info', CleanUTF8(APathInfo));
    Result.Add('doc_root', ExcludeTrailingPathDelimiter(ExpandFileName(ARoute.DocRoot)));
  end;
  if GVDRXEdgeToken <> '' then
    Result.Add('_edge_token', GVDRXEdgeToken);
end;

// The ONE way an HTTP request reaches code behind the bus: publish the request
// envelope to the route's in_topic, wait for a reply on a freshly minted
// reply_to topic, turn the reply back into an HTTP response. Whatever
// subscribes - a runner, a cgi executive, a supervised daemon, a WebSocket
// client - is just a consumer.
function RunBusRoute(const ARequest, AOrigTarget: string; const ARoute: TVDRX_BusRoute;
  const AConn: TVDRX_ConnInfo; const AScriptName, AScriptFile, APathInfo: string;
  ATemplates: TVDRX_TemplateStore; ABus: TVDRX_MessageQueue; ARegistry: TVDRX_Registry;
  const ASourceID: string): string;
var
  Method, Path, ReplyRaw: string;
  Env: TJSONObject;
  AllowHdrs: TStringList;
  ReplyJ: TJSONData;
  RStatus, WaitMs: Integer;
begin
  ParseRequestLine(ARequest, Method, Path);
  if ARoute.Allow <> '' then
    if Pos(',' + UpperCase(Method) + ',', ',' + StringReplace(UpperCase(ARoute.Allow), ' ', '', [rfReplaceAll]) + ',') = 0 then
    begin
      AllowHdrs := TStringList.Create;
      try
        AllowHdrs.Add('Allow=' + ARoute.Allow);
        Exit(PlainResponse('405 Method Not Allowed', 'text/plain', 'Method not allowed - use ' + ARoute.Allow, AllowHdrs));
      finally
        AllowHdrs.Free;
      end;
    end;

  Env := BuildEnvelope(ARequest, AOrigTarget, ARoute, AConn, AScriptName, AScriptFile, APathInfo);
  try
    WaitMs := ARoute.TimeoutMs;
    // the cgi executive kills a runaway program at timeout_ms and answers 504
    // itself; give that reply time to arrive before the edge gives up
    if SameText(ARoute.Kind, 'cgi') then Inc(WaitMs, 5000);
    if not PublishAndWait(ARegistry, ABus, ARoute.InTopic, 'http.reply', Env, WaitMs, ASourceID, ReplyRaw) then
    begin
      ABus.Publish('log.error', Format('http route "%s": no subscriber on "%s" answered %s within %dms', [ARoute.ID, ARoute.InTopic, Path, WaitMs]), ASourceID);
      Exit(PlainResponse('504 Gateway Timeout', 'text/plain', 'No handler answered in time'));
    end;
  finally
    Env.Free;
  end;

  ABus.Publish('log.info', Format('http route "%s": %s %s (in_topic=%s) -> %d bytes', [ARoute.ID, Method, Path, ARoute.InTopic, Length(ReplyRaw)]), ASourceID);
  if SameText(ARoute.Response, 'json') then
  begin
    // hand the browser the whole reply envelope as JSON (status, body,
    // content_type, exit_code, stderr, ...) instead of unwrapping it
    RStatus := 200;
    try
      ReplyJ := GetJSON(ReplyRaw);
      try
        if ReplyJ is TJSONObject then RStatus := TJSONObject(ReplyJ).Get('status', 200);
      finally
        ReplyJ.Free;
      end;
    except
      ReplyRaw := '{"status":502,"body":"reply was not valid JSON"}';
      RStatus := 502;
    end;
    Exit(PlainResponse(IntToStr(RStatus) + ' ' + HTTPStatusText(RStatus), 'application/json', ReplyRaw));
  end;
  Result := BuildReplyResponse(ReplyRaw, ARoute.ContentType, ATemplates, ABus, ARegistry, ASourceID);
end;

constructor TVDRX_HTTPExecutive.Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config; ATemplates: TVDRX_TemplateStore;
  const AStaticDir: string; const ARoutes: TVDRX_RouteTable;
  ARegistry: TVDRX_Registry);
begin
  inherited Create(ABus);
  FConfig := AConfig;
  FTemplates := ATemplates;
  FStaticDir := AStaticDir;
  FRoutes := ARoutes;
  FRegistry := ARegistry;
  FCustomHeaders := TStringList.Create;
  Port := 8081;
end;

destructor TVDRX_HTTPExecutive.Destroy;
begin
  FCustomHeaders.Free;
  inherited Destroy;
end;

// Adds a site's custom response headers (CORS etc., from "cors"/"headers" in
// http_sites) to a response some other code already built - used for the
// bus/cgi routes, whose responses are assembled by BuildReplyResponse
// rather than by PlainResponse. Headers the response
// already carries (matched case-insensitively) are left alone, so a script can
// still override a site default. Without this a browser would pass the CORS
// preflight but then refuse to hand the actual response to the calling page.
function InjectCustomHeaders(const AResponse: string; ACustomHeaders: TStringList): string;
var
  p, HdrEnd, i: Integer;
  Head, Extra, Name: string;
begin
  Result := AResponse;
  if (ACustomHeaders = nil) or (ACustomHeaders.Count = 0) then Exit;
  p := Pos(#13#10, AResponse);
  if p = 0 then Exit;
  HdrEnd := Pos(#13#10#13#10, AResponse);
  if HdrEnd = 0 then HdrEnd := Length(AResponse);
  Head := LowerCase(Copy(AResponse, 1, HdrEnd));
  Extra := '';
  for i := 0 to ACustomHeaders.Count - 1 do
  begin
    Name := ACustomHeaders.Names[i];
    if (Name <> '') and (Pos(#13#10 + LowerCase(Name) + ':', Head) = 0) then
      Extra := Extra + Name + ': ' + ACustomHeaders.ValueFromIndex[i] + #13#10;
  end;
  Insert(Extra, Result, p + 2);
end;

class function TVDRX_HTTPExecutive.BuildResponse(const ARequest: string;
  ATemplates: TVDRX_TemplateStore; AConfig: TVDRX_Config; const AStaticDir: string;
  const ARoutes: TVDRX_RouteTable; const AConn: TVDRX_ConnInfo;
  ABus: TVDRX_MessageQueue; ARegistry: TVDRX_Registry; const ASourceID: string;
  ACustomHeaders: TStringList): string;
var
  Method, Path, OrigTarget, Request, Location: string;
  ScriptName, ScriptFile, PathInfo, StaticPath: string;
  Query: string;
  RedirectStatus: Integer;
  Route: TVDRX_ProxyRoute;
  BusRoute: TVDRX_BusRoute;
begin
  OrigTarget := RequestTarget(ARequest);
  ParseRequestLine(ARequest, Method, Path);

  // Fast-path CORS preflight probe
  if Method = 'OPTIONS' then
  begin
    ABus.Publish('log.info', Format('http: %s %s -> 204 No Content (preflight)', [Method, Path]), ASourceID);
    Exit(PlainResponse('204 No Content', 'text/plain', '', ACustomHeaders));
  end;

  // 1. rewrites - from here on the (possibly rewritten) request is what gets routed;
  //    the envelope still carries the client's original URI as request_uri.
  Request := ARequest;
  if Length(ARoutes.Rewrites) > 0 then
  begin
    if ApplyRewrites(ARequest, ARoutes.Rewrites, Request, Location, RedirectStatus) then
    begin
      ABus.Publish('log.info', Format('http: %s %s -> %d redirect to %s', [Method, Path, RedirectStatus, Location]), ASourceID);
      Exit(RedirectResponse(RedirectStatus, Location, ACustomHeaders));
    end;
    if Request <> ARequest then
    begin
      ParseRequestLine(Request, Method, Path);
      ABus.Publish('log.info', Format('http: rewrote %s -> %s', [OrigTarget, RequestTarget(Request)]), ASourceID);
    end;
  end;

  // 2. reverse-proxy routes (processes with a prefix)
  if MatchProxyRoute(Path, ARoutes.Proxy, Route) then
  begin
    ABus.Publish('log.info', Format('http: %s %s -> proxy %s:%d', [Method, Path, Route.Host, Route.Port]), ASourceID);
    Exit(ProxyRequest(Request, Route, ABus, ASourceID));
  end;

  // 3. bus routes: http_routes and cgi entries
  if MatchBusRoute(Path, ARoutes.Bus, BusRoute) then
  begin
    ScriptName := '';
    ScriptFile := '';
    PathInfo := '';
    if SameText(BusRoute.Kind, 'cgi') then
    begin
      case ResolveCGITarget(Path, BusRoute, ScriptName, ScriptFile, PathInfo, StaticPath) of
        crScript: ;   // fall through to RunBusRoute below
        crStatic:
          begin
            if (Method <> 'GET') and (Method <> 'HEAD') then
              Exit(PlainResponse('405 Method Not Allowed', 'text/plain', 'Method not allowed', ACustomHeaders));
            Exit(ServeStaticFile(StaticPath, BusRoute.DocRoot, ABus, ASourceID, ACustomHeaders));
          end;
        crRedirectSlash:
          begin
            Query := ExtractQueryString(Request);
            Exit(RedirectResponse(301, Path + '/' + IfThen(Query <> '', '?' + Query, ''), ACustomHeaders));
          end;
        crForbidden:
          begin
            ABus.Publish('log.warn', Format('http: %s %s -> 403 (path refused under %s)', [Method, Path, BusRoute.DocRoot]), ASourceID);
            Exit(PlainResponse('403 Forbidden', 'text/plain', 'Forbidden', ACustomHeaders));
          end;
      else
        ABus.Publish('log.warn', Format('http: %s %s -> 404 (nothing under %s)', [Method, Path, BusRoute.DocRoot]), ASourceID);
        Exit(PlainResponse('404 Not Found', 'text/plain', 'Not found', ACustomHeaders));
      end;
    end;
    ABus.Publish('log.info', Format('http: %s %s -> route "%s" (%s) -> %s', [Method, Path, BusRoute.ID, BusRoute.Kind, BusRoute.InTopic]), ASourceID);
    Exit(InjectCustomHeaders(RunBusRoute(Request, OrigTarget, BusRoute, AConn, ScriptName, ScriptFile, PathInfo,
      ATemplates, ABus, ARegistry, ASourceID), ACustomHeaders));
  end;

  // 4. the site's own static_dir
  if (Method = 'GET') or (Method = 'HEAD') then
    Result := ServeStaticFile(Path, AStaticDir, ABus, ASourceID, ACustomHeaders)
  else
  begin
    ABus.Publish('log.warn', 'http: unhandled method "' + Method + '" for ' + Path, ASourceID);
    Result := PlainResponse('404 Not Found', 'text/plain', 'Not found', ACustomHeaders);
  end;
end;

{ TVDRX_HTTPConnection }

constructor TVDRX_HTTPConnection.Create(ABus: TVDRX_MessageQueue; ATransport: TVDRX_Transport;
  ATemplates: TVDRX_TemplateStore; AConfig: TVDRX_Config; const AStaticDir: string;
  const ARoutes: TVDRX_RouteTable; const AConn: TVDRX_ConnInfo;
  ARegistry: TVDRX_Registry; const ASourceID: string; ACustomHeaders: TStringList);
begin
  inherited Create(ABus);
  FTransport := ATransport;
  FTemplates := ATemplates;
  FConfig := AConfig;
  FStaticDir := AStaticDir;
  FRoutes := ARoutes;
  FConn := AConn;
  FRegistry := ARegistry;
  FSourceID := ASourceID;
  FCustomHeaders := ACustomHeaders;
end;

procedure TVDRX_HTTPConnection.HandlePacket(const AMsg: TVDRX_Message);
begin
end;

procedure TVDRX_HTTPConnection.Run(const ARequest: string);
var
  Request, Response, Method, Path: string;
  HeadEnd, Sent, N: Integer;
  TooLarge: Boolean;
begin
  TooLarge := False;
  if ARequest <> '' then
    Request := ARequest
  else
    Request := ReadFullRequest(FTransport, TooLarge);

  if TooLarge then
  begin
    Bus.Publish('log.warn', 'http: request body exceeds the configured limit - 413', FSourceID);
    Response := PlainResponse('413 Payload Too Large', 'text/plain',
      'Request body exceeds the configured limit.');
    Sent := 0;
    while Sent < Length(Response) do
    begin
      N := FTransport.Write(Response[Sent + 1], Length(Response) - Sent);
      if N <= 0 then Break;
      Inc(Sent, N);
    end;
  end
  else if Request <> '' then
  begin
    ParseRequestLine(Request, Method, Path);
    Response := TVDRX_HTTPExecutive.BuildResponse(Request, FTemplates, FConfig, FStaticDir,
      FRoutes, FConn, Bus, FRegistry, FSourceID, FCustomHeaders);
    Bus.Publish('log.info', Format('http: %s %s -> %s', [Method, Path, StatusOf(Response)]), FSourceID);
    if Method = 'HEAD' then
    begin
      // headers only (Content-Length still describes the body a GET would return)
      HeadEnd := Pos(#13#10#13#10, Response);
      if HeadEnd > 0 then SetLength(Response, HeadEnd + 3);
    end;
    // send() may accept fewer bytes than offered (big bodies, send timeout)
    Sent := 0;
    while Sent < Length(Response) do
    begin
      N := FTransport.Write(Response[Sent + 1], Length(Response) - Sent);
      if N <= 0 then
      begin
        Bus.Publish('log.warn', Format('http: %s %s - client went away after %d of %d bytes', [Method, Path, Sent, Length(Response)]), FSourceID);
        Break;
      end;
      Inc(Sent, N);
    end;
  end
  else
    Bus.Publish('log.warn', 'http: connection closed before a request arrived', FSourceID);
  FTransport.Close;
end;

procedure TVDRX_HTTPExecutive.HandleConnection(ATransport: TVDRX_Transport);
var
  Conn: TVDRX_HTTPConnection;
  Info: TVDRX_ConnInfo;
begin
  Info.RemoteAddr := ATransport.PeerAddr;
  Info.RemotePort := ATransport.PeerPort;
  Info.Secure := ATransport.Secure;
  if Info.Secure then Info.ServerPort := TLSPort else Info.ServerPort := Port;
  Conn := TVDRX_HTTPConnection.Create(Bus, ATransport, FTemplates, FConfig, FStaticDir,
    FRoutes, Info, FRegistry, ID, FCustomHeaders);
  try
    Conn.Run;
  finally
    Conn.Free;
  end;
end;

procedure TVDRX_HTTPExecutive.HandlePacket(const AMsg: TVDRX_Message);
begin
end;

function FindConfigRowByID(AConfig: TVDRX_Config; const AArrayKey, AID: string;
  out ARow: TStringList): Boolean;
var
  Rows: TVDRX_ConfigRows;
  Row: TStringList;
begin
  Result := False;
  Rows := AConfig.GetObjectArray(AArrayKey);
  try
    for Row in Rows do
      if Row.Values['id'] = AID then
      begin
        ARow := TStringList.Create;
        ARow.Assign(Row);
        Exit(True);
      end;
  finally
    Rows.Free;
  end;
end;

procedure TVDRX_HTTPExecutive.ApplyConfig;
var
  NewPort, NewTLSPort, i: Integer;
  CertFile, KeyFile, RawHeaders: string;
  SiteRow: TStringList;
  HeadersJSON: TJSONData;
  HeadersObj: TJSONObject;
begin
  if not FindConfigRowByID(FConfig, 'http_sites', ID, SiteRow) then
  begin
    Bus.Publish('log.warn', 'http ' + ID + ': no matching http_sites entry found on reload - config for this site is unchanged', ID);
    Exit;
  end;
  try
    FStaticDir := ExpandFileName(IfThen(SiteRow.Values['static_dir'] <> '', SiteRow.Values['static_dir'], 'static'));
    NewPort := StrToIntDef(SiteRow.Values['port'], Port);
    NewTLSPort := StrToIntDef(SiteRow.Values['tls_port'], 0);
    CertFile := SiteRow.Values['tls_cert'];
    KeyFile := SiteRow.Values['tls_key'];

    FCustomHeaders.Clear;
    if (SiteRow.Values['cors'] = 'True') or (SiteRow.Values['cors'] = 'true') or (SiteRow.Values['cors'] = '1') then
    begin
      FCustomHeaders.Values['Access-Control-Allow-Origin'] := '*';
      FCustomHeaders.Values['Access-Control-Allow-Methods'] := 'GET, POST, OPTIONS';
      FCustomHeaders.Values['Access-Control-Allow-Headers'] := '*';
    end;

    RawHeaders := SiteRow.Values['headers'];
    if RawHeaders <> '' then
    begin
      try
        HeadersJSON := GetJSON(RawHeaders);
        try
          if HeadersJSON is TJSONObject then
          begin
            HeadersObj := TJSONObject(HeadersJSON);
            for i := 0 to HeadersObj.Count - 1 do
              FCustomHeaders.Values[HeadersObj.Names[i]] := HeadersObj.Items[i].AsString;
          end;
        finally
          HeadersJSON.Free;
        end;
      except
      end;
    end;
  finally
    SiteRow.Free;
  end;

  if (NewPort <> Port) or (NewTLSPort <> TLSPort) then
  begin
    Shutdown;
    Port := NewPort;
    ConfigureTLS(NewTLSPort, CertFile, KeyFile);
    Initialize;
  end;
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

destructor TVDRX_ConnectionExecutive.Destroy;
begin
  if Assigned(FTransport) then
    FTransport.Free;
  inherited Destroy;
end;

{ TVDRX_WSConnection }

constructor TVDRX_WSConnection.Create(ABus: TVDRX_MessageQueue; AListener: TVDRX_WebSocketExecutive; ATransport: TVDRX_Transport);
begin
  inherited Create(ABus);
  FListener := AListener;
  FTransport := ATransport;
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
    if FTransport.Read(Ext[0], 2) <> 2 then Exit;
    Len := (Ext[0] shl 8) or Ext[1];
    // always <= 65535 here, well under WS_MAX_FRAME_LEN - checked anyway so
    // the cap is enforced the same way on both extended-length encodings
    // rather than relying on that numeric coincidence.
    if Len > WS_MAX_FRAME_LEN then Exit;
  end
  else if LenByte = 127 then
  begin
    if FTransport.Read(Ext8[0], 8) <> 8 then Exit;
    Len := 0;
    for i := 0 to 7 do
      Len := (Len shl 8) or Ext8[i];
    if (Len < 0) or (Len > WS_MAX_FRAME_LEN) then Exit;
  end;
  if (Hdr[1] and $80) <> 0 then
  begin
    if FTransport.Read(Mask[0], 4) <> 4 then Exit;
  end
  else
    FillChar(Mask, SizeOf(Mask), 0);
  SetLength(Data, Integer(Len));
  Received := 0;
  while Received < Len do
  begin
    i := FTransport.Read(Data[Received], Integer(Len - Received));
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
          FStopping := True;
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
  if not DoHandshake then
  begin
    Bus.Publish('log.warn', 'ws ' + ID + ': handshake failed, dropping connection', ID);
    Exit;
  end;

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

  FStopping := True;
  if Assigned(FPingThread) then
  begin
    WaitThreadOrTimeout(FPingThread, 1000);
    FreeAndNil(FPingThread);
  end;

  Bus.Publish('log.info', 'ws ' + ID + ': disconnected', ID);
  Bus.Publish('sys.ws.disconnected', Format('{"id":%s}', [JSONString(ID)]), ID);
  FListener.Registry.Unregister(ID + '.rpc');
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
  FAuthLock := TCriticalSection.Create;
  FAuthTrack := specialize TDictionary<string, TVDRX_AuthTrack>.Create;
end;

destructor TVDRX_WebSocketExecutive.Destroy;
begin
  FAuthTrack.Free;
  FAuthLock.Free;
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

procedure TVDRX_WebSocketExecutive.AdoptConnection(ATransport: TVDRX_Transport; const AInitialRequest: string);
var
  Conn: TVDRX_WSConnection;
  Protocol: TVDRX_WSProtocolExecutive;
  NewID: string;
  Filter: string;
begin
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

constructor TVDRX_SocketClientExecutive.Create(ABus: TVDRX_MessageQueue);
begin
  inherited Create(ABus);
  FTransportLock := TCriticalSection.Create;
  FSendLock := TCriticalSection.Create;
  FSendEvent := TEvent.Create(nil, False, False, '');
  FSendQueue := TStringList.Create;
  FPort := 0;
  FTLS := False;
  FTLSVerify := True;
  FFraming := 'delimiter';
  FDelimiter := #13#10;
  FChunkSize := 4096;
  FReconnectPolicy := 'auto';
  FReconnectDelayMs := 500;
  FMaxReconnectDelayMs := 30000;
  FGracefulTimeoutMs := 5000;
  FWriteTimeoutMs := 5000;
  FStopping := False;
  FConnected := False;
end;

destructor TVDRX_SocketClientExecutive.Destroy;
begin
  FSendQueue.Free;
  FSendEvent.Free;
  FSendLock.Free;
  FTransportLock.Free;
  inherited Destroy;
end;

procedure TVDRX_SocketClientExecutive.DoConnect;
var
  Sock: TSocket;
  Ctx: TVDRX_TLSClientContext;
  Transport: TVDRX_Transport;
  PeerName: string;
begin
  Bus.Publish('log.info', Format('%s: (re)connecting to %s:%d ...', [ID, FHost, FPort]), ID);
  if not ConnectRawSocket(FHost, FPort, Sock) then
  begin
    Bus.Publish('log.warn', Format('%s: connect to %s:%d failed', [ID, FHost, FPort]), ID);
    Exit;
  end;
  SetSocketKeepAlive(Sock); // catches a peer that goes silently half-open later

  if FTLS then
  begin
    PeerName := IfThen(FTLSPeerName <> '', FTLSPeerName, FHost);
    Ctx := TVDRX_TLSClientContext.Create(FTLSCAFile, FTLSVerify);
    try
      if not Ctx.OK then
      begin
        Bus.Publish('log.warn', Format('%s: TLS context setup failed for %s:%d (libssl not loadable, or CA file "%s" could not be loaded) - not connecting',
          [ID, FHost, FPort, FTLSCAFile]), ID);
        CloseSocket(Sock);
        Exit;
      end;
      Transport := TVDRX_TLSTransport.Create(Sock, Ctx.Ctx, PeerName);
      if not TVDRX_TLSTransport(Transport).Handshook then
      begin
        Bus.Publish('log.warn', Format('%s: TLS handshake to %s:%d failed (verify_peer=%s, ca_file="%s")',
          [ID, FHost, FPort, BoolToStr(FTLSVerify, True), FTLSCAFile]), ID);
        Transport.Close;
        Transport.Free;
        Exit;
      end;
    finally
      Ctx.Free;
    end;
  end
  else
    Transport := TVDRX_PlainTransport.Create(Sock);

  Transport.SetWriteTimeout(FWriteTimeoutMs); // bounds SendLoop's writes below - see unit comment on TVDRX_Transport.SetWriteTimeout

  FTransportLock.Enter;
  try
    FTransport := Transport;
    FConnected := True;
  finally
    FTransportLock.Leave;
  end;

  Bus.Publish('log.info', Format('%s: connected to %s:%d%s', [ID, FHost, FPort, IfThen(FTLS, ' (TLS)', '')]), ID);
  FReaderThread := TVDRX_WorkerThread.Create(@ReaderLoop);
  FReaderThread.FreeOnTerminate := False;
  FReaderThread.Start;
end;

procedure TVDRX_SocketClientExecutive.DoDisconnect;
var
  Transport: TVDRX_Transport;
  ReaderThread: TThread;
begin
  FTransportLock.Enter;
  try
    Transport := FTransport;
    FTransport := nil;
    FConnected := False;
    ReaderThread := FReaderThread;
    FReaderThread := nil;
  finally
    FTransportLock.Leave;
  end;

  if Assigned(Transport) then
  begin
    Transport.Close;
    if WaitThreadOrTimeout(ReaderThread, FGracefulTimeoutMs) then
    begin
      if Assigned(ReaderThread) then ReaderThread.Free;
    end
    else
      Bus.Publish('log.warn', ID + ': reader thread did not exit in time - abandoning it', ID);
    Transport.Free;
  end;

  // Anything still queued was addressed to the connection that just died -
  // a fresh reconnect is a new peer/session, not a continuation, so drop it
  // rather than replaying possibly-stale traffic once SendLoop picks back up.
  FSendLock.Enter;
  try
    FSendQueue.Clear;
  finally
    FSendLock.Leave;
  end;
end;

procedure TVDRX_SocketClientExecutive.ReaderLoop;
const
  BufSize = 4096;
var
  Buf: array[0..BufSize - 1] of Byte;
  Received, i: Integer;
  LineBuf, Line: string;
  Ch: Char;
  Transport: TVDRX_Transport;
  ChunkBuf: string;
begin
  LineBuf := '';
  while not FStopping do
  begin
    FTransportLock.Enter;
    Transport := FTransport;
    FTransportLock.Leave;
    if not Assigned(Transport) then Break;

    if FFraming = 'chunk' then
    begin
      SetLength(ChunkBuf, FChunkSize);
      Received := Transport.Read(ChunkBuf[1], FChunkSize);
      if Received > 0 then
        Bus.Publish(FPublishTopic, Copy(ChunkBuf, 1, Received), ID)
      else
      begin
        FTransportLock.Enter;
        FConnected := False;
        FTransportLock.Leave;
        Break;
      end;
    end
    else
    begin
      Received := Transport.Read(Buf, SizeOf(Buf));
      if Received > 0 then
      begin
        for i := 0 to Received - 1 do
        begin
          Ch := Chr(Buf[i]);
          if Ch = #10 then
          begin
            Line := LineBuf;
            LineBuf := '';
            if Line <> '' then
              Bus.Publish(FPublishTopic, Line, ID);
          end
          else if Ch <> #13 then
            LineBuf := LineBuf + Ch;
        end;
      end
      else
      begin
        FTransportLock.Enter;
        FConnected := False;
        FTransportLock.Leave;
        Break;
      end;
    end;
  end;
end;

procedure TVDRX_SocketClientExecutive.MonitorLoop;
var
  StillConnected: Boolean;
  StartDelayMs: Integer;
begin
  StartDelayMs := FReconnectDelayMs;
  while not FStopping do
  begin
    Sleep(1000);
    if FStopping then Break;

    FTransportLock.Enter;
    StillConnected := FConnected;
    FTransportLock.Leave;

    if (not StillConnected) and (not FStopping) then
    begin
      DoDisconnect;

      if FReconnectPolicy = 'none' then
      begin
        Bus.Publish('log.info', Format('%s: disconnected, reconnect policy "none" - leaving it down', [ID]), ID);
        Exit;
      end;

      Sleep(FReconnectDelayMs);
      if FReconnectDelayMs < FMaxReconnectDelayMs then
        FReconnectDelayMs := FReconnectDelayMs * 2;
      if not FStopping then
      begin
        DoConnect;
        FReconnectDelayMs := StartDelayMs;
      end;
    end;
  end;
end;

procedure TVDRX_SocketClientExecutive.Initialize;
begin
  FStopping := False;
  DoConnect;
  FMonitorThread := TVDRX_WorkerThread.Create(@MonitorLoop);
  FMonitorThread.FreeOnTerminate := False;
  FMonitorThread.Start;
  FSendThread := TVDRX_WorkerThread.Create(@SendLoop);
  FSendThread.FreeOnTerminate := False;
  FSendThread.Start;
end;

procedure TVDRX_SocketClientExecutive.Shutdown;
begin
  FStopping := True;
  FSendEvent.SetEvent; // wake SendLoop so it notices FStopping promptly
  if Assigned(FSendThread) then
  begin
    if WaitThreadOrTimeout(FSendThread, FGracefulTimeoutMs) then
      FSendThread.Free
    else
      Bus.Publish('log.warn', ID + ': send thread did not exit in time - abandoning it', ID);
    FSendThread := nil;
  end;
  DoDisconnect;
  if Assigned(FMonitorThread) then
  begin
    if WaitThreadOrTimeout(FMonitorThread, FGracefulTimeoutMs) then
      FMonitorThread.Free
    else
      Bus.Publish('log.warn', ID + ': monitor thread did not exit in time - abandoning it', ID);
    FMonitorThread := nil;
  end;
end;

// Formats the outgoing line and queues it - the actual (potentially slow)
// Transport.Write happens on FSendThread via SendLoop, never here. This is
// what keeps a stalled/half-open remote peer from blocking
// TVDRX_Kernel.Execute's single dispatch thread: HandlePacket now always
// returns immediately regardless of the connection's state.
procedure TVDRX_SocketClientExecutive.HandlePacket(const AMsg: TVDRX_Message);
var
  OutStr: string;
begin
  if FFraming = 'chunk' then
    OutStr := AMsg.Payload
  else
    OutStr := AMsg.Payload + FDelimiter;

  if Length(OutStr) > 0 then
    EnqueueLine(OutStr);
end;

procedure TVDRX_SocketClientExecutive.EnqueueLine(const ALine: string);
begin
  if FStopping then Exit;
  FSendLock.Enter;
  try
    if FStopping then Exit;
    FSendQueue.Add(ALine);
  finally
    FSendLock.Leave;
  end;
  FSendEvent.SetEvent;
end;

// Drains FSendQueue one line at a time and performs the actual blocking
// Transport.Write here, off the dispatch thread. Because DoConnect already
// called SetWriteTimeout, a stalled/half-open peer makes this Write return
// promptly (error or short write) instead of hanging - at which point this
// loop marks the connection down and lets MonitorLoop's existing
// reconnect/backoff machinery take over, exactly as if ReaderLoop had
// noticed a closed socket.
procedure TVDRX_SocketClientExecutive.SendLoop;
var
  Line: string;
  HaveLine: Boolean;
  Transport: TVDRX_Transport;
  Sent: Integer;
begin
  while not FStopping do
  begin
    if FSendEvent.WaitFor(500) <> wrSignaled then
      Continue;

    while not FStopping do
    begin
      HaveLine := False;
      FSendLock.Enter;
      try
        if FSendQueue.Count > 0 then
        begin
          Line := FSendQueue[0];
          FSendQueue.Delete(0);
          HaveLine := True;
        end;
      finally
        FSendLock.Leave;
      end;
      if not HaveLine then Break;

      FTransportLock.Enter;
      Transport := FTransport;
      FTransportLock.Leave;
      if not Assigned(Transport) then Continue; // dropped while queued - nothing to send to

      Sent := Transport.Write(Line[1], Length(Line));
      if Sent <= 0 then
      begin
        Bus.Publish('log.warn', Format('%s: write to %s:%d failed or timed out - marking connection down',
          [ID, FHost, FPort]), ID);
        FTransportLock.Enter;
        FConnected := False;
        FTransportLock.Leave;
        Break; // stop draining against a dead connection; MonitorLoop reconnects and DoDisconnect clears the rest
      end;
    end;
  end;
end;

initialization
  GReplyTopicLock := TCriticalSection.Create;

finalization
  GReplyTopicLock.Free;

end.
