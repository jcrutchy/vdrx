unit vdrx_httpparse;

{$mode ObjFPC}{$H+}

// HTTP request parsing and path safety (request line, headers, URL paths), route/rewrite records and 
// matching, static-file policy, and the HTTP timeouts. No daemon state beyond configuration; the main 
// target for fuzzing and review.

interface

uses
  Classes, SysUtils, StrUtils, {$IFDEF UNIX}BaseUnix, {$ENDIF} dynlibs, fpjson, RegExpr, vdrx_core, vdrx_procutil, vdrx_transport;

type

  TVDRX_ProxyRoute = record
    Prefix: string;
    Host: string;
    Port: Word;
  end;

  TVDRX_ProxyRoutes = array of TVDRX_ProxyRoute;

  // One HTTP route onto the bus: requests under Prefix are published as a JSON
  // envelope to InTopic and the reply that comes back becomes the HTTP response.
  // Kind 'bus'  : publish straight away (http_routes; legacy bus-daemon routes).
  // Kind 'cgi'  : first map the URL onto a script under DocRoot (index files,
  //               PATH_INFO, front-controller Fallback, static files), then publish
  //               with script_name/script_filename/path_info filled in (cgi entries).
  TVDRX_BusRoute = record
    ID: string;
    Kind: string;
    Prefix: string;
    InTopic: string;
    Allow: string;        // comma-separated HTTP methods accepted; '' = any
    TimeoutMs: Integer;
    ContentType: string;  // default for a reply that doesn't say
    Response: string;     // 'raw' (default): use the reply's status/headers/body; 'json': hand back the whole envelope as application/json
    // kind 'cgi' only
    DocRoot: string;
    Extensions: string;   // lower-case, wrapped in commas (',.php,.cgi,'); '' = every file is a script
    IndexFiles: string;   // comma-separated, tried in order for a directory URL
    Fallback: string;     // URL path (under Prefix) of a front-controller script, '' = none
    Static: Boolean;      // serve non-script files from DocRoot directly
  end;

  TVDRX_BusRoutes = array of TVDRX_BusRoute;

  // "rewrites": regex on the request path -> new target (may carry ?query).
  // Flag: 'last' (default, first match wins) | 'continue' | 'redirect' (302) | 'permanent' (301)
  TVDRX_RewriteRule = record
    Pattern: string;
    Target: string;
    Flag: string;
  end;

  TVDRX_RewriteRules = array of TVDRX_RewriteRule;

  // Everything the HTTP edge consults, in the order it consults it.
  TVDRX_RouteTable = record
    Rewrites: TVDRX_RewriteRules;
    Proxy: TVDRX_ProxyRoutes;
    Bus: TVDRX_BusRoutes;
  end;

const
  MAX_HEADER_SIZE = 16384;
  MAX_BODY_SIZE = 10 * 1024 * 1024;
  DefaultStaticDenyExtensions: array[0..19] of string = ('conf', 'log', 'pem', 'key', 'env', 'bak',
    'sql', 'sqlite', 'sqlite3', 'db', 'inc', 'php', 'phtml', 'py', 'pl', 'cgi', 'sh', 'bat', 'cmd', 'ps1');

var
  HTTPResponseTimeoutMs: Integer = 600000;
  StaticFollowSymlinks: Boolean = False;
  HTTPWriteTimeoutMs: Integer = 30000;

// How long an HTTP client may take to send its request: AReadMs is the longest
// gap between two reads (idle / slow-loris), ARequestMs the total allowed for
// the whole request (headers + body). 0 turns that limit off.
procedure VDRX_ConfigureHTTPTimeouts(AReadMs, ARequestMs: Integer);

// How long the daemon waits for a client to take the response: AWriteMs is the longest a single
// write may stall (a client that stopped reading), AResponseMs the most the whole response may take.
// A client that exceeds either is dropped. 0 turns a limit off.
procedure VDRX_ConfigureHTTPWriteLimits(AWriteMs, AResponseMs: Integer);

// What the static file server will NOT hand out, whatever is lying in the directory:
//  * files with these extensions: configuration, logs, keys, backups, databases, and script
//    source (a .php that no CGI route runs would otherwise be sent as text). Matches are answered
//    with the same 404 as a missing file. The default list is DefaultStaticDenyExtensions;
//    AExtraDeny adds to it and AAllow takes entries out of it.
//  * anything reached through a symbolic link (AFollowSymlinks = False), so a link inside the
//    directory cannot lead out of it.
procedure VDRX_ConfigureStaticPolicy(const AExtraDeny, AAllow: array of string; AFollowSymlinks: Boolean);

// True when the static server would refuse a file with this name (by extension).
function VDRX_StaticDenied(const AFileName: string): Boolean;

// Splits a URL path into safe directory/file segments (percent-decoded); False for anything that
// could escape the doc root or reach something hidden. Exposed for the unit tests.
function SplitURLPath(const ARawPath: string; ASegs: TStrings): Boolean;

function ExtractHeaderValue(const AHeaderBlock, AName: string): string;

// 'http://Dash.Corp:8080/x' -> 'dash.corp'; 'dash.corp:8080' -> 'dash.corp'; '[::1]:80' -> '[::1]'.
function HostNameOf(const AValue: string): string;

// The status line and headers of a response whose body is AContentLength bytes long and is sent
// separately (streamed from a file) rather than built in memory.
function PlainResponseHead(const AStatus, AContentType: string; AContentLength: Int64; ACustomHeaders: TStringList = nil): string;

function ExtractQueryString(const ARequest: string): string;

// "HTTP/1.1" from "GET /x HTTP/1.1"
function RequestVersion(const ARequest: string): string;

function ExtractBody(const ARequest: string): string;

function HeadersToJSON(const AHeaderBlock: string): TJSONObject;

