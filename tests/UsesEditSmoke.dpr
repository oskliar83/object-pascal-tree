program UsesEditSmoke;

{
  PasTree.UsesEdit: the edits that take entries out of `uses` clauses. Each
  case is a unit's text, the names to remove, and the text the edits leave
  (or the refusal): the layout kept, a removed entry's line and separator
  going with it, a whole clause with its line, a directive never dropped, a
  refusal where no comma can go without one.
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.StrUtils,
  System.Classes,
  System.Generics.Collections,
  System.Generics.Defaults,
  PasTree.Types in '..\source\PasTree.Types.pas',
  PasTree.Lexer in '..\source\PasTree.Lexer.pas',
  PasTree.SourceManager in '..\source\PasTree.SourceManager.pas',
  PasTree.Dcu in '..\source\PasTree.Dcu.pas',
  PasTree.Dcu.Source in '..\source\PasTree.Dcu.Source.pas',
  PasTree.Preprocessor in '..\source\PasTree.Preprocessor.pas',
  PasTree.Ast in '..\source\PasTree.Ast.pas',
  PasTree.Parser in '..\source\PasTree.Parser.pas',
  PasTree.UsesEdit in '..\source\PasTree.UsesEdit.pas';

var
  GSM: TPasSourceManager;
  GPP: TPasPreprocessor;
  GFailed, GPassed: Integer;

function Parse(const AText: string): TPasTree;
var
  LDiags: TArray<TPasParseDiag>;
begin
  Result := TPasParser.ParseFile(GPP.ProcessText('test.pas', AText), LDiags);
end;

// A unit whose interface `uses` is AIntf and implementation `uses` AImpl
// ('' for none), each a clause with its own line(s).
function UnitText(const AIntf, AImpl: string): string;
begin
  Result := 'unit U;'#13#10'interface'#13#10;
  if AIntf <> '' then
    Result := Result + AIntf + #13#10;
  Result := Result + #13#10'implementation'#13#10;
  if AImpl <> '' then
    Result := Result + AImpl + #13#10;
  Result := Result + #13#10'end.'#13#10;
end;

function Visible(const AText: string): string;
begin
  Result := StringReplace(AText, #13#10, '|', [rfReplaceAll]);
end;

procedure Ok(const AName: string; ACond: Boolean; const AMsg: string = '');
begin
  if ACond then
    Inc(GPassed)
  else
  begin
    Inc(GFailed);
    Writeln('FAIL ', AName, IfThen(AMsg <> '', ': ' + AMsg, ''));
  end;
end;

// AText with AEdits applied, from the last one back; each edit's OldText
// checked against the text it replaces.
function Applied(const AText: string; const AEdits: TArray<TPasUsesRemoval>;
  out AOldOk: Boolean): string;
var
  LEdits: TArray<TPasUsesRemoval>;
begin
  AOldOk := True;
  LEdits := Copy(AEdits);
  TArray.Sort<TPasUsesRemoval>(LEdits, TComparer<TPasUsesRemoval>.Construct(
    function(const A, B: TPasUsesRemoval): Integer
    begin
      Result := B.Start - A.Start;
    end));
  Result := AText;
  for var LE in LEdits do
  begin
    if Copy(Result, LE.Start + 1, LE.Len) <> LE.OldText then
      AOldOk := False;
    Result := Copy(Result, 1, LE.Start) + LE.NewText +
      Copy(Result, LE.Start + LE.Len + 1, MaxInt);
  end;
end;

// Removing ANames from AText leaves AExpected, with no refusal and nothing
// missing.
procedure Check(const AName, AText: string; const ANames: TArray<string>;
  const AExpected: string);
var
  LTree: TPasTree;
  LEdits: TArray<TPasUsesRemoval>;
  LRefused, LMissing: TArray<string>;
  LOut: string;
  LOldOk: Boolean;
begin
  LTree := Parse(AText);
  LEdits := UsesRemovalByName(LTree, ANames, LRefused, LMissing);
  LOut := Applied(AText, LEdits, LOldOk);
  Ok(AName + ': no refusal', LRefused = nil, string.Join('; ', LRefused));
  Ok(AName + ': nothing missing', LMissing = nil,
    string.Join(', ', LMissing));
  Ok(AName + ': OldText is the text replaced', LOldOk);
  Ok(AName, LOut = AExpected, 'got ' + Visible(LOut) + ' expected ' +
    Visible(AExpected));
end;

// Removing ANames from AText is refused for AEntry, with a reason holding
// AWhy, and no edit is made.
procedure CheckRefused(const AName, AText: string; const ANames: TArray<string>;
  const AEntry, AWhy: string);
var
  LTree: TPasTree;
  LEdits: TArray<TPasUsesRemoval>;
  LRefused, LMissing: TArray<string>;
begin
  LTree := Parse(AText);
  LEdits := UsesRemovalByName(LTree, ANames, LRefused, LMissing);
  Ok(AName + ': no edit', LEdits = nil);
  Ok(AName + ': refused', (Length(LRefused) >= 1) and
    LRefused[0].StartsWith(AEntry + ': ') and LRefused[0].Contains(AWhy),
    string.Join('; ', LRefused));
end;

procedure Cases;
var
  LTree: TPasTree;
  LEdits: TArray<TPasUsesRemoval>;
  LRefused, LMissing: TArray<string>;
  LText: string;
begin
  // One entry per line: the removed entry's line goes with it.
  Check('middle of a column', UnitText('uses'#13#10'  A,'#13#10'  B,'#13#10 +
    '  C;', ''), ['B'], UnitText('uses'#13#10'  A,'#13#10'  C;', ''));
  Check('first of a column', UnitText('uses'#13#10'  A,'#13#10'  B,'#13#10 +
    '  C;', ''), ['A'], UnitText('uses'#13#10'  B,'#13#10'  C;', ''));
  Check('last of a column: the comma before it goes',
    UnitText('uses'#13#10'  A,'#13#10'  B,'#13#10'  C;', ''), ['C'],
    UnitText('uses'#13#10'  A,'#13#10'  B;', ''));
  Check('two apart in one clause: one edit',
    UnitText('uses'#13#10'  A,'#13#10'  B,'#13#10'  C,'#13#10'  D;', ''),
    ['A', 'C'], UnitText('uses'#13#10'  B,'#13#10'  D;', ''));
  // On one line.
  Check('on one line', UnitText('uses A, B, C;', ''), ['B'],
    UnitText('uses A, C;', ''));
  Check('a run ending the line', UnitText('uses A, B, C;', ''), ['B', 'C'],
    UnitText('uses A;', ''));
  // Every entry: the clause with its line, no blank line doubled.
  Check('whole clause', UnitText('uses A, B;', ''), ['A', 'B'],
    'unit U;'#13#10'interface'#13#10#13#10'implementation'#13#10#13#10 +
    'end.'#13#10);
  // A unit scope name matches the dotted entry.
  Check('Forms matches Vcl.Forms', UnitText('uses Vcl.Forms, A;', ''),
    ['Forms'], UnitText('uses A;', ''));
  // Both clauses, one edit each, in file order.
  LText := UnitText('uses A, B;', 'uses C, D;');
  Check('both clauses', LText, ['B', 'C'],
    UnitText('uses A;', 'uses D;'));
  LTree := Parse(LText);
  LEdits := UsesRemovalByName(LTree, ['C', 'B'], LRefused, LMissing);
  Ok('both clauses: in file order', (Length(LEdits) = 2) and
    (LEdits[0].Start < LEdits[1].Start));
  Ok('both clauses: Line:Col of the interface clause',
    (Length(LEdits) = 2) and (LEdits[0].Line = 3) and (LEdits[0].Col = 1));
  LEdits := UsesRemovalByName(LTree, ['Nope', 'A'], LRefused, LMissing);
  Ok('a name no clause holds is missing, the others answer',
    (Length(LEdits) = 1) and (Length(LMissing) = 1) and
    (LMissing[0] = 'Nope'));
  // A directive is never dropped: the entry goes with a comma of its own.
  // NOPE is not defined, so every entry is compiled - and in the tree.
  Check('directive kept: the comma before',
    UnitText('uses A{$IFNDEF NOPE}, B{$ENDIF};', ''), ['B'],
    UnitText('uses A{$IFNDEF NOPE}{$ENDIF};', ''));
  Check('directive kept: the comma after',
    UnitText('uses A, B{$IFNDEF NOPE}, C{$ENDIF};', ''), ['A'],
    UnitText('uses B{$IFNDEF NOPE}, C{$ENDIF};', ''));
  // Refused, said per entry.
  CheckRefused('no comma without a directive',
    UnitText('uses A{$IFNDEF NOPE}, B{$ENDIF};', ''), ['A'], 'A',
    'a compiler directive stands between');
  CheckRefused('every visible entry with a directive',
    UnitText('uses A{$IFNDEF NOPE}, B{$ENDIF};', ''), ['A', 'B'], 'A',
    'every entry the compiler sees goes');
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
    Writeln(Format('UsesEditSmoke: %d passed, %d failed', [GPassed, GFailed]));
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
