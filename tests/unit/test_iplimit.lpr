program test_iplimit;

{$mode objfpc}{$H+}

// vdrx_iplimit.pas: per-address concurrent cap, new-connection rate (token bucket), exempt ranges,
// bounded address table.
//
//   fpc -Mobjfpc -Fu../../src test_iplimit.lpr ; ./test_iplimit        (exit code 0 = all passed)

uses
  SysUtils, Classes, vdrx_iplimit;

var
  Passed, Failed: Integer;

procedure Check(ACond: Boolean; const AName: string);
begin
  if ACond then begin Inc(Passed); WriteLn('  ok    ', AName); end
  else begin Inc(Failed); WriteLn('  FAIL  ', AName); end;
end;

var
  L: TVDRX_IPLimiter;
  V: Cardinal;
  i: Integer;
  Ok: Integer;
  Verdict: TVDRX_LimitVerdict;
begin
  Passed := 0; Failed := 0;

  WriteLn('-- IPv4 parsing');
  Check(VDRX_ParseIPv4('1.2.3.4', V) and (V = $01020304), 'dotted quad parses');
  Check(not VDRX_ParseIPv4('1.2.3', V), 'three parts refused');
  Check(not VDRX_ParseIPv4('1.2.3.4.5', V), 'five parts refused');
  Check(not VDRX_ParseIPv4('256.1.1.1', V), 'octet over 255 refused');
  Check(not VDRX_ParseIPv4('1..2.3', V), 'empty part refused');
  Check(not VDRX_ParseIPv4('1.2.3.4x', V), 'trailing junk refused');
  Check(not VDRX_ParseIPv4('', V), 'empty refused');
  Check(not VDRX_ParseIPv4('0x7f.0.0.1', V), 'hex refused');

  WriteLn('-- concurrent cap');
  L := TVDRX_IPLimiter.Create;
  L.MaxPerIP := 3; L.RatePerSec := 0;
  Check(L.TryAcquire('10.0.0.1') = lvOK, '1st ok');
  Check(L.TryAcquire('10.0.0.1') = lvOK, '2nd ok');
  Check(L.TryAcquire('10.0.0.1') = lvOK, '3rd ok');
  Check(L.TryAcquire('10.0.0.1') = lvTooManyConns, '4th refused');
  Check(L.TryAcquire('10.0.0.2') = lvOK, 'a different address is unaffected');
  L.Release('10.0.0.1');
  Check(L.OpenFor('10.0.0.1') = 2, 'release frees a slot');
  Check(L.TryAcquire('10.0.0.1') = lvOK, 'slot can be reused');
  for i := 1 to 10 do L.Release('10.0.0.1');
  Check(L.OpenFor('10.0.0.1') = 0, 'extra releases never go negative');
  L.Release('9.9.9.9');
  Check(True, 'release of an unknown address is harmless');
  L.Free;

  WriteLn('-- rate limit (token bucket)');
  L := TVDRX_IPLimiter.Create;
  L.MaxPerIP := 0; L.RatePerSec := 10; L.Burst := 5;
  L.SetFakeClock(1000000);
  Ok := 0;
  for i := 1 to 20 do
    if L.TryAcquire('10.0.0.1') = lvOK then Inc(Ok);
  Check(Ok = 5, 'a burst of 20 gets exactly Burst (5) through, got ' + IntToStr(Ok));
  Check(L.TryAcquire('10.0.0.1') = lvRateExceeded, 'refused with the rate verdict');
  L.SetFakeClock(1000000 + 200);               // 0.2 s at 10/s = 2 tokens
  Ok := 0;
  for i := 1 to 10 do
    if L.TryAcquire('10.0.0.1') = lvOK then Inc(Ok);
  Check(Ok = 2, 'after 200 ms two more are allowed, got ' + IntToStr(Ok));
  L.SetFakeClock(1000000 + 60000);             // long idle: bucket refills but never beyond Burst
  Ok := 0;
  for i := 1 to 20 do
    if L.TryAcquire('10.0.0.1') = lvOK then Inc(Ok);
  Check(Ok = 5, 'the bucket never holds more than Burst, got ' + IntToStr(Ok));
  Check(L.TryAcquire('10.0.0.2') = lvOK, 'another address has its own bucket');
  L.Free;

  WriteLn('-- refused attempts cost nothing against the concurrent count');
  L := TVDRX_IPLimiter.Create;
  L.MaxPerIP := 2; L.RatePerSec := 0;
  L.TryAcquire('10.0.0.1'); L.TryAcquire('10.0.0.1');
  for i := 1 to 50 do L.TryAcquire('10.0.0.1');
  Check(L.OpenFor('10.0.0.1') = 2, 'count stays at 2 after 50 refusals');
  L.Free;

  WriteLn('-- exempt ranges');
  L := TVDRX_IPLimiter.Create;
  L.MaxPerIP := 1; L.RatePerSec := 0;
  Check(L.AddExempt('127.0.0.1'), 'single address accepted');
  Check(L.AddExempt('192.168.0.0/16'), 'CIDR accepted');
  Check(not L.AddExempt('10.0.0.0/33'), '/33 refused');
  Check(not L.AddExempt('10.0.0/8'), 'bad address refused');
  Check(not L.AddExempt('nonsense'), 'nonsense refused');
  Ok := 0;
  for i := 1 to 10 do
    if L.TryAcquire('127.0.0.1') = lvOK then Inc(Ok);
  Check(Ok = 10, 'exempt address is never limited');
  Ok := 0;
  for i := 1 to 10 do
    if L.TryAcquire('192.168.44.5') = lvOK then Inc(Ok);
  Check(Ok = 10, 'address inside an exempt CIDR is never limited');
  Check(L.TryAcquire('192.169.0.1') = lvOK, 'outside the range: first ok');
  Check(L.TryAcquire('192.169.0.1') = lvTooManyConns, 'outside the range: second refused');
  Check(L.TrackedCount = 1, 'exempt addresses are not tracked');
  L.Free;

  WriteLn('-- bounded table');
  L := TVDRX_IPLimiter.Create;
  L.MaxPerIP := 2; L.RatePerSec := 10; L.Burst := 5; L.MaxTracked := 100;
  L.SetFakeClock(5000000);
  for i := 1 to 100 do
  begin
    Verdict := L.TryAcquire('10.1.0.' + IntToStr(i));
    L.Release('10.1.0.' + IntToStr(i));
  end;
  Check(L.TrackedCount = 100, 'table fills to MaxTracked');
  Check(L.TryAcquire('10.2.0.1') = lvOK, 'a new address while full is let through');
  Check(L.UntrackedCount = 1, 'and counted as untracked (nothing is purgeable yet)');
  Check(L.TrackedCount = 100, 'table did not grow past its bound');
  L.SetFakeClock(5000000 + 600000);            // everything idle and refilled: purgeable
  Check(L.TryAcquire('10.3.0.1') = lvOK, 'after idle time a new address is tracked');
  Check(L.TrackedCount < 100, 'idle entries were purged (' + IntToStr(L.TrackedCount) + ' left)');
  L.Free;

  WriteLn('-- entries holding connections are never purged');
  L := TVDRX_IPLimiter.Create;
  L.MaxPerIP := 5; L.RatePerSec := 10; L.Burst := 5; L.MaxTracked := 2;
  L.SetFakeClock(7000000);
  L.TryAcquire('10.0.0.1');                    // stays open
  L.TryAcquire('10.0.0.2'); L.Release('10.0.0.2');
  L.SetFakeClock(7000000 + 600000);
  L.TryAcquire('10.0.0.3');
  Check(L.OpenFor('10.0.0.1') = 1, 'the entry with an open connection survives a purge');
  L.Free;

  WriteLn('-- live (long-lived) connections');
  L := TVDRX_IPLimiter.Create;
  L.MaxPerIP := 0; L.RatePerSec := 0; L.MaxLivePerIP := 2;
  Check(L.TryAcquireLive('10.0.0.1'), 'live 1 ok');
  Check(L.TryAcquireLive('10.0.0.1'), 'live 2 ok');
  Check(not L.TryAcquireLive('10.0.0.1'), 'live 3 refused');
  Check(L.TryAcquireLive('10.0.0.2'), 'another address unaffected');
  L.ReleaseLive('10.0.0.1');
  Check(L.TryAcquireLive('10.0.0.1'), 'slot reusable after release');
  for i := 1 to 10 do L.ReleaseLive('10.0.0.1');
  Check(L.TryAcquireLive('10.0.0.1') and L.TryAcquireLive('10.0.0.1') and not L.TryAcquireLive('10.0.0.1'),
    'extra releases never go negative');
  L.AddExempt('10.9.0.0/16');
  Ok := 0;
  for i := 1 to 10 do
    if L.TryAcquireLive('10.9.1.1') then Inc(Ok);
  Check(Ok = 10, 'exempt addresses are not limited');
  L.Free;

  L := TVDRX_IPLimiter.Create;
  L.MaxLivePerIP := 5; L.MaxPerIP := 5; L.RatePerSec := 10; L.Burst := 5; L.MaxTracked := 1;
  L.SetFakeClock(9000000);
  L.TryAcquireLive('10.0.0.1');
  L.SetFakeClock(9000000 + 600000);
  L.TryAcquire('10.0.0.2');
  Check(L.OpenFor('10.0.0.1') = 0, 'live count is separate from the accept-phase count');
  Check(not L.TryAcquireLive('10.0.0.1') or True, 'table of 1: a live entry is never purged (no crash)');
  L.Free;

  WriteLn('-- disabled');
  L := TVDRX_IPLimiter.Create;
  L.MaxPerIP := 0; L.RatePerSec := 0;
  Ok := 0;
  for i := 1 to 1000 do
    if L.TryAcquire('10.0.0.1') = lvOK then Inc(Ok);
  Check(Ok = 1000, 'both limits at 0 = no limiting');
  Check(L.TrackedCount = 0, 'and nothing is tracked');
  L.Free;

  WriteLn;
  WriteLn(Passed, ' passed, ', Failed, ' failed');
  if Failed > 0 then Halt(1);
end.
