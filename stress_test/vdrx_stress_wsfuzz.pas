unit vdrx_stress_wsfuzz;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Math, ssockets, vdrx_stress_report, vdrx_stress_daemonctl;

type
  TWSFuzzConfig = record
    Host: string;
    Port: Word;
    ConnectTimeoutMs: Integer;
    ReadTimeoutMs: Integer;
    RapidConnectCycles: Integer;
  end;

procedure RunWSFuzzSuite(const ACfg: TWSFuzzConfig; AReport: TStressReport;
  ACtl: TVDRX_DaemonController);

implementation

const
  SUITE = 'ws';

// Handshake doesn't validate the response at all - we don't care whether the
// server's Sec-WebSocket-Accept is byte-correct, only whether it's alive
// afterward. A real Sec-WebSocket-Key isn't even required to be a properly
// random base64 blob for that purpose, so a fixed one is fine here.
function DoHandshake(ASock: TInetSocket): Boolean;
var
  Req: string;
  Buf: array[0..1023] of Byte;
begin
  Result := False;
  Req := 'GET / HTTP/1.1'#13#10 +
    'Host: x'#13#10 +
    'Upgrade: websocket'#13#10 +
    'Connection: Upgrade'#13#10 +
    'Sec-WebSocket-Key: ZHVtbXlrZXkxMjM0NTY3OA=='#13#10 +
    'Sec-WebSocket-Version: 13'#13#10#13#10;
  try
    ASock.Write(Req[1], Length(Req));
    ASock.Read(Buf, SizeOf(Buf)); // don't inspect it - just drain the handshake response
    Result := True;
  except
    Result := False;
  end;
end;

// Encodes one WS frame. AMasked=True (the RFC-correct default for a client)
// XORs the payload with a fixed masking key - fine for fuzzing purposes,
// doesn't need to be random. AMasked=False deliberately produces a
// protocol-violating unmasked client frame, which is itself one of the fuzz
// cases below.
function EncodeFrame(AOpcode: Byte; const APayload: string; AMasked: Boolean;
  AFin: Boolean = True): string;
var
  Header: string;
  MaskKey: array[0..3] of Byte;
  MaskedPayload: string;
  i: Integer;
  Len: Int64;
  B0, B1: Byte;
begin
  Len := Length(APayload);
  B0 := AOpcode and $0F;
  if AFin then
    B0 := B0 or $80;
  Header := Chr(B0);

  B1 := 0;
  if AMasked then
    B1 := $80;

  if Len <= 125 then
    Header := Header + Chr(B1 or Len)
  else if Len <= 65535 then
  begin
    Header := Header + Chr(B1 or 126);
    Header := Header + Chr((Len shr 8) and $FF) + Chr(Len and $FF);
  end
  else
  begin
    Header := Header + Chr(B1 or 127);
    for i := 7 downto 0 do
      Header := Header + Chr((Len shr (i * 8)) and $FF);
  end;

  if AMasked then
  begin
    MaskKey[0] := $12; MaskKey[1] := $34; MaskKey[2] := $56; MaskKey[3] := $78;
    Header := Header + Chr(MaskKey[0]) + Chr(MaskKey[1]) + Chr(MaskKey[2]) + Chr(MaskKey[3]);
    SetLength(MaskedPayload, Len);
    for i := 1 to Len do
      MaskedPayload[i] := Chr(Ord(APayload[i]) xor MaskKey[(i - 1) mod 4]);
    Result := Header + MaskedPayload;
  end
  else
    Result := Header + APayload;
end;

procedure SendFrameRaw(const ACfg: TWSFuzzConfig; const AFrameBytes: string);
var
  Sock: TInetSocket;
  Buf: array[0..4095] of Byte;
