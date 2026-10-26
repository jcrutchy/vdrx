program test_runner_expandargs;

{$mode ObjFPC}{$H+}

// Self-contained tests for TVDRX_RunnerExecutive.ExpandArgs (vdrx_runner.pas),
// specifically the WholeToken boundary arithmetic that decides whether a
// %%name%% / %%name?%% placeholder is the ENTIRE argument template (which
// triggers the "value may not start with -" guard) or just part of a larger
// token like "--units=%%units?%%" (which doesn't).
//
// This exists because a code review flagged that arithmetic as possibly
// off-by-one. Working through it by hand on paper showed it is actually
// correct - these cases pin that down so it stays correct.
//
//   fpc -Mobjfpc -Sh -Fu../../src test_runner_expandargs.lpr
//   ./test_runner_expandargs          (exit code 0 = all passed)

uses
  SysUtils, Classes, vdrx_core, vdrx_runner;

type
  // ExpandArgs is protected; this just exposes it to the test, same as any
  // other descendant of TVDRX_RunnerExecutive (e.g. TVDRX_CGIExecutive) can
  // already call it.
  TTestRunner = class(TVDRX_RunnerExecutive)
  public
    function TestExpandArgs(AParams: TStringList; ADest: TStrings; out AError: string): Boolean;
  end;

function TTestRunner.TestExpandArgs(AParams: TStringList; ADest: TStrings; out AError: string): Boolean;
begin
  Result := ExpandArgs(AParams, ADest, AError);
end;

var
  Passed, Failed: Integer;

procedure Check(ACond: Boolean; const AName: string);
begin
  if ACond then
  begin
    Inc(Passed);
    WriteLn('  ok    ', AName);
  end
  else
  begin
    Inc(Failed);
    WriteLn('  FAIL  ', AName);
  end;
end;

procedure RunCase(const ACaseName, AArgTemplate: string; AParams: array of string;
  AExpectOK: Boolean; const AExpectedDest: string);
var
  Bus: TVDRX_MessageQueue;
  Runner: TTestRunner;
  Args, Params, Dest: TStringList;
  i: Integer;
  OK: Boolean;
  ErrText, Got: string;
begin
  Bus := TVDRX_MessageQueue.Create;
  Runner := TTestRunner.Create(Bus);
  Args := TStringList.Create;
  Params := TStringList.Create;
  Dest := TStringList.Create;
  try
    Args.Add(AArgTemplate);
    Runner.SetArgs(Args);
    i := 0;
    while i < Length(AParams) do
    begin
      Params.Add(AParams[i] + '=' + AParams[i + 1]);
      Inc(i, 2);
    end;

    OK := Runner.TestExpandArgs(Params, Dest, ErrText);
    Check(OK = AExpectOK, ACaseName + ' - Result');
    if OK then
    begin
      Got := Dest.CommaText;
      Check(Got = AExpectedDest, ACaseName + ' - output');
      if Got <> AExpectedDest then
      begin
        WriteLn('          expected: [', AExpectedDest, ']');
        WriteLn('          actual:   [', Got, ']');
      end;
    end;
  finally
    Dest.Free;
    Params.Free;
    Args.Free;
    Runner.Free;
    Bus.Free;
  end;
end;

begin
  Passed := 0;
  Failed := 0;

  // A token that is NOTHING BUT one required placeholder.
  RunCase('whole required placeholder, value present',
    '%%name%%', ['name', 'value123'], True, 'value123');

  // Required placeholder, parameter missing -> error, nothing added.
  RunCase('whole required placeholder, value missing',
    '%%name%%', [], False, '');

  // Optional placeholder embedded in a larger token ("flag=value" written as
  // one token, per the header comment); missing -> the WHOLE token is
  // dropped, not an error.
  RunCase('embedded optional placeholder, value missing -> token dropped',
    '--units=%%units?%%', [], True, '');

  // Optional placeholder embedded in a larger token; value present -> kept.
  RunCase('embedded optional placeholder, value present',
    '--units=%%units?%%', ['units', 'mm'], True, '--units=mm');

  // A WHOLE token that is just one optional placeholder, value starting
  // with "-": this is exactly the case the leading-dash guard exists for
  // (stop a caller smuggling an option flag in where a plain value belongs).
  RunCase('whole optional placeholder, value starts with "-" -> rejected',
    '%%val?%%', ['val', '-5'], False, '');

  // The SAME value ("-5"), but the placeholder is only PART of the token
  // (surrounded by literal text) - WholeToken must be False here, so the
  // leading-dash guard must NOT fire.
  RunCase('non-whole placeholder, value starts with "-" -> allowed',
    'prefix%%val%%suffix', ['val', '-5'], True, 'prefix-5suffix');

  WriteLn;
  WriteLn(Passed, ' passed, ', Failed, ' failed.');
  if Failed > 0 then Halt(1);
end.
