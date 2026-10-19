unit vdrx_config;

{$mode ObjFPC}{$H+}

// VDRX's configuration class. All of the real work (JSON loading, recursive
// "includes", {VARIABLES}, safe reload) lives in the generic, project-
// independent jsonconf.pas - see the header comment there for the full
// variable syntax and the list of reserved variables. This unit only keeps the
// names the rest of VDRX already uses and adds VDRX's own reserved variables.

interface

uses
  Classes, SysUtils, jsonconf;

type
  // Same shape as before: one Name=Value TStringList per object in a config array.
  TVDRX_ConfigRows = TJsonConfRows;

  TVDRX_Config = class(TJsonConf)
  protected
    procedure RegisterReservedVariables; override;
  end;

implementation

procedure TVDRX_Config.RegisterReservedVariables;
var
  ExePath: string;
begin
  inherited;
  // VDRX-flavoured names for the generic APP_* ones, so a vdrx.conf (or an
  // included application's conf) reads naturally: {VDRX_ROOT_PATH}/scripts/...
  ExePath := ExpandFileName(ParamStr(0));
  SetReservedVariable('VDRX_ROOT_PATH', ExtractFileDir(ExePath));
  SetReservedVariable('VDRX_BIN_FILENAME', ExtractFileName(ExePath));
  SetReservedVariable('VDRX_BIN_PATH', ExePath);
end;

end.
