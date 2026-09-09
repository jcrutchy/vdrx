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
  fpjson,
  jsonparser,
  vdrx_core,
  vdrx_config,
  vdrx_admin,
  vdrx_logger,
  vdrx_stdin,
  vdrx_bridge,
  vdrx_bucket,
  vdrx_network,
  vdrx_templates,
  vdrx_procutil;

type
  // Polls GShutdownRequested (vdrx_procutil.pas) from ordinary thread
  // context and drives Kernel.Terminate itself once it flips - see
  // InstallShutdownSignalHandler's comment for why the signal/console
  // handler that sets that flag doesn't just call Terminate directly.
  // 200ms poll is a deliberate trade-off: fast enough that Ctrl+C feels
  // responsive, slow enough not to matter as a busy-loop over what's
  // hopefully the whole remaining runtime of the process.
  TVDRX_ShutdownWatcherThread = class(TThread)
  private
    FKernel: TVDRX_Kernel;
  protected
    procedure Execute; override;
  public
    constructor Create(AKernel: TVDRX_Kernel);
  end;

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
  ShutdownWatcher: TVDRX_ShutdownWatcherThread;

constructor TVDRX_ShutdownWatcherThread.Create(AKernel: TVDRX_Kernel);
begin
  inherited Create(False);
  FKernel := AKernel;
  FreeOnTerminate := False;
end;

procedure TVDRX_ShutdownWatcherThread.Execute;
begin
  while not Terminated do
  begin
    if GShutdownRequested then
    begin
      // Ordinary thread context from here on - safe to do everything the
      // signal/console handler itself deliberately didn't (see
      // GShutdownRequested's comment in vdrx_procutil.pas). Kernel.Terminate
      // is the exact same call 'quit'/sys.quit already makes - Ctrl+C now
      // drives the identical clean-shutdown path (kernel.shutdown ->
      // Registry.ShutdownAll -> every executive's own Shutdown, including
      // Bridge's TryGracefulTerminate-then-wait-then-ForceKillProcess for
      // each supervised child) rather than the OS's own default behaviour.
      FKernel.Terminate;
      Exit; // one-shot - Kernel.Execute's own loop takes it from here
    end;
    Sleep(200);
  end;
end;

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

procedure SetupProcesses(AConfig: TVDRX_Config; ARegistry: TVDRX_Registry;
  AGracefulMs: Integer; out ARoutes: TVDRX_ProxyRoutes);
var
  Rows: TVDRX_ConfigRows;
  Row: TStringList;
  Bridge: TVDRX_BridgeExecutive;
  n, BridgeGraceMs, i: Integer;
  RestartRaw, QueueGroup, GroupSuffix: string;
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
      if (Row.Values['enabled'] = 'False') or (Row.Values['enabled'] = 'false') or (Row.Values['enabled'] = '0') then
      begin
        WriteLn('  Process "', Row.Values['id'], '": disabled (enabled=false) - skipping.');
        Continue;
      end;
      Bridge := TVDRX_BridgeExecutive.Create(Kernel.Queue);
      Bridge.Command := Row.Values['command'];
      BridgeGraceMs := StrToIntDef(Row.Values['graceful_timeout_ms'], AGracefulMs);
      Bridge.GracefulTimeoutMs := BridgeGraceMs;

      RestartRaw := Row.Values['restart'];
      if RestartRaw = '' then RestartRaw := 'always';
      if (RestartRaw <> 'always') and (RestartRaw <> 'on-failure') and (RestartRaw <> 'never') then
      begin
        WriteLn('  Process "', Row.Values['id'], '": unrecognized restart "', RestartRaw, '" - using "always".');
        RestartRaw := 'always';
      end;
      Bridge.RestartPolicy := RestartRaw;

      Bridge.PublishPatterns := Row.Values['publish'];

      // queue_group: '' (the default) keeps the historical fan-out behaviour
      // - every subscriber matching a topic gets every message. Give two or
      // more processes entries the same queue_group (they still need their
      // own distinct "id") and Register's round-robin dispatch means each
      // published message goes to exactly one member of the group, letting
      // several instances of an expensive worker script share a queue of
      // jobs on one topic without any change to the worker script itself.
      QueueGroup := Row.Values['queue_group'];

      if Row.Values['subscribe'] <> '' then
      begin
        Filters := SplitString(Row.Values['subscribe'], ',');
        ARegistry.Register(Bridge, Row.Values['id'], Trim(Filters[0]), QueueGroup);
        for i := 1 to High(Filters) do
          ARegistry.Register(Bridge, Row.Values['id'], Trim(Filters[i]), QueueGroup);
      end
      else
        ARegistry.Register(Bridge, Row.Values['id'], Row.Values['id'] + '.in', QueueGroup);

      GroupSuffix := IfThen(QueueGroup <> '', ', queue_group=' + QueueGroup, '');

      if Row.Values['prefix'] <> '' then
      begin
        n := Length(ARoutes);
        SetLength(ARoutes, n + 1);
        ARoutes[n].Prefix := Row.Values['prefix'];
        ARoutes[n].Host := IfThen(Row.Values['host'] <> '', Row.Values['host'], '127.0.0.1');
        ARoutes[n].Port := StrToIntDef(Row.Values['port'], 0);
        WriteLn('  Process "', Row.Values['id'], '" (proxied): ', ARoutes[n].Prefix, ' -> ',
          ARoutes[n].Host, ':', ARoutes[n].Port, ' (', Row.Values['command'],
          ', restart=', RestartRaw, ', graceful_timeout_ms=', BridgeGraceMs, GroupSuffix, ')');
      end
      else
        WriteLn('  Process "', Row.Values['id'], '" (', Row.Values['command'],
          ', restart=', RestartRaw, ', graceful_timeout_ms=', BridgeGraceMs, GroupSuffix, ')');
    end;
  finally
    Rows.Free;
  end;
