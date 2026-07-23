unit vrdx_transport;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Sockets, openssl;

type
  // Byte-stream abstraction over an accepted connection - lets every protocol
  // executive (HTTP, WebSocket, IRCD) do its reads/writes without caring whether
  // the underlying socket is plaintext or TLS. Deliberately mirrors fpRecv/fpSend's
  // blocking, synchronous style - no event-loop rewrite needed anywhere else; every
  // existing "one thread per connection" executive keeps working exactly as before,
  // just talking to ATransport instead of a raw TSocket.
  TVRDX_Transport = class
  public
    function Read(var ABuf; ALen: Integer): Integer; virtual; abstract;
    function Write(const ABuf; ALen: Integer): Integer; virtual; abstract;
    procedure Close; virtual; abstract;
  end;

  TVRDX_PlainTransport = class(TVRDX_Transport)
  private
    FSocket: TSocket;
  public
    constructor Create(ASocket: TSocket);
    function Read(var ABuf; ALen: Integer): Integer; override;
    function Write(const ABuf; ALen: Integer): Integer; override;
    procedure Close; override;
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
  TVRDX_TLSTransport = class(TVRDX_Transport)
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
  end;

  // One per TLS-enabled listener - loads the cert/key once at Initialize time and
  // hands out the resulting context for TVRDX_TLSTransport to wrap each accepted
  // connection in. Deliberately doesn't crash the daemon if the cert/key don't load
  // - check .OK and skip bringing the TLS listener up if false.
  TVRDX_TLSContext = class
  private
    FCtx: PSSL_CTX;
    FOK: Boolean;
  public
    constructor Create(const ACertFile, AKeyFile: string);
    destructor Destroy; override;
    property OK: Boolean read FOK;
    property Ctx: PSSL_CTX read FCtx;
  end;

implementation

{ TVRDX_PlainTransport }

constructor TVRDX_PlainTransport.Create(ASocket: TSocket);
begin
  inherited Create;
  FSocket := ASocket;
end;

function TVRDX_PlainTransport.Read(var ABuf; ALen: Integer): Integer;
begin
  Result := fpRecv(FSocket, @ABuf, ALen, 0);
end;

function TVRDX_PlainTransport.Write(const ABuf; ALen: Integer): Integer;
begin
  Result := fpSend(FSocket, @ABuf, ALen, 0);
end;

procedure TVRDX_PlainTransport.Close;
begin
  CloseSocket(FSocket);
end;

{ TVRDX_TLSTransport }

constructor TVRDX_TLSTransport.Create(ASocket: TSocket; ACtx: PSSL_CTX);
begin
  inherited Create;
  FSocket := ASocket;
  FSSL := SslNew(ACtx);
  SslSetFd(FSSL, FSocket);
  FOK := Assigned(FSSL) and (SslAccept(FSSL) = 1); // blocking - fine, runs on this connection's own thread
end;

destructor TVRDX_TLSTransport.Destroy;
begin
  if Assigned(FSSL) then
    SslFree(FSSL);
  inherited Destroy;
end;

function TVRDX_TLSTransport.Read(var ABuf; ALen: Integer): Integer;
begin
  if not FOK then Exit(-1);
  Result := SslRead(FSSL, @ABuf, ALen);
end;

function TVRDX_TLSTransport.Write(const ABuf; ALen: Integer): Integer;
begin
  if not FOK then Exit(-1);
  Result := SslWrite(FSSL, @ABuf, ALen);
end;

procedure TVRDX_TLSTransport.Close;
begin
  if Assigned(FSSL) then
    SslShutdown(FSSL);
  FOK := False;
  CloseSocket(FSocket);
end;

{ TVRDX_TLSContext }

constructor TVRDX_TLSContext.Create(const ACertFile, AKeyFile: string);
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

destructor TVRDX_TLSContext.Destroy;
begin
  if Assigned(FCtx) then
    SslCtxFree(FCtx);
  inherited Destroy;
end;

end.
