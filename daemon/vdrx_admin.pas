unit vdrx_admin;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, vdrx_core, vdrx_config, vdrx_bridge;

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
  // Not authenticated - see vdrx_admincmd.pas for what feeds these topics
  // (stdin, IRC "!" commands) and why that's deliberate for now.
  TVDRX_AdminExecutive = class(TVDRX_Executive)
  private
    FConfig: TVDRX_Config;
    FRegistry: TVDRX_Registry;
    FKernel: TVDRX_Kernel;
    function IsProtected(const AID: string): Boolean;
    procedure DoKill(const ATarget: string);
    procedure DoKillAll(const ATypeFilter: string);
  public
    constructor Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config;
      ARegistry: TVDRX_Registry; AKernel: TVDRX_Kernel); reintroduce;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
  end;

implementation

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
    DoKillAll(AMsg.Payload);
end;

end.