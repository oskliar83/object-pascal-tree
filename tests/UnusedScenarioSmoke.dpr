program UnusedScenarioSmoke;

{ FindUnusedSymbols (PasTree.Sema.Lint) over a corpus of small programs,
  each expectation proven by the compiler.

  tests\fixtures\unused\<scenario>\ holds one scenario's units (and its form
  and include files), analyzed alone; tests\fixtures\unused\expected.txt has
  one line per declaration weighed:

    scenario <TAB> file <TAB> line <TAB> name <TAB> truth <TAB> now <TAB> note

  truth is what dcc 37.0 proved (`row!`: a row nothing could reach at run
  time either - no form, no RTTI - so a doubt on it is a gap too). The generator kept outside the repository
  builds each scenario as a program (every unit of it in its `uses`), deletes
  the declaration with its implementation - and, for a row made by rows, the
  rows using it - rebuilds and runs it: `row` - it compiles and runs as
  before without it; `used` - it does not compile; `runtime` - it compiles
  but the program fails or does something else (a form file, RTTI,
  FindClass, dispatch, an overload a call rebinds to). now is what
  FindUnusedSymbols answers today: `none`, `row` (no doubt), `row?` (a row
  with a doubt) or `in-row` (left out as a member of a type that is a row:
  right where the member is dead). The suite asserts `now`, so it stays green, and counts
  where `now` falls short of `truth`: a known gap, the note saying what the
  rule misses. Fixing one is changing its `now`. Every row FindUnusedSymbols
  gives in a fixture unit must be in the file.

  The fixtures use the real RTL and VCL ($(BDS)\source), as the programs
  they stand for do.

  UnusedScenarioSmoke -dump <file>: write every row of the fixture units,
  tab-separated (scenario, file, line, name, kind, how - `in-row` for a
  member left out - doubts), and check
  nothing - the generator's input. }

{$APPTYPE CONSOLE}
{$MAXSTACKSIZE $01000000}

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Platforms in '..\source\PasTree.Platforms.pas',
  PasTree.Project in '..\source\PasTree.Project.pas',
  PasTree.Sema.Model in '..\source\PasTree.Sema.Model.pas',
  PasTree.Sema.Project in '..\source\PasTree.Sema.Project.pas',
  PasTree.Sema.Nav in '..\source\PasTree.Sema.Nav.pas',
  PasTree.Sema.Lint in '..\source\PasTree.Sema.Lint.pas',
  PasTree.TestKit in 'PasTree.TestKit.pas';

var
  GCounter: TPasSuiteCounter;

procedure Ok(const AName: string; ACond: Boolean);
begin
  GCounter.Ok(AName, ACond);
end;

function StudioDir: string;
begin
  Result := ExcludeTrailingPathDelimiter(GetEnvironmentVariable('BDS'));
  if (Result = '') or not TDirectory.Exists(Result) then
    Result := 'C:\Program Files (x86)\Embarcadero\Studio\37.0';
end;

// The library the fixtures compile against: the RTL and VCL sources.
function LibraryDirs: TArray<string>;
var
  LSrc: string;
begin
  LSrc := TPath.Combine(StudioDir, 'source');
  Result := [TPath.Combine(LSrc, 'rtl\sys'), TPath.Combine(LSrc, 'rtl\common'),
    TPath.Combine(LSrc, 'rtl\win'), TPath.Combine(LSrc, 'vcl')];
end;

function Verdict(const ARow: TPasUnusedSymbol; AInRow: Boolean): string;
begin
  if AInRow then
    Result := 'in-row'
  else if ARow.Doubts <> nil then
    Result := 'row?'
  else
    Result := 'row';
end;

const
  cHow: array[TPasUnusedHow] of string = ('unused', 'only-by-unused',
    'only-written');

// One scenario's rows: its directory analyzed alone, so that the same names
// in two scenarios stay apart (a name declared twice is a doubt of its own).
function ScenarioRows(const ADir: string;
  out AInRow: TArray<TPasUnusedSymbol>): TArray<TPasUnusedSymbol>;
var
  LProj: TPasSemaProject;
  LNav: TPasNavigator;
  LMids: TArray<Integer>;
  LSkips: TPasUnusedSkips;
begin
  LProj := TPasSemaProject.Create(pfWin32, LibraryDirs, []);
  LNav := nil;
  try
    LProj.AnalyzeDirectory(ADir);
    LNav := TPasNavigator.Create(LProj);
    LNav.LibraryPaths := LibraryDirs;
    LMids := nil;
    for var LFile in TDirectory.GetFiles(ADir, '*.pas') do
      LMids := LMids + [LProj.ModelIdOf(LFile)];
    Result := FindUnusedSymbols(LNav, LMids, LSkips, AInRow);
  finally
    LNav.Free;
    LProj.Free;
  end;
end;

type
  TScenRow = record
    Scenario: string;
    Row: TPasUnusedSymbol;
    InRow: Boolean;   // left out: a member of a row type
    Seen: Boolean;
  end;

procedure Run(const ADumpFile: string);
var
  LFixDir, LExpFile: string;
  LRows: TArray<TScenRow>;
  LS: TScenRow;
  LOut, LLines, LGapRows: TStringList;
  LF: TArray<string>;
  LKey, LNow, LTruth, LNames: string;
  LTotal, LRight, LGaps, LSerious, LMatch: Integer;
