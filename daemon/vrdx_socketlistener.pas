unit vrdx_socketlistener;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Sockets, vrdx_core, vrdx_transport;

type

  // Common accept-loop skeleton for every raw-socket listener executive (IRCD, HTTP,
  // WebSocket, and the combined HTTP/WS listener). Binds Port (plaintext) and/or
  // TLSPort (TLS, once ConfigureTLS is called with a loadable cert/key), accepts in
  // a loop on whichever are configured, and spawns one TVRDX_ListenerConnThread per
  // accepted connection which calls the descendant's HandleConnection with an
  // already-ready TVRDX_Transport. Descendants only implement HandleConnection -
  // accept-loop plumbing, socket lifecycle, TLS handshaking, and thread teardown all
  // live here, and descendants never need to know or care which transport they got.
  //
  // Extracted after the third near-identical accept loop (IRCD/WebSocket/HTTP)
  // started duplicating this exact code - see WIRING.md session notes. Widened to
  // dual plain+TLS listening in a later session (see WIRING.md) so a protocol can
  // be reachable either encrypted or not, client's choice, without the HTTP/WS/IRCD
  // layer needing separate encrypted/plaintext code paths of its own.
  TVRDX_SocketListenerExecutive = class(TVRDX_Executive)
  private
    FPort: Word;             // 0 = plaintext listener disabled
    FTLSPort: Word;          // 0 = TLS listener disabled
    FTLSCertFile: string;
    FTLSKeyFile: string;
    FTLSContext: TVRDX_TLSContext;
    FBacklog: Integer;
    FPlainSocket: TSocket;
    FTLSSocket: TSocket;
    FPlainThread: TThread;
    FTLSThread: TThread;
    FStopping: Boolean;
    function BindListenSocket(APort: Word): TSocket;
    procedure AcceptLoopPlain;
    procedure AcceptLoopTLS;
  protected
    // Called on its own dedicated thread per accepted connection - free to block.
    // ATransport is already Read/Write-ready (the TLS handshake, if any, is already
    // done by the time this is called). Implementations own it: read it, respond,
    // and Close+Free it themselves, or hand it off elsewhere (e.g. registering a
    // longer-lived executive that takes over the connection, as
    // TVRDX_WebSocketExecutive.AdoptConnection and TVRDX_IRCDExecutive's connection
    // hand-off do).
    procedure HandleConnection(ATransport: TVRDX_Transport); virtual; abstract;
  public
    constructor Create(ABus: TVRDX_MessageQueue); override;
    destructor Destroy; override;
    property Port: Word read FPort write FPort;
    property TLSPort: Word read FTLSPort;
    // True only once the TLS accept loop has actually started - i.e. tls_port was
    // configured AND the cert/key loaded successfully. False the whole time if TLS
    // was never configured, or if it was configured but failed to come up (bad
    // path, unloadable libssl, etc) - check this rather than TLSPort<>0 when
    // reporting status, since TLSPort alone only reflects what was *asked for*.
    function TLSActive: Boolean;
    // Call before Initialize. TLS only actually comes up if ATLSPort <> 0 AND the
    // cert/key load successfully - a bad path or unreadable file just leaves the
    // TLS side down (logged via HandlePacket's usual log.warn path, see
    // descendants), the plaintext listener (if any) is unaffected.
    procedure ConfigureTLS(ATLSPort: Word; const ACertFile, AKeyFile: string);
    property Backlog: Integer read FBacklog write FBacklog;
    property Stopping: Boolean read FStopping;
    procedure Initialize; override;
    procedure Shutdown; override;
  end;

implementation

type
  TVRDX_ListenerConnThread = class(TThread)
  private
    FOwner: TVRDX_SocketListenerExecutive;
    FTransport: TVRDX_Transport;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TVRDX_SocketListenerExecutive; ATransport: TVRDX_Transport);
  end;

constructor TVRDX_ListenerConnThread.Create(AOwner: TVRDX_SocketListenerExecutive; ATransport: TVRDX_Transport);
begin
  inherited Create(True);
  FOwner := AOwner;
  FTransport := ATransport;
  FreeOnTerminate := True; // fire-and-forget per-connection dispatch thread
end;

procedure TVRDX_ListenerConnThread.Execute;
begin
  FOwner.HandleConnection(FTransport);
end;

{ TVRDX_SocketListenerExecutive }

constructor TVRDX_SocketListenerExecutive.Create(ABus: TVRDX_MessageQueue);
begin
  inherited Create(ABus);
  FBacklog := 16;
end;

destructor TVRDX_SocketListenerExecutive.Destroy;
begin
  FTLSContext.Free;
  inherited Destroy;
end;

