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
    FHead: Integer; // index of the next message to dequeue; see TryDequeue
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
  // empty default so most executives (Logger, Admin) can ignore them entirely;
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
    // Drops every filter subscription for AID, calls the executive's Shutdown
    // (threads/child processes torn down here), THEN destroys it (owning map).
    // Use when the executive itself is going away, not just its subscriptions -
    // this is what 'sys.kill'/'sys.killall' (see vdrx_admin.pas) actually call.
    procedure Unregister(const AID: string);
    // Thread-safe lookup without taking ownership - used by admin kill-by-id.
    function Find(const AID: string): TVDRX_Executive;
    function GetSubscribers(const ATopic: string): TVDRX_ExecList;
    // Caller-owned copy of every currently-registered executive (references only,
    // doesn't affect ownership) - used by admin kill-by-pid/killall to enumerate
    // without holding the lock while doing potentially slow work per executive.
    function Snapshot: TVDRX_ExecList;
    procedure InitializeAll;
    procedure ShutdownAll;
    procedure ApplyAllConfigs;
    // Drops the AID entry WITHOUT calling Shutdown - for an executive's own
    // thread to call on itself when it's exiting normally (e.g. a
    // connection's RunLoop reaching its natural end after the client
    // disconnects). Unregister (above) calls Shutdown first, which includes
    // a WaitFor on that executive's own thread - fine when called from some
    // OTHER thread (admin's sys.kill/sys.killall), but a thread can never
    // WaitFor itself: that's an immediate, silent deadlock. This is the
    // symptom that showed up as "'quit' does nothing after the dashboard's
    // WebSocket connection has opened and closed once" - found this session.
    procedure UnregisterSelf(const AID: string);
  end;

  { TVDRX_Kernel }

  TVDRX_Kernel = class(TThread)
  private
    FQueue: TVDRX_MessageQueue;
    FRegistry: TVDRX_Registry;
    FRestartRequested: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Terminate;
  public
    property Queue: TVDRX_MessageQueue read FQueue;
    property Registry: TVDRX_Registry read FRegistry;
    // Set by TVDRX_AdminExecutive when handling 'sys.restart', read by
    // vdrx_daemon.lpr's main after Kernel.WaitFor returns, to decide whether
    // to respawn a fresh instance of the daemon before this process exits.
    property RestartRequested: Boolean read FRestartRequested write FRestartRequested;
  end;

// Topic/filter wildcard matching, scanned in a single pass over both strings
// with no allocation - '*' matches exactly one dot-delimited segment, '>'
// matches the rest of the topic however many segments remain. Used
// internally by TVDRX_Registry's dispatch (once per subscriber per
// dequeued message, so this runs a lot under load) and exported here so any
// other unit that needs the same "does this topic satisfy this filter"
// question (e.g. vdrx_bridge.pas validating a process's declared publish
// patterns) reuses this instead of growing its own copy that could drift.
// Previously split both strings on '.' into dynamic arrays on every call,
// which meant two heap allocations (plus one per segment) per match check;
// this version walks both strings with plain index scanning instead.
function TopicMatches(const Filter, Topic: string): Boolean;

// Escapes a string into a complete, quoted JSON string literal - not just the
// escaping, the surrounding quotes too. Anything writing a hand-built JSON
// line (Bridge's HandlePacket, WSConnection's HandleRPC/HandlePacket) needs
// this, not StringToJSONString, which only escapes and leaves quoting to the
// caller - easy to miss, see the game.cmd.ping malformed-JSON bug this fixed.
function JSONString(const S: string): string;

implementation

function JSONString(const S: string): string;
begin
  Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
  Result := '"' + Result + '"';
end;

function TopicMatches(const Filter, Topic: string): Boolean;
var
  fLen, tLen, fPos, tPos, fEnd, tEnd, segLen: Integer;
begin
  fLen := Length(Filter);
  tLen := Length(Topic);
  fPos := 1;
  tPos := 1;
  while True do
  begin
    fEnd := fPos;
    while (fEnd <= fLen) and (Filter[fEnd] <> '.') do Inc(fEnd);
    segLen := fEnd - fPos;

    if (segLen = 1) and (Filter[fPos] = '>') then
      Exit(True);

    if tPos = 0 then
      Exit(False); // filter has another segment; topic has already run out

    tEnd := tPos;
    while (tEnd <= tLen) and (Topic[tEnd] <> '.') do Inc(tEnd);

    if not ((segLen = 1) and (Filter[fPos] = '*')) then
    begin
      if segLen <> (tEnd - tPos) then Exit(False);
      if (segLen > 0) and not CompareMem(@Filter[fPos], @Topic[tPos], segLen) then
        Exit(False);
    end;

    if fEnd > fLen then
      // this was the filter's last segment - match iff the topic segment
      // just compared was also its last (mirrors the old Length(fParts) =
      // Length(tParts) check at the end of the split-based version)
      Exit(tEnd > tLen);

    fPos := fEnd + 1;
    if tEnd > tLen then
      tPos := 0
    else
      tPos := tEnd + 1;
  end;
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
    Result := FHead < FList.Count;
    if Result then
    begin
      AMsg := FList[FHead];
      Inc(FHead);
      // FList.Delete(0) here used to shift every remaining element down by
      // one on every single dequeue - O(N) per message, so O(N^2) for a
      // backlog draining under load. Advancing FHead instead makes the
      // common case O(1); the consumed prefix [0..FHead) is only actually
      // removed from FList in one shot (DeleteRange, an O(N) memmove) once
      // it's grown large relative to what's left, so that cost is amortized
      // across many dequeues rather than paid on every one.
      if (FHead > 256) and (FHead * 2 >= FList.Count) then
      begin
        FList.DeleteRange(0, FHead);
        FHead := 0;
      end;
      if FHead < FList.Count then
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
  Pair: specialize TPair<string, TVDRX_Executive>;
