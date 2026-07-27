unit vdrx_plague;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Math, fpjson, jsonparser, vdrx_core, vdrx_config;

type
  // Single active game, no lobby/multi-table support - matches "just the
  // basic game" scope. If multi-table ever gets asked for, the natural cut
  // is the same one Whiteboard already made for boards: key FState by a
  // game id instead of holding exactly one. Deliberately not doing that yet.

  { TVDRX_PlagueExecutive }

  TVDRX_PlagueExecutive = class(TVDRX_Executive)
  private
    FLock: TCriticalSection;
    FState: TJSONObject;       // canonical live state, mutated in place - same approach as Whiteboard's FBoards
    FCountries: TJSONObject;   // id -> {name, population, neighbors:[ids]} - loaded once, immutable at runtime
    FDataDir: string;
    FTickThread: TVDRX_WorkerThread;
    FTickMs: Integer;
    FWinFraction: Double;
    FStopping: Boolean;

    procedure LoadCountries(const AFilePath: string);
    function NewGameState: TJSONObject;
    procedure SaveStateToDisk;
    function GetOrCreateCountryState(const ACountryID: string): TJSONObject;
    function CountryPopulation(const ACountryID: string): Int64;

    // -- action handlers, all called with FLock already held --
    procedure DoJoin(const APlayerID: string; AArgs: TJSONObject);
    procedure DoSeedPathogen(const APlayerID: string; AArgs: TJSONObject);
    procedure DoEvolveTrait(const APlayerID: string; AArgs: TJSONObject);
    procedure DoInvestCure(const APlayerID: string; AArgs: TJSONObject);
    procedure DoQuarantine(const APlayerID: string; AArgs: TJSONObject);
    procedure DoSetBorder(const APlayerID: string; AArgs: TJSONObject; AClose: Boolean);
    procedure DoStartGame;

    // -- simulation --
    procedure TickLoop; // runs on FTickThread
    procedure DoTick;
    function TraitCost(ACurrentValue: Double): Double;
    procedure CheckWinConditions;
    function BorderClosed(const AFromID, AToID: string): Boolean;
    procedure PublishDeltaLocked;
  public
    constructor Create(ABus: TVDRX_MessageQueue; const ADataDir: string; AConfig: TVDRX_Config); reintroduce;
    destructor Destroy; override;
    procedure Initialize; override;
    procedure Shutdown; override;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    function GetSnapshot: string; // thread-safe synchronous read, for TVDRX_HTTPExecutive
    function GetCountriesJSON: string; // world geometry/pop/neighbors - immutable after load, no lock needed
  end;

implementation

const
  // Deliberately simple: no SIR curves, no per-trait interaction beyond
  // straight multiplication. Good enough for "basic game"; honest
  // epidemiology can come later as a deferred upgrade, same spirit as the
  // per-connection mailbox note in WIRING.md.
  // BUG FIX (found live-testing): the original formula scaled new infections
  // off the whole susceptible population, independent of how many people
  // actually carry the disease - with 1 case in a 331M-population country
  // that computed ~650,000 new infections on the very first tick,
  // regardless of infectivity. An epidemic's growth rate has to be driven
  // by its current carrier count (classic SIR beta*I*S/N shape), not just
  // by how many people are theoretically available to catch it.
  ContactsPerInfectedPerTick = 15.0; // effective exposures one carrier generates per tick, at infectivity=100
  BaseDeathRate = 0.01;         // fraction of infected who die per tick, at lethality=100
  BaseCrossBorderChance = 0.05; // chance per tick an uninfected neighbor gets seeded, at infectivity=100
  BaseCureRatePerPoint = 0.5;   // cure_progress gained per invested point, before diminishing returns
  EvolutionPointsPerInfected = 0.002; // passive trickle, per infected person worldwide, per tick
  TraitMax = 100.0;

{ TVDRX_PlagueExecutive }

