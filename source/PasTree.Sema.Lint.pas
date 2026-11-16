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
  naming it (a frame's class placed on a form; a handler `OnClick = M` or a
  component `object X: TC` of the class's form, TPasFormBinder's rules),
  and for a class or record helper, which applies without being named, no
  member of it used. Kinds weighed: types,
  routines (nested ones too), unit and class variables and constants,
  fields, properties. A routine's locals and parameters are not: dcc hints
  them itself (H2164, H2219).

  A declaration every use of which sits in rows - in their bodies, their
  declarations (a property's `read GetX`, a field's type), or its own body
  (recursion) - is a row too (uhOnlyByUnused, By naming them): removed
  with them it is missed by nothing. A field or a unit or class variable
  whose every other use is the target of a plain `:=` (`FX := ...`,
  `Self.FX := ...`) is a row (uhOnlyWritten, Writes listing the
  assignments): nothing reads what it holds, and the assignments go with
  it - not an `absolute` one (a write of it writes another), not a
  record's field (the record is read whole). Both are
  decided together, to a fixed point (a type used only by a field only
  written is one; two routines calling only each other are two), over the
  declarations weighed - a use in one not weighed (another unit's in
  CheckUnusedSymbols, a virtual method) keeps it. A bare `inherited;` is
  a use placed in the routine it is written in: a static method only a
  dead descendant's hiding method runs that way is a row. A use the index
  cannot place (an include file, a form file binding it) keeps it, and a
  declaration bound more than 16 times is taken as used unsearched. Doubts
  of their own: an assignment whose value code computes - a call, a
  property (removing it drops that), an interface reference held (it
  keeps the object alive), a row using it that has a doubt.

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
  IDE's import headers); a unit that replaces a library unit of the same
  name (a patched Vcl.Menus: a unit found under ANav.LibraryPaths or the
  installed $(BDS)\source by that name, at another path) - the library's
  .dcu files were compiled against the original interface, so removing
  anything from it breaks units the analysis does not see (F2051, F2613).
  A false "unused" costs a deleted declaration that
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
  4,000-unit group. A helper none of whose members is used, and each such
  member: a call the index bound to the helped type's own member may run
  the helper's (27 of 27 such helpers were in use on a 4,000-unit group). A
  member of a class's unnamed first section whose ancestry the index could
  not follow to TPersistent, in a unit with a form file: published if the
  class streams, and the form may bind it by name at run time. One analysis, one configuration: pastree-mcp's `lint
  unused-symbol` keeps a row only when every analysis of a group holding
  the unit finds it unused. }
type
  TPasUnusedSkip = (usPublished, usDispatch, usInterface, usImplements,
    usOperator, usClassCtor, usAttribute, usForIn, usGenerated,
    usReplacesLibrary);
  TPasUnusedSkips = array[TPasUnusedSkip] of Integer;

  // Why a row is one (TPasUnusedSymbol.How).
  TPasUnusedHow = (
    uhUnused,        // nothing uses it
    uhOnlyByUnused,  // used only by rows (By) - or by itself: dead with them
    uhOnlyWritten);  // a field or variable only assigned (Writes), any other
                     // use by rows (By): nothing reads what it holds

  TPasUnusedSymbol = record
    UnitId, Sym: Integer;     // the declaration, in ANav's project
    FileName: string;         // the file it is written in (an include too)
    Line, Col: Integer;       // 1-based: its name
    Name: string;             // qualified by the types it is declared in
    Kind: TSemaSymbolKind;
    Head: TPasRoutineHead;    // a routine's; rhNone else
    RecordField: Boolean;
    Doubts: TArray<string>;   // one sentence each; empty when none
    How: TPasUnusedHow;
    By: TArray<string>;       // the rows using it, qualified ('' for itself)
    Writes: TArray<string>;   // uhOnlyWritten: the assignments, 'File.pas:12'
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

type
  // The verdict on one declaration asked about (CheckUnusedSymbols).
  TPasUnusedVerdict = (
    uvUnused,       // a row: Row holds it, its doubts with it
    uvUsed,         // used by name, a bare inherited, a redeclaration or a form
    uvSkipped,      // reached another way, not weighed: Skip says how
    uvNotCovered,   // not a declaration the rule weighs: a local, a
                    // parameter, an enum value, a unit, a label
    uvNotFound);    // TPasWorkspace.CheckUnusedSymbols: the key is no
                    // declaration of this analysis
  TPasUnusedCheck = record
    Target: TPasExtRef;
    Verdict: TPasUnusedVerdict;
    Skip: TPasUnusedSkip;     // uvSkipped
    Row: TPasUnusedSymbol;    // uvUnused
  end;

// FindUnusedSymbols for the declarations ATargets alone, one verdict each in
// their order: "is this one dead?" without the rows of its whole unit. The
// same rule - the overloads beside a routine asked about are weighed too, so
// the doubt "another overload is used" means what it means in a whole run,
// and so are the declarations its uses sit in, and theirs, up to 4 rounds
// and 300 declarations: one used only by a dead property's getter is a row.
function CheckUnusedSymbols(ANav: TPasNavigator;
  const ATargets: TArray<TPasExtRef>): TArray<TPasUnusedCheck>;

// CheckUnusedSymbols' demand in light mode.
function DemandCheckUnusedSymbols(ANav: TPasNavigator;
  const ATargets: TArray<TPasExtRef>): TPasDemand;

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
  System.Threading,
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
    // CheckUnits' lock, shared by the lints of one parallel run (nil when
    // this lint runs alone): what writes outside the lint - a hydration,
    // the word index of the units nobody loaded - takes it.
    FLock: TObject;
    // A lint of CheckUnits' run shares its main lint's walk past the loaded
    // models (FNLNodes, FNLPaths, FNLOut - taken under FLock), not owning it.
    FNLShared: Boolean;
    // Hydrated's locks, one per model id modulo their count (nil alone).
    FStripes: TArray<TObject>;
    // ImplNodeOf's answers, and PastLoadedOut's and NLPath's of the shared
    // walk: read without the lock.
    FImplNodes: TDictionary<Int64, Integer>;
    FNLOutMemo: TDictionary<Integer, TArray<Integer>>;
    FNLPathMemo: TDictionary<Integer, string>;
    // LinkEffect's answers of the whole run (CheckUnits: the main lint's
    // FEffect, under FLock), beside this lint's own.
    FSharedEffect: TDictionary<Integer, string>;
    class function K64(AMid, ASym: Integer): Int64; static; inline;
    procedure Lock;
    function NLPath(ANode: Integer): string;
    procedure Unlock;
    function Hydrated(AMid: Integer): Boolean;
    function ImplNodeOf(AMid, ASym: Integer): Integer;
    function NotLoadedOut(AMid: Integer; const APath: string): TArray<string>;
    procedure ScanNotLoaded(const APaths: TArray<string>);
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
  FImplNodes := TDictionary<Int64, Integer>.Create;
  FNLOutMemo := TDictionary<Integer, TArray<Integer>>.Create;
  FNLPathMemo := TDictionary<Integer, string>.Create;
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
  FNLPathMemo.Free;
  FNLOutMemo.Free;
  FImplNodes.Free;
  FForms.Free;
  FLoadNeeded.Free;
  if not FNLShared then
  begin
    FNLOut.Free;
    FNLPaths.Free;
    FNLNodes.Free;
  end;
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
procedure TUsesLint.Lock;
begin
  if FLock <> nil then
    TMonitor.Enter(FLock);
end;

procedure TUsesLint.Unlock;
begin
  if FLock <> nil then
    TMonitor.Exit(FLock);
end;

function TUsesLint.Hydrated(AMid: Integer): Boolean;
begin
  // Its text in place: nothing to write, no lock (EnsureHydrated's own
  // first test).
  if (AMid < 0) or (AMid >= FProj.ModelCount) or
     not FProj.Model(AMid).Demoted then
    Exit(FProj.EnsureHydrated(AMid));
  if FStripes = nil then
    Exit(FProj.EnsureHydrated(AMid));
  // One model at a time - two workers rehydrating the same one would race -
  // but different models in parallel (EnsureHydrated writes only its own
  // model, as HydrateModels runs it).
  TMonitor.Enter(FStripes[AMid mod Length(FStripes)]);
  try
    Result := FProj.EnsureHydrated(AMid);
  finally
    TMonitor.Exit(FStripes[AMid mod Length(FStripes)]);
  end;
end;

// The body node of routine (AMid, ASym): RoutineImplNode, which hydrates
// the model to pair the headers.
function TUsesLint.ImplNodeOf(AMid, ASym: Integer): Integer;
begin
  // Hydrated first, outside the shared lock; then the pairing, whose caches
  // are the navigator's (CacheOf), under it.
  if not Hydrated(AMid) then
    Exit(NIL_NODE);
  if FImplNodes.TryGetValue(K64(AMid, ASym), Result) then
    Exit;
  if FLock <> nil then
    FNav.PrepareRoutinePairs(AMid, FLock);
  Lock;
  try
    Result := FNav.RoutineImplNode(AMid, ASym);
  finally
    Unlock;
  end;
  FImplNodes.Add(K64(AMid, ASym), Result);
end;

class function TUsesLint.K64(AMid, ASym: Integer): Int64;
begin
  Result := (Int64(AMid) shl 32) or Cardinal(ASym);
end;

// A loaded model's not-loaded imports (AMid >= 0), else what the unit
// nobody loaded at APath lists (the word index, filled on first ask).
function TUsesLint.NotLoadedOut(AMid: Integer;
  const APath: string): TArray<string>;
begin
  Lock;
  try
    if AMid >= 0 then
      Result := FProj.NotLoadedImports(AMid)
    else
      Result := FProj.NotLoadedUses(APath);
  finally
    Unlock;
  end;
end;

procedure TUsesLint.ScanNotLoaded(const APaths: TArray<string>);
begin
  Lock;
  try
    FProj.ScanNotLoaded(APaths);
  finally
    Unlock;
  end;
end;

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
  // A lint of CheckUnits' run: another may have read it (the file's text).
  if FSharedEffect <> nil then
  begin
    Lock;
    try
      if FSharedEffect.TryGetValue(AMid, Result) then
      begin
        FEffect.Add(AMid, Result);
        Exit;
      end;
    finally
      Unlock;
    end;
  end;
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
  if FSharedEffect <> nil then
  begin
    Lock;
    try
      FSharedEffect.AddOrSetValue(AMid, Result);
    finally
      Unlock;
    end;
  end;
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
  Lock;
  try
    if not FNLNodes.TryGetValue(LKey, Result) then
    begin
      Result := FProj.ModelCount + FNLPaths.Count;
      FNLPaths.Add(APath);
      FNLNodes.Add(LKey, Result);
    end;
  finally
    Unlock;
  end;
end;

// The path of NLNode ANode.
function TUsesLint.NLPath(ANode: Integer): string;
begin
  if FNLPathMemo.TryGetValue(ANode, Result) then
    Exit;
  Lock;
  try
    Result := FNLPaths[ANode - FProj.ModelCount];
  finally
    Unlock;
  end;
  FNLPathMemo.Add(ANode, Result);
end;

// The targets of ANode's `uses` past the loaded graph (FEdges): a loaded
// model's not-loaded imports, a not-loaded unit's every listed unit - a
// loaded one as its model id, the rest as NLNode.
function TUsesLint.PastLoadedOut(ANode: Integer): TArray<Integer>;
var
  LPaths: TArray<string>;
  LMid: Integer;
begin
  if FNLOutMemo.TryGetValue(ANode, Result) then
    Exit;
  Lock;
  try
    if FNLOut.TryGetValue(ANode, Result) then
    begin
      FNLOutMemo.Add(ANode, Result);
      Exit;
    end;
    if ANode < FProj.ModelCount then
      LPaths := NotLoadedOut(ANode, '')
    else
      LPaths := NotLoadedOut(-1, FNLPaths[ANode - FProj.ModelCount]);
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
    FNLOutMemo.Add(ANode, Result);
  finally
    Unlock;
  end;
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
            Visit(LT, NLPath(LT));
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
        Lock;
        try
          for var LI := LAt to LQueue.Count - 1 do
            if (LQueue[LI] >= LN) and not FNLOut.ContainsKey(LQueue[LI]) then
              LWave := LWave + [FNLPaths[LQueue[LI] - LN]];
          ScanNotLoaded(LWave);
        finally
          Unlock;
        end;
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
            LBody := ImplNodeOf(AMid, LSym);
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
    LImpl := ImplNodeOf(AMid, ASym);
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
        if not Hydrated(LX.UnitId) then
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
  if not Hydrated(AMid) then
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

// CheckUnit(AMid, AEdges) of every unit of AMids, into ALint - on the
// analysis's pool (TPasSemaProject.ParallelRun): the units in contiguous
// slices, each checked by a lint of its own (its own caches; one lock for
// what writes outside a lint), then merged in the slices' order - the rows
// as one loop adds them, the light units and the dead edges as sets.
// Single-threaded, or a few units: ALint checks them itself.
procedure CheckUnits(ALint: TUsesLint; const AMids: TArray<Integer>;
  AEdges: Boolean);
var
  LMids: TArray<Integer>;
  LLints: TArray<TUsesLint>;
  LLock: TObject;
  LStripes: TArray<TObject>;
  LK, LN: Integer;
begin
  LMids := nil;
  for var LMid in AMids do
    if (LMid >= 0) and (LMid < ALint.FProj.ModelCount) then
      LMids := LMids + [LMid];
  LN := Length(LMids);
  LK := Min(LN div 8, 2 * Max(1, TThreadPool.Default.MaxWorkerThreads));
  if ALint.FProj.SingleThreaded or (LK < 2) then
  begin
    for var LMid in LMids do
      ALint.CheckUnit(LMid, AEdges);
    Exit;
  end;
  // The units' own text, read by each check: hydrated here, in parallel.
  ALint.FProj.HydrateModels(LMids);
  LLock := TObject.Create;
  SetLength(LStripes, 64);
  for var LI := 0 to High(LStripes) do
    LStripes[LI] := TObject.Create;
  SetLength(LLints, LK);
  try
    for var LI := 0 to LK - 1 do
    begin
      LLints[LI] := TUsesLint.Create(ALint.FNav);
      LLints[LI].FOptions := ALint.FOptions;
      LLints[LI].FLock := LLock;
      LLints[LI].FStripes := LStripes;
      // One walk past the loaded models for all of them: what one scans of
      // the units nobody loaded, the others find done.
      LLints[LI].FNLOut.Free;
      LLints[LI].FNLPaths.Free;
      LLints[LI].FNLNodes.Free;
      LLints[LI].FNLOut := ALint.FNLOut;
      LLints[LI].FNLPaths := ALint.FNLPaths;
      LLints[LI].FNLNodes := ALint.FNLNodes;
      LLints[LI].FNLShared := True;
      LLints[LI].FSharedEffect := ALint.FEffect;
    end;
    ALint.FProj.ParallelRun(LK - 1,
      procedure(ASlice: Integer)
      begin
        for var LI := LN * ASlice div LK to LN * (ASlice + 1) div LK - 1 do
          LLints[ASlice].CheckUnit(LMids[LI], AEdges);
      end);
    for var LLint in LLints do
    begin
      ALint.FRows.AddRange(LLint.FRows);
      for var LMid in LLint.FLightNeeded.Keys do
        ALint.FLightNeeded.AddOrSetValue(LMid, True);
      for var LPath in LLint.FLoadNeeded.Keys do
        ALint.FLoadNeeded.AddOrSetValue(LPath, True);
      for var LEdge in LLint.FDeadEdges.Keys do
        ALint.FDeadEdges.AddOrSetValue(LEdge, True);
    end;
  finally
    for var LLint in LLints do
      LLint.Free;
    for var LStripe in LStripes do
      LStripe.Free;
    LLock.Free;
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
    CheckUnits(LLint, LLint.FRoots + AMids, True);
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
    CheckUnits(LRowsLint, AMids, False);
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
    CheckUnits(LLint, AMids, False);
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

const
  // A candidate bound more often is taken as used, its references not
  // searched (its declaration sites are up to 3 of them).
  UNUSED_MAX_SEARCHED = 16;

type
  // One use of a candidate a reference search found (TUnusedLint.FUses).
  TUnusedSite = record
    Users: TArray<Int64>;  // the declarations it sits in; nil: none (a
                           // program's block, initialization) - a live use
    Write: Boolean;        // the target of a plain `:=`
    Call: Boolean;         // Write: the value assigned is computed by a call
    At: string;            // 'File.pas:12'
  end;

  // A reference hit placed by Search (TUnusedLint.PlaceHit).
  TUnusedHit = record
    Mid, Node: Integer;    // where it is
    BMid, BSym: Integer;   // what it binds
    ByName: Boolean;       // not mapped back: by the name it highlights
    Declared: Boolean;     // a declaration naming (BMid, BSym)
    Deferred: Boolean;     // on a pool worker: placed again on the caller's
    SiteReady: Boolean;    // Site made
    Site: TUnusedSite;
  end;

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
    FEnumOf: TDictionary<Int64, Int64>;  // an enum value -> its enum type
    FDirNames: TDictionary<string, Boolean>;  // Collect's unit, DirectiveNames
    // A `$IF` name no unit-level declaration answers (the last segment of a
    // dotted one, `{$IF TFoo.CLevel > 1}`): MarkIfNamed, by name.
    FIfNames: TDictionary<string, Boolean>;
    FStreams: TDictionary<Int64, Boolean>;  // Streams' answers, per class
    FSkips: TPasUnusedSkips;
    // CheckUnusedSymbols: the declarations collected (nil: every one of a
    // unit), and why each one not weighed was skipped.
    FOnly: TDictionary<Int64, Boolean>;
    FSkipOf: TDictionary<Int64, TPasUnusedSkip>;
    // The unit names under the library trees, and a file of each (lazy).
    FLibUnits: TDictionary<string, string>;
    // Used other than by a reference hit placed in a declaration: never a
    // row of Derive. FUses: a candidate's hits, each placed.
    FHard: TDictionary<Int64, Boolean>;
    FUses: TObjectDictionary<Int64, TList<TUnusedSite>>;
    FImplSym: TDictionary<Int64, Int64>;  // a routine node -> its symbol
    // The bare `inherited;` running each routine, placed (MarkBound), until
    // PlaceInherited moves a candidate's to FUses.
    FInherits: TObjectDictionary<Int64, TList<Int64>>;  // (model, node) each
    FFormAsked: TDictionary<Int64, Boolean>;  // FormBinds' answers
    FFormsRead: Boolean;  // the form files read once for this run (FormBinds)
    FSearched: TDictionary<Int64, Boolean>;  // the candidates Search asked about
    // The library units whose bodies can name an own declaration
    // (LibraryWithin), once computed (FWithinDone).
    FWithin: TArray<Boolean>;
    FWithinAny, FWithinDone: Boolean;
    function LibraryWithin(out AAny: Boolean): TArray<Boolean>;
    procedure PlaceInherited;
    function PlaceHit(const AH: TPasRefHit; AReadOnly: Boolean): TUnusedHit;
    function PlaceHits(AHits: TList<TPasRefHit>): TArray<TUnusedHit>;
    function SiteOf(const AH: TPasRefHit; AMid, ANode: Integer;
      AReadOnly: Boolean; out AReady: Boolean): TUnusedSite;
    procedure PrepareDeclAt(const AMids: TArray<Integer>);
    function DeclMapOf(AMid: Integer): TDictionary<Integer, Integer>;
    function FormBinds(AMid, ASym: Integer): Boolean;
    procedure Hard(AKey: Int64);
    // UsersOf, PlainWrite: False when AReadOnly (on a pool worker) and a
    // step that writes was needed (the answer is then not made).
    function UsersOf(LM: TPasSemaModel; AMid, ANode: Integer;
      AReadOnly: Boolean; out AUsers: TArray<Int64>): Boolean;
    function PlainWrite(LM: TPasSemaModel; AMid, ANode: Integer;
      AReadOnly: Boolean; out AWrite, ACall: Boolean): Boolean;
    function MayBeOnlyWritten(AKey: Int64): Boolean;
    procedure Derive(ARows: Boolean);
    procedure InheritDoubts;
    function UnknownUsers: TArray<TPasExtRef>;
    procedure Restrict(const ATargets: TArray<TPasExtRef>);
    procedure Extend(const AMore: TArray<TPasExtRef>);
    class function K(AMid, ASym: Integer): Int64; static; inline;
    function VisPos(LM: TPasSemaModel; AVis: Integer; out AFileId, ALine,
      ACol: Integer): Boolean;
    function HasDirective(LM: TPasSemaModel; ARoutine: Integer;
      const AWord: string): Boolean;
    function DescendsFrom(AClass: TSemaXType; const ANameLower: string):
      Boolean;
    function Streams(AClass: TSemaXType): Boolean;
    function TypeInfoOn(const AClass: TSemaXType): Boolean;
    procedure MarkDelegates(AMid: Integer);
    procedure MarkIfNames(AMid: Integer);
    procedure MarkIfNamed;
    function AncestryKnown(AClass: TSemaXType): Boolean;
    function NamesAncestor(const AClass: TSemaXType): Boolean;
    function IsStructType(const AX: TSemaXType; AKind: TPasNodeKind): Boolean;
    function ListedInterfaces(const AClass: TSemaXType): TArray<TSemaXType>;
    function InterfaceNamesOf(const AClass: TSemaXType): TDictionary<string,
      Boolean>;
    function QualifiedName(LM: TPasSemaModel; ASym: Integer): string;
    function Generated(LM: TPasSemaModel; const AFile: string): Boolean;
    function DelegatesInterface(LM: TPasSemaModel; ASym: Integer): Boolean;
    procedure DirectiveNames(LM: TPasSemaModel;
      ANames: TDictionary<string, Boolean>);
    procedure MarkRepublished;
    function ReplacesLibrary(AMid: Integer): Boolean;
    function IsHelperType(LM: TPasSemaModel; ASym: Integer): Boolean;
    function HelperOwner(LM: TPasSemaModel; ASym: Integer): Integer;
    function FormFileOf(AMid: Integer): string;
    procedure CollectIfaceNames;
    procedure Collect(AMid: Integer);
    function DeclaredAt(AMid, ANode: Integer; out ASym: Integer): Boolean;
    procedure MarkBound(AMid: Integer);
    procedure MarkUnbound(AMid: Integer; ANames: TDictionary<string, Boolean>);
    procedure Search;
    procedure MarkHelpers;
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
  FEnumOf := TDictionary<Int64, Int64>.Create;
  FDirNames := TDictionary<string, Boolean>.Create;
  FIfNames := TDictionary<string, Boolean>.Create;
  FStreams := TDictionary<Int64, Boolean>.Create;
  FHard := TDictionary<Int64, Boolean>.Create;
  FUses := TObjectDictionary<Int64, TList<TUnusedSite>>.Create([doOwnsValues]);
  FImplSym := TDictionary<Int64, Int64>.Create;
  FSearched := TDictionary<Int64, Boolean>.Create;
  FInherits := TObjectDictionary<Int64, TList<Int64>>.Create(
    [doOwnsValues]);
  FFormAsked := TDictionary<Int64, Boolean>.Create;
  FillChar(FSkips, SizeOf(FSkips), 0);
end;

destructor TUnusedLint.Destroy;
begin
  FFormAsked.Free;
  FInherits.Free;
  FSearched.Free;
  FImplSym.Free;
  FUses.Free;
  FHard.Free;
  FSkipOf.Free;
  FOnly.Free;
  FDirNames.Free;
  FIfNames.Free;
  FStreams.Free;
  FEnumOf.Free;
  FLibUnits.Free;
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

procedure TUnusedLint.Hard(AKey: Int64);
begin
  FUsed.AddOrSetValue(AKey, True);
  FHard.AddOrSetValue(AKey, True);
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

// Is AClass, or an ancestor, the class named ANameLower
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

// A TPersistent descendant, or a descendant of any class declared under
// `$M+` / `$TYPEINFO ON`: its unnamed first section is published - a form's
// components and handlers, a method MethodAddress('Ping') finds (dcc32 37.0:
// deleting it compiles, and the lookup returns nil).
function TUnusedLint.Streams(AClass: TSemaXType): Boolean;
var
  LKey: Int64;
begin
  LKey := K(AClass.UnitId, AClass.Sym);
  if FStreams.TryGetValue(LKey, Result) then
    Exit;
  Result := DescendsFrom(AClass, 'tpersistent');
  for var LDepth := 1 to 64 do
  begin
    if Result or not XValid(AClass) then
      Break;
    Result := TypeInfoOn(AClass);
    AClass := FProj.CanonTypeX(FProj.AncestorOfX(AClass));
  end;
  FStreams.Add(LKey, Result);
end;

// Was class AClass declared under `$M+` (`$TYPEINFO ON`)? The option state
// at its declaration: the last option directive before it (OptionRefs, kept
// when the text is demoted). One in another file - an include - is taken
// as before it when it leaves M on: a row kept, never a wrong deletion. A
// library class is TPersistent's (Streams); a unit no directive turns M on
// in, the usual one, answers at once.
function TUnusedLint.TypeInfoOn(const AClass: TSemaXType): Boolean;
var
  LM: TPasSemaModel;
  LAny: Boolean;
  LVis, LFile, LTok, LOff: Integer;
begin
  Result := False;
  if (AClass.UnitId < 0) or (AClass.UnitId >= FProj.ModelCount) then
    Exit;
  LM := FProj.Model(AClass.UnitId);
  LAny := False;
  for var LR in LM.Tree.Source.OptionRefs do
    if LR.State.Switches['M'] then
    begin
      LAny := True;
      Break;
    end;
  if not LAny or FNav.IsUnderLibraryPath(FProj.ModelFile(AClass.UnitId)) then
    Exit;
  if not FProj.EnsureHydrated(AClass.UnitId) then
    Exit(True);
  LVis := LM.Tree.NodeLeftmostVis(LM.Symbols[AClass.Sym].DeclNode);
  if (LVis < 0) or (LVis > High(LM.Tree.Source.Visible)) then
    Exit(True);
  LFile := LM.Tree.Source.Visible[LVis].FileId;
  LTok := LM.Tree.Source.Visible[LVis].TokenIndex;
  if (LFile < 0) or (LFile > High(LM.Tree.Source.Files)) or (LTok < 0) or
     (LTok > High(LM.Tree.Source.Files[LFile].Tokens)) then
    Exit(True);
  LOff := LM.Tree.Source.Files[LFile].Tokens[LTok].Start;
  for var LR in LM.Tree.Source.OptionRefs do
    if LR.FileId = LFile then
    begin
      if LR.Start >= LOff then
        Break;
      Result := LR.State.Switches['M'];
    end
    else if LR.State.Switches['M'] then
      Result := True;
end;

// Was AClass's ancestry followed all the way to TObject? Then Streams'
// answer is the compiler's: a class that does not reach TPersistent is
// never streamed, and no form binds a member of its first section.
function TUnusedLint.AncestryKnown(AClass: TSemaXType): Boolean;
var
  LNext: TSemaXType;
begin
  for var LDepth := 1 to 64 do
  begin
    if not XValid(AClass) then
      Exit(False);
    if FProj.Model(AClass.UnitId).Symbols[AClass.Sym].NameLower =
       'tobject' then
      Exit(True);
    LNext := FProj.CanonTypeX(FProj.AncestorOfX(AClass));
    // No ancestor bound: the root when the class names none (`class` is
    // TObject's), the end of what the index followed when it names one.
    if not XValid(LNext) then
      Exit(not NamesAncestor(AClass));
    AClass := LNext;
  end;
  Result := False;
end;

// Does AClass's declaration have a heritage list - `class(TBase)`? False
// too for one whose declaration the index does not hold.
function TUnusedLint.NamesAncestor(const AClass: TSemaXType): Boolean;
var
  LM: TPasSemaModel;
  LDecl, LDef, LChild: Integer;
begin
  Result := True;
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
  LChild := LM.Tree.Nodes[LDef].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if LM.Tree.Nodes[LChild].Kind in [nkIdent, nkMember, nkTypeArgs] then
      Exit;
    LChild := LM.Tree.Nodes[LChild].NextSibling;
  end;
  Result := False;
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
    // The index alone (DescendantTypes): FindDescendants' demand and rows,
    // per class, were most of a project-wide run. ListedInterfaces reads a
    // descendant's tree: its model hydrated first.
    for var LD in FNav.DescendantTypes(AClass.UnitId, AClass.Sym) do
      if FProj.EnsureHydrated(LD.UnitId) then
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

// A property with an `implements` specifier (14.4.1): its value supplies
// the class's methods of that interface, a use no name in code makes -
// dcc32 37.0 says E2291 for the interface's methods once it is gone.
function TUnusedLint.DelegatesInterface(LM: TPasSemaModel;
  ASym: Integer): Boolean;
var
  LNode, LChild: Integer;
begin
  Result := False;
  LNode := LM.Symbols[ASym].DeclNode;
  while (LNode <> NIL_NODE) and (LM.Tree.Nodes[LNode].Kind <> nkPropertyDecl) do
    LNode := LM.Tree.Nodes[LNode].Parent;
  if LNode = NIL_NODE then
    Exit;
  LChild := LM.Tree.Nodes[LNode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if (LM.Tree.Nodes[LChild].Kind = nkPropSpec) and
       LM.Tree.NodeTextEquals(LChild, 'implements') then
      Exit(True);
    LChild := LM.Tree.Nodes[LChild].NextSibling;
  end;
end;

// A property of model AMid delegating an interface to a class-typed value
// (`property Saver: TSaver read FSaver implements ISave`, 14.4.1): the
// methods of that class and its ancestors named like a method of the
// interface (or an ancestor of it) implement it for the owner - a use no
// name in code makes (dcc32 37.0: E2291 once TSaver.Save is gone). An
// interface-typed value's methods are its implementing class's, which
// lists the interface (usImplements).
procedure TUnusedLint.MarkDelegates(AMid: Integer);
var
  LM, LCM: TPasSemaModel;
  LNode, LSpec, LChild, LScope: Integer;
  LX, LT: TSemaXType;
  LNames: TDictionary<string, Boolean>;
begin
  LM := FProj.Model(AMid);
  LNames := nil;
  try
    for var LSym := 0 to LM.SymCount - 1 do
    begin
      if (LM.Symbols[LSym].Kind <> skProperty) or
         (LM.Symbols[LSym].DeclNode = NIL_NODE) or
         not DelegatesInterface(LM, LSym) then
        Continue;
      LT := FProj.CanonTypeX(FProj.SymDeclTypeX(AMid, LSym));
      if not IsStructType(LT, nkClassType) then
        Continue;
      LNode := LM.Symbols[LSym].DeclNode;
      while (LNode <> NIL_NODE) and
            (LM.Tree.Nodes[LNode].Kind <> nkPropertyDecl) do
        LNode := LM.Tree.Nodes[LNode].Parent;
      if LNode = NIL_NODE then
        Continue;
      if LNames = nil then
        LNames := TDictionary<string, Boolean>.Create
      else
        LNames.Clear;
      LSpec := LM.Tree.Nodes[LNode].FirstChild;
      while LSpec <> NIL_NODE do
      begin
        if (LM.Tree.Nodes[LSpec].Kind = nkPropSpec) and
           LM.Tree.NodeTextEquals(LSpec, 'implements') then
        begin
          LChild := LM.Tree.Nodes[LSpec].FirstChild;
          while LChild <> NIL_NODE do
          begin
            LX := FProj.CanonTypeX(FProj.ResolveTypeExpr(AMid, LChild));
            for var LUp := 1 to 64 do
            begin
              if not IsStructType(LX, nkInterfaceType) then
                Break;
              LCM := FProj.Model(LX.UnitId);
              LScope := LCM.Symbols[LX.Sym].MemberScope;
              if (LScope <> NIL_SCOPE) and (LScope < LCM.Scopes.Count) then
                for var LIdx := 0 to LCM.Scopes[LScope].Symbols.Count - 1 do
                  LNames.AddOrSetValue(LCM.Symbols[LCM.Scopes[LScope].
                    Symbols[LIdx]].NameLower, True);
              LX := FProj.CanonTypeX(FProj.AncestorOfX(LX));
            end;
            LChild := LM.Tree.Nodes[LChild].NextSibling;
          end;
        end;
        LSpec := LM.Tree.Nodes[LSpec].NextSibling;
      end;
      if LNames.Count = 0 then
        Continue;
      for var LUp := 1 to 64 do
      begin
        if not IsStructType(LT, nkClassType) then
          Break;
        LCM := FProj.Model(LT.UnitId);
        LScope := LCM.Symbols[LT.Sym].MemberScope;
        if (LScope <> NIL_SCOPE) and (LScope < LCM.Scopes.Count) then
          for var LIdx := 0 to LCM.Scopes[LScope].Symbols.Count - 1 do
          begin
            var LMem := LCM.Scopes[LScope].Symbols[LIdx];
            if (LCM.Symbols[LMem].Kind = skRoutine) and
               LNames.ContainsKey(LCM.Symbols[LMem].NameLower) then
              Hard(K(LT.UnitId, LMem));
          end;
        LT := FProj.CanonTypeX(FProj.AncestorOfX(LT));
      end;
    end;
  finally
    LNames.Free;
  end;
end;

// The names the `$IF` / `$ELSEIF` expressions of model AMid read
// (IfNameRefs: a constant, `Declared(X)`'s argument - not a conditional
// symbol) are uses of what they denote: deleting `CLevel` of
// `{$IF CLevel < 2}`, or TProbe of `{$IF Declared(TProbe)}`, still compiles
// (dcc32 37.0 takes an unreadable `$IF` comparison as True, a bare unknown
// name and Declared() of it as False) - the other branch. Resolved as the
// unit's code sees the name (IfNameTarget); one no unit-level declaration
// answers - a dotted name's last segment - kept by name for MarkIfNamed. A
// directive in a branch not compiled counts too, as DirectiveNames'.
procedure TUnusedLint.MarkIfNames(AMid: Integer);
var
  LM: TPasSemaModel;
  LSeen: TDictionary<string, Boolean>;
  LTMid, LTSym: Integer;
  LName: string;
begin
  LM := FProj.Model(AMid);
  if LM.Tree.Source.IfNameRefs = nil then
    Exit;
  LSeen := TDictionary<string, Boolean>.Create;
  try
    for var LR in LM.Tree.Source.IfNameRefs do
    begin
      LName := PasFoldName(LR.Name);
      if not LSeen.TryAdd(LName, True) then
        Continue;
      if FNav.IfNameTarget(AMid, LName, LTMid, LTSym) then
        Hard(K(LTMid, LTSym))
      else
        FIfNames.AddOrSetValue(LName, True);
    end;
  finally
    LSeen.Free;
  end;
end;

// A member named by a `$IF` name MarkIfNames could not resolve - its last
// segment, `{$IF TFoo.CLevel > 1}` - is used: a row kept, never a wrong
// deletion.
procedure TUnusedLint.MarkIfNamed;
var
  LM: TPasSemaModel;
  LScope: Integer;
begin
  if FIfNames.Count = 0 then
    Exit;
  for var LC in FCands do
  begin
    LM := FProj.Model(LC.UnitId);
    LScope := LM.Symbols[LC.Sym].Scope;
    if (LScope >= 0) and (LScope < LM.Scopes.Count) and
       (LM.Scopes[LScope].Kind = sckStruct) and
       FIfNames.ContainsKey(LM.Symbols[LC.Sym].NameLower) then
      Hard(K(LC.UnitId, LC.Sym));
  end;
end;

// The names the EXTERNALSYM and NODEFINE directives of a model's files
// spell, folded: dcc binds each name (dcc32 37.0: E2003 once X is gone, or
// E2240 "$EXTERNALSYM and $NODEFINE not allowed for 'X'; only global
// symbols" when what is left of that name is no global), so the name is a
// use. The preprocessor
// drops both directives as C++ header trivia, so the text is read here; a
// directive in a branch not compiled counts too - a row kept, never a
// wrong deletion.
procedure TUnusedLint.DirectiveNames(LM: TPasSemaModel;
  ANames: TDictionary<string, Boolean>);
var
  LText, LWord: string;
  LI, LJ, LLen: Integer;
begin
  for var LFi := 0 to High(LM.Tree.Source.Files) do
  begin
    LText := LM.Tree.Source.Files[LFi].Source;
    LLen := Length(LText);
    LI := Pos('$', LText);
    while LI > 0 do
    begin
      // A directive opens with a brace or a parenthesis-star, then the
      // dollar sign and the word with no space between.
      if ((LI > 1) and (LText[LI - 1] = '{')) or ((LI > 2) and
         (LText[LI - 1] = '*') and (LText[LI - 2] = '(')) then
      begin
        LJ := LI + 1;
        while (LJ <= LLen) and CharInSet(LText[LJ], ['A'..'Z', 'a'..'z']) do
          Inc(LJ);
        LWord := UpperCase(Copy(LText, LI + 1, LJ - LI - 1));
        if (LWord = 'EXTERNALSYM') or (LWord = 'NODEFINE') then
        begin
          while (LJ <= LLen) and CharInSet(LText[LJ], [' ', #9, #10, #13]) do
            Inc(LJ);
          LI := LJ;
          while (LJ <= LLen) and (LText[LJ].IsLetterOrDigit or
            (LText[LJ] = '_')) do
            Inc(LJ);
          if LJ > LI then
            ANames.AddOrSetValue(PasFoldName(Copy(LText, LI, LJ - LI)), True);
        end;
      end;
      LI := Pos('$', LText, LI + 1);
    end;
  end;
end;

// A property a descendant redeclares - a bare `property X;`, usually
// republishing it - is used: removing it breaks the redeclaration (dcc32
// 37.0: E2147 "Property 'X' does not exist in base class"). MarkBound sees
// the redeclarations of the units it walks; this asks every descendant of
// the candidate's class, wherever it is - a library unit, a light one -
// which MarkBound does not walk. One DescendantTypes per class - the index
// alone, no demand and no rows (FindDescendants') - and a descendant's model
// hydrated only when it declares a property of the name: its symbols and
// scopes stay when its text is demoted.
procedure TUnusedLint.MarkRepublished;
var
  LM, LDM: TPasSemaModel;
  LKids: TDictionary<Int64, TArray<TPasExtRef>>;
  LHits: TArray<TPasExtRef>;
  LOwner, LScope, LP, LBMid, LBSym, LPMid, LPSym: Integer;
begin
  LKids := TDictionary<Int64, TArray<TPasExtRef>>.Create;
  try
    for var LC in FCands do
    begin
      if (LC.Kind <> skProperty) or FUsed.ContainsKey(K(LC.UnitId, LC.Sym)) then
        Continue;
      LM := FProj.Model(LC.UnitId);
      LScope := LM.Symbols[LC.Sym].Scope;
      if (LScope = NIL_SCOPE) or (LScope >= LM.Scopes.Count) or
         (LM.Scopes[LScope].Kind <> sckStruct) then
        Continue;
      LOwner := LM.Scopes[LScope].StructSym;
      if LOwner = NIL_SYM then
        Continue;
      if not LKids.TryGetValue(K(LC.UnitId, LOwner), LHits) then
      begin
        LHits := FNav.DescendantTypes(LC.UnitId, LOwner);
        LKids.Add(K(LC.UnitId, LOwner), LHits);
      end;
      for var LD in LHits do
      begin
        LDM := FProj.Model(LD.UnitId);
        LScope := LDM.Symbols[LD.Sym].MemberScope;
        if (LScope = NIL_SCOPE) or (LScope >= LDM.Scopes.Count) then
          Continue;
        LP := LDM.FindLocal(LScope, LM.Symbols[LC.Sym].NameLower);
        if (LP = NIL_SYM) or (LDM.Symbols[LP].Kind <> skProperty) or
           not FProj.EnsureHydrated(LD.UnitId) then
          Continue;
        // Every link up from the redeclaration: a link between is needed
        // as much as the candidate.
        LBMid := LD.UnitId;
        LBSym := LP;
        for var LDepth := 1 to 64 do
        begin
          if not FProj.PropertyRedeclPrev(LBMid, LBSym, LPMid, LPSym) then
            Break;
          LBMid := LPMid;
          LBSym := LPSym;
          Hard(K(LBMid, LBSym));
        end;
        if FUsed.ContainsKey(K(LC.UnitId, LC.Sym)) then
          Break;
      end;
    end;
  finally
    LKids.Free;
  end;
end;

// Does unit AMid take the place of a library unit of its name - one under
// the library trees (ANav.LibraryPaths, the installed $(BDS)\source) at
// another path, a patched Vcl.Menus? Every library .dcu that uses it was
// compiled against the original's interface: deleting a declaration of the
// copy fails in units the analysis never reads (F2051, F2613), whether the
// copy itself uses it or not.
function TUnusedLint.ReplacesLibrary(AMid: Integer): Boolean;
var
  LTrees: TArray<string>;
  LBds, LFiles, LOwn: string;
begin
  if FLibUnits = nil then
  begin
    FLibUnits := TDictionary<string, string>.Create;
    LTrees := FNav.LibraryPaths;
    LBds := GetEnvironmentVariable('BDS');
    if (LBds <> '') and TDirectory.Exists(TPath.Combine(LBds, 'source')) then
      LTrees := LTrees + [TPath.Combine(LBds, 'source')];
    for var LTree in LTrees do
      try
        if TDirectory.Exists(LTree) then
          for var LFile in TDirectory.GetFiles(LTree, '*.pas',
            TSearchOption.soAllDirectories) do
          begin
            var LKey := PasFoldName(TPath.GetFileNameWithoutExtension(LFile));
            if FLibUnits.TryGetValue(LKey, LFiles) then
              FLibUnits[LKey] := LFiles + '|' + LFile
            else
              FLibUnits.Add(LKey, LFile);
          end;
      except
        on Exception do;   // an unreadable tree names no unit
      end;
  end;
  Result := False;
  if not FLibUnits.TryGetValue(FProj.Model(AMid).UnitNameLower, LFiles) then
    Exit;
  LOwn := TPath.GetFullPath(FProj.ModelFile(AMid));
  for var LFile in LFiles.Split(['|']) do
    if not SameText(TPath.GetFullPath(LFile), LOwn) then
      Exit(True);
end;

// Is type ASym of LM a class or record helper
function TUnusedLint.IsHelperType(LM: TPasSemaModel; ASym: Integer): Boolean;
var
  LDef: Integer;
begin
  LDef := TPasSemaProject.TypeDefNodeIn(LM, ASym);
  Result := (LDef <> NIL_NODE) and (LM.Tree.Nodes[LDef].Kind = nkHelperType);
end;

// The helper member ASym of LM is declared in, or NIL_SYM.
function TUnusedLint.HelperOwner(LM: TPasSemaModel; ASym: Integer): Integer;
var
  LScope: Integer;
begin
  Result := NIL_SYM;
  LScope := LM.Symbols[ASym].Scope;
  if (LScope < 0) or (LScope >= LM.Scopes.Count) or
     (LM.Scopes[LScope].Kind <> sckStruct) or
     (LM.Scopes[LScope].StructSym = NIL_SYM) then
    Exit;
  if IsHelperType(LM, LM.Scopes[LScope].StructSym) then
    Result := LM.Scopes[LScope].StructSym;
end;

// The form file beside unit AMid (.dfm, .fmx), or ''.
function TUnusedLint.FormFileOf(AMid: Integer): string;
begin
  for var LExt in ['.dfm', '.fmx'] do
  begin
    Result := ChangeFileExt(FProj.ModelFile(AMid), LExt);
    if FileExists(Result) then
      Exit;
  end;
  Result := '';
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
  LOwner, LNode, LFi, LLine, LCol, LTFi, LTLine, LTCol, LSym: Integer;
  LC: TPasUnusedSymbol;
  LSkip: Boolean;

  procedure Skip(AWhy: TPasUnusedSkip);
  begin
    Inc(FSkips[AWhy]);
    LSkip := True;
    if FSkipOf <> nil then
      FSkipOf.AddOrSetValue(K(AMid, LSym), AWhy);
  end;

begin
  if not FProj.EnsureHydrated(AMid) then
    Exit;
  LM := FProj.Model(AMid);
  if Generated(LM, FProj.ModelFile(AMid)) then
  begin
    Inc(FSkips[usGenerated]);
    if FOnly <> nil then
      for LSym := 0 to LM.SymCount - 1 do
        if FOnly.ContainsKey(K(AMid, LSym)) then
          FSkipOf.AddOrSetValue(K(AMid, LSym), usGenerated);
    Exit;
  end;
  if ReplacesLibrary(AMid) then
  begin
    Inc(FSkips[usReplacesLibrary]);
    if FOnly <> nil then
      for LSym := 0 to LM.SymCount - 1 do
        if FOnly.ContainsKey(K(AMid, LSym)) then
          FSkipOf.AddOrSetValue(K(AMid, LSym), usReplacesLibrary);
    Exit;
  end;
  FDirNames.Clear;
  DirectiveNames(LM, FDirNames);
  for LSym := 0 to LM.SymCount - 1 do
  begin
    if (FOnly <> nil) and not FOnly.ContainsKey(K(AMid, LSym)) then
      Continue;
    // Collected or skipped already (a unit asked about again, Extend).
    if FCount.ContainsKey(K(AMid, LSym)) or ((FSkipOf <> nil) and
       FSkipOf.ContainsKey(K(AMid, LSym))) then
      Continue;
    LS := LM.Symbols[LSym];
    // A value of a named enum (TypeSym, 2.2.4) named in code is a use of its
    // type (MarkBound): `Ord(grpError)` needs TGroups (E2003 without it).
    if (LS.Kind = skEnumValue) and (LS.TypeSym <> NIL_SYM) then
      FEnumOf.AddOrSetValue(K(AMid, LSym), K(AMid, LS.TypeSym));
    // A nameless symbol is the type an anonymous method makes for itself
    // (25 rows "unused-symbol  (type)" on a client group): nothing names it.
    if (LS.DeclNode = NIL_NODE) or (LS.NameLower = '') or
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
      // A class constructor or destructor runs at the unit's initialization
      // and finalization, never named. The declaration in the class starts
      // at `constructor` (the `class` word is the routine node's Aux,
      // IsClassCtorDtor); a body without one in the class at `class`.
      else if LM.IsClassCtorDtor(LSym) or ((LM.RoutineHead(LSym) in
        [rhConstructor, rhDestructor]) and (LNode <> NIL_NODE) and
        VisPos(LM, LM.Tree.NodeLeftmostVis(LNode), LTFi, LTLine, LTCol) and
        SameText(Copy(LM.Tree.Source.Files[LTFi].LineText(LTLine), LTCol, 6),
        'class ')) then
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
    // Used without a name in code: a property delegating an interface, a
    // global an EXTERNALSYM / NODEFINE directive names.
    if ((LS.Kind = skProperty) and DelegatesInterface(LM, LSym)) or
       ((LKind in [sckUnit, sckImplementation]) and
       FDirNames.ContainsKey(LS.NameLower)) then
      Hard(K(AMid, LSym));
  end;
end;

// The symbol of model AMid whose declaration name is ANode. A table per
// model, built on the first ask: only the models a reference hit lands on a
// declaration of are asked (a property redeclared).
function TUnusedLint.DeclaredAt(AMid, ANode: Integer;
  out ASym: Integer): Boolean;
var
  LMap: TDictionary<Integer, Integer>;
begin
  if not FDeclAt.TryGetValue(AMid, LMap) then
  begin
    LMap := DeclMapOf(AMid);
    FDeclAt.Add(AMid, LMap);
  end;
  Result := LMap.TryGetValue(ANode, ASym);
end;

// What a bare `inherited;` of model AMid runs is used: it names nothing a
// reference search finds.
procedure TUnusedLint.MarkBound(AMid: Integer);
var
  LM: TPasSemaModel;
  LBMid, LBSym, LCtx, LN: Integer;
  LEnum: Int64;
begin
  if not FProj.EnsureHydrated(AMid) then
    Exit;
  LM := FProj.Model(AMid);
  MarkDelegates(AMid);
  MarkIfNames(AMid);
  for var LI := 0 to High(LM.Tree.Nodes) do
    if (LM.Tree.Nodes[LI].Kind = nkInherited) and
       (LM.Tree.Nodes[LI].FirstChild = NIL_NODE) and
       FProj.BareInheritedTarget(AMid, LI, LBMid, LBSym, LCtx) then
    begin
      // A use placed like a reference hit, where it is written kept until
      // PlaceInherited places a candidate's (most such calls run a virtual
      // method, never a candidate): dead when the routine running it is.
      FUsed.AddOrSetValue(K(LBMid, LBSym), True);
      var LAt: TList<Int64>;
      if not FInherits.TryGetValue(K(LBMid, LBSym), LAt) then
      begin
        LAt := TList<Int64>.Create;
        FInherits.Add(K(LBMid, LBSym), LAt);
      end;
      LAt.Add(K(AMid, LI));
    end;
  // The bindings, counted: a declaration bound more often than its own
  // sites could make it (its declaration, implementation header, forward)
  // is used, and Search does not ask for its references.
  // A binding of an enum value (FEnumOf) other than its own declaration
  // marks the enum type.
  // Only uses are counted: a declared name (nfName - the implementation
  // header's, a forward's) and the declaration itself are not, so a count
  // above what the reference search places is a use it missed (Search).
  for var LI := 0 to High(LM.RefMap) do
    if LM.RefMap[LI] = NIL_SYM then
      Continue
    else if FCount.TryGetValue(K(AMid, LM.RefMap[LI]), LN) then
    begin
      if not (nfName in LM.Tree.Nodes[LI].Flags) and
         (LM.Symbols[LM.RefMap[LI]].DeclNode <> LI) then
        FCount[K(AMid, LM.RefMap[LI])] := LN + 1;
    end
    else if FEnumOf.TryGetValue(K(AMid, LM.RefMap[LI]), LEnum) and
      (LM.Symbols[LM.RefMap[LI]].DeclNode <> LI) then
      Hard(LEnum);
  for var LP in LM.ExtRefMap do
    if FCount.TryGetValue(K(LP.Value.UnitId, LP.Value.Sym), LN) then
    begin
      if not (nfName in LM.Tree.Nodes[LP.Key].Flags) then
        FCount[K(LP.Value.UnitId, LP.Value.Sym)] := LN + 1;
    end
    else if FEnumOf.TryGetValue(K(LP.Value.UnitId, LP.Value.Sym), LEnum) then
      Hard(LEnum);
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
      if not FHard.TryAdd(K(LBMid, LBSym), True) then
        Break;   // the rest of the chain is marked already
      FUsed.AddOrSetValue(K(LBMid, LBSym), True);
    end;
  end;
  MarkUnbound(AMid, FCandNames);
end;

procedure TUnusedLint.MarkUnbound(AMid: Integer;
  ANames: TDictionary<string, Boolean>);
var
  LM: TPasSemaModel;
  LN: Integer;
begin
  if not FProj.EnsureHydrated(AMid) then
    Exit;
  LM := FProj.Model(AMid);
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
    if not ANames.ContainsKey(LName) or DeclaredAt(AMid, LI, LN) then
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

// What hit AH binds (Search): its model and node, the declaration it is
// bound to - or declares (Declared: a descendant's `property X;`) - or
// ByName (the hit cannot be mapped back). AReadOnly: on a pool worker -
// what would write (IdentAt's cache, DeclaredAt's map, a hydration) is not
// done and Deferred says so; the caller places the hit again on its thread.
// The site (SiteOf) is made too when AH binds a candidate.
function TUnusedLint.PlaceHit(const AH: TPasRefHit;
  AReadOnly: Boolean): TUnusedHit;
var
  LM: TPasSemaModel;
  LIdent: TPasNavIdent;
  LExt: TPasExtRef;
  LNotReady: Boolean;
begin
  Result := Default(TUnusedHit);
  Result.Mid := FNav.ModelIdOf(AH.FilePath);
  Result.Node := NIL_NODE;
  LM := nil;
  if Result.Mid >= 0 then
  begin
    LM := FProj.Model(Result.Mid);
    if AH.Implicit then
      Result.Node := AH.IndexNode
    else if AReadOnly then
    begin
      if not FNav.IdentNodeAt(Result.Mid, AH.Line, AH.Col, Result.Node,
         LNotReady) then
        Result.Node := NIL_NODE;
      if LNotReady then
      begin
        Result.Deferred := True;
        Exit;
      end;
    end
    else if FNav.IdentAt(Result.Mid, AH.Line, AH.Col, LIdent) then
      Result.Node := LIdent.Node;
  end;
  if Result.Node = NIL_NODE then
  begin
    Result.ByName := True;
    Exit;
  end;
  if (Result.Node >= 0) and (Result.Node < Length(LM.RefMap)) and
     (LM.RefMap[Result.Node] <> NIL_SYM) then
  begin
    Result.BMid := Result.Mid;
    Result.BSym := LM.RefMap[Result.Node];
  end
  else if LM.ExtRefMap.TryGetValue(Result.Node, LExt) then
  begin
    Result.BMid := LExt.UnitId;
    Result.BSym := LExt.Sym;
  end
  else if AReadOnly and not FDeclAt.ContainsKey(Result.Mid) then
  begin
    Result.Deferred := True;
    Exit;
  end
  else if DeclaredAt(Result.Mid, Result.Node, Result.BSym) then
  begin
    Result.BMid := Result.Mid;
    Result.Declared := True;
  end
  else
  begin
    Result.ByName := True;
    Exit;
  end;
  // The site, for a candidate: whether it is still weighed when the hit is
  // applied (FHard) is decided then.
  if FCount.ContainsKey(K(Result.BMid, Result.BSym)) then
    Result.Site := SiteOf(AH, Result.Mid, Result.Node, AReadOnly,
      Result.SiteReady);
end;

// The site hit AH (on node ANode of model AMid) makes. AReady False: on a
// pool worker (AReadOnly), a step that writes was needed - made again on the
// caller's thread.
function TUnusedLint.SiteOf(const AH: TPasRefHit; AMid, ANode: Integer;
  AReadOnly: Boolean; out AReady: Boolean): TUnusedSite;
var
  LM: TPasSemaModel;
begin
  Result := Default(TUnusedSite);
  LM := FProj.Model(AMid);
  AReady := False;
  if not UsersOf(LM, AMid, ANode, AReadOnly, Result.Users) then
    Exit;
  if not PlainWrite(LM, AMid, ANode, AReadOnly, Result.Write, Result.Call) then
    Exit;
  Result.At := Format('%s:%d', [ExtractFileName(AH.FilePath), AH.Line]);
  AReady := True;
end;

// Every hit placed (PlaceHit), on the pool: first, on this thread, the hit
// models hydrated with their position caches and DeclaredAt's maps built.
function TUnusedLint.PlaceHits(AHits: TList<TPasRefHit>): TArray<TUnusedHit>;
var
  LMids: TArray<Integer>;
  LSeen: TDictionary<Integer, Boolean>;
  LResult: TArray<TUnusedHit>;
  LHits: TArray<TPasRefHit>;
begin
  LHits := AHits.ToArray;
  LMids := nil;
  LSeen := TDictionary<Integer, Boolean>.Create;
  try
    for var LH in LHits do
    begin
      var LMid := FNav.ModelIdOf(LH.FilePath);
      if (LMid >= 0) and LSeen.TryAdd(LMid, True) then
        LMids := LMids + [LMid];
    end;
  finally
    LSeen.Free;
  end;
  FNav.PrepareCaches(LMids);
  PrepareDeclAt(LMids);
  SetLength(LResult, Length(LHits));
  FProj.ParallelRun(High(LHits),
    procedure(AIdx: Integer)
    begin
      LResult[AIdx] := PlaceHit(LHits[AIdx], True);
    end);
  Result := LResult;
end;

// DeclaredAt's maps of AMids, built on the pool (each reads its model only)
// and added here: afterwards DeclaredAt of them only reads.
procedure TUnusedLint.PrepareDeclAt(const AMids: TArray<Integer>);
var
  LTodo: TArray<Integer>;
  LMaps: TArray<TDictionary<Integer, Integer>>;
begin
  LTodo := nil;
  for var LMid in AMids do
    if not FDeclAt.ContainsKey(LMid) then
      LTodo := LTodo + [LMid];
  SetLength(LMaps, Length(LTodo));
  FProj.ParallelRun(High(LTodo),
    procedure(AIdx: Integer)
    begin
      LMaps[AIdx] := DeclMapOf(LTodo[AIdx]);
    end);
  for var LIdx := 0 to High(LTodo) do
    FDeclAt.Add(LTodo[LIdx], LMaps[LIdx]);
end;

function TUnusedLint.DeclMapOf(AMid: Integer): TDictionary<Integer, Integer>;
var
  LM: TPasSemaModel;
begin
  Result := TDictionary<Integer, Integer>.Create;
  LM := FProj.Model(AMid);
  for var LSym := 0 to LM.SymCount - 1 do
    if LM.Symbols[LSym].DeclNode <> NIL_NODE then
      Result.AddOrSetValue(LM.Symbols[LSym].DeclNode, LSym);
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
  LByName: TDictionary<string, Boolean>;
  LBMid, LBSym, LPMid, LPSym, LN: Integer;
  LNew: TDictionary<Int64, Boolean>;
  LPlaced: TArray<TUnusedHit>;
  LPlacedN: TDictionary<Int64, Integer>;  // a new candidate's placed hits
begin
  MarkRepublished;
  // The candidates not searched yet: all of them, but in CheckUnusedSymbols'
  // later rounds (Extend) only the ones a round added.
  LNew := TDictionary<Int64, Boolean>.Create;
  for var LC in FCands do
    if FSearched.TryAdd(K(LC.UnitId, LC.Sym), True) then
      LNew.Add(K(LC.UnitId, LC.Sym), True);
  LRefs := nil;
  for var LC in FCands do
    // Used by a bare inherited alone is searched too: its other uses decide
    // whether that is all.
    if not LNew.ContainsKey(K(LC.UnitId, LC.Sym)) or
       FHard.ContainsKey(K(LC.UnitId, LC.Sym)) then
      Continue
    else if FCount[K(LC.UnitId, LC.Sym)] > UNUSED_MAX_SEARCHED then
      Hard(K(LC.UnitId, LC.Sym))
    else
    begin
      LExt.UnitId := LC.UnitId;
      LExt.Sym := LC.Sym;
      LRefs := LRefs + [LExt];
    end;
  LByName := TDictionary<string, Boolean>.Create;
  LHits := TList<TPasRefHit>.Create;
  LPlacedN := TDictionary<Int64, Integer>.Create;
  try
    if LRefs <> nil then
    begin
      // Not searched: only the library bodies the demand would have made
      // full (UnusedLintDemand) - the rest cannot name a candidate.
      var LAny: Boolean;
      var LWithin := LibraryWithin(LAny);
      FNav.CollectReferencesOfAll(LRefs, LHits, False, -1, LWithin);
    end;
    // Each hit placed on the pool (PlaceHits: what it binds, the site it
    // makes - reads only), then applied here in the hits' order, as one
    // loop did it.
    LPlaced := PlaceHits(LHits);
    for var LIdx := 0 to LHits.Count - 1 do
    begin
      var LH := LHits[LIdx];
      var LP := LPlaced[LIdx];
      if LP.Deferred then
        LP := PlaceHit(LH, False);
      // A hit that cannot be mapped back to what it binds - in an include
      // file, which no model is named after - marks every candidate of the
      // name it highlights: a use is never lost, a namesake kept at worst.
      if LP.ByName then
      begin
        LByName.AddOrSetValue(LowerCase(Copy(LH.Snippet, LH.HiFrom + 1,
          LH.HiTo - LH.HiFrom)), True);
        Continue;
      end;
      LBMid := LP.BMid;
      LBSym := LP.BSym;
      // A descendant's `property X;` is a declaration naming the
      // ancestor's: the property it declares, and every link up.
      if LP.Declared then
        Hard(K(LBMid, LBSym));
      FUsed.AddOrSetValue(K(LBMid, LBSym), True);
      if LNew.ContainsKey(K(LBMid, LBSym)) then
      begin
        if not LPlacedN.TryGetValue(K(LBMid, LBSym), LN) then
          LN := 0;
        LPlacedN.AddOrSetValue(K(LBMid, LBSym), LN + 1);
      end;
      // Placed: the declarations it sits in, and whether it is assigned.
      if FCount.ContainsKey(K(LBMid, LBSym)) and
         not FHard.ContainsKey(K(LBMid, LBSym)) then
      begin
        var LSites: TList<TUnusedSite>;
        if not FUses.TryGetValue(K(LBMid, LBSym), LSites) then
        begin
          LSites := TList<TUnusedSite>.Create;
          FUses.Add(K(LBMid, LBSym), LSites);
        end;
        if not LP.SiteReady then
          LP.Site := SiteOf(LH, LP.Mid, LP.Node, False, LP.SiteReady);
        LSites.Add(LP.Site);
      end;
      for var LDepth := 1 to 64 do
      begin
        if (FProj.Model(LBMid).Symbols[LBSym].Kind <> skProperty) or
           not FProj.PropertyRedeclPrev(LBMid, LBSym, LPMid, LPSym) then
          Break;
        LBMid := LPMid;
        LBSym := LPSym;
        Hard(K(LBMid, LBSym));
      end;
    end;
    for var LC in FCands do
      if LByName.ContainsKey(FProj.Model(LC.UnitId).Symbols[LC.Sym].NameLower)
      then
        Hard(K(LC.UnitId, LC.Sym));
    // Bound more often than the search placed: a use it does not find (on a
    // client group, calls through a record helper's method from a unit the
    // project compiles) - used, and never a row made by rows.
    for var LC in FCands do
      if LNew.ContainsKey(K(LC.UnitId, LC.Sym)) and
         not FHard.ContainsKey(K(LC.UnitId, LC.Sym)) then
      begin
        if not LPlacedN.TryGetValue(K(LC.UnitId, LC.Sym), LN) then
          LN := 0;
        if FCount[K(LC.UnitId, LC.Sym)] > LN then
          Hard(K(LC.UnitId, LC.Sym));
      end;
  finally
    LPlacedN.Free;
    LByName.Free;
    LHits.Free;
  end;
  // A class a form file names - a frame placed on a form, a module - and a
  // member of a class's unnamed first section one binds: a handler
  // (`OnClick = M`), a component (`object X: TC`). Such a member is
  // published, and not weighed, when the class is seen to stream; when its
  // ancestry is not followed to TPersistent the form still binds it by name
  // (TReader: MethodAddress, FieldAddress), and deleting it compiles and
  // fails when the form is created.
  // A used one is asked by Derive, when it may be a row made by rows.
  for var LC in FCands do
    if LNew.ContainsKey(K(LC.UnitId, LC.Sym)) and
       not FUsed.ContainsKey(K(LC.UnitId, LC.Sym)) and
       FormBinds(LC.UnitId, LC.Sym) then
      Hard(K(LC.UnitId, LC.Sym));
  LNew.Free;
end;

// Does a form file bind (AMid, ASym): a class it names, or a member of a
// class's unnamed first section (a handler, a component)? Asked once each.
function TUnusedLint.FormBinds(AMid, ASym: Integer): Boolean;
var
  LCM: TPasSemaModel;
  LScope: Integer;
begin
  if FFormAsked.TryGetValue(K(AMid, ASym), Result) then
    Exit;
  Result := False;
  LCM := FProj.Model(AMid);
  LScope := LCM.Symbols[ASym].Scope;
  if ((LCM.Symbols[ASym].Kind = skType) and
     (LCM.Symbols[ASym].TypeCat = tcClass)) or
     ((LCM.Symbols[ASym].Kind in [skRoutine, skField]) and
     (LCM.Symbols[ASym].Visibility = svDefault) and (LScope >= 0) and
     (LScope < LCM.Scopes.Count) and
     (LCM.Scopes[LScope].Kind = sckStruct) and
     (LCM.Scopes[LScope].StructSym <> NIL_SYM) and
     (LCM.Symbols[LCM.Scopes[LScope].StructSym].TypeCat = tcClass)) then
  begin
    // The form files read as they are now once per run, not once per
    // declaration asked: each read stats every form file of the group, and
    // a project-wide run asks thousands.
    Result := Length(FNav.FindFormSites(AMid, ASym, not FFormsRead)) > 0;
    FFormsRead := True;
  end;
  FFormAsked.Add(K(AMid, ASym), Result);
end;

// The bare `inherited;` uses of the candidates (MarkBound) joined to their
// placed hits; anything else they run stays used.
procedure TUnusedLint.PlaceInherited;
var
  LSites: TList<TUnusedSite>;
  LAt: TList<Int64>;
  LM: TPasSemaModel;
  LMid, LNode, LFi, LLine, LCol: Integer;
begin
  for var LC in FCands do
  begin
    var LKey := K(LC.UnitId, LC.Sym);
    if FHard.ContainsKey(LKey) or not FInherits.TryGetValue(LKey, LAt) then
      Continue;
    if not FUses.TryGetValue(LKey, LSites) then
    begin
      LSites := TList<TUnusedSite>.Create;
      FUses.Add(LKey, LSites);
    end;
    for var LWhere in LAt do
    begin
      LMid := Integer(LWhere shr 32);
      LNode := Integer(Cardinal(LWhere and $FFFFFFFF));
      LM := FProj.Model(LMid);
      var LSite := Default(TUnusedSite);
      UsersOf(LM, LMid, LNode, False, LSite.Users);
      if VisPos(LM, LM.Tree.NodeLeftmostVis(LNode), LFi, LLine, LCol) then
        LSite.At := Format('%s:%d', [ExtractFileName(
          LM.Tree.Source.FileNames[LFi]), LLine]);
      LSites.Add(LSite);
    end;
    FInherits.Remove(LKey);
  end;
end;

// A class or record helper applies without being named: a call to a member
// it adds is its use. One of its members used marks it used.
procedure TUnusedLint.MarkHelpers;
var
  LM: TPasSemaModel;
  LScope: Integer;
begin
  for var LC in FCands do
  begin
    if (LC.Kind <> skType) or FUsed.ContainsKey(K(LC.UnitId, LC.Sym)) then
      Continue;
    LM := FProj.Model(LC.UnitId);
    if not IsHelperType(LM, LC.Sym) then
      Continue;
    LScope := LM.Symbols[LC.Sym].MemberScope;
    if (LScope = NIL_SCOPE) or (LScope >= LM.Scopes.Count) then
      Continue;
    for var LIdx := 0 to LM.Scopes[LScope].Symbols.Count - 1 do
      if FUsed.ContainsKey(K(LC.UnitId, LM.Scopes[LScope].Symbols[LIdx])) then
      begin
        Hard(K(LC.UnitId, LC.Sym));
        Break;
      end;
  end;
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
// One file's words for AddDoubts: those of the branches it does not compile
// and those its string literals spell - each with where, in text order.
type
  TDoubtWord = record
    Word, At: string;
  end;

  TDoubtFile = record
    FileName: string;
    Inactive: TArray<TDoubtWord>;
    Strings: TArray<TDoubtWord>;
  end;

// Every word of 3 letters or more in AText (at AOffset of ATS), in order.
procedure DoubtWords(const ATS: TPasTokenStream; const AFile, AText: string;
  AOffset: Integer; AList: TList<TDoubtWord>);
var
  LJ, LK, LLine, LCol: Integer;
  LW: TDoubtWord;
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
      LW.Word := LowerCase(Copy(AText, LJ, LK - LJ));
      if Length(LW.Word) >= 3 then
      begin
        ATS.OffsetToLineCol(AOffset + LJ - 1, LLine, LCol);
        LW.At := Format('%s:%d', [ExtractFileName(AFile), LLine]);
        AList.Add(LW);
      end;
      LJ := LK;
    end
    else
      Inc(LJ);
  end;
end;

// The string literals of AText, outside comments: one scan. A lookup by
// name passes the name as the whole literal: FindClass('TFoo'),
// 'Unit.TFoo', 'TFoo.Bar' - a word inside a message or a query is not one
// (3,292 rows of 8,598 on a 4,000-unit group had such a doubt). Kept: the
// literal, and its last segment ('#' + it) for a type.
procedure DoubtStrings(const ATS: TPasTokenStream; const AFile: string;
  AList: TList<TDoubtWord>);
var
  LText, LWord: string;
  LI, LStart, LLine, LCol: Integer;
  LW: TDoubtWord;
begin
  LText := ATS.Source;
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
          LWord := LowerCase(Trim(Copy(LText, LStart, LI - LStart)));
          if IsValidIdent(LWord, True) and (Length(LWord) >= 3) then
          begin
            ATS.OffsetToLineCol(LStart - 1, LLine, LCol);
            LW.At := Format('%s:%d', [ExtractFileName(AFile), LLine]);
            LW.Word := LWord;
            AList.Add(LW);
            if LWord.Contains('.') then
              LWord := Copy(LWord, LWord.LastIndexOf('.') + 2, MaxInt);
            LW.Word := '#' + LWord;
            AList.Add(LW);
          end;
        end;
    end;
    Inc(LI);
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
  LFile, LWord, LAt: string;
  LC: TPasUnusedSymbol;
  LMids: TArray<Integer>;
  LFiles: TArray<TArray<Integer>>;
  LRead: TArray<TArray<TDoubtFile>>;
begin
  LInactive := TDictionary<string, string>.Create;
  LStrings := TDictionary<string, string>.Create;
  LUnitNames := TDictionary<string, string>.Create;
  LDone := TDictionary<string, Boolean>.Create;
  try
    // The project's own units and their own files, hydrated here; their
    // words read on the pool, each file's in order; then taken in the
    // units' and files' order as one loop took them (the first place of a
    // word wins, a file's literals once).
    LMids := nil;
    LFiles := nil;
    for var LMid := 0 to FProj.ModelCount - 1 do
      if not FProj.IsLight(LMid) and
         not FNav.IsUnderLibraryPath(FProj.ModelFile(LMid)) then
        LMids := LMids + [LMid];
    FProj.HydrateModels(LMids);
    SetLength(LFiles, Length(LMids));
    for var LIdx := 0 to High(LMids) do
      if not FProj.EnsureHydrated(LMids[LIdx]) then
        LMids[LIdx] := -1;
    FProj.ParallelRun(High(LMids),
      procedure(AIdx: Integer)
      var
        LTM: TPasSemaModel;
      begin
        if LMids[AIdx] < 0 then
          Exit;
        LTM := FProj.Model(LMids[AIdx]);
        for var LFi := 0 to High(LTM.Tree.Source.Files) do
          if not FNav.IsUnderLibraryPath(LTM.Tree.Source.FileNames[LFi]) then
            LFiles[AIdx] := LFiles[AIdx] + [LFi];
      end);
    SetLength(LRead, Length(LMids));
    FProj.ParallelRun(High(LMids),
      procedure(AIdx: Integer)
      var
        LTM: TPasSemaModel;
        LTS: TPasTokenStream;
        LList: TList<TDoubtWord>;
        LName: string;
      begin
        if LMids[AIdx] < 0 then
          Exit;
        LTM := FProj.Model(LMids[AIdx]);
        SetLength(LRead[AIdx], Length(LFiles[AIdx]));
        LList := TList<TDoubtWord>.Create;
        try
          for var LK := 0 to High(LFiles[AIdx]) do
          begin
            var LFi := LFiles[AIdx][LK];
            LName := LTM.Tree.Source.FileNames[LFi];
            LTS := LTM.Tree.Source.Files[LFi];
            LRead[AIdx][LK].FileName := LName;
            LList.Clear;
            if LFi <= High(LTM.Tree.Source.Skipped) then
              for var LR in LTM.Tree.Source.Skipped[LFi] do
                DoubtWords(LTS, LName, Copy(LTS.Source, LR.Start + 1,
                  LR.EndPos - LR.Start), LR.Start, LList);
            LRead[AIdx][LK].Inactive := LList.ToArray;
            LList.Clear;
            DoubtStrings(LTS, LName, LList);
            LRead[AIdx][LK].Strings := LList.ToArray;
          end;
        finally
          LList.Free;
        end;
      end);
    for var LIdx := 0 to High(LMids) do
      for var LK := 0 to High(LRead[LIdx]) do
      begin
        for var LW in LRead[LIdx][LK].Inactive do
          LInactive.TryAdd(LW.Word, LW.At);
        if not LDone.TryAdd(LowerCase(LRead[LIdx][LK].FileName), True) then
          Continue;
        for var LW in LRead[LIdx][LK].Strings do
          LStrings.TryAdd(LW.Word, LW.At);
      end;
    // The names every unit declares in its interface, with a unit declaring
    // each: a row's name declared by another unit is a doubt.
    // Each unit's names on the pool, taken in the units' order.
    var LNames: TArray<TArray<string>>;
    SetLength(LNames, FProj.ModelCount);
    FProj.ParallelRun(FProj.ModelCount - 1,
      procedure(AMid: Integer)
      var
        LTM: TPasSemaModel;
        LList: TList<string>;
      begin
        LTM := FProj.Model(AMid);
        LList := TList<string>.Create;
        try
          for var LSym := 0 to LTM.SymCount - 1 do
            if (LTM.Symbols[LSym].DeclNode <> NIL_NODE) and
               (LTM.Symbols[LSym].Scope >= 0) and
               (LTM.Symbols[LSym].Scope < LTM.Scopes.Count) and
               (LTM.Scopes[LTM.Symbols[LSym].Scope].Kind = sckUnit) and
               (LTM.Symbols[LSym].Kind in [skType, skVar, skConst,
               skRoutine]) then
              LList.Add(LTM.Symbols[LSym].NameLower);
          LNames[AMid] := LList.ToArray;
        finally
          LList.Free;
        end;
      end);
    for var LMid := 0 to FProj.ModelCount - 1 do
    begin
      if LNames[LMid] = nil then
        Continue;
      var LUnit := TPath.GetFileNameWithoutExtension(FProj.ModelFile(LMid));
      for LWord in LNames[LMid] do
        if not LUnitNames.TryGetValue(LWord, LAt) then
          LUnitNames.Add(LWord, LUnit)
        else if (Length(LAt) < 200) and not ContainsText('|' + LAt + '|',
          '|' + LUnit + '|') then
          LUnitNames[LWord] := LAt + '|' + LUnit;
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
      // A method too by its bare name - extended RTTI's GetMethod('Run'),
      // which every public method answers (dcc32 37.0: deleting it compiles,
      // and the lookup returns nil); not a free routine, which no RTTI lists.
      LM := FProj.Model(LC.UnitId);
      if ((LC.Kind = skType) and LStrings.TryGetValue('#' + LWord, LAt)) or
         LStrings.TryGetValue(LOwnerName + '.' + LWord, LAt) or
         ((LC.Kind = skRoutine) and (LOwnerSym >= 0) and
         (LM.Scopes[LOwnerSym].Kind = sckStruct) and
         (LM.Symbols[LC.Sym].Visibility in [svDefault, svPublic]) and
         LStrings.TryGetValue('#' + LWord, LAt)) then
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
      // A helper no member of which is used, and such a member: a call
      // to a member it adds is its only use, and the index may have bound
      // one to the helped type's own member (overloads, an access the
      // helper widens) - 27 of 27 such helpers were in use on a 4,000-unit
      // group.
      LM := FProj.Model(LC.UnitId);
      if (LC.Kind = skType) and IsHelperType(LM, LC.Sym) then
        LC.Doubts := LC.Doubts + ['a helper applies without being named - '
          + 'no use of a member it adds was found, but a call the index bound '
          + 'to the helped type may run one']
      else if HelperOwner(LM, LC.Sym) <> NIL_SYM then
      begin
        if FUnused.ContainsKey(K(LC.UnitId, HelperOwner(LM, LC.Sym))) then
          LC.Doubts := LC.Doubts + [Format('a member of the helper %s, no '
            + 'member of which is used - a call the index bound to the helped '
            + 'type may run it', [LM.Symbols[HelperOwner(LM, LC.Sym)].Name])];
      end
      // The unnamed first section of a class not seen to stream, in a unit
      // with a form file: published if it streams after all (the ancestry
      // the index could not follow), and the form binds by name at run time.
      // Not when the ancestry was followed to TObject without meeting
      // TPersistent (`TFoo = class`): such a class never streams - the doubt
      // hid every plain class's fields in a form's unit, and with them what
      // only those fields use (a type held by an unused class's field).
      else if (LC.Kind in [skRoutine, skField, skProperty]) and
        (LM.Symbols[LC.Sym].Visibility = svDefault) and
        (LM.Scopes[LM.Symbols[LC.Sym].Scope].Kind = sckStruct) and
        (LM.Scopes[LM.Symbols[LC.Sym].Scope].StructSym <> NIL_SYM) and
        (LM.Symbols[LM.Scopes[LM.Symbols[LC.Sym].Scope].StructSym].TypeCat =
        tcClass) and not AncestryKnown(XPlain(LC.UnitId,
        LM.Scopes[LM.Symbols[LC.Sym].Scope].StructSym)) then
      begin
        LFile := FormFileOf(LC.UnitId);
        if LFile <> '' then
          LC.Doubts := LC.Doubts + [Format('in the unnamed first section of '
            + 'a class the index did not follow to TPersistent, in a unit with '
            + 'a form file (%s) - published if the class streams, and a form '
            + 'may bind it by name at run time', [ExtractFileName(LFile)])];
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

// The declarations the use ANode sits in: the innermost routine (a nested
// one, a method's implementation - its declared symbol), or the property,
// field, variable, constant or type whose declaration holds it (`read
// GetX`, a field's type; every name of `FA, FB: TX`). A routine's locals
// are passed through to the routine. nil: in none (a program's block,
// initialization, a routine not placed) - a live use.
function TUnusedLint.UsersOf(LM: TPasSemaModel; AMid, ANode: Integer;
  AReadOnly: Boolean; out AUsers: TArray<Int64>): Boolean;
