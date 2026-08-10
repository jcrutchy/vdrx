unit vdrx_socketlistener;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Sockets, SyncObjs, vdrx_core, vdrx_transport, vdrx_procutil;

type

  TVDRX_SocketListenerExecutive = class;

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

implementation

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
  fpBind(Result, @Addr, SizeOf(Addr));
  fpListen(Result, FBacklog);
end;

procedure TVDRX_SocketListenerExecutive.AcceptLoopPlain;
var
  ClientAddr: TInetSockAddr;
  AddrLen: TSockLen;
  ClientSock: TSocket;
  ConnThread: TVDRX_ListenerConnThread;
begin
  FPlainSocket := BindListenSocket(FPort);
  while not FStopping do
  begin
    AddrLen := SizeOf(ClientAddr);
    ClientSock := fpAccept(FPlainSocket, @ClientAddr, @AddrLen);
    if ClientSock = -1 then
      Continue;

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
  CloseSocket(FPlainSocket);
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
  while not FStopping do
  begin
    AddrLen := SizeOf(ClientAddr);
    ClientSock := fpAccept(FTLSSocket, @ClientAddr, @AddrLen);
    if ClientSock = -1 then
      Continue;

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
  CloseSocket(FTLSSocket);
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

  // 1. Unblock accept loops
  if FPlainSocket <> 0 then
    CloseSocket(FPlainSocket);
  if FTLSSocket <> 0 then
    CloseSocket(FTLSSocket);

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

end.