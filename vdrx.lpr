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
  RegExpr,
  vdrx_core,
  vdrx_config,
  vdrx_admin,
  vdrx_logger,
  vdrx_stdin,
  vdrx_bridge,
  vdrx_bucket,
  vdrx_network,
  vdrx_templates,
  vdrx_runner,
  vdrx_cgi,
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
  Routes: TVDRX_RouteTable;
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

      // "publish_allow": topic patterns the child process may publish to.
      // (Formerly called "publish" - still accepted, but "publish" is now
      // reserved for "the topic this thing writes its output to", as it is on
      // socket_clients and runners.)
      if Row.Values['publish_allow'] <> '' then
        Bridge.PublishPatterns := Row.Values['publish_allow']
      else
      begin
        Bridge.PublishPatterns := Row.Values['publish'];
        if Row.Values['publish'] <> '' then
          WriteLn('  Process "', Row.Values['id'], '": "publish" is deprecated here - rename it to "publish_allow" (same meaning).');
      end;

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
          ', restart=', RestartRaw, ', graceful_timeout_ms=', BridgeGraceMs, GroupSuffix,
          ', subscribe=', IfThen(Row.Values['subscribe'] <> '', Row.Values['subscribe'], Row.Values['id'] + '.in'),
          ', output -> ', Row.Values['id'], '.out)');
      end
      else
        WriteLn('  Process "', Row.Values['id'], '" (', Row.Values['command'],
          ', restart=', RestartRaw, ', graceful_timeout_ms=', BridgeGraceMs, GroupSuffix,
          ', subscribe=', IfThen(Row.Values['subscribe'] <> '', Row.Values['subscribe'], Row.Values['id'] + '.in'),
          ', output -> ', Row.Values['id'], '.out)');
    end;
  finally
    Rows.Free;
  end;
end;

function SetupHTTPSites(AConfig: TVDRX_Config; ARegistry: TVDRX_Registry;
  AGracefulMs: Integer; const ARoutes: TVDRX_RouteTable): TVDRX_HTTPSites;
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
        ARoutes, ARegistry);
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

// cli_bridges "exit_status": {"1": 422, "3": 400} arrives as JSON text (nested
// objects are stored that way by GetObjectArray); turn it into "1=422,3=400".
function ExitStatusToPairs(const AJSON: string): string;
var
  D: TJSONData;
  i: Integer;
begin
  Result := '';
  if Trim(AJSON) = '' then Exit;
  try
    D := GetJSON(AJSON);
  except
    WriteLn('  cli_bridges: exit_status is not valid JSON - ignored.');
    Exit;
  end;
  try
    if D is TJSONObject then
      for i := 0 to TJSONObject(D).Count - 1 do
      begin
        if Result <> '' then Result := Result + ',';
        Result := Result + TJSONObject(D).Names[i] + '=' + TJSONObject(D).Items[i].AsString;
      end
    else
      WriteLn('  cli_bridges: exit_status must be an object like {"1": 422} - ignored.');
  finally
    D.Free;
  end;
end;

// http_routes: "this URL prefix publishes the request onto the bus topic
// in_topic and returns whatever reply comes back" - the generic way for ANY
// executive (runner, supervised daemon, WebSocket client ...) to serve HTTP.
//   id           names the route; also the default in_topic ("<id>.in"), so a
//                route and a runner that share an id are wired together
//   prefix       URL prefix (required)
//   in_topic     bus topic the request envelope is published to
//   allow        HTTP methods accepted, default "POST" (others get 405)
//   timeout_ms   how long to wait for the reply, default 10000 (-> 504)
//   content_type of a successful reply when the reply doesn't say, default text/plain
//   response     "raw" (default: the reply's own status/headers/body) or
//                "json" (the whole reply envelope returned as application/json)
procedure SetupHTTPRoutes(AConfig: TVDRX_Config; var ARoutes: TVDRX_BusRoutes);
var
  Rows: TVDRX_ConfigRows;
  Row: TStringList;
  n: Integer;
  Resp: string;