constructor TVDRX_PlagueExecutive.Create(ABus: TVDRX_MessageQueue; const ADataDir: string; AConfig: TVDRX_Config);
begin
  inherited Create(ABus);
  FLock := TCriticalSection.Create;
  if ADataDir <> '' then
    FDataDir := ADataDir
  else
    FDataDir := 'vdrx_data' + PathDelim + 'plague';
  ForceDirectories(FDataDir);

  FTickMs := 3000;
  FWinFraction := 0.85; // config unit has no GetFloat yet - left a compiled-in constant
                          // rather than half-wiring a config path that would silently
                          // truncate fractional values via GetInteger.
  if Assigned(AConfig) then
  begin
    FTickMs := AConfig.GetInteger('executives.plague.tick_ms', FTickMs);
    LoadCountries(AConfig.GetString('executives.plague.countries_file', 'plague_countries.json'));
  end
  else
    LoadCountries('plague_countries.json');

  FState := NewGameState;
end;

destructor TVDRX_PlagueExecutive.Destroy;
begin
  FState.Free;
  FCountries.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TVDRX_PlagueExecutive.LoadCountries(const AFilePath: string);
var
  SL: TStringList;
  J: TJSONData;
  Raw: TJSONObject;
  i: Integer;
begin
  FCountries := TJSONObject.Create;
  if not FileExists(AFilePath) then
  begin
    Bus.Publish('log.warn', 'plague: countries file "' + AFilePath + '" not found - starting with an empty world', 'plague');
    Exit;
  end;
  SL := TStringList.Create;
  try
    SL.LoadFromFile(AFilePath);
    try
      J := GetJSON(SL.Text);
      if J is TJSONObject then
      begin
        // Every downstream loop (DoTick, CheckWinConditions, ...) hard-casts
        // FCountries.Items[i] straight to TJSONObject with no type check -
        // fast and simple as long as that assumption holds. It doesn't hold
        // for free-form caller-edited JSON: a stray non-object entry (a
        // "_comment" string field, for instance) passes GetJSON fine but
        // blows up the first time the tick thread indexes into it, and does
        // so on every tick from then on since the file never changes. Filter
        // once here, at the one place external data enters the process,
        // instead of defending every consumer.
        Raw := TJSONObject(J);
        for i := Raw.Count - 1 downto 0 do
          if not (Raw.Items[i] is TJSONObject) then
          begin
            Bus.Publish('log.warn', 'plague: countries file entry "' + Raw.Names[i] +
              '" is not an object (got ' + Raw.Items[i].ClassName + ') - skipped', 'plague');
            Raw.Delete(i);
          end;
        FCountries.Free;
        FCountries := Raw;
      end
      else
      begin
        J.Free;
        Bus.Publish('log.error', 'plague: countries file did not contain a JSON object - starting empty', 'plague');
      end;
    except
      on E: Exception do
        Bus.Publish('log.error', 'plague: failed to parse countries file: ' + E.Message, 'plague');
    end;
  finally
    SL.Free;
  end;
end;

// Expected countries.json shape (caller-supplied, see plague_countries.json.example):
// {
//   "usa": {"name": "United States", "population": 331000000, "neighbors": ["canada","mexico"]},
//   "canada": {"name": "Canada", "population": 38000000, "neighbors": ["usa"]},
//   ...
// }
// "points"/"polygon" keys, if present, are ignored server-side - client-only.

function TVDRX_PlagueExecutive.NewGameState: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('status', 'lobby'); // lobby -> running -> ended
  Result.Add('winner', '');
  Result.Add('players', TJSONObject.Create);
  Result.Add('pathogens', TJSONObject.Create);
  Result.Add('countries', TJSONObject.Create);       // id -> {pathogens:{pid->{infected,dead,immune}}, quarantine:0}
  Result.Add('closed_borders', TJSONArray.Create);    // ["fromId>toId", ...] - both directions added on close
end;

procedure TVDRX_PlagueExecutive.SaveStateToDisk;
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.Text := FState.AsJSON;
    SL.SaveToFile(IncludeTrailingPathDelimiter(FDataDir) + 'game.json');
  finally
    SL.Free;
  end;
end;

function TVDRX_PlagueExecutive.GetOrCreateCountryState(const ACountryID: string): TJSONObject;
var
  Countries: TJSONObject;
begin
  Countries := TJSONObject(FState.Objects['countries']);
  Result := TJSONObject(Countries.Find(ACountryID));
  if not Assigned(Result) then
  begin
    Result := TJSONObject.Create;
    Result.Add('pathogens', TJSONObject.Create);
    Result.Add('quarantine', 0.0);
    Countries.Add(ACountryID, Result);
  end;
end;

