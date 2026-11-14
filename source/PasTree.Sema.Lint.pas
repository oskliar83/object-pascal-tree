unit PasTree.Sema.Lint;

{ Unused `uses` entries: a unit listed in a unit's `uses` none of whose names
  the unit uses - removing it shortens every build of the importer.

  A name counts for the unit listing it when dcc needs that unit in scope to
  bind it: a unit-level declaration of its interface, an enum value, a
  helper's member. A member reached through a value or a type (`List.Add`,
  `TFoo.Create`) does not: dcc finds members wherever the type came from, and
  the type named is the use. So do the qualifier of `Unit.Name`, the unit's
  form file naming a class or a module the listed unit declares - or an
  ANCESTOR of a component class it names, or a component of a form it
  inherits - each a unit the IDE's designer puts back into `uses` on the
  next save (0.93.3, 0.93.4; DesignerUnits), a name bound
  through an alias of another unit (`TModalResult` of Vcl.Controls is
  System.UITypes'), a name of the interface PasTree bound to a unit of the
  implementation `uses`, and a unit an inline routine the unit calls needs
  for its expansion (InlineDeps).

  What the index cannot see is said on the entry (Doubts) rather than decided:
  a name bound to nothing that the unit declares, a branch not compiled here
  naming it, a routine called here that the unit declares too (dcc picks
  among every unit's overloads), and - since a unit can be in `uses` for what
  its initialization does, registering a class or a graphic format - the
  initialization a removal leaves out of the program: the units no other path
  of the program reaches any more, those with initialization or finalization
  code or a resource named.

  One analysis, one configuration: an entry used only in a branch the
  analysis does not compile is reported (with the doubt that names it). The
  same rule is pastree-mcp's `lint unused-uses`, which weighs every analysis
  of a group. }

interface

uses
  PasTree.Sema.Model,
  PasTree.Sema.Project,
  PasTree.Sema.Nav;

type
  TPasUnusedUse = record
    Hit: TPasRefHit;          // the entry's name in its `uses` clause
    UnitName: string;         // as written
    InInterface: Boolean;
    // Why removing it may be wrong, one sentence each; empty when nothing
    // the index sees speaks against the removal.
    Doubts: TArray<string>;
  end;

  { loHideGlobalInit: leave out what a removal would cost a unit's
    initialization that reaches OUTSIDE the unit - an unused entry naming
    such a unit (even one the program reaches another way), or whose
    removal leaves one out of the program, a unit nobody uses that
    has one (or is the only path to one). "Outside" is a routine or a
    variable of another unit, or a member of one's type named through the
    type (`RegisterClass`, `Application.Title := ...`,
    `TPicture.RegisterFileFormat`, `TProviders.Register(...)`), named in the
    initialization or in a routine of the unit it calls; a constructor, a
    type, a constant or a member reached through the unit's own variable
    (`FList := TList.Create`, `FList.Add`) stays inside. Such a unit is in
    `uses` for what it registers, which no index of names can see, so a host
    acting on the rows (removing them) is better off not offered it at all.
    Without the option those rows come with a doubt, as before. }
  TPasLintOption = (loHideGlobalInit);
  TPasLintOptions = set of TPasLintOption;

  TPasUnreferencedUnit = record
    Hit: TPasRefHit;          // the unit's name in its own header
    UnitName: string;
    // Who lists it, by file name: 'Main.pas (no name of it used)',
    // 'Project.dpr (no name of it used)', 'Old.pas (itself unreferenced)'.
    // Empty when nothing does (a directory analysis).
    ListedBy: TArray<string>;
    Doubts: TArray<string>;   // as TPasUnusedUse's
  end;

// The units AMids no other unit really uses: what the program would no
// longer reach once every unused `uses` entry is gone - its own included,
// where the IDE lists every unit of a project. An entry with a doubt (a
// dead branch naming the unit, a name bound to nothing) is kept as a use.
// Without a program in the analysis (a directory), the units no other unit
// lists and uses. A unit with initialization or
// finalization code or a resource carries a doubt: it may be listed for
// what that registers. Sorted by unit name (ListedBy too). AOptions: see
// TPasLintOption.
function FindUnreferencedUnits(ANav: TPasNavigator;
  const AMids: TArray<Integer>;
  AOptions: TPasLintOptions = []): TArray<TPasUnreferencedUnit>;

// The unused `uses` entries of the units AMids of ANav's project, sorted by
// the listing file's name (its path breaking a tie), then by the unused
// unit's name. A program, a library or a package is skipped: its
// `uses` is its contents. An entry whose unit did not resolve is not judged.
// The navigator pairs an inline routine's declaration with its body.
// AOptions: see TPasLintOption.
function FindUnusedUses(ANav: TPasNavigator;
  const AMids: TArray<Integer>;
  AOptions: TPasLintOptions = []): TArray<TPasUnusedUse>;

{ LIGHT MODE (TPasSemaProject.LightPaths). TPasWorkspace.FindUnusedUses /
  FindUnreferencedUnits (PasTree.Sema.Workspace) make the lint exact
  without the host's help; LintPromotions stays for hosts not moved yet.
  The lint reads what a light unit
  never had analyzed - an inline routine's body (InlineDeps), its
  initialization (the link effects, loHideGlobalInit's test), the units its
  implementation `uses` brings in (reach) - and answers those on the safe
  side: a doubt on the row naming the unit ("the expansion of an inline
  routine of X ... is not known", "removing it leaves X out of P, analyzed
  interface-only ..."), a light unit's initialization counted as global
  under loHideGlobalInit. A unit kept, never one a removal needs called
  unused. LintPromotions is the preparation step that makes the lint exact
  instead: the light units the same lint over AMids (both reports, AOptions)
  had to treat as unknown, as file paths, sorted. The host promotes them
  (TPasSemaProject.PromoteUnit) and asks again until the answer is empty -
  a promotion loads the unit's implementation-only units light, which may
  be needed in turn - recreates its navigator, then lints. A promotion
  refused leaves its unit's doubts on the rows. The lint itself stays
  read-only. }
function LintPromotions(ANav: TPasNavigator; const AMids: TArray<Integer>;
  AOptions: TPasLintOptions = []): TArray<string>;

{ LintPromotions as the uses lint's DEMAND (TPasNavigator's light-mode
  family, docs/library-light-mode.md): the same light units, for
  TPasSemaProject.EnsureFull / PasEnsureDemand - which promote them in one
  batch, take in what their implementations import and ask again until
  nothing is left - and, as LoadOnly, the not-loaded imports of light units
  through which a full closure may still reach a unit a removal seems to
  leave out (a library body reaching it, 0.123.0): taken in light, the
  next round reads that far. Empty, at no cost, when no unit is light. Both
  reports set ANav.NotSearched: the light units their answer had to treat
  as unknown, and those imports (0 after the demand is met). }
function DemandLint(ANav: TPasNavigator; const AMids: TArray<Integer>;
  AOptions: TPasLintOptions = []): TPasDemand;

{ ---- Unused declarations ----

  A declaration of the units asked about that nothing in the analysis uses:
  no reference by name (FindReferences' rule - a property counts the
  references of its redeclaration chain, so a descendant's `property X;`
  keeps the ancestor's), no bare `inherited;` running it, no form file
  naming it (a frame's class placed on a form). Kinds weighed: types,
  routines (nested ones too), unit and class variables and constants,
  fields, properties. A routine's locals and parameters are not: dcc hints
  them itself (H2164, H2219).

  What is reached other than by name is not weighed, and counted
  (TPasUnusedSkip): published members, which form files and RTTI find by
  name - in a class that streams (a TPersistent descendant) the unnamed
  first section too; virtual, dynamic, abstract, override and message
  methods, run through dispatch; an interface's members, and a class's
  method that an interface its class, an ancestor or a descendant lists
  names (dcc pairs them by name; a method reference type in the list names
  Invoke); operators; class constructors and destructors; the constructors
  of a TCustomAttribute descendant, which `[Name(...)]` calls; the for-in
  protocol (GetEnumerator, MoveNext, Current); generated units (`_TLB`, the
  IDE's import headers). A false "unused" costs a deleted declaration that
  was in use, so the exceptions are the rule. A reference hit that cannot
  be mapped back to what it binds (an include file) keeps every candidate of
  its name.

  What the index cannot settle is a doubt on the row: the name written in a
  branch this configuration does not compile, or - a type - as a whole
  string literal (FindClass('TFoo'); a member only as 'TFoo.Bar': a member
  RTTI finds by name is published), in the project's own files (not under
  ANav.LibraryPaths); a record's field, whose record may be read
  or written whole; another overload of the name in use (a call bound to it
  may run this one under dcc's rules); the name declared at unit level by
  another unit too (the `uses` order decides which one a unit binds); the
  name written where the analysis bound nothing (what dcc binds there is
  not known). Each
  of the last two is a binding of the index's that dcc made otherwise on a
  4,000-unit group. One analysis, one configuration: pastree-mcp's `lint
  unused-symbol` keeps a row only when every analysis of a group holding
  the unit finds it unused. }
type
  TPasUnusedSkip = (usPublished, usDispatch, usInterface, usImplements,
    usOperator, usClassCtor, usAttribute, usForIn, usGenerated);
  TPasUnusedSkips = array[TPasUnusedSkip] of Integer;

  TPasUnusedSymbol = record
    UnitId, Sym: Integer;     // the declaration, in ANav's project
    FileName: string;         // the file it is written in (an include too)
    Line, Col: Integer;       // 1-based: its name
    Name: string;             // qualified by the types it is declared in
    Kind: TSemaSymbolKind;
    Head: TPasRoutineHead;    // a routine's; rhNone else
    RecordField: Boolean;
    Doubts: TArray<string>;   // one sentence each; empty when none
  end;

// The unused declarations of the units AMids, by file, line and column.
// ASkips counts what was not weighed (generated units: one per unit).
function FindUnusedSymbols(ANav: TPasNavigator; const AMids: TArray<Integer>;
  out ASkips: TPasUnusedSkips): TArray<TPasUnusedSymbol>;

// FindUnusedSymbols' demand in light mode: the references of the
// declarations it searches (DemandReferencesOfAll) - a library body may use
// an own declaration only there.
function DemandUnusedSymbols(ANav: TPasNavigator;
  const AMids: TArray<Integer>): TPasDemand;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.StrUtils,
  System.Math,
  System.Character,
  System.RegularExpressions,
  System.Generics.Collections,
  System.Generics.Defaults,
  PasTree.Types,
  PasTree.Preprocessor,
  PasTree.Ast,
  PasTree.Dfm;

const
  // Units, places or calls named in one doubt; past them, counted.
  MAX_NAMED = 3;

type
  TLintPlace = record
    FilePath: string;
    Line: Integer;
  end;

  TLintEntry = record
    Name: string;
    NameNode: Integer;
    UnitId, Sym: Integer;
    InInterface, Used: Boolean;
    Doubts: TArray<string>;
  end;

  // What is read more than once over the units checked: the interface names
  // A form file as DesignerUnits reads it: whether it is there and parses,
  // its root object's class, every class name it streams (folded).
  TLintFormInfo = record
    Valid: Boolean;
    RootClass: string;
    Classes: TArray<string>;
  end;

  // of the units they list, the uses graph, what each program reaches, which
  // units run code at start.
  TUsesLint = class
  private
    FNav: TPasNavigator;
    FProj: TPasSemaProject;
    // An inline routine (model shl 32 or symbol) -> the units its expansion
    // needs; nil while it is being computed (a recursive inline routine).
    FInline: TDictionary<Int64, TArray<Integer>>;
    // A property -> its accessors marked inline.
    FAccessors: TDictionary<Int64, TArray<Int64>>;
    FNames: TObjectDictionary<Integer, TDictionary<string, Integer>>;
    FEffect: TDictionary<Integer, string>;
    FReach: TDictionary<Integer, TArray<Boolean>>;
    FStart, FEdges: TArray<Integer>;
    FRoots: TArray<Integer>;
    FRows: TList<TPasUnusedUse>;
    FDeadEdges: TDictionary<Int64, Boolean>;   // From shl 32 or Target
    FOptions: TPasLintOptions;
    FGlobalInit: TDictionary<Integer, Boolean>;
    // Light mode: an inline routine -> the LIGHT units its expansion depends
    // on (a body there is not analyzed), and every light unit an answer had
    // to treat as unknown - what LintPromotions returns.
    FInlineLight: TDictionary<Int64, TArray<Integer>>;
    FLightNeeded: TDictionary<Integer, Boolean>;
    // Light mode, the reach past the loaded models (KeptPastLoaded): the
    // units nobody loaded, as nodes ModelCount + index, by lower path; each
    // node's `uses` targets, built on first walk; and the not-loaded imports
    // of loaded units a removal's answer needs taken in - LintPromotions'
    // LoadOnly.
    FNLNodes: TDictionary<string, Integer>;
    FNLPaths: TList<string>;
    FNLOut: TDictionary<Integer, TArray<Integer>>;
    FLoadNeeded: TDictionary<string, Boolean>;
    // DesignerUnits' form files by lower-cased path: every component class
    // of every form climbs its ancestry, and each level asked the disk for
    // two files and re-parsed the one it found - 12 of the lint's 13 s on a
    // 1,566-unit project.
    FForms: TDictionary<string, TLintFormInfo>;
    function FormInfo(const AFile: string): TLintFormInfo;
    function IsLight(AMid: Integer): Boolean;
    procedure BuildGraph;
    function GlobalInit(AMid: Integer): Boolean;
    function DropsGlobalInit(AFrom, ATo: Integer): Boolean;
    function ReachOf(ARoot, ASkipFrom, ASkipTo: Integer): TArray<Boolean>;
    function FullReach(ARoot: Integer): TArray<Boolean>;
    function EffectsFrom(AStart: Integer; const ALost, AKept: TArray<Boolean>;
      out AUnknown: TArray<Integer>; out APending: TArray<string>): TArray<string>;
    function NLNode(const APath: string): Integer;
    function PastLoadedOut(ANode: Integer): TArray<Integer>;
    function KeptPastLoaded(const ALess, ALost: TArray<Boolean>): TArray<Boolean>;
    function NamesOf(AMid: Integer): TDictionary<string, Integer>;
    function LinkEffect(AMid: Integer): string;
    function NeedsItsUnit(const AExt: TPasExtRef): Boolean;
    function UnitNameOf(AMid: Integer): string;
    function DropsText(AFrom, ATo: Integer; out AUnknown: string): string;
    procedure AddNodeUnits(AMid, ANode: Integer;
      AUnits: TDictionary<Integer, Boolean>);
    procedure AddTypeUnits(AMid, ASym: Integer;
      AUnits: TDictionary<Integer, Boolean>);
    function InlineAccessors(AMid, ASym: Integer): TArray<Int64>;
    function InlineDeps(AMid, ASym: Integer): TArray<Integer>;
    // After InlineDeps of the same routine (AKey = model shl 32 or symbol):
    // the light units its expansion depends on, nil for none.
    function InlineLightOf(AKey: Int64): TArray<Integer>;
    function ClassTypeIn(AMid: Integer; const ANameLower: string): TSemaXType;
    function DesignerUnits(AMid: Integer; const AFormFile: string;
      const AClasses: TArray<string>): TDictionary<Integer, Boolean>;
    // AEdges: record the unused entries no doubt holds back as FDeadEdges
    // instead of rows - a program's too (its `uses` lists units the build
    // takes in, what FindUnreferencedUnits weighs).
    procedure CheckUnit(AMid: Integer; AEdges: Boolean = False);
    function LiveUnits: TArray<Boolean>;
  public
    constructor Create(ANav: TPasNavigator);
    destructor Destroy; override;
  end;

function IsIdentChar(ACh: Char): Boolean;
begin
  Result := PasIsIdentChar(ACh);
end;

// 'a, b and 2 more'.
function NamedList(const AItems: TArray<string>; AMax: Integer): string;
begin
  Result := '';
  for var LI := 0 to Min(Length(AItems), AMax) - 1 do
  begin
    if LI > 0 then
      Result := Result + IfThen(LI = Length(AItems) - 1, ' and ', ', ');
    Result := Result + AItems[LI];
  end;
  if Length(AItems) > AMax then
    Result := Result + Format(' and %d more', [Length(AItems) - AMax]);
end;

// The module node: the root itself, or its child.
function ModuleNode(LM: TPasSemaModel): Integer;
var
  LC: Integer;
begin
  Result := NIL_NODE;
  if Length(LM.Tree.Nodes) = 0 then
    Exit;
  if LM.Tree.Nodes[0].Kind in [nkUnit, nkProgram, nkLibrary, nkPackage] then
    Exit(0);
  LC := LM.Tree.Nodes[0].FirstChild;
  while LC <> NIL_NODE do
  begin
    if LM.Tree.Nodes[LC].Kind in [nkUnit, nkProgram, nkLibrary, nkPackage] then
      Exit(LC);
    LC := LM.Tree.Nodes[LC].NextSibling;
  end;
end;

// The module's child of kind AKind, NIL_NODE when it has none.
function ModuleChild(LM: TPasSemaModel; AKind: TPasNodeKind): Integer;
var
  LMod: Integer;
begin
  Result := NIL_NODE;
  LMod := ModuleNode(LM);
  if LMod = NIL_NODE then
    Exit;
  Result := LM.Tree.Nodes[LMod].FirstChild;
  while (Result <> NIL_NODE) and (LM.Tree.Nodes[Result].Kind <> AKind) do
    Result := LM.Tree.Nodes[Result].NextSibling;
end;

// Whether ANode's subtree holds anything but empty blocks: an
// `initialization` with a statement in it.
function HasStatements(LM: TPasSemaModel; ANode: Integer): Boolean;
var
  LC: Integer;
begin
  Result := False;
  LC := LM.Tree.Nodes[ANode].FirstChild;
  while LC <> NIL_NODE do
  begin
    if not (LM.Tree.Nodes[LC].Kind in [nkBlock, nkEmptyStmt]) or
       HasStatements(LM, LC) then
      Exit(True);
    LC := LM.Tree.Nodes[LC].NextSibling;
  end;
end;

function InUsesClause(LM: TPasSemaModel; ANode: Integer): Boolean;
var
  LP: Integer;
begin
  LP := ANode;
  while LP <> NIL_NODE do
  begin
    if LM.Tree.Nodes[LP].Kind = nkUsesClause then
      Exit(True);
    LP := LM.Tree.Nodes[LP].Parent;
  end;
  Result := False;
end;

// The 1-based line of ANode's first token, in the file it is written in.
procedure NodePlace(LM: TPasSemaModel; ANode: Integer; out AFile: string;
  out ALine: Integer);
var
  LVisTok, LCol: Integer;
  LVis: TPasVisibleToken;
  LTS: TPasTokenStream;
begin
  AFile := '';
  ALine := 0;
  LVisTok := LM.Tree.NodeLeftmostVis(ANode);
  if (LVisTok < 0) or (LVisTok > High(LM.Tree.Source.Visible)) then
    Exit;
  LVis := LM.Tree.Source.Visible[LVisTok];
  LTS := LM.Tree.Source.Files[LVis.FileId];
  AFile := LM.Tree.Source.FileNames[LVis.FileId];
  LTS.OffsetToLineCol(LTS.Tokens[LVis.TokenIndex].Start, ALine, LCol);
end;

// The row of a `uses` entry: its whole (dotted) name highlighted.
function EntryHit(LM: TPasSemaModel; ANode: Integer;
  out AHit: TPasRefHit): Boolean;
var
  LFirstVis, LLastVis, LLineTo, LColTo: Integer;
  LFrom, LTo: TPasVisibleToken;
  LTS: TPasTokenStream;
begin
  Result := False;
  AHit := Default(TPasRefHit);
  LFirstVis := LM.Tree.NodeLeftmostVis(ANode);
  LLastVis := LM.Tree.Nodes[ANode].LastToken;
  if (LFirstVis < 0) or (LLastVis < LFirstVis) or
     (LLastVis > High(LM.Tree.Source.Visible)) then
    Exit;
  LFrom := LM.Tree.Source.Visible[LFirstVis];
  LTo := LM.Tree.Source.Visible[LLastVis];
  LTS := LM.Tree.Source.Files[LFrom.FileId];
  AHit.FilePath := LM.Tree.Source.FileNames[LFrom.FileId];
  LTS.OffsetToLineCol(LTS.Tokens[LFrom.TokenIndex].Start, AHit.Line, AHit.Col);
  AHit.Snippet := LTS.LineText(AHit.Line);
  AHit.HiFrom := AHit.Col - 1;
  AHit.HiTo := AHit.HiFrom + LTS.Tokens[LFrom.TokenIndex].Len;
  // A name written over several lines (or files) highlights its first
  // segment alone.
  if LTo.FileId = LFrom.FileId then
  begin
    LTS.OffsetToLineCol(LTS.Tokens[LTo.TokenIndex].EndPos, LLineTo, LColTo);
    if LLineTo = AHit.Line then
      AHit.HiTo := LColTo - 1;
  end;
  Result := True;
end;

// The words of LM's branches not compiled here, lower case -> the first
// place each is written. Only the unit's own files (FileId 0 and its
// includes): a library include's dead branches say nothing of this unit.
function SkippedWordPlaces(LM: TPasSemaModel): TDictionary<string, TLintPlace>;
var
  LText, LWord: string;
  LAt, LEnd, LCol: Integer;
  LPlace: TLintPlace;
begin
  Result := TDictionary<string, TLintPlace>.Create;
  for var LFi := 0 to Min(High(LM.Tree.Source.Skipped),
    High(LM.Tree.Source.Files)) do
    for var LR in LM.Tree.Source.Skipped[LFi] do
    begin
      LText := Copy(LM.Tree.Source.Files[LFi].Source, LR.Start + 1,
        LR.EndPos - LR.Start);
      LAt := 1;
      while LAt <= Length(LText) do
      begin
        if not IsIdentChar(LText[LAt]) or ((LAt > 1) and
          IsIdentChar(LText[LAt - 1])) then
        begin
          Inc(LAt);
          Continue;
        end;
        LEnd := LAt;
        while (LEnd <= Length(LText)) and IsIdentChar(LText[LEnd]) do
          Inc(LEnd);
        LWord := PasFoldName(Copy(LText, LAt, LEnd - LAt));
        if not Result.ContainsKey(LWord) then
        begin
          LM.Tree.Source.Files[LFi].OffsetToLineCol(LR.Start + LAt - 1,
            LPlace.Line, LCol);
          LPlace.FilePath := LM.Tree.Source.FileNames[LFi];
          Result.Add(LWord, LPlace);
        end;
        LAt := LEnd;
      end;
    end;
end;

// The identifiers of LM bound to nothing, lower case -> the first node: a
// name the index could not resolve may be one of a unit called unused. A
// member name after a dot is left out - the unit of its base decides it.
function UnboundWords(LM: TPasSemaModel): TDictionary<string, Integer>;
var
  LP, LMod: Integer;
  LSkip: TArray<TPair<Integer, Integer>>;   // token ranges: the module's
                                            // name, its uses clauses
  LOut: Boolean;
begin
  Result := TDictionary<string, Integer>.Create;
  LSkip := nil;
  LMod := ModuleNode(LM);
  if LMod <> NIL_NODE then
    LP := LM.Tree.Nodes[LMod].FirstChild
  else
    LP := NIL_NODE;
  if LP <> NIL_NODE then
    LSkip := LSkip + [TPair<Integer, Integer>.Create(
      LM.Tree.Nodes[LP].FirstToken, LM.Tree.Nodes[LP].LastToken)];
  for var LNode := 0 to High(LM.Tree.Nodes) do
    if LM.Tree.Nodes[LNode].Kind = nkUsesClause then
      LSkip := LSkip + [TPair<Integer, Integer>.Create(
        LM.Tree.Nodes[LNode].FirstToken, LM.Tree.Nodes[LNode].LastToken)];
  for var LNode := 0 to Min(High(LM.Tree.Nodes), High(LM.RefMap)) do
  begin
    if LM.Tree.Nodes[LNode].Kind <> nkIdent then
      Continue;
    LOut := False;
    for var LR in LSkip do
      if (LM.Tree.Nodes[LNode].FirstToken >= LR.Key) and
         (LM.Tree.Nodes[LNode].FirstToken <= LR.Value) then
        LOut := True;
    if LOut or (nfName in LM.Tree.Nodes[LNode].Flags) or
       (LM.RefMap[LNode] <> NIL_SYM) or LM.ExtRefMap.ContainsKey(LNode) then
      Continue;
    LP := LM.Tree.Nodes[LNode].Parent;
    if (LP <> NIL_NODE) and (LM.Tree.Nodes[LP].FirstChild <> LNode) and
       (LM.Tree.Nodes[LP].Kind = nkMember) then
      Continue;
    if (LP <> NIL_NODE) and (LM.Tree.Nodes[LP].FirstChild = LNode) and
       (LM.Tree.Nodes[LP].Kind in [nkNamedArg, nkAggregateField]) then
      Continue;
    Result.TryAdd(PasFoldName(LM.Tree.NodeText(LNode)), LNode);
  end;
end;

{ TUsesLint }

constructor TUsesLint.Create(ANav: TPasNavigator);
var
  LM: TPasSemaModel;
  LMod: Integer;
begin
  inherited Create;
  FNav := ANav;
  FProj := ANav.Project;
  FInline := TDictionary<Int64, TArray<Integer>>.Create;
  FAccessors := TDictionary<Int64, TArray<Int64>>.Create;
  FNames := TObjectDictionary<Integer, TDictionary<string, Integer>>.Create(
    [doOwnsValues]);
  FEffect := TDictionary<Integer, string>.Create;
  FReach := TDictionary<Integer, TArray<Boolean>>.Create;
  FRows := TList<TPasUnusedUse>.Create;
  FDeadEdges := TDictionary<Int64, Boolean>.Create;
  FGlobalInit := TDictionary<Integer, Boolean>.Create;
  FInlineLight := TDictionary<Int64, TArray<Integer>>.Create;
  FLightNeeded := TDictionary<Integer, Boolean>.Create;
  FNLNodes := TDictionary<string, Integer>.Create;
  FNLPaths := TList<string>.Create;
  FNLOut := TDictionary<Integer, TArray<Integer>>.Create;
  FLoadNeeded := TDictionary<string, Boolean>.Create;
  FForms := TDictionary<string, TLintFormInfo>.Create;
  for var LMid := 0 to FProj.ModelCount - 1 do
  begin
    LM := FProj.Model(LMid);
    LMod := ModuleNode(LM);
    if (LMod <> NIL_NODE) and
       (LM.Tree.Nodes[LMod].Kind in [nkProgram, nkLibrary, nkPackage]) then
      FRoots := FRoots + [LMid];
  end;
end;

destructor TUsesLint.Destroy;
begin
  FForms.Free;
  FLoadNeeded.Free;
  FNLOut.Free;
  FNLPaths.Free;
  FNLNodes.Free;
  FLightNeeded.Free;
  FInlineLight.Free;
  FGlobalInit.Free;
  FAccessors.Free;
  FInline.Free;
  FDeadEdges.Free;
  FRows.Free;
  FReach.Free;
  FEffect.Free;
  FNames.Free;
  inherited;
end;

// A light model (TPasSemaProject.LightPaths): its implementation - bodies,
// implementation `uses`, initialization - was never analyzed.
function TUsesLint.IsLight(AMid: Integer): Boolean;
begin
  Result := FProj.IsLight(AMid);
end;

function TUsesLint.UnitNameOf(AMid: Integer): string;
begin
  Result := TPath.GetFileNameWithoutExtension(FProj.ModelFile(AMid));
end;

function TUsesLint.NamesOf(AMid: Integer): TDictionary<string, Integer>;
var
  UM: TPasSemaModel;
  LNames: TDictionary<string, Integer>;
begin
  if FNames.TryGetValue(AMid, Result) then
    Exit;
  LNames := TDictionary<string, Integer>.Create;
  FNames.Add(AMid, LNames);
  Result := LNames;
  UM := FProj.Model(AMid);
  if (UM.InterfaceScope < 0) or (UM.InterfaceScope >= UM.Scopes.Count) then
    Exit;
  UM.EnumScopeDeep(UM.InterfaceScope,
    procedure(ASym, AScope: Integer)
    begin
      if (UM.Scopes[AScope].Kind in [sckUnit, sckEnum]) and
         (UM.Symbols[ASym].Kind <> skUnitRef) then
        LNames.TryAdd(UM.Symbols[ASym].NameLower, ASym);
    end);
end;

// What linking AMid into a program does by itself, '' for nothing: it has
// initialization or finalization code, or links a resource in.
function TUsesLint.LinkEffect(AMid: Integer): string;
var
  LM: TPasSemaModel;
  LSec: Integer;
  LText: string;
begin
  if FEffect.TryGetValue(AMid, Result) then
    Exit;
  LM := FProj.Model(AMid);
  Result := '';
  LSec := ModuleChild(LM, nkInitSec);
  if (LSec <> NIL_NODE) and HasStatements(LM, LSec) then
    Result := 'initialization';
  LSec := ModuleChild(LM, nkFinalSec);
  if (Result = '') and (LSec <> NIL_NODE) and HasStatements(LM, LSec) then
    Result := 'finalization';
  // `{$R WindowsXP.res}` - Vcl.XPMan does nothing else. A form file's
  // `{$R *.dfm}` is not counted: its class is what a program would use.
  if Result = '' then
  begin
    try
      LText := TFile.ReadAllText(FProj.ModelFile(AMid));
    except
      LText := '';
    end;
    for var LMatch in TRegEx.Matches(LText,
      '\{\$(R|RESOURCE)\s+([^}]*)\}', [roIgnoreCase]) do
      if not TRegEx.IsMatch(LMatch.Groups[2].Value,
        '^\s*[+-]|\*\.(dfm|fmx|xfm)', [roIgnoreCase]) then
      begin
        Result := 'a resource';
        Break;
      end;
  end;
  FEffect.Add(AMid, Result);
end;

// Whether a binding to AExt needs its unit in `uses`: a unit-level
// declaration of its interface, an enum value, a helper's member - not a
// member reached through a value or a type.
function TUsesLint.NeedsItsUnit(const AExt: TPasExtRef): Boolean;
var
  UM: TPasSemaModel;
  LScope, LOwner: Integer;
begin
  Result := False;
  if (AExt.UnitId < 0) or (AExt.UnitId >= FProj.ModelCount) then
    Exit;
  UM := FProj.Model(AExt.UnitId);
  if (AExt.Sym < 0) or (AExt.Sym >= UM.SymCount) then
    Exit;
  LScope := UM.Symbols[AExt.Sym].Scope;
  if (LScope < 0) or (LScope >= UM.Scopes.Count) then
    Exit;
  case UM.Scopes[LScope].Kind of
    sckUnit, sckEnum:
      Result := True;
    sckStruct:
      begin
        LOwner := UM.Scopes[LScope].OwnerNode;
        Result := (LOwner >= 0) and (LOwner <= High(UM.Tree.Nodes)) and
          (UM.Tree.Nodes[LOwner].Kind = nkHelperType);
      end;
  end;
end;

procedure TUsesLint.BuildGraph;
var
  LN, LTo: Integer;
  LFill: TArray<Integer>;
  LM: TPasSemaModel;
begin
  if FStart <> nil then
    Exit;
  LN := FProj.ModelCount;
  SetLength(FStart, LN + 1);
  for var LMid := 0 to LN - 1 do
  begin
    LM := FProj.Model(LMid);
    for var LU := 0 to High(LM.UsesList) do
    begin
      LTo := LM.UsesList[LU].UnitId;
      if (LTo >= 0) and (LTo < LN) then
        Inc(FStart[LMid + 1]);
    end;
  end;
  for var LI := 1 to LN do
    Inc(FStart[LI], FStart[LI - 1]);
  SetLength(FEdges, FStart[LN]);
  LFill := Copy(FStart);
  for var LMid := 0 to LN - 1 do
  begin
    LM := FProj.Model(LMid);
    for var LU := 0 to High(LM.UsesList) do
    begin
      LTo := LM.UsesList[LU].UnitId;
      if (LTo >= 0) and (LTo < LN) then
      begin
        FEdges[LFill[LMid]] := LTo;
        Inc(LFill[LMid]);
      end;
    end;
  end;
end;

// The units ARoot reaches through `uses`, the edge ASkipFrom -> ASkipTo left
// out (-1: none). nil when ASkipTo is reached all the same: whatever the edge
// led to is then reached through another path, and nothing is lost.
function TUsesLint.ReachOf(ARoot, ASkipFrom, ASkipTo: Integer): TArray<Boolean>;
var
  LQueue: TList<Integer>;
  LAt, LU: Integer;
begin
  BuildGraph;
  Result := nil;
  SetLength(Result, FProj.ModelCount);
  LQueue := TList<Integer>.Create;
  try
    Result[ARoot] := True;
    LQueue.Add(ARoot);
    LAt := 0;
    while LAt < LQueue.Count do
    begin
      LU := LQueue[LAt];
      for var LE := FStart[LU] to FStart[LU + 1] - 1 do
        if not Result[FEdges[LE]] and
           not ((LU = ASkipFrom) and (FEdges[LE] = ASkipTo)) then
        begin
          if (ASkipTo >= 0) and (FEdges[LE] = ASkipTo) then
            Exit(nil);
          Result[FEdges[LE]] := True;
          LQueue.Add(FEdges[LE]);
        end;
      Inc(LAt);
    end;
  finally
    LQueue.Free;
  end;
end;

function TUsesLint.FullReach(ARoot: Integer): TArray<Boolean>;
begin
  if not FReach.TryGetValue(ARoot, Result) then
  begin
    Result := ReachOf(ARoot, -1, -1);
    FReach.Add(ARoot, Result);
  end;
end;

// The units with an effect AStart reaches through the units in ALost,
// 'Name (initialization)'. A light unit among them is not judged - its
// initialization and what its implementation `uses` brings in are not known:
// it goes to AUnknown instead (the caller records it in FLightNeeded). A unit
// in AKept (nil: none) may stay reached through units nobody loaded: not
// judged either - a unit with an effect, or a light one, goes to APending.
function TUsesLint.EffectsFrom(AStart: Integer; const ALost,
  AKept: TArray<Boolean>; out AUnknown: TArray<Integer>;
  out APending: TArray<string>): TArray<string>;
var
  LSeen: TArray<Boolean>;
  LQueue: TList<Integer>;
  LAt, LU: Integer;
begin
  Result := nil;
  AUnknown := nil;
  APending := nil;
  SetLength(LSeen, FProj.ModelCount);
  LQueue := TList<Integer>.Create;
  try
    LSeen[AStart] := True;
    LQueue.Add(AStart);
    LAt := 0;
    while LAt < LQueue.Count do
    begin
      LU := LQueue[LAt];
      if (AKept <> nil) and AKept[LU] then
      begin
        if IsLight(LU) or (LinkEffect(LU) <> '') then
          APending := APending + [UnitNameOf(LU)];
      end
      else if IsLight(LU) then
        AUnknown := AUnknown + [LU]
      else if LinkEffect(LU) <> '' then
        Result := Result + [Format('%s (%s)', [UnitNameOf(LU),
          LinkEffect(LU)])];
      for var LE := FStart[LU] to FStart[LU + 1] - 1 do
        if ALost[FEdges[LE]] and not LSeen[FEdges[LE]] then
        begin
          LSeen[FEdges[LE]] := True;
          LQueue.Add(FEdges[LE]);
        end;
      Inc(LAt);
    end;
  finally
    LQueue.Free;
  end;
end;

// The node of a unit nobody loaded (ModelCount + index), made on first use.
function TUsesLint.NLNode(const APath: string): Integer;
var
  LKey: string;
begin
  LKey := LowerCase(APath);
  if not FNLNodes.TryGetValue(LKey, Result) then
  begin
    Result := FProj.ModelCount + FNLPaths.Count;
    FNLPaths.Add(APath);
    FNLNodes.Add(LKey, Result);
  end;
end;

// The targets of ANode's `uses` past the loaded graph (FEdges): a loaded
// model's not-loaded imports, a not-loaded unit's every listed unit - a
// loaded one as its model id, the rest as NLNode.
function TUsesLint.PastLoadedOut(ANode: Integer): TArray<Integer>;
var
  LPaths: TArray<string>;
  LMid: Integer;
begin
  if FNLOut.TryGetValue(ANode, Result) then
    Exit;
  if ANode < FProj.ModelCount then
    LPaths := FProj.NotLoadedImports(ANode)
  else
    LPaths := FProj.NotLoadedUses(FNLPaths[ANode - FProj.ModelCount]);
  Result := nil;
  for var LPath in LPaths do
  begin
    LMid := FProj.ModelIdOf(LPath);
    if LMid >= 0 then
      Result := Result + [LMid]
    else
      Result := Result + [NLNode(LPath)];
  end;
  FNLOut.Add(ANode, Result);
end;

// Light mode: the units of ALost a full closure may still reach after the
// removal - through the units nobody loaded, past a light unit's
// implementation `uses` (a library body reaching a unit the removed entry
// also led to). The word index lists every name, conditional or not, so
// this over-approximates: such a unit is not called lost but PENDING, and
// the frontier of the path - the not-loaded import of a unit ALess keeps -
// goes to FLoadNeeded, taken in light by the demand. The next round walks
// the loaded graph that far, and the answer ends as the full analysis's.
// nil when nothing lost is reached that way (no light unit: no walk).
function TUsesLint.KeptPastLoaded(const ALess,
  ALost: TArray<Boolean>): TArray<Boolean>;
var
  LN, LAt, LU, LT: Integer;
  LSeen: TDictionary<Integer, Boolean>;
  LQueue: TList<Integer>;
  LTag: TDictionary<Integer, string>;   // node -> the frontier import's path
  LFrontier: string;
  LLeft, LWaveEnd: Integer;
  LWave: TArray<string>;

  procedure Visit(ANode: Integer; const AFrontier: string);
  begin
    if LSeen.ContainsKey(ANode) or
       ((ANode < LN) and ALess[ANode]) then
      Exit;
    LSeen.Add(ANode, True);
    LTag.Add(ANode, AFrontier);
    LQueue.Add(ANode);
  end;

begin
  Result := nil;
  if FProj.LightCount = 0 then
    Exit;
  LN := FProj.ModelCount;
  LSeen := TDictionary<Integer, Boolean>.Create;
  LTag := TDictionary<Integer, string>.Create;
  LQueue := TList<Integer>.Create;
  try
    // Only a light model has not-loaded imports worth a walk; the loaded
    // edges out of ALess stay inside it (the removed one aside).
    for LU := 0 to LN - 1 do
      if ALess[LU] and IsLight(LU) then
        for LT in PastLoadedOut(LU) do
          if LT >= LN then
            Visit(LT, FNLPaths[LT - LN]);
    // Done once every lost unit a row would name is reached.
    LLeft := 0;
    for LU := 0 to LN - 1 do
      if ALost[LU] and (IsLight(LU) or (LinkEffect(LU) <> '')) then
        Inc(LLeft);
    LAt := 0;
    LWaveEnd := 0;
    while (LAt < LQueue.Count) and (LLeft > 0) do
    begin
      // A wave's units nobody loaded are scanned together, in parallel.
      if LAt = LWaveEnd then
      begin
        LWave := nil;
        for var LI := LAt to LQueue.Count - 1 do
          if (LQueue[LI] >= LN) and not FNLOut.ContainsKey(LQueue[LI]) then
            LWave := LWave + [FNLPaths[LQueue[LI] - LN]];
        FProj.ScanNotLoaded(LWave);
        LWaveEnd := LQueue.Count;
      end;
      LU := LQueue[LAt];
      LFrontier := LTag[LU];
      if LU < LN then
      begin
        if ALost[LU] then
        begin
          if Result = nil then
            SetLength(Result, LN);
          Result[LU] := True;
          FLoadNeeded.AddOrSetValue(LFrontier, True);
          if IsLight(LU) or (LinkEffect(LU) <> '') then
            Dec(LLeft);
        end;
        for var LE := FStart[LU] to FStart[LU + 1] - 1 do
          Visit(FEdges[LE], LFrontier);
      end;
      for LT in PastLoadedOut(LU) do
        Visit(LT, LFrontier);
      Inc(LAt);
    end;
  finally
    LQueue.Free;
    LTag.Free;
    LSeen.Free;
  end;
end;

// 'removing it leaves X (initialization) out of P', '' when it leaves
// nothing with an effect out. With no program in the analysis (a directory
// of units) only the listed unit's own effect is known. AUnknown: the same
// for the light units the removal leaves out, whose effects are not known
// ('' for none) - a doubt on the safe side; and, in light mode, the units a
// library implementation not loaded may still reach (KeptPastLoaded) - not
// reported as left out, their path taken in by the demand.
function TUsesLint.DropsText(AFrom, ATo: Integer; out AUnknown: string): string;
var
  LFull, LLess, LLost, LKept: TArray<Boolean>;
  LUnits, LPrograms, LEffects, LLightUnits, LLightPrograms, LPending,
    LPendingUnits: TArray<string>;
  LUnknown: TArray<Integer>;
begin
  Result := '';
  AUnknown := '';
  LPendingUnits := nil;
  if FRoots = nil then
  begin
    if IsLight(ATo) then
    begin
      FLightNeeded.AddOrSetValue(ATo, True);
      AUnknown := Format('%s is analyzed interface-only - whether it has ' +
        'initialization a program may need linked in is not known',
        [UnitNameOf(ATo)]);
    end
    else if LinkEffect(ATo) <> '' then
      Result := Format('%s has %s - a program may need it linked in',
        [UnitNameOf(ATo), LinkEffect(ATo)]);
    Exit;
  end;
  LUnits := nil;
  LPrograms := nil;
  LLightUnits := nil;
  LLightPrograms := nil;
  for var LRoot in FRoots do
  begin
    LFull := FullReach(LRoot);
    if not LFull[AFrom] then
      Continue;
    LLess := ReachOf(LRoot, AFrom, ATo);
    if LLess = nil then
      Continue;
    SetLength(LLost, Length(LFull));
    for var LMid := 0 to High(LFull) do
      LLost[LMid] := LFull[LMid] and not LLess[LMid];
    LEffects := EffectsFrom(ATo, LLost, nil, LUnknown, LPending);
    // Light mode: what a library body may still reach is not lost yet -
    // walked only when something would be reported.
    if (LEffects <> nil) or (LUnknown <> nil) then
    begin
      LKept := KeptPastLoaded(LLess, LLost);
      if LKept <> nil then
        LEffects := EffectsFrom(ATo, LLost, LKept, LUnknown, LPending);
    end;
    for var LU in LPending do
      if not MatchText(LU, LPendingUnits) then
        LPendingUnits := LPendingUnits + [LU];
    for var LU in LEffects do
      if not MatchText(LU, LUnits) then
        LUnits := LUnits + [LU];
    if (LEffects <> nil) and not MatchText(UnitNameOf(LRoot), LPrograms) then
      LPrograms := LPrograms + [UnitNameOf(LRoot)];
    for var LU in LUnknown do
    begin
      FLightNeeded.AddOrSetValue(LU, True);
      if not MatchText(UnitNameOf(LU), LLightUnits) then
        LLightUnits := LLightUnits + [UnitNameOf(LU)];
    end;
    if (LUnknown <> nil) and
       not MatchText(UnitNameOf(LRoot), LLightPrograms) then
      LLightPrograms := LLightPrograms + [UnitNameOf(LRoot)];
  end;
  if LUnits <> nil then
    Result := Format('removing it leaves %s out of %s', [NamedList(LUnits,
      MAX_NAMED), NamedList(LPrograms, MAX_NAMED)]);
  if LLightUnits <> nil then
    AUnknown := Format('removing it leaves %s out of %s, analyzed ' +
      'interface-only - what their initialization and implementation bring ' +
      'in is not known', [NamedList(LLightUnits, MAX_NAMED),
      NamedList(LLightPrograms, MAX_NAMED)]);
  if LPendingUnits <> nil then
  begin
    if AUnknown <> '' then
      AUnknown := AUnknown + '; ';
    AUnknown := AUnknown + Format('whether removing it leaves %s out is ' +
      'not known - a library implementation not loaded may reach them',
      [NamedList(LPendingUnits, MAX_NAMED)]);
  end;
end;

// Whether AMid's initialization reaches outside the unit - see
// TPasLintOption. The section's subtree is walked, and the body of every
// routine of the unit it calls, to any depth; a binding to another unit
// decides by what it binds to.
function TUsesLint.GlobalInit(AMid: Integer): Boolean;
var
  LM, UM: TPasSemaModel;
  LSec, LNode, LChild, LScope, LBody: Integer;
  LStack: TList<Integer>;
  LSeen: TDictionary<Integer, Boolean>;   // own routine symbols walked
  LExt: TPasExtRef;
  LSym: Integer;

  // Whether ANode is the member name of `Q.Name` with Q a TYPE (`TReg.Add`,
  // `Unit.TReg.Add`) - a class member, reached without an object; a member
  // reached through a variable (`FList.Add`) is not.
  function TypeQualified(ANode: Integer): Boolean;
  var
    LP, LQ, LC: Integer;
    LQExt: TPasExtRef;
  begin
    Result := False;
    LP := LM.Tree.Nodes[ANode].Parent;
    if (LP = NIL_NODE) or (LM.Tree.Nodes[LP].Kind <> nkMember) or
       (LM.Tree.Nodes[LP].FirstChild = ANode) then
      Exit;
    LQ := LM.Tree.Nodes[LP].FirstChild;
    // A qualified qualifier: its last segment.
    while (LQ <> NIL_NODE) and (LM.Tree.Nodes[LQ].Kind = nkMember) do
    begin
      LC := LM.Tree.LastChild(LQ);
      LQ := LC;
    end;
    if LQ = NIL_NODE then
      Exit;
    if LM.ExtRefMap.TryGetValue(LQ, LQExt) then
      Result := (LQExt.UnitId >= 0) and (LQExt.UnitId < FProj.ModelCount) and
        (LQExt.Sym >= 0) and (LQExt.Sym < FProj.Model(LQExt.UnitId).SymCount) and
        (FProj.Model(LQExt.UnitId).Symbols[LQExt.Sym].Kind = skType)
    else if (LQ <= High(LM.RefMap)) and (LM.RefMap[LQ] <> NIL_SYM) and
       (LM.RefMap[LQ] < LM.SymCount) then
      Result := LM.Symbols[LM.RefMap[LQ]].Kind = skType;
  end;

  // A binding of ANode to another unit that acts on that unit's state.
  function Outside(ANode: Integer; const AExt: TPasExtRef): Boolean;
  begin
    Result := False;
    if (AExt.UnitId < 0) or (AExt.UnitId >= FProj.ModelCount) or
       (AExt.UnitId = AMid) then
      Exit;
    UM := FProj.Model(AExt.UnitId);
    if (AExt.Sym < 0) or (AExt.Sym >= UM.SymCount) then
      Exit;
    LScope := UM.Symbols[AExt.Sym].Scope;
    if (LScope < 0) or (LScope >= UM.Scopes.Count) then
      Exit;
    case UM.Scopes[LScope].Kind of
      sckUnit:
        Result := UM.Symbols[AExt.Sym].Kind in [skVar, skRoutine];
      // A class method, class var or class property: by the type's name.
      // (No symbol flag says `class` - sfClassMember is any struct member.)
      sckStruct:
        Result := (UM.Symbols[AExt.Sym].Kind in [skVar, skField, skRoutine,
          skProperty]) and
          not FProj.IsConstructorSym(AExt.UnitId, AExt.Sym) and
          TypeQualified(ANode);
    end;
  end;

begin
  if FGlobalInit.TryGetValue(AMid, Result) then
    Exit;
  // A light unit's initialization was never analyzed: unknown counts as
  // global - the safe side (its rows are held back, the unit kept).
  if IsLight(AMid) then
  begin
    FLightNeeded.AddOrSetValue(AMid, True);
    FGlobalInit.Add(AMid, True);
    Exit(True);
  end;
  Result := False;
  // Nodes and both maps only, as LinkEffect and AddNodeUnits: a
  // text-demoted model answers without hydrating (RoutineImplNode hydrates
  // what it pairs).
  LM := FProj.Model(AMid);
  LSec := ModuleChild(LM, nkInitSec);
  if (LSec <> NIL_NODE) and HasStatements(LM, LSec) then
  begin
    LStack := TList<Integer>.Create;
    LSeen := TDictionary<Integer, Boolean>.Create;
    try
      LStack.Add(LSec);
      while (LStack.Count > 0) and not Result do
      begin
        LNode := LStack.Last;
        LStack.Delete(LStack.Count - 1);
        if LM.ExtRefMap.TryGetValue(LNode, LExt) then
          Result := Outside(LNode, LExt)
        else if LNode <= High(LM.RefMap) then
        begin
          // A routine of this unit: its body runs too.
          LSym := LM.RefMap[LNode];
          if (LSym <> NIL_SYM) and (LSym < LM.SymCount) and
             (LM.Symbols[LSym].Kind = skRoutine) and
             not LSeen.ContainsKey(LSym) then
          begin
            LSeen.Add(LSym, True);
            LBody := FNav.RoutineImplNode(AMid, LSym);
            if LBody <> NIL_NODE then
              LStack.Add(LBody);
          end;
        end;
        LChild := LM.Tree.Nodes[LNode].FirstChild;
        while LChild <> NIL_NODE do
        begin
          LStack.Add(LChild);
          LChild := LM.Tree.Nodes[LChild].NextSibling;
        end;
      end;
    finally
      LSeen.Free;
      LStack.Free;
    end;
  end;
  FGlobalInit.Add(AMid, Result);
end;

// Whether removing AFrom's entry for ATo leaves a unit with a global
// initialization out of a program - ATo itself, or one only it brought in.
// With no program in the analysis, ATo's own.
function TUsesLint.DropsGlobalInit(AFrom, ATo: Integer): Boolean;
var
  LFull, LLess: TArray<Boolean>;
begin
  if FRoots = nil then
    Exit(GlobalInit(ATo));
  for var LRoot in FRoots do
  begin
    LFull := FullReach(LRoot);
    if not LFull[AFrom] then
      Continue;
    LLess := ReachOf(LRoot, AFrom, ATo);
    if LLess = nil then
      Continue;
    for var LMid := 0 to High(LFull) do
      if LFull[LMid] and not LLess[LMid] and GlobalInit(LMid) then
        Exit(True);
  end;
  Result := False;
end;

// What the program reaches through the edges FDeadEdges leaves.
function TUsesLint.LiveUnits: TArray<Boolean>;
var
  LQueue: TList<Integer>;
  LAt, LU, LN: Integer;

  function Dead(AFrom, ATo: Integer): Boolean;
  begin
    Result := FDeadEdges.ContainsKey((Int64(AFrom) shl 32) or Cardinal(ATo));
  end;

begin
  BuildGraph;
  LN := FProj.ModelCount;
  Result := nil;
  SetLength(Result, LN);
  if FRoots <> nil then
  begin
    LQueue := TList<Integer>.Create;
    try
      for var LRoot in FRoots do
      begin
        Result[LRoot] := True;
        LQueue.Add(LRoot);
      end;
      LAt := 0;
      while LAt < LQueue.Count do
      begin
        LU := LQueue[LAt];
        for var LE := FStart[LU] to FStart[LU + 1] - 1 do
          if not Result[FEdges[LE]] and not Dead(LU, FEdges[LE]) then
          begin
            Result[FEdges[LE]] := True;
            LQueue.Add(FEdges[LE]);
          end;
        Inc(LAt);
      end;
    finally
      LQueue.Free;
    end;
    Exit;
  end;
  // No program: nothing to reach from, so a unit is live while another unit
  // lists it and uses it. Not repeated: in a directory of units every unit
  // under a top one would drop with it, and the top ones are what the
  // directory is for.
  for LU := 0 to LN - 1 do
    for var LE := FStart[LU] to FStart[LU + 1] - 1 do
      if (FEdges[LE] <> LU) and not Dead(LU, FEdges[LE]) then
        Result[FEdges[LE]] := True;
end;

// The routine node a routine symbol's declaration sits in, NIL_NODE if none.
function RoutineNodeOf(LM: TPasSemaModel; ASym: Integer): Integer;
begin
  Result := LM.Symbols[ASym].DeclNode;
  while (Result <> NIL_NODE) and (LM.Tree.Nodes[Result].Kind <> nkRoutine) do
    Result := LM.Tree.Nodes[Result].Parent;
end;

// The units the bindings in ANode's subtree of model AMid belong to - a
// routine body left out (a declaration that holds its body gives its header).
// Nodes and both maps only: a text-demoted model answers too.
procedure TUsesLint.AddNodeUnits(AMid, ANode: Integer;
  AUnits: TDictionary<Integer, Boolean>);
var
  LM: TPasSemaModel;
  LStack: TList<Integer>;
  LNode, LChild: Integer;
  LExt: TPasExtRef;
begin
  if ANode = NIL_NODE then
    Exit;
  LM := FProj.Model(AMid);
  LStack := TList<Integer>.Create;
  try
    LStack.Add(ANode);
    while LStack.Count > 0 do
    begin
      LNode := LStack.Last;
      LStack.Delete(LStack.Count - 1);
      if LM.ExtRefMap.TryGetValue(LNode, LExt) then
        AUnits.AddOrSetValue(LExt.UnitId, True)
      else if (LNode <= High(LM.RefMap)) and (LM.RefMap[LNode] <> NIL_SYM) then
        AUnits.AddOrSetValue(AMid, True);
      LChild := LM.Tree.Nodes[LNode].FirstChild;
      while LChild <> NIL_NODE do
      begin
        if LM.Tree.Nodes[LChild].Kind <> nkRoutineBody then
          LStack.Add(LChild);
        LChild := LM.Tree.Nodes[LChild].NextSibling;
      end;
    end;
  finally
    LStack.Free;
  end;
end;

// The units of what a symbol's declaration names as its type: a routine's
// parameter and result types, a variable's, field's, parameter's, constant's
// or property's declared type. An inline body binding `GetY` needs the unit
// of GetY's result type though it names no symbol of it (`O := GetY`, probe
// UX3 in local/probe-inline: H2443 naming that unit).
procedure TUsesLint.AddTypeUnits(AMid, ASym: Integer;
  AUnits: TDictionary<Integer, Boolean>);
var
  LM: TPasSemaModel;
begin
  LM := FProj.Model(AMid);
  case LM.Symbols[ASym].Kind of
    skRoutine:
      AddNodeUnits(AMid, RoutineNodeOf(LM, ASym), AUnits);
    skVar, skConst, skField, skParam, skProperty:
      AddNodeUnits(AMid, LM.Symbols[ASym].TypeNode, AUnits);
  end;
end;

// A property's accessors marked inline (model shl 32 or symbol): the
// routines its `read`/`write` specifiers bind. A republished property
// (`property Caption;`) has none of its own and takes its ancestor's.
function TUsesLint.InlineAccessors(AMid, ASym: Integer): TArray<Int64>;
var
  LKey: Int64;
  LM, BM: TPasSemaModel;
  LMid, LSym, LDecl, LChild, LName, LPrevMid, LPrevSym: Integer;
  LExt: TPasExtRef;
  LBound: Boolean;
begin
  LKey := (Int64(AMid) shl 32) or Cardinal(ASym);
  if FAccessors.TryGetValue(LKey, Result) then
    Exit;
  Result := nil;
  for var LDepth := 1 to 16 do
  begin
    LM := FProj.Model(AMid);
    if LM.Symbols[ASym].DeclNode = NIL_NODE then
      Break;
    LDecl := LM.Tree.Nodes[LM.Symbols[ASym].DeclNode].Parent;
    if (LDecl = NIL_NODE) or (LM.Tree.Nodes[LDecl].Kind <> nkPropertyDecl) then
      Break;
    LBound := False;
    LChild := LM.Tree.Nodes[LDecl].FirstChild;
    while LChild <> NIL_NODE do
    begin
      LName := LM.Tree.Nodes[LChild].FirstChild;
      if (LM.Tree.Nodes[LChild].Kind = nkPropSpec) and (LName <> NIL_NODE) and
         (LM.Tree.Nodes[LName].Kind = nkIdent) then
      begin
        LMid := -1;
        LSym := NIL_SYM;
        if (LName <= High(LM.RefMap)) and (LM.RefMap[LName] <> NIL_SYM) then
        begin
          LMid := AMid;
          LSym := LM.RefMap[LName];
        end
        else if LM.ExtRefMap.TryGetValue(LName, LExt) then
        begin
          LMid := LExt.UnitId;
          LSym := LExt.Sym;
        end;
        if LMid >= 0 then
        begin
          BM := FProj.Model(LMid);
          if BM.Symbols[LSym].Kind in [skRoutine, skField] then
            LBound := True;
          if (BM.Symbols[LSym].Kind = skRoutine) and
             (sfInline in BM.Symbols[LSym].Flags) then
            Result := Result + [(Int64(LMid) shl 32) or Cardinal(LSym)];
        end;
      end;
      LChild := LM.Tree.Nodes[LChild].NextSibling;
    end;
    if LBound or not FProj.PropertyRedeclPrev(AMid, ASym, LPrevMid,
      LPrevSym) then
      Break;
    AMid := LPrevMid;
    ASym := LPrevSym;
  end;
  FAccessors.Add(LKey, Result);
end;

{ The units dcc needs in a caller's `uses` to expand a call of the inline
  routine ASym of model AMid: without one of them the call is compiled as a
  plain call and dcc says H2443 - the code changes, so the unit is used.
  Probed on dcc64 37.0 (local/probe-inline): every unit whose symbol the
  routine's declaration or body binds - a routine, a variable, a typed or a
  string constant, a type, a member reached through a value (`GetY.V`) -
  and the units of those symbols' declared types (`O := GetY`); the units an
  inline routine it calls needs (nested expansion), a property's inline
  getter included; units of the routine's implementation `uses` alike. An
  enum value folds into the code and asks for no unit; so do an ordinal
  constant, SizeOf and a cast of a constant, which this keeps (the error is
  on the safe side: a unit kept, never one called unused that is needed).
  The caller's `uses` must name each unit itself - one reaching it through
  another unit's `uses` does not do. }
function TUsesLint.InlineDeps(AMid, ASym: Integer): TArray<Integer>;
var
  LKey: Int64;
  LM: TPasSemaModel;
  LUnits: TDictionary<Integer, Boolean>;
  LNested: TList<Int64>;
  LStack: TList<Integer>;
  LDecl, LImpl, LNode, LChild: Integer;
  LExt: TPasExtRef;
  LLight: TDictionary<Integer, Boolean>;

  procedure Bind(ABMid, ABSym: Integer);
  var
    BM: TPasSemaModel;
  begin
    if (ABMid < 0) or (ABMid >= FProj.ModelCount) then
      Exit;
    BM := FProj.Model(ABMid);
    if (ABSym < 0) or (ABSym >= BM.SymCount) or
       (BM.Symbols[ABSym].Kind = skEnumValue) then
      Exit;
    LUnits.AddOrSetValue(ABMid, True);
    AddTypeUnits(ABMid, ABSym, LUnits);
    case BM.Symbols[ABSym].Kind of
      skRoutine:
        if sfInline in BM.Symbols[ABSym].Flags then
          LNested.Add((Int64(ABMid) shl 32) or Cardinal(ABSym));
      skProperty:
        LNested.AddRange(InlineAccessors(ABMid, ABSym));
    end;
  end;

  procedure Walk(ARoot: Integer);
  begin
    LStack.Clear;
    LStack.Add(ARoot);
    while LStack.Count > 0 do
    begin
      LNode := LStack.Last;
      LStack.Delete(LStack.Count - 1);
      if LM.ExtRefMap.TryGetValue(LNode, LExt) then
        Bind(LExt.UnitId, LExt.Sym)
      else if (LNode <= High(LM.RefMap)) and (LM.RefMap[LNode] <> NIL_SYM) then
        Bind(AMid, LM.RefMap[LNode]);
      LChild := LM.Tree.Nodes[LNode].FirstChild;
      while LChild <> NIL_NODE do
      begin
        LStack.Add(LChild);
        LChild := LM.Tree.Nodes[LChild].NextSibling;
      end;
    end;
  end;

begin
  LKey := (Int64(AMid) shl 32) or Cardinal(ASym);
  if FInline.TryGetValue(LKey, Result) then
    Exit;
  FInline.Add(LKey, nil);
  LUnits := TDictionary<Integer, Boolean>.Create;
  LNested := TList<Int64>.Create;
  LStack := TList<Integer>.Create;
  LLight := TDictionary<Integer, Boolean>.Create;
  try
    // A light unit's routine has no body here: what its expansion needs is
    // not known - recorded, for the doubt and for LintPromotions.
    if IsLight(AMid) then
    begin
      LLight.AddOrSetValue(AMid, True);
      FLightNeeded.AddOrSetValue(AMid, True);
    end;
    LImpl := FNav.RoutineImplNode(AMid, ASym);
    LM := FProj.Model(AMid);
    LDecl := RoutineNodeOf(LM, ASym);
    if LDecl <> NIL_NODE then
      Walk(LDecl);
    if (LImpl <> NIL_NODE) and (LImpl <> LDecl) then
      Walk(LImpl);
    for var LInner in LNested do
      if LInner <> LKey then
      begin
        for var LU in InlineDeps(LInner shr 32, Integer(LInner and $FFFFFFFF)) do
          LUnits.AddOrSetValue(LU, True);
        for var LU in InlineLightOf(LInner) do
          LLight.AddOrSetValue(LU, True);
      end;
    Result := LUnits.Keys.ToArray;
    if LLight.Count > 0 then
      FInlineLight.AddOrSetValue(LKey, LLight.Keys.ToArray);
  finally
    LLight.Free;
    LStack.Free;
    LNested.Free;
    LUnits.Free;
  end;
  FInline[LKey] := Result;
end;

function TUsesLint.FormInfo(const AFile: string): TLintFormInfo;
var
  LKey: string;
  LDoc: IPasDfmDoc;
begin
  LKey := LowerCase(AFile);
  if FForms.TryGetValue(LKey, Result) then
    Exit;
  Result := Default(TLintFormInfo);
  if FileExists(AFile) then
  begin
    LDoc := PasDfmLoad(AFile);
    if (LDoc <> nil) and (LDoc.Doc.Error = '') then
    begin
      Result.Valid := True;
      for var LI := 0 to High(LDoc.Doc.Idents) do
        if LDoc.Doc.Idents[LI].Role = dirClassName then
        begin
          if Result.Classes = nil then
            Result.RootClass := LDoc.Doc.IdentText(LI);
          Result.Classes := Result.Classes +
            [PasFoldName(LDoc.Doc.IdentText(LI))];
        end;
    end;
  end;
  FForms.Add(LKey, Result);
end;

function TUsesLint.InlineLightOf(AKey: Int64): TArray<Integer>;
begin
  if not FInlineLight.TryGetValue(AKey, Result) then
    Result := nil;
end;

// The class type ANameLower names in unit AMid - its own interface first,
// then its `uses` (a form file names classes the way the unit sees them);
// XNil when it names none.
function TUsesLint.ClassTypeIn(AMid: Integer;
  const ANameLower: string): TSemaXType;
var
  LM: TPasSemaModel;
  LSym, LRMid, LRSym: Integer;
begin
  Result := XNil;
  LM := FProj.Model(AMid);
  if LM.InterfaceScope <> NIL_SCOPE then
  begin
    LSym := LM.Resolve(LM.InterfaceScope, ANameLower);
    if (LSym <> NIL_SYM) and (LM.Symbols[LSym].Kind = skType) then
      Exit(XPlain(AMid, LSym));
  end;
  if FProj.ResolveRealDecl(AMid, ANameLower, LRMid, LRSym) and
     (FProj.Model(LRMid).Symbols[LRSym].Kind = skType) then
    Result := XPlain(LRMid, LRSym);
end;

{ The units the IDE's designer puts back into `uses` when it saves the form
  of unit AMid (AFormFile, whose class names are AClasses): the unit of
  every class each component descends from, and of every component of every
  form it inherits - though dcc needs none of them. Vcl.ImgList and
  System.ImageList for a TImageList, System.Actions for a TActionList,
  Vcl.ToolWin for a TToolBar; and for a form inheriting one that holds a
  component, that component's unit and its ancestors' too, although the
  form's own file does not name it (a descendant's file holds only what it
  changes). Removing one changes nothing a save does not undo, and the
  undoing rewrites the clause under whoever removed it: on a client's main
  form ten of the seventeen entries removed came back on the first save
  (0.93.3), and on a dialog three units of components on its third
  ancestor form did (0.93.4).

  Each class is bound in the unit whose form file names it, then climbed
  (AncestorOfX). A class on the way that is the ROOT of a form file of its
  own unit - an ancestor form, a frame - adds that file's classes, bound in
  that unit; each form file is read once. }
function TUsesLint.DesignerUnits(AMid: Integer; const AFormFile: string;
  const AClasses: TArray<string>): TDictionary<Integer, Boolean>;
var
  LQueue: TList<TPair<Integer, string>>;
  LSeen: TDictionary<string, Boolean>;
  LX: TSemaXType;
  LAt, LDepth: Integer;
  LFile: string;
  LInfo: TLintFormInfo;
begin
  Result := TDictionary<Integer, Boolean>.Create;
  LQueue := TList<TPair<Integer, string>>.Create;
  LSeen := TDictionary<string, Boolean>.Create;
  try
    LSeen.Add(LowerCase(AFormFile), True);
    for var LClass in AClasses do
      LQueue.Add(TPair<Integer, string>.Create(AMid, LClass));
    LAt := 0;
    while LAt < LQueue.Count do
    begin
      LX := ClassTypeIn(LQueue[LAt].Key, LQueue[LAt].Value);
      Inc(LAt);
      LDepth := 0;
      while XValid(LX) and (LDepth < 64) do
      begin
        Result.AddOrSetValue(LX.UnitId, True);
        for var LExt in ['.dfm', '.fmx'] do
        begin
          LFile := ChangeFileExt(FProj.ModelFile(LX.UnitId), LExt);
          if LSeen.ContainsKey(LowerCase(LFile)) then
            Continue;
          LInfo := FormInfo(LFile);
          // The file's first class is its root object's: only a form file
          // whose root IS this class holds components this form inherits.
          if not LInfo.Valid or not SameText(LInfo.RootClass,
             FProj.Model(LX.UnitId).Symbols[LX.Sym].Name) then
            Continue;
          LSeen.Add(LowerCase(LFile), True);
          for var LClass in LInfo.Classes do
            LQueue.Add(TPair<Integer, string>.Create(LX.UnitId, LClass));
        end;
        if not FProj.EnsureHydrated(LX.UnitId) then
          Break;
        LX := FProj.AncestorOfX(LX);
        Inc(LDepth);
      end;
    end;
  finally
    LSeen.Free;
    LQueue.Free;
  end;
end;

procedure TUsesLint.CheckUnit(AMid: Integer; AEdges: Boolean);
var
  LM: TPasSemaModel;
  LEntries: TList<TLintEntry>;
  LByName: TDictionary<string, Integer>;
  LByUnit, LBySym: TDictionary<Integer, Integer>;
  LOrphans: TList<TPair<Integer, TPasExtRef>>;
  LImplSec, LImplTok, LE, LNode, LSym, LLine: Integer;
  LInIface: Boolean;
  LEntry: TLintEntry;
  LKey, LName, LFile, LFormFile, LText: string;
  LDoc: IPasDfmDoc;
  LFormWords: TDictionary<string, Integer>;
  LUnbound: TDictionary<string, Integer>;
  LSkipped: TDictionary<string, TLintPlace>;
  LOverCalls: TDictionary<string, Integer>;   // called routine name -> a call
  LNames: TDictionary<string, Integer>;
  LInline: TDictionary<Integer, Boolean>;   // units inline expansions need
  LInlineLight: TArray<string>;   // light units whose expansions are unknown
  LExtM: TPasSemaModel;
  LKeys: TArray<Int64>;
  LRow: TPasUnusedUse;
  LFormClasses: TArray<string>;   // the class names the form file streams
  LDesign: TDictionary<Integer, Boolean>;

  procedure MarkUse(AIdx: Integer);
  var
    LX: TLintEntry;
  begin
    LX := LEntries[AIdx];
    LX.Used := True;
    LEntries[AIdx] := LX;
  end;

  procedure AddDoubt(AIdx: Integer; const AText: string);
  var
    LX: TLintEntry;
  begin
    LX := LEntries[AIdx];
    if MatchText(AText, LX.Doubts) then
      Exit;
    LX.Doubts := LX.Doubts + [AText];
    LEntries[AIdx] := LX;
  end;

begin
  if not FProj.EnsureHydrated(AMid) then
    Exit;
  LM := FProj.Model(AMid);
  // A program, a library, a package: its uses are its contents - but which
  // of them the build would still take in is a question of reach. A
  // package's `contains` is never optional.
  if (ModuleChild(LM, nkInterfaceSec) = NIL_NODE) and (not AEdges or
    (ModuleNode(LM) = NIL_NODE) or
    (LM.Tree.Nodes[ModuleNode(LM)].Kind in [nkUnit, nkPackage])) then
    Exit;
  LImplSec := ModuleChild(LM, nkImplementationSec);
  if LImplSec = NIL_NODE then
    LImplTok := MaxInt
  else
    LImplTok := LM.Tree.Nodes[LImplSec].FirstToken;
  LEntries := TList<TLintEntry>.Create;
  LByName := TDictionary<string, Integer>.Create;
  LByUnit := TDictionary<Integer, Integer>.Create;
  LBySym := TDictionary<Integer, Integer>.Create;
  LOrphans := TList<TPair<Integer, TPasExtRef>>.Create;
  LUnbound := nil;
  LSkipped := nil;
  LOverCalls := nil;
  LFormWords := nil;
  LFormClasses := nil;
  try
    for var LU in LM.UsesList do
    begin
      if (LU.UnitId < 0) or (LU.NameNode = NIL_NODE) then
        Continue;
      LKey := PasFoldName(LU.NameFull);
      if LByName.ContainsKey(LKey) then
        Continue;   // listed twice (E2004): one entry
      LEntry := Default(TLintEntry);
      LEntry.Name := LU.NameFull;
      LEntry.NameNode := LU.NameNode;
      LEntry.UnitId := LU.UnitId;
      LEntry.Sym := LU.Sym;
      LEntry.InInterface := LM.Tree.Nodes[LU.NameNode].FirstToken < LImplTok;
      LE := LEntries.Add(LEntry);
      LByName.Add(LKey, LE);
      LByUnit.AddOrSetValue(LU.UnitId, LE);
      if LU.Sym <> NIL_SYM then
        LBySym.AddOrSetValue(LU.Sym, LE);
    end;
    if LEntries.Count = 0 then
      Exit;

    // What the unit binds to each entry. An interface name needs an
    // interface entry; the implementation sees both.
    for var LPair in LM.ExtRefMap do
    begin
      if not NeedsItsUnit(LPair.Value) then
        Continue;
      LInIface := LM.Tree.Nodes[LPair.Key].FirstToken < LImplTok;
      if LByUnit.TryGetValue(LPair.Value.UnitId, LE) and
         (LEntries[LE].InInterface or not LInIface) then
        MarkUse(LE)
      else if (LPair.Value.UnitId <> AMid) and not MatchText(FProj.Model(
        LPair.Value.UnitId).UnitNameLower, ['system', 'sysinit']) then
        LOrphans.Add(LPair);
    end;
    // A name bound to a unit not in `uses` came through one that is: an
    // alias of it there, which the index binds through to what it names; or
    // a name of the interface bound to a unit of the implementation `uses`.
    // Every listed unit declaring the name is credited.
    for var LPair in LOrphans do
    begin
      LName := FProj.Model(LPair.Value.UnitId).Symbols[
        LPair.Value.Sym].NameLower;
      LInIface := LM.Tree.Nodes[LPair.Key].FirstToken < LImplTok;
      for LE := 0 to LEntries.Count - 1 do
        if not LEntries[LE].Used and
           (LEntries[LE].InInterface or not LInIface) and
           NamesOf(LEntries[LE].UnitId).ContainsKey(LName) then
          MarkUse(LE);
    end;
    // `Unit.Name`: the qualifier binds to the uses entry itself.
    if LBySym.Count > 0 then
      for LNode := 0 to High(LM.RefMap) do
      begin
        LSym := LM.RefMap[LNode];
        if (LSym <> NIL_SYM) and LBySym.TryGetValue(LSym, LE) and
           not LEntries[LE].Used and not InUsesClause(LM, LNode) then
          MarkUse(LE);
      end;
    // The unit's form file naming a declaration of a listed unit - a
    // component class, a link to another module's component (`PopupMenu =
    // dmData.pmMain`) - uses it: the designer keeps such a unit in `uses`,
    // and a class a form streams must be linked in.
    LFile := FProj.ModelFile(AMid);
    for var LExt in ['.dfm', '.fmx'] do
      if (LFormWords = nil) and FileExists(ChangeFileExt(LFile, LExt)) then
      begin
        LDoc := PasDfmLoad(ChangeFileExt(LFile, LExt));
        if (LDoc = nil) or (LDoc.Doc.Error <> '') then
          Continue;
        LFormFile := ChangeFileExt(LFile, LExt);
        LFormWords := TDictionary<string, Integer>.Create;
        for var LI := 0 to High(LDoc.Doc.Idents) do
        begin
          if LDoc.Doc.Idents[LI].Role = dirClassName then
            LFormClasses := LFormClasses + [PasFoldName(LDoc.Doc.IdentText(LI))];
          if (LDoc.Doc.Idents[LI].Role = dirClassName) or
             ((LDoc.Doc.Idents[LI].Role = dirValue) and
             (LDoc.Doc.Idents[LI].Seg = 0) and
             (LDoc.Doc.Idents[LI].SegCount > 1)) then
            LFormWords.TryAdd(PasFoldName(LDoc.Doc.IdentText(LI)),
              LDoc.Doc.LineOf(LDoc.Doc.Idents[LI].Offset));
        end;
      end;
    if LFormWords <> nil then
      for LE := 0 to LEntries.Count - 1 do
        if not LEntries[LE].Used then
        begin
          LNames := NamesOf(LEntries[LE].UnitId);
          for var LW in LFormWords do
            if LNames.ContainsKey(LW.Key) then
            begin
              MarkUse(LE);
              Break;
            end;
        end;
    // What the IDE's designer puts back into `uses` on the next save - see
    // DesignerUnits.
    if LFormClasses <> nil then
    begin
      LDesign := DesignerUnits(AMid, LFormFile, LFormClasses);
      try
        for LE := 0 to LEntries.Count - 1 do
          if not LEntries[LE].Used and
             LDesign.ContainsKey(LEntries[LE].UnitId) then
            MarkUse(LE);
      finally
        LDesign.Free;
      end;
    end;
    // A unit the expansion of an inline routine called here needs - read or
    // written through a property too. Asked only while an entry is left: a
    // body's pairing hydrates the model declaring it.
    LInline := nil;
    LInlineLight := nil;
    for LEntry in LEntries do
      if not LEntry.Used then
      begin
        LInline := TDictionary<Integer, Boolean>.Create;
        Break;
      end;
    if LInline <> nil then
    begin
      for var LPair in LM.ExtRefMap do
      begin
        LExtM := FProj.Model(LPair.Value.UnitId);
        if (LPair.Value.Sym < 0) or (LPair.Value.Sym >= LExtM.SymCount) then
          Continue;
        LKeys := nil;
        case LExtM.Symbols[LPair.Value.Sym].Kind of
          skRoutine:
            if sfInline in LExtM.Symbols[LPair.Value.Sym].Flags then
              LKeys := [(Int64(LPair.Value.UnitId) shl 32) or
                Cardinal(LPair.Value.Sym)];
          skProperty:
            LKeys := InlineAccessors(LPair.Value.UnitId, LPair.Value.Sym);
        end;
        for var LK in LKeys do
        begin
          for var LU in InlineDeps(LK shr 32, Integer(LK and $FFFFFFFF)) do
            LInline.AddOrSetValue(LU, True);
          for var LU in InlineLightOf(LK) do
            if not MatchText(UnitNameOf(LU), LInlineLight) then
              LInlineLight := LInlineLight + [UnitNameOf(LU)];
        end;
      end;
      for LE := 0 to LEntries.Count - 1 do
        if not LEntries[LE].Used and LInline.ContainsKey(LEntries[LE].UnitId)
        then
          MarkUse(LE);
    end;

    // What may make a removal wrong.
    for LE := 0 to LEntries.Count - 1 do
    begin
      if LEntries[LE].Used then
        Continue;
      LEntry := LEntries[LE];
      LNames := NamesOf(LEntry.UnitId);
      if LUnbound = nil then
        LUnbound := UnboundWords(LM);
      if LSkipped = nil then
        LSkipped := SkippedWordPlaces(LM);
      // A name bound to nothing here that the unit declares.
      for var LW in LUnbound do
        if LNames.ContainsKey(LW.Key) then
        begin
          NodePlace(LM, LW.Value, LText, LLine);
          AddDoubt(LE, Format('`%s` at %s:%d is bound to nothing and %s ' +
            'declares it', [LM.Tree.NodeText(LW.Value),
            ExtractFileName(LText), LLine, LEntry.Name]));
        end;
      // A branch not compiled here naming the unit or a name of it.
      LName := PasFoldName(LEntry.Name);
      if LName.Contains('.') then
        LName := Copy(LName, LName.LastIndexOf('.') + 2, MaxInt);
      for var LW in LSkipped do
        if LNames.ContainsKey(LW.Key) or (LW.Key = LName) then
          AddDoubt(LE, Format('a branch not compiled here names `%s` at ' +
            '%s:%d', [LW.Key, ExtractFileName(LW.Value.FilePath),
            LW.Value.Line]));
      // A routine of another unit called here that this unit declares too:
      // dcc picks among the overloads of every unit in scope, and PasTree's
      // pick may not be its.
      if LOverCalls = nil then
      begin
        LOverCalls := TDictionary<string, Integer>.Create;
        for var LPair in LM.ExtRefMap do
          if NeedsItsUnit(LPair.Value) and (FProj.Model(
            LPair.Value.UnitId).Symbols[LPair.Value.Sym].Kind = skRoutine) then
            LOverCalls.TryAdd(FProj.Model(LPair.Value.UnitId).Symbols[
              LPair.Value.Sym].NameLower, LPair.Key);
      end;
      for var LW in LOverCalls do
        if LNames.TryGetValue(LW.Key, LSym) and
           (FProj.Model(LEntry.UnitId).Symbols[LSym].Kind = skRoutine) then
        begin
          NodePlace(LM, LW.Value, LText, LLine);
          AddDoubt(LE, Format('it declares an overload of `%s`, called at ' +
            '%s:%d - removed, the call may take another overload',
            [LM.Tree.NodeText(LW.Value), ExtractFileName(LText), LLine]));
        end;
      // An inline routine of a light unit called here: what its expansion
      // needs is not known, so any entry may be what it needs - the safe
      // side; LintPromotions names the units whose promotion settles it.
      if LInlineLight <> nil then
        AddDoubt(LE, Format('the expansion of an inline routine of %s ' +
          'called here is not known (analyzed interface-only) - it may ' +
          'need this unit', [NamedList(LInlineLight, MAX_NAMED)]));
      if not AEdges then
      begin
        LText := DropsText(AMid, LEntry.UnitId, LName);
        if LText <> '' then
          AddDoubt(LE, LText);
        if LName <> '' then
          AddDoubt(LE, LName);
      end;
    end;

    if AEdges then
    begin
      for LEntry in LEntries do
        // A unit with a global initialization stays reached: the program
        // keeps it for what it registers, and so keeps what it lists.
        if not LEntry.Used and (LEntry.Doubts = nil) and
           not ((loHideGlobalInit in FOptions) and
           GlobalInit(LEntry.UnitId)) then
          FDeadEdges.AddOrSetValue((Int64(AMid) shl 32) or
            Cardinal(LEntry.UnitId), True);
      Exit;
    end;
    for LEntry in LEntries do
    begin
      if LEntry.Used or not EntryHit(LM, LEntry.NameNode, LRow.Hit) then
        Continue;
      // The entry's own unit whether or not the program still reaches it
      // another way: it is in this `uses` for what it registers.
      if (loHideGlobalInit in FOptions) and
         (GlobalInit(LEntry.UnitId) or
         DropsGlobalInit(AMid, LEntry.UnitId)) then
        Continue;
      LRow.UnitName := LEntry.Name;
      LRow.InInterface := LEntry.InInterface;
      LRow.Doubts := LEntry.Doubts;
      FRows.Add(LRow);
    end;
  finally
    LFormWords.Free;
    LOverCalls.Free;
    LSkipped.Free;
    LUnbound.Free;
    LOrphans.Free;
    LBySym.Free;
    LByUnit.Free;
    LByName.Free;
    LEntries.Free;
  end;
end;

// FindUnreferencedUnits over a lint the caller owns (LintPromotions reads
// what it recorded).
function UnreferencedRows(LLint: TUsesLint; const AMids: TArray<Integer>;
  AOptions: TPasLintOptions): TArray<TPasUnreferencedUnit>;

  // Whether AMid, or a unit only it brings into the program (not live),
  // has a global initialization.
  function BringsGlobalInit(ALint: TUsesLint; AMid: Integer;
    const ALive: TArray<Boolean>): Boolean;
  var
    LSeen: TArray<Boolean>;
    LQueue: TList<Integer>;
    LAt, LU: Integer;
  begin
    Result := False;
    SetLength(LSeen, Length(ALive));
    LQueue := TList<Integer>.Create;
    try
      LSeen[AMid] := True;
      LQueue.Add(AMid);
      LAt := 0;
      while (LAt < LQueue.Count) and not Result do
      begin
        LU := LQueue[LAt];
        Result := ALint.GlobalInit(LU);
        for var LE := ALint.FStart[LU] to ALint.FStart[LU + 1] - 1 do
          if not ALive[ALint.FEdges[LE]] and not LSeen[ALint.FEdges[LE]] then
          begin
            LSeen[ALint.FEdges[LE]] := True;
            LQueue.Add(ALint.FEdges[LE]);
          end;
        Inc(LAt);
      end;
    finally
      LQueue.Free;
    end;
  end;

var
  LLive: TArray<Boolean>;
  LRows: TList<TPasUnreferencedUnit>;
  LRow: TPasUnreferencedUnit;
  LM: TPasSemaModel;
  LMod, LName: Integer;
  LProj: TPasSemaProject;
  LSeeds: TArray<Integer>;
  LQueue: TList<Integer>;
  LAt, LU: Integer;
begin
  LProj := LLint.FProj;
  LRows := TList<TPasUnreferencedUnit>.Create;
  try
    LLint.FOptions := AOptions;
    for var LRoot in LLint.FRoots do
      LLint.CheckUnit(LRoot, True);
    for var LMid in AMids do
      if (LMid >= 0) and (LMid < LProj.ModelCount) then
        LLint.CheckUnit(LMid, True);
    LLive := LLint.LiveUnits;
    // A unit kept for its global initialization - its own, or one only it
    // brings in - is not reported, and it keeps what it really uses: the
    // seeds first (against the live set as computed), then their reach over
    // the edges that are not dead.
    if loHideGlobalInit in AOptions then
    begin
      LSeeds := nil;
      for var LMid in AMids do
        if (LMid >= 0) and (LMid < LProj.ModelCount) and not LLive[LMid] and
           BringsGlobalInit(LLint, LMid, LLive) then
          LSeeds := LSeeds + [LMid];
      LQueue := TList<Integer>.Create;
      try
        for var LMid in LSeeds do
        begin
          LLive[LMid] := True;
          LQueue.Add(LMid);
        end;
        LAt := 0;
        while LAt < LQueue.Count do
        begin
          LU := LQueue[LAt];
          for var LE := LLint.FStart[LU] to LLint.FStart[LU + 1] - 1 do
            if not LLive[LLint.FEdges[LE]] and
               not LLint.FDeadEdges.ContainsKey((Int64(LU) shl 32) or
               Cardinal(LLint.FEdges[LE])) then
            begin
              LLive[LLint.FEdges[LE]] := True;
              LQueue.Add(LLint.FEdges[LE]);
            end;
          Inc(LAt);
        end;
      finally
        LQueue.Free;
      end;
    end;
    for var LMid in AMids do
    begin
      if (LMid < 0) or (LMid >= LProj.ModelCount) or LLive[LMid] or
         not LProj.EnsureHydrated(LMid) then
        Continue;
      LM := LProj.Model(LMid);
      LMod := ModuleNode(LM);
      if (LMod = NIL_NODE) or (LM.Tree.Nodes[LMod].Kind <> nkUnit) then
        Continue;
      LName := LM.Tree.Nodes[LMod].FirstChild;
      LRow := Default(TPasUnreferencedUnit);
      if (LName = NIL_NODE) or not EntryHit(LM, LName, LRow.Hit) then
        Continue;
      LRow.UnitName := LLint.UnitNameOf(LMid);
      // One row per listing file, named with its extension: a program's
      // `.dpr` and a unit's `.pas` are told apart at a glance.
      for var LFrom := 0 to LProj.ModelCount - 1 do
        for var LE := LLint.FStart[LFrom] to LLint.FStart[LFrom + 1] - 1 do
          if (LLint.FEdges[LE] = LMid) and (LFrom <> LMid) then
          begin
            if LLint.FDeadEdges.ContainsKey((Int64(LFrom) shl 32) or
              Cardinal(LMid)) then
              LRow.ListedBy := LRow.ListedBy + [ExtractFileName(
                LProj.ModelFile(LFrom)) + ' (no name of it used)']
            else
              LRow.ListedBy := LRow.ListedBy + [ExtractFileName(
                LProj.ModelFile(LFrom)) + ' (itself unreferenced)'];
            Break;   // listed twice (E2004): one row
          end;
      TArray.Sort<string>(LRow.ListedBy, TIStringComparer.Ordinal);
      if LLint.IsLight(LMid) then
      begin
        LLint.FLightNeeded.AddOrSetValue(LMid, True);
        LRow.Doubts := ['it is analyzed interface-only - whether it has ' +
          'initialization, finalization or a resource a unit can be listed ' +
          'for is not known'];
      end
      else if LLint.LinkEffect(LMid) <> '' then
        LRow.Doubts := [Format('it has %s - a unit can be listed only for ' +
          'what that registers', [LLint.LinkEffect(LMid)])];
      LRows.Add(LRow);
    end;
    Result := LRows.ToArray;
  finally
    LRows.Free;
  end;
  TArray.Sort<TPasUnreferencedUnit>(Result,
    TComparer<TPasUnreferencedUnit>.Construct(
    function(const A, B: TPasUnreferencedUnit): Integer
    begin
      Result := CompareText(A.UnitName, B.UnitName);
      if Result = 0 then
        Result := CompareText(A.Hit.FilePath, B.Hit.FilePath);
    end));
end;

function FindUnreferencedUnits(ANav: TPasNavigator;
  const AMids: TArray<Integer>;
  AOptions: TPasLintOptions): TArray<TPasUnreferencedUnit>;
var
  LLint: TUsesLint;
begin
  LLint := TUsesLint.Create(ANav);
  try
    Result := UnreferencedRows(LLint, AMids, AOptions);
    ANav.NotSearched := LLint.FLightNeeded.Count + LLint.FLoadNeeded.Count;
  finally
    LLint.Free;
  end;
end;

// LintPromotions, and the not-loaded imports to take in light (ALoad,
// KeptPastLoaded's frontier), sorted.
function LintNeeds(ANav: TPasNavigator; const AMids: TArray<Integer>;
  AOptions: TPasLintOptions; out ALoad: TArray<string>): TArray<string>;
var
  LRowsLint, LUnrefLint: TUsesLint;
  LNeeded: TDictionary<Integer, Boolean>;
  LLoad: TDictionary<string, string>;
begin
  Result := nil;
  ALoad := nil;
  LLoad := TDictionary<string, string>.Create;
  LNeeded := TDictionary<Integer, Boolean>.Create;
  LRowsLint := TUsesLint.Create(ANav);
  LUnrefLint := TUsesLint.Create(ANav);
  try
    // Both reports, run as a host runs them; every light unit an answer had
    // to treat as unknown is recorded on the way.
    LRowsLint.FOptions := AOptions;
    for var LMid in AMids do
      if (LMid >= 0) and (LMid < ANav.Project.ModelCount) then
        LRowsLint.CheckUnit(LMid);
    LUnrefLint.FOptions := AOptions;
    UnreferencedRows(LUnrefLint, AMids, AOptions);
    for var LMid in LRowsLint.FLightNeeded.Keys do
      LNeeded.AddOrSetValue(LMid, True);
    for var LMid in LUnrefLint.FLightNeeded.Keys do
      LNeeded.AddOrSetValue(LMid, True);
    for var LMid in LNeeded.Keys do
      Result := Result + [ANav.Project.ModelFile(LMid)];
    for var LPath in LRowsLint.FLoadNeeded.Keys do
      LLoad.AddOrSetValue(LowerCase(LPath), LPath);
    for var LPath in LUnrefLint.FLoadNeeded.Keys do
      LLoad.AddOrSetValue(LowerCase(LPath), LPath);
    ALoad := LLoad.Values.ToArray;
  finally
    LUnrefLint.Free;
    LRowsLint.Free;
    LNeeded.Free;
    LLoad.Free;
  end;
  TArray.Sort<string>(Result, TIStringComparer.Ordinal);
  TArray.Sort<string>(ALoad, TIStringComparer.Ordinal);
end;

function LintPromotions(ANav: TPasNavigator; const AMids: TArray<Integer>;
  AOptions: TPasLintOptions): TArray<string>;
var
  LLoad: TArray<string>;
begin
  Result := LintNeeds(ANav, AMids, AOptions, LLoad);
end;

function DemandLint(ANav: TPasNavigator; const AMids: TArray<Integer>;
  AOptions: TPasLintOptions): TPasDemand;
var
  LLoad: TArray<string>;
begin
  if ANav.Project.LightCount = 0 then
    Exit(Default(TPasDemand));
  Result := ANav.Project.DemandOfFiles(LintNeeds(ANav, AMids, AOptions,
    LLoad));
  Result.LoadOnly := LLoad;
  Inc(Result.NotSearched, Length(LLoad));
end;

function FindUnusedUses(ANav: TPasNavigator;
  const AMids: TArray<Integer>;
  AOptions: TPasLintOptions): TArray<TPasUnusedUse>;
var
  LLint: TUsesLint;
begin
  LLint := TUsesLint.Create(ANav);
  try
    LLint.FOptions := AOptions;
    for var LMid in AMids do
      if (LMid >= 0) and (LMid < ANav.Project.ModelCount) then
        LLint.CheckUnit(LMid);
    Result := LLint.FRows.ToArray;
    ANav.NotSearched := LLint.FLightNeeded.Count + LLint.FLoadNeeded.Count;
  finally
    LLint.Free;
  end;
  TArray.Sort<TPasUnusedUse>(Result, TComparer<TPasUnusedUse>.Construct(
    function(const A, B: TPasUnusedUse): Integer
    begin
      // By the listing file's name (a host groups by file, so one file's
      // rows stay together: the path breaks a tie of names), then by the
      // unused unit's name.
      Result := CompareText(ExtractFileName(A.Hit.FilePath),
        ExtractFileName(B.Hit.FilePath));
      if Result = 0 then
        Result := CompareText(A.Hit.FilePath, B.Hit.FilePath);
      if Result = 0 then
        Result := CompareText(A.UnitName, B.UnitName);
      if Result = 0 then
        Result := A.Hit.Line - B.Hit.Line;
      if Result = 0 then
        Result := A.Hit.Col - B.Hit.Col;
    end));
end;

{ ---- unused declarations ---- }

type
  TUnusedLint = class
  private
    FNav: TPasNavigator;
    FProj: TPasSemaProject;
    FCands: TList<TPasUnusedSymbol>;
    FUsed: TDictionary<Int64, Boolean>;
    FCount: TDictionary<Int64, Integer>;  // a candidate -> its bindings
    FDeclAt: TObjectDictionary<Integer, TDictionary<Integer, Integer>>;
    FCandNames: TDictionary<string, Boolean>;  // the candidates' names
    FUnbound: TDictionary<string, string>;     // such a name bound to nothing
    FUnused: TDictionary<Int64, Boolean>;      // the rows, once known
    FIfaceNames: TDictionary<string, Boolean>;  // every interface's members
    FClassIface: TObjectDictionary<Int64, TDictionary<string, Boolean>>;
    FSkips: TPasUnusedSkips;
    class function K(AMid, ASym: Integer): Int64; static; inline;
    function VisPos(LM: TPasSemaModel; AVis: Integer; out AFileId, ALine,
      ACol: Integer): Boolean;
    function HasDirective(LM: TPasSemaModel; ARoutine: Integer;
      const AWord: string): Boolean;
    function DescendsFrom(AClass: TSemaXType; const ANameLower: string):
      Boolean;
    function Streams(AClass: TSemaXType): Boolean;
    function IsStructType(const AX: TSemaXType; AKind: TPasNodeKind): Boolean;
    function ListedInterfaces(const AClass: TSemaXType): TArray<TSemaXType>;
    function InterfaceNamesOf(const AClass: TSemaXType): TDictionary<string,
      Boolean>;
    function QualifiedName(LM: TPasSemaModel; ASym: Integer): string;
    function Generated(LM: TPasSemaModel; const AFile: string): Boolean;
    procedure CollectIfaceNames;
    procedure Collect(AMid: Integer);
    function DeclaredAt(AMid, ANode: Integer; out ASym: Integer): Boolean;
    procedure MarkBound(AMid: Integer);
    procedure Search;
    function UsedOverload(AMid, ASym: Integer): Boolean;
    procedure AddDoubts;
  public
    constructor Create(ANav: TPasNavigator);
    destructor Destroy; override;
  end;

constructor TUnusedLint.Create(ANav: TPasNavigator);
begin
  inherited Create;
  FNav := ANav;
  FProj := ANav.Project;
  FCands := TList<TPasUnusedSymbol>.Create;
  FUsed := TDictionary<Int64, Boolean>.Create;
  FCount := TDictionary<Int64, Integer>.Create;
  FCandNames := TDictionary<string, Boolean>.Create;
  FUnbound := TDictionary<string, string>.Create;
  FUnused := TDictionary<Int64, Boolean>.Create;
  FDeclAt := TObjectDictionary<Integer, TDictionary<Integer, Integer>>.Create(
    [doOwnsValues]);
  FIfaceNames := TDictionary<string, Boolean>.Create;
  FClassIface := TObjectDictionary<Int64, TDictionary<string, Boolean>>.Create(
    [doOwnsValues]);
  FillChar(FSkips, SizeOf(FSkips), 0);
end;

destructor TUnusedLint.Destroy;
begin
  FClassIface.Free;
  FUnused.Free;
  FUnbound.Free;
  FCandNames.Free;
  FDeclAt.Free;
  FCount.Free;
  FIfaceNames.Free;
  FUsed.Free;
  FCands.Free;
  inherited;
end;

class function TUnusedLint.K(AMid, ASym: Integer): Int64;
begin
  Result := (Int64(AMid) shl 32) or Cardinal(ASym);
end;

function TUnusedLint.VisPos(LM: TPasSemaModel; AVis: Integer; out AFileId,
  ALine, ACol: Integer): Boolean;
var
  LTok: Integer;
begin
  Result := False;
  if (AVis < 0) or (AVis > High(LM.Tree.Source.Visible)) then
    Exit;
  AFileId := LM.Tree.Source.Visible[AVis].FileId;
  LTok := LM.Tree.Source.Visible[AVis].TokenIndex;
  if (AFileId < 0) or (AFileId > High(LM.Tree.Source.Files)) or (LTok < 0) or
     (LTok > High(LM.Tree.Source.Files[AFileId].Tokens)) then
    Exit;
  LM.Tree.Source.Files[AFileId].OffsetToLineCol(
    LM.Tree.Source.Files[AFileId].Tokens[LTok].Start, ALine, ACol);
  Result := True;
end;

function TUnusedLint.HasDirective(LM: TPasSemaModel; ARoutine: Integer;
  const AWord: string): Boolean;
var
  LChild: Integer;
begin
  LChild := LM.Tree.Nodes[ARoutine].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if (LM.Tree.Nodes[LChild].Kind = nkDirective) and
       SameText(LM.Tree.NodeText(LChild), AWord) then
      Exit(True);
    LChild := LM.Tree.Nodes[LChild].NextSibling;
  end;
  Result := False;
end;

// Is AClass, or an ancestor, the class named ANameLower?
function TUnusedLint.DescendsFrom(AClass: TSemaXType;
  const ANameLower: string): Boolean;
begin
  for var LDepth := 1 to 64 do
  begin
    if not XValid(AClass) then
      Break;
    if FProj.Model(AClass.UnitId).Symbols[AClass.Sym].NameLower =
       ANameLower then
      Exit(True);
    AClass := FProj.CanonTypeX(FProj.AncestorOfX(AClass));
  end;
  Result := False;
end;

// A TPersistent descendant: compiled {$M+}, its unnamed first section is
// published - a form's components and handlers.
function TUnusedLint.Streams(AClass: TSemaXType): Boolean;
begin
  Result := DescendsFrom(AClass, 'tpersistent');
end;

// The class or interface node type symbol AX declares, if of AKind.
function TUnusedLint.IsStructType(const AX: TSemaXType;
  AKind: TPasNodeKind): Boolean;
var
  LM: TPasSemaModel;
  LDecl, LChild: Integer;
begin
  Result := False;
  if not XValid(AX) then
    Exit;
  LM := FProj.Model(AX.UnitId);
  LDecl := LM.Symbols[AX.Sym].DeclNode;
  if LDecl = NIL_NODE then
    Exit;
  LDecl := LM.Tree.DeclRootOf(LDecl);
  if (LDecl = NIL_NODE) or (LM.Tree.Nodes[LDecl].Kind <> nkTypeDecl) then
    Exit;
  LChild := LM.Tree.Nodes[LDecl].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if LM.Tree.Nodes[LChild].Kind = AKind then
      Exit(True);
    LChild := LM.Tree.Nodes[LChild].NextSibling;
  end;
end;

// The interfaces a class's heritage list names, and those they extend.
function TUnusedLint.ListedInterfaces(
  const AClass: TSemaXType): TArray<TSemaXType>;
var
  LX: TSemaXType;
  LM: TPasSemaModel;
  LDecl, LDef, LChild: Integer;
  LList: TList<TSemaXType>;
  LInList: Boolean;
begin
  Result := nil;
  if not XValid(AClass) then
    Exit;
  LM := FProj.Model(AClass.UnitId);
  LDecl := LM.Symbols[AClass.Sym].DeclNode;
  if LDecl = NIL_NODE then
    Exit;
  LDecl := LM.Tree.DeclRootOf(LDecl);
  if (LDecl = NIL_NODE) or (LM.Tree.Nodes[LDecl].Kind <> nkTypeDecl) then
    Exit;
  LDef := LM.Tree.Nodes[LDecl].FirstChild;
  while (LDef <> NIL_NODE) and (LM.Tree.Nodes[LDef].Kind <> nkClassType) do
    LDef := LM.Tree.Nodes[LDef].NextSibling;
  if LDef = NIL_NODE then
    Exit;
  LList := TList<TSemaXType>.Create;
  try
    LInList := False;
    LChild := LM.Tree.Nodes[LDef].FirstChild;
    while LChild <> NIL_NODE do
    begin
      if LM.Tree.Nodes[LChild].Kind in [nkIdent, nkMember, nkTypeArgs] then
      begin
        LInList := True;
        LX := FProj.CanonTypeX(FProj.ResolveTypeExpr(AClass.UnitId, LChild));
        // `class(TInterfacedObject, TFunc<T>)`: a method reference type is
        // an interface whose one method is Invoke.
        if IsStructType(LX, nkProcType) then
        begin
          if not LList.Contains(LX) then
            LList.Add(LX);
        end
        else
          for var LUp := 1 to 64 do
          begin
            if not IsStructType(LX, nkInterfaceType) or LList.Contains(LX) then
              Break;
            LList.Add(LX);
            LX := FProj.CanonTypeX(FProj.AncestorOfX(LX));
          end;
      end
      else if LInList then
        Break;   // the heritage list is over: members follow
      LChild := LM.Tree.Nodes[LChild].NextSibling;
    end;
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

// The method names a call through an interface may run on AClass: every
// interface the class, an ancestor or a descendant lists names. Per class.
function TUnusedLint.InterfaceNamesOf(
  const AClass: TSemaXType): TDictionary<string, Boolean>;
var
  LK: TSemaXType;
  LClasses: TList<TSemaXType>;
  LIM: TPasSemaModel;
  LScope: Integer;
begin
  if FClassIface.TryGetValue(K(AClass.UnitId, AClass.Sym), Result) then
    Exit;
  Result := TDictionary<string, Boolean>.Create;
  FClassIface.Add(K(AClass.UnitId, AClass.Sym), Result);
  LClasses := TList<TSemaXType>.Create;
  try
    LK := AClass;
    for var LDepth := 1 to 64 do
    begin
      if not IsStructType(LK, nkClassType) then
        Break;
      LClasses.Add(LK);
      LK := FProj.CanonTypeX(FProj.AncestorOfX(LK));
    end;
    for var LD in FNav.FindDescendants(AClass.UnitId, AClass.Sym) do
      if LD.Kind = pdkDescendant then
        LClasses.Add(XPlain(LD.UnitId, LD.Sym));
    for var LC in LClasses do
      for var LI in ListedInterfaces(LC) do
      begin
        if IsStructType(LI, nkProcType) then
        begin
          Result.AddOrSetValue('invoke', True);
          Continue;
        end;
        if not FProj.EnsureHydrated(LI.UnitId) then
          Continue;
        LIM := FProj.Model(LI.UnitId);
        LScope := LIM.Symbols[LI.Sym].MemberScope;
        if (LScope <> NIL_SCOPE) and (LScope < LIM.Scopes.Count) then
          for var LIdx := 0 to LIM.Scopes[LScope].Symbols.Count - 1 do
            Result.AddOrSetValue(LIM.Symbols[LIM.Scopes[LScope].Symbols[LIdx]].
              NameLower, True);
      end;
  finally
    LClasses.Free;
  end;
end;

// The name with the types it is declared in: TOuter.TInner.Member.
function TUnusedLint.QualifiedName(LM: TPasSemaModel; ASym: Integer): string;
var
  LScope, LOwner: Integer;
begin
  Result := LM.Symbols[ASym].Name;
  LScope := LM.Symbols[ASym].Scope;
  for var LDepth := 1 to 16 do
  begin
    if (LScope = NIL_SCOPE) or (LScope >= LM.Scopes.Count) or
       (LM.Scopes[LScope].Kind <> sckStruct) then
      Break;
    LOwner := LM.Scopes[LScope].StructSym;
    if LOwner = NIL_SYM then
      Break;
    Result := LM.Symbols[LOwner].Name + '.' + Result;
    LScope := LM.Symbols[LOwner].Scope;
  end;
end;

// A unit a tool writes: a type library import (`_TLB`), an XML data
// binding, the IDE's import header - its declarations are the tool's.
function TUnusedLint.Generated(LM: TPasSemaModel; const AFile: string): Boolean;
var
  LText: string;
begin
  Result := TPath.GetFileNameWithoutExtension(AFile).EndsWith('_TLB', True);
  if not Result and (Length(LM.Tree.Source.Files) > 0) then
    for var LLine := 1 to Min(40, Length(LM.Tree.Source.Files[0].LineStarts)) do
    begin
      LText := LowerCase(LM.Tree.Source.Files[0].LineText(LLine));
      if (Pos('were generated from data read from', LText) > 0) or
         (Pos('xml data binding', LText) > 0) or
         (Pos('this unit was generated', LText) > 0) then
        Exit(True);
    end;
end;

// The method names of every interface the analysis declares: a cheap no
// before InterfaceNamesOf's walk of a class's hierarchy.
procedure TUnusedLint.CollectIfaceNames;
var
  LM: TPasSemaModel;
  LScope: Integer;
begin
  // A method reference type's one method (ListedInterfaces).
  FIfaceNames.AddOrSetValue('invoke', True);
  for var LMid := 0 to FProj.ModelCount - 1 do
  begin
    LM := FProj.Model(LMid);
    for var LSym := 0 to LM.SymCount - 1 do
    begin
      if (LM.Symbols[LSym].Kind <> skType) or
         (LM.Symbols[LSym].TypeCat <> tcInterface) then
        Continue;
      LScope := LM.Symbols[LSym].MemberScope;
      if (LScope <> NIL_SCOPE) and (LScope < LM.Scopes.Count) then
        for var LIdx := 0 to LM.Scopes[LScope].Symbols.Count - 1 do
          FIfaceNames.AddOrSetValue(LM.Symbols[LM.Scopes[LScope].Symbols[LIdx]].
            NameLower, True);
    end;
  end;
end;

// The declarations of unit AMid weighed - those not reached another way.
procedure TUnusedLint.Collect(AMid: Integer);
var
  LM: TPasSemaModel;
  LS: TSemaSymbol;
  LKind: TSemaScopeKind;
  LOwner, LNode, LFi, LLine, LCol, LTFi, LTLine, LTCol: Integer;
  LC: TPasUnusedSymbol;
  LSkip: Boolean;

  procedure Skip(AWhy: TPasUnusedSkip);
  begin
    Inc(FSkips[AWhy]);
    LSkip := True;
  end;

begin
  if not FProj.EnsureHydrated(AMid) then
    Exit;
  LM := FProj.Model(AMid);
  if Generated(LM, FProj.ModelFile(AMid)) then
  begin
    Inc(FSkips[usGenerated]);
    Exit;
  end;
  for var LSym := 0 to LM.SymCount - 1 do
  begin
    LS := LM.Symbols[LSym];
    if (LS.DeclNode = NIL_NODE) or
       (LS.Flags * [sfBuiltin, sfCompletesForward] <> []) or
       not (LS.Kind in [skType, skVar, skConst, skField, skRoutine,
         skProperty]) or (LS.Scope < 0) or (LS.Scope >= LM.Scopes.Count) then
      Continue;
    LKind := LM.Scopes[LS.Scope].Kind;
    // A routine's locals are dcc's hints; its nested routines are not.
    if not ((LKind in [sckUnit, sckImplementation, sckStruct]) or
       ((LKind = sckRoutine) and (LS.Kind = skRoutine))) then
      Continue;
    if not VisPos(LM, LM.Tree.NodeLeftmostVis(LS.DeclNode), LFi, LLine,
       LCol) then
      Continue;
    LSkip := False;
    LC := Default(TPasUnusedSymbol);
    LOwner := NIL_SYM;
    if LKind = sckStruct then
      LOwner := LM.Scopes[LS.Scope].StructSym;
    if LOwner <> NIL_SYM then
    begin
      if LM.Symbols[LOwner].TypeCat = tcInterface then
        Skip(usInterface)
      else if LS.Visibility in [svPublished, svAutomated] then
        Skip(usPublished)
      else if (LS.Visibility = svDefault) and
        (LM.Symbols[LOwner].TypeCat = tcClass) and
        Streams(XPlain(AMid, LOwner)) then
        Skip(usPublished);
      LC.RecordField := (LS.Kind = skField) and
        (LM.Symbols[LOwner].TypeCat = tcRecord);
    end;
    if not LSkip and (LS.Kind = skRoutine) then
    begin
      LNode := LS.DeclNode;
      while (LNode <> NIL_NODE) and (LM.Tree.Nodes[LNode].Kind <> nkRoutine) do
        LNode := LM.Tree.Nodes[LNode].Parent;
      if LM.RoutineHead(LSym) = rhOperator then
        Skip(usOperator)
      else if (sfOverrideDirective in LS.Flags) or ((LNode <> NIL_NODE) and
        (HasDirective(LM, LNode, 'virtual') or HasDirective(LM, LNode,
        'dynamic') or HasDirective(LM, LNode, 'override') or
        HasDirective(LM, LNode, 'abstract') or HasDirective(LM, LNode,
        'message'))) then
        Skip(usDispatch)
      else if (LM.RoutineHead(LSym) in [rhConstructor, rhDestructor]) and
        (LNode <> NIL_NODE) and VisPos(LM, LM.Tree.NodeLeftmostVis(LNode),
        LTFi, LTLine, LTCol) and SameText(Copy(LM.Tree.Source.Files[LTFi].
        LineText(LTLine), LTCol, 6), 'class ') then
        Skip(usClassCtor)
      // `[MaxLength(10)]` runs MaxLengthAttribute.Create: an attribute's
      // constructor is called by the attribute, which names the class.
      else if (LM.RoutineHead(LSym) = rhConstructor) and (LOwner <> NIL_SYM)
        and DescendsFrom(XPlain(AMid, LOwner), 'tcustomattribute') then
        Skip(usAttribute)
      else if (LOwner <> NIL_SYM) and FIfaceNames.ContainsKey(LS.NameLower) and
        InterfaceNamesOf(XPlain(AMid, LOwner)).ContainsKey(LS.NameLower) then
        Skip(usImplements);
    end;
    // `for X in L` calls L.GetEnumerator, then the enumerator's MoveNext and
    // Current, none of them by a name in the code.
    if not LSkip and (LOwner <> NIL_SYM) and
       (LS.Kind in [skRoutine, skProperty]) and
       ((LS.NameLower = 'getenumerator') or (LS.NameLower = 'movenext') or
       (LS.NameLower = 'current')) then
      Skip(usForIn);
    if LSkip then
      Continue;
    LC.UnitId := AMid;
    LC.Sym := LSym;
    LC.FileName := LM.Tree.Source.FileNames[LFi];
    LC.Line := LLine;
    LC.Col := LCol;
    LC.Name := QualifiedName(LM, LSym);
    LC.Kind := LS.Kind;
    if LS.Kind = skRoutine then
      LC.Head := LM.RoutineHead(LSym);
    FCands.Add(LC);
    FCount.AddOrSetValue(K(AMid, LSym), 0);
    FCandNames.AddOrSetValue(LS.NameLower, True);
  end;
end;

// The symbol of model AMid whose declaration name is ANode. A table per
// model, built on the first ask: only the models a reference hit lands on a
// declaration of are asked (a property redeclared).
function TUnusedLint.DeclaredAt(AMid, ANode: Integer;
  out ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
  LMap: TDictionary<Integer, Integer>;
begin
  if not FDeclAt.TryGetValue(AMid, LMap) then
  begin
    LMap := TDictionary<Integer, Integer>.Create;
    FDeclAt.Add(AMid, LMap);
    LM := FProj.Model(AMid);
    for var LSym := 0 to LM.SymCount - 1 do
      if LM.Symbols[LSym].DeclNode <> NIL_NODE then
        LMap.AddOrSetValue(LM.Symbols[LSym].DeclNode, LSym);
  end;
  Result := LMap.TryGetValue(ANode, ASym);
end;

// What a bare `inherited;` of model AMid runs is used: it names nothing a
// reference search finds.
procedure TUnusedLint.MarkBound(AMid: Integer);
var
  LM: TPasSemaModel;
  LBMid, LBSym, LCtx, LN: Integer;
begin
  if not FProj.EnsureHydrated(AMid) then
    Exit;
  LM := FProj.Model(AMid);
  for var LI := 0 to High(LM.Tree.Nodes) do
    if (LM.Tree.Nodes[LI].Kind = nkInherited) and
       (LM.Tree.Nodes[LI].FirstChild = NIL_NODE) and
       FProj.BareInheritedTarget(AMid, LI, LBMid, LBSym, LCtx) then
      FUsed.AddOrSetValue(K(LBMid, LBSym), True);
  // The bindings, counted: a declaration bound more often than its own
  // sites could make it (its declaration, implementation header, forward)
  // is used, and Search does not ask for its references.
  for var LI := 0 to High(LM.RefMap) do
    if (LM.RefMap[LI] <> NIL_SYM) and FCount.TryGetValue(K(AMid,
       LM.RefMap[LI]), LN) then
      FCount[K(AMid, LM.RefMap[LI])] := LN + 1;
  for var LP in LM.ExtRefMap do
    if FCount.TryGetValue(K(LP.Value.UnitId, LP.Value.Sym), LN) then
      FCount[K(LP.Value.UnitId, LP.Value.Sym)] := LN + 1;
  // A property redeclared below (`property X;`, a published one too) needs
  // every link above it: removing one breaks the redeclaration (E2003).
  for var LSym := 0 to LM.SymCount - 1 do
  begin
    if LM.Symbols[LSym].Kind <> skProperty then
      Continue;
    LBMid := AMid;
    LBSym := LSym;
    for var LDepth := 1 to 64 do
    begin
      if not FProj.PropertyRedeclPrev(LBMid, LBSym, LN, LCtx) then
        Break;
      LBMid := LN;
      LBSym := LCtx;
      if not FUsed.TryAdd(K(LBMid, LBSym), True) then
        Break;   // the rest of the chain is marked already
    end;
  end;
  // A name the analysis bound to nothing, where a candidate's name is
  // written: what dcc binds there is not known here (a doubt on the row).
  // Keyed by name and qualifier (UnboundKey): `X.Name` with X bound to a
  // known type is that type's member, not a candidate's of another class;
  // with X bound to nothing it is a member of a type named X, or of
  // anything ('*') when X's type is not known; a bare name is ''.
  for var LI := 0 to High(LM.Tree.Nodes) do
  begin
    // A declared name (nfName: a variable's, a parameter's, each segment of
    // `procedure TFoo.Bar`) is no use: the implementation header's TFoo and
    // Bar are bound to nothing.
    if (LM.Tree.Nodes[LI].Kind <> nkIdent) or
       (nfName in LM.Tree.Nodes[LI].Flags) or
       ((LI < Length(LM.RefMap)) and (LM.RefMap[LI] <> NIL_SYM)) or
       LM.ExtRefMap.ContainsKey(LI) then
      Continue;
    var LName := LM.Tree.NodeNameLower(LI);
    if not FCandNames.ContainsKey(LName) or DeclaredAt(AMid, LI, LN) then
      Continue;
    var LQual := '';
    var LP := LM.Tree.Nodes[LI].Parent;
    if (LP <> NIL_NODE) and (LM.Tree.Nodes[LP].Kind = nkMember) and
       (LM.Tree.Nodes[LP].FirstChild <> LI) then
    begin
      var LBase := LM.Tree.Nodes[LP].FirstChild;
      if ((LBase < Length(LM.RefMap)) and (LM.RefMap[LBase] <> NIL_SYM)) or
         LM.ExtRefMap.ContainsKey(LBase) then
      begin
        if XValid(FProj.WithTargetTypeX(AMid, LBase)) then
          Continue;   // a member of a type the index knows: not ours
        LQual := '*';
      end
      else if LM.Tree.Nodes[LBase].Kind = nkIdent then
        LQual := LM.Tree.NodeNameLower(LBase)
      else
        LQual := '*';
    end;
    if FUnbound.ContainsKey(LName + '|' + LQual) then
      Continue;
    var LFi, LLine, LCol: Integer;
    if VisPos(LM, LM.Tree.NodeLeftmostVis(LI), LFi, LLine, LCol) then
      FUnbound.Add(LName + '|' + LQual, Format('%s:%d', [ExtractFileName(
        LM.Tree.Source.FileNames[LFi]), LLine]));
  end;
end;

// The references of every candidate in one pass: a hit marks what it binds
// to, and a property every link up its redeclaration chain (a descendant's
// `property X;` binds to its own link, and removing the ancestor's breaks
// it). A class a form file names is used.
procedure TUnusedLint.Search;
var
  LRefs: TArray<TPasExtRef>;
  LExt: TPasExtRef;
  LHits: TList<TPasRefHit>;
  LIdent: TPasNavIdent;
  LM: TPasSemaModel;
  LByName: TDictionary<string, Boolean>;
  LMid, LNode, LBMid, LBSym, LPMid, LPSym: Integer;
begin
  LRefs := nil;
  for var LC in FCands do
    if FUsed.ContainsKey(K(LC.UnitId, LC.Sym)) then
      Continue
    else if FCount[K(LC.UnitId, LC.Sym)] > 3 then
      FUsed.AddOrSetValue(K(LC.UnitId, LC.Sym), True)
    else
    begin
      LExt.UnitId := LC.UnitId;
      LExt.Sym := LC.Sym;
      LRefs := LRefs + [LExt];
    end;
  LByName := TDictionary<string, Boolean>.Create;
  LHits := TList<TPasRefHit>.Create;
  try
    if LRefs <> nil then
      FNav.CollectReferencesOfAll(LRefs, LHits);
    for var LH in LHits do
    begin
      // A hit that cannot be mapped back to what it binds - in an include
      // file, which no model is named after - marks every candidate of the
      // name it highlights: a use is never lost, a namesake kept at worst.
      LMid := FNav.ModelIdOf(LH.FilePath);
      LNode := NIL_NODE;
      LM := nil;
      if LMid >= 0 then
      begin
        LM := FProj.Model(LMid);
        if LH.Implicit then
          LNode := LH.IndexNode
        else if FNav.IdentAt(LMid, LH.Line, LH.Col, LIdent) then
          LNode := LIdent.Node;
      end;
      if LNode = NIL_NODE then
      begin
        LByName.AddOrSetValue(LowerCase(Copy(LH.Snippet, LH.HiFrom + 1,
          LH.HiTo - LH.HiFrom)), True);
        Continue;
      end;
      if (LNode >= 0) and (LNode < Length(LM.RefMap)) and
         (LM.RefMap[LNode] <> NIL_SYM) then
      begin
        LBMid := LMid;
        LBSym := LM.RefMap[LNode];
      end
      else if LM.ExtRefMap.TryGetValue(LNode, LExt) then
      begin
        LBMid := LExt.UnitId;
        LBSym := LExt.Sym;
      end
      else if DeclaredAt(LMid, LNode, LBSym) then
        // A descendant's `property X;` is a declaration naming the
        // ancestor's: the property it declares, and every link up.
        LBMid := LMid
      else
      begin
        LByName.AddOrSetValue(LowerCase(Copy(LH.Snippet, LH.HiFrom + 1,
          LH.HiTo - LH.HiFrom)), True);
        Continue;
      end;
      FUsed.AddOrSetValue(K(LBMid, LBSym), True);
      for var LDepth := 1 to 64 do
      begin
        if (FProj.Model(LBMid).Symbols[LBSym].Kind <> skProperty) or
           not FProj.PropertyRedeclPrev(LBMid, LBSym, LPMid, LPSym) then
          Break;
        LBMid := LPMid;
        LBSym := LPSym;
        FUsed.AddOrSetValue(K(LBMid, LBSym), True);
      end;
    end;
    for var LC in FCands do
      if LByName.ContainsKey(FProj.Model(LC.UnitId).Symbols[LC.Sym].NameLower)
      then
        FUsed.AddOrSetValue(K(LC.UnitId, LC.Sym), True);
  finally
    LByName.Free;
    LHits.Free;
  end;
  // A class a form file names - a frame placed on a form, a module.
  for var LC in FCands do
    if not FUsed.ContainsKey(K(LC.UnitId, LC.Sym)) and (LC.Kind = skType) and
       (FProj.Model(LC.UnitId).Symbols[LC.Sym].TypeCat = tcClass) and
       (Length(FNav.FindFormSites(LC.UnitId, LC.Sym)) > 0) then
      FUsed.AddOrSetValue(K(LC.UnitId, LC.Sym), True);
end;

// Is another overload of routine (AMid, ASym) - in its scope, by name -
// not a row itself: used, or reached another way (a virtual one)? Asked
// once the rows are known (FUnused).
function TUnusedLint.UsedOverload(AMid, ASym: Integer): Boolean;
var
  LM: TPasSemaModel;
  LS: Integer;
begin
  Result := False;
  LM := FProj.Model(AMid);
  LS := LM.FindLocal(LM.Symbols[ASym].Scope, LM.Symbols[ASym].NameLower);
  while LS <> NIL_SYM do
  begin
    if (LS <> ASym) and (LM.Symbols[LS].Kind = skRoutine) and
       not FUnused.ContainsKey(K(AMid, LS)) then
      Exit(True);
    LS := LM.Symbols[LS].NextOverload;
  end;
end;

// The doubts of the rows left: the name written in a branch not compiled
// or in a string literal of the project's own files, a record's field.
procedure TUnusedLint.AddDoubts;
var
  LOwnerName: string;
  LOwnerSym: Integer;
  LInactive, LStrings, LUnitNames: TDictionary<string, string>;
  LKind: TSemaScopeKind;
  LDone: TDictionary<string, Boolean>;
  LM: TPasSemaModel;
  LTS: TPasTokenStream;
  LText, LFile, LWord, LAt: string;
  LI, LStart, LLine, LCol: Integer;
  LC: TPasUnusedSymbol;

  procedure AddWords(ADict: TDictionary<string, string>; const AText: string;
    AOffset: Integer);
  var
    LJ, LK: Integer;
  begin
    LJ := 1;
    while LJ <= Length(AText) do
    begin
      if (AText[LJ].IsLetter or (AText[LJ] = '_')) and ((LJ = 1) or
         not (AText[LJ - 1].IsLetterOrDigit or (AText[LJ - 1] = '_'))) then
      begin
        LK := LJ;
        while (LK <= Length(AText)) and (AText[LK].IsLetterOrDigit or
          (AText[LK] = '_')) do
          Inc(LK);
        LWord := LowerCase(Copy(AText, LJ, LK - LJ));
        if (Length(LWord) >= 3) and not ADict.ContainsKey(LWord) then
        begin
          LTS.OffsetToLineCol(AOffset + LJ - 1, LLine, LCol);
          ADict.Add(LWord, Format('%s:%d', [ExtractFileName(LFile), LLine]));
        end;
        LJ := LK;
      end
      else
        Inc(LJ);
    end;
  end;

begin
  LInactive := TDictionary<string, string>.Create;
  LStrings := TDictionary<string, string>.Create;
  LUnitNames := TDictionary<string, string>.Create;
  LDone := TDictionary<string, Boolean>.Create;
  try
    for var LMid := 0 to FProj.ModelCount - 1 do
    begin
      if FProj.IsLight(LMid) or FNav.IsUnderLibraryPath(FProj.ModelFile(LMid))
         or not FProj.EnsureHydrated(LMid) then
        Continue;
      LM := FProj.Model(LMid);
      for var LFi := 0 to High(LM.Tree.Source.Files) do
      begin
        LFile := LM.Tree.Source.FileNames[LFi];
        if FNav.IsUnderLibraryPath(LFile) then
          Continue;
        LTS := LM.Tree.Source.Files[LFi];
        if LFi <= High(LM.Tree.Source.Skipped) then
          for var LR in LM.Tree.Source.Skipped[LFi] do
            AddWords(LInactive, Copy(LTS.Source, LR.Start + 1, LR.EndPos -
              LR.Start), LR.Start);
        if not LDone.TryAdd(LowerCase(LFile), True) then
          Continue;
        // String literals, outside comments: one scan of the text.
        LText := LTS.Source;
        LI := 1;
        while LI <= Length(LText) do
        begin
          case LText[LI] of
            '/':
              if (LI < Length(LText)) and (LText[LI + 1] = '/') then
                while (LI <= Length(LText)) and not CharInSet(LText[LI],
                  [#10, #13]) do
                  Inc(LI);
            '{':
              while (LI <= Length(LText)) and (LText[LI] <> '}') do
                Inc(LI);
            '''':
              begin
                LStart := LI + 1;
                Inc(LI);
                while (LI <= Length(LText)) and not CharInSet(LText[LI],
                  ['''', #10, #13]) do
                  Inc(LI);
                // A lookup by name passes the name as the whole literal:
                // FindClass('TFoo'), 'Unit.TFoo', 'TFoo.Bar' - a word
                // inside a message or a query is not one (3,292 rows of
                // 8,598 on a 4,000-unit group had such a doubt). Kept: the
                // literal, and its last segment ('#' + it) for a type.
                LWord := LowerCase(Trim(Copy(LText, LStart, LI - LStart)));
                if IsValidIdent(LWord, True) and (Length(LWord) >= 3) then
                begin
                  LTS.OffsetToLineCol(LStart - 1, LLine, LCol);
                  LAt := Format('%s:%d', [ExtractFileName(LFile), LLine]);
                  LStrings.TryAdd(LWord, LAt);
                  if LWord.Contains('.') then
                    LWord := Copy(LWord, LWord.LastIndexOf('.') + 2, MaxInt);
                  LStrings.TryAdd('#' + LWord, LAt);
                end;
              end;
          end;
          Inc(LI);
        end;
      end;
    end;
    // The names every unit declares in its interface, with a unit declaring
    // each: a row's name declared by another unit is a doubt.
    for var LMid := 0 to FProj.ModelCount - 1 do
    begin
      LM := FProj.Model(LMid);
      for var LSym := 0 to LM.SymCount - 1 do
        if (LM.Symbols[LSym].DeclNode <> NIL_NODE) and
           (LM.Symbols[LSym].Scope >= 0) and
           (LM.Symbols[LSym].Scope < LM.Scopes.Count) and
           (LM.Scopes[LM.Symbols[LSym].Scope].Kind = sckUnit) and
           (LM.Symbols[LSym].Kind in [skType, skVar, skConst, skRoutine]) then
        begin
          LWord := LM.Symbols[LSym].NameLower;
          if not LUnitNames.TryGetValue(LWord, LAt) then
            LUnitNames.Add(LWord,
              TPath.GetFileNameWithoutExtension(FProj.ModelFile(LMid)))
          else if (Length(LAt) < 200) and not ContainsText('|' + LAt + '|',
            '|' + TPath.GetFileNameWithoutExtension(FProj.ModelFile(LMid)) +
            '|') then
            LUnitNames[LWord] := LAt + '|' +
              TPath.GetFileNameWithoutExtension(FProj.ModelFile(LMid));
        end;
    end;
    for var LIdx := 0 to FCands.Count - 1 do
    begin
      LC := FCands[LIdx];
      LWord := LowerCase(FProj.Model(LC.UnitId).Symbols[LC.Sym].Name);
      if LInactive.TryGetValue(LWord, LAt) then
        LC.Doubts := LC.Doubts + [Format('the name is written in a branch '
          + 'this configuration does not compile (%s)', [LAt])];
      // Unbound bare, of a qualifier whose type is not known, or of one
      // named as the row's type (`TFoo.Create`) or unit (`UFoo.Proc`).
      LOwnerName := FProj.Model(LC.UnitId).UnitNameLower;
      LOwnerSym := FProj.Model(LC.UnitId).Symbols[LC.Sym].Scope;
      if (LOwnerSym >= 0) and (FProj.Model(LC.UnitId).Scopes[LOwnerSym].Kind =
         sckStruct) and (FProj.Model(LC.UnitId).Scopes[LOwnerSym].StructSym <>
         NIL_SYM) then
        LOwnerName := FProj.Model(LC.UnitId).Symbols[FProj.Model(LC.UnitId).
          Scopes[LOwnerSym].StructSym].NameLower;
      if FUnbound.TryGetValue(LWord + '|', LAt) or
         FUnbound.TryGetValue(LWord + '|*', LAt) or
         FUnbound.TryGetValue(LWord + '|' + LOwnerName, LAt) then
        LC.Doubts := LC.Doubts + [Format('the name is written where the '
          + 'index bound nothing (%s) - it may be a use of this one', [LAt])];
      // A type looked up by its name (FindClass('TFoo'), 'Unit.TFoo'); a
      // member only by its qualified one ('TFoo.Bar'): a member found by name
      // through RTTI is published, and not weighed.
      if ((LC.Kind = skType) and LStrings.TryGetValue('#' + LWord, LAt)) or
         LStrings.TryGetValue(LOwnerName + '.' + LWord, LAt) then
        LC.Doubts := LC.Doubts + [Format('a string literal spells it (%s) - '
          + 'a lookup by name?', [LAt])];
      if LC.RecordField then
        LC.Doubts := LC.Doubts + ['a record''s field: the record may be read '
          + 'or written whole (a file, a stream, a buffer)'];
      // An overload of a name in use: a call the index bound to a sibling
      // may run this one under dcc's rules (an AnsiString argument, a
      // nested overload - both seen on a 4,000-unit group).
      if (LC.Kind = skRoutine) and UsedOverload(LC.UnitId, LC.Sym) then
        LC.Doubts := LC.Doubts + [Format('another overload of %s is used - a '
          + 'call may run this one where the index chose that one',
          [FProj.Model(LC.UnitId).Symbols[LC.Sym].Name])];
      // Declared at unit level by another unit too: which of them a unit
      // naming it binds is the order of its `uses` (the last listed wins),
      // and a use bound to the other here may be this one's in dcc.
      LKind := FProj.Model(LC.UnitId).Scopes[FProj.Model(LC.UnitId).Symbols[
        LC.Sym].Scope].Kind;
      if (LKind in [sckUnit, sckImplementation]) and LUnitNames.TryGetValue(
         LWord, LAt) then
        for var LOther in LAt.Split(['|']) do
          if not SameText(LOther, TPath.GetFileNameWithoutExtension(
            FProj.ModelFile(LC.UnitId))) then
          begin
            LC.Doubts := LC.Doubts + [Format('%s declares %s too - which one '
              + 'a unit binds depends on the order of its `uses`', [LOther,
              FProj.Model(LC.UnitId).Symbols[LC.Sym].Name])];
            Break;
          end;
      FCands[LIdx] := LC;
    end;
  finally
    LUnitNames.Free;
    LDone.Free;
    LStrings.Free;
    LInactive.Free;
  end;
end;

function FindUnusedSymbols(ANav: TPasNavigator; const AMids: TArray<Integer>;
  out ASkips: TPasUnusedSkips): TArray<TPasUnusedSymbol>;
var
  LLint: TUnusedLint;
  LKept: TList<TPasUnusedSymbol>;
begin
  LLint := TUnusedLint.Create(ANav);
  LKept := TList<TPasUnusedSymbol>.Create;
  try
    LLint.CollectIfaceNames;
    for var LMid in AMids do
      if (LMid >= 0) and (LMid < ANav.Project.ModelCount) then
        LLint.Collect(LMid);
    for var LMid := 0 to ANav.Project.ModelCount - 1 do
      if not ANav.Project.IsLight(LMid) and
         not ANav.IsUnderLibraryPath(ANav.Project.ModelFile(LMid)) then
        LLint.MarkBound(LMid);
    LLint.Search;
    for var LC in LLint.FCands do
      if not LLint.FUsed.ContainsKey(TUnusedLint.K(LC.UnitId, LC.Sym)) then
      begin
        LKept.Add(LC);
        LLint.FUnused.AddOrSetValue(TUnusedLint.K(LC.UnitId, LC.Sym), True);
      end;
    LLint.FCands.Clear;
    LLint.FCands.AddRange(LKept);
    if LLint.FCands.Count > 0 then
      LLint.AddDoubts;
    Result := LLint.FCands.ToArray;
    ASkips := LLint.FSkips;
  finally
    LKept.Free;
    LLint.Free;
  end;
  TArray.Sort<TPasUnusedSymbol>(Result, TComparer<TPasUnusedSymbol>.Construct(
    function(const A, B: TPasUnusedSymbol): Integer
    begin
      Result := CompareText(A.FileName, B.FileName);
      if Result = 0 then
        Result := A.Line - B.Line;
      if Result = 0 then
        Result := A.Col - B.Col;
    end));
end;

function DemandUnusedSymbols(ANav: TPasNavigator;
  const AMids: TArray<Integer>): TPasDemand;
var
  LLint: TUnusedLint;
  LRefs: TArray<TPasExtRef>;
  LExt: TPasExtRef;
begin
  LLint := TUnusedLint.Create(ANav);
  try
    LLint.CollectIfaceNames;
    for var LMid in AMids do
      if (LMid >= 0) and (LMid < ANav.Project.ModelCount) then
        LLint.Collect(LMid);
    LRefs := nil;
    for var LC in LLint.FCands do
    begin
      LExt.UnitId := LC.UnitId;
      LExt.Sym := LC.Sym;
      LRefs := LRefs + [LExt];
    end;
    Result := ANav.DemandReferencesOfAll(LRefs);
  finally
    LLint.Free;
  end;
end;

end.