begin
  Rows := AConfig.GetObjectArray('http_routes');
  try
    for Row in Rows do
    begin
      if (Row.Values['id'] = '') or (Row.Values['prefix'] = '') then
      begin
        WriteLn('  Skipping http_routes entry - needs at least id and prefix.');
        Continue;
      end;
      Resp := LowerCase(IfThen(Row.Values['response'] <> '', Row.Values['response'], 'raw'));
      if (Resp <> 'raw') and (Resp <> 'json') then
      begin
        WriteLn('  http_routes entry "', Row.Values['id'], '": unrecognized response "', Resp, '" - using "raw".');
        Resp := 'raw';
      end;
      n := Length(ARoutes);
      SetLength(ARoutes, n + 1);
      ARoutes[n].ID := Row.Values['id'];
      ARoutes[n].Kind := 'bus';
      ARoutes[n].Prefix := Row.Values['prefix'];
      ARoutes[n].InTopic := IfThen(Row.Values['in_topic'] <> '', Row.Values['in_topic'], Row.Values['id'] + '.in');
      ARoutes[n].Allow := IfThen(Row.Values['allow'] <> '', Row.Values['allow'], 'POST');
      ARoutes[n].TimeoutMs := StrToIntDef(Row.Values['timeout_ms'], 10000);
      ARoutes[n].ContentType := IfThen(Row.Values['content_type'] <> '', Row.Values['content_type'], 'text/plain');
      ARoutes[n].Response := Resp;
      WriteLn('  HTTP route "', Row.Values['id'], '": ', ARoutes[n].Allow, ' ', ARoutes[n].Prefix,
        ' -> publish "', ARoutes[n].InTopic, '", await reply (timeout_ms=', ARoutes[n].TimeoutMs,
        ', response=', Resp, ')');
    end;
  finally
    Rows.Free;
  end;
end;

// JSON array text -> TStringList of its elements ('' / invalid -> empty)
procedure JSONArrayToList(const AJSON: string; AList: TStrings);
var
  D: TJSONData;
  i: Integer;
begin
  AList.Clear;
  if Trim(AJSON) = '' then Exit;
  try
    D := GetJSON(AJSON);
  except
    Exit;
  end;
  try
    if D is TJSONArray then
      for i := 0 to TJSONArray(D).Count - 1 do
        AList.Add(TJSONArray(D).Items[i].AsString);
  finally
    D.Free;
  end;
end;

function ConfBool(const AValue: string; ADefault: Boolean): Boolean;
begin
  if AValue = '' then Exit(ADefault);
  Result := not ((AValue = 'False') or (AValue = 'false') or (AValue = '0'));
end;

// cgi: a CGI adaptor (vdrx_cgi.pas) AND the HTTP route that feeds it. A web
// server's "run this through php-cgi" in one entry; the program is just a
// consumer of bus messages.
//   id            required; default in_topic "<id>.in"
//   prefix        required; URL prefix this entry serves ("/" = the whole site)
//   doc_root      required; directory the URL (minus prefix) maps onto
//   command       program to run, e.g. "{PHP_CGI_BIN_FILENAME}"; "" = the script
//                 file itself is the executable (classic cgi-bin: .cgi/.exe/#!)
//   args          array of arguments; "%%script%%" = absolute script filename.
//                 Default ["%%script%%"]  ->  php-cgi /www/index.php
//   extensions    array of script extensions, default [".php"] (or [".cgi"] when
//                 command is ""); any other existing file under doc_root is static
//   index         array of directory index files, default ["index.php", "index.html"]
//   fallback      URL path of a front-controller script ("/index.php") that gets
//                 every request that matched no file - pretty URLs / frameworks
//   static        serve non-script files from doc_root (default true)
//   allow         accepted HTTP methods, default any
//   env           object of extra environment variables for the program
//   work_dir      working directory; default = the script's own directory
//   output        "cgi" (default: program prints headers, blank line, body) or
//                 "raw" (stdout is the body verbatim, status 200)
//   timeout_ms (30000), workers (4), max_queue (64), content_type (text/html),
//   in_topic, enabled
procedure SetupCGI(AConfig: TVDRX_Config; ARegistry: TVDRX_Registry;
  AGracefulMs: Integer; var ARoutes: TVDRX_BusRoutes);
