unit vdrx_connection;

{$mode ObjFPC}{$H+}

// Shared base classes for executives that own sockets: per-connection executives and the 
// listening-socket executive with its accept loop and connection limits.

interface

uses
  Classes, SysUtils, StrUtils, Sockets, SyncObjs, {$IFDEF UNIX}BaseUnix, {$ENDIF} dynlibs, vdrx_core, vdrx_procutil, vdrx_transport, vdrx_iplimit;

type

  TVDRX_SocketListenerExecutive = class;

  // Facts about the connection a request arrived on (CGI wants REMOTE_ADDR etc.)
  TVDRX_ConnInfo = record
    RemoteAddr: string;
    RemotePort: Word;
    ServerPort: Word;
    Secure: Boolean;
  end;

  TVDRX_ListenerConnThread = class(TThread)
  private
    FOwner: TVDRX_SocketListenerExecutive;
    FTransport: TVDRX_Transport;
    // TLS: the accepted socket whose handshake THIS thread performs (nil
    // transport until it is done). Doing it here instead of in the accept loop
    // means a client that stalls mid-handshake only stalls itself.
    FPendingSock: TSocket;
    FPendingAddr: string;
    FPendingPort: Word;
    FLimitAddr: string;
  protected
    procedure Execute; override;
  public
    // The address whose per-IP slot (and the listener's global slot) this connection holds;
    // handed back when the thread ends.
    property LimitAddr: string read FLimitAddr write FLimitAddr;
    constructor Create(AOwner: TVDRX_SocketListenerExecutive; ATransport: TVDRX_Transport);
    constructor CreateTLS(AOwner: TVDRX_SocketListenerExecutive; ASock: TSocket;
      const APeerAddr: string; APeerPort: Word);
    // nil while a TLS handshake is still in progress
    property Transport: TVDRX_Transport read FTransport;
  end;

  TVDRX_SocketListenerExecutive = class(TVDRX_Executive)
  private
    FPort: Word;
    FTLSPort: Word;
    FTLSCertFile: string;
    FTLSKeyFile: string;
    FTLSPolicy: TVDRX_TLSPolicy;
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
    FLastRejectLog: QWord;
    FRejectedSinceLog: array[0..2] of Integer;   // global cap, per-IP concurrent cap, per-IP rate
    FLastRejectAddr: string;
    FOpenConns: LongInt;                         // reserved at accept time, released when the thread ends
    FLimiter: TVDRX_IPLimiter;

    function BindListenSocket(APort: Word): TSocket;
    function CompleteTLSHandshake(ASock: TSocket; const APeerAddr: string; APeerPort: Word): TVDRX_Transport;
    function TryReserve(const AAddr: string): Boolean;
    procedure AcceptLoopPlain;
    procedure AcceptLoopTLS;
    function WaitConnGone(AThread: TVDRX_ListenerConnThread; ATimeoutMs: Integer): Boolean;
  protected
    FMaxConnections: Integer;
    procedure NoteRejected(AReason: Integer; const AAddr: string);
    procedure ReleaseSlot(const AAddr: string);
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
    // Protocol versions and ciphers this listener's TLS port will accept (default: TVDRX_TLSPolicy's).
    procedure ConfigureTLSPolicy(const APolicy: TVDRX_TLSPolicy);
    property Backlog: Integer read FBacklog write FBacklog;
    // Interface the listener binds to. Default 127.0.0.1 (loopback only);
    // '0.0.0.0' = every interface, or the address of one specific interface.
    property BindAddress: string read FBindAddress write FBindAddress;
    // Concurrent connections this listener will serve; more are closed at
    // once. 0 = unlimited (not recommended).
    property MaxConnections: Integer read FMaxConnections write FMaxConnections;
    // Per-address limits (concurrent connections, new-connection rate, exempt ranges). Configured by the
    // owner of the listener; defaults are in TVDRX_IPLimiter.
    property Limiter: TVDRX_IPLimiter read FLimiter;
    property Stopping: Boolean read FStopping;
    property GracefulTimeoutMs: Integer read FGracefulTimeoutMs write FGracefulTimeoutMs;
    procedure Initialize; override;
    procedure Shutdown; override;
  end;

  TVDRX_ConnectionExecutive = class(TVDRX_Executive)
  protected
    FTransport: TVDRX_Transport;
  public
    destructor Destroy; override;
  end;

implementation

constructor TVDRX_ListenerConnThread.Create(AOwner: TVDRX_SocketListenerExecutive; ATransport: TVDRX_Transport);
begin
  inherited Create(True);
  FOwner := AOwner;
  FTransport := ATransport;
  FPendingSock := -1;
  FreeOnTerminate := False;