end;

function SetupHTTPSites(AConfig: TVDRX_Config; ARegistry: TVDRX_Registry;
  AGracefulMs: Integer; const AProxyRoutes: TVDRX_ProxyRoutes;
  const ACLIRoutes: TVDRX_CLIRoutes): TVDRX_HTTPSites;
var
  Rows: TVDRX_ConfigRows;
  Row: TStringList;
  Site: TVDRX_HTTPSite;
  n, i: Integer;
  RawHeaders: string;
  HeadersJSON: TJSONData;
  HeadersObj: TJSONObject;
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
        AProxyRoutes, ACLIRoutes, ARegistry);
      Site.HTTP.Port := StrToIntDef(Row.Values['port'], 8081);
      Site.HTTP.GracefulTimeoutMs := AGracefulMs;

      // Default CORS headers if "cors": true is declared
      if (Row.Values['cors'] = 'True') or (Row.Values['cors'] = 'true') or (Row.Values['cors'] = '1') then
      begin
        Site.HTTP.CustomHeaders.Values['Access-Control-Allow-Origin'] := '*';
        Site.HTTP.CustomHeaders.Values['Access-Control-Allow-Methods'] := 'GET, POST, OPTIONS';
        Site.HTTP.CustomHeaders.Values['Access-Control-Allow-Headers'] := '*';
      end;

      // Explicit custom response headers if "headers": { ... } object is provided
      RawHeaders := Row.Values['headers'];
      if RawHeaders <> '' then
      begin
        try
          HeadersJSON := GetJSON(RawHeaders);
          try
            if HeadersJSON is TJSONObject then
            begin
              HeadersObj := TJSONObject(HeadersJSON);
              for i := 0 to HeadersObj.Count - 1 do
                Site.HTTP.CustomHeaders.Values[HeadersObj.Names[i]] := HeadersObj.Items[i].AsString;
            end;
          finally
            HeadersJSON.Free;
          end;
        except
          // Ignore malformed JSON headers block
        end;
      end;

      if Row.Values['tls_port'] <> '' then
        Site.HTTP.ConfigureTLS(StrToIntDef(Row.Values['tls_port'], 0),
          Row.Values['tls_cert'], Row.Values['tls_key']);

      ARegistry.Register(Site.HTTP, Site.ID, 'sys.none');

      n := Length(Result);
      SetLength(Result, n + 1);
      Result[n] := Site;

      WriteLn('  HTTP site "', Site.ID, '": port ', Site.HTTP.Port,
        ', static="', ExpandFileName(IfThen(Row.Values['static_dir'] <> '', Row.Values['static_dir'], 'static')),
        '", templates="', Site.Templates.Dir, '"',
        IfThen(Site.HTTP.CustomHeaders.Count > 0, ' (' + IntToStr(Site.HTTP.CustomHeaders.Count) + ' custom headers/CORS)', ''));
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
  Protocol: string;
