unit vdrx_transport;

{$mode ObjFPC}{$H+}

// Byte-stream transports: plain TCP and TLS (OpenSSL), outbound connects, socket options and OpenSSL 
// discovery.

interface

uses
  SysUtils, Sockets, openssl, resolve, {$IFDEF UNIX}BaseUnix, {$ENDIF} dynlibs, vdrx_core, vdrx_config;

type

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
    // True if the certificate the peer presented is valid for AName (a DNS name, or an IP address).
    // SSL_VERIFY_PEER alone only proves the chain leads to a trusted CA - it says nothing about WHICH
    // host the certificate was issued to, so without this any certificate from the same CA would do.
    function PeerCertMatches(const AName: string): Boolean;
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

const
  TLS_HANDSHAKE_TIMEOUT_MS = 5000;

function ConnectTCP(const AHost: string; APort: Word): TVDRX_Transport;
function ConnectTCPHost(const AHost: string; APort: Word): TVDRX_Transport;
procedure ApplyOpenSSLDLLOverrides(AConfig: TVDRX_Config);

// Makes sure FPC's OpenSSL binding has found a library, looking for the versioned libssl.so.3 /
// .1.1 when the plain libssl.so (a -dev package file) is missing. True = TLS can work.
// VDRX_OpenSSLNote says what was done or why it failed (empty if nothing special).
function VDRX_EnsureOpenSSL: Boolean;
function VDRX_OpenSSLNote: string;

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

function ConnectRawSocket(const AHost: string; APort: Word; out ASocket: TSocket): Boolean;

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

// Reads exactly ACount bytes. TCP is a byte stream: a 2-byte header may arrive
// as 1 + 1, so a single short Read is normal and is not an error. False on EOF,
// error or timeout.
function ReadExact(ATransport: TVDRX_Transport; var ABuf; ACount: Integer): Boolean;

implementation

// Reads exactly ACount bytes. TCP is a byte stream: a 2-byte header may arrive
// as 1 + 1, so a single short Read is normal and is not an error. False on EOF,
// error or timeout.
function ReadExact(ATransport: TVDRX_Transport; var ABuf; ACount: Integer): Boolean;
var
  P: PByte;
  Got, N: Integer;
begin
  Result := False;
  P := @ABuf;
  Got := 0;
  while Got < ACount do
  begin
    N := ATransport.Read((P + Got)^, ACount - Got);
    if N <= 0 then Exit;
    Inc(Got, N);
  end;
  Result := True;
end;


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

// FPC's OpenSSL binding builds the library file name itself: it takes DLLSSLName ("libssl") and
// appends ".so". Distributions install the runtime library only under its VERSIONED name
// (libssl.so.3, libssl.so.1.1); the plain "libssl.so" comes with the -dev package. So on a normal
// server the binding finds nothing and TLS silently never starts. VDRX_EnsureOpenSSL fixes that
// without asking anyone to install -dev packages.
var
  OpenSSLChecked: Boolean = False;
  OpenSSLReady: Boolean = False;
  OpenSSLConfigured: Boolean = False;     // tls_ssl_dll / tls_crypto_dll given: use exactly that, never guess
  OpenSSLNote: string = '';
  OpenSSLLock: TRTLCriticalSection;

function VDRX_OpenSSLNote: string;
begin
  Result := OpenSSLNote;
end;

procedure ApplyOpenSSLDLLOverrides(AConfig: TVDRX_Config);
var
  SSLDll, CryptoDll: string;
begin
  // tls_ssl_dll / tls_crypto_dll: the binding's library names (Windows: the DLL file names; Unix:
  // a path WITHOUT the ".so", which the binding appends).
  SSLDll := AConfig.GetString('tls_ssl_dll', '');
  CryptoDll := AConfig.GetString('tls_crypto_dll', '');
  if SSLDll <> '' then DLLSSLName := SSLDll;
  if CryptoDll <> '' then DLLUtilName := CryptoDll;
  OpenSSLConfigured := (SSLDll <> '') or (CryptoDll <> '');
end;