begin
  LFixDir := TPath.GetFullPath(TPath.Combine(ExtractFilePath(ParamStr(0)),
    '..\fixtures\unused'));
  LExpFile := TPath.Combine(LFixDir, 'expected.txt');
  if (ADumpFile = '') and not TFile.Exists(LExpFile) then
  begin
    Ok('unused scenarios: ' + LExpFile + ' exists', False);
    Exit;
  end;
  if not TDirectory.Exists(LibraryDirs[0]) then
  begin
    // The suite needs the Studio's sources; a machine without them cannot
    // build the fixtures' programs either.
    Ok('unused scenarios: the RTL sources at ' + LibraryDirs[0], False);
    Exit;
  end;
  LRows := nil;
  for var LDir in TDirectory.GetDirectories(LFixDir) do
  begin
    var LInRow: TArray<TPasUnusedSymbol>;
    var LShown := ScenarioRows(LDir, LInRow);
    for var LPass := 0 to 1 do
      for var LR in (if LPass = 0 then LShown else LInRow) do
      begin
        LS.Scenario := ExtractFileName(LDir);
        LS.Row := LR;
        LS.InRow := LPass = 1;
        LS.Seen := False;
        LRows := LRows + [LS];
      end;
  end;
  LOut := TStringList.Create;
  LLines := TStringList.Create;
  LGapRows := TStringList.Create;
  try
    if ADumpFile <> '' then
    begin
      for LS in LRows do
        LOut.Add(Format('%s'#9'%s'#9'%d'#9'%s'#9'%d'#9'%s'#9'%s',
          [LS.Scenario, ExtractFileName(LS.Row.FileName), LS.Row.Line,
           LS.Row.Name, Ord(LS.Row.Kind),
           (if LS.InRow then 'in-row' else cHow[LS.Row.How]),
           string.Join(' | ', LS.Row.Doubts)]));
      LOut.WriteBOM := False;
      LOut.SaveToFile(ADumpFile, TEncoding.UTF8);
      Writeln(Length(LRows), ' rows written to ', ADumpFile);
      Exit;
    end;
    LLines.LoadFromFile(LExpFile, TEncoding.UTF8);
    LTotal := 0;
    LRight := 0;
    LGaps := 0;
    LSerious := 0;
    for var LLine in LLines do
    begin
      if (LLine = '') or LLine.StartsWith('#') then
        Continue;
      LF := LLine.Split([#9]);
      if Length(LF) < 6 then
      begin
        Ok('unused scenarios: a well-formed line: ' + LLine, False);
        Continue;
      end;
      Inc(LTotal);
      LTruth := LF[4];
      LNow := 'none';
      LMatch := 0;
      for var LI := 0 to High(LRows) do
        if (LRows[LI].Scenario = LF[0]) and
           SameText(ExtractFileName(LRows[LI].Row.FileName), LF[1]) and
           (LRows[LI].Row.Line = StrToInt(LF[2])) and
           SameText(LRows[LI].Row.Name, LF[3]) then
        begin
          LNow := Verdict(LRows[LI].Row, LRows[LI].InRow);
          LRows[LI].Seen := True;
          Inc(LMatch);
        end;
      LKey := LF[0] + ' ' + LF[3] + ' (' + LF[1] + ':' + LF[2] + ')';
      Ok('unused scenarios: ' + LKey + ' - ' + LF[5] + ', is ' + LNow,
        (LNow = LF[5]) and (LMatch <= 1));
      // Right: a row for a dead one (a doubt allowed; `row!`: nothing could
      // reach it, so no doubt either), no row - or one with a doubt - for
      // one bound at run time, no row for a used one.
      if ((LTruth = 'row!') and (LF[5] = 'row')) or
         (((LTruth = 'row') or (LTruth = 'row!')) and (LF[5] = 'in-row')) or
         ((LTruth = 'row') and (LF[5] <> 'none')) or
         ((LTruth = 'runtime') and (LF[5] <> 'row')) or
         ((LTruth = 'used') and (LF[5] = 'none')) then
        Inc(LRight)
      else
      begin
        Inc(LGaps);
        if (LTruth <> 'row') and (LF[5] = 'row') then
          Inc(LSerious);
        LGapRows.Add('  ' + LKey + ': ' + LTruth + ', now ' + LF[5]);
      end;
    end;
    LNames := '';
    for LS in LRows do
      if not LS.Seen then
        LNames := LNames + ' ' + LS.Scenario + ' ' +
          ExtractFileName(LS.Row.FileName) + ':' + IntToStr(LS.Row.Line) +
          ' ' + LS.Row.Name;
    Ok('unused scenarios: every row is expected (' + LNames + ' )',
      LNames = '');
    Writeln(Format('unused scenarios: %d declarations weighed, %d answered ' +
      'right, %d known gaps (%d a confident row of a used one)',
      [LTotal, LRight, LGaps, LSerious]));
    for var LGap in LGapRows do
      Writeln(LGap);
  finally
    LGapRows.Free;
    LLines.Free;
    LOut.Free;
  end;
end;

begin
  GCounter.Init;
  try
    if (ParamCount = 2) and SameText(ParamStr(1), '-dump') then
      Run(ParamStr(2))
    else
      Run('');
  except
    on E: Exception do
      Ok('unused scenarios: no exception (' + E.ClassName + ': ' + E.Message +
        ')', False);
  end;
  if GCounter.Finish('UnusedScenarioSmoke') then
    ExitCode := 1;
end.