var
  LN, LC, LName, LSym, LFi, LLine, LCol, LTMid, LTSym: Integer;
  LExt: TPasExtRef;
  LLocal: Boolean;
  LKey: Int64;
  LTName: string;
begin
  Result := True;
  AUsers := nil;
  LN := LM.Tree.Nodes[ANode].Parent;
  while LN <> NIL_NODE do
  begin
    case LM.Tree.Nodes[LN].Kind of
      nkRoutine:
        begin
          LName := NIL_NODE;
          LC := LM.Tree.Nodes[LN].FirstChild;
          while LC <> NIL_NODE do
          begin
            if (LM.Tree.Nodes[LC].Kind = nkIdent) and
               (nfName in LM.Tree.Nodes[LC].Flags) then
              LName := LC
            else if not (LM.Tree.Nodes[LC].Kind in [nkGenericParams,
              nkAttrGroup]) then
              Break;
            LC := LM.Tree.Nodes[LC].NextSibling;
          end;
          if LName = NIL_NODE then
            Exit;
          if DeclaredAt(AMid, LName, LSym) then
          begin
            AUsers := [K(AMid, LSym)];
            Exit;
          end;
          if (LName < Length(LM.RefMap)) and (LM.RefMap[LName] <> NIL_SYM) then
          begin
            AUsers := [K(AMid, LM.RefMap[LName])];
            Exit;
          end;
          if LM.ExtRefMap.TryGetValue(LName, LExt) then
          begin
            AUsers := [K(LExt.UnitId, LExt.Sym)];
            Exit;
          end;
          // A method's implementation header binds its name to nothing: the
          // navigator pairs it with the declaration (Find References from
          // the header). Once per routine.
          if not FImplSym.TryGetValue(K(AMid, LN), LKey) then
          begin
            if AReadOnly then
              Exit(False);   // SymbolAtFile and the memo: the caller's thread
            LKey := -1;
            if VisPos(LM, LM.Tree.NodeLeftmostVis(LName), LFi, LLine, LCol)
               and FNav.SymbolAtFile(AMid, LM.Tree.Source.FileNames[LFi],
               LLine, LCol, LTMid, LTSym, LTName) then
              LKey := K(LTMid, LTSym);
            FImplSym.Add(K(AMid, LN), LKey);
          end;
          if LKey <> -1 then
            AUsers := [LKey];
          Exit;
        end;
      nkPropertyDecl, nkVarDecl, nkConstDecl, nkTypeDecl:
        begin
          LLocal := False;
          LC := LM.Tree.Nodes[LN].FirstChild;
          while LC <> NIL_NODE do
          begin
            if DeclaredAt(AMid, LC, LSym) then
            begin
              var LScope := LM.Symbols[LSym].Scope;
              if (LScope >= 0) and (LScope < LM.Scopes.Count) and
                 (LM.Scopes[LScope].Kind = sckRoutine) then
                LLocal := True
              else
                AUsers := AUsers + [K(AMid, LSym)];
            end;
            LC := LM.Tree.Nodes[LC].NextSibling;
          end;
          if LLocal then
            AUsers := nil
          else if AUsers <> nil then
            Exit;
        end;
      nkInterfaceSec, nkImplementationSec, nkInitSec, nkFinalSec, nkUnit,
      nkProgram, nkLibrary, nkPackage:
        begin
          AUsers := nil;
          Exit;
        end;
    end;
    LN := LM.Tree.Nodes[LN].Parent;
  end;
