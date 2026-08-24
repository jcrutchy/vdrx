unit vdrx_admin;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Math, vdrx_core, vdrx_config, vdrx_bridge, vdrx_bucket;

type

  // Listens on 'sys.>'. Handles the daemon's operator-control surface:
  //   sys.reload   - re-read the config file and re-apply it to everything
  //   sys.quit     - clean shutdown of the whole daemon
  //   sys.restart  - clean shutdown, then respawn a fresh instance
  //   sys.kill     - payload is a PID (kills that bridge's child process -
  //                  its executive stays supervised and restarts it) or an
  //                  executive ID (shuts that one executive down and
  //                  unregisters it entirely)
  //   sys.killall  - payload is optional; empty kills every non-core
  //                  executive, or a substring matched against class names
  //                  (e.g. "bridge") to kill just executives of that kind
  //   sys.list     - payload ignored. Lists every registered executive (ID,
  //                  class) - Bridges additionally show pid/running state
  //                  and restart policy.
  //   sys.history  - payload is "<bucket name> [count]" (count defaults to
  //                  20). Prints the last <count> entries from that
  //                  bucket's history file - see vdrx_bucket.pas.
  // Not authenticated - see vdrx_admincmd.pas for what feeds these topics
  // (stdin today; written to be reusable by any future text-command
  // source) and why that's deliberate for now.
  TVDRX_AdminExecutive = class(TVDRX_Executive)
  private
    FConfig: TVDRX_Config;
    FRegistry: TVDRX_Registry;
    FKernel: TVDRX_Kernel;
    function IsProtected(const AID: string): Boolean;
    procedure DoKill(const ATarget: string);
    procedure DoKillAll(const ATypeFilter: string);
    procedure DoList;
    procedure DoHistory(const AArgs: string);
  public
    constructor Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config;
      ARegistry: TVDRX_Registry; AKernel: TVDRX_Kernel); reintroduce;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
  end;

// Shared line-command parser used by anything that lets an operator type
// admin commands at VDRX - stdin (vdrx_stdin.pas) today, written to be
// reusable by any future text-command source. Not authenticated in any way
// yet (deliberate, matches the rest of the daemon at this stage) - anything
// that can reach this can quit/restart/kill the daemon.
//
// Recognised commands (case-insensitive), one per line:
//   quit                  - clean shutdown of the whole daemon
//   restart               - clean shutdown, then respawn a fresh instance
//   reload                 - re-read vdrx_daemon.conf and re-apply it live
//   kill <target>          - <target> numeric = a PID: kills that bridge's
//                            child process (its executive stays supervised
//                            and will restart it); <target> non-numeric =
//                            an executive ID: shuts that one executive down
//                            (threads/process included) and unregisters it
//   killall [type]         - kill everything (or, if [type] is given, only
//                            executives whose class name contains it, e.g.
//                            "killall bridge")
//   list                   - list every registered executive; Bridges show
//                            pid/running state and restart policy too
//   history <bucket> [n]   - show the last n (default 20) entries from a
//                            bucket's history file
procedure DispatchAdminCommandLine(ABus: TVDRX_MessageQueue; const ASourceID, ALine: string);

implementation

procedure DispatchAdminCommandLine(ABus: TVDRX_MessageQueue; const ASourceID, ALine: string);
var
  Line, Cmd, Rest: string;
  SpacePos: Integer;
begin
  Line := Trim(ALine);
  if Line = '' then Exit;
  SpacePos := Pos(' ', Line);
  if SpacePos > 0 then
  begin
    Cmd := LowerCase(Copy(Line, 1, SpacePos - 1));
    Rest := Trim(Copy(Line, SpacePos + 1, MaxInt));
  end
  else
  begin
    Cmd := LowerCase(Line);
    Rest := '';
  end;

  if Cmd = 'quit' then
    ABus.Publish('sys.quit', '', ASourceID)
  else if Cmd = 'restart' then
    ABus.Publish('sys.restart', '', ASourceID)
  else if Cmd = 'reload' then
    ABus.Publish('sys.reload', '', ASourceID)
  else if Cmd = 'kill' then
  begin
    if Rest = '' then
      ABus.Publish('log.warn', 'admin: "kill" needs a PID or executive ID', ASourceID)
    else
      ABus.Publish('sys.kill', Rest, ASourceID);
  end
  else if Cmd = 'killall' then
    ABus.Publish('sys.killall', Rest, ASourceID)
  else if Cmd = 'list' then
    ABus.Publish('sys.list', '', ASourceID)
  else if Cmd = 'history' then
  begin
    if Rest = '' then
      ABus.Publish('log.warn', 'admin: "history" needs a bucket name, e.g. "history world"', ASourceID)
    else
      ABus.Publish('sys.history', Rest, ASourceID);
  end
  else
    ABus.Publish('log.warn', 'admin: unrecognised command "' + Cmd + '"', ASourceID);