{$IFDEF UNIX}
// Full path of a shared library that is already loaded in this process, found through
// /proc/self/maps (Linux). ASoname is e.g. 'libssl.so.3'; the mapped file may carry a longer version.
function LoadedLibraryPath(const ASoname: string): string;
var
  F: TextFile;
  Line, Path: string;
  p: Integer;
begin
  Result := '';
  AssignFile(F, '/proc/self/maps');
  {$I-} Reset(F); {$I+}
  if IOResult <> 0 then Exit;
  try
    while not Eof(F) do
    begin
      ReadLn(F, Line);
      p := Pos('/', Line);
      if p = 0 then Continue;
      Path := Copy(Line, p, MaxInt);
      if Pos(ASoname, ExtractFileName(Path)) = 1 then Exit(Path);
    end;
  finally
    CloseFile(F);
  end;
end;

// A fresh directory that only this user can enter. CreateDir fails if the name is taken, so a
// directory somebody else made in advance is never reused.
function MakePrivateDir: string;
var
  Buf: array[0..7] of Byte;
  F: file;
  i: Integer;
  Dir, Hex: string;
  St: Stat;
begin
  Result := '';
  FillChar(Buf, SizeOf(Buf), 0);
  AssignFile(F, '/dev/urandom');
  {$I-} Reset(F, 1); {$I+}
  if IOResult = 0 then
  begin
    BlockRead(F, Buf, SizeOf(Buf));
    CloseFile(F);
  end
  else
    for i := 0 to 7 do Buf[i] := Random(256) xor Byte(GetTickCount64 shr i);
  Hex := '';
  for i := 0 to 7 do Hex := Hex + LowerCase(IntToHex(Buf[i], 2));
  Dir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'vdrx-ssl-' + Hex;
  if not CreateDir(Dir) then Exit;
  fpChmod(PChar(Dir), &700);
  if (fpLstat(PChar(Dir), St) <> 0) or (not fpS_ISDIR(St.st_mode)) or (St.st_uid <> fpGeteuid) or ((St.st_mode and &777) <> &700) then
  begin
    RemoveDir(Dir);
    Exit;
  end;
  Result := Dir;
end;

function TryVersionedOpenSSL(const ASSLSoname, ACryptoSoname: string): Boolean;
var
  SSLPath, CryptoPath, Dir: string;
  H1, H2: TLibHandle;
begin
  Result := False;
  H1 := LoadLibrary(ASSLSoname);
  H2 := LoadLibrary(ACryptoSoname);
  if (H1 = NilHandle) or (H2 = NilHandle) then Exit;
  SSLPath := LoadedLibraryPath(ASSLSoname);
  CryptoPath := LoadedLibraryPath(ACryptoSoname);
  if (SSLPath = '') or (CryptoPath = '') then Exit;
  Dir := MakePrivateDir;
  if Dir = '' then Exit;
  try
    if (fpSymlink(PChar(SSLPath), PChar(Dir + '/libssl.so')) = 0) and
       (fpSymlink(PChar(CryptoPath), PChar(Dir + '/libcrypto.so')) = 0) then
    begin
      DLLSSLName := Dir + '/libssl';
      DLLUtilName := Dir + '/libcrypto';
      Result := InitSSLInterface;      // loads both; they stay loaded after the links are gone
    end;
  finally
    fpUnlink(PChar(Dir + '/libssl.so'));
    fpUnlink(PChar(Dir + '/libcrypto.so'));
    RemoveDir(Dir);
  end;
end;
{$ENDIF}

// Makes sure the OpenSSL binding has found a library. Cheap after the first call. Only TLS needs
// it, so it runs when the first TLS context is created, not at startup.
function VDRX_EnsureOpenSSL: Boolean;
{$IFDEF UNIX}
const
  Pairs: array[0..3, 0..1] of string = (('libssl.so.3', 'libcrypto.so.3'), ('libssl.so.1.1', 'libcrypto.so.1.1'),
    ('libssl.so.1.0.2', 'libcrypto.so.1.0.2'), ('libssl.so.1.0.0', 'libcrypto.so.1.0.0'));
