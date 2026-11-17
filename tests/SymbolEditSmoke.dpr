program SymbolEditSmoke;

{
  PasTree.SymbolEdit: the edits that remove unused declarations. Each case
  is a unit's text, rows placed in it by hand the way FindUnusedSymbols
  places them (the name's line and column), and the text the edits leave -
  or the refusal. Lines are written with `|` for the line break. The rows of
  a real analysis, and dcc over the result, are UnusedScenarioSmoke's.
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.StrUtils,
  System.Classes,
  System.Generics.Collections,
  System.Generics.Defaults,
  PasTree.Types,
  PasTree.SourceManager,
  PasTree.Preprocessor,
  PasTree.Ast,
  PasTree.Parser,
  PasTree.UsesEdit,
  PasTree.Sema.Model,
  PasTree.Sema.Lint,
  PasTree.SymbolEdit;

var
  GSM: TPasSourceManager;
  GPP: TPasPreprocessor;
  GFailed, GPassed: Integer;
  GTexts: TDictionary<string, string>;   // file -> text

function L(const AText: string): string;
begin
  Result := AText.Replace('|', #13#10);
end;

function Shown(const AText: string): string;
begin
  Result := AText.Replace(#13#10, '|');
end;

procedure Ok(const AName: string; ACond: Boolean; const AMsg: string = '');
begin
  if FindCmdLineSwitch('v') then Writeln('  ', AName);
  if ACond then
    Inc(GPassed)
  else
  begin
    Inc(GFailed);
    Writeln('FAIL ', AName, IfThen(AMsg <> '', ': ' + AMsg, ''));
  end;
end;

// A row of AFile: the name at the AOccurrence-th whole-word ANeedle.
function Row(const AFile, AName: string; AKind: TSemaSymbolKind;
  const ANeedle: string; AOccurrence: Integer = 1): TPasUnusedSymbol;
var
  LText: string;
  LAt, LSeen, LLine: Integer;
begin
  Result := Default(TPasUnusedSymbol);
  Result.FileName := AFile;
  Result.Name := AName;
  Result.Kind := AKind;
  LText := GTexts[AFile];
  LSeen := 0;
  LAt := 0;
  repeat
    LAt := PosEx(ANeedle, LText, LAt + 1);
    if LAt = 0 then
      raise Exception.Create('no ' + ANeedle + ' in ' + AFile);
    if ((LAt = 1) or not CharInSet(LText[LAt - 1], ['A'..'Z', 'a'..'z', '0'..'9',
       '_'])) and ((LAt + Length(ANeedle) > Length(LText)) or
       not CharInSet(LText[LAt + Length(ANeedle)], ['A'..'Z', 'a'..'z',
       '0'..'9', '_'])) then
      Inc(LSeen);
  until LSeen = AOccurrence;
  LLine := 1;
  for var LI := 1 to LAt - 1 do
    if LText[LI] = #10 then
      LLine := LLine + 1;
  Result.Line := LLine;
  Result.Col := LAt - (LastDelimiter(#10, Copy(LText, 1, LAt - 1)));
end;

// A write site of the AOccurrence-th ANeedle in AFile.
function Write(const AFile, ANeedle: string; AOccurrence: Integer;
  AComputed: Boolean = False): TPasUnusedWrite;
var
  LRow: TPasUnusedSymbol;
begin
  LRow := Row(AFile, ANeedle, skField, ANeedle, AOccurrence);
  Result.FileName := AFile;
  Result.Line := LRow.Line;
  Result.Col := LRow.Col;
  Result.Computed := AComputed;
end;

function Removal(const ARows: TArray<TPasUnusedSymbol>;
  const AAsked: TArray<Integer>; out ATaken: TArray<Integer>;
  out ARefused: TArray<TPasSymbolRefusal>): TArray<TPasSymbolRemoval>;
begin
  Result := UnusedSymbolsRemoval(ARows, AAsked,
    function(const AFileName: string; out AText: string): Boolean
    begin
      Result := GTexts.TryGetValue(AFileName, AText);
    end,
    function(const AFileName, AText: string; out ATree: TPasTree;
      out AErrors: Integer): Boolean
    var
      LDiags: TArray<TPasParseDiag>;
    begin
      ATree := TPasParser.ParseFile(GPP.ProcessText(AFileName, AText), LDiags);
      AErrors := Length(LDiags);
      Result := True;
    end, ATaken, ARefused);
end;

function FirstWhy(const ARefused: TArray<TPasSymbolRefusal>): string;
begin
  if ARefused = nil then
    Result := 'nothing refused'
  else
    Result := ARefused[0].Reason;
end;

// AFile's text with AEdits of it applied, each OldText checked.
function Applied(const AFile: string; const AEdits: TArray<TPasSymbolRemoval>;
  out AOldOk: Boolean): string;
begin
  AOldOk := True;
  Result := GTexts[AFile];
  for var LI := High(AEdits) downto 0 do
    if AEdits[LI].FileName = AFile then
    begin
      if Copy(Result, AEdits[LI].Edit.Start + 1, AEdits[LI].Edit.Len) <>
         AEdits[LI].Edit.OldText then
        AOldOk := False;
      Result := Copy(Result, 1, AEdits[LI].Edit.Start) +
        Copy(Result, AEdits[LI].Edit.Start + AEdits[LI].Edit.Len + 1, MaxInt);
    end;
end;

// Removing the rows AAsked of ARows from the one file 'u.pas' leaves
// AExpected, nothing refused.
procedure Check(const AName, AText: string; const ARows: TArray<TPasUnusedSymbol>;
  const AAsked: TArray<Integer>; const AExpected: string);
var
  LEdits: TArray<TPasSymbolRemoval>;
  LTaken: TArray<Integer>;
  LRefused: TArray<TPasSymbolRefusal>;
  LOut: string;
  LOldOk: Boolean;
begin
  LEdits := Removal(ARows, AAsked, LTaken, LRefused);
  LOut := Applied('u.pas', LEdits, LOldOk);
  Ok(AName + ': no refusal', LRefused = nil, FirstWhy(LRefused));
  Ok(AName + ': OldText is the text replaced', LOldOk);
  Ok(AName, LOut = L(AExpected), 'got ' + Shown(LOut) + #13#10'   expected ' +
    AExpected);
end;

procedure CheckRefused(const AName: string; const ARows: TArray<TPasUnusedSymbol>;
  const AAsked: TArray<Integer>; const AWhy: string);
var
  LEdits: TArray<TPasSymbolRemoval>;
  LTaken: TArray<Integer>;
  LRefused: TArray<TPasSymbolRefusal>;
begin
  LEdits := Removal(ARows, AAsked, LTaken, LRefused);
  Ok(AName + ': no edit', LEdits = nil, IntToStr(Length(LEdits)) + ' edits');
  Ok(AName + ': refused', (Length(LRefused) = 1) and
    LRefused[0].Reason.Contains(AWhy), FirstWhy(LRefused));
end;

procedure Use(const AText: string);
begin
  GTexts.AddOrSetValue('u.pas', L(AText));
end;

procedure Cases;
const
  cHead = 'unit u;|interface|';
var
  LRows: TArray<TPasUnusedSymbol>;
  LEdits: TArray<TPasSymbolRemoval>;
  LTaken: TArray<Integer>;
  LRefused: TArray<TPasSymbolRefusal>;
  LText: string;
begin
  // Variables: a name out of a list, the list, the section.
  LText := cHead + 'var|  G1, G2: Integer;|  G3: string;||implementation||end.|';
  Use(LText);
  Check('last name of a list', LText, [Row('u.pas', 'G2', skVar, 'G2')], [0],
    cHead + 'var|  G1: Integer;|  G3: string;||implementation||end.|');
  Check('first name of a list', LText, [Row('u.pas', 'G1', skVar, 'G1')], [0],
    cHead + 'var|  G2: Integer;|  G3: string;||implementation||end.|');
  Check('a whole list: its line', LText, [Row('u.pas', 'G1', skVar, 'G1'),
    Row('u.pas', 'G2', skVar, 'G2')], [0, 1],
    cHead + 'var|  G3: string;||implementation||end.|');
  Check('a whole section', LText, [Row('u.pas', 'G1', skVar, 'G1'),
    Row('u.pas', 'G2', skVar, 'G2'), Row('u.pas', 'G3', skVar, 'G3')],
    [0, 1, 2], cHead + '|implementation||end.|');

  // A method: its declaration and its body; the blank lines kept single.
  LText := cHead + 'type|  TFoo = class|    procedure A;|    procedure B;|' +
    '  end;||implementation||procedure TFoo.A;|begin|end;||' +
    'procedure TFoo.B;|begin|end;||end.|';
  Use(LText);
  Check('a method and its body', LText, [Row('u.pas', 'TFoo.A', skRoutine,
    'A')], [0], cHead + 'type|  TFoo = class|    procedure B;|  end;||' +
    'implementation||procedure TFoo.B;|begin|end;||end.|');
  // A type: its declaration, its section, its methods' bodies.
  Check('a type and its methods', LText, [Row('u.pas', 'TFoo', skType,
    'TFoo')], [0], cHead + '|implementation||end.|');

  // Overloads: the body with the same parameters.
  LText := cHead + 'procedure P(A: Integer); overload;|' +
    'procedure P(const S: string); overload;||implementation||' +
    'procedure P(A: Integer);|begin|end;||procedure P(const S: string);|' +
    'begin|end;||end.|';
  Use(LText);
  Check('an overload and its body', LText, [Row('u.pas', 'P', skRoutine, 'P',
    2)], [0], cHead + 'procedure P(A: Integer); overload;||implementation||' +
    'procedure P(A: Integer);|begin|end;||end.|');

  // A forward and a nested routine.
  LText := cHead + '|implementation||procedure F; forward;||procedure G;|' +
    '  procedure Inner;|  begin|  end;|begin|end;||procedure F;|begin|end;||' +
    'end.|';
  Use(LText);
  Check('a forward and its body', LText, [Row('u.pas', 'F', skRoutine, 'F')],
    [0], cHead + '|implementation||procedure G;|  procedure Inner;|  begin|' +
    '  end;|begin|end;||end.|');
  Check('a nested routine', LText, [Row('u.pas', 'G.Inner', skRoutine,
    'Inner')], [0], cHead + '|implementation||procedure F; forward;||' +
    'procedure G;|begin|end;||procedure F;|begin|end;||end.|');

  // A field only assigned: its assignments go, in a list and as a body.
  LText := cHead + 'type|  TFoo = class|  private|    FA: Integer;|' +
    '    FB: Integer;|  public|    procedure M(C: Boolean);|  end;||' +
    'implementation||procedure TFoo.M(C: Boolean);|begin|  FA := 1;|' +
    '  Self.FA := 2;|  if C then FA := 3;|  FB := FB + 1;|end;||end.|';
  Use(LText);
  LRows := [Row('u.pas', 'TFoo.FA', skField, 'FA')];
  LRows[0].How := uhOnlyWritten;
  LRows[0].WriteSites := [Write('u.pas', 'FA', 2), Write('u.pas', 'FA', 3),
    Write('u.pas', 'FA', 4)];
  Check('a field only assigned and its assignments', LText, LRows, [0],
    cHead + 'type|  TFoo = class|  private|    FB: Integer;|  public|' +
    '    procedure M(C: Boolean);|  end;||implementation||' +
    'procedure TFoo.M(C: Boolean);|begin|  if C then ;|  FB := FB + 1;|end;||' +
    'end.|');
  LRows[0].WriteSites[0].Computed := True;
  CheckRefused('a computed value', LRows, [0], 'computed by code');

  // Used only by rows: those go too; one that is no row refuses it.
  LText := cHead + 'type|  TFoo = class|  private|    function GetX: Integer;|' +
    '  public|    property X: Integer read GetX;|  end;||implementation||' +
    'function TFoo.GetX: Integer;|begin|  Result := 0;|end;||end.|';
  Use(LText);
  LRows := [Row('u.pas', 'TFoo.GetX', skRoutine, 'GetX'),
    Row('u.pas', 'TFoo.X', skProperty, 'X')];
  LRows[0].How := uhOnlyByUnused;
  LRows[0].By := ['TFoo.X'];
  Check('a getter takes its property', LText, LRows, [0],
    cHead + 'type|  TFoo = class|  private|  public|  end;||implementation||' +
    'end.|');
  LEdits := Removal(LRows, [0], LTaken, LRefused);
  Ok('a getter takes its property: both taken', (Length(LTaken) = 2));
  CheckRefused('a user that is no row', [LRows[0]], [0],
    'TFoo.X uses it and is not removed with it');
  LRows[1].Doubts := ['a doubt'];
  CheckRefused('a user with a doubt', LRows, [0], 'has a doubt');

  // Directives: a switch refuses, a balanced conditional goes, a split
  // declaration refuses.
  LText := cHead + '|implementation||procedure A;|begin|{$R-}|end;||' +
    'procedure B;|begin|{$IFDEF X}|  Beep;|{$ENDIF}|end;||' +
    '{$IFDEF Y}|procedure C(I: Integer);|{$ELSE}|procedure C;|{$ENDIF}|' +
    'begin|end;||end.|';
  Use(LText);
  CheckRefused('a switch inside', [Row('u.pas', 'A', skRoutine, 'A')], [0],
    '{$R}');
  Check('a balanced conditional inside', LText, [Row('u.pas', 'B', skRoutine,
    'B')], [0], cHead + '|implementation||procedure A;|begin|{$R-}|end;||' +
    '{$IFDEF Y}|procedure C(I: Integer);|{$ELSE}|procedure C;|{$ENDIF}|' +
    'begin|end;||end.|');
  CheckRefused('split between branches', [Row('u.pas', 'C', skRoutine, 'C',
    2)], [0], 'splits it between branches');

  // A variant record's field; a class var section; the file changed.
  LText := cHead + 'type|  TR = record|    A: Integer;|    case B: Integer of|' +
    '      0: (C: Integer);|  end;|  TK = class|    class var CV: Integer;|' +
    '    procedure M;|  end;||implementation||procedure TK.M;|begin|end;||' +
    'end.|';
  Use(LText);
  CheckRefused('a variant field', [Row('u.pas', 'TR.C', skField, 'C')], [0],
    'variant part');
  Check('a class var section', LText, [Row('u.pas', 'TK.CV', skField, 'CV')],
    [0], cHead + 'type|  TR = record|    A: Integer;|    case B: Integer of|' +
    '      0: (C: Integer);|  end;|  TK = class|    procedure M;|  end;||' +
    'implementation||procedure TK.M;|begin|end;||end.|');
  LRows := [Row('u.pas', 'TK.CV', skField, 'CV')];
  Inc(LRows[0].Line);
  CheckRefused('the file changed', LRows, [0], 'the file has changed');

  // Comments: one directly above goes, a group's heading stays.
  LText := cHead + 'const|  // The answer.|  C1 = 42;||  // Limits|  C2 = 1;|' +
    '  C3 = 2;||implementation||end.|';
  Use(LText);
  Check('a comment above goes', LText, [Row('u.pas', 'C1', skConst, 'C1')],
    [0], cHead + 'const|  // Limits|  C2 = 1;|  C3 = 2;||implementation||' +
    'end.|');
  Check('a group''s heading stays', LText, [Row('u.pas', 'C2', skConst,
    'C2')], [0], cHead + 'const|  // The answer.|  C1 = 42;||  // Limits|' +
    '  C3 = 2;||implementation||end.|');

  // An external routine: the implementation is a header of its own.
  LText := cHead + 'function F(A: Integer): Integer; stdcall;|' +
    'function G: Integer; stdcall;||implementation||' +
    'function F; external ''x.dll'' name ''F'';||' +
    'function G; external ''x.dll'' name ''G'';||end.|';
  Use(LText);
  Check('an external and its implementation header', LText,
    [Row('u.pas', 'F', skRoutine, 'F')], [0], cHead +
    'function G: Integer; stdcall;||implementation||' +
    'function G; external ''x.dll'' name ''G'';||end.|');

  // A class property and a class method: their `class` goes too, the
  // type's own `class` stays.
  LText := cHead + 'type|  TC = class|    class function Get: Integer; static;|' +
    '    class property P: Integer read Get;|  end;||implementation||' +
    'class function TC.Get: Integer;|begin|  Result := 0;|end;||end.|';
  Use(LText);
  LRows := [Row('u.pas', 'TC.P', skProperty, 'P'), Row('u.pas', 'TC.Get',
    skRoutine, 'Get')];
  LRows[1].By := ['TC.P'];
  Check('a class property and its class getter', LText, LRows, [1],
    cHead + 'type|  TC = class|  end;||implementation||end.|');

  // A row in an include file.
  GTexts.AddOrSetValue('i.inc', L('const|  CI = 1;|'));
  CheckRefused('an include file', [Row('i.inc', 'CI', skConst, 'CI')], [0],
    'include file');

  // Two files: a field declared in one, assigned in the other.
  GTexts.AddOrSetValue('a.pas', L('unit a;|interface|var|  V: Integer;|' +
    '  W: Integer;|implementation|end.|'));
  Use('unit u;|interface|implementation|uses a;|initialization|  V := 1;|' +
    '  W := 2;|end.|');
  LRows := [Row('a.pas', 'V', skVar, 'V')];
  LRows[0].How := uhOnlyWritten;
  LRows[0].WriteSites := [Write('u.pas', 'V', 1)];
  LEdits := Removal(LRows, [0], LTaken, LRefused);
  var LOldOk: Boolean;
  Ok('two files: two edits', Length(LEdits) = 2);
  Ok('two files: the declaration', Applied('a.pas', LEdits, LOldOk) =
    L('unit a;|interface|var|  W: Integer;|implementation|end.|'));
  Ok('two files: the assignment', Applied('u.pas', LEdits, LOldOk) =
    L('unit u;|interface|implementation|uses a;|initialization|  W := 2;|' +
    'end.|'), Shown(Applied('u.pas', LEdits, LOldOk)));
end;

begin
  try
    GSM := TPasSourceManager.Create(nil);
    GPP := TPasPreprocessor.Create(GSM, TPasDefines.Create);
    GTexts := TDictionary<string, string>.Create;
    try
      Cases;
    finally
      GTexts.Free;
      GPP.Free;
      GSM.Free;
    end;
    Writeln(Format('SymbolEditSmoke: %d passed, %d failed', [GPassed,
      GFailed]));
    if GFailed > 0 then
      ExitCode := 1;
  except
    on E: Exception do
    begin
      Writeln('EXCEPTION ', E.ClassName, ': ', E.Message, ' at ', IntToHex(NativeUInt(ExceptAddr) - HInstance + $400000, 8));
      ExitCode := 1;
    end;
  end;
end.
