unit vdrx_iplimit;

{$mode ObjFPC}{$H+}

// Per-client-address limits for listeners that face untrusted networks.
//
//   * MaxPerIP    - connections one address may hold open at once
//   * RatePerSec  - sustained rate of NEW connections from one address (token bucket)
//   * Burst       - bucket size: how many new connections an address may open at once
//   * exempt list - addresses / CIDR ranges that are never limited (monitoring, a trusted proxy ...)
//
// The table of tracked addresses is bounded (MaxTracked). Entries that hold no connection and whose
// bucket has refilled are dropped when room is needed. If the table is still full of live entries
// (an attacker rotating through huge numbers of source addresses), a new address is NOT tracked and is
// let through to the listener's global connection cap - failing closed here would let an attacker deny
// service to everybody, which is worse than not limiting one more address.
//
// Thread safe. Every successful TryAcquire (lvOK) must be paired with exactly one Release.

interface

uses
  Classes, SysUtils, SyncObjs;

type
  TVDRX_LimitVerdict = (lvOK, lvTooManyConns, lvRateExceeded);

  TVDRX_IPEntry = class
  public
    Conns: Integer;                 // connections still in their accept/request phase
    Live: Integer;                  // long-lived connections adopted by a protocol (WebSocket)
    Tokens: Double;
    LastTick: QWord;
  end;

  // An address in the one form everything here works with: 16 bytes, network order. IPv4 is held as its
  // IPv4-mapped IPv6 form (::ffff:a.b.c.d), so one comparison serves both families.
  TVDRX_IP16 = array[0..15] of Byte;

  TVDRX_IPRange = record
    Net: TVDRX_IP16;
    Bits: Integer;     // prefix length, 0..128 (an IPv4 /n is stored as 96 + n)
  end;

  // A set of IPv4 addresses and ranges. Fill it while configuring; after that it is only read, so it
  // needs no lock of its own.
  TVDRX_IPMatcher = class
  private
    FItems: array of TVDRX_IPRange;
  public
    // "a.b.c.d", "a.b.c.d/n", an IPv6 address or "ipv6/n". False (and nothing added) if it does not parse.
    function Add(const ASpec: string): Boolean;
    function Matches(const AAddr: string): Boolean;
    function Count: Integer;
  end;

  TVDRX_IPLimiter = class
  private
    FLock: TCriticalSection;
    FTable: TStringList;            // sorted; Objects[] = TVDRX_IPEntry
    FExempt: TVDRX_IPMatcher;
    FMaxPerIP: Integer;
    FMaxLivePerIP: Integer;
    FRatePerSec: Double;
    FBurst: Integer;
    FMaxTracked: Integer;
    FFakeNow: QWord;
    FUntracked: Integer;
    function Now: QWord;
    procedure Purge(ANow: QWord);
    function FindEntry(const AAddr: string; out AIndex: Integer): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    // Accepts "a.b.c.d" or "a.b.c.d/n". False if it does not parse.
    function AddExempt(const ASpec: string): Boolean;
    function TryAcquire(const AAddr: string): TVDRX_LimitVerdict;
    procedure Release(const AAddr: string);
    // Long-lived connections (WebSocket) outlive the accept thread, so they are counted separately,
    // from the moment the protocol adopts them until it lets go. No rate token is spent: the
    // connection already paid for its accept.
    function TryAcquireLive(const AAddr: string): Boolean;
    procedure ReleaseLive(const AAddr: string);
    function TrackedCount: Integer;
    function OpenFor(const AAddr: string): Integer;
    // Addresses let through untracked because the table was full (diagnostics).
    function UntrackedCount: Integer;
    // Unit tests only: a controllable clock (ms). 0 = real clock.
    procedure SetFakeClock(AMs: QWord);
    // 0 disables the concurrent cap; rate 0 disables the rate limit.
    property MaxPerIP: Integer read FMaxPerIP write FMaxPerIP;
    property MaxLivePerIP: Integer read FMaxLivePerIP write FMaxLivePerIP;
    property RatePerSec: Double read FRatePerSec write FRatePerSec;
    property Burst: Integer read FBurst write FBurst;
    property MaxTracked: Integer read FMaxTracked write FMaxTracked;
  end;