end;

// Is the use ANode the target of a plain `:=` - `FX :=`, `Self.FX :=`,
// `Obj.FX :=`? ACall: the value assigned is not Plain - code runs to
// compute it (`TFoo.Create`, `GetX`, a property).
function TUnusedLint.PlainWrite(LM: TPasSemaModel; AMid, ANode: Integer;
  AReadOnly: Boolean; out AWrite, ACall: Boolean): Boolean;
var
  LCur, LP, LRhs: Integer;
  LExt: TPasExtRef;
  LBlocked: Boolean;   // AReadOnly: a model to hydrate first

  // A value no code runs to compute: a literal, nil, a variable, field,
  // constant, parameter or enum value, and operators over them. A call, a
  // property (its getter), a cast or a name bound to nothing is not.
  function Plain(ANo: Integer): Boolean;
  var
    LC, LBMid, LBSym: Integer;
  begin
    LBMid := -1;
    LBSym := NIL_SYM;
    if (ANo < Length(LM.RefMap)) and (LM.RefMap[ANo] <> NIL_SYM) then
    begin
      LBMid := AMid;
      LBSym := LM.RefMap[ANo];
    end
    else if LM.ExtRefMap.TryGetValue(ANo, LExt) then
    begin
      LBMid := LExt.UnitId;
      LBSym := LExt.Sym;
    end;
    case LM.Tree.Nodes[ANo].Kind of
      nkIntLit, nkRealLit, nkStrLit, nkNilLit, nkCaretChar:
        Exit(True);
      nkIdent:
        begin
          if (LBMid >= 0) and AReadOnly and FProj.Model(LBMid).Demoted then
          begin
            LBlocked := True;
            Exit(False);
          end;
          Exit((LBMid >= 0) and FProj.EnsureHydrated(LBMid) and
            (FProj.Model(LBMid).Symbols[LBSym].Kind in [skVar, skConst,
            skField, skParam, skEnumValue]));
        end;
      nkUnaryOp, nkBinaryOp, nkParen, nkSetCtor, nkRange, nkInlineIf,
      nkMember, nkIndex, nkDeref:
        begin
          if LBMid >= 0 then
            Exit(False);   // brackets bound: a default array property
          LC := LM.Tree.Nodes[ANo].FirstChild;
          while LC <> NIL_NODE do
          begin
            if not Plain(LC) then
              Exit(False);
            LC := LM.Tree.Nodes[LC].NextSibling;
          end;
          Exit(True);
        end;
    end;
    Result := False;
  end;

