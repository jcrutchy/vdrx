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

  TVDRX_ProxyRoute = record
    Prefix: string;
    Host: string;
    Port: Word;
  end;
  TVDRX_ProxyRoutes = array of TVDRX_ProxyRoute;

  TVDRX_CLIRoute = record
    Prefix: string;
    Command: string;
    ScriptDir: string;
    TimeoutMs: Integer;
    ContentType: string;
    Protocol: string;
    InTopic: string;
  end;
  TVDRX_CLIRoutes = array of TVDRX_CLIRoute;

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

    function BindListenSocket(APort: Word): TSocket;
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
    property Stopping: Boolean read FStopping;
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

  TVDRX_OneShotWaiter = class(TVDRX_Executive)
  private
    FEvent: TEvent;
    FReplyPayload: string;
    FGotReply: Boolean;
  public
    constructor Create(ABus: TVDRX_MessageQueue);
    destructor Destroy; override;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    function WaitForReply(ATimeoutMs: Integer; out APayload: string): Boolean;
  end;

  TVDRX_HTTPExecutive = class(TVDRX_SocketListenerExecutive)
  private
    FConfig: TVDRX_Config;
    FTemplates: TVDRX_TemplateStore;
    FStaticDir: string;
    FProxyRoutes: TVDRX_ProxyRoutes;
    FCLIRoutes: TVDRX_CLIRoutes;
    FRegistry: TVDRX_Registry;
    FCustomHeaders: TStringList;
  protected
    procedure HandleConnection(ATransport: TVDRX_Transport); override;
  public
    constructor Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config;
      ATemplates: TVDRX_TemplateStore;
      const AStaticDir: string; const AProxyRoutes: TVDRX_ProxyRoutes;
      const ACLIRoutes: TVDRX_CLIRoutes; ARegistry: TVDRX_Registry); reintroduce;
    destructor Destroy; override;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    procedure ApplyConfig; override;
    property CustomHeaders: TStringList read FCustomHeaders;
    class function BuildResponse(const ARequest: string;
      ATemplates: TVDRX_TemplateStore; AConfig: TVDRX_Config; const AStaticDir: string;
      const AProxyRoutes: TVDRX_ProxyRoutes; const ACLIRoutes: TVDRX_CLIRoutes;
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
    FProxyRoutes: TVDRX_ProxyRoutes;
    FCLIRoutes: TVDRX_CLIRoutes;
    FRegistry: TVDRX_Registry;
    FSourceID: string;
    FCustomHeaders: TStringList;
  public
    constructor Create(ABus: TVDRX_MessageQueue; ATransport: TVDRX_Transport;
      ATemplates: TVDRX_TemplateStore; AConfig: TVDRX_Config; const AStaticDir: string;
      const AProxyRoutes: TVDRX_ProxyRoutes; const ACLIRoutes: TVDRX_CLIRoutes;
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
    procedure PingLoop;
    procedure SendLoop;
    procedure EnqueueFrame(const APayload: string; AOpcode: Byte);
    function WriteAll(const ABuf: string): Boolean;
    function DoHandshake: Boolean;
    function ReadFrame(out APayload: string; out AOpcode: Byte): Boolean;
  public
    constructor Create(ABus: TVDRX_MessageQueue; AListener: TVDRX_WebSocketExecutive; ATransport: TVDRX_Transport);
    destructor Destroy; override;
    property PendingRequest: string read FPendingRequest write FPendingRequest;
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
  public
    constructor Create(ABus: TVDRX_MessageQueue; AListener: TVDRX_WebSocketExecutive; AConn: TVDRX_WSConnection); reintroduce;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
  end;

  TVDRX_WebSocketExecutive = class(TVDRX_SocketListenerExecutive)
  private
    FConfig: TVDRX_Config;
    FRegistry: TVDRX_Registry;
    FConnCounter: Integer;
    FPingIntervalMs, FPongTimeoutMs: Integer;
    FDefaultSubscribe: string;
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

    procedure DoConnect;
    procedure DoDisconnect;
    procedure ReaderLoop;
    procedure MonitorLoop;
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
    procedure Initialize; override;
    procedure Shutdown; override;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
  end;

const
  MAX_HEADER_SIZE = 16384;
  MAX_BODY_SIZE = 10 * 1024 * 1024;
  WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

function ConnectTCP(const AHost: string; APort: Word): TVDRX_Transport;
function ConnectTCPHost(const AHost: string; APort: Word): TVDRX_Transport;
procedure ApplyOpenSSLDLLOverrides(AConfig: TVDRX_Config);

implementation

function ReadFullRequest(ATransport: TVDRX_Transport): string; forward;

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

function ProcessFindInPath(const Exe: string): string;
var
  Paths: TStringList;
  Dir: string;
  Candidate: string;
begin
  Result := Exe;
  if (Pos(PathDelim, Exe) > 0) or (Pos('/', Exe) > 0) then Exit;
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
  Request: string;
  Conn: TVDRX_HTTPConnection;
begin
  Request := ReadFullRequest(ATransport);
  if Request = '' then
  begin
    ATransport.Close;
    ATransport.Free;
    Exit;
  end;

  if TVDRX_WSConnection.IsUpgradeRequest(Request) then
    FWebSocket.AdoptConnection(ATransport, Request)
  else
  begin
    Conn := TVDRX_HTTPConnection.Create(Bus, ATransport, FTemplates, FConfig, FStaticDir,
      FProxyRoutes, FCLIRoutes, FWebSocket.Registry, ID);
    try
      Conn.Run(Request);
    finally
      Conn.Free;
    end;
  end;
end;

procedure TVDRX_WebListenerExecutive.HandlePacket(const AMsg: TVDRX_Message);
begin
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

function ReadFullRequest(ATransport: TVDRX_Transport): string;
var
  Buf: array[0..4095] of Byte;
  Received, HeaderEnd, ContentLength, BodySoFar, ToRead, TotalLen: Integer;
  HeaderBlock, CLStr: string;
begin
  Result := '';
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
  if ContentLength > MAX_BODY_SIZE then ContentLength := MAX_BODY_SIZE;

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
  else Result := 'application/octet-stream';
end;

function ServeStaticFile(const APath, AStaticDir: string; ABus: TVDRX_MessageQueue;
  const ASourceID: string; ACustomHeaders: TStringList = nil): string;
var
  FilePath, Body: string;
  FS: TFileStream;
begin
  ABus.Publish('log.info', 'http: static path: "' + APath + '"', ASourceID);
  if (AStaticDir = '') or (Pos('..', APath) > 0) or (APath = '') or (APath[1] <> '/') then
  begin
    ABus.Publish('log.warn', 'http: rejected static path "' + APath + '"', ASourceID);
    Exit(PlainResponse('404 Not Found', 'text/plain', 'Not found', ACustomHeaders));
  end;
  FilePath := IncludeTrailingPathDelimiter(AStaticDir) + Copy(APath, 2, MaxInt);
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
  Result := PlainResponse('200 OK', GuessContentType(APath), Body, ACustomHeaders);
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
    Proc.Options := [poUsePipes, poStderrToOutPut];
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
      WaitThreadOrTimeout(WatchdogThread, 500);

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
    400: Result := 'Bad Request';
    401: Result := 'Unauthorized';
    403: Result := 'Forbidden';
    404: Result := 'Not Found';
    405: Result := 'Method Not Allowed';
    500: Result := 'Internal Server Error';
    502: Result := 'Bad Gateway';
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
          Result.Strings[Name] := Value;
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

function BuildBusCLIResponse(const AReplyLine, ADefaultContentType: string;
  ATemplates: TVDRX_TemplateStore; ABus: TVDRX_MessageQueue; ARegistry: TVDRX_Registry; const ASourceID: string): string;
var
  J: TJSONData;
  Obj, ParamsObj, RowsObj, HeadersObj, RenderEnvelope, ReplyObj: TJSONObject;
  ReplyJSON: TJSONData;
  Status, ContentType, Body, TemplateName, TemplateTopic, ReplyRaw: string;
  StatusCode, i: Integer;
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
    else
      Body := Obj.Get('body', '');

    Result := 'HTTP/1.1 ' + Status + #13#10 + 'Content-Type: ' + ContentType + #13#10;

    HeadersObj := FindJSONObject(Obj, 'headers');
    if Assigned(HeadersObj) then
      for i := 0 to HeadersObj.Count - 1 do
        if HeadersObj.Items[i].JSONType in [jtString, jtNumber, jtBoolean] then
          Result := Result + HeadersObj.Names[i] + ': ' + HeadersObj.Items[i].AsString + #13#10;

    Result := Result + 'Content-Length: ' + IntToStr(Length(Body)) + #13#10#13#10 + Body;
  finally
    Obj.Free;
  end;
end;

function RunBusCLIScript(const ARequest: string; const ARoute: TVDRX_CLIRoute;
  ATemplates: TVDRX_TemplateStore; ABus: TVDRX_MessageQueue; ARegistry: TVDRX_Registry; const ASourceID: string): string;
var
  Method, Path, SubPath, QueryString, HeaderBlock, Body, ReqLine, Output, FirstLine: string;
  HeaderEnd: Integer;
  ReqObj: TJSONObject;
  Proc: TProcess;
  Watchdog: TCLIWatchdog;
  WatchdogThread: TThread;
  Buf: array[0..4095] of Byte;
  Received, i: Integer;
  Cwd: string;
begin
  ParseRequestLine(ARequest, Method, Path);
  QueryString := ExtractQueryString(ARequest);
  HeaderEnd := Pos(#13#10#13#10, ARequest);
  if HeaderEnd > 0 then HeaderBlock := Copy(ARequest, 1, HeaderEnd - 1) else HeaderBlock := ARequest;
  Body := ExtractBody(ARequest);

  if Length(Path) >= Length(ARoute.Prefix) then
    SubPath := Copy(Path, Length(ARoute.Prefix) + 1, MaxInt)
  else
    SubPath := '';

  ReqObj := TJSONObject.Create;
  try
    ReqObj.Add('method', Method);
    ReqObj.Add('path', Path);
    ReqObj.Add('prefix', ARoute.Prefix);
    ReqObj.Add('sub_path', SubPath);
    ReqObj.Add('query', QueryString);
    ReqObj.Add('headers', HeadersToJSON(HeaderBlock));
    ReqObj.Add('body', Body);
    ReqLine := ReqObj.AsJSON + LineEnding;
  finally
    ReqObj.Free;
  end;

  Proc := TProcess.Create(nil);
  try
    {$WARN SYMBOL_DEPRECATED OFF}
    Proc.CommandLine := ARoute.Command;
    {$WARN SYMBOL_DEPRECATED ON}
    Cwd := ExpandFileName(IfThen(ARoute.ScriptDir <> '', ARoute.ScriptDir, GetCurrentDir));
    Proc.CurrentDirectory := Cwd;
    Proc.Options := [poUsePipes, poStderrToOutPut];
    try
      Proc.Execute;
    except
      on E: Exception do
      begin
        ABus.Publish('log.error', Format('http bus cli: failed to start "%s" (cwd=%s) - %s', [ARoute.Command, Cwd, E.Message]), ASourceID);
        Exit(PlainResponse('502 Bad Gateway', 'text/plain', 'Could not start script'));
      end;
    end;

    Proc.Input.Write(ReqLine[1], Length(ReqLine));
    try Proc.CloseInput; except end;

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
      WaitThreadOrTimeout(WatchdogThread, 500);

      if Watchdog.Fired then
      begin
        ABus.Publish('log.error', Format('http bus cli: %s (cwd=%s) exceeded %dms, killed it', [ARoute.Command, Cwd, ARoute.TimeoutMs]), ASourceID);
        Exit(PlainResponse('504 Gateway Timeout', 'text/plain', 'Script timed out'));
      end;
    finally
      WatchdogThread.Free;
      Watchdog.Free;
    end;
  finally
    Proc.Free;
  end;

  if (Length(Output) >= 3) and (Output[1] = #$EF) and (Output[2] = #$BB) and (Output[3] = #$BF) then
    Delete(Output, 1, 3);

  FirstLine := '';
  with TStringList.Create do
  try
    Text := Output;
    for i := 0 to Count - 1 do
    begin
      if Copy(TrimLeft(Strings[i]), 1, 1) = '{' then
      begin
        FirstLine := Trim(Strings[i]);
        Break;
      end;
    end;
    if (FirstLine = '') and (Count > 0) then
      ABus.Publish('log.warn', Format('http bus cli: %s (cwd=%s) produced no line starting with "{" - raw output: %s', [ARoute.Command, Cwd, Output]), ASourceID);
  finally
    Free;
  end;

  ABus.Publish('log.info', Format('http bus cli: %s %s (sub_path="%s", cwd=%s) -> %d bytes', [ARoute.Command, Path, SubPath, Cwd, Length(Output)]), ASourceID);
  Result := BuildBusCLIResponse(FirstLine, ARoute.ContentType, ATemplates, ABus, ARegistry, ASourceID);
end;

function RunBusDaemonRoute(const ARequest: string; const ARoute: TVDRX_CLIRoute;
  ATemplates: TVDRX_TemplateStore; ABus: TVDRX_MessageQueue; ARegistry: TVDRX_Registry; const ASourceID: string): string;
var
  Method, Path, SubPath, QueryString, HeaderBlock, Body, ReplyRaw: string;
  HeaderEnd: Integer;
  ReqObj: TJSONObject;
begin
  ParseRequestLine(ARequest, Method, Path);
  QueryString := ExtractQueryString(ARequest);
  HeaderEnd := Pos(#13#10#13#10, ARequest);
  if HeaderEnd > 0 then HeaderBlock := Copy(ARequest, 1, HeaderEnd - 1) else HeaderBlock := ARequest;
  Body := ExtractBody(ARequest);

  if Length(Path) >= Length(ARoute.Prefix) then
    SubPath := Copy(Path, Length(ARoute.Prefix) + 1, MaxInt)
  else
    SubPath := '';

  ReqObj := TJSONObject.Create;
  try
    ReqObj.Add('method', Method);
    ReqObj.Add('path', Path);
    ReqObj.Add('prefix', ARoute.Prefix);
    ReqObj.Add('sub_path', SubPath);
    ReqObj.Add('query', QueryString);
    ReqObj.Add('headers', HeadersToJSON(HeaderBlock));
    ReqObj.Add('body', Body);

    if not PublishAndWait(ARegistry, ABus, ARoute.InTopic, 'http.reply', ReqObj, ARoute.TimeoutMs, ASourceID, ReplyRaw) then
    begin
      ABus.Publish('log.error', Format('http bus-daemon: no subscriber on "%s" answered %s within %dms', [ARoute.InTopic, Path, ARoute.TimeoutMs]), ASourceID);
      Exit(PlainResponse('504 Gateway Timeout', 'text/plain', 'No daemon answered in time'));
    end;
  finally
    ReqObj.Free;
  end;

  ABus.Publish('log.info', Format('http bus-daemon: %s %s (in_topic=%s) -> %d bytes', [Method, Path, ARoute.InTopic, Length(ReplyRaw)]), ASourceID);
  Result := BuildBusCLIResponse(ReplyRaw, ARoute.ContentType, ATemplates, ABus, ARegistry, ASourceID);
end;

constructor TVDRX_HTTPExecutive.Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config; ATemplates: TVDRX_TemplateStore;
  const AStaticDir: string; const AProxyRoutes: TVDRX_ProxyRoutes; const ACLIRoutes: TVDRX_CLIRoutes;
  ARegistry: TVDRX_Registry);
begin
  inherited Create(ABus);
  FConfig := AConfig;
  FTemplates := ATemplates;
  FStaticDir := AStaticDir;
  FProxyRoutes := AProxyRoutes;
  FCLIRoutes := ACLIRoutes;
  FRegistry := ARegistry;
  FCustomHeaders := TStringList.Create;
  Port := 8081;
end;

destructor TVDRX_HTTPExecutive.Destroy;
begin
  FCustomHeaders.Free;
  inherited Destroy;
end;

class function TVDRX_HTTPExecutive.BuildResponse(const ARequest: string;
  ATemplates: TVDRX_TemplateStore; AConfig: TVDRX_Config; const AStaticDir: string;
  const AProxyRoutes: TVDRX_ProxyRoutes; const ACLIRoutes: TVDRX_CLIRoutes;
  ABus: TVDRX_MessageQueue; ARegistry: TVDRX_Registry; const ASourceID: string;
  ACustomHeaders: TStringList): string;
var
  Method, Path: string;
  Route: TVDRX_ProxyRoute;
  CLIRoute: TVDRX_CLIRoute;
begin
  ParseRequestLine(ARequest, Method, Path);

  // Fast-path CORS preflight probe
  if Method = 'OPTIONS' then
  begin
    ABus.Publish('log.info', Format('http: %s %s -> 204 No Content (preflight)', [Method, Path]), ASourceID);
    Exit(PlainResponse('204 No Content', 'text/plain', '', ACustomHeaders));
  end;

  if MatchProxyRoute(Path, AProxyRoutes, Route) then
  begin
    ABus.Publish('log.info', Format('http: %s %s -> proxy %s:%d', [Method, Path, Route.Host, Route.Port]), ASourceID);
    Exit(ProxyRequest(ARequest, Route, ABus, ASourceID));
  end;

  if MatchCLIRoute(Path, ACLIRoutes, CLIRoute) then
  begin
    if SameText(CLIRoute.Protocol, 'bus-daemon') then
    begin
      ABus.Publish('log.info', Format('http: %s %s -> bus-daemon %s', [Method, Path, CLIRoute.InTopic]), ASourceID);
      Exit(RunBusDaemonRoute(ARequest, CLIRoute, ATemplates, ABus, ARegistry, ASourceID));
    end
    else if SameText(CLIRoute.Protocol, 'bus') then
    begin
      ABus.Publish('log.info', Format('http: %s %s -> bus cli %s', [Method, Path, CLIRoute.Command]), ASourceID);
      Exit(RunBusCLIScript(ARequest, CLIRoute, ATemplates, ABus, ARegistry, ASourceID));
    end
    else
    begin
      ABus.Publish('log.info', Format('http: %s %s -> cli %s', [Method, Path, CLIRoute.Command]), ASourceID);
      Exit(RunCLIScript(ARequest, CLIRoute, ABus, ASourceID));
    end;
  end;

  if Method = 'GET' then
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
  const AProxyRoutes: TVDRX_ProxyRoutes; const ACLIRoutes: TVDRX_CLIRoutes;
  ARegistry: TVDRX_Registry; const ASourceID: string; ACustomHeaders: TStringList);
begin
  inherited Create(ABus);
  FTransport := ATransport;
  FTemplates := ATemplates;
  FConfig := AConfig;
  FStaticDir := AStaticDir;
  FProxyRoutes := AProxyRoutes;
  FCLIRoutes := ACLIRoutes;
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
begin
  if ARequest <> '' then
    Request := ARequest
  else
    Request := ReadFullRequest(FTransport);

  if Request <> '' then
  begin
    ParseRequestLine(Request, Method, Path);
    Response := TVDRX_HTTPExecutive.BuildResponse(Request, FTemplates, FConfig, FStaticDir,
      FProxyRoutes, FCLIRoutes, Bus, FRegistry, FSourceID, FCustomHeaders);
    Bus.Publish('log.info', Format('http: %s %s -> %s', [Method, Path, StatusOf(Response)]), FSourceID);
    FTransport.Write(Response[1], Length(Response));
  end
  else
    Bus.Publish('log.warn', 'http: connection closed before a request arrived', FSourceID);
  FTransport.Close;
end;

procedure TVDRX_HTTPExecutive.HandleConnection(ATransport: TVDRX_Transport);
var
  Conn: TVDRX_HTTPConnection;
begin
  Conn := TVDRX_HTTPConnection.Create(Bus, ATransport, FTemplates, FConfig, FStaticDir,
    FProxyRoutes, FCLIRoutes, FRegistry, ID, FCustomHeaders);
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
      FSendQueue.Add(Char(AOpcode) + APayload);
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
  i, Count: Integer;
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
        Count := FControlQueue.Count + FSendQueue.Count;
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

    if Count = 0 then
      Continue;
  end;
end;

{ TVDRX_WSProtocolExecutive }

constructor TVDRX_WSProtocolExecutive.Create(ABus: TVDRX_MessageQueue; AListener: TVDRX_WebSocketExecutive; AConn: TVDRX_WSConnection);
begin
  inherited Create(ABus);
  FListener := AListener;
  FConn := AConn;
  FAuthenticated := False;
end;

procedure TVDRX_WSProtocolExecutive.HandlePacket(const AMsg: TVDRX_Message);
var
  J: TJSONData;
  Obj: TJSONObject;
  PayloadData: TJSONData;
  Method, Topic, Payload, Token, Src: string;
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
      Src := Obj.Get('source', FConn.ID);
      FAuthenticated := Token <> '';
      if FAuthenticated then
        Bus.Publish('log.info', 'ws ' + FConn.ID + ': authenticated (stub - any nonempty token passes)', ID)
      else
        Bus.Publish('log.warn', 'ws ' + FConn.ID + ': sys.auth sent with an empty token, rejected', ID);
      Bus.Publish(FConn.ID + '.rpc.out', Format('{"event":"auth.ok","source":%s}', [JSONString(Src)]), ID);
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
  if FDefaultSubscribe <> '' then
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
  FStopping := False;
  FConnected := False;
end;

destructor TVDRX_SocketClientExecutive.Destroy;
begin
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
end;

procedure TVDRX_SocketClientExecutive.Shutdown;
begin
  FStopping := True;
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

procedure TVDRX_SocketClientExecutive.HandlePacket(const AMsg: TVDRX_Message);
var
  Transport: TVDRX_Transport;
  OutStr: string;
begin
  FTransportLock.Enter;
  Transport := FTransport;
  FTransportLock.Leave;
  if not Assigned(Transport) then Exit;

  if FFraming = 'chunk' then
    OutStr := AMsg.Payload
  else
    OutStr := AMsg.Payload + FDelimiter;

  if Length(OutStr) > 0 then
    Transport.Write(OutStr[1], Length(OutStr));
end;

initialization
  GReplyTopicLock := TCriticalSection.Create;

finalization
  GReplyTopicLock.Free;

end.
