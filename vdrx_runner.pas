unit vdrx_runner;

{$mode ObjFPC}{$H+}

// TVDRX_RunnerExecutive - runs an ordinary command-line program once per bus
// message, and publishes what it printed back onto the bus.
//
//   subscribe  : topics it listens on (default "<id>.in")
//   message    : a JSON object, or plain text (which is then just the body):
//                  { "body":   "text fed to the program's stdin",
//                    "params": { "units": "mm" },          // optional
//                    "query":  "units=mm&flag=1",          // optional (what an HTTP route sends)
//                    "reply_to": "http.reply.17" }         // optional
//   program    : command + args; "%%name%%" placeholders in args are filled
//                from params/query (see ExpandArgs for the rules)
//   reply      : { "status", "content_type", "body", "exit_code", "stderr" }
//                published to the message's reply_to if it has one, otherwise to
//                the runner's own "publish" topic (default "<id>.out")
//
// (EnvelopeMode is the old spawn-per-request "bus" cli_bridges contract: whole
// request envelope in as one JSON line, one JSON reply line out.)
//
// HandlePacket only queues the message; a small pool of worker threads does the
// actual spawning, so a slow program never stalls the bus. If the queue is
// full the message is answered immediately with status 503.
//
// Nothing from a message ever reaches a shell or is split on spaces: the
// program is started with an argument VECTOR, and only placeholders the config
// itself names can be filled.

interface

uses
  Classes, SysUtils, StrUtils, SyncObjs, Process, fpjson, jsonparser, Generics.Collections,
  vdrx_core, vdrx_procutil;

type
  TVDRX_RunnerExecutive = class(TVDRX_Executive)
  private
    FCommandParts: TStringList;  // program + fixed leading args
    FArgTemplates: TStringList;  // appended after the fixed ones; may contain %%name%%
    FStdinFromBody: Boolean;
    FWorkDir: string;
    FTimeoutMs: Integer;
    FWorkers: Integer;
    FMaxQueue: Integer;
    FGraceMs: Integer;
    FContentType: string;
    FPublishTopic: string;
    FExitStatus: TStringList;    // "1=422" pairs
    FLock: TCriticalSection;
    FSignal: TEvent;
    FJobs: TVDRX_MessageList;
    FThreads: array of TThread;
    FStopping: Boolean;
    FEnvelopeMode: Boolean;
    procedure WorkerLoop;
    procedure ProcessEnvelope(const AMsg: TVDRX_Message);
  protected
    // One queued message, on a worker thread. CGI (vdrx_cgi.pas) overrides this.
    procedure Process(const AMsg: TVDRX_Message); virtual;
    procedure Reply(const AReplyTo: string; AStatus: Integer; const AContentType, ABody, AStderr: string; AExitCode: Integer);
    function ExpandArgs(AParams: TStringList; ADest: TStrings; out AError: string): Boolean;
    function ReplyToOf(const APayload: string): string;
    property CommandParts: TStringList read FCommandParts;
    property ArgTemplates: TStringList read FArgTemplates;
  public
    constructor Create(ABus: TVDRX_MessageQueue); override;
    destructor Destroy; override;
    procedure Initialize; override;
    procedure Shutdown; override;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    // Configuration (set before the executive is registered/initialised)
    procedure SetCommand(const ACommandLine: string);
    procedure SetArgs(AArgs: TStrings);
    property StdinFromBody: Boolean read FStdinFromBody write FStdinFromBody;
    // True = the legacy cli_bridges "bus" contract: the program gets the whole
    // request envelope as ONE JSON line on stdin and answers with ONE JSON line
    // on stdout (the first line starting with "{"), which is published verbatim
    // as the reply. False (default) = ordinary CLI program (see header).
    property EnvelopeMode: Boolean read FEnvelopeMode write FEnvelopeMode;
    property WorkDir: string read FWorkDir write FWorkDir;
    property TimeoutMs: Integer read FTimeoutMs write FTimeoutMs;
    property Workers: Integer read FWorkers write FWorkers;
    property MaxQueue: Integer read FMaxQueue write FMaxQueue;
    property GraceMs: Integer read FGraceMs write FGraceMs;
    property ContentType: string read FContentType write FContentType;
    property PublishTopic: string read FPublishTopic write FPublishTopic;
    // "1=422,3=400": program exit code -> HTTP-style status in the reply
    procedure SetExitStatus(const APairs: string);
  end;

