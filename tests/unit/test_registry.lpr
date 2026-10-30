program test_registry;

{$mode objfpc}{$H+}

// The subscription registry (vdrx_core.pas). It used to leave an empty table entry behind for every
// literal filter that was ever subscribed - and the bus request/reply path subscribes a fresh filter
// per request - so the table, and the time every unregister spent walking it, grew without bound.
//
//   fpc -Mobjfpc -Fu../../src test_registry.lpr ; ./test_registry        (exit code 0 = all passed)

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, vdrx_core;

type
  TDummy = class(TVDRX_Executive)
  public
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
  end;

procedure TDummy.HandlePacket(const AMsg: TVDRX_Message);
begin
end;

var
  Passed, Failed: Integer;

procedure Check(ACond: Boolean; const AName: string);
begin
  if ACond then begin Inc(Passed); WriteLn('  ok    ', AName); end
  else begin Inc(Failed); WriteLn('  FAIL  ', AName); end;
end;

function Subs(R: TVDRX_Registry; const ATopic: string): Integer;
var L: TVDRX_ExecList;
begin
  L := R.GetSubscribers(ATopic);
  try Result := L.Count; finally L.Free; end;
end;

function TimeChurn(R: TVDRX_Registry; ACycles: Integer): QWord;
var
  i: Integer;
  T: QWord;
begin
  T := GetTickCount64;
  for i := 1 to ACycles do
  begin
    R.Register(TDummy.Create(nil), 'churn' + IntToStr(i), 'churn.reply.' + IntToStr(i));
    R.Unregister('churn' + IntToStr(i));
  end;
  Result := GetTickCount64 - T;
end;

var
  R: TVDRX_Registry;
  i: Integer;
  Base: Integer;
  TSmall, TBig: QWord;
begin
  Passed := 0; Failed := 0;
  R := TVDRX_Registry.Create;
  try
    WriteLn('-- the table does not keep entries for filters nobody uses');
    Base := R.LiteralFilterCount;
    for i := 1 to 3000 do R.Register(TDummy.Create(nil), 'e' + IntToStr(i), 'reply.' + IntToStr(i));
    Check(R.LiteralFilterCount = Base + 3000, '3000 executives with a filter each: 3000 table entries');
    for i := 1 to 3000 do R.Unregister('e' + IntToStr(i));
    Check(R.LiteralFilterCount = Base, 'after unregistering them all the table is back to where it started (was: 3000 left behind)');

    WriteLn('-- shared and multiple filters');
    R.Register(TDummy.Create(nil), 'a', 'shared.x');
    R.Register(R.Find('a'), 'a', 'only.a1');
    R.Register(R.Find('a'), 'a', 'only.a2');
    R.Register(R.Find('a'), 'a', 'wild.>');
    R.Register(TDummy.Create(nil), 'b', 'shared.x');
    Check(Subs(R, 'shared.x') = 2, 'two executives on one filter both receive it');
    R.Unregister('a');
    Check((Subs(R, 'shared.x') = 1) and (Subs(R, 'only.a1') = 0) and (Subs(R, 'only.a2') = 0) and (Subs(R, 'wild.q') = 0), 'unregistering one removes all of ITS filters (literal and wildcard) and keeps the other''s');
    Check(R.LiteralFilterCount = Base + 1, 'the shared filter stays while someone still uses it, the others are gone');
    R.Unregister('b');
    Check(R.LiteralFilterCount = Base, 'and goes when the last user goes');

    WriteLn('-- UnregisterFilter / ClearFilters');
    R.Register(TDummy.Create(nil), 'c', 'c.one');
    R.Register(R.Find('c'), 'c', 'c.two');
    R.UnregisterFilter('c', 'c.one');
    Check((Subs(R, 'c.one') = 0) and (Subs(R, 'c.two') = 1) and (R.LiteralFilterCount = Base + 1), 'UnregisterFilter drops that filter (and its entry) only');
    R.UnregisterFilter('c', 'c.one');
    R.UnregisterFilter('c', 'no.such');
    Check(R.LiteralFilterCount = Base + 1, 'removing a filter twice, or one never added, is harmless');
    R.ClearFilters('c');
    Check((R.Find('c') <> nil) and (Subs(R, 'c.two') = 0) and (R.LiteralFilterCount = Base), 'ClearFilters drops every filter but keeps the executive registered');
    R.Register(R.Find('c'), 'c', 'c.again');
    Check(Subs(R, 'c.again') = 1, 'and it can subscribe again afterwards');
    R.Unregister('c');
    Check(R.LiteralFilterCount = Base, 'clean again');

    WriteLn('-- the cost of an unregister does not depend on how many filters exist');
    TSmall := TimeChurn(R, 4000);
    for i := 1 to 20000 do R.Register(TDummy.Create(nil), 'perm' + IntToStr(i), 'perm.' + IntToStr(i));
    TBig := TimeChurn(R, 4000);
    WriteLn('        4000 register+unregister cycles: ', TSmall, ' ms with ~0 other filters, ', TBig, ' ms with 20000');
    Check(TBig < TSmall * 6 + 50, 'it takes about as long with 20000 filters in the table as with none (was: proportional to the table size)');
    Check(R.LiteralFilterCount = Base + 20000, 'and the churn left nothing behind');
  finally
    R.Free;
  end;
  WriteLn;
  WriteLn(Passed, ' passed, ', Failed, ' failed');
  if Failed > 0 then Halt(1);
end.