var
  Rows: TVDRX_ConfigRows;
  Row: TStringList;
  Exec: TVDRX_CGIExecutive;
  Args, Exts, Idx, Env: TStringList;
  EnvJSON: TJSONData;
  n, i: Integer;
  Id, InTopic, Ext: string;
begin
  Rows := AConfig.GetObjectArray('cgi');
  try
    for Row in Rows do
    begin
      Id := Row.Values['id'];
      if (Id = '') or (Row.Values['prefix'] = '') or (Row.Values['doc_root'] = '') then
      begin
        WriteLn('  Skipping cgi entry - needs at least id, prefix and doc_root.');
        Continue;
      end;
      if not ConfBool(Row.Values['enabled'], True) then
      begin
        WriteLn('  CGI "', Id, '": disabled (enabled=false) - skipping.');
        Continue;
      end;
      InTopic := IfThen(Row.Values['in_topic'] <> '', Row.Values['in_topic'], Id + '.in');

      Exec := TVDRX_CGIExecutive.Create(Kernel.Queue);
      Exec.SetCommand(Row.Values['command']);
      Args := TStringList.Create;
      Exts := TStringList.Create;
      Idx := TStringList.Create;
      Env := TStringList.Create;
      try
        JSONArrayToList(Row.Values['args#json'], Args);
        Exec.SetArgs(Args);   // empty = just the script
        Exec.WorkDir := Row.Values['work_dir'];
        Exec.TimeoutMs := StrToIntDef(Row.Values['timeout_ms'], 30000);
        Exec.Workers := StrToIntDef(Row.Values['workers'], 4);
        Exec.MaxQueue := StrToIntDef(Row.Values['max_queue'], 64);
        Exec.GraceMs := AGracefulMs;
        Exec.ContentType := IfThen(Row.Values['content_type'] <> '', Row.Values['content_type'], 'text/html');
        Exec.PublishTopic := Id + '.out';
        Exec.RawOutput := LowerCase(Row.Values['output']) = 'raw';
        if Row.Values['env'] <> '' then
        begin
          try
            EnvJSON := GetJSON(Row.Values['env']);
            try
              if EnvJSON is TJSONObject then
                for i := 0 to TJSONObject(EnvJSON).Count - 1 do
                  Env.Add(TJSONObject(EnvJSON).Names[i] + '=' + TJSONObject(EnvJSON).Items[i].AsString);
            finally
              EnvJSON.Free;
            end;
          except
            WriteLn('  CGI "', Id, '": "env" is not a valid JSON object - ignored.');
          end;
        end;
        Exec.SetExtraEnv(Env);
        ARegistry.Register(Exec, Id, InTopic);

        JSONArrayToList(Row.Values['extensions#json'], Exts);
        if Exts.Count = 0 then Exts.Add(IfThen(Row.Values['command'] <> '', '.php', '.cgi'));
        JSONArrayToList(Row.Values['index#json'], Idx);
        if Idx.Count = 0 then
        begin
          Idx.Add('index.php');
          Idx.Add('index.html');
        end;

        n := Length(ARoutes);
        SetLength(ARoutes, n + 1);
        ARoutes[n].ID := Id;
        ARoutes[n].Kind := 'cgi';
        ARoutes[n].Prefix := Row.Values['prefix'];
        ARoutes[n].InTopic := InTopic;
        ARoutes[n].Allow := Row.Values['allow'];
        ARoutes[n].TimeoutMs := Exec.TimeoutMs;
        ARoutes[n].ContentType := Exec.ContentType;
        ARoutes[n].Response := 'raw';
        ARoutes[n].DocRoot := ExpandFileName(Row.Values['doc_root']);
        ARoutes[n].Extensions := ',';
        for i := 0 to Exts.Count - 1 do
        begin
          Ext := LowerCase(Trim(Exts[i]));
          if Ext = '' then Continue;
          if Ext[1] <> '.' then Ext := '.' + Ext;
          ARoutes[n].Extensions := ARoutes[n].Extensions + Ext + ',';
        end;
        ARoutes[n].IndexFiles := Idx.CommaText;
        ARoutes[n].Fallback := Row.Values['fallback'];
        ARoutes[n].Static := ConfBool(Row.Values['static'], True);
        WriteLn('  CGI "', Id, '": ', ARoutes[n].Prefix, ' -> ', IfThen(Row.Values['command'] <> '', Row.Values['command'], '(script itself)'),
          ' [doc_root=', ARoutes[n].DocRoot, ', ext=', Copy(ARoutes[n].Extensions, 2, Length(ARoutes[n].Extensions) - 2),
          IfThen(ARoutes[n].Fallback <> '', ', fallback=' + ARoutes[n].Fallback, ''),
          ', workers=', Exec.Workers, ', timeout_ms=', Exec.TimeoutMs, ']');
      finally
        Env.Free;
        Idx.Free;
        Exts.Free;
        Args.Free;
      end;
    end;
  finally
    Rows.Free;
  end;
