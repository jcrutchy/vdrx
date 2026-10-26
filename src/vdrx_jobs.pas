unit vdrx_jobs;

{$mode ObjFPC}{$H+}

// Scheduled jobs: run ordinary programs at intervals, several at once, and put
// everything they print onto the bus as it happens.
//
// Three cooperating executives share one TVDRX_JobTable (the job definitions
// plus their run state):
//
//   TVDRX_SchedulerExecutive   a clock. Once a second it looks for jobs that are
//                              due and publishes  sched.<job>  - nothing else. It
//                              knows nothing about processes. Last-tick times are
//                              kept in a small state file, so a restart does not
//                              re-run every job (and an overdue one runs at once).
//   TVDRX_JobRunnerExecutive   starts jobs. Subscribes to
//                                sched.>      a tick (from the scheduler or anyone)
//                                jobs.run     run now   - payload: job id, or {"job":"id"}
//                                jobs.kill    stop one  - payload: job id, or {"job":"id"}
//                                jobs.list    publish   jobs.state  (every job's state)
//                              Each run gets its own thread; stdout and stderr are
//                              read line by line and published as they arrive.
//   TVDRX_JobConsoleExecutive  optional: prints job.> as coloured console lines.
//
// What a run publishes (the payload is always one JSON object with "job", "ts"
// (UTC, ISO 8601) and, for a run, "run" (a counter) and "pid"):
//
//   job.<id>.start     {trigger}                       the process was started
//   job.<id>.out       {stream:"out", line}            one line of stdout
//   job.<id>.err       {stream:"err", line}            one line of stderr
//   job.<id>.exit      {status, code, duration_ms, stop?, error?}
//                        status: ok | failed | timeout | killed | start_failed
//   job.<id>.skip      {reason, trigger}               a tick was ignored (overlap)
//   job.<id>.queued    {reason, trigger}               waiting for the previous run
//                                                      to end / for a free slot
//   job.<id>.restart   {reason, trigger}               overlap "kill": stopping the
//                                                      old run so a new one can start
//   job.<id>.error     {reason, trigger}               could not start at all
//
// Job ids may contain letters, digits, "_" and "-" only (never "."), because the
// id is a segment of the topic: a subscriber can ask for  job.its.>  or  job.*.exit
// or  job.>  and get exactly what it expects.
//
// HandlePacket (kernel thread) only ever takes a lock briefly and starts a
// thread; spawning, pipe reading and waiting all happen on the run's own thread,
// so a slow or chatty job can never stall the bus.

interface

uses
  Classes, SysUtils, SyncObjs, StrUtils, Process, Pipes, DateUtils,
  fpjson, jsonparser, Generics.Collections,
  vdrx_core, vdrx_procutil, vdrx_logger;

