unit vrdx_core;

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  SyncObjs,
  DateUtils,
  Generics.Collections;

const
  Infinite = UInt32(-1);

type

  TVRDX_Executive = class;

  TVRDX_Message = record
    Topic: string;
    Payload: string;
    SourceID: string;
    Seq: Int64;
    Timestamp: TDateTime;
  end;

  TVRDX_ExecList = specialize TList<TVRDX_Executive>;
  TVRDX_ExecListDictionary = specialize TObjectDictionary<string, TVRDX_ExecList>;
  TVRDX_ExecMasterMap = specialize TObjectDictionary<string, TVRDX_Executive>;
  TVRDX_MessageList = specialize TList<TVRDX_Message>;

  TVRDX_WorkerThread = class(TThread)
  private
    FExecuteMethod: TThreadMethod;
  protected
    procedure Execute; override;
  public
    constructor Create(AExecuteMethod: TThreadMethod);
  end;

  TVRDX_MessageQueue = class
  private
    FList: TVRDX_MessageList;
    FLock: TCriticalSection;
    FSignal: TEvent;
    FSeqCounter: Int64;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Publish(const ATopic, APayload, ASourceID: string);
    function TryDequeue(out AMsg: TVRDX_Message; TimeoutMs: Cardinal = 500): Boolean;
  end;

  // Base for every executive - internal object, external-process Bridge, or socket
  // listener. Holds a Bus reference so descendants can Publish from Initialize,
  // reader threads, or HandlePacket alike. Initialize/Shutdown are virtual with an
  // empty default so most executives (Logger, Whiteboard) can ignore them entirely;
  // Bridge and the socket listeners override both to spawn/bind on startup and tear
  // down cleanly on shutdown. No intermediate base class for "threaded" or "socket"
  // executives yet - deliberately waiting for three concrete, near-identical
  // examples before extracting one (see session notes).

  { TVRDX_Executive }

  TVRDX_Executive = class
  private
    FID: string;
    FBus: TVRDX_MessageQueue;
  public
    constructor Create(ABus: TVRDX_MessageQueue); virtual;
    property ID: string read FID write FID;
    property Bus: TVRDX_MessageQueue read FBus;
    procedure Initialize; virtual;
    procedure Shutdown; virtual;
    procedure HandlePacket(const AMsg: TVRDX_Message); virtual; abstract;
    procedure ApplyConfig; virtual;
  end;

  // A single (Executive, Filter) routing entry. Filters now live here rather than on
  // the executive itself, so one executive can be registered under any number of
  // them - e.g. a Logger subscribed to both 'log.>' and 'irc.>'.
  TVRDX_Subscription = class
  public
    Exec: TVRDX_Executive;
    Filter: string;
    constructor Create(AExec: TVRDX_Executive; const AFilter: string);
  end;

  TVRDX_SubList = specialize TObjectList<TVRDX_Subscription>; // owns its Subscriptions
  TVRDX_SubListDictionary = specialize TObjectDictionary<string, TVRDX_SubList>;

  // MasterMap (owning, ID -> Executive) is still the single source of truth for
  // lifecycle and memory management - exactly one entry per AID, regardless of how
  // many filters that executive is subscribed under. LiteralSubs/WildcardSubs are
  // reference-only routing indices of TVRDX_Subscription pairs; the same executive
  // can appear in either or both, any number of times, under different filters.
  TVRDX_Registry = class
  private
    FMasterMap: TVRDX_ExecMasterMap;
    FLiteralSubs: TVRDX_SubListDictionary;
    FWildcardSubs: TVRDX_SubList;
    FLock: TCriticalSection;
    procedure RemoveSubscriptionsUnlocked(AExec: TVRDX_Executive);
  public
    constructor Create;
    destructor Destroy; override;
    // Adds one more filter subscription for AExec under AID. If AID isn't already
    // registered, this also takes ownership of AExec (it'll be freed on
    // Unregister). Safe to call repeatedly with the same AID to add more filters to
    // an already-registered executive.
    procedure Register(AExec: TVRDX_Executive; const AID, AFilter: string);
    // Drops every filter subscription for AID WITHOUT destroying the executive -
    // use this (then Register again) to replace an executive's subscriptions in
    // place, e.g. a WebSocket connection re-subscribing to a new topic.
    procedure ClearFilters(const AID: string);
    // Drops every filter subscription for AID AND destroys the executive (owning
    // map). Use when the executive itself is going away, not just its subscriptions.
    procedure Unregister(const AID: string);
    function GetSubscribers(const ATopic: string): TVRDX_ExecList;
    procedure InitializeAll;
    procedure ShutdownAll;
    procedure ApplyAllConfigs;
  end;

  { TVRDX_Kernel }

  TVRDX_Kernel = class(TThread)
  private
    FQueue: TVRDX_MessageQueue;
    FRegistry: TVRDX_Registry;
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Terminate;
  public
    property Queue: TVRDX_MessageQueue read FQueue;
    property Registry: TVRDX_Registry read FRegistry;
  end;

