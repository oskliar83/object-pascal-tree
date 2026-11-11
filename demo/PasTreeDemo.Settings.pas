unit PasTreeDemo.Settings;

{
  PasTree demo - persisted settings, in a plain .ini next to the executable.

  Everything the demo used to forget on every launch: the target platform, the
  highlighter and threading choices, the identifier-highlight colour, and the
  list of recently opened projects.

  A file rather than the registry, deliberately: it travels with the checkout,
  can be inspected and hand-edited, and a corrupt or missing one costs nothing
  - every getter takes a default. The registry is still read for the IDE's own
  library paths (that is the IDE's data, not ours).

  Layout:

      [Settings]
      Platform=1
      Highlighter=1
      Threading=1
      HighlightColor=16032864
      LightLibraries=0

      [Recent]
      Project0=C:\Repos\...\Some.dproj
      Project1=...

      [Format]
      IndentStep=2
      TabWidth=8
      MaxBlankLines=2
      BeginOnNewLine=1
      ElseOnNewLine=1
      StatementAfterThenDo=Always
      OneStatementPerLine=1
      OneDeclPerLine=1
      IndentNestedRoutines=1
      KeepDirectivesAtColumn1=1
      KeepCommentsAtColumn1=1
      NormalizeSpaces=1
      SpaceAroundOperators=1
      SpaceAfterSeparators=1
      RemoveSpaces=1
      ReservedWordCase=Lower
      DirectiveWordCase=Lower
      CompilerDirectiveCase=Upper
      RightMargin=0
      WrapLongLines=0
      AlignAssignments=0
      AlignDeclColons=0
      AlignTrailingComments=0
      FormatDcuText=1

  [Format] is TPasFormatOptions field for field, under the field's own name;
  an absent or unreadable key takes TPasFormatOptions.Default's value, so an
  empty section IS the default style. StatementAfterThenDo is spelled
  Always / Keep (TPasFormatBreak without its prefix), the three case keys
  Lower / Upper / Keep (TPasFormatCase without its prefix). There is no options
  dialog - the section is written back on exit so it can be hand-edited.
  FormatDcuText is the demo's own key, not an options field: whether a
  compiled unit's generated interface text is analyzed and shown in that
  style (TPasSemaProject.DcuTextFilter); default on.

  Recent entries are most-recent-first, deduplicated by full path (case-
  insensitively, matching the filesystem), and capped - see RECENT_MAX.
}

interface

uses
  System.SysUtils, System.Classes, System.IniFiles,
  PasTree.Format;

const
  // Twenty still fits a drop-down without scrolling on any usable screen, and
  // covers more than the working week ten did - the list is the fastest way
  // back into a project that was open two days ago. The cap is applied on ADD,
  // so the file never grows unbounded whatever this is set to.
  RECENT_MAX = 20;

type
  TDemoSettings = class
  private
    FIni: TMemIniFile;
    FRecent: TStringList;
    procedure LoadRecent;
    procedure SaveRecent;
  public
    constructor Create(const AFileName: string);
    destructor Destroy; override;

    // Values, with the caller's default when the key is absent or unparsable.
    function ReadInt(const AName: string; ADefault: Integer): Integer;
    procedure WriteInt(const AName: string; AValue: Integer);
    function ReadString(const AName, ADefault: string): string;
    procedure WriteString(const AName, AValue: string);
    { The Light libraries checkbox (TPasSemaProject.LightPaths): library
      units interface-only. Default OFF - the demo shows the analyzer whole
      unless asked; [Settings] LightLibraries=1. }
    function GetLightLibraries: Boolean;
    procedure SetLightLibraries(AValue: Boolean);
    property LightLibraries: Boolean read GetLightLibraries
      write SetLightLibraries;

    { The formatter's style, section [Format]: each field read separately,
      falling back to TPasFormatOptions.Default's value for that field. A
      negative IndentStep or TabWidth, or a MaxBlankLines below -1, is
      unreadable and takes the default too. }
    function ReadFormatOptions: TPasFormatOptions;
    procedure WriteFormatOptions(const AOptions: TPasFormatOptions);
    { [Format] FormatDcuText: a .dcu-only unit's generated text goes through
      the formatter with ReadFormatOptions' style before the analysis and
      the unit's tab read it. Default ON - the demo shows the feature. }
    function GetFormatDcuText: Boolean;
    procedure SetFormatDcuText(AValue: Boolean);
    property FormatDcuText: Boolean read GetFormatDcuText
      write SetFormatDcuText;

    { Moves AProjectFile to the front, or inserts it there. Existence is NOT
      checked here: a project on a disconnected network share is still the last
      thing the user opened, and dropping it at save time would lose it for
      good. The display side does the pruning - see ExistingRecent. }
    procedure AddRecent(const AProjectFile: string);
    // Every remembered entry, most-recent-first, including missing files.
    function Recent: TArray<string>;
    { The subset that exists RIGHT NOW, for the menu. Checked per call rather
      than cached: a share can come back between two drops of the list. }
    function ExistingRecent: TArray<string>;

    procedure Save;
  end;

// The settings file for this executable: <exe dir>\PasTreeDemo.ini.
function DefaultSettingsFile: string;

implementation

uses
  System.IOUtils;

const
  SEC_SETTINGS = 'Settings';
  SEC_RECENT = 'Recent';
  KEY_PROJECT = 'Project';
  SET_LIGHTLIBRARIES = 'LightLibraries';
  SEC_FORMAT = 'Format';
  FMT_DCUTEXT = 'FormatDcuText';
  // TPasFormatBreak's values as the .ini spells them, in declaration order.
  FORMAT_BREAK_NAMES: array[TPasFormatBreak] of string = ('Always', 'Keep');
  FORMAT_CASE_NAMES: array[TPasFormatCase] of string = ('Lower', 'Upper',
    'Keep');

function DefaultSettingsFile: string;
begin
  Result := TPath.ChangeExtension(ParamStr(0), '.ini');
end;

constructor TDemoSettings.Create(const AFileName: string);
begin
  inherited Create;
  // TMemIniFile reads once and writes once (UpdateFile), so nothing here
  // touches the disk between Create and Save - the recent list is rewritten on
  // every open, and a file write per click is not something to pay for.
  FIni := TMemIniFile.Create(AFileName, TEncoding.UTF8);
  FRecent := TStringList.Create;
  FRecent.CaseSensitive := False;
  LoadRecent;
end;

destructor TDemoSettings.Destroy;
begin
  FRecent.Free;
  FIni.Free;
  inherited;
end;

procedure TDemoSettings.LoadRecent;
var
  LIdx: Integer;
  LPath: string;
begin
  FRecent.Clear;
  // Read by INDEX, not by enumerating the section: the order IS the data here,
  // and ReadSection gives no guarantee about it.
  for LIdx := 0 to RECENT_MAX - 1 do
  begin
    LPath := FIni.ReadString(SEC_RECENT, KEY_PROJECT + IntToStr(LIdx), '');
    if (LPath <> '') and (FRecent.IndexOf(LPath) < 0) then
      FRecent.Add(LPath);
  end;
end;

procedure TDemoSettings.SaveRecent;
var
  LIdx: Integer;
begin
  // Erased first: shortening the list must not leave the old tail behind under
  // its own keys, where the next load would read it back.
  FIni.EraseSection(SEC_RECENT);
  for LIdx := 0 to FRecent.Count - 1 do
    FIni.WriteString(SEC_RECENT, KEY_PROJECT + IntToStr(LIdx), FRecent[LIdx]);
end;

function TDemoSettings.ReadInt(const AName: string; ADefault: Integer): Integer;
begin
  Result := FIni.ReadInteger(SEC_SETTINGS, AName, ADefault);
end;

procedure TDemoSettings.WriteInt(const AName: string; AValue: Integer);
begin
  FIni.WriteInteger(SEC_SETTINGS, AName, AValue);
end;

function TDemoSettings.ReadString(const AName, ADefault: string): string;
begin
  Result := FIni.ReadString(SEC_SETTINGS, AName, ADefault);
end;

procedure TDemoSettings.WriteString(const AName, AValue: string);
begin
  FIni.WriteString(SEC_SETTINGS, AName, AValue);
end;

function TDemoSettings.GetLightLibraries: Boolean;
begin
  Result := ReadInt(SET_LIGHTLIBRARIES, 0) <> 0;
end;

procedure TDemoSettings.SetLightLibraries(AValue: Boolean);
begin
  WriteInt(SET_LIGHTLIBRARIES, Ord(AValue));
end;

function TDemoSettings.ReadFormatOptions: TPasFormatOptions;

  function ReadIntAtLeast(const AName: string; AMin, ADefault: Integer): Integer;
  begin
    Result := FIni.ReadInteger(SEC_FORMAT, AName, ADefault);
    if Result < AMin then
      Result := ADefault;
  end;

  function ReadFlag(const AName: string; ADefault: Boolean): Boolean;
  begin
    Result := FIni.ReadInteger(SEC_FORMAT, AName, Ord(ADefault)) <> 0;
  end;

  function ReadCase(const AName: string; ADefault: TPasFormatCase): TPasFormatCase;
  var
    LCase: TPasFormatCase;
    LName: string;
  begin
    Result := ADefault;
    LName := FIni.ReadString(SEC_FORMAT, AName, '');
    for LCase := Low(TPasFormatCase) to High(TPasFormatCase) do
      if SameText(LName, FORMAT_CASE_NAMES[LCase]) then
        Result := LCase;
  end;

var
  LDef: TPasFormatOptions;
  LBreak: TPasFormatBreak;
  LText: string;
begin
  LDef := TPasFormatOptions.Default;
  // Starts from the default record, so a field a later stage adds to
  // TPasFormatOptions has its default here before this unit learns its key.
  Result := LDef;
  Result.IndentStep := ReadIntAtLeast('IndentStep', 0, LDef.IndentStep);
  Result.TabWidth := ReadIntAtLeast('TabWidth', 1, LDef.TabWidth);
  Result.MaxBlankLines := ReadIntAtLeast('MaxBlankLines', -1,
    LDef.MaxBlankLines);
  Result.BeginOnNewLine := ReadFlag('BeginOnNewLine', LDef.BeginOnNewLine);
  Result.ElseOnNewLine := ReadFlag('ElseOnNewLine', LDef.ElseOnNewLine);
  LText := FIni.ReadString(SEC_FORMAT, 'StatementAfterThenDo', '');
  for LBreak := Low(TPasFormatBreak) to High(TPasFormatBreak) do
    if SameText(LText, FORMAT_BREAK_NAMES[LBreak]) then
      Result.StatementAfterThenDo := LBreak;
  Result.OneStatementPerLine := ReadFlag('OneStatementPerLine',
    LDef.OneStatementPerLine);
  Result.OneDeclPerLine := ReadFlag('OneDeclPerLine', LDef.OneDeclPerLine);
  Result.IndentNestedRoutines := ReadFlag('IndentNestedRoutines',
    LDef.IndentNestedRoutines);
  Result.KeepDirectivesAtColumn1 := ReadFlag('KeepDirectivesAtColumn1',
    LDef.KeepDirectivesAtColumn1);
  Result.KeepCommentsAtColumn1 := ReadFlag('KeepCommentsAtColumn1',
    LDef.KeepCommentsAtColumn1);
  Result.NormalizeSpaces := ReadFlag('NormalizeSpaces', LDef.NormalizeSpaces);
  Result.SpaceAroundOperators := ReadFlag('SpaceAroundOperators',
    LDef.SpaceAroundOperators);
  Result.SpaceAfterSeparators := ReadFlag('SpaceAfterSeparators',
    LDef.SpaceAfterSeparators);
  Result.RemoveSpaces := ReadFlag('RemoveSpaces', LDef.RemoveSpaces);
  Result.ReservedWordCase := ReadCase('ReservedWordCase', LDef.ReservedWordCase);
  Result.DirectiveWordCase := ReadCase('DirectiveWordCase',
    LDef.DirectiveWordCase);
  Result.CompilerDirectiveCase := ReadCase('CompilerDirectiveCase',
    LDef.CompilerDirectiveCase);
  Result.RightMargin := ReadIntAtLeast('RightMargin', 0, LDef.RightMargin);
  Result.WrapLongLines := ReadFlag('WrapLongLines', LDef.WrapLongLines);
  Result.AlignAssignments := ReadFlag('AlignAssignments', LDef.AlignAssignments);
  Result.AlignDeclColons := ReadFlag('AlignDeclColons', LDef.AlignDeclColons);
  Result.AlignTrailingComments := ReadFlag('AlignTrailingComments',
    LDef.AlignTrailingComments);
end;

function TDemoSettings.GetFormatDcuText: Boolean;
begin
  Result := FIni.ReadInteger(SEC_FORMAT, FMT_DCUTEXT, 1) <> 0;
end;

procedure TDemoSettings.SetFormatDcuText(AValue: Boolean);
begin
  FIni.WriteInteger(SEC_FORMAT, FMT_DCUTEXT, Ord(AValue));
end;

procedure TDemoSettings.WriteFormatOptions(const AOptions: TPasFormatOptions);
begin
  FIni.WriteInteger(SEC_FORMAT, 'IndentStep', AOptions.IndentStep);
  FIni.WriteInteger(SEC_FORMAT, 'TabWidth', AOptions.TabWidth);
  FIni.WriteInteger(SEC_FORMAT, 'MaxBlankLines', AOptions.MaxBlankLines);
  FIni.WriteInteger(SEC_FORMAT, 'BeginOnNewLine', Ord(AOptions.BeginOnNewLine));
  FIni.WriteInteger(SEC_FORMAT, 'ElseOnNewLine', Ord(AOptions.ElseOnNewLine));
  FIni.WriteString(SEC_FORMAT, 'StatementAfterThenDo',
    FORMAT_BREAK_NAMES[AOptions.StatementAfterThenDo]);
  FIni.WriteInteger(SEC_FORMAT, 'OneStatementPerLine',
    Ord(AOptions.OneStatementPerLine));
  FIni.WriteInteger(SEC_FORMAT, 'OneDeclPerLine', Ord(AOptions.OneDeclPerLine));
  FIni.WriteInteger(SEC_FORMAT, 'IndentNestedRoutines',
    Ord(AOptions.IndentNestedRoutines));
  FIni.WriteInteger(SEC_FORMAT, 'KeepDirectivesAtColumn1',
    Ord(AOptions.KeepDirectivesAtColumn1));
  FIni.WriteInteger(SEC_FORMAT, 'KeepCommentsAtColumn1',
    Ord(AOptions.KeepCommentsAtColumn1));
  FIni.WriteInteger(SEC_FORMAT, 'NormalizeSpaces', Ord(AOptions.NormalizeSpaces));
  FIni.WriteInteger(SEC_FORMAT, 'SpaceAroundOperators',
    Ord(AOptions.SpaceAroundOperators));
  FIni.WriteInteger(SEC_FORMAT, 'SpaceAfterSeparators',
    Ord(AOptions.SpaceAfterSeparators));
  FIni.WriteInteger(SEC_FORMAT, 'RemoveSpaces', Ord(AOptions.RemoveSpaces));
  FIni.WriteString(SEC_FORMAT, 'ReservedWordCase',
    FORMAT_CASE_NAMES[AOptions.ReservedWordCase]);
  FIni.WriteString(SEC_FORMAT, 'DirectiveWordCase',
    FORMAT_CASE_NAMES[AOptions.DirectiveWordCase]);
  FIni.WriteString(SEC_FORMAT, 'CompilerDirectiveCase',
    FORMAT_CASE_NAMES[AOptions.CompilerDirectiveCase]);
  FIni.WriteInteger(SEC_FORMAT, 'RightMargin', AOptions.RightMargin);
  FIni.WriteInteger(SEC_FORMAT, 'WrapLongLines', Ord(AOptions.WrapLongLines));
  FIni.WriteInteger(SEC_FORMAT, 'AlignAssignments',
    Ord(AOptions.AlignAssignments));
  FIni.WriteInteger(SEC_FORMAT, 'AlignDeclColons', Ord(AOptions.AlignDeclColons));
  FIni.WriteInteger(SEC_FORMAT, 'AlignTrailingComments',
    Ord(AOptions.AlignTrailingComments));
end;

procedure TDemoSettings.AddRecent(const AProjectFile: string);
var
  LFull: string;
  LIdx: Integer;
begin
  if AProjectFile = '' then
    Exit;
  // Normalized before comparing, so the same project reached through a
  // relative path or a different case is one entry, not two.
  LFull := TPath.GetFullPath(AProjectFile);
  LIdx := FRecent.IndexOf(LFull);   // CaseSensitive=False
  if LIdx >= 0 then
    FRecent.Delete(LIdx);
  FRecent.Insert(0, LFull);
  while FRecent.Count > RECENT_MAX do
    FRecent.Delete(FRecent.Count - 1);
end;

function TDemoSettings.Recent: TArray<string>;
begin
  Result := FRecent.ToStringArray;
end;

function TDemoSettings.ExistingRecent: TArray<string>;
var
  LPath: string;
begin
  Result := nil;
  for LPath in FRecent do
    if TFile.Exists(LPath) then
      Result := Result + [LPath];
end;

procedure TDemoSettings.Save;
begin
  SaveRecent;
  FIni.UpdateFile;
end;

end.