end;

constructor TVDRX_ListenerConnThread.CreateTLS(AOwner: TVDRX_SocketListenerExecutive; ASock: TSocket;
  const APeerAddr: string; APeerPort: Word);
begin
  inherited Create(True);
  FOwner := AOwner;
  FTransport := nil;
  FPendingSock := ASock;
  FPendingAddr := APeerAddr;
  FPendingPort := APeerPort;
  FreeOnTerminate := False;
end;

procedure TVDRX_ListenerConnThread.Execute;
var
  T: TVDRX_Transport;
begin
  // Registered first, so a connection that is still handshaking already counts
  // against max_connections and is waited for at shutdown.
  FOwner.RegisterConnection(Self);
  try
    try
      if FPendingSock <> -1 then
      begin
        T := FOwner.CompleteTLSHandshake(FPendingSock, FPendingAddr, FPendingPort);
        FPendingSock := -1;
        FTransport := T;               // nil = handshake failed or timed out (socket already closed)
      end;
      if FTransport <> nil then
      begin
        if FOwner.Stopping then
          FTransport.Free
        else
          FOwner.HandleConnection(FTransport);
      end;
    except
    end;
  finally
    FOwner.UnregisterConnection(Self);
    FOwner.ReleaseSlot(FLimitAddr);
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
  FTLSPolicy := VDRX_DefaultTLSPolicy;
  FMaxConnections := 256;
  FCriticalSection := TCriticalSection.Create;
  FActiveConnections := TList.Create;
  FLimiter := TVDRX_IPLimiter.Create;
end;

destructor TVDRX_SocketListenerExecutive.Destroy;
begin
  FLimiter.Free;
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

procedure TVDRX_SocketListenerExecutive.ConfigureTLSPolicy(const APolicy: TVDRX_TLSPolicy);
begin
  FTLSPolicy := APolicy;
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

// Reserves a connection slot at ACCEPT time. (Counting only when the connection thread starts, as this
// used to, let a burst of connections overshoot max_connections: threads register after the accept loop
// has already moved on.) Order matters: the cheap global cap first, so a refused connection never
// spends a token from the address's rate bucket.
function TVDRX_SocketListenerExecutive.TryReserve(const AAddr: string): Boolean;
var
  V: TVDRX_LimitVerdict;
begin
  Result := False;
  if (FMaxConnections > 0) and (InterlockedIncrement(FOpenConns) > FMaxConnections) then
  begin
    InterlockedDecrement(FOpenConns);
    NoteRejected(0, AAddr);
    Exit;
  end;
  if FMaxConnections <= 0 then InterlockedIncrement(FOpenConns);
  V := FLimiter.TryAcquire(AAddr);
  if V <> lvOK then
  begin
    InterlockedDecrement(FOpenConns);
    if V = lvTooManyConns then NoteRejected(1, AAddr) else NoteRejected(2, AAddr);
    Exit;
  end;
  Result := True;
end;

procedure TVDRX_SocketListenerExecutive.ReleaseSlot(const AAddr: string);
begin
  FLimiter.Release(AAddr);
  InterlockedDecrement(FOpenConns);
end;

// Logs at most once every 10 s (with counts) so a flood of refused
// connections cannot also flood the log. The address is the last one refused; it comes from
// NetAddrToStr, so it cannot carry control characters.
procedure TVDRX_SocketListenerExecutive.NoteRejected(AReason: Integer; const AAddr: string);
var
  Now: QWord;
  C: array[0..2] of Integer;
  DoLog: Boolean;
  LastAddr: string;
begin
  DoLog := False;
  FillChar(C, SizeOf(C), 0);
  LastAddr := '';
  FCriticalSection.Acquire;
  try
    Inc(FRejectedSinceLog[AReason]);
    FLastRejectAddr := AAddr;
    Now := GetTickCount64;
    if (FLastRejectLog = 0) or (Now - FLastRejectLog >= 10000) then
    begin
      DoLog := True;
      C[0] := FRejectedSinceLog[0]; C[1] := FRejectedSinceLog[1]; C[2] := FRejectedSinceLog[2];
      LastAddr := FLastRejectAddr;
      FLastRejectLog := Now;
      FillChar(FRejectedSinceLog, SizeOf(FRejectedSinceLog), 0);
    end;
  finally
    FCriticalSection.Release;
  end;
  if DoLog then
    Bus.Publish('log.warn', ID + ': refused connections - ' + IntToStr(C[0]) + ' over max_connections (' +
      IntToStr(FMaxConnections) + '), ' + IntToStr(C[1]) + ' over max_connections_per_ip (' +
      IntToStr(FLimiter.MaxPerIP) + '), ' + IntToStr(C[2]) + ' over connection_rate_per_ip (' +
      FloatToStr(FLimiter.RatePerSec) + '/s); most recent: ' + LastAddr, ID);
