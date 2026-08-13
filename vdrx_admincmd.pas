unit vdrx_admincmd;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, vdrx_core;

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

end.