function TVDRX_PlagueExecutive.CountryPopulation(const ACountryID: string): Int64;
var
  Entry: TJSONObject;
begin
  Result := 0;
  Entry := TJSONObject(FCountries.Find(ACountryID));
  if Assigned(Entry) then
    Result := Entry.Get('population', Int64(0));
end;

procedure TVDRX_PlagueExecutive.Initialize;
begin
  FStopping := False;
  FTickThread := TVDRX_WorkerThread.Create(@TickLoop);
  FTickThread.Start;
end;

procedure TVDRX_PlagueExecutive.Shutdown;
begin
  FStopping := True;
  if Assigned(FTickThread) then
  begin
    FTickThread.WaitFor; // TickLoop polls FStopping every 200ms - bounded wait, no timeout helper needed
    FreeAndNil(FTickThread);
  end;
end;

procedure TVDRX_PlagueExecutive.TickLoop;
var
  Waited: Integer;
begin
  // Polls FStopping in short slices rather than one long Sleep(FTickMs) so
  // Shutdown doesn't have to wait out a full tick interval to return - same
  // "don't stall a graceful stop" reasoning as WaitThreadOrTimeout elsewhere
  // in this codebase, just simpler since there's no child process to signal.
  while not FStopping do
  begin
    Waited := 0;
    while (not FStopping) and (Waited < FTickMs) do
    begin
      Sleep(200);
      Inc(Waited, 200);
    end;
    if FStopping then Break;
    FLock.Enter;
    try
      // TVDRX_WorkerThread.Execute (vdrx_core.pas) has no exception guard of
      // its own - an unhandled exception here doesn't crash the daemon, it
      // just silently kills this thread, and the game freezes forever with
      // no error anywhere. Found that the hard way: a single non-object
      // entry in a caller-supplied countries file (see LoadCountries) took
      // the tick thread out on the very first tick with zero log output.
      // Catching here means a bad tick gets logged and skipped instead of
      // quietly ending the game.
      if FState.Get('status', '') = 'running' then
        try
          DoTick;
        except
          on E: Exception do
            Bus.Publish('log.error', 'plague: DoTick raised ' + E.ClassName + ': ' + E.Message +
              ' - this tick was skipped, simulation continues', ID);
        end;
    finally
      FLock.Leave;
    end;
  end;
end;

function TVDRX_PlagueExecutive.TraitCost(ACurrentValue: Double): Double;
begin
  // Rising marginal cost - same shape as Plague Inc's own trait pricing,
  // just linear instead of tiered: cheap early, expensive once a trait is
  // already high.
  Result := 1.0 + (ACurrentValue / 10.0);
end;

function TVDRX_PlagueExecutive.BorderClosed(const AFromID, AToID: string): Boolean;
var
  Arr: TJSONArray;
  i: Integer;
  Key: string;
begin
  Result := False;
  Arr := TJSONArray(FState.Arrays['closed_borders']);
  Key := AFromID + '>' + AToID;
  for i := 0 to Arr.Count - 1 do
    if Arr.Strings[i] = Key then Exit(True);
end;

// -- Actions --------------------------------------------------------------

procedure TVDRX_PlagueExecutive.DoJoin(const APlayerID: string; AArgs: TJSONObject);
var
  Players, P: TJSONObject;
  Role: string;
begin
  Role := AArgs.Get('role', '');
  if (Role <> 'infector') and (Role <> 'defender') then
  begin
    Bus.Publish('log.warn', 'plague: join with invalid role "' + Role + '" from ' + APlayerID, ID);
    Exit;
  end;
  Players := TJSONObject(FState.Objects['players']);
  if Assigned(Players.Find(APlayerID)) then
    Players.Delete(APlayerID); // re-join replaces prior entry (e.g. reconnect) rather than erroring
  P := TJSONObject.Create;
  P.Add('name', AArgs.Get('name', APlayerID));
  P.Add('role', Role);
  Players.Add(APlayerID, P);
end;

// One pathogen per infector, seeded into exactly one starting country
// (patient zero). Re-seeding an already-seeded pathogen is a no-op, not an
// error - keeps this idempotent if a client retries the request.
procedure TVDRX_PlagueExecutive.DoSeedPathogen(const APlayerID: string; AArgs: TJSONObject);
var
  Players, Pathogens, Pathogen, CountryState, PathogenCounts: TJSONObject;
  CountryID: string;
