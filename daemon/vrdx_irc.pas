unit vrdx_irc;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Sockets, StrUtils, vrdx_core, vrdx_socketlistener, vrdx_config;

type
  // IRCD, not an IRC client - VDRX binds 6667 and HexChat connects to it. Just enough
  // protocol to keep HexChat happy: NICK/USER -> welcome, JOIN echoed back, PING/PONG,
  // PRIVMSG parsed and republished onto the bus. Accept loop and per-connection
  // threading come from TVRDX_SocketListenerExecutive; this unit only implements the
  // protocol itself in HandleConnection.
  TVRDX_IRCDExecutive = class(TVRDX_SocketListenerExecutive)
  private
    FConfig: TVRDX_Config;
  protected
    procedure HandleConnection(ASock: TSocket); override;
  public
    constructor Create(ABus: TVRDX_MessageQueue; AConfig: TVRDX_Config); reintroduce;
    procedure HandlePacket(const AMsg: TVRDX_Message); override;
    procedure ApplyConfig; override;
  end;

implementation

function JEsc(const S: string): string;
begin
  Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
  Result := '"' + Result + '"';
end;

{ TVRDX_IRCDExecutive }

constructor TVRDX_IRCDExecutive.Create(ABus: TVRDX_MessageQueue; AConfig: TVRDX_Config);
begin
  inherited Create(ABus);
  FConfig := AConfig;
  Port := 6667;
end;

procedure TVRDX_IRCDExecutive.HandleConnection(ASock: TSocket);
var
  Buf: array[0..4095] of Byte;
  Received: Integer;
  Acc, Line, Nick: string;
  NlPos, p1, p2: Integer;

  procedure SendLine(const S: string);
  var B: string;
  begin
    B := S + #13#10;
    fpSend(ASock, @B[1], Length(B), 0);
  end;

var
  Channel, Msg: string;
begin
  Bus.Publish('log.info', 'Client connected from 127.0.0.1', ID);
  Nick := 'guest';
  Acc := '';
  while not Stopping do
  begin
    Received := fpRecv(ASock, @Buf[0], SizeOf(Buf), 0);
    if Received <= 0 then
      Break;
    SetString(Line, PAnsiChar(@Buf[0]), Received);
    Acc := Acc + Line;
    repeat
      NlPos := Pos(#10, Acc);
      if NlPos > 0 then
      begin
        Line := TrimRight(Copy(Acc, 1, NlPos - 1));
        Acc := Copy(Acc, NlPos + 1, Length(Acc));
        if Line = '' then Continue;

        if Copy(Line, 1, 4) = 'PING' then
          SendLine('PONG' + Copy(Line, 5, Length(Line)))
        else if Copy(Line, 1, 4) = 'NICK' then
        begin
          Nick := Trim(Copy(Line, 6, Length(Line)));
          SendLine(':vrdx 001 ' + Nick + ' :Welcome to VDRX');
        end
        else if Copy(Line, 1, 4) = 'JOIN' then
          SendLine(':' + Nick + ' JOIN ' + Trim(Copy(Line, 6, Length(Line))))
        else if Copy(Line, 1, 7) = 'PRIVMSG' then
        begin
          p1 := Pos(' ', Line);
          p2 := PosEx(' ', Line, p1 + 1);
          if p2 > 0 then
          begin
            Channel := Copy(Line, p1 + 1, p2 - p1 - 1);
            Msg := Copy(Line, p2 + 3, Length(Line)); // skip leading ' :'
            Bus.Publish('irc.msg.' + Channel,
              Format('{"from":%s,"text":%s}', [JEsc(Nick), JEsc(Msg)]), 'irc.' + Nick);
          end;
        end;
        // USER intentionally ignored - NICK alone is enough to identify SourceID
      end;
    until NlPos = 0;
  end;
  CloseSocket(ASock);
end;

procedure TVRDX_IRCDExecutive.HandlePacket(const AMsg: TVRDX_Message);
begin
  // Outbound IRC (e.g. a bot announcing something in-channel) would go here - not
  // needed for the hello-world flow, which is one-directional (IRC -> bus).
end;

// Rebinding to a new port means tearing the listener down and bringing it back up -
// Shutdown/Initialize (inherited from TVRDX_SocketListenerExecutive) already do
// exactly that, so reuse them rather than duplicating low-level socket calls here.
procedure TVRDX_IRCDExecutive.ApplyConfig;
var
  NewPort: Integer;
begin
  NewPort := FConfig.GetInteger('executives.ircd.port', 6667);
  if NewPort <> Port then
  begin
    Port := NewPort;
    Shutdown;
    Initialize;
  end;
end;

end.