var
  i: Integer;
  SavedSSL, SavedCrypto: string;
{$ENDIF}
begin
  EnterCriticalSection(OpenSSLLock);
  try
  if OpenSSLChecked then Exit(OpenSSLReady);
  OpenSSLChecked := True;
  OpenSSLReady := InitSSLInterface;        // works as is: a configured name, or the -dev package's libssl.so
  if (not OpenSSLReady) and OpenSSLConfigured then
    OpenSSLNote := 'tls_ssl_dll / tls_crypto_dll are set but OpenSSL could not be loaded from them (on Unix give the path WITHOUT ".so")';
  {$IFDEF UNIX}
  if (not OpenSSLReady) and (not OpenSSLConfigured) then
  begin
    SavedSSL := DLLSSLName;
    SavedCrypto := DLLUtilName;
    for i := Low(Pairs) to High(Pairs) do
      if TryVersionedOpenSSL(Pairs[i, 0], Pairs[i, 1]) then
      begin
        OpenSSLReady := True;
        OpenSSLNote := 'libssl.so is not installed (it belongs to the libssl-dev package); using ' + Pairs[i, 0] + ' instead';
        Break;
      end;
    if not OpenSSLReady then
    begin
      DLLSSLName := SavedSSL;
      DLLUtilName := SavedCrypto;
      OpenSSLNote := 'no usable OpenSSL library found (looked for libssl.so and libssl.so.3 / .1.1 / .1.0.2 / .1.0.0); install the OpenSSL runtime or set tls_ssl_dll / tls_crypto_dll';
    end;
  end;
  {$ENDIF}
  Result := OpenSSLReady;
  finally
    LeaveCriticalSection(OpenSSLLock);
  end;
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
  // close() alone does not wake another thread that is blocked in recv()/send() on this socket (on
  // Linux it stays blocked), so a connection whose peer stopped reading could never be evicted.
  // shutdown() does wake it.
  {$IFDEF UNIX}fpShutdown(FSocket, 2);{$ENDIF}
  CloseSocket(FSocket);
end;

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

function TVDRX_TLSTransport.PeerCertMatches(const AName: string): Boolean;
type
  TCheckHost = function(x: PX509; name: PAnsiChar; namelen: PtrUInt; flags: LongWord; peername: Pointer): LongInt; cdecl;
  TCheckIP = function(x: PX509; ipasc: PAnsiChar; flags: LongWord): LongInt; cdecl;
  TGetPeerCert = function(ssl: PSSL): PX509; cdecl;
var
  Cert: PX509;
  P, G: Pointer;
  IsIP: Boolean;
  i: Integer;
begin
  Result := False;
  if (not FOK) or (not Assigned(FSSL)) or (AName = '') then Exit;
  IsIP := Pos(':', AName) > 0;
  if not IsIP then
  begin
    IsIP := True;
    for i := 1 to Length(AName) do
      if not (AName[i] in ['0'..'9', '.']) then IsIP := False;
  end;
  if IsIP then P := GetProcedureAddress(SSLUtilHandle, 'X509_check_ip_asc')
  else P := GetProcedureAddress(SSLUtilHandle, 'X509_check_host');
  if P = nil then Exit;   // libcrypto older than 1.0.2 cannot check names: do not trust, fail closed
  // OpenSSL 3 turned SSL_get_peer_certificate into a macro for SSL_get1_peer_certificate, so FPC's binding
  // (which looks up the old name) finds nothing there: ask libssl for whichever of the two it has.
  G := GetProcedureAddress(SSLLibHandle, 'SSL_get1_peer_certificate');
  if G = nil then G := GetProcedureAddress(SSLLibHandle, 'SSL_get_peer_certificate');
  if G = nil then Exit;
  Cert := TGetPeerCert(G)(FSSL);
  if Cert = nil then Exit;
  try
    if IsIP then Result := TCheckIP(P)(Cert, PAnsiChar(AName), 0) = 1
    else Result := TCheckHost(P)(Cert, PAnsiChar(AName), Length(AName), 0, nil) = 1;
  finally
    X509Free(Cert);
  end;
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
  {$IFDEF UNIX}fpShutdown(FSocket, 2);{$ENDIF}
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
  VDRX_EnsureOpenSSL;
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
  VDRX_EnsureOpenSSL;
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

initialization
  InitCriticalSection(OpenSSLLock);

finalization
  DoneCriticalSection(OpenSSLLock);

end.