begin
  Players := TJSONObject(FState.Objects['players']);
  if not (Assigned(Players.Find(APlayerID)) and (TJSONObject(Players.Objects[APlayerID]).Get('role', '') = 'infector')) then
    Exit;

  CountryID := AArgs.Get('country_id', '');
  if not Assigned(FCountries.Find(CountryID)) then
  begin
    Bus.Publish('log.warn', 'plague: seed request for unknown country "' + CountryID + '"', ID);
    Exit;
  end;

  Pathogens := TJSONObject(FState.Objects['pathogens']);
  if Assigned(Pathogens.Find(APlayerID)) then Exit; // already seeded - pathogen id == owning player id, one-to-one

  Pathogen := TJSONObject.Create;
  Pathogen.Add('owner', APlayerID);
  Pathogen.Add('name', AArgs.Get('name', 'Pathogen'));
  Pathogen.Add('infectivity', 10.0);
  Pathogen.Add('lethality', 5.0);
  Pathogen.Add('evolution_points', 0.0);
  Pathogen.Add('cure_progress', 0.0);
  Pathogen.Add('eradicated', False);
  Pathogens.Add(APlayerID, Pathogen);

  CountryState := GetOrCreateCountryState(CountryID);
  PathogenCounts := TJSONObject.Create;
  PathogenCounts.Add('infected', Int64(1));
  PathogenCounts.Add('dead', Int64(0));
  PathogenCounts.Add('immune', Int64(0));
  TJSONObject(CountryState.Objects['pathogens']).Add(APlayerID, PathogenCounts);
end;

procedure TVDRX_PlagueExecutive.DoEvolveTrait(const APlayerID: string; AArgs: TJSONObject);
var
  Pathogens, Pathogen: TJSONObject;
  Trait: string;
  Cur, Cost, Points: Double;
begin
  Pathogens := TJSONObject(FState.Objects['pathogens']);
  Pathogen := TJSONObject(Pathogens.Find(APlayerID));
  if not Assigned(Pathogen) then Exit;
  if Pathogen.Get('eradicated', False) then Exit;

  Trait := AArgs.Get('trait', '');
  if (Trait <> 'infectivity') and (Trait <> 'lethality') then Exit;

  Cur := Pathogen.Floats[Trait];
  if Cur >= TraitMax then Exit;
  Cost := TraitCost(Cur);
  Points := Pathogen.Floats['evolution_points'];
  if Points < Cost then
  begin
    Bus.Publish('log.info', 'plague: ' + APlayerID + ' short on evolution points for ' + Trait, ID);
    Exit;
  end;

  Pathogen.Floats['evolution_points'] := Points - Cost;
  Pathogen.Floats[Trait] := Min(TraitMax, Cur + 1.0);
end;

// Defender action, but pooled - not owner-scoped like a pathogen. Any
// defender can invest in any pathogen's cure; there's no per-defender point
// budget yet (deferred), so this is trust-based between defender players
// for now, same spirit as vdrx_admincmd.pas not yet doing RBAC.
procedure TVDRX_PlagueExecutive.DoInvestCure(const APlayerID: string; AArgs: TJSONObject);
var
  Players, Pathogens, Pathogen: TJSONObject;
  PathogenID: string;
  Amount, Cur: Double;
begin
  Players := TJSONObject(FState.Objects['players']);
  if not (Assigned(Players.Find(APlayerID)) and (TJSONObject(Players.Objects[APlayerID]).Get('role', '') = 'defender')) then
    Exit;

  PathogenID := AArgs.Get('pathogen_id', '');
  Pathogens := TJSONObject(FState.Objects['pathogens']);
  Pathogen := TJSONObject(Pathogens.Find(PathogenID));
  if not Assigned(Pathogen) then Exit;
  if Pathogen.Get('eradicated', False) then Exit;

  Amount := AArgs.Get('amount', 0.0);
  if Amount <= 0 then Exit;
  Cur := Pathogen.Floats['cure_progress'];
  // Diminishing returns as progress climbs, same reasoning as TraitCost but
  // inverted - keeps a late cure from being trivially rushed by one big
  // deposit right at the end.
  Pathogen.Floats['cure_progress'] := Min(100.0, Cur + Amount * BaseCureRatePerPoint * (1.0 - Cur / 200.0));