implementation

const
  MAX_PARAM_LEN = 1024;

// "a=1&b=two%20words" -> params (later duplicates win)
procedure ParseQuery(const AQuery: string; AParams: TStringList);
var
  Pairs: TStringList;
  i, p: Integer;
  K, V: string;
begin
  if AQuery = '' then Exit;
  Pairs := TStringList.Create;
  try
    Pairs.Delimiter := '&';
    Pairs.StrictDelimiter := True;
    Pairs.DelimitedText := AQuery;
    for i := 0 to Pairs.Count - 1 do
    begin
      p := Pos('=', Pairs[i]);
      if p > 0 then
      begin
        K := URLDecode(Copy(Pairs[i], 1, p - 1));
        V := URLDecode(Copy(Pairs[i], p + 1, MaxInt));
      end
      else
      begin
        K := URLDecode(Pairs[i]);
        V := '';
      end;
      if K <> '' then
      begin
        // TStringList.Values deletes an entry assigned '' - keep a sentinel-free
        // approach: store as "K=V" lines ourselves, replacing any earlier K
        p := AParams.IndexOfName(K);
        if p >= 0 then AParams.Delete(p);
        AParams.Add(K + '=' + V);
      end;
    end;
  finally
    Pairs.Free;
  end;
end;

{ TVDRX_RunnerExecutive }

constructor TVDRX_RunnerExecutive.Create(ABus: TVDRX_MessageQueue);
begin
  inherited Create(ABus);
  FCommandParts := TStringList.Create;
  FArgTemplates := TStringList.Create;
  FExitStatus := TStringList.Create;
  FLock := TCriticalSection.Create;
  FSignal := TEvent.Create(nil, False, False, '');
  FJobs := TVDRX_MessageList.Create;
  FStdinFromBody := True;
  FTimeoutMs := 10000;
  FWorkers := 2;
  FMaxQueue := 64;
  FGraceMs := 5000;
  FContentType := 'text/plain';
end;

destructor TVDRX_RunnerExecutive.Destroy;
begin
  Shutdown;
  FJobs.Free;
  FSignal.Free;
  FLock.Free;
  FExitStatus.Free;
  FArgTemplates.Free;
  FCommandParts.Free;
  inherited;
end;

procedure TVDRX_RunnerExecutive.SetCommand(const ACommandLine: string);
begin
  CommandToList(ACommandLine, FCommandParts);
end;

procedure TVDRX_RunnerExecutive.SetArgs(AArgs: TStrings);
begin
  FArgTemplates.Assign(AArgs);
end;

procedure TVDRX_RunnerExecutive.SetExitStatus(const APairs: string);
begin
  FExitStatus.CommaText := APairs;
end;

procedure TVDRX_RunnerExecutive.Initialize;
var
  i: Integer;
begin
  if Length(FThreads) > 0 then Exit;
  if FWorkers < 1 then FWorkers := 1;
  SetLength(FThreads, FWorkers);
  for i := 0 to FWorkers - 1 do
  begin
    FThreads[i] := TVDRX_WorkerThread.Create(@WorkerLoop);
    FThreads[i].Start;
  end;
end;

procedure TVDRX_RunnerExecutive.Shutdown;
var
  i: Integer;
begin
  FLock.Enter;
  try
    if FStopping then Exit;
    FStopping := True;
  finally
    FLock.Leave;
  end;
  for i := 0 to High(FThreads) do FSignal.SetEvent;
  for i := 0 to High(FThreads) do
  begin
    if not WaitThreadOrTimeout(FThreads[i], FGraceMs) then
      Bus.Publish('log.warn', 'runner ' + ID + ': worker thread did not exit in time - abandoning it', ID)
    else
      FThreads[i].Free;
    FThreads[i] := nil;
  end;
  SetLength(FThreads, 0);
end;