begin
  Result := True;
  AWrite := False;
  ACall := False;
  LBlocked := False;
  if LM.Tree.Nodes[ANode].Kind <> nkIdent then
    Exit;
  LCur := ANode;
  LP := LM.Tree.Nodes[LCur].Parent;
  // The member's name, its last child: `X.FX`.
  if (LP <> NIL_NODE) and (LM.Tree.Nodes[LP].Kind = nkMember) and
     (LM.Tree.Nodes[LP].FirstChild <> LCur) and
     (LM.Tree.Nodes[LCur].NextSibling = NIL_NODE) then
  begin
    LCur := LP;
    LP := LM.Tree.Nodes[LCur].Parent;
  end;
  if (LP = NIL_NODE) or (LM.Tree.Nodes[LP].Kind <> nkAssign) or
     (LM.Tree.Nodes[LP].FirstChild <> LCur) then
    Exit;
  AWrite := True;
  LRhs := LM.Tree.Nodes[LCur].NextSibling;
  ACall := (LRhs <> NIL_NODE) and not Plain(LRhs);
  Result := not LBlocked;
end;

// A field, or a unit or class variable, not `absolute` (its writes write
// another): what may be a row for being only written.
function TUnusedLint.MayBeOnlyWritten(AKey: Int64): Boolean;
var
  LM: TPasSemaModel;
  LSym, LDecl: Integer;
