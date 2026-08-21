program vdrx;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  StrUtils,
  SysUtils,
  Process,
  vdrx_core,
  vdrx_config,
  vdrx_admin,
  vdrx_logger,
  vdrx_stdin,
  vdrx_bridge,
  vdrx_bucket,
  vdrx_websocket,
  vdrx_http,
  vdrx_socketlistener,
  vdrx_weblistener,
  vdrx_templates, vdrx_procutil, vdrx_transport, vdrx_admincmd;

type
  TVDRX_HTTPSite = record
    ID: string;
    HTTP: TVDRX_HTTPExecutive;
    Templates: TVDRX_TemplateStore;
  end;
  TVDRX_HTTPSites = array of TVDRX_HTTPSite;

var
  Kernel: TVDRX_Kernel;
  Config: TVDRX_Config;
  Admin: TVDRX_AdminExecutive;
  Logger: TVDRX_LoggerExecutive;
  Stdin: TVDRX_StdinExecutive;
  WS: TVDRX_WebSocketExecutive;
  ProxyRoutes: TVDRX_ProxyRoutes;
  CLIRoutes: TVDRX_CLIRoutes;
  ShutdownGraceMs: Integer;
  DoRestart: Boolean;
  NewProc: TProcess;
  i: Integer;
  HTTPSites: TVDRX_HTTPSites;

procedure ConfigureListenerTLS(AListener: TVDRX_SocketListenerExecutive; const AKeyPrefix: string);
begin
  AListener.ConfigureTLS(
    Config.GetInteger(AKeyPrefix + '.tls_port', 0),
    Config.GetString(AKeyPrefix + '.tls_cert', ''),
    Config.GetString(AKeyPrefix + '.tls_key', ''));
end;

procedure ReportListener(AListener: TVDRX_SocketListenerExecutive; const AName: string);
begin
  WriteLn('  ', AName, ' listening on port ', AListener.Port, '.');
  if AListener.TLSActive then
    WriteLn('  ', AName, ' also listening TLS on port ', AListener.TLSPort, '.')
  else if AListener.TLSPort <> 0 then
    WriteLn('  ', AName, ' TLS was configured (port ', AListener.TLSPort,
      ') but failed to come up - check tls_cert/tls_key and that libssl is loadable.');
end;

// Generalized from the old SetupProxyBridges: every entry in "processes" gets
// a supervised TVDRX_BridgeExecutive (spawn, restart-on-crash, graceful-then-
// force shutdown - see vdrx_bridge.pas) regardless of what it's for. prefix/
// host/port are now OPTIONAL - give them and the process also gets an HTTP
// reverse-proxy route (same as the old proxy_bridges did); omit them for a
// bare supervised background process with no HTTP surface at all (a SOMA
// worker, a future Cartographica island process, etc). id and command are the
// only two required fields. Deliberately NOT merged with cli_bridges below -
// that's a genuinely different mechanism (invoke-per-request script
// execution, no persistent process, no Bridge involved), not another flavour
// of this one.
procedure SetupProcesses(AConfig: TVDRX_Config; ARegistry: TVDRX_Registry;
  AGracefulMs: Integer; out ARoutes: TVDRX_ProxyRoutes);
var
  Rows: TVDRX_ConfigRows;
  Row: TStringList;
  Bridge: TVDRX_BridgeExecutive;
  n, BridgeGraceMs, i: Integer;
  RestartRaw: string;
  Filters: TStringArray;