// Cheap and non-blocking by design: queue the message and return. (Parsing a
// multi-megabyte request here would hold up the whole bus.) Only when the
// queue is full do we parse, just far enough to answer 503 to the sender.
procedure TVDRX_RunnerExecutive.HandlePacket(const AMsg: TVDRX_Message);
var
  Queued: Boolean;
begin
  Queued := False;
  FLock.Enter;
  try
    if (not FStopping) and (FJobs.Count < FMaxQueue) then
    begin
      FJobs.Add(AMsg);
      Queued := True;
    end;
  finally
    FLock.Leave;
  end;
  if Queued then
    FSignal.SetEvent
  else
  begin
    Bus.Publish('log.warn', 'runner ' + ID + ': queue full (' + IntToStr(FMaxQueue) + ') - rejecting a request with 503', ID);
    Reply(ReplyToOf(AMsg.Payload), 503, 'text/plain', 'Runner busy - try again shortly', '', -1);
  end;
end;

function TVDRX_RunnerExecutive.ReplyToOf(const APayload: string): string;
var
  J: TJSONData;
begin
  Result := FPublishTopic;
  try
    J := GetJSON(APayload);
    try
      if J is TJSONObject then
        if TJSONObject(J).Get('reply_to', '') <> '' then
          Result := TJSONObject(J).Get('reply_to', '');
    finally
      J.Free;
    end;
  except
    // not JSON - nobody asked for a reply, so the default topic it is
  end;
end;

procedure TVDRX_RunnerExecutive.WorkerLoop;
var
  Msg: TVDRX_Message;
  Have, Stopping: Boolean;
begin
  repeat
    Have := False;
    FLock.Enter;
    try
      Stopping := FStopping;
      if FJobs.Count > 0 then
      begin
        Msg := FJobs[0];
        FJobs.Delete(0);
        Have := True;
      end;
    finally
      FLock.Leave;
    end;
    if Have then
    begin
      try
        Process(Msg);
      except
        on E: Exception do
        begin
          Bus.Publish('log.error', 'runner ' + ID + ': unexpected error: ' + E.ClassName + ': ' + E.Message, ID);
          try
            Reply(ReplyToOf(Msg.Payload), 500, 'text/plain', 'Runner internal error', '', -1);
          except
          end;
        end;
      end;
      FLock.Enter;
      try
        if FJobs.Count > 0 then FSignal.SetEvent; // pass the baton to a sibling worker
      finally
        FLock.Leave;
      end;
    end
    else if not Stopping then
      FSignal.WaitFor(500);
  until Stopping and not Have;
end;

// Builds the argument list: the config's templates with %%name%% placeholders
// filled from AParams.
//   %%name%%    required - a missing parameter is an error (-> 400)
//   %%name?%%   optional - a token containing a missing one is dropped entirely
//               (write flag-with-value as ONE token, "--units=%%units?%%")
// Values are checked: no control characters, at most MAX_PARAM_LEN long, and a
// token that is nothing but one placeholder may not start with "-" (so a caller
// can't smuggle in an option flag where a plain value belongs).
function TVDRX_RunnerExecutive.ExpandArgs(AParams: TStringList; ADest: TStrings;
  out AError: string): Boolean;
var
  t, i, p, q: Integer;
  Token, Out_, Name, Value: string;
  Optional, Drop, WholeToken: Boolean;
  Idx: Integer;
