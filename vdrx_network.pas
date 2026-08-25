unit vdrx_network;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, Sockets, SyncObjs, Process, vdrx_core,
  vdrx_config, vdrx_templates, vdrx_procutil, Generics.Collections,
  openssl, resolve, {$IFDEF UNIX}BaseUnix,{$ENDIF} base64, sha1, fpjson, jsonparser, DateUtils;

type

  TVDRX_SocketListenerExecutive = class;
  TVDRX_WebSocketExecutive = class;

  // One configured reverse-proxy target - see vdrx_daemon.conf's
  // "proxy_bridges" and vdrx_daemon.lpr's SetupProxyBridges. Prefix match is
  // longest-prefix-wins (like nginx location blocks), so overlapping
  // prefixes (e.g. "/app/" and "/app/admin/") behave predictably.
  TVDRX_ProxyRoute = record
    Prefix: string;
    Host: string;
    Port: Word;
  end;
  TVDRX_ProxyRoutes = array of TVDRX_ProxyRoute;

  // A one-shot-per-request PHP (or anything else) invocation, as opposed to
  // TVDRX_ProxyRoute's persistent Bridge-managed backend. No Registry/Bridge
  // involved at all - just this route table, consulted per request; the
  // process is spawned, run, and freed entirely within RunCLIScript below.
  TVDRX_CLIRoute = record
    Prefix: string;
    Command: string;
    ScriptDir: string;
    TimeoutMs: Integer;
    ContentType: string;
  end;
  TVDRX_CLIRoutes = array of TVDRX_CLIRoute;

  // Byte-stream abstraction over an accepted connection - lets every protocol
  // executive (HTTP, WebSocket) do its reads/writes without caring whether
  // the underlying socket is plaintext or TLS. Deliberately mirrors fpRecv/fpSend's
  // blocking, synchronous style - no event-loop rewrite needed anywhere else; every
  // existing "one thread per connection" executive keeps working exactly as before,
  // just talking to ATransport instead of a raw TSocket.
  TVDRX_Transport = class
  public
    function Read(var ABuf; ALen: Integer): Integer; virtual; abstract;
    function Write(const ABuf; ALen: Integer): Integer; virtual; abstract;
    procedure Close; virtual; abstract;
    procedure SetReadTimeout(ATimeoutMs: Integer); virtual; abstract;
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
  end;

  // One shared SSL_CTX per listener (holds the loaded cert/key) hands out one SSL*
  // per connection. The handshake runs in Create, on that connection's own thread -
  // same reasoning as everywhere else in this codebase: a slow/stalled TLS client
  // only blocks its own thread, never the accept loop or any other connection.
  //
  // Built against fpc's actual bundled openssl.pas (packages/openssl/src) - this is
  // a dynamically-loaded (dlopen-style) binding with Pascal-cased names (SslNew,
  // SslCtxNew, etc), NOT the raw C names (SSL_new, SSL_CTX_new). Every wrapper
  // function here lazily calls InitSSLInterface itself, so no explicit init call is
  // required - it'll just return failure/nil if libssl isn't found at runtime.
  TVDRX_TLSTransport = class(TVDRX_Transport)
  private
    FSocket: TSocket;
    FSSL: PSSL;
    FOK: Boolean;
  public
    constructor Create(ASocket: TSocket; ACtx: PSSL_CTX);
    destructor Destroy; override;
    property Handshook: Boolean read FOK; // caller checks this and drops the connection if False
    function Read(var ABuf; ALen: Integer): Integer; override;
    function Write(const ABuf; ALen: Integer): Integer; override;
    procedure Close; override;
    procedure SetReadTimeout(ATimeoutMs: Integer); override;
  end;

  // One per TLS-enabled listener - loads the cert/key once at Initialize time and
  // hands out the resulting context for TVDRX_TLSTransport to wrap each accepted
  // connection in. Deliberately doesn't crash the daemon if the cert/key don't load
  // - check .OK and skip bringing the TLS listener up if false.
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

  TVDRX_ListenerConnThread = class(TThread)
  private
    FOwner: TVDRX_SocketListenerExecutive;
    FTransport: TVDRX_Transport;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TVDRX_SocketListenerExecutive; ATransport: TVDRX_Transport);
    // Exposed so Shutdown can force-close a hung connection's transport to
    // unblock a blocking Read/Write that FStopping alone can't interrupt.
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

    // Thread tracking synchronization
    FCriticalSection: TCriticalSection;
    FActiveConnections: TList;

    function BindListenSocket(APort: Word): TSocket;
    procedure AcceptLoopPlain;
    procedure AcceptLoopTLS;
  protected
    procedure HandleConnection(ATransport: TVDRX_Transport); virtual; abstract;

    // Called by TVDRX_ListenerConnThread during life cycle
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
    property Stopping: Boolean read FStopping;
    // How long Shutdown waits for accept/connection threads to exit on their
    // own before force-closing their sockets to unblock a hung blocking
    // Read/Write. Defaults to 5000ms; set from vdrx_daemon.conf's top-level
    // "shutdown_grace_ms" in vdrx_daemon.lpr.
    property GracefulTimeoutMs: Integer read FGracefulTimeoutMs write FGracefulTimeoutMs;
    procedure Initialize; override;
    procedure Shutdown; override;
  end;

  TVDRX_WebListenerExecutive = class(TVDRX_SocketListenerExecutive)
  private
    FWebSocket: TVDRX_WebSocketExecutive;
    FTemplates: TVDRX_TemplateStore;
    FConfig: TVDRX_Config;
    FStaticDir: string;
    FProxyRoutes: TVDRX_ProxyRoutes;
    FCLIRoutes: TVDRX_CLIRoutes;
  protected
    procedure HandleConnection(ATransport: TVDRX_Transport); override;
  public
    constructor Create(ABus: TVDRX_MessageQueue;
      AWebSocket: TVDRX_WebSocketExecutive; ATemplates: TVDRX_TemplateStore;
      AConfig: TVDRX_Config; const AStaticDir: string; const AProxyRoutes: TVDRX_ProxyRoutes;
      const ACLIRoutes: TVDRX_CLIRoutes); reintroduce;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
  end;

  // Bounds RunCLIScript's wall-clock time WITHOUT blocking the read loop that
  // drains the child's stdout - see RunCLIScript's comment for why those two
  // things have to happen concurrently, not one after the other.
  TCLIWatchdog = class
  private
    FProc: TProcess;
    FTimeoutMs: Integer;
    FCancelled: Boolean;
    FFired: Boolean;
  public
    constructor Create(AProc: TProcess; ATimeoutMs: Integer);
    procedure Run;
    procedure Cancel;
    property Fired: Boolean read FFired;
  end;

  TVDRX_HTTPExecutive = class(TVDRX_SocketListenerExecutive)
  private
    FConfig: TVDRX_Config;
    FTemplates: TVDRX_TemplateStore;
    FStaticDir: string;
    FProxyRoutes: TVDRX_ProxyRoutes;
    FCLIRoutes: TVDRX_CLIRoutes;
  protected
    procedure HandleConnection(ATransport: TVDRX_Transport); override;
  public
    constructor Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config;
      ATemplates: TVDRX_TemplateStore;
      const AStaticDir: string; const AProxyRoutes: TVDRX_ProxyRoutes;
      const ACLIRoutes: TVDRX_CLIRoutes); reintroduce;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    procedure ApplyConfig; override;
    class function BuildResponse(const ARequest: string;
      ATemplates: TVDRX_TemplateStore; AConfig: TVDRX_Config; const AStaticDir: string;
      const AProxyRoutes: TVDRX_ProxyRoutes; const ACLIRoutes: TVDRX_CLIRoutes;
      ABus: TVDRX_MessageQueue; const ASourceID: string): string;
  end;

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

