program test_spawn;

{$mode objfpc}{$H+}

// Tests for the small pure functions behind process spawning and static serving:
// the clean child environment, NUL handling in the UTF-8 checks, the .bat/.cmd argument rule and
// the static-file deny list.
//
//   fpc -Mobjfpc -Fu../../src test_spawn.lpr ; ./test_spawn        (exit code 0 = all passed)

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, vdrx_procutil, vdrx_runner, vdrx_network;

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

begin
  Passed := 0; Failed := 0;
  TestEnvironment;
  TestUTF8;
  TestBatch;
  TestStatic;
  WriteLn;
  WriteLn(Passed, ' passed, ', Failed, ' failed');
  if Failed > 0 then Halt(1);
end.
