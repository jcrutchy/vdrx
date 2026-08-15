unit vdrx_stress_httpfuzz;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Math, ssockets, vdrx_stress_report, vdrx_stress_daemonctl;

type
  THTTPFuzzConfig = record
    Host: string;
    Port: Word;
    LoadRequests: Integer;    // total requests for the load-test phase
    LoadConcurrency: Integer; // simultaneous connections during that phase
    ConnectTimeoutMs: Integer;
    ReadTimeoutMs: Integer;
  end;

// Runs every malformed-request case, then a basic concurrent-load phase.
// After each malformed case, checks the daemon is still alive/responsive -
// that survival check IS the pass/fail signal, not HTTP spec compliance.
// Whatever status code (or no response at all) the daemon gives to a
// garbage request is fine; dying is not.
procedure RunHTTPFuzzSuite(const ACfg: THTTPFuzzConfig; AReport: TStressReport;
  ACtl: TVDRX_DaemonController);

implementation

type
  TLoadWorkerThread = class(TThread)
  public
    Cfg: THTTPFuzzConfig;
    RequestCount: Integer;
    ErrorCount: Integer;
  protected
    procedure Execute; override;
  end;

procedure TLoadWorkerThread.Execute;
var
  k: Integer;
  S: TInetSocket;
  Req2: string;
  B: array[0..1023] of Byte;
begin
  Req2 := 'GET / HTTP/1.1'#13#10'Host: x'#13#10'Connection: close'#13#10#13#10;
  for k := 1 to RequestCount do
  begin
    if TryConnect(Cfg.Host, Cfg.Port, Cfg.ConnectTimeoutMs, S) then
    begin
      try
        try
          S.Write(Req2[1], Length(Req2));
          S.Read(B, SizeOf(B));
        except
          Inc(ErrorCount);
        end;
      finally
        S.Free;
      end;
    end
    else
      Inc(ErrorCount);
  end;
end;

const
  SUITE = 'http';

// Sends raw bytes, then tries to read *something* back (doesn't care what -
// a response, a RST, a timeout, all just mean "the socket did what sockets
// do"). Returns True as long as it got this far without an unhandled
// exception - the real check happens in the caller via daemon liveness.
procedure SendRaw(const ACfg: THTTPFuzzConfig; const ARaw: string);
var
  Sock: TInetSocket;
  Buf: array[0..4095] of Byte;
begin
  if not TryConnect(ACfg.Host, ACfg.Port, ACfg.ConnectTimeoutMs, Sock) then
    Exit; // connection refused is a legitimate outcome (e.g. HTTP not enabled) - not a fuzz finding
  try
    try
      if ARaw <> '' then
        Sock.Write(ARaw[1], Length(ARaw));
      Sock.Read(Buf, SizeOf(Buf)); // best-effort; timeout or EOF both fine, we don't inspect the reply
    except
      // connection reset, timeout, etc - all expected outcomes of sending garbage
    end;
  finally
    Sock.Free;
  end;
end;

function CheckAlive(const ACfg: THTTPFuzzConfig; AReport: TStressReport;
  ACtl: TVDRX_DaemonController; const ATestName: string): Boolean;
var
  Sock: TInetSocket;
  Req: string;
  Buf: array[0..255] of Byte;
begin
  Result := True;
  if ACtl.Managed and (not ACtl.IsAlive) then
  begin
    AReport.Fail(SUITE, ATestName, 'managed daemon process is no longer running (crash) - recent output: ' +
      Copy(ACtl.RecentOutput, 1, 500));
    Exit(False);
  end;
  // Whether managed or attached, also confirm the HTTP port itself still
  // answers - a hung listener thread (still "running" as a process, but no
  // longer accepting connections) is just as real a regression as a crash.
  if TryConnect(ACfg.Host, ACfg.Port, ACfg.ConnectTimeoutMs, Sock) then
  begin
    try
      Req := 'GET / HTTP/1.1'#13#10'Host: localhost'#13#10'Connection: close'#13#10#13#10;
      Sock.Write(Req[1], Length(Req));
      try
        Sock.Read(Buf, SizeOf(Buf));
      except
      end;
    finally
      Sock.Free;
    end;
  end
  else
  begin
    AReport.Fail(SUITE, ATestName, 'HTTP port no longer accepting connections after this test');
    Result := False;
  end;
end;

