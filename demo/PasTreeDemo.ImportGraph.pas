unit PasTreeDemo.ImportGraph;

{ Find All > Import Graph: how the program takes a unit in
  (PasTree.Sema.ImportGraph). One bottom page per unit asked about.

  The tree grows BACKWARDS from the unit: its children are the units whose
  `uses` lists it and that the program reaches, theirs the units listing
  those, up to the program. Children are made when a node is expanded
  (OnInitChildren) - the paths of a real project are far too many to list.
  They come nearest to the program first, so the first child of each level
  is the shortest chain, expanded when the page opens.

  A row is the importer; its columns say how it lists its parent (interface
  or implementation `uses`), its level (the fewest steps from the program),
  and where the entry is written. A bold row is an entry every path takes - removing that
  one entry drops the unit from the program; a navy name is a bottleneck,
  a unit every path goes through. A unit already on the row's own chain is
  shown grey as "(cycle)" and not expanded. Double-click opens the entry. }

interface

uses
  System.SysUtils, System.StrUtils, System.Classes, System.UITypes,
  System.Generics.Collections, Vcl.Controls, Vcl.ComCtrls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Graphics,
  VirtualTrees, VirtualTrees.Types, VirtualTrees.BaseTree,
  PasTree.Sema.ImportGraph;

type
  // Where an edge's entry is written, read from the current analysis;
  // False when it cannot be said now (an analysis running, an edit since).
  TImportSiteFunc = reference to function(AGraph: TPasImportGraph;
    AEdge: Integer; out AFile: string; out ALine, ACol: Integer): Boolean;
  TImportNavigateProc = reference to procedure(const AFile: string;
    ALine, ACol: Integer);

  TImportGraphTab = class(TTabSheet)
  private
    FGraph: TPasImportGraph;
    FPaths: TPasImportPaths;
    FTarget: Integer;
    FRoots: TArray<Integer>;
    FTop: TPanel;
    FRootBox: TComboBox;
    FSummary: TLabel;
    FTree: TVirtualStringTree;
    FImporters: TDictionary<Integer, TArray<Integer>>;
    FSites: TDictionary<Integer, string>;
    FOnSite: TImportSiteFunc;
    FOnNavigate: TImportNavigateProc;
    function ImportersOf(AUnit: Integer): TArray<Integer>;
    function IsCycle(ANode: PVirtualNode): Boolean;
    function SiteText(AEdge: Integer): string;
    procedure SetRoot(ARoot: Integer);
    procedure UpdateSummary;
    procedure ExpandShortest;
    procedure RootChange(Sender: TObject);
    procedure TreeInitNode(Sender: TBaseVirtualTree; ParentNode,
      Node: PVirtualNode; var InitialStates: TVirtualNodeInitStates);
    procedure TreeInitChildren(Sender: TBaseVirtualTree; Node: PVirtualNode;
      var ChildCount: Cardinal);
    procedure TreeGetText(Sender: TBaseVirtualTree; Node: PVirtualNode;
      Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);
    procedure TreePaintText(Sender: TBaseVirtualTree;
      const TargetCanvas: TCanvas; Node: PVirtualNode; Column: TColumnIndex;
      TextType: TVSTTextType);
    procedure TreeDblClick(Sender: TObject);
  public
    TargetFile: string;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { Takes AGraph (owned from here on). ATarget: the unit asked about;
      ARoot: the program to start from, -1 for the first reaching it. }
    procedure Show(AGraph: TPasImportGraph; ATarget, ARoot: Integer;
      const AOnSite: TImportSiteFunc; const AOnNavigate: TImportNavigateProc);
    property Graph: TPasImportGraph read FGraph;
  end;

implementation

type
  // A node's unit and the edge from it to its parent's unit (-1: the target).
  TImportNodeData = record
    UnitIdx: Integer;
    Edge: Integer;
  end;
  PImportNodeData = ^TImportNodeData;

const
  COL_UNIT = 0;
  COL_VIA = 1;
  COL_DEPTH = 2;
  COL_SITE = 3;

{ TImportGraphTab }

