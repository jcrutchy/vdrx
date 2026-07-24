unit vdrx_core;

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

  TVDRX_Executive = class;

  TVDRX_Message = record
    Topic: string;
    Payload: string;
    SourceID: string;
    Seq: Int64;
    Timestamp: TDateTime;
  end;

  TVDRX_ExecList = specialize TList<TVDRX_Executive>;
  TVDRX_ExecListDictionary = specialize TObjectDictionary<string, TVDRX_ExecList>;
  TVDRX_ExecMasterMap = specialize TObjectDictionary<string, TVDRX_Executive>;
  TVDRX_MessageList = specialize TList<TVDRX_Message>;

  TVDRX_WorkerThread = class(TThread)
  private
    FExecuteMethod: TThreadMethod;
  protected
    procedure Execute; override;
  public
    constructor Create(AExecuteMethod: TThreadMethod);
  end;

  TVDRX_MessageQueue = class
  private
    FList: TVDRX_MessageList;
    FLock: TCriticalSection;
    FSignal: TEvent;
    FSeqCounter: Int64;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Publish(const ATopic, APayload, ASourceID: string);
    function TryDequeue(out AMsg: TVDRX_Message; TimeoutMs: Cardinal = 500): Boolean;
  end;

  // Base for every executive - internal object, external-process Bridge, or socket
  // listener. Holds a Bus reference so descendants can Publish from Initialize,
  // reader threads, or HandlePacket alike. Initialize/Shutdown are virtual with an
  // empty default so most executives (Logger, Whiteboard) can ignore them entirely;
  // Bridge and the socket listeners override both to spawn/bind on startup and tear
  // down cleanly on shutdown. No intermediate base class for "threaded" or "socket"
  // executives yet - deliberately waiting for three concrete, near-identical
  // examples before extracting one (see session notes).

  { TVDRX_Executive }

  TVDRX_Executive = class
  private
    FID: string;
    FBus: TVDRX_MessageQueue;
  public
    constructor Create(ABus: TVDRX_MessageQueue); virtual;
    property ID: string read FID write FID;
    property Bus: TVDRX_MessageQueue read FBus;
    procedure Initialize; virtual;
    procedure Shutdown; virtual;
    procedure HandlePacket(const AMsg: TVDRX_Message); virtual; abstract;
    procedure ApplyConfig; virtual;
  end;

  // A single (Executive, Filter) routing entry. Filters now live here rather than on
  // the executive itself, so one executive can be registered under any number of
  // them - e.g. a Logger subscribed to both 'log.>' and 'irc.>'.
  TVDRX_Subscription = class
  public
    Exec: TVDRX_Executive;
    Filter: string;
    constructor Create(AExec: TVDRX_Executive; const AFilter: string);
  end;

  TVDRX_SubList = specialize TObjectList<TVDRX_Subscription>; // owns its Subscriptions
  TVDRX_SubListDictionary = specialize TObjectDictionary<string, TVDRX_SubList>;

  // MasterMap (owning, ID -> Executive) is still the single source of truth for
  // lifecycle and memory management - exactly one entry per AID, regardless of how
  // many filters that executive is subscribed under. LiteralSubs/WildcardSubs are
  // reference-only routing indices of TVDRX_Subscription pairs; the same executive
  // can appear in either or both, any number of times, under different filters.
  TVDRX_Registry = class
  private
    FMasterMap: TVDRX_ExecMasterMap;
    FLiteralSubs: TVDRX_SubListDictionary;
    FWildcardSubs: TVDRX_SubList;
    FLock: TCriticalSection;
    procedure RemoveSubscriptionsUnlocked(AExec: TVDRX_Executive);
  public
    constructor Create;
    destructor Destroy; override;
    // Adds one more filter subscription for AExec under AID. If AID isn't already
    // registered, this also takes ownership of AExec (it'll be freed on
    // Unregister). Safe to call repeatedly with the same AID to add more filters to
    // an already-registered executive.
    procedure Register(AExec: TVDRX_Executive; const AID, AFilter: string);
    // Drops every filter subscription for AID WITHOUT destroying the executive -
    // use this (then Register again) to replace an executive's subscriptions in
    // place, e.g. a WebSocket connection re-subscribing to a new topic.
    procedure ClearFilters(const AID: string);
    // Drops just the one (AID, AFilter) subscription, leaving any other filters
    // that AID is registered under untouched - use this when an executive wants to
    // leave a single topic without losing its other subscriptions, e.g. an IRC
    // connection PARTing one channel while staying in others.
    procedure UnregisterFilter(const AID, AFilter: string);
    // Drops every filter subscription for AID AND destroys the executive (owning
    // map). Use when the executive itself is going away, not just its subscriptions.
    procedure Unregister(const AID: string);
    function GetSubscribers(const ATopic: string): TVDRX_ExecList;
    procedure InitializeAll;
    procedure ShutdownAll;
    procedure ApplyAllConfigs;
  end;

  { TVDRX_Kernel }

  TVDRX_Kernel = class(TThread)
  private
    FQueue: TVDRX_MessageQueue;
    FRegistry: TVDRX_Registry;
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Terminate;
  public
    property Queue: TVDRX_MessageQueue read FQueue;
    property Registry: TVDRX_Registry read FRegistry;
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