procedure RunHTTPFuzzSuite(const ACfg: THTTPFuzzConfig; AReport: TStressReport;
  ACtl: TVDRX_DaemonController);
var
  LongPath, LongHeaderVal, Req: string;
  i: Integer;
  TrickleSock: TInetSocket;
  FullReq: string;
  j: Integer;
  Survived: Boolean;
  Threads: array of TThread;
  StartTime, EndTime: TDateTime;
  t, PerThread: Integer;
  TotalErrors: Integer;
begin
  AReport.Info('http: baseline sanity check');
  if not CheckAlive(ACfg, AReport, ACtl, 'baseline') then
  begin
    AReport.Fail(SUITE, 'baseline', 'daemon unreachable before fuzzing even started - aborting suite');
    Exit;
  end;
  AReport.Pass(SUITE, 'baseline');

  // --- Malformed request line ---
  SendRaw(ACfg, 'GARBAGE NOT AN HTTP REQUEST AT ALL'#13#10#13#10);
  if CheckAlive(ACfg, AReport, ACtl, 'malformed_request_line') then
    AReport.Pass(SUITE, 'malformed_request_line');

  SendRaw(ACfg, #0#0#0#0#0#0#0#0#13#10#13#10);
  if CheckAlive(ACfg, AReport, ACtl, 'null_bytes_as_request') then
    AReport.Pass(SUITE, 'null_bytes_as_request');

  SendRaw(ACfg, 'GET / HTTP/999.999'#13#10#13#10);
  if CheckAlive(ACfg, AReport, ACtl, 'bogus_http_version') then
    AReport.Pass(SUITE, 'bogus_http_version');

  SendRaw(ACfg, ''#0''); // truly empty
  if CheckAlive(ACfg, AReport, ACtl, 'empty_request') then
    AReport.Pass(SUITE, 'empty_request');

  // --- Oversized URL ---
  LongPath := StringOfChar('A', 200000);
  SendRaw(ACfg, 'GET /' + LongPath + ' HTTP/1.1'#13#10'Host: x'#13#10#13#10);
  if CheckAlive(ACfg, AReport, ACtl, 'oversized_url_200kb') then
    AReport.Pass(SUITE, 'oversized_url_200kb');

  // --- Oversized / many headers ---
  LongHeaderVal := StringOfChar('B', 500000);
  SendRaw(ACfg, 'GET / HTTP/1.1'#13#10'Host: x'#13#10'X-Huge: ' + LongHeaderVal + #13#10#13#10);
  if CheckAlive(ACfg, AReport, ACtl, 'oversized_header_value_500kb') then
    AReport.Pass(SUITE, 'oversized_header_value_500kb');

  Req := 'GET / HTTP/1.1'#13#10'Host: x'#13#10;
  for i := 1 to 5000 do
    Req := Req + Format('X-Filler-%d: v'#13#10, [i]);
  Req := Req + #13#10;
  SendRaw(ACfg, Req);
  if CheckAlive(ACfg, AReport, ACtl, 'five_thousand_headers') then
    AReport.Pass(SUITE, 'five_thousand_headers');

  // --- Content-Length lies ---
  SendRaw(ACfg, 'POST / HTTP/1.1'#13#10'Host: x'#13#10'Content-Length: -1'#13#10#13#10);
  if CheckAlive(ACfg, AReport, ACtl, 'negative_content_length') then
    AReport.Pass(SUITE, 'negative_content_length');

  SendRaw(ACfg, 'POST / HTTP/1.1'#13#10'Host: x'#13#10'Content-Length: 999999999999'#13#10#13#10'short body');
  if CheckAlive(ACfg, AReport, ACtl, 'huge_content_length_short_body') then
    AReport.Pass(SUITE, 'huge_content_length_short_body');

  SendRaw(ACfg, 'POST / HTTP/1.1'#13#10'Host: x'#13#10'Content-Length: notanumber'#13#10#13#10);
  if CheckAlive(ACfg, AReport, ACtl, 'non_numeric_content_length') then
    AReport.Pass(SUITE, 'non_numeric_content_length');

  // --- Malformed chunked encoding ---
  SendRaw(ACfg, 'POST / HTTP/1.1'#13#10'Host: x'#13#10'Transfer-Encoding: chunked'#13#10#13#10 +
    'ZZZ'#13#10'not a valid chunk size'#13#10);
  if CheckAlive(ACfg, AReport, ACtl, 'malformed_chunk_size') then
    AReport.Pass(SUITE, 'malformed_chunk_size');

  // --- Path traversal attempt (static file serving) ---
  SendRaw(ACfg, 'GET /../../../../etc/passwd HTTP/1.1'#13#10'Host: x'#13#10#13#10);
  if CheckAlive(ACfg, AReport, ACtl, 'path_traversal_attempt') then
    AReport.Pass(SUITE, 'path_traversal_attempt');

  SendRaw(ACfg, 'GET /%2e%2e%2f%2e%2e%2f%2e%2e%2fetc%2fpasswd HTTP/1.1'#13#10'Host: x'#13#10#13#10);
  if CheckAlive(ACfg, AReport, ACtl, 'encoded_path_traversal_attempt') then
    AReport.Pass(SUITE, 'encoded_path_traversal_attempt');

  // --- Non-UTF8 / raw binary garbage in the request ---
  SendRaw(ACfg, 'GET /' + Chr($FF) + Chr($FE) + Chr($80) + Chr($81) + ' HTTP/1.1'#13#10'Host: x'#13#10#13#10);
  if CheckAlive(ACfg, AReport, ACtl, 'raw_binary_in_path') then
    AReport.Pass(SUITE, 'raw_binary_in_path');

  // --- Immediate close, no data at all ---
  SendRaw(ACfg, '');
  if CheckAlive(ACfg, AReport, ACtl, 'connect_then_immediate_close') then
    AReport.Pass(SUITE, 'connect_then_immediate_close');

  // --- Slow-loris-lite: trickle a request one byte at a time ---
  FullReq := 'GET / HTTP/1.1'#13#10'Host: x'#13#10#13#10;
  Survived := True;
  if TryConnect(ACfg.Host, ACfg.Port, ACfg.ConnectTimeoutMs, TrickleSock) then
  begin
    try
      for j := 1 to Length(FullReq) do
      begin
        try
          TrickleSock.Write(FullReq[j], 1);
        except
          Survived := False;
          Break;
        end;
        Sleep(5);
      end;
    finally
      TrickleSock.Free;
    end;
  end;
  if Survived then
  begin
    if CheckAlive(ACfg, AReport, ACtl, 'trickled_request_byte_at_a_time') then
      AReport.Pass(SUITE, 'trickled_request_byte_at_a_time');
  end
  else
    AReport.Info('http: trickled_request connection dropped mid-send (acceptable - server may enforce a read timeout)');

  // --- Basic concurrent load phase ---
  AReport.Info(Format('http: load phase - %d requests across %d concurrent connections',
    [ACfg.LoadRequests, ACfg.LoadConcurrency]));

  PerThread := ACfg.LoadRequests div Max(1, ACfg.LoadConcurrency);
  SetLength(Threads, ACfg.LoadConcurrency);

  StartTime := Now;
  for t := 0 to ACfg.LoadConcurrency - 1 do
  begin
    Threads[t] := TLoadWorkerThread.Create(True);
    TLoadWorkerThread(Threads[t]).Cfg := ACfg;
    TLoadWorkerThread(Threads[t]).RequestCount := PerThread;
    TLoadWorkerThread(Threads[t]).ErrorCount := 0;
    Threads[t].FreeOnTerminate := False;
    Threads[t].Start;
  end;

  TotalErrors := 0;
  for t := 0 to ACfg.LoadConcurrency - 1 do
  begin
    Threads[t].WaitFor;
    TotalErrors := TotalErrors + TLoadWorkerThread(Threads[t]).ErrorCount;
    Threads[t].Free;
  end;
  EndTime := Now;

  AReport.Metric(SUITE, 'load_requests_per_sec',
    (PerThread * ACfg.LoadConcurrency) / Max(0.001, (EndTime - StartTime) * 86400), 'req/s');
  AReport.Metric(SUITE, 'load_error_count', TotalErrors, 'count');

  if CheckAlive(ACfg, AReport, ACtl, 'load_phase_survival') then
    AReport.Pass(SUITE, 'load_phase_survival');

  if TotalErrors > (PerThread * ACfg.LoadConcurrency) div 10 then
    AReport.Fail(SUITE, 'load_phase_error_rate',
      Format('%d/%d requests failed (>10%%) under concurrent load',
        [TotalErrors, PerThread * ACfg.LoadConcurrency]))
  else
    AReport.Pass(SUITE, 'load_phase_error_rate');
end;

end.
