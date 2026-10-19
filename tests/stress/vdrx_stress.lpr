program vdrx_stress;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes, SysUtils,
  vdrx_config,
  vdrx_stress_report,
  vdrx_stress_daemonctl,
  vdrx_stress_httpfuzz,
  vdrx_stress_wsfuzz,
  vdrx_stress_procstress;

// Writes a combined http+ws-enabled vdrx_daemon.conf into AWorkDir for spawn
// mode's http/ws suites. This intentionally does NOT touch or reuse any
// vdrx_daemon.conf that might already exist there for other purposes - a
// stress run's config is disposable and suite-specific, same reasoning as
// procstress writing its own dedicated one.
procedure WriteHTTPWSConfig(const AWorkDir: string; AHTTPPort, AWSPort: Word);
var
  F: TextFile;
begin
  ForceDirectories(AWorkDir);
  AssignFile(F, AWorkDir + PathDelim + 'vdrx_daemon.conf');
  Rewrite(F);
  WriteLn(F, '{');
  WriteLn(F, '  "shutdown_grace_ms": 3000,');
  WriteLn(F, '  "stdin_admin_enabled": true,');
  WriteLn(F, '  "static_dir": "static",');
  WriteLn(F, '  "executives": {');
  WriteLn(F, '    "http": { "enabled": true, "port": ', AHTTPPort, ', "tls_port": 0, "tls_cert": "", "tls_key": "" },');
  WriteLn(F, '    "ws":   { "enabled": true, "port": ', AWSPort, ', "tls_port": 0, "tls_cert": "", "tls_key": "" }');
  WriteLn(F, '  }');
  WriteLn(F, '}');
  CloseFile(F);
end;

function HasSuite(AConfig: TVDRX_Config; const AName: string): Boolean;
var
  Suites: TStringArray;
  s: string;
begin
  Result := False;
  Suites := AConfig.GetStringArray('suites');
  for s in Suites do
    if LowerCase(s) = AName then
      Exit(True);
end;

var
  Report: TStressReport;
  Config: TVDRX_Config;
  ConfigPath, Mode, DaemonExe, WorkDir, Host: string;
  HTTPPort, WSPort: Integer;
  Ctl: TVDRX_DaemonController;
  HTTPCfg: THTTPFuzzConfig;
  WSCfg: TWSFuzzConfig;
  ProcCfg: TProcStressConfig;

begin
  ConfigPath := 'vdrx_stress.conf';
  if ParamCount >= 1 then
    ConfigPath := ParamStr(1);

  if not FileExists(ConfigPath) then
  begin
    WriteLn('Config file not found: ', ConfigPath);
    WriteLn('Usage: vdrx_stress [path-to-vdrx_stress.conf]');
    Halt(1);
  end;

  Config := TVDRX_Config.Create(ConfigPath);
  Report := TStressReport.Create;

  Mode := LowerCase(Config.GetString('mode', 'spawn'));
  DaemonExe := Config.GetString('daemon_exe', './vdrx_daemon');
  WorkDir := Config.GetString('work_dir', '.');
  Host := Config.GetString('host', '127.0.0.1');
  HTTPPort := Config.GetInteger('http_port', 8081);
  WSPort := Config.GetInteger('ws_port', 8082);

  Ctl := TVDRX_DaemonController.Create;
  Ctl.Host := Host;

  if (Mode = 'spawn') and (HasSuite(Config, 'http') or HasSuite(Config, 'ws')) then
  begin
    WriteHTTPWSConfig(WorkDir, HTTPPort, WSPort);
    Report.Info('Spawning daemon for http/ws suites: ' + DaemonExe);
    if not Ctl.StartManaged(DaemonExe, WorkDir) then
    begin
      Report.Fail('setup', 'spawn', 'could not start daemon at ' + DaemonExe);
      Halt(Report.ExitCode);
    end;
    if not Ctl.WaitForPortOpen(HTTPPort, 5000) and not Ctl.WaitForPortOpen(WSPort, 5000) then
    begin
      Report.Fail('setup', 'spawn', 'neither HTTP nor WS port came up within 5s');
      Ctl.StopManaged(2000);
      Halt(Report.ExitCode);
    end;
  end
  else if Mode = 'attach' then
    Report.Info(Format('Attaching to already-running daemon at %s (http:%d ws:%d)', [Host, HTTPPort, WSPort]));

  if HasSuite(Config, 'http') then
  begin
    HTTPCfg.Host := Host;
    HTTPCfg.Port := HTTPPort;
    HTTPCfg.LoadRequests := Config.GetInteger('http.load_requests', 500);
    HTTPCfg.LoadConcurrency := Config.GetInteger('http.load_concurrency', 20);
    HTTPCfg.ConnectTimeoutMs := Config.GetInteger('http.connect_timeout_ms', 2000);
    HTTPCfg.ReadTimeoutMs := Config.GetInteger('http.read_timeout_ms', 2000);
    RunHTTPFuzzSuite(HTTPCfg, Report, Ctl);
  end;

  if HasSuite(Config, 'ws') then
  begin
    WSCfg.Host := Host;
    WSCfg.Port := WSPort;
    WSCfg.ConnectTimeoutMs := Config.GetInteger('ws.connect_timeout_ms', 2000);
    WSCfg.ReadTimeoutMs := Config.GetInteger('ws.read_timeout_ms', 2000);
    WSCfg.RapidConnectCycles := Config.GetInteger('ws.rapid_connect_cycles', 50);
    RunWSFuzzSuite(WSCfg, Report, Ctl);
  end;

  if (Mode = 'spawn') and (HasSuite(Config, 'http') or HasSuite(Config, 'ws')) then
    Ctl.StopManaged(3000);

  if HasSuite(Config, 'procstress') then
  begin
    if Mode <> 'spawn' then
      Report.Info('procstress needs spawn mode (it drives the daemon via stdin) - skipped in attach mode')
    else
    begin
      ProcCfg.ExePath := DaemonExe;
      ProcCfg.WorkDir := Config.GetString('procstress.work_dir', WorkDir + PathDelim + 'procstress_workdir');
      ProcCfg.Cycles := Config.GetInteger('procstress.cycles', 30);
      ProcCfg.DelayMsBetween := Config.GetInteger('procstress.delay_ms', 100);
      RunProcessStressSuite(ProcCfg, Report);
    end;
  end;

  Ctl.Free;
  Config.Free;
  Report.PrintSummary;
  Halt(Report.ExitCode);
end.
