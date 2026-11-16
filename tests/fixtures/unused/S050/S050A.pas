unit S050A;
interface
uses System.Classes;
type
  TStrEnum = record
  private
    FList: TStrings;
    FI: Integer;
  public
    function MoveNext: Boolean;
    function GetCurrent: string;
    property Current: string read GetCurrent;
  end;
  TStringsLenHelper = class helper for TStrings
    function GetEnumerator: TStrEnum;
  end;
implementation
function TStrEnum.MoveNext: Boolean; begin Inc(FI); Result := FI < FList.Count; end;
function TStrEnum.GetCurrent: string; begin Result := FList[FI] + '!'; end;
function TStringsLenHelper.GetEnumerator: TStrEnum; begin Result.FList := Self; Result.FI := -1; end;
var L: TStringList; S, R: string;
initialization
  L := TStringList.Create;
  L.Add('a');
  R := '';
  for S in L do R := R + S;
  if R <> 'a!' then Halt(3);
  L.Free;
end.
