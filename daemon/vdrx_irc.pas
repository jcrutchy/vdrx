unit vdrx_irc;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Sockets, SyncObjs, StrUtils, fpjson, jsonparser,
  vdrx_core, vdrx_socketlistener, vdrx_transport, vdrx_config;

type
  TVDRX_IRCDExecutive = class;

  // One instance per live HexChat/IRC connection. Talks to FTransport rather than a
  // raw socket, so it works identically whether the client connected plain (6667)
  // or TLS/ircs (6697 by convention) - see TVDRX_SocketListenerExecutive and
  // vdrx_transport.pas. Each connection is a proper registered TVDRX_Executive
  // (same pattern as TVDRX_WSConnection) - that's what lets channel members
  // actually see each other: JOIN/PART/QUIT/PRIVMSG all go out onto the bus under
  // 'irc.<channel>.event', every other connection subscribed to that channel's
  // filter gets HandlePacket called, and relays the line to its own connection. No
  // direct socket-to-socket fan-out anywhere - it's all ordinary bus routing.
  TVDRX_IRCConnection = class(TVDRX_Executive)
  private
    FListener: TVDRX_IRCDExecutive;
    FTransport: TVDRX_Transport;
    FThread: TThread;
    FSendLock: TCriticalSection; // SendLine is called from both this connection's own
                                  // read thread AND HandlePacket (on the Kernel's
                                  // dispatch thread whenever a channel event arrives) -
                                  // without this, concurrent writes to the same
                                  // socket/SSL object interleave and corrupt the
                                  // stream. See vdrx_websocket.pas's FSendLock for the
                                  // same fix, already in place there.
    FNick: string;
    FUser: string;
    FRealname: string;
    FRegistered: Boolean; // NICK + USER both seen, welcome burst sent
    FChannels: TStringList; // channels this connection has JOINed, as typed (e.g. '#general')
    FAwaitingPong: Boolean;
    FLastPingSent: TDateTime;
    FLastActivity: TDateTime;
    function HostMask: string;
    procedure SendLine(const S: string);
    procedure SendNumeric(const ANumeric, AParams: string);
    procedure HandleLine(const ALine: string);
    procedure MaybeCompleteRegistration;
    procedure SendWelcomeBurst;
    procedure SendMotd;
    procedure DoJoin(const AChannel: string);
    procedure DoPart(const AChannel, AReason: string);
    procedure DoPrivMsg(const ATarget, AText: string);
    procedure DoTopic(const AChannel, ANewTopic: string; AHasNewTopic: Boolean);
    procedure DoQuitAllChannels(const AReason: string);
    procedure SendNames(const AChannel: string);
  public
    constructor Create(ABus: TVDRX_MessageQueue; AListener: TVDRX_IRCDExecutive; ATransport: TVDRX_Transport);
    destructor Destroy; override;
    property Nick: string read FNick;
    procedure Initialize; override;
    procedure Shutdown; override;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    procedure RunLoop; // public: called from TIRCConnThread below
  end;

  // IRCD, not an IRC client - VDRX binds 6667 (and optionally 6697 for TLS) and
  // HexChat connects to it. Accept loop, per-connection threading, and plain-vs-TLS
  // transport selection all come from TVDRX_SocketListenerExecutive; this unit
  // hands each accepted connection off to a long-lived TVDRX_IRCConnection
  // (AdoptConnection-style, matching vdrx_websocket.pas) rather than handling the
  // protocol inline in HandleConnection.
  TVDRX_IRCDExecutive = class(TVDRX_SocketListenerExecutive)
  private
    FConfig: TVDRX_Config;
    FRegistry: TVDRX_Registry;
    FConnCounter: Integer;
    FTopicLock: TObject; // guards FTopics - declared TObject to avoid an extra uses dependency; cast at use
    FTopics: TStringList; // channel name -> topic string, shared across all connections
  protected
    procedure HandleConnection(ATransport: TVDRX_Transport); override;
  public
    constructor Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config; ARegistry: TVDRX_Registry); reintroduce;
    destructor Destroy; override;
    property Config: TVDRX_Config read FConfig;
    property Registry: TVDRX_Registry read FRegistry;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    function NextConnID: string;
    function GetTopic(const AChannel: string): string;
    procedure SetTopic(const AChannel, ATopic: string);
    procedure ApplyConfig; override;
  end;

implementation

function JEsc(const S: string): string;
begin
  Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
  Result := '"' + Result + '"';
end;