end;

// rewrites: regex on the request path -> new target, applied before any routing.
//   match   regular expression (required), tested against the path (no query)
//   to      replacement target (required); $1, $2 ... are the regex groups; a
//           "?x=$1" part REPLACES the query string, without one the client's is kept
//   flag    "last" (default - the first matching rule wins) | "continue" (keep
//           applying later rules to the result) | "redirect" (302) | "permanent" (301)
procedure SetupRewrites(AConfig: TVDRX_Config; out ARules: TVDRX_RewriteRules);
var
  Rows: TVDRX_ConfigRows;
  Row: TStringList;
  Re: TRegExpr;
  n: Integer;
  Flag: string;
begin
  SetLength(ARules, 0);
  Rows := AConfig.GetObjectArray('rewrites');
  try
    for Row in Rows do
    begin
      if (Row.Values['match'] = '') or (Row.Values['to'] = '') then
      begin
        WriteLn('  Skipping rewrites entry - needs match and to.');
        Continue;
      end;
      Flag := LowerCase(IfThen(Row.Values['flag'] <> '', Row.Values['flag'], 'last'));
      if (Flag <> 'last') and (Flag <> 'continue') and (Flag <> 'redirect') and (Flag <> 'permanent') then
      begin
        WriteLn('  rewrites entry "', Row.Values['match'], '": unrecognized flag "', Flag, '" - using "last".');
        Flag := 'last';
      end;
      Re := TRegExpr.Create;
      try
        try
          Re.Expression := Row.Values['match'];
          Re.Compile;   // surface a bad pattern now, not on the first request
        except
          on E: Exception do
          begin
            WriteLn('  Skipping rewrites entry "', Row.Values['match'], '": bad regular expression - ', E.Message);
            Continue;
          end;
        end;
      finally
        Re.Free;
      end;
      n := Length(ARules);
      SetLength(ARules, n + 1);
      ARules[n].Pattern := Row.Values['match'];
      ARules[n].Target := Row.Values['to'];
      ARules[n].Flag := Flag;
      WriteLn('  Rewrite: ', ARules[n].Pattern, ' -> ', ARules[n].Target, ' [', Flag, ']');
    end;
  finally
    Rows.Free;
  end;
end;

// cli_bridges is the OLD way of reaching a program over HTTP, kept working by
// translating each entry into the current machinery (so it gets the same
// fixes) and logging a nudge:
//   protocol "cgi" (default)  -> a cgi entry (doc_root = script_dir, any file is a
//                                script, output "raw": stdout is the body)
//   protocol "bus"            -> a runner in envelope mode + an http route
//   protocol "bus-daemon"     -> an http route
// New configs should use cgi / runners + http_routes directly (readme section 4).
procedure SetupLegacyCLIBridges(AConfig: TVDRX_Config; ARegistry: TVDRX_Registry;
  AGracefulMs: Integer; var ARoutes: TVDRX_BusRoutes);
var
  Rows: TVDRX_ConfigRows;
  Row: TStringList;
  n: Integer;
  Protocol, Id, InTopic: string;
  Cgi: TVDRX_CGIExecutive;
  Run: TVDRX_RunnerExecutive;
  TimeoutMs: Integer;