begin
  FLock.Enter;
  try
    if not FMasterMap.TryGetValue(AID, Exec) then
      Exit;
    RemoveSubscriptionsUnlocked(Exec);
    // ExtractPair (not Remove) while still under FLock: this atomically
    // pulls Exec out of the map and hands exclusive ownership to this call.
    // TObjectDictionary's ExtractPair, unlike Remove, does NOT free the
    // value - ownership transfers to us instead. That closes the race that
    // used to exist here: two threads calling Unregister(AID) concurrently
    // could both TryGetValue the same Exec pointer, both call Exec.Shutdown,
    // and then whichever thread's Remove ran first would free Exec out from
    // under the other thread's still-in-flight Shutdown call (use-after-free).
    // Now only one thread can ever ExtractPair a given AID; a second
    // concurrent call simply finds nothing left to TryGetValue and exits above.
    Pair := FMasterMap.ExtractPair(AID);
    Exec := Pair.Value;
  finally
    FLock.Leave;
  end;
  // Shutdown deliberately runs outside FLock - it can block for a while
  // (joining threads, waiting out a process's graceful-kill window before
  // force-killing it) and must not stall Register/GetSubscribers/Find while
  // it runs. Previously this method skipped Shutdown entirely and just let
  // FMasterMap.Remove's destructor call run - which meant killing/unregistering
  // a Bridge (or any executive holding a thread/child process) never actually
  // stopped what it owned. Small race window here: a concurrent Register(AID,...)
  // could re-add a *different* executive under AID before ExtractPair above runs,
  // which would then be silently dropped - acceptable for now (nothing here is
  // authenticated or under heavy concurrency yet, see vdrx_admincmd.pas).
  Exec.Shutdown;
  Exec.Free; // we exclusively own Exec now (see ExtractPair above), so free it ourselves
end;

function TVDRX_Registry.Find(const AID: string): TVDRX_Executive;
begin
  FLock.Enter;
  try
    if not FMasterMap.TryGetValue(AID, Result) then
      Result := nil;
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

function TVDRX_Registry.Snapshot: TVDRX_ExecList;
begin
  Result := TVDRX_ExecList.Create;
  FLock.Enter;
  try
    Result.AddRange(FMasterMap.Values);
  finally
    FLock.Leave;
  end;
end;

procedure TVDRX_Registry.InitializeAll;
var
  Snap: TVDRX_ExecList;
  Exec: TVDRX_Executive;
begin
  Snap := Snapshot;
  try
    // Deliberately called outside FLock - Initialize can block for a while (binding
    // a socket, spawning a process) and must not stall Register/Unregister/
    // GetSubscribers while it runs.
    for Exec in Snap do
      Exec.Initialize;
  finally
    Snap.Free;
  end;
end;

procedure TVDRX_Registry.ShutdownAll;
var
  Snap: TVDRX_ExecList;
  Exec: TVDRX_Executive;
begin
  Snap := Snapshot;
  try
    for Exec in Snap do
      Exec.Shutdown;
  finally
    Snap.Free;
  end;
end;

procedure TVDRX_Registry.ApplyAllConfigs;
var
  Snap: TVDRX_ExecList;
  Exec: TVDRX_Executive;
begin
  Snap := Snapshot;
  try
    for Exec in Snap do
      Exec.ApplyConfig;
  finally
    Snap.Free;
  end;
end;

procedure TVDRX_Registry.UnregisterSelf(const AID: string);
var
  Exec: TVDRX_Executive;
begin
  FLock.Enter;
  try
    if not FMasterMap.TryGetValue(AID, Exec) then
      Exit;
    RemoveSubscriptionsUnlocked(Exec);
    FMasterMap.Remove(AID); // owning map - frees Exec via its plain destructor, no Shutdown call
  finally
    FLock.Leave;
  end;
end;

{ TVDRX_Kernel }

constructor TVDRX_Kernel.Create;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FRegistry := TVDRX_Registry.Create;
  FQueue := TVDRX_MessageQueue.Create;
  FRestartRequested := False;
end;

destructor TVDRX_Kernel.Destroy;
begin
  // FQueue/FRegistry used to be freed at the bottom of Execute, on the
  // worker thread, right after ShutdownAll. But both are created in Create
  // and exposed to the main thread via the Queue/Registry properties for the
  // whole lifetime of the Kernel object - if the main thread read either
  // property anywhere around WaitFor/termination (or any code holds a
  // reference from earlier), it could dereference an already-freed pointer.
  // Freeing them here instead means they only go away when the TThread
  // object itself is destroyed (i.e. after the main thread has called
  // WaitFor and then frees the Kernel), which is the point nothing should
  // still be touching them.
  FQueue.Free;
  FRegistry.Free;
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
  WriteLn('Dispatcher: Exited loop cleanly.');
end;

procedure TVDRX_Kernel.Terminate;
begin
  inherited Terminate;
  FQueue.Publish('kernel.shutdown', '', '');
end;

end.
