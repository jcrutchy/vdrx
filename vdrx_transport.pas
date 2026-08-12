unit vdrx_transport;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Sockets, openssl, resolve
  {$IFDEF UNIX}, BaseUnix{$ENDIF};

type
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

end.
