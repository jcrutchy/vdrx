program test_httphdr;

{$mode objfpc}{$H+}

// vdrx_httpparse.pas: removing client-supplied "who am I" headers, and adding the real peer for an upstream.
//
//   fpc -Mobjfpc -Fu../../src test_httphdr.lpr ; ./test_httphdr        (exit code 0 = all passed)

uses
  SysUtils, vdrx_httpparse;

var
  Passed, Failed: Integer;

procedure Check(ACond: Boolean; const AName: string);
begin
  if ACond then begin Inc(Passed); WriteLn('  ok    ', AName); end
  else begin Inc(Failed); WriteLn('  FAIL  ', AName); end;
end;

const
  CRLF = #13#10;

function Req(const AHeaders: array of string; const ABody: string = ''): string;
var
  i: Integer;
begin
  Result := 'GET /x HTTP/1.1' + CRLF;
  for i := 0 to High(AHeaders) do Result := Result + AHeaders[i] + CRLF;
  Result := Result + CRLF + ABody;
end;

var
  R: string;
begin
  Passed := 0; Failed := 0;

  WriteLn('-- StripForwardedHeaders');
  R := StripForwardedHeaders(Req(['Host: a', 'X-Forwarded-For: 1.2.3.4', 'Accept: */*']));
  Check(R = Req(['Host: a', 'Accept: */*']), 'X-Forwarded-For is removed, the rest is untouched');
  R := StripForwardedHeaders(Req(['x-forwarded-for: 1.1.1.1', 'X-FORWARDED-PROTO: https', 'x-forwarded-host: evil', 'X-Forwarded-Port: 1']));
  Check(R = Req([]), 'every X-Forwarded-* in any case goes');
  R := StripForwardedHeaders(Req(['Forwarded: for=1.1.1.1', 'X-Real-IP: 1.1.1.1', 'X-Client-IP: 1.1.1.1', 'True-Client-IP: 1.1.1.1',
    'CF-Connecting-IP: 1.1.1.1', 'X-Cluster-Client-IP: 1.1.1.1', 'X-Original-Forwarded-For: 1.1.1.1']));
  Check(R = Req([]), 'Forwarded, X-Real-IP and the other client-address headers go');
  R := StripForwardedHeaders(Req(['X_Forwarded_For: 1.1.1.1', 'X_Real_IP: 1.1.1.1']));
  Check(R = Req([]), 'underscore spellings go too');
  R := StripForwardedHeaders(Req(['X-Forwarded-For : 1.1.1.1']));
  Check(R = Req([]), 'a space before the colon does not hide it');
  R := StripForwardedHeaders(Req(['X-Forwarded-For: 1.1.1.1', 'X-Forwarded-For: 2.2.2.2', 'Host: a']));
  Check(R = Req(['Host: a']), 'repeated headers all go');
  R := StripForwardedHeaders(Req(['X-Forwarded-For: 1.1.1.1,', '   2.2.2.2', 'Host: a']));
  Check(R = Req(['Host: a']), 'a folded continuation line goes with its header');
  R := StripForwardedHeaders(Req(['Host: a', ' folded', 'Accept: */*']));
  Check(R = Req(['Host: a', ' folded', 'Accept: */*']), 'a continuation of a kept header stays');
  R := StripForwardedHeaders(Req(['Host: a', 'X-Forwarded-Foo-Bar: 1', 'X-Forward: 1', 'Xforwarded-for: 1', 'Cookie: forwarded=1; x-real-ip=2']));
  Check(R = Req(['Host: a', 'X-Forward: 1', 'Xforwarded-for: 1', 'Cookie: forwarded=1; x-real-ip=2']), 'only real names match, never values or look-alikes');
  R := StripForwardedHeaders(Req(['Host: a'], 'X-Forwarded-For: 9.9.9.9' + CRLF + 'body'));
  Check(R = Req(['Host: a'], 'X-Forwarded-For: 9.9.9.9' + CRLF + 'body'), 'the body is never touched');
  R := StripForwardedHeaders('GET / HTTP/1.1' + CRLF + 'X-Forwarded-For: 1.1.1.1' + CRLF);
  Check(R = 'GET / HTTP/1.1' + CRLF + 'X-Forwarded-For: 1.1.1.1' + CRLF, 'an incomplete head is returned unchanged');
  R := StripForwardedHeaders(Req([]));
  Check(R = Req([]), 'a request with no headers is unchanged');

  WriteLn('-- AddForwardedHeaders');
  R := AddForwardedHeaders(Req(['Host: a']), '203.0.113.9', False);
  Check(R = Req(['Host: a', 'X-Forwarded-For: 203.0.113.9', 'X-Forwarded-Proto: http']), 'peer and scheme are added (plain)');
  R := AddForwardedHeaders(Req(['Host: a']), '203.0.113.9', True);
  Check(Pos('X-Forwarded-Proto: https', R) > 0, 'scheme is https over TLS');
  R := AddForwardedHeaders(Req(['Host: a', 'X-Forwarded-For: 10.0.0.1', 'X-Forwarded-Proto: https']), '10.0.0.2', False);
  Check(R = Req(['Host: a', 'X-Forwarded-Proto: https', 'X-Forwarded-For: 10.0.0.1, 10.0.0.2']), 'a trusted proxy''s chain is extended (one header) and its scheme kept');
  R := AddForwardedHeaders(Req(['Host: a', 'X-Forwarded-For: 1.1.1.1', 'X-Forwarded-For: 2.2.2.2']), '3.3.3.3', False);
  Check(Pos('X-Forwarded-For: 1.1.1.1, 2.2.2.2, 3.3.3.3', R) > 0, 'repeated headers are merged into one chain');
  R := AddForwardedHeaders(Req(['Host: a'], 'body'), '1.2.3.4', False);
  Check(Copy(R, Length(R) - 3, 4) = 'body', 'the body is kept');
  Check(AddForwardedHeaders(Req(['Host: a']), '', False) = Req(['Host: a']), 'no peer address: unchanged');
  R := AddForwardedHeaders(StripForwardedHeaders(Req(['X-Forwarded-For: 6.6.6.6', 'Host: a'])), '1.2.3.4', False);
  Check(Pos('6.6.6.6', R) = 0, 'strip then add: a client''s forged value never reaches the upstream');

  WriteLn;
  WriteLn(Passed, ' passed, ', Failed, ' failed');
  if Failed > 0 then Halt(1);
end.
