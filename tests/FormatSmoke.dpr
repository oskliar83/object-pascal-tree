program FormatSmoke;

{
  PasTree.Format, stage F1: indentation and line breaks. Every case is an
  input and the text the default style (or the options the case names) must
  turn it into; every case is also held to the formatter's three gates:
  - G-tok: the output holds the input's tokens, whitespace aside;
  - G-idem: formatting the output changes nothing;
  - G-tree: the output parses to the same tree (TreeFingerprint).
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Lexer in '..\source\PasTree.Lexer.pas',
  PasTree.SourceManager in '..\source\PasTree.SourceManager.pas',
  PasTree.Dcu in '..\source\PasTree.Dcu.pas',
  PasTree.Dcu.Source in '..\source\PasTree.Dcu.Source.pas',
  PasTree.Preprocessor in '..\source\PasTree.Preprocessor.pas',
  PasTree.Ast in '..\source\PasTree.Ast.pas',
  PasTree.Ast.Check in '..\source\PasTree.Ast.Check.pas',
  PasTree.Parser in '..\source\PasTree.Parser.pas',
  PasTree.Printer in '..\source\PasTree.Printer.pas',
  PasTree.Format in '..\source\PasTree.Format.pas';

var
  GSM: TPasSourceManager;
  GPP: TPasPreprocessor;
  GFailed, GPassed: Integer;

function Parse(const AText: string; out ADiags: Integer): TPasTree;
var
  LDiags: TArray<TPasParseDiag>;
begin
  Result := TPasParser.ParseFile(GPP.ProcessText('test.pas', AText), LDiags);
  ADiags := Length(LDiags);
end;

function FormatText(const AText: string;
  const AOptions: TPasFormatOptions): string;
var
  LTree: TPasTree;
  LDiags: Integer;
begin
  LTree := Parse(AText, LDiags);
  Result := PasApplyEdits(AText, PasFormatEdits(LTree, 0, AOptions));
end;

function Lines(const AText: array of string): string;
var
  LIdx: Integer;
begin
  Result := '';
  for LIdx := 0 to High(AText) do
    Result := Result + AText[LIdx] + #13#10;
end;

function Visible(const AText: string): string;
begin
  Result := StringReplace(AText, #13#10, '|' + sLineBreak, [rfReplaceAll]);
end;

procedure Fail(const AName, AMsg: string);
begin
  Inc(GFailed);
  Writeln('FAIL ', AName, ': ', AMsg);
end;

procedure Check(const AName, AInput, AExpected: string;
  const AOptions: TPasFormatOptions); overload;
var
  LOut, LAgain, LMsg: string;
  LTreeA, LTreeB: TPasTree;
  LDiagsA, LDiagsB, LIdx: Integer;
  LFpA, LFpB: TArray<string>;
begin
  LOut := FormatText(AInput, AOptions);
  if LOut <> AExpected then
  begin
    Fail(AName, 'output differs' + sLineBreak + '--- expected' + sLineBreak +
      Visible(AExpected) + '--- got' + sLineBreak + Visible(LOut));
    Exit;
  end;
  if not PasSameTokens(AInput, LOut, LMsg) then
  begin
    Fail(AName, 'G-tok ' + LMsg);
    Exit;
  end;
  LAgain := FormatText(LOut, AOptions);
  if LAgain <> LOut then
  begin
    Fail(AName, 'G-idem' + sLineBreak + Visible(LAgain));
    Exit;
  end;
  LTreeA := Parse(AInput, LDiagsA);
  LTreeB := Parse(LOut, LDiagsB);
  if LDiagsA = 0 then
  begin
    LFpA := TreeFingerprint(LTreeA);
    LFpB := TreeFingerprint(LTreeB);
    if Length(LFpA) <> Length(LFpB) then
    begin
      Fail(AName, 'G-tree node count');
      Exit;
    end;
    for LIdx := 0 to High(LFpA) do
      if LFpA[LIdx] <> LFpB[LIdx] then
      begin
        Fail(AName, 'G-tree ' + LFpA[LIdx] + ' / ' + LFpB[LIdx]);
        Exit;
      end;
  end;
  Inc(GPassed);
end;

procedure Check(const AName, AInput, AExpected: string); overload;
begin
  Check(AName, AInput, AExpected, TPasFormatOptions.Default);
end;

const
  UNIT_HEAD = 'unit U;' + #13#10 + #13#10 + 'interface' + #13#10 + #13#10 +
    'implementation' + #13#10 + #13#10;
  UNIT_TAIL = #13#10 + 'end.' + #13#10;

function U(const ABody: array of string): string;
begin
  Result := UNIT_HEAD + Lines(ABody) + UNIT_TAIL;
end;

function SameOptions(const A, B: TPasFormatOptions): Boolean;
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
    (A.KeepCommentsAtColumn1 = B.KeepCommentsAtColumn1) and
    (A.NormalizeSpaces = B.NormalizeSpaces) and
    (A.SpaceAroundOperators = B.SpaceAroundOperators) and
    (A.SpaceAfterSeparators = B.SpaceAfterSeparators) and
    (A.RemoveSpaces = B.RemoveSpaces) and
    (A.ReservedWordCase = B.ReservedWordCase) and
    (A.DirectiveWordCase = B.DirectiveWordCase) and
    (A.CompilerDirectiveCase = B.CompilerDirectiveCase) and
    (A.RightMargin = B.RightMargin) and (A.WrapLongLines = B.WrapLongLines) and
    (A.AlignAssignments = B.AlignAssignments) and
    (A.AlignDeclColons = B.AlignDeclColons) and
    (A.AlignTrailingComments = B.AlignTrailingComments);
end;

// Style inference (F9): a unit written in a style far from the default -
// four-space steps, upper-case reserved words, `then begin`, colons aligned -
// infers that style, the `begin` split between two layouts reads as mixed,
// and the unit formatted with what was inferred stays as it is.
procedure InferCase;
var
  LText, LMsg: string;
  LIdx, LDiags: Integer;
  LTree: TPasTree;
  LSample: TPasFormatSample;
  LOpts: TPasFormatOptions;
  LNotes: TArray<TPasFormatInferNote>;
  LMixed: Boolean;
begin
  LText := 'UNIT U;' + #13#10 + #13#10 + 'INTERFACE' + #13#10 + #13#10 +
    'IMPLEMENTATION' + #13#10;
  for LIdx := 1 to 25 do
    LText := LText + #13#10 + Lines([
      'PROCEDURE P' + IntToStr(LIdx) + ';',
      'VAR',
      '    A   : Integer;',
      '    Bcd : STRING;',
      'BEGIN',
      '    IF A = 0 THEN BEGIN',
      '        A := 1;',
      '    END;',
      'END;']);
  LText := LText + #13#10 + 'END.' + #13#10;
  LTree := Parse(LText, LDiags);
  if LDiags > 0 then
  begin
    Fail('infer', 'the sample does not parse clean');
    Exit;
  end;
  LSample := Default(TPasFormatSample);
  PasFormatTally(LTree, 0, LSample);
  LOpts := PasInferFormatOptions(LSample, LNotes);
  LMsg := '';
  if LOpts.IndentStep <> 4 then
    LMsg := LMsg + ' IndentStep ' + IntToStr(LOpts.IndentStep);
  if LOpts.ReservedWordCase <> fcUpper then
    LMsg := LMsg + ' ReservedWordCase';
  if LOpts.BeginOnNewLine then
    LMsg := LMsg + ' BeginOnNewLine';
  if not LOpts.AlignDeclColons then
    LMsg := LMsg + ' AlignDeclColons';
  if LOpts.AlignAssignments then
    LMsg := LMsg + ' AlignAssignments';
  if LOpts.MaxBlankLines <> 1 then
    LMsg := LMsg + ' MaxBlankLines ' + IntToStr(LOpts.MaxBlankLines);
  LMixed := False;
  for LIdx := 0 to High(LNotes) do
    if LNotes[LIdx].Option = 'BeginOnNewLine' then
      LMixed := LNotes[LIdx].Mixed;
  if not LMixed then
    LMsg := LMsg + ' BeginOnNewLine not mixed';
  if Length(PasFormatEdits(LTree, 0, LOpts)) > 0 then
    LMsg := LMsg + ' the sample changes: ' + Visible(PasApplyEdits(LText,
      PasFormatEdits(LTree, 0, LOpts)));
  if LMsg <> '' then
    Fail('infer', LMsg)
  else
    Inc(GPassed);
  // A sample of nothing decides every option as its default.
  LOpts := PasInferFormatOptions(Default(TPasFormatSample), LNotes);
  if not SameOptions(LOpts, TPasFormatOptions.Default) then
    Fail('infer nothing', 'not the default')
  else
    Inc(GPassed);