const
  MAX_HEADER_SIZE = 16384;
  MAX_BODY_SIZE = 10 * 1024 * 1024; // generous for dev/test form posts - not meant for large uploads
  WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

// Opens a client TCP connection to AHost:APort - for reverse-proxying to a
// locally-managed backend (see vdrx_http.pas's proxy_bridges). Returns nil
// on failure. IPv4 dotted-quad host only (matches this whole codebase's
// AF_INET-only assumption elsewhere) and plaintext only - nothing here
// talks TLS as a CLIENT, which is fine since backends are loopback-only by
// design (see vdrx_http.pas's ProxyRequest).
function ConnectTCP(const AHost: string; APort: Word): TVDRX_Transport;

implementation

// Parses a plain "a.b.c.d" IPv4 address into the 4 bytes sockaddr_in.sin_addr
// needs, in the correct (network) byte order - dotted-quad notation is
// already MSB-first, so filling Bytes[0..3] in left-to-right reading order
// and copying them straight into sin_addr is correct with no byte-swap step.
// Deliberately hand-rolled rather than relying on the Sockets unit's own
// string-to-address helper: an earlier version of this function used
// StrToHostAddr and was never actually verified against this FPC version -
// it silently produced the wrong address, which is why every connect()
// attempt hung for ~21s (Windows' default SYN-retry timeout for a target
// that never responds) instead of failing or succeeding immediately.
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

