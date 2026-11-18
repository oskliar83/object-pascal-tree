unit PasTree.Dcp;

{
  The units a compiled package's .dcp holds (docs/dcu-reader.md, sec.
  "Units inside a .dcp").

  A .dcp is a header, the package's .bpl name and its `requires` list, a
  directory of its units, and then each unit's .dcu image in full, one after
  another in directory order - the first right after the directory, each
  exactly as long as the size its own .dcu header states, the last ending
  the file (every .dcp of Delphi 11, 12 and 13, all platforms: 2,419 files,
  46,497 units). So a unit inside one is read by PasTree.Dcu unchanged, from
  its offset.

  A unit inside a .dcp is addressed by a path that is no file:
  `<dir>\<package>.dcp\<unit>.dcu` (DcpMemberPath). TPasSourceManager hands
  that path out like any .dcu path (IsDcuPath holds for it); LoadDcu reads
  it from the .dcp, DcuSiblingPath finds the units it imports.

  Which .dcp files a unit is taken from is the source manager's business
  (TPasSourceManager.SetPackages): dcc takes a unit from a package only when
  the package is linked - a package's `requires`, transitively, or a
  program's -LU - and never from a .dcp that merely lies on the search path
  (spec 1.2.1).
}

interface

uses
  System.SysUtils;

type
  EPasDcpError = class(Exception);

  { One unit of a .dcp's directory: where its .dcu image starts and how long
    it is. Flags is the directory's last field, read as is (3 marks the
    package's own unit, which the directory names with a leading dot and
    TPasDcpPackage leaves out). }
  TPasDcpEntry = record
    UnitName: string;
    Offset: Int64;
    Size: Integer;
    Flags: Cardinal;
  end;

  { A .dcp's header and directory - not its images, which ReadDcpMember
    reads one at a time. }
  TPasDcpPackage = class
  private
    FFileName: string;
    FBplName: string;
    FRequires: TArray<string>;
    FUnits: TArray<TPasDcpEntry>;
  public
    { The entry of AUnitName (case-insensitive), -1 when the package does not
      contain it. }
    function IndexOf(const AUnitName: string): Integer;
    property FileName: string read FFileName;
    { The .bpl the package builds (`vclsmp370.bpl`). }
    property BplName: string read FBplName;
    { The packages its `requires` names, as written there (`vcl`, `rtl`). }
    property Requires: TArray<string> read FRequires;
    { Every unit it contains, in directory order; the package's own unit
      (`.VclSmp`) is not one. }
    property Units: TArray<TPasDcpEntry> read FUnits;
  end;

{ Reads APath's header and directory; raises EPasDcpError when it is not a
  .dcp this reader understands. The caller owns the result. }
function ReadDcpPackage(const APath: string): TPasDcpPackage;

{ The same, shared: read once per file and stamp (write time and size), nil
  when the file cannot be read (DcpPackageError says why). Owned by this
  unit and never freed before finalization - a package read again after a
  rebuild leaves the old object alive for a caller still holding it. }
function DcpPackage(const APath: string): TPasDcpPackage;
function DcpPackageError(const APath: string): string;

{ `<ADcpPath>\<AUnitName>.dcu`: the path of a unit inside a .dcp. }
function DcpMemberPath(const ADcpPath, AUnitName: string): string;

{ True when APath has the shape DcpMemberPath gives (a `.dcu` whose
  directory part ends in `.dcp`) - syntax only, nothing is read. }
function SplitDcpMemberPath(const APath: string;
  out ADcpPath, AUnitName: string): Boolean;