begin
  LM := FProj.Model(Integer(AKey shr 32));
  LSym := Integer(Cardinal(AKey and $FFFFFFFF));
  Result := LM.Symbols[LSym].Kind in [skField, skVar];
  if not Result then
    Exit;
  // A record's field: the record is read whole (passed, copied, written to
  // a stream), and what the field holds with it.
  var LScope := LM.Symbols[LSym].Scope;
  if (LScope >= 0) and (LScope < LM.Scopes.Count) and
     (LM.Scopes[LScope].Kind = sckStruct) and
     (LM.Scopes[LScope].StructSym <> NIL_SYM) and
     (LM.Symbols[LM.Scopes[LScope].StructSym].TypeCat = tcRecord) then
    Exit(False);
  LDecl := LM.Tree.Nodes[LM.Symbols[LSym].DeclNode].Parent;
  Result := (LDecl = NIL_NODE) or (LM.Tree.Nodes[LDecl].Kind <> nkVarDecl) or
    (LM.Tree.Nodes[LDecl].Aux <> 1);
end;

// The rows made by the rows (TPasUnusedHow): the candidates used only
// through placed hits, each kept while every use of it sits in rows, in
// itself or in the others kept, or - a field or variable - assigns it.
// A greatest fixed point: two routines calling only each other are two.
// FUnused is made afresh - the candidates nothing uses, then these; ARows:
// the rows' How, By, Writes and doubts set too (once, at the end).
procedure TUnusedLint.Derive(ARows: Boolean);
var
  LKept: TDictionary<Int64, Boolean>;
  LChanged, LOk, LDead: Boolean;
  LIdx: Integer;
  LC: TPasUnusedSymbol;
  LBy: TDictionary<Int64, Boolean>;
  LWrites: TArray<string>;

  function DeadUser(AUser, AOf: Int64): Boolean;
  begin
    Result := (AUser = AOf) or FUnused.ContainsKey(AUser) or
      LKept.ContainsKey(AUser);
  end;

