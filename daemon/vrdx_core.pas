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
  TVRDX_ExecDictionary = specialize TObjectDictionary<string, TVRDX_ExecList>;
  TVRDX_MessageList = specialize TList<TVRDX_Message>;

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

  TVRDX_Executive = class
  private
    FFilter: string;
  public
    property Filter: string read FFilter write FFilter;
    procedure HandlePacket(const AMsg: TVRDX_Message); virtual; abstract;
  end;

  TVRDX_Registry = class
  private
    FLiteralSubs: TVRDX_ExecDictionary;
    FWildcardSubs: TVRDX_ExecList;
    FLock: TCriticalSection;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Register(AExec: TVRDX_Executive; const ATopicFilter: string);
    function GetSubscribers(const ATopic: string): TVRDX_ExecList;
  end;

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
  end;

implementation

var
  GConsoleLock: TCriticalSection;

procedure LogLine(const S: string);
begin
  GConsoleLock.Enter;
  try
    WriteLn(S);
  finally
    GConsoleLock.Leave;
  end;
end;

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
  LogLine(Format('Queue: Publishing %s (seq=%d)', [ATopic, Msg.Seq]));
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

{ TVRDX_Registry }

constructor TVRDX_Registry.Create;
begin
  FLock := TCriticalSection.Create;
  FLiteralSubs := TVRDX_ExecDictionary.Create([doOwnsValues]);
  FWildcardSubs := TVRDX_ExecList.Create;
end;

destructor TVRDX_Registry.Destroy;
begin
  FWildcardSubs.Free;
  FLiteralSubs.Free;
  FLock.Free;
  inherited;
end;

procedure TVRDX_Registry.Register(AExec: TVRDX_Executive; const ATopicFilter: string);
var
  List: TVRDX_ExecList;
begin
  FLock.Enter;
  try
    if (Pos('*', ATopicFilter) > 0) or (Pos('>', ATopicFilter) > 0) then
      FWildcardSubs.Add(AExec)
    else
    begin
      if not FLiteralSubs.TryGetValue(ATopicFilter, List) then
      begin
        List := TVRDX_ExecList.Create;
        FLiteralSubs.Add(ATopicFilter, List);
      end;
      List.Add(AExec);
    end;
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
    begin
      if TopicMatches(Exec.Filter, ATopic) then
        Result.Add(Exec);
    end;
  finally
    FLock.Leave;
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
  while not Terminated do
  begin
    if FQueue.TryDequeue(Msg, Infinite) then
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
  FQueue.Free;
  FRegistry.Free;
  WriteLn('Dispatcher: Exited loop cleanly.');
end;

procedure TVRDX_Kernel.Terminate;
begin
  inherited Terminate;
  FQueue.Publish('kernel.shutdown', '', '');
end;

initialization
  GConsoleLock := TCriticalSection.Create;

finalization
  GConsoleLock.Free;

end.