// vdrx is usually the first server a client reaches, so any header that claims to say who the client is
// (X-Forwarded-For, Forwarded, X-Real-IP, CF-Connecting-IP ...) was written by the client and is a lie.
// Applications behind vdrx (CGI scripts, bus subscribers, reverse-proxied servers) often trust those headers
// for rate limiting, audit logs and "is this an internal address" checks, so vdrx removes them from the
// request unless the peer is a configured trusted proxy. Only the head is touched; folded continuation lines
// of a removed header go with it; the request line is never removed.
function StripForwardedHeaders(const ARequest: string): string;

// True for the config spellings of "no": false, 0, no, off (any case). Anything else, and '', is not.
function VDRX_IsFalseText(const AText: string): Boolean;

// For a request vdrx passes on to an upstream: appends the connecting address to X-Forwarded-For (creating it)
// and sets X-Forwarded-Proto when the request has none. Run it AFTER StripForwardedHeaders, so that for an
// untrusted client these headers hold only what vdrx saw itself.
function AddForwardedHeaders(const ARequest, APeerAddr: string; ASecure: Boolean): string;

procedure ParseRequestLine(const ARequest: string; out AMethod, APath: string);

function GuessContentType(const APath: string): string;

function HTTPStatusText(ACode: Integer): string;

// True when any path component below ARoot (not ARoot itself: pointing the site at a link is the
// administrator's choice) is a symbolic link / reparse point.
function PathHasSymlink(const ARoot: string; ASegs: TStrings): Boolean;

function PlainResponse(const AStatus, AContentType, ABody: string; ACustomHeaders: TStringList = nil): string;

function MatchBusRoute(const APath: string; const ARoutes: TVDRX_BusRoutes; out AMatch: TVDRX_BusRoute): Boolean;

function StatusOf(const AResponse: string): string;

// "/path?query" exactly as the client sent it
function RequestTarget(const ARequest: string): string;

// Runs the rewrite rules, in order, against the request path. A matching rule
// replaces the whole target with its "to" (regex groups as $1, $2, ... - see
// TRegExpr.Substitute); a "?query" in "to" replaces the query string, otherwise
// the client's own query is kept. Returns True for a redirect rule (ALocation +
// ARedirectStatus set); otherwise ANewRequest is the request to route (the
// original one if nothing matched).
function ApplyRewrites(const ARequest: string; const ARules: TVDRX_RewriteRules;
  out ANewRequest, ALocation: string; out ARedirectStatus: Integer): Boolean;

// True when a comma-separated header value (e.g. "keep-alive, Upgrade") contains AToken.
function ValueHasToken(const AValue, AToken: string): Boolean;

// Reads one HTTP request. Returns '' when the request is not usable:
//   * ATooLarge  - declared body over MAX_BODY_SIZE (caller answers 413)
//   * ATimedOut  - the client sent something and then went too slow or silent
//                  (caller answers 408); a client that never sent a byte is
//                  just dropped
// A request cut off in the middle of its body is dropped too, instead of being
// handled with a shorter body than it declared.
function ReadFullRequest(ATransport: TVDRX_Transport; out ATooLarge, ATimedOut: Boolean; out ABadStatus, ABadWhy: string): string;

function MatchProxyRoute(const APath: string; const ARoutes: TVDRX_ProxyRoutes; out AMatch: TVDRX_ProxyRoute): Boolean;

implementation

var
  HTTPReadTimeoutMs: Integer = 10000;
  HTTPRequestTimeoutMs: Integer = 30000;
  StaticDeny: TStringList = nil;            // lower-case extensions without the dot

procedure VDRX_ConfigureStaticPolicy(const AExtraDeny, AAllow: array of string; AFollowSymlinks: Boolean);
var
  i, k: Integer;
  E: string;
begin
  if StaticDeny = nil then StaticDeny := TStringList.Create;
  StaticDeny.Clear;
  StaticDeny.Sorted := False;
  for i := Low(DefaultStaticDenyExtensions) to High(DefaultStaticDenyExtensions) do
    StaticDeny.Add(DefaultStaticDenyExtensions[i]);
  for i := Low(AExtraDeny) to High(AExtraDeny) do
  begin
    E := LowerCase(Trim(AExtraDeny[i]));
    if (E <> '') and (E[1] = '.') then Delete(E, 1, 1);
    if (E <> '') and (StaticDeny.IndexOf(E) < 0) then StaticDeny.Add(E);
  end;
  for i := Low(AAllow) to High(AAllow) do
  begin
    E := LowerCase(Trim(AAllow[i]));
    if (E <> '') and (E[1] = '.') then Delete(E, 1, 1);
    k := StaticDeny.IndexOf(E);
    if k >= 0 then StaticDeny.Delete(k);
  end;
  StaticFollowSymlinks := AFollowSymlinks;
end;

function VDRX_StaticDenied(const AFileName: string): Boolean;
var
  Ext: string;
  i: Integer;
begin
  Ext := LowerCase(ExtractFileExt(AFileName));
  if (Ext <> '') and (Ext[1] = '.') then Delete(Ext, 1, 1);
  if Ext = '' then Exit(False);
  if StaticDeny = nil then
  begin
    for i := Low(DefaultStaticDenyExtensions) to High(DefaultStaticDenyExtensions) do
      if Ext = DefaultStaticDenyExtensions[i] then Exit(True);
    Exit(False);
  end;
  Result := StaticDeny.IndexOf(Ext) >= 0;
end;

const
  SYMLINK_ATTR = $00000400;   // = faSymLink on Unix and FILE_ATTRIBUTE_REPARSE_POINT on Windows (the name itself is flagged non-portable)