constructor TImportGraphTab.Create(AOwner: TComponent);

  procedure AddColumn(const AText: string; AWidth: Integer);
  var
    LCol: TVirtualTreeColumn;
  begin
    LCol := FTree.Header.Columns.Add;
    LCol.Text := AText;
    LCol.Width := AWidth;
  end;

begin
  inherited Create(AOwner);
  FImporters := TDictionary<Integer, TArray<Integer>>.Create;
  FSites := TDictionary<Integer, string>.Create;
  FTarget := -1;

  FTop := TPanel.Create(Self);
  FTop.Parent := Self;
  FTop.Align := alTop;
  FTop.Height := 26;
  FTop.BevelOuter := bvNone;

  FRootBox := TComboBox.Create(Self);
  FRootBox.Parent := FTop;
  FRootBox.Left := 4;
  FRootBox.Top := 2;
  FRootBox.Width := 180;
  FRootBox.Style := csDropDownList;
  FRootBox.Hint := 'The program, library or package the paths start from';
  FRootBox.ShowHint := True;
  FRootBox.OnChange := RootChange;

  FSummary := TLabel.Create(Self);
  FSummary.Parent := FTop;
  FSummary.Left := 192;
  FSummary.Top := 6;
  FSummary.AutoSize := False;
  FSummary.Anchors := [akLeft, akTop, akRight];
  FSummary.Width := FTop.Width - 196;
  FSummary.EllipsisPosition := epEndEllipsis;
  FSummary.ShowHint := True;

  FTree := TVirtualStringTree.Create(Self);
  FTree.Parent := Self;
  FTree.Align := alClient;
  FTree.NodeDataSize := SizeOf(TImportNodeData);
  FTree.DefaultNodeHeight := 19;
  FTree.Header.Height := 17;
  FTree.Header.Options := FTree.Header.Options + [hoVisible, hoColumnResize];
  FTree.Header.MainColumn := COL_UNIT;
  AddColumn('Unit', 260);
  AddColumn('Listed in', 110);
  AddColumn('Level', 50);
  AddColumn('Entry', 220);
  FTree.TreeOptions.SelectionOptions :=
    [toFullRowSelect, toRightClickSelect];
  FTree.OnInitNode := TreeInitNode;
  FTree.OnInitChildren := TreeInitChildren;
  FTree.OnGetText := TreeGetText;
  FTree.OnPaintText := TreePaintText;
  FTree.OnDblClick := TreeDblClick;
end;

destructor TImportGraphTab.Destroy;
begin
  FPaths.Free;
  FGraph.Free;
  FSites.Free;
  FImporters.Free;
  inherited;
end;

procedure TImportGraphTab.Show(AGraph: TPasImportGraph; ATarget,
  ARoot: Integer; const AOnSite: TImportSiteFunc;
  const AOnNavigate: TImportNavigateProc);
begin
  FTree.Clear;
  FreeAndNil(FPaths);
  if AGraph <> FGraph then
    FGraph.Free;
  FGraph := AGraph;
  FTarget := ATarget;
  FOnSite := AOnSite;
  FOnNavigate := AOnNavigate;
  Caption := 'Import graph: ' + FGraph.Units[ATarget].Name;
  FRoots := FGraph.RootsReaching(ATarget);
  FRootBox.Items.BeginUpdate;
  try
    FRootBox.Items.Clear;
    for var LR in FRoots do
      FRootBox.Items.Add(FGraph.Units[LR].Name);
  finally
    FRootBox.Items.EndUpdate;
  end;
  FRootBox.Enabled := Length(FRoots) > 1;
  if FRoots = nil then
  begin
    FSummary.Caption := Format('No program of the analysis takes %s in.',
      [FGraph.Units[ATarget].Name]);
    FSummary.Hint := FSummary.Caption;
    Exit;
  end;
  FRootBox.ItemIndex := 0;
  for var LI := 0 to High(FRoots) do
    if FRoots[LI] = ARoot then
      FRootBox.ItemIndex := LI;
  SetRoot(FRoots[FRootBox.ItemIndex]);
end;

procedure TImportGraphTab.RootChange(Sender: TObject);
begin
  if (FRootBox.ItemIndex >= 0) and (FRootBox.ItemIndex <= High(FRoots)) then
    SetRoot(FRoots[FRootBox.ItemIndex]);