implementation

function TopicMatches(const Filter, Topic: string): Boolean;
var
  fParts, tParts: TStringArray;
  i: Integer;
begin
  fParts := Filter.Split(['.']);
  tParts := Topic.Split(['.']);
  for i := 0 to High(fParts) do
  begin
    if fParts[i] = '>' then
      Exit(True);
    if i > High(tParts) then
      Exit(False);
    if (fParts[i] <> '*') and (fParts[i] <> tParts[i]) then
      Exit(False);
  end;
  Result := Length(fParts) = Length(tParts);
end;

{ TVRDX_WorkerThread }

constructor TVRDX_WorkerThread.Create(AExecuteMethod: TThreadMethod);
begin
  inherited Create(True);
  FExecuteMethod := AExecuteMethod;
  FreeOnTerminate := False;
end;

procedure TVRDX_WorkerThread.Execute;
begin
  if Assigned(FExecuteMethod) then
  begin
    FExecuteMethod();
  end;
end;

{ TVRDX_MessageQueue }

constructor TVRDX_MessageQueue.Create;
begin
  FList := TVRDX_MessageList.Create;
  FLock := TCriticalSection.Create;
  FSignal := TEvent.Create(nil, False, False, '');
end;

destructor TVRDX_MessageQueue.Destroy;
begin
  FSignal.Free;
  FLock.Free;
  FList.Free;
  inherited;
end;

procedure TVRDX_MessageQueue.Publish(const ATopic, APayload, ASourceID: string);
var
  Msg: TVRDX_Message;
begin
  FLock.Enter;
  try
    Inc(FSeqCounter);
    Msg.Topic := ATopic;
    Msg.Payload := APayload;
    Msg.SourceID := ASourceID;
    Msg.Seq := FSeqCounter;
    Msg.Timestamp := Now;
    FList.Add(Msg);
  finally
    FLock.Leave;
  end;
  FSignal.SetEvent;
end;

function TVRDX_MessageQueue.TryDequeue(out AMsg: TVRDX_Message; TimeoutMs: Cardinal): Boolean;
begin
  Result := False;
  if FSignal.WaitFor(TimeoutMs) <> wrSignaled then
    Exit;
  FLock.Enter;
  try
    Result := FList.Count > 0;
    if Result then
    begin
      AMsg := FList[0];
      FList.Delete(0);
      if FList.Count > 0 then
        FSignal.SetEvent;
    end;
  finally
    FLock.Leave;
  end;
end;

{ TVRDX_Executive }

constructor TVRDX_Executive.Create(ABus: TVRDX_MessageQueue);
begin
  inherited Create;
  FBus := ABus;
end;

procedure TVRDX_Executive.Initialize;
begin
end;

procedure TVRDX_Executive.Shutdown;
begin
end;

procedure TVRDX_Executive.ApplyConfig;
begin
end;

{ TVRDX_Registry }

constructor TVRDX_Registry.Create;
begin
  FLock := TCriticalSection.Create;
  FMasterMap := TVRDX_ExecMasterMap.Create([doOwnsValues]);
  FLiteralSubs := TVRDX_ExecListDictionary.Create([doOwnsValues]);
  FWildcardSubs := TVRDX_ExecList.Create;
end;

destructor TVRDX_Registry.Destroy;
begin
  FWildcardSubs.Free;
  FLiteralSubs.Free;
  FMasterMap.Free; // owns and frees every registered executive
  FLock.Free;
  inherited;
end;

procedure TVRDX_Registry.Register(AExec: TVRDX_Executive; const AID, AFilter: string);
var
  List: TVRDX_ExecList;