// "1.2.3.4" -> host-order cardinal. False for anything that is not a strict dotted quad.
function VDRX_ParseIPv4(const S: string; out V: Cardinal): Boolean;

// A strict IPv4 or IPv6 address (no zone id, no brackets, no port) -> 16 bytes. IPv4 becomes ::ffff:a.b.c.d.
function VDRX_ParseIP(const S: string; out B: TVDRX_IP16): Boolean;
// The text form vdrx uses everywhere (logs, REMOTE_ADDR, X-Forwarded-For): an IPv4 or IPv4-mapped address as a
// dotted quad, anything else as lower-case RFC 5952 IPv6 text. So a dual-stack socket's ::ffff:1.2.3.4 peer
// is reported, limited and matched as plain 1.2.3.4.
function VDRX_FormatIP(const B: TVDRX_IP16): string;
// What a client's limits and lock-outs are counted against. An IPv4 address counts as itself. An IPv6 address
// counts as its /64, because whoever holds an IPv6 network usually holds the whole /64 (billions of
// billions of addresses) and per-address limits would cost them nothing.
function VDRX_LimitKey(const AAddr: string): string;

implementation

function VDRX_ParseIPv4(const S: string; out V: Cardinal): Boolean;
var
  i, Part, Digits, Dots: Integer;
begin
  Result := False;
  V := 0;
  Part := 0; Digits := 0; Dots := 0;
  if S = '' then Exit;
  for i := 1 to Length(S) + 1 do
  begin
    if (i <= Length(S)) and (S[i] in ['0'..'9']) then
    begin
      Part := Part * 10 + Ord(S[i]) - 48;
      Inc(Digits);
      if (Digits > 3) or (Part > 255) then Exit;
    end
    else if (i > Length(S)) or (S[i] = '.') then
    begin
      if Digits = 0 then Exit;
      V := (V shl 8) or Cardinal(Part);
      Part := 0; Digits := 0;
      if i <= Length(S) then Inc(Dots);
    end
    else
      Exit;
  end;
  Result := Dots = 3;
end;

constructor TVDRX_IPLimiter.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FTable := TStringList.Create;
  FTable.Sorted := True;
  FTable.Duplicates := dupError;
  FTable.CaseSensitive := True;
  FExempt := TVDRX_IPMatcher.Create;
  FMaxPerIP := 64;
  FMaxLivePerIP := 100;
  FRatePerSec := 20;
  FBurst := 100;
  FMaxTracked := 65536;
end;

destructor TVDRX_IPLimiter.Destroy;
var
  i: Integer;
begin
  for i := 0 to FTable.Count - 1 do FTable.Objects[i].Free;
  FTable.Free;
  FExempt.Free;
  FLock.Free;
  inherited Destroy;
end;

function TVDRX_IPLimiter.Now: QWord;
begin
  if FFakeNow <> 0 then Result := FFakeNow else Result := GetTickCount64;
end;

procedure TVDRX_IPLimiter.SetFakeClock(AMs: QWord);
begin
  FLock.Acquire;
  try
    FFakeNow := AMs;
  finally
    FLock.Release;
  end;
end;

function VDRX_ParseIP(const S: string; out B: TVDRX_IP16): Boolean;
var
  V4: Cardinal;
  Head, Tail: array[0..8] of Word;
  NHead, NTail, i, p, Start, Digits, Val, Dots: Integer;
  Tok: string;
  InTail, SeenGap: Boolean;

  function AddGroup(AValue: Word): Boolean;
  begin
    if InTail then begin if NTail >= 8 then Exit(False); Tail[NTail] := AValue; Inc(NTail); end
    else begin if NHead >= 8 then Exit(False); Head[NHead] := AValue; Inc(NHead); end;
    Result := True;
  end;

