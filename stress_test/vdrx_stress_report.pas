unit vdrx_stress_report;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Generics.Collections;

type
  TStressFailure = record
    Suite, TestName, Reason: string;
  end;
  TStressFailureList = specialize TList<TStressFailure>;

  TStressMetric = record
    Suite, Name, Unit_: string;
    Value: Double;
  end;
  TStressMetricList = specialize TList<TStressMetric>;

  // Shared across every suite and every worker thread within a suite - all
  // public methods take their own lock, so any thread can call Pass/Fail/
  // Metric/Info freely without the suite needing its own synchronization.
  TStressReport = class
  private
    FLock: TCriticalSection;
    FPassCount, FFailCount: Int64;
    FFailures: TStressFailureList;
    FMetrics: TStressMetricList;
    FStartedAt: TDateTime;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Pass(const ASuite, ATestName: string);
    procedure Fail(const ASuite, ATestName, AReason: string);
    procedure Metric(const ASuite, AName: string; AValue: Double; const AUnit: string);
    procedure Info(const AMsg: string);
    procedure PrintSummary;
    // Nonzero on any failure - the process exit code, so this can plug into
    // a CI/regression gate later without needing to scrape console output.
    function ExitCode: Integer;
    property PassCount: Int64 read FPassCount;
    property FailCount: Int64 read FFailCount;
  end;

implementation

constructor TStressReport.Create;
begin
  FLock := TCriticalSection.Create;
  FFailures := TStressFailureList.Create;
  FMetrics := TStressMetricList.Create;
  FStartedAt := Now;
end;

destructor TStressReport.Destroy;
begin
  FFailures.Free;
  FMetrics.Free;
  FLock.Free;
  inherited;
end;

procedure TStressReport.Pass(const ASuite, ATestName: string);
begin
  FLock.Enter;
  try
    Inc(FPassCount);
    WriteLn(Format('[pass] %s / %s', [ASuite, ATestName]));
    Flush(Output);
  finally
    FLock.Leave;
  end;
end;

procedure TStressReport.Fail(const ASuite, ATestName, AReason: string);
var
  F: TStressFailure;
begin
  F.Suite := ASuite;
  F.TestName := ATestName;
  F.Reason := AReason;
  FLock.Enter;
  try
    Inc(FFailCount);
    FFailures.Add(F);
  finally
    FLock.Leave;
  end;
  // Failures print immediately too, not just in the final summary - on a long
  // run you want to see a crash the moment it happens, not five minutes later.
  WriteLn(Format('[FAIL] %s / %s: %s', [ASuite, ATestName, AReason]));
  Flush(Output); // stdout is block-buffered when redirected (not a TTY) - a
                  // killed/hung process can lose everything since the last
                  // flush otherwise; same lesson as hogircd's silent logging
end;

procedure TStressReport.Metric(const ASuite, AName: string; AValue: Double; const AUnit: string);
var
  M: TStressMetric;
begin
  M.Suite := ASuite;
  M.Name := AName;
  M.Value := AValue;
  M.Unit_ := AUnit;
  FLock.Enter;
  try
    FMetrics.Add(M);
  finally
    FLock.Leave;
  end;
end;

procedure TStressReport.Info(const AMsg: string);
begin
  FLock.Enter;
  try
    WriteLn('[INFO] ' + AMsg);
    Flush(Output);
  finally
    FLock.Leave;
  end;
end;

procedure TStressReport.PrintSummary;
var
  F: TStressFailure;
  M: TStressMetric;
begin
  FLock.Enter;
  try
    WriteLn;
    WriteLn('=== Summary (', FormatDateTime('hh:nn:ss', Now - FStartedAt), ' elapsed) ===');
    WriteLn(Format('  %d passed, %d failed', [FPassCount, FFailCount]));
    if FMetrics.Count > 0 then
    begin
      WriteLn('  Metrics:');
      for M in FMetrics do
        WriteLn(Format('    %s / %s: %.3f %s', [M.Suite, M.Name, M.Value, M.Unit_]));
    end;
    if FFailures.Count > 0 then
    begin
      WriteLn('  Failures:');
      for F in FFailures do
        WriteLn(Format('    %s / %s: %s', [F.Suite, F.TestName, F.Reason]));
    end;
  finally
    FLock.Leave;
  end;
end;

function TStressReport.ExitCode: Integer;
begin
  if FFailCount > 0 then
    Result := 1
  else
    Result := 0;
end;

end.
