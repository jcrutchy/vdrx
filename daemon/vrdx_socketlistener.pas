unit vrdx_socketlistener;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Sockets, vrdx_core;

type

  // Common accept-loop skeleton for every raw-socket listener executive (IRCD, HTTP,
  // WebSocket, and the combined HTTP/WS listener). Binds Port, accepts in a loop, and
  // spawns one TVRDX_ListenerConnThread per accepted connection which calls the
  // descendant's HandleConnection. Descendants only implement HandleConnection -
  // accept-loop plumbing, socket lifecycle, and thread teardown all live here.
  //
  // Extracted after the third near-identical accept loop (IRCD/WebSocket/HTTP)
  // started duplicating this exact code - see WIRING.md session notes.
  TVRDX_SocketListenerExecutive = class(TVRDX_Executive)
  private
    FPort: Word;
    FBacklog: Integer;
    FListenSocket: TSocket;
    FAcceptThread: TThread;
    FStopping: Boolean;
    procedure AcceptLoop;
  protected
    // Called on its own dedicated thread per accepted connection - free to block.
    // Implementations own ASock: read it, respond, and CloseSocket it themselves,
    // or hand it off elsewhere (e.g. registering a longer-lived executive that takes
    // over the socket, as TVRDX_WebSocketExecutive.AdoptConnection does).
    procedure HandleConnection(ASock: TSocket); virtual; abstract;
  public
    constructor Create(ABus: TVRDX_MessageQueue); override;
    property Port: Word read FPort write FPort;
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
    FSock: TSocket;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TVRDX_SocketListenerExecutive; ASock: TSocket);
  end;

constructor TVRDX_ListenerConnThread.Create(AOwner: TVRDX_SocketListenerExecutive; ASock: TSocket);
begin
  inherited Create(True);
  FOwner := AOwner;
  FSock := ASock;
  FreeOnTerminate := True; // fire-and-forget per-connection dispatch thread
end;

procedure TVRDX_ListenerConnThread.Execute;
begin
  FOwner.HandleConnection(FSock);
end;

{ TVRDX_SocketListenerExecutive }

constructor TVRDX_SocketListenerExecutive.Create(ABus: TVRDX_MessageQueue);
begin
  inherited Create(ABus);
  FBacklog := 16;
end;

procedure TVRDX_SocketListenerExecutive.AcceptLoop;
var
  Addr, ClientAddr: TInetSockAddr;
  AddrLen: TSockLen;
  ClientSock: TSocket;
begin
  FListenSocket := fpSocket(AF_INET, SOCK_STREAM, 0);
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(FPort);
  Addr.sin_addr.s_addr := 0;
  fpBind(FListenSocket, @Addr, SizeOf(Addr));
  fpListen(FListenSocket, FBacklog);
  while not FStopping do
  begin
    AddrLen := SizeOf(ClientAddr);
    ClientSock := fpAccept(FListenSocket, @ClientAddr, @AddrLen);
    if ClientSock = -1 then
      Continue;
    TVRDX_ListenerConnThread.Create(Self, ClientSock).Start;
  end;
  CloseSocket(FListenSocket);
end;

procedure TVRDX_SocketListenerExecutive.Initialize;
begin
  FStopping := False;
  FAcceptThread := TVRDX_WorkerThread.Create(@AcceptLoop);
  FAcceptThread.FreeOnTerminate := False;
  FAcceptThread.Start;
end;

procedure TVRDX_SocketListenerExecutive.Shutdown;
begin
  FStopping := True;
  if FListenSocket <> 0 then
    CloseSocket(FListenSocket); // unblocks fpAccept in AcceptLoop
  if Assigned(FAcceptThread) then
  begin
    FAcceptThread.WaitFor;
    FAcceptThread.Free;
    FAcceptThread := nil;
  end;
  // NOTE: per-connection threads are FreeOnTerminate and not individually
  // tracked/joined here - same simplification flagged in the pre-refactor units.
  // A production Shutdown needs to track, signal, and join every live connection,
  // not just the accept loop.
end;

end.
