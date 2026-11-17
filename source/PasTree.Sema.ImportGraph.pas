unit PasTree.Sema.ImportGraph;

{ The unit import graph: how a unit gets into a program.

  A unit is linked into a program when the program's `uses` closure reaches
  it - through an interface or an implementation `uses` entry alike, and
  often through a chain nobody wrote on purpose (a form unit that lists a
  data module that lists a reporting library). The question a host asks is
  "through which units does X come in", and its answer is every path
  Root -> ... -> X of the `uses` graph: too many to list, so the host shows
  them as a tree grown backwards from X, a level at a time (Importers), and
  this unit says which of the steps are forced.

  TPasImportGraph is a SNAPSHOT of one analysis' graph: units by file, an edge
  per resolved `uses` entry (dcc's own resolution, conditionals decided - an
  entry in a branch not compiled is no edge). It holds no model id and no
  reference to the project, so a host may keep it across a reanalysis and
  rebuild it when it wants a fresh one. An edge's position is asked of a
  project when shown (EdgeSite): reading every entry's position up front
  would rehydrate every demoted model of the analysis.

  TPasImportPaths answers for one root and one target:
  - Depth: the fewest `uses` steps from the root (-1: not reached);
  - Importers: the edges into a unit from units the root reaches - every one
    of them is on some path to the target, since the unit reaches it; the
    nearest to the root first, so following the first importer up is the
    shortest chain;
  - IsBottleneck: a unit every path goes through (a dominator of the target);
  - IsSole: an edge every path takes - removing that one `uses` entry drops
    the target from the program (unless another configuration lists it).
  Both are on the shortest chain, so each is checked by one walk with the
  candidate taken out: a chain is short, the walks are linear. }

interface

uses
  System.Generics.Collections,
  PasTree.Sema.Project;