procedure TVRDX_SocketListenerExecutive.ConfigureTLS(ATLSPort: Word; const ACertFile, AKeyFile: string);
begin
  FTLSPort := ATLSPort;
  FTLSCertFile := ACertFile;
  FTLSKeyFile := AKeyFile;
end;

function TVRDX_SocketListenerExecutive.BindListenSocket(APort: Word): TSocket;
var
  Addr: TInetSockAddr;
  OptVal: LongInt;
begin
  Result := fpSocket(AF_INET, SOCK_STREAM, 0);
  OptVal := 1;
  fpSetSockOpt(Result, SOL_SOCKET, SO_REUSEADDR, @OptVal, SizeOf(OptVal)); // avoid "address in use" on a fast restart while the old socket's still in TIME_WAIT
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(APort);
  Addr.sin_addr.s_addr := 0;
  fpBind(Result, @Addr, SizeOf(Addr));
  fpListen(Result, FBacklog);
end;

procedure TVRDX_SocketListenerExecutive.AcceptLoopPlain;
var
  ClientAddr: TInetSockAddr;
  AddrLen: TSockLen;
  ClientSock: TSocket;
begin
  FPlainSocket := BindListenSocket(FPort);
  while not FStopping do
  begin
    AddrLen := SizeOf(ClientAddr);
    ClientSock := fpAccept(FPlainSocket, @ClientAddr, @AddrLen);
    if ClientSock = -1 then
      Continue;
    TVRDX_ListenerConnThread.Create(Self, TVRDX_PlainTransport.Create(ClientSock)).Start;
  end;
  CloseSocket(FPlainSocket);
end;

procedure TVRDX_SocketListenerExecutive.AcceptLoopTLS;
var
  ClientAddr: TInetSockAddr;
  AddrLen: TSockLen;
  ClientSock: TSocket;
  Transport: TVRDX_TLSTransport;
begin
  FTLSSocket := BindListenSocket(FTLSPort);
  while not FStopping do
  begin
    AddrLen := SizeOf(ClientAddr);
    ClientSock := fpAccept(FTLSSocket, @ClientAddr, @AddrLen);
    if ClientSock = -1 then
      Continue;
    // Handshake happens inside TVRDX_TLSTransport.Create, on this connection's own
    // thread (spawned below) - no, actually inline here first so we can bail out
    // before spawning a thread for a connection whose handshake never completes.
    Transport := TVRDX_TLSTransport.Create(ClientSock, FTLSContext.Ctx);
    if not Transport.Handshook then
    begin
      Transport.Free; // bad client, wrong protocol on this port, etc - just drop it
      Continue;
    end;
    TVRDX_ListenerConnThread.Create(Self, Transport).Start;
  end;
  CloseSocket(FTLSSocket);
end;

function TVRDX_SocketListenerExecutive.TLSActive: Boolean;
begin
  Result := Assigned(FTLSThread);
end;

procedure TVRDX_SocketListenerExecutive.Initialize;
begin
  FStopping := False;
  if FPort <> 0 then
  begin
    FPlainThread := TVRDX_WorkerThread.Create(@AcceptLoopPlain);
    FPlainThread.FreeOnTerminate := False;
    FPlainThread.Start;
  end;
  if FTLSPort <> 0 then
  begin
    FTLSContext := TVRDX_TLSContext.Create(FTLSCertFile, FTLSKeyFile);
    if not FTLSContext.OK then
    begin
      FTLSContext.Free;
      FTLSContext := nil; // cert/key didn't load - TLS side just stays down
    end
    else
    begin
      FTLSThread := TVRDX_WorkerThread.Create(@AcceptLoopTLS);
      FTLSThread.FreeOnTerminate := False;
      FTLSThread.Start;
    end;
  end;
end;

procedure TVRDX_SocketListenerExecutive.Shutdown;
begin
  FStopping := True;
  if FPlainSocket <> 0 then
    CloseSocket(FPlainSocket); // unblocks fpAccept in AcceptLoopPlain
  if FTLSSocket <> 0 then
    CloseSocket(FTLSSocket); // unblocks fpAccept in AcceptLoopTLS
  if Assigned(FPlainThread) then
  begin
    FPlainThread.WaitFor;
    FPlainThread.Free;
    FPlainThread := nil;
  end;
  if Assigned(FTLSThread) then
  begin
    FTLSThread.WaitFor;
    FTLSThread.Free;
    FTLSThread := nil;
  end;
  FTLSContext.Free;
  FTLSContext := nil;
  // NOTE: per-connection threads are FreeOnTerminate and not individually
  // tracked/joined here - same simplification flagged in the pre-refactor units.
  // A production Shutdown needs to track, signal, and join every live connection,
  // not just the accept loop(s).
end;

end.