begin
  Rows := AConfig.GetObjectArray('cli_bridges');
  try
    for Row in Rows do
    begin
      Id := Row.Values['id'];
      if (Id = '') or (Row.Values['prefix'] = '') then
      begin
        WriteLn('  Skipping cli_bridges entry - needs at least id and prefix.');
        Continue;
      end;
      Protocol := LowerCase(IfThen(Row.Values['protocol'] <> '', Row.Values['protocol'], 'cgi'));
      if Protocol = 'exec' then
      begin
        WriteLn('  Skipping cli_bridges entry "', Id, '": protocol "exec" no longer exists - declare a runners entry plus an http_routes entry instead (see readme 4e).');
        Continue;
      end;
      if (Protocol <> 'cgi') and (Protocol <> 'bus') and (Protocol <> 'bus-daemon') then
      begin
        WriteLn('  cli_bridges entry "', Id, '": unrecognized protocol "', Protocol, '" - using "cgi".');
        Protocol := 'cgi';
      end;
      if (Protocol <> 'bus-daemon') and (Row.Values['command'] = '') then
      begin
        WriteLn('  Skipping cli_bridges entry "', Id, '" - protocol "', Protocol, '" also needs command.');
        Continue;
      end;
      if (Protocol = 'cgi') and (Row.Values['script_dir'] = '') then
      begin
        WriteLn('  Skipping cli_bridges entry "', Id, '" - protocol "cgi" also needs script_dir.');
        Continue;
      end;

      TimeoutMs := StrToIntDef(Row.Values['timeout_ms'], 5000);
      InTopic := IfThen(Row.Values['in_topic'] <> '', Row.Values['in_topic'], Id + '.in');
      n := Length(ARoutes);
      SetLength(ARoutes, n + 1);
      ARoutes[n].ID := Id;
      ARoutes[n].Prefix := Row.Values['prefix'];
      ARoutes[n].InTopic := InTopic;
      ARoutes[n].Allow := Row.Values['allow'];
      ARoutes[n].TimeoutMs := TimeoutMs;
      ARoutes[n].ContentType := IfThen(Row.Values['content_type'] <> '', Row.Values['content_type'], 'text/html');
      ARoutes[n].Response := Row.Values['response'];
      ARoutes[n].Kind := 'bus';

      if Protocol = 'bus-daemon' then
        WriteLn('  cli_bridges "', Id, '" (bus-daemon): deprecated - same as an http_routes entry; ', ARoutes[n].Prefix, ' -> "', InTopic, '"')
      else if Protocol = 'bus' then
      begin
        Run := TVDRX_RunnerExecutive.Create(Kernel.Queue);
        Run.SetCommand(Row.Values['command']);
        Run.EnvelopeMode := True;
        Run.WorkDir := Row.Values['script_dir'];
        Run.TimeoutMs := TimeoutMs;
        Run.Workers := 4;
        Run.GraceMs := AGracefulMs;
        Run.PublishTopic := Id + '.out';
        ARegistry.Register(Run, Id, InTopic);
        ARoutes[n].TimeoutMs := TimeoutMs + 2000;   // let the runner's own 504 arrive first
        WriteLn('  cli_bridges "', Id, '" (bus): deprecated - now a runner (envelope mode) + http route: ',
          ARoutes[n].Prefix, ' -> ', Row.Values['command']);
      end
      else
      begin
        Cgi := TVDRX_CGIExecutive.Create(Kernel.Queue);
        Cgi.SetCommand(Row.Values['command']);
        Cgi.TimeoutMs := TimeoutMs;
        Cgi.Workers := 2;
        Cgi.GraceMs := AGracefulMs;
        Cgi.ContentType := ARoutes[n].ContentType;
        Cgi.PublishTopic := Id + '.out';
        Cgi.RawOutput := True;
        ARegistry.Register(Cgi, Id, InTopic);
        ARoutes[n].Kind := 'cgi';
        ARoutes[n].DocRoot := ExpandFileName(Row.Values['script_dir']);
        ARoutes[n].Extensions := '';        // any file under script_dir is a script, as before
        ARoutes[n].IndexFiles := '';
        ARoutes[n].Fallback := '';
        ARoutes[n].Static := False;
        WriteLn('  cli_bridges "', Id, '" (cgi): deprecated - now a cgi entry (output "raw"): ',
          ARoutes[n].Prefix, ' -> ', Row.Values['command'], ' ', ARoutes[n].DocRoot, '/*');
      end;
    end;
  finally
    Rows.Free;
  end;
