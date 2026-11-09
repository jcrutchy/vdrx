program test_spawn;

{$mode objfpc}{$H+}

// Tests for the small pure functions behind process spawning and static serving:
// the clean child environment, NUL handling in the UTF-8 checks, the .bat/.cmd argument rule and
// the static-file deny list.
//
//   fpc -Mobjfpc -Fu../../src test_spawn.lpr ; ./test_spawn        (exit code 0 = all passed)

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, fpjson, jsonparser, vdrx_cgi, openssl, {$IFDEF UNIX}dynlibs,{$ENDIF} vdrx_procutil, vdrx_runner, vdrx_network;

var
  Passed, Failed: Integer;

procedure Check(ACond: Boolean; const AName: string);
begin
  if ACond then begin Inc(Passed); WriteLn('  ok    ', AName); end
  else begin Inc(Failed); WriteLn('  FAIL  ', AName); end;
end;

function Has(L: TStrings; const AName: string): Boolean;
var i: Integer;
begin
  for i := 0 to L.Count - 1 do
    if SameText(Copy(L[i], 1, Length(AName) + 1), AName + '=') then Exit(True);
  Result := False;
end;

function ValueOf(L: TStrings; const AName: string): string;
var i: Integer;
begin
  for i := 0 to L.Count - 1 do
    if SameText(Copy(L[i], 1, Length(AName) + 1), AName + '=') then Exit(Copy(L[i], Length(AName) + 2, MaxInt));
  Result := '<unset>';
end;

procedure TestEnvironment;
var
  Daemon, Extra, Pass, Dest: TStringList;
begin
  WriteLn('-- clean child environment');
  Daemon := TStringList.Create; Extra := TStringList.Create; Pass := TStringList.Create; Dest := TStringList.Create;
  try
    Daemon.CommaText := 'PATH=/usr/bin:/bin,HOME=/root,LANG=en_AU.UTF-8,LC_TIME=C,TZ=UTC,DB_PASSWORD=hunter2,AWS_SECRET_ACCESS_KEY=AKIAFAKE,SYSTEMROOT=C:\Windows,Path2=nope,=C:=C:\x';
    Extra.Add('REQUEST_METHOD=GET'); Extra.Add('QUERY_STRING=a=b');

    BuildChildEnvironment(Daemon, Extra, False, nil, Dest);
    Check(not Has(Dest, 'DB_PASSWORD'), 'a daemon secret (DB_PASSWORD) is not passed on');
    Check(not Has(Dest, 'AWS_SECRET_ACCESS_KEY'), 'a cloud key is not passed on');
    Check(not Has(Dest, 'HOME'), 'HOME is not passed on');
    Check(ValueOf(Dest, 'PATH') = '/usr/bin:/bin', 'PATH is passed on');
    Check(Has(Dest, 'LANG') and Has(Dest, 'LC_TIME') and Has(Dest, 'TZ'), 'locale and time zone variables are passed on (LANG, LC_*, TZ)');
    Check(Has(Dest, 'SYSTEMROOT'), 'what Windows programs need to start (SYSTEMROOT) is passed on');
    Check(not Has(Dest, 'Path2'), 'a name that merely starts like an allowed one is not');
    Check(ValueOf(Dest, 'REQUEST_METHOD') = 'GET', 'the CGI variables are added');

    Pass.Add('DB_PASSWORD');
    BuildChildEnvironment(Daemon, Extra, False, Pass, Dest);
    Check(Has(Dest, 'DB_PASSWORD') and not Has(Dest, 'AWS_SECRET_ACCESS_KEY'), 'child_env_passthrough passes exactly the named variable');
    Pass.Clear; Pass.Add('db_password');
    BuildChildEnvironment(Daemon, Extra, False, Pass, Dest);
    Check(Has(Dest, 'DB_PASSWORD'), 'passthrough names match case-insensitively');

    BuildChildEnvironment(Daemon, Extra, True, nil, Dest);
    Check(Has(Dest, 'DB_PASSWORD') and Has(Dest, 'HOME') and Has(Dest, 'REQUEST_METHOD'), 'child_env_inherit passes everything, plus the CGI variables');

    Daemon.Add('QUERY_STRING=from-the-daemon');
    BuildChildEnvironment(Daemon, Extra, True, nil, Dest);
    Check(ValueOf(Dest, 'QUERY_STRING') = 'a=b', 'a request variable replaces a same-named daemon variable (inherit mode)');
    Check(Dest.IndexOf('QUERY_STRING=from-the-daemon') < 0, '... and the old line is gone, not duplicated');

    Daemon.Clear; Extra.Clear;
    BuildChildEnvironment(Daemon, Extra, False, nil, Dest);
    Check(Dest.Count > 0, 'never empty (an empty list would make the child inherit everything)');
  finally
    Dest.Free; Pass.Free; Extra.Free; Daemon.Free;
  end;
end;