end;

constructor TVDRX_AdminExecutive.Create(ABus: TVDRX_MessageQueue;
  AConfig: TVDRX_Config; ARegistry: TVDRX_Registry; AKernel: TVDRX_Kernel);
begin
  inherited Create(ABus);
  FConfig := AConfig;
  FRegistry := ARegistry;
  FKernel := AKernel;
end;

// Executives that keep the daemon itself controllable - never touched by
// killall, and refused as an explicit kill target too.
function TVDRX_AdminExecutive.IsProtected(const AID: string): Boolean;
begin
  Result := (AID = 'admin') or (AID = 'logger') or (AID = 'stdin');
end;

procedure TVDRX_AdminExecutive.DoKill(const ATarget: string);
var
  PID, Code: Integer;
  Snap: TVDRX_ExecList;
  Exec, Found: TVDRX_Executive;
begin
  Val(Trim(ATarget), PID, Code);
  if Code = 0 then
  begin
    // Numeric - treat as a bridge child-process PID.
    Found := nil;
    Snap := FRegistry.Snapshot;
    try
      for Exec in Snap do
        if (Exec is TVDRX_BridgeExecutive) and (TVDRX_BridgeExecutive(Exec).CurrentPID = PID) then
        begin
          Found := Exec;
          Break;
        end;
    finally
      Snap.Free;
    end;
    if Assigned(Found) then
    begin
      Bus.Publish('log.info', Format('admin: killing pid %d (bridge "%s") - its supervisor will restart it', [PID, Found.ID]), ID);
      TVDRX_BridgeExecutive(Found).KillCurrentProcess;
    end
    else
      Bus.Publish('log.warn', Format('admin: no bridge process found with pid %d', [PID]), ID);
  end
  else
  begin
    // Not numeric - treat as an executive ID.
    if IsProtected(ATarget) then
    begin
      Bus.Publish('log.warn', 'admin: refusing to kill protected executive "' + ATarget + '"', ID);
      Exit;
    end;
    if not Assigned(FRegistry.Find(ATarget)) then
    begin
      Bus.Publish('log.warn', 'admin: no executive registered with id "' + ATarget + '"', ID);
      Exit;
    end;
    Bus.Publish('log.info', 'admin: killing executive "' + ATarget + '"', ID);
    FRegistry.Unregister(ATarget); // Shuts it down (threads/process) then frees it
  end;
end;

procedure TVDRX_AdminExecutive.DoKillAll(const ATypeFilter: string);
var
  Snap: TVDRX_ExecList;
  Exec: TVDRX_Executive;
  Targets: TStringArray;
  i, n: Integer;
  Filter: string;
begin
  Filter := LowerCase(Trim(ATypeFilter));
  SetLength(Targets, 0);
  Snap := FRegistry.Snapshot;
  try
    for Exec in Snap do
    begin
      if IsProtected(Exec.ID) then Continue;
      if (Filter <> '') and (Pos(Filter, LowerCase(Exec.ClassName)) = 0) then Continue;
      n := Length(Targets);
      SetLength(Targets, n + 1);
      Targets[n] := Exec.ID;
    end;
  finally
    Snap.Free;
  end;

  if Filter <> '' then
    Bus.Publish('log.info', Format('admin: killall (type contains "%s") matched %d executive(s)', [Filter, Length(Targets)]), ID)
  else
    Bus.Publish('log.info', Format('admin: killall matched %d executive(s)', [Length(Targets)]), ID);

  for i := 0 to High(Targets) do
    FRegistry.Unregister(Targets[i]);
