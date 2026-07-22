unit vrdx_admin;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, vrdx_core, vrdx_config;

type

  // Listens on 'sys.reload'. Reloads the config file, then walks every registered
  // executive via Registry.ApplyAllConfigs so listener ports, log thresholds, etc.
  // all pick up the new values through the same virtual ApplyConfig hook.
  TVRDX_AdminExecutive = class(TVRDX_Executive)
  private
    FConfig: TVRDX_Config;
    FRegistry: TVRDX_Registry;
  public
    constructor Create(ABus: TVRDX_MessageQueue; AConfig: TVRDX_Config;
      ARegistry: TVRDX_Registry); reintroduce;
    procedure HandlePacket(const AMsg: TVRDX_Message); override;
  end;

implementation

constructor TVRDX_AdminExecutive.Create(ABus: TVRDX_MessageQueue;
  AConfig: TVRDX_Config; ARegistry: TVRDX_Registry);
begin
  inherited Create(ABus);
  FConfig := AConfig;
  FRegistry := ARegistry;
end;

procedure TVRDX_AdminExecutive.HandlePacket(const AMsg: TVRDX_Message);
begin
  if AMsg.Topic = 'sys.reload' then
  begin
    FConfig.Reload;
    FRegistry.ApplyAllConfigs;
    Bus.Publish('log.info', 'Configuration reloaded successfully.', ID);
  end;
end;

end.
