unit PasTree.Format;

{
  PasTree - the formatter (stage F1: indentation and line breaks).

  THE MODEL: REWRITE THE GAPS, NEVER A TOKEN. The lexer is lossless - every
  character of a file is in exactly one token, comments and directives
  included - so a formatter that keeps every non-whitespace token of the
  ORIGINAL stream and recomputes only the whitespace between two of them
  cannot lose a comment, a directive, an inactive $IF branch or an
  include's text, and cannot rewrite the author's spelling of a construct
  the way the structural printer's canonical form does (`class(TBase);`,
  `[A][B]`). The tree only DECIDES each gap: which node owns the token after
  it (TPasOwnership), which line unit - a statement, a declaration, a
  section, a member - that token starts, and how deep that unit sits.

  THE ITEMS of one file, in order: every code token (a visible token of
  this file), every comment, every directive, and every skipped region (an
  inactive $IF branch, opaque as a whole). The gap between two items is
  pure whitespace; it is the only text an edit replaces.

  F1 DECIDES, PER GAP:
  - its line breaks: the author's, capped at MaxBlankLines blank lines, plus
    the FORCED ones the options ask for (one statement per line, `begin` on
    its own line, `end` / `else` / `until` on their own lines, one
    declaration per line, the section word alone). F1 never removes a line
    break the author wrote (but blank lines over the cap); a gap without a
    line break is F2's;
  - for a gap that ends a line: the indentation of the next line. A line that
    starts a unit takes the unit's column (UnitCol, from the tree); a line
    that starts with a closer (`end`, `until`, `else`) takes its construct's;
    any other line is a CONTINUATION and keeps its offset from the first
    token of the unit it continues, so a wrapped argument list aligned under
    its `(` stays aligned; a comment or directive line takes the column of
    the code line it introduces (a directive written in column 1 stays
    there).

  F2 DECIDES the gaps INSIDE a line, between two code tokens (SpaceRule):
  one space where the rules ask for one and the author wrote none (several
  are the author's alignment and stay), none where the rules ask for none
  and the two tokens lex back unchanged (MayTouch); and the case of a word
  (ItemText): reserved words, the directive words a node owns, a compiler
  directive's name, and the identifiers a leaf holds through the caller's
  TPasIdentCaseFunc. docs/formatter.md is the full account.

  KEPT AS WRITTEN - the gap is copied: next to a skipped region or an opaque
  token, inside asm (tfAsm), around a token the tree owns no node for, after
  the final `end.`, around a unit the parse flagged (nfError: error-tolerant
  is the primary mode, the half-typed statement at the caret is left alone,
  and a flagged unit's own column is its original one so what it contains
  is indented from where it really is), and anywhere in a one-line anonymous
  method. No break is FORCED next to a directive: a directive may cut across
  a construct, and the author's layout is the only safe one there.

  LEXICAL SAFETY (spec B.2, B.6.2, B.6.3). Whitespace is insignificant
  except inside a multiline string - one token, never touched - and where it
  separates two tokens that would otherwise lex as one. F1 only ever turns a
  gap into another gap that still contains at least one line break, or
  inserts a line break into a gap, so no two tokens can fuse; the `^` + blank
  of B.6.2 keeps its first character, which is all dcc reads after a caret.
  A `//` comment keeps the line break after it (no break is ever removed
  down to zero).
}

interface

uses
  PasTree.Types,
  PasTree.Preprocessor,
  PasTree.Ast;

type
  { Whether a statement after `then`, `do` or `else` goes onto its own line. }
  TPasFormatBreak = (fbAlways, fbKeep);

  { How a class of words is spelled: lower case, upper case, as written. }
  TPasFormatCase = (fcLower, fcUpper, fcKeep);

  TPasFormatOptions = record
    IndentStep: Integer;              // 2
    // Tab stops of the ORIGINAL text, for reading a column written with tabs.
    TabWidth: Integer;                // 8
    // Blank lines kept in a row; -1 keeps them all.
    MaxBlankLines: Integer;           // 2
    // `begin` of a routine body or of a statement's body on its own line.
    BeginOnNewLine: Boolean;          // True
    // `else` of an if on its own line, not after the `end` of its then part.
    ElseOnNewLine: Boolean;           // True
    StatementAfterThenDo: TPasFormatBreak; // fbAlways
    // Every statement of a statement list on its own line.
    OneStatementPerLine: Boolean;     // True
    // Every declaration, member and section on its own line; the section
    // word (`var`, `type`, `const`, `uses`) alone on its line.
    OneDeclPerLine: Boolean;          // True
    // A nested routine one step deeper than the routine declaring it.
    IndentNestedRoutines: Boolean;    // True
    // A directive written in column 1 stays in column 1.
    KeepDirectivesAtColumn1: Boolean; // True
    // A comment written in column 1 above declarations stays there.
    KeepCommentsAtColumn1: Boolean;   // True
    // Spacing inside a line (F2). Off: every gap without a line break is
    // kept as written. On: the spaces the rules below ask for are added
    // where none is, and removed where the rules say none - a run of
    // several spaces where one is asked for is the author's alignment and
    // is kept.
    NormalizeSpaces: Boolean;         // True
    // One space around `:=`, a binary operator and a declaration's `=`.
    SpaceAroundOperators: Boolean;    // True
    // One space after `,`, after `;` inside a line and after `:`.
    SpaceAfterSeparators: Boolean;    // True
    // No space inside `( )` and `[ ]`, before `,` `;` `:` `)` `]`, around `.`
    // and `..`, before the `(` of a call or a parameter list and the `[` of
    // an index, inside `< >` of type arguments, after a unary `-` `+` `@`,
    // around `^`.
    RemoveSpaces: Boolean;            // True
    // Reserved words (B.4.1): `begin`, `string`, `and`.
    ReservedWordCase: TPasFormatCase; // fcLower
    // Directive words in their directive position (B.4.2): `override`,
    // `read`, `out`, `on`, `abstract` - the identifier tokens a node owns.
    DirectiveWordCase: TPasFormatCase; // fcLower
    // A compiler directive's name: `{$IFDEF`, `{$R`.
    CompilerDirectiveCase: TPasFormatCase; // fcUpper
    // Wrapping (F5). A line whose code ends right of RightMargin breaks at
    // its best point: after a `,` of a list (`;` of a parameter list), after
    // a binary operator - the shallowest, the lowest precedence - and, last,
    // after `:=`; the new line one IndentStep right of its statement's or
    // declaration's column. Only adds line breaks; a line with no such
    // point stays long. 0 is no margin.
    RightMargin: Integer;             // 0 (120 is the margin when on)
    WrapLongLines: Boolean;           // False
    // Alignment (F5), each over consecutive single-line items - a blank
    // line, a comment line or another construct ends a group of them:
    // `:=` of assignments in one statement list,
    AlignAssignments: Boolean;        // False
    // `:` / `=` of declarations in one section or member list,
    AlignDeclColons: Boolean;         // False
    // the comment that ends a line, at one column down the lines.
    AlignTrailingComments: Boolean;   // False
    class function Default: TPasFormatOptions; static;
  end;

  { An identifier's spelling as the caller wants it - its declaration's, for
    a caller that resolves names - or AText unchanged. AVis is the token's
    visible index in the tree PasFormatEdits formats. }
  TPasIdentCaseFunc = reference to function(AVis: Integer;
    const AText: string): string;

  TPasTextEdit = record
    Start: Integer;    // 0-based offset into the file's source
    Len: Integer;
    Text: string;
  end;
  TPasTextEdits = TArray<TPasTextEdit>;

  { Style inference (F9): the rules of the formatter whose sites a sample
    counts - a site is a place the rule decides, and it agrees when the text
    already reads as the rule (on) would make it. }
  TPasFormatFact = (ffBeginOnNewLine, ffElseOnNewLine, ffStatementAfterThenDo,
    ffOneStatementPerLine, ffOneDeclPerLine, ffRemoveSpaces,
    ffSpaceAfterSeparators, ffSpaceAroundOperators, ffAlignAssignments,
    ffAlignDeclColons, ffAlignTrailingComments);

  TPasFormatTally = record
    Sites, Agree: Int64;
  end;

  { The classes of words a case option spells. }
  TPasFormatWordClass = (fwReserved, fwDirective, fwCompilerDirective);

  { What a set of files says about its own style, summed file by file
    (PasFormatTally) and read by PasInferFormatOptions. }
  TPasFormatSample = record
    Files: Integer;
    Lines: Int64;                     // lines with code or a comment
    Facts: array[TPasFormatFact] of TPasFormatTally;
    Lower, Upper, Mixed: array[TPasFormatWordClass] of Int64;
    // Gaps of N blank lines (10: ten or more).
    BlankRuns: array[1..10] of Int64;
    // Lines by length, trailing blanks aside (400: 400 or longer).
    LineLen: array[0..400] of Int64;
    // The lines a format re-indents with IndentStep 2, 3, 4, nested routines
    // indented or not, nothing else changed.
    Reindent: array[2..4, Boolean] of Int64;
    procedure Add(const AOther: TPasFormatSample);
  end;

  { One option as PasInferFormatOptions decided it. }
  TPasFormatInferNote = record
    Option: string;     // the TPasFormatOptions field
    Value: string;
    Evidence: string;   // what the sample showed
    Mixed: Boolean;     // no clear majority: the value keeps the text as is
                        // or is the default
  end;