begin
  FUnused.Clear;
  for var LR in FCands do
    if not FUsed.ContainsKey(K(LR.UnitId, LR.Sym)) then
      FUnused.AddOrSetValue(K(LR.UnitId, LR.Sym), True);
  LKept := TDictionary<Int64, Boolean>.Create;
  LBy := TDictionary<Int64, Boolean>.Create;
  try
    // A form file binding one keeps it, whatever uses it in code: asked of
    // the ones the fixed point keeps (few), and the point made again
    // without those a form binds.
    repeat
    LKept.Clear;
    for var LP in FUses do
      if FUsed.ContainsKey(LP.Key) and not FHard.ContainsKey(LP.Key) and
         not FUnused.ContainsKey(LP.Key) then
        LKept.Add(LP.Key, True);
    repeat
      LChanged := False;
      for var LKey in LKept.Keys.ToArray do
      begin
        LOk := True;
        for var LSite in FUses[LKey] do
        begin
          LDead := LSite.Users <> nil;
          for var LU in LSite.Users do
            if not DeadUser(LU, LKey) then
            begin
              LDead := False;
              Break;
            end;
          if not LDead and not (LSite.Write and MayBeOnlyWritten(LKey)) then
          begin
            LOk := False;
            Break;
          end;
        end;
        if not LOk then
        begin
          LKept.Remove(LKey);
          LChanged := True;
        end;
      end;
    until not LChanged;
    LChanged := False;
    for var LKey in LKept.Keys do
      if FormBinds(Integer(LKey shr 32), Integer(Cardinal(LKey and
         $FFFFFFFF))) then
      begin
        FHard.AddOrSetValue(LKey, True);
        LChanged := True;
      end;
    until not LChanged;
    for var LKey in LKept.Keys do
      FUnused.AddOrSetValue(LKey, True);
    if not ARows or (LKept.Count = 0) then
      Exit;
    for LIdx := 0 to FCands.Count - 1 do
    begin
      LC := FCands[LIdx];
      var LKey := K(LC.UnitId, LC.Sym);
      if not LKept.ContainsKey(LKey) then
        Continue;
      LBy.Clear;
      LWrites := nil;
      LC.How := uhOnlyByUnused;
      for var LSite in FUses[LKey] do
      begin
        LDead := LSite.Users <> nil;
        for var LU in LSite.Users do
          if not DeadUser(LU, LKey) then
            LDead := False;
        if LDead then
        begin
          for var LU in LSite.Users do
            if LBy.TryAdd(LU, True) then
              if LU = LKey then
                LC.By := LC.By + ['']
              else
                LC.By := LC.By + [QualifiedName(FProj.Model(Integer(LU shr 32)),
                  Integer(Cardinal(LU and $FFFFFFFF)))];
        end
        else
        begin
          LC.How := uhOnlyWritten;
          LWrites := LWrites + [LSite.At];
          if LSite.Call then
            LC.Doubts := LC.Doubts + [Format('the value assigned at %s is '
              + 'computed by code (a call, a property) - removing the '
              + 'assignment drops it', [LSite.At])];
        end;
      end;
      LC.Writes := LWrites;
      if LC.How = uhOnlyWritten then
      begin
        var LX := FProj.CanonTypeX(FProj.DeclTypeX(LC.UnitId, LC.Sym));
        if XValid(LX) and FProj.EnsureHydrated(LX.UnitId) and
           (FProj.Model(LX.UnitId).Symbols[LX.Sym].TypeCat = tcInterface) then
          LC.Doubts := LC.Doubts + ['it holds an interface reference - '
            + 'assigning it keeps the object alive until it is cleared'];
      end;
      FCands[LIdx] := LC;
    end;
  finally
    LBy.Free;
    LKept.Free;
  end;
