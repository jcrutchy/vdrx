unit vdrx_socketclient;

{$mode ObjFPC}{$H+}

// Outbound socket client executive: dials a remote host (optionally over TLS), splits its input into 
// lines under max_line_bytes and reconnects with backoff.

interface

uses
  Classes, SysUtils, StrUtils, Sockets, SyncObjs, openssl, {$IFDEF UNIX}BaseUnix, {$ENDIF} dynlibs, jsonparser, vdrx_core, vdrx_procutil, vdrx_linebuf, vdrx_transport, vdrx_connection;

type

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
    FMaxLineBytes: Integer;
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
    // Longest line accepted in "delimiter" framing; a peer that sends more without a
    // newline is disconnected (default 1 MiB, see vdrx_linebuf.pas).
    property MaxLineBytes: Integer read FMaxLineBytes write FMaxLineBytes;
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

implementation

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
  FMaxLineBytes := VDRX_DEFAULT_MAX_LINE_BYTES;
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
      // The chain checked out (SSL_VERIFY_PEER); now check the certificate is for THIS host, otherwise
      // any certificate issued by the same CA would let someone impersonate the server.
      if FTLSVerify and not TVDRX_TLSTransport(Transport).PeerCertMatches(PeerName) then
      begin
        Bus.Publish('log.warn', Format('%s: TLS certificate presented by %s:%d is not valid for the name "%s" - dropping the connection (use tls_peer_name if the server legitimately uses another name)',
          [ID, FHost, FPort, PeerName]), ID);
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
  Assembler: TVDRX_LineBuffer;
  Lines: TStringList;
  Transport: TVDRX_Transport;
  ChunkBuf: string;
begin
  Assembler := TVDRX_LineBuffer.Create(FMaxLineBytes);
  Lines := TStringList.Create;
  try
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
          Lines.Clear;
          if Assembler.Feed(Buf, Received, Lines) then
          begin
            // Deliver what was complete before the oversized line, then cut the connection:
            // a peer that will not send a newline is misbehaving or hostile, and reconnecting
            // (per the reconnect policy) gives it a clean slate.
            for i := 0 to Lines.Count - 1 do
              if Lines[i] <> '' then Bus.Publish(FPublishTopic, Lines[i], ID);
            Bus.Publish('log.warn', Format(
              'socket client %s: peer sent a line longer than max_line_bytes (%d) - disconnecting',
              [ID, Assembler.MaxLineBytes]), ID);
            FTransportLock.Enter;
            FConnected := False;
            FTransportLock.Leave;
            Break;
          end;
          for i := 0 to Lines.Count - 1 do
            if Lines[i] <> '' then
              Bus.Publish(FPublishTopic, Lines[i], ID);
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
  finally
    Lines.Free;
    Assembler.Free;
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

end.
