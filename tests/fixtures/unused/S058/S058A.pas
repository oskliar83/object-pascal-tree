unit S058A;
interface
implementation
const
  CDefault = 4;
  CBlue = 2;
function Twice(A: Integer = CDefault): Integer; begin Result := A * 2; end;
initialization
  if Twice <> 8 then Halt(3);
end.
