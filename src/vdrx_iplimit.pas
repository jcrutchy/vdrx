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

  TVDRX_IPExempt = record
    Net: Cardinal;     // host byte order
    Mask: Cardinal;
  end;

  // A set of IPv4 addresses and ranges. Fill it while configuring; after that it is only read, so it
  // needs no lock of its own.
  TVDRX_IPMatcher = class
  private
    FItems: array of TVDRX_IPExempt;
  public
    // "a.b.c.d" or "a.b.c.d/n". False (and nothing added) if it does not parse.
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

function TVDRX_IPMatcher.Add(const ASpec: string): Boolean;
var
  P, Bits: Integer;
  A: string;
  Net, Mask: Cardinal;
begin
  Result := False;
  P := Pos('/', ASpec);
  Bits := 32;
  if P > 0 then
  begin
    A := Trim(Copy(ASpec, 1, P - 1));
    Bits := StrToIntDef(Trim(Copy(ASpec, P + 1, 10)), -1);
    if (Bits < 0) or (Bits > 32) then Exit;
  end
  else
    A := Trim(ASpec);
  if not VDRX_ParseIPv4(A, Net) then Exit;
  if Bits = 0 then Mask := 0 else Mask := Cardinal($FFFFFFFF) shl (32 - Bits);
  SetLength(FItems, Length(FItems) + 1);
  FItems[High(FItems)].Net := Net and Mask;
  FItems[High(FItems)].Mask := Mask;
  Result := True;
end;

function TVDRX_IPMatcher.Matches(const AAddr: string): Boolean;
var
  V: Cardinal;
  i: Integer;
begin
  Result := False;
  if Length(FItems) = 0 then Exit;
  if not VDRX_ParseIPv4(AAddr, V) then Exit;
  for i := 0 to High(FItems) do
    if (V and FItems[i].Mask) = FItems[i].Net then Exit(True);
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
  Result := FTable.Find(AAddr, AIndex);
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
      FTable.AddObject(AAddr, E);
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
      FTable.AddObject(AAddr, E);
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
