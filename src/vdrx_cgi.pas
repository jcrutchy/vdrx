unit vdrx_cgi;

{$mode ObjFPC}{$H+}

// TVDRX_CGIExecutive - the CGI adaptor. It is an ordinary bus executive: it
// subscribes to a topic, and for every HTTP request envelope that arrives it
// runs a CGI program the way a web server would (RFC 3875), then publishes the
// program's response back onto the bus as a reply envelope.
//
//   php-cgi, python, perl, a compiled .cgi / .exe ... are just consumers: they
//   neither know nor care that a message bus sits between them and the browser.
//
// Request envelope (what the HTTP edge publishes; see vdrx_network.pas):
//   { "method", "path", "query", "headers": {..}, "body" | "body_b64",
//     "protocol", "remote_addr", "remote_port", "server_name", "server_port",
//     "https", "request_uri",
//     "script_name", "script_filename", "path_info", "doc_root",   // resolved by the route
//     "reply_to" }
//
// Reply envelope (what the edge turns back into an HTTP response):
//   { "status": 200, "content_type": "text/html",
//     "headers": { "Set-Cookie": ["a=1", "b=2"], "X-Foo": "bar" },
//     "body" | "body_b64" }
//
// Process model: inherited from TVDRX_RunnerExecutive - HandlePacket only
// queues, a small pool of worker threads spawns the programs, a full queue is
// answered 503, a program over timeout_ms is killed and answered 504.
//
// The program is started with an argument VECTOR (never a shell):
//   command + args   e.g. command "php-cgi", args ["%%script%%"]  ->  php-cgi /www/index.php
//   command ""       the script file itself is the executable (classic cgi-bin)
// "%%script%%" is replaced by the absolute script filename.

interface

uses
  Classes, SysUtils, StrUtils, fpjson, jsonparser, base64,
  vdrx_core, vdrx_procutil, vdrx_runner;

const
  VDRX_SERVER_SOFTWARE = 'VDRX/1.0';

type
  TVDRX_CGIExecutive = class(TVDRX_RunnerExecutive)
  private
    FRawOutput: Boolean;
    FExtraEnv: TStringList;
    procedure ReplyEnvelope(const AReplyTo: string; AStatus: Integer;
      const AContentType: string; AHeaders: TStringList; const ABody: string);
  protected
    procedure Process(const AMsg: TVDRX_Message); override;
  public
    constructor Create(ABus: TVDRX_MessageQueue); override;
    destructor Destroy; override;
    // "NAME=value" lines added to every program's environment (config "env").
    procedure SetExtraEnv(AEnv: TStrings);
    // False (default): the program speaks CGI (header block, blank line, body).
    // True: stdout is the body verbatim, status 200, the configured content_type
    // - for simple legacy scripts that just print a page.
    property RawOutput: Boolean read FRawOutput write FRawOutput;
  end;

// Exposed (and unit-testable) building blocks -------------------------------

// RFC 3875 meta-variables (+ the de-facto ones PHP and friends expect) from a
// request envelope. ABody is the DECODED request body (CONTENT_LENGTH is its
// byte length).
procedure BuildCGIEnv(AReq: TJSONObject; const ABody: string; AEnv: TStrings);

// Splits CGI program output into status, headers and body (RFC 3875 section 6).
// AHeaders gets "Name=value" lines in order, duplicates preserved (Set-Cookie);
// Status and Content-Type are consumed into AStatus / AContentType. Returns
// False if the output has no CGI header block at all.
function ParseCGIOutput(const AOutput: string; out AStatus: Integer;
  out AContentType: string; AHeaders: TStrings; out ABody: string): Boolean;

implementation

{ ---- request side ---------------------------------------------------------- }

function JStr(AObj: TJSONObject; const AName, ADefault: string): string;
var
  D: TJSONData;
begin
  Result := ADefault;
  D := AObj.Find(AName);
  if Assigned(D) and (D.JSONType in [jtString, jtNumber, jtBoolean]) then
    Result := D.AsString;