begin
  SetLength(ARoutes, 0);
  Rows := AConfig.GetObjectArray('processes');
  try
    for Row in Rows do
    begin
      if (Row.Values['id'] = '') or (Row.Values['command'] = '') then
      begin
        WriteLn('  Skipping processes entry - needs at least id and command.');
        Continue;
      end;
      Bridge := TVDRX_BridgeExecutive.Create(Kernel.Queue);
      Bridge.Command := Row.Values['command'];
      // Most simple dev web servers (php -S included) don't respond to a
      // graceful-shutdown hint at all - SIGTERM does work on Unix, but
      // there's genuinely no equivalent on Windows (see vdrx_procutil.pas's
      // TryGracefulTerminate). Waiting the full shutdown_grace_ms on every
      // quit/restart just to then force-kill it anyway wastes real time -
      // override per-process via "graceful_timeout_ms" in its processes
      // entry; falls back to the daemon-wide default if not set.
      BridgeGraceMs := StrToIntDef(Row.Values['graceful_timeout_ms'], AGracefulMs);
      Bridge.GracefulTimeoutMs := BridgeGraceMs;

      // "restart": "always" (default) | "on-failure" | "never" - see
      // TVDRX_BridgeExecutive.RestartPolicy in vdrx_bridge.pas. An unrecognized
      // value falls back to "always" with a warning, rather than silently
      // guessing wrong about how badly this one wants to keep running.
      RestartRaw := Row.Values['restart'];
      if RestartRaw = '' then RestartRaw := 'always';
      if (RestartRaw <> 'always') and (RestartRaw <> 'on-failure') and (RestartRaw <> 'never') then
      begin
        WriteLn('  Process "', Row.Values['id'], '": unrecognized restart "', RestartRaw, '" - using "always".');
        RestartRaw := 'always';
      end;
      Bridge.RestartPolicy := RestartRaw;

      // "publish": ["topic.filter", ...] - see PublishPatterns in
      // vdrx_bridge.pas. Omit it (the default) and this process can never
      // override <id>.out, no matter what its stdout looks like.
      Bridge.PublishPatterns := Row.Values['publish'];

      // "subscribe": ["topic.filter", ...] - GetObjectArray comma-joins the
      // JSON array into one string (see vdrx_config.pas), split back out here.
      // Each filter is registered so matching bus messages are written to the
      // child's stdin (TVDRX_BridgeExecutive.HandlePacket already does this -
      // it just never had a real subscription routed to it before). No
      // subscribe entries at all keeps the old behaviour: registered on
      // 'sys.none', i.e. publish-only.
      if Row.Values['subscribe'] <> '' then
      begin
        Filters := SplitString(Row.Values['subscribe'], ',');
        ARegistry.Register(Bridge, Row.Values['id'], Trim(Filters[0]));
        for i := 1 to High(Filters) do
          ARegistry.Register(Bridge, Row.Values['id'], Trim(Filters[i]));
      end
      else
        ARegistry.Register(Bridge, Row.Values['id'], 'sys.none');

      if Row.Values['prefix'] <> '' then
      begin
        n := Length(ARoutes);
        SetLength(ARoutes, n + 1);
        ARoutes[n].Prefix := Row.Values['prefix'];
        ARoutes[n].Host := IfThen(Row.Values['host'] <> '', Row.Values['host'], '127.0.0.1');
        ARoutes[n].Port := StrToIntDef(Row.Values['port'], 0);
        WriteLn('  Process "', Row.Values['id'], '" (proxied): ', ARoutes[n].Prefix, ' -> ',
          ARoutes[n].Host, ':', ARoutes[n].Port, ' (', Row.Values['command'],
          ', restart=', RestartRaw, ', graceful_timeout_ms=', BridgeGraceMs, ')');
      end
      else
        WriteLn('  Process "', Row.Values['id'], '" (', Row.Values['command'],
          ', restart=', RestartRaw, ', graceful_timeout_ms=', BridgeGraceMs, ')');
    end;
  finally
    Rows.Free;
  end;
end;

// Generalized the same way SetupProcesses generalized proxy bridges: every
// entry in "http_sites" gets its own TVDRX_HTTPExecutive + TVDRX_TemplateStore,
// each on its own port with its own static/template roots. Previously there
// was exactly one of each, wired from top-level static_dir/template_dir/
// executives.http.* keys - fine when VDRX only ever served itself, not once
// a second app (Kyzu) wants its own site. ProxyRoutes/CLIRoutes stay shared
// across all sites for now - genuinely global concerns (any site can proxy
// to any bridge), not per-site ones.
function SetupHTTPSites(AConfig: TVDRX_Config; ARegistry: TVDRX_Registry;
  AGracefulMs: Integer; const AProxyRoutes: TVDRX_ProxyRoutes;
  const ACLIRoutes: TVDRX_CLIRoutes): TVDRX_HTTPSites;
var
  Rows: TVDRX_ConfigRows;
  Row: TStringList;
  Site: TVDRX_HTTPSite;
  n: Integer;