end;

// A row made by rows is as sure as they are: a doubt of one using it is one
// of its own.
procedure TUnusedLint.InheritDoubts;
var
  LDoubted: TDictionary<string, Boolean>;
  LC: TPasUnusedSymbol;
begin
  LDoubted := TDictionary<string, Boolean>.Create;
  try
    for var LR in FCands do
      if LR.Doubts <> nil then
        LDoubted.AddOrSetValue(LR.Name, True);
    for var LIdx := 0 to FCands.Count - 1 do
    begin
      LC := FCands[LIdx];
      for var LB in LC.By do
        if (LB <> '') and LDoubted.ContainsKey(LB) then
        begin
          LC.Doubts := LC.Doubts + [Format('%s, which uses it, has a doubt of '
            + 'its own', [LB])];
          Break;
        end;
      FCands[LIdx] := LC;
    end;
  finally
    LDoubted.Free;
  end;
end;

// The declarations the uses of a used candidate sit in that were not
// weighed (not in FOnly): what CheckUnusedSymbols adds for the next round.
function TUnusedLint.UnknownUsers: TArray<TPasExtRef>;
var
  LSeen: TDictionary<Int64, Boolean>;
  LExt: TPasExtRef;

  // Live whatever the declarations not weighed yet turn out to be: a use
  // in no declaration, or in one weighed and settled live - used another
  // way than by placed hits, not weighed (virtual, published), or not a
  // candidate - that is no assignment it may be only written by. Its users
  // need no next round (a call chain up to a live handler stops there).
  function LiveNow(AKey: Int64; ASites: TList<TUnusedSite>): Boolean;
  begin
    for var LSite in ASites do
    begin
      if LSite.Write and MayBeOnlyWritten(AKey) then
        Continue;
      if LSite.Users = nil then
        Exit(True);
      for var LU in LSite.Users do
        if (LU <> AKey) and FOnly.ContainsKey(LU) and
           (FHard.ContainsKey(LU) or FSkipOf.ContainsKey(LU) or
           not FCount.ContainsKey(LU)) then
          Exit(True);
    end;
    Result := False;
  end;

begin
  Result := nil;
  if FOnly = nil then
    Exit;
  LSeen := TDictionary<Int64, Boolean>.Create;
  try
    for var LP in FUses do
    begin
      if FHard.ContainsKey(LP.Key) or FUnused.ContainsKey(LP.Key) or
         LiveNow(LP.Key, LP.Value) then
        Continue;
      for var LSite in LP.Value do
        for var LU in LSite.Users do
          if not FOnly.ContainsKey(LU) and LSeen.TryAdd(LU, True) then
          begin
            LExt.UnitId := Integer(LU shr 32);
            LExt.Sym := Integer(Cardinal(LU and $FFFFFFFF));
            Result := Result + [LExt];
          end;
    end;
  finally
    LSeen.Free;
  end;