// to get around lack of poSearchPath in process.TProcessOptions
function ProcessFindInPath(const Exe: string): string;
var
  Paths: TStringList;
  Dir: string;
  Candidate: string;
begin
  Result := Exe;  // default return value

  // If Exe already contains a path, don't search PATH
  if (Pos(PathDelim, Exe) > 0) or (Pos('/', Exe) > 0) then
    Exit;

  Paths := TStringList.Create;
  try
    Paths.Delimiter := PathSeparator;
    Paths.StrictDelimiter := True;
    Paths.DelimitedText := GetEnvironmentVariable('PATH');

    for Dir in Paths do
    begin
      Candidate := IncludeTrailingPathDelimiter(Dir) + Exe;
      if FileExists(Candidate) then
      begin
        Result := Candidate;
        Exit;
      end;
    end;
  finally
    Paths.Free;
  end;
end;


function ConnectTCP(const AHost: string; APort: Word): TVDRX_Transport;
var
  Sock: TSocket;
  Addr: TInetSockAddr;
  IPBytes: Cardinal;
begin
  Result := nil;
  if not ParseIPv4(AHost, IPBytes) then Exit; // dotted-quad IPv4 only - matches the loopback-only proxy design, no DNS resolution needed
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

{ TVDRX_TLSTransport }

constructor TVDRX_TLSTransport.Create(ASocket: TSocket; ACtx: PSSL_CTX);
begin
  inherited Create;
  FSocket := ASocket;
  FSSL := SslNew(ACtx);
  SslSetFd(FSSL, FSocket);
  FOK := Assigned(FSSL) and (SslAccept(FSSL) = 1); // blocking - fine, runs on this connection's own thread
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
  // Delegate socket timeout configuration to underlying socket via temporary plain wrapper or direct options
  PlainTemp := TVDRX_PlainTransport.Create(FSocket);
  try
    PlainTemp.SetReadTimeout(ATimeoutMs);
  finally
    PlainTemp.Free;
  end;
end;

{ TVDRX_TLSContext }

constructor TVDRX_TLSContext.Create(const ACertFile, AKeyFile: string);
begin
  inherited Create;
  // SslTLSMethod loads the 'TLS_method' symbol - the modern, version-negotiating
  // method that works for both accept (server) and connect (client) roles; which
  // role you get is determined by calling SslAccept vs SslConnect, not by the
  // method object. (SslMethodV23 / 'SSLv23_method' is NOT used here - that symbol
  // was dropped from OpenSSL 1.1+/3.x and this unit itself flags it as
  // "method not supported by lib".)
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

constructor TVDRX_ListenerConnThread.Create(AOwner: TVDRX_SocketListenerExecutive; ATransport: TVDRX_Transport);
begin
  inherited Create(True);
  FOwner := AOwner;
  FTransport := ATransport;
  FreeOnTerminate := False; // Managed manually by the executive for graceful shutdown tracking
end;

procedure TVDRX_ListenerConnThread.Execute;
begin
  FOwner.RegisterConnection(Self);
  try
    try
      FOwner.HandleConnection(FTransport);
    except
      // Isolate connection exceptions
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
  FBacklog := 16;
  FGracefulTimeoutMs := 5000;
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
begin
  Result := fpSocket(AF_INET, SOCK_STREAM, 0);
  OptVal := 1;
  fpSetSockOpt(Result, SOL_SOCKET, SO_REUSEADDR, @OptVal, SizeOf(OptVal));
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(APort);
  Addr.sin_addr.s_addr := 0;
  if fpBind(Result, @Addr, SizeOf(Addr)) <> 0 then
  begin
    Bus.Publish('log.error', ID + ': fpBind failed on port ' + IntToStr(APort) +
      ' (errno ' + IntToStr(socketerror) + ') - port likely already in use', ID);
    CloseSocket(Result);
    Exit(-1); // caller must check for -1 rather than trying to accept on a dead/invalid socket
  end;
  if fpListen(Result, FBacklog) <> 0 then
  begin
    Bus.Publish('log.error', ID + ': fpListen failed on port ' + IntToStr(APort) +
      ' (errno ' + IntToStr(socketerror) + ')', ID);
    CloseSocket(Result);
    Exit(-1);
  end;
end;

procedure TVDRX_SocketListenerExecutive.AcceptLoopPlain;
var
  ClientAddr: TInetSockAddr;
  AddrLen: TSockLen;
  ClientSock: TSocket;
  ConnThread: TVDRX_ListenerConnThread;