begin
  Result := False;
  FillChar(B, SizeOf(B), 0);
  if S = '' then Exit;
  if Pos(':', S) = 0 then
  begin
    if not VDRX_ParseIPv4(S, V4) then Exit;
    B[10] := $FF; B[11] := $FF;
    B[12] := V4 shr 24; B[13] := (V4 shr 16) and $FF; B[14] := (V4 shr 8) and $FF; B[15] := V4 and $FF;
    Exit(True);
  end;
  // IPv6: groups of 1-4 hex digits separated by ':', at most one '::', optionally ending in a dotted quad.
  NHead := 0; NTail := 0; InTail := False; SeenGap := False;
  p := 1;
  if (S[1] = ':') then
  begin
    if (Length(S) < 2) or (S[2] <> ':') then Exit;      // a lone leading ':'
    SeenGap := True; InTail := True; p := 3;
    if p > Length(S) then begin Result := True; Exit; end;   // "::"
  end;
  while p <= Length(S) do
  begin
    Start := p;
    while (p <= Length(S)) and (S[p] <> ':') do Inc(p);
    Tok := Copy(S, Start, p - Start);
    if Tok = '' then Exit;
    if Pos('.', Tok) > 0 then
    begin
      if p <= Length(S) then Exit;                        // a dotted quad is only allowed last
      if not VDRX_ParseIPv4(Tok, V4) then Exit;
      if not AddGroup(V4 shr 16) then Exit;
      if not AddGroup(V4 and $FFFF) then Exit;
    end
    else
    begin
      if Length(Tok) > 4 then Exit;
      Val := 0;
      for i := 1 to Length(Tok) do
        case Tok[i] of
          '0'..'9': Val := Val * 16 + Ord(Tok[i]) - 48;
          'a'..'f': Val := Val * 16 + Ord(Tok[i]) - 87;
          'A'..'F': Val := Val * 16 + Ord(Tok[i]) - 55;
        else Exit;
        end;
      if not AddGroup(Val) then Exit;
    end;
    if p <= Length(S) then
    begin
      Inc(p);                                             // past a ':'
      if p > Length(S) then Exit;                         // trailing single ':'
      if S[p] = ':' then
      begin
        if SeenGap then Exit;                             // a second '::'
        SeenGap := True; InTail := True; Inc(p);
        if p > Length(S) then Break;                      // "1::"
      end;
    end;
  end;
  if SeenGap then
  begin
    if NHead + NTail > 7 then Exit;                       // '::' must stand for at least one group
  end
  else if NHead <> 8 then Exit;
  for i := 0 to NHead - 1 do begin B[i * 2] := Head[i] shr 8; B[i * 2 + 1] := Head[i] and $FF; end;
  for i := 0 to NTail - 1 do
  begin
    B[(8 - NTail + i) * 2] := Tail[i] shr 8;
    B[(8 - NTail + i) * 2 + 1] := Tail[i] and $FF;
  end;
  Result := True;
end;

function VDRX_FormatIP(const B: TVDRX_IP16): string;
var
  i, BestStart, BestLen, RunStart, RunLen: Integer;
  G: array[0..7] of Word;
  Mapped: Boolean;
begin
  Mapped := True;
  for i := 0 to 9 do if B[i] <> 0 then Mapped := False;
  if Mapped and (B[10] = $FF) and (B[11] = $FF) then
    Exit(IntToStr(B[12]) + '.' + IntToStr(B[13]) + '.' + IntToStr(B[14]) + '.' + IntToStr(B[15]));
  for i := 0 to 7 do G[i] := (Word(B[i * 2]) shl 8) or B[i * 2 + 1];
  BestStart := -1; BestLen := 0; RunStart := -1; RunLen := 0;
  for i := 0 to 7 do
  begin
    if G[i] = 0 then
    begin
      if RunStart < 0 then begin RunStart := i; RunLen := 0; end;
      Inc(RunLen);
      if RunLen > BestLen then begin BestStart := RunStart; BestLen := RunLen; end;
    end
    else
      RunStart := -1;
  end;
  if BestLen < 2 then BestStart := -1;                    // RFC 5952: never compress a single group
  Result := '';
  i := 0;
  while i < 8 do
  begin
    if i = BestStart then
    begin
      Result := Result + '::';
      Inc(i, BestLen);
      Continue;
    end;
    if (Result <> '') and (Result[Length(Result)] <> ':') then Result := Result + ':';
    Result := Result + LowerCase(IntToHex(G[i], 1));
    Inc(i);
  end;
