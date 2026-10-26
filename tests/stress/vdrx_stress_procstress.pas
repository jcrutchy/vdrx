unit vdrx_stress_procstress;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Math, vdrx_stress_report, vdrx_stress_daemonctl;

type
  TProcStressConfig = record
    ExePath: string;
    WorkDir: string;        // dedicated work dir - this suite writes its OWN
                             // vdrx_daemon.conf here, never touches the
                             // caller's real one
    Cycles: Integer;        // how many rapid kill cycles to run
    DelayMsBetween: Integer;
  end;

procedure RunProcessStressSuite(const ACfg: TProcStressConfig; AReport: TStressReport);

implementation

const
  SUITE = 'procstress';

procedure WriteTestConfig(const AWorkDir: string);
var
  F: TextFile;
  TargetCmd: string;
begin
  ForceDirectories(AWorkDir);
  // A long-lived, harmless placeholder process for Bridge to supervise.
  // Windows note: deliberately "ping -n 30 127.0.0.1" rather than
  // "timeout /t 30" - timeout refuses to run at all when its stdin isn't a
  // real interactive console (exactly the situation here, since Bridge
  // redirects it via a pipe), a well-known gotcha; ping has no such
  // restriction and reliably takes about the right amount of time either way.
  {$IFDEF UNIX}
  TargetCmd := '/bin/sleep 30';
  {$ELSE}
  TargetCmd := 'ping -n 30 127.0.0.1';
  {$ENDIF}
  AssignFile(F, AWorkDir + PathDelim + 'vdrx_daemon.conf');
  Rewrite(F);
  WriteLn(F, '{');
  WriteLn(F, '  "shutdown_grace_ms": 2000,');
  WriteLn(F, '  "stdin_admin_enabled": true,');
  WriteLn(F, '  "processes": [');
  WriteLn(F, '    { "id": "target", "command": "', TargetCmd, '", "restart": "always" }');
  WriteLn(F, '  ]');
  WriteLn(F, '}');
  CloseFile(F);
end;

procedure RunProcessStressSuite(const ACfg: TProcStressConfig; AReport: TStressReport);
var
  Ctl: TVDRX_DaemonController;
  i: Integer;
  StartTime: TDateTime;
begin
  WriteTestConfig(ACfg.WorkDir);
  Ctl := TVDRX_DaemonController.Create;
  try
    if not Ctl.StartManaged(ACfg.ExePath, ACfg.WorkDir) then
    begin
      AReport.Fail(SUITE, 'startup', 'failed to spawn daemon for process-stress suite');
      Exit;
    end;

    Sleep(500); // give it a moment to register the bridge and spawn "target"
    if not Ctl.IsAlive then
    begin
      AReport.Fail(SUITE, 'startup',
        'daemon exited immediately after spawn - recent output: ' + Copy(Ctl.RecentOutput, 1, 500));
      Exit;
    end;
    AReport.Pass(SUITE, 'startup');

    // --- Rapid kill cycling ---
    // Deliberately no coordination with how long "target" takes to actually
    // respawn - some kills will land on a live process, some on a process
    // still mid-restart-backoff. That's the point: this is exactly the kind
    // of race a human operator mashing "kill" wouldn't hit reliably by hand.
    AReport.Info(Format('procstress: %d rapid kill cycles', [ACfg.Cycles]));
    StartTime := Now;
    for i := 1 to ACfg.Cycles do
    begin
      Ctl.SendStdinLine('kill target');
      if ACfg.DelayMsBetween > 0 then
        Sleep(ACfg.DelayMsBetween);
      if not Ctl.IsAlive then
      begin
        AReport.Fail(SUITE, 'kill_cycle_survival',
          Format('daemon died after %d/%d kill cycles - recent output: %s',
            [i, ACfg.Cycles, Copy(Ctl.RecentOutput, 1, 500)]));
        Ctl.StopManaged(1000);
        Exit;
      end;
    end;
    AReport.Pass(SUITE, 'kill_cycle_survival');
    AReport.Metric(SUITE, 'kill_cycles_per_sec',
      ACfg.Cycles / Max(0.001, (Now - StartTime) * 86400), 'cycles/s');

    // --- killall cycling ---
    AReport.Info('procstress: killall cycling');
    for i := 1 to Min(20, ACfg.Cycles) do
    begin
      Ctl.SendStdinLine('killall bridge');
      Sleep(Max(50, ACfg.DelayMsBetween));
      if not Ctl.IsAlive then
      begin
        AReport.Fail(SUITE, 'killall_cycle_survival',
          Format('daemon died after %d killall cycles - recent output: %s',
            [i, Copy(Ctl.RecentOutput, 1, 500)]));
        Ctl.StopManaged(1000);
        Exit;
      end;
    end;
    AReport.Pass(SUITE, 'killall_cycle_survival');

    // --- Final sanity: still responsive to an ordinary admin command ---
    Ctl.SendStdinLine('list');
    Sleep(300);
    if Ctl.IsAlive then
      AReport.Pass(SUITE, 'final_list_survival')
    else
      AReport.Fail(SUITE, 'final_list_survival', 'daemon died after final list command');

  finally
    Ctl.StopManaged(3000);
    Ctl.Free;
  end;
end;

end.