begin
  SetLength(ARoutes, 0);
  Rows := AConfig.GetObjectArray('cli_bridges');
  try
    for Row in Rows do
    begin
      if (Row.Values['id'] = '') or (Row.Values['prefix'] = '') then
      begin
        WriteLn('  Skipping cli_bridges entry - needs at least id and prefix.');
        Continue;
      end;

      Protocol := LowerCase(IfThen(Row.Values['protocol'] <> '', Row.Values['protocol'], 'cgi'));
      if (Protocol <> 'cgi') and (Protocol <> 'bus') and (Protocol <> 'bus-daemon') then
      begin
        WriteLn('  cli_bridges entry "', Row.Values['id'], '": unrecognized protocol "', Protocol, '" - using "cgi".');
        Protocol := 'cgi';
      end;

      if (Protocol = 'bus-daemon') and (Row.Values['in_topic'] = '') and (Row.Values['id'] = '') then
      begin
        WriteLn('  Skipping cli_bridges entry - protocol "bus-daemon" needs id (to default in_topic) or an explicit in_topic.');
        Continue;
      end;
      if (Protocol <> 'bus-daemon') and (Row.Values['command'] = '') then
      begin
        WriteLn('  Skipping cli_bridges entry "', Row.Values['id'], '" - protocol "', Protocol, '" also needs command.');
        Continue;
      end;
      if (Protocol = 'cgi') and (Row.Values['script_dir'] = '') then
      begin
        WriteLn('  Skipping cli_bridges entry "', Row.Values['id'], '" - protocol "cgi" also needs script_dir.');
        Continue;
      end;

      n := Length(ARoutes);
      SetLength(ARoutes, n + 1);
      ARoutes[n].Prefix := Row.Values['prefix'];
      ARoutes[n].Command := Row.Values['command'];
      ARoutes[n].ScriptDir := Row.Values['script_dir'];
      ARoutes[n].TimeoutMs := StrToIntDef(Row.Values['timeout_ms'], 5000);
      ARoutes[n].ContentType := IfThen(Row.Values['content_type'] <> '', Row.Values['content_type'], 'text/html');
      ARoutes[n].Protocol := Protocol;
      ARoutes[n].InTopic := IfThen(Row.Values['in_topic'] <> '', Row.Values['in_topic'], Row.Values['id'] + '.in');

      case Protocol of
        'bus':
          WriteLn('  CLI bridge "', Row.Values['id'], '" (bus): ', ARoutes[n].Prefix, ' -> ',
            ARoutes[n].Command, ' [cwd=', ExpandFileName(IfThen(ARoutes[n].ScriptDir <> '', ARoutes[n].ScriptDir, GetCurrentDir)),
            '] (timeout_ms=', ARoutes[n].TimeoutMs, ')');
        'bus-daemon':
          WriteLn('  CLI bridge "', Row.Values['id'], '" (bus-daemon): ', ARoutes[n].Prefix, ' -> in_topic="',
            ARoutes[n].InTopic, '" (timeout_ms=', ARoutes[n].TimeoutMs, ')');
      else
        WriteLn('  CLI bridge "', Row.Values['id'], '" (cgi): ', ARoutes[n].Prefix, ' -> ',
          ARoutes[n].Command, ' ', ExpandFileName(ARoutes[n].ScriptDir), '/* (timeout_ms=', ARoutes[n].TimeoutMs, ')');
      end;
    end;
  finally
    Rows.Free;
  end;
end;

procedure SetupTemplateExecutives(AConfig: TVDRX_Config; ARegistry: TVDRX_Registry);
var
  Rows: TVDRX_ConfigRows;
  Row: TStringList;
  Store: TVDRX_TemplateStore;
  Exec: TVDRX_TemplateExecutive;
begin
  Rows := AConfig.GetObjectArray('templates');
  try
    for Row in Rows do
    begin
      if (Row.Values['id'] = '') or (Row.Values['dir'] = '') then
      begin
        WriteLn('  Skipping templates entry - needs at least id and dir.');
        Continue;
      end;
      Store := TVDRX_TemplateStore.Create(AConfig, Row.Values['dir']);
      Exec := TVDRX_TemplateExecutive.Create(Kernel.Queue, Store);
      ARegistry.Register(Exec, Row.Values['id'], IfThen(Row.Values['subscribe'] <> '', Row.Values['subscribe'], Row.Values['id'] + '.in'));
      WriteLn('  Template executive "', Row.Values['id'], '": dir="', Store.Dir, '", subscribe="',
        IfThen(Row.Values['subscribe'] <> '', Row.Values['subscribe'], Row.Values['id'] + '.in'), '"');
    end;
  finally
    Rows.Free;
  end;
end;

