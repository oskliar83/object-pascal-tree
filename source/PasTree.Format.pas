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
    LineBreak: string;
    IdentCase: TPasIdentCaseFunc;
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
  for LNode := 0 to LCount - 1 do
    if (Lead[LNode] >= 0) and ForcedUnit(LNode) then
      ForcedAt[Lead[LNode]] := True;
  for LVis := 0 to High(ForcedAt) do
    if (Own.Owner[LVis] >= 0) and ForcedCloser(LVis) then
      ForcedAt[LVis] := True;
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
  LParent := Parent(AUnit);
  LKind := Kind(AUnit);
  if (LParent <> NIL_NODE) and OneLineAnon(AUnit) then
    Exit;
  if LParent = NIL_NODE then
    Exit;
  if LKind = nkUsesItem then
    Exit(O.OneDeclPerLine and (T^.Nodes[LParent].FirstChild = AUnit));
  if LKind in STMT_KINDS then
  begin
    case Kind(LParent) of
      nkBlock, nkInitSec, nkFinalSec:
        Result := O.OneStatementPerLine;
      nkRoutineBody:
        Result := O.BeginOnNewLine;
      nkUnit, nkProgram, nkLibrary, nkPackage:
        Result := True;               // a program's main block
      nkTryStmt, nkFinallyPart, nkRepeatStmt, nkExceptPart, nkCaseStmt:
        Result := HeadlessBlock(AUnit) and O.OneStatementPerLine;
      nkIfStmt, nkWhileStmt, nkForStmt, nkForInStmt, nkWithStmt, nkExceptOn:
        if T^.Nodes[LParent].FirstChild = AUnit then
          Result := False             // a for's inline var counter
        else if LKind = nkBlock then
          Result := O.BeginOnNewLine
        else if (Kind(LParent) = nkIfStmt) and (LKind = nkIfStmt) and
          (T^.LastChild(LParent) = AUnit) and
          (T^.Nodes[LParent].FirstChild <> NIL_NODE) and
          (T^.Nodes[T^.Nodes[LParent].FirstChild].NextSibling <> AUnit) then
          Result := False             // `else if`
        else
          Result := O.StatementAfterThenDo = fbAlways;
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
      Result := True;
    nkVarDecl:
      // `class var FNull: TBinaryWriter;` - a struct's var section keeps its
      // first field on its head word's line.
      Result := O.OneDeclPerLine and (Kind(LParent) <> nkVariantBranch) and
        not ((Kind(LParent) = nkVarSec) and (Parent(LParent) <> NIL_NODE) and
        (Kind(Parent(LParent)) in STRUCT_KINDS) and
        (T^.Nodes[LParent].FirstChild = AUnit));
  else
    Result := O.OneDeclPerLine and (LKind in DECL_KINDS + SECTION_KINDS);
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
  if LOwner = NIL_NODE then
    Exit;
  if OneLineAnon(LOwner) then
    Exit;
  if Kind(LOwner) in STRUCT_KINDS then
    Result := O.OneDeclPerLine and HasMembers(LOwner)
  else if (VisKind(AVis) = tkElse) and (Kind(LOwner) = nkIfStmt) then
    Result := O.ElseOnNewLine
  else if Kind(LOwner) = nkBlock then
    Result := O.OneStatementPerLine
  else
    Result := True;
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
  end;
  if O.SpaceAfterSeparators and (LKa in [tkComma, tkSemicolon, tkColon]) then
    Exit(1);
  if O.SpaceAroundOperators then
  begin
    if (LKa = tkAssign) or (LKb = tkAssign) then
      Exit(1);
    if IsOperatorOf(AA, LOa) or IsOperatorOf(AB, LOb) then
      Exit(1);
    if IsDeclEqual(AA, LOa) or IsDeclEqual(AB, LOb) then
      Exit(1);
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
          Result := ApplyCase(LText, O.ReservedWordCase)
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
            Result := ApplyCase(LText, O.DirectiveWordCase)
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

function TFormatter.Run: TPasTextEdits;
var
  LCount, LIdx, LBreaks, LCol, LLineIndent, LLineFirstOrig, LEditCount,
    LShift, LSpaces, LOrigSpaces: Integer;
  LKeep, LStarts: Boolean;
  LPrev, LCur: TFmtItem;
  LFirstBreak, LGap, LNew: string;
  LKept: TArray<Boolean>;

  procedure AddEdit(AStart, ALen: Integer; const AText: string);
  begin
    if LEditCount = Length(Result) then
      SetLength(Result, LEditCount * 2);
    Result[LEditCount].Start := AStart;
    Result[LEditCount].Len := ALen;
    Result[LEditCount].Text := AText;
    Inc(LEditCount);
  end;

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
  SetLength(LKept, LCount);
  // Pass 1: the line breaks of every gap.
  LKept[0] := True;
  for LIdx := 1 to LCount - 1 do
  begin
    LPrev := Items[LIdx - 1];
    LCur := Items[LIdx];
    LBreaks := CountBreaks(LPrev.EndPos, LCur.Start, LFirstBreak);
    LKeep := Opaque(LPrev) or Opaque(LCur);
    if not LKeep then
    begin
      if (O.MaxBlankLines >= 0) and (LBreaks > O.MaxBlankLines + 1) then
        LBreaks := O.MaxBlankLines + 1;
      if (LBreaks = 0) and (LCur.Kind = fiCode) and ForcedAt[LCur.Vis] and
        (LPrev.Kind <> fiDirective) and not LineOfComments(LIdx) then
        LBreaks := 1;
    end;
    NL[LIdx] := LBreaks;
    LKept[LIdx] := LKeep;
  end;
  // Pass 2: columns, in order (a continuation reads the columns before it),
  // and the edits.
  SetLength(Result, 64);
  LEditCount := 0;
  LShift := 0;
  LLineIndent := OrigCol(Items[0].Start);
  LLineFirstOrig := LLineIndent;
  for LIdx := 0 to LCount - 1 do
  begin
    LCur := Items[LIdx];
    LStarts := (LIdx = 0) or (NL[LIdx] > 0);
    if LStarts then
    begin
      if LKept[LIdx] then
        LCol := OrigCol(LCur.Start)
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
      if (LIdx > 0) and not LKept[LIdx] then
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
    else if O.NormalizeSpaces and not LKept[LIdx] and
      (LCur.Kind = fiCode) and (Items[LIdx - 1].Kind = fiCode) then
    begin
      // A gap inside a line, between two code tokens (F2).
      LSpaces := SpaceRule(Items[LIdx - 1].Vis, LCur.Vis);
      LOrigSpaces := OrigCol(LCur.Start) - OrigCol(Items[LIdx - 1].EndPos);
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
    if LCur.Kind in [fiCode, fiDirective] then
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

end.