type
  TPasImportUnit = record
    Name: string;       // the file name without its extension
    FilePath: string;
    IsRoot: Boolean;    // a program, a library or a package
    Light: Boolean;     // read light (light mode): a library unit
  end;

  TPasImportEdge = record
    FromUnit, ToUnit: Integer;   // indexes of TPasImportGraph.Units
    InImpl: Boolean;             // a unit's implementation `uses` (a root's: no)
    UsesIdx: Integer;            // the entry's index in the importer's list
    Written: string;             // the entry's name as written (`Forms`)
  end;

  TPasImportGraph = class
  private
    FUnits: TArray<TPasImportUnit>;
    FEdges: TArray<TPasImportEdge>;
    FOutStart, FOutEdges: TArray<Integer>;   // edges by FromUnit
    FInStart, FInEdges: TArray<Integer>;     // edges by ToUnit
    FByFile: TDictionary<string, Integer>;
    FByName: TDictionary<string, Integer>;
    function GetUnit(AIdx: Integer): TPasImportUnit;
    function GetEdge(AIdx: Integer): TPasImportEdge;
    procedure BuildIndex;
  public
    { Every model of AProject a unit, every resolved `uses` entry an edge.
      Light mode: the units nobody loaded are not in it - a host wanting the
      whole closure meets TPasWorkspace.EnsureClosure first (as
      TPasWorkspace.ImportGraph does). }
    constructor Create(AProject: TPasSemaProject);
    destructor Destroy; override;
    function UnitCount: Integer;
    function EdgeCount: Integer;
    property Units[AIdx: Integer]: TPasImportUnit read GetUnit;
    property Edges[AIdx: Integer]: TPasImportEdge read GetEdge;
    function OutEdges(AUnit: Integer): TArray<Integer>;
    function InEdges(AUnit: Integer): TArray<Integer>;
    // A unit by its file path, else by its name; -1 when none.
    function UnitOf(const AFileOrName: string): Integer;
    // The programs, libraries and packages, by name.
    function Roots: TArray<Integer>;
    // The units AUnit reaches through `uses` (itself included).
    function Reach(AUnit: Integer): TArray<Boolean>;
    // The roots whose closure has ATarget, by name.
    function RootsReaching(ATarget: Integer): TArray<Integer>;
    { Where AEdge's entry is written, read from AProject - the analysis the
      graph was taken of or a later one. False when the importer is not in
      AProject or its entry no longer names the same unit (an edit since). }
    function EdgeSite(AProject: TPasSemaProject; AEdge: Integer;
      out AFilePath: string; out ALine, ACol: Integer): Boolean;
  end;

  TPasImportPaths = class
  private
    FGraph: TPasImportGraph;
    FRoot, FTarget: Integer;
    FDepth: TArray<Integer>;
    FParentEdge: TArray<Integer>;
    FChain: TArray<Integer>;
    FBottleneck: TArray<Boolean>;
    FOnPathFlags: TArray<Boolean>;
    FSole: TDictionary<Integer, Boolean>;
    FOnPath: Integer;
    function ReachesWithout(ASkipUnit, ASkipEdge: Integer): Boolean;
  public
    // The graph is the caller's and must outlive this view.
    constructor Create(AGraph: TPasImportGraph; ARoot, ATarget: Integer);
    destructor Destroy; override;
    property Graph: TPasImportGraph read FGraph;
    property Root: Integer read FRoot;
    property Target: Integer read FTarget;
    // The root's closure has the target.
    function Reached: Boolean;
    function Depth(AUnit: Integer): Integer;
    // Reached from the root and reaching the target.
    function OnPath(AUnit: Integer): Boolean;
    // The units on a path, the root and the target included.
    property OnPathCount: Integer read FOnPath;
    { The edges into AUnit (on a path) from units the root reaches: by the
      importer's Depth, then its name. }
    function Importers(AUnit: Integer): TArray<Integer>;
    // The edges of one shortest path, from the root to the target.
    property ShortestChain: TArray<Integer> read FChain;
    // Every path goes through AUnit - never the root or the target.
    function IsBottleneck(AUnit: Integer): Boolean;
    // The bottlenecks, the root's side first.
    function Bottlenecks: TArray<Integer>;
    // Every path takes AEdge.
    function IsSole(AEdge: Integer): Boolean;
    // The sole edges, the root's side first.
    function SoleEdges: TArray<Integer>;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.Generics.Defaults,
  PasTree.Ast,
  PasTree.Sema.Model;

{ TPasImportGraph }

function IsRootModel(AProject: TPasSemaProject; AMid: Integer): Boolean;
var
  LM: TPasSemaModel;
  LC: Integer;
  LExt: string;
begin
  LM := AProject.Model(AMid);
  if (LM <> nil) and (Length(LM.Tree.Nodes) > 0) then
  begin
    if LM.Tree.Nodes[0].Kind in [nkProgram, nkLibrary, nkPackage] then
      Exit(True);
    if LM.Tree.Nodes[0].Kind = nkUnit then
      Exit(False);
    LC := LM.Tree.Nodes[0].FirstChild;
    while LC <> NIL_NODE do
    begin
      if LM.Tree.Nodes[LC].Kind in [nkProgram, nkLibrary, nkPackage] then
        Exit(True);
      if LM.Tree.Nodes[LC].Kind = nkUnit then
        Exit(False);
      LC := LM.Tree.Nodes[LC].NextSibling;
    end;
  end;
  LExt := LowerCase(ExtractFileExt(AProject.ModelFile(AMid)));
  Result := (LExt = '.dpr') or (LExt = '.dpk');
end;

constructor TPasImportGraph.Create(AProject: TPasSemaProject);
var
  LN, LTo: Integer;
  LM: TPasSemaModel;
  LSeen: TDictionary<Int64, Boolean>;
  LList: TList<TPasImportEdge>;
  LE: TPasImportEdge;
begin
  inherited Create;
  FByFile := TDictionary<string, Integer>.Create;
  FByName := TDictionary<string, Integer>.Create;
  LN := AProject.ModelCount;
  SetLength(FUnits, LN);
  for var LMid := 0 to LN - 1 do
  begin
    FUnits[LMid].FilePath := AProject.ModelFile(LMid);
    FUnits[LMid].Name := TPath.GetFileNameWithoutExtension(
      FUnits[LMid].FilePath);
    FUnits[LMid].IsRoot := IsRootModel(AProject, LMid);
    FUnits[LMid].Light := AProject.IsLight(LMid);
  end;
  LSeen := TDictionary<Int64, Boolean>.Create;
  LList := TList<TPasImportEdge>.Create;
  try
    for var LMid := 0 to LN - 1 do
    begin
      LM := AProject.Model(LMid);
      if LM = nil then
        Continue;
      for var LU := 0 to High(LM.UsesList) do
      begin
        LTo := LM.UsesList[LU].UnitId;
        if (LTo < 0) or (LTo >= LN) or (LTo = LMid) then
          Continue;
        // One edge per pair: dcc refuses a unit listed twice, but an entry
        // the resolver saw twice (an include) must not double a path.
        if not LSeen.TryAdd(Int64(LMid) shl 32 or LTo, True) then
          Continue;
        LE.FromUnit := LMid;
        LE.ToUnit := LTo;
        // A program's, a library's or a package's `uses` has no sections
        // (the resolver files it under the module's body).
        LE.InImpl := LM.UsesList[LU].InImpl and not FUnits[LMid].IsRoot;
        LE.UsesIdx := LU;
        LE.Written := LM.UsesList[LU].NameFull;
        LList.Add(LE);
      end;
    end;
    FEdges := LList.ToArray;
  finally
    LList.Free;
    LSeen.Free;
  end;
  BuildIndex;
end;

destructor TPasImportGraph.Destroy;
begin
  FByName.Free;
  FByFile.Free;
  inherited;
end;

procedure TPasImportGraph.BuildIndex;
var
  LN: Integer;
  LFillOut, LFillIn: TArray<Integer>;
begin
  LN := Length(FUnits);
  for var LU := 0 to LN - 1 do
  begin
    FByFile.AddOrSetValue(LowerCase(FUnits[LU].FilePath), LU);
    FByName.TryAdd(LowerCase(FUnits[LU].Name), LU);
  end;
  SetLength(FOutStart, LN + 1);
  SetLength(FInStart, LN + 1);
  for var LE := 0 to High(FEdges) do
  begin
    Inc(FOutStart[FEdges[LE].FromUnit + 1]);
    Inc(FInStart[FEdges[LE].ToUnit + 1]);
  end;
  for var LI := 1 to LN do
  begin
    Inc(FOutStart[LI], FOutStart[LI - 1]);
    Inc(FInStart[LI], FInStart[LI - 1]);
  end;
  SetLength(FOutEdges, Length(FEdges));
  SetLength(FInEdges, Length(FEdges));
  LFillOut := Copy(FOutStart);
  LFillIn := Copy(FInStart);
  for var LE := 0 to High(FEdges) do
  begin
    FOutEdges[LFillOut[FEdges[LE].FromUnit]] := LE;
    Inc(LFillOut[FEdges[LE].FromUnit]);
    FInEdges[LFillIn[FEdges[LE].ToUnit]] := LE;
    Inc(LFillIn[FEdges[LE].ToUnit]);
  end;
end;

function TPasImportGraph.UnitCount: Integer;
begin
  Result := Length(FUnits);
end;

function TPasImportGraph.EdgeCount: Integer;
begin
  Result := Length(FEdges);
end;

function TPasImportGraph.GetUnit(AIdx: Integer): TPasImportUnit;
begin
  Result := FUnits[AIdx];
end;

function TPasImportGraph.GetEdge(AIdx: Integer): TPasImportEdge;
begin
  Result := FEdges[AIdx];
end;

function TPasImportGraph.OutEdges(AUnit: Integer): TArray<Integer>;
begin
  Result := Copy(FOutEdges, FOutStart[AUnit],
    FOutStart[AUnit + 1] - FOutStart[AUnit]);
end;

function TPasImportGraph.InEdges(AUnit: Integer): TArray<Integer>;
begin
  Result := Copy(FInEdges, FInStart[AUnit],
    FInStart[AUnit + 1] - FInStart[AUnit]);
end;

function TPasImportGraph.UnitOf(const AFileOrName: string): Integer;
begin
  if not FByFile.TryGetValue(LowerCase(AFileOrName), Result) and
     not FByName.TryGetValue(LowerCase(AFileOrName), Result) then
    Result := -1;
end;

function TPasImportGraph.Roots: TArray<Integer>;
begin
  Result := nil;
  for var LU := 0 to High(FUnits) do
    if FUnits[LU].IsRoot then
      Result := Result + [LU];
  TArray.Sort<Integer>(Result, TComparer<Integer>.Construct(
    function(const A, B: Integer): Integer
    begin
      Result := CompareText(FUnits[A].Name, FUnits[B].Name);
      if Result = 0 then
        Result := A - B;
    end));
end;

function TPasImportGraph.Reach(AUnit: Integer): TArray<Boolean>;
var
  LQueue: TArray<Integer>;
  LAt, LCount, LU, LTo: Integer;
begin
  SetLength(Result, Length(FUnits));
  SetLength(LQueue, Length(FUnits));
  Result[AUnit] := True;
  LQueue[0] := AUnit;
  LCount := 1;
  LAt := 0;
  while LAt < LCount do
  begin
    LU := LQueue[LAt];
    Inc(LAt);
    for var LK := FOutStart[LU] to FOutStart[LU + 1] - 1 do
    begin
      LTo := FEdges[FOutEdges[LK]].ToUnit;
      if not Result[LTo] then
      begin
        Result[LTo] := True;
        LQueue[LCount] := LTo;
        Inc(LCount);
      end;
    end;
  end;
end;

function TPasImportGraph.RootsReaching(ATarget: Integer): TArray<Integer>;
begin
  Result := nil;
  for var LR in Roots do
    if Reach(LR)[ATarget] then
      Result := Result + [LR];
end;

function TPasImportGraph.EdgeSite(AProject: TPasSemaProject; AEdge: Integer;
  out AFilePath: string; out ALine, ACol: Integer): Boolean;
var
  LMid, LTo: Integer;
  LM: TPasSemaModel;
  LRef: TPasUsesRef;
begin
  AFilePath := '';
  ALine := 0;
  ACol := 0;
  Result := False;
  if (AProject = nil) or (AEdge < 0) or (AEdge > High(FEdges)) then
    Exit;
  LMid := AProject.ModelIdOf(FUnits[FEdges[AEdge].FromUnit].FilePath);
  if LMid < 0 then
    Exit;
  LM := AProject.Model(LMid);
  if (LM = nil) or (FEdges[AEdge].UsesIdx > High(LM.UsesList)) then
    Exit;
  LRef := LM.UsesList[FEdges[AEdge].UsesIdx];
  LTo := LRef.UnitId;
  if (LTo < 0) or (LTo >= AProject.ModelCount) or
     not SameText(AProject.ModelFile(LTo),
       FUnits[FEdges[AEdge].ToUnit].FilePath) then
    Exit;
  Result := AProject.NodeSite(LMid, LRef.NameNode, AFilePath, ALine, ACol);
end;

{ TPasImportPaths }

constructor TPasImportPaths.Create(AGraph: TPasImportGraph; ARoot,
  ATarget: Integer);
var
  LN, LAt, LCount, LU, LTo, LE: Integer;
  LQueue: TArray<Integer>;
begin
  inherited Create;
  FGraph := AGraph;
  FRoot := ARoot;
  FTarget := ATarget;
  FSole := TDictionary<Integer, Boolean>.Create;
  LN := AGraph.UnitCount;
  SetLength(FDepth, LN);
  SetLength(FParentEdge, LN);
  SetLength(FBottleneck, LN);
  for var LI := 0 to LN - 1 do
  begin
    FDepth[LI] := -1;
    FParentEdge[LI] := -1;
  end;
  if (ARoot < 0) or (ARoot >= LN) or (ATarget < 0) or (ATarget >= LN) then
    Exit;
  // Breadth first from the root: Depth and a shortest-path tree.
  SetLength(LQueue, LN);
  FDepth[ARoot] := 0;
  LQueue[0] := ARoot;
  LCount := 1;
  LAt := 0;
  while LAt < LCount do
  begin
    LU := LQueue[LAt];
    Inc(LAt);
    for var LK := AGraph.FOutStart[LU] to AGraph.FOutStart[LU + 1] - 1 do
    begin
      LE := AGraph.FOutEdges[LK];
      LTo := AGraph.FEdges[LE].ToUnit;
      if FDepth[LTo] < 0 then
      begin
        FDepth[LTo] := FDepth[LU] + 1;
        FParentEdge[LTo] := LE;
        LQueue[LCount] := LTo;
        Inc(LCount);
      end;
    end;
  end;
  if FDepth[ATarget] < 0 then
    Exit;
  // Backwards from the target over the reached units: who is on a path.
  SetLength(FOnPathFlags, LN);
  FOnPathFlags[ATarget] := True;
  LQueue[0] := ATarget;
  LCount := 1;
  LAt := 0;
  while LAt < LCount do
  begin
    LU := LQueue[LAt];
    Inc(LAt);
    for var LK := AGraph.FInStart[LU] to AGraph.FInStart[LU + 1] - 1 do
    begin
      LTo := AGraph.FEdges[AGraph.FInEdges[LK]].FromUnit;
      if (FDepth[LTo] >= 0) and not FOnPathFlags[LTo] then
      begin
        FOnPathFlags[LTo] := True;
        LQueue[LCount] := LTo;
        Inc(LCount);
      end;
    end;
  end;
  FOnPath := LCount;
  // The shortest chain, root first.
  LU := ATarget;
  while LU <> ARoot do
  begin
    FChain := [FParentEdge[LU]] + FChain;
    LU := AGraph.FEdges[FParentEdge[LU]].FromUnit;
  end;
  // Whatever every path takes is on this chain: try each without it.
  for var LI := 0 to High(FChain) do
  begin
    LE := FChain[LI];
    if not ReachesWithout(-1, LE) then
      FSole.Add(LE, True);
    LU := AGraph.FEdges[LE].ToUnit;
    if (LU <> ATarget) and not ReachesWithout(LU, -1) then
      FBottleneck[LU] := True;
  end;
end;

destructor TPasImportPaths.Destroy;
begin
  FSole.Free;
  inherited;
end;

function TPasImportPaths.ReachesWithout(ASkipUnit, ASkipEdge: Integer): Boolean;
var
  LSeen: TArray<Boolean>;
  LQueue: TArray<Integer>;
  LAt, LCount, LU, LTo, LE: Integer;
begin
  SetLength(LSeen, FGraph.UnitCount);
  SetLength(LQueue, FGraph.UnitCount);
  LSeen[FRoot] := True;
  LQueue[0] := FRoot;
  LCount := 1;
  LAt := 0;
  while LAt < LCount do
  begin
    LU := LQueue[LAt];
    Inc(LAt);
    for var LK := FGraph.FOutStart[LU] to FGraph.FOutStart[LU + 1] - 1 do
    begin
      LE := FGraph.FOutEdges[LK];
      if LE = ASkipEdge then
        Continue;
      LTo := FGraph.FEdges[LE].ToUnit;
      if (LTo = ASkipUnit) or LSeen[LTo] then
        Continue;
      if LTo = FTarget then
        Exit(True);
      LSeen[LTo] := True;
      LQueue[LCount] := LTo;
      Inc(LCount);
    end;
  end;
  Result := False;
end;

function TPasImportPaths.Reached: Boolean;
begin
  Result := (FTarget >= 0) and (FTarget < Length(FDepth)) and
    (FDepth[FTarget] >= 0);
end;

function TPasImportPaths.Depth(AUnit: Integer): Integer;
begin
  if (AUnit < 0) or (AUnit > High(FDepth)) then
    Exit(-1);
  Result := FDepth[AUnit];
end;

function TPasImportPaths.OnPath(AUnit: Integer): Boolean;
begin
  Result := (AUnit >= 0) and (AUnit <= High(FOnPathFlags)) and
    FOnPathFlags[AUnit];
end;

function TPasImportPaths.Importers(AUnit: Integer): TArray<Integer>;
var
  LG: TPasImportGraph;
begin
  Result := nil;
  if not Reached or (Depth(AUnit) < 0) then
    Exit;
  LG := FGraph;
  for var LE in LG.InEdges(AUnit) do
    if FDepth[LG.FEdges[LE].FromUnit] >= 0 then
      Result := Result + [LE];
  TArray.Sort<Integer>(Result, TComparer<Integer>.Construct(
    function(const A, B: Integer): Integer
    var
      LA, LB: Integer;
    begin
      LA := LG.FEdges[A].FromUnit;
      LB := LG.FEdges[B].FromUnit;
      Result := FDepth[LA] - FDepth[LB];
      if Result = 0 then
        Result := CompareText(LG.FUnits[LA].Name, LG.FUnits[LB].Name);
      if Result = 0 then
        Result := LA - LB;
    end));
end;

function TPasImportPaths.IsBottleneck(AUnit: Integer): Boolean;
begin
  Result := (AUnit >= 0) and (AUnit <= High(FBottleneck)) and
    FBottleneck[AUnit];
end;

function TPasImportPaths.Bottlenecks: TArray<Integer>;
begin
  Result := nil;
  for var LE in FChain do
    if FBottleneck[FGraph.FEdges[LE].ToUnit] then
      Result := Result + [FGraph.FEdges[LE].ToUnit];
end;

function TPasImportPaths.IsSole(AEdge: Integer): Boolean;
begin
  Result := FSole.ContainsKey(AEdge);
end;

function TPasImportPaths.SoleEdges: TArray<Integer>;
begin
  Result := nil;
  for var LE in FChain do
    if FSole.ContainsKey(LE) then
      Result := Result + [LE];
end;

end.
