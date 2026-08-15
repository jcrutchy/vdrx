unit vdrx_stress_daemonctl;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Math, Process, ssockets, sockets
  {$IFDEF UNIX}, BaseUnix{$ENDIF};

// Cross-platform SO_RCVTIMEO - Windows wants milliseconds as a plain DWORD,
// Unix wants a struct timeval. Needed so a fuzz test that intentionally
// sends a broken/incomplete request doesn't just block forever waiting for
// a response that will never come.
procedure SetSocketRecvTimeout(AHandle: TSocket; AMilliseconds: Integer);

// Connects with its own short timeout (see SetSocketRecvTimeout) rather than
// the OS default (which on some platforms is measured in minutes) - a fuzz
// loop doing thousands of connections can't afford that per attempt.
function TryConnect(const AHost: string; APort: Word; ATimeoutMs: Integer;
  out ASocket: TInetSocket): Boolean;

type
  // Owns (in managed mode) the vdrx_daemon process under test: spawns it,
  // watches whether it's still alive, and can feed it admin commands over
  // its stdin exactly like a human operator would. In attach mode it's just
  // a place to hang the Host/HTTPPort/WSPort the suites connect to - nothing
  // here is optional to use, the fuzz suites only ever talk to the daemon
  // over its real network interfaces either way.
  TVDRX_DaemonController = class
  private
    FProcess: TProcess;
    FManaged: Boolean;
    FStopRequested: Boolean;
  public
    Host: string;
    HTTPPort, WSPort: Word;
    constructor Create;
    destructor Destroy; override;
    // AWorkDir is where vdrx_daemon.exe/vdrx_daemon looks for its own
    // vdrx_daemon.conf (and where it writes bucket/log files) - same as
    // running it by hand from that directory.
    function StartManaged(const AExePath, AWorkDir: string): Boolean;
    procedure StopManaged(ATimeoutMs: Integer);
    procedure SendStdinLine(const ALine: string);
    // False here, after StartManaged succeeded and before StopManaged was
    // called, means the daemon died on its own - a crash, by definition.
    function IsAlive: Boolean;
    function WaitForPortOpen(APort: Word; ATimeoutMs: Integer): Boolean;
    function RecentOutput: string;
    property Managed: Boolean read FManaged;
  end;

implementation

procedure SetSocketRecvTimeout(AHandle: TSocket; AMilliseconds: Integer);
{$IFDEF WINDOWS}
var
  TimeoutMs: DWORD;
begin
  TimeoutMs := AMilliseconds;
  fpsetsockopt(AHandle, SOL_SOCKET, SO_RCVTIMEO, @TimeoutMs, SizeOf(TimeoutMs));
  fpsetsockopt(AHandle, SOL_SOCKET, SO_SNDTIMEO, @TimeoutMs, SizeOf(TimeoutMs));
end;
{$ELSE}
var
  TV: TTimeVal;
begin
  TV.tv_sec := AMilliseconds div 1000;
  TV.tv_usec := (AMilliseconds mod 1000) * 1000;
  fpsetsockopt(AHandle, SOL_SOCKET, SO_RCVTIMEO, @TV, SizeOf(TV));
  fpsetsockopt(AHandle, SOL_SOCKET, SO_SNDTIMEO, @TV, SizeOf(TV));
end;
{$ENDIF}

function TryConnect(const AHost: string; APort: Word; ATimeoutMs: Integer;
  out ASocket: TInetSocket): Boolean;
begin
  Result := False;
  ASocket := nil;
  try
    ASocket := TInetSocket.Create(AHost, APort);
    SetSocketRecvTimeout(ASocket.Handle, ATimeoutMs);
    Result := True;
  except
    on E: Exception do
    begin
      if Assigned(ASocket) then
        FreeAndNil(ASocket);
      Result := False;
    end;
  end;
end;

constructor TVDRX_DaemonController.Create;
begin
  Host := '127.0.0.1';
end;

destructor TVDRX_DaemonController.Destroy;
begin
  if FManaged and IsAlive then
    StopManaged(2000);
  inherited;
end;

function TVDRX_DaemonController.StartManaged(const AExePath, AWorkDir: string): Boolean;
begin
  Result := False;
  FManaged := True;
  FStopRequested := False;
  FProcess := TProcess.Create(nil);
  FProcess.Executable := AExePath;
  FProcess.CurrentDirectory := AWorkDir;
  FProcess.Options := [poUsePipes];
  try
    FProcess.Execute;
    Result := True;
  except
    on E: Exception do
    begin
      WriteLn('Failed to start managed daemon "', AExePath, '": ', E.Message);
      FreeAndNil(FProcess);
      Exit;
    end;
  end;
end;

procedure TVDRX_DaemonController.StopManaged(ATimeoutMs: Integer);
var
  Waited: Integer;
begin
  if not Assigned(FProcess) then Exit;
  FStopRequested := True;
  try
    SendStdinLine('quit');
  except
    // already dead - fine, that's what we wanted anyway
  end;
  Waited := 0;
  while FProcess.Running and (Waited < ATimeoutMs) do
  begin
    Sleep(50);
    Inc(Waited, 50);
  end;
  if FProcess.Running then
  begin
    try
      FProcess.Terminate(1);
    except
    end;
  end;
  FreeAndNil(FProcess);
end;

procedure TVDRX_DaemonController.SendStdinLine(const ALine: string);
var
  S: string;
begin
  if not Assigned(FProcess) then Exit;
  S := ALine + LineEnding;
  FProcess.Input.Write(S[1], Length(S));
end;

function TVDRX_DaemonController.IsAlive: Boolean;
begin
  if not FManaged then
    Result := True // attach mode - "alive" isn't ours to know, callers use WaitForPortOpen instead
  else
    Result := Assigned(FProcess) and FProcess.Running;
end;

function TVDRX_DaemonController.WaitForPortOpen(APort: Word; ATimeoutMs: Integer): Boolean;
var
  Sock: TInetSocket;
  Waited: Integer;
begin
  Result := False;
  Waited := 0;
  while Waited < ATimeoutMs do
  begin
    if TryConnect(Host, APort, 200, Sock) then
    begin
      Sock.Free;
      Exit(True);
    end;
    Sleep(100);
    Inc(Waited, 100);
  end;
end;

function TVDRX_DaemonController.RecentOutput: string;
var
  Buf: array[0..65535] of Byte;
  NRead: Integer;
begin
  Result := '';
  if not Assigned(FProcess) then Exit;
  try
    if FProcess.Output.NumBytesAvailable > 0 then
    begin
      NRead := FProcess.Output.Read(Buf, Min(SizeOf(Buf), FProcess.Output.NumBytesAvailable));
      if NRead > 0 then
        SetString(Result, PAnsiChar(@Buf[0]), NRead);
    end;
  except
    // process may already be gone by the time we try this - fine, we tried
  end;
end;

end.