begin
  SetLength(Result, 0);
  Rows := AConfig.GetObjectArray('http_sites');
  try
    for Row in Rows do
    begin
      if (Row.Values['id'] = '') or (Row.Values['port'] = '') then
      begin
        WriteLn('  Skipping http_sites entry - needs at least id and port.');
        Continue;
      end;

      Site.ID := Row.Values['id'];
      Site.Templates := TVDRX_TemplateStore.Create(AConfig,
        IfThen(Row.Values['template_dir'] <> '', Row.Values['template_dir'], 'templates'));
      Site.HTTP := TVDRX_HTTPExecutive.Create(Kernel.Queue, AConfig, Site.Templates,
        IfThen(Row.Values['static_dir'] <> '', Row.Values['static_dir'], 'static'),
        AProxyRoutes, ACLIRoutes);
      Site.HTTP.Port := StrToIntDef(Row.Values['port'], 8081);
      Site.HTTP.GracefulTimeoutMs := AGracefulMs;

      if Row.Values['tls_port'] <> '' then
        Site.HTTP.ConfigureTLS(StrToIntDef(Row.Values['tls_port'], 0),
          Row.Values['tls_cert'], Row.Values['tls_key']);

      ARegistry.Register(Site.HTTP, Site.ID, 'sys.none'); // serves requests directly, doesn't consume bus messages

      n := Length(Result);
      SetLength(Result, n + 1);
      Result[n] := Site;

      WriteLn('  HTTP site "', Site.ID, '": port ', Site.HTTP.Port,
        ', static="', Row.Values['static_dir'], '", templates="', Row.Values['template_dir'], '"');
    end;
  finally
    Rows.Free;
  end;
end;

procedure SetupCLIBridges(AConfig: TVDRX_Config; out ARoutes: TVDRX_CLIRoutes);
var
  Rows: TVDRX_ConfigRows;
  Row: TStringList;
  n: Integer;
begin
  SetLength(ARoutes, 0);
  Rows := AConfig.GetObjectArray('cli_bridges');
  try
    for Row in Rows do
    begin
      if (Row.Values['id'] = '') or (Row.Values['command'] = '') or (Row.Values['prefix'] = '') or (Row.Values['script_dir'] = '') then
      begin
        WriteLn('  Skipping cli_bridges entry - needs id, prefix, command, and script_dir.');
        Continue;
      end;
      n := Length(ARoutes);
      SetLength(ARoutes, n + 1);
      ARoutes[n].Prefix := Row.Values['prefix'];
      ARoutes[n].Command := Row.Values['command'];
      ARoutes[n].ScriptDir := Row.Values['script_dir'];
      ARoutes[n].TimeoutMs := StrToIntDef(Row.Values['timeout_ms'], 5000);
      ARoutes[n].ContentType := IfThen(Row.Values['content_type'] <> '', Row.Values['content_type'], 'text/html');
      WriteLn('  CLI bridge "', Row.Values['id'], '": ', ARoutes[n].Prefix, ' -> ',
        ARoutes[n].Command, ' ', ARoutes[n].ScriptDir, '/* (timeout_ms=', ARoutes[n].TimeoutMs, ')');
    end;
  finally
    Rows.Free;
  end;
end;

// One TVDRX_BucketExecutive per "buckets" config entry, registered on
// whatever topic filter(s) it declares - same comma-joined-array pattern as
// "processes"' subscribe field. Every matching message gets appended to
// that bucket's own history file (default bucket_<name>.jsonl, override with
// "file"). See vdrx_bucket.pas for why this is full history rather than
// latest-value-per-topic, and vdrx_admin.pas's DoHistory for how it's read
// back (the "history" console command - there's no automatic replay).
procedure SetupBuckets(AConfig: TVDRX_Config; ARegistry: TVDRX_Registry);
var
  Rows: TVDRX_ConfigRows;
  Row: TStringList;
  Bucket: TVDRX_BucketExecutive;
  Filters: TStringArray;
  FilePath: string;
  i: Integer;
begin
  Rows := AConfig.GetObjectArray('buckets');
  try
    for Row in Rows do
    begin
      if (Row.Values['name'] = '') or (Row.Values['topics'] = '') then
      begin
        WriteLn('  Skipping buckets entry - needs at least name and topics.');
        Continue;
      end;
      FilePath := IfThen(Row.Values['file'] <> '', Row.Values['file'],
        'bucket_' + Row.Values['name'] + '.jsonl');
      Bucket := TVDRX_BucketExecutive.Create(Kernel.Queue, FilePath);
      Filters := SplitString(Row.Values['topics'], ',');
      ARegistry.Register(Bucket, Row.Values['name'], Trim(Filters[0]));
      for i := 1 to High(Filters) do
        ARegistry.Register(Bucket, Row.Values['name'], Trim(Filters[i]));
      WriteLn('  Bucket "', Row.Values['name'], '": ', Row.Values['topics'],
        ' -> ', FilePath);
    end;
  finally
    Rows.Free;
  end;
end;