end;

// The identifier-case callback: a leaf's identifier takes the spelling the
// caller gives, and a spelling that is not the same word is refused.
procedure IdentCaseCase;
var
  LText, LOut: string;
  LTree: TPasTree;
  LDiags: Integer;
begin
  LText := U(['procedure P;', 'var', '  I: integer;', 'begin', '  i := 0;',
    'end;']);
  LTree := Parse(LText, LDiags);
  LOut := PasApplyEdits(LText, PasFormatEdits(LTree, 0,
    TPasFormatOptions.Default,
    function(AVis: Integer; const AText: string): string
    begin
      if SameText(AText, 'integer') then
        Result := 'Integer'
      else if SameText(AText, 'i') then
        Result := 'I'
      else if SameText(AText, 'p') then
        Result := 'Q'                 // not a spelling of P: refused
      else
        Result := AText;
    end));
  if LOut <> U(['procedure P;', 'var', '  I: Integer;', 'begin', '  I := 0;',
    'end;']) then
    Fail('identifier case', Visible(LOut))
  else
    Inc(GPassed);
end;

// Range mode: only the edits of the selected text, each as the whole-file
// format makes it.
procedure RangeCase;
var
  LText, LOut: string;
  LTree: TPasTree;
  LDiags, LStart: Integer;