end;

function VDRX_LimitKey(const AAddr: string): string;
var
  B: TVDRX_IP16;
  i: Integer;
  Mapped: Boolean;
begin
  if not VDRX_ParseIP(AAddr, B) then Exit(AAddr);
  Mapped := True;
  for i := 0 to 9 do if B[i] <> 0 then Mapped := False;
  if Mapped and (B[10] = $FF) and (B[11] = $FF) then Exit(VDRX_FormatIP(B));
  for i := 8 to 15 do B[i] := 0;
  Result := VDRX_FormatIP(B) + '/64';
end;

function TVDRX_IPMatcher.Add(const ASpec: string): Boolean;
var
  P, Bits, MaxBits: Integer;
  A: string;
  B: TVDRX_IP16;
begin
  Result := False;
  P := Pos('/', ASpec);
  Bits := -1;
  if P > 0 then
  begin
    A := Trim(Copy(ASpec, 1, P - 1));
    Bits := StrToIntDef(Trim(Copy(ASpec, P + 1, 10)), -1);
    if Bits < 0 then Exit;
  end
  else
    A := Trim(ASpec);
  if not VDRX_ParseIP(A, B) then Exit;
  // A bare address is a /32 (IPv4) or /128 (IPv6). A prefix length counts in the address's own family.
  if Pos(':', A) > 0 then MaxBits := 128 else MaxBits := 32;
  if Bits < 0 then Bits := MaxBits;
  if Bits > MaxBits then Exit;
  if MaxBits = 32 then Bits := Bits + 96;
  SetLength(FItems, Length(FItems) + 1);
  FItems[High(FItems)].Net := B;
  FItems[High(FItems)].Bits := Bits;
  Result := True;
end;

function TVDRX_IPMatcher.Matches(const AAddr: string): Boolean;
var
  V: TVDRX_IP16;
  i, k, Full, Rest: Integer;
  Ok: Boolean;
begin
  Result := False;
  if Length(FItems) = 0 then Exit;
  if not VDRX_ParseIP(AAddr, V) then Exit;
  for i := 0 to High(FItems) do
  begin
    Full := FItems[i].Bits div 8;
    Rest := FItems[i].Bits mod 8;
    Ok := True;
    for k := 0 to Full - 1 do
      if V[k] <> FItems[i].Net[k] then begin Ok := False; Break; end;
    if Ok and (Rest > 0) then
      Ok := ((V[Full] xor FItems[i].Net[Full]) and ($FF shl (8 - Rest)) and $FF) = 0;
    if Ok then Exit(True);
  end;
end;

function TVDRX_IPMatcher.Count: Integer;
begin
  Result := Length(FItems);
end;

function TVDRX_IPLimiter.AddExempt(const ASpec: string): Boolean;
begin
  FLock.Acquire;
  try
    Result := FExempt.Add(ASpec);
  finally
    FLock.Release;
  end;
end;

function TVDRX_IPLimiter.FindEntry(const AAddr: string; out AIndex: Integer): Boolean;
begin
  Result := FTable.Find(VDRX_LimitKey(AAddr), AIndex);   // IPv6 clients are counted per /64
end;

// Drops entries that hold no connection and have been quiet long enough for their bucket to refill.
// Caller holds FLock.
procedure TVDRX_IPLimiter.Purge(ANow: QWord);
var
  i: Integer;
  E: TVDRX_IPEntry;
  RefillMs: QWord;
begin
  if FRatePerSec > 0 then
    RefillMs := QWord(Round(FBurst / FRatePerSec * 1000)) + 1000
  else
    RefillMs := 1000;
  for i := FTable.Count - 1 downto 0 do
  begin
    E := TVDRX_IPEntry(FTable.Objects[i]);
    if (E.Conns = 0) and (E.Live = 0) and (ANow - E.LastTick >= RefillMs) then
    begin
      E.Free;
      FTable.Delete(i);
    end;
  end;
end;

function TVDRX_IPLimiter.TryAcquire(const AAddr: string): TVDRX_LimitVerdict;
var
  T: QWord;
  Idx: Integer;
  E: TVDRX_IPEntry;
  Add: Double;