begin
  Result := False;
  AError := '';
  ADest.Clear;
  for t := 0 to FArgTemplates.Count - 1 do
  begin
    Token := FArgTemplates[t];
    Out_ := '';
    Drop := False;
    i := 1;
    while i <= Length(Token) do
    begin
      if (Token[i] = '%') and (i < Length(Token)) and (Token[i + 1] = '%') then
      begin
        q := Pos('%%', Copy(Token, i + 2, MaxInt));
        if q > 0 then
        begin
          Name := Copy(Token, i + 2, q - 1);
          Optional := (Name <> '') and (Name[Length(Name)] = '?');
          if Optional then Delete(Name, Length(Name), 1);
          WholeToken := (i = 1) and (i + 2 + q + 1 = Length(Token) + 1);
          Idx := AParams.IndexOfName(Name);
          if Idx < 0 then
          begin
            if Optional then
              Drop := True
            else
            begin
              AError := 'missing parameter "' + Name + '"';
              Exit;
            end;
          end
          else
          begin
            Value := AParams.ValueFromIndex[Idx];
            if Length(Value) > MAX_PARAM_LEN then
            begin
              AError := 'parameter "' + Name + '" is too long';
              Exit;
            end;
            for p := 1 to Length(Value) do
              if Value[p] < ' ' then
              begin
                AError := 'parameter "' + Name + '" contains control characters';
                Exit;
              end;
            if WholeToken and (Value <> '') and (Value[1] = '-') then
            begin
              AError := 'parameter "' + Name + '" may not start with "-"';
              Exit;
            end;
            Out_ := Out_ + Value;
          end;
          Inc(i, q + 3);
          Continue;
        end;
      end;
      Out_ := Out_ + Token[i];
      Inc(i);
    end;
    if not Drop then ADest.Add(Out_);
  end;
  Result := True;
end;

procedure TVDRX_RunnerExecutive.Reply(const AReplyTo: string; AStatus: Integer;
  const AContentType, ABody, AStderr: string; AExitCode: Integer);
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('status', AStatus);
    O.Add('content_type', AContentType);
    O.Add('body', CleanUTF8(ABody));
    if AExitCode >= 0 then O.Add('exit_code', AExitCode);
    if AStderr <> '' then O.Add('stderr', CleanUTF8(AStderr));
    Bus.Publish(AReplyTo, O.AsJSON, ID);
  finally
    O.Free;
  end;
end;

procedure TVDRX_RunnerExecutive.Process(const AMsg: TVDRX_Message);
var
  J: TJSONData;
  Req, ParamsObj: TJSONObject;
  Body, ReplyTo, Query, ErrText, SO, SE, Exe, Trimmed: string;
  Params: TStringList;
  Args: TStringList;
  i, Code, Status, p: Integer;
  RR: TVDRX_RunResult;
  Stdin: string;
begin
  if FEnvelopeMode then
  begin
    ProcessEnvelope(AMsg);
    Exit;
  end;
  Body := AMsg.Payload;
  ReplyTo := FPublishTopic;
  Query := '';
  Params := TStringList.Create;
  Args := TStringList.Create;
  try
    // plain text -> body only; a JSON object -> body/params/query/reply_to
    J := nil;
    try
      J := GetJSON(AMsg.Payload);
    except
      J := nil;
    end;
    try
      if Assigned(J) and (J is TJSONObject) then
      begin
        Req := TJSONObject(J);
        Body := Req.Get('body', '');
        Query := Req.Get('query', '');
        if Req.Get('reply_to', '') <> '' then ReplyTo := Req.Get('reply_to', '');
        ParseQuery(Query, Params);
        if Req.Find('params') is TJSONObject then
        begin
          ParamsObj := TJSONObject(Req.Find('params'));
          for i := 0 to ParamsObj.Count - 1 do
          begin
            p := Params.IndexOfName(ParamsObj.Names[i]);
            if p >= 0 then Params.Delete(p);
            Params.Add(ParamsObj.Names[i] + '=' + ParamsObj.Items[i].AsString);
          end;
        end;
      end;
    finally
      J.Free;
    end;

    if not ExpandArgs(Params, Args, ErrText) then
    begin
      Reply(ReplyTo, 400, 'text/plain', 'Bad request: ' + ErrText, '', -1);
      Exit;
    end;

    if FCommandParts.Count = 0 then
    begin
      Reply(ReplyTo, 500, 'text/plain', 'Runner has no command configured', '', -1);
      Exit;
    end;
    Exe := FCommandParts[0];
    // fixed leading args from the command string, then the expanded templates
    for i := FCommandParts.Count - 1 downto 1 do
      Args.Insert(0, FCommandParts[i]);

    if FStdinFromBody then Stdin := Body else Stdin := '';
    RR := RunProgramCaptureArgs(Exe, Args, FWorkDir, Stdin, FTimeoutMs, Code, SO, SE, ErrText);
    case RR of
      rrStartFailed:
        begin
          Bus.Publish('log.warn', 'runner ' + ID + ': could not start "' + Exe + '": ' + ErrText, ID);
          Reply(ReplyTo, 502, 'text/plain', 'Could not start program', '', -1);
          Exit;
        end;
      rrTimedOut:
        begin
          Bus.Publish('log.warn', 'runner ' + ID + ': "' + Exe + '" exceeded ' + IntToStr(FTimeoutMs) + 'ms and was killed', ID);
          Reply(ReplyTo, 504, 'text/plain', 'Program timed out', '', -1);
          Exit;
        end;
    end;

    if Code = 0 then
    begin
      Reply(ReplyTo, 200, FContentType, SO, Trim(SE), 0);
      Exit;
    end;

    Trimmed := Trim(SE);
    if Trimmed = '' then Trimmed := Trim(SO);
    if Trimmed = '' then Trimmed := 'Program exited with code ' + IntToStr(Code);
    Status := 500;
    p := FExitStatus.IndexOfName(IntToStr(Code));
    if p >= 0 then Status := StrToIntDef(FExitStatus.ValueFromIndex[p], 500);
    Bus.Publish('log.warn', 'runner ' + ID + ': "' + Exe + '" exit ' + IntToStr(Code) + ' -> ' + IntToStr(Status) + ': ' + Copy(Trimmed, 1, 200), ID);
    Reply(ReplyTo, Status, 'text/plain', Trimmed, '', Code);
  finally
    Args.Free;
    Params.Free;
  end;
