program test_topiccover;

{$mode objfpc}{$H+}

// Property test for the access-control rule behind ws_profiles subscribe_allow / publish_allow.
//
// TopicFilterCovers(Allow, Filter) must be SOUND: whenever it says "yes", every topic that Filter matches
// is also matched by Allow (otherwise a client could subscribe to / publish on topics its profile does not
// allow). It is checked exhaustively against TopicMatches (the bus's own matcher) over every pattern of up
// to 3 segments drawn from {a, b, *, >, empty} and every topic of up to 4 segments drawn from {a, b, c, empty}.
// Completeness (answering "no" for something that would in fact be allowed) only costs usability, so it is
// reported, not failed.
//
//   fpc -Mobjfpc -Fu../../src test_topiccover.lpr ; ./test_topiccover        (exit code 0 = all passed)

uses
  {$IFDEF UNIX}cthreads, {$ENDIF}   Classes, SysUtils, vdrx_core, vdrx_websocket;

const
  PatSegs: array[0..4] of string = ('a', 'b', '*', '>', '');
  TopSegs: array[0..3] of string = ('a', 'b', 'c', '');

var
  Patterns, Topics: TStringList;

procedure GenPatterns(const APrefix: string; ADepth, AMax: Integer);
var
  i: Integer;
  P: string;
begin
  for i := 0 to High(PatSegs) do
  begin
    if ADepth = 0 then P := PatSegs[i] else P := APrefix + '.' + PatSegs[i];
    Patterns.Add(P);
    if ADepth + 1 < AMax then GenPatterns(P, ADepth + 1, AMax);
  end;
end;

procedure GenTopics(const APrefix: string; ADepth, AMax: Integer);
var
  i: Integer;
  T: string;
begin
  for i := 0 to High(TopSegs) do
  begin
    if ADepth = 0 then T := TopSegs[i] else T := APrefix + '.' + TopSegs[i];
    Topics.Add(T);
    if ADepth + 1 < AMax then GenTopics(T, ADepth + 1, AMax);
  end;
end;

var
  A, F, T: string;
  Unsound, Covered, OverDenied, Pairs: Int64;
  Counter, Shown: Integer;
  Subset: Boolean;
begin
  Patterns := TStringList.Create;
  Topics := TStringList.Create;
  GenPatterns('', 0, 3);
  GenTopics('', 0, 4);
  Unsound := 0; Covered := 0; OverDenied := 0; Pairs := 0; Shown := 0;
  for A in Patterns do
    for F in Patterns do
    begin
      Inc(Pairs);
      Subset := True;
      for T in Topics do
        if TopicMatches(F, T) and not TopicMatches(A, T) then begin Subset := False; Break; end;
      if TopicFilterCovers(A, F) then
      begin
        Inc(Covered);
        if not Subset then
        begin
          Inc(Unsound);
          if Shown < 10 then begin Inc(Shown); WriteLn('  UNSOUND  allow="', A, '" filter="', F, '" is said to be covered but is not'); end;
        end;
      end
      else if Subset and (A <> '') and (F <> '') then
        Inc(OverDenied);
    end;
  WriteLn('  ', Pairs, ' allow/filter pairs checked against ', Topics.Count, ' topics each');
  WriteLn('  ', Covered, ' judged covered, ', OverDenied, ' refused although the topic sets nest (over-denial: safe, only less convenient)');
  Counter := 0;
  if Unsound = 0 then WriteLn('  ok    TopicFilterCovers is sound: it never grants more than the allow pattern')
  else begin WriteLn('  FAIL  ', Unsound, ' unsound judgements'); Counter := 1; end;
  WriteLn;
  if Unsound = 0 then WriteLn('1 passed, 0 failed') else WriteLn('0 passed, 1 failed');
  Patterns.Free; Topics.Free;
  if Counter > 0 then Halt(1);
end.