type
  // What to do with a tick that arrives while the previous run is still going.
  //   joSkip   ignore it (default)
  //   joQueue  remember ONE rerun and start it as soon as the current run ends
  //   joKill   stop the running one, then start a fresh run
  TVDRX_JobOverlap = (joSkip, joQueue, joKill);

  TVDRX_JobRun = class;

  TVDRX_JobDef = class
  public
    // ---- configuration: set once at startup, read-only afterwards ----------
    Name: string;
    Command: string;          // program plus any fixed leading arguments
    Args: TStringList;        // further arguments, passed exactly as written
    WorkDir: string;
    Env: TStringList;         // NAME=value lines added to the inherited environment
    IntervalSec: Integer;     // 0 = never scheduled (jobs.run / sched.<id> only)
    Enabled: Boolean;         // enabled = scheduled; a disabled job can still be run by hand
    RunOnStart: Boolean;      // a job that has never run is due immediately
    Overlap: TVDRX_JobOverlap;
    TimeoutSec: Integer;      // 0 = no limit
    KillGraceMs: Integer;     // polite stop (SIGTERM) -> force kill after this long
    StripANSI: Boolean;       // remove colour escape codes from published lines
    // ---- state: guarded by TVDRX_JobTable.Lock ------------------------------
    LastTick: Int64;          // unix seconds of the last scheduled tick (persisted)
    Running: Boolean;
    PendingRun: Boolean;      // overlap queue/kill: one more run is owed
    Waiting: Boolean;         // sitting in the max_concurrent queue
    CurrentRun: TVDRX_JobRun;
    RunCount: Integer;
    LastStatus: string;
    LastCode: Integer;
    LastStarted: string;
    LastEnded: string;
    LastDurationMs: Int64;
    constructor Create(const AName: string);
    destructor Destroy; override;
  end;

  TVDRX_JobDefList = specialize TObjectList<TVDRX_JobDef>;

  // The job definitions and their shared state. Definitions are added during
  // startup only (before any thread exists), so Find/Item/Count need no lock;
  // everything mutable on a TVDRX_JobDef is guarded by Lock.
  TVDRX_JobTable = class
  private
    FJobs: TVDRX_JobDefList;
    FLock: TCriticalSection;
    FStatePath: string;
  public
    constructor Create(const AStatePath: string);
    destructor Destroy; override;
    // False (and nothing added) if the id is invalid or already used; AError says why.
    function Add(ADef: TVDRX_JobDef; out AError: string): Boolean;
    function Find(const AName: string): TVDRX_JobDef;
    function Count: Integer;
    function Item(AIndex: Integer): TVDRX_JobDef;
    procedure LoadState;
    procedure SaveState;
    property Lock: TCriticalSection read FLock;
  end;

  TVDRX_SchedulerExecutive = class(TVDRX_Executive)
  private
    FTable: TVDRX_JobTable;
    FThread: TThread;
    FStop: TEvent;
    FStopping: Boolean;
    procedure Loop;
    procedure CheckDue;
  public
    constructor Create(ABus: TVDRX_MessageQueue; ATable: TVDRX_JobTable); reintroduce;
    destructor Destroy; override;
    procedure Initialize; override;
    procedure Shutdown; override;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
  end;

  TVDRX_JobRunList = specialize TList<TVDRX_JobRun>;

  TVDRX_JobRunnerExecutive = class(TVDRX_Executive)
  private
    FTable: TVDRX_JobTable;
    FMaxConcurrent: Integer;
    FGraceMs: Integer;
    FActive: TVDRX_JobRunList;
    FWaiting: TStringList;
    FRunSeq: Integer;
    FStopping: Boolean;
    function StartRunLocked(ADef: TVDRX_JobDef; const ATrigger: string; out AError: string): Boolean;
    procedure RunFinished(ARun: TVDRX_JobRun; const AStatus: string; ACode: Integer; ADurationMs: Int64);
    procedure NoteStarted(ARun: TVDRX_JobRun);
    procedure PublishJob(const AJob, ASuffix, APayload: string);
    procedure PublishNote(const AJob, ASuffix, AReason, ATrigger: string);
    procedure Trigger(const AName, ATrigger: string);
    procedure KillJob(const AName: string);
    procedure PublishState;
    function JobNameOf(const APayload: string): string;
  public
    constructor Create(ABus: TVDRX_MessageQueue; ATable: TVDRX_JobTable); reintroduce;
    destructor Destroy; override;
    procedure Shutdown; override;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    // 0 = no limit. Ticks beyond the limit wait in a FIFO queue for a free slot.
    property MaxConcurrent: Integer read FMaxConcurrent write FMaxConcurrent;
    // Longest polite-stop wait at shutdown (jobs' own kill_grace_ms is capped to it).
    property GraceMs: Integer read FGraceMs write FGraceMs;
  end;

  // One run of one job: the process and the thread that watches it.
  TVDRX_JobRun = class
  private
    FOwner: TVDRX_JobRunnerExecutive;
    FDef: TVDRX_JobDef;
    FRunID: Integer;
    FTrigger: string;
    FPid: Integer;
    FStopCode: LongInt;   // 0 = running normally; else a STOP_* code (set once)
    FOutBuf: string;
    FErrBuf: string;
    procedure EmitLine(const AStream, ALine: string);
    procedure SplitLines(var ABuf: string; const AStream: string; AFinal: Boolean);
    function Drain(AStream: TInputPipeStream; var ABuf: string; const AName: string): Integer;
    function GraceFor(AStopCode: LongInt): QWord;
  public
    constructor Create(AOwner: TVDRX_JobRunnerExecutive; ADef: TVDRX_JobDef;
      ARunID: Integer; const ATrigger: string);
    procedure Go;                          // the thread body
    procedure RequestStop(ACode: LongInt); // first request wins
  end;

  // Prints job.> as one coloured line each - timestamp and "[job:pid]" in a
  // black-on-yellow block, a yellow arrow, then the message. Formatting and
  // console I/O happen on its own writer thread.
  TVDRX_JobConsoleExecutive = class(TVDRX_Executive)
  private
    FLock: TCriticalSection;
    FSignal: TEvent;
    FPending: TVDRX_MessageList;
    FWriter: TThread;
    FStopping: Boolean;
    FColor: Boolean;
    function FormatMessage(const AMsg: TVDRX_Message): string;
    procedure FlushPending;
    procedure WriterLoop;
  public
    constructor Create(ABus: TVDRX_MessageQueue; AColor: Boolean); reintroduce;
    destructor Destroy; override;
    procedure Shutdown; override;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
  end;

// True if S is usable as a job id (1..64 of letters, digits, "_" and "-").
function ValidJobName(const S: string): Boolean;

implementation

const
  STOP_NONE = 0;
  STOP_KILLED = 1;    // jobs.kill
  STOP_RESTART = 2;   // overlap "kill": replaced by a newer run
  STOP_SHUTDOWN = 3;  // daemon is quitting
  STOP_TIMEOUT = 4;   // timeout_sec exceeded
  MAX_LINE_BYTES = 16384; // a line longer than this is published in pieces

// ---- helpers ----------------------------------------------------------------

function ValidJobName(const S: string): Boolean;
var
  i: Integer;
