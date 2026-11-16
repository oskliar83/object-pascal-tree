unit S059A;
interface
implementation
const
  CRed = 1;
var X: Integer;
initialization
  X := 1;
  case X of
    CRed: X := 10;
  end;
  if X <> 10 then Halt(3);
end.