begin
  LText := U(['procedure P;', 'begin', '      A;', 'B;', '    C;', 'end;']);
  LTree := Parse(LText, LDiags);
  LStart := Pos('B;', LText) - 1;
  LOut := PasApplyEdits(LText, PasFormatRangeEdits(LTree, 0,
    TPasFormatOptions.Default, LStart, LStart + 2));
  if LOut <> U(['procedure P;', 'begin', '      A;', '  B;', '    C;', 'end;']) then
    Fail('range', Visible(LOut))
  else
    Inc(GPassed);
end;

// An include file formats as itself: its own tokens, laid out by the
// includer's tree; the includer is not touched by it.
procedure IncludeCase;
var
  LDir, LMain, LInc, LOut: string;
  LTree: TPasTree;
  LDiags: TArray<TPasParseDiag>;
  LPre: TPasPreprocessed;
  LFile: Integer;
begin
  LDir := TPath.Combine(TPath.GetTempPath, 'PasTreeFormatSmoke');
  ForceDirectories(LDir);
  LMain := TPath.Combine(LDir, 'IncMain.pas');
  LInc := TPath.Combine(LDir, 'IncBody.inc');
  TFile.WriteAllText(LMain, U(['procedure P;', 'begin',
    '  {$I IncBody.inc}', 'end;']));
  TFile.WriteAllText(LInc, Lines(['A;', '      B;']));
  LPre := GPP.Process(LMain);
  LTree := TPasParser.ParseFile(LPre, LDiags);
  LFile := -1;
  for var LIdx := 0 to High(LPre.FileNames) do
    if SameText(TPath.GetFileName(LPre.FileNames[LIdx]), 'IncBody.inc') then
      LFile := LIdx;
  if (LFile < 0) or (Length(LDiags) > 0) then
  begin
    Fail('include', 'the include was not read');
    Exit;
  end;
  LOut := PasApplyEdits(LPre.Files[LFile].Source,
    PasFormatEdits(LTree, LFile, TPasFormatOptions.Default));
  if LOut <> Lines(['A;', '  B;']) then
    Fail('include', Visible(LOut))
  else
    Inc(GPassed);