begin
  if not TryConnect(ACfg.Host, ACfg.Port, ACfg.ConnectTimeoutMs, Sock) then
    Exit;
  try
    if not DoHandshake(Sock) then
      Exit;
    try
      Sock.Write(AFrameBytes[1], Length(AFrameBytes));
      Sock.Read(Buf, SizeOf(Buf)); // best-effort drain; timeout/close both fine
    except
      // reset/timeout after sending garbage - expected
    end;
  finally
    Sock.Free;
  end;
end;

function CheckAlive(const ACfg: TWSFuzzConfig; AReport: TStressReport;
  ACtl: TVDRX_DaemonController; const ATestName: string): Boolean;
var
  Sock: TInetSocket;
begin
  Result := True;
  if ACtl.Managed and (not ACtl.IsAlive) then
  begin
    AReport.Fail(SUITE, ATestName, 'managed daemon process is no longer running (crash) - recent output: ' +
      Copy(ACtl.RecentOutput, 1, 500));
    Exit(False);
  end;
  if TryConnect(ACfg.Host, ACfg.Port, ACfg.ConnectTimeoutMs, Sock) then
  begin
    if not DoHandshake(Sock) then
    begin
      AReport.Fail(SUITE, ATestName, 'WS port accepted TCP connection but handshake failed');
      Result := False;
    end;
    Sock.Free;
  end
  else
  begin
    AReport.Fail(SUITE, ATestName, 'WS port no longer accepting connections after this test');
    Result := False;
  end;
end;

procedure RunWSFuzzSuite(const ACfg: TWSFuzzConfig; AReport: TStressReport;
  ACtl: TVDRX_DaemonController);
var
  HugePayload: string;
  i: Integer;
  ConnectFails: Integer;
  Sock: TInetSocket;
