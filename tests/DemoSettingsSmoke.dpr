program DemoSettingsSmoke;

{ The demo's persisted settings: the recent-projects list (order, dedup, cap,
  round-trip through the file), the value getters and the [Format] section -
  plus the text arithmetic of the Format / Format Selection commands.

  Worth a suite despite living in the demo, for one reason: none of this is
  checkable by looking at the running program. The list only shows itself when
  a drop-down opens, and the rules that make it useful - most-recent-first,
  one entry per project however it was spelled, a cap that does not leave a
  tail behind in the file - are exactly the ones that break silently. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.IOUtils,
  PasTreeDemo.Settings in '..\demo\PasTreeDemo.Settings.pas',
  PasTreeDemo.Includes in '..\demo\PasTreeDemo.Includes.pas',
  PasTreeDemo.Format in '..\demo\PasTreeDemo.Format.pas',
  PasTree.Format,
  PasTree.TestKit in 'PasTree.TestKit.pas';

var
  GCounter: TPasSuiteCounter;
  GDir: string;

procedure Ok(const AName: string; ACond: Boolean); forward;

{ The include-argument span, asserted as the TEXT it selects - an expected ''
  means "column ACol is not inside an $I argument". Comparing text rather than
  two column numbers is what makes a failure readable. }
procedure CheckSpan(const AName, ALine: string; ACol: Integer;
  const AExpected: string);
var
  LFrom, LTo: Integer;
  LGot: string;
begin
  if TryIncludeArgSpan(ALine, ACol, LFrom, LTo) then
    LGot := Copy(ALine, LFrom, LTo - LFrom + 1)
  else
    LGot := '';
  if LGot = AExpected then
    Ok(AName, True)
  else
  begin
    Ok(AName, False);
    Writeln('    line "', ALine, '" col ', ACol, ': expected "', AExpected,
      '", got "', LGot, '"');
  end;
end;

procedure Ok(const AName: string; ACond: Boolean);
begin
  GCounter.Ok(AName, ACond);
end;

// A real file on disk, so AddRecent's existence-insensitivity and
// ExistingRecent's pruning can be told apart.
function MakeFile(const AName: string): string;
begin
  Result := TPath.Combine(GDir, AName);
  TFile.WriteAllText(Result, '{}');
end;

// Lower-cased, because re-adding an entry stores the spelling just used -
// `AddRecent(UpperCase(P))` leaves the path upper-cased, which is right (it is
// what the user typed) and would otherwise make these comparisons about case.
function Joined(const A: TArray<string>): string;
var
  LIdx: Integer;
begin
  Result := '';
  for LIdx := 0 to High(A) do
    Result := Result + LowerCase(TPath.GetFileName(A[LIdx])) + ';';
end;

// Field by field: a record of Booleans and an enum has padding, so a memory
// compare could fail two equal values.
function SameFormatOptions(const A, B: TPasFormatOptions): Boolean;
begin
  Result := (A.IndentStep = B.IndentStep) and (A.TabWidth = B.TabWidth) and
    (A.MaxBlankLines = B.MaxBlankLines) and
    (A.BeginOnNewLine = B.BeginOnNewLine) and
    (A.ElseOnNewLine = B.ElseOnNewLine) and
    (A.StatementAfterThenDo = B.StatementAfterThenDo) and
    (A.OneStatementPerLine = B.OneStatementPerLine) and
    (A.OneDeclPerLine = B.OneDeclPerLine) and
    (A.IndentNestedRoutines = B.IndentNestedRoutines) and
    (A.KeepDirectivesAtColumn1 = B.KeepDirectivesAtColumn1) and
    (A.KeepCommentsAtColumn1 = B.KeepCommentsAtColumn1);
end;

function TextEdit(AStart, ALen: Integer; const AText: string): TPasTextEdit;
begin
  Result.Start := AStart;
  Result.Len := ALen;
  Result.Text := AText;
end;

// The [Format] section: defaults from an empty file, a full round trip of
// every field set away from its default, and unreadable values falling back
// one field at a time.
procedure CheckFormatSection;
var
  LSet: TDemoSettings;
  LIni: string;
  LOpts, LGot, LDef: TPasFormatOptions;