// Splits one IRC line into an uppercased command and its parameters, honouring the
// ':trailing multi-word param' convention. Deliberately not a full RFC 1459 parser
// (no message tags, no source prefix on client->server lines) - HexChat, and every
// other normal client, doesn't send either on outgoing lines.
procedure SplitIRCLine(const ALine: string; out ACmd: string; AParams: TStringList);
var
  S: string;
  SpacePos: Integer;
begin
  AParams.Clear;
  S := ALine;
  SpacePos := Pos(' ', S);
  if SpacePos = 0 then
  begin
    ACmd := UpperCase(S);
    Exit;
  end;
  ACmd := UpperCase(Copy(S, 1, SpacePos - 1));
  S := Copy(S, SpacePos + 1, Length(S));
  while S <> '' do
  begin
    if S[1] = ':' then
    begin
      AParams.Add(Copy(S, 2, Length(S)));
      S := '';
    end
    else
    begin
      SpacePos := Pos(' ', S);
      if SpacePos = 0 then
      begin
        AParams.Add(S);
        S := '';
      end
      else
      begin
        AParams.Add(Copy(S, 1, SpacePos - 1));
        S := Copy(S, SpacePos + 1, Length(S));
      end;
    end;
  end;
end;

function ChannelTopic(const AChannel: string): string;
begin
  Result := 'irc.' + AChannel + '.event';
end;

type
  // Same rationale as TVDRX_ListenerConnThread/TWSConnThread: a plain TThread
  // wrapper rather than an anonymous closure over a loop-local connection value.
  TIRCConnThread = class(TThread)
  private
    FConn: TVDRX_IRCConnection;
  protected
    procedure Execute; override;
  public
    constructor Create(AConn: TVDRX_IRCConnection);
  end;

constructor TIRCConnThread.Create(AConn: TVDRX_IRCConnection);
begin
  inherited Create(True);
  FConn := AConn;
  FreeOnTerminate := False;
end;

procedure TIRCConnThread.Execute;
begin
  FConn.RunLoop;
end;

{ TVDRX_IRCConnection }

constructor TVDRX_IRCConnection.Create(ABus: TVDRX_MessageQueue; AListener: TVDRX_IRCDExecutive; ATransport: TVDRX_Transport);
begin
  inherited Create(ABus);
  FListener := AListener;
  FTransport := ATransport;
  FSendLock := TCriticalSection.Create;
  FNick := '*';
  FChannels := TStringList.Create;
  FChannels.CaseSensitive := False;
  FChannels.Duplicates := dupIgnore;
end;

destructor TVDRX_IRCConnection.Destroy;
begin
  FChannels.Free;
  FTransport.Free;
  FSendLock.Free;
  inherited Destroy;
end;

function TVDRX_IRCConnection.HostMask: string;
begin
  Result := FNick + '!' + LowerCase(FUser) + '@vdrx';
end;

procedure TVDRX_IRCConnection.SendLine(const S: string);
var
  B: string;
begin
  B := S + #13#10;
  FSendLock.Enter;
  try
    FTransport.Write(B[1], Length(B));
    Bus.Publish('log.TVDRX_IRCConnection.SendLine', S, ID);
  finally
    FSendLock.Leave;
  end;
end;

// Numerics always look like ":server NNN nick <params>" - centralising this means
// every reply below is one line instead of a hand-built Format call.
procedure TVDRX_IRCConnection.SendNumeric(const ANumeric, AParams: string);
begin
  SendLine(':' + FListener.Config.GetString('executives.ircd.servername', 'vdrx') +
    ' ' + ANumeric + ' ' + FNick + ' ' + AParams);
end;

procedure TVDRX_IRCConnection.MaybeCompleteRegistration;
begin
  if FRegistered then Exit;
  if (FNick = '') or (FNick = '*') or (FUser = '') then Exit;
  FRegistered := True;
  SendWelcomeBurst;
  SendMotd;
  Bus.Publish('log.info', 'IRC client registered: ' + FNick, ID);
end;

procedure TVDRX_IRCConnection.SendWelcomeBurst;
var
  ServerName, Network: string;
begin
  ServerName := FListener.Config.GetString('executives.ircd.servername', 'vdrx');
  Network := FListener.Config.GetString('executives.ircd.network', 'VDRX');
  SendNumeric('001', ':Welcome to ' + Network + ', ' + FNick + '!' + HostMask);
  SendNumeric('002', ':Your host is ' + ServerName + ', running VDRX IRCD');
  SendNumeric('003', ':This server was started by VDRX');
  SendNumeric('004', ServerName + ' vdrx-0.1 o o');
