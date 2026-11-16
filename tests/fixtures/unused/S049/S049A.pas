unit S049A;
interface
type
  TBag = class;
  TBagEnum = class
  private
    FBag: TBag;
    FI: Integer;
  public
    constructor Create(ABag: TBag);
    function MoveNext: Boolean;
    function GetCurrent: Integer;
    property Current: Integer read GetCurrent;
    procedure Reset;
  end;
  TBag = class
    Items: array[0..2] of Integer;
    function GetEnumerator: TBagEnum;
  end;
implementation
constructor TBagEnum.Create(ABag: TBag); begin FBag := ABag; FI := -1; end;
function TBagEnum.MoveNext: Boolean; begin Inc(FI); Result := FI < 3; end;
function TBagEnum.GetCurrent: Integer; begin Result := FBag.Items[FI]; end;
procedure TBagEnum.Reset; begin FI := -1; end;
function TBag.GetEnumerator: TBagEnum; begin Result := TBagEnum.Create(Self); end;
var B: TBag; I, S: Integer;
initialization
  B := TBag.Create;
  B.Items[0] := 1; B.Items[1] := 2; B.Items[2] := 3;
  S := 0;
  for I in B do Inc(S, I);
  if S <> 6 then Halt(3);
  B.Free;
end.