// True when APath is itself a symbolic link (lstat on Unix; on Windows a reparse point). FindFirst
// is not used on Unix: it reports what the link points at, not the link.
function IsSymlinkPath(const APath: string): Boolean;
{$IFDEF UNIX}
var
  St: Stat;
begin
  Result := (fpLstat(PChar(APath), St) = 0) and fpS_ISLNK(St.st_mode);
end;
{$ELSE}
var
  SR: TSearchRec;
begin
  Result := False;
  if FindFirst(APath, faAnyFile, SR) = 0 then
  begin
    try
      Result := (SR.Attr and SYMLINK_ATTR) <> 0;
    finally
      FindClose(SR);
    end;
  end;
end;
{$ENDIF}

// True when any path component below ARoot (not ARoot itself: pointing the site at a link is the
// administrator's choice) is a symbolic link / reparse point.
function PathHasSymlink(const ARoot: string; ASegs: TStrings): Boolean;
var
  Cur: string;
  i: Integer;
begin
  Result := False;
  Cur := ExcludeTrailingPathDelimiter(ARoot);
  for i := 0 to ASegs.Count - 1 do
  begin
    Cur := Cur + PathDelim + ASegs[i];
    if IsSymlinkPath(Cur) then Exit(True);
  end;
end;

procedure VDRX_ConfigureHTTPWriteLimits(AWriteMs, AResponseMs: Integer);
begin
  if AWriteMs >= 0 then HTTPWriteTimeoutMs := AWriteMs;
  if AResponseMs >= 0 then HTTPResponseTimeoutMs := AResponseMs;
end;

procedure VDRX_ConfigureHTTPTimeouts(AReadMs, ARequestMs: Integer);
begin
  if AReadMs >= 0 then HTTPReadTimeoutMs := AReadMs;
  if ARequestMs >= 0 then HTTPRequestTimeoutMs := ARequestMs;
end;

// The status line and headers of a response whose body is AContentLength bytes long and is sent
// separately (streamed from a file) rather than built in memory.
function PlainResponseHead(const AStatus, AContentType: string; AContentLength: Int64; ACustomHeaders: TStringList = nil): string;
var
  i: Integer;
  ExtraHeaders: string;
begin
  ExtraHeaders := '';
  if Assigned(ACustomHeaders) then
  begin
    for i := 0 to ACustomHeaders.Count - 1 do
    begin
      if ACustomHeaders.Names[i] <> '' then
        ExtraHeaders := ExtraHeaders + ACustomHeaders.Names[i] + ': ' + ACustomHeaders.ValueFromIndex[i] + #13#10
      else if Trim(ACustomHeaders[i]) <> '' then
        ExtraHeaders := ExtraHeaders + Trim(ACustomHeaders[i]) + #13#10;
    end;
  end;

  Result := 'HTTP/1.1 ' + AStatus + #13#10 +
            'Content-Type: ' + AContentType + #13#10 +
            'Content-Length: ' + IntToStr(AContentLength) + #13#10 +
            ExtraHeaders + #13#10;
end;

function PlainResponse(const AStatus, AContentType, ABody: string; ACustomHeaders: TStringList = nil): string;
begin
  Result := PlainResponseHead(AStatus, AContentType, Length(ABody), ACustomHeaders) + ABody;
end;

function StatusOf(const AResponse: string): string;
var
  LineEnd, SpacePos: Integer;