end;

procedure TVDRX_IRCConnection.SendMotd;
var
  Lines: TStringArray;
  i: Integer;
begin
  Lines := FListener.Config.GetStringArray('executives.ircd.motd');
  if Length(Lines) = 0 then
  begin
    SendNumeric('422', ':MOTD File is missing');
    Exit;
  end;
  SendNumeric('375', ':- Message of the day -');
  for i := 0 to High(Lines) do
    SendNumeric('372', ':- ' + Lines[i]);
  SendNumeric('376', ':End of /MOTD command.');
end;

procedure TVDRX_IRCConnection.SendNames(const AChannel: string);
var
  Subscribers: TVDRX_ExecList;
  Exec: TVDRX_Executive;
  Names: string;
begin
  Names := '';
  Subscribers := FListener.Registry.GetSubscribers(ChannelTopic(AChannel));
  try
    for Exec in Subscribers do
      if Exec is TVDRX_IRCConnection then
      begin
        if Names <> '' then Names := Names + ' ';
        Names := Names + TVDRX_IRCConnection(Exec).Nick;
      end;
  finally
    Subscribers.Free;
  end;
  SendNumeric('353', '= ' + AChannel + ' :' + Names);
  SendNumeric('366', AChannel + ' :End of /NAMES list.');
end;

procedure TVDRX_IRCConnection.DoJoin(const AChannel: string);
var
  Topic: string;
  Payload: string;
begin
  if (AChannel = '') or ((AChannel[1] <> '#') and (AChannel[1] <> '&')) then
  begin
    SendNumeric('403', AChannel + ' :No such channel');
    Exit;
  end;
  if FChannels.IndexOf(AChannel) >= 0 then Exit; // already in channel

  // Register for this channel's events BEFORE announcing, so GetSubscribers below
  // (called from SendNames) already includes us - but we still send our own
  // JOIN/NAMES synchronously rather than waiting on the bus round-trip, since
  // HexChat expects an immediate reply to its JOIN command.
  FListener.Registry.Register(Self, ID, ChannelTopic(AChannel));
  FChannels.Add(AChannel);

  SendLine(':' + HostMask + ' JOIN :' + AChannel);
  Topic := FListener.GetTopic(AChannel);
  if Topic <> '' then
    SendNumeric('332', AChannel + ' :' + Topic)
  else
    SendNumeric('331', AChannel + ' :No topic is set');
  SendNames(AChannel);

  // Tell everyone else already in the channel - HandlePacket skips the sender, so
  // this never double-delivers to us on top of the SendLine above.
  Payload := Format('{"kind":"join","nick":%s,"user":%s}', [JEsc(FNick), JEsc(FUser)]);
  Bus.Publish(ChannelTopic(AChannel), Payload, ID);
end;

procedure TVDRX_IRCConnection.DoPart(const AChannel, AReason: string);
var
  Payload: string;
begin
  if FChannels.IndexOf(AChannel) < 0 then
  begin
    SendNumeric('442', AChannel + ' :You''re not on that channel');
    Exit;
  end;
  // Publish first, while we're still subscribed, then send our own PART line
  // directly and finally drop the subscription - this way both we and everyone
  // else see exactly one PART line each, in the right order.
  Payload := Format('{"kind":"part","nick":%s,"user":%s,"reason":%s}', [JEsc(FNick), JEsc(FUser), JEsc(AReason)]);
  Bus.Publish(ChannelTopic(AChannel), Payload, ID);
  SendLine(':' + HostMask + ' PART ' + AChannel + ' :' + AReason);
  FListener.Registry.UnregisterFilter(ID, ChannelTopic(AChannel));
  FChannels.Delete(FChannels.IndexOf(AChannel));
end;

procedure TVDRX_IRCConnection.DoPrivMsg(const ATarget, AText: string);
var
  Payload: string;
begin
  if (ATarget = '') or ((ATarget[1] <> '#') and (ATarget[1] <> '&')) then
  begin
    // No per-nick routing table yet (deferred, same spirit as other flagged gaps in
    // WIRING.md) - only channel messages are relayed for now.
    SendNumeric('401', ATarget + ' :No such nick/channel');
    Exit;
  end;
  if FChannels.IndexOf(ATarget) < 0 then
  begin
    SendNumeric('442', ATarget + ' :You''re not on that channel');
    Exit;
  end;
  Payload := Format('{"kind":"privmsg","from":%s,"user":%s,"text":%s}', [JEsc(FNick), JEsc(FUser), JEsc(AText)]);
  Bus.Publish(ChannelTopic(ATarget), Payload, ID);