{ The .dcu image of the unit APath (DcpMemberPath's shape) names; raises
  EPasDcpError when the .dcp cannot be read or does not contain the unit. }
function ReadDcpMember(const APath: string): TBytes;

{ A .dcu file, or a unit inside a .dcp that contains it. }
function DcuPathExists(const APath: string): Boolean;

{ The file whose write time and size stand for APath: the .dcp of a unit
  inside one, APath itself otherwise. }
function DcuStampPath(const APath: string): string;

{ The .dcu of AUnitName for a compiled unit at AFromPath that imports it,
  '' when none is at hand. For a .dcu file: the .dcu beside it. For a unit
  inside a .dcp: the same .dcp, then a .dcu beside the .dcp, then the
  packages its `requires` names, transitively, as `.dcp` files beside it -
  where dcc's library directory keeps them. }
function DcuSiblingPath(const AFromPath, AUnitName: string): string;

implementation

uses
  System.Classes,
  System.IOUtils,
  System.Generics.Collections;

const
  cDirEntryFixed = 60;          // offset (4) + 52 bytes + flags (4), then two names
  cMaxDirectory = 64 * 1024 * 1024;

function TPasDcpPackage.IndexOf(const AUnitName: string): Integer;
begin
  for Result := 0 to High(FUnits) do
    if SameText(FUnits[Result].UnitName, AUnitName) then
      Exit;
  Result := -1;
end;

// The header and directory, from the first ABytes of a file of AFileSize
// bytes. Layout (Win32 `PKX0`, Win64 `PKX1` with the units' .dcu magic
// after it, and an 8-byte image base):
//   magic, [dcu magic], requires count, unit count, directory size,
//   directory offset, image base, 9, length of the .bpl name,
//   the .bpl name and each required package as zero-terminated strings,
//   then at the directory offset one entry per unit: its image's offset
//   (4), 52 bytes, flags (4), the unit's name and its namespace, both
//   zero-terminated.
procedure ParseDirectory(const ABytes: TBytes; AFileSize: Int64;
  APkg: TPasDcpPackage);
var
  LPos, LBase, LImageBase: Integer;
  LReqCount, LUnitCount, LDirSize, LDirOfs: Cardinal;
  LIdx, LCount: Integer;
  LEntry: TPasDcpEntry;
  LUnits: TList<TPasDcpEntry>;
  LName: string;

  procedure Fail(const AWhat: string);
  begin
    raise EPasDcpError.CreateFmt('%s: %s', [TPath.GetFileName(APkg.FFileName), AWhat]);
  end;

  function U32(AAt: Integer): Cardinal;
  begin
    if (AAt < 0) or (AAt + 4 > Length(ABytes)) then
      Fail('the directory ends early');
    Result := PCardinal(@ABytes[AAt])^;
  end;

  function CStr: string;
  var
    LEnd: Integer;
  begin
    LEnd := LPos;
    while (LEnd < Length(ABytes)) and (ABytes[LEnd] <> 0) do
      Inc(LEnd);
    if LEnd >= Length(ABytes) then
      Fail('a name runs past the directory');
    Result := TEncoding.UTF8.GetString(ABytes, LPos, LEnd - LPos);
    LPos := LEnd + 1;
  end;

begin
  if (Length(ABytes) < 4) or (ABytes[0] <> Ord('P')) or
     (ABytes[1] <> Ord('K')) or (ABytes[2] <> Ord('X')) or
     not (ABytes[3] in [Ord('0'), Ord('1')]) then
    Fail('not a .dcp (no PKX0/PKX1 magic)');
  // PKX1 (64-bit targets) puts its units' .dcu magic after its own and
  // stores an 8-byte image base.
  if ABytes[3] = Ord('1') then
  begin
    LBase := 8;
    LImageBase := 8;
  end
  else
  begin
    LBase := 4;
    LImageBase := 4;
  end;
  LReqCount := U32(LBase);
  LUnitCount := U32(LBase + 4);
  LDirSize := U32(LBase + 8);
  LDirOfs := U32(LBase + 12);
  if (Int64(LDirOfs) + LDirSize > Length(ABytes)) or
     (Int64(LDirOfs) + LDirSize > AFileSize) then
    Fail('the directory lies past the end of the file');
  // Every count is bounded by the bytes that would have to hold it.
  if (LReqCount > LDirOfs) or (Int64(LUnitCount) * cDirEntryFixed > LDirSize) then
    Fail('a count larger than its table');
  LPos := LBase + 24 + LImageBase;
  if LPos > Integer(LDirOfs) then
    Fail('the header overlaps the directory');
  APkg.FBplName := CStr;
  SetLength(APkg.FRequires, LReqCount);
  for LIdx := 0 to Integer(LReqCount) - 1 do
    APkg.FRequires[LIdx] := CStr;
  LPos := LDirOfs;
  LCount := LUnitCount;
  LUnits := TList<TPasDcpEntry>.Create;
  try
    for LIdx := 0 to LCount - 1 do
    begin
      LEntry := Default(TPasDcpEntry);
      LEntry.Offset := U32(LPos);
      LEntry.Flags := U32(LPos + cDirEntryFixed - 4);
      Inc(LPos, cDirEntryFixed);
      LName := CStr;
      CStr;                                  // its namespace: Vcl.Samples
      if LPos > Integer(LDirOfs + LDirSize) then
        Fail('an entry runs past the directory');
      LEntry.UnitName := LName;
      if (LEntry.Offset < LDirOfs + LDirSize) or (LEntry.Offset >= AFileSize) then
        Fail(Format('unit %s starts outside the file', [LName]));
      if (LUnits.Count > 0) and (LEntry.Offset <= LUnits.Last.Offset) then
        Fail(Format('unit %s is out of order', [LName]));
      // The previous image ends where this one starts.
      if LUnits.Count > 0 then
      begin
        LEntry.Size := 0;
        var LPrev := LUnits.Last;
        LPrev.Size := LEntry.Offset - LPrev.Offset;
        LUnits[LUnits.Count - 1] := LPrev;
      end;
      LUnits.Add(LEntry);
    end;
    if LUnits.Count > 0 then
    begin
      var LLast := LUnits.Last;
      LLast.Size := AFileSize - LLast.Offset;
      LUnits[LUnits.Count - 1] := LLast;
    end;
    // The package's own unit (`.VclSmp`) is no unit a `uses` can name.
    for LIdx := LUnits.Count - 1 downto 0 do
      if LUnits[LIdx].UnitName.StartsWith('.') or (LUnits[LIdx].UnitName = '') then
        LUnits.Delete(LIdx);
    APkg.FUnits := LUnits.ToArray;
  finally
    LUnits.Free;
  end;
end;

function ReadDcpPackage(const APath: string): TPasDcpPackage;
var
  LStream: TFileStream;
  LBytes: TBytes;
  LNeed: Int64;
begin
  Result := TPasDcpPackage.Create;
  try
    Result.FFileName := APath;
    try
      LStream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
    except
      on E: Exception do
        raise EPasDcpError.CreateFmt('%s cannot be opened: %s',
          [TPath.GetFileName(APath), E.Message]);
    end;
    try
      // The header first: it says where the directory ends.
      SetLength(LBytes, 64);
      if LStream.Size < Length(LBytes) then
        SetLength(LBytes, LStream.Size);
      LStream.ReadBuffer(LBytes, Length(LBytes));
      LNeed := Length(LBytes);
      if Length(LBytes) >= 24 then
      begin
        var LBase := 4;
        if LBytes[3] = Ord('1') then
          LBase := 8;
        LNeed := Int64(PCardinal(@LBytes[LBase + 12])^) +
          PCardinal(@LBytes[LBase + 8])^;
      end;
      if (LNeed > Length(LBytes)) and (LNeed <= LStream.Size) and
         (LNeed <= cMaxDirectory) then
      begin
        SetLength(LBytes, LNeed);
        LStream.Position := 0;
        LStream.ReadBuffer(LBytes, LNeed);
      end;
      ParseDirectory(LBytes, LStream.Size, Result);
    finally
      LStream.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ ---- the shared packages ---- }

type
  TDcpCacheItem = record
    Stamp: string;
    Pkg: TPasDcpPackage;    // nil: unreadable, Error says why
    Error: string;
  end;

var
  GLock: TObject;
  GCache: TDictionary<string, TDcpCacheItem>;
  GOwned: TObjectList<TPasDcpPackage>;

function FileStampOf(const APath: string): string;
var
  LRec: TSearchRec;
begin
  Result := '';
  if FindFirst(APath, faAnyFile, LRec) = 0 then
  try
    Result := Format('%.12f/%d', [Double(LRec.TimeStamp), LRec.Size]);
  finally
    FindClose(LRec);
  end;
end;

function CacheItem(const APath: string): TDcpCacheItem;
var
  LKey, LStamp: string;
begin
  LKey := LowerCase(TPath.GetFullPath(APath));
  LStamp := FileStampOf(APath);
  TMonitor.Enter(GLock);
  try
    if GCache.TryGetValue(LKey, Result) and (Result.Stamp = LStamp) then
      Exit;
  finally
    TMonitor.Exit(GLock);
  end;
  // Read outside the lock; a racing reader's copy is kept in GOwned too.
  Result := Default(TDcpCacheItem);
  Result.Stamp := LStamp;
  if LStamp = '' then
    Result.Error := Format('%s does not exist', [TPath.GetFileName(APath)])
  else
    try
      Result.Pkg := ReadDcpPackage(APath);
    except
      on E: Exception do
        Result.Error := E.Message;
    end;
  TMonitor.Enter(GLock);
  try
    if Result.Pkg <> nil then
      GOwned.Add(Result.Pkg);
    GCache.AddOrSetValue(LKey, Result);
  finally
    TMonitor.Exit(GLock);
  end;
end;

function DcpPackage(const APath: string): TPasDcpPackage;
begin
  Result := CacheItem(APath).Pkg;
end;

function DcpPackageError(const APath: string): string;
begin
  Result := CacheItem(APath).Error;
end;

{ ---- member paths ---- }

function DcpMemberPath(const ADcpPath, AUnitName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ADcpPath) + AUnitName + '.dcu';
end;

function SplitDcpMemberPath(const APath: string;
  out ADcpPath, AUnitName: string): Boolean;
begin
  ADcpPath := '';
  AUnitName := '';
  if not SameText(ExtractFileExt(APath), '.dcu') then
    Exit(False);
  ADcpPath := TPath.GetDirectoryName(APath);
  if not SameText(ExtractFileExt(ADcpPath), '.dcp') then
  begin
    ADcpPath := '';
    Exit(False);
  end;
  AUnitName := TPath.GetFileNameWithoutExtension(APath);
  Result := AUnitName <> '';
end;

function ReadDcpMember(const APath: string): TBytes;
var
  LDcp, LUnit: string;
  LItem: TDcpCacheItem;
  LIdx: Integer;
  LStream: TFileStream;
begin
  if not SplitDcpMemberPath(APath, LDcp, LUnit) then
    raise EPasDcpError.CreateFmt('%s names no unit inside a .dcp', [APath]);
  LItem := CacheItem(LDcp);
  if LItem.Pkg = nil then
    raise EPasDcpError.Create(LItem.Error);
  LIdx := LItem.Pkg.IndexOf(LUnit);
  if LIdx < 0 then
    raise EPasDcpError.CreateFmt('%s contains no unit %s',
      [TPath.GetFileName(LDcp), LUnit]);
  LStream := TFileStream.Create(LDcp, fmOpenRead or fmShareDenyWrite);
  try
    if LItem.Pkg.Units[LIdx].Offset + LItem.Pkg.Units[LIdx].Size > LStream.Size then
      raise EPasDcpError.CreateFmt('%s changed while it was read',
        [TPath.GetFileName(LDcp)]);
    SetLength(Result, LItem.Pkg.Units[LIdx].Size);
    LStream.Position := LItem.Pkg.Units[LIdx].Offset;
    LStream.ReadBuffer(Result, Length(Result));
  finally
    LStream.Free;
  end;
end;

function MemberExists(const ADcp, AUnit: string): Boolean;
var
  LPkg: TPasDcpPackage;
begin
  LPkg := DcpPackage(ADcp);
  Result := (LPkg <> nil) and (LPkg.IndexOf(AUnit) >= 0);
end;

function DcuPathExists(const APath: string): Boolean;
var
  LDcp, LUnit: string;
begin
  if FileExists(APath) then
    Exit(True);
  Result := SplitDcpMemberPath(APath, LDcp, LUnit) and MemberExists(LDcp, LUnit);
end;

function DcuStampPath(const APath: string): string;
var
  LDcp, LUnit: string;
begin
  if not FileExists(APath) and SplitDcpMemberPath(APath, LDcp, LUnit) then
    Result := LDcp
  else
    Result := APath;
end;

function DcuSiblingPath(const AFromPath, AUnitName: string): string;
var
  LDcp, LUnit, LDir, LReqPath: string;
  LPkg: TPasDcpPackage;
  LQueue: TQueue<string>;
  LSeen: TDictionary<string, Boolean>;
begin
  if FileExists(AFromPath) or not SplitDcpMemberPath(AFromPath, LDcp, LUnit) then
  begin
    Result := TPath.Combine(TPath.GetDirectoryName(AFromPath), AUnitName + '.dcu');
    if not FileExists(Result) then
      Result := '';
    Exit;
  end;
  if MemberExists(LDcp, AUnitName) then
    Exit(DcpMemberPath(LDcp, AUnitName));
  LDir := TPath.GetDirectoryName(LDcp);
  Result := TPath.Combine(LDir, AUnitName + '.dcu');
  if FileExists(Result) then
    Exit;
  Result := '';
  LPkg := DcpPackage(LDcp);
  if LPkg = nil then
    Exit;
  LQueue := TQueue<string>.Create;
  LSeen := TDictionary<string, Boolean>.Create;
  try
    LSeen.Add(LowerCase(TPath.GetFileNameWithoutExtension(LDcp)), True);
    for var LReq in LPkg.Requires do
      LQueue.Enqueue(LReq);
    while LQueue.Count > 0 do
    begin
      LUnit := LQueue.Dequeue;
      if LSeen.ContainsKey(LowerCase(LUnit)) then
        Continue;
      LSeen.Add(LowerCase(LUnit), True);
      LReqPath := TPath.Combine(LDir, LUnit + '.dcp');
      LPkg := DcpPackage(LReqPath);
      if LPkg = nil then
        Continue;
      if LPkg.IndexOf(AUnitName) >= 0 then
        Exit(DcpMemberPath(LReqPath, AUnitName));
      for var LReq in LPkg.Requires do
        LQueue.Enqueue(LReq);
    end;
  finally
    LSeen.Free;
    LQueue.Free;
  end;
end;

initialization
  GLock := TObject.Create;
  GCache := TDictionary<string, TDcpCacheItem>.Create;
  GOwned := TObjectList<TPasDcpPackage>.Create(True);

finalization
  GCache.Free;
  GOwned.Free;
  GLock.Free;

end.