end;

procedure TImportGraphTab.SetRoot(ARoot: Integer);
begin
  FTree.Clear;
  FImporters.Clear;
  FSites.Clear;
  FreeAndNil(FPaths);
  FPaths := TPasImportPaths.Create(FGraph, ARoot, FTarget);
  UpdateSummary;
  FTree.RootNodeCount := 1;
  ExpandShortest;
end;

procedure TImportGraphTab.UpdateSummary;
var
  LChain: TArray<Integer>;
  LText, LNames: string;
begin
  LChain := FPaths.ShortestChain;
  if not FPaths.Reached then
  begin
    FSummary.Caption := 'Not reached from this program.';
    FSummary.Hint := FSummary.Caption;
    Exit;
  end;
  if LChain = nil then
    LNames := FGraph.Units[FTarget].Name
  else
  begin
    LNames := FGraph.Units[FGraph.Edges[LChain[0]].FromUnit].Name;
    for var LE in LChain do
      LNames := LNames + ' -> ' + FGraph.Units[FGraph.Edges[LE].ToUnit].Name;
  end;
  LText := Format('%d step(s): %s; %d unit(s) on its paths',
    [Length(LChain), LNames, FPaths.OnPathCount]);
  if FPaths.Bottlenecks <> nil then
  begin
    LNames := '';
    for var LU in FPaths.Bottlenecks do
      LNames := LNames + IfThen(LNames <> '', ', ') + FGraph.Units[LU].Name;
    LText := LText + '; every path goes through ' + LNames;
  end;
  if FPaths.SoleEdges <> nil then
  begin
    LNames := '';
    for var LE in FPaths.SoleEdges do
      LNames := LNames + IfThen(LNames <> '', ', ') +
        FGraph.Units[FGraph.Edges[LE].FromUnit].Name + ' -> ' +
        FGraph.Units[FGraph.Edges[LE].ToUnit].Name;
    LText := LText + '; removing one of these entries drops it: ' + LNames;
  end
  else if LChain <> nil then
    LText := LText + '; no single entry removes it';
  FSummary.Caption := LText;
  FSummary.Hint := LText;
end;

// The first child of every level is the importer nearest the program: down
// that line is the shortest chain, opened to the program itself.
procedure TImportGraphTab.ExpandShortest;
var
  LNode: PVirtualNode;
begin
  LNode := FTree.GetFirst;
  while LNode <> nil do
  begin
    FTree.Expanded[LNode] := True;
    if not FTree.HasChildren[LNode] then
      Break;
    LNode := FTree.GetFirstChild(LNode);
    if (LNode = nil) or IsCycle(LNode) then
      Break;
  end;
  if LNode <> nil then
  begin
    FTree.FocusedNode := LNode;
    FTree.Selected[LNode] := True;
    FTree.ScrollIntoView(LNode, False);
  end;
end;

function TImportGraphTab.ImportersOf(AUnit: Integer): TArray<Integer>;
begin
  if not FImporters.TryGetValue(AUnit, Result) then
  begin
    Result := FPaths.Importers(AUnit);
    FImporters.Add(AUnit, Result);
  end;
end;

// The node's unit is already on the chain above it.
function TImportGraphTab.IsCycle(ANode: PVirtualNode): Boolean;
var
  LUnit: Integer;
  LUp: PVirtualNode;
begin
  LUnit := PImportNodeData(FTree.GetNodeData(ANode)).UnitIdx;
  LUp := FTree.NodeParent[ANode];
  while LUp <> nil do
  begin
    if PImportNodeData(FTree.GetNodeData(LUp)).UnitIdx = LUnit then
      Exit(True);
    LUp := FTree.NodeParent[LUp];
  end;
  Result := False;
end;

procedure TImportGraphTab.TreeInitNode(Sender: TBaseVirtualTree; ParentNode,
  Node: PVirtualNode; var InitialStates: TVirtualNodeInitStates);
var
  LData: PImportNodeData;
  LIn: TArray<Integer>;