end;

procedure TVDRX_PlagueExecutive.DoQuarantine(const APlayerID: string; AArgs: TJSONObject);
var
  Players: TJSONObject;
  CountryState: TJSONObject;
  CountryID: string;
  Level: Double;
begin
  Players := TJSONObject(FState.Objects['players']);
  if not (Assigned(Players.Find(APlayerID)) and (TJSONObject(Players.Objects[APlayerID]).Get('role', '') = 'defender')) then
    Exit;

  CountryID := AArgs.Get('country_id', '');
  if not Assigned(FCountries.Find(CountryID)) then Exit;
  Level := Max(0.0, Min(100.0, AArgs.Get('level', 0.0)));

  CountryState := GetOrCreateCountryState(CountryID);
  CountryState.Floats['quarantine'] := Level;
end;

procedure TVDRX_PlagueExecutive.DoSetBorder(const APlayerID: string; AArgs: TJSONObject; AClose: Boolean);
var
  Players: TJSONObject;
  FromID, ToID, KeyFwd, KeyBack: string;
  Arr: TJSONArray;
  i: Integer;
begin
  Players := TJSONObject(FState.Objects['players']);
  if not (Assigned(Players.Find(APlayerID)) and (TJSONObject(Players.Objects[APlayerID]).Get('role', '') = 'defender')) then
    Exit;

  FromID := AArgs.Get('from_id', '');
  ToID := AArgs.Get('to_id', '');
  if (FromID = '') or (ToID = '') then Exit;
  KeyFwd := FromID + '>' + ToID;
  KeyBack := ToID + '>' + FromID;

  Arr := TJSONArray(FState.Arrays['closed_borders']);
  if AClose then
  begin
    if not BorderClosed(FromID, ToID) then Arr.Add(KeyFwd);
    if not BorderClosed(ToID, FromID) then Arr.Add(KeyBack);
  end
  else
    for i := Arr.Count - 1 downto 0 do
      if (Arr.Strings[i] = KeyFwd) or (Arr.Strings[i] = KeyBack) then Arr.Delete(i);
end;

procedure TVDRX_PlagueExecutive.DoStartGame;
begin
  if FState.Get('status', '') <> 'lobby' then Exit;
  if TJSONObject(FState.Objects['pathogens']).Count = 0 then
  begin
    Bus.Publish('log.warn', 'plague: start_game requested with no pathogens seeded yet', ID);
    Exit;
  end;
  FState.Strings['status'] := 'running';
end;

// -- Simulation -------------------------------------------------------------

procedure TVDRX_PlagueExecutive.DoTick;
var
  Pathogens, Countries: TJSONObject;
  PathogenID, CountryID, NeighborID: string;
  Pathogen, CountryState, NeighborState, PCounts, NCounts: TJSONObject;
  NeighborsArr: TJSONArray;
  CountryIDs: TStringArray;
  i, j, k: Integer;
  Infectivity, Lethality, Quarantine: Double;
  Infected, Dead, Immune, Population, Susceptible: Int64;
  NewInfections, NewDeaths, TotalInfectedWorldwide: Int64;