end;

procedure TVDRX_IRCConnection.DoTopic(const AChannel, ANewTopic: string; AHasNewTopic: Boolean);
var
  Payload: string;
begin
  if FChannels.IndexOf(AChannel) < 0 then
  begin
    SendNumeric('442', AChannel + ' :You''re not on that channel');
    Exit;
  end;
  if not AHasNewTopic then
  begin
    if FListener.GetTopic(AChannel) <> '' then
      SendNumeric('332', AChannel + ' :' + FListener.GetTopic(AChannel))
    else
      SendNumeric('331', AChannel + ' :No topic is set');
    Exit;
  end;
  FListener.SetTopic(AChannel, ANewTopic);
  SendLine(':' + HostMask + ' TOPIC ' + AChannel + ' :' + ANewTopic);
  Payload := Format('{"kind":"topic","nick":%s,"user":%s,"topic":%s}', [JEsc(FNick), JEsc(FUser), JEsc(ANewTopic)]);
  Bus.Publish(ChannelTopic(AChannel), Payload, ID);
end;

procedure TVDRX_IRCConnection.DoQuitAllChannels(const AReason: string);
var
  i: Integer;
  Payload: string;
begin
  Payload := Format('{"kind":"quit","nick":%s,"user":%s,"reason":%s}', [JEsc(FNick), JEsc(FUser), JEsc(AReason)]);
  for i := 0 to FChannels.Count - 1 do
    Bus.Publish(ChannelTopic(FChannels[i]), Payload, ID);
end;

procedure TVDRX_IRCConnection.HandleLine(const ALine: string);
var
  Cmd: string;
  Params: TStringList;
  ServerName: string;
begin
  Bus.Publish('log.TVDRX_IRCConnection.HandleLine', ALine, ID);
  Params := TStringList.Create;
  try
    SplitIRCLine(ALine, Cmd, Params);
    ServerName := FListener.Config.GetString('executives.ircd.servername', 'vdrx');
    if Cmd = 'CAP' then
    begin
      // Modern clients (HexChat included) probe capabilities before registering -
      // advertise none and move on rather than leaving them hanging on a timeout.
      if (Params.Count > 0) and (UpperCase(Params[0]) = 'LS') then
        SendLine(':' + ServerName + ' CAP * LS :')
      else if (Params.Count > 0) and (UpperCase(Params[0]) = 'REQ') then
        SendLine(':' + ServerName + ' CAP * NAK :' + Params.Text);
      // CAP END: nothing to do - registration proceeds once NICK/USER are both seen.
    end
    else if Cmd = 'PASS' then
      // No auth implemented yet (flagged, same as sys.auth in the WebSocket
      // executive) - accepted and ignored rather than rejecting the connection.
    else if Cmd = 'PING' then
    begin
      if Params.Count > 0 then
        SendLine(':' + ServerName + ' PONG :' + Params[0])
      else
        SendLine(':' + ServerName + ' PONG ' + ServerName);
    end
    else if Cmd = 'PONG' then
    begin
      FAwaitingPong := False;
      FLastPingSent := Now;
    end
    else if Cmd = 'NICK' then
    begin
      if Params.Count > 0 then
      begin
        FNick := Params[0];
        MaybeCompleteRegistration;
      end;
    end
    else if Cmd = 'USER' then
    begin
      if Params.Count > 0 then
      begin
        FUser := Params[0];
        if Params.Count > 3 then FRealname := Params[3] else FRealname := FUser;
        MaybeCompleteRegistration;
      end;
    end
    else if not FRegistered then
      SendNumeric('451', ':You have not registered')
    else if Cmd = 'JOIN' then
    begin
      if Params.Count > 0 then
        DoJoin(Params[0]);
    end
    else if Cmd = 'PART' then
    begin
      if Params.Count > 0 then
        DoPart(Params[0], IfThen(Params.Count > 1, Params[1], FNick));
    end
    else if Cmd = 'PRIVMSG' then
    begin
      if Params.Count > 1 then
        DoPrivMsg(Params[0], Params[1]);
    end
    else if Cmd = 'TOPIC' then
    begin
      if Params.Count > 0 then
        DoTopic(Params[0], IfThen(Params.Count > 1, Params[1], ''), Params.Count > 1);
    end
    else if Cmd = 'MODE' then
    begin
      // Stub: report "no modes set" rather than staying silent, so HexChat's
      // automatic post-registration MODE query doesn't sit waiting on nothing.
      if (Params.Count > 0) and (Params[0] = FNick) then
        SendNumeric('221', ':+')
      else if Params.Count > 0 then
        SendNumeric('324', Params[0] + ' :+');
    end
    else if Cmd = 'QUIT' then
    begin
      DoQuitAllChannels(IfThen(Params.Count > 0, Params[0], 'Leaving'));
      FTransport.Close; // unblocks RunLoop's Read; cleanup happens there
    end;
    // Anything else (WHO/WHOIS/AWAY/LIST/...) is silently ignored for now -
    // deferred the same way other gaps in this codebase are flagged in WIRING.md.
  finally
    Params.Free;
  end;
