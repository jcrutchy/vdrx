program test_redact;

{$mode ObjFPC}{$H+}

// Self-contained tests for vdrx_redact.pas (log credential masking).
//
//   fpc -Mobjfpc -Sh -Fu../../src test_redact.lpr
//   ./test_redact          (exit code 0 = all passed)

uses
  SysUtils, vdrx_redact;

var
  Passed, Failed: Integer;
  R: TVDRX_Redactor;

procedure Check(ACond: Boolean; const AName: string);
begin
  if ACond then begin Inc(Passed); WriteLn('  ok    ', AName); end
  else begin Inc(Failed); WriteLn('  FAIL  ', AName); end;
end;

procedure Gone(const AInput, ASecret, AName: string);
var Out: string;
begin
  Out := R.Redact(AInput);
  if Pos(ASecret, Out) > 0 then WriteLn('          leaked: ', Out);
  Check(Pos(ASecret, Out) = 0, AName);
end;

procedure Same(const AInput, AName: string);
var Out: string;
begin
  Out := R.Redact(AInput);
  if Out <> AInput then begin WriteLn('          changed to: ', Out); end;
  Check(Out = AInput, AName);
end;

procedure Has(const AInput, AWanted, AName: string);
var Out: string;
begin
  Out := R.Redact(AInput);
  if Pos(AWanted, Out) = 0 then WriteLn('          output: ', Out);
  Check(Pos(AWanted, Out) > 0, AName);
end;

begin
  Passed := 0; Failed := 0;
  R := TVDRX_Redactor.Create(True);
  try
    WriteLn('-- secret members');
    Gone('{ "headers" : { "Authorization" : "Bearer SUPERSECRETBEARER", "Host" : "x" } }', 'SUPERSECRETBEARER', 'Authorization header value removed');
    Has ('{ "headers" : { "Authorization" : "Bearer SUPERSECRETBEARER", "Host" : "x" } }', '"Host" : "x"', 'neighbouring members survive');
    Has ('{ "Cookie" : "session=SESSIONCOOKIE123" }', '"Cookie"', 'the member NAME is kept so the line stays readable');
    Gone('{"COOKIE":"a=1"}', 'a=1', 'member names match case-insensitively');
    Gone('{"Set-Cookie":"sid=ABCDEF12345; HttpOnly"}', 'ABCDEF12345', 'Set-Cookie');
    Gone('{"Cookie":"a=\"quoted secret\"; b=2"}', 'quoted secret', 'value containing escaped quotes is masked in full');
    Gone('{"Cookie":"a=\"x\"; tail=AFTERQUOTE', 'AFTERQUOTE', 'value cut off by truncation (no closing quote) is masked');
    Gone('{"method": "sys.auth", "token": "WSSECRETTOKEN999"}', 'WSSECRETTOKEN999', 'WebSocket sys.auth token');
    Has ('{"method": "sys.auth", "token": "WSSECRETTOKEN999"}', '"method": "sys.auth"', 'and the method is still logged');
    Gone('{"_edge_token" : "717ED496B64F45DA83CD773356F0EE86"}', '717ED496B64F45DA83CD773356F0EE86', '_edge_token');
    Gone('{"password":"HUNTER2PASSWORD","user":"bob"}', 'HUNTER2PASSWORD', 'password member');
    Has ('{"password":"HUNTER2PASSWORD","user":"bob"}', '"user":"bob"', 'user name member survives');
    Gone('{"api_key":"K1","client_secret":"CS2","access_token":"AT3","refresh_token":"RT4","x-api-key":"XK5"}', 'RT4', 'refresh_token');
    Gone('{"api_key":"K1","client_secret":"CS2","access_token":"AT3","refresh_token":"RT4","x-api-key":"XK5"}', 'XK5', 'x-api-key');

    WriteLn('-- bodies');
    Gone('{ "method" : "POST", "body" : "username=bob&amp;note=PRIVATE TEXT" }', 'PRIVATE TEXT', 'body removed when RedactBodies is on');
    Has ('{ "method" : "POST", "body" : "x" }', '"method" : "POST"', 'method kept');
    Gone('{"body_b64":"U0VDUkVUQk9EWQ=="}', 'U0VDUkVUQk9EWQ', 'body_b64 removed');
    R.RedactBodies := False;
    Has ('{ "body" : "just some text" }', 'just some text', 'body kept when RedactBodies is off');
    Gone('{ "body" : "password=HUNTER2PASSWORD&x=1" }', 'HUNTER2PASSWORD', 'but a password= pair inside a kept body is still masked');
    R.RedactBodies := True;

    WriteLn('-- query strings / form fields');
    Gone('"query" : "api_key=URLQUERYSECRET&page=2"', 'URLQUERYSECRET', 'api_key= in a query string');
    Has ('"query" : "api_key=URLQUERYSECRET&page=2"', 'page=2', 'other parameters survive');
    Gone('/x.py?access_token=AAA111&refresh-token=BBB222&sig=CCC333', 'BBB222', 'refresh-token=');
    Gone('/x.py?session=S1D2&sid=ZZ99', 'ZZ99', 'sid=');
    Gone('GET /cb?code=1&password=pw123 HTTP/1.1', 'pw123', 'password= in a request line');
    Same('"query" : "monkey=banana&author=jane&page=2"', 'monkey= / author= are not mistaken for key= / auth=');

    WriteLn('-- schemes');
    Gone('Authorization: Bearer abcdef1234567890', 'abcdef1234567890', 'Bearer credential in plain text');
    Gone('proxy said Basic dXNlcjpwYXNzd29yZA== ok', 'dXNlcjpwYXNzd29yZA', 'Basic credential in plain text');
    Same('the Basic idea of it', 'ordinary words are left alone');

    WriteLn('-- must not touch');
    Same('{"method":"GET","path":"/index.py","remote_addr":"10.0.0.5","status":200}', 'an ordinary request line is unchanged');
    Same('{"token_count":"5","tokenizer":"x","secrets_found":0}', 'similar-looking member names are unchanged');
    Same('', 'empty string');
    Same('[INFO] ws.conn.1: authenticated (profile "viewer")', 'a log message is unchanged');

    WriteLn('-- properties');
    Check(R.Redact(R.Redact('{"token":"T","body":"B"}')) = R.Redact('{"token":"T","body":"B"}'), 'redacting twice gives the same result');
  finally
    R.Free;
  end;
  WriteLn;
  WriteLn(Passed, ' passed, ', Failed, ' failed');
  if Failed > 0 then Halt(1);
end.