begin
  Pathogens := TJSONObject(FState.Objects['pathogens']);
  Countries := TJSONObject(FState.Objects['countries']);

  for i := 0 to Pathogens.Count - 1 do
  begin
    PathogenID := Pathogens.Names[i];
    Pathogen := TJSONObject(Pathogens.Items[i]);
    if Pathogen.Get('eradicated', False) then Continue;

    // Cure crossing 100 this tick: convert every remaining case for this
    // pathogen to immune and mark eradicated. Simple and final - no relapse.
    if Pathogen.Floats['cure_progress'] >= 100.0 then
    begin
      for j := 0 to Countries.Count - 1 do
      begin
        CountryState := TJSONObject(Countries.Items[j]);
        PCounts := TJSONObject(TJSONObject(CountryState.Objects['pathogens']).Find(PathogenID));
        if Assigned(PCounts) then
        begin
          PCounts.Int64s['immune'] := PCounts.Int64s['immune'] + PCounts.Int64s['infected'];
          PCounts.Int64s['infected'] := 0;
        end;
      end;
      Pathogen.Booleans['eradicated'] := True;
      Continue;
    end;
    Infectivity := Pathogen.Floats['infectivity'];
    Lethality := Pathogen.Floats['lethality'];
    TotalInfectedWorldwide := 0;

    // Snapshot country ids up front - the cross-border seeding step below
    // can add new entries to Countries, and mutating a TJSONObject while
    // iterating it by index is asking for trouble.
    SetLength(CountryIDs, Countries.Count);
    for j := 0 to Countries.Count - 1 do
      CountryIDs[j] := Countries.Names[j];
    for j := 0 to High(CountryIDs) do
    begin
      CountryID := CountryIDs[j];
      CountryState := TJSONObject(Countries.Find(CountryID));
      if not Assigned(CountryState) then Continue; // shouldn't happen, defensive only
      PCounts := TJSONObject(TJSONObject(CountryState.Objects['pathogens']).Find(PathogenID));
      if not Assigned(PCounts) then Continue; // no cases of this pathogen here
      Infected := PCounts.Get('infected', Int64(0));
      Dead := PCounts.Get('dead', Int64(0));
      Immune := PCounts.Get('immune', Int64(0));
      if Infected <= 0 then Continue;
      Quarantine := CountryState.Get('quarantine', 0.0);
      Population := CountryPopulation(CountryID);
      Susceptible := Population - Infected - Dead - Immune;
      if Susceptible < 0 then Susceptible := 0;

      NewInfections := Trunc(Infected * ContactsPerInfectedPerTick * (Infectivity / TraitMax) *
        (Susceptible / Max(Int64(1), Population)) * (1.0 - Quarantine / 100.0));
      if NewInfections > Susceptible then NewInfections := Susceptible;
      NewDeaths := Trunc(Infected * BaseDeathRate * (Lethality / TraitMax));
      if NewDeaths > Infected then NewDeaths := Infected;

      Infected := Infected + NewInfections - NewDeaths;
      if Infected < 0 then Infected := 0;
      Dead := Dead + NewDeaths;
      PCounts.Int64s['infected'] := Infected;
      PCounts.Int64s['dead'] := Dead;
      PCounts.Int64s['immune'] := Immune;
      Inc(TotalInfectedWorldwide, Infected);

      // Cross-border seeding: each uninfected, unblocked neighbor has a
      // chance (scaled by infectivity) to pick up one imported case.
      NeighborState := TJSONObject(FCountries.Find(CountryID));
      if Assigned(NeighborState) and (NeighborState.Find('neighbors') is TJSONArray) then
      begin
        NeighborsArr := TJSONArray(NeighborState.Arrays['neighbors']);
        for k := 0 to NeighborsArr.Count - 1 do
        begin
          NeighborID := NeighborsArr.Strings[k];
          if BorderClosed(CountryID, NeighborID) then Continue;

          NCounts := nil;
          if Assigned(TJSONObject(Countries.Find(NeighborID))) then
            NCounts := TJSONObject(TJSONObject(TJSONObject(Countries.Objects[NeighborID]).Objects['pathogens']).Find(PathogenID));
          if Assigned(NCounts) and (NCounts.Get('infected', Int64(0)) > 0) then
            Continue; // already has active cases there

          if Random < (BaseCrossBorderChance * (Infectivity / TraitMax)) then
          begin
            NCounts := TJSONObject.Create;
            NCounts.Add('infected', Int64(1));
            NCounts.Add('dead', Int64(0));
            NCounts.Add('immune', Int64(0));
            TJSONObject(GetOrCreateCountryState(NeighborID).Objects['pathogens']).Add(PathogenID, NCounts);
          end;
        end;
      end;
    end;
    Pathogen.Floats['evolution_points'] := Pathogen.Floats['evolution_points']
      + TotalInfectedWorldwide * EvolutionPointsPerInfected;
  end;
  CheckWinConditions;
  SaveStateToDisk;
  PublishDeltaLocked;
end;

// World-population fraction infected+dead, for one pathogen, across every
// country FCountries knows about (not just ones it's currently in) - that's
// the honest denominator for "how much of the world has this hit".
procedure TVDRX_PlagueExecutive.CheckWinConditions;
var
  Pathogens, Countries: TJSONObject;
  i, j: Integer;
  PathogenID: string;
  Pathogen, CountryState, PCounts: TJSONObject;
  WorldPop, HitCount: Int64;
  AllEradicated: Boolean;