begin
  AReport.Info('ws: baseline handshake sanity check');
  if not CheckAlive(ACfg, AReport, ACtl, 'baseline') then
  begin
    AReport.Fail(SUITE, 'baseline', 'daemon unreachable before fuzzing even started - aborting suite');
    Exit;
  end;
  AReport.Pass(SUITE, 'baseline');

  // --- Valid frame, valid-looking JSON-RPC ---
  SendFrameRaw(ACfg, EncodeFrame($1, '{"action":"subscribe","topic":"log.>"}', True));
  if CheckAlive(ACfg, AReport, ACtl, 'valid_subscribe_message') then
    AReport.Pass(SUITE, 'valid_subscribe_message');

  // --- Malformed JSON inside an otherwise-valid frame ---
  SendFrameRaw(ACfg, EncodeFrame($1, '{not valid json at all', True));
  if CheckAlive(ACfg, AReport, ACtl, 'malformed_json_payload') then
    AReport.Pass(SUITE, 'malformed_json_payload');

  SendFrameRaw(ACfg, EncodeFrame($1, '', True));
  if CheckAlive(ACfg, AReport, ACtl, 'empty_text_frame') then
    AReport.Pass(SUITE, 'empty_text_frame');

  SendFrameRaw(ACfg, EncodeFrame($1, '{"action":"subscribe"}', True)); // missing "topic"
  if CheckAlive(ACfg, AReport, ACtl, 'missing_required_field') then
    AReport.Pass(SUITE, 'missing_required_field');

  SendFrameRaw(ACfg, EncodeFrame($1, '{"action":"subscribe","topic":12345}', True)); // wrong type
  if CheckAlive(ACfg, AReport, ACtl, 'wrong_field_type') then
    AReport.Pass(SUITE, 'wrong_field_type');

  SendFrameRaw(ACfg, EncodeFrame($1, '{"action":"nonexistent_action_xyz","topic":"x"}', True));
  if CheckAlive(ACfg, AReport, ACtl, 'unknown_action') then
    AReport.Pass(SUITE, 'unknown_action');

  // --- Deeply nested JSON (recursion-depth stress) ---
  SendFrameRaw(ACfg, EncodeFrame($1, StringOfChar('[', 5000) + '1' + StringOfChar(']', 5000), True));
  if CheckAlive(ACfg, AReport, ACtl, 'deeply_nested_json') then
    AReport.Pass(SUITE, 'deeply_nested_json');

  // --- Non-UTF8 bytes claimed as a text frame ---
  SendFrameRaw(ACfg, EncodeFrame($1, Chr($FF) + Chr($FE) + Chr($80) + Chr($C0), True));
  if CheckAlive(ACfg, AReport, ACtl, 'invalid_utf8_in_text_frame') then
    AReport.Pass(SUITE, 'invalid_utf8_in_text_frame');

  // --- Unmasked client frame - protocol violation, RFC 6455 says the server
  //     should close the connection, not crash ---
  SendFrameRaw(ACfg, EncodeFrame($1, '{"action":"subscribe","topic":"x"}', False));
  if CheckAlive(ACfg, AReport, ACtl, 'unmasked_client_frame') then
    AReport.Pass(SUITE, 'unmasked_client_frame');

  // --- Invalid/reserved opcode ---
  SendFrameRaw(ACfg, EncodeFrame($3, 'x', True)); // 0x3 is reserved, not defined
  if CheckAlive(ACfg, AReport, ACtl, 'reserved_opcode') then
    AReport.Pass(SUITE, 'reserved_opcode');

  // --- Binary frame instead of text ---
  SendFrameRaw(ACfg, EncodeFrame($2, '{"action":"subscribe","topic":"x"}', True));
  if CheckAlive(ACfg, AReport, ACtl, 'binary_opcode_with_json') then
    AReport.Pass(SUITE, 'binary_opcode_with_json');

  // --- Fragmented frame, never completed (FIN=0, no continuation follows) ---
  SendFrameRaw(ACfg, EncodeFrame($1, '{"action":"subscribe"', True, False));
  if CheckAlive(ACfg, AReport, ACtl, 'abandoned_fragment') then
    AReport.Pass(SUITE, 'abandoned_fragment');

  // --- Oversized frame - this is exactly what the known "WS frame length
  //     cap" gap (see README) would need to guard against. Kept to 5MB
  //     rather than truly huge, to stay a meaningful test without spending
  //     the whole run on one allocation. ---
  HugePayload := StringOfChar('X', 5 * 1024 * 1024);
  SendFrameRaw(ACfg, EncodeFrame($1, HugePayload, True));
  if CheckAlive(ACfg, AReport, ACtl, 'oversized_frame_5mb') then
    AReport.Pass(SUITE, 'oversized_frame_5mb');

  // --- Raw garbage immediately after a valid handshake, not framed at all ---
  begin
    if TryConnect(ACfg.Host, ACfg.Port, ACfg.ConnectTimeoutMs, Sock) then
    begin
      try
        if DoHandshake(Sock) then
        begin
          try
            Sock.Write('\x00\xFF\xDE\xAD\xBE\xEF not a websocket frame at all'[1], 40);
          except
          end;
        end;
      finally
        Sock.Free;
      end;
    end;
  end;
  if CheckAlive(ACfg, AReport, ACtl, 'raw_garbage_after_handshake') then
    AReport.Pass(SUITE, 'raw_garbage_after_handshake');

  // --- Rapid connect/disconnect cycling, no clean WS close handshake ---
  AReport.Info(Format('ws: %d rapid connect/disconnect cycles', [ACfg.RapidConnectCycles]));
  ConnectFails := 0;
  for i := 1 to ACfg.RapidConnectCycles do
  begin
    if TryConnect(ACfg.Host, ACfg.Port, ACfg.ConnectTimeoutMs, Sock) then
    begin
      DoHandshake(Sock);
      Sock.Free; // abrupt close, no WS close frame - simulates a crashed/killed client
    end
    else
      Inc(ConnectFails);
  end;
  AReport.Metric(SUITE, 'rapid_reconnect_failures', ConnectFails, 'count');
  if CheckAlive(ACfg, AReport, ACtl, 'rapid_reconnect_survival') then
    AReport.Pass(SUITE, 'rapid_reconnect_survival');
end;

end.