end;

// Restricted to ATargets and the overloads beside each: the doubt "another
// overload of it is used" asks whether a sibling is a row, so the siblings
// are weighed too.
procedure TUnusedLint.Restrict(const ATargets: TArray<TPasExtRef>);
var
  LM: TPasSemaModel;
  LS: Integer;
begin
  FOnly := TDictionary<Int64, Boolean>.Create;
  FSkipOf := TDictionary<Int64, TPasUnusedSkip>.Create;
  for var LT in ATargets do
  begin
    if (LT.UnitId < 0) or (LT.UnitId >= FProj.ModelCount) or
       not FProj.EnsureHydrated(LT.UnitId) then
      Continue;
    LM := FProj.Model(LT.UnitId);
    if (LT.Sym < 0) or (LT.Sym >= LM.SymCount) then
      Continue;
    FOnly.AddOrSetValue(K(LT.UnitId, LT.Sym), True);
    if (LM.Symbols[LT.Sym].Kind <> skRoutine) or
       (LM.Symbols[LT.Sym].Scope < 0) then
      Continue;
    LS := LM.FindLocal(LM.Symbols[LT.Sym].Scope, LM.Symbols[LT.Sym].NameLower);
    while LS <> NIL_SYM do
    begin
      if LM.Symbols[LS].Kind = skRoutine then
        FOnly.AddOrSetValue(K(LT.UnitId, LS), True);
      LS := LM.Symbols[LS].NextOverload;
    end;
  end;
end;

// The declarations AMore weighed too, in a later round of
// CheckUnusedSymbols: collected (once each), the new names' unbound places
// scanned for their doubts, their references searched (only theirs - the
// group-wide marks are a whole run's already), and FUnused made afresh. Not
// counted: each is searched.
procedure TUnusedLint.Extend(const AMore: TArray<TPasExtRef>);
var
  LOldNames, LNames: TDictionary<string, Boolean>;
  LMids: TArray<Integer>;
begin
  LOldNames := TDictionary<string, Boolean>.Create;
  LNames := TDictionary<string, Boolean>.Create;
  try
    for var LName in FCandNames.Keys do
      LOldNames.Add(LName, True);
    LMids := nil;
    for var LT in AMore do
    begin
      if (LT.UnitId < 0) or (LT.UnitId >= FProj.ModelCount) or
         not FProj.EnsureHydrated(LT.UnitId) or (LT.Sym < 0) or
         (LT.Sym >= FProj.Model(LT.UnitId).SymCount) then
        Continue;
      FOnly.AddOrSetValue(K(LT.UnitId, LT.Sym), True);
      var LNew := True;
      for var LMid in LMids do
        if LMid = LT.UnitId then
          LNew := False;
      if LNew then
        LMids := LMids + [LT.UnitId];
    end;
    for var LMid in LMids do
      Collect(LMid);
    MarkIfNamed;
    // Their uses as the index binds them, as MarkBound counts the first
    // round's: what Search compares its placed hits with.
    var LFresh := TDictionary<Int64, Boolean>.Create;
    try
      for var LC in FCands do
        if not FSearched.ContainsKey(K(LC.UnitId, LC.Sym)) then
          LFresh.AddOrSetValue(K(LC.UnitId, LC.Sym), True);
      if LFresh.Count > 0 then
        for var LMid := 0 to FProj.ModelCount - 1 do
        begin
          if FProj.IsLight(LMid) or
             FNav.IsUnderLibraryPath(FProj.ModelFile(LMid)) or
             not FProj.EnsureHydrated(LMid) then
            Continue;
          var LM := FProj.Model(LMid);
          for var LI := 0 to High(LM.RefMap) do
            if (LM.RefMap[LI] <> NIL_SYM) and
               LFresh.ContainsKey(K(LMid, LM.RefMap[LI])) and
               not (nfName in LM.Tree.Nodes[LI].Flags) and
               (LM.Symbols[LM.RefMap[LI]].DeclNode <> LI) then
              FCount[K(LMid, LM.RefMap[LI])] :=
                FCount[K(LMid, LM.RefMap[LI])] + 1;
          for var LP in LM.ExtRefMap do
            if LFresh.ContainsKey(K(LP.Value.UnitId, LP.Value.Sym)) and
               not (nfName in LM.Tree.Nodes[LP.Key].Flags) then
              FCount[K(LP.Value.UnitId, LP.Value.Sym)] :=
                FCount[K(LP.Value.UnitId, LP.Value.Sym)] + 1;
        end;
    finally
      LFresh.Free;
    end;
    PlaceInherited;
    for var LName in FCandNames.Keys do
      if not LOldNames.ContainsKey(LName) then
        LNames.Add(LName, True);
    if LNames.Count > 0 then
      for var LMid := 0 to FProj.ModelCount - 1 do
        if not FProj.IsLight(LMid) and
           not FNav.IsUnderLibraryPath(FProj.ModelFile(LMid)) then
          MarkUnbound(LMid, LNames);
  finally
    LNames.Free;
    LOldNames.Free;
  end;
  Search;
  MarkHelpers;
  Derive(False);
end;

// The candidates of AMids collected, the group-wide marks made, their
// references searched and FUnused made (RunUnusedLint's first half).
procedure GatherUnused(ALint: TUnusedLint; ANav: TPasNavigator;
  const AMids: TArray<Integer>);
begin
  ALint.CollectIfaceNames;
  for var LMid in AMids do
    if (LMid >= 0) and (LMid < ANav.Project.ModelCount) then
      ALint.Collect(LMid);
  for var LMid := 0 to ANav.Project.ModelCount - 1 do
    if not ANav.Project.IsLight(LMid) and
       not ANav.IsUnderLibraryPath(ANav.Project.ModelFile(LMid)) then
      ALint.MarkBound(LMid);
  ALint.MarkIfNamed;
  ALint.PlaceInherited;
  ALint.Search;
  ALint.MarkHelpers;
  ALint.Derive(False);
end;

// The rows left in FCands (and FUnused) with their How and doubts.
procedure FinishUnused(ALint: TUnusedLint);
var
  LKept: TList<TPasUnusedSymbol>;
begin
  LKept := TList<TPasUnusedSymbol>.Create;
  try
    ALint.Derive(True);
    for var LC in ALint.FCands do
      if ALint.FUnused.ContainsKey(TUnusedLint.K(LC.UnitId, LC.Sym)) then
        LKept.Add(LC);
    ALint.FCands.Clear;
    ALint.FCands.AddRange(LKept);
    if ALint.FCands.Count > 0 then
    begin
      ALint.AddDoubts;
      ALint.InheritDoubts;
    end;
  finally
    LKept.Free;
  end;
end;

// The candidates of AMids collected and searched, the rows left in FCands
// (and FUnused) with their doubts.
procedure RunUnusedLint(ALint: TUnusedLint; ANav: TPasNavigator;
  const AMids: TArray<Integer>);
begin
  GatherUnused(ALint, ANav, AMids);
  FinishUnused(ALint);
end;

// The references the candidates of AMids are searched for.
// Which library bodies can name an own declaration at all: see
// UnusedLintDemand. AAny: one does. nil when the analysis has no light unit.
function TUnusedLint.LibraryWithin(out AAny: Boolean): TArray<Boolean>;
var
  LWithin, LOwn: TArray<Boolean>;
  LAny, LMore: Boolean;
begin
  if FWithinDone then
  begin
    AAny := FWithinAny;
    Exit(FWithin);
  end;
  // Which library bodies can name an own declaration at all: a library unit
  // sees the project's units only through its own `uses` (either section),
  // so only one listing an own unit can (the declarations reached otherwise
  // - virtual, published, interface members - are not weighed). An own unit
  // that replaces a library unit (a patched copy kept in the project's tree,
  // usReplacesLibrary) does not count: the library's units were compiled
  // against the original's interface and bind nothing the copy adds - on a
  // 3,000-unit client group two such copies brought 186 library units into
  // every run. Usually no library unit lists an own unit: nothing to
  // analyze, and the candidates are not even collected for it. A library
  // unit listing such a library unit is one too (it may name an own member
  // through that unit's declarations): the closure, over the library units'
  // edges.
  LWithin := nil;
  LAny := False;
  SetLength(LWithin, FProj.ModelCount);
  SetLength(LOwn, FProj.ModelCount);
  for var LMid := 0 to FProj.ModelCount - 1 do
    LOwn[LMid] := not FProj.IsLightFile(FProj.ModelFile(LMid))
      and not ReplacesLibrary(LMid);
  repeat
    LMore := False;
    for var LMid := 0 to FProj.ModelCount - 1 do
    begin
      if LWithin[LMid] or not FProj.IsLight(LMid) then
        Continue;
      var LM := FProj.Model(LMid);
      for var LU := 0 to High(LM.UsesList) do
      begin
        var LTarget := LM.UsesList[LU].UnitId;
        if (LTarget >= 0) and (LTarget < FProj.ModelCount) and
           (LOwn[LTarget] or LWithin[LTarget]) then
        begin
          LWithin[LMid] := True;
          LAny := True;
          LMore := True;
          Break;
        end;
      end;
    end;
  until not LMore;
  FWithin := LWithin;
  FWithinAny := LAny;
  FWithinDone := True;
  AAny := LAny;
  Result := LWithin;
end;

function UnusedLintDemand(ALint: TUnusedLint; ANav: TPasNavigator;
  const AMids: TArray<Integer>): TPasDemand;
var
  LRefs: TArray<TPasExtRef>;
  LExt: TPasExtRef;
  LWithin: TArray<Boolean>;
  LAny: Boolean;
begin
  LWithin := ALint.LibraryWithin(LAny);
  if not LAny then
    Exit(Default(TPasDemand));
  ALint.CollectIfaceNames;
  for var LMid in AMids do
    if (LMid >= 0) and (LMid < ANav.Project.ModelCount) then
      ALint.Collect(LMid);
  LRefs := nil;
  for var LC in ALint.FCands do
  begin
    LExt.UnitId := LC.UnitId;
    LExt.Sym := LC.Sym;
    LRefs := LRefs + [LExt];
  end;
  Result := ANav.DemandReferencesOfAll(LRefs, LWithin);
end;

function TargetMids(const ATargets: TArray<TPasExtRef>): TArray<Integer>;
begin
  Result := nil;
  for var LT in ATargets do
  begin
    var LNew := True;
    for var LMid in Result do
      if LMid = LT.UnitId then
        LNew := False;
    if LNew then
      Result := Result + [LT.UnitId];
  end;
end;

function FindUnusedSymbols(ANav: TPasNavigator; const AMids: TArray<Integer>;
  out ASkips: TPasUnusedSkips): TArray<TPasUnusedSymbol>;
var
  LLint: TUnusedLint;
begin
  LLint := TUnusedLint.Create(ANav);
  try
    RunUnusedLint(LLint, ANav, AMids);
    Result := LLint.FCands.ToArray;
    ASkips := LLint.FSkips;
  finally
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
begin
  LLint := TUnusedLint.Create(ANav);
  try
    Result := UnusedLintDemand(LLint, ANav, AMids);
  finally
    LLint.Free;
  end;
end;

function CheckUnusedSymbols(ANav: TPasNavigator;
  const ATargets: TArray<TPasExtRef>): TArray<TPasUnusedCheck>;
var
  LLint: TUnusedLint;
  LKey: Int64;
  LSkip: TPasUnusedSkip;
  LAll, LMore: TArray<TPasExtRef>;
begin
  SetLength(Result, Length(ATargets));
  // The declarations the targets' uses sit in are weighed too, and theirs,
  // round by round: a getter is dead when its property is.
  LAll := ATargets;
  LLint := TUnusedLint.Create(ANav);
  try
    LLint.Restrict(LAll);
    GatherUnused(LLint, ANav, TargetMids(LAll));
    for var LRound := 2 to 4 do
    begin
      LMore := LLint.UnknownUsers;
      if (LMore = nil) or (Length(LAll) + Length(LMore) > 300) then
        Break;
      LAll := LAll + LMore;
      LLint.Extend(LMore);
    end;
    FinishUnused(LLint);
    for var LI := 0 to High(ATargets) do
    begin
      Result[LI].Target := ATargets[LI];
      LKey := TUnusedLint.K(ATargets[LI].UnitId, ATargets[LI].Sym);
      if LLint.FUnused.ContainsKey(LKey) then
      begin
        Result[LI].Verdict := uvUnused;
        for var LC in LLint.FCands do
          if (LC.UnitId = ATargets[LI].UnitId) and
             (LC.Sym = ATargets[LI].Sym) then
            Result[LI].Row := LC;
      end
      else if LLint.FSkipOf.TryGetValue(LKey, LSkip) then
      begin
        Result[LI].Verdict := uvSkipped;
        Result[LI].Skip := LSkip;
      end
      // A candidate (bindings counted) not left a row.
      else if LLint.FCount.ContainsKey(LKey) then
        Result[LI].Verdict := uvUsed
      else
        Result[LI].Verdict := uvNotCovered;
    end;
  finally
    LLint.Free;
  end;
end;

function DemandCheckUnusedSymbols(ANav: TPasNavigator;
  const ATargets: TArray<TPasExtRef>): TPasDemand;
var
  LLint: TUnusedLint;
begin
  LLint := TUnusedLint.Create(ANav);
  try
    LLint.Restrict(ATargets);
    Result := UnusedLintDemand(LLint, ANav, TargetMids(ATargets));
  finally
    LLint.Free;
  end;
end;

end.