end;

// runners: run an ordinary command-line program once per bus message (see
// vdrx_runner.pas). Config:
//   id            required; defaults: subscribe "<id>.in", publish "<id>.out"
//   command       required; the program (and any fixed leading arguments)
//   args          optional array of further arguments; "%%name%%" is filled
//                 from the message's params/query, "%%name?%%" if optional
//   subscribe     topic(s) it listens on
//   publish       where results go when the message has no reply_to
//   stdin         "body" (default) or "none"
//   exit_status   {"1": 422, "3": 400}: exit code -> reply status (else 500)
//   timeout_ms    default 10000 (-> reply status 504, program killed)
//   workers       programs allowed to run at once, default 2
//   max_queue     waiting messages allowed, default 64 (-> reply status 503)
//   content_type  of a successful reply, default text/plain
//   script_dir    working directory for the program
procedure SetupRunners(AConfig: TVDRX_Config; ARegistry: TVDRX_Registry;
  AGracefulMs: Integer);
var
  Rows: TVDRX_ConfigRows;
  Row: TStringList;
  Runner: TVDRX_RunnerExecutive;
  Args: TStringList;
  Filters: TStringArray;
  ArgsJSON: TJSONData;
  SubDesc, PubDesc: string;
  i: Integer;
begin
  Rows := AConfig.GetObjectArray('runners');
  try
    for Row in Rows do
    begin
      if (Row.Values['id'] = '') or (Row.Values['command'] = '') then
      begin
        WriteLn('  Skipping runners entry - needs at least id and command.');
        Continue;
      end;
      if (Row.Values['enabled'] = 'False') or (Row.Values['enabled'] = 'false') or (Row.Values['enabled'] = '0') then
      begin
        WriteLn('  Runner "', Row.Values['id'], '": disabled (enabled=false) - skipping.');
        Continue;
      end;

      Runner := TVDRX_RunnerExecutive.Create(Kernel.Queue);
      Runner.SetCommand(Row.Values['command']);
      Args := TStringList.Create;
      try
        if Row.Values['args#json'] <> '' then
        begin
          try
            ArgsJSON := GetJSON(Row.Values['args#json']);
            try
              if ArgsJSON is TJSONArray then
                for i := 0 to TJSONArray(ArgsJSON).Count - 1 do
                  Args.Add(TJSONArray(ArgsJSON).Items[i].AsString);
            finally
              ArgsJSON.Free;
            end;
          except
            WriteLn('  Runner "', Row.Values['id'], '": "args" is not a valid JSON array - ignored.');
          end;
        end;
        Runner.SetArgs(Args);
      finally
        Args.Free;
      end;
      Runner.StdinFromBody := LowerCase(IfThen(Row.Values['stdin'] <> '', Row.Values['stdin'], 'body')) <> 'none';
      Runner.WorkDir := Row.Values['script_dir'];
      Runner.TimeoutMs := StrToIntDef(Row.Values['timeout_ms'], 10000);
      Runner.Workers := StrToIntDef(Row.Values['workers'], 2);
      Runner.MaxQueue := StrToIntDef(Row.Values['max_queue'], 64);
      Runner.GraceMs := AGracefulMs;
      Runner.ContentType := IfThen(Row.Values['content_type'] <> '', Row.Values['content_type'], 'text/plain');
      Runner.PublishTopic := IfThen(Row.Values['publish'] <> '', Row.Values['publish'], Row.Values['id'] + '.out');
      Runner.SetExitStatus(ExitStatusToPairs(Row.Values['exit_status']));

      SubDesc := IfThen(Row.Values['subscribe'] <> '', Row.Values['subscribe'], Row.Values['id'] + '.in');
      Filters := SplitString(SubDesc, ',');
      ARegistry.Register(Runner, Row.Values['id'], Trim(Filters[0]));
      for i := 1 to High(Filters) do
        ARegistry.Register(Runner, Row.Values['id'], Trim(Filters[i]));
      PubDesc := Runner.PublishTopic;
      WriteLn('  Runner "', Row.Values['id'], '": subscribe=', SubDesc, ', replies to reply_to or ', PubDesc,
        ' (', Row.Values['command'], ', workers=', Runner.Workers, ', max_queue=', Runner.MaxQueue,
        ', timeout_ms=', Runner.TimeoutMs, ')');
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
  RotateSuffix, BucketID, BucketTopics: string;
