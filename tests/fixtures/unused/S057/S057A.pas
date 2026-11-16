unit S057A;
interface
type
  TRect4 = class
  private
    FV: array[0..3] of Integer;
    function GetV(AIndex: Integer): Integer;
  public
    property Left: Integer index 0 read GetV;
    property Top: Integer index 1 read GetV;
  end;
implementation
function TRect4.GetV(AIndex: Integer): Integer; begin Result := FV[AIndex]; end;
var R: TRect4;
initialization
  R := TRect4.Create;
  if R.Left <> 0 then Halt(3);
  R.Free;
end.
