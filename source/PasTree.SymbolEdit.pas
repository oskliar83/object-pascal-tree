unit PasTree.SymbolEdit;

(*
  Removing unused declarations: the text edits that take FindUnusedSymbols'
  rows (PasTree.Sema.Lint) out of their files. Which declarations are unused
  is the lint's; what a removal takes with it and how the text reads after it
  is this unit's. Shared by the hosts that act on the rows - pastree-lsp's
  pastree/symbolsRemoval (the RAD Studio client's Remove in its Unused tab)
  and pastree-mcp's `lint` with `apply`. The sibling of PasTree.UsesEdit,
  whose edit record it shares (0.209.0).

  ON THE TEXT AS IT IS NOW, BY PARSE. The rows come from an analysis that may
  be older than the text (a Remove before this one moved lines), so a row is
  found again by its name's line and column in a tree the host parses from
  the current text, and its name is checked there. Nothing is resolved: the
  parts of a declaration are found by their written names, as dcc pairs them.

  WHAT A ROW TAKES WITH IT:
  - the declaration itself: one name out of `A, B: Integer` (the comma
    beside it with it), the whole `A: Integer;` when every name goes, and
    the whole `var` / `const` / `type` section when every declaration of it
    goes - `class var` and the other head words of a type's own sections too;
  - a routine: every part dcc pairs with it - the declaration in a type or
    the interface, a `forward`, the implementation - by the qualified name
    written in the header (`TOuter.TFoo.Bar`); overloads are told apart by
    their parameter types, and a body whose parameters are left out cannot
    be told (refused);
  - a type: its declaration, a forward declaration of it (`TFoo = class;`),
    and the implementation of every method of it and of the types nested in
    it (headers starting `TFoo.`);
  - an only-assigned row (uhOnlyWritten): every assignment in WriteSites -
    the statement and its `;` in a statement list, the statement alone as
    the body of an `if`, a loop or a `case` branch (an empty statement is
    left: the condition is still evaluated, as it was);
  - a row used only by rows (By): those rows, transitively - removed alone,
    they no longer compile. A name in By that is no row given is a member
    of a type row (it goes with the type) or refuses the removal.

  LAYOUT. A part that has its lines to itself goes with them: the blanks
  before it, its trailing `;`, a comment after it on its last line, and the
  line break. A comment directly above it - no blank line between, on lines
  of its own, not a compiler directive - goes with it when the line after it
  is blank or starts a new declaration group (a keyword, `end`): one that
  heads a group the next declaration still belongs to stays. When a removal
  leaves two blank lines in a row, one goes. A part sharing its line with
  code that stays takes only itself and the blanks after it. Every edit only
  deletes; edits of one file touching each other are merged into one, so a
  file's edits never overlap.

  REFUSED, with a reason per row, never guessed at:
  - the row has a doubt (a `but` - the hosts never remove those either), or
    a row that must go with it has one or is refused;
  - the name is no longer at its line and column (the file changed since
    the search), or the part is in an $I include file;
  - a compiler directive inside what would go - other than $IF / $IFDEF /
    $IFNDEF / $IFOPT / $ELSE / $ELSEIF / $ENDIF / $IFEND and $REGION /
    $ENDREGION balanced within it (a `{$R-}` or `{$DEFINE}` changes the code
    after it; an unbalanced `{$ENDIF}` means the declaration is split
    between branches - the other branch would be left without it);
  - a field of a record's variant part (the variant's layout is the
    record's);
  - an assignment whose value code computes (TPasUnusedWrite.Computed - a
    call, a property): removing it drops that;
  - an assignment no longer found, or one under a label (a goto target);
  - a routine whose implementation cannot be told among its overloads;
  - an edit after which the file would parse with more errors than before
    (the check that catches what the rules above missed).

  A pure function of the rows and the texts the host hands in.
*)

interface

uses
  System.SysUtils,
  PasTree.Ast,
  PasTree.UsesEdit,
  PasTree.Sema.Lint;

type
  { One edit of the removal: the file and a deletion in it - the
    TPasUsesRemoval shape (NewText is always ''), 1-based Line:Col and
    0-based Start/Len in that file's text as handed in. }
  TPasSymbolRemoval = record
    FileName: string;
    Edit: TPasUsesRemoval;
  end;

  { An asked row that cannot be removed: its index in the rows, and why. }
  TPasSymbolRefusal = record
    Row: Integer;
    Reason: string;
  end;

  { The text of AFileName as it is now (an open editor's, else the disk's);
    False when it cannot be read. }
  TPasRemovalTextOf = reference to function(const AFileName: string;
    out AText: string): Boolean;
  { AText of AFileName parsed as the host parses it (its defines and search
    paths): the tree, and the count of its parse errors. }
  TPasRemovalParse = reference to function(const AFileName, AText: string;
    out ATree: TPasTree; out AErrors: Integer): Boolean;

{ The edits that remove the rows AAsked (indices into ARows) with what must
  go with them. ATaken: every row removed - the asked ones that are not
  refused and the rows going with them (By, members of a type removed), in
  ascending order. ARefused: the asked rows that stay, with why. Edits are
  grouped by file, in ascending order within one. }
function UnusedSymbolsRemoval(const ARows: TArray<TPasUnusedSymbol>;
  const AAsked: TArray<Integer>; const ATextOf: TPasRemovalTextOf;
  const AParse: TPasRemovalParse; out ATaken: TArray<Integer>;
  out ARefused: TArray<TPasSymbolRefusal>): TArray<TPasSymbolRemoval>;

implementation

uses
  System.Math,
  System.StrUtils,
  System.Generics.Collections,
  System.Generics.Defaults,
  PasTree.Types,
  PasTree.Preprocessor,
  PasTree.Sema.Model;

type
  TDrop = record
    Start, Stop: Integer;   // 0-based [Start, Stop) of the file's text
  end;

  // A part of a row found in a file: a node to remove whole, or names of a
  // declaration list (Names: the nfName idents going), or an assignment.
  TPartKind = (pkNode, pkName, pkAssign);
  TPart = record
    Kind: TPartKind;
    Node: Integer;     // the declaration / routine / assignment node
    Name: Integer;     // pkName: the ident
    Row: Integer;      // the row it belongs to
  end;

  // One file of the removal.
  TFileWork = class
    FileName: string;
    Text: string;
    Tree: TPasTree;
    Errors: Integer;
    Parsed: Boolean;
    ReadError: string;
    IdentAt: TDictionary<Integer, Integer>;   // offset -> nkIdent node
    Parts: TList<TPart>;
    constructor Create;
    destructor Destroy; override;
  end;

constructor TFileWork.Create;
begin
  inherited Create;
  IdentAt := TDictionary<Integer, Integer>.Create;
  Parts := TList<TPart>.Create;
end;

destructor TFileWork.Destroy;
begin
  Parts.Free;
  IdentAt.Free;
  inherited;
end;

{ -------- text and tokens -------- }

function IsBlank(C: Char): Boolean;
begin
  Result := (C = ' ') or (C = #9);
end;

// 0-based offset of 1-based ALine:ACol in ATS; -1 when out of range.
function OffsetOfLineCol(const ATS: TPasTokenStream; ALine,
  ACol: Integer): Integer;
begin
  if (ALine < 1) or (ALine > Length(ATS.LineStarts)) or (ACol < 1) then
    Exit(-1);
  Result := ATS.LineStarts[ALine - 1] + ACol - 1;
  if Result > Length(ATS.Source) then
    Result := -1;
end;

function VisInMain(const ATree: TPasTree; AVis: Integer): Boolean;
begin
  Result := (AVis >= 0) and (AVis <= High(ATree.Source.Visible)) and
    (ATree.Source.Visible[AVis].FileId = 0);
end;

function VisStart(const ATree: TPasTree; AVis: Integer): Integer;
begin
  Result := ATree.Source.Files[0].Tokens[
    ATree.Source.Visible[AVis].TokenIndex].Start;
end;

function VisEnd(const ATree: TPasTree; AVis: Integer): Integer;
begin
  Result := ATree.Source.Files[0].Tokens[
    ATree.Source.Visible[AVis].TokenIndex].EndPos;
end;

function VisIs(const ATree: TPasTree; AVis: Integer;
  const AWord: string): Boolean;
begin
  Result := (AVis >= 0) and (AVis <= High(ATree.Source.Visible)) and
    ATree.Source.VisibleTextEquals(AVis, AWord);
end;

// Whether a node's whole span lies in the main file.
function NodeInMain(const ATree: TPasTree; ANode: Integer): Boolean;
begin
  Result := VisInMain(ATree, ATree.NodeLeftmostVis(ANode)) and
    VisInMain(ATree, ATree.Nodes[ANode].LastToken);
end;

// The directive's word: `{$IFDEF X}` -> 'IFDEF'.
function DirectiveWord(const AText: string): string;
var
  LAt: Integer;
begin
  Result := '';
  LAt := Pos('$', AText);
  if LAt = 0 then
    Exit;
  Inc(LAt);
  while (LAt <= Length(AText)) and CharInSet(AText[LAt], ['A'..'Z', 'a'..'z',
    '0'..'9', '_']) do
  begin
    Result := Result + UpCase(AText[LAt]);
    Inc(LAt);
  end;
end;

{ '' when the directives inside [AFrom, ATo) of the main file may go with
  the text: only conditional ones and regions, balanced. The reason else. }
function DirectivesIn(const ATree: TPasTree; AFrom, ATo: Integer): string;
var
  LDepth, LRegion: Integer;
  LWord: string;
begin
  Result := '';
  LDepth := 0;
  LRegion := 0;
  for var LTok in ATree.Source.Files[0].Tokens do
  begin
    if LTok.Start >= ATo then
      Break;
    if (LTok.Start < AFrom) or (LTok.Kind <> tkDirective) then
      Continue;
    LWord := DirectiveWord(ATree.Source.Files[0].TokenText(LTok));
    if (LWord = 'IF') or (LWord = 'IFDEF') or (LWord = 'IFNDEF') or
       (LWord = 'IFOPT') then
      Inc(LDepth)
    else if (LWord = 'ELSE') or (LWord = 'ELSEIF') then
    begin
      if LDepth = 0 then
        Exit('a compiler directive ({$' + LWord + '}) splits it between ' +
          'branches - remove it by hand');
    end
    else if (LWord = 'ENDIF') or (LWord = 'IFEND') then
    begin
      Dec(LDepth);
      if LDepth < 0 then
        Exit('a compiler directive ({$' + LWord + '}) splits it between ' +
          'branches - remove it by hand');
    end
    else if LWord = 'REGION' then
      Inc(LRegion)
    else if LWord = 'ENDREGION' then
    begin
      Dec(LRegion);
      if LRegion < 0 then
        Exit('it holds the end of a {$REGION} it does not open');
    end
    else
      Exit('a compiler directive inside it ({$' + LWord + '}) would go ' +
        'with it - remove it by hand');
  end;
  if LDepth > 0 then
    Result := 'a compiler directive splits it between branches - remove it ' +
      'by hand'
  else if LRegion > 0 then
    Result := 'it holds the start of a {$REGION} it does not close';
end;

// Start of the line holding offset AAt (0-based).
function LineStartOf(const AText: string; AAt: Integer): Integer;
begin
  Result := AAt;
  while (Result > 0) and (AText[Result] <> #10) do
    Dec(Result);
end;

// AAt (at a line start) moved past that line and its break.
function PastLine(const AText: string; AAt: Integer): Integer;
begin
  Result := AAt;
  while (Result < Length(AText)) and (AText[Result + 1] <> #10) do
    Inc(Result);
  if Result < Length(AText) then
    Inc(Result);
end;

// Whether the line starting at ALineStart holds only blanks (an empty
// line at the end of the text is blank too).
function LineBlank(const AText: string; ALineStart: Integer): Boolean;
var
  LAt: Integer;
begin
  LAt := ALineStart;
  while (LAt < Length(AText)) and IsBlank(AText[LAt + 1]) do
    Inc(LAt);
  Result := (LAt >= Length(AText)) or CharInSet(AText[LAt + 1], [#13, #10]);
end;

// The first word on the line starting at ALineStart, lower-cased.
function FirstWord(const AText: string; ALineStart: Integer): string;
var
  LAt: Integer;
begin
  Result := '';
  LAt := ALineStart;
  while (LAt < Length(AText)) and IsBlank(AText[LAt + 1]) do
    Inc(LAt);
  while (LAt < Length(AText)) and CharInSet(AText[LAt + 1], ['A'..'Z',
    'a'..'z', '_']) do
  begin
    Result := Result + LowerCase(AText[LAt + 1]);
    Inc(LAt);
  end;
end;

// The index in Files[0].Tokens of the token starting at AOffset; -1.
function TokenAt(const ATree: TPasTree; AOffset: Integer): Integer;
var
  LLo, LHi, LMid: Integer;
begin
  LLo := 0;
  LHi := High(ATree.Source.Files[0].Tokens);
  while LLo <= LHi do
  begin
    LMid := (LLo + LHi) div 2;
    if ATree.Source.Files[0].Tokens[LMid].Start < AOffset then
      LLo := LMid + 1
    else if ATree.Source.Files[0].Tokens[LMid].Start > AOffset then
      LHi := LMid - 1
    else
      Exit(LMid);
  end;
  Result := -1;
end;

function IsComment(AKind: TPasTokenKind): Boolean;
begin
  Result := AKind in [tkCommentLine, tkCommentBrace, tkCommentParen];
end;

function LineBreaks(const AText: string): Integer;
begin
  Result := 0;
  for var C in AText do
    if C = #10 then
      Inc(Result);
end;

{ The start of the comment lines directly above the code starting at
  AStart (a line start's code), -1 when none: comments on lines of their
  own, no blank line between them and the code, no directive. }
function AttachedCommentStart(const ATree: TPasTree; AStart: Integer): Integer;
var
  LIdx, LFirst: Integer;
  LToks: TArray<TPasToken>;

  // The line breaks in the whitespace tokens right before LIdx + 1, LIdx
  // left on the token before them; -1 when there is none (LIdx unchanged).
  function BreaksBefore: Integer;
  begin
    if (LIdx < 0) or (LToks[LIdx].Kind <> tkWhitespace) then
      Exit(-1);
    Result := 0;
    while (LIdx >= 0) and (LToks[LIdx].Kind = tkWhitespace) do
    begin
      Inc(Result, LineBreaks(ATree.Source.Files[0].TokenText(LToks[LIdx])));
      Dec(LIdx);
    end;
  end;

begin
  Result := -1;
  LToks := ATree.Source.Files[0].Tokens;
  LIdx := TokenAt(ATree, AStart) - 1;
  LFirst := -1;
  // Exactly one line break between the code and the comment above it.
  if BreaksBefore <> 1 then
    Exit;
  while (LIdx >= 0) and IsComment(LToks[LIdx].Kind) do
  begin
    var LComment := LIdx;
    Dec(LIdx);
    if LIdx < 0 then
    begin
      LFirst := LComment;
      Break;
    end;
    var LBreaks := BreaksBefore;
    if LBreaks = -1 then
      Break;            // code or a directive right before it
    if LBreaks = 0 then
    begin
      // Blanks before it on its line: at the text's start it is its own.
      if LIdx < 0 then
        LFirst := LComment;
      Break;
    end;
    LFirst := LComment;
    if LBreaks > 1 then
      Break;            // a blank line above: the run ends
  end;
  if LFirst >= 0 then
    Result := LineStartOf(ATree.Source.Files[0].Source, LToks[LFirst].Start);
end;

{ The drop of the code [AStart, AStop): with its lines when it has them to
  itself, a comment trailing it on its line, and an attached comment above
  (see the unit's header). }
function LineDrop(const ATree: TPasTree; AStart, AStop: Integer): TDrop;
var
  LText: string;
  LS, LE, LTok: Integer;
  LAtStart: Boolean;
  LToks: TArray<TPasToken>;
  LWord: string;
begin
  LText := ATree.Source.Files[0].Source;
  LToks := ATree.Source.Files[0].Tokens;
  LS := AStart;
  while (LS > 0) and IsBlank(LText[LS]) do
    Dec(LS);
  LAtStart := (LS = 0) or (LText[LS] = #10);
  LE := AStop;
  while (LE < Length(LText)) and IsBlank(LText[LE + 1]) do
    Inc(LE);
  // A comment trailing it on the same line (one, not a directive).
  LTok := TokenAt(ATree, LE);
  if (LTok >= 0) and IsComment(LToks[LTok].Kind) and
     (LineBreaks(ATree.Source.Files[0].TokenText(LToks[LTok])) = 0) then
  begin
    LE := LToks[LTok].EndPos;
    while (LE < Length(LText)) and IsBlank(LText[LE + 1]) do
      Inc(LE);
  end;
  if (LE >= Length(LText)) or CharInSet(LText[LE + 1], [#13, #10]) then
  begin
    if LAtStart then
    begin
      Result.Start := LS;
      Result.Stop := LE;
      if (Result.Stop < Length(LText)) and (LText[Result.Stop + 1] = #13) then
        Inc(Result.Stop);
      if (Result.Stop < Length(LText)) and (LText[Result.Stop + 1] = #10) then
        Inc(Result.Stop);
      // The comment above, unless the next line continues its group.
      LWord := FirstWord(LText, Result.Stop);
      if LineBlank(LText, Result.Stop) or MatchText(LWord, ['end', 'private',
         'protected', 'public', 'published', 'strict', 'type', 'var',
         'const', 'resourcestring', 'threadvar', 'procedure', 'function',
         'constructor', 'destructor', 'property', 'class', 'operator',
         'implementation', 'initialization', 'finalization', 'begin']) then
      begin
        var LC := AttachedCommentStart(ATree, AStart);
        if LC >= 0 then
          Result.Start := LC;
      end;
    end
    else
    begin
      // Code before it on the line: it and the blanks before it.
      Result.Start := LS;
      Result.Stop := LE;
    end;
  end
  else
  begin
    // Code after it on the line: it and the blanks after it.
    Result.Start := AStart;
    Result.Stop := LE;
  end;
end;

{ -------- the tree -------- }

// The [first, last] visible tokens a whole declaration node spans, with the
// head words in front (`class`, a type's own `class var`), an attribute
// group before it and its trailing `;`.
procedure DeclSpan(const ATree: TPasTree; ANode: Integer;
  out AFirst, ALast: Integer);
var
  LPrev, LSib: Integer;
begin
  AFirst := ATree.NodeLeftmostVis(ANode);
  ALast := ATree.Nodes[ANode].LastToken;
  case ATree.Nodes[ANode].Kind of
    nkRoutine, nkPropertyDecl:
      // A class method or property: its `class` before the node - not the
      // `class` heading the type it is the first member of.
      if VisIs(ATree, AFirst - 1, 'class') and
         (ATree.Nodes[ATree.Nodes[ANode].Parent].FirstToken <> AFirst - 1) then
        Dec(AFirst);
    nkVarSec:
      if VisIs(ATree, AFirst - 1, 'var') or
         VisIs(ATree, AFirst - 1, 'threadvar') then
      begin
        if not VisIs(ATree, AFirst, 'var') then
        begin
          Dec(AFirst);
          if VisIs(ATree, AFirst - 1, 'class') then
            Dec(AFirst);
        end;
      end;
  end;
  // Attribute groups right before it, siblings in its parent.
  LSib := ATree.Nodes[ATree.Nodes[ANode].Parent].FirstChild;
  LPrev := NIL_NODE;
  while (LSib <> NIL_NODE) and (LSib <> ANode) do
  begin
    if ATree.Nodes[LSib].Kind = nkAttrGroup then
    begin
      if LPrev = NIL_NODE then
        LPrev := LSib;
    end
    else
      LPrev := NIL_NODE;
    LSib := ATree.Nodes[LSib].NextSibling;
  end;
  if LPrev <> NIL_NODE then
    AFirst := Min(AFirst, ATree.NodeLeftmostVis(LPrev));
  if (ALast < High(ATree.Source.Visible)) and
     (ATree.Source.VisibleKind(ALast + 1) = tkSemicolon) then
    Inc(ALast);
end;

// The nfName idents of a routine node, in order.
function NameSegments(const ATree: TPasTree; ARoutine: Integer): TArray<Integer>;
var
  LChild: Integer;
begin
  Result := nil;
  LChild := ATree.Nodes[ARoutine].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if (ATree.Nodes[LChild].Kind = nkIdent) and
       (nfName in ATree.Nodes[LChild].Flags) then
      Result := Result + [LChild];
    LChild := ATree.Nodes[LChild].NextSibling;
  end;
end;

function SegmentText(const ATree: TPasTree; ANode: Integer): string;
begin
  Result := LowerCase(ATree.NodeText(ANode));
  if (Result <> '') and (Result[1] = '&') then
    Delete(Result, 1, 1);
end;

function JoinedName(const ATree: TPasTree;
  const ASegs: TArray<Integer>): string;
begin
  Result := '';
  for var LS in ASegs do
    Result := Result + IfThen(Result <> '', '.') + SegmentText(ATree, LS);
end;

function IsStructType(AKind: TPasNodeKind): Boolean;
begin
  Result := AKind in [nkClassType, nkRecordType, nkObjectType,
    nkInterfaceType, nkHelperType];
end;

// The names of the types ANode is declared in, outermost first, joined
// with dots and lower-cased ('' at unit level). False when it sits in a
// routine body or a type without a name.
function OwnerTypes(const ATree: TPasTree; ANode: Integer;
  out AOwners: string): Boolean;
var
  LAt: Integer;
begin
  AOwners := '';
  LAt := ATree.Nodes[ANode].Parent;
  while LAt <> NIL_NODE do
  begin
    case ATree.Nodes[LAt].Kind of
      nkClassType, nkRecordType, nkObjectType, nkInterfaceType, nkHelperType:
        begin
          var LDecl := ATree.Nodes[LAt].Parent;
          if (LDecl = NIL_NODE) or (ATree.Nodes[LDecl].Kind <> nkTypeDecl) then
            Exit(False);
          AOwners := SegmentText(ATree, ATree.Nodes[LDecl].FirstChild) +
            IfThen(AOwners <> '', '.') + AOwners;
        end;
      nkRoutineBody, nkRoutine:
        Exit(False);
    end;
    LAt := ATree.Nodes[LAt].Parent;
  end;
  Result := True;
end;

function HasChild(const ATree: TPasTree; ANode: Integer;
  AKind: TPasNodeKind): Integer;
begin
  Result := ATree.Nodes[ANode].FirstChild;
  while (Result <> NIL_NODE) and (ATree.Nodes[Result].Kind <> AKind) do
    Result := ATree.Nodes[Result].NextSibling;
end;

function HasDirective(const ATree: TPasTree; ARoutine: Integer;
  const AWord: string): Boolean;
var
  LChild: Integer;
begin
  LChild := ATree.Nodes[ARoutine].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if (ATree.Nodes[LChild].Kind = nkDirective) and
       ATree.NodeTextEquals(LChild, AWord) then
      Exit(True);
    LChild := ATree.Nodes[LChild].NextSibling;
  end;
  Result := False;
end;

// A routine's parameter types, for telling overloads apart: each
// parameter's mode and type text, once per name; '' with no list.
function ParamKey(const ATree: TPasTree; ARoutine: Integer): string;
var
  LParams, LParam, LChild, LNames: Integer;
  LType: string;
begin
  Result := '';
  LParams := HasChild(ATree, ARoutine, nkParams);
  if LParams = NIL_NODE then
    Exit;
  LParam := ATree.Nodes[LParams].FirstChild;
  while LParam <> NIL_NODE do
  begin
    if ATree.Nodes[LParam].Kind = nkParam then
    begin
      LNames := 0;
      LType := '';
      LChild := ATree.Nodes[LParam].FirstChild;
      while LChild <> NIL_NODE do
      begin
        if (ATree.Nodes[LChild].Kind = nkIdent) and
           (nfName in ATree.Nodes[LChild].Flags) then
          Inc(LNames)
        else if (ATree.Nodes[LChild].Kind <> nkAttrGroup) and (LType = '') then
          LType := LowerCase(ATree.NodeSpanText(LChild)).Replace(' ', '')
            .Replace(#9, '').Replace(#13, '').Replace(#10, '');
        LChild := ATree.Nodes[LChild].NextSibling;
      end;
      if nfVar in ATree.Nodes[LParam].Flags then
        LType := 'var ' + LType
      else if nfConst in ATree.Nodes[LParam].Flags then
        LType := 'const ' + LType
      else if nfOut in ATree.Nodes[LParam].Flags then
        LType := 'out ' + LType;
      for var LI := 1 to Max(LNames, 1) do
        Result := Result + LType + ';';
    end;
    LParam := ATree.Nodes[LParam].NextSibling;
  end;
  if Result = '' then
    Result := '()';
end;

function HasBody(const ATree: TPasTree; ARoutine: Integer): Boolean;
begin
  Result := HasChild(ATree, ARoutine, nkRoutineBody) <> NIL_NODE;
end;

// An implementation: a body, or an `external` header.
function IsImpl(const ATree: TPasTree; ARoutine: Integer): Boolean;
begin
  Result := HasBody(ATree, ARoutine) or HasDirective(ATree, ARoutine,
    'external');
end;

// Whether a routine node stands at unit level (a section, a program's
// declarations) - where a header names the routine with its types.
function AtUnitLevel(const ATree: TPasTree; ARoutine: Integer): Boolean;
var
  LParent: Integer;
begin
  LParent := ATree.Nodes[ARoutine].Parent;
  Result := (LParent <> NIL_NODE) and (ATree.Nodes[LParent].Kind in
    [nkInterfaceSec, nkImplementationSec, nkProgram, nkLibrary, nkUnit]);
end;

{ -------- one row's parts -------- }

// The routine parts of the routine whose name ident is AIdent: every node
// dcc pairs with it. '' or the reason they cannot be told.
function RoutinePartsOf(const ATree: TPasTree; ARoutine: Integer;
  out AParts: TArray<Integer>): string;
var
  LOwners, LQName, LKey: string;
  LSameName, LDecls, LImpls: TArray<Integer>;
  LInType: Boolean;
  LScope: Integer;
begin
  Result := '';
  AParts := [ARoutine];
  LInType := IsStructType(ATree.Nodes[ATree.Nodes[ARoutine].Parent].Kind);
  if not LInType and not AtUnitLevel(ATree, ARoutine) then
  begin
    // A nested routine: its `forward` siblings in the same body.
    LScope := ATree.Nodes[ARoutine].Parent;
    LQName := JoinedName(ATree, NameSegments(ATree, ARoutine));
    LSameName := nil;
    var LSib := ATree.Nodes[LScope].FirstChild;
    while LSib <> NIL_NODE do
    begin
      if (ATree.Nodes[LSib].Kind = nkRoutine) and (LSib <> ARoutine) and
         (JoinedName(ATree, NameSegments(ATree, LSib)) = LQName) then
        LSameName := LSameName + [LSib];
      LSib := ATree.Nodes[LSib].NextSibling;
    end;
    if LSameName = nil then
      Exit;
    LKey := ParamKey(ATree, ARoutine);
    for var LR in LSameName do
      if ParamKey(ATree, LR) = LKey then
        AParts := AParts + [LR];
    if Length(AParts) = 1 then
      Result := 'its body cannot be told among the routines of that name ' +
        '- remove it by hand';
    Exit;
  end;
  if not OwnerTypes(ATree, ARoutine, LOwners) then
    Exit('it is declared in a type without a name of its own');
  LQName := JoinedName(ATree, NameSegments(ATree, ARoutine));
  if LOwners <> '' then
    LQName := LOwners + '.' + LQName;
  // The other headers of that name (in the type, or headers without a body
  // at unit level - an interface's, a forward) and the implementations (a
  // body, or an `external` header - the implementation of an external
  // routine declared in the interface).
  LDecls := nil;
  LImpls := nil;
  for var LN := 0 to High(ATree.Nodes) do
  begin
    if (ATree.Nodes[LN].Kind <> nkRoutine) or (LN = ARoutine) then
      Continue;
    if LInType then
    begin
      if (ATree.Nodes[LN].Parent = ATree.Nodes[ARoutine].Parent) and
         (JoinedName(ATree, NameSegments(ATree, LN)) =
          JoinedName(ATree, NameSegments(ATree, ARoutine))) then
        LDecls := LDecls + [LN]
      else if AtUnitLevel(ATree, LN) and IsImpl(ATree, LN) and
         (JoinedName(ATree, NameSegments(ATree, LN)) = LQName) then
        LImpls := LImpls + [LN];
    end
    else if AtUnitLevel(ATree, LN) and
       (JoinedName(ATree, NameSegments(ATree, LN)) = LQName) then
    begin
      if IsImpl(ATree, LN) then
        LImpls := LImpls + [LN]
      else
        LDecls := LDecls + [LN];
    end;
  end;
  LKey := ParamKey(ATree, ARoutine);
  AParts := [ARoutine];
  if not LInType and IsImpl(ATree, ARoutine) then
  begin
    // The row is an implementation: the headers before it with its
    // parameters (an overloaded set), or every header of a routine not
    // overloaded.
    if LImpls = nil then
      AParts := AParts + LDecls
    else
      for var LD in LDecls do
        if ParamKey(ATree, LD) = LKey then
          AParts := AParts + [LD];
    Exit;
  end;
  // The row is a declaration: its implementation and its other headers.
  if LDecls = nil then
  begin
    if Length(LImpls) > 1 then
    begin
      // One header, several bodies: the one with its parameters.
      var LHit: TArray<Integer> := nil;
      for var LI in LImpls do
        if ParamKey(ATree, LI) = LKey then
          LHit := LHit + [LI];
      if Length(LHit) <> 1 then
        Exit('its implementation cannot be told among the bodies of that ' +
          'name - remove it by hand');
      LImpls := LHit;
    end;
    AParts := AParts + LImpls;
    Exit;
  end;
  // Overloaded: the headers and the body with the same parameters.
  for var LD in LDecls do
    if ParamKey(ATree, LD) = LKey then
      AParts := AParts + [LD];
  var LHit: TArray<Integer> := nil;
  for var LI in LImpls do
    if ParamKey(ATree, LI) = LKey then
      LHit := LHit + [LI];
  if Length(LHit) > 1 then
    Exit('its implementation cannot be told among the bodies of that name ' +
      '- remove it by hand');
  if (LHit = nil) and (LImpls <> nil) and not HasDirective(ATree, ARoutine,
     'external') and not (ATree.Nodes[ATree.Nodes[ARoutine].Parent].Kind =
     nkInterfaceType) then
    for var LI in LImpls do
      if ParamKey(ATree, LI) = '' then
        Exit('a body of that name leaves its parameters out, and the ' +
          'routine is overloaded - remove it by hand');
  AParts := AParts + LHit;
end;

// The method resolution clauses naming the routine ARoutine declared in a
// type: `procedure IFoo.Bar = Baz;` names IFoo's Bar and, in its class, Baz.
// They go with it - left behind, they name nothing.
function ResolutionClauses(const ATree: TPasTree;
  ARoutine: Integer): TArray<Integer>;
var
  LOwner, LName: string;
  LParentKind: TPasNodeKind;
  LIdents: TArray<Integer>;
begin
  Result := nil;
  LParentKind := ATree.Nodes[ATree.Nodes[ARoutine].Parent].Kind;
  if not IsStructType(LParentKind) or
     not OwnerTypes(ATree, ARoutine, LOwner) then
    Exit;
  LName := JoinedName(ATree, NameSegments(ATree, ARoutine));
  if LastDelimiter('.', LOwner) > 0 then
    LOwner := Copy(LOwner, LastDelimiter('.', LOwner) + 1, MaxInt);
  for var LN := 0 to High(ATree.Nodes) do
  begin
    if ATree.Nodes[LN].Kind <> nkMethodResolution then
      Continue;
    LIdents := nil;
    var LChild := ATree.Nodes[LN].FirstChild;
    while LChild <> NIL_NODE do
    begin
      if ATree.Nodes[LChild].Kind = nkIdent then
        LIdents := LIdents + [LChild];
      LChild := ATree.Nodes[LChild].NextSibling;
    end;
    if Length(LIdents) < 3 then
      Continue;
    if LParentKind = nkInterfaceType then
    begin
      // IFoo.Bar = ...: the interface's method.
      if (SegmentText(ATree, LIdents[High(LIdents) - 2]) = LOwner) and
         (SegmentText(ATree, LIdents[High(LIdents) - 1]) = LName) then
        Result := Result + [LN];
    end
    else if (ATree.Nodes[LN].Parent = ATree.Nodes[ARoutine].Parent) and
       (SegmentText(ATree, LIdents[High(LIdents)]) = LName) then
      // ... = Baz in Baz's own type.
      Result := Result + [LN];
  end;
end;

function RoutineParts(const ATree: TPasTree; ARoutine: Integer;
  out AParts: TArray<Integer>): string;
begin
  Result := RoutinePartsOf(ATree, ARoutine, AParts);
  if Result = '' then
    AParts := AParts + ResolutionClauses(ATree, ARoutine);
end;

// The type parts: its declaration, a forward of it, and the bodies of its
// methods and of its nested types' (headers starting with its name).
function TypeParts(const ATree: TPasTree; ADecl: Integer;
  out AParts: TArray<Integer>): string;
var
  LOwners, LQName, LName: string;
begin
  Result := '';
  AParts := [ADecl];
  if not OwnerTypes(ATree, ADecl, LOwners) then
  begin
    // A type local to a routine: no method can be declared on it.
    Exit;
  end;
  LName := SegmentText(ATree, ATree.Nodes[ADecl].FirstChild);
  LQName := IfThen(LOwners <> '', LOwners + '.') + LName;
  for var LN := 0 to High(ATree.Nodes) do
    case ATree.Nodes[LN].Kind of
      nkTypeDecl:
        if (LN <> ADecl) and (ATree.Nodes[LN].Parent =
           ATree.Nodes[ADecl].Parent) and
           (SegmentText(ATree, ATree.Nodes[LN].FirstChild) = LName) then
        begin
          var LDef := ATree.Nodes[LN].FirstChild;
          while (LDef <> NIL_NODE) and not IsStructType(ATree.Nodes[LDef].Kind) do
            LDef := ATree.Nodes[LDef].NextSibling;
          if (LDef <> NIL_NODE) and PasIsForwardStruct(ATree, LDef) then
            AParts := AParts + [LN];
        end;
      nkRoutine:
        if AtUnitLevel(ATree, LN) and StartsText(LQName + '.',
           JoinedName(ATree, NameSegments(ATree, LN))) then
          AParts := AParts + [LN];
    end;
end;

{ -------- the removal -------- }

type
  TRemoval = class
    Rows: TArray<TPasUnusedSymbol>;
    TextOf: TPasRemovalTextOf;
    Parse: TPasRemovalParse;
    Files: TObjectDictionary<string, TFileWork>;
    Refused: TDictionary<Integer, string>;     // row -> why (its own parts)
    Found: TList<TPair<TFileWork, TPart>>;     // FindParts' parts
    ByName: TDictionary<string, TList<Integer>>;
    constructor Create;
    destructor Destroy; override;
    function FileOf(const AFileName: string): TFileWork;
    function Closure(ARow: Integer; out AWhy: string): TArray<Integer>;
    function FindParts(ARow: Integer): string;
    function FileDrops(AWork: TFileWork; out ADrops: TArray<TDrop>;
      out ARefusedRow: Integer; out AWhy: string): Boolean;
  end;

constructor TRemoval.Create;
begin
  inherited Create;
  Files := TObjectDictionary<string, TFileWork>.Create([doOwnsValues]);
  Refused := TDictionary<Integer, string>.Create;
  Found := TList<TPair<TFileWork, TPart>>.Create;
  ByName := TObjectDictionary<string, TList<Integer>>.Create([doOwnsValues]);
end;

destructor TRemoval.Destroy;
begin
  ByName.Free;
  Found.Free;
  Refused.Free;
  Files.Free;
  inherited;
end;

function TRemoval.FileOf(const AFileName: string): TFileWork;
var
  LText: string;
begin
  if Files.TryGetValue(LowerCase(AFileName), Result) then
    Exit;
  Result := TFileWork.Create;
  Files.Add(LowerCase(AFileName), Result);
  Result.FileName := AFileName;
  if not TextOf(AFileName, LText) then
  begin
    Result.ReadError := ExtractFileName(AFileName) + ' could not be read';
    Exit;
  end;
  Result.Text := LText;
  if not Parse(AFileName, LText, Result.Tree, Result.Errors) then
  begin
    Result.ReadError := ExtractFileName(AFileName) + ' could not be parsed';
    Exit;
  end;
  Result.Parsed := True;
  for var LN := 0 to High(Result.Tree.Nodes) do
    if (Result.Tree.Nodes[LN].Kind = nkIdent) and
       VisInMain(Result.Tree, Result.Tree.Nodes[LN].FirstToken) then
      Result.IdentAt.TryAdd(VisStart(Result.Tree,
        Result.Tree.Nodes[LN].FirstToken), LN);
end;

// The written name of a row: the qualified name's last segment, without a
// generic's parameter list, lower-cased.
function RowWord(const AName: string): string;
var
  LAt: Integer;
begin
  Result := AName;
  LAt := Pos('<', Result);
  if LAt > 0 then
    Result := Copy(Result, 1, LAt - 1);
  Result := LowerCase(Copy(Result, LastDelimiter('.', Result) + 1, MaxInt));
  if (Result <> '') and (Result[1] = '&') then
    Delete(Result, 1, 1);
end;

// A qualified name with the generic parameter lists dropped, lower-cased.
function PlainName(const AName: string): string;
var
  LDepth: Integer;
begin
  Result := '';
  LDepth := 0;
  for var C in AName do
    if C = '<' then
      Inc(LDepth)
    else if C = '>' then
      Dec(LDepth)
    else if LDepth = 0 then
      Result := Result + LowerCase(C);
end;

function TRemoval.Closure(ARow: Integer; out AWhy: string): TArray<Integer>;
var
  LSeen: TDictionary<Integer, Boolean>;
  LQueue: TQueue<Integer>;
  LRow: Integer;
  LList: TList<Integer>;
  LName, LPrefix: string;
  LFound: Boolean;
begin
  Result := nil;
  AWhy := '';
  LSeen := TDictionary<Integer, Boolean>.Create;
  LQueue := TQueue<Integer>.Create;
  try
    LSeen.Add(ARow, True);
    LQueue.Enqueue(ARow);
    while LQueue.Count > 0 do
    begin
      LRow := LQueue.Dequeue;
      Result := Result + [LRow];
      for var LBy in Rows[LRow].By do
      begin
        if LBy = '' then
          Continue;
        LName := PlainName(LBy);
        LFound := False;
        if ByName.TryGetValue(LName, LList) then
          for var LR in LList do
          begin
            LFound := True;
            if LSeen.TryAdd(LR, True) then
              LQueue.Enqueue(LR);
          end;
        // A member of a type row goes with the type.
        LPrefix := LName;
        while not LFound and (LastDelimiter('.', LPrefix) > 0) do
        begin
          LPrefix := Copy(LPrefix, 1, LastDelimiter('.', LPrefix) - 1);
          if ByName.TryGetValue(LPrefix, LList) then
            for var LR in LList do
              if Rows[LR].Kind = skType then
              begin
                LFound := True;
                if LSeen.TryAdd(LR, True) then
                  LQueue.Enqueue(LR);
              end;
        end;
        if not LFound then
        begin
          AWhy := Format('%s uses it and is not removed with it', [LBy]);
          Exit;
        end;
      end;
    end;
  finally
    LQueue.Free;
    LSeen.Free;
  end;
end;

// The ident node at ALine:ACol of AWork's text; NIL_NODE.
function IdentAtPos(AWork: TFileWork; ALine, ACol: Integer): Integer;
var
  LOffset: Integer;
begin
  Result := NIL_NODE;
  LOffset := OffsetOfLineCol(AWork.Tree.Source.Files[0], ALine, ACol);
  if LOffset >= 0 then
    AWork.IdentAt.TryGetValue(LOffset, Result);
end;

function TRemoval.FindParts(ARow: Integer): string;
var
  LWork: TFileWork;
  LIdent, LDecl, LAt: Integer;
  LPart: TPart;
  LNodes: TArray<Integer>;
  LWhy: string;
begin
  Result := '';
  LWork := FileOf(Rows[ARow].FileName);
  if LWork.ReadError <> '' then
    Exit(LWork.ReadError);
  // A file that is no unit, program or package is an $I include: its text
  // means something only where it is included.
  if (Length(LWork.Tree.Nodes) = 0) or not (LWork.Tree.Nodes[0].Kind in
     [nkUnit, nkProgram, nkLibrary, nkPackage]) then
    Exit('it is declared in an $I include file - remove it by hand');
  LIdent := IdentAtPos(LWork, Rows[ARow].Line, Rows[ARow].Col);
  if (LIdent = NIL_NODE) or (SegmentText(LWork.Tree, LIdent) <>
     RowWord(Rows[ARow].Name)) then
    Exit(Format('%s:%d no longer declares %s - the file has changed since ' +
      'the search', [ExtractFileName(Rows[ARow].FileName), Rows[ARow].Line,
      Rows[ARow].Name]));
  LDecl := LWork.Tree.Nodes[LIdent].Parent;
  LPart := Default(TPart);
  LPart.Row := ARow;
  case LWork.Tree.Nodes[LDecl].Kind of
    nkVarDecl:
      begin
        if not (nfName in LWork.Tree.Nodes[LIdent].Flags) then
          Exit('not a declaration Remove knows');
        LAt := LWork.Tree.Nodes[LDecl].Parent;
        while (LAt <> NIL_NODE) and not IsStructType(LWork.Tree.Nodes[LAt].Kind)
          and not (LWork.Tree.Nodes[LAt].Kind in [nkVariantPart,
          nkRoutineBody, nkRoutine]) do
          LAt := LWork.Tree.Nodes[LAt].Parent;
        if (LAt <> NIL_NODE) and (LWork.Tree.Nodes[LAt].Kind = nkVariantPart)
        then
          Exit('a field of a record''s variant part - the variant''s layout ' +
            'is the record''s');
        LPart.Kind := pkName;
        LPart.Node := LDecl;
        LPart.Name := LIdent;
        LNodes := nil;
      end;
    nkConstDecl, nkTypeDecl, nkPropertyDecl:
      begin
        if LWork.Tree.Nodes[LDecl].FirstChild <> LIdent then
          Exit('not a declaration Remove knows');
        if LWork.Tree.Nodes[LDecl].Kind = nkTypeDecl then
        begin
          LWhy := TypeParts(LWork.Tree, LDecl, LNodes);
          if LWhy <> '' then
            Exit(LWhy);
        end
        else
          LNodes := [LDecl];
      end;
    nkRoutine:
      begin
        if not (nfName in LWork.Tree.Nodes[LIdent].Flags) then
          Exit('not a declaration Remove knows');
        LWhy := RoutineParts(LWork.Tree, LDecl, LNodes);
        if LWhy <> '' then
          Exit(LWhy);
      end;
  else
    Exit('not a declaration Remove knows (a parameter, a local, an enum ' +
      'value)');
  end;
  if LPart.Kind = pkName then
  begin
    if not NodeInMain(LWork.Tree, LDecl) then
      Exit('it is declared in an include file');
    Found.Add(TPair<TFileWork, TPart>.Create(LWork, LPart));
  end
  else
    for var LN in LNodes do
    begin
      if not NodeInMain(LWork.Tree, LN) then
        Exit('a part of it is in an include file');
      LPart.Kind := pkNode;
      LPart.Node := LN;
      Found.Add(TPair<TFileWork, TPart>.Create(LWork, LPart));
    end;
  // Its assignments (an only-assigned row).
  for var LW in Rows[ARow].WriteSites do
  begin
    var LFileW := FileOf(LW.FileName);
    var LAt2 := Format('%s:%d', [ExtractFileName(LW.FileName), LW.Line]);
    if LW.Computed then
      Exit(Format('the value assigned at %s is computed by code (a call, a ' +
        'property) - removing the assignment drops it', [LAt2]));
    if LFileW.ReadError <> '' then
      Exit(LFileW.ReadError);
    var LId := IdentAtPos(LFileW, LW.Line, LW.Col);
    if (LId = NIL_NODE) or (SegmentText(LFileW.Tree, LId) <>
       RowWord(Rows[ARow].Name)) then
      Exit(Format('the assignment at %s is no longer there - the file has ' +
        'changed since the search', [LAt2]));
    // Up through `Self.` / `Obj.` to the assignment it is the target of.
    var LUp := LId;
    var LParent := LFileW.Tree.Nodes[LUp].Parent;
    while (LParent <> NIL_NODE) and (LFileW.Tree.Nodes[LParent].Kind = nkMember)
      and (LFileW.Tree.Nodes[LParent].FirstChild <> LUp) do
    begin
      LUp := LParent;
      LParent := LFileW.Tree.Nodes[LUp].Parent;
    end;
    if (LParent = NIL_NODE) or (LFileW.Tree.Nodes[LParent].Kind <> nkAssign) or
       (LFileW.Tree.Nodes[LParent].FirstChild <> LUp) then
      Exit(Format('%s is not a plain assignment of it any more', [LAt2]));
    if not NodeInMain(LFileW.Tree, LParent) then
      Exit(Format('the assignment at %s is in an include file', [LAt2]));
    if (LFileW.Tree.Nodes[LParent].Parent <> NIL_NODE) and
       (LFileW.Tree.Nodes[LFileW.Tree.Nodes[LParent].Parent].Kind =
        nkLabeledStmt) then
      Exit(Format('the assignment at %s carries a label', [LAt2]));
    LPart := Default(TPart);
    LPart.Kind := pkAssign;
    LPart.Node := LParent;
    LPart.Row := ARow;
    Found.Add(TPair<TFileWork, TPart>.Create(LFileW, LPart));
  end;
end;

function DropOf(AFrom, ATo: Integer): TDrop;
begin
  Result.Start := AFrom;
  Result.Stop := ATo;
end;

{ The drops of one file for its parts: whole nodes, names of lists, whole
  lists and sections emptied, assignments. False with the row to refuse and
  why when one cannot go. }
function TRemoval.FileDrops(AWork: TFileWork; out ADrops: TArray<TDrop>;
  out ARefusedRow: Integer; out AWhy: string): Boolean;
var
  LTree: TPasTree;
  LWhole: TDictionary<Integer, Integer>;          // node -> row
  LNames: TDictionary<Integer, Integer>;          // name ident -> row
  LListRows: TDictionary<Integer, Integer>;       // list decl -> a row
  LChanged: Boolean;

  function Covered(ANode: Integer): Boolean;
  var
    LAt: Integer;
  begin
    LAt := LTree.Nodes[ANode].Parent;
    while LAt <> NIL_NODE do
    begin
      if LWhole.ContainsKey(LAt) then
        Exit(True);
      LAt := LTree.Nodes[LAt].Parent;
    end;
    Result := False;
  end;

  function Add(AFrom, ATo, ARow: Integer): Boolean;
  begin
    AWhy := DirectivesIn(LTree, AFrom, ATo);
    if AWhy <> '' then
    begin
      ARefusedRow := ARow;
      Exit(False);
    end;
    ADrops := ADrops + [DropOf(AFrom, ATo)];
    Result := True;
  end;

  function NodeDrop(ANode, ARow: Integer): Boolean;
  var
    LFirst, LLast: Integer;
    LD: TDrop;
  begin
    DeclSpan(LTree, ANode, LFirst, LLast);
    LD := LineDrop(LTree, VisStart(LTree, LFirst), VisEnd(LTree, LLast));
    Result := Add(LD.Start, LD.Stop, ARow);
  end;

  function AssignDrop(ANode, ARow: Integer): Boolean;
  var
    LFirst, LLast, LParent: Integer;
    LD: TDrop;
  begin
    LFirst := LTree.NodeLeftmostVis(ANode);
    LLast := LTree.Nodes[ANode].LastToken;
    LParent := LTree.Nodes[ANode].Parent;
    if (LParent <> NIL_NODE) and (LTree.Nodes[LParent].Kind in [nkBlock,
       nkInitSec, nkFinalSec, nkExceptPart, nkFinallyPart]) then
    begin
      if (LLast < High(LTree.Source.Visible)) and
         (LTree.Source.VisibleKind(LLast + 1) = tkSemicolon) then
        Inc(LLast);
      LD := LineDrop(LTree, VisStart(LTree, LFirst), VisEnd(LTree, LLast));
    end
    else
      // The body of an if, a loop, a case branch: the statement alone, an
      // empty statement left in its place.
      LD := DropOf(VisStart(LTree, LFirst), VisEnd(LTree, LLast));
    Result := Add(LD.Start, LD.Stop, ARow);
  end;

  // The drops of a list declaration some names of which go.
  function NameDrops(ADecl: Integer; const ANames: TArray<Integer>;
    ARow: Integer): Boolean;
  var
    LIdx, LRunEnd, LFrom, LTo: Integer;
    LGo: TArray<Boolean>;
  begin
    SetLength(LGo, Length(ANames));
    for LIdx := 0 to High(ANames) do
      LGo[LIdx] := LNames.ContainsKey(ANames[LIdx]);
    LIdx := 0;
    while LIdx <= High(ANames) do
    begin
      if not LGo[LIdx] then
      begin
        Inc(LIdx);
        Continue;
      end;
      LRunEnd := LIdx;
      while (LRunEnd < High(ANames)) and LGo[LRunEnd + 1] do
        Inc(LRunEnd);
      if LRunEnd < High(ANames) then
      begin
        LFrom := VisStart(LTree, LTree.Nodes[ANames[LIdx]].FirstToken);
        LTo := VisStart(LTree, LTree.Nodes[ANames[LRunEnd + 1]].FirstToken);
      end
      else
      begin
        LFrom := VisEnd(LTree, LTree.Nodes[ANames[LIdx - 1]].LastToken);
        LTo := VisEnd(LTree, LTree.Nodes[ANames[LRunEnd]].LastToken);
      end;
      if not Add(LFrom, LTo, ARow) then
        Exit(False);
      LIdx := LRunEnd + 1;
    end;
    Result := True;
  end;

  function DeclNames(ADecl: Integer): TArray<Integer>;
  var
    LChild: Integer;
  begin
    Result := nil;
    LChild := LTree.Nodes[ADecl].FirstChild;
    while LChild <> NIL_NODE do
    begin
      if (LTree.Nodes[LChild].Kind = nkIdent) and
         (nfName in LTree.Nodes[LChild].Flags) then
        Result := Result + [LChild];
      LChild := LTree.Nodes[LChild].NextSibling;
    end;
  end;

  function IsDecl(ANode: Integer): Boolean;
  begin
    Result := LTree.Nodes[ANode].Kind in [nkVarDecl, nkConstDecl, nkTypeDecl,
      nkRoutine, nkPropertyDecl, nkMethodResolution];
  end;

var
  LRow: Integer;
begin
  Result := False;
  ADrops := nil;
  ARefusedRow := -1;
  AWhy := '';
  LTree := AWork.Tree;
  LWhole := TDictionary<Integer, Integer>.Create;
  LNames := TDictionary<Integer, Integer>.Create;
  LListRows := TDictionary<Integer, Integer>.Create;
  try
    for var LPart in AWork.Parts do
      case LPart.Kind of
        pkNode: LWhole.AddOrSetValue(LPart.Node, LPart.Row);
        pkName:
          begin
            LNames.AddOrSetValue(LPart.Name, LPart.Row);
            LListRows.AddOrSetValue(LPart.Node, LPart.Row);
          end;
      end;
    // A list every name of which goes is a whole node.
    for var LDecl in LListRows.Keys do
    begin
      var LAll := True;
      for var LN in DeclNames(LDecl) do
        if not LNames.ContainsKey(LN) then
          LAll := False;
      if LAll then
        LWhole.AddOrSetValue(LDecl, LListRows[LDecl]);
    end;
    // A section every declaration of which goes, up to a fixed point.
    repeat
      LChanged := False;
      for var LN := 0 to High(LTree.Nodes) do
        if (LTree.Nodes[LN].Kind in [nkVarSec, nkConstSec, nkTypeSec]) and
           not LWhole.ContainsKey(LN) then
        begin
          var LAny := False;
          var LAll := True;
          LRow := -1;
          var LChild := LTree.Nodes[LN].FirstChild;
          while LChild <> NIL_NODE do
          begin
            if IsDecl(LChild) then
            begin
              LAny := True;
              if LWhole.ContainsKey(LChild) then
                LRow := LWhole[LChild]
              else
                LAll := False;
            end;
            LChild := LTree.Nodes[LChild].NextSibling;
          end;
          if LAny and LAll then
          begin
            LWhole.Add(LN, LRow);
            LChanged := True;
          end;
        end;
    until not LChanged;
    // The drops: each whole node not inside another, the names of lists
    // that stay, the assignments not inside a node going.
    for var LPair in LWhole do
      if not Covered(LPair.Key) then
        if not NodeDrop(LPair.Key, LPair.Value) then
          Exit;
    for var LDecl in LListRows.Keys do
      if not LWhole.ContainsKey(LDecl) and not Covered(LDecl) then
        if not NameDrops(LDecl, DeclNames(LDecl), LListRows[LDecl]) then
          Exit;
    for var LPart in AWork.Parts do
      if (LPart.Kind = pkAssign) and not Covered(LPart.Node) then
        if not AssignDrop(LPart.Node, LPart.Row) then
          Exit;
    Result := True;
  finally
    LListRows.Free;
    LNames.Free;
    LWhole.Free;
  end;
end;

// ADrops sorted and merged where they touch, then one blank line taken
// where a drop leaves two in a row.
function Merged(const AText: string; const ADrops: TArray<TDrop>): TArray<TDrop>;
var
  LDrops: TArray<TDrop>;
  LChanged: Boolean;
begin
  LDrops := Copy(ADrops);
  repeat
    TArray.Sort<TDrop>(LDrops, TComparer<TDrop>.Construct(
      function(const A, B: TDrop): Integer
      begin
        Result := A.Start - B.Start;
        if Result = 0 then
          Result := B.Stop - A.Stop;
      end));
    Result := nil;
    for var LD in LDrops do
      if (Result <> nil) and (LD.Start <= Result[High(Result)].Stop) then
        Result[High(Result)].Stop := Max(Result[High(Result)].Stop, LD.Stop)
      else
        Result := Result + [LD];
    LChanged := False;
    for var LIdx := 0 to High(Result) do
    begin
      var LD := Result[LIdx];
      // Whole lines right under a list's head word (`const`, `private`)
      // and a blank line after them: the blank line goes too.
      if (LD.Start > 0) and (AText[LD.Start] = #10) and (LD.Stop > LD.Start)
         and (AText[LD.Stop] = #10) and (LD.Stop < Length(AText)) and
         MatchText(Trim(Copy(AText, LineStartOf(AText, LD.Start - 1) + 1,
         LD.Start - LineStartOf(AText, LD.Start - 1))), ['const', 'var',
         'type', 'threadvar', 'resourcestring', 'private', 'protected',
         'public', 'published', 'strict private', 'strict protected',
         'class var', 'begin']) and LineBlank(AText, LD.Stop) then
      begin
        Result[LIdx].Stop := PastLine(AText, LD.Stop);
        LChanged := True;
        Continue;
      end;
      // Whole lines, a blank line before and after: the one after goes.
      if ((LD.Start = 0) or (AText[LD.Start] = #10)) and (LD.Stop > LD.Start)
         and (AText[LD.Stop] = #10) and (LD.Start > 0) and
         (LD.Stop < Length(AText)) and
         LineBlank(AText, LineStartOf(AText, LD.Start - 1)) and
         LineBlank(AText, LD.Stop) then
      begin
        Result[LIdx].Stop := PastLine(AText, LD.Stop);
        LChanged := True;
      end;
    end;
    LDrops := Result;
  until not LChanged;
end;

function UnusedSymbolsRemoval(const ARows: TArray<TPasUnusedSymbol>;
  const AAsked: TArray<Integer>; const ATextOf: TPasRemovalTextOf;
  const AParse: TPasRemovalParse; out ATaken: TArray<Integer>;
  out ARefused: TArray<TPasSymbolRefusal>): TArray<TPasSymbolRemoval>;
var
  LWork: TRemoval;
  LAskedWhy: TDictionary<Integer, string>;   // asked row -> why it stays
  LClosures: TDictionary<Integer, TArray<Integer>>;
  LTaken: TDictionary<Integer, Boolean>;
  LWhy: string;
  LNew: Boolean;
  LParts: TDictionary<Integer, TArray<TPair<TFileWork, TPart>>>;
  LRefusal: TPasSymbolRefusal;
  LKey, LList: TList<Integer>;
  LDrops: TArray<TDrop>;
  LBad: Integer;
  LEdit: TPasSymbolRemoval;
begin
  Result := nil;
  ATaken := nil;
  ARefused := nil;
  LWork := TRemoval.Create;
  LAskedWhy := TDictionary<Integer, string>.Create;
  LClosures := TDictionary<Integer, TArray<Integer>>.Create;
  LTaken := TDictionary<Integer, Boolean>.Create;
  try
    LWork.Rows := ARows;
    LWork.TextOf := ATextOf;
    LWork.Parse := AParse;
    for var LIdx := 0 to High(ARows) do
    begin
      var LName := PlainName(ARows[LIdx].Name);
      if not LWork.ByName.TryGetValue(LName, LList) then
      begin
        LList := TList<Integer>.Create;
        LWork.ByName.Add(LName, LList);
      end;
      LList.Add(LIdx);
    end;
    // The closures; a doubt anywhere in one refuses it.
    for var LAsk in AAsked do
    begin
      if (LAsk < 0) or (LAsk > High(ARows)) or LClosures.ContainsKey(LAsk) or
         LAskedWhy.ContainsKey(LAsk) then
        Continue;
      var LC := LWork.Closure(LAsk, LWhy);
      if LWhy = '' then
        for var LR in LC do
          if ARows[LR].Doubts <> nil then
          begin
            if LR = LAsk then
              LWhy := 'it has a doubt: ' + ARows[LR].Doubts[0]
            else
              LWhy := Format('%s, which goes with it, has a doubt',
                [ARows[LR].Name]);
            Break;
          end;
      if LWhy <> '' then
        LAskedWhy.Add(LAsk, LWhy)
      else
        LClosures.Add(LAsk, LC);
    end;
    // Find the parts (once per row), make the drops; a refusal anywhere
    // drops every closure holding that row, and the rest is made again.
    LParts := TDictionary<Integer, TArray<TPair<TFileWork, TPart>>>.Create;
    try
      repeat
        LTaken.Clear;
        for var LPair in LClosures do
          for var LR in LPair.Value do
            LTaken.AddOrSetValue(LR, True);
        for var LF in LWork.Files.Values do
          LF.Parts.Clear;
        LNew := False;
        for var LR in LTaken.Keys do
        begin
          if LWork.Refused.ContainsKey(LR) then
            Continue;
          if not LParts.ContainsKey(LR) then
          begin
            LWork.Found.Clear;
            LWhy := LWork.FindParts(LR);
            if LWhy <> '' then
            begin
              LWork.Refused.Add(LR, LWhy);
              LNew := True;
              Continue;
            end;
            LParts.Add(LR, LWork.Found.ToArray);
          end;
          for var LP in LParts[LR] do
            LP.Key.Parts.Add(LP.Value);
        end;
        if not LNew then
          for var LF in LWork.Files.Values do
          begin
            if LF.Parts.Count = 0 then
              Continue;
            if not LWork.FileDrops(LF, LDrops, LBad, LWhy) then
            begin
              LWork.Refused.AddOrSetValue(LBad, LWhy);
              LNew := True;
              Continue;
            end;
            // The file must parse no worse than before.
            LDrops := Merged(LF.Text, LDrops);
            var LText := LF.Text;
            for var LI := High(LDrops) downto 0 do
              LText := Copy(LText, 1, LDrops[LI].Start) +
                Copy(LText, LDrops[LI].Stop + 1, MaxInt);
            var LTree2: TPasTree;
            var LErr2: Integer;
            if not AParse(LF.FileName, LText, LTree2, LErr2) or
               (LErr2 > LF.Errors) then
            begin
              for var LPart in LF.Parts do
                LWork.Refused.AddOrSetValue(LPart.Row, Format('%s would not ' +
                  'parse after the edit - remove it by hand',
                  [ExtractFileName(LF.FileName)]));
              LNew := True;
            end;
          end;
        // Closures with a refused row go.
        LKey := TList<Integer>.Create;
        try
          for var LPair in LClosures do
            for var LR in LPair.Value do
              if LWork.Refused.TryGetValue(LR, LWhy) then
              begin
                if LR <> LPair.Key then
                  LWhy := Format('%s, which goes with it: %s',
                    [ARows[LR].Name, LWhy]);
                LAskedWhy.AddOrSetValue(LPair.Key, LWhy);
                LKey.Add(LPair.Key);
                Break;
              end;
          for var LK in LKey do
            LClosures.Remove(LK);
        finally
          LKey.Free;
        end;
      until not LNew;
    finally
      LParts.Free;
    end;
    // The edits, by file.
    for var LF in LWork.Files.Values do
    begin
      if LF.Parts.Count = 0 then
        Continue;
      if not LWork.FileDrops(LF, LDrops, LBad, LWhy) then
        Continue;   // cannot happen: the loop above settled it
      for var LD in Merged(LF.Text, LDrops) do
      begin
        LEdit := Default(TPasSymbolRemoval);
        LEdit.FileName := LF.FileName;
        LEdit.Edit.Start := LD.Start;
        LEdit.Edit.Len := LD.Stop - LD.Start;
        LF.Tree.Source.Files[0].OffsetToLineCol(LD.Start, LEdit.Edit.Line,
          LEdit.Edit.Col);
        LF.Tree.Source.Files[0].OffsetToLineCol(LD.Stop, LEdit.Edit.EndLine,
          LEdit.Edit.EndCol);
        LEdit.Edit.OldText := Copy(LF.Text, LD.Start + 1, LD.Stop - LD.Start);
        LEdit.Edit.NewText := '';
        Result := Result + [LEdit];
      end;
    end;
    TArray.Sort<TPasSymbolRemoval>(Result,
      TComparer<TPasSymbolRemoval>.Construct(
      function(const A, B: TPasSymbolRemoval): Integer
      begin
        Result := CompareText(A.FileName, B.FileName);
        if Result = 0 then
          Result := A.Edit.Start - B.Edit.Start;
      end));
    // The rows taken: the closures, and the members of a type taken that
    // are rows themselves.
    ATaken := LTaken.Keys.ToArray;
    for var LR := 0 to High(ARows) do
      if not LTaken.ContainsKey(LR) then
        for var LT in LTaken.Keys do
          if (ARows[LT].Kind = skType) and SameText(ARows[LT].FileName,
             ARows[LR].FileName) and StartsText(PlainName(ARows[LT].Name) + '.',
             PlainName(ARows[LR].Name)) then
          begin
            ATaken := ATaken + [LR];
            Break;
          end;
    TArray.Sort<Integer>(ATaken);
    for var LAsk in AAsked do
      if LAskedWhy.TryGetValue(LAsk, LWhy) then
      begin
        LRefusal.Row := LAsk;
        LRefusal.Reason := LWhy;
        ARefused := ARefused + [LRefusal];
        LAskedWhy.Remove(LAsk);
      end;
  finally
    LTaken.Free;
    LClosures.Free;
    LAskedWhy.Free;
    LWork.Free;
  end;
end;

end.