end;

procedure TVDRX_SocketListenerExecutive.AcceptLoopPlain;
var
  ClientAddr: TInetSockAddr;
  AddrLen: TSockLen;
  ClientSock: TSocket;
  ConnThread: TVDRX_ListenerConnThread;
  PlainT: TVDRX_PlainTransport;
  PeerStr: string;
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

    PeerStr := NetAddrToStr(ClientAddr.sin_addr);
    if not TryReserve(PeerStr) then
    begin
      CloseSocket(ClientSock);
      Continue;
    end;

    FCriticalSection.Acquire;
    try
      if FStopping then
      begin
        CloseSocket(ClientSock);
        ReleaseSlot(PeerStr);
        Break;
      end;
      PlainT := TVDRX_PlainTransport.Create(ClientSock);
      PlainT.PeerAddr := PeerStr;
      PlainT.PeerPort := ntohs(ClientAddr.sin_port);
      ConnThread := TVDRX_ListenerConnThread.Create(Self, PlainT);
      ConnThread.LimitAddr := PeerStr;
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

function TVDRX_SocketListenerExecutive.CompleteTLSHandshake(ASock: TSocket; const APeerAddr: string;
  APeerPort: Word): TVDRX_Transport;
var
  T: TVDRX_TLSTransport;
begin
  Result := nil;
  // Bound the handshake itself (see SetRawSocketReadTimeout's comment);
  // restored to unlimited once it has actually completed.
  SetRawSocketReadTimeout(ASock, TLS_HANDSHAKE_TIMEOUT_MS);
  T := TVDRX_TLSTransport.Create(ASock, FTLSContext.Ctx);
  if not T.Handshook then
  begin
    T.Free;
    Exit;
  end;
  T.SetReadTimeout(0);
  T.PeerAddr := APeerAddr;
  T.PeerPort := APeerPort;
  T.Secure := True;
  Result := T;
end;

procedure TVDRX_SocketListenerExecutive.AcceptLoopTLS;
var
  ClientAddr: TInetSockAddr;
  AddrLen: TSockLen;
  ClientSock: TSocket;
  ConnThread: TVDRX_ListenerConnThread;
  PeerStr: string;
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

    PeerStr := NetAddrToStr(ClientAddr.sin_addr);
    if not TryReserve(PeerStr) then
    begin
      CloseSocket(ClientSock);
      Continue;
    end;

    // The handshake is NOT done here: this loop must get straight back to
    // accept(). The connection thread performs it (see TVDRX_ListenerConnThread).
    FCriticalSection.Acquire;
    try
      if FStopping then
      begin
        CloseSocket(ClientSock);
        ReleaseSlot(PeerStr);
        Break;
      end;
      ConnThread := TVDRX_ListenerConnThread.CreateTLS(Self, ClientSock,
        PeerStr, ntohs(ClientAddr.sin_port));
      ConnThread.LimitAddr := PeerStr;
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
      Bus.Publish('log.error', ID + ': TLS port ' + IntToStr(FTLSPort) + ' NOT started - could not load certificate "' +
        FTLSCertFile + '" / key "' + FTLSKeyFile + '", or OpenSSL could not be loaded' +
        IfThen(VDRX_OpenSSLNote <> '', ' (' + VDRX_OpenSSLNote + ')', ''), ID);
    end
    else if not FTLSContext.ApplyPolicy(FTLSPolicy) then
    begin
      // Never serve TLS with a policy that could not be enforced.
      Bus.Publish('log.error', ID + ': TLS port ' + IntToStr(FTLSPort) + ' NOT started - ' +
        FTLSContext.PolicyNote, ID);
      FTLSContext.Free;
      FTLSContext := nil;
    end
    else
    begin
      if VDRX_OpenSSLNote <> '' then Bus.Publish('log.info', ID + ': ' + VDRX_OpenSSLNote, ID);
      Bus.Publish('log.info', ID + ': TLS port ' + IntToStr(FTLSPort) + ' - ' + FTLSContext.PolicyNote, ID);
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
        try
          if ConnThread.Transport <> nil then ConnThread.Transport.Close;
        except
        end;
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

destructor TVDRX_ConnectionExecutive.Destroy;
begin
  if Assigned(FTransport) then
    FTransport.Free;
  inherited Destroy;
end;

{ TVDRX_WSConnection }

end.