end;

procedure TVDRX_RunnerExecutive.ProcessEnvelope(const AMsg: TVDRX_Message);
var
  ReplyTo, Exe, SO, SE, ErrText, Line: string;
  Args, Lines: TStringList;
  Code, i: Integer;
  RR: TVDRX_RunResult;
begin
  ReplyTo := ReplyToOf(AMsg.Payload);
  if FCommandParts.Count = 0 then
  begin
    Reply(ReplyTo, 500, 'text/plain', 'Runner has no command configured', '', -1);
    Exit;
  end;
  Exe := FCommandParts[0];
  Args := TStringList.Create;
  Lines := TStringList.Create;
  try
    for i := 1 to FCommandParts.Count - 1 do Args.Add(FCommandParts[i]);
    RR := RunProgramCaptureArgs(Exe, Args, FWorkDir, AMsg.Payload + LineEnding, FTimeoutMs, Code, SO, SE, ErrText);
    case RR of
      rrStartFailed:
        begin
          Bus.Publish('log.error', 'runner ' + ID + ': failed to start "' + Exe + '": ' + ErrText, ID);
          Reply(ReplyTo, 502, 'text/plain', 'Could not start script', '', -1);
          Exit;
        end;
      rrTimedOut:
        begin
          Bus.Publish('log.error', 'runner ' + ID + ': "' + Exe + '" exceeded ' + IntToStr(FTimeoutMs) + 'ms, killed it', ID);
          Reply(ReplyTo, 504, 'text/plain', 'Script timed out', '', -1);
          Exit;
        end;
    end;
    // a UTF-8 BOM (Windows scripts) and stray notices/warnings ahead of the
    // reply must not corrupt it: take the first line that looks like JSON
    if (Length(SO) >= 3) and (SO[1] = #$EF) and (SO[2] = #$BB) and (SO[3] = #$BF) then Delete(SO, 1, 3);
    Lines.Text := SO;
    Line := '';
    for i := 0 to Lines.Count - 1 do
      if Copy(TrimLeft(Lines[i]), 1, 1) = '{' then
      begin
        Line := Trim(Lines[i]);
        Break;
      end;
    if Line = '' then
    begin
      Bus.Publish('log.warn', 'runner ' + ID + ': "' + Exe + '" produced no JSON reply line - stdout: ' + Copy(SO, 1, 300) +
        IfThen(Trim(SE) <> '', ' stderr: ' + Copy(Trim(SE), 1, 300), ''), ID);
      Reply(ReplyTo, 502, 'text/plain', IfThen(Trim(SO) = '', 'Empty response from script', 'Malformed response from script'), '', -1);
      Exit;
    end;
    Bus.Publish(ReplyTo, Line, ID);
  finally
    Lines.Free;
    Args.Free;
  end;
end;

end.