begin
  LData := PImportNodeData(Sender.GetNodeData(Node));
  if ParentNode = nil then
  begin
    LData.UnitIdx := FTarget;
    LData.Edge := -1;
  end
  else
  begin
    LIn := ImportersOf(PImportNodeData(Sender.GetNodeData(ParentNode)).UnitIdx);
    LData.Edge := LIn[Node.Index];
    LData.UnitIdx := FGraph.Edges[LData.Edge].FromUnit;
  end;
  if (LData.UnitIdx <> FPaths.Root) and not IsCycle(Node) and
     (ImportersOf(LData.UnitIdx) <> nil) then
    Include(InitialStates, ivsHasChildren);
end;

procedure TImportGraphTab.TreeInitChildren(Sender: TBaseVirtualTree;
  Node: PVirtualNode; var ChildCount: Cardinal);
begin
  ChildCount := Length(ImportersOf(
    PImportNodeData(Sender.GetNodeData(Node)).UnitIdx));
end;

function TImportGraphTab.SiteText(AEdge: Integer): string;
var
  LFile: string;
  LLine, LCol: Integer;
begin
  if FSites.TryGetValue(AEdge, Result) then
    Exit;
  Result := '';
  if Assigned(FOnSite) and FOnSite(FGraph, AEdge, LFile, LLine, LCol) then
  begin
    Result := Format('%s:%d', [ExtractFileName(LFile), LLine]);
    FSites.Add(AEdge, Result);
  end;
end;

procedure TImportGraphTab.TreeGetText(Sender: TBaseVirtualTree;
  Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType;
  var CellText: string);
var
  LData: PImportNodeData;
  LUnit: TPasImportUnit;
begin
  CellText := '';
  LData := PImportNodeData(Sender.GetNodeData(Node));
  if (LData = nil) or (FPaths = nil) then
    Exit;
  LUnit := FGraph.Units[LData.UnitIdx];
  case Column of
    COL_UNIT:
      begin
        CellText := LUnit.Name;
        if LUnit.IsRoot then
          CellText := CellText + ' (program)';
        if IsCycle(Node) then
          CellText := CellText + ' (cycle)';
      end;
    COL_VIA:
      if LData.Edge >= 0 then
        CellText := IfThen(FGraph.Edges[LData.Edge].InImpl, 'implementation',
          'interface');
    COL_DEPTH:
      CellText := IntToStr(FPaths.Depth(LData.UnitIdx));
    COL_SITE:
      if LData.Edge >= 0 then
        CellText := SiteText(LData.Edge);
  end;
end;

procedure TImportGraphTab.TreePaintText(Sender: TBaseVirtualTree;
  const TargetCanvas: TCanvas; Node: PVirtualNode; Column: TColumnIndex;
  TextType: TVSTTextType);
var
  LData: PImportNodeData;
begin
  LData := PImportNodeData(Sender.GetNodeData(Node));
  if (LData = nil) or (FPaths = nil) then
    Exit;
  if (LData.Edge >= 0) and FPaths.IsSole(LData.Edge) then
    TargetCanvas.Font.Style := TargetCanvas.Font.Style + [fsBold];
  if vsSelected in Node.States then
    Exit;
  if IsCycle(Node) then
    TargetCanvas.Font.Color := clGrayText
  else if (Column = COL_UNIT) and FPaths.IsBottleneck(LData.UnitIdx) then
    TargetCanvas.Font.Color := clNavy
  else if Column in [COL_DEPTH, COL_SITE] then
    TargetCanvas.Font.Color := TColor($00606060);
end;

procedure TImportGraphTab.TreeDblClick(Sender: TObject);
var
  LData: PImportNodeData;
  LFile: string;
  LLine, LCol: Integer;
begin
  if (FTree.FocusedNode = nil) or not Assigned(FOnNavigate) then
    Exit;
  LData := PImportNodeData(FTree.GetNodeData(FTree.FocusedNode));
  if LData = nil then
    Exit;
  if (LData.Edge >= 0) and Assigned(FOnSite) and
     FOnSite(FGraph, LData.Edge, LFile, LLine, LCol) then
    FOnNavigate(LFile, LLine, LCol)
  else
    // The target itself, or an entry that cannot be placed now: the unit.
    FOnNavigate(FGraph.Units[LData.UnitIdx].FilePath, 1, 1);
end;

end.