{ The edits that format file AFileId of ATree (0: the main file), in
  ascending order, none overlapping. ATree must come from a parse of that
  file's current text. }
function PasFormatEdits(const ATree: TPasTree; AFileId: Integer;
  const AOptions: TPasFormatOptions): TPasTextEdits; overload;
{ The same, every identifier a leaf holds spelled as AIdentCase says (nil:
  as written). }
function PasFormatEdits(const ATree: TPasTree; AFileId: Integer;
  const AOptions: TPasFormatOptions;
  const AIdentCase: TPasIdentCaseFunc): TPasTextEdits; overload;

{ Range mode: the edits of PasFormatEdits that touch the text from AStart to
  AEnd (0-based offsets into the file's source, AEnd exclusive) - a gap's
  edit by the token after it, so formatting a selection re-indents its
  first line and leaves the line after it alone. Every column is still
  computed over the whole file: a range formats as it would in a format of
  the whole file, and the two agree edit for edit. }
function PasFormatRangeEdits(const ATree: TPasTree; AFileId: Integer;
  const AOptions: TPasFormatOptions; AStart, AEnd: Integer;
  const AIdentCase: TPasIdentCaseFunc = nil): TPasTextEdits;

{ AText formatted as a file of its own, parsed with no conditional symbol
  defined and no search path: for text a tool generated - the interface
  source PasTree.Dcu.Source prints for a compiled unit (a
  TPasSourceManager.DcuTextFilter), code a refactoring writes. AFileName
  names it for the parse only. }
function PasFormatText(const AText, AFileName: string;
  const AOptions: TPasFormatOptions): string;

{ ASource with AEdits applied (ascending, not overlapping - as
  PasFormatEdits returns them). }
function PasApplyEdits(const ASource: string;
  const AEdits: TPasTextEdits): string;

{ G-tok: do the two texts hold the same tokens but whitespace, each with the
  same text - a word and a compiler directive with the same text but for
  case, when AWordCase (what the case options may change)? AMsg names the
  first difference. }
function PasSameTokens(const AOld, ANew: string; out AMsg: string;
  AWordCase: Boolean = True): Boolean;

{ Style inference (F9). Adds what file AFileId of ATree shows about its
  style to ASample: the formatter is run over it with every rule on and
  counts, at each place a rule decides, whether the text already agrees -
  so a sample measures exactly the rules the formatter applies. Asm, a
  skipped region and a unit the parse flagged count nothing. }
procedure PasFormatTally(const ATree: TPasTree; AFileId: Integer;
  var ASample: TPasFormatSample);

{ The options a sample's files are written in, and a note per option: a rule
  that agrees at 90% of its sites or more is on, one that agrees at 10% or
  less off; between, off - the formatter keeps the text as written - and
  the note says Mixed. A case class is lower or upper at 90% and kept
  otherwise; alignment is on at 60%. The indent step and nested routines'
  indentation are those that re-indent the fewest lines, the blank-line cap
  the smallest that 99% of the blank runs fit under, the right margin (and
  wrapping) the smallest of 80, 100, 120 that 99.5% of the lines fit in. A
  rule with fewer than 20 sites (alignment 10) keeps its default. TabWidth
  and the column-1 options keep theirs: they keep text, never change it. }
function PasInferFormatOptions(const ASample: TPasFormatSample;
  out ANotes: TArray<TPasFormatInferNote>): TPasFormatOptions;

implementation

uses
  System.SysUtils,
  PasTree.Lexer,
  PasTree.SourceManager,
  PasTree.Parser,
  PasTree.Printer;

class function TPasFormatOptions.Default: TPasFormatOptions;
begin
  Result.IndentStep := 2;
  Result.TabWidth := 8;
  Result.MaxBlankLines := 2;
  Result.BeginOnNewLine := True;
  Result.ElseOnNewLine := True;
  Result.StatementAfterThenDo := fbAlways;
  Result.OneStatementPerLine := True;
  Result.OneDeclPerLine := True;
  Result.IndentNestedRoutines := True;
  Result.KeepDirectivesAtColumn1 := True;
  Result.KeepCommentsAtColumn1 := True;
  Result.NormalizeSpaces := True;
  Result.SpaceAroundOperators := True;
  Result.SpaceAfterSeparators := True;
  Result.RemoveSpaces := True;
  Result.ReservedWordCase := fcLower;
  Result.DirectiveWordCase := fcLower;
  Result.CompilerDirectiveCase := fcUpper;
  Result.RightMargin := 0;
  Result.WrapLongLines := False;
  Result.AlignAssignments := False;
  Result.AlignDeclColons := False;
  Result.AlignTrailingComments := False;
end;

const
  STMT_KINDS = [nkBlock, nkAssign, nkExprStmt, nkIfStmt, nkCaseStmt,
    nkForStmt, nkForInStmt, nkWhileStmt, nkRepeatStmt, nkWithStmt,
    nkGotoStmt, nkLabeledStmt, nkTryStmt, nkRaiseStmt, nkAsmStmt,
    nkInlineVar, nkInlineConst];
  DECL_KINDS = [nkTypeDecl, nkConstDecl, nkVarDecl, nkVisibility, nkRoutine,
    nkPropertyDecl, nkMethodResolution, nkVariantPart, nkVariantBranch];
  SECTION_KINDS = [nkUsesClause, nkInterfaceSec, nkImplementationSec,
    nkInitSec, nkFinalSec, nkExportsClause, nkTypeSec, nkConstSec, nkVarSec,
    nkLabelSec];
  // A line unit: a node whose first token starts a line in canonical layout.
  UNIT_KINDS = STMT_KINDS + DECL_KINDS + SECTION_KINDS + [nkCaseSel,
    nkExceptOn, nkExceptPart, nkFinallyPart, nkUsesItem];
  STRUCT_KINDS = [nkClassType, nkRecordType, nkObjectType, nkInterfaceType,
    nkHelperType];
  ROOT_KINDS = [nkUnit, nkProgram, nkLibrary, nkPackage];
  // The statements whose last child is a body (then / else for an if).
  BODY_OWNERS = [nkIfStmt, nkWhileStmt, nkForStmt, nkForInStmt, nkWithStmt,
    nkExceptOn];
  // A block that stands for a statement list, with no begin / end of its own.
  HEADLESS_OWNERS = [nkTryStmt, nkFinallyPart, nkRepeatStmt, nkExceptPart,
    nkCaseStmt];

type
  TFmtItemKind = (fiCode, fiComment, fiDirective, fiOpaque);

  TFmtItem = record
    Kind: TFmtItemKind;
    Start, EndPos: Integer;
    Vis: Integer;       // fiCode: the visible index
    InAsm: Boolean;
    AfterEnd: Boolean;  // after the root's final `end.`
  end;

  TFormatter = record
  private
    T: ^TPasTree;
    O: TPasFormatOptions;
    FileId: Integer;
    Src: string;
    Stream: ^TPasTokenStream;
    Own: TPasOwnership;
    Items: TArray<TFmtItem>;
    Leftmost: TArray<Integer>;      // per node
    Lead: TArray<Integer>;          // per node, -1 when not a unit
    UnitAt: TArray<Integer>;        // per vis: the OUTERMOST unit led by it
    ForcedAt: TArray<Boolean>;      // per vis: a forced break before it
    NearUnit: TArray<Integer>;      // per node: nearest unit, itself included
    Flagged: TArray<Boolean>;       // per node: a unit the parse flagged
    ColMemo: TArray<Integer>;       // per node, -2 unknown
    CodeColMemo: TArray<Integer>;   // per vis, -2 unknown
    TokCol: TArray<Integer>;        // per vis: its output column, -1 unknown
    LineIndentAt: TArray<Integer>;  // per vis: the output indent of its line
    StartsLineAt: TArray<Boolean>;  // per vis
    NL: TArray<Integer>;            // per item: line breaks of the gap before it
    ItemCol: TArray<Integer>;       // per item: its output column
    CommentCont: TArray<Boolean>;   // per item: continues a trailing comment
    Kept: TArray<Boolean>;          // per item: the gap before it is copied
    // F5. Per item: the spaces of the gap before it inside a line (-1: the
    // F2 rule), the column of a line a wrap started (-1: none), its output
    // line. Per vis: its item.
    GapSet: TArray<Integer>;
    WrapColAt: TArray<Integer>;
    OutLine: TArray<Integer>;
    VisItem: TArray<Integer>;
    LineBreak: string;
    IdentCase: TPasIdentCaseFunc;
    // F9, a tally run: the sample counted into (nil otherwise), the rule the
    // last ForcedUnit / ForcedCloser / SpaceRule consulted (Ord of a
    // TPasFormatFact; -1 none, -2 a break no option decides) and, per vis,
    // the rule that forces the break before it.
    Tally: ^TPasFormatSample;
    LastFact: Integer;
    FactAt: TArray<Integer>;
    function Rule(AOn: Boolean; AFact: TPasFormatFact): Boolean;
    procedure CountWord(AClass: TPasFormatWordClass; const AText: string);
    procedure TallySpace(AItem, ASpaces, AOrigSpaces: Integer);
    procedure TallyGroup(AFact: TPasFormatFact; const AGroup: TArray<Integer>;
      ACount: Integer);
    procedure Init(const ATree: TPasTree; AFileId: Integer;
      const AOptions: TPasFormatOptions);
    procedure BuildItems;
    procedure BuildUnits;
    function OrigCol(AOffset: Integer): Integer;
    function LineOf(AOffset: Integer): Integer;
    function VisStart(AVis: Integer): Integer;
    function VisKind(AVis: Integer): TPasTokenKind;
    function InFile(AVis: Integer): Boolean;
    function IsUnit(ANode: Integer): Boolean;
    function Kind(ANode: Integer): TPasNodeKind;
    function Parent(ANode: Integer): Integer;
    function HasMembers(AStruct: Integer): Boolean;
    function HeadlessBlock(ABlock: Integer): Boolean;
    function VarSecHeaded(ASec: Integer): Boolean;
    function OneLineAnon(ANode: Integer): Boolean;
    function UnitFlagged(AUnit: Integer): Boolean;
    function VisFlagged(AVis: Integer): Boolean;
    procedure NoteFact(AVis: Integer);
    function ForcedUnit(AUnit: Integer): Boolean;
    function CloserOwner(AVis: Integer): Integer;
    function ForcedCloser(AVis: Integer): Boolean;
    function UnitCol(AUnit: Integer): Integer;
    function BaseCol(ANode: Integer): Integer;
    function AnonCol(AAnon: Integer): Integer;
    function CloserCol(AVis: Integer): Integer;
    function ContinuationCol(AVis, AOrigCol: Integer): Integer;
    function IsContinuation(AVis: Integer): Boolean;
    function CodeCol(AVis: Integer): Integer;
    function CommentCol(AItem: Integer): Integer;
    function CountBreaks(AStart, AEnd: Integer; out AFirst: string): Integer;
    function SpaceRule(AA, AB: Integer): Integer;
    function MayTouch(AA, AB: Integer): Boolean;
    function ItemText(AItem: Integer): string;
    procedure Layout(AEmit: Boolean; var AEdits: TPasTextEdits;
      var ACount: Integer);
    function ItemLen(AItem: Integer): Integer;
    function Spans(AItem: Integer): Boolean;
    function LineEnd(AItem: Integer): Integer;
    function PlainLine(AFirst, AEnd: Integer): Boolean;
    function WrapRank(AItem: Integer): Integer;
    function WrapLine(AFirst, AEnd: Integer): Integer;
    function WrapLines: Integer;
    function AlignTok(ANode: Integer): Integer;
    procedure AlignGaps(ABaseOnly: Boolean);
    procedure AlignComments;
    function Run: TPasTextEdits;
  end;

{ TFormatter }

procedure TFormatter.Init(const ATree: TPasTree; AFileId: Integer;
  const AOptions: TPasFormatOptions);
begin
  T := @ATree;
  O := AOptions;
  if O.IndentStep < 0 then
    O.IndentStep := 0;
  if O.TabWidth < 1 then
    O.TabWidth := 1;
  FileId := AFileId;
  Stream := @ATree.Source.Files[AFileId];
  Src := Stream^.Source;
  Own.Build(ATree);
  if Pos(#13#10, Src) > 0 then
    LineBreak := #13#10
  else if Pos(#10, Src) > 0 then
    LineBreak := #10
  else
    LineBreak := sLineBreak;
end;

function TFormatter.Kind(ANode: Integer): TPasNodeKind;
begin
  Result := T^.Nodes[ANode].Kind;
end;

function TFormatter.Parent(ANode: Integer): Integer;
begin
  Result := T^.Nodes[ANode].Parent;
end;

function TFormatter.VisKind(AVis: Integer): TPasTokenKind;
begin
  Result := T^.Source.VisibleKind(AVis);
end;

function TFormatter.InFile(AVis: Integer): Boolean;
begin
  Result := (AVis >= 0) and (AVis <= High(T^.Source.Visible)) and
    (T^.Source.Visible[AVis].FileId = FileId);
end;

function TFormatter.VisStart(AVis: Integer): Integer;
begin
  Result := Stream^.Tokens[T^.Source.Visible[AVis].TokenIndex].Start;
end;

function TFormatter.LineOf(AOffset: Integer): Integer;
var
  LLo, LHi, LMid: Integer;
begin
  LLo := 0;
  LHi := High(Stream^.LineStarts);
  while LLo < LHi do
  begin
    LMid := (LLo + LHi + 1) div 2;
    if Stream^.LineStarts[LMid] <= AOffset then
      LLo := LMid
    else
      LHi := LMid - 1;
  end;
  Result := LLo;
end;

function TFormatter.OrigCol(AOffset: Integer): Integer;
var
  LIdx: Integer;
begin
  Result := 0;
  if Length(Stream^.LineStarts) = 0 then
    Exit;
  for LIdx := Stream^.LineStarts[LineOf(AOffset)] to AOffset - 1 do
    if Src[LIdx + 1] = #9 then
      Result := (Result div O.TabWidth + 1) * O.TabWidth
    else
      Inc(Result);
end;

procedure TFormatter.BuildItems;
var
  LRawToVis: TArray<Integer>;
  LRegions: TArray<TPasSkippedRegion>;
  LIdx, LRegion, LCount, LRootEnd, LOwnIdx: Integer;
  LTok: TPasToken;
  LItem: TFmtItem;

  procedure Add(const AItem: TFmtItem);
  begin
    if LCount = Length(Items) then
      SetLength(Items, LCount * 2 + 64);
    Items[LCount] := AItem;
    Inc(LCount);
  end;

begin
  SetLength(LRawToVis, Length(Stream^.Tokens));
  for LIdx := 0 to High(LRawToVis) do
    LRawToVis[LIdx] := -1;
  for LIdx := 0 to High(T^.Source.Visible) do
    if T^.Source.Visible[LIdx].FileId = FileId then
      LRawToVis[T^.Source.Visible[LIdx].TokenIndex] := LIdx;
  if FileId <= High(T^.Source.Skipped) then
    LRegions := T^.Source.Skipped[FileId]
  else
    LRegions := nil;
  // The root's final `.`: what follows it is text dcc ignores.
  LRootEnd := MaxInt;
  if Length(T^.Nodes) > 0 then
    for LOwnIdx := Own.OwnStart[0] to Own.OwnStart[1] - 1 do
      if (VisKind(Own.Own[LOwnIdx]) = tkDot) and InFile(Own.Own[LOwnIdx]) then
        LRootEnd := VisStart(Own.Own[LOwnIdx]);
  LCount := 0;
  LRegion := 0;
  LIdx := 0;
  while LIdx <= High(Stream^.Tokens) do
  begin
    LTok := Stream^.Tokens[LIdx];
    if LTok.Kind = tkEndOfFile then
      Break;
    while (LRegion <= High(LRegions)) and
      (LRegions[LRegion].EndPos <= LTok.Start) do
      Inc(LRegion);
    if (LRegion <= High(LRegions)) and (LTok.Start >= LRegions[LRegion].Start) then
    begin
      LItem := Default(TFmtItem);
      LItem.Kind := fiOpaque;
      LItem.Start := LRegions[LRegion].Start;
      LItem.EndPos := LRegions[LRegion].EndPos;
      LItem.Vis := -1;
      Add(LItem);
      while (LIdx <= High(Stream^.Tokens)) and
        (Stream^.Tokens[LIdx].Kind <> tkEndOfFile) and
        (Stream^.Tokens[LIdx].Start < LRegions[LRegion].EndPos) do
        Inc(LIdx);
      Inc(LRegion);
      Continue;
    end;
    if LTok.Kind <> tkWhitespace then
    begin
      LItem := Default(TFmtItem);
      LItem.Start := LTok.Start;
      LItem.EndPos := LTok.Start + LTok.Len;
      LItem.Vis := -1;
      LItem.InAsm := tfAsm in LTok.Flags;
      LItem.AfterEnd := LTok.Start > LRootEnd;
      case LTok.Kind of
        tkCommentLine, tkCommentBrace, tkCommentParen:
          LItem.Kind := fiComment;
        tkDirective:
          LItem.Kind := fiDirective;
      else
        if LRawToVis[LIdx] >= 0 then
        begin
          LItem.Kind := fiCode;
          LItem.Vis := LRawToVis[LIdx];
        end
        else
          LItem.Kind := fiOpaque;
      end;
      Add(LItem);
    end;
    Inc(LIdx);
  end;
  SetLength(Items, LCount);
end;

function TFormatter.IsUnit(ANode: Integer): Boolean;
begin
  Result := (ANode >= 0) and (Lead[ANode] >= 0);
end;

function TFormatter.HeadlessBlock(ABlock: Integer): Boolean;
var
  LParent: Integer;
begin
  LParent := Parent(ABlock);
  Result := (Kind(ABlock) = nkBlock) and
    ((LParent = NIL_NODE) or (Kind(LParent) in HEADLESS_OWNERS));
end;

function TFormatter.VarSecHeaded(ASec: Integer): Boolean;
var
  LFirst: Integer;
begin
  LFirst := Leftmost[ASec];
  Result := (LFirst >= 0) and ((VisKind(LFirst) in [tkVar, tkThreadvar]) or
    ((LFirst > 0) and (VisKind(LFirst - 1) in [tkVar, tkThreadvar])));
end;

procedure TFormatter.BuildUnits;
var
  LNode, LLead, LCount, LVis, LChild: Integer;
  LNodeRec: TPasNode;
begin
  LCount := Length(T^.Nodes);
  SetLength(Leftmost, LCount);
  SetLength(Lead, LCount);
  SetLength(NearUnit, LCount);
  SetLength(ColMemo, LCount);
  for LNode := 0 to LCount - 1 do
  begin
    Leftmost[LNode] := T^.NodeLeftmostVis(LNode);
    ColMemo[LNode] := -2;
    Lead[LNode] := -1;
  end;
  SetLength(UnitAt, Length(T^.Source.Visible));
  SetLength(ForcedAt, Length(T^.Source.Visible));
  SetLength(CodeColMemo, Length(T^.Source.Visible));
  SetLength(TokCol, Length(T^.Source.Visible));
  SetLength(LineIndentAt, Length(T^.Source.Visible));
  SetLength(StartsLineAt, Length(T^.Source.Visible));
  for LVis := 0 to High(UnitAt) do
  begin
    UnitAt[LVis] := NIL_NODE;
    CodeColMemo[LVis] := -2;
    TokCol[LVis] := -1;
    LineIndentAt[LVis] := 0;
  end;
  for LNode := 0 to LCount - 1 do
  begin
    LNodeRec := T^.Nodes[LNode];
    if not (LNodeRec.Kind in UNIT_KINDS) then
      Continue;
    if LNodeRec.LastToken < LNodeRec.FirstToken then
      Continue;                       // owns nothing: nkEmptyStmt and the like
    LLead := Leftmost[LNode];
    if LLead < 0 then
      Continue;
    // The head words a member's or a struct var section's list owns.
    if (LNodeRec.Kind = nkVarSec) and not (VisKind(LLead) in [tkVar, tkThreadvar])
      and (LLead > 0) and (VisKind(LLead - 1) in [tkVar, tkThreadvar]) then
      Dec(LLead);
    if (LNodeRec.Kind in [nkRoutine, nkPropertyDecl, nkVarSec]) and
      (LNodeRec.Aux = 1) and (LLead > 0) and (VisKind(LLead - 1) = tkClass) then
      Dec(LLead);
    Lead[LNode] := LLead;
  end;
  // Attribute groups a list holds as the siblings before a declaration
  // (`[Weak] FRef: TObject` in a class body) lead it.
  for LNode := 0 to LCount - 1 do
  begin
    LVis := -1;
    LChild := T^.Nodes[LNode].FirstChild;
    while LChild <> NIL_NODE do
    begin
      if Kind(LChild) = nkAttrGroup then
      begin
        if LVis < 0 then
          LVis := Leftmost[LChild];
      end
      else
      begin
        if (LVis >= 0) and (Lead[LChild] >= 0) and (LVis < Lead[LChild]) then
          Lead[LChild] := LVis;
        LVis := -1;
      end;
      LChild := T^.Nodes[LChild].NextSibling;
    end;
  end;
  // The outermost unit each token leads, and whether any of them forces a
  // break before it. Nodes are visited from the root down by depth, so a
  // later (deeper) unit never replaces an outer one: compare depths.
  for LNode := 0 to LCount - 1 do
    if Lead[LNode] >= 0 then
    begin
      LVis := Lead[LNode];
      if (UnitAt[LVis] = NIL_NODE) then
        UnitAt[LVis] := LNode
      else
      begin
        // Keep the outer one: the one that is an ancestor of the other.
        LLead := LNode;
        while (LLead <> NIL_NODE) and (LLead <> UnitAt[LVis]) do
          LLead := Parent(LLead);
        if LLead = NIL_NODE then
          UnitAt[LVis] := LNode;      // LNode is the outer one
      end;
    end;
  for LNode := 0 to LCount - 1 do
  begin
    LLead := LNode;
    while (LLead <> NIL_NODE) and (Lead[LLead] < 0) do
      LLead := Parent(LLead);
    NearUnit[LNode] := LLead;
  end;
  // A unit is flagged when the parse said so (nfError) or holds a node the
  // parse made up (nkError, nkMissing) - not every recovery sets the flag.
  SetLength(Flagged, LCount);
  for LNode := 0 to LCount - 1 do
  begin
    if nfError in T^.Nodes[LNode].Flags then
      Flagged[LNode] := True;
    if (Kind(LNode) in [nkError, nkMissing]) and (NearUnit[LNode] <> NIL_NODE) then
      Flagged[NearUnit[LNode]] := True;
  end;
  if Tally <> nil then
  begin
    SetLength(FactAt, Length(ForcedAt));
    for LVis := 0 to High(FactAt) do
      FactAt[LVis] := -1;
  end;
  for LNode := 0 to LCount - 1 do
    if (Lead[LNode] >= 0) and ForcedUnit(LNode) then
    begin
      ForcedAt[Lead[LNode]] := True;
      NoteFact(Lead[LNode]);
    end;
  for LVis := 0 to High(ForcedAt) do
    if (Own.Owner[LVis] >= 0) and ForcedCloser(LVis) then
    begin
      ForcedAt[LVis] := True;
      NoteFact(LVis);
    end;
end;

// A tally run's options have every rule on, so a forced break is a site of
// the rule that forced it; a break no option decides is no site, whatever
// else asks for it.
procedure TFormatter.NoteFact(AVis: Integer);
begin
  if Tally = nil then
    Exit;
  if LastFact = -2 then
    FactAt[AVis] := -2
  else if (LastFact >= 0) and (FactAt[AVis] = -1) then
    FactAt[AVis] := LastFact;
end;

// A gap inside a line SpaceRule decided by rule LastFact: 1 agrees with a
// space or more, 0 with none - or with several before a `:`, the author's
// alignment F2 keeps; a gap that may not shrink is no site.
procedure TFormatter.TallySpace(AItem, ASpaces, AOrigSpaces: Integer);
var
  LAgree: Boolean;
begin
  if ASpaces = 1 then
    LAgree := AOrigSpaces >= 1
  else if AOrigSpaces = 0 then
    LAgree := True
  else if (AOrigSpaces > 1) and (VisKind(Items[AItem].Vis) = tkColon) then
    LAgree := True
  else if MayTouch(AItem - 1, AItem) then
    LAgree := False
  else
    Exit;
  Inc(Tally^.Facts[TPasFormatFact(LastFact)].Sites);
  if LAgree then
    Inc(Tally^.Facts[TPasFormatFact(LastFact)].Agree);
end;

// A group alignment would line up (AGroup: the items of the aligned tokens,
// each after the text it is aligned past): a site when that text ends at
// different columns in the original on each line, agreeing when the tokens
// already stand at one column.
procedure TFormatter.TallyGroup(AFact: TPasFormatFact;
  const AGroup: TArray<Integer>; ACount: Integer);
var
  LIdx, LEnd0, LCol0: Integer;
  LDiffer, LAligned: Boolean;
begin
  if ACount < 2 then
    Exit;
  LEnd0 := OrigCol(Items[AGroup[0] - 1].EndPos);
  LCol0 := OrigCol(Items[AGroup[0]].Start);
  LDiffer := False;
  LAligned := True;
  for LIdx := 0 to ACount - 1 do
  begin
    // Both on one original line: the token was written after its text.
    if LineOf(Items[AGroup[LIdx] - 1].EndPos) <>
      LineOf(Items[AGroup[LIdx]].Start) then
      Exit;
    if OrigCol(Items[AGroup[LIdx] - 1].EndPos) <> LEnd0 then
      LDiffer := True;
    if OrigCol(Items[AGroup[LIdx]].Start) <> LCol0 then
      LAligned := False;
  end;
  if not LDiffer then
    Exit;
  Inc(Tally^.Facts[AFact].Sites);
  if LAligned then
    Inc(Tally^.Facts[AFact].Agree);
end;

function TFormatter.Rule(AOn: Boolean; AFact: TPasFormatFact): Boolean;
begin
  LastFact := Ord(AFact);
  Result := AOn;
end;

procedure TFormatter.CountWord(AClass: TPasFormatWordClass;
  const AText: string);
begin
  if (Tally = nil) or (AText = '') then
    Exit;
  if AText = LowerCase(AText) then
    Inc(Tally^.Lower[AClass])
  else if AText = UpperCase(AText) then
    Inc(Tally^.Upper[AClass])
  else
    Inc(Tally^.Mixed[AClass]);
end;

function TFormatter.HasMembers(AStruct: Integer): Boolean;
var
  LChild: Integer;
begin
  LChild := T^.Nodes[AStruct].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if Kind(LChild) in UNIT_KINDS then
      Exit(True);
    LChild := T^.Nodes[LChild].NextSibling;
  end;
  Result := False;
end;

function TFormatter.OneLineAnon(ANode: Integer): Boolean;
var
  LNode, LFirst, LLast: Integer;
begin
  LNode := ANode;
  while LNode <> NIL_NODE do
  begin
    if Kind(LNode) = nkAnonMethod then
    begin
      LFirst := Leftmost[LNode];
      LLast := T^.Nodes[LNode].LastToken;
      if InFile(LFirst) and InFile(LLast) and
        (LineOf(VisStart(LFirst)) = LineOf(VisStart(LLast))) then
        Exit(True);
    end;
    LNode := Parent(LNode);
  end;
  Result := False;
end;

function TFormatter.UnitFlagged(AUnit: Integer): Boolean;
begin
  Result := (AUnit <> NIL_NODE) and Flagged[AUnit];
end;

function TFormatter.VisFlagged(AVis: Integer): Boolean;
var
  LOwner: Integer;
begin
  LOwner := Own.Owner[AVis];
  if LOwner < 0 then
    Exit(True);
  if Kind(LOwner) in [nkError, nkMissing] then
    Exit(True);
  Result := UnitFlagged(NearUnit[LOwner]);
end;

function TFormatter.ForcedUnit(AUnit: Integer): Boolean;
var
  LParent: Integer;
  LKind: TPasNodeKind;
begin
  Result := False;
  LastFact := -1;
  LParent := Parent(AUnit);
  LKind := Kind(AUnit);
  if (LParent <> NIL_NODE) and OneLineAnon(AUnit) then
    Exit;
  if LParent = NIL_NODE then
    Exit;
  if LKind = nkUsesItem then
  begin
    if T^.Nodes[LParent].FirstChild = AUnit then
      Result := Rule(O.OneDeclPerLine, ffOneDeclPerLine);
    Exit;
  end;
  if LKind in STMT_KINDS then
  begin
    case Kind(LParent) of
      nkBlock, nkInitSec, nkFinalSec:
        Result := Rule(O.OneStatementPerLine, ffOneStatementPerLine);
      nkRoutineBody:
        Result := Rule(O.BeginOnNewLine, ffBeginOnNewLine);
      nkUnit, nkProgram, nkLibrary, nkPackage:
        begin
          Result := True;             // a program's main block
          LastFact := -2;
        end;
      nkTryStmt, nkFinallyPart, nkRepeatStmt, nkExceptPart, nkCaseStmt:
        if HeadlessBlock(AUnit) then
          Result := Rule(O.OneStatementPerLine, ffOneStatementPerLine);
      nkIfStmt, nkWhileStmt, nkForStmt, nkForInStmt, nkWithStmt, nkExceptOn:
        if T^.Nodes[LParent].FirstChild = AUnit then
          Result := False             // a for's inline var counter
        else if LKind = nkBlock then
          Result := Rule(O.BeginOnNewLine, ffBeginOnNewLine)
        else if (Kind(LParent) = nkIfStmt) and (LKind = nkIfStmt) and
          (T^.LastChild(LParent) = AUnit) and
          (T^.Nodes[LParent].FirstChild <> NIL_NODE) and
          (T^.Nodes[T^.Nodes[LParent].FirstChild].NextSibling <> AUnit) then
          Result := False             // `else if`
        else
          Result := Rule(O.StatementAfterThenDo = fbAlways,
            ffStatementAfterThenDo);
    end;
    Exit;
  end;
  // `private type` / `public const`: a struct's section on its visibility's
  // line stays there.
  if (LKind in SECTION_KINDS) and (Kind(LParent) in STRUCT_KINDS) and
    (Lead[AUnit] > 0) and (Own.Owner[Lead[AUnit] - 1] >= 0) and
    (Kind(Own.Owner[Lead[AUnit] - 1]) = nkVisibility) then
    Exit;
  case LKind of
    nkCaseSel, nkExceptOn, nkExceptPart, nkFinallyPart:
      begin
        Result := True;
        LastFact := -2;
      end;
    nkVarDecl:
      // `class var FNull: TBinaryWriter;` - a struct's var section keeps its
      // first field on its head word's line.
      if (Kind(LParent) <> nkVariantBranch) and
        not ((Kind(LParent) = nkVarSec) and (Parent(LParent) <> NIL_NODE) and
        (Kind(Parent(LParent)) in STRUCT_KINDS) and
        (T^.Nodes[LParent].FirstChild = AUnit)) then
        Result := Rule(O.OneDeclPerLine, ffOneDeclPerLine);
  else
    if LKind in DECL_KINDS + SECTION_KINDS then
      Result := Rule(O.OneDeclPerLine, ffOneDeclPerLine);
  end;
end;

// The node a closer keyword closes, NIL_NODE when AVis is no closer.
function TFormatter.CloserOwner(AVis: Integer): Integer;
var
  LOwner: Integer;
begin
  Result := NIL_NODE;
  LOwner := Own.Owner[AVis];
  if LOwner < 0 then
    Exit;
  case VisKind(AVis) of
    tkEnd:
      if (Kind(LOwner) in ROOT_KINDS + STRUCT_KINDS + [nkCaseStmt, nkTryStmt]) or
        ((Kind(LOwner) = nkBlock) and not HeadlessBlock(LOwner)) then
        Result := LOwner;
    tkUntil:
      if Kind(LOwner) = nkRepeatStmt then
        Result := LOwner;
    tkElse:
      if Kind(LOwner) in [nkIfStmt, nkCaseStmt, nkExceptPart] then
        Result := LOwner
      else if (Kind(LOwner) = nkBlock) and (Parent(LOwner) <> NIL_NODE) and
        (Kind(Parent(LOwner)) in [nkCaseStmt, nkExceptPart]) then
        Result := Parent(LOwner);  // the else block owns its `else`
  end;
end;

function TFormatter.ForcedCloser(AVis: Integer): Boolean;
var
  LOwner: Integer;
begin
  LOwner := CloserOwner(AVis);
  Result := False;
  LastFact := -1;
  if LOwner = NIL_NODE then
    Exit;
  if OneLineAnon(LOwner) then
    Exit;
  if Kind(LOwner) in STRUCT_KINDS then
  begin
    if HasMembers(LOwner) then
      Result := Rule(O.OneDeclPerLine, ffOneDeclPerLine);
  end
  else if (VisKind(AVis) = tkElse) and (Kind(LOwner) = nkIfStmt) then
    Result := Rule(O.ElseOnNewLine, ffElseOnNewLine)
  else if Kind(LOwner) = nkBlock then
    Result := Rule(O.OneStatementPerLine, ffOneStatementPerLine)
  else
  begin
    Result := True;
    LastFact := -2;
  end;
end;

function TFormatter.AnonCol(AAnon: Integer): Integer;
var
  LFirst, LBody: Integer;
begin
  LFirst := Leftmost[AAnon];
  if (LFirst < 0) or not InFile(LFirst) or (TokCol[LFirst] < 0) then
    Exit(BaseCol(Parent(AAnon)) + O.IndentStep);
  if StartsLineAt[LFirst] then
    Exit(TokCol[LFirst]);
  // `Run(procedure` with the body's `begin` written under its `procedure`:
  // the body stays under it. Otherwise one step in from the line.
  LBody := T^.LastChild(AAnon);
  if (LBody <> NIL_NODE) and (Kind(LBody) = nkRoutineBody) then
    LBody := T^.LastChild(LBody);
  if (LBody <> NIL_NODE) and IsUnit(LBody) and InFile(Lead[LBody]) and
    (OrigCol(VisStart(Lead[LBody])) = OrigCol(VisStart(LFirst))) and
    (LineOf(VisStart(Lead[LBody])) > LineOf(VisStart(LFirst))) then
    Result := TokCol[LFirst]
  else
    Result := LineIndentAt[LFirst] + O.IndentStep;
end;

function TFormatter.BaseCol(ANode: Integer): Integer;
begin
  if ANode = NIL_NODE then
    Exit(0);
  if IsUnit(ANode) then
  begin
    // A unit that shares its line with what comes before it (`private
    // type`, `1: begin`, `else if`) lays out what it holds from that line.
    if InFile(Lead[ANode]) and (TokCol[Lead[ANode]] >= 0) and
      not StartsLineAt[Lead[ANode]] then
      Exit(LineIndentAt[Lead[ANode]]);
    Exit(UnitCol(ANode));
  end;
  if Kind(ANode) = nkAnonMethod then
    Exit(AnonCol(ANode));
  if Kind(ANode) in ROOT_KINDS then
    Exit(0);
  Result := BaseCol(Parent(ANode));
end;

function TFormatter.UnitCol(AUnit: Integer): Integer;
var
  LParent, LRoutine, LStep: Integer;
  LKind: TPasNodeKind;
begin
  if ColMemo[AUnit] <> -2 then
    Exit(ColMemo[AUnit]);
  LStep := O.IndentStep;
  LParent := Parent(AUnit);
  LKind := Kind(AUnit);
  if UnitFlagged(AUnit) and InFile(Lead[AUnit]) then
    // A flagged unit stands where it is written; what it holds is laid out
    // from there.
    Result := OrigCol(VisStart(Lead[AUnit]))
  else if LParent = NIL_NODE then
    Result := 0
  else
    case Kind(LParent) of
      nkUnit, nkProgram, nkLibrary, nkPackage,
      nkInterfaceSec, nkImplementationSec:
        Result := 0;
      nkInitSec, nkFinalSec, nkUsesClause, nkExportsClause, nkTypeSec,
      nkConstSec, nkLabelSec, nkVariantPart, nkVariantBranch,
      nkExceptPart, nkFinallyPart, nkRepeatStmt, nkCaseStmt, nkCaseSel:
        Result := BaseCol(LParent) + LStep;
      nkVarSec:
        if VarSecHeaded(LParent) then
          Result := BaseCol(LParent) + LStep
        else
          Result := BaseCol(LParent);
      nkClassType, nkRecordType, nkObjectType, nkInterfaceType, nkHelperType:
        if LKind = nkVisibility then
          Result := BaseCol(LParent)
        else
          Result := BaseCol(LParent) + LStep;
      nkRoutineBody:
        begin
          LRoutine := Parent(LParent);
          Result := BaseCol(LRoutine);
          if (LKind = nkRoutine) and O.IndentNestedRoutines then
            Inc(Result, LStep);
        end;
      nkBlock:
        if HeadlessBlock(LParent) then
          Result := BaseCol(LParent)
        else
          Result := BaseCol(LParent) + LStep;
      nkTryStmt:
        if LKind = nkBlock then
          Result := BaseCol(LParent) + LStep
        else
          Result := BaseCol(LParent);
      nkIfStmt, nkWhileStmt, nkForStmt, nkForInStmt, nkWithStmt, nkExceptOn:
        if LKind = nkBlock then
          Result := BaseCol(LParent)
        else if (Kind(LParent) = nkIfStmt) and (LKind = nkIfStmt) and
          (T^.LastChild(LParent) = AUnit) and InFile(Lead[AUnit]) and
          (Lead[AUnit] > 0) and (VisKind(Lead[AUnit] - 1) = tkElse) and
          InFile(Lead[AUnit] - 1) and
          (LineOf(VisStart(Lead[AUnit] - 1)) = LineOf(VisStart(Lead[AUnit]))) then
          Result := BaseCol(LParent)  // `else if` on one line
        else
          Result := BaseCol(LParent) + LStep;
      nkLabeledStmt:
        Result := BaseCol(LParent);
    else
      Result := BaseCol(LParent);
    end;
  ColMemo[AUnit] := Result;
end;

function TFormatter.CloserCol(AVis: Integer): Integer;
var
  LOwner: Integer;
begin
  LOwner := CloserOwner(AVis);
  if Kind(LOwner) in ROOT_KINDS then
    Result := 0
  else if (Kind(LOwner) = nkExceptPart) then
    Result := BaseCol(Parent(LOwner))
  else
    Result := BaseCol(LOwner);
end;

// A continuation line: keep the offset its first item (AOrigCol, in the
// original) had from the first token of AVis's unit.
function TFormatter.ContinuationCol(AVis, AOrigCol: Integer): Integer;
var
  LUnit, LLead: Integer;
begin
  Result := AOrigCol;
  if Own.Owner[AVis] < 0 then
    Exit;
  LUnit := NearUnit[Own.Owner[AVis]];
  if LUnit = NIL_NODE then
    Exit;
  LLead := Lead[LUnit];
  if InFile(LLead) and (LLead < AVis) and (TokCol[LLead] >= 0) then
  begin
    Result := TokCol[LLead] + AOrigCol - OrigCol(VisStart(LLead));
    if Result < 0 then
      Result := 0;
  end;
end;

function TFormatter.IsContinuation(AVis: Integer): Boolean;
begin
  Result := (CloserOwner(AVis) = NIL_NODE) and (UnitAt[AVis] = NIL_NODE);
end;

function TFormatter.CodeCol(AVis: Integer): Integer;
begin
  if CodeColMemo[AVis] <> -2 then
    Exit(CodeColMemo[AVis]);
  if CloserOwner(AVis) <> NIL_NODE then
    Result := CloserCol(AVis)
  else if UnitAt[AVis] <> NIL_NODE then
    Result := UnitCol(UnitAt[AVis])
  else
    Result := ContinuationCol(AVis, OrigCol(VisStart(AVis)));
  CodeColMemo[AVis] := Result;
end;

function TFormatter.CommentCol(AItem: Integer): Integer;
var
  LNext, LVis, LIdx, LOrig: Integer;
  LSameLine: Boolean;
begin
  // A comment under a trailing comment, in its column: the two are one
  // comment, and stay aligned.
  LNext := AItem + 1;
  while (LNext <= High(Items)) and (Items[LNext].Kind = fiComment) do
    Inc(LNext);
  if (AItem > 1) and (Items[AItem].Kind = fiComment) and
    (Items[AItem - 1].Kind = fiComment) and
    ((NL[AItem - 1] = 0) or CommentCont[AItem - 1]) and
    (NL[AItem] = 1) and ((LNext > High(Items)) or
    (OrigCol(Items[AItem].Start) > OrigCol(Items[LNext].Start))) and
    (OrigCol(Items[AItem].Start) >= OrigCol(Items[AItem - 1].Start)) and
    (Src[Items[AItem].Start + 1] = Src[Items[AItem - 1].Start + 1]) then
  begin
    // A comment line right under a trailing comment and right of the code
    // that follows continues that comment: it keeps its offset from it.
    CommentCont[AItem] := True;
    Result := ItemCol[AItem - 1] + OrigCol(Items[AItem].Start) -
      OrigCol(Items[AItem - 1].Start);
    if Result < 0 then
      Result := 0;
    Exit;
  end;
  LNext := AItem + 1;
  // The code line it introduces, past other comments, directives and an
  // inactive branch.
  while (LNext <= High(Items)) and
    (Items[LNext].Kind in [fiComment, fiDirective, fiOpaque]) and
    not Items[LNext].InAsm and not Items[LNext].AfterEnd do
    Inc(LNext);
  if (LNext > High(Items)) or (Items[LNext].Kind <> fiCode) or
    Items[LNext].AfterEnd or Items[LNext].InAsm or VisFlagged(Items[LNext].Vis) then
    Exit(OrigCol(Items[AItem].Start));
  LVis := Items[LNext].Vis;
  LSameLine := True;
  for LIdx := AItem + 1 to LNext do
    if NL[LIdx] > 0 then
      LSameLine := False;
  // Code after the comment on its line: the line is that code's, measured
  // from where the line really starts.
  if LSameLine and IsContinuation(LVis) then
    Exit(ContinuationCol(LVis, OrigCol(Items[AItem].Start)));
  Result := CodeCol(LVis);
  if LSameLine then
    Exit;
  LOrig := OrigCol(Items[AItem].Start);
  // A directive keeps its offset from the code it introduces: a nested
  // conditional's indentation is the author's.
  if Items[AItem].Kind = fiDirective then
  begin
    // Less than a step off is a slip of the hand, not a nesting.
    if Abs(LOrig - OrigCol(VisStart(LVis))) >= O.IndentStep then
      Result := Result + LOrig - OrigCol(VisStart(LVis));
    if Result < 0 then
      Result := 0;
    Exit;
  end;
  // A comment written over several lines is laid out by its author: moving
  // its first line alone would cut it from the rest.
  if LineOf(Items[AItem].EndPos) <> LineOf(Items[AItem].Start) then
    Exit(LOrig);
  // A comment in column 1 above declarations is a section heading (the
  // RTL's `{ TList class }`); among statements it is just misplaced.
  if O.KeepCommentsAtColumn1 and (LOrig = 0) and
    (Own.Owner[LVis] >= 0) and (NearUnit[Own.Owner[LVis]] <> NIL_NODE) and
    not (Kind(NearUnit[Own.Owner[LVis]]) in STMT_KINDS + [nkCaseSel,
    nkExceptOn, nkExceptPart, nkFinallyPart]) then
    Exit(0);
  // A comment above a closer (`end`, `until`, `else`, `except`, `finally`)
  // belongs either to what the closer ends - one step in - or to the closer
  // itself: the author's own layout says which, by whether it was written
  // right of the closer.
  if ((VisKind(LVis) in [tkEnd, tkUntil, tkElse]) and (CloserOwner(LVis) <> NIL_NODE) and
    not (Kind(CloserOwner(LVis)) in ROOT_KINDS)) or
    (VisKind(LVis) in [tkExcept, tkFinally]) then
    if OrigCol(Items[AItem].Start) > OrigCol(VisStart(LVis)) then
      Inc(Result, O.IndentStep);
end;

function TFormatter.CountBreaks(AStart, AEnd: Integer;
  out AFirst: string): Integer;
var
  LIdx: Integer;
begin
  Result := 0;
  AFirst := '';
  LIdx := AStart;
  while LIdx < AEnd do
  begin
    case Src[LIdx + 1] of
      #13:
        begin
          Inc(Result);
          if (LIdx + 1 < AEnd) and (Src[LIdx + 2] = #10) then
          begin
            if AFirst = '' then
              AFirst := #13#10;
            Inc(LIdx);
          end
          else if AFirst = '' then
            AFirst := #13;
        end;
      #10:
        begin
          Inc(Result);
          if AFirst = '' then
            AFirst := #10;
        end;
    end;
    Inc(LIdx);
  end;
end;

// The spaces a gap inside a line takes between code tokens AA and AB (visible
// indices): 0, 1 (at least one - more is the author's alignment), or -1 to
// keep it as written.
function TFormatter.SpaceRule(AA, AB: Integer): Integer;
var
  LKa, LKb: TPasTokenKind;
  LOa, LOb: Integer;
  LNa, LNb: TPasNodeKind;

  function IsOperatorOf(AVis, AOwner: Integer): Boolean;
  begin
    Result := (AOwner >= 0) and (Kind(AOwner) in [nkBinaryOp]) and
      not (VisKind(AVis) in [tkIdentifier]);
  end;

  function IsDeclEqual(AVis, AOwner: Integer): Boolean;
  begin
    Result := (VisKind(AVis) = tkEqual) and (AOwner >= 0) and
      (Kind(AOwner) in [nkTypeDecl, nkConstDecl, nkEnumValue, nkParam,
      nkVarDecl, nkMethodResolution, nkInlineConst]);
  end;

begin
  Result := -1;
  LastFact := -1;
  LKa := VisKind(AA);
  LKb := VisKind(AB);
  LOa := Own.Owner[AA];
  LOb := Own.Owner[AB];
  if (LOa < 0) or (LOb < 0) then
    Exit;
  LNa := Kind(LOa);
  LNb := Kind(LOb);
  // One literal's elements (B.6.1), and the character after a caret
  // (B.6.2): the gap is part of the value.
  if (LOa = LOb) and (LNa in [nkStrLit, nkCaretChar]) then
    Exit;
  if (LKa = tkCaret) and (LNa = nkCaretChar) then
    Exit;
  if (LNa = nkFormattedArg) or (LNb = nkFormattedArg) then
    Exit;                             // `Write(X:10:2)`
  if O.RemoveSpaces then
  begin
    LastFact := Ord(ffRemoveSpaces);
    if (LKb in [tkComma, tkSemicolon, tkRParen, tkRBracket, tkColon]) or
      (LKa in [tkLParen, tkLBracket]) then
      Exit(0);
    if (LKa in [tkDot, tkDotDot]) or (LKb in [tkDot, tkDotDot]) then
      Exit(0);
    if (LKb = tkLParen) and (LNb in [nkCall, nkParams, nkProgramParams]) then
      Exit(0);
    if (LKb = tkLBracket) and (LNb in [nkIndex, nkParams]) then
      Exit(0);
    if (LNb in [nkTypeArgs, nkGenericParams]) and (LKb in [tkLess, tkGreater]) then
      Exit(0);
    if (LNa in [nkTypeArgs, nkGenericParams]) and (LKa = tkLess) then
      Exit(0);
    if (LNa = nkUnaryOp) and (LKa in [tkMinus, tkPlus, tkAt]) then
      Exit(0);
    if (LKb = tkCaret) and (LNb = nkDeref) then
      Exit(0);
    if (LKa = tkCaret) and (LNa = nkPointerType) then
      Exit(0);
    LastFact := -1;
  end;
  if O.SpaceAfterSeparators and (LKa in [tkComma, tkSemicolon, tkColon]) then
  begin
    LastFact := Ord(ffSpaceAfterSeparators);
    Exit(1);
  end;
  if O.SpaceAroundOperators then
  begin
    LastFact := Ord(ffSpaceAroundOperators);
    if (LKa = tkAssign) or (LKb = tkAssign) then
      Exit(1);
    if IsOperatorOf(AA, LOa) or IsOperatorOf(AB, LOb) then
      Exit(1);
    if IsDeclEqual(AA, LOa) or IsDeclEqual(AB, LOb) then
      Exit(1);
    LastFact := -1;
  end;
end;

// May the gap between items AA and AB shrink to nothing? Only when the two
// tokens lex back as the same two (spec B.2: `(` `*`, `/` `/`, `:` `=`,
// `<` `>`, `.` `.`, two words would fuse).
function TFormatter.MayTouch(AA, AB: Integer): Boolean;
var
  LA, LB: string;
  LStream: TPasTokenStream;
  LIdx, LCount: Integer;
begin
  LA := Copy(Src, Items[AA].Start + 1, Items[AA].EndPos - Items[AA].Start);
  LB := Copy(Src, Items[AB].Start + 1, Items[AB].EndPos - Items[AB].Start);
  // After an operand, as both tokens stand here: the lexer reads a caret
  // by the token before it (B.6.2), and a caret that starts an operand is
  // never asked about (SpaceRule keeps its gap).
  LStream := TPasLexer.Tokenize('x ' + LA + LB);
  LCount := -1;
  for LIdx := 0 to High(LStream.Tokens) do
    if not (LStream.Tokens[LIdx].Kind in [tkWhitespace, tkEndOfFile]) then
    begin
      Inc(LCount);
      if (LCount = 1) and ((LStream.Tokens[LIdx].Len <> Length(LA)) or
        (LStream.Tokens[LIdx].Kind <> Stream^.Tokens[T^.Source.Visible[
        Items[AA].Vis].TokenIndex].Kind)) then
        Exit(False);
    end;
  Result := LCount = 2;
end;


function ApplyCase(const AText: string; ACase: TPasFormatCase): string;
begin
  case ACase of
    fcLower:
      Result := LowerCase(AText);
    fcUpper:
      Result := UpperCase(AText);
  else
    Result := AText;
  end;
end;

// The text an item takes: a word in its class's case, a compiler
// directive's name in its.
function TFormatter.ItemText(AItem: Integer): string;
var
  LText: string;
  LVis, LOwner, LIdx, LEnd: Integer;
begin
  LText := Copy(Src, Items[AItem].Start + 1,
    Items[AItem].EndPos - Items[AItem].Start);
  Result := LText;
  case Items[AItem].Kind of
    fiDirective:
      if O.CompilerDirectiveCase <> fcKeep then
      begin
        // `{$name` or `(*$name`: only the name, never the argument.
        LIdx := Pos('$', LText);
        if LIdx = 0 then
          Exit;
        LEnd := LIdx + 1;
        while (LEnd <= Length(LText)) and CharInSet(LText[LEnd],
          ['A'..'Z', 'a'..'z', '_']) do
          Inc(LEnd);
        CountWord(fwCompilerDirective, Copy(LText, LIdx + 1, LEnd - LIdx - 1));
        Result := Copy(LText, 1, LIdx) +
          ApplyCase(Copy(LText, LIdx + 1, LEnd - LIdx - 1),
          O.CompilerDirectiveCase) + Copy(LText, LEnd, MaxInt);
      end;
    fiCode:
      begin
        LVis := Items[AItem].Vis;
        if VisFlagged(LVis) then
          Exit;
        LOwner := Own.Owner[LVis];
        if VisKind(LVis) in [tkAnd..tkXor] then
        begin
          CountWord(fwReserved, LText);
          Result := ApplyCase(LText, O.ReservedWordCase);
        end
        else if VisKind(LVis) = tkIdentifier then
        begin
          // The kinds that own a directive word in valid code - every one
          // the self-host and the Studio source show (tools\PasTreeFormat
          // -words). Error recovery hands stray words to other kinds.
          if (LOwner >= 0) and (Kind(LOwner) in [nkDirective, nkPropSpec,
            nkVisibility, nkTypeDecl, nkPackage, nkUsesClause, nkClassType,
            nkObjectType, nkRecordType, nkHelperType, nkInterfaceType,
            nkProcType, nkRoutine, nkRaiseStmt, nkParam, nkExceptOn,
            nkVarDecl, nkExportsItem, nkConstraint]) then
          begin
            CountWord(fwDirective, LText);
            Result := ApplyCase(LText, O.DirectiveWordCase);
          end
          else if Assigned(IdentCase) and (LOwner >= 0) and
            (Kind(LOwner) = nkIdent) then
          begin
            Result := IdentCase(LVis, LText);
            // Only the case may change: anything else is no spelling of it.
            if not SameText(Result, LText) or (Length(Result) <> Length(LText)) then
              Result := LText;
          end;
        end;
      end;
  end;
end;

function TFormatter.ItemLen(AItem: Integer): Integer;
begin
  Result := Items[AItem].EndPos - Items[AItem].Start;
end;

function TFormatter.Spans(AItem: Integer): Boolean;
begin
  Result := LineOf(Items[AItem].EndPos) <> LineOf(Items[AItem].Start);
end;

// The last item of AItem's output line.
function TFormatter.LineEnd(AItem: Integer): Integer;
begin
  Result := AItem;
  while (Result < High(Items)) and (OutLine[Result + 1] = OutLine[AItem]) do
    Inc(Result);
end;

// The output line of items AFirst .. AEnd - 1 is one F5 may lay out: it
// starts with code, holds no directive (no wrap or alignment next to one),
// no inactive branch, no asm, nothing after the final `end.`, no flagged
// unit, no caret character, no item over several lines, no gap kept as
// written and no tab - a column read off it is the column it has.
function TFormatter.PlainLine(AFirst, AEnd: Integer): Boolean;
var
  LIdx: Integer;
begin
  Result := False;
  if (Items[AFirst].Kind <> fiCode) or Kept[AFirst] then
    Exit;
  for LIdx := AFirst to AEnd - 1 do
  begin
    if (Items[LIdx].Kind in [fiDirective, fiOpaque]) or Items[LIdx].InAsm or
      Items[LIdx].AfterEnd or Spans(LIdx) then
      Exit;
    if (Items[LIdx].Kind = fiCode) and VisFlagged(Items[LIdx].Vis) then
      Exit;
    // A caret in operand position reads the character after it, a blank
    // included (spec B.6.2): no gap near one is laid out.
    if (Items[LIdx].Kind = fiCode) and (VisKind(Items[LIdx].Vis) = tkCaret) and
      (Kind(Own.Owner[Items[LIdx].Vis]) = nkCaretChar) then
      Exit;
    if (LIdx > AFirst) and Kept[LIdx] then
      Exit;
  end;
  for LIdx := Items[AFirst].Start to Items[AEnd - 1].EndPos - 1 do
    if Src[LIdx + 1] = #9 then
      Exit;
  Result := True;
end;

// May a wrap break the line in the gap before item AItem (both it and the
// item before it code on one line), and how good a point is it: 0 after a
// `,` of a list (a `;` of a parameter list), 1..3 after a binary operator
// (relational, additive, multiplicative), 9 after `:=`; -1 not here. Never
// inside a literal or type arguments, before a caret, inside an anonymous
// method written on one line.
function TFormatter.WrapRank(AItem: Integer): Integer;
const
  LIST_KINDS = [nkCall, nkSetCtor, nkIndex, nkUsesClause, nkEnumType,
    nkVarDecl, nkParam, nkCaseLabels, nkExportsClause, nkWithStmt,
    nkInlineVar, nkProgramParams, nkAttrGroup, nkAttribute, nkInherited];
var
  LA, LB, LOa, LOb: Integer;
begin
  Result := -1;
  LA := Items[AItem - 1].Vis;
  LB := Items[AItem].Vis;
  LOa := Own.Owner[LA];
  LOb := Own.Owner[LB];
  if (LOa < 0) or (LOb < 0) or (VisKind(LB) = tkCaret) then
    Exit;
  if (Kind(LOa) in [nkTypeArgs, nkGenericParams, nkStrLit, nkCaretChar,
    nkFormattedArg]) or (Kind(LOb) in [nkTypeArgs, nkGenericParams]) then
    Exit;
  case VisKind(LA) of
    tkComma:
      if Kind(LOa) in LIST_KINDS then
        Result := 0;
    tkSemicolon:
      if Kind(LOa) = nkParams then
        Result := 0;
    tkAssign:
      if Kind(LOa) = nkAssign then
        Result := 9;
  else
    // After the operator's last token (`is not`, `not in` own two).
    if (Kind(LOa) = nkBinaryOp) and (LOb <> LOa) then
      case VisKind(LA) of
        tkEqual, tkNotEqual, tkLess, tkGreater, tkLessEqual, tkGreaterEqual,
        tkIn, tkIs, tkNot:
          Result := 1;
        tkPlus, tkMinus, tkOr, tkXor:
          Result := 2;
      else
        Result := 3;
      end;
  end;
  if (Result >= 0) and OneLineAnon(LOb) then
    Result := -1;
end;

// Wrap the output line of items AFirst .. AEnd - 1 if its code ends right
// of the margin; the breaks it added. A break goes at the best point that
// leaves the line before it inside the margin - the shallowest, then the
// lowest rank (WrapRank), then the rightmost; `:=` only when nothing else
// will do - or, when none does, at the leftmost of the best; the rest of
// the line is wrapped again. The new line takes the column a later format
// of the result reads back for it: one IndentStep right of its unit's
// first token (a continuation keeps its offset from it, CodeCol), a uses
// item its unit's column.
function TFormatter.WrapLine(AFirst, AEnd: Integer): Integer;
var
  LLast, LIdx, LSeg, LDepth, LRank, LWrap, LBest, LBestWrap, LShift: Integer;
  LCol, LDepthAt: TArray<Integer>;
  LKey, LBestKey: array[0..4] of Integer;
  LFits, LBetter: Boolean;

  function WrapCol(AItem: Integer): Integer;
  var
    LVis, LLead, LUnit: Integer;
  begin
    Result := -1;
    LVis := Items[AItem].Vis;
    if UnitAt[LVis] <> NIL_NODE then
    begin
      if Kind(UnitAt[LVis]) = nkUsesItem then
        Result := CodeCol(LVis);
      Exit;
    end;
    if CloserOwner(LVis) <> NIL_NODE then
      Exit;
    LUnit := NearUnit[Own.Owner[LVis]];
    if LUnit = NIL_NODE then
      Exit;
    LLead := Lead[LUnit];
    if not InFile(LLead) or (LLead >= LVis) or (TokCol[LLead] < 0) then
      Exit;
    // One step right of the line the unit starts on, never left of the
    // line being broken (an author's continuation under its `(`).
    if (VisItem[LLead] >= AFirst) and (VisItem[LLead] < AEnd) then
      Result := LCol[0] + O.IndentStep
    else
      Result := LineIndentAt[LLead] + O.IndentStep;
    if Result < LCol[0] then
      Result := LCol[0];
  end;

begin
  Result := 0;
  LLast := AEnd - 1;
  while (LLast >= AFirst) and (Items[LLast].Kind <> fiCode) do
    Dec(LLast);
  // The code is measured, not a comment after it.
  if (LLast < AFirst) or (ItemCol[LLast] + ItemLen(LLast) <= O.RightMargin) or
    not PlainLine(AFirst, AEnd) then
    Exit;
  SetLength(LCol, AEnd - AFirst);
  SetLength(LDepthAt, AEnd - AFirst);
  LDepth := 0;
  for LIdx := AFirst to AEnd - 1 do
  begin
    LCol[LIdx - AFirst] := ItemCol[LIdx];
    LDepthAt[LIdx - AFirst] := LDepth;
    if Items[LIdx].Kind = fiCode then
      case VisKind(Items[LIdx].Vis) of
        tkLParen, tkLBracket:
          Inc(LDepth);
        tkRParen, tkRBracket:
          Dec(LDepth);
      end;
  end;
  LSeg := AFirst;
  while LCol[LLast - AFirst] + ItemLen(LLast) > O.RightMargin do
  begin
    LBest := -1;
    LBestWrap := -1;
    for LIdx := LSeg + 1 to LLast do
    begin
      if (Items[LIdx].Kind <> fiCode) or (Items[LIdx - 1].Kind <> fiCode) then
        Continue;
      LRank := WrapRank(LIdx);
      if LRank < 0 then
        Continue;
      LWrap := WrapCol(LIdx);
      if (LWrap < 0) or (LWrap >= LCol[LIdx - AFirst]) then
        Continue;                     // no shorter for it
      LFits := LCol[LIdx - 1 - AFirst] + ItemLen(LIdx - 1) <= O.RightMargin;
      LKey[0] := Ord(not LFits);
      LKey[1] := Ord(LRank = 9);
      LKey[2] := LDepthAt[LIdx - AFirst];
      LKey[3] := LRank;
      if LFits then
        LKey[4] := -LIdx
      else
        LKey[4] := LIdx;
      LBetter := LBest < 0;
      if not LBetter then
        for LDepth := 0 to 4 do
          if LKey[LDepth] <> LBestKey[LDepth] then
          begin
            LBetter := LKey[LDepth] < LBestKey[LDepth];
            Break;
          end;
      if LBetter then
      begin
        LBest := LIdx;
        LBestWrap := LWrap;
        LBestKey := LKey;
      end;
    end;
    if LBest < 0 then
      Break;
    NL[LBest] := 1;
    WrapColAt[LBest] := LBestWrap;
    Inc(Result);
    LShift := LBestWrap - LCol[LBest - AFirst];
    for LIdx := LBest to AEnd - 1 do
      Inc(LCol[LIdx - AFirst], LShift);
    LSeg := LBest;
  end;
end;

function TFormatter.WrapLines: Integer;
var
  LIdx, LEnd: Integer;
begin
  Result := 0;
  LIdx := 0;
  while LIdx <= High(Items) do
  begin
    LEnd := LineEnd(LIdx) + 1;
    Inc(Result, WrapLine(LIdx, LEnd));
    LIdx := LEnd;
  end;
end;

// The token alignment lines up in a unit: an assignment's `:=`, a variable
// declaration's `:`, a constant's `:` (typed) or `=`, a type's `=`; -1 for
// any other unit or one the options leave alone.
function TFormatter.AlignTok(ANode: Integer): Integer;
var
  LIdx, LVis: Integer;
  LKind: TPasNodeKind;
begin
  Result := -1;
  LKind := Kind(ANode);
  if LKind = nkAssign then
  begin
    if not O.AlignAssignments or (Parent(ANode) = NIL_NODE) or
      not (Kind(Parent(ANode)) in [nkBlock, nkInitSec, nkFinalSec]) then
      Exit;
  end
  else if not (O.AlignDeclColons and (LKind in [nkVarDecl, nkConstDecl,
    nkTypeDecl])) then
    Exit;
  for LIdx := Own.OwnStart[ANode] to Own.OwnStart[ANode + 1] - 1 do
  begin
    LVis := Own.Own[LIdx];
    case VisKind(LVis) of
      tkAssign:
        if LKind = nkAssign then
          Exit(LVis);
      tkColon:
        if LKind in [nkVarDecl, nkConstDecl] then
          Exit(LVis);
      tkEqual:
        if (LKind in [nkConstDecl, nkTypeDecl]) and (Result < 0) then
          Result := LVis;             // a typed constant's `:` comes first
    end;
  end;
end;

// ABaseOnly: every gap alignment owns before `:=`, `:`, `=` takes its one
// rule width (1, 0, 1), the width wrapping measures with - so a format of
// the result, whose gaps hold the padding, wraps the same. Otherwise the
// groups: consecutive output lines, each one unit of one kind under one
// parent written on that line alone; in a group of two or more the token
// goes one column right of the longest text before it (a `:` touches it
// when that text is as long on every line); a unit in no group keeps F2's
// rule.
procedure TFormatter.AlignGaps(ABaseOnly: Boolean);
var
  LCand, LGroup: TArray<Integer>;
  LNode, LVis, LTok, LItem, LLeadItem, LLast, LEnd, LCount, LPrevLine,
    LPrevParent: Integer;
  LPrevKind: TPasNodeKind;
  LPrevTok: TPasTokenKind;

  procedure Close;
  var
    LIdx, LMax, LPad, LEndCol: Integer;
    LSame: Boolean;
  begin
    if Tally <> nil then
    begin
      if (LCount >= 2) and (VisKind(Items[LGroup[0]].Vis) = tkAssign) then
        TallyGroup(ffAlignAssignments, LGroup, LCount)
      else
        TallyGroup(ffAlignDeclColons, LGroup, LCount);
      LCount := 0;
      Exit;
    end;
    if LCount >= 2 then
    begin
      LMax := 0;
      LSame := True;
      for LIdx := 0 to LCount - 1 do
      begin
        LEndCol := ItemCol[LGroup[LIdx] - 1] + ItemLen(LGroup[LIdx] - 1);
        if (LIdx > 0) and (LEndCol <> LMax) then
          LSame := False;
        if LEndCol > LMax then
          LMax := LEndCol;
      end;
      LPad := 1;
      if (VisKind(Items[LGroup[0]].Vis) = tkColon) and LSame then
        LPad := 0;
      for LIdx := 0 to LCount - 1 do
        GapSet[LGroup[LIdx]] := LMax + LPad -
          (ItemCol[LGroup[LIdx] - 1] + ItemLen(LGroup[LIdx] - 1));
    end;
    LCount := 0;
  end;

begin
  SetLength(LCand, Length(T^.Source.Visible));
  for LVis := 0 to High(LCand) do
    LCand[LVis] := NIL_NODE;
  for LNode := 0 to High(T^.Nodes) do
  begin
    if (Lead[LNode] < 0) or not InFile(Lead[LNode]) then
      Continue;
    LTok := AlignTok(LNode);
    if (LTok < 0) or not InFile(LTok) then
      Continue;
    LItem := VisItem[LTok];
    if (LItem <= 0) or (NL[LItem] > 0) or Kept[LItem] or
      (Items[LItem - 1].Kind <> fiCode) then
      Continue;
    if ABaseOnly then
    begin
      if VisKind(LTok) = tkColon then
        GapSet[LItem] := 0
      else
        GapSet[LItem] := 1;
    end
    else
    begin
      GapSet[LItem] := -1;
      LCand[Lead[LNode]] := LNode;
    end;
  end;
  if ABaseOnly then
    Exit;
  SetLength(LGroup, 16);
  LCount := 0;
  LPrevLine := -2;
  LPrevParent := NIL_NODE;
  LPrevKind := nkError;
  LPrevTok := tkEndOfFile;
  for LVis := 0 to High(LCand) do
  begin
    LNode := LCand[LVis];
    if LNode = NIL_NODE then
      Continue;
    LTok := AlignTok(LNode);
    LItem := VisItem[LTok];
    LLeadItem := VisItem[LVis];
    LLast := T^.Nodes[LNode].LastToken;
    // The unit alone on its line: from its first token to its last, a `;`
    // after it, comments after that.
    if (LLeadItem < 0) or ((LLeadItem > 0) and (NL[LLeadItem] = 0)) or
      not InFile(LLast) or (VisItem[LLast] < 0) or
      (OutLine[VisItem[LLast]] <> OutLine[LLeadItem]) then
    begin
      Close;
      Continue;
    end;
    LEnd := LineEnd(LLeadItem);
    while Items[LEnd].Kind <> fiCode do
      Dec(LEnd);
    if not ((Items[LEnd].Vis = LLast) or ((Items[LEnd].Vis = LLast + 1) and
      (VisKind(LLast + 1) = tkSemicolon))) or
      not PlainLine(LLeadItem, LineEnd(LLeadItem) + 1) then
    begin
      Close;
      Continue;
    end;
    if (LCount > 0) and ((OutLine[LLeadItem] <> LPrevLine + 1) or
      (Parent(LNode) <> LPrevParent) or (Kind(LNode) <> LPrevKind) or
      (VisKind(LTok) <> LPrevTok)) then
      Close;
    if LCount = Length(LGroup) then
      SetLength(LGroup, LCount * 2);
    LGroup[LCount] := LItem;
    Inc(LCount);
    LPrevLine := OutLine[LLeadItem];
    LPrevParent := Parent(LNode);
    LPrevKind := Kind(LNode);
    LPrevTok := VisKind(LTok);
  end;
  Close;
end;

// Trailing comments: the comment after the last code of a line, on
// consecutive code lines of one indentation (a blank line, a comment line,
// another indentation ends the group), at one column - one right of the
// longest code before one of them. A comment alone keeps its gap.
procedure TFormatter.AlignComments;
var
  LGroup: TArray<Integer>;
  LIdx, LEnd, LLast, LCount, LPrevLine, LPrevIndent: Integer;

  procedure Close;
  var
    LK, LMax: Integer;
  begin
    if Tally <> nil then
    begin
      TallyGroup(ffAlignTrailingComments, LGroup, LCount);
      LCount := 0;
      Exit;
    end;
    if LCount >= 2 then
    begin
      LMax := 0;
      for LK := 0 to LCount - 1 do
        if ItemCol[LGroup[LK] - 1] + ItemLen(LGroup[LK] - 1) > LMax then
          LMax := ItemCol[LGroup[LK] - 1] + ItemLen(LGroup[LK] - 1);
      for LK := 0 to LCount - 1 do
        GapSet[LGroup[LK]] := LMax + 1 -
          (ItemCol[LGroup[LK] - 1] + ItemLen(LGroup[LK] - 1));
    end;
    LCount := 0;
  end;

begin
  SetLength(LGroup, 16);
  LCount := 0;
  LPrevLine := -2;
  LPrevIndent := -1;
  LIdx := 0;
  while LIdx <= High(Items) do
  begin
    LEnd := LineEnd(LIdx) + 1;
    LLast := LEnd - 1;
    while (LLast >= LIdx) and (Items[LLast].Kind <> fiCode) do
      Dec(LLast);
    if (LLast >= LIdx) and PlainLine(LIdx, LEnd) then
    begin
      // A code line of the group's indentation without a comment of its
      // own keeps the group going.
      if (LCount > 0) and ((OutLine[LIdx] <> LPrevLine + 1) or
        (ItemCol[LIdx] <> LPrevIndent)) then
        Close;
      if (LLast + 1 < LEnd) and (Items[LLast + 1].Kind = fiComment) then
      begin
        if LCount = Length(LGroup) then
          SetLength(LGroup, LCount * 2);
        LGroup[LCount] := LLast + 1;
        Inc(LCount);
      end;
      LPrevLine := OutLine[LIdx];
      LPrevIndent := ItemCol[LIdx];
    end
    else
      Close;
    LIdx := LEnd;
  end;
  Close;
end;

// Pass 2: the columns of every item, in order (a continuation reads the
// columns before it), its output line, and - AEmit - the edits.
procedure TFormatter.Layout(AEmit: Boolean; var AEdits: TPasTextEdits;
  var ACount: Integer);
var
  LCount, LIdx, LBreaks, LCol, LLineIndent, LLineFirstOrig, LShift, LSpaces,
    LOrigSpaces: Integer;
  LStarts: Boolean;
  LCur: TFmtItem;
  LFirstBreak, LGap, LNew: string;

  procedure AddEdit(AStart, ALen: Integer; const AText: string);
  begin
    if not AEmit then
      Exit;
    if ACount = Length(AEdits) then
      SetLength(AEdits, ACount * 2 + 64);
    AEdits[ACount].Start := AStart;
    AEdits[ACount].Len := ALen;
    AEdits[ACount].Text := AText;
    Inc(ACount);
  end;

begin
  LCount := Length(Items);
  for LIdx := 0 to High(ColMemo) do
    ColMemo[LIdx] := -2;
  for LIdx := 0 to High(CodeColMemo) do
  begin
    CodeColMemo[LIdx] := -2;
    TokCol[LIdx] := -1;
    LineIndentAt[LIdx] := 0;
    StartsLineAt[LIdx] := False;
  end;
  for LIdx := 0 to LCount - 1 do
    CommentCont[LIdx] := False;
  LShift := 0;
  LLineIndent := OrigCol(Items[0].Start);
  LLineFirstOrig := LLineIndent;
  for LIdx := 0 to LCount - 1 do
  begin
    LCur := Items[LIdx];
    if LIdx = 0 then
      OutLine[LIdx] := 0
    else
      OutLine[LIdx] := OutLine[LIdx - 1] + NL[LIdx] +
        LineOf(Items[LIdx - 1].EndPos) - LineOf(Items[LIdx - 1].Start);
    LStarts := (LIdx = 0) or (NL[LIdx] > 0);
    if LStarts then
    begin
      if Kept[LIdx] then
        LCol := OrigCol(LCur.Start)
      else if WrapColAt[LIdx] >= 0 then
        LCol := WrapColAt[LIdx]       // a line a wrap started (F5)
      else
        case LCur.Kind of
          fiCode:
            LCol := CodeCol(LCur.Vis);
          fiDirective:
            if O.KeepDirectivesAtColumn1 and (OrigCol(LCur.Start) = 0) then
              LCol := 0
            else
              LCol := CommentCol(LIdx);
        else
          LCol := CommentCol(LIdx);
        end;
      LLineIndent := LCol;
      LLineFirstOrig := OrigCol(LCur.Start);
      if (LIdx > 0) and not Kept[LIdx] then
      begin
        CountBreaks(Items[LIdx - 1].EndPos, LCur.Start, LFirstBreak);
        if LFirstBreak = '' then
          LFirstBreak := LineBreak;
        LNew := '';
        for LBreaks := 1 to NL[LIdx] do
          LNew := LNew + LFirstBreak;
        LNew := LNew + StringOfChar(' ', LCol);
        LGap := Copy(Src, Items[LIdx - 1].EndPos + 1,
          LCur.Start - Items[LIdx - 1].EndPos);
        if LGap <> LNew then
          AddEdit(Items[LIdx - 1].EndPos, LCur.Start - Items[LIdx - 1].EndPos,
            LNew);
      end;
      LShift := 0;
    end
    else if (GapSet[LIdx] >= 0) and not Kept[LIdx] then
    begin
      // A gap alignment (or wrapping's measure) sets (F5).
      LOrigSpaces := OrigCol(LCur.Start) - OrigCol(Items[LIdx - 1].EndPos);
      LNew := StringOfChar(' ', GapSet[LIdx]);
      if Copy(Src, Items[LIdx - 1].EndPos + 1,
        LCur.Start - Items[LIdx - 1].EndPos) <> LNew then
        AddEdit(Items[LIdx - 1].EndPos, LCur.Start - Items[LIdx - 1].EndPos,
          LNew);
      Inc(LShift, GapSet[LIdx] - LOrigSpaces);
    end
    else if O.NormalizeSpaces and not Kept[LIdx] and
      (LCur.Kind = fiCode) and (Items[LIdx - 1].Kind = fiCode) then
    begin
      // A gap inside a line, between two code tokens (F2).
      LSpaces := SpaceRule(Items[LIdx - 1].Vis, LCur.Vis);
      LOrigSpaces := OrigCol(LCur.Start) - OrigCol(Items[LIdx - 1].EndPos);
      if AEmit and (Tally <> nil) and (LastFact >= 0) then
        TallySpace(LIdx, LSpaces, LOrigSpaces);
      if (LSpaces = 1) and (LOrigSpaces = 0) then
      begin
        AddEdit(LCur.Start, 0, ' ');
        Inc(LShift);
      end
      else if (LSpaces = 0) and (LOrigSpaces > 0) and
        // `Name    : Type` - colons aligned down a declaration list are the
        // author's alignment, as several spaces are where one is asked.
        not ((LOrigSpaces > 1) and (VisKind(LCur.Vis) = tkColon)) and
        MayTouch(LIdx - 1, LIdx) then
      begin
        AddEdit(Items[LIdx - 1].EndPos, LCur.Start - Items[LIdx - 1].EndPos, '');
        Dec(LShift, LOrigSpaces);
      end;
    end;
    if AEmit and (LCur.Kind in [fiCode, fiDirective]) then
    begin
      LNew := ItemText(LIdx);
      if LNew <> Copy(Src, LCur.Start + 1, LCur.EndPos - LCur.Start) then
        AddEdit(LCur.Start, LCur.EndPos - LCur.Start, LNew);
    end;
    ItemCol[LIdx] := LLineIndent + OrigCol(LCur.Start) - LLineFirstOrig + LShift;
    if LCur.Kind = fiCode then
    begin
      StartsLineAt[LCur.Vis] := LStarts;
      LineIndentAt[LCur.Vis] := LLineIndent;
      TokCol[LCur.Vis] := ItemCol[LIdx];
    end;
    // An item that spans lines (a block comment, a multiline string, a
    // skipped region): what follows it on its last line stays where it is.
    if LineOf(LCur.EndPos) <> LineOf(LCur.Start) then
    begin
      LLineIndent := 0;
      LLineFirstOrig := 0;
      LShift := 0;
    end;
  end;
end;

function TFormatter.Run: TPasTextEdits;
var
  LCount, LIdx, LBreaks, LEditCount, LIter: Integer;
  LPrev, LCur: TFmtItem;
  LFirstBreak: string;
  LAlign: Boolean;

  // Only comments stand before item AIdx on its line, and the line starts
  // with one of them: the line is already AIdx's (`{class} function F;`, a
  // generated unit's member marker) - a break before AIdx would cut the
  // comment from what it marks.
  function LineOfComments(AIdx: Integer): Boolean;
  var
    LK: Integer;
  begin
    LK := AIdx - 1;
    while (LK > 0) and (Items[LK].Kind = fiComment) and (NL[LK] = 0) do
      Dec(LK);
    Result := (LK >= 0) and (Items[LK].Kind = fiComment) and
      ((LK = 0) or (NL[LK] > 0));
  end;

  function Opaque(const AItem: TFmtItem): Boolean;
  begin
    Result := (AItem.Kind = fiOpaque) or AItem.InAsm or AItem.AfterEnd or
      ((AItem.Kind = fiCode) and VisFlagged(AItem.Vis));
  end;

begin
  Result := nil;
  BuildItems;
  BuildUnits;
  LCount := Length(Items);
  if LCount = 0 then
    Exit;
  SetLength(NL, LCount);
  SetLength(ItemCol, LCount);
  SetLength(CommentCont, LCount);
  SetLength(Kept, LCount);
  SetLength(GapSet, LCount);
  SetLength(WrapColAt, LCount);
  SetLength(OutLine, LCount);
  SetLength(VisItem, Length(T^.Source.Visible));
  for LIdx := 0 to High(VisItem) do
    VisItem[LIdx] := -1;
  for LIdx := 0 to LCount - 1 do
  begin
    GapSet[LIdx] := -1;
    WrapColAt[LIdx] := -1;
    if Items[LIdx].Kind = fiCode then
      VisItem[Items[LIdx].Vis] := LIdx;
  end;
  // Pass 1: the line breaks of every gap.
  Kept[0] := True;
  for LIdx := 1 to LCount - 1 do
  begin
    LPrev := Items[LIdx - 1];
    LCur := Items[LIdx];
    LBreaks := CountBreaks(LPrev.EndPos, LCur.Start, LFirstBreak);
    Kept[LIdx] := Opaque(LPrev) or Opaque(LCur);
    if not Kept[LIdx] then
    begin
      if Tally <> nil then
      begin
        if LBreaks > High(Tally^.BlankRuns) then
          Inc(Tally^.BlankRuns[High(Tally^.BlankRuns)])
        else if LBreaks >= 2 then
          Inc(Tally^.BlankRuns[LBreaks - 1]);
        if (LCur.Kind = fiCode) and (FactAt[LCur.Vis] >= 0) and
          (LPrev.Kind <> fiDirective) and not LineOfComments(LIdx) then
        begin
          Inc(Tally^.Facts[TPasFormatFact(FactAt[LCur.Vis])].Sites);
          if LBreaks > 0 then
            Inc(Tally^.Facts[TPasFormatFact(FactAt[LCur.Vis])].Agree);
        end;
      end;
      if (O.MaxBlankLines >= 0) and (LBreaks > O.MaxBlankLines + 1) then
        LBreaks := O.MaxBlankLines + 1;
      if (LBreaks = 0) and (LCur.Kind = fiCode) and ForcedAt[LCur.Vis] and
        (LPrev.Kind <> fiDirective) and not LineOfComments(LIdx) then
        LBreaks := 1;
    end;
    NL[LIdx] := LBreaks;
  end;
  LEditCount := 0;
  // F5. Wrapping measures with every gap alignment owns at its rule width
  // and adds breaks until no line it may break is too long; alignment then
  // reads the columns of the lines as wrapped, the trailing comments last
  // (after the padding of the code before them).
  LAlign := O.AlignAssignments or O.AlignDeclColons;
  if LAlign and (Tally = nil) then
    AlignGaps(True);
  if O.WrapLongLines and (O.RightMargin > 0) then
    for LIter := 1 to 32 do
    begin
      Layout(False, Result, LEditCount);
      if WrapLines = 0 then
        Break;
    end;
  if LAlign then
  begin
    Layout(False, Result, LEditCount);
    AlignGaps(False);
  end;
  if O.AlignTrailingComments then
  begin
    Layout(False, Result, LEditCount);
    AlignComments;
  end;
  Layout(True, Result, LEditCount);
  SetLength(Result, LEditCount);
end;

function PasFormatEdits(const ATree: TPasTree; AFileId: Integer;
  const AOptions: TPasFormatOptions): TPasTextEdits;
begin
  Result := PasFormatEdits(ATree, AFileId, AOptions, nil);
end;

function PasFormatEdits(const ATree: TPasTree; AFileId: Integer;
  const AOptions: TPasFormatOptions;
  const AIdentCase: TPasIdentCaseFunc): TPasTextEdits;
var
  LFmt: TFormatter;
begin
  Result := nil;
  if (AFileId < 0) or (AFileId > High(ATree.Source.Files)) or
    (Length(ATree.Nodes) = 0) then
    Exit;
  LFmt := Default(TFormatter);
  LFmt.Init(ATree, AFileId, AOptions);
  LFmt.IdentCase := AIdentCase;
  Result := LFmt.Run;
end;

function PasFormatRangeEdits(const ATree: TPasTree; AFileId: Integer;
  const AOptions: TPasFormatOptions; AStart, AEnd: Integer;
  const AIdentCase: TPasIdentCaseFunc): TPasTextEdits;
var
  LAll: TPasTextEdits;
  LIdx, LCount, LAnchor: Integer;
begin
  LAll := PasFormatEdits(ATree, AFileId, AOptions, AIdentCase);
  SetLength(Result, Length(LAll));
  LCount := 0;
  for LIdx := 0 to High(LAll) do
  begin
    // A gap's edit belongs to the token after it (where it ends); a
    // token's own edit (its case) to the token.
    if Trim(Copy(ATree.Source.Files[AFileId].Source, LAll[LIdx].Start + 1,
      LAll[LIdx].Len)) = '' then
      LAnchor := LAll[LIdx].Start + LAll[LIdx].Len
    else
      LAnchor := LAll[LIdx].Start;
    if (LAnchor >= AStart) and (LAnchor < AEnd) then
    begin
      Result[LCount] := LAll[LIdx];
      Inc(LCount);
    end;
  end;
  SetLength(Result, LCount);
end;

function PasFormatText(const AText, AFileName: string;
  const AOptions: TPasFormatOptions): string;
var
  LSM: TPasSourceManager;
  LDefines: TPasDefines;
  LPP: TPasPreprocessor;
  LPre: TPasPreprocessed;
  LTree: TPasTree;
  LDiags: TArray<TPasParseDiag>;
begin
  LSM := TPasSourceManager.Create([]);
  LDefines := TPasDefines.Create;
  try
    LPP := TPasPreprocessor.Create(LSM, LDefines);
    try
      LPre := LPP.ProcessText(AFileName, AText);
      if Length(LPre.Files) = 0 then
        Exit(AText);
      LTree := TPasParser.ParseFile(LPre, LDiags);
      Result := PasApplyEdits(LPre.Files[0].Source,
        PasFormatEdits(LTree, 0, AOptions));
    finally
      LPP.Free;
    end;
  finally
    LDefines.Free;
    LSM.Free;
  end;
end;

function PasApplyEdits(const ASource: string;
  const AEdits: TPasTextEdits): string;
var
  LSb: TStringBuilder;
  LPos, LIdx: Integer;
begin
  LSb := TStringBuilder.Create(Length(ASource) + 256);
  try
    LPos := 0;
    for LIdx := 0 to High(AEdits) do
    begin
      LSb.Append(ASource, LPos, AEdits[LIdx].Start - LPos);
      LSb.Append(AEdits[LIdx].Text);
      LPos := AEdits[LIdx].Start + AEdits[LIdx].Len;
    end;
    LSb.Append(ASource, LPos, Length(ASource) - LPos);
    Result := LSb.ToString;
  finally
    LSb.Free;
  end;
end;

function PasSameTokens(const AOld, ANew: string; out AMsg: string;
  AWordCase: Boolean): Boolean;
var
  LOld, LNew: TPasTokenStream;
  LI, LJ, LLine, LCol: Integer;
begin
  AMsg := '';
  LOld := TPasLexer.Tokenize(AOld);
  LNew := TPasLexer.Tokenize(ANew);
  LI := 0;
  LJ := 0;
  while True do
  begin
    while (LI <= High(LOld.Tokens)) and (LOld.Tokens[LI].Kind = tkWhitespace) do
      Inc(LI);
    while (LJ <= High(LNew.Tokens)) and (LNew.Tokens[LJ].Kind = tkWhitespace) do
      Inc(LJ);
    if (LI > High(LOld.Tokens)) or (LJ > High(LNew.Tokens)) then
      Break;
    if (LOld.Tokens[LI].Kind <> LNew.Tokens[LJ].Kind) or
      ((LOld.TokenText(LI) <> LNew.TokenText(LJ)) and not (AWordCase and
      (LOld.Tokens[LI].Kind in [tkIdentifier, tkDirective, tkAnd..tkXor]) and
      SameText(LOld.TokenText(LI), LNew.TokenText(LJ)))) then
    begin
      LOld.OffsetToLineCol(LOld.Tokens[LI].Start, LLine, LCol);
      AMsg := Format('(%d,%d): %s became %s',
        [LLine, LCol, LOld.TokenText(LI), LNew.TokenText(LJ)]);
      Exit(False);
    end;
    Inc(LI);
    Inc(LJ);
  end;
  Result := (LI > High(LOld.Tokens)) = (LJ > High(LNew.Tokens));
  if not Result then
    AMsg := 'token count differs';
end;

{ TPasFormatSample }

procedure TPasFormatSample.Add(const AOther: TPasFormatSample);
var
  LFact: TPasFormatFact;
  LClass: TPasFormatWordClass;
  LIdx: Integer;
  LNested: Boolean;
begin
  Inc(Files, AOther.Files);
  Inc(Lines, AOther.Lines);
  for LFact := Low(TPasFormatFact) to High(TPasFormatFact) do
  begin
    Inc(Facts[LFact].Sites, AOther.Facts[LFact].Sites);
    Inc(Facts[LFact].Agree, AOther.Facts[LFact].Agree);
  end;
  for LClass := Low(TPasFormatWordClass) to High(TPasFormatWordClass) do
  begin
    Inc(Lower[LClass], AOther.Lower[LClass]);
    Inc(Upper[LClass], AOther.Upper[LClass]);
    Inc(Mixed[LClass], AOther.Mixed[LClass]);
  end;
  for LIdx := Low(BlankRuns) to High(BlankRuns) do
    Inc(BlankRuns[LIdx], AOther.BlankRuns[LIdx]);
  for LIdx := Low(LineLen) to High(LineLen) do
    Inc(LineLen[LIdx], AOther.LineLen[LIdx]);
  for LIdx := Low(Reindent) to High(Reindent) do
    for LNested := False to True do
      Inc(Reindent[LIdx, LNested], AOther.Reindent[LIdx, LNested]);
end;

const
  // The indent steps a sample measures (TPasFormatSample.Reindent).
  INFER_STEPS: array[0..2] of Integer = (2, 3, 4);

// Options under which a format only re-indents: every break, space and case
// rule keeps the text as written.
function IndentOnlyOptions: TPasFormatOptions;
begin
  Result := TPasFormatOptions.Default;
  Result.MaxBlankLines := -1;
  Result.BeginOnNewLine := False;
  Result.ElseOnNewLine := False;
  Result.StatementAfterThenDo := fbKeep;
  Result.OneStatementPerLine := False;
  Result.OneDeclPerLine := False;
  Result.NormalizeSpaces := False;
  Result.ReservedWordCase := fcKeep;
  Result.DirectiveWordCase := fcKeep;
  Result.CompilerDirectiveCase := fcKeep;
end;

procedure PasFormatTally(const ATree: TPasTree; AFileId: Integer;
  var ASample: TPasFormatSample);
var
  LFmt: TFormatter;
  LOpts: TPasFormatOptions;
  LSrc: string;
  LStep, LPos, LEnd, LLen: Integer;
  LNested: Boolean;
begin
  if (AFileId < 0) or (AFileId > High(ATree.Source.Files)) or
    (Length(ATree.Nodes) = 0) then
    Exit;
  Inc(ASample.Files);
  // Every rule on, so each place a rule decides is visited; blank lines
  // uncapped, so the runs are the text's.
  LOpts := TPasFormatOptions.Default;
  LOpts.MaxBlankLines := -1;
  LOpts.AlignAssignments := True;
  LOpts.AlignDeclColons := True;
  LOpts.AlignTrailingComments := True;
  LFmt := Default(TFormatter);
  LFmt.Init(ATree, AFileId, LOpts);
  LFmt.Tally := @ASample;
  LFmt.Run;
  LOpts := IndentOnlyOptions;
  for LStep in INFER_STEPS do
    for LNested := False to True do
    begin
      LOpts.IndentStep := LStep;
      LOpts.IndentNestedRoutines := LNested;
      Inc(ASample.Reindent[LStep, LNested],
        Length(PasFormatEdits(ATree, AFileId, LOpts)));
    end;
  // Line lengths, trailing blanks aside; a tab is one column.
  LSrc := ATree.Source.Files[AFileId].Source;
  LPos := 1;
  while LPos <= Length(LSrc) do
  begin
    LEnd := LPos;
    while (LEnd <= Length(LSrc)) and not CharInSet(LSrc[LEnd], [#10, #13]) do
      Inc(LEnd);
    LLen := LEnd - LPos;
    while (LLen > 0) and CharInSet(LSrc[LPos + LLen - 1], [' ', #9]) do
      Dec(LLen);
    if LLen > 0 then
    begin
      Inc(ASample.Lines);
      if LLen > High(ASample.LineLen) then
        LLen := High(ASample.LineLen);
      Inc(ASample.LineLen[LLen]);
    end;
    if (LEnd < Length(LSrc)) and (LSrc[LEnd] = #13) and
      (LSrc[LEnd + 1] = #10) then
      Inc(LEnd);
    LPos := LEnd + 1;
  end;
end;

function PasInferFormatOptions(const ASample: TPasFormatSample;
  out ANotes: TArray<TPasFormatInferNote>): TPasFormatOptions;
const
  MIN_SITES = 20;
  MIN_ALIGN_SITES = 10;
var
  LCount: Integer;
  LDefault: TPasFormatOptions;

  procedure Note(const AOption, AValue, AEvidence: string;
    AMixed: Boolean = False);
  begin
    if LCount = Length(ANotes) then
      SetLength(ANotes, LCount * 2 + 16);
    ANotes[LCount].Option := AOption;
    ANotes[LCount].Value := AValue;
    ANotes[LCount].Evidence := AEvidence;
    ANotes[LCount].Mixed := AMixed;
    Inc(LCount);
  end;

  function Pct(A, B: Int64): Double;
  begin
    if B = 0 then
      Result := 0
    else
      Result := 100.0 * A / B;
  end;

  function OnOff(AOn: Boolean): string;
  begin
    if AOn then
      Result := 'on'
    else
      Result := 'off';
  end;

  // A rule on at AOnAt of its sites or more, off at AOffAt or less, off and
  // mixed between; its default with fewer than AMin sites.
  function Decide(AFact: TPasFormatFact; const AOption: string;
    ADefault: Boolean; AMin: Integer; AOnAt, AOffAt: Double): Boolean;
  var
    LTally: TPasFormatTally;
    LShare: Double;
    LEvidence: string;
  begin
    LTally := ASample.Facts[AFact];
    LShare := Pct(LTally.Agree, LTally.Sites);
    LEvidence := Format('agrees at %.1f%% of %d sites', [LShare, LTally.Sites]);
    if LTally.Sites < AMin then
    begin
      Result := ADefault;
      Note(AOption, OnOff(Result), Format('%d sites, too few: the default',
        [LTally.Sites]));
    end
    else if LShare >= AOnAt then
    begin
      Result := True;
      Note(AOption, OnOff(Result), LEvidence);
    end
    else
    begin
      Result := False;
      Note(AOption, OnOff(Result), LEvidence, LShare > AOffAt);
    end;
  end;

  function CaseOf(AClass: TPasFormatWordClass; const AOption: string;
    ADefault: TPasFormatCase): TPasFormatCase;
  const
    NAMES: array[TPasFormatCase] of string = ('lower', 'upper', 'as written');
  var
    LAll: Int64;
    LLower, LUpper: Double;
  begin
    LAll := ASample.Lower[AClass] + ASample.Upper[AClass] +
      ASample.Mixed[AClass];
    LLower := Pct(ASample.Lower[AClass], LAll);
    LUpper := Pct(ASample.Upper[AClass], LAll);
    if LAll < MIN_SITES then
    begin
      Result := ADefault;
      Note(AOption, NAMES[Result], Format('%d words, too few: the default',
        [LAll]));
      Exit;
    end;
    if LLower >= 90 then
      Result := fcLower
    else if LUpper >= 90 then
      Result := fcUpper
    else
      Result := fcKeep;
    Note(AOption, NAMES[Result], Format('%.1f%% lower, %.1f%% upper of %d words',
      [LLower, LUpper, LAll]), Result = fcKeep);
  end;

  procedure Indentation;
  var
    LStep, LBest: Integer;
    LNested, LBestNested: Boolean;
    LMin: Int64;
  begin
    LBest := 0;
    LBestNested := LDefault.IndentNestedRoutines;
    LMin := High(Int64);
    for LStep in INFER_STEPS do
      for LNested := False to True do
        if (ASample.Reindent[LStep, LNested] < LMin) or
          ((ASample.Reindent[LStep, LNested] = LMin) and
          (LNested = LDefault.IndentNestedRoutines)) then
        begin
          LMin := ASample.Reindent[LStep, LNested];
          LBest := LStep;
          LBestNested := LNested;
        end;
    if ASample.Lines < MIN_SITES then
    begin
      Note('IndentStep', IntToStr(Result.IndentStep),
        Format('%d lines, too few: the default', [ASample.Lines]));
      Exit;
    end;
    Result.IndentStep := LBest;
    Note('IndentStep', IntToStr(LBest), Format(
      '%.1f%% of %d lines keep their indentation; with 2: %.1f%%, ' +
      '3: %.1f%%, 4: %.1f%%', [100 - Pct(LMin, ASample.Lines), ASample.Lines,
      100 - Pct(ASample.Reindent[2, LBestNested], ASample.Lines),
      100 - Pct(ASample.Reindent[3, LBestNested], ASample.Lines),
      100 - Pct(ASample.Reindent[4, LBestNested], ASample.Lines)]),
      Pct(LMin, ASample.Lines) > 20);
    if ASample.Reindent[LBest, True] = ASample.Reindent[LBest, False] then
      Note('IndentNestedRoutines', OnOff(Result.IndentNestedRoutines),
        'no line tells: the default')
    else
    begin
      Result.IndentNestedRoutines := LBestNested;
      Note('IndentNestedRoutines', OnOff(LBestNested), Format(
        '%d lines re-indented on, %d off', [ASample.Reindent[LBest, True],
        ASample.Reindent[LBest, False]]));
    end;
  end;

  procedure BlankLines;
  var
    LAll, LOver: Int64;
    LIdx, LCap: Integer;
  begin
    LAll := 0;
    for LIdx := Low(ASample.BlankRuns) to High(ASample.BlankRuns) do
      Inc(LAll, ASample.BlankRuns[LIdx]);
    if LAll < MIN_SITES then
    begin
      Note('MaxBlankLines', IntToStr(Result.MaxBlankLines),
        Format('%d blank runs, too few: the default', [LAll]));
      Exit;
    end;
    for LCap := 1 to High(ASample.BlankRuns) - 1 do
    begin
      LOver := 0;
      for LIdx := LCap + 1 to High(ASample.BlankRuns) do
        Inc(LOver, ASample.BlankRuns[LIdx]);
      if LOver * 100 <= LAll then
      begin
        Result.MaxBlankLines := LCap;
        Note('MaxBlankLines', IntToStr(LCap), Format(
          '%d of %d runs of blank lines are longer', [LOver, LAll]));
        Exit;
      end;
    end;
    Result.MaxBlankLines := -1;
    Note('MaxBlankLines', 'all kept', Format(
      'runs of blank lines vary (%d runs)', [LAll]), True);
  end;

  procedure Margin;
  const
    MARGINS: array[0..2] of Integer = (80, 100, 120);
  var
    LMargin, LIdx: Integer;
    LOver: Int64;
  begin
    if ASample.Lines < MIN_SITES then
    begin
      Note('RightMargin', 'off', Format('%d lines, too few: the default',
        [ASample.Lines]));
      Exit;
    end;
    for LMargin in MARGINS do
    begin
      LOver := 0;
      for LIdx := LMargin + 1 to High(ASample.LineLen) do
        Inc(LOver, ASample.LineLen[LIdx]);
      if LOver * 1000 <= ASample.Lines * 5 then
      begin
        Result.RightMargin := LMargin;
        Result.WrapLongLines := True;
        Note('RightMargin', IntToStr(LMargin), Format(
          '%d of %d lines are longer', [LOver, ASample.Lines]));
        Note('WrapLongLines', 'on', Format('the lines fit in %d', [LMargin]));
        Exit;
      end;
    end;
    Note('RightMargin', 'off', Format(
      '%.1f%% of %d lines are longer than 120: no margin holds',
      [Pct(LOver, ASample.Lines), ASample.Lines]));
    Note('WrapLongLines', 'off', 'no margin holds');
  end;

begin
  LCount := 0;
  ANotes := nil;
  LDefault := TPasFormatOptions.Default;
  Result := LDefault;
  Indentation;
  BlankLines;
  Result.BeginOnNewLine := Decide(ffBeginOnNewLine, 'BeginOnNewLine',
    LDefault.BeginOnNewLine, MIN_SITES, 90, 10);
  Result.ElseOnNewLine := Decide(ffElseOnNewLine, 'ElseOnNewLine',
    LDefault.ElseOnNewLine, MIN_SITES, 90, 10);
  if Decide(ffStatementAfterThenDo, 'StatementAfterThenDo',
    LDefault.StatementAfterThenDo = fbAlways, MIN_SITES, 90, 10) then
    Result.StatementAfterThenDo := fbAlways
  else
    Result.StatementAfterThenDo := fbKeep;
  Result.OneStatementPerLine := Decide(ffOneStatementPerLine,
    'OneStatementPerLine', LDefault.OneStatementPerLine, MIN_SITES, 90, 10);
  Result.OneDeclPerLine := Decide(ffOneDeclPerLine, 'OneDeclPerLine',
    LDefault.OneDeclPerLine, MIN_SITES, 90, 10);
  Result.SpaceAroundOperators := Decide(ffSpaceAroundOperators,
    'SpaceAroundOperators', LDefault.SpaceAroundOperators, MIN_SITES, 90, 10);
  Result.SpaceAfterSeparators := Decide(ffSpaceAfterSeparators,
    'SpaceAfterSeparators', LDefault.SpaceAfterSeparators, MIN_SITES, 90, 10);
  Result.RemoveSpaces := Decide(ffRemoveSpaces, 'RemoveSpaces',
    LDefault.RemoveSpaces, MIN_SITES, 90, 10);
  Result.NormalizeSpaces := Result.SpaceAroundOperators or
    Result.SpaceAfterSeparators or Result.RemoveSpaces;
  Note('NormalizeSpaces', OnOff(Result.NormalizeSpaces),
    'on when one of the space rules is');
  Result.ReservedWordCase := CaseOf(fwReserved, 'ReservedWordCase',
    LDefault.ReservedWordCase);
  Result.DirectiveWordCase := CaseOf(fwDirective, 'DirectiveWordCase',
    LDefault.DirectiveWordCase);
  Result.CompilerDirectiveCase := CaseOf(fwCompilerDirective,
    'CompilerDirectiveCase', LDefault.CompilerDirectiveCase);
  Margin;
  Result.AlignAssignments := Decide(ffAlignAssignments, 'AlignAssignments',
    LDefault.AlignAssignments, MIN_ALIGN_SITES, 60, 20);
  Result.AlignDeclColons := Decide(ffAlignDeclColons, 'AlignDeclColons',
    LDefault.AlignDeclColons, MIN_ALIGN_SITES, 60, 20);
  Result.AlignTrailingComments := Decide(ffAlignTrailingComments,
    'AlignTrailingComments', LDefault.AlignTrailingComments, MIN_ALIGN_SITES,
    60, 20);
  SetLength(ANotes, LCount);
end;

end.