begin
  FPlainSocket := BindListenSocket(FPort);
  if FPlainSocket = -1 then
  begin
    FPlainSocket := 0;
    Exit; // bind/listen already logged the reason above; nothing to accept on
  end;
  while not FStopping do
  begin
    AddrLen := SizeOf(ClientAddr);
    ClientSock := fpAccept(FPlainSocket, @ClientAddr, @AddrLen);
    if ClientSock = -1 then
    begin
      // An unexpected accept error (anything other than the socket having
      // just been closed for shutdown, which the FStopping check above
      // already handles) used to hit this in a tight loop with no wait,
      // pegging a CPU core. Give the error a moment to clear.
      if not FStopping then
        Sleep(10);
      Continue;
    end;

    FCriticalSection.Acquire;
    try
      if FStopping then
      begin
        CloseSocket(ClientSock);
        Break;
      end;
      ConnThread := TVDRX_ListenerConnThread.Create(Self, TVDRX_PlainTransport.Create(ClientSock));
    finally
      FCriticalSection.Release;
    end;
    ConnThread.Start;
  end;
  // Shutdown may have already closed FPlainSocket to unblock fpAccept above -
  // guard against closing an already-closed (and possibly since-reused, on
  // POSIX) descriptor a second time.
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

    Transport := TVDRX_TLSTransport.Create(ClientSock, FTLSContext.Ctx);
    if not Transport.Handshook then
    begin
      Transport.Free;
      Continue;
    end;

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

procedure TVDRX_SocketListenerExecutive.Shutdown;
var
  I: Integer;
  ConnThread: TVDRX_ListenerConnThread;
  CopyList: TList;
begin
  FStopping := True;

  // 1. Unblock accept loops. Guard + zero each socket var so the accept
  // loop's own closing code (AcceptLoopPlain/AcceptLoopTLS) won't also try
  // to close it again once it wakes up from fpAccept - double-closing a fd
  // on POSIX is dangerous once the number has been recycled for another
  // thread's socket.
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

  // 2. Join accept threads (bounded - these should return almost immediately
  // once their listen socket is closed above).
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

  // 3. Thread-safe snapshot of active connection threads to close
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
      // First give it FGracefulTimeoutMs to notice FStopping/EOF and exit on
      // its own; if it doesn't, force its transport closed - that unblocks a
      // blocking Read/Write (a connection idling on a client that never
      // sends/disconnects, the classic hang case) and lets HandleConnection
      // return. Give it one more short window after that before giving up.
      if not WaitThreadOrTimeout(ConnThread, FGracefulTimeoutMs) then
      begin
        Bus.Publish('log.warn', ID + ': connection thread did not exit in time - forcing its socket closed', ID);
        try ConnThread.Transport.Close; except end;
      end;
      if WaitThreadOrTimeout(ConnThread, FGracefulTimeoutMs) then
        ConnThread.Free
      else
        // Genuinely stuck even after a forced close (shouldn't happen) -
        // abandon it rather than risk freeing an object a live thread is
        // still touching.
        Bus.Publish('log.warn', ID + ': connection thread still stuck after forcing its socket closed - abandoning it', ID);
    end;
  finally
    CopyList.Free;
  end;

  // 4. Safe to tear down shared resources like context now that all threads are dead
  FTLSContext.Free;
  FTLSContext := nil;
end;

constructor TVDRX_WebListenerExecutive.Create(ABus: TVDRX_MessageQueue; AWebSocket: TVDRX_WebSocketExecutive;
  ATemplates: TVDRX_TemplateStore; AConfig: TVDRX_Config; const AStaticDir: string;
  const AProxyRoutes: TVDRX_ProxyRoutes; const ACLIRoutes: TVDRX_CLIRoutes);
begin
  inherited Create(ABus);
  FWebSocket := AWebSocket;
  FTemplates := ATemplates;
  FConfig := AConfig;
  FStaticDir := AStaticDir;
  FProxyRoutes := AProxyRoutes;
  FCLIRoutes := ACLIRoutes;
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
    Response := TVDRX_HTTPExecutive.BuildResponse(Request, FTemplates, FConfig, FStaticDir, FProxyRoutes, FCLIRoutes, Bus, ID);
    ATransport.Write(Response[1], Length(Response));
    ATransport.Close;
    ATransport.Free;
  end;
end;

procedure TVDRX_WebListenerExecutive.HandlePacket(const AMsg: TVDRX_Message);
begin
  // Request/response + hand-off only.
end;

constructor TCLIWatchdog.Create(AProc: TProcess; ATimeoutMs: Integer);
begin
  inherited Create;
  FProc := AProc;
  FTimeoutMs := ATimeoutMs;
end;

procedure TCLIWatchdog.Cancel;
begin
  FCancelled := True;
end;

procedure TCLIWatchdog.Run;
var
  Waited: Integer;