end;

procedure TVDRX_AdminExecutive.DoList;
var
  Snap: TVDRX_ExecList;
  Exec: TVDRX_Executive;
  Line: string;
begin
  Snap := FRegistry.Snapshot;
  try
    Bus.Publish('log.info', Format('admin: %d executive(s) registered:', [Snap.Count]), ID);
    for Exec in Snap do
    begin
      Line := Format('  %s (%s)', [Exec.ID, Exec.ClassName]);
      if Exec is TVDRX_BridgeExecutive then
      begin
        if TVDRX_BridgeExecutive(Exec).CurrentPID <> 0 then
          Line := Line + Format(' - running, pid %d, restart=%s',
            [TVDRX_BridgeExecutive(Exec).CurrentPID, TVDRX_BridgeExecutive(Exec).RestartPolicy])
        else
          Line := Line + Format(' - not running, restart=%s',
            [TVDRX_BridgeExecutive(Exec).RestartPolicy]);
      end;
      Bus.Publish('log.info', Line, ID);
    end;
  finally
    Snap.Free;
  end;
end;

procedure TVDRX_AdminExecutive.DoHistory(const AArgs: string);
var
  Snap: TVDRX_ExecList;
  Exec: TVDRX_Executive;
  Bucket: TVDRX_BucketExecutive;
  Parts: TStringList;
  BucketName: string;
  Count, i: Integer;
  Lines: TStringList;
begin
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ' ';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := Trim(AArgs);
    if Parts.Count = 0 then
    begin
      Bus.Publish('log.warn', 'admin: history needs a bucket name, e.g. "history world"', ID);
      Exit;
    end;
    BucketName := Parts[0];
    Count := 20;
    if Parts.Count > 1 then
      Count := StrToIntDef(Parts[1], 20);
  finally
    Parts.Free;
  end;

  Bucket := nil;
  Snap := FRegistry.Snapshot;
  try
    for Exec in Snap do
      if (Exec is TVDRX_BucketExecutive) and (Exec.ID = BucketName) then
      begin
        Bucket := TVDRX_BucketExecutive(Exec);
        Break;
      end;
  finally
    Snap.Free;
  end;

  if not Assigned(Bucket) then
  begin
    Bus.Publish('log.warn', Format('admin: no bucket named "%s"', [BucketName]), ID);
    Exit;
  end;

  Lines := TStringList.Create;
  try
    if FileExists(Bucket.FilePath) then
      Lines.LoadFromFile(Bucket.FilePath);
    Bus.Publish('log.info', Format('admin: last %d of %d entries in bucket "%s":',
      [Min(Count, Lines.Count), Lines.Count, BucketName]), ID);
    for i := Max(0, Lines.Count - Count) to Lines.Count - 1 do
      Bus.Publish('log.info', '  ' + Lines[i], ID);
  finally
    Lines.Free;
  end;
end;

procedure TVDRX_AdminExecutive.HandlePacket(const AMsg: TVDRX_Message);
begin
  if AMsg.Topic = 'sys.reload' then
  begin
    FConfig.Reload;
    FRegistry.ApplyAllConfigs;
    Bus.Publish('log.info', 'Configuration reloaded successfully.', ID);
  end
  else if AMsg.Topic = 'sys.quit' then
  begin
    Bus.Publish('log.info', 'admin: quit requested - shutting down.', ID);
    FKernel.Terminate;
  end
  else if AMsg.Topic = 'sys.restart' then
  begin
    Bus.Publish('log.info', 'admin: restart requested - shutting down, then respawning.', ID);
    FKernel.RestartRequested := True;
    FKernel.Terminate;
  end
  else if AMsg.Topic = 'sys.kill' then
    DoKill(AMsg.Payload)
  else if AMsg.Topic = 'sys.killall' then
    DoKillAll(AMsg.Payload)
  else if AMsg.Topic = 'sys.list' then
    DoList
  else if AMsg.Topic = 'sys.history' then
    DoHistory(AMsg.Payload);
end;

end.