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
      // "enabled": false (default true) - skip standing this one up entirely,
      // without having to delete/comment it out of the config. Checked here,
      // same place as the id/command validation above, so a disabled entry
      // costs nothing beyond this one string compare.
      if (Row.Values['enabled'] = 'False') or (Row.Values['enabled'] = 'false') or (Row.Values['enabled'] = '0') then
      begin
        WriteLn('  Process "', Row.Values['id'], '": disabled (enabled=false) - skipping.');
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
      // it just never had a real subscription routed to it before). Omit it
      // entirely and this falls back to "<id>.in" - a literal topic, not a
      // wildcard, so it only ever matches something explicitly published TO
      // this process by name. That's a change from the old default (nothing
      // at all, registered on the unmatchable 'sys.none') - every executive
      // type having a sensible pub/sub default, rather than requiring
      // "subscribe" just to be reachable at all, is deliberate config
      // consistency (see the readme's §2 note on this).
      if Row.Values['subscribe'] <> '' then
      begin
        Filters := SplitString(Row.Values['subscribe'], ',');
        ARegistry.Register(Bridge, Row.Values['id'], Trim(Filters[0]));
        for i := 1 to High(Filters) do
          ARegistry.Register(Bridge, Row.Values['id'], Trim(Filters[i]));
      end
      else
        ARegistry.Register(Bridge, Row.Values['id'], Row.Values['id'] + '.in');

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
        AProxyRoutes, ACLIRoutes, ARegistry);
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
        ', static="', ExpandFileName(IfThen(Row.Values['static_dir'] <> '', Row.Values['static_dir'], 'static')),
        '", templates="', Site.Templates.Dir, '"');
    end;
  finally
    Rows.Free;
  end;
end;

// "protocol": "cgi" (default) | "bus" | "bus-daemon" - see TVDRX_CLIRoute's
// comment in vdrx_network.pas for the full contract differences.
//   'cgi'        - needs id/prefix/command/script_dir (original behaviour).
//   'bus'        - needs id/prefix/command; script_dir optional (just sets
//                  the spawned process's CWD, defaults to '.').
//   'bus-daemon' - needs id/prefix/in_topic; command/script_dir are unused
//                  (nothing is spawned - requests are published to in_topic
//                  for whatever's already subscribed there, typically a
//                  persistent `processes` entry, to answer).
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
      ARoutes[n].ScriptDir := Row.Values['script_dir']; // optional for 'bus' - RunBusCLIScript falls back to '.'; unused for 'bus-daemon'
      ARoutes[n].TimeoutMs := StrToIntDef(Row.Values['timeout_ms'], 5000);
      ARoutes[n].ContentType := IfThen(Row.Values['content_type'] <> '', Row.Values['content_type'], 'text/html');
      ARoutes[n].Protocol := Protocol;
      // Same "<id>.in" fallback as every other executive type - see
      // SetupProcesses' comment for why.
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

// One TVDRX_TemplateExecutive per "templates" config entry, registered on
// whatever "subscribe" filter it declares (same comma/array-joined pattern
// GetObjectArray already flattens everywhere else - "processes"' subscribe,
// "buckets"' topics). Each entry owns its own TVDRX_TemplateStore rooted at
// "dir" - completely independent of any http_sites entry's own
// template_dir, which is the point: a bus-CLI reply's "template_topic"
// names one of THESE explicitly, rather than implicitly inheriting whatever
// HTTP site's connection happened to answer the request - see
// BuildBusCLIResponse's comment in vdrx_network.pas.
//
//   { "id": "admin_templates", "dir": "templates", "subscribe": "template.admin.render" }
//
// Deliberately not tied to http_sites at all in config - an included app's
// own config (see the "includes" mechanism) can define its own template
// executive alongside its own cli_bridges routes, with no coordination
// needed with vdrx.conf's own http_sites beyond agreeing on a topic name.
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
      Exec := TVDRX_TemplateExecutive.Create(Kernel.Queue, Store); // owns Store - see TVDRX_TemplateExecutive.Destroy
      // Same "<id>.in" fallback as every other executive type - see
      // SetupProcesses' comment for why.
      ARegistry.Register(Exec, Row.Values['id'], IfThen(Row.Values['subscribe'] <> '', Row.Values['subscribe'], Row.Values['id'] + '.in'));
      WriteLn('  Template executive "', Row.Values['id'], '": dir="', Store.Dir, '", subscribe="',
        IfThen(Row.Values['subscribe'] <> '', Row.Values['subscribe'], Row.Values['id'] + '.in'), '"');
    end;
  finally
    Rows.Free;
  end;
end;
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

// Every entry in "socket_clients" gets its own TVDRX_SocketClientExecutive -
// a supervised outbound TCP/TLS connection, the dialer counterpart to
// SetupProcesses' spawned children. id/host/port are the only required
// fields; everything else falls back to sane defaults (see
// TVDRX_SocketClientExecutive.Create) exactly like SetupProcesses does for
// "processes". "subscribe" uses the same comma-joined-filter convention as
// "processes" - filters this instance's socket writes, not its own inbound
// data (that always publishes to "<id>.out", unconditionally, same as
// Bridge's stdout).
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

      // "framing": "delimiter" (default) | "chunk" - see TVDRX_SocketClientExecutive
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

      // "reconnect": "auto" (default) | "none" - see TVDRX_SocketClientExecutive
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

      // Same "<id>.in" fallback as SetupProcesses - see its comment for why.
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
    InstallShutdownSignalHandler; // Ctrl+C/SIGINT/SIGTERM - see vdrx_procutil.pas
    Kernel := TVDRX_Kernel.Create;
    Config := TVDRX_Config.Create('vdrx.conf');

    // Must run before Registry.InitializeAll (Kernel.Start below) - any
    // executive whose Initialize does a TLS handshake needs the right DLLs
    // already pointed at before that call. See ApplyOpenSSLDLLOverrides'
    // comment in vdrx_network.pas.
    ApplyOpenSSLDLLOverrides(Config);

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
      WS.DefaultSubscribe := Config.GetString('executives.ws.default_subscribe', '');
      ConfigureListenerTLS(WS, 'executives.ws');
      Kernel.Registry.Register(WS, 'ws', 'sys.none'); // each connection registers itself
    end;

    SetupProcesses(Config, Kernel.Registry, ShutdownGraceMs, ProxyRoutes);
    SetupSocketClients(Config, Kernel.Registry, ShutdownGraceMs);
    SetupCLIBridges(Config, CLIRoutes);
    SetupTemplateExecutives(Config, Kernel.Registry);
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
    WriteLn('  Ctrl+C for a clean shutdown - every supervised process gets its own graceful-then-forced teardown, same as typing quit.');

    ShutdownWatcher := TVDRX_ShutdownWatcherThread.Create(Kernel);

    Kernel.WaitFor; // returns once sys.quit/sys.restart/Ctrl+C has driven Kernel.Terminate
                     // and ShutdownAll has finished tearing everything down cleanly
    ShutdownWatcher.Terminate;
    WaitThreadOrTimeout(ShutdownWatcher, 500);
    ShutdownWatcher.Free;
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