procedure TestUTF8;
begin
  WriteLn('-- NUL bytes are not "text"');
  Check(IsValidUTF8('plain text'), 'ordinary text is valid');
  Check(IsValidUTF8('caf' + #$C3#$A9), 'a UTF-8 sequence is valid');
  Check(not IsValidUTF8('abc' + #0 + 'def'), 'a NUL byte makes it not text (so it travels as base64 and arrives intact)');
  Check(not IsValidUTF8(#0), 'a lone NUL');
  Check(not IsValidUTF8(#$FF#$FE), 'an invalid sequence still fails');
  Check(CleanUTF8('ab' + #0 + 'cd') = 'ab?cd', 'CleanUTF8 replaces a NUL with ?');
  Check(CleanUTF8('ok') = 'ok', 'CleanUTF8 leaves text alone');
end;

procedure TestBatch;
begin
  WriteLn('-- .bat / .cmd programs (cmd.exe re-parses the command line)');
  Check(IsBatchScript('C:\tools\run.bat') and IsBatchScript('x.CMD') and IsBatchScript('/opt/job.cmd'), 'batch files are recognised (any case, any path style)');
  Check(not IsBatchScript('python') and not IsBatchScript('run.sh') and not IsBatchScript('batch') and not IsBatchScript('a.bat.exe'), 'other programs are not');
  Check(HasBatchMetaChars('a & calc') and HasBatchMetaChars('x|y') and HasBatchMetaChars('a>b') and HasBatchMetaChars('%PATH%') and
        HasBatchMetaChars('say "hi"') and HasBatchMetaChars('a^b') and HasBatchMetaChars('(x)') and HasBatchMetaChars('hi!') and
        HasBatchMetaChars('a' + #10 + 'b'), 'every cmd.exe metacharacter is caught');
  Check(not HasBatchMetaChars('report-2024_final.pdf') and not HasBatchMetaChars('a b c') and not HasBatchMetaChars('42'), 'ordinary values pass');
end;

procedure TestCGIEnv;
var
  Req: TJSONObject;
  Env: TStringList;
  i, Bad: Integer;
begin
  WriteLn('-- CGI environment built from a hostile request');
  Req := TJSONObject(GetJSON('{"method":"GET","server_port":"80' + '\u0000EVIL=1","remote_port":"1\r\nX=2","query":"a=1\u0000B=2",' +
    '"path_info":"/x\ny","headers":{"Proxy":"http://evil/","X.Foo":"1","X-Ok":"fine\r\nInjected: 1","Content-Type":"t\u0000x","Bad Name":"v","":"v"}}'));
  Env := TStringList.Create;
  try
    BuildCGIEnv(Req, '', Env);
    Bad := 0;
    for i := 0 to Env.Count - 1 do
      if (Pos(#0, Env[i]) > 0) or (Pos(#10, Env[i]) > 0) or (Pos(#13, Env[i]) > 0) then Inc(Bad);
    Check(Bad = 0, 'no variable contains NUL, CR or LF (every one could otherwise inject another)');
    Check((Env.IndexOfName('EVIL') < 0) and (Env.IndexOfName('X') < 0) and (Env.IndexOfName('B') < 0), 'no extra variable can be smuggled in through a value');
    Check(Env.IndexOfName('HTTP_PROXY') < 0, 'a Proxy request header never becomes HTTP_PROXY (httpoxy)');
    Check(Env.Values['HTTP_X_OK'] = 'fine  Injected: 1', 'a header value with CR/LF is flattened, and its name maps to HTTP_X_OK');
    Check((Pos(#0, Env.Values['SERVER_PORT']) = 0) and (Env.Values['REMOTE_PORT'] = '1  X=2'), 'ports are sanitised like every other value');
    Check(Env.Values['REDIRECT_STATUS'] = '200', 'REDIRECT_STATUS is still set for php-cgi');
  finally
    Env.Free;
    Req.Free;
  end;
end;

procedure TestURLPaths;
var
  S: TStringList;
  function Ok(const P: string): Boolean;
  begin
    Result := SplitURLPath(P, S);
  end;
begin
  WriteLn('-- URL path splitting (what may reach the file system)');
  S := TStringList.Create;
  try
    Check(Ok('/app/index.php') and (S.Count = 2) and (S[1] = 'index.php'), 'an ordinary path splits into its segments');
    Check(Ok('/.well-known/acme') and Ok('/a//b/./c') and (S.Count = 3), '.well-known is allowed; empty and "." segments are dropped');
    Check(not Ok('/a/../b') and not Ok('/%2e%2e/b') and not Ok('/a/%2E%2E/b'), '".." is refused, also percent-encoded');
    Check(not Ok('/.git/config') and not Ok('/a/.env') and not Ok('/%2egit/x'), 'dot-files are refused');
    Check(not Ok('/a\b') and not Ok('/a%5cb') and not Ok('/a%00b') and not Ok('/f.txt:stream') and not Ok('/C:/x'), 'backslash, NUL and ":" are refused');
    Check(not Ok('/x.php.') and not Ok('/x.php%20') and not Ok('/x.php '), 'trailing dot or space is refused (Windows ignores them)');
    Check(not Ok('/GIT~1/config') and not Ok('/PROGRA~1/x') and not Ok('/a/DOCUME~2.TXT') and not Ok('/git~1'), '8.3 short-name aliases (GIT~1 is how NTFS names .git) are refused');
    Check(Ok('/report~final.pdf') and Ok('/a~b/c') and Ok('/notes~.txt') and Ok('/verylongname~1/x'), 'ordinary names containing "~" still work');
    Check(not Ok('/con') and not Ok('/NUL.txt') and not Ok('/a/Aux.log') and not Ok('/com1') and not Ok('/LPT9.x') and not Ok('/conin$'), 'Windows device names are refused, any case, any extension');
    Check(Ok('/console') and Ok('/com10') and Ok('/auxiliary.txt') and Ok('/lpt') and Ok('/nullable'), 'names that merely start like a device name still work');
  finally
    S.Free;
  end;
end;

procedure TestStatic;
begin
  WriteLn('-- static file deny list');
  VDRX_ConfigureStaticPolicy([], [], False);
  Check(VDRX_StaticDenied('/srv/x/vdrx.conf') and VDRX_StaticDenied('a.LOG') and VDRX_StaticDenied('k.pem') and VDRX_StaticDenied('t.key'), 'config, log and key files are denied (any case)');
  Check(VDRX_StaticDenied('page.php') and VDRX_StaticDenied('x.py') and VDRX_StaticDenied('run.sh') and VDRX_StaticDenied('go.bat'), 'script source is denied');
  Check(VDRX_StaticDenied('dump.sql') and VDRX_StaticDenied('site.bak') and VDRX_StaticDenied('data.sqlite') and VDRX_StaticDenied('prod.env'), 'backups, databases and *.env files are denied (a bare .env is a dot-file, refused earlier by SplitURLPath)');
  Check(not VDRX_StaticDenied('index.html') and not VDRX_StaticDenied('app.js') and not VDRX_StaticDenied('logo.png') and not VDRX_StaticDenied('noext') and not VDRX_StaticDenied('notes.txt'), 'normal web files are not');
  Check(VDRX_StaticDenied('backup.php.bak') and not VDRX_StaticDenied('conf.html'), 'the LAST extension decides');
  VDRX_ConfigureStaticPolicy(['.TXT', 'md'], ['php'], False);
  Check(VDRX_StaticDenied('notes.txt') and VDRX_StaticDenied('r.md'), 'static_deny_extensions adds (with or without a dot, any case)');
  Check(not VDRX_StaticDenied('page.php') and VDRX_StaticDenied('x.conf'), 'static_allow_extensions removes one entry and leaves the rest');
  VDRX_ConfigureStaticPolicy([], [], False);
end;

{$IFDEF UNIX}
function TempSslDirs: Integer;
var SR: TSearchRec;
begin
  Result := 0;
  if FindFirst(IncludeTrailingPathDelimiter(GetTempDir(False)) + 'vdrx-ssl-*', faAnyFile, SR) = 0 then
  begin
    repeat Inc(Result); until FindNext(SR) <> 0;
    FindClose(SR);
  end;
end;

// Runs on any machine that has an OpenSSL RUNTIME, with or without the -dev package: the binding is
// first pointed at a library name that does not exist, as it would be on a server where only the
// versioned libssl.so.3 is installed.
procedure TestOpenSSL;
var
  Before: Integer;
  Ctx: PSSL_CTX;
  H: TLibHandle;
begin
  WriteLn('-- finding OpenSSL when only the versioned library exists');
  H := LoadLibrary('libssl.so.3');
  if H = NilHandle then H := LoadLibrary('libssl.so.1.1');
  if H = NilHandle then begin WriteLn('  skip  no OpenSSL runtime library on this machine'); Exit; end;
  Before := TempSslDirs;
  DLLSSLName := 'libssl_vdrx_test_missing';
  DLLUtilName := 'libcrypto_vdrx_test_missing';
  Check(VDRX_EnsureOpenSSL, 'a missing default name is recovered from the versioned library');
  Check(Pos('libssl.so', VDRX_OpenSSLNote) = 1, 'and it says so (' + VDRX_OpenSSLNote + ')');
  Ctx := SslCtxNew(SslTLSMethod);
  Check(Assigned(Ctx), 'a TLS context can be created afterwards');
  if Assigned(Ctx) then SslCtxFree(Ctx);
  Check(TempSslDirs = Before, 'no temporary directory is left behind');
  Check(VDRX_EnsureOpenSSL, 'asking again is cheap and gives the same answer');
end;
{$ENDIF}

begin
  Passed := 0; Failed := 0;
  {$IFDEF UNIX}TestOpenSSL;{$ENDIF}
  TestEnvironment;
  TestUTF8;
  TestBatch;
  TestStatic;
  TestURLPaths;
  TestCGIEnv;
  WriteLn;
  WriteLn(Passed, ' passed, ', Failed, ' failed');
  if Failed > 0 then Halt(1);
end.
