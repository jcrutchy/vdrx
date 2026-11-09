unit vdrx_redact;

{$mode ObjFPC}{$H+}

// Masks credentials in text that is about to be written to a log. Pure text
// in, text out - no dependency on the rest of vdrx, so it is unit-tested on
// its own (tests/unit/test_redact.lpr).
//
// What it masks:
//   * JSON members whose NAME is a known secret: Authorization, Cookie,
//     Set-Cookie, token, _edge_token, password, api_key, secret, ...
//     (the value is replaced, the name is kept so the log line stays readable)
//   * HTTP bodies ("body" / "body_b64" members) - optional, on by default
//   * sensitive query-string / form parameters anywhere in the text
//     (api_key=..., token=..., password=..., session=..., sig=...)
//   * "Bearer xxx" / "Basic xxx" credentials
//
// It is a safety net for logs, not a guarantee: a secret in a member called
// "foo" is not recognised. Keep secrets out of topics you log.

interface

uses
  SysUtils, RegExpr;

const
  REDACTED_MARK = '[REDACTED]';

// Makes text safe to write into a log line. A client can put anything into a message that ends up in the
// log (a job name, a header, a body): a line break would forge a new log entry, and an ESC byte would inject
// terminal control sequences into the operator's console. CR, LF, ESC and the other control characters
// (except tab) become visible escapes (\r \n \xNN); bytes 128 and up (UTF-8) are left alone.
function VDRX_EscapeLogText(const AText: string): string;

type
  TVDRX_Redactor = class
  private
    FSecretMember: TRegExpr;
    FBodyMember: TRegExpr;
    FQueryPair: TRegExpr;
    FAuthScheme: TRegExpr;
    FRedactBodies: Boolean;
  public
    constructor Create(ARedactBodies: Boolean = True);
    destructor Destroy; override;
    // Not thread-safe (TRegExpr keeps match state): one thread at a time.
    function Redact(const AText: string): string;
    property RedactBodies: Boolean read FRedactBodies write FRedactBodies;
  end;

implementation

function VDRX_EscapeLogText(const AText: string): string;
const
  HEX = '0123456789abcdef';
var
  i, n: Integer;
  c: Char;
  Clean: Boolean;
begin
  Clean := True;
  for i := 1 to Length(AText) do
    if (AText[i] < #32) and (AText[i] <> #9) or (AText[i] = #127) then begin Clean := False; Break; end;
  if Clean then Exit(AText);
  SetLength(Result, Length(AText) * 4);   // worst case: every character becomes \xNN
  n := 0;
  for i := 1 to Length(AText) do
  begin
    c := AText[i];
    if c = #10 then begin Result[n + 1] := '\'; Result[n + 2] := 'n'; Inc(n, 2); end
    else if c = #13 then begin Result[n + 1] := '\'; Result[n + 2] := 'r'; Inc(n, 2); end
    else if ((c < #32) and (c <> #9)) or (c = #127) then
    begin
      Result[n + 1] := '\'; Result[n + 2] := 'x';
      Result[n + 3] := HEX[(Ord(c) shr 4) + 1]; Result[n + 4] := HEX[(Ord(c) and 15) + 1];
      Inc(n, 4);
    end
    else begin Inc(n); Result[n] := c; end;
  end;
  SetLength(Result, n);
end;

const
  // "<name>" : "<value>"  - the value may contain \" escapes and may be cut
  // off by payload truncation (no closing quote), so the closing quote is optional.
  JSON_STRING_VALUE = '\s*:\s*)"(?:[^"\\]|\\.)*"?';

constructor TVDRX_Redactor.Create(ARedactBodies: Boolean);
begin
  inherited Create;
  FRedactBodies := ARedactBodies;

  FSecretMember := TRegExpr.Create;
  FSecretMember.ModifierI := True;
  FSecretMember.Expression :=
    '("(?:authorization|proxy-authorization|cookie|set-cookie|x-api-key|x-auth-token|x-csrf-token|' +
    'token|_edge_token|access_token|refresh_token|id_token|password|passwd|pwd|secret|client_secret|' +
    'api_key|apikey)"' + JSON_STRING_VALUE;
  FSecretMember.Compile;

  FBodyMember := TRegExpr.Create;
  FBodyMember.ModifierI := True;
  FBodyMember.Expression := '("(?:body|body_b64)"' + JSON_STRING_VALUE;
  FBodyMember.Compile;

  FQueryPair := TRegExpr.Create;
  FQueryPair.ModifierI := True;
  FQueryPair.Expression :=
    '\b(api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|token|password|passwd|pwd|' +
    'client[_-]?secret|secret|session(?:id)?|sid|auth|signature|sig)=[^&"\s\\]+';
  FQueryPair.Compile;

  FAuthScheme := TRegExpr.Create;
  FAuthScheme.ModifierI := True;
  FAuthScheme.Expression := '\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}';
  FAuthScheme.Compile;
end;

destructor TVDRX_Redactor.Destroy;
begin
  FAuthScheme.Free;
  FQueryPair.Free;
  FBodyMember.Free;
  FSecretMember.Free;
  inherited Destroy;
end;

function TVDRX_Redactor.Redact(const AText: string): string;
begin
  Result := AText;
  if Result = '' then Exit;
  Result := FSecretMember.Replace(Result, '$1"' + REDACTED_MARK + '"', True);
  if FRedactBodies then
    Result := FBodyMember.Replace(Result, '$1"[body redacted]"', True);
  Result := FQueryPair.Replace(Result, '$1=' + REDACTED_MARK, True);
  Result := FAuthScheme.Replace(Result, '$1 ' + REDACTED_MARK, True);
end;

end.
