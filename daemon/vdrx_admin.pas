unit vdrx_admin;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, vdrx_core, vdrx_config;

type

  // Listens on 'sys.reload'. Reloads the config file, then walks every registered
  // executive via Registry.ApplyAllConfigs so listener ports, log thresholds, etc.
  // all pick up the new values through the same virtual ApplyConfig hook.
  TVDRX_AdminExecutive = class(TVDRX_Executive)
  private
    FConfig: TVDRX_Config;
    FRegistry: TVDRX_Registry;
  public
    constructor Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config;
      ARegistry: TVDRX_Registry); reintroduce;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
  end;

implementation

constructor TVDRX_AdminExecutive.Create(ABus: TVDRX_MessageQueue;
  AConfig: TVDRX_Config; ARegistry: TVDRX_Registry);
begin
  inherited Create(ABus);
  FConfig := AConfig;
  FRegistry := ARegistry;
end;

procedure TVDRX_AdminExecutive.HandlePacket(const AMsg: TVDRX_Message);
begin
  if AMsg.Topic = 'sys.reload' then
  begin
    FConfig.Reload;
    FRegistry.ApplyAllConfigs;
    Bus.Publish('log.info', 'Configuration reloaded successfully.', ID);
  end;
end;

end.