begin
  FLock.Enter;
  try
    AExec.ID := AID;
    AExec.Filter := AFilter;
    FMasterMap.Add(AID, AExec);
    if (Pos('*', AFilter) > 0) or (Pos('>', AFilter) > 0) then
      FWildcardSubs.Add(AExec)
    else
    begin
      if not FLiteralSubs.TryGetValue(AFilter, List) then
      begin
        List := TVRDX_ExecList.Create;
        FLiteralSubs.Add(AFilter, List);
      end;
      List.Add(AExec);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TVRDX_Registry.Unregister(const AID: string);
var
  Exec: TVRDX_Executive;
  List: TVRDX_ExecList;
begin
  FLock.Enter;
  try
    if not FMasterMap.TryGetValue(AID, Exec) then
      Exit;
    FWildcardSubs.Remove(Exec);
    for List in FLiteralSubs.Values do
      List.Remove(Exec);
    FMasterMap.Remove(AID); // owning map - this is what actually frees Exec
  finally
    FLock.Leave;
  end;
end;

function TVRDX_Registry.GetSubscribers(const ATopic: string): TVRDX_ExecList;
var
  Exec: TVRDX_Executive;
begin
  FLock.Enter;
  try
    Result := TVRDX_ExecList.Create;
    if FLiteralSubs.ContainsKey(ATopic) then
      Result.AddRange(FLiteralSubs[ATopic]);
    for Exec in FWildcardSubs do
      if TopicMatches(Exec.Filter, ATopic) then
        Result.Add(Exec);
  finally
    FLock.Leave;
  end;
end;

procedure TVRDX_Registry.InitializeAll;
var
  Snapshot: TVRDX_ExecList;
  Exec: TVRDX_Executive;
begin
  Snapshot := TVRDX_ExecList.Create;
  try
    FLock.Enter;
    try
      Snapshot.AddRange(FMasterMap.Values);
    finally
      FLock.Leave;
    end;
    // Deliberately called outside FLock - Initialize can block for a while (binding
    // a socket, spawning a process) and must not stall Register/Unregister/
    // GetSubscribers while it runs.
    for Exec in Snapshot do
      Exec.Initialize;
  finally
    Snapshot.Free;
  end;
end;

procedure TVRDX_Registry.ShutdownAll;
var
  Snapshot: TVRDX_ExecList;
  Exec: TVRDX_Executive;
begin
  Snapshot := TVRDX_ExecList.Create;
  try
    FLock.Enter;
    try
      Snapshot.AddRange(FMasterMap.Values);
    finally
      FLock.Leave;
    end;
    for Exec in Snapshot do
      Exec.Shutdown;
  finally
    Snapshot.Free;
  end;
end;

procedure TVRDX_Registry.ApplyAllConfigs;
var
  Snapshot: TVRDX_ExecList;
  Exec: TVRDX_Executive;
begin
  Snapshot := TVRDX_ExecList.Create;
  try
    FLock.Enter;
    try
      Snapshot.AddRange(FMasterMap.Values);
    finally
      FLock.Leave;
    end;
    for Exec in Snapshot do
      Exec.ApplyConfig;
  finally
    Snapshot.Free;
  end;
end;

{ TVRDX_Kernel }

constructor TVRDX_Kernel.Create;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FRegistry := TVRDX_Registry.Create;
  FQueue := TVRDX_MessageQueue.Create;
end;

destructor TVRDX_Kernel.Destroy;
begin
  inherited;
end;

procedure TVRDX_Kernel.Execute;
var
  Msg: TVRDX_Message;
  Subscribers: TVRDX_ExecList;
  Exec: TVRDX_Executive;
begin
  FRegistry.InitializeAll;
  while not Terminated do
  begin
    if FQueue.TryDequeue(Msg, 500) then
    begin
      if Msg.Topic = 'kernel.shutdown' then
      begin
        WriteLn('Dispatcher: Shutdown signal processed.');
        Break;
      end;
      Subscribers := FRegistry.GetSubscribers(Msg.Topic);
      try
        for Exec in Subscribers do
          Exec.HandlePacket(Msg);
      finally
        Subscribers.Free;
      end;
    end;
  end;
  FRegistry.ShutdownAll;
  FQueue.Free;
  FRegistry.Free;
  WriteLn('Dispatcher: Exited loop cleanly.');
end;

procedure TVRDX_Kernel.Terminate;
begin
  inherited Terminate;
  FQueue.Publish('kernel.shutdown', '', '');
end;

end.
