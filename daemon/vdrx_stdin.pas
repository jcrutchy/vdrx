unit vdrx_stdin;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, vdrx_core, vdrx_admincmd;

type
  // Reads admin commands (quit/restart/reload/kill/killall - see
  // vdrx_admincmd.pas) one per line from the console. Replaces the daemon's
  // old "press ENTER to stop" main-thread ReadLn: that blocked the main
  // thread and only understood one gesture; this runs on its own thread,
  // doesn't consume the bus (registered on 'sys.none' like IRCD/WS), and
  // understands the full command set.
  //
  // Caveat: ReadLn blocks on the OS's stdin read, which can't be portably
  // interrupted from another thread. On sys.quit/sys.restart this thread is
  // simply abandoned (FreeOnTerminate) rather than joined - fine for a
  // console-attached dev daemon, since the process is exiting anyway; if
  // stdin is piped/closed, ReadLn returns on EOF and the thread exits itself.
  TVDRX_StdinExecutive = class(TVDRX_Executive)
  private
    FThread: TThread;
    FStopping: Boolean;
    procedure ReadLoop;
  public
    procedure Initialize; override;
    procedure Shutdown; override;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
  end;

implementation

procedure TVDRX_StdinExecutive.ReadLoop;
var
  Line: string;
begin
  while not FStopping do
  begin
    if Eof(Input) then Break; // stdin closed/piped-and-drained
    ReadLn(Line);
    if FStopping then Break;
    DispatchAdminCommandLine(Bus, ID, Line);
  end;
end;

procedure TVDRX_StdinExecutive.Initialize;
begin
  FStopping := False;
  FThread := TVDRX_WorkerThread.Create(@ReadLoop);
  FThread.FreeOnTerminate := True; // see unit comment - not joined on Shutdown
  FThread.Start;
end;

procedure TVDRX_StdinExecutive.Shutdown;
begin
  FStopping := True; // best-effort - the thread only notices after its next line
end;

procedure TVDRX_StdinExecutive.HandlePacket(const AMsg: TVDRX_Message);
begin
  // Doesn't consume bus messages - registered on 'sys.none' only.
end;

end.