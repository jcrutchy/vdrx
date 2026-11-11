unit vdrx_stdin;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, vdrx_core, vdrx_admin, vdrx_linebuf;

type
  // Reads admin commands (quit/restart/reload/kill/killall - see
  // vdrx_admin.pas) one per line from the console. Replaces the daemon's
  // old "press ENTER to stop" main-thread ReadLn: that blocked the main
  // thread and only understood one gesture; this runs on its own thread,
  // doesn't consume the bus (registered on 'sys.none' like WS), and
  // understands the full command set.
  //
  // Caveat: the read blocks on the OS's stdin read, which can't be portably
  // interrupted from another thread. On sys.quit/sys.restart this thread is
  // simply abandoned (FreeOnTerminate) rather than joined - fine for a
  // console-attached dev daemon, since the process is exiting anyway; if
  // stdin is piped/closed, the read returns on EOF and the thread exits itself.
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
const
  // Admin commands are a few words; anything near this size is not a command. Bounded so
  // that a pipe attached to stdin cannot make the daemon buffer an endless line.
  MaxCommandBytes = 4096;
var
  Buf: array[0..511] of Byte;
  Got, i: Integer;
  Assembler: TVDRX_LineBuffer;
  Lines: TStringList;
begin
  Assembler := TVDRX_LineBuffer.Create(MaxCommandBytes);
  Lines := TStringList.Create;
  try
    while not FStopping do
    begin
      Got := FileRead(StdInputHandle, Buf, SizeOf(Buf));
      if Got <= 0 then Break; // stdin closed/piped-and-drained (or unreadable)
      if FStopping then Break;
      Lines.Clear;
      if Assembler.Feed(Buf, Got, Lines) then
        Bus.Publish('log.warn', 'stdin: ignored a console line longer than ' + IntToStr(MaxCommandBytes) + ' bytes', ID);
      for i := 0 to Lines.Count - 1 do
        DispatchAdminCommandLine(Bus, ID, Lines[i]);
    end;
  finally
    Lines.Free;
    Assembler.Free;
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
