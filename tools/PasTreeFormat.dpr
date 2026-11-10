program PasTreeFormat;

{
  The formatter (PasTree.Format) over a corpus, held to its gates. Every
  .pas/.dpr/.dpk under a directory - or one file - is preprocessed and
  parsed as PasTreePrint does it; each file that parses clean is formatted
  with the default style and judged three times:

  - G-tok: the output holds the input's tokens, whitespace aside (a comment,
    a directive and an inactive branch byte for byte);
  - G-idem: formatting the output again changes nothing;
  - G-tree: the output parses clean to the same tree (TreeFingerprint).

  And measured (G-rtl, the tuning metric of the default style): the gaps
  the format changed - those that only moved a line's indentation, those
  that got a line break they did not have, and those that lost blank lines -
  and the lines of the corpus, so a style's distance from the corpus reads
  as one rate.

  Usage:
    PasTreeFormat <root-dir|file> [-p:<platform>] [-max:<n>] [-out:<dir>]
    PasTreeFormat <file> -print [-p:<platform>]

  -out writes every formatted file under <dir>, at its path relative to the
  root, for a diff against the corpus. -print writes one file's format to
  stdout and nothing else.

  Exit code: 0 every gate held, 1 a gate failed, 2 usage or I/O error.
}

{$APPTYPE CONSOLE}
{$MAXSTACKSIZE $01000000}   // 16 MB per thread: README, "The stack every host should reserve"

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Diagnostics,
  System.Generics.Collections,
  System.Generics.Defaults,
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Lexer in '..\source\PasTree.Lexer.pas',
  PasTree.SourceManager in '..\source\PasTree.SourceManager.pas',
  PasTree.Dcu in '..\source\PasTree.Dcu.pas',
  PasTree.Dcu.Source in '..\source\PasTree.Dcu.Source.pas',
  PasTree.Preprocessor in '..\source\PasTree.Preprocessor.pas',
  PasTree.Platforms in '..\source\PasTree.Platforms.pas',
  PasTree.Ast in '..\source\PasTree.Ast.pas',
  PasTree.Ast.Check in '..\source\PasTree.Ast.Check.pas',
  PasTree.Parser in '..\source\PasTree.Parser.pas',
  PasTree.Printer in '..\source\PasTree.Printer.pas',
  PasTree.Format in '..\source\PasTree.Format.pas';

type
  TTotals = record
    Files, Clean, Exceptions, Lines: Int64;
    Changed, Edits, IndentOnly, BreakAdded, BlankDropped: Int64;
    SpaceEdits, CaseEdits: Int64;
    TokFail, IdemFail, TreeFail: Int64;
  end;

var
  GTotals: TTotals;
  GPP: TPasPreprocessor;
  GMax: Integer = 200;
  GPrinted: Integer;
  GOutDir, GRoot: string;
  GWordsMode, GHistMode: Boolean;
  GWords: TDictionary<string, Int64>;

procedure Report(const AFile, AGate, AMsg: string);
begin
  if GPrinted < GMax then
    Writeln(AFile, ': ', AGate, ': ', AMsg);
  Inc(GPrinted);
end;

function Breaks(const AText: string): Integer;
var
  LIdx: Integer;