begin
  Result := lvOK;
  if (FMaxPerIP <= 0) and (FRatePerSec <= 0) then Exit;
  FLock.Acquire;
  try
    if FExempt.Matches(AAddr) then Exit;
    T := Now;
    if not FindEntry(AAddr, Idx) then
    begin
      if FTable.Count >= FMaxTracked then Purge(T);
      if FTable.Count >= FMaxTracked then
      begin
        Inc(FUntracked);
        Exit;                        // fail open for the per-IP check; the global cap still applies
      end;
      E := TVDRX_IPEntry.Create;
      E.Tokens := FBurst;
      E.LastTick := T;
      FTable.AddObject(VDRX_LimitKey(AAddr), E);
    end
    else
      E := TVDRX_IPEntry(FTable.Objects[Idx]);

    if FRatePerSec > 0 then
    begin
      if T > E.LastTick then
      begin
        Add := (T - E.LastTick) * FRatePerSec / 1000.0;
        E.Tokens := E.Tokens + Add;
        if E.Tokens > FBurst then E.Tokens := FBurst;
      end;
      E.LastTick := T;
      if E.Tokens < 1 then Exit(lvRateExceeded);
    end
    else
      E.LastTick := T;

    if (FMaxPerIP > 0) and (E.Conns >= FMaxPerIP) then Exit(lvTooManyConns);

    if FRatePerSec > 0 then E.Tokens := E.Tokens - 1;
    Inc(E.Conns);
  finally
    FLock.Release;
  end;
end;

procedure TVDRX_IPLimiter.Release(const AAddr: string);
var
  Idx: Integer;
begin
  if (FMaxPerIP <= 0) and (FRatePerSec <= 0) then Exit;
  FLock.Acquire;
  try
    if FindEntry(AAddr, Idx) then
      with TVDRX_IPEntry(FTable.Objects[Idx]) do
        if Conns > 0 then Dec(Conns);
  finally
    FLock.Release;
  end;
end;

function TVDRX_IPLimiter.TryAcquireLive(const AAddr: string): Boolean;
var
  Idx: Integer;
  E: TVDRX_IPEntry;
  T: QWord;
begin
  Result := True;
  if FMaxLivePerIP <= 0 then Exit;
  FLock.Acquire;
  try
    if FExempt.Matches(AAddr) then Exit;
    T := Now;
    if not FindEntry(AAddr, Idx) then
    begin
      if FTable.Count >= FMaxTracked then Purge(T);
      if FTable.Count >= FMaxTracked then
      begin
        Inc(FUntracked);
        Exit;
      end;
      E := TVDRX_IPEntry.Create;
      E.Tokens := FBurst;
      E.LastTick := T;
      FTable.AddObject(VDRX_LimitKey(AAddr), E);
    end
    else
      E := TVDRX_IPEntry(FTable.Objects[Idx]);
    if E.Live >= FMaxLivePerIP then Exit(False);
    Inc(E.Live);
  finally
    FLock.Release;
  end;
end;

procedure TVDRX_IPLimiter.ReleaseLive(const AAddr: string);
var
  Idx: Integer;
begin
  if FMaxLivePerIP <= 0 then Exit;
  FLock.Acquire;
  try
    if FindEntry(AAddr, Idx) then
      with TVDRX_IPEntry(FTable.Objects[Idx]) do
        if Live > 0 then Dec(Live);
  finally
    FLock.Release;
  end;
end;

function TVDRX_IPLimiter.TrackedCount: Integer;
begin
  FLock.Acquire;
  try
    Result := FTable.Count;
  finally
    FLock.Release;
  end;
end;

function TVDRX_IPLimiter.OpenFor(const AAddr: string): Integer;
var
  Idx: Integer;
begin
  Result := 0;
  FLock.Acquire;
  try
    if FindEntry(AAddr, Idx) then Result := TVDRX_IPEntry(FTable.Objects[Idx]).Conns;
  finally
    FLock.Release;
  end;
end;

function TVDRX_IPLimiter.UntrackedCount: Integer;
begin
  FLock.Acquire;
  try
    Result := FUntracked;
  finally
    FLock.Release;
  end;
end;

end.