begin
  Result := (Length(S) >= 1) and (Length(S) <= 64);
  if not Result then Exit;
  for i := 1 to Length(S) do
    if not (S[i] in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-']) then
      Exit(False);
end;

function UtcNow: TDateTime;
begin
  Result := LocalTimeToUniversal(Now);
end;

function UnixNow: Int64;
begin
  Result := DateTimeToUnix(UtcNow, True);
end;

function UtcIso: string;
begin
  Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"Z"', UtcNow);
end;

// Removes ANSI colour/cursor escape sequences (ESC [ ... final-byte).
function StripANSICodes(const S: string): string;
var
  i, n: Integer;
begin
  if Pos(#27, S) = 0 then Exit(S);
  Result := '';
  n := Length(S);
  i := 1;
  while i <= n do
  begin
    if S[i] = #27 then
    begin
      Inc(i);
      if (i <= n) and (S[i] = '[') then
      begin
        Inc(i);
        while (i <= n) and not (S[i] in ['@'..'~']) do Inc(i);
        Inc(i); // the final byte
      end
      else if i <= n then
        Inc(i); // a two-character escape
    end
    else
    begin
      Result := Result + S[i];
      Inc(i);
    end;
  end;
end;

function OverlapName(AOverlap: TVDRX_JobOverlap): string;
begin
  case AOverlap of
    joQueue: Result := 'queue';
    joKill: Result := 'kill';
  else
    Result := 'skip';
  end;
end;

function StopName(ACode: LongInt): string;
begin
  case ACode of
    STOP_KILLED: Result := 'killed';
    STOP_RESTART: Result := 'restart';
    STOP_SHUTDOWN: Result := 'shutdown';
    STOP_TIMEOUT: Result := 'timeout';
  else
    Result := '';
  end;
end;

// A fresh event object with the fields every job message carries.
function NewEvent(const AJob: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('job', AJob);
  Result.Add('ts', UtcIso);
end;

{ TVDRX_JobDef }

constructor TVDRX_JobDef.Create(const AName: string);
begin
  inherited Create;
  Name := AName;
  Args := TStringList.Create;
  Env := TStringList.Create;
  Enabled := True;
  RunOnStart := True;
  Overlap := joSkip;
  KillGraceMs := 3000;
  StripANSI := True;
  LastCode := -1;
end;

destructor TVDRX_JobDef.Destroy;
begin
  Env.Free;
  Args.Free;
  inherited;
end;

{ TVDRX_JobTable }

constructor TVDRX_JobTable.Create(const AStatePath: string);
begin
  inherited Create;
  FJobs := TVDRX_JobDefList.Create(True);
  FLock := TCriticalSection.Create;
  FStatePath := AStatePath;
end;

destructor TVDRX_JobTable.Destroy;
begin
  FLock.Free;
  FJobs.Free;
  inherited;
end;

function TVDRX_JobTable.Add(ADef: TVDRX_JobDef; out AError: string): Boolean;
begin
  AError := '';
  if not ValidJobName(ADef.Name) then
  begin
    AError := 'id "' + ADef.Name + '" is not valid (letters, digits, "_" and "-" only, 1-64 characters)';
    Exit(False);
  end;
  if Find(ADef.Name) <> nil then
  begin
    AError := 'id "' + ADef.Name + '" is used twice';
    Exit(False);
  end;
  FJobs.Add(ADef);
  Result := True;
end;

function TVDRX_JobTable.Find(const AName: string): TVDRX_JobDef;
var
  i: Integer;
begin
  for i := 0 to FJobs.Count - 1 do
    if FJobs[i].Name = AName then Exit(FJobs[i]);
  Result := nil;
end;

function TVDRX_JobTable.Count: Integer;
begin
  Result := FJobs.Count;
end;

function TVDRX_JobTable.Item(AIndex: Integer): TVDRX_JobDef;
begin
  Result := FJobs[AIndex];
end;

// State file: {"<id>": <unix seconds of the last scheduled tick>, ...}
procedure TVDRX_JobTable.LoadState;
var
  SL: TStringList;
  J: TJSONData;
  O: TJSONObject;
  i: Integer;
  D: TVDRX_JobDef;
begin
  if (FStatePath = '') or (not FileExists(FStatePath)) then Exit;
  SL := TStringList.Create;
  try
    try
      SL.LoadFromFile(FStatePath);
      J := GetJSON(SL.Text);
    except
      Exit; // unreadable state just means "no history" - every job counts as never run
    end;
    try
      if J is TJSONObject then
      begin
        O := TJSONObject(J);
        FLock.Enter;
        try
          for i := 0 to O.Count - 1 do
          begin
            D := Find(O.Names[i]);
            if D <> nil then D.LastTick := O.Items[i].AsInt64;
          end;
        finally
          FLock.Leave;
        end;
      end;
    finally
      J.Free;
    end;
  finally
    SL.Free;
  end;
end;

procedure TVDRX_JobTable.SaveState;
var
  O: TJSONObject;
  i: Integer;
  Text, Tmp: string;
  F: TFileStream;
begin
  if FStatePath = '' then Exit;
  O := TJSONObject.Create;
  try
    FLock.Enter;
    try
      for i := 0 to FJobs.Count - 1 do
        if FJobs[i].LastTick > 0 then
          O.Add(FJobs[i].Name, FJobs[i].LastTick);
    finally
      FLock.Leave;
    end;
    Text := O.FormatJSON;
  finally
    O.Free;
  end;
  // write beside, then rename over: a crash mid-write cannot leave half a file
  Tmp := FStatePath + '.tmp';
  try
    F := TFileStream.Create(Tmp, fmCreate);
    try
      if Text <> '' then F.WriteBuffer(Text[1], Length(Text));
    finally
      F.Free;
    end;
    {$IFNDEF UNIX}
    if FileExists(FStatePath) then DeleteFile(FStatePath);
    {$ENDIF}
    RenameFile(Tmp, FStatePath);
  except
    // a read-only or full disk must not take the scheduler down; the worst
    // outcome is every job counting as overdue after the next restart
  end;
end;

{ TVDRX_SchedulerExecutive }

constructor TVDRX_SchedulerExecutive.Create(ABus: TVDRX_MessageQueue; ATable: TVDRX_JobTable);
begin
  inherited Create(ABus);
  FTable := ATable;
  FStop := TEvent.Create(nil, True, False, '');
end;

destructor TVDRX_SchedulerExecutive.Destroy;
begin
  Shutdown;
  FStop.Free;
  inherited;
end;

procedure TVDRX_SchedulerExecutive.Initialize;
begin
  if Assigned(FThread) then Exit;
  FThread := TVDRX_WorkerThread.Create(@Loop);
  FThread.Start;
end;

procedure TVDRX_SchedulerExecutive.Shutdown;
begin
  if FStopping then Exit;
  FStopping := True;
  FStop.SetEvent;
  if Assigned(FThread) then
  begin
    if WaitThreadOrTimeout(FThread, 3000) then
      FThread.Free
    else
      Bus.Publish('log.warn', 'scheduler: thread did not exit in time - abandoning it', ID);
    FThread := nil;
  end;
end;

// The scheduler subscribes to nothing; it only publishes.
procedure TVDRX_SchedulerExecutive.HandlePacket(const AMsg: TVDRX_Message);
begin
end;

procedure TVDRX_SchedulerExecutive.Loop;
begin
  repeat
    try
      CheckDue;
    except
      on E: Exception do
        Bus.Publish('log.error', 'scheduler: ' + E.ClassName + ': ' + E.Message, ID);
    end;
  until FStop.WaitFor(1000) = wrSignaled;
end;

// A job is due when it has never run (and run_on_start is on) or when its
// interval has passed since the last tick. The tick time is stamped when the
// tick is PUBLISHED, whether or not the runner then skips it - same as a classic
// cron-style scheduler, and it means a slow job never makes its own schedule drift.
procedure TVDRX_SchedulerExecutive.CheckDue;
var
  i: Integer;
  D: TVDRX_JobDef;
  NowU: Int64;
  Due: TStringList;
  Dirty: Boolean;
begin
  NowU := UnixNow;
  Dirty := False;
  Due := TStringList.Create;
  try
    FTable.Lock.Enter;
    try
      for i := 0 to FTable.Count - 1 do
      begin
        D := FTable.Item(i);
        if (not D.Enabled) or (D.IntervalSec <= 0) then Continue;
        if D.LastTick > NowU then
        begin
          D.LastTick := NowU; // the clock was set back: don't wait out the difference
          Dirty := True;
        end;
        if D.LastTick = 0 then
        begin
          D.LastTick := NowU;
          Dirty := True;
          if D.RunOnStart then Due.Add(D.Name);
        end
        else if NowU - D.LastTick >= D.IntervalSec then
        begin
          D.LastTick := NowU;
          Dirty := True;
          Due.Add(D.Name);
        end;
      end;
    finally
      FTable.Lock.Leave;
    end;
    if Dirty then FTable.SaveState;
    for i := 0 to Due.Count - 1 do
      Bus.Publish('sched.' + Due[i], '{"job":"' + Due[i] + '","trigger":"schedule"}', ID);
  finally
    Due.Free;
  end;
end;

{ TVDRX_JobRunnerExecutive }

constructor TVDRX_JobRunnerExecutive.Create(ABus: TVDRX_MessageQueue; ATable: TVDRX_JobTable);
begin
  inherited Create(ABus);
  FTable := ATable;
  FActive := TVDRX_JobRunList.Create;
  FWaiting := TStringList.Create;
  FGraceMs := 5000;
end;

destructor TVDRX_JobRunnerExecutive.Destroy;
begin
  Shutdown;
  FWaiting.Free;
  FActive.Free;
  inherited;
end;

procedure TVDRX_JobRunnerExecutive.Shutdown;
var
  i, Left: Integer;
  T0: QWord;
begin
  FTable.Lock.Enter;
  try
    if FStopping then Exit;
    FStopping := True;
    for i := 0 to FActive.Count - 1 do
      FActive[i].RequestStop(STOP_SHUTDOWN);
    FWaiting.Clear;
  finally
    FTable.Lock.Leave;
  end;
  T0 := GetTickCount64;
  repeat
    FTable.Lock.Enter;
    try
      Left := FActive.Count;
    finally
      FTable.Lock.Leave;
    end;
    if Left = 0 then Exit;
    Sleep(20);
  until GetTickCount64 - T0 > QWord(FGraceMs) + 3000;
  Bus.Publish('log.warn', 'jobs: ' + IntToStr(Left) + ' job process(es) did not exit in time - abandoning them', ID);
end;

procedure TVDRX_JobRunnerExecutive.PublishJob(const AJob, ASuffix, APayload: string);
begin
  Bus.Publish('job.' + AJob + '.' + ASuffix, APayload, ID);
end;

procedure TVDRX_JobRunnerExecutive.PublishNote(const AJob, ASuffix, AReason, ATrigger: string);
var
  O: TJSONObject;
begin
  O := NewEvent(AJob);
  try
    O.Add('reason', AReason);
    O.Add('trigger', ATrigger);
    PublishJob(AJob, ASuffix, O.AsJSON);
  finally
    O.Free;
  end;
end;

// "report", or {"job":"report"} (what a browser or script would send)
function TVDRX_JobRunnerExecutive.JobNameOf(const APayload: string): string;
var
  J: TJSONData;
begin
  Result := Trim(APayload);
  if (Result <> '') and (Result[1] = '{') then
  begin
    Result := '';
    try
      J := GetJSON(APayload);
      try
        if J is TJSONObject then Result := Trim(TJSONObject(J).Get('job', ''));
      finally
        J.Free;
      end;
    except
      // not JSON after all: nothing to run
    end;
  end;
end;

procedure TVDRX_JobRunnerExecutive.HandlePacket(const AMsg: TVDRX_Message);
begin
  if Copy(AMsg.Topic, 1, 6) = 'sched.' then
    Trigger(Copy(AMsg.Topic, 7, MaxInt), 'schedule')
  else if AMsg.Topic = 'jobs.run' then
    Trigger(JobNameOf(AMsg.Payload), 'manual')
  else if AMsg.Topic = 'jobs.kill' then
    KillJob(JobNameOf(AMsg.Payload))
  else if AMsg.Topic = 'jobs.list' then
    PublishState;
end;

// Caller holds the table lock. Never re-enters it.
function TVDRX_JobRunnerExecutive.StartRunLocked(ADef: TVDRX_JobDef;
  const ATrigger: string; out AError: string): Boolean;
var
  Run: TVDRX_JobRun;
  T: TVDRX_WorkerThread;
begin
  Result := False;
  AError := '';
  Inc(FRunSeq);
  Run := TVDRX_JobRun.Create(Self, ADef, FRunSeq, ATrigger);
  ADef.Running := True;
  ADef.CurrentRun := Run;
  FActive.Add(Run);
  try
    T := TVDRX_WorkerThread.Create(@Run.Go);
    T.FreeOnTerminate := True; // nobody joins a run; FActive is what Shutdown waits on
    T.Start;
    Result := True;
  except
    on E: Exception do
    begin
      AError := 'could not start a thread for the run: ' + E.Message;
      FActive.Remove(Run);
      ADef.Running := False;
      ADef.CurrentRun := nil;
      Run.Free;
    end;
  end;
end;

procedure TVDRX_JobRunnerExecutive.Trigger(const AName, ATrigger: string);
var
  Def: TVDRX_JobDef;
  Note, Reason, Err: string;
begin
  if AName = '' then Exit;
  Def := FTable.Find(AName);
  if Def = nil then
  begin
    Bus.Publish('log.warn', 'jobs: ' + ATrigger + ' for unknown job "' + AName + '"', ID);
    Exit;
  end;
  Note := '';
  Reason := '';
  FTable.Lock.Enter;
  try
    if FStopping then Exit;
    if Def.Running then
    begin
      case Def.Overlap of
        joSkip:
          begin
            Note := 'skip';
            Reason := 'previous run still active';
          end;
        joQueue:
          if Def.PendingRun then
          begin
            Note := 'skip';
            Reason := 'previous run still active and a rerun is already queued';
          end
          else
          begin
            Def.PendingRun := True;
            Note := 'queued';
            Reason := 'previous run still active - runs again when it ends';
          end;
        joKill:
          if Def.PendingRun then
          begin
            Note := 'skip';
            Reason := 'previous run is already being replaced';
          end
          else
          begin
            Def.PendingRun := True;
            Note := 'restart';
            Reason := 'stopping the previous run to start a new one';
            if Def.CurrentRun <> nil then Def.CurrentRun.RequestStop(STOP_RESTART);
          end;
      end;
    end
    else if Def.Waiting then
    begin
      Note := 'skip';
      Reason := 'already waiting for a free slot';
    end
    else if (FMaxConcurrent > 0) and (FActive.Count >= FMaxConcurrent) then
    begin
      Def.Waiting := True;
      FWaiting.Add(Def.Name);
      Note := 'queued';
      Reason := 'waiting for a free slot (max_concurrent ' + IntToStr(FMaxConcurrent) + ')';
    end
    else if not StartRunLocked(Def, ATrigger, Err) then
    begin
      Note := 'error';
      Reason := Err;
    end;
  finally
    FTable.Lock.Leave;
  end;
  if Note <> '' then PublishNote(AName, Note, Reason, ATrigger);
  if Note = 'error' then
    Bus.Publish('log.error', 'jobs: ' + AName + ': ' + Reason, ID);
end;

procedure TVDRX_JobRunnerExecutive.KillJob(const AName: string);
var
  Def: TVDRX_JobDef;
  Did, Cancelled: Boolean;
  i: Integer;
begin
  if AName = '' then Exit;
  Def := FTable.Find(AName);
  if Def = nil then
  begin
    Bus.Publish('log.warn', 'jobs: kill for unknown job "' + AName + '"', ID);
    Exit;
  end;
  Did := False;
  Cancelled := False;
  FTable.Lock.Enter;
  try
    Def.PendingRun := False; // a kill also cancels a rerun that was owed
    if Def.Waiting then
    begin
      i := FWaiting.IndexOf(Def.Name);
      if i >= 0 then FWaiting.Delete(i);
      Def.Waiting := False;
      Cancelled := True;
    end;
    if Def.Running and (Def.CurrentRun <> nil) then
    begin
      Def.CurrentRun.RequestStop(STOP_KILLED);
      Did := True;
    end;
  finally
    FTable.Lock.Leave;
  end;
  if Cancelled then PublishNote(AName, 'skip', 'removed from the wait queue', 'kill');
  if (not Did) and (not Cancelled) then
    Bus.Publish('log.warn', 'jobs: kill: "' + AName + '" is not running', ID);
  // when a process was running, its job.<id>.exit (status "killed") is the answer
end;

// Called by a run's thread as its last act; frees the run.
procedure TVDRX_JobRunnerExecutive.RunFinished(ARun: TVDRX_JobRun;
  const AStatus: string; ACode: Integer; ADurationMs: Int64);
var
  Def, Next: TVDRX_JobDef;
  Err: string;
begin
  Def := ARun.FDef;
  FTable.Lock.Enter;
  try
    FActive.Remove(ARun);
    Def.Running := False;
    Def.CurrentRun := nil;
    Inc(Def.RunCount);
    Def.LastStatus := AStatus;
    Def.LastCode := ACode;
    Def.LastEnded := UtcIso;
    Def.LastDurationMs := ADurationMs;
    if not FStopping then
    begin
      if Def.PendingRun then
      begin
        Def.PendingRun := False;
        if not StartRunLocked(Def, 'rerun', Err) then
          Bus.Publish('log.error', 'jobs: ' + Def.Name + ': ' + Err, ID);
      end;
      while (FWaiting.Count > 0) and ((FMaxConcurrent <= 0) or (FActive.Count < FMaxConcurrent)) do
      begin
        Next := FTable.Find(FWaiting[0]);
        FWaiting.Delete(0);
        if Next = nil then Continue;
        Next.Waiting := False;
        if not Next.Running then
          if not StartRunLocked(Next, 'queued', Err) then
            Bus.Publish('log.error', 'jobs: ' + Next.Name + ': ' + Err, ID);
      end;
    end;
  finally
    FTable.Lock.Leave;
  end;
  ARun.Free;
end;

procedure TVDRX_JobRunnerExecutive.NoteStarted(ARun: TVDRX_JobRun);
begin
  FTable.Lock.Enter;
  try
    ARun.FDef.LastStarted := UtcIso;
  finally
    FTable.Lock.Leave;
  end;
end;

procedure TVDRX_JobRunnerExecutive.PublishState;
var
  Root, Row: TJSONObject;
  Arr: TJSONArray;
  Wait: TJSONArray;
  i: Integer;
  D: TVDRX_JobDef;
  NowU: Int64;
  Due: Int64;
begin
  NowU := UnixNow;
  Root := TJSONObject.Create;
  try
    Arr := TJSONArray.Create;
    Root.Add('ts', UtcIso);
    FTable.Lock.Enter;
    try
      Root.Add('max_concurrent', FMaxConcurrent);
      Root.Add('active', FActive.Count);
      Wait := TJSONArray.Create;
      for i := 0 to FWaiting.Count - 1 do Wait.Add(FWaiting[i]);
      Root.Add('waiting', Wait);
      for i := 0 to FTable.Count - 1 do
      begin
        D := FTable.Item(i);
        Row := TJSONObject.Create;
        Row.Add('job', D.Name);
        Row.Add('enabled', D.Enabled);
        Row.Add('interval_sec', D.IntervalSec);
        Row.Add('overlap', OverlapName(D.Overlap));
        Row.Add('running', D.Running);
        if D.Running and (D.CurrentRun <> nil) then
        begin
          Row.Add('pid', D.CurrentRun.FPid);
          Row.Add('run', D.CurrentRun.FRunID);
        end;
        Row.Add('runs', D.RunCount);
        if D.LastStatus <> '' then
        begin
          Row.Add('last_status', D.LastStatus);
          Row.Add('last_code', D.LastCode);
          Row.Add('last_started', D.LastStarted);
          Row.Add('last_ended', D.LastEnded);
          Row.Add('last_duration_ms', D.LastDurationMs);
        end;
        if D.Enabled and (D.IntervalSec > 0) then
        begin
          if D.LastTick = 0 then
            Due := 0
          else
          begin
            Due := D.LastTick + D.IntervalSec - NowU;
            if Due < 0 then Due := 0;
          end;
          Row.Add('next_in_sec', Due);
        end;
        Arr.Add(Row);
      end;
    finally
      FTable.Lock.Leave;
    end;
    Root.Add('jobs', Arr);
    Bus.Publish('jobs.state', Root.AsJSON, ID);
  finally
    Root.Free;
  end;
end;

{ TVDRX_JobRun }

constructor TVDRX_JobRun.Create(AOwner: TVDRX_JobRunnerExecutive; ADef: TVDRX_JobDef;
  ARunID: Integer; const ATrigger: string);
begin
  inherited Create;
  FOwner := AOwner;
  FDef := ADef;
  FRunID := ARunID;
  FTrigger := ATrigger;
end;

procedure TVDRX_JobRun.RequestStop(ACode: LongInt);
begin
  // only the first request counts - a timeout must not overwrite a kill
  InterlockedCompareExchange(FStopCode, ACode, STOP_NONE);
end;

function TVDRX_JobRun.GraceFor(AStopCode: LongInt): QWord;
begin
  Result := FDef.KillGraceMs;
  if (AStopCode = STOP_SHUTDOWN) and (QWord(FOwner.FGraceMs) < Result) then
    Result := FOwner.FGraceMs;
end;

procedure TVDRX_JobRun.EmitLine(const AStream, ALine: string);
var
  L: string;
  O: TJSONObject;
begin
  L := ALine;
  if (L <> '') and (L[Length(L)] = #13) then SetLength(L, Length(L) - 1);
  if FDef.StripANSI then L := StripANSICodes(L);
  O := NewEvent(FDef.Name);
  try
    O.Add('run', FRunID);
    O.Add('pid', FPid);
    O.Add('stream', AStream);
    O.Add('line', CleanUTF8(L));
    FOwner.PublishJob(FDef.Name, AStream, O.AsJSON);
  finally
    O.Free;
  end;
end;

// Publishes every complete line in ABuf and keeps the unfinished tail. With
// AFinal the tail goes out too (the program ended without a final newline).
procedure TVDRX_JobRun.SplitLines(var ABuf: string; const AStream: string; AFinal: Boolean);
var
  Start, P: Integer;
begin
  Start := 1;
  repeat
    P := PosEx(#10, ABuf, Start);
    if P = 0 then Break;
    EmitLine(AStream, Copy(ABuf, Start, P - Start));
    Start := P + 1;
  until False;
  if Start > 1 then ABuf := Copy(ABuf, Start, MaxInt);
  if (ABuf <> '') and (AFinal or (Length(ABuf) >= MAX_LINE_BYTES)) then
  begin
    EmitLine(AStream, ABuf);
    ABuf := '';
  end;
end;

// Reads whatever is waiting on a pipe; returns the number of bytes read.
function TVDRX_JobRun.Drain(AStream: TInputPipeStream; var ABuf: string; const AName: string): Integer;
var
  Chunk: array[0..8191] of Byte;
  N: Integer;
  S: string;
begin
  Result := 0;
  while AStream.NumBytesAvailable > 0 do
  begin
    N := AStream.Read(Chunk[0], SizeOf(Chunk));
    if N <= 0 then Break;
    SetLength(S, N);
    Move(Chunk[0], S[1], N);
    ABuf := ABuf + S;
    Inc(Result, N);
    SplitLines(ABuf, AName, False);
  end;
end;

procedure TVDRX_JobRun.Go;
var
  Proc: TProcess;
  Parts: TStringList;
  Exe, Found, Status, StartError: string;
  i, p, Got, Code: Integer;
  WasRunning, Started, TermSent, KillSent: Boolean;
  T0, StopAt: QWord;
  SC: LongInt;
  O: TJSONObject;
begin
  Status := 'ok';
  StartError := '';
  Code := -1;
  Started := False;
  TermSent := False;
  KillSent := False;
  StopAt := 0;
  T0 := GetTickCount64;
  Proc := TProcess.Create(nil);
  Parts := TStringList.Create;
  try
    try
      // ---- start --------------------------------------------------------------
      try
        CommandToList(FDef.Command, Parts);
        if Parts.Count = 0 then raise Exception.Create('empty command');
        Exe := Parts[0];
        if not FileExists(Exe) then
        begin
          Found := ExeSearch(Exe, SysUtils.GetEnvironmentVariable('PATH'));
          if Found <> '' then Exe := Found;
        end;
        Proc.Executable := Exe;
        for i := 1 to Parts.Count - 1 do Proc.Parameters.Add(Parts[i]);
        for i := 0 to FDef.Args.Count - 1 do Proc.Parameters.Add(FDef.Args[i]);
        if FDef.WorkDir <> '' then Proc.CurrentDirectory := ExpandFileName(FDef.WorkDir);
        if FDef.Env.Count > 0 then
        begin
          // inherit the daemon's environment, then let the job's own entries win
          for i := 1 to GetEnvironmentVariableCount do
            Proc.Environment.Add(GetEnvironmentString(i));
          for i := 0 to FDef.Env.Count - 1 do
          begin
            if Pos('=', FDef.Env[i]) < 2 then Continue;
            p := Proc.Environment.IndexOfName(Copy(FDef.Env[i], 1, Pos('=', FDef.Env[i]) - 1));
            if p >= 0 then Proc.Environment.Delete(p);
            Proc.Environment.Add(FDef.Env[i]);
          end;
        end;
        Proc.Options := [poUsePipes]; // stdout and stderr stay separate
        Proc.Execute;
        Started := True;
      except
        on E: Exception do
        begin
          Status := 'start_failed';
          StartError := E.Message;
        end;
      end;

      if not Started then
      begin
        O := NewEvent(FDef.Name);
        try
          O.Add('run', FRunID);
          O.Add('status', Status);
          O.Add('code', -1);
          O.Add('duration_ms', Int64(GetTickCount64 - T0));
          O.Add('error', StartError);
          FOwner.PublishJob(FDef.Name, 'exit', O.AsJSON);
        finally
          O.Free;
        end;
        FOwner.Bus.Publish('log.error', 'jobs: ' + FDef.Name + ': could not start "' + FDef.Command + '": ' + StartError, FOwner.ID);
      end
      else
      begin
        FPid := Proc.ProcessID;
        FOwner.NoteStarted(Self);
        O := NewEvent(FDef.Name);
        try
          O.Add('run', FRunID);
          O.Add('pid', FPid);
          O.Add('trigger', FTrigger);
          FOwner.PublishJob(FDef.Name, 'start', O.AsJSON);
        finally
          O.Free;
        end;
        // the job reads no input: close stdin so a script that does read it gets EOF
        try Proc.CloseInput; except end;

        // ---- watch ------------------------------------------------------------
        repeat
          // Sample "running" BEFORE draining: if it had already exited and the
          // drain finds nothing, every byte it wrote has been collected.
          WasRunning := Proc.Running;
          Got := Drain(Proc.Output, FOutBuf, 'out') + Drain(Proc.Stderr, FErrBuf, 'err');
          if WasRunning then
          begin
            SC := FStopCode;
            if (SC = STOP_NONE) and (FDef.TimeoutSec > 0) and
               (GetTickCount64 - T0 > QWord(FDef.TimeoutSec) * 1000) then
            begin
              RequestStop(STOP_TIMEOUT);
              SC := FStopCode;
            end;
            if SC <> STOP_NONE then
            begin
              if not TermSent then
              begin
                TermSent := True;
                StopAt := GetTickCount64;
                TryGracefulTerminate(Proc);
              end
              else if (not KillSent) and (GetTickCount64 - StopAt >= GraceFor(SC)) then
              begin
                KillSent := True;
                ForceKillProcess(Proc);
              end;
            end;
            if Got = 0 then Sleep(5);
          end;
        until (not WasRunning) and (Got = 0);
        SplitLines(FOutBuf, 'out', True);
        SplitLines(FErrBuf, 'err', True);

        Code := Proc.ExitStatus;
        {$IFDEF UNIX}
        // FPC 3.2 returns the raw wait() status (exit code 1 arrives as 256)
        if (Code >= 256) and ((Code and $FF) = 0) then Code := Code shr 8;
        {$ENDIF}
        SC := FStopCode;
        if SC = STOP_TIMEOUT then
          Status := 'timeout'
        else if SC <> STOP_NONE then
          Status := 'killed'
        else if Code = 0 then
          Status := 'ok'
        else
          Status := 'failed';

        O := NewEvent(FDef.Name);
        try
          O.Add('run', FRunID);
          O.Add('pid', FPid);
          O.Add('status', Status);
          O.Add('code', Code);
          O.Add('duration_ms', Int64(GetTickCount64 - T0));
          if SC <> STOP_NONE then O.Add('stop', StopName(SC));
          FOwner.PublishJob(FDef.Name, 'exit', O.AsJSON);
        finally
          O.Free;
        end;
        if (Status = 'failed') or (Status = 'timeout') then
          FOwner.Bus.Publish('log.warn', 'jobs: ' + FDef.Name + ' ' + Status + ' (exit ' + IntToStr(Code) + ', ' +
            IntToStr(GetTickCount64 - T0) + 'ms)', FOwner.ID);
      end;
    except
      on E: Exception do
      begin
        Status := 'error';
        FOwner.Bus.Publish('log.error', 'jobs: ' + FDef.Name + ': unexpected error: ' + E.ClassName + ': ' + E.Message, FOwner.ID);
        try
          if Started and Proc.Running then ForceKillProcess(Proc);
        except
        end;
      end;
    end;
  finally
    Parts.Free;
    Proc.Free;
  end;
  // last act: book-keeping, start whatever was waiting, free this run
  FOwner.RunFinished(Self, Status, Code, Int64(GetTickCount64 - T0));
end;

{ TVDRX_JobConsoleExecutive }

constructor TVDRX_JobConsoleExecutive.Create(ABus: TVDRX_MessageQueue; AColor: Boolean);
begin
  inherited Create(ABus);
  FColor := AColor;
  FLock := TCriticalSection.Create;
  FSignal := TEvent.Create(nil, False, False, '');
  FPending := TVDRX_MessageList.Create;
  FWriter := TVDRX_WorkerThread.Create(@WriterLoop);
  FWriter.Start;
end;

destructor TVDRX_JobConsoleExecutive.Destroy;
begin
  Shutdown;
  FWriter.Free;
  FPending.Free;
  FSignal.Free;
  FLock.Free;
  inherited;
end;

procedure TVDRX_JobConsoleExecutive.Shutdown;
begin
  FLock.Enter;
  try
    if FStopping then Exit;
    FStopping := True;
  finally
    FLock.Leave;
  end;
  FSignal.SetEvent;
  FWriter.WaitFor;
  FlushPending; // anything published after the writer's final pass
end;

procedure TVDRX_JobConsoleExecutive.HandlePacket(const AMsg: TVDRX_Message);
begin
  FLock.Enter;
  try
    FPending.Add(AMsg);
  finally
    FLock.Leave;
  end;
  FSignal.SetEvent;
end;

procedure TVDRX_JobConsoleExecutive.FlushPending;
var
  Batch: TVDRX_MessageList;
  Text, Line: string;
  i: Integer;
begin
  Batch := TVDRX_MessageList.Create;
  try
    FLock.Enter;
    try
      Batch.AddRange(FPending);
      FPending.Clear;
    finally
      FLock.Leave;
    end;
    Text := '';
    for i := 0 to Batch.Count - 1 do
    begin
      try
        Line := FormatMessage(Batch[i]);
      except
        Line := ''; // a malformed payload must not stop the console
      end;
      Text := Text + Line;
    end;
  finally
    Batch.Free;
  end;
  ConsoleWrite(Text);
end;

procedure TVDRX_JobConsoleExecutive.WriterLoop;
var
  Stopping: Boolean;
begin
  repeat
    FSignal.WaitFor(250);
    FLock.Enter;
    try
      Stopping := FStopping;
    finally
      FLock.Leave;
    end;
    FlushPending;
  until Stopping;
end;

function FormatDuration(AMs: Int64): string;
begin
  if AMs < 1000 then
    Result := IntToStr(AMs) + 'ms'
  else if AMs < 60000 then
    Result := FormatFloat('0.0', AMs / 1000) + 's'
  else
    Result := IntToStr(AMs div 60000) + 'm' + IntToStr((AMs mod 60000) div 1000) + 's';
end;

// "job.its.out" + payload -> one console line ('' = print nothing)
function TVDRX_JobConsoleExecutive.FormatMessage(const AMsg: TVDRX_Message): string;
const
  ESC = #27;
  ARROW = #$E2#$96#$BA; // the "play" triangle, as UTF-8 bytes
var
  J: TJSONData;
  O: TJSONObject;
  Job, Suffix, Stamp, Prefix, Msg: string;
  Pid, Color, p, q: Integer;
  Status: string;
begin
  Result := '';
  // topic: job.<id>.<suffix>
  p := Pos('.', AMsg.Topic);
  if p = 0 then Exit;
  q := PosEx('.', AMsg.Topic, p + 1);
  if q = 0 then Exit;
  Job := Copy(AMsg.Topic, p + 1, q - p - 1);
  Suffix := Copy(AMsg.Topic, q + 1, MaxInt);

  J := GetJSON(AMsg.Payload);
  try
    if not (J is TJSONObject) then Exit;
    O := TJSONObject(J);
    Stamp := StringReplace(Copy(O.Get('ts', ''), 1, 19), 'T', ' ', []);
    Pid := O.Get('pid', 0);
    Color := 92;
    if Suffix = 'out' then
    begin
      Msg := O.Get('line', '');
      if Trim(Msg) = '' then Exit;
    end
    else if Suffix = 'err' then
    begin
      Msg := O.Get('line', '');
      if Trim(Msg) = '' then Exit;
      Color := 91;
    end
    else if Suffix = 'start' then
    begin
      Msg := 'started (' + O.Get('trigger', '') + ')';
      Color := 96;
    end
    else if Suffix = 'exit' then
    begin
      Status := O.Get('status', '');
      if Status = 'ok' then
        Msg := 'finished in ' + FormatDuration(O.Get('duration_ms', Int64(0)))
      else
      begin
        Color := 91;
        Msg := Status;
        if (O.Get('stop', '') <> '') and (O.Get('stop', '') <> Status) then Msg := Msg + ' (' + O.Get('stop', '') + ')';
        if Status = 'failed' then Msg := Msg + ', exit code ' + IntToStr(O.Get('code', -1));
        Msg := Msg + ' after ' + FormatDuration(O.Get('duration_ms', Int64(0)));
        if O.Get('error', '') <> '' then Msg := Msg + ': ' + O.Get('error', '');
      end;
    end
    else if (Suffix = 'skip') or (Suffix = 'queued') or (Suffix = 'restart') then
    begin
      Msg := Suffix + ': ' + O.Get('reason', '');
      Color := 90;
    end
    else if Suffix = 'error' then
    begin
      Msg := O.Get('reason', '');
      Color := 91;
    end
    else
      Exit;
  finally
    J.Free;
  end;

  if Pid > 0 then
    Prefix := Stamp + ' [' + Job + ':' + IntToStr(Pid) + ']'
  else
    Prefix := Stamp + ' [' + Job + ']';
  if FColor then
    Result := ESC + '[30m' + ESC + '[103m' + Prefix + ' ' + ESC + '[0m' +
      ESC + '[93m' + ARROW + ESC + '[0m' +
      ESC + '[' + IntToStr(Color) + 'm ' + Msg + ESC + '[0m' + LineEnding
  else
    Result := Prefix + ' > ' + Msg + LineEnding;
end;

end.