{ TVDRX_WorkerThread }

constructor TVDRX_WorkerThread.Create(AExecuteMethod: TThreadMethod);
begin
  inherited Create(True);
  FExecuteMethod := AExecuteMethod;
  FreeOnTerminate := False;
end;

procedure TVDRX_WorkerThread.Execute;
begin
  if Assigned(FExecuteMethod) then
  begin
    FExecuteMethod();
  end;
end;

{ TVDRX_MessageQueue }

constructor TVDRX_MessageQueue.Create;
begin
  FList := TVDRX_MessageList.Create;
  FLock := TCriticalSection.Create;
  FSignal := TEvent.Create(nil, False, False, '');
end;

destructor TVDRX_MessageQueue.Destroy;
begin
  FSignal.Free;
  FLock.Free;
  FList.Free;
  inherited;
end;

procedure TVDRX_MessageQueue.Publish(const ATopic, APayload, ASourceID: string);
var
  Msg: TVDRX_Message;
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

function TVDRX_MessageQueue.TryDequeue(out AMsg: TVDRX_Message; TimeoutMs: Cardinal): Boolean;
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

{ TVDRX_Executive }

constructor TVDRX_Executive.Create(ABus: TVDRX_MessageQueue);
begin
  inherited Create;
  FBus := ABus;
end;

procedure TVDRX_Executive.Initialize;
begin
end;

procedure TVDRX_Executive.Shutdown;
begin
end;

procedure TVDRX_Executive.ApplyConfig;
begin
end;

{ TVDRX_Subscription }

constructor TVDRX_Subscription.Create(AExec: TVDRX_Executive; const AFilter: string);
begin
  inherited Create;
  Exec := AExec;
  Filter := AFilter;
end;

{ TVDRX_Registry }

constructor TVDRX_Registry.Create;
begin
  FLock := TCriticalSection.Create;
  FMasterMap := TVDRX_ExecMasterMap.Create([doOwnsValues]);
  FLiteralSubs := TVDRX_SubListDictionary.Create([doOwnsValues]);
  FWildcardSubs := TVDRX_SubList.Create; // owns its Subscriptions
end;

destructor TVDRX_Registry.Destroy;
begin
  FWildcardSubs.Free;
  FLiteralSubs.Free;
  FMasterMap.Free; // owns and frees every registered executive
  FLock.Free;
  inherited;
end;

// Adds one more filter subscription for AExec under AID. Only takes ownership of
// AExec (adds it to the owning MasterMap) the first time AID is seen; subsequent
// calls with the same AID just add another Subscription for the already-owned
// executive - this is what lets one executive be registered under any number of
// filters, e.g. Register(Logger, 'logger', 'log.>') then
// Register(Logger, 'logger', 'irc.>').
procedure TVDRX_Registry.Register(AExec: TVDRX_Executive; const AID, AFilter: string);
var
  List: TVDRX_SubList;
  Sub: TVDRX_Subscription;
begin
  FLock.Enter;
  try
    if not FMasterMap.ContainsKey(AID) then
    begin
      AExec.ID := AID;
      FMasterMap.Add(AID, AExec);
    end;
    Sub := TVDRX_Subscription.Create(AExec, AFilter);
    if (Pos('*', AFilter) > 0) or (Pos('>', AFilter) > 0) then
      FWildcardSubs.Add(Sub)
    else
    begin
      if not FLiteralSubs.TryGetValue(AFilter, List) then
      begin
        List := TVDRX_SubList.Create;
        FLiteralSubs.Add(AFilter, List);
      end;
      List.Add(Sub);
    end;
  finally
    FLock.Leave;
  end;