end;

function NoCRLF(const S: string): string;
var
  i: Integer;
begin
  Result := S;
  for i := 1 to Length(Result) do
    if Result[i] in [#0, #10, #13] then Result[i] := ' ';
end;

procedure BuildCGIEnv(AReq: TJSONObject; const ABody: string; AEnv: TStrings);
var
  Headers: TJSONObject;
  i, j: Integer;
  Name, Up, PathInfo, DocRoot: string;
  Https: Boolean;
  D: TJSONData;
begin
  AEnv.Clear;
  PathInfo := JStr(AReq, 'path_info', '');
  DocRoot := JStr(AReq, 'doc_root', '');
  D := AReq.Find('https');
  Https := Assigned(D) and (D.JSONType = jtBoolean) and D.AsBoolean;

  AEnv.Add('GATEWAY_INTERFACE=CGI/1.1');
  AEnv.Add('SERVER_SOFTWARE=' + VDRX_SERVER_SOFTWARE);
  AEnv.Add('SERVER_PROTOCOL=' + NoCRLF(JStr(AReq, 'protocol', 'HTTP/1.1')));
  AEnv.Add('SERVER_NAME=' + NoCRLF(JStr(AReq, 'server_name', 'localhost')));
  AEnv.Add('SERVER_PORT=' + JStr(AReq, 'server_port', '80'));
  AEnv.Add('REQUEST_METHOD=' + NoCRLF(JStr(AReq, 'method', 'GET')));
  AEnv.Add('REQUEST_URI=' + NoCRLF(JStr(AReq, 'request_uri', JStr(AReq, 'path', '/'))));
  AEnv.Add('SCRIPT_NAME=' + NoCRLF(JStr(AReq, 'script_name', '')));
  AEnv.Add('SCRIPT_FILENAME=' + NoCRLF(JStr(AReq, 'script_filename', '')));
  AEnv.Add('DOCUMENT_ROOT=' + NoCRLF(DocRoot));
  AEnv.Add('PATH_INFO=' + NoCRLF(PathInfo));
  if (PathInfo <> '') and (DocRoot <> '') then
    AEnv.Add('PATH_TRANSLATED=' + NoCRLF(ExcludeTrailingPathDelimiter(DocRoot) + PathInfo))
  else
    AEnv.Add('PATH_TRANSLATED=');
  AEnv.Add('QUERY_STRING=' + NoCRLF(JStr(AReq, 'query', '')));
  AEnv.Add('REMOTE_ADDR=' + NoCRLF(JStr(AReq, 'remote_addr', '')));
  AEnv.Add('REMOTE_HOST=' + NoCRLF(JStr(AReq, 'remote_addr', '')));
  AEnv.Add('REMOTE_PORT=' + JStr(AReq, 'remote_port', ''));
  // php-cgi built with cgi.force_redirect refuses to run unless this is set
  AEnv.Add('REDIRECT_STATUS=200');
  if Https then AEnv.Add('HTTPS=on');

  if ABody <> '' then
    AEnv.Add('CONTENT_LENGTH=' + IntToStr(Length(ABody)))
  else
    AEnv.Add('CONTENT_LENGTH=');
  AEnv.Add('CONTENT_TYPE=');   // overwritten below if the client sent one

  // Every request header becomes HTTP_<NAME>, except the two that have their own
  // meta-variables - and "Proxy", which must never become HTTP_PROXY (httpoxy).
  D := AReq.Find('headers');
  if Assigned(D) and (D is TJSONObject) then
  begin
    Headers := TJSONObject(D);
    for i := 0 to Headers.Count - 1 do
    begin
      Name := Headers.Names[i];
      if not (Headers.Items[i].JSONType in [jtString, jtNumber, jtBoolean]) then Continue;
      if SameText(Name, 'Content-Type') then
      begin
        AEnv.Values['CONTENT_TYPE'] := NoCRLF(Headers.Items[i].AsString);
        Continue;
      end;
      if SameText(Name, 'Content-Length') or SameText(Name, 'Proxy') then Continue;
      Up := '';
      for j := 1 to Length(Name) do
        case Name[j] of
          'a'..'z': Up := Up + UpCase(Name[j]);
          'A'..'Z', '0'..'9', '_': Up := Up + Name[j];
          '-': Up := Up + '_';
        end;
      if Up <> '' then
        AEnv.Add('HTTP_' + Up + '=' + NoCRLF(Headers.Items[i].AsString));
    end;
  end;
end;

{ ---- response side --------------------------------------------------------- }

function ParseCGIOutput(const AOutput: string; out AStatus: Integer;
  out AContentType: string; AHeaders: TStrings; out ABody: string): Boolean;
var
  Pos_, Len, LineEnd, Colon, i, Code: Integer;
  Line, Name, Value, LName: string;
  Seen: Integer;
  HaveLocation, HaveStatus: Boolean;
  Out_: string;

  function ValidName(const N: string): Boolean;
  var
    k: Integer;
  begin
    Result := N <> '';
    for k := 1 to Length(N) do
      if not (N[k] in ['A'..'Z', 'a'..'z', '0'..'9', '-', '_']) then Exit(False);
  end;

begin
  Result := False;
  AStatus := 200;
  AContentType := '';
  ABody := '';
  AHeaders.Clear;
  Out_ := AOutput;
  if (Length(Out_) >= 3) and (Out_[1] = #$EF) and (Out_[2] = #$BB) and (Out_[3] = #$BF) then
    Delete(Out_, 1, 3);
  Len := Length(Out_);
  Pos_ := 1;
  Seen := 0;
  HaveLocation := False;
  HaveStatus := False;
  while Pos_ <= Len do
  begin
    LineEnd := PosEx(#10, Out_, Pos_);
    if LineEnd = 0 then
    begin
      Line := Copy(Out_, Pos_, MaxInt);
      Pos_ := Len + 1;
    end
    else
    begin
      Line := Copy(Out_, Pos_, LineEnd - Pos_);
      Pos_ := LineEnd + 1;
    end;
    if (Line <> '') and (Line[Length(Line)] = #13) then SetLength(Line, Length(Line) - 1);

    if Line = '' then
    begin
      // blank line: end of the header block
      if Seen = 0 then Exit(False);
      ABody := Copy(Out_, Pos_, MaxInt);
      Result := True;
      Break;
    end;

    Colon := Pos(':', Line);
    Name := '';
    if Colon > 1 then Name := Copy(Line, 1, Colon - 1);
    if not ValidName(Name) then Exit(False);   // not a header block at all
    Value := Trim(Copy(Line, Colon + 1, MaxInt));
    Inc(Seen);
    LName := LowerCase(Name);
    if LName = 'status' then
    begin
      Code := 0;
      i := 1;
      while (i <= Length(Value)) and (Value[i] in ['0'..'9']) do
      begin
        Code := Code * 10 + Ord(Value[i]) - 48;
        Inc(i);
      end;
      if (Code >= 100) and (Code <= 599) then AStatus := Code;
      HaveStatus := True;
    end
    else if LName = 'content-type' then
      AContentType := Value
    else
    begin
      if LName = 'location' then HaveLocation := True;
      AHeaders.Add(Name + '=' + Value);
    end;
  end;

  // ran out of data without a blank line: headers only, empty body
  if (not Result) and (Seen > 0) then Result := True;

  // RFC 3875 6.2.3 / 6.2.4: a Location without a Status is a redirect
  if Result and HaveLocation and (not HaveStatus) then AStatus := 302;
end;

{ ---- TVDRX_CGIExecutive ---------------------------------------------------- }

constructor TVDRX_CGIExecutive.Create(ABus: TVDRX_MessageQueue);
begin
  inherited Create(ABus);
  FExtraEnv := TStringList.Create;
  ContentType := 'text/html';
  TimeoutMs := 30000;
  Workers := 4;
end;

destructor TVDRX_CGIExecutive.Destroy;
begin
  FExtraEnv.Free;
  inherited;
end;

procedure TVDRX_CGIExecutive.SetExtraEnv(AEnv: TStrings);
begin
  FExtraEnv.Assign(AEnv);
end;

// Headers is a list of "Name=value" lines; same-named headers become a JSON
// array (so several Set-Cookie lines survive the trip over the bus).
procedure TVDRX_CGIExecutive.ReplyEnvelope(const AReplyTo: string; AStatus: Integer;
  const AContentType: string; AHeaders: TStringList; const ABody: string);
var
  O, H: TJSONObject;
  Arr: TJSONArray;
  D: TJSONData;
  i, p: Integer;
  Name, Value: string;
begin
  O := TJSONObject.Create;
  try
    O.Add('status', AStatus);
    if AContentType <> '' then O.Add('content_type', AContentType);
    H := TJSONObject.Create;
    if Assigned(AHeaders) then
      for i := 0 to AHeaders.Count - 1 do
      begin
        p := Pos('=', AHeaders[i]);
        if p < 2 then Continue;
        Name := Copy(AHeaders[i], 1, p - 1);
        Value := CleanUTF8(Copy(AHeaders[i], p + 1, MaxInt));
        D := H.Find(Name);
        if D = nil then
          H.Add(Name, Value)
        else if D is TJSONArray then
          TJSONArray(D).Add(Value)
        else
        begin
          Arr := TJSONArray.Create;
          Arr.Add(D.AsString);
          Arr.Add(Value);
          H.Delete(H.IndexOfName(Name));
          H.Add(Name, Arr);
        end;
      end;
    O.Add('headers', H);
    if IsValidUTF8(ABody) then
      O.Add('body', ABody)
    else
      O.Add('body_b64', EncodeStringBase64(ABody));
    Bus.Publish(AReplyTo, O.AsJSON, ID);
  finally
    O.Free;
  end;
end;

procedure TVDRX_CGIExecutive.Process(const AMsg: TVDRX_Message);
var
  J: TJSONData;
  Req: TJSONObject;
  ReplyTo, Body, ScriptFile, Exe, SO, SE, ErrText, CT, ScriptDirectory: string;
  Env, Args, Params, Hdrs: TStringList;
  Code, Status, i: Integer;
  RR: TVDRX_RunResult;
  Bad: Boolean;
begin
  ReplyTo := ReplyToOf(AMsg.Payload);
  J := nil;
  try
    J := GetJSON(AMsg.Payload);
  except
    J := nil;
  end;
  if not (Assigned(J) and (J is TJSONObject)) then
  begin
    J.Free;
    Reply(ReplyTo, 400, 'text/plain', 'CGI request must be a JSON envelope', '', -1);
    Exit;
  end;
  Req := TJSONObject(J);

  if not EdgeTokenOK(Req) then
  begin
    J.Free;
    Bus.Publish('log.warn', 'cgi ' + ID + ': rejected a request with a missing/wrong _edge_token (not from the HTTP edge) - refusing to run ' +
      Req.Get('script_filename', '(no script_filename given)'), ID);
    Reply(ReplyTo, 403, 'text/plain', 'Forbidden', '', -1);
    Exit;
  end;

  Env := TStringList.Create;
  Args := TStringList.Create;
  Params := TStringList.Create;
  Hdrs := TStringList.Create;
  try
    // body: plain text, or base64 for anything that is not valid UTF-8
    if Req.Find('body_b64') is TJSONString then
    begin
      try
        Body := DecodeStringBase64(Req.Get('body_b64', ''));
      except
        Reply(ReplyTo, 400, 'text/plain', 'Bad body_b64', '', -1);
        Exit;
      end;
    end
    else
      Body := Req.Get('body', '');

    ScriptFile := Req.Get('script_filename', '');
    if ScriptFile = '' then
    begin
      Bus.Publish('log.warn', 'cgi ' + ID + ': request has no script_filename (is this executive reached through a "cgi" route?)', ID);
      Reply(ReplyTo, 500, 'text/plain', 'CGI executive got a request with no script_filename', '', -1);
      Exit;
    end;

    BuildCGIEnv(Req, Body, Env);
    for i := 0 to FExtraEnv.Count - 1 do
    begin
      if Pos('=', FExtraEnv[i]) < 2 then Continue;
      Env.Values[Copy(FExtraEnv[i], 1, Pos('=', FExtraEnv[i]) - 1)] := Copy(FExtraEnv[i], Pos('=', FExtraEnv[i]) + 1, MaxInt);
    end;

    // program + arguments
    if CommandParts.Count = 0 then
    begin
      Exe := ScriptFile;           // classic cgi-bin: the script is the program
    end
    else
    begin
      Exe := CommandParts[0];
      Params.Add('script=' + ScriptFile);
      if ArgTemplates.Count = 0 then
      begin
        Args.Add(ScriptFile);
        Bad := False;
      end
      else
        Bad := not ExpandArgs(Params, Args, ErrText);
      if Bad then
      begin
        Reply(ReplyTo, 500, 'text/plain', 'Bad CGI args config: ' + ErrText, '', -1);
        Exit;
      end;
      for i := CommandParts.Count - 1 downto 1 do
        Args.Insert(0, CommandParts[i]);
    end;

    // CGI convention (Apache, nginx+fcgiwrap): run in the script's directory
    ScriptDirectory := WorkDir;
    if ScriptDirectory = '' then ScriptDirectory := ExtractFilePath(ScriptFile);

    RR := RunProgramCaptureArgs(Exe, Args, ScriptDirectory, Body, TimeoutMs, Code, SO, SE, ErrText, Env);
    case RR of
      rrStartFailed:
        begin
          Bus.Publish('log.error', 'cgi ' + ID + ': could not start "' + Exe + '": ' + ErrText, ID);
          Reply(ReplyTo, 502, 'text/plain', 'Could not start CGI program', '', -1);
          Exit;
        end;
      rrTimedOut:
        begin
          Bus.Publish('log.error', 'cgi ' + ID + ': ' + ScriptFile + ' exceeded ' + IntToStr(TimeoutMs) + 'ms, killed it', ID);
          Reply(ReplyTo, 504, 'text/plain', 'CGI program timed out', '', -1);
          Exit;
        end;
    end;
    if Trim(SE) <> '' then
      Bus.Publish('log.warn', 'cgi ' + ID + ': ' + ScriptFile + ' wrote to stderr: ' + Copy(Trim(SE), 1, 500), ID);

    if FRawOutput then
    begin
      if Code <> 0 then
        Reply(ReplyTo, 500, 'text/plain', 'CGI program exited with code ' + IntToStr(Code), '', Code)
      else
        ReplyEnvelope(ReplyTo, 200, ContentType, nil, SO);
      Exit;
    end;

    if not ParseCGIOutput(SO, Status, CT, Hdrs, Body) then
    begin
      Bus.Publish('log.warn', Format('cgi %s: %s (exit %d) produced no valid CGI header block - stdout starts: %s',
        [ID, ScriptFile, Code, Copy(SO, 1, 200)]), ID);
      if Trim(SO) = '' then
        Reply(ReplyTo, 502, 'text/plain', 'CGI program produced no output (exit code ' + IntToStr(Code) + ')', '', Code)
      else
        Reply(ReplyTo, 502, 'text/plain', 'Malformed CGI response (missing header block)', '', Code);
      Exit;
    end;
    if (CT = '') and (Status < 300) then CT := ContentType;
    Bus.Publish('log.info', Format('cgi %s: %s -> %d (%d bytes)', [ID, ScriptFile, Status, Length(Body)]), ID);
    ReplyEnvelope(ReplyTo, Status, CT, Hdrs, Body);
  finally
    Hdrs.Free;
    Params.Free;
    Args.Free;
    Env.Free;
    Req.Free;
  end;
end;

end.