begin
  if FState.Get('status', '') <> 'running' then Exit;

  WorldPop := 0;
  for i := 0 to FCountries.Count - 1 do
    WorldPop := WorldPop + TJSONObject(FCountries.Items[i]).Get('population', Int64(0));
  if WorldPop <= 0 then Exit; // no world loaded - nothing to check yet

  Pathogens := TJSONObject(FState.Objects['pathogens']);
  Countries := TJSONObject(FState.Objects['countries']);
  AllEradicated := Pathogens.Count > 0;

  for i := 0 to Pathogens.Count - 1 do
  begin
    PathogenID := Pathogens.Names[i];
    Pathogen := TJSONObject(Pathogens.Items[i]);
    if not Pathogen.Get('eradicated', False) then
      AllEradicated := False;

    HitCount := 0;
    for j := 0 to Countries.Count - 1 do
    begin
      CountryState := TJSONObject(Countries.Items[j]);
      PCounts := TJSONObject(TJSONObject(CountryState.Objects['pathogens']).Find(PathogenID));
      if Assigned(PCounts) then
        HitCount := HitCount + PCounts.Get('infected', Int64(0)) + PCounts.Get('dead', Int64(0));
    end;
    if (WorldPop > 0) and (HitCount / WorldPop >= FWinFraction) then
    begin
      FState.Strings['status'] := 'ended';
      FState.Strings['winner'] := 'infector:' + Pathogen.Get('owner', PathogenID);
      Exit;
    end;
  end;

  if AllEradicated then
  begin
    FState.Strings['status'] := 'ended';
    FState.Strings['winner'] := 'defenders';
  end;
end;

// Full-state broadcast every tick, not a computed diff. Simpler and, given
// this is one lobby's worth of countries/pathogens (tens to low hundreds of
// entries, not thousands), cheap enough over a local WS connection - a real
// delta encoding is a legitimate future optimization, not a correctness
// issue, so it's deferred rather than half-built here.
procedure TVDRX_PlagueExecutive.PublishDeltaLocked;
begin
  Bus.Publish('plague.delta', FState.AsJSON, ID);
end;

procedure TVDRX_PlagueExecutive.HandlePacket(const AMsg: TVDRX_Message);
var
  J: TJSONData;
  Action, PlayerID: string;
  Args: TJSONObject;
begin
  if AMsg.Topic <> 'plague.action' then Exit;
  FLock.Enter;
  try
    try
      J := GetJSON(AMsg.Payload);
      try
        if not (J is TJSONObject) then Exit;
        Args := TJSONObject(J);
        Action := Args.Get('type', '');
        PlayerID := Args.Get('player_id', '');
        if (PlayerID = '') and (Action <> 'start_game') then Exit;

        if Action = 'join' then DoJoin(PlayerID, Args)
        else if Action = 'seed_pathogen' then DoSeedPathogen(PlayerID, Args)
        else if Action = 'evolve_trait' then DoEvolveTrait(PlayerID, Args)
        else if Action = 'invest_cure' then DoInvestCure(PlayerID, Args)
        else if Action = 'quarantine' then DoQuarantine(PlayerID, Args)
        else if Action = 'close_border' then DoSetBorder(PlayerID, Args, True)
        else if Action = 'open_border' then DoSetBorder(PlayerID, Args, False)
        else if Action = 'start_game' then DoStartGame
        else
          Bus.Publish('log.warn', 'plague: unknown action type "' + Action + '"', ID);

        SaveStateToDisk;
        PublishDeltaLocked;
      finally
        J.Free;
      end;
    except
      on E: Exception do
        Bus.Publish('log.error', 'plague: malformed action payload: ' + E.Message, ID);
    end;
  finally
    FLock.Leave;
  end;
end;

function TVDRX_PlagueExecutive.GetSnapshot: string;
begin
  FLock.Enter;
  try
    Result := FState.AsJSON;
  finally
    FLock.Leave;
  end;
end;

function TVDRX_PlagueExecutive.GetCountriesJSON: string;
begin
  // FCountries is populated once in Create (LoadCountries) and never
  // mutated afterwards, unlike FState - no FLock needed here.
  Result := FCountries.AsJSON;
end;

end.