begin
  Waited := 0;
  while (not FCancelled) and (Waited < FTimeoutMs) do
  begin
    Sleep(50);
    Inc(Waited, 50);
  end;
  if (not FCancelled) and FProc.Running then
  begin
    FFired := True;
    ForceKillProcess(FProc);
  end;
end;

function PlainResponse(const AStatus, AContentType, ABody: string): string;
begin
  Result := 'HTTP/1.1 ' + AStatus + #13#10 +
            'Content-Type: ' + AContentType + #13#10 +
            'Content-Length: ' + IntToStr(Length(ABody)) + #13#10#13#10 + ABody;
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
    for i := 1 to SL.Count - 1 do // line 0 is the request line, not a header
    begin
      Colon := Pos(':', SL[i]);
      if (Colon > 0) and SameText(Trim(Copy(SL[i], 1, Colon - 1)), AName) then
        Exit(Trim(Copy(SL[i], Colon + 1, MaxInt)));
    end;
  finally
    SL.Free;
  end;
end;

// Reads a full request off the wire: headers (up to the blank line), then -
// if a Content-Length header is present - exactly that many more body bytes.
// Needed for the proxy path (a PHP app expects to see the whole POST body,
// not the first ~1KB a single Read happened to return) but applies to every
// request now, board/static included, since it's strictly more correct.
function ReadFullRequest(ATransport: TVDRX_Transport): string;
var
  Buf: array[0..4095] of Byte;
  Received, HeaderEnd, ContentLength, BodySoFar, ToRead: Integer;
  HeaderBlock, CLStr: string;