procedure SetupBuckets(AConfig: TVDRX_Config; ARegistry: TVDRX_Registry);
var
  Rows: TVDRX_ConfigRows;
  Row: TStringList;
  Bucket: TVDRX_BucketExecutive;
  Filters: TStringArray;
  FilePath: string;
  MaxSizeMB, MaxFiles, EffectiveMaxFiles, i: Integer;
  RotateSuffix: string;
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
      // max_size_mb=0 (the default when omitted) keeps a bucket's original
      // unbounded-append behaviour; set it to enable rotation, optionally
      // paired with max_files (defaults to 5 rotated files) to cap total
      // disk use.
      MaxSizeMB := StrToIntDef(Row.Values['max_size_mb'], 0);
      MaxFiles := StrToIntDef(Row.Values['max_files'], 0);
      Bucket := TVDRX_BucketExecutive.Create(Kernel.Queue, FilePath, MaxSizeMB, MaxFiles);
      Filters := SplitString(Row.Values['topics'], ',');
      ARegistry.Register(Bucket, Row.Values['name'], Trim(Filters[0]));
      for i := 1 to High(Filters) do
        ARegistry.Register(Bucket, Row.Values['name'], Trim(Filters[i]));
      if MaxSizeMB > 0 then
      begin
        if MaxFiles > 0 then EffectiveMaxFiles := MaxFiles else EffectiveMaxFiles := 5;
        RotateSuffix := ', rotates at ' + IntToStr(MaxSizeMB) + 'MB (keeping ' +
          IntToStr(EffectiveMaxFiles) + ' old files)';
      end
      else
        RotateSuffix := '';
      WriteLn('  Bucket "', Row.Values['name'], '": ', Row.Values['topics'],
        ' -> ', FilePath, RotateSuffix);
    end;
  finally
    Rows.Free;
  end;
end;

procedure SetupSocketClients(AConfig: TVDRX_Config; ARegistry: TVDRX_Registry;
  AGracefulMs: Integer);
var
  Rows: TVDRX_ConfigRows;
  Row: TStringList;
  Client: TVDRX_SocketClientExecutive;
  FramingRaw, ReconnectRaw: string;
  Filters: TStringArray;
  i: Integer;
