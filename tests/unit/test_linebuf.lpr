program test_linebuf;

{$mode objfpc}{$H+}

// vdrx_linebuf.pas: line splitting with a hard limit on how much of an unfinished line is held.
//
//   fpc -Mobjfpc -Fu../../src test_linebuf.lpr ; ./test_linebuf        (exit code 0 = all passed)

uses
  SysUtils, Classes, vdrx_linebuf;

var
  Passed, Failed: Integer;

procedure Check(ACond: Boolean; const AName: string);
begin
  if ACond then begin Inc(Passed); WriteLn('  ok    ', AName); end
  else begin Inc(Failed); WriteLn('  FAIL  ', AName); end;
end;

function FeedStr(B: TVDRX_LineBuffer; const S: string; L: TStrings): Boolean;
begin
  if S = '' then Exit(False);
  Result := B.Feed(S[1], Length(S), L);
end;

var
  B: TVDRX_LineBuffer;
  L: TStringList;
  Big: string;
  i: Integer;
  Over: Boolean;
begin
  Passed := 0; Failed := 0;
  L := TStringList.Create;

  WriteLn('-- splitting');
  B := TVDRX_LineBuffer.Create(1024);
  FeedStr(B, 'one'#10'two'#13#10'thr', L);
  Check((L.Count = 2) and (L[0] = 'one') and (L[1] = 'two'), 'LF and CRLF lines are split, CR removed');
  Check(B.Pending = 3, 'unfinished tail is held');
  L.Clear; FeedStr(B, 'ee'#10, L);
  Check((L.Count = 1) and (L[0] = 'three'), 'a line completes across feeds');
  L.Clear; FeedStr(B, #10#10, L);
  Check((L.Count = 2) and (L[0] = '') and (L[1] = ''), 'empty lines are reported (callers filter)');
  L.Clear; FeedStr(B, 'a'#13'b'#10, L);
  Check((L.Count = 1) and (L[0] = 'ab'), 'a bare CR is removed');
  L.Clear; FeedStr(B, 'x'#0'y'#10, L);
  Check((L.Count = 1) and (L[0] = 'x'#0'y'), 'NUL bytes pass through untouched');
  B.Free;

  WriteLn('-- the limit');
  B := TVDRX_LineBuffer.Create(1024);
  L.Clear;
  Big := StringOfChar('A', 1024) + #10;
  Over := FeedStr(B, Big, L);
  Check((not Over) and (L.Count = 1) and (Length(L[0]) = 1024), 'a line of exactly the limit is accepted');
  L.Clear;
  Big := StringOfChar('B', 1025) + #10 + 'ok'#10;
  Over := FeedStr(B, Big, L);
  Check(Over, 'a line one byte over the limit is reported');
  Check((L.Count = 1) and (L[0] = 'ok'), 'the over-long line is dropped, the next one is intact');
  Check(B.Dropped = 1, 'drops are counted');
  B.Free;

  WriteLn('-- memory stays bounded');
  B := TVDRX_LineBuffer.Create(4096);
  L.Clear; Over := False;
  Big := StringOfChar('C', 1000);
  for i := 1 to 5000 do                       // 5 MB with no newline
  begin
    if FeedStr(B, Big, L) then Over := True;
    if B.Pending > 4096 then begin Check(False, 'pending exceeded the limit'); Break; end;
  end;
  Check(Over and (B.Pending <= 4096) and (L.Count = 0), '5 MB without a newline: reported once, nothing buffered beyond the limit, nothing emitted');
  Check(B.Dropped = 1, 'one endless line counts as one drop, not one per chunk');
  L.Clear; FeedStr(B, 'tail'#10'next'#10, L);
  Check((L.Count = 1) and (L[0] = 'next'), 'after the endless line finally ends, the buffer recovers at the next line');
  B.Free;

  WriteLn('-- byte-at-a-time feeding matches bulk feeding');
  B := TVDRX_LineBuffer.Create(1024);
  L.Clear;
  Big := 'abc'#10 + StringOfChar('D', 1025) + #10'z'#10;
  for i := 1 to Length(Big) do
    FeedStr(B, Copy(Big, i, 1), L);
  Check((L.Count = 2) and (L[0] = 'abc') and (L[1] = 'z') and (B.Dropped = 1), 'same result fed one byte at a time');
  B.Free;

  WriteLn('-- limit clamping');
  Check(VDRX_ClampMaxLineBytes(0) = VDRX_DEFAULT_MAX_LINE_BYTES, '0 / unset gives the default');
  Check(VDRX_ClampMaxLineBytes(-5) = VDRX_DEFAULT_MAX_LINE_BYTES, 'negative gives the default');
  Check(VDRX_ClampMaxLineBytes(10) = VDRX_MIN_MAX_LINE_BYTES, 'tiny values are raised to the minimum');
  Check(VDRX_ClampMaxLineBytes(MaxInt) = VDRX_MAX_MAX_LINE_BYTES, 'huge values are capped');
  Check(VDRX_ClampMaxLineBytes(5000) = 5000, 'sane values are kept');

  L.Free;
  WriteLn;
  WriteLn(Passed, ' passed, ', Failed, ' failed');
  if Failed > 0 then Halt(1);
end.
