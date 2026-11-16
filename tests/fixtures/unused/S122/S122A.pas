unit S122A;
interface
type
  TSize2 = record
    W, H: Integer;
    function Area: Integer;
    function Perimeter: Integer;
  end;
const
  CUnit: TSize2 = (W: 2; H: 3);
implementation
function TSize2.Area: Integer; begin Result := W * H; end;
function TSize2.Perimeter: Integer; begin Result := 2 * (W + H); end;
initialization
  if CUnit.Area <> 6 then Halt(3);
end.