begin
  Rows := AConfig.GetObjectArray('socket_clients');
  try
    for Row in Rows do
    begin
      if (Row.Values['id'] = '') or (Row.Values['host'] = '') or (Row.Values['port'] = '') then
      begin
        WriteLn('  Skipping socket_clients entry - needs at least id, host, and port.');
        Continue;
      end;
      if (Row.Values['enabled'] = 'False') or (Row.Values['enabled'] = 'false') or (Row.Values['enabled'] = '0') then
      begin
        WriteLn('  Socket client "', Row.Values['id'], '": disabled (enabled=false) - skipping.');
        Continue;
      end;
      Client := TVDRX_SocketClientExecutive.Create(Kernel.Queue);
      Client.Host := Row.Values['host'];
      Client.Port := Word(StrToIntDef(Row.Values['port'], 0));
      Client.TLS := (Row.Values['tls'] = 'True') or (Row.Values['tls'] = 'true') or (Row.Values['tls'] = '1');
      Client.TLSVerify := not ((Row.Values['tls_verify'] = 'False') or (Row.Values['tls_verify'] = 'false') or (Row.Values['tls_verify'] = '0'));
      Client.TLSCAFile := Row.Values['tls_ca_file'];
      Client.TLSPeerName := Row.Values['tls_peer_name'];
      Client.GracefulTimeoutMs := StrToIntDef(Row.Values['graceful_timeout_ms'], AGracefulMs);

      FramingRaw := Row.Values['framing'];
      if FramingRaw = '' then FramingRaw := 'delimiter';
      if (FramingRaw <> 'delimiter') and (FramingRaw <> 'chunk') then
      begin
        WriteLn('  Socket client "', Row.Values['id'], '": unrecognized framing "', FramingRaw, '" - using "delimiter".');
        FramingRaw := 'delimiter';
      end;
      Client.Framing := FramingRaw;
      Client.Delimiter := IfThen(Row.Values['delimiter'] <> '', Row.Values['delimiter'], #13#10);
      Client.ChunkSize := StrToIntDef(Row.Values['chunk_size'], 4096);

      ReconnectRaw := Row.Values['reconnect'];
      if ReconnectRaw = '' then ReconnectRaw := 'auto';
      if (ReconnectRaw <> 'auto') and (ReconnectRaw <> 'none') then
      begin
        WriteLn('  Socket client "', Row.Values['id'], '": unrecognized reconnect "', ReconnectRaw, '" - using "auto".');
        ReconnectRaw := 'auto';
      end;
      Client.ReconnectPolicy := ReconnectRaw;
      Client.ReconnectDelayMs := StrToIntDef(Row.Values['reconnect_delay_ms'], 500);
      Client.MaxReconnectDelayMs := StrToIntDef(Row.Values['max_reconnect_delay_ms'], 30000);
      Client.PublishTopic := IfThen(Row.Values['publish'] <> '', Row.Values['publish'], Row.Values['id'] + '.out');

      if Row.Values['subscribe'] <> '' then
      begin
        Filters := SplitString(Row.Values['subscribe'], ',');
        ARegistry.Register(Client, Row.Values['id'], Trim(Filters[0]));
        for i := 1 to High(Filters) do
          ARegistry.Register(Client, Row.Values['id'], Trim(Filters[i]));
      end
      else
        ARegistry.Register(Client, Row.Values['id'], Row.Values['id'] + '.in');

      WriteLn('  Socket client "', Row.Values['id'], '": ', Row.Values['host'], ':', Client.Port,
        IfThen(Client.TLS, ' (TLS, verify=' + BoolToStr(Client.TLSVerify, True) + ')', ''),
        ', framing=', FramingRaw, ', reconnect=', ReconnectRaw);
    end;
  finally
    Rows.Free;
  end;
end;

begin

  try
    InstallShutdownSignalHandler;
    Kernel := TVDRX_Kernel.Create;
    Config := TVDRX_Config.Create('vdrx.conf');

    ApplyOpenSSLDLLOverrides(Config);

    ShutdownGraceMs := Config.GetInteger('shutdown_grace_ms', 5000);

    Logger := TVDRX_LoggerExecutive.Create(Kernel.Queue, 'vdrx_daemon.log', lvlINFO);
    Kernel.Registry.Register(Logger, 'logger', '>');

    Admin := TVDRX_AdminExecutive.Create(Kernel.Queue, Config, Kernel.Registry, Kernel);
    Kernel.Registry.Register(Admin, 'admin', 'sys.>');

    if Config.GetBoolean('stdin_admin_enabled', True) then
    begin
      Stdin := TVDRX_StdinExecutive.Create(Kernel.Queue);
      Kernel.Registry.Register(Stdin, 'stdin', 'sys.none');
    end;

    if Config.GetBoolean('executives.ws.enabled', False) then
    begin
      WS := TVDRX_WebSocketExecutive.Create(Kernel.Queue, Config, Kernel.Registry);
      WS.Port := Config.GetInteger('executives.ws.port', 8082);
      WS.GracefulTimeoutMs := ShutdownGraceMs;
      WS.DefaultSubscribe := Config.GetString('executives.ws.default_subscribe', '');
      ConfigureListenerTLS(WS, 'executives.ws');
      Kernel.Registry.Register(WS, 'ws', 'sys.none');
    end;

    SetupProcesses(Config, Kernel.Registry, ShutdownGraceMs, ProxyRoutes);
    SetupSocketClients(Config, Kernel.Registry, ShutdownGraceMs);
    SetupCLIBridges(Config, CLIRoutes);
    SetupTemplateExecutives(Config, Kernel.Registry);
    SetupBuckets(Config, Kernel.Registry);

    HTTPSites := SetupHTTPSites(Config, Kernel.Registry, ShutdownGraceMs, ProxyRoutes, CLIRoutes);

    Kernel.Start;

    WriteLn('VDRX daemon running.');
    if Assigned(WS) then ReportListener(WS, 'WebSocket');
    for i := 0 to High(HTTPSites) do
      ReportListener(HTTPSites[i].HTTP, 'HTTP (' + HTTPSites[i].ID + ')');
    WriteLn('  Logger writing to vdrx_daemon.log (console threshold: INFO).');
    if Assigned(Stdin) then
      WriteLn('  Type quit / restart / reload / kill <pid-or-id> / killall [type] and press Enter to control the daemon.');
    WriteLn('  Shutdown grace period: ', ShutdownGraceMs, 'ms before hung threads/processes are force-killed.');
    WriteLn('  Ctrl+C for a clean shutdown - every supervised process gets its own graceful-then-forced teardown, same as typing quit.');

    ShutdownWatcher := TVDRX_ShutdownWatcherThread.Create(Kernel);

    Kernel.WaitFor;
    ShutdownWatcher.Terminate;
    WaitThreadOrTimeout(ShutdownWatcher, 500);
    ShutdownWatcher.Free;
    DoRestart := Kernel.RestartRequested;
    Kernel.Free;
    for i := 0 to High(HTTPSites) do
      HTTPSites[i].Templates.Free;
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
        NewProc.Options := [];
        NewProc.Execute;
      finally
        NewProc.Free;
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