begin
  Rows := AConfig.GetObjectArray('buckets');
  try
    for Row in Rows do
    begin
      // "id" + "subscribe" match every other executive; the older "name" +
      // "topics" spellings are still accepted.
      BucketID := IfThen(Row.Values['id'] <> '', Row.Values['id'], Row.Values['name']);
      BucketTopics := IfThen(Row.Values['subscribe'] <> '', Row.Values['subscribe'], Row.Values['topics']);
      if (Row.Values['id'] = '') and (Row.Values['name'] <> '') then
        WriteLn('  Bucket "', BucketID, '": "name" is deprecated - rename it to "id".');
      if (Row.Values['subscribe'] = '') and (Row.Values['topics'] <> '') then
        WriteLn('  Bucket "', BucketID, '": "topics" is deprecated - rename it to "subscribe".');
      if (BucketID = '') or (BucketTopics = '') then
      begin
        WriteLn('  Skipping buckets entry - needs at least id and subscribe.');
        Continue;
      end;
      FilePath := IfThen(Row.Values['file'] <> '', Row.Values['file'],
        'bucket_' + BucketID + '.jsonl');
      // max_size_mb=0 (the default when omitted) keeps a bucket's original
      // unbounded-append behaviour; set it to enable rotation, optionally
      // paired with max_files (defaults to 5 rotated files) to cap total
      // disk use.
      MaxSizeMB := StrToIntDef(Row.Values['max_size_mb'], 0);
      MaxFiles := StrToIntDef(Row.Values['max_files'], 0);
      Bucket := TVDRX_BucketExecutive.Create(Kernel.Queue, FilePath, MaxSizeMB, MaxFiles);
      Filters := SplitString(BucketTopics, ',');
      ARegistry.Register(Bucket, BucketID, Trim(Filters[0]));
      for i := 1 to High(Filters) do
        ARegistry.Register(Bucket, BucketID, Trim(Filters[i]));
      if MaxSizeMB > 0 then
      begin
        if MaxFiles > 0 then EffectiveMaxFiles := MaxFiles else EffectiveMaxFiles := 5;
        RotateSuffix := ', rotates at ' + IntToStr(MaxSizeMB) + 'MB (keeping ' +
          IntToStr(EffectiveMaxFiles) + ' old files)';
      end
      else
        RotateSuffix := '';
      WriteLn('  Bucket "', BucketID, '": subscribe=', BucketTopics,
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
    if not Config.Loaded then
      raise Exception.Create('configuration errors in ' + ExpandFileName(Config.FilePath)
        + LineEnding + Config.LastErrors);

    ApplyOpenSSLDLLOverrides(Config);

    ShutdownGraceMs := Config.GetInteger('shutdown_grace_ms', 5000);

    Logger := TVDRX_LoggerExecutive.Create(Kernel.Queue, 'vdrx_daemon.log', lvlINFO,
      Config.GetInteger('log_max_payload_bytes', 4096));
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

    SetupProcesses(Config, Kernel.Registry, ShutdownGraceMs, Routes.Proxy);
    SetupSocketClients(Config, Kernel.Registry, ShutdownGraceMs);
    SetupRewrites(Config, Routes.Rewrites);
    SetupLegacyCLIBridges(Config, Kernel.Registry, ShutdownGraceMs, Routes.Bus);
    SetupHTTPRoutes(Config, Routes.Bus);
    SetupCGI(Config, Kernel.Registry, ShutdownGraceMs, Routes.Bus);
    SetupRunners(Config, Kernel.Registry, ShutdownGraceMs);
    SetupTemplateExecutives(Config, Kernel.Registry);
    SetupBuckets(Config, Kernel.Registry);

    HTTPSites := SetupHTTPSites(Config, Kernel.Registry, ShutdownGraceMs, Routes);

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