begin
  Result := '';
  HeaderEnd := 0;
  while (HeaderEnd = 0) and (Length(Result) < MAX_HEADER_SIZE) do
  begin
    Received := ATransport.Read(Buf[0], SizeOf(Buf));
    if Received <= 0 then Exit(Result); // closed before headers finished - hand back whatever we have
    SetLength(Result, Length(Result) + Received);
    Move(Buf[0], Result[Length(Result) - Received + 1], Received);
    HeaderEnd := Pos(#13#10#13#10, Result);
  end;
  if HeaderEnd = 0 then Exit; // headers too large or never terminated - drop rather than hang

  HeaderBlock := Copy(Result, 1, HeaderEnd - 1);
  CLStr := ExtractHeaderValue(HeaderBlock, 'Content-Length');
  ContentLength := 0;
  if CLStr <> '' then
    ContentLength := StrToIntDef(Trim(CLStr), 0);
  if ContentLength > MAX_BODY_SIZE then ContentLength := MAX_BODY_SIZE; // clamp rather than reject

  BodySoFar := Length(Result) - (HeaderEnd + 3);
  while BodySoFar < ContentLength do
  begin
    ToRead := ContentLength - BodySoFar;
    if ToRead > SizeOf(Buf) then ToRead := SizeOf(Buf);
    Received := ATransport.Read(Buf[0], ToRead);
    if Received <= 0 then Break; // client stopped sending early - forward whatever we actually got
    SetLength(Result, Length(Result) + Received);
    Move(Buf[0], Result[Length(Result) - Received + 1], Received);
    Inc(BodySoFar, Received);
  end;
end;

function IsValidBoardName(const AName: string): Boolean;
var
  i: Integer;
begin
  Result := (Length(AName) > 0) and (Length(AName) <= 64);
  if not Result then Exit;
  for i := 1 to Length(AName) do
    if not (AName[i] in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-']) then
      Exit(False);
end;

function GuessContentType(const APath: string): string;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(APath));
  if Ext = '.js' then Result := 'application/javascript'
  else if Ext = '.css' then Result := 'text/css'
  else if Ext = '.html' then Result := 'text/html'
  else if Ext = '.json' then Result := 'application/json'
  else if Ext = '.svg' then Result := 'image/svg+xml'
  else Result := 'application/octet-stream';
end;

function ServeStaticFile(const APath, AStaticDir: string; ABus: TVDRX_MessageQueue; const ASourceID: string): string;
var
  FilePath, Body: string;
  FS: TFileStream;
begin
  ABus.Publish('log.info', 'http: static path: "' + APath + '"', ASourceID);
  if (AStaticDir = '') or (Pos('..', APath) > 0) or (APath = '') or (APath[1] <> '/') then
  begin
    ABus.Publish('log.warn', 'http: rejected static path "' + APath + '"', ASourceID);
    Exit(PlainResponse('404 Not Found', 'text/plain', 'Not found'));
  end;
  FilePath := IncludeTrailingPathDelimiter(AStaticDir) + Copy(APath, 2, MaxInt);
  if (not FileExists(FilePath)) or DirectoryExists(FilePath) then
  begin
    ABus.Publish('log.warn', 'http: static file not found: ' + FilePath, ASourceID);
    Exit(PlainResponse('404 Not Found', 'text/plain', 'Not found'));
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
  Result := PlainResponse('200 OK', GuessContentType(APath), Body);
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

// Strips any existing Connection header and forces 'Connection: close' -
// without this, a keep-alive-capable backend (php -S included) would hold
// the socket open waiting for a second request over the same connection,
// and the "read until the backend closes" loop in ProxyRequest below would
// then block forever on every single proxied request. Same shape of bug as
// the WebSocket self-join deadlock from earlier in this project: a blocking
// read with no other signal for "the response is actually done."
function ForceConnectionClose(const ARequest: string): string;
var
  HeaderEnd, i: Integer;
  OutLines: TStringList;
begin
  HeaderEnd := Pos(#13#10#13#10, ARequest);
  if HeaderEnd = 0 then Exit(ARequest); // malformed - forward as-is rather than guess
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
    // The backend can take a moment to finish starting and bind its port
    // after Bridge spawns it - a request landing in that window (most
    // likely right after the daemon itself just started, or right after
    // 'sys.restart') would otherwise get a spurious 502 on an
    // otherwise-healthy setup. A few short retries covers that startup
    // race without masking a genuinely-down backend for long.
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

function MatchCLIRoute(const APath: string; const ARoutes: TVDRX_CLIRoutes; out AMatch: TVDRX_CLIRoute): Boolean;
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

// Same '..'-rejection posture as ServeStaticFile - a literal-substring check,
// not full canonicalization. Consistent risk level to what's already
// accepted for static files in this codebase; fine for the "not secure yet"
// bar everything else here is at.
function ResolveScriptPath(const APath, APrefix, AScriptDir: string; out AScriptPath: string): Boolean;
var
  Rel: string;
begin
  Result := False;
  Rel := Copy(APath, Length(APrefix) + 1, MaxInt);
  if (Rel = '') or (Pos('..', Rel) > 0) then Exit;
  AScriptPath := IncludeTrailingPathDelimiter(AScriptDir) + Rel;
  Result := FileExists(AScriptPath);
end;

// Spawns ARoute.Command ScriptPath fresh, feeds it a handful of CGI-ish env
// vars (works whether ARoute.Command is plain 'php' - readable via
// getenv()/$_SERVER - or 'php-cgi', which auto-populates $_GET/$_POST from
// them like a real CGI SAPI would), and returns its stdout verbatim as the
// response body. The read loop and TCLIWatchdog run CONCURRENTLY - see the
// type's comment above for why draining stdout can't wait until after the
// process exits.
function RunCLIScript(const ARequest: string; const ARoute: TVDRX_CLIRoute;
  ABus: TVDRX_MessageQueue; const ASourceID: string): string;
var
  Method, Path, ScriptPath, QueryString, HeaderBlock: string;
  Proc: TProcess;
  Watchdog: TCLIWatchdog;
  WatchdogThread: TThread;
  Buf: array[0..4095] of Byte;
  Received, HdrEnd: Integer;
  Output: string;
begin
  ParseRequestLine(ARequest, Method, Path);
  if not ResolveScriptPath(Path, ARoute.Prefix, ARoute.ScriptDir, ScriptPath) then
  begin
    ABus.Publish('log.warn', 'http cli: no script found for "' + Path + '" under ' + ARoute.ScriptDir, ASourceID);
    Exit(PlainResponse('404 Not Found', 'text/plain', 'Not found'));
  end;

  QueryString := ExtractQueryString(ARequest);
  HdrEnd := Pos(#13#10#13#10, ARequest);
  if HdrEnd > 0 then HeaderBlock := Copy(ARequest, 1, HdrEnd - 1) else HeaderBlock := ARequest;

  Proc := TProcess.Create(nil);
  try
    if FileExists(ARoute.Command) then
      Proc.Executable := ARoute.Command
    else
      Proc.Executable := ProcessFindInPath(ARoute.Command);
    Proc.Parameters.Add(ScriptPath);
    Proc.Environment.Add('REQUEST_METHOD=' + Method);
    Proc.Environment.Add('QUERY_STRING=' + QueryString);
    Proc.Environment.Add('REQUEST_URI=' + Path + IfThen(QueryString <> '', '?' + QueryString, ''));
    Proc.Environment.Add('CONTENT_TYPE=' + ExtractHeaderValue(HeaderBlock, 'Content-Type'));
    Proc.Environment.Add('CONTENT_LENGTH=' + ExtractHeaderValue(HeaderBlock, 'Content-Length'));
    // poSearchPath: without it, ARoute.Command only works as an absolute
    // path ("/usr/bin/php") - a bare command name like "php" from
    // vdrx.conf would fail to launch on any system where it's only
    // resolvable via the shell's PATH.
    //Proc.Options := [poUsePipes, poStderrToOutPut, poSearchPath]; // poSearchPath not in process.TProcessOptions
    Proc.Options := [poUsePipes, poStderrToOutPut];

    Proc.CurrentDirectory := ARoute.ScriptDir;
    Proc.Execute;

    Watchdog := TCLIWatchdog.Create(Proc, ARoute.TimeoutMs);
    WatchdogThread := TVDRX_WorkerThread.Create(@Watchdog.Run);
    WatchdogThread.FreeOnTerminate := False;
    WatchdogThread.Start;
    try
      Output := '';
      repeat
        Received := Proc.Output.Read(Buf[0], SizeOf(Buf));
        if Received > 0 then
        begin
          SetLength(Output, Length(Output) + Received);
          Move(Buf[0], Output[Length(Output) - Received + 1], Received);
        end;
      until Received <= 0;

      Watchdog.Cancel;
      WaitThreadOrTimeout(WatchdogThread, 500); // polls every 50ms internally - should return almost immediately

      if Watchdog.Fired then
      begin
        ABus.Publish('log.error', Format('http cli: %s exceeded %dms, killed it', [ScriptPath, ARoute.TimeoutMs]), ASourceID);
        Exit(PlainResponse('504 Gateway Timeout', 'text/plain', 'Script timed out'));
      end;
    finally
      WatchdogThread.Free;
      Watchdog.Free;
    end;
  finally
    Proc.Free;
  end;

  ABus.Publish('log.info', Format('http cli: %s -> %d bytes', [ScriptPath, Length(Output)]), ASourceID);
  Result := PlainResponse('200 OK', ARoute.ContentType, Output);
end;

constructor TVDRX_HTTPExecutive.Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config; ATemplates: TVDRX_TemplateStore;
  const AStaticDir: string; const AProxyRoutes: TVDRX_ProxyRoutes; const ACLIRoutes: TVDRX_CLIRoutes);
begin
  inherited Create(ABus);
  FConfig := AConfig;
  FTemplates := ATemplates;
  FStaticDir := AStaticDir;
  FProxyRoutes := AProxyRoutes;
  FCLIRoutes := ACLIRoutes;
  Port := 8081;
end;

class function TVDRX_HTTPExecutive.BuildResponse(const ARequest: string;
  ATemplates: TVDRX_TemplateStore; AConfig: TVDRX_Config; const AStaticDir: string;
  const AProxyRoutes: TVDRX_ProxyRoutes; const ACLIRoutes: TVDRX_CLIRoutes;
  ABus: TVDRX_MessageQueue; const ASourceID: string): string;
var
  Method, Path, BoardName: string;
  Route: TVDRX_ProxyRoute;
  CLIRoute: TVDRX_CLIRoute;
begin
  ParseRequestLine(ARequest, Method, Path);

  if MatchProxyRoute(Path, AProxyRoutes, Route) then
  begin
    ABus.Publish('log.info', Format('http: %s %s -> proxy %s:%d', [Method, Path, Route.Host, Route.Port]), ASourceID);
    Exit(ProxyRequest(ARequest, Route, ABus, ASourceID));
  end;

  if MatchCLIRoute(Path, ACLIRoutes, CLIRoute) then
  begin
    ABus.Publish('log.info', Format('http: %s %s -> cli %s', [Method, Path, CLIRoute.Command]), ASourceID);
    Exit(RunCLIScript(ARequest, CLIRoute, ABus, ASourceID));
  end;

  if Method = 'GET' then
    Result := ServeStaticFile(Path, AStaticDir, ABus, ASourceID)
  else
  begin
    ABus.Publish('log.warn', 'http: unhandled method "' + Method + '" for ' + Path, ASourceID);
    Result := PlainResponse('404 Not Found', 'text/plain', 'Not found');
  end;
end;

procedure TVDRX_HTTPExecutive.HandleConnection(ATransport: TVDRX_Transport);
var
  Request, Response, Method, Path: string;
begin
  Request := ReadFullRequest(ATransport);
  if Request <> '' then
  begin
    ParseRequestLine(Request, Method, Path);
    Response := BuildResponse(Request, FTemplates, FConfig, FStaticDir, FProxyRoutes, FCLIRoutes, Bus, ID);
    Bus.Publish('log.info', Format('http: %s %s -> %s', [Method, Path, StatusOf(Response)]), ID);
    ATransport.Write(Response[1], Length(Response));
  end
  else
    Bus.Publish('log.warn', 'http: connection closed before a request arrived', ID);
  ATransport.Close;
  ATransport.Free;
end;

procedure TVDRX_HTTPExecutive.HandlePacket(const AMsg: TVDRX_Message);
begin
  // HTTP is request/response, not bus-driven - nothing to do here.
end;

procedure TVDRX_HTTPExecutive.ApplyConfig;
var
  NewPort, NewTLSPort: Integer;
  CertFile, KeyFile: string;
begin
  FStaticDir := FConfig.GetString('static_dir', FStaticDir);
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
  // NB: FProxyRoutes is NOT rebuilt here yet - proxy_bridges is only read at
  // startup (see vdrx_daemon.lpr's SetupProxyBridges). A 'sys.reload' picks
  // up template/board-nav/port changes live but not new/changed proxy
  // routes - restart the daemon (or 'sys.restart') for those.
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
  // Natural (client-initiated) disconnects finish inside RunLoop by calling
  // UnregisterSelf, which frees the owning TVDRX_WSConnection (and this
  // thread's FConn along with it) while still running on this very thread.
  // Nothing outside ever holds a reference to FThread to Free it in that
  // path (see RunLoop), so this thread must clean up its own TThread object
  // when it terminates or it leaks. Shutdown's forced-close path still works
  // fine with this set True: it just stops calling FThread.Free itself
  // (see TVDRX_WSConnection.Shutdown).
  FreeOnTerminate := True;
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
  FStopping := True;
  // Fallback cleanup: normally RunLoop already stops and frees FPingThread
  // itself before calling UnregisterSelf (which is what drives us here), so
  // this is a no-op on that path. But Destroy can also be reached via
  // Shutdown's FMasterMap.Remove, so guard here too - freeing FTransport/
  // FSendLock below while FPingThread's PingLoop might still be mid-SendFrame
  // on another thread is the exact use-after-free this used to hit.
  if Assigned(FPingThread) then
  begin
    WaitThreadOrTimeout(FPingThread, 500);
    FreeAndNil(FPingThread);
  end;
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

// Frames declaring a payload bigger than this are rejected outright rather
// than trusting the client's stated 64-bit length as-is - without a cap, a
// single malicious/buggy frame could claim an enormous length and force a
// huge SetLength allocation before we've even read that much data.
const
  WS_MAX_FRAME_LEN = 64 * 1024 * 1024; // 64MB

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
  end
  else if LenByte = 127 then
  begin
    // 64-bit extended length (RFC 6455 5.2) - previously this branch just
    // aborted and dropped the connection for any frame over 65,535 bytes.
    if FTransport.Read(Ext8[0], 8) <> 8 then Exit;
    Len := 0;
    for i := 0 to 7 do
      Len := (Len shl 8) or Ext8[i];
    if (Len < 0) or (Len > WS_MAX_FRAME_LEN) then Exit; // oversized/malformed - drop rather than allocate
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
    if i <= 0 then Exit; // connection closed/errored mid-frame
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
  PayloadData: TJSONData;
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
      PayloadData := Obj.Find('payload');
      if not Assigned(PayloadData) then
        Payload := '{}'
      else if PayloadData.JSONType = jtString then
        Payload := PayloadData.AsString
      else
        Payload := PayloadData.AsJSON;
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

  // Stop and free FPingThread BEFORE UnregisterSelf below, which frees Self
  // (FMasterMap has [doOwnsValues]). FPingThread's PingLoop touches FSendLock
  // and FTransport on its own thread; freeing those out from under a still-
  // running PingLoop was a real Access Violation. Setting FStopping here also
  // makes PingLoop notice and exit on its own between iterations even without
  // the join below.
  FStopping := True;
  if Assigned(FPingThread) then
  begin
    WaitThreadOrTimeout(FPingThread, 1000);
    FreeAndNil(FPingThread);
  end;

  Bus.Publish('log.info', 'ws ' + ID + ': disconnected', ID);
  Bus.Publish('sys.ws.disconnected', Format('{"id":%s}', [JSONString(ID)]), ID);
  FListener.Registry.UnregisterSelf(ID); // NOT Unregister - this is our own thread, see vdrx_core.pas's UnregisterSelf comment
  // Self (and every field on it, including FTransport/FSendLock) is invalid
  // from this point on - do not touch anything after the call above.
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
    // FThread now has FreeOnTerminate := True (see TWSConnThread.Create), so
    // it frees itself when RunLoop returns - we must NOT call FThread.Free
    // here too, or we'd double-free it. Just wait for it to finish, then
    // drop our own now-dangling reference.
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