begin
  Result := 0;
  for LIdx := 1 to Length(AText) do
    if AText[LIdx] = #10 then
      Inc(Result)
    else if (AText[LIdx] = #13) and
      ((LIdx = Length(AText)) or (AText[LIdx + 1] <> #10)) then
      Inc(Result);
end;

function Fingerprint(const AText, AFile: string; out AClean: Boolean): TArray<string>;
var
  LTree: TPasTree;
  LDiags: TArray<TPasParseDiag>;
begin
  LTree := TPasParser.ParseFile(GPP.ProcessText(AFile, AText), LDiags);
  AClean := Length(LDiags) = 0;
  Result := TreeFingerprint(LTree);
end;

// -words: every identifier token a node owns that is no leaf - the words
// the grammar reads as keywords in their place - counted by owner kind and
// spelling, for the case rule of the formatter.
procedure CountWords(const ATree: TPasTree);
var
  LOwn: TPasOwnership;
  LVis, LOwner: Integer;
  LKey: string;
  LCount: Int64;
begin
  LOwn.Build(ATree);
  for LVis := 0 to High(LOwn.Owner) do
  begin
    LOwner := LOwn.Owner[LVis];
    if (LOwner < 0) or (ATree.Source.VisibleKind(LVis) <> tkIdentifier) then
      Continue;
    if ATree.Nodes[LOwner].Kind in [nkIdent, nkIntLit, nkRealLit, nkStrLit,
      nkNilLit, nkCaretChar, nkError, nkMissing] then
      Continue;
    LKey := ATree.KindName(ATree.Nodes[LOwner].Kind) + ' ' +
      LowerCase(ATree.Source.VisibleText(LVis));
    if not GWords.TryGetValue(LKey, LCount) then
      LCount := 0;
    GWords.AddOrSetValue(LKey, LCount + 1);
  end;
end;

// -hist: every edit counted by its kind and the words around it - the word
// before the gap and the one after, lower case - for tuning the default
// style against a corpus (stage F3).
function NeighborWord(const ASource: string; APos: Integer;
  ABackward: Boolean): string;
var
  LEnd: Integer;
begin
  if ABackward then
  begin
    LEnd := APos;                     // 1-based end of the word
    while (LEnd > 0) and CharInSet(ASource[LEnd], [' ', #9, #13, #10]) do
      Dec(LEnd);
    APos := LEnd;
    while (APos > 0) and not CharInSet(ASource[APos], [' ', #9, #13, #10]) and
      (LEnd - APos < 12) do
      Dec(APos);
    Result := Copy(ASource, APos + 1, LEnd - APos);
  end
  else
  begin
    APos := APos + 1;                 // 1-based start
    LEnd := APos;
    while (LEnd <= Length(ASource)) and
      not CharInSet(ASource[LEnd], [' ', #9, #13, #10]) and (LEnd - APos < 12) do
      Inc(LEnd);
    Result := Copy(ASource, APos, LEnd - APos);
  end;
  Result := LowerCase(Result);
end;

procedure CountEdit(const ASource: string; const AEdit: TPasTextEdit;
  const AOld: string);
var
  LKey: string;
  LCount: Int64;
begin
  if Trim(AOld) <> '' then
    LKey := 'case   ' + LowerCase(AOld) + ' -> ' + AEdit.Text
  else if (Breaks(AOld) = 0) and (Breaks(AEdit.Text) = 0) then
    LKey := Format('space  %s|%s  %d->%d', [NeighborWord(ASource, AEdit.Start,
      True), NeighborWord(ASource, AEdit.Start + AEdit.Len, False),
      Length(AOld), Length(AEdit.Text)])
  else if Breaks(AOld) < Breaks(AEdit.Text) then
    LKey := 'break  ' + NeighborWord(ASource, AEdit.Start, True) + ' | ' +
      NeighborWord(ASource, AEdit.Start + AEdit.Len, False)
  else if Breaks(AOld) > Breaks(AEdit.Text) then
    LKey := 'blank'
  else
    LKey := 'indent ' + NeighborWord(ASource, AEdit.Start + AEdit.Len, False);
  if not GWords.TryGetValue(LKey, LCount) then
    LCount := 0;
  GWords.AddOrSetValue(LKey, LCount + 1);
end;

procedure JudgeFile(const AFile: string);
var
  LPre: TPasPreprocessed;
  LTree: TPasTree;
  LDiags: TArray<TPasParseDiag>;
  LEdits, LAgain: TPasTextEdits;
  LSource, LOut, LMsg, LOld: string;
  LFpA, LFpB: TArray<string>;
  LClean: Boolean;
  LIdx: Integer;
begin
  Inc(GTotals.Files);
  try
    LPre := GPP.Process(AFile);
    if Length(LPre.Files) = 0 then
      Exit;
    LTree := TPasParser.ParseFile(LPre, LDiags);
    if (Length(LDiags) > 0) or (Length(LPre.Diagnostics) > 0) then
      Exit;
    Inc(GTotals.Clean);
    if GWordsMode then
    begin
      CountWords(LTree);
      Exit;
    end;
    LSource := LPre.Files[0].Source;
    Inc(GTotals.Lines, Breaks(LSource) + 1);
    LEdits := PasFormatEdits(LTree, 0, TPasFormatOptions.Default);
    LOut := PasApplyEdits(LSource, LEdits);
    if Length(LEdits) > 0 then
      Inc(GTotals.Changed);
    Inc(GTotals.Edits, Length(LEdits));
    for LIdx := 0 to High(LEdits) do
    begin
      LOld := Copy(LSource, LEdits[LIdx].Start + 1, LEdits[LIdx].Len);
      if Trim(LOld) <> '' then
        Inc(GTotals.CaseEdits)       // a token's text: its case
      else if (Breaks(LOld) = 0) and (Breaks(LEdits[LIdx].Text) = 0) then
        Inc(GTotals.SpaceEdits)
      else if Breaks(LOld) = Breaks(LEdits[LIdx].Text) then
        Inc(GTotals.IndentOnly)
      else if Breaks(LOld) < Breaks(LEdits[LIdx].Text) then
        Inc(GTotals.BreakAdded)
      else
        Inc(GTotals.BlankDropped);
      if GHistMode then
        CountEdit(LSource, LEdits[LIdx], LOld);
    end;
    if GOutDir <> '' then
    begin
      LMsg := TPath.Combine(GOutDir, ExtractRelativePath(
        IncludeTrailingPathDelimiter(GRoot), AFile));
      ForceDirectories(TPath.GetDirectoryName(LMsg));
      TFile.WriteAllText(LMsg, LOut, TUTF8Encoding.Create(False));
    end;
    if not PasSameTokens(LSource, LOut, LMsg) then
    begin
      Inc(GTotals.TokFail);
      Report(AFile, 'G-tok', LMsg);
      Exit;
    end;
    // Parsed as the file it replaces: its includes resolve the same.
    LPre := GPP.ProcessText(AFile, LOut);
    LTree := TPasParser.ParseFile(LPre, LDiags);
    LAgain := PasFormatEdits(LTree, 0, TPasFormatOptions.Default);
    if Length(LAgain) > 0 then
    begin
      Inc(GTotals.IdemFail);
      LPre.Files[0].OffsetToLineCol(LAgain[0].Start, LIdx, LIdx);
      Report(AFile, 'G-idem', Format('%d more edits, the first at line %d',
        [Length(LAgain), LIdx]));
    end;
    LFpA := Fingerprint(LSource, AFile, LClean);
    LFpB := Fingerprint(LOut, AFile, LClean);
    if not LClean then
    begin
      Inc(GTotals.TreeFail);
      Report(AFile, 'G-tree', 'the output does not parse clean');
      Exit;
    end;
    if Length(LFpA) <> Length(LFpB) then
    begin
      Inc(GTotals.TreeFail);
      Report(AFile, 'G-tree', Format('%d nodes became %d',
        [Length(LFpA), Length(LFpB)]));
      Exit;
    end;
    for LIdx := 0 to High(LFpA) do
      if LFpA[LIdx] <> LFpB[LIdx] then
      begin
        Inc(GTotals.TreeFail);
        Report(AFile, 'G-tree', LFpA[LIdx] + ' became ' + LFpB[LIdx]);
        Exit;
      end;
  except
    on E: Exception do
    begin
      Inc(GTotals.Exceptions);
      Report(AFile, 'exception', E.ClassName + ': ' + E.Message);
    end;
  end;
end;

function CorpusFiles(const ARoot: string; out ADir: string): TArray<string>;
var
  LAll: TArray<string>;
  LFile, LExt: string;
  LCount: Integer;
begin
  if TFile.Exists(ARoot) then
  begin
    ADir := TPath.GetDirectoryName(TPath.GetFullPath(ARoot));
    Result := [TPath.GetFullPath(ARoot)];
    Exit;
  end;
  ADir := TPath.GetFullPath(ARoot);
  LAll := TDirectory.GetFiles(ADir, '*.*', TSearchOption.soAllDirectories);
  SetLength(Result, Length(LAll));
  LCount := 0;
  for LFile in LAll do
  begin
    LExt := LowerCase(TPath.GetExtension(LFile));
    if (LExt = '.pas') or (LExt = '.dpr') or (LExt = '.dpk') then
    begin
      Result[LCount] := LFile;
      Inc(LCount);
    end;
  end;
  SetLength(Result, LCount);
  TArray.Sort<string>(Result, TIStringComparer.Ordinal);
end;

procedure WithPreprocessor(const ADir: string; APlatform: TPasPlatform;
  const AProc: TProc);
var
  LSM: TPasSourceManager;
  LDefines: TPasDefines;
  LInfo: TPasPlatformInfo;
begin
  LInfo := PlatformInfo(APlatform);
  LSM := TPasSourceManager.Create([]);
  LDefines := CreatePlatformDefines(APlatform);
  GPP := TPasPreprocessor.Create(LSM, LDefines, DEFAULT_COMPILER_VERSION,
    LInfo.PointerBytes, LInfo.ExtendedBytes, LInfo.LongBytes,
    LInfo.ExtendedAlign);
  try
    LSM.BuildIncludeIndex(ADir);
    AProc();
  finally
    FreeAndNil(GPP);
    LDefines.Free;
    LSM.Free;
  end;
end;

procedure PrintOne(const AFile: string; APlatform: TPasPlatform);
var
  LDir: string;
begin
  CorpusFiles(AFile, LDir);
  WithPreprocessor(LDir, APlatform,
    procedure
    var
      LPre: TPasPreprocessed;
      LTree: TPasTree;
      LDiags: TArray<TPasParseDiag>;
    begin
      LPre := GPP.Process(TPath.GetFullPath(AFile));
      LTree := TPasParser.ParseFile(LPre, LDiags);
      Write(PasApplyEdits(LPre.Files[0].Source,
        PasFormatEdits(LTree, 0, TPasFormatOptions.Default)));
    end);
end;

function Pct(A, B: Int64): Double;
begin
  if B = 0 then
    Result := 0
  else
    Result := 100.0 * A / B;
end;

var
  GPlatform: TPasPlatform;
  GArg: string;
  GIdx: Integer;
  GPrintMode: Boolean;
  GWatch: TStopwatch;
  GFiles: TArray<string>;
begin
  try
    GPlatform := pfWin64;
    GPrintMode := False;
    GArg := '';
    for GIdx := 1 to ParamCount do
      if ParamStr(GIdx).StartsWith('-p:', True) then
      begin
        if not TryParsePlatformName(Copy(ParamStr(GIdx), 4, MaxInt), GPlatform) then
        begin
          Writeln('Unknown platform: ', Copy(ParamStr(GIdx), 4, MaxInt));
          Halt(2);
        end;
      end
      else if ParamStr(GIdx).StartsWith('-max:', True) then
        GMax := StrToIntDef(Copy(ParamStr(GIdx), 6, MaxInt), GMax)
      else if ParamStr(GIdx).StartsWith('-out:', True) then
        GOutDir := TPath.GetFullPath(Copy(ParamStr(GIdx), 6, MaxInt))
      else if SameText(ParamStr(GIdx), '-print') then
        GPrintMode := True
      else if SameText(ParamStr(GIdx), '-words') then
        GWordsMode := True
      else if SameText(ParamStr(GIdx), '-hist') then
        GHistMode := True
      else
        GArg := ParamStr(GIdx);
    if GArg = '' then
    begin
      Writeln('Usage: PasTreeFormat <root-dir|file> [-p:<platform>] ' +
        '[-max:<n>] [-out:<dir>] | <file> -print');
      Halt(2);
    end;
    if GPrintMode then
    begin
      PrintOne(GArg, GPlatform);
      Halt(0);
    end;
    GWords := TDictionary<string, Int64>.Create;
    GWatch := TStopwatch.StartNew;
    GFiles := CorpusFiles(GArg, GRoot);
    WithPreprocessor(GRoot, GPlatform,
      procedure
      var
        LFile: string;
      begin
        for LFile in GFiles do
          JudgeFile(LFile);
      end);
    if GWordsMode or GHistMode then
      for GArg in GWords.Keys do
        Writeln(GWords[GArg]:10, '  ', GArg);
    Writeln;
    Writeln(Format('Files: %d, parsed clean: %d, exceptions: %d',
      [GTotals.Files, GTotals.Clean, GTotals.Exceptions]));
    Writeln(Format('Changed: %d files, %d edits over %d lines (%.2f%%): ' +
      '%d indentation only, %d line breaks added, %d with blank lines ' +
      'dropped, %d spacing inside a line, %d case',
      [GTotals.Changed, GTotals.Edits, GTotals.Lines,
       Pct(GTotals.Edits, GTotals.Lines), GTotals.IndentOnly,
       GTotals.BreakAdded, GTotals.BlankDropped, GTotals.SpaceEdits,
       GTotals.CaseEdits]));
    Writeln(Format('Gates: G-tok %d, G-idem %d, G-tree %d failures',
      [GTotals.TokFail, GTotals.IdemFail, GTotals.TreeFail]));
    Writeln(Format('Elapsed: %.1f s', [GWatch.ElapsedMilliseconds / 1000]));
    if (GTotals.TokFail + GTotals.IdemFail + GTotals.TreeFail +
      GTotals.Exceptions) > 0 then
      ExitCode := 1;
  except
    on E: Exception do
    begin
      Writeln('EXCEPTION ', E.ClassName, ': ', E.Message);
      ExitCode := 2;
    end;
  end;
end.
