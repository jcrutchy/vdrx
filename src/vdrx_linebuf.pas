unit vdrx_linebuf;

{$mode ObjFPC}{$H+}

// Splits a byte stream into lines without letting one peer make the daemon hold an
// unbounded amount of memory. Used wherever vdrx reads newline-delimited text from
// something it does not fully control: socket_clients, a supervised process's stdout,
// and the stdin admin console.
//
// A line longer than the limit is DROPPED, not truncated: the bytes already held are
// discarded, everything up to the next newline is skipped, and Feed reports it once so
// the caller can log it (and, for a network peer, disconnect). Truncating would hand the
// bus a mangled line that looks valid. CR bytes are removed wherever they appear and do
// not count toward the limit. Work is O(n) in the bytes fed: the buffer grows by
// doubling up to the limit, never by one character at a time.

interface

uses
  Classes, SysUtils;

const
  VDRX_DEFAULT_MAX_LINE_BYTES = 1048576;      // 1 MiB
  VDRX_MIN_MAX_LINE_BYTES     = 1024;
  VDRX_MAX_MAX_LINE_BYTES     = 67108864;     // 64 MiB

type
  TVDRX_LineBuffer = class
  private
    FMax: Integer;
    FBuf: string;
    FLen: Integer;
    FSkipping: Boolean;
    FDropped: Int64;
  public
    constructor Create(AMaxLineBytes: Integer);
    // Consumes ALen bytes at AData. Every completed line (possibly empty) is appended to
    // ALines. Returns True if at least one line in this call exceeded the limit.
    function Feed(const AData; ALen: Integer; ALines: TStrings): Boolean;
    // Bytes of an unfinished line currently held (never more than the limit).
    property Pending: Integer read FLen;
    // Number of over-long lines dropped so far.
    property Dropped: Int64 read FDropped;
    property MaxLineBytes: Integer read FMax;
  end;

// Clamps a configured limit into the supported range; 0 or less means "use the default".
function VDRX_ClampMaxLineBytes(AValue: Integer): Integer;

implementation

function VDRX_ClampMaxLineBytes(AValue: Integer): Integer;
begin
  if AValue <= 0 then Exit(VDRX_DEFAULT_MAX_LINE_BYTES);
  if AValue < VDRX_MIN_MAX_LINE_BYTES then Exit(VDRX_MIN_MAX_LINE_BYTES);
  if AValue > VDRX_MAX_MAX_LINE_BYTES then Exit(VDRX_MAX_MAX_LINE_BYTES);
  Result := AValue;
end;

constructor TVDRX_LineBuffer.Create(AMaxLineBytes: Integer);
begin
  inherited Create;
  FMax := VDRX_ClampMaxLineBytes(AMaxLineBytes);
  FBuf := '';
  FLen := 0;
  FSkipping := False;
  FDropped := 0;
end;

function TVDRX_LineBuffer.Feed(const AData; ALen: Integer; ALines: TStrings): Boolean;
var
  P: PByte;
  i, NewCap: Integer;
  B: Byte;
  Line: string;
begin
  Result := False;
  P := @AData;
  for i := 0 to ALen - 1 do
  begin
    B := P[i];
    if B = 10 then
    begin
      if FSkipping then
        FSkipping := False
      else
      begin
        SetString(Line, PAnsiChar(Pointer(FBuf)), FLen);
        ALines.Add(Line);
      end;
      FLen := 0;
    end
    else if B <> 13 then
    begin
      if FSkipping then Continue;
      if FLen >= FMax then
      begin
        FSkipping := True;
        FLen := 0;
        Inc(FDropped);
        Result := True;
        Continue;
      end;
      if FLen >= Length(FBuf) then
      begin
        NewCap := Length(FBuf) * 2;
        if NewCap < 256 then NewCap := 256;
        if NewCap > FMax then NewCap := FMax;
        SetLength(FBuf, NewCap);
      end;
      Inc(FLen);
      FBuf[FLen] := Chr(B);
    end;
  end;
  // Give the memory back after a very large line instead of pinning it for the
  // lifetime of the connection.
  if (FLen = 0) and (Length(FBuf) > 65536) then FBuf := '';
end;

end.