begin

  try
    Kernel := TVDRX_Kernel.Create;
    Config := TVDRX_Config.Create('vdrx.conf');

    ShutdownGraceMs := Config.GetInteger('shutdown_grace_ms', 5000);

    // Subscribes to everything under log.* - any executive's Bus.Publish of a
    // log.info/log.warn/log.error topic ends up here, colored on the console and
    // plain in vdrx_daemon.log.
    Logger := TVDRX_LoggerExecutive.Create(Kernel.Queue, 'vdrx_daemon.log', lvlINFO);
    //Kernel.Registry.Register(Logger, 'logger', 'log.>');
    //Kernel.Registry.Register(Logger, 'logger', 'irc.>');
    Kernel.Registry.Register(Logger, 'logger', '>');

    // Listens on 'sys.>' - reload/quit/restart/kill/killall. See vdrx_admin.pas
    // and vdrx_admincmd.pas for the full command set and who can trigger it
    // (stdin below is the only source right now; DispatchAdminCommandLine in
    // vdrx_admincmd.pas is written to be reusable by any future text-command
    // source the same way).
    Admin := TVDRX_AdminExecutive.Create(Kernel.Queue, Config, Kernel.Registry, Kernel);
    Kernel.Registry.Register(Admin, 'admin', 'sys.>');

    // Reads quit/restart/reload/kill/killall commands typed at the console.
    // Replaces the old "press ENTER to stop" main-thread ReadLn.
    if Config.GetBoolean('stdin_admin_enabled', True) then
    begin
      Stdin := TVDRX_StdinExecutive.Create(Kernel.Queue);
      Kernel.Registry.Register(Stdin, 'stdin', 'sys.none'); // doesn't consume bus messages, only publishes
    end;

    if Config.GetBoolean('executives.ws.enabled', False) then
    begin
      WS := TVDRX_WebSocketExecutive.Create(Kernel.Queue, Config, Kernel.Registry);
      WS.Port := Config.GetInteger('executives.ws.port', 8082);
      WS.GracefulTimeoutMs := ShutdownGraceMs;
      ConfigureListenerTLS(WS, 'executives.ws');
      Kernel.Registry.Register(WS, 'ws', 'sys.none'); // each connection registers itself
    end;

    SetupProcesses(Config, Kernel.Registry, ShutdownGraceMs, ProxyRoutes);
    SetupCLIBridges(Config, CLIRoutes);
    SetupBuckets(Config, Kernel.Registry);

    HTTPSites := SetupHTTPSites(Config, Kernel.Registry, ShutdownGraceMs, ProxyRoutes, CLIRoutes);

    Kernel.Start; // Execute() calls Registry.InitializeAll - this is what actually
                  // binds every listener's socket(s) and starts its accept thread(s)

    WriteLn('VDRX daemon running.');
    if Assigned(WS) then ReportListener(WS, 'WebSocket');
    for i := 0 to High(HTTPSites) do
      ReportListener(HTTPSites[i].HTTP, 'HTTP (' + HTTPSites[i].ID + ')');
    WriteLn('  Logger writing to vdrx_daemon.log (console threshold: INFO).');
    if Assigned(Stdin) then
      WriteLn('  Type quit / restart / reload / kill <pid-or-id> / killall [type] and press Enter to control the daemon.');
    WriteLn('  Shutdown grace period: ', ShutdownGraceMs, 'ms before hung threads/processes are force-killed.');

    Kernel.WaitFor; // returns once sys.quit/sys.restart has driven Kernel.Terminate
                     // and ShutdownAll has finished tearing everything down cleanly
    DoRestart := Kernel.RestartRequested; // read before Free below
    Kernel.Free;
    for i := 0 to High(HTTPSites) do
      HTTPSites[i].Templates.Free; // HTTP executives themselves are Registry-owned, freed by Kernel.Free above
    Config.Free;

    WriteLn('Daemon stopped.');

    if DoRestart then
    begin
      WriteLn('Respawning...');
      NewProc := TProcess.Create(nil);
      try
        NewProc.Executable := ParamStr(0);
        for i := 1 to ParamCount do
          NewProc.Parameters.Add(ParamStr(i));
        NewProc.CurrentDirectory := GetCurrentDir;
        NewProc.Options := []; // detached - don't wait, don't inherit our pipes;
                                // the new instance keeps running independently
                                // once Execute returns
        NewProc.Execute;
      finally
        NewProc.Free; // doesn't own/stop the spawned OS process
      end;
    end;

  except
    on E: Exception do
    begin
      WriteLn('FATAL: daemon failed to start - ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;

end.