end;

// Removes every Subscription that points at AExec, from both the wildcard list and
// every literal-filter bucket, without touching the MasterMap. Caller holds FLock.
procedure TVDRX_Registry.RemoveSubscriptionsUnlocked(AExec: TVDRX_Executive);
var
  i: Integer;
  List: TVDRX_SubList;
begin
  for i := FWildcardSubs.Count - 1 downto 0 do
    if FWildcardSubs[i].Exec = AExec then
      FWildcardSubs.Delete(i); // owned list - frees the Subscription

  for List in FLiteralSubs.Values do
    for i := List.Count - 1 downto 0 do
      if List[i].Exec = AExec then
        List.Delete(i);
end;

procedure TVDRX_Registry.ClearFilters(const AID: string);
var
  Exec: TVDRX_Executive;
begin
  FLock.Enter;
  try
    if FMasterMap.TryGetValue(AID, Exec) then
      RemoveSubscriptionsUnlocked(Exec);
  finally
    FLock.Leave;
  end;
end;

procedure TVDRX_Registry.UnregisterFilter(const AID, AFilter: string);
var
  Exec: TVDRX_Executive;
  i: Integer;
  List: TVDRX_SubList;
begin
  FLock.Enter;
  try
    if not FMasterMap.TryGetValue(AID, Exec) then
      Exit;
    for i := FWildcardSubs.Count - 1 downto 0 do
      if (FWildcardSubs[i].Exec = Exec) and (FWildcardSubs[i].Filter = AFilter) then
        FWildcardSubs.Delete(i);
    if FLiteralSubs.TryGetValue(AFilter, List) then
      for i := List.Count - 1 downto 0 do
        if List[i].Exec = Exec then
          List.Delete(i);
  finally
    FLock.Leave;
  end;
end;

procedure TVDRX_Registry.Unregister(const AID: string);
var
  Exec: TVDRX_Executive;
begin
  FLock.Enter;
  try
    if not FMasterMap.TryGetValue(AID, Exec) then
      Exit;
    RemoveSubscriptionsUnlocked(Exec);
    FMasterMap.Remove(AID); // owning map - this is what actually frees Exec
  finally
    FLock.Leave;
  end;
end;

// Same executive can be reachable via more than one matching Subscription (e.g. two
// overlapping wildcard filters, or a literal + a wildcard both matching ATopic) -
// dedupe so HandlePacket is never called twice for one message.
function TVDRX_Registry.GetSubscribers(const ATopic: string): TVDRX_ExecList;
var
  Sub: TVDRX_Subscription;
  List: TVDRX_SubList;
begin
  FLock.Enter;
  try
    Result := TVDRX_ExecList.Create;
    if FLiteralSubs.TryGetValue(ATopic, List) then
      for Sub in List do
        if Result.IndexOf(Sub.Exec) < 0 then
          Result.Add(Sub.Exec);
    for Sub in FWildcardSubs do
      if TopicMatches(Sub.Filter, ATopic) then
        if Result.IndexOf(Sub.Exec) < 0 then
          Result.Add(Sub.Exec);
  finally
    FLock.Leave;
  end;
end;

procedure TVDRX_Registry.InitializeAll;
var
  Snapshot: TVDRX_ExecList;
  Exec: TVDRX_Executive;
begin
  Snapshot := TVDRX_ExecList.Create;
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

procedure TVDRX_Registry.ShutdownAll;
var
  Snapshot: TVDRX_ExecList;
  Exec: TVDRX_Executive;
begin
  Snapshot := TVDRX_ExecList.Create;
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

procedure TVDRX_Registry.ApplyAllConfigs;
var
  Snapshot: TVDRX_ExecList;
  Exec: TVDRX_Executive;
begin
  Snapshot := TVDRX_ExecList.Create;
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

{ TVDRX_Kernel }

constructor TVDRX_Kernel.Create;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FRegistry := TVDRX_Registry.Create;
  FQueue := TVDRX_MessageQueue.Create;
end;

destructor TVDRX_Kernel.Destroy;
begin
  inherited;
end;

procedure TVDRX_Kernel.Execute;
var
  Msg: TVDRX_Message;
  Subscribers: TVDRX_ExecList;
  Exec: TVDRX_Executive;
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

procedure TVDRX_Kernel.Terminate;
begin
  inherited Terminate;
  FQueue.Publish('kernel.shutdown', '', '');
end;

end.