end;

procedure TVDRX_IRCConnection.RunLoop;
var
  Buf: array[0..4095] of Byte;
  Received: Integer;
  Acc, Line: string;
  NlPos: Integer;
  PingToken: string;
  PingCounter: Integer;
const
  PING_INTERVAL = 30.0; // Send server ping every 30 seconds
  TIMEOUT_LIMIT = 90.0; // Give generous window before dropping
begin
  Bus.Publish('log.info', 'IRC client connected', ID);
  Acc := '';
  FLastPingSent := Now;
  FLastActivity := Now;
  FAwaitingPong := False;
  PingCounter := 0;

  while not TIRCConnThread(FThread).Terminated do
  begin
    Received := FTransport.Read(Buf[0], SizeOf(Buf));

    if TIRCConnThread(FThread).Terminated then
      Break;

    if Received > 0 then
    begin
      FLastActivity := Now; // Any traffic proves connection is alive

      SetString(Line, PAnsiChar(@Buf[0]), Received);
      Acc := Acc + Line;

      repeat
        NlPos := Pos(#10, Acc);
        if NlPos > 0 then
        begin
          Line := Copy(Acc, 1, NlPos - 1);
          if (Length(Line) > 0) and (Line[Length(Line)] = #13) then
            SetLength(Line, Length(Line) - 1);
          Acc := Copy(Acc, NlPos + 1, Length(Acc));
          Line := TrimRight(Line);
          if Line <> '' then
            HandleLine(Line);
        end;
      until NlPos = 0;

    end
    else if Received = 0 then
    begin
      Break; // Graceful disconnect
    end
    else
    begin
      // Read timed out (-1) - check timers below
    end;

    if TIRCConnThread(FThread).Terminated then
      Break;

    // Check if it's time to send a server-initiated ping
    if not FAwaitingPong and ((Now - FLastPingSent) * 86400 >= PING_INTERVAL) then
    begin
      Inc(PingCounter);
      PingToken := 'vdrxping' + IntToStr(PingCounter);
      SendLine('PING :' + PingToken);
      FLastPingSent := Now;
      FAwaitingPong := True;
    end;

    // Check if the client timed out responding to our ping or sending activity
    if FAwaitingPong and ((Now - FLastPingSent) * 86400 >= TIMEOUT_LIMIT) then
    begin
      Bus.Publish('log.info', 'IRC client ping timeout', ID);
      Break;
    end;
  end;

  if FRegistered then
    DoQuitAllChannels('Connection closed');
  FListener.Registry.Unregister(ID);
end;

procedure TVDRX_IRCConnection.Initialize;
begin
  FThread := TIRCConnThread.Create(Self);
  FThread.Start;
end;

procedure TVDRX_IRCConnection.Shutdown;
begin
  FTransport.Close; // unblocks the blocking Read in RunLoop
  if Assigned(FThread) then
  begin
    FThread.Terminate();
    FThread.WaitFor;
    FThread.Free;
    FThread := nil;
  end;
end;

procedure TVDRX_IRCConnection.HandlePacket(const AMsg: TVDRX_Message);
var
  J: TJSONData;
  Obj: TJSONObject;
  Kind, Channel, Mask: string;
begin
  if AMsg.SourceID = ID then Exit; // our own actions are already echoed synchronously
  // Topic shape is 'irc.<channel>.event' - pull the channel back out for the reply.
  Channel := Copy(AMsg.Topic, 5, Length(AMsg.Topic) - 4 - Length('.event'));
  try
    J := GetJSON(AMsg.Payload);
  except
    Exit; // malformed payload dropped
  end;
  try
    if not (J is TJSONObject) then Exit;
    Obj := TJSONObject(J);
    Kind := Obj.Get('kind', '');
    if Kind = 'privmsg' then
    begin
      Mask := Obj.Get('from', '') + '!' + LowerCase(Obj.Get('user', '')) + '@vdrx';
      SendLine(':' + Mask + ' PRIVMSG ' + Channel + ' :' + Obj.Get('text', ''));
    end
    else if Kind = 'join' then
    begin
      Mask := Obj.Get('nick', '') + '!' + LowerCase(Obj.Get('user', '')) + '@vdrx';
      SendLine(':' + Mask + ' JOIN :' + Channel);
    end
    else if Kind = 'part' then
    begin
      Mask := Obj.Get('nick', '') + '!' + LowerCase(Obj.Get('user', '')) + '@vdrx';
      SendLine(':' + Mask + ' PART ' + Channel + ' :' + Obj.Get('reason', ''));
    end
    else if Kind = 'quit' then
    begin
      Mask := Obj.Get('nick', '') + '!' + LowerCase(Obj.Get('user', '')) + '@vdrx';
      SendLine(':' + Mask + ' QUIT :' + Obj.Get('reason', ''));
    end
    else if Kind = 'topic' then
    begin
      Mask := Obj.Get('nick', '') + '!' + LowerCase(Obj.Get('user', '')) + '@vdrx';
      SendLine(':' + Mask + ' TOPIC ' + Channel + ' :' + Obj.Get('topic', ''));
    end;
  finally
    J.Free;
  end;
end;

{ TVDRX_IRCDExecutive }

constructor TVDRX_IRCDExecutive.Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config; ARegistry: TVDRX_Registry);
begin
  inherited Create(ABus);
  FConfig := AConfig;
  FRegistry := ARegistry;
  Port := 6667;
  FTopicLock := TCriticalSection.Create;
  FTopics := TStringList.Create;
  FTopics.CaseSensitive := False;
end;

destructor TVDRX_IRCDExecutive.Destroy;
begin
  FTopics.Free;
  FTopicLock.Free;
  inherited Destroy;
end;

function TVDRX_IRCDExecutive.NextConnID: string;
begin
  Inc(FConnCounter);
  Result := 'ircd.conn.' + IntToStr(FConnCounter);
end;

function TVDRX_IRCDExecutive.GetTopic(const AChannel: string): string;
var
  idx: Integer;
begin
  TCriticalSection(FTopicLock).Enter;
  try
    idx := FTopics.IndexOfName(AChannel);
    if idx >= 0 then
      Result := FTopics.ValueFromIndex[idx]
    else
      Result := '';
  finally
    TCriticalSection(FTopicLock).Leave;
  end;
end;

procedure TVDRX_IRCDExecutive.SetTopic(const AChannel, ATopic: string);
begin
  TCriticalSection(FTopicLock).Enter;
  try
    FTopics.Values[AChannel] := ATopic;
  finally
    TCriticalSection(FTopicLock).Leave;
  end;
end;

procedure TVDRX_IRCDExecutive.HandleConnection(ATransport: TVDRX_Transport);
var
  Conn: TVDRX_IRCConnection;
begin
  ATransport.SetReadTimeout(1000); // 1-second timeout so Read unblocks periodically for heartbeats
  Conn := TVDRX_IRCConnection.Create(Bus, Self, ATransport);
  FRegistry.Register(Conn, NextConnID, 'sys.none'); // real channel filters added on JOIN
  Conn.Initialize;
end;

procedure TVDRX_IRCDExecutive.HandlePacket(const AMsg: TVDRX_Message);
begin
  // The listener itself isn't a message recipient - each TVDRX_IRCConnection is.
end;

// Same restart-on-change pattern used for both the plain port and (new) TLS port -
// Shutdown/Initialize (inherited from TVDRX_SocketListenerExecutive) already tear
// down and rebind whichever of the two are configured, so reuse that rather than
// duplicating low-level socket calls here.
procedure TVDRX_IRCDExecutive.ApplyConfig;
var
  NewPort, NewTLSPort: Integer;
  CertFile, KeyFile: string;
begin
  NewPort := FConfig.GetInteger('executives.ircd.port', 6667);
  NewTLSPort := FConfig.GetInteger('executives.ircd.tls_port', 0);
  CertFile := FConfig.GetString('executives.ircd.tls_cert', '');
  KeyFile := FConfig.GetString('executives.ircd.tls_key', '');
  if (NewPort <> Port) or (NewTLSPort <> TLSPort) then
  begin
    Shutdown;
    Port := NewPort;
    ConfigureTLS(NewTLSPort, CertFile, KeyFile);
    Initialize;
  end;
end;

end.