begin
  LineEnd := Pos(#13#10, AResponse);
  if LineEnd = 0 then LineEnd := Length(AResponse) + 1;
  SpacePos := Pos(' ', AResponse);
  if (SpacePos = 0) or (SpacePos >= LineEnd) then Exit('?');
  Result := Copy(AResponse, SpacePos + 1, LineEnd - SpacePos - 1);
end;

procedure ParseRequestLine(const ARequest: string; out AMethod, APath: string);
var
  LineEnd, Sp1, Sp2: Integer;
  Line: string;
begin
  AMethod := '';
  APath := '';
  LineEnd := Pos(#13#10, ARequest);
  if LineEnd = 0 then LineEnd := Pos(#10, ARequest);
  if LineEnd = 0 then Line := ARequest else Line := Copy(ARequest, 1, LineEnd - 1);
  Sp1 := Pos(' ', Line);
  if Sp1 = 0 then Exit;
  AMethod := Copy(Line, 1, Sp1 - 1);
  Sp2 := PosEx(' ', Line, Sp1 + 1);
  if Sp2 = 0 then Sp2 := Length(Line) + 1;
  APath := Copy(Line, Sp1 + 1, Sp2 - Sp1 - 1);
  Sp1 := Pos('?', APath);
  if Sp1 > 0 then APath := Copy(APath, 1, Sp1 - 1);
end;

function ExtractQueryString(const ARequest: string): string;
var
  LineEnd, Sp1, Sp2, QPos: Integer;
  Line, RawPath: string;
begin
  Result := '';
  LineEnd := Pos(#13#10, ARequest);
  if LineEnd = 0 then LineEnd := Length(ARequest) + 1;
  Line := Copy(ARequest, 1, LineEnd - 1);
  Sp1 := Pos(' ', Line);
  if Sp1 = 0 then Exit;
  Sp2 := PosEx(' ', Line, Sp1 + 1);
  if Sp2 = 0 then Sp2 := Length(Line) + 1;
  RawPath := Copy(Line, Sp1 + 1, Sp2 - Sp1 - 1);
  QPos := Pos('?', RawPath);
  if QPos > 0 then
    Result := Copy(RawPath, QPos + 1, MaxInt);
end;

function ExtractHeaderValue(const AHeaderBlock, AName: string): string;
var
  SL: TStringList;
  i, Colon: Integer;
begin
  Result := '';
  SL := TStringList.Create;
  try
    SL.Text := AHeaderBlock;
    for i := 1 to SL.Count - 1 do
    begin
      Colon := Pos(':', SL[i]);
      if (Colon > 0) and SameText(Trim(Copy(SL[i], 1, Colon - 1)), AName) then
        Exit(Trim(Copy(SL[i], Colon + 1, MaxInt)));
    end;
  finally
    SL.Free;
  end;
end;

// 'http://Dash.Corp:8080/x' -> 'dash.corp'; 'dash.corp:8080' -> 'dash.corp'; '[::1]:80' -> '[::1]'.
function HostNameOf(const AValue: string): string;
var
  S: string;
  p: Integer;
begin
  S := Trim(AValue);
  p := Pos('://', S);
  if p > 0 then Delete(S, 1, p + 2);
  p := Pos('/', S);
  if p > 0 then SetLength(S, p - 1);
  if (S <> '') and (S[1] = '[') then
  begin
    p := Pos(']', S);
    if p > 0 then SetLength(S, p);
  end
  else
  begin
    p := Pos(':', S);
    if p > 0 then SetLength(S, p - 1);
  end;
  Result := LowerCase(S);
end;

// Strict syntax and framing check of a request head (the text before the blank line). Returns '' when it is
// acceptable, else the status to answer with ('400 Bad Request', '501 Not Implemented'); AWhy says why for the log.
// On success AContentLength is the body length the request declares (0 if none).
//
// This matters because vdrx's front end and whatever is behind it (a reverse-proxied upstream, a CGI program, a
// proxy in front of vdrx) must agree on where a request ends and what it says. Every rule below closes a way for
// two parsers to disagree, which is how request smuggling works:
//   - a bare CR or LF anywhere (some parsers treat it as a line break, others as part of a value)
//   - a header line starting with space/tab (obsolete line folding), or whitespace before the colon
//   - a header name that is not a plain token
//   - more than one Content-Length, or a Content-Length that is not plain decimal digits (FPC's StrToInt would
//     happily read '$10' or '0x10' as 16)
//   - any Transfer-Encoding: vdrx does not decode chunked bodies, so it would read the body as empty while a
//     backend honouring the header reads it as the rest of the stream (RFC 9112 6.1: answer 501)
function CheckRequestHead(const AHead: string; out AContentLength: Int64; out AWhy: string): string;
const
  TokenChars = ['A'..'Z', 'a'..'z', '0'..'9', '!', '#', '$', '%', '&', '''', '*', '+', '-', '.', '^', '_', '`', '|', '~'];
var
  i, LineStart, Colon, CLCount, k: Integer;
  Line, Name, Value: string;
  c: Char;

  function Bad(const AMsg: string): string;
  begin
    AWhy := AMsg;
    Result := '400 Bad Request';
  end;

begin
  Result := '';
  AWhy := '';
  AContentLength := 0;
  CLCount := 0;
  for i := 1 to Length(AHead) do
  begin
    c := AHead[i];
    if c = #13 then begin if (i = Length(AHead)) or (AHead[i + 1] <> #10) then Exit(Bad('bare CR in the request head')); end
    else if c = #10 then begin if (i = 1) or (AHead[i - 1] <> #13) then Exit(Bad('bare LF in the request head')); end
    else if ((c < #32) and (c <> #9)) or (c = #127) then Exit(Bad('control character in the request head'));
  end;
  // line 1 is the request line; the header fields start after the first CRLF
  LineStart := Pos(#13#10, AHead);
  if LineStart = 0 then Exit;                      // no header fields at all
  LineStart := LineStart + 2;
  while LineStart <= Length(AHead) do
  begin
    k := PosEx(#13#10, AHead, LineStart);
    if k = 0 then k := Length(AHead) + 1;
    Line := Copy(AHead, LineStart, k - LineStart);
    LineStart := k + 2;
    if Line = '' then Continue;
    if Line[1] in [' ', #9] then Exit(Bad('obsolete header line folding'));
    Colon := Pos(':', Line);
    if Colon < 2 then Exit(Bad('header line without a name'));
    Name := Copy(Line, 1, Colon - 1);
    for k := 1 to Length(Name) do
      if not (Name[k] in TokenChars) then Exit(Bad('invalid character in a header name (whitespace before the colon?)'));
    Name := LowerCase(Name);
    if Name = 'transfer-encoding' then
    begin
      AWhy := 'Transfer-Encoding is not supported (chunked request bodies are not decoded)';
      Exit('501 Not Implemented');
    end;
    if Name = 'content-length' then
    begin
      Inc(CLCount);
      Value := Trim(Copy(Line, Colon + 1, MaxInt));
      if (Value = '') or (Length(Value) > 12) then Exit(Bad('invalid Content-Length'));
      for k := 1 to Length(Value) do
        if not (Value[k] in ['0'..'9']) then Exit(Bad('invalid Content-Length'));
      AContentLength := StrToInt64(Value);
    end;
  end;
  if CLCount > 1 then Exit(Bad('more than one Content-Length header'));
end;

// True when a comma-separated header value (e.g. "keep-alive, Upgrade") contains AToken.
function ValueHasToken(const AValue, AToken: string): Boolean;
var
  Part: string;
begin
  Result := False;
  for Part in LowerCase(AValue).Split([',']) do
    if Trim(Part) = LowerCase(AToken) then Exit(True);
end;

// Reads one HTTP request. Returns '' when the request is not usable:
//   * ATooLarge  - declared body over MAX_BODY_SIZE (caller answers 413)
//   * ATimedOut  - the client sent something and then went too slow or silent
//                  (caller answers 408); a client that never sent a byte is
//                  just dropped
// A request cut off in the middle of its body is dropped too, instead of being
// handled with a shorter body than it declared.
function ReadFullRequest(ATransport: TVDRX_Transport; out ATooLarge, ATimedOut: Boolean; out ABadStatus, ABadWhy: string): string;
var
  Buf: array[0..4095] of Byte;
  Received, HeaderEnd, ContentLength, BodySoFar, ToRead, Used, Cap: Integer;
  HeaderBlock: string;
  CL64: Int64;
  StartTick, ReadStart: QWord;
  Armed: Int64;

  // Sets the socket read timeout for the next read: the per-read limit, or what is
  // left of the total, whichever is smaller. False = the total has already run out.
  function ArmTimeout: Boolean;
  var
    Left: Int64;
  begin
    Result := True;
    Left := HTTPReadTimeoutMs;
    if HTTPRequestTimeoutMs > 0 then
    begin
      Armed := Int64(HTTPRequestTimeoutMs) - Int64(GetTickCount64 - StartTick);
      if Armed <= 0 then Exit(False);
      if (Left <= 0) or (Armed < Left) then Left := Armed;
    end;
    Armed := Left;
    if Left > 0 then ATransport.SetReadTimeout(Integer(Left));
  end;

  // After a read that returned nothing: was that our timeout firing (as opposed to the peer closing)?
  function LooksLikeTimeout: Boolean;
  begin
    Result := (Armed > 0) and (Int64(GetTickCount64 - ReadStart) + 150 >= Armed);
  end;

begin
  Result := '';
  ATooLarge := False;
  ATimedOut := False;
  ABadStatus := '';
  ABadWhy := '';
  HeaderEnd := 0;
  StartTick := GetTickCount64;
  Armed := 0;
  while (HeaderEnd = 0) and (Length(Result) < MAX_HEADER_SIZE) do
  begin
    if not ArmTimeout then
    begin
      ATimedOut := Result <> '';
      Exit('');
    end;
    ReadStart := GetTickCount64;
    Received := ATransport.Read(Buf[0], SizeOf(Buf));
    if Received <= 0 then
    begin
      if LooksLikeTimeout then
      begin
        ATimedOut := Result <> '';
        Exit('');
      end;
      Exit(Result);
    end;
    SetLength(Result, Length(Result) + Received);
    Move(Buf[0], Result[Length(Result) - Received + 1], Received);
    HeaderEnd := Pos(#13#10#13#10, Result);
  end;
  if HeaderEnd = 0 then
  begin
    if Length(Result) >= MAX_HEADER_SIZE then
    begin
      ABadStatus := '431 Request Header Fields Too Large';
      ABadWhy := 'request head longer than ' + IntToStr(MAX_HEADER_SIZE) + ' bytes';
      Exit('');
    end;
    Exit;
  end;
  if HeaderEnd - 1 > MAX_HEADER_SIZE then
  begin
    ABadStatus := '431 Request Header Fields Too Large';
    ABadWhy := 'request head longer than ' + IntToStr(MAX_HEADER_SIZE) + ' bytes';
    Exit('');
  end;

  HeaderBlock := Copy(Result, 1, HeaderEnd - 1);
  ABadStatus := CheckRequestHead(HeaderBlock, CL64, ABadWhy);
  if ABadStatus <> '' then Exit('');
  if CL64 > MAX_BODY_SIZE then CL64 := Int64(MAX_BODY_SIZE) + 1;
  ContentLength := Integer(CL64);
  if ContentLength > MAX_BODY_SIZE then
  begin
    // Previously this just clamped ContentLength and kept reading: the
    // client still sends the bytes beyond the clamp, which were never
    // consumed, so the next request parsed off this connection (if the
    // caller ever reused it) would desync on that leftover body data.
    // Every connection here is answered once and closed (see
    // TVDRX_HTTPConnection.Run), so today that's latent rather than
    // exploitable - but it is a real request-smuggling trap if keep-alive
    // is ever added, and a declared-too-large body deserves an honest 413
    // rather than a silently truncated 200 anyway. The caller closes the
    // connection either way.
    ATooLarge := True;
    Exit('');
  end;

  // The body buffer grows as bytes actually arrive. Reserving the declared
  // Content-Length up front (up to 10 MB) let a client that only SAYS it will
  // send a big body pin that much address space/commit per connection.
  BodySoFar := Length(Result) - (HeaderEnd + 3);
  Used := Length(Result);
  Cap := Used;
  while BodySoFar < ContentLength do
  begin
    if not ArmTimeout then
    begin
      ATimedOut := True;
      Exit('');
    end;
    ToRead := ContentLength - BodySoFar;
    if ToRead > SizeOf(Buf) then ToRead := SizeOf(Buf);
    ReadStart := GetTickCount64;
    Received := ATransport.Read(Buf[0], ToRead);
    if Received <= 0 then
    begin
      ATimedOut := LooksLikeTimeout;
      Exit('');                       // truncated body: do not process half a request
    end;
    if Used + Received > Cap then
    begin
      Cap := Used + Received + (Used div 2) + 65536;
      if Cap > HeaderEnd + 3 + ContentLength then Cap := HeaderEnd + 3 + ContentLength;
      SetLength(Result, Cap);
    end;
    Move(Buf[0], Result[Used + 1], Received);
    Inc(Used, Received);
    Inc(BodySoFar, Received);
  end;
  SetLength(Result, Used);
  // Anything that arrived beyond the declared body is not part of this request (a second, pipelined request,
  // or an attempt to smuggle one): it must never be handed on - the reverse proxy forwards the raw bytes.
  if Length(Result) > HeaderEnd + 3 + ContentLength then
    SetLength(Result, HeaderEnd + 3 + ContentLength);
end;

// A Windows 8.3 short-name alias: up to 6 name characters, '~', digits, and an optional extension of
// at most 3 characters ("GIT~1" is what NTFS calls ".git", "PROGRA~1" what it calls "Program Files").
// The dot-file rule below would not see through one, so aliases are refused outright.
function IsShortNameAlias(const ASeg: string): Boolean;
var
  Stem, Ext: string;
  d, t, k: Integer;
begin
  Result := False;
  d := Pos('.', ASeg);
  if d > 0 then begin Stem := Copy(ASeg, 1, d - 1); Ext := Copy(ASeg, d + 1, MaxInt); end
  else begin Stem := ASeg; Ext := ''; end;
  if (Length(Ext) > 3) or (Length(Stem) < 3) or (Length(Stem) > 8) then Exit;
  t := Pos('~', Stem);
  if (t < 2) or (t > 7) or (t = Length(Stem)) then Exit;
  for k := t + 1 to Length(Stem) do
    if not (Stem[k] in ['0'..'9']) then Exit;
  Result := True;
end;

// Windows device names (CON, NUL, COM1 ...) are special whatever the extension or case ("nul.txt" is
// still the NUL device); opening one can hang a handler or read the console. Refused on every platform.
function IsReservedDeviceName(const ASeg: string): Boolean;
var
  Stem: string;
  d: Integer;
begin
  d := Pos('.', ASeg);
  if d > 0 then Stem := Copy(ASeg, 1, d - 1) else Stem := ASeg;
  Stem := UpperCase(TrimRight(Stem));
  Result := (Stem = 'CON') or (Stem = 'PRN') or (Stem = 'AUX') or (Stem = 'NUL') or (Stem = 'CONIN$') or (Stem = 'CONOUT$') or
    ((Length(Stem) = 4) and ((Copy(Stem, 1, 3) = 'COM') or (Copy(Stem, 1, 3) = 'LPT')) and (Stem[4] in ['0'..'9']));
end;

// Maps a URL path (e.g. '/app/index.php') onto a directory, segment by segment.
// Returns False for anything that could escape or hide something: "..", NUL,
// backslashes, ':' (NTFS alternate data streams), dot-files (.git, .env ...;
// ".well-known" is allowed), their 8.3 aliases (GIT~1), Windows device names and
// segments ending in '.' or ' ' (Windows ignores those, so "x.php." would serve a
// script's source as plain text).
function SplitURLPath(const ARawPath: string; ASegs: TStrings): Boolean;
var
  Decoded, Seg: string;
  p, q: Integer;
begin
  Result := False;
  ASegs.Clear;
  Decoded := URLDecode(ARawPath, False);
  if (Pos(#0, Decoded) > 0) or (Pos('\', Decoded) > 0) or (Pos(':', Decoded) > 0) then Exit;
  p := 1;
  while p <= Length(Decoded) + 1 do
  begin
    q := PosEx('/', Decoded, p);
    if q = 0 then q := Length(Decoded) + 1;
    Seg := Copy(Decoded, p, q - p);
    p := q + 1;
    if (Seg = '') or (Seg = '.') then Continue;
    if Seg = '..' then Exit;
    if (Seg[1] = '.') and (Seg <> '.well-known') then Exit;
    if Seg[Length(Seg)] in ['.', ' '] then Exit;
    if IsShortNameAlias(Seg) or IsReservedDeviceName(Seg) then Exit;
    ASegs.Add(Seg);
  end;
  Result := True;
end;

function GuessContentType(const APath: string): string;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(APath));
  if Ext = '.png' then Result := 'image/png'
  else if (Ext = '.jpg') or (Ext = '.jpeg') then Result := 'image/jpeg'
  else if Ext = '.webp' then Result := 'image/webp'
  else if Ext = '.gif' then Result := 'image/gif'
  else if Ext = '.ico' then Result := 'image/x-icon'
  else if Ext = '.js' then Result := 'application/javascript'
  else if Ext = '.css' then Result := 'text/css'
  else if Ext = '.html' then Result := 'text/html'
  else if Ext = '.json' then Result := 'application/json'
  else if Ext = '.svg' then Result := 'image/svg+xml'
  else if Ext = '.wasm' then Result := 'application/wasm'
  else if (Ext = '.txt') or (Ext = '.log') or (Ext = '.md') then Result := 'text/plain; charset=utf-8'
  else if Ext = '.xml' then Result := 'application/xml'
  else if Ext = '.pdf' then Result := 'application/pdf'
  else if Ext = '.woff2' then Result := 'font/woff2'
  else if Ext = '.woff' then Result := 'font/woff'
  else if Ext = '.map' then Result := 'application/json'
  else if (Ext = '.mp4') or (Ext = '.m4v') then Result := 'video/mp4'
  else if Ext = '.csv' then Result := 'text/csv'
  else Result := 'application/octet-stream';
end;

// Does APath fall under APrefix? A prefix that ends in '/' covers everything below it. One that does not
// ("/app") covers "/app", "/app/x" and "/app?x" but NOT "/application" or "/app-admin": matching a bare string
// prefix would hand those other paths to the route (and, for a reverse proxy, forward them upstream).
function PathUnderPrefix(const APath, APrefix: string): Boolean;
var
  n: Integer;
begin
  n := Length(APrefix);
  if (n = 0) or (Copy(APath, 1, n) <> APrefix) then Exit(False);
  Result := (APrefix[n] = '/') or (Length(APath) = n) or (APath[n + 1] in ['/', '?']);
end;

function MatchProxyRoute(const APath: string; const ARoutes: TVDRX_ProxyRoutes; out AMatch: TVDRX_ProxyRoute): Boolean;
var
  i, bestLen: Integer;
begin
  Result := False;
  bestLen := -1;
  for i := 0 to High(ARoutes) do
    if PathUnderPrefix(APath, ARoutes[i].Prefix) and (Length(ARoutes[i].Prefix) > bestLen) then
    begin
      AMatch := ARoutes[i];
      bestLen := Length(ARoutes[i].Prefix);
      Result := True;
    end;
end;

function MatchBusRoute(const APath: string; const ARoutes: TVDRX_BusRoutes; out AMatch: TVDRX_BusRoute): Boolean;
var
  i, bestLen: Integer;
begin
  Result := False;
  bestLen := -1;
  for i := 0 to High(ARoutes) do
    if PathUnderPrefix(APath, ARoutes[i].Prefix) and (Length(ARoutes[i].Prefix) > bestLen) then
    begin
      AMatch := ARoutes[i];
      bestLen := Length(ARoutes[i].Prefix);
      Result := True;
    end;
end;

{ ---- request-line helpers + rewrites --------------------------------------- }

// "HTTP/1.1" from "GET /x HTTP/1.1"
function RequestVersion(const ARequest: string): string;
var
  LineEnd, Sp1, Sp2: Integer;
  Line: string;
begin
  Result := 'HTTP/1.1';
  LineEnd := Pos(#13#10, ARequest);
  if LineEnd = 0 then Exit;
  Line := Copy(ARequest, 1, LineEnd - 1);
  Sp1 := Pos(' ', Line);
  if Sp1 = 0 then Exit;
  Sp2 := PosEx(' ', Line, Sp1 + 1);
  if Sp2 > 0 then Result := Trim(Copy(Line, Sp2 + 1, MaxInt));
end;

// "/path?query" exactly as the client sent it
function RequestTarget(const ARequest: string): string;
var
  LineEnd, Sp1, Sp2: Integer;
  Line: string;
begin
  Result := '';
  LineEnd := Pos(#13#10, ARequest);
  if LineEnd = 0 then LineEnd := Length(ARequest) + 1;
  Line := Copy(ARequest, 1, LineEnd - 1);
  Sp1 := Pos(' ', Line);
  if Sp1 = 0 then Exit;
  Sp2 := PosEx(' ', Line, Sp1 + 1);
  if Sp2 = 0 then Sp2 := Length(Line) + 1;
  Result := Copy(Line, Sp1 + 1, Sp2 - Sp1 - 1);
end;

function ReplaceRequestTarget(const ARequest, ANewTarget: string): string;
var
  LineEnd, Sp1: Integer;
  Line: string;
begin
  LineEnd := Pos(#13#10, ARequest);
  if LineEnd = 0 then Exit(ARequest);
  Line := Copy(ARequest, 1, LineEnd - 1);
  Sp1 := Pos(' ', Line);
  if Sp1 = 0 then Exit(ARequest);
  Result := Copy(Line, 1, Sp1) + ANewTarget + ' ' + RequestVersion(ARequest) + Copy(ARequest, LineEnd, MaxInt);
end;

// Runs the rewrite rules, in order, against the request path. A matching rule
// replaces the whole target with its "to" (regex groups as $1, $2, ... - see
// TRegExpr.Substitute); a "?query" in "to" replaces the query string, otherwise
// the client's own query is kept. Returns True for a redirect rule (ALocation +
// ARedirectStatus set); otherwise ANewRequest is the request to route (the
// original one if nothing matched).
function ApplyRewrites(const ARequest: string; const ARules: TVDRX_RewriteRules;
  out ANewRequest, ALocation: string; out ARedirectStatus: Integer): Boolean;
var
  Method, Path, Query, NewTarget, Flag: string;
  i, q: Integer;
  Re: TRegExpr;
  Matched, Changed: Boolean;
begin
  Result := False;
  ANewRequest := ARequest;
  ALocation := '';
  ARedirectStatus := 0;
  if Length(ARules) = 0 then Exit;
  ParseRequestLine(ARequest, Method, Path);
  Query := ExtractQueryString(ARequest);
  Changed := False;
  Re := TRegExpr.Create;
  try
    for i := 0 to High(ARules) do
    begin
      Matched := False;
      NewTarget := '';
      try
        Re.Expression := ARules[i].Pattern;
        if Re.Exec(Path) then
        begin
          NewTarget := Re.Substitute(ARules[i].Target);
          Matched := True;
        end;
      except
        // a bad pattern is reported once at startup (vdrx.lpr); skip it here
      end;
      if not Matched then Continue;
      Changed := True;
      q := Pos('?', NewTarget);
      if q > 0 then
      begin
        Path := Copy(NewTarget, 1, q - 1);
        Query := Copy(NewTarget, q + 1, MaxInt);
      end
      else
        Path := NewTarget;
      Flag := LowerCase(ARules[i].Flag);
      if (Flag = 'redirect') or (Flag = 'permanent') then
      begin
        ALocation := Path + IfThen(Query <> '', '?' + Query, '');
        if Flag = 'permanent' then ARedirectStatus := 301 else ARedirectStatus := 302;
        Exit(True);
      end;
      if Flag <> 'continue' then Break;   // 'last' (default): first match wins
    end;
  finally
    Re.Free;
  end;
  if Changed then
    ANewRequest := ReplaceRequestTarget(ARequest, Path + IfThen(Query <> '', '?' + Query, ''));
end;

{ ---- mapping a URL onto a script under doc_root ----------------------------- }

function HTTPStatusText(ACode: Integer): string;
begin
  case ACode of
    200: Result := 'OK';
    201: Result := 'Created';
    204: Result := 'No Content';
    301: Result := 'Moved Permanently';
    302: Result := 'Found';
    303: Result := 'See Other';
    304: Result := 'Not Modified';
    307: Result := 'Temporary Redirect';
    308: Result := 'Permanent Redirect';
    400: Result := 'Bad Request';
    401: Result := 'Unauthorized';
    403: Result := 'Forbidden';
    404: Result := 'Not Found';
    405: Result := 'Method Not Allowed';
    409: Result := 'Conflict';
    410: Result := 'Gone';
    413: Result := 'Payload Too Large';
    415: Result := 'Unsupported Media Type';
    422: Result := 'Unprocessable Content';
    429: Result := 'Too Many Requests';
    500: Result := 'Internal Server Error';
    501: Result := 'Not Implemented';
    502: Result := 'Bad Gateway';
    503: Result := 'Service Unavailable';
    504: Result := 'Gateway Timeout';
  else
    if (ACode >= 200) and (ACode < 300) then Result := 'OK'
    else if (ACode >= 400) and (ACode < 500) then Result := 'Error'
    else if ACode >= 500 then Result := 'Server Error'
    else Result := 'Unknown';
  end;
end;

function ExtractBody(const ARequest: string): string;
var
  HeaderEnd: Integer;
begin
  HeaderEnd := Pos(#13#10#13#10, ARequest);
  if HeaderEnd = 0 then Exit('');
  Result := Copy(ARequest, HeaderEnd + 4, MaxInt);
end;

function HeadersToJSON(const AHeaderBlock: string): TJSONObject;
var
  SL: TStringList;
  i, Colon: Integer;
  Name, Value: string;
begin
  Result := TJSONObject.Create;
  SL := TStringList.Create;
  try
    SL.Text := AHeaderBlock;
    for i := 1 to SL.Count - 1 do
    begin
      Colon := Pos(':', SL[i]);
      if Colon > 0 then
      begin
        Name := Trim(Copy(SL[i], 1, Colon - 1));
        Value := Trim(Copy(SL[i], Colon + 1, MaxInt));
        if Name <> '' then
        begin
          // a repeated header is folded into one comma-separated value
          // (RFC 9110 5.3; Cookie uses "; ")
          if Assigned(Result.Find(Name)) then
            Result.Strings[Name] := Result.Strings[Name] + IfThen(SameText(Name, 'Cookie'), '; ', ', ') + CleanUTF8(Value)
          else
            Result.Strings[Name] := CleanUTF8(Value);
        end;
      end;
    end;
  finally
    SL.Free;
  end;
end;

function VDRX_IsFalseText(const AText: string): Boolean;
var
  T: string;
begin
  T := LowerCase(Trim(AText));
  Result := (T = 'false') or (T = '0') or (T = 'no') or (T = 'off');
end;

function IsForwardedHeaderName(const AName: string): Boolean;
var
  L: string;
begin
  L := StringReplace(LowerCase(Trim(AName)), '_', '-', [rfReplaceAll]);
  Result := (L = 'forwarded') or (Copy(L, 1, 12) = 'x-forwarded-') or (L = 'x-real-ip') or
    (L = 'x-client-ip') or (L = 'true-client-ip') or (L = 'cf-connecting-ip') or
    (L = 'x-cluster-client-ip') or (L = 'x-original-forwarded-for');
end;

function StripForwardedHeaders(const ARequest: string): string;
var
  HeadEnd, LineStart, k, Colon: Integer;
  Line: string;
  Dropping: Boolean;
begin
  HeadEnd := Pos(#13#10#13#10, ARequest);
  if HeadEnd = 0 then Exit(ARequest);
  Result := '';
  Dropping := False;
  LineStart := 1;
  while LineStart <= HeadEnd do
  begin
    k := PosEx(#13#10, ARequest, LineStart);
    if (k = 0) or (k > HeadEnd) then k := HeadEnd + 1;
    Line := Copy(ARequest, LineStart, k - LineStart);
    LineStart := k + 2;
    if Result = '' then
      Result := Line + #13#10                                    // the request line
    else if (Line <> '') and (Line[1] in [' ', #9]) then
    begin
      if not Dropping then Result := Result + Line + #13#10;      // continuation of the previous header
    end
    else
    begin
      Colon := Pos(':', Line);
      Dropping := (Colon > 0) and IsForwardedHeaderName(Copy(Line, 1, Colon - 1));
      if not Dropping then Result := Result + Line + #13#10;
    end;
  end;
  Result := Result + #13#10 + Copy(ARequest, HeadEnd + 4, MaxInt);
end;

function AddForwardedHeaders(const ARequest, APeerAddr: string; ASecure: Boolean): string;
var
  HeadEnd, LineStart, k, Colon: Integer;
  Line, Name, Extra, Proto, Prior: string;
  Seen: Boolean;
begin
  HeadEnd := Pos(#13#10#13#10, ARequest);
  if (HeadEnd = 0) or (APeerAddr = '') then Exit(ARequest);
  if ASecure then Proto := 'https' else Proto := 'http';
  Prior := '';
  Seen := False;
  Result := '';
  LineStart := 1;
  while LineStart <= HeadEnd do
  begin
    k := PosEx(#13#10, ARequest, LineStart);
    if (k = 0) or (k > HeadEnd) then k := HeadEnd + 1;
    Line := Copy(ARequest, LineStart, k - LineStart);
    LineStart := k + 2;
    Colon := Pos(':', Line);
    if (Result <> '') and (Colon > 0) then
    begin
      Name := LowerCase(Trim(Copy(Line, 1, Colon - 1)));
      if Name = 'x-forwarded-for' then
      begin
        // an existing value (only possible from a trusted proxy) is extended, not replaced
        if Prior <> '' then Prior := Prior + ', ';
        Prior := Prior + Trim(Copy(Line, Colon + 1, MaxInt));
        Continue;
      end;
      if Name = 'x-forwarded-proto' then Seen := True;
    end;
    Result := Result + Line + #13#10;
  end;
  if Prior <> '' then Prior := Prior + ', ';
  Extra := 'X-Forwarded-For: ' + Prior + APeerAddr + #13#10;
  if not Seen then Extra := Extra + 'X-Forwarded-Proto: ' + Proto + #13#10;
  Result := Result + Extra + #13#10 + Copy(ARequest, HeadEnd + 4, MaxInt);
end;

end.