end;

procedure Cases;
var
  LOpt: TPasFormatOptions;
begin
  Check('already formatted', U([
    'procedure P;',
    'var',
    '  I: Integer;',
    'begin',
    '  I := 1;',
    '  if I > 0 then',
    '  begin',
    '    I := 2;',
    '  end',
    '  else',
    '    I := 3;',
    'end;']), U([
    'procedure P;',
    'var',
    '  I: Integer;',
    'begin',
    '  I := 1;',
    '  if I > 0 then',
    '  begin',
    '    I := 2;',
    '  end',
    '  else',
    '    I := 3;',
    'end;']));

  Check('reindent statements', U([
    'procedure P;',
    'begin',
    '      A;',
    'B;',
    '    while C do',
    '        D;',
    'end;']), U([
    'procedure P;',
    'begin',
    '  A;',
    '  B;',
    '  while C do',
    '    D;',
    'end;']));

  Check('one statement per line', U([
    'procedure P;',
    'begin A; B; if C then D else E; end;']), U([
    'procedure P;',
    'begin',
    '  A;',
    '  B;',
    '  if C then',
    '    D',
    '  else',
    '    E;',
    'end;']));

  Check('then begin, end else', U([
    'procedure P;',
    'begin',
    '  if C then begin',
    '    A;',
    '  end else begin',
    '    B;',
    '  end;',
    'end;']), U([
    'procedure P;',
    'begin',
    '  if C then',
    '  begin',
    '    A;',
    '  end',
    '  else',
    '  begin',
    '    B;',
    '  end;',
    'end;']));

  Check('else if stays', U([
    'procedure P;',
    'begin',
    '  if A then',
    '    X',
    '  else if B then',
    '    Y',
    '  else',
    '    Z;',
    'end;']), U([
    'procedure P;',
    'begin',
    '  if A then',
    '    X',
    '  else if B then',
    '    Y',
    '  else',
    '    Z;',
    'end;']));

  Check('case, try, repeat', U([
    'procedure P;',
    'begin',
    'case X of',
    '1: A;',
    '2:',
    'B;',
    'else C;',
    'end;',
    'try A; finally B; end;',
    'try',
    'A;',
    'except',
    'on E: Exception do',
    'B;',
    'end;',
    'repeat A; until B;',
    'end;']), U([
    'procedure P;',
    'begin',
    '  case X of',
    '    1: A;',
    '    2:',
    '      B;',
    '  else',
    '    C;',
    '  end;',
    '  try',
    '    A;',
    '  finally',
    '    B;',
    '  end;',
    '  try',
    '    A;',
    '  except',
    '    on E: Exception do',
    '      B;',
    '  end;',
    '  repeat',
    '    A;',
    '  until B;',
    'end;']));

  Check('continuation keeps its offset', U([
    'procedure P;',
    'begin',
    '    Foo(A,',
    '        B);',
    '    X := 1 +',
    '      2;',
    'end;']), U([
    'procedure P;',
    'begin',
    '  Foo(A,',
    '      B);',
    '  X := 1 +',
    '    2;',
    'end;']));

  Check('comments', U([
    'procedure P;',
    'begin',
    '// before A',
    'A; // after A',
    '    { block }',
    '  B;',
    '    // before end',
    'end;']), U([
    'procedure P;',
    'begin',
    '  // before A',
    '  A; // after A',
    '  { block }',
    '  B;',
    '  // before end',
    'end;']));

  Check('directives and inactive code', U([
    'procedure P;',
    'begin',
    '{$IFDEF NEVER_DEFINED}',
    '     junk junk(',
    '{$ELSE}',
    '      A;',
    '{$ENDIF}',
    '    {$IFDEF X} B; {$ENDIF}',
    'end;']), U([
    'procedure P;',
    'begin',
    '{$IFDEF NEVER_DEFINED}',
    '     junk junk(',
    '{$ELSE}',
    '  A;',
    '{$ENDIF}',
    '    {$IFDEF X} B; {$ENDIF}',
    'end;']));

  Check('class layout', UNIT_HEAD.Replace('implementation' + #13#10 + #13#10,
    '') + Lines([
    'type',
    'TFoo = class(TObject)',
    'private',
    'FA: Integer; FB: string;',
    '[Weak] FC: TObject;',
    'public',
    'class procedure M; procedure N;',
    'property A: Integer read FA;',
    'class var',
    'Count: Integer;',
    'end;',
    'TRec = record X, Y: Integer; end;',
    'TEmpty = class end;',
    '',
    'implementation',
    '',
    'class procedure TFoo.M;',
    'begin',
    'end;',
    '',
    'procedure TFoo.N;',
    'begin end;']) + UNIT_TAIL, UNIT_HEAD.Replace('implementation' +
    #13#10 + #13#10, '') + Lines([
    'type',
    '  TFoo = class(TObject)',
    '  private',
    '    FA: Integer;',
    '    FB: string;',
    '    [Weak] FC: TObject;',
    '  public',
    '    class procedure M;',
    '    procedure N;',
    '    property A: Integer read FA;',
    '    class var',
    '      Count: Integer;',
    '  end;',
    '  TRec = record',
    '    X, Y: Integer;',
    '  end;',
    '  TEmpty = class end;',
    '',
    'implementation',
    '',
    'class procedure TFoo.M;',
    'begin',
    'end;',
    '',
    'procedure TFoo.N;',
    'begin',
    'end;']) + UNIT_TAIL);

  Check('sections and uses', Lines([
    'unit U;',
    'interface',
    'uses SysUtils, Classes;',
    'const A = 1; B = 2;',
    'var V: Integer;',
    'implementation',
    'end.']), Lines([
    'unit U;',
    'interface',
    'uses',
    '  SysUtils, Classes;',
    'const',
    '  A = 1;',
    '  B = 2;',
    'var',
    '  V: Integer;',
    'implementation',
    'end.']));

  Check('nested routine', U([
    'procedure P;',
    'procedure Q;',
    'begin',
    'A;',
    'end;',
    'var I: Integer;',
    'begin',
    'Q;',
    'end;']), U([
    'procedure P;',
    '  procedure Q;',
    '  begin',
    '    A;',
    '  end;',
    'var',
    '  I: Integer;',
    'begin',
    '  Q;',
    'end;']));

  Check('anonymous method', U([
    'procedure P;',
    'begin',
    '  Run(procedure begin A; end);',
    '  Run(',
    '        procedure',
    '        begin',
    '        A;',
    '        end);',
    'end;']), U([
    'procedure P;',
    'begin',
    '  Run(procedure begin A; end);',
    '  Run(',
    '        procedure',
    '        begin',
    '          A;',
    '        end);',
    'end;']));

  Check('blank lines capped', U([
    'procedure P;',
    'begin',
    '  A;',
    '',
    '',
    '',
    '',
    '  B;',
    'end;']), U([
    'procedure P;',
    'begin',
    '  A;',
    '',
    '',
    '  B;',
    'end;']));

  Check('invalid code left alone', U([
    'procedure P;',
    'begin',
    '      A := ;',
    'end;']), U([
    'procedure P;',
    'begin',
    '      A := ;',
    'end;']));

  Check('asm opaque', U([
    'procedure P;',
    'asm',
    '      mov eax, 1',
    '   end;']), U([
    'procedure P;',
    'asm',
    '      mov eax, 1',
    '   end;']));

  Check('F2 spaces', U([
    'procedure P(A:Integer;B : string);',
    'var',
    '  X,Y:Integer;',
    '  C: array[0 .. 9] of Integer;',
    'begin',
    '  X:=A+B*2;',
    '  Foo ( X , Y );',
    '  L [ 1 ] := - X;',
    '  S := ''a''#13''b''^M;',
    '  if (X>0)and(Y<>1) then',
    '    Z := P ^ .F;',
    '  Write(X:10:2);',
    'end;']), U([
    'procedure P(A: Integer; B: string);',
    'var',
    '  X, Y: Integer;',
    '  C: array[0..9] of Integer;',
    'begin',
    '  X := A + B * 2;',
    '  Foo(X, Y);',
    '  L[1] := -X;',
    '  S := ''a''#13''b''^M;',
    '  if (X > 0) and (Y <> 1) then',
    '    Z := P^.F;',
    '  Write(X:10:2);',
    'end;']));

  Check('F2 alignment kept, no fusion', U([
    'const',
    '  toEOF     = Char(0);',
    '  toSymbol  = Char(1);',
    'procedure P;',
    'begin',
    '  X := ( * Y);',
    '  Z := A - -B;',
    'end;']), U([
    'const',
    '  toEOF     = Char(0);',
    '  toSymbol  = Char(1);',
    'procedure P;',
    'begin',
    '  X := ( * Y);',
    '  Z := A - -B;',
    'end;']));

  Check('F2 case', U([
    'Procedure P; Override;',
    '{$ifndef Debug}',
    'Var',
    '  S: String;',
    '{$EndIf}',
    'Begin',
    '  If S = '''' Then Exit',
    'End;']), U([
    'procedure P; override;',
    '{$IFNDEF Debug}',
    'var',
    '  S: string;',
    '{$ENDIF}',
    'begin',
    '  if S = '''' then',
    '    Exit',
    'end;']));

  IdentCaseCase;
  RangeCase;
  IncludeCase;
  InferCase;

  LOpt := TPasFormatOptions.Default;
  LOpt.StatementAfterThenDo := fbKeep;
  LOpt.IndentStep := 4;
  Check('options: keep then, step 4', U([
    'procedure P;',
    'begin',
    '  if A then Exit;',
    '  for I := 0 to 1 do',
    '  B;',
    'end;']), U([
    'procedure P;',
    'begin',
    '    if A then Exit;',
    '    for I := 0 to 1 do',
    '        B;',
    'end;']), LOpt);

  Check('program main block', Lines([
    'program X;',
    'uses SysUtils;',
    'begin A; B;',
    'end.']), Lines([
    'program X;',
    'uses',
    '  SysUtils;',
    'begin',
    '  A;',
    '  B;',
    'end.']));

  Check('initialization', Lines([
    'unit U;',
    'interface',
    'implementation',
    'initialization',
    'A;',
    'finalization',
    '    B;',
    'end.']), Lines([
    'unit U;',
    'interface',
    'implementation',
    'initialization',
    '  A;',
    'finalization',
    '  B;',
    'end.']));

  // F5, wrapping: off by default, a long line stays as it is.
  Check('wrap off', U([
    'procedure P;',
    'begin',
    '  Foo(Alpha, Beta, Gamma, Delta, Epsilon);',
    'end;']), U([
    'procedure P;',
    'begin',
    '  Foo(Alpha, Beta, Gamma, Delta, Epsilon);',
    'end;']));

  LOpt := TPasFormatOptions.Default;
  LOpt.WrapLongLines := True;
  LOpt.RightMargin := 40;
  Check('wrap: after the last comma that fits', U([
    'procedure P;',
    'begin',
    '  Foo(Alpha, Beta, Gamma, Delta, Epsilon);',
    'end;']), U([
    'procedure P;',
    'begin',
    '  Foo(Alpha, Beta, Gamma, Delta,',
    '    Epsilon);',
    'end;']), LOpt);

  LOpt.RightMargin := 30;
  Check('wrap: lowest operator, := last, uses items', Lines([
    'unit U;',
    'interface',
    'uses',
    '  SysUtils, Classes, Generics.Collections, Types;',
    'implementation',
    'procedure P;',
    'begin',
    '  Result := AlphaValue + BetaValue * GammaValue;',
    '  S := ''a very long string literal'';',
    '  WriteLn(''a very long string literal'');',
    '  Foo(Alpha, {$IFDEF X}Beta,{$ENDIF} Gamma, Delta);',
    'end;',
    'end.']), Lines([
    'unit U;',
    'interface',
    'uses',
    '  SysUtils, Classes,',
    '  Generics.Collections, Types;',
    'implementation',
    'procedure P;',
    'begin',
    '  Result := AlphaValue +',
    '    BetaValue * GammaValue;',
    '  S :=',
    '    ''a very long string literal'';',
    '  WriteLn(''a very long string literal'');',
    '  Foo(Alpha, {$IFDEF X}Beta,{$ENDIF} Gamma, Delta);',
    'end;',
    'end.']), LOpt);

  // F5, alignment: each option off keeps the author's spacing, on aligns
  // a group of consecutive lines and leaves a line alone as F2 has it.
  Check('align off', U([
    'var',
    '  A: Integer;',
    '  LongName: string;',
    'procedure P;',
    'begin',
    '  A := 1; // one',
    '  LongName := 2; // two',
    'end;']), U([
    'var',
    '  A: Integer;',
    '  LongName: string;',
    'procedure P;',
    'begin',
    '  A := 1; // one',
    '  LongName := 2; // two',
    'end;']));

  LOpt := TPasFormatOptions.Default;
  LOpt.AlignAssignments := True;
  Check('align assignments', U([
    'procedure P;',
    'begin',
    '  A := 1;',
    '  LongName := 2;',
    '',
    '  B     := 3;',
    '  Foo;',
    '  CC := 4;',
    '  D := Foo(1,',
    '    2);',
    'end;']), U([
    'procedure P;',
    'begin',
    '  A        := 1;',
    '  LongName := 2;',
    '',
    '  B     := 3;',
    '  Foo;',
    '  CC := 4;',
    '  D := Foo(1,',
    '    2);',
    'end;']), LOpt);

  LOpt := TPasFormatOptions.Default;
  LOpt.AlignDeclColons := True;
  Check('align declaration colons', U([
    'var',
    '  A: Integer;',
    '  LongName: string;',
    '  X: Integer;',
    '',
    '  Y: Integer;',
    '  Z: string;',
    'const',
    '  C = 1;',
    '  LongC = 2;',
    '  T: Integer = 3;',
    'type',
    '  TA = Integer;',
    '  TLonger = string;']), U([
    'var',
    '  A        : Integer;',
    '  LongName : string;',
    '  X        : Integer;',
    '',
    '  Y: Integer;',
    '  Z: string;',
    'const',
    '  C     = 1;',
    '  LongC = 2;',
    '  T: Integer = 3;',
    'type',
    '  TA      = Integer;',
    '  TLonger = string;']), LOpt);

  LOpt := TPasFormatOptions.Default;
  LOpt.AlignTrailingComments := True;
  Check('align trailing comments', U([
    'procedure P;',
    'begin',
    '  A := 1; // one',
    '  Longer := 2; // two',
    '  Foo;',
    '  B := 3;    // three',
    '  // a comment line ends the group',
    '  C := 4;     // alone: kept',
    'end;']), U([
    'procedure P;',
    'begin',
    '  A := 1;      // one',
    '  Longer := 2; // two',
    '  Foo;',
    '  B := 3;      // three',
    '  // a comment line ends the group',
    '  C := 4;     // alone: kept',
    'end;']), LOpt);

  LOpt.AlignAssignments := True;
  LOpt.AlignDeclColons := True;
  LOpt.WrapLongLines := True;
  LOpt.RightMargin := 30;
  Check('wrap and align together', U([
    'procedure P;',
    'var',
    '  I: Integer; // a',
    '  Name: string; // b',
    'begin',
    '  I := 1; // c',
    '  Name := Foo(Alpha, Beta, Gamma);',
    'end;']), U([
    'procedure P;',
    'var',
    '  I    : Integer; // a',
    '  Name : string;  // b',
    'begin',
    '  I := 1; // c',
    '  Name := Foo(Alpha, Beta,',
    '    Gamma);',
    'end;']), LOpt);
end;

begin
  try
    GSM := TPasSourceManager.Create(nil);
    GPP := TPasPreprocessor.Create(GSM, TPasDefines.Create);
    try
      Cases;
    finally
      GPP.Free;
      GSM.Free;
    end;
    Writeln(Format('FormatSmoke: %d passed, %d failed', [GPassed, GFailed]));
    if GFailed > 0 then
      ExitCode := 1;
  except
    on E: Exception do
    begin
      Writeln('EXCEPTION ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