begin
  LDef := TPasFormatOptions.Default;
  LIni := TPath.Combine(GDir, 'format.ini');
  LSet := TDemoSettings.Create(LIni);
  try
    Ok('[Format]: an empty file reads as the default style',
      SameFormatOptions(LSet.ReadFormatOptions, LDef));
    LOpts := LDef;
    LOpts.IndentStep := 4;
    LOpts.TabWidth := 4;
    LOpts.MaxBlankLines := -1;
    LOpts.BeginOnNewLine := not LDef.BeginOnNewLine;
    LOpts.ElseOnNewLine := not LDef.ElseOnNewLine;
    LOpts.StatementAfterThenDo := fbKeep;
    LOpts.OneStatementPerLine := not LDef.OneStatementPerLine;
    LOpts.OneDeclPerLine := not LDef.OneDeclPerLine;
    LOpts.IndentNestedRoutines := not LDef.IndentNestedRoutines;
    LOpts.KeepDirectivesAtColumn1 := not LDef.KeepDirectivesAtColumn1;
    LOpts.KeepCommentsAtColumn1 := not LDef.KeepCommentsAtColumn1;
    LSet.WriteFormatOptions(LOpts);
    LSet.Save;
  finally
    LSet.Free;
  end;
  LSet := TDemoSettings.Create(LIni);
  try
    LGot := LSet.ReadFormatOptions;
    Ok('[Format]: every field round-trips', SameFormatOptions(LGot, LOpts));
    LSet.WriteFormatOptions(LDef);
    Ok('[Format]: the defaults written read back as the defaults',
      SameFormatOptions(LSet.ReadFormatOptions, LDef));
  finally
    LSet.Free;
  end;

  // Hand-edited: an unreadable value takes the default for THAT field only.
  TFile.WriteAllText(LIni, '[Format]'#13#10'IndentStep=-3'#13#10 +
    'TabWidth=0'#13#10'MaxBlankLines=-2'#13#10 +
    'StatementAfterThenDo=Sometimes'#13#10'BeginOnNewLine=0'#13#10 +
    'ElseOnNewLine=yes'#13#10);
  LSet := TDemoSettings.Create(LIni);
  try
    LGot := LSet.ReadFormatOptions;
    Ok('[Format]: a negative indent, a zero tab, -2 blank lines fall back',
      (LGot.IndentStep = LDef.IndentStep) and (LGot.TabWidth = LDef.TabWidth)
      and (LGot.MaxBlankLines = LDef.MaxBlankLines));
    Ok('[Format]: an unknown break word falls back',
      LGot.StatementAfterThenDo = LDef.StatementAfterThenDo);
    Ok('[Format]: a valid field next to them is read',
      not LGot.BeginOnNewLine);
    Ok('[Format]: a non-number flag falls back',
      LGot.ElseOnNewLine = LDef.ElseOnNewLine);
  finally
    LSet.Free;
  end;
  TFile.WriteAllText(LIni, '[Format]'#13#10'StatementAfterThenDo=keep'#13#10);
  LSet := TDemoSettings.Create(LIni);
  try
    Ok('[Format]: the break word ignores case',
      LSet.ReadFormatOptions.StatementAfterThenDo = fbKeep);
    Ok('[Format] FormatDcuText: on when absent', LSet.FormatDcuText);
    LSet.FormatDcuText := False;
    LSet.Save;
  finally
    LSet.Free;
  end;
  LSet := TDemoSettings.Create(LIni);
  try
    Ok('[Format] FormatDcuText: off round-trips, under its own key',
      not LSet.FormatDcuText and
      (TFile.ReadAllText(LIni).Contains('FormatDcuText=0')));
    Ok('[Format] FormatDcuText: the option fields are untouched by it',
      LSet.ReadFormatOptions.StatementAfterThenDo = fbKeep);
    LSet.FormatDcuText := True;
    Ok('[Format] FormatDcuText: ...and turns on again', LSet.FormatDcuText);
  finally
    LSet.Free;
  end;
  TFile.WriteAllText(LIni, '[Format]'#13#10'FormatDcuText=0'#13#10);
  LSet := TDemoSettings.Create(LIni);
  try
    Ok('[Format] FormatDcuText: a hand-written 0 turns it off',
      not LSet.FormatDcuText);
  finally
    LSet.Free;
  end;
end;

// Format / Format Selection: line starts, the selection filter and the
// caret's new offset, over hand-made edit lists.
procedure CheckFormatArithmetic;
const
  // Line 1 `begin` (0), line 2 `    A;` (7), line 3 `  B;` (15), line 4
  // `end.` (21).
  SRC = 'begin'#13#10'    A;'#13#10'  B;'#13#10'end.';
var
  LStarts: TArray<Integer>;
  LLine, LCol: Integer;
  LEdits, LKept: TPasTextEdits;
begin
  LStarts := LineStartsOf(SRC);
  Ok('line starts: CRLF', (Length(LStarts) = 4) and (LStarts[1] = 7) and
    (LStarts[2] = 15) and (LStarts[3] = 21));
  Ok('line starts: a lone LF and a lone CR break too',
    Length(LineStartsOf('a'#10'b'#13'c')) = 3);
  Ok('line starts: an empty text is one line', Length(LineStartsOf('')) = 1);
  OffsetToLineCol(LStarts, 11, LLine, LCol);
  Ok('offset -> line/col', (LLine = 2) and (LCol = 5));
  OffsetToLineCol(LStarts, 0, LLine, LCol);
  Ok('offset 0 -> 1:1', (LLine = 1) and (LCol = 1));
  OffsetToLineCol(LStarts, Length(SRC), LLine, LCol);
  Ok('the end of the text -> the last line', (LLine = 4) and (LCol = 5));

  // The gap before `A` (5..10: a line break and four blanks) re-indented to
  // two, and the gap before `end.` (19..20) given a blank line. The gap
  // before `B` is untouched, so it has no edit.
  LEdits := [TextEdit(5, 6, #13#10'  '), TextEdit(19, 2, #13#10#13#10)];
  LKept := EditsForLines(LStarts, LEdits, 2, 3);
  Ok('selection keeps the gap whose next token is on a selected line',
    (Length(LKept) = 1) and (LKept[0].Start = 5));
  LKept := EditsForLines(LStarts, LEdits, 4, 4);
  Ok('...the gap starting on the line above lays out the first selected one',
    (Length(LKept) = 1) and (LKept[0].Start = 19));
  Ok('...and none for a line no gap ends on',
    Length(EditsForLines(LStarts, LEdits, 1, 1)) = 0);

  Ok('caret before the edits stays', OffsetAfterEdits(LEdits, 3) = 3);
  Ok('caret at a gap''s start stays', OffsetAfterEdits(LEdits, 5) = 5);
  Ok('caret inside a gap lands on the next token',
    OffsetAfterEdits(LEdits, 8) = 9);
  Ok('caret on the token after a gap moves with it',
    OffsetAfterEdits(LEdits, 11) = 9);
  Ok('caret after both edits shifts by their sum (-2 + 2)',
    OffsetAfterEdits(LEdits, 23) = 23);
  Ok('caret between them shifts by the first only',
    OffsetAfterEdits(LEdits, 17) = 15);
end;

var
  LSet: TDemoSettings;
  LIni, LA, LB, LC, LGone: string;
  LIdx: Integer;
begin
  GCounter.Init;
  GDir := TPath.Combine(TPath.GetTempPath, 'PasTreeDemoSettings');
  TDirectory.CreateDirectory(GDir);
  LIni := TPath.Combine(GDir, 'demo.ini');
  if TFile.Exists(LIni) then
    TFile.Delete(LIni);

  LA := MakeFile('A.dproj');
  LB := MakeFile('B.dproj');
  LC := MakeFile('C.dproj');
  LGone := TPath.Combine(GDir, 'Vanished.dproj');   // deliberately not created

  LSet := TDemoSettings.Create(LIni);
  try
    Ok('empty to start', Length(LSet.Recent) = 0);

    LSet.AddRecent(LA);
    LSet.AddRecent(LB);
    LSet.AddRecent(LC);
    Ok('most-recent-first', Joined(LSet.Recent) = 'c.dproj;b.dproj;a.dproj;');

    // Re-opening an entry MOVES it, it does not duplicate it.
    LSet.AddRecent(LA);
    Ok('re-open moves to front, no duplicate',
      Joined(LSet.Recent) = 'a.dproj;c.dproj;b.dproj;');

    // The filesystem is case-insensitive here, so a differently-cased or
    // relative spelling is the SAME project - the commonest way a list like
    // this fills up with the same entry three times.
    LSet.AddRecent(UpperCase(LB));
    Ok('case-insensitive dedup', Length(LSet.Recent) = 3);
    LSet.AddRecent(TPath.Combine(TPath.Combine(GDir, 'sub'), '..\C.dproj'));
    Ok('relative spelling dedups too', Length(LSet.Recent) = 3);

    // A missing file is REMEMBERED (it may be a disconnected share) but not
    // OFFERED. Those are two different lists on purpose.
    LSet.AddRecent(LGone);
    Ok('a missing project is still remembered', Length(LSet.Recent) = 4);
    Ok('...but not offered', Length(LSet.ExistingRecent) = 3);
    Ok('...and the offered list keeps its order',
      Joined(LSet.ExistingRecent) = 'c.dproj;b.dproj;a.dproj;');

    for LIdx := 1 to RECENT_MAX + 5 do
      LSet.AddRecent(MakeFile(Format('Bulk%d.dproj', [LIdx])));
    Ok('capped at RECENT_MAX', Length(LSet.Recent) = RECENT_MAX);

    LSet.WriteInt('Threading', 1);
    Ok('Light libraries: off by default', not LSet.LightLibraries);
    LSet.LightLibraries := True;
    LSet.Save;
  finally
    LSet.Free;
  end;

  // Reload: the cap must have SHRUNK the file, not just the in-memory list -
  // leaving the old tail under its own keys would read straight back.
  LSet := TDemoSettings.Create(LIni);
  try
    Ok('round-trips at the cap', Length(LSet.Recent) = RECENT_MAX);
    Ok('round-trips in order',
      TPath.GetFileName(LSet.Recent[0]) = Format('Bulk%d.dproj',
        [RECENT_MAX + 5]));
    Ok('a stored value round-trips', LSet.ReadInt('Threading', 0) = 1);
    Ok('an absent value falls back', LSet.ReadInt('NoSuchKey', 42) = 42);
    Ok('Light libraries round-trips', LSet.LightLibraries);
    LSet.LightLibraries := False;
    Ok('...and turns off again', not LSet.LightLibraries and
      (LSet.ReadInt('LightLibraries', 7) = 0));
  finally
    LSet.Free;
  end;

  // A file that cannot be read is not an error: every getter has a default.
  LSet := TDemoSettings.Create(TPath.Combine(GDir, 'does-not-exist.ini'));
  try
    Ok('a missing .ini is empty, not fatal',
      (Length(LSet.Recent) = 0) and (LSet.ReadInt('Threading', 7) = 7));
  finally
    LSet.Free;
  end;

  CheckFormatSection;
  CheckFormatArithmetic;

  TDirectory.Delete(GDir, True);

  { The $I file-name span behind ctrl+click and Open File at Cursor on an
    include. Here rather than in the form for the same reason the rest of this
    suite exists: a running program cannot show you that the span is right, only
    that the jump felt right on the one line you tried. }
  CheckSpan('plain include', '{$I common.inc}', 6, 'common.inc');
  CheckSpan('...indented and followed by code', '  {$I common.inc} // x', 9,
    'common.inc');
  CheckSpan('the long spelling', '{$INCLUDE common.inc}', 12, 'common.inc');
  CheckSpan('lower case', '{$i common.inc}', 6, 'common.inc');
  CheckSpan('the parenthesis-star form', '(*$I common.inc*)', 7, 'common.inc');
  CheckSpan('a quoted path keeps the path, not the quotes',
    '{$I ''..\lib\a b.inc''}', 8, '..\lib\a b.inc');
  CheckSpan('a relative path', '{$I ..\include\common.inc}', 8,
    '..\include\common.inc');
  // The caret one PAST the name is still the name - that is where a
  // double-click leaves it.
  CheckSpan('caret just past the last character', '{$I common.inc}', 12,
    'common.inc');
  CheckSpan('caret on the first character', '{$I common.inc}', 5, 'common.inc');
  // Not includes, and each one would otherwise open something.
  CheckSpan('$I+ is I/O checking', '{$I+}', 4, '');
  CheckSpan('$I- likewise', '{$I-}', 4, '');
  CheckSpan('$I% is an environment string', '{$I%DATE%}', 5, '');
  CheckSpan('$IFDEF is not $I', '{$IFDEF DEBUG}', 9, '');
  CheckSpan('$IFNDEF is not $I either', '{$IFNDEF X}', 10, '');
  CheckSpan('an ordinary comment is not a directive', '{ common.inc }', 4, '');
  CheckSpan('outside the directive', 'uses A; {$I common.inc}', 3, '');
  // Two directives on one line: the caret picks its own.
  CheckSpan('the second of two directives', '{$I a.inc}{$I b.inc}', 15,
    'b.inc');
  CheckSpan('...and the first', '{$I a.inc}{$I b.inc}', 6, 'a.inc');

  if GCounter.Finish('DemoSettingsSmoke') then
    ExitCode := 1;
end.